#!/usr/bin/env bash
# ============================================================================
#  'orbit admin': el grupo orbit-admin, su regla de sudo y lo que Orbit deja de
#  fiarse cuando root actúa en nombre de otro.
#    bash tests/admin_test.sh
#
#  La regla se valida con el visudo de verdad, sobre ficheros bajo $TMP: nada
#  de esto toca /etc/sudoers.d, ni crea grupos, ni mete a nadie en ellos. Un
#  sudoers roto deja sin sudo a todo el servidor, incluido quien tendría que
#  arreglarlo, así que lo que más se prueba es que no se instale nada que
#  visudo no haya aceptado antes.
# ============================================================================
# shellcheck disable=SC2034  # asigna variables que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
SUDOERS_ADMIN="$TMP/sudoers.d/orbit-admin"; mkdir -p "$TMP/sudoers.d"
ORBIT_BIN="/usr/local/bin/orbit"

# --- dobles de las cuentas -------------------------------------------------
# Un passwd y un group de mentira, con la forma de los de verdad, y las tres
# órdenes que los cambian apuntando lo que hacen.
cat > "$TMP/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
deploy:x:1001:1001::/home/deploy:/bin/bash
ana:x:1002:1002::/home/ana:/bin/bash
luis:x:1003:1003::/home/luis:/bin/bash
orbit-tienda:x:998:998::/srv/apps/tienda:/usr/sbin/nologin
appuser:x:1500:1500::/home/appuser:/bin/bash
EOF
: > "$TMP/group"
CALLS="$TMP/calls"; : > "$CALLS"
getent() {
  local f
  case "$1" in passwd) f="$TMP/passwd" ;; group) f="$TMP/group" ;; *) return 2 ;; esac
  grep -m1 "^$2:" "$f" || return 2
}
groupadd() { printf 'groupadd %s\n' "$*" >> "$CALLS"; printf '%s:x:999:\n' "${*: -1}" >> "$TMP/group"; }
gpasswd() {
  printf 'gpasswd %s\n' "$*" >> "$CALLS"
  local op="$1" u="$2" g="$3" line mem
  line="$(grep "^$g:" "$TMP/group")"; mem="${line##*:}"
  case "$op" in
    -a) mem="${mem:+$mem,}$u" ;;
    -d) mem=",$mem,"; mem="${mem//,$u,/,}"; mem="${mem#,}"; mem="${mem%,}" ;;
  esac
  sed -i "s|^$g:.*|${line%:*}:$mem|" "$TMP/group"
}
# Como usuario normal no se puede dar un fichero a root; en el servidor, sí.
chown() { printf 'chown %s\n' "$*" >> "$CALLS"; }
DEPLOY_USER="deploy"

if ! command -v visudo >/dev/null; then
  echo "visudo no está (viene con sudo): me salto las pruebas de la regla de sudo."
  report
fi

# ═══════════════════════════════════════════════════════════════════════════
section "A quién no"
for u in noexiste root www-data nobody deploy '-o' 'Ana'; do
  run _admin_add "$u" >"$TMP/o" 2>&1; r=$?
  check "rechaza «$u»"            "1" "$r"
done
mkapp tienda node 3001; load_app tienda; A_USER="appuser"; save_app
run _admin_add appuser >"$TMP/o" 2>&1; r=$?
check "rechaza al usuario de una app" "1" "$r"
check "y dice de cuál"           "1" "$(grep -c 'tienda' "$TMP/o")"
# Ninguno de los rechazos ha dejado nada: ni regla, ni grupo, ni temporales.
check "sin regla"                "0" "$(find "$TMP/sudoers.d" -type f | wc -l)"
check "sin grupo"                "0" "$(grep -c . "$TMP/group")"

