#!/usr/bin/env bash
# Variables de entorno: ida y vuelta, valores difíciles y uso desde scripts.
#   bash tests/env_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables que lee el
# 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root()  { :; }
systemctl()  { printf '%s\n' "$*" >> "$TMP/systemctl.log"; }
LOG_FILE="$TMP/orbit.log"
: > "$TMP/systemctl.log"

mkapp web node 3001 web.test
ENVF="$TMP/apps/web/shared/.env"
mkdir -p "$TMP/apps/web/shared"

section "Alta, cambio y baja"
run cmd_env set web CLAVE valor >/dev/null 2>&1; r=$?
check "añade"          "0"     "$r"
check "y se lee"       "valor" "$(run cmd_env get web CLAVE)"
run cmd_env set web CLAVE otro >/dev/null 2>&1
check "sustituye"      "otro"  "$(run cmd_env get web CLAVE)"
check "sin duplicar"   "1"     "$(grep -c '^CLAVE=' "$ENVF")"
run cmd_env unset web CLAVE >/dev/null 2>&1
check "elimina"        "0"     "$(grep -c '^CLAVE=' "$ENVF")"
# Quitar algo que no está no es un error: el estado final es el que se pedía.
run cmd_env unset web CLAVE >"$TMP/u" 2>&1; r=$?
check "quitar dos veces" "0" "$r"
check "y lo dice"        "1" "$(grep -c 'no estaba definida' "$TMP/u")"

section "Valores difíciles"
# El bug que costó _q(): con comillas dobles, bash expande $ al cargar el
# fichero y la contraseña llega truncada.
run cmd_env set web PASSWORD 'p$assw0rd' >/dev/null 2>&1
check "conserva el dólar" 'p$assw0rd' "$(run cmd_env get web PASSWORD)"
run cmd_env set web URL 'postgresql://u:p$x@127.0.0.1:5432/db' >/dev/null 2>&1
check "url con dólar" 'postgresql://u:p$x@127.0.0.1:5432/db' "$(run cmd_env get web URL)"
run cmd_env set web CON_ESPACIOS 'uno dos tres' >/dev/null 2>&1
check "con espacios" "uno dos tres" "$(run cmd_env get web CON_ESPACIOS)"
run cmd_env set web CON_DOBLES 'dice "hola"' >/dev/null 2>&1
check "con comillas dobles" 'dice "hola"' "$(run cmd_env get web CON_DOBLES)"
run cmd_env set web VACIA '' >/dev/null 2>&1
check "valor vacío" "" "$(run cmd_env get web VACIA)"
run cmd_env set web CON_IGUAL 'a=b=c' >/dev/null 2>&1
check "con signos igual" "a=b=c" "$(run cmd_env get web CON_IGUAL)"
run cmd_env set web BACKTICK 'a`b`c' >/dev/null 2>&1
check "con comilla invertida" 'a`b`c' "$(run cmd_env get web BACKTICK)"

section "Lo que el .env sirve de verdad"
# La prueba que importa: lo que ve quien carga el fichero, que es lo que hacen
# el build y 'orbit exec'.
# shellcheck disable=SC1090  # es el .env que acaba de escribir la prueba
VISTO="$( set -a; . "$ENVF"; set +a; printf '%s|%s|%s' "$PASSWORD" "$CON_ESPACIOS" "$CON_DOBLES" )"
check "coincide al cargarlo" 'p$assw0rd|uno dos tres|dice "hola"' "$VISTO"

