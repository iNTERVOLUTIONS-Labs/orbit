#!/usr/bin/env bash
# Los ayudantes de install.sh que deciden qué se ve cuando algo va mal.
#   bash tests/install_test.sh
#
# install.sh es un script, no una biblioteca: en cuanto se carga, instala. Así
# que aquí se extraen sólo las funciones que interesan, con la misma técnica
# que ya usan tests/lib.sh y el propio install.sh para el núcleo de idiomas.
#
# Lo que se comprueba son las dos cosas que un servidor de verdad encontró en
# los primeros cinco minutos y que ninguna prueba anterior podía ver: que el
# error de apt llegue entero a quien instala, y que un sistema sin los pockets
# de actualizaciones lo sepa antes de atascarse.
# shellcheck disable=SC2034  # VERSION_CODENAME la leen las funciones extraídas
# de install.sh, no este fichero: shellcheck no puede verlo desde aquí.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SRC="$ORBIT_ROOT/install.sh"

# Las funciones, sacadas por nombre. Si alguna dejara de terminar en '}' al
# principio de línea, esto sacaría un trozo a medias y la prueba lo diría al
# instante — que es justo lo que queremos de una extracción.
extraer() { # extraer <función…>
  local f
  for f in "$@"; do
    sed -n "/^$f() {/,/^}/p" "$SRC"
    printf '\n'
  done
}
# shellcheck disable=SC1090
source <(extraer apt_install _apt_pocket_hay _apt_pockets_faltan _apt_pockets_aviso _apt_formato_sources _php_ver_del_sistema _ssh_puertos _swap_aviso)

# Dobles de lo que esas funciones usan del resto del script.
SALIDA_LOG="$TMP/salida.log"
# Los dobles FORMATEAN, como los de verdad: 'warn "… %s" "$x"'. Guardando sólo
# el primer argumento, lo que se comprueba abajo —que el mensaje nombre el
# pocket concreto y los paquetes concretos— nunca podría ser cierto, y la
# prueba estaría midiendo el doble en vez del código.
_reg() { local tag="$1" f="$2"; shift 2
  # shellcheck disable=SC2059  # el formato es del código, igual que en warn/info
  printf "$tag $f\n" "$@" >> "$SALIDA_LOG"; }
warn() { _reg WARN "$@"; }
info() { _reg INFO "$@"; }
die()  { _reg DIE  "$@"; return 1; }

section "El aviso de los pockets"
# 'apt-cache policy' se dobla porque lo que se prueba es la lectura, no apt.
VERSION_CODENAME="noble"
apt-cache() { cat "$TMP/policy"; }
# Un sistema completo: los tres pockets presentes.
printf 'release v=24.04,o=Ubuntu,a=noble,n=noble,c=main\nrelease a=noble-updates,n=noble\nrelease a=noble-security,n=noble\n' > "$TMP/policy"
check "sistema completo, sin quejas" "" "$(_apt_pockets_faltan)"
# El caso que atascó el servidor: 'Suites: noble' a secas.
printf 'release v=24.04,o=Ubuntu,a=noble,n=noble,c=main\n' > "$TMP/policy"
check "faltan los dos" "noble-updates noble-security" "$(_apt_pockets_faltan)"
# Y cada uno por su lado, porque son fallos distintos: sin '-updates' hay
# paquetes que no resuelven; sin '-security' el servidor no recibe parches.
printf 'release a=noble,n=noble\nrelease a=noble-updates,n=noble\n' > "$TMP/policy"
check "falta sólo seguridad" "noble-security" "$(_apt_pockets_faltan)"
printf 'release a=noble,n=noble\nrelease a=noble-security,n=noble\n' > "$TMP/policy"
check "falta sólo updates"   "noble-updates"  "$(_apt_pockets_faltan)"

# Sin nombre en clave no se inventa nada: en un sistema que no dice cuál es,
# afirmar que le faltan pockets sería adivinar.
VERSION_CODENAME=""
check "sin codename, callado" "" "$(_apt_pockets_faltan)"
VERSION_CODENAME="noble"
# Y si apt-cache no contesta —no está, o falla— tampoco.
apt-cache() { return 1; }
check "sin apt-cache, callado" "" "$(_apt_pockets_faltan)"
apt-cache() { cat "$TMP/policy"; }

