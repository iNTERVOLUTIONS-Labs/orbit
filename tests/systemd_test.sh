#!/usr/bin/env bash
# Pruebas de la unidad de systemd que genera Orbit.
#   bash tests/systemd_test.sh
#
# La unidad es lo más delicado que escribe Orbit: es la que encierra el proceso
# en producción y la que decide qué puede leer. Un fallo aquí no lo ve ninguna
# prueba de build —el build corre con 'sudo -u deploy -H', fuera del cajón— y
# sólo aparece cuando la app ya está desplegada y no arranca.
#
# shellcheck disable=SC2034  # asigna variables A_* que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"

# Ni systemd ni root en el contenedor: la unidad se escribe en $TMP y se lee.
UNITDIR="$TMP/systemd"; mkdir -p "$UNITDIR"
svc_unit() { echo "$UNITDIR/$(svc_name "$1").service"; }
systemctl() { :; }

mkapp web node 3001 web.test
render_systemd web
U="$(svc_unit web)"

# Valor de una directiva Environment= de la unidad, por nombre.
env_of() { sed -n "s/^Environment=$1=//p" "$U"; }

section "La unidad carga el fichero de entorno que declara la app"
# shared/.env siempre, y el de "env": {"file": …} detrás, que en systemd gana.
# Antes la unidad decía shared/.env y nada más, mientras 'orbit env' y la
# provisión escribían en el declarado.
check "sin declarar, uno"   "EnvironmentFile=-$TMP/apps/web/shared/.env" "$(grep '^EnvironmentFile=' "$U")"
load_app web; A_ENV_FILE="api/.env"; save_app
render_systemd web
check "declarado, los dos y en orden" \
  "EnvironmentFile=-$TMP/apps/web/shared/.env|EnvironmentFile=-$TMP/apps/web/shared/api/.env" \
  "$(grep '^EnvironmentFile=' "$U" | tr '\n' '|' | sed 's/|$//')"
# Una ruta que no vale no sale de shared/: se queda en shared/.env.
load_app web; A_ENV_FILE="../../etc/shadow"; save_app
render_systemd web
check "una ruta mala no cuela" "EnvironmentFile=-$TMP/apps/web/shared/.env" "$(grep '^EnvironmentFile=' "$U")"
load_app web; A_ENV_FILE=""; save_app
render_systemd web

section "PHP opcional no impide arrancar apps Node"
# Sin el '-', una app de Node en un servidor sin php-fpm moría con 226/NAMESPACE
# antes de ejecutar nada: systemd no puede montar una ruta que no existe.
# (De la rama fix/next-listen-localhost, sin publicar.)
check "el socket ausente no rompe el namespace" "1" "$(grep -c '^ReadWritePaths=.* -/run/php$' "$U")"

section "La unidad se escribe"
check "existe"          "1" "$([[ -f "$U" ]] && echo 1 || echo 0)"
check "arranca la app"  "1" "$(grep -c "^ExecStart=.*node server.js" "$U")"
check "como deploy"     "1" "$(grep -c "^User=$(id -un)$" "$U")"

# ---------------------------------------------------------------------------
# El bug: ProtectHome=true tapa /home con un tmpfs en modo 000, así que el
# proceso no puede ni atravesarlo. Con el HOME que systemd deduce de User=
# (/home/deploy) cualquier lectura del HOME muere con EACCES. Se veía así:
#
#   Error: EACCES: permission denied, opendir
#          '/home/deploy/.cache/node/corepack/v1/pnpm'
#
# …y la unidad reiniciaba en bucle. corepack guarda ahí el gestor de paquetes
# que fija el repositorio, y el arranque de una app con pnpm pasa por él.
# ---------------------------------------------------------------------------
section "El HOME del servicio es alcanzable"
check "HOME declarado"      "1" "$([[ -n "$(env_of HOME)" ]] && echo 1 || echo 0)"
check "y no está en /home"  "0" "$(env_of HOME | grep -c '^/home/')"
check "vive con la app"     "$TMP/apps/web/shared/home" "$(env_of HOME)"
# shared/ y no la release: la caché tiene que sobrevivir al despliegue siguiente.
check "fuera de la release" "0" "$(env_of HOME | grep -c '/releases/')"
check "y existe en disco"   "1" "$([[ -d "$(env_of HOME)" ]] && echo 1 || echo 0)"

section "corepack encuentra su caché"
check "COREPACK_HOME fijo"  "$TMP/apps/web/shared/home/.cache/node/corepack" \
                            "$(env_of COREPACK_HOME)"
