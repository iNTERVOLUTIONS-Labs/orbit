#!/usr/bin/env bash
# ============================================================================
#  Idioma: detección, precedencia, formato y catálogo.
#
#  Lo que más se comprueba aquí no son los mensajes, que se ven a simple vista,
#  sino las dos cosas que fallan en silencio:
#
#    · Que el catálogo no se quede atrás. Como la clave es el propio texto en
#      español, cambiar una frase y no tocar el catálogo no rompe nada — sale
#      la frase en español, y nadie se entera. Aquí se compara el catálogo con
#      lo que hay de verdad en el código y se dice qué sobra y qué falta.
#    · Que las traducciones sepan printf. Un '%s' de menos deja un hueco, uno
#      de más pinta basura, y un '%' que quería ser un porcentaje se come el
#      argumento siguiente. Se cuentan uno a uno.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ═══ el catálogo, leído del propio script ═════════════════════════════════
#
# Se sacan los mensajes del código con el mismo criterio con el que los ve
# bash: primer argumento literal de ok/info/warn/err/die/title/hint/t, segundo
# de ask. Sin nada de esto la prueba se creería cualquier cosa.
ORBIT_SRC="$ORBIT_ROOT/orbit"

# Los mensajes que el código le pasa a _t, uno por línea, con los saltos de
# línea escapados para que cada mensaje ocupe una línea y sólo una.
_msgids() { _msgids_de "$ORBIT_SRC"; }
_msgids_de() { # _msgids_de <fichero>
  python3 - "$1" <<'PY'
import re, sys

# 'step' sólo existe en install.sh y los selectores sólo en orbit: la misma
# tabla vale para los dos porque un nombre que no aparece no encuentra nada.
FUNCS = {'die':0,'ok':0,'info':0,'warn':0,'err':0,'title':0,'hint':0,'t':0,'_t':0,
         'step':0,'confirm':0,'choose':0,'spin':0,'pick_app':0,'ask':1,'_pick_script':1}
CALL = re.compile(r'(?<![\w./-])(' + '|'.join(sorted(FUNCS, key=len, reverse=True)) + r')(?=[ \t])')
POS  = re.compile(r'(^|[;&|{(!)]|\bthen\b|\belse\b|\bdo\b|\bif\b|\belif\b|\bwhile\b|\buntil\b|\$\()[ \t]*$')
DEF  = re.compile(r'^\s*(die|ok|info|warn|err|title|hint|step|t|_t)\(\)')

def skip(s, i, op, cl):
    depth = 0; j = i
    while j < len(s):
        c = s[j]
        if c == '\\': j += 2; continue
        if c == "'": j = s.index("'", j+1) + 1; continue
        if c == '"': j = end_dq(s, j) + 1; continue
        if c == op: depth += 1
        elif c == cl:
            depth -= 1
            if depth == 0: return j + 1
        j += 1
    raise ValueError

def end_dq(s, start):
    j = start + 1
    while j < len(s):
        c = s[j]
        if c == '\\': j += 2; continue
        if c == '"': return j
        if c == '$' and s[j+1:j+2] == '(': j = skip(s, j+1, '(', ')'); continue
        if c == '$' and s[j+1:j+2] == '{': j = skip(s, j+1, '{', '}'); continue
        j += 1
    raise ValueError

def has_live_dollar(s):
    """Un '$' de verdad —una expansión— frente a un '\\$' escapado, que es texto.
    Sin esta distinción, cualquier mensaje con un dólar literal quedaba fuera de
    la comprobación, y por tanto no se podía traducir sin que nadie lo notara."""
    i = 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s): i += 2; continue
        if s[i] == '$': return True
        i += 1
    return False

def unescape(s):
    out = []; i = 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            n = s[i+1]
            if n == '\n': i += 2; continue
            if n in '"\\$`': out.append(n); i += 2; continue
        out.append(s[i]); i += 1
    return ''.join(out)

def arg_at(src, i, n):
    for k in range(n + 1):
        while i < len(src) and src[i] in ' \t': i += 1
        if i >= len(src): return None
        if src[i] == '"':
            try: e = end_dq(src, i)
            except ValueError: return None
            if k == n: return src[i+1:e]
            i = e + 1
        elif src[i] == "'":
            e = src.find("'", i + 1)
            if e < 0: return None
            if k == n: return src[i+1:e]
            i = e + 1
        else:
            m = re.match(r'[^\s"\';|&]+', src[i:])
            if not m or k == n: return None
            i += m.end()
    return None

src = open(sys.argv[1]).read()
seen = []
for m in CALL.finditer(src):
    bol = src.rfind('\n', 0, m.start()) + 1
    head = src[bol:m.start()]
    if head.lstrip().startswith('#'): continue
    if not POS.search(head): continue
    if DEF.match(src[bol:]): continue
    s = arg_at(src, m.end(), FUNCS[m.group(1)])
    if s is None or not s.strip(): continue
    if has_live_dollar(s): continue   # una expansión, no un literal
    s = unescape(s)
    if s not in seen: seen.append(s)