section "Sin metadatos de apt no se acusa a nadie"
# Con /var/lib/apt/lists vacío —una imagen recién hecha, o un 'apt-get clean'—
# apt-cache sigue imprimiendo el estado de dpkg y ninguna entrada de
# repositorio. Sin la guarda, un sistema perfectamente configurado recibía el
# aviso entero: un aviso que acusa a quien no es cuesta más que no avisar.
printf 'Package files:\n 100 /var/lib/dpkg/status\n     release a=now\n' > "$TMP/policy"
check "listas vacías, callado" "" "$(_apt_pockets_faltan)"
# Y que la guarda no tape el caso de verdad: con el pocket base a la vista, sí
# se afirma lo que falta.
printf 'release a=noble,n=noble\n' > "$TMP/policy"
check "con el base visible, sí habla" "noble-updates noble-security" "$(_apt_pockets_faltan)"

section "Debian nombra los pockets al revés que Ubuntu"
# Los dos archivos ponen el dato en campos distintos, comprobado contra los
# ficheros Release de verdad y no de memoria:
#
#   Ubuntu noble-security     Suite: noble-security       Codename: noble
#   Debian bookworm-security  Suite: oldstable-security   Codename: bookworm-security
#
# 'apt-cache policy' publica Suite como 'a=' y Codename como 'n='. Escrito
# sólo con 'a=', esto era correcto en Ubuntu e **inerte en Debian**: no existe
# ningún 'a=bookworm', así que la guarda del pocket base cortaba antes de
# mirar nada y el aviso no podía salir jamás — el aviso que existe porque sin
# '-security' unattended-upgrades no tiene de dónde traer parches.
#
# Las líneas de abajo son la salida literal de 'apt-cache policy' en una
# Debian 12, con el orden de campos que imprime apt.
VERSION_CODENAME="bookworm"
printf 'release v=12.15,o=Debian,a=oldstable,n=bookworm,l=Debian,c=main,b=amd64\nrelease v=12-updates,o=Debian,a=oldstable-updates,n=bookworm-updates,l=Debian,c=main,b=amd64\nrelease v=12,o=Debian,a=oldstable-security,n=bookworm-security,l=Debian-Security,c=main,b=amd64\n' > "$TMP/policy"
check "Debian completa, sin quejas" "" "$(_apt_pockets_faltan)"
# Y el caso que importa: la misma máquina sin el pocket de seguridad. Antes
# de la v1.3.0 esto salía vacío, o sea que un Debian sin parches automáticos
# pasaba el instalador sin una sola línea.
printf 'release v=12.15,o=Debian,a=oldstable,n=bookworm,l=Debian,c=main,b=amd64\nrelease v=12-updates,o=Debian,a=oldstable-updates,n=bookworm-updates,l=Debian,c=main,b=amd64\n' > "$TMP/policy"
check "Debian sin seguridad, habla" "bookworm-security" "$(_apt_pockets_faltan)"
printf 'release v=12.15,o=Debian,a=oldstable,n=bookworm,l=Debian,c=main,b=amd64\n' > "$TMP/policy"
check "Debian pelada, los dos" "bookworm-updates bookworm-security" "$(_apt_pockets_faltan)"
# El 'a=' de Debian no vale como atajo, y esto lo fija: 'oldstable' era
# 'stable' hace dos años y será otra cosa cuando salga la siguiente. Una
# política que sólo trae los Suite móviles no identifica ningún pocket.
printf 'release v=12.15,o=Debian,a=oldstable,l=Debian,c=main,b=amd64\n' > "$TMP/policy"
check "sin codename no adivina" "" "$(_apt_pockets_faltan)"

# Y el campo se compara ENTERO, porque 'bookworm' es subcadena de
# 'bookworm-updates'. Con una comparación floja, una máquina que sólo tuviera
# el pocket de actualizaciones daría el base por presente y el aviso hablaría
# de una configuración que no es la suya. Aquí lo correcto es callar: sin
# pocket base no hay nada fiable que juzgar.
VERSION_CODENAME="bookworm"
printf 'release v=12-updates,o=Debian,a=oldstable-updates,n=bookworm-updates,l=Debian,c=main,b=amd64\n' > "$TMP/policy"
check "el prefijo no cuela" "" "$(_apt_pockets_faltan)"

