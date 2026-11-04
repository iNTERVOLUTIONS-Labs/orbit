#!/usr/bin/env bash
# Las tres puertas del despliegue: congelar, rutas vigiladas y esperar a la CI.
#   bash tests/gates_test.sh
#
# Contra repositorios git de verdad, igual que autodeploy_test: lo que se
# comprueba es qué despliega y qué no, y eso sólo se ve mirando qué sirve
# 'current' al final. GitHub se dobla con un 'gh' de mentira en el PATH que
# devuelve respuestas con la forma de la API y pasa el filtro --jq por el jq de
# verdad — así el filtro que escribe Orbit se ejercita entero, y una errata en
# él pone esto en rojo en vez de pasar inadvertida.
#
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, CHECKS_GRACE…)
# que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for c in git rsync jq; do
  command -v "$c" >/dev/null || { echo "falta $c: me salto las pruebas de las puertas del despliegue."; exit 0; }
done

need_root()      { :; }
SYSCTL_LOG="$TMP/systemctl.log"; : > "$SYSCTL_LOG"
systemctl()      { printf '%s\n' "$*" >> "$SYSCTL_LOG"; [[ "${1:-}" == "is-active" ]] && return 1; return 0; }
render_systemd() { :; }
render_nginx()   { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }
health_wait()    { return 0; }
nginx()          { return 0; }
LOG_FILE="$TMP/orbit.log"
METRICS_FILE="$TMP/deploys.tsv"
NOTIFY_CONF="$TMP/notify.conf"
WATCH_STATE="$TMP/watch.state"
WATCH_LOCK="$TMP/watch.lock"
WATCH_LOG="$TMP/watch.log"
CONF_FILE="$TMP/etc/orbit.conf"

# El gh de mentira vive en el PATH de quien despliega. as_deploy sin '-l': una
# shell de login reharía el PATH desde /etc/profile y ~/.profile, y si en esta
# máquina hay un gh de verdad en ~/.local/bin, ganaría al doble y la prueba
# hablaría con GitHub.
mkdir -p "$TMP/bin" "$TMP/gh"
export PATH="$TMP/bin:$PATH"
GH_LOG="$TMP/gh.log"; : > "$GH_LOG"
export GH_LOG GH_DIR="$TMP/gh"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
# gh api [--paginate] <ruta> --jq <filtro>
printf '%s\n' "$*" >> "$GH_LOG"
[[ "${1:-}" == "api" ]] || { echo "gh doble: sólo sé 'api'" >&2; exit 2; }
shift
ruta="" jq_f="."
while (( $# )); do
  case "$1" in
    --paginate) shift ;;
    --jq) jq_f="$2"; shift 2 ;;
    *) ruta="$1"; shift ;;
  esac
done
if [[ -f "$GH_DIR/fail" ]]; then cat "$GH_DIR/fail" >&2; exit 1; fi
# Un efecto secundario a la carta: la prueba del commit fijado empuja un commit
# nuevo justo mientras Orbit pregunta a la CI.
[[ -f "$GH_DIR/hook" ]] && bash "$GH_DIR/hook"
case "$ruta" in
  *check-runs*) f="$GH_DIR/runs.json" ;;
  */status)     f="$GH_DIR/status.json" ;;
  *) echo "gh doble: ruta desconocida $ruta" >&2; exit 1 ;;
esac
jq -r "$jq_f" < "$f"
GH
chmod +x "$TMP/bin/gh"
as_deploy() { bash -c "$*"; }
as_app()    { bash -c "$*"; }
sudo() {
  while [[ "${1:-}" == -* ]]; do
    case "$1" in -u) shift 2 ;; --) shift; break ;; *) shift ;; esac
  done
  "$@"
}
# El repositorio «de GitHub» es local: git lo reescribe con insteadOf, así que
# A_REPO puede ser una URL de github.com —que es lo que mira la puerta de la
# CI— y el clon sale de una carpeta de aquí.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"; : > "$GIT_CONFIG_GLOBAL"

cat > "$NOTIFY_CONF" <<EOF
NOTIFY_MIN_LEVEL='info'
NOTIFY_WEBHOOK='https://avisos.test/hook'
EOF
: > "$TMP/notificaciones"
curl() { printf '%s\n' "$*" >> "$TMP/notificaciones"; return 0; }
avisos() { wc -l < "$TMP/notificaciones" | tr -d ' '; }

crear_repo() { # crear_repo <ruta>
  git init -q -b main "$1"
  git -C "$1" config user.email orbit@test
  git -C "$1" config user.name Orbit
  printf 'v1\n' > "$1/index.html"
  git -C "$1" add -A
  git -C "$1" commit -qm inicial
}
commit_en() { # commit_en <repo> <fichero> <contenido>
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -qm "$2: $3"
}
registrar() { # registrar <app> <repo>
  A_NAME="$1"; A_REPO="$2"; A_BRANCH="main"; A_DOMAIN="$1.test"; A_ALIASES=""
  A_TYPE="static"; A_PKG="pnpm"; A_BUILD=""; A_START=""; A_OUTDIR="."
  A_SPA="no"; A_PORT=""; A_DOCROOT=""; A_PYAPP=""; A_PYMGR=""; A_PYFW=""
  A_MIGRATE=""; A_STATIC_URL=""; A_STATIC_ROOT=""; A_MEDIA_URL=""
  A_MEDIA_ROOT=""; A_REDIRECT=""; A_REDIRECT_CODE=""; A_APPDIR="."
  A_AUTODEPLOY="yes"; A_AUTOFAIL=""; A_USER=""; A_QUEUE=""
  A_CHECKS=""; A_WATCH_SEEN=""; A_CI_SEEN=""
  A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
  save_app
}
sirve() { cat "$TMP/apps/$1/current/${2:-index.html}" 2>/dev/null; }
pasada() { # pasada <salida> [opciones de deploy --all]  -> deja el código en $r
  local out="$1"; shift
  run cmd_deploy_all "$@" >"$out" 2>&1; r=$?
}
pasada_json() { # pasada_json <salida> [opciones]
  local out="$1"; shift
  JSON="yes"; _ui_route
  run cmd_deploy_all "$@" >"$out" 2>"$out.err"; r=$?
  JSON="no"; _ui_route
}
estado() { jq -r --arg a "$2" '.apps[] | select(.app==$a) | .status' < "$1"; }

