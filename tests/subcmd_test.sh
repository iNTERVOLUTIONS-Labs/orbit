#!/usr/bin/env bash
# Despacho de subcomandos: una sola regla para todos los comandos.
#   bash tests/subcmd_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables que lee el
# 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root()    { :; }
systemctl()    { :; }
ufw()          { echo "estado del cortafuegos"; }
LOG_FILE="$TMP/orbit.log"
nginx_file()   { echo "$TMP/vhost-$1.conf"; }
render_nginx() { : ; }
cmd_deploy_all() { echo "deploy_all $*"; }

# Cuatro apps con nombres que chocan a propósito con subcomandos, más una
# normal. Si el despacho se equivoca, se equivoca aquí.
mkapp web    static "" web.test
mkapp status static "" status.test
mkapp set    static "" set.test
mkapp get    static "" get.test
mkapp on     static "" on.test

# Devuelve "<subcomando>|<argumentos restantes>" para inspeccionar el reparto.
# Sólo para entradas válidas: con una inválida _subcmd aborta el proceso.
sub() { _subcmd "$@" 2>/dev/null; printf '%s|%s' "$SUBCMD" "${SUBCMD_ARGS[*]}"; }

SPEC="add rm|del|remove list|ls"

section "El helper reparte los argumentos"
check "sin nada, el defecto"   "list|"          "$(sub redirect list app "$SPEC")"
check "nombre canónico"        "add|"           "$(sub redirect list app "$SPEC" add)"
check "alias → canónico"       "rm|"            "$(sub redirect list app "$SPEC" del)"
check "segundo alias"          "rm|"            "$(sub redirect list app "$SPEC" remove)"
check "arrastra el resto"      "add|web /a /b"  "$(sub redirect list app "$SPEC" add web /a /b)"
check "el defecto no consume"  "list|web"       "$(sub redirect list app "$SPEC" web)"
check "guiones también"        "quiet|"         "$(sub watch once noapp "quiet|--quiet|-q" -q)"

section "Lo que no entiende, lo dice"
run _subcmd redirect list app "$SPEC" noexiste >/dev/null 2>&1; r=$?
check "app inexistente aborta"  "1" "$r"
run _subcmd redirect list app "$SPEC" noexiste 2>"$TMP/e1" >/dev/null
check "y nombra el comando"     "1" "$(grep -c 'orbit redirect' "$TMP/e1")"
check "y lista los subcomandos" "1" "$(grep -c 'add rm list' "$TMP/e1")"
run _subcmd watch once noapp "enable disable" web >/dev/null 2>&1; r=$?
check "sin apps, ni las que hay" "1" "$r"
# La comparación es por igualdad, no por prefijo: 'on' no es 'once'.
run _subcmd watch once noapp "once|--once enable" on >/dev/null 2>&1; r=$?
check "'on' no encaja en 'once'" "1" "$r"

section "Pedir ayuda no es equivocarse"
run _subcmd watch once noapp "enable disable status" --help >"$TMP/ay" 2>&1; r=$?
check "sale con 0"              "0" "$r"
check "y enseña los subcomandos" "1" "$(grep -c 'orbit watch <enable|disable|status>' "$TMP/ay")"
run _subcmd maintenance status app "on off" ayuda >"$TMP/ay2" 2>&1
check "dice que admite app"     "1" "$(grep -c 'orbit maintenance <on|off> \[app\]' "$TMP/ay2")"
run cmd_watch --help >/dev/null 2>&1; r=$?
check "por el comando de verdad" "0" "$r"

section "Cuando una app se llama como un subcomando"
_subcmd maintenance status app "on|activar off|quitar status" status 2>"$TMP/h1" >"$TMP/h1o"
check "gana el subcomando"      "status" "$SUBCMD"
check "y avisa de la forma larga" "1" "$(grep -c 'orbit maintenance status status' "$TMP/h1")"
check "el aviso no va a stdout" "0" "$(wc -c <"$TMP/h1o")"
_subcmd maintenance status app "on|activar off|quitar status" web 2>"$TMP/h2" >/dev/null
check "sin choque, sin aviso"   "0" "$(wc -c <"$TMP/h2")"

section "orbit env"
run cmd_env set set CLAVE valor >/dev/null 2>"$TMP/es"
check "'env set set' es la app 'set'" "valor" "$(run cmd_env get set CLAVE 2>/dev/null)"
check "avisa del choque"        "1" "$(grep -c 'orbit env edit set' "$TMP/es")"
run cmd_env set get OTRA dato >/dev/null 2>&1
check "'env get get' lee la app 'get'" "dato" "$(run cmd_env get get OTRA 2>/dev/null)"
check "el aviso no contamina"   "dato" "$(run cmd_env get get OTRA 2>/dev/null)"
run cmd_env list web >/dev/null 2>&1; r=$?
check "list sigue funcionando"  "0" "$r"
run cmd_env borrar web >/dev/null 2>&1; r=$?
check "subcomando inventado"    "1" "$r"

