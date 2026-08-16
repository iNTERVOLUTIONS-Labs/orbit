#!/usr/bin/env bash
# Copias de seguridad: qué se guarda, qué no, y que se pueda volver de ellas.
#   bash tests/backup_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, BACKUP_*…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
BACKUP_DIR="$TMP/backups"
BACKUP_KEEP=14
BACKUP_HOOK=""

# --- PostgreSQL de mentira --------------------------------------------------
# Lo que se prueba aquí es qué entra en el fichero y qué sale al restaurar, no
# PostgreSQL. Las llamadas quedan anotadas para poder comprobarlas.
PSQL="$TMP/psql.log"; : > "$PSQL"
DBS="$TMP/dbs"; : > "$DBS"       # bases que "existen"
ROLES="$TMP/roles"; : > "$ROLES" # roles que "existen"
sudo() { # sudo -u postgres <cmd> …
  local u=""
  while [[ "${1:-}" == -* ]]; do
    case "$1" in -u) u="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac
  done
  [[ "$u" == "postgres" ]] || { "$@"; return; }
  printf '%s\n' "$*" >> "$PSQL"
  case "${1:-}" in
    psql)
      # 'psql -q <base>' lee el volcado por la entrada, y 'psql -tAc/-qc' trae
      # la orden como argumento. Distinguirlos importa: drenar la entrada
      # cuando no la hay deja la prueba colgada esperando al teclado.
      local cmdform="no" arg
      for arg in "$@"; do [[ "$arg" == -*c ]] && cmdform="yes"; done
      [[ "$cmdform" == "yes" ]] || { cat >/dev/null 2>&1; return 0; }
      case "$*" in
        *"FROM pg_database"*) grep -qx "$(sed 's/.*datname=.\([^'"'"']*\).*/\1/' <<<"$*")" "$DBS" && echo 1 ;;
        *"FROM pg_roles"*)    grep -qx "$(sed 's/.*rolname=.\([^'"'"']*\).*/\1/' <<<"$*")" "$ROLES" && echo 1 ;;
        *"CREATE ROLE"*)      sed 's/.*CREATE ROLE .\([^"]*\)".*/\1/' <<<"$*" >> "$ROLES" ;;
      esac ;;
    # El volcado de mentira tiene que parecerse al de verdad en lo único que
    # Orbit mira para saber si está entero: la marca que pg_dump escribe **al
    # terminar**. Un volcado sin ella es, para Orbit, un volcado cortado — que
    # es justo lo que se quiere detectar. La estructura está copiada de un
    # pg_dump 16 de verdad, incluido el '\unrestrict' del final, que desde
    # 16.13 va DESPUÉS de la marca.
    pg_dump)  printf -- '--\n-- PostgreSQL database dump\n--\n\n\\restrict abc123\n\nCREATE TABLE cosas();\n\n--\n-- PostgreSQL database dump complete\n--\n\n\\unrestrict abc123\n\n' ;;
    createdb) printf '%s\n' "${*: -1}" >> "$DBS" ;;
  esac
  return 0
}
systemctl() { case "${1:-}" in is-active) [[ "${3:-}" == "postgresql" ]] ;; *) return 0 ;; esac; }

# --- una app con todo lo que se puede tener ---------------------------------
mkapp tienda next 3001 tienda.test "www.tienda.test"
load_app tienda; A_REPO="https://example.test/tienda.git"; A_PHP="yes"; save_app
mkdir -p "$TMP/apps/tienda/shared/uploads"
printf 'DATABASE_URL=postgresql://tienda:secreta123@127.0.0.1:5432/tienda\nAPI_KEY=abc\n' \
  > "$TMP/apps/tienda/shared/.env"
printf 'una foto\n' > "$TMP/apps/tienda/shared/uploads/foto.jpg"
printf '<h1>volvemos</h1>\n' > "$TMP/apps/tienda/shared/maintenance.html"
mkdir -p "$TMP/etc/redirects"
printf '/viejo /nuevo 301\n' > "$TMP/etc/redirects/tienda.list"
# Y una release, que NO debe acabar en la copia.
mkdir -p "$TMP/apps/tienda/releases/r1"
printf 'index\n' > "$TMP/apps/tienda/releases/r1/index.html"
ln -sfn "$TMP/apps/tienda/releases/r1" "$TMP/apps/tienda/current"
echo tienda > "$DBS"