# ═══════════════════════════════════════════════════════ congelar ═════════
section "orbit lock deja un fichero que se lee con cat"
crear_repo "$TMP/repo-web"
registrar web "$TMP/repo-web"
run cmd_deploy web >/dev/null 2>&1; r=$?
check "el primer despliegue va"    "0"  "$r"
check "y sirve la v1"              "v1" "$(sirve web)"

SUDO_USER="dave"
run cmd_lock web -m $'Black Friday\nhasta el lunes' >"$TMP/l1" 2>&1; r=$?
check "congela"                    "0"  "$r"
LF="$(app_lockfile web)"
check "el fichero existe"          "1"  "$([[ -f "$LF" ]] && echo 1 || echo 0)"
check "al lado de la configuración" "$TMP/etc/apps/web.lock" "$LF"
check "con quién"                  "1"  "$(grep -cx 'by=dave' "$LF")"
check "con cuándo"                 "1"  "$(grep -cE '^at=[0-9]{4}-' "$LF")"
# Una línea: el motivo acaba en un aviso, en el fichero y dentro del JSON.
check "el motivo en una línea"     "1"  "$(grep -cx 'reason=Black Friday hasta el lunes' "$LF")"
check "dice cómo se levanta"       "1"  "$(grep -c 'orbit unlock web' "$TMP/l1")"
check "y que el rollback sigue"    "1"  "$(grep -c 'rollback sigue permitido' "$TMP/l1")"
# No vive en la configuración: un despliegue largo guarda la suya entera al
# acabar (save_app) y se habría llevado por delante una congelación puesta a
# mitad. Se comprueba guardando la app después de congelarla.
load_app web; save_app
check "save_app no la toca"        "1"  "$([[ -f "$LF" ]] && echo 1 || echo 0)"
check "ni aparece en el .conf"     "0"  "$(grep -ci 'lock' "$(app_conf web)")"

section "Congelada, 'orbit deploy' se niega, sin tocar nada ni contarlo como fallo"
commit_en "$TMP/repo-web" index.html v2
: > "$METRICS_FILE"
run cmd_deploy web >"$TMP/l2" 2>&1; r=$?
check "se niega"                   "1"  "$r"
check "producción intacta"         "v1" "$(sirve web)"
check "dice quién"                 "1"  "$(grep -c 'por dave' "$TMP/l2")"
check "dice por qué"               "1"  "$(grep -c 'Black Friday' "$TMP/l2")"
check "y cómo forzarlo"            "1"  "$(grep -c 'orbit deploy web --force' "$TMP/l2")"
# Negarse no es un despliegue fallido: 'orbit metrics' contaría como roto lo
# que nunca empezó.
check "no se apunta en métricas"   "0"  "$(grep -c . "$METRICS_FILE")"

JSON="yes"; _ui_route
run cmd_deploy web >"$TMP/l2j" 2>/dev/null; r=$?
JSON="no"; _ui_route
check "con --json también"         "1"  "$r"
check "y contesta con un objeto"   "false" "$(jq -r '.ok' < "$TMP/l2j")"
check "que dice el motivo"         "1"  "$(jq -r '.error' < "$TMP/l2j" | grep -c 'Black Friday')"

run cmd_deploy web --force >"$TMP/l3" 2>&1; r=$?
check "--force despliega"          "0"  "$r"
check "la v2"                      "v2" "$(sirve web)"
check "avisando"                   "1"  "$(grep -c 'has puesto --force' "$TMP/l3")"
check "y sigue congelada"          "1"  "$([[ -f "$LF" ]] && echo 1 || echo 0)"

section "Congelada, el rollback sí se permite"
# Es la salida de emergencia: una congelación que la bloqueara obligaría a
# levantarla en mitad de un incidente.
v1rel="$(releases_desc "$TMP/apps/web" | tail -1)"
run cmd_rollback web "$v1rel" >"$TMP/l4" 2>&1; r=$?
check "vuelve atrás"               "0"  "$r"
check "a la v1"                    "v1" "$(sirve web)"
check "y lo dice"                  "1"  "$(grep -c 'el rollback sí se permite' "$TMP/l4")"