# ═══════════════════════════════════════════════════════════════════════════
section "Añadir"
run _admin_add ana >"$TMP/o" 2>&1; r=$?
check "añade"                    "0" "$r"
check "la regla existe"          "1" "$([[ -f "$SUDOERS_ADMIN" ]] && echo 1 || echo 0)"
check "con 0440"                 "440" "$(stat -c %a "$SUDOERS_ADMIN")"
check "y de root"                "1" "$(grep -c '^chown root:root ' "$CALLS")"
check "visudo la acepta"         "0" "$(visudo -c -f "$SUDOERS_ADMIN" >/dev/null 2>&1; echo $?)"
check "sólo nombra orbit"        "1" "$(grep -cx '%orbit-admin ALL=(root) NOPASSWD: /usr/local/bin/orbit' "$SUDOERS_ADMIN")"
check "una sola regla"           "1" "$(grep -vc '^#' "$SUDOERS_ADMIN")"
check "grupo de sistema"         "1" "$(grep -c '^groupadd --system orbit-admin$' "$CALLS")"
check "ana en el grupo"          "ana" "$(_admin_members)"
# Lo que no se puede callar: equivale a root.
check "avisa de que es root"     "1" "$(grep -c 'equivale a darle root' "$TMP/o")"
check "y de la sesión nueva"     "1" "$(grep -c 'sesión' "$TMP/o")"
check "sin temporales en sudoers.d" "0" "$(find "$TMP/sudoers.d" -name '.*' -type f | wc -l)"
check "lo apunta en el registro" "1" "$(grep -c 'admin add ana' "$LOG_FILE")"

section "El registro dice quién"
# Con varias personas actuando como root, «root hizo esto» no sirve: cada
# línea lleva el SUDO_USER que puso sudo. Se evalúan las dos líneas del script
# que lo deciden, con cada valor.
_quien() { # _quien <SUDO_USER> -> lo que queda en el registro
  local SUDO_USER="$1"; : > "$TMP/quien.log"
  eval "$(grep -E '^_LOG_WHO=|^\[\[ "\$\{SUDO_USER:-root\}"' "$ORBIT_ROOT/orbit")"
  LOG_FILE="$TMP/quien.log" logline "deploy web"
  sed 's/^[^ ]* //' "$TMP/quien.log"
}
check "las dos líneas están"     "2" "$(grep -cE '^_LOG_WHO=|^\[\[ "\$\{SUDO_USER:-root\}"' "$ORBIT_ROOT/orbit")"
check "a nombre de quien lo pidió" "[ana] deploy web" "$(_quien ana)"
check "root a secas, sin nombre" "deploy web" "$(_quien root)"
check "sin sudo, sin nombre"     "deploy web" "$(_quien "")"
check "un nombre raro no entra"  "deploy web" "$(_quien 'ana] x [root')"
_LOG_WHO=""

section "Añadir otra vez no cambia nada"
cp "$SUDOERS_ADMIN" "$TMP/regla.antes"; ino="$(stat -c %i "$SUDOERS_ADMIN")"
: > "$CALLS"
run _admin_add ana >"$TMP/o" 2>&1; r=$?
check "sale bien"                "0" "$r"
check "lo dice"                  "1" "$(grep -c 'ya era' "$TMP/o")"
check "sin gpasswd"              "0" "$(grep -c '^gpasswd' "$CALLS")"
check "sin groupadd"             "0" "$(grep -c '^groupadd' "$CALLS")"
check "la regla, la misma"       "$ino" "$(stat -c %i "$SUDOERS_ADMIN")"
check "un solo miembro"          "ana" "$(_admin_members)"
check "y vuelve a avisar"        "1" "$(grep -c 'equivale a darle root' "$TMP/o")"

run _admin_add luis >/dev/null 2>&1
check "dos miembros"             "ana luis" "$(_admin_members | tr '\n' ' ' | sed 's/ $//')"

# ═══════════════════════════════════════════════════════════════════════════
section "Lo que visudo no acepta no se instala"
# El caso que importa: una regla rota en sudoers.d deja sin sudo a todo el
# servidor. Se simula un visudo que la rechaza, y lo que había se queda.
visudo() { echo "parse error near line 3" >&2; return 1; }
sed -i 's/^luis:.*/luis:x:1003:1003::\/home\/luis:\/bin\/bash/' "$TMP/passwd"
printf 'nuevo:x:1004:1004::/home/nuevo:/bin/bash\n' >> "$TMP/passwd"
: > "$CALLS"
run _admin_add nuevo >"$TMP/o" 2>&1; r=$?
check "aborta"                   "1" "$r"
check "y cuenta por qué"         "1" "$(grep -c 'parse error' "$TMP/o")"
check "la regla de antes, intacta" "" "$(cmp "$TMP/regla.antes" "$SUDOERS_ADMIN" 2>&1)"
check "sin temporales"           "0" "$(find "$TMP/sudoers.d" -name '.*' -type f | wc -l)"
check "nadie añadido"            "0" "$(grep -c '^gpasswd' "$CALLS")"
unset -f visudo

