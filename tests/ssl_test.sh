#!/usr/bin/env bash
# Certificados: Let's Encrypt por DNS o HTTP, la prueba de renovación y los
# certificados de origen de Cloudflare.
#   bash tests/ssl_test.sh
#
# 'cmd_ssl' no tenía ni una prueba, y sus dos fallos de verdad eran de los que
# no avisan: un alias comodín que desaparecía de la petición (nullglob) y una
# renovación que se rompe sesenta días después de emitir. Aquí hay dos dobles,
# y los dos están hechos para poder fallar:
#
#   · certbot apunta con qué argumentos lo llaman y, al emitir, deja un
#     certificado de verdad en la carpeta de mentira de Let's Encrypt, para que
#     el vhost se genere por la rama con HTTPS.
#   · curl hace de API de Cloudflare: lee el token **del fichero de -K**, como
#     el de verdad, y a una petición de certificado contesta firmando el CSR
#     que le mandan con una CA de pruebas. Si Orbit mandara una clave que no es
#     la suya, o guardara un certificado que no casa con su clave, nginx -t lo
#     rechazaría en un servidor; aquí lo rechaza _cert_key_match, y la prueba
#     se pone en rojo.
# shellcheck disable=SC2034  # asigna variables (A_*, LETSENCRYPT_EMAIL…) que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v openssl >/dev/null && command -v jq >/dev/null || {
  echo "Sin openssl o sin jq no puedo generar ni leer certificados: me salto estas pruebas."
  echo "  sudo apt-get install -y openssl jq"
  exit 0
}

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
mkdir -p "$TMP/le/live" "$LE_RENEWAL_DIR" "$TMP/fx/cf"

# Let's Encrypt de mentira, en su sitio de pruebas.
cert_file() { echo "$TMP/le/live/$1/fullchain.pem"; }
cert_key()  { echo "$TMP/le/live/$1/privkey.pem"; }

# nginx y systemd no se tocan. 'nginx -t' falla cuando se le pide y, como el de
# verdad, cuando un vhost nombra un certificado o una clave que no existen: sin
# eso, borrar un certificado antes de que nginx aceptara el vhost nuevo —el
# orden que protege producción— salía en verde.
NGINX_FAIL=""
nginx() {
  [[ "${1:-}" == "-t" ]] || return 0
  [[ -n "$NGINX_FAIL" ]] && return 1
  local f p
  for f in "$NGINX_AVAILABLE"/*.conf; do
    while read -r p <&3; do
      [[ -f "$p" ]] || return 1
    done 3< <(sed -n 's/^[[:space:]]*ssl_certificate\(_key\)\{0,1\}[[:space:]]\{1,\}\([^;]*\);.*/\2/p' "$f")
  done
  return 0
}
systemctl() { return 0; }

# Un certificado autofirmado con estos nombres. Lo que importa es que sea un
# certificado de verdad: openssl tiene que poder leer su fecha y sus nombres.
selfsigned() { # selfsigned <cert> <clave> <días> <nombre>…
  local c="$1" k="$2" days="$3"; shift 3
  local san; san="$(printf 'DNS:%s,' "$@")"; san="${san%,}"
  mkdir -p "$(dirname "$c")"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days "$days" \
    -keyout "$k" -out "$c" -subj "/CN=$1" -addext "subjectAltName=$san" >/dev/null 2>&1
}

# --- certbot de mentira -------------------------------------------------------
CERTBOT_LOG="$TMP/certbot.log"; : > "$CERTBOT_LOG"
CERTBOT_FAIL=""
certbot() {
  printf '%s\n' "$*" >> "$CERTBOT_LOG"
  [[ -n "$CERTBOT_FAIL" ]] && return 1
  local name="" a prev="" auth="webroot" cred=""
  local -a ds=()
  for a in "$@"; do
    [[ "$prev" == "--cert-name" ]] && name="$a"
    [[ "$prev" == "-d" ]] && ds+=("$a")
    [[ "$prev" == "--dns-cloudflare-credentials" ]] && cred="$a"
    [[ "$a" == "--dns-cloudflare" ]] && auth="dns-cloudflare"
    prev="$a"
  done
  case "${1:-}" in
    certonly)
      [[ " $* " == *" --dry-run "* ]] && return 0
      selfsigned "$(cert_file "$name")" "$(cert_key "$name")" 90 "${ds[@]}"
      # Lo que guarda certbot de verdad, en lo que Orbit mira.
      { printf '[renewalparams]\nauthenticator = %s\n' "$auth"
        [[ -n "$cred" ]] && printf 'dns_cloudflare_credentials = %s\n' "$cred"
        [[ "$auth" == webroot ]] && printf 'webroot_path = %s,\n' "$ACME_DIR"
      } > "$LE_RENEWAL_DIR/$name.conf" ;;
    delete)
      rm -rf "$TMP/le/live/$name" "$LE_RENEWAL_DIR/$name.conf" ;;
  esac
  return 0
}

# --- la API de Cloudflare de mentira -----------------------------------------
FAKE_TOKEN="cf-token-de-pruebas_123"
FAKE_ACCOUNT_TOKEN="cfat_token-de-cuenta_456"
FAKE_VERIFY="active"          # active | disabled | invalid | offline
FAKE_DENY=""                  # no vacío: el token no tiene el permiso de certificados
declare -A FAKE_ZONES=([tienda.test]="Z1")
declare -A FAKE_PROXY=([tienda.test]="true" [www.tienda.test]="true")
CURL_ARGV="$TMP/curl.argv"; : > "$CURL_ARGV"
CURL_CFG="$TMP/curl.cfg";   : > "$CURL_CFG"

# La CA que hace de Cloudflare: el emisor lleva su nombre, como el de verdad.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -keyout "$TMP/fx/cf/ca.key" -out "$TMP/fx/cf/ca.crt" \
  -subj "/O=CloudFlare, Inc./OU=CloudFlare Origin SSL ECC Certificate Authority/CN=prueba" >/dev/null 2>&1

