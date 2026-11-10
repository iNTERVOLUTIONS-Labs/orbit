#!/usr/bin/env bash
# orbit cf-purge: vaciar la caché de Cloudflare de una app tras desplegar.
#   bash tests/cfpurge_test.sh
#
# Salió de poner una regla de caché de HTML en Cloudflare para las webs
# estáticas de un servidor de verdad: desde entonces, cada despliegue tardaba
# hasta diez minutos en verse. Lo que se fija aquí: que sólo se vacía lo de la
# app (purga por host, agrupada por zona), que el token de purga manda sobre el
# de DNS, y que un fallo de Cloudflare **nunca** tumba el despliegue.
#
# shellcheck disable=SC2034  # variables que lee el 'orbit' cargado por lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
CONF_FILE="$TMP/etc/orbit.conf"

# La API, doblada: apunta método, ruta, cuerpo y con qué fichero de token.
API_LOG="$TMP/api.log"; : > "$API_LOG"
API_CODE=200
_cf_api() { # <método> <ruta> <salida> [cuerpo]
  printf '%s %s %s %s\n' "$1" "$2" "${CF_INI:-}" "$( [[ -n "${4:-}" ]] && cat "$4")" >> "$API_LOG"
  if [[ "$2" == /zones\?per_page=1 ]]; then
    printf '{"result":[{"account":{"id":"0123456789abcdef0123456789abcdef"}}]}' > "$3"
  else
    printf '{}' > "$3"
  fi
  printf '%s' "$API_CODE"
}
# Zonas de mentira: ejemplo.test y otra.test; lo demás no lo ve el token.
_cf_zone_id() {
  case "$1" in
    *ejemplo.test) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    *otra.test)    printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
  esac
  return 0
}
posts() { grep -c '^POST ' "$API_LOG"; }

printf 'dns_cloudflare_api_token = dns\n' > "$TMP/etc/cloudflare.ini"
mkapp web static 0 ejemplo.test "www.ejemplo.test"
load_app web

section "Apagado, no se llama a Cloudflare"
CF_PURGE="no"; : > "$API_LOG"
run _cf_purge_after web >/dev/null 2>&1; check "sale con 0"   "0" "$?"
check "ninguna llamada"     "0" "$(grep -c . "$API_LOG")"

section "Encendido: un POST por zona con los hosts de la app"
CF_PURGE="yes"; : > "$API_LOG"
run _cf_purge_after web >/dev/null 2>&1; check "sale con 0"   "0" "$?"
check "un POST"             "1" "$(posts)"
check "a purge_cache"       "1" "$(grep -c '/zones/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/purge_cache' "$API_LOG")"
check "por host, los dos"   "1" "$(grep -cF '{"hosts":["ejemplo.test","www.ejemplo.test"]}' "$API_LOG")"
check "nada de purge_everything" "0" "$(grep -c purge_everything "$API_LOG")"

section "Dominios de dos zonas, dos llamadas"
A_ALIASES="www.ejemplo.test tienda.otra.test"; : > "$API_LOG"
run _cf_purge_app web >/dev/null 2>&1; check "sale con 0"     "0" "$?"
check "dos POST"            "2" "$(posts)"
check "la otra zona, sola"  "1" "$(grep -cF '{"hosts":["tienda.otra.test"]}' "$API_LOG")"

section "Un dominio que el token no ve se dice, y lo demás se vacía igual"
A_ALIASES="www.ejemplo.test fuera.test"; : > "$API_LOG"
out="$(run _cf_purge_app web 2>&1)"; r=$?
check "rc 1"                "1" "$r"
check "lo nombra"           "1" "$(grep -c 'fuera.test' <<<"$out")"
check "el resto sí"         "1" "$(posts)"
A_ALIASES="www.ejemplo.test"

section "Sin permiso de purga: se dice cuál falta, y el despliegue sigue"
API_CODE=403; : > "$API_LOG"
out="$(run _cf_purge_app web 2>&1)"; r=$?
check "rc 1"                "1" "$r"
check "nombra el permiso"   "1" "$(grep -c 'Cache Purge' <<<"$out")"
run _cf_purge_after web >/dev/null 2>&1; check "pero after da 0" "0" "$?"
API_CODE=200

section "El token de purga manda sobre el de DNS"
: > "$API_LOG"
run _cf_purge_app web >/dev/null 2>&1
check "sin el suyo, cloudflare.ini" "1" "$(grep -c "$TMP/etc/cloudflare.ini" "$API_LOG")"
printf 'dns_cloudflare_api_token = purga\n' > "$TMP/etc/cloudflare-purge.ini"
: > "$API_LOG"
run _cf_purge_app web >/dev/null 2>&1
check "con el suyo, ése"    "1" "$(grep -c "$TMP/etc/cloudflare-purge.ini" "$API_LOG")"
rm -f "$TMP/etc/cloudflare-purge.ini"

section "on/off se guardan en orbit.conf; sin token, on no se enciende"
mv "$TMP/etc/cloudflare.ini" "$TMP/etc/cloudflare.ini.aparte"
run cmd_cf_purge on >/dev/null 2>&1; check "sin token: falla" "1" "$?"
check "y no lo apunta"      "0" "$(grep -c '^CF_PURGE=.*yes' "$CONF_FILE")"
mv "$TMP/etc/cloudflare.ini.aparte" "$TMP/etc/cloudflare.ini"
run cmd_cf_purge on >/dev/null 2>&1; check "con token: 0"    "0" "$?"
check "CF_PURGE=yes"        "1" "$(grep -c "^CF_PURGE='\?\"\?yes" "$CONF_FILE")"
run cmd_cf_purge off >/dev/null 2>&1
check "off lo apaga"        "1" "$(grep -c "^CF_PURGE='\?\"\?no" "$CONF_FILE")"

section "token: se prueba antes de guardarlo, y queda sólo para root"
FAKE_TOK="abc_123-XYZ"
ask() { printf -v "$1" '%s' "$FAKE_TOK"; }
API_CODE=403
run cmd_cf_purge token >/dev/null 2>&1; check "rechazado: falla" "1" "$?"
check "y no lo guarda"      "0" "$([[ -e "$TMP/etc/cloudflare-purge.ini" ]] && echo 1 || echo 0)"
check "ni deja temporales"  "0" "$(find "$TMP/etc" -name '.cloudflare-purge.ini.*' | wc -l)"
API_CODE=200
run cmd_cf_purge token >/dev/null 2>&1; check "bueno: 0"         "0" "$?"
check "lo guarda"           "1" "$(grep -c "= $FAKE_TOK$" "$TMP/etc/cloudflare-purge.ini")"
check "en 600"              "600" "$(stat -c %a "$TMP/etc/cloudflare-purge.ini")"
FAKE_TOK='mal token'
run cmd_cf_purge token >/dev/null 2>&1; check "con espacios: falla" "1" "$?"
check "y deja el anterior"  "1" "$(grep -c 'abc_123-XYZ' "$TMP/etc/cloudflare-purge.ini")"

section "Lo llaman el despliegue y la vuelta atrás"
check "cmd_deploy"          "1" "$(declare -f cmd_deploy   | grep -c '_cf_purge_after "\$name"')"
check "cmd_rollback"        "1" "$(declare -f cmd_rollback | grep -c '_cf_purge_after "\$name"')"
check "no entra en las copias" "0" "$(declare -f cmd_backup | grep -c 'cloudflare-purge')"

report
