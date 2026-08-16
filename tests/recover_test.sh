#!/usr/bin/env bash
# Recuperación de builds: reconocer el fallo, arreglarlo y no pasarse de listo.
#   bash tests/recover_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, BUILD_*…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
NOTIFY_CONF="$TMP/notify.conf"          # sin configurar: notify no hace nada
DEPLOY_USER="$(id -un)"

log_con() { # log_con <líneas…> -> ruta a un log de build de mentira
  local f; f="$(mktemp -p "$TMP")"
  printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}

section "Reconocer qué ha bloqueado pnpm"
# La línea exacta que escupe pnpm 11.20, comprobada contra el binario real.
L="$(log_con 'Progress: resolved 251, reused 0' \
             '[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: esbuild@0.28.1' \
             'Run "pnpm approve-builds" to pick which dependencies should be allowed to run scripts.')"
check "un paquete"        "esbuild" "$(_recover_pnpm_pkgs "$L")"
L="$(log_con '[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: core-js@3.39.0, esbuild@0.28.1')"
check "dos paquetes"      "core-js esbuild" "$(_recover_pnpm_pkgs "$L" | tr '\n' ' ' | sed 's/ $//')"
# La arroba de delante es del ámbito, no de la versión: cortar por la primera
# dejaría el nombre vacío y se escribiría un allowBuilds sin paquete.
L="$(log_con '[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: @parcel/watcher@2.4.1, sharp@0.33.5')"
check "paquete con ámbito" "@parcel/watcher sharp" "$(_recover_pnpm_pkgs "$L" | tr '\n' ' ' | sed 's/ $//')"
# Si algún día pnpm colorea ese mensaje, la firma sigue estando.
L="$(log_con "$(printf '\033[31m[ERR_PNPM_IGNORED_BUILDS]\033[0m Ignored build scripts: \033[1mesbuild@0.28.1\033[0m')")"
check "con colores"       "esbuild" "$(_recover_pnpm_pkgs "$L")"
L="$(log_con 'Error: Cannot find module "./config"' 'Build failed')"
check "otro fallo, nada"  ""        "$(_recover_pnpm_pkgs "$L")"
# Lo que sale del log acaba escrito en un fichero de configuración, así que lo
# que no parezca un nombre de paquete no pasa de aquí.
L="$(log_con 'Ignored build scripts: mal$nombre@1.0.0, bueno@2.0.0')"
check "descarta lo raro"  "bueno"   "$(_recover_pnpm_pkgs "$L")"

