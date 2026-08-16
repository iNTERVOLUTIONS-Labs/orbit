#!/usr/bin/env bash
# Pruebas del aislamiento por app: el nombre del usuario, su creación, la
# migración con 'orbit isolate' y que remove se lleve lo que es suyo.
#
# Ningún usuario se crea de verdad: useradd/userdel los apunta lib.sh en
# USERS_LOG, y el chown se dobla aquí. Lo que sí es real es la unidad de
# systemd que se genera (en $TMP) y la configuración que se guarda.
#
# shellcheck disable=SC2034  # asigna variables A_* que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
# is-active contesta que no: aquí no corre nada, y así 'isolate' no intenta
# reiniciar ni se queda 30 segundos esperando a un health check sin app.
systemctl() { [[ "${1:-}" == "is-active" ]] && return 1; return 0; }

section "El nombre de usuario es determinista y siempre vale para useradd"
# Determinista porque un restore en un servidor nuevo tiene que recrear EL
# MISMO usuario que dice la configuración; ≤32 y sin puntos porque useradd
# con el NAME_REGEX por defecto de Debian rechaza lo demás.
check "simple"            "orbit-blog" "$(_app_username blog)"
check "dos veces, igual"  "$(_app_username blog)" "$(_app_username blog)"
U1="$(_app_username web.es)"; U2="$(_app_username web-es)"
check "sin puntos"        "0" "$(grep -c '\.' <<<"$U1")"
# 'web.es' saneada es 'web-es': sin el sufijo con hash las dos apps
# compartirían usuario, que es exactamente lo que el aislamiento elimina.
check "no choca con su gemela" "0" "$([[ "$U1" == "$U2" ]] && echo 1 || echo 0)"
LARGO="$(_app_username una-app-con-un-nombre-larguisimo-de-verdad)"
check "cabe en useradd"   "1" "$(( ${#LARGO} <= 32 ? 1 : 0 ))"
check "y recortado sigue siendo suyo" "$LARGO" \
      "$(_app_username una-app-con-un-nombre-larguisimo-de-verdad)"

section "La creación del usuario"
: > "$USERS_LOG"
_ensure_app_user orbit-demo demo
check "llama a useradd"   "1" "$(grep -c '^useradd .* orbit-demo$' "$USERS_LOG")"
check "de sistema"        "1" "$(grep -c -- '--system' "$USERS_LOG")"
# Sin -m: el HOME es shared/home, que el despliegue crea con el dueño bueno,
# y un /etc/skel sembrado ahí no pinta nada.
check "sin esqueleto"     "0" "$(grep -c ' -m ' "$USERS_LOG")"
check "HOME el de la app" "1" "$(grep -c -- "-d $TMP/apps/demo/shared/home" "$USERS_LOG")"
check "sin shell de entrada" "1" "$(grep -c -- '-s /usr/sbin/nologin' "$USERS_LOG")"
: > "$USERS_LOG"
_ensure_app_user root demo    # root existe en cualquier máquina
check "si ya existe, ni lo toca" "0" "$(wc -l < "$USERS_LOG")"

section "orbit isolate migra una app con proceso"
chown() { printf 'chown %s\n' "$*" >> "$TMP/chown.log"; }
: > "$TMP/chown.log"; : > "$USERS_LOG"
mkapp vieja node 3010 vieja.test
mkdir -p "$TMP/apps/vieja/releases/r1" "$TMP/apps/vieja/shared" "$TMP/apps/vieja/cache"
ln -sfn "$TMP/apps/vieja/releases/r1" "$TMP/apps/vieja/current"
run cmd_isolate vieja >/dev/null 2>&1; r=$?
check "termina bien"      "0" "$r"
check "A_USER guardado"   "orbit-vieja" \
      "$(sed -n "s/^A_USER='\(.*\)'\$/\1/p" "$TMP/etc/apps/vieja.conf")"
check "usuario creado"    "1" "$(grep -c 'orbit-vieja$' "$USERS_LOG")"
check "releases cambian de dueño" "1" "$(grep -c 'releases' "$TMP/chown.log")"
check "shared también"    "1" "$(grep -c 'shared' "$TMP/chown.log")"
# La caché de git es del fetcher: deploy la escribe en cada fetch, y un chown
# aquí rompería el despliegue siguiente.
check "la caché ni se mira" "0" "$(grep -c 'cache' "$TMP/chown.log")"
check "la unidad corre como él" "1" "$(grep -c '^User=orbit-vieja$' "$(svc_unit vieja)")"
check "y su grupo"        "1" "$(grep -c '^Group=orbit-vieja$' "$(svc_unit vieja)")"
run cmd_isolate vieja >"$TMP/iso2" 2>&1; r=$?
check "repetirlo no es un error" "0" "$r"
check "y dice que ya estaba" "1" "$(grep -c 'ya está aislada' "$TMP/iso2")"

section "Una estática no se aísla"
# No corre nada que aislar; decir que sí sería vender seguridad que no existe.
mkapp folleto static "" folleto.test
run cmd_isolate folleto >/dev/null 2>&1; r=$?
check "se niega"          "1" "$r"