# Y sin regla previa ni grupo, tampoco se crea el grupo: lo primero que se
# hace es validar.
mv "$SUDOERS_ADMIN" "$TMP/regla.guardada"; cp "$TMP/group" "$TMP/group.guardado"; : > "$TMP/group"
visudo() { return 1; }
: > "$CALLS"
run _admin_add nuevo >/dev/null 2>&1; r=$?
check "sin regla: aborta"        "1" "$r"
check "antes de crear el grupo"  "0" "$(grep -c '^groupadd' "$CALLS")"
check "y sin fichero"            "0" "$(find "$TMP/sudoers.d" -type f | wc -l)"
unset -f visudo
mv "$TMP/regla.guardada" "$SUDOERS_ADMIN"; cp "$TMP/group.guardado" "$TMP/group"

# Sin visudo no se instala a ciegas.
mkdir -p "$TMP/vacio"
for b in mktemp chmod cat dirname sed grep cmp mv rm date mkdir; do ln -sf "$(command -v "$b")" "$TMP/vacio/$b"; done
PATH="$TMP/vacio" run _admin_add nuevo >"$TMP/o" 2>&1; r=$?
check "sin visudo: aborta"       "1" "$r"
check "y lo dice"                "1" "$(grep -c 'visudo' "$TMP/o")"

# ═══════════════════════════════════════════════════════════════════════════
section "Quitar"
: > "$CALLS"
run _admin_remove luis >"$TMP/o" 2>&1; r=$?
check "quita"                    "0" "$r"
check "con gpasswd -d"           "1" "$(grep -cx 'gpasswd -d luis orbit-admin' "$CALLS")"
check "queda ana"                "ana" "$(_admin_members)"
check "avisa de las sesiones abiertas" "1" "$(grep -c 'loginctl terminate-user luis' "$TMP/o")"
: > "$CALLS"
run _admin_remove luis >"$TMP/o" 2>&1; r=$?
check "quitar a quien no está: bien" "0" "$r"
check "sin tocar nada"           "0" "$(grep -c . "$CALLS")"
check "la regla sigue"           "1" "$([[ -f "$SUDOERS_ADMIN" ]] && echo 1 || echo 0)"

section "La lista"
run _admin_list >"$TMP/o" 2>&1
check "enseña a ana"             "1" "$(grep -c 'ana' "$TMP/o")"
check "y dice lo que es"         "1" "$(grep -c 'equivale a ser root' "$TMP/o")"

# ═══════════════════════════════════════════════════════════════════════════
section "Por la línea de órdenes"
run cmd_admin >"$TMP/o" 2>&1; r=$?
check "sin subcomando, la lista" "0" "$r"
run cmd_admin add >/dev/null 2>&1; r=$?
check "add sin usuario"          "1" "$r"
run cmd_admin add ana luis >/dev/null 2>&1; r=$?
check "add con dos"              "1" "$r"
run cmd_admin bogus >/dev/null 2>&1; r=$?
check "subcomando desconocido"   "1" "$r"

