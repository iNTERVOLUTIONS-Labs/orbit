#!/usr/bin/env bash
# Pruebas del vhost generado, con nginx de verdad.
#   bash tests/nginx_test.sh
#
# Levanta un nginx aislado bajo un directorio temporal (puertos 18080/18443),
# así que no toca /etc/nginx ni el nginx del sistema. Si no hay binario de
# nginx, la prueba se salta con aviso en vez de fallar.
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, PORT_BASE,
# KEEP_RELEASES…) que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v nginx >/dev/null || {
  echo "nginx no está instalado: me salto las pruebas de vhost."
  echo "  sudo apt-get install -y nginx-light"
  exit 0
}

NG="$TMP/ng"
HTTP_PORT=18080
HTTPS_PORT=18443
mkdir -p "$NG"/{snippets,vhosts,logs,certs,tmp}

# Las pruebas apuntan los certificados a su propio directorio: así se ejercita
# la rama "con HTTPS" de nginx_vhost sin escribir en /etc/letsencrypt.
cert_file() { echo "$NG/certs/$1.crt"; }
cert_key()  { echo "$NG/certs/$1.key"; }

issue_cert() { # issue_cert <dominio>
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$(cert_key "$1")" -out "$(cert_file "$1")" \
    -subj "/CN=$1" >/dev/null 2>&1
}

# --- snippets equivalentes a los que escribe install.sh ---------------------
cat > "$NG/snippets/orbit-acme.conf" <<EOF
location ^~ /.well-known/acme-challenge/ {
    root $NG/acme;
    default_type "text/plain";
    allow all;
}
EOF

cat > "$NG/snippets/orbit-security.conf" <<'EOF'
add_header X-Content-Type-Options "nosniff" always;
location = /favicon.ico { access_log off; log_not_found off; }
location ~ /\.(?!well-known) { deny all; access_log off; log_not_found off; }
location ~* \.(env|log|sql|sqlite|bak|old|swp|ini|yml|yaml|toml)$ { deny all; }
location ^~ /.git/ { deny all; }
EOF

cat > "$NG/snippets/orbit-ssl.conf" <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
EOF

# --- nginx.conf de pruebas: reproduce las zonas de conf.d/00-orbit-base.conf
MIME=""
[[ -f /etc/nginx/mime.types ]] && MIME="    include /etc/nginx/mime.types;"
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

# --- instalar un vhost generado por orbit dentro del árbol de pruebas -------
install_vhost() { # install_vhost <app>
  nginx_vhost "$1" \
    | sed -e "s#/etc/nginx/snippets/#$NG/snippets/#g" \
          -e "s#/var/log/nginx/#$NG/logs/#g" \
          -e "s#/run/php/orbit.sock#$NG/php.sock#g" \
          -e "s#$TMP/pool/orbit-aislada.sock#$NG/php2.sock#g" \
          -e "s/^\( *\)listen 80;/\1listen 127.0.0.1:$HTTP_PORT;/" \
          -e "s/^\( *\)listen 443 ssl\(.*\);/\1listen 127.0.0.1:$HTTPS_PORT ssl\2;/" \
          -e "/listen \[::\]/d" \
    > "$NG/vhosts/$1.conf"
}

# --- fixtures: apps registradas y su contenido en disco ---------------------
mkweb() { # mkweb <app> <spa:yes|no> [contenido]
  local rel="$TMP/apps/$1/releases/r1"
  mkdir -p "$rel"
  printf '%s\n' "${3:-portada de $1}" > "$rel/index.html"
  printf 'no encontrado\n' > "$rel/404.html"
  ln -sfn "$rel" "$TMP/apps/$1/current"
  mkapp "$1" static "" "$1.test"
  A_SPA="$2"; A_OUTDIR="."; save_app
}

mkweb sincert   no "sin certificado"
mkweb concert   no "con certificado"
mkweb spa       yes "aplicacion de una pagina"
issue_cert concert.test
issue_cert spa.test

# app con proceso detrás: un servidor de verdad en el puerto interno
BACKPORT=18099
mkdir -p "$TMP/back"
printf 'respuesta del backend\n' > "$TMP/back/index.html"
python3 -m http.server "$BACKPORT" --bind 127.0.0.1 --directory "$TMP/back" >/dev/null 2>&1 &
BACKPID=$!
mkapp proxyapp node "$BACKPORT" "proxy.test"
issue_cert proxy.test

# App Python con estáticos: nginx debe servir /static/ y /media/ desde disco.
# Con DEBUG=False Django no los sirve, así que si esto no funciona el sitio
# sale sin CSS aunque el proceso esté perfectamente vivo.
PYREL="$TMP/apps/pyapp/releases/r1"
mkdir -p "$PYREL/staticfiles/css" "$TMP/apps/pyapp/shared/media"
printf 'body{color:red}\n' > "$PYREL/staticfiles/css/app.css"
printf 'una foto subida\n' > "$TMP/apps/pyapp/shared/media/foto.txt"
ln -sfn "$PYREL" "$TMP/apps/pyapp/current"
mkapp pyapp python "$BACKPORT" "py.test"
A_STATIC_URL="/static/"; A_STATIC_ROOT="staticfiles"
A_MEDIA_URL="/media/";   A_MEDIA_ROOT="$TMP/apps/pyapp/shared/media"
save_app
issue_cert py.test

# Web estática cuyos endpoints PHP viven FUERA de la carpeta compilada. Es lo
# que hace cualquier Astro o Vite con una carpeta 'api/' en la raíz: el build
# sólo copia public/ a dist/, así que api/ se queda donde está y nginx —que
# sirve dist/— devolvía 404 en todos los endpoints con la web viéndose perfecta.
AREL="$TMP/apps/apiweb/releases/r1"
ASHARED="$TMP/apps/apiweb/shared"
mkdir -p "$AREL/dist" "$AREL/api" "$ASHARED/api/undelivered"
printf 'la portada compilada\n'                 > "$AREL/dist/index.html"
printf '<?php echo "endpoint vivo\n"; ?>\n'     > "$AREL/api/contact.php"
printf '<?php echo "no soy un endpoint\n"; ?>\n' > "$AREL/api/_lib.php"
printf 'una hoja de estilo\n'                   > "$AREL/api/no-es-codigo.txt"
# Y dentro, lo que la app escribe en tiempo de ejecución: por el modelo de §4
# eso vive en shared/, y lo que apunta a shared/ es dato, no se sirve nunca.
printf 'From: alguien\n\nCV con datos personales\n' > "$ASHARED/api/undelivered/2026.eml"
printf '{"visitas":42}\n'                          > "$ASHARED/api/stats.json"
ln -sfn "$ASHARED/api/undelivered" "$AREL/api/undelivered"
ln -sfn "$ASHARED/api/stats.json"  "$AREL/api/stats.json"
ln -sfn "$AREL" "$TMP/apps/apiweb/current"
mkapp apiweb static "" "apiweb.test"
A_TYPE="static"; A_OUTDIR="dist"; A_SPA="no"; A_PHP="yes"; save_app

