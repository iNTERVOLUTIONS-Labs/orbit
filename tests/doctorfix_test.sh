#!/usr/bin/env bash
# 'orbit doctor --fix': qué arregla, qué no toca y qué cuenta después.
#   bash tests/doctorfix_test.sh
#
# Lo delicado de este comando no es arreglar: es **no** arreglar lo que no le
# toca. Un diagnóstico que decide por su cuenta qué borrar de un disco lleno,
# o que instala paquetes en el servidor de alguien, deja de ser un diagnóstico.
#
# shellcheck disable=SC2034  # asigna variables A_* que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"

# --- lo que el arreglo tocaría, anotado en vez de ejecutado ----------------
ACCIONES="$TMP/acciones"; : > "$ACCIONES"
ARRANCADOS="$TMP/arrancados"; : > "$ARRANCADOS"
systemctl() {
  printf '%s\n' "$*" >> "$ACCIONES"
  case "${1:-}" in
    start)    printf '%s\n' "${2:-}" >> "$ARRANCADOS"; return 0 ;;
    is-active)
      # Sólo está vivo lo que alguien haya arrancado en esta prueba.
      local u="${*: -1}"; grep -qx "$u" "$ARRANCADOS" ;;
    *) return 0 ;;
  esac
}
sleep() { :; }   # _fix_service espera un segundo antes de comprobar

section "Un servicio parado se arranca, y se comprueba que sigue vivo"
: > "$ARRANCADOS"
run _fix_service postgresql; check "lo arranca" "0" "$?"
check "y lo hace de verdad" "1" "$(grep -cx 'postgresql' "$ARRANCADOS")"

# Arrancar no es estar vivo: una unidad puede aceptar el 'start' y morirse acto
# seguido. Si sólo se mirara el código de 'systemctl start', el diagnóstico
# diría «arreglado» sobre un servicio que sigue caído.
systemctl() {
  case "${1:-}" in
    start) return 0 ;;        # acepta el arranque…
    is-active) return 1 ;;    # …pero no llega a levantar
    *) return 0 ;;
  esac
}
run _fix_service postgresql; check "si no levanta, falla" "1" "$?"

section "Un autodespliegue en rojo se dice, y no se apaga solo"
# Una pasada fallida deja 'orbit-autodeploy.service' en estado 'failed', y eso
# es deliberado: es el aviso de que el automático no está funcionando. Lo que
# faltaba es que alguien lo contara — 'systemctl is-system-running' pasa a
# decir «degraded» y el diagnóstico, que es donde se va a mirar, no lo
# mencionaba. Visto en un servidor de verdad tras romper un build a propósito.
_ad_failed="si"
systemctl() {
  case "${1:-}" in
    is-failed) [[ "$_ad_failed" == "si" ]] ;;
    is-active) return 0 ;;
    *) return 0 ;;
  esac
}
_doctor_collect
_idx_de() { local i; for i in "${!DOC_ID[@]}"; do [[ "${DOC_ID[$i]}" == "$1" ]] && { echo "$i"; return; }; done; }
I="$(_idx_de autodeploy)"
check "lo ve"                "1" "$([[ -n "$I" ]] && echo 1 || echo 0)"
check "y como aviso"         "warn" "${DOC_LEVEL[${I:-0}]:-}"
check "diciendo dónde mirar" "1" "$(grep -c 'journalctl' <<<"${DOC_FIX[${I:-0}]:-}")"
# Y NO lo arregla solo: un 'reset-failed' automático borraría la única señal de
# que los despliegues automáticos están fallando. Apagar la alarma no es
# arreglar el fuego.
check "pero no lo apaga solo" "" "${DOC_ACT[${I:-0}]:-}"
# Y cuando está en verde, ni se menciona.
_ad_failed="no"; _doctor_collect
check "en verde no dice nada" "" "$(_idx_de autodeploy)"
unset -f systemctl _idx_de
systemctl() {
  printf '%s\n' "$*" >> "$ACCIONES"
  case "${1:-}" in
    start)    printf '%s\n' "${2:-}" >> "$ARRANCADOS"; return 0 ;;
    is-active) local u="${*: -1}"; grep -qx "$u" "$ARRANCADOS" ;;
    *) return 0 ;;
  esac
}

