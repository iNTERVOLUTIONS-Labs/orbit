#!/usr/bin/env bash
# Redirecciones: reglas de ruta, dominios enteros y su comportamiento en nginx.
#   bash tests/redirect_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, PORT_BASE,
# KEEP_RELEASES…) que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root()    { :; }
systemctl()    { :; }
render_nginx() { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }
LOG_FILE="$TMP/orbit.log"

# --- una app estática cualquiera y un dominio a redirigir ------------------
REL="$TMP/apps/web/releases/r1"
mkdir -p "$REL"
printf 'portada\n' > "$REL/index.html"
printf 'una pagina\n' > "$REL/pricing.html"
ln -sfn "$REL" "$TMP/apps/web/current"
mkapp web static "" "web.test"
A_OUTDIR="."; A_SPA="no"; save_app

section "Validación de las reglas"
run cmd_redirect add web /precios /pricing >/dev/null 2>&1; r=$?
check "acepta una regla normal" "0" "$r"
run cmd_redirect add web precios /pricing >"$TMP/e" 2>&1; r=$?
check "exige la barra inicial" "1" "$r"
check "y lo explica" "1" "$(grep -c "empezar por '/'" "$TMP/e")"
run cmd_redirect add web '/mal;return 301 http://malo' /x >"$TMP/e" 2>&1; r=$?
check "rechaza el punto y coma" "1" "$r"
run cmd_redirect add web '/comi"lla' /x >/dev/null 2>&1; r=$?
check "rechaza la comilla doble" "1" "$r"
run cmd_redirect add web /x 'destino-sin-barra' >/dev/null 2>&1; r=$?
check "exige destino válido" "1" "$r"
run cmd_redirect add web /x /y --409 >/dev/null 2>&1; r=$?
check "rechaza opción inventada" "1" "$r"
run cmd_redirect add noexiste /x /y >/dev/null 2>&1; r=$?
check "exige que la app exista" "1" "$r"

section "El fichero de reglas"
check "una sola regla" "1" "$(_redir_rules web | wc -l)"
check "legible con cat" "/precios /pricing 301" "$(_redir_rules web)"
# Repetir el mismo origen sustituye, no duplica.
run cmd_redirect add web /precios /tarifas --302 >/dev/null 2>&1
check "sustituye, no duplica" "1" "$(_redir_rules web | wc -l)"
check "guarda el código nuevo" "/precios /tarifas 302" "$(_redir_rules web)"
run cmd_redirect add web /precios /pricing >/dev/null 2>&1

section "Quitar reglas"
run cmd_redirect add web /temporal /x >/dev/null 2>&1
check "dos reglas" "2" "$(_redir_rules web | wc -l)"
run cmd_redirect rm web /temporal >/dev/null 2>&1; r=$?
check "quita" "0" "$r"
check "queda una" "1" "$(_redir_rules web | wc -l)"
# Quitar algo que no está es un no-op, no un error: el estado final es el mismo.
run cmd_redirect rm web /temporal >"$TMP/e" 2>&1; r=$?
check "quitar dos veces no falla" "0" "$r"
check "y lo dice" "1" "$(grep -c 'no tenía ninguna redirección' "$TMP/e")"

