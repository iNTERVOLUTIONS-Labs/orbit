#!/usr/bin/env bash
# 'orbit traffic': el resumen de visitas que sale del log de nginx.
#   bash tests/traffic_test.sh
#
# Lo que se comprueba aquí no es «suma bien». Es lo otro: que un número que no
# cubre lo que se pidió se anuncie recortado en vez de salir a secas —el log
# tiene 14 días y la ventana puede ser mayor—, que una hora sin tráfico sea un
# cero y no una hora que desaparece del dibujo, y que lo automático se cuente
# aparte en vez de mezclarse con las visitas. Un panel de tráfico que miente
# por omisión es peor que no tenerlo, porque nadie va a comprobarlo.
# shellcheck disable=SC2034  # asigna variables A_*/TRAFFIC_* que lee el 'orbit'
# cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
LOGDIR="$TMP/nginx"; mkdir -p "$LOGDIR"
nginx_log_access() { echo "$LOGDIR/$1.access.log"; }
nginx_log_error()  { echo "$LOGDIR/$1.error.log"; }

# Una línea de log de verdad, con el formato 'orbit' de install.sh.
#   linea <hace-minutos> <ip> <host> <ruta> <estado> <bytes> <referencia> <agente> [rt]
linea() {
  local min="$1" ip="$2" host="$3" ruta="$4" est="$5" by="$6" ref="$7" ua="$8" rt="${9:-0.020}"
  printf '[%s] %s - %s "GET %s HTTP/1.1" %s %s "%s" "%s" rt=%s\n' \
    "$(date -d "-$min minutes" '+%d/%b/%Y:%H:%M:%S %z')" \
    "$ip" "$host" "$ruta" "$est" "$by" "$ref" "$ua" "$rt"
}

mkapp web static ""
load_app web   # A_DOMAIN sale de aquí: es lo que separa una referencia externa
               # de un enlace de la propia web, que en cualquier sitio con menú
               # son el 90% y no dicen de dónde viene nadie.
ACC="$LOGDIR/web.access.log"
# En orden, del más viejo al más nuevo, como cualquier log de verdad: de eso
# depende que la primera línea diga hasta dónde llega lo que hay en disco.
{
  linea 40 5.5.5.5 web.test /.git/config 404  200 -                     'Mozilla/5.0 (compatible; Nmapbot/1.0)'
  linea 40 5.5.5.5 web.test /wp-login    404  200 -                     'curl/8.5.0'
  linea 30 3.3.3.3 web.test /no-existe   404  200 -                     'Mozilla/5.0'
  linea 30 4.4.4.4 web.test /roto        500  100 -                     'Mozilla/5.0' 1.500
  linea 20 2.2.2.2 web.test /precios     200 2000 https://noticias.test/ 'Mozilla/5.0'
  # Entrecomillada, y no por gusto: 'orbit' activa nullglob, así que un '?' sin
  # comillas que no case con ningún fichero desaparece del todo y el argumento
  # siguiente se corre un sitio. Es la trampa de docs/DEVELOPMENT.md, aquí mismo.
  linea 20 2.2.2.2 web.test '/precios?x=1' 200 2000 http://web.test/  'Mozilla/5.0'
  linea 10 1.1.1.1 web.test /            200 1000 -                     'Mozilla/5.0'
  linea 10 1.1.1.1 web.test /            200 1000 -                     'Mozilla/5.0'
} > "$ACC"

BLK="$(_traffic_scan web "$(_since_stamp 24h)" "$(date -d '24 hours ago' +%s)")"
campo() { _traffic_field "$BLK" "$@"; }

section "Lo que dice una pasada"
check "cuenta las peticiones" "8" "$(campo T)"
check "y las IPs distintas"   "5" "$(campo U)"
check "suma los bytes"        "6700" "$(campo B)"
# El reparto por clase es lo que se pinta como «errores», y confundir un 404
# con un 500 es confundir «alguien pidió lo que no hay» con «tu web se rompió».
check "2xx"                   "4" "$(awk '$1=="C" && $2=="2" {print $3}' <<<"$BLK")"
check "4xx"                   "3" "$(awk '$1=="C" && $2=="4" {print $3}' <<<"$BLK")"
check "5xx"                   "1" "$(awk '$1=="C" && $2=="5" {print $3}' <<<"$BLK")"
check "y el código exacto"    "1" "$(awk '$1=="S" && $2=="500" {print $3}' <<<"$BLK")"

