#!/usr/bin/env bash
# El panel en vivo: la medida de CPU, la de memoria y el recuento de
# peticiones, que son lo único de 'orbit top' que puede estar mal.
#   bash tests/top_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, TOP_*…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"

# --- dobles de las piezas del sistema --------------------------------------
# systemd contesta lo que digan estas variables, que es como se controla desde
# la prueba lo que "consume" cada app.
UP="$TMP/up"; mkdir -p "$UP"
FAKE_MEM="0"; FAKE_CPU="0"
systemctl() {
  case "${1:-}" in
    is-active) [[ -f "$UP/${3:-${2:-}}" ]] ;;
    # systemctl show <unidad> -p <propiedad> --value
    show)
      case "${4:-}" in
        MemoryCurrent) printf '%s\n' "$FAKE_MEM" ;;
        CPUUsageNSec)  printf '%s\n' "$FAKE_CPU" ;;
      esac ;;
    *) return 0 ;;
  esac
}
LOGDIR="$TMP/nginx"; mkdir -p "$LOGDIR"
nginx_log_access() { echo "$LOGDIR/$1.access.log"; }

mkapp web  next   3001 web.test
mkapp docs static ""   docs.test
touch "$UP/orbit-web"

section "Memoria en unidades humanas"
check "bytes"        "512B"  "$(_human_bytes 512)"
check "kilobytes"    "2K"    "$(_human_bytes 2048)"
check "megabytes"    "128M"  "$(_human_bytes 134217728)"
check "gigabytes"    "1,5G"  "$(_human_bytes 1610612736)"
check "cero"         "0B"    "$(_human_bytes 0)"
# systemd devuelve '[not set]' cuando la unidad no lleva contabilidad, y eso no
# es un cero: es que no se sabe.
check "sin dato"     "·"     "$(_human_bytes '[not set]')"
check "vacío"        "·"     "$(_human_bytes '')"

section "El porcentaje de CPU necesita dos lecturas"
TOP_CPU_PREV=(); TOP_TS_PREV=()
FAKE_MEM=134217728; FAKE_CPU=1000000000
_top_measure web next 1000000000000 0
check "estado"             "running" "$TM_STATE"
check "memoria"            "134217728" "$TM_MEM"
# La primera no puede dar porcentaje: no hay contra qué comparar. Inventarse un
# cero sería mentir, porque un cero es una afirmación.
check "sin porcentaje aún" ""        "$TM_PCT"
# Un segundo después (1e9 ns) habiendo gastado 0,05 s de CPU: 5,0 %.
FAKE_CPU=1050000000
_top_measure web next 1001000000000 0
check "5,0 %"              "50"      "$TM_PCT"
check "y se pinta"         "5,0%"    "$(_top_pct_text)"
# Medio segundo gastando 0,25 s son dos núcleos a tope: 50 %… de un núcleo cada
# uno. El total puede pasar de 100 y eso es correcto.
FAKE_CPU=1550000000
_top_measure web next 1001500000000 0
check "puede pasar de 100" "1000"    "$TM_PCT"
check "y se pinta"         "100,0%"  "$(_top_pct_text)"

section "Una app parada no arrastra su muestra"
rm -f "$UP/orbit-web"
FAKE_CPU=9999999999
_top_measure web next 1002000000000 0
check "parada"             "stopped" "$TM_STATE"
check "sin memoria"        ""        "$TM_MEM"
check "sin porcentaje"     ""        "$TM_PCT"
# Lo que se prueba de verdad: al volver, la primera medición no compara contra
# la muestra de antes de pararse. Si lo hiciera, pintaría un pico gigante que
# no ha ocurrido nunca.
touch "$UP/orbit-web"
FAKE_CPU=9999999999
_top_measure web next 1003000000000 0
check "empieza de cero"    ""        "$TM_PCT"
_top_measure web next 1004000000000 0
check "y a la siguiente sí" "0"      "$TM_PCT"

section "Un contador que retrocede no cuenta"
# Al reiniciarse una unidad, CPUUsageNSec vuelve a empezar. La resta daría un
# número negativo, y un negativo pintado como porcentaje asusta sin motivo.
TOP_CPU_PREV=(); TOP_TS_PREV=()
FAKE_CPU=5000000000; _top_measure web next 2000000000000 0
FAKE_CPU=1000000;    _top_measure web next 2001000000000 0
check "se calla"           ""        "$TM_PCT"

