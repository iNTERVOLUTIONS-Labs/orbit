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
check "TOKEN se genera"           "generate" "$(printf '%s\n' "$A_ENV_SPEC" | awk -F'\t' '$1=="TOKEN"{print $2}')"
check "SMTP_PASS es secreto"      "secret"   "$(printf '%s\n' "$A_ENV_SPEC" | awk -F'\t' '$1=="SMTP_PASS"{print $4}')"

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
A_ENV_FILE="api/.env"; A_ENV_SPEC="$(printf 'K\tgenerate\thex:8\tplain\t')"
A_NAME="web"; save_app; A_ENV_FILE=""; A_ENV_SPEC=""; load_app web
check "sobreviven a save/load"   "api/.env" "$A_ENV_FILE"
check "y el spec entero"         "K"        "$(printf '%s\n' "$A_ENV_SPEC" | awk -F'\t' '{print $1}')"

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
A_ENV_SPEC="$(printf 'TOKEN\tgenerate\thex:24\tplain\tToken del panel')"
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

A_ENV_SPEC="$(printf 'SMTP_USER\tprompt\tCuenta SMTP\tplain\t\nSMTP_PASS\tprompt\tContraseña\tsecret\t')"
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
A_ENV_SPEC="$(printf 'OPCIONAL\tgenerate\thex:8\tplain\t')"
_env_write "$ENVF" OPCIONAL ''
_provision_env web "$SHARED" >/dev/null 2>&1
check "no lo rellena"        ""  "$(_env_read "$ENVF" OPCIONAL)"
check "y sigue declarada"    "1" "$(grep -c '^OPCIONAL=' "$ENVF")"

# ------------------------------------------------------------------ defensa
section "Entradas hostiles"
A_ENV_FILE="../../../etc/passwd"
A_ENV_SPEC="$(printf 'X\tgenerate\thex:8\tplain\t')"
_provision_env web "$SHARED" > "$TMP/bad" 2>&1
check "rechaza salirse del directorio" "1" "$(grep -c 'no es una ruta dentro' "$TMP/bad")"

A_ENV_FILE="api/.env"
A_ENV_SPEC="$(printf '2MALA\tgenerate\thex:8\tplain\t')"
_provision_env web "$SHARED" > "$TMP/bad2" 2>&1
check "rechaza nombres inválidos" "1" "$(grep -c 'no es un nombre de variable' "$TMP/bad2")"

# El .env vive en shared/, que es del usuario de despliegue: una app
# comprometida puede cambiarlo por un enlace a /etc/shadow. Todo lo que hay
# debajo corre como root, así que seguir el enlace sería escalada de
# privilegios, y automática: pasa sola en el despliegue siguiente.
section "No se escribe a través de un enlace simbólico"
VICTIMA="$TMP/victima"; echo "no me toques" > "$VICTIMA"

rm -f "$SHARED/api/.env"; ln -s "$VICTIMA" "$SHARED/api/.env"
A_ENV_FILE="api/.env"; A_ENV_SPEC="$(printf 'X\tgenerate\thex:8\tplain\t')"
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

report
