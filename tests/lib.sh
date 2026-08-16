#!/usr/bin/env bash
# ============================================================================
#  Cargador común de las pruebas de Orbit.
#
#    source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
#  Deja disponibles todas las funciones de 'orbit' sin ejecutar main(), con un
#  /etc/orbit falso bajo $TMP. No necesita root, ni systemd, ni un servidor.
# ============================================================================

# La tabla de glifos de 'orbit' mira la configuración regional para decidir
# entre los símbolos Unicode y el ASCII de repuesto. Sin fijarla aquí, media
# suite compararía contra '✓' o contra '+' según la máquina — exactamente la
# clase de prueba que pasa en un sitio y falla en otro. Se fija a UTF-8, que es
# el caso normal; el camino ASCII lo ejercita 'ui_test' a propósito.
export LC_ALL="${LC_ALL:-C.UTF-8}"

ORBIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/etc/apps" "$TMP/apps" "$TMP/acme" "$TMP/fx"
cat > "$TMP/etc/orbit.conf" <<EOF
DEPLOY_USER="$(id -un)"
APPS_DIR="$TMP/apps"
ACME_DIR="$TMP/acme"
PHP_VER="8.3"
APP_ISOLATION="no"
PORT_BASE="3001"
KEEP_RELEASES="5"
EOF

# Cargamos el script sin su última línea (la llamada a main) y neutralizando la
# auto-elevación con sudo, para poder invocar las funciones una a una.
sed '$ d' "$ORBIT_ROOT/orbit" \
  | sed "s|^ETC_DIR=.*|ETC_DIR=\"$TMP/etc\"|" \
  | sed 's|^if \[\[ \$EUID -ne 0 \]\]; then|if false; then|' \
  > "$TMP/orbitlib.sh"
# shellcheck disable=SC1090
source "$TMP/orbitlib.sh"

# Ninguna prueba puede escribir en el systemd de verdad.
#
# No es teoría: 'subcmd_test' llamaba a 'orbit autodeploy on' sin redirigir
# nada, así que dejaba un orbit-autodeploy.timer real en /etc/systemd/system de
# la máquina de quien ejecutara las pruebas **como root** — y como root sí
# escribe, la prueba pasaba. En CI, que corre sin privilegios, el mismo camino
# fallaba al escribir y la prueba se caía. Un fallo que sólo aparece según
# quién ejecute la tanda es lo peor de las dos formas.
#
# Se redirigen aquí las cuatro rutas de unidad, de modo que ninguna suite tenga
# que acordarse. Las que quieren inspeccionar el fichero generado vuelven a
# definirlas después de este 'source', y su definición gana.
# Ninguna prueba crea ni borra usuarios de verdad, por lo mismo que ninguna
# escribe en el systemd real: las llamadas se apuntan y las suites que quieren
# mirarlas leen el registro. El conf de arriba deja APP_ISOLATION="no" porque
# un usuario que no existe rompe cualquier chown/install real que venga
# después; las suites del aislamiento lo encienden a propósito con sus dobles.
USERS_LOG="$TMP/users.log"; : > "$USERS_LOG"
useradd() { printf 'useradd %s\n' "$*" >> "$USERS_LOG"; }
userdel() { printf 'userdel %s\n' "$*" >> "$USERS_LOG"; }

# Y tampoco en /etc/php: un pool escrito ahí por una prueba se lo comería el
# php-fpm de la máquina en su siguiente recarga.
mkdir -p "$TMP/pool"
php_pool_file() { echo "$TMP/pool/orbit-$1.conf"; }
php_sock_path() { echo "$TMP/pool/orbit-$1.sock"; }

# Y tampoco en /etc/nginx, que es el que faltaba y el que costó caro.
#
# 'isolate_test' termina con un 'cmd_remove tienda', y 'cmd_remove' borraba el
# vhost por su ruta absoluta. Lanzada la tanda **como root** en un servidor que
# tenía una app llamada 'tienda', la prueba se llevó por delante el vhost de la
# app de verdad: sin un error, con las 32 suites en verde, y dejando una web
# registrada, compilada y con su unidad viva a la que ya no atendía nadie. Se
# supo en la comprobación del reinicio siguiente, una hora después.
#
# Es el mismo fallo que el recuadro de systemd de aquí arriba describe —«un
# fallo que sólo aparece según quién ejecute la tanda es lo peor de las dos
# formas»—, en el único directorio donde no se había aplicado.
#
# 'NGINX_DEFAULT_CONF' se reasigna aparte a propósito: se compone a partir de
# NGINX_AVAILABLE **en el momento del source**, así que cambiar la variable de
# después no lo arrastra. Las otras dos sí valen aquí porque quien las lee son
# funciones, y una función mira la variable cuando la llaman.
NGINX_AVAILABLE="$TMP/nginx/sites-available"
NGINX_ENABLED="$TMP/nginx/sites-enabled"
# shellcheck disable=SC2034  # lo leen 'nginx_default_write' y doctor, en el orbit cargado arriba
NGINX_DEFAULT_CONF="$NGINX_AVAILABLE/000-orbit-default"
mkdir -p "$NGINX_AVAILABLE" "$NGINX_ENABLED"