section "Peticiones del último minuto"
LOG="$LOGDIR/web.access.log"
linea() { # linea <hace cuántos segundos>
  LC_ALL=C date -d "$1 seconds ago" '+[%d/%b/%Y:%H:%M:%S +0000] 1.2.3.4 - web.test "GET / HTTP/1.1" 200 12'
}
# En orden cronológico, que es como los escribe nginx: lo nuevo abajo. Importa
# para la prueba del tope de más abajo, que se queda con el final del fichero.
{ linea 3600; linea 90; linea 50; linea 20; linea 10; } > "$LOG"
TM_REQ=""; TM_CAP="no"
_top_reqs web "$(date -d '1 minute ago' '+%Y%m%d%H%M%S')"
check "sólo el último minuto" "3"    "$TM_REQ"
check "sin tope"              "no"   "$TM_CAP"

# El tope existe porque el log de una web con tráfico son cientos de megas y
# esto se refresca cada dos segundos. Se queda con las últimas líneas, que son
# las recientes; quedarse con las primeras daría siempre cero. Y lo avisa: un
# número corto sin avisar se lee como que hay poco tráfico.
TOP_LOG_LINES=2
TM_REQ=""; TM_CAP="no"
_top_reqs web "$(date -d '1 minute ago' '+%Y%m%d%H%M%S')"
check "se queda en el tope"   "2"    "$TM_REQ"
check "y lo avisa"            "yes"  "$TM_CAP"
TOP_LOG_LINES=5000

# Un log del formato antiguo no lleva fecha y no se puede filtrar: mejor no dar
# número que dar uno inventado. Es el mismo criterio que 'orbit logs --since'.
printf '1.2.3.4 - web.test "GET / HTTP/1.1" 200 12\n' > "$LOG"
TM_REQ=""; TM_CAP="no"
_top_reqs web "$(date -d '1 minute ago' '+%Y%m%d%H%M%S')"
check "sin marca de tiempo"   ""     "$TM_REQ"

# Sin fichero de log tampoco hay número, y no es un error.
TM_REQ=""
run _top_reqs sin-log "$(date -d '1 minute ago' '+%Y%m%d%H%M%S')"; r=$?
check "sin log, sin ruido"    "0"    "$r"
check "y sin número"          ""     "$TM_REQ"

section "Una foto suelta"
{ linea 10; linea 20; } > "$LOG"
SALIDA="$(run cmd_top --once 2>&1)"
check "sale sin terminal"     "0"    "$?"
check "trae las apps"         "2"    "$(grep -cE '^  (web|docs) ' <<<"$SALIDA")"
check "y el dominio"          "1"    "$(grep -c 'web.test' <<<"$SALIDA")"
# Sin terminal no se entra en el bucle ni se pinta la pantalla alternativa: si
# se colara, un 'orbit top > fichero' no terminaría nunca.
check "sin pantalla alterna"  "0"    "$(grep -c '1049h' <<<"$SALIDA")"

section "Argumentos"
run cmd_top --interval=0 >/dev/null 2>&1; r=$?
check "intervalo 0 no vale"   "1"    "$r"
run cmd_top --interval=dos >/dev/null 2>&1; r=$?
check "intervalo no numérico" "1"    "$r"
run cmd_top --todo >/dev/null 2>&1; r=$?
check "opción desconocida"    "1"    "$r"
run cmd_top --help >/dev/null 2>&1; r=$?
check "pedir ayuda no falla"  "0"    "$r"

if ! command -v jq >/dev/null; then
  printf '\nfalta jq: me salto las pruebas que validan el JSON.\n'
  report
fi

section "orbit top --json"
top_json() { JSON="yes" run cmd_top 2>/dev/null | jq -r "$1" 2>&1; }
check "es JSON válido"   "object" "$(top_json 'type')"
check "las dos apps"     "2"      "$(top_json '.apps | length')"
check "memoria en bytes" "number" "$(top_json '.apps[] | select(.name=="web") | .memory_bytes | type')"
check "cpu con decimal"  "number" "$(top_json '.apps[] | select(.name=="web") | .cpu_percent | type')"
check "peticiones"       "2"      "$(top_json '.apps[] | select(.name=="web") | .requests_last_minute')"
check "sin tope"         "false"  "$(top_json '.apps[] | select(.name=="web") | .requests_capped')"
# La estática no tiene servicio, así que no tiene ni CPU ni memoria que dar.
check "estática sin cpu" "null"   "$(top_json '.apps[] | select(.name=="docs") | .cpu_percent')"
check "ni memoria"       "null"   "$(top_json '.apps[] | select(.name=="docs") | .memory_bytes')"

report
