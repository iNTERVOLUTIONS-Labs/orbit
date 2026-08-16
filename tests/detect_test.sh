#!/usr/bin/env bash
# Pruebas de detección de stack y de serialización. No necesitan servidor ni root.
#   bash tests/detect_test.sh
# shellcheck disable=SC2034  # estas pruebas asignan variables (A_*, PORT_BASE,
# KEEP_RELEASES…) que lee el 'orbit' cargado por lib.sh, no este fichero.
set -uo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FX="$TMP/fx"

# --- fixtures
mkdir -p "$FX/next"
echo '{"dependencies":{"next":"15"},"scripts":{"build":"next build","start":"next start"}}' > "$FX/next/package.json"
touch "$FX/next/pnpm-lock.yaml"

mkdir -p "$FX/nextexp"
cp "$FX/next/package.json" "$FX/nextexp/package.json"
touch "$FX/nextexp/pnpm-lock.yaml"
printf "module.exports = { output: 'export' };\n" > "$FX/nextexp/next.config.js"

mkdir -p "$FX/astro"
echo '{"dependencies":{"astro":"5"},"scripts":{"build":"astro build"}}' > "$FX/astro/package.json"
touch "$FX/astro/pnpm-lock.yaml"

mkdir -p "$FX/astrossr"
echo '{"dependencies":{"astro":"5","@astrojs/node":"9"},"scripts":{"build":"astro build"}}' > "$FX/astrossr/package.json"
touch "$FX/astrossr/pnpm-lock.yaml"

mkdir -p "$FX/vite"
echo '{"devDependencies":{"vite":"6"},"scripts":{"build":"vite build"}}' > "$FX/vite/package.json"
touch "$FX/vite/package-lock.json"

mkdir -p "$FX/cra"
echo '{"dependencies":{"react-scripts":"5"},"scripts":{"build":"react-scripts build"}}' > "$FX/cra/package.json"
touch "$FX/cra/yarn.lock"

mkdir -p "$FX/express"
echo '{"dependencies":{"express":"4"},"scripts":{"start":"node server.js"}}' > "$FX/express/package.json"
touch "$FX/express/pnpm-lock.yaml"

mkdir -p "$FX/php/public"
echo '{}' > "$FX/php/composer.json"
touch "$FX/php/index.php"

mkdir -p "$FX/py"
echo 'flask' > "$FX/py/requirements.txt"

# --- Python: un fixture por combinación de gestor y framework
# Django con la distribución habitual y el paquete declarado en manage.py
mkdir -p "$FX/django/miproyecto"
printf 'Django==5.2\npsycopg[binary]\n' > "$FX/django/requirements.txt"
cat > "$FX/django/manage.py" <<'EOF'
import os, sys
def main():
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'miproyecto.settings')
EOF
touch "$FX/django/miproyecto/__init__.py" "$FX/django/miproyecto/settings.py"
touch "$FX/django/miproyecto/wsgi.py" "$FX/django/miproyecto/asgi.py"

# Django con Channels: asgi.py existe en cualquier proyecto moderno, así que
# lo que debe decidir es que haya un servidor ASGI de verdad en las dependencias
mkdir -p "$FX/djchannels/config"
printf 'Django==5.2\nchannels[daphne]==4.1\n' > "$FX/djchannels/requirements.txt"
cat > "$FX/djchannels/manage.py" <<'EOF'
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
EOF
touch "$FX/djchannels/config/__init__.py" "$FX/djchannels/config/wsgi.py" "$FX/djchannels/config/asgi.py"

# Django sin pista en manage.py: hay que dar con el paquete por el wsgi.py
mkdir -p "$FX/djraro/elsitio"
printf 'Django==5.2\n' > "$FX/djraro/requirements.txt"
printf 'import sys\n' > "$FX/djraro/manage.py"
touch "$FX/djraro/elsitio/__init__.py" "$FX/djraro/elsitio/wsgi.py"

# FastAPI en app/main.py, con el objeto anotado
mkdir -p "$FX/fastapi/app"
printf 'fastapi\npydantic\n' > "$FX/fastapi/requirements.txt"
printf 'from fastapi import FastAPI\napi: FastAPI = FastAPI()\n' > "$FX/fastapi/app/main.py"

# Flask clásico
mkdir -p "$FX/flask"
printf 'Flask==3.0\n' > "$FX/flask/requirements.txt"
printf 'from flask import Flask\napp = Flask(__name__)\n' > "$FX/flask/app.py"

# Poetry: pyproject con fichero de bloqueo
mkdir -p "$FX/poetry"
cat > "$FX/poetry/pyproject.toml" <<'EOF'
[tool.poetry]
name = "web"
[tool.poetry.dependencies]
python = "^3.12"
Django = "^5.2"
EOF
touch "$FX/poetry/poetry.lock"
printf 'os.environ.setdefault("DJANGO_SETTINGS_MODULE", "web.settings")\n' > "$FX/poetry/manage.py"
mkdir -p "$FX/poetry/web"; touch "$FX/poetry/web/wsgi.py"

# uv: mismo caso con su propio fichero de bloqueo
mkdir -p "$FX/uv"
cat > "$FX/uv/pyproject.toml" <<'EOF'
[project]
name = "api"
dependencies = ["fastapi", "uvicorn"]
EOF
touch "$FX/uv/uv.lock"
printf 'from fastapi import FastAPI\napp = FastAPI()\n' > "$FX/uv/main.py"

# pyproject suelto, sin fichero de bloqueo ni requirements
mkdir -p "$FX/pyproj"
printf '[project]\nname = "x"\ndependencies = ["flask"]\n' > "$FX/pyproj/pyproject.toml"
printf 'from flask import Flask\napp = Flask(__name__)\n' > "$FX/pyproj/wsgi.py"

mkdir -p "$FX/plain"
echo '<h1>hola</h1>' > "$FX/plain/index.html"

# --- fixtures copiados de los scaffolds de verdad ---------------------------
# Las dependencias y los scripts son los que generan hoy 'sv create',
# 'create-react-router', 'ng new' y 'hugo new site', no los que uno recuerda.

# SvelteKit tal y como sale de 'sv create': adapter-auto y, ojo, la
# configuración del adaptador ya no está en svelte.config.js sino dentro de
# vite.config.ts. Por eso se mira el paquete y no el fichero.
mkdir -p "$FX/svelte"
echo '{"devDependencies":{"@sveltejs/kit":"^2.63.0","@sveltejs/adapter-auto":"^7.0.1","svelte":"^5","vite":"^8"},"scripts":{"build":"vite build"}}' > "$FX/svelte/package.json"
touch "$FX/svelte/pnpm-lock.yaml"

mkdir -p "$FX/sveltenode"
echo '{"devDependencies":{"@sveltejs/kit":"^2.63.0","@sveltejs/adapter-node":"^5","svelte":"^5","vite":"^8"},"scripts":{"build":"vite build"}}' > "$FX/sveltenode/package.json"
touch "$FX/sveltenode/pnpm-lock.yaml"

mkdir -p "$FX/sveltestatic"
echo '{"devDependencies":{"@sveltejs/kit":"^2.63.0","@sveltejs/adapter-static":"^3","svelte":"^5","vite":"^8"},"scripts":{"build":"vite build"}}' > "$FX/sveltestatic/package.json"
touch "$FX/sveltestatic/pnpm-lock.yaml"

# React Router 7, que es lo que crea hoy 'create-remix'.
mkdir -p "$FX/rr"
echo '{"dependencies":{"@react-router/node":"^7","@react-router/serve":"^7","react-router":"^7"},"devDependencies":{"@react-router/dev":"^7","vite":"^6"},"scripts":{"build":"react-router build","start":"react-router-serve ./build/server/index.js"}}' > "$FX/rr/package.json"
touch "$FX/rr/pnpm-lock.yaml"
printf 'import type { Config } from "@react-router/dev/config";\nexport default { ssr: true } satisfies Config;\n' > "$FX/rr/react-router.config.ts"

mkdir -p "$FX/rrspa"
cp "$FX/rr/package.json" "$FX/rrspa/package.json"
touch "$FX/rrspa/pnpm-lock.yaml"
printf 'export default {\n  ssr: false\n};\n' > "$FX/rrspa/react-router.config.ts"

# Remix de los de antes, que siguen existiendo y hay que seguir desplegando.
mkdir -p "$FX/remix"
echo '{"dependencies":{"@remix-run/node":"^2","@remix-run/react":"^2","@remix-run/serve":"^2"},"devDependencies":{"vite":"^5"},"scripts":{"build":"remix vite:build"}}' > "$FX/remix/package.json"
touch "$FX/remix/pnpm-lock.yaml"

# Angular moderno: angular.json NO trae outputPath, así que la carpeta sale del
# nombre del proyecto. Comprobado compilando: dist/<proyecto>/browser.
mkdir -p "$FX/ng"
echo '{"dependencies":{"@angular/core":"^20","@angular/common":"^20","rxjs":"^7"},"scripts":{"build":"ng build"}}' > "$FX/ng/package.json"
touch "$FX/ng/package-lock.json"
echo '{"projects":{"mi-panel":{"architect":{"build":{"builder":"@angular/build:application","options":{}}}}}}' > "$FX/ng/angular.json"

mkdir -p "$FX/ngssr"
echo '{"dependencies":{"@angular/core":"^20","@angular/ssr":"^20","express":"^5"},"scripts":{"build":"ng build"}}' > "$FX/ngssr/package.json"
touch "$FX/ngssr/package-lock.json"
echo '{"projects":{"tienda":{"architect":{"build":{"builder":"@angular/build:application","options":{}}}}}}' > "$FX/ngssr/angular.json"

# Angular antiguo: el builder 'browser' no mete subcarpeta y outputPath es explícito.
mkdir -p "$FX/ngold"
echo '{"dependencies":{"@angular/core":"^15"},"scripts":{"build":"ng build"}}' > "$FX/ngold/package.json"
touch "$FX/ngold/package-lock.json"
echo '{"projects":{"viejo":{"architect":{"build":{"builder":"@angular-devkit/build-angular:browser","options":{"outputPath":"dist/viejo"}}}}}}' > "$FX/ngold/angular.json"

# ── Qwik ──────────────────────────────────────────────────────────────────
# El package.json es el de 'npm create qwik@latest' 1.20.0, copiado tal cual en
# lo que importa: los paquetes de Qwik están en devDependencies, 'vite' también
# —por eso se lo llevaba la rama de Vite— y 'start' es el servidor de
# desarrollo, que es el otro sitio donde esto se podía torcer.
#
# El adaptador NO es un paquete, a diferencia de SvelteKit: 'qwik add' deja un
# directorio adapters/<nombre>/vite.config.ts. Los fixtures lo reproducen.
_qwik_pkg() { # _qwik_pkg <serve|-> [dep-extra]
  local serve="$1" extra="${2:-}"
  local deps='{}'; [[ -n "$extra" ]] && deps="{\"$extra\":\"4\"}"
  local scripts='"build":"qwik build","build.client":"vite build","start":"vite --open --mode ssr","preview":"qwik build preview && vite preview --open"'
  [[ "$serve" != "-" ]] && scripts="$scripts,\"serve\":\"$serve\""
  printf '{"type":"module","scripts":{%s},"dependencies":%s,"devDependencies":{"@builder.io/qwik":"^1.20.0","@builder.io/qwik-city":"^1.20.0","vite":"7.3.1","typescript":"5.4.5"}}\n' \
    "$scripts" "$deps"
}
_qwik_fx() { # _qwik_fx <dir> <adaptador|-> <serve|-> [dep-extra]
  mkdir -p "$FX/$1"
  _qwik_pkg "$3" "${4:-}" > "$FX/$1/package.json"
  touch "$FX/$1/pnpm-lock.yaml"
  [[ "$2" != "-" ]] && { mkdir -p "$FX/$1/adapters/$2"
    printf 'export default extendConfig(baseConfig, () => ({}));\n' > "$FX/$1/adapters/$2/vite.config.ts"; }
  return 0
}

