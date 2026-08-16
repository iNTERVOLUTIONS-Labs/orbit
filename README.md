<p align="center">
  <img src="assets/banner.svg" alt="Orbit" width="100%">
</p>

<p align="center">
  <strong>Despliega tus webs en tu propio VPS con un comando.</strong><br>
  Sin Vercel, sin Netlify, sin factura sorpresa a fin de mes.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/licencia-MIT-5EE7E7?style=flat-square" alt="MIT">
  <img src="https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420?style=flat-square" alt="Ubuntu 24.04">
  <img src="https://img.shields.io/badge/bash-5.2-4EAA25?style=flat-square" alt="Bash">
  <img src="https://img.shields.io/badge/dependencias-0-7C6CF0?style=flat-square" alt="Sin dependencias">
</p>

---

```bash
orbit new
```

Eliges un repo de tu GitHub desde una lista, escribes el dominio, y en un par de minutos la web está online con su certificado HTTPS. A partir de ahí, cada actualización es `orbit deploy mi-web`.

Orbit es un único script de Bash. No hay demonio, no hay base de datos de control, no hay panel web que mantener. Solo nginx, systemd y unos ficheros de configuración que puedes leer con `cat`.

## Qué resuelve

Tienes un VPS de 5 euros al mes con recursos de sobra y varias webs pequeñas. Cada vez que quieres publicar una, se te va la tarde entre configurar nginx a mano, acordarte de cómo iba certbot, escribir un servicio de systemd y rezar para que el build no te tumbe la versión que ya estaba funcionando.

Orbit automatiza exactamente eso, y nada más.

## Características

- **Detecta el proyecto solo**: Next.js, Astro, SvelteKit, Remix/React Router, Angular, Nuxt, Hugo, Eleventy, React (Vite y CRA), Express, Go, Deno, Bun, Laravel, PHP y Python. Lee tu `package.json` y decide cómo compilarlo y cómo servirlo. Y si tu web estática lleva un `.php` dentro —el típico formulario de contacto—, lo detecta y se lo pasa a php-fpm.
- **Despliegues atómicos**: cada versión va a su propia carpeta y solo al final se mueve un symlink. Si el build falla, la web anterior ni se entera.
- **Se despliega al hacer push**: opcional y por app. Sin webhooks, sin puertos abiertos: un temporizador pregunta si la rama ha avanzado.
- **Rollback automático**: si la app arranca pero no responde al health check, vuelve sola a la versión anterior.
- **Se recupera sola de los fallos de build que sabe arreglar**: pnpm 11 bloqueando los scripts de `esbuild`, un build sin memoria. Lo arregla, reintenta una vez y se lo apunta para la próxima.
- **HTTPS sin dolor**: Let's Encrypt por DNS-01 con Cloudflare, así que funciona con el proxy naranja activado y renueva solo.
- **Un menú y una CLI**: usa el que prefieras, hacen lo mismo. Y `--json` para cuando quien lee no es una persona.
- **Seguro por defecto**: firewall, fail2ban, apps en usuario sin privilegios, systemd endurecido, cabeceras de seguridad, ficheros sensibles bloqueados, y un dominio que no sirve ninguna app no ve la web de otra.
- **Se vigila solo**: un temporizador de systemd comprueba cada minuto que todo responde, reinicia lo que se cae y te avisa por Telegram o Discord. Sin demonios y con freno: si una app se reinicia 3 veces en 10 minutos, se rinde y te lo dice.
- **Habla tu idioma**: español e inglés, según el idioma del sistema. Sin configurar nada, y con `orbit --lang <código>` para una sola orden.
- **Todo es texto plano**: la configuración de cada app es un fichero de 16 líneas. Si Orbit desapareciera mañana, tu servidor seguiría funcionando igual.

## Instalación

En un Ubuntu 24.04 recién creado:

```bash
git clone https://github.com/intervolutions/orbit.git
cd orbit
sudo bash install.sh
```

Unos 5 a 10 minutos. Instala nginx, Node 22 con pnpm, PostgreSQL, PHP 8.3 FPM, Python, Certbot, GitHub CLI, UFW y fail2ban.

Después:

```bash
orbit github      # conecta tu cuenta de GitHub
orbit cf-token    # guarda tu token de Cloudflare
orbit new         # despliega tu primera web
```

