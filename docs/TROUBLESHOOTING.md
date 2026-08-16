# Resolución de problemas

Empieza siempre por aquí:

```bash
orbit doctor
```

---

## Un dominio mío enseña la web de otra app

Dos formas de encontrártelo, y las dos son el mismo fallo:

- Un dominio que **no has configurado** apunta a tu IP y, al entrar por `https://`, sale la web de la primera app que desplegaste.
- Acabas de crear una app y su dominio, por `https://`, enseña otra web. Por `http://` va bien.

La causa es el servidor por defecto de nginx. Sin un `default_server` para el 443, una petición HTTPS con un nombre que no declara ningún vhost la atiende el primer bloque con certificado que haya, y ése es la primera app por orden alfabético. En el segundo caso el dominio nuevo **todavía no tiene certificado** —lo tendrá al pasar `orbit ssl`—, así que su vhost no tiene bloque de 443 y cae en el mismo sitio.

Compruébalo y arréglalo:

```bash
orbit doctor                 # la comprobación 'default-server' lo dice
sudo orbit nginx-rebuild     # escribe el servidor por defecto para 80 y 443
```

Después, un nombre que no sirve ninguna app **rechaza el saludo TLS** en el 443 (`curl` da `error 35`, el navegador un error de conexión segura, y detrás de Cloudflare sale un 525) y cierra la conexión en el 80. Es lo correcto: no existe ningún certificado válido para un nombre que este servidor no sirve, y presentar el de otro dominio es justo lo que estábamos arreglando.

Ojo con el diagnóstico equivocado: si la app **sí tiene** certificado y le falta el `index.html`, no verás la web de nadie más — verás un **403**. El `index.html` no tiene nada que ver; mira el certificado.

```bash
orbit list                   # la columna SSL dice si lo tiene
sudo orbit ssl mi-web        # si no, emítelo
```

## El formulario en PHP de mi web estática no funciona

Un sitio de Astro, Vite o Eleventy con un `contacto.php` dentro. La web va perfecta y el formulario da 404, o peor: **el navegador se descarga el `.php` en vez de ejecutarlo**.

Si te descargaba el fichero, mira lo que había dentro y **cambia cualquier credencial que llevara escrita**: ese código ha sido público mientras tanto. nginx no tiene `php` en `mime.types`, así que lo servía como descarga.

Comprueba si la app tiene la capacidad activada:

```bash
orbit info mi-web --json | jq -r '.app.config.php'
```

Si sale vacío, actívala y regenera el vhost:

```bash
sudo sed -i "s/^A_PHP=.*/A_PHP='yes'/" /etc/orbit/apps/mi-web.conf
sudo orbit nginx-rebuild
```

Si sale `yes` y sigue dando 404, el `.php` no está llegando a la carpeta publicada. Míralo:

```bash
find /srv/apps/mi-web/current -name '*.php'
```

Si no aparece, es que el build no lo copia. En Astro y Vite, los ficheros de `public/` se copian tal cual a `dist/`; los de `src/` los procesa el build y se quedan por el camino. Mueve el `.php` a `public/` y vuelve a desplegar.

Y si aparece pero responde 502, es php-fpm:

```bash
sudo orbit doctor          # lo dice explícitamente si alguna app usa PHP
sudo systemctl status php8.3-fpm
```

## Le he puesto un subdominio y me añade `www.`

Ya no: `orbit new` solo propone `www.` para dominios de los que se compran (`midominio.com`, `midominio.co.uk`), no para subdominios (`blog.midominio.com`).

Si tienes una app creada antes de ese cambio con un alias `www.<subdominio>` que no existe en el DNS, quítalo — es lo que puede estar rompiéndote la emisión del certificado, porque Let's Encrypt valida todos los nombres del lote o no emite ninguno:

```bash
sudo orbit domain mi-web      # deja el campo de dominios extra vacío
sudo orbit ssl mi-web         # reemite el certificado ya sin el nombre fantasma
```

## La web da 502 Bad Gateway

nginx está vivo pero la app no responde.

```bash
orbit logs mi-web
```

Causas habituales:

- **Falta una variable de entorno.** Revisa con `orbit env mi-web`.
- **El puerto no coincide.** La app debe escuchar en la variable `PORT` que le pasa systemd. Si tu código tiene el puerto escrito a fuego, cámbialo por `process.env.PORT`.
- **La app escucha en `0.0.0.0` o en una interfaz que no es localhost.** Debe escuchar en `127.0.0.1`.

---

## La app se reinicia sola sin parar (`EACCES` en `.cache/node/corepack`)

El build va bien, la release se activa, y el servicio se estrella en bucle:

```
[Error: EACCES: permission denied, opendir '/home/deploy/.cache/node/corepack/v1/pnpm'] {
  errno: -13, code: 'EACCES', syscall: 'opendir',
  path: '/home/deploy/.cache/node/corepack/v1/pnpm'
}
orbit-mi-web.service: Scheduled restart job, restart counter is at 36.
```