# Sin adaptador: lo que sale de 'npm create qwik'. Comprobado compilando —
# dist/ no tiene index.html, ni una sola página, sólo los bundles.
_qwik_fx qwik - -
# Los tres que dejan un servidor. El de Express añade 'express' a dependencies,
# que es la segunda rama que se lo quedaba.
_qwik_fx qwikexpress express 'node server/entry.express' express
_qwik_fx qwiknode    node-server 'node server/entry.node-server'
_qwik_fx qwikfastify fastify 'node server/entry.fastify' fastify
# Bun y Deno: el tipo tiene que decir cuál, porque de él depende el binario que
# exige 'orbit doctor'.
_qwik_fx qwikbun  bun  'bun server/entry.bun.js'
_qwik_fx qwikdeno deno 'deno run --allow-net --allow-read --allow-env server/entry.deno.js'
# El único que deja un sitio servible: no tiene 'serve' porque no hay nada que
# arrancar. Comprobado compilando: dist/ con index.html, demo/ y 404.html.
_qwik_fx qwikstatic static -
# Adaptadores de plataformas que no son este servidor.
_qwik_fx qwikcf cloudflare-pages -
# Más de un adaptador, que la documentación de Qwik propone: prerenderizar lo
# que se pueda y servir el resto. Alfabéticamente 'cloudflare-pages' va antes
# que 'node-server' y 'express' antes que 'static', así que quedarse con el
# primero se equivocaba en los dos sentidos.
#
# Los pares están elegidos para que el orden alfabético empuje hacia el lado
# equivocado, que es lo único que prueba la precedencia: 'azure-swa' va antes
# que 'express' y antes que 'static'. Con 'cloudflare-pages' y 'node-server' no
# se vería nada, porque el camino de repuesto arranca precisamente el
# node-server y las dos respuestas coinciden por casualidad.
_qwik_fx qwikdual express 'node server/entry.express' express
mkdir -p "$FX/qwikdual/adapters/static"
printf 'export default {};\n' > "$FX/qwikdual/adapters/static/vite.config.ts"
_qwik_fx qwikazex express 'node server/entry.express' express
mkdir -p "$FX/qwikazex/adapters/azure-swa"
printf 'export default {};\n' > "$FX/qwikazex/adapters/azure-swa/vite.config.ts"
_qwik_fx qwikazst static -
mkdir -p "$FX/qwikazst/adapters/azure-swa"
printf 'export default {};\n' > "$FX/qwikazst/adapters/azure-swa/vite.config.ts"
# Qwik 2: renombró los paquetes y mantuvo la convención de adaptadores.
mkdir -p "$FX/qwikv2/adapters/node-server"
printf 'export default {};\n' > "$FX/qwikv2/adapters/node-server/vite.config.ts"
echo '{"type":"module","scripts":{"build":"qwik build","start":"vite --open --mode ssr","serve":"node server/entry.node-server"},"devDependencies":{"@qwik.dev/core":"2.0.0-beta.38","@qwik.dev/router":"2.0.0-beta.38","vite":"7"}}' > "$FX/qwikv2/package.json"
touch "$FX/qwikv2/pnpm-lock.yaml"
# Y en un monorepo, que es donde se ve si las rutas se traducen.
mkdir -p "$FX/qwikmono/apps/web"
cp -r "$FX/qwiknode/package.json" "$FX/qwikmono/apps/web/package.json"
cp -r "$FX/qwiknode/adapters" "$FX/qwikmono/apps/web/adapters"
echo '{"private":true,"devDependencies":{"turbo":"^2"},"scripts":{"build":"turbo build"}}' > "$FX/qwikmono/package.json"
touch "$FX/qwikmono/pnpm-lock.yaml"
mkdir -p "$FX/qwikmonostatic/apps/web"
cp -r "$FX/qwikstatic/package.json" "$FX/qwikmonostatic/apps/web/package.json"
cp -r "$FX/qwikstatic/adapters" "$FX/qwikmonostatic/apps/web/adapters"
echo '{"private":true,"devDependencies":{"turbo":"^2"}}' > "$FX/qwikmonostatic/package.json"
touch "$FX/qwikmonostatic/pnpm-lock.yaml"

mkdir -p "$FX/eleventy"
echo '{"devDependencies":{"@11ty/eleventy":"^3"},"scripts":{"build":"eleventy"}}' > "$FX/eleventy/package.json"
touch "$FX/eleventy/package-lock.json"

# Hugo: sin package.json y con la forma que deja 'hugo new site'.
mkdir -p "$FX/hugo/content" "$FX/hugo/layouts"
printf 'baseURL = "https://example.org/"\ntitle = "Mi sitio"\n' > "$FX/hugo/hugo.toml"

# Hugo con Tailwind: lleva package.json, y ahí es donde se confundía con un
# proyecto de JavaScript sin framework.
mkdir -p "$FX/hugotw/content" "$FX/hugotw/layouts"
printf 'baseURL = "https://example.org/"\n' > "$FX/hugotw/hugo.toml"
echo '{"devDependencies":{"tailwindcss":"^4"},"scripts":{"build":"tailwindcss -o static/app.css"}}' > "$FX/hugotw/package.json"
touch "$FX/hugotw/package-lock.json"

# Go: 'go.mod' y un paquete main. El main NO está en main.go a propósito —puede
# estar en cualquier fichero— y el código nombra PORT, que es lo normal.
mkdir -p "$FX/go"
printf 'module ejemplo.com/web\ngo 1.24\n' > "$FX/go/go.mod"
printf 'package main\nimport "os"\nfunc main(){ _ = os.Getenv("PORT") }\n' > "$FX/go/servidor.go"

# Go con varios binarios: se elige el que parece el servidor, no el primero.
mkdir -p "$FX/gomulti/cmd/servidor" "$FX/gomulti/cmd/migrador"
printf 'module ejemplo.com/multi\ngo 1.24\n' > "$FX/gomulti/go.mod"
printf 'package main\nimport "os"\nfunc main(){ _ = os.Getenv("PORT") }\n' > "$FX/gomulti/cmd/servidor/main.go"
printf 'package main\nfunc main(){}\n' > "$FX/gomulti/cmd/migrador/main.go"

# Un sitio de Hugo con Hugo Modules TIENE go.mod: 'hugo mod init' lo escribe
# para declarar el tema. Sin la comprobación del paquete main, esto se
# detectaría como Go y se intentaría compilar un binario que no existe.
mkdir -p "$FX/hugomod/content" "$FX/hugomod/layouts"
printf 'baseURL = "https://example.org/"\n' > "$FX/hugomod/hugo.toml"
printf 'module github.com/yo/misitio\ngo 1.24\nrequire github.com/x/tema v0.0.0 // indirect\n' > "$FX/hugomod/go.mod"

# Un repositorio de librería en Go no tiene ningún main: no es desplegable, y
# tratarlo como Go daría un build que sale bien y no deja binario.
mkdir -p "$FX/golib"
printf 'module ejemplo.com/lib\ngo 1.24\n' > "$FX/golib/go.mod"
printf 'package lib\n' > "$FX/golib/lib.go"

# Go que empaqueta su frontend con go:embed: tiene go.mod Y package.json. Si
# ganara la rama de Node, se publicaría como estático apuntando a un dist/ que
# nadie genera, y la web entera saldría en 404.
mkdir -p "$FX/goembed"
printf 'module ejemplo.com/embed\ngo 1.24\n' > "$FX/goembed/go.mod"
printf 'package main\nimport "os"\nfunc main(){ _ = os.Getenv("PORT") }\n' > "$FX/goembed/main.go"
echo '{"devDependencies":{"vite":"^5"},"scripts":{"build":"vite build"}}' > "$FX/goembed/package.json"
touch "$FX/goembed/package-lock.json"

# Go que lleva el puerto escrito y no mira el entorno: Orbit no puede hacer
# nada más que avisar, porque en Go el servidor es la app y no lo genera Orbit.
mkdir -p "$FX/goport"
printf 'module ejemplo.com/fijo\ngo 1.24\n' > "$FX/goport/go.mod"
printf 'package main\nimport "net/http"\nfunc main(){ http.ListenAndServe(":8080", nil) }\n' > "$FX/goport/main.go"

# Un .go suelto sin go.mod no es un proyecto desplegable: es anterior a los
# módulos, y 'go build' ni siquiera arranca.
mkdir -p "$FX/gosuelto"
printf 'package main\nfunc main(){}\n' > "$FX/gosuelto/main.go"

# Deno: la señal fuerte es el deno.lock, que sólo escribe 'deno install'.
mkdir -p "$FX/deno"
echo '{"tasks":{"start":"deno serve main.ts"},"imports":{"@std/http":"jsr:@std/http@^1"}}' > "$FX/deno/deno.json"
echo '{"version":"5"}' > "$FX/deno/deno.lock"
printf 'Deno.serve({ port: Number(Deno.env.get("PORT")) }, () => new Response("hola"));\n' > "$FX/deno/main.ts"

# Deno sin Deno.serve en el fichero: el servidor se levanta con 'deno serve',
# que exporta un default. El arranque no es el mismo.
mkdir -p "$FX/denoserve"
echo '{"tasks":{"start":"deno serve main.ts"}}' > "$FX/denoserve/deno.json"
printf 'export default { fetch: () => new Response("hola") };\n' > "$FX/denoserve/main.ts"

# Un deno.json puesto sólo para 'deno fmt' en un proyecto de Node no es Deno.
mkdir -p "$FX/denofmt"
echo '{"fmt":{"lineWidth":100}}' > "$FX/denofmt/deno.json"
echo '{"devDependencies":{"vite":"6"},"scripts":{"build":"vite build"}}' > "$FX/denofmt/package.json"
touch "$FX/denofmt/package-lock.json"

# Y un Next instalado con 'deno install' TIENE deno.json y deno.lock —Deno 2
# resuelve las dependencias npm:— y sigue siendo Next.
mkdir -p "$FX/denonext"
echo '{"nodeModulesDir":"auto"}' > "$FX/denonext/deno.json"
echo '{"version":"5"}' > "$FX/denonext/deno.lock"
echo '{"dependencies":{"next":"15"},"scripts":{"build":"next build","start":"next start"}}' > "$FX/denonext/package.json"

# Deno que declara sus propios permisos: manda el repositorio.
mkdir -p "$FX/denoperm"
echo '{"permissions":{"net":true},"tasks":{"start":"deno run main.ts"}}' > "$FX/denoperm/deno.json"
printf 'Deno.serve(() => new Response("hola"));\n' > "$FX/denoperm/main.ts"

# Deno cuyo servidor no se llama como ninguno de los de siempre: el fichero
# sale de la tarea del repositorio.
mkdir -p "$FX/denotask/api"
echo '{"tasks":{"start":"deno run -A api/entrada.ts"}}' > "$FX/denotask/deno.json"
printf 'Deno.serve(() => new Response("hola"));\n' > "$FX/denotask/api/entrada.ts"

# Deno sin fichero de arranque reconocible: se avisa, pero NO se publica como
# estático — eso sería nginx sirviendo el código del servidor.
mkdir -p "$FX/denosinentry"
echo '{"imports":{"@std/http":"jsr:@std/http@^1"}}' > "$FX/denosinentry/deno.json"

# Bun como runtime: el repositorio dice que arranca con bun.
mkdir -p "$FX/bun/src"
echo '{"scripts":{"start":"bun run src/index.ts"},"devDependencies":{"@types/bun":"^1"}}' > "$FX/bun/package.json"
touch "$FX/bun/bun.lock"
printf 'export default { fetch: () => new Response("hola") };\n' > "$FX/bun/src/index.ts"

# Bun sin script de arranque: un servidor de Bun.serve no siempre lo trae, y
# sin las señales de apoyo esto caía en el último 'else' y se publicaba el
# código fuente. Es el caso que motiva toda esta rama.
mkdir -p "$FX/bunserve"
echo '{"devDependencies":{"@types/bun":"^1"}}' > "$FX/bunserve/package.json"
touch "$FX/bunserve/bun.lock"
printf 'Bun.serve({ port: process.env.PORT, fetch: () => new Response("hola") });\n' > "$FX/bunserve/index.ts"

# Bun sólo como gestor de paquetes de un proyecto de Node: cambia A_PKG y nada
# más. El runtime lo decide el framework, no el lockfile.
mkdir -p "$FX/bunnext"
echo '{"dependencies":{"next":"15"},"scripts":{"build":"next build","start":"next start"}}' > "$FX/bunnext/package.json"
touch "$FX/bunnext/bun.lock"

# Hono corre en Node y en Bun: quien decide es el script de arranque.
mkdir -p "$FX/bunhono"
echo '{"dependencies":{"hono":"^4"},"scripts":{"start":"bun run server.ts"}}' > "$FX/bunhono/package.json"
touch "$FX/bunhono/bun.lock"
printf 'export default { fetch: () => new Response("hola") };\n' > "$FX/bunhono/server.ts"
mkdir -p "$FX/nodehono"
echo '{"dependencies":{"hono":"^4"},"scripts":{"start":"node server.js"}}' > "$FX/nodehono/package.json"
touch "$FX/nodehono/bun.lock"