section "Lo automático se cuenta aparte, no se mezcla"
# Dos peticiones de las ocho son un escáner y un curl. Sumarlas a las visitas
# convierte cualquier medición en ruido: la mitad del tráfico de un VPS con IP
# pública es gente buscando /.git/config.
check "las cuenta"            "2" "$(campo BOT)"
check "y no entran en rutas"  ""  "$(awk '$1=="P" && $3=="/.git/config" {print $2}' <<<"$BLK")"

section "La ruta pierde la consulta, que si no cada visita es una ruta nueva"
check "/precios suma las dos" "2" "$(awk '$1=="P" && $3=="/precios" {print $2}' <<<"$BLK")"
check "y la portada"          "2" "$(awk '$1=="P" && $3=="/" {print $2}' <<<"$BLK")"

section "Referencias: las de fuera"
check "cuenta la externa"     "1" "$(awk '$1=="R" && $3=="https://noticias.test/" {print $2}' <<<"$BLK")"
# El enlace desde la propia web no dice de dónde viene nadie.
check "y no la propia"        ""  "$(awk '$1=="R" && $3 ~ /web.test/ {print $2}' <<<"$BLK")"

section "Tiempos: cubos, y sólo de las líneas que los traen"
check "todas traen rt"        "8" "$(campo RT)"
check "el máximo, en ms"      "1500" "$(campo RT 3)"
check "la mitad, por debajo de" "≤ 25 ms" "$(_traffic_pctl "$BLK" 8 50)"
check "y el 95%"              "≤ 2,5 s"   "$(_traffic_pctl "$BLK" 8 95)"
check "en número, para el contrato" "25" "$(_traffic_pctl_num "$BLK" 8 50)"
# Un log del formato anterior no trae 'rt='. No se inventa: se cuenta cuántas
# líneas sí lo traían, y quien pinta decide si eso le vale.
sed -i 's/ rt=[0-9.]*$//' "$ACC"
BLK2="$(_traffic_scan web "$(_since_stamp 24h)" "$(date -d '24 hours ago' +%s)")"
check "sin rt, sigue contando" "8" "$(_traffic_field "$BLK2" T)"
check "pero no finge tiempos"  "0" "$(_traffic_field "$BLK2" RT)"
check "y el percentil se calla" "·" "$(_traffic_pctl "$BLK2" 0 50)"
check "también en el contrato"  "null" "$(_traffic_pctl_num "$BLK2" 0 50)"

section "La ventana"
# Una línea de hace tres horas no está en la última hora, y una de hace tres
# días no está en las últimas 24 h. Es el filtro del que cuelga todo lo demás.
{ linea 180 9.9.9.9 web.test /vieja 200 100 - 'Mozilla/5.0'; cat "$ACC"; } > "$ACC.tmp"
mv "$ACC.tmp" "$ACC"
BLK3="$(_traffic_scan web "$(_since_stamp 25m)" "$(date -d '25 minutes ago' +%s)")"
check "25m deja fuera lo viejo" "4" "$(_traffic_field "$BLK3" T)"
BLK4="$(_traffic_scan web "$(_since_stamp 24h)" "$(date -d '24 hours ago' +%s)")"
check "24h lo incluye"         "9" "$(_traffic_field "$BLK4" T)"

section "Los rotados: se leen los que pueden aportar, y no los demás"
# logrotate deja '.log.1' sin comprimir (delaycompress) y '.log.N.gz' detrás.
{ linea 600 8.8.8.8 web.test /ayer 200 100 - 'Mozilla/5.0'; } > "$LOGDIR/web.access.log.1"
{ linea 700 7.7.7.7 web.test /ayer2 200 100 - 'Mozilla/5.0'; } | gzip > "$LOGDIR/web.access.log.2.gz"
BLK5="$(_traffic_scan web "$(_since_stamp 24h)" "$(date -d '24 hours ago' +%s)")"
check "entra el rotado plano"  "1" "$(awk '$1=="P" && $3=="/ayer" {print $2}' <<<"$BLK5")"
check "y el comprimido"        "1" "$(awk '$1=="P" && $3=="/ayer2" {print $2}' <<<"$BLK5")"
# Y el que se rotó antes del corte no se abre siquiera: su mtime es posterior a
# su última línea, así que uno más viejo que la ventana no puede aportar nada.
# Sin esto, 'traffic --since 1h' abre catorce ficheros para no contar nada.
touch -d '10 days ago' "$LOGDIR/web.access.log.2.gz"
check "el viejo ni se abre" "0" \
  "$(_traffic_files web "$(date -d '24 hours ago' +%s)" | grep -c 'log.2.gz')"