section "Orden de evaluación"
run cmd_redirect add web '/blog/*' '/noticias/*' >/dev/null 2>&1
run cmd_redirect add web '/blog/viejo/*' '/archivo/*' >/dev/null 2>&1
# Entre expresiones regulares gana la primera que coincide, así que la más
# específica tiene que emitirse antes o /blog/viejo/x acabaría en /noticias/.
LARGA="$(grep -n 'blog/viejo' "$TMP/vhost-web.conf" | cut -d: -f1)"
CORTA="$(grep -n 'location ~ "\^/blog/(' "$TMP/vhost-web.conf" | cut -d: -f1)"
check "la específica va antes" "1" "$([[ "$LARGA" -lt "$CORTA" ]] && echo 1 || echo 0)"
# Las exactas van delante de las regulares en el fichero generado.
EXACTA="$(grep -n 'location = /precios' "$TMP/vhost-web.conf" | cut -d: -f1)"
check "las exactas primero" "1" "$([[ "$EXACTA" -lt "$LARGA" ]] && echo 1 || echo 0)"

section "Redirección de dominio entero"
run cmd_redirect add viejo.test https://nuevo.test >/dev/null 2>&1; r=$?
check "crea la redirección" "0" "$r"
load_app viejo.test
check "es de tipo redirect" "redirect"            "$A_TYPE"
check "guarda el destino"   "https://nuevo.test"  "$A_REDIRECT"
check "301 por defecto"     "301"                 "$A_REDIRECT_CODE"
check "aparece en la lista" "1" "$(app_names | grep -cx 'viejo.test')"
# Un dominio no se despliega: no hay código detrás.
run cmd_deploy viejo.test >"$TMP/e" 2>&1; r=$?
check "no se puede desplegar" "1" "$r"
check "y explica por qué" "1" "$(grep -c 'no tiene código que desplegar' "$TMP/e")"
# Errores de uso de la forma de dominio.
run cmd_redirect add viejo.test nuevo.test >/dev/null 2>&1; r=$?
check "exige URL completa" "1" "$r"
run cmd_redirect add web /solo-dos-args >/dev/null 2>&1; r=$?
check "'web' no es un dominio" "1" "$r"
run cmd_redirect add web https://x.test >"$TMP/e" 2>&1; r=$?
check "y lo dice claro" "1" "$(grep -c 'no parece un dominio' "$TMP/e")"

# Un dominio que ya sirve otra app no puede convertirse en redirección: nginx
# admite dos vhosts con el mismo server_name avisando por el log y se queda con
# uno según el orden de los include, así que la redirección funcionaría o no
# según cómo se llame el fichero. Mejor negarse.
run cmd_redirect add web.test https://otro.test >"$TMP/e2" 2>&1; r=$?
check "dominio de otra app"   "1" "$r"
check "y dice de quién es"    "1" "$(grep -c "app «web»" "$TMP/e2")"
check "no crea nada"          "0" "$(app_exists web.test && echo 1 || echo 0)"
# También si es un alias, no sólo el dominio principal.
load_app web; A_ALIASES="www.web.test"; save_app
run cmd_redirect add www.web.test https://otro.test >/dev/null 2>&1; r=$?
check "alias de otra app"     "1" "$r"
load_app web; A_ALIASES=""; save_app
# Reescribir una redirección ya existente sigue estando permitido.
run cmd_redirect add viejo.test https://otro-destino.test >/dev/null 2>&1; r=$?
check "rehacer la suya sí"    "0" "$r"
load_app viejo.test
check "y actualiza el destino" "https://otro-destino.test" "$A_REDIRECT"
run cmd_redirect add viejo.test https://nuevo.test >/dev/null 2>&1

section "Si nginx rechaza, no queda nada a medias"
# render_nginx real falla si la configuración no valida. Aquí se simula para
# comprobar que no queda una redirección registrada que nginx no sirve.
_render_ok() { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }
render_nginx() { _render_ok "$1"; return 1; }
run cmd_redirect add roto.test https://destino.test >/dev/null 2>&1; r=$?
check "aborta" "1" "$r"
check "no deja la app creada" "0" "$(app_names | grep -cx 'roto.test' || true)"
run cmd_redirect add web /nueva-regla /x >/dev/null 2>&1; r=$?
check "aborta la de ruta" "1" "$r"
check "no deja la regla" "0" "$(_redir_rules web | grep -c '/nueva-regla' || true)"
render_nginx() { _render_ok "$1"; }

section "Listado"
run cmd_redirect list >"$TMP/lista" 2>&1
check "muestra la de ruta"    "1" "$(grep -c '/precios' "$TMP/lista")"
check "muestra la de dominio" "1" "$(grep -c 'https://nuevo.test' "$TMP/lista")"

# ═══════════════════════════════════════════════════════════════════════════
# Con nginx de verdad: lo único que demuestra que una redirección redirige.
# ═══════════════════════════════════════════════════════════════════════════
command -v nginx >/dev/null || {
  echo
  echo "nginx no está instalado: me salto la comprobación en vivo."
  report
}

NG="$TMP/ng"; PORT=18400
mkdir -p "$NG"/{snippets,vhosts,logs,tmp}
: > "$NG/snippets/orbit-acme.conf"
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

install_vhost() {
  nginx_vhost "$1" \
    | sed -e "s#/etc/nginx/snippets/#$NG/snippets/#g" \
          -e "s#/var/log/nginx/#$NG/logs/#g" \
          -e "s/^\( *\)listen 80;/\1listen 127.0.0.1:$PORT;/" \
          -e "/listen \[::\]/d" \
    > "$NG/vhosts/$1.conf"
}

# Un juego de reglas que cubre las tres formas y las dos políticas de consulta.
run cmd_redirect rm web '/blog/viejo/*' >/dev/null 2>&1
run cmd_redirect rm web '/blog/*'       >/dev/null 2>&1
run cmd_redirect add web /precios /pricing                    >/dev/null 2>&1
run cmd_redirect add web /promo   https://otro.test/oferta --302 >/dev/null 2>&1
run cmd_redirect add web /sinq    /destino --no-query         >/dev/null 2>&1
run cmd_redirect add web '/blog/*'       '/noticias/*'        >/dev/null 2>&1
run cmd_redirect add web '/blog/viejo/*' '/archivo/*'         >/dev/null 2>&1
run cmd_redirect add web '~^/p/(\d{3})$' '/producto/$1'       >/dev/null 2>&1
run cmd_redirect add web /index.html /                        >/dev/null 2>&1
install_vhost web
install_vhost viejo.test

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

CODE() { curl -s -o /dev/null -w '%{http_code}' -m 5 -H "Host: $1" "http://127.0.0.1:$PORT$2"; }
LOC()  { curl -sI -m 5 -H "Host: $1" "http://127.0.0.1:$PORT$2" | awk '/^[Ll]ocation:/{print $2}' | tr -d '\r'; }

section "Location relativo"
# Sin 'absolute_redirect off' nginx responde "http://web.test/pricing" usando
# el esquema de la conexión al origen. Detrás de Cloudflare esa conexión es por
# el puerto 80 aunque el visitante venga por HTTPS, así que el navegador
# bajaría a texto plano en cada redirección interna.
check "no degrada a http" "/pricing" \
  "$(curl -sI -m 5 -H 'Host: web.test' -H 'X-Forwarded-Proto: https' \
     "http://127.0.0.1:$PORT/precios" | awk '/^[Ll]ocation:/{print $2}' | tr -d '\r')"

section "Redirecciones en vivo"
check "exacta 301"     "301"       "$(CODE web.test /precios)"
check "exacta destino" "/pricing"  "$(LOC  web.test /precios)"
check "302 con flag"   "302"       "$(CODE web.test /promo)"
check "destino externo" "https://otro.test/oferta" "$(LOC web.test /promo)"

# 'return' de nginx descarta la cadena de consulta por defecto: si esto se
# rompe, se pierde ?utm_source= en cada redirección sin que nadie lo note.
check "conserva la consulta" "/pricing?utm_source=boletin" \
  "$(LOC web.test '/precios?utm_source=boletin')"
check "--no-query la descarta" "/destino" "$(LOC web.test '/sinq?utm_source=x')"

check "comodín captura"   "/noticias/hola"   "$(LOC web.test /blog/hola)"
check "comodín anidado"   "/archivo/x"       "$(LOC web.test /blog/viejo/x)"
check "regex con \\d{3}"  "/producto/123"    "$(LOC web.test /p/123)"
# /p/12 no casa con la regla y tampoco existe en disco: 404 es lo correcto.
check "regex no coincide" "404"              "$(CODE web.test /p/12)"
# El punto de /index.html es un carácter, no "cualquier carácter".
check "el punto es literal" "301" "$(CODE web.test /index.html)"
check "no cuela indexXhtml" "404" "$(CODE web.test /indexXhtml)"
check "lo no redirigido se sirve" "200" "$(CODE web.test /)"

section "Dominio entero en vivo"
check "redirige"           "301" "$(CODE viejo.test /cualquier/cosa)"
check "conserva ruta"      "https://nuevo.test/cualquier/cosa" "$(LOC viejo.test /cualquier/cosa)"
check "conserva consulta"  "https://nuevo.test/x?a=1"          "$(LOC viejo.test '/x?a=1')"
check "también la raíz"    "https://nuevo.test/"               "$(LOC viejo.test /)"

section "Sobreviven a la regeneración del vhost"
# El caso que motiva guardarlas fuera del vhost: 'orbit deploy' y
# 'orbit nginx-rebuild' lo reescriben entero.
run cmd_self_update >/dev/null 2>&1 || true
install_vhost web
check "siguen tras nginx-rebuild" "1" "$(grep -c 'location = /precios' "$NG/vhosts/web.conf")"
render_nginx web
install_vhost web
check "siguen tras regenerar" "1" "$(grep -c 'location = /precios' "$NG/vhosts/web.conf")"

report
