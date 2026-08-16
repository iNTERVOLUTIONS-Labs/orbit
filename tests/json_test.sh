#!/usr/bin/env bash
# El contrato máquina: escapado, tipos, y que lo que sale sea JSON de verdad.
#   bash tests/json_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, JSON…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"

# --- dobles de las piezas del sistema --------------------------------------
UP="$TMP/up"; mkdir -p "$UP"
systemctl() {
  case "${1:-}" in
    is-active) [[ -f "$UP/${3:-${2:-}}" ]] ;;
    *) return 0 ;;
  esac
}
# Los certificados viven en /etc/letsencrypt, que ni existe ni debe tocarse
# desde una prueba: se traen a $TMP y se les pone la fecha de caducidad a mano.
mkdir -p "$TMP/certs"
cert_file() { echo "$TMP/certs/$1.pem"; }
FAKE_EXP=""
openssl() { printf 'notAfter=%s\n' "$FAKE_EXP"; }

section "Escapado de cadenas"
check "texto normal"      '"hola"'            "$(_j_str 'hola')"
check "vacía"             '""'                "$(_j_str '')"
check "comillas dobles"   '"dice \"hola\""'   "$(_j_str 'dice "hola"')"
check "barra invertida"   '"C:\\ruta"'        "$(_j_str 'C:\ruta')"
# La barra se escapa antes que nada: si se hiciera al revés, el \" que produce
# el escapado de la comilla se volvería a escapar y saldría \\" — JSON válido
# que dice otra cosa.
check "barra y comilla"   '"a\\\"b"'          "$(_j_str 'a\"b')"
check "comilla simple"    "\"d'or\""          "$(_j_str "d'or")"
check "acentos"           '"añó"'             "$(_j_str 'añó')"
check "tabulador"         '"a\tb"'            "$(_j_str "a"$'\t'"b")"
check "salto de línea"    '"a\nb"'            "$(_j_str "a"$'\n'"b")"
check "retorno de carro"  '"a\rb"'            "$(_j_str "a"$'\r'"b")"
# Un carácter de control sin escape corto rompería el JSON del cliente, así que
# se cae. Pasa de verdad: una app que escupe un \a acaba en un mensaje de error.
check "control sin escape" '"ab"'             "$(_j_str "a"$'\a'"b")"
# Lo que guarda _q y no debe expandirse en ningún momento del viaje.
check "variable literal"  '"pnpm --port ${PORT}"' "$(_j_str 'pnpm --port ${PORT}')"

section "Tipos"
check "número"            "3001"   "$(_j_num 3001)"
check "número negativo"   "-5"     "$(_j_num -5)"
# Vacío no es cero: el puerto de una web estática no existe, no vale 0.
check "vacío es null"     "null"   "$(_j_num '')"
check "texto es null"     "null"   "$(_j_num 'abc')"
check "medio texto"       "null"   "$(_j_num '30 días')"
check "sí"                "true"   "$(_j_bool yes)"
check "no"                "false"  "$(_j_bool no)"
check "vacío es false"    "false"  "$(_j_bool '')"
check "lista"             '["a","b"]' "$(_j_list a b)"
check "lista vacía"       '[]'     "$(_j_list)"
check "lista con comillas" '["di \"a\""]' "$(_j_list 'di "a"')"

section "Qué comandos hablan JSON"
run _json_capable list  ; r=$?; check "list sí"   "0" "$r"
run _json_capable top   ; r=$?; check "top sí"    "0" "$r"
run _json_capable doctor; r=$?; check "doctor sí" "0" "$r"
run _json_capable deploy; r=$?; check "deploy sí" "0" "$r"
run _json_capable new   ; r=$?; check "new no"    "1" "$r"

section "Dónde puede ir --json"
JSON="no"; _json_strip web --json
check "lo detecta"        "yes"   "$JSON"
check "y lo quita"        "web"   "${JSON_ARGS[*]}"
JSON="no"; _json_strip --json list web
check "delante también"   "yes"   "$JSON"
check "sin tocar el resto" "list web" "${JSON_ARGS[*]}"
JSON="no"; _json_strip web
check "sin bandera"       "no"    "$JSON"

