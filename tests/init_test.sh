#!/usr/bin/env bash
# 'orbit init': escribir un orbit.json en un proyecto con lo que se detecte.
#   bash tests/init_test.sh
#
# Lo que más importa aquí no es el fichero, que se ve a simple vista, sino las
# dos cosas que serían caras: que lo escrito se vuelva a leer igual —es el
# reverso exacto de _read_descriptor, y si los dos lados se separan el
# descriptor deja de significar lo que dice— y que la rama de repuesto de la
# detección no acabe congelada en el repositorio de nadie.
#
# shellcheck disable=SC2034  # asigna variables A_* que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LOG_FILE="$TMP/orbit.log"
PROY="$TMP/proy"

# Un proyecto de mentira, del tipo que sea, recién hecho.
proyecto() { # proyecto <subdir> [ficheros que crear…]
  rm -rf "$PROY"; mkdir -p "$PROY"
}
init() { # init <argumentos…> -> deja la salida en $SALIDA y el código en $r
  SALIDA="$(run cmd_init "$@" 2>&1)"; r=$?
}

section "El comando decide antes de elevarse a root"
# 'orbit init' escribe dentro del repositorio de quien lo ejecuta, así que no
# se auto-eleva: un orbit.json de root en un checkout ajeno obliga a usar sudo
# hasta para borrarlo. La decisión la toma _first_word ANTES del sudo, y por
# eso tiene que saber distinguir un comando de un valor de opción.
check "el comando pelado"     "init"   "$(_first_word init)"
check "con opciones delante"  "init"   "$(_first_word --json --yes init)"
# La trampa: '--lang en' lleva valor, y confundir ese valor con el comando
# haría que 'orbit --lang init …' se saltara la elevación de cualquier otro.
check "el valor no es comando" "init"  "$(_first_word --lang en init)"
check "y otro comando, otro"  "deploy" "$(_first_word deploy web)"
check "sin comando, nada"     ""       "$(_first_word --eva)"

section "Un proyecto reconocido se escribe tal cual"
proyecto
printf '{"scripts":{"build":"astro build"},"dependencies":{"astro":"^4"}}\n' > "$PROY/package.json"
mkdir -p "$PROY/dist"
init "$PROY"
check "termina bien"     "0" "$r"
check "escribe el fichero" "1" "$([[ -f "$PROY/orbit.json" ]] && echo 1 || echo 0)"
check "y lo dice"        "1" "$(grep -c 'Escrito' <<<"$SALIDA")"
if command -v jq >/dev/null; then
  check "es JSON válido"  "0" "$(jq -e . "$PROY/orbit.json" >/dev/null 2>&1; echo $?)"
  check "con su tipo"     "static" "$(jq -r '.type' "$PROY/orbit.json")"
  check "y su carpeta web" "dist"  "$(jq -r '.outdir' "$PROY/orbit.json")"
  # Sólo lo que tiene valor: una clave vacía en un fichero que alguien va a
  # editar a mano invita a rellenarla con cualquier cosa.
  check "sin claves vacías" "0" "$(jq -r 'to_entries[] | select(.value == "") | .key' "$PROY/orbit.json" | wc -l)"

  section "Lo escrito se vuelve a leer igual"
  # El ida y vuelta es lo que hace que esto valga para algo: 'orbit init' es el
  # reverso de _read_descriptor, y si escribiera una clave que el lector no
  # entiende, el fichero diría una cosa y el despliegue haría otra.
  A_TYPE=""; A_OUTDIR=""; A_BUILD=""; A_SPA=""; A_APPDIR=""; A_DOCROOT=""; A_PHP=""
  A_START=""; A_SHARED=""; A_ENV_FILE=""; A_ENV_SPEC=""
  # Sin 'run': eso corre en un subshell y las variables que fija el lector no
  # saldrían de él — la comprobación miraría un valor vacío y pasaría por los
  # pelos si algún día se esperara vacío.
  _read_descriptor "$PROY" >/dev/null 2>&1; r=$?
  check "el lector lo acepta" "0" "$r"
  check "mismo tipo"          "static" "$A_TYPE"
  check "misma carpeta web"   "dist"   "$A_OUTDIR"
