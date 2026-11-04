#!/usr/bin/env bash
# Provisión declarativa de variables desde orbit.json.
#   bash tests/provision_test.sh
#
# Lo que se comprueba, en orden de importancia:
#   · lo que se puede generar se genera sin preguntar a nadie,
#   · lo que ya tiene valor NO se pisa nunca (un redespliegue no puede
#     cambiarle a nadie la contraseña),
#   · sin terminal no se cuelga esperando: avisa y sigue,
#   · y el fichero queda con permisos de credencial, no de fichero público.
# shellcheck disable=SC2034  # estas pruebas asignan variables que lee el
# 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"

mkapp web static 3001 web.test
SHARED="$TMP/apps/web/shared"
mkdir -p "$SHARED"

# ---------------------------------------------------------------- descriptor
section "Lectura de orbit.json"

REPO="$TMP/repo"; mkdir -p "$REPO"
cat > "$REPO/orbit.json" <<'JSON'
{
  "type": "static",
  "outdir": "dist",
  "shared": ["api/.env"],
  "env": {
    "file": "api/.env",
    "vars": {
      "TOKEN":     { "generate": "hex:24", "desc": "Token del panel" },
      "SMTP_USER": { "prompt": "Cuenta SMTP" },
      "SMTP_PASS": { "prompt": "Contraseña", "secret": true }
    }
  }
}
JSON

# Sin 'jq' no se aplica ningún descriptor —está decidido así en §18.9b— y
# entonces estas cuatro afirmaciones dejan de ser ciertas POR DISEÑO: sin la
# guarda, la suite se ponía en rojo acusando a código sano. Es el tercer
# estado de docs/DEVELOPMENT.md, ni probado ni saltado, y aquí venía doble: la suite
# tampoco la ejecutaba nadie, así que nunca se vio. La pregunta al escribir
# una prueba que depende de una herramienta opcional no es sólo «¿se salta?»
# sino «¿qué afirma si no está?».
if ! command -v jq >/dev/null; then
  echo "  (falta jq: me salto lo que sale de leer el orbit.json)"
else

A_TYPE=""; A_ENV_FILE=""; A_ENV_SPEC=""
_read_descriptor "$REPO" >/dev/null 2>&1
check "coge el fichero declarado" "api/.env" "$A_ENV_FILE"
check "y las tres variables"      "3"        "$(printf '%s\n' "$A_ENV_SPEC" | grep -c .)"
check "TOKEN se genera"           "generate" "$(printf '%s\n' "$A_ENV_SPEC" | awk -F'\037' '$1=="TOKEN"{print $2}')"
check "SMTP_PASS es secreto"      "secret"   "$(printf '%s\n' "$A_ENV_SPEC" | awk -F'\037' '$1=="SMTP_PASS"{print $4}')"

# Sin bloque 'env' no se inventa nada: un repo que no lo declara no debe
# encontrarse un .env aparecido de la nada. Va dentro de la guarda a
# propósito: sin jq esto se cumpliría por no haber leído nada, que es pasar
# por el motivo equivocado.
cat > "$REPO/orbit.json" <<'JSON'
{ "type": "static", "outdir": "dist" }
JSON
A_ENV_FILE=""; A_ENV_SPEC=""
_read_descriptor "$REPO" >/dev/null 2>&1
check "sin bloque env, nada" "" "$A_ENV_SPEC"

fi