# Los cuatro que se colaban por la rama de repuesto —static con A_OUTDIR="."—,
# que es nginx sirviendo la raíz del repositorio. Salieron de una revisión
# adversarial del soporte de Deno y Bun, y cada uno por un camino distinto.
#
# 1 · bun.lock en el .gitignore, que es lo normal en mucha gente: sin él A_PKG
#     no vale 'bun', y la señal fuerte —el propio "start": "bun run …"— no se
#     llegaba ni a mirar.
mkdir -p "$FX/bunsinlock"
echo '{"scripts":{"start":"bun run server.ts"},"devDependencies":{"@types/bun":"^1"}}' > "$FX/bunsinlock/package.json"
printf 'const CLAVE="secreto";\nBun.serve({fetch:()=>new Response("hola")});\n' > "$FX/bunsinlock/server.ts"

# 2 · Bun no necesita package.json para ejecutar un fichero, y _is_bun_app sólo
#     se llamaba desde dentro de la rama que lo exige.
mkdir -p "$FX/bunfigsolo"
printf '[install]\nregistry = "https://registry.npmjs.org"\n' > "$FX/bunfigsolo/bunfig.toml"
printf 'Bun.serve({fetch:()=>new Response("hola")});\n' > "$FX/bunfigsolo/index.ts"

# 3 · Deno importando por URL o por 'jsr:' a pelo: ni deno.json ni deno.lock,
#     o sea nada que Orbit reconociera.
mkdir -p "$FX/denosuelto"
printf 'const CLAVE="secreto";\nDeno.serve(()=>new Response("hola"));\n' > "$FX/denosuelto/main.ts"

# 4 · Un servidor de Node sin framework: el 'http' de la biblioteca estándar y
#     nada más. Lo que lo delata es el 'start': hay algo que arrancar.
mkdir -p "$FX/nodesuelto"
echo '{"dependencies":{"pg":"^8"},"scripts":{"start":"node server.js"}}' > "$FX/nodesuelto/package.json"
printf 'require("http");\n' > "$FX/nodesuelto/server.js"
touch "$FX/nodesuelto/package-lock.json"

# 5 · El mismo servidor, pero en TypeScript: 'build' con tsc y 'start' sobre lo
#     compilado. Es la mitad peor del mismo agujero, y la que no avisaba.
#
#     La condición de la rama pedía «tiene start y NO tiene build», así que
#     esto se le escapaba y salía 'static' con A_OUTDIR='dist'. Y ahí no salta
#     el aviso de «la carpeta no existe», porque tsc la crea: nginx publicaba
#     el servidor compilado y la app no se arrancaba nunca. Salió al desplegar
#     una app así en un servidor de verdad; ninguna prueba lo miraba porque
#     todas las de esta familia traían sólo 'start'.
mkdir -p "$FX/nodets"
echo '{"dependencies":{"pg":"^8"},"scripts":{"build":"tsc","start":"node dist/server.js"}}' > "$FX/nodets/package.json"
printf 'import http from "http";\n' > "$FX/nodets/server.ts"
touch "$FX/nodets/package-lock.json"

# Un deno.lock suelto no convierte una app de Node en una app de Deno: basta
# con que alguien haya ejecutado 'deno' una vez en el repositorio.
mkdir -p "$FX/nodecondeno"
echo '{"dependencies":{"pg":"^8"},"scripts":{"start":"node server.js"}}' > "$FX/nodecondeno/package.json"
printf 'require("http");\n' > "$FX/nodecondeno/server.js"
echo '{"version":"5"}' > "$FX/nodecondeno/deno.lock"
touch "$FX/nodecondeno/package-lock.json"

# Fresh y compañía no escriben 'Deno.serve' en ninguna parte: exportan un
# default o llaman a app.listen(). Lo que decide entre 'deno run' y 'deno serve'
# es el export default, no el literal.
mkdir -p "$FX/denolisten"
echo '{"tasks":{"build":"deno run -A dev.ts build","start":"deno run -A main.ts"},"imports":{"fresh":"jsr:@fresh/core@^2"}}' > "$FX/denolisten/deno.json"
printf 'import { App } from "fresh";\nexport const app = new App();\napp.listen();\n' > "$FX/denolisten/main.ts"

# Un deno.jsonc con comentarios: es su motivo de existir, y jq no sabe leerlo.
mkdir -p "$FX/denojsonc/api"
printf '{\n  // el servidor de verdad\n  "tasks": { "start": "deno serve api/entrada.ts" },\n  "imports": {}\n}\n' > "$FX/denojsonc/deno.jsonc"
printf 'export default { fetch: () => new Response("ok") };\n' > "$FX/denojsonc/api/entrada.ts"

# Una tarea puede ser un objeto con 'command' dentro, no sólo una cadena.
mkdir -p "$FX/denoobjeto/api"
echo '{"tasks":{"start":{"command":"deno serve api/main.ts","description":"arranca"}},"imports":{}}' > "$FX/denoobjeto/deno.json"
printf 'export default { fetch: () => new Response("ok") };\n' > "$FX/denoobjeto/api/main.ts"

# main.ts que es una herramienta de línea de órdenes, y el servidor en otro
# sitio: manda lo que diga la tarea del repositorio.
mkdir -p "$FX/denotarea/src"
echo '{"tasks":{"start":"deno run -A src/servidor.ts"},"imports":{}}' > "$FX/denotarea/deno.json"
printf 'Deno.serve(()=>new Response("cli"));\n'       > "$FX/denotarea/main.ts"
printf 'Deno.serve(()=>new Response("servidor"));\n'  > "$FX/denotarea/src/servidor.ts"

# Laravel: hacen falta las tres señales, y cada fixture de abajo existe porque
# quitando una de ellas se confunde con un proyecto real distinto.
mkdir -p "$FX/laravel/bootstrap" "$FX/laravel/public"
printf '#!/usr/bin/env php\n' > "$FX/laravel/artisan"
printf '<?php return 1;\n'    > "$FX/laravel/bootstrap/app.php"
echo '{"require":{"php":"^8.2","laravel/framework":"^13.0"}}' > "$FX/laravel/composer.json"
# Y con el package.json del esqueleto, que es el que rompía la detección: vite
# en devDependencies y un script 'build'.
echo '{"devDependencies":{"vite":"^7","laravel-vite-plugin":"^2"},"scripts":{"build":"vite build"}}' > "$FX/laravel/package.json"
touch "$FX/laravel/package-lock.json"

# Una API de Laravel pelada: sin JavaScript por ningún lado.
mkdir -p "$FX/laravelapi/bootstrap" "$FX/laravelapi/public"
printf '#!/usr/bin/env php\n' > "$FX/laravelapi/artisan"
printf '<?php return 1;\n'    > "$FX/laravelapi/bootstrap/app.php"
echo '{"require":{"laravel/framework":"^13.0"}}' > "$FX/laravelapi/composer.json"

# Symfony tiene composer.json y public/, pero su consola está en bin/console.
mkdir -p "$FX/symfony/bin" "$FX/symfony/public"
printf '#!/usr/bin/env php\n' > "$FX/symfony/bin/console"
echo '{"require":{"symfony/framework-bundle":"^7.0"}}' > "$FX/symfony/composer.json"

# Lumen sí trae 'artisan', y no es Laravel: declara otro framework.
mkdir -p "$FX/lumen/bootstrap" "$FX/lumen/public"
printf '#!/usr/bin/env php\n' > "$FX/lumen/artisan"
printf '<?php return 1;\n'    > "$FX/lumen/bootstrap/app.php"
echo '{"require":{"laravel/lumen-framework":"^10.0"}}' > "$FX/lumen/composer.json"

# Un paquete que se prueba contra Laravel lo declara en require-dev, y no es
# una aplicación: no tiene artisan ni bootstrap/app.php.
mkdir -p "$FX/lpaquete/src"
echo '{"name":"yo/mi-paquete","require-dev":{"laravel/framework":"^13.0"}}' > "$FX/lpaquete/composer.json"
printf '<?php\n' > "$FX/lpaquete/src/Todo.php"

# Statamic es un CMS construido sobre Laravel: se detecta como Laravel, pero
# hay que decir en voz alta lo que significa (principio 1).
mkdir -p "$FX/statamic/bootstrap" "$FX/statamic/public"
printf '#!/usr/bin/env php\n' > "$FX/statamic/artisan"
printf '<?php return 1;\n'    > "$FX/statamic/bootstrap/app.php"
echo '{"require":{"laravel/framework":"^13.0","statamic/cms":"^5.0"}}' > "$FX/statamic/composer.json"

# Un config.toml a secas NO es Hugo: lo usan medio mundo. Hace falta la forma.
mkdir -p "$FX/noHugo"
printf '[tool]\nx = 1\n' > "$FX/noHugo/config.toml"
echo '{"dependencies":{"express":"^4"},"scripts":{"start":"node server.js"}}' > "$FX/noHugo/package.json"
touch "$FX/noHugo/package-lock.json"

section "Detección de stack"
A_NAME="test"

detect_stack "$FX/next";     check "next"        "next"    "$A_TYPE"
detect_stack "$FX/next";     check "next pkg"    "pnpm"    "$A_PKG"
detect_stack "$FX/nextexp";  check "next export" "static"  "$A_TYPE"
detect_stack "$FX/nextexp";  check "next outdir" "out"     "$A_OUTDIR"
detect_stack "$FX/astro";    check "astro"       "static"  "$A_TYPE"
detect_stack "$FX/astro";    check "astro spa"   "no"      "$A_SPA"
detect_stack "$FX/astrossr"; check "astro ssr"   "node"    "$A_TYPE"
detect_stack "$FX/vite";     check "vite"        "static"  "$A_TYPE"
detect_stack "$FX/vite";     check "vite spa"    "yes"     "$A_SPA"
detect_stack "$FX/vite";     check "vite pkg"    "npm"     "$A_PKG"
detect_stack "$FX/cra";      check "cra outdir"  "build"   "$A_OUTDIR"
detect_stack "$FX/cra";      check "cra pkg"     "yarn"    "$A_PKG"
detect_stack "$FX/express";  check "express"     "node"    "$A_TYPE"
detect_stack "$FX/php";      check "php"         "php"     "$A_TYPE"
detect_stack "$FX/php";      check "php docroot" "public"  "$A_DOCROOT"
detect_stack "$FX/py";       check "python"      "python"  "$A_TYPE"
detect_stack "$FX/plain";    check "html suelto" "static"  "$A_TYPE"

section "SvelteKit: manda el adaptador, no el framework"
# SvelteKit se construye con Vite, así que sin una rama propia caería en la de
# 'vite' y se serviría como SPA desde dist/ — una carpeta que no existe.
detect_stack "$FX/sveltenode";   check "adapter-node"        "node"   "$A_TYPE"
detect_stack "$FX/sveltenode";   check "arranca con node build" "node build" "$A_START"
detect_stack "$FX/sveltestatic"; check "adapter-static"      "static" "$A_TYPE"
detect_stack "$FX/sveltestatic"; check "y sale en build/"    "build"  "$A_OUTDIR"
detect_stack "$FX/sveltestatic"; check "no es una SPA"       "no"     "$A_SPA"
# adapter-auto no funciona en un VPS, pero equivocarse hacia 'estático'
# publicaría el JavaScript del servidor. Se elige proceso, que como mucho no
# arranca y hace rollback.
detect_stack "$FX/svelte";       check "adapter-auto → proceso" "node" "$A_TYPE"

section "Remix, que hoy es React Router 7"
detect_stack "$FX/rr";     check "react router"        "node"   "$A_TYPE"
detect_stack "$FX/rr";     check "usa su propio start" "pnpm run start" "$A_START"
detect_stack "$FX/remix";  check "remix de los de antes" "node" "$A_TYPE"
detect_stack "$FX/remix";  check "sin script start"    "pnpm exec remix-serve ./build/server/index.js" "$A_START"
# Con ssr:false no hay servidor: es una SPA prerenderizada en build/client.
detect_stack "$FX/rrspa";  check "ssr false → estático" "static" "$A_TYPE"
detect_stack "$FX/rrspa";  check "y en build/client"   "build/client" "$A_OUTDIR"
detect_stack "$FX/rrspa";  check "sin comando de arranque" "" "$A_START"