**Es cosa de Orbit, no de tu app, y no es un permiso de disco.** La unidad lleva `ProtectHome=true`, que tapa `/home` con un tmpfs en modo 000; el `HOME` que systemd deduce de `User=deploy` cae justo debajo. Tu repositorio fija el gestor de paquetes (`"packageManager": "pnpm@…"`), el `pnpm` del arranque es el lanzador de corepack, y su caché vive en ese `HOME` que ahora no se puede ni abrir. El build no lo notaba porque corre fuera del cajón de systemd.

Comprueba si tienes unidades de antes del arreglo:

```bash
orbit doctor      # avisa: "Unidad anterior al HOME propio, y su app puede no arrancar: mi-web"
```

Arreglo, y no hay que tocar nada a mano:

```bash
orbit deploy mi-web
```

El despliegue reescribe la unidad con su `HOME` dentro de `/srv/apps/mi-web/shared/home` y deja ahí la caché de corepack, en el mismo paso. `chmod` sobre `/home/deploy` **no** sirve: los permisos del disco no importan, lo que tapa la ruta es el montaje de systemd. Abrir el cajón con `ProtectHome=read-only` tampoco: dejaría a la app leer las claves SSH del servidor. El detalle largo está en ARCHITECTURE §5.1.

---

## La app se reinicia sola sin parar (`EADDRINUSE`)

```bash
orbit logs mi-web
```

Si ves `Error: listen EADDRINUSE: address already in use 127.0.0.1:3001` una y otra vez, hay **dos apps peleando por el mismo puerto interno**. systemd reinicia la perdedora cada 3 segundos para siempre.

```bash
orbit doctor      # avisa: "Puertos internos duplicados: 3001"
```

Arreglo, en una de las dos apps:

```bash
orbit port mi-web
```

Sin número, mira si el puerto choca y solo entonces mueve la app a uno libre. Puedes ejecutarlo tantas veces como quieras: si no hay conflicto no cambia nada.

Las versiones anteriores a la 1.1 podían repartir un puerto ya asignado cuando la app que lo tenía estaba parada. Si vienes de una de ellas, pasa `orbit doctor` una vez.

---

## Cloudflare dice "Web server is down" (error 521)

Cloudflare no consigue conectar con tu servidor.

La causa más común: **la zona está en Full (strict) pero la app todavía no tiene certificado**. En ese caso nginx solo escucha en el puerto 80 y Cloudflare intenta conectar por el 443.

```bash
orbit list                          # ¿la columna SSL dice "no"?
sudo ss -ltnp | grep -E ':80|:443'  # ¿hay algo escuchando en 443?
```

Arreglo:

```bash
orbit ssl mi-web
```

Otras causas:

- **Estás entrando por un hostname que no está en el vhost.** Desplegaste `midominio.com` y entras por `www.midominio.com`, o al revés. Compruébalo con `orbit info mi-web` y arréglalo con `orbit domain mi-web`.
- **Ejecutaste `orbit firewall lock` y el dominio está en nube gris.** Ponlo en naranja o ejecuta `orbit firewall unlock`.
- **nginx no está corriendo.** `systemctl status nginx`.

---

## ERR_TOO_MANY_REDIRECTS

El navegador entra en bucle.

Casi siempre es **Cloudflare en modo Flexible**. En ese modo Cloudflare habla con tu origen por el puerto 80, y un vhost que redirige a HTTPS provoca un ciclo infinito.

Arreglo: **SSL/TLS → Overview → Full (strict)**.

Orbit genera vhosts que detectan la cabecera `X-Forwarded-Proto` para que el bucle no ocurra ni aunque la zona esté en Flexible, pero si vienes de una versión anterior regenera la configuración:

```bash
orbit nginx-rebuild
```

Para confirmar de dónde viene el bucle, desde el servidor:

```bash
curl -sI -H 'Host: midominio.com' http://127.0.0.1/ | head -3
curl -skI --resolve midominio.com:443:127.0.0.1 https://midominio.com/ | head -3
```

- 80 devuelve 301 y 443 devuelve 200 → tu origen está bien, el bucle lo crea Cloudflare
- 443 devuelve 301 a la misma URL → el bucle está dentro de tu app: mira `next.config`, `middleware.ts` o `trailingSlash`

---

## `[ERR_PNPM_OUTDATED_LOCKFILE]`: el lockfile no cuadra con el package.json

```
[ERR_PNPM_OUTDATED_LOCKFILE] Cannot install with "frozen-lockfile" because
pnpm-lock.yaml is not up to date with <ROOT>/package.json
  * 1 dependencies were added: playwright@^1.49.0
```

Casi siempre es un **merge de PR** donde el conflicto de `pnpm-lock.yaml` se resolvió quedándose con un lado. La rama pasaba CI porque era coherente; el commit de merge, que es el que se despliega, no lo es y nadie lo probó.

