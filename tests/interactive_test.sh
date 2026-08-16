#!/usr/bin/env bash
# Elegir en vez de escribir, y no acabar en la shell cuando algo falla.
#   bash tests/interactive_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, EVA…) que
# lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
DEPLOY_USER="$(id -un)"
# 'choose' sin fzf y sin terminal usa la lista numerada y lee de la entrada.
# Las pruebas le dan el número por stdin, que es exactamente lo que teclearía
# alguien delante del menú.
command -v fzf >/dev/null && fzf() { return 1; }

# Lo que necesita jq va marcado y se salta, no se da por fallido: sin jq,
# _pkg_scripts no devuelve nada **por diseño**, así que afirmar lo contrario
# convierte una herramienta ausente en un bug inventado.
SIN_JQ="no"; command -v jq >/dev/null || SIN_JQ="yes"

SRC="$TMP/src"; mkdir -p "$SRC"

section "Los scripts salen del package.json, no de la imaginación"
cat > "$SRC/package.json" <<'EOF'
{ "name": "x", "scripts": {
    "build": "vite build",
    "dev": "vite",
    "dev:debug": "NODE_OPTIONS=--inspect vite",
    "start": "node server.js" } }
EOF
# La lista de scripts sale de jq. Sin él, _pkg_scripts no devuelve nada — que es
# su comportamiento declarado— y estas afirmaciones dejan de ser ciertas por
# diseño. Antes iban sin guardia, así que 'make test' sin jq salía **en rojo**
# con siete fallos repartidos entre esta sección y la siguiente, que parecían un
# bug del selector de scripts. Ni probado ni saltado: acusando a quien no era.
if [[ "$SIN_JQ" == "yes" ]]; then
  echo "  (falta jq: me salto la lista de scripts del package.json)"
else
check "los lee todos"     "4" "$(_pkg_scripts "$SRC" | wc -l)"
check "nombre y comando"  "dev:debug	NODE_OPTIONS=--inspect vite" \
                          "$(_pkg_scripts "$SRC" | grep '^dev:debug')"
fi
mkdir -p "$TMP/vacio"; printf '{}' > "$TMP/vacio/package.json"
# jq -e sale con 4 cuando no ha producido nada: lo que importa es que no sea 0.
_pkg_scripts "$TMP/vacio" >/dev/null 2>&1 && r=0 || r=1
check "sin scripts, falla" "1" "$r"
_pkg_scripts "$TMP" >/dev/null 2>&1 && r=0 || r=1
check "sin package.json"   "1" "$r"

section "Elegir el script que arranca en modo depuración"
A_PKG="pnpm"
if [[ "$SIN_JQ" == "yes" ]]; then
  echo "  (falta jq: me salto elegir de una lista de scripts)"
else
# 1 = el valor detectado, 2 = build, 3 = dev, 4 = dev:debug…
check "elige dev:debug"   "pnpm run dev:debug" \
                          "$(printf '4\n' | _pick_script "$SRC" "Arranque" "pnpm start")"
check "conserva el detectado" "pnpm start" \
                          "$(printf '1\n' | _pick_script "$SRC" "Arranque" "pnpm start")"
# La descripción que se enseña al lado no puede acabar dentro del comando.
check "sin la descripción" "0" \
  "$(printf '2\n' | _pick_script "$SRC" "Build" "pnpm build" | grep -c '·')"
# Sin valor detectado no hay primera entrada, así que 'build' es la 1.
check "ni espacios de sobra" "pnpm run build" \
                          "$(printf '1\n' | _pick_script "$SRC" "Build" "" )"
# Escribir otro: penúltima opción cuando se admite vacío, última si no.
check "deja escribir otro" "bun run raro" \
  "$(printf '6\nbun run raro\n' | _pick_script "$SRC" "Build" "pnpm build" --vacio)"
check "y deja dejarlo vacío" "" \
  "$(printf '7\n' | _pick_script "$SRC" "Build" "pnpm build" --vacio)"