section "Congelada, 'deploy --all' y el automático la saltan"
crear_repo "$TMP/repo-otra"
registrar otra "$TMP/repo-otra"
run cmd_deploy otra >/dev/null 2>&1
commit_en "$TMP/repo-web" index.html v3
commit_en "$TMP/repo-otra" index.html v2
pasada "$TMP/a1" --auto
check "la pasada sale bien"        "0"  "$r"
check "la congelada no se toca"    "v1" "$(sirve web)"
check "la otra sí se despliega"    "v2" "$(sirve otra)"
check "el resumen la cuenta"       "1"  "$(grep -c '1 congeladas' "$TMP/a1")"
commit_en "$TMP/repo-otra" index.html v3
pasada_json "$TMP/a1j" --auto
check "estado locked"              "locked"   "$(estado "$TMP/a1j" web)"
check "con su motivo"              "1"  "$(jq -r '.apps[]|select(.app=="web")|.error' < "$TMP/a1j" | grep -c 'Black Friday')"
check "sin objeto de despliegue"   "null" "$(jq -r '.apps[]|select(.app=="web")|.result|type' < "$TMP/a1j")"
check "recuento locked"            "1"  "$(jq -r '.locked' < "$TMP/a1j")"
check "el total cuadra"            "1"  "$(jq -r 'if .total == (.apps|length) then 1 else 0 end' < "$TMP/a1j")"
# Congelar es una decisión, no una avería: la pasada no se pone en rojo.
check "ok sigue en true"           "true" "$(jq -r '.ok' < "$TMP/a1j")"
# Y un 'deploy --all' a secas —sin --if-changed— tampoco la despliega.
pasada "$TMP/a2"
check "--all a secas la salta"     "v1" "$(sirve web)"

section "Se enseña donde se mira"
run cmd_info web >"$TMP/i1" 2>&1
check "info lo dice"               "1"  "$(grep -c 'Despliegues .*congelada desde .*Black Friday' "$TMP/i1")"
JSON="yes"
run cmd_info web >"$TMP/i1j" 2>/dev/null
check "info --json: locked"        "true" "$(jq -r '.app.state.locked' < "$TMP/i1j")"
check "con quién"                  "dave" "$(jq -r '.app.state.lock.by' < "$TMP/i1j")"
check "y el motivo"                "Black Friday hasta el lunes" "$(jq -r '.app.state.lock.reason' < "$TMP/i1j")"
run cmd_list >"$TMP/i2j" 2>/dev/null
check "list --json: la congelada"  "true"  "$(jq -r '.apps[]|select(.name=="web")|.state.locked' < "$TMP/i2j")"
check "y la que no"                "false" "$(jq -r '.apps[]|select(.name=="otra")|.state.locked' < "$TMP/i2j")"
# Lo que no existe es null (§13.1), no un objeto vacío.
check "sin congelar, lock es null" "null"  "$(jq -r '.apps[]|select(.name=="otra")|.state.lock|type' < "$TMP/i2j")"
JSON="no"
run cmd_list >"$TMP/i3" 2>&1
check "list marca la congelada"    "1"  "$(grep -E '^  web ' "$TMP/i3" | grep -c 'congelada')"
check "y no la otra"               "0"  "$(grep -E '^  otra ' "$TMP/i3" | grep -c 'congelada')"
_watch_state_load
run cmd_autodeploy status >"$TMP/i4" 2>&1
check "autodeploy status también"  "1"  "$(grep -c 'congelada' "$TMP/i4")"

section "Un 'touch' a mano también congela"
# Lo que manda es que el fichero exista (principio 5): el contenido es para
# contar quién y por qué, y sin él se dice null en vez de inventarlo.
: > "$(app_lockfile otra)"
JSON="yes"
run cmd_info otra >"$TMP/t1j" 2>/dev/null
JSON="no"
check "cuenta como congelada"      "true" "$(jq -r '.app.state.locked' < "$TMP/t1j")"
check "sin quién: null"            "null" "$(jq -r '.app.state.lock.by|type' < "$TMP/t1j")"
run cmd_deploy otra >/dev/null 2>&1; r=$?
check "y frena el despliegue"      "1"  "$r"
rm -f "$(app_lockfile otra)"

section "orbit unlock"
run cmd_unlock web >"$TMP/u1" 2>&1; r=$?
check "descongela"                 "0"  "$r"
check "borra el fichero"           "0"  "$([[ -f "$LF" ]] && echo 1 || echo 0)"
run cmd_unlock web >"$TMP/u2" 2>&1; r=$?
check "dos veces no es un error"   "0"  "$r"
check "y lo dice"                  "1"  "$(grep -c 'no estaba congelada' "$TMP/u2")"
pasada "$TMP/u3" --auto
check "y vuelve a desplegarse"     "v3" "$(sirve web)"
run cmd_lock web extra sobra >/dev/null 2>&1; r=$?
check "un argumento de más falla"  "1"  "$r"
run cmd_lock web --inventada >/dev/null 2>&1; r=$?
check "y una opción que no existe" "1"  "$r"
run cmd_lock no-existe >/dev/null 2>&1; r=$?
check "y una app que no existe"    "1"  "$r"

