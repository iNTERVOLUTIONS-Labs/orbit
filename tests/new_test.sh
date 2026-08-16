#!/usr/bin/env bash
# Crear una app sin que haya nadie delante: argumentos, validación y --yes.
#   bash tests/new_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, ASSUME_YES…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

section "Con --yes no se pregunta ni se lee de la entrada"
# Lo que se comprueba no es sólo que valga el valor por defecto: es que la
# entrada quede intacta. Si 'ask' leyera igualmente, se comería la línea
# siguiente de un script y el fallo aparecería tres comandos más allá.
ASSUME_YES="yes"
# shellcheck disable=SC2154  # 'v' la asigna ask con printf -v, es decir por
# nombre, y shellcheck no puede verlo
check "vale el defecto y no consume" "por-defecto|SIGUIENTE" \
  "$( { ask v "Pregunta" "por-defecto" >/dev/null; read -r resto; printf '%s|%s' "$v" "$resto"; } <<<"SIGUIENTE" )"
run confirm "¿Sí?" y  </dev/null >/dev/null 2>&1; r=$?
check "confirm con defecto sí" "0" "$r"
run confirm "¿No?" n  </dev/null >/dev/null 2>&1; r=$?
check "confirm con defecto no" "1" "$r"
# Varias llamadas pasan el valor de un campo, donde el no se escribe 'no'.
run confirm "¿SPA?" no </dev/null >/dev/null 2>&1; r=$?
check "y con 'no' entero"      "1" "$r"
ASSUME_YES="no"
check "sin --yes sí lee"       "escrito" \
  "$( { ask v "Pregunta" "por-defecto" >/dev/null; printf '%s' "$v"; } <<<"escrito" )"

# --- dobles de lo que 'new' llama ------------------------------------------
need_root() { :; }
LOG_FILE="$TMP/orbit.log"
PASOS="$TMP/pasos"; : > "$PASOS"
install()     { :; }                                   # las carpetas no hacen falta
spin()        { :; }                                   # ni clonar de verdad
db_create()   { printf 'db %s\n'     "$1" >> "$PASOS"; }
cmd_deploy()  { printf 'deploy %s\n' "$1" >> "$PASOS"; }
cmd_ssl()     { printf 'ssl %s\n'    "$1" >> "$PASOS"; }
cmd_env()     { printf 'env %s\n'    "$1" >> "$PASOS"; }
free_port()   { echo 3001; }
# El doble respeta el segundo argumento porque el de verdad lo usa para algo
# que se comprueba aquí: '--appdir' no es un campo que se pise al final, dirige
# la detección entera hacia esa carpeta.
detect_stack() { A_TYPE="next"; A_PKG="pnpm"; A_BUILD="pnpm build"; A_START="pnpm start"
                 A_OUTDIR=""; A_SPA="no"; A_DOCROOT=""; A_APPDIR="${2:-.}"; A_PHP=""
                 A_PYAPP=""; A_PYMGR=""; A_PYFW=""; A_MIGRATE=""; }
_read_descriptor() { return 1; }
sudo() { return 1; }                                   # gh no está conectado

nueva() { # nueva <argumentos…> -> deja la salida en $SALIDA y el código en $r
  : > "$PASOS"
  SALIDA="$(run cmd_new "$@" </dev/null 2>&1)"; r=$?
}
campo() { # campo <app> <clave>
  ( load_app "$1"; printf '%s' "${!2}" )
}

section "Lo mínimo para crear una app sin nadie delante"
nueva --repo https://example.test/web.git --domain web.test --yes
check "termina bien"    "0"           "$r"
check "existe"          "0"           "$(app_exists web && echo 0 || echo 1)"
# El nombre sale del repositorio cuando no se da: es el mismo valor por defecto
# que propone el asistente, no una regla nueva escondida en otro sitio.
check "nombre del repo" "web"         "$(campo web A_NAME)"
check "repositorio"     "https://example.test/web.git" "$(campo web A_REPO)"
check "dominio"         "web.test"    "$(campo web A_DOMAIN)"
check "rama por defecto" "main"       "$(campo web A_BRANCH)"
check "tipo detectado"  "next"        "$(campo web A_TYPE)"
check "puerto asignado" "3001"        "$(campo web A_PORT)"
# Sin decir nada se propone el www, igual que en el asistente.
check "alias www"       "www.web.test" "$(campo web A_ALIASES)"
check "despliega"       "1"           "$(grep -c '^deploy web$' "$PASOS")"
# Sin base de datos y sin abrir el editor: los dos preguntan con «no» por
# defecto, y --yes acepta el valor por defecto, no dice que sí a todo.
check "sin base de datos" "0"         "$(grep -c '^db ' "$PASOS")"
check "sin editor"      "0"           "$(grep -c '^env ' "$PASOS")"
# Y sin certificado, porque no hay email de Let's Encrypt configurado. Morir
# aquí dejaría la app creada y desplegada pero el comando en error.
check "sin certificado" "0"           "$(grep -c '^ssl ' "$PASOS")"
check "y lo avisa"      "1"           "$(grep -c 'email de' <<<"$SALIDA")"

