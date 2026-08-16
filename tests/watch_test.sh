#!/usr/bin/env bash
# Watchdog: transiciones, protección contra bucles de reinicio y avisos.
#   bash tests/watch_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, WATCH_*…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
WATCH_STATE="$TMP/watch.state"
WATCH_LOG="$TMP/watch.log"
WATCH_LOCK="$TMP/watch.lock"
NOTIFY_CONF="$TMP/notify.conf"
LOG_FILE="$TMP/orbit.log"

# --- dobles de las piezas del sistema --------------------------------------
# Cada app "responde" o no según un fichero, y cada reinicio queda anotado:
# así se puede comprobar cuántas veces se ha intentado, que es lo que define
# la protección contra bucles.
RESTARTS="$TMP/restarts"; : > "$RESTARTS"
UP="$TMP/up"; mkdir -p "$UP"

systemctl() {
  case "${1:-}" in
    restart) printf '%s\n' "${2:-}" >> "$RESTARTS" ;;
    is-active) [[ -f "$UP/${3:-${2:-}}" ]] ;;
    is-enabled) return 0 ;;
    list-unit-files) return 0 ;;
    *) return 0 ;;
  esac
}
curl() { # solo se usa para el health check y para los avisos
  local url="${*: -1}"
  case "$url" in
    http://127.0.0.1:*) [[ -f "$UP/port$(sed 's/.*://; s#/.*##' <<<"$url")" ]] ;;
    *) printf '%s\n' "$*" >> "$TMP/notificaciones"; return 0 ;;
  esac
}
: > "$TMP/notificaciones"

# --- una app con proceso ---------------------------------------------------
mkapp web node 3001 web.test
mkapp estatica static "" est.test

arriba()  { touch "$UP/orbit-$1" "$UP/port$2"; }
abajo()   { rm -f "$UP/orbit-$1" "$UP/port$2"; }
# Los reinicios se cuentan por unidad: si se contaran todos, los de nginx y
# PostgreSQL se mezclarían con los de la app que se está probando.
reinicios() { grep -cx "orbit-$1" "$RESTARTS" 2>/dev/null; true; }
estado()  { _watch_state_load; printf '%s' "${WS_STATE[$1]:-sin-estado}"; }
intentos(){ _watch_state_load; printf '%s' "${WS_TRIES[$1]:-0}"; }
avisos()  { wc -l < "$TMP/notificaciones" | tr -d ' '; }

# Los servicios del sistema están sanos: lo que se prueba aquí son las apps.
touch "$UP/nginx" "$UP/postgresql" "$UP/php8.3-fpm"

section "Servidor sano"
arriba web 3001
run _watch_run
check "la app está correcta" "ok" "$(estado app:web)"
check "no reinicia nada"     "0"  "$(reinicios web)"
check "no avisa"             "0"  "$(avisos)"
check "el estado es legible" "1"  "$(grep -c '^app:web ok' "$WATCH_STATE")"
# Un servidor sano no escribe en el historial: si lo hiciera, en un mes habría
# 43.000 líneas y nadie volvería a mirarlo.
check "no escribe historial" "0" "$([[ -f "$WATCH_LOG" ]] && grep -c . "$WATCH_LOG" || echo 0)"

section "La app se cae"
abajo web 3001
run _watch_run
check "la reinicia"        "1"     "$(reinicios web)"
check "queda en fallo"     "fallo" "$(estado app:web)"
check "un intento"         "1"     "$(intentos app:web)"
check "anota el evento"    "1"     "$(grep -c 'app:web' "$WATCH_LOG")"

section "Protección contra bucles"
run _watch_run
check "segundo reinicio" "2" "$(reinicios web)"
run _watch_run
check "tercer reinicio"  "3" "$(reinicios web)"
# A la cuarta se rinde: seguir reiniciando una app rota consume el servidor y
# esconde el problema.
run _watch_run
check "no hay cuarto reinicio" "3"        "$(reinicios web)"
check "se declara rendido"     "rendido"  "$(estado app:web)"
run _watch_run
run _watch_run
check "sigue sin reiniciar"    "3"        "$(reinicios web)"

section "Sin avisos repetidos"
# Se avisa de la transición, no del estado: si no, llegaría el mismo mensaje
# cada minuto mientras durase la avería.
cat > "$NOTIFY_CONF" <<EOF
NOTIFY_MIN_LEVEL='info'
NOTIFY_WEBHOOK='https://avisos.test/hook'
EOF
: > "$TMP/notificaciones"
mkapp otra node 3002 otra.test
run _watch_run
check "avisa de la caída" "1" "$(avisos)"
run _watch_run
run _watch_run
check "no repite el aviso" "1" "$(avisos)"