curl() {
  printf '%s\n' "$*" >> "$CURL_ARGV"
  local cfg method="GET" out="" body=""
  cfg="$(cat)"; printf '%s\n' "$cfg" >> "$CURL_CFG"
  while (( $# )); do
    case "$1" in
      -X) method="$2"; shift ;;
      -o) out="$2"; shift ;;
      --data-binary) body="${2#@}"; shift ;;
    esac
    shift
  done
  local url path code=200 resp=""
  url="$(sed -n 's/^url = "\(.*\)"$/\1/p' <<<"$cfg")"
  path="${url#"$CF_API"}"
  # Como la de verdad: el token se lee de la configuración, no de argv.
  local tok; tok="$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p' <<<"$cfg")"
  [[ "$FAKE_VERIFY" == "offline" ]] && return 7
  # Un token de cuenta es válido en todo menos en /user/tokens/verify, que le
  # contesta exactamente lo mismo que a uno inventado: así es la API de verdad.
  if [[ "$tok" != "$FAKE_TOKEN" && ! ( "$tok" == "$FAKE_ACCOUNT_TOKEN" && "$path" != /user/tokens/verify ) ]]; then
    printf '{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}' > "$out"
    printf '401'; return 0
  fi
  case "$method $path" in
    "GET /zones?per_page=1")
      resp='{"success":true,"result":[{"id":"Z1","name":"tienda.test","account":{"id":"acc0123abcd","name":"x"}}]}' ;;
    "GET /accounts/acc0123abcd/tokens/verify")
      resp="{\"success\":true,\"result\":{\"id\":\"y\",\"status\":\"$FAKE_VERIFY\"}}" ;;
    "GET /user/tokens/verify")
      # Sin jq a propósito: la prueba de «sin jq» pasa por aquí.
      resp="{\"success\":true,\"result\":{\"id\":\"x\",\"status\":\"$FAKE_VERIFY\"}}" ;;
    "GET /zones?name="*)
      local id="${FAKE_ZONES[${path#/zones?name=}]:-}"
      if [[ -n "$id" ]]; then resp="{\"result\":[{\"id\":\"$id\"}]}"; else resp='{"result":[]}'; fi ;;
    "GET /zones/"*"/dns_records?name="*)
      local h="${path#*name=}"; h="${h%%&*}"
      case "${FAKE_PROXY[$h]:-none}" in
        none) resp='{"result":[]}' ;;
        *)    resp="{\"result\":[{\"type\":\"A\",\"name\":\"$h\",\"proxied\":${FAKE_PROXY[$h]}}]}" ;;
      esac ;;
    "POST /certificates")
      cp "$body" "$TMP/fx/cf/last-request.json"
      if [[ -n "$FAKE_DENY" ]]; then
        printf '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}' > "$out"
        printf '403'; return 0
      fi
      jq -r .csr "$body" > "$TMP/fx/cf/req.csr"
      local san; san="$(jq -r '[.hostnames[] | "DNS:" + .] | join(",")' "$body")"
      openssl x509 -req -in "$TMP/fx/cf/req.csr" -CA "$TMP/fx/cf/ca.crt" -CAkey "$TMP/fx/cf/ca.key" \
        -CAcreateserial -days "$(jq -r .requested_validity "$body")" \
        -extfile <(printf 'subjectAltName=%s\n' "$san") -out "$TMP/fx/cf/issued.pem" >/dev/null 2>&1
      resp="$(jq -cn --rawfile c "$TMP/fx/cf/issued.pem" '{success:true,result:{id:"cert-123",certificate:$c}}')" ;;
    *) code=404; resp='{"success":false}' ;;
  esac
  printf '%s' "$resp" > "$out"
  printf '%s' "$code"
}

cf_token_file() { printf 'dns_cloudflare_api_token = %s\n' "$FAKE_TOKEN" > "$ETC_DIR/cloudflare.ini"; chmod 0600 "$ETC_DIR/cloudflare.ini"; }

mode_of() { stat -c '%a' "$1" 2>/dev/null; }

# Una web estática con www: lo más sencillo que tiene vhost y dos nombres.
mkapp tienda static "" tienda.test "www.tienda.test"
load_app tienda; A_OUTDIR="."; save_app
mkdir -p "$TMP/apps/tienda/current" "$TMP/apps/tienda/shared"

# ═════════════════════════════════════════════════════════════════════════════
section "Los nombres del certificado, con un comodín dentro"
# Orbit corre con nullglob. 'for a in $A_ALIASES' convertía '*.tienda.test' en
# nada —no hay ficheros que se le parezcan— y la petición salía sin él.
mkapp comodin static "" comodin.test "*.comodin.test www.comodin.test"
load_app comodin
NAMES=(); _ssl_names NAMES
check "tres nombres"            "3" "${#NAMES[@]}"
check "el comodín sigue ahí"    "*.comodin.test" "${NAMES[1]}"
ARGS="$(_ssl_le_args dns ops@x.test | tr '\n' ' ')"
check "y llega a certbot"       "1" "$(grep -c -- '-d \*\.comodin\.test ' <<<"$ARGS")"
check "por DNS, el token"       "1" "$(grep -c -- "--dns-cloudflare-credentials $ETC_DIR/cloudflare.ini" <<<"$ARGS")"
check "y 30 s de propagación"   "1" "$(grep -c -- '--dns-cloudflare-propagation-seconds 30' <<<"$ARGS")"
check "clave ECDSA"             "1" "$(grep -c -- '--key-type ecdsa --cert-name comodin.test' <<<"$ARGS")"
ARGS="$(_ssl_le_args webroot "" | tr '\n' ' ')"
check "por HTTP, la carpeta"    "1" "$(grep -c -- "--webroot -w $ACME_DIR" <<<"$ARGS")"
check "sin correo, sin -m"      "1" "$(grep -c -- '--register-unsafely-without-email' <<<"$ARGS")"
# Y el que reparte dominios entre apps tenía el mismo agujero.
check "el comodín tiene dueño"  "comodin" "$(domain_owner '*.comodin.test')"

section "Un comodín por HTTP no llega a certbot"
: > "$CERTBOT_LOG"; rm -f "$ETC_DIR/cloudflare.ini"
LETSENCRYPT_EMAIL="ops@tienda.test"
OUT="$(run cmd_ssl comodin </dev/null 2>&1)"; r=$?
check "se niega"                "1" "$r"
check "y dice por qué"          "1" "$(grep -c 'sólo emite comodines validando por DNS' <<<"$OUT")"
check "certbot ni se entera"    "0" "$(wc -l < "$CERTBOT_LOG")"
run cmd_remove comodin -y --purge >/dev/null 2>&1