**Orbit resuelve la mitad segura y sólo esa.** Si lo único que ha derivado son dependencias **añadidas** y **todas están en `devDependencies`**, las resuelve, reintenta una vez y sigue: no llegan al runtime, y lo que ya estaba fijado en el lockfile no se mueve. Si estás leyendo esto es porque no ha entrado en ese caso. Orbit te dice cuál de estos es:

**El paquete está en `dependencies`.** Eso sí se publica. Resolverlo aquí pondría en producción una versión que no ha decidido nadie, y el lockfile existe justamente para que eso no pase.

**Le han cambiado la versión pedida a algo** (`- ms (lockfile: ^2.1.3, manifest: ^2.0.0)`). Ese paquete sí se reresuelve, así que la respuesta es la misma.

**Falta `jq`.** Sin él no se puede saber en qué sección del `package.json` está cada paquete, y suponerlo sería el error que todo esto evita:

```bash
sudo apt-get install -y jq
```

**Usas npm o yarn.** npm lista los paquetes que faltan del árbol entero, transitivas incluidas y ya resueltas (`Missing: is-number@3.0.0`), y yarn no nombra ninguno. Sin saber cuál es la dependencia directa no se puede decidir si llega a producción.

El arreglo definitivo es siempre el mismo, y es un commit tuyo **en tu máquina**:

```bash
# en tu equipo, en el repositorio
git pull
pnpm install
git add pnpm-lock.yaml
git commit -m 'actualiza pnpm-lock.yaml'
git push

# y ya en el servidor
orbit deploy mi-web
```

`git add pnpm-lock.yaml` y no `git commit -am`: lo segundo se llevaría por delante cualquier otro fichero que tuvieras tocado.

### Por qué arreglarlo *en el servidor* no funciona

Es el error que comete todo el mundo la primera vez, y no da ninguna pista de por qué no ha servido. Ninguno de los tres sitios donde da la tentación de entrar sirve:

| Dónde | Qué pasa |
|---|---|
| `/srv/apps/<app>` | No hay ningún `package.json`: sólo `cache/`, `releases/`, `shared/` y el enlace `current` |
| `/srv/apps/<app>/releases/<fecha>` | Se copia con `rsync --exclude '.git'`, así que **no es un repositorio**: `git commit` no tiene dónde escribir. Y si el build falló, esa release ya no existe |
| `/srv/apps/<app>/cache` | Sí tiene `.git`, pero cada despliegue empieza con `git reset --hard origin/<rama>` y `git clean -fd`: **cualquier cosa que arregles ahí la borra el despliegue siguiente** |

Eso es a propósito, y es el principio 1: Orbit despliega tu repositorio, no una versión del repositorio que alguien ha tocado en el servidor. Si el arreglo viviera sólo en el servidor, el despliegue siguiente lo perdería y nadie sabría por qué.

Ojo: cuando Orbit sí lo resuelve, **no se lo apunta**. La deriva es del commit, no de la app, y recordarla dejaría la app instalando sin lockfile congelado para siempre. El despliegue siguiente, con el lockfile ya arreglado, va solo. El razonamiento completo está en ARCHITECTURE §14.6.

## `[ERR_PNPM_IGNORED_BUILDS]` durante el build

```
[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: esbuild@0.28.1
Run "pnpm approve-builds" to pick which dependencies should be allowed to run scripts.
```

Desde **pnpm 11**, una dependencia con scripts de instalación sin aprobar hace **fallar** el install en vez de avisar. Sin esos scripts, paquetes como `esbuild`, `sharp` o `@parcel/watcher` se quedan sin su binario nativo.

**Orbit lo arregla solo**: detecta el fallo, escribe el `allowBuilds` en la release, reintenta una vez y se acuerda para el próximo despliegue. Si estás leyendo esto es porque quieres saber qué pasó, o porque no se ha arreglado. Las tres razones por las que no se arregla:

**1. Lo tienes denegado a propósito.** Si tu `pnpm-workspace.yaml` dice `esbuild: false`, Orbit lo respeta y no reintenta. Es una decisión tuya, no un descuido. Cámbialo a `true` en el repositorio si lo necesitas.

**2. La recuperación está desactivada.** Mira `BUILD_RECOVERY` en `/etc/orbit/orbit.conf`.

**3. El `pnpm-workspace.yaml` no está en la raíz del repositorio.** Orbit lo escribe en la raíz de la release, que es donde corre el install. Si tu proyecto vive en un subdirectorio y el install se lanza desde ahí, pnpm buscará el fichero en otro sitio.

**El arreglo definitivo**, que hace que Orbit no tenga que intervenir, es una línea en tu repositorio:

```yaml
# pnpm-workspace.yaml, en la raíz
allowBuilds:
  'esbuild': true
```

Añade ahí todos los que te salgan en el error. Con eso, el despliegue pasa a la primera y sin reintentos.

Para ver qué ha aprendido Orbit por su cuenta:

```bash
orbit info mi-web --json | jq -r '.app.config.pnpm_allow'
```

Y para que lo olvide (por ejemplo, después de arreglarlo en el repositorio), borra el valor de `A_PNPM_ALLOW` en `/etc/orbit/apps/mi-web.conf`.