# App de Deno, con su código dentro de la release. En Deno y en Bun no hay
# carpeta compilada: lo que se despliega es el fuente. Si el vhost sirviera
# algo de disco, serviría el servidor entero — main.ts salía con 200 y el
# cuerpo completo. Aquí no puede haber ni una ruta que llegue al disco.
DREL="$TMP/apps/denoapp/releases/r1"
mkdir -p "$DREL"
printf 'const CLAVE = "secreto-de-deno";\nDeno.serve(() => new Response("hola"));\n' > "$DREL/main.ts"
printf '{"tasks":{"start":"deno serve main.ts"}}\n' > "$DREL/deno.json"
printf 'API_KEY=no-mirar\n' > "$DREL/.env"
ln -sfn "$DREL" "$TMP/apps/denoapp/current"
mkapp denoapp deno "$BACKPORT" "deno.test"
A_TYPE="deno"; save_app
issue_cert deno.test

# App híbrida: web estática compilada con un .php dentro, que es lo que monta
# cualquiera que tenga un Astro con formulario de contacto.
HREL="$TMP/apps/hibrida/releases/r1"
mkdir -p "$HREL"
printf 'portada de hibrida\n' > "$HREL/index.html"
printf '<?php echo "hola desde php\\n"; echo $_SERVER["REQUEST_METHOD"], "\\n"; ?>\n' > "$HREL/contacto.php"
ln -sfn "$HREL" "$TMP/apps/hibrida/current"
mkdir -p "$TMP/apps/hibrida/shared"
printf 'volvemos enseguida\n' > "$TMP/apps/hibrida/shared/maintenance.html"
mkapp hibrida static "" "hibrida.test"
A_OUTDIR="."; A_SPA="no"; A_PHP="yes"; save_app

# App PHP con subidas dentro del docroot, que es de donde salía una ejecución
# remota de código. 'php artisan storage:link' deja exactamente este árbol:
# public/storage → shared/storage/app/public, o sea una carpeta escribible por
# los visitantes dentro de lo que sirve nginx. Con 'location ~ \.php$' casando
# con cualquier ruta, subir un .php y pedirlo lo ejecutaba — y el pool de
# php-fpm corre como el usuario de despliegue, dueño del código y del .env de
# todas las apps.
TREL="$TMP/apps/tienda/releases/r1"
TSHARED="$TMP/apps/tienda/shared"
mkdir -p "$TREL/public" "$TSHARED/storage/app/public" "$TREL/public/uploads"
printf '<?php echo "la tienda\n"; ?>\n' > "$TREL/public/index.php"
ln -sfn "$TSHARED/storage" "$TREL/storage"
ln -sfn "$TSHARED/storage/app/public" "$TREL/public/storage"
ln -sfn "$TREL" "$TMP/apps/tienda/current"
# Lo que sube un visitante: una foto de verdad y algo que no lo es.
printf 'una foto\n'                              > "$TSHARED/storage/app/public/foto.jpg"
printf '<?php echo "EJECUTADO\n"; ?>\n'          > "$TSHARED/storage/app/public/avatar.php"
printf '<?php echo "EJECUTADO\n"; ?>\n'          > "$TREL/public/uploads/nota.php"
# Y lo que no es ejecutable pero tampoco es para nadie. El snippet de seguridad
# deniega estas extensiones… pero un prefijo '^~' hace que nginx deje de mirar
# las expresiones regulares, así que el snippet quedaba apagado justo donde el
# nombre del fichero lo elige un desconocido.
printf 'APP_KEY=base64:SECRETO-ROBADO\n'         > "$TSHARED/storage/app/public/robado.env"
printf 'DROP TABLE users;\n'                     > "$TSHARED/storage/app/public/volcado.sql"
printf 'clave: secreta\n'                        > "$TSHARED/storage/app/public/conf.yaml"
printf 'binario sqlite\n'                        > "$TSHARED/storage/app/public/datos.sqlite"
mkdir -p "$TSHARED/storage/app/public/.git"
printf '[core]\n'                                > "$TSHARED/storage/app/public/.git/config"
mkapp tienda php "" "tienda.test"
A_TYPE="php"; A_DOCROOT="public"; save_app
# El secreto que esta app NO puede dejar leer a las demás. Dueño www-data
# —que es quien corre su pool en este árbol— y 0640, igual que en producción.
printf 'APP_KEY=el-secreto-de-tienda\n' > "$TSHARED/.env"
chown www-data:www-data "$TSHARED/.env" 2>/dev/null || true
chmod 0640 "$TSHARED/.env"
# Una sonda que intenta leerlo. La misma en las dos apps: lo único que cambia
# es el pool que la ejecuta, que es exactamente la variable bajo prueba.
SONDA='<?php $c=@file_get_contents("'"$TSHARED"'/.env"); echo $c ? "LEIDO:$c" : "DENEGADO\n"; ?>'
printf '%s\n' "$SONDA" > "$TREL/public/sonda.php"
printf '<?php echo posix_getpwuid(posix_geteuid())["name"] ?? "?", "\n"; ?>' \
  > "$TREL/public/quien.php"

# La app aislada: mismo PHP, otro usuario, otro pool. Es la mitad del
# aislamiento que faltaba (§5.3): con el pool compartido, este .php corría
# como el mismo usuario que el de 'tienda' y se llevaba su .env entero.
ISREL="$TMP/apps/aislada/releases/r1"
mkdir -p "$ISREL/public"
printf '<?php echo "la web aislada\n"; ?>\n' > "$ISREL/public/index.php"
printf '%s\n' "$SONDA" > "$ISREL/public/sonda.php"
printf '<?php echo posix_getpwuid(posix_geteuid())["name"] ?? "?", "\n"; ?>' \
  > "$ISREL/public/quien.php"
ln -sfn "$ISREL" "$TMP/apps/aislada/current"
mkapp aislada php "" "aislada.test"
A_TYPE="php"; A_DOCROOT="public"; A_USER="nobody"; save_app

# La misma app, pero declarada como Laravel: es un tipo nuevo, y lo que hay que
# comprobar es que entra por donde entra PHP y no por el 'die' del final.
LREL="$TMP/apps/lara/releases/r1"
LSHARED="$TMP/apps/lara/shared"
mkdir -p "$LREL/public" "$LSHARED/storage/app/public"
printf '<?php echo "la web de laravel\n"; ?>\n' > "$LREL/public/index.php"
printf 'APP_KEY=base64:secreta-de-laravel\n'   > "$LSHARED/.env"
ln -sfn "$LSHARED/.env" "$LREL/.env"
ln -sfn "$LSHARED/storage" "$LREL/storage"
# Lo que deja 'php artisan storage:link': un enlace absoluto que salta dos veces
# hasta shared/, con las subidas de los usuarios dentro del docroot.
ln -sfn "$LREL/storage/app/public" "$LREL/public/storage"
ln -sfn "$LREL" "$TMP/apps/lara/current"
printf 'una foto de laravel\n'          > "$LSHARED/storage/app/public/foto.jpg"
printf '<?php echo "EJECUTADO\n"; ?>\n' > "$LSHARED/storage/app/public/avatar.php"
mkapp lara laravel "" "lara.test"
A_TYPE="laravel"; A_DOCROOT="public"; save_app

