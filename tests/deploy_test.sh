#!/usr/bin/env bash
# Prueba del ciclo de despliegue completo contra un repositorio git local.
#   bash tests/deploy_test.sh
#
# No necesita systemd, ni el usuario 'deploy', ni tocar /etc/nginx: se anulan
# esas piezas tal y como sugiere ARCHITECTURE §11. Lo que sí se ejercita de
# verdad es git, rsync, las releases, el symlink atómico y la poda.
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, PORT_BASE,
# KEEP_RELEASES…) que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v rsync >/dev/null || {
  echo "rsync no está instalado: me salto las pruebas de despliegue."
  exit 0
}

# --- piezas del sistema que no queremos tocar desde una prueba -------------
need_root()     { :; }
# Se apunta lo que se le pide para poder comprobar que el despliegue recarga
# php-fpm: sin esa recarga el symlink se mueve y php-fpm sigue sirviendo la
# release anterior hasta que caduque su caché de realpath.
SYSCTL_LOG="$TMP/systemctl.log"; : > "$SYSCTL_LOG"
# 'is-active' contesta que no: en este árbol no corre systemd y ninguna unidad
# está activa de verdad. Sin esto, el despliegue tomaría el camino del reinicio
# sin corte en TODAS las pruebas —el stub devolvía 0 a cualquier cosa— y las
# del camino clásico dejarían de ejercitar lo que dicen. Las pruebas del
# solape lo redefinen a propósito.
systemctl() {
  printf '%s\n' "$*" >> "$SYSCTL_LOG"
  [[ "${1:-}" == "is-active" ]] && return 1
  return 0
}
render_systemd() { :; }
render_nginx()  { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }
LOG_FILE="$TMP/orbit.log"

# Todo corre como el usuario actual: no hay usuario 'deploy' en el contenedor.
# Pero se apunta QUIÉN habría corrido cada cosa, que es la mitad que faltaba:
# doblando los dos al mismo bash, la diferencia entre el fetcher y el builder
# —lo único que sostiene §5.3— era invisible para la suite, y por ahí se coló
# un 'as_deploy' en las cachés de Laravel que las escribía en una release del
# usuario de la app: permiso denegado, y Laravel sin poder desplegarse en
# ninguna app aislada. Aquí no se puede reproducir el permiso, pero sí el
# reparto de papeles, que es lo que hay que fijar.
QUIEN_LOG="$TMP/quien.log"; : > "$QUIEN_LOG"
as_deploy() { printf 'as_deploy %s\n' "$*" >> "$QUIEN_LOG"; bash -lc "$*"; }
as_app()    { printf 'as_app %s\n'    "$*" >> "$QUIEN_LOG"; bash -lc "$*"; }
sudo() { # descarta -u/-H/-- y ejecuta el resto tal cual
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -u) shift 2 ;;
      --) shift; break ;;
      *)  shift ;;
    esac
  done
  "$@"
}

# --- servidor HTTP de mentira, para el health check -------------------------
# El puerto lo elige el sistema (bind al 0) y se escribe en un fichero. Con un
# número fijo se choca antes o después con algo que ya esté escuchando, y el
# síntoma —«Empty reply from server»— no se parece en nada a «ese puerto está
# ocupado»: costó un rato averiguarlo.
_srv_start() { # _srv_start <fichero del código> <fichero del puerto>
  rm -f "$2"
  python3 -c "
import http.server, sys
cf, pf = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        c = int(open(cf).read().strip())
        self.send_response(c); self.send_header('Content-Length','1'); self.end_headers()
        self.wfile.write(b'x')
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(pf,'w').write(str(s.server_address[1]))
s.serve_forever()
" "$1" "$2" >/dev/null 2>&1 &
  # Sin 'echo' del puerto y sin sustitución de órdenes en quien llama: dentro de
  # un $( ) el servidor se queda en el subshell y '$!' no vale para nada. El
  # puerto se lee del fichero.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$2" ]] && break; sleep 0.3; done
}

# --- repositorio de origen -------------------------------------------------
ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN"
git -C "$ORIGIN" config user.email orbit@test
git -C "$ORIGIN" config user.name Orbit
publish() { # publish <contenido>
  printf '%s\n' "$1" > "$ORIGIN/index.html"
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" commit -qm "$1"
}
publish "version uno"

{
  A_NAME="web"; A_REPO="$ORIGIN"; A_BRANCH="main"; A_DOMAIN="web.test"
  A_ALIASES=""; A_TYPE="static"; A_PKG="pnpm"; A_BUILD=""; A_START=""
  A_OUTDIR="."; A_SPA="no"; A_PORT=""; A_DOCROOT=""; A_PYAPP=""
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
}
save_app

BASE="$TMP/apps/web"
current_release() { basename "$(readlink -f "$BASE/current")"; }
count_releases()  { releases_desc "$BASE" | wc -l; }

section "Primer despliegue"
run cmd_deploy web >"$TMP/out1" 2>&1; r=$?
[[ "$r" == 0 ]] || sed 's/^/      /' "$TMP/out1"
check "termina bien" "0" "$r"
check "sirve la version uno" "version uno" "$(cat "$BASE/current/index.html")"
check "una release" "1" "$(count_releases)"
check ".env enlazado" "$TMP/apps/web/shared/.env" "$(readlink "$BASE/current/.env")"
load_app web
check "guarda el commit" "1" "$(grep -c "$(git -C "$ORIGIN" rev-parse --short HEAD)" <<<"$A_LASTDEPLOY")"
check "deja rastro en el log" "1" "$(grep -c '^.* deploy web ' "$TMP/orbit.log")"

section "Segundo despliegue"
sleep 1   # las releases se nombran por segundo
publish "version dos"
FIRST="$(current_release)"
run cmd_deploy web >"$TMP/out2" 2>&1; r=$?
check "termina bien" "0" "$r"
check "sirve la version dos" "version dos" "$(cat "$BASE/current/index.html")"
check "dos releases" "2" "$(count_releases)"
check "release nueva" "no" "$([[ "$(current_release)" == "$FIRST" ]] && echo si || echo no)"

section "Build fallido: producción intacta"
sleep 1
publish "version tres"
load_app web
A_BUILD="echo 'algo ha explotado' >&2; exit 1"
save_app
GOOD="$(current_release)"
run cmd_deploy web >"$TMP/out3" 2>&1; r=$?
check "aborta" "1" "$r"
check "no mueve el symlink" "$GOOD" "$(current_release)"
check "sigue la version dos" "version dos" "$(cat "$BASE/current/index.html")"
check "borra la release rota" "2" "$(count_releases)"
check "explica el motivo" "1" "$(grep -c 'La versión anterior sigue en producción' "$TMP/out3")"

section "Un build que Orbit sabe arreglar"
# El caso que motivó todo esto: el build falla por algo con arreglo conocido,
# Orbit lo aplica y reintenta una vez. Aquí se usa el remedio de memoria y no
# el de pnpm porque no depende de ninguna herramienta externa: la firma está en
# el log y el arreglo es una variable de entorno.
sleep 1
publish "version recuperada"
load_app web
# Se busca el heap concreto que pone el remedio, y no un NODE_OPTIONS
# cualquiera: hay entornos que ya lo traen puesto, y entonces el primer intento
# saldría bien y esta prueba no probaría nada sin decirlo.
A_BUILD='case "${NODE_OPTIONS:-}" in *max-old-space-size=2048*) echo compilado ;;
         *) echo "FATAL ERROR: Allocation failed - JavaScript heap out of memory" >&2; exit 1 ;; esac'
A_NODE_HEAP=""
save_app
# Fija, para no depender de la memoria de la máquina que ejecute las pruebas.
_recover_heap_mb() { printf '2048'; }
GOOD="$(current_release)"
run cmd_deploy web >"$TMP/rec1" 2>&1; r=$?
check "termina bien"        "0"  "$r"
check "y despliega"         "version recuperada" "$(cat "$BASE/current/index.html")"
check "reintenta una vez"   "1"  "$(grep -c 'Compilando de nuevo' "$TMP/rec1")"
check "y lo dice"           "1"  "$(grep -c 'Recuperado' "$TMP/rec1")"
check "queda en el log"     "1"  "$(grep -c ' recover web ' "$TMP/orbit.log")"
load_app web
check "lo recuerda"         "2048" "$A_NODE_HEAP"

# Lo que hace que esto sirva de algo: el siguiente despliegue ya no falla,
# porque el arreglo se aplica desde el primer intento.
sleep 1
publish "version siguiente"
run cmd_deploy web >"$TMP/rec2" 2>&1; r=$?
check "el siguiente, a la primera" "0" "$r"
check "sin reintento"       "0"  "$(grep -c 'Compilando de nuevo' "$TMP/rec2")"