for s in seen:
    print(s.replace('\n', '\\n'))
PY
}

# Las claves del catálogo inglés, con el mismo escapado.
_i18n_load_keys() {
  local k
  ORBIT_LANG_CODE="en"; _i18n_load
  for k in "${!I18N[@]}"; do printf '%s\n' "${k//$'\n'/\\n}"; done
}

# Las claves del catálogo del instalador. Se carga su '_i18n_load' a solas, sin
# ejecutar el resto del script, que instalaría medio servidor.
_inst_keys() {
  bash -c '
    set -Eeuo pipefail
    declare -A I18N=(); ORBIT_LANG_CODE="en"
    eval "$(sed -n "/^_i18n_load() {/,/^}/p;/^_i18n_en() {/,/^}/p" "$1")"
    _i18n_load
    for k in "${!I18N[@]}"; do printf "%s\\n" "$k"; done
  ' _ "$ORBIT_ROOT/install.sh"
}

# Y sus valores, para poder contar los %s de los dos lados.
declare -A INST_CAT_V=()
_inst_load_values() {
  local line k v
  while IFS= read -r line; do
    k="${line%%$'\t'*}"; v="${line#*$'\t'}"
    INST_CAT_V["$k"]="$v"
  done < <(bash -c '
    set -Eeuo pipefail
    declare -A I18N=(); ORBIT_LANG_CODE="en"
    eval "$(sed -n "/^_i18n_load() {/,/^}/p;/^_i18n_en() {/,/^}/p" "$1")"
    _i18n_load
    for k in "${!I18N[@]}"; do printf "%s\\t%s\\n" "$k" "${I18N[$k]}"; done
  ' _ "$ORBIT_ROOT/install.sh")
}

# ═══ normalizar el código de idioma ═══════════════════════════════════════
section "De configuración regional a idioma"
check "es_ES.UTF-8"        "es"  "$(_lang_norm 'es_ES.UTF-8')"
check "en_GB"              "en"  "$(_lang_norm 'en_GB')"
check "pt_BR.UTF-8"        "pt"  "$(_lang_norm 'pt_BR.UTF-8')"
check "es.UTF-8"           "es"  "$(_lang_norm 'es.UTF-8')"
check "ca_ES@valencia"     "ca"  "$(_lang_norm 'ca_ES@valencia')"
check "EN mayúsculas"      "en"  "$(_lang_norm 'EN')"
check "en-US con guion"    "en"  "$(_lang_norm 'en-US')"
check "vacío"              ""    "$(_lang_norm '')"

section "Qué idiomas habla"
run _lang_supported es; check "es"            "0" "$?"
run _lang_supported en; check "en"            "0" "$?"
run _lang_supported fr; check "fr todavía no" "1" "$?"
# Sin los espacios de _lang_supported, una 'e' encajaría dentro de 'es'.
run _lang_supported e;  check "una letra suelta no" "1" "$?"
run _lang_supported ""; check "vacío no"      "1" "$?"

# ═══ el idioma del sistema ════════════════════════════════════════════════
section "El idioma que dice el entorno"
check "LANG"        "en_GB.UTF-8" "$(LC_ALL='' LC_MESSAGES='' LANGUAGE='' LANG=en_GB.UTF-8 _lang_from_env)"
check "LC_ALL manda" "de_DE.UTF-8" "$(LC_ALL=de_DE.UTF-8 LC_MESSAGES='' LANGUAGE='' LANG=en_GB.UTF-8 _lang_from_env)"
check "LC_MESSAGES sobre LANG" "fr_FR" "$(LC_ALL='' LC_MESSAGES=fr_FR LANGUAGE='' LANG=en_GB.UTF-8 _lang_from_env)"
check "LANGUAGE gana" "pt" "$(LC_ALL='' LC_MESSAGES='' LANGUAGE=pt:en LANG=en_GB.UTF-8 _lang_from_env)"
# 'C' y 'POSIX' no son un idioma: son «ninguno». Darlas por inglés le cambiaría
# el idioma a medio servidor sólo por correr dentro de un cron.
check "C no es inglés"      "" "$(LC_ALL=C LC_MESSAGES='' LANGUAGE='' LANG='' _lang_from_env)"
check "C.UTF-8 tampoco"     "" "$(LC_ALL=C.UTF-8 LC_MESSAGES='' LANGUAGE='' LANG='' _lang_from_env)"
check "POSIX tampoco"       "" "$(LC_ALL=POSIX LC_MESSAGES='' LANGUAGE='' LANG='' _lang_from_env)"
check "sin nada"            "" "$(LC_ALL='' LC_MESSAGES='' LANGUAGE='' LANG='' _lang_from_env)"
# LANGUAGE sólo cuenta si la regional dice algo; con todo en C no dice nada.
check "LANGUAGE sin regional" "" "$(LC_ALL=C LC_MESSAGES='' LANGUAGE=pt LANG='' _lang_from_env)"

section "El idioma que dicen los ficheros del sistema"
# Es el caso del temporizador de systemd y de cron: arrancan con el entorno
# vacío, y ahí «no hay LANG» no significa que nadie tenga idioma.
mkdir -p "$TMP/os"
printf 'LANG=en_US.UTF-8\n' > "$TMP/os/locale"
_lang_from_os() {                     # misma lógica, sobre un fichero de mentira
  local k line
  for k in LC_ALL LC_MESSAGES LANG LANGUAGE; do
    line="$(grep -m1 -E "^[[:space:]]*$k=" "$TMP/os/locale" 2>/dev/null)" || continue
    line="${line#*=}"; line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"; line="${line%%:*}"
    case "$line" in ""|C|C.*|POSIX|POSIX.*) continue ;; esac
    printf '%s' "$line"; return 0
  done
}
check "lee /etc/default/locale" "en_US.UTF-8" "$(_lang_from_os)"
printf 'LANG="es_ES.UTF-8"\n' > "$TMP/os/locale"
check "con comillas"            "es_ES.UTF-8" "$(_lang_from_os)"
printf 'LANG=C.UTF-8\n' > "$TMP/os/locale"
check "C se descarta"           ""            "$(_lang_from_os)"
printf '# un comentario\nOTRA=cosa\n' > "$TMP/os/locale"
# Sin el '|| continue' de _lang_from_os esto mata al script: pipefail hereda el
# código de grep, y un fichero que no menciona LANG no es un error.
check "sin ninguna clave"       ""            "$(_lang_from_os)"