# ------------------------------------------------------- siempre definidas
# El fallo que tumbó el CI: A_ENV_SPEC no estaba en ORBIT_APP_FIELDS, así que
# tras `load_app` quedaba SIN DEFINIR y `set -u` abortaba el despliegue de
# cualquier app —también las que no declaran `env`—.
section "Las variables quedan definidas pase lo que pase"
check "persistidas con el resto" "1" "$(printf '%s\n' "${ORBIT_APP_FIELDS[@]}" | grep -c '^A_ENV_SPEC$')"
A_ENV_FILE="sucio"; A_ENV_SPEC="sucio"
_read_env_block "$TMP/no-existe-este-dir"
check "sin orbit.json, vacías"   ""  "$A_ENV_FILE$A_ENV_SPEC"
mkdir -p "$TMP/sinenv"; echo '{ "type": "static" }' > "$TMP/sinenv/orbit.json"
A_ENV_FILE="sucio"; A_ENV_SPEC="sucio"
_read_env_block "$TMP/sinenv"
check "sin bloque env, vacías"   ""  "$A_ENV_FILE$A_ENV_SPEC"
# Y sobreviven al ciclo guardar/cargar, que es lo que hace el despliegue.
A_ENV_FILE="api/.env"; A_ENV_SPEC="$(printf 'K\tgenerate\thex:8\tplain\t' | tr '\t' '\037')"
A_NAME="web"; save_app; A_ENV_FILE=""; A_ENV_SPEC=""; load_app web
check "sobreviven a save/load"   "api/.env" "$A_ENV_FILE"
check "y el spec entero"         "K"        "$(printf '%s\n' "$A_ENV_SPEC" | awk -F'\037' '{print $1}')"

# ------------------------------------------------------------- fichero único
section "orbit env toca el mismo fichero que la provisión"
# Si `orbit env set` escribiera en shared/.env mientras la provisión mira
# shared/api/.env, la variable nunca quedaría definida y el aviso se repetiría
# en cada despliegue sin que se entienda por qué.
A_ENV_FILE="api/.env"
check "_env_path sigue al descriptor" "api/.env" "$(_env_path web | sed "s|$SHARED/||")"
A_ENV_FILE=""
check "y por defecto, .env"           ".env"     "$(_env_path web | sed "s|$SHARED/||")"
A_ENV_FILE="/etc/passwd"
check "una ruta absoluta no cuela"    ".env"     "$(_env_path web | sed "s|$SHARED/||")"
A_ENV_FILE="api/.env"

# ------------------------------------------------------------------ generar
section "Lo que no necesita a nadie se genera solo"

A_ENV_FILE="api/.env"
A_ENV_SPEC="$(printf 'TOKEN\tgenerate\thex:24\tplain\tToken del panel' | tr '\t' '\037')"
ASSUME_YES="yes"     # como un autodeploy: sin nadie al teclado
_provision_env web "$SHARED" >/dev/null 2>&1

ENVF="$SHARED/api/.env"
check "crea el fichero"      "0"  "$([[ -f "$ENVF" ]] && echo 0 || echo 1)"
TOK="$(_env_read "$ENVF" TOKEN)"
check "y el token"           "48" "${#TOK}"
check "en hexadecimal"       "0"  "$([[ "$TOK" =~ ^[0-9a-f]+$ ]] && echo 0 || echo 1)"
check "permisos de secreto"  "640" "$(stat -c '%a' "$ENVF")"

section "Un redespliegue no pisa lo que ya hay"
_provision_env web "$SHARED" >/dev/null 2>&1
check "el token es el mismo" "$TOK" "$(_env_read "$ENVF" TOKEN)"
check "y no se duplica"      "1"    "$(grep -c '^TOKEN=' "$ENVF")"

# Un valor puesto a mano manda sobre cualquier generación posterior.
run cmd_env set web TOKEN 'puesto-a-mano' >/dev/null 2>&1 || true
_env_write "$ENVF" TOKEN 'puesto-a-mano'
_provision_env web "$SHARED" >/dev/null 2>&1
check "respeta el valor manual" "puesto-a-mano" "$(_env_read "$ENVF" TOKEN)"

# ------------------------------------------------------- sin nadie al teclado
section "Lo que hay que preguntar, sin terminal"

