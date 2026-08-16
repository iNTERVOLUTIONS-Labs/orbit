#!/usr/bin/env bash
# Las colas de Laravel, procesadas por temporizador: 'orbit queue'.
#   bash tests/queue_test.sh
#
# Lo que se comprueba aquí no es «llama a artisan»: es que el ciclo tenga las
# dos propiedades de las que vive el diseño (ARCHITECTURE §18.9). Que termine
# solo —'--stop-when-empty' y un '--max-time' que no puede pasar de su propio
# periodo—, y que lo ejecute el usuario de la app y no el de despliegue. Sin la
# primera, el «worker de un ciclo» vuelve a ser el worker residente que este
# diseño evita, por el camino largo; sin la segunda, la cola lee y escribe con
# los permisos equivocados y se lleva por delante el aislamiento del §5.3.
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, PHP_*…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
CONF_FILE="$TMP/etc/orbit.conf"
UNITDIR="$TMP/systemd"; mkdir -p "$UNITDIR"
queue_unit()    { echo "$UNITDIR/orbit-queue.timer"; }
queue_service() { echo "$UNITDIR/orbit-queue.service"; }
QUEUE_LOCK_DIR="$TMP/locks"
# El aviso de una cola que deja de procesarse pasa por el vigilante, que
# escribe en /var/lib/orbit: sin estas tres líneas la prueba tocaría el estado
# del servidor donde se ejecuta.
WATCH_STATE="$TMP/watch.state"
WATCH_LOCK="$TMP/watch.lock"
WATCH_LOG="$TMP/watch.log"

SYSCTL_LOG="$TMP/systemctl.log"; : > "$SYSCTL_LOG"
systemctl() { printf '%s\n' "$*" >> "$SYSCTL_LOG"; return 0; }

# Los avisos se apuntan en un fichero en vez de salir a la red.
NOTIFY_CONF="$TMP/notify.conf"
cat > "$NOTIFY_CONF" <<EOF
NOTIFY_MIN_LEVEL='info'
NOTIFY_WEBHOOK='https://avisos.test/hook'
EOF
: > "$TMP/notificaciones"
curl() { printf '%s\n' "$*" >> "$TMP/notificaciones"; return 0; }
avisos() { wc -l < "$TMP/notificaciones" | tr -d ' '; }

# --- el php de mentira ------------------------------------------------------
# Un doble que no puede fallar no comprueba nada (docs/DEVELOPMENT.md), así que éste
# apunta con qué argumentos y desde dónde lo llamaron, y sale con el código que
# le diga $PHP_RC. La mutación que tiene que ponerlo en rojo es quitarle
# cualquiera de las banderas al queue:work, y está ejercitada más abajo.
export PHP_LOG="$TMP/php.log"; : > "$PHP_LOG"
export PHP_RC="$TMP/php.rc";   printf '0\n' > "$PHP_RC"
export PHP_SLEEP="$TMP/php.sleep"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/php" <<'EOF'
#!/usr/bin/env bash
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >> "$PHP_LOG"
[[ -s "$PHP_SLEEP" ]] && sleep "$(cat "$PHP_SLEEP")"
exit "$(cat "$PHP_RC" 2>/dev/null || echo 0)"
EOF
chmod +x "$TMP/bin/php"
export PATH="$TMP/bin:$PATH"

# El doble de as_app apunta **quién** habría ejecutado cada cosa, que es la
# mitad que la suite no veía cuando as_deploy y as_app eran el mismo shell. Y
# corre con 'bash -c' y no con 'bash -lc' a propósito: el perfil de login
# reescribe el PATH y se llevaría por delante el php de mentira.
APPUSER_LOG="$TMP/asapp.log"; : > "$APPUSER_LOG"
as_app() { printf '%s :: %s\n' "$(app_user)" "$*" >> "$APPUSER_LOG"; bash -c "$*"; }