## El build falla con "Module not found" o errores de PostCSS

Si ves cosas como `Can't resolve '@/components/Algo'` junto a un error de plugin de PostCSS, casi seguro que **no se instalaron las devDependencies**.

En un proyecto Next, `tailwindcss`, `postcss` y `typescript` viven ahí. Sin TypeScript instalado, webpack ni siquiera busca ficheros `.tsx`, de ahí los errores de módulo no encontrado.

Orbit hace `unset NODE_ENV` antes de compilar precisamente por esto. Si vienes de una versión antigua, comprueba tu configuración:

```bash
grep A_BUILD /etc/orbit/apps/mi-web.conf
```

Debe llevar `--include=dev` en npm o `--prod=false` en pnpm.

Para probar el build a mano sin lanzar un despliegue:

```bash
sudo -u deploy bash -lc 'cd /srv/apps/mi-web/cache && unset NODE_ENV && pnpm install && pnpm run build'
```

---

## Una migración funciona a mano y falla desde la app (o al revés)

Casi siempre es que el entorno no es el mismo. Compáralos:

```bash
orbit exec mi-web sh -c 'echo "$DATABASE_URL"'    # lo que ve la app de verdad
```

`orbit exec` monta el mismo entorno que la unidad de systemd: la release activa como directorio, el `.env` de `shared/`, `PORT`, `HOST` y `NODE_ENV=production`. Si lo que sale ahí no es lo que esperabas, el problema está en el `.env`, no en tu código.

Dos causas concretas:

- **Estabas ejecutando desde `cache/` en vez de desde `current/`.** El clon de git no tiene el `.env` enlazado ni los artefactos del build.
- **Tu `.env` define `NODE_ENV=development`.** No sirve de nada: la unidad de systemd declara `EnvironmentFile` **antes** que `Environment=NODE_ENV=production`, así que gana la unidad. `orbit exec` se comporta igual, a propósito. Si necesitas otro valor, cámbialo en la unidad, no en el `.env`.

---

## `orbit exec` me dice "no tiene ninguna release activa"

La app está registrada pero nunca se ha desplegado, o el symlink `current` no existe.

```bash
orbit deploy mi-web
```

---

## La web dice "volvemos enseguida" y no debería

Alguien —o un despliegue que murió a mitad— dejó puesto el mantenimiento:

```bash
orbit maintenance status
orbit maintenance off mi-web
```

O directamente, que es lo mismo:

```bash
rm /srv/apps/mi-web/shared/maintenance.on
```

No hace falta recargar nginx: el fichero se comprueba en cada petición.

`orbit watch` avisa cuando una app lleva más de 30 minutos así, precisamente porque el olvido es el fallo probable. El umbral está en `WATCH_MAINT_MAX`.

---

## Pongo el mantenimiento y la web sigue sirviendo

El vhost de esa app es anterior a la versión que trae el mantenimiento y no lleva la guarda. `orbit maintenance on` te avisa de esto; para aplicarlo:

```bash
orbit nginx-rebuild
grep maintenance /etc/nginx/sites-available/orbit-mi-web.conf
```

---

## El autodespliegue ha dejado de desplegar y no dice nada

Comprueba primero si Orbit puede siquiera preguntarle al remoto:

```bash
orbit autodeploy status
```

```
  ○ mi-web            main (no consigo hablar con el remoto)
```

El error completo de git sale pidiendo el despliegue a mano:

```bash
orbit deploy mi-web
```

Las tres causas habituales, que se arreglan de forma distinta:

- **`could not read Username` o `Authentication failed`** — el token de GitHub ha caducado o se ha revocado. `orbit github` para volver a conectar.
- **`Repository not found`** — el repositorio se ha renombrado, se ha hecho privado o se ha borrado. Corrige `A_REPO` en `/etc/orbit/apps/mi-web.conf`.
- **`Could not resolve host`** — problema de red o de DNS en el servidor, casi siempre temporal.

Si el mensaje es que **la rama ya no existe**, el repositorio contesta bien pero `A_BRANCH` apunta a algo que se ha borrado o renombrado (el caso clásico es `master` → `main`). Cámbialo en el fichero de la app y despliega.

Mientras dure, la web sigue sirviendo la versión anterior con normalidad: por eso no se nota mirándola.

---

## He clonado una app y el staging no arranca

Es lo esperado la primera vez: la copia **no hereda los valores del `.env`**, solo los nombres. Un `DATABASE_URL` heredado habría hecho que el staging escribiera en la base de datos de producción.

```bash
orbit env staging            # rellena los valores
orbit db create staging      # si necesita su propia base de datos
orbit deploy staging
orbit maintenance off staging
```

Mientras tanto el dominio responde 503 con la página de aviso, no un 502: la copia nace en mantenimiento a propósito, porque todavía no tiene código desplegado.

Si el staging arranca pero **escribe donde no debe**, mira las rutas absolutas:

```bash
grep -E 'ROOT=' /etc/orbit/apps/staging.conf
```

