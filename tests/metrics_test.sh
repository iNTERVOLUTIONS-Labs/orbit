#!/usr/bin/env bash
# Métricas de despliegue: el histórico que escribe cada 'orbit deploy' y lo que
# 'orbit metrics' saca de él.
#   bash tests/metrics_test.sh
# shellcheck disable=SC2034  # asigna variables A_* que lee el 'orbit' de lib.sh
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_root() { :; }
LOG_FILE="$TMP/orbit.log"
METRICS_FILE="$TMP/deploys.tsv"

# --- el histórico se escribe a mano para las lecturas ----------------------
# Las pruebas de lectura no despliegan nada: así se puede fabricar una tendencia
# de veinte builds sin esperar veinte builds, y lo que se comprueba es la
# aritmética, no el despliegue. El apunte de verdad se ejercita más abajo.
apunta() { # apunta <app> <estado> <total> <build> [sha] [paso] [notas]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" "$1" "$2" "$3" "$4" "r-$RANDOM" "${5:--}" "${6:--}" "${7:--}" \
    >> "$METRICS_FILE"
}

section "La mediana, y por qué no la media"
# Un build que normalmente tarda 30 s y una vez tardó 400 tiene una media que no
# describe ningún despliegue real. Por eso lo que se enseña es la mediana.
check "impares"       "30" "$(_med 30 10 400)"
check "con un pico"   "30" "$(_med 30 30 30 30 400)"
check "sin datos"     ""   "$(_med)"
check "ignora lo que no es número" "5" "$(_med 5 - '' abc)"

section "Sin histórico no se inventa nada"
run cmd_metrics >"$TMP/m0" 2>&1; r=$?
check "no falla"      "0" "$r"
check "y lo dice"     "1" "$(grep -c 'Todavía no hay ningún despliegue' "$TMP/m0")"

section "Cuenta despliegues y fallos por app"
mkapp web static "" web.test
mkapp api static "" api.test
for i in 1 2 3 4 5 6 7 8; do apunta web ok 10 20; done
apunta web fallo 3 - "" build "el build ha fallado"
apunta api ok 5 4
run cmd_metrics >"$TMP/m1" 2>&1; r=$?
check "termina bien"  "0" "$r"
check "web: total"    "1" "$(grep -cE '^ +web +9 ' "$TMP/m1")"
check "web: un fallo con su porcentaje" "1" "$(grep -c '1 (11%)' "$TMP/m1")"
check "api: sin fallos" "1" "$(grep -cE '^ +api +1 +0 ' "$TMP/m1")"
# El filtro es por columna exacta: un 'grep web' contaría también 'web-staging',
# y contar despliegues de otra app es peor que no contar ninguno.
mkapp web-staging static "" ws.test
apunta web-staging ok 99 99
run cmd_metrics >"$TMP/m2" 2>&1
check "no se mezcla con la parecida" "1" "$(grep -cE '^ +web +9 ' "$TMP/m2")"

section "La tendencia se calla cuando no hay datos para tenerla"
# Dos datos no son una tendencia, y fingirla es peor que callarse: alguien
# tomaría una decisión con ella.
rm -f "$METRICS_FILE"
for i in 1 2 3 4 5; do apunta web ok 10 10; done
check "con cinco builds, nada" "" "$(_metrics_trend web)"
apunta web ok 10 10
check "con seis, ya se puede"  "0" "$(_metrics_trend web)"
# Y cuando la hay, dice cuánto: los últimos tres tardan 20 s más que los tres
# primeros.
rm -f "$METRICS_FILE"
for i in 1 2 3; do apunta web ok 30 10; done
for i in 1 2 3; do apunta web ok 50 30; done
check "el build va a peor"     "20" "$(_metrics_trend web)"
rm -f "$METRICS_FILE"
for i in 1 2 3; do apunta web ok 50 30; done
for i in 1 2 3; do apunta web ok 30 10; done
check "y a mejor también"      "-20" "$(_metrics_trend web)"
# Un build que no llegó a terminar no deja tiempo, así que no entra en la
# mediana: si entrara como cero, un build roto parecería una mejora.
rm -f "$METRICS_FILE"
for i in 1 2 3; do apunta web ok 30 10; done
for i in 1 2 3; do apunta web fallo 1 - "" build; done
for i in 1 2 3; do apunta web ok 50 30; done
check "un build sin terminar no cuenta" "20" "$(_metrics_trend web)"
# Pero uno que **sí** terminó cuenta aunque el despliegue fallara después: lo
# que se mide es compilar, no desplegar. Un health check que tumba la release no
# hace que esos 30 s de build no hayan pasado.
rm -f "$METRICS_FILE"
for i in 1 2 3; do apunta web ok    30 10; done
for i in 1 2 3; do apunta web fallo 40 30 "" service; done
check "uno que sí terminó, sí"  "20" "$(_metrics_trend web)"