section "Nombre, rama y alias explícitos"
nueva --repo https://example.test/otro.git --name tienda --domain tienda.test \
      --branch produccion --aliases "a.test b.test" --yes
check "nombre"          "tienda"      "$(campo tienda A_NAME)"
check "rama"            "produccion"  "$(campo tienda A_BRANCH)"
check "alias"           "a.test b.test" "$(campo tienda A_ALIASES)"

section "Las banderas mandan sobre la detección"
nueva --repo https://example.test/est.git --name est --domain est.test \
      --type static --outdir build --spa yes --build "" --yes
check "tipo"            "static"      "$(campo est A_TYPE)"
check "carpeta web"     "build"       "$(campo est A_OUTDIR)"
check "spa"             "yes"         "$(campo est A_SPA)"
# --build '' es una respuesta: significa «sin build», y no es lo mismo que no
# haber dicho nada, que es cuando vale lo detectado.
check "sin build"       ""            "$(campo est A_BUILD)"
# Una estática no tiene servicio y por tanto no gasta un puerto.
check "sin puerto"      ""            "$(campo est A_PORT)"
check "y se enseña lo que se guarda" "1" "$(grep -c 'Tipo *static' <<<"$SALIDA")"

# '--appdir' dice DÓNDE está la app, así que la detección se hace ahí dentro y
# la carpeta tiene que existir en el repositorio. Con una errata, lo que había
# antes era un build que moría con «cd: no such file or directory» sin decir de
# dónde salía esa ruta.
mkdir -p "$TMP/apps/tienda-php/cache/apps/web"
nueva --repo https://example.test/php.git --name tienda-php --domain php.test \
      --type php --docroot public --appdir apps/web --yes
check "docroot"         "public"      "$(campo tienda-php A_DOCROOT)"
check "subcarpeta"      "apps/web"    "$(campo tienda-php A_APPDIR)"

mkdir -p "$TMP/apps/tienda-mala/cache"
nueva --repo https://example.test/php.git --name tienda-mala --domain mala.test \
      --type php --appdir noexiste --yes
check "una subcarpeta que no está, falla" "1" "$r"
check "y dice cuál"     "1"           "$(grep -c "carpeta 'noexiste'" <<<"$SALIDA")"
check "sin dejar la app" "1"          "$(app_exists tienda-mala && echo 0 || echo 1)"
# Y una ruta que se sale del repositorio tampoco: acaba en el vhost y en las
# rutas del despliegue, igual que las del orbit.json.
nueva --repo https://example.test/php.git --name tienda-fuera --domain fuera.test \
      --type php --appdir ../../etc --yes
check "ni una que se sale" "1"        "$r"
check "y lo explica"    "1"           "$(grep -c 'no es una ruta dentro del repositorio' <<<"$SALIDA")"

section "PHP dentro de una estática"
# Se detecta solo, pero tiene que poder forzarse en los dos sentidos: hay quien
# tiene un .php de sobra en el repo y no quiere que se ejecute nada.
nueva --repo https://example.test/mix.git --name mix --domain mix.test \
      --type static --outdir dist --php yes --yes
check "se activa"       "yes"         "$(campo mix A_PHP)"
check "y se enseña"     "1"           "$(grep -c 'PHP.*sí' <<<"$SALIDA")"
nueva --repo https://example.test/mix2.git --name mix2 --domain mix2.test \
      --type static --outdir dist --php no --yes
check "y se puede apagar" ""          "$(campo mix2 A_PHP)"
nueva --repo https://example.test/x.git --domain x.test --php quizas --yes
check "sólo yes o no"   "1"           "$r"