# --- apps de mentira --------------------------------------------------------
mkapp web  next   3001 web.test "www.web.test blog.web.test"
mkapp docs static ""   docs.test
touch "$UP/orbit-web"
mkdir -p "$TMP/apps/web/releases/20260101-000000" "$TMP/apps/web/releases/20260102-000000"

if ! command -v jq >/dev/null; then
  printf '\nfalta jq: me salto las pruebas que validan el JSON.\n'
  report
fi

# Valida y consulta a la vez: si la salida no es JSON, jq falla y la
# comprobación enseña el error en vez de un valor raro.
j() { # j <filtro> <comando…>
  local q="$1"; shift
  JSON="yes" run "$@" 2>/dev/null | jq -r "$q" 2>&1
}

section "orbit list --json"
# Las apps salen ordenadas por nombre, así que se buscan por nombre y no por
# posición: una prueba que dependa del orden se rompe al añadir una app.
app() { printf '.apps[] | select(.name=="%s") | %s' "$1" "$2"; }
check "es JSON válido"   "object" "$(j 'type' cmd_list)"
check "dos apps"         "2"      "$(j '.apps | length' cmd_list)"
check "esquema"          "1"      "$(j '.schema' cmd_list)"
check "orden estable"    "docs web" "$(j '[.apps[].name] | join(" ")' cmd_list)"
check "tipo"             "next"   "$(j "$(app web .type)" cmd_list)"
# El puerto va como número y no como cadena: quien pinte "puerto 3001" no
# debería tener que convertirlo, y quien ordene por puerto, menos.
check "puerto es número" "number" "$(j "$(app web '.state.port | type')" cmd_list)"
check "puerto"           "3001"   "$(j "$(app web .state.port)" cmd_list)"
# Una estática no tiene puerto, y eso no es el puerto 0.
check "sin puerto"       "null"   "$(j "$(app docs .state.port)" cmd_list)"
check "alias como lista" "2"      "$(j "$(app web '.aliases | length')" cmd_list)"
check "primer alias"     "www.web.test" "$(j "$(app web '.aliases[0]')" cmd_list)"
check "sin alias"        "0"      "$(j "$(app docs '.aliases | length')" cmd_list)"
check "activo"           "running" "$(j "$(app web .state.service)" cmd_list)"
rm -f "$UP/orbit-web"
check "parado"           "stopped" "$(j "$(app web .state.service)" cmd_list)"
# Una web estática no está parada: es que no hay servicio que arrancar, y
# confundir las dos cosas pinta una alarma roja donde no pasa nada.
check "estática sin servicio" "null" "$(j "$(app docs .state.service)" cmd_list)"
check "releases"         "2"      "$(j "$(app web .state.releases)" cmd_list)"
check "sin certificado"  "false"  "$(j "$(app web .state.ssl)" cmd_list)"
touch "$TMP/certs/web.test.pem"
check "con certificado"  "true"   "$(j "$(app web .state.ssl)" cmd_list)"
# 'served' es lo primero que hay que saber: sin vhost nginx no atiende el
# dominio en absoluto —ni siquiera la pagina de mantenimiento—, asi que ningun
# otro campo del estado describe lo que recibe un visitante. Falto hasta la
# v1.3.5, y por eso una app sin vhost salia identica a una sana en las dos
# salidas del mismo comando.
check "sin vhost, false"  "false" "$(j "$(app web .state.served)" cmd_list)"
: > "$(nginx_file web)"; ln -sfn "$(nginx_file web)" "$(nginx_link web)"
check "con vhost, true"   "true"  "$(j "$(app web .state.served)" cmd_list)"
# El fichero sin el enlace no lo carga nginx: la web esta igual de muerta y el
# fichero engaña a quien mire solo sites-available.
rm -f "$(nginx_link web)"
check "el fichero solo no basta" "false" "$(j "$(app web .state.served)" cmd_list)"
rm -f "$(nginx_file web)"