section "La congelación es de esta app y de este momento"
run cmd_lock web "copia" >/dev/null 2>&1
# Un clon nace sin ella: hereda la configuración, y esto no está ahí.
_maint_on() { :; }
run cmd_clone web web-staging --domain staging.web.test >/dev/null 2>&1; r=$?
check "el clon se crea"            "0"  "$r"
check "y nace sin congelar"        "0"  "$([[ -f "$(app_lockfile web-staging)" ]] && echo 1 || echo 0)"
# Ni viaja en una copia: restaurarla semanas después traería una congelación
# que nadie recuerda.
_db_exists() { return 1; }
BACKUP_DIR="$TMP/backups"; mkdir -p "$BACKUP_DIR"
bk="$(run _backup_one web 2>/dev/null | tail -1)"
check "la copia existe"            "1"  "$([[ -f "$bk" ]] && echo 1 || echo 0)"
check "y no lleva la congelación"  "0"  "$(tar -tzf "$bk" 2>/dev/null | grep -c 'lock')"
# Y se va con la app.
run cmd_remove web-staging -y >/dev/null 2>&1
run cmd_lock web-staging >/dev/null 2>&1   # ya no existe: no crea nada
run cmd_remove web -y >/dev/null 2>&1; r=$?
check "remove termina"             "0"  "$r"
check "y se lleva la congelación"  "0"  "$([[ -f "$LF" ]] && echo 1 || echo 0)"
check "sin dejar la de un clon"    "0"  "$([[ -f "$(app_lockfile web-staging)" ]] && echo 1 || echo 0)"
rm -f "$(app_conf otra)"

# ═══════════════════════════════════════════════ rutas vigiladas ══════════
section "_watch_match: una ruta cubre lo suyo y nada más"
_watch_match "backend/app.py"      backend;         check "dentro"            "0" "$?"
_watch_match "backend"             backend;         check "ella misma"        "0" "$?"
_watch_match "backend2/app.py"     backend;         check "un prefijo no vale" "1" "$?"
_watch_match "docs/x.md"           backend packages/shared; check "fuera"     "1" "$?"
_watch_match "packages/shared/a.ts" backend packages/shared; check "la segunda" "0" "$?"

section "Un commit fuera de las rutas vigiladas no despliega"
crear_repo "$TMP/repo-mono"
mkdir -p "$TMP/repo-mono/backend" "$TMP/repo-mono/docs"
printf 'api v1\n' > "$TMP/repo-mono/backend/api.txt"
printf '{"type":"static","watch":["backend/", "./packages/shared"]}\n' > "$TMP/repo-mono/orbit.json"
git -C "$TMP/repo-mono" add -A; git -C "$TMP/repo-mono" commit -qm estructura
registrar mono "$TMP/repo-mono"
pasada "$TMP/w0" --auto
check "despliega la primera vez"   "api v1" "$(sirve mono backend/api.txt)"

: > "$TMP/fetches"
as_deploy() { [[ "$*" == *"--no-write-fetch-head"* ]] && echo x >> "$TMP/fetches"; bash -c "$*"; }
commit_en "$TMP/repo-mono" docs/guia.md "docs v2"
pasada_json "$TMP/w1" --auto
check "la pasada sale bien"        "0"       "$r"
check "estado ignored"             "ignored" "$(estado "$TMP/w1" mono)"
check "recuento ignored"           "1"       "$(jq -r '.ignored' < "$TMP/w1")"
check "no ha desplegado"           ""        "$(sirve mono docs/guia.md)"
check "lo dice una vez"            "1"       "$(grep -c 'no tocan las rutas vigiladas' "$TMP/w1.err")"
load_app mono
check "apunta el commit visto"     "1"       "$([[ "$A_WATCH_SEEN" == "$(git -C "$TMP/repo-mono" rev-parse HEAD) "* ]] && echo 1 || echo 0)"
check "ha hecho un fetch"          "1"       "$(grep -c . "$TMP/fetches")"
# La segunda pasada con el mismo remoto no vuelve a traer nada ni a decirlo:
# el temporizador pasa cada minuto.
pasada_json "$TMP/w2" --auto
check "sigue ignored"              "ignored" "$(estado "$TMP/w2" mono)"
check "sin otro fetch"             "1"       "$(grep -c . "$TMP/fetches")"
check "ni otra línea"              "0"       "$(grep -c 'no tocan las rutas vigiladas' "$TMP/w2.err")"

section "Un commit dentro sí, y con todo lo de antes"
# El diff es contra lo DESPLEGADO, no contra lo visto: el cambio de docs que se
# saltó también llega ahora, porque viaja en el mismo árbol.
commit_en "$TMP/repo-mono" backend/api.txt "api v2"
pasada "$TMP/w3" --auto
check "despliega"                  "api v2"  "$(sirve mono backend/api.txt)"
check "con lo saltado dentro"      "docs v2" "$(sirve mono docs/guia.md)"
commit_en "$TMP/repo-mono" packages/shared/lib.ts "lib v1"
pasada "$TMP/w4" --auto
check "la segunda ruta (con ./) también" "lib v1" "$(sirve mono packages/shared/lib.ts)"
commit_en "$TMP/repo-mono" packages/sharedx/a.ts "parecida"
pasada "$TMP/w4b" --auto
check "una hermana con el mismo prefijo no" "" "$(sirve mono packages/sharedx/a.ts)"
# El orbit.json se vigila siempre: es donde se declara qué se vigila.
printf '{"type":"static","watch":["backend/"],"x":1}\n' > "$TMP/repo-mono/orbit.json"
git -C "$TMP/repo-mono" commit -qam "solo el descriptor"
pasada "$TMP/w5" --auto
check "cambiar orbit.json despliega" "1"    "$(grep -c '"x":1' "$TMP/apps/mono/current/orbit.json")"