A_ENV_SPEC="$(printf 'SMTP_USER\tprompt\tCuenta SMTP\tplain\t\nSMTP_PASS\tprompt\tContraseña\tsecret\t' | tr '\t' '\037')"
ASSUME_YES="yes"
_provision_env web "$SHARED" > "$TMP/out" 2>&1
check "no se cuelga"          "0" "$?"
check "no inventa valores"    "0" "$(grep -c '^SMTP_USER=' "$ENVF")"
check "avisa de lo que falta" "1" "$(grep -c 'Faltan por definir.*SMTP_USER' "$TMP/out")"
check "y da el comando"       "1" "$(grep -c 'orbit env set web SMTP_PASS' "$TMP/out")"

# --------------------------------------------------------------- generadores
section "Formatos de generación"
V="$(_env_generate hex:8)"
check "hex da el doble de caracteres" "16" "${#V}"
V="$(_env_generate uuid)"
check "uuid con forma de uuid" "0" "$([[ "$V" =~ ^[0-9a-f-]{36}$ ]] && echo 0 || echo 1)"
V="$(_env_generate base64:24)"
check "base64 sin caracteres de URL" "0" "$([[ "$V" =~ ^[A-Za-z0-9_-]+=*$ ]] && echo 0 || echo 1)"
check "formato desconocido falla"    "1" "$(_env_generate rot13:8 >/dev/null 2>&1; echo $?)"

# --------------------------------------------------- valores puestos a mano
section "Un valor vacío puesto a mano es una decisión, no un hueco"
# `orbit env set app CLAVE ''` es como se desactiva algo opcional. Si la
# provisión lo tratara como «falta», cada despliegue lo volvería a rellenar.
A_ENV_FILE="api/.env"
A_ENV_SPEC="$(printf 'OPCIONAL\tgenerate\thex:8\tplain\t' | tr '\t' '\037')"
_env_write "$ENVF" OPCIONAL ''
_provision_env web "$SHARED" >/dev/null 2>&1
check "no lo rellena"        ""  "$(_env_read "$ENVF" OPCIONAL)"
check "y sigue declarada"    "1" "$(grep -c '^OPCIONAL=' "$ENVF")"

# ------------------------------------------------------------------ defensa
section "Entradas hostiles"
A_ENV_FILE="../../../etc/passwd"
A_ENV_SPEC="$(printf 'X\tgenerate\thex:8\tplain\t' | tr '\t' '\037')"
_provision_env web "$SHARED" > "$TMP/bad" 2>&1
check "rechaza salirse del directorio" "1" "$(grep -c 'no es una ruta dentro' "$TMP/bad")"

A_ENV_FILE="api/.env"
A_ENV_SPEC="$(printf '2MALA\tgenerate\thex:8\tplain\t' | tr '\t' '\037')"
_provision_env web "$SHARED" > "$TMP/bad2" 2>&1
check "rechaza nombres inválidos" "1" "$(grep -c 'no es un nombre de variable' "$TMP/bad2")"

# El .env vive en shared/, que es del usuario de despliegue: una app
# comprometida puede cambiarlo por un enlace a /etc/shadow. Todo lo que hay
# debajo corre como root, así que seguir el enlace sería escalada de
# privilegios, y automática: pasa sola en el despliegue siguiente.
section "No se escribe a través de un enlace simbólico"
VICTIMA="$TMP/victima"; echo "no me toques" > "$VICTIMA"

rm -f "$SHARED/api/.env"; ln -s "$VICTIMA" "$SHARED/api/.env"
A_ENV_FILE="api/.env"; A_ENV_SPEC="$(printf 'X\tgenerate\thex:8\tplain\t' | tr '\t' '\037')"
_provision_env web "$SHARED" > "$TMP/sym" 2>&1
check "avisa del enlace"        "1"              "$(grep -c 'enlace simbólico' "$TMP/sym")"
check "y no escribe la víctima" "no me toques"   "$(cat "$VICTIMA")"
rm -f "$SHARED/api/.env"