fi
# Un repo sin package.json no puede ofrecer lista: se pregunta y ya.
check "sin lista, pregunta" "make all" \
                          "$(printf 'make all\n' | _pick_script "$TMP" "Build" "")"

section "Las ramas se ordenan dejando arriba las de siempre"
as_deploy() { printf '%s\n' \
  "aaa	refs/heads/feature/zzz" \
  "bbb	refs/heads/main" \
  "ccc	refs/heads/develop" \
  "ddd	refs/heads/aaa-primera"; }
check "main primero"     "main"    "$(_remote_branches http://x | head -1)"
check "develop después"  "develop" "$(_remote_branches http://x | sed -n 2p)"
check "y el resto, alfabético" "aaa-primera" "$(_remote_branches http://x | sed -n 3p)"
check "están las cuatro" "4"       "$(_remote_branches http://x | wc -l)"
# Una línea sin refs/heads no puede colarse como rama vacía.
as_deploy() { printf '%s\n' "aaa	refs/tags/v1" "bbb	refs/heads/main"; }
check "los tags no son ramas" "main" "$(_remote_branches http://x)"
unset -f as_deploy

section "Elegir un PR o un commit, sin cambiar la rama de la app"
mkdir -p "$TMP/etc/apps"
APPS_DIR="$TMP/apps"
A_NAME="web"; A_BRANCH="main"; A_REPO="https://github.com/x/y.git"
mkdir -p "$TMP/apps/web/cache/.git"
_open_prs() { printf '%s\n' "31	fix/lockfile	Arregla el lockfile" "40	feat/x	Algo nuevo"; }
as_deploy() { printf '%s\n' "1a2b3c4	Último commit" "9f8e7d6	El de antes"; }
# 1 = la rama, 2 y 3 = los PRs, 4 y 5 = los commits.
check "la rama no es un ref"  ""          "$(printf '1\n' | _pick_ref)"
check "un PR"                 "pr:31"     "$(printf '2\n' | _pick_ref)"
check "el segundo PR"         "pr:40"     "$(printf '3\n' | _pick_ref)"
check "un commit"             "1a2b3c4"   "$(printf '4\n' | _pick_ref)"
check "cancelar es la rama"   ""          "$(printf '99\n' | _pick_ref)"
# Sin PRs ni caché sólo queda la rama: no se pregunta lo que no tiene respuesta.
_open_prs() { return 1; }
rm -rf "$TMP/apps/web/cache"
check "sin nada que elegir, calla" "" "$(_pick_ref </dev/null)"
unset -f _open_prs as_deploy

section "Un error no puede tirarte a la shell"
# die() hace 'exit', que es lo que se llevaba por delante el menú entero.
muere() { die "me he roto"; }
( _menu_run muere >/dev/null 2>&1 ) </dev/null && r=0 || r=$?
check "el menú sobrevive"   "0" "$r"
SALIDA="$( _menu_run muere 2>&1 </dev/null )"
check "y lo dice"           "1" "$(grep -c 'terminado con un error' <<<"$SALIDA")"
check "sin perder el sitio" "1" "$(grep -c 'vuelves al menú' <<<"$SALIDA")"
check "y espera a ENTER"    "1" "$(grep -c 'Pulsa ENTER' <<<"$SALIDA")"
# Y cuando va bien no molesta con el aviso.
bien() { echo hecho; }
SALIDA="$( _menu_run bien 2>&1 </dev/null )"
check "si va bien, sin aviso" "0" "$(grep -c 'terminado con un error' <<<"$SALIDA")"
check "pero pausa igual"      "1" "$(grep -c 'Pulsa ENTER' <<<"$SALIDA")"
# Los de pantalla completa sólo pausan si fallan, para no meter una tecla de
# más entre el panel y el menú.
SALIDA="$( _menu_live bien 2>&1 </dev/null )"
check "pantalla completa, sin pausa" "0" "$(grep -c 'Pulsa ENTER' <<<"$SALIDA")"
SALIDA="$( _menu_live muere 2>&1 </dev/null )"
check "salvo si falla"               "1" "$(grep -c 'Pulsa ENTER' <<<"$SALIDA")"