Orbit reapunta a la copia las que están dentro de la carpeta de la app original. Una que apunte a otro sitio (`/mnt/almacen/...`) se copia tal cual —Orbit avisa al clonar— y las dos apps escribirán ahí. Cámbiala a mano y regenera el vhost:

```bash
orbit nginx-rebuild
```

---

## Un comando no encuentra mi app y me habla de subcomandos

```
✖ orbit maintenance: no sé qué es «mi-web».
✖ Se esperaba un subcomando (on off edit status) o el nombre de una app existente.
```

El nombre no coincide con ninguna app. Míralo con `orbit list`: el nombre es el de la columna `APP`, no el dominio.

El caso contrario también existe. Si tu app se llama igual que un subcomando —`status`, `set`, `list`, `on`— el atajo no la alcanza, porque **el subcomando gana siempre**:

```bash
orbit maintenance status      # el estado del servidor, no la app 'status'
```

Escribe el subcomando entero y se resuelve:

```bash
orbit maintenance status status   # ahora sí, la app 'status'
orbit env edit set                # la app 'set'
```

Cuando el choque ocurre, Orbit escribe la forma larga por `stderr`. Va por `stderr` a propósito, para que `VALOR=$(orbit env get mi-app CLAVE)` siga recibiendo solo el valor. El porqué está en ARCHITECTURE §8.3.

---

## He cambiado una variable y la app no se entera

Las variables se leen al arrancar el proceso. Cambiar el `.env` no reinicia nada por defecto:

```bash
orbit restart mi-web
```

Comprueba qué ve la app de verdad, que no siempre es lo que crees:

```bash
orbit exec mi-web sh -c 'echo "$API_KEY"'
```

Si ahí sale algo distinto de lo que pusiste:

- **El valor llevaba un `$` y estaba escrito con comillas dobles.** `PASSWORD="p$assw0rd"` hace que bash expanda `$assw0rd` al cargar el fichero y la app reciba `p`. Reescríbelo con `orbit env set mi-web PASSWORD 'p$assw0rd'`, que usa comillas simples.
- **La unidad de systemd la define después.** `NODE_ENV`, `PORT` y `HOST` los fija la unidad, y esa gana sobre el `.env`. Está explicado en ARCHITECTURE §5.

---

## Hago push y no se despliega

```bash
orbit autodeploy status
```

Causas, en orden de frecuencia:

- **Esa app no está en automático.** Es un permiso por app: `orbit autodeploy enable mi-web`. Activarlo en una no lo activa en las demás, a propósito.
- **El commit anterior rompió el build.** Verás `(commit a1b2c3d falló; espero uno nuevo)`. Orbit no reintenta el mismo commit; sube el arreglo o lanza `orbit deploy mi-web` a mano para ver el error completo.
- **El temporizador está parado.** `systemctl list-timers orbit-autodeploy.timer`. Si no aparece, vuelve a ejecutar `orbit autodeploy enable <app>`.
- **Has empujado a otra rama.** Orbit sigue la de `orbit info mi-web`, no siempre `main`.
- **El repositorio es privado y `deploy` no tiene acceso.** Compruébalo tal y como lo hace Orbit:

```bash
sudo -u deploy git ls-remote https://github.com/tu/repo.git refs/heads/main
```

Si eso no responde un SHA, ejecuta `orbit github`.

Para ver qué está pasando en cada pasada:

```bash
journalctl -u orbit-autodeploy.service -n 30
```

---

## El vigilante no avisa de nada

Comprueba en este orden:

```bash
orbit watch status          # ¿está activo el temporizador?
orbit notify status         # ¿hay algún canal configurado?
orbit notify test           # ¿llega de verdad?
orbit watch --history       # ¿ha detectado algo?
```

Causas habituales:

- **No hay canal configurado.** `orbit watch enable` te avisa de esto, pero es fácil pasarlo por alto: sin canal, Orbit reinicia lo que se cae y no te enteras.
- **`NOTIFY_MIN_LEVEL` está en `crit`.** Las caídas de app son `warn`; solo el «me rindo» y los certificados son `crit`. Bájalo a `warn`.
- **El historial está vacío y eso es correcto.** Solo se anotan los cambios de estado. Un servidor sano no escribe nada.
- **El temporizador no arrancó.** `systemctl list-timers orbit-watch.timer`. Si no aparece, `orbit watch enable` otra vez y mira `journalctl -u orbit-watch.service -n 20`.

---

## Una app aparece como "caída, me he rendido"

Orbit la reinició 3 veces en 10 minutos y dejó de intentarlo a propósito. Reiniciar en bucle una app que no arranca consume el servidor y esconde el problema.

```bash
orbit logs mi-web           # la causa está aquí
orbit watch --history       # cuándo empezó
```

Cuando lo arregles, el siguiente `orbit watch` la verá responder, la marcará como correcta y te avisará de la vuelta. Para no esperar al minuto:

```bash
orbit restart mi-web && orbit watch
```