# ═══ precedencia ══════════════════════════════════════════════════════════
section "Quién manda sobre quién"
_r() { # _r <flag> <env> <conf> <LANG>
  ORBIT_LANG_FLAG="$1"
  # shellcheck disable=SC2034  # las lee _lang_resolve
  ORBIT_LANG_ENV="$2"
  # shellcheck disable=SC2034  # ídem: es la de /etc/orbit/orbit.conf
  ORBIT_LANG="$3"
  local LC_ALL="" LC_MESSAGES="" LANGUAGE="" LANG="$4"
  _lang_from_os() { :; }              # el sistema no dice nada en estas pruebas
  _lang_resolve
  printf '%s' "$ORBIT_LANG_CODE"
}
check "sin nada, español"      "es" "$(_r "" "" "" "")"
check "el sistema decide"      "en" "$(_r "" "" "" "en_US.UTF-8")"
check "la conf gana al sistema" "en" "$(_r "" "" "en" "es_ES.UTF-8")"
check "el entorno gana a la conf" "es" "$(_r "" "es" "en" "en_US.UTF-8")"
check "la bandera gana a todo" "en" "$(_r "en" "es" "es" "es_ES.UTF-8")"
check "un idioma que no existe se ignora" "es" "$(_r "klingon" "" "" "es_ES.UTF-8")"
# Un idioma que no está no puede dejar a Orbit sin arrancar: se cae al fuente y
# quien se equivocó tecleando se entera por la bandera, que sí se valida.
check "y no aborta"            "es" "$(_r "" "klingon" "" "")"
check "regional completa en la bandera" "en" "$(_r "en_US.UTF-8" "" "" "")"

# ═══ formatear el mensaje ═════════════════════════════════════════════════
section "Sustituir los argumentos"
ORBIT_LANG_CODE="es"; _i18n_load
_t "Release %s activada" "2026-01-01"
check "un argumento"  "Release 2026-01-01 activada" "$I18N_MSG"
_t "%s → %s (código %s)" a b 301
check "tres"          "a → b (código 301)" "$I18N_MSG"
_t "Sin argumentos"
check "ninguno"       "Sin argumentos" "$I18N_MSG"
_t "Disco al %s%% (umbral %s%%). Mira 'ncdu /' o poda releases." 91 90
check "porcentajes"   "Disco al 91% (umbral 90%). Mira 'ncdu /' o poda releases." "$I18N_MSG"
# El '--' de printf: hay mensajes que empiezan por guión, y sin él printf los
# toma por opciones suyas, se queja y devuelve 2. Los comandos que morían con
# uno de esos pasaban de salir con 1 a salir con 2.
_t "--lines quiere un número, no '%s'" xyz
check "empieza por guión" "--lines quiere un número, no 'xyz'" "$I18N_MSG"
# Sin argumentos no se formatea, y por eso un '%s' sale tal cual. No es un
# descuido: es lo que hace que "$(t …)" —un texto ya montado, que puede llevar
# cualquier cosa dentro— se pueda pasar a spin, choose o ask sin que se
# reinterprete como formato. Antes salía vacío, y el comando de build de la app
# se pintaba corrompido.
_t "%s"; check "sin argumentos no se formatea" "%s" "$I18N_MSG"
_t "50%-done"; check "ni un % suelto"          "50%-done" "$I18N_MSG"
_t "%s de %s" "a" "b"; check "y con ellos, sí"  "a de b"   "$I18N_MSG"