argv_php() { sed -n 's/^cwd=.* argv=//p' "$PHP_LOG" | tail -1; }
cwd_php()  { sed -n 's/^cwd=\(.*\) argv=.*/\1/p' "$PHP_LOG" | tail -1; }

# --- una app de Laravel de mentira ------------------------------------------
crear_laravel() { # crear_laravel <app> [subcarpeta]
  local n="$1" sub="${2:-}" rel="$TMP/apps/$1/releases/r1" app
  app="$rel${sub:+/$sub}"
  mkdir -p "$app" "$TMP/apps/$n/shared"
  : > "$app/artisan"
  ln -sfn "$rel" "$TMP/apps/$n/current"
  printf 'APP_KEY=base64:x\nQUEUE_CONNECTION=database\n' > "$TMP/apps/$n/shared/.env"
  A_NAME="$n"; A_TYPE="laravel"; A_PORT=""; A_USER="orbit-$n"
  A_DOMAIN="$n.test"; A_ALIASES=""; A_REPO="https://example.test/$n.git"
  A_BRANCH="main"; A_PKG="composer"; A_BUILD=""; A_START=""; A_OUTDIR=""
  A_SPA="no"; A_DOCROOT="public"; A_PYAPP=""; A_APPDIR="${sub:-.}"
  A_QUEUE=""; A_AUTODEPLOY=""; A_AUTOFAIL=""
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
  save_app
}

crear_laravel tienda
mkapp estatica static ""

section "El límite del ciclo sale del intervalo, y no de un ajuste aparte"
# Si un ciclo pudiera durar más que su propio periodo, el siguiente arrancaría
# con el anterior dentro: dos workers sobre la misma cola y, en un despliegue,
# dos releases distintas a la vez.
QUEUE_EVERY=1; check "un minuto → 55 s"  "55"  "$(_queue_max_time)"
QUEUE_EVERY=5; check "cinco → 295 s"     "295" "$(_queue_max_time)"
# Nadie llega aquí por la CLI —'every' rechaza el cero—, pero orbit.conf se
# edita a mano y un --max-time negativo haría fallar cada ciclo sin decir por qué.
QUEUE_EVERY=0; check "un cero a mano no da negativo" "10" "$(_queue_max_time)"
QUEUE_EVERY=1

section "La unidad que escribe el temporizador"
QUEUE_EVERY=2
run _queue_timer_write >/dev/null 2>&1
U="$UNITDIR/orbit-queue.timer"; S="$UNITDIR/orbit-queue.service"
check "el temporizador existe"  "1" "$(grep -c 'OnUnitActiveSec=2min' "$U")"
check "sin margen que sumar"    "1" "$(grep -c 'AccuracySec=1s' "$U")"
check "y se activa al arrancar" "1" "$(grep -c 'WantedBy=timers.target' "$U")"
check "llama a queue run --all" "1" "$(grep -c 'ExecStart=/usr/local/bin/orbit queue run --all --quiet' "$S")"
check "es de un solo disparo"   "1" "$(grep -c 'Type=oneshot' "$S")"
# El segundo cinturón: si artisan se cuelga contra una base de datos que no
# contesta, --max-time no le llega y quien lo corta es systemd.
check "y systemd corta al final" "1" "$(grep -c 'TimeoutStartSec=145' "$S")"
QUEUE_EVERY=1

section "Un ciclo: qué se ejecuta, y quién lo ejecuta"
: > "$PHP_LOG"; : > "$APPUSER_LOG"
run cmd_queue run tienda >"$TMP/r1" 2>&1; r=$?
check "sale bien" "0" "$r"
# La orden entera, escrita a propósito: es el contrato con Laravel, y cualquiera
# de las banderas que se caiga cambia lo que hace el ciclo.
check "la orden exacta" \
  "artisan queue:work --stop-when-empty --sleep=0 --max-time=55 --no-interaction --no-ansi" \
  "$(argv_php)"
