#!/usr/bin/env bash
# Pruebas del vhost generado, con nginx de verdad.
#   bash tests/nginx_test.sh
#
# Levanta un nginx aislado bajo un directorio temporal (puertos 18080/18443
# por defecto; ORBIT_TEST_HTTP_PORT y ORBIT_TEST_HTTPS_PORT los cambian), así
# que no toca /etc/nginx ni el nginx del sistema. Si no hay binario de
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
HTTP_PORT="${ORBIT_TEST_HTTP_PORT:-18080}"
HTTPS_PORT="${ORBIT_TEST_HTTPS_PORT:-18443}"
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

# El de seguridad se saca de install.sh tal cual, y no una copia reducida: las
# cabeceras que repite _sec_headers tienen que ser exactamente éstas, y con una
# copia a mano la prueba compararía el vhost con algo que no existe en ningún
# servidor.
sed -n "/^cat > \/etc\/nginx\/snippets\/orbit-security.conf <<'EOF'/,/^EOF/p" \
  "$ORBIT_ROOT/install.sh" | sed '1d;$d' > "$NG/snippets/orbit-security.conf"

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
BACKPORT=$((18099 + ${ORBIT_TEST_PORT_OFFSET:-0}))
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
printf 'una hoja de estilo\n'                   > "$AREL/api/estilo.css"
printf 'unas notas\n'                           > "$AREL/api/no-es-codigo.txt"
printf '<?php echo "indice de la api\n"; ?>\n'  > "$AREL/api/index.php"
# Lo que trae una carpeta api/ de verdad además de sus endpoints, y que la
# versión anterior servía con 200 —o ejecutaba— porque dentro del prefijo sólo
# se negaban seis extensiones. Cada fichero lleva la palabra FUGA para poder
# comprobar que no sale ni su contenido.
mkdir -p "$AREL/api/vendor/phpunit/phpunit/src/Util/PHP" "$AREL/api/vendor/composer" \
         "$AREL/api/lib" "$AREL/api/_privado"
printf '<?php echo "FUGA eval-stdin\n"; ?>\n'   > "$AREL/api/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php"
printf '[{"name":"FUGA"}]\n'                     > "$AREL/api/vendor/composer/installed.json"
printf '<?php echo "FUGA lib\n"; ?>\n'          > "$AREL/api/lib/db.php"
printf '<?php echo "FUGA privado\n"; ?>\n'      > "$AREL/api/_privado/x.php"
for f in README.md composer.json composer.lock config.inc phpunit.xml.dist deploy.sh \
         backup.sql.gz db.sqlite3 env.local 'contact.php~' contact.php.save datos.json; do
  printf 'FUGA %s\n' "$f" > "$AREL/api/$f"
done
# Y dos carpetas de primer nivel con PHP que NO son endpoints. La regla de
# antes publicaba cualquier carpeta con un .php a dos niveles o menos.
mkdir -p "$AREL/scripts" "$AREL/config"
printf '<?php echo "FUGA migrate\n"; ?>\n'      > "$AREL/scripts/migrate.php"
printf '<?php return []; ?>\n'                  > "$AREL/config/app.php"
printf '{"clave":"FUGA"}\n'                      > "$AREL/config/keys.json"
# Y dentro, lo que la app escribe en tiempo de ejecución: por el modelo de §4
# eso vive en shared/, y lo que apunta a shared/ es dato, no se sirve nunca.
printf 'From: alguien\n\nCV con datos personales\n' > "$ASHARED/api/undelivered/2026.eml"
printf '{"visitas":42}\n'                          > "$ASHARED/api/stats.json"
ln -sfn "$ASHARED/api/undelivered" "$AREL/api/undelivered"
ln -sfn "$ASHARED/api/stats.json"  "$AREL/api/stats.json"
ln -sfn "$AREL" "$TMP/apps/apiweb/current"
mkapp apiweb static "" "apiweb.test"
A_TYPE="static"; A_OUTDIR="dist"; A_SPA="no"; A_PHP="yes"; save_app

# El mismo caso en un monorepo: la web vive en site/, compila a site/public, y
# lleva un contact.php suelto en site/ y su api/ al lado. La regla de antes
# veía un .php en 'site/' y publicaba '/site/' **desde la raíz de la release**:
# el código fuente entero de la web. Y su 'api/', que es site/api/, no la veía.
SREL="$TMP/apps/monophp/releases/r1"
mkdir -p "$SREL/site/public" "$SREL/site/api" "$SREL/site/src"
printf 'portada del monorepo\n'                > "$SREL/site/public/index.html"
printf '<?php echo "FUGA contact\n"; ?>\n'     > "$SREL/site/contact.php"
printf 'const SECRETO = "FUGA";\n'              > "$SREL/site/src/app.js"
printf '<?php echo "endpoint del monorepo\n"; ?>\n' > "$SREL/site/api/form.php"
ln -sfn "$SREL" "$TMP/apps/monophp/current"
mkapp monophp static "" "monophp.test"
A_TYPE="static"; A_OUTDIR="site/public"; A_APPDIR="site"; A_SPA="no"; A_PHP="yes"; save_app

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
printf 'body{}\n' > "$HREL/a.css"
# Con el docroot en la raíz del repositorio, lo que en otra web se queda fuera
# del build aquí está a una URL: las dependencias de composer —con el phpunit
# que ejecuta lo que le manden por POST—, sus .json, los .md y las piezas que
# se incluyen y no se piden.
mkdir -p "$HREL/vendor/phpunit/phpunit/src/Util/PHP" "$HREL/lib" "$HREL/assets"
printf '<?php echo "FUGA eval-stdin\n"; ?>\n' > "$HREL/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php"
printf 'FUGA vendor js\n'                      > "$HREL/vendor/x.js"
printf '<?php echo "FUGA lib\n"; ?>\n'        > "$HREL/lib/db.php"
printf '<?php echo "FUGA privado\n"; ?>\n'    > "$HREL/_conexion.php"
printf 'una librería de js\n'                  > "$HREL/assets/lib.js"
for f in README.md composer.json composer.lock config.inc 'contacto.php~' contacto.php.save backup.sql.gz; do
  printf 'FUGA %s\n' "$f" > "$HREL/$f"
done
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

# Una app PHP a secas servida desde la raíz del repositorio: la detección deja
# A_DOCROOT="." cuando no hay public/, web/ ni html/. Es la web estática con PHP
# de 'hibrida' con otro tipo, y le faltaba la misma protección: phpunit se
# ejecutaba y los composer.* salían con 200.
PLREL="$TMP/apps/plano/releases/r1"
mkdir -p "$PLREL/vendor/phpunit/phpunit/src/Util/PHP" "$PLREL/lib" "$PLREL/assets"
printf '<?php echo "portada plana\n"; ?>\n'      > "$PLREL/index.php"
printf '<?php echo "contacto plano\n"; ?>\n'     > "$PLREL/contacto.php"
printf 'body{color:blue}\n'                     > "$PLREL/assets/app.css"
printf '<?php echo "FUGA eval-stdin\n"; ?>\n'    > "$PLREL/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php"
printf '<?php echo "FUGA lib\n"; ?>\n'           > "$PLREL/lib/db.php"
printf '<?php echo "FUGA privado\n"; ?>\n'       > "$PLREL/_conexion.php"
for f in README.md composer.json composer.lock config.inc 'contacto.php~' contacto.php.save backup.sql.gz datos.sqlite3; do
  printf 'FUGA %s\n' "$f" > "$PLREL/$f"
done
ln -sfn "$PLREL" "$TMP/apps/plano/current"
mkapp plano php "" "plano.test"
A_TYPE="php"; A_DOCROOT="."; save_app
# Y en un monorepo: la app en web/, sin public/ dentro. La detección deja el
# docroot en la raíz de la app, que es web/, y las URL parten de ahí.
MPREL="$TMP/apps/monoplano/releases/r1"
mkdir -p "$MPREL/web/vendor/composer"
printf '<?php echo "portada monoplano\n"; ?>\n'  > "$MPREL/web/index.php"
printf '[{"name":"FUGA"}]\n'                     > "$MPREL/web/vendor/composer/installed.json"
printf '{"require":{"FUGA":"1"}}\n'              > "$MPREL/web/composer.json"
ln -sfn "$MPREL" "$TMP/apps/monoplano/current"
mkapp monoplano php "" "monoplano.test"
A_TYPE="php"; A_DOCROOT="web"; A_APPDIR="web"; save_app

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
  chmod -R a+rX "$TMP/apps/hibrida" "$TMP/apps/plano" "$TMP/apps/monoplano" "$TMP/apps/tienda" "$TMP/apps/monolara" "$TMP/apps/apiweb" "$TMP/apps/monophp" 2>/dev/null || true
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

