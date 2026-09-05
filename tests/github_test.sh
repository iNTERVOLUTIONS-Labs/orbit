#!/usr/bin/env bash
# Las tres preguntas de GitHub, ya con contrato.
#   bash tests/github_test.sh
#
# Lo que se prueba aquí no es que `gh` funcione —eso es de gh— sino que lo que
# este servidor sabe de GitHub se pueda **leer desde fuera** sin un terminal.
# Hasta ahora esa información existía sólo dentro del selector de `orbit new`, y
# un cliente no puede usar un selector: `choose` necesita fzf o una lista
# numerada que alguien lee, y con `--yes` ni se llega a él.
#
# shellcheck disable=SC2034  # estas pruebas asignan variables (JSON, DEPLOY_USER…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
DEPLOY_USER="deploy"

SIN_JQ="no"; command -v jq >/dev/null || SIN_JQ="yes"
j() { jq -r "$1"; }

# `as_deploy` es la única puerta al `gh` del servidor, así que doblarla es
# doblar GitHub entero. Cada sección pone la suya.
SIN_SESION='return 1'

# ── quién está conectado ────────────────────────────────────────────────────

section "La cuenta se lee de las dos frases que ha usado gh"
# gh cambió el texto en la 2.40. Las dos formas existen en máquinas reales, y
# equivocarse aquí deja la sesión sin nombre en el servidor de otro.
as_deploy() { printf '%s\n' \
  "github.com" \
  "  ✓ Logged in to github.com account davabe (/home/deploy/.config/gh/hosts.yml)" \
  "  - Token: gho_************"; }
check "frase nueva"  "davabe" "$(_gh_account)"
as_deploy() { printf '%s\n' \
  "  ✓ Logged in to github.com as davabe (/home/deploy/.config/gh/hosts.yml)"; }
check "frase vieja"  "davabe" "$(_gh_account)"
# Una tercera forma no se adivina: mejor sin nombre que con uno inventado. Un
# hueco se ve; un nombre que no es el de nadie, no.
as_deploy() { printf '%s\n' "You are not logged into any GitHub hosts"; }
check "frase desconocida" "" "$(_gh_account)"

section "El token no sale de aquí por ninguna vía"
# La salida de 'gh auth status' lleva el token enmascarado y las rutas de los
# ficheros de configuración. Lo único que se devuelve es la cuenta: si algún día
# alguien amplía esto para «dar más contexto», esta prueba se pone roja.
as_deploy() { printf '%s\n' \
  "  ✓ Logged in to github.com account davabe (/home/deploy/.config/gh/hosts.yml)" \
  "  - Token: gho_abcdefghijklmnop" \
  "  - Token scopes: 'gist', 'read:org', 'repo'"; }
CUENTA="$(_gh_account)"
check "sólo la cuenta"      "davabe" "$CUENTA"
check "sin el token"        "0"      "$(grep -c 'gho_' <<<"$CUENTA")"
check "sin la ruta del conf" "0"     "$(grep -c 'hosts.yml' <<<"$CUENTA")"

# ── el estado, como objeto ──────────────────────────────────────────────────

if [[ "$SIN_JQ" == "yes" ]]; then
  echo "  (falta jq: me salto el contrato de 'github status')"
else
section "orbit github status --json"
JSON="yes"
as_deploy() { printf '%s\n' "  ✓ Logged in to github.com account davabe"; }
OUT="$(_github_status)"
check "es un objeto"    "object"  "$(j 'type' <<<"$OUT")"
check "publica schema"  "1"       "$(j '.schema' <<<"$OUT")"
check "conectado"       "true"    "$(j '.connected' <<<"$OUT")"
check "la cuenta"       "davabe"  "$(j '.account' <<<"$OUT")"
# Quién pregunta importa: el gh que cuenta es el del usuario de despliegue, no
# el de quien ejecuta orbit. Un cliente que enseñe la lista de otra cuenta
# enseña repositorios que este servidor puede no alcanzar.
check "y con qué usuario" "deploy" "$(j '.deploy_user' <<<"$OUT")"