section "Qué entra en la copia"
FICH="$(_backup_one tienda)"
check "se crea el fichero"  "1"  "$([[ -f "$FICH" ]] && echo 1 || echo 0)"
# Con secretos dentro, el fichero no puede ser legible por cualquiera.
check "permisos 0600"       "600" "$(stat -c '%a' "$FICH")"
DENTRO="$(tar tzf "$FICH" | sed 's|^\./||' | sort | tr '\n' ' ')"
check "el manifiesto"       "1"  "$(grep -c 'manifest' <<<"$DENTRO")"
check "la configuración"    "1"  "$(grep -c 'app.conf' <<<"$DENTRO")"
check "el .env"             "1"  "$(grep -c 'shared/.env' <<<"$DENTRO")"
check "las subidas"         "1"  "$(grep -c 'shared/uploads/foto.jpg' <<<"$DENTRO")"
check "la página de mantenimiento" "1" "$(grep -c 'shared/maintenance.html' <<<"$DENTRO")"
check "las redirecciones"   "1"  "$(grep -c 'redirects.list' <<<"$DENTRO")"
check "la base de datos"    "1"  "$(grep -c 'database.sql.gz' <<<"$DENTRO")"
# Lo que NO entra, y es la decisión de diseño: el código está en git, que es
# mejor copia que ésta. Meterlo multiplicaría el tamaño sin añadir nada.
check "el código no entra"  "0"  "$(grep -c 'releases' <<<"$DENTRO")"
check "ni la release activa" "0" "$(grep -c 'current' <<<"$DENTRO")"

section "El manifiesto se lee sin tener Orbit"
MAN="$TMP/man"; tar xzf "$FICH" -C "$TMP" ./manifest && mv "$TMP/manifest" "$MAN"
check "de qué app es"    "tienda" "$(sed -n 's/^app=//p' "$MAN")"
check "y de dónde sale el código" "https://example.test/tienda.git" "$(sed -n 's/^repositorio=//p' "$MAN")"
check "dice si lleva base" "si"  "$(sed -n 's/^base_de_datos=//p' "$MAN")"
check "y si lleva redirecciones" "si" "$(sed -n 's/^redirecciones=//p' "$MAN")"
# Quien lo abra dentro de dos años tiene que saber qué hacer con él.
check "explica el siguiente paso" "1" "$(grep -c 'orbit deploy tienda' "$MAN")"

section "Una app sin base de datos ni redirecciones"
mkapp simple static "" simple.test
mkdir -p "$TMP/apps/simple/shared"
printf 'X=1\n' > "$TMP/apps/simple/shared/.env"
F2="$(_backup_one simple)"
D2="$(tar tzf "$F2" | tr '\n' ' ')"
check "sin volcado"      "0"  "$(grep -c 'database' <<<"$D2")"
check "sin redirecciones" "0" "$(grep -c 'redirects' <<<"$D2")"
check "pero con su .env" "1"  "$(grep -c 'shared/.env' <<<"$D2")"
check "y el manifiesto lo dice" "no" \
  "$(tar xzOf "$F2" ./manifest | sed -n 's/^base_de_datos=//p')"

section "Restaurar en un servidor limpio"
# El caso de verdad: se ha perdido todo y sólo queda el .tar.gz.
rm -f "$TMP/etc/apps/tienda.conf" "$TMP/etc/redirects/tienda.list"
rm -rf "$TMP/apps/tienda"
: > "$DBS"; : > "$ROLES"
check "no queda nada"    "0"  "$(app_exists tienda && echo 1 || echo 0)"

SALIDA="$(run cmd_restore "$FICH" --yes </dev/null 2>&1)"; r=$?
check "restaura"         "0"  "$r"
check "vuelve la app"    "1"  "$(app_exists tienda && echo 1 || echo 0)"
check "con su dominio"   "tienda.test" "$(load_app tienda; printf '%s' "$A_DOMAIN")"
check "y sus capacidades" "yes" "$(load_app tienda; printf '%s' "$A_PHP")"
check "vuelve el .env"   "1"  "$(grep -c 'API_KEY=abc' "$TMP/apps/tienda/shared/.env")"
check "vuelven las subidas" "una foto" "$(cat "$TMP/apps/tienda/shared/uploads/foto.jpg")"
check "vuelven las redirecciones" "1" "$(grep -c '/viejo /nuevo' "$TMP/etc/redirects/tienda.list")"
# El código no vuelve, y hay que decirlo: es la mitad del trabajo que queda.
check "el código no vuelve" "0" "$([[ -e "$TMP/apps/tienda/current" ]] && echo 1 || echo 0)"
check "pero dice cómo traerlo" "1" "$(grep -c 'orbit deploy tienda' <<<"$SALIDA")"

