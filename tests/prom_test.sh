#!/usr/bin/env bash
# ============================================================================
#  Métricas para Prometheus: el fichero que lee el colector de ficheros de
#  node_exporter, y la pasada del vigilante que lo escribe.
#    bash tests/prom_test.sh
#
#  Lo que se comprueba es lo que falla en silencio: un formato que node_exporter
#  rechaza entero —y con él todas las métricas de ese colector—, un «arriba»
#  que no es el del vigilante, un secreto que se cuela en una etiqueta, una
#  foto vieja que se queda publicada y un coste que crece con cada app.
# ============================================================================
# shellcheck disable=SC2034  # asigna variables que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
METRICS_FILE="$TMP/deploys.tsv"
WATCH_STATE="$TMP/watch.state"
WATCH_LOG="$TMP/watch.log"
WATCH_LOCK="$TMP/watch.lock"
NOTIFY_CONF="$TMP/notify.conf"
# 0755 como la crea el paquete: con la umask 002 de Ubuntu saldría escribible
# por el grupo del usuario, y _prom_write se negaría (con razón).
PROMDIR="$TMP/node-exporter"; mkdir -m 0755 "$PROMDIR"

# --- dobles ----------------------------------------------------------------
# systemctl apunta cada llamada, para poder contar cuántas cuesta una pasada.
# 'show' contesta con las propiedades en un orden distinto del pedido, que es
# lo que hace el de verdad, y con un bloque 'not-found' en medio.
SYSLOG="$TMP/systemctl.log"; : > "$SYSLOG"
TIMERS="$TMP/timers"; mkdir -p "$TIMERS"
UP="$TMP/up"; mkdir -p "$UP"
systemctl() {
  printf '%s\n' "$*" >> "$SYSLOG"
  case "${1:-}" in
    show)
      local u
      for u in "$@"; do
        case "$u" in
          orbit-*.service)
            if [[ -f "$TMP/restarts-${u%.service}" ]]; then
              printf 'NRestarts=%s\nId=%s\nLoadState=loaded\n\n' "$(cat "$TMP/restarts-${u%.service}")" "$u"
            else
              printf 'Id=%s\nLoadState=not-found\nNRestarts=0\n\n' "$u"
            fi ;;
        esac
      done ;;
    is-active)
      local x="${*: -1}"
      [[ -f "$TIMERS/$x" || -f "$UP/$x" ]] ;;
    restart) return 0 ;;
    *) return 0 ;;
  esac
}
CURLS="$TMP/curls"; : > "$CURLS"
curl() {
  local url="${*: -1}"
  case "$url" in
    http://127.0.0.1:*)
      printf '%s\n' "$url" >> "$CURLS"
      local p="${url##*:}"; [[ -f "$UP/port${p%%/*}" ]] ;;
    *) printf '%s\n' "$*" >> "$TMP/notificaciones"; return 0 ;;
  esac
}
: > "$TMP/notificaciones"
touch "$UP/nginx" "$UP/postgresql" "$UP/php8.3-fpm"

# Un formato que node_exporter acepta, comprobado línea a línea y sin promtool:
# cada familia con su HELP y su TYPE delante y sus muestras juntas, nombres
# válidos, etiquetas bien cerradas, valores numéricos y los contadores con
# '_total'. Devuelve las líneas que no lo cumplen.
formato() { # formato <fichero>
  awk '
    function fam(n) { sub(/\{.*/, "", n); sub(/ .*/, "", n); return n }
    /^# HELP / { h[$3] = 1; if ($3 in visto) print "HELP repetido: " $3; next }
    /^# TYPE / { if (!($3 in h)) print "TYPE sin HELP: " $3
                 if ($4 !~ /^(gauge|counter)$/) print "tipo raro: " $0
                 if ($4 == "counter" && $3 !~ /_total$/) print "contador sin _total: " $3
                 if ($3 in tipo) print "TYPE repetido: " $3
                 tipo[$3] = $4; actual = $3; next }
    /^#/ { print "comentario raro: " $0; next }
    /^$/ { print "línea vacía"; next }
    { f = fam($0)
      if (f != actual) print "muestra fuera de su familia: " $0
      visto[f] = 1
      if ($0 !~ /^[a-zA-Z_:][a-zA-Z0-9_:]*(\{([a-zA-Z_][a-zA-Z0-9_]*="([^"\\]|\\.)*"(,[a-zA-Z_][a-zA-Z0-9_]*="([^"\\]|\\.)*")*)\})? -?[0-9]+(\.[0-9]+)?$/)
        print "muestra mal formada: " $0 }
  ' "$1"
}
valor() { # valor <fichero> <muestra sin valor> -> el valor, o vacío
  awk -v k="$2" 'index($0, k " ") == 1 { print substr($0, length(k) + 2) }' "$1"
}