section "Qwik: lo decide el adaptador, y el adaptador no es un paquete"
# La primera prueba es la que pide docs/DEVELOPMENT.md al añadir un stack: qué pasa cuando
# no casa nada. Aquí «nada» es un Qwik sin adaptador, que es como sale del
# generador — y era el agujero: 'vite' está en las devDependencies de todo
# proyecto de Qwik, así que la rama de Vite lo daba por estático en dist/ con
# respaldo de SPA. Comprobado compilando: sin adaptador, dist/ no tiene
# index.html, o sea que el respaldo apunta a un fichero que no existe y la web
# entera devuelve 404. Se va con proceso para que falle en voz alta (§18.8).
detect_stack "$FX/qwik" >/dev/null 2>&1; check "sin adaptador no es estático" "node" "$A_TYPE"
detect_stack "$FX/qwik" >/dev/null 2>&1; check "y no publica el repo"         ""     "$A_OUTDIR"
# Y lo dice: un despliegue que falla sin explicar por qué manda a depurar nginx.
_avisa_qwik() { detect_stack "$FX/$1" 2>&1 | grep -c 'adaptador' ; }
check "avisa de que le falta el adaptador" "1" "$(_avisa_qwik qwik | head -1)"
check "y también si es de otra plataforma" "1" "$(_avisa_qwik qwikcf | head -1)"
detect_stack "$FX/qwikcf" >/dev/null 2>&1; check "cloudflare-pages → proceso" "node" "$A_TYPE"

# Los que sí dejan un servidor. El arranque sale del script 'serve' que escribe
# el propio adaptador, no de 'start': en Qwik 'start' es 'vite --mode ssr', o
# sea el servidor de desarrollo. Es el único stack donde 'start' no vale.
detect_stack "$FX/qwikexpress"; check "adaptador express"   "node" "$A_TYPE"
detect_stack "$FX/qwikexpress"; check "arranca por su serve" "node server/entry.express" "$A_START"
detect_stack "$FX/qwiknode";    check "adaptador node-server" "node server/entry.node-server" "$A_START"
detect_stack "$FX/qwikfastify"; check "adaptador fastify"   "node server/entry.fastify" "$A_START"
# El tipo tiene que decir el runtime: de él dependen el binario que exige
# 'orbit doctor' y lo que enseña 'orbit list'.
detect_stack "$FX/qwikbun";  check "adaptador bun"  "bun"  "$A_TYPE"
detect_stack "$FX/qwikbun";  check "y arranca con bun" "bun server/entry.bun.js" "$A_START"
detect_stack "$FX/qwikdeno"; check "adaptador deno" "deno" "$A_TYPE"

# El adaptador estático es el único que deja un sitio servible. Comprobado
# compilando: dist/ con index.html, demo/ y un 404.html de verdad — por eso no
# es SPA, o ese 404.html no se usaría nunca.
detect_stack "$FX/qwikstatic"; check "adaptador static"     "static" "$A_TYPE"
detect_stack "$FX/qwikstatic"; check "y sale en dist/"      "dist"   "$A_OUTDIR"
detect_stack "$FX/qwikstatic"; check "no es una SPA"        "no"     "$A_SPA"
detect_stack "$FX/qwikstatic"; check "sin comando de arranque" ""    "$A_START"

# Con dos adaptadores manda el que deja un servidor: sabe contestar a todo, y
# el estático solo dejaría sin servir lo que no esté prerenderizado.
detect_stack "$FX/qwikdual"; check "static junto a express"  "node" "$A_TYPE"
detect_stack "$FX/qwikdual"; check "y arranca el servidor"   "node server/entry.express" "$A_START"
detect_stack "$FX/qwikdual"; check "sin servir dist/"        ""     "$A_OUTDIR"
# Y uno de otra plataforma no tapa al que sí vale, aunque vaya antes en orden
# alfabético — que es como se equivocaba quedándose con el primero.
detect_stack "$FX/qwikazex" >/dev/null 2>&1; check "azure no tapa a express" "node server/entry.express" "$A_START"
check "y no avisa de lo que sí se puede desplegar" "0" "$(_avisa_qwik qwikazex | head -1)"
detect_stack "$FX/qwikazst" >/dev/null 2>&1; check "ni al estático"     "static" "$A_TYPE"
detect_stack "$FX/qwikazst" >/dev/null 2>&1; check "que sigue en dist/" "dist"   "$A_OUTDIR"

# Qwik 2 renombró los paquetes (@qwik.dev/*) y mantuvo la convención.
detect_stack "$FX/qwikv2"; check "qwik 2"                   "node" "$A_TYPE"
detect_stack "$FX/qwikv2"; check "y arranca igual"          "node server/entry.node-server" "$A_START"

# En un monorepo las rutas se traducen a la raíz de la release, que es desde
# donde trabajan nginx y systemd.
detect_stack "$FX/qwikmono"; check "qwik en apps/web"       "apps/web" "$A_APPDIR"
detect_stack "$FX/qwikmono"; check "y el arranque lleva la ruta" "node apps/web/server/entry.node-server" "$A_START"
detect_stack "$FX/qwikmonostatic"; check "y el estático también" "apps/web/dist" "$A_OUTDIR"

section "Angular: la carpeta lleva el nombre del proyecto"
# angular.json moderno no declara outputPath: la ruta se deduce del nombre del
# proyecto, que no tiene por qué ser el del repositorio. Y el builder nuevo
# mete un 'browser' dentro. Comprobado compilando un Angular 20 de verdad.
detect_stack "$FX/ng";    check "angular"            "static" "$A_TYPE"
detect_stack "$FX/ng";    check "es una SPA"         "yes"    "$A_SPA"
# Con SSR manda el servidor: nginx no puede resolver las rutas por su cuenta.
detect_stack "$FX/ngssr"; check "angular con ssr"    "node"   "$A_TYPE"
# Lo que sale de leer angular.json necesita jq. Sin él, _detect_angular tiene un
# camino de respaldo declarado —el nombre del proyecto es el del directorio— y
# estas tres afirmaciones dejan de ser ciertas por diseño.
#
# Antes iban sin guardia, así que 'make test' sin jq salía **en rojo** con tres
# fallos que parecían un bug de la detección de Angular. Un tercer estado, y el
# peor de los tres: ni probado ni saltado, sino acusando a quien no era. Ahora
# se anuncia el salto como el resto de la suite, y así 'make test-strict' —que
# es el que se niega a mentir— lo cuenta entre lo que no se ha ejecutado.
if ! command -v jq >/dev/null; then
  echo "  (falta jq: me salto lo que sale de leer angular.json)"
else
  detect_stack "$FX/ng";    check "dist/<proyecto>/browser" "dist/mi-panel/browser" "$A_OUTDIR"
  # El builder antiguo no mete subcarpeta y sí declara la ruta.
  detect_stack "$FX/ngold"; check "builder antiguo"    "dist/viejo" "$A_OUTDIR"
  detect_stack "$FX/ngssr"; check "arranca el server.mjs" "node dist/tienda/server/server.mjs" "$A_START"
fi

section "Hugo y Eleventy"
detect_stack "$FX/hugo";   check "hugo"              "static" "$A_TYPE"
detect_stack "$FX/hugo";   check "compila con hugo"  "hugo --minify" "$A_BUILD"
detect_stack "$FX/hugo";   check "sale en public/"   "public" "$A_OUTDIR"
# Un sitio de Hugo con Tailwind lleva package.json, y ahí se confundía con un
# proyecto de JavaScript sin framework: se compilaba a un dist/ inexistente.
detect_stack "$FX/hugotw"; check "hugo con tailwind" "static" "$A_TYPE"
detect_stack "$FX/hugotw"; check "instala y compila" "npm ci --include=dev && hugo --minify" "$A_BUILD"
detect_stack "$FX/hugotw"; check "y sigue en public/" "public" "$A_OUTDIR"

section "Go"
# El paquete main no está en main.go: se busca leyendo los ficheros, no por el
# nombre, porque 'package main' puede vivir en servidor.go y un main.go puede
# declarar cualquier otro paquete.
detect_stack "$FX/go";       check "go"              "go"   "$A_TYPE"
detect_stack "$FX/go";       check "go pkg"          "go"   "$A_PKG"
detect_stack "$FX/go";       check "build"  "go build -trimpath -o bin/app ." "$A_BUILD"
detect_stack "$FX/go";       check "arranque"        "./bin/app" "$A_START"
# -trimpath no es cosmética: sin él la ruta de la release queda dentro del
# binario, y esa carpeta la borra la poda dentro de KEEP_RELEASES despliegues.
detect_stack "$FX/go";       check "lleva -trimpath" "1" "$(grep -c -- '-trimpath' <<<"$A_BUILD")"
detect_stack "$FX/go";       check "sin carpeta web" ""     "$A_OUTDIR"
run needs_svc go;            check "lleva unidad"    "0"    "$?"

# Con varios binarios se elige el que parece el servidor, no el primero por
# orden alfabético —que sería el migrador—.
detect_stack "$FX/gomulti" 2>/dev/null
check "varios binarios" "go build -trimpath -o bin/app ./cmd/servidor" "$A_BUILD"
out="$(detect_stack "$FX/gomulti" 2>&1)"
check "y avisa de que elige" "1" "$(grep -c 'varios binarios' <<<"$out")"

# Los cuatro que NO son Go, y cada uno por un motivo distinto.
detect_stack "$FX/hugomod";  check "hugo con módulos" "static" "$A_TYPE"
detect_stack "$FX/hugomod";  check "y compila con hugo" "1" "$(grep -c hugo <<<"$A_BUILD")"
detect_stack "$FX/golib";    check "librería sin main" "static" "$A_TYPE"
detect_stack "$FX/gosuelto"; check ".go sin go.mod"    "static" "$A_TYPE"
# Éste es el que más duele si falla: saldría 'static' con A_OUTDIR=dist, una
# carpeta que nadie genera, y la web entera en 404.
detect_stack "$FX/goembed" 2>/dev/null
check "go:embed gana a vite" "go" "$A_TYPE"

# Una app que no nombra PORT no puede escuchar donde Orbit le dice, y eso se
# avisa al detectar y no 40 segundos después, con el health check agotándose.
out="$(detect_stack "$FX/goport" 2>&1)"
check "avisa si no lee PORT" "1" "$(grep -c 'variable PORT' <<<"$out")"
out="$(detect_stack "$FX/go" 2>&1)"
check "y calla si la lee"    "0" "$(grep -c 'variable PORT' <<<"$out")"
# 'config.toml' lo usa medio mundo: sin la forma de un sitio de Hugo, no es Hugo.
detect_stack "$FX/noHugo"; check "config.toml no basta" "node" "$A_TYPE"
detect_stack "$FX/eleventy"; check "eleventy"        "static" "$A_TYPE"
detect_stack "$FX/eleventy"; check "sale en _site/"  "_site"  "$A_OUTDIR"

section "Deno y Bun"
# Lo primero, y lo que motiva la rama entera: ninguno de los dos puede acabar
# en 'static'. Un tipo estático significa nginx sirviendo el repositorio desde
# disco, o sea el código del servidor a la vista. Comprobado contra nginx:
# antes de esto, GET /main.ts devolvía 200 con el fichero entero.
detect_stack "$FX/deno";      check "deno"            "deno"  "$A_TYPE"
detect_stack "$FX/deno";      check "deno pkg"        "deno"  "$A_PKG"
detect_stack "$FX/deno";      check "y no es estático" ""     "$A_OUTDIR"
run needs_svc deno;           check "lleva unidad"    "0"     "$?"
# 'deno check' delante del arranque: un error de tipos revienta el build, con
# rollback, en vez de dejar el servicio en el bucle de Restart=always.
detect_stack "$FX/deno";      check "build"  "deno install --frozen && deno check main.ts" "$A_BUILD"
# Deno.serve en el fichero → 'deno run'. Sin él, el fichero exporta un default
# y hace falta 'deno serve', que además no lee PORT y escucha en 0.0.0.0.
detect_stack "$FX/deno"
check "arranque con deno run" "deno run --cached-only --allow-net --allow-env --allow-read=. main.ts" "$A_START"
detect_stack "$FX/denoserve"
check "arranque con deno serve" "1" "$(grep -c -- 'deno serve .*--port ${PORT} --host 127.0.0.1' <<<"$A_START")"
# Los permisos son de la aplicación: si el repositorio los declara, Orbit no
# se los pisa.
detect_stack "$FX/denoperm";  check "permisos del repo" "1" "$(grep -c -- ' -P ' <<<"$A_START")"
detect_stack "$FX/denoperm";  check "y no los suyos"    "0" "$(grep -c -- '--allow-net' <<<"$A_START")"
# El fichero de arranque puede no llamarse como ninguno de los de siempre.
detect_stack "$FX/denotask";  check "entrada por la tarea" "1" "$(grep -c 'api/entrada.ts' <<<"$A_START")"
# Y si no hay forma de saberlo, se avisa —pero sigue sin ser estático—.
out="$(detect_stack "$FX/denosinentry" 2>&1)"
check "avisa si no hay arranque" "1" "$(grep -c 'fichero de arranque' <<<"$out")"
detect_stack "$FX/denosinentry" 2>/dev/null
check "y aun así no es estático" "deno" "$A_TYPE"
# Los dos que NO son Deno.
detect_stack "$FX/denofmt";   check "deno.json de 'deno fmt'" "static" "$A_TYPE"
detect_stack "$FX/denonext";  check "next instalado con deno" "next"   "$A_TYPE"

