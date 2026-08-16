#!/usr/bin/env bash
# Despliegue real de proyectos Python: Django de principio a fin, y arranque
# real de Flask y FastAPI. Necesita red la primera vez (pip install).
#   bash tests/python_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, PORT_BASE,
# KEEP_RELEASES…) que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for c in git rsync python3; do
  command -v "$c" >/dev/null || { echo "falta $c: me salto las pruebas de Django."; exit 0; }
done
# La guarda CREA un entorno, no le pregunta al módulo si existe.
#
# Antes era 'python3 -m venv --help', y eso contesta que sí aunque el paquete
# python3-venv no esté: el módulo 'venv' viene en la biblioteca estándar y lo
# que falta es 'ensurepip', que sólo se nota al crear el entorno de verdad.
# Medido en un contenedor debian:12 con sólo 'python3' instalado: '--help'
# sale con 0 y la creación muere con «ensurepip is not available».
#
# El efecto era el tercer estado de siempre —ni probado ni saltado, sino en
# rojo— y con 16 fallos que acusaban al despliegue de Python de Orbit, que
# estaba perfectamente. Lo encontró el trabajo de CI en Debian; en el runner
# de Ubuntu no podía verse, porque allí python3-venv viene puesto.
#
# La lección, que ya está en docs/DEVELOPMENT.md con otros disfraces: **preguntarle a una
# herramienta si existe no es preguntarle si funciona.** Cuando la guarda sea
# barata de ejecutar de verdad, ejecútala.
if ! python3 -m venv "$TMP/_venv_probe" >/dev/null 2>&1; then
  echo "falta python3-venv (o su ensurepip): me salto las pruebas de Django."
  exit 0
fi
rm -rf "$TMP/_venv_probe"

# --- piezas del sistema que no queremos tocar ------------------------------
need_root()      { :; }
systemctl()      { :; }
render_systemd() { :; }
render_nginx()   { nginx_vhost "$1" > "$TMP/vhost-$1.conf"; }
health_wait()    { return 0; }
LOG_FILE="$TMP/orbit.log"
as_deploy() { bash -lc "$*"; }
sudo() {
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -u) shift 2 ;;
      --) shift; break ;;
      *)  shift ;;
    esac
  done
  "$@"
}

# --- un proyecto Django mínimo pero de verdad ------------------------------
ORIGIN="$TMP/origin"
mkdir -p "$ORIGIN/miweb" "$ORIGIN/assets"
printf 'Django>=5.0,<6\n' > "$ORIGIN/requirements.txt"

cat > "$ORIGIN/manage.py" <<'EOF'
#!/usr/bin/env python
import os, sys
def main():
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'miweb.settings')
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
if __name__ == '__main__':
    main()
EOF

: > "$ORIGIN/miweb/__init__.py"
cat > "$ORIGIN/miweb/settings.py" <<'EOF'
import os
from pathlib import Path
BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = os.environ.get('SECRET_KEY', 'clave-de-pruebas')
DEBUG = os.environ.get('DEBUG', '0') == '1'
_hosts = os.environ.get('DJANGO_ALLOWED_HOSTS', '')
ALLOWED_HOSTS = [h for h in _hosts.split(',') if h]
INSTALLED_APPS = [
    'django.contrib.contenttypes',
    'django.contrib.auth',
    'django.contrib.staticfiles',
]
MIDDLEWARE = []
ROOT_URLCONF = 'miweb.urls'
TEMPLATES = []
WSGI_APPLICATION = 'miweb.wsgi.application'
DATABASES = {'default': {
    'ENGINE': 'django.db.backends.sqlite3',
    'NAME': os.environ.get('SQLITE_PATH', str(BASE_DIR / 'db.sqlite3')),
}}
STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
STATICFILES_DIRS = [BASE_DIR / 'assets']
# A propósito dentro de la release: así se comprueba que Orbit avisa de que
# las subidas de los usuarios se perderían en el siguiente despliegue.
MEDIA_URL = '/media/'
MEDIA_ROOT = BASE_DIR / 'media'
USE_TZ = True
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
EOF