# --- la release anterior sigue contestando por sus recursos -----------------
# Un visitante cargó el HTML de la release A; se despliega la B. Su navegador
# sigue pidiendo los chunks con hash de A, y en B no existen. Lo que se fija
# aquí es que los recursos caen a A —y SÓLO los recursos—: una ruta nunca sale
# de la anterior, ni nada que la activa niegue, ni PHP. La web va en una
# subcarpeta del monorepo para que la ruta de la anterior se componga igual
# que la de la activa.
SKA="$TMP/apps/skew/releases/A"; SKB="$TMP/apps/skew/releases/B"
mkdir -p "$SKA/site/dist/_astro" "$SKB/site/dist/_astro" "$SKA/site/dist/vieja"
printf 'portada A\n'                 > "$SKA/site/dist/index.html"
printf 'portada B\n'                 > "$SKB/site/dist/index.html"
printf 'B no existe\n'               > "$SKB/site/dist/404.html"
printf 'chunk de A\n'                > "$SKA/site/dist/_astro/a.Ab12Cd34.js"
printf 'chunk de B\n'                > "$SKB/site/dist/_astro/b.Cd34.js"
printf 'estilo de A\n'               > "$SKA/site/dist/_astro/comun.css"
printf 'estilo de B\n'               > "$SKB/site/dist/_astro/comun.css"
# Lo que sólo existe en A y no puede salir por ningún lado: una página (que
# para la activa no existe), un .env, un fichero oculto con extensión de
# recurso, un .php con el fuente, y un service worker viejo.
printf 'pagina vieja de A\n'         > "$SKA/site/dist/vieja/index.html"
printf 'pagina vieja de A\n'         > "$SKA/site/dist/suelta.html"
printf 'SECRETO=FUGA\n'              > "$SKA/site/dist/.env"
printf 'FUGA oculto\n'               > "$SKA/site/dist/.oculto.js"
printf '<?php echo "FUGA"; ?>\n'     > "$SKA/site/dist/viejo.php"
printf 'FUGA sw viejo\n'             > "$SKA/site/dist/sw.js"
ln -sfn "$SKB" "$TMP/apps/skew/current"
ln -sfn "$SKA" "$TMP/apps/skew/previous"
mkapp skew static "" "skew.test"
A_TYPE="static"; A_OUTDIR="site/dist"; A_APPDIR="site"; A_SPA="no"; save_app

# La misma situación en una SPA, que es la que más chunks carga a demanda. Sin
# 404.html, para fijar de paso que un .js que falta no recibe el index.html.
SPA_A="$TMP/apps/spaskew/releases/A"; SPA_B="$TMP/apps/spaskew/releases/B"
mkdir -p "$SPA_A/dist/assets" "$SPA_B/dist/assets"
printf 'shell A\n'                   > "$SPA_A/dist/index.html"
printf 'shell B\n'                   > "$SPA_B/dist/index.html"
printf 'lazy de A\n'                 > "$SPA_A/dist/assets/ruta-x9.js"
ln -sfn "$SPA_B" "$TMP/apps/spaskew/current"
ln -sfn "$SPA_A" "$TMP/apps/spaskew/previous"
mkapp spaskew static "" "spaskew.test"
A_TYPE="static"; A_OUTDIR="dist"; A_SPA="yes"; save_app

# Next sirve sus chunks desde disco por un alias, y ahí la anterior tiene que
# entrar sin 'alias' —una named location no lo admite—. En un monorepo, para
# que la ruta lleve A_APPDIR.
NXA="$TMP/apps/nextapp/releases/A"; NXB="$TMP/apps/nextapp/releases/B"
mkdir -p "$NXA/apps/web/.next/static/chunks" "$NXB/apps/web/.next/static/chunks"
printf 'next chunk A\n'              > "$NXA/apps/web/.next/static/chunks/a1.js"
printf 'next chunk B\n'              > "$NXB/apps/web/.next/static/chunks/b2.js"
printf 'FUGA\n'                      > "$NXA/apps/web/.next/static/chunks/.oculto.js"
ln -sfn "$NXB" "$TMP/apps/nextapp/current"
ln -sfn "$NXA" "$TMP/apps/nextapp/previous"
mkapp nextapp next "$BACKPORT" "nextapp.test"
A_TYPE="next"; A_APPDIR="apps/web"; save_app

# Django con ManifestStaticFilesStorage: los nombres llevan hash, igual que un
# bundle. La anterior de pyapp trae una hoja que la activa ya no tiene.
PYOLD="$TMP/apps/pyapp/releases/r0"
mkdir -p "$PYOLD/staticfiles/css"
printf 'hoja de la anterior\n'       > "$PYOLD/staticfiles/css/app.4f2e.css"
ln -sfn "$PYOLD" "$TMP/apps/pyapp/previous"

# Y las webs con PHP: la anterior de apiweb tiene un recurso dentro de api/ —
# un prefijo '^~', que ya no mira la anterior— y uno de verdad en dist/; la de
# hibrida, un .php y un vendor/ que la activa no tiene.
AOLD="$TMP/apps/apiweb/releases/r0"
mkdir -p "$AOLD/dist/_astro" "$AOLD/api"
printf 'recurso de la anterior\n'    > "$AOLD/dist/_astro/v.js"
printf 'FUGA api vieja\n'            > "$AOLD/api/viejo.js"
ln -sfn "$AOLD" "$TMP/apps/apiweb/previous"
HOLD="$TMP/apps/hibrida/releases/r0"
mkdir -p "$HOLD/vendor"
printf '<?php echo "EJECUTADO de la anterior\n"; ?>\n' > "$HOLD/viejo.php"
printf 'FUGA vendor viejo\n'         > "$HOLD/vendor/viejo.js"
ln -sfn "$HOLD" "$TMP/apps/hibrida/previous"

# Una app con proceso que no contesta: nada escucha en el puerto 1. Una con su
# página de error y otra sin ella, que tiene que dar el mismo código.
mkapp caida node 1 "caida.test"
_errpage_ensure caida
mkapp caidasin node 1 "caidasin.test"