mkdir -p "$TMP/systemd"
svc_unit()           { echo "$TMP/systemd/$(svc_name "$1").service"; }
svc_next_unit()      { echo "$TMP/systemd/$(svc_next_name "$1").service"; }
watch_unit()         { echo "$TMP/systemd/orbit-watch.timer"; }
watch_service()      { echo "$TMP/systemd/orbit-watch.service"; }
autodeploy_unit()    { echo "$TMP/systemd/orbit-autodeploy.timer"; }
autodeploy_service() { echo "$TMP/systemd/orbit-autodeploy.service"; }
queue_unit()         { echo "$TMP/systemd/orbit-queue.timer"; }
queue_service()      { echo "$TMP/systemd/orbit-queue.service"; }
# Y el cerrojo por app de las colas, que vive en /var/lib/orbit: un flock ahí
# no rompe nada, pero deja ficheros del usuario que ejecutó las pruebas en un
# directorio del servidor.
# shellcheck disable=SC2034  # la lee el 'orbit' cargado más arriba, no lib.sh
QUEUE_LOCK_DIR="$TMP/locks"

# 'orbit' activa errexit. En las pruebas queremos seguir ejecutando después de
# un fallo esperado para poder contarlo, así que lo desactivamos a propósito.
set +e

# …pero los comandos de orbit dependen de errexit para abortar a tiempo. run()
# los ejecuta en un subshell con las mismas opciones que en producción, de modo
# que un fallo a mitad se comporta igual que en el servidor.
#
# ATENCIÓN a cómo se llama. Bash apaga errexit dentro de cualquier comando que
# forme parte de una lista '&&' o '||', y el subshell lo hereda: volver a poner
# 'set -Eeuo pipefail' dentro **no** lo reactiva, ni tampoco esconderlo detrás
# de otra función. O sea que esto:
#
#     run cmd_x && r=0 || r=$?      # ← MAL: errexit desactivado
#
# ejecuta cmd_x **sin** errexit, y una orden que en el servidor abortaría a
# mitad aquí sigue hasta el final y devuelve 0. La prueba pasa y el fallo no
# existe. La forma correcta deja el subshell suelto:
#
#     run cmd_x; r=$?               # ← BIEN
run() { ( set -Eeuo pipefail; "$@" ); }

TEST_PASS=0
TEST_FAIL=0

section() { printf '\n%s\n' "$*"; }

# printf '%-24s' cuenta bytes, no caracteres: con acentos la columna se
# descuadra (la misma trampa que documenta ARCHITECTURE §10). ${#s} cuenta
# caracteres, pero sólo si la configuración regional es UTF-8; en la local C
# vuelve a contar bytes, así que la fijamos dentro de la función.
_pad() { # _pad <texto> <ancho>
  local LC_ALL=C.UTF-8
  local s="$1" w="$2" n
  n=$(( w - ${#s} ))
  printf '%s' "$s"
  (( n > 0 )) && printf '%*s' "$n" ''
  return 0
}

check() { # check <nombre> <esperado> <obtenido>
  if [[ "$2" == "$3" ]]; then
    printf '  ok    %s %s\n' "$(_pad "$1" 24)" "$3"
    TEST_PASS=$((TEST_PASS + 1))
  else
    printf '  FALLO %s esperaba=%s obtuvo=%s\n' "$(_pad "$1" 24)" "$2" "$3"
    TEST_FAIL=$((TEST_FAIL + 1))
  fi
}

# Registra una app de mentira igual que lo haría el asistente, pasando por
# save_app para que el fichero tenga exactamente el formato de producción.
# Escribe globales A_* a propósito: es lo que save_app espera.
# shellcheck disable=SC2034
mkapp() { # mkapp <nombre> <tipo> <puerto> [dominio] [alias]
  A_NAME="$1"; A_TYPE="$2"; A_PORT="$3"
  # A_USER se vacía a mano: si quedara el de la app cargada justo antes, la
  # nueva nacería «aislada» con el usuario de OTRA — pasó en isolate_test.
  # A_QUEUE, por lo mismo: una app nueva que heredara el permiso de la anterior
  # se pondría a vaciar una cola que nadie le pidió.
  A_USER=""; A_QUEUE=""
  A_DOMAIN="${4:-$1.test}"; A_ALIASES="${5:-}"
  A_REPO="https://example.test/$1.git"; A_BRANCH="main"
  A_PKG="pnpm"; A_BUILD=""; A_START="node server.js"
  A_OUTDIR=""; A_SPA="no"; A_DOCROOT=""; A_PYAPP=""; A_APPDIR="."
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
  save_app
}

report() {
  printf '\n'
  if (( TEST_FAIL )); then
    printf '%s pruebas fallidas, %s correctas\n' "$TEST_FAIL" "$TEST_PASS"
    exit 1
  fi
  printf '%s pruebas correctas\n' "$TEST_PASS"
  exit 0
}