section "Ante la duda, desplegar"
# Una ruta que no vale no estrecha lo vigilado en silencio: se avisa y se
# despliega sin filtrar.
printf '{"type":"static","watch":["backend/", "../fuera"]}\n' > "$TMP/repo-mono/orbit.json"
git -C "$TMP/repo-mono" commit -qam "watch malo"
commit_en "$TMP/repo-mono" docs/otra.md "con watch malo"
pasada "$TMP/w6" --auto
check "despliega sin filtrar"      "con watch malo" "$(sirve mono docs/otra.md)"
check "y avisa"                    "1"   "$(grep -c "'watch' trae rutas que no son del repositorio" "$TMP/w6")"
printf '{"type":"static","watch":"backend/"}\n' > "$TMP/repo-mono/orbit.json"
git -C "$TMP/repo-mono" commit -qam "watch que no es lista"
commit_en "$TMP/repo-mono" docs/tres.md "no es lista"
pasada "$TMP/w6b" --auto
check "una cadena suelta tampoco filtra" "no es lista" "$(sirve mono docs/tres.md)"
# Sin "watch", todo despliega, que es como ha sido siempre.
printf '{"type":"static"}\n' > "$TMP/repo-mono/orbit.json"
git -C "$TMP/repo-mono" commit -qam "sin watch"
commit_en "$TMP/repo-mono" docs/cuatro.md "sin watch"
pasada "$TMP/w6c" --auto
check "sin watch no se filtra"     "sin watch" "$(sirve mono docs/cuatro.md)"
printf '{"type":"static","watch":[]}\n' > "$TMP/repo-mono/orbit.json"
git -C "$TMP/repo-mono" commit -qam "watch vacío"
commit_en "$TMP/repo-mono" docs/cinco.md "vacía"
pasada "$TMP/w6d" --auto
check "una lista vacía tampoco"    "vacía" "$(sirve mono docs/cinco.md)"
# Si el commit desplegado ya no está en la caché —un force-push, una caché
# rehecha— no se puede saber qué ha cambiado: se despliega.
printf '{"type":"static","watch":["backend/"]}\n' > "$TMP/repo-mono/orbit.json"
git -C "$TMP/repo-mono" commit -qam "watch otra vez"
pasada "$TMP/w7" --auto
commit_en "$TMP/repo-mono" docs/seis.md "commit desconocido"
load_app mono; A_LASTDEPLOY="2026-01-01T00:00:00+00:00 0123456"; save_app
pasada "$TMP/w7b" --auto
check "un desplegado que no existe despliega" "commit desconocido" "$(sirve mono docs/seis.md)"
# Y si hay un despliegue en curso, no se toca su caché: que decida él.
commit_en "$TMP/repo-mono" docs/siete.md "con cerrojo"
load_app mono
exec {LOCKFD}>"$DEPLOY_LOCK_DIR/mono.lock"; flock -n "$LOCKFD"
_watch_gate "$(git -C "$TMP/repo-mono" rev-parse HEAD)"; r=$?
exec {LOCKFD}>&-
check "con el cerrojo puesto, desplegar" "0"       "$r"
check "porque no ha podido mirar"        "unknown" "$WATCH_NOTE"

section "Lo visto deja de valer si cambia lo desplegado"
# El par «nuevo desplegado»: si alguien despliega otra cosa a mano, lo que se
# comparó ya no es lo que hay en producción.
pasada "$TMP/w8" --auto
commit_en "$TMP/repo-mono" docs/ocho.md "visto"
pasada "$TMP/w8b" --auto
load_app mono; visto="$A_WATCH_SEEN"
check "queda visto"                "1" "$([[ -n "$visto" ]] && echo 1 || echo 0)"
A_LASTDEPLOY="2026-01-01T00:00:00+00:00 0123456"; save_app
pasada "$TMP/w8c" --auto
check "con otro desplegado, se vuelve a mirar" "visto" "$(sirve mono docs/ocho.md)"

section "A mano y con --all a secas, siempre se despliega"
pasada "$TMP/w9" --auto
commit_en "$TMP/repo-mono" docs/nueve.md "a mano"
run cmd_deploy mono >/dev/null 2>&1; r=$?
check "orbit deploy a mano"        "a mano" "$(sirve mono docs/nueve.md)"
commit_en "$TMP/repo-mono" docs/diez.md "todas"
pasada "$TMP/w10"
check "deploy --all sin --if-changed" "todas" "$(sirve mono docs/diez.md)"
commit_en "$TMP/repo-mono" docs/once.md "si cambia"
pasada "$TMP/w11" --if-changed
check "--if-changed sí filtra"     "" "$(sirve mono docs/once.md)"

section "La carpeta de la app se vigila aunque no se nombre"
# Olvidarse de poner la propia carpeta es el error evidente, y su síntoma sería
# no desplegar nunca. Y las rutas son del repositorio, también en el orbit.json
# de la subcarpeta: 'packages/ui' es hermana de la app, no hija.
crear_repo "$TMP/repo-sub"
mkdir -p "$TMP/repo-sub/apps/web" "$TMP/repo-sub/packages/ui" "$TMP/repo-sub/docs"
printf 'web v1\n' > "$TMP/repo-sub/apps/web/index.html"
printf '{"type":"static","watch":["packages/ui"]}\n' > "$TMP/repo-sub/apps/web/orbit.json"
git -C "$TMP/repo-sub" add -A; git -C "$TMP/repo-sub" commit -qm estructura
registrar sub "$TMP/repo-sub"
load_app sub; A_APPDIR="apps/web"; save_app
pasada "$TMP/s0" --auto
commit_en "$TMP/repo-sub" docs/a.md "fuera"
pasada_json "$TMP/s1" --auto
check "fuera de todo, ignored"     "ignored" "$(estado "$TMP/s1" sub)"
commit_en "$TMP/repo-sub" packages/ui/b.ts "ui"
pasada "$TMP/s2" --auto
check "la ruta del descriptor de la subcarpeta, desde la raíz" "ui" "$(sirve sub packages/ui/b.ts)"
commit_en "$TMP/repo-sub" apps/web/index.html "web v2"
pasada "$TMP/s3" --auto
check "y la carpeta de la app"     "web v2" "$(sirve sub apps/web/index.html)"
rm -f "$(app_conf mono)" "$(app_conf sub)"
as_deploy() { bash -c "$*"; }