# ═════════════════════════════════════════════════════════════════════════════
section "Let's Encrypt por DNS"
cf_token_file; : > "$CERTBOT_LOG"
OUT="$(run cmd_ssl tienda </dev/null 2>&1)"; r=$?
check "sale bien"               "0" "$r"
check "certonly por DNS"        "1" "$(grep -c '^certonly --dns-cloudflare ' "$CERTBOT_LOG")"
check "con los dos nombres"     "1" "$(grep -c -- '-d tienda.test -d www.tienda.test ' "$CERTBOT_LOG")"
check "el vhost sirve HTTPS"    "1" "$(grep -c "ssl_certificate .*$TMP/le/live/tienda.test/fullchain.pem;" "$(nginx_file tienda)")"
load_app tienda
check "tipo letsencrypt"        "letsencrypt" "$(app_cert_type)"

section "El cartel de python-cloudflare no sale, lo demás sí"
BANNER='/usr/lib/python3/dist-packages/certbot_dns_cloudflare/_internal/dns_cloudflare.py:108: PendingDeprecationWarning:
       !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!   WARNING  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       !! You'"'"'re seeing this warning because you'"'"'ve upgraded the Python package '"'"'cloudflare'"'"' to version  !!
       !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  self.cf = CloudFlare.CloudFlare(token=api_token)
Waiting 30 seconds for DNS changes to propagate
Some challenges have failed.'
FILTERED="$(_certbot_quiet <<<"$BANNER")"
check "sin exclamaciones"       "0" "$(grep -c '!!' <<<"$FILTERED")"
check "sin el aviso"            "0" "$(grep -c 'PendingDeprecation' <<<"$FILTERED")"
check "el resto, entero"        "2" "$(wc -l <<<"$FILTERED")"
check "y el error de verdad"    "1" "$(grep -c 'Some challenges have failed' <<<"$FILTERED")"

# ═════════════════════════════════════════════════════════════════════════════
section "La prueba de renovación"
: > "$CERTBOT_LOG"
VH_BEFORE="$(md5sum < "$(nginx_file tienda)")"
OUT="$(run cmd_ssl tienda --dry-run </dev/null 2>&1)"; r=$?
check "sale bien"               "0" "$r"
# Con certificado se prueba lo que hará el temporizador: 'renew' con lo que
# certbot tiene guardado, no una emisión nueva con lo que diga la app hoy.
check "renew, no certonly"      "1" "$(grep -c '^renew --cert-name tienda.test --dry-run ' "$CERTBOT_LOG")"
# Sin esto, certbot sin terminal espera hasta 8 minutos al azar antes de
# empezar: 338 s en la primera prueba de verdad, sin decir nada.
check "sin la espera al azar"   "1" "$(grep -c -- '--no-random-sleep-on-renew' "$CERTBOT_LOG")"
check "dice por qué renovará"   "1" "$(grep -c 'certbot renovará por: dns-cloudflare' <<<"$OUT")"
check "el vhost, sin tocar"     "$VH_BEFORE" "$(md5sum < "$(nginx_file tienda)")"

section "La prueba avisa de un alias que el certificado no cubre"
load_app tienda; A_ALIASES="www.tienda.test tienda2.test"; save_app
OUT="$(run cmd_ssl tienda --dry-run </dev/null 2>&1)"
check "lo dice"                 "1" "$(grep -c 'no cubre tienda2.test' <<<"$OUT")"
load_app tienda; A_ALIASES="www.tienda.test"; save_app

section "Si certbot falla, la prueba falla"
CERTBOT_FAIL="yes"
OUT="$(run cmd_ssl tienda --dry-run </dev/null 2>&1)"; r=$?
CERTBOT_FAIL=""
check "sale con 1"              "1" "$r"
check "y lo dice"               "1" "$(grep -c 'así fallará también la renovación' <<<"$OUT")"

section "Con certificado y sin configuración de renovación, la prueba falla"
mv "$LE_RENEWAL_DIR/tienda.test.conf" "$TMP/conf.aparte"
: > "$CERTBOT_LOG"
OUT="$(run cmd_ssl tienda --dry-run </dev/null 2>&1)"; r=$?
mv "$TMP/conf.aparte" "$LE_RENEWAL_DIR/tienda.test.conf"
# Probar una emisión nueva saldría bien y diría lo contrario de lo que va a
# pasar dentro de sesenta días.
check "sale con 1"              "1" "$r"
check "sin probar otra cosa"    "0" "$(wc -l < "$CERTBOT_LOG")"
check "dice por qué"            "1" "$(grep -c 'no tiene configuración para renovarlo' <<<"$OUT")"

section "Sin certificado, la prueba es de la emisión, y no escribe nada"
mkapp nueva static "" nueva.test
: > "$CERTBOT_LOG"; unset LETSENCRYPT_EMAIL
CONF_BEFORE="$(md5sum < "$CONF_FILE")"
OUT="$(run cmd_ssl nueva --dry-run </dev/null 2>&1)"; r=$?
check "sale bien"               "0" "$r"
check "certonly --dry-run"      "1" "$(grep -c '^certonly --dns-cloudflare .* --dry-run$' "$CERTBOT_LOG")"
# Los mismos argumentos que la emisión, más '--dry-run': si se separaran, la
# prueba saldría bien sobre una invocación que ya no existe.
load_app nueva
check "los de la emisión"       "certonly $(_ssl_le_args dns "" | tr '\n' ' ')--dry-run" "$(cat "$CERTBOT_LOG")"
check "sin preguntar el correo" "$CONF_BEFORE" "$(md5sum < "$CONF_FILE")"
check "y sin vhost"             "no" "$([[ -f "$(nginx_file nueva)" ]] && echo si || echo no)"
LETSENCRYPT_EMAIL="ops@tienda.test"