# Y también si el enlace está a mitad del camino, no en el fichero final.
rm -rf "$SHARED/api"; mkdir -p "$TMP/fuera"; ln -s "$TMP/fuera" "$SHARED/api"
_provision_env web "$SHARED" > "$TMP/sym2" 2>&1
check "detecta el enlace intermedio" "1" "$(grep -c 'enlace simbólico' "$TMP/sym2")"
check "y no crea nada fuera"         "0" "$(find "$TMP/fuera" -type f | wc -l)"
rm -f "$SHARED/api"


# ----------------------------------------------------------- con alguien delante
section "Las respuestas van a su variable, no a la lista"
# Hasta la 1.3.7 el bucle leía la especificación por la entrada estándar y las
# preguntas también: la respuesta se tragaba la línea siguiente de la lista.
# Aquí se simula a alguien delante con la entrada por una tubería.
_env_can_ask() { return 0; }
rm -rf "$SHARED/api"; mkdir -p "$SHARED/api"
A_ENV_FILE="api/.env"
A_ENV_SPEC="$(printf 'SMTP_USER\tprompt\tCuenta SMTP\tplain\t\nSMTP_PASS\tprompt\tContraseña\tsecret\t\nOTRA\tprompt\tOtra\tplain\t' | tr '\t' '\037')"
_provision_env web "$SHARED" < <(printf 'yo@x.test\nsecreto1\ntercera\n') > "$TMP/ask" 2>&1
check "la primera respuesta, a la primera" "yo@x.test" "$(_env_read "$ENVF" SMTP_USER)"
check "la segunda, a la segunda"           "secreto1"  "$(_env_read "$ENVF" SMTP_PASS)"
check "y la tercera también"               "tercera"   "$(_env_read "$ENVF" OTRA)"
check "nada pendiente"                     ""          "$ENV_MISSING"

if ! command -v jq >/dev/null; then
  echo "  (falta jq: me salto lo que se declara en orbit.json)"
else
section "Una variable declarada sin 'prompt' también se pregunta"
cat > "$TMP/orbit.json" <<'JSON'
{ "type": "static",
  "env": { "file": "api/.env", "vars": {
    "API_URL": { "desc": "URL de la API", "default": "https://api.test" },
    "DB_PASS": { "prompt": "Contraseña de la base", "secret": true, "required": true },
    "ANALYTICS": {}
  } } }
JSON
_read_env_block "$TMP"
check "API_URL se pregunta"          "prompt"   "$(awk -F'\037' '$1=="API_URL"{print $2}' <<<"$A_ENV_SPEC")"
check "con su descripción de etiqueta" "URL de la API" "$(awk -F'\037' '$1=="API_URL"{print $3}' <<<"$A_ENV_SPEC")"
check "y su valor por defecto"       "https://api.test" "$(awk -F'\037' '$1=="API_URL"{print $7}' <<<"$A_ENV_SPEC")"
check "DB_PASS es obligatoria"       "required" "$(awk -F'\037' '$1=="DB_PASS"{print $6}' <<<"$A_ENV_SPEC")"
check "una vacía se pregunta por su nombre" "ANALYTICS" "$(awk -F'\037' '$1=="ANALYTICS"{print $3}' <<<"$A_ENV_SPEC")"

section "Sin nadie delante: lo que tiene valor por defecto se pone, lo obligatorio para"
_env_can_ask() { return 1; }
rm -f "$ENVF"
_provision_env web "$SHARED" > "$TMP/req" 2>&1
check "el valor por defecto, puesto" "https://api.test" "$(_env_read "$ENVF" API_URL)"
check "la obligatoria, apuntada"     "DB_PASS"          "$ENV_MISSING_REQ"
check "la opcional, sólo pendiente"  "DB_PASS ANALYTICS" "$ENV_MISSING"
check "y propone --env"              "1" "$(grep -c 'orbit deploy web --env' "$TMP/req")"