check "termina cuando se vacía" "1" "$(grep -c -- '--stop-when-empty' "$PHP_LOG")"
check "y no puede eternizarse"  "1" "$(grep -c -- '--max-time=55' "$PHP_LOG")"
# La release de verdad y no 'current': el symlink puede moverse a mitad de
# ciclo, y un worker que abre unos ficheros de una release y otros de la
# siguiente es peor que cualquiera de las dos.
check "desde la release, no del symlink" "$TMP/apps/tienda/releases/r1" "$(cwd_php)"
# El §5.3 entero: la cola la ejecuta el usuario de la app. Con el de despliegue
# escribiría los logs y la caché de Laravel con el dueño equivocado.
check "y con el usuario de la app" "1" "$(grep -c '^orbit-tienda :: ' "$APPUSER_LOG")"

section "Una app en un monorepo ejecuta en su carpeta"
crear_laravel api backend
: > "$PHP_LOG"
run cmd_queue run api >/dev/null 2>&1; r=$?
check "sale bien"          "0" "$r"
check "y entra en backend" "$TMP/apps/api/releases/r1/backend" "$(cwd_php)"
rm -f "$(app_conf api)"

section "Lo que no es de Laravel no tiene cola"
run cmd_queue enable estatica >"$TMP/e1" 2>&1; r=$?
check "no se puede activar" "1" "$r"
load_app estatica
check "y no queda marcada"  "" "$A_QUEUE"

section "Que no haya QUEUE_CONNECTION no significa que no haya cola"
# Salió desplegando un Laravel de verdad: desde la 11, el valor por defecto del
# framework es 'database' y no 'sync', así que un .env sin la clave —que es el
# que deja 'orbit new', porque el esqueleto de Laravel no trae .env— encola en
# la base de datos sin que lo ejecute nadie. Leer la clave ausente como un «no»
# dejaba callado justo el aviso que existe para contar ese silencio.
load_app tienda
mkdir -p "$TMP/apps/tienda/releases/r1/config"
_qphp="$TMP/apps/tienda/releases/r1/config/queue.php"
printf "    'default' => env('QUEUE_CONNECTION', 'database'),\n" > "$_qphp"
printf 'APP_KEY=base64:x\n' > "$TMP/apps/tienda/shared/.env"
check "sale del config del framework" "database" "$(_queue_connection tienda)"
# Y en un Laravel 10 el defecto era 'sync': ahí de verdad no hay nada que vaciar.
printf "    'default' => env('QUEUE_CONNECTION', 'sync'),\n" > "$_qphp"
check "y si el defecto es sync, sync"  "sync"     "$(_queue_connection tienda)"
# La clave del .env manda sobre el respaldo, siempre.
printf 'QUEUE_CONNECTION=redis\n' >> "$TMP/apps/tienda/shared/.env"
check "el .env manda"                  "redis"    "$(_queue_connection tienda)"
# Y sin config que leer se calla, que es lo que ya hacía: un aviso falso en cada
# despliegue es peor que un aviso que falta (la lección de ALLOWED_HOSTS).
rm -f "$_qphp"
printf 'APP_KEY=base64:x\n' > "$TMP/apps/tienda/shared/.env"
check "sin nada que leer, calla"       ""         "$(_queue_connection tienda)"
printf 'APP_KEY=base64:x\nQUEUE_CONNECTION=database\n' > "$TMP/apps/tienda/shared/.env"

section "Altas y bajas"
: > "$SYSCTL_LOG"
run cmd_queue enable tienda >"$TMP/on1" 2>&1; r=$?
check "activa"              "0"   "$r"
load_app tienda
check "queda marcada"       "yes" "$A_QUEUE"
check "arranca el timer"    "1"   "$(grep -c 'enable --now orbit-queue.timer' "$SYSCTL_LOG")"
check "solo ella"           "tienda" "$(_queue_enabled_apps | tr '\n' ' ' | sed 's/ $//')"
# La latencia se dice al encender, no cuando alguien pregunte por qué el correo
# tarda un minuto. Es el precio del diseño y la conversación va por delante.
check "avisa de la latencia" "1" "$(grep -c 'puede tardar' "$TMP/on1")"