# ═════════════════════════════════════════════════════════════════════════════
section "Lo que hará fallar la renovación, sin salir de la máquina"
check "bien configurada"        "" "$(_le_renewal_problem tienda.test)"
printf '[renewalparams]\nauthenticator = dns-cloudflare\ndns_cloudflare_credentials = %s\n' "$TMP/no-existe.ini" \
  > "$LE_RENEWAL_DIR/roto.test.conf"
check "el token ya no está"     "1" "$(_le_renewal_problem roto.test | grep -c 'no-existe.ini, y ese fichero no existe')"
printf 'otra_cosa = 1\n' > "$TMP/vacio.ini"
printf '[renewalparams]\nauthenticator = dns-cloudflare\ndns_cloudflare_credentials = %s\n' "$TMP/vacio.ini" \
  > "$LE_RENEWAL_DIR/roto.test.conf"
check "el fichero sin token"    "1" "$(_le_renewal_problem roto.test | grep -c 'no lleva ningún token')"
printf '[renewalparams]\nauthenticator = webroot\nwebroot_path = %s/no-acme,\n' "$TMP" \
  > "$LE_RENEWAL_DIR/roto.test.conf"
check "la carpeta del reto"     "1" "$(_le_renewal_problem roto.test | grep -c 'no-acme, y esa carpeta no existe')"
check "sin configuración"       "1" "$(_le_renewal_problem nadie.test | grep -c 'no tiene configuración para renovarlo')"
# Y doctor lo cuenta, con la orden que lo comprueba de verdad.
printf '[renewalparams]\nauthenticator = dns-cloudflare\ndns_cloudflare_credentials = %s\n' "$TMP/no-existe.ini" \
  > "$LE_RENEWAL_DIR/tienda.test.conf"
DOC_LEVEL=(); DOC_ID=(); DOC_MSG=(); DOC_FIX=(); DOC_ACT=()
load_app tienda; _doctor_cert tienda ""
check "doctor lo ve"            "1" "$(printf '%s\n' "${DOC_ID[@]}" | grep -c '^renew:tienda.test$')"
check "y manda al dry-run"      "1" "$(printf '%s\n' "${DOC_FIX[@]}" | grep -c 'orbit ssl tienda --dry-run')"
printf '[renewalparams]\nauthenticator = dns-cloudflare\ndns_cloudflare_credentials = %s\n' "$ETC_DIR/cloudflare.ini" \
  > "$LE_RENEWAL_DIR/tienda.test.conf"

# ═════════════════════════════════════════════════════════════════════════════
section "Certificado de origen: un nombre fuera del proxy lo para todo"
FAKE_PROXY[www.tienda.test]="false"
: > "$CURL_ARGV"; : > "$CERTBOT_LOG"
VH_BEFORE="$(md5sum < "$(nginx_file tienda)")"
OUT="$(run cmd_ssl tienda --origin </dev/null 2>&1)"; r=$?
check "se niega"                "1" "$r"
check "dice cuál"               "1" "$(grep -c 'www.tienda.test NO pasa por el proxy' <<<"$OUT")"
check "sin pedir nada"          "0" "$(grep -c -- '-X POST' "$CURL_ARGV")"
check "sin instalar nada"       "no" "$([[ -d "$(origin_dir tienda)" ]] && echo si || echo no)"
check "el vhost, igual"         "$VH_BEFORE" "$(md5sum < "$(nginx_file tienda)")"
FAKE_PROXY[www.tienda.test]="none"
OUT="$(run cmd_ssl tienda --origin </dev/null 2>&1)"; r=$?
check "sin registro, tampoco"   "1" "$r"
FAKE_PROXY[www.tienda.test]="true"

section "Certificado de origen: el token sin permiso"
FAKE_DENY="yes"
OUT="$(run cmd_ssl tienda --origin </dev/null 2>&1)"; r=$?
FAKE_DENY=""
check "se niega"                "1" "$r"
check "dice qué permiso falta"  "1" "$(grep -c 'Zone → SSL and Certificates → Edit' <<<"$OUT")"
check "y lo que dijo Cloudflare" "1" "$(grep -c '10000: Authentication error' <<<"$OUT")"
check "sin instalar nada"       "no" "$([[ -d "$(origin_dir tienda)" ]] && echo si || echo no)"
# La clave privada que se generó para la petición no puede quedarse en disco.
check "y sin restos de la clave" "0" "$(find "$ORIGIN_CERT_DIR" -name key.pem 2>/dev/null | wc -l)"

section "Certificado de origen: si nginx lo rechaza, Let's Encrypt sigue ahí"
: > "$CERTBOT_LOG"; NGINX_FAIL="yes"
OUT="$(run cmd_ssl tienda --origin </dev/null 2>&1)"; r=$?
NGINX_FAIL=""
check "sale con 1"              "1" "$r"
check "certbot no borra nada"   "0" "$(grep -c '^delete' "$CERTBOT_LOG")"
check "el de LE, en su sitio"   "yes" "$([[ -f "$(cert_file tienda.test)" && -f "$LE_RENEWAL_DIR/tienda.test.conf" ]] && echo yes)"
check "sin carpeta de origen"   "no" "$([[ -d "$(origin_dir tienda)" ]] && echo si || echo no)"
check "el vhost sigue en LE"    "1" "$(grep -c "ssl_certificate_key $TMP/le/live/tienda.test/privkey.pem;" "$(nginx_file tienda)")"

section "Certificado de origen: Let's Encrypt sólo se borra si el vhost ya no lo usa"
# Si por lo que sea el vhost aceptado siguiera leyendo la clave de Let's
# Encrypt —una carpeta que no se pudo mover con errexit apagado, por ejemplo—,
# borrarla dejaría a nginx sin arrancar en la próxima recarga.
eval "$(declare -f render_nginx | sed '1s/^render_nginx/_real_render_nginx/')"
render_nginx() { has_origin() { return 1; }; _real_render_nginx "$@"; local rc=$?; unset -f has_origin; eval "$HAS_ORIGIN_DEF"; return $rc; }
HAS_ORIGIN_DEF="$(declare -f has_origin)"
: > "$CERTBOT_LOG"
run cmd_ssl tienda --origin </dev/null >/dev/null 2>&1
check "no borra Let's Encrypt"  "0" "$(grep -c '^delete' "$CERTBOT_LOG")"
check "que sigue en su sitio"   "yes" "$([[ -f "$(cert_file tienda.test)" ]] && echo yes)"
eval "$(declare -f _real_render_nginx | sed '1s/^_real_render_nginx/render_nginx/')"
eval "$HAS_ORIGIN_DEF"
rm -rf "$(origin_dir tienda)"; run render_nginx tienda >/dev/null 2>&1