section "Un build que no sabe arreglar"
# Un error de código no se arregla repitiéndolo: reintentar sería tardar el
# doble en dar la misma noticia.
sleep 1
publish "version rota"
load_app web
A_BUILD='echo "TypeError: undefined is not a function" >&2; exit 1'
save_app
GOOD="$(current_release)"
BEFORE="$(count_releases)"
run cmd_deploy web >"$TMP/rec3" 2>&1; r=$?
check "aborta"              "1"  "$r"
check "sin reintentar"      "0"  "$(grep -c 'Compilando de nuevo' "$TMP/rec3")"
check "no mueve el symlink" "$GOOD" "$(current_release)"
check "y borra la rota"     "$BEFORE" "$(count_releases)"

# No lo arregla, pero tampoco te deja con el log crudo: el consejo tiene que
# llegar hasta la salida del despliegue, no quedarse en la función.
sleep 1
publish "version con lockfile viejo"
load_app web
A_BUILD='echo "[ERR_PNPM_OUTDATED_LOCKFILE] Cannot install with \"frozen-lockfile\"" >&2; exit 1'
save_app
run cmd_deploy web >"$TMP/rec5" 2>&1; r=$?
check "aborta igual"        "1"  "$r"
check "pero explica el fallo" "1" "$(grep -c 'no coincide con el package.json' "$TMP/rec5")"
check "y sigue diciendo que no ha tocado producción" "1" \
                            "$(grep -c 'La versión anterior sigue en producción' "$TMP/rec5")"

section "Cuando el reintento también falla"
# Dos intentos y se acabó. Ni un bucle, ni una release a medias en producción.
sleep 1
publish "version sin memoria"
load_app web
A_BUILD='echo "FATAL ERROR: Allocation failed - JavaScript heap out of memory" >&2; exit 1'
A_NODE_HEAP=""
save_app
GOOD="$(current_release)"
BEFORE="$(count_releases)"
run cmd_deploy web >"$TMP/rec4" 2>&1; r=$?
check "aborta"              "1"  "$r"
check "exactamente dos intentos" "1" "$(grep -c 'Compilando de nuevo' "$TMP/rec4")"
check "lo explica"          "1"  "$(grep -c 'ha vuelto a fallar' "$TMP/rec4")"
check "producción intacta"  "$GOOD" "$(current_release)"
check "y borra la rota"     "$BEFORE" "$(count_releases)"

section "Poda de releases antiguas"
load_app web
A_BUILD=""
save_app
KEEP_RELEASES=2
for v in cuatro cinco; do
  sleep 1
  publish "version $v"
  run cmd_deploy web >/dev/null 2>&1
done
check "conserva KEEP_RELEASES" "2" "$(count_releases)"
check "sirve la ultima" "version cinco" "$(cat "$BASE/current/index.html")"
check "la activa no se poda" "1" "$([[ -d "$BASE/current/" ]] && echo 1 || echo 0)"

section "Dos despliegues en el mismo segundo"
# Sin desambiguar, ambos escribirían en la misma carpeta y la release
# "anterior" a la que volver sería la que acabamos de sobrescribir.
KEEP_RELEASES=5
publish "version seis"
run cmd_deploy web >/dev/null 2>&1
PREV="$(current_release)"
publish "version siete"
run cmd_deploy web >/dev/null 2>&1
check "carpetas distintas" "no" "$([[ "$(current_release)" == "$PREV" ]] && echo si || echo no)"
check "la anterior sobrevive" "version seis" "$(cat "$BASE/releases/$PREV/index.html")"

section "De clonar a servir, de una tirada"
# El camino que recorre alguien que monta un staging: clonar, rellenar el
# .env, desplegar y quitar el mantenimiento. Cada pieza tenía su prueba; lo
# que faltaba era comprobar que encajan.
load_app web; A_BRANCH="main"; save_app
mkdir -p "$TMP/apps/web/shared"
printf 'DATABASE_URL=postgres://u:secreta@localhost/prod\n' > "$TMP/apps/web/shared/.env"
publish "produccion sirviendo"
run cmd_deploy web >/dev/null 2>&1

run cmd_clone web staging --domain staging.web.test >/dev/null 2>&1; r=$?
check "clona"                  "0" "$r"
check "nace en mantenimiento"  "1" "$(_maint_is_on staging && echo 1 || echo 0)"
check "sin release todavía"    "0" "$([[ -e "$TMP/apps/staging/current" ]] && echo 1 || echo 0)"
check "sin el secreto"         "0" "$(grep -c secreta "$TMP/apps/staging/shared/.env")"

run cmd_env set staging DATABASE_URL 'postgres://u:otra@localhost/staging' >/dev/null 2>&1
run cmd_deploy staging >"$TMP/cl1" 2>&1; r=$?
check "el primer despliegue sale" "0" "$r"
check "y sirve el mismo código"   "produccion sirviendo" "$(cat "$TMP/apps/staging/current/index.html")"
check "sin tocar producción"      "produccion sirviendo" "$(cat "$TMP/apps/web/current/index.html")"
check "cada una con su release"   "no" "$([[ "$(readlink "$TMP/apps/staging/current")" == "$(readlink "$TMP/apps/web/current")" ]] && echo si || echo no)"
check "sigue en mantenimiento"    "1" "$(_maint_is_on staging && echo 1 || echo 0)"

run cmd_maintenance off staging >/dev/null 2>&1
check "y se quita a mano"         "0" "$(_maint_is_on staging && echo 1 || echo 0)"
check "el .env del staging aguanta" "1" "$(grep -c 'otra@localhost' "$TMP/apps/staging/shared/.env")"
check "el de producción también"    "1" "$(grep -c 'secreta@localhost' "$TMP/apps/web/shared/.env")"

# Desplegar la copia no puede arrastrar a la original ni al revés.
publish "solo en staging"
run cmd_deploy staging >/dev/null 2>&1
check "avanza sola"               "solo en staging"      "$(cat "$TMP/apps/staging/current/index.html")"
check "la original se queda"      "produccion sirviendo" "$(cat "$TMP/apps/web/current/index.html")"

section "Rollback nombrando la release"
# Sin nombrarla se abre un selector, que es lo cómodo con alguien delante. Un
# script —y Orbit Desktop— necesita poder decir a cuál volver.
load_app web; A_BUILD=""; A_NODE_HEAP=""; save_app
KEEP_RELEASES=5
sleep 1; publish "uno"; run cmd_deploy web >/dev/null 2>&1
UNO="$(current_release)"
sleep 1; publish "dos"; run cmd_deploy web >/dev/null 2>&1
DOS="$(current_release)"
run cmd_rollback web "$UNO" >"$TMP/rb1" 2>&1; r=$?
check "vuelve a la nombrada" "0"   "$r"
check "y sirve aquello"   "uno"    "$(cat "$BASE/current/index.html")"
check "queda en el log"   "1"      "$(grep -c " rollback web $UNO\$" "$TMP/orbit.log")"

# Volver a la que ya está activa no es un error, pero tampoco es un trabajo:
# reiniciar el servicio y recargar nginx por nada es peor que no hacer nada.
run cmd_rollback web "$UNO" >"$TMP/rb2" 2>&1; r=$?
check "a la activa, no hace nada" "0" "$r"
check "y lo dice"         "1"      "$(grep -c 'ya está sirviendo' "$TMP/rb2")"

run cmd_rollback web 19990101-000000 >"$TMP/rb3" 2>&1; r=$?
check "release inventada" "1"      "$r"
check "y enseña cuáles hay" "1"    "$(grep -c "$DOS" "$TMP/rb3")"
check "sin tocar nada"    "uno"    "$(cat "$BASE/current/index.html")"

# Sin terminal y sin release, elegir «la primera de la lista» sería volver a la
# que ya está activa: mejor abortar diciendo cómo se nombra.
run cmd_rollback web </dev/null >"$TMP/rb4" 2>&1; r=$?
check "sin release ni terminal" "1" "$r"
check "explica el uso"    "1"      "$(grep -c 'orbit rollback web <release>' "$TMP/rb4")"
run cmd_rollback web "$DOS" >/dev/null 2>&1

section "Laravel: el storage compartido se siembra, y sobrevive"
# El 'artisan' de mentira es un script de PHP porque Orbit lo invoca como
# 'php artisan', igual que haría con el de verdad.
if ! command -v php >/dev/null; then
  echo "  (sin php instalado: me salto las pruebas de Laravel)"
else
# El fallo que arregla esto: la línea que sustituye storage/ por el compartido
# sólo se activaba si shared/storage ya existía, y Orbit no lo creaba nunca. En
# la práctica no se activaba jamás, así que todo lo que la app escribiera —logs,
# sesiones, subidas— se borraba en el despliegue siguiente. Y crearlo a mano era
# peor: un shared/storage vacío deja la app devolviendo 500 en todo, porque
# Laravel crea logs/ sola pero no framework/views/.
LAR="$TMP/laravel"
git init -q -b main "$LAR"
git -C "$LAR" config user.email orbit@test
git -C "$LAR" config user.name Orbit
mkdir -p "$LAR/bootstrap/cache" "$LAR/public" \
         "$LAR/storage/app/public" "$LAR/storage/framework/views" \
         "$LAR/storage/framework/cache/data" "$LAR/storage/framework/sessions" "$LAR/storage/logs"
