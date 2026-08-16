#!/usr/bin/env bash
# Pruebas de la capa visual: color, ancho, rótulos y animaciones.
#   bash tests/ui_test.sh
#
# Lo que se comprueba aquí no es que quede bonito —eso no lo sabe una prueba—
# sino que la decoración **no se cuele donde no debe** y que las trampas que ya
# han costado bugs (bytes contra caracteres, leer de stdin, \r sin terminal)
# sigan cerradas.
#
# shellcheck disable=SC2034  # asigna variables A_* que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# El bloque de color se evalúa al cargar el script, así que para probarlo hay
# que volver a cargarlo con otro entorno. $TMP/orbitlib.sh lo deja lib.sh.
con_entorno() { # con_entorno <VAR=valor…> -- <expresión que imprime algo>
  local -a envs=()
  while [[ "${1:-}" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env "${envs[@]}" bash -c "source '$TMP/orbitlib.sh' >/dev/null 2>&1; $1" 2>/dev/null
}

section "Cuándo se pinta y cuándo no"
# Sin terminal no hay color: los escapes acabarían dentro del fichero de quien
# redirige la salida.
check "sin terminal, sin color" "0" \
  "$(con_entorno TERM=xterm -- 'printf "%s" "${#R}"')"
# NO_COLOR es una convención (no-color.org) que respetan curl, ripgrep y
# systemd. Vale con que esté puesta, aunque sea vacía.
check "NO_COLOR vacía manda"    "0" \
  "$(con_entorno TERM=xterm NO_COLOR= -- 'printf "%s" "${#R}"')"
check "NO_COLOR con valor"      "0" \
  "$(con_entorno TERM=xterm NO_COLOR=1 -- 'printf "%s" "${#R}"')"
check "TERM=dumb tampoco"       "0" \
  "$(con_entorno TERM=dumb -- 'printf "%s" "${#R}"')"

section "Ancho de la interfaz"
check "por defecto"      "66" "$(con_entorno TERM=xterm -- 'printf "%s" "$UI_WIDTH"')"
check "se acota abajo"   "40" "$(con_entorno TERM=xterm COLUMNS=12  -- 'printf "%s" "$UI_WIDTH"')"
check "y arriba"        "100" "$(con_entorno TERM=xterm COLUMNS=400 -- 'printf "%s" "$UI_WIDTH"')"
check "respeta COLUMNS"  "72" "$(con_entorno TERM=xterm COLUMNS=72  -- 'printf "%s" "$UI_WIDTH"')"
# Un COLUMNS con basura no puede tumbar a orbit ni dar una raya de ancho «».
check "COLUMNS con basura" "66" "$(con_entorno TERM=xterm COLUMNS=ocho -- 'printf "%s" "$UI_WIDTH"')"

section "La raya mide lo que dice"
UI_WIDTH=66
# ${#s} cuenta caracteres sólo con la configuración regional en UTF-8.
n_chars() { local LC_ALL=C.UTF-8 s; s="$(cat)"; s="${s//$'\n'/}"; printf '%s' "${#s}"; }
check "ancho por defecto" "66" "$(hr | n_chars)"
check "ancho explícito"   "20" "$(hr 20 | n_chars)"

section "Los acentos no descuadran los rótulos"
# printf '%-*s' cuenta BYTES: con 'GESTIÓN' e 'INFRAESTRUCTURA' la raya salía
# más corta que en 'DESPLIEGUE' y las tres secciones no acababan a la vez.
# Es la misma trampa que documenta ARCHITECTURE §10.
UI_WIDTH=66; R=""; B=""; CYA=""; GRY=""
a="$(_menu_sec DESPLIEGUE      | n_chars)"
b="$(_menu_sec GESTIÓN         | n_chars)"
c="$(_menu_sec INFRAESTRUCTURA | n_chars)"
check "DESPLIEGUE"      "66" "$a"
check "GESTIÓN, con Ó"  "66" "$b"
check "INFRAESTRUCTURA" "66" "$c"
check "las tres iguales" "1" "$([[ "$a" == "$b" && "$b" == "$c" ]] && echo 1 || echo 0)"

section "La pausa de las animaciones espera de verdad"
# Regresión: la primera versión leía de /dev/null, que da EOF al instante. El
# 'read' volvía sin esperar y el spinner giraba a toda velocidad quemando CPU
# en vez de ahorrarla. Se mide: 10 pausas de 0,05 s son al menos 0,4 s.
t0=$(date +%s%N); for _ in 1 2 3 4 5 6 7 8 9 10; do _nap 0.05; done; t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
check "10 x 50ms esperan" "1" "$([[ "$ms" -ge 400 ]] && echo 1 || echo 0)"
# …y sin pasarse: si durmiera de más, un build parecería más lento de lo que es.
check "y no se pasan"     "1" "$([[ "$ms" -le 1500 ]] && echo 1 || echo 0)"

section "La pausa no se come el teclado"
# _nap leyendo de stdin se tragaba la tecla que el usuario pulsa durante la
# animación, que es su respuesta al menú. La misma trampa que dejaba 'orbit
# status' pintando como servicios las teclas siguientes.
leido="$(printf 'MI-RESPUESTA\n' | { _nap 0.05; read -r x; printf '%s' "$x"; })"
check "stdin intacto" "MI-RESPUESTA" "$leido"

section "Animar exige las tres condiciones"
UI_TTY="no"; R=$'\e[0m'; UI_ANIM="yes"
check "sin terminal, no"  "1" "$(_can_anim; echo $?)"
UI_TTY="yes"; R=""
check "sin color, no"     "1" "$(_can_anim; echo $?)"
UI_TTY="yes"; R=$'\e[0m'; UI_ANIM="no"
check "si se apaga, no"   "1" "$(_can_anim; echo $?)"
UI_TTY="yes"; R=$'\e[0m'; UI_ANIM="yes"
check "con las tres, sí"  "0" "$(_can_anim; echo $?)"

section "El rótulo redirigido no lleva decoración"
# banner() acaba en 'orbit --help | tee' y en informes de fallo pegados en un
# issue. Sin terminal no puede salir ni un escape ni un fotograma.
mkapp web node 3001 web.test
salida="$(con_entorno TERM=xterm -- 'APPS_CONF="'"$TMP/etc/apps"'"; banner')"
check "sin escapes"    "0" "$(printf '%s' "$salida" | grep -c $'\e')"
check "sin retornos"   "0" "$(printf '%s' "$salida" | grep -c $'\r')"
check "dice la versión" "1" "$(printf '%s' "$salida" | grep -c 'deploy platform')"
# El logotipo grande no aparece sin terminal: son seis líneas de adorno en un
# fichero de log.
check "sin logotipo"   "0" "$(printf '%s' "$salida" | grep -c '█')"

section "La espera de salud, redirigida, no se repite"
# Es el momento del que depende que haya rollback, así que su rastro en el log
# del autodespliegue tiene que ser legible. Con '\r' y sin terminal, cada
# segundo dejaría una línea casi igual —la trampa del spinner— y taparía el
# resultado. Sin terminal: puntos, una sola línea, ni un '\r'.
curl() { return 1; }        # el puerto no contesta nunca
salud="$(health_wait 3001 3)"
check "sin retornos"   "0" "$(printf '%s' "$salud" | grep -c $'\r')"
check "sin barra"      "0" "$(printf '%s' "$salud" | grep -c '█')"
check "una sola línea" "1" "$(printf '%s\n' "$salud" | grep -c 'Comprobando salud')"
# Sólo los puntos del final: '127.0.0.1' ya trae tres, y contarlos todos hacía
# que la prueba pasara por el motivo equivocado.
puntos="${salud##*3001 }"
check "un punto por segundo" "3" "${#puntos}"
# Y devuelve fallo, que es lo que dispara el rollback.
health_wait 3001 1 >/dev/null 2>&1; check "agotado es fallo" "1" "$?"
unset -f curl

section "Las ayudas de varias líneas salen en varias líneas"
# 't' imprime con '%s', que **no** interpreta los \n del texto, así que estas
# dos ayudas salían en una sola línea con los «\n» a la vista — desde siempre, y
# en el comando que más se usa. Se arregló en el sitio que imprime, con '%b', y
# no en 't', que la usan setecientos mensajes y ahí un backslash literal
# cambiaría de significado.
need_root() { :; }
ayuda="$( ( cmd_deploy --help ) 2>&1 )"
check "deploy: varias líneas"  "1" "$([[ "$(grep -c . <<<"$ayuda")" -ge 6 ]] && echo 1 || echo 0)"
check "y sin barras a la vista" "0" "$(grep -c '\\n' <<<"$ayuda")"
check "menciona --all"          "1" "$(grep -qc -- 'deploy --all' <<<"$ayuda" && echo 1 || echo 0)"
ayuda="$( ( cmd_remove --help ) 2>&1 )"
check "remove: varias líneas"  "1" "$([[ "$(grep -c . <<<"$ayuda")" -ge 3 ]] && echo 1 || echo 0)"
check "y sin barras"           "0" "$(grep -c '\\n' <<<"$ayuda")"
# El %s de --purge lleva un argumento: si se queda fuera del t(), sale literal.
check "y la ruta sustituida"   "0" "$(grep -c '%s' <<<"$ayuda")"

section "Los símbolos, y por qué no valen todos"
# El fallo que trajo esta tabla: el tic verde salía como un icono de color en
# terminales normales. La causa es que ✔ (U+2714) y ✖ (U+2716) están en
# emoji-data, así que fontconfig se los cede a la fuente de emoji en color —que
# trae su propio verde y ocupa dos columnas— mientras que ✓ (U+2713) y ✗
# (U+2717) no están y los pinta la monoespaciada. La prueba, por tanto, no es
# "hay un tic": es **que no vuelva a colarse ninguno de los dos que son emoji**,
# ni aquí ni en el instalador, que es donde estaban.
check "orbit sin emoji"     "0" "$(grep -c $'✔\|✖' <(grep -v '^#' "$ORBIT_ROOT/orbit"))"
check "install sin emoji"   "0" "$(grep -c $'✔\|✖' <(grep -v '^#' "$ORBIT_ROOT/install.sh"))"
# ⎇ (U+2387) no es emoji, pero casi ninguna monoespaciada lo trae —DejaVu Sans
# Mono, la de la mayoría de los servidores, no— así que era un cuadrado vacío.
check "sin la tecla alt"    "0" "$(grep -c $'⎇' <(grep -v '^#' "$ORBIT_ROOT/orbit"))"

# Y el otro modo de fallo de una tabla: usar un nombre que no está en ella. Con
# 'set -u' eso no sale feo, MATA — le pasó a install.sh, que traía "$G_SEP" en
# el banner sin haberlo declarado y moría justo después de comprobar el root,
# sin instalar nada. El equivalente aquí lo comprueba install_test.sh; esta es
# la mitad de 'orbit', donde el mismo descuido tumbaría cualquier orden.
# El '\b' delante evita que 'ORBIT_LANG_CODE=' declare un 'G_CODE' inventado,
# que taparía el fallo en vez de encontrarlo.
check "ningún glifo sin declarar" "" "$(comm -23 \
  <(grep -oE '\$\{?G_[A-Z_]+' "$ORBIT_ROOT/orbit" | tr -d '${' | sort -u) \
  <(grep -oE '\bG_[A-Z_]+='   "$ORBIT_ROOT/orbit" | tr -d '='   | sort -u) \
  | tr '\n' ' ' | sed 's/ *$//')"

# Con UTF-8, los símbolos de siempre.
check "utf-8 da tic"        "✓" "$(con_entorno LC_ALL=C.UTF-8 -- 'printf "%s" "$G_OK"')"
check "utf-8 da aspa"       "✗" "$(con_entorno LC_ALL=C.UTF-8 -- 'printf "%s" "$G_ERR"')"
check "y raya de dibujo"    "─" "$(con_entorno LC_ALL=C.UTF-8 -- 'printf "%s" "$G_HR"')"
# 'utf8' sin guion es igual de válido para la libc, y hay sistemas que la
# escriben así.
check "utf8 sin guion vale" "✓" "$(con_entorno LC_ALL=en_US.utf8 -- 'printf "%s" "$G_OK"')"

# Sin UTF-8 —el LANG=C de un VPS recién creado, por SSH— cada símbolo de tres
# bytes serían tres borrones. Ahí todo tiene que ser ASCII de siete bits.
for v in G_OK G_ERR G_WARN G_INFO G_ON G_OFF G_MID G_ARROW G_SEC G_BRANCH G_EDIT G_PROMPT G_DIAMOND G_HR; do
  check "ascii: $v" "0" \
    "$(con_entorno LC_ALL=C LANG=C -- 'printf "%s" "$'"$v"'"' | grep -cP '[^\x00-\x7F]')"
done
check "y ok() lo usa"       "1" \
  "$(con_entorno LC_ALL=C LANG=C TERM=xterm -- 'ok hecho' | grep -c '^  + hecho$')"
check "y err() también"     "1" \
  "$(con_entorno LC_ALL=C LANG=C TERM=xterm -- 'err roto 2>&1' | grep -c '^  x roto$')"
# La raya también: 'hr' pinta el ancho entero, y una raya de U+2500 en una
# terminal que no habla UTF-8 son 198 borrones, no una línea.
check "y la raya"           "0" \
  "$(con_entorno LC_ALL=C LANG=C TERM=xterm -- 'hr 10' | grep -cP '[^\x00-\x7F]')"
# El logotipo grande está hecho de bloques: sin UTF-8, ni aparece. Ojo al 'if':
# el script trae errexit puesto, así que un '_logo_fits; printf "$?"' suelto se
# muere en el propio _logo_fits y no llega a imprimir nada.
#
# Las otras dos condiciones de _logo_fits —que haya color y que la ventana sea
# grande— no se dan capturando la salida, así que se ponen a mano: si no, la
# prueba pasaría por no haber terminal y no por la codificación, que es justo
# lo que se quiere comprobar.
_cabe='R=$'"'"'\e[0m'"'"'; UI_WIDTH=90; tput() { printf 50; }; if _logo_fits; then printf si; else printf no; fi'
check "ni el logotipo"      "no" "$(con_entorno LC_ALL=C LANG=C -- "$_cabe")"
check "pero con utf-8 sí"   "si" "$(con_entorno LC_ALL=C.UTF-8 -- "$_cabe")"

# Y quien quiera decidirlo a mano, puede: hay terminales que hablan UTF-8 con
# LANG sin poner (un systemd, un contenedor) y al revés.
check "forzar ascii"        "+" "$(con_entorno LC_ALL=C.UTF-8 UI_GLYPHS=ascii -- 'printf "%s" "$G_OK"')"
check "forzar unicode"      "✓" "$(con_entorno LC_ALL=C UI_GLYPHS=unicode -- 'printf "%s" "$G_OK"')"

report
