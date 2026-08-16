#!/usr/bin/env bash
# orbit logs: ventana temporal, en journald y en los logs de nginx.
#   bash tests/logs_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables que lee el
# 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
mkdir -p "$TMP/nglogs"
nginx_log_access() { echo "$TMP/nglogs/$1.access.log"; }
nginx_log_error()  { echo "$TMP/nglogs/$1.error.log"; }
# El comando real bloquearía siguiendo el journal: aquí solo interesa con qué
# argumentos se le llama.
journalctl() { printf 'journalctl %s\n' "$*"; }

mkapp web  node   3001 web.test
mkapp esta static ""   esta.test

section "Formas de decir «desde cuándo»"
check "30m"        "30 minutes ago" "$(_since_expr 30m)"
check "2h"         "2 hours ago"    "$(_since_expr 2h)"
check "3d"         "3 days ago"     "$(_since_expr 3d)"
check "45s"        "45 seconds ago" "$(_since_expr 45s)"
check "en español" "2 horas ago"    "$(_since_expr 2horas | sed 's/hours/horas/')"
check "hoy"        "today"          "$(_since_expr hoy)"
check "ayer"       "yesterday"      "$(_since_expr ayer)"
check "una hora"   "10:00"          "$(_since_expr 10:00)"
check "una fecha"  "2026-08-01"     "$(_since_expr 2026-08-01)"

HOY="$(_since_stamp hoy)"
check "hoy es comparable" "14" "${#HOY}"
check "basura no vale"    ""   "$(_since_stamp 'el martes pasado')"
check "y aborta"          "1"  "$(run cmd_logs web --since 'el martes pasado' >/dev/null 2>&1; echo $?)"

section "El filtro por fecha de los logs de nginx"
ACC="$TMP/nglogs/esta.access.log"
ERR="$TMP/nglogs/esta.error.log"
cat > "$ACC" <<'EOF'
[05/Jan/2026:23:00:00 +0000] 3.3.3.3 - esta.test "GET /enero HTTP/1.1" 200
[05/Aug/2026:10:00:00 +0000] 1.1.1.1 - esta.test "GET /manana HTTP/1.1" 200
[05/Aug/2026:17:59:52 +0000] 2.2.2.2 - esta.test "GET /tarde HTTP/1.1" 200
[05/Dec/2026:01:00:00 +0000] 4.4.4.4 - esta.test "GET /diciembre HTTP/1.1" 200
EOF
cat > "$ERR" <<'EOF'
2026/08/05 09:00:00 [error] 1#1: algo temprano
2026/08/05 18:30:00 [error] 1#1: algo tarde
EOF
CUT=20260805120000
check "deja pasar lo nuevo"   "1" "$(_log_since "$CUT" "$ACC" | grep -c '/tarde')"
check "descarta lo viejo"     "0" "$(_log_since "$CUT" "$ACC" | grep -c '/manana')"
# El mes va como texto: sin traducirlo, enero parecería posterior a agosto.
check "enero no es agosto"    "0" "$(_log_since "$CUT" "$ACC" | grep -c '/enero')"
check "y diciembre sí pasa"   "1" "$(_log_since "$CUT" "$ACC" | grep -c '/diciembre')"
check "también el log de errores" "1" "$(_log_since "$CUT" "$ERR" | grep -c 'algo tarde')"
check "y descarta el viejo"   "0" "$(_log_since "$CUT" "$ERR" | grep -c 'algo temprano')"
SUCIO="$TMP/nglogs/sucia.access.log"
cp "$ACC" "$SUCIO"; printf 'una linea sin fecha\n' >> "$SUCIO"
check "una línea sin fecha se ignora" "0" "$(_log_since "$CUT" "$SUCIO" | grep -c 'sin fecha')"

section "Formato viejo, sin marca de tiempo"
OLD="$TMP/nglogs/vieja.access.log"
printf '1.1.1.1 - vieja.test "GET / HTTP/1.1" 200\n' > "$OLD"
check "se detecta"            "1" "$(_log_has_time "$OLD" && echo 0 || echo 1)"
check "el nuevo pasa"         "0" "$(_log_has_time "$ACC" && echo 0 || echo 1)"
check "un log vacío no molesta" "0" "$(: > "$TMP/nglogs/v.log"; _log_has_time "$TMP/nglogs/v.log" && echo 0 || echo 1)"
# Un fichero de log no se vacía al cambiar el formato: durante días conserva
# arriba las líneas viejas y abajo las nuevas. Mirar la primera decía que el
# formato seguía siendo el antiguo cuando ya no lo era.
MIX="$TMP/nglogs/mixta.access.log"
cat > "$MIX" <<'EOF'
1.1.1.1 - mixta.test "GET /antes HTTP/1.1" 200
[05/Aug/2026:18:45:40 +0000] 1.1.1.1 - mixta.test "GET /despues HTTP/1.1" 200
EOF
check "log a medio migrar"    "0" "$(_log_has_time "$MIX" && echo 0 || echo 1)"

section "orbit logs con una app estática"
run cmd_logs esta --since 2h >"$TMP/l1" 2>&1
check "no sigue en vivo"      "0" "$(grep -c 'Ctrl-C' "$TMP/l1")"
run cmd_logs esta --since 20m >"$TMP/l2" 2>&1
check "filtra de verdad"      "0" "$(grep -c '/enero' "$TMP/l2")"
# tail aplica -n a cada fichero: 2 del log de acceso y 2 del de errores.
run cmd_logs esta --no-follow --lines 2 >"$TMP/l3" 2>&1
check "--lines recorta"       "4" "$(grep -cvE '^(==>|$)' "$TMP/l3")"
run cmd_logs esta --lines dos >/dev/null 2>&1; r=$?
check "--lines quiere número" "1" "$r"
run cmd_logs esta --invento >/dev/null 2>&1; r=$?
check "opción desconocida"    "1" "$r"
run cmd_logs sinlogs --no-follow >/dev/null 2>&1; r=$?
check "app inexistente"       "1" "$r"