mkapp web node 3001 web.test
mkapp api node 3002 api.test
mkapp est static "" est.test

# ═══════════════════════════════════════════════════════════════════════════
section "El escapado de las etiquetas"
_prom_esc_v X 'a\b"c'$'\n''d'
check "barra, comilla y salto"   'a\\b\"c\nd' "$X"
_prom_esc_v X 'web.test'
check "lo normal queda igual"    'web.test' "$X"

# ═══════════════════════════════════════════════════════════════════════════
section "La fecha del histórico, en awk que no es gawk"
# Ubuntu trae mawk, sin mktime. La conversión es aritmética y tiene que dar lo
# mismo que 'date' con husos de los dos signos, con y sin dos puntos, y en un
# 29 de febrero. Se ejecuta con cada awk que haya en la máquina.
FECHAS=(1970-01-01T00:00:00+00:00 2000-02-29T23:59:59-05:30 2026-03-01T00:00:00+0100
        2026-08-10T16:21:04+00:00 2038-01-19T03:14:08+00:00)
esperado=""; for d in "${FECHAS[@]}"; do esperado+="$(date -d "$d" +%s) "; done
for aw in awk mawk gawk; do
  command -v "$aw" >/dev/null || continue
  obtenido="$(printf '%s\n' "${FECHAS[@]}" | "$aw" "$_PROM_AWK_EPOCH"' { printf "%.0f ", epoch($1) }')"
  check "epoch con $aw"           "$esperado" "$obtenido"
done
check "lo que no es fecha, vacío" "x" "$(echo basura | awk "$_PROM_AWK_EPOCH"' { printf "x%s", epoch($1) }')"

# ═══════════════════════════════════════════════════════════════════════════
section "Lo que se publica"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  2026-08-10T16:00:00+00:00 web ok 30 20 r1 aaa - - \
  2026-08-10T17:00:00+00:00 web ok 40 25 r2 bbb - - \
  2026-08-10T20:00:00+02:00 web fallo 5 - - - build "el build ha fallado" \
  2026-08-10T16:00:00+00:00 api fallo 3 - - - code - \
  2026-08-10T16:00:00+00:00 borrada ok 1 1 r x - - \
  > "$METRICS_FILE"
