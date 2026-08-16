#!/usr/bin/env bash
# orbit clone: qué se copia, qué no, y qué pasa si algo falla a mitad.
#   bash tests/clone_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables que lee el
# 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root()    { :; }
systemctl()    { :; }
LOG_FILE="$TMP/orbit.log"
nginx_file()   { echo "$TMP/vhost-$1.conf"; }
render_nginx() { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }
mkdir -p "$TMP/etc/redirects"

# --- el original: una app con de todo ---------------------------------------
mkapp origen node 3001 origen.test "www.origen.test"
A_REPO="https://example.test/origen.git"; A_BRANCH="produccion"
A_START='node server.js --port ${PORT}'
A_MIGRATE="./manage.py migrate"
A_STATIC_URL="/static/"; A_STATIC_ROOT="staticfiles"
A_MEDIA_URL="/media/";   A_MEDIA_ROOT="$TMP/apps/origen/shared/media"
A_AUTODEPLOY="yes"; A_AUTOFAIL="deadbeef"; A_LASTDEPLOY="2026-01-02T03:04:05+00:00"
A_QUEUE="yes"
save_app

mkdir -p "$TMP/apps/origen/shared"
cat > "$TMP/apps/origen/shared/.env" <<'EOF'
# la base de datos de produccion
DATABASE_URL=postgres://u:secreta@127.0.0.1/prod
export STRIPE_KEY=sk_live_no_compartir
VACIA=
EOF
printf '/vieja /nueva 301\n' > "$TMP/etc/redirects/origen.list"
cat > "$TMP/apps/origen/shared/maintenance.html" <<'EOF'
<h1>volvemos enseguida</h1>
<p class="motivo"><!--# include file="maintenance.reason" --></p>
EOF

section "Lo que se hereda"
run cmd_clone origen copia --domain staging.origen.test >"$TMP/c1" 2>&1; r=$?
check "clona"                "0"   "$r"
check "registra la app"      "1"   "$(app_exists copia && echo 1 || echo 0)"
load_app copia
check "nombre nuevo"         "copia"        "$A_NAME"
check "dominio nuevo"        "staging.origen.test" "$A_DOMAIN"
check "hereda el tipo"       "node"         "$A_TYPE"
check "hereda el repo"       "https://example.test/origen.git" "$A_REPO"
check "hereda la rama"       "produccion"   "$A_BRANCH"
check "hereda el arranque"   'node server.js --port ${PORT}' "$A_START"
check "hereda las migraciones" "./manage.py migrate" "$A_MIGRATE"

section "Lo que no se hereda"
check "sin alias"            ""    "$A_ALIASES"
check "puerto propio"        "1"   "$([[ -n "$A_PORT" && "$A_PORT" != "3001" ]] && echo 1 || echo 0)"
check "sin autodespliegue"   "no"  "$A_AUTODEPLOY"
# Procesar la cola también es un permiso: un staging que la vacía manda de
# verdad los correos que se encuentre dentro.
check "sin cola"             "no"  "$A_QUEUE"
check "sin commit fallido"   ""    "$A_AUTOFAIL"
check "sin fecha de despliegue" "" "$A_LASTDEPLOY"
check "fecha de creación nueva" "1" "$([[ -n "$A_CREATED" ]] && echo 1 || echo 0)"

section "Las rutas absolutas apuntan a la copia"
# Una ruta absoluta con el nombre del original dentro hace que staging escriba
# en las subidas de producción. Es el fallo que no se nota hasta que ya pasó.
check "media reapuntada"  "$TMP/apps/copia/shared/media" "$A_MEDIA_ROOT"
check "relativa intacta"  "staticfiles"                  "$A_STATIC_ROOT"
check "url intacta"       "/media/"                      "$A_MEDIA_URL"

section "El .env lleva los nombres, no los valores"
ENVC="$TMP/apps/copia/shared/.env"
check "existe"               "1" "$([[ -f "$ENVC" ]] && echo 1 || echo 0)"
check "conserva la clave"    "1" "$(grep -c '^DATABASE_URL=$' "$ENVC")"
check "y el export"          "1" "$(grep -c '^export STRIPE_KEY=$' "$ENVC")"
check "conserva comentarios" "1" "$(grep -c 'la base de datos de produccion' "$ENVC")"
check "sin la contraseña"    "0" "$(grep -c 'secreta' "$ENVC")"
check "sin la clave de pago" "0" "$(grep -c 'sk_live' "$ENVC")"
check "avisa de qué falta"   "1" "$(grep -c 'orbit env copia' "$TMP/c1")"
check "y de la base de datos" "1" "$(grep -c 'orbit db create copia' "$TMP/c1")"