section "Las marcas de color"
B=$'\e[1m'; R=$'\e[0m'; D=$'\e[2m'
_t "{b}%s{r} y {d}algo{r}" hola
check "se sustituyen" "${B}hola${R} y ${D}algo${R}" "$I18N_MSG"
B=""; R=""; D=""
_t "{b}%s{r} y {d}algo{r}" hola
check "sin color, desaparecen" "hola y algo" "$I18N_MSG"
# La clave del catálogo no puede depender de si hay color o no: si las marcas
# fueran ${B} de verdad, se expandirían antes de que _t viera nada y la misma
# frase sería dos claves distintas.
_t "{r}"; check "una marca suelta" "" "$I18N_MSG"

section "Buscar en el catálogo"
ORBIT_LANG_CODE="en"; _i18n_load
_t "Release %s activada" "2026-01-01"
check "traduce"       "Release 2026-01-01 is live" "$I18N_MSG"
_t "Una frase que no está en ningún catálogo"
check "lo que falta sale en español" "Una frase que no está en ningún catálogo" "$I18N_MSG"
ORBIT_LANG_CODE="es"; _i18n_load
_t "Release %s activada" "2026-01-01"
check "en español no hay catálogo" "Release 2026-01-01 activada" "$I18N_MSG"
check "y queda vacío"              "0" "${#I18N[@]}"

# ═══ el catálogo contra el código ═════════════════════════════════════════
section "El catálogo no se ha quedado atrás"
# Hace falta python3 para leer bash de verdad: comillas anidadas, "$(…)" dentro
# de la cadena, continuaciones de línea. Con grep saldría una lista aproximada,
# y una comprobación de cobertura aproximada no comprueba nada — así que sin
# python3 se dice y se salta, en vez de dar por bueno lo que no se ha mirado.
if ! command -v python3 >/dev/null; then
  echo "  (falta python3: me salto la comprobación del catálogo)"
  SIN_PYTHON="yes"
fi
mapfile -t CODE_MSGS < <([[ "${SIN_PYTHON:-no}" == "yes" ]] || _msgids)
mapfile -t CAT_KEYS  < <(_i18n_load_keys)
ORBIT_LANG_CODE="es"; _i18n_load

if [[ "${SIN_PYTHON:-no}" != "yes" ]]; then
  check "hay mensajes que traducir" "1" "$(( ${#CODE_MSGS[@]} > 500 ? 1 : 0 ))"
  check "y catálogo inglés"         "1" "$(( ${#CAT_KEYS[@]}  > 500 ? 1 : 0 ))"

  # Una clave que ya no está en el código es una frase que alguien cambió sin
  # tocar el catálogo: la traducción vieja no se va a usar nunca más.
  declare -A EN_CODE=()
  for m in "${CODE_MSGS[@]}"; do EN_CODE["$m"]=1; done
  huerfanas=""
  for k in "${CAT_KEYS[@]}"; do
    [[ -n "${EN_CODE[$k]:-}" ]] || huerfanas="${huerfanas:+$huerfanas
  }$k"
  done
  check "ninguna traducción huérfana" "" "$huerfanas"

  # Al revés no es un fallo del programa —lo que falte sale en español— pero sí
  # conviene que no se acumule sin que nadie lo mire. Las únicas que pueden
  # faltar son las que se escriben igual en los dos idiomas: rótulos de columna,
  # líneas de código de ejemplo y formatos que sólo llevan %s. Cualquier otra que
  # aparezca aquí es una frase que alguien añadió y nadie tradujo.
  IGUALES=(
    ' [app]' 'commit {b}%s{r} · %s' '%s' '    Build       %s' '    Start       %s'
    '    SPA         %s' '    Docroot     %s' '    Framework   %s (%s)'
    '  orbit deploy %s' '  orbit ssl %s' 'App' '%s {d}· %s{r}' '%s — %s'
    '%s → %s {d}· %s{r}' 'APP' 'CPU' 'MEM' 'REQ/min' '%s → %s'
    "  STATIC_ROOT = BASE_DIR / 'staticfiles'"
    "  MEDIA_ROOT = '%s/%s/shared/media'"
    '  <p class="motivo"><!--# include file="maintenance.reason" --></p>'
    'Plan:' '  %s'
    "  --start './bin/app --addr 127.0.0.1:\$PORT'"
    # Rótulos de 'list', 'info' y 'status' que se escriben igual en los dos
    # idiomas. Los espacios son la alineación de la tabla, así que van tal cual.
    'SSL' 'no'
    '  Build         %s' '  Start         %s' '  Releases      %s'
    '  Host        %s (%s)' '  Uptime      %s'
  )
  declare -A EN_CAT=() EN_IGUAL=()
  for k in "${CAT_KEYS[@]}"; do EN_CAT["$k"]=1; done
  for k in "${IGUALES[@]}"; do EN_IGUAL["$k"]=1; done
  sin=""
  for m in "${CODE_MSGS[@]}"; do
    [[ -n "${EN_CAT[$m]:-}" || -n "${EN_IGUAL[$m]:-}" ]] || sin="${sin:+$sin
  }$m"
  done
  check "nada sin traducir" "" "$sin"
  # Y al revés: una entrada de esa lista que ya no esté en el código sobra.
  fuera=""
  declare -A EN_CODE2=()
  for m in "${CODE_MSGS[@]}"; do EN_CODE2["$m"]=1; done
  for k in "${IGUALES[@]}"; do
    [[ -n "${EN_CODE2[$k]:-}" ]] || fuera="${fuera:+$fuera
  }$k"
  done
  check "y la lista de iguales al día" "" "$fuera"