# ═══════════════════════════════════════════════════════════════════════════
section "doctor: la regla"
lvl() { local i; for i in "${!DOC_ID[@]}"; do [[ "${DOC_ID[$i]}" == "$1" ]] && { echo "${DOC_LEVEL[$i]}"; return; }; done; }
reset_doc() { DOC_LEVEL=(); DOC_ID=(); DOC_MSG=(); DOC_FIX=(); DOC_ACT=(); }
reset_doc; _doctor_admin
check "en su sitio, con miembros: info" "info" "$(lvl admin)"
check "y nombra a quién"         "1" "$(printf '%s\n' "${DOC_MSG[@]}" | grep -c 'ana')"
chmod 0644 "$SUDOERS_ADMIN"; reset_doc; _doctor_admin
check "permisos flojos: error"   "error" "$(lvl admin)"
chmod 0440 "$SUDOERS_ADMIN"
cp "$SUDOERS_ADMIN" "$TMP/r"; chmod 0644 "$SUDOERS_ADMIN"
printf '%%orbit-admin ALL=(root) NOPASSWD /usr/local/bin/orbit\n' > "$SUDOERS_ADMIN"; chmod 0440 "$SUDOERS_ADMIN"
reset_doc; _doctor_admin
check "regla rota: error"        "error" "$(lvl admin)"
chmod 0644 "$SUDOERS_ADMIN"
printf '%%orbit-admin ALL=(root) NOPASSWD: /opt/otro/orbit\n' > "$SUDOERS_ADMIN"; chmod 0440 "$SUDOERS_ADMIN"
reset_doc; _doctor_admin
check "otro binario: aviso"      "warn" "$(lvl admin)"
rm -f "$SUDOERS_ADMIN"; reset_doc; _doctor_admin
check "miembros sin regla: aviso" "warn" "$(lvl admin)"
: > "$TMP/group"; reset_doc; _doctor_admin
check "nada de nada: silencio"   "" "$(lvl admin)"

# ═══════════════════════════════════════════════════════════════════════════
section "doctor: quién puede cambiar lo que root ejecuta"
# Se prueba el ayudante con el uid de quien ejecuta la tanda en vez del de
# root: la regla es la misma, y así no hace falta serlo.
ME="$(id -u)"; D="$TMP/arbol"; mkdir -p "$D/bin"
printf '#!/bin/bash\n' > "$D/bin/orbit"; chmod 0755 "$D/bin/orbit" "$D/bin" "$D"
check "todo en orden"            "" "$(_paths_unsafe "$ME" "$D" "$D/bin" "$D/bin/orbit")"
chmod o+w "$D/bin/orbit"
check "escribible por todos"     "$D/bin/orbit" "$(_paths_unsafe "$ME" "$D/bin/orbit")"
chmod o-w "$D/bin/orbit"; chmod g+w "$D/bin"
# Escribible por un grupo que no es el de root —el 'staff' que Debian ponía en
# /usr/local—: quien esté en él puede sustituir el binario.
if [[ "$(stat -c %g "$D/bin")" != 0 ]]; then
  check "escribible por un grupo" "$D/bin" "$(_paths_unsafe "$ME" "$D/bin")"
fi
chmod g-w "$D/bin"
mkdir -p "$D/pegajoso"; chmod 1777 "$D/pegajoso"
check "carpeta pegajosa: vale"   "" "$(_paths_unsafe "$ME" "$D/pegajoso")"
ln -s "$D/bin/orbit" "$D/enlace"
check "un enlace no cuenta"      "" "$(_paths_unsafe "$ME" "$D/enlace")"
check "otro dueño"               "$D/bin/orbit" "$(_paths_unsafe 0 "$D/bin/orbit")"
[[ "$ME" == 0 ]] && check "otro dueño" "$D/bin/orbit" "$(_paths_unsafe 4242 "$D/bin/orbit")"
# Lo que se mira entero: el binario y cada carpeta por encima, y todo lo que
# root carga con '.'. notify.conf también: lo carga cada aviso, o sea cada
# pasada del vigilante que tenga algo que contar.
mkdir -p "$TMP/etc/apps"; : > "$TMP/etc/notify.conf"; chmod 0644 "$TMP/etc/notify.conf"
ORBIT_BIN_SAVE="$ORBIT_BIN"; ORBIT_BIN="$D/bin/orbit"
reset_doc; _doctor_paths_as "$ME"
check "doctor mira la carpeta del binario" "0" "$(printf '%s\n' "${DOC_MSG[@]}" | grep -c "$D/bin[,]\|$D/bin\$")"
chmod o+w "$TMP/etc/notify.conf"
reset_doc; _doctor_paths_as "$ME"
check "notify.conf escribible: error" "error" "$(lvl paths)"
check "y lo nombra"              "1" "$(printf '%s\n' "${DOC_MSG[@]}" | grep -c 'notify.conf')"
chmod o-w "$TMP/etc/notify.conf"; chmod g+w,o+w "$D/bin"
reset_doc; _doctor_paths_as "$ME"
check "la carpeta del binario, también" "1" "$(printf '%s\n' "${DOC_MSG[@]}" | grep -c "$D/bin,\|$D/bin\$")"
chmod go-w "$D/bin"; ORBIT_BIN="$ORBIT_BIN_SAVE"
# Sin ser root, doctor no opina: todo sería de quien pregunta.
if [[ $EUID -ne 0 ]]; then
  reset_doc; _doctor_paths
  check "sin root, no opina"     "" "$(lvl paths)"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "El entorno de quien llama no decide nada"