La guía completa paso a paso está en **[docs/INSTALL.md](docs/INSTALL.md)**.

## Uso

```
orbit                      Menú interactivo
orbit new                  Añadir una web nueva
orbit deploy [app]         Actualizar (git pull + build + reinicio)
orbit deploy --all         Actualizar todas, con resumen
orbit autodeploy enable    Desplegar sola al hacer push, sin webhooks
orbit queue enable <app>   Vaciar la cola de un Laravel por temporizador
orbit clone <app> <nuevo>  Duplicar una app para montar un staging
orbit rollback [app]       Volver a una versión anterior
orbit list                 Tabla con todas las apps
orbit top                  Panel en vivo: CPU, memoria y peticiones
orbit traffic [app]        Quién visita, del log de nginx: sin cookies ni JS
orbit logs [app] [--since] Logs en vivo, o una ventana de tiempo
orbit env [app]            Editar variables de entorno
orbit env set|get|unset    Variables desde un script
orbit exec <app> [cmd]     Ejecutar algo con el entorno de la app
orbit migrate [app]        Migraciones, con el plan por delante
orbit redirect add|list|rm Redirecciones de ruta o de dominio
orbit port [app] [puerto]  Cambiar el puerto interno de la app
orbit ssl [app]            Emitir o renovar certificado
orbit db create|backup     Bases de datos PostgreSQL
orbit backup [app|--all]   Copia de configuración, .env, subidas y base de datos
orbit restore <fichero>    Devolver una copia a su sitio
orbit status               Salud del servidor
orbit doctor               Diagnóstico completo
orbit maintenance on|off   Página de "volvemos enseguida" con 503
orbit watch enable         Vigilancia cada minuto, sin demonios
orbit notify setup         Avisos por Telegram, Discord, webhook o correo
orbit lang [código]        Idioma: español o inglés (por defecto, el del sistema)
```

Orbit habla el idioma de tu sistema. Para una sola orden, `orbit --lang en <comando>`.

Referencia completa en **[docs/USAGE.md](docs/USAGE.md)**.

## Cómo funciona

```
/srv/apps/mi-web/
├── cache/       clon de git reutilizado, los deploys son incrementales
├── releases/    20260805-041230/  20260804-235018/  ...
├── shared/
│   └── .env     variables persistentes, symlinkeadas a cada release
└── current  ->  releases/20260805-041230
```

Un despliegue es: actualizar el clon, copiarlo a una release nueva, compilar, mover el symlink `current`, reiniciar el servicio y recargar nginx. Si algo falla antes de mover el symlink, no ha pasado nada.

Las apps de Node y Python corren como servicios de systemd escuchando solo en `127.0.0.1`. nginx hace de proxy. Las webs estáticas las sirve nginx directamente desde disco. PHP va por socket a php-fpm.

El detalle completo, con las decisiones de diseño y por qué se tomaron, está en **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Stacks soportados

| Detecta | Modo | Cómo se sirve |
|---|---|---|
| `next` | proceso | Node en puerto interno, `/_next/static` servido por nginx |
| `next` con `output: 'export'` | estático | Ficheros de `out/` |
| `astro` | estático | Ficheros de `dist/` |
| `astro` + `@astrojs/node` | proceso | Proxy a `dist/server/entry.mjs` |
| `nuxt` | proceso | Proxy a `.output/server/index.mjs` |
| `vite` | estático SPA | `dist/`, con fallback a `index.html` |
| `react-scripts` | estático SPA | `build/` |
| `@sveltejs/kit` + `adapter-node` | proceso | `node build`, con el puerto por variable |
| `@sveltejs/kit` + `adapter-static` | estático | Ficheros de `build/` |
| `@react-router/serve` o `@remix-run/serve` | proceso | Remix y React Router 7, con su propio `start` |
| React Router con `ssr: false` | estático SPA | `build/client` |
| `@angular/core` | estático SPA | `dist/<proyecto>/browser`, leído de `angular.json` |
| `@angular/core` + `@angular/ssr` | proceso | `dist/<proyecto>/server/server.mjs` |
| `hugo.toml` | estático | `hugo --minify` a `public/` (hugo lo instalas tú) |
| `@11ty/eleventy` | estático | Ficheros de `_site/` |
| `express` `fastify` `koa` `nest` `hono` | proceso | Proxy al puerto interno |
| `go.mod` + un paquete `main` | proceso | `go build -trimpath` y el binario por systemd (Go lo instalas tú) |
| `deno.lock` o `deno.json` con `tasks`/`imports` | proceso | `deno install --frozen`, caché en `shared/deno` (deno lo instalas tú) |
| `bun.lock` + arranque con bun | proceso | `bun install --frozen-lockfile` (bun lo instalas tú) |
| `bun.lock` con un framework | según el framework | Bun sólo como gestor de paquetes |
| `artisan` + `laravel/framework` | laravel | php-fpm con `public/` de docroot, `storage/` compartido y las cachés en su sitio |
| `composer.json` o `.php` | php | php8.3-fpm por socket |
| `manage.py` | proceso | Django: venv, `collectstatic`, `/static/` y `/media/` desde nginx |
| `fastapi` | proceso | venv propio con uvicorn |
| `flask` | proceso | venv propio con gunicorn |
| `requirements.txt` `pyproject.toml` | proceso | venv propio, con pip, Poetry o uv |