# Las apps con proceso que sirven sus propios recursos (§4.1). Nuxt, en un
# monorepo para que la carpeta lleve A_APPDIR delante, con el proceso de
# verdad detrás: el backend de python, que sirve $TMP/back. Lo que sólo tiene
# el proceso es lo que demuestra que un recurso que no está en disco le llega
# **con su URI**: si nginx la reescribiera, el backend no lo encontraría.
PNA="$TMP/apps/procnuxt/releases/A"; PNB="$TMP/apps/procnuxt/releases/B"
PNP="apps/web/.output/public"
mkdir -p "$PNA/$PNP/_nuxt/builds" "$PNB/$PNP/_nuxt/builds" "$TMP/back/_nuxt/builds"
printf 'nuxt chunk A\n'              > "$PNA/$PNP/_nuxt/a1.js"
printf 'nuxt chunk B\n'              > "$PNB/$PNP/_nuxt/b2.js"
printf 'estilo A\n'                  > "$PNA/$PNP/_nuxt/comun.css"
printf 'estilo B\n'                  > "$PNB/$PNP/_nuxt/comun.css"
printf 'latest del disco\n'          > "$PNA/$PNP/_nuxt/builds/latest.json"
printf 'latest del disco\n'          > "$PNB/$PNP/_nuxt/builds/latest.json"
# Lo que está en la anterior y no puede salir: ocultos, secretos, una página.
printf 'FUGA oculto\n'               > "$PNA/$PNP/_nuxt/.oculto.js"
printf 'SECRETO=FUGA\n'              > "$PNA/$PNP/_nuxt/viejo.env"
printf 'pagina vieja FUGA\n'         > "$PNA/$PNP/vieja.html"
printf 'del proceso\n'               > "$TMP/back/_nuxt/solo-app.js"
printf 'latest del proceso\n'        > "$TMP/back/_nuxt/builds/latest.json"
# Un enlace que el build deja en su salida hacia lo que no es de la app: nginx
# lo seguía y servía como www-data lo que hubiera al otro lado —los logs de
# las otras apps, que son de www-data—. El dueño del destino tiene que ser
# otro que el del enlace, que es lo que mira 'if_not_owner': como root, un
# fichero de nobody; sin root, uno del sistema, que es de root.
FUGA_T="$TMP/fuera/secreto.txt"; mkdir -p "$TMP/fuera"; printf 'FUGA por enlace\n' > "$FUGA_T"
if [[ $EUID -eq 0 ]]; then chown 65534 "$TMP/fuera" "$FUGA_T"; else FUGA_T="/etc/hostname"; fi
ln -s "$FUGA_T" "$PNB/$PNP/_nuxt/enlace.js"
ln -s "$FUGA_T" "$PNA/$PNP/_nuxt/enlace-viejo.js"
ln -s "$(dirname "$FUGA_T")" "$PNB/$PNP/_nuxt/carpeta"
# Y el que la app hace hacia lo suyo, que sigue valiendo.
ln -s b2.js "$PNB/$PNP/_nuxt/propio.js"
ln -sfn "$PNB" "$TMP/apps/procnuxt/current"
ln -sfn "$PNA" "$TMP/apps/procnuxt/previous"
mkapp procnuxt node "$BACKPORT" "procnuxt.test"
A_APPDIR="apps/web"; A_ASSETS="/_nuxt/:$PNP !/_nuxt/builds/"; save_app
# Qwik, con dos prefijos y el proceso caído: nadie escucha en el puerto 1.
PQA="$TMP/apps/procqwik/releases/A"; PQB="$TMP/apps/procqwik/releases/B"
mkdir -p "$PQA/dist/build" "$PQA/dist/assets" "$PQB/dist/build" "$PQB/dist/assets"
printf 'qwik A\n'                    > "$PQA/dist/build/q-a.js"
printf 'qwik B\n'                    > "$PQB/dist/build/q-b.js"
printf 'grafo A\n'                   > "$PQA/dist/assets/g-a.json"
ln -sfn "$PQB" "$TMP/apps/procqwik/current"
ln -sfn "$PQA" "$TMP/apps/procqwik/previous"
mkapp procqwik node 1 "procqwik.test"
A_ASSETS='/build/:dist /assets/:dist'; save_app
for app in procnuxt procqwik; do install_vhost "$app"; done

# Web estática de las que dejan Astro con format "file" (es.html + es/), Vite…
# Cubre la barra final, el markdown, la caché por nombre con hash y la CSP que
# declara el orbit.json. Los ficheros de nombre «sin hash» son los que cambian
# de contenido entre releases sin cambiar de nombre.
PTR="$TMP/apps/astro/releases/r1"
mkdir -p "$PTR/es" "$PTR/dir" "$PTR/_astro" "$PTR/fonts" "$PTR/pagefind"
printf 'portada astro\n'      > "$PTR/index.html"
printf 'astro no existe\n'    > "$PTR/404.html"
printf 'pagina es\n'          > "$PTR/es.html"
printf 'otra de es\n'         > "$PTR/es/other.html"
printf 'pagina de dir\n'      > "$PTR/dir/index.html"
printf '# hola\n'             > "$PTR/x.md"
printf 'body{}\n'             > "$PTR/_astro/Base.jLhV-p7P.css"
printf 'x\n'                  > "$PTR/_astro/Base.astro_astro_type_script_index_0_lang.BT5XGmD_.js"
printf 'x\n'                  > "$PTR/_astro/index-BqX9fK2a.js"
printf 'x\n'                  > "$PTR/fonts/Outfit-latin-variable.woff2"
printf 'x\n'                  > "$PTR/pagefind/pagefind.js"
printf '<svg/>\n'             > "$PTR/favicon.svg"
printf '%s\n' "{\"type\":\"static\",\"csp\":\"default-src 'self'; img-src 'self' data:\"}" > "$PTR/orbit.json"
ln -sfn "$PTR" "$TMP/apps/astro/current"
mkapp astro static "" "astro.test"
A_OUTDIR="."; A_SPA="no"; A_PHP=""; save_app
issue_cert astro.test

# El mismo sitio con la CSP en modo informe, y con una CSP que no vale.
for extra in cspro cspmal; do
  mkdir -p "$TMP/apps/$extra/releases/r1"
  printf 'portada\n' > "$TMP/apps/$extra/releases/r1/index.html"
  printf 'body{}\n'  > "$TMP/apps/$extra/releases/r1/a.css"
  ln -sfn "$TMP/apps/$extra/releases/r1" "$TMP/apps/$extra/current"
  mkapp "$extra" static "" "$extra.test"; A_OUTDIR="."; A_SPA="no"; A_PHP=""; save_app
done
printf '%s\n' '{"type":"static","csp":"default-src '"'"'none'"'"'","csp_report_only":true}' \
  > "$TMP/apps/cspro/releases/r1/orbit.json"
printf '%s\n' '{"type":"static","csp":"default-src \"self\""}' > "$TMP/apps/cspmal/releases/r1/orbit.json"

for app in sincert concert spa proxyapp pyapp hibrida plano monoplano tienda aislada denoapp lara monolara monoweb apiweb monophp \
           skew spaskew nextapp caida caidasin astro cspro; do install_vhost "$app"; done

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
# shellcheck disable=SC2218  # es el nginx de verdad; el doble se define más abajo, a propósito
command nginx -c "$NG/nginx.conf" -p "$NG" 2>>"$NG/logs/error.log"
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
# shellcheck disable=SC2218  # es el nginx de verdad; el doble se define más abajo, a propósito
command nginx -t >/dev/null 2>&1   # el resto del diagnóstico no importa aquí
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
  # Un estático de esa carpeta sí se sirve: una imagen o una hoja de estilo del
  # formulario. Lo demás ya no —ver abajo—, y eso incluye un .txt: en una
  # carpeta de código fuente, un .txt es un requirements.txt o unas notas.
  check "un estático se sirve" "una hoja de estilo" \
    "$(BODY -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/estilo.css")"
  check "un .txt, ya no" "404" \
    "$(H -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/no-es-codigo.txt")"
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

section "Dentro de una carpeta PHP de fuera, todo está prohibido salvo lo que se nombra"
# Antes, dentro de 'location ^~ /api/' sólo se negaban seis extensiones, y el
# '^~' apagaba además el snippet de seguridad entero. Todo esto salía con 200:
# lo medido en una carpeta api/ real. Se mira el código y que no salga el
# contenido, porque un 404 con cuerpo de otro sitio también sería un fallo.
if [[ -n "$PHPFPM" ]]; then
  for ruta in /api/_lib.php /api/_privado/x.php /api/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php \
              /api/vendor/composer/installed.json /api/lib/db.php /api/README.md /api/composer.json \
              /api/composer.lock /api/config.inc /api/phpunit.xml.dist /api/deploy.sh /api/backup.sql.gz \
              /api/db.sqlite3 /api/env.local '/api/contact.php~' /api/contact.php.save /api/datos.json; do
    check "api: $ruta" "404 0" \
      "$(H -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT$ruta") $(BODY -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT$ruta" | grep -c 'FUGA\|no soy un endpoint')"
  done
  # El POST es la forma en que se explota el eval-stdin de phpunit.
  check "api: eval-stdin por POST" "404" \
    "$(H -X POST --data '<?php echo 1;' -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php")"
  # Lo que sí tiene que seguir: el índice de la carpeta, por su index.php.
  check "api: /api/ va a su index.php" "indice de la api" \
    "$(BODY -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/")"
  # Y el mantenimiento: un 'if' en la location de fuera no corre cuando la
  # petición acaba en una de dentro. Con la web en 503, el formulario seguía
  # procesándose — la sorpresa de las dos de la mañana que el guard de la
  # location principal ya evitaba.
  printf 'volvemos enseguida\n' > "$(maint_page apiweb)"; chmod a+r "$(maint_page apiweb)"
  touch "$(maint_flag apiweb)"
  check "api: mantenimiento también aquí" "503" \
    "$(H -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT/api/contact.php")"
  rm -f "$(maint_flag apiweb)"