fi

# ═══ la clave, byte a byte ════════════════════════════════════════════════
section "La clave del código es la del catálogo, sin normalizar"
# La comprobación de arriba compara listas de texto, y para poder escribir un
# mensaje por línea el extractor convierte los saltos reales en '\n'. Eso hace
# que un mensaje escrito con un salto de verdad y su clave escrita con '\n' —dos
# caracteres— parezcan iguales cuando no lo son: el catálogo no lo encontraría
# nunca y las dos comprobaciones lo darían por bueno. Pasó exactamente eso.
#
# Aquí se busca cada mensaje en el array de verdad, con la clave tal cual.
if [[ "${SIN_PYTHON:-no}" != "yes" ]]; then
  ORBIT_LANG_CODE="en"; _i18n_load
  nunca=""
  for m in "${CODE_MSGS[@]}"; do
    # Sólo los que el catálogo dice tener: los que faltan ya los cuenta la
    # comprobación anterior, y aquí sólo importa que lo que hay se encuentre.
    [[ -n "${EN_CAT[$m]:-}" ]] || continue
    real="${m//\\n/$'\n'}"          # deshacer la normalización del extractor
    [[ -n "${I18N[$real]+x}" || -n "${I18N[$m]+x}" ]] \
      || nunca="${nunca:+$nunca
}$m"
  done
  check "toda clave se encuentra de verdad" "" "$nunca"
  ORBIT_LANG_CODE="es"; _i18n_load
fi

# ═══ que las traducciones sepan printf ════════════════════════════════════
section "Los %s cuadran"
# Se cuentan las directivas de verdad: '%%' es un porcentaje literal y no
# consume ningún argumento, así que se quita antes de contar.
_specs() { local s="${1//%%/}"; s="${s//[^%]/}"; printf '%s' "${#s}"; }
ORBIT_LANG_CODE="en"; _i18n_load
malos=""
for k in "${!I18N[@]}"; do
  a="$(_specs "$k")"; b="$(_specs "${I18N[$k]}")"
  [[ "$a" == "$b" ]] || malos="${malos:+$malos
}$k ($a vs $b)"
done
check "misma cuenta que el original" "" "$malos"

# Un '%' que no sea '%s' ni '%%' se come el argumento siguiente y pinta
# cualquier cosa. Es el fallo más fácil de colar traduciendo un porcentaje.
sueltos=""
for k in "${!I18N[@]}"; do
  v="${I18N[$k]//%%/}"
  [[ "$v" =~ %[^s] || "$v" =~ %$ ]] && sueltos="${sueltos:+$sueltos
}$k"
done
check "sin directivas raras" "" "$sueltos"

# Las marcas que abren tienen que cerrar. Una {b} sin {r} deja el resto de la
# sesión en negrita.
descuadre=""
for k in "${!I18N[@]}"; do
  ka="$(grep -o '{[a-z]*}' <<<"$k" | wc -l)"
  va="$(grep -o '{[a-z]*}' <<<"${I18N[$k]}" | wc -l)"
  [[ "$ka" == "$va" ]] || descuadre="${descuadre:+$descuadre
}$k ($ka vs $va)"
done
check "mismas marcas de color" "" "$descuadre"

# Y ninguna marca inventada: {negrita} no la sustituye nadie y saldría tal cual.
inventadas=""
for k in "${!I18N[@]}"; do
  for mk in $(grep -o '{[a-z]*}' <<<"${I18N[$k]}" || true); do
    case "$mk" in
      '{b}'|'{d}'|'{r}'|'{red}'|'{grn}'|'{yel}'|'{blu}'|'{mag}'|'{cya}'|'{gry}') ;;
      *) inventadas="${inventadas:+$inventadas
}$k → $mk" ;;
    esac
  done