# El mismo Laravel, pero en backend/ dentro de un monorepo. Lo que se comprueba
# aquí no es la detección —eso es detect_test— sino que el vhost que sale de un
# A_DOCROOT con subcarpeta sirve la app y **no** deja al alcance nada de lo que
# hay por encima del docroot: el .env que ahora se enlaza también dentro de la
# app, el composer.json, el artisan, ni el frontend de al lado. Sin subcarpeta
# esto ya estaba probado; con ella el docroot baja un nivel y todo lo que antes
# quedaba fuera del árbol pasa a estar a dos saltos de la raíz servida.
MREL="$TMP/apps/monolara/releases/r1"
MSHARED="$TMP/apps/monolara/shared"
mkdir -p "$MREL/backend/public" "$MREL/frontend/src" "$MSHARED/storage/app/public"
printf '<?php echo "la web del monorepo\n"; ?>\n' > "$MREL/backend/public/index.php"
printf '{"require":{"laravel/framework":"^13.0"}}\n' > "$MREL/backend/composer.json"
printf '#!/usr/bin/env php\n'                    > "$MREL/backend/artisan"
printf 'const SECRETO = "clave-del-front";\n'    > "$MREL/frontend/src/app.js"
printf 'APP_KEY=base64:secreta-del-monorepo\n'   > "$MSHARED/.env"
# Los dos enlaces que hace el despliegue: el de la raíz de la release y el de
# dentro de la app, que es el que lee Laravel.
ln -sfn "$MSHARED/.env" "$MREL/.env"
ln -sfn "$MSHARED/.env" "$MREL/backend/.env"
ln -sfn "$MSHARED/storage" "$MREL/backend/storage"
ln -sfn "$MREL/backend/storage/app/public" "$MREL/backend/public/storage"
ln -sfn "$MREL" "$TMP/apps/monolara/current"
printf 'una foto del monorepo\n'        > "$MSHARED/storage/app/public/foto.jpg"
printf '<?php echo "EJECUTADO\n"; ?>\n' > "$MSHARED/storage/app/public/avatar.php"
mkapp monolara laravel "" "monolara.test"
A_TYPE="laravel"; A_DOCROOT="backend/public"; A_APPDIR="backend"; save_app

# Un generador estático en una subcarpeta —el caso de Hugo en 'site/'—. Aquí lo
# que se mueve es la carpeta compilada, que es literalmente lo que sirve nginx:
# si A_OUTDIR se queda en 'public' apunta a algo que no existe, y si se queda en
# '.' publica el repositorio entero. Las dos son el agujero de §18.8.
GREL="$TMP/apps/monoweb/releases/r1"
mkdir -p "$GREL/site/public" "$GREL/site/content" "$GREL/site/layouts"
printf 'portada compilada
'            > "$GREL/site/public/index.html"
printf 'title = "x"
'                  > "$GREL/site/hugo.toml"
printf '# borrador sin publicar
'      > "$GREL/site/content/borrador.md"
printf 'SECRETO=no-mirar
'             > "$GREL/site/config.privado"
ln -sfn "$GREL" "$TMP/apps/monoweb/current"
mkapp monoweb static "" "monoweb.test"
A_TYPE="static"; A_OUTDIR="site/public"; A_APPDIR="site"; A_SPA="no"; save_app

# php-fpm de verdad si está instalado: probar que el vhost "parece correcto" no
# demuestra que el formulario funcione, que es justo lo que falló.
#
# La versión no se fija: producción instala php8.3-fpm, pero el contenedor de
# desarrollo puede traer otra (pasó con 8.4, de sury) y para lo que se prueba
# aquí —que nginx le pasa los .php a un pool— cualquier php-fpm vale. Cuando
# esto buscaba sólo php-fpm8.3, con 8.4 instalado no se saltaba: ver abajo.
PHPFPM="$(command -v php-fpm8.3 || command -v php-fpm || true)"
if [[ -z "$PHPFPM" || ! -x "$PHPFPM" ]]; then
  for _f in /usr/sbin/php-fpm*; do [[ -x "$_f" ]] && PHPFPM="$_f"; done
fi

# php-fpm sólo baja de privilegios si lo arranca root: sin eso IGNORA las
# directivas 'user' de los pools y todos corren como quien lo lanzó. Importa
# para una sola sección —la del aislamiento entre apps PHP, que necesita dos
# pools con usuarios DISTINTOS—, y era un fallo real: en CI, que corre como
# 'runner', los dos pools eran el mismo usuario y la prueba se ponía en rojo
# acusando a código que estaba bien. El tercer estado otra vez.
#
# Así que el privilegio se pide explícitamente y, si no lo hay, esa sección se
# salta en voz alta. El resto de las pruebas de PHP no lo necesitan: sólo
# comprueban que nginx le pasa los .php a un pool, y para eso da igual quién
# lo ejecute.
SUDO=""
if [[ $EUID -ne 0 ]] && sudo -n true 2>/dev/null; then SUDO="sudo"; fi
priv() { if [[ -n "$SUDO" ]]; then sudo "$@"; else "$@"; fi; }
PUEDE_AISLAR="no"
[[ $EUID -eq 0 || -n "$SUDO" ]] && PUEDE_AISLAR="si"
if [[ -n "$PHPFPM" ]]; then
  cat > "$NG/php-fpm.conf" <<EOF
[global]
error_log = $NG/logs/php-error.log
pid = $NG/php.pid
daemonize = yes
[orbit]
listen = $NG/php.sock
listen.mode = 0666
user = www-data
group = www-data
pm = static
pm.max_children = 2
; El pool de la app aislada: OTRO usuario y OTRO socket, que es justo lo que
; hace 'orbit isolate' en una app PHP. Aquí es 'nobody' en vez de un
; orbit-<app> de verdad porque una prueba no crea usuarios; lo que se ejerce
; es la propiedad, no el nombre.
[orbit-aislada]
listen = $NG/php2.sock
listen.mode = 0666
user = nobody
group = nogroup
pm = static
pm.max_children = 2
; Fiel al que escribe render_php_pool: el cinturón sobre los tirantes. Sin
; esto la prueba sólo ejercería la mitad de dueños, y el producto lleva las
; dos — un fichero de otra app al que alguien le abriera los permisos seguiría
; estando fuera del alcance de este pool.
php_admin_value[open_basedir] = $TMP/apps/aislada:/tmp
EOF
  # php-fpm se niega a correr como root, así que el pool va como www-data y el
  # árbol de pruebas tiene que ser legible para él.
  chmod a+rx "$TMP" "$NG" 2>/dev/null || true
  chmod -R a+rX "$TMP/apps/hibrida" "$TMP/apps/tienda" "$TMP/apps/monolara" 2>/dev/null || true
  priv "$PHPFPM" -y "$NG/php-fpm.conf" >/dev/null 2>&1
  [[ -S "$NG/php.sock" ]] || PHPFPM=""