fi

section "Sólo se publican las carpetas PHP que se piden"
# La regla de antes publicaba cualquier carpeta de primer nivel con un .php a
# dos niveles o menos: '/scripts/migrate.php' se ejecutaba y '/config/' servía
# sus .json.
check "scripts/ no tiene bloque" "0" "$(grep -c 'location \^~ /scripts/' "$NG/vhosts/apiweb.conf")"
check "config/ no tiene bloque"  "0" "$(grep -c 'location \^~ /config/' "$NG/vhosts/apiweb.conf")"
for ruta in /scripts/migrate.php /config/keys.json /config/app.php; do
  check "fuera: $ruta" "1" \
    "$([[ "$(H -H 'Host: apiweb.test' "http://127.0.0.1:$HTTP_PORT$ruta")" != "200" ]] && echo 1 || echo 0)"
done
# En el monorepo: '/site/' era el código fuente entero de la web.
check "monorepo: sin /site/"      "0" "$(grep -c 'location \^~ /site/' "$NG/vhosts/monophp.conf")"
check "monorepo: api desde site/" "1" \
  "$(grep -cE "^\s*root $TMP/apps/monophp/current/site;" "$NG/vhosts/monophp.conf")"
check "monorepo: portada"         "portada del monorepo" \
  "$(BODY -H 'Host: monophp.test' "http://127.0.0.1:$HTTP_PORT/")"
for ruta in /site/contact.php /site/src/app.js; do
  check "monorepo: $ruta" "0" \
    "$(BODY -H 'Host: monophp.test' "http://127.0.0.1:$HTTP_PORT$ruta" | grep -c FUGA)"
done
if [[ -n "$PHPFPM" ]]; then
  check "monorepo: su api/ funciona" "endpoint del monorepo" \
    "$(BODY -H 'Host: monophp.test' "http://127.0.0.1:$HTTP_PORT/api/form.php")"
fi
# Otra carpeta, sólo si el repositorio la declara en su orbit.json.
mkdir -p "$AREL/formularios"
printf '<?php echo "formulario declarado\n"; ?>\n' > "$AREL/formularios/alta.php"
printf '{"type":"static","php_dirs":["formularios","../fuera","a/b","*"]}\n' > "$AREL/orbit.json"
load_app apiweb
OUTSIDE="$(_php_outside_dirs "$(app_current apiweb)" | tr '\n' ' ')"
if command -v jq >/dev/null; then
  check "php_dirs declarado"           "api formularios " "$OUTSIDE"
else
  # Sin jq no se puede leer la lista: se queda en lo de por defecto, que es lo
  # seguro, y no en lo declarado.
  check "php_dirs sin jq, sólo api"    "api " "$OUTSIDE"
fi
rm -f "$AREL/orbit.json"

section "Un nombre que ya protege otro bloque no se publica dos veces"
# Dos 'location ^~' con el mismo prefijo son un vhost que nginx rechaza. Pasaba
# con una web estática cuyo 'storage/' —que _php_writable_denies protege
# siempre— llevaba un .php dentro, y con un 'uploads/' en dist/ y en la raíz.
# Se valida aparte, con su propio nginx -t: dentro de la tanda grande, un vhost
# roto tumbaría todas las comprobaciones de detrás y no diría cuál.
DREL2="$TMP/apps/dupweb/releases/r1"
mkdir -p "$DREL2/dist/uploads" "$DREL2/storage" "$DREL2/uploads" "$DREL2/api"
printf 'portada\n'           > "$DREL2/dist/index.html"
printf '<?php echo 1; ?>\n'  > "$DREL2/storage/x.php"
printf '<?php echo 1; ?>\n'  > "$DREL2/uploads/x.php"
printf '<?php echo 1; ?>\n'  > "$DREL2/api/x.php"
printf '{"type":"static","php_dirs":["storage","uploads","api"]}\n' > "$DREL2/orbit.json"
ln -sfn "$DREL2" "$TMP/apps/dupweb/current"
mkapp dupweb static "" "dupweb.test"
A_TYPE="static"; A_OUTDIR="dist"; A_SPA="no"; A_PHP="yes"; save_app
mkdir -p "$NG/aparte"
nginx_vhost dupweb | sed -e "s#/etc/nginx/snippets/#$NG/snippets/#g" -e "s#/var/log/nginx/#$NG/logs/#g" \
  -e "s#/run/php/orbit.sock#$NG/php.sock#g" -e "s/^\( *\)listen 80;/\1listen 127.0.0.1:$HTTP_PORT;/" \
  -e "/listen \[::\]/d" > "$NG/aparte/dupweb.conf"
sed "s#include $NG/vhosts/\*.conf;#include $NG/aparte/*.conf;#" "$NG/nginx.conf" > "$NG/aparte.conf"
nginx -t -c "$NG/aparte.conf" -p "$NG" >"$NG/logs/aparte.out" 2>&1 && r=ok || r=error
[[ "$r" == ok ]] || sed 's/^/      /' "$NG/logs/aparte.out"
check "sin prefijos repetidos: nginx -t" "ok" "$r"
check "un solo /storage/" "1" "$(grep -c 'location \^~ /storage/' "$NG/aparte/dupweb.conf")"
check "un solo /uploads/" "1" "$(grep -c 'location \^~ /uploads/' "$NG/aparte/dupweb.conf")"

# Y el mismo choque por otro lado: una app PHP servida desde la raíz que
# declara "shared": ["vendor"] —para que composer no reinstale en cada
# despliegue— dejaba vendor/ como enlace a shared/. _php_writable_denies lo
# protegía como carpeta de escritura y _php_root_denies lo negaba entero: dos
# 'location ^~ /vendor/', 'nginx -t' en rojo y la app sin poder desplegarse.
VREL="$TMP/apps/shvendor/releases/r1"
mkdir -p "$VREL" "$TMP/apps/shvendor/shared/vendor/composer" "$TMP/apps/shvendor/shared/node_modules"
printf '<?php echo 1; ?>\n' > "$VREL/index.php"
ln -sfn "$TMP/apps/shvendor/shared/vendor" "$VREL/vendor"
ln -sfn "$TMP/apps/shvendor/shared/node_modules" "$VREL/node_modules"
ln -sfn "$VREL" "$TMP/apps/shvendor/current"
mkapp shvendor php "" "shvendor.test"
A_TYPE="php"; A_DOCROOT="."; A_SHARED="vendor node_modules"; save_app
rm -f "$NG/aparte/"*.conf
nginx_vhost shvendor | sed -e "s#/etc/nginx/snippets/#$NG/snippets/#g" -e "s#/var/log/nginx/#$NG/logs/#g" \
  -e "s#/run/php/orbit.sock#$NG/php.sock#g" -e "s#unix:[^;]*\.sock#unix:$NG/php.sock#g" \
  -e "s/^\( *\)listen 80;/\1listen 127.0.0.1:$HTTP_PORT;/" -e "/listen \[::\]/d" > "$NG/aparte/shvendor.conf"
nginx -t -c "$NG/aparte.conf" -p "$NG" >"$NG/logs/aparte2.out" 2>&1 && r=ok || r=error
[[ "$r" == ok ]] || sed 's/^/      /' "$NG/logs/aparte2.out"
check "shared vendor: nginx -t"  "ok" "$r"
check "un solo /vendor/"         "1"  "$(grep -c 'location \^~ /vendor/' "$NG/aparte/shvendor.conf")"
check "y es el que lo niega todo" "1" "$(grep -c 'location \^~ /vendor/ *{ return 404; }' "$NG/aparte/shvendor.conf")"
check "un solo /node_modules/"   "1"  "$(grep -c 'location \^~ /node_modules/' "$NG/aparte/shvendor.conf")"