done
check "sin marcas inventadas" "" "$inventadas"

section "Un mensaje con % lleva siempre %s"
# Es la regla que permite que _t no formatee cuando no hay argumentos, y con
# ella que "$(t …)" sea seguro en cualquier posición. Si un mensaje llevara un
# '%%' y se llamara sin argumentos, saldría '%%' por pantalla.
malformados=""
for k in "${!I18N[@]}"; do
  [[ "$k" == *%* ]] || continue
  [[ "$k" == *%s* ]] || malformados="${malformados:+$malformados
}$k"
done
check "ningún %% suelto sin %s" "" "$malformados"

section "Los rótulos que luego se comparan"
# _pick_ref reconoce su propia elección por el símbolo de delante, y
# _pick_script por el texto entero. Si una traducción se lleva el símbolo, el
# selector deja de reconocer lo que acaba de enseñar.
check "el ✎ sigue delante" "1" \
  "$(grep -c '^✎' <<<"${I18N['✎ escribir otro comando']:-✎ x}")"
check "el ∅ sigue delante" "1" \
  "$(grep -c '^∅' <<<"${I18N['∅ ninguno {d}· esta app no lo necesita{r}']:-∅ x}")"

section "El atajo de sí/no"
ORBIT_LANG_CODE="en"; _i18n_load
_t "[S/n]"; check "por defecto sí" "[Y/n]" "$I18N_MSG"
_t "[s/N]"; check "por defecto no" "[y/N]" "$I18N_MSG"
# La respuesta se acepta en los dos idiomas: quien tiene Orbit en inglés y
# teclea 's' de «sí» no se ha equivocado de programa.
# shellcheck disable=SC2034  # la lee confirm
ASSUME_YES="no"
printf 's\n' | { run confirm "¿?" y >/dev/null; }; check "'s' vale en inglés" "0" "$?"
printf 'y\n' | { run confirm "¿?" y >/dev/null; }; check "'y' vale en español" "0" "$?"
printf 'n\n' | { run confirm "¿?" y >/dev/null; }; check "'n' es que no"      "1" "$?"
ORBIT_LANG_CODE="es"; _i18n_load

# ═══ lo que de verdad sale por pantalla ══════════════════════════════════
section "La salida cambia de idioma, no sólo el catálogo"
# Todo lo de arriba mira el catálogo y el mecanismo. Nada miraba **la pantalla**,
# y por ahí se coló que 'list', 'info' y 'status' salieran en español con
# --lang en: son printf crudos que nunca llamaban a t, así que el extractor no
# los veía y las comprobaciones de cobertura los daban por inexistentes.
#
# Esto compara la salida de cada comando en los dos idiomas y exige que cambie.
# No compara contra un texto fijo a propósito: eso obligaría a tocar la prueba
# cada vez que alguien mejora una frase, y acabaría desactivada.
mkapp par node 3401 par.test >/dev/null 2>&1
_salida() { # _salida <idioma> <función> [args…]
  local l="$1"; shift
  ORBIT_LANG_CODE="$l"; _i18n_load
  # Sin color, para comparar palabras y no secuencias de escape. Se apagan las
  # diez, aunque estas funciones no usen todas: apagar la mitad dejaría escapes
  # sueltos en la comparación en cuanto alguien añadiera un color a una línea.
  # shellcheck disable=SC2034
  local B="" D="" R="" RED="" GRN="" YEL="" BLU="" MAG="" CYA="" GRY=""
  "$@" 2>&1 | sed 's/[[:space:]]\+$//'
}
_comunes() { # _comunes <función> [args…] -> las líneas con texto que NO cambian
  local es en
  es="$(_salida es "$@" | grep -E '[A-Za-zÁ-ú]{4,}' | sort -u)"
  en="$(_salida en "$@" | grep -E '[A-Za-zÁ-ú]{4,}' | sort -u)"
  comm -12 <(printf '%s\n' "$es") <(printf '%s\n' "$en")
}
# Lo que puede coincidir son datos —nombres de app, dominios, rutas, versiones—
# y las poquísimas etiquetas que se escriben igual en los dos idiomas. Ésas se
# declaran aquí por su nombre: si aparece una que no está, es una frase que
# alguien añadió sin traducir, y la prueba la enseña entera.
check "list cambia entero" "" "$(_comunes cmd_list | grep -vE '^  (par|w1) ' || true)"
# 'Host' y 'Uptime' se escriben igual en español y en inglés.
check "status cambia entero" "" \
  "$(_comunes cmd_status | grep -vE '^  (Host|Uptime) ' || true)"
ORBIT_LANG_CODE="es"; _i18n_load