section "Certificado de origen: pedido a la API"
# Lo que dejó un intento cortado de golpe, con su clave dentro.
mkdir -p "$ORIGIN_CERT_DIR/.tienda.nuevo.viejo"; : > "$ORIGIN_CERT_DIR/.tienda.nuevo.viejo/key.pem"
: > "$CURL_ARGV"; : > "$CURL_CFG"; : > "$CERTBOT_LOG"
OUT="$(run cmd_ssl tienda --origin </dev/null 2>&1)"; r=$?
check "sale bien"               "0" "$r"
REQ="$TMP/fx/cf/last-request.json"
check "15 años"                 "5475" "$(jq -r .requested_validity "$REQ")"
check "ECC por defecto"         "origin-ecc" "$(jq -r .request_type "$REQ")"
check "los dos nombres"         "tienda.test www.tienda.test" "$(jq -r '.hostnames | join(" ")' "$REQ")"
# A Cloudflare va la petición firmada, nunca la clave.
check "manda un CSR"            "1" "$(jq -r .csr "$REQ" | grep -c 'BEGIN CERTIFICATE REQUEST')"
check "y no la clave"           "0" "$(grep -c 'PRIVATE KEY' "$REQ")"
check "el token, por -K"        "yes" "$(grep -q "^header = \"Authorization: Bearer $FAKE_TOKEN\"$" "$CURL_CFG" && echo yes)"
check "y nunca en argv"         "0" "$(grep -c "$FAKE_TOKEN" "$CURL_ARGV")"
check "cert en su sitio"        "yes" "$(has_origin tienda && echo yes)"
check "y los restos, fuera"     "no" "$([[ -d "$ORIGIN_CERT_DIR/.tienda.nuevo.viejo" ]] && echo si || echo no)"
check "carpeta 0700"            "700" "$(mode_of "$(origin_dir tienda)")"
check "clave 0600"              "600" "$(mode_of "$(origin_key tienda)")"
check "casan"                   "0" "$(_cert_key_match "$(origin_cert tienda)" "$(origin_key tienda)"; echo $?)"
check "el vhost la usa"         "1" "$(grep -c "ssl_certificate_key $ORIGIN_CERT_DIR/tienda/key.pem;" "$(nginx_file tienda)")"
check "origin.info legible"     "1" "$(grep -c '^cloudflare_id=cert-123$' "$(origin_dir tienda)/origin.info")"
# El Let's Encrypt de antes ya no lo sirve nadie: si se quedara, certbot lo
# renovaría para nada y el día que la validación falle, el temporizador también.
check "retira Let's Encrypt"    "1" "$(grep -c '^delete --cert-name tienda.test --non-interactive$' "$CERTBOT_LOG")"
check "certbot ya no lo tiene"  "no" "$([[ -f "$LE_RENEWAL_DIR/tienda.test.conf" ]] && echo si || echo no)"
load_app tienda
check "tipo origin"             "origin" "$(app_cert_type)"
DAYS="$(app_cert_days)"
check "unos 15 años"            "yes" "$( (( DAYS > 5400 )) && echo yes)"

section "Lo que se ve del certificado de origen"
check "list/info --json"        "origin" "$(_app_state_json --cert-days | jq -r .cert_type)"
# Por rango y no por igualdad: entre una lectura y otra puede pasar el segundo
# que convierte 5475 días en 5474,99.
JD="$(_app_state_json --cert-days | jq -r .cert_days)"
check "con sus días"            "yes" "$( (( JD > 5400 && JD <= 5475 )) && echo yes)"
OUT="$(cmd_info tienda 2>&1)"
check "orbit info"              "1" "$(grep -c 'HTTPS *origen de Cloudflare' <<<"$OUT")"
_watch_warn() { printf '%s|%s\n' "$1" "$4" >> "$TMP/watch.log"; }
: > "$TMP/watch.log"; WATCH_CERT_DAYS=99999 _watch_certs
check "el vigilante, a --origin" "1" "$(grep -c "^cert:tienda.test|.*'orbit ssl tienda --origin'" "$TMP/watch.log")"

section "Qué nombres cubre un certificado"
selfsigned "$TMP/fx/wild.crt" "$TMP/fx/wild.key" 2 comodin.test '*.comodin.test'
check "el exacto"               "0" "$(_cert_covers "$TMP/fx/wild.crt" comodin.test; echo $?)"
check "una etiqueta, sí"        "0" "$(_cert_covers "$TMP/fx/wild.crt" a.comodin.test; echo $?)"
check "en mayúsculas, también"  "0" "$(_cert_covers "$TMP/fx/wild.crt" A.Comodin.Test; echo $?)"
check "dos etiquetas, no"       "1" "$(_cert_covers "$TMP/fx/wild.crt" a.b.comodin.test; echo $?)"
check "otro dominio, no"        "1" "$(_cert_covers "$TMP/fx/wild.crt" a.otro.test; echo $?)"
check "el comodín, a sí mismo"  "0" "$(_cert_covers "$TMP/fx/wild.crt" '*.comodin.test'; echo $?)"
selfsigned "$TMP/fx/solo.crt" "$TMP/fx/solo.key" 2 solo.comodin.test
check "sin comodín, no cubre al hermano" "1" "$(_cert_covers "$TMP/fx/solo.crt" otro.comodin.test; echo $?)"