else
  echo "  (falta jq: me salto la comprobación del contenido y del ida y vuelta)"
fi

section "No se pisa nada sin permiso"
# Dentro puede haber un bloque 'env' escrito a mano que la detección no sabe
# reproducir. Perderlo en silencio sería mucho peor que no escribir el fichero.
printf '{"type":"node","env":{"vars":{"TOKEN":{"generate":"hex:24"}}}}\n' > "$PROY/orbit.json"
init "$PROY"
check "se niega"         "1" "$r"
check "y dice cómo"      "1" "$(grep -q -- '--force' <<<"$SALIDA" && echo 1 || echo 0)"
check "sin tocar el suyo" "1" "$(grep -c 'TOKEN' "$PROY/orbit.json")"
init "$PROY" --force
check "con --force sí"   "0" "$r"
check "y ahora es el nuevo" "0" "$(grep -c 'TOKEN' "$PROY/orbit.json")"

section "--force regenera desde el proyecto, no desde el fichero viejo"
# detect_stack termina leyendo el orbit.json que haya, así que con el fichero
# viejo todavía en su sitio salía un híbrido: el tipo, el arranque y la carpeta
# web de antes mezclados con el build recién detectado — un fichero que no
# describía ni el proyecto ni lo que había antes. Lo cazó la revisión del PR
# #12, y esta sección es la que lo fija.
proyecto
printf '{"scripts":{"build":"astro build"},"dependencies":{"astro":"^4"}}\n' > "$PROY/package.json"
mkdir -p "$PROY/dist"
printf '{"type":"node","start":"node viejo.js","outdir":"antiguo"}\n' > "$PROY/orbit.json"
init "$PROY" --force
check "termina bien"       "0" "$r"
if command -v jq >/dev/null; then
  check "el tipo, el detectado"  "static" "$(jq -r '.type' "$PROY/orbit.json")"
  check "la carpeta web también" "dist"   "$(jq -r '.outdir' "$PROY/orbit.json")"
  check "y sin el arranque viejo" "null"  "$(jq -r '.start' "$PROY/orbit.json")"
fi
# El guarda es de esa carpeta y de ese momento: dejarlo puesto haría que el
# comando siguiente detectara ignorando un descriptor que sí manda.
check "el guarda queda apagado" "" "$DETECT_IGNORA_DESC"

section "La rama de repuesto no se congela en el repositorio"
# Es la lección de §18.8 llevada a su peor versión: la rama de repuesto deja
# 'static' sirviendo la raíz, o sea el código fuente, y al escribirlo en el
# orbit.json la decisión queda tomada para siempre — el descriptor pisa a la
# detección, así que el aviso de esa rama no volvería a salir nunca.
proyecto
printf 'const x = 1;\n' > "$PROY/servidor.js"
init "$PROY"
check "se niega"          "1" "$r"
check "sin escribir nada" "0" "$([[ -f "$PROY/orbit.json" ]] && echo 1 || echo 0)"
check "y explica por qué" "1" "$(grep -q 'código fuente' <<<"$SALIDA" && echo 1 || echo 0)"
# Pero un sitio que de verdad es HTML sí: ahí servir la raíz es lo correcto, y
# negarse sería negarle el comando a quien tiene el caso más simple de todos.
proyecto
printf '<h1>hola</h1>\n' > "$PROY/index.html"
init "$PROY"
check "un HTML sí pasa"   "0" "$r"
check "y se escribe"      "1" "$([[ -f "$PROY/orbit.json" ]] && echo 1 || echo 0)"

section "Los argumentos"
init "$TMP/no-existe"
check "un directorio que no está" "1" "$r"
init "$PROY" --inventada
check "opción desconocida"        "1" "$r"
init "$PROY" otro
check "dos directorios"           "1" "$r"
init --help
check "la ayuda sale bien"        "0" "$r"
check "y explica el --force"      "1" "$(grep -q -- '--force' <<<"$SALIDA" && echo 1 || echo 0)"

report