section "El asistente distingue quién ha fallado"
APPS_DIR="$TMP/apps"; ETC_DIR="$TMP/etc"
A_NAME="roto"; A_BRANCH="main"; A_REPO="https://github.com/x/y.git"
A_BUILD="pnpm run build"
mkdir -p "$TMP/apps/roto"
# Sin release publicada: el build no llegó, y el sitio donde mirar es el repo.
SALIDA="$(_new_undeployed roto no 2>&1)"
check "dice que no sirve nada"  "1" "$(grep -c 'Ninguna versión publicada' <<<"$SALIDA")"
check "manda al repositorio"    "1" "$(grep -c 'en tu repositorio' <<<"$SALIDA")"
check "y da cómo comprobarlo"   "1" "$(grep -c 'git clone --depth 1' <<<"$SALIDA")"
check "con el build de verdad"  "1" "$(grep -c 'pnpm run build' <<<"$SALIDA")"
check "no habla de nginx"       "0" "$(grep -c 'nginx -t' <<<"$SALIDA")"
# Con release publicada el build fue bien: el fallo es posterior, y decir
# «arréglalo en tu repositorio» mandaría a mirar donde no es.
mkdir -p "$TMP/apps/roto/releases/uno"; ln -sfn "$TMP/apps/roto/releases/uno" "$TMP/apps/roto/current"
SALIDA="$(_new_undeployed roto no 2>&1)"
check "reconoce que compiló"    "1" "$(grep -c 'El código compiló' <<<"$SALIDA")"
check "no culpa al repositorio" "0" "$(grep -c 'en tu repositorio' <<<"$SALIDA")"
check "manda a nginx"           "1" "$(grep -c 'nginx -t' <<<"$SALIDA")"
check "y a doctor"              "1" "$(grep -c 'orbit doctor' <<<"$SALIDA")"
# La base de datos sólo se nombra si se pidió.
check "sin bd, no la nombra"    "0" "$(grep -c 'PostgreSQL' <<<"$SALIDA")"
check "con bd, sí"              "1" "$(grep -c 'PostgreSQL' <<<"$(_new_undeployed roto y 2>&1)")"
# Pero «hay release» tampoco quiere decir «arranca». Con una app con proceso
# cuyo health check falló, el symlink está puesto y el servicio no responde:
# ahí el discurso de «el build fue bien, esto no es tu código» es falso —lo que
# no arranca es justo su código— y mandaba a 'nginx -t' y a 'orbit doctor', que
# es donde no está el problema. Salió desplegando en un VPS una rama con un
# import inexistente: compila, activa la release y se estrella en bucle.
A_TYPE="node"; A_PORT="3001"
needs_svc()   { [[ "$1" == "node" ]]; }
health_wait() { return 1; }          # la app no contesta en su puerto
SALIDA="$(_new_undeployed roto no 2>&1)"
check "reconoce que compiló, igual" "1" "$(grep -c 'El código compiló' <<<"$SALIDA")"
check "dice que no arranca"         "1" "$(grep -c 'no arranca' <<<"$SALIDA")"
check "no dice que no es su código" "0" "$(grep -c 'no es tu código' <<<"$SALIDA")"
check "manda a los logs"            "1" "$(grep -c 'orbit logs roto' <<<"$SALIDA")"
check "y no a nginx"                "0" "$(grep -c 'nginx -t' <<<"$SALIDA")"
# Y si el proceso sí responde, lo que queda entre medias es nginx: el mensaje
# de antes vuelve a ser el correcto.
health_wait() { return 0; }
SALIDA="$(_new_undeployed roto no 2>&1)"
check "con la app viva, vuelve nginx" "1" "$(grep -c 'nginx -t' <<<"$SALIDA")"
check "y no habla del arranque"       "0" "$(grep -c 'no arranca' <<<"$SALIDA")"
unset -f needs_svc health_wait; A_TYPE=""; A_PORT=""
rm -f "$TMP/apps/roto/current"