# ═══════════════════════════════════════════════════ la CI ════════════════
section "_gh_slug: sólo GitHub, y en sus cuatro formas"
check "https"            "acme/web" "$(_gh_slug https://github.com/acme/web)"
check "https con .git"   "acme/web" "$(_gh_slug https://github.com/acme/web.git)"
check "https con token"  "acme/web" "$(_gh_slug https://x-access-token:abc@github.com/acme/web.git)"
check "ssh corto"        "acme/web" "$(_gh_slug git@github.com:acme/web.git)"
check "ssh largo"        "acme/web" "$(_gh_slug ssh://git@github.com/acme/web)"
_gh_slug https://gitlab.com/acme/web >/dev/null;          check "gitlab no"            "1" "$?"
_gh_slug https://github.com.evil.test/acme/web >/dev/null; check "un dominio que lo imita no" "1" "$?"
_gh_slug https://evil.test/github.com/acme/web >/dev/null; check "ni metido en la ruta"   "1" "$?"
_gh_slug /srv/repos/web >/dev/null;                        check "ni una carpeta"         "1" "$?"

# Las respuestas, con la forma de la API de verdad.
runs() { # runs <estado:conclusión:nombre>…
  local x sep="" st co nm
  printf '{"total_count":%s,"check_runs":[' "$#"
  for x in "$@"; do
    IFS=: read -r st co nm <<<"$x"
    printf '%s{"name":"%s","status":"%s","conclusion":%s}' "$sep" "$nm" "$st" \
      "$([[ -n "$co" ]] && printf '"%s"' "$co" || printf 'null')"
    sep=","
  done
  printf ']}\n'
}
statuses() { # statuses <estado:contexto>…
  local x sep="" st cx
  printf '{"state":"pending","total_count":%s,"statuses":[' "$#"
  for x in "$@"; do
    IFS=: read -r st cx <<<"$x"
    printf '%s{"state":"%s","context":"%s"}' "$sep" "$st" "$cx"; sep=","
  done
  printf ']}\n'
}
ci() { runs "$@" > "$GH_DIR/runs.json"; }
st() { statuses "$@" > "$GH_DIR/status.json"; }
SHA=0123456789abcdef0123456789abcdef01234567

section "_ci_state: lo que dice GitHub, en cinco respuestas"
ci completed:success:build completed:success:lint; st
_ci_state acme/web "$SHA"; check "todo en verde"         "success" "$CI_STATE"
ci completed:success:build completed:neutral:sonar completed:skipped:deploy-preview; st
_ci_state acme/web "$SHA"; check "neutras y saltadas valen" "success" "$CI_STATE"
ci completed:success:build in_progress::e2e queued::lint; st
_ci_state acme/web "$SHA"; check "alguna sin terminar"   "pending" "$CI_STATE"
check "y cuáles"         "e2e, lint" "$CI_WHY"
ci completed:success:build completed:failure:tests in_progress::e2e; st
_ci_state acme/web "$SHA"; check "una roja gana a una pendiente" "failure" "$CI_STATE"
check "y nombra la roja" "tests" "$CI_WHY"
ci completed:cancelled:build; st
_ci_state acme/web "$SHA"; check "cancelada cuenta como roja" "failure" "$CI_STATE"
# Los statuses —Jenkins, Buildkite, un CI propio— cuentan igual que las check
# runs. El "state" combinado de la API dice "pending" con cero statuses, y por
# eso no se mira: se mira cada uno.
ci; st success:ci/jenkins
_ci_state acme/web "$SHA"; check "un status verde"       "success" "$CI_STATE"
ci; st error:ci/jenkins
_ci_state acme/web "$SHA"; check "un status en error es rojo" "failure" "$CI_STATE"
ci completed:success:build; st pending:ci/buildkite
_ci_state acme/web "$SHA"; check "mezcla con uno pendiente" "pending" "$CI_STATE"
ci; st
_ci_state acme/web "$SHA"; check "ninguna"               "none"    "$CI_STATE"
printf 'HTTP 401: Bad credentials (https://api.github.com/repos/acme/web/commits)\n' > "$GH_DIR/fail"
_ci_state acme/web "$SHA"; check "gh falla → error"      "error"   "$CI_STATE"
check "con lo que dijo gh" "1" "$(grep -c '^HTTP 401' <<<"$CI_WHY")"
rm -f "$GH_DIR/fail"
check "pregunta por el commit" "1" "$(grep -q "repos/acme/web/commits/$SHA/check-runs" "$GH_LOG" && echo 1 || echo 0)"

section "La pasada espera a la CI"
crear_repo "$TMP/repo-ci"
printf '[url "%s"]\n\tinsteadOf = https://github.com/acme/ci\n' "$TMP/repo-ci" > "$GIT_CONFIG_GLOBAL"
registrar app "https://github.com/acme/ci"
run cmd_autodeploy checks on app >"$TMP/c0" 2>&1; r=$?
check "se activa"                  "0"   "$r"
load_app app
check "queda en la configuración"  "yes" "$A_CHECKS"
check "nombra el repositorio"      "1"   "$(grep -c 'acme/ci' "$TMP/c0")"
ci completed:success:build; st
pasada "$TMP/c1" --auto
check "en verde despliega"         "v1"  "$(sirve app)"

