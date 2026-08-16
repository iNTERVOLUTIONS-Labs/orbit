#!/usr/bin/env bash
# Despliegue en lote y automático, contra repositorios git de verdad.
#   bash tests/autodeploy_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, WATCH_*…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for c in git rsync; do
  command -v "$c" >/dev/null || { echo "falta $c: me salto estas pruebas."; exit 0; }
done

need_root()      { :; }
SYSCTL_LOG="$TMP/systemctl.log"; : > "$SYSCTL_LOG"
systemctl()      { printf '%s\n' "$*" >> "$SYSCTL_LOG"; }
render_systemd() { :; }
render_nginx()   { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }
health_wait()    { return 0; }
LOG_FILE="$TMP/orbit.log"
NOTIFY_CONF="$TMP/notify.conf"
# El autodespliegue anota los remotos mudos en el estado del vigilante, y ese
# fichero vive en /var/lib/orbit: sin estas tres líneas la prueba escribiría
# en el sistema donde se ejecuta.
WATCH_STATE="$TMP/watch.state"
WATCH_LOCK="$TMP/watch.lock"
WATCH_LOG="$TMP/watch.log"
as_deploy() { bash -lc "$*"; }
as_app()    { bash -lc "$*"; }
sudo() {
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -u) shift 2 ;;
      --) shift; break ;;
      *)  shift ;;
    esac
  done
  "$@"
}

# Los avisos se apuntan en un fichero en vez de salir a la red.
cat > "$NOTIFY_CONF" <<EOF
NOTIFY_MIN_LEVEL='info'
NOTIFY_WEBHOOK='https://avisos.test/hook'
EOF
: > "$TMP/notificaciones"
curl() { printf '%s\n' "$*" >> "$TMP/notificaciones"; return 0; }
avisos() { wc -l < "$TMP/notificaciones" | tr -d ' '; }

# --- dos repositorios de origen --------------------------------------------
crear_repo() { # crear_repo <ruta> <contenido>
  git init -q -b main "$1"
  git -C "$1" config user.email orbit@test
  git -C "$1" config user.name Orbit
  printf '%s\n' "$2" > "$1/index.html"
  git -C "$1" add -A
  git -C "$1" commit -qm inicial
}
publicar() { # publicar <ruta> <contenido>
  printf '%s\n' "$2" > "$1/index.html"
  git -C "$1" commit -qam "$2"
}

registrar() { # registrar <app> <repo>
  A_NAME="$1"; A_REPO="$2"; A_BRANCH="main"; A_DOMAIN="$1.test"; A_ALIASES=""
  A_TYPE="static"; A_PKG="pnpm"; A_BUILD=""; A_START=""; A_OUTDIR="."
  A_SPA="no"; A_PORT=""; A_DOCROOT=""; A_PYAPP=""; A_PYMGR=""; A_PYFW=""
  A_MIGRATE=""; A_STATIC_URL=""; A_STATIC_ROOT=""; A_MEDIA_URL=""
  A_MEDIA_ROOT=""; A_REDIRECT=""; A_REDIRECT_CODE=""
  A_AUTODEPLOY=""; A_AUTOFAIL=""
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
  save_app
}

crear_repo "$TMP/repo-una" "una v1"
crear_repo "$TMP/repo-dos" "dos v1"
registrar una "$TMP/repo-una"
registrar dos "$TMP/repo-dos"

sirve() { cat "$TMP/apps/$1/current/index.html" 2>/dev/null; }

section "deploy --all"
run cmd_deploy_all >"$TMP/all1" 2>&1; r=$?
check "termina bien"     "0"      "$r"
check "despliega la una" "una v1" "$(sirve una)"
check "y la dos"         "dos v1" "$(sirve dos)"
check "resume el total"  "1"      "$(grep -c '2 correctas · 0 fallidas' "$TMP/all1")"