# Una cola en 'sync' no tiene nada que vaciar: el permiso se da igual —el .env
# cambia cuando quiera— pero callárselo deja a alguien mirando una cola vacía
# convencido de que Orbit no procesa nada.
printf 'QUEUE_CONNECTION=sync\n' > "$TMP/apps/tienda/shared/.env"
run cmd_queue enable tienda >"$TMP/on2" 2>&1
check "avisa del sync"      "1" "$(grep -c 'no hay cola que vaciar' "$TMP/on2")"
printf 'QUEUE_CONNECTION=database\n' > "$TMP/apps/tienda/shared/.env"
run cmd_queue enable tienda >"$TMP/on3" 2>&1
check "y con cola de verdad no" "0" "$(grep -c 'no hay cola que vaciar' "$TMP/on3")"
# Y vacío no es 'sync', que es el error que este comando vino a corregir: es
# «no lo sé», y pasa con una app que todavía no se ha desplegado.
rm -f "$TMP/apps/tienda/shared/.env"
run cmd_queue enable tienda >"$TMP/on4" 2>&1
check "sin saberlo, no lo afirma" "0" "$(grep -c 'no hay cola que vaciar' "$TMP/on4")"
check "y lo dice como lo que es" "1" "$(grep -c 'Todavía no sé' "$TMP/on4")"
printf 'APP_KEY=base64:x\nQUEUE_CONNECTION=database\n' > "$TMP/apps/tienda/shared/.env"

section "La baja de la última apaga el temporizador y su luz roja"
crear_laravel otra
run cmd_queue enable otra >/dev/null 2>&1
: > "$SYSCTL_LOG"
run cmd_queue disable otra >/dev/null 2>&1
load_app otra
check "se desactiva"          "no" "$A_QUEUE"
check "pero queda tienda"     "0"  "$(grep -c 'disable --now orbit-queue.timer' "$SYSCTL_LOG")"
: > "$SYSCTL_LOG"
run cmd_queue disable tienda >/dev/null 2>&1
check "ahora sí lo para"      "1" "$(grep -c 'disable --now orbit-queue.timer' "$SYSCTL_LOG")"
# Un ciclo fallido deja la unidad en 'failed' a propósito y el ciclo siguiente
# la pone en verde sola. Retirado el temporizador ya no hay ciclo siguiente:
# ese rojo se quedaría para siempre, y con él un servidor que
# 'systemctl is-system-running' lee como «degraded». La misma lección que costó
# un arreglo en el autodespliegue, en un servidor de verdad.
check "y limpia el estado fallido" "1" "$(grep -c 'reset-failed orbit-queue' "$SYSCTL_LOG")"
rm -f "$(app_conf otra)"
load_app tienda; A_QUEUE="yes"; save_app

section "Cambiar cada cuánto se vacía"
REINICIOS="$TMP/timer-restarts"; : > "$REINICIOS"
systemctl() { printf '%s\n' "$*" >> "$SYSCTL_LOG"
              case "${1:-}" in restart) printf '%s\n' "${2:-}" >> "$REINICIOS" ;; esac; return 0; }
run cmd_queue every 3 >/dev/null 2>&1; r=$?
check "acepta el cambio"     "0" "$r"
check "lo guarda en la conf" "1" "$(grep -c '^QUEUE_EVERY="3"' "$CONF_FILE")"
check "reescribe la unidad"  "1" "$(grep -c 'OnUnitActiveSec=3min' "$U")"
# Y con él el corte de systemd, que también se deriva del intervalo: si sólo se
# reescribiera el temporizador, un ciclo de 3 min moriría contra el
# TimeoutStartSec de 85 s que dejó el intervalo anterior.
check "y también el corte"   "1" "$(grep -c 'TimeoutStartSec=205' "$S")"
check "y reinicia el timer"  "1" "$(grep -cx 'orbit-queue.timer' "$REINICIOS")"
run cmd_queue every 0 >/dev/null 2>&1;    r=$?; check "rechaza el cero" "1" "$r"
run cmd_queue every tres >/dev/null 2>&1; r=$?; check "y lo que no es número" "1" "$r"
run cmd_queue every 1 >/dev/null 2>&1