section "Con alguien delante, Intro acepta el valor por defecto"
_env_can_ask() { return 0; }
rm -f "$ENVF"
_provision_env web "$SHARED" < <(printf '\nclave-db\n\n') > "$TMP/req2" 2>&1
check "Intro deja el de por defecto" "https://api.test" "$(_env_read "$ENVF" API_URL)"
check "la obligatoria, contestada"   "clave-db" "$(_env_read "$ENVF" DB_PASS)"
check "ya no para nada"              ""         "$ENV_MISSING_REQ"
check "la vacía queda pendiente"     "ANALYTICS" "$ENV_MISSING"

section "Una obligatoria sin respuesta se pregunta dos veces y luego para"
rm -f "$ENVF"
_provision_env web "$SHARED" < <(printf 'x\n\n\n\n') > "$TMP/req3" 2>&1
check "insiste una vez" "1" "$(grep -c 'Hace falta un valor' "$TMP/req3")"
check "y la deja como obligatoria pendiente" "DB_PASS" "$ENV_MISSING_REQ"

fi
_env_can_ask() { return 0; }

section "Un valor con salto de línea o comilla simple no se guarda"
rm -f "$ENVF"
A_ENV_SPEC="$(printf 'K\tprompt\tK\tplain\t' | tr '\t' '\037')"
_provision_env web "$SHARED" < <(printf "con'comilla\n") > "$TMP/q" 2>&1
check "no lo escribe" "0" "$(grep -c '^K=' "$ENVF" 2>/dev/null || true)"
check "y dice por qué" "1" "$(grep -c 'comilla simple' "$TMP/q")"
check "falla _env_value_ok con salto" "1" "$(_env_value_ok $'a\nb' && echo 0 || echo 1)"

section "Lo que llega con deploy --env se escribe antes que nada"
rm -f "$ENVF"
DEP_ENV_SET=("K=desde-cli" "OTRA=dos")
_env_can_ask() { return 1; }
_provision_env web "$SHARED" > "$TMP/cli" 2>&1
check "escribe la primera"     "desde-cli" "$(_env_read "$ENVF" K)"
check "y la segunda"           "dos"       "$(_env_read "$ENVF" OTRA)"
check "y K ya no falta"        ""          "$ENV_MISSING"
DEP_ENV_SET=()

section "El .env.example del repo"
REL="$TMP/release"; mkdir -p "$REL/api"
printf '# comentario\nAPP_ENV=production\nexport MAIL_HOST="smtp.test" # nota\nSTRIPE_SECRET=sk_test_cambiame\r\nYA=1\n' > "$REL/api/.env.example"
rm -f "$ENVF"; printf 'YA=hecho\n' > "$ENVF"
A_ENV_FILE="api/.env"; A_ENV_SPEC=""; ENV_EXAMPLE_DECL=""
_provision_env web "$SHARED" "$REL" > "$TMP/ex1" 2>&1
check "sin nadie delante, lo dice" "1" "$(grep -c 'api/.env.example trae variable(s).*APP_ENV MAIL_HOST STRIPE_SECRET' "$TMP/ex1")"
check "y no escribe nada"          "0" "$(grep -c '^APP_ENV=' "$ENVF")"
check "ni toca lo que había"       "hecho" "$(_env_read "$ENVF" YA)"
check "no para el despliegue"      ""  "$ENV_MISSING_REQ"

_env_can_ask() { return 0; }
# s = sí; Intro = el del ejemplo; un valor; el secreto no trae el del ejemplo.
_provision_env web "$SHARED" "$REL" < <(printf 's\n\nmail.mio.test\nsk_live_bueno\n') > "$TMP/ex2" 2>&1
check "Intro deja el del ejemplo"    "production"    "$(_env_read "$ENVF" APP_ENV)"
check "un valor nuevo manda"         "mail.mio.test" "$(_env_read "$ENVF" MAIL_HOST)"
check "el secreto, el que se teclea" "sk_live_bueno" "$(_env_read "$ENVF" STRIPE_SECRET)"
check "el ejemplo no se ofrece en un secreto" "0" "$(grep -c 'sk_test_cambiame' "$TMP/ex2")"