echo 2 > "$TMP/restarts-orbit-web"
mkdir -p "$TMP/apps/web/rel" "$TMP/apps/web/shared"
ln -s "$TMP/apps/web/rel" "$TMP/apps/web/current"
touch -h -d @1786000000 "$TMP/apps/web/current"
touch "$TMP/apps/web/shared/maintenance.on"
_lock_write api "probando" >/dev/null 2>&1
load_app est; A_AUTODEPLOY="yes"; save_app
touch "$TIMERS/orbit-watch.timer"
_watch_state_load
WS_STATE["app:web"]="ok"; WS_STATE["app:api"]="rendido"
: > "$SYSLOG"
run _prom_render --fresh > "$TMP/m1"; r=$?
check "sale bien"                "0" "$r"
check "formato sin fallos"       "" "$(formato "$TMP/m1")"
check "versión"                  "1" "$(valor "$TMP/m1" "orbit_info{version=\"$ORBIT_VERSION\"}")"
check "app arriba"               "1" "$(valor "$TMP/m1" 'orbit_app_up{app="web"}')"
check "rendida es abajo"         "0" "$(valor "$TMP/m1" 'orbit_app_up{app="api"}')"
# Una web estática no tiene proceso que pueda caerse: un 'up' suyo sería
# inventado, y un 0 por defecto, una alerta falsa.
check "la estática no tiene up"  "" "$(valor "$TMP/m1" 'orbit_app_up{app="est"}')"
check "ni se pregunta por su unidad" "0" "$(grep -c 'orbit-est.service' "$SYSLOG")"
check "reinicios de systemd"     "2" "$(valor "$TMP/m1" 'orbit_app_restarts_total{app="web"}')"
check "unidad sin cargar, nada"  "" "$(valor "$TMP/m1" 'orbit_app_restarts_total{app="api"}')"
check "mantenimiento"            "1" "$(valor "$TMP/m1" 'orbit_app_maintenance{app="web"}')"
check "sin mantenimiento"        "0" "$(valor "$TMP/m1" 'orbit_app_maintenance{app="api"}')"
check "congelada"                "1" "$(valor "$TMP/m1" 'orbit_app_locked{app="api"}')"
check "autodespliegue"           "1" "$(valor "$TMP/m1" 'orbit_app_autodeploy_enabled{app="est"}')"
check "release: fecha del enlace" "1786000000" "$(valor "$TMP/m1" 'orbit_app_current_release_timestamp_seconds{app="web"}')"
check "sin release, nada"        "" "$(valor "$TMP/m1" 'orbit_app_current_release_timestamp_seconds{app="api"}')"
# El último intento es el fallo de las 20:00+02:00, que son las 18:00 UTC.
check "último intento, con huso" "$(date -d 2026-08-10T18:00:00Z +%s)" "$(valor "$TMP/m1" 'orbit_app_last_deploy_timestamp_seconds{app="web"}')"
check "el último falló"          "0" "$(valor "$TMP/m1" 'orbit_app_last_deploy_success{app="web"}')"
check "lo que tardó"             "5" "$(valor "$TMP/m1" 'orbit_app_last_deploy_duration_seconds{app="web"}')"
# El fallo no llegó a compilar: el build que vale es el anterior que terminó.
check "último build que terminó" "25" "$(valor "$TMP/m1" 'orbit_app_last_build_duration_seconds{app="web"}')"
check "último correcto"          "$(date -d 2026-08-10T17:00:00Z +%s)" "$(valor "$TMP/m1" 'orbit_app_last_successful_deploy_timestamp_seconds{app="web"}')"
check "sin ninguno correcto"     "" "$(valor "$TMP/m1" 'orbit_app_last_successful_deploy_timestamp_seconds{app="api"}')"
check "correctos"                "2" "$(valor "$TMP/m1" 'orbit_app_deploys{app="web",result="ok"}')"
check "fallidos"                 "1" "$(valor "$TMP/m1" 'orbit_app_deploys{app="web",result="failed"}')"
# Una app que ya no existe no publica series: seguirían en Grafana para
# siempre con su último valor.
check "la borrada no sale"       "0" "$(grep -c 'app="borrada"' "$TMP/m1")"
check "temporizador activo"      "1" "$(valor "$TMP/m1" 'orbit_timer_active{timer="watch"}')"
check "temporizador parado"      "0" "$(valor "$TMP/m1" 'orbit_timer_active{timer="queue"}')"
check "sin certificados, nada"   "0" "$(grep -c '^orbit_cert_expiry' "$TMP/m1")"
check "contador con su tipo"     "1" "$(grep -cx '# TYPE orbit_app_restarts_total counter' "$TMP/m1")"
# 'deploys' no es un contador: la poda del histórico lo hace bajar, y un
# contador que baja es un reinicio para Prometheus — rate() se inventaría un
# pico del tamaño del histórico entero.
check "deploys es un gauge"      "1" "$(grep -cx '# TYPE orbit_app_deploys gauge' "$TMP/m1")"

if command -v promtool >/dev/null; then
  promtool check metrics < "$TMP/m1" >"$TMP/pt" 2>&1; r=$?
  check "promtool lo acepta"     "0" "$r"
else
  echo "  (promtool no está en el PATH: el formato lo valida la comprobación de arriba)"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "Sin el vigilante de este minuto, lo que dejó el último"