section "El www no se le pone a un subdominio"
# Es lo que pasaba al desplegar 'blog.midominio.com': se proponía
# 'www.blog.midominio.com', que no existe en el DNS, y el certificado del lote
# entero se podía ir al traste por un nombre que nadie iba a escribir.
nueva --repo https://example.test/sub.git --name sub --domain blog.ejemplo.com --yes
check "subdominio sin www" ""         "$(campo sub A_ALIASES)"
nueva --repo https://example.test/apex.git --name apex --domain ejemplo.com --yes
check "y el dominio sí"  "www.ejemplo.com" "$(campo apex A_ALIASES)"

section "--aliases vacío es una respuesta"
nueva --repo https://example.test/solo.git --name solo --domain solo.test --aliases "" --yes
check "ningún alias"    ""            "$(campo solo A_ALIASES)"

section "Base de datos y certificado"
nueva --repo https://example.test/db.git --name conbd --domain bd.test --db --no-ssl --yes
check "crea la base"    "1"           "$(grep -c '^db conbd$' "$PASOS")"
check "y no el certificado" "0"       "$(grep -c '^ssl ' "$PASOS")"

nueva --repo https://example.test/ssl.git --name conssl --domain ssl.test \
      --email yo@example.test --yes
check "guarda el email" "1"           "$(grep -c 'LETSENCRYPT_EMAIL="yo@example.test"' "$CONF_FILE")"
check "emite certificado" "1"         "$(grep -c '^ssl conssl$' "$PASOS")"

section "Sin terminal tampoco se emite el certificado, y el comando no falla"
# El caso de arriba pasa por '--yes'. Éste no lo lleva —un script que llama a
# 'orbit new --repo … --name … --domain …' y ya está—, y ahí la guarda no
# entraba: sólo miraba ASSUME_YES, aunque su propio comentario decía «sin
# terminal no hay a quién pedírselo».
#
# Lo que ocurría: el 'confirm' del certificado se quedaba con su valor por
# defecto, que es «sí», porque 'read' falla con EOF al instante; y 'cmd_ssl'
# moría pidiendo un correo que nadie podía teclear. La app quedaba **creada,
# desplegada y sirviendo**, y el comando salía con 1. Anunciar un fallo que no
# ha ocurrido es el mismo pecado que anunciar un éxito que no ha ocurrido,
# sólo que se nota menos. Salió desplegando en un servidor de verdad.
#
# La prueba puede verlo porque 'nueva' llama con '</dev/null', o sea sin
# terminal: es la condición exacta, no una imitación.
nueva --repo https://example.test/sinterm.git --domain sinterm.test
check "termina bien"      "0" "$r"
check "y la app existe"   "0" "$(app_exists sinterm && echo 0 || echo 1)"
check "la ha desplegado"  "1" "$(grep -c '^deploy sinterm$' "$PASOS")"
check "sin certificado"   "0" "$(grep -c '^ssl ' "$PASOS")"
check "y dice por qué"    "1" "$(grep -c 'email de' <<<"$SALIDA")"

# Con email configurado sí se emite: lo que faltaba era el dato, no el permiso.
CONF_EMAIL_ANTES="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_EMAIL="yo@example.test"
nueva --repo https://example.test/conmail.git --domain conmail.test
check "con email sí emite" "1" "$(grep -c '^ssl conmail$' "$PASOS")"
LETSENCRYPT_EMAIL="$CONF_EMAIL_ANTES"

section "Lo que se rechaza antes de clonar"
# Todas estas tienen que fallar sin haber tocado el disco: descubrir que el
# tipo no existe después de bajarse el repositorio es tarde y deja basura.
nueva --repo https://example.test/x.git --domain x.test --type basura --yes
check "tipo inventado"  "1"           "$r"
check "y dice cuáles hay" "1"         "$(grep -c 'static, next, node' <<<"$SALIDA")"
nueva --repo https://example.test/x.git --domain x.test --spa quizas --yes
check "spa que no es sí ni no" "1"    "$r"
nueva --repo https://example.test/x.git --domain x.test --nosequé --yes
check "opción desconocida" "1"        "$r"
nueva --repo https://example.test/x.git --domain
check "valor que falta"  "1"          "$r"
check "y lo explica"     "1"          "$(grep -c 'necesita un valor' <<<"$SALIDA")"
nueva --repo https://example.test/x.git --name "MAYUS" --domain x.test --yes
check "nombre inválido"  "1"          "$r"
nueva --repo https://example.test/x.git --name "../fuera" --domain x.test --yes
check "nombre con ruta"  "1"          "$r"
nueva --repo https://example.test/x.git --name web --domain otro.test --yes
check "nombre repetido"  "1"          "$r"
check "no crea nada"     "0"          "$(app_exists x && echo 1 || echo 0)"