# Bun: como runtime cambia el tipo; como gestor de paquetes, sólo A_PKG.
detect_stack "$FX/bun";       check "bun"             "bun"   "$A_TYPE"
detect_stack "$FX/bun";       check "bun pkg"         "bun"   "$A_PKG"
detect_stack "$FX/bun";       check "y no es estático" ""     "$A_OUTDIR"
run needs_svc bun;            check "lleva unidad"    "0"     "$?"
detect_stack "$FX/bun";       check "instala congelado" "bun install --frozen-lockfile" "$A_BUILD"
detect_stack "$FX/bun";       check "arranque"        "bun run start" "$A_START"
# El que motiva las señales de apoyo: sin script de arranque, esto se publicaba
# como sitio estático con el index.ts dentro.
detect_stack "$FX/bunserve";  check "Bun.serve sin script" "bun" "$A_TYPE"
detect_stack "$FX/bunserve";  check "y arranca su fichero" "bun run index.ts" "$A_START"
# Bun como gestor: el tipo lo sigue decidiendo el framework.
detect_stack "$FX/bunnext";   check "next con bun"    "next"  "$A_TYPE"
detect_stack "$FX/bunnext";   check "pero instala bun" "bun"  "$A_PKG"
detect_stack "$FX/bunnext";   check "sin bun install a mano" "1" "$(grep -c 'bun install --frozen-lockfile' <<<"$A_BUILD")"
# Hono corre en los dos: decide el script de arranque, no la dependencia.
detect_stack "$FX/bunhono";   check "hono con bun"    "bun"   "$A_TYPE"
detect_stack "$FX/nodehono";  check "hono con node"   "node"  "$A_TYPE"

section "Nada acaba sirviendo el código fuente por accidente"
# La regla, y vale para el stack que se añada mañana: la rama de repuesto es
# 'static' con A_OUTDIR=".", o sea nginx sirviendo la raíz del repositorio. Para
# un sitio que es HTML está bien; para cualquier otra cosa es publicar el código
# y el .env. Ante la duda, con proceso: un despliegue que falla en voz alta es
# mejor que uno que sale bien y enseña los secretos.
detect_stack "$FX/bunsinlock";  check "bun sin lockfile"   "bun"  "$A_TYPE"
detect_stack "$FX/bunsinlock";  check "y el gestor cuadra" "bun"  "$A_PKG"
# El fallo de antes era éste: tipo 'bun' compilado con pnpm, o sea que el
# diagnóstico exigía un binario y el build necesitaba el otro.
detect_stack "$FX/bunsinlock";  check "instala con bun"    "bun install" "$A_BUILD"
detect_stack "$FX/bunfigsolo";  check "bun sin package.json" "bun" "$A_TYPE"
detect_stack "$FX/denosuelto";  check "deno sin config"    "deno" "$A_TYPE"
detect_stack "$FX/nodesuelto";  check "node sin framework" "node" "$A_TYPE"
detect_stack "$FX/nodesuelto";  check "y arranca su script" "npm run start" "$A_START"
# Un paso de build no convierte un servidor en un sitio estático: lo tienen casi
# todos los servidores compilados. Lo que decide es que haya un 'start'.
detect_stack "$FX/nodets";      check "node en TypeScript" "node" "$A_TYPE"
# Con las dependencias de desarrollo puestas, que es de donde sale 'tsc': sin
# ellas el build no tendría con qué compilar.
detect_stack "$FX/nodets";      check "compila antes de arrancar" "npm ci --include=dev && npm run build" "$A_BUILD"
detect_stack "$FX/nodets";      check "y arranca lo compilado" "npm run start" "$A_START"
# Y lo que costó el bug: 'dist' existe porque tsc la crea, así que servirla como
# estática no habría dado ni el aviso de la carpeta ausente.
detect_stack "$FX/nodets";      check "no publica el dist compilado" "" "$A_OUTDIR"
# Ninguno de los cinco puede quedarse con la raíz del repo como docroot.
for f in bunsinlock bunfigsolo denosuelto nodesuelto nodets; do
  detect_stack "$FX/$f" >/dev/null 2>&1
  check "$f no sirve el repo" "" "$A_OUTDIR"
done
# Y cuando de verdad no se reconoce nada, se dice: es lo único honesto.
out="$(detect_stack "$FX/gosuelto" 2>&1)"
check "y si no lo reconoce, avisa" "1" "$(grep -c 'No reconozco este repositorio' <<<"$out")"

section "Deno: lo que decide el arranque"
# Un deno.lock suelto no convierte una app de Node en una app de Deno.
detect_stack "$FX/nodecondeno"; check "node con deno.lock"  "node" "$A_TYPE"
# --frozen sólo con lockfile: sin él, 'deno install --frozen' sale con 1 y
# vuelca el diff del lockfile que acaba de calcular. Ese repo no se desplegaría
# nunca. Medido con deno 2.9.5.
detect_stack "$FX/denosuelto";  check "sin lock, sin --frozen" "0" "$(grep -c -- '--frozen' <<<"$A_BUILD")"
detect_stack "$FX/deno";        check "con lock, con --frozen" "1" "$(grep -c -- '--frozen' <<<"$A_BUILD")"
# Lo que decide entre 'deno run' y 'deno serve' es el export default, no el
# literal 'Deno.serve'. Fresh y Oak no lo escriben, y 'deno serve' sobre un
# módulo sin default falla… **saliendo con 0**, así que systemd lo ve como una
# salida limpia y sólo lo caza el health check.
detect_stack "$FX/denolisten";  check "sin default, deno run" "1" "$(grep -c '^deno run ' <<<"$A_START")"
detect_stack "$FX/denolisten";  check "y ejecuta su build"    "1" "$(grep -c 'deno task build' <<<"$A_BUILD")"
detect_stack "$FX/denoserve";   check "con default, deno serve" "1" "$(grep -c '^deno serve ' <<<"$A_START")"
# El deno.jsonc lleva comentarios —es su motivo de existir— y jq no sabe
# leerlos: sin quitarlos, este repositorio se quedaba sin fichero de arranque
# aunque su tarea lo dijera con todas las letras.
detect_stack "$FX/denojsonc";   check "jsonc con comentarios" "1" "$(grep -c 'api/entrada.ts' <<<"$A_START")"
detect_stack "$FX/denoobjeto";  check "tarea como objeto"     "1" "$(grep -c 'api/main.ts' <<<"$A_START")"
# Y la tarea manda sobre los nombres de siempre: quien mejor sabe cuál es el
# servidor es quien escribió el repositorio.
detect_stack "$FX/denotarea";   check "la tarea gana a main.ts" "1" "$(grep -c 'src/servidor.ts' <<<"$A_START")"

section "Laravel"
# El bug de partida, medido sobre un 'composer create-project laravel/laravel'
# de verdad: la rama de package.json iba antes que la de composer.json, veía el
# 'vite' de las devDependencies y publicaba la app como estática apuntando a un
# dist/ que Laravel no genera jamás. La web entera en 404.
detect_stack "$FX/laravel";    check "laravel"          "laravel" "$A_TYPE"
detect_stack "$FX/laravel";    check "y no estático"    ""        "$A_OUTDIR"
detect_stack "$FX/laravel";    check "docroot fijo"     "public"  "$A_DOCROOT"
detect_stack "$FX/laravel";    check "no lleva unidad"  "1"       "$(needs_svc laravel && echo 0 || echo 1)"
# --force no es opcional: en producción y sin terminal, artisan pide
# confirmación y aborta con 1. La decisión sigue siendo del usuario, tomada en
# 'orbit migrate', que pregunta y enseña el plan antes.
detect_stack "$FX/laravel";    check "migración"        "php artisan migrate --force" "$A_MIGRATE"
# composer primero: su post-autoload-dump lanza 'artisan package:discover', que
# necesita el vendor/ recién generado.
detect_stack "$FX/laravel"
check "composer va primero" "1" "$(grep -c '^composer install --no-dev' <<<"$A_BUILD")"
# Y los assets detrás, con las banderas de desarrollo: vite y tailwind están en
# devDependencies, así que un install de producción deja el build sin compilador.
check "y compila los assets" "1" "$(grep -c 'npm ci --include=dev && npm run build' <<<"$A_BUILD")"

# Sin package.json no hay nada de JavaScript que instalar.
detect_stack "$FX/laravelapi"; check "api sin assets"   "composer install --no-dev --optimize-autoloader --no-interaction" "$A_BUILD"
detect_stack "$FX/laravelapi"; check "y el gestor lo dice" "composer" "$A_PKG"

# Los tres que NO son Laravel, cada uno por una señal distinta.
detect_stack "$FX/symfony";    check "symfony no"       "php"     "$A_TYPE"
detect_stack "$FX/lumen";      check "lumen tampoco"    "php"     "$A_TYPE"
detect_stack "$FX/lpaquete";   check "un paquete menos" "php"     "$A_TYPE"

# Un CMS sobre Laravel se detecta, y se dice lo que significa: cada despliegue
# rehace la carpeta, así que lo que se instale desde su panel desaparece.
detect_stack "$FX/statamic" >/dev/null 2>&1
check "statamic es laravel"    "laravel" "$A_TYPE"
out="$(detect_stack "$FX/statamic" 2>&1)"
check "y avisa de que es un CMS" "1" "$(grep -c 'statamic/cms' <<<"$out")"
out="$(detect_stack "$FX/laravel" 2>&1)"
check "y calla si no lo es"      "0" "$(grep -c 'es un CMS' <<<"$out")"

section "Laravel fuera de la raíz (monorepo)"
# El agujero de partida, medido antes de escribir nada: un repositorio con el
# Laravel en backend/ y el frontend al lado no casaba con ninguna rama de
# detect_stack —ni package.json en la raíz, ni composer.json, ni .php sueltos,
# ni index.html—, así que caía en la de repuesto: A_TYPE=static con
# A_OUTDIR='.', o sea nginx sirviendo el repositorio entero, **y** A_PHP=yes
# porque _has_php encontraba los .php de Laravel dentro. Publicar el código y
# ejecutarlo, las dos cosas a la vez.
_mklaravel() { # _mklaravel <dir> [lockfile]
  mkdir -p "$1/bootstrap" "$1/public" "$1/storage/framework/cache" "$1/database"
  printf '#!/usr/bin/env php\n' > "$1/artisan"
  printf '<?php return 1;\n'    > "$1/bootstrap/app.php"
  echo '{"require":{"php":"^8.2","laravel/framework":"^13.0"}}' > "$1/composer.json"
  printf '<?php\n' > "$1/public/index.php"
  [[ -n "${2:-}" ]] && touch "$1/$2"
  return 0
}

mkdir -p "$FX/mono/frontend"
_mklaravel "$FX/mono/backend"
echo '{"devDependencies":{"vite":"6"},"scripts":{"build":"vite build"}}' > "$FX/mono/frontend/package.json"
detect_stack "$FX/mono" >/dev/null 2>&1
check "sigue siendo laravel"   "laravel"        "$A_TYPE"
check "y sabe dónde está"      "backend"        "$A_APPDIR"
# Lo que importa de verdad: el docroot es el public/ **de la app**, no la raíz
# del repositorio. Si esto sale 'public' a secas, nginx apunta a una carpeta que
# no existe y _warn_missing_root manda; si sale vacío, sirve el repo entero.
check "docroot dentro"         "backend/public" "$A_DOCROOT"
check "y nada de estático"     ""               "$A_OUTDIR"
# El build empieza en la raíz de la release (_build_run hace cd "$rel"), así que
# la orden tiene que entrar ella sola en la carpeta del Laravel.
check "el build entra"         "1" "$(grep -c '^cd backend && composer install' <<<"$A_BUILD")"
check "y la migración también" "cd backend && php artisan migrate --force" "$A_MIGRATE"

# El frontend de al lado no se compila ni se sirve, y eso se dice: es la
# diferencia entre una decisión y un olvido.
out="$(detect_stack "$FX/mono" 2>&1)"
check "avisa del frontend"     "1" "$(grep -c "otro paquete de JavaScript en 'frontend/'" <<<"$out")"
# Con el nombre dentro, no sólo la frase: la primera versión de esta prueba
# buscaba 'La app está en' y pasaba con el '%s' vacío, que es justo lo que
# hacía una llamada recursiva al pisar el global del que salía el nombre.
check "y dice dónde está"      "1" "$(grep -c 'La app está en .*backend' <<<"$out")"