# Fuera de la pasada se lee el fichero de estado, y se publica su hora: con el
# vigilante parado, un 'up' sin fecha diría más de lo que sabe.
WS_STATE=(); WS_STATE["app:web"]="fallo"; _watch_state_save
touch -d @1786100000 "$WATCH_STATE"
WS_STATE=()
run _prom_render > "$TMP/m2"
check "lee el estado guardado"   "0" "$(valor "$TMP/m2" 'orbit_app_up{app="web"}')"
check "y dice de cuándo es"      "1786100000" "$(valor "$TMP/m2" 'orbit_watch_last_run_timestamp_seconds')"
check "sin estado de la app, nada" "" "$(valor "$TMP/m2" 'orbit_app_up{app="api"}')"
rm -f "$WATCH_STATE"
run _prom_render > "$TMP/m3"
check "sin vigilante nunca, sin up" "0" "$(grep -c '^orbit_app_up' "$TMP/m3")"
check "ni hora inventada"        "0" "$(grep -c '^orbit_watch_last_run' "$TMP/m3")"
check "y sigue siendo válido"    "" "$(formato "$TMP/m3")"

# ═══════════════════════════════════════════════════════════════════════════
section "Lo que no se publica"
# La URL de un repositorio privado puede llevar un token dentro, y el .env es
# justo lo que no puede salir de la máquina. Se siembran los dos con algo que
# se reconozca y se busca en la salida entera.
load_app web
A_REPO="https://x-access-token:ghp_SECRETO123@github.com/acme/web.git"; A_BRANCH="rama-secreta"
save_app
mkdir -p "$TMP/apps/web/shared"; printf 'DATABASE_URL=postgres://u:CLAVE456@db/x\n' > "$TMP/apps/web/shared/.env"
run _prom_render --fresh > "$TMP/m4"
check "ni el token del repo"     "0" "$(grep -c 'SECRETO123' "$TMP/m4")"
check "ni la URL"                "0" "$(grep -c 'github.com' "$TMP/m4")"
check "ni la rama"               "0" "$(grep -c 'rama-secreta' "$TMP/m4")"
check "ni el .env"               "0" "$(grep -c 'CLAVE456' "$TMP/m4")"

# ═══════════════════════════════════════════════════════════════════════════
section "El coste no crece con las apps"
# Corre cada minuto. Lo que no puede pasar es una llamada a systemctl por app:
# con 40 apps serían 40 procesos por minuto para decir lo que dice uno.
: > "$SYSLOG"; run _prom_render --fresh >/dev/null
antes="$(wc -l < "$SYSLOG")"
for i in 1 2 3 4 5 6; do mkapp "extra$i" node "$((3100 + i))" "extra$i.test"; done
: > "$SYSLOG"; run _prom_render --fresh >/dev/null
check "las mismas llamadas con 6 apps más" "$antes" "$(wc -l < "$SYSLOG")"
check "un solo show para todas"  "1" "$(grep -c '^show' "$SYSLOG")"
for i in 1 2 3 4 5 6; do rm -f "$TMP/etc/apps/extra$i.conf"; done