section "Detección de cambios"
load_app una
_pending_sha || true
check "el remoto coincide" "" "$PENDING_SHA"
publicar "$TMP/repo-una" "una v2"
load_app una
_pending_sha || true
check "detecta el commit nuevo" "si" "$([[ -n "$PENDING_SHA" ]] && echo si || echo no)"
load_app dos
_pending_sha || true
check "la dos sigue igual" "no" "$([[ -n "$PENDING_SHA" ]] && echo si || echo no)"

section "«Sin cambios» y «no he podido preguntar» no son lo mismo"
# Durante meses valían igual: si el remoto no contestaba, el temporizador
# decía «sin cambios» cada cinco minutos y el autodespliegue se paraba sin
# que nadie se enterase.
registrar roto "$TMP/repo-que-no-existe"
load_app roto
_pending_sha && r=0 || r=$?
check "remoto inalcanzable → 2" "2" "$r"
check "y dice por qué"          "1" "$([[ -n "$REMOTE_ERR" ]] && echo 1 || echo 0)"
load_app dos
_pending_sha && r=0 || r=$?
check "al día → 1"              "1" "$r"
load_app una
_pending_sha && r=0 || r=$?
check "con novedad → 0"         "0" "$r"
check "y deja el SHA"           "1" "$([[ "$PENDING_SHA" =~ ^[0-9a-f]{40}$ ]] && echo 1 || echo 0)"
# La rama que ya no está en el remoto es un caso distinto del repo caído: se
# arregla cambiando la rama, no esperando a que vuelva la red.
load_app dos; A_BRANCH="rama-que-no-existe"; save_app
_pending_sha && r=0 || r=$?
check "rama inexistente → 3"    "3" "$r"
load_app dos; A_BRANCH="main"; save_app
# La app rota se da de baja: si se queda, todas las pasadas siguientes
# contarían un remoto sin contacto y los recuentos no cuadrarían.
rm -f "$(app_conf roto)"

section "deploy --all --if-changed"
run cmd_deploy_all --if-changed >"$TMP/all2" 2>&1; r=$?
check "termina bien"        "0"      "$r"
check "actualiza la una"    "una v2" "$(sirve una)"
check "no toca la dos"      "dos v1" "$(sirve dos)"
check "cuenta la saltada"   "1"      "$(grep -c '1 correctas · 0 fallidas · 1 sin cambios' "$TMP/all2")"

# Sin cambios en ninguna, no debe desplegar nada.
run cmd_deploy_all --if-changed >"$TMP/all3" 2>&1
check "segunda pasada en vacío" "1" "$(grep -c '0 correctas · 0 fallidas · 2 sin cambios' "$TMP/all3")"

section "El automático es por app"
# Activar el automático en una app no puede desplegar también a las demás:
# eso convertiría un permiso por app en un permiso global.
load_app una; A_AUTODEPLOY="yes"; save_app
load_app dos; A_AUTODEPLOY="no";  save_app
publicar "$TMP/repo-una" "una v2b"
publicar "$TMP/repo-dos" "dos v2b"
run cmd_deploy_all --auto >"$TMP/auto1" 2>&1
check "despliega la marcada"  "una v2b" "$(sirve una)"
check "no toca la que no"     "dos v1"  "$(sirve dos)"
check "sólo mira una"         "1"       "$(grep -c '1 correctas · 0 fallidas · 0 sin cambios' "$TMP/auto1")"
# A mano sí se despliegan todas las que hayan cambiado.
run cmd_deploy_all --if-changed >/dev/null 2>&1
check "a mano sí va la dos"   "dos v2b" "$(sirve dos)"
load_app dos; A_AUTODEPLOY=""; save_app

section "Un commit roto no se reintenta en bucle"
# Este es el riesgo de sondear cada minuto: si el build falla, reintentarlo
# sin parar llena el log y el teléfono sin arreglar nada.
load_app una
A_BUILD="exit 1"; save_app
publicar "$TMP/repo-una" "una rota"
: > "$TMP/notificaciones"
run cmd_deploy_all --auto >"$TMP/all4" 2>&1; r=$?
check "informa del fallo"   "1"       "$r"
check "producción intacta"  "una v2b" "$(sirve una)"
check "avisa una vez"       "1"      "$(avisos)"
load_app una
check "recuerda el commit roto" "si" "$([[ -n "$A_AUTOFAIL" ]] && echo si || echo no)"