section "El spinner no escribe una línea por fotograma sin terminal"
# Con la salida redirigida —un cron, 'orbit deploy | tee'— cada fotograma se
# quedaba escrito: un build largo dejaba miles de líneas iguales.
SALIDA="$(spin "Compilando" sleep 0.4 2>&1)"
check "una sola línea"     "1" "$(printf '%s' "$SALIDA" | grep -c 'Compilando')"
check "y dice que fue bien" "1" "$(grep -c '✓' <<<"$SALIDA")"
# Y sigue devolviendo el código de salida, que es para lo que se usa.
spin "algo" true  >/dev/null 2>&1 && r=0 || r=$?
check "devuelve 0 si va bien" "0" "$r"
spin "algo" false >/dev/null 2>&1 && r=0 || r=$?
check "y 1 si falla"          "1" "$r"

# shellcheck disable=SC2123  # tocar PATH es justo lo que se quiere probar:
# simular un servidor al que le falta una herramienta.
section "El diagnóstico no se muere por una herramienta que falte"
# 'dig' viene de dnsutils. Sin él, la asignación 'ip=$(dig …)' salía con 127 y
# errexit mataba a doctor a media recogida: como se imprime al final, no salía
# ningún diagnóstico. Justo lo que se ejecuta cuando algo va mal.
ETC_DIR="$TMP/etc"; APPS_DIR="$TMP/apps"
mkdir -p "$TMP/etc/apps" "$TMP/apps"
cat > "$TMP/etc/apps/web.conf" <<'CONF'
A_NAME='web'
A_DOMAIN='web.test'
A_TYPE='static'
CONF
# Y el diagnóstico de verdad: se recoge entero, con dig fuera del PATH y dos
# apps, para comprobar además que el aviso se da una vez y no una por app.
cp "$TMP/etc/apps/web.conf" "$TMP/etc/apps/otra.conf"
sed -i "s/'web'/'otra'/; s/web.test/otra.test/" "$TMP/etc/apps/otra.conf"
nginx()     { return 0; }
systemctl() { return 0; }
has_cert()  { return 1; }
cert_days_left() { printf ''; }
# Que falte 'dig' se dice aquí y no se simula moviendo el PATH: dónde esté
# instalado depende de la máquina. Esta prueba se escribió con un PATH
# recortado a "/usr/bin:/bin", que en este contenedor no lo tenía y en el
# runner de CI sí — así que pasaba en un sitio y fallaba en el otro sin que
# nada hubiera cambiado en Orbit.
_have_dig() { return 1; }
run _doctor_collect >/dev/null 2>&1; r=$?
check "la recogida entera sobrevive" "0" "$r"
_doctor_collect >/dev/null 2>&1
check "avisa de que falta dig"  "1" "$(printf '%s\n' "${DOC_MSG[@]}" | grep -c "Sin 'dig'")"
check "y dice cómo instalarlo"  "1" "$(printf '%s\n' "${DOC_FIX[@]}" | grep -c 'dnsutils')"
check "una vez, no una por app" "1" "$(printf '%s\n' "${DOC_ID[@]}" | grep -cx 'dns')"
check "y ninguna de dns:<app>"  "0" "$(printf '%s\n' "${DOC_ID[@]}" | grep -c '^dns:')"

# Y con dig disponible se comprueba cada dominio, que es la otra mitad y hasta
# ahora no la miraba nadie.
_have_dig() { return 0; }
dig() { printf '203.0.113.9\n'; }
_doctor_collect >/dev/null 2>&1
check "con dig, no avisa"       "0" "$(printf '%s\n' "${DOC_MSG[@]}" | grep -c "Sin 'dig'")"
check "y mira los dos dominios" "2" "$(printf '%s\n' "${DOC_ID[@]}" | grep -c '^dns:')"
unset -f nginx systemctl has_cert cert_days_left _have_dig dig

