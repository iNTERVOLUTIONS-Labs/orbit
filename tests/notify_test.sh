#!/usr/bin/env bash
# Los avisos: los canales, y sobre todo si dicen la verdad sobre sí mismos.
#   bash tests/notify_test.sh
#
# El correo no estaba por un motivo escrito en el ROADMAP: «un VPS limpio no
# puede enviarlo y falla en silencio». Las dos mitades hacen falta. La primera
# se resuelve con un relé —curl habla SMTP y ya es dependencia—; la segunda no
# es del correo sino de todo el subsistema, porque 'notify test' anunciaba
# «Enviado» pasara lo que pasara. Un canal de avisos que miente sobre sí mismo
# es peor que no tenerlo: uno deja de mirar el servidor confiando en que ya
# avisará.
#
# Por eso aquí hay un servidor SMTP de mentira **de verdad**: acepta la
# conversación entera y guarda el mensaje. Un doble que no puede fallar no
# comprueba nada, y con curl de por medio la única forma de saber que el correo
# sale es que algo lo reciba.
# shellcheck disable=SC2034  # asigna variables NOTIFY_* que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
NOTIFY_CONF="$TMP/notify.conf"

section "Qué canales cuentan como configurados"
NOTIFY_TELEGRAM_TOKEN=""; NOTIFY_TELEGRAM_CHAT=""; NOTIFY_DISCORD=""
NOTIFY_WEBHOOK=""; NOTIFY_MAIL_TO=""; NOTIFY_SMTP_URL=""
check "sin nada, ninguno"      "" "$(_notify_channels)"
NOTIFY_TELEGRAM_TOKEN="t"
# Un token sin chat no es un canal: enviaría a ninguna parte, y contarlo haría
# que 'notify_configured' dijera que sí y nadie recibiera nada.
check "token sin chat, tampoco" "" "$(_notify_channels)"
NOTIFY_TELEGRAM_CHAT="c"
check "con los dos, sí"        "telegram" "$(_notify_channels)"
NOTIFY_MAIL_TO="a@b.test"
check "correo sin servidor, no" "telegram" "$(_notify_channels)"
NOTIFY_SMTP_URL="smtp://127.0.0.1:2525"
check "con servidor, sí"       "telegram mail" "$(_notify_channels | tr '\n' ' ' | sed 's/ $//')"

section "Los argumentos con los que se llama a curl"
NOTIFY_MAIL_TO="uno@b.test, dos@b.test"
NOTIFY_MAIL_FROM="orbit@servidor.test"
NOTIFY_SMTP_USER=""; NOTIFY_SMTP_PASS=""
ARGS="$(_notify_mail_args | tr '\n' ' ')"
check "el servidor"        "1" "$(grep -c -- '--url smtp://127.0.0.1:2525' <<<"$ARGS")"
check "el remitente"       "1" "$(grep -c -- '--mail-from orbit@servidor.test' <<<"$ARGS")"
# Un aviso que sólo puede ir a una persona se pierde en cuanto esa persona está
# de vacaciones.
check "los dos destinos"   "2" "$(grep -o -- '--mail-rcpt' <<<"$ARGS" | wc -l)"
check "sin usuario, sin --user" "0" "$(grep -c -- '--user' <<<"$ARGS")"
check "y sin exigir TLS"        "0" "$(grep -c -- '--ssl-reqd' <<<"$ARGS")"
# Con contraseña sí se exige, y no se negocia: un AUTH sin cifrar entrega la
# contraseña del correo a cualquiera que mire la red.
NOTIFY_SMTP_USER="yo"; NOTIFY_SMTP_PASS="secreta"
ARGS="$(_notify_mail_args | tr '\n' ' ')"
check "con usuario, --user"     "1" "$(grep -c -- '--user yo:secreta' <<<"$ARGS")"
check "y TLS obligatorio"       "1" "$(grep -c -- '--ssl-reqd' <<<"$ARGS")"
# Salvo que la URL ya sea cifrada de origen, donde pedirlo otra vez sobra.
NOTIFY_SMTP_URL="smtps://correo.test:465"
ARGS="$(_notify_mail_args | tr '\n' ' ')"
check "con smtps no hace falta" "0" "$(grep -c -- '--ssl-reqd' <<<"$ARGS")"

# --- el servidor SMTP de mentira -------------------------------------------
if ! command -v python3 >/dev/null; then
  echo "  (falta python3: me salto el envío de correo de verdad)"
  report
fi

cat > "$TMP/smtpd.py" <<'PY'
import socket, sys, threading
puerto = int(sys.argv[1]); destino = sys.argv[2]
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", puerto)); srv.listen(4)
sys.stderr.write("listo\n"); sys.stderr.flush()