# Segunda y tercera pasada con el mismo commit roto: ni intento ni aviso.
run cmd_deploy_all --auto >"$TMP/all5" 2>&1
run cmd_deploy_all --auto >/dev/null 2>&1
check "no reintenta"        "1" "$(grep -c '0 correctas · 0 fallidas · 1 sin cambios' "$TMP/all5")"
check "no vuelve a avisar"  "1" "$(avisos)"
# Pero pedirlo a mano sí reintenta: es la vía para volver a probar tras
# corregir algo que no está en el código, como una variable del .env.
run cmd_deploy_all --if-changed >"$TMP/all5b" 2>&1; r=$?
check "a mano sí reintenta" "1" "$r"

section "Un commit nuevo sí se intenta"
load_app una
A_BUILD=""; save_app
publicar "$TMP/repo-una" "una v3"
run cmd_deploy_all --auto >"$TMP/all6" 2>&1; r=$?
check "lo despliega"        "0"      "$r"
check "sirve la corregida"  "una v3" "$(sirve una)"
load_app una
check "olvida el commit roto" "" "$A_AUTOFAIL"

section "Altas y bajas en automático"
run cmd_autodeploy enable una >"$TMP/ad1" 2>&1; r=$?
check "activa"            "0"   "$r"
load_app una
check "queda marcada"     "yes" "$A_AUTODEPLOY"
check "dice cada cuánto"  "1"   "$(grep -c 'Sin puertos abiertos ni webhooks' "$TMP/ad1")"
check "solo ella"         "una" "$(_autodeploy_enabled_apps | tr '\n' ' ' | sed 's/ $//')"

run cmd_autodeploy status >"$TMP/ad2" 2>&1
check "aparece en el estado" "1" "$(grep -c 'una ' "$TMP/ad2")"

: > "$SYSCTL_LOG"
run cmd_autodeploy disable una >/dev/null 2>&1
load_app una
check "se desactiva" "no" "$A_AUTODEPLOY"
check "ya no queda ninguna" "" "$(_autodeploy_enabled_apps | tr -d '\n')"
check "y para el temporizador" "1" \
  "$(grep -c 'disable --now orbit-autodeploy.timer' "$SYSCTL_LOG")"
# Y apaga la luz roja que pueda haber dejado. Una pasada fallida deja la unidad
# en 'failed', y eso es a propósito: es el aviso de que el automático no está
# funcionando, y la pasada siguiente lo pone en verde sola. Pero al retirar el
# temporizador ya no hay pasada siguiente, así que ese 'failed' se queda para
# siempre y con él un 'systemctl is-system-running' diciendo «degraded» por una
# unidad que nadie va a volver a ejecutar. Visto en un servidor de verdad.
check "y limpia el estado fallido" "1" \
  "$(grep -c 'reset-failed orbit-autodeploy' "$SYSCTL_LOG")"

section "Una redirección no se despliega sola"
A_NAME="viejo.test"; A_TYPE="redirect"; A_DOMAIN="viejo.test"
A_REDIRECT="https://nuevo.test"; A_REDIRECT_CODE="301"; A_REPO=""
A_BRANCH=""; A_ALIASES=""; A_PKG=""; A_BUILD=""; A_START=""; A_OUTDIR=""
A_SPA="no"; A_PORT=""; A_DOCROOT=""; A_PYAPP=""; A_PYMGR=""; A_PYFW=""
A_MIGRATE=""; A_STATIC_URL=""; A_STATIC_ROOT=""; A_MEDIA_URL=""
A_MEDIA_ROOT=""; A_AUTODEPLOY=""; A_AUTOFAIL=""
A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
save_app
check "queda fuera del lote" "0" "$(deployable_apps | grep -cx 'viejo.test' || true)"
run cmd_autodeploy enable viejo.test >/dev/null 2>&1; r=$?
check "no se puede activar" "1" "$r"