# Se ejecuta el bloque de limpieza tal cual está en el script, con su misma
# primera línea y la guarda forzada —aquí nadie es root—, y un entorno de
# alguien que quisiera que root hiciera otra cosa. Se ejecuta como fichero y
# no con '.': cuando sobra algo, el bloque se vuelve a lanzar a sí mismo.
BLOQUE="$TMP/limpieza.sh"
{ head -1 "$ORBIT_ROOT/orbit"
  echo 'set -Eeuo pipefail'
  sed -n '/^# >>> limpieza del entorno/,/^# <<< limpieza del entorno/p' "$ORBIT_ROOT/orbit" \
    | sed 's|^if \[\[ \$EUID -eq 0 \&\& .*SUDO_UID.*; then$|if true; then|'
  cat <<'EOF'
for v in BACKUP_HOOK APPS_DIR METRICS_PROM_DIR ORBIT_LANG LANG LANGUAGE TERM SUDO_USER; do
  printf '%s=%s\n' "$v" "${!v-(nada)}"
done
printf 'PATH=%s\nHOME=%s\nUMASK=%s\nDIRTY=%s\n' "$PATH" "$HOME" "$(umask)" "${_ORBIT_ENV_DIRTY:-}"
printf 'HIJOS=%s\n' "$(/usr/bin/env | /usr/bin/grep -c '^a\.b=')"
printf 'FUNCIONES=%s\n' "$(declare -F | /usr/bin/wc -l)"
type systemctl 2>/dev/null | head -1
EOF
} > "$BLOQUE"
chmod +x "$BLOQUE"
check "el bloque está"           "1" "$(grep -c '^if true; then' "$BLOQUE")"
# Las funciones exportadas se llaman como las órdenes que usa el propio
# bloque: si bash las importara, 'set' y 'read' serían las de quien llama
# antes de que Orbit pudiera hacer nada. Con un 'read' importado que nunca
# falla el bucle no acabaría: de ahí el 'timeout' y el 'head', para que eso
# salga en rojo y no cuelgue la tanda llenando el disco.
env -i PATH="$TMP/malo:/usr/bin:/bin" HOME="/home/ana" BACKUP_HOOK='touch /tmp/pwned' \
  APPS_DIR=/tmp/x METRICS_PROM_DIR=/etc ORBIT_LANG=en LANG=es_ES.UTF-8 \
  LANGUAGE=../../../tmp/x TERM=xterm-256color SUDO_USER=ana SUDO_UID=1002 \
  'BASH_FUNC_systemctl%%=() { echo secuestrado; }' \
  'BASH_FUNC_set%%=() { echo secuestrado; }' 'BASH_FUNC_read%%=() { echo secuestrado; }' \
  'a.b=1' _ORBIT_ENV_DIRTY=yes \
  timeout 20 bash -c 'umask 077; exec "$1"' _ "$BLOQUE" 2>&1 | head -c 100000 > "$TMP/env.out"