section "orbit maintenance"
run cmd_maintenance web >"$TMP/m1" 2>&1
check "app suelta → su estado"  "1" "$(grep -c 'sirve con normalidad' "$TMP/m1")"
run cmd_maintenance on on >/dev/null 2>&1; r=$?
check "'on on' enciende la app 'on'" "0" "$r"
check "y crea su testigo"       "1" "$([[ -e "$(maint_flag on)" ]] && echo 1 || echo 0)"
check "sin tocar a web"         "0" "$([[ -e "$(maint_flag web)" ]] && echo 1 || echo 0)"
run cmd_maintenance status >"$TMP/m2" 2>&1
check "el listado la incluye"   "1" "$(grep -c ' on ' "$TMP/m2")"
run cmd_maintenance web >"$TMP/m3" 2>&1
check "filtrado por app"        "0" "$(grep -c 'on.test' "$TMP/m3")"
run cmd_maintenance status noexiste >/dev/null 2>&1; r=$?
check "app inexistente aborta"  "1" "$r"
run cmd_maintenance apagar web >/dev/null 2>&1; r=$?
check "subcomando inventado"    "1" "$r"
run cmd_maintenance quitar on >/dev/null 2>&1
check "el alias 'quitar' apaga" "0" "$([[ -e "$(maint_flag on)" ]] && echo 1 || echo 0)"

section "orbit autodeploy"
run cmd_autodeploy web >"$TMP/a1" 2>&1
check "app suelta → su estado"  "1" "$(grep -c 'no se despliega sola' "$TMP/a1")"
A_REPO="https://example.test/web.git"
run cmd_autodeploy on web >/dev/null 2>&1; r=$?
check "alias 'on' activa"       "0" "$r"
run cmd_autodeploy web >"$TMP/a2" 2>&1
check "y ahora lo cuenta"       "1" "$(grep -c 'desplegado' "$TMP/a2")"
run cmd_autodeploy off web >/dev/null 2>&1
run cmd_autodeploy web >"$TMP/a3" 2>&1
check "alias 'off' desactiva"   "1" "$(grep -c 'no se despliega sola' "$TMP/a3")"
check "'--once' sigue valiendo" "deploy_all --auto" "$(run cmd_autodeploy --once 2>/dev/null)"
check "y 'once' también"        "deploy_all --auto" "$(run cmd_autodeploy once 2>/dev/null)"
run cmd_autodeploy cada 9 >/dev/null 2>&1; r=$?
check "'cada 9' lee el minuto"  "0" "$r"
check "y lo guarda"             "1" "$(grep -c '^AUTODEPLOY_EVERY="9"' "$TMP/etc/orbit.conf")"
run cmd_autodeploy arrancar >/dev/null 2>&1; r=$?
check "subcomando inventado"    "1" "$r"

section "orbit redirect"
run cmd_redirect add web /vieja /nueva >/dev/null 2>&1
run cmd_redirect add status /otra /sitio >/dev/null 2>&1
run cmd_redirect web >"$TMP/r1" 2>&1
check "app suelta → su lista"   "1" "$(grep -c '/vieja' "$TMP/r1")"
check "y sólo la suya"          "0" "$(grep -c '/otra' "$TMP/r1")"
run cmd_redirect help >"$TMP/r2" 2>&1
check "la ayuda sigue ahí"      "1" "$(grep -c 'orbit redirect rm' "$TMP/r2")"
run cmd_redirect ls web >/dev/null 2>&1; r=$?
check "alias 'ls'"              "0" "$r"
run cmd_redirect quitar web /vieja >/dev/null 2>&1; r=$?
check "subcomando inventado"    "1" "$r"

section "orbit watch"
WATCH_LOG="$TMP/watch.log"
printf 'uno\ndos\ntres\ncuatro\n' > "$WATCH_LOG"
check "'--history 2' recorta"   "2" "$(run cmd_watch --history 2 2>/dev/null | grep -cE '^  (tres|cuatro)$')"
check "y 'history' es lo mismo" "2" "$(run cmd_watch history 2 2>/dev/null | grep -cE '^  (tres|cuatro)$')"
run cmd_watch web >/dev/null 2>&1; r=$?
check "no admite apps"          "1" "$r"
run cmd_watch mirar >/dev/null 2>&1; r=$?
check "subcomando inventado"    "1" "$r"

section "db, notify y firewall"
run cmd_db >"$TMP/d1" 2>&1
check "db sin nada → ayuda"     "1" "$(grep -c 'orbit db create' "$TMP/d1")"
run cmd_db help >"$TMP/d2" 2>&1
check "db help → ayuda"         "1" "$(grep -c 'orbit db create' "$TMP/d2")"
run cmd_db borrar >/dev/null 2>&1; r=$?
check "db inventado aborta"     "1" "$r"
run cmd_notify >"$TMP/n1" 2>&1
check "notify sin nada → estado" "1" "$(grep -c 'Sin avisos configurados' "$TMP/n1")"
run cmd_notify probar >/dev/null 2>&1; r=$?
check "notify inventado aborta" "1" "$r"
run cmd_firewall >"$TMP/f1" 2>&1
check "firewall sin nada → estado" "1" "$(grep -c 'estado del cortafuegos' "$TMP/f1")"
run cmd_firewall abrir >/dev/null 2>&1; r=$?
check "firewall inventado aborta" "1" "$r"

report