section "Cambiar cada cuánto se comprueba"
# El intervalo va escrito dentro de la unidad, así que cambiarlo en la
# configuración no basta: hay que reescribirla y reiniciar el temporizador.
UNITDIR="$TMP/systemd"; mkdir -p "$UNITDIR"
CONF_FILE="$TMP/etc/orbit.conf"
autodeploy_unit()    { echo "$UNITDIR/orbit-autodeploy.timer"; }
autodeploy_service() { echo "$UNITDIR/orbit-autodeploy.service"; }
REINICIOS_T="$TMP/timer-restarts"; : > "$REINICIOS_T"
systemctl() { case "${1:-}" in restart) printf '%s\n' "${2:-}" >> "$REINICIOS_T" ;; esac; return 0; }

load_app una; A_AUTODEPLOY="yes"; save_app
run cmd_autodeploy every 5 >"$TMP/ev1" 2>&1; r=$?
check "acepta el cambio"     "0" "$r"
check "lo guarda en la conf" "1" "$(grep -c '^AUTODEPLOY_EVERY="5"' "$CONF_FILE")"
check "reescribe la unidad"  "1" "$(grep -c 'OnUnitActiveSec=5min' "$UNITDIR/orbit-autodeploy.timer")"
check "y reinicia el timer"  "1" "$(grep -cx 'orbit-autodeploy.timer' "$REINICIOS_T")"

# Con una instalación anterior la clave no existe en orbit.conf: hay que
# añadirla, no fallar en silencio.
grep -v AUTODEPLOY_EVERY "$CONF_FILE" > "$CONF_FILE.tmp" && mv "$CONF_FILE.tmp" "$CONF_FILE"
run cmd_autodeploy every 7 >/dev/null 2>&1
check "la añade si faltaba"  "1" "$(grep -c '^AUTODEPLOY_EVERY="7"' "$CONF_FILE")"

run cmd_autodeploy every 0 >/dev/null 2>&1; r=$?
check "rechaza el cero"      "1" "$r"
run cmd_autodeploy every diez >/dev/null 2>&1; r=$?
check "rechaza lo que no es número" "1" "$r"
run cmd_autodeploy every 99999 >/dev/null 2>&1; r=$?
check "rechaza lo absurdo"   "1" "$r"

# Si nadie tiene el automático activado, se guarda pero no se toca systemd.
load_app una; A_AUTODEPLOY="no"; save_app
: > "$REINICIOS_T"
run cmd_autodeploy every 9 >"$TMP/ev2" 2>&1
check "guarda sin apps"      "1" "$(grep -c '^AUTODEPLOY_EVERY="9"' "$CONF_FILE")"
check "y no toca el timer"   "0" "$(grep -c . "$REINICIOS_T")"
load_app una; A_AUTODEPLOY="yes"; save_app

section "status avisa si la unidad se ha quedado atrás"
# Alguien edita orbit.conf a mano: la unidad conserva el valor viejo y el
# cambio no surte efecto. Callarse sería dejarle creer que ya está.
printf 'OnUnitActiveSec=9min\n' > "$UNITDIR/orbit-autodeploy.timer"
AUTODEPLOY_EVERY=3
run cmd_autodeploy status >"$TMP/st" 2>&1
check "detecta el desajuste" "1" "$(grep -c 'sigue con 9 min' "$TMP/st")"