fi

# El snippet que incluye el vhost lo pone Ubuntu en /etc/nginx; en el árbol de
# pruebas hay que dejarlo donde nginx lo va a buscar (bajo el prefijo). Y hace
# falta SIEMPRE, no sólo cuando php-fpm corre: los vhosts de las apps PHP lo
# incluyen igual, y con el snippet ausente 'nginx -t' muere y arrastra a las 28
# comprobaciones que vienen detrás — el tercer estado otra vez: ni probado ni
# saltado, sino en rojo acusando a código que estaba bien. Así se descubrió,
# con php-fpm8.4 instalado y la copia dentro del bloque de php-fpm8.3.
if [[ -f /etc/nginx/snippets/fastcgi-php.conf ]]; then
  cp /etc/nginx/snippets/fastcgi-php.conf "$NG/snippets/fastcgi-php.conf"
else
  # Equivalente mínimo del que trae Ubuntu, para que la validación no dependa
  # de qué paquete de nginx está instalado.
  cat > "$NG/snippets/fastcgi-php.conf" <<'EOF'
fastcgi_split_path_info ^(.+?\.php)(/.*)$;
try_files $fastcgi_script_name =404;
set $path_info $fastcgi_path_info;
fastcgi_param PATH_INFO $path_info;
fastcgi_index index.php;
include fastcgi.conf;
EOF
fi
if [[ -f /etc/nginx/fastcgi.conf ]]; then
  cp /etc/nginx/fastcgi.conf "$NG/fastcgi.conf"
else
  printf 'fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;\nfastcgi_param QUERY_STRING $query_string;\nfastcgi_param REQUEST_METHOD $request_method;\n' \
    > "$NG/fastcgi.conf"
fi

for app in sincert concert spa proxyapp pyapp hibrida tienda aislada denoapp lara monolara monoweb apiweb; do install_vhost "$app"; done

# El servidor por defecto, igual que lo escribe install.sh. Va en 000- para que
# nginx lo vea antes que los vhosts de las apps, que es de donde salía el bug:
# sin un default_server en 443, una petición HTTPS con un nombre que nadie
# sirve caía en el primer bloque con certificado —la primera app— y le
# enseñaba a un desconocido la web de otro.
DEFAULT_VHOST="$NG/vhosts/000-default.conf"
_default_vhost > "$DEFAULT_VHOST"
sed -i -e "s#/etc/nginx/snippets/#$NG/snippets/#g" \
       -e "s/^\( *\)listen 80 default_server;/\1listen 127.0.0.1:$HTTP_PORT default_server;/" \
       -e "s/^\( *\)listen 443 ssl default_server;/\1listen 127.0.0.1:$HTTPS_PORT ssl default_server;/" \
       -e "/listen \[::\]/d" "$DEFAULT_VHOST"

section "Validación de la configuración"
nginx -t -c "$NG/nginx.conf" -p "$NG" >"$NG/logs/t.out" 2>&1 && r=ok || r=error
[[ "$r" == ok ]] || sed 's/^/      /' "$NG/logs/t.out"
check "nginx -t" "ok" "$r"

grep -q 'ssl_certificate ' "$NG/vhosts/concert.conf" && r=si || r=no
check "rama con certificado" "si" "$r"
grep -q 'ssl_certificate ' "$NG/vhosts/sincert.conf" && r=si || r=no
check "rama sin certificado" "no" "$r"
# El fallback de una SPA va a una named location, no al URI /index.html: con el
# URI, si falta el fichero nginx vuelve a entrar en location / y acaba dando 500
# en todo el sitio en vez de 404 en una ruta.
grep -q 'try_files .* @spa;' "$NG/vhosts/spa.conf" && r=si || r=no
check "spa con fallback" "si" "$r"
grep -q 'try_files /index.html =404;' "$NG/vhosts/spa.conf" && r=si || r=no
check "y termina en 404" "si" "$r"
grep -q 'try_files .*=404;' "$NG/vhosts/sincert.conf" && r=si || r=no
check "estática sin fallback" "si" "$r"

# --- arrancar nginx --------------------------------------------------------
chmod 711 "$TMP"; chmod -R a+rX "$NG" "$TMP/apps" "$TMP/back"
nginx -c "$NG/nginx.conf" -p "$NG" 2>>"$NG/logs/error.log"
started=$?
# La limpieza pasa por 'priv' porque el php-fpm de la sección de aislamiento
# lo arranca root: su pid y sus logs son suyos, y ni el kill ni el rm saldrían
# de otra forma.
trap 'nginx -c "$NG/nginx.conf" -p "$NG" -s quit 2>/dev/null; kill $BACKPID 2>/dev/null; [[ -f "$NG/php.pid" ]] && priv kill "$(cat "$NG/php.pid")" 2>/dev/null; priv rm -rf "$TMP"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$HTTP_PORT/" && break
  sleep 0.3
done
check "nginx arranca" "0" "$started"

# --noproxy: en un entorno con HTTPS_PROXY configurado, una URL con nombre
# —no con IP— saldría por el proxy y no llegaría nunca a este nginx.
H() { curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -m 5 "$@"; }
BODY() { curl -s --noproxy '*' -m 5 "$@"; }

# Petición HTTPS con SNI de verdad. Pedirle a curl "https://127.0.0.1" con una
# cabecera Host **no manda SNI**, porque el SNI sale del nombre de la URL y ahí
# hay una IP. Sin SNI, nginx resuelve con el servidor por defecto — que es
# justo el fallo que estas pruebas vigilan, así que probar así daría verde por
# el motivo equivocado. Con --resolve el nombre viaja en el saludo TLS.
HS()    { local h="$1"; shift; H    -k --resolve "$h:$HTTPS_PORT:127.0.0.1" "$@"; }
BODYS() { local h="$1"; shift; BODY -k --resolve "$h:$HTTPS_PORT:127.0.0.1" "$@"; }

section "Bucle de redirecciones (no regresión)"
# Con certificado y sin X-Forwarded-Proto, el puerto 80 debe redirigir…
check "80 sin XFP → 301" "301" \
  "$(H -H 'Host: concert.test' "http://127.0.0.1:$HTTP_PORT/")"
# …pero si Cloudflare ya sirvió al visitante por HTTPS, hay que servir la
# página. Si esto redirige, vuelve el ERR_TOO_MANY_REDIRECTS en modo Flexible.
check "80 con XFP → 200" "200" \
  "$(H -H 'Host: concert.test' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$HTTP_PORT/")"