section "Cuándo se salta un ciclo, y por qué eso no es un fallo"
# Saltarse un ciclo es normal —un despliegue en marcha, una app sin release— y
# no puede poner la unidad en rojo: si lo hiciera, la alarma que sí importa
# —los trabajos apilándose— quedaría enterrada bajo el ruido.
: > "$PHP_LOG"
touch "$(maint_flag tienda)"
run cmd_queue run tienda >"$TMP/s1" 2>&1; r=$?
check "en mantenimiento no corre" "0" "$(grep -c . "$PHP_LOG")"
check "y no es un fallo"          "0" "$r"
check "lo dice"                   "1" "$(grep -c 'mantenimiento' "$TMP/s1")"
rm -f "$(maint_flag tienda)"

mv "$TMP/apps/tienda/current" "$TMP/apps/tienda/current.off"
run cmd_queue run tienda >"$TMP/s2" 2>&1; r=$?
check "sin release tampoco"       "0" "$(grep -c . "$PHP_LOG")"
check "y sigue sin ser un fallo"  "0" "$r"
mv "$TMP/apps/tienda/current.off" "$TMP/apps/tienda/current"

# Dos ciclos de la misma cola compitiendo por los mismos trabajos es justo lo
# que el cerrojo evita. El de fuera se queda con él y el ciclo se salta.
mkdir -p "$QUEUE_LOCK_DIR"
exec 8>"$(queue_lock tienda)"
flock -n 8
run cmd_queue run tienda >"$TMP/s3" 2>&1; r=$?
check "con el cerrojo tomado, se salta" "0" "$(grep -c . "$PHP_LOG")"
check "sin dar error"                   "0" "$r"
check "y explica cuál"                  "1" "$(grep -c 'ciclo anterior' "$TMP/s3")"
exec 8>&-
run cmd_queue run tienda >/dev/null 2>&1
check "suelto el cerrojo, corre"        "1" "$(grep -c . "$PHP_LOG")"

section "Un ciclo que falla se ve, y se avisa una sola vez"
printf '1\n' > "$PHP_RC"
: > "$TMP/notificaciones"
run cmd_queue run tienda >"$TMP/f1" 2>&1; r=$?
# El código de salida es lo que deja la unidad en rojo, y ese rojo es todo el
# aviso que hay: sin él los trabajos se apilan sin un solo error (§18.9).
check "devuelve fallo"      "1" "$r"
check "dice con qué salió"  "1" "$(grep -c 'no se ha podido procesar' "$TMP/f1")"
check "y con qué código"    "2" "$(grep -c 'salió con 1' "$TMP/f1")"
check "queda anotado"       "fallo" "$(_watch_state_load; echo "${WS_STATE[cola:tienda]:-}")"
check "avisa una vez"       "1" "$(avisos)"
run cmd_queue run tienda >/dev/null 2>&1
run cmd_queue run tienda >/dev/null 2>&1
check "y no repite"         "1" "$(avisos)"
printf '0\n' > "$PHP_RC"
run cmd_queue run tienda >/dev/null 2>&1; r=$?
check "al recuperarse sale bien" "0" "$r"
check "vuelve a ok"              "ok" "$(_watch_state_load; echo "${WS_STATE[cola:tienda]:-}")"
check "y se dice"                "2"  "$(avisos)"