# ═══════════════════════════════════════════════════════════════════════════
section "Los certificados se abren una vez por pasada"
# El vigilante ya pregunta cuándo caduca cada uno. Si las métricas volvieran a
# abrirlos, serían dos procesos más por certificado y minuto para nada.
CERTS="$TMP/certs"; mkdir -p "$CERTS"
if command -v openssl >/dev/null; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CERTS/k.pem" -out "$CERTS/web.test.pem" \
    -days 30 -subj "/CN=web.test" >/dev/null 2>&1
  cert_file() { echo "$CERTS/$1.pem"; }
  OPENSSL_CALLS="$TMP/openssl.calls"; : > "$OPENSSL_CALLS"
  openssl() { echo x >> "$OPENSSL_CALLS"; command openssl "$@"; }
  fin="$(date -d "$(command openssl x509 -enddate -noout -in "$CERTS/web.test.pem" | cut -d= -f2)" +%s)"
  METRICS_PROM_DIR="$PROMDIR"
  touch "$UP/port3001" "$UP/orbit-web"
  run _watch_run >/dev/null 2>&1
  check "la pasada escribe el fichero" "1" "$([[ -f "$PROMDIR/orbit.prom" ]] && echo 1 || echo 0)"
  check "caducidad publicada"    "$fin" "$(valor "$PROMDIR/orbit.prom" 'orbit_cert_expiry_timestamp_seconds{app="web",domain="web.test"}')"
  check "openssl una sola vez"   "1" "$(wc -l < "$OPENSSL_CALLS")"
  check "con certificado, válido" "" "$(formato "$PROMDIR/orbit.prom")"
  if command -v promtool >/dev/null; then
    promtool check metrics < "$PROMDIR/orbit.prom" >"$TMP/pt" 2>&1; r=$?
    check "promtool acepta la pasada entera" "0" "$r"
  fi
  # Con un certificado de origen de Cloudflare (1.4.7) el vhost sirve ése y no
  # el de Let's Encrypt que pudiera quedar: la caducidad publicada tiene que
  # ser la suya, o Grafana avisaría de un certificado que ya no sirve nadie y
  # callaría el que sí.
  mkdir -p "$ORIGIN_CERT_DIR/web"
  command openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ORIGIN_CERT_DIR/web/key.pem" \
    -out "$ORIGIN_CERT_DIR/web/cert.pem" -days 5475 -subj "/CN=web.test" >/dev/null 2>&1
  fin_origen="$(date -d "$(command openssl x509 -enddate -noout -in "$ORIGIN_CERT_DIR/web/cert.pem" | cut -d= -f2)" +%s)"
  declare -A CERT_END=()
  run _watch_run >/dev/null 2>&1
  check "con origen, su caducidad" "$fin_origen" "$(valor "$PROMDIR/orbit.prom" 'orbit_cert_expiry_timestamp_seconds{app="web",domain="web.test"}')"
  rm -rf "${ORIGIN_CERT_DIR:?}/web"
  declare -A CERT_END=()
  # Lo guardado es de la pasada. cert_days_left vuelve a leer: en un mismo
  # proceso puede haber un 'orbit ssl' entre medias, y un «no hay» de antes de
  # emitir el certificado seguiría diciéndolo después.
  declare -A CERT_END=(["web.test"]="")
  dias="$(cert_days_left web.test)"
  check "cert_days_left no se fía de lo guardado" "1" "$([[ "$dias" =~ ^(29|30)$ ]] && echo 1 || echo "«$dias»")"
  unset -f openssl
  cert_file() { echo "/nonexistent/$1.pem"; }
  METRICS_PROM_DIR=""
else
  echo "  me salto la caducidad de certificados: falta openssl"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "La pasada del vigilante: el up es el suyo, y del mismo minuto"
METRICS_PROM_DIR="$PROMDIR"; rm -f "$PROMDIR/orbit.prom" "$WATCH_STATE"
touch "$UP/port3001" "$UP/orbit-web"; rm -f "$UP/port3002" "$UP/orbit-api"
: > "$CURLS"
run _watch_run >/dev/null 2>&1
check "web arriba"               "1" "$(valor "$PROMDIR/orbit.prom" 'orbit_app_up{app="web"}')"
check "api abajo en esta pasada" "0" "$(valor "$PROMDIR/orbit.prom" 'orbit_app_up{app="api"}')"
# Ni un curl más que los del propio vigilante: las métricas reutilizan su
# respuesta. Con las métricas apagadas se hacen los mismos.
con="$(wc -l < "$CURLS")"; : > "$CURLS"
METRICS_PROM_DIR=""; run _watch_run >/dev/null 2>&1; METRICS_PROM_DIR="$PROMDIR"
check "ningún curl de más"       "$(wc -l < "$CURLS")" "$con"
check "fichero legible por node_exporter" "644" "$(stat -c %a "$PROMDIR/orbit.prom")"
check "sin temporales al lado"   "0" "$(find "$PROMDIR" -name '.orbit.prom.*' | wc -l)"
check "y válido"                 "" "$(formato "$PROMDIR/orbit.prom")"