check "80 con XFP sirve" "con certificado" \
  "$(BODY -H 'Host: concert.test' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$HTTP_PORT/")"
# Sin certificado no hay a dónde redirigir: se sirve tal cual.
check "sin cert → 200" "200" \
  "$(H -H 'Host: sincert.test' "http://127.0.0.1:$HTTP_PORT/")"

section "HTTPS"
check "443 sirve" "200" \
  "$(HS concert.test "https://concert.test:$HTTPS_PORT/")"
check "HSTS presente" "1" \
  "$(curl -skI --noproxy '*' -m 5 --resolve "concert.test:$HTTPS_PORT:127.0.0.1" \
       "https://concert.test:$HTTPS_PORT/" | grep -ci '^strict-transport-security')"

section "Rutas y fallbacks"
check "spa ruta inventada" "200" \
  "$(HS spa.test "https://spa.test:$HTTPS_PORT/una/ruta/inventada")"
check "estática ruta inventada" "404" \
  "$(H -H 'Host: sincert.test' "http://127.0.0.1:$HTTP_PORT/una/ruta/inventada")"
check "proxy al puerto interno" "respuesta del backend" \
  "$(BODYS proxy.test "https://proxy.test:$HTTPS_PORT/")"

section "Estáticos de Python servidos por nginx"
check "/static/ desde disco" "body{color:red}" \
  "$(BODYS py.test "https://py.test:$HTTPS_PORT/static/css/app.css")"
check "/media/ ruta absoluta" "una foto subida" \
  "$(BODYS py.test "https://py.test:$HTTPS_PORT/media/foto.txt")"
# Lo que no es estático sigue yendo al proceso.
check "el resto va al proxy" "respuesta del backend" \
  "$(BODYS py.test "https://py.test:$HTTPS_PORT/")"
check "estático inexistente" "404" \
  "$(HS py.test "https://py.test:$HTTPS_PORT/static/no-existe.css")"
# Sin estáticos declarados no debe aparecer ningún bloque alias.
check "node sin bloque alias" "0" "$(grep -c 'alias' "$NG/vhosts/proxyapp.conf")"

section "Un dominio que no sirve nadie"
# El bug: alguien apunta su dominio a este servidor —o se despliega uno y aún
# no tiene certificado— y por HTTPS le contestaba la primera app de la lista.
# Enseñarle a un desconocido la web de otro no es un fallo de comodidad.
check "por HTTP, conexión cerrada" "000" \
  "$(H -H 'Host: nadie.test' "http://127.0.0.1:$HTTP_PORT/")"
# Por HTTPS se rechaza el saludo TLS: no hay certificado para ese nombre y
# fingir que sí lo hay sólo cambia el problema por un aviso del navegador.
run curl -sk --noproxy '*' --max-time 5 --resolve "nadie.test:$HTTPS_PORT:127.0.0.1" "https://nadie.test:$HTTPS_PORT/" >/dev/null 2>&1; r=$?
check "por HTTPS, saludo rechazado" "1" "$([[ "$r" != 0 ]] && echo 1 || echo 0)"
check "y no sale la web de otro" "0" \
  "$(BODYS nadie.test "https://nadie.test:$HTTPS_PORT/" 2>/dev/null | grep -c 'con certificado')"

# Una app desplegada a la que todavía no se le ha emitido el certificado: su
# vhost sólo tiene el puerto 80. Antes, pedirla por HTTPS enseñaba otra web.
check "sin certificado, tampoco" "0" \
  "$(BODYS sincert.test "https://sincert.test:$HTTPS_PORT/" 2>/dev/null | grep -c 'con certificado')"
# Y por HTTP la suya sigue funcionando: rechazar el HTTPS no puede romper eso.
check "pero por HTTP sí"    "sin certificado" \
  "$(BODY -H 'Host: sincert.test' "http://127.0.0.1:$HTTP_PORT/")"
# El que sí tiene certificado no se entera de nada de esto.
check "el que tiene cert, igual" "200" \
  "$(HS concert.test "https://concert.test:$HTTPS_PORT/")"
# La validación de Let's Encrypt entra por el puerto 80 antes de que exista el
# vhost de la app: si el servidor por defecto la bloqueara, no habría forma de
# emitir el primer certificado.
mkdir -p "$NG/acme/.well-known/acme-challenge"
printf 'token-de-prueba\n' > "$NG/acme/.well-known/acme-challenge/xyz"
check "acme sigue pasando"  "token-de-prueba" \
  "$(BODY -H 'Host: nadie.test' "http://127.0.0.1:$HTTP_PORT/.well-known/acme-challenge/xyz")"
# Y con el vhost de una app que YA tiene certificado, que es el caso de la
# renovación. Aquí no basta con incluir el snippet: la redirección a HTTPS es
# un 'if' a nivel de server, y nginx evalúa la fase rewrite del server ANTES de
# elegir el location, así que se llevaba por delante también el reto de ACME —
# el 'location ^~' no llegaba a mirarse. La emisión funcionaba, porque cuando
# se emite todavía no hay redirección que esquivar; la RENOVACIÓN no podía
# funcionar nunca. certbot pedía por HTTP, recibía un 301 al HTTPS —que no
# sirve el reto— y contestaba 404: el certificado caducaba en silencio a los 90
# días. Salió con certbot de verdad en un VPS, con 'certbot renew --dry-run'.
check "acme con cert no redirige" "200" \
  "$(H -H 'Host: concert.test' "http://127.0.0.1:$HTTP_PORT/.well-known/acme-challenge/xyz")"
check "y sirve el token"          "token-de-prueba" \
  "$(BODY -H 'Host: concert.test' "http://127.0.0.1:$HTTP_PORT/.well-known/acme-challenge/xyz")"
# Lo demás sigue redirigiendo: la excepción es sólo para el reto.
check "el resto sí redirige"      "301" \
  "$(H -H 'Host: concert.test' "http://127.0.0.1:$HTTP_PORT/otra/cosa")"

section "El diagnóstico lo detecta en un servidor antiguo"
# Los servidores instalados antes de que existiera el bloque de 443 siguen
# expuestos hasta que se regeneran, así que 'orbit doctor' tiene que decirlo
# con todas las letras y dar el comando.
NGINX_DEFAULT_CONF="$TMP/000-orbit-default"
printf 'server {\n    listen 80 default_server;\n    server_name _;\n}\n' > "$NGINX_DEFAULT_CONF"
DOC_LEVEL=(); DOC_ID=(); DOC_MSG=(); DOC_FIX=()
nginx -t >/dev/null 2>&1   # el resto del diagnóstico no importa aquí
_doc_default() {           # sólo la parte que se está probando
  if [[ ! -f "$NGINX_DEFAULT_CONF" ]]; then
    _doc error default-server "sin servidor por defecto" "orbit nginx-rebuild"
  elif ! grep -q 'listen 443 ssl default_server' "$NGINX_DEFAULT_CONF"; then
    _doc error default-server "no cubre el 443" "sudo orbit nginx-rebuild"
  else
    _doc ok default-server "cubre 80 y 443"
  fi
}
_doc_default
check "servidor viejo, error" "error" "${DOC_LEVEL[0]}"
check "y dice cómo arreglarlo" "1" "$(grep -c 'nginx-rebuild' <<<"${DOC_FIX[0]}")"
DOC_LEVEL=(); DOC_ID=(); DOC_MSG=(); DOC_FIX=()
_default_vhost > "$NGINX_DEFAULT_CONF"
_doc_default
check "ya regenerado, correcto" "ok" "${DOC_LEVEL[0]}"