section "Un remoto mudo se avisa una vez, no en cada pasada"
# El temporizador pasa cada pocos minutos y una avería de red dura horas: si
# se avisara del estado en vez de la transición, serían cien mensajes iguales.
load_app una; A_AUTODEPLOY="no"; save_app
registrar mudo "$TMP/repo-que-no-esta"
load_app mudo; A_AUTODEPLOY="yes"; save_app
: > "$TMP/notificaciones"
run cmd_deploy_all --auto >"$TMP/m1" 2>&1; r=$?
check "la pasada da error"     "1" "$r"
check "lo dice en el resumen"  "1" "$(grep -c 'sin contacto' "$TMP/m1")"
check "y explica que no es «sin cambios»" "1" "$(grep -c 'no es «sin cambios»' "$TMP/m1")"
check "avisa una vez"          "1" "$(avisos)"
run cmd_deploy_all --auto >/dev/null 2>&1
run cmd_deploy_all --auto >/dev/null 2>&1
check "y no repite"            "1" "$(avisos)"
check "queda anotado"          "sin-contacto" "$(_watch_state_load; echo "${WS_STATE[remoto:mudo]:-}")"

# Cuando el remoto vuelve, se dice: un aviso que no se cierra no sirve.
load_app mudo; A_REPO="$TMP/repo-dos"; save_app
run cmd_deploy_all --auto >/dev/null 2>&1; r=$?
check "la pasada vuelve a salir" "0" "$r"
check "avisa la recuperación"    "2" "$(avisos)"
check "y vuelve a ok"            "ok" "$(_watch_state_load; echo "${WS_STATE[remoto:mudo]:-}")"

# Una rama que ya no existe es otro problema y se dice distinto.
load_app mudo; A_BRANCH="rama-fantasma"; save_app
: > "$TMP/notificaciones"
run cmd_deploy_all --auto >"$TMP/m2" 2>&1; r=$?
check "también da error"       "1" "$r"
check "nombra la rama"         "2" "$(grep -c "rama-fantasma" "$TMP/m2")"
check "y se anota aparte"      "sin-rama" "$(_watch_state_load; echo "${WS_STATE[remoto:mudo]:-}")"

# Donde se mira el estado es donde tiene que salir el problema.
run cmd_autodeploy status >"$TMP/m3" 2>&1
check "status lo enseña"       "1" "$(grep -c 'ya no existe en el remoto' "$TMP/m3")"
load_app mudo; A_REPO="$TMP/no-esta-tampoco"; A_BRANCH="main"; save_app
run cmd_deploy_all --auto >/dev/null 2>&1
run cmd_autodeploy status >"$TMP/m4" 2>&1
check "y el remoto mudo también" "1" "$(grep -c 'no consigo hablar con el remoto' "$TMP/m4")"
rm -f "$(app_conf mudo)"

section "El contrato por lotes: deploy --all --json"
# Un resumen en prosa vale para una persona; un cliente necesita saber cuál de
# los seis finales le ha tocado a cada app y por qué. Lo que se comprueba aquí
# es el contrato, no el despliegue: que sea **un solo objeto**, que cada app
# lleve dentro el mismo objeto que devuelve 'orbit deploy <app> --json', y que
# «al día» y «no he podido preguntar» no se confundan, que es el error que este
# comando ya cometió una vez en prosa.
if ! command -v jq >/dev/null; then
  echo "  falta jq: me salto las comprobaciones del contrato por lotes."