section "Si no se puede escribir, la vigilancia sigue y avisa una vez"
# Todo lo demás sano y ya anotado, para que el único cambio de estado que
# pueda avisar sea el de las métricas.
touch "$UP/port3002" "$UP/orbit-api"; run _watch_run >/dev/null 2>&1
cp "$PROMDIR/orbit.prom" "$TMP/antes.prom"
: > "$TMP/notificaciones"; printf 'NOTIFY_WEBHOOK=%s\n' "'https://hook.test/x'" > "$NOTIFY_CONF"
# Un fallo a mitad de escribir. Con eval porque la definición de verdad se
# repone más abajo, y shellcheck tomaría esta por la única.
eval '_prom_render() { return 1; }'
run _watch_run >/dev/null 2>&1; r=$?
check "la pasada no se cae"      "0" "$r"
check "el estado se guarda"      "1" "$([[ -f "$WATCH_STATE" ]] && echo 1 || echo 0)"
check "el fichero anterior, intacto" "" "$(cmp "$TMP/antes.prom" "$PROMDIR/orbit.prom" 2>&1)"
check "sin temporales a medias"  "0" "$(find "$PROMDIR" -name '.orbit.prom.*' | wc -l)"
check "queda en alerta"          "alerta" "$(_watch_state_load; printf '%s' "${WS_STATE[prom]:-}")"
# El webhook lleva la URL por stdin (-K -) para que no salga en 'ps': aquí se
# cuentan las llamadas, no se busca la dirección.
n1="$(grep -c . "$TMP/notificaciones")"
run _watch_run >/dev/null 2>&1
check "avisa una vez, no cada minuto" "$n1" "$(grep -c . "$TMP/notificaciones")"
check "y avisó"                  "1" "$(( n1 >= 1 ))"
# Se recupera el renderizador de verdad del script.
eval "$(sed -n '/^_prom_render() {/,/^}/p' "$TMP/orbitlib.sh")"
run _watch_run >/dev/null 2>&1
check "vuelve a ok"              "ok" "$(_watch_state_load; printf '%s' "${WS_STATE[prom]:-}")"
rm -f "$NOTIFY_CONF"

# ═══════════════════════════════════════════════════════════════════════════
section "Encender y apagar"
CONF="$TMP/etc/orbit.conf"; cp "$CONF" "$TMP/conf.bak"
METRICS_PROM_DIR=""; rm -f "$PROMDIR/orbit.prom"
run _prom_enable "$TMP/no-existe" >"$TMP/o" 2>&1; r=$?
check "carpeta que no existe: no" "1" "$r"
check "y no apunta nada"          "0" "$(grep -c METRICS_PROM_DIR "$CONF")"
run _prom_enable "relativa/x" >/dev/null 2>&1; r=$?
check "ruta relativa: no"         "1" "$r"

# Una carpeta que puede escribir otro —el usuario de node_exporter, en las
# instalaciones que se la dan a él— es una carpeta donde ese otro elige qué
# fichero sobrescribe root: entre el mktemp y el mv cambia el temporal por un
# enlace. Ni se enciende ni, si cambia después, se escribe.
mkdir -p "$TMP/ajena"; chmod 0777 "$TMP/ajena"; touch "$TIMERS/orbit-watch.timer"
run _prom_enable "$TMP/ajena" >"$TMP/o" 2>&1; r=$?
check "carpeta que escribe otro: no" "1" "$r"
check "y dice cómo arreglarlo"    "1" "$(grep -c 'chown root:root' "$TMP/o")"
check "sin apuntar nada"          "0" "$(grep -c METRICS_PROM_DIR "$CONF")"
check "ni dejar fichero"          "0" "$(find "$TMP/ajena" -type f | wc -l)"
METRICS_PROM_DIR="$TMP/ajena"; _prom_refresh --fresh
check "la pasada tampoco escribe" "1" "$PROM_RC"
check "ni temporales"             "0" "$(find "$TMP/ajena" -type f | wc -l)"
chmod 1777 "$TMP/ajena"; _prom_refresh --fresh
# Con el bit pegajoso nadie puede renombrar ni borrar lo que no es suyo.
check "pegajosa sí"               "0" "$PROM_RC"
chmod 0777 "$TMP/ajena"; rm -f "$TMP/ajena/"*
# Y por un enlace, que es como se apunta a menudo a la carpeta del colector:
# _paths_unsafe no sigue enlaces, y el enlace pasaba la comprobación con una
# carpeta 0777 al otro lado.
ln -s "$TMP/ajena" "$TMP/enlace-ajena"
run _prom_enable "$TMP/enlace-ajena" >"$TMP/o" 2>&1; r=$?
check "por un enlace, tampoco"    "1" "$r"
check "y nombra la de verdad"     "1" "$(grep -q "$TMP/ajena " "$TMP/o" && echo 1)"
METRICS_PROM_DIR="$TMP/enlace-ajena"; _prom_refresh --fresh
check "ni la pasada por el enlace" "1" "$PROM_RC"
check "ni deja nada al otro lado" "0" "$(find "$TMP/ajena" -type f | wc -l)"
DOC_ID=(); DOC_LEVEL=(); _doctor_prom
check "doctor lo ve por el enlace" "error" "$(for i in "${!DOC_ID[@]}"; do [[ "${DOC_ID[$i]}" == prom ]] && echo "${DOC_LEVEL[$i]}"; done)"
# Ni con la de arriba en manos de otro: puede cambiarle el nombre a la de
# abajo y poner la suya.
mkdir -p "$TMP/ajena/hija"; chmod 0755 "$TMP/ajena/hija"
METRICS_PROM_DIR="$TMP/ajena/hija"; _prom_refresh --fresh
check "ni bajo una carpeta ajena" "1" "$PROM_RC"
# Un enlace a una carpeta buena sigue valiendo, y escribe al otro lado.
mkdir -m 0755 "$TMP/buena"; ln -s "$TMP/buena" "$TMP/enlace-buena"
METRICS_PROM_DIR="$TMP/enlace-buena"; _prom_refresh --fresh
check "un enlace a una buena, sí" "0" "$PROM_RC"
check "y escribe en la de verdad" "1" "$([[ -f "$TMP/buena/orbit.prom" && ! -L "$TMP/buena/orbit.prom" ]] && echo 1 || echo 0)"
rm -rf "$TMP/ajena" "$TMP/enlace-ajena" "$TMP/buena" "$TMP/enlace-buena"; METRICS_PROM_DIR=""