commit_en "$TMP/repo-ci" index.html v2
ci completed:success:build in_progress::tests; st
: > "$TMP/notificaciones"
pasada_json "$TMP/c2" --auto
check "pendiente no despliega"     "v1"         "$(sirve app)"
check "estado ci_pending"          "ci_pending" "$(estado "$TMP/c2" app)"
check "dice qué falta"             "tests"      "$(jq -r '.apps[0].error' < "$TMP/c2")"
check "la pasada no falla"         "0"          "$r"
check "ni avisa"                   "0"          "$(avisos)"

ci completed:failure:tests; st
pasada_json "$TMP/c3" --auto
check "roja no despliega"          "v1"        "$(sirve app)"
check "estado ci_failed"           "ci_failed" "$(estado "$TMP/c3" app)"
check "la pasada no falla"         "0"         "$r"
check "ok sigue en true"           "true"      "$(jq -r '.ok' < "$TMP/c3")"
check "avisa una vez"              "1"         "$(avisos)"
pasada "$TMP/c3b" --auto
pasada "$TMP/c3c" --auto
check "y no repite"                "1"         "$(avisos)"
run cmd_autodeploy status >"$TMP/c3s" 2>&1
check "status lo enseña"           "1"         "$(grep -c 'ha fallado; espero uno que pase' "$TMP/c3s")"
# Otro commit rojo es otra transición: si el estado no llevara el commit, el
# segundo pasaría callado.
commit_en "$TMP/repo-ci" index.html v3
pasada "$TMP/c4" --auto
check "otro commit rojo, otro aviso" "2"       "$(avisos)"

ci completed:success:tests; st
pasada "$TMP/c5" --auto
check "en verde, despliega"        "v3"  "$(sirve app)"
check "y avisa de la vuelta"       "3"   "$(avisos)"
check "nombrando la CI"            "1"   "$(tail -1 "$TMP/notificaciones" | grep -c 'vuelve a estar en verde')"

section "Sin poder preguntar, no se despliega y la pasada falla"
commit_en "$TMP/repo-ci" index.html v4
printf 'error connecting to api.github.com\n' > "$GH_DIR/fail"
: > "$TMP/notificaciones"
pasada_json "$TMP/c6" --auto
check "no despliega"               "v3"         "$(sirve app)"
check "estado ci_unknown"          "ci_unknown" "$(estado "$TMP/c6" app)"
check "con el motivo"              "1"          "$(jq -r '.apps[0].error' < "$TMP/c6" | grep -c 'api.github.com')"
# Una puerta que no puede preguntar no abre, y eso tiene que verse: si no, el
# autodespliegue se pararía en verde.
check "la pasada falla"            "1"          "$r"
check "ok en false"                "false"      "$(jq -r '.ok' < "$TMP/c6")"
check "recuento ci_unknown"        "1"          "$(jq -r '.ci_unknown' < "$TMP/c6")"
check "avisa"                      "1"          "$(avisos)"
pasada "$TMP/c6b" --auto
check "una vez"                    "1"          "$(avisos)"
check "y el resumen lo explica"    "1"          "$(grep -c 'Sin respuesta de GitHub' "$TMP/c6b")"
run cmd_autodeploy status >"$TMP/c6s" 2>&1
check "status lo enseña"           "1"          "$(grep -c 'no consigo preguntar a GitHub' "$TMP/c6s")"
rm -f "$GH_DIR/fail"

section "Sin ninguna comprobación, se despliega pasada la gracia"
# GitHub tarda unos segundos en registrar las comprobaciones de un push: una
# pasada que llegara en ese hueco desplegaría justo lo que la puerta retiene.
ci; st
CHECKS_GRACE=3600
pasada_json "$TMP/c7" --auto
check "la primera vez espera"      "ci_pending" "$(estado "$TMP/c7" app)"
check "y no despliega"             "v3"         "$(sirve app)"
load_app app
check "apunta cuándo lo vio"       "1" "$([[ "$A_CI_SEEN" == "$(git -C "$TMP/repo-ci" rev-parse HEAD) "* ]] && echo 1 || echo 0)"
# Pasada la gracia (aquí, haciendo viejo el apunte), se despliega y se dice.
A_CI_SEEN="${A_CI_SEEN%% *} 1000"; save_app
pasada "$TMP/c8" --auto
check "pasada la gracia, despliega" "v4"        "$(sirve app)"
check "y lo dice"                  "1"          "$(grep -c 'no tiene comprobaciones en GitHub' "$TMP/c8")"
CHECKS_GRACE=300