section "Una cola sin nadie que la ejecute se dice, aunque no haya nada rojo"
# Este es el fallo silencioso que motiva 'orbit queue' (ARCHITECTURE §18.9):
# con QUEUE_CONNECTION=database y ningún worker, los trabajos se apilan en la
# tabla, la web sigue contestando 200 y no hay error en ninguna parte. El aviso
# del despliegue sólo lo ve quien despliega; aquí lo ve quien pregunta qué va
# mal, que es cuando alguien echa de menos un correo.
mkapp cola laravel ""
mkdir -p "$TMP/apps/cola/shared"
printf 'QUEUE_CONNECTION=database\n' > "$TMP/apps/cola/shared/.env"
_q_failed="no"; _q_timer="si"
systemctl() {
  case "${1:-}" in
    is-failed) [[ "$_q_failed" == "si" ]] ;;
    is-active) [[ "$*" == *orbit-queue.timer* ]] && [[ "$_q_timer" == "si" ]] ;;
    *) return 0 ;;
  esac
}
_idx_de() { local i; for i in "${!DOC_ID[@]}"; do [[ "${DOC_ID[$i]}" == "$1" ]] && { echo "$i"; return; }; done; }
_doctor_collect
I="$(_idx_de queue-cola)"
check "ve la cola sin worker" "1" "$([[ -n "$I" ]] && echo 1 || echo 0)"
check "y como aviso"          "warn" "${DOC_LEVEL[${I:-0}]:-}"
check "diciendo qué escribir" "1" "$(grep -c 'orbit queue enable' <<<"${DOC_FIX[${I:-0}]:-}")"
# Con el temporizador puesto ya hay quien los ejecute: repetir el aviso sería
# mandar a arreglar lo que no está roto.
load_app cola; A_QUEUE="yes"; save_app
_doctor_collect
check "con la cola puesta, calla" "" "$(_idx_de queue-cola)"

# Y el caso contrario, que se lee peor porque no hay nada rojo en ninguna
# parte: apps con la cola puesta y el temporizador parado.
_q_timer="no"; _doctor_collect
I="$(_idx_de queue)"
check "temporizador parado, aviso" "1" "$([[ -n "$I" ]] && echo 1 || echo 0)"
_q_timer="si"

# Un ciclo fallido deja la unidad en 'failed' a propósito —es el único aviso
# que hay de que los trabajos se están apilando— y el ciclo siguiente la pone
# en verde sola. Como en el autodespliegue, doctor lo cuenta y no lo apaga.
_q_failed="si"; _doctor_collect
I="$(_idx_de queue)"
check "y la unidad en rojo"        "1" "$([[ -n "$I" ]] && echo 1 || echo 0)"
check "sin apagarla"               ""  "${DOC_ACT[${I:-0}]:-}"
_q_failed="no"
rm -f "$(app_conf cola)" "$TMP/apps/cola/shared/.env"
unset -f systemctl _idx_de
systemctl() {
  printf '%s\n' "$*" >> "$ACCIONES"
  case "${1:-}" in
    start)    printf '%s\n' "${2:-}" >> "$ARRANCADOS"; return 0 ;;
    is-active) local u="${*: -1}"; grep -qx "$u" "$ARRANCADOS" ;;
    *) return 0 ;;
  esac
}

section "Una app en mantenimiento se dice, y tampoco se levanta sola"
# Orbit contaba el mantenimiento de Laravel ('php artisan down') y se callaba el
# suyo. Importa porque la bandera vive en shared/ y **sobrevive al arranque de
# la máquina**: en el arranque no corre nada de Orbit (ARCHITECTURE §5.5), así
# que un despliegue muerto de mala manera —SIGKILL, corte de luz; con SIGTERM la
# trampa de salida sí la retira— deja una web devolviendo 503 y nadie la
# levanta. El vigilante lo avisa a los WATCH_MAINT_MAX minutos, pero sólo si
# está encendido; el diagnóstico es donde se pregunta qué pasa.
_have_dig() { return 1; }              # sin salir a la red por un dominio .test
cert_days_left() { echo ""; }
mkapp mant node 3009 mant.test
install -d "$(app_shared mant)"
: > "$(maint_flag mant)"
_doctor_collect
_idx_de() { local i; for i in "${!DOC_ID[@]}"; do [[ "${DOC_ID[$i]}" == "$1" ]] && { echo "$i"; return; }; done; }
I="$(_idx_de maint-mant)"
check "lo ve"                 "1" "$([[ -n "$I" ]] && echo 1 || echo 0)"
check "y como aviso"          "warn" "${DOC_LEVEL[${I:-0}]:-}"
check "diciendo cómo quitarlo" "1" "$(grep -c 'maintenance off mant' <<<"${DOC_FIX[${I:-0}]:-}")"
# Sin acción: un mantenimiento se pone a mano y con motivo, y publicar una web
# que alguien había bajado a propósito es peor que dejarla bajada.
check "pero no lo quita solo" "" "${DOC_ACT[${I:-0}]:-}"
# Y sin bandera, ni se menciona. La mutación de contarlo siempre muere aquí.
rm -f "$(maint_flag mant)"
_doctor_collect
check "sin mantenimiento no dice nada" "" "$(_idx_de maint-mant)"
rm -f "$(app_conf mant)"; rm -rf "$(app_dir mant)"
# Sólo el ayudante de la sección: '_have_dig' y 'cert_days_left' son funciones
# de verdad de 'orbit', y un 'unset -f' aquí se las lleva por delante para lo
# que venga después — el 'cmd_doctor --fix' de más abajo salía con 127.
unset -f _idx_de