Si quieres darle más margen antes de rendirse, en `/etc/orbit/orbit.conf`:

```bash
WATCH_MAX_TRIES="5"
WATCH_WINDOW="900"
```

---

## Una redirección no se aplica

Comprueba primero que la regla existe y qué genera:

```bash
orbit redirect list mi-web
grep -n 'location' /etc/nginx/sites-available/orbit-mi-web.conf | head
curl -sI -H 'Host: mi-web.com' http://127.0.0.1/precios | head -3
```

Causas habituales:

- **Tu shell se comió el comodín.** `orbit redirect add mi-web /blog/* /noticias/*` sin comillas hace que bash expanda `*` con los ficheros del directorio actual. Usa **comillas simples** siempre que el patrón lleve `*`, `$` o `\`.
- **Otra regla más general va antes.** Entre expresiones regulares gana la primera que coincide. Orbit las ordena de patrón más largo a más corto, pero si dos tienen la misma longitud el orden no está garantizado: hazlas más específicas.
- **El navegador cacheó un 301.** Un 301 se guarda **para siempre**. Prueba en una ventana privada o con `curl`, que no cachea. Si te equivocaste con un 301 en producción, quien ya lo visitó seguirá redirigido aunque quites la regla; es el motivo de empezar con `--302` cuando hay dudas.
- **La app estaba sirviendo ya esa ruta.** Una redirección exacta gana siempre, pero una de comodín compite con las demás reglas del vhost.

---

## Después de redirigir, el navegador baja de https a http

Ya no debería pasar: los vhosts llevan `absolute_redirect off`. Si vienes de una versión anterior:

```bash
orbit nginx-rebuild
grep absolute_redirect /etc/nginx/sites-available/orbit-mi-web.conf
```

El motivo está explicado en ARCHITECTURE §6: nginx construye la URL absoluta con el esquema de la conexión con el origen, que detrás de Cloudflare es el puerto 80 aunque el visitante venga por HTTPS.

---

## Django: la web sale sin CSS

Con `DEBUG=False`, **Django no sirve ficheros estáticos en absoluto**. No es que sea lento: no los sirve. Los tiene que servir nginx.

```bash
orbit deploy mi-web
```

Al terminar te dice qué ha configurado:

```
  ✔ nginx servirá /static/ desde staticfiles
```

Si en vez de eso ves un aviso de que falta `STATIC_ROOT`, añádelo a `settings.py`:

```python
STATIC_ROOT = BASE_DIR / 'staticfiles'
```

Comprueba lo que ha quedado guardado y lo que sirve nginx:

```bash
grep STATIC /etc/orbit/apps/mi-web.conf
grep -A3 'location /static/' /etc/nginx/sites-available/orbit-mi-web.conf
curl -I -H 'Host: mi-web.com' -H 'X-Forwarded-Proto: https' http://127.0.0.1/static/admin/css/base.css
```

---

## Django: 400 Bad Request en todo

El dominio no está en `ALLOWED_HOSTS`. Orbit avisa de esto al desplegar:

```
  ! mi-web.com no está en ALLOWED_HOSTS: Django responderá 400 Bad Request.
```

Lo más cómodo es leerlo del entorno para no tocar el código al cambiar de dominio:

```python
ALLOWED_HOSTS = [h for h in os.environ.get('DJANGO_ALLOWED_HOSTS', '').split(',') if h]
CSRF_TRUSTED_ORIGINS = ['https://' + h for h in ALLOWED_HOSTS]
```

Y en `orbit env mi-web`:

```
DJANGO_ALLOWED_HOSTS=mi-web.com,www.mi-web.com
```

`CSRF_TRUSTED_ORIGINS` importa aparte: sin él los formularios del admin fallan con «CSRF verification failed» aunque `ALLOWED_HOSTS` esté bien, porque Django está detrás de un proxy que termina el TLS.

---

## Django: "attempt to write a readonly database"

La base de datos SQLite, o el directorio que la contiene, no pertenece al usuario `deploy`. Pasa típicamente cuando alguien ejecutó `python manage.py migrate` como root una vez.

```bash
ls -l /srv/apps/mi-web/shared/
sudo chown -R deploy:deploy /srv/apps/mi-web/shared/
```

SQLite necesita permiso de escritura **también sobre el directorio**, no solo sobre el fichero, porque crea ficheros auxiliares (`-wal`, `-journal`) al lado.

---

## Han desaparecido las imágenes que subieron los usuarios

`MEDIA_ROOT` apuntaba dentro de la release. Cada despliegue crea una carpeta nueva, así que las subidas se quedaron en la anterior y la poda se las llevó al cabo de cinco despliegues.

Orbit avisa de esto en cada despliegue:

```
  ! MEDIA_ROOT está dentro de la release: lo que suban tus usuarios
  ! desaparecerá en el próximo despliegue.