# Un 'artisan' de mentira que **hace algo comprobable**. El de antes era un
# '#!/usr/bin/env php' vacío que aceptaba cualquier subcomando y salía con 0:
# con él se podían borrar key:generate, storage:link y config:cache uno a uno y
# 'make test' seguía en verde. Éste apunta lo que le piden y escribe la clave,
# que es lo que permite comprobar el orden y que no se regenere.
# Va en PHP porque Orbit lo invoca como 'php artisan', igual que el de verdad.
cat > "$LAR/artisan" <<'ART'
#!/usr/bin/env php
<?php
$d = getcwd();
$args = array_slice($argv, 1);
file_put_contents("$d/artisan.log", implode(' ', $args)."\n", FILE_APPEND);
switch ($args[0] ?? '') {
  case 'key:generate':
    // Como el de verdad: **sustituye** la línea APP_KEY=, no la crea, y si no
    // la encuentra sale con 0 sin escribir nada. Ése es justo el éxito mudo
    // que el despliegue tiene que detectar mirando el resultado.
    if (!is_file("$d/.env")) exit(1);
    $c = file_get_contents("$d/.env");
    if (!preg_match('/^APP_KEY=$/m', $c)) exit(0);
    file_put_contents("$d/.env", preg_replace('/^APP_KEY=$/m',
      'APP_KEY=base64:CLAVE'.bin2hex(random_bytes(4)), $c));
    break;
  case 'storage:link':
    @unlink("$d/public/storage");
    @symlink("$d/storage/app/public", "$d/public/storage");
    break;
  case 'config:cache':
    @mkdir("$d/bootstrap/cache", 0755, true);
    file_put_contents("$d/bootstrap/cache/config.php", '<?php return [];');
    break;
  case 'route:cache':
    @mkdir("$d/bootstrap/cache", 0755, true);
    file_put_contents("$d/bootstrap/cache/routes-v7.php", '<?php return [];');
    break;
  case 'view:cache':
    @mkdir("$d/storage/framework/views", 0755, true);
    file_put_contents("$d/storage/framework/views/compilada", 'x');
    break;
  case 'migrate:status':
    echo "  0001_01_01_000000_create_users_table .. [1] Ran\n";
    break;
}
exit(0);
ART
chmod +x "$LAR/artisan"
printf '{"require":{"laravel/framework":"^13.0"}}\n' > "$LAR/composer.json"
printf '<?php return 1;\n' > "$LAR/bootstrap/app.php"
printf '<?php echo "hola";\n' > "$LAR/public/index.php"
# Cada carpeta escribible viaja en git con su .gitignore, que es justo lo que
# permite sembrar el esqueleto sin inventarse la lista de directorios.
find "$LAR/storage" -type d -exec sh -c 'printf "*\n!.gitignore\n" > "$1/.gitignore"' _ {} \;
git -C "$LAR" add -A -f >/dev/null 2>&1
git -C "$LAR" commit -qm "laravel"

{
  A_NAME="tienda"; A_REPO="$LAR"; A_BRANCH="main"; A_DOMAIN="tienda.test"
  A_ALIASES=""; A_TYPE="laravel"; A_PKG="composer"; A_BUILD=""; A_START=""
  A_OUTDIR=""; A_SPA="no"; A_PORT=""; A_DOCROOT="public"; A_PYAPP=""
  A_MIGRATE="php artisan migrate --force"
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
}
save_app
LBASE="$TMP/apps/tienda"

# Un servidor HTTP de verdad detrás, porque desde este ciclo el despliegue de
# una app Laravel comprueba con curl que la web responde antes de darse por
# bueno. El código que devuelve se cambia desde un fichero, para poder romperlo
# a propósito más abajo.
CODEFILE="$TMP/httpcode"; echo 200 > "$CODEFILE"
_srv_start "$CODEFILE" "$TMP/httpport"; HPID=$!
NGINX_HTTP_PORT="$(cat "$TMP/httpport")"

run cmd_deploy tienda >"$TMP/lar1" 2>&1; r=$?
[[ "$r" == 0 ]] || sed 's/^/      /' "$TMP/lar1" | tail -20
check "primer despliegue"      "0" "$r"
check "storage es un enlace"   "$LBASE/shared/storage" "$(readlink "$LBASE/current/storage")"
# Ésta es la que se pone en rojo sin la siembra: sin framework/views la web
# responde 500 en todas las peticiones con «Please provide a valid cache path».
check "y trae el esqueleto"    "1" "$([[ -d "$LBASE/shared/storage/framework/views" ]] && echo 1 || echo 0)"
check "también cache/data"     "1" "$([[ -d "$LBASE/shared/storage/framework/cache/data" ]] && echo 1 || echo 0)"
check "y logs"                 "1" "$([[ -d "$LBASE/shared/storage/logs" ]] && echo 1 || echo 0)"

PRIMERA_KEY="$(grep '^APP_KEY=' "$LBASE/shared/.env")"
# Sin esto el despliegue no existe para una app PHP: php-fpm guarda en su caché
# de realpath a qué release apunta 'current', con un TTL de 120 s, así que mover
# el symlink no cambia nada. Medido con un Laravel de verdad: la release recién
# activada devolvía 200 con el cuerpo de la **anterior**, y sólo tras recargar
# php-fpm aparecía la nueva.
check "recarga php-fpm" "1" "$(grep -c "^reload php${PHP_VER}-fpm$" "$SYSCTL_LOG")"

# Lo que sube un usuario tiene que seguir ahí tras el despliegue siguiente: es
# la razón entera de que storage/ sea compartido.
printf 'una foto\n' > "$LBASE/shared/storage/app/public/foto.jpg"
sleep 1
git -C "$LAR" commit -q --allow-empty -m "otra"
run cmd_deploy tienda >"$TMP/lar2" 2>&1; r=$?
check "segundo despliegue"     "0" "$r"
check "la subida sigue"        "una foto" "$(cat "$LBASE/shared/storage/app/public/foto.jpg" 2>/dev/null)"
check "y se ve desde la release" "una foto" "$(cat "$LBASE/current/storage/app/public/foto.jpg" 2>/dev/null)"
check "dos releases"           "2" "$(releases_desc "$LBASE" | wc -l)"
# La APP_KEY se escribe una vez y no se toca más: regenerarla en cada despliegue
# invalidaría las sesiones y todo lo cifrado con la anterior. Antes esto sólo
# comprobaba que la línea existiera —y la línea la escribe Orbit, no artisan—,
# así que pasaba igual con key:generate borrado.
check "APP_KEY con valor" "1" "$(grep -c '^APP_KEY=base64:' "$LBASE/shared/.env")"
check "y la misma que en el primer despliegue" "$PRIMERA_KEY" \
  "$(grep '^APP_KEY=' "$LBASE/shared/.env")"

section "Laravel: los pasos de artisan, y en qué orden"
# El fixture apunta cada subcomando en artisan.log, así que aquí se comprueba
# lo que de verdad se ejecutó y no lo que creemos que se ejecutó.
LOG="$LBASE/current/artisan.log"
check "storage:link en cada release" "1" "$(grep -c '^storage:link --force$' "$LOG")"
check "cachea la configuración"      "1" "$(grep -c '^config:cache$' "$LOG")"
check "y las rutas"                  "1" "$(grep -c '^route:cache$' "$LOG")"
# view:cache escribe en storage/, que es compartido, y hace un view:clear antes:
# la release nueva borraría las vistas compiladas de la anterior.
check "pero NO las vistas"           "0" "$(grep -c '^view:cache$' "$LOG")"
# Y el orden: las cachés después del enlace, nunca antes.
check "el enlace va antes que la caché" "1" \
  "$(awk '/^storage:link/{s=NR} /^config:cache/{c=NR} END{print (s && c && s<c) ? 1 : 0}' "$LOG")"
# La clave se genera en el primero y no se vuelve a tocar.
check "key:generate sólo la primera vez" "0" "$(grep -c '^key:generate' "$LOG")"
# Y las cachés son de esta release, no compartidas: por eso vuelven con el
# symlink en un rollback.
check "config.php es de la release" "1" \
  "$([[ -f "$LBASE/current/bootstrap/cache/config.php" ]] && echo 1 || echo 0)"
check "y no está en shared" "0" \
  "$([[ -f "$LBASE/shared/bootstrap/cache/config.php" ]] && echo 1 || echo 0)"
# Y las escribe el usuario de la APP, no el fetcher. Desde §5.3 la release es
# del usuario de la app, así que 'as_deploy' aquí es permiso denegado sobre
# bootstrap/cache/ y el despliegue aborta: con el aislamiento puesto —o sea,
# en toda app creada desde la v1.0.3— Laravel no se podía desplegar en
# absoluto. Salió desplegando un Laravel de verdad en un VPS. Los tres pasos
# de artisan tienen que ir con el mismo sombrero; los otros dos ya lo hacían.
check "las cachés las escribe el usuario de la app" "1" \
  "$(( $(grep -c '^as_app .*config:cache' "$QUIEN_LOG") > 0 ? 1 : 0 ))"