# Un cerrojo que no se puede ni abrir es un servidor roto, no un ciclo
# solapado: con el mismo código de salida, un /var/lib/orbit sin permisos se
# leería para siempre como «el ciclo anterior sigue en marcha».
_lockdir_bueno="$QUEUE_LOCK_DIR"
QUEUE_LOCK_DIR="/dev/null/no-existe"
run cmd_queue run tienda >"$TMP/f3" 2>&1; r=$?
check "sin cerrojo, falla"  "1" "$r"
check "una sola línea de error" "1" "$(grep -c 'no se ha podido procesar' "$TMP/f3")"
check "y dice que es el cerrojo" "1" "$(grep -q 'cerrojo' "$TMP/f3" && echo 1 || echo 0)"
QUEUE_LOCK_DIR="$_lockdir_bueno"

# Un artisan que no está es otro fallo distinto, y también tiene que verse.
mv "$TMP/apps/tienda/releases/r1/artisan" "$TMP/apps/tienda/releases/r1/artisan.off"
run cmd_queue run tienda >"$TMP/f2" 2>&1; r=$?
check "sin artisan, falla"  "1" "$r"
check "y dice qué falta"    "1" "$(grep -c 'no se ha podido procesar' "$TMP/f2")"
mv "$TMP/apps/tienda/releases/r1/artisan.off" "$TMP/apps/tienda/releases/r1/artisan"

section "La pasada del temporizador: --all"
crear_laravel dos
load_app dos; A_QUEUE="no"; save_app
: > "$PHP_LOG"
run cmd_queue run --all --quiet >/dev/null 2>&1; r=$?
check "sale bien"                "0" "$r"
check "solo las que lo han pedido" "1" "$(grep -c . "$PHP_LOG")"
load_app dos; A_QUEUE="yes"; save_app
: > "$PHP_LOG"
run cmd_queue run --all --quiet >/dev/null 2>&1
check "ahora las dos"            "2" "$(grep -c . "$PHP_LOG")"

# Una app rota no puede dejar sin ciclo a las demás: la pasada sigue y el
# resumen se cobra al final, en el código de salida.
rm -f "$TMP/apps/dos/releases/r1/artisan"
: > "$PHP_LOG"
run cmd_queue run --all --quiet >/dev/null 2>&1; r=$?
check "una rota da fallo"        "1" "$r"
check "y la otra corre igual"    "1" "$(grep -c . "$PHP_LOG")"
rm -f "$(app_conf dos)"

load_app tienda; A_QUEUE="no"; save_app
run cmd_queue run --all --quiet >"$TMP/vacio" 2>&1; r=$?
check "sin apps no es un error"  "0" "$r"
check "y lo dice"                "1" "$(grep -c 'Ninguna app procesa colas' "$TMP/vacio")"
load_app tienda; A_QUEUE="yes"; save_app

section "El presupuesto es de la pasada, no de cada app"
# Tres apps ocupadas a 55 s cada una son 165 s dentro de una ventana de 60: la
# pasada se solaparía con la siguiente y systemd la mataría al llegar a su
# TimeoutStartSec, o sea una unidad en rojo cada minuto en un servidor sano.
crear_laravel lenta
load_app lenta;  A_QUEUE="yes"; save_app
load_app tienda; A_QUEUE="yes"; save_app
printf '2\n' > "$PHP_SLEEP"
: > "$PHP_LOG"
run cmd_queue run --all --quiet >/dev/null 2>&1; r=$?
check "la pasada sale bien"  "0" "$r"
check "corren las dos"       "2" "$(grep -c . "$PHP_LOG")"
_mt1="$(sed -n '1s/.*--max-time=\([0-9]*\).*/\1/p' "$PHP_LOG")"
_mt2="$(sed -n '2s/.*--max-time=\([0-9]*\).*/\1/p' "$PHP_LOG")"
check "la primera se lleva el ciclo entero" "55" "$_mt1"
check "y la segunda, lo que quedaba"        "1"  "$(( _mt2 < _mt1 ? 1 : 0 ))"
: > "$PHP_SLEEP"