section "Un comando del menú conserva errexit"
# Bash apaga errexit dentro de un subshell que esté a la izquierda de un '||',
# y eso lo hereda incluso a través de una función auxiliar. Con errexit apagado,
# un comando que falla a mitad sigue adelante: 'orbit github' llegó a anunciar
# «GitHub conectado» después de que 'gh' fallara dos veces por no estar.
a_medias() { false; printf 'HE SEGUIDO\n'; printf 'y he dicho que todo bien\n'; }
SALIDA="$(_menu_run a_medias 2>&1 </dev/null)"
check "aborta al primer fallo"  "0" "$(grep -c 'HE SEGUIDO' <<<"$SALIDA")"
check "y no anuncia un éxito"   "0" "$(grep -c 'todo bien' <<<"$SALIDA")"
check "lo cuenta como error"    "1" "$(grep -c 'terminado con un error' <<<"$SALIDA")"
SALIDA="$(_menu_live a_medias 2>&1 </dev/null)"
check "igual a pantalla completa" "0" "$(grep -c 'HE SEGUIDO' <<<"$SALIDA")"
# Y lo que va bien sigue yendo bien: esto no puede volverse un abortador.
entero() { printf 'uno\n'; true; printf 'dos\n'; }
SALIDA="$(_menu_run entero 2>&1 </dev/null)"
check "lo que va bien, entero"  "1" "$(grep -c 'dos' <<<"$SALIDA")"
check "sin marcarlo como error" "0" "$(grep -c 'terminado con un error' <<<"$SALIDA")"

section "'orbit status' no se come la entrada estándar"
# El 'while read' de los servicios se quedó sin su '< <(_base_services)': leía
# de stdin, así que la lista salía vacía y además se tragaba lo que viniera
# detrás — desde el menú, las teclas que pulsabas después.
PHP_VER="8.3"
systemctl() { return 0; }
hostname() { printf 'x\n'; }
SALIDA="$(printf 'NO-ME-COMAS\n' | cmd_status 2>&1)"
check "lista nginx"        "1" "$(grep -c '● nginx' <<<"$SALIDA")"
check "lista postgresql"   "1" "$(grep -c '● postgresql' <<<"$SALIDA")"
check "y php-fpm"          "1" "$(grep -c '● php8.3-fpm' <<<"$SALIDA")"
check "no pinta la entrada" "0" "$(grep -c 'NO-ME-COMAS' <<<"$SALIDA")"
# Lo que le llegue por stdin tiene que seguir ahí para el siguiente.
SOBRA="$( { cmd_status >/dev/null 2>&1; cat; } <<<'SIGO-AQUI' )"
check "y la deja intacta"  "SIGO-AQUI" "$SOBRA"
unset -f systemctl hostname

section "El cortafuegos se le pregunta a ufw, no a systemd"
# 'ufw enable' carga las reglas en el kernel en ese momento y deja la unidad
# habilitada para el arranque siguiente, pero NO la arranca. Así que hasta el
# primer reinicio 'systemctl is-active ufw' contesta 'inactive' con el
# cortafuegos filtrando de verdad, y 'orbit status' anunciaba el cortafuegos
# apagado justo después de instalar — que es cuando más se mira. Medido en la
# máquina recién instalada: ExecMainStartTimestamp vacío y las reglas puestas.
systemctl() { return 1; }              # systemd dice que no a todo
ufw() { printf 'Status: active\n'; }
check "ufw activo aunque systemd diga que no" "0" "$(_service_activo ufw; echo $?)"
check "y los demás siguen mirando a systemd"  "1" "$(_service_activo nginx; echo $?)"
ufw() { printf 'Status: inactive\n'; }
check "y si ufw dice que no, es que no"       "1" "$(_service_activo ufw; echo $?)"
# La comparación es contra el texto de ufw, que ufw traduce. Sin fijar el
# idioma, un servidor en otra lengua diría que el cortafuegos está apagado.
check "se le pregunta en C"                   "1" \
  "$(grep -c 'LC_ALL=C ufw status' "$ORBIT_ROOT/orbit")"
# Y sin ufw instalado no se inventa nada.
ufw() { return 127; }
check "sin ufw, no está activo"               "1" "$(_service_activo ufw; echo $?)"
unset -f systemctl ufw