section "Una web estática servida desde la raíz del repositorio"
# hibrida: A_OUTDIR=".", así que el docroot ES el repositorio.
if [[ -n "$PHPFPM" ]]; then
  for ruta in /vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php /vendor/x.js /lib/db.php /_conexion.php \
              /README.md /composer.json /composer.lock /config.inc '/contacto.php~' /contacto.php.save /backup.sql.gz; do
    check "raíz: $ruta" "404 0" \
      "$(H -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT$ruta") $(BODY -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT$ruta" | grep -c 'FUGA')"
  done
  # Y lo que es de la web sigue en pie: no se le puede quitar a una web estática
  # su carpeta de JavaScript por llamarse 'lib' en otro sitio.
  check "raíz: el .php de la web, sí" "hola desde php" \
    "$(BODY -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/contacto.php" | head -1)"
  check "raíz: sus estáticos, sí" "una librería de js" \
    "$(BODY -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/assets/lib.js")"
fi

section "Una app PHP servida desde la raíz del repositorio"
# plano: A_TYPE=php y A_DOCROOT=".". Antes del arreglo, las once rutas de abajo
# salían con 200 —eval-stdin.php y lib/db.php, ejecutados—.
check "el vhost lo niega"  "1" "$(grep -c 'location \^~ /vendor/' "$NG/vhosts/plano.conf")"
check "en un monorepo también" "1" "$(grep -c 'location \^~ /vendor/' "$NG/vhosts/monoplano.conf")"
# Y un docroot que no es la raíz de la app no lo necesita: lo de fuera ya no
# está a una URL, y negar /lib/*.php ahí podría quitarle páginas a la app.
check "con public/, no hace falta" "0" "$(grep -c 'location \^~ /vendor/' "$NG/vhosts/tienda.conf")"
check "ni en Laravel"      "0" "$(grep -c 'location \^~ /vendor/' "$NG/vhosts/lara.conf")"
if [[ -n "$PHPFPM" ]]; then
  for ruta in /vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php /lib/db.php /_conexion.php \
              /README.md /composer.json /composer.lock /config.inc '/contacto.php~' /contacto.php.save \
              /backup.sql.gz /datos.sqlite3; do
    check "php en la raíz: $ruta" "404 0" \
      "$(H -H 'Host: plano.test' "http://127.0.0.1:$HTTP_PORT$ruta") $(BODY -H 'Host: plano.test' "http://127.0.0.1:$HTTP_PORT$ruta" | grep -c 'FUGA')"
  done
  check "la portada, sí"      "portada plana"  "$(BODY -H 'Host: plano.test' "http://127.0.0.1:$HTTP_PORT/")"
  check "sus páginas, sí"     "contacto plano" "$(BODY -H 'Host: plano.test' "http://127.0.0.1:$HTTP_PORT/contacto.php")"
  check "sus estáticos, sí"   "body{color:blue}" "$(BODY -H 'Host: plano.test' "http://127.0.0.1:$HTTP_PORT/assets/app.css")"
  check "una ruta bonita va al front controller" "portada plana" \
    "$(BODY -H 'Host: plano.test' "http://127.0.0.1:$HTTP_PORT/blog/hola")"
  for ruta in /vendor/composer/installed.json /composer.json; do
    check "monorepo: $ruta" "404 0" \
      "$(H -H 'Host: monoplano.test' "http://127.0.0.1:$HTTP_PORT$ruta") $(BODY -H 'Host: monoplano.test' "http://127.0.0.1:$HTTP_PORT$ruta" | grep -c 'FUGA')"
  done
  check "monorepo: la portada, sí" "portada monoplano" "$(BODY -H 'Host: monoplano.test' "http://127.0.0.1:$HTTP_PORT/")"
fi

section "Las cabeceras de seguridad, también en los estáticos"
# Un 'add_header' en una location anula todos los heredados. El Cache-Control
# de los estáticos se llevaba por delante nosniff, X-Frame-Options y el HSTS:
# medido, '/' con las tres y '/a.css' con ninguna.
CAB='^(x-content-type-options|x-frame-options|referrer-policy|permissions-policy|cross-origin-opener-policy|strict-transport-security):'
cabeceras() { curl -skI --noproxy '*' -m 5 "$@" | tr -d '\r' | grep -iE "$CAB" | cut -d: -f1 | tr 'A-Z' 'a-z' | sort | tr '\n' ' '; }
printf 'body{}\n' > "$TMP/apps/concert/releases/r1/a.css"
printf 'body{}\n' > "$TMP/apps/sincert/releases/r1/a.css"
chmod a+r "$TMP/apps/concert/releases/r1/a.css" "$TMP/apps/sincert/releases/r1/a.css"
RAIZ443="$(cabeceras --resolve "concert.test:$HTTPS_PORT:127.0.0.1" "https://concert.test:$HTTPS_PORT/")"
check "443: '/' trae las seis"      "6" "$(wc -w <<<"$RAIZ443" | tr -d ' ')"
check "443: el .css, las mismas"    "$RAIZ443" \
  "$(cabeceras --resolve "concert.test:$HTTPS_PORT:127.0.0.1" "https://concert.test:$HTTPS_PORT/a.css")"
check "443: y su Cache-Control"     "1" \
  "$(curl -skI --noproxy '*' -m 5 --resolve "concert.test:$HTTPS_PORT:127.0.0.1" "https://concert.test:$HTTPS_PORT/a.css" | grep -ci '^cache-control: public, max-age=86400')"
# Por el 80, '/' no lleva HSTS y el estático tampoco puede llevarlo: el cuerpo
# del vhost es el mismo en los dos server, y lo que cambia es la variable.
RAIZ80="$(cabeceras -H 'Host: sincert.test' "http://127.0.0.1:$HTTP_PORT/")"
check "80: '/' sin HSTS"            "0" "$(grep -c strict <<<"$RAIZ80")"
check "80: el .css, las mismas"     "$RAIZ80" "$(cabeceras -H 'Host: sincert.test' "http://127.0.0.1:$HTTP_PORT/a.css")"
check "80 con XFP: el .css igual que '/'" \
  "$(cabeceras -H 'Host: concert.test' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$HTTP_PORT/")" \
  "$(cabeceras -H 'Host: concert.test' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$HTTP_PORT/a.css")"
if [[ -n "$PHPFPM" ]]; then
  check "php: el .css, las mismas que '/'" \
    "$(cabeceras -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/")" \
    "$(cabeceras -H 'Host: hibrida.test' "http://127.0.0.1:$HTTP_PORT/a.css")"
fi
# La lista de _sec_headers es una copia de la de install.sh (no se puede
# incluir el snippet: trae 'location'). Si una cambia y la otra no, aquí.
check "misma lista que install.sh" \
  "$(grep -oE '^add_header +[A-Za-z-]+ +"[^"]*"' "$NG/snippets/orbit-security.conf" | sed -E 's/ +/ /g' | sort | tr '\n' '|')" \
  "$(_sec_headers | grep -v Strict-Transport | grep -oE 'add_header +[A-Za-z-]+ +"[^"]*"' | sed -E 's/ +/ /g' | sort | tr '\n' '|')"

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