section "orbit info --json"
check "es JSON válido"   "object" "$(j 'type' cmd_info web)"
check "nombre"           "web"    "$(j '.app.name' cmd_info web)"
check "config completa"  "$(printf '%s\n' "${ORBIT_APP_FIELDS[@]}" | wc -l)" \
                         "$(j '.app.config | length' cmd_info web)"
check "releases"         "2"      "$(j '.app.releases | length' cmd_info web)"
check "la más nueva primero" "20260102-000000" "$(j '.app.releases[0]' cmd_info web)"
# Sin app no puede abrir un selector: al otro lado no hay nadie que elija.
JSON="yes" run cmd_info >/dev/null 2>&1; r=$?
check "sin app, error"   "1"      "$r"

section "Valores difíciles de ida y vuelta"
# El mismo valor que obligó a escribir _q(): si algo lo expande por el camino,
# el cliente recibe el comando sin el puerto y la app no arranca.
load_app web
A_BUILD='pnpm build --out "dist" && echo ${PORT}'
A_START="node d'or.js"
save_app
check "comando con \${} y comillas" 'pnpm build --out "dist" && echo ${PORT}' \
                                    "$(j '.app.config.build' cmd_info web)"
check "comilla simple"   "node d'or.js" "$(j '.app.config.start' cmd_info web)"

section "Certificados"
check "sin certificado, null" "null" "$(j '.app.state.cert_days' cmd_info docs)"
# Con medio día de holgura: los días son enteros y se redondean hacia abajo,
# así que un '+30 days' exacto da 29 en cuanto pasa un segundo entre que la
# prueba calcula la fecha y la función mira el reloj.
FAKE_EXP="$(date -d '+30 days 12 hours' '+%b %e %H:%M:%S %Y GMT')"
check "días que quedan"  "30"     "$(j '.app.state.cert_days' cmd_info web)"
FAKE_EXP="$(date -d '-2 days -12 hours' '+%b %e %H:%M:%S %Y GMT')"
check "caducado, negativo" "-2"   "$(j '.app.state.cert_days' cmd_info web)"
FAKE_EXP="esto no es una fecha"
# Que openssl devuelva basura no puede romper la salida entera.
check "fecha ilegible"   "null"   "$(j '.app.state.cert_days' cmd_info web)"
FAKE_EXP="$(date -d '+30 days 12 hours' '+%b %e %H:%M:%S %Y GMT')"

section "orbit status --json"
check "es JSON válido"   "object" "$(j 'type' cmd_status)"
check "carga son 3"      "3"      "$(j '.host.load | length' cmd_status)"
check "carga es número"  "number" "$(j '.host.load[0] | type' cmd_status)"
check "memoria en kB"    "number" "$(j '.host.memory_kb.total | type' cmd_status)"
check "disco en %"       "number" "$(j '.host.disk_kb.use_percent | type' cmd_status)"
check "servicios"        "5"      "$(j '.services | length' cmd_status)"
check "el primero"       "nginx"  "$(j '.services[0].name' cmd_status)"
check "y las apps"       "2"      "$(j '.apps | length' cmd_status)"