section "Se despliega el commit que ha pasado, aunque la rama avance"
# Entre la pregunta a la CI y el fetch del despliegue alguien empuja otro
# commit. Desplegar la punta sería desplegar uno que nadie ha comprobado.
commit_en "$TMP/repo-ci" index.html v5
COMPROBADO="$(git -C "$TMP/repo-ci" rev-parse HEAD)"
ci completed:success:build; st
cat > "$GH_DIR/hook" <<EOF
[[ -f "$GH_DIR/hook.done" ]] && exit 0
: > "$GH_DIR/hook.done"
printf 'v6 sin comprobar\n' > "$TMP/repo-ci/index.html"
git -C "$TMP/repo-ci" commit -qam v6
EOF
pasada "$TMP/c9" --auto
rm -f "$GH_DIR/hook" "$GH_DIR/hook.done"
check "sirve el comprobado"        "v5"  "$(sirve app)"
load_app app
check "y lo apunta como desplegado" "${COMPROBADO:0:7}" "$(_deployed_sha)"
# Y la carrera ha ocurrido de verdad: si el doble no hubiera empujado nada, la
# prueba pasaría igual sin el commit fijado.
check "la rama sí había avanzado"  "v6 sin comprobar" "$(git -C "$TMP/repo-ci" show HEAD:index.html)"
# El nuevo se comprueba en la pasada siguiente, como cualquier otro.
ci completed:failure:build; st
pasada "$TMP/c9b" --auto
check "el de detrás, rojo, no entra" "v5" "$(sirve app)"

section "'deploy --all' a secas también espera; a mano, no"
pasada_json "$TMP/c10"
check "--all a secas: ci_failed"   "ci_failed" "$(estado "$TMP/c10" app)"
check "y no despliega"             "v5"        "$(sirve app)"
run cmd_deploy app >"$TMP/c11" 2>&1; r=$?
check "a mano despliega"           "0"         "$r"
check "el rojo"                    "v6 sin comprobar" "$(sirve app)"
check "pero avisa"                 "1"         "$(grep -c 'La CI de este commit ha fallado (build)' "$TMP/c11")"

section "orbit autodeploy checks"
run cmd_autodeploy checks app >"$TMP/k1" 2>&1
check "sin on ni off, dice cómo está" "1" "$(grep -c 'con la CI de GitHub en verde' "$TMP/k1")"
run cmd_autodeploy checks app off >/dev/null 2>&1; r=$?
load_app app
check "off (en cualquier orden)"   "no"  "$A_CHECKS"
commit_en "$TMP/repo-ci" index.html v7
ci completed:failure:build; st
pasada "$TMP/k2" --auto
check "sin la puerta, el rojo entra" "v7" "$(sirve app)"
: > "$GH_LOG"
run cmd_deploy app --force >/dev/null 2>&1
check "y a mano ni se pregunta"    "0"   "$(grep -c . "$GH_LOG")"
registrar fuera "$TMP/repo-otra"
run cmd_autodeploy checks on fuera >"$TMP/k3" 2>&1; r=$?
check "fuera de GitHub se niega"   "1"   "$r"
check "diciendo por qué"           "1"   "$(grep -c 'Sólo sé preguntar por la CI a GitHub' "$TMP/k3")"
# Y si alguien la enciende a mano en el .conf de un repositorio que no es de
# GitHub, la puerta no abre: no puede preguntar.
load_app fuera; A_CHECKS="yes"; save_app
load_app app; A_AUTODEPLOY="no"; save_app
commit_en "$TMP/repo-otra" index.html "fuera v9"
pasada_json "$TMP/k4" --auto
check "no es GitHub: ci_unknown"   "ci_unknown" "$(estado "$TMP/k4" fuera)"
check "y no despliega"             "1"  "$([[ "$(sirve fuera)" != "fuera v9" ]] && echo 1 || echo 0)"

# ═══════════════════════════════════════════ por el router de verdad ══════
section "Los comandos nuevos llegan por la línea de órdenes"
# Lo de arriba llama a las funciones; esto pasa por main(), que es donde un
# comando sin registrar o un --json mal criado se notan. Misma copia que
# cli_test: ETC_DIR redirigido y sin auto-elevación.
sed "s|^ETC_DIR=.*|ETC_DIR=\"$TMP/etc\"|; \
     s|^LOG_FILE=.*|LOG_FILE=\"$TMP/orbit.log\"|; \
     s|^if \[\[ \$EUID -ne 0 \]\]; then|if false; then|; \
     s|^need_root() {.*|need_root() { return 0; }|" \
    "$ORBIT_ROOT/orbit" > "$TMP/orbitcli"
chmod +x "$TMP/orbitcli"
O="$TMP/orbitcli"
"$O" lock app -m "desde la CLI" >/dev/null 2>&1; r=$?
check "orbit lock"                 "0" "$r"
check "deja el fichero"            "1" "$(grep -cx 'reason=desde la CLI' "$(app_lockfile app)")"
check "list --json lo publica"     "true" "$("$O" --json list 2>/dev/null | jq -r '.apps[]|select(.name=="app")|.state.locked')"
# lock/unlock no hablan JSON, como maintenance on/off: el estado se lee de
# 'info --json'. Aceptar --json y contestar prosa sería lo peor de las tres.
"$O" --json lock app >"$TMP/cli1" 2>/dev/null; r=$?
check "--json se rechaza"          "1" "$r"
check "sin nada en stdout"         "0" "$(grep -c . "$TMP/cli1")"
"$O" unlock app >/dev/null 2>&1; r=$?
check "orbit unlock"               "0" "$r"
check "y lo borra"                 "0" "$([[ -f "$(app_lockfile app)" ]] && echo 1 || echo 0)"
check "la ayuda nombra lock"       "1" "$("$O" help 2>/dev/null | grep -c 'lock <app>')"
check "deploy --help nombra --force" "1" "$("$O" deploy --help 2>/dev/null | grep -c -- '--force')"
check "autodeploy --help nombra checks" "1" "$("$O" autodeploy --help 2>/dev/null | grep -c 'checks')"
check "y en inglés también"        "1" "$("$O" --lang en lock --help 2>/dev/null | grep -c 'emergency exit')"

report