check "pero el de hoy sí"   "1" \
  "$(_traffic_files web "$(date -d '24 hours ago' +%s)" | grep -c 'log.1$')"
rm -f "$LOGDIR/web.access.log.1" "$LOGDIR/web.access.log.2.gz"

section "Hasta dónde llega el log, dicho antes que los números"
# Lo peor que puede hacer este comando es contestar a 'los últimos 30 días' con
# lo que había en dos y no decirlo: el número parece una respuesta.
H="$(_traffic_horizon web)"
check "sabe dónde empieza"  "1" "$([[ ${#H} == 14 ]] && echo 1 || echo 0)"
# La primera línea del fichero, que en un log de verdad es la más vieja.
check "y es la hora de la primera línea" "1" \
  "$([[ "$H" == "$(date -d '-180 minutes' '+%Y%m%d%H')"* ]] && echo 1 || echo 0)"
run cmd_traffic web --since 30d >"$TMP/t30" 2>&1
check "avisa de que está recortado" "1" "$(grep -c 'Sólo hay log desde' "$TMP/t30")"
run cmd_traffic web --since 5m >"$TMP/t5m" 2>&1
check "y con una ventana que cubre, no" "0" "$(grep -c 'Sólo hay log desde' "$TMP/t5m")"

section "El informe de una app"
run cmd_traffic web --since 24h >"$TMP/rep" 2>&1; r=$?
check "sale bien"            "0" "$r"
check "cuenta las visitas"   "1" "$(grep -c 'Peticiones' "$TMP/rep")"
check "dice cuántas son máquinas" "1" "$(grep -c 'automáticas' "$TMP/rep")"
check "y enseña las rutas"   "1" "$(grep -cE ' /precios$' "$TMP/rep")"
check "con su gráfica"       "1" "$(grep -c 'Por hora' "$TMP/rep")"

# Una hora sin tráfico es un cero, no una hora que no existe: si se saltara, la
# gráfica encogería los huecos y dos picos separados por un día parecerían
# seguidos. La serie va de la primera hora con tráfico a la última.
section "La serie temporal no se salta los huecos"
: > "$ACC"
{
  linea 200 1.1.1.1 web.test / 200 100 - 'Mozilla/5.0'
  linea 5   1.1.1.1 web.test / 200 100 - 'Mozilla/5.0'
} > "$ACC"
run cmd_traffic web --since 24h >"$TMP/hue" 2>&1
check "cuatro horas, no dos" "1" "$(grep -cE '[3-6] h · máx' "$TMP/hue")"
# Y con más de dos días se agrupa por día, porque 168 barras no caben en una
# terminal — y se dice en la etiqueta, que una barra que unas veces es una hora
# y otras un día sin avisar es peor que no dibujarla.
{ linea 5000 1.1.1.1 web.test / 200 100 - 'Mozilla/5.0'; } >> "$ACC"
run cmd_traffic web --since 7d >"$TMP/dia" 2>&1
check "más de dos días, por día" "1" "$(grep -c 'Por día' "$TMP/dia")"

section "Cuando no hay nada que contar"
: > "$ACC"
run cmd_traffic web --since 24h >"$TMP/vac" 2>&1; r=$?
check "no es un error"       "0" "$r"
check "y lo dice"            "1" "$(grep -c 'Ninguna petición' "$TMP/vac")"

section "Una ventana que no se entiende no devuelve cero"
# Un cero parece un dato. Es la regla de las colecciones vacías: «no hay» y «no
# he podido» no se pueden decir igual.
run cmd_traffic web --since mañana-quizá >/dev/null 2>&1; r=$?
check "aborta"               "1" "$r"
run cmd_traffic web --top 0 >/dev/null 2>&1; r=$?
check "y --top quiere un número" "1" "$r"