section "orbit doctor --json"
# Se rellena a mano en vez de ejecutar el diagnóstico entero: aquí se prueba el
# contrato, no si este contenedor tiene nginx.
DOC_LEVEL=(ok warn error info); DOC_ID=(nginx disk ports "cert:web.test")
DOC_MSG=("todo bien" "disco al 90%" 'puertos "duplicados"' "quedan 30 días")
DOC_FIX=("" "" "usa orbit port" "")
# El quinto array dice cuáles sabe arreglar 'doctor --fix' solo. Aquí se deja
# a medias a propósito: un cliente tiene que poder distinguir «hay consejo» de
# «hay botón», y son cosas distintas.
DOC_ACT=("" "" "_fix_ports" "")
check "es JSON válido"   "object" "$(_doctor_json | jq -r 'type')"
check "cuatro avisos"    "4"      "$(_doctor_json | jq -r '.checks | length')"
check "nivel"            "error"  "$(_doctor_json | jq -r '.checks[2].level')"
check "identificador"    "cert:web.test" "$(_doctor_json | jq -r '.checks[3].id')"
check "mensaje escapado" 'puertos "duplicados"' "$(_doctor_json | jq -r '.checks[2].message')"
check "arreglo"          "usa orbit port" "$(_doctor_json | jq -r '.checks[2].fix')"
check "sin arreglo, null" "null"  "$(_doctor_json | jq -r '.checks[0].fix')"
# 'fixable' es lo que separa saber el arreglo de poder aplicarlo.
check "se puede arreglar"  "true"  "$(_doctor_json | jq -r '.checks[2].fixable')"
check "consejo sin botón"  "false" "$(_doctor_json | jq -r '.checks[1].fixable')"
check "lo que está bien, no" "false" "$(_doctor_json | jq -r '.checks[0].fixable')"
# 'info' cuenta como bien: los días que le quedan a un certificado vigente no
# son un problema que haya que resolver.
check "resumen ok"       "2"      "$(_doctor_json | jq -r '.summary.ok')"
check "resumen avisos"   "1"      "$(_doctor_json | jq -r '.summary.warn')"
check "resumen errores"  "1"      "$(_doctor_json | jq -r '.summary.error')"

section "orbit version --json"
# Lo primero que preguntará un cliente antes de fiarse del resto. La versión de
# Orbit y la del contrato van separadas: Orbit puede subir sin que el contrato
# cambie, y un cliente que las confunda se negaría a hablar sin motivo.
ORBIT_VERSION="1.1.0"
check "es JSON válido"   "object" "$(j 'type' cmd_version)"
check "versión"          "1.1.0"  "$(j '.version' cmd_version)"
check "contrato"         "1"      "$(j '.contract' cmd_version)"
check "y sin --json, plano" "orbit 1.1.0" "$(run cmd_version)"

section "orbit redirect list --json"
mkdir -p "$TMP/etc/redirects"
redir_file() { echo "$TMP/etc/redirects/$1.list"; }
printf '/precios /pricing 301\n/blog/* /noticias/* 302 noquery\n' > "$(redir_file web)"
check "es JSON válido"   "object" "$(j 'type' cmd_redirect list)"
check "dos reglas"       "2"      "$(j '.redirects | length' cmd_redirect list)"
check "de qué app"       "web"    "$(j '.redirects[0].app' cmd_redirect list)"
check "origen"           "/precios" "$(j '.redirects[0].from' cmd_redirect list)"
check "destino"          "/pricing" "$(j '.redirects[0].to' cmd_redirect list)"
check "código es número" "number" "$(j '.redirects[0].code | type' cmd_redirect list)"
check "y el 302"         "302"    "$(j '.redirects[1].code' cmd_redirect list)"
# 'noquery' se publica como lo que significa —si la cadena de consulta viaja—
# y no como el nombre interno de la bandera.
check "conserva la query" "true"  "$(j '.redirects[0].query' cmd_redirect list)"
check "y la descarta"    "false"  "$(j '.redirects[1].query' cmd_redirect list)"
# Una redirección de dominio entero es otra cosa: se configura y se deshace
# distinto, así que el cliente tiene que poder distinguirlas.
mkapp viejo.com redirect "" viejo.com
load_app viejo.com; A_REDIRECT="https://nuevo.com"; A_REDIRECT_CODE="308"; save_app
check "dominio entero"   "domain" "$(j '.redirects[] | select(.app=="viejo.com") | .kind' cmd_redirect list)"
check "y su destino"     "https://nuevo.com" "$(j '.redirects[] | select(.app=="viejo.com") | .to' cmd_redirect list)"
check "de ruta"          "path path" "$(j '[.redirects[] | select(.app=="web") | .kind] | join(" ")' cmd_redirect list)"
rm -f "$TMP/etc/apps/viejo.com.conf"
# Filtrar por app sigue funcionando igual que en la tabla.
check "filtrando por app" "2"     "$(j '.redirects | length' cmd_redirect list web)"
check "una app sin reglas" "0"    "$(j '.redirects | length' cmd_redirect list docs)"