section "Rutas con barra final, markdown, caché por hash y CSP"
SKU="http://127.0.0.1:$HTTP_PORT"
# X-Forwarded-Proto: la web tiene certificado y el 80 redirige; así se llega al cuerpo.
AS=(-H 'Host: astro.test' -H 'X-Forwarded-Proto: https')
loc() { curl -s --noproxy '*' -o /dev/null -w '%{http_code} %{redirect_url}' -m 5 "$@" | sed 's/ $//'; }
hdr() { curl -sI --noproxy '*' -m 5 "$@" | tr -d '\r'; }
# El 403 de nginx: el directorio es/ existe sin index.html y '$uri/' lo listaba.
check "es/ -> 301 a /es"            "301 /es"   "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code} %header{location}' -m 5 "${AS[@]}" "$SKU/es/")"
check "es/ con query la conserva"   "/es?a=1&b=2" "$(curl -s --noproxy '*' -o /dev/null -w '%header{location}' -m 5 "${AS[@]}" "$SKU/es/?a=1&b=2")"
check "es -> 200"                   "200"       "$(H "${AS[@]}" "$SKU/es")"
check "es -> su página"             "pagina es" "$(BODY "${AS[@]}" "$SKU/es")"
check "es/other -> 200"             "200"       "$(H "${AS[@]}" "$SKU/es/other")"
check "dir/ sirve su index"         "200 pagina de dir" "$(H "${AS[@]}" "$SKU/dir/") $(BODY "${AS[@]}" "$SKU/dir/")"
check "dir sin barra, también"      "200"       "$(H "${AS[@]}" "$SKU/dir")"
# Un 404 de verdad con barra final da un salto a la ruta sin barra, y ahí sale su página.
check "nope/ -> 301 a /nope"        "301 /nope" "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code} %header{location}' -m 5 "${AS[@]}" "$SKU/nope/")"
check "nope/ -> 404 con su página"  "404 astro no existe" "$(H -L "${AS[@]}" "$SKU/nope/") $(BODY -L "${AS[@]}" "$SKU/nope/")"
check "nope -> 404"                 "404"       "$(H "${AS[@]}" "$SKU/nope")"
check "la raiz no redirige"         "200"       "$(H "${AS[@]}" "$SKU/")"
check "ruta con espacio y barra"    "301 /a%20b" "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code} %header{location}' -m 5 "${AS[@]}" "$SKU/a%20b/")"
# Redirección abierta: '/\evil.com/' saldría como 'Location: /\evil.com', que un
# navegador lee como '//evil.com'. Ninguna variante puede dar un Location que
# empiece por '//' ni por '/\'; esas peticiones son un 404 de verdad.
for ruta in '/%5Cevil.com/' '/%5cevil.com/' '//evil.com/' '/%2F%2Fevil.com/' '/%2f/evil.com/' '/%5C%5Cevil.com/' '/\evil.com/' '/%5Cevil.com/x/'; do
  LOCH="$(curl -s --globoff --noproxy '*' -o /dev/null -w '%{http_code} %header{location}' -m 5 "${AS[@]}" "$SKU$ruta")"
  case "$LOCH" in
    *' //'*|*' /\\'*|*' /\'*) r="ABIERTA: $LOCH" ;;
    *) r="cerrada" ;;
  esac
  check "sin redirección abierta: $ruta" "cerrada" "$r"
done
check "'/%5Cevil.com/' es un 404"   "404" "$(H "${AS[@]}" "$SKU/%5Cevil.com/")"
# Cualquier ruta que empiece por «/\» o «//» es un 404, a cualquier profundidad.
check "'/%5Cevil.com/x/' tampoco"   "404" "$(H "${AS[@]}" "$SKU/%5Cevil.com/x/")"
# Una SPA no redirige nada: un directorio sin index cae en el shell, nunca 403.
mkdir -p "$TMP/apps/spa/releases/r1/carpeta"; printf 'x\n' > "$TMP/apps/spa/releases/r1/carpeta/otra.html"
chmod -R a+rX "$TMP/apps/spa"
SPAH=(-H 'Host: spa.test' -H 'X-Forwarded-Proto: https')
check "spa: dir sin index, shell"   "200 aplicacion de una pagina" \
  "$(H "${SPAH[@]}" "$SKU/carpeta/") $(BODY "${SPAH[@]}" "$SKU/carpeta/")"
# Markdown: se muestra, no se descarga.
MDH="$(hdr "${AS[@]}" "$SKU/x.md")"
check "md: tipo"                    "content-type: text/markdown; charset=utf-8" "$(grep -i '^content-type:' <<<"$MDH" | tr 'A-Z' 'a-z')"
check "md: nosniff"                 "1" "$(grep -ci '^x-content-type-options: nosniff' <<<"$MDH")"
check "md: un .md que falta"        "404" "$(H "${AS[@]}" "$SKU/falta.md")"
# Caché: con hash, inmutable; sin hash, un día; HTML, no-cache.
for f in /_astro/Base.jLhV-p7P.css /_astro/Base.astro_astro_type_script_index_0_lang.BT5XGmD_.js /_astro/index-BqX9fK2a.js; do
  check "hash: $f" "1 1" \
    "$(hdr "${AS[@]}" "$SKU$f" | grep -ci '^cache-control: public, immutable') $(hdr "${AS[@]}" "$SKU$f" | grep -ci '^cache-control: max-age=31536000')"
done
for f in /fonts/Outfit-latin-variable.woff2 /pagefind/pagefind.js /favicon.svg; do
  check "sin hash: $f" "cache-control: public, max-age=86400" \
    "$(hdr "${AS[@]}" "$SKU$f" | grep -i '^cache-control:' | tr 'A-Z' 'a-z')"
done
check "html: no-cache"              "cache-control: no-cache" "$(hdr "${AS[@]}" "$SKU/" | grep -i '^cache-control:' | tr 'A-Z' 'a-z')"
check "html sin ext: no-cache"      "cache-control: no-cache" "$(hdr "${AS[@]}" "$SKU/es" | grep -i '^cache-control:' | tr 'A-Z' 'a-z')"
# La anterior: con hash o sin él, la misma política.
SKPREV="$(hdr -H 'Host: skew.test' "$SKU/_astro/a.Ab12Cd34.js")"
check "anterior con hash, inmutable" "1" "$(grep -ci '^cache-control: public, immutable' <<<"$SKPREV")"
# CSP del orbit.json: en el HTML, en los estáticos, en el .md y en el 404.
CSP="content-security-policy: default-src 'self'; img-src 'self' data:"
for f in / /es /_astro/Base.jLhV-p7P.css /fonts/Outfit-latin-variable.woff2 /x.md /favicon.svg; do
  check "csp en $f" "$CSP" "$(hdr "${AS[@]}" "$SKU$f" | grep -i '^content-security-policy:' | tr 'A-Z' 'a-z')"
done
check "csp en el 404"               "1" "$(hdr "${AS[@]}" "$SKU/nope" | grep -ci '^content-security-policy:')"
check "csp en la 301"               "1" "$(hdr "${AS[@]}" "$SKU/es/" | grep -ci '^content-security-policy:')"
check "sin csp, sin cabecera"       "0" "$(hdr -H 'Host: sincert.test' "$SKU/" | grep -ci '^content-security-policy')"
check "informe: la cabecera"        "1" "$(hdr -H 'Host: cspro.test' "$SKU/" | grep -ci '^content-security-policy-report-only: default-src .none.')"
check "informe: no la de bloqueo"   "0" "$(hdr -H 'Host: cspro.test' "$SKU/" | grep -ci '^content-security-policy:')"
check "informe: en el css"          "1" "$(hdr -H 'Host: cspro.test' "$SKU/a.css" | grep -ci '^content-security-policy-report-only:')"
# Una CSP rechazada aborta antes de escribir el vhost.
( nginx_vhost cspmal >/dev/null 2>&1 ); check "csp con comillas dobles: aborta" "1" "$?"

section "Los recursos de la release anterior siguen sirviéndose"
SK=(-H 'Host: skew.test')
SKU="http://127.0.0.1:$HTTP_PORT"
check "chunk de la anterior"         "200"          "$(H "${SK[@]}" "$SKU/_astro/a.Ab12Cd34.js")"
check "y es el de la anterior"       "chunk de A"   "$(BODY "${SK[@]}" "$SKU/_astro/a.Ab12Cd34.js")"
check "el de la activa, igual"       "chunk de B"   "$(BODY "${SK[@]}" "$SKU/_astro/b.Cd34.js")"
# Si los dos lo tienen, manda la activa: la anterior es un repuesto.
check "si están los dos, la activa"  "estilo de B"  "$(BODY "${SK[@]}" "$SKU/_astro/comun.css")"
# El de la anterior es tan inmutable como el de la activa —lleva hash—, y
# lleva las mismas cabeceras de seguridad.
SKH="$(curl -sI --noproxy '*' -m 5 "${SK[@]}" "$SKU/_astro/a.Ab12Cd34.js")"
check "con caché inmutable"          "1" "$(grep -ci '^cache-control: public, immutable' <<<"$SKH")"
check "y con nosniff"                "1" "$(grep -ci '^x-content-type-options: nosniff' <<<"$SKH")"
check "la portada es la activa"      "portada B"    "$(BODY "${SK[@]}" "$SKU/")"
# Lo que no se puede servir de la anterior, aunque esté ahí.
# '/vieja/' redirige a '/vieja' (barra final) y ahí es un 404 de verdad: se sigue.
check "una ruta, nunca de la anterior" "404"        "$(H -L "${SK[@]}" "$SKU/vieja/")"
check "ni un .html"                  "404"          "$(H "${SK[@]}" "$SKU/suelta.html")"
check "sale el 404.html de la activa" "B no existe" "$(BODY -L "${SK[@]}" "$SKU/vieja/")"
check "un recurso que no está en ninguna" "404"     "$(H "${SK[@]}" "$SKU/_astro/nada.js")"
check "también con su 404.html"      "B no existe"  "$(BODY "${SK[@]}" "$SKU/_astro/nada.js")"
check ".env de la anterior"          "403"          "$(H "${SK[@]}" "$SKU/.env")"
check "un oculto con extensión de recurso" "403"    "$(H "${SK[@]}" "$SKU/.oculto.js")"
check "un .php de la anterior"       "404"          "$(H "${SK[@]}" "$SKU/viejo.php")"
check "y su fuente no sale"          "0" "$(BODY "${SK[@]}" "$SKU/viejo.php" | grep -c FUGA)"
check "un service worker viejo, no"  "404"          "$(H "${SK[@]}" "$SKU/sw.js")"