section "doctor: un certificado de origen sin el proxy delante"
printf 'set_real_ip_from 104.16.0.0/13;\nset_real_ip_from 172.64.0.0/13;\nset_real_ip_from 2400:cb00::/32;\n' > "$TMP/cf-ips.conf"
CF_REALIP_CONF="$TMP/cf-ips.conf"
check "104.17.1.1 es suya"      "0" "$(_ip4_in_cf 104.17.1.1; echo $?)"
check "172.71.255.255 también"  "0" "$(_ip4_in_cf 172.71.255.255; echo $?)"
check "172.72.0.0 ya no"        "1" "$(_ip4_in_cf 172.72.0.0; echo $?)"
check "203.0.113.5 no"          "1" "$(_ip4_in_cf 203.0.113.5; echo $?)"
DOC_LEVEL=(); DOC_ID=(); DOC_MSG=(); DOC_FIX=(); DOC_ACT=()
load_app tienda; _doctor_cert tienda 203.0.113.5
check "lo acusa como error"     "error" "$(for i in "${!DOC_ID[@]}"; do [[ "${DOC_ID[$i]}" == origin-proxy:tienda.test ]] && echo "${DOC_LEVEL[$i]}"; done)"
DOC_LEVEL=(); DOC_ID=(); DOC_MSG=(); DOC_FIX=(); DOC_ACT=()
_doctor_cert tienda 104.17.1.1
check "detrás del proxy, nada"  "0" "$(printf '%s\n' "${DOC_ID[@]}" | grep -c '^origin-proxy:')"
DOC_LEVEL=(); DOC_ID=(); DOC_MSG=(); DOC_FIX=(); DOC_ACT=()
_doctor_cert tienda "tienda.cdn.test."
check "un CNAME no acusa"       "0" "$(printf '%s\n' "${DOC_ID[@]}" | grep -c '^origin-proxy:')"
check "ni pide renovar con LE"  "0" "$(printf '%s\n' "${DOC_ID[@]}" | grep -c '^renew:')"
check "cubre sus nombres"       "0" "$(printf '%s\n' "${DOC_ID[@]}" | grep -c '^origin-names:')"
# Un alias añadido sin pedir otro: Cloudflare en Full (strict) da 526.
load_app tienda; A_ALIASES="www.tienda.test nuevo.tienda.test"
DOC_LEVEL=(); DOC_ID=(); DOC_MSG=(); DOC_FIX=(); DOC_ACT=()
_doctor_cert tienda 104.17.1.1
check "el alias nuevo, error"   "1" "$(printf '%s\n' "${DOC_MSG[@]}" | grep -c 'no cubre nuevo.tienda.test')"
load_app tienda

section "Si nginx lo rechaza, se queda el de antes"
BEFORE="$(md5sum < "$(origin_cert tienda)")"
NGINX_FAIL="yes"
OUT="$(run cmd_ssl tienda --origin </dev/null 2>&1)"; r=$?
NGINX_FAIL=""
check "sale con 1"              "1" "$r"
check "el certificado anterior" "$BEFORE" "$(md5sum < "$(origin_cert tienda)")"
check "y su clave casa"         "0" "$(_cert_key_match "$(origin_cert tienda)" "$(origin_key tienda)"; echo $?)"
check "sin carpetas a medias"   "0" "$(find "$ORIGIN_CERT_DIR" -mindepth 1 -maxdepth 1 -name '.*' | wc -l)"

section "La copia de seguridad lleva el certificado de origen"
_db_exists() { return 1; }
BACKUP_DIR="$TMP/backups"
BK="$(_backup_one tienda)"
check "dentro va la clave"      "1" "$(tar tzf "$BK" | grep -c '^\./tls/key\.pem$')"
check "y sigue siendo 0600"     "1" "$(tar tvzf "$BK" | grep -c -- '^-rw------- .* \./tls/key\.pem$')"
check "el manifiesto lo dice"   "1" "$(tar xzOf "$BK" ./manifest | grep -c '^certificado_origen=si$')"
_verify_one "$BK"; check "verify la da por buena" "0" "$?"
# Una copia que dice llevarlo y no lo lleva es una copia rota.
mkdir -p "$TMP/bk-roto"; tar xzf "$BK" -C "$TMP/bk-roto"; rm -rf "$TMP/bk-roto/tls"
tar czf "$TMP/roto.tar.gz" -C "$TMP/bk-roto" .
_verify_one "$TMP/roto.tar.gz"; r=$?
check "sin tls/, rota"          "1" "$r"
check "y dice qué falta"        "1" "$(grep -c 'certificado de origen' <<<"$VERIFY_MSG")"
CERT_SUM="$(md5sum < "$(origin_cert tienda)")"
rm -rf "$(origin_dir tienda)"
run _restore_one "$BK" --sin-siguiente-paso >/dev/null 2>&1
check "restaurado"              "$CERT_SUM" "$(md5sum < "$(origin_cert tienda)")"
check "clave 0600"              "600" "$(mode_of "$(origin_key tienda)")"
check "carpeta 0700"            "700" "$(mode_of "$(origin_dir tienda)")"
# Una clave que no casa con su certificado dejaría a nginx sin arrancar en el
# despliegue siguiente: no se restaura.
mkdir -p "$TMP/bk-mal"; tar xzf "$BK" -C "$TMP/bk-mal"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TMP/bk-mal/tls/key.pem" 2>/dev/null
tar czf "$TMP/mal.tar.gz" -C "$TMP/bk-mal" .
rm -rf "$(origin_dir tienda)"
OUT="$(run _restore_one "$TMP/mal.tar.gz" --sin-siguiente-paso 2>&1)"
check "la que no casa, no"      "no" "$(has_origin tienda && echo si || echo no)"
check "y lo dice"               "1" "$(grep -c 'no casa con su clave' <<<"$OUT")"
run _restore_one "$BK" --sin-siguiente-paso >/dev/null 2>&1