section "orbit watch status --json"
WATCH_STATE="$TMP/watch.state"
{ printf '# cabecera\n'
  printf 'app:web ok 100 0 0\n'
  printf 'app:docs rendido 200 3 250\n'
  printf 'cert:web.test caducando 300 0 0\n'; } > "$WATCH_STATE"
_watch_state_load
check "es JSON válido"   "object" "$(_watch_report_json | jq -r 'type')"
check "tres sujetos"     "3"      "$(_watch_report_json | jq -r '.subjects | length')"
# El sujeto va con su prefijo: es la clave con la que el watchdog lo guarda.
check "ordenados"        "app:docs" "$(_watch_report_json | jq -r '.subjects[0].subject')"
check "estado"           "rendido" "$(_watch_report_json | jq -r '.subjects[0].state')"
check "intentos"         "3"      "$(_watch_report_json | jq -r '.subjects[0].tries')"
check "y es número"      "number" "$(_watch_report_json | jq -r '.subjects[0].tries | type')"
check "resumen: caídas"  "1"      "$(_watch_report_json | jq -r '.summary.down')"
check "resumen: avisos"  "1"      "$(_watch_report_json | jq -r '.summary.warning')"
check "resumen: total"   "3"      "$(_watch_report_json | jq -r '.summary.total')"

section "orbit db list --json"
# psql de mentira: aquí se prueba el formato de salida, no PostgreSQL.
sudo() { printf 'orbit_web|deploy|8388608\nmi_tienda|tienda|1024\n'; }
check "es JSON válido"   "object" "$(j 'type' cmd_db list)"
check "dos bases"        "2"      "$(j '.databases | length' cmd_db list)"
check "nombre"           "orbit_web" "$(j '.databases[0].name' cmd_db list)"
check "dueño"            "deploy" "$(j '.databases[0].owner' cmd_db list)"
# En bytes y como número: quien pinte una barra necesita el número, y de
# '8192 kB' no se vuelve atrás sin adivinar.
check "tamaño es número" "number" "$(j '.databases[0].size_bytes | type' cmd_db list)"
check "tamaño"           "8388608" "$(j '.databases[0].size_bytes' cmd_db list)"
unset -f sudo

section "Los subcomandos que no serializan lo dicen"
JSON="yes" run cmd_redirect add web /a /b >/dev/null 2>&1; r=$?
check "redirect add"     "1"      "$r"
JSON="yes" run cmd_watch enable   >/dev/null 2>&1; r=$?
check "watch enable"     "1"      "$r"
JSON="yes" run cmd_db backup web  >/dev/null 2>&1; r=$?
check "db backup"        "1"      "$r"

section "El .env no sale por aquí"
mkdir -p "$TMP/apps/web/shared"
printf 'SECRETO=contraseña-de-verdad\nexport OTRA=x\n' > "$TMP/apps/web/shared/.env"
check "sólo los nombres" "2"      "$(j '.keys | length' cmd_env list web)"
check "el primero"       "SECRETO" "$(j '.keys[0]' cmd_env list web)"
check "con export"       "OTRA"   "$(j '.keys[1]' cmd_env list web)"
# La prueba que de verdad importa: que el valor no viaje. Un panel que enseñe
# el .env entero es un panel que filtra la contraseña en una captura.
SALIDA="$(JSON=yes run cmd_env list web 2>/dev/null)"
check "sin valores"      "0"      "$(grep -c 'contraseña-de-verdad' <<<"$SALIDA")"
: > "$TMP/apps/web/shared/.env"
check "sin variables"    "0"      "$(j '.keys | length' cmd_env list web)"
# Los demás subcomandos no tienen nada que serializar y deben decirlo, no
# fingir que su salida de siempre es JSON.
JSON="yes" run cmd_env get web SECRETO >/dev/null 2>&1; r=$?
check "env get lo rechaza" "1"    "$r"