# En Ubuntu el mismo caso se comporta distinto, y no es una incoherencia: allí
# el Codename de los tres pockets es 'noble' a secas, así que una entrada de
# '-updates' ya demuestra que hay metadatos de noble y el aviso puede afirmar
# lo que falta. Es lo que se quiere de la guarda —distinguir «no hay
# metadatos» de «faltan pockets»—, y por eso se comprueban las dos.
VERSION_CODENAME="noble"
printf 'release a=noble-updates,n=noble\n' > "$TMP/policy"
check "Ubuntu sí puede afirmar" "noble-security" "$(_apt_pockets_faltan)"

section "Qué PHP trae esta distribución"
# Estaba escrito 'PHP_VER=8.3' porque es lo de Ubuntu 24.04, y era el único
# motivo por el que el instalador no valía para Debian 12 (8.2): doce
# 'php8.3-*' que allí no existen. Se le pregunta al metapaquete 'php-fpm', que
# lo declara en su 'Depends' y no hay que mantener a mano.
apt-cache() { cat "$TMP/phpshow"; }
printf 'Package: php-fpm\nVersion: 2:8.3+93ubuntu2\nDepends: php8.3-fpm\n' > "$TMP/phpshow"
check "Ubuntu 24.04 da 8.3" "8.3" "$(_php_ver_del_sistema)"
printf 'Package: php-fpm\nVersion: 2:8.2+93\nDepends: php8.2-fpm\n' > "$TMP/phpshow"
check "Debian 12 da 8.2"    "8.2" "$(_php_ver_del_sistema)"
# Sin metadatos no se inventa un número: quien llama se queda con el de
# cabecera, que es lo que hacía antes, y el paso lo enseña en su línea.
printf '' > "$TMP/phpshow"
check "sin respuesta, vacío"  "" "$(_php_ver_del_sistema)"
apt-cache() { return 1; }
check "sin apt-cache, vacío"  "" "$(_php_ver_del_sistema)"
# Y no se cuela cualquier cosa que lleve un número: 'php-fpm' declara varias
# líneas y sólo la de la dependencia dice la versión.
apt-cache() { cat "$TMP/phpshow"; }
printf 'Package: php-fpm\nVersion: 2:8.2+93\nSuggests: php7.4-fpm\nDepends: php8.2-fpm\n' > "$TMP/phpshow"
check "no la coge de Suggests" "8.2" "$(_php_ver_del_sistema)"
apt-cache() { cat "$TMP/policy"; }

# Y con errexit puesto de verdad, que es lo que este arnés no tiene.
#
# 'apt-cache show' de un paquete que no existe sale con 100, y bajo pipefail
# la asignación hereda ese 100: sin '|| true' eso mata al instalador entero en
# el paso 8, sin un mensaje, en cualquier sistema sin el metapaquete 'php-fpm'.
# Las comprobaciones de arriba no pueden verlo por partida doble —el arnés
# corre sin errexit, y encima la capturan con "$( )", que es justo la forma que
# sobrevive—, así que se ejerce la llamada DIRECTA y en un subshell con las
# banderas de verdad. Es el único patrón que reactiva errexit; ver docs/DEVELOPMENT.md.
cat > "$TMP/php_errexit.sh" <<'EOS'
set -Eeuo pipefail
eval "$(sed -n '/^_php_ver_del_sistema() {/,/^}/p' "$1")"
apt-cache() { return 100; }   # el paquete no existe
_php_ver_del_sistema          # llamada directa, sin capturar
echo VIVE
EOS
_sal="$(bash "$TMP/php_errexit.sh" "$SRC" 2>&1)"; _rc=$?
check "sobrevive a un apt-cache que falla" "VIVE" "$_sal"
check "y sin código de error"              "0"    "$_rc"
# Sin 'set +e … set -e' alrededor a propósito, y merece la nota porque el
# reflejo es escribirlo: este arnés corre con 'set -uo pipefail' y SIN errexit,
# así que ese 'set -e' no lo restauraría, lo ENCENDERÍA para todo lo que viene
# detrás. Pasó al escribir esto: la sección de 'apt_install', que ejerce un
# fallo a propósito, dejó de reportar y mató la suite entera desde ahí. El
# errexit que hace falta es el del subshell de arriba, que ya lo trae puesto.