def atender(c):
    f = c.makefile("rwb")
    f.write(b"220 orbit-test ESMTP\r\n"); f.flush()
    datos, en_datos = [], False
    while True:
        linea = f.readline()
        if not linea:
            break
        if en_datos:
            if linea in (b".\r\n", b".\n"):
                en_datos = False
                f.write(b"250 Ok\r\n"); f.flush()
                open(destino, "ab").write(b"".join(datos) + b"\n--- FIN ---\n")
                datos = []
            else:
                datos.append(linea)
            continue
        orden = linea.decode("utf-8", "replace").strip().upper()
        if orden.startswith("EHLO") or orden.startswith("HELO"):
            f.write(b"250-orbit-test\r\n250 AUTH PLAIN LOGIN\r\n")
        elif orden.startswith("AUTH"):
            f.write(b"235 Ok\r\n")
        elif orden.startswith("MAIL FROM") or orden.startswith("RCPT TO"):
            open(destino, "ab").write(linea)
            f.write(b"250 Ok\r\n")
        elif orden.startswith("DATA"):
            en_datos = True
            f.write(b"354 End data with <CR><LF>.<CR><LF>\r\n")
        elif orden.startswith("QUIT"):
            f.write(b"221 Bye\r\n"); f.flush(); break
        else:
            f.write(b"250 Ok\r\n")
        f.flush()
    c.close()

while True:
    c, _ = srv.accept()
    threading.Thread(target=atender, args=(c,), daemon=True).start()
PY

BUZON="$TMP/buzon"; : > "$BUZON"
PUERTO=$(( 34000 + RANDOM % 2000 ))
python3 "$TMP/smtpd.py" "$PUERTO" "$BUZON" 2>"$TMP/smtpd.err" &
SMTPD=$!
trap 'kill "$SMTPD" 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -q listo "$TMP/smtpd.err" 2>/dev/null && break; sleep 0.1; done

section "Un correo que llega de verdad"
NOTIFY_TELEGRAM_TOKEN=""; NOTIFY_TELEGRAM_CHAT=""; NOTIFY_DISCORD=""; NOTIFY_WEBHOOK=""
NOTIFY_MAIL_TO="avisos@b.test"; NOTIFY_MAIL_FROM="orbit@servidor.test"
NOTIFY_SMTP_URL="smtp://127.0.0.1:$PUERTO"; NOTIFY_SMTP_USER=""; NOTIFY_SMTP_PASS=""
NOTIFY_MIN_LEVEL="warn"
_notify_save

run _notify_ch_mail crit "[crit] servidor · La web se ha caído" "La web se ha caído"; r=$?
check "curl sale con cero"   "0" "$r"
check "el destinatario"      "1" "$(grep -c 'RCPT TO:<avisos@b.test>' "$BUZON")"
check "y el remitente"       "1" "$(grep -c 'MAIL FROM:<orbit@servidor.test>' "$BUZON")"
check "con asunto"           "1" "$(grep -c '^Subject: \[orbit\] crit' "$BUZON")"
check "y el cuerpo"          "1" "$(grep -c 'La web se ha caído' "$BUZON")"
# Sin la cabecera, cualquier acento de un mensaje de Orbit sale como bytes
# sueltos en el cliente de correo. Y todos los mensajes llevan.
check "declarando el charset" "1" "$(grep -c 'charset=UTF-8' "$BUZON")"

section "El nivel mínimo también vale para el correo"
: > "$BUZON"
NOTIFY_MIN_LEVEL="crit"; _notify_save
run notify warn "esto no debería salir"
check "un warn con mínimo crit no sale" "0" "$(grep -c FIN "$BUZON")"
run notify crit "esto sí"
check "y un crit sí"                    "1" "$(grep -c FIN "$BUZON")"
NOTIFY_MIN_LEVEL="warn"; _notify_save

section "notify test dice la verdad de cada canal"
: > "$BUZON"
run cmd_notify test >"$TMP/ok" 2>&1; r=$?
check "sale bien"          "0" "$r"
check "y nombra el canal"  "1" "$(grep -c 'mail' "$TMP/ok")"
check "el correo llegó"    "1" "$(grep -c FIN "$BUZON")"

# Y lo que importa: con el servidor apagado tiene que decirlo. Antes se llamaba
# a 'notify', que se traga los fallos por diseño, y salía «Enviado» igual: un
# token caducado, un webhook borrado y una contraseña mal escrita daban todos
# la misma línea verde.
kill "$SMTPD" 2>/dev/null; wait "$SMTPD" 2>/dev/null
run cmd_notify test >"$TMP/mal" 2>&1; r=$?
check "con el servidor caído, falla" "1" "$r"
check "y dice qué canal"             "1" "$(grep -c 'mail: no ha salido' "$TMP/mal")"
check "con el motivo de curl"        "1" "$(grep -ci 'connect\|conexión\|refused\|rehus' "$TMP/mal")"
check "y no dice que se ha enviado"  "0" "$(grep -c 'mail: enviado' "$TMP/mal")"

section "Un canal roto no puede tumbar al que lo llama"
# 'notify' lo llama el vigilante a mitad de un arreglo: si un aviso que no sale
# abortara, un correo mal configurado se llevaría por delante el reinicio de la
# app que estaba caída.
run notify crit "con el servidor apagado"; r=$?
check "notify sigue devolviendo cero" "0" "$r"

section "El fichero de configuración no lo puede leer nadie más"
# Lleva la contraseña del correo del usuario.
NOTIFY_SMTP_USER="yo"; NOTIFY_SMTP_PASS="secreta"; _notify_save
check "solo root"          "600" "$(stat -c %a "$NOTIFY_CONF")"
check "y guarda el relé"   "1" "$(grep -c '^NOTIFY_SMTP_URL=' "$NOTIFY_CONF")"
check "y la contraseña"    "1" "$(grep -c '^NOTIFY_SMTP_PASS=' "$NOTIFY_CONF")"

report
