#!/usr/bin/env bash
# ============================================================================
#  El router: main() de punta a punta.
#
#  Las otras 33 suites cargan las funciones de 'orbit' SIN main —tests/lib.sh
#  corta la última línea del script a propósito, y hace bien: así se puede
#  llamar a una función suelta sin montar un servidor—. El efecto secundario es
#  que las 110 líneas donde viven el bucle de banderas globales, '_json_strip',
#  '_lang_strip', la criba de '_json_capable' y el árbol de despacho entero
#  **no las ejecutaba ninguna prueba**.
#
#  Y eso no es una laguna teórica: 'orbit doctor --fix --json --yes' estuvo
#  documentado en USAGE.md y muerto durante versiones, porque
#  'doctorfix_test.sh' llama a 'cmd_doctor --fix' como FUNCIÓN, saltándose
#  main(), que es donde se leen las banderas. La prueba pasaba y el comando no
#  funcionaba.
#
#  Esta suite invoca el script COMO BINARIO, que es como lo invoca una persona
#  y como lo invocará cualquier cliente que hable por SSH.
# ============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Una copia ejecutable con ETC_DIR redirigido y la auto-elevación fuera. No se
# reutiliza $TMP/orbitlib.sh porque a ése le falta justamente la línea que
# aquí interesa.
sed "s|^ETC_DIR=.*|ETC_DIR=\"$TMP/etc\"|; \
     s|^LOG_FILE=.*|LOG_FILE=\"$TMP/orbit.log\"|; \
     s|^if \[\[ \$EUID -ne 0 \]\]; then|if false; then|; \
     s|^need_root() {.*|need_root() { return 0; }|" \
    "$ORBIT_ROOT/orbit" > "$TMP/orbitcli"
chmod +x "$TMP/orbitcli"
O="$TMP/orbitcli"

# Dos apps, para que los selectores tengan de dónde elegir y para que el orden
# alfabético signifique algo.
mkapp app-a static ""
mkapp app-b node 3001

rc() { "$@" >/dev/null 2>&1; echo $?; }

# ── banderas globales ──────────────────────────────────────────────────────
section "Banderas globales"

check "--json delante"        "0" "$(rc "$O" --json version)"
check "--json detrás"         "0" "$(rc "$O" version --json)"
check "--lang sin valor"      "1" "$(rc "$O" --lang)"
check "--lang inexistente"    "1" "$(rc "$O" --lang klingon list)"
check "comando desconocido"   "1" "$(rc "$O" noexiste)"

# --json DELANTE de un comando que no lo habla lo criba '_json_capable' en
# main y muere. Eso es el contrato.
check "--json donde no lo hay, delante" "1" "$(rc "$O" --json exec app-a ls)"

# DETRÁS es otra historia, y esta prueba existe para dejarla escrita: main sólo
# saca el '--json' de los argumentos cuando el comando dice hablarlo, así que en
# los demás llega al parser del propio comando — y lo que pase ahí depende de si
# ese comando filtra opciones desconocidas. 'cmd_service' no lo hace, así que
# 'orbit restart app-a --json' **se traga la bandera y sale con 0**.
#
# No se arregla aquí: hacer que todos los comandos rechacen lo que no conocen es
# un cambio de comportamiento en veintitantos sitios y merece su propio PR. Lo
# que hace falta hoy es que esté fijado, para que el día que cambie sea a
# propósito. Y para un cliente la consecuencia práctica es una regla: **--json
# siempre delante**, que es la única posición con un comportamiento definido.
check "--json detrás, en un comando que no lo habla, se ignora" "0" \
  "$(rc "$O" restart app-a --json)"

# ── el contrato ────────────────────────────────────────────────────────────
section "El contrato"

VER="$("$O" version --json 2>/dev/null)"
check "version --json es un objeto" "{" "${VER:0:1}"
check "publica schema"              "1" "$(sed -n 's/.*"schema":\([0-9]*\).*/\1/p' <<<"$VER")"
check "publica contract"            "1" "$(sed -n 's/.*"contract":\([0-9]*\).*/\1/p' <<<"$VER")"