# En una SPA, igual para los recursos; y las rutas siguen siendo del shell de
# la activa, no del de la anterior.
SP=(-H 'Host: spaskew.test')
check "spa: chunk de la anterior"    "lazy de A"    "$(BODY "${SP[@]}" "$SKU/assets/ruta-x9.js")"
check "spa: las rutas, a la activa"  "shell B"      "$(BODY "${SP[@]}" "$SKU/una/ruta")"
check "spa: un .js que falta"        "404"          "$(H "${SP[@]}" "$SKU/assets/nada.js")"
# Antes el 404 volvía a entrar por 'location /' y caía en el fallback: el .js
# que faltaba se contestaba con el index.html entero.
check "y no es el index.html"        "0" "$(BODY "${SP[@]}" "$SKU/assets/nada.js" | grep -c 'shell')"

# Next: el alias de /_next/static/ con la anterior detrás.
NX=(-H 'Host: nextapp.test')
check "next: chunk de la anterior"   "next chunk A" "$(BODY "${NX[@]}" "$SKU/_next/static/chunks/a1.js")"
check "next: el de la activa"        "next chunk B" "$(BODY "${NX[@]}" "$SKU/_next/static/chunks/b2.js")"
check "next: en ninguna, 404"        "404"          "$(H "${NX[@]}" "$SKU/_next/static/chunks/nada.js")"
check "next: oculto, no"             "403"          "$(H "${NX[@]}" "$SKU/_next/static/chunks/.oculto.js")"
check "next: el resto, al proceso"   "respuesta del backend" "$(BODY "${NX[@]}" "$SKU/")"

# Django: el hash de ManifestStaticFilesStorage, igual.
check "django: hoja de la anterior"  "hoja de la anterior" \
  "$(BODYS py.test "https://py.test:$HTTPS_PORT/static/css/app.4f2e.css")"
check "django: la de la activa"      "body{color:red}" \
  "$(BODYS py.test "https://py.test:$HTTPS_PORT/static/css/app.css")"

# Con PHP: lo que protege un prefijo '^~' no mira la anterior, y un .php de la
# anterior no se ejecuta ni se sirve.
check "apiweb: recurso de la anterior" "recurso de la anterior" \
  "$(BODY -H 'Host: apiweb.test' "$SKU/_astro/v.js")"
check "apiweb: dentro de api/, no"   "404" "$(H -H 'Host: apiweb.test' "$SKU/api/viejo.js")"
check "hibrida: vendor/ de la anterior, no" "404" "$(H -H 'Host: hibrida.test' "$SKU/vendor/viejo.js")"
check "hibrida: un .php de la anterior, no" "404" "$(H -H 'Host: hibrida.test' "$SKU/viejo.php")"
check "hibrida: ni se ejecuta"       "0" "$(BODY -H 'Host: hibrida.test' "$SKU/viejo.php" | grep -c 'EJECUTADO')"

# Las apps con proceso: lo mismo, y lo que no está en ninguna va a la app.
PN=(-H 'Host: procnuxt.test')
check "proceso: chunk de la anterior" "nuxt chunk A" "$(BODY "${PN[@]}" "$SKU/_nuxt/a1.js")"
check "proceso: el de la activa"     "nuxt chunk B" "$(BODY "${PN[@]}" "$SKU/_nuxt/b2.js")"
check "proceso: los dos, la activa"  "estilo B"     "$(BODY "${PN[@]}" "$SKU/_nuxt/comun.css")"
PNH="$(curl -sI --noproxy '*' -m 5 "${PN[@]}" "$SKU/_nuxt/a1.js")"
check "proceso: inmutable"           "1" "$(grep -ci '^cache-control: public, immutable' <<<"$PNH")"
check "proceso: con nosniff"         "1" "$(grep -ci '^x-content-type-options: nosniff' <<<"$PNH")"
# La activa tiene su propia location, y su add_header anula los del server.
PNH="$(curl -sI --noproxy '*' -m 5 "${PN[@]}" "$SKU/_nuxt/b2.js")"
check "proceso: la activa, inmutable" "1" "$(grep -ci '^cache-control: public, immutable' <<<"$PNH")"
check "proceso: y con nosniff"       "1" "$(grep -ci '^x-content-type-options: nosniff' <<<"$PNH")"
# En ninguna de las dos: a la app, con la URI tal cual. Un 'buildAssetsDir'
# propio o un recurso que el framework genera en marcha llegan igual que antes.
check "proceso: si no está, a la app" "del proceso" "$(BODY "${PN[@]}" "$SKU/_nuxt/solo-app.js")"
check "proceso: y su 404 es el de la app" "1"   "$(BODY "${PN[@]}" "$SKU/_nuxt/nada.js" | grep -c 'Error code: 404')"
# latest.json es de Nuxt pero no es inmutable: así se entera el navegador de
# que hay un despliegue nuevo. Lo contesta el proceso, con sus cabeceras.
check "proceso: builds/, a la app"   "latest del proceso" "$(BODY "${PN[@]}" "$SKU/_nuxt/builds/latest.json")"
check "proceso: y sin un año de caché" "0" \
  "$(curl -sI --noproxy '*' -m 5 "${PN[@]}" "$SKU/_nuxt/builds/latest.json" | grep -ci immutable)"