section "El consejo depende del formato de las fuentes"
# La política se fija aquí y no se hereda de la sección de antes. Se heredaba,
# y al meter en medio la tanda de Debian estas dos comprobaciones se cayeron
# sin que nada suyo hubiera cambiado: el aviso no salía porque el fichero que
# habían dejado los de arriba ya no era el que hacía falta. Una prueba que
# depende del estado que le dejó otra falla el día que alguien escribe entre
# las dos, y acusa a quien no es.
VERSION_CODENAME="noble"
printf 'release a=noble,n=noble\n' > "$TMP/policy"
# El formato deb822 (.sources) tiene línea 'Suites:'; el clásico (.list) no —el
# pocket es el tercer término de cada línea 'deb URI pocket componentes'—, así
# que el mismo consejo en el otro formato no arregla nada y deja el fichero
# roto. Lo cazó la revisión del PR #13.
APT_SOURCES_DIR="$TMP/sources.d"; mkdir -p "$APT_SOURCES_DIR"
printf 'Types: deb\nURIs: http://x/ubuntu\nSuites: noble\nComponents: main\n' > "$APT_SOURCES_DIR/ubuntu.sources"
check "detecta deb822" "deb822" "$(_apt_formato_sources)"
: > "$SALIDA_LOG"; _apt_pockets_aviso
check "y habla de Suites"  "1" "$(grep -c '^INFO   Suites: noble noble-updates' "$SALIDA_LOG")"
rm -f "$APT_SOURCES_DIR"/*.sources
check "detecta el clásico" "list" "$(_apt_formato_sources)"
: > "$SALIDA_LOG"; _apt_pockets_aviso
# Ahí lo que vale es una línea 'deb …', no un campo que no existe. Se mira la
# INSTRUCCIÓN, no la palabra: el mensaje del formato clásico nombra 'Suites:'
# precisamente para decir que ahí no existe.
check "no propone Suites"  "0" "$(grep -c '^INFO   Suites:' "$SALIDA_LOG")"
check "sino una línea deb" "1" "$(grep -q '  deb <la misma URI> noble-updates' "$SALIDA_LOG" && echo 1 || echo 0)"
APT_SOURCES_DIR="$TMP/sources.d"
printf 'Types: deb\nSuites: noble\n' > "$APT_SOURCES_DIR/ubuntu.sources"

section "El aviso dice cómo arreglarlo"
printf 'release a=noble,n=noble\n' > "$TMP/policy"
: > "$SALIDA_LOG"
_apt_pockets_aviso
check "avisa"              "1" "$(grep -c '^WARN' "$SALIDA_LOG")"
check "nombra los pockets" "1" "$(grep -q 'noble-security' "$SALIDA_LOG" && echo 1 || echo 0)"
# El motivo de seguridad, no sólo el del atasco: es la mitad que importa cuando
# la máquina ya lleva meses funcionando.
check "y habla de parches"  "1" "$(grep -q 'parches' "$SALIDA_LOG" && echo 1 || echo 0)"
check "con la orden exacta" "1" "$(grep -q "Suites: noble" "$SALIDA_LOG" && echo 1 || echo 0)"
# Con todo en su sitio, ni una línea: un aviso que sale siempre no es un aviso.
printf 'release a=noble,n=noble\nrelease a=noble-updates,n=noble\nrelease a=noble-security,n=noble\n' > "$TMP/policy"
: > "$SALIDA_LOG"
_apt_pockets_aviso
check "y calla si no hay nada que decir" "0" "$(wc -l < "$SALIDA_LOG")"

section "apt_install no se traga el error"
# Es el fallo que se vio en un servidor: nueve llamadas con '-qq' y la salida a
# /dev/null, así que quien instalaba veía «held broken packages» y un número de
# línea, nunca QUÉ paquete ni por qué.
INTENTOS="$TMP/intentos.log"
# Con los pockets incompletos, que es como se dio en el servidor: el fallo de
# apt y su causa llegaban juntos, y el mensaje tiene que traer las dos cosas.
printf 'release a=noble,n=noble\n' > "$TMP/policy"
: > "$INTENTOS"; : > "$SALIDA_LOG"
apt-get() { printf '%s\n' "$*" >> "$INTENTOS"; return 100; }
run apt_install build-essential libssl-dev; r=$?
check "falla"                 "1" "$r"
# Dos intentos: el silencioso y el que enseña el motivo.
check "lo intenta dos veces"  "2" "$(wc -l < "$INTENTOS")"
check "el primero, callado"   "1" "$(head -1 "$INTENTOS" | grep -q -- '-qq' && echo 1 || echo 0)"
# El segundo SIN -qq es todo el arreglo: es el que deja que apt explique.
check "el segundo, hablador"  "0" "$(tail -1 "$INTENTOS" | grep -c -- '-qq')"
check "y nombra los paquetes" "1" "$(grep -q 'build-essential libssl-dev' "$SALIDA_LOG" && echo 1 || echo 0)"
check "acaba abortando"       "1" "$(grep -c '^DIE' "$SALIDA_LOG")"
# Y de paso mira los pockets: en el caso real, era la causa.
check "y mira los pockets"    "1" "$(grep -c 'pockets' "$SALIDA_LOG")"

# Cuando va bien, ni una palabra: el instalador ya tiene sus propios 'ok'.
: > "$INTENTOS"; : > "$SALIDA_LOG"
apt-get() { printf '%s\n' "$*" >> "$INTENTOS"; return 0; }
run apt_install nginx; r=$?
check "instala"               "0" "$r"
check "un solo intento"       "1" "$(wc -l < "$INTENTOS")"
check "y sin ruido"           "0" "$(wc -l < "$SALIDA_LOG")"

section "La tabla de glifos declara todo lo que el script usa"
# Un símbolo escrito en un printf pero ausente de la tabla es, con 'set -u', un
# 'unbound variable': el instalador muere en esa línea sin instalar nada. Pasó
# de verdad —60bc7cb cambió el '·' del banner por "$G_SEP" y no añadió G_SEP a
# la tabla— y nadie lo vio porque estas pruebas extraen funciones sueltas y
# ninguna llegaba a ejecutar el banner. Así que se comprueban las dos cosas:
# la lista entera de nombres, y el banner corriendo de verdad.
#
# '\b' delante evita que 'ORBIT_LANG_CODE=' cuele un 'G_CODE' inventado en la
# lista de declarados, que taparía justo el fallo que se busca.
_glifos_usados()     { grep -oE '\$\{?G_[A-Z_]+' "$SRC" | tr -d '${' | sort -u; }
_glifos_declarados() { grep -oE '\bG_[A-Z_]+=' "$SRC" | tr -d '=' | sort -u; }
check "ninguno sin declarar" "" \
  "$(comm -23 <(_glifos_usados) <(_glifos_declarados) | tr '\n' ' ' | sed 's/ *$//')"

# Y el banner, ejecutado con la tabla de verdad y con 'set -u' puesto, en los
# dos caminos: la terminal UTF-8 y el 'LANG=C' del VPS recién creado, que son
# ramas distintas del logotipo y podrían perder glifos por separado.
cat > "$TMP/banner.sh" <<'EOS'
set -Eeuo pipefail
eval "$(sed -n '/^if \[\[ "${LC_ALL/,/^fi$/p' "$1")"
eval "$(sed -n '/^banner() {/,/^}/p' "$1")"
ORBIT_VERSION="0.0.0"; D=""; R=""
banner
EOS
_banner_con() { # _banner_con <locale>
  LANG="$1" LC_ALL="$1" LC_CTYPE="$1" bash "$TMP/banner.sh" "$SRC" >/dev/null 2>&1 \
    && echo vive || echo muere
}
check "el banner vive en UTF-8" "vive" "$(_banner_con en_US.UTF-8)"
check "y en una terminal LANG=C" "vive" "$(_banner_con C)"

section "Tener swap no es tener suficiente"
# El paso 2 crea 4 GB para que un build grande tenga aire, pero su guarda mira
# si EXISTE swap, no cuánta. Una máquina que ya trae 512 MB pasaba por ahí en
# silencio y se quedaba igual de justa. Salió en la instalación real: 3.880 MB
# de RAM y 975 MB de swap al 100%, con shellcheck sobre 'orbit' muriéndose por
# falta de memoria. No se toca lo que ya está montado; se dice cuánto hay.
: > "$SALIDA_LOG"
free() { printf 'Mem: 3880 x x\nSwap: 974 x x\n'; }
run _swap_aviso; r=$?
check "no falla"                "0" "$r"
check "dice cuánta swap hay"    "1" "$(grep -c 'Ya existe swap (974 MB)' "$SALIDA_LOG")"
check "y avisa de que es poca"  "1" "$(grep -c '^WARN' "$SALIDA_LOG")"
check "nombrando las dos cifras" "1" \
  "$(grep -c '3880 MB de RAM y 974 MB' "$SALIDA_LOG")"
check "y dice cómo añadirla"    "1" "$(grep -c 'fallocate -l 4G' "$SALIDA_LOG")"

# Con swap de sobra no hay nada que avisar: un aviso que sale siempre no lo lee
# nadie cuando importa.
: > "$SALIDA_LOG"
free() { printf 'Mem: 3880 x x\nSwap: 4096 x x\n'; }
run _swap_aviso; r=$?
check "con swap de sobra, no falla" "0" "$r"
check "lo dice igual"               "1" "$(grep -c 'Ya existe swap (4096 MB)' "$SALIDA_LOG")"
check "pero sin avisar"             "0" "$(grep -c '^WARN' "$SALIDA_LOG")"

# El umbral es 2048: justo por debajo avisa, justo en el borde no.
: > "$SALIDA_LOG"; free() { printf 'Mem: 3880 x x\nSwap: 2047 x x\n'; }
run _swap_aviso; check "2047 MB avisa" "1" "$(grep -c '^WARN' "$SALIDA_LOG")"
: > "$SALIDA_LOG"; free() { printf 'Mem: 3880 x x\nSwap: 2048 x x\n'; }
run _swap_aviso; check "2048 MB no"    "0" "$(grep -c '^WARN' "$SALIDA_LOG")"

# Y si 'free' no contesta, se sigue: esto es un aviso del instalador, no una
# comprobación de seguridad. Sin cifra no se puede afirmar que falte, así que
# no se afirma.
: > "$SALIDA_LOG"; free() { return 1; }
run _swap_aviso; r=$?
check "sin 'free' no se muere"   "0" "$r"
check "ni acusa a nadie"         "0" "$(grep -c '^WARN' "$SALIDA_LOG")"
unset -f free

section "En qué puerto está SSH, que no es donde el perfil de ufw cree"
# El paso 12 decía 'ufw allow OpenSSH'. Ese perfil falla de dos maneras, y las
# dos salieron ejecutando el instalador en una Debian 12 de verdad:
#
#   · Si no está instalado openssh-server, el perfil no existe: ufw devuelve
#     error y, con errexit, el instalador muere en el paso 12 de 13 sin llegar
#     a instalar 'orbit'. Es lo que pasó.
#   · Y cuando existe, dice 'ports=22/tcp' a pelo. Con sshd en otro puerto, el
#     cortafuegos abre el 22 y tapa el suyo — medido con un cliente en otro
#     espacio de red: el SSH de verdad daba TIMEOUT. Eso no da error, sale en
#     verde, y quien instala se entera al reconectar. Estaba también en Ubuntu.
#
# Aquí se dobla todo lo que la función consulta: no hace falta un sshd para
# comprobar que se le pregunta bien.
SSHD_CONFIG="$TMP/sshd_config"
SSHD_CONFIG_DIR="$TMP/sshd_config.d"
mkdir -p "$SSHD_CONFIG_DIR"
# Los dobles callan por defecto: cada caso enciende sólo la fuente que ejerce.
ss()   { return 0; }
sshd() { return 1; }
unset SSH_CONNECTION

check "sin nada, no inventa un puerto" "" "$(_ssh_puertos)"

# 1. El puerto de esta sesión. La fuente que no puede equivocarse sobre dejarte
#    fuera: si estás leyendo por SSH, es por ahí.
SSH_CONNECTION="10.0.0.9 51234 10.0.0.1 2222"
check "lo saca de SSH_CONNECTION" "2222" "$(_ssh_puertos)"
unset SSH_CONNECTION

# 2. Los sockets que escuchan, con el formato de 'ss' de verdad. La línea IPv6
#    importa: '[::]:2222' tiene tres ':' antes del puerto, y partir por ':' y
#    quedarse con el primer trozo daría '[' en vez del número.
ss() { cat <<'EOS'
LISTEN 0 128    0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=612,fd=3))
LISTEN 0 128       [::]:2222    [::]:* users:(("sshd",pid=612,fd=4))
LISTEN 0 511    0.0.0.0:80   0.0.0.0:* users:(("nginx",pid=700,fd=6))
EOS
}
check "lee los sockets, IPv6 incluido" "2222" "$(_ssh_puertos)"
check "y no confunde a nginx con sshd" "2222" "$(_ssh_puertos)"
ss() { return 0; }

# 3. Lo que sshd hará al arrancar. No tiene por qué coincidir con lo que
#    escucha: una config editada y sin recargar dice una cosa y el proceso otra.
sshd() { printf 'port 2222\nport 22\npermitrootlogin no\n'; }
check "pregunta a sshd -T" "22 2222" "$(_ssh_puertos)"
sshd() { return 1; }

# 4. Y si sshd no contesta —parado, o con una config que no valida—, el fichero.
printf 'Port 2222\nPermitRootLogin no\n' > "$SSHD_CONFIG"
check "lee el sshd_config" "2222" "$(_ssh_puertos)"

printf '   port   2244\n' > "$SSHD_CONFIG"   # sshd no distingue mayúsculas
check "sin importar sangrado ni caja" "2244" "$(_ssh_puertos)"

printf 'Port 22\nPort 2222\n' > "$SSHD_CONFIG"
check "varios Port, todos" "22 2222" "$(_ssh_puertos)"

# Un sshd_config sin 'Port' no significa «sin SSH»: significa 22, que es lo que
# haría sshd. Darlo por vacío dejaría el cortafuegos sin regla en la
# instalación más corriente que hay.
printf 'PermitRootLogin no\n' > "$SSHD_CONFIG"
check "sin Port es el 22, como sshd" "22" "$(_ssh_puertos)"

printf 'PermitRootLogin no\n' > "$SSHD_CONFIG"
printf 'Port 2022\n' > "$SSHD_CONFIG_DIR/99-puerto.conf"
check "y mira el directorio de Include" "2022" "$(_ssh_puertos)"
rm -f "$SSHD_CONFIG_DIR"/*.conf

# Las fuentes se unen, no se eligen: un puerto de más sólo abre donde SSH ya
# atiende, y uno de menos deja a alguien fuera.
SSH_CONNECTION="10.0.0.9 51234 10.0.0.1 22"
ss()   { echo 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))'; }
sshd() { printf 'port 2022\n'; }
printf 'Port 2244\n' > "$SSHD_CONFIG"
check "las une y las ordena, sin repetir" "22 2022 2222 2244" "$(_ssh_puertos)"
unset SSH_CONNECTION
ss() { return 0; }; sshd() { return 1; }
rm -f "$SSHD_CONFIG"

# Y lo que de verdad costó el bug: la función tiene que sobrevivir a que no
# haya NADA que encontrar. Sin coincidencias, el 'grep' del final devuelve 1 y
# bajo pipefail la asignación se queda con ese 1 — capturada no se nota, pero
# llamada directa mata el instalador. Por eso se llama sin capturar, dentro de
# un subshell con las banderas puestas: capturándola esta prueba no vería nada.
# Ver docs/DEVELOPMENT.md y ARCHITECTURE §10.
run bash -c '
  set -Eeuo pipefail
  SSHD_CONFIG=/nada; SSHD_CONFIG_DIR=/nada
  ss() { return 0; }; sshd() { return 1; }
  '"$(extraer _ssh_puertos)"'
  _ssh_puertos >/dev/null'; r=$?
check "no muere bajo errexit sin encontrar nada" "0" "$r"

# El bug fijado en el sitio donde estaba: el perfil no puede volver. Los
# comentarios se quitan antes de mirar — el de arriba explica el fallo citando
# la línea, y sin esto la prueba se acusaría a sí misma.
check "install.sh ya no usa el perfil OpenSSH" "0" \
  "$(grep -v '^[[:space:]]*#' "$SRC" | grep -c 'ufw allow OpenSSH')"
# Y las reglas de SSH van antes del 'enable', que es lo que evita que un fallo
# a mitad deje el cortafuegos levantado sin por dónde entrar.
_ln_ssh="$(grep -n '_ssh_puertos)"' "$SRC" | tail -1 | cut -d: -f1)"
_ln_up="$(grep -n 'ufw --force enable' "$SRC" | cut -d: -f1)"
check "y se abren antes de encender" "1" \
  "$(( _ln_ssh < _ln_up ? 1 : 0 ))"

report