check "creada en disco"     "1" "$([[ -d "$(env_of COREPACK_HOME)" ]] && echo 1 || echo 0)"
# Explícita y no heredada de HOME: un XDG_CACHE_HOME en el .env la movería de
# sitio y volveríamos al mismo EACCES sin nada que lo explicara.
check "no depende de HOME"  "1" "$(grep -c '^Environment=COREPACK_HOME=' "$U")"
# corepack resuelve <COREPACK_HOME>/v1/<gestor>: la ruta del error de producción.
check "bajo ReadWritePaths" "1" \
  "$(awk -v h="$(env_of COREPACK_HOME)" '/^ReadWritePaths=/{sub(/^ReadWritePaths=/,"");
      split($0,p," "); for(i in p) if (index(h,p[i])==1) f=1} END{print f+0}' "$U")"

section "Todo el HOME lleva dueño, no sólo la hoja"
# 'install -d -o X a/b/c' le pone dueño **al último componente**: los
# intermedios los crea quien ejecuta, que aquí es root. Así que ~/.cache
# quedaba de root:root, y cualquier herramienta que quiera crear su propia
# carpeta dentro se estrellaba:
#
#   failed to initialize build cache at …/shared/home/.cache/go-build:
#   mkdir …/.cache/go-build: permission denied
#
# Node no se enteraba porque Orbit le crea la ruta ENTERA de corepack; nadie
# más tiene ese privilegio. Salió con un 'go build' de verdad en un VPS: Go no
# se podía desplegar en ninguna app aislada. Lo que se afirma es que a la
# llamada van todos los niveles, que es lo único que se puede ver sin root.
#
# Y desde 1.4.9 la llamada la hace el usuario de la app, no un 'install -d -o'
# de root: shared/home es suyo, y con un '.cache' cambiado por un enlace a
# /etc, root le daba /etc.
: > "$AS_USER_LOG"
INSTALL_LOG="$TMP/install.log"; : > "$INSTALL_LOG"
install() { printf 'install %s\n' "$*" >> "$INSTALL_LOG"; command install "$@"; }
render_systemd web >/dev/null 2>&1
HOMEDIR="$TMP/apps/web/shared/home"
MKD="$(grep "^$(id -un) mkdir -p -m 0755 -- " "$AS_USER_LOG")"
check "el HOME"            "1" "$(grep -c " $HOMEDIR\( \|\$\)" <<<"$MKD")"
check "y su .cache"        "1" "$(grep -c " $HOMEDIR/.cache\( \|\$\)" <<<"$MKD")"
check "y .cache/node"      "1" "$(grep -c " $HOMEDIR/.cache/node\( \|\$\)" <<<"$MKD")"
check "y el de corepack"   "1" "$(grep -c " $HOMEDIR/.cache/node/corepack\( \|\$\)" <<<"$MKD")"
check "y root no lo crea"  "0" "$(grep -c "$HOMEDIR" "$INSTALL_LOG")"
unset -f install

section "El cajón sigue cerrado"
# El arreglo no puede haber sido abrir /home: eso dejaría al proceso leer las
# claves SSH del usuario deploy y las de cualquier otro.
check "ProtectHome=true"    "1" "$(grep -c '^ProtectHome=true$' "$U")"
check "sin read-only"       "0" "$(grep -c '^ProtectHome=read-only' "$U")"
check "sin tmpfs"           "0" "$(grep -c '^ProtectHome=tmpfs' "$U")"
check "ProtectSystem"       "1" "$(grep -c '^ProtectSystem=strict$' "$U")"
check "NoNewPrivileges"     "1" "$(grep -c '^NoNewPrivileges=true$' "$U")"
check "sin BindPaths"       "0" "$(grep -c '^Bind.*Paths=' "$U")"

section "Precedencia de variables"
# systemd aplica EnvironmentFile **por encima** de Environment=, se escriban en
# el orden que se escriban: la prueba de antes comprobaba que el .env iba
# primero en el fichero, como si eso decidiera algo, y no decide nada. Medido
# con systemd-run: un PORT=8080 en el .env ganaba al Environment=PORT=3005 de la
# unidad. Muchos .env traen PORT=3000 de la máquina de quien los escribió, y
# con eso la app escuchaba donde el health check no miraba: rollback en cada
# despliegue. Un HOST=0.0.0.0 la dejaba abierta a internet sin nginx.
#
# Lo que manda de verdad es la orden de arranque, así que se fijan ahí.
EXEC="$(sed -n 's/^ExecStart=//p' "$U")"
check "PORT en la orden"     "1" "$(grep -c '^/usr/bin/env PORT=3001 ' <<<"$EXEC")"
check "HOST en la orden"     "1" "$(grep -c ' HOST=127.0.0.1 ' <<<"$EXEC")"
check "NODE_ENV en la orden" "1" "$(grep -c ' NODE_ENV=production ' <<<"$EXEC")"
check "y la app detrás"      "1" "$(grep -c "/bin/bash -c 'node server.js'$" <<<"$EXEC")"