Si tu proyecto no encaja, el asistente te deja definir los comandos a mano.

## Requisitos

- Ubuntu 24.04 LTS, o Debian 12. En Debian el instalador se adapta solo (PHP 8.2 en vez de 8.3, y algún paquete que allí no viene de serie), y **está instalado de principio a fin en una máquina Debian de verdad**: los trece pasos, una app con proceso levantada por systemd, unattended-upgrades trayendo parches, y la máquina reiniciada y volviendo sola
- 1 GB de RAM mínimo, 2 GB o más recomendado si compilas Next en el servidor
- Un dominio con el DNS apuntando al servidor
- Cuenta de Cloudflare, opcional pero muy recomendada

Probado en un VPS de OVH con 12 GB de RAM y 6 vCPU sirviendo varias webs a la vez.

## Qué NO es Orbit

Conviene ser honesto sobre los límites:

- **No instala WordPress, foros ni nada que se actualice solo.** Orbit despliega **tu repositorio de git**: lo compila, lo publica de forma atómica y te deja volver atrás. Una aplicación que se modifica a sí misma es incompatible con ese modelo, porque el siguiente despliegue borraría lo que ella misma escribió. Es una decisión de diseño, no una tarea pendiente.
- **No tiene panel web, y no lo va a tener.** `orbit` corre como root y `orbit exec` ejecuta comandos arbitrarios: un panel web encima de eso no sería un panel, sería una shell de root expuesta a internet. El estado en vivo se mira con `orbit top` desde el terminal, y la interfaz con ratón será **Orbit Desktop**, un cliente que corre en tu portátil y entra por SSH sin instalar nada en el servidor. El razonamiento completo está en [ARCHITECTURE §13](docs/ARCHITECTURE.md).
- **No es Kubernetes.** Un servidor, un nginx. Si necesitas escalar horizontalmente, esta no es tu herramienta.
- **No hace despliegues sin corte para apps con estado.** Al reiniciar un proceso de Node hay un hueco de uno o dos segundos.
- **No gestiona varios servidores.** Todavía. Está en el [roadmap](ROADMAP.md).
- **No sustituye a Docker** si tu proyecto ya está contenerizado. Orbit compila en el propio host.
- **Está pensado para proyectos personales y pequeños negocios**, no para infraestructura crítica con SLA.

## Contribuir

Las contribuciones son bienvenidas. Lee [CONTRIBUTING.md](CONTRIBUTING.md) antes de mandar un PR. Lo importante:

- Bash 5 con `set -Eeuo pipefail`, sin dependencias externas más allá de lo que instala `install.sh`
- Pasa `shellcheck -S warning` antes de enviar
- Prueba en un Ubuntu 24.04 limpio, aunque sea en una VM
- Cambios en `render_nginx` deben validarse con `nginx -t`

## Licencia

MIT. Haz lo que quieras con él.

## Créditos

Hecho por **[Intervolutions](https://intervolutions.com)**.

Nació de la frustración de desplegar webs a mano una y otra vez en el mismo VPS. Si te ahorra una tarde, ya ha cumplido su propósito.