section "El mensaje de rechazo nombra a todos los que sí hablan"
# Este mensaje es lo único que ve un cliente que se equivoca de comando. Durante
# un tiempo nombraba cuatro de los nueve, así que quien probaba 'db list --json'
# y leía la respuesta concluía que no existía. La prueba cruza las dos listas
# para que no se vuelvan a separar.
for c in list info status doctor top traffic deploy version env db redirect watch queue; do
  run _json_capable "$c"; r=$?
  check "«$c» habla JSON"  "0" "$r"
done
# Y cada uno tiene que aparecer en el texto que se le enseña a la gente.
for c in list info status doctor top traffic deploy version; do
  check "el mensaje nombra $c" "1" "$(grep -c "\b$c\b" <<<"$(_json_cmds_help)")"
done
for c in env db redirect watch queue; do
  check "el mensaje nombra $c" "1" "$(grep -c "'$c " <<<"$(_json_cmds_help)")"
done

section "Con --json, por la salida normal no va nada más"
# Un adorno para personas delante del objeto convierte 'orbit … --json | jq' en
# un error de sintaxis. Le pasó a 'watch status', que saludaba con un ✔.
JSON="yes"
WS_STATE=(); WS_SINCE=(); WS_TRIES=(); WS_LAST=()
systemctl() { return 0; }
SALIDA="$(_watch_report 2>/dev/null)"
check "watch: es JSON"        "object" "$(jq -r 'type' <<<"$SALIDA" 2>/dev/null)"
check "sin el saludo delante" "0"      "$(grep -c 'Temporizador' <<<"$SALIDA")"
# Y el dato que daba esa línea no se pierde: pasa a ser un campo.
check "dice si está activo"   "true"   "$(jq -r '.timer_active' <<<"$SALIDA")"
systemctl() { return 1; }
check "y si está parado"      "false"  "$(_watch_report 2>/dev/null | jq -r '.timer_active')"
unset -f systemctl
JSON="no"

section "«No he podido preguntar» no es «no hay ninguna»"
# 'orbit db list --json' devolvía {"databases":[]} con código 0 cuando
# PostgreSQL no contestaba. Sin --json el mismo caso sale con error, y un
# script de copias que lea la lista vacía concluye que no hay nada que salvar.
JSON="yes"
need_root() { :; }
sudo() { return 2; }        # psql no contesta
SALIDA="$(cmd_db list 2>/dev/null)"; r=$?
check "no inventa una lista" "0" "$(grep -c 'databases' <<<"$SALIDA")"
check "y sale con error"     "1" "$r"
check "sin ensuciar stdout"  ""  "$SALIDA"
SALIDA="$(cmd_db list 2>&1 >/dev/null)"
check "lo dice por stderr"   "1" "$(grep -c 'No he podido preguntarle a PostgreSQL' <<<"$SALIDA")"
# Y cuando sí contesta, la lista sale bien.
sudo() { printf 'midb|dueno|123456\notra|dueno|7\n'; }
SALIDA="$(cmd_db list 2>/dev/null)"
check "dos bases"            "2"      "$(jq '.databases|length' <<<"$SALIDA")"
check "con su tamaño"        "123456" "$(jq -r '.databases[0].size_bytes' <<<"$SALIDA")"
check "el tamaño es número"  "number" "$(jq -r '.databases[0].size_bytes|type' <<<"$SALIDA")"
sudo() { printf '\n'; }     # servidor sano, sin bases
check "vacío de verdad, []"  "0"      "$(cmd_db list 2>/dev/null | jq '.databases|length')"
unset -f sudo need_root
JSON="no"

report
