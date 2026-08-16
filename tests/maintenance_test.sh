#!/usr/bin/env bash
# Página de mantenimiento: el 503, la validación de certbot y el automático.
#   bash tests/maintenance_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables que lee el
# 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root()  { :; }
systemctl()  { :; }
LOG_FILE="$TMP/orbit.log"
nginx_file() { echo "$TMP/vhost-$1.conf"; }
render_nginx() { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }

REL="$TMP/apps/web/releases/r1"
mkdir -p "$REL" "$TMP/apps/web/shared"
printf 'la web de verdad\n' > "$REL/index.html"
ln -sfn "$REL" "$TMP/apps/web/current"
mkapp web static "" "web.test"
A_OUTDIR="."; A_SPA="no"; save_app

section "Encender y apagar"
run cmd_maintenance on web >"$TMP/on" 2>&1; r=$?
check "enciende"            "0" "$r"
check "crea el testigo"     "1" "$([[ -e "$(maint_flag web)" ]] && echo 1 || echo 0)"
check "y la página"         "1" "$([[ -f "$(maint_page web)" ]] && echo 1 || echo 0)"
check "dice dónde editarla" "1" "$(grep -c 'maintenance.html' "$TMP/on")"
run cmd_maintenance status >"$TMP/st" 2>&1
check "sale en el estado"   "1" "$(grep -c 'web ' "$TMP/st")"
run cmd_maintenance off web >/dev/null 2>&1
check "apaga"               "0" "$([[ -e "$(maint_flag web)" ]] && echo 1 || echo 0)"
# Apagar algo que no estaba encendido no es un error.
run cmd_maintenance off web >"$TMP/off2" 2>&1; r=$?
check "apagar dos veces"    "0" "$r"
check "y lo dice"           "1" "$(grep -c 'no estaba en mantenimiento' "$TMP/off2")"

section "La página es tuya"
printf 'MI PAGINA PERSONALIZADA\n' > "$(maint_page web)"
run cmd_maintenance on web >/dev/null 2>&1
check "no la sobrescribe" "MI PAGINA PERSONALIZADA" "$(cat "$(maint_page web)")"
run cmd_maintenance off web >/dev/null 2>&1

section "Una redirección no se pone en mantenimiento"
A_NAME="viejo.test"; A_TYPE="redirect"; A_DOMAIN="viejo.test"
A_REDIRECT="https://nuevo.test"; A_REDIRECT_CODE="301"; A_REPO=""; A_BRANCH=""
A_ALIASES=""; A_PKG=""; A_BUILD=""; A_START=""; A_OUTDIR=""; A_SPA="no"
A_PORT=""; A_DOCROOT=""; A_PYAPP=""; A_PYMGR=""; A_PYFW=""; A_MIGRATE=""
A_STATIC_URL=""; A_STATIC_ROOT=""; A_MEDIA_URL=""; A_MEDIA_ROOT=""
A_AUTODEPLOY=""; A_AUTOFAIL=""; A_MAINT_AUTO=""
A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
save_app
run cmd_maintenance on viejo.test >/dev/null 2>&1; r=$?
check "lo rechaza" "1" "$r"
check "y su vhost no lleva el bloque" "0" \
  "$(nginx_vhost viejo.test | grep -c '__orbit_maintenance')"

section "El vhost generado"
load_app web
VH="$(nginx_vhost web)"
check "guarda dentro de location /" "1" \
  "$(grep -A2 '^    location / {' <<<"$VH" | grep -c 'maintenance.on')"
# Si estuviera a nivel de servidor, el 503 se comería la validación de certbot.
check "no a nivel de servidor" "0" \
  "$(grep -B1 'maintenance.on' <<<"$VH" | grep -c 'server_name')"
check "bloque de la página"    "1" "$(grep -c 'location = /__orbit_maintenance' <<<"$VH")"
check "y el del motivo"        "1" "$(grep -c 'location = /maintenance.reason' <<<"$VH")"
check "con SSI activada"       "1" "$(grep -c '^ *ssi on;' <<<"$VH")"
# La directiva, no el comentario que la explica.
check "con Retry-After"        "1" "$(grep -c '^ *add_header Retry-After' <<<"$VH")"
check "sin duplicar el bloque" "1" "$(grep -c 'location = /__orbit_maintenance' <<<"$VH")"
# El rewrite tiene que estar en un location de coincidencia exacta: dentro de
# uno con nombre, la subpetición de la SSI vuelve a caer en él y la página se
# incluye a sí misma en bucle.
check "rewrite acotado"        "0" "$(grep -c 'location @mantenimiento' <<<"$VH")"