run _prom_enable "$PROMDIR/" >"$TMP/o" 2>&1; r=$?
check "enciende"                  "0" "$r"
check "lo apunta en orbit.conf"   "1" "$(grep -cx "METRICS_PROM_DIR='$PROMDIR'" "$CONF")"
check "y lo escribe ya"           "1" "$([[ -f "$PROMDIR/orbit.prom" ]] && echo 1 || echo 0)"

# Sin vigilante no se deja el fichero: nadie lo refrescaría.
rm -f "$TIMERS/orbit-watch.timer" "$PROMDIR/orbit.prom"
run _prom_enable "$PROMDIR" >"$TMP/o" 2>&1; r=$?
check "sin vigilante también se enciende" "0" "$r"
check "pero no deja una foto"     "0" "$([[ -f "$PROMDIR/orbit.prom" ]] && echo 1 || echo 0)"
check "y lo dice"                 "1" "$(grep -c 'orbit watch enable' "$TMP/o")"

# Cambiar de carpeta no deja la vieja publicando para siempre.
touch "$TIMERS/orbit-watch.timer"
METRICS_PROM_DIR="$PROMDIR"; touch "$PROMDIR/orbit.prom"
mkdir -m 0755 "$TMP/otra"
run _prom_enable "$TMP/otra" >/dev/null 2>&1
check "la carpeta vieja se vacía" "0" "$([[ -f "$PROMDIR/orbit.prom" ]] && echo 1 || echo 0)"
check "la nueva se llena"         "1" "$([[ -f "$TMP/otra/orbit.prom" ]] && echo 1 || echo 0)"

METRICS_PROM_DIR="$TMP/otra"
run _prom_disable >/dev/null 2>&1; r=$?
check "apaga"                     "0" "$r"
check "borra el fichero"          "0" "$([[ -f "$TMP/otra/orbit.prom" ]] && echo 1 || echo 0)"
check "y lo quita de orbit.conf"  "1" "$(grep -cx "METRICS_PROM_DIR=''" "$CONF")"

section "Parar la vigilancia retira el fichero"
METRICS_PROM_DIR="$PROMDIR"; touch "$PROMDIR/orbit.prom"
watch_unit() { echo "$TMP/systemd/orbit-watch.timer"; }
run cmd_watch disable >"$TMP/o" 2>&1
check "sin vigilante, sin foto"   "0" "$([[ -f "$PROMDIR/orbit.prom" ]] && echo 1 || echo 0)"
check "y lo cuenta"               "1" "$(grep -c "$PROMDIR/orbit.prom" "$TMP/o")"
cp "$TMP/conf.bak" "$CONF"

