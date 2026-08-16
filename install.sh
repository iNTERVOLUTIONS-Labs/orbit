#!/usr/bin/env bash
# ============================================================================
#  ORBIT · Deploy Platform Installer
#  Ubuntu 24.04 · Debian 12  ·  nginx + Node 22 + pnpm + PostgreSQL + PHP + Python
#  Uso:  sudo bash install.sh
# ============================================================================
set -Eeuo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
APPS_DIR="/srv/apps"
ETC_DIR="/etc/orbit"
ACME_DIR="/var/www/orbit-acme"
NODE_MAJOR=22
# Lo que trae Ubuntu 24.04, y sólo el valor de partida: en el paso 8 se le
# pregunta a apt cuál sirve esta distribución, porque Debian 12 va por 8.2.
# Un PHP_VER puesto en el entorno gana sobre las dos cosas, y se recuerda que
# venía de fuera para no pisarlo con la respuesta de apt.
PHP_VER_FIJADO="${PHP_VER:-}"
PHP_VER="${PHP_VER:-8.3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# La versión no se declara aquí: vive en una sola línea de 'orbit' y de ahí se
# extrae, igual que el núcleo de idiomas. Este script la usa sólo para el
# banner, así que sin 'orbit' al lado basta un interrogante — del fichero
# ausente de verdad se ocupa el 'die' de más abajo. Cuando había dos
# declaraciones, subir la versión era acordarse de dos ficheros.
ORBIT_VERSION="$(sed -n 's/^ORBIT_VERSION="\([0-9][^"]*\)".*/\1/p' "$SCRIPT_DIR/orbit" 2>/dev/null || true)"
ORBIT_VERSION="${ORBIT_VERSION:-?}"

# ---------------------------------------------------------------- UI ------
if [[ -t 1 ]]; then
  B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[38;5;203m'; GRN=$'\e[38;5;114m'; YEL=$'\e[38;5;221m'
  BLU=$'\e[38;5;75m'; MAG=$'\e[38;5;177m'; CYA=$'\e[38;5;80m'
else
  B=""; D=""; R=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYA=""
fi

# ------------------------------------------------------------ idioma ------
#
# El instalador habla el idioma del sistema, igual que 'orbit'. Pero el
# mecanismo no se copia aquí: se saca de 'orbit', que está al lado —hace falta
# de todas formas, este script no puede instalar nada sin él— entre las dos
# marcas que lo delimitan. Dos copias de «qué idioma toca» se separan a la
# primera, y esta es la misma técnica que ya usa tests/lib.sh.
#
# Lo que sí es suyo es el catálogo: el instalador y 'orbit' no dicen las mismas
# frases, así que compartir el texto no tendría sentido.
#
# Si el fichero no está o las marcas han desaparecido, el instalador se queda
# en español en vez de romperse: sin idioma se instala igual, sin 'orbit' no.
# El 'die' de más abajo es el que se ocupa de que falte de verdad.
#
# El trozo se saca a una variable y se comprueba ahí dentro, sin tuberías. La
# primera versión hacía 'sed … | grep -q', y con pipefail eso NO funciona: al
# encontrar la línea, grep -q sale corriendo y cierra la tubería, sed recibe un
# SIGPIPE y la tubería entera devuelve 141. La condición fallaba siempre y el
# instalador se quedaba en español para todo el mundo, sin decir nada — que es
# justo lo que hace tan caro este tipo de fallo. Es la misma trampa de pipefail
# que documenta ARCHITECTURE §10, con otro disfraz.
_NUCLEO=""
[[ -r "$SCRIPT_DIR/orbit" ]] && _NUCLEO="$(sed -n '/^# >>> núcleo de idiomas/,/^# <<< núcleo de idiomas/p' "$SCRIPT_DIR/orbit" 2>/dev/null || true)"
if [[ "$_NUCLEO" == *$'\n_lang_resolve() {'* ]]; then
  # shellcheck disable=SC1090
  . <(printf '%s\n' "$_NUCLEO")
else
  # Sin núcleo, 't' es la identidad y todo sale en el idioma fuente.
  I18N_MSG=""
  declare -A I18N=()
  # Tiene que rendir igual que el núcleo, no sólo «no romperse»: si le faltan
  # las marcas de color, el instalador de repuesto escribe «{b}orbit{r}» tal
  # cual. Y la condición de los argumentos es la misma de _t. Ver ARCHITECTURE
  # §21.2 y §21.3.
  _t() {
    local f="${1-}"; shift || true
    if [[ "$f" == *'{'* ]]; then
      f="${f//'{b}'/${B-}}";     f="${f//'{d}'/${D-}}";     f="${f//'{r}'/${R-}}"
      f="${f//'{red}'/${RED-}}"; f="${f//'{grn}'/${GRN-}}"; f="${f//'{yel}'/${YEL-}}"
      f="${f//'{blu}'/${BLU-}}"; f="${f//'{mag}'/${MAG-}}"; f="${f//'{cya}'/${CYA-}}"
      f="${f//'{gry}'/${GRY-}}"
    fi
    # shellcheck disable=SC2059
    if (($#)); then printf -v I18N_MSG -- "$f" "$@"; else I18N_MSG="$f"; fi
  }
  t()  { _t "$@"; printf '%s' "$I18N_MSG"; }
  _lang_early() { :; }
  _lang_resolve() { :; }
  ORBIT_LANG_CODE="es"
fi

# El catálogo del instalador. Las reglas son las de 'orbit' (ver ARCHITECTURE
# §21): la clave es la frase en español, las partes variables van como %s, un
# '%' literal se escribe '%%' y los colores son marcas {b} {r}. Lo que falte
# sale en español.
_i18n_load() {
  # shellcheck disable=SC2034  # la lee _t, que viene del núcleo de 'orbit'
  I18N=()
  # El español no tiene catálogo: es el idioma en el que está escrito esto.
  [[ "$ORBIT_LANG_CODE" == "es" ]] && return 0
  case "$ORBIT_LANG_CODE" in
    en) _i18n_en ;;
  esac
}

_i18n_en() {
  # shellcheck disable=SC2034  # la lee _t, que viene del núcleo de 'orbit'
  I18N=(
    ["Fallo en la línea %s. Revisa el mensaje anterior."]="Failed on line %s. Check the message above."
    ["apt no ha podido instalar: %s"]="apt could not install: %s"
    ["Arregla lo que dice apt ahí arriba y vuelve a lanzar el instalador."]="Fix what apt says above and run the installer again."
    ["A este sistema le faltan pockets de apt: %s"]="This system is missing apt pockets: %s"
    ["Sin ellos hay paquetes que no se pueden resolver —y sin '-security' el"]="Without them some packages cannot be resolved — and without '-security' the"
    ["servidor no recibe parches, aunque unattended-upgrades esté puesto."]="server gets no patches, even with unattended-upgrades installed."
    ["Añádelos a la línea 'Suites:' de tus fuentes de apt, que quede así:"]="Add them to the 'Suites:' line of your apt sources, so it reads:"
    ["Tus fuentes usan el formato clásico, que no tiene línea 'Suites:':"]="Your sources use the classic format, which has no 'Suites:' line:"
    ["añade una línea por cada pocket que falte, copiando la que ya tienes"]="add one line per missing pocket, copying the one you already have"
    ["y cambiando sólo el nombre del pocket. Por ejemplo:"]="and changing only the pocket name. For example:"
    ["  deb <la misma URI> %s <los mismos componentes>"]="  deb <the same URI> %s <the same components>"
    ["  Suites: %s %s"]="  Suites: %s %s"
    ["y después:  sudo apt-get update"]="and then:  sudo apt-get update"
    ["Ejecuta como root:  sudo bash install.sh"]="Run this as root:  sudo bash install.sh"
    ["No se detecta /etc/os-release"]="I can't find /etc/os-release"
    ["Probado en Ubuntu 24.04 y Debian 12 (detectado %s). Continuando…"]="Tested on Ubuntu 24.04 and Debian 12 (found %s). Carrying on…"
    ["fail2ban no ha arrancado, así que SSH no está vigilado."]="fail2ban did not start, so SSH is not being watched."
    ["Mira el motivo con:  systemctl status fail2ban  y  journalctl -u fail2ban -n 30"]="Find out why with:  systemctl status fail2ban  and  journalctl -u fail2ban -n 30"
    ["No encuentro el fichero 'orbit' junto a install.sh. Sube los dos ficheros al mismo directorio."]="I can't find the 'orbit' file next to install.sh. Upload both files to the same directory."
    ["1/13  Actualizando el sistema base"]="1/13  Updating the base system"
    ["Paquetes base instalados"]="Base packages installed"
    ["2/13  Zona horaria, swap y límites del kernel"]="2/13  Timezone, swap and kernel limits"
    ["Zona horaria: %s"]="Timezone: %s"
    ["Swap de 4 GB creada (builds de Next.js agradecidos)"]="4 GB of swap created (Next.js builds will thank you)"
    ["Ya existe swap (%s MB), no toco nada"]="Swap already exists (%s MB), leaving it alone"
    ["Con %s MB de RAM y %s MB de swap, un build grande puede quedarse sin memoria."]="With %s MB of RAM and %s MB of swap, a large build may run out of memory."
    ["Si te pasa, añade swap:  fallocate -l 4G /swapfile && chmod 600 /swapfile"]="If that happens, add swap:  fallocate -l 4G /swapfile && chmod 600 /swapfile"
    ["                        mkswap /swapfile && swapon /swapfile"]="                           mkswap /swapfile && swapon /swapfile"
    ["Tuning de kernel aplicado"]="Kernel tuning applied"
    ["3/13  Creando el usuario de despliegue '%s'"]="3/13  Creating the deploy user '%s'"
    ["Usuario '%s' creado (sin contraseña, sólo uso interno)"]="User '%s' created (no password, internal use only)"
    ["El usuario '%s' ya existía"]="User '%s' already existed"
    ["Estructura de directorios lista en %s"]="Directory layout ready in %s"
    ["4/13  Instalando Node.js %s LTS + pnpm"]="4/13  Installing Node.js %s LTS + pnpm"
    # Estas dos se escriben igual en los dos idiomas. Están de todas formas: el
    # catálogo del instalador son cuarenta frases, así que la regla es que las
    # lleva todas y la prueba lo exige. Con una lista de excepciones a mano —lo
    # que sí hace 'orbit', que tiene seiscientas— habría que mantenerla.
    ["Node %s · npm %s · pnpm %s"]="Node %s · npm %s · pnpm %s"
    ["GitHub CLI %s"]="GitHub CLI %s"
    ["5/13  Instalando y endureciendo nginx"]="5/13  Installing and hardening nginx"
    ["nginx configurado (gzip, cabeceras de seguridad, TLS compartido)"]="nginx configured (gzip, security headers, shared TLS)"
    ["6/13  Restaurando IPs reales de Cloudflare"]="6/13  Restoring Cloudflare's real IPs"
    ["No pude descargar los rangos de Cloudflare; se aplicará la lista incluida"]="I could not download Cloudflare's ranges; the bundled list will be used"
    ["%s rangos de Cloudflare cargados"]="%s Cloudflare ranges loaded"
    ["7/13  Instalando PostgreSQL"]="7/13  Installing PostgreSQL"
    ["PostgreSQL %s escuchando sólo en localhost"]="PostgreSQL %s listening on localhost only"
    ["8/13  Instalando PHP %s (FPM) + Composer"]="8/13  Installing PHP %s (FPM) + Composer"
    ["PHP %s con pool 'orbit' en /run/php/orbit.sock"]="PHP %s with the 'orbit' pool on /run/php/orbit.sock"
    ["9/13  Instalando Python + herramientas"]="9/13  Installing Python + tooling"
    ["Python %s listo (cada app usa su propio venv)"]="Python %s ready (each app uses its own venv)"
    ["10/13  Instalando Certbot (Let's Encrypt)"]="10/13  Installing Certbot (Let's Encrypt)"
    ["Certbot instalado, renovación automática activada"]="Certbot installed, automatic renewal on"
    ["11/13  Instalando GitHub CLI"]="11/13  Installing the GitHub CLI"
    ["12/13  Firewall, fail2ban y actualizaciones automáticas"]="12/13  Firewall, fail2ban and automatic updates"
    ["UFW activo: SSH en %s, más 80 y 443"]="UFW on: SSH on %s, plus 80 and 443"
    ["UFW activo: sólo 80 y 443"]="UFW on: 80 and 443 only"
    ["No hay ningún servidor SSH en esta máquina."]="There is no SSH server on this machine."
    ["El cortafuegos se activa sin regla para SSH. Si instalas uno después,"]="The firewall goes up with no SSH rule. If you install one later,"
    ["ábrele el puerto:  sudo ufw allow <puerto>/tcp"]="open its port:  sudo ufw allow <port>/tcp"
    ["fail2ban vigilando SSH"]="fail2ban watching SSH"
    ["Parches de seguridad automáticos activados"]="Automatic security patches enabled"
    ["13/13  Instalando la herramienta 'orbit'"]="13/13  Installing the 'orbit' tool"
    ["No he podido generar el servidor por defecto; ejecuta 'orbit nginx-rebuild'"]="I could not generate the default server; run 'orbit nginx-rebuild'"
    ["nginx no valida la configuración"]="nginx does not validate the configuration"
    ["Comandos disponibles: {b}orbit{r}  (y el atajo {b}dv{r})"]="Commands available: {b}orbit{r}  (and the {b}dv{r} shortcut)"
  )
}

# Los mismos símbolos y por el mismo motivo que en 'orbit' — ver el bloque de
# la tabla de glifos allí. Resumen: ✔ (U+2714) y ✖ (U+2716) están en emoji-data
# y la fuente de emoji en color se los queda, así que el tic verde salía como
# un icono con su propio color y ancho doble; ✓ (U+2713) y ✗ (U+2717) no lo
# están. Y una terminal sin UTF-8 —el 'LANG=C' de un VPS recién creado, que es
# justo donde se ejecuta este instalador— no pinta ninguno, así que ASCII.
if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]* ]]; then
  G_OK="✓"; G_ERR="✗"; G_INFO="·"; G_SEC="▸"; G_SEP="·"
else
  G_OK="+"; G_ERR="x"; G_INFO="."; G_SEC=">"; G_SEP="-"
fi

step()  { _t "$@"; printf "\n${MAG}${B}%s %s${R}\n" "$G_SEC" "$I18N_MSG"; }
ok()    { _t "$@"; printf "  ${GRN}%s${R} %s\n" "$G_OK" "$I18N_MSG"; }
info()  { _t "$@"; printf "  ${BLU}%s${R} %s\n" "$G_INFO" "$I18N_MSG"; }
warn()  { _t "$@"; printf "  ${YEL}!${R} %s\n" "$I18N_MSG"; }
die()   { _t "$@"; printf "\n  ${RED}%s %s${R}\n\n" "$G_ERR" "$I18N_MSG" >&2; exit 1; }

# El idioma, decidido antes del primer mensaje. '--lang en' vale también aquí,
# porque quien instala en inglés lo primero que hace es instalar.
_lang_early "$@"
_lang_resolve
_i18n_load

banner() {
# El logotipo está hecho de bloques y esquinas dobles. Sin UTF-8 no sale un
# logotipo: salen seis líneas de basura, y es lo primero que ve quien instala.
if [[ "$G_OK" == "✓" ]]; then
cat <<'EOB'

   ██████╗ ██████╗ ██████╗ ██╗████████╗
  ██╔═══██╗██╔══██╗██╔══██╗██║╚══██╔══╝
  ██║   ██║██████╔╝██████╔╝██║   ██║
  ██║   ██║██╔══██╗██╔══██╗██║   ██║
  ╚██████╔╝██║  ██║██████╔╝██║   ██║
   ╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚═╝   ╚═╝

  Deploy platform · React / Next / Astro / PHP / Python
EOB
else
cat <<'EOB'

  ORBIT

  Deploy platform - React / Next / Astro / PHP / Python
EOB
fi
# El nombre sale de /etc/os-release, que ya está cargado cuando esto se pinta:
# decir «Ubuntu 24.04 LTS» en un Debian era mentira en la primera línea. Con
# valor por defecto porque este printf corre bajo 'set -u' y la variable la
# pone el fichero de la máquina, no el script — que es exactamente cómo el
# banner mató al instalador en la v1.2.8.
printf "  ${D}v%s %s %s${R}\n" "$ORBIT_VERSION" "$G_SEP" "${PRETTY_NAME:-Linux}"
}

# El mensaje va en una función y no dentro del 'trap': entre comillas simples
# no está en posición de comando, y la prueba que cruza el catálogo con el
# código no lo vería. Un mensaje invisible para esa prueba es uno que se queda
# sin traducir sin que nadie se entere.
_on_err() { die "Fallo en la línea %s. Revisa el mensaje anterior." "$1"; }
trap '_on_err "$LINENO"' ERR

# apt-get con '-qq' y la salida a /dev/null esconde justo lo que hace falta
# cuando falla: qué paquete no se puede resolver y por qué. Lo encontró un
# servidor de verdad a los cinco minutos — una imagen de Ubuntu con el pocket
# 'noble' a secas dejaba 'build-essential' y 'libssl-dev' sin resolver, y lo
# único que veía quien instalaba era «held broken packages» y un número de
# línea. Con nueve llamadas repartidas por el script, el arreglo va en una.
#
# Callado mientras va bien, y al fallar repite el mismo comando SIN silenciar
# para que el motivo salga entero. El segundo intento no arregla nada: está
# para contar lo que pasó, y por eso lleva '|| true' — lo que decide es el
# 'die' de después, no su código de salida.
apt_install() { # apt_install <paquetes…>
  apt-get install -y -qq "$@" >/dev/null 2>&1 && return 0
  warn "apt no ha podido instalar: %s" "$*"
  printf "\n"
  apt-get install -y "$@" || true
  printf "\n"
  _apt_pockets_aviso
  die "Arregla lo que dice apt ahí arriba y vuelve a lanzar el instalador."
}

# Los pockets de actualizaciones y de seguridad, o su ausencia.
#
# Una imagen instalada con sólo el pocket original —'Suites: noble'— tiene los
# paquetes congelados en el día del lanzamiento, mientras que el sistema ya va
# por un point release con paquetes de '-updates'. Cualquier paquete que
# dependa de una versión exacta (build-essential vía libc6-dev, libssl-dev vía
# libssl3t64) deja de poder resolverse, y apt lo cuenta como «paquetes rotos»,
# que no se parece en nada a la causa.
#
# Y hay algo peor que el atasco: sin '-security' esa máquina **no recibe
# parches**. El instalador pone unattended-upgrades, que sin ese pocket no
# tiene de dónde traer nada — protección aparente y cero real.
#
# La salida de apt-cache se lleva a una variable y se mira ahí: 'apt-cache
# policy | grep -q' bajo pipefail devuelve 141 y la condición nunca sería
# cierta. Es la trampa que ya costó que el instalador se quedara en español
# para todo el mundo (ver el núcleo de idiomas, arriba).
#
# Y hay un detalle que sólo aparece al salir de Ubuntu, comprobado contra los
# ficheros Release de los dos archivos y no de memoria: **Ubuntu nombra el
# pocket en el campo Suite y Debian en el Codename, o sea al revés**.
#
#   Ubuntu noble-security   Suite: noble-security   Codename: noble
#   Debian bookworm-security  Suite: oldstable-security  Codename: bookworm-security
#
# 'apt-cache policy' publica el primero como 'a=' y el segundo como 'n=', así
# que una comprobación escrita sólo con 'a=' es correcta en Ubuntu e **inerte
# en Debian**: allí no existe ningún 'a=bookworm', la guarda del pocket base
# corta antes de mirar nada y el aviso no puede salir jamás. Justo el aviso
# que existe porque sin '-security' unattended-upgrades no tiene de dónde
# traer parches. Se acepta cualquiera de los dos campos.
#
# Y no vale usar sólo 'n=': en Ubuntu el Codename de los tres pockets es
# 'noble' a secas, así que 'n=noble-security' no existe. Cada distribución
# pone el dato en el campo que la otra deja fijo.
#
# El 'a=' de Debian tampoco serviría por otro motivo, y conviene saberlo antes
# de intentar el atajo: es 'oldstable-security' hoy y era 'stable-security'
# hace dos años. Es una etiqueta que se mueve sola cuando sale la versión
# siguiente; el codename es lo único estable.
# El campo se compara ENTERO, y no como subcadena: 'a=noble' aparece dentro de
# 'a=noble-updates', así que un sistema al que le falte el pocket base pero
# tenga el de actualizaciones diría que está completo. Se pasan los separadores
# —comas, espacios y saltos de línea— a comas y se envuelve el todo en una más,
# de modo que cada campo queda delimitado por los dos lados.
_apt_pocket_hay() { # _apt_pocket_hay <política> <nombre>
  local pol=",${1//[$'\n\t' ]/,},"
  [[ "$pol" == *",a=$2,"* || "$pol" == *",n=$2,"* ]]
}

_apt_pockets_faltan() { # -> imprime los que falten, separados por espacio
  local cod="${VERSION_CODENAME:-}" pol falta=""
  [[ -n "$cod" ]] || return 0
  pol="$(apt-cache policy 2>/dev/null || true)"
  [[ -n "$pol" ]] || return 0
  # Y si no se ve ni el pocket base, lo que falta no son los pockets: son los
  # metadatos. Con /var/lib/apt/lists vacío —una imagen recién hecha, o un
  # 'apt-get clean'— 'apt-cache policy' sigue imprimiendo el estado de dpkg
  # ('release a=now') y ninguna entrada de repositorio, así que sin esto un
  # sistema perfectamente configurado recibía el aviso entero. Un aviso que
  # acusa a quien no es cuesta más que no avisar. Lo cazó la revisión del PR.
  _apt_pocket_hay "$pol" "$cod" || return 0
  _apt_pocket_hay "$pol" "${cod}-updates"  || falta+=" ${cod}-updates"
  _apt_pocket_hay "$pol" "${cod}-security" || falta+=" ${cod}-security"
  printf '%s' "${falta# }"
}

# En qué formato están las fuentes de apt. Importa para el consejo: el formato
# deb822 (.sources) tiene una línea 'Suites:' que se amplía, y el clásico
# (.list) no tiene ese campo —el pocket es el tercer término de cada línea
# 'deb URI pocket componentes'—, así que decirle a alguien con .list que añada
# una línea 'Suites:' no arregla nada y encima le deja el fichero roto. Lo
# cazó la revisión del PR.
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
_apt_formato_sources() { # -> deb822 | list
  local f
  for f in "$APT_SOURCES_DIR"/*.sources; do
    [[ -f "$f" ]] || continue
    grep -q '^Suites:' "$f" 2>/dev/null && { printf 'deb822'; return 0; }
  done
  printf 'list'
}

_apt_pockets_aviso() {
  local falta cod; falta="$(_apt_pockets_faltan)"
  [[ -n "$falta" ]] || return 0
  cod="${VERSION_CODENAME:-noble}"
  warn "A este sistema le faltan pockets de apt: %s" "$falta"
  info "Sin ellos hay paquetes que no se pueden resolver —y sin '-security' el"
  info "servidor no recibe parches, aunque unattended-upgrades esté puesto."
  # Se enseña cómo tiene que QUEDAR, no un 'sed' que lo reescriba: quien lo lea
  # entiende qué está cambiando, y no hay orden que pueda apuntar al fichero
  # equivocado.
  if [[ "$(_apt_formato_sources)" == "deb822" ]]; then
    info "Añádelos a la línea 'Suites:' de tus fuentes de apt, que quede así:"
    info "  Suites: %s %s" "$cod" "$falta"
  else
    info "Tus fuentes usan el formato clásico, que no tiene línea 'Suites:':"
    info "añade una línea por cada pocket que falte, copiando la que ya tienes"
    info "y cambiando sólo el nombre del pocket. Por ejemplo:"
    info "  deb <la misma URI> %s <los mismos componentes>" "${falta%% *}"
  fi
  info "y después:  sudo apt-get update"
  return 0
}

# Cuánta swap hay ya, y si llega. Se llama sólo cuando el paso 2 ha encontrado
# swap montada, o sea cuando no va a crear la suya.
#
# Que haya swap no es que haya suficiente, y la guarda del paso 2 sólo mira si
# EXISTE. Ese paso está ahí para que un build grande tenga aire —por eso son 4
# GB— así que una máquina que ya trae 512 MB de fábrica pasaba por allí en
# silencio y se quedaba igual de justa. Es la lección de la guarda de
# 'python3-venv' otra vez: preguntar si algo está no es preguntar si llega.
# Medido en la máquina donde salió: 3.880 MB de RAM y 975 MB de swap al 100%,
# con shellcheck sobre 'orbit' muriéndose por falta de memoria.
#
# Lo que NO se hace es tocar lo que el administrador ya montó: esa parte estaba
# bien y sigue igual. Lo que faltaba era decir cuánto hay.
_swap_aviso() {
  local swap_mb ram_mb
  swap_mb="$(free -m | awk '/^Swap:/ {print $2}')" || true
  ram_mb="$(free -m | awk '/^Mem:/ {print $2}')" || true
  info "Ya existe swap (%s MB), no toco nada" "${swap_mb:-?}"
  # El umbral es la mitad de lo que este paso habría creado. Por debajo de ahí,
  # tener swap y no tenerla se parecen demasiado.
  if [[ -n "${swap_mb:-}" ]] && (( swap_mb < 2048 )); then
    warn "Con %s MB de RAM y %s MB de swap, un build grande puede quedarse sin memoria." "${ram_mb:-?}" "$swap_mb"
    info "Si te pasa, añade swap:  fallocate -l 4G /swapfile && chmod 600 /swapfile"
    info "                        mkswap /swapfile && swapon /swapfile"
  fi
  return 0
}

# En qué puertos atiende SSH, preguntando en vez de suponiendo.
#
# Esto existe porque el paso 12 decía 'ufw allow OpenSSH', y ese perfil miente
# de dos formas distintas —las dos encontradas ejecutando el instalador en una
# Debian 12 de verdad, que es donde la primera se ve:
#
#   · No existe si no está instalado openssh-server. El perfil lo trae ese
#     paquete, en Debian y en Ubuntu igual (comprobado extrayendo los dos
#     .deb), así que en una máquina sin él ufw contesta «Could not find a
#     profile matching 'OpenSSH'» y, con errexit, eso mata el instalador en el
#     paso 12 de 13: 'orbit' no llega a instalarse. Debian trae además un
#     perfil 'SSH' genérico que Ubuntu no tiene, así que cambiar el nombre
#     arreglaría una distribución y rompería la otra.
#
#   · Y cuando existe, declara 'ports=22/tcp' a pelo. Un servidor con sshd en
#     otro puerto —de lo primero que hace cualquier guía de endurecimiento—
#     recibía un cortafuegos que abre el 22 y tapa el suyo. Eso no falla: sale
#     en verde, anuncia «SSH, 80 y 443», y la sesión abierta sobrevive porque
#     ufw deja pasar lo ESTABLECIDO. Te enteras al reconectar, cuando ya no
#     puedes. Ese es el fallo grave, y estaba también en Ubuntu.
#
# Las fuentes van de más a menos fiables y se unen, que es lo seguro: un puerto
# de más sólo abre donde SSH ya atiende, y uno de menos deja a alguien fuera.
# Las dos rutas salen a variables por lo mismo que APT_SOURCES_DIR: para que la
# prueba pueda darle un sshd_config de mentira sin tocar el del sistema.
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_CONFIG_DIR="${SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}"

_ssh_puertos() { # -> los puertos de SSH separados por espacio, o nada
  local out p
  out="$( {
      # 1. El puerto que lleva ESTA sesión. Es la única fuente que no puede
      #    equivocarse sobre quedarse fuera: si estás leyendo esto por SSH, es
      #    por ahí. Sólo llega si el entorno se conserva ('sudo -E', o root
      #    directamente): sudo no guarda SSH_CONNECTION por defecto.
      [[ -n "${SSH_CONNECTION:-}" ]] && awk '{print $4}' <<<"$SSH_CONNECTION"
      # 2. Lo que escucha ahora mismo.
      ss -lntpH 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
      # 3. Lo que hará sshd al arrancar, con los Include ya resueltos. No tiene
      #    por qué coincidir con lo de arriba: una config editada y sin
      #    recargar dice una cosa y el proceso vivo otra.
      sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
      # 4. Y si sshd no contesta —parado, o con una config que no valida— lo
      #    que diga el fichero. Aquí los Include se miran a mano, que es peor
      #    que preguntarle a sshd; por eso va la última. Un sshd_config sin
      #    'Port' significa 22, que es lo que haría sshd.
      if [[ -f "$SSHD_CONFIG" ]]; then
        p="$(grep -rhiE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
             "$SSHD_CONFIG" "$SSHD_CONFIG_DIR/" 2>/dev/null \
             | awk '{print $2}')" || true
        if [[ -n "$p" ]]; then printf '%s\n' "$p"; else printf '22\n'; fi
      fi
    } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' )" || true
  # El '|| true' va aquí dentro y no en quien llame: sin coincidencias, ese
  # grep devuelve 1, y bajo pipefail la asignación se queda con ese 1. Llamada
  # directa eso mata el instalador; capturada, no. Ver ARCHITECTURE §10.
  printf '%s' "${out% }"
  return 0
}

# ------------------------------------------------------------ checks ------
[[ $EUID -eq 0 ]] || die "Ejecuta como root:  sudo bash install.sh"
[[ -f /etc/os-release ]] || die "No se detecta /etc/os-release"
. /etc/os-release
# Se mira ID y no sólo VERSION_ID: '12' es Debian 12, pero también sería un
# Ubuntu inventado, y el aviso decía «Ubuntu» pasara lo que pasara. Sigue
# siendo un aviso y no un portazo —hay derivadas que funcionan igual—, pero
# ahora nombra lo que ha encontrado.
_distro="${ID:-desconocida} ${VERSION_ID:-?}"
case "$_distro" in
  "ubuntu 24.04"|"debian 12") ;;
  *) warn "Probado en Ubuntu 24.04 y Debian 12 (detectado %s). Continuando…" "$_distro" ;;
esac
[[ -f "$SCRIPT_DIR/orbit" ]] || die "No encuentro el fichero 'orbit' junto a install.sh. Sube los dos ficheros al mismo directorio."

banner
export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------- 1. system ------
step "1/13  Actualizando el sistema base"
apt-get update -qq
# Con los metadatos ya frescos, y antes de instalar nada: es un aviso, no un
# portazo —hay espejos que sirven todo desde un solo pocket—, pero enterarse
# aquí ahorra el atasco entero. Va después del 'update' a propósito: con
# /var/lib/apt/lists sin poblar, apt-cache no ve ningún repositorio y el aviso
# acusaría a un sistema que está bien.
_apt_pockets_aviso
apt-get -y -qq upgrade
apt_install \
  ca-certificates curl wget gnupg lsb-release apt-transport-https software-properties-common \
  git rsync unzip zip jq fzf tree htop ncdu bc dnsutils net-tools \
  build-essential pkg-config libssl-dev ufw fail2ban unattended-upgrades \
  logrotate cron acl \
  sudo python3-systemd
# Los dos últimos vienen de salir de Ubuntu, donde los dos llegaban solos:
#   · 'sudo' no está en una Debian mínima —el instalador de Debian lo omite si
#     le das contraseña de root—, y 'orbit' se auto-eleva con él y ejecuta
#     todos los builds con 'sudo -u'. Sin sudo no hay producto, y el fallo
#     aparecería en el primer despliegue y no aquí.
#   · 'python3-systemd' lo necesita el 'backend = systemd' de fail2ban. En
#     Ubuntu es un 'Depends' de fail2ban y en Debian 12 sólo un 'Recommends',
#     así que una imagen instalada sin recomendados se quedaba sin él. Ver el
#     paso 12.
ok "Paquetes base instalados"

step "2/13  Zona horaria, swap y límites del kernel"
timedatectl set-timezone "${ORBIT_TZ:-Europe/Madrid}" 2>/dev/null || true
ok "Zona horaria: %s" "$(timedatectl show -p Timezone --value 2>/dev/null || echo desconocida)"

# Sin tubería a propósito: 'swapon --show | grep -q .' es el patrón que ya
# costó el fallo del núcleo de idiomas —grep -q cierra la tubería al primer
# acierto, swapon muere con SIGPIPE y pipefail se queda con ese 141—, y aquí
# el '!' lo convierte en «no hay swap» justo cuando sí la hay. Lo que sigue
# es un fallocate sobre /swapfile: crear de cero un fichero que puede estar
# montado como swap en ese momento. La salida vacía se comprueba directamente.
if [[ -z "$(swapon --show 2>/dev/null)" ]]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap -q /swapfile >/dev/null
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap de 4 GB creada (builds de Next.js agradecidos)"
else
  # Que haya swap no es que haya suficiente, y la guarda de arriba sólo mira si
  # EXISTE. Este paso está aquí para que un build grande tenga aire —por eso son
  # 4 GB— así que una máquina que ya trae 512 MB de fábrica pasaba por aquí en
  # silencio y se quedaba igual de justa. Es la lección de la guarda de
  # 'python3-venv' otra vez: preguntar si algo está no es preguntar si llega.
  #
  # Lo que NO se hace es tocar lo que el administrador ya montó: esa parte
  # estaba bien. Lo que faltaba era decir cuánto hay, para que quien lo lea
  # pueda decidir.
  _swap_aviso
fi

cat > /etc/sysctl.d/99-orbit.conf <<'EOF'
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
vm.swappiness = 10
fs.file-max = 200000
EOF
sysctl --system >/dev/null 2>&1 || true

cat > /etc/security/limits.d/99-orbit.conf <<'EOF'
*  soft  nofile  65535
*  hard  nofile  65535
EOF
ok "Tuning de kernel aplicado"

# ------------------------------------------------------- 3. deploy user ---
step "3/13  Creando el usuario de despliegue '%s'" "$DEPLOY_USER"
if ! id "$DEPLOY_USER" &>/dev/null; then
  adduser --disabled-password --gecos "Orbit deploy user" "$DEPLOY_USER" >/dev/null
  ok "Usuario '%s' creado (sin contraseña, sólo uso interno)" "$DEPLOY_USER"
else
  info "El usuario '%s' ya existía" "$DEPLOY_USER"
fi
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0750 "/home/$DEPLOY_USER/.ssh"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 0755 "$APPS_DIR"
install -d -m 0755 "$ETC_DIR" "$ETC_DIR/apps" "$ETC_DIR/backups"
install -d -o "$DEPLOY_USER" -g www-data -m 0755 "$ACME_DIR"
install -d -m 0755 /var/log/orbit /var/lib/orbit
# 0700: dentro van los volcados de las bases y los .env de las copias
install -d -m 0700 /var/backups/orbit
install -d -m 0755 "$ETC_DIR/redirects"
chmod 755 /srv
ok "Estructura de directorios lista en %s" "$APPS_DIR"

# --------------------------------------------------------- 4. node --------
step "4/13  Instalando Node.js %s LTS + pnpm" "$NODE_MAJOR"
if ! command -v node >/dev/null || [[ "$(node -v | cut -c2- | cut -d. -f1)" != "$NODE_MAJOR" ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null 2>&1
  apt_install nodejs
fi
corepack enable >/dev/null 2>&1 || npm i -g corepack >/dev/null 2>&1
COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare pnpm@latest --activate >/dev/null 2>&1 || npm i -g pnpm >/dev/null 2>&1
COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare yarn@stable --activate >/dev/null 2>&1 || true
ok "Node %s · npm %s · pnpm %s" "$(node -v)" "$(npm -v)" "$(pnpm -v 2>/dev/null || echo '?')"

# store global pnpm cache in a shared place so builds are fast for the deploy user
sudo -u "$DEPLOY_USER" -H bash -lc 'pnpm config set store-dir ~/.pnpm-store >/dev/null 2>&1' || true

# --------------------------------------------------------- 5. nginx -------
step "5/13  Instalando y endureciendo nginx"
apt_install nginx
rm -f /etc/nginx/sites-enabled/default
install -d -m 0755 /etc/nginx/snippets

# Ubuntu ya define gzip/access_log/types_hash/ssl_protocols en nginx.conf:
# los ajustamos ahí para no duplicar directivas (nginx aborta si se repiten).
sed -i \
  -e 's|^\s*ssl_protocols .*|\tssl_protocols TLSv1.2 TLSv1.3;|' \
  -e 's|^\s*ssl_prefer_server_ciphers .*|\tssl_prefer_server_ciphers off;|' \
  /etc/nginx/nginx.conf

cat > /etc/nginx/conf.d/00-orbit-base.conf <<'EOF'
# --- ORBIT base tuning ---------------------------------------------------
server_tokens off;
client_max_body_size 128m;
client_body_timeout 30s;

gzip_vary on;
gzip_comp_level 6;
gzip_min_length 512;
gzip_proxied any;
gzip_types text/plain text/css text/xml text/javascript application/javascript
           application/json application/xml application/rss+xml application/wasm
           image/svg+xml font/woff font/woff2 application/manifest+json;

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

limit_req_zone $binary_remote_addr zone=orbit_general:10m rate=40r/s;
limit_conn_zone $binary_remote_addr zone=orbit_conn:10m;

# La marca de tiempo va primero y entre corchetes: sin ella una línea de log no
# se puede situar, y 'orbit logs --since' no tendría nada que mirar.
log_format orbit '[$time_local] $remote_addr - $host "$request" $status $body_bytes_sent '
                 '"$http_referer" "$http_user_agent" rt=$request_time';

# TLS compartido (a nivel http para no repetir zonas en cada vhost)
ssl_session_timeout 1d;
ssl_session_cache shared:OrbitSSL:20m;
ssl_session_tickets off;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
EOF

cat > /etc/nginx/snippets/orbit-security.conf <<'EOF'
add_header X-Content-Type-Options    "nosniff" always;
add_header X-Frame-Options           "SAMEORIGIN" always;
add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
add_header Permissions-Policy        "geolocation=(), microphone=(), camera=(), interest-cohort=()" always;
add_header Cross-Origin-Opener-Policy "same-origin-allow-popups" always;

location = /favicon.ico { access_log off; log_not_found off; }
location = /robots.txt  { access_log off; log_not_found off; }
location ~ /\.(?!well-known) { deny all; access_log off; log_not_found off; }
location ~* \.(env|log|sql|sqlite|bak|old|swp|ini|yml|yaml|toml)$ { deny all; }
location ^~ /.git/ { deny all; }
EOF

cat > /etc/nginx/snippets/orbit-ssl.conf <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_stapling on;
ssl_stapling_verify on;
EOF

cat > /etc/nginx/snippets/orbit-acme.conf <<EOF
location ^~ /.well-known/acme-challenge/ {
    root $ACME_DIR;
    default_type "text/plain";
    allow all;
}
EOF

# El servidor por defecto —el que contesta a los nombres que no sirve nadie— lo
# escribe 'orbit nginx-rebuild' al final del instalador, y no aquí. Definirlo en
# dos sitios es cómo acaban divergiendo: éste se quedó sin el bloque de 443
# durante meses, y sin él una petición HTTPS con un nombre desconocido caía en
# el primer vhost con certificado y enseñaba la web de otro. Hasta entonces no
# hay ningún server block, así que nginx no sirve nada, que es lo correcto.
ok "nginx configurado (gzip, cabeceras de seguridad, TLS compartido)"

# ------------------------------------------------- 6. cloudflare real ip --
step "6/13  Restaurando IPs reales de Cloudflare"
CF_SNIPPET=/etc/nginx/snippets/orbit-cloudflare.conf
{
  echo "# Generado por Orbit el $(date -Iseconds)"
  if curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null | grep -E '^[0-9]' | sed 's/^/set_real_ip_from /; s/$/;/'; then :; fi
  if curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null | grep -E '^[0-9a-fA-F:]' | sed 's/^/set_real_ip_from /; s/$/;/'; then :; fi
  echo "real_ip_header CF-Connecting-IP;"
  echo "real_ip_recursive on;"
} > "$CF_SNIPPET"
if [[ $(grep -c set_real_ip_from "$CF_SNIPPET") -lt 5 ]]; then
  warn "No pude descargar los rangos de Cloudflare; se aplicará la lista incluida"
  cat > "$CF_SNIPPET" <<'EOF'
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
EOF
fi
echo "include /etc/nginx/snippets/orbit-cloudflare.conf;" > /etc/nginx/conf.d/01-orbit-cloudflare.conf
ok "%s rangos de Cloudflare cargados" "$(grep -c set_real_ip_from "$CF_SNIPPET")"

# ----------------------------------------------------- 7. postgresql ------
step "7/13  Instalando PostgreSQL"
apt_install postgresql postgresql-contrib
systemctl enable --now postgresql >/dev/null 2>&1 || true
ok "PostgreSQL %s escuchando sólo en localhost" "$(sudo -u postgres psql -tAc 'SHOW server_version;' 2>/dev/null | cut -d' ' -f1 || echo '?')"

# -------------------------------------------------------- 8. php ---------
# Qué PHP sirve esta distribución, preguntándoselo a apt en vez de saberlo.
#
# Estaba escrito 'PHP_VER=8.3' porque es lo que trae Ubuntu 24.04, y ése es el
# único motivo por el que el instalador no valía para Debian 12, que trae 8.2:
# doce 'php8.3-*' que allí no existen, o sea el paso entero al suelo. Un número
# más en una tabla de distribuciones habría arreglado hoy y caducado en la
# siguiente; el metapaquete 'php-fpm' ya declara cuál es la de cada sistema y
# no hay que mantenerlo:
#
#   Ubuntu 24.04   php-fpm 2:8.3+93ubuntu2   Depends: php8.3-fpm
#   Debian 12      php-fpm 2:8.2+93          Depends: php8.2-fpm
#
# Un PHP_VER puesto en el entorno gana, que es como se instala una versión de
# un repositorio de terceros (Sury) sin tocar el script. Y si apt no contesta
# —sin metadatos, o sin ese metapaquete— se sigue con el valor de cabecera en
# vez de abortar: es un paso más del instalador, y quien lo lea verá qué
# versión se ha elegido en la línea del 'step'.
#
# El '|| true' no es decoración, y costó comprobarlo: 'apt-cache show' de un
# paquete que no existe sale con 100 —medido—, y bajo pipefail la asignación
# hereda ese 100. Con errexit, eso mata el instalador entero en el paso 8, sin
# un mensaje, en cualquier sistema que no tenga el metapaquete 'php-fpm'.
#
# Y lo que hace falta saber es POR QUÉ no salta hoy, porque es la clase de
# trampa que reaparece. Comprobado ejecutándolo en bash 5.2.21:
#
#   f                    # llamada directa      -> muere, rc=100
#   _v="$(f)"            # capturada            -> sobrevive
#
# O sea que la función es letal o inofensiva **según cómo la llame quien la
# llame**, y aquí se la llama de la forma que sobrevive. Eso no es estar bien:
# es estar a una línea de distancia de un instalador que muere en silencio, y
# la prueba que la ejerza capturándola nunca lo vería. Con '|| true' da igual
# quién la llame. (De paso: 'local d="$(…)"' en una sola línea tampoco falla
# nunca, porque el estado que se mira es el de 'local'.)
_php_ver_del_sistema() {
  local dep
  dep="$(apt-cache show php-fpm 2>/dev/null \
         | sed -n 's/^Depends:.*php\([0-9]\+\.[0-9]\+\)-fpm.*/\1/p' | head -1)" || true
  [[ -n "$dep" ]] && printf '%s' "$dep"
  return 0
}
if [[ -z "${PHP_VER_FIJADO:-}" ]]; then
  _v="$(_php_ver_del_sistema)"
  [[ -n "$_v" ]] && PHP_VER="$_v"
  unset _v
fi
step "8/13  Instalando PHP %s (FPM) + Composer" "$PHP_VER"
apt_install \
  php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-common php${PHP_VER}-opcache \
  php${PHP_VER}-pgsql php${PHP_VER}-mysql php${PHP_VER}-mbstring php${PHP_VER}-xml \
  php${PHP_VER}-curl php${PHP_VER}-zip php${PHP_VER}-gd php${PHP_VER}-intl php${PHP_VER}-bcmath \
  composer

cat > /etc/php/${PHP_VER}/fpm/pool.d/orbit.conf <<EOF
[orbit]
user = $DEPLOY_USER
group = $DEPLOY_USER
listen = /run/php/orbit.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 20
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 6
pm.max_requests = 500
php_admin_value[expose_php] = off
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[memory_limit] = 256M
php_admin_flag[log_errors] = on
EOF
systemctl enable --now php${PHP_VER}-fpm >/dev/null 2>&1 || true
systemctl restart php${PHP_VER}-fpm
ok "PHP %s con pool 'orbit' en /run/php/orbit.sock" "$(php -r 'echo PHP_VERSION;')"

# ------------------------------------------------------- 9. python -------
step "9/13  Instalando Python + herramientas"
apt_install python3 python3-venv python3-pip python3-dev pipx
ok "Python %s listo (cada app usa su propio venv)" "$(python3 -V | cut -d' ' -f2)"

# ------------------------------------------------------ 10. certbot ------
step "10/13  Instalando Certbot (Let's Encrypt)"
apt_install certbot python3-certbot-dns-cloudflare
systemctl enable certbot.timer >/dev/null 2>&1 || true
install -d -m 0750 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/orbit-reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/orbit-reload-nginx.sh
ok "Certbot instalado, renovación automática activada"

# --------------------------------------------------- 11. github cli ------
step "11/13  Instalando GitHub CLI"
if ! command -v gh >/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt_install gh
fi
ok "GitHub CLI %s" "$(gh --version | head -1 | awk '{print $3}')"

# ------------------------------------------------- 12. firewall/hardening -
step "12/13  Firewall, fail2ban y actualizaciones automáticas"
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Las reglas de SSH van ANTES de encender, y el orden no es casual: entre el
# 'default deny' y el 'enable' no puede haber nada que falle, porque cualquier
# cosa que corte ahí deja el cortafuegos a medio configurar.
_ssh_p="$(_ssh_puertos)"
if [[ -n "$_ssh_p" ]]; then
  for _p in $_ssh_p; do
    ufw allow "${_p}/tcp" comment 'SSH' >/dev/null
  done
else
  # Ninguna de las cuatro fuentes ve un SSH: ni el entorno de esta sesión, ni
  # un socket escuchando, ni sshd, ni un sshd_config. O sea que no hay servidor
  # SSH instalado y nadie puede estar entrando por ahí — encender el
  # cortafuegos es seguro. Abrir el 22 «por si acaso» sería abrir un puerto
  # donde no atiende nadie, que es justo lo que el paso 12 viene a evitar.
  #
  # Se dice igual, porque un cortafuegos que se levanta sin regla de SSH es
  # exactamente lo que hay que saber antes de que pase, no después.
  warn "No hay ningún servidor SSH en esta máquina."
  info "El cortafuegos se activa sin regla para SSH. Si instalas uno después,"
  info "ábrele el puerto:  sudo ufw allow <puerto>/tcp"
fi

ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw --force enable >/dev/null
if [[ -n "$_ssh_p" ]]; then
  ok "UFW activo: SSH en %s, más 80 y 443" "$_ssh_p"
else
  ok "UFW activo: sólo 80 y 443"
fi

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
destemail = root@localhost

[sshd]
enabled = true
maxretry = 4
bantime = 4h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban || true
# Y se comprueba que de verdad esté vigilando, en vez de anunciarlo.
#
# 'backend = systemd' —el de arriba, y el correcto en una máquina cuyo sshd
# escribe en el journal y no en /var/log/auth.log— necesita el módulo
# python3-systemd. En Ubuntu llega solo, porque su fail2ban lo lleva en
# 'Depends'; en Debian 12 es un 'Recommends', así que una imagen instalada con
# '--no-install-recommends' —lo normal en las de nube— se queda sin él y
# fail2ban no arranca. Los dos 'systemctl' de arriba llevan '|| true' a
# propósito, para no tumbar la instalación entera por esto, y el efecto era
# que el instalador imprimía «vigilando SSH» sobre un servicio muerto: la
# misma mentira que costó el arreglo de 'notify test' en la v1.2.7. El
# paquete va explícito unas líneas más arriba; esto es el segundo cinturón,
# porque lo que importa no es haberlo instalado sino que el servicio esté en
# pie.
if systemctl is-active --quiet fail2ban 2>/dev/null; then
  ok "fail2ban vigilando SSH"
else
  warn "fail2ban no ha arrancado, así que SSH no está vigilado."
  info "Mira el motivo con:  systemctl status fail2ban  y  journalctl -u fail2ban -n 30"
fi

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "Parches de seguridad automáticos activados"

cat > /etc/logrotate.d/orbit <<'EOF'
/var/log/orbit/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF

# ---------------------------------------------------- 13. orbit CLI ------
step "13/13  Instalando la herramienta 'orbit'"
install -m 0755 "$SCRIPT_DIR/orbit" /usr/local/bin/orbit
ln -sfn /usr/local/bin/orbit /usr/local/bin/dv

if [[ ! -f "$ETC_DIR/orbit.conf" ]]; then
  cat > "$ETC_DIR/orbit.conf" <<EOF
# Configuración global de Orbit
DEPLOY_USER="$DEPLOY_USER"
APPS_DIR="$APPS_DIR"
ACME_DIR="$ACME_DIR"
PHP_VER="$PHP_VER"
LETSENCRYPT_EMAIL=""
PORT_BASE="3001"
KEEP_RELEASES="5"

# Reinicio sin corte al desplegar: la release nueva arranca en un puerto libre
# y el tráfico sólo se mueve cuando responde. Ponlo en "no" si una app lee el
# puerto de su propio .env en vez de la variable PORT que le pasa la unidad.
DEPLOY_OVERLAP="yes"

# Aislamiento por app: cada app con proceso nueva nace con su propio usuario
# de sistema, y así una app comprometida no puede leer el .env de otra. Las
# anteriores se migran con 'orbit isolate <app>'. "no" lo apaga para las que
# se creen después.
APP_ISOLATION="yes"

# El idioma en el que habla Orbit. Vacío significa «el del sistema»: se mira
# LANG y compañía, y si no dicen nada —un temporizador de systemd, una línea de
# cron— /etc/default/locale. Ponerlo aquí fija el idioma de este servidor para
# todo el mundo, incluidos los avisos que salen solos; quien quiera leerlo en
# otro tiene 'orbit --lang <código> <comando>' y ORBIT_LANG en su entorno.
# Se cambia también con 'orbit lang <código>'.
ORBIT_LANG=""

# Umbrales del vigilante (orbit watch)
WATCH_DISK_MAX="90"     # % de disco a partir del cual avisar
WATCH_MEM_MIN="10"      # % de memoria disponible por debajo del cual avisar
WATCH_CERT_DAYS="10"    # días de margen antes de que caduque un certificado
WATCH_MAX_TRIES="3"     # reinicios seguidos antes de rendirse y avisar
WATCH_WINDOW="600"      # ventana en segundos en la que se cuentan esos reinicios

# Despliegue automático (orbit autodeploy)
AUTODEPLOY_EVERY="1"    # cada cuántos minutos se mira si la rama ha avanzado

# Colas de Laravel (orbit queue)
QUEUE_EVERY="1"         # cada cuántos minutos se vacía la cola de quien lo pida
EOF
  chmod 0640 "$ETC_DIR/orbit.conf"
else
  # Las instalaciones anteriores guardaban ORBIT_VERSION en el conf, y como el
  # conf sólo se escribe la primera vez, tras actualizar 'orbit --version'
  # seguía anunciando la versión con la que se instaló. Ahora la versión la
  # dice el propio script; la clave heredada se retira para que un 'cat' del
  # conf no cuente otra historia.
  sed -i '/^ORBIT_VERSION=/d' "$ETC_DIR/orbit.conf"
fi

# Plantilla de avisos. Puede contener tokens, así que nace con permisos 0600.
if [[ ! -f "$ETC_DIR/notify.conf" ]]; then
  cat > "$ETC_DIR/notify.conf" <<'EOF'
# Avisos de Orbit. Rellénalo con "orbit notify setup".
# El correo no está: un VPS limpio no puede enviarlo y falla en silencio.
NOTIFY_MIN_LEVEL='warn'
NOTIFY_TELEGRAM_TOKEN=''
NOTIFY_TELEGRAM_CHAT=''
NOTIFY_DISCORD=''
NOTIFY_WEBHOOK=''
EOF
  chmod 0600 "$ETC_DIR/notify.conf"
fi

# sudo sin contraseña para el usuario deploy en las tareas que necesita
cat > /etc/sudoers.d/orbit <<EOF
$DEPLOY_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart orbit-*, /usr/bin/systemctl reload nginx
EOF
chmod 0440 /etc/sudoers.d/orbit

# backup diario de bases de datos
cat > /etc/cron.d/orbit-db-backup <<'EOF'
30 4 * * * root /usr/local/bin/orbit db backup-all >/var/log/orbit/db-backup.log 2>&1
EOF

# Ahora que 'orbit' y su configuración existen, que escriba él lo que es suyo:
# el servidor por defecto para 80 y 443. Una sola definición, la del script.
orbit nginx-rebuild >/dev/null 2>&1 || warn "No he podido generar el servidor por defecto; ejecuta 'orbit nginx-rebuild'"

nginx -t >/dev/null 2>&1 && systemctl reload nginx || { nginx -t; die "nginx no valida la configuración"; }
systemctl enable --now nginx >/dev/null 2>&1 || true
ok "Comandos disponibles: {b}orbit{r}  (y el atajo {b}dv{r})"

# ------------------------------------------------------------- resumen ---
IP4=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

# El resumen final va entero por idioma y no frase a frase, igual que la ayuda
# de 'orbit' (ver ARCHITECTURE §21.7): es una pantalla con una caja dibujada y
# dos columnas alineadas a mano, y traducirla por trozos la desalinearía sin
# que nadie lo viera hasta ejecutarla.
_resumen_es() {
cat <<EOF

${GRN}${B}  ╭──────────────────────────────────────────────────────────────╮
  │  INSTALACIÓN COMPLETADA                                      │
  ╰──────────────────────────────────────────────────────────────╯${R}

  ${B}Servidor${R}      $(hostname -f 2>/dev/null || hostname)   ${D}(${IP4})${R}
  ${B}Web server${R}    nginx $(nginx -v 2>&1 | grep -o '[0-9.]*')
  ${B}Runtime${R}       Node $(node -v) · pnpm $(pnpm -v 2>/dev/null) · PHP $(php -r 'echo PHP_VERSION;') · Python $(python3 -V | cut -d' ' -f2)
  ${B}Base de datos${R} PostgreSQL (localhost)
  ${B}Apps${R}          $APPS_DIR
  ${B}Config${R}        $ETC_DIR

  ${CYA}${B}Siguientes pasos${R}

    ${B}1.${R} Conecta tu cuenta de GitHub:   ${B}orbit github${R}
    ${B}2.${R} Guarda tu token de Cloudflare: ${B}orbit cf-token${R}
    ${B}3.${R} Despliega tu primera web:      ${B}orbit new${R}
    ${B}4.${R} Activa los avisos y la vigilancia:
       ${B}orbit notify setup${R} y ${B}orbit watch enable${R}
       o abre el menú interactivo:        ${B}orbit${R}

  ${D}En Cloudflare, cada dominio debe tener un registro A → ${IP4}
  y el modo SSL/TLS en "Full (strict)".${R}

EOF
}

_resumen_en() {
cat <<EOF

${GRN}${B}  ╭──────────────────────────────────────────────────────────────╮
  │  INSTALL COMPLETE                                            │
  ╰──────────────────────────────────────────────────────────────╯${R}

  ${B}Server${R}        $(hostname -f 2>/dev/null || hostname)   ${D}(${IP4})${R}
  ${B}Web server${R}    nginx $(nginx -v 2>&1 | grep -o '[0-9.]*')
  ${B}Runtime${R}       Node $(node -v) · pnpm $(pnpm -v 2>/dev/null) · PHP $(php -r 'echo PHP_VERSION;') · Python $(python3 -V | cut -d' ' -f2)
  ${B}Database${R}      PostgreSQL (localhost)
  ${B}Apps${R}          $APPS_DIR
  ${B}Config${R}        $ETC_DIR

  ${CYA}${B}Next steps${R}

    ${B}1.${R} Connect your GitHub account:  ${B}orbit github${R}
    ${B}2.${R} Store your Cloudflare token:  ${B}orbit cf-token${R}
    ${B}3.${R} Deploy your first site:       ${B}orbit new${R}
    ${B}4.${R} Turn on notifications and watching:
       ${B}orbit notify setup${R} and ${B}orbit watch enable${R}
       or open the interactive menu:      ${B}orbit${R}

  ${D}In Cloudflare, every domain needs an A record → ${IP4}
  and the SSL/TLS mode set to "Full (strict)".${R}

EOF
}

case "$ORBIT_LANG_CODE" in
  en) _resumen_en ;;
  *)  _resumen_es ;;
esac