cat > "$ORIGIN/miweb/urls.py" <<'EOF'
urlpatterns = []
EOF
cat > "$ORIGIN/miweb/wsgi.py" <<'EOF'
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'miweb.settings')
application = get_wsgi_application()
EOF
: > "$ORIGIN/miweb/asgi.py"
printf 'body { color: rebeccapurple }\n' > "$ORIGIN/assets/estilo.css"

git init -q -b main "$ORIGIN"
git -C "$ORIGIN" config user.email orbit@test
git -C "$ORIGIN" config user.name Orbit
git -C "$ORIGIN" add -A
git -C "$ORIGIN" commit -qm "proyecto django"

section "Detección sobre el repositorio real"
A_NAME="dj"
detect_stack "$ORIGIN"
check "tipo"        "python"                 "$A_TYPE"
check "framework"   "django"                 "$A_PYFW"
check "módulo wsgi" "miweb.wsgi:application" "$A_PYAPP"

# --- registrar la app tal y como haría el asistente ------------------------
A_REPO="$ORIGIN"; A_BRANCH="main"; A_DOMAIN="dj.test"; A_ALIASES=""
A_PORT="3001"; A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
save_app
mkdir -p "$TMP/apps/dj/shared"
# DEBUG activado y sin ALLOWED_HOSTS: los dos avisos que más veces dejan una
# web de Django caída o expuesta en un VPS.
cat > "$TMP/apps/dj/shared/.env" <<EOF
SECRET_KEY=una-clave
DEBUG=1
SQLITE_PATH=$TMP/apps/dj/shared/db.sqlite3
EOF

section "Primer despliegue"
run cmd_deploy dj >"$TMP/out1" 2>&1; r=$?
[[ "$r" == 0 ]] || tail -30 "$TMP/out1" | sed 's/^/      /'
check "despliega" "0" "$r"

REL="$(readlink -f "$TMP/apps/dj/current")"
check "crea el venv"        "1" "$([[ -x "$REL/.venv/bin/python" ]] && echo 1 || echo 0)"
check "instala django"      "1" "$("$REL/.venv/bin/python" -c 'import django;print(1)' 2>/dev/null || echo 0)"
check "ejecuta collectstatic" "body { color: rebeccapurple }" \
  "$(cat "$REL/staticfiles/estilo.css" 2>/dev/null)"

section "Ajustes leídos de Django"
load_app dj
check "STATIC_URL"  "/static/"    "$A_STATIC_URL"
# Relativa, no absoluta: la ruta absoluta llevaría el nombre de esta release
# y quedaría obsoleta en el siguiente despliegue.
check "STATIC_ROOT relativa" "staticfiles" "$A_STATIC_ROOT"
check "MEDIA_URL"   "/media/"     "$A_MEDIA_URL"
check "MEDIA_ROOT relativa"  "media"       "$A_MEDIA_ROOT"