# ═══════════════════════════════════════════════════════════════════════════
section "doctor"
_idx_de() { local i; for i in "${!DOC_ID[@]}"; do [[ "${DOC_ID[$i]}" == "$1" ]] && { echo "${DOC_LEVEL[$i]}"; return; }; done; }
DOC_LEVEL=(); DOC_ID=(); DOC_MSG=(); DOC_FIX=(); DOC_ACT=()
METRICS_PROM_DIR=""; _doctor_prom
check "apagadas: nada que decir"  "" "$(_idx_de prom)"
METRICS_PROM_DIR="$TMP/no-existe"; _doctor_prom
check "carpeta perdida: error"    "error" "$(_idx_de prom)"
DOC_ID=(); DOC_LEVEL=(); METRICS_PROM_DIR="$PROMDIR"; rm -f "$TIMERS/orbit-watch.timer"; _doctor_prom
check "sin vigilante: aviso"      "warn" "$(_idx_de prom)"
DOC_ID=(); DOC_LEVEL=(); touch "$TIMERS/orbit-watch.timer"; touch -d '-10 min' "$PROMDIR/orbit.prom"; _doctor_prom
check "viejo: aviso"              "warn" "$(_idx_de prom)"
DOC_ID=(); DOC_LEVEL=(); touch "$PROMDIR/orbit.prom"; _doctor_prom
check "al día: bien"              "ok" "$(_idx_de prom)"
DOC_ID=(); DOC_LEVEL=(); chmod o+w "$PROMDIR"; _doctor_prom
check "la escribe otro: error"    "error" "$(_idx_de prom)"
chmod o-w "$PROMDIR"
METRICS_PROM_DIR=""

# ═══════════════════════════════════════════════════════════════════════════
section "Por la línea de órdenes"
sed "s|^ETC_DIR=.*|ETC_DIR=\"$TMP/etc\"|; \
     s|^LOG_FILE=.*|LOG_FILE=\"$TMP/orbit.log\"|; \
     s|^if \[\[ \$EUID -ne 0 \]\]; then|if false; then|; \
     s|^if \[\[ \$EUID -eq 0 \&\& .*SUDO_UID.*; then\$|if false; then|; \
     s|^WATCH_STATE=.*|WATCH_STATE=\"$TMP/watch.state\"|; \
     s|^need_root() {.*|need_root() { return 0; }|" \
    "$ORBIT_ROOT/orbit" > "$TMP/orbitcli"
chmod +x "$TMP/orbitcli"
O="$TMP/orbitcli"
METRICS_FILE="$METRICS_FILE" "$O" metrics --prom >"$TMP/c1" 2>"$TMP/c1e"; r=$?
check "metrics --prom"            "0" "$r"
check "por stdout sólo métricas"  "" "$(formato "$TMP/c1")"
check "y nada por stderr"         "0" "$(grep -c . "$TMP/c1e")"
"$O" --json metrics --prom >"$TMP/c2" 2>/dev/null; r=$?
check "--json con --prom: no"     "1" "$r"
check "sin nada en stdout"        "0" "$(grep -c . "$TMP/c2")"
"$O" metrics --prom web >/dev/null 2>&1; r=$?
check "--prom va solo"            "1" "$r"
"$O" --json metrics prom status >"$TMP/c3" 2>/dev/null; r=$?
check "--json en prom: no"        "1" "$r"
check "sin nada en stdout "       "0" "$(grep -c . "$TMP/c3")"
"$O" metrics prom noexiste >/dev/null 2>&1; r=$?
check "subcomando desconocido"    "1" "$r"
"$O" metrics prom status >"$TMP/c4" 2>&1; r=$?
check "status"                    "0" "$r"
check "dice que están apagadas"   "1" "$(grep -c 'orbit metrics prom enable' "$TMP/c4")"
"$O" metrics prom --help >/dev/null 2>&1; r=$?
check "pedir ayuda no es error"   "0" "$r"
"$O" --json metrics >"$TMP/c5" 2>/dev/null; r=$?
check "metrics --json sigue igual" "{" "$(head -c1 "$TMP/c5")"

report
