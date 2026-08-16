#!/usr/bin/env bash
# Pruebas de 'orbit exec': entorno, precedencia, código de salida y errores.
#   bash tests/exec_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, PORT_BASE,
# KEEP_RELEASES…) que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"

# No hay usuario 'deploy' en el contenedor: se ejecuta todo como el actual.
sudo() { # descarta -u/-H/-- y ejecuta el resto tal cual
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -u) shift 2 ;;
      --) shift; break ;;
      *)  shift ;;
    esac
  done
  "$@"
}

# --- una app desplegada de mentira -----------------------------------------
REL="$TMP/apps/web/releases/r1"
mkdir -p "$REL/node_modules/.bin" "$REL/.venv/bin" "$TMP/apps/web/shared"
ln -sfn "$REL" "$TMP/apps/web/current"
cat > "$TMP/apps/web/shared/.env" <<'EOF'
DEL_ENV=hola
NODE_ENV=development
DATABASE_URL="postgresql://u:p@127.0.0.1:5432/db"
EOF
printf '#!/bin/sh\necho binario-local\n' > "$REL/node_modules/.bin/miherramienta"
chmod +x "$REL/node_modules/.bin/miherramienta"

mkapp web node 3001 web.test

# Una app registrada pero nunca desplegada.
mkapp nueva node 3002 nueva.test

x() { run cmd_exec "$@"; }   # con las mismas opciones que en producción

section "Entorno de ejecución"
check "directorio de trabajo" "$(readlink -f "$REL")" "$(x web pwd)"
check "carga el .env" "hola" "$(x web sh -c 'echo $DEL_ENV')"
check "valores con comillas" "postgresql://u:p@127.0.0.1:5432/db" \
  "$(x web sh -c 'echo $DATABASE_URL')"
check "PORT de la app" "3001" "$(x web sh -c 'echo $PORT')"
check "HOST local" "127.0.0.1" "$(x web sh -c 'echo $HOST')"

# systemd pone EnvironmentFile antes que Environment=, así que el NODE_ENV de
# la unidad gana al del .env. exec tiene que comportarse igual o miente.
check "NODE_ENV gana al .env" "production" "$(x web sh -c 'echo $NODE_ENV')"

check "node_modules/.bin en PATH" "binario-local" "$(x web miherramienta)"
check ".venv/bin en PATH" "1" \
  "$(x web sh -c 'case $PATH in *"/.venv/bin"*) echo 1;; *) echo 0;; esac')"

section "Formas de invocación"
check "argv directo" "uno dos" "$(x web echo uno dos)"
check "respeta las comillas" "un argumento" "$(x web echo 'un argumento')"
check "cadena con && va al shell" "a-b" "$(x web 'echo -n a-; echo b')"
check "cadena con tubería" "2" "$(x web 'printf "x\ny\n" | wc -l | tr -d " "')"

section "Código de salida"
x web true >/dev/null 2>&1 && r=0 || r=$?
check "propaga el 0" "0" "$r"
x web sh -c 'exit 7' >/dev/null 2>&1 && r=0 || r=$?
check "propaga el 7" "7" "$r"
x web sh -c 'exit 1' >/dev/null 2>&1 && r=0 || r=$?
check "propaga el 1" "1" "$r"

section "Salida limpia"
# Nada de decoración de Orbit: la salida debe poder encadenarse en un script.
check "stdout sin adornos" "solo-esto" "$(x web echo solo-esto)"
check "una sola línea" "1" "$(x web echo solo-esto | wc -l)"

section "Errores con salida"
x nueva pwd >"$TMP/e1" 2>&1 && r=0 || r=$?
check "app sin desplegar aborta" "1" "$r"
check "y dice qué hacer" "1" "$(grep -c 'orbit deploy nueva' "$TMP/e1")"
x noexiste pwd >"$TMP/e2" 2>&1 && r=0 || r=$?
check "app inexistente aborta" "1" "$r"
check "y remite a orbit list" "1" "$(grep -c 'orbit list' "$TMP/e2")"

section "Aviso de devDependencies"
x web 'pnpm install --frozen-lockfile' >"$TMP/e3" 2>"$TMP/e3err"
check "avisa de NODE_ENV" "1" "$(grep -c 'devDependencies' "$TMP/e3err")"
# …y por stderr, para no colarse en una tubería del usuario.
check "el aviso no va a stdout" "0" "$(grep -c 'devDependencies' "$TMP/e3")"
x web echo hola >"$TMP/e4" 2>&1
check "no avisa sin motivo" "0" "$(grep -c 'devDependencies' "$TMP/e4")"

section "Registro"
check "anota la app" "exec web" "$(grep -o 'exec web$' "$TMP/orbit.log" | tail -1)"
# El comando puede llevar una contraseña delante: no debe acabar en el log.
x web 'echo PGPASSWORD=secreto-que-no-debe-salir' >/dev/null 2>&1
check "no anota el comando" "0" "$(grep -c 'secreto-que-no-debe-salir' "$TMP/orbit.log")"

report