check "y no el fetcher"                             "0" \
  "$(grep -c '^as_deploy .*config:cache' "$QUIEN_LOG")"
check "storage:link, igual"                         "1" \
  "$(( $(grep -c '^as_app .*storage:link' "$QUIEN_LOG") > 0 ? 1 : 0 ))"
# El fetcher sigue siendo quien trae el código: si esto se fuera a as_app,
# las credenciales de git dejarían de estar donde el clon las busca.
check "pero el código lo sigue trayendo el fetcher" "1" \
  "$(( $(grep -c '^as_deploy .*git ' "$QUIEN_LOG") > 0 ? 1 : 0 ))"

section "Laravel en una subcarpeta: todo se resuelve donde vive la app"
# El repositorio con la API en backend/ y el frontend al lado. Antes de esto no
# casaba con ninguna rama de detect_stack y acababa en la de repuesto: nginx
# sirviendo el repositorio entero con php-fpm ejecutando los .php que hubiera
# dentro. Aquí no se comprueba la detección —eso es detect_test— sino lo que
# viene después: que el enlace de storage, artisan, public/storage y el docroot
# del vhost apunten a backend/ y no a la raíz de la release.
LARM="$TMP/laravelmono"
git init -q -b main "$LARM"
git -C "$LARM" config user.email orbit@test
git -C "$LARM" config user.name Orbit
mkdir -p "$LARM/frontend"
echo '{"devDependencies":{"vite":"6"},"scripts":{"build":"vite build"}}' > "$LARM/frontend/package.json"
# El mismo Laravel de arriba, movido a backend/. Se copia en vez de rehacerlo
# para que el 'artisan' que se ejerce sea exactamente el mismo doble.
mkdir -p "$LARM/backend"
cp -a "$LAR/artisan" "$LAR/composer.json" "$LARM/backend/"
mkdir -p "$LARM/backend/bootstrap/cache" "$LARM/backend/public"
cp -a "$LAR/bootstrap/app.php" "$LARM/backend/bootstrap/app.php"
cp -a "$LAR/public/index.php"  "$LARM/backend/public/index.php"
mkdir -p "$LARM/backend/storage/app/public" "$LARM/backend/storage/framework/views" \
         "$LARM/backend/storage/framework/cache/data" \
         "$LARM/backend/storage/framework/sessions" "$LARM/backend/storage/logs"
find "$LARM/backend/storage" -type d -exec sh -c 'printf "*\n!.gitignore\n" > "$1/.gitignore"' _ {} \;
git -C "$LARM" add -A -f >/dev/null 2>&1
git -C "$LARM" commit -qm "monorepo"

# La configuración sale de la detección de verdad y no de valores escritos a
# mano: así esta prueba se pone en rojo también si detect_stack deja de poner
# A_APPDIR o el docroot. Lo único que se sustituye es el build, porque aquí no
# hay composer — y se sustituye por algo que **apunta dónde ha corrido**, que es
# justo lo que hay que comprobar del 'cd' que añade la detección.
{
  detect_stack "$LARM" >/dev/null 2>&1
  A_NAME="mono"; A_REPO="$LARM"; A_BRANCH="main"; A_DOMAIN="mono.test"
  A_ALIASES=""; A_PORT=""; A_BUILD="cd backend && pwd > cwd.txt"
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
}
check "la detección deja la subcarpeta" "backend"        "$A_APPDIR"
check "y el docroot dentro"             "backend/public" "$A_DOCROOT"
save_app
MBASE="$TMP/apps/mono"

run cmd_deploy mono >"$TMP/mono1" 2>&1; r=$?
[[ "$r" == 0 ]] || sed 's/^/      /' "$TMP/mono1" | tail -20
check "despliega"              "0" "$r"
# El build arranca en la raíz de la release (_build_run hace cd "$rel"), así que
# el 'cd backend' de A_BUILD es lo único que lo mete donde toca.
check "el build corre en backend" "$(readlink -f "$MBASE/current")/backend" \
  "$(cat "$MBASE/current/backend/cwd.txt" 2>/dev/null)"
# El storage compartido es el de Laravel, que está en backend/. Si esto se
# enlaza en la raíz, la app escribe dentro de la release y lo pierde todo en el
# despliegue siguiente — el bug que ya costó una sección entera, otra vez.
check "storage enlazado en backend" "$MBASE/shared/storage" \
  "$(readlink "$MBASE/current/backend/storage")"
check "y no en la raíz"        "0" "$([[ -e "$MBASE/current/storage" ]] && echo 1 || echo 0)"
check "con su esqueleto"       "1" "$([[ -d "$MBASE/shared/storage/framework/views" ]] && echo 1 || echo 0)"
# artisan apunta su getcwd() en artisan.log: es la prueba directa de dónde se ha
# ejecutado. En la raíz no debe haber ninguno.
check "artisan corrió en backend" "1" \
  "$([[ -f "$MBASE/current/backend/artisan.log" ]] && echo 1 || echo 0)"
check "y no en la raíz"        "0" \
  "$([[ -f "$MBASE/current/artisan.log" ]] && echo 1 || echo 0)"
check "con storage:link"       "1" "$(grep -c '^storage:link --force$' "$MBASE/current/backend/artisan.log")"
check "y config:cache"         "1" "$(grep -c '^config:cache$' "$MBASE/current/backend/artisan.log")"
check "public/storage dentro"  "1" \
  "$([[ -L "$MBASE/current/backend/public/storage" ]] && echo 1 || echo 0)"
check "APP_KEY generada"       "1" "$(grep -c '^APP_KEY=base64:' "$MBASE/shared/.env")"
# Y el docroot del vhost: es lo que separa «sirve la app» de «publica el
# repositorio». Se mira el fichero generado, no la variable.
check "nginx apunta a backend/public" "1" \
  "$(grep -c "^    root $MBASE/current/backend/public;$" "$TMP/vhost-mono.conf")"

section "Go en una subcarpeta: el ejecutable se busca donde vive la app"
# El paso 4c aborta el despliegue cuando el build sale con 0 y no deja binario
# —'go build' sobre un paquete que no es 'main' hace justo eso—. Miraba en la
# raíz de la release, así que con la app en backend/ la comprobación no medía
# nada: o fallaba siempre, o habría que dejar el binario donde nadie lo arranca.
# Se comprueba en las dos direcciones, que es lo único que fija la ruta.
GOREL="$TMP/gorepo"
git init -q -b main "$GOREL"
git -C "$GOREL" config user.email orbit@test; git -C "$GOREL" config user.name Orbit
mkdir -p "$GOREL/backend"
printf 'module ejemplo\ngo 1.22\n'     > "$GOREL/backend/go.mod"
printf 'package main\nfunc main(){}\n' > "$GOREL/backend/main.go"
git -C "$GOREL" add -A >/dev/null 2>&1; git -C "$GOREL" commit -qm "go"

{
  detect_stack "$GOREL" >/dev/null 2>&1
  A_NAME="gomono"; A_REPO="$GOREL"; A_BRANCH="main"; A_DOMAIN="gomono.test"
  A_ALIASES=""; A_PORT="$NGINX_HTTP_PORT"
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
  # No hay toolchain de Go aquí, y no hace falta: lo que se comprueba es dónde
  # busca Orbit el binario, no que Go compile. El build deja el ejecutable justo
  # donde lo dejaría 'go build -o bin/app' dentro de backend/.
  A_BUILD='cd backend && mkdir -p bin && printf "#!/bin/sh\nexit 0\n" > bin/app && chmod +x bin/app'
}
check "la detección lo ve en backend" "backend" "$A_APPDIR"
save_app
run cmd_deploy gomono >"$TMP/go1" 2>&1; r=$?
[[ "$r" == 0 ]] || sed 's/^/      /' "$TMP/go1" | tail -15
check "con el binario dentro, despliega" "0" "$r"
check "y está donde dice"      "1" \
  "$([[ -x "$TMP/apps/gomono/current/backend/bin/app" ]] && echo 1 || echo 0)"

# Y al revés: un binario en la raíz de la release no vale. Si esta comprobación
# pasara, la ruta del paso 4c daría igual — y el binario que systemd arranca es
# el de dentro.
load_app gomono
A_BUILD='mkdir -p bin && printf "#!/bin/sh\nexit 0\n" > bin/app && chmod +x bin/app'
save_app
sleep 1
git -C "$GOREL" commit -q --allow-empty -m "sin binario dentro"
run cmd_deploy gomono >"$TMP/go2" 2>&1; r=$?
check "en la raíz no cuenta"   "1" "$r"
check "y lo dice"              "1" "$(grep -c 'no ha dejado ningún ejecutable' "$TMP/go2")"
check "producción intacta"     "1" \
  "$([[ -x "$TMP/apps/gomono/current/backend/bin/app" ]] && echo 1 || echo 0)"