section "Una app con proceso caída se dice, y tampoco se levanta sola"
# Doctor no miraba si las apps estaban vivas: con la unidad parada salía sin
# una palabra del tema —nginx válido, PostgreSQL activo, disco bien— mientras
# 'orbit list' sí decía 'stopped'. O sea que el dato existía y no estaba donde
# se pregunta «¿qué va mal?». Salió comprobando el arranque en frío de un
# servidor de verdad: la web devolvía 502 y el diagnóstico decía rc=0.
_have_dig() { return 1; }
cert_days_left() { echo ""; }
_idx_de() { local i; for i in "${!DOC_ID[@]}"; do [[ "${DOC_ID[$i]}" == "$1" ]] && { echo "$i"; return; }; done; }
: > "$ARRANCADOS"                      # nadie vivo: la unidad está parada
mkapp caida node 3011 caida.test
_doctor_collect
I="$(_idx_de service-caida)"
check "lo ve"                    "1"     "$([[ -n "$I" ]] && echo 1 || echo 0)"
check "y como error, no aviso"   "error" "${DOC_LEVEL[${I:-0}]:-}"
check "diciendo dónde mirar"     "1"     "$(grep -c 'orbit logs caida' <<<"${DOC_MSG[${I:-0}]:-}${DOC_FIX[${I:-0}]:-}")"
# Sin acción, por lo mismo que el mantenimiento: una app puede estar parada
# porque alguien la paró, y si se está muriendo en bucle arrancarla no arregla
# nada — apaga la señal y deja el fuego.
check "pero no la arranca sola"  ""      "${DOC_ACT[${I:-0}]:-}"

# Con la unidad viva, ni se menciona. La mutación de contarlo siempre muere aquí.
printf 'orbit-caida\n' >> "$ARRANCADOS"
_doctor_collect
check "corriendo, no dice nada"  ""      "$(_idx_de service-caida)"

# Y una estática no está parada: es que no hay nada que arrancar, que no es lo
# mismo. Sin esta distinción, cada sitio estático del servidor saldría como
# app caída y el diagnóstico se volvería ruido.
mkapp quieta static 0 quieta.test
_doctor_collect
check "una estática no está caída" ""    "$(_idx_de service-quieta)"

rm -f "$(app_conf caida)" "$(app_conf quieta)"
rm -rf "$(app_dir caida)" "$(app_dir quieta)"
: > "$ARRANCADOS"
unset -f _idx_de

section "Una app registrada sin vhost se dice, y ésta sí se arregla sola"
# El agujero: un descriptor sin vhost es una app registrada, compilada, con su
# pool de php-fpm escrito y su unidad en verde, cuyo dominio no atiende nadie.
# La petición cae en el servidor por defecto y el visitante recibe la conexión
# cerrada — ni 404 ni 502; curl dice 000, que es lo que no dice nada.
#
# Y no lo veía ninguna de las tres preguntas que se hacen: 'nginx -t' pasa,
# porque lo que falta no es sintaxis sino un fichero; 'orbit list' pintaba
# 'php-fpm', que es una constante escrita para las apps PHP y no puede acusar
# a nadie; y doctor salía entero en verde. Salió en un servidor de verdad,
# comprobando el arranque en frío: una app llevaba una hora invisible.
_have_dig() { return 1; }
cert_days_left() { echo ""; }
nginx() { return 0; }                  # 'nginx -t' del render, sin el binario
_idx_de() { local i; for i in "${!DOC_ID[@]}"; do [[ "${DOC_ID[$i]}" == "$1" ]] && { echo "$i"; return; }; done; }
mkapp huerfana static 0 huerfana.test
rm -f "$(nginx_file huerfana)" "$(nginx_link huerfana)"
_doctor_collect
I="$(_idx_de vhost-huerfana)"
check "lo ve"                  "1"     "$([[ -n "$I" ]] && echo 1 || echo 0)"
check "y como error"           "error" "${DOC_LEVEL[${I:-0}]:-}"
# Éste SÍ lleva acción, al revés que el mantenimiento o la unidad parada:
# aquéllos pueden ser una decisión de alguien y deshacerla sin preguntar es
# peor que dejarla. Un vhost que falta no lo decide nadie, y se regenera del
# descriptor, así que rehacerlo no inventa nada.
check "y con arreglo"          "1"     "$([[ -n "${DOC_ACT[${I:-0}]:-}" ]] && echo 1 || echo 0)"