else
  # Un tablero con los cuatro finales interesantes a la vez: una al día, una
  # con novedad, una con el remoto mudo y una con la rama desaparecida.
  registrar sinremoto "$TMP/repo-que-tampoco-existe"
  registrar sinrama   "$TMP/repo-dos"
  load_app sinrama; A_BRANCH="rama-fantasma"; save_app
  load_app dos; A_BRANCH="main"; A_AUTODEPLOY="no"; save_app
  # Primero se pone todo al día, y **después** se publica el commit nuevo: al
  # revés, la pasada de calentamiento ya desplegaba 'una' y la prueba medía un
  # tablero con un final de menos.
  # '; r=$?' y no a secas: la pasada devuelve 1 —hay apps sin contacto— y bajo
  # errexit una orden que falla sin recoger su código se lleva el script por
  # delante. Es la trampa que abre docs/DEVELOPMENT.md, y aquí la sección entera
  # desaparecía sin imprimir un solo fallo.
  run cmd_deploy_all --if-changed >/dev/null 2>&1; r=$?
  publicar "$TMP/repo-una" "una v9"

  JSON="yes"; _ui_route
  run cmd_deploy_all --if-changed >"$TMP/j1" 2>"$TMP/j1err"; r=$?
  JSON="no"; _ui_route
  # No poder preguntar cuenta como fallo de la pasada, igual que en prosa.
  check "la pasada da error"      "1" "$r"
  # Un solo objeto por stdout, como todos los demás comandos (§13.6b): si
  # fueran varias líneas, 'orbit deploy --all --json | jq .' no valdría.
  check "una sola línea"          "1" "$(wc -l < "$TMP/j1")"
  check "y es JSON válido"        "object" "$(jq -r 'type' < "$TMP/j1" 2>/dev/null || echo NO)"
  check "no se cuela la prosa"    "0" "$(grep -c 'correctas ·' "$TMP/j1")"
  # …que sí sale, pero por stderr, que es donde va lo que lee una persona.
  check "la prosa va a stderr"    "1" "$(grep -c 'correctas ·' "$TMP/j1err")"

  estado() { jq -r --arg a "$1" '.apps[] | select(.app==$a) | .status' < "$TMP/j1"; }
  check "la que tiene novedad"    "deployed"    "$(estado una)"
  check "la que está al día"      "unchanged"   "$(estado dos)"
  check "la del remoto mudo"      "unreachable" "$(estado sinremoto)"
  check "la de la rama perdida"   "gone"        "$(estado sinrama)"
  # Y los recuentos desglosados, no agrupados: juntar «sin cambios» con «no he
  # podido preguntar» es exactamente lo que hacía falta arreglar.
  check "recuentos"  "1 1 1 1" \
    "$(jq -r '[.deployed,.unchanged,.unreachable,.gone]|join(" ")' < "$TMP/j1")"
  check "total cuadra" "1" \
    "$(jq -r 'if .total == (.apps|length) then 1 else 0 end' < "$TMP/j1")"
  # 'ok' y el código de salida no pueden discrepar nunca.
  check "ok es false"  "false" "$(jq -r '.ok' < "$TMP/j1")"

  # Lo que hace útil el contrato: dentro de cada app desplegada va **el mismo
  # objeto** que devuelve 'orbit deploy <app> --json', sin recortar. Un cliente
  # aprende una forma y le sirve para los dos comandos.
  check "la desplegada trae su objeto" "1" \
    "$(jq -r '.apps[]|select(.app=="una")|.result|if type=="object" then 1 else 0 end' < "$TMP/j1")"
  check "con su release"  "1" \
    "$(jq -r '.apps[]|select(.app=="una")|.result.release|if . != null then 1 else 0 end' < "$TMP/j1")"
  check "y su commit"     "1" \
    "$(jq -r '.apps[]|select(.app=="una")|.result.commit.sha|if . != null then 1 else 0 end' < "$TMP/j1")"
  # Las que no se han desplegado no se inventan un objeto: 'result' es null y
  # el motivo va en 'error'. Un null es una respuesta; un objeto a medias, no.
  check "la que no, no lo trae" "null" \
    "$(jq -r '.apps[]|select(.app=="dos")|.result|type' < "$TMP/j1")"
  check "el remoto mudo explica" "1" \
    "$(jq -r '.apps[]|select(.app=="sinremoto")|.error|if . != null then 1 else 0 end' < "$TMP/j1")"
  # Y explica de verdad: git termina su queja con un párrafo de ayuda, así que
  # coger la última línea daba «and the repository exists.», un trozo de frase
  # suelto. Lo que ha pasado está en el primer 'fatal:'.
  check "con el fatal de git"   "1" \
    "$(jq -r '.apps[]|select(.app=="sinremoto")|.error' < "$TMP/j1" | grep -c '^fatal:')"

  # Un despliegue que falla dice en qué paso y por qué, dentro de su objeto.
  load_app sinremoto; A_BRANCH="main"; save_app
  JSON="yes"; _ui_route
  run cmd_deploy_all >"$TMP/j2" 2>/dev/null; r=$?
  JSON="no"; _ui_route
  check "el fallo dice el paso"  "code" \
    "$(jq -r '.apps[]|select(.app=="sinremoto")|.result.failed_step' < "$TMP/j2")"
  check "y el motivo"            "1" \
    "$(jq -r '.apps[]|select(.app=="sinremoto")|.result.error|if . != null then 1 else 0 end' < "$TMP/j2")"

  section "--progress en un lote: los sucesos llevan la app"
  JSON="yes"; _ui_route
  run cmd_deploy_all --progress >"$TMP/j3" 2>"$TMP/j3ev"; r=$?
  JSON="no"; _ui_route
  check "stdout sigue siendo el objeto" "object" "$(jq -r 'type' < "$TMP/j3")"
  check "ningún suceso en stdout"       "0"      "$(grep -c '"event"' "$TMP/j3")"
  check "hay sucesos de app"            "1"      "$(grep -qc '"event":"app"' "$TMP/j3ev" && echo 1 || echo 0)"
  # Sin el nombre de la app, un paso de un lote no se puede atribuir: es un
  # campo añadido al suceso de 'deploy', que es lo que el contrato permite.
  check "y los pasos la llevan"         "0" \
    "$(grep '"event":"step"' "$TMP/j3ev" | grep -vc '"app":"' || true)"
  # Cada app que se despliega abre y cierra: un cliente puede pintar la barra.
  check "abre y cierra cada app"        "1" \
    "$(grep -c '"event":"app".*"status":"start"' "$TMP/j3ev" >/dev/null && echo 1 || echo 0)"
  rm -f "$(app_conf sinremoto)" "$(app_conf sinrama)"

  section "Un lote sin apps es una colección vacía, no un silencio"
  # Con stdout en blanco, un cliente no puede distinguir «no había nada» de
  # «algo se rompió». La regla de las colecciones vacías, aplicada al lote.
  mkdir -p "$TMP/sinapps"
  APPS_CONF_ORIG="$APPS_CONF"; APPS_CONF="$TMP/sinapps"
  JSON="yes"; _ui_route
  run cmd_deploy_all >"$TMP/j4" 2>/dev/null; r=$?
  JSON="no"; _ui_route
  APPS_CONF="$APPS_CONF_ORIG"
  check "termina bien"     "0"  "$r"
  check "y contesta igual" "0"  "$(jq -r '.total' < "$TMP/j4")"
  check "con lista vacía"  "0"  "$(jq -r '.apps|length' < "$TMP/j4")"
  check "y ok en true"     "true" "$(jq -r '.ok' < "$TMP/j4")"