rm -f "$ENVF"
_provision_env web "$SHARED" "$REL" < <(printf 'n\n') > "$TMP/ex3" 2>&1
check "si dice que no, nada" "0" "$(grep -c '=' "$ENVF" 2>/dev/null || true)"

ENV_EXAMPLE_DECL="no"
_provision_env web "$SHARED" "$REL" > "$TMP/ex4" 2>&1 </dev/null
check "\"example\": false lo apaga" "0" "$(grep -c 'env.example' "$TMP/ex4")"
ENV_EXAMPLE_DECL=""
ln -sf /etc/hostname "$REL/.env.example"; rm -f "$REL/api/.env.example"
check "un ejemplo que es un enlace no se lee" "" "$(_env_example_file "$REL")"
# Y tampoco uno con un enlace por el camino: git guarda enlaces, y con 'cfg'
# apuntando a /etc/orbit y "example": "cfg/orbit.conf", root leía la
# configuración del servidor y ofrecía sus valores para el .env de la app.
mkdir -p "$TMP/de-root"; printf 'NOTIFY_TELEGRAM_TOKEN=secreto-del-servidor\n' > "$TMP/de-root/orbit.conf"
ln -sfn "$TMP/de-root" "$REL/cfg"
ENV_EXAMPLE_DECL="cfg/orbit.conf"
check "ni uno con un enlace por el camino" "" "$(_env_example_file "$REL")"
ENV_EXAMPLE_DECL=""; rm -f "$REL/cfg"
mkdir -p "$REL/cfg"; printf 'A=1\n' > "$REL/cfg/ejemplo.env"; ENV_EXAMPLE_DECL="cfg/ejemplo.env"
check "pero uno de verdad, sí" "$REL/cfg/ejemplo.env" "$(_env_example_file "$REL")"
ENV_EXAMPLE_DECL=""; rm -rf "$REL/cfg"
_env_can_ask() { return 1; }

section "Leer un .env como lo lee la app"
printf 'A="v" # nota\nB=v # nota\nC=crlf\r\nD=%s\nE="con \\" dentro"\nF=  \n' "$(_q "ab'cd")" > "$TMP/lee.env"
check "comillas dobles y comentario" "v"     "$(_env_read "$TMP/lee.env" A)"
check "sin comillas y comentario"    "v"     "$(_env_read "$TMP/lee.env" B)"
check "un CRLF no deja \\r"          "crlf"  "$(_env_read "$TMP/lee.env" C)"
check "lo que escribe _q vuelve igual" "ab'cd" "$(_env_read "$TMP/lee.env" D)"
check "una comilla escapada"         'con " dentro' "$(_env_read "$TMP/lee.env" E)"
check "sólo espacios es vacío"       ""      "$(_env_read "$TMP/lee.env" F)"

section "orbit env no sigue un enlace hasta un fichero de root"
VICT2="$TMP/shadow"; printf 'root:x\n' > "$VICT2"; chmod 0600 "$VICT2"
rm -rf "$SHARED/api"; mkdir -p "$SHARED/api"; ln -s "$VICT2" "$SHARED/api/.env"
A_ENV_FILE="api/.env"
run _env_path web >/dev/null 2>"$TMP/ep"; r=$?
check "se niega"               "1"   "$([[ "$r" != 0 ]] && echo 1 || echo 0)"
check "y lo dice"              "1"   "$(grep -c 'enlace simbólico' "$TMP/ep")"
check "el destino sigue en 600" "600" "$(stat -c '%a' "$VICT2")"
rm -f "$SHARED/api/.env"


report