# Segundo nivel: 'apps/api' es el otro reparto que se ve.
mkdir -p "$FX/mono2/apps"
_mklaravel "$FX/mono2/apps/api"
detect_stack "$FX/mono2" >/dev/null 2>&1
check "dos niveles"            "apps/api"        "$A_APPDIR"
check "y su docroot"           "apps/api/public" "$A_DOCROOT"

# El gestor de paquetes sale del lockfile de la app, no del de la raíz. Sin
# esto, un backend/ con package-lock.json se instalaba con pnpm.
mkdir -p "$FX/monopkg"
_mklaravel "$FX/monopkg/backend" package-lock.json
echo '{"devDependencies":{"vite":"6"},"scripts":{"build":"vite build"}}' > "$FX/monopkg/backend/package.json"
detect_stack "$FX/monopkg" >/dev/null 2>&1
check "el gestor es el de la app" "npm" "$A_PKG"
check "y el install va dentro"    "1"   "$(grep -c 'npm ci --include=dev && npm run build' <<<"$A_BUILD")"

# Un Laravel dentro de vendor/ es una dependencia —una bifurcación vendorizada,
# el esqueleto que traen los paquetes para probarse—, no la app. Va a dos
# niveles porque es donde de verdad cae ('vendor/<org>/'), que es justo el
# alcance que recorre _stack_dirs: ponerlo más hondo probaría el límite de
# profundidad y no la poda, y pasaría con la poda quitada.
mkdir -p "$FX/monovendor"
_mklaravel "$FX/monovendor/vendor/acme"
printf '<?php echo 1;\n' > "$FX/monovendor/index.php"
detect_stack "$FX/monovendor" >/dev/null 2>&1
check "vendor no cuenta"       "php" "$A_TYPE"
check "y no se queda appdir"   "."   "$A_APPDIR"

# Y por debajo de dos niveles no se busca: no hay convención que seguir ahí, y
# recorrer el repositorio entero costaría caro para acertar poco. Se comprueba
# para que el límite sea una decisión y no un accidente.
mkdir -p "$FX/monohondo"
_mklaravel "$FX/monohondo/a/b/c"
detect_stack "$FX/monohondo" >/dev/null 2>&1
check "tres niveles ya no"     "."      "$A_APPDIR"
check "y cae en la de repuesto" "static" "$A_TYPE"

# Con varios, se elige por nombre y se dice cuál. Equivocarse aquí no publica
# nada raro —el docroot sigue siendo el public/ de un Laravel—, pero callarse sí
# dejaría a alguien mirando por qué se despliega la otra.
mkdir -p "$FX/monodos"
_mklaravel "$FX/monodos/admin"
_mklaravel "$FX/monodos/backend"
detect_stack "$FX/monodos" >/dev/null 2>&1
check "gana el nombre de siempre" "backend" "$A_APPDIR"
out="$(detect_stack "$FX/monodos" 2>&1)"
check "y lo dice"              "1" "$(grep -c 'varias apps desplegables' <<<"$out")"

# La raíz sigue mandando: un Laravel en la raíz no se va a buscar a otra parte
# aunque haya uno dentro.
mkdir -p "$FX/monoraiz"
_mklaravel "$FX/monoraiz"
_mklaravel "$FX/monoraiz/otro"
detect_stack "$FX/monoraiz" >/dev/null 2>&1
check "la raíz gana"           "."      "$A_APPDIR"
check "y su docroot es plano"  "public" "$A_DOCROOT"

# Y la raíz que se declara a sí misma manda sobre lo que haya dos carpetas más
# abajo: un monorepo de JavaScript que trae un Laravel de ejemplo se despliega
# como lo que dice la raíz, no como el ejemplo. Con el Laravel *en* la raíz sí
# gana Laravel (§18.5), y esa distinción es justo la que se comprueba aquí.
mkdir -p "$FX/monojs"
echo '{"dependencies":{"next":"15"},"scripts":{"build":"next build","start":"next start"}}' > "$FX/monojs/package.json"
touch "$FX/monojs/pnpm-lock.yaml"
_mklaravel "$FX/monojs/playgrounds/laravel"
detect_stack "$FX/monojs" >/dev/null 2>&1
check "la raíz de JS manda"    "next" "$A_TYPE"
check "y sin subcarpeta"       "."    "$A_APPDIR"
# Y no por una guardia especial, sino porque la raíz se lleva su propia rama
# mucho antes de que se mire ninguna subcarpeta: la regla es estructural.
check "y el ejemplo no se toca"  "next" "$A_TYPE"

section "Los demás stacks tampoco tienen que estar en la raíz"
# Lo de Laravel no era de Laravel. Medido antes de generalizar: un Go en
# 'backend/', un Django en 'backend/' y un Hugo en 'site/' daban los tres
# A_TYPE=static con A_OUTDIR='.', o sea nginx sirviendo el repositorio entero.
# El mismo agujero de §18.8, con el código fuente publicado en vez de ejecutado.

# Go. El binario se compila y se arranca dentro de la carpeta, y el 'cd' del
# arranque importa: la unidad tiene WorkingDirectory en la raíz de la release.
mkdir -p "$FX/monogo/backend"
printf 'module ejemplo\ngo 1.22\n' > "$FX/monogo/backend/go.mod"
printf 'package main\nfunc main(){}\n' > "$FX/monogo/backend/main.go"
detect_stack "$FX/monogo" >/dev/null 2>&1
check "go en backend"          "go"      "$A_TYPE"
check "y lo sabe"              "backend" "$A_APPDIR"
check "compila dentro"         "1" "$(grep -c '^cd backend && go build' <<<"$A_BUILD")"
check "y arranca dentro"       "cd backend && ./bin/app" "$A_START"
# Y NO se queda como estática sirviendo la raíz, que era el fallo.
check "no publica el repo"     ""        "$A_OUTDIR"

# Django. Todo lo suyo es relativo al directorio de la app —el venv, manage.py,
# requirements.txt—, así que basta con entrar; pero hay que entrar en los tres
# sitios: build, arranque y migración.
mkdir -p "$FX/monody/backend/proj"
printf 'Django==5.2\n' > "$FX/monody/backend/requirements.txt"
printf "import os\ndef main():\n    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'proj.settings')\n" \
  > "$FX/monody/backend/manage.py"
touch "$FX/monody/backend/proj/__init__.py" "$FX/monody/backend/proj/settings.py" \
      "$FX/monody/backend/proj/wsgi.py"
detect_stack "$FX/monody" >/dev/null 2>&1
check "django en backend"      "python"  "$A_TYPE"
check "framework"              "django"  "$A_PYFW"
check "subcarpeta"             "backend" "$A_APPDIR"
check "el venv se crea dentro" "1" "$(grep -c '^cd backend && python3 -m venv .venv' <<<"$A_BUILD")"
check "collectstatic también"  "1" "$(grep -c 'manage.py collectstatic' <<<"$A_BUILD")"
check "arranca dentro"         "1" "$(grep -c '^cd backend && ./.venv/bin/gunicorn' <<<"$A_START")"
# La migración va por _run_in_app, que también parte de la raíz de la release.
check "y migra dentro"         "cd backend && ./.venv/bin/python manage.py migrate" "$A_MIGRATE"
check "y el módulo es el suyo" "proj.wsgi:application" "$A_PYAPP"

# Hugo. Aquí lo que se mueve es la carpeta compilada, que es lo que sirve nginx.
mkdir -p "$FX/monohugo/site/content" "$FX/monohugo/site/layouts"
printf 'title = "x"\n' > "$FX/monohugo/site/hugo.toml"
detect_stack "$FX/monohugo" >/dev/null 2>&1
check "hugo en site"           "static"      "$A_TYPE"
check "subcarpeta"             "site"        "$A_APPDIR"
check "compila dentro"         "cd site && hugo --minify" "$A_BUILD"
# La clave: el docroot es site/public y no public/, que no existiría, ni '.',
# que sería el repositorio entero.
check "y sirve site/public"    "site/public" "$A_OUTDIR"

# El aviso del frontend de al lado vale para todos, no sólo para Laravel: es el
# reparto más común que hay.
mkdir -p "$FX/monogofront/backend" "$FX/monogofront/frontend"
printf 'module ejemplo\ngo 1.22\n'   > "$FX/monogofront/backend/go.mod"
printf 'package main\nfunc main(){}\n' > "$FX/monogofront/backend/main.go"
echo '{"devDependencies":{"vite":"6"},"scripts":{"build":"vite build"}}' > "$FX/monogofront/frontend/package.json"
out="$(detect_stack "$FX/monogofront" 2>&1)"
check "avisa del frontend"     "1" "$(grep -c "otro paquete de JavaScript en 'frontend/'" <<<"$out")"
detect_stack "$FX/monogofront" >/dev/null 2>&1
check "y despliega el backend" "go" "$A_TYPE"

# Con dos stacks distintos manda el orden de la rama principal —Hugo va delante
# de Go, como en la raíz— y se dicen los dos, porque Orbit sirve una app por
# dominio y la otra hay que declararla aparte.
mkdir -p "$FX/monomix/api" "$FX/monomix/site/content" "$FX/monomix/site/layouts"
printf 'module ejemplo\ngo 1.22\n'   > "$FX/monomix/api/go.mod"
printf 'package main\nfunc main(){}\n' > "$FX/monomix/api/main.go"
printf 'title = "x"\n' > "$FX/monomix/site/hugo.toml"
detect_stack "$FX/monomix" >/dev/null 2>&1
check "gana el orden de la raíz" "site" "$A_APPDIR"
out="$(detect_stack "$FX/monomix" 2>&1)"
check "y se dicen las dos"     "1" "$(grep -c 'varias apps desplegables' <<<"$out")"
check "nombrando ambas"        "1" "$(grep -cE 'api.*site|site.*api' <<<"$out")"

# Dentro de un mismo stack manda el nombre de siempre, no el alfabeto.
mkdir -p "$FX/monogodos/admin" "$FX/monogodos/backend"
for d in admin backend; do
  printf 'module ejemplo\ngo 1.22\n'   > "$FX/monogodos/$d/go.mod"
  printf 'package main\nfunc main(){}\n' > "$FX/monogodos/$d/main.go"
done
detect_stack "$FX/monogodos" >/dev/null 2>&1
check "gana 'backend' sobre 'admin'" "backend" "$A_APPDIR"

# Un monorepo dentro de un monorepo, que es lo que sale al pedir una subcarpeta
# que a su vez es un workspace de npm. Las dos rutas se **suman** en A_APPDIR,
# pero el 'cd' llega sólo hasta la subcarpeta: las órdenes de npm ya traen
# dentro la ruta del paquete ('--dir apps/web'), así que entrar hasta el paquete
# las dejaría buscándolo dos veces.
mkdir -p "$FX/monodoble/servicio/apps/web"
echo '{"name":"raiz","workspaces":["apps/*"]}' > "$FX/monodoble/servicio/package.json"
touch "$FX/monodoble/servicio/pnpm-lock.yaml"
echo '{"devDependencies":{"vite":"6"},"scripts":{"build":"vite build"}}' \
  > "$FX/monodoble/servicio/apps/web/package.json"
detect_stack "$FX/monodoble" "servicio" >/dev/null 2>&1
check "las dos rutas se suman"  "servicio/apps/web"      "$A_APPDIR"
check "y la carpeta compilada"  "servicio/apps/web/dist" "$A_OUTDIR"
check "el cd para en servicio"  "1" "$(grep -c '^cd servicio && pnpm install' <<<"$A_BUILD")"
check "y no entra dos veces"    "0" "$(grep -c 'cd servicio/apps/web' <<<"$A_BUILD")"

# Lo que hay en la raíz manda, y sólo se mira dentro cuando la raíz no dice
# nada. Estas cuatro salieron de una regresión de este mismo cambio: la búsqueda
# estaba colocada **delante** de ramas que sí reconocen la raíz, y entonces un
# proyecto normal con una carpeta de utilidades al lado dejaba de servirse. Lo
# encontró probarlo, no leerlo.
mkdir -p "$FX/raizhtml/tools"
printf '<h1>hola</h1>\n' > "$FX/raizhtml/index.html"
printf '[project]\nname="tools"\n' > "$FX/raizhtml/tools/pyproject.toml"
detect_stack "$FX/raizhtml" >/dev/null 2>&1
check "un index.html manda"    "static" "$A_TYPE"
check "y no se va a tools/"    "."      "$A_APPDIR"