```

Arreglo, en `settings.py`:

```python
MEDIA_ROOT = '/srv/apps/mi-web/shared/media'
```

Si aún conservas una release antigua, lo que se subió está ahí:

```bash
ls /srv/apps/mi-web/releases/*/media/
```

---

## El build de Python falla con "No such file or directory: requirements.txt"

Vienes de una versión de Orbit anterior a la 1.1, que generaba el build asumiendo que siempre había un `requirements.txt` aunque el proyecto usara `pyproject.toml`. Regenera la detección creando la app de nuevo, o corrige el comando a mano:

```bash
grep A_BUILD /etc/orbit/apps/mi-web.conf
```

Debe usar `uv sync`, `poetry install` o `pip install .` según lo que tenga tu repositorio.

---

## El build se queda sin memoria

```
FATAL ERROR: Ineffective mark-compacts near heap limit
Allocation failed - JavaScript heap out of memory
```

**Orbit lo intenta solo**: al ver ese error reintenta dándole a Node hasta un 75 % de la memoria **libre** (con un tope de 4 GB), y se lo apunta en `A_NODE_HEAP` para el próximo despliegue.

Si te sale este mensaje en su lugar:

```
✖ El build se ha quedado sin memoria y no queda suficiente libre para darle más.
```

es que no había memoria que darle. Ampliar el heap en esa situación no salva el build: cambia el error por una muerte a manos del OOM killer, que además se lleva por delante lo que estuviera sirviendo. Tienes tres salidas:

**Añade swap.** El instalador crea 4 GB; para un Next grande puede quedarse corto:

```bash
sudo fallocate -l 4G /swapfile2 && sudo chmod 600 /swapfile2
sudo mkswap /swapfile2 && sudo swapon /swapfile2
echo '/swapfile2 none swap sw 0 0' | sudo tee -a /etc/fstab
```

**Para algo mientras compilas.** `orbit stop otra-app`, despliega, y vuelve a arrancarla.

**Fíjalo tú a mano** si sabes cuánto necesita, con `orbit env mi-web` y añadiendo `NODE_OPTIONS=--max-old-space-size=4096`. El que pongas tú manda sobre el que calcule Orbit.

Si aun con el heap ampliado sigue fallando, el proyecto necesita más de lo que este servidor puede darle: toca compilar fuera y subir el artefacto, que está en el roadmap como builds remotos.

---

## Faltan ficheros que sí están en mi máquina

Al servidor solo llega lo que git manda. Comprueba qué hay de verdad en el clon:

```bash
sudo -u deploy git -C /srv/apps/mi-web/cache ls-files | grep -i loquebuscas
```

Dos causas típicas:

- **Nunca hiciste `git add`**, o un `.gitignore` los está tapando.
- **Mayúsculas.** macOS y Windows no distinguen mayúsculas, Linux sí. Si el fichero es `section.tsx` y lo importas como `Section`, en tu portátil compila y en el servidor no. Para renombrar en git hace falta hacerlo en dos pasos:

```bash
git mv components/section.tsx components/Section.tmp
git mv components/Section.tmp components/Section.tsx
```

---

## El certificado no se emite

```bash
orbit doctor
```

Causas frecuentes:

- El registro A todavía no ha propagado. Espera unos minutos.
- El token de Cloudflare no tiene permiso sobre esa zona. Vuelve a crearlo con **All zones**.
- Has pedido más de 5 certificados para el mismo dominio en una semana. Let's Encrypt te limita. Hay que esperar.

Ver los certificados que existen:

```bash
sudo certbot certificates
```

---

## "Orbit no está instalado" cuando sí lo está

Estás ejecutándolo sin privilegios y la configuración es de root. Desde la versión 1.0 Orbit se auto-eleva con sudo. Si tienes una copia vieja:

```bash
sudo orbit doctor
```

Y actualiza el ejecutable:

```bash
sudo install -m 0755 orbit /usr/local/bin/orbit
```

---

## nginx no arranca después de tocar algo

```bash
sudo nginx -t
```

Te dice el fichero y la línea exacta. Errores clásicos:

- **Directiva duplicada.** El `nginx.conf` de Ubuntu ya define `gzip`, `access_log` y `types_hash_max_size`. No las repitas en `conf.d`.
- **`http2 on;` en nginx 1.24.** Esa directiva no existe hasta la 1.25.1. En Ubuntu 24.04 hay que usar `listen 443 ssl http2;`.
- **`listen [::]:80` en un servidor sin IPv6.** nginx falla al crear el socket.

Para volver a un estado conocido:

```bash
orbit nginx-rebuild
```

---

## Se llena el disco

```bash
orbit status          # cuánto queda
ncdu /                # explorar qué ocupa
pnpm store prune      # limpiar la caché de paquetes
```

Las releases antiguas se podan solas: se conservan las 5 últimas por app.

Las copias de bases de datos se borran a los 14 días. Si necesitas espacio ya:

```bash
find /var/backups/orbit -name '*.sql.gz' -mtime +3 -delete
```

---

## `orbit top` no enseña la CPU ni la memoria de una app

Si la columna CPU pone `·` **solo la primera vez** y luego se llena, es lo normal: el porcentaje se calcula restando dos lecturas, y hasta la segunda no hay nada que restar.

Si se queda en `·` siempre y la app está activa, systemd no está llevando la cuenta de esa unidad:

```bash
systemctl show orbit-mi-web -p CPUAccounting -p CPUUsageNSec -p MemoryCurrent
```

Si `CPUUsageNSec` sale vacío o como `[not set]`, actívalo:

```bash
sudo systemctl set-property orbit-mi-web CPUAccounting=yes MemoryAccounting=yes
```

En Ubuntu 24.04 viene activado por defecto, así que esto solo pasa en servidores con `DefaultCPUAccounting=no` en `/etc/systemd/system.conf` o en contenedores sin cgroup v2 completo.

Que una web **estática** no dé ni CPU ni memoria no es un fallo: no hay ningún proceso suyo corriendo, la sirve nginx directamente desde el disco. Por eso su estado sale como `—` y no como «parada».

## `orbit top` no cuenta las peticiones (`REQ/min` con `·`)

Tu log de acceso no lleva marca de tiempo, así que no se puede saber cuáles son del último minuto. Es lo mismo que le pasa a `orbit logs --since`, y se arregla igual:

```bash
sudo orbit nginx-rebuild
```

Las peticiones aparecerán a partir de las líneas nuevas. Las viejas se quedan sin contar porque no hay forma de datarlas.

Si el número sale con un `+` detrás (`5000+`), no es un error: se leen las últimas 5000 líneas del log y ese minuto las ha llenado, así que el número real es **mayor**. Sube el tope en `/etc/orbit/orbit.conf`:

```bash
TOP_LOG_LINES="20000"
```

## `--json` me dice que ese comando no tiene salida JSON

Es a propósito. `--json` está en `list`, `info`, `status`, `doctor`, `top` y `env list`; en el resto aborta en vez de ignorar la bandera, porque ignorarla en silencio te dejaría analizando una tabla de texto creyendo que es JSON.

Dos casos que despistan:

- **`orbit env get` no lo acepta.** Ya imprime el valor pelado, que es lo que necesita un script: `CLAVE=$(orbit env get mi-web CLAVE)`.
- **`orbit exec` nunca mira la bandera**, ni siquiera para quejarse. Ahí un `--json` es un argumento del comando que estás ejecutando dentro de la app, no de Orbit: `orbit exec mi-web node script.js --json` funciona como esperas.

---

## He restaurado una copia y la app no arranca

Mira primero si le falta el código. Una copia de Orbit **no lo lleva** —está en tu repositorio— así que después de restaurar hay que desplegar:

```bash
orbit deploy mi-web
```

Si ya has desplegado y sigue sin ir, casi siempre es la base de datos. Comprueba que la app puede entrar con lo que dice su `.env`:

```bash
orbit exec mi-web env | grep DATABASE_URL
sudo -u postgres psql -c '\du'          # ¿existe el rol?
sudo -u postgres psql -c '\l'           # ¿existe la base?
```

Si el rol no existe, es que la restauración no pudo sacar la contraseña del `.env` —te lo dijo en su momento— y hay que crearlo a mano y cargar el volcado:

```bash
orbit db create mi-web                  # crea rol, base y reescribe DATABASE_URL
tar xzf mi-web-2026….tar.gz -O ./database.sql.gz | gunzip | sudo -u postgres psql mi_web
```

Ojo con el orden: `orbit db create` **reescribe** `DATABASE_URL` en el `.env` con una contraseña nueva, así que hazlo antes de arrancar la app y no después.

## `orbit backup` dice que el hook ha fallado

```
✖ El BACKUP_HOOK ha fallado: la copia sólo está en este servidor.
```

La copia está hecha y guardada en `/var/backups/orbit`; lo que no ha funcionado es sacarla fuera. Pruébalo a mano con el mismo comando que tienes en `orbit.conf`:

```bash
grep BACKUP_HOOK /etc/orbit/orbit.conf
bash -c 'rclone copy -- "$1"' _ /var/backups/orbit/mi-web-2026….tar.gz
```

Dos cosas fallan casi siempre:

**1. El hook corre como root.** La configuración de `rclone` o las claves SSH que use tienen que ser las de root, no las de tu usuario.

**2. Las comillas en `orbit.conf`.** El fichero se carga con `source`, así que esto está mal:

```bash
BACKUP_HOOK="subir.sh $ORBIT_BACKUP_FILE"    # ✗ se expande al cargar, a nada
BACKUP_HOOK='subir.sh $ORBIT_BACKUP_FILE'    # ✓ el texto llega intacto
```

Con un comando suelto no hace falta nombrar el fichero: llega como último argumento.

```bash
BACKUP_HOOK='rclone copy --'                 # ✓ recibe la ruta al final
```

---

## Sigo atascado

Abre un issue con:

- La salida de `orbit doctor`
- La salida **completa** del comando que falla, no solo la última línea. La causa real suele estar arriba del todo.
- Tipo de app y versión de Ubuntu