# El .env también se enlaza dentro de la app, no sólo en la raíz de la release:
# un framework que lo lea junto a su manifiesto no vería el de la raíz.
check ".env dentro de la app"  "$TMP/apps/gomono/shared/.env" \
  "$(readlink "$TMP/apps/gomono/current/backend/.env")"

for _k in "${ORBIT_APP_FIELDS[@]}"; do printf -v "$_k" '%s' ""; done

# Las secciones de abajo montan su app escribiendo las A_* a mano, y ninguna
# escribe A_APPDIR porque hasta ahora siempre valía '.'. Dejarlo en 'backend'
# se lo colaría a todas: save_app guarda lo que haya en la variable, y el
# despliegue siguiente buscaría su app dentro de un backend/ que no existe. Es
# exactamente el fallo que describe el comentario de ORBIT_APP_FIELDS, sólo que
# provocado por la prueba. Se limpia igual que lo hace load_app.
for _k in "${ORBIT_APP_FIELDS[@]}"; do printf -v "$_k" '%s' ""; done

section "Laravel: si la web no responde, se vuelve atrás"
# Una app Laravel no lleva unidad, así que no pasa por el health check del paso
# 6 ni por su rollback: una release que compilaba bien y reventaba **al servir**
# se publicaba y se quedaba. Aquí se comprueba su equivalente contra el servidor
# de arriba, con el curl de verdad y sin sustituir la comprobación por nada.

# Con la web contestando, el despliegue sigue su curso.
sleep 1
git -C "$LAR" commit -q --allow-empty -m "sana"
run cmd_deploy tienda >"$TMP/lar3" 2>&1; r=$?
check "con la web viva, despliega" "0" "$r"
check "y lo dice"                  "1" "$(grep -c 'La web responde' "$TMP/lar3")"
BUENA="$(basename "$(readlink -f "$LBASE/current")")"

# Y con la web devolviendo 500, se deshace el symlink.
echo 500 > "$CODEFILE"
sleep 1
git -C "$LAR" commit -q --allow-empty -m "rota"
: > "$SYSCTL_LOG"
run cmd_deploy tienda >"$TMP/lar4" 2>&1; r=$?
cp "$SYSCTL_LOG" "$TMP/sysctl-rb"
check "con la web rota, aborta"    "1" "$r"
check "y vuelve a la anterior"     "$BUENA" "$(basename "$(readlink -f "$LBASE/current")")"
# Y php-fpm otra vez al volver atrás: su caché apunta ya a la release rota, así
# que sin recargar la web se queda en 500 con el symlink bien puesto. Medido.
check "y recarga php-fpm al volver" "2" "$(grep -c "^reload php${PHP_VER}-fpm$" "$TMP/sysctl-rb")"
check "lo dice con el código"      "1" "$(grep -c 'La web devuelve 500' "$TMP/lar4")"
check "y anuncia el rollback"      "1" "$(grep -c 'Restaurada la release anterior' "$TMP/lar4")"

# En mantenimiento un 503 es la respuesta correcta, no un fallo: si esto no se
# salta, no se puede desplegar el arreglo de una web que está caída a propósito.
echo 503 > "$CODEFILE"
: > "$(maint_flag tienda)"
sleep 1
git -C "$LAR" commit -q --allow-empty -m "en mantenimiento"
run cmd_deploy tienda >"$TMP/lar5" 2>&1; r=$?
check "en mantenimiento no comprueba" "0" "$r"
check "y lo dice"                     "1" "$(grep -c 'me salto la comprobación de salud' "$TMP/lar5")"
rm -f "$(maint_flag tienda)"
# Lo mismo con la bandera de Laravel, que vive en shared/ y sobrevive al deploy.
mkdir -p "$LBASE/shared/storage/framework"
: > "$LBASE/shared/storage/framework/maintenance.php"
sleep 1
git -C "$LAR" commit -q --allow-empty -m "artisan down"
run cmd_deploy tienda >"$TMP/lar6" 2>&1; r=$?
check "y con 'artisan down' tampoco" "0" "$r"
rm -f "$LBASE/shared/storage/framework/maintenance.php"

# Y si no contesta nadie, tampoco vale. Esta es la que faltaba: con un servidor
# vivo al otro lado nunca se ejercitaba la rama de «no conecta», y ahí había un
# fallo de verdad —curl escribe '000' por -w **y** sale con 7, así que un
# '|| printf 000' detrás daba '000000' y eso no casaba con ningún patrón de
# fallo—. Lo encontró un despliegue de prueba con nginx en otro puerto.
kill "$HPID" 2>/dev/null
sleep 1
git -C "$LAR" commit -q --allow-empty -m "sin nadie escuchando"
run cmd_deploy tienda >"$TMP/lar7" 2>&1; r=$?
check "sin nadie escuchando, aborta" "1" "$r"
check "y lo dice como 000"           "1" "$(grep -c 'La web devuelve 000\b' "$TMP/lar7")"

NGINX_HTTP_PORT=80
fi

section "PHP y estáticas con PHP: la misma red de seguridad"
# Las tres formas de que php-fpm ejecute las páginas —laravel, php a secas, y
# una estática con un .php dentro— se sirven desde disco a través del mismo
# symlink, así que las tres necesitan lo mismo: que php-fpm se entere del cambio
# y que alguien compruebe que la web sigue en pie. Esta parte no necesita php
# instalado: la comprobación es curl contra nginx, no artisan.
PCODE="$TMP/phpcode"; echo 200 > "$PCODE"
_srv_start "$PCODE" "$TMP/phpport"; PSRVPID=$!
NGINX_HTTP_PORT="$(cat "$TMP/phpport")"

PORIGIN="$TMP/phporigin"
git init -q -b main "$PORIGIN"
git -C "$PORIGIN" config user.email o@t; git -C "$PORIGIN" config user.name O
printf '<?php echo "hola";\n' > "$PORIGIN/index.php"
printf 'portada\n'            > "$PORIGIN/index.html"
git -C "$PORIGIN" add -A; git -C "$PORIGIN" commit -qm "inicial"

# Una app PHP a secas y una estática con un .php dentro. La segunda es el caso
# de §18.7 —un Astro con su formulario de contacto— y hasta ahora tampoco tenía
# quien mirase si el despliegue la había dejado en pie.
for caso in "php:phpapp::" "static:phpstatic:.:yes"; do
  IFS=: read -r tipo app outdir conphp <<<"$caso"
  {
    A_NAME="$app"; A_REPO="$PORIGIN"; A_BRANCH="main"; A_DOMAIN="$app.test"
    A_ALIASES=""; A_TYPE="$tipo"; A_PKG="pnpm"; A_BUILD=""; A_START=""
    A_OUTDIR="$outdir"; A_SPA="no"; A_PORT=""; A_DOCROOT="."; A_PHP="$conphp"
    A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
  }
  save_app
  PBASE="$TMP/apps/$app"

  echo 200 > "$PCODE"; : > "$SYSCTL_LOG"
  run cmd_deploy "$app" >"$TMP/p-$app-1" 2>&1; r=$?
  [[ "$r" == 0 ]] || sed 's/^/      /' "$TMP/p-$app-1"
  check "$tipo: despliega"        "0" "$r"
  check "$tipo: recarga php-fpm"  "1" "$(grep -c "^reload php${PHP_VER}-fpm$" "$SYSCTL_LOG")"
  check "$tipo: comprueba la web" "1" "$(grep -c 'La web responde' "$TMP/p-$app-1")"
  PBUENA="$(basename "$(readlink -f "$PBASE/current")")"

  echo 500 > "$PCODE"
  sleep 1
  git -C "$PORIGIN" commit -q --allow-empty -m "rota $app"
  run cmd_deploy "$app" >"$TMP/p-$app-2" 2>&1; r=$?
  check "$tipo: con 500, aborta"  "1" "$r"
  check "$tipo: y vuelve atrás"   "$PBUENA" "$(basename "$(readlink -f "$PBASE/current")")"
done

# Y una estática **sin** PHP no pasa por nada de esto: nginx le sirve ficheros y
# no hay ninguna caché de por medio, así que ni se recarga php-fpm ni se
# comprueba nada. Aquí importa lo que NO se hace.
{
  A_NAME="soloficheros"; A_REPO="$PORIGIN"; A_BRANCH="main"; A_DOMAIN="soloficheros.test"
  A_ALIASES=""; A_TYPE="static"; A_PKG="pnpm"; A_BUILD=""; A_START=""
  A_OUTDIR="."; A_SPA="no"; A_PORT=""; A_DOCROOT=""; A_PHP=""
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
}
save_app
echo 500 > "$PCODE"; : > "$SYSCTL_LOG"
run cmd_deploy soloficheros >"$TMP/p-solo" 2>&1; r=$?
check "estática sin php: despliega igual" "0" "$r"