section "El motivo"
run cmd_maintenance on web "Migrando la base de datos" >"$TMP/m1" 2>&1
check "lo guarda"    "Migrando la base de datos" "$(cat "$(maint_reason web)")"
check "y lo confirma" "1" "$(grep -c 'Motivo: Migrando la base de datos' "$TMP/m1")"
check "sale en el estado" "1" "$(run cmd_maintenance status | grep -c 'Migrando la base de datos')"
# Sin salto de línea final: si no, el párrafo nunca estaría :empty.
check "sin salto final" "0" "$(tail -c1 "$(maint_reason web)" | wc -l)"

# Un '<' en el texto rompería la maqueta de la página.
run cmd_maintenance on web 'Cambio de <servidor> & "cosas"' >/dev/null 2>&1
check "escapa el HTML" 'Cambio de &lt;servidor&gt; &amp; &quot;cosas&quot;' \
  "$(cat "$(maint_reason web)")"

# Al quitarlo se limpia, para que no reaparezca en el siguiente aviso.
run cmd_maintenance off web >/dev/null 2>&1
check "se limpia al quitarlo" "" "$(cat "$(maint_reason web)")"
# Y el fichero tiene que seguir existiendo: si falta, la SSI incrusta un 404.
check "pero el fichero queda" "1" "$([[ -f "$(maint_reason web)" ]] && echo 1 || echo 0)"

# Sin motivo, encender no deja nada escrito.
run cmd_maintenance on web >/dev/null 2>&1
check "sin motivo, vacío" "" "$(cat "$(maint_reason web)")"
run cmd_maintenance off web >/dev/null 2>&1

section "Una página antigua avisa"
# Las páginas escritas antes de esta versión no traen el hueco del motivo.
printf 'MI PAGINA SIN HUECO\n' > "$(maint_page web)"
run cmd_maintenance on web "un motivo" >"$TMP/m2" 2>&1
check "avisa de que no se verá" "1" "$(grep -c 'no tiene el hueco del motivo' "$TMP/m2")"
check "y dice qué añadir"       "1" "$(grep -c 'maintenance.reason' "$TMP/m2")"
run cmd_maintenance off web >/dev/null 2>&1
rm -f "$(maint_page web)"
run cmd_maintenance on web >/dev/null 2>&1
check "la página nueva sí lo trae" "1" "$(grep -c 'maintenance.reason' "$(maint_page web)")"
run cmd_maintenance off web >/dev/null 2>&1

section "Automático durante el despliegue"
mkapp proc node 3001 proc.test
# En este mismo shell y no dentro de "$( )": MAINT_BY_DEPLOY es quien recuerda
# que el testigo lo pusimos nosotros, y en un subshell se pierde al salir. La
# version anterior de esta prueba lo hacia asi y pasaba por accidente — la
# trampa que habia dentro de _maint_deploy_on se disparaba al cerrarse el
# subshell y limpiaba el testigo, de modo que la comprobacion de al lado daba
# por bueno un camino que nunca se ejecutaba.
MAINT_BY_DEPLOY=""
_maint_deploy_on proc
check "se activa" "1" "$([[ -e "$(maint_flag proc)" ]] && echo 1 || echo 0)"
_maint_deploy_off
check "y se quita" "0" "$([[ -e "$(maint_flag proc)" ]] && echo 1 || echo 0)"

# Un motivo de una vez anterior no puede reaparecer en un despliegue.
_maint_on proc "motivo viejo"
rm -f "$(maint_flag proc)"
MAINT_BY_DEPLOY=""
_maint_deploy_on proc
check "no arrastra el motivo" "" "$(cat "$(maint_reason proc)")"
_maint_deploy_off

# Si ya estaba puesto a mano, el despliegue no debe quitarlo al terminar.
_maint_on proc
MAINT_BY_DEPLOY=""
_maint_deploy_on proc
_maint_deploy_off
check "respeta el manual" "1" "$([[ -e "$(maint_flag proc)" ]] && echo 1 || echo 0)"
rm -f "$(maint_flag proc)"

# Y se puede desactivar por app.
load_app proc; A_MAINT_AUTO="no"; save_app; load_app proc
MAINT_BY_DEPLOY=""
_maint_deploy_on proc
check "se puede desactivar" "0" "$([[ -e "$(maint_flag proc)" ]] && echo 1 || echo 0)"
load_app proc; A_MAINT_AUTO=""; save_app; load_app proc

section "Un despliegue que muere no lo deja encendido"
# Una web no puede quedarse en «volvemos enseguida» para siempre porque el
# despliegue abortara a mitad. La trampa la pone 'cmd_deploy' —que es lo unico
# que llama aqui— junto con lo demas que hay que hacer al salir, asi que se
# reproduce esa disposicion y no la de antes: ponerla dentro de
# _maint_deploy_on sustituia la de cmd_deploy, y entonces el fallo del health
# check salia sin objeto JSON. Lo que se prueba es la garantia, no quien la da.
MAINT_BY_DEPLOY=""
( trap '_deploy_on_exit' EXIT; _maint_deploy_on proc; exit 1 ) >/dev/null 2>&1
check "el trap lo limpia" "0" "$([[ -e "$(maint_flag proc)" ]] && echo 1 || echo 0)"