# ═══ el instalador ════════════════════════════════════════════════════════
section "install.sh comparte el núcleo, no lo copia"
# El instalador saca de 'orbit' el mecanismo de idiomas con sed, entre dos
# marcas. Si las marcas desaparecen o alguien mueve una función fuera del
# bloque, el instalador se queda mudo en español sin decir nada — así que esto
# comprueba que el trozo extraído se carga solo y trae lo que hace falta.
NUCLEO="$TMP/nucleo.sh"
sed -n '/^# >>> núcleo de idiomas/,/^# <<< núcleo de idiomas/p' "$ORBIT_SRC" > "$NUCLEO"
check "las marcas existen" "1" "$([[ -s "$NUCLEO" ]] && echo 1 || echo 0)"
# En un bash aparte, para que no lo salve nada de lo que ya hay cargado aquí.
_nucleo_trae() { # _nucleo_trae <función>
  bash -c 'set -Eeuo pipefail; . "$1" >/dev/null 2>&1; declare -F "$2" >/dev/null' \
    _ "$NUCLEO" "$1" && echo 1 || echo 0
}
for fn in _lang_norm _lang_supported _lang_from_env _lang_from_os _lang_resolve _t t _lang_early; do
  check "trae $fn" "1" "$(_nucleo_trae "$fn")"
done
# Y que de verdad resuelve: cargar el trozo tiene que bastar para detectar.
check "y resuelve solo" "en" \
  "$(LANG=en_US.UTF-8 bash -c 'set -Eeuo pipefail; . "$1"; _lang_resolve; printf "%s" "$ORBIT_LANG_CODE"' _ "$NUCLEO")"
# El instalador no puede depender de que 'orbit' esté: sin él se queda en
# español, pero se instala. La rama de repuesto define las mismas funciones.
check "install.sh tiene rama de repuesto" "1" \
  "$(grep -c '_lang_early() { :; }' "$ORBIT_ROOT/install.sh")"

# Y de punta a punta, que es donde se vio el fallo de verdad: la condición que
# decide si se carga el núcleo llevaba un 'sed | grep -q', y con pipefail eso
# devuelve 141 —grep sale al primer acierto y sed se come un SIGPIPE—, así que
# el instalador se quedaba en español para todo el mundo sin decir nada.
#
# Se ejecuta sólo la cabecera del instalador, hasta que ya ha decidido idioma:
# el resto instala medio servidor. Va en su propio directorio, con 'orbit' al
# lado, para que su SCRIPT_DIR salga bien.
mkdir -p "$TMP/inst"
cp "$ORBIT_SRC" "$TMP/inst/orbit"
sed -n '1,/^_i18n_load$/p' "$ORBIT_ROOT/install.sh" > "$TMP/inst/cabecera.sh"
check "la cabecera acaba donde toca" "1" \
  "$(grep -c '^_i18n_load$' "$TMP/inst/cabecera.sh")"
_inst_lang() { # _inst_lang <LANG>  -> idioma y una frase suya
  # 'env -u' y no 'VAR=""': con LC_MESSAGES vacía, bash avisa por stderr en cada
  # llamada de que no puede fijar la configuración regional. Quitarlas del
  # entorno es además lo que de verdad pasa en un cron.
  env -u LC_ALL -u LC_MESSAGES -u LANGUAGE -u ORBIT_LANG LANG="$1" \
    bash -c '. "$1"; printf "%s|" "$ORBIT_LANG_CODE"; t "Paquetes base instalados"' \
    _ "$TMP/inst/cabecera.sh" 2>/dev/null
}
check "con LANG inglés"  "en|Base packages installed" "$(_inst_lang en_US.UTF-8)"
check "con LANG español" "es|Paquetes base instalados" "$(_inst_lang es_ES.UTF-8)"
# Sin 'orbit' al lado no hay núcleo, y entonces todo sale en el idioma fuente.
rm -f "$TMP/inst/orbit"
check "sin 'orbit' al lado, español" "es|Paquetes base instalados" "$(_inst_lang en_US.UTF-8)"
cp "$ORBIT_SRC" "$TMP/inst/orbit"

section "El catálogo del instalador"
if [[ "${SIN_PYTHON:-no}" != "yes" ]]; then
  mapfile -t INST_MSGS < <(_msgids_de "$ORBIT_ROOT/install.sh")
  mapfile -t INST_KEYS < <(_inst_keys)
  _inst_load_values
  check "hay mensajes" "1" "$(( ${#INST_MSGS[@]} > 30 ? 1 : 0 ))"
  declare -A INST_CODE=() INST_CAT=()
  for m in "${INST_MSGS[@]}"; do INST_CODE["$m"]=1; done
  for k in "${INST_KEYS[@]}"; do INST_CAT["$k"]=1; done
  sobra=""
  for k in "${INST_KEYS[@]}"; do
    [[ -n "${INST_CODE[$k]:-}" ]] || sobra="${sobra:+$sobra
}$k"
  done
  check "ninguna traducción huérfana" "" "$sobra"
  falta=""
  for m in "${INST_MSGS[@]}"; do
    [[ -n "${INST_CAT[$m]:-}" ]] || falta="${falta:+$falta
}$m"
  done
  check "ningún mensaje sin traducir" "" "$falta"
  # Los mismos %s a los dos lados, que aquí también se cuelan.
  malos=""
  for k in "${INST_KEYS[@]}"; do
    a="$(_specs "$k")"; b="$(_specs "${INST_CAT_V[$k]}")"
    [[ "$a" == "$b" ]] || malos="${malos:+$malos
}$k ($a vs $b)"
  done
  check "los %s cuadran" "" "$malos"