check "BACKUP_HOOK fuera"        "1" "$(grep -cx 'BACKUP_HOOK=(nada)' "$TMP/env.out")"
check "APPS_DIR fuera"           "1" "$(grep -cx 'APPS_DIR=(nada)' "$TMP/env.out")"
check "los ajustes de Orbit fuera" "1" "$(grep -cx 'METRICS_PROM_DIR=(nada)' "$TMP/env.out")"
check "ORBIT_LANG se queda"      "1" "$(grep -cx 'ORBIT_LANG=en' "$TMP/env.out")"
check "LANG se queda"            "1" "$(grep -cx 'LANG=es_ES.UTF-8' "$TMP/env.out")"
check "LANGUAGE con ruta, fuera" "1" "$(grep -cx 'LANGUAGE=(nada)' "$TMP/env.out")"
check "TERM se queda"            "1" "$(grep -cx 'TERM=xterm-256color' "$TMP/env.out")"
check "quién lo pidió, se queda" "1" "$(grep -cx 'SUDO_USER=ana' "$TMP/env.out")"
check "PATH fijo"                "1" "$(grep -cx 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin' "$TMP/env.out")"
check "HOME de root"             "1" "$(grep -cx "HOME=$(eval echo ~root)" "$TMP/env.out")"
# Con un 077 de quien llama, cada release y cada vhost que creara root saldría
# sin lectura para nginx y php-fpm.
check "umask fija"               "1" "$(grep -cx 'UMASK=0022' "$TMP/env.out")"
# Lo que no tiene nombre de variable bash no lo importa, pero sí se lo pasaría
# a cada hijo: sólo el 'env -i' lo quita.
check "lo que no es variable, fuera de los hijos" "1" "$(grep -cx 'HIJOS=0' "$TMP/env.out")"
check "ninguna función importada" "1" "$(grep -cx 'FUNCIONES=0' "$TMP/env.out")"
check "ni secuestro"             "0" "$(grep -c 'secuestrado\|function' "$TMP/env.out")"
# Se relanza una vez y no en bucle: la segunda vez no sobra nada.
check "una sola salida"          "1" "$(grep -c '^PATH=' "$TMP/env.out")"
# Y cada motivo de relanzarse, solo: un entorno limpio salvo una cosa. Si no,
# lo demás que sobra lo taparía y una rama que no se cumpliera nunca seguiría
# en verde.
LIMPIO_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
LIMPIO_HOME="$(eval echo ~root)"
solo() { env -i SUDO_UID=1002 "$@" timeout 20 "$BLOQUE" 2>&1 | head -c 100000; }
check "sólo un nombre raro: fuera" "HIJOS=0" "$(solo PATH="$LIMPIO_PATH" HOME="$LIMPIO_HOME" 'a.b=1' | grep '^HIJOS=')"
check "sólo un PATH ajeno: fijo"   "PATH=$LIMPIO_PATH" "$(solo PATH="$TMP/malo:/usr/bin:/bin" HOME="$LIMPIO_HOME" | grep '^PATH=')"
check "sin PATH: se pone"          "1" "$(solo HOME="$LIMPIO_HOME" | grep -c '^PATH='"$LIMPIO_PATH"'$')"
check "sin HOME: se pone"          "HOME=$LIMPIO_HOME" "$(solo PATH="$LIMPIO_PATH" | grep '^HOME=')"
check "limpio del todo: igual"     "PATH=$LIMPIO_PATH" "$(solo PATH="$LIMPIO_PATH" HOME="$LIMPIO_HOME" | grep '^PATH=')"
# Sin /proc no se puede mirar: se apunta, y Orbit se niega a seguir.
sed 's|/proc/self/environ|/nonexistent/environ|g' "$BLOQUE" > "$TMP/limpieza-sinproc.sh"; chmod +x "$TMP/limpieza-sinproc.sh"
env -i BACKUP_HOOK=x SUDO_UID=1002 PATH=/usr/bin:/bin HOME=/home/ana "$TMP/limpieza-sinproc.sh" > "$TMP/env2.out" 2>&1
check "sin /proc, se apunta"     "1" "$(grep -cx 'DIRTY=yes' "$TMP/env2.out")"
# Y el script de verdad, con la guarda forzada y sin /proc, se para antes de
# hacer nada. Sin la auto-elevación (aquí sí se ejecutaría un sudo de verdad)
# y con la configuración de la tanda.
sed "s|^ETC_DIR=.*|ETC_DIR=\"$TMP/etc\"|; \
     s|/proc/self/environ|/nonexistent/environ|g; \
     s|^if \[\[ \$EUID -ne 0 \]\]; then|if false; then|; \
     s|^if \[\[ \$EUID -eq 0 \&\& .*SUDO_UID.*; then\$|if true; then|" \
    "$ORBIT_ROOT/orbit" > "$TMP/orbit-forzado"