section "Un 'confirm' sin nadie delante no se inventa un sí en silencio"
# 'read' falla con EOF al instante cuando no hay nadie, y antes eso era un
# 'read -r a || true': la respuesta por defecto se tomaba **sin decirlo**, así
# que en la salida no había forma de distinguir «el usuario pulsó Enter» de «no
# había usuario». Con un valor por defecto que sea «sí» eso es una decisión
# tomada por nadie, y en 'orbit new' llegó a lanzar la emisión de un
# certificado de Let's Encrypt — una acción hacia fuera y con límites de
# frecuencia. La respuesta no cambia; lo que se arregla es el silencio.
_avisa() { grep -c 'sin nadie a quien preguntar\|nobody to ask' <<<"$1"; }
ASSUME_YES="no"
SALIDA="$(confirm "¿Seguimos?" y </dev/null 2>&1)"; r=$?
check "responde el valor por defecto" "0" "$r"
check "y lo dice"                     "1" "$(_avisa "$SALIDA")"
SALIDA="$(confirm "¿Seguimos?" n </dev/null 2>&1)"; r=$?
check "con defecto 'no', dice que no" "1" "$r"
check "y también lo dice"             "1" "$(_avisa "$SALIDA")"

# Y lo que la primera versión de este arreglo rompió, que por eso está aquí:
# miraba '! -t 0', o sea «no hay terminal», y **una tubería tampoco es un
# terminal pero sí trae respuesta**. Con eso, 'echo n | orbit …' dejaba de
# contestar que no y se quedaba con el valor por defecto. Lo cazó i18n_test,
# que le pasa las respuestas justo así. Lo que hay que mirar no es de dónde
# viene la entrada sino si 'read' consigue leer algo.
SALIDA="$(confirm "¿Seguimos?" y <<<'n' 2>&1)"; r=$?
check "una tubería sí contesta"       "1" "$r"
check "y ahí no sobra el aviso"       "0" "$(_avisa "$SALIDA")"
SALIDA="$(confirm "¿Seguimos?" n <<<'s' 2>&1)"; r=$?
check "y contesta que sí"             "0" "$r"
# Una línea sin salto final también es una respuesta: 'read' devuelve 1 y aun
# así ha leído. Sin el '[[ -z "$a" ]]', esto se trataría como si no hubiera
# nadie y contestaría lo contrario.
SALIDA="$(printf 'n' | confirm "¿Seguimos?" y 2>&1)"; r=$?
check "sin salto final, también"      "1" "$r"
check "y tampoco avisa"               "0" "$(_avisa "$SALIDA")"
# Un Enter a secas es contestar: se toma el valor por defecto, pero lo ha
# elegido alguien.
SALIDA="$(confirm "¿Seguimos?" y <<<'' 2>&1)"; r=$?
check "un Enter es el defecto"        "0" "$r"
check "sin avisar de nada"            "0" "$(_avisa "$SALIDA")"

# Con --yes hay alguien que ha dicho que sí de antemano: ahí no hay nada que
# avisar.
ASSUME_YES="yes"
SALIDA="$(confirm "¿Seguimos?" y </dev/null 2>&1)"
check "con --yes no sobra el aviso"   "0" "$(_avisa "$SALIDA")"
ASSUME_YES="no"
unset -f _avisa

section "Una copia que no es una copia se explica, no revienta"
# Con pipefail, 'tar' sobre un fichero corrupto sale con su código y la
# asignación lo hereda: errexit mataba a orbit con un 2 y sin una sola línea,
# antes de llegar al mensaje que explica qué pasa.
printf 'basura\n' | gzip > "$TMP/falso.tar.gz"
check "no dice de quién es" "" "$(_restore_name "$TMP/falso.tar.gz")"
( set -Eeuo pipefail; _restore_name "$TMP/falso.tar.gz" >/dev/null ) && r=0 || r=1
check "y no aborta"         "0" "$r"
tar czf "$TMP/sinmani.tar.gz" -C "$TMP" src 2>/dev/null
check "un tar sin manifiesto" "" "$(_restore_name "$TMP/sinmani.tar.gz")"

report