# Sin sesión, `account` es null y NO una cadena vacía: son dos cosas distintas
# y sólo una de ellas es «no hay nadie».
as_deploy() { eval "$SIN_SESION"; }
OUT="$(_github_status)"
check "sin sesión: false" "false" "$(j '.connected' <<<"$OUT")"
check "sin sesión: null"  "null"  "$(j '.account' <<<"$OUT")"
JSON="no"
fi

# ── la lista de repositorios ────────────────────────────────────────────────

# Lo que devolvería gh, con los casos que de verdad aparecen: uno privado, uno
# público sin descripción, y uno recién creado **sin rama y sin descripción**.
#
# Los campos van separados por US (0x1f) y no por tabuladores, y ése es justo el
# caso que hay que probar: con tabuladores, bash colapsa dos seguidos —es espacio
# en blanco— y un repositorio sin descripción llegaba con la fecha metida en el
# campo de la descripción.
REPOS=$'davabe/tienda\x1ftrue\x1fmain\x1fLa tienda\x1f2026-09-04T22:25:55Z
davabe/blog\x1ffalse\x1fmain\x1f\x1f2026-08-30T09:05:00Z
davabe/vacio\x1ftrue\x1f\x1f\x1f2026-05-02T10:10:00Z'

section "La lista es la del servidor, y la comparte con el selector de 'new'"
as_deploy() { case "$*" in *"auth status"*) return 0 ;; *) printf '%s\n' "$REPOS" ;; esac; }
# `_gh_repos` es lo que consume el selector de `orbit new`: sólo la primera
# columna. Que salga de la misma función que el contrato es lo que impide que
# el selector y el cliente acaben contando cosas distintas.
check "sólo los nombres" "davabe/tienda davabe/blog davabe/vacio" "$(_gh_repos | tr '\n' ' ' | sed 's/ $//')"
check "y son tres"       "3" "$(_gh_repos | wc -l)"

if [[ "$SIN_JQ" == "yes" ]]; then
  echo "  (falta jq: me salto el contrato de 'github repos')"
else
section "orbit github repos --json"
JSON="yes"
OUT="$(_github_repos)"
check "es un objeto"      "object"          "$(j 'type' <<<"$OUT")"
check "los tres"          "3"               "$(j '.repos | length' <<<"$OUT")"
check "el nombre entero"  "davabe/tienda"   "$(j '.repos[0].name_with_owner' <<<"$OUT")"
check "privado es bool"   "true"            "$(j '.repos[0].private' <<<"$OUT")"
check "público también"   "false"           "$(j '.repos[1].private' <<<"$OUT")"
check "la rama"           "main"            "$(j '.repos[0].default_branch' <<<"$OUT")"

# **Un repositorio vacío no tiene rama, y no se le inventa una.** Poner «main»
# ahí haría que un cliente clonara con --branch main y fallara por culpa
# nuestra, con un mensaje de git que no habla de eso.
check "sin rama: null"    "null"            "$(j '.repos[2].default_branch' <<<"$OUT")"
# Y una descripción vacía es «no hay», no una cadena en blanco que luego pinte
# una línea de nada.
check "sin descripción"   "null"            "$(j '.repos[1].description' <<<"$OUT")"
check "con descripción"   "La tienda"       "$(j '.repos[0].description' <<<"$OUT")"
check "la fecha, tal cual" "2026-09-04T22:25:55Z" "$(j '.repos[0].updated_at' <<<"$OUT")"

section "«Puede haber más» no es «hay más»"
# Con menos de los que caben, están todos y se afirma. Con justo los que caben,
# desde aquí no se puede saber sin pedir otra página — así que se dice eso.
check "no truncado"  "false" "$(j '.truncated' <<<"$OUT")"
OUT="$(_github_repos 3)"
check "truncado"     "true"  "$(j '.truncated' <<<"$OUT")"
check "y con el tope" "3"    "$(j '.limit' <<<"$OUT")"

section "Sin sesión, la lista es vacía y lo dice"
# Vacía y `connected:false`, que no es lo mismo que una cuenta sin repositorios.
# Un cliente que no distinga las dos enseña «no tienes repos» a quien sólo tiene
# el servidor sin conectar.
as_deploy() { eval "$SIN_SESION"; }
OUT="$(_github_repos)"
check "no conectado" "false" "$(j '.connected' <<<"$OUT")"
check "sin repos"    "0"     "$(j '.repos | length' <<<"$OUT")"
check "y sigue siendo un objeto" "object" "$(j 'type' <<<"$OUT")"