section "El contrato: traffic --json"
# La primera queda fuera de la ventana a propósito: marca el horizonte, y es
# lo que permite comprobar que 'complete' distingue «esto es todo» de «esto es
# lo que quedaba en disco».
{
  linea 60 0.0.0.0 web.test /viejo 200   10 -                      'Mozilla/5.0'
  linea 10 1.1.1.1 web.test /      200 1000 -                      'Mozilla/5.0'
  linea 10 1.1.1.1 web.test /      200 1000 -                      'Mozilla/5.0'
  linea 10 2.2.2.2 web.test /uno   404  100 https://noticias.test/ 'Mozilla/5.0' 0.900
  linea 10 3.3.3.3 web.test /bot   200  100 -                      'Googlebot/2.1'
} > "$ACC"
if command -v jq >/dev/null; then
  JSON="yes"
  run cmd_traffic web --since 30m >"$TMP/j" 2>/dev/null
  check "es JSON válido"    "0" "$(jq -e . "$TMP/j" >/dev/null 2>&1; echo $?)"
  check "un solo objeto"    "1" "$(jq -s 'length' "$TMP/j")"
  check "con la app dentro" "web" "$(jq -r '.apps[0].app' "$TMP/j")"
  check "las peticiones"    "4" "$(jq -r '.apps[0].requests' "$TMP/j")"
  check "las automáticas"   "1" "$(jq -r '.apps[0].automated' "$TMP/j")"
  check "los códigos"       "1" "$(jq -r '.apps[0].status["4xx"]' "$TMP/j")"
  check "el percentil"      "1000" "$(jq -r '.apps[0].latency_ms.p95' "$TMP/j")"
  check "las rutas"         "/" "$(jq -r '.apps[0].paths[0].path' "$TMP/j")"
  check "las referencias"   "https://noticias.test/" "$(jq -r '.apps[0].referrers[0].referrer' "$TMP/j")"
  check "y las horas"       "1" "$(( $(jq -r '.apps[0].hours | length' "$TMP/j") >= 1 ? 1 : 0 ))"
  # 'complete' es lo que separa «esto es todo» de «esto es lo que queda en
  # disco», y sin él un cliente pinta una gráfica recortada como si fuera la
  # buena.
  check "dice si cubre la ventana" "true" "$(jq -r '.apps[0].complete' "$TMP/j")"
  run cmd_traffic web --since 30d >"$TMP/j2" 2>/dev/null
  check "y cuándo no"              "false" "$(jq -r '.apps[0].complete' "$TMP/j2")"
  JSON="no"
else
  echo "  falta jq: me salto el contrato --json."
fi

section "Una redirección no tiene tráfico propio que contar"
A_NAME="viejo.test"; A_TYPE="redirect"; A_DOMAIN="viejo.test"
A_REDIRECT="https://nuevo.test"; A_REDIRECT_CODE="301"; A_PORT=""
A_REPO=""; A_BRANCH=""; A_ALIASES=""; A_PKG=""; A_BUILD=""; A_START=""
A_OUTDIR=""; A_SPA="no"; A_DOCROOT=""; A_PYAPP=""; A_APPDIR="."
A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
save_app
if command -v jq >/dev/null; then
  JSON="yes"
  run cmd_traffic >"$TMP/j3" 2>/dev/null
  check "queda fuera del contrato" "0" "$(jq -r '[.apps[].app] | map(select(. == "viejo.test")) | length' "$TMP/j3")"
  JSON="no"
fi
rm -f "$(app_conf viejo.test)"

section "El techo de claves distintas se dice, no se calla"
# Un escaneo de rutas al azar es lo primero que recibe cualquier IP pública. El
# array de awk no puede crecer sin límite, pero recortar en silencio deja un
# «rutas más pedidas» que no suma el total y nadie sabe por qué.
: > "$ACC"
for i in $(seq 1 40); do
  linea 10 1.1.1.1 web.test "/r$i" 200 10 - 'Mozilla/5.0'
done > "$ACC"
TRAFFIC_MAX_KEYS=10
BLK6="$(_traffic_scan web "$(_since_stamp 24h)" "$(date -d '24 hours ago' +%s)")"
check "cuenta todas las peticiones" "40" "$(_traffic_field "$BLK6" T)"
check "y las que no cupieron"       "30" "$(_traffic_field "$BLK6" OTRAS)"
run cmd_traffic web --since 24h >"$TMP/cap" 2>&1
check "lo dice en el informe"       "1" "$(grep -c 'peticiones más a rutas distintas' "$TMP/cap")"
TRAFFIC_MAX_KEYS=20000

report