section "Lo que el repositorio declara como dato sobrevive al despliegue"
# La trampa de quien viene de un hosting clásico: allí el directorio es el mismo
# para siempre, aquí la release se rehace entera. Todo lo que la app escriba
# dentro —credenciales puestas a mano, mensajes sin entregar, estadísticas—
# desaparece en el segundo despliegue, y la web sigue funcionando, así que no se
# nota hasta que se busca un dato y no está.
printf 'semilla del repo\n' > "$PORIGIN/datos.txt"
mkdir -p "$PORIGIN/subidas"; printf '*\n' > "$PORIGIN/subidas/.gitignore"
git -C "$PORIGIN" add -A; git -C "$PORIGIN" commit -qm "con datos"
{
  A_NAME="condatos"; A_REPO="$PORIGIN"; A_BRANCH="main"; A_DOMAIN="condatos.test"
  A_ALIASES=""; A_TYPE="php"; A_PKG="pnpm"; A_BUILD=""; A_START=""
  A_OUTDIR=""; A_SPA="no"; A_PORT=""; A_DOCROOT="."; A_PHP=""
  A_SHARED="datos.txt subidas secretos/clave.txt"
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
}
save_app
DBASE="$TMP/apps/condatos"
echo 200 > "$PCODE"
run cmd_deploy condatos >"$TMP/d1" 2>&1; r=$?
[[ "$r" == 0 ]] || sed 's/^/      /' "$TMP/d1"
check "despliega"                "0" "$r"
# Lo que el repositorio trae se usa de semilla; lo que no trae se crea vacío.
check "el fichero es un enlace"  "$DBASE/shared/datos.txt" "$(readlink "$DBASE/current/datos.txt")"
check "y conserva la semilla"    "semilla del repo" "$(cat "$DBASE/current/datos.txt")"
check "la carpeta es un enlace"  "$DBASE/shared/subidas"   "$(readlink "$DBASE/current/subidas")"
# Una ruta que el repo no trae se crea igual, con sus carpetas intermedias.
check "lo que no trae, se crea"  "1" "$([[ -e "$DBASE/shared/secretos/clave.txt" ]] && echo 1 || echo 0)"
check "y también está enlazado"  "$DBASE/shared/secretos/clave.txt" "$(readlink "$DBASE/current/secretos/clave.txt")"

# Ahora lo que de verdad importa: escribir como escribiría la app, y desplegar.
printf 'CONTRASENA-DE-VERDAD\n' > "$DBASE/current/secretos/clave.txt"
printf 'un CV\n'                > "$DBASE/current/subidas/candidato.pdf"
printf 'editado en produccion\n' > "$DBASE/current/datos.txt"
sleep 1
git -C "$PORIGIN" commit -q --allow-empty -m "otra vez"
run cmd_deploy condatos >"$TMP/d2" 2>&1; r=$?
check "segundo despliegue"       "0" "$r"
check "la contraseña sigue"      "CONTRASENA-DE-VERDAD" "$(cat "$DBASE/current/secretos/clave.txt" 2>/dev/null)"
check "el CV sigue"              "un CV"                "$(cat "$DBASE/current/subidas/candidato.pdf" 2>/dev/null)"
# Y lo editado en producción gana: la semilla es semilla, no una plantilla que
# se reimponga en cada despliegue.
check "y no se pisa con la semilla" "editado en produccion" "$(cat "$DBASE/current/datos.txt" 2>/dev/null)"

# Una ruta que se sale del directorio de la app no se enlaza: acabaría en el
# vhost y en un 'rm -rf'.
load_app condatos
A_SHARED="../fuera ruta/../../mala /etc/passwd bien.txt"
save_app
sleep 1
git -C "$PORIGIN" commit -q --allow-empty -m "rutas raras"
run cmd_deploy condatos >"$TMP/d3" 2>&1; r=$?
check "las rutas raras no paran el despliegue" "0" "$r"
check "y se dicen una a una"     "3" "$(grep -c 'shared: me salto' "$TMP/d3")"
check "la buena sí se enlaza"    "$DBASE/shared/bien.txt" "$(readlink "$DBASE/current/bien.txt")"
check "y nada fuera de la app"   "0" "$([[ -e "$TMP/apps/fuera" ]] && echo 1 || echo 0)"

kill "$PSRVPID" 2>/dev/null
NGINX_HTTP_PORT=80

section "Eliminar sin nadie delante"
run cmd_clone web borrame --domain borrame.test >/dev/null 2>&1
check "hay algo que borrar" "1"    "$(app_exists borrame && echo 1 || echo 0)"
mkdir -p "$TMP/apps/borrame/shared"; echo secreto > "$TMP/apps/borrame/shared/.env"
run cmd_remove borrame --yes >"$TMP/rm1" 2>&1; r=$?
check "borra la app"      "0"      "$r"
check "y su configuración" "0"     "$(app_exists borrame && echo 1 || echo 0)"
# --yes es «no preguntes», no «y además llévate el .env y las subidas».
check "pero no los datos" "1"      "$([[ -f "$TMP/apps/borrame/shared/.env" ]] && echo 1 || echo 0)"
check "y avisa de dónde están" "1" "$(grep -c 'siguen en' "$TMP/rm1")"

run cmd_clone web borrame2 --domain borrame2.test >/dev/null 2>&1
mkdir -p "$TMP/apps/borrame2/shared"; echo secreto > "$TMP/apps/borrame2/shared/.env"
run cmd_remove borrame2 --yes --purge >/dev/null 2>&1; r=$?
check "con --purge borra todo" "0" "$r"
check "sin carpeta"       "0"      "$([[ -d "$TMP/apps/borrame2" ]] && echo 1 || echo 0)"
check "queda en el log"   "1"      "$(grep -c 'remove borrame2 purge=yes' "$TMP/orbit.log")"

run cmd_remove --yes >/dev/null 2>&1; r=$?
check "sin app, no adivina" "1"    "$r"
run cmd_remove web --loquesea >/dev/null 2>&1; r=$?
check "opción desconocida" "1"     "$r"
check "y web sigue ahí"   "1"      "$(app_exists web && echo 1 || echo 0)"

section "Cambio de rama inexistente"
load_app web
A_BRANCH="no-existe"
save_app
run cmd_deploy web >"$TMP/out4" 2>&1; r=$?
check "aborta" "1" "$r"
check "sugiere qué mirar" "1" "$(grep -c "orbit github" "$TMP/out4")"

# ═══════════════════════════════════════════════════════════════════════════
#  orbit deploy --json
#
#  La regla que se prueba aquí, y que es la que hace útil todo el contrato:
#  por stdout va **un objeto y nada más**. Ni un ✔, ni una raya, ni el volcado
#  de un build que ha fallado.
# ═══════════════════════════════════════════════════════════════════════════
load_app web; A_BRANCH="main"; save_app
if ! command -v jq >/dev/null; then
  echo "jq no está: me salto las comprobaciones de --json del despliegue."
else

section "El resultado es un objeto y nada más"
sleep 1; publish "version json"
ANTERIOR="$(current_release)"    # la que está sirviendo justo antes de este despliegue
JSON="yes"; _ui_route
run cmd_deploy web >"$TMP/j1" 2>"$TMP/j1err"; r=$?
check "termina bien"      "0"      "$r"
check "stdout es JSON"    "object" "$(jq -r 'type' < "$TMP/j1")"
check "una sola línea"    "1"      "$(wc -l < "$TMP/j1")"
# Lo que se le cuenta a una persona no puede haberse colado en el objeto.
check "sin ✓ en stdout"   "0"      "$(grep -c '✓' "$TMP/j1")"
check "sin rayas"         "0"      "$(grep -c '─' "$TMP/j1")"
# …pero tiene que seguir estando, en stderr, para quien mire el log.
check "y sí en stderr"    "1"      "$([[ -s "$TMP/j1err" ]] && echo 1 || echo 0)"

section "Lo que dice el objeto"
check "de qué app"        "web"    "$(jq -r '.app'      < "$TMP/j1")"
check "ha ido bien"       "true"   "$(jq -r '.ok'       < "$TMP/j1")"
check "qué release"       "$(current_release)" "$(jq -r '.release' < "$TMP/j1")"
check "de qué commit"     "$(git -C "$ORIGIN" rev-parse --short HEAD)" \
                                   "$(jq -r '.commit.sha' < "$TMP/j1")"
check "y su asunto"       "version json" "$(jq -r '.commit.subject' < "$TMP/j1")"
check "sin rollback"      "false"  "$(jq -r '.rolled_back' < "$TMP/j1")"
check "sin recuperación"  "false"  "$(jq -r '.recovered'   < "$TMP/j1")"
check "sin error"         "null"   "$(jq -r '.error'       < "$TMP/j1")"
check "lleva el esquema"  "1"      "$(jq -r '.schema'      < "$TMP/j1")"
# La release anterior, para que un panel pueda ofrecer el rollback sin
# tener que ir a buscarla con otra llamada.
check "y la anterior"     "$ANTERIOR" "$(jq -r '.previous' < "$TMP/j1")"