section "El contrato"
if ! command -v jq >/dev/null; then
  echo "  falta jq: me salto las comprobaciones de --json."
else
  rm -f "$METRICS_FILE"
  for i in 1 2 3 4 5 6; do apunta web ok 10 12; done
  apunta web fallo 2 - "" build
  apunta api ok 5 -
  JSON="yes"; _ui_route
  run cmd_metrics >"$TMP/j1" 2>/dev/null; r=$?
  JSON="no"; _ui_route
  check "termina bien"     "0"      "$r"
  check "una sola línea"   "1"      "$(wc -l < "$TMP/j1")"
  check "y es un objeto"   "object" "$(jq -r 'type' < "$TMP/j1")"
  check "cuenta los despliegues" "7" "$(jq -r '.apps[]|select(.app=="web")|.deploys' < "$TMP/j1")"
  check "y los fallos"           "1" "$(jq -r '.apps[]|select(.app=="web")|.failed' < "$TMP/j1")"
  check "la mediana del build"  "12" "$(jq -r '.apps[]|select(.app=="web")|.build_median_s' < "$TMP/j1")"
  # Sin datos suficientes, null y no cero: cero es un valor y significa «igual».
  check "sin tendencia, null" "null" "$(jq -r '.apps[]|select(.app=="api")|.build_trend_s' < "$TMP/j1")"
  # Una app sin paso de build no compila en cero segundos: no compila.
  check "sin build, null"     "null" "$(jq -r '.apps[]|select(.app=="api")|.build_median_s' < "$TMP/j1")"
fi

section "El apunte lo escribe el despliegue, y también cuando falla"
# Aquí sí se despliega de verdad: es la única forma de comprobar que la línea se
# escribe, que el build se cronometra aparte y que un fallo deja su motivo.
if ! command -v rsync >/dev/null; then
  echo "  falta rsync: me salto el despliegue de verdad."