section "Subir uno hecho en el panel"
selfsigned "$TMP/fx/up.crt" "$TMP/fx/up.key" 5475 tienda.test www.tienda.test
selfsigned "$TMP/fx/otro.crt" "$TMP/fx/otro.key" 5475 tienda.test www.tienda.test
selfsigned "$TMP/fx/corto.crt" "$TMP/fx/corto.key" 5475 tienda.test
: > "$CURL_ARGV"
OUT="$(run cmd_ssl tienda --origin-cert "$TMP/fx/up.crt" --origin-key "$TMP/fx/otro.key" </dev/null 2>&1)"; r=$?
check "sin pareja, no"          "1" "$r"
check "lo dice"                 "1" "$(grep -c 'no son pareja' <<<"$OUT")"
OUT="$(run cmd_ssl tienda --origin-cert "$TMP/fx/corto.crt" --origin-key "$TMP/fx/corto.key" </dev/null 2>&1)"; r=$?
check "sin www, no"             "1" "$r"
check "dice cuál falta"         "1" "$(grep -c 'no cubre www.tienda.test' <<<"$OUT")"
OUT="$(run cmd_ssl tienda --origin-cert "$TMP/fx/up.crt" --origin-key "$TMP/fx/up.key" </dev/null 2>&1)"; r=$?
check "con su clave, sí"        "0" "$r"
check "instalado"               "$(md5sum < "$TMP/fx/up.crt")" "$(md5sum < "$(origin_cert tienda)")"
check "avisa de quién lo firma" "1" "$(grep -c 'No lo ha firmado Cloudflare' <<<"$OUT")"
check "y no pide nada a nadie"  "0" "$(grep -c -- '-X POST' "$CURL_ARGV")"
check "solo una de las dos"     "1" "$(run cmd_ssl tienda --origin-cert "$TMP/fx/up.crt" </dev/null >/dev/null 2>&1; echo $?)"

section "Una app llamada «tienda.anterior» no pierde lo suyo"
# Los puntos valen en un nombre de app. Con 'tienda.anterior' como carpeta
# apartada, pedir otro para 'tienda' borraba el certificado de la vecina.
mkapp tienda.anterior static "" vecina.test
mkdir -p "$(origin_dir tienda.anterior)"; printf 'de la vecina\n' > "$(origin_dir tienda.anterior)/cert.pem"
run cmd_ssl tienda --origin-cert "$TMP/fx/up.crt" --origin-key "$TMP/fx/up.key" </dev/null >/dev/null 2>&1
check "la vecina, intacta"      "de la vecina" "$(cat "$(origin_dir tienda.anterior)/cert.pem" 2>/dev/null)"
rm -rf "$(origin_dir tienda.anterior)"; rm -f "$(app_conf tienda.anterior)"

section "Volver a Let's Encrypt, y que nginx lo rechace"
NGINX_FAIL="yes"; : > "$CERTBOT_LOG"
OUT="$(run cmd_ssl tienda </dev/null 2>&1)"; r=$?
NGINX_FAIL=""
check "sale con 1"              "1" "$r"
check "el de origen, en su sitio" "yes" "$(has_origin tienda && echo yes)"
check "y casa"                  "0" "$(_cert_key_match "$(origin_cert tienda)" "$(origin_key tienda)"; echo $?)"
check "sin carpetas apartadas"  "0" "$(find "$ORIGIN_CERT_DIR" -mindepth 1 -maxdepth 1 -name '.*' | wc -l)"

section "Volver a Let's Encrypt"
: > "$CERTBOT_LOG"
OUT="$(run cmd_ssl tienda </dev/null 2>&1)"; r=$?
check "sale bien"               "0" "$r"
check "pregunta antes"          "1" "$(grep -c '¿Cambiarlo por uno de Let' <<<"$OUT")"
check "emite con certbot"       "1" "$(grep -c '^certonly ' "$CERTBOT_LOG")"
check "retira el de origen"     "no" "$([[ -d "$(origin_dir tienda)" ]] && echo si || echo no)"
check "el vhost vuelve a LE"    "1" "$(grep -c "ssl_certificate .*$TMP/le/live/tienda.test/fullchain.pem;" "$(nginx_file tienda)")"
load_app tienda
check "tipo letsencrypt"        "letsencrypt" "$(app_cert_type)"
# Y contestar que no lo deja todo como estaba.
run _restore_one "$BK" --sin-siguiente-paso >/dev/null 2>&1
: > "$CERTBOT_LOG"
OUT="$(printf 'n\n' | run cmd_ssl tienda 2>&1)"; r=$?
check "con un no, nada"         "0" "$(wc -l < "$CERTBOT_LOG")"
check "y sigue el de origen"    "yes" "$(has_origin tienda && echo yes)"

section "Cambiar los dominios pide otro de origen, no uno de Let's Encrypt"
eval "$(declare -f cmd_ssl | sed '1s/^cmd_ssl/_real_cmd_ssl/')"
# Por eval y no con 'cmd_ssl() {…}' a pelo: shellcheck ve esa definición y da
# por no definidas todas las llamadas de antes en el fichero (SC2218).
_stub_cmd_ssl() { printf 'ssl %s\n' "$*" >> "$TMP/ssl.calls"; }
eval "$(declare -f _stub_cmd_ssl | sed '1s/^_stub_cmd_ssl/cmd_ssl/')"
: > "$TMP/ssl.calls"
printf '\n\ns\n' | cmd_domain tienda >/dev/null 2>&1
check "orbit ssl --origin"      "ssl tienda --origin" "$(cat "$TMP/ssl.calls")"
eval "$(declare -f _real_cmd_ssl | sed '1s/^_real_cmd_ssl/cmd_ssl/')"

section "orbit remove sin --purge lo aparta"
# Va por nombre de app: si se quedara, una app nueva con el mismo nombre y otro
# dominio lo serviría al instante, sin cubrir sus nombres.
cp "$(app_conf tienda)" "$TMP/tienda.conf.bak"
CERT_SUM="$(md5sum < "$(origin_cert tienda)")"
run cmd_remove tienda -y >/dev/null 2>&1
check "ya no es de nadie"       "no" "$(has_origin tienda && echo si || echo no)"
APARTADO="$(find "$ORIGIN_CERT_DIR" -mindepth 1 -maxdepth 1 -name '.tienda.eliminada.*' | head -1)"
check "pero sigue en disco"     "$CERT_SUM" "$(md5sum < "$APARTADO/cert.pem")"
rm -rf "$APARTADO"
cp "$TMP/tienda.conf.bak" "$(app_conf tienda)"
run _restore_one "$BK" --sin-siguiente-paso >/dev/null 2>&1
mkdir -p "$TMP/apps/tienda/current" "$TMP/apps/tienda/shared"

section "orbit remove --purge se lleva la clave"
run cmd_remove tienda -y --purge >/dev/null 2>&1
check "sin carpeta"             "no" "$([[ -d "$(origin_dir tienda)" ]] && echo si || echo no)"