section "Las cuatro fuentes dicen lo mismo del mantenimiento"
# La tabla de 'orbit list' no miraba el testigo, y era la unica que no: el
# '--json' de ESE MISMO comando ya traia "maintenance": true, y 'orbit top' ya
# pintaba 'manten.'. O sea que la salida humana y la salida maquina del mismo
# comando se contradecian, y la que se contradecia era la que mira una persona:
# con una app en mantenimiento, la tabla decia «activo» sobre una web que
# contestaba 503 a todo el mundo.
#
# Salio midiendo en un servidor el residuo que deja un despliegue muerto con
# SIGKILL (ARCHITECTURE §5.5), que es la forma en que esto aparece sin que
# nadie lo haya puesto a mano.
mkapp lista node 3021 lista.test
systemctl() { return 0; }          # la unidad, viva: sin el testigo diria «activo»
has_cert()  { return 1; }
install -d "$(app_shared lista)"
# Con su vhost puesto: sin el, 'sin vhost' gana sobre todo lo demas y esta
# seccion mediria otra cosa. Es la precedencia correcta —sin vhost nginx no
# sirve ni la pagina de 503— y por eso hay que darle el vhost para poder
# preguntar por el mantenimiento.
: > "$(nginx_file lista)"; ln -sfn "$(nginx_file lista)" "$(nginx_link lista)"

rm -f "$(maint_flag lista)"
SALIDA="$(cmd_list 2>&1)"
check "sin testigo, activo"  "1" "$(grep -c 'lista' <<<"$SALIDA" | head -1)"
check "y no dice manten."    "0" "$(grep -c 'manten\.' <<<"$SALIDA")"

: > "$(maint_flag lista)"
SALIDA="$(cmd_list 2>&1)"
check "con testigo, lo dice" "1" "$(grep -c 'manten\.' <<<"$SALIDA")"
# Y gana sobre el estado de la unidad, que es lo que hace que sea correcto: el
# visitante recibe 503 este la unidad como este.
check "aunque la unidad viva" "0" "$(grep -E 'lista' <<<"$SALIDA" | grep -c 'activo')"

# Y la precedencia, que es lo que separa las dos malas noticias: sin vhost no
# hay 503 que servir, asi que ese estado gana incluso sobre el mantenimiento.
rm -f "$(nginx_link lista)"
SALIDA="$(cmd_list 2>&1)"
check "sin vhost gana al manten." "1" "$(grep -E 'lista' <<<"$SALIDA" | grep -c 'sin vhost')"

rm -f "$(maint_flag lista)" "$(app_conf lista)" "$(nginx_file lista)"; rm -rf "$(app_dir lista)"
unset -f systemctl has_cert

section "El vigilante avisa si se queda puesto"
WATCH_STATE="$TMP/watch.state"; WATCH_LOG="$TMP/watch.log"
NOTIFY_CONF="$TMP/sin-avisos"
_maint_on proc
WATCH_MAINT_MAX=0
_watch_state_load; _watch_maint >/dev/null; _watch_state_save
check "detecta el olvido" "alerta" "$(_watch_state_load; printf '%s' "${WS_STATE[mant:proc]:-}")"
rm -f "$(maint_flag proc)"
_watch_state_load; _watch_maint >/dev/null; _watch_state_save
check "y la salida"       "ok"     "$(_watch_state_load; printf '%s' "${WS_STATE[mant:proc]:-}")"

# ═══════════════════════════════════════════════════════════════════════════
# Con nginx de verdad: que devuelva 503 es lo único que demuestra que sirve.
# ═══════════════════════════════════════════════════════════════════════════
command -v nginx >/dev/null || {
  echo
  echo "nginx no está instalado: me salto la comprobación en vivo."
  report
}