section "Un despliegue que falla también contesta"
# Es lo que más falta hace: sin objeto, el cliente tiene un código de salida y
# un texto en castellano pensado para una persona, y no sabe dónde se rompió.
load_app web; A_BRANCH="tampoco-existe"; save_app
run cmd_deploy web >"$TMP/j2" 2>"$TMP/j2err"; r=$?
check "falla"             "1"      "$r"
check "pero contesta"     "object" "$(jq -r 'type' < "$TMP/j2")"
check "y dice que no"     "false"  "$(jq -r '.ok'   < "$TMP/j2")"
check "en qué paso"       "code"   "$(jq -r '.failed_step' < "$TMP/j2")"
check "stdout sigue limpio" "1"    "$(wc -l < "$TMP/j2")"
load_app web; A_BRANCH="main"; save_app

section "Sin nombre de app no se inventa nada"
# 'pick_app' preguntaría por stdout, que es justo donde va el objeto — y al
# otro lado no hay nadie que conteste.
run cmd_deploy >"$TMP/j3" 2>"$TMP/j3err"; r=$?
check "aborta"            "1"      "$r"
check "y lo explica"      "1"      "$(grep -c 'necesita el nombre' "$TMP/j3err")"
check "sin preguntar"     "0"      "$(grep -c 'App a desplegar' "$TMP/j3")"

section "El progreso va aparte, y sólo si se pide"
sleep 1; publish "version progreso"
PROGRESS="no"
run cmd_deploy web >"$TMP/j4" 2>"$TMP/j4err"
check "sin --progress, ni un suceso" "0" "$(grep -c '"event"' "$TMP/j4err")"
sleep 1; publish "version progreso dos"
PROGRESS="yes"
run cmd_deploy web >"$TMP/j5" 2>"$TMP/j5err"
check "con --progress, sucesos"  "1" "$([[ "$(grep -c '"event"' "$TMP/j5err")" -gt 0 ]] && echo 1 || echo 0)"
# Cada suceso es una línea de JSON por su cuenta: así se puede leer según llega.
check "cada uno es JSON"  "0" "$(grep '"event"' "$TMP/j5err" | jq -e . >/dev/null 2>&1; echo $?)"
# Cada paso emite dos sucesos, 'start' y 'ok': con sólo uno de los dos no se
# podría dibujar una barra que avanza, que es para lo que existe esto.
check "el paso empieza"   "1" "$(grep -c '"step":"code","status":"start"' "$TMP/j5err")"
check "y termina"         "1" "$(grep -c '"step":"code","status":"ok"' "$TMP/j5err")"
# Y el objeto de stdout sigue siendo uno solo: el progreso no lo ensucia.
check "stdout intacto"    "1" "$(wc -l < "$TMP/j5")"
check "y sigue siendo válido" "object" "$(jq -r 'type' < "$TMP/j5")"
PROGRESS="no"

section "La espera de salud no ensucia el objeto"
# Codex, revisando el PR: 'health_wait' escribia la cabecera, los puntos y el
# salto de linea directamente en stdout. Con --json eso va DELANTE del objeto y
# 'jq' no puede analizarlo. No lo cazo ninguna prueba porque todas usaban una
# app estatica, que no tiene servicio y nunca pasa por ahi.
#
# Se llama a la funcion directamente y con un plazo de 1 s: es ella la que
# estaba mal, y hacerlo por el despliegue entero costaria 40 s de espera real
# por caso sin comprobar nada mas.
curl() { return 1; }        # el puerto no contesta: se agota el plazo
JSON="yes"; _ui_route
SALIDA="$(health_wait 3999 1 2>"$TMP/hw1err")"
check "stdout vacio"        "0" "$(printf '%s' "$SALIDA" | wc -c)"
check "y la espera, en stderr" "1" "$(grep -c 'Comprobando salud' "$TMP/hw1err")"
# Sin --json tiene que seguir saliendo por donde salia.
JSON="no"; _ui_route
SALIDA="$(health_wait 3999 1 2>/dev/null)"
check "sin --json, a stdout" "1" "$(grep -c 'Comprobando salud' <<<"$SALIDA")"

section "Sin release anterior no hay rollback que anunciar"
# Codex: en el primer despliegue de una app 'prev' esta vacio, no se restaura
# nada y 'current' se queda apuntando a la release rota. Decir rolled_back ahi
# le haria creer a quien automatiza que produccion esta a salvo.
#
# 'sleep' se anula mientras dure esto: health_wait espera un segundo por
# vuelta y aqui se agota el plazo dos veces a proposito.
needs_svc() { [[ "$1" == "node" ]]; }
journalctl() { :; }
sleep() { :; }
mkapp nueva node 3998 nueva.test
load_app nueva; A_REPO="$ORIGIN"; A_BRANCH="main"; A_TYPE="node"; A_START="true"; save_app
JSON="yes"; _ui_route
run cmd_deploy nueva >"$TMP/js1" 2>"$TMP/js1err"; r=$?
check "falla"               "1"      "$r"
check "stdout sigue siendo JSON" "object" "$(jq -r 'type' < "$TMP/js1" 2>/dev/null || echo NO)"
check "una sola linea"      "1"      "$(wc -l < "$TMP/js1")"
check "no dice rollback"    "false"  "$(jq -r '.rolled_back' < "$TMP/js1")"
check "dice donde fallo"    "service" "$(jq -r '.failed_step' < "$TMP/js1")"
check "y lo explica"        "1"      "$(jq -r '.error' < "$TMP/js1" | grep -c 'no había release anterior')"

# Con una release anterior si se restaura, y entonces si se dice.
unset -f curl                       # este despliegue tiene que salir bien
JSON="no"; _ui_route
run cmd_deploy nueva >/dev/null 2>&1
check "la segunda vez si despliega" "1" "$([[ -L "$TMP/apps/nueva/current" ]] && echo 1 || echo 0)"
curl() { return 1; }                # y ahora vuelve a no responder
JSON="yes"; _ui_route
run cmd_deploy nueva >"$TMP/js2" 2>/dev/null
check "ahora si hay rollback" "true" "$(jq -r '.rolled_back' < "$TMP/js2")"
unset -f curl; unset -f needs_svc; unset -f journalctl; unset -f sleep
JSON="no"; _ui_route

section "Reinicio sin corte: el viejo no se retira hasta que el nuevo responde"
# La frase del roadmap hecha secuencia, y lo que se afirma es el ORDEN, que es
# lo único que separa «sin corte» de «con corte»: si el restart de la unidad
# canónica se adelantara al health check del puente —que es exactamente el
# código de antes—, la primera comprobación de orden se pone en rojo.
needs_svc() { [[ "$1" == "node" ]]; }
journalctl() { :; }
sleep() { :; }
SEQ="$TMP/overlap.seq"; : > "$SEQ"
# 'is-active' contesta que sí: aquí la app está «corriendo» y toca solaparse.
systemctl() {
  printf '%s\n' "$*" >> "$SYSCTL_LOG"
  printf 'sysctl %s\n' "$*" >> "$SEQ"
  return 0
}
# Cada render apunta a qué puerto mandaría nginx el tráfico, leído del vhost
# de verdad y no de una variable: es lo que un visitante recibiría.
render_nginx() {
  nginx_vhost "$1" > "$TMP/vhost-$1.conf"
  printf 'nginx %s\n' "$(grep -o 'proxy_pass http://127.0.0.1:[0-9]*' "$TMP/vhost-$1.conf" \
                         | head -1 | grep -o '[0-9]*$')" >> "$SEQ"
}
# Las sondas de salud también se apuntan: el health check de la canónica
# tiene que medir el puerto de la CANÓNICA. La primera versión medía el del
# puente —nginx_vhost pisa la A_PORT global al aplicar el override— y daba
# por sana una unidad que quizá ni había arrancado; lo cazó la revisión del
# PR #9, no esta suite, porque nadie miraba a qué puerto se preguntaba.
curl() { printf 'curl %s\n' "$*" >> "$SEQ"; return 0; }
# El drenaje también se apunta: 'systemctl reload' vuelve cuando entrega la
# señal, no cuando el cambio está aplicado, así que entre mover nginx y parar
# el proceso al que ya no apunta tiene que haber una espera. Sin ella las
# peticiones en vuelo contra ese puerto mueren: medido en un VPS de verdad,
# 1-2 respuestas 502 por despliegue con el reinicio «sin corte» puesto.
nginx_drain() { printf 'drain\n' >> "$SEQ"; }
free_port() { echo 4999; }  # determinista: el del sistema depende del entorno
publish "solape uno"
mkapp fluida node 3997 fluida.test
load_app fluida; A_REPO="$ORIGIN"; A_BRANCH="main"; A_TYPE="node"; A_START="true"; save_app
run cmd_deploy fluida >/dev/null 2>&1; r=$?
check "despliega"            "0" "$r"
_seq() { grep -n "$1" "$SEQ" | head -1 | cut -d: -f1; }
N_START="$(_seq '^sysctl start orbit-fluida-next$')"
N_FLIP="$(_seq '^nginx 4999$')"
N_RESTART="$(_seq '^sysctl restart orbit-fluida$')"
N_BACK="$(_seq '^nginx 3997$')"
N_STOP="$(_seq '^sysctl stop orbit-fluida-next$')"
check "el puente arranca"    "1" "$([[ -n "$N_START" ]] && echo 1 || echo 0)"
check "nginx sólo se mueve con el puente vivo" "1" \
  "$(( ${N_START:-999} < ${N_FLIP:-0} ? 1 : 0 ))"