section "orbit logs con una app con proceso"
check "usa journalctl"        "1" "$(run cmd_logs web --no-follow 2>/dev/null | grep -c 'u orbit-web')"
check "sigue por defecto"     "1" "$(run cmd_logs web 2>/dev/null | grep -c ' -f')"
check "con --since no sigue"  "0" "$(run cmd_logs web --since 1h 2>/dev/null | grep -c ' -f')"
check "y le pasa la fecha"    "1" "$(run cmd_logs web --since 1h 2>/dev/null | grep -c -- '--since 20')"
check "--lines llega"         "1" "$(run cmd_logs web --no-follow --lines 500 2>/dev/null | grep -c -- '-n 500')"
check "-f fuerza seguir"      "1" "$(run cmd_logs web --since 1h -f 2>/dev/null | grep -c ' -f')"
# Un 502 no está en el journal de la app: está en el log de nginx.
: > "$TMP/nglogs/web.access.log"
check "--nginx cambia de sitio" "0" "$(run cmd_logs web --nginx --no-follow 2>/dev/null | grep -c journalctl)"
check "y lo explica"            "1" "$(run cmd_logs web --nginx --no-follow 2>&1 | grep -c 'Los de la aplicación')"

section "Sin ficheros de log todavía"
mkapp reciente static "" reciente.test
run cmd_logs reciente --no-follow >"$TMP/l4" 2>&1; r=$?
check "no aborta"             "0" "$r"
check "y lo dice"             "1" "$(grep -c 'todavía no tiene logs' "$TMP/l4")"

# ═════════════════════════════════════════════ el formato, con nginx real ══
command -v nginx >/dev/null || { echo; echo "nginx no está: me salto la comprobación del formato."; report; }

NG="$TMP/ng"; PORT=18092
mkdir -p "$NG"/{snippets,vhosts,logs,tmp}
cert_file() { echo "$NG/certs/$1.crt"; }
: > "$NG/snippets/orbit-acme.conf"
: > "$NG/snippets/orbit-security.conf"

# El mismo formato que escribe install.sh, para comprobar que lo que emite
# nginx es exactamente lo que el filtro sabe leer.
FMT="$(grep -A1 "^log_format orbit" "$ORBIT_ROOT/install.sh" | tr -d '\n')"
MIME=""; [[ -f /etc/nginx/mime.types ]] && MIME="    include /etc/nginx/mime.types;"
cat > "$NG/nginx.conf" <<EOF
worker_processes 1;
error_log $NG/logs/error.log warn;
pid $NG/nginx.pid;
events { worker_connections 128; }
http {
$MIME
    default_type application/octet-stream;
    client_body_temp_path $NG/tmp;
    proxy_temp_path $NG/tmp;
    fastcgi_temp_path $NG/tmp;
    uwsgi_temp_path $NG/tmp;
    scgi_temp_path $NG/tmp;
    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
    limit_req_zone \$binary_remote_addr zone=orbit_general:1m rate=40r/s;
    limit_conn_zone \$binary_remote_addr zone=orbit_conn:1m;
    $FMT
    include $NG/vhosts/*.conf;
}
EOF

REL="$TMP/apps/esta/releases/r1"; mkdir -p "$REL"
printf 'hola\n' > "$REL/index.html"
ln -sfn "$REL" "$TMP/apps/esta/current"
load_app esta; A_OUTDIR="."; A_SPA="no"; save_app
nginx_log_access() { echo "$NG/logs/$1.access.log"; }
nginx_log_error()  { echo "$NG/logs/$1.error.log"; }
nginx_vhost esta \
  | sed -e "s#/etc/nginx/snippets/#$NG/snippets/#g" \
        -e "s/^\( *\)listen 80;/\1listen 127.0.0.1:$PORT;/" \
        -e "/listen \[::\]/d" \
  > "$NG/vhosts/esta.conf"

chmod 755 "$TMP"; chmod -R a+rX "$TMP/apps" 2>/dev/null || true
d="$TMP"; while [[ "$d" != "/" ]]; do chmod a+x "$d" 2>/dev/null || true; d="$(dirname "$d")"; done

nginx -c "$NG/nginx.conf" -t >/dev/null 2>&1 || { nginx -c "$NG/nginx.conf" -t; exit 1; }
nginx -c "$NG/nginx.conf" >/dev/null 2>&1
sleep 0.5
curl -s -o /dev/null -m 4 "http://127.0.0.1:$PORT/"
sleep 0.3

section "Lo que escribe nginx es lo que el filtro lee"
LINE="$(tail -n1 "$NG/logs/esta.access.log" 2>/dev/null || true)"
check "la línea lleva fecha"  "1" "$(printf '%s' "$LINE" | grep -cE '^\[[0-9]{2}/[A-Z][a-z]{2}/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} ')"
check "el filtro la reconoce" "1" "$(_log_since "$(date -d '1 hour ago' '+%Y%m%d%H%M%S')" "$NG/logs/esta.access.log" | grep -c 'GET /')"
check "y la descarta si es vieja" "0" "$(_log_since "$(date -d '1 hour' '+%Y%m%d%H%M%S')" "$NG/logs/esta.access.log" | grep -c 'GET /')"
check "orbit logs --since la ve" "1" "$(run cmd_logs esta --since 1h 2>/dev/null | grep -c 'GET /')"

nginx -c "$NG/nginx.conf" -s stop >/dev/null 2>&1 || true
report