section "Ficheros sensibles"
printf 'SECRETO=1\n' > "$TMP/apps/sincert/releases/r1/.env"
chmod a+r "$TMP/apps/sincert/releases/r1/.env"
check ".env bloqueado" "403" \
  "$(H -H 'Host: sincert.test' "http://127.0.0.1:$HTTP_PORT/.env")"

# Un .php dentro de una web estática se servía tal cual: nginx no tiene '.php'
# en mime.types, así que salía como octet-stream y el navegador se descargaba
# **el código fuente**, con las credenciales que llevara dentro. Es el caso de
# un sitio Astro con un formulario de contacto en PHP.
printf '<?php $SMTP_PASS = "secreta-de-verdad"; mail("a@b.c","x","y"); ?>\n' \
  > "$TMP/apps/sincert/releases/r1/contacto.php"
chmod a+r "$TMP/apps/sincert/releases/r1/contacto.php"
check "el código PHP no se sirve" "0" \
  "$(BODY -H 'Host: sincert.test' "http://127.0.0.1:$HTTP_PORT/contacto.php" | grep -c 'secreta-de-verdad')"
check "y devuelve 404" "404" \
  "$(H -H 'Host: sincert.test' "http://127.0.0.1:$HTTP_PORT/contacto.php")"

section "Lo que sube un visitante no se ejecuta"
# La regla: la release es código que viene de git, y shared/ es lo que se
# escribe en tiempo de ejecución. Lo que se alcanza por un enlace a shared/ es
# dato, nunca código — y nginx no puede distinguirlos por sí solo, porque
# 'location ~ \.php$' casa con la ruta, no con el origen del fichero.
if [[ -z "$PHPFPM" ]]; then
  echo "  (sin php-fpm instalado: me salto la ejecución real)"
else
  # Primero, que la app siga funcionando: sin esto la prueba de abajo pasaría
  # con un vhost que no sirve nada.
  check "la app PHP funciona" "la tienda" \
    "$(BODY -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/")"
  # Y que las subidas legítimas se sigan sirviendo: cerrar el agujero rompiendo
  # las fotos no es cerrarlo.
  check "las subidas se sirven" "una foto" \
    "$(BODY -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/storage/foto.jpg")"
  # El agujero: un .php subido, dentro del docroot por el enlace de storage:link.
  check "el .php subido no se ejecuta" "404" \
    "$(H -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/storage/avatar.php")"
  # Y tampoco se sirve tal cual: cambiar una ejecución remota por una fuga del
  # código fuente es mejor, pero sigue siendo un fallo.
  check "ni se filtra su fuente" "0" \
    "$(BODY -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/storage/avatar.php" | grep -c 'EJECUTADO\|<?php')"
  # Una carpeta de subidas que es un directorio de verdad dentro de la release,
  # no un enlace: es el caso de la app que escribe donde no debe.
  check "uploads/ tampoco ejecuta" "404" \
    "$(H -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/uploads/nota.php")"
fi
# Éstas no necesitan php-fpm: es nginx quien tiene que negarse.
#
# El agujero que fijan: 'orbit-security.conf' deniega .env, .sql, .sqlite y
# compañía con una 'location' de expresión regular, y un prefijo '^~' gana a
# **todas** las expresiones regulares del servidor. O sea que el bloque que
# protege las carpetas de subidas apagaba el snippet justo ahí, y un fichero
# subido con uno de esos nombres se servía entero. Medido: 200 y el cuerpo.
check "un .env subido"     "404" \
  "$(H -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/storage/robado.env")"
check "y no se filtra"     "0" \
  "$(BODY -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/storage/robado.env" | grep -c SECRETO)"
check "un .sql subido"     "404" \
  "$(H -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/storage/volcado.sql")"
check "un .sqlite subido"  "404" \
  "$(H -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/storage/datos.sqlite")"
check "un .yaml subido"    "404" \
  "$(H -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/storage/conf.yaml")"
check "un .git subido"     "404" \
  "$(H -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/storage/.git/config")"
# Fuera del prefijo ya funcionaba, y tiene que seguir funcionando.
check "y fuera del prefijo, 403" "403" \
  "$(H -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/cualquiera.env")"

section "Los prefijos de subidas no se comen las rutas de la app"
# Los nombres heurísticos —uploads, upload, files, media— se emitían **existan
# o no**, y sin try_files. En una app cuyo tráfico entero pasa por un front
# controller eso cierra cinco prefijos del sitio: /media/{id} o
# /files/{uuid}/download respondían 404 de nginx sin llegar nunca a la app, y
# el síntoma no apunta a nginx por ningún lado.
check "sólo storage si no hay carpetas" "1" \
  "$(grep -c 'location \^~' "$NG/vhosts/lara.conf")"
# En tienda sí existe public/uploads, así que ahí sí se emite.
check "y uploads donde existe" "2" \
  "$(grep -c 'location \^~' "$NG/vhosts/tienda.conf")"
# El bloque devuelve el control al front controller en vez de morir en 404.
check "vuelve al front controller" "1" \
  "$(grep -c 'try_files \$uri \$uri/ /index.php?\$query_string;' \
     <<<"$(sed -n '/location \^~ \/storage\//,/^    }/p' "$NG/vhosts/lara.conf")")"
if [[ -n "$PHPFPM" ]]; then
  # La prueba de verdad: una ruta viva de la app bajo uno de esos prefijos.
  check "una ruta bajo /storage/" "la web de laravel" \
    "$(BODY -H 'Host: lara.test' "http://127.0.0.1:$HTTP_PORT/storage/informe/7")"
fi

section "Laravel se sirve como PHP, y sus subidas tampoco se ejecutan"
# 'laravel' es un tipo nuevo: si no estuviera en el case de nginx_vhost, la
# generación moriría con «Tipo de app desconocido» y no habría vhost.
check "hay vhost"          "1" "$([[ -s "$NG/vhosts/lara.conf" ]] && echo 1 || echo 0)"
check "el docroot es public" "1" \
  "$(grep -cE "^\s*root $TMP/apps/lara/current/public;" "$NG/vhosts/lara.conf")"
