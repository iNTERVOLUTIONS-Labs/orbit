#!/usr/bin/env bash
# Pruebas de las funciones internas de orbit: conteo de apps y puertos.
#   bash tests/unit_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, PORT_BASE,
# KEEP_RELEASES…) que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Sustituimos 'ss' por una función vacía: si dependiéramos de lo que esté
# escuchando en la máquina de pruebas, el resultado no sería reproducible.
ss() { :; }

section "Conteo de aplicaciones"
# Regresión: banner() contaba con `ls "$APPS_CONF"/*.conf | wc -l`. Con
# nullglob y cero apps, ls se queda sin argumentos y lista el directorio
# actual, así que un servidor recién instalado decía tener 8 apps.
mkdir -p "$TMP/ruido" && touch "$TMP/ruido"/{a,b,c,d,e,f,g,h}
check "sin apps desde otro dir" "0" "$(cd "$TMP/ruido" && app_count)"

mkapp web1 node 3001
mkapp web2 node 3002
check "dos apps"                "2" "$(app_count)"
check "dos apps desde otro dir" "2" "$(cd "$TMP/ruido" && app_count)"

section "Puertos internos"
# Regresión: save_app serializa con _q(), que emite comillas simples
# (A_PORT='3001'), pero free_port buscaba ^A_PORT="3001" con comillas dobles.
# El grep no coincidía nunca y Orbit repartía a una app nueva un puerto que ya
# tenía otra: la segunda unidad muere con EADDRINUSE en bucle de reinicio.
check "puertos reservados" "3001 3002" "$(used_ports | sort | tr '\n' ' ' | sed 's/ $//')"
check "primer puerto libre" "3003" "$(free_port)"

# Al reasignar el puerto de una app, el suyo propio no cuenta como ocupado.
check "excluyendo la propia app" "3001" "$(free_port web1)"

# Un fichero editado a mano puede no llevar comillas: hay que aceptarlo igual.
mkapp web3 node 3003
sed -i "s/^A_PORT=.*/A_PORT=3003/" "$(app_conf web3)"
check "conf sin comillas" "3004" "$(free_port)"

# PORT_BASE se respeta aunque los puertos bajos estén libres. La asignación va
# dentro de la sustitución (subshell) para no alterar el resto de las pruebas.
check "respeta PORT_BASE" "4000" "$(PORT_BASE=4000; free_port)"

section "Detección de conflictos"
_port_taken_by_other web2 3001 && r=si || r=no
check "3001 lo tiene web1" "si" "$r"
_port_taken_by_other web1 3001 && r=si || r=no
check "web1 no choca consigo" "no" "$r"
_port_taken_by_other web1 3999 && r=si || r=no
check "3999 libre" "no" "$r"