section "Avisos"
check "avisa de DEBUG"      "1" "$(grep -c 'DEBUG=True en producción' "$TMP/out1")"
check "avisa de ALLOWED_HOSTS" "1" "$(grep -c 'no está en ALLOWED_HOSTS' "$TMP/out1")"
check "avisa de MEDIA_ROOT" "1" "$(grep -c 'desaparecerá en el próximo despliegue' "$TMP/out1")"
# Nunca se aplican solas, pero tampoco se callan.
check "avisa de migraciones" "1" "$(grep -c 'orbit migrate dj' "$TMP/out1")"
# 'migrate --check' abre la conexión, y SQLite crea el fichero por el mero
# hecho de conectarse: que exista no demuestra nada. Lo que hay que mirar es
# si se ha llegado a escribir la tabla de migraciones aplicadas.
aplicadas() {
  python3 -c "
import sqlite3, sys
try:
    c = sqlite3.connect('$TMP/apps/dj/shared/db.sqlite3')
    print(c.execute(\"select count(*) from sqlite_master where name='django_migrations'\").fetchone()[0])
except Exception:
    print(0)
"
}
check "no migra sola" "0" "$(aplicadas)"

section "ALLOWED_HOSTS que sí valen no llevan aviso"
# El aviso de arriba es correcto cuando el dominio no está. Lo que faltaba es
# el caso contrario, y ahí había un bug: la lista se dividía SIN comillas, así
# que un '*' —que en Django permite cualquier host— se expandía con los nombres
# de fichero del directorio de turno y no llegaba a compararse nunca. Cualquier
# Django con ALLOWED_HOSTS = ['*'] recibía en CADA despliegue el aviso de que
# iba a contestar 400 Bad Request, y lo mandaba a editar un settings.py que
# estaba bien. Salió desplegando un Django de verdad en un VPS: la web
# contestaba 200 y Orbit decía que no.
#
# El directorio tiene que tener ficheros para que el glob tenga con qué
# expandirse: en uno vacío, con 'nullglob', el bucle no se ejecuta y el fallo
# se disfraza de otra cosa.
_CWD="$PWD"; cd "$TMP" || exit 1; : > uno.txt; : > dos.txt
run _host_allowed "midominio.com" "*"; r=$?
check "'*' permite cualquier host"        "0" "$r"
run _host_allowed "midominio.com" "midominio.com"; r=$?
check "el dominio exacto"                 "0" "$r"
run _host_allowed "midominio.com" "otro.com,midominio.com"; r=$?
check "dentro de una lista"               "0" "$r"
run _host_allowed "sub.midominio.com" ".midominio.com"; r=$?
check "el punto inicial cubre subdominios" "0" "$r"
run _host_allowed "midominio.com" "otro.com"; r=$?
check "uno ajeno no"                      "1" "$r"
run _host_allowed "midominio.com" ""; r=$?
check "y vacío tampoco"                   "1" "$r"
cd "$_CWD" || exit 1

section "Vhost generado"
check "alias de estáticos" "1" \
  "$(grep -c "alias $TMP/apps/dj/current/staticfiles/;" "$TMP/vhost-dj.conf")"
check "location /static/"  "1" "$(grep -c 'location /static/ {' "$TMP/vhost-dj.conf")"
check "location /media/"   "1" "$(grep -c 'location /media/ {' "$TMP/vhost-dj.conf")"
check "y el proxy al final" "1" "$(grep -c 'proxy_pass http://127.0.0.1:3001;' "$TMP/vhost-dj.conf")"

section "orbit migrate"
run cmd_migrate dj --yes >"$TMP/mig" 2>&1; r=$?
[[ "$r" == 0 ]] || tail -20 "$TMP/mig" | sed 's/^/      /'
check "aplica migraciones" "0" "$r"
check "ahora sí hay tabla" "1" "$(aplicadas)"
check "enseña el plan"     "1" "$(grep -c 'Plan:' "$TMP/mig")"
check "queda en el log"    "1" "$(grep -c 'migrate dj' "$TMP/orbit.log")"

section "Segundo despliegue"
sleep 1
printf 'body { color: teal }\n' > "$ORIGIN/assets/estilo.css"
git -C "$ORIGIN" commit -qam "cambia el color"
run cmd_deploy dj >"$TMP/out2" 2>&1; r=$?
check "despliega" "0" "$r"
load_app dj
# La ruta no debe acumular la release anterior ni volverse absoluta.
check "STATIC_ROOT sigue relativa" "staticfiles" "$A_STATIC_ROOT"
REL2="$(readlink -f "$TMP/apps/dj/current")"
check "estáticos de la nueva" "body { color: teal }" "$(cat "$REL2/staticfiles/estilo.css")"
check "ya no avisa de migraciones" "0" "$(grep -c 'orbit migrate dj' "$TMP/out2")"

section "Build fallido en collectstatic"
sleep 1
printf 'STATIC_ROOT = None\n' >> "$ORIGIN/miweb/settings.py"
git -C "$ORIGIN" commit -qam "rompe STATIC_ROOT"
GOOD="$(readlink -f "$TMP/apps/dj/current")"
run cmd_deploy dj >"$TMP/out3" 2>&1; r=$?
check "aborta el despliegue" "1" "$r"
check "producción intacta" "$GOOD" "$(readlink -f "$TMP/apps/dj/current")"

# ═══════════════════════════════════════════════════════════════════════════
# Que la detección acierte el módulo no demuestra que el comando arranque.
# La versión anterior generaba 'gunicorn app:app' para todo el mundo, que es
# sintácticamente correcto y no levanta nada. Aquí se arranca de verdad.
# ═══════════════════════════════════════════════════════════════════════════
arranca() { # arranca <app> <puerto> -> cuerpo de la respuesta
  local name="$1" port="$2" rel pid out
  rel="$(readlink -f "$TMP/apps/$name/current")"
  out="$TMP/$name.serve.log"
  ( cd "$rel" && PORT="$port" bash -lc "${A_START//\$\{PORT\}/$port}" >"$out" 2>&1 ) &
  pid=$!
  local i
  for (( i = 0; i < 40; i++ )); do
    curl -fsS -m 2 "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.5
  done
  kill "$pid" 2>/dev/null
  pkill -P "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

despliega_py() { # despliega_py <app> <puerto> <dir origen>
  local name="$1" port="$2" src="$3"
  git init -q -b main "$src"
  git -C "$src" config user.email orbit@test
  git -C "$src" config user.name Orbit
  git -C "$src" add -A
  git -C "$src" commit -qm inicial
  A_NAME="$name"; detect_stack "$src"
  A_REPO="$src"; A_BRANCH="main"; A_DOMAIN="$name.test"; A_ALIASES=""
  A_PORT="$port"; A_CREATED="2026-01-01T00:00:00+00:00"; A_LASTDEPLOY=""
  save_app
  run cmd_deploy "$name" >"$TMP/$name.deploy.log" 2>&1
}

section "Flask arranca con lo que genera Orbit"
FL="$TMP/flaskapp"
mkdir -p "$FL"
printf 'Flask>=3\n' > "$FL/requirements.txt"
cat > "$FL/app.py" <<'EOF'
from flask import Flask
app = Flask(__name__)

@app.get("/")
def home():
    return "hola desde flask"
EOF
despliega_py flaskapp 18201 "$FL" && r=0 || r=$?
[[ "$r" == 0 ]] || tail -20 "$TMP/flaskapp.deploy.log" | sed 's/^/      /'
check "despliega" "0" "$r"
load_app flaskapp
check "módulo detectado" "app:app" "$A_PYAPP"
check "responde de verdad" "hola desde flask" "$(arranca flaskapp 18201)"
# Sin estáticos declarados, el vhost de una app Python es un proxy y nada más.
check "vhost sin alias" "0" "$(grep -c 'alias' "$TMP/vhost-flaskapp.conf")"
check "y sí con proxy"  "1" "$(grep -c 'proxy_pass' "$TMP/vhost-flaskapp.conf")"

section "FastAPI arranca con lo que genera Orbit"
FA="$TMP/fastapiapp"
mkdir -p "$FA"
printf 'fastapi>=0.110\n' > "$FA/requirements.txt"
cat > "$FA/main.py" <<'EOF'
from fastapi import FastAPI
api = FastAPI()

@api.get("/")
def home():
    return "hola desde fastapi"
EOF
despliega_py fastapiapp 18202 "$FA" && r=0 || r=$?
[[ "$r" == 0 ]] || tail -20 "$TMP/fastapiapp.deploy.log" | sed 's/^/      /'
check "despliega" "0" "$r"
load_app fastapiapp
check "objeto no llamado app" "main:api" "$A_PYAPP"
check "arranca con uvicorn"   "1" "$(grep -c uvicorn <<<"$A_START")"
check "responde de verdad"    '"hola desde fastapi"' "$(arranca fastapiapp 18202)"

report