mkdir -p "$FX/raizphp/site/content" "$FX/raizphp/site/layouts"
printf '{}\n' > "$FX/raizphp/composer.json"
printf '<?php echo 1;\n' > "$FX/raizphp/index.php"
printf 'title = "docs"\n' > "$FX/raizphp/site/hugo.toml"
detect_stack "$FX/raizphp" >/dev/null 2>&1
check "una app PHP en la raíz manda" "php" "$A_TYPE"
check "y la documentación no gana"   "."   "$A_APPDIR"

# Un requirements.txt en la raíz tampoco se deja adelantar por una subcarpeta.
mkdir -p "$FX/raizpy/site/content" "$FX/raizpy/site/layouts"
printf 'flask\n' > "$FX/raizpy/requirements.txt"
printf 'title = "docs"\n' > "$FX/raizpy/site/hugo.toml"
detect_stack "$FX/raizpy" >/dev/null 2>&1
check "python en la raíz manda" "python" "$A_TYPE"
check "y sin subcarpeta"        "."      "$A_APPDIR"

# En cambio un package.json que no declara framework, no trae script de build y
# no tiene ningún paquete de app dentro es el contenedor de un workspace, no una
# app: ahí sí se mira dentro, porque lo contrario es servir la raíz del
# repositorio. Con script de build se respeta la raíz, que ya es una
# declaración.
mkdir -p "$FX/wsvacio/backend"
echo '{"name":"raiz","workspaces":["packages/*"]}' > "$FX/wsvacio/package.json"
printf 'module ejemplo\ngo 1.22\n'     > "$FX/wsvacio/backend/go.mod"
printf 'package main\nfunc main(){}\n' > "$FX/wsvacio/backend/main.go"
detect_stack "$FX/wsvacio" >/dev/null 2>&1
check "un workspace vacío no manda" "go"      "$A_TYPE"
check "y se busca dentro"           "backend" "$A_APPDIR"
mkdir -p "$FX/wsbuild/backend"
echo '{"name":"raiz","scripts":{"build":"turbo run build"}}' > "$FX/wsbuild/package.json"
printf 'module ejemplo\ngo 1.22\n'     > "$FX/wsbuild/backend/go.mod"
printf 'package main\nfunc main(){}\n' > "$FX/wsbuild/backend/main.go"
detect_stack "$FX/wsbuild" >/dev/null 2>&1
check "con script de build, manda la raíz" "static" "$A_TYPE"
check "y no se va al backend"              "."      "$A_APPDIR"

if command -v jq >/dev/null; then
  section "Una subcarpeta puede declararse a sí misma"
  # El orbit.json sólo se leía de la raíz, así que la app de un monorepo no
  # tenía forma de declarar su despliegue. Ahora se lee en la carpeta que de
  # verdad se está detectando, y sus rutas son relativas a esa carpeta: es
  # donde vive el fichero y donde piensa quien lo escribe.
  mkdir -p "$FX/decl/backend"
  cat > "$FX/decl/backend/orbit.json" <<'JSON'
{"type":"node","build":"cargo build --release","start":"./target/release/api"}
JSON
  printf 'fn main(){}\n' > "$FX/decl/backend/main.rs"
  detect_stack "$FX/decl" >/dev/null 2>&1
  # Ningún heurístico reconoce esto: sin la declaración sería la rama de
  # repuesto, con el repositorio entero publicado.
  check "el tipo lo dice el repo"  "node"    "$A_TYPE"
  check "y dónde está"             "backend" "$A_APPDIR"
  # Las órdenes del descriptor también entran en la carpeta, igual que las
  # detectadas: quien escribe 'cargo build' en backend/orbit.json no está
  # pensando en la raíz del repositorio.
  check "el build entra"           "cd backend && cargo build --release"    "$A_BUILD"
  check "y el arranque también"    "cd backend && ./target/release/api"     "$A_START"

  # Y las rutas se componen, no se copian: 'dist' en backend/orbit.json es
  # backend/dist para nginx, que es quien va a servirlo.
  mkdir -p "$FX/decl2/servicio"
  cat > "$FX/decl2/servicio/orbit.json" <<'JSON'
{"type":"static","outdir":"dist","docroot":"public","build":"make sitio"}
JSON
  detect_stack "$FX/decl2" >/dev/null 2>&1
  check "outdir compuesto"         "servicio/dist"   "$A_OUTDIR"
  check "docroot compuesto"        "servicio/public" "$A_DOCROOT"

  # Si la raíz trae el suyo, gana la raíz: ese fichero describe el repositorio
  # entero, incluida la carpeta donde vive la app.
  mkdir -p "$FX/decl3/backend"
  cp "$FX/decl/backend/orbit.json" "$FX/decl3/backend/orbit.json"
  printf '{"type":"static","outdir":"publico"}\n' > "$FX/decl3/orbit.json"
  detect_stack "$FX/decl3" >/dev/null 2>&1
  check "la raíz declarada manda"  "static"  "$A_TYPE"
  check "y no baja a la subcarpeta" "."      "$A_APPDIR"
  check "con su propia carpeta web" "publico" "$A_OUTDIR"

  # Una declaración manda sobre lo que se infiera de la raíz: es la única
  # búsqueda de subcarpeta que va delante de las ramas de la raíz, porque un
  # orbit.json no aparece por accidente —a diferencia de un pyproject.toml—.
  mkdir -p "$FX/decl4/backend"
  cp "$FX/decl/backend/orbit.json" "$FX/decl4/backend/orbit.json"
  printf '<h1>hola</h1>\n' > "$FX/decl4/index.html"
  detect_stack "$FX/decl4" >/dev/null 2>&1
  check "la declaración gana al index.html" "node"    "$A_TYPE"
  check "y se va a la subcarpeta"           "backend" "$A_APPDIR"

  # Un orbit.json que no se puede aplicar no dirige nada. Con la comprobación
  # floja —«¿existe el fichero?»— un descriptor roto en una subcarpeta se
  # llevaba la detección hacia ella, y una vez dentro no se puede volver a la
  # raíz porque la búsqueda queda apagada: un sitio perfectamente detectable en
  # la raíz acababa sin servirse y con la subcarpeta publicada en su lugar.
  mkdir -p "$FX/declroto/backend"
  printf '<h1>la web de verdad</h1>\n' > "$FX/declroto/index.html"
  printf 'esto no es JSON {{{\n' > "$FX/declroto/backend/orbit.json"
  detect_stack "$FX/declroto" >/dev/null 2>&1
  check "un JSON inválido no manda"   "static" "$A_TYPE"
  check "y la raíz se sigue sirviendo" "."     "$A_APPDIR"
  # Y uno bien formado pero sin 'type' tampoco: _read_descriptor lo rechaza, así
  # que dejarle dirigir la detección sería llevarla a donde nadie la aplica.
  printf '{"outdir":"dist"}\n' > "$FX/declroto/backend/orbit.json"
  detect_stack "$FX/declroto" >/dev/null 2>&1
  check "sin 'type' tampoco manda"    "static" "$A_TYPE"
  check "y sigue en la raíz"          "."      "$A_APPDIR"

  # Lo que el repositorio declara como dato también es una ruta suya: si no se
  # recoloca, el despliegue enlaza release/storage/data mientras la app escribe
  # en release/backend/storage/data, y lo que guarde se pierde en el despliegue
  # siguiente sin decir nada.
  mkdir -p "$FX/declshared/backend"
  cat > "$FX/declshared/backend/orbit.json" <<'JSON'
{"type":"static","outdir":"dist","shared":["storage/data","config.local.php"]}
JSON
  detect_stack "$FX/declshared" >/dev/null 2>&1
  check "shared recolocado" "backend/storage/data backend/config.local.php" "$A_SHARED"

  # La invariante que hay detrás del aviso vacío: con la búsqueda apagada —que
  # es como corre la llamada recursiva— _declared_stack_dir no puede tocar
  # STACK_DIR, porque el nombre que hay dentro es de quien la llamó. Se
  # comprueba aquí y no sólo por el mensaje: en el código hay además una copia
  # local en cada sitio que llama, así que quitar una de las dos defensas no
  # rompe nada visible y la otra se quedaría sin probar.
  # Fuera de 'run': ésa lanza un subshell, y entonces STACK_DIR no sale de él —
  # la comprobación pasaría siempre, que es la trampa del doble que no puede
  # fallar. Se vio al mutar el código a propósito y ver que seguía en verde.
  STACK_DIR="backend"; DETECT_BUSCA_SUB="no"
  _declared_stack_dir "$FX/decl" && r=0 || r=$?
  check "apagada, no responde"     "1"       "$r"
  check "y respeta lo que había"   "backend" "$STACK_DIR"
  DETECT_BUSCA_SUB="si"

  # Un repositorio que se declara no recibe el aviso de «no reconozco esto, te
  # publico el código fuente»: es alarmante, y falso, porque el descriptor lo
  # desmiente tres líneas más abajo.
  out="$(detect_stack "$FX/decl" 2>&1)"
  check "sin aviso de código fuente" "0" "$(grep -c 'publicaría el código fuente' <<<"$out")"
  check "y dice dónde estaba"        "1" "$(grep -c 'La app está en .*backend' <<<"$out")"
fi

# Y un repositorio sin ningún Laravel no se inventa uno: la rama de repuesto
# sigue siendo la rama de repuesto.
mkdir -p "$FX/monoNada/backend"
printf 'hola\n' > "$FX/monoNada/backend/README"
detect_stack "$FX/monoNada" >/dev/null 2>&1
check "sin laravel, nada"      "static" "$A_TYPE"
check "y sin subcarpeta"       "."      "$A_APPDIR"

section "PHP dentro de un proyecto que no es PHP"
# Un Astro con un formulario de contacto en PHP: el tipo sigue siendo estático,
# porque el 99 % del sitio son ficheros, pero ese .php tiene que acabar en
# php-fpm y no servido tal cual.
mkdir -p "$FX/astrophp/public"
cp "$FX/astro/package.json" "$FX/astrophp/package.json"
touch "$FX/astrophp/pnpm-lock.yaml"
printf '<?php mail("a@b.c","x","y"); ?>\n' > "$FX/astrophp/public/contacto.php"
detect_stack "$FX/astrophp"; check "sigue siendo estático" "static" "$A_TYPE"
detect_stack "$FX/astrophp"; check "y además ejecuta PHP"  "yes"    "$A_PHP"
# El caso normal no debe cambiar: una estática sin PHP no lo activa.
detect_stack "$FX/astro";    check "sin php, no se activa" ""       "$A_PHP"
# Y una app PHP de verdad sigue siendo de tipo php, no una estática con añadido.
detect_stack "$FX/php";      check "php sigue siendo php"  "php"    "$A_TYPE"

# Un .php de una dependencia no es del proyecto: hay paquetes de npm que traen
# ejemplos en PHP, y eso no convierte tu web en una app PHP.
mkdir -p "$FX/astrodep/node_modules/algo"
cp "$FX/astro/package.json" "$FX/astrodep/package.json"
touch "$FX/astrodep/pnpm-lock.yaml"
printf '<?php echo 1; ?>\n' > "$FX/astrodep/node_modules/algo/demo.php"
detect_stack "$FX/astrodep"; check "node_modules no cuenta" "" "$A_PHP"
mkdir -p "$FX/astrovendor/vendor"
cp "$FX/astro/package.json" "$FX/astrovendor/package.json"
touch "$FX/astrovendor/pnpm-lock.yaml"
printf '<?php echo 1; ?>\n' > "$FX/astrovendor/vendor/x.php"
detect_stack "$FX/astrovendor"; check "vendor tampoco" "" "$A_PHP"

# Con composer.json además hay que instalar sus dependencias, sin perder el
# build de la parte estática.
mkdir -p "$FX/astrocomposer/public"
cp "$FX/astro/package.json" "$FX/astrocomposer/package.json"
touch "$FX/astrocomposer/pnpm-lock.yaml"
echo '{}' > "$FX/astrocomposer/composer.json"
printf '<?php echo 1; ?>\n' > "$FX/astrocomposer/public/c.php"
detect_stack "$FX/astrocomposer"
check "composer se añade"    "1" "$(grep -c 'composer install' <<<"$A_BUILD")"
check "sin perder el build"  "1" "$(grep -c 'astro build\|run build' <<<"$A_BUILD")"