# Con el servicio de la app en marcha, quien escucha en SU puerto es ella misma
# y no es conflicto. Pero eso no puede extenderse a cualquier otro puerto: con
# la app viva, 'orbit port web1 5432' se llevaría por delante a PostgreSQL.
systemctl() { return 0; }                       # el servicio de la app, activo
ss() { printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n' 3001 4321; }
_port_taken_by_other web1 3001 && r=si || r=no
check "su propio puerto no cuenta" "no" "$r"
_port_taken_by_other web1 4321 && r=si || r=no
check "el de otro proceso sí"      "si" "$r"
# 'ss' se REPONE, no se quita: un 'unset -f' aquí devolvía el 'ss' de verdad al
# resto del fichero y con él los puertos de la máquina, que es justo lo que el
# doble de arriba existe para evitar. Se notaba sólo en un servidor con apps
# de Orbit funcionando, y cambiando de sección según cuántas hubiera: con una
# en el 3001 caía 'orbit port', y al aparecer dos más en el 3004 y el 3005
# empezó a caer también 'web4 recibe 3004'. La regla es del fichero entero.
unset -f systemctl; ss() { :; }

section "Un 'ss' que no cabe en la tubería sigue diciendo la verdad"
# La versión anterior preguntaba 'ss -ltn | grep -q ":$p "' una vez por puerto
# candidato, y ese patrón está en la lista negra de docs/DEVELOPMENT.md por un motivo:
# grep -q sale corriendo en cuanto acierta, ss recibe un SIGPIPE y muere con
# 141, y pipefail se queda con ese 141 — la condición se vuelve falsa AUNQUE
# el puerto esté ocupado. No saltaba porque la salida de ss cabe de sobra en
# el buffer de la tubería; con más de mil sockets a la escucha, no.
#
# El doble reproduce justo eso. El puerto es el 3004 y no uno de los que ya
# tiene una app: si lo tuviera, 'used_ports' lo descartaría antes de mirar a
# 'ss' y la prueba pasaría en verde sin ejercitar nada — pasó al escribirla.
# Aparece en la PRIMERA línea, seguido de mucho ruido, que es lo que llena el
# buffer. Antes free_port entregaba el 3004 y la unidad nueva moría con
# EADDRINUSE en bucle de reinicio.
ss() {
  printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
  printf 'LISTEN 0 128 127.0.0.1:3004 0.0.0.0:*\n'
  local i; for ((i=0; i<40000; i++)); do printf 'LISTEN 0 128 10.0.0.1:%s 0.0.0.0:*\n' "$((20000+i%40000))"; done
}
check "se salta el puerto ocupado" "3005" "$(free_port)"
_port_taken_by_other web1 3004 && r=si || r=no
check "y el conflicto se ve"       "si"   "$r"
# IPv6 tiene sus propios dos puntos en la dirección: el puerto es lo que sigue
# a los ÚLTIMOS, o '[::]:3004' se leería como ':3004' y no casaría con nada.
ss() { printf 'State Recv-Q Send-Q Local Address:Port\nLISTEN 0 128 [::]:3004 [::]:*\n'; }
_port_taken_by_other web1 3004 && r=si || r=no
check "también escuchando en IPv6" "si"   "$r"
# La cabecera no es un puerto, y sin '-H' siempre viene.
ss() { printf 'State Recv-Q Send-Q Local Address:Port\n'; }
_port_taken_by_other web1 3004 && r=si || r=no
check "la cabecera no ocupa nada"  "no"   "$r"
ss() { :; }

section "Ningún awk usa expresiones de intervalo"
# El awk de Debian 12 no entiende '{40}', y esto costó el autodespliegue entero.
#
# Debian 12 trae mawk 1.3.4 snapshot **20200120**, que trata '{40}' como cuatro
# caracteres literales; Ubuntu 24.04 trae mawk 1.3.4 snapshot **20240123**, que
# sí implementa los intervalos. Mismo número de versión, distinta fecha, y
# 'mawk -W version' es el único sitio donde se ve la diferencia.
#
# Lo que se rompía: '_remote_head' sacaba el SHA con
# `awk '$1 ~ /^[0-9a-f]{40}$/'`, así que en Debian NUNCA reconocía la respuesta
# de 'git ls-remote' aunque fuese perfecta. El resultado no es un error visible
# sino el peor de los silencios: Orbit concluye «no he podido preguntar al
# remoto» en cada pasada, y **el autodespliegue deja de desplegar sin que nadie
# se entere** — que es exactamente el fallo que el código de al lado se escribió
# para evitar (ver «Sin cambios» y «no he podido preguntar» en autodeploy_test).
#
# Ninguna prueba podía verlo: el runner de Ubuntu trae gawk, y el mawk de
# Ubuntu es el nuevo. Lo encontró el trabajo de CI en Debian.
#
# Se comprueba la CLASE entera y no esa línea, que es la lección de los glifos
# de la v1.2.8: la siguiente se escribirá en otro comando.
# Las líneas de comentario se descartan: el arreglo lleva al lado el ejemplo de
# lo que NO hay que escribir, y una prueba que prohíba documentar la trampa
# acaba borrando el motivo. La salida de 'grep -n' es 'fichero:línea:texto', así
# que se filtra por el texto que empieza en almohadilla. Un comentario al final
# de una línea de código sigue contando, que es lo que se quiere.
_awk_intervalos="$(grep -nE "awk.*\{[0-9]+(,[0-9]*)?\}" "$ORBIT_ROOT/orbit" "$ORBIT_ROOT/install.sh" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
check "ninguno en orbit ni en install.sh" "" "$_awk_intervalos"

section "Nadie escribe a mano las rutas de nginx"
# Lo que costó tenerlas escritas a pelo: 'isolate_test' termina con un
# 'cmd_remove tienda', y 'cmd_remove' borraba el vhost por su ruta absoluta.
# Lanzada la tanda **como root** en un servidor de pruebas que tenía una app
# llamada 'tienda', la suite borró el vhost de la app de verdad. Sin un error,
# con las 32 suites en verde, y dejando una web registrada, compilada, con su
# pool de php-fpm y su unidad vivos, a la que ya no atendía nadie: el visitante
# recibía la conexión cerrada del servidor por defecto. Se supo una hora
# después, en la comprobación del reinicio.
#
# El arnés ya redirigía systemd, /etc/php y las altas de usuarios por este
# mismo motivo —está escrito en la cabecera de tests/lib.sh— y nginx era el
# único directorio que se había quedado fuera, porque el enlace de
# sites-enabled estaba repetido a mano en cinco sitios y no había forma de
# desviarlo.
#
# Se comprueba la CLASE y no aquellas cinco líneas: la sexta la escribe alguien
# dentro de seis meses. Las únicas dos apariciones permitidas son las que
# definen las variables; todo lo demás pasa por 'nginx_file' y 'nginx_link'.
# Los comentarios se descartan, que es la lección de la comprobación de los
# awk de aquí arriba: una prueba que prohíba documentar la trampa acaba
# borrando el motivo.
_ngx_apelo="$(grep -nE "/etc/nginx/sites-(available|enabled)" "$ORBIT_ROOT/orbit" \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE '^[0-9]+:NGINX_(AVAILABLE|ENABLED)=' || true)"
check "ninguna ruta a pelo en orbit" "" "$_ngx_apelo"
# Y que la redirección del arnés llegue de verdad a las dos funciones: si
# alguien reintroduce la ruta dentro de 'nginx_file', esto lo caza aquí y no
# en el servidor de otro.
check "nginx_file cae en el árbol de pruebas" "1" \
  "$(grep -c "^$TMP/" <<<"$(nginx_file cualquiera)")"
check "nginx_link también"                    "1" \
  "$(grep -c "^$TMP/" <<<"$(nginx_link cualquiera)")"

section "Puerto asignado a una app nueva"
# free_port debe seguir siendo correcto según crecen las apps registradas.
mkapp web4 node "$(free_port)"
load_app web4
check "web4 recibe 3004" "3004" "$A_PORT"
check "sin duplicados" "" "$(used_ports | sort | uniq -d | tr '\n' ' ' | sed 's/ $//')"

section "orbit port"
# Se anulan las piezas que tocarían el sistema; lo que se prueba aquí es la
# lógica de decisión, no systemd ni nginx (eso lo cubre nginx_test.sh).
need_root()      { :; }
render_systemd() { :; }
render_nginx()   { return 0; }
systemctl()      { return 1; }   # ningún servicio activo
health_wait()    { return 0; }
# El doble de 'ss' viene ya de arriba, repuesto tras la sección que lo
# sustituye: sin él, 'free_port' y '_port_taken_by_other' miran los puertos de
# la MÁQUINA y estas comprobaciones se ponen en rojo acusando a código sano.
LOG_FILE="$TMP/orbit.log"

run cmd_port web1 >/dev/null 2>&1
load_app web1
check "sin conflicto no mueve" "3001" "$A_PORT"

run cmd_port web1 3002 >/dev/null 2>&1; r=$?
check "rechaza puerto de otra" "1" "$r"
load_app web1
check "y lo deja como estaba" "3001" "$A_PORT"

run cmd_port web1 "no-es-un-numero" >/dev/null 2>&1; r=$?
check "rechaza basura" "1" "$r"
run cmd_port web1 80 >/dev/null 2>&1; r=$?
check "rechaza puerto reservado" "1" "$r"
run cmd_port web1 99999 >/dev/null 2>&1; r=$?
check "rechaza fuera de rango" "1" "$r"

run cmd_port web1 4100 >/dev/null 2>&1
load_app web1
check "acepta puerto libre" "4100" "$A_PORT"

# Si nginx rechaza la configuración hay que dejarlo todo como estaba.
render_nginx() { return 1; }
run cmd_port web1 4200 >/dev/null 2>&1; r=$?
check "aborta si nginx falla" "1" "$r"
load_app web1
check "y revierte el puerto" "4100" "$A_PORT"
render_nginx() { return 0; }

section "Autorreparación de un duplicado"
# Situación que dejaba el free_port roto: dos apps con el mismo puerto.
sed -i "s/^A_PORT=.*/A_PORT='3003'/" "$(app_conf web1)"
check "doctor lo ve" "3003" "$(used_ports | sort | uniq -d)"
run cmd_port web1 >/dev/null 2>&1
load_app web1
check "mueve la app" "3001" "$A_PORT"
check "ya no hay duplicados" "" "$(used_ports | sort | uniq -d)"

section "Las herramientas se comprueban como el usuario que compila"
# El fallo que motiva esto: los instaladores de bun y de deno dejan el binario
# en el HOME de quien los ejecuta —normalmente root— y luego se enlaza a
# /usr/local/bin. Con /root en modo 700, 'command -v' desde root dice que sí y
# todos los builds mueren con 'command not found'. Medido en el contenedor de
# desarrollo con bunx: root lo encuentra, cualquier otro usuario no.
if command -v sudo >/dev/null; then
  run _deploy_tiene sh;            check "una que existe"    "0" "$?"
  run _deploy_tiene noexistoseguro; check "una que no"       "1" "$?"
  # La versión sale por stdout y en una línea: es lo que va al diagnóstico.
  check "y da la versión" "1" "$([[ -n "$(_deploy_version bash 2>/dev/null)" ]] && echo 1 || echo 0)"
  # Y la versión no repite el nombre: 'deno --version' devuelve «deno 2.9.5
  # (stable, …)» y 'bun --version' sólo «1.3.11». Sin recortar, el diagnóstico
  # escribía «deno deno 2.9.5 (stable, …)».
  check "sin repetir el nombre" "0" "$(_deploy_version bash 2>/dev/null | grep -c '^bash ')"
  # El build y el servicio no ven lo mismo: el build va por 'bash -lc', que lee
  # los perfiles de login, y la unidad lleva un PATH fijo. Una herramienta
  # instalada en el HOME del usuario compila y luego el servicio muere con 127.
  run _unidad_tiene sh;             check "en el PATH del servicio" "0" "$?"
  run _unidad_tiene noexistoseguro; check "y si no, se nota"        "1" "$?"
else
  echo "  (sin sudo: me salto la comprobación como el usuario de despliegue)"
fi

report