# Y los '$' de la orden de la app, doblados: systemd expande él mismo los
# '${PORT}' de ExecStart —también entre comillas— con su entorno, el del .env,
# antes de ejecutar nada. Es justo como arrancan Python y Deno.
mkapp py python 3006 py.test
A_START='./.venv/bin/gunicorn -b 127.0.0.1:${PORT} app:app'; save_app
render_systemd py
UP="$(svc_unit py)"
check "los \$ se doblan" "1" \
  "$(grep -c "^ExecStart=.*-b 127.0.0.1:\$\${PORT} app:app'$" "$UP")"

# La comprobación que importa, sin systemd: se ejecuta la orden tal como la
# recibe el proceso —con el '$$' ya convertido en '$', que es lo que hace
# systemd— y con el entorno que deja el .env, que llega antes y por encima.
mkapp eco node 3007 eco.test
A_START='echo "$PORT ${PORT} $HOST $NODE_ENV"'; save_app
render_systemd eco
ORDEN="$(sed -n 's/^ExecStart=//p' "$(svc_unit eco)")"; ORDEN="${ORDEN//\$\$/\$}"
check "un .env con PORT y HOST no gana" "3007 3007 127.0.0.1 production" \
  "$(PORT=8080 HOST=0.0.0.0 NODE_ENV=development bash -c "exec $ORDEN")"

# Y lo mismo con lo demás que fija Orbit. Con sólo Environment=HOME, un HOME
# del .env —el /home/ana del portátil de quien lo escribió— ganaba, y el
# proceso arrancaba con un HOME que ProtectHome tapa: EACCES en bucle, el
# fallo de §5.1 abierto desde el .env. Medido con systemd-run antes de
# arreglarlo. PATH, COREPACK_HOME y DENO_DIR, por lo mismo.
check "HOME en la orden"          "1" "$(grep -c " HOME=$TMP/apps/web/shared/home " <<<"$EXEC")"
check "PATH en la orden"          "1" "$(grep -c " PATH=$UNIT_PATH " <<<"$EXEC")"
check "COREPACK_HOME en la orden" "1" "$(grep -c " COREPACK_HOME=$TMP/apps/web/shared/home/.cache/node/corepack " <<<"$EXEC")"
load_app eco; A_START='echo "$HOME|$PATH|$COREPACK_HOME"'; save_app
render_systemd eco
ORDEN="$(sed -n 's/^ExecStart=//p' "$(svc_unit eco)")"; ORDEN="${ORDEN//\$\$/\$}"
check "un .env con HOME, PATH y COREPACK_HOME no gana" \
  "$TMP/apps/eco/shared/home|$UNIT_PATH|$TMP/apps/eco/shared/home/.cache/node/corepack" \
  "$(HOME=/home/ana PATH=/home/ana/.nvm/bin:/usr/bin:/bin COREPACK_HOME=/tmp/otra bash -c "exec $ORDEN")"

section "Regenerar es idempotente"
before="$(md5sum < "$U")"
render_systemd web
check "misma unidad" "$before" "$(md5sum < "$U")"
# Y si alguien borra el HOME a mano, regenerar lo repone: la unidad y el disco
# no pueden contarse cosas distintas.
rm -rf "$(env_of HOME)"
render_systemd web
check "repone el HOME" "1" "$([[ -d "$(env_of HOME)" ]] && echo 1 || echo 0)"

section "Deno guarda sus dependencias donde el servicio las busca"
# Es el mismo fallo de corepack, en otro sitio: Deno no deja node_modules en el
# repositorio, sino que lo baja todo a DENO_DIR, que por defecto vive en el
# HOME. El build corre con el HOME de deploy y el servicio con el de la unidad,
# así que sin fijarlo el build salía bien y el arranque se estrellaba pidiendo
# dependencias que en su HOME no estaban.
mkapp api deno 3002 api.test
render_systemd api
UD="$(svc_unit api)"
env_of_d() { sed -n "s/^Environment=$1=//p" "$UD"; }
check "DENO_DIR fijo"       "$TMP/apps/api/shared/deno" "$(env_of_d DENO_DIR)"
check "y en la orden, que es lo que gana al .env" "1" \
  "$(grep -c "^ExecStart=/usr/bin/env .* DENO_DIR=$TMP/apps/api/shared/deno /bin/bash -c " "$UD")"