chmod +x "$TMP/orbit-forzado"
check "la copia, sin elevación"  "1" "$(grep -c '^if false; then' "$TMP/orbit-forzado")"
env -i SUDO_UID=1002 PATH=/usr/bin:/bin "$TMP/orbit-forzado" version > "$TMP/env3.out" 2>&1; r=$?
check "y el script se niega"     "1" "$r"
check "diciendo por qué"         "1" "$(grep -c 'environ' "$TMP/env3.out")"
check "sin llegar a nada"        "0" "$(grep -c '^orbit ' "$TMP/env3.out")"
# Con /proc, la misma copia relanzada por 'env -i' llega a contestar: el
# relanzamiento funciona con el script entero y sus argumentos.
sed 's|/nonexistent/environ|/proc/self/environ|g' "$TMP/orbit-forzado" > "$TMP/orbit-forzado2"; chmod +x "$TMP/orbit-forzado2"
out="$(env -i SUDO_UID=1002 BACKUP_HOOK=x PATH=/usr/bin:/bin "$TMP/orbit-forzado2" version 2>&1)"
check "relanzado, contesta"      "orbit $ORBIT_VERSION" "$out"
# La marca de «no he podido limpiar» la pone Orbit y no se hereda: si viniera
# del entorno, bastaría un 'export' para que root no pudiera usar orbit.
sed "s|^ETC_DIR=.*|ETC_DIR=\"$TMP/etc\"|; \
     s|^if \[\[ \$EUID -ne 0 \]\]; then|if false; then|" \
    "$ORBIT_ROOT/orbit" > "$TMP/orbit-normal"
out="$(env -i _ORBIT_ENV_DIRTY=yes PATH=/usr/bin:/bin bash "$TMP/orbit-normal" version 2>&1)"
check "la marca no viene de fuera" "orbit $ORBIT_VERSION" "$out"
# Y sin ser root en nombre de otro, el bloque no toca nada.
sed -n '/^# >>> limpieza del entorno/,/^# <<< limpieza del entorno/p' "$ORBIT_ROOT/orbit" > "$TMP/limpieza2.sh"
printf 'printf "%%s\\n" "${BACKUP_HOOK-(nada)}"\n' >> "$TMP/limpieza2.sh"
if [[ $EUID -ne 0 ]]; then
  check "sin elevar, no limpia"  "x" "$(env -i BACKUP_HOOK=x SUDO_UID=1002 bash "$TMP/limpieza2.sh")"
fi
check "root de verdad, tampoco" "x" "$(env -i BACKUP_HOOK=x bash "$TMP/limpieza2.sh")"

# ═══════════════════════════════════════════════════════════════════════════
section "La auto-elevación"
# El intérprete por su ruta: con '/usr/bin/env bash', sudo resolvería 'bash'
# con el PATH que le pase el sudoers, antes de la primera línea de Orbit.
check "shebang sin env y con -p"  "#!/bin/bash -p" "$(head -1 "$ORBIT_ROOT/orbit")"
# Se eleva la ruta real: la regla nombra /usr/local/bin/orbit, y 'dv' —el
# enlace de install.sh— no se llama así. Se ejecuta el script de verdad con un
# 'sudo' de mentira que enseña con qué lo llamaron.
if [[ $EUID -ne 0 ]]; then
  mkdir -p "$TMP/elev/bin" "$TMP/elev/fake"
  cp "$ORBIT_ROOT/orbit" "$TMP/elev/bin/orbit"; chmod +x "$TMP/elev/bin/orbit"
  ln -s orbit "$TMP/elev/bin/dv"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$TMP/elev/fake/sudo"; chmod +x "$TMP/elev/fake/sudo"
  out="$(PATH="$TMP/elev/fake:$PATH" "$TMP/elev/bin/dv" list 2>&1 | tr '\n' ' ')"
  check "eleva la ruta real"     "-- $TMP/elev/bin/orbit list " "$out"
  out="$(ORBIT_LANG=en PATH="$TMP/elev/fake:$PATH" "$TMP/elev/bin/dv" list 2>&1 | tr '\n' ' ')"
  check "y se lleva el idioma"   "-- $TMP/elev/bin/orbit --lang en list " "$out"
else
  echo "  me salto la auto-elevación: corriendo como root no se eleva nada"
fi

report