section "La base de datos vuelve con la contraseña que espera el .env"
# Lo que rompe una restauración y no se ve hasta mucho después: recrear el rol
# con una contraseña nueva. La app arrancaría con el .env restaurado y daría
# "password authentication failed" sin relación aparente con la restauración.
check "recrea el rol"    "1"  "$(grep -c 'CREATE ROLE "tienda"' "$PSQL")"
check "con la del .env"  "1"  "$(grep -c "PASSWORD 'secreta123'" "$PSQL")"
check "crea la base"     "1"  "$(grep -cx 'tienda' "$DBS")"
check "y le da permisos" "1"  "$(grep -c 'GRANT ALL PRIVILEGES ON DATABASE "tienda"' "$PSQL")"

section "Sacar el usuario y la contraseña de un DATABASE_URL"
U='postgresql://miuser:mipass@127.0.0.1:5432/midb'
check "usuario"         "miuser" "$(_pg_url_part "$U" user)"
check "contraseña"      "mipass" "$(_pg_url_part "$U" pass)"
# Una URL sin credenciales no debe dar media respuesta: o se sabe, o no.
run _pg_url_part 'postgresql://127.0.0.1:5432/midb' pass >/dev/null; r=$?
check "sin credenciales, no" "1" "$r"
run _pg_url_part '' pass >/dev/null; r=$?
check "vacío, tampoco"  "1"  "$r"
# Una contraseña con arroba dentro: el usuario es lo de antes de la ÚLTIMA
# arroba, no de la primera.
check "arroba en la contraseña" "pa@ss" "$(_pg_url_part 'postgresql://u:pa@ss@h:5432/d' pass)"

section "Restaurar encima de algo que ya existe"
# Es destructivo, así que sin -y no se hace.
printf 'API_KEY=NUEVA\n' > "$TMP/apps/tienda/shared/.env"
SALIDA="$(printf 'n\n' | run cmd_restore "$FICH" 2>&1)"; r=$?
check "avisa de que existe" "1" "$(grep -c 'ya existe' <<<"$SALIDA")"
check "y no lo pisa"     "1"  "$(grep -c 'API_KEY=NUEVA' "$TMP/apps/tienda/shared/.env")"
# Con la base ya creada, cargar el volcado encima se pregunta aparte: son dos
# daños distintos. Se contesta que sí para ejercitar las dos ramas.
SALIDA="$(printf 'y\n' | run cmd_restore "$FICH" --yes 2>&1)"
check "con --yes sí"     "1"  "$(grep -c 'API_KEY=abc' "$TMP/apps/tienda/shared/.env")"
check "y pregunta por la base" "1" "$(grep -c 'La base .* ya existe' <<<"$SALIDA")"

section "Ficheros que no son copias de Orbit"
printf 'cualquier cosa\n' | gzip > "$TMP/falso.tar.gz"
run cmd_restore "$TMP/falso.tar.gz" --yes </dev/null >/dev/null 2>&1; r=$?
check "un gz cualquiera"  "1" "$r"
tar -czf "$TMP/vacio.tar.gz" -C "$TMP" falso.tar.gz
run cmd_restore "$TMP/vacio.tar.gz" --yes </dev/null >/dev/null 2>&1; r=$?
check "un tar sin manifiesto" "1" "$r"
run cmd_restore "$TMP/no-existe.tar.gz" </dev/null >/dev/null 2>&1; r=$?
check "un fichero que no está" "1" "$r"
# Un nombre de app inventado dentro del manifiesto escribiría fuera de sitio.
mkdir -p "$TMP/malo"; printf 'app=../../etc/passwd\n' > "$TMP/malo/manifest"
printf 'A_NAME=x\n' > "$TMP/malo/app.conf"
tar -czf "$TMP/malo.tar.gz" -C "$TMP/malo" .
run cmd_restore "$TMP/malo.tar.gz" --yes </dev/null >/dev/null 2>&1; r=$?
check "nombre con ruta dentro" "1" "$r"