# El front controller: sin esto las rutas bonitas de Laravel dan 404. Va en
# 'location /' y también dentro de los bloques de subidas, que si no se comerían
# las rutas de la app; por eso se mira el de 'location /' y no el total.
check "front controller"   "1" \
  "$(grep -c 'try_files \$uri \$uri/ /index.php?\$query_string;' \
     <<<"$(sed -n '/^    location \/ {/,/^    }/p' "$NG/vhosts/lara.conf")")"
# storage:link mete una carpeta escribible por los visitantes dentro del
# docroot. Que no se ejecute no es cosa de Laravel, pero aquí es donde más se
# nota, así que se fija también para este tipo.
check "storage protegido"  "1" \
  "$(grep -c 'location \^~ /storage/' "$NG/vhosts/lara.conf")"
if [[ -n "$PHPFPM" ]]; then
  check "la app funciona"        "la web de laravel" \
    "$(BODY -H 'Host: lara.test' "http://127.0.0.1:$HTTP_PORT/")"
  check "las subidas se sirven"  "una foto de laravel" \
    "$(BODY -H 'Host: lara.test' "http://127.0.0.1:$HTTP_PORT/storage/foto.jpg")"
  check "el .php subido no corre" "404" \
    "$(H -H 'Host: lara.test' "http://127.0.0.1:$HTTP_PORT/storage/avatar.php")"
  # El .env vive un nivel por encima del docroot, y además lo deniega el snippet
  # de seguridad. Las dos defensas, porque la primera se pierde en cuanto
  # alguien apunta el docroot a la raíz del repo.
  check "el .env no se alcanza"  "0" \
    "$(BODY -H 'Host: lara.test' "http://127.0.0.1:$HTTP_PORT/.env" | grep -c 'secreta-de-laravel')"
fi

section "Laravel en una subcarpeta: el docroot baja, la superficie no sube"
# Con la app en backend/, el docroot es backend/public y todo el repositorio
# —composer.json, artisan, el .env que ahora se enlaza también dentro de la app,
# y el frontend de al lado— queda por encima de lo que sirve nginx. Eso es lo
# que hay que comprobar con peticiones de verdad y no leyendo el vhost: el modo
# de fallo de esta rama, antes de arreglarla, era servir el repositorio entero.
check "la raíz es backend/public" "1" \
  "$(grep -c "^    root $TMP/apps/monolara/current/backend/public;$" "$NG/vhosts/monolara.conf")"
if [[ -n "$PHPFPM" ]]; then
  check "la app funciona"          "la web del monorepo" \
    "$(BODY -H 'Host: monolara.test' "http://127.0.0.1:$HTTP_PORT/")"
  # Las cuatro rutas por las que se saldría el código si el docroot fuera la
  # raíz de la release. Ninguna puede devolver su contenido.
  check "el .env de la app, no"    "0" \
    "$(BODY -H 'Host: monolara.test' "http://127.0.0.1:$HTTP_PORT/backend/.env" | grep -c 'secreta-del-monorepo')"
  check "ni el de la raíz"         "0" \
    "$(BODY -H 'Host: monolara.test' "http://127.0.0.1:$HTTP_PORT/.env" | grep -c 'secreta-del-monorepo')"
  check "ni el composer.json"      "0" \
    "$(BODY -H 'Host: monolara.test' "http://127.0.0.1:$HTTP_PORT/backend/composer.json" | grep -c 'laravel/framework')"
  check "ni el código del front"   "0" \
    "$(BODY -H 'Host: monolara.test' "http://127.0.0.1:$HTTP_PORT/frontend/src/app.js" | grep -c 'clave-del-front')"
  # Y lo que sí tiene que seguir funcionando: las subidas se sirven y no se
  # ejecutan, igual que con el Laravel de la raíz.
  check "las subidas se sirven"    "una foto del monorepo" \
    "$(BODY -H 'Host: monolara.test' "http://127.0.0.1:$HTTP_PORT/storage/foto.jpg")"
  check "el .php subido no corre"  "404" \
    "$(H -H 'Host: monolara.test' "http://127.0.0.1:$HTTP_PORT/storage/avatar.php")"
fi

# Y el mismo caso sin PHP por medio: un generador estático en una subcarpeta.
check "la raíz es site/public" "1" \
  "$(grep -c "^    root $TMP/apps/monoweb/current/site/public;$" "$NG/vhosts/monoweb.conf")"
check "sirve lo compilado"     "portada compilada" \
  "$(BODY -H 'Host: monoweb.test' "http://127.0.0.1:$HTTP_PORT/")"
# Lo que está fuera de la carpeta compilada no se sirve: los borradores, la
# configuración del generador y cualquier cosa que el autor dejara al lado. Se
# mira el código y no el cuerpo: la página 404 de nginx trae un <title> dentro,
# así que buscar 'title' en el cuerpo daba verde por el motivo equivocado —y
# rojo aquí, que es como se vio—.
for ruta in /content/borrador.md /hugo.toml /config.privado; do
  check "fuera del build: $ruta" "1" \
    "$([[ "$(H -H 'Host: monoweb.test' "http://127.0.0.1:$HTTP_PORT$ruta")" != "200" ]] && echo 1 || echo 0)"
done

section "El PHP que el build no copia a dist/ se sirve igual"
# El caso de cualquier Astro o Vite con una carpeta 'api/' en la raíz: el build
# sólo copia public/ a dist/, así que api/ se queda fuera del docroot y todos
# los endpoints daban 404 con la web viéndose perfecta. Medido con un proyecto
# real, cuya propia documentación de despliegue lo llamaba «el error nº 1» y lo
# resolvía subiendo la carpeta aparte a mano.
check "hay bloque para /api/" "1" \
  "$(grep -c 'location \^~ /api/ {' "$NG/vhosts/apiweb.conf")"
# El 'root' es la raíz de la release, no el docroot: por eso /api/x.php resuelve
# a <release>/api/x.php sin tocar nada de fastcgi.
check "servido desde la release" "1" \
  "$(grep -cE "^\s*root $TMP/apps/apiweb/current;" "$NG/vhosts/apiweb.conf")"
# Lo que apunta a shared/ es dato en tiempo de ejecución, y no se sirve.
check "el dato compartido, negado" "1" \
  "$(grep -c 'location \^~ /api/undelivered { return 404; }' "$NG/vhosts/apiweb.conf")"