check "proceso: las rutas, a la app" "respuesta del backend" "$(BODY "${PN[@]}" "$SKU/")"
check "proceso: una página vieja, no" "0"       "$(BODY "${PN[@]}" "$SKU/vieja.html" | grep -c FUGA)"
check "proceso: oculto de la anterior" "403"    "$(H "${PN[@]}" "$SKU/_nuxt/.oculto.js")"
check "proceso: .env de la anterior" "403"      "$(H "${PN[@]}" "$SKU/_nuxt/viejo.env")"
check "enlace fuera: no se sigue"    "404"      "$(H "${PN[@]}" "$SKU/_nuxt/enlace.js")"
check "ni en la anterior"            "404"      "$(H "${PN[@]}" "$SKU/_nuxt/enlace-viejo.js")"
check "ni una carpeta enlazada"      "404"      "$(H "${PN[@]}" "$SKU/_nuxt/carpeta/${FUGA_T##*/}")"
check "el enlace propio, sí"         "nuxt chunk B" "$(BODY "${PN[@]}" "$SKU/_nuxt/propio.js")"
# Con el proceso caído los recursos siguen saliendo, de las dos; lo que no
# está es un 502 —ha ido a la app—, no un 404 que nadie ha decidido.
PQ=(-H 'Host: procqwik.test')
check "caída: /build/ de la anterior" "qwik A"  "$(BODY "${PQ[@]}" "$SKU/build/q-a.js")"
check "caída: /build/ de la activa"  "qwik B"   "$(BODY "${PQ[@]}" "$SKU/build/q-b.js")"
check "caída: el segundo prefijo"    "grafo A"  "$(BODY "${PQ[@]}" "$SKU/assets/g-a.json")"
check "caída: lo que no está, 502"   "502"      "$(H "${PQ[@]}" "$SKU/build/nada.js")"
check "caída: y la portada, 502"     "502"      "$(H "${PQ[@]}" "$SKU/")"

# Y cuando la poda se lleva la anterior, el enlace queda colgando y el recurso
# es un 404 normal: nada que limpiar en nginx.
rm -rf "$SKA"
check "podada la anterior, 404"      "404"          "$(H "${SK[@]}" "$SKU/_astro/a.Ab12Cd34.js")"
check "y la activa sigue igual"      "chunk de B"   "$(BODY "${SK[@]}" "$SKU/_astro/b.Cd34.js")"

section "La página de 404 de la web"
check "estática: ruta inventada"     "no encontrado" \
  "$(BODY -H 'Host: sincert.test' "$SKU/una/ruta/inventada")"
# Pedirla por su nombre es pedir una página que existe.
check "el 404.html a secas, 200"     "200" "$(H -H 'Host: sincert.test' "$SKU/404.html")"
# El formato de carpetas: 404/index.html en vez de 404.html.
mkdir -p "$TMP/apps/spaskew/releases/B/dist/404"
printf 'carpeta 404\n' > "$TMP/apps/spaskew/releases/B/dist/404/index.html"
check "con 404/index.html también"   "carpeta 404" "$(BODY "${SP[@]}" "$SKU/assets/nada.js")"
check "con su código"                "404"         "$(H "${SP[@]}" "$SKU/assets/nada.js")"
check "y la SPA sigue con su shell"  "shell B"     "$(BODY "${SP[@]}" "$SKU/otra/ruta")"
check "con 200"                      "200"         "$(H "${SP[@]}" "$SKU/otra/ruta")"

section "Cuando la app no contesta"
check "502, no otro código"          "502" "$(H -H 'Host: caida.test' "$SKU/")"
check "con la página de Orbit"       "1"   "$(BODY -H 'Host: caida.test' "$SKU/" | grep -c '<h1>.*no responde ahora mismo')"
check "y no la de nginx"             "0"   "$(BODY -H 'Host: caida.test' "$SKU/" | grep -ci 'bad gateway')"
CH="$(curl -sI --noproxy '*' -m 5 -H 'Host: caida.test' "$SKU/cualquier/ruta")"
check "sin caché"                    "1"   "$(grep -ci '^cache-control: no-store' <<<"$CH")"
check "con las cabeceras de seguridad" "1" "$(grep -ci '^x-frame-options: sameorigin' <<<"$CH")"
# Sin la página —alguien la borró— el código es el mismo. Con un 'rewrite' a
# secas, como la de mantenimiento, el fichero que falta lo convertía en 404.
check "sin página, sigue siendo 502" "502" "$(H -H 'Host: caidasin.test' "$SKU/")"
# Lo que contesta la app pasa tal cual: un 404 del proceso no es de Orbit.
check "el 404 de la app, intacto"    "404" "$(H -H 'Host: proxy.test' -H 'X-Forwarded-Proto: https' "$SKU/no-existe")"
check "y sin la página de la web"    "0"   "$(BODY -H 'Host: proxy.test' -H 'X-Forwarded-Proto: https' "$SKU/no-existe" | grep -c 'no encontrado')"

section "El mantenimiento puesto a mano, sin página"
# El principio 3: el testigo se puede poner con un 'touch' sin Orbit. Si la
# página no existía, el 'rewrite' que la buscaba convertía el 503 en un 404
# para toda la web.
: > "$TMP/apps/caidasin/shared/maintenance.on" 2>/dev/null \
  || { mkdir -p "$TMP/apps/caidasin/shared"; : > "$TMP/apps/caidasin/shared/maintenance.on"; }
check "sigue siendo 503"             "503" "$(H -H 'Host: caidasin.test' "$SKU/")"
check "con su Retry-After"           "1"   "$(curl -sI --noproxy '*' -m 5 -H 'Host: caidasin.test' "$SKU/" | grep -ci '^retry-after: 120')"
rm -f "$TMP/apps/caidasin/shared/maintenance.on"
check "y al quitarlo, vuelve el 502" "502" "$(H -H 'Host: caidasin.test' "$SKU/")"

section "Pasar del límite es un 429, no el mantenimiento"
# 40 r/s con 80 de ráfaga: 200 peticiones seguidas por la misma conexión lo
# rebasan seguro. Antes salía un 503 —el del mantenimiento, con su página y su
# Retry-After de dos minutos— o un 404 si la página no existía.
LIM="$(for _ in $(seq 200); do printf 'url = "%s/"\n' "$SKU"; done \
  | curl -s --noproxy '*' -m 20 -H 'Host: caida.test' -o /dev/null -w '%{http_code}\n' -K - 2>/dev/null || true)"
check "alguna llega al límite"       "1" "$([[ "$(grep -c '^429$' <<<"$LIM")" -gt 0 ]] && echo 1 || echo 0)"
check "y ninguna sale como 503"      "0" "$(grep -c '^503$' <<<"$LIM")"
# Y tampoco como 404: sin página de mantenimiento —una app que no ha estado
# nunca en mantenimiento no la tiene— el 503 acababa en eso. Medido.
check "ni como 404"                  "0" "$(grep -c '^404$' <<<"$LIM")"

section "Si nginx rechaza el vhost, el servidor se queda como estaba"
# Antes, render_nginx escribía el vhost y lo enlazaba en sites-enabled **antes**
# de 'nginx -t', y al fallar devolvía 1 sin deshacer nada: la configuración del
# servidor entero quedaba inválida —ningún otro despliegue, ninguna renovación,
# y nginx sin arrancar tras un reinicio—. Aquí 'nginx -t' es el de verdad,
# sobre lo que haya en el sites-enabled de las pruebas (lib.sh lo desvía a
# $TMP), con las mismas rutas traducidas que install_vhost.
nginx() {
  if [[ "${1:-}" == "-t" ]]; then
    local f
    rm -rf "$NG/rt"; mkdir -p "$NG/rt"
    for f in "$NGINX_ENABLED"/*; do
      [[ -e "$f" ]] || continue
      sed -e "s#/etc/nginx/snippets/#$NG/snippets/#g" -e "s#/var/log/nginx/#$NG/logs/#g" \
          -e "/listen \[::\]/d" -e "s/^\( *\)listen 80;/\1listen 127.0.0.1:$HTTP_PORT;/" \
          -e "s/^\( *\)listen 443 ssl\(.*\);/\1listen 127.0.0.1:$HTTPS_PORT ssl\2;/" \
          "$f" > "$NG/rt/${f##*/}"
    done
    sed "s#include $NG/vhosts/\*.conf;#include $NG/rt/*;#" "$NG/nginx.conf" > "$NG/rt.conf"
    command nginx -t -c "$NG/rt.conf" -p "$NG"
    return
  fi
  command nginx "$@"
}
systemctl() { return 0; }
run render_nginx sincert >/dev/null 2>&1; r=$?
check "un vhost válido se acepta"   "0" "$r"
ANTES="$(cat "$(nginx_file sincert)")"
# Un alias con ';' escrito en la configuración a mano, o por una versión que
# todavía no validaba los dominios: nginx no puede leer el resultado.
load_app sincert; A_ALIASES='otra.test;roto'; save_app
render_nginx sincert >/dev/null 2>&1; r=$?
check "uno roto se rechaza"         "1" "$r"
check "el vhost anterior, intacto"  "1" "$([[ "$(cat "$(nginx_file sincert)")" == "$ANTES" ]] && echo 1 || echo 0)"
check "sigue enlazado"              "1" "$([[ -L "$(nginx_link sincert)" ]] && echo 1 || echo 0)"
check "y nginx -t sigue pasando"    "0" "$(nginx -t >/dev/null 2>&1; echo $?)"
check "el rechazado, a la vista"    "1" "$(grep -c 'otra.test;roto' "$(nginx_file sincert).rejected")"
load_app sincert; A_ALIASES=''; save_app
# Una app nueva, sin vhost anterior: no se queda ni el enlace ni el fichero.
mkapp nueva-rota static "" "nueva.test;roto"
A_OUTDIR="."; save_app
render_nginx nueva-rota >/dev/null 2>&1; r=$?
check "nueva y rota: se rechaza"    "1" "$r"
check "sin enlace"                  "0" "$([[ -e "$(nginx_link nueva-rota)" || -L "$(nginx_link nueva-rota)" ]] && echo 1 || echo 0)"
check "ni fichero"                  "0" "$([[ -e "$(nginx_file nueva-rota)" ]] && echo 1 || echo 0)"
check "y nginx -t sigue pasando"    "0" "$(nginx -t >/dev/null 2>&1; echo $?)"
unset -f nginx systemctl

report