section "Una app PHP se aísla con su propio pool"
# El socket lo crearía php-fpm, que aquí no corre: la espera se dobla, y su
# camino de fallo tiene su propia sección más abajo.
_php_sock_ready() { return 0; }
# Un usuario propio no aísla una app PHP: sus páginas las ejecuta php-fpm, y
# con el pool compartido seguirían corriendo como 'deploy' — leyendo el .env de
# todas las demás. Usuario y pool son la misma decisión.
render_nginx() { :; }
mkapp tienda php "" tienda.test
A_TYPE="php"; A_DOCROOT="public"; save_app
run cmd_isolate tienda >/dev/null 2>&1; r=$?
check "se aísla"          "0" "$r"
POOL="$(php_pool_file tienda)"
check "tiene pool propio" "1" "$([[ -f "$POOL" ]] && echo 1 || echo 0)"
check "corre como suyo"   "1" "$(grep -c '^user = orbit-tienda$' "$POOL")"
check "y su grupo"        "1" "$(grep -c '^group = orbit-tienda$' "$POOL")"
check "con socket propio" "1" "$(grep -c "^listen = .*orbit-tienda.sock$" "$POOL")"
# El socket lo abre nginx, así que ese extremo es de www-data aunque el
# proceso de detrás sea de la app. Si fuera de la app, nginx no le hablaría.
check "que nginx puede abrir" "1" "$(grep -c '^listen.owner = www-data$' "$POOL")"
# Cinturón sobre los tirantes: aunque alguien le cambiara el dueño a un
# fichero de otra app, este pool no puede salir de lo suyo.
check "encerrado en su carpeta" "1" \
  "$(grep -c "^php_admin_value\[open_basedir\] = $TMP/apps/tienda:/tmp\$" "$POOL")"
# Y el vhost tiene que hablar con ESE socket, no con el compartido.
check "nginx va a su socket" "$(php_sock_path tienda)" "$(php_sock_for tienda)"
check "y una sin aislar, al compartido" "/run/php/orbit.sock" "$(php_sock_for folleto)"

section "Migrar una app PHP no la deja un segundo sin poder leer su .env"
# El agujero, medido en un VPS: el .env es el único fichero 0640 de shared/, y
# durante la migración cambia de dueño ANTES de que nginx mueva el tráfico al
# socket nuevo. En ese hueco —un segundo largo— quien sirve sigue siendo el
# pool compartido, que corre como deploy y ya no puede leer el .env que acaba
# de dejar de ser suyo: la app contesta sin su configuración. Y la de al lado
# sigue siendo legible, así que el aislamiento tampoco está puesto todavía.
#
# No hay orden que lo arregle: al revés, el pool nuevo serviría mientras el
# .env es aún de deploy, y falla igual. Lo que se afirma aquí es que durante el
# relevo el .env lo pueden leer LOS DOS —dueño el usuario nuevo, grupo el
# viejo— y que se cierra en cuanto el tráfico ha llegado. Eso no abre nada:
# deploy ya podía leerlo antes de migrar, porque era suyo.
SEQ="$TMP/isolate.seq"; : > "$SEQ"
chown()       { printf 'chown %s\n' "$*" >> "$SEQ"; }
chgrp()       { printf 'chgrp %s\n' "$*" >> "$SEQ"; }
render_nginx() { printf 'nginx\n' >> "$SEQ"; }
mkapp bazar php "" bazar.test
A_TYPE="php"; A_DOCROOT="public"; save_app
mkdir -p "$TMP/apps/bazar/shared"; : > "$TMP/apps/bazar/shared/.env"
run cmd_isolate bazar >/dev/null 2>&1
_sq() { grep -n "$1" "$SEQ" | head -1 | cut -d: -f1; }
N_NGINX="$(_sq '^nginx$')"
# El .env queda con dueño nuevo y grupo viejo: legible por los dos.
N_ABIERTO="$(grep -n "\.env" "$SEQ" | grep "orbit-bazar:$DEPLOY_USER" | head -1 | cut -d: -f1)"
# Y se cierra a su grupo definitivo después.
N_CERRADO="$(grep -n "\.env" "$SEQ" | grep -E "chgrp orbit-bazar|chown orbit-bazar:orbit-bazar" | tail -1 | cut -d: -f1)"
check "el .env se deja legible por el pool viejo" "1" \
  "$([[ -n "$N_ABIERTO" ]] && echo 1 || echo 0)"
check "y eso ocurre antes de mover el tráfico" "1" \
  "$(( ${N_ABIERTO:-999} < ${N_NGINX:-0} ? 1 : 0 ))"
check "se cierra al grupo de la app"       "1" \
  "$([[ -n "$N_CERRADO" ]] && echo 1 || echo 0)"
check "y sólo después de mover el tráfico"  "1" \
  "$(( ${N_NGINX:-999} < ${N_CERRADO:-0} ? 1 : 0 ))"