check "la canónica se reinicia con el tráfico en el puente" "1" \
  "$(( ${N_FLIP:-999} < ${N_RESTART:-0} ? 1 : 0 ))"
check "nginx vuelve al puerto canónico" "1" \
  "$(( ${N_RESTART:-999} < ${N_BACK:-0} ? 1 : 0 ))"
check "y sólo entonces se retira el puente" "1" \
  "$(( ${N_BACK:-999} < ${N_STOP:-0} ? 1 : 0 ))"
# Mover nginx no basta: hay que esperar a que los workers viejos —los que
# todavía tienen la configuración vieja— terminen antes de parar el proceso
# al que apuntaban. Las dos mitades del relevo tienen la misma frontera.
N_DRAIN1="$(awk -v a="${N_FLIP:-0}" -v b="${N_RESTART:-0}" \
  'NR>a && NR<b && /^drain$/ {print NR; exit}' "$SEQ")"
N_DRAIN2="$(awk -v a="${N_BACK:-0}" -v b="${N_STOP:-0}" \
  'NR>a && NR<b && /^drain$/ {print NR; exit}' "$SEQ")"
check "nginx se drena antes de parar la canónica" "1" \
  "$([[ -n "$N_DRAIN1" ]] && echo 1 || echo 0)"
check "nginx se drena antes de retirar el puente" "1" \
  "$([[ -n "$N_DRAIN2" ]] && echo 1 || echo 0)"
check "la canónica nunca se paró" "0" "$(grep -c '^sysctl stop orbit-fluida$' "$SEQ")"
N_PROBE="$(awk -v n="${N_RESTART:-999}" 'NR>n && /^curl .*:3997\// {print NR; exit}' "$SEQ")"
check "y su salud se mide en SU puerto" "1" "$([[ -n "$N_PROBE" ]] && echo 1 || echo 0)"
check "la release nueva queda activa" "1" \
  "$(readlink -f "$TMP/apps/fluida/current" | grep -c 'releases/')"
check "el vhost final apunta a la app" "1" \
  "$(grep -c 'proxy_pass http://127.0.0.1:3997;' "$TMP/vhost-fluida.conf")"
check "el fichero del puente no queda" "0" \
  "$([[ -f "$(svc_next_unit fluida)" ]] && echo 1 || echo 0)"
# Sin hueco no hay mantenimiento: la página de obras es el parche del camino
# clásico, y encenderla aquí sería el corte que se acaba de quitar.
check "sin testigo de mantenimiento" "0" \
  "$([[ -f "$(maint_flag fluida)" ]] && echo 1 || echo 0)"

section "Reinicio sin corte: si el puente no responde, producción ni se toca"
# El otro final, que es el que justifica el diseño: una release rota se queda
# en el puente y el proceso viejo ni se entera. Antes de esto, la release rota
# paraba producción, fallaba el health check y había que restaurar; ahora el
# fallo ocurre ANTES de tocar nada, que es el principio 4 aplicado al reinicio.
PREV_REL="$(readlink -f "$TMP/apps/fluida/current")"
curl() { return 1; }        # el puente nunca responde
: > "$SYSCTL_LOG"; : > "$SEQ"
publish "solape dos"
JSON="yes"; _ui_route
run cmd_deploy fluida >"$TMP/ov1" 2>/dev/null; r=$?
JSON="no"; _ui_route
check "falla"                    "1" "$r"
check "la canónica no se reinició" "0" "$(grep -c '^restart orbit-fluida$' "$SYSCTL_LOG")"
check "ni se paró"               "0" "$(grep -c '^stop orbit-fluida$' "$SYSCTL_LOG")"
check "el puente sí se retira"   "1" "$(grep -c '^stop orbit-fluida-next$' "$SYSCTL_LOG")"
check "sin fichero del puente"   "0" "$([[ -f "$(svc_next_unit fluida)" ]] && echo 1 || echo 0)"
check "current vuelve a la release anterior" "$PREV_REL" \
  "$(readlink -f "$TMP/apps/fluida/current")"
check "rollback anunciado"       "true" "$(jq -r '.rolled_back' < "$TMP/ov1")"
check "donde falló"              "service" "$(jq -r '.failed_step' < "$TMP/ov1")"
check "y el motivo es el puente" "1" "$(jq -r '.error' < "$TMP/ov1" | grep -c 'release nueva')"

section "Un puente huérfano no se retira si la canónica no responde"
# El estado que deja el final «canónica sin puerto, puente sirviendo»: la
# unidad canónica sigue ACTIVA para is-active aunque no conteste, así que el
# despliegue siguiente entra por el camino del solape y se encuentra el
# huérfano. Retirarlo sin oír a la canónica —que es lo que hacía la primera
# versión, y lo cazó la revisión del PR #9— paraba el único proceso
# verificado que quedaba. Aquí la canónica calla y el resto responde.
echo "unidad huérfana" > "$(svc_next_unit fluida)"
curl() { [[ "$*" == *:3997/* ]] && return 1; return 0; }
: > "$SYSCTL_LOG"; : > "$SEQ"
publish "solape tres"
run cmd_deploy fluida >/dev/null 2>"$TMP/ov2err"; r=$?
check "aborta"                    "1" "$r"
check "el huérfano sigue ahí"     "1" "$([[ -f "$(svc_next_unit fluida)" ]] && echo 1 || echo 0)"
check "y nadie lo paró"           "0" "$(grep -c '^stop orbit-fluida-next$' "$SYSCTL_LOG")"
check "nginx ni se tocó"          "0" "$(grep -c '^nginx ' "$SEQ")"
check "y se dice por qué"         "1" "$(grep -c 'sigue sin responder' "$TMP/ov2err")"
rm -f "$(svc_next_unit fluida)"

section "Si nginx no recarga la vuelta, el puente se queda sirviendo"
# render_nginx devuelve 0 con la configuración escrita y válida aunque la
# recarga falle — está bien para los demás llamadores, pero el solape retiraba
# el puente con el nginx que corre aún apuntándole (revisión del PR #9). El
# doble reproduce exactamente eso: la recarga «falla» sólo al volver al puerto
# canónico, que es el único momento en el que importa distinguir escrita de
# aplicada.
curl() { return 0; }
render_nginx() {
  nginx_vhost "$1" > "$TMP/vhost-$1.conf"
  local p; p="$(grep -o 'proxy_pass http://127.0.0.1:[0-9]*' "$TMP/vhost-$1.conf" \
                | head -1 | grep -o '[0-9]*$')"
  NGINX_RELOAD_OK="yes"; [[ "$p" == "3997" ]] && NGINX_RELOAD_OK="no"
  printf 'nginx %s\n' "$p" >> "$SEQ"
}
: > "$SYSCTL_LOG"; : > "$SEQ"
publish "solape cuatro"
run cmd_deploy fluida >"$TMP/ov3out" 2>&1; r=$?
check "el despliegue no se da por bueno" "1" "$r"
check "el puente no se paró"      "0" "$(grep -c '^stop orbit-fluida-next$' "$SYSCTL_LOG")"
check "su unidad sigue escrita"   "1" "$([[ -f "$(svc_next_unit fluida)" ]] && echo 1 || echo 0)"
check "y se pide recargar nginx"  "1" "$(grep -c 'systemctl reload nginx' "$TMP/ov3out")"
# El huérfano que acaba de quedarse lo recogería el despliegue siguiente; aquí
# se recoge a mano para no contaminar lo que venga detrás.
rm -f "$(svc_next_unit fluida)"
NGINX_RELOAD_OK="yes"
unset -f curl; unset -f needs_svc; unset -f journalctl; unset -f sleep; unset -f free_port
systemctl() {
  printf '%s\n' "$*" >> "$SYSCTL_LOG"
  [[ "${1:-}" == "is-active" ]] && return 1
  return 0
}
render_nginx() { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }

section "--progress sin --json no tiene sentido"
JSON="no"; _ui_route
run cmd_deploy web --progress >/dev/null 2>"$TMP/j6err"; r=$?
check "aborta" "1" "$r"
check "y lo dice" "1" "$(grep -c 'sólo tiene sentido con --json' "$TMP/j6err")"

fi
JSON="no"; _ui_route

report