# ═════════════════════════════════════════════════════════════════════════════
section "orbit cf-token comprueba el token antes de guardarlo"
rm -f "$ETC_DIR/cloudflare.ini"; : > "$CURL_ARGV"
FAKE_VERIFY="active"
OUT="$(printf '%s\n' "$FAKE_TOKEN" | run cmd_cf_token 2>&1)"; r=$?
check "activo: sale bien"       "0" "$r"
check "guardado"                "dns_cloudflare_api_token = $FAKE_TOKEN" "$(cat "$ETC_DIR/cloudflare.ini")"
check "0600"                    "600" "$(mode_of "$ETC_DIR/cloudflare.ini")"
check "nunca en argv"           "0" "$(grep -c "$FAKE_TOKEN" "$CURL_ARGV")"
check "sin temporales"          "0" "$(find "$ETC_DIR" -name '.cloudflare.ini.*' | wc -l)"
# Un token que Cloudflare no reconoce no se guarda, y el que había se queda.
OUT="$(printf 'otro-token-que-no-vale\n' | run cmd_cf_token 2>&1)"; r=$?
check "inválido: no"            "1" "$r"
check "el de antes sigue"       "dns_cloudflare_api_token = $FAKE_TOKEN" "$(cat "$ETC_DIR/cloudflare.ini")"
check "sin temporales"          "0" "$(find "$ETC_DIR" -name '.cloudflare.ini.*' | wc -l)"
FAKE_VERIFY="disabled"
OUT="$(printf '%s\n' "$FAKE_TOKEN" | run cmd_cf_token 2>&1)"; r=$?
check "desactivado: no"         "1" "$r"
check "y dice cómo está"        "1" "$(grep -c 'disabled' <<<"$OUT")"
# Sin red se guarda igual —no poder preguntar no es un «no»—, pero se dice.
FAKE_VERIFY="offline"; rm -f "$ETC_DIR/cloudflare.ini"
OUT="$(printf '%s\n' "$FAKE_TOKEN" | run cmd_cf_token 2>&1)"; r=$?
check "sin red: se guarda"      "0" "$r"
check "pero lo avisa"           "1" "$(grep -c 'No he podido preguntarle a Cloudflare' <<<"$OUT")"
FAKE_VERIFY="active"
# Un token de cuenta ('cfat_…'): /user/tokens/verify le dice «Invalid API
# Token», como a uno inventado, y Orbit lo rechazaba siendo bueno. Medido
# contra la API real con uno de verdad.
rm -f "$ETC_DIR/cloudflare.ini"; : > "$CURL_ARGV"; : > "$CURL_CFG"
OUT="$(printf '%s\n' "$FAKE_ACCOUNT_TOKEN" | run cmd_cf_token 2>&1)"; r=$?
check "de cuenta: se guarda"    "0" "$r"
check "y lo da por activo"      "1" "$(grep -c 'reconoce el token y está activo' <<<"$OUT")"
check "verificado en la cuenta" "1" "$(grep -c 'accounts/acc0123abcd/tokens/verify' "$CURL_CFG")"
check "nunca en argv"           "0" "$(grep -c "$FAKE_ACCOUNT_TOKEN" "$CURL_ARGV")"
FAKE_VERIFY="disabled"
OUT="$(printf '%s\n' "$FAKE_ACCOUNT_TOKEN" | run cmd_cf_token 2>&1)"; r=$?
check "de cuenta, desactivado: no" "1" "$r"
check "y dice cómo está"        "1" "$(grep -c 'disabled' <<<"$OUT")"
FAKE_VERIFY="active"
# Uno inventado sigue sin pasar aunque se pruebe la segunda puerta: la lista
# de zonas también le contesta 401.
OUT="$(printf 'cfat_inventado\n' | run cmd_cf_token 2>&1)"; r=$?
check "inventado con cfat_: no" "1" "$r"
rm -f "$ETC_DIR/cloudflare.ini"
OUT="$(printf 'con espacio dentro\n' | run cmd_cf_token 2>&1)"; r=$?
check "con espacios, no"        "1" "$r"
# jq es opcional en el resto de Orbit: sin él, un token bueno se rechazaba con
# «HTTP 200». Un PATH con todo menos jq.
mkdir -p "$TMP/nojq"
for b in /usr/local/bin/* /usr/bin/* /bin/*; do
  n="${b##*/}"; [[ "$n" == jq || -e "$TMP/nojq/$n" || -L "$TMP/nojq/$n" ]] || ln -s "$b" "$TMP/nojq/$n" 2>/dev/null
done
rm -f "$ETC_DIR/cloudflare.ini"
OUT="$(printf '%s\n' "$FAKE_TOKEN" | PATH="$TMP/nojq:/usr/sbin:/sbin" run cmd_cf_token 2>&1)"; r=$?
check "sin jq: se guarda"       "0" "$r"
check "y lo da por activo"      "1" "$(grep -c 'reconoce el token y está activo' <<<"$OUT")"
FAKE_VERIFY="disabled"
OUT="$(printf '%s\n' "$FAKE_TOKEN" | PATH="$TMP/nojq:/usr/sbin:/sbin" run cmd_cf_token 2>&1)"; r=$?
check "sin jq, desactivado: no" "1" "$r"
FAKE_VERIFY="active"
OUT="$(printf '%s\n' "$FAKE_ACCOUNT_TOKEN" | PATH="$TMP/nojq:/usr/sbin:/sbin" run cmd_cf_token 2>&1)"; r=$?
check "sin jq, de cuenta: sí"   "0" "$r"
FAKE_VERIFY="active"
# Y pedir un certificado de origen sin jq se niega antes de generar la clave,
# con la orden que lo arregla, en vez de morir a mitad con un código a pelo.
mkapp sinjq static "" tienda.test
OUT="$(PATH="$TMP/nojq:/usr/sbin:/sbin" run cmd_ssl sinjq --origin </dev/null 2>&1)"; r=$?
check "origen sin jq: no"       "1" "$r"
check "y dice qué instalar"     "1" "$(grep -c 'apt-get install -y jq' <<<"$OUT")"
check "sin clave a medias"      "0" "$(find "$ORIGIN_CERT_DIR" -name key.pem 2>/dev/null | wc -l)"

report