section "Python: gestor de dependencias"
detect_stack "$FX/django"; check "requirements → pip" "pip"       "$A_PYMGR"
detect_stack "$FX/poetry"; check "poetry.lock"        "poetry"    "$A_PYMGR"
detect_stack "$FX/uv";     check "uv.lock"            "uv"        "$A_PYMGR"
detect_stack "$FX/pyproj"; check "pyproject suelto"   "pyproject" "$A_PYMGR"
# El bug que motivó este ciclo: sin requirements.txt, el build hacía
# 'pip install -r requirements.txt' y fallaba siempre.
detect_stack "$FX/pyproj"
check "no exige requirements" "0" "$(grep -c 'requirements.txt' <<<"$A_BUILD")"
detect_stack "$FX/uv"
check "uv no exige requirements" "0" "$(grep -c 'requirements.txt' <<<"$A_BUILD")"
# El servidor se instala después de las dependencias porque 'uv sync' borra
# todo lo que no esté en el fichero de bloqueo.
check "servidor tras uv sync" "1" \
  "$([[ "$A_BUILD" == *"uv sync"*"pip install uvicorn"* ]] && echo 1 || echo 0)"

section "Python: framework y punto de entrada"
detect_stack "$FX/django"
check "django"            "django"                     "$A_PYFW"
check "módulo de manage"  "miproyecto.wsgi:application" "$A_PYAPP"
check "arranca gunicorn"  "1" "$(grep -c 'gunicorn' <<<"$A_START")"
check "collectstatic"     "1" "$(grep -c 'collectstatic --noinput' <<<"$A_BUILD")"
check "comando de migrar" "./.venv/bin/python manage.py migrate" "$A_MIGRATE"
check "puerto literal"    "1" "$(grep -cF '${PORT}' <<<"$A_START")"

detect_stack "$FX/djchannels"
check "channels → asgi"   "config.asgi:application" "$A_PYAPP"
check "arranca uvicorn"   "1" "$(grep -c 'uvicorn' <<<"$A_START")"

detect_stack "$FX/django"
check "asgi.py solo no basta" "miproyecto.wsgi:application" "$A_PYAPP"

detect_stack "$FX/djraro"
check "paquete por wsgi.py" "elsitio.wsgi:application" "$A_PYAPP"

detect_stack "$FX/fastapi"
check "fastapi"          "fastapi"      "$A_PYFW"
check "objeto anotado"   "app.main:api" "$A_PYAPP"
check "fastapi → uvicorn" "1" "$(grep -c 'uvicorn' <<<"$A_START")"
check "sin migraciones"  ""             "$A_MIGRATE"

detect_stack "$FX/flask"
check "flask"            "flask"     "$A_PYFW"
check "objeto de flask"  "app:app"   "$A_PYAPP"
check "flask → gunicorn" "1" "$(grep -c 'gunicorn' <<<"$A_START")"

detect_stack "$FX/pyproj"
check "flask en wsgi.py" "wsgi:app" "$A_PYAPP"

detect_stack "$FX/uv"
check "fastapi en main"  "main:app" "$A_PYAPP"

# Una app Python que no es ninguno de los tres conocidos no debe inventarse
# un framework ni un comando de migración.
detect_stack "$FX/py"
check "genérico"          "flask" "$A_PYFW"
detect_stack "$FX/django"; A_PYFW=""; detect_stack "$FX/plain"
check "estático sin framework" "" "$A_PYFW"

section "Serialización de configuración"
# Literales ${...} y comillas simples: la trampa que motivó _q().
{
  A_NAME="cfgtest"; A_REPO="x"; A_BRANCH="main"; A_DOMAIN="d.test"; A_ALIASES=""
  A_TYPE="python"; A_PKG="pnpm"; A_BUILD="a && b"
  A_START='gunicorn -b 127.0.0.1:${PORT} app:app'
  A_OUTDIR=""; A_SPA="no"; A_PORT="3002"; A_DOCROOT=""; A_PYAPP="app:app"
  A_CREATED="hoy"; A_LASTDEPLOY="con 'comillas' dentro"
}
save_app
expected_start="$A_START"; expected_last="$A_LASTDEPLOY"
unset A_START A_LASTDEPLOY
load_app cfgtest
check "literal \${PORT}" "$expected_start" "$A_START"
check "comillas simples" "$expected_last"  "$A_LASTDEPLOY"

# A_APPDIR decide dónde busca nginx los assets: si no se persiste, el primer render_nginx
# posterior al alta lo pierde y el alias de /_next/static/ vuelve a apuntar a la raíz.
A_NAME="appdirtest"; A_APPDIR="apps/web"; A_TYPE="next"; A_PORT="3003"
save_app; unset A_APPDIR; load_app appdirtest
check "appdir persistido" "apps/web" "$A_APPDIR"

section "Monorepos (la raíz no declara el framework)"

# getDARC: pnpm workspace, next en apps/web, raíz sólo con herramientas.
# Sin detección de monorepo esto se clasificaba como static+SPA y tumbaba la web entera con
# "rewrite or internal redirection cycle" en TODAS las rutas.
mkdir -p "$TMP/fx/mononext/apps/web" "$TMP/fx/mononext/packages/engine"
touch "$TMP/fx/mononext/pnpm-lock.yaml"
echo "packages: ['apps/*','packages/*']" > "$TMP/fx/mononext/pnpm-workspace.yaml"
echo '{"private":true,"scripts":{"build":"turbo run build","start":"turbo run start"},"devDependencies":{"turbo":"2","prettier":"3"}}' > "$TMP/fx/mononext/package.json"
echo '{"scripts":{"build":"next build","start":"next start"},"dependencies":{"next":"15"}}' > "$TMP/fx/mononext/apps/web/package.json"
echo '{"scripts":{"build":"tsc"},"devDependencies":{"typescript":"5"}}' > "$TMP/fx/mononext/packages/engine/package.json"

detect_stack "$TMP/fx/mononext"; check "mono next"        "next"                        "$A_TYPE"
detect_stack "$TMP/fx/mononext"; check "mono appdir"      "apps/web"                    "$A_APPDIR"
detect_stack "$TMP/fx/mononext"; check "mono start"       "pnpm --dir apps/web run start" "$A_START"

# El outdir de un estático en monorepo tiene que ser relativo a la raíz del repo: es donde
# nginx pone el `root`.
mkdir -p "$TMP/fx/monovite/apps/site"
touch "$TMP/fx/monovite/pnpm-lock.yaml"
echo '{"private":true,"scripts":{"build":"turbo run build"},"devDependencies":{"turbo":"2"}}' > "$TMP/fx/monovite/package.json"
echo '{"scripts":{"build":"vite build"},"devDependencies":{"vite":"6"}}' > "$TMP/fx/monovite/apps/site/package.json"
detect_stack "$TMP/fx/monovite"; check "mono vite"        "static"                      "$A_TYPE"
detect_stack "$TMP/fx/monovite"; check "mono vite outdir" "apps/site/dist"              "$A_OUTDIR"

# Un proyecto de un solo paquete no debe cambiar de comportamiento.
detect_stack "$TMP/fx/next";     check "simple appdir"    "."                           "$A_APPDIR"

if command -v jq >/dev/null; then
  section "orbit.json (el repo se declara y no se infiere nada)"
  cp -r "$TMP/fx/mononext" "$TMP/fx/desc"
  echo '{"type":"node","appdir":"apps/web","start":"node apps/web/run.js"}' > "$TMP/fx/desc/orbit.json"
  detect_stack "$TMP/fx/desc"; _read_descriptor "$TMP/fx/desc" || true
  check "descriptor tipo"  "node"                    "$A_TYPE"
  check "descriptor start" "node apps/web/run.js"    "$A_START"
  check "descriptor appdir" "apps/web"               "$A_APPDIR"

  # Las rutas del descriptor acaban dentro del vhost de nginx y dentro de las
  # operaciones de fichero del despliegue —incluido el 'rm -rf' que sustituye
  # storage/ por el enlace al compartido—, así que una que se sale de la release
  # no se acepta. No es una frontera de seguridad —el mismo fichero declara el
  # 'build', que es una orden de shell— sino la diferencia entre una errata que
  # se ve y una que borra o que tumba nginx entero.
  cp -r "$TMP/fx/mononext" "$TMP/fx/descmalo"
  echo '{"type":"node","appdir":"../../etc","start":"node x.js"}' > "$TMP/fx/descmalo/orbit.json"
  detect_stack "$TMP/fx/descmalo"
  out="$(_read_descriptor "$TMP/fx/descmalo" 2>&1 || true)"
  check "un appdir con .. no entra" "1" "$(grep -c "no es una ruta dentro del repositorio" <<<"$out")"
  check "y la app se queda donde estaba" "apps/web" "$A_APPDIR"

  # Un docroot con un ';' dentro escribe un vhost que nginx no puede leer, y el
  # fichero se enlaza en sites-enabled antes del 'nginx -t': eso tumba la
  # configuración del servidor entero, no sólo la de esta app.
  echo '{"type":"php","docroot":"public; root /etc"}' > "$TMP/fx/descmalo/orbit.json"
  detect_stack "$TMP/fx/descmalo"
  out="$(_read_descriptor "$TMP/fx/descmalo" 2>&1 || true)"
  check "ni un docroot con ';'"  "1" "$(grep -c "no es una ruta dentro del repositorio" <<<"$out")"
  check "y no se queda puesto"   "0" "$(grep -c ';' <<<"$A_DOCROOT")"

  # Y las buenas siguen pasando: un outdir escondido tras un punto es normal.
  echo '{"type":"static","outdir":".output/public"}' > "$TMP/fx/descmalo/orbit.json"
  detect_stack "$TMP/fx/descmalo"; _read_descriptor "$TMP/fx/descmalo" >/dev/null 2>&1 || true
  check "un outdir con punto sí" ".output/public" "$A_OUTDIR"
fi

section "El www sólo donde tiene sentido"
# A un dominio que se compra se le propone el www. A un subdominio no: nadie
# escribe www.blog.midominio.com, y pedirle a Let's Encrypt un certificado para
# un nombre que no está en el DNS puede hacer fallar la emisión entera.
check "dominio normal"    "www.midominio.com"  "$(default_alias midominio.com)"
check "con guiones"       "www.mi-dominio.es"  "$(default_alias mi-dominio.es)"
check "subdominio"        ""                   "$(default_alias blog.midominio.com)"
check "staging"           ""                   "$(default_alias staging.midominio.com)"
check "subdominio hondo"  ""                   "$(default_alias a.b.midominio.com)"
# El que ya es www no se duplica.
check "ya es www"         ""                   "$(default_alias www.midominio.com)"
# Los dominios de segundo nivel se compran enteros: 'midominio.co.uk' es tan
# raíz como 'midominio.com', y ahí el www sí va.
check "co.uk"             "www.midominio.co.uk"  "$(default_alias midominio.co.uk)"
check "com.ar"            "www.midominio.com.ar" "$(default_alias midominio.com.ar)"
check "com.mx"            "www.midominio.com.mx" "$(default_alias midominio.com.mx)"
# Pero un subdominio de tres etiquetas que no encaja en ese patrón, no.
check "sub de tres"       ""                   "$(default_alias blog.midominio.es)"
check "mayúsculas"        "www.midominio.com"  "$(default_alias MiDominio.COM)"

section "nginx generado"
A_NAME="nginxtest"; A_PORT="3001"

# El fallback de una SPA no puede ser el URI /index.html: si falta el fichero, nginx vuelve a
# entrar en location / y responde 500 en todo el sitio en vez de 404 en una ruta.
A_TYPE="static"; A_OUTDIR="dist"; A_SPA="yes"; A_APPDIR="."
body="$(_body_static)"
grep -q 'try_files \$uri \$uri/index.html \$uri.html \$uri/ @spa;' <<<"$body" \
  && check "spa sin bucle" "si" "si" || check "spa sin bucle" "si" "no"
grep -q 'location @spa' <<<"$body" && grep -q 'try_files /index.html =404;' <<<"$body" \
  && check "spa termina en 404" "si" "si" || check "spa termina en 404" "si" "no"

# Un estático que no es SPA no debe ganar la named location.
A_SPA="no"; body="$(_body_static)"
grep -q '@spa' <<<"$body" && check "sin spa, sin @spa" "no" "si" || check "sin spa, sin @spa" "no" "no"

# En un monorepo .next está en el paquete de la app; con el alias en la raíz todos los chunks
# dan 404 y la web carga sin estilos ni JS.
A_TYPE="next"; A_APPDIR="apps/web"
grep -q "alias $(app_current nginxtest)/apps/web/.next/static/;" <<<"$(_body_next)" \
  && check "alias _next monorepo" "si" "si" || check "alias _next monorepo" "si" "no"
A_APPDIR="."
grep -q "alias $(app_current nginxtest)/.next/static/;" <<<"$(_body_next)" \
  && check "alias _next simple" "si" "si" || check "alias _next simple" "si" "no"

report