else
  systemctl() { :; }; render_systemd() { :; }; render_nginx() { :; }; notify() { :; }
  as_deploy() { bash -lc "$*"; }
  as_app()    { bash -lc "$*"; }
  sudo() { while [[ "${1:-}" == -* ]]; do case "$1" in -u) shift 2 ;; --) shift; break ;; *) shift ;; esac; done; "$@"; }
  curl() { printf '200'; }
  rm -f "$METRICS_FILE"
  ORIGEN="$TMP/origen"; git init -q -b main "$ORIGEN"
  git -C "$ORIGEN" config user.email o@t; git -C "$ORIGEN" config user.name O
  printf '<h1>hola</h1>\n' > "$ORIGEN/index.html"
  git -C "$ORIGEN" add -A >/dev/null 2>&1; git -C "$ORIGEN" commit -qm v1

  mkapp real static "" real.test
  A_REPO="$ORIGEN"; A_BRANCH="main"; A_OUTDIR="."; A_BUILD="sleep 1"; save_app
  run cmd_deploy real >/dev/null 2>&1; r=$?
  check "el despliegue va bien"  "0" "$r"
  check "y deja una línea"       "1" "$(wc -l < "$METRICS_FILE")"
  linea="$(tail -n 1 "$METRICS_FILE")"
  check "nueve columnas"         "9" "$(awk -F'\t' '{print NF}' <<<"$linea")"
  check "la app"              "real" "$(cut -f2 <<<"$linea")"
  check "el resultado"          "ok" "$(cut -f3 <<<"$linea")"
  # El build se cronometra aparte del despliegue entero: es el número que crece
  # con el proyecto, y el resto —clonar, mover un symlink— es casi constante.
  check "el build se mide solo"  "1" "$([[ "$(cut -f5 <<<"$linea")" -ge 1 ]] && echo 1 || echo 0)"

  # Y se mide **sólo el build**, no todo lo que va antes. El retardo conocido va
  # *delante* del build, que es donde de verdad distingue: puesto detrás, los dos
  # números crecen igual y la prueba pasa con el cronómetro mal puesto. Lo dijo
  # mutar el código a «apunta el total» y ver que seguía en verde.
  rm -f "$METRICS_FILE"
  # el rsync es del builder desde el aislamiento por app: el retardo va en as_app
  as_app() { case "$*" in *rsync*) sleep 3 ;; esac; bash -lc "$*"; }
  git -C "$ORIGEN" commit -q --allow-empty -m v-lento
  run cmd_deploy real >/dev/null 2>&1
  as_app() { bash -lc "$*"; }
  linea="$(tail -n 1 "$METRICS_FILE")"
  check "el build no arrastra lo de antes" "1" \
    "$([[ "$(cut -f5 <<<"$linea")" -le 2 ]] && echo 1 || echo 0)"
  check "pero el total sí lo cuenta"       "1" \
    "$([[ "$(cut -f4 <<<"$linea")" -ge 4 ]] && echo 1 || echo 0)"

  # Un build que revienta: la línea tiene que estar igual, con el paso y el
  # motivo. Sin esto no se podría contar «cuántos han fallado», que es la mitad
  # de lo que pide la métrica.
  load_app real; A_BUILD="exit 3"; save_app
  git -C "$ORIGEN" commit -q --allow-empty -m v2
  run cmd_deploy real >/dev/null 2>&1; r=$?
  check "el despliegue falla"    "1" "$r"
  check "y también deja línea"   "2" "$(wc -l < "$METRICS_FILE")"
  linea="$(tail -n 1 "$METRICS_FILE")"
  check "apuntado como fallo" "fallo" "$(cut -f3 <<<"$linea")"
  check "con el paso"         "build" "$(cut -f8 <<<"$linea")"
  check "y el motivo"             "1" "$(cut -f9 <<<"$linea" | grep -c 'build')"
  # Un build que no llegó a terminar no tiene tiempo que comparar.
  check "sin tiempo de build"     "-" "$(cut -f5 <<<"$linea")"

  # Una app sin orden de build no compila en cero segundos: no compila. Se
  # despliega de verdad porque el guion lo pone el camino del 'else', y ese
  # camino no lo toca ninguna de las líneas escritas a mano de arriba.
  rm -f "$METRICS_FILE"
  mkapp nobuild static "" nobuild.test
  A_REPO="$ORIGEN"; A_BRANCH="main"; A_OUTDIR="."; A_BUILD=""; save_app
  run cmd_deploy nobuild >/dev/null 2>&1; r=$?
  check "sin build, despliega"    "0" "$r"
  check "y no apunta un tiempo"   "-" "$(cut -f5 < "$METRICS_FILE")"

  # Un tabulador o un salto de línea dentro de un campo partiría el registro en
  # dos, y el motivo viene de fuera.
  rm -f "$METRICS_FILE"
  DEP_ERR="$(printf 'con\ttabulador\ny salto')"; DEP_OK="no"; DEP_STEP="build"
  A_NAME="real"; DEP_T0=$SECONDS; DEP_REL=""; DEP_SHA=""
  DEP_ROLLBACK="no"; DEP_RECOVER="no"; DEP_BUILD_S=""
  _metrics_record
  check "una línea, no tres"      "1" "$(wc -l < "$METRICS_FILE")"
  check "y sigue con nueve columnas" "9" "$(awk -F'\t' '{print NF}' < "$METRICS_FILE")"

  # El histórico no crece sin fin.
  rm -f "$METRICS_FILE"
  METRICS_KEEP=10
  for i in $(seq 1 215); do apunta web ok 1 1; done
  _metrics_prune
  check "se poda a lo que se guarda" "10" "$(wc -l < "$METRICS_FILE")"
  # Y no se reescribe el fichero en cada despliegue: sólo cuando sobra de más.
  rm -f "$METRICS_FILE"
  for i in $(seq 1 12); do apunta web ok 1 1; done
  _metrics_prune
  check "con poco de más, no toca" "12" "$(wc -l < "$METRICS_FILE")"
fi

report