section "Lo que no se acepta"
# bash escapa la comilla simple como '\'' y systemd no entiende ese escape:
# el valor se leería distinto según lo lance el servicio o 'orbit exec'.
run cmd_env set web MALA "no'vale" >"$TMP/e" 2>&1; r=$?
check "rechaza la comilla simple" "1" "$r"
check "y explica por qué"         "1" "$(grep -c 'systemd y bash no la escapan igual' "$TMP/e")"
check "no la ha escrito"          "0" "$(grep -c '^MALA=' "$ENVF")"
run cmd_env set web '2CLAVE' x >/dev/null 2>&1; r=$?
check "rechaza clave que empieza por número" "1" "$r"
run cmd_env set web 'CON-GUION' x >/dev/null 2>&1; r=$?
check "rechaza el guion" "1" "$r"
run cmd_env set web SOLA >/dev/null 2>&1; r=$?
check "exige un valor" "1" "$r"
run cmd_env get web NOEXISTE >/dev/null 2>&1; r=$?
check "get de algo que no está falla" "1" "$r"

section "Uso desde un script"
# Sin decoración: VALOR=$(orbit env get ...) tiene que funcionar tal cual.
VALOR="$(run cmd_env get web CON_ESPACIOS)"
check "salida limpia" "uno dos tres" "$VALOR"
check "una sola línea" "1" "$(run cmd_env get web CON_ESPACIOS | wc -l)"

section "Listado"
run cmd_env list web >"$TMP/l" 2>&1
check "lista las claves"  "1" "$(grep -cx 'PASSWORD' "$TMP/l")"
# Los valores son secretos: no salen en el listado.
check "sin valores"       "0" "$(grep -c 'p\$assw0rd' "$TMP/l")"

section "Comentarios y orden"
# Un .env comentado a mano no debe descolocarse al tocar una clave.
cat > "$ENVF" <<'EOF'
# Base de datos
DATABASE_URL='postgresql://x'
# Terceros
STRIPE_KEY='sk_test'
EOF
run cmd_env set web STRIPE_KEY 'sk_live' >/dev/null 2>&1
check "conserva comentarios" "2" "$(grep -c '^#' "$ENVF")"
check "sustituye en su sitio" "4" "$(grep -n '^STRIPE_KEY=' "$ENVF" | cut -d: -f1)"
check "no toca a la otra" "postgresql://x" "$(run cmd_env get web DATABASE_URL)"

section "Reinicio"
: > "$TMP/systemctl.log"
run cmd_env set web OTRA x >"$TMP/r1" 2>&1
check "no reinicia por defecto" "0" "$(grep -c restart "$TMP/systemctl.log")"
check "pero lo recuerda"        "1" "$(grep -c 'orbit restart web' "$TMP/r1")"
run cmd_env set web OTRA y --restart >/dev/null 2>&1
check "reinicia si se pide"     "1" "$(grep -c 'restart orbit-web' "$TMP/systemctl.log")"

section "Compatibilidad con lo ya escrito"
# Ficheros de versiones anteriores: comillas dobles, export, sin comillas.
cat > "$ENVF" <<'EOF'
SIN_COMILLAS=valor
CON_DOBLES="otro valor"
export EXPORTADA=tercero
EOF
check "lee sin comillas"   "valor"       "$(run cmd_env get web SIN_COMILLAS)"
check "lee comillas dobles" "otro valor" "$(run cmd_env get web CON_DOBLES)"
check "lee las exportadas" "tercero"     "$(run cmd_env get web EXPORTADA)"
check "las lista todas"    "3"           "$(run cmd_env list web | wc -l)"
run cmd_env set web EXPORTADA cambiado >/dev/null 2>&1
check "sustituye una exportada" "cambiado" "$(run cmd_env get web EXPORTADA)"
check "sin dejar la vieja"      "0"        "$(grep -c '^export EXPORTADA' "$ENVF")"

section "El symlink de la release sigue valiendo"
# El .env se enlaza dentro de cada release: si se reemplazara el fichero por
# uno nuevo en vez de reescribirlo, el enlace quedaría apuntando al viejo.
mkdir -p "$TMP/apps/web/releases/r1"
ln -sfn "$ENVF" "$TMP/apps/web/releases/r1/.env"
run cmd_env set web ENLACE funciona >/dev/null 2>&1
# shellcheck disable=SC1090
POR_ENLACE="$( set -a; . "$TMP/apps/web/releases/r1/.env"; set +a; printf '%s' "$ENLACE" )"
check "se ve por el enlace" "funciona" "$POR_ENLACE"