section "Copiar todas de una pasada"
: > "$PSQL"
rm -f "$BACKUP_DIR"/*.tar.gz
run cmd_backup --all >/dev/null 2>&1; r=$?
check "termina bien"     "0"  "$r"
check "una por app"      "2"  "$(find "$BACKUP_DIR" -name '*.tar.gz' ! -name '_orbit-conf-*' | wc -l)"
# La configuración global va aparte: restaurarla es otra decisión.
check "y la global"      "1"  "$(find "$BACKUP_DIR" -name '_orbit-conf-*.tar.gz' | wc -l)"
check "lleva orbit.conf" "1"  "$(tar tzf "$(find "$BACKUP_DIR" -name '_orbit-conf-*' | head -1)" | grep -c 'orbit.conf')"
# El token de Cloudflare NO se copia: se regenera en treinta segundos y su
# ausencia hace que una copia robada no sirva para tomar el DNS.
printf 'token\n' > "$TMP/etc/cloudflare.ini"
run cmd_backup tienda >/dev/null 2>&1
check "sin el token de CF" "0" \
  "$(tar tzf "$(find "$BACKUP_DIR" -name 'tienda-*' | sort | tail -1)" | grep -c cloudflare)"

section "Sacar la copia del servidor"
# Una copia que vive en el mismo disco que los datos no es una copia. El hook
# recibe el fichero y hace con él lo que sepa: rclone, scp, s3cmd…
ENVIADAS="$TMP/enviadas"; : > "$ENVIADAS"
BACKUP_HOOK="printf '%s\\n' >> $ENVIADAS"
run cmd_backup tienda >/dev/null 2>&1
check "se llama al hook" "1"  "$(wc -l < "$ENVIADAS")"
check "con la ruta"      "1"  "$(grep -c "^$BACKUP_DIR/tienda-" "$ENVIADAS")"

# Un hook con tuberías o redirecciones no puede recibir el fichero de último
# argumento —acabaría en el último comando de la tubería, donde no hace nada—,
# así que si lo nombra, se respeta tal cual.
: > "$ENVIADAS"
BACKUP_HOOK="printf 'con-variable %s\\n' \"\$ORBIT_BACKUP_FILE\" >> $ENVIADAS"
run cmd_backup tienda >/dev/null 2>&1
check "lo nombra él"     "1"  "$(grep -c '^con-variable ' "$ENVIADAS")"
# Y una sola vez: si además se le añadiera de último argumento, printf lo
# imprimiría dos veces.
check "y no se duplica"  "1"  "$(grep -o "$BACKUP_DIR/tienda-" "$ENVIADAS" | wc -l)"
# Si el hook falla, la copia sólo está aquí, y eso hay que decirlo.
BACKUP_HOOK="exit 1"
SALIDA="$(run cmd_backup tienda 2>&1)"
check "avisa si falla"   "1"  "$(grep -c 'sólo está en este servidor' <<<"$SALIDA")"
BACKUP_HOOK=""

section "Las copias viejas se van solas"
touch -d '30 days ago' "$BACKUP_DIR/tienda-20250101-000000.tar.gz"
run cmd_backup simple >/dev/null 2>&1
check "borra las caducadas" "0" "$(find "$BACKUP_DIR" -name 'tienda-20250101-*' | wc -l)"
check "y conserva las nuevas" "1" \
  "$([[ $(find "$BACKUP_DIR" -name '*.tar.gz' -newermt '-1 day' | wc -l) -gt 0 ]] && echo 1 || echo 0)"

section "Levantar el servidor entero de una tirada"
# El caso para el que existe: la máquina se ha perdido, hay un Ubuntu nuevo con
# Orbit instalado, y en un directorio están las copias que el hook fue sacando.
BACKUP_DIR="$TMP/servidor"; mkdir -p "$BACKUP_DIR"
: > "$DBS"; : > "$ROLES"
run cmd_backup --all >/dev/null 2>&1
# Una copia vieja de la misma app: no debe ganarle a la reciente.
VIEJA="$BACKUP_DIR/tienda-20200101-000000.tar.gz"
cp "$(find "$BACKUP_DIR" -name 'tienda-*' | head -1)" "$VIEJA"
touch -d '2 years ago' "$VIEJA"
# Y ahora se pierde todo.
rm -f "$TMP/etc/apps/"*.conf "$TMP/etc/redirects/"*.list
rm -rf "$TMP/apps/tienda" "$TMP/apps/simple"
: > "$DBS"; : > "$ROLES"
check "no queda nada"     "0"  "$(app_names | wc -w)"

DESPLIEGUES="$TMP/despliegues"; : > "$DESPLIEGUES"
cmd_deploy() { printf '%s\n' "$1" >> "$DESPLIEGUES"; }
SALIDA="$(run cmd_restore --all --yes </dev/null 2>&1)"; r=$?
check "restaura todo"     "0"  "$r"
check "vuelven las dos apps" "2" "$(app_names | wc -w)"
check "con sus .env"      "1"  "$(grep -c 'API_KEY=abc' "$TMP/apps/tienda/shared/.env")"
check "y sus redirecciones" "1" "$(grep -c '/viejo /nuevo' "$TMP/etc/redirects/tienda.list")"
# De cada app se coge la más reciente: restaurar una vieja encima de una nueva
# sería perder datos sin que nadie lo haya pedido.
check "coge la copia nueva" "0" "$(grep -c '20200101' <<<"$SALIDA")"
# El código es la otra mitad, y traerlo puede tardar y fallar: no se hace por
# sorpresa, se dan los comandos.
check "no despliega solo" "0"  "$(wc -l < "$DESPLIEGUES")"
check "pero dice cómo"    "1"  "$(grep -c 'orbit deploy tienda' <<<"$SALIDA")"

# Con --deploy sí, que es lo que quiere quien está levantando un servidor.
rm -f "$TMP/etc/apps/"*.conf; rm -rf "$TMP/apps/tienda" "$TMP/apps/simple"
: > "$DESPLIEGUES"
run cmd_restore --all --yes --deploy </dev/null >/dev/null 2>&1
check "con --deploy despliega" "2" "$(wc -l < "$DESPLIEGUES")"
check "en orden"          "simple" "$(head -1 "$DESPLIEGUES")"
unset -f cmd_deploy

section "Las preferencias vuelven, las rutas de este servidor no"
# La configuración global lleva las dos cosas mezcladas, y sólo una es
# restaurable: traer APPS_DIR de otra máquina deja un servidor recién montado
# apuntando a rutas que no existen.
printf 'LETSENCRYPT_EMAIL="yo@example.test"\nKEEP_RELEASES="9"\nWATCH_MAX_TRIES="7"\nBACKUP_KEEP="30"\nAPPS_DIR="/servidor/viejo"\nDEPLOY_USER="otro"\nPHP_VER="7.4"\n' > "$TMP/conf-copia"
KEEP_RELEASES=5
_restore_conf "$TMP/conf-copia" >/dev/null
check "vuelve el email"   "1"  "$(grep -c 'LETSENCRYPT_EMAIL="yo@example.test"' "$CONF_FILE")"
check "y las releases"    "9"  "$KEEP_RELEASES"
check "y los umbrales"    "1"  "$(grep -c 'WATCH_MAX_TRIES="7"' "$CONF_FILE")"
check "y las copias"      "1"  "$(grep -c 'BACKUP_KEEP="30"' "$CONF_FILE")"
# Lo que describe a ESTE servidor se queda como está, pase lo que pase.
check "APPS_DIR no se toca" "0" "$(grep -c '/servidor/viejo' "$CONF_FILE")"
check "ni el usuario"     "0"  "$(grep -c 'DEPLOY_USER="otro"' "$CONF_FILE")"
check "ni la versión de PHP" "0" "$(grep -c 'PHP_VER="7.4"' "$CONF_FILE")"

section "Ver lo que hay guardado"
SALIDA="$(run cmd_backup list 2>&1)"
check "lista todas las que hay" "$(find "$BACKUP_DIR" -name 'tienda-*.tar.gz' | wc -l)" \
                          "$(grep -c 'tienda-' <<<"$SALIDA")"
BACKUP_DIR="$TMP/no-existe"
check "sin copias, lo dice" "1" "$(run cmd_backup list 2>&1 | grep -c 'Todavía no hay ninguna')"

# ═══════════════════════════════════════════════════════════════════════════
#  Verificar: saber que el fichero existe no es saber que se puede volver
#  de él. Entre las dos cosas caben cuatro averías, y TRES de ellas pasan
#  'gzip -t' tan campantes.
# ═══════════════════════════════════════════════════════════════════════════
BACKUP_DIR="$TMP/backups"
V="$TMP/verificar"; mkdir -p "$V"

# Las pruebas de restauración de arriba vacían el PostgreSQL de mentira para
# imitar un servidor limpio, así que esta sección monta el suyo. Sin esto la
# copia salía con 'base_de_datos=no' y las comprobaciones del volcado no se
# ejercitaban: pasaban por no llegar a mirar, que es la peor forma de pasar.
echo tienda > "$DBS"

# Una copia recién hecha y buena, de la que partir para ir rompiéndola.
BUENA="$(_backup_one tienda)"
check "la copia base lleva la base" "si" \
  "$(tar xzOf "$BUENA" ./manifest | sed -n 's/^base_de_datos=//p')"

# Rehace un tar.gz a partir de un directorio ya modificado.
rehacer() { # rehacer <dir> <destino>
  tar -czf "$2" -C "$1" .
}
# Abre una copia en un directorio nuevo y lo imprime.
abrir() { # abrir <fichero>
  local d; d="$(mktemp -d)"; tar xzf "$1" -C "$d"; printf '%s' "$d"
}

section "Una copia buena se reconoce como buena"
run _verify_one "$BUENA"; check "verifica" "0" "$?"
check "y dice de qué app es" "1" "$(_verify_one "$BUENA" >/dev/null; grep -c 'tienda' <<<"$VERIFY_MSG")"

section "Un pg_dump que falló y dejó el .gz vacío"
# El caso peligroso de verdad: pg_dump falla, gzip escribe un .gz válido de
# cero bytes de contenido, y el manifiesto seguía diciendo 'base_de_datos=si'.
# Sabías que el fichero existía; no que se pudiera volver de él.
D="$(abrir "$BUENA")"; : | gzip > "$D/database.sql.gz"
rehacer "$D" "$V/dump-vacio.tar.gz"
check "el .gz es válido"  "0" "$(gzip -t "$D/database.sql.gz" 2>/dev/null; echo $?)"
run _verify_one "$V/dump-vacio.tar.gz"; check "aun así, la caza" "1" "$?"
check "y dice por qué" "1" "$(_verify_one "$V/dump-vacio.tar.gz" >/dev/null 2>&1 || true; grep -c 'incompleto o corrupto' <<<"$VERIFY_MSG")"
rm -rf "$D"

section "Un volcado cortado a la mitad"
# Comprime bien, pero le falta la marca que pg_dump escribe al terminar: el
# proceso murió a mitad (OOM, disco lleno, la máquina se reinició).
D="$(abrir "$BUENA")"
printf -- '--\n-- PostgreSQL database dump\n--\n\nCREATE TABLE cosas(' | gzip > "$D/database.sql.gz"
rehacer "$D" "$V/dump-cortado.tar.gz"
check "el .gz es válido"  "0" "$(gzip -t "$D/database.sql.gz" 2>/dev/null; echo $?)"
run _verify_one "$V/dump-cortado.tar.gz"; check "la caza igual" "1" "$?"
rm -rf "$D"

section "La marca no tiene por qué ser la última línea"
# Desde PostgreSQL 16.13 el volcado acaba en '\unrestrict <token>', DESPUÉS de
# la marca. Mirar sólo el final daría por rota una copia buena en cualquier
# servidor al día — y esto es una regresión que se paga en pánico.
D="$(abrir "$BUENA")"
printf -- '--\n-- PostgreSQL database dump complete\n--\n\n\\unrestrict xyz\n' | gzip > "$D/database.sql.gz"
rehacer "$D" "$V/dump-moderno.tar.gz"
run _verify_one "$V/dump-moderno.tar.gz"; check "la da por buena" "0" "$?"
rm -rf "$D"

section "Un fichero cortado por un disco lleno"
head -c 120 "$BUENA" > "$V/truncada.tar.gz"
run _verify_one "$V/truncada.tar.gz"; check "no se abre" "1" "$?"
check "y lo explica" "1" "$(_verify_one "$V/truncada.tar.gz" >/dev/null 2>&1 || true; grep -c 'corrupto o incompleto' <<<"$VERIFY_MSG")"

section "Le falta algo imprescindible"
D="$(abrir "$BUENA")"; rm -f "$D/manifest"; rehacer "$D" "$V/sin-manifiesto.tar.gz"; rm -rf "$D"
run _verify_one "$V/sin-manifiesto.tar.gz"; check "sin manifiesto" "1" "$?"
D="$(abrir "$BUENA")"; rm -f "$D/app.conf"; rehacer "$D" "$V/sin-conf.tar.gz"; rm -rf "$D"
run _verify_one "$V/sin-conf.tar.gz"; check "sin app.conf" "1" "$?"
# El .env es lo único verdaderamente irrecuperable: no está en git ni en
# ninguna otra parte. Que falte y nadie lo diga es el peor caso de todos.
D="$(abrir "$BUENA")"; rm -f "$D/shared/.env"; rehacer "$D" "$V/sin-env.tar.gz"; rm -rf "$D"
run _verify_one "$V/sin-env.tar.gz"; check "sin .env" "1" "$?"
check "y lo nombra" "1" "$(_verify_one "$V/sin-env.tar.gz" >/dev/null 2>&1 || true; grep -c 'irrecuperable' <<<"$VERIFY_MSG")"

section "Faltan ficheros de shared/"
D="$(abrir "$BUENA")"; rm -f "$D/shared/uploads/foto.jpg"; rehacer "$D" "$V/sin-subidas.tar.gz"; rm -rf "$D"
run _verify_one "$V/sin-subidas.tar.gz"; check "los cuenta" "1" "$?"

section "Copias de versiones anteriores"
# Las de antes no traen 'entorno=' ni 'ficheros_shared='. No comprobar un campo
# que no existe es distinto de dar la copia por rota: si se rechazaran, una
# actualización de Orbit convertiría todo tu histórico en chatarra.
D="$(abrir "$BUENA")"
grep -v '^entorno=\|^ficheros_shared=' "$D/manifest" > "$D/m2" && mv "$D/m2" "$D/manifest"
rm -f "$D/shared/uploads/foto.jpg"
rehacer "$D" "$V/antigua.tar.gz"; rm -rf "$D"
run _verify_one "$V/antigua.tar.gz"; check "siguen valiendo" "0" "$?"

section "El comando, de punta a punta"
BACKUP_DIR="$V/solas"; mkdir -p "$BACKUP_DIR"
cp "$BUENA" "$BACKUP_DIR/"
SALIDA="$(run cmd_backup verify 2>&1)"; RC=$?
check "verifica todas"  "0" "$RC"
check "y lo dice"       "1" "$(grep -c 'se pueden restaurar' <<<"$SALIDA")"
cp "$V/dump-vacio.tar.gz" "$BACKUP_DIR/tienda-99999999-000000.tar.gz"
SALIDA="$(run cmd_backup verify 2>&1)"; RC=$?
check "una mala, falla" "1" "$RC"
check "y la nombra"     "1" "$(grep -c 'tienda-99999999' <<<"$SALIDA")"
# La configuración global no lleva app ni manifiesto: medirla con la misma vara
# la daría por rota siempre.
tar -czf "$BACKUP_DIR/_orbit-conf-20260101-000000.tar.gz" -C "$TMP/etc" orbit.conf
SALIDA="$(run cmd_backup verify 2>&1)"
check "la global, aparte" "1" "$(grep -c 'configuración global' <<<"$SALIDA")"

section "Verificar no ejecuta lo que hay dentro de la copia"
# Codex, revisando el PR: la primera version leia app.conf con '.', creyendo
# que el subshell bastaba. Aisla las variables, si, pero no los efectos: un
# app.conf con una linea cualquiera se ejecutaria **como root**, que es quien
# corre orbit. Y este comando existe para apuntarlo a un fichero del que no te
# fias, asi que verificar una copia no puede ser mas peligroso que no hacerlo.
TESTIGO="$V/me-he-ejecutado"
D="$(abrir "$BUENA")"
printf "A_NAME='tienda'\ntouch '%s'\n" "$TESTIGO" > "$D/app.conf"
rehacer "$D" "$V/con-codigo.tar.gz"; rm -rf "$D"
run _verify_one "$V/con-codigo.tar.gz" >/dev/null 2>&1
check "no ejecuta nada" "0" "$([[ -e "$TESTIGO" ]] && echo 1 || echo 0)"
# Y aun asi lee el nombre, que es lo que tenia que sacar de ahi.
_verify_one "$V/con-codigo.tar.gz" >/dev/null 2>&1 || true
check "pero lee el nombre" "1" "$(grep -c 'tienda' <<<"$VERIFY_MSG")"

section "Las dos mitades tienen que hablar de la misma app"
# Un manifiesto que dice una cosa y un app.conf que dice otra restauraria
# encima de quien no toca.
D="$(abrir "$BUENA")"
sed -i "s/^A_NAME=.*/A_NAME='otra-cosa'/" "$D/app.conf"
rehacer "$D" "$V/discordante.tar.gz"; rm -rf "$D"
run _verify_one "$V/discordante.tar.gz"; check "lo caza" "1" "$?"
check "y nombra a las dos" "1" \
  "$(_verify_one "$V/discordante.tar.gz" >/dev/null 2>&1 || true; grep -c 'otra-cosa' <<<"$VERIFY_MSG")"