section "Lo que viene de GitHub se escapa"
# Una descripción con comillas rompe el JSON de cualquier cliente si sale sin
# escapar, y las descripciones las escribe cualquiera.
as_deploy() { case "$*" in *"auth status"*) return 0 ;;
  *) printf '%s\n' $'x/y\x1ffalse\x1fmain\x1fdice "hola" y \\ barra\x1f2026-01-01T00:00:00Z' ;; esac; }
OUT="$(_github_repos)"
check "sigue siendo JSON"  "object" "$(j 'type' <<<"$OUT")"
check "y dice lo mismo"    'dice "hola" y \ barra' "$(j '.repos[0].description' <<<"$OUT")"
JSON="no"
fi

# ── las ramas ───────────────────────────────────────────────────────────────

if [[ "$SIN_JQ" == "yes" ]]; then
  echo "  (falta jq: me salto el contrato de 'github branches')"
else
section "orbit github branches --json"
JSON="yes"
as_deploy() { printf '%s\n' \
  "aaa	refs/heads/feature/zzz" \
  "bbb	refs/heads/main" \
  "ccc	refs/heads/develop"; }
OUT="$(_github_branches https://github.com/x/y.git)"
check "es un objeto"   "object" "$(j 'type' <<<"$OUT")"
check "las tres"       "3"      "$(j '.branches | length' <<<"$OUT")"
# El orden es el de `_remote_branches`: main primero, porque es la que casi
# siempre se quiere y alfabéticamente iría después de 'develop'.
check "main primero"   "main"   "$(j '.branches[0]' <<<"$OUT")"
check "lleva el repo"  "https://github.com/x/y.git" "$(j '.repo' <<<"$OUT")"

# Un repositorio vacío no tiene ramas, y una lista vacía es la respuesta
# correcta. Rellenarla sería afirmar que existe una rama que no está.
as_deploy() { return 1; }
OUT="$(_github_branches https://github.com/x/vacio.git)"
check "vacío: lista vacía" "0"      "$(j '.branches | length' <<<"$OUT")"
check "y sigue siendo un objeto" "object" "$(j 'type' <<<"$OUT")"
JSON="no"
fi

section "Sin URL no se adivina un repositorio"
as_deploy() { return 1; }
( _github_branches >/dev/null 2>&1 ); check "branches sin url falla" "1" "$?"

# ── el router ───────────────────────────────────────────────────────────────

section "Conectar sigue siendo lo que era"
# La compatibilidad importa: 'orbit github' a secas tiene que seguir abriendo el
# flujo de siempre, porque está escrito en la ayuda de 'new', en el doctor y en
# la documentación del cliente.
_subcmd github connect noapp "connect|conectar status repos branches|ramas help|-h|--help|ayuda"
check "sin argumentos, conectar" "connect" "$SUBCMD"
_subcmd github connect noapp "connect|conectar status repos branches|ramas help|-h|--help|ayuda" status
check "status"   "status"   "$SUBCMD"
_subcmd github connect noapp "connect|conectar status repos branches|ramas help|-h|--help|ayuda" repos
check "repos"    "repos"    "$SUBCMD"
_subcmd github connect noapp "connect|conectar status repos branches|ramas help|-h|--help|ayuda" ramas https://x
check "ramas es branches" "branches" "$SUBCMD"
check "y le llega la url" "https://x" "${SUBCMD_ARGS[0]}"

section "Conectar no tiene objeto que devolver, y lo dice"
# Abre un navegador y hace preguntas. Fingir un objeto dejaría a un cliente
# esperando algo que no va a llegar nunca.
JSON="yes"
( cmd_github >/dev/null 2>&1 ); check "github --json falla" "1" "$?"
JSON="no"

section "El contrato se anuncia donde se busca"
run _json_capable github; check "github habla JSON"  "0" "$?"
run _json_capable gh;     check "gh también"          "0" "$?"
# Y aparece en el mensaje que ve quien se equivoca de comando: es lo único que
# lee, y durante un tiempo nombraba cuatro de los nueve.
check "el mensaje lo nombra" "1" "$(grep -c "github repos" <<<"$(_json_cmds_help)")"

report