# Y no antes, que es la otra forma de tener el mismo agujero: cerrar el grupo
# con el tráfico todavía en el socket compartido deja al pool viejo sin poder
# leer el .env exactamente igual. Sin esta comprobación, añadir un cierre
# prematuro y dejar el bueno al final pasaba en verde — comprobado mutando.
check "y no se cierra antes de tiempo"      "0" \
  "$(awk -v n="${N_NGINX:-0}" 'NR<n && /\.env/ && (/chgrp orbit-bazar/ || /chown orbit-bazar:orbit-bazar/)' "$SEQ" | wc -l)"
unset -f chgrp render_nginx
chown() { printf 'chown %s\n' "$*" >> "$TMP/chown.log"; }
render_nginx() { :; }

section "Si php-fpm no carga el pool, no se toca nada"
# El aislamiento cambia el dueño de todos los ficheros de la app. Hacerlo y
# descubrir DESPUÉS que el pool no carga deja la app entre dos sillas: sus
# ficheros ya no los lee el pool compartido y el suyo no existe. Por eso el
# pool se comprueba primero, y la señal es el socket — 'systemctl reload' sale
# con 0 aunque un pool se rechace, y 'nginx -t' tampoco mira si existe.
_php_sock_ready() { return 1; }
mkapp fragil php "" fragil.test
A_TYPE="php"; A_DOCROOT="public"; save_app
mkdir -p "$TMP/apps/fragil/shared"
: > "$TMP/chown.log"
run cmd_isolate fragil >/dev/null 2>&1; r=$?
check "aborta"            "1" "$r"
check "sin usuario guardado" "" \
  "$(sed -n "s/^A_USER='\(.*\)'\$/\1/p" "$TMP/etc/apps/fragil.conf")"
check "sin pool a medias" "0" "$([[ -f "$(php_pool_file fragil)" ]] && echo 1 || echo 0)"
check "y sin tocar dueños" "0" "$(grep -c fragil "$TMP/chown.log")"
_php_sock_ready() { return 0; }

section "El pool se va con la app"
# Un pool huérfano apuntando a un usuario que ya no existe deja a php-fpm
# negándose a arrancar, y con él TODAS las apps PHP del servidor.
run cmd_remove tienda --yes --purge >/dev/null 2>&1
check "sin pool"          "0" "$([[ -f "$POOL" ]] && echo 1 || echo 0)"
unset -f render_nginx

section "El dueño sale de la app nombrada, no de la que esté cargada"
# La revisión del PR #10 lo cazó: _env_path recibe la app por nombre pero
# resolvía el dueño con los globales. En un clone, los globales ya son del
# clon cuando se lee el .env del ORIGINAL: el chown le robaba el fichero al
# original —sus builds ya no podían leerlo— y de paso le enseñaba los
# secretos al usuario del clon.
mkapp otra node 3012 otra.test
sed -i "s/^A_USER=''$/A_USER='orbit-otra'/" "$TMP/etc/apps/otra.conf"
mkapp llana node 3014 llana.test
check "app_user_of lee el conf"  "orbit-otra" "$(app_user_of otra)"
check "y sin A_USER, deploy"     "$(id -un)"  "$(app_user_of llana)"
load_app vieja                     # los globales son de OTRA app a propósito
mkdir -p "$TMP/apps/otra/shared"
install() { printf 'install %s\n' "$*" >> "$TMP/chown.log"; }
: > "$TMP/chown.log"
_env_path otra >/dev/null 2>&1
unset -f install
check "el .env es del nombrado"  "2" "$(grep -c 'orbit-otra' "$TMP/chown.log")"
check "no del cargado"           "0" "$(grep -c 'orbit-vieja' "$TMP/chown.log")"

section "remove sin --purge conserva al dueño de lo que se queda"
# También de la revisión: sin --purge las releases y el .env se quedan, y
# borrar a su único dueño los dejaba huérfanos bajo un UID numérico, con el
# 0640 inaccesible desde la cuenta que anuncia la app.
: > "$USERS_LOG"
run cmd_remove vieja --yes >/dev/null 2>&1; r=$?
check "remove termina"    "0" "$r"
check "sin purge, sin userdel" "0" "$(grep -c 'userdel' "$USERS_LOG")"
: > "$USERS_LOG"
mkapp vieja2 node 3013 vieja2.test
run cmd_isolate vieja2 >/dev/null 2>&1
run cmd_remove vieja2 --yes --purge >/dev/null 2>&1; r=$?
check "con purge, termina" "0" "$r"
check "y el usuario se va con los datos" "1" "$(grep -c '^userdel orbit-vieja2$' "$USERS_LOG")"
: > "$USERS_LOG"
mkapp comun node 3011 comun.test
run cmd_remove comun --yes --purge >/dev/null 2>&1
# Sin A_USER la app corre como deploy, y a deploy no lo borra nadie: es la
# guarda que evita que una conf editada a mano tumbe al usuario del servidor.
check "sin usuario propio, sin userdel" "0" "$(grep -c 'userdel' "$USERS_LOG")"

report