run _fix_vhost huerfana >/dev/null 2>&1; check "el arreglo funciona" "0" "$?"
check "escribe el vhost"       "1"     "$([[ -f "$(nginx_file huerfana)" ]] && echo 1 || echo 0)"
check "y lo enlaza"            "1"     "$([[ -L "$(nginx_link huerfana)" ]] && echo 1 || echo 0)"

# Con el vhost puesto, ni se menciona. La mutación de acusar siempre muere aquí.
_doctor_collect
check "ya no dice nada"        ""      "$(_idx_de vhost-huerfana)"

# Y la otra mitad del agujero: el fichero está y el enlace no. nginx no lo
# carga, así que la web está igual de muerta y el fichero engaña a quien mire
# sólo sites-available.
rm -f "$(nginx_link huerfana)"
_doctor_collect
check "el enlace suelto también cuenta" "1" \
  "$([[ -n "$(_idx_de vhost-huerfana)" ]] && echo 1 || echo 0)"

# El arreglo escribe el vhost de la app que se le pide, no el de la que
# estuviera cargada: los arreglos corren DESPUÉS del recorrido de las apps, así
# que las A_* traen las de la última que se miró. Quien lo salva es el
# 'load_app' que hace 'nginx_vhost' por su cuenta — el primer '_fix_vhost'
# llevaba uno propio, redundante, y quitarlo no ponía en rojo nada, que es como
# se supo. La comprobación se queda como control de eso: si algún día
# 'nginx_vhost' deja de cargar la app, aquí sale.
mkapp otra static 0 otra.test
rm -f "$(nginx_file huerfana)" "$(nginx_link huerfana)"
load_app otra
run _fix_vhost huerfana >/dev/null 2>&1
check "y escribe el de la app que toca" "1" \
  "$(grep -c 'huerfana.test' "$(nginx_file huerfana)")"

rm -f "$(app_conf huerfana)" "$(app_conf otra)" \
      "$(nginx_file huerfana)" "$(nginx_link huerfana)"
rm -rf "$(app_dir huerfana)" "$(app_dir otra)"
unset -f nginx _idx_de

section "Sólo se arregla lo que está roto"
# Un 'ok' con acción no debería existir, pero si existiera, arreglar lo que
# funciona sería lo peor que podría hacer este comando.
TOCADO="$TMP/tocado"; : > "$TOCADO"
_fix_marca() { printf 'tocado\n' >> "$TOCADO"; return 0; }
DOC_LEVEL=(ok info); DOC_ID=(a b); DOC_MSG=("bien" "dato")
DOC_FIX=("" ""); DOC_ACT=("_fix_marca" "_fix_marca")
run _doctor_fix >/dev/null 2>&1
check "no toca lo que está bien" "0" "$(wc -l < "$TOCADO")"

DOC_LEVEL=(warn error); DOC_ID=(a b); DOC_MSG=("aviso" "error")
DOC_FIX=("" ""); DOC_ACT=("_fix_marca" "_fix_marca")
run _doctor_fix >/dev/null 2>&1
check "sí lo que está mal"       "2" "$(wc -l < "$TOCADO")"

section "Un arreglo que falla se cuenta como fallo"
_fix_roto() { return 1; }
DOC_LEVEL=(error); DOC_ID=(x); DOC_MSG=("algo")
DOC_FIX=("hazlo a mano así"); DOC_ACT=("_fix_roto")
SALIDA="$(run _doctor_fix 2>&1)"; RC=$?
check "devuelve fallo"    "1" "$RC"
check "lo dice"           "1" "$(grep -c 'No he podido arreglar' <<<"$SALIDA")"
# Si no puede, al menos que diga cómo se hace a mano: quedarse callado deja al
# usuario con un problema y sin la frase que ya estaba escrita.
check "y remite al manual" "1" "$(grep -c 'hazlo a mano así' <<<"$SALIDA")"