# La lista NO se escribe a mano: se saca del propio script. Si '_json_capable'
# gana una entrada y esta prueba no, la que se queda corta miente — es la misma
# trampa que el comentario de '_json_cmds_help' cuenta sobre la ayuda.
#
# Se excluyen los que necesitan un subcomando o un argumento ('env list <app>',
# 'db list', 'deploy <app>'…): ésos tienen su propia suite, y aquí lo que se
# prueba es el router.
section "Los comandos que dicen hablar JSON, lo hablan"
while read -r c; do
  case "$c" in
    env|db|database|redirect|redir|watch|queue|cola|colas|deploy|up|backup|copia|logs|log) continue ;;
    metricas|métricas|trafico|tráfico|ls|show|check|-v|--version) continue ;;
    # 'info' exige el nombre de la app con --json, y hace bien: un cliente no
    # puede contestar a un selector. Se prueba abajo, en su sección.
    info) continue ;;
  esac
  out="$("$O" --json "$c" 2>/dev/null)"
  check "orbit --json $c" "{" "${out:0:1}"
done < <(sed -n '/^_json_capable()/,/^}/p' "$ORBIT_ROOT/orbit" \
         | grep -oE '^ +[a-z|-]+\)' | tr -d ' )' | tr '|' '\n' | grep -v '^\*$')

# ── lo documentado se puede ejecutar ───────────────────────────────────────
section "Lo documentado se puede ejecutar"

# Regresión del arreglo de 'doctor'. Antes, esto salía con 1 y el mensaje
# «no sé qué es «--yes»» — o sea que USAGE.md documentaba un camino muerto.
check "doctor acepta --yes" "no" \
  "$("$O" doctor --fix --json --yes 2>&1 >/dev/null | grep -qF -- '«--yes»' && echo si || echo no)"

# Y la guarda sigue en pie: sin --yes, 'doctor --fix --json' se niega, porque
# sin terminal no hay a quién preguntar.
check "y sin --yes se sigue negando" "1" "$(rc "$O" doctor --fix --json)"

# ── el contrato de backup ──────────────────────────────────────────────────
section "backup list/verify --json"

export BACKUP_DIR="$TMP/backups"; mkdir -p "$BACKUP_DIR"
BL="$("$O" backup list --json 2>/dev/null)"
check "sin copias es una colección vacía" "0" \
  "$(sed -n 's/.*"total":\([0-9]*\).*/\1/p' <<<"$BL")"
check "y no un silencio" "{" "${BL:0:1}"

echo hola > "$TMP/x.txt"
tar -czf "$BACKUP_DIR/mi-web-20260829-031500.tar.gz" -C "$TMP" x.txt
tar -czf "$BACKUP_DIR/_orbit-conf-20260829-031500.tar.gz" -C "$TMP" x.txt
BL="$("$O" backup list --json 2>/dev/null)"
check "dos copias" "2" "$(sed -n 's/.*"total":\([0-9]*\).*/\1/p' <<<"$BL")"
# El nombre de app se recorta por el sufijo de fecha y no por el primer guion:
# 'mi-web' tiene uno dentro, y cortar por él daría 'mi'.
check "el guion del nombre sobrevive" "1" \
  "$(grep -c '"app":"mi-web"' <<<"$BL")"
check "la copia global no tiene app" "1" \
  "$(grep -c '"kind":"config"' <<<"$BL")"
check "--json fuera de list/verify se rechaza" "1" "$(rc "$O" backup create --json)"

# 'ok' es booleano y es la misma regla que el código de salida: un cliente que
# mire el objeto y otro que mire el rc no pueden discrepar nunca.
: > "$BACKUP_DIR/rota-20260828-031500.tar.gz"
BV="$("$O" backup verify --json 2>/dev/null)"
check "con una copia rota, ok:false" "1" "$(grep -c '"ok":false}$' <<<"$BV")"
check "y el rc concuerda"            "1" "$(rc "$O" backup verify --json)"
rm -f "$BACKUP_DIR/rota-20260828-031500.tar.gz" "$BACKUP_DIR/mi-web-20260829-031500.tar.gz"
check "todas sanas, rc 0"            "0" "$(rc "$O" backup verify --json)"