section "Permisos"
check "0640"        "640"    "$(stat -c '%a' "$ENVF")"
check "no legible por todos" "0" "$(( $(stat -c '%a' "$ENVF") % 10 ))"

section "El dueño del .env se conserva, no se adivina"
# '_env_write' terminaba con un 'chown "$(app_user)"', y app_user() lee las
# GLOBALES: quien llega sin load_app —'orbit db create <app>' es el caso real—
# obtenía 'deploy' y le robaba el .env al usuario de una app aislada. El efecto
# se ve entero en un servidor: 'orbit db create' sobre una app Laravel aislada
# dejaba el .env en deploy:deploy 0640, y el build siguiente moría con EACCES
# leyéndolo — su propio fichero. El arreglo del PR #10 estaba en la llamada, y
# esta línea lo deshacía tres líneas más abajo.
#
# Reescribir conserva el inodo, así que el dueño se mantiene solo: lo que se
# afirma aquí es que no se toca. Sin root no se puede dar el fichero a otro
# usuario, así que se comprueba que no se llame a chown, que es la causa.
CHOWN_LOG="$TMP/chown-env.log"; : > "$CHOWN_LOG"
chown() { printf 'chown %s\n' "$*" >> "$CHOWN_LOG"; command chown "$@" 2>/dev/null || true; }
A_USER=""   # como llega 'orbit db create': sin load_app
_env_write "$ENVF" SINDUENO valor
check "no adivina el dueño" "0" "$(grep -c "$ENVF" "$CHOWN_LOG")"
check "y el valor se escribe igual" "valor" "$(_env_read "$ENVF" SINDUENO)"
check "conservando los permisos"    "640"   "$(stat -c '%a' "$ENVF")"
unset -f chown

section "Una clave se compara literal, no como expresión regular"
# Los tres ayudantes metían la clave en una expresión regular, menos el que
# borra, que la comparaba literal. Con eso no podían coincidir nunca:
#
#   · 'env get app FOO.BAR' devolvía el valor de FOOXBAR — el secreto de otra
#     variable, por stdout, bajo un nombre que no es el suyo.
#   · 'env unset app FOO.BAR' decía «eliminada» sin borrar nada, porque el que
#     decide si existe casaba y el que borra no. Quien quita una credencial
#     filtrada se quedaba creyendo que ya no estaba.
#
# El punto es el metacarácter barato; el mismo agujero lo abrían '*', '[' o
# '^'. Se comprueban los tres ayudantes por separado, porque el fallo era
# justo que no estaban de acuerdo.
REGEXF="$TMP/regex.env"
printf 'FOOXBAR=secreto-de-otra\nDB_PASS=hunter2\n' > "$REGEXF"
_env_has "$REGEXF" 'FOO.BAR' && r=si || r=no
check "_env_has no casa por comodín" "no" "$r"
check "_env_read no devuelve el ajeno" "" "$(_env_read "$REGEXF" 'FOO.BAR')"
_env_write "$REGEXF" 'FOO.BAR'
check "y el fichero sigue entero" "2" "$(grep -c '=' "$REGEXF")"
# La clave de verdad se sigue leyendo y borrando igual que siempre.
check "la clave literal sí se lee" "hunter2" "$(_env_read "$REGEXF" DB_PASS)"
_env_has "$REGEXF" DB_PASS && r=si || r=no
check "y sí se encuentra"          "si" "$r"
# Y varias definiciones de la misma clave: gana la última, como en quien carga
# el fichero. Lo hacía el 'tail -1' del sed que se ha quitado.
printf 'K=primera\nK=ultima\n' > "$REGEXF"
check "la última definición gana" "ultima" "$(_env_read "$REGEXF" K)"
# 'export K=v' es una línea válida de .env y se leía igual: sigue igual.
printf '  export K=exportada\n' > "$REGEXF"
check "acepta 'export' y sangría" "exportada" "$(_env_read "$REGEXF" K)"

report