section "Un arreglo que aborta a mitad no cuenta como éxito"
# Dentro de un 'if' bash apaga errexit y el subshell lo hereda, así que un
# arreglo que muere a la mitad devolvería 0 y diríamos «arreglado». Es la
# trampa de ARCHITECTURE §20.7, aquí sobre el propio arreglador.
_fix_a_medias() { false; printf 'no debería llegar\n'; return 0; }
DOC_LEVEL=(error); DOC_ID=(x); DOC_MSG=("algo"); DOC_FIX=(""); DOC_ACT=("_fix_a_medias")
run _doctor_fix >/dev/null 2>&1; check "se entera" "1" "$?"

section "Cuántos ha aplicado"
_fix_bien() { return 0; }
DOC_LEVEL=(error warn error); DOC_ID=(a b c); DOC_MSG=(1 2 3)
DOC_FIX=("" "" ""); DOC_ACT=("_fix_bien" "" "_fix_bien")
# Sin 'run': el contador vuelve por REPLY, y REPLY escrito dentro de un
# subshell se pierde al salir de él.
#
# El precio es que hay que apagar errexit después. _doctor_fix usa el patrón
# que documenta docs/DEVELOPMENT.md —'set +e; ( set -Eeuo pipefail; … ); rc=$?; set -e'—
# y ese 'set -e' final no restaura el estado anterior: lo enciende. Dentro de
# 'orbit' da igual, porque allí siempre está encendido; aquí no, y sin este
# 'set +e' el primer 'run' que devolviera 1 mataría la prueba entera sin decir
# una palabra. Costó encontrarlo: el síntoma era el script terminando en seco.
_doctor_fix >/dev/null 2>&1; set +e
check "los cuenta" "2" "$REPLY"

section "Puertos duplicados: se mueve la que NO está sirviendo"
# Moverlas todas cortaría un servicio que funciona para arreglar otro que no.
mkapp uno  node 3001 uno.test
mkapp dos  node 3001 dos.test     # el mismo puerto: dos apps peleando
mkapp tres node 3002 tres.test
: > "$ARRANCADOS"; echo "orbit-uno" >> "$ARRANCADOS"   # 'uno' es la que sirve
systemctl() {
  case "${1:-}" in
    is-active) local u="${*: -1}"; grep -qx "$u" "$ARRANCADOS" ;;
    *) return 0 ;;
  esac
}
MOVIDAS="$TMP/movidas"; : > "$MOVIDAS"
cmd_port() { printf '%s\n' "$1" >> "$MOVIDAS"; load_app "$1"; A_PORT=3999; save_app; return 0; }
run _fix_ports; check "arregla algo" "0" "$?"
check "mueve una sola"      "1"    "$(wc -l < "$MOVIDAS")"
check "y no es la que sirve" "dos" "$(cat "$MOVIDAS")"
check "'uno' conserva su puerto" "3001" "$(app_port uno)"

section "Si ninguna está viva, se mueve igual"
mkapp cuatro node 3005 cuatro.test
mkapp cinco  node 3005 cinco.test
: > "$ARRANCADOS"; : > "$MOVIDAS"
run _fix_ports; check "no se queda parado" "0" "$?"
check "mueve una" "1" "$(wc -l < "$MOVIDAS")"

section "Sin duplicados no hace nada"
: > "$MOVIDAS"
# Un puerto distinto por app, sin repetir ninguno.
i=4100; for a in uno dos tres cuatro cinco; do load_app "$a"; A_PORT=$i; save_app; i=$((i+1)); done
run _fix_ports; check "no mueve nada" "1" "$?"
check "ni una" "0" "$(wc -l < "$MOVIDAS")"

section "--fix necesita --yes cuando la salida es JSON"
# 'confirm' escribe la pregunta por stdout, y con --json ahí sólo va el JSON.
# Decidir por nuestra cuenta que quien automatiza ya ha dicho que sí sería
# aplicar cambios en un servidor sin que nadie los haya aceptado.
JSON="yes"; ASSUME_YES="no"
SALIDA="$(run cmd_doctor --fix 2>"$TMP/err")"; RC=$?
check "aborta"            "1" "$RC"
check "y lo explica"      "1" "$(grep -c 'necesita también --yes' "$TMP/err")"
check "stdout limpio"     "0" "$(printf '%s' "$SALIDA" | wc -c)"
JSON="no"; ASSUME_YES="no"

section "Una opción que no existe no se ignora"
run cmd_doctor --arregla-todo >/dev/null 2>&1; check "aborta" "1" "$?"

report