fi

# ═══ el entorno y la auto-elevación ══════════════════════════════════════
section "Un ORBIT_LANG que no existe no deja a nadie sin orbit"
# ARCHITECTURE §21.4 dice que un idioma que no existe se ignora. Pero al
# elevarse a root la variable se convierte en bandera, y las banderas SÍ se
# validan: un 'export ORBIT_LANG=klingon' en un .bashrc dejaba orbit inservible
# para ese usuario y funcionando para root, que no se eleva. Dos comportamientos
# según quién ejecuta es lo peor de las dos opciones.
_eleva() { # _eleva <valor de ORBIT_LANG> -> "sí" si se inyectaría la bandera
  local v="$1"
  _lang_supported "$(_lang_norm "$v")" && echo "sí" || echo "no"
}
check "en se pasa"        "sí" "$(_eleva en)"
check "es_ES.UTF-8 se pasa" "sí" "$(_eleva es_ES.UTF-8)"
check "klingon no"        "no" "$(_eleva klingon)"
check "vacío tampoco"     "no" "$(_eleva '')"

# ═══ las banderas ═════════════════════════════════════════════════════════
section "--lang en cualquier posición"
_lang_strip --lang en list; check "delante"  "en" "$ORBIT_LANG_FLAG"
check "y sale de los argumentos"  "list" "${LANG_ARGS[*]}"
ORBIT_LANG_FLAG=""
_lang_strip list --lang en; check "detrás"   "en" "$ORBIT_LANG_FLAG"
check "y también sale"            "list" "${LANG_ARGS[*]}"
ORBIT_LANG_FLAG=""
_lang_strip list --lang=en web; check "con ="  "en" "$ORBIT_LANG_FLAG"
check "sin tocar lo demás"        "list web" "${LANG_ARGS[*]}"
ORBIT_LANG_FLAG=""; LANG_MISSING="no"
_lang_strip list --idioma en; check "--idioma" "en" "$ORBIT_LANG_FLAG"
ORBIT_LANG_FLAG=""; LANG_MISSING="no"
_lang_strip list --lang; check "sin valor se anota" "yes" "$LANG_MISSING"
ORBIT_LANG_FLAG=""; LANG_MISSING="no"
_lang_strip env set web CLAVE valor
check "no toca argumentos ajenos" "env set web CLAVE valor" "${LANG_ARGS[*]}"
# Tras un '--' ya no hay banderas de Orbit, así que un valor que se llame
# '--lang' se puede guardar. Sin esto no había forma de escribirlo.
ORBIT_LANG_FLAG=""; LANG_MISSING="no"
_lang_strip env set web FLAGS -- --lang
check "'--' termina las banderas" "env set web FLAGS -- --lang" "${LANG_ARGS[*]}"
check "y no se lo queda"          ""    "$ORBIT_LANG_FLAG"
check "ni protesta"               "no"  "$LANG_MISSING"

section "Un salto de línea escrito en un mensaje tiene que salir como salto"
# '_t' no pasa la frase por el formateador cuando no lleva argumentos, y eso
# está bien razonado ahí mismo: dentro puede venir un '%' de un comando de
# build. La consecuencia es que el '\n' de la frase llega LITERAL, así que
# imprimirla con '%s' la saca tal cual por pantalla:
#
#   El build fue bien, así que esto no es tu código: se ha roto\n    algo…
#
# Salía así en los dos idiomas y en cuatro sitios, uno de ellos el mensaje que
# explica un primer despliegue fallido — justo cuando peor sienta. La regla,
# que ya cumplían los bloques de uso: una frase con '\n' se imprime con '%b'.
# '%b' interpreta las barras del argumento pero NO sus '%', así que no
# reintroduce el problema que '_t' evita.
CON_SALTO="$(awk 'NR<11000' "$ORBIT_SRC" | grep -nP 't "(?:[^"\\]|\\.)*\\n')"
check "hay mensajes con salto que vigilar" "1" \
  "$([[ -n "$CON_SALTO" ]] && echo 1 || echo 0)"
check "y todos se imprimen con %b" "" \
  "$(printf '%s\n' "$CON_SALTO" | grep -v '%b' | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')"

report