# Forzar un tipo con proceso sobre un repo detectado como estático dejaría
# A_START vacío, y con él una unidad de systemd con ExecStart vacío que systemd
# rechaza. Se ve antes de escribir la configuración, no al arrancar.
detect_stack() { A_TYPE="static"; A_PKG="pnpm"; A_BUILD="pnpm build"; A_START=""
                 A_OUTDIR="dist"; A_SPA="no"; A_DOCROOT=""; A_APPDIR="."; A_PHP=""
                 A_PYAPP=""; A_PYMGR=""; A_PYFW=""; A_MIGRATE=""; }
nueva --repo https://example.test/x.git --name sinstart --domain x.test --type node --yes
check "proceso sin arranque" "1"      "$r"
check "y dice qué falta" "1"          "$(grep -c -- '--start' <<<"$SALIDA")"
check "sin registrar"    "0"          "$(app_exists sinstart && echo 1 || echo 0)"
# Con --start sí, que es la forma de desplegar un repo que Orbit no reconoce.
nueva --repo https://example.test/x.git --name constart --domain x.test \
      --type node --start "node server.js" --yes
check "con arranque, bien" "0"        "$r"
check "y lo guarda"      "node server.js" "$(campo constart A_START)"

section "Lo que falta se dice, no se adivina"
nueva --domain sinrepo.test --yes
check "sin repositorio"  "1"          "$r"
check "y dice cómo"      "1"          "$(grep -c 'con --repo' <<<"$SALIDA")"
nueva --repo https://example.test/x.git --name sindominio --yes
check "sin dominio"      "1"          "$r"
check "y dice cómo"      "1"          "$(grep -c 'con --domain' <<<"$SALIDA")"

section "Pedir ayuda no es equivocarse"
nueva --help
check "sale bien"        "0"          "$r"
check "y explica"        "1"          "$(grep -c -- '--repo <url>' <<<"$SALIDA")"
check "sin crear nada"   "0"          "$(wc -l < "$PASOS")"

section "Las apps nuevas con proceso nacen aisladas"
# El conf de pruebas apaga APP_ISOLATION (un usuario que no existe rompe los
# chown reales); aquí se enciende a propósito, con el useradd doblado en lib.
# El tipo va explícito: la sección de arriba dejó el doble de detect_stack en
# 'static', y una estática no se aísla — lo que se prueba aquí es el registro.
APP_ISOLATION="yes"
: > "$USERS_LOG"
nueva --repo https://example.test/isla.git --domain isla.test \
      --type node --start "node server.js" --yes
check "termina bien"     "0"          "$r"
check "con su usuario"   "orbit-isla" "$(campo isla A_USER)"
check "creado de verdad" "1"          "$(grep -c 'orbit-isla$' "$USERS_LOG")"
# Y una app PHP, que es la que más lo necesita: su código lo ejecuta php-fpm,
# no ella, así que sin usuario —y sin el pool que va con él— nace compartiendo
# intérprete con todas las demás. Lo dejó fuera la primera versión y lo cazó la
# revisión del PR #11: la condición miraba sólo si la app tenía proceso.
: > "$USERS_LOG"
nueva --repo https://example.test/foto.git --domain foto.test \
      --type php --docroot public --yes
check "una PHP también"  "orbit-foto" "$(campo foto A_USER)"
check "con su usuario"   "1"          "$(grep -c 'orbit-foto$' "$USERS_LOG")"
check "y su pool"        "1"          "$([[ -f "$(php_pool_file foto)" ]] && echo 1 || echo 0)"
APP_ISOLATION="no"
nueva --repo https://example.test/compartida.git --domain compartida.test \
      --type node --start "node server.js" --yes
check "apagado, sin usuario" ""       "$(campo compartida A_USER)"

report