section "Escribir el allowBuilds que pide pnpm 11"
REL="$TMP/rel"
ws() { # ws <contenido inicial, o nada> ; deja la release lista
  rm -rf "$REL"; mkdir -p "$REL"
  [[ $# -gt 0 ]] && printf '%b' "$1" > "$REL/pnpm-workspace.yaml"
  return 0
}
yaml() { cat "$REL/pnpm-workspace.yaml" 2>/dev/null; }

ws
run _pnpm_ws_apply "$REL" esbuild; r=$?
check "sin fichero, lo crea" "0"    "$r"
check "contenido"         "allowBuilds:|  'esbuild': true" "$(yaml | tr '\n' '|' | sed 's/|$//')"

# El caso que costó un despliegue entero: **pnpm 11 escribe él mismo el
# fichero cuando falla**, con el valor sin decidir. Una versión anterior veía
# ese 'allowBuilds:', daba por hecho que venía del repositorio, se apartaba por
# respeto y el reintento fallaba exactamente igual.
ws 'allowBuilds:\n  esbuild: set this to true or false\n'
run _pnpm_ws_apply "$REL" esbuild >/dev/null; r=$?
check "rellena el hueco de pnpm" "0" "$r"
check "y queda en true"   "1"       "$(grep -cx "  'esbuild': true" "$REL/pnpm-workspace.yaml")"
check "sin dejar el hueco" "0"      "$(grep -c 'set this to' "$REL/pnpm-workspace.yaml")"

# En un monorepo el fichero ya existe y lleva los globs de los paquetes:
# sobrescribirlo se llevaría por delante el workspace entero.
ws "packages:\n  - 'apps/*'\n"
run _pnpm_ws_apply "$REL" esbuild sharp >/dev/null; r=$?
check "añade el bloque"   "0"       "$r"
check "los globs siguen"  "1"       "$(grep -c "apps/\*" "$REL/pnpm-workspace.yaml")"
check "y los dos paquetes" "2"      "$(grep -cE "^  '(esbuild|sharp)': true$" "$REL/pnpm-workspace.yaml")"

# Bloque a medias: se añade sólo lo que falta, sin reescribir lo que ya estaba.
ws "packages:\n  - 'apps/*'\nallowBuilds:\n  sharp: true\n"
run _pnpm_ws_apply "$REL" esbuild sharp >/dev/null; r=$?
check "completa lo que falta" "0"   "$r"
check "sharp como estaba"  "1"      "$(grep -cx "  sharp: true" "$REL/pnpm-workspace.yaml")"
check "y esbuild nuevo"    "1"      "$(grep -cx "  'esbuild': true" "$REL/pnpm-workspace.yaml")"

# Un fichero sin salto de línea final se comería la clave nueva pegándola a la
# última línea, y el YAML resultante no diría lo que parece.
ws "packages:\n  - 'apps/*'"
run _pnpm_ws_apply "$REL" esbuild >/dev/null
check "sin salto final"   "1"       "$(grep -cx "allowBuilds:" "$REL/pnpm-workspace.yaml")"
check "y el glob entero"  "1"       "$(grep -cx "  - 'apps/\*'" "$REL/pnpm-workspace.yaml")"

# El bloque no tiene por qué ser el último del fichero.
ws "allowBuilds:\n  esbuild: set this to true or false\npackages:\n  - 'apps/*'\n"
run _pnpm_ws_apply "$REL" esbuild >/dev/null
check "bloque en medio"   "1"       "$(grep -cx "  'esbuild': true" "$REL/pnpm-workspace.yaml")"
check "sin tocar lo de abajo" "1"   "$(grep -cx "  - 'apps/\*'" "$REL/pnpm-workspace.yaml")"

# Ya concedido: no hay nada que cambiar, y reescribir el fichero por gusto
# sólo serviría para mover la fecha.
ws "allowBuilds:\n  'esbuild': true\n"
run _pnpm_ws_apply "$REL" esbuild >/dev/null; r=$?
check "ya estaba, no cambia" "1"    "$r"

# Un 'false' es una decisión de quien escribió el repositorio, no un hueco.
ws "allowBuilds:\n  esbuild: false\n"
run _pnpm_ws_apply "$REL" esbuild >/dev/null; r=$?
check "denegado, se respeta" "1"    "$r"
check "y sigue en false"  "1"       "$(grep -cx "  esbuild: false" "$REL/pnpm-workspace.yaml")"
check "y se sabe cuál es" "esbuild" "$(_pnpm_ws_denied "$REL/pnpm-workspace.yaml" esbuild sharp)"

# Los nombres con ámbito llevan una arroba, que en YAML es carácter reservado:
# sin comillas, '@parcel/watcher: true' no es un documento válido.
ws
run _pnpm_ws_apply "$REL" '@parcel/watcher' >/dev/null
check "nombre con ámbito" "1"       "$(grep -cx "  '@parcel/watcher': true" "$REL/pnpm-workspace.yaml")"

# Sin paquetes no hay nada que escribir, y desde luego no un allowBuilds vacío.
ws
run _pnpm_ws_apply "$REL" >/dev/null; r=$?
check "sin paquetes, nada" "1"      "$r"
check "ni fichero"        "0"       "$([[ -f "$REL/pnpm-workspace.yaml" ]] && echo 1 || echo 0)"

section "Cuánta memoria darle a Node"
mem() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\n' "$1" "$2" > "$TMP/mem"; printf '%s' "$TMP/mem"; }
check "8 GB libres → 4096 (tope)" "4096" "$(_recover_heap_mb "$(mem 16000000 8000000)")"
check "3 GB libres → 2250"        "2250" "$(_recover_heap_mb "$(mem 4000000 3072000)")"
# Con poca memoria libre, más heap no salva el build: sólo cambia el error por
# una muerte a manos del OOM killer, que además se lleva lo que estaba sirviendo.
# shellcheck disable=SC2218  # aquí se llama a la función real de 'orbit'; más
# abajo se sustituye por un doble para probar otra cosa, y shellcheck ve esa
# definición posterior y cree que es la única.
run _recover_heap_mb "$(mem 1000000 700000)" >/dev/null; r=$?
check "700 MB libres → no hay remedio" "1" "$r"
# shellcheck disable=SC2218  # ídem: la real ahora, el doble más abajo.
run _recover_heap_mb "$TMP/no-existe" >/dev/null; r=$?
check "sin poder mirarlo, tampoco"     "1" "$r"

section "Aplicar lo aprendido antes de compilar"
mkapp web next 3001 web.test
load_app web
REL="$TMP/rel"; rm -rf "$REL"; mkdir -p "$REL"
run _build_prepare "$REL" >/dev/null
check "sin nada aprendido, no escribe" "0" "$([[ -f "$REL/pnpm-workspace.yaml" ]] && echo 1 || echo 0)"
A_PNPM_ALLOW="esbuild sharp"; save_app
load_app web
_build_prepare "$REL" >/dev/null
check "lo escribe"        "2"       "$(grep -cE "^  '(esbuild|sharp)': true$" "$REL/pnpm-workspace.yaml")"
# Y no lo escribe dos veces: los despliegues se repiten y el fichero también.
_build_prepare "$REL" >/dev/null
check "es idempotente"    "1"       "$(grep -cx "allowBuilds:" "$REL/pnpm-workspace.yaml")"

section "El entorno del build"
# El reintento tiene que ser el mismo entorno que el intento, más el remedio.
sudo() { printf '%s\n' "${*: -1}"; }        # el último argumento es el comando
load_app web; A_NODE_HEAP=""
check "sin heap, sin NODE_OPTIONS" "0" "$(_build_run "$REL" | grep -c NODE_OPTIONS)"
check "pero sí el resto"           "1" "$(_build_run "$REL" | grep -c 'CI=1')"
A_NODE_HEAP="2048"
check "con heap"          "1"       "$(_build_run "$REL" | grep -c -- '--max-old-space-size=2048')"
# La expansión tiene que llegar sin resolver al shell de destino: se resuelve
# allí, después de cargar el .env, y por eso un NODE_OPTIONS de la app gana.
check "respeta el de la app" "1"    "$(_build_run "$REL" | grep -cF '${NODE_OPTIONS:-}')"
A_NODE_HEAP=""

section "Decidir si merece la pena reintentar"
ws
load_app web; A_PNPM_ALLOW=""; A_NODE_HEAP=""; save_app; load_app web
L="$(log_con '[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: esbuild@0.28.1')"
run _build_recover web "$REL" "$L" >/dev/null; r=$?
check "pnpm: reintenta"   "0"       "$r"
_build_recover web "$REL" "$L" >/dev/null   # otra vez, ya sin subshell, para ver el efecto
check "y recuerda"        "esbuild" "$(campo() { load_app web; printf '%s' "$A_PNPM_ALLOW"; }; campo)"

# Un paquete nuevo se suma a los que ya se sabían, no los sustituye. Cada
# recuperación es un despliegue distinto, así que se recarga la app: es lo que
# hace cmd_deploy, y _build_recover cuenta con tenerla cargada.
L="$(log_con '[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: sharp@0.33.5')"
load_app web; _build_recover web "$REL" "$L" >/dev/null
load_app web
check "une, no pisa"      "esbuild sharp" "$A_PNPM_ALLOW"
load_app web; _build_recover web "$REL" "$L" >/dev/null
load_app web
check "sin repetir"       "esbuild sharp" "$A_PNPM_ALLOW"

# Si el repositorio deniega ese paquete a propósito, no hay remedio que
# aplicar: reintentar sería llevarle la contraria a quien escribió el repo.
ws "allowBuilds:\n  denegado: false\n"
L="$(log_con '[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: denegado@1.0.0')"
SALIDA="$(_build_recover web "$REL" "$L" 2>&1)" && r=0 || r=$?
check "denegado, no reintenta" "1"  "$r"
check "y lo dice"         "1"       "$(grep -c 'deniega a propósito' <<<"$SALIDA")"
check "sin cambiar el fichero" "1"  "$(grep -cx "  denegado: false" "$REL/pnpm-workspace.yaml")"

# El fichero ya lo permitía y pnpm sigue quejándose: el remedio no llega a
# donde tiene que llegar, y repetirlo sólo repetiría el error.
ws "allowBuilds:\n  'raro': true\n"
L="$(log_con '[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: raro@1.0.0')"
SALIDA="$(_build_recover web "$REL" "$L" 2>&1)" && r=0 || r=$?
check "ya permitido, no reintenta" "1" "$r"
check "y avisa de dónde mirar" "1"  "$(grep -c 'raíz del repositorio' <<<"$SALIDA")"
ws

section "Cuándo NO hay que reintentar"
L="$(log_con 'Error: Cannot find module "./config"')"
run _build_recover web "$REL" "$L" >/dev/null; r=$?
# Un error de código no se arregla repitiendo: reintentar sería tardar el
# doble en dar la misma noticia.
check "fallo sin firma"   "1"       "$r"
run _build_recover web "$REL" "$TMP/no-existe" >/dev/null; r=$?
check "sin log"           "1"       "$r"
BUILD_RECOVERY="no"
L="$(log_con '[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: esbuild@0.28.1')"
run _build_recover web "$REL" "$L" >/dev/null; r=$?
check "desactivado"       "1"       "$r"
run _build_prepare "$REL" >/dev/null; r=$?
check "tampoco prepara"   "0"       "$r"
BUILD_RECOVERY="yes"

section "Fallos que no se arreglan, pero se explican"
# Las firmas están tomadas de la salida real de pnpm 11.20, npm 10.9 y yarn
# 4.5, no de memoria. Si alguna cambiara, esto deja de encajar en silencio, y
# por eso la prueba las escribe literales.
load_app web; A_PKG="pnpm"
consejo() { _build_advise "$(log_con "$@")" 2>&1; }

S="$(consejo '[ERR_PNPM_OUTDATED_LOCKFILE] Cannot install with "frozen-lockfile" because pnpm-lock.yaml is not up to date with <ROOT>/package.json')"
check "pnpm: lockfile viejo" "1" "$(grep -c 'no coincide con el package.json' <<<"$S")"
# 'git add <lockfile>' y no 'git commit -am': lo segundo se llevaría por
# delante cualquier otro fichero tocado que hubiera en el árbol de trabajo.
check "y dice qué ejecutar"  "1" "$(grep -c 'pnpm install && git add pnpm-lock.yaml' <<<"$S")"
check "sin arrastrar lo demás" "0" "$(grep -c 'commit -am' <<<"$S")"
check "y dónde está el porqué" "1" "$(grep -c '14.6' <<<"$S")"
# El error que comete todo el mundo: arreglarlo dentro del servidor, donde
# cache/ se resetea en cada despliegue y las releases no llevan .git.
check "avisa de que aquí no vale" "1" "$(grep -c 'git reset --hard' <<<"$S")"
check "y dice cómo seguir"   "1" "$(grep -c 'orbit deploy' <<<"$S")"

# Con el detalle de pnpm delante, el consejo nombra el paquete y la razón.
DRIFT_ADD=(); DRIFT_BAD=("lodash (dependencies)")
S="$(consejo '[ERR_PNPM_OUTDATED_LOCKFILE] Cannot install with "frozen-lockfile"')"
check "nombra el paquete"    "1" "$(grep -c 'lodash' <<<"$S")"
# Que Orbit no lo arregle solo es una decisión, no una carencia, y se explica.
check "y por qué no lo hace" "1" "$(grep -c 'no ha decidido nadie' <<<"$S")"
DRIFT_BAD=("sin-jq")
S="$(consejo '[ERR_PNPM_OUTDATED_LOCKFILE] Cannot install with "frozen-lockfile"')"
check "sin jq, lo dice"      "1" "$(grep -c 'sin jq' <<<"$S")"
check "y cómo instalarlo"    "1" "$(grep -c 'apt-get install -y jq' <<<"$S")"
# Sin recuperación por medio, los nombres se sacan del log igualmente.
DRIFT_ADD=(); DRIFT_BAD=()
S="$(consejo '[ERR_PNPM_OUTDATED_LOCKFILE] Cannot install with "frozen-lockfile"' \
             '* 1 dependencies are mismatched:' \
             '  - ms (lockfile: ^2.1.3, manifest: ^2.0.0)')"
check "saca el nombre del log" "1" "$(grep -c 'ms' <<<"$S")"
check "y qué le pasa"        "1" "$(grep -c 'versión pedida' <<<"$S")"
DRIFT_ADD=(); DRIFT_BAD=()

S="$(consejo 'npm error `npm ci` can only install packages when your package.json and package-lock.json or npm-shrinkwrap.json are in sync.')"
check "npm: lockfile viejo"  "1" "$(grep -c 'no coincide' <<<"$S")"
S="$(consejo '➤ YN0028: · The lockfile would have been modified by this install, which is explicitly forbidden.')"
check "yarn: lockfile viejo" "1" "$(grep -c 'no coincide' <<<"$S")"

S="$(consejo '[ERR_PNPM_NO_LOCKFILE] Cannot install with "frozen-lockfile" because pnpm-lock.yaml is absent')"
check "falta el lockfile"    "1" "$(grep -c 'no trae pnpm-lock.yaml' <<<"$S")"
# La causa casi siempre es la misma y merece nombrarse.
check "apunta al gitignore"  "1" "$(grep -c 'check-ignore' <<<"$S")"
S="$(consejo 'npm error The `npm ci` command can only install with an existing package-lock.json or npm-shrinkwrap.json')"
A_PKG="npm"
S="$(consejo 'npm error The `npm ci` command can only install with an existing package-lock.json or npm-shrinkwrap.json')"
check "y con el nombre de npm" "1" "$(grep -c 'no trae package-lock.json' <<<"$S")"
A_PKG="pnpm"

# El disco lleno provoca fallos raros más abajo: si se mirara al final se daría
# el consejo del síntoma en vez del de la causa.
S="$(consejo 'ENOSPC: no space left on device, write' '[ERR_PNPM_OUTDATED_LOCKFILE] no está al día')"
check "disco lleno gana"     "1" "$(grep -c 'sin espacio en disco' <<<"$S")"
check "y no habla del lockfile" "0" "$(grep -c 'no coincide' <<<"$S")"

# Hugo no lo instala Orbit —es un binario que la mayoría de servidores no
# necesita—, así que cuando falta hay que decir exactamente cómo ponerlo.
S="$(consejo '/bin/bash: line 1: hugo: command not found')"
check "falta hugo"           "1" "$(grep -c 'Hugo no está instalado' <<<"$S")"
check "y dice cómo instalarlo" "1" "$(grep -c 'apt-get install -y hugo' <<<"$S")"
# La versión de Ubuntu va por detrás y con temas modernos no basta.
check "y avisa de la versión" "1" "$(grep -c 'releases' <<<"$S")"

# adapter-auto compila en Vercel y falla en un VPS, y el mensaje de SvelteKit
# no dice cuál instalar en su lugar.
A_PKG="pnpm"
S="$(consejo 'Error: Could not detect a supported production environment.' 'See https://svelte.dev/docs/kit/adapter-auto')"
check "sveltekit adapter-auto" "1" "$(grep -c 'adapter-auto' <<<"$S")"
check "propone adapter-node" "1" "$(grep -c 'pnpm add -D @sveltejs/adapter-node' <<<"$S")"
check "y el estático"        "1" "$(grep -c 'adapter-static' <<<"$S")"

S="$(consejo 'npm error code EBADENGINE' 'npm error engine Unsupported engine')"
check "versión de Node"      "1" "$(grep -c "versión de Node" <<<"$S")"
check "y dice cuál hay aquí" "1" "$(grep -c 'El servidor tiene Node' <<<"$S")"

check "un fallo cualquiera, silencio" "" "$(consejo 'TypeError: undefined is not a function')"
check "sin log, silencio"    ""  "$(_build_advise "$TMP/no-existe" 2>&1)"
# Se llama justo antes de abortar: si devolviera algo distinto de 0, errexit se
# llevaría por delante el mensaje que explica por qué se aborta.
run _build_advise "$(log_con 'nada reconocible')" >/dev/null 2>&1; r=$?
check "nunca falla"          "0"  "$r"

section "Memoria: se avisa aunque no haya remedio"
load_app web; A_NODE_HEAP=""; save_app; load_app web
_recover_heap_mb() { return 1; }            # servidor sin memoria que ofrecer
L="$(log_con 'FATAL ERROR: Ineffective mark-compacts near heap limit' \
             'Allocation failed - JavaScript heap out of memory')"
SALIDA="$(_build_recover web "$REL" "$L" 2>&1)" && r=0 || r=$?
check "no reintenta a ciegas" "1"   "$r"
check "pero lo explica"   "1"       "$(grep -c 'no queda suficiente libre' <<<"$SALIDA")"
check "y dice qué hacer"  "1"       "$(grep -c 'swap' <<<"$SALIDA")"
check "sin inventarse heap" ""      "$(load_app web; printf '%s' "$A_NODE_HEAP")"

_recover_heap_mb() { printf '2048'; }       # ahora sí hay memoria
run _build_recover web "$REL" "$L" >/dev/null; r=$?
check "con memoria, reintenta" "0"  "$r"
_build_recover web "$REL" "$L" >/dev/null
check "y la recuerda"     "2048"    "$(load_app web; printf '%s' "$A_NODE_HEAP")"

# ── El lockfile que no cuadra con el package.json ────────────────────────
#
# Las cinco firmas de abajo son la salida literal de pnpm 11.20, capturada
# ejecutándolo contra proyectos de verdad: una devDependency añadida, una
# dependencia de producción añadida, un especificador subido, una quitada, y
# dos a la vez con una de ámbito.

pkgjson() { # pkgjson <json>  ; deja un package.json en la release
  rm -rf "$REL"; mkdir -p "$REL"
  printf '%s' "$1" > "$REL/package.json"
}

section "Leer qué ha derivado, de la salida real de pnpm"
L="$(log_con '  Failure reason:' \
             '  specifiers in the lockfile don'"'"'t match specifiers in package.json:' \
             '* 1 dependencies were added: playwright@^1.49.0')"
check "una añadida"      "add playwright"  "$(_lock_drift "$L")"
L="$(log_con '* 2 dependencies were added: @types/node@^22.0.0, is-even@^1.0.0')"
# La arroba del ámbito no es la de la versión: se corta por la última.
check "dos, una de ámbito" "add @types/node add is-even" \
                          "$(_lock_drift "$L" | tr '\n' ' ' | sed 's/ $//')"
L="$(log_con '* 1 dependencies were removed: is-odd@^3.0.1')"
check "una quitada"      "del is-odd"      "$(_lock_drift "$L")"
L="$(log_con '* 1 dependencies are mismatched:' '  - ms (lockfile: ^2.1.3, manifest: ^2.0.0)')"
check "un especificador subido" "mismatch ms" "$(_lock_drift "$L")"
L="$(log_con 'Error: Cannot find module "./config"')"
check "otro fallo, nada" ""                "$(_lock_drift "$L")"

section "Sólo se resuelve lo que no llega a producción"
A_PKG="pnpm"; A_APPDIR="."
# _dep_section lee el package.json con jq y no tiene camino de respaldo: sin jq
# devuelve vacío para todo, y entonces _recover_lockfile se **niega** a
# descongelar, que es la dirección segura y lo correcto. Pero afirmar aquí que
# recupera sería convertir una herramienta ausente en un bug: sin guardia,
# 'make test' sin jq salía en rojo con seis fallos que apuntaban al recuperador
# de lockfiles en vez de a jq. Se anuncia el salto, y test-strict lo cuenta.
# Fuera de la guardia: la sección de npm de más abajo también los usa.
DEV='{"dependencies":{"ms":"^2.1.3"},"devDependencies":{"playwright":"^1.49.0"}}'
PROD='{"dependencies":{"ms":"^2.1.3","lodash":"^4.17.21"}}'
if ! command -v jq >/dev/null; then
  echo "  (falta jq: me salto de qué sección del package.json es cada paquete)"
else

pkgjson "$DEV"
L="$(log_con '* 1 dependencies were added: playwright@^1.49.0')"
BUILD_UNFREEZE="no"
# Fuera de $(...): dentro sería un subshell y BUILD_UNFREEZE no saldría de él.
_recover_lockfile "$REL" "$L" > "$TMP/drift.out" 2>&1 && r=0 || r=$?
SALIDA="$(cat "$TMP/drift.out")"
check "devDependency: recupera" "0"    "$r"
check "y lo dice"           "1"        "$(grep -c 'devDependencies' <<<"$SALIDA")"
check "descongela el install" "yes"    "$BUILD_UNFREEZE"
check "sin nada que reprochar" "0"     "${#DRIFT_BAD[@]}"

pkgjson "$PROD"
L="$(log_con '* 1 dependencies were added: lodash@^4.17.21')"
BUILD_UNFREEZE="no"
_recover_lockfile "$REL" "$L" >/dev/null 2>&1 && r=0 || r=$?
check "producción: se niega"  "1"      "$r"
check "no toca el install"    "no"     "$BUILD_UNFREEZE"
check "y nombra el paquete"   "1"      "$(grep -c 'lodash' <<<"${DRIFT_BAD[*]}")"

# Un especificador subido sí reresuelve ese paquete: es el caso peligroso.
pkgjson "$DEV"
L="$(log_con '* 1 dependencies are mismatched:' '  - ms (lockfile: ^2.1.3, manifest: ^2.0.0)')"
BUILD_UNFREEZE="no"
_recover_lockfile "$REL" "$L" >/dev/null 2>&1 && r=0 || r=$?
check "versión cambiada: se niega" "1" "$r"
check "no toca el install"    "no"     "$BUILD_UNFREEZE"

# Una devDependency buena y una de producción mala: manda la mala.
pkgjson '{"dependencies":{"lodash":"^4.17.21"},"devDependencies":{"playwright":"^1.49.0"}}'
L="$(log_con '* 2 dependencies were added: lodash@^4.17.21, playwright@^1.49.0')"
BUILD_UNFREEZE="no"
_recover_lockfile "$REL" "$L" >/dev/null 2>&1 && r=0 || r=$?
check "una mala lo estropea todo" "1" "$r"
check "no toca el install"    "no"     "$BUILD_UNFREEZE"

# Un paquete que no aparece en ningún package.json no se supone: se rechaza.
pkgjson '{"dependencies":{"ms":"^2.1.3"}}'
L="$(log_con '* 1 dependencies were added: playwright@^1.49.0')"
BUILD_UNFREEZE="no"
_recover_lockfile "$REL" "$L" >/dev/null 2>&1 && r=0 || r=$?
check "sección desconocida: se niega" "1" "$r"

# En un monorepo la dependencia vive en la subcarpeta de la app.
rm -rf "$REL"; mkdir -p "$REL/apps/web"
printf '%s' '{"name":"raiz"}' > "$REL/package.json"
printf '%s' "$DEV" > "$REL/apps/web/package.json"
A_APPDIR="apps/web"
L="$(log_con '* 1 dependencies were added: playwright@^1.49.0')"
BUILD_UNFREEZE="no"
_recover_lockfile "$REL" "$L" >/dev/null 2>&1 && r=0 || r=$?
check "monorepo: mira la subcarpeta" "0" "$r"
A_APPDIR="."
fi

# npm y yarn no dicen qué entrada del package.json ha cambiado.
pkgjson "$DEV"
L="$(log_con 'npm error Missing: is-even@1.0.0 from lock file')"
A_PKG="npm"; BUILD_UNFREEZE="no"
_recover_lockfile "$REL" "$L" >/dev/null 2>&1 && r=0 || r=$?
check "con npm, no se adivina" "1"     "$r"
A_PKG="pnpm"

section "El reintento instala sin congelar, y sólo el reintento"
A_BUILD="pnpm install --frozen-lockfile --prod=false && pnpm build"
A_NODE_HEAP=""; A_PORT=3001
# Se sustituye sudo para ver el comando que se habría ejecutado.
sudo() { while [[ "${1:-}" == -* ]]; do shift; done; printf '%s' "${!#}"; }
BUILD_UNFREEZE="no"
check "primer intento, congelado" "1" "$(_build_run "$REL" | grep -c -- '--frozen-lockfile')"
BUILD_UNFREEZE="yes"
check "reintento, sin congelar"   "1" "$(_build_run "$REL" | grep -c -- '--no-frozen-lockfile')"
check "y no queda el congelado"   "0" "$(_build_run "$REL" | grep -c -- ' --frozen-lockfile')"
unset -f sudo

section "No se recuerda: vale para este commit, no para la app"
# A diferencia de allowBuilds o del heap, esto no se guarda en la configuración.
load_app web 2>/dev/null || true
check "nada en la configuración" "0" \
  "$(grep -c 'UNFREEZE\|FROZEN' "$TMP/etc/apps/web.conf" 2>/dev/null | head -1)"

report