section "Recuperación"
arriba otra 3002
run _watch_run
check "vuelve a ok"        "ok" "$(estado app:otra)"
check "avisa de la vuelta" "2"  "$(avisos)"
check "reinicia el contador" "0" "$(intentos app:otra)"
# Y si vuelve a caer, empieza de cero: puede reintentar otra vez.
abajo otra 3002
N="$(reinicios otra)"
run _watch_run
check "puede reintentar" "$((N + 1))" "$(reinicios otra)"

section "La ventana caduca"
# Tres reinicios repartidos a lo largo del día no son un bucle. Se simula
# envejeciendo el último intento más allá de la ventana.
_watch_state_load
WS_STATE["app:web"]="rendido"; WS_TRIES["app:web"]=3
WS_LAST["app:web"]=$(( $(date +%s) - WATCH_WINDOW - 60 ))
_watch_state_save
N="$(reinicios web)"
run _watch_run
check "vuelve a intentarlo" "$((N + 1))" "$(reinicios web)"
check "y cuenta desde uno"  "1"          "$(intentos app:web)"

section "Umbrales de aviso"
: > "$TMP/notificaciones"
# Sin run(): estas comprobaciones cambian el estado en memoria y un subshell
# se llevaría el cambio por delante.
solo() { _watch_state_load; "$@"; _watch_state_save; }
WATCH_DISK_MAX=0
solo _watch_disk >/dev/null
check "avisa del disco" "alerta" "$(estado disco)"
WATCH_DISK_MAX=100
solo _watch_disk >/dev/null
check "y de la mejora" "ok" "$(estado disco)"
WATCH_MEM_MIN=100
solo _watch_mem >/dev/null
check "avisa de la memoria" "alerta" "$(estado memoria)"
WATCH_MEM_MIN=0
solo _watch_mem >/dev/null
check "y de la mejora" "ok" "$(estado memoria)"

section "Las apps estáticas no se vigilan"
# No tienen proceso: no hay nada que pueda caerse ni que reiniciar.
check "sin estado" "sin-estado" "$(estado app:estatica)"

section "Nivel mínimo de aviso"
cat > "$NOTIFY_CONF" <<EOF
NOTIFY_MIN_LEVEL='crit'
NOTIFY_WEBHOOK='https://avisos.test/hook'
EOF
: > "$TMP/notificaciones"
notify info "esto no debería salir"
notify warn "esto tampoco"
check "filtra por debajo" "0" "$(avisos)"
notify crit "esto sí"
check "deja pasar crit" "1" "$(avisos)"

section "Sin configurar no se envía nada"
rm -f "$NOTIFY_CONF"
: > "$TMP/notificaciones"
notify crit "al vacío"
check "no envía" "0" "$(avisos)"
notify_configured && r=si || r=no
check "y lo sabe" "no" "$r"

section "Historial"
run cmd_watch --history >"$TMP/hist" 2>&1
check "muestra eventos" "si" "$(grep -q 'app:web' "$TMP/hist" && echo si || echo no)"
check "explica el silencio" "1" "$(grep -c 'un servidor sano no escribe nada' "$TMP/hist")"

section "El temporizador"
# Escribir las unidades no puede depender de que systemd conteste: en un
# contenedor sin systemd, un daemon-reload fallido mataba el comando por
# errexit justo después de escribirlas, sin decir nada.
UNITDIR="$TMP/systemd"; mkdir -p "$UNITDIR"
_watch_timer_write() {
  printf 'ExecStart=/usr/local/bin/orbit watch --quiet\n' > "$UNITDIR/orbit-watch.service"
  printf 'OnUnitActiveSec=1min\n' > "$UNITDIR/orbit-watch.timer"
  systemctl daemon-reload 2>/dev/null || warn "systemd no ha recargado las unidades."
}
systemctl() { case "${1:-}" in daemon-reload) return 1 ;; *) return 0 ;; esac; }
run cmd_watch enable >"$TMP/en" 2>&1; r=$?
check "no muere si systemd falla" "0" "$r"
check "avisa de systemd"          "1" "$(grep -c 'contenedor sin systemd\|no ha recargado' "$TMP/en")"
check "confirma la activación"    "1" "$(grep -c 'Vigilancia activada' "$TMP/en")"
check "escribe el servicio"       "1" "$([[ -f "$UNITDIR/orbit-watch.service" ]] && echo 1 || echo 0)"
check "y el temporizador"         "1" "$([[ -f "$UNITDIR/orbit-watch.timer" ]] && echo 1 || echo 0)"
# Y dice explícitamente que no queda ningún proceso residente.
check "explica que no hay demonio" "1" "$(grep -c 'No hay ningún proceso residente' "$TMP/en")"

section "Uso incorrecto"
run cmd_watch --inventado >"$TMP/e" 2>&1; r=$?
check "rechaza opción" "1" "$r"

report