check "creada en disco"     "1" "$([[ -d "$(env_of_d DENO_DIR)" ]] && echo 1 || echo 0)"
# En shared/ y no en la release: si viviera en la release, cada despliegue
# empezaría con la caché vacía y el primer arranque tendría que bajarlo todo.
check "fuera de la release" "0" "$(env_of_d DENO_DIR | grep -c '/releases/')"
check "bajo ReadWritePaths" "1" \
  "$(awk -v h="$(env_of_d DENO_DIR)" '/^ReadWritePaths=/{sub(/^ReadWritePaths=/,"");
      n=split($0,p," "); for(i=1;i<=n;i++) if (index(h,p[i])==1) ok=1}
      END{print ok?1:0}' "$UD")"
# Y a una app que no es de Deno no se le cuela la variable: la unidad de antes
# tiene que salir byte a byte igual que salía.
check "sólo en Deno"        "0" "$(grep -c '^Environment=DENO_DIR=' "$U")"
check "ni en su orden"       "0" "$(grep -c 'DENO_DIR=' "$U")"

section "Una app en una subcarpeta arranca donde vive"
# WorkingDirectory es la raíz de la release y no se toca: la unidad no sabe de
# monorepos. Quien entra es el propio A_START, con el 'cd' que le puso la
# detección. Lo que hay que fijar aquí es que ese 'cd' llega a la unidad tal
# cual, porque es lo único que hace que systemd arranque el binario correcto.
mkapp srv go 3003 srv.test
A_APPDIR="backend"; A_START="cd backend && ./bin/app"; save_app
render_systemd srv
US="$(svc_unit srv)"
check "el cd llega al ExecStart" "1" \
  "$(grep -c "^ExecStart=/usr/bin/env .* /bin/bash -c 'cd backend && ./bin/app'$" "$US")"
# WorkingDirectory sigue siendo la raíz de la release: es de donde parten todas
# las rutas que Orbit guarda, y cambiarlo aquí las partiría en dos convenciones.
check "WorkingDirectory no cambia" "1" \
  "$(grep -c "^WorkingDirectory=$TMP/apps/srv/current$" "$US")"
# Go apaga con SIGTERM, y eso tiene que seguir siendo cierto con el cd delante:
# bash hace exec del último comando de un -c aunque lleve 'cd x &&', así que la
# señal le llega al binario y no a un bash intermedio. Comprobado ejecutándolo.
check "y KillSignal sigue siendo SIGTERM" "1" "$(grep -c '^KillSignal=SIGTERM$' "$US")"

section "Las estáticas no llevan servicio"
mkapp docs static 0 docs.test
render_systemd docs
check "sin unidad" "0" "$([[ -f "$(svc_unit docs)" ]] && echo 1 || echo 0)"

section "La unidad puente del reinicio sin corte"
# El puente arranca la release NUEVA mientras la canónica sigue sirviendo la
# vieja. Si su WorkingDirectory fuera 'current', las dos instancias correrían
# la misma release y verificar el puente no verificaría nada; si llevara el
# puerto de la app, pelearía con el proceso vivo por el socket y el health
# check estaría midiendo al viejo. Son las dos mutaciones que tienen que poner
# esto en rojo.
mkapp par node 3004 par.test
load_app par
PREL="$TMP/apps/par/releases/20260810-120000"; mkdir -p "$PREL"
render_systemd_next par 4999 "$PREL"
UN="$(svc_next_unit par)"
check "existe"                 "1" "$([[ -f "$UN" ]] && echo 1 || echo 0)"
check "anclada a la release"   "1" "$(grep -c "^WorkingDirectory=$PREL$" "$UN")"
check "no al symlink"          "0" "$(grep -c '^WorkingDirectory=.*current' "$UN")"
check "con su puerto"          "1" "$(grep -c '^Environment=PORT=4999$' "$UN")"
check "su nombre en el journal" "1" "$(grep -c '^SyslogIdentifier=orbit-par-next$' "$UN")"
# El mismo cajón que la canónica: el puente ejecuta el mismo código ajeno, y
# unos segundos con menos hardening siguen siendo el mismo agujero.
check "mismo hardening"        "1" "$(grep -c '^ProtectHome=true$' "$UN")"
# Y la canónica no se ha movido: sigue sobre current y con el puerto de la app.
render_systemd par
check "la canónica, en current" "1" "$(grep -c "^WorkingDirectory=$TMP/apps/par/current$" "$(svc_unit par)")"
check "y con su puerto"         "1" "$(grep -c '^Environment=PORT=3004$' "$(svc_unit par)")"

report