# ── el contrato de logs ────────────────────────────────────────────────────
section "logs --json"

export NGINX_LOG_DIR="$TMP/nginxlog"; mkdir -p "$NGINX_LOG_DIR"
# El banco redirige los logs; el script de verdad los tiene fijos, así que se
# parchea la copia igual que se parchea ETC_DIR.
sed -i -e 's|^nginx_log_access() .*|nginx_log_access() { echo "$NGINX_LOG_DIR/$1.access.log"; }|' \
       -e 's|^nginx_log_error()  .*|nginx_log_error()  { echo "$NGINX_LOG_DIR/$1.error.log"; }|' "$O"

printf '[29/Aug/2026:14:02:11 +0200] GET / 200\nsin marca\n' > "$NGINX_LOG_DIR/app-a.access.log"
printf '2026/08/29 14:03:01 [error] algo\n' > "$NGINX_LOG_DIR/app-a.error.log"

LJ="$("$O" logs app-a --json --nginx 2>/dev/null)"
check "la primera línea es el meta" "1" "$(head -1 <<<"$LJ" | grep -c '"event":"meta"')"
check "y lleva el schema"           "1" "$(head -1 <<<"$LJ" | grep -c '"schema":1')"
# Con --json no se sigue en vivo por defecto, que es la regla de 'orbit top':
# en modo máquina, una foto.
check "follow es false por defecto" "1" "$(head -1 <<<"$LJ" | grep -c '"follow":false')"
check "acceso y error se distinguen" "1" "$(grep -c '"stream":"error"' <<<"$LJ")"
# El log de acceso lleva huso; el de error no lo lleva y no se le inventa.
check "el huso del acceso se conserva" "1" "$(grep -c '"ts":"2026-08-29T14:02:11+02:00"' <<<"$LJ")"
check "sin marca de tiempo es null"    "1" "$(grep -c '"ts":null' <<<"$LJ")"
check "termina con un end"             "1" "$(tail -1 <<<"$LJ" | grep -c '"event":"end"')"
check "y cuenta las líneas"            "3" "$(tail -1 <<<"$LJ" | sed -n 's/.*"lines":\([0-9]*\).*/\1/p')"
# El tope de --lines es por fuente, igual que 'tail -n N f1 f2'.
check "el tope se anuncia" "1" \
  "$("$O" logs app-a --json --nginx --lines 1 2>/dev/null | tail -1 | grep -c '"truncated":true')"
check "y sin tope no se anuncia" "1" \
  "$(tail -1 <<<"$LJ" | grep -c '"truncated":false')"
# Un cliente no puede contestar a un selector.
check "sin app, --json aborta" "1" "$(rc "$O" logs --json)"

# ── sin terminal no se elige por el usuario ────────────────────────────────
section "Sin terminal no se elige por el usuario"

# Esto NO arregla nada: documenta el comportamiento de hoy con una prueba.
# 'pick_app' sin TTY devuelve el valor por defecto, que es la primera app por
# orden alfabético, y el comando sigue adelante con rc 0. Cambiarlo afectaría a
# once comandos y merece su propio PR con su propia discusión; lo que hace
# falta hoy es que el día que alguien lo cambie sea porque quiso.
check "info sin app elige la primera" "app-a" \
  "$("$O" info </dev/null 2>/dev/null | sed -n '2p' | tr -d ' ')"
# Y los tres que sí se protegen, que son los que un cliente usa.
check "info --json no elige"     "1" "$(rc "$O" info --json)"
check "deploy --json no elige"   "1" "$(rc "$O" deploy --json)"
check "logs --json no elige"     "1" "$(rc "$O" logs --json)"

report