NG="$TMP/ng"; PORT=18700
mkdir -p "$NG"/{snippets,vhosts,logs,tmp,acme/.well-known/acme-challenge}
printf 'token-de-certbot\n' > "$NG/acme/.well-known/acme-challenge/prueba"
cat > "$NG/snippets/orbit-acme.conf" <<EOF
location ^~ /.well-known/acme-challenge/ { root $NG/acme; default_type "text/plain"; allow all; }
EOF
: > "$NG/snippets/orbit-security.conf"
: > "$NG/snippets/orbit-ssl.conf"
cat > "$NG/nginx.conf" <<EOF
worker_processes 1;
error_log $NG/logs/error.log warn;
pid $NG/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $NG/tmp; proxy_temp_path $NG/tmp; fastcgi_temp_path $NG/tmp;
    uwsgi_temp_path $NG/tmp; scgi_temp_path $NG/tmp;
    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
    limit_req_zone \$binary_remote_addr zone=orbit_general:1m rate=40r/s;
    limit_conn_zone \$binary_remote_addr zone=orbit_conn:1m;
    log_format orbit '\$remote_addr \$host "\$request" \$status';
    include $NG/vhosts/*.conf;
}
EOF
nginx_vhost web \
  | sed -e "s#/etc/nginx/snippets/#$NG/snippets/#g" \
        -e "s#/var/log/nginx/#$NG/logs/#g" \
        -e "s/^\( *\)listen 80;/\1listen 127.0.0.1:$PORT;/" \
        -e "/listen \[::\]/d" \
  > "$NG/vhosts/web.conf"

section "Validación de la configuración"
nginx -t -c "$NG/nginx.conf" -p "$NG" >"$NG/logs/t.out" 2>&1 && r=ok || r=error
[[ "$r" == ok ]] || sed 's/^/      /' "$NG/logs/t.out"
check "nginx -t" "ok" "$r"

chmod 711 "$TMP"; chmod -R a+rX "$NG" "$TMP/apps"
nginx -c "$NG/nginx.conf" -p "$NG" 2>>"$NG/logs/error.log"
trap 'nginx -c "$NG/nginx.conf" -p "$NG" -s quit 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/" && break
  sleep 0.3
done

CODE() { curl -so /dev/null -w '%{http_code}' -m 5 -H 'Host: web.test' "http://127.0.0.1:$PORT$1"; }
BODY() { curl -s -m 5 -H 'Host: web.test' "http://127.0.0.1:$PORT$1"; }
HDR()  { curl -sI -m 5 -H 'Host: web.test' "http://127.0.0.1:$PORT$1"; }

section "Sirviendo con normalidad"
check "la web responde" "la web de verdad" "$(BODY /)"
check "acme accesible"  "token-de-certbot" "$(BODY /.well-known/acme-challenge/prueba)"

section "En mantenimiento"
# Un 'touch': nginx lo ve en la siguiente petición, sin recargar nada.
run cmd_maintenance on web >/dev/null 2>&1
chmod -R a+rX "$TMP/apps"
check "responde 503"      "503" "$(CODE /)"
check "sirve la página"   "1"   "$(BODY / | grep -c 'Volvemos enseguida</h1>')"
check "con Retry-After"   "1"   "$(HDR / | grep -ci '^retry-after')"
check "y sin cachear"     "1"   "$(HDR / | grep -ci 'no-store')"
check "también en rutas"  "503" "$(CODE /una/ruta)"

# Lo que de verdad importaba comprobar: certbot tiene que poder renovar
# aunque la web esté en mantenimiento. Con la guarda a nivel de servidor
# esto devolvería 503 y la renovación fallaría en silencio.
check "certbot sigue pudiendo validar" "token-de-certbot" \
  "$(BODY /.well-known/acme-challenge/prueba)"

section "El motivo en vivo"
run cmd_maintenance on web "Migrando la base de datos, volvemos a las 18:00" >/dev/null 2>&1
chmod -R a+rX "$TMP/apps"
check "sale en la página" "1" \
  "$(BODY / | grep -c 'Migrando la base de datos, volvemos a las 18:00')"
check "y sigue siendo 503" "503" "$(CODE /)"
# El párrafo vacío no debe enseñar nada raro.
run cmd_maintenance on web >/dev/null 2>&1
chmod -R a+rX "$TMP/apps"
check "sin motivo, párrafo vacío" "1" "$(BODY / | grep -c '<p class="motivo"></p>')"
# La trampa que encontró la prueba con nginx: sin el fichero, la SSI incrusta
# una página de error entera dentro del párrafo.
# Con la recursión, el encabezado salía cincuenta veces antes de reventar.
check "no se incluye a sí misma" "1" "$(BODY / | grep -c '<h1>')"
check "sin errores de SSI"       "0" "$(BODY / | grep -c 'error occurred while processing')"
# El motivo no es accesible desde fuera.
run cmd_maintenance on web "SECRETO-QUE-NO-DEBE-SALIR-SUELTO" >/dev/null 2>&1
chmod -R a+rX "$TMP/apps"
check "el motivo no se sirve suelto" "0" \
  "$(BODY /maintenance.reason | grep -cx 'SECRETO-QUE-NO-DEBE-SALIR-SUELTO')"
run cmd_maintenance on web >/dev/null 2>&1
chmod -R a+rX "$TMP/apps"

section "Al quitarlo"
run cmd_maintenance off web >/dev/null 2>&1
check "vuelve la web" "la web de verdad" "$(BODY /)"
check "código 200"    "200"              "$(CODE /)"

report