fi

section "Cada despliegue del lote corre CON errexit"
# La forma entera son dos mitades: 'set +e' saca la llamada de un contexto donde
# su fallo está manejado, y 'set -Eeuo pipefail' dentro del hijo lo vuelve a
# encender. Con sólo la primera, cmd_deploy corre sin errexit igual que con el
# 'if ( … )' de antes: una orden que falla a mitad sigue adelante y la pasada lo
# cuenta como correcto. Y por aquí pasa el autodespliegue, sin nadie delante.
#
# Se comprueba sustituyendo cmd_deploy por uno que falla a mitad y sigue: si el
# hijo tuviera errexit apagado, llegaría al final y devolvería 0.
cmd_deploy_orig="$(declare -f cmd_deploy)"
cmd_deploy() { false; SIGUIO="si"; return 0; }
export SIGUIO=""
run cmd_deploy_all >/dev/null 2>&1; r=$?
check "el hijo aborta al fallar" "1" "$r"
eval "$cmd_deploy_orig"

section "Uso incorrecto"
run cmd_deploy_all --inventado >/dev/null 2>&1; r=$?
check "rechaza opción" "1" "$r"
# --progress sin --json no significa nada: los sucesos son para un programa.
run cmd_deploy_all --progress >/dev/null 2>&1; r=$?
check "y --progress sin --json" "1" "$r"

report