if [[ -n "$PHPFPM" ]]; then
  check "la portada sigue siendo dist/" "la portada compilada" \
    "$(BODY -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/")"
  check "el endpoint se ejecuta" "endpoint vivo" \
    "$(BODY -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/contact.php")"
  check "y no se sirve su fuente" "0" \
    "$(BODY -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/contact.php" | grep -c '<?php')"
  # Un fichero normal de esa carpeta sí se sirve: no es una carpeta prohibida,
  # es una carpeta que además ejecuta PHP.
  check "un fichero normal se sirve" "una hoja de estilo" \
    "$(BODY -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/no-es-codigo.txt")"
  # Y lo que vive en shared/: ni el .eml con el CV ni las estadísticas.
  check "el .eml con el CV, 404" "404" \
    "$(H -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/undelivered/2026.eml")"
  check "ni se filtra su contenido" "0" \
    "$(BODY -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/undelivered/2026.eml" | grep -c 'datos personales')"
  check "las estadísticas, 404" "404" \
    "$(H -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/stats.json")"
  # Una ruta que no existe dentro de la carpeta no se cuela al front controller.
  check "lo que no existe, 404" "404" \
    "$(H -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/no-existe.php")"
fi

section "El código de Deno y Bun no se sirve desde disco"
# En Deno y en Bun no hay carpeta compilada: la release *es* el código. Si el
# vhost tuviera un 'root', el servidor entero quedaría a la vista. La prueba no
# es que main.ts dé 404 —eso lo daría también un root mal apuntado— sino que la
# petición llegue al proceso: por eso se compara con lo que responde el backend.
check "la app va al proceso" "respuesta del backend" \
  "$(BODYS deno.test "https://deno.test:$HTTPS_PORT/")"
check "el fuente no se sirve" "0" \
  "$(BODYS deno.test "https://deno.test:$HTTPS_PORT/main.ts" | grep -c 'secreto-de-deno')"
check "ni el deno.json" "0" \
  "$(BODYS deno.test "https://deno.test:$HTTPS_PORT/deno.json" | grep -c 'deno serve')"
check "ni el .env" "0" \
  "$(BODYS deno.test "https://deno.test:$HTTPS_PORT/.env" | grep -c 'no-mirar')"
# Y ninguna raíz puede apuntar a la release, que es de donde salía todo. Los
# dos 'root' que sí quedan miran a shared/ y están dentro de bloques 'internal':
# son la página de mantenimiento, a la que no se llega desde fuera.
check "sin root a la release" "0" \
  "$(grep -cE '^[[:space:]]*root .*/current' "$NG/vhosts/denoapp.conf")"

section "PHP dentro de una web estática"
# El caso real: Astro compila a dist/ y dentro hay un contacto.php que tiene
# que ejecutarse. Sin esto, nginx sirve el fichero en vez de pasárselo a
# php-fpm, y el formulario no funciona… o peor, enseña el código.
if [[ -z "$PHPFPM" ]]; then
  echo "  (sin php-fpm instalado: me salto la ejecución real)"
else
  check "ejecuta el PHP" "hola desde php" \
    "$(BODY -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/contacto.php" | head -1)"
  check "y el método llega" "POST" \
    "$(BODY -X POST -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/contacto.php" | tail -1)"
  # Lo estático sigue sirviéndose desde disco, sin pasar por PHP.
  check "el HTML sigue igual" "portada de hibrida" \
    "$(BODY -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/")"
  # Un .php que no existe no se inventa: sin el try_files del snippet, php-fpm
  # ejecutaría lo que pillara por PATH_INFO.
  check "php inexistente es 404" "404" \
    "$(H -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/no-existe.php")"
  check "y no se ejecuta por PATH_INFO" "404" \
    "$(H -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/index.html/x.php")"
  # En mantenimiento tampoco: un formulario que sigue enviando correos
  # mientras la web dice "volvemos enseguida" es una sorpresa desagradable.
  touch "$(maint_flag hibrida)"
  check "mantenimiento también para el PHP" "503" \
    "$(H -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/contacto.php")"
  rm -f "$(maint_flag hibrida)"
fi

section "Una app PHP aislada no alcanza el .env de otra"
# La mitad del aislamiento que faltaba (§5.3), y el único sitio donde se puede
# demostrar: con un pool único, TODAS las apps PHP corren como el mismo
# usuario, así que el dueño del fichero daba igual y un file_get_contents desde
# cualquier .php se llevaba los secretos de todas las demás. Ni el usuario por
# app ni ninguna regla de nginx lo tapan: quien ejecuta el código es php-fpm.
#
# Las dos apps corren la MISMA sonda, con el mismo .env de destino. Lo único
# que cambia es el pool que la ejecuta.
if [[ -z "$PHPFPM" ]]; then
  echo "  (sin php-fpm instalado: me salto la ejecución real)"
elif [[ "$PUEDE_AISLAR" != "si" ]]; then
  # Ni root ni sudo sin contraseña: php-fpm no puede bajar de usuario, así que
  # los dos pools serían el mismo y esto no demostraría nada. Se dice y se
  # salta, que es lo honesto — 'make test-strict' se niega a dar por buena una
  # tanda con saltos, y así el verde sigue significando lo que dice.
  echo "  (hace falta root o sudo sin contraseña para dar dos pools distintos: me salto el aislamiento)"
else
  # El .env vuelve a sus permisos de producción JUSTO AQUÍ, y no donde se
  # creó: el árbol de pruebas se hace legible en bloque más arriba
  # ('chmod -R a+rX "$TMP/apps"', que php-fpm necesita para leer las webs) y
  # eso abría el fichero a todo el mundo. Con el .env legible por cualquiera
  # la comprobación de abajo pasaba... midiendo nada. Lo destapó verla en
  # rojo y bajar hasta los permisos reales, no leer el código.
  priv chown www-data:www-data "$TSHARED/.env" 2>/dev/null || true
  priv chmod 0640 "$TSHARED/.env"

  # Cada vhost habla con su propio pool. Sin esto lo de abajo no probaría
  # nada: dos sockets distintos es la premisa de todo lo demás.
  check "cada app, en su pool" "www-data" \
    "$(BODY -H 'Host: tienda.test'  "http://127.0.0.1:$HTTP_PORT/quien.php")"
  check "y la aislada, en el suyo" "nobody" \
    "$(BODY -H 'Host: aislada.test' "http://127.0.0.1:$HTTP_PORT/quien.php")"
  # EL CONTROL, y no es opcional: si la sonda estuviera rota —una ruta mal, un
  # posix_* que no existe— daría "DENEGADO" en las dos y la prueba de abajo
  # pasaría sin haber comprobado nada. Que la app dueña SÍ lo lea es lo que
  # convierte el "DENEGADO" de la otra en una afirmación.
  check "la dueña sí lee su .env" "LEIDO:APP_KEY=el-secreto-de-tienda" \
    "$(BODY -H 'Host: tienda.test' "http://127.0.0.1:$HTTP_PORT/sonda.php")"
  # Y la de al lado, no.
  check "la de al lado, no"       "DENEGADO" \
    "$(BODY -H 'Host: aislada.test' "http://127.0.0.1:$HTTP_PORT/sonda.php")"
  # Que siga siendo una web y no sólo una negativa.
  check "y sigue funcionando"     "la web aislada" \
    "$(BODY -H 'Host: aislada.test' "http://127.0.0.1:$HTTP_PORT/")"
fi

report