# Y cuando no queda tiempo ni para arrancar el intérprete, se espera a la
# pasada siguiente en vez de levantar Laravel para matarlo a mitad.
: > "$PHP_LOG"
QUEUE_BUDGET=3
load_app tienda
run _queue_run_one tienda >/dev/null 2>&1; r=$?
check "sin tiempo, se salta"  "1" "$r"
check "y no arranca nada"     "0" "$(grep -c . "$PHP_LOG")"
QUEUE_BUDGET=""
rm -f "$(app_conf lenta)"

section "orbit queue status"
systemctl() { printf '%s\n' "$*" >> "$SYSCTL_LOG"
              case "$*" in *is-active*) return 0 ;; esac; return 0; }
run cmd_queue status >"$TMP/st1" 2>&1
check "nombra la app"       "1" "$(grep -c 'tienda' "$TMP/st1")"
check "y su conexión"       "1" "$(grep -c 'database' "$TMP/st1")"
check "y cuánto dura un ciclo" "1" "$(grep -c 'como mucho' "$TMP/st1")"
# Alguien edita orbit.conf a mano: la unidad conserva el valor viejo y el
# cambio no surte efecto. Callarse sería dejarle creer que ya está.
printf 'OnUnitActiveSec=9min\n' > "$U"
QUEUE_EVERY=4
run cmd_queue status >"$TMP/st2" 2>&1
check "detecta el desajuste" "1" "$(grep -c 'sigue con 9 min' "$TMP/st2")"
QUEUE_EVERY=1

section "El contrato: queue status --json"
if command -v jq >/dev/null; then
  JSON="yes"
  run cmd_queue status >"$TMP/j1" 2>/dev/null
  check "es JSON válido"    "0" "$(jq -e . "$TMP/j1" >/dev/null 2>&1; echo $?)"
  check "un solo objeto"    "1" "$(jq -s 'length' "$TMP/j1")"
  check "dice si hay timer" "true" "$(jq -r '.timer_active' "$TMP/j1")"
  check "y el intervalo"    "1"    "$(jq -r '.every_minutes' "$TMP/j1")"
  check "con la app dentro" "tienda" "$(jq -r '.apps[0].app' "$TMP/j1")"
  check "y su conexión"     "database" "$(jq -r '.apps[0].connection' "$TMP/j1")"
  # Una colección vacía significa «no hay», nunca «no he podido preguntar».
  load_app tienda; A_QUEUE="no"; save_app
  run cmd_queue status >"$TMP/j2" 2>/dev/null
  check "sin apps, lista vacía" "0" "$(jq -r '.apps | length' "$TMP/j2")"
  load_app tienda; A_QUEUE="yes"; save_app
  # Los demás subcomandos no tienen nada que serializar, y fingir que su salida
  # de siempre es JSON es peor que negarse, porque el cliente se lo cree.
  JSON="yes"; run cmd_queue enable tienda >/dev/null 2>&1; r=$?
  check "enable rechaza --json" "1" "$r"
  # Un .env que no se puede leer da null, y no la cadena vacía: son cosas
  # distintas y el cliente tiene que poder distinguirlas.
  mv "$TMP/apps/tienda/shared/.env" "$TMP/apps/tienda/shared/.env.off"
  run cmd_queue status >"$TMP/j3" 2>/dev/null
  check "sin .env, null"    "null" "$(jq -r '.apps[0].connection' "$TMP/j3")"
  mv "$TMP/apps/tienda/shared/.env.off" "$TMP/apps/tienda/shared/.env"
  JSON="no"
else
  echo "  falta jq: me salto el contrato --json."
fi

section "El estado de la app lo publica 'orbit info'"
# Un cliente que pinte el panel tiene que poder saber si la cola está puesta,
# igual que sabe si lo está el autodespliegue.
if command -v jq >/dev/null; then
  load_app tienda
  check "queue en el objeto" "true" "$(_app_state_json | jq -r '.queue')"
  load_app estatica
  check "y falso si no"      "false" "$(_app_state_json | jq -r '.queue')"
fi

report