section "Lo demás que sí se copia"
check "las redirecciones"    "1" "$(grep -c '/vieja /nueva' "$TMP/etc/redirects/copia.list")"
check "la página de aviso"   "1" "$(grep -c 'volvemos enseguida' "$TMP/apps/copia/shared/maintenance.html")"

section "Nace en mantenimiento"
check "con el testigo puesto" "1" "$(_maint_is_on copia && echo 1 || echo 0)"
check "y dice por qué"        "1" "$(grep -c 'todavía no se ha desplegado' "$(maint_reason copia)")"
check "el original, no"       "0" "$(_maint_is_on origen && echo 1 || echo 0)"

section "El original no se toca"
load_app origen
check "conserva su puerto"    "3001"          "$A_PORT"
check "conserva su dominio"   "origen.test"   "$A_DOMAIN"
check "conserva sus alias"    "www.origen.test" "$A_ALIASES"
check "conserva su autodespliegue" "yes"      "$A_AUTODEPLOY"
check "conserva su cola"           "yes"      "$A_QUEUE"
check "conserva sus secretos" "1" "$(grep -c 'sk_live' "$TMP/apps/origen/shared/.env")"

section "Con --with-env, bajo tu responsabilidad"
run cmd_clone origen concopia --domain con.origen.test --with-env >"$TMP/c2" 2>&1
check "copia los valores"     "1" "$(grep -c 'sk_live_no_compartir' "$TMP/apps/concopia/shared/.env")"
check "y lo advierte"         "1" "$(grep -c 'escribirá ahí' "$TMP/c2")"

section "Se niega antes de escribir nada"
run cmd_clone origen copia --domain otra.test >/dev/null 2>&1; r=$?
check "nombre ya usado"       "1" "$r"
run cmd_clone noexiste x --domain x.test >/dev/null 2>&1; r=$?
check "origen inexistente"    "1" "$r"
run cmd_clone origen otra --domain origen.test >/dev/null 2>&1; r=$?
check "mismo dominio"         "1" "$r"
check "y no deja rastro"      "0" "$(app_exists otra && echo 1 || echo 0)"
run cmd_clone origen otra --domain www.origen.test >"$TMP/e1" 2>&1; r=$?
check "dominio de un alias"   "1" "$r"
check "y dice de quién es"    "1" "$(grep -c "app 'origen'" "$TMP/e1")"
run cmd_clone origen ../malo --domain m.test >/dev/null 2>&1; r=$?
check "nombre con ruta"       "1" "$r"
check "no escribe fuera"      "0" "$([[ -e "$TMP/etc/apps/../malo.conf" ]] && echo 1 || echo 0)"
run cmd_clone origen MAYUS --domain m.test >/dev/null 2>&1; r=$?
check "nombre en mayúsculas"  "1" "$r"
run cmd_clone origen otra --opcion-rara >/dev/null 2>&1; r=$?
check "opción desconocida"    "1" "$r"

# Una app de tipo 'redirect' no tiene código: clonarla no significa nada.
mkapp viejo.test redirect "" viejo.test
A_TYPE="redirect"; A_REDIRECT="https://nuevo.test"; A_REDIRECT_CODE="301"; save_app
run cmd_clone viejo.test otra --domain otro.test >"$TMP/e2" 2>&1; r=$?
check "clonar una redirección" "1" "$r"
check "y sugiere qué hacer"    "1" "$(grep -c 'orbit redirect add' "$TMP/e2")"

section "Si nginx rechaza el vhost, no queda nada"
LIBRE="$(free_port)"
render_nginx() { return 1; }
run cmd_clone origen rota --domain rota.test >/dev/null 2>&1; r=$?
check "aborta"                "1" "$r"
check "sin configuración"     "0" "$(app_exists rota && echo 1 || echo 0)"
check "sin directorio"        "0" "$([[ -d "$TMP/apps/rota" ]] && echo 1 || echo 0)"
check "sin redirecciones"     "0" "$([[ -f "$TMP/etc/redirects/rota.list" ]] && echo 1 || echo 0)"
check "el puerto vuelve a estar libre" "$LIBRE" "$(free_port)"
render_nginx() { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }

# ════════════════════════════════════════════════════════ nginx de verdad ══
# La afirmación importante del comando —«una copia sin desplegar contesta 503 y
# no 502»— no se puede comprobar leyendo el vhost: hay que pedírselo a nginx.
command -v nginx >/dev/null || { echo; echo "nginx no está: me salto la parte servida."; report; }

NG="$TMP/ng"; PORT=18091
mkdir -p "$NG"/{snippets,vhosts,logs,tmp,acme}
cert_file() { echo "$NG/certs/$1.crt"; }
cert_key()  { echo "$NG/certs/$1.key"; }

cat > "$NG/snippets/orbit-acme.conf" <<EOF
location ^~ /.well-known/acme-challenge/ { root $NG/acme; default_type "text/plain"; allow all; }
EOF
: > "$NG/snippets/orbit-security.conf"
: > "$NG/snippets/orbit-ssl.conf"

MIME=""; [[ -f /etc/nginx/mime.types ]] && MIME="    include /etc/nginx/mime.types;"
cat > "$NG/nginx.conf" <<EOF
worker_processes 1;
error_log $NG/logs/error.log warn;
pid $NG/nginx.pid;
events { worker_connections 128; }
http {
$MIME
    default_type application/octet-stream;
    access_log off;
    client_body_temp_path $NG/tmp;
    proxy_temp_path $NG/tmp;
    fastcgi_temp_path $NG/tmp;
    uwsgi_temp_path $NG/tmp;
    scgi_temp_path $NG/tmp;
    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
    limit_req_zone \$binary_remote_addr zone=orbit_general:1m rate=40r/s;
    limit_conn_zone \$binary_remote_addr zone=orbit_conn:1m;
    log_format orbit '\$remote_addr \$host "\$request" \$status';
    include $NG/vhosts/*.conf;
}
EOF

install_vhost() { # install_vhost <app>
  nginx_vhost "$1" \
    | sed -e "s#/etc/nginx/snippets/#$NG/snippets/#g" \
          -e "s#/var/log/nginx/#$NG/logs/#g" \
          -e "s/^\( *\)listen 80;/\1listen 127.0.0.1:$PORT;/" \
          -e "/listen \[::\]/d" \
    > "$NG/vhosts/$1.conf"
}

# El worker corre como 'nobody' y tiene que poder atravesar el temporal.
chmod 755 "$TMP"; chmod -R a+rX "$TMP/apps" 2>/dev/null || true
d="$TMP"; while [[ "$d" != "/" ]]; do chmod a+x "$d" 2>/dev/null || true; d="$(dirname "$d")"; done

install_vhost copia
nginx -c "$NG/nginx.conf" -t >/dev/null 2>&1 || { nginx -c "$NG/nginx.conf" -t; echo "vhost inválido"; exit 1; }
nginx -c "$NG/nginx.conf" >/dev/null 2>&1
sleep 0.5
get() { curl -s -o /dev/null -w '%{http_code}' -m 4 "http://127.0.0.1:$PORT$1"; }
body() { curl -s -m 4 "http://127.0.0.1:$PORT$1"; }

section "Servida de verdad, recién clonada"
check "responde 503"          "503" "$(get /)"
check "con la página del original" "1" "$(body / | grep -c 'volvemos enseguida')"
check "y el motivo por SSI"   "1" "$(body / | grep -c 'todavía no se ha desplegado')"
mkdir -p "$NG/acme/.well-known/acme-challenge"
printf 'ok\n' > "$NG/acme/.well-known/acme-challenge/x"
chmod -R a+rX "$NG/acme"
check "acme sigue pasando"    "1" "$(body /.well-known/acme-challenge/x | grep -c '^ok$')"

section "Y al quitar el mantenimiento deja de mentir"
run cmd_maintenance off copia >/dev/null 2>&1
check "ya no es 503"          "502" "$(get /)"

nginx -c "$NG/nginx.conf" -s stop >/dev/null 2>&1 || true

report