section "El HOME del servicio no entra en la copia"
# Codex: shared/home es el HOME del servicio (ARCHITECTURE §5.1) y es cache —
# el gestor de paquetes que baja corepack y lo que cada libreria deje ahi.
# Copiarlo multiplicaria el tamano de cada copia y de cada generacion que se
# conserve, por datos que caducan y que el build vuelve a sembrar.
mkdir -p "$TMP/apps/tienda/shared/home/.cache/node/corepack/v1/pnpm"
head -c 20000 /dev/urandom > "$TMP/apps/tienda/shared/home/.cache/node/corepack/v1/pnpm/paquete.tgz"
FCACHE="$(_backup_one tienda)"
DENTRO="$(tar tzf "$FCACHE" | sed 's|^\./||')"
check "sin shared/home"   "0" "$(grep -c '^shared/home' <<<"$DENTRO")"
check "sin la cache"      "0" "$(grep -c 'corepack' <<<"$DENTRO")"
# Lo que si tiene que seguir estando, que es lo irrecuperable.
check "pero con el .env"  "1" "$(grep -c '^shared/.env$' <<<"$DENTRO")"
check "y con las subidas" "1" "$(grep -c '^shared/uploads/foto.jpg$' <<<"$DENTRO")"
# Y el recuento del manifiesto no puede contar lo que no se guardo, o 'verify'
# echaria en falta ficheros que nunca entraron y las daria todas por rotas.
run _verify_one "$FCACHE"; check "y verifica bien" "0" "$?"
check "el recuento cuadra" "0" \
  "$(tar xzOf "$FCACHE" ./manifest | sed -n 's/^ficheros_shared=//p' | \
     awk -v n="$(tar tzf "$FCACHE" | grep -c '^\./shared/.*[^/]$')" '{print ($1==n)?0:1}')"

section "Un volcado fallido aborta la copia entera"
# Antes: pg_dump fallaba, la copia se creaba igual y el manifiesto decía llevar
# la base. Ahora no hay copia — mejor ninguna que una que miente.
BACKUP_DIR="$V/fallo"; mkdir -p "$BACKUP_DIR"
sudo() { # el pg_dump se rompe; lo demás sigue contestando
  local u=""
  while [[ "${1:-}" == -* ]]; do
    case "$1" in -u) u="$2"; shift 2 ;; --) shift; break ;; *) shift ;; esac
  done
  [[ "$u" == "postgres" ]] || { "$@"; return; }
  case "${1:-}" in
    pg_dump) echo "pg_dump: error: no he podido conectar" >&2; return 1 ;;
    psql)    case "$*" in *"FROM pg_database"*) echo 1 ;; esac ;;
  esac
  return 0
}
run _backup_one tienda; check "no la hace" "1" "$?"
check "y no deja fichero" "0" "$(find "$BACKUP_DIR" -name 'tienda-*.tar.gz' 2>/dev/null | wc -l)"

report
