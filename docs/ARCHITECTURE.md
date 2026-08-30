# Arquitectura de Orbit

Este documento explica cómo está construido Orbit, qué decisiones se tomaron y por qué. Si vas a contribuir, empieza aquí.

---

## 1. Principios de diseño

Seis reglas guiaron todas las decisiones. La primera manda sobre las demás.

**1. Orbit despliega repositorios de git, y nada más.** Coges un repo, se compila, se sirve y se mantiene actualizado. Eso es todo lo que hace y todo lo que va a hacer.

La tentación que vuelve en cada revisión es añadir aplicaciones que se instalan y se actualizan solas: WordPress, foros, paneles. Encajan mal por una razón concreta, no por gusto: **el modelo de releases inmutables con symlink es incompatible con una aplicación que se modifica a sí misma.** WordPress se actualiza desde su propio panel, instala plugins y escribe dentro de su directorio; el siguiente despliegue tiraría todo eso. Soportarlo exigiría una segunda clase de aplicación —docroot estable, sin build, con su propia copia de seguridad y su propio endurecimiento— es decir, un segundo producto dentro del primero, con el doble de superficie que mantener y el doble de formas de romperse.

Hay además un motivo más simple: para eso ya existen herramientas mejores. Orbit no compite con un panel de hosting. Hace bien una cosa que los paneles hacen mal, que es publicar tu código desde git de forma atómica y reversible.

Si una propuesta obliga a relajar el modelo de releases, la respuesta es no.

**2. Un fichero, sin demonios.** Orbit es un script de Bash. No corre en segundo plano, no tiene base de datos de control, no expone un puerto. Se ejecuta, hace su trabajo y termina. Esto significa que no puede fallar mientras no lo estás usando.

**3. Si Orbit desaparece, el servidor sigue funcionando.** Todo lo que genera son artefactos estándar: vhosts de nginx, unidades de systemd, certificados de certbot. Puedes borrar `/usr/local/bin/orbit` y tus webs seguirán online. Esto es deliberado y no negociable: nadie debería quedar atrapado en una herramienta mantenida por una persona.

**4. Fallar antes de tocar producción.** Cada operación destructiva ocurre lo más tarde posible. El build se hace en una carpeta nueva. El symlink se mueve al final. nginx se valida antes de recargarse. Si algo revienta a mitad, la versión anterior sigue sirviendo.

**5. Todo legible con `cat`.** La configuración de una app son unas líneas de `clave='valor'`. Los logs van a journald y a `/var/log/nginx`. No hay formato binario, no hay estado oculto.

**6. Seguro por defecto, sin preguntar.** El firewall se activa, fail2ban se configura, las apps corren sin privilegios y systemd las encierra. No hay un modo inseguro que sea más cómodo.

---

## 2. Vista general

```
                      Internet
                         │
                    ┌────▼────┐
                    │Cloudflare│  proxy, cache, WAF, TLS de borde
                    └────┬────┘
                         │  HTTPS (Full strict)
              ┌──────────▼──────────┐
              │  UFW  22 / 80 / 443 │
              └──────────┬──────────┘
                         │
                    ┌────▼────┐
                    │  nginx  │  TLS de origen, vhost por dominio
                    └────┬────┘
          ┌──────────────┼──────────────┬──────────────┐
          │              │              │              │
   ficheros de     127.0.0.1:3001   unix socket    127.0.0.1:3002
      disco         (systemd)        php-fpm         (systemd)
          │              │              │              │
     Astro/Vite       Next.js          PHP          Python
      estático                                     gunicorn
                         │                              │
                         └──────────┬───────────────────┘
                                    │
                            ┌───────▼───────┐
                            │  PostgreSQL   │  solo localhost
                            └───────────────┘
```

Orbit no está en el camino de una petición. Solo configura las piezas y se aparta.

---

## 3. Por qué nginx

Se evaluaron tres candidatos.

**OpenLiteSpeed** es rápido, pero su configuración vive en XML pensado para editarse desde una interfaz gráfica. Generarlo desde un script es frágil, y donde destaca —caché de páginas para aplicaciones PHP monolíticas— no es el caso de uso de Orbit, que es sobre todo proxy inverso a procesos de Node.

**Apache** funciona perfectamente, pero consume más memoria por conexión, `mod_php` es un modelo heredado, y para proxy inverso nginx sigue siendo mejor.

**nginx** ganó porque:

- Es el mejor proxy inverso del mercado, y el 80 % de los casos de uso de Orbit son eso
- Consume poco en reposo, importa cuando el VPS tiene 1 o 2 GB
- Su configuración es texto plano trivial de generar por plantilla
- Sirve ficheros estáticos más rápido que cualquier runtime de Node
- Documentación y comunidad enormes: cuando algo falla, la respuesta ya está escrita

**Caddy** se consideró por su TLS automático, pero Cloudflare ya resuelve la parte difícil de los certificados y el ecosistema de nginx es más maduro.

### Detalles de la configuración generada

Ubuntu 24.04 trae nginx 1.24. Esto importa más de lo que parece:

- La directiva `http2 on;` no existe hasta la 1.25.1. Orbit detecta la versión y emite `listen 443 ssl http2;` o `listen 443 ssl;` más `http2 on;` según corresponda.
- El `nginx.conf` de Ubuntu ya declara `gzip on;`, `access_log` y `types_hash_max_size`. Redeclararlas en `conf.d` hace que **nginx no arranque**. El instalador las evita y ajusta `ssl_protocols` directamente en `nginx.conf`.

Además:

- **IPv6 condicional.** `listen [::]:80` mata nginx en un VPS sin IPv6. Orbit comprueba `/proc/net/if_inet6` antes de emitirlo.
- **Servidor por defecto que devuelve 444.** Cualquier petición con un `Host` que no reconocemos se cierra sin respuesta. Los escáneres automáticos que van por IP no obtienen nada.
- **Zonas compartidas a nivel http.** `ssl_session_cache`, `limit_req_zone` y `limit_conn_zone` se declaran una vez en `conf.d`, no por vhost.

---

## 4. Modelo de despliegue

Inspirado en Capistrano, adaptado a un solo servidor.

```
/srv/apps/<app>/
├── cache/                    clon de git persistente
├── releases/
│   ├── 20260805-041230/      release activa
│   ├── 20260804-235018/
│   └── ...                   se conservan las 5 últimas
├── shared/
│   ├── .env                  sobrevive a los despliegues
│   └── storage/              opcional, para uploads
└── current -> releases/20260805-041230
```

### Secuencia de un despliegue

| # | Paso | Si falla |
|---|---|---|
| 1 | `git fetch` sobre `cache/` (o `clone` la primera vez) | Aborta. No se ha tocado nada. |
| 2 | `rsync` de `cache/` a una release nueva con marca de tiempo | Aborta. |
| 3 | Symlink de `shared/.env` dentro de la release | Aborta. |
| 4 | Ejecutar el comando de build como usuario `deploy` | Borra la release, aborta. **Producción intacta.** |
| 4b | Django: preguntar a los ajustes dónde han quedado los estáticos | Avisa y sigue sin servirlos desde nginx. |
| 5 | Mover el symlink `current` (operación atómica) | — |
| 6 | Poner la página de mantenimiento, regenerar la unidad y reiniciar | El testigo se retira con un `trap`. |
| 7 | Health check: `curl` a `127.0.0.1:PORT` durante 40 s | **Rollback automático** al symlink anterior. |
| 8 | Regenerar el vhost y `nginx -t` antes de recargar | Aborta con la config anterior intacta. |
| 9 | Podar releases antiguas, guardar el commit desplegado | — |
| 10 | Django: comprobar migraciones pendientes y **avisar sin aplicarlas** | Solo avisa. |

El punto crítico es el paso 4. Un build puede tardar dos minutos y consumir toda la RAM, y durante ese tiempo la web anterior sigue sirviendo con normalidad.

### Despliegue automático: por qué se sondea y no se reciben webhooks

Desplegar al hacer push es la petición más repetida, y la forma evidente de hacerlo —un endpoint que GitHub llama— es la que peor encaja aquí. Se evaluaron las dos.

**Servidor de webhooks.** GitHub llama a una URL y el despliegue empieza al instante. El coste: un proceso escuchando en un puerto, que rompe el principio 2 y hay que mantener vivo; una ruta pública en nginx; un secreto compartido que verificar con HMAC en cada petición; y superficie de ataque entrante permanente para un VPS cuyo firewall solo abre 22, 80 y 443 a propósito. Y el fallo peor: si ese proceso muere, los despliegues dejan de ocurrir **en silencio**. Sigues haciendo push y nada pasa, sin ningún sitio donde mirar.

**Sondeo con temporizador.** Cada minuto, systemd invoca `orbit deploy --all --auto --quiet`. Para cada app en automático se hace un `git ls-remote` —una petición del protocolo git, sin clonar nada— y se compara el SHA remoto con el desplegado. Si coinciden, no se hace nada; el ciclo cuesta una conexión por app.

Se eligió el sondeo:

- **Cero superficie entrante.** No se abre ningún puerto ni se expone ninguna ruta.
- **No hay proceso que mantener.** Es el mismo modelo que el vigilante: systemd llama, el script termina.
- **Los fallos se ven.** `systemctl list-timers` y `journalctl -u orbit-autodeploy` dicen si se está ejecutando. Un demonio muerto no dice nada.
- **La latencia no importa.** Hasta un minuto entre el push y el despliegue. En un VPS personal eso no le molesta a nadie, y es un precio ridículo por no abrir un puerto.

La contrapartida honesta: con muchas apps en automático son muchas conexiones a la hora. `AUTODEPLOY_EVERY` sube el intervalo.

### «Sin cambios» y «no he podido preguntar» no son lo mismo

El sondeo tiene un fallo propio que el webhook no tiene: **puede no llegar a preguntar**. Durante meses `_pending_sha` devolvía lo mismo en los dos casos —código 1— y `deploy --all` los contaba juntos como «sin cambios». Con el token caducado, el repositorio renombrado o la red caída, el temporizador pasaba cada cinco minutos, anotaba «0 correctas · 0 fallidas · 2 sin cambios» y terminaba **en verde**. Nadie se enteraba de que el autodespliegue había dejado de existir, y la web seguía sirviendo la versión vieja sin dar ninguna señal.

Es exactamente el fallo silencioso que el principio 4 dice no tolerar, y estuvo dentro desde que se escribió el sondeo.

Ahora hay cuatro respuestas, no dos:

| | Significa | Qué hace Orbit |
|---|---|---|
| `0` | hay commit nuevo (`PENDING_SHA`) | desplegar |
| `1` | al día | contar como «sin cambios» |
| `2` | no se ha podido hablar con el remoto | error en pantalla, aviso por transición, la pasada falla |
| `3` | la rama ya no existe en el remoto | igual, pero con otro mensaje: se arregla cambiando la rama, no esperando |

El motivo exacto que dio git —`could not read Username`, `Repository not found`, `Could not resolve host`— se conserva en `REMOTE_ERR` y sale en el aviso, porque los tres se arreglan de forma distinta. Va por variable global y no por `stdout`: una sustitución de comandos es un subshell y el motivo se perdería justo cuando hace falta. Es el mismo patrón de `SUBCMD` (§8.3).

**La pasada devuelve error.** Con el temporizador eso deja la unidad en rojo en `systemctl status orbit-autodeploy` en lugar de terminar en verde sin haber hecho nada. Un timer no se detiene porque su servicio falle, así que no hay nada que rearmar.

**El aviso es por transición, no por estado.** Una avería de red dura horas y el temporizador pasa cada pocos minutos: avisar del estado serían cien mensajes iguales. Se reutiliza `_watch_to` del vigilante (§8.2) con el sujeto `remoto:<app>`, así que sale un mensaje cuando empieza y otro cuando se recupera. Como el fichero de estado lo reescribe el vigilante cada minuto, `_watch_mark` toma el mismo `flock`; la sección crítica es leer-modificar-escribir, nunca un despliegue entero.

Y aparece donde se mira: `orbit autodeploy status` y `orbit doctor` señalan las apps cuyo remoto está mudo.

### Un commit roto no se reintenta

Sondear cada minuto crea un peligro que no existe con webhooks: si un commit rompe el build, el siguiente ciclo lo intentaría otra vez, y el siguiente, indefinidamente.

La solución no necesita contadores ni ventanas, porque el disparador ya es un cambio: se guarda en `A_AUTOFAIL` el SHA que falló y se salta mientras el remoto siga en ese commit. Cuando llega uno nuevo, se intenta. Un despliegue correcto lo borra.

El aviso, como en el vigilante, se manda una vez —al fallar—, no en cada ciclo.

`--auto` implica además el filtro por app: solo se miran las que tienen `A_AUTODEPLOY='yes'`. Sin ese filtro, activar el automático en una app desplegaría también cualquier otra cuya rama avanzara, que es justo lo contrario de un permiso por app. Un `orbit deploy --all --if-changed` a mano sí las mira todas, e ignora `A_AUTOFAIL`: si lo pides tú, es que quieres reintentar.

### Por qué `cache/` más `rsync` y no un clon por release

Un `git clone` por despliegue en un repo con historia es lento y descarga lo mismo una y otra vez. Un clon persistente que se actualiza con `fetch` y luego se copia con `rsync --delete` reduce un despliegue típico a unos pocos segundos de red. El coste es un directorio extra por app.

### El entorno del build

Una lección aprendida en producción: **nunca exportes `NODE_ENV=production` durante el build.**

npm y pnpm interpretan esa variable como permiso para saltarse las `devDependencies`. En un proyecto Next estándar ahí viven `tailwindcss`, `postcss` y `typescript`. El resultado son errores desconcertantes: PostCSS no encuentra su plugin y, peor, los imports `@/components/Foo` dejan de resolver porque sin TypeScript instalado webpack ni siquiera busca ficheros `.tsx`.

Orbit hace `unset NODE_ENV` antes de compilar, y los comandos de instalación llevan `--include=dev` en npm y `--prod=false` en pnpm. `NODE_ENV=production` se establece en la unidad de systemd, que es donde de verdad hace falta.

---

## 5. Gestión de procesos: systemd, no PM2

PM2 es cómodo pero añade un runtime de Node que hay que mantener vivo, tiene su propio formato de estado y duplica lo que el sistema operativo ya hace.

systemd ya está ahí, arranca al iniciar la máquina sin trucos, escribe en journald con rotación incluida y permite encerrar el proceso. Cada app de Node o Python recibe una unidad generada así:

```ini
[Service]
User=deploy
WorkingDirectory=/srv/apps/<app>/current
EnvironmentFile=-/srv/apps/<app>/shared/.env
Environment=NODE_ENV=production PORT=3001 HOST=127.0.0.1
Environment=HOME=/srv/apps/<app>/shared/home
Environment=COREPACK_HOME=/srv/apps/<app>/shared/home/.cache/node/corepack
ExecStart=/bin/bash -c '<comando de arranque>'
Restart=always

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=/srv/apps/<app>
LimitNOFILE=65535
```

`ProtectSystem=strict` monta todo el sistema de ficheros en solo lectura salvo las rutas de `ReadWritePaths`. Una app comprometida no puede escribir fuera de su propio directorio.

### 5.1 El HOME del servicio, y por qué no es `/home/deploy`

`ProtectHome=true` no oculta `/home`: lo tapa con un tmpfs en **modo 000**. El proceso no puede ni atravesarlo, y eso incluye su propio `$HOME`, porque el `HOME` que systemd deduce de `User=deploy` es justo `/home/deploy`.

Durante meses no se notó, porque casi nada mira el `HOME` en producción. Lo que sí lo mira es **corepack**: cuando un repositorio fija su gestor de paquetes (`"packageManager": "pnpm@…"` en el `package.json`), el `pnpm` del `PATH` es un lanzador que resuelve la versión buena desde su caché. Y esa caché está, por defecto, en `$HOME/.cache/node/corepack/v1/`. Una app cuyo arranque es `pnpm run start` moría así, en bucle:

```
Error: EACCES: permission denied, opendir '/home/deploy/.cache/node/corepack/v1/pnpm'
orbit-tape-project.service: Scheduled restart job, restart counter is at 36.
```

Lo que hacía el fallo difícil de ver es que **el build funciona**. El build no corre dentro de la unidad: corre con `sudo -u deploy -H bash -lc`, sin cajón, con `/home` entero a la vista. Compilaba, activaba la release, y sólo entonces el servicio se estrellaba. Ninguna prueba unitaria lo alcanza, porque ninguna monta el espacio de nombres de systemd.

El arreglo **no** es abrir `/home` —`ProtectHome=read-only` dejaría al proceso leer las claves SSH de `deploy` y las de cualquier otro usuario, y el principio 7 dice que no hay un modo inseguro más cómodo—. El arreglo es que la app deje de necesitar `/home`:

```ini
Environment=HOME=/srv/apps/<app>/shared/home
Environment=COREPACK_HOME=/srv/apps/<app>/shared/home/.cache/node/corepack
```

Con eso el `HOME` cae dentro de `ReadWritePaths`, así que además de legible es **escribible**, que es lo que esperan las librerías que dejan cosas en `~/.config` o `~/.cache`. El cajón se queda exactamente igual de cerrado.

Tres detalles que no son obvios:

- **`COREPACK_HOME` se fija aparte y no se hereda de `HOME`.** corepack resuelve su caché mirando `COREPACK_HOME`, luego `XDG_CACHE_HOME`, luego `~/.cache`. Como el `.env` de la app se carga *antes* que las líneas `Environment=`, un `XDG_CACHE_HOME` escrito ahí movería la caché de sitio y devolvería el mismo `EACCES` sin nada que lo explicara.
- **Va en `shared/` y no en la release.** La caché se llena una vez y los despliegues siguientes la encuentran hecha; en la release se borraría con ella.
- **El build usa esa misma caché, pero conserva su `HOME`.** `_build_run` exporta `COREPACK_HOME` y nada más. Si se moviera el `HOME` entero, el almacén de pnpm (`~/.local/share/pnpm/store`) pasaría a ser uno por app y la misma dependencia ocuparía disco tantas veces como apps la usen. Lo que tiene que coincidir entre build y arranque es sólo la caché de corepack: si no coinciden, el build baja el gestor a un sitio y el servicio lo busca en otro.

`orbit doctor` avisa de las unidades escritas antes de este cambio (`service-home`). No las arregla: regenerar la unidad sin rehacer el build dejaría la caché vacía. Quien lo arregla es un `orbit deploy`, que hace las dos cosas en el orden bueno.

### `orbit exec` y por qué copia la unidad línea por línea

Una herramienta para lanzar migraciones y depurar solo sirve si el entorno que monta es **el mismo** que el de la app en producción. Si difiere en algo, te hace perseguir fantasmas.

El detalle que casi se escapa está en el orden de la unidad:

```ini
EnvironmentFile=-/srv/apps/<app>/shared/.env
Environment=NODE_ENV=production
```

systemd aplica esas directivas **en el orden en que aparecen**, así que un `NODE_ENV=development` escrito en el `.env` queda pisado por el de la unidad. `orbit exec` carga el `.env` primero y exporta las variables fijas después, reproduciendo esa precedencia exacta. Hay una prueba que lo fija (`NODE_ENV gana al .env`), porque invertirlo sería un cambio invisible en la lectura del código y muy visible al depurar.

Diferencias conocidas, y son deliberadas:

- **El `.env` se carga con `source`, no se interpreta.** systemd parsea pares `CLAVE=valor` sin ejecutar nada; Orbit ejecuta el fichero, igual que ya hacía durante el build. Para valores normales es indistinguible; con sustituciones de shell dentro del `.env`, no. Se prefiere la coherencia con el resto de Orbit sobre la coherencia con systemd, y se documenta.
- **El `PATH` es el del shell de login del usuario `deploy`, con `node_modules/.bin` y `.venv/bin` de la release por delante**, no el `PATH` fijo de la unidad. La unidad necesita un `PATH` mínimo y predecible; una sesión interactiva necesita encontrar `prisma`, `pnpm` o `pytest`. Son objetivos distintos.

La salida no lleva decoración y el código de salida se propaga, de modo que `orbit exec` se puede meter en una tubería o en un script. Por eso los avisos van a `stderr`: un aviso en `stdout` acabaría dentro del fichero de quien redirija la salida.

Y por eso mismo el log registra `exec <app>` sin el comando. Un `orbit exec web 'psql "postgres://u:clave@..."'` dejaría la contraseña escrita en `/var/log/orbit/orbit.log` para siempre. El nombre de la app basta para saber qué se tocó y cuándo.

Los puertos se asignan automáticamente desde el 3001 y **nunca se exponen**: las apps escuchan solo en `127.0.0.1`.

### El reparto de puertos, y por qué se mira dos veces

`free_port()` consulta dos fuentes y necesita las dos:

- **Los ficheros de configuración de las apps**, porque un puerto reservado por una app parada sigue siendo suyo.
- **`ss -ltn`**, porque un programa ajeno a Orbit puede estar ocupando ese puerto ahora mismo.

Fiarse solo de `ss` fue un bug real. Cuando la serialización pasó a comillas simples (ver §8), el `grep "^A_PORT=\"$p\""` de `free_port` dejó de coincidir con lo que escribía `save_app` y nadie lo notó, porque `ss` tapaba el problema mientras las apps estaban levantadas. El síntoma solo aparecía al registrar una app nueva con otra parada: las dos recibían el 3001, la segunda unidad moría con `EADDRINUSE` en el bucle de `Restart=always` y nginx servía a la que hubiera ganado la carrera.

De ahí dos decisiones:

- `used_ports()` lee el valor con comillas simples, dobles o sin ellas. Un fichero editado a mano tiene que seguir funcionando.
- `orbit doctor` avisa de puertos duplicados y `orbit port <app>` los repara. Sin argumento no mueve nada si no hay conflicto, así que se puede ejecutar las veces que haga falta.

La lección general está en §10: **cuando cambies un formato, busca a todos los que lo leen.**

Y la segunda fuente tenía su propio fallo, encontrado en la v1.2.9 leyendo el código y no viéndolo fallar. La consulta a `ss` estaba escrita `ss -ltn | grep -q ":$p "`, una vez por puerto candidato: el patrón que §10 prohíbe, con `ss` muriendo de SIGPIPE y `pipefail` quedándose con el 141. **La condición es falsa aunque el puerto esté ocupado**, o sea que la segunda fuente deja de existir sin avisar y volvemos exactamente al bug de arriba: dos apps con el mismo puerto y una unidad en bucle de `EADDRINUSE`. No se manifestaba porque la salida de `ss` cabe en el buffer de la tubería mientras haya menos de unos mil sockets a la escucha.

Ahora `ss` se lee **una vez** a una tabla en memoria y se consulta ahí, que además quita dos forks por candidato. Tres detalles que la prueba fija, porque los tres son formas de leer mal la misma tabla:

- **El puerto es lo que sigue a los últimos dos puntos.** Una dirección IPv6 trae los suyos: `[::]:3004` leído a la ligera da `:3004` y no casa con nada, y un puerto ocupado en IPv6 se daría por libre.
- **La cabecera de `ss` no es un socket.** Se descarta por no ser numérica en vez de pedir `-H`, que no existe en los iproute2 antiguos.
- **El doble de la prueba tiene que ser grande.** Con una salida corta, la versión mala pasa la prueba: el fallo *es* que la salida no quepa. Son 40.000 líneas con el acierto en la primera.

### 5.2 Reinicio sin corte: la unidad puente

Reiniciar una app con proceso dejaba uno o dos segundos de hueco: `systemctl restart` para el proceso viejo antes de arrancar el nuevo, y hasta que el nuevo escucha, nginx responde 502. La página de mantenimiento convertía ese hueco en un 503 honesto (§8), pero seguía siendo un corte. Desde la v1.0.2 el despliegue no lo tiene:

1. La release nueva arranca bajo **otro nombre** (`orbit-<app>-next`, «la unidad puente») y en un **puerto libre**, con el proceso viejo aún sirviendo en el suyo. El symlink `current` **todavía no se ha movido**: nginx sigue sirviendo los estáticos de la release vieja, que son los que el HTML del proceso viejo está pidiendo.
2. Se le hace el health check al puente. **Si no responde, no ha pasado nada** — y esta vez es literal: ni el proceso viejo se paró, ni el symlink se movió, ni nginx se enteró. Es el principio 4 aplicado al reinicio: el fallo ocurre antes de tocar producción, no después.
3. Con el puente verificado, **ahora** se activa el symlink y nginx pasa a mandarle el tráfico. La recarga de nginx es graciosa: las conexiones abiertas terminan donde estaban.
4. La unidad canónica se reinicia, ya con una release **verificada**, en su puerto de siempre. El hueco de este arranque lo atiende el puente.
5. nginx vuelve al puerto canónico y el puente se retira — **solo si la recarga se confirmó**: `render_nginx` distingue «configuración escrita» de «configuración aplicada» (`NGINX_RELOAD_OK`), porque con la recarga fallida el nginx que corre seguiría apuntando al puente y retirarlo sería el corte.

**El estado en reposo es idéntico al de antes**: una unidad, un puerto, un vhost. El puente existe solo mientras dura el despliegue, así que ni `watch`, ni `logs`, ni `port`, ni las copias tienen que saber que existe. Eso descartó la alternativa clásica de blue-green con dos unidades permanentes alternándose: cada consumidor de `svc_name` habría tenido que aprender cuál de las dos está viva, y son muchos.

Decisiones que no se ven desde fuera:

- **El symlink espera al puente.** La primera versión lo movía antes (el paso 5 clásico), y la revisión del PR lo cazó: nginx sirve los recursos a través de `current`, así que durante todo el health check el HTML viejo pedía chunks con hash de la release nueva — 404 en los estáticos hasta 40 segundos, incluso mientras se rechazaba un puente roto. Diferido, la ventana queda en lo que tarda una recarga, y el camino del fallo no toca literalmente nada.
- **La unidad puente ancla `WorkingDirectory` a la release concreta, no al symlink.** Con el symlink diferido ya no es una precaución sino una necesidad: cuando el puente arranca, `current` apunta todavía a la release vieja.
- **El puente no se `enable`.** Si el servidor se reinicia a mitad de despliegue, lo que debe volver es la unidad canónica.
- **El puerto del puente no se guarda en la configuración.** Es un estado de segundos; un despliegue muerto a mitad no puede dejar el conf mintiendo sobre el puerto. El vhost se genera con un override explícito (`NGINX_PORT_OVERRIDE`) que `nginx_vhost` aplica después de su `load_app`, porque ese `load_app` relee `A_PORT` del disco y pisaría cualquier apaño menos explícito.
- **Y ese override pisa la `A_PORT` global**, porque `nginx_vhost` trabaja sobre globales: después de renderizar el vhost del puente hay que recargar la app (`load_app`) antes del health check de la canónica. Sin eso —el hallazgo más caro de la revisión del PR— la comprobación medía el puerto del puente, que ya sabíamos que respondía, y daba por sana una canónica que quizá ni había arrancado, con nginx a punto de apuntarle. Desde entonces la suite apunta también **a qué puerto** se le pregunta la salud, no solo que se pregunta.
- **Si la canónica no levanta después de que el puente haya pasado el health check** —lo único que puede significar es que algo se quedó su puerto—, el puente **no se retira**: la web está en pie y retirarlo sería el corte que se intentaba evitar. El despliegue falla en voz alta diciendo quién está sirviendo y desde dónde, y el siguiente despliegue recoge el puente.
- **El trap de salida solo limpia el puente si nginx no le apunta.** La misma regla desde el otro lado: un `die` a mitad no puede llevarse por delante al único proceso que responde.
- **Entre mover nginx y parar el proceso viejo se espera a que nginx drene**, y esto no se dedujo: lo encontró el tráfico de un VPS. `systemctl reload nginx` vuelve cuando entrega la señal, no cuando el cambio está aplicado, así que justo después siguen vivos los workers con la configuración **vieja**. Parar ahí el proceso al que nginx acaba de dejar de apuntar mata lo que va en vuelo hacia él: eran **1-2 respuestas 502 por despliegue** —10 ms entre la recarga y el `stop`—, exactamente lo que esta sección prometía no tener. `nginx_drain` espera a que los workers de antes de la recarga terminen (~0,2 s), en las **dos** mitades del relevo, que tienen la misma frontera. Es un mejor esfuerzo con plazo de 10 s: un cliente con keep-alive puede retener un worker viejo hasta 75 s y bloquear el despliegue ahí sería peor que el 502. Dos detalles del cómo, que son trampas ya fichadas en §10: la espera mira `/proc` y no `kill -0`, porque a un proceso de `www-data` `kill -0` contesta «permiso denegado» y en bash ese falso es el mismo que «no existe» —daba por drenado siempre—; y los workers se buscan con `ps -C`, que compara el ejecutable, porque `pgrep -f 'worker process'` se encuentra a sí mismo y la espera no terminaba nunca
- **Un puente huérfano solo se recoge si la canónica contesta.** «Activa» para systemd no es «sana»: el final del punto anterior deja la unidad canónica activa a ojos de `is-active` y sin nadie escuchando en su puerto, y en ese estado el huérfano es el único proceso verificado que existe. Antes de devolverle el vhost a la canónica se le pregunta por HTTP; si calla, el despliegue aborta sin tocar nada y dice por qué.

`DEPLOY_OVERLAP="no"` en `orbit.conf` devuelve el camino clásico (parar, arrancar, mantenimiento mientras tanto). Hace falta cuando una app lee el puerto de su propio `.env` en vez de la variable `PORT` que le pasa la unidad: sus dos instancias pelearían por el mismo puerto, el puente nunca pasaría el health check y el despliegue abortaría siempre — sin corte, pero también sin desplegar. El primer despliegue y una app parada usan el camino clásico por definición: no hay nadie sirviendo a quien proteger.

Lo que las pruebas cubren y lo que no: la secuencia completa está fijada con dobles en `deploy_test.sh` —el orden es lo único que separa «sin corte» de «con corte», y la mutación de adelantar el `restart` la pone en rojo— y la unidad puente en `systemd_test.sh`. El drenaje de nginx es parte de ese mismo orden, con una comprobación por mitad.

Y esto ya se ha ejercitado con systemd y nginx de verdad bajo tráfico, que es lo que ningún doble podía ver: una sonda de ~10 req/s contra el dominio durante el despliegue, contando los 502. La primera tanda dio **5 en 3 despliegues**; con el drenaje, **0 en 5**. De ahí salió el fallo de arriba, que llevaba desde la v1.0.2 sin que ninguna prueba pudiera alcanzarlo. Dos avisos para quien repita la medición: la sonda tiene que ir **por debajo del `limit_req` de 40 r/s** del vhost, porque a 100 req/s nginx contesta 503 por rate limiting y parece un corte que no existe —la primera medición se acusó a sí misma—; y conviene distinguir el 502 (el hueco de verdad) del 503 (la página de mantenimiento del camino clásico, que ahí es lo correcto).

### 5.3 Aislamiento por app: un usuario de sistema por aplicación

Hasta la v1.0.3 todas las apps corrían como `deploy`, y eso tenía un precio concreto: una app comprometida podía leer el `.env` de todas las demás. Ahora cada app con proceso nueva nace con su propio usuario de sistema (`orbit-<app>`), y las anteriores se migran con **`orbit isolate <app>`**. `APP_ISOLATION="no"` en `orbit.conf` lo apaga para las que se creen después.

La pieza central no es el usuario: es la separación de **dos papeles que hasta ahora eran la misma persona**:

- **El fetcher** (`as_deploy`) trae el código: git y gh, con las credenciales que viven en el HOME de `deploy`. Siempre es `deploy` — el usuario de una app no tiene por qué poder leer las llaves con las que se clonan los repos privados. La caché de git (`<app>/cache`) es suya.
- **El builder** (`as_app`) compila y escribe: la release, `shared/`, los enlaces del `.env`, artisan. Corre como el usuario de la app, y sin `A_USER` —apps sin migrar, PHP, estáticas— resuelve a `deploy`, con lo que todo lo anterior a la migración se comporta exactamente igual que antes.

La frontera está en el rsync de la caché a la release: la caché es del fetcher y el builder la lee (0755); la release es del builder desde el primer directorio.

Decisiones con motivo:

- **El nombre del usuario es determinista** (`_app_username`): un `orbit restore` en un servidor recién instalado tiene que recrear *el mismo* usuario que dice la configuración restaurada. Y siempre vale para `useradd`: ≤32 caracteres y sin puntos, que el `NAME_REGEX` por defecto de Debian rechaza; si hubo que sanear o recortar, lleva un sufijo con hash del nombre completo — dos apps que sólo se distinguen en un punto no pueden acabar compartiendo usuario, porque compartir usuario es exactamente lo que esto elimina.
- **Todo lo que ejecuta código, y nada más.** Una estática no ejecuta nada que aislar, así que `orbit isolate` la rechaza; una app con proceso se aísla con su usuario; y una app PHP necesita además su **pool propio** (§5.4), porque sus páginas no las ejecuta ella sino php-fpm. Usuario y pool son la misma decisión y se responden con el mismo dato: `php_sock_for` mira el usuario, no el tipo. Un pool que corriera como `deploy` no aislaría nada, y un usuario propio sin pool dejaría a php-fpm sin poder leer el `.env` 0640 que le acaba de cambiar de dueño — las dos mitades separadas son peores que ninguna.
- **nginx no necesita nada nuevo**: los estáticos siguen siendo legibles por otros (0755/0644, como siempre), y lo que no debe leerse —el `.env`, `shared/`— está a 0640/dueño-app, que es el punto.
- **`orbit remove` se lleva el usuario**, con una guarda que no es decorativa: si `A_USER` es el propio `deploy` —una conf editada a mano—, no hay `userdel` que valga.
- **Las unidades ya estaban preparadas**: `HOME` y `COREPACK_HOME` viven en `shared/home` desde el bug de `ProtectHome` (§5.1), así que cambiar `User=` no movió ninguna caché de sitio.

Como todo lo que vive en systemd y en `/etc/passwd`, las pruebas cubren la mecánica —el nombre, el registro, la migración, el `User=` de la unidad, con `useradd` doblado— y un servidor real tiene que confirmar el resto: es la misma deuda de §5.1, con un motivo más.

---

### 5.4 Un pool de php-fpm por app: la otra mitad del aislamiento

El usuario por app (§5.3) no aísla una app PHP, y conviene entender por qué antes de tocar nada: **el código de una página PHP no lo ejecuta la app, lo ejecuta php-fpm**. Con un pool único —lo que instalaba `install.sh` hasta la v1.0.4— todas las apps PHP del servidor corrían como el mismo usuario, así que el dueño de los ficheros daba exactamente igual: un `file_get_contents('/srv/apps/otra/shared/.env')` desde cualquier `.php` se llevaba los secretos de todas las demás. Ninguna regla de nginx tapa eso, porque nginx no llega a ver la lectura.

Desde la v1.0.4, una app PHP aislada tiene **su propio pool**: `/etc/php/<ver>/fpm/pool.d/orbit-<app>.conf`, corriendo como su usuario, escuchando en `/run/php/orbit-<app>.sock`, y con el vhost hablándole a ese socket. Las apps sin aislar siguen en el pool compartido de siempre.

- **El socket lo elige el usuario, no el tipo.** `php_sock_for` devuelve el socket propio si la app tiene usuario propio. Así no hay dos condiciones que puedan desincronizarse, y el estado intermedio peligroso —usuario propio con pool compartido, donde php-fpm ya no puede leer el `.env` 0640 que acaba de cambiar de dueño— no es representable.
- **Los dos extremos del socket tienen dueño distinto a propósito**: `listen.owner = www-data` porque quien lo abre es nginx, y `user`/`group` la app porque es quien ejecuta. Al revés, nginx no podría hablarle.
- **`open_basedir` como cinturón sobre los tirantes.** El aislamiento real es de dueños; `open_basedir` cubre el caso de que a un fichero de otra app alguien le abra los permisos. Cuesta una línea y cierra toda una clase de accidente.
- **El pool se reescribe en cada despliegue**, por el mismo motivo que la unidad de systemd: que el disco no pueda contradecir a la configuración.
- **Y se retira con la app, siempre.** Un pool huérfano que apunta a un usuario que ya no existe deja a php-fpm **negándose a arrancar**, y con él todas las apps PHP del servidor. Por eso `orbit remove` lo borra aunque conserve los datos, y antes del `userdel`.
- **El fichero del pool no viaja en las copias de seguridad**: es configuración de *esta* máquina, con su versión de PHP. `orbit restore` lo regenera.
- **Y migrar tiene un relevo, porque el cambio de dueño y el de tráfico no pueden ser simultáneos.** El `.env` es el único fichero 0640 de `shared/`, y por tanto el único que puede quedarse sin lector a mitad de `orbit isolate`: cuando cambia de dueño, quien sirve sigue siendo el pool compartido —que corre como `deploy`— hasta que nginx mueve el tráfico al socket propio. En ese hueco la app contesta **sin su configuración**. Medido en un VPS con una sonda a 15 req/s: tres peticiones. No hay orden que lo evite, y conviene ver por qué: invertirlo deja al pool nuevo sirviendo mientras el `.env` es todavía de `deploy`, y falla exactamente igual. Así que durante el relevo lo leen **los dos** —dueño el usuario nuevo, grupo el viejo— y el grupo se cierra **después** de mover el tráfico y de drenar nginx. No abre nada: antes de migrar el `.env` era de `deploy`. Con el relevo, cero fallos en la misma sonda. Las dos mitades están fijadas por separado, y la segunda existe porque la mutación de cerrar el grupo antes de tiempo pasaba en verde sin ella.

Esto es lo único de todo el aislamiento que **sí se puede demostrar en el contenedor**, y por eso `nginx_test.sh` levanta dos pools de verdad con usuarios distintos y corre la misma sonda en las dos apps: la dueña lee su `.env` y la de al lado recibe `DENEGADO`. La comprobación de que la dueña **sí** lee no es decorativa — es la que distingue «denegado porque el aislamiento funciona» de «denegado porque la sonda está rota», que es como pasan las pruebas vacías. Escribirla destapó dos fallos del propio arnés, y ninguno del producto. El primero: un `chmod -R a+rX` que el árbol de pruebas necesita para que php-fpm lea las webs dejaba el `.env` legible por todo el mundo, y la comprobación habría pasado sin comprobar nada. El segundo lo encontró el CI, y es el más instructivo: **php-fpm sólo baja de privilegios si lo arranca root**. En un runner que corre como usuario normal, las directivas `user` de los pools se ignoran en silencio y los dos pools resultan ser el mismo — así que la prueba se ponía en rojo acusando a un código que estaba bien, que es exactamente el tercer estado que este documento lleva avisando desde lo de `jq`. La sección pide ahora el privilegio explícitamente (root, o `sudo` sin contraseña) y, si no lo encuentra, se salta diciéndolo; `make test-strict` se niega a dar por buena una tanda con saltos, así que el verde sigue significando lo que dice. La suite entera sigue siendo rootless: ésta es la única sección que pide más, y lo pide porque la propiedad que demuestra no existe sin ello.

### 5.5 El arranque de la máquina, y por qué Orbit no participa en él

Cuando el servidor se reinicia, **Orbit no corre**. No hay nada suyo en el arranque: ni un `orbit boot`, ni una unidad que recorra las apps, ni un `ExecStartPre` que repare nada. Lo que vuelve, vuelve porque systemd lo tenía apuntado — que es el principio 3 en su forma más literal (si Orbit desaparece del disco, la máquina sigue arrancando igual).

Dónde está apuntado cada cosa, que son cuatro sitios y ninguno es un fichero de Orbit:

| Qué | Quién lo deja `enabled` | Ancla |
|---|---|---|
| Las apps con proceso | el propio render de la unidad, en cada despliegue | `WantedBy=multi-user.target` |
| La unidad puente `orbit-<app>-next` | **nadie, a propósito** (§5.2) | — |
| `orbit-watch.timer`, `orbit-autodeploy.timer` | `watch enable` / `autodeploy enable`, con `--now` | `WantedBy=timers.target` |
| nginx, php-fpm, PostgreSQL, certbot, fail2ban | `install.sh`, una vez | sus propios paquetes |

Dos detalles que no son obvios:

- **El `enable` se reafirma en cada despliegue**, no sólo al crear la app: va en la misma función que escribe la unidad, por el mismo motivo por el que el fichero se reescribe entero — que el disco no pueda contradecir a la configuración. Una app cuyo `enable` se perdiera (un `systemctl disable` a mano, una restauración a medias) vuelve a quedar en el arranque con el despliegue siguiente, sin que nadie tenga que acordarse.
- **`After=network-online.target postgresql.service` ordena, no garantiza.** Ordenar sólo tiene efecto sobre unidades que estén en la misma transacción de arranque, y quien de verdad sostiene el caso raro es `Restart=always` con `RestartSec=3`: una app que arrancase antes que su base de datos se muere y vuelve sola en tres segundos. El orden está para que eso **no** pase y el log del arranque no se llene de cadáveres, no como red de seguridad. La red es el `Restart`.

**Comprobado con un reinicio de verdad**, que es la única forma de comprobarlo: 34 verificaciones sobre la máquina recién arrancada, 0 fallos, **sin tocar nada** — las 5 apps con proceso levantadas por systemd, nginx y php-fpm con sus 6 pools, y los 11 sitios contestando por su dominio. Hasta entonces sólo estaba probada la mitad barata: parar todo y volver a levantarlo desde una sesión que vive en esa máquina. No es la misma prueba y conviene tener claro qué se saltaba —el orden real del arranque, las dependencias que en frío no están todavía, y la pregunta previa a todas, que es si la máquina vuelve—, porque `systemd-analyze verify` valida la sintaxis de una unidad y no dice nada de eso.

Las 34 son 3 servicios base + 5 apps con su contador de reinicios + 6 pools + 11 dominios + 2 de unidades sueltas + 2 de HTTPS. Se apunta porque durante un tiempo esto puso «8 sitios», que era el inventario de la tanda anterior arrastrado a mano: con 8 la cuenta no sale, y un número que no cuadra con su total es la clase de dato que sobrevive a tres revisiones.

**Y repetido a la hora y cincuenta minutos del arranque, con el mismo resultado.** No es la misma pregunta que la primera pasada. Una comprobación hecha a los dos minutos dice que la máquina *arrancó*, y no distingue eso de una app que arranca, se muere y vuelve a arrancar cada tres segundos: con `Restart=always` puesto, `is-active` diría «activa» en los dos casos. Lo que los separa es el **contador de reinicios** de cada unidad, que es lo que mira ese bloque del script, y a las dos horas sigue en 0.

#### El mismo reinicio, en Debian 12

Repetido sobre la máquina de §23.4 (v1.3.4): **14 comprobaciones, 0 fallos y cero intervención** — los seis servicios base, el cortafuegos, la app con proceso con `NRestarts=0` y su web contestando 200 por nginx. Son menos que las 34 de arriba porque la máquina tiene una app y no cinco, no porque se mire menos: la lista sale de recorrer `/etc/orbit/apps/*.conf` y los descriptores que haya, en vez de un número escrito a mano — que es la corrección que se llevó el «8 sitios» del párrafo anterior.

Nada de esto es mérito de Orbit, y ése es justo el punto de la sección: vuelve lo que systemd tenía apuntado. Lo que se comprueba es que esté apuntado bien **en una distribución donde nadie lo había mirado**.

De paso cerró el cabo de §23.6b por el otro lado: antes del reinicio `systemctl is-active ufw` decía `inactive` con el cortafuegos filtrando; después dice `active`, porque ahora la unidad sí ha corrido. O sea que el estado engañoso es exactamente el de recién instalado.

#### El instrumento no puede formar parte de lo que mide

La primera pasada de esa comprobación dio 13 de 14, y el fallo no era de la máquina. El script estaba enganchado a `multi-user.target`, así que **formaba parte del arranque**: mientras corría, el arranque no podía estar terminado por definición, y `systemctl is-system-running` contestaba `starting`. `systemd-analyze blame` lo dejaba a la vista poniéndolo **el primero de todos con 46 segundos**, que eran su propio margen de espera.

Se arregla sacándolo de la transacción de arranque: un temporizador con `OnBootSec=2min` en vez de `WantedBy=multi-user.target`. Dos minutos y no cuarenta y cinco segundos por lo del párrafo anterior — el contador de reinicios necesita tiempo para contar.

Es la sonda de tráfico de §5.2 otra vez en otro plano: allí la medición se acusaba a sí misma por pasarse del `limit_req`, aquí por existir. El mismo día, el mismo script se había cazado a sí mismo con un glob `orbit-*.service` que incluía su propia unidad y daba un FALLO por una unidad `oneshot` que había terminado bien. **Antes de creerte una medición, comprueba si estás dentro de lo que estás midiendo.**

Lo que este reinicio **no** demuestra sigue siendo el reinicio **a mitad de un despliegue**. Auditar qué deja un despliegue muerto encontró tres residuos, y merece la pena separarlos porque sólo uno era un agujero:

- **La release a medio construir** no llega a producción. El symlink `current` es lo último que se mueve, así que la máquina vuelve sobre la release anterior y la carpeta huérfana no la sirve nadie. Es el principio 4 haciendo exactamente su trabajo.
- **La unidad puente** (`orbit-<app>-next`) no se hace `enable`, así que no vuelve; y si su fichero se quedó en el disco, el despliegue siguiente ya lo recogía. Eso no es de esta sección sino del §5.2, y el detalle importante es que antes de retirarlo **oye contestar a la unidad canónica**: si no contesta, no toca nada, porque ese puente puede ser lo único que está sirviendo la web.
- **El testigo de mantenimiento** (`shared/maintenance.on`) sí sobrevive, y ahí estaba el agujero — más pequeño de lo que parecía, pero por un motivo que había que comprobar y no suponer. Con un `reboot` ordenado no pasa nada: el despliegue retira el testigo en su trampa de salida, y **bash ejecuta la trampa `EXIT` también cuando lo mata un SIGTERM**, que es lo contrario de lo que uno diría de memoria. El residuo sólo existe cuando no hay SIGTERM: un `reboot -f`, un corte de luz, un SIGKILL por agotar el `TimeoutStopSec`. Entonces la máquina arranca con la web en mantenimiento, devolviendo 503 a todo el mundo, y **nadie la levanta** — porque en el arranque no corre nada de Orbit, que es lo que hace fuerte a esta sección y aquí juega en contra.

Y lo que faltaba no era el arreglo sino el aviso, igual que con el autodespliegue en rojo. `orbit watch` ya lo contaba a los `WATCH_MAINT_MAX` minutos —el comentario de `_watch_maint` dice literalmente «o lo dejó un despliegue que murió de mala manera»—, pero sólo si el vigilante está encendido. `orbit doctor`, que es donde uno pregunta qué pasa, se callaba, y encima de forma asimétrica: contaba el `php artisan down` de Laravel y no el mantenimiento propio de Orbit. Ahora lo dice, con desde cuándo, y **sin acción** ni en `--fix`: un mantenimiento se pone a mano y con motivo, y publicar una web que alguien había bajado a propósito es peor que dejarla bajada.

Así que del reinicio a mitad de despliegue sigue faltando la medición en la máquina, pero ya no es razonamiento entero: los tres residuos están enumerados, dos tienen código que los cubre y el tercero tiene prueba.

Y comprobando el arranque en frío apareció el mismo agujero **un escalón más arriba, y más tonto**: `orbit doctor` tampoco miraba si las apps estaban corriendo. Con la unidad de una app parada y su web devolviendo 502, el diagnóstico salía entero en verde —nginx válido, PostgreSQL activo, disco bien— mientras `orbit list` sí decía `stopped`. O sea que el dato existía y no estaba donde se pregunta qué va mal. Ahora se cuenta como error, **sin acción** por lo mismo de siempre: una app puede estar parada porque alguien la paró, y si se está muriendo en bucle arrancarla no arregla nada, sólo apaga la señal. Y se distingue de una web estática, que no está parada: es que no tiene nada que arrancar, y confundir las dos cosas convertiría cada sitio estático del servidor en una alarma.

---

## 6. Certificados y el problema de Cloudflare

### Por qué DNS-01

La validación HTTP-01 exige que Let's Encrypt alcance tu servidor por el puerto 80. Con el proxy de Cloudflare activado eso funciona a veces, pero si tienes "Always Use HTTPS" encendido entras en un huevo-y-gallina: Cloudflare redirige a HTTPS, que necesita el certificado que estás intentando emitir.

DNS-01 con la API de Cloudflare evita todo eso. Crea un registro TXT temporal, Let's Encrypt lo comprueba, se borra. Funciona con la nube naranja activada, permite comodines y no depende de que tu servidor sea accesible.

El token se guarda en `/etc/orbit/cloudflare.ini` con permisos `0600` y solo necesita el permiso `Zone → DNS → Edit`.

### El bucle de redirecciones

Este merece explicación porque es el fallo más confuso que puede darte un origen detrás de Cloudflare.

Si la zona está en modo **Flexible**, Cloudflare habla con tu origen por el puerto 80. Un vhost que redirige incondicionalmente a HTTPS hace esto:

```
navegador → Cloudflare → origen:80 → 301 a https://
navegador → Cloudflare → origen:80 → 301 a https://
navegador → Cloudflare → origen:80 → 301 a https://    ERR_TOO_MANY_REDIRECTS
```

La solución correcta es poner la zona en **Full (strict)**, y así lo dice la documentación. Pero una herramienta no debería depender de que el usuario configure bien un panel externo. El vhost generado mira la cabecera que Cloudflare siempre envía:

```nginx
if ($http_x_forwarded_proto != "https") {
    return 301 https://$host$request_uri;
}
```

Si el visitante ya está en HTTPS del lado de Cloudflare, servimos la página en vez de redirigir. El bucle se vuelve imposible.

Contrapartida honesta: alguien que llame directamente a la IP por el puerto 80 falsificando esa cabecera vería la web sin cifrar. Como el contenido es público de todas formas no es una fuga real, y `orbit firewall lock` cierra el puerto a todo lo que no sea Cloudflare, eliminando el matiz.

### El reto de ACME no se puede redirigir, y por eso la renovación no funcionaba

La redirección de arriba tenía un efecto que no se veía hasta noventa días después: **se llevaba por delante la validación de Let's Encrypt**.

El `if` vive a nivel de `server`, y nginx corre la fase *rewrite* del `server` **antes** de elegir el `location`. Así que incluir el snippet de ACME más arriba no bastaba: el `location ^~ /.well-known/acme-challenge/` no llegaba a mirarse nunca, y una petición al reto recibía el 301 igual que cualquier otra.

Lo que hacía el fallo invisible es que **la emisión sí funciona**. Cuando se emite el primer certificado el vhost todavía no tiene bloque de HTTPS ni redirección, así que certbot valida por el puerto 80 sin estorbo y el certificado sale. Es a partir de ese momento —con la redirección ya escrita— cuando la validación deja de ser posible: certbot pide por HTTP, se come el 301 al HTTPS, que no sirve el reto, y recibe un 404.

```
Invalid response from https://…/.well-known/acme-challenge/…: 404
```

El certificado caduca en silencio a los 90 días, y el único aviso es el `WATCH_CERT_DAYS` del vigilante, que dice que queda poco pero no que la renovación es imposible.

La solución es el patrón de bandera, porque nginx no encadena condiciones en un solo `if`:

```nginx
set $orbit_https_redir 1;
if ($http_x_forwarded_proto = "https") { set $orbit_https_redir 0; }
if ($request_uri ~ ^/\.well-known/acme-challenge/) { set $orbit_https_redir 0; }
if ($orbit_https_redir) { return 301 https://$host$request_uri; }
```

Esto no lo encontró ninguna prueba, y no por descuido: la suite ya comprobaba que el reto pasa por el servidor **por defecto** —el caso de la emisión, cuando la app aún no tiene vhost— y esa comprobación estaba en verde. El caso que faltaba es el contrario y es el de la renovación: el reto contra el vhost de una app que **ya tiene certificado**. Lo destapó `certbot renew --dry-run` contra un dominio de verdad. Ahora hay tres comprobaciones con nginx real: que el reto no redirige con certificado, que sirve el token, y que **lo demás sigue redirigiendo** — sin la tercera, «arreglarlo» quitando la redirección entera también saldría en verde.

### El otro degradado silencioso: `absolute_redirect`

Primo hermano del bucle anterior, y más difícil de ver porque no rompe nada de forma visible.

Cuando nginx responde `return 301 /pricing`, no envía esa ruta tal cual: construye una URL absoluta usando el `Host` y **el esquema de la conexión con el origen**. Detrás de Cloudflare esa conexión entra por el puerto 80 aunque el visitante venga por HTTPS, así que la cabecera sale así:

```
Location: http://midominio.com/pricing
```

El navegador, que estaba en `https://`, se va a `http://`. Con «Always Use HTTPS» activado Cloudflare lo devuelve a HTTPS y solo se pierde un viaje de ida y vuelta; sin él, el visitante se queda en texto plano. Y esto afecta también a las redirecciones que nginx genera por su cuenta, como añadir la barra final a un directorio, así que estaba ocurriendo desde el primer día en cualquier web estática.

La solución es una directiva:

```nginx
absolute_redirect off;
```

Con ella nginx responde `Location: /pricing` y el navegador conserva el esquema en el que ya está. Se emite en los dos bloques `server` de cada vhost. Hay una prueba que lo fija enviando `X-Forwarded-Proto: https` por el puerto 80 y comprobando que la respuesta no lleva `http://` delante.

### IPs reales

Sin configurar nada, un origen detrás de Cloudflare ve todas las peticiones viniendo de las IPs de Cloudflare. Los logs son inútiles y el rate limiting castiga a todos por igual. El instalador descarga los rangos oficiales y configura `set_real_ip_from` con `real_ip_header CF-Connecting-IP`. `orbit cf-update` los refresca cuando Cloudflare los cambia.

---

## 7. Detección de stack

`detect_stack()` recibe un directorio y decide cinco cosas: tipo, gestor de paquetes, comando de build, comando de arranque y dónde quedan los ficheros compilados.

El orden de comprobación importa, porque los indicadores se solapan:

```
1. Gestor de paquetes por el lockfile
   pnpm-lock.yaml → pnpm    yarn.lock → yarn    package-lock.json → npm

2. Si hay package.json, mirar las dependencias en este orden:
   next     → proceso, salvo output:'export' en next.config → estático
   nuxt     → proceso
   astro    → estático, salvo @astrojs/node → proceso
   vite     → estático SPA
   react-scripts → estático SPA
   express|fastify|koa|nest|hono → proceso
   otro con script build → estático SPA (mejor apuesta)

3. composer.json o ficheros .php → php, docroot en public/ web/ html/

4. requirements.txt, pyproject.toml o manage.py → python (ver 7.1)

5. index.html suelto → estático
```

La distinción SPA importa: una app de Vite necesita que todas las rutas caigan en `index.html`, mientras que Astro genera un fichero HTML por ruta y ese fallback rompería sus 404.

La detección se apoya en `jq`, que instala `install.sh`. Hay un respaldo con `grep` por si acaso.

Nunca es adivinanza silenciosa: el asistente muestra lo detectado y te deja corregirlo antes de guardar nada.

### 7.1 Python: por qué hacen falta tres decisiones y no una

La primera versión trataba «Python» como un único caso y generaba siempre lo mismo:

```bash
pip install -r requirements.txt … && gunicorn -b 127.0.0.1:${PORT} app:app
```

Eso está mal de dos formas distintas. Con `pyproject.toml` y sin `requirements.txt` el build **falla siempre**, porque el fichero no existe. Y `app:app` es un objeto que en Django no existe, en FastAPI puede llamarse de otra manera y en Flask solo acierta por casualidad. Un comando sintácticamente correcto que no levanta nada.

Ahora se deciden tres cosas por separado:

**El gestor, por el fichero de bloqueo.** `uv.lock` → `uv sync --frozen`, `poetry.lock` → `poetry install --only main`, `requirements.txt` → `pip install -r`, y `pyproject.toml` a secas → `pip install .`.

`uv` y `poetry` se instalan **dentro del venv de la app**, no en el sistema. Es deliberado: añadirlos a `install.sh` significaría imponerlos a todo el mundo y fijar una versión global para todos los proyectos, cuando lo que se necesita es exactamente lo contrario. Así se respeta el principio de no añadir dependencias y cada app usa la suya.

Detalle que costó una prueba descubrir: **el servidor de aplicación se instala al final, después de las dependencias**. `uv sync` significa «sincronizar», y elimina del venv todo lo que no esté en el fichero de bloqueo. Instalar gunicorn antes de `uv sync` equivale a no instalarlo.

**El framework, y de ahí el punto de entrada.** Si hay `manage.py` es Django, y el nombre del paquete sale de `DJANGO_SETTINGS_MODULE` **leído de ese mismo `manage.py`**, no de una convención. Adivinar por el nombre del directorio falla en cuanto alguien usa `config/` o `src/`, que es lo que hace media documentación moderna. Si `manage.py` no lo declara, se busca el paquete que contiene `wsgi.py`.

Para Flask y FastAPI se busca el fichero donde se instancia el objeto (`main.py`, `app.py`, `app/main.py`, `src/main.py`…) y **el nombre real de la variable**, que no siempre es `app`.

**WSGI o ASGI.** Cualquier proyecto Django moderno trae un `asgi.py` generado por `django-admin`, así que su existencia no dice nada. Lo que decide es que haya un servidor ASGI de verdad declarado en las dependencias: `channels`, `daphne`, `uvicorn` o `hypercorn`. Con eso, `uvicorn`; sin eso, `gunicorn`.

### 7.2 Los estáticos de Django no se pueden adivinar

`settings.py` es código Python: `STATIC_ROOT` puede ser `BASE_DIR / 'staticfiles'`, venir de una variable de entorno o calcularse. Leerlo con `grep` sería adivinar.

La única forma correcta es preguntárselo a Django, y eso solo se puede hacer **después del build**, con el venv ya montado. Por eso el despliegue tiene un paso 4b: ejecuta un `python -c` de seis líneas dentro de la release, con el `.env` cargado, y guarda `STATIC_URL`, `STATIC_ROOT`, `MEDIA_URL` y `MEDIA_ROOT` en la configuración de la app. `render_nginx` se limita a leer esos campos, de modo que sigue siendo una función pura que no necesita ejecutar nada.

Las rutas se guardan **relativas a la release** cuando caen dentro de ella. Guardar la absoluta llevaría el nombre de esta release concreta y quedaría obsoleta en el siguiente despliegue, apuntando a un directorio ya podado.

Este mismo paso aprovecha para mirar tres cosas más y avisar, que son las que más veces dejan una web de Django rota en un VPS:

- `DEBUG=True`, que enseña trazas con rutas y variables a cualquiera
- el dominio ausente de `ALLOWED_HOSTS`, que hace que Django conteste `400 Bad Request` a todo
- `MEDIA_ROOT` dentro de la release, que borra las subidas de los usuarios en el siguiente despliegue

Avisar y no arreglar es deliberado: los tres se corrigen en `settings.py`, que es del usuario.

### 7.3 Migraciones: avisar sí, aplicar nunca

`orbit deploy` no ejecuta `migrate`. Nunca. Una migración que borra una columna, lanzada sin querer por un despliegue automático, es la forma más rápida de perder datos que no se recuperan con un rollback de symlink.

Pero callarse tampoco vale: una app desplegada con migraciones pendientes falla en la primera petición que toque esa tabla. El equilibrio es `migrate --check` al final del despliegue, que no aplica nada, y un aviso con el comando exacto.

`orbit migrate` enseña primero el plan completo (`migrate --plan`), operación por operación, y pide confirmación. `--yes` la salta para scripts. Si falla a mitad, el mensaje dice explícitamente que la base de datos puede haber quedado a medias: Orbit no puede deshacer una migración, y fingir lo contrario sería peor que no decir nada.

---

## 7.4 Monorepos y `orbit.json`

En un monorepo la raíz **no declara el framework**: su `package.json` sólo lleva herramientas (turbo, prettier, husky) y `next` vive en `apps/web/package.json`. Sin mirar dentro, la detección caía hasta el último `else`, veía un script `build` y clasificaba un servidor Next como sitio estático con fallback SPA: nginx apuntando a un `dist/` que no existe. No es una degradación, es la web entera devolviendo 500.

`_find_app_package` recorre los `package.json` a profundidad 1 y 2 —`apps/web`, `packages/api`, `web/`— y se queda con el primero que declare un framework conocido; `apps/*` gana, porque es la convención para lo desplegable frente a las librerías internas. Los globs de `pnpm-workspace.yaml` no se parsean a propósito: cubrir el caso real sale más barato que escribir medio intérprete de YAML en Bash.

El resultado se guarda en `A_APPDIR` y cambia tres cosas:

- **el arranque** pasa a `pnpm --dir apps/web run start`, no `turbo run start` desde la raíz. El proceso tiene que ser la app: un orquestador por delante se come las señales de `KillSignal` y puede levantar más de un paquete;
- **el install y el build siguen lanzándose desde la raíz**, que en un workspace es lo correcto, porque las dependencias internas tienen que construirse antes;
- **las rutas de salida** quedan relativas a la raíz del repo (`apps/site/dist`), que es donde nginx pondrá el `root`, y el alias de `/_next/static/` apunta a `apps/web/.next`.

### Cuando adivinar no basta

Un repo puede declararse a sí mismo en un `orbit.json` y saltarse la inferencia entera:

```json
{ "type": "node", "appdir": "apps/web", "start": "node apps/web/run.js" }
```

Adivinar es lo que hay cuando no queda otra. Que el repo lo diga es mejor que cualquier heurística, porque viaja con el código y se revisa en el mismo PR que lo cambia. Sin `type` el descriptor se ignora con un aviso, igual que si no es JSON válido: un fichero a medias no debe dejar una app sin tipo.

### El fallback de una SPA no puede ser un URI

`try_files … /index.html` es una **redirección interna**: si el fichero no está, nginx vuelve a entrar en `location /`, vuelve a no encontrarlo y a las diez vueltas responde `rewrite or internal redirection cycle` con un **500 para todas las rutas**, incluidas las que sí existen. El peor modo de fallo posible: la web entera caída porque falta un fichero.

El fallback va a una named location que termina en `=404`, así que un `index.html` ausente da un 404 honesto en esa ruta y el resto del sitio sigue en pie.

---

## 8. Formato de configuración

Cada app es un fichero en `/etc/orbit/apps/<nombre>.conf`:

```bash
A_NAME='mi-web'
A_REPO='https://github.com/usuario/mi-web.git'
A_BRANCH='main'
A_DOMAIN='mi-web.com'
A_ALIASES='www.mi-web.com'
A_TYPE='next'
A_PKG='pnpm'
A_BUILD='pnpm install --frozen-lockfile --prod=false && pnpm run build'
A_START='pnpm run start'
A_OUTDIR=''
A_SPA='no'
A_PORT='3001'
A_DOCROOT=''
A_APPDIR='apps/web'   # monorepo: dónde vive la app dentro del repo
A_PYAPP=''
A_PYMGR=''
A_PYFW=''
A_MIGRATE=''
A_STATIC_URL=''
A_STATIC_ROOT=''
A_MEDIA_URL=''
A_MEDIA_ROOT=''
A_CREATED='2026-08-05T04:12:30+00:00'
A_LASTDEPLOY='2026-08-05T04:12:30+00:00 e62fe1a'
```

Se carga con `source`. Sencillo, pero tiene una trampa que costó un bug: si los valores se escriben entre comillas dobles, `source` **expande** lo que haya dentro. Un comando de arranque de Python como `gunicorn -b 127.0.0.1:${PORT}` se guardaba correctamente y al recargarlo `${PORT}` se convertía en cadena vacía.

La solución es serializar siempre con comillas simples y escapar las comillas simples internas:

```bash
_q() { local s=${1-}; s=${s//\'/\'\\\'\'}; printf "'%s'" "$s"; }
```

Cualquier campo nuevo que se añada debe pasar por `_q()`.

La misma trampa aparece en el `.env` de cada app, y ahí es peor porque lo leen **dos programas distintos**: bash con `source` (el build y `orbit exec`) y systemd como `EnvironmentFile`. Con comillas dobles, `PASSWORD="p$assw0rd"` hace que bash expanda `$assw0rd` y la app reciba `p`. Por eso `orbit env set` escribe también con `_q()`.

Eso deja un límite que se prefiere declarar antes que disimular: **un valor con una comilla simple se rechaza**. bash la escapa como `'\''` y systemd no entiende ese escape, así que el valor se leería distinto según lo lance el servicio o `orbit exec`. Guardar algo que se comporta de dos maneras según quién lo lea es peor que negarse y explicar por qué.

Leer, en cambio, es permisivo: `orbit env get` carga el fichero igual que lo hace el build, de modo que devuelve exactamente lo que verá la app, venga escrito con comillas dobles, sin comillas o con `export` delante.

Los campos se añaden **al final de la lista de `save_app` y a la de reinicio de `load_app`**, en ese orden. `load_app` pone todos a vacío antes de hacer `source`, y por eso una configuración escrita por una versión anterior de Orbit sigue cargando sin error: los campos que no existían quedan vacíos y se rellenan solos en el siguiente despliegue. No hace falta migrar nada.

---

## 8.0 La página de mantenimiento

Dos decisiones pequeñas con motivos concretos.

### El interruptor es un fichero, no una directiva

Regenerar el vhost y recargar nginx para encender el mantenimiento sería lo evidente, y es peor por tres razones: cuesta una recarga en cada sentido, puede fallar la validación justo cuando quieres cerrar la web deprisa, y deja el estado dentro de un fichero generado que el siguiente despliegue reescribe.

En su lugar, el vhost lleva siempre la guarda y lo que cambia es la existencia de `shared/maintenance.on`:

```nginx
location / {
    if (-f /srv/apps/<app>/shared/maintenance.on) { return 503; }
    …
}
```

nginx lo comprueba en cada petición. Encender es `touch`, apagar es `rm`, ambas atómicas, ninguna puede dejar la configuración rota. Y se puede hacer a mano si Orbit no está, que es el principio 3.

### La guarda va dentro de `location /`, y esto sí importa

La colocación evidente sería a nivel de servidor, una sola línea para todo el vhost. Está mal, y de una forma que no se nota hasta que es tarde.

Un `if` de servidor se evalúa en la fase de reescritura, **antes** de elegir el `location`. Eso significa que `return 503` también responde a `/.well-known/acme-challenge/`, de modo que certbot no puede completar la validación HTTP-01 mientras dure el mantenimiento. Un mantenimiento largo coincidiendo con una renovación deja el certificado caducado sin que nadie se entere.

Comprobado con nginx antes de elegir:

| Dónde va la condición | `/` | `/.well-known/acme-challenge/` |
|---|---|---|
| A nivel de servidor | 503 | **503** |
| Dentro de `location /` | 503 | **200**, devuelve el token |

Dentro de `location /`, el `location ^~ /.well-known/acme-challenge/` del snippet gana por prefijo y la validación sigue pasando.

### El motivo va aparte, y por eso hace falta SSI

La página es del usuario y no se toca; el motivo cambia en cada aviso. Meterlo dentro del HTML con `sed` destruiría cualquier personalización, y regenerar la página entera con el mensaje haría lo mismo.

Así que el motivo vive en `shared/maintenance.reason` y la página lo incluye:

```html
<p class="motivo"><!--# include file="maintenance.reason" --></p>
```

Diseño y contenido quedan separados: cambiar el mensaje es escribir un fichero de una línea, y no obliga a recargar nginx ni a tocar la maqueta.

Dos detalles que solo aparecieron probándolo con nginx:

**El `rewrite` tiene que estar en un `location` de coincidencia exacta.** Con la estructura evidente —`error_page 503 @mantenimiento` y un `location @mantenimiento` con `rewrite ^ /maintenance.html break`— la subpetición que genera la SSI para leer el motivo vuelve a caer en ese mismo `location`, se reescribe otra vez a la página, y **la página se incluye a sí misma** unas cincuenta veces hasta agotar el límite de recursión. La respuesta salía con el encabezado repetido y un `[an error occurred while processing the directive]` al final. Con `location = /__orbit_maintenance` para la página y `location = /maintenance.reason` para el motivo, cada subpetición cae donde debe.

**El fichero del motivo tiene que existir siempre.** Si falta, la SSI incrusta una página de error 404 completa —con su `<html>`, su `<title>` y la versión de nginx— dentro del párrafo. Por eso se escribe vacío cuando no hay mensaje, en lugar de borrarlo.

Ambos `location` son `internal`, así que el motivo no se puede pedir suelto desde fuera.

### 503 y no 200

`error_page 503 @mantenimiento` conserva el código, y el bloque añade `Retry-After`. Un 503 con `Retry-After` le dice a un buscador «vuelve luego»; un 200 con un cartel de obras le dice que ese es el contenido definitivo de la web. La diferencia se paga en posicionamiento semanas después.

### Automático durante el despliegue

Reiniciar un proceso deja uno o dos segundos en los que nginx no encuentra a nadie detrás y responde 502. Encender el mantenimiento justo antes del reinicio y apagarlo cuando el health check pasa convierte ese hueco en una página honesta.

El riesgo evidente es dejarlo encendido: un despliegue que muere a mitad tendría la web cerrada indefinidamente. Se cubre por dos vías. Un `trap … EXIT` retira el testigo pase lo que pase, incluido el camino del rollback. Y el vigilante avisa si una app lleva más de `WATCH_MAINT_MAX` minutos en mantenimiento, que cubre el caso de un `SIGKILL` en el que el trap no llega a ejecutarse.

Si el testigo ya estaba puesto antes de empezar, el despliegue no lo retira: lo puso una persona y no es suyo.

---

## 8.1 Redirecciones

Dos problemas distintos que se resuelven de dos formas distintas a propósito.

**Un dominio entero que se muda** es, conceptualmente, una web más: tiene su nombre, su vhost y su certificado, y hay que renovarlo. Modelarlo como una app con `A_TYPE='redirect'` hace que herede gratis `orbit ssl`, `orbit remove`, `orbit list` y `orbit nginx-rebuild`. La alternativa —un registro aparte de dominios redirigidos— habría obligado a duplicar las cuatro cosas. Lo único que se añade es un `_body_redirect` de una línea y la negativa explícita de `orbit deploy`, porque no hay código detrás.

**Las redirecciones de ruta dentro de una app** no pueden vivir en el vhost, porque el vhost se regenera entero en cada despliegue y se las llevaría por delante. Tampoco encajan en `<app>.conf`, que es un formato de `clave='valor'` de una línea. Van a un fichero propio, `/etc/orbit/redirects/<app>.list`, con una regla por línea:

```
/precios /pricing 301
/blog/* /noticias/* 301
~^/p/(\d{3})$ /producto/$1 302
/promo https://otro.com/x 301 noquery
```

Se puede leer con `cat`, editar con `nano` y versionar. `nginx_vhost` lo lee y antepone los bloques `location` al cuerpo de la app.

### La cadena de consulta, y por qué el valor por defecto es el contrario al de nginx

`return 301 /pricing` **descarta** la cadena de consulta. Es fácil suponer lo contrario, porque `rewrite` sí la conserva. Comprobado:

```
/a?utm=x  →  /destino            (return 301 /destino)
/b?utm=x  →  /destino?utm=x      (return 301 /destino$is_args$args)
```

Perder `?utm_source=` en una redirección no rompe nada visible: la página carga igual. Simplemente la campaña deja de atribuirse, y eso no se descubre hasta que alguien mira las analíticas semanas después. Por eso Orbit emite siempre `$is_args$args` salvo que el destino ya traiga su propia consulta o se pida `--no-query`.

### Orden de evaluación

nginx da prioridad absoluta a `location =`, así que las reglas exactas ganan sin más. Entre expresiones regulares gana **la primera que coincide**, de modo que el orden de emisión sí importa: `/blog/*` colocada antes que `/blog/viejo/*` se tragaría a la segunda. Orbit las ordena por longitud de patrón descendente, que es una aproximación buena a «lo más específico primero».

### Por qué se entrecomilla todo

El patrón y el destino se emiten entre comillas dobles:

```nginx
location ~ "^/p/(\d{3})$" { return 302 "/producto/$1$is_args$args"; }
```

Sin comillas, nginx interpreta `{` y `}` como delimitadores de bloque, y una expresión regular con un cuantificador `\d{3}` no arranca. Entrecomillar permite además admitir barras invertidas en los patrones sin inventar reglas de escapado. Lo que sí se rechaza al añadir la regla es el punto y coma, la comilla doble y los espacios: son los tres caracteres capaces de cerrar la directiva y convertir una redirección en otra cosa. Se valida antes de escribir nada, no después.

El comodín `*` se traduce a expresión regular escapando el resto del patrón, de modo que el punto de `/index.html` sea un punto y no «cualquier carácter».

---

## 8.2 El vigilante, sin demonios

El principio 2 dice que Orbit no corre en segundo plano. Vigilar un servidor parece exigir justo lo contrario, así que conviene ser preciso sobre por qué esto no lo rompe.

`orbit watch enable` escribe dos ficheros de systemd y activa un temporizador. Cada minuto, **systemd** invoca `orbit watch --quiet`; el script comprueba, actúa si hace falta y termina. No hay ningún proceso de Orbit vivo entre una invocación y la siguiente: `ps aux | grep orbit` no devuelve nada. Si borras `/usr/local/bin/orbit`, lo único que queda huérfano es un temporizador que se retira con `systemctl disable orbit-watch.timer`.

La alternativa —un proceso residente con su propio bucle— habría necesitado supervisión propia, y un vigilante que hay que vigilar no resuelve el problema, lo mueve.

### Notificar la transición, no el estado

Es la decisión que separa un watchdog útil de uno que se acaba silenciando.

Si el aviso se enviara mientras el estado sea «caído», una app rota a las tres de la mañana generaría un mensaje por minuto: 300 mensajes idénticos antes del desayuno. A la tercera noche, nadie mira las notificaciones de Orbit, y entonces da igual lo bien que detecte las caídas.

Por eso el estado se guarda entre ejecuciones en `/var/lib/orbit/watch.state` y solo se avisa cuando cambia: una vez al caer, una vez al rendirse, una vez al volver. El mismo criterio rige el historial: **un servidor sano no escribe una sola línea**. Registrar cada comprobación produciría 43.000 líneas al mes, y un log que nadie lee es un log que no existe.

### Reiniciar con freno

Reiniciar lo que se ha caído es la mitad útil del trabajo. La otra mitad es saber cuándo parar.

Una app que falla al arrancar —una variable de entorno que falta, una migración a medias— no se arregla reiniciándola. Un watchdog ingenuo la reinicia cada minuto para siempre, consume CPU, llena el journal y, sobre todo, disfraza el problema: el servicio aparece «reiniciándose» en lugar de «roto», que es lo que hay que ver.

Tres reinicios en diez minutos y se rinde: marca el sujeto como `rendido`, avisa con nivel crítico y no vuelve a tocarlo. La ventana se reinicia sola, porque tres reinicios repartidos a lo largo del día son tres incidentes distintos y cada uno merece su intento.

### Qué se arregla y qué solo se avisa

Se reinician servicios. **No se toca nada más.** El disco lleno, la memoria al límite y un certificado a punto de caducar solo generan un aviso.

La tentación de borrar releases antiguas o limpiar cachés automáticamente es real y hay que resistirla: una herramienta que borra ficheros por su cuenta a las tres de la mañana, sin nadie mirando, convierte un aviso en una pérdida de datos. El umbral existe para que un humano decida.

### Por qué no hay avisos por correo

Los canales son Telegram, Discord y un webhook genérico. El correo está deliberadamente ausente.

Un VPS recién instalado **no puede enviar correo**. Sin un relé SMTP configurado, el mensaje se queda en la cola local o lo descarta el destinatario por falta de SPF y DKIM. Y lo hace **en silencio**: `mail` devuelve 0 y el aviso no llega nunca.

Un canal de avisos que falla sin decirlo es peor que no tener ninguno, porque te hace creer que estás cubierto. Entrará cuando `orbit mail setup` configure un relé de verdad; hasta entonces, decirlo es más honesto que ofrecerlo.

### Concurrencia

El temporizador dispara cada minuto; una comprobación con la red lenta puede tardar más. Dos ejecuciones simultáneas se pisarían el fichero de estado, así que hay un `flock` no bloqueante: si ya hay una en marcha, la nueva sale sin hacer nada. El fichero de estado se escribe en un temporal y se mueve al final, de modo que una interrupción a mitad deja el anterior intacto y nunca uno a medias.

---

## 8.3 El despacho de subcomandos

Un comando como `orbit maintenance` recibe en la misma posición dos cosas distintas: un subcomando (`on`, `off`, `status`) o el nombre de una app. Es cómodo —`orbit env mi-web` se escribe solo— y es la fuente de ambigüedad más tonta que tiene la CLI.

Durante cinco versiones cada comando la resolvió por su cuenta, y cada uno eligió una respuesta distinta para el mismo argumento desconocido:

| Comando | `orbit <cmd> loquesea` hacía… |
|---|---|
| `env` | tratarlo como app y abrir el editor |
| `redirect` | imprimir la ayuda |
| `maintenance` | ignorarlo y listar el estado global |
| `autodeploy` | ignorarlo y listar el estado global |
| `watch` | abortar con un `uso:` escrito a mano |

Los tres primeros son variantes de «hacer otra cosa en silencio», que es exactamente lo que un despliegue no debe hacer. `orbit maintenance mi-web` respondía con el listado global y parecía que había funcionado.

Ahora la regla vive en `_subcmd` y sólo ahí:

```bash
_subcmd <comando> <por-defecto> <app|noapp> <subcomandos> [argumentos…]
```

1. Si el primer argumento es un subcomando o uno de sus alias, es un subcomando. **Gana siempre.**
2. Si no, y el comando admite una app ahí (`app`), se usa el subcomando por defecto y el argumento se deja intacto.
3. Si no es ninguna de las dos cosas, se aborta nombrando lo que se esperaba.

El resultado queda en `SUBCMD` —siempre el nombre canónico, nunca el alias— y el resto en `SUBCMD_ARGS`, que el llamador vuelca con `set -- "${SUBCMD_ARGS[@]}"`. A partir de ahí cada `case` sólo lista canónicos, así que añadir un alias es tocar la cadena de la declaración y nada más.

### Por qué gana el subcomando

Es la asimetría menos mala. Si ganase el nombre de la app, crear una app llamada `status` inutilizaría `orbit maintenance status` para todo el servidor; ganando el subcomando, sólo esa app pierde el atajo y sigue siendo alcanzable por la forma larga (`orbit maintenance status status`). Se rompe una app, no un comando.

Y como es un caso raro y desconcertante, cuando ocurre se dice: si el primer argumento es a la vez subcomando y nombre de app, `_subcmd` escribe la forma larga por `stderr`. Por `stderr` y no por `stdout` a propósito: `orbit env get` está pensado para `VALOR=$(orbit env get app CLAVE)`, y un aviso en la salida normal envenenaría la variable. Es la razón de que exista `hint()` al lado de `info()`.

### Pedir ayuda no es equivocarse

`-h`, `--help`, `help` y `ayuda` salen por la lista de subcomandos con código **0**, no por el camino del error. `redirect` y `db` declaran `help` en su propia cadena y ganan antes, así que conservan la ayuda larga que ya tenían; los otros seis reciben gratis un `uso:` derivado del propio spec, que por construcción no puede quedarse desfasado.

### La comparación es por igualdad, no por prefijo

Los alias se declaran `once|--once`, y la búsqueda compara `"|$grupo|"` contra `*"|$primero|"*`. Sin las barras, `on` encajaría dentro de `once` y `orbit autodeploy on` acabaría lanzando un despliegue en vez de activar una app. Hay una prueba dedicada a eso.

---

## 8.4 Clonar una app

`orbit clone mi-web staging` duplica una app para montar un entorno de pruebas. Lo que hay que diseñar no es la copia: es la lista de cosas que **no** se copian.

| Se hereda | Se deja fuera | Por qué |
|---|---|---|
| tipo, repo, rama, build, arranque | **puerto interno** | dos procesos no caben en el mismo puerto; se pide uno libre |
| gestor de dependencias, framework | **dominios extra** | los alias son del original; el staging tiene el suyo |
| comando de migración | **certificado** | Let's Encrypt emite por dominio, y el dominio es otro |
| reglas de redirección | **despliegue automático** | es un permiso, y los permisos no se heredan |
| página de mantenimiento | **testigo y motivo de mantenimiento** | son estado del original, no su aspecto |
| nombres de las variables del `.env` | **valores del `.env`** | ver abajo |
| | **releases y symlink `current`** | el build se hizo con el entorno del original |

### Los valores del `.env` son el detalle importante

Copiar el `.env` entero es lo cómodo y es exactamente lo que no se puede hacer: `DATABASE_URL` heredado significa que el staging escribe en la base de datos de producción, y eso no se nota hasta que ya ha pasado. Copiar solo los nombres deja un fichero que se ve de un vistazo y que la app rechaza al arrancar, que es el fallo correcto.

Se conservan comentarios, orden y la palabra `export`, para que el fichero siga siendo reconocible; lo único que se vacía es lo que va detrás del `=`. Quien sepa lo que hace tiene `--with-env`, con un aviso explícito.

### Las rutas absolutas llevan el nombre de la app dentro

`A_MEDIA_ROOT` suele ser `/srv/apps/mi-web/shared/media` —es la ruta que Orbit recomienda cuando detecta que Django escribe dentro de la release—. Copiada tal cual, la copia sirve **y sobrescribe** las subidas de producción. `_clone_path` reescribe el prefijo `$APPS_DIR/<original>` por el de la copia; las rutas relativas viven dentro de la release, no llevan el nombre de la app y se quedan igual.

Si la ruta absoluta apunta a otro sitio (`/mnt/almacen`), Orbit no puede saber qué querías: la copia tal cual y lo dice con un aviso.

### Nace en mantenimiento

Una copia recién creada no tiene release. Sin más, el dominio contestaría 502 —o el listado de un directorio vacío— y parecería que el clonado ha salido mal. Se aprovecha la maquinaria de §8.0: la copia nace con el testigo puesto y un motivo que explica que todavía no se ha desplegado, así que el dominio responde **503 con la página del original** desde el primer segundo. La validación de certbot sigue pasando por delante de la guarda, de modo que se puede emitir el certificado antes del primer despliegue.

Se sale con `orbit maintenance off`, a mano. El despliegue **no** lo quita solo: adivinar cuándo una app está lista para recibir tráfico no es cosa de Orbit.

### Todo lo que puede fallar, antes de escribir

El orden es deliberado: nombre válido y libre, dominio libre —mirando también los alias de las demás apps—, tipo clonable. Solo entonces se crean directorios y configuración. Y si `nginx -t` rechaza el vhost al final, se deshace todo: fichero de configuración, directorio, redirecciones y vhost. Una copia a medias con el dominio ya enganchado es peor que no tener copia.

---

## 8.5 Filtrar logs por fecha

`orbit logs --since 2h` parece un envoltorio de `journalctl --since`, y para las apps con proceso lo es. Para las estáticas —y para los 502 de cualquier app, que los escribe nginx y no la aplicación— hay que filtrar ficheros de texto, y ahí aparecieron dos problemas.

### El formato de log no llevaba la fecha

```
$remote_addr - $host "$request" $status $body_bytes_sent "$http_referer" …
```

Una línea que no se puede situar en el tiempo sirve para contar, no para depurar. Ahora el formato empieza por `[$time_local]`, delante de todo, porque así se lee mejor y el filtro puede mirar siempre las mismas columnas.

El formato vive en `/etc/nginx/conf.d/00-orbit-base.conf`, que escribe el instalador y **no** se regenera con los vhosts. Un servidor instalado antes se habría quedado sin poder filtrar para siempre, así que `orbit nginx-rebuild` corrige esa línea —con copia, `nginx -t` y vuelta atrás si falla— en vez de pedir una reinstalación.

### El filtro es `awk` de verdad, no `gawk`

Ubuntu trae **mawk**, no gawk: no hay `match()` de tres argumentos, ni `strftime`, ni `mktime`. La tentación es llamar a `date -d` por línea, que en un log de un millón de líneas es un millón de procesos.

Las dos marcas de tiempo posibles son de **ancho fijo**, así que `substr` basta:

```
acceso   [05/Aug/2026:17:59:52 +0000] …
errores  2026/08/05 17:59:52 [error] …
```

Ambas se normalizan a `YYYYMMDDHHMMSS`, que se compara **como texto** contra el corte. El mes del log de acceso va en inglés y abreviado, así que se traduce con `index("JanFebMar…", mes)`; sin esa traducción `Jan` sería posterior a `Aug` por orden alfabético, y filtrar por «las últimas dos horas» devolvería los accesos de enero. Hay una prueba dedicada exactamente a eso.

### La comprobación del formato mira la última línea

Un fichero de log no se vacía al cambiar el formato: durante días conserva arriba las líneas viejas y abajo las nuevas. La primera versión miraba la primera línea y avisaba de «este log no lleva fecha» en un servidor donde ya la llevaba. Se ve en cuanto se prueba contra un servidor real, y no antes.

---

## 9. Modelo de seguridad

### Superficie expuesta

Solo tres puertos: 22, 80 y 443. PostgreSQL escucha en localhost. Los procesos de las apps escuchan en localhost. php-fpm usa un socket unix.

`orbit firewall lock` va más allá y restringe 80 y 443 a los rangos de Cloudflare, de forma que el origen deja de ser alcanzable por IP directa.

### Privilegios

Orbit necesita root porque escribe en `/etc/nginx`, gestiona systemd y crea usuarios de PostgreSQL. Si lo invocas sin ser root, se auto-eleva con `sudo`.

Pero **el código de tus apps nunca corre como root**. Clonar, compilar y ejecutar ocurre como el usuario `deploy`, que no tiene contraseña ni shell de login útil. El endurecimiento de systemd limita el daño de una app comprometida a su propio directorio.

### Qué NO protege

Honestidad sobre los límites:

- El aislamiento entre apps cubre **todo lo que ejecuta código**: las apps con proceso por su usuario (§5.3) y las PHP por su usuario más su pool de php-fpm (§5.4). Ninguna puede leer el `.env` de otra. Lo que **no** cubre: las apps registradas antes de la v1.0.3 siguen compartiendo `deploy` hasta que se migren con `orbit isolate <app>`, y el aislamiento es entre apps, no contra el sistema — para eso está el endurecimiento de la unidad.
- Orbit **no audita el código que despliegas**. Si tu repo tiene una dependencia maliciosa, se ejecutará durante el build con los permisos del usuario de la app.
- **Los secretos se guardan en texto plano** en `shared/.env`, con permisos `0640` y dueño el usuario de la app. Es el mismo modelo que usa casi todo el mundo, pero no es una bóveda.

### Lo que sí hace el instalador

- UFW con denegación por defecto
- fail2ban vigilando SSH: 4 intentos, 4 horas de bloqueo
- Actualizaciones de seguridad desatendidas
- `server_tokens off`, HSTS, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`
- 403 en `.env`, `.git/`, `.sql`, `.log`, `.bak` y similares
- Rate limiting de 40 req/s por IP real con margen de 80
- TLS 1.2 y 1.3 solamente, con suites modernas

---

## 10. Estructura del código

Un solo fichero, organizado en secciones separadas por cabeceras:

| Sección | Contenido |
|---|---|
| UI | Colores, `ok`/`info`/`hint`/`warn`/`err`, `ask`, `confirm`, `choose` con fzf, `spin` |
| subcomandos | `_subcmd`, `SUBCMD`, `SUBCMD_ARGS` (§8.3) |
| app config | `load_app`, `save_app`, `_q`, `free_port`, `releases_desc` |
| detect | `detect_stack`, `_detect_python`, `_json_keys` |
| django | `_django_probe`, `_django_apply_settings`, `cmd_migrate` |
| redirecciones | `_redir_valid`, `_redir_rules`, `_redir_location`, `_redirect_block`, `cmd_redirect` |
| avisos | `notify`, `_notify_channels`, `_notify_ch_*` (uno por canal), `notify_configured`, `cmd_notify` |
| lote y automático | `_remote_head`, `_pending_sha`, `deployable_apps`, `cmd_deploy_all`, `cmd_autodeploy` (§4) |
| colas | `_queue_timer_write`, `_queue_run_one`, `_queue_connection`, `cmd_queue` (§18.9) |
| tráfico | `_traffic_files`, `_traffic_scan`, `_TRAFFIC_AWK`, `_traffic_report`, `cmd_traffic` (§13.8) |
| entorno | `_env_path`, `_env_read`, `_env_write`, `cmd_env` |
| mantenimiento | `maint_flag`, `_maint_guard`, `_maint_location`, `_maint_deploy_on/off`, `cmd_maintenance` |
| vigilancia | `_watch_state_load/save`, `_watch_to`, `_watch_down`, `_watch_apps`, `cmd_watch` |
| exec | `cmd_exec`, `_exec_script` |
| logs | `_since_expr`, `_log_since`, `nginx_log_access`, `cmd_logs` (§8.5) |
| nginx | `_body_static`, `_body_next`, `_body_proxy`, `_body_python`, `_body_php`, `_alias_location`, `nginx_vhost`, `render_nginx` |
| systemd | `render_systemd` |
| deploy | `cmd_deploy`, `cmd_rollback` |
| new app | `cmd_new` |
| clonar | `_clone_path`, `_clone_env`, `cmd_clone` (§8.4) |
| ssl | `cmd_ssl`, `cmd_cf_token` |
| github | `cmd_github` |
| base de datos | `db_create`, `cmd_db` |
| varios | `cmd_list`, `cmd_info`, `cmd_logs`, `cmd_env`, `cmd_status`, `cmd_doctor` |
| menú | `menu` |
| router | `main` |

### Convenciones

- `set -Eeuo pipefail` en la cabecera. Toda la lógica lo asume.
- Variables de app con prefijo `A_`, globales de configuración en mayúsculas sin prefijo.
- Funciones privadas con guion bajo inicial: `_body_static`, `_q`, `_json_keys`.
- Todo lo que se ejecuta como `deploy` pasa por `as_deploy` o `sudo -u "$DEPLOY_USER" -H`.
- Los mensajes al usuario van en castellano. Los comentarios del código, también.

### Trampas conocidas de Bash

Estas mordieron durante el desarrollo. Si tocas el código, tenlas presentes:

- **`shopt -s nullglob` está activo.** Un glob sin coincidencias desaparece. `grep patrón "$dir"/*.config` sin ficheros se convierte en `grep patrón` y **se queda leyendo de stdin para siempre**. Comprueba siempre que el array no está vacío antes de expandirlo.
- **`ls` con un glob vacío lista el directorio actual.** Usa `find` para enumerar releases.
- **`cmd | grep -q` bajo `pipefail` devuelve 141, no 0.** `grep -q` sale corriendo en cuanto encuentra la línea y cierra la tubería; quien escribe al otro lado recibe un SIGPIPE y muere con 141, y `pipefail` se queda con ese 141. Una condición escrita así **nunca** es cierta. Le pasó a `install.sh` al comprobar si `orbit` traía el núcleo de idiomas (§21.6b): la condición fallaba siempre y el instalador se quedaba en español para todo el mundo sin dar ningún error. Saca la salida a una variable y comprueba ahí dentro, o usa `grep -c … >/dev/null`, que lee hasta el final.

  Y hay una variante peor, que es la que costó el segundo hallazgo: **cuando la salida cabe en el buffer de la tubería, el bug no aparece**. `ss -ltn | grep -q ":$p "` y `swapon --show | grep -q .` estaban escritos así y funcionaban, porque `ss` con unos cientos de sockets y `swapon` con una línea terminan de escribir antes de que a nadie le cierren nada. El buffer son unos 64 KB —más de mil sockets—, así que la condición sólo miente en el servidor grande, que es donde peor viene. No basta con que la comprobación pase: **si hay una tubería a un `grep -q`, está mal aunque hoy dé el resultado correcto.** Los tres sitios que quedaban se quitaron en la v1.2.9; el de `free_port` está contado en §5, «El reparto de puertos», y el de `swapon` habría hecho un `fallocate` sobre un `/swapfile` montado.
- **Una función que asigna desde una tubería es letal o inofensiva según cómo la llames.** Con `f` haciendo `d="$(tubería que falla)"` dentro, medido en bash 5.2.21: `f` a secas mata el script por errexit; `_v="$(f)"` sobrevive, y `_v` se queda con la salida parcial; y `local x="$(falla)"` no falla nunca, porque el estado que se mira es el de `local`. La consecuencia práctica es que el fallo se queda dormido hasta que alguien escribe la llamada de la otra forma, y **una prueba que la ejerza capturándola no puede verlo**. Pon el `|| true` en la función, no en quien la llama. Salió del `_php_ver_del_sistema` de §23.2.
- **`printf '%-9s'` cuenta bytes, no caracteres.** «estático» son 8 caracteres pero 9 bytes en UTF-8, y la columna se descuadra. Usa ASCII en texto tabulado o calcula el relleno a mano.
- **Las variables de bucle no son locales por defecto.** Un `for d in ...` dentro de una función pisa la `d` de quien la llamó. Declara `local` siempre.
- **Con `set -u`, indexar un array fuera de rango aborta.** Valida los índices que vengan de entrada del usuario.
- **`${#cadena}` cuenta bytes si la configuración regional no es UTF-8.** Es la misma trampa del punto anterior una capa más abajo: calcular el relleno a mano no basta si el proceso corre con `LANG` vacío, que es lo normal en cron y en systemd. Fija `LC_ALL=C.UTF-8` donde midas anchos.
- **Un cambio de formato rompe a quien lo lee, no a quien lo escribe.** El paso a comillas simples en `save_app` dejó mudo un `grep` de `free_port` durante meses. Cuando toques la serialización, busca todos los `grep`, `sed` y `cut` que miren esos ficheros.
- **En bash 5.2, `&` en el reemplazo de `${var//patrón/reemplazo}` significa «lo que ha coincidido».** La opción `patsub_replacement` viene activada por defecto, así que `${s//</&lt;}` no produce `&lt;` sino `<lt;`, y una variable con `&` dentro tampoco sirve porque el resultado se vuelve a interpretar. Escápala como `\&` o usa `sed`. Silencioso: no da error, solo corrompe la salida.
- **Dos comandos en el mismo segundo comparten marca de tiempo.** Las releases se llaman `%Y%m%d-%H%M%S`; dos despliegues seguidos caían en la misma carpeta y la "release anterior" a la que volver era la que acababas de sobrescribir. Ahora se añade un sufijo `-2`, `-3`… si la carpeta ya existe.

---

## 11. Cómo probar los cambios

```bash
make test
```

Ejecuta sintaxis, `shellcheck -S warning` y las suites. Ninguna necesita un servidor de verdad, un dominio, ni el usuario `deploy`, y ninguna toca `/etc/nginx`, `/etc/systemd` ni `/etc/orbit` del sistema.

**Esa última frase estuvo escrita aquí siendo falsa, y costó una web.** Ver §11.1.

### 11.1 La suite borró el vhost de una app de verdad

El arnés redirigía `/etc/orbit`, `/srv/apps`, las cuatro rutas de unidad de systemd, `/etc/php` y las altas de usuarios. Cada una de esas redirecciones tiene detrás un incidente, y el comentario de `tests/lib.sh` lo dice: *«un fallo que sólo aparece según quién ejecute la tanda es lo peor de las dos formas»*. Nginx era el único directorio que se había quedado fuera, porque `nginx_file()` devolvía la ruta escrita a pelo y el enlace de `sites-enabled` estaba repetido a mano en cinco sitios: no había ningún punto donde desviarlo.

Lo que pasó: `isolate_test` termina con un `cmd_remove tienda`, y `cmd_remove` borra el vhost por su ruta absoluta. La tanda se lanzó **como root** en un servidor de pruebas que tenía una app llamada `tienda`, y la suite borró el vhost de la app de verdad. Sin un error, con las 32 suites en verde y `make test-strict` diciendo 2.512 comprobaciones y 0 fallos.

Lo que quedó es peor que una web caída: una app **registrada, compilada, con su pool de php-fpm escrito, su release en `current` y su unidad viva**, cuyo dominio no atendía nadie. La petición caía en el servidor por defecto y el visitante recibía la conexión cerrada — ni 404 ni 502; `curl` contesta `000`, que es lo que no dice nada. Se supo una hora más tarde, en la comprobación del arranque en frío, porque **ninguna de las tres preguntas que se hacen llegaba al dato**:

- `nginx -t` pasa. Lo que falta no es sintaxis, es un fichero.
- `orbit list` decía `php-fpm`. Es una constante escrita para las apps PHP: no puede acusar a nadie.
- `orbit doctor` salía entero en verde.

Dos arreglos, y el segundo importa más que el primero:

1. **Las dos rutas van en `NGINX_AVAILABLE` y `NGINX_ENABLED`**, y todo pasa por `nginx_file`/`nginx_link`. El arnés las reapunta a su árbol temporal, como ya hacía con las demás. `unit_test` vigila **la clase**, no aquellas cinco líneas: prohíbe que vuelva a aparecer la ruta escrita a mano en `orbit`, porque la sexta la escribe alguien dentro de seis meses.
2. **`orbit doctor` mira si cada app registrada tiene su vhost**, fichero y enlace. Éste sí lleva acción de `--fix`, al revés que el mantenimiento o una unidad parada (§19.5): aquéllos pueden ser una decisión de alguien y deshacerla sin preguntar es peor que dejarla, mientras que un vhost que falta no lo decide nadie — y se regenera del descriptor, así que rehacerlo no inventa nada.

Y la lección de método, que es de dónde salió todo: **para saber si las pruebas tocan el sistema, no las leas — móntales un sistema falso encima y mira qué queda tocado.** La sonda fue un `unshare -m` con copias montadas sobre `/etc/nginx`, `/etc/orbit`, `/etc/php` y `/etc/systemd/system`, testigos plantados con los nombres de app que usan las suites, y cada suite lanzada por separado. Señaló `isolate_test` en la primera pasada. Es el mismo instrumento de §5.1 —`unshare -m` para reproducir lo que sólo existe dentro del espacio de nombres de systemd— usado aquí para lo contrario: acotar el daño en vez de provocarlo.

### El arnés: `tests/lib.sh`

Todas las suites empiezan igual:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
```

El arnés monta un `/etc/orbit` de mentira bajo un directorio temporal, carga `orbit` sin su última línea (la llamada a `main`) y neutraliza la auto-elevación con `sudo`. A partir de ahí puedes llamar a `detect_stack`, `save_app` o `cmd_deploy` como funciones normales.

Dos detalles que importan:

- **Las funciones de Bash se pueden sustituir después de cargar el script.** Es el mecanismo que usan las pruebas para no tocar el sistema: `systemctl() { :; }`, `render_nginx() { :; }`, `cert_file() { echo "$TMP/certs/$1.crt"; }`. Por eso `orbit` reúne las rutas de los certificados en `cert_file`/`cert_key`/`has_cert` en lugar de repetir el literal `/etc/letsencrypt/live/...` por todas partes: hace el código testeable sin añadir configuración.
- **El arnés desactiva `errexit`** para poder contar un fallo esperado y seguir. Pero los comandos de Orbit *dependen* de `errexit` para abortar a tiempo, así que se invocan con `run cmd_deploy web`, que los mete en un subshell con `set -Eeuo pipefail`. Sin eso un despliegue roto "pasa" la prueba sin haber hecho nada, que es exactamente lo que ocurrió al escribir la suite.

### Qué cubre cada suite

| Suite | Qué comprueba | Requiere |
|---|---|---|
| `detect_test.sh` | `detect_stack` con un fixture por framework, e ida y vuelta de `save_app`/`load_app` con `${PORT}` y comillas simples | nada |
| `unit_test.sh` | conteo de apps, reparto de puertos, detección de conflictos y `orbit port` completo | nada |
| `subcmd_test.sh` | `_subcmd` en aislamiento y los ocho comandos que lo usan, con apps llamadas `status`, `set`, `get` y `on` para forzar el choque | nada |
| `exec_test.sh` | entorno de `orbit exec`, precedencia de `NODE_ENV`, `PATH`, formas de invocación, código de salida y secretos fuera del log | nada |
| `nginx_test.sh` | vhost real validado con `nginx -t` y servido en los puertos 18080/18443, ambas ramas (con y sin certificado), y `/static/` servido desde disco | `nginx` |
| `maintenance_test.sh` | el 503 servido por nginx de verdad, la cabecera `Retry-After`, que la validación de certbot sigue pasando y que un despliegue abortado no deja la web cerrada | `nginx` |
| `env_test.sh` | ida y vuelta del `.env` con valores que llevan `$`, comillas y espacios; compatibilidad con lo escrito por versiones anteriores | nada |
| `autodeploy_test.sh` | `deploy --all`, detección de commits nuevos con repos git reales, permiso por app, commit roto que no se reintenta y remoto mudo avisado una sola vez | `git`, `rsync` |
| `watch_test.sh` | transiciones de estado, protección contra bucles de reinicio, recuperación, filtrado por nivel y ausencia de avisos repetidos | nada |
| `redirect_test.sh` | reglas de ruta y dominios enteros, con nginx sirviéndolas de verdad: códigos, cadena de consulta, orden de evaluación y `Location` relativo | `nginx` |
| `python_test.sh` | proyecto Django real: venv, `collectstatic`, lectura de los ajustes, avisos y `orbit migrate`; y arranque real de Flask y FastAPI con el comando generado | `git`, `rsync`, red |
| `deploy_test.sh` | despliegue de principio a fin contra un repo git local: releases, symlink, poda, build fallido, y el ciclo completo clonar → desplegar → quitar el mantenimiento | `git`, `rsync` |
| `logs_test.sh` | traducción de «hace dos horas», el filtro por fecha sobre las dos marcas de tiempo de nginx, los argumentos que recibe journalctl y el formato emitido por nginx de verdad | `nginx` |
| `clone_test.sh` | qué hereda y qué no una copia, las rutas absolutas reapuntadas, el `.env` sin valores, el deshacer si nginx rechaza, y el 503 servido por nginx antes del primer despliegue | `nginx` |
| `provision_test.sh` | las variables que declara un `orbit.json`: lo que se puede generar se genera sin preguntar, lo que ya tiene valor no se pisa, sin terminal no se cuelga, travesía de rutas y escritura a través de un enlace simbólico | `jq` para el bloque del descriptor |

Las dos últimas se saltan solas con un aviso si falta el binario, en vez de fallar.

**Y una suite puede estar sin ejecutarse.** `provision_test.sh` existía desde su propio commit y no la lanzaba nadie: no estaba en el `Makefile`, y lo que se cuenta al final de la tanda son las suites que **sí** se lanzaron, así que el hueco no aparece por ningún lado. Eran 36 comprobaciones de credenciales generadas, travesía de rutas y escritura a través de enlaces simbólicos, o sea justo lo que no se quiere tener sin probar. Desde la v1.2.9 `make check` cruza los ficheros `tests/*_test.sh` que hay contra los que el target `test` invoca y falla si sobra alguno — la misma forma que la comprobación de glifos de §20.9: **se compara la clase entera, no el nombre que se te ocurra**.

Al ejecutarla salió el segundo problema, que es el tercer estado de §11 otra vez: sin `jq` la suite se ponía **en rojo** en vez de saltarse, porque sin `jq` no se aplica ningún descriptor (§18.9b) y sus cuatro primeras afirmaciones dejan de ser ciertas por diseño. Ya se salta anunciándolo. La pregunta al escribir una prueba que depende de una herramienta opcional sigue siendo la de §11: no sólo «¿se salta?», sino «¿qué afirma si no está?» — y hay una tercera que faltaba, «¿la ejecuta alguien?».

### La prueba que no se puede quitar

En `nginx_test.sh`:

```bash
curl -sI -H 'Host: x.test' http://127.0.0.1:18080/                               # 301
curl -s  -H 'Host: x.test' -H 'X-Forwarded-Proto: https' http://127.0.0.1:18080/ # sirve
```

El segundo debe devolver la página, no un 301. Es la no regresión del bucle de redirecciones de §6: si alguien "simplifica" el vhost y deja el `return 301` incondicional, vuelve el `ERR_TOO_MANY_REDIRECTS` con Cloudflare en modo Flexible y esta prueba es lo único que lo detecta antes de producción.

`deploy_test.sh` protege la otra garantía grande: **un build fallido no toca producción**. Fuerza un `A_BUILD` que falla y comprueba que el symlink `current` no se ha movido, que la release rota se ha borrado y que se sigue sirviendo la versión anterior.

---

## 12. Decisiones que se reconsideran a menudo

Preguntas que vuelven en cada revisión, con la respuesta actual:

**¿Por qué Bash y no Go o Python?** Porque el 90 % del trabajo es orquestar herramientas de línea de comandos, y Bash es nativo ahí. Un binario en Go sería más robusto, pero introduce un paso de compilación y hace que el código deje de ser auditable con `less`. Si el proyecto crece mucho, se replanteará.

**¿Por qué no Docker?** Porque el objetivo son VPS pequeños con proyectos que no están contenerizados. Docker añade una capa de memoria y complejidad que no se paga sola en ese escenario. Soporte opcional está en el roadmap.

**¿Por qué compilar en el servidor y no en CI?** Porque es lo más simple que funciona y no exige que el usuario configure nada externo. Builds remotos están en el roadmap.

**¿Por qué un fichero por app en vez de un único config global?** Porque permite editar, borrar y respaldar apps de forma independiente, y evita que una escritura concurrente corrompa la configuración de todas.

---

## 13. Interfaces: el contrato y el panel

La pregunta que abre esta sección es la que vuelve cada pocos meses: **¿y una interfaz gráfica?** La respuesta corta es que ya la hay, que está en el terminal, y que la que no está —la de verdad, con ratón— vivirá fuera de este repositorio y fuera del servidor. La respuesta larga es lo que sigue.

### 13.1 El bloqueador no era la interfaz, era el contrato

`orbit list` imprime una tabla con `printf`, columnas alineadas, colores ANSI y cabeceras en castellano. Está bien: la lee una persona. El problema aparece en cuanto algo que no es una persona necesita esos mismos datos.

Cualquier interfaz —un panel en el terminal, un cliente de escritorio, el script de alguien— que tenga que sacarlos de ahí acaba analizando texto con `awk`. Y a partir de ese momento **alinear una columna es un cambio incompatible**: se rompe algo, en otra máquina, sin que ningún aviso lo relacione con el commit que lo causó.

Por eso `--json` va primero y la interfaz después. El JSON es el contrato y la tabla es la presentación:

```
orbit version --json   orbit list --json            orbit info <app> --json
orbit status --json    orbit doctor --json          orbit top --json
orbit db list --json   orbit redirect list --json   orbit watch status --json
orbit env list <app> --json
```

`orbit version --json` publica **dos** versiones, la de Orbit y la del contrato, y no es redundancia: Orbit puede subir de versión sin que el contrato cambie —de hecho es lo normal— y un cliente que las confundiera se negaría a hablar con un servidor perfectamente compatible.

Tres decisiones dentro del contrato merecen explicación:

**Los campos se añaden, nunca se renombran.** Es una promesa explícita, escrita también en `USAGE.md`, y es lo único que hace que alguien pueda depender de esta salida. Si algún día hubiera que romperla, sube `schema`, que viaja en todas las respuestas precisamente para eso.

**Y qué se garantiza cuando `schema` sube.** Subir `schema` es la salida de emergencia, y conviene decir hasta dónde llega. Un cliente que sólo lea «si hay que romper, sube `schema`» sólo puede concluir que un `schema` mayor puede ser cualquier cosa, y de ahí sale la única política defensiva posible: negarse a hablar. Que es la peor forma de romper algo que todavía funcionaba.

Tres cosas se garantizan **para siempre**, en cualquier `schema`:

1. **`orbit version --json` no cambia de forma.** Sigue siendo un objeto con `schema`, `version` y `contract`, y los tres siguen significando lo mismo. Es el saludo, y un saludo que cambia no sirve para negociar nada.
2. **Por stdout va un solo objeto JSON, y todo lo dirigido a una persona sale por stderr.** La regla de §13.6b es del contrato, no de un comando. La única excepción es `orbit logs --json`, que emite NDJSON porque su salida es un flujo sin final, y lo anuncia en su primera línea (§13.9).
3. **Lo que no existe sigue siendo `null`.** Ningún `schema` futuro sustituirá un `null` por un 0, por una cadena vacía o por un valor centinela. Es la regla que separa «no aplica» de «está caído», y romperla haría que un cliente antiguo pintara alarmas falsas en vez de fallar — que es exactamente lo que §13.1 quiere evitar cuando dice que el puerto de una web estática es `null`.

Y una que se garantiza **dentro de un mismo `schema`**: un campo, una vez publicado, no cambia de tipo ni de significado. Puede quedarse sin usar; no puede querer decir otra cosa.

Lo que **no** se garantiza al subir `schema`: que un campo siga existiendo, que se llame igual, que una colección conserve su nombre, o que un enumerado no gane valores nuevos. Un cliente que se encuentre un `schema` mayor del que conoce puede fiarse de las cuatro reglas de arriba y de nada más — que es suficiente para saludar, avisar a quien lo usa y no inventarse datos.

**Lo que no existe es `null`, no cero ni cadena vacía.** El puerto interno de una web estática es `null`; el 0 sería un puerto. Su `service` también es `null` y no `stopped`, porque no hay ningún proceso que arrancar: confundir «no aplica» con «está caída» pinta una alarma roja donde no pasa nada, y eso enseña a la gente a ignorar las alarmas.

**`config` es el fichero, `state` es lo observado.** `config` reproduce `/etc/orbit/apps/<app>.conf` clave a clave, y por eso **todos sus valores son cadenas**: en el fichero lo son. Los datos con tipo —puerto como número, banderas como booleano— están en `state`, que es lo que Orbit deduce preguntándole a systemd, al disco y a los certificados. Mezclarlos habría obligado a decidir, campo a campo, cuál de las dos cosas es cada uno.

Como efecto secundario, los tres sitios que enumeraban los campos de una app —`load_app`, `save_app` y ahora el JSON— pasaron a leer una sola lista, `ORBIT_APP_FIELDS`. Antes, añadir un campo era acordarse de tres lugares, y el que se olvidaba era `load_app`: el campo no se vaciaba y se quedaba con **el valor de la app cargada justo antes**. Un bug que solo aparece cuando recorres varias apps seguidas, que es exactamente lo que hace `orbit list`.

### 13.2 Los secretos no cruzan el contrato

`orbit env list --json` devuelve los **nombres** de las variables y nada más, igual que su versión de tabla. No es una limitación pendiente de levantar: un panel que enseñe el `.env` entero es un panel que filtra la contraseña de la base de datos en la primera captura de pantalla que alguien pegue en un issue.

Quien necesite un valor concreto tiene `orbit env get <app> <CLAVE>`, que lo imprime pelado y sin adornos. Es una decisión deliberada por comando y no un descuido: pedir un secreto debe ser un acto explícito.

### 13.3 Por qué el panel está en el terminal y no en un puerto

`orbit top` dibuja CPU, memoria y peticiones por minuto de cada app, refrescándose en vivo. No abre ningún puerto, no deja nada corriendo y se va con `Ctrl-C`. Es la única forma de interfaz gráfica que respeta el principio 2 sin discusión: **la dibuja el terminal**.

Las alternativas se estudiaron y se descartaron, en este orden:

| Opción | Qué exige del servidor | Veredicto |
|---|---|---|
| Panel en el terminal | Nada | **Elegido** |
| HTML estático regenerado | Un fichero que ya escribe un temporizador existente | Aplazado, ver 13.5 |
| Cliente de escritorio por SSH | Nada | Fuera de este repositorio, ver 13.4 |
| Web UI activada por socket | Un socket en `127.0.0.1` y código nuevo ejecutándose como root | Plan B, no hizo falta |
| Panel web tipo Plesk | Un demonio, un puerto público y sesiones | **Descartado** |

El último merece detalle, porque es el que siempre se pide.

`orbit` se auto-eleva a root —lo necesita para escribir en `/etc/nginx` y gestionar systemd— y `orbit exec` ejecuta comandos arbitrarios dentro de una app. Un panel web por encima de eso no es «un panel»: es **una shell de root expuesta a internet**. Y esa clase de producto es la más atacada del hosting; el ejemplo reciente y concreto es CVE-2025-48703 en CentOS Web Panel, ejecución remota **sin autenticar** sobre unos 200 000 servidores, explotada activamente y con aviso de CISA. Orbit no tiene equipo de seguridad a tiempo completo; lo que tiene es una superficie de ataque de tres puertos, y esa es su mejor característica.

Hay un segundo motivo, menos dramático y más definitivo: **un panel cambia de producto**. Hoy Orbit compite siendo un script de Bash que cabe en una tarde de lectura. Con panel competiría con Coolify, CapRover, Dokploy y Plesk, que tienen equipos. El precedente más cercano lo confirma: Dokku, que es el vecino de al lado, mantiene el proyecto libre sin interfaz web y pone el panel en un binario aparte y de pago. Hasta ellos lo sacaron del núcleo.

### 13.4 Orbit Desktop: el cliente va fuera, y por eso puede existir

El roadmap decía «interfaz gráfica de escritorio: el terminal es el interfaz». Esa frase se escribió pensando en una GUI **corriendo en el servidor**, y ahí sigue siendo cierta. Pero una aplicación que corre en **tu portátil** y ejecuta `orbit` por SSH no rompe ninguno de los seis principios: el servidor no gana un proceso, ni un puerto, ni un byte de estado. Tiene exactamente el mismo estatus que tu terminal.

Eso es **Orbit Desktop**, que vivirá en su propio repositorio. Dos decisiones de partida:

**Habla SSH, no una API propia.** No hay que inventar autenticación: se reutilizan las claves, el agente y `~/.ssh/config`, incluido `ProxyJump`. Es el modelo de VS Code Remote-SSH y el de los gestores tipo Forge o Ploi, que administran servidores sin instalar un panel en ellos. El día que Orbit Desktop desaparezca, el servidor no se entera.

**El repositorio va aparte a propósito.** Mantiene `orbit` en un solo fichero de Bash y convierte la interfaz en *un cliente más*, no en *una parte de Orbit*. Si el cliente se queda sin mantenimiento, Orbit no se entera tampoco.

Y hay un regalo: un cliente que habla SSH con varios servidores **es** el `orbit remote add` de la v2.0. Resuelve el multiservidor sin plano de control, que es justo la restricción que se puso esa versión.

La regla que no puede romper, y que se escribe aquí para que quede antes que el código: **la interfaz nunca escribe en `/etc/nginx`, `/etc/orbit` ni systemd. Solo invoca `orbit`.** En cuanto genere un vhost por su cuenta, existen dos verdades sobre cómo se despliega y empieza el segundo producto dentro del primero contra el que avisa la sección 1.

### 13.5 Lo que hace falta para que un cliente exista: comandos que no pregunten

`orbit new` era un asistente de cien líneas: trece `ask` y doce `confirm`. Un cliente no puede contestar a eso, y fingir un terminal para hacerlo es la peor solución de todas.

La forma obvia habría sido escribir una rama «no interactiva» al lado de la interactiva. Se descartó: **dos caminos que hacen lo mismo se separan**, y el que se queda atrás es siempre el que no usa nadie a diario. Lo que se hizo en su lugar:

- Cada argumento nuevo (`--repo`, `--domain`, `--type`…) es **el valor por defecto de su pregunta**.
- `--yes` hace que `ask` y `confirm` devuelvan ese valor por defecto **sin leer de la entrada**.

Así los dos modos recorren exactamente el mismo código y no hay una mitad sin probar. Y `--yes` no significa «que sí a todo», sino «acepta lo que está por defecto», que en la práctica es más seguro de lo que suena: la base de datos no se crea y el editor del `.env` no se abre, porque esas dos preguntas tienen «no» por defecto.

Que `ask` **no lea** cuando hay `--yes` no es un detalle de estilo. Si leyera igualmente, se comería la línea siguiente del script que la invocó y el fallo aparecería tres comandos más allá, sin relación aparente con la causa.

El único sitio donde esto obligó a inventar algo es el certificado: Let's Encrypt necesita un email y sin terminal no hay a quién pedírselo. Morir ahí dejaría la app creada y desplegada pero el comando en error —la peor combinación—, así que se avisa, se sigue, y el certificado se emite después con `orbit ssl`.

Los dos comandos destructivos siguieron la misma regla, con un matiz que merece la pena escribir porque es fácil equivocarse:

**`--yes` significa «acepta lo que está por defecto», no «que sí a todo».** Por eso `orbit remove <app> --yes` quita la app de nginx, de systemd y de la configuración, pero **no borra `/srv/apps/<app>`**: esa pregunta siempre tuvo «no» por defecto. Borrar los datos necesita `--purge`, y va aparte porque es un daño de otra categoría: quitar una app de nginx se deshace volviéndola a crear en un minuto, mientras que `/srv/apps/<app>` contiene el `.env`, las releases y las subidas de tus usuarios, que no vuelven.

**`orbit rollback` sin release y sin terminal aborta.** La tentación es reutilizar el comportamiento del selector, que ofrece las releases de la más nueva a la más vieja, y quedarse con la primera. Pero la primera es la que ya está activa: ese «valor por defecto» habría reiniciado el servicio y recargado nginx para dejar todo exactamente igual. Cuando el valor por defecto sensato no existe, la respuesta correcta es preguntar, y si no se puede preguntar, abortar diciendo cómo se nombra.

### 13.6 Cómo mide el panel, y qué no puede medir

**La CPU es una diferencia, no un valor.** systemd solo lleva `CPUUsageNSec`, el total acumulado desde que arrancó la unidad. El porcentaje sale de restar dos lecturas y dividir por el tiempo transcurrido, así que **la primera vez no hay porcentaje** y se pinta como que no se sabe. Inventar un cero sería mentir, porque un cero es una afirmación. En el panel en vivo la segunda lectura llega sola al fotograma siguiente; para una foto suelta (`--once` o `--json`) hay que esperar a propósito, y por eso ese modo tarda un segundo.

Dos casos que parecen detalles y no lo son:

- **Una app parada tira su muestra anterior.** Su contador se queda quieto mientras está caída; si se guardara, al arrancar de nuevo la diferencia contra aquella lectura vieja pintaría un pico enorme que no ha ocurrido nunca.
- **Un contador que retrocede se ignora.** Al reiniciarse una unidad, `CPUUsageNSec` vuelve a empezar. La resta daría un negativo, y un negativo pintado como porcentaje asusta sin motivo.

**Las peticiones se cuentan sobre las últimas 5000 líneas**, no sobre el fichero entero: el log de acceso de una web con tráfico son cientos de megas y esto se refresca cada dos segundos. El tope es real y por tanto se anuncia: si un minuto lo llena, el número sale con un `+` detrás. Un número corto sin avisar se lee como «hay poco tráfico», que es justo lo contrario de lo que está pasando.

El filtro por tiempo reutiliza el mismo `awk` que `orbit logs --since` (§8.5), con la misma consecuencia: **un log del formato antiguo, sin marca de tiempo, no da número**. Se pinta como desconocido en vez de inventarlo, y se arregla con `orbit nginx-rebuild`.

**Sin terminal no hay panel.** Si la salida está redirigida, `orbit top` da un fotograma y termina. Un bucle que se refresca dentro de una tubería solo sirve para llenar el disco, y la secuencia de borrado de pantalla al principio de un fichero es basura.

### 13.6b `orbit deploy --json`: por qué no es streaming, y por qué sí lo es

Era la única pieza que le faltaba al contrato para que un cliente pudiera enseñar un despliegue, y la pregunta abierta —¿progreso en streaming o sólo el resultado?— resultó tener una respuesta que no obliga a elegir.

**Por stdout va un solo objeto, como en todos los demás comandos.** Si `deploy` emitiera una línea por paso, sería el único comando cuyo `--json` no es un documento JSON: `orbit deploy --json | jq .` daría error de sintaxis, y cada cliente tendría que llevar para siempre un caso especial para este comando. Un contrato con una excepción son dos contratos.

**El progreso es opcional, va por stderr y sólo si se pide** con `--progress`: una línea de JSON por suceso, legible según llega.

```bash
orbit deploy mi-web --json                    # un objeto, al terminar
orbit deploy mi-web --json --progress 2>eventos.ndjson
```

Eso es posible gracias al cambio que lo hizo viable: **con `--json`, todo lo que se le cuenta a una persona sale ya por stderr**. Hasta ahora la regla «por stdout sólo el JSON» se cumplía a mano, comando por comando, y funcionaba porque los comandos con `--json` se bifurcan pronto y no vuelven a hablar. `deploy` hace veinte cosas y cuenta cada una, así que mantenerlo a base de acordarse era cuestión de tiempo. Ahora lo impide la estructura: `ok`, `info`, `warn`, `title`, `hr` y el spinner escriben en `$UI_FD`, que vale 1 normalmente y 2 con `--json`. No hay forma de que un `✔` acabe dentro del objeto.

Y con eso, `--progress` no pisa nada: sólo cambia el formato de esa misma información, de frases para una persona a sucesos para un programa.

**Un despliegue que falla también contesta.** Es lo que más falta hace: sin objeto, el cliente tendría un código de salida y un texto en castellano pensado para alguien que lo lee. Como los fallos salen por `die`, que hace `exit`, hay un `trap … EXIT` que emite el objeto con `ok:false` y `failed_step` — en qué paso se rompió— si nadie lo ha emitido antes.

Dos campos existen para que un panel pueda enseñar distinto lo que **es** distinto: `rolled_back` (salió mal y se volvió atrás) y `recovered` (Orbit arregló el build por su cuenta y reintentó). Y `previous` lleva la release anterior, para poder ofrecer el rollback sin una segunda llamada.

Lo que `--json` **no** hace es preguntar: sin nombre de app aborta en vez de sacar el selector, y `--pick` está prohibido. `pick_app` escribe por stdout, que es donde va el objeto, y al otro lado no hay nadie que conteste.

### 13.6bb `orbit deploy --all --json`: seis finales, no dos

Un lote no es un despliegue repetido: de cada app sale **uno de seis finales**, y confundir dos de ellos ya costó un fallo real en la versión en prosa —«sin cambios» y «no he podido preguntar» valían lo mismo, así que un remoto caído se anunciaba como «nada que hacer» cada cinco minutos—. El contrato por lotes existe para que eso no se pueda repetir del lado de un cliente.

```
deployed     se ha desplegado
failed       se ha intentado y ha fallado
unchanged    el remoto no ha avanzado
unreachable  no he podido preguntarle al remoto
gone         la rama configurada ya no existe
skipped      este commit ya rompió el build; se espera al siguiente
```

Los recuentos van desglosados por los seis y no agrupados en «correctas / fallidas». Y `ok` es **la misma regla que el código de salida** —ni fallos ni apps sin contacto—, para que un cliente que mire el objeto y otro que mire el código de salida no puedan discrepar nunca.

**Dentro de cada app va el objeto de `orbit deploy <app> --json` sin recortar.** Es la decisión que hace el contrato barato de aprender: una forma, dos comandos. Por eso `result` es un objeto anidado y no unos campos aplanados — aplanarlos sería inventar un tercer contrato, y perdería `rolled_back`, `recovered` y `previous`, que son justo lo que un panel necesita para enseñar distinto lo que es distinto. En las apps que no se han desplegado `result` es `null` y el motivo va en `error`: un `null` es una respuesta, un objeto a medias no.

Y como en todos los demás comandos, por stdout va **un solo objeto**. Una pasada sin apps devuelve la colección vacía con `total: 0`, no un silencio: con stdout en blanco, un cliente no puede distinguir «no había nada» de «algo se rompió».

Con `--progress`, los sucesos por app (`{"event":"app",…}`) se mezclan con los pasos de cada despliegue por el mismo canal, así que **el suceso de paso lleva ahora el nombre de la app**. Es un campo añadido, que es lo que el contrato permite —los campos se añaden, nunca se renombran—, y sin él un paso de un lote no se puede atribuir.

Tres cosas salieron de escribirlo, y ninguna es del contrato:

- **`deploy --all` corría cada despliegue sin `errexit`.** Estaba escrito `if ( cmd_deploy "$n" ); then`, y dentro de un `if` bash apaga errexit *y se hereda*: media orden que fallara seguía adelante. Es la trampa que abre docs/DEVELOPMENT.md, y estaba en el camino por el que pasa el autodespliegue, que corre sin nadie delante. **La primera versión de este arreglo se quedó a medias**, y merece quedar escrito porque es la parte de la trampa que se olvida: quitar el `if` y poner `set +e … rc=$? … set -e` **no basta**, porque el hijo hereda el errexit apagado del padre. Hace falta encenderlo dentro: `( set -Eeuo pipefail; cmd_deploy … )`. Medido con las dos formas, la de a medias se comporta exactamente igual que el `if` que sustituía. Lo encontró una revisión del PR, no las pruebas — y ahora hay una que lo fija sustituyendo `cmd_deploy` por uno que falla a mitad.
- **El resumen en prosa escribía por stdout.** Nunca había convivido con un contrato, así que la regla de §13.6b se cumplía sola. Ahora sale por `$UI_FD`, como todo lo que lee una persona.
- **`REMOTE_ERR` se quedaba con la última línea de git**, que en el error más común es «and the repository exists.» — un trozo de frase suelto, del párrafo de ayuda que git imprime detrás. Daba igual mientras sólo lo leyera una persona junto al resto del mensaje; dentro del contrato es lo único que un panel enseñaría. Ahora se coge el primer `fatal:`.

Y una de fuera: **la ayuda de `deploy` y la de `remove` salían en una sola línea** con los `\n` a la vista, desde siempre. `t` imprime con `%s`, que no interpreta escapes. Se arregla en los dos sitios que imprimen, con `%b`, y no en `t`: la usan setecientos mensajes y ahí un backslash literal cambiaría de significado.

### 13.6c Lo que enseñó revisar el `--json` de `deploy`

Tres de los fallos que salieron de la revisión son la misma clase de error, y conviene nombrarla: **`deploy` es largo, y una regla que se cumple «acordándose» no sobrevive a un comando largo.**

- `health_wait` escribía en stdout. Se me pasó justo porque la función no está en `cmd_deploy` sino a 2.000 líneas de allí, y todas las pruebas de `--json` usaban una app estática, que no tiene servicio y nunca pasa por ahí. La lección no es «revisar mejor»: es que la prueba tiene que ejercer el camino, y una app sin servicio no lo ejerce.
- La detección de terminal preguntaba por `-t 1` aunque la presentación estuviera saliendo por la 2. Enrutar la escritura y dejar la decisión de dibujar mirando otro descriptor es medio arreglo.
- **`trap` sustituye, no encadena.** `cmd_deploy` ponía su manejador de salida y `_maint_deploy_on` lo reemplazaba por el suyo cien líneas más abajo. Los dos «funcionaban» por separado. La primera solución fue componer traps leyendo el anterior con `trap -p`, y se descartó al probarla: en el banco de pruebas heredaba el `rm -rf "$TMP"` de `tests/lib.sh` y borraba el directorio a mitad de la tanda. Lo correcto era más simple — **un solo manejador para todo el despliegue**, ya que `_maint_deploy_on` sólo lo llama `cmd_deploy`.

Y una de contrato: marcar `deploy` como capaz de JSON marcó también `deploy --all`, que despacha a otra función y devolvía prosa. Se rechazó en vez de improvisar —aceptar la opción y no cumplirla es lo peor de las tres salidas, porque le promete a un cliente un objeto que no va a llegar— y el rechazo duró exactamente hasta que el contrato existió, que es §13.6bb. Resultó tener seis finales por app y no cuatro.

### 13.6d Lo que cuesta un fork, y por qué se paga justo aquí

Orbit es Bash, así que la unidad de coste no es el algoritmo: es el proceso. Un `"$(funcion)"` no llama a la función, **lanza un shell entero** para recoger por una tubería lo que la función iba a escribir de todos modos. Cuesta medio milisegundo, que es invisible una vez y no lo es en un bucle.

Los ayudantes del contrato (`_j_str`, `_j_num`, `_j_bool`, `_j_list`) escriben por stdout, igual que el `printf` que los rodeaba. Capturarlos era pagar un proceso por campo para mover un texto de stdout a stdout. Medido con 40 apps, contando los `clone()` con `strace` y no a ojo:

| | antes | ahora |
|---|---|---|
| `orbit list --json` | 842 procesos, 630 ms | 242, 250 ms |
| `orbit list` | 327 procesos, 330 ms | 167, 190 ms |
| `free_port` | 80 procesos, 100 ms | 0, 42 ms |

**Se paga justo aquí por dónde está el consumidor.** El contrato `--json` es lo único que ve Orbit Desktop (§13.4): cada pantalla suya es un `orbit … --json` por SSH, así que esta latencia *es* la de la interfaz, sumada a la de la red y no escondida detrás de ella. Y `list` es el comando que más se teclea y la portada del menú. En un comando que despliega —donde el trabajo de verdad son un `git fetch` y un build de tres minutos— esto mismo no valdría la pena.

Las tres formas que se usan, por si hay que repetirlas:

- **Llamar en vez de capturar** cuando la función ya escribe por stdout. Es el caso de todos los ayudantes JSON.
- **`printf -v`** en lugar de `"$(printf …)"` para rellenar una columna.
- **`_t`, que deja la traducción en `I18N_MSG`**, en lugar de `"$(t …)"`, que la imprime y obliga a recogerla. Y sacar del bucle lo que no depende de la app: las siete palabras de las columnas ESTADO y SSL se traducían una vez por fila.

**La salida no cambia ni un byte, y eso se comprueba, no se supone.** El volcado de `list --json`, `info --json` y las comprobaciones de puertos, con cuatro apps de tipos distintos —alias, releases, certificado, mantenimiento, y comillas y `%` dentro de los valores—, se compara carácter a carácter contra el del código anterior. Un cambio de rendimiento sobre un contrato tiene exactamente un criterio de éxito, y es ése.

Y la lección de método, que no es sobre forks: **las dos primeras cifras que escribí eran falsas.** Un comentario decía «1.240 procesos en un `orbit list --json`» y esa función sólo la llama `orbit info`, o sea una app; otro decía 873 ms donde son 330. Ninguna cambiaba la decisión, las dos habrían pasado tres revisiones —una cifra dentro de un comentario no la comprueba nadie— y las dos se cayeron al medir de verdad, después del cambio y no durante. Es el «8 sitios» que eran 11 de §5.5, otra vez.

### 13.8 `orbit traffic`: analítica sin analítica

Quién visita cada web, sumando el log de acceso que nginx ya escribe. La decisión es la misma que en las métricas de despliegue (§18.10) —leer lo que ya existe en vez de montar un recolector—, y por eso una analítica de acceso cabe en Orbit cuando un panel web no cabe: no hay proceso nuevo, ni puerto, ni cookie, ni una línea de JavaScript en la página de nadie. El dato lleva ahí desde la primera visita.

**Lo que hace legítimo el resultado no es la suma, es lo que se dice sobre ella.** Cuatro decisiones, y las cuatro van en la dirección de admitir lo que no se sabe:

- **Se cuentan IPs, no personas**, y el texto lo dice cada vez. Sin cookies no hay forma de distinguir dos pestañas de dos visitantes, y llamar «visitas» a las IPs sería inventar precisión.
- **Lo automático se cuenta aparte.** En un VPS con IP pública, buena parte del tráfico son escáneres buscando `/.git/config` o `/wp-login`. Sumarlos a las visitas convierte la medición en ruido; el reparto se hace con una lista conservadora de agentes que se anuncian como automáticos, porque meter ahí navegadores raros convertiría el número en una opinión.
- **La ventana que no se puede cubrir se anuncia recortada.** logrotate se lleva los logs a los catorce días, así que `--since 30d` en un servidor de dos semanas tiene una respuesta más pequeña que la pregunta. Devolverla sin decirlo es el peor final posible, porque un número parece siempre una respuesta. Se compara el corte con la primera línea del fichero más viejo que exista —mirado **aparte** de la lectura, porque quien lee ya ha descartado los ficheros anteriores al corte y concluir desde ahí sería concluir sobre lo que no se ha abierto— y el JSON lo publica como `complete`.
- **Los percentiles salen de cubos, y se dicen como «≤ X».** Ordenar un millón de tiempos dentro de mawk no es ordenarlos: es escribir un quicksort en awk. Con cubos, lo que se afirma es exactamente lo que se sabe.

**La línea se parte por comillas y no por espacios**, y de eso depende que el análisis no se desalinee: el formato `orbit` tiene tres campos entrecomillados —petición, referencia y agente— y nginx escapa las comillas de dentro como `\x22`, así que `split($0, q, "\"")` es exacto. Partir por espacios se rompe con el primer agente de usuario, que lo llevan todos.

**Sólo se abren los ficheros que pueden aportar algo.** El mtime de un rotado es el momento de la rotación, o sea posterior a su última línea; uno más viejo que el corte no puede contener nada de la ventana. Es la diferencia entre abrir un fichero y abrir quince, y la respuesta a por qué esto no necesita un índice.

Tres cosas salieron de ejecutarlo y no de escribirlo. **`date -d "2026-08-11 20:00:00 +1 hour"` devuelve las 22:00**, porque el «+1» se lee como huso horario: la serie por horas se rellena con aritmética de epoch. **Una hora sin tráfico es un cero y no una hora que no existe** — saltársela encoge los huecos y dibuja dos picos separados por un día como si fueran seguidos. Y **más de dos días no caben en una línea de terminal**, así que se agrupa por días y se dice en la etiqueta: una barra que unas veces es una hora y otras un día, sin avisar, es peor que no dibujarla.

Lo que queda fuera, dicho para que nadie lo descubra mirando: lo que sirvió una caché delante no está aquí —con Cloudflare por medio, esto es lo que llegó al servidor—, y las rutas distintas tienen un techo (`TRAFFIC_MAX_KEYS`) para que un escaneo aleatorio no haga crecer el array de awk sin límite. Cuando se alcanza, se dice cuántas peticiones quedaron fuera; un recorte silencioso se lee como «esto es todo».

### 13.7 Lo que queda pendiente

El **panel HTML estático** —una página de solo lectura que regenerase el temporizador de `orbit watch`, servida por nginx como un site más y protegida con Cloudflare Access— sigue siendo la respuesta correcta para mirar el estado desde el móvil, y no rompe ningún principio: es un fichero, no un proceso. Está aplazado, no descartado.

La **web UI activada por socket** al estilo de Cockpit (systemd escucha, el proceso arranca bajo demanda y se muere solo a los diez minutos) es el plan B honesto si algún día `top` y el cliente de escritorio no bastan. Se documenta aquí para que quien lo proponga dentro de dos años sepa que ya se pensó, y en qué orden.

---

### 13.9 `orbit logs --json`: la única excepción del contrato, y por qué se declara

`logs` es el único comando de Orbit cuya salida es **inherentemente un flujo sin final**: con `--follow` no termina nunca. La regla de §13.6b —por stdout un solo objeto— no se puede cumplir aquí sin romper el caso principal, así que había dos salidas y ninguna es cómoda.

**La que se descartó: un objeto con todas las líneas dentro.** Sería coherente con el resto del contrato y funciona perfectamente para `orbit logs mi-web --lines 80`. Falla en los dos casos que importan: no se puede emitir hasta que termina, así que `--follow` queda fuera; y con `--since 7d` sobre una web con tráfico, ese objeto son cientos de megas acumulados en memoria de bash antes de imprimir el primer byte. **Un contrato que sólo funciona para el caso pequeño es un contrato con una excepción, y §13.6b ya dice que un contrato con una excepción son dos contratos.**

**La que se eligió: NDJSON, y decirlo en voz alta.** Una línea de JSON por línea de log. La excepción existe, así que se declara en vez de esconderla — y se declara **en la propia salida**: la primera línea es siempre un `{"event":"meta",…}` que lleva el `schema` y dice qué viene detrás. Un cliente no tiene que adivinar si este comando le va a dar un objeto o un flujo; se lo dice el flujo.

```
{"schema":1,"event":"meta","app":"mi-web","source":"nginx","unit":null,"since":null,"follow":false,"lines":80}
{"event":"line","ts":"2026-08-29T14:02:11+02:00","stream":"access","text":"…"}
{"event":"line","ts":null,"stream":"access","text":"…"}
{"event":"end","lines":2,"truncated":false}
```

Cuatro decisiones dentro, y las cuatro son la misma regla de siempre aplicada a un sitio nuevo:

**La marca de tiempo se toma del log, no se inventa.** El log de acceso de nginx la lleva con huso y sale con él. El de error la lleva **sin** huso, y sale sin él: es ISO-8601 válido y quiere decir «hora local del servidor». Ponerle el huso de hoy sería mentir en cuanto la línea sea anterior a un cambio de horario. Y un log del formato antiguo, que no lleva marca, da `"ts": null` — el mismo `null` de siempre, y de paso el cliente puede ofrecer `orbit nginx-rebuild` sin parsear un aviso traducido.

**`stream` dice de qué log viene cada línea**, y eso es algo que la salida en prosa **pierde**: `tail` mezcla el de acceso y el de error sin decir cuál es cuál. Distinguirlos es la primera pregunta de cualquiera que mira un log de nginx.

**`truncated` es por fuente, no por total.** Es la misma honestidad que `requests_capped` en `top` y `complete` en `traffic`. Y es por fuente porque el tope de `--lines` lo es: igual que `tail -n N f1 f2` da N de cada fichero. Con el log de acceso y el de error, un total de 3 con `--lines 2` no dice por sí solo si se llenó algo.

**No se estructura el contenido de la línea.** `text` es la línea tal cual. Sacarle el nivel, el módulo o el código HTTP sería inventar un formato que la aplicación del usuario no ha prometido, y es el primer paso hacia un parser de logs dentro de Orbit.

**Y `--follow` deja de ser el defecto con `--json`**, que es la misma regla que `orbit top`: en modo máquina, una foto. Quien quiera el flujo lo pide. Esto invierte un valor por defecto, así que conviene decirlo — y no rompe a nadie, porque hasta ahora `orbit logs --json` era un error. Cuando se sigue en vivo **no hay `end`**, y es correcto: un flujo que no termina no tiene final que anunciar. El cliente ya lo sabe, porque el `meta` se lo dijo con `"follow":true`.

---

## 14. Recuperación de builds

Un despliegue puede fallar por tu código —y entonces el trabajo de Orbit es apartarse y enseñarte el error— o puede fallar por algo que no tiene nada que ver contigo, que tiene un arreglo de una línea y que te obliga a entrar por SSH a las once de la noche a escribirla.

El segundo caso tiene nombre desde 2026:

```
[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: esbuild@0.28.1
```

pnpm 11 cambió el aviso por un error: una dependencia con scripts de instalación sin aprobar ya no compila. Y sin esos scripts, `esbuild` o `sharp` se quedan sin binario, así que aunque el install pasara, el build siguiente fallaría igual.

### 14.1 Las reglas antes que los remedios

Un reintento automático es una idea peligrosa: mal hecha, es un bucle que tumba el servidor o un despliegue que publica algo que nadie ha aprobado. Las cinco reglas que la hacen segura se decidieron antes de escribir el primer remedio:

1. **Como mucho un reintento.** Exactamente dos intentos de build por despliegue, nunca tres. No hay contador que ajustar ni configuración que subir.
2. **Solo fallos con firma conocida.** Si Orbit no reconoce el error, no reintenta. Repetir un `TypeError` es tardar el doble en dar la misma noticia.
3. **Todo dentro de la release nueva.** El repositorio y la caché de git no se tocan, y `current` sigue apuntando a la versión anterior mientras tanto. La garantía de §4 no se relaja: si la recuperación empeora las cosas, se borra la release y no ha pasado nada.
4. **Lo aprendido se guarda** en la configuración de la app (`A_PNPM_ALLOW`, `A_NODE_HEAP`), de modo que el despliegue siguiente aplica el arreglo **antes** de compilar y sale a la primera. Sin esto, la recuperación funcionaría pero enseñaría un error rojo en cada despliegue, y un error rojo que siempre está es un error que nadie mira. La excepción es el lockfile derivado (§14.6): eso es una propiedad del commit y no de la app, y recordarlo sería peor que olvidarlo.
5. **Se dice qué cambiar en el repositorio** para que Orbit no tenga que volver a hacerlo. El objetivo declarado de esta sección es que sobre.

Se desactiva entera con `BUILD_RECOVERY="no"`.

### 14.2 Por qué se edita el YAML y no se llama a `pnpm approve-builds`

pnpm trae un comando para esto, acepta los nombres por argumento y funciona sin terminal. Era la opción obvia. Se probó, y falló en el servidor de pruebas por un motivo que no se ve leyendo la documentación:

**`pnpm approve-builds` lo resuelve el pnpm que haya en el PATH, que no tiene por qué ser el que usa el build.** Con corepack, cada repositorio fija su versión en `packageManager`, y el `pnpm` del sistema puede ser un 10. Un pnpm 10 escribe el formato antiguo —`pnpm.onlyBuiltDependencies` en `package.json`— que el 11 **ignora en silencio**. El remedio decía haberse aplicado, el reintento fallaba con el mismo error, y nada en la salida explicaba por qué.

Escribir el `allowBuilds` directamente no depende de qué pnpm haya delante, es el mismo mecanismo que aplica la preparación del despliegue siguiente —uno y no dos, que es como se evita que discrepen— y se comprobó contra pnpm 11.20 real: con el fichero puesto, el install ejecuta los scripts pendientes aunque `node_modules` ya exista de un intento anterior.

### 14.3 El hueco que escribe pnpm, y por qué costó un despliegue

La primera versión no tocaba el fichero si ya contenía `allowBuilds:`, razonando que ahí mandaba el repositorio. Es un razonamiento correcto y una implementación equivocada, porque **pnpm 11 escribe él mismo el `pnpm-workspace.yaml` cuando falla**, con el valor sin decidir:

```yaml
allowBuilds:
  esbuild: set this to true or false
```

Así que en el caso normal —un repositorio que no declara nada— para cuando Orbit miraba el fichero ya existía, con un `allowBuilds:` dentro, puesto por pnpm medio segundo antes. Orbit se apartaba por respeto a una decisión que nadie había tomado, y el reintento fallaba exactamente igual que el intento.

Esto no se ve leyendo el código ni escribiendo pruebas con ficheros inventados: se ve ejecutando un despliegue de verdad contra pnpm de verdad. La versión actual mira **el valor de cada paquete**, no la presencia del bloque, y distingue seis situaciones:

| Situación | Qué hace |
|---|---|
| No existe el fichero | Lo crea con el bloque |
| Existe sin bloque | Añade el bloque al final |
| El paquete no está en el bloque | Lo añade dentro |
| El hueco de pnpm (`set this to…`) | Lo rellena con `true` |
| Ya está en `true` | No toca nada |
| Está en `false` | Lo respeta y no reintenta |

El último importa: un `false` es una decisión de quien escribió el repositorio —«este paquete no ejecuta nada en mi servidor»— y una herramienta que la sobreescribiera para que el build pasara estaría haciendo justo lo contrario de lo que se le pide.

### 14.4 La memoria, y cuándo negarse a reintentar

El segundo remedio es el `JavaScript heap out of memory`, que en un VPS pequeño compilando Next es un clásico. Se reintenta con `NODE_OPTIONS=--max-old-space-size=N`, calculado sobre la memoria **disponible** y no la total —en el servidor hay más apps corriendo— con un tope de 4 GB.

Lo interesante es cuándo **no** se aplica:

- Si hay menos de ~1,3 GB libres, no se reintenta. Prometerle a Node una memoria que no existe no salva el build: cambia el error por una muerte a manos del OOM killer, que además se lleva por delante lo que estuviera sirviendo. Se dice que añadas swap o compiles fuera, que es la verdad.
- Si ya se intentó con ese mismo heap y no bastó, tampoco. Repetir un remedio que ya falló es la definición de perder el tiempo.

`NODE_OPTIONS` se antepone al de la app, nunca lo sustituye: si tu `.env` trae el suyo, el tuyo va después y gana.

### 14.5 Lo que deliberadamente no se recupera

**Un lockfile desactualizado que toque a producción.** Es el fallo de despliegue más común de todos y tiene un «arreglo» tentador: reintentar sin `--frozen-lockfile`. La primera versión de esta sección lo descartaba entero. Medirlo demostró que la frontera no estaba donde se había supuesto, y §14.6 cuenta dónde está de verdad: se resuelve la mitad que no puede llegar a producción, y sólo esa.

Pero «no lo arreglo» y «no digo nada» son cosas distintas, y confundirlas es dejar a alguien delante de un volcado de log a las once de la noche. Junto a la recuperación hay una capa de **consejo**, que no toca nada, no reintenta y siempre devuelve 0 —la invoca quien está a punto de abortar—: reconoce el fallo y escribe la frase que te ahorra la búsqueda, incluido el comando exacto con el gestor de paquetes de **tu** app.

Reconoce cuatro clases, y el orden importa: **el disco lleno se mira primero**, porque provoca fallos extraños más abajo y mirarlo al final significaría dar el consejo del síntoma en lugar del de la causa.

| Firma | Verificada contra |
|---|---|
| `ERR_PNPM_OUTDATED_LOCKFILE` · `can only install packages when your package.json…` · `YN0028 … would have been modified` | pnpm 11.20, npm 10.9, yarn 4.5 |
| `ERR_PNPM_NO_LOCKFILE` · `can only install with an existing package-lock.json` · `YN0028 … would have been created` | pnpm 11.20, npm 10.9, yarn 4.5 |
| `ENOSPC` · `no space left on device` | — |
| `EBADENGINE` · `Unsupported engine` | npm 10.9 |

Esas cadenas están copiadas de la salida real de cada herramienta, ejecutada a propósito para verlas, y no de la memoria de nadie. Un patrón que no encaja no rompe nada, y ese es justo el problema: no se nota que ha dejado de servir.

**Cualquier cosa que cambie qué código se publica.** La recuperación puede arreglar *cómo* se compila; nunca *qué* se compila. Es la misma frontera del principio 1: Orbit despliega tu repositorio, no una versión mejorada de tu repositorio.

### 14.6 El lockfile que no cuadra, y la mitad que sí se puede resolver

El accidente es casi siempre el mismo: un merge de PR donde el conflicto de `pnpm-lock.yaml` se resolvió quedándose con un lado. La rama pasaba CI porque era coherente consigo misma; **el commit de merge, que es el que se despliega, no lo es y nadie lo probó**.

La primera versión de Orbit se negaba a tocarlo, con este argumento: instalar sin `--frozen-lockfile` publicaría versiones que nadie ha decidido. Suena bien y **es falso en la mitad de los casos**. Lo que lo demostró fue medirlo.

#### La medición

Se fijó a mano una resolución vieja dentro de un rango ancho —`semver` clavado en 7.3.5 bajo el especificador `^7.3.5`, que permite hasta 7.8.5—, se añadió una dependencia nueva al `package.json` y se instaló **sin** `--frozen-lockfile`. Si el argumento fuera cierto, `semver` habría saltado a 7.8.5.

Se quedó en 7.3.5. pnpm resolvió únicamente el paquete nuevo. **No rereseulve lo que no ha cambiado de especificador.**

#### Dónde está la frontera de verdad

pnpm no dice «el lockfile está mal»: dice exactamente qué ha derivado, y la clase importa.

| Lo que dice pnpm | Qué se movería al instalar sin congelar |
|---|---|
| `* N dependencies were added: playwright@^1.49.0` | sólo ese paquete y su cierre |
| `* N dependencies are mismatched:` `- ms (lockfile: ^2.1.3, manifest: ^2.0.0)` | **ese paquete se reresuelve** |
| `* N dependencies were removed: is-odd@^3.0.1` | desaparece del árbol |

Y hay una segunda pregunta que pnpm no contesta, porque para él no existe: **¿el paquete llega a producción?** Un `playwright` añadido y un `lodash` añadido producen exactamente el mismo mensaje. La diferencia está en el `package.json`, y hay que ir a mirarla.

De ahí sale la regla, que cabe en una frase: **Orbit resuelve solo lo que no llega a producción.**

- La deriva son **sólo altas**, y **todas** están en `devDependencies` → se resuelve y se reintenta. Las devDependencies se instalan para compilar (`--prod=false`) y no viajan al runtime; lo que ya estaba fijado no se mueve, que es lo que se midió.
- Cualquier otra cosa —un especificador subido, una baja, o un paquete añadido que está en `dependencies`— → Orbit se niega, y **nombra el paquete y el motivo**. Ahí sí se publicaría una versión que no ha decidido nadie.

Una sola dependencia de producción en el lote estropea todo el lote. No se resuelve «la parte buena»: el install es uno solo.

#### Lo que hace falta para poder decidir

Clasificar exige leer el `package.json`, y eso exige **`jq`**. Sin jq, Orbit no adivina: se niega y dice que le falta jq, porque suponer la sección de un paquete es exactamente el error que este código existe para no cometer.

Y sólo funciona con **pnpm**. No es un olvido:

- **npm** lista los paquetes que faltan del árbol entero, transitivas incluidas y con la versión ya resuelta (`Missing: is-number@3.0.0 from lock file`). De ahí no se puede saber qué entrada del `package.json` derivó.
- **yarn** no nombra ninguno: dice que el lockfile se habría modificado, y nada más.

Sin saber cuál es la dependencia directa no se puede decidir si llega a producción. Con los dos, Orbit explica y manda al repositorio.

#### La excepción a la regla 4

Los otros dos remedios **se guardan** en la configuración de la app, para que el despliegue siguiente salga a la primera. Éste no, y es deliberado: la deriva es una propiedad **del commit**, no de la app. Recordarla dejaría la app instalando sin lockfile congelado para siempre —justo lo que no queremos— cuando el despliegue siguiente, con el lockfile ya arreglado en el repositorio, funciona solo. Es el único remedio que no aprende nada.

---

## 15. Un proyecto, varios lenguajes

### 15.1 El caso: una web estática con un `.php` dentro

Un sitio de Astro con un formulario de contacto que envía por PHP. El 99 % del sitio son ficheros compilados que sirve nginx desde disco, y hay exactamente un fichero que tiene que ejecutarse.

`detect_stack` elegía **un** tipo y ese tipo era `static`, así que el vhost servía todo desde disco. La petición a `/contacto.php` entraba por `location /`, `try_files` encontraba el fichero, y nginx lo servía.

Eso no es un 404: **es entregar el código fuente**. nginx no trae `php` en `mime.types`, así que el fichero sale como `application/octet-stream` y el navegador se lo descarga entero, con la contraseña del SMTP o la clave de la API que llevara escrita dentro. Se comprobó contra nginx de verdad antes de tocar nada, y la prueba que lo detecta está en `tests/nginx_test.sh` y falla si alguien deshace el arreglo.

### 15.2 La forma correcta: capacidades, no un tipo más

La tentación es añadir un tipo `static+php`. Es un error: los tipos crecen multiplicándose —`static+php`, `next+php`, `static+python`— y cada combinación necesita su rama en la generación del vhost.

`A_TYPE` sigue siendo **cómo se sirve el grueso del sitio**, y lo que se ha añadido es una **capacidad ortogonal**, `A_PHP`, que responde a otra pregunta: «¿además hay que ejecutar PHP?». Un tipo, varias capacidades. Si mañana hace falta lo mismo con otro lenguaje, es un campo más y no una tabla de combinaciones.

La detección mira el repositorio, no sólo su fichero de manifiesto: si el proyecto es estático y hay algún `.php` que no venga de una dependencia, se enciende la capacidad. Se podan `node_modules`, `vendor`, `.git` y `.cache`, porque un `.php` de ejemplo dentro de un paquete de npm no convierte tu web en una aplicación PHP.

Sólo se mira en las estáticas, y la razón es que en una app con proceso nginx no sirve nada de disco: todo va al puerto interno. Un `.php` dentro de un proyecto Next no es cosa de nginx.

### 15.3 El bloque de PHP vive en un solo sitio

`_php_location` la usan la app PHP entera y la estática con PHP dentro. Con dos copias, alguien endurecería una y la otra se quedaría atrás sin que nadie lo notara —que es exactamente cómo se acumulan los agujeros.

Dentro incluye el snippet del sistema, `snippets/fastcgi-php.conf`, y no un `fastcgi_pass` escrito a mano. Ese snippet trae:

```nginx
fastcgi_split_path_info ^(.+?\.php)(/.*)$;
try_files $fastcgi_script_name =404;
```

El `try_files` no es decoración: sin él, una petición a `/subidas/foto.jpg/x.php` acaba ejecutando la foto subida como código PHP. Es la vulnerabilidad clásica de `cgi.fix_pathinfo`, y hay una prueba que la dispara a propósito y exige un 404.

El guard de mantenimiento va **dentro** del bloque. Antes sólo estaba en `location /`, así que una app PHP «en mantenimiento» seguía procesando cualquier petición directa a un `.php`: la web decía «volvemos enseguida» mientras el formulario seguía mandando correos.

### 15.4 Y si no ejecuta PHP, un `.php` tampoco se sirve

La otra mitad del arreglo, y la que cierra la fuga para todo el mundo:

```nginx
location ~ \.php$ { return 404; }
```

Va en **todas** las webs estáticas que no declaran la capacidad. Un `.php` olvidado en la carpeta publicada deja de ser código fuente descargable.

404 y no 403 a propósito: un 403 confirma que el fichero está ahí, y no hay ninguna razón para dar esa información.

### 15.5 Cuando el `.php` no llega a publicarse

Detectar PHP en el repositorio no garantiza que el fichero acabe en la carpeta que sirve nginx. En Astro y en Vite, lo que va en `public/` se copia tal cual a `dist/`, pero lo que está en `src/` lo procesa el build y no aparece.

Por eso el despliegue avisa cuando la capacidad está encendida y no hay ningún `.php` en la carpeta publicada, y dice dónde ponerlo. Es el aviso que convierte «el formulario da 404 y no sé por qué» en una frase.

---

## 16. El `www`, y por qué no se le pone a un subdominio

`orbit new` proponía `www.<dominio>` como alias siempre que el dominio no empezara ya por `www.`. Para `midominio.com` es lo que quiere todo el mundo. Para `blog.midominio.com` propone `www.blog.midominio.com`, que no usa nadie y que **no existe en el DNS**.

El daño no es cosmético: ese alias entra en la petición de certificado, y Let's Encrypt valida **todos** los nombres del lote o no emite ninguno. Un alias fantasma puede dejar sin HTTPS a un dominio que estaba perfectamente.

Distinguir un dominio registrable de un subdominio es, en el caso general, imposible sin la lista de sufijos públicos: 15 000 líneas que hay que mantener al día y que serían la dependencia más pesada del proyecto. La regla que se usa cubre lo que se ve en la práctica:

| Dominio | Etiquetas | ¿Se propone www? |
|---|---|---|
| `midominio.com` | 2 | Sí |
| `midominio.co.uk`, `midominio.com.ar` | 3, con SLD conocido bajo ccTLD de 2 letras | Sí |
| `blog.midominio.com` | cualquier otra cosa | No |

La duda se resuelve siempre hacia el «no», y es deliberado: equivocarse hacia el no cuesta escribir `--aliases www.midominio.com` una vez, y equivocarse hacia el sí cuesta un certificado que no se emite.

---

## 17. Copias de seguridad

Hasta ahora Orbit copiaba las bases de datos y nada más. Eso deja fuera lo único que de verdad no se puede recuperar de ninguna otra parte: el `.env`.

### 17.1 Lo que no se copia, y por qué

**El código no entra en la copia.** Está en git, que es una copia de seguridad del código mejor que cualquier cosa que pudiera hacer Orbit: tiene historia, está replicada y ya la estás usando. Meter las releases en el `.tar.gz` multiplicaría su tamaño por veinte sin añadir nada que no tuvieras ya.

Lo que se guarda es exactamente lo que **no** está en git y no está en ningún otro sitio:

| Dentro | Por qué |
|---|---|
| `shared/` | El `.env` y las subidas de tus usuarios. Irrecuperables. |
| `app.conf` | Cómo se construye y se sirve esta app. |
| `redirects.list` | Se escribieron a mano, no salen de ningún repositorio. |
| `database.sql.gz` | Obvio. |
| `manifest` | Qué hay dentro y qué hacer con ello. |

Restaurar, entonces, no es «volver al estado anterior»: es **dejar en su sitio lo que no está en git y desplegar**. El comando lo dice al terminar, con el nombre de la app ya escrito.

**El token de Cloudflare tampoco entra.** Es una decisión de seguridad y no un olvido: se regenera en treinta segundos con `orbit cf-token`, y su ausencia significa que una copia robada —que ya lleva secretos de aplicación dentro— al menos no sirve para tomar el control de tu DNS.

### 17.2 El formato es un tar.gz, no un formato de Orbit

Principio 3: si Orbit desaparece, lo tuyo sigue funcionando. Una copia que sólo Orbit sepa abrir sería justo lo contrario. Se abre con `tar tzf`, el manifiesto es texto plano y dice de dónde sale el código, y el volcado es un `pg_dump` normal que se carga con `psql`.

Alguien que encuentre uno de estos ficheros dentro de dos años, sin Orbit y sin este documento, tiene dentro todo lo que necesita para reconstruir la app a mano.

### 17.3 La contraseña de la base de datos

El detalle que separa una restauración que funciona de una que parece funcionar.

Un `pg_dump` lleva el esquema y los datos, pero **no el rol ni su contraseña**. Restaurando en un servidor limpio, lo natural sería crear el rol con una contraseña nueva… y entonces el `.env` que se acaba de restaurar, que lleva la vieja dentro de `DATABASE_URL`, ya no vale. La app arranca, y horas después falla con `password authentication failed` sin que nada apunte a la restauración.

Así que el rol se recrea con **la contraseña que dice el `.env` restaurado**, sacándola de la propia `DATABASE_URL`. Si no se puede leer, no se inventa nada: se avisa y se dan los dos comandos exactos para hacerlo a mano.

Un detalle del análisis que costó una prueba: el usuario es lo que va antes de la **última** arroba, no de la primera. Una contraseña con una arroba dentro —`postgresql://u:pa@ss@host/db`— se partía por la mitad.

### 17.4 Sacarlas del servidor sin saber de S3

Una copia que vive en el mismo disco que los datos no es una copia: el disco que se lleva los datos se lleva las copias.

Orbit no habla con S3, ni con rclone, ni con Backblaze, y no debería: sería una dependencia nueva, credenciales nuevas que guardar y un proveedor que elegir por ti. Lo que hace es pasarle cada copia recién creada al comando que le digas:

```bash
BACKUP_HOOK="rclone copy --"
```

Funciona con lo que ya tengas instalado, no añade nada al servidor y se prueba con un `echo`. Si el hook falla se dice en voz alta —«la copia sólo está en este servidor»— porque un envío que falla en silencio es peor que no tener envío: te crea la sensación de estar cubierto.

Hay dos maneras de escribir un hook y las dos tienen que funcionar. A un comando suelto se le añade el fichero al final, como hace `find -exec`. A una línea con tuberías, no: ahí el último argumento acabaría en el último comando de la tubería, que es donde no sirve para nada, así que si el hook **nombra** el fichero —`$ORBIT_BACKUP_FILE`— se respeta tal cual y no se añade nada.

Un aviso que costó descubrirlo probándolo: `orbit.conf` se carga con `source`, así que un hook escrito entre **comillas dobles** con un `$` dentro se expande al cargar el fichero, no al ejecutar el hook. En la primera prueba de verdad, `BACKUP_HOOK="cp -- $1 …"` acabó intentando copiar un fichero llamado `backup`, que era el primer argumento de la línea de comandos. En la documentación van con comillas simples y se explica por qué.

### 17.4b Verificar: saber que el fichero existe no es saber que se puede volver de él

Entre esas dos cosas caben cuatro averías, y **tres pasan `gzip -t` tan campantes**:

| Avería | ¿La ve el tamaño? | ¿La ve `gzip -t`? |
|---|---|---|
| El `.tar.gz` cortado por un disco lleno | A veces | **Sí** |
| `pg_dump` falló y dejó un `.gz` vacío | No | No |
| `pg_dump` murió a mitad (OOM, reinicio) | No | No |
| Falta el `.env` dentro | No | No |

La segunda era un bug de verdad, no una hipótesis. `_backup_one` hacía:

```bash
sudo -u postgres pg_dump "$db" 2>/dev/null | gzip > "$tmp/database.sql.gz"
con_db="si"
```

Si `pg_dump` falla, **`gzip` escribe igualmente un `.gz` válido de contenido vacío** y la línea siguiente marca el manifiesto con `base_de_datos=si`. Y el fallo no se propagaba: `_backup_one` se llama desde `if out="$(_backup_one "$n")"`, y dentro de un `if` bash apaga `errexit`, así que `pipefail` no salta (ARCHITECTURE §20.7). El resultado era una copia que decía llevar la base de datos y no la llevaba, sin un solo aviso.

Ahora el código de salida se recoge con el único patrón que funciona —`set +e; ( set -Eeuo pipefail; … ); rc=$?; set -e`— y si el volcado falla **no hay copia**: mejor ninguna que una que miente.

**La marca de que un volcado está entero.** `pg_dump` escribe `-- PostgreSQL database dump complete` cuando termina, y es lo único que distingue un volcado bueno de uno cortado. Dos detalles, los dos comprobados ejecutándolos contra un PostgreSQL 16 de verdad:

- **No es la última línea.** Desde PostgreSQL 16.13 el volcado acaba en `\unrestrict <token>`, que va *después* de la marca. Comprobar sólo el final daría por rota una copia buena en cualquier servidor al día.
- **Empieza por `--`, así que `grep` la toma por una opción.** Sin `-e` delante, `grep` contesta con su ayuda de uso y la comprobación diría «no está» siempre: daría por rotas **todas** las copias.

**Lo que `verify` no hace, a propósito:** restaurar sobre una base de pruebas para ver si el SQL se aplica. Sería la única comprobación completa de verdad, pero exige crear y borrar bases en el servidor de producción, y una herramienta de verificación que puede romper lo que verifica no vale. Se comprueba que el volcado esté entero, que es donde falla de verdad.

**Lo que se verifica se lee, no se ejecuta.** La primera versión cargaba el `app.conf` de la copia con `.` dentro de un subshell, creyendo que el subshell bastaba. Aísla las variables, sí, pero no los efectos: un `app.conf` con cualquier línea dentro se habría ejecutado **como root**, y ficheros, procesos y red no vuelven atrás al salir del subshell. Y este comando existe justamente para apuntarlo a un fichero del que no te fías: verificar una copia no puede ser más peligroso que no verificarla. `orbit restore` nunca lo ejecutó —copia el fichero con `install` y ya—, así que era un agujero nuevo, no uno heredado.

**El HOME del servicio (§5.1) no entra en la copia.** `shared/home` es caché: el gestor de paquetes que baja corepack y lo que cada librería deje en `~/.cache`. Nada de eso está sólo ahí —corepack lo vuelve a bajar y el build lo siembra de nuevo—, así que cae de lleno en la regla de §17.1. Copiarlo multiplicaría el tamaño de cada copia y de cada generación conservada por datos que caducan. Se borra después del `cp` y no con un `--exclude` porque el recuento de `ficheros_shared` tiene que salir de lo que de verdad va dentro: si contara la caché, `verify` echaría en falta ficheros que nunca se guardaron y daría por rotas todas las copias.

Cada copia se verifica **nada más crearla**, y antes de pasársela al `BACKUP_HOOK`: mandar a S3 una copia rota es peor que no mandarla, porque te crea la sensación de estar cubierto. `orbit backup verify` repite la comprobación sobre las que ya están guardadas.

Los campos `entorno=` y `ficheros_shared=` del manifiesto existen para esto: dejan que la verificación compare lo que la copia promete con lo que lleva dentro. Las copias anteriores no los traen, y entonces esas dos comprobaciones se saltan — que es distinto de darlas por rotas: si se rechazaran, una actualización de Orbit convertiría todo tu histórico en chatarra.

### 17.5 El servidor entero, y la línea que no se cruza

`orbit restore --all` levanta una máquina completa desde un directorio de copias: es el caso para el que existe todo esto —el servidor se ha perdido, hay un Ubuntu nuevo con Orbit instalado, y en algún sitio están los ficheros que el hook fue sacando—.

De cada app se coge **la copia más reciente**, leyendo el manifiesto y no el nombre del fichero: un nombre de app puede llevar guiones y puntos, así que deducirlo de `mi-web-20260806-030000.tar.gz` es adivinar. Restaurar una copia vieja encima de una nueva sería perder datos sin que nadie lo haya pedido.

Se enseña el plan entero antes de tocar nada y se pregunta **una vez**. Encadenar veinte confirmaciones a las tres de la mañana no es seguridad: es una carrera de clics en la que se acaba pulsando «sí» sin leer.

**La configuración global se restaura clave a clave, no fichero a fichero.** Es la decisión que quedaba pendiente y tiene una respuesta clara en cuanto se separan las dos cosas que `orbit.conf` mezcla:

| | Ejemplos | ¿Se restaura? |
|---|---|---|
| Describe **este** servidor | `APPS_DIR`, `DEPLOY_USER`, `PHP_VER`, `ACME_DIR` | **No.** Las escribió el instalador y las buenas son las de aquí |
| Es una **preferencia tuya** | `LETSENCRYPT_EMAIL`, `KEEP_RELEASES`, `WATCH_*`, `BACKUP_*`, `BUILD_RECOVERY` | **Sí.** Son las que quieres de vuelta |

Volcar el fichero entero es exactamente cómo se deja un servidor recién montado apuntando a rutas que no existen y a un usuario que no está creado. Y no restaurar nada obliga a reconfigurar a mano lo que ya habías decidido una vez. La lista blanca es la única de las tres opciones que hace lo correcto en los dos casos.

`notify.conf` sí se restaura entero, y no es una excepción caprichosa: ese fichero no describe al servidor, describe **a quién avisar y por dónde**. Es preferencia pura, y volver a sacar un token de Telegram es de las cosas más molestas de rehacer.

**El código no se despliega solo.** Traerlo puede tardar minutos, puede fallar y necesita GitHub conectado, así que no ocurre por sorpresa: o se pide con `--deploy`, o se imprimen los comandos ya escritos, uno por app. Es la misma regla que en el resto de Orbit: lo que tarda y puede fallar se pide, no se supone.

---

## 18. Los stacks que se añadieron en 2026, y lo que enseñaron

SvelteKit, Remix, Angular, Hugo, Eleventy y Go. Seis maneras distintas de contestar a la única pregunta que le importa a Orbit: **¿dónde deja el build lo que hay que servir, y hace falta un proceso vivo?**

Ninguno se dedujo de la documentación ni de la memoria. Se generó un proyecto con la herramienta oficial de cada uno, se compiló, y se miró la carpeta de salida. Tres de los cinco primeros resultaron ser distintos de lo que dice la mitad de internet, y el sexto —Go— sólo enseñó lo que enseñó porque se compilaron once proyectos y se rompieron a propósito ocho veces.

### 18.1 SvelteKit: manda el adaptador, y ya no vive donde vivía

SvelteKit no decide nada por sí mismo: lo decide el **adaptador**. `adapter-node` produce un servidor que se arranca con `node build`; `adapter-static` prerenderiza a `build/`. El mismo `package.json`, el mismo `vite build`, dos resultados incompatibles.

Lo que se aprendió generando el proyecto: **`sv create` ya no escribe `svelte.config.js`**. El adaptador se configura dentro de `vite.config.ts`, en las opciones del plugin `sveltekit()`. Una detección que leyera `svelte.config.js` —que es lo que dice casi toda la documentación de terceros— no encontraría nada en un proyecto nuevo.

Por eso se mira **el paquete instalado** y no el fichero de configuración: `@sveltejs/adapter-static` en las dependencias es una señal que no depende de dónde haya decidido el framework guardar su configuración este año.

Y una decisión de seguridad en el caso ambiguo. El scaffold por defecto trae `adapter-auto`, que sólo funciona en Vercel, Netlify y similares: en un VPS **falla siempre**. Ahí Orbit elige tratarlo como proceso, y no es arbitrario:

- Si acierta, funciona.
- Si se equivoca —era estático—, el proceso no arranca, el health check falla y hay rollback. Ruidoso y reversible.
- Al revés, tratar como estático algo que era un servidor, nginx publicaría el directorio `build/` con **el JavaScript del servidor dentro**. Es el mismo error que el `.php` servido como fichero (§15), y por eso la duda se resuelve siempre hacia el proceso.

Además, el fallo de `adapter-auto` tiene su propia firma en la capa de consejo (§14.5): el mensaje de SvelteKit dice que el entorno no está soportado, pero no cuál de los dos adaptadores instalar.

### 18.2 Remix es React Router desde 2025

`npx create-remix@latest` ya no crea un proyecto de Remix: imprime un aviso y te manda a `create-react-router`. Remix v2 se fusionó con React Router v7.

Así que se reconocen los dos, porque los proyectos de Remix v2 siguen existiendo y hay que seguir desplegándolos. La señal en ambos casos es el **paquete que sirve**, no el que se usa para escribir la aplicación:

- `@react-router/serve` → `react-router-serve ./build/server/index.js`
- `@remix-run/serve` → `remix-serve ./build/server/index.js`

Eso importa porque `react-router` a secas es también la librería de rutas de cualquier SPA de React. Detectar por `react-router` habría convertido en «proceso» a miles de aplicaciones que son ficheros estáticos. Con `ssr: false` en `react-router.config`, el proyecto es exactamente eso —una SPA prerenderizada en `build/client`— y Orbit lo trata como estático.

### 18.3 Angular: la ruta lleva dentro el nombre del proyecto

Angular es el único de los grandes cuyo build no va a un sitio fijo. La carpeta es `dist/<nombre-del-proyecto>`, el nombre está en `angular.json`, y **no tiene por qué coincidir con el del repositorio**.

Y desde Angular 17 hay una vuelta más: el builder `@angular/build:application` mete un subdirectorio `browser`, porque el mismo `dist/` puede llevar el servidor al lado. Compilando un Angular 20 recién generado:

```
dist/ng20/browser/index.html      ← lo que sirve nginx
dist/ng20/server/server.mjs       ← con SSR, lo que arranca systemd
```

El builder antiguo (`…:browser`) no mete esa subcarpeta, así que se distinguen por el nombre del builder que declara `angular.json`. Y si `angular.json` trae un `outputPath` explícito, manda ése.

Sin `jq` no se puede leer ese fichero, y ahí el nombre del proyecto se toma del directorio del repositorio: es lo que pone `ng new`, así que acierta en el caso normal y en el raro deja una carpeta que no existe, lo que se ve al instante en el aviso del despliegue.

### 18.4 Hugo: el primero que no se declara en un `package.json`

Todo lo demás que despliega Orbit se reconoce leyendo dependencias. Un sitio de Hugo se reconoce por su **forma**: un `hugo.toml` en la raíz, o un `config.toml` acompañado de `content/` y de `layouts/`, `archetypes/` o `themes/`.

Esa distinción no es paranoia: `config.toml` y `config.yaml` los usa medio mundo. Sin exigir la estructura, cualquier proyecto con un fichero de configuración en TOML se habría convertido en un sitio de Hugo.

Hugo va **antes** que la detección de Node en la cadena, y esto sí es un caso real: muchos sitios de Hugo llevan un `package.json` para Tailwind o PostCSS. Detectando Node primero, ese sitio se habría clasificado como «proyecto de JavaScript sin framework» y se habría compilado a un `dist/` que no existe. Detectando Hugo primero, su `package.json` se usa para lo que es: instalar las dependencias **antes** de `hugo --minify`.

**Orbit no instala Hugo**, y es deliberado. Es un binario de Go que el 99 % de los servidores no necesita, y meterlo en `install.sh` se lo cobraría a todo el mundo en tiempo y en disco. Lo que hace es detectarlo, generar el build correcto, y decir exactamente cómo instalarlo cuando falta: en el consejo del build fallido (§14.5) y en `orbit doctor`, que lo comprueba **sólo si alguna app lo usa**, igual que hace con php-fpm.

Jekyll queda fuera por el mismo motivo pero con más peso: necesita Ruby entero, no un binario.

### 18.5 El orden de la cadena es parte del diseño

Cuatro de los cinco frameworks nuevos se construyen con Vite. Si la rama de `vite` siguiera donde estaba, SvelteKit, Remix y una SPA de React Router se habrían clasificado como «SPA estática en `dist/`» —una carpeta que ninguno de los tres genera.

La regla, que ya estaba escrita en `CONTRIBUTING.md` y que estos cinco confirman: **los indicadores se solapan y gana el primero que coincide**, así que lo específico va antes que lo genérico. Un framework construido sobre Vite es más específico que Vite.

### 18.6 Go: el primero cuyo runtime no se instala

Go entró siguiendo el mismo método —once proyectos reales compilados y arrancados, no documentación— y resultó ser el stack que mejor encaja en el modelo de Orbit y el que más excepciones necesita.

Encaja bien por tres motivos medidos. **No hay runtime que instalar**: el artefacto es un binario autocontenido que arranca bajo `ProtectSystem=strict` y `ProtectHome=true` sin tocar nada fuera de su directorio. **La caché ya está donde tiene que estar**: el build corre con `sudo -u deploy -H`, así que `GOMODCACHE` y `GOCACHE` caen en `/home/deploy`, fuera de la release y compartidas entre apps — 19,8 s en frío contra 0,57 s en una release nueva, sin configurar nada. Y el **«lockfile congelado» es el comportamiento por defecto**: desde Go 1.16 `go build` usa `-mod=readonly`, así que toda la maquinaria de §14.6 sobra aquí.

Y necesita cuatro excepciones que ningún otro stack tiene.

**Un build de Go puede salir con 0 y no dejar binario.** `go build -o bin/app .` sobre un repositorio sin `package main` **sale con rc=0** y escribe un archivo `ar` de 2,8 KB en modo 0644. Sin comprobarlo, eso llega a producción: se mueve el symlink, systemd arranca, `Permission denied`, `Restart=always`, cuarenta segundos de health check y rollback — y el mensaje que ve quien despliega habla de permisos, que es exactamente la pista falsa que costó los 36 reinicios de §5.1. Por eso hay un paso 4c en el despliegue que comprueba `-x bin/app` con la release todavía sin activar. **Un éxito mudo es el peor modo de fallo que hay**, y es el motivo de que tampoco se use `go build ./...`, que también sale con 0 sin escribir nada.

**`go` casi nunca está en el `PATH`.** La instalación que recomienda go.dev descomprime en `/usr/local/go` y te deja a ti la línea del perfil, y quien la escribe la escribe en el suyo, no en el de `deploy`. Comprobado: con el `PATH` de login de `deploy` el build muere con `go: command not found` aunque Go esté instalado y funcionando. Se añade en `_build_run` y en `_exec_script`, al final para que un Go del sistema siga ganando, y **no** en `A_BUILD`, que es lo que se enseña en el asistente y lo que la gente edita a mano. `orbit doctor` mira los dos sitios por lo mismo: decir que falta Go en un servidor donde Go funciona es peor que no comprobarlo, porque manda a arreglar lo que no está roto.

**`KillSignal=SIGINT` se salta el apagado ordenado.** El patrón que trae la documentación de Go atrapa `SIGTERM`, muchas veces sólo `SIGTERM`. Con `SIGINT`, una app así se muere en seco con exit 130 y las peticiones en vuelo cortadas; con `SIGTERM`, cierra bien. La unidad usa ahora una señal u otra según el tipo.

**`-trimpath` no es cosmética.** Sin él, la ruta de *esta* release queda dentro del binario, y esa carpeta la borra la poda dentro de `KEEP_RELEASES` despliegues: cada traza de pánico apuntaría a un directorio que ya no existe. Con él, dos releases del mismo commit dan además el mismo md5.

**Y la detección exige dos cosas, no una: `go.mod` *y* algún paquete `main`.** Porque `hugo mod init` escribe un `go.mod` en la raíz del sitio para declarar el tema, así que un sitio de Hugo con módulos es indistinguible de un repositorio de Go si sólo se mira el nombre del fichero. Hugo ya va delante en la cadena; la comprobación del `main` es el segundo cierre, el que aguanta si alguien reordena. Y el `main` se busca **leyendo** los `.go`, no por el nombre `main.go`: el paquete `main` puede vivir en `servidor.go` y un `main.go` puede declarar cualquier otro paquete.

Go va **delante de `package.json`** por lo de §18.5: un servidor de Go que empaqueta su frontend con `go:embed` tiene los dos ficheros en la raíz, y la rama de Node vería el `vite` de las `devDependencies` y lo publicaría como estático apuntando a un `dist/` que nadie genera.

**Por qué Orbit no instala Go.** Es el precedente de Hugo (§18.4) con los números diez veces mayores. El paquete de Ubuntu es Go 1.22, fuera de soporte, y con él cualquier repositorio cuyo `go.mod` diga `go 1.25` —que es lo que escribe `go mod tidy` **solo**— dispara la descarga de un toolchain de 214 MB en el primer despliegue: daría la ilusión de soporte y el coste real de no tenerlo. El tarball oficial son 287 MB y, sobre todo, un ciclo de mantenimiento que Orbit tendría que adoptar para siempre. Y la contra-razón habitual no aplica: Node y PHP se instalan porque los necesita **el runtime**, y aquí el runtime no necesita nada. Se detecta, se dice cómo instalarlo cuando falla el build, y `orbit doctor` lo comprueba sólo si alguna app lo usa.

**Lo que deliberadamente no hace.** No compila el frontend cuando hay un `package.json` al lado: en Hugo ese acoplamiento está definido, en Go no —el `go:embed` necesita que la carpeta ya exista, y el script que la genera se llama como quiera—, así que eso lo dice `orbit.json`. No lee `go.work`. No usa `go install`, que escribe en `/home/deploy/go/bin`, fuera de la release, y rompería el rollback por symlink. No fuerza `CGO_ENABLED=0`, que revienta sqlite con `build constraints exclude all Go files`. No toca `GOTOOLCHAIN`, para que un repositorio que compila en el portátil compile en el servidor. Y no intenta el equivalente de §14.6 para el `go.sum`: en Go no existe la frontera `dependencies`/`devDependencies`, así que no hay forma de saber si la deriva llega a producción — se explica y se manda al repositorio, como en §14.5.

Una firma de error que merece mención aparte, porque es una trampa que se repite: el patrón obvio para «Go no está instalado», calcado del de Hugo, **da un falso positivo con `django: command not found`**, porque esa cadena contiene `go: command not found`. El patrón lleva ancla por delante.

## 18.7 Lo que sube un visitante no es código

Un agujero de ejecución remota, encontrado buscando cómo encajaría Laravel y reproducido con nginx y php-fpm de verdad antes de tocar nada.

`php artisan storage:link` crea `public/storage → ../storage/app/public`. Es decir: deja una carpeta **escribible por los visitantes** dentro del árbol que sirve nginx. Y el bloque que Orbit generaba era éste:

```nginx
location ~ \.php$ { … fastcgi_pass … }
```

Esa expresión regular casa con **cualquier** ruta acabada en `.php`, venga de donde venga el fichero. Subir un `avatar.php` por el formulario de subida de la aplicación y pedirlo devolvía 200 y lo ejecutaba:

```
$ curl .../storage/avatar.php
RCE: ejecutado como uid=1002(deploy)
```

`deploy` es el usuario dueño del código y del `.env` de **todas** las apps del servidor. No es «una app comprometida»: es el servidor entero.

Y no es un problema de Laravel. Es de cualquier aplicación PHP que guarde subidas bajo su docroot, que son muchas.

### La regla, que sale del modelo de releases

No es una lista de nombres de carpeta: es §4 otra vez. **La release es código inmutable que viene de git; `shared/` es lo que se escribe en tiempo de ejecución.** Lo que se alcanza a través de un enlace a `shared/` es dato, nunca código.

Eso Orbit lo sabe de verdad, así que se calcula: se recorre el docroot y se apunta cada entrada que sea un enlace y acabe dentro de `shared/`. Más `storage`, siempre, exista o no todavía — el vhost se regenera desde `orbit port` o `orbit restore`, cuando puede no haber release, y un agujero que aparece según cuándo se generó el fichero es peor que no taparlo.

A eso se le añaden los nombres de siempre (`uploads`, `upload`, `files`, `media`). Eso ya es una heurística y no un hecho, y está ahí por dos motivos: una app que escribe dentro de su propia release existe, y un `.php` legítimo dentro de `uploads/` no es un caso de uso — es exactamente el agujero. Principio 6.

### Por qué `^~` y por qué 404 en vez de servirlo

```nginx
location ^~ /storage/ {
    location ~* \.(?:php|phar|phtml|php[0-9]|cgi|pl|py|rb|sh|lua)$ { return 404; }
}
```

El `^~` no es decorativo: entre un prefijo marcado así y una expresión regular, nginx **deja de mirar las expresiones regulares**. Sin él, `location ~ \.php$` seguiría ganando y el bloque no serviría de nada.

Y dentro se devuelve 404 en vez de dejar que el fichero se sirva tal cual. Servirlo cambiaría una ejecución remota por una fuga del código fuente, que es mejor y sigue siendo un fallo — el mismo de §15. Las subidas legítimas se siguen sirviendo: la comprobación de que la foto sigue llegando está en la suite, porque cerrar el agujero rompiendo las fotos no es cerrarlo.

La prueba se escribió antes de creerse el arreglo: sin él, tres comprobaciones se ponen en rojo con un 200 y el fuente por delante.

### El PHP que el build no copia, y el dato que el despliegue borraba

Las dos salieron del mismo sitio: un proyecto real —un Astro con cuatro endpoints PHP— que en Orbit se veía perfecto y tenía **los cuatro formularios en 404**.

**El PHP vivía fuera de la carpeta compilada.** `astro build` —y vite, y eleventy— sólo copian a `dist/` lo que esté en `public/`. Una carpeta `api/` en la raíz del repositorio no se copia, y nginx sirve `dist/`. Medido antes de tocar nada:

```
A_TYPE=static  A_OUTDIR=dist  A_PHP=yes
docroot => .../current/dist
.php dentro del docroot: 0        .php en el repositorio: 12
/api/contact.php → 404
```

No es un caso raro: la documentación de despliegue de ese proyecto lo llama «el error nº 1» y lo resolvía **subiendo la carpeta aparte a mano**, con un segundo `rsync` que había que acordarse de ejecutar siempre y en el orden correcto.

Orbit no necesita que se suba nada aparte ni que se mueva el código: sirve esas carpetas **desde donde están**. Se buscan en la release —no en la configuración— las carpetas de primer nivel que traen `.php` y no están dentro de `A_OUTDIR`, y cada una recibe su bloque con `root <release>`. Se usa `root` y no `alias` a propósito: como el prefijo de la URL y el nombre de la carpeta coinciden, `SCRIPT_FILENAME` sale bien sin tocar nada de fastcgi, que es justo donde se equivoca todo el mundo. Y como se calcula de la release, una app que ya existía lo tiene en el siguiente despliegue sin volver a detectar nada.

**Y lo que la app escribía desaparecía en cada despliegue.** Ése es el precio de las releases inmutables, y es invisible para quien viene de un hosting clásico: allí el directorio es el mismo para siempre. En ese proyecto se perdían las credenciales de correo puestas a mano, los mensajes sin entregar —con currículums dentro—, las estadísticas y los logs. La web seguía funcionando, así que no se notaba hasta buscar un dato y no encontrarlo.

El repositorio lo declara en su `orbit.json`, y a partir de ahí es automático:

```json
{ "type": "static", "shared": ["api/config.local.php", "api/undelivered"] }
```

Cada entrada se crea en `shared/` la primera vez —con lo que traiga el repositorio, si trae algo, que sirve de semilla— y se enlaza en cada release. Un fichero como fichero, una carpeta como carpeta. La semilla es semilla y no plantilla: lo editado en producción no se vuelve a pisar. Las rutas que se salgan del directorio de la app se descartan una a una y se dice cuáles, porque acaban en un `rm -rf` y en el vhost.

**Y de eso sale gratis la parte de seguridad.** Lo que dentro de una carpeta publicada apunta a `shared/` es, por el modelo de §4, lo que la app escribe en tiempo de ejecución: dato, no código. Así que se niega, sin heurística ni lista de nombres. Antes de esto, medido en ese proyecto:

```
/api/undelivered/2026-01-01.eml → 200   ← el CV de un candidato
/api/telemetry-data/stats.json  → 200
```

Su documentación traía cuatro reglas de nginx escritas a mano para taparlo. Aquí salen solas de dónde está cada cosa, y son las mismas cuatro.

Lo que **no** se automatiza, y conviene decirlo: los ficheros de inclusión (`_lib.php`, `_smtp.php`) siguen siendo alcanzables. Denegarlos exigiría dar por hecho que el guion bajo significa «no es un endpoint», y eso es una convención, no un hecho: un proyecto que llame así a un endpoint se encontraría un 404 sin explicación. Bajo Orbit se **ejecutan**, y ejecutarlos no devuelve nada —comprobado, 0 bytes—, así que la diferencia con negarlos es cosmética. En Plesk sí importaba, porque allí podían acabar servidos como fuente.

### Lo que el `^~` apagaba sin querer, y el 404 que se comía la aplicación

Dos revisiones más tarde, el mismo bloque tenía dos fallos propios. Los dos salieron de montar Laravel encima, que es la clase de app que más lo pisa.

**El `^~` apaga también el snippet de seguridad.** `orbit-security.conf` deniega `.env`, `.log`, `.sql`, `.sqlite`, `.bak`, `.ini`, `.yaml`… con una `location` de expresión regular. Y un prefijo marcado `^~` hace que nginx deje de mirar **todas** las expresiones regulares, no sólo la de `.php`. O sea que el bloque que protege las carpetas de subidas dejaba fuera de servicio al snippet **justo donde el nombre del fichero lo elige un desconocido**:

```
/storage/robado.env    200   APP_KEY=base64:SECRETO   ← dentro del prefijo
/cualquiera.env        403                            ← fuera
```

La regla estaba exactamente del revés: se aplicaba donde el contenido lo pone el repositorio y se apagaba donde lo pone quien sube el fichero. Las dos negaciones se repiten ahora dentro del bloque. No es redundancia: es que ahí dentro el snippet no existe.

**Y los nombres heurísticos se comían rutas vivas.** `uploads`, `upload`, `files` y `media` se emitían **existieran o no** como carpeta, y el bloque no tenía `try_files`, así que nada caía al front controller. En una app cuyo tráfico entero pasa por `index.php` —Laravel— eso cierra cinco prefijos del sitio: `/media/{id}` o `/files/{uuid}/download` respondían **404 de nginx**, sin llegar nunca a la aplicación, y el síntoma no apunta a nginx por ningún lado. Ahora los nombres de la heurística sólo se emiten si la carpeta existe de verdad —`storage` sigue siendo incondicional, porque eso Orbit sí lo sabe— y el bloque termina devolviendo el control al front controller.

**Un tercero, más callado: el nombre del enlace entra en el vhost.** Los nombres descubiertos salen del repositorio, y acaban interpolados dentro de `location ^~ /$p/ {`. Un enlace llamado `mal;dentro` escribe una directiva que nginx no puede leer — y como el vhost se enlaza en `sites-enabled` **antes** del `nginx -t`, a partir de ahí falla la configuración del servidor entero: no se despliega ninguna otra app ni se renueva ningún certificado. Se filtran a `[A-Za-z0-9._-]`.

## 18.8 Deno y Bun: el stack que no se detecta se publica como código fuente

Deno y Bun entraron por la puerta de atrás. No se buscaba soportarlos: se comprobó qué hacía Orbit con ellos, y lo que hacía era **publicar el repositorio entero como sitio estático**. Medido contra un nginx de verdad, antes de tocar nada:

```
$ curl -s http://.../main.ts
const port = Number(Deno.env.get("PORT") ?? 8000);
Deno.serve({ port }, () => new Response("hola"));
```

200, y el servidor entero por delante. El `.env` iba con él. No es una detección incompleta: es §15 y §18.7 otra vez, y por el mismo mecanismo que las dos.

**El fallo es estructural, y merece decirlo en general: en Orbit, la rama que no reconoce nada acaba en `A_TYPE=static` con `A_OUTDIR="."`, o sea nginx sirviendo la raíz del repositorio.** Para un sitio que es HTML eso es exactamente lo correcto, y es la razón de que esté ahí. Para cualquier cosa que no lo sea, el modo de fallo por defecto es enseñar el código. Deno y Bun caían ahí porque **no compilan a una carpeta**: lo que se despliega *es* el fuente. Un repositorio de Deno no tiene ningún fichero que Orbit reconociera, y uno de Bun tenía `package.json` sin ninguna dependencia de la lista de frameworks.

De ahí salen las dos reglas de esta sección. **Ante la duda, con proceso y no estático**: equivocarse hacia «app con proceso» da un despliegue que falla en voz alta y con rollback; equivocarse hacia «estático» da un despliegue que sale bien y publica el código. Y **nunca se cae al `else` en silencio**: si se reconoce Deno pero no se encuentra el fichero de arranque, se avisa y se deja el tipo puesto, en vez de dejar que la app resbale hasta la rama estática.

### Los tres sitios donde Deno no se parece a nada de lo que ya había

**1 · Las dependencias no viven en el repositorio.** No hay `node_modules`: `deno install` lo deja todo en `DENO_DIR`, que por defecto es `$HOME/.cache/deno` — comprobado con `deno info`. Y como el `HOME` del build (`sudo -u deploy -H`) no es el `HOME` de la unidad (§5.1), el build salía bien y el servicio se estrellaba al arrancar. Con la misma caché apuntada a otro sitio:

```
error: JSR package manifest for '@std/http' failed to load.
       Specifier not found in cache: "https://jsr.io/@std/http/meta.json", --cached-only is specified.
```

Es el fallo de corepack en otro sitio, y se arregla igual: un `DENO_DIR` fijo bajo `shared/`, escrito en la unidad y exportado en el build, para que los dos miren a la misma carpeta. En `shared/` y no en la release porque se llena una vez y tiene que sobrevivir al despliegue siguiente.

`--cached-only` en el arranque es la otra mitad: sin él, un fallo de caché no se ve — se convierte en una descarga silenciosa en cada reinicio, dentro de una unidad que no debería estar hablando con internet para arrancar.

Bun no necesita nada de esto: instala en `node_modules`, dentro de la release, que es donde Orbit ya sabe mirar.

**2 · `deno task` no sirve como orden de arranque.** La tarea del repositorio trae el puerto que le puso su autor, y no hay forma de pasarle otro. Medido:

```
$ deno task start -- --port 3999
Task start deno serve main.ts '--' '--port' '3999'
deno serve: Listening on http://0.0.0.0:8000/
```

Los argumentos entran **detrás** del fichero y `deno serve` los ignora. Por eso Orbit no arranca con `deno task`, sino que compone la orden él: `deno serve --port ${PORT} --host 127.0.0.1 <fichero>`. Las dos banderas hacen falta y por separado — con `PORT=3999` en el entorno, `deno serve` sigue escuchando en `0.0.0.0:8000`, así que además de no coger el puerto se asomaba a internet saltándose el proxy. Si el fichero llama a `Deno.serve` él mismo, entonces sí lee `PORT` la aplicación y se arranca con `deno run`.

**3 · Los permisos son de la aplicación, no del servidor.** Deno es el único stack donde el runtime tiene su propio cajón de arena, y solaparlo con el de systemd sería adivinar. Orbit da el mínimo con el que funciona una web normal —`--allow-net --allow-env --allow-read=.`— y lo deja **a la vista en `A_START`** para que se edite; si el repositorio declara `permissions` en su `deno.json`, gana el repositorio y Orbit sólo pasa `-P`. Lo que no se concede —`write`, `run`, `ffi`, `sys`— es justo lo que systemd no puede negar dentro del directorio de la app, porque `ReadWritePaths` lo permite adrede. Los dos cajones se complementan; no se repiten.

`--allow-net` y `--allow-env` van sin acotar a propósito: acotar el primero al puerto rompe en cuanto `orbit port` lo cambia y deja fuera la base de datos y cualquier API externa, y acotar el segundo deja a la app sin su propio `.env`.

### Bun aparece de dos maneras, y confundirlas es el error

Bun puede ser el **gestor de paquetes** de un proyecto que sigue siendo de Node —un Next instalado con bun—, y entonces sólo cambia `A_PKG`; o el **runtime**, y entonces el proceso que arranca systemd es `bun`. La pregunta sólo se hace cuando ningún framework ha coincidido: si el repositorio declara `next`, manda Next, se instale con lo que se instale. Es §18.5 sin excepciones.

La señal fuerte es que el propio repositorio diga que arranca con bun. Las de apoyo —`@types/bun`, `bunfig.toml`— existen porque un servidor de `Bun.serve` puede no traer script de arranque, y sin ellas ese repositorio era exactamente el que caía en el `else` y se publicaba entero.

Hono es el caso que obliga a mirar el arranque y no la dependencia: corre en Node y en Bun con el mismo `package.json`, y quien decide es el `"start"`.

Un `deno.json` tampoco basta por sí solo: mucha gente lo lleva sólo para `deno fmt` en un proyecto que es de Node. Se pide, como con Hugo (§18.4), la forma de un proyecto que se ejecuta: o `deno.lock` —que sólo escribe `deno install`— o un `deno.json` que declare `tasks`, `imports`, `importMap` o `workspace`. Y **por delante de las dos**, un framework de JavaScript en el `package.json` descarta Deno: Deno 2 resuelve dependencias `npm:`, así que un Next instalado con `deno install` tiene `deno.json` **y** `deno.lock` y sigue siendo Next.

### `bun install --frozen-lockfile` y `deno install --frozen` fallan los dos

Comprobado en los dos, cambiando el manifiesto sin regenerar el lockfile:

```
$ bun install --frozen-lockfile
error: lockfile had changes, but lockfile is frozen
$ deno install --frozen
(sale con 1 y enseña el diff de lo que no cuadra)
```

Así que en los dos se exige, y la regla de §14.6 —lo que se despliega es lo que dice el lockfile— sale gratis. En Deno se añade además un `deno check <fichero>` al build: un error de tipos que reventaría el servicio se ve en el build, con rollback, y no en el bucle de `Restart=always`.

### Por qué `orbit doctor` pregunta como `deploy` y no como root

Los instaladores de bun y de deno dejan el binario en el `HOME` de quien los ejecuta. Quien los ejecuta suele ser root, y luego enlaza el binario a `/usr/local/bin`. El resultado, medido en esta misma máquina:

```
# como root
$ command -v bunx  →  /root/.bun/bin/bunx   ✔  1.3.11
# como cualquier otro
$ command -v bunx  →  (nada)
```

`/root` es modo 700, así que el enlace apunta a un sitio que sólo root atraviesa. `command -v` desde root dice que sí, y **todos los builds mueren con `command not found`**. Un diagnóstico en verde con todo roto es peor que no comprobar nada, así que la pregunta se hace con `sudo -u "$DEPLOY_USER" -H bash -lc`, que es exactamente como corre el build. Y si la herramienta existe para root pero no para `deploy`, el mensaje lo dice tal cual, porque es un fallo distinto y se arregla distinto.

**Orbit no los instala**, por el precedente de Hugo (§18.4) y de Go (§18.6): son runtimes que se instalan con un script propio y se actualizan solos, y meterlos en `install.sh` sería adoptar su ciclo de vida para siempre. Se detecta, se dice cómo instalarlos, y `doctor` lo comprueba sólo si alguna app los usa.

Y hay una segunda mitad, que sólo apareció al revisar el cambio con saña: **el build y el servicio no ven lo mismo**. El build va por `bash -lc`, que lee los perfiles de login; la unidad de systemd lleva un `PATH` fijo y ni siquiera el `HOME` del usuario. Una herramienta instalada en `$HOME/.bun/bin` con el `PATH` exportado desde el `.profile` compila perfectamente y **luego el servicio no arranca**. Así que `doctor` pregunta dos veces —como el usuario de despliegue y con el `PATH` de la unidad— y dice cuál de las dos falla, porque se arreglan distinto.

### Lo que enseñó revisar este cambio a conciencia

El soporte entró con 27 comprobaciones y las pruebas en verde, y una revisión adversarial encontró **cuatro caminos más** por los que un repositorio acababa en `static` con `A_OUTDIR="."`. Merece la pena enumerarlos, porque el patrón se repite y el siguiente stack lo va a repetir otra vez:

- **`bun.lock` en el `.gitignore`.** `A_PKG` sólo vale `bun` si el lockfile está *en el repositorio*, y la comprobación empezaba exigiendo eso — así que un `package.json` que decía literalmente `"start": "bun run server.ts"` no se llegaba ni a mirar. La señal más fuerte de todas, tapada por una puerta puesta antes. **La señal fuerte va primero.**
- **`bunfig.toml` sin `package.json`.** La comprobación de Bun sólo se llamaba desde dentro de la rama que exige `package.json`, así que su propio `|| [[ -f bunfig.toml ]]` era código muerto.
- **Deno importando por URL o `jsr:` a pelo**, sin `deno.json` ni `deno.lock`: nada que reconocer. Se cierra con el criterio de Hugo — la forma de un proyecto que se ejecuta: un fichero de entrada de los de siempre que use la API de `Deno.`
- **Un servidor de Node sin framework**: el `http` de la biblioteca estándar y nada más. Tiene `start` y no tiene `build`, que es exactamente lo contrario de un sitio compilado, y ahora eso basta para clasificarlo como app con proceso.

Y cuando de verdad no se reconoce nada, la rama de repuesto **lo dice en voz alta** en vez de servir la raíz del repositorio en silencio.

Otras cuatro correcciones de la misma revisión, todas medidas:

- **`deno install --frozen` sin lockfile sale con 1** y vuelca el diff del lockfile que acaba de calcular, así que ese repositorio no se podría desplegar nunca. `--frozen` sólo si hay `deno.lock`, que es la misma regla que sigue la rama de Node.
- **Lo que decide entre `deno run` y `deno serve` es el `export default`, no el literal `Deno.serve`.** Fresh, Oak y cualquier cosa que llame a `app.listen()` no lo escriben. Y `deno serve` sobre un módulo sin default falla **saliendo con 0** — systemd lo ve como una salida limpia, lo reinicia, y lo único que lo caza es el health check 40 s después. Es la misma familia de «éxito mudo» que el build de Go que no deja binario (§18.6).
- **`jq` no sabe leer JSONC**, que es el motivo de existir de `deno.jsonc`. Sobre uno con comentarios sale con 5 y no imprime nada, así que en una máquina con `jq` —la normal, `install.sh` lo instala— un repositorio con `deno.jsonc` se quedaba sin fichero de arranque aunque su tarea lo dijera con todas las letras. Se le quitan los comentarios antes de pasárselo, y el respaldo entiende también la forma de tarea con objeto.
- **La tarea del repositorio manda sobre los nombres de siempre.** Un `main.ts` que es una herramienta de línea de órdenes y un `"start": "deno run -A src/server.ts"` arrancaban el fichero equivocado. Quien mejor sabe cuál es el servidor es quien escribió el repositorio.

Veintiuna comprobaciones nuevas, de las que diecisiete se ponen en rojo contra la versión anterior.

## 18.9 Laravel: el orden importa más que los comandos

Laravel es el stack donde menos código nuevo hace falta y más decisiones hay que tomar. No trae proceso —lo sirve php-fpm, como cualquier app PHP—, no necesita unidad de systemd, no ocupa puerto y no cambia `needs_svc`. Lo que trae es un **orden**: cinco cosas que hay que hacer en su momento exacto, y cuatro de ellas fallan en silencio si se hacen en otro.

Todo lo de esta sección está medido contra un `composer create-project laravel/laravel` real (Laravel 13, PHP 8.4) servido por nginx y php-fpm, no leído en la documentación.

### El punto de partida: Orbit clasificaba mal un Laravel de verdad

`detect_stack` sobre el esqueleto recién creado, sin tocar nada:

```
A_TYPE=static  A_PKG=pnpm  A_OUTDIR=dist  A_SPA=yes  A_DOCROOT=
```

El motivo es §18.5 otra vez: **la rama de `package.json` iba antes que la de `composer.json`**, y el esqueleto de Laravel trae un `package.json` con `vite` en `devDependencies` y un script `build`. En un servidor eso pone el `root` de nginx en `<release>/dist`, que Laravel no genera nunca, con fallback de SPA a un `index.html` que tampoco existe: **la web entera en 404**. No es una degradación, es el sitio caído.

Por eso `_is_laravel` va delante de `package.json`, junto a Hugo y a Go.

### La detección pide tres señales, y ninguna sobra

`artisan` + `laravel/framework` en los `require` + `bootstrap/app.php`. Cada una por separado se equivoca en un proyecto real: Symfony pone su consola en `bin/console` y WordPress no tiene ninguna, pero **Lumen también trae `artisan`**; `laravel/framework` lo declara en `require-dev` cualquier paquete que se pruebe contra Laravel; y `bootstrap/app.php` es el punto de entrada de verdad, que una librería no tiene. Comprobado contra ocho proyectos —Laravel completo, Laravel sin `package.json`, Symfony, WordPress, PHP a secas, Lumen, un paquete con `laravel/framework` sólo en `require-dev` y Statamic— con `jq` y por el camino de respaldo sin `jq`.

`A_TYPE='laravel'` es un **tipo** y no una capacidad como `A_PHP`, y aquí sí se cumple el criterio de §15.2: no es «además hay que ejecutar PHP», es *cómo se sirve el grueso del sitio*. `A_DOCROOT` es `public` fijo y no buscado entre candidatos: en Laravel siempre lo es, y buscar sólo puede acertar por casualidad.

Un CMS construido sobre Laravel —Statamic, October, Winter— se detecta como Laravel y **se avisa**: se administra desde su propio panel y escribe dentro del repositorio, así que el principio 1 lo deja fuera igual que a WordPress. No se bloquea; se dice lo que va a pasar.

### `shared/storage` no se creaba nunca, y las subidas se perdían en silencio

El mecanismo existía a medias: la línea que sustituye `storage/` por el compartido sólo se activaba **si `shared/storage` ya existía**, y Orbit no lo creaba jamás. Así que en la práctica no se activaba nunca: `storage/` se quedaba dentro de la release y todo lo que la app escribiera —logs, sesiones, subidas de usuarios— desaparecía en el despliegue siguiente. Sin un mensaje.

Y crearlo a mano era **peor**. Un `mkdir shared/storage` vacío deja esto:

```
GET /  →  HTTP 500
production.ERROR: Please provide a valid cache path.
```

Con `APP_DEBUG=false`, el visitante ve un 500 con el cuerpo vacío. La pantalla en blanco clásica. Laravel crea `logs/` sola pero no `framework/views/`.

El arreglo sale del propio repositorio: cada carpeta escribible de Laravel viaja en git **con su `.gitignore` rastreado**, así que el esqueleto está ahí y lo único que faltaba era copiarlo. Se siembra con `rsync -a --ignore-existing` antes de sustituir la carpeta — `--ignore-existing` porque lo que ya hay son las subidas y los logs de la gente, y eso no se pisa nunca. La guarda `! -L` hace el paso idempotente.

Diez comprobaciones nuevas en `deploy_test` lo fijan; siete se ponen en rojo sin el arreglo.

### El paso 4d, y por qué no puede ir dentro del build

`_build_run` lanza el build así:

```bash
sudo -u deploy -H bash -lc "cd '$rel' && set -a; [ -f .env ] && . ./.env; set +a; …"
```

Ese `set -a; . ./.env` **exporta** las variables al entorno. Y Dotenv, que es quien lee el `.env` dentro de Laravel, usa `createImmutable`: **no pisa lo que ya está en el entorno**. Así que dentro del build gana la versión que ha interpretado bash, y en tiempo de petición —php-fpm, entorno limpio— gana la que interpreta Dotenv. Con `APP_NAME='mi$app'` en el `.env`, medido:

```
entorno limpio, como php-fpm ....... mi$app     ← Dotenv
dentro del shell del build ......... mi         ← bash expandió $app
```

Y `config:cache` **congela** lo que vea. Una contraseña con un `$` dentro queda cacheada truncada, la app no conecta con la base de datos, y el síntoma es un «authentication failed» que no lleva a ninguna parte. Peor todavía: **sin** `config:cache` la app funcionaría, porque leería el `.env` por Dotenv. Es un fallo que sólo aparece al hacer las cosas bien.

Por eso los `artisan` van en un paso aparte, `_laravel_post_build`, con el entorno tal y como lo verá php-fpm. En orden:

1. **`APP_KEY`.** Sin ella la web devuelve 500 en **todas** las peticiones, y el build pasa igualmente: `config:cache` y `route:cache` salen con 0. Y hay un detalle que cuesta un rato: `key:generate` **sustituye** la línea `APP_KEY=`, no la crea, así que sobre el `.env` vacío que crea Orbit falla con «No APP_KEY variable was found in the .env file». Se añade la línea y se genera **sólo si falta**: regenerarla en cada despliegue invalidaría las sesiones y todo lo que la app haya cifrado con la anterior, que es una pérdida de datos silenciosa.
2. **`storage:link --force`.** El enlace que crea es **absoluto** y lleva dentro el nombre de esta release, así que hay que rehacerlo en cada despliegue. `--relative` no vale: pide `symfony/filesystem`, que no es dependencia de producción de `laravel/framework` y un `--no-dev` no la instala.
3. **`config:cache` y `route:cache`.** Escriben en `bootstrap/cache/`, que es **por release y tiene que serlo**: así vuelven atrás con el symlink en un rollback.
4. Los avisos.

**`view:cache` está deliberadamente fuera**, y con medición: escribe en `storage/`, que es compartido, y hace un `view:clear` primero — o sea que la release nueva **borra las vistas compiladas de la anterior** (21 ficheros de r1 antes, 0 después). Blade las compila sola en la primera petición, así que lo único que se ahorraría es esa primera compilación, y lo que costaría es que una release escriba dentro del estado de otra. Eso rompe la invariante de la que vive todo el modelo.

Por lo mismo, `vendor/`, `bootstrap/cache/` y `public/build/` **no** pueden ir en `shared/`: son artefactos de una release concreta, y compartirlos convierte cualquier rollback en código viejo con las dependencias y las rutas del nuevo.

### Los cuatro avisos, todos de cosas que dejan el build en verde

- **`APP_DEBUG=true`** enseña la traza completa con rutas y variables. El gemelo exacto del aviso `DEBUG=True` de Django.
- **`DB_CONNECTION=sqlite`**: `install.sh` instala `php-pgsql` y `php-mysql`, no `php-sqlite3`. El error que sale es `could not find driver`, que no dice qué instalar.
- **Una cola sin nadie que la ejecute.** Medido: con `QUEUE_CONNECTION=database` y ningún worker, un trabajo encolado se queda en la tabla, y no hay error, ni log, ni pista. Los correos no salen y la web responde 200 a todo.
- **El PHP del build contra el del pool.** Si el `composer install` corre con un `php` más nuevo que el de `php${PHP_VER}-fpm`, se instala bien y el visitante ve un 500 con «Composer detected issues in your platform» — es `vendor/composer/platform_check.php`, que compara la versión en tiempo de petición. **Ninguna comprobación de build lo detecta.** Reproducido aquí: un `vendor/` resuelto con PHP 8.4 muere bajo PHP 8.3.

Ese último es el que se va a encontrar cualquiera hoy: Ubuntu 24.04 trae PHP 8.3 e `install.sh` fija `PHP_VER=8.3`, y un Laravel reciente arrastra un Symfony que exige ≥ 8.4.1. Orbit no cambia la versión de PHP del servidor de nadie: lo detecta y lo dice con todas las letras, en el aviso del despliegue y en la firma de `_build_advise`.

### Las colas: por qué no hay un worker residente, y qué hay en su lugar

El argumento fácil sería el principio 2, y sería hacer trampa: esa regla es sobre Orbit, no sobre las apps, que ya tienen sus unidades con `Restart=always`. Los motivos de verdad son otros tres.

**Una app Laravel no tiene hoy ninguna unidad, y el modelo lo asume en cuatro sitios.** `needs_svc` decide si hay `render_systemd`, si hay mantenimiento automático durante el despliegue, si hay `health_wait` y **si hay rollback automático**. Una cola es un servicio sin puerto: `health_wait` no significa nada para ella. Meterla obliga a partir en dos lo que hoy es una sola pregunta, e inventar un segundo criterio de «está viva» para un tipo de app que no tiene el primero. Eso no es añadir una unidad: es un segundo modelo de servicio dentro del primero.

**Un worker residente convierte el despliegue atómico en un despliegue a medias.** `queue:work` carga el código una vez y no lo suelta: tras mover el symlink, php-fpm sirve la release nueva y el worker sigue con la vieja. La respuesta de Laravel es `queue:restart`, que **no reinicia nada** — escribe una señal en la caché y cada worker sale cuando la ve. O sea que la corrección del despliegue pasaría a depender de que el `CACHE_STORE` esté bien configurado. Estado oculto y coordinación entre procesos: contra el principio 5 y contra el 4.

**Y nada de lo que Orbit ya tiene sabría mirar esa unidad**: `orbit status` deriva el estado del tipo, `orbit watch` reinicia lo que no responde **en su puerto**, `orbit top` mide por cgroup de app. Una cola parada y sin vigilancia es peor que no tener cola, porque parece que funciona.

La forma que sí encaja no es un worker residente sino **un temporizador**, que es literalmente el patrón que el principio 2 bendice, y es lo que hay: `orbit queue enable <app>` lanzando `queue:work --stop-when-empty --sleep=0` una vez por ciclo. Sin proceso residente no hay código viejo pegado —cada ciclo arranca desde `current/`—, si un ciclo revienta el siguiente empieza limpio, y se lee con `cat`. Medido: un ciclo con la cola vacía tarda 0,19 s. Lo que se paga es latencia, hasta un ciclo entero. Para correos e informes es irrelevante; para una cola que tiene que responder en segundos, no vale, y ésa es la conversación que hay que tener **antes** de encenderlo — por eso la dice el propio comando al activarlo, y no sólo este documento.

### `orbit queue`: lo que costó escribirlo, que no fue llamar a artisan

La orden es de una línea. Lo que tiene contenido son las cuatro decisiones de alrededor, y tres de ellas salieron de buscarle agujeros al cambio antes de que existiera un servidor donde probarlo.

**El ciclo tiene que terminar, y el límite se deriva del intervalo.** `--stop-when-empty` no basta: una cola que recibe trabajos más rápido de lo que los ejecuta nunca se vacía, y ese `queue:work` se convierte en el worker residente que este diseño evita, por el camino largo y sin que nadie lo haya decidido. Así que va con `--max-time`, y su valor **no** es un ajuste aparte sino `QUEUE_EVERY × 60 − 5`: si un ciclo pudiera durar más que su propio periodo, el siguiente arrancaría con el anterior todavía dentro, y las dos propiedades que compra el diseño —un solo worker por cola y un ciclo que empieza limpio— dejarían de ser ciertas. Un `orbit.conf` editado a mano con un cero daría un `--max-time` negativo, así que hay suelo.

**Y el límite es de la pasada, no de cada app.** Éste es el agujero que encontró la revisión: con tres apps ocupadas, tres ciclos de 55 s seguidos son 165 s dentro de una ventana de 60. La pasada se solaparía con la siguiente y, peor, systemd la mataría al llegar a su `TimeoutStartSec` — o sea **una unidad en rojo cada minuto en un servidor que funciona**, que es exactamente el ruido que vuelve inútil la señal de la que vive el resto de esta sección. La pasada reparte un presupuesto: la primera app se lleva el ciclo entero y cada una descuenta lo que tardó. La que se quede sin tiempo no pierde nada — sus trabajos siguen ahí y la pasada siguiente empieza por ella con el presupuesto entero.

**`current` se resuelve una vez, al principio del ciclo.** Con el `cd` sobre el symlink a secas, un despliegue a mitad de ciclo deja al worker abriendo unos ficheros de la release vieja y otros de la nueva, que es peor que cualquiera de las dos. La promesa es «cada ciclo, una release», y una ruta que puede cambiar bajo los pies no la sostiene.

**Lo ejecuta el usuario de la app** (`as_app`, §5.3) y no el de despliegue. Es el mismo descuido que costó los cuatro fallos de Laravel, Go y el `.env`: cuando cambias quién ejecuta algo, la pregunta no es «¿he cambiado la función?» sino quién más escribía en lo que ahora es de otro. Una cola ejecutada como `deploy` deja los logs y las cachés de Laravel con el dueño equivocado, y la petición siguiente de php-fpm no puede escribirlos.

**Un ciclo que falla deja la unidad en rojo, y eso es todo el aviso que hay.** Es deliberado, por lo mismo que en el autodespliegue (§4): una cola sin procesar no da ningún error —la web contesta 200, los correos simplemente no salen— así que el rojo es la única señal, `orbit doctor` la cuenta sin apagarla, y el ciclo siguiente que salga bien la pone en verde sola. La notificación va por `_watch_mark`, que avisa de la **transición** y no del estado: con el temporizador pasando cada minuto y una avería que dura horas, avisar del estado serían sesenta mensajes iguales por hora. Y saltarse un ciclo —app en mantenimiento, sin release, cerrojo tomado— **no** es un fallo y no pone nada en rojo: si lo hiciera, la alarma que importa quedaría enterrada bajo el ruido de los despliegues.

Lo que queda fuera, dicho aquí para que nadie lo descubra mirando: se procesa la cola **por defecto** de la conexión por defecto. Las colas con nombre (`high`, `emails`) necesitan su propio temporizador llamando a `orbit exec`, porque el nombre no se puede leer del `.env` — vive en `config/queue.php`, que es código.

### Lo que ya estaba bien, y una arista conocida

El `_body_php` de hoy, con `A_DOCROOT=public`, genera exactamente lo que Laravel recomienda: `try_files $uri $uri/ /index.php?$query_string`, `index index.php`, el `.env` un nivel por encima del docroot y además denegado por `orbit-security.conf`, y el `try_files $fastcgi_script_name =404` del snippet del sistema cerrando el `cgi.fix_pathinfo`. No hace falta un `_body_laravel` aparte. Y lo que sí hacía falta —que un `.php` subido a `public/storage` no se ejecute— no es de Laravel: es de cualquier app PHP con subidas bajo su docroot, y está en §18.7, que salió precisamente de mirar cómo encajaría Laravel.

### El despliegue no existía para una app PHP hasta que caducaba una caché

Éste es el hallazgo más caro de toda la sección, y no lo encontró ninguna revisión: salió de romper un Laravel de verdad a propósito para probar el health check, y descubrir que el health check decía que todo iba bien.

**php-fpm guarda en su caché de `realpath` a qué release apunta `current`.** El TTL por defecto son 120 segundos. Mover el symlink no cambia nada hasta que esa entrada caduca. Medido, activando una release cuyo `public/index.php` lanza una excepción:

```
recién activada la release rota .. 200, y el cuerpo es la portada VIEJA
tras recargar php-fpm ............ 500, que es la release nueva
```

Las consecuencias, por orden de gravedad:

1. **Durante hasta dos minutos, los visitantes reciben el código anterior.** El despliegue dice «activada» y no lo está.
2. **Mezclado.** nginx sí resuelve el symlink en cada petición, así que sirve los estáticos de la release nueva mientras php-fpm ejecuta el HTML de la vieja: la web sale con el CSS nuevo y el marcado antiguo. Es la avería clásica de los despliegues por symlink con PHP, y aquí estaba entera.
3. **Cualquier comprobación de salud es inútil**, porque mide la release que ya estaba.

Se arregla con un `systemctl reload php${PHP_VER}-fpm` justo después de mover el symlink. `reload` es `SIGUSR2`: los procesos terminan la petición que tengan entre manos antes de renovarse, así que no se cae ninguna. Alcanza a todas las apps PHP del servidor porque el pool es uno solo, y eso es aceptable precisamente porque es elegante. Y **también al volver atrás**: sin eso, el rollback devuelve el symlink a su sitio y la web se queda en 500, porque la caché apunta ya a la release rota. Comprobado en los dos sentidos.

Vale para `laravel`, para `php` y para una estática con `A_PHP=yes`: es la misma caché.

### El health check de una app sin unidad

Con lo anterior arreglado, la comprobación puede existir. Las apps con proceso se miran por su puerto interno (`health_wait`); una app PHP no tiene ninguno, así que la única forma de saber si está viva es **pedirle la portada a nginx como haría un visitante**.

Va por el puerto 80 con `Host:` y `X-Forwarded-Proto: https` — esa cabecera es la que hace que el vhost sirva en vez de redirigir cuando la app tiene certificado (§9.2), así que no hace falta TLS, ni saber si hay certificado, ni resolver el dominio.

Se acepta **cualquier cosa que no sea un 5xx**. Un 404 en la portada puede ser correcto —una API sin ruta raíz— y no es asunto de Orbit decidirlo; lo que no vale es que el servidor diga que ha reventado, ni que no conteste nadie.

Vale para los tres tipos que sirve php-fpm, y conviene ser exacto sobre lo que cubre en cada uno, porque no es lo mismo:

| | quién sirve la portada | qué se coge |
|---|---|---|
| `laravel`, `php` | php-fpm | un error de sintaxis, una extensión que falta, un proveedor que no arranca: todo eso sale como 5xx |
| `static` con `A_PHP=yes` | nginx, desde disco (`index index.html`) | que el sitio siga en pie, y nada más — **el PHP ni se toca** |

Esa última fila es la parte incómoda y está medida: en una estática con un `contacto.php` dentro, la portada no pasa por PHP, así que romper el formulario no lo detecta nadie. Es menos de lo que parece, y es lo único honesto que se puede hacer sin inventarse qué URL de cada proyecto significa «estoy sano». Lo que sí aporta ahí es el otro medio arreglo: la recarga de php-fpm, que en ese tipo hacía la misma falta que en los otros dos.

Y es la única parte del despliegue que comprueba algo **con producción ya tocada**, porque no hay alternativa: la release no es alcanzable hasta que el symlink se mueve y nginx recarga. Por eso lo que sigue a un fallo es exactamente lo del paso 6: devolver el symlink a la release anterior, regenerar el vhost y recargar php-fpm.

Se salta si la app está en mantenimiento —el de Orbit o el `php artisan down` de Laravel—, porque ahí el 503 es la respuesta correcta y no un fallo; si no, no se podría desplegar el arreglo de una web caída a propósito.

Un detalle que costó un rato y que merece quedarse escrito: **`curl` escribe `000` por `-w` cuando ni siquiera conecta, y además sale con 7.** Un `|| printf '000'` encadenado detrás daba `000000`, que no casa con ningún patrón de fallo — así que un servidor que no contestaba se daba por sano. Lo encontró el despliegue de prueba con nginx en otro puerto; las pruebas unitarias no, porque siempre tenían un servidor vivo al otro lado. La rama de «no conecta» hay que ejercitarla a propósito.

### Lo que enseñaron dos revisiones adversariales de este cambio

Igual que con Deno y Bun, Laravel entró con las pruebas en verde y dos revisiones encontraron cosas que las pruebas no podían ver. Tres merecen quedarse escritas porque no son de Laravel:

**`_env_read` interpretaba el `.env` con `source`.** Un `.env` no es un script de bash, y tratarlo como tal costaba dos fallos a la vez. El primero: **ejecutaba lo que hubiera dentro, como root**. Una línea `APP_DEBUG=$(id -un > /tmp/x)` en el `.env` de una app se ejecutaba en el siguiente despliegue con todos los privilegios — y el `.env` lo escribe el usuario de despliegue, que es también el de php-fpm, así que cualquier ejecución de código en cualquier app PHP del servidor podía dejar ahí una línea y esperar. Con autodespliegue, ese despliegue lo lanza un temporizador sin nadie delante. El sumidero era antiguo, pero Laravel añadió cuatro llamadas en la ruta automática.

El segundo es más silencioso y probablemente más frecuente: **un carácter normal de una contraseña rompía todo lo que iba detrás**. Con `DB_PASSWORD=aB3(x9Z!`, bash aborta el `source` en el paréntesis y todas las claves siguientes se leen vacías, mientras que phpdotenv las lee perfectamente. En Laravel eso significaba `APP_KEY` vacía → **regenerada en cada despliegue**, invalidando sesiones y todo lo cifrado, mientras Orbit imprimía «se queda en shared/.env, no se toca más». Y los cuatro avisos del paso 4 callaban a la vez. Ahora se lee la última asignación y se le quitan las comillas exteriores, que es lo que hace phpdotenv.

**Y el arreglo trajo dentro el fallo siguiente, que tardó tres versiones en verse.** La lectura pasó a ser un `sed` con la clave interpolada en la expresión regular, y `_env_has` ya era un `grep -E` igual; el que borra, en cambio, comparaba literal. O sea que **los tres no podían coincidir**, y con una clave que llevara un metacarácter se contradecían de la peor forma posible. Con un `.env` que tiene `FOOXBAR` y pidiendo `FOO.BAR`, reproducido contra el código de la v1.2.8:

- **`orbit env get app FOO.BAR` imprimía el valor de `FOOXBAR`** — el secreto de otra variable, por stdout, bajo un nombre que no es el suyo. Y stdout es precisamente el interfaz de este comando: existe para escribirse `VALOR=$(orbit env get app CLAVE)`.
- **`orbit env unset app FOO.BAR` decía «eliminada» sin borrar nada**, porque el que decide si la clave existe casaba y el que la borra no. Quien retira una credencial filtrada se queda creyendo que ya no está.

El punto es el metacarácter barato; `*`, `[` o `^` abren el mismo agujero. Desde la v1.2.9 hay **una sola función** que decide si una línea pertenece a una clave y la usan los tres, así que no pueden volver a discrepar; `get` y `unset` validan además el nombre igual que `set`, porque una clave con metacaracteres no puede existir en un `.env` y pedirla es siempre un error de quien la escribe. La regla general: **cuando tres funciones deciden lo mismo, la decisión va en una sola** — si no, el bug no está en ninguna de las tres sino en que discrepan, y las pruebas de cada una por separado pasan.

**`detect_stack` devolvía 1**, porque su última orden era un `[[ -f composer.json ]] && …`. Para una estática con un `.php` y sin `composer.json` —el caso de §18.7, un Astro con su `contacto.php`— la función salía con 1, y `cmd_new` la llama bajo `errexit` sin `|| true`: **`orbit new` se moría justo después de clonar, sin un error, sin un `die` y sin nada en pantalla**. Es la trampa de docs/DEVELOPMENT.md en el camino de entrada del producto. Y la prueba que debía cogerlo existía y era ciega: llamaba a `detect_stack` fuera de `run` y nadie miraba el código de salida.

**Un `artisan` de mentira que no hacía nada dejaba las pruebas ciegas.** El fixture de `deploy_test` era un `#!/usr/bin/env php` vacío que aceptaba cualquier subcomando y salía con 0: se podían borrar `key:generate`, `storage:link` y `config:cache` uno a uno y `make test` seguía en verde. La única comprobación que se caía la satisfacía el `printf 'APP_KEY='` de Orbit, no artisan. Ahora el fixture apunta lo que le piden y escribe de verdad, así que se comprueba el orden real, que `view:cache` no está, y que la clave no cambia entre despliegues. Es §21.8b otra vez: **una prueba construida sobre un doble que no puede fallar no comprueba nada**.

De ahí sale también un cambio de criterio: **los pasos de `_laravel_post_build` que dejan la web rota ahora abortan el despliegue** en vez de avisar. Laravel no lleva unidad, así que no hay `health_wait` ni rollback automático: un `warn` perdido entre veinte líneas y un «✔ desplegada» al final sustituían una web que funcionaba por una que devuelve 500 en todo. Y `config:cache` es además el mejor comprobante previo que tiene esta clase de app —arranca Laravel entero y lee su configuración—, así que falla antes de mover el symlink, que es gratis.

La arista: `orbit-security.conf` deniega por extensión (`\.(env|log|sql|sqlite|bak|old|swp|ini|yml|yaml|toml)$`), y es una `location` con regex, así que gana al front controller. Una ruta viva de Laravel que acabe en `.yaml` o `.sql` —`/informes/datos.sql`— responde **403**. No se quita, porque es una defensa que vale para todo lo demás, pero se documenta: el síntoma («mi ruta de exportación da 403 y en local funciona») no lleva a nadie a mirar un snippet de nginx.

## 18.9b La app fuera de la raíz del repositorio, y el octavo agujero de la rama de repuesto

El punto de partida, medido antes de escribir nada. Un monorepo normal —la API de Laravel en `backend/`, el frontend en `frontend/`— pasado por `detect_stack`:

```
A_TYPE=static  A_APPDIR=.  A_OUTDIR=.  A_DOCROOT=  A_PHP=yes
```

Ninguna rama casaba: no hay `package.json` en la raíz, ni `composer.json`, ni `.php` sueltos, ni `index.html`. Así que caía en la de repuesto, que es la que §18.8 documenta como la fuente de siete agujeros anteriores. Éste es el octavo, y es de los peores de la serie por dos cosas a la vez:

- `A_OUTDIR="."` pone el `root` de nginx en la raíz del repositorio, así que **todo el repositorio se publica**: `backend/composer.json`, `backend/artisan`, el código del frontend;
- y `_has_php` encuentra los `.php` de Laravel dentro, pone `A_PHP=yes`, y entonces php-fpm **ejecuta** cualquier `.php` alcanzable por URL — fuera de su docroot y sin el front controller.

Publicar el código y ejecutarlo, en el mismo despliegue. Comprobado con nginx y php-fpm de verdad: con el docroot en la raíz, `GET /backend/composer.json` devuelve 200 con el contenido y `GET /frontend/src/app.js` también.

Y no era de Laravel. Auditándolo salió que el mismo repositorio con un Go en `backend/`, un Django en `backend/` o un Hugo en `site/` daba exactamente lo mismo: `A_TYPE=static` con `A_OUTDIR="."`. Menos grave —sin `.php` dentro se publica el código pero no se ejecuta— pero el mismo agujero. Por eso lo que sigue está escrito una vez y vale para todos.

### Por qué no valía `_find_app_package`

Es la función que ya resuelve los monorepos de npm, y no sirve: lee `dependencies` de un `package.json` para decidir si un paquete es la app. En un monorepo de Laravel no hay ningún `package.json` que leer — la señal está en `composer.json` y en `artisan`. Así que `_laravel_dirs` es una búsqueda aparte, con las mismas dos convenciones: **dos niveles** (`backend/`, `apps/api/`), porque por debajo ya no hay convención que seguir y recorrer el repositorio entero cuesta caro para acertar poco.

### Las tres reglas que la hacen segura

**Se poda lo que no es del proyecto.** Un Laravel dentro de `vendor/` o de `node_modules/` es una dependencia —una bifurcación vendorizada, el esqueleto que traen los paquetes para probarse contra el framework—, no la app. La prueba que lo fija está a **dos** niveles (`vendor/acme/`) a propósito: puesta más honda pasaría con la poda quitada, comprobando el límite de profundidad en vez de la poda.

**La raíz que se declara a sí misma manda.** Si el `package.json` de la raíz declara un framework, eso es el repositorio diciendo lo que es, y gana sobre lo que aparezca dos carpetas más abajo. Un monorepo de JavaScript que trae un Laravel de ejemplo en `playgrounds/laravel/` existe, y sin esta regla se desplegaría el ejemplo. Con el Laravel **en** la raíz no hace falta la cautela —`artisan` y `bootstrap/app.php` ahí *son* el repositorio, y por eso `_is_laravel` sigue yendo delante (§18.5)—: a dos niveles, un Laravel es un indicio y no una prueba. Salió de buscarle agujeros al cambio, no de una prueba en rojo.

**Con varios, se elige y se dice.** Mismo criterio que con los binarios de Go: los nombres de siempre primero, si no el primero del glob —que viene ordenado, o sea el menos profundo—, y un aviso. Equivocarse aquí no publica nada raro: el docroot sigue siendo el `public/` de *un* Laravel.

### Una traducción de coordenadas, y no dieciséis ramas parcheadas

La forma obvia de soportar esto sería que cada rama de `detect_stack` compusiera sus propias rutas. Son dieciséis ramas y crecen, y la que se olvidara fallaría **hacia servir la carpeta equivocada**, que es el modo de fallo que toda esta sección existe para evitar.

Lo que se hace en su lugar: `detect_stack <dir> <sub>` **se llama a sí misma** sobre la subcarpeta —el mismo código de siempre, sin saber que está dentro de un monorepo— y después `_stack_relocate` traduce las coordenadas de una vez:

```
A_APPDIR   .           ->  backend            (y sub/inner si dentro había otro monorepo)
A_OUTDIR   dist        ->  backend/dist
           .           ->  backend
A_DOCROOT  public      ->  backend/public
A_SHARED   storage/x   ->  backend/storage/x
A_BUILD    <orden>     ->  cd backend && <orden>
A_START    <orden>     ->  cd backend && <orden>
A_MIGRATE  <orden>     ->  cd backend && <orden>
```

`A_SHARED` entró en la lista tarde, y por una revisión del PR: lo declara el `orbit.json` de la app, así que sus rutas son suyas. Sin recolocarlas, el despliegue enlazaba `release/storage/data` mientras la app escribe en `release/backend/storage/data` — el enlace apunta a un sitio por el que no pasa nadie y lo que la app guarde se pierde en el despliegue siguiente, en silencio. Es el bug que motivó §18.9, por otro camino.

Añadir un stack nuevo no toca nada de esto. Y la recursión se apaga a sí misma mientras dura, así que un monorepo dentro de un monorepo no sigue bajando.

Dos detalles que costaron pensarlos:

**El `cd` va a `$sub`, no a `A_APPDIR`.** Si la subcarpeta lleva a su vez un workspace de npm, las órdenes de dentro ya vienen con la ruta del paquete puesta (`pnpm --dir apps/web run start`), así que entrar hasta el paquete las dejaría buscándolo dos veces. `A_APPDIR` acaba valiendo `servicio/apps/web` y el `cd` sólo llega a `servicio`.

**El `cd` no rompe el apagado ordenado.** La unidad arranca con `ExecStart=/bin/bash -c '<A_START>'`, y la duda razonable es si `cd x && ./app` deja un `bash` de por medio que se coma el `KillSignal` — que en Go es `SIGTERM` y es lo único que dispara el cierre ordenado. Comprobado ejecutándolo, no leyéndolo: bash hace `exec` del último comando de un `-c` aunque lleve un `cd` delante, el PID del proceso lanzado **es** el de la app, y el manejador de `SIGTERM` se ejecuta. `WorkingDirectory` se queda en la raíz de la release y no se toca.

### Dónde va la búsqueda en la cadena, y el error que costó ponerla ahí

La primera versión de este cambio la colocó **delante** de la rama de `package.json`, razonando que un workspace no es una app desplegable. El razonamiento vale para los workspaces y era falso para todo lo demás, porque de paso se adelantaba a las ramas de `composer.json`, de `requirements.txt` y de `index.html`. Medido:

```
un sitio estático con tools/pyproject.toml al lado  ->  app de Python en tools/
una app PHP con su documentación en site/           ->  Hugo, y el PHP sin servir
```

En los dos casos la web de verdad dejaba de servirse. Lo encontró probarlo, no leerlo.

La regla correcta, y la única que no tiene contraejemplos: **lo que hay en la raíz es el repositorio, y sólo cuando la raíz no reconoce nada tiene sentido mirar dentro.** Así que la búsqueda se llama desde los dos sitios donde eso ocurre —justo antes de la rama de repuesto, y dentro de la rama de `package.json` cuando no hay framework, ni script de `build`, ni paquete de app dentro, que es el contenedor de un workspace y nada más—.

Un efecto secundario que conviene registrar: con la búsqueda en su sitio, la guardia que se escribió para el caso «la raíz declara un framework de JavaScript» pasó a ser **código inalcanzable** —esa raíz se lleva su propia rama mucho antes— y se ha quitado. La regla sigue viva, pero ahora es estructural en vez de un caso especial, que es mejor sitio para vivir. Código muerto que aparenta una protección es peor que no tener nada.

### Dos convenciones de ruta, y no se pueden mezclar

`A_APPDIR` dice dónde vive la app, y a partir de ahí hay dos formas de componer una ruta. Están en dos funciones para que no se confundan:

```
_app_root <release>  ->  <release>/backend      hacia dentro, ruta absoluta
_app_sub  public     ->  backend/public         hacia fuera, relativa al repo
```

La segunda es la convención que **ya seguía** `A_OUTDIR` en los monorepos de npm, donde la carpeta compilada se guarda como `apps/web/dist` y no como `dist`: toda ruta que se guarda en la configuración es relativa a la raíz de la release, con la subcarpeta ya dentro. Por eso `A_DOCROOT` de un Laravel en `backend/` vale `backend/public` y no `public`, y por eso el vhost no tiene que saber nada de `A_APPDIR`.

Y una tercera para los comandos: `_app_cd` antepone `cd backend &&`. Hace falta porque el build arranca en la raíz de la release —`_build_run` hace `cd "$rel"`— y `_run_in_app` también, mientras que composer y artisan tienen que correr donde está el `composer.json`.

### Lo que cada stack necesitó además

La traducción de coordenadas resuelve casi todo, pero tres sitios del despliegue tenían la raíz de la release escrita:

- **Go.** El paso 4c aborta el despliegue cuando el build sale con 0 y no deja binario —`go build` sobre un paquete que no es `main` hace exactamente eso—, y miraba en `<release>/bin/app`. Con la app en `backend/` esa comprobación no medía nada.
- **Django.** `_django_probe` lanza el `python` del venv para preguntarle a Django dónde tiene `STATIC_ROOT`, y tanto `manage.py` como el venv están dentro de la app. El recorte que convierte la respuesta en una ruta relativa, en cambio, es contra la raíz de la release — de nuevo las dos rutas a la vez, como en `_laravel_post_build`. Lo bueno: ese recorte ya dejaba `backend/staticfiles`, que es justo lo que nginx necesita, así que los estáticos salieron gratis. Es la mejor señal de que la convención de rutas era la correcta.
- **Hugo.** Nada, y por eso es el caso que mejor enseña el diseño: lo único que cambia es `A_OUTDIR`, que pasa de `public` a `site/public`, y eso lo hace la traducción de coordenadas sola.

### El `.env` lo encontró la prueba de despliegue, no la de detección

La detección salía verde y el despliegue moría en el paso de la `APP_KEY`: `key:generate` no encontraba `.env`, salía con 1, y el despliegue abortaba con un mensaje que hablaba de la clave y no de dónde estaba buscándola.

El motivo: el despliegue enlazaba `shared/.env` en la **raíz de la release**, y Laravel busca su `.env` junto a su `composer.json`. Son dos lectores distintos mirando en sitios distintos — `_build_run` hace `cd $rel; . ./.env`, y artisan mira en la carpeta de la app —, así que ahora se enlaza en los dos sitios. No se acota a Laravel: cualquier framework que lea su `.env` junto a su manifiesto —Next y Vite lo hacen— estaba en el mismo caso, con el enlace de la raíz sirviéndole de nada.

Es la lección de siempre de este documento, otra vez: la prueba de detección no podía verlo, porque el fallo vive en la interacción entre el enlace, artisan y dónde está cada uno.

### Una app por vhost, y la otra también se puede desplegar

Cuando el repositorio trae más de una app desplegable hay que elegir una, porque un vhost sirve una. Los desempates son dos y no se confunden: **entre stacks** manda el orden de la rama principal —el mismo que ya carga con el razonamiento de por qué lo específico va antes que lo genérico—, y **dentro de un stack** mandan los nombres de siempre (`backend`, `api`, `server`…), igual que con los binarios de Go. Se avisa de todas las que hay.

La otra no se pierde: `orbit new otra --appdir frontend` la despliega como app aparte con su propio dominio. Para que eso funcione de verdad, `--appdir` **dirige la detección** en vez de ser un campo que se pisa al final — antes dejaba `A_BUILD` y `A_START` apuntando a la raíz del repositorio, o sea una app que no compilaba, o peor, que compilaba lo que no era. Y la carpeta tiene que existir: con una errata, lo que había era un build muriendo con «cd: no such file or directory» sin decir de dónde salía esa ruta.

Y si al lado hay un frontend suelto con su `package.json` —que no es ninguno de los stacks de arriba, así que no sale en esa lista—, **Orbit no lo compila ni lo sirve**, y lo dice. Es la misma regla que el aviso de «un framework de servidor dentro del `package.json` de Laravel», sólo que aquí el framework está en otra carpeta.

Y `orbit exec <app>` sigue dejándote en la raíz de la release, no en la carpeta de la app: cambiarlo tocaría también los monorepos de npm y las apps de Python, donde `./.venv` es relativo a la raíz. Lo que sí se ha corregido es que los consejos que imprime Orbit lleven el `cd` puesto, que era donde se notaba.

### El `orbit.json` de la app, y no sólo el del repositorio

El descriptor existía para que un repositorio pudiera declarar su despliegue en vez de que Orbit lo adivine, y se leía **sólo de la raíz**. En un monorepo eso deja fuera justo al que más lo necesita: la app que vive en `backend/` no tenía forma de decir cómo se despliega, y si además su stack no lo reconoce ningún heurístico, no había forma de desplegarla.

La pieza que lo resuelve es la misma de antes. El descriptor **se lee dentro de `detect_stack`**, sobre la carpeta que de verdad se está detectando, en lugar de leerlo quien la llama. Y como detectar un monorepo es esta función llamándose a sí misma sobre la subcarpeta, el `orbit.json` de `backend/` se lee ahí dentro —donde sus rutas significan lo que su autor quiso decir— y lo recoloca después la misma traducción de coordenadas que todo lo demás:

```
backend/orbit.json:  {"type":"static","outdir":"dist","build":"make sitio"}
                     ->  A_OUTDIR=backend/dist
                         A_BUILD=cd backend && make sitio
```

Leerlo desde fuera obligaría a recolocar dos veces, una por cada origen, y a acertar las dos.

**Una declaración manda sobre cualquier inferencia**, así que una subcarpeta con `orbit.json` es la **única** búsqueda de subcarpeta que va delante de las ramas de la raíz. Con un matiz que costó una revisión del PR: lo que manda es un descriptor que se vaya a **aplicar**, no un fichero con ese nombre. Con la comprobación floja, un `orbit.json` roto —JSON inválido, o sin `type`— en una subcarpeta se llevaba la detección hacia ella, y una vez dentro no se puede volver a la raíz porque la búsqueda queda apagada: un sitio perfectamente detectable en la raíz acababa sin servirse y con la subcarpeta publicada en su lugar. El agujero de §18.8, entrando por la puerta que se abrió para evitarlo. Sin `jq` vale lo mismo, porque sin `jq` ningún descriptor se aplica. La excepción tiene motivo, y es el reverso exacto de la regresión de más arriba: todo lo demás que se busca ahí abajo son indicios —un `pyproject.toml` puede ser de una carpeta de utilidades—, y un `orbit.json` no aparece por accidente. Si la raíz trae el suyo, gana la raíz sin mirar dentro: ese fichero describe el repositorio entero, incluida la carpeta donde vive la app, y dos declaraciones compitiendo no las resuelve una heurística.

Dos detalles que sólo se ven ejecutándolo:

**La rama de repuesto ya no alarma cuando el repositorio se declara.** Un `backend/` con un `orbit.json` y nada que ningún heurístico reconozca pasaba por el «no reconozco este repositorio, nginx publicaría el código fuente» **y tres líneas después el descriptor lo desmentía**. Asustar y contradecirse en el mismo párrafo.

**Y el aviso salía sin nombre de carpeta.** `_declared_stack_dir` vaciaba `STACK_DIR` antes de comprobar si la búsqueda estaba apagada, y la llamada recursiva pasa por ahí otra vez: le borraba el nombre a quien lo había puesto, y el mensaje quedaba en «La app está en : …». La prueba no lo cogía porque buscaba la frase y no el nombre. Está arreglado en el orden de la función y, además, con una copia local en cada sitio que llama; como con dos defensas quitar una no rompe nada visible, hay una prueba que fija la invariante directamente —y esa prueba, escrita con el `run` de la suite, tampoco podía fallar, porque `run` lanza un subshell y el global no salía de él—.

### Las rutas del `orbit.json`, validadas

`appdir`, `outdir` y `docroot` los declara el repositorio y acababan aplicándose tal cual. Con este cambio `appdir` pasa a decidir sobre qué carpeta actúa el `rm -rf` que sustituye `storage/` por el enlace al compartido, así que se validan como todo lo que llega a un vhost (§18.7): nada absoluto, nada con `..`, y sin guion inicial —una carpeta llamada `-rf` convierte el `cd` del build en un puñado de opciones—.

Con la honestidad por delante, que es la costumbre aquí: **esto no es una frontera de seguridad**. El mismo `orbit.json` declara `build`, que es una orden de shell y corre como el usuario de despliegue, igual que los scripts de un `package.json`. Un repositorio hostil ya ejecuta código por diseño. Lo que esto evita son dos averías corrientes: un `..` que saca las rutas del despliegue fuera de la carpeta de la app, y un `;` en `docroot` que escribe un vhost ilegible — y como el fichero se enlaza en `sites-enabled` **antes** del `nginx -t`, eso tumba la configuración del servidor entero: ninguna otra app se despliega y ningún certificado se renueva.

## 18.10 Métricas de despliegue: un fichero de texto y ninguna pieza nueva

La pregunta que contesta `orbit metrics` es **«¿esto va a peor?»**. Todo lo demás sale de ahí.

**Dónde viven los datos.** Una línea TSV por despliegue en `/var/lib/orbit/deploys.tsv`, escrita por el propio `orbit deploy`. No hay recolector, ni base de datos, ni proceso: el principio 2 no se toca porque no hay nada nuevo corriendo, y el 5 tampoco porque el histórico se lee con `cat`, se filtra con `grep` y se suma con `awk` mucho antes de que nadie llame a `--json`. El JSON se genera al leer, que es donde hace falta.

```
2026-08-10T16:21:04+00:00	web	ok	  2	 2	20260810-162102	252b1de	-	-
2026-08-10T16:21:18+00:00	roto	fallo	  0	 -	-	-	code	no pude clonar el repositorio
```

Nueve columnas: fecha, app, resultado, segundos totales, segundos de build, release, commit, paso donde falló y notas.

**Se escribe desde el manejador de salida del despliegue**, que es el único sitio por el que pasan los dos finales. Sin eso no se podrían contar los fallos, que es la mitad de lo que pide la métrica — y los fallos son justo los despliegues que no llegan al final del código.

**No sustituye a `logline`,** y merece decirse porque la tentación es fundirlos: aquella es la bitácora de todo lo que hace Orbit, en prosa y para una persona; esto son datos de una sola cosa. Fundirlos obligaría a analizar la bitácora para contar, que es exactamente lo que el contrato `--json` existe para no tener que hacer.

### Las tres decisiones que tienen contenido

**El build se cronometra aparte del despliegue.** Es el número que le interesa a alguien: clonar, mover un symlink y recargar nginx son más o menos constantes, y lo que crece con el proyecto es compilar. La prueba que lo fija mete un retardo conocido **delante** del build, que es donde de verdad distingue — puesta detrás, los dos números crecen igual y pasa con el cronómetro mal puesto. Eso lo dijo mutar el código, no leerlo.

**La mediana, no la media.** Un build que normalmente tarda 30 s y una vez tardó 400 porque el servidor estaba ocupado tiene una media que no describe ningún despliegue real.

**Y la tendencia se calla cuando no hay datos para tenerla.** Con menos de seis builds correctos no se calcula nada y se dice por qué, en vez de enseñar un número que alguien usaría para decidir. En el contrato eso es `null` y no `0`: el cero es un valor y significa «igual».

Un detalle que salió de mutarlo y cambió el diseño: la primera versión sólo contaba los builds de despliegues **que terminaron bien**. Es una distinción arbitraria — un build que terminó en 30 s es una medición de 30 s aunque el health check tumbara la release después, porque lo que se mide es compilar, no desplegar—. Y un build que no llegó a terminar no deja número, así que se cae solo. El filtro correcto es «¿hay un número?», que además es más simple.

### Lo que no hace

**No se poda con bloqueo.** Añadir una línea con `>>` es atómico entre procesos; la reescritura de la poda no, así que un despliegue que termine en ese instante podría perder su línea. Ocurre una vez cada doscientos despliegues y lo que se pierde es un dato de observabilidad, no un despliegue.

**No entra en las copias de seguridad**, igual que el estado del vigilante: es observabilidad derivada, no configuración. Un servidor restaurado empieza su histórico de cero, y eso es correcto — las medianas de otra máquina no describen ésta.

**Y hay una restricción para quien añada un motivo de fallo nuevo:** esto se queda en disco. Hoy los diecisiete `DEP_ERR` son cadenas fijas cuya única parte variable es un código HTTP. Meter ahí la salida de git sería otra cosa: la URL de un repositorio privado puede llevar un token dentro.

## 18.11 Qwik: lo decide el adaptador, y el adaptador no es un paquete

Qwik se lee como una segunda parte de §18.1: igual que en SvelteKit, el `package.json` es el mismo, el build es el mismo y **el adaptador decide si sale un sitio o sale un servidor**. La diferencia está en cómo se encuentra, y es la que hace que la técnica de SvelteKit no sirva.

**En SvelteKit el adaptador es un paquete**, así que basta con mirar las dependencias: `@sveltejs/adapter-static` está o no está. **En Qwik no lo es.** Los adaptadores viven dentro de `@builder.io/qwik-city` (`@qwik.dev/router` en la v2), que ya está instalado pase lo que pase, así que ninguno aparece nunca en el `package.json`. Lo que sí deja `qwik add` es un **directorio**:

```
adapters/express/vite.config.ts
adapters/static/vite.config.ts
adapters/node-server/vite.config.ts
```

Esa es la señal, y tiene una propiedad que no tenía la de SvelteKit: es la misma en la v1 y en la v2. Qwik 2 renombró los dos paquetes —`@builder.io/qwik` → `@qwik.dev/core`, `@builder.io/qwik-city` → `@qwik.dev/router`— y no tocó la convención de adaptadores. Se reconocen los cuatro nombres para saber *que es Qwik*; lo que se hace con él sale del directorio.

### El agujero, que es otra vez el de §18.8

`vite` está en las `devDependencies` de **todos** los proyectos de Qwik. La rama de Vite está antes en la cadena, así que se los quedaba enteros y salía `A_TYPE=static`, `A_OUTDIR=dist`, `A_SPA=yes`. Medido compilando cuatro proyectos de `npm create qwik@latest` 1.20.0, uno por adaptador:

| adaptador | `dist/index.html` | servidor | qué hacía Orbit |
|---|---|---|---|
| ninguno | **no existe** | no hay | `static` → 404 completo |
| `express` | **no existe** | `server/entry.express.js` | `static` → 404 completo |
| `node-server` | **no existe** | `server/entry.node-server.js` | `static` → 404 completo |
| `static` | sí | no hay | `static` con SPA de más |

Los tres primeros son el fallo entero: nginx apuntando a un `dist/` **sin una sola página**, y el respaldo de SPA reescribiendo todo hacia un `/index.html` que no existe. No es una degradación, es la web entera en 404 — la misma frase que ya está escrita para el monorepo de Next, y por la misma razón.

Y el adaptador de Express **añade `express` a las `dependencies`**, así que la segunda señal tampoco salvaba nada: la rama de Vite va antes que la de Express. La de Qwik va delante de las dos, y ese es el motivo de su sitio en la cadena (§18.5).

### El arranque sale de `serve`, y nunca de `start`

Cada adaptador escribe en el `package.json` el script con el que se arranca lo que compila: `node server/entry.express`, `bun server/entry.bun.js`, `deno run --allow-net … server/entry.deno.js`. Es su declaración autorizada, y se prefiere a una tabla de nombres porque el fichero de entrada lleva dentro el nombre del adaptador, son catorce, y dos cambian de nombre entre la v1 y la v2 (`bun` → `bun-server`, `deno` → `deno-server`).

**Y hay que decir de dónde no sale.** En Qwik, `start` es:

```json
"start": "vite --open --mode ssr"
```

O sea el servidor de **desarrollo**. Es el único de los diecinueve stacks donde `start` no arranca la aplicación en producción, y el camino genérico de la cadena —«tiene `start`, luego se arranca con `start`»— lo habría cogido sin pestañear. La mutación que lo comprueba deja `vite --open --mode ssr` como orden de arranque de producción en ocho comprobaciones a la vez.

El tipo dice el runtime (`node`, `bun`, `deno`) porque de él dependen el binario que exige `orbit doctor` y lo que enseña `orbit list`. Comprobado arrancando el `node-server` ya compilado: lee `PORT`, escucha donde se le dice y devuelve 200 con el HTML generado en el servidor, que es exactamente lo que Orbit necesita de una app con proceso (§5.1).

### El estático va sin respaldo de SPA

El adaptador `static` es el único que deja algo servible, y prerenderiza **una página por ruta**: `dist/` sale con `index.html`, las carpetas de cada ruta y un `404.html` de verdad. Por eso `A_SPA="no"`: con el respaldo activado, ese `404.html` no se usaría jamás y cualquier ruta inexistente devolvería la portada con un 200. Es el mismo criterio que con `adapter-static` de SvelteKit.

### Lo que no se puede desplegar aquí se dice

Sin adaptador —que es como sale del generador— y con los de Cloudflare, Vercel, Netlify, AWS, Azure, Firebase y Cloud Run, no hay nada que este servidor pueda ejecutar. Se avisa, se dice qué comando ejecutar (`npm run qwik add node-server`) y **se va con proceso**, por la regla de §18.8: así el despliegue falla en voz alta y hay rollback, en vez de publicar un sitio roto que parece desplegado. El aviso importa tanto como la elección — un despliegue que falla sin explicar por qué manda a depurar nginx, que es justo el bug que ya costó un arreglo en la 1.1.

## 19. El servidor por defecto, y por qué el 443 necesita el suyo

Un nginx con varias webs elige a quién le toca contestar mirando el nombre que pide el cliente. Cuando ese nombre no lo declara ningún `server_name`, no devuelve un error: **elige el primer bloque que escuche en ese puerto**. Es el comportamiento documentado, no un fallo, y por eso existe `default_server`: para decidir explícitamente quién es ese primero.

Orbit tenía uno desde el principio. Sólo para el puerto 80.

### 19.1 Lo que pasaba

Con un `default_server` en el 80 y ninguno en el 443, una petición HTTPS cuyo SNI no coincidiera con ningún vhost caía en el primer bloque `listen 443 ssl` del `include`, que se lee por orden alfabético: **la primera app desplegada**. Dos consecuencias, y la segunda es peor que la primera:

- Alguien apunta un dominio a tu IP —a propósito o por error de otro— y ve la web de un cliente tuyo.
- Una app **recién creada** hace lo mismo. Entre `orbit new` y `orbit ssl` no hay certificado, y sin certificado su vhost no tiene bloque de 443. Durante esos minutos, entrar por HTTPS al dominio nuevo enseña la web de otra app.

Ese segundo caso es el que se ve desde fuera como «he desplegado un dominio y me lleva a otro sitio». Se confunde fácilmente con un problema de contenido —«será que no tiene `index.html`»— y no lo es: una app **con** certificado y sin `index.html` devuelve un 403 correctísimo y no filtra nada. El disparador era siempre el certificado que aún no existía.

No es un problema estético. Es enseñarle a un desconocido algo que no es suyo, y encaja de lleno en el principio 6.

### 19.2 Por qué se rechaza el saludo TLS y no se sirve una página

En el 443 el servidor por defecto hace `ssl_reject_handshake on;` y no tiene certificado. Se consideraron las alternativas:

- **Servir una página de error con un certificado cualquiera.** Requiere presentar el certificado de otro dominio, que es exactamente el problema que estamos arreglando, y encima el navegador enseña un aviso de seguridad. Se cambia una filtración por una alarma.
- **Emitir un certificado autofirmado para el servidor por defecto.** Mismo aviso del navegador, más un certificado que hay que generar, guardar y renovar para no decir nada.
- **Rechazar el saludo.** No hace falta ningún certificado, porque *no puede existir* uno válido para un nombre que este servidor no sirve. El cliente recibe un error de TLS, que es literalmente lo que ocurre: aquí no hay nada para ti.

Detrás de Cloudflare, la tercera opción se traduce en un **525** para el visitante. Dice la verdad —el origen no atiende ese nombre— sin que el origen tenga que mentir con un certificado prestado.

`ssl_reject_handshake` existe desde **nginx 1.19.4**. Ubuntu 24.04 trae 1.24, así que en el destino soportado siempre está. Si no lo está, el fichero se genera con el bloque de 80 y un comentario explicando qué falta: Orbit no escribe una configuración que nginx no va a entender, y tampoco se calla el hueco.

En el **puerto 80** se mantiene el `return 444` de siempre —cerrar la conexión sin contestar—, con una excepción: el `include` del desafío de Let's Encrypt. Tiene que seguir pasando, porque el primer certificado de una app se emite **antes** de que su vhost sepa de HTTPS.

### 19.3 Una sola definición, y cómo llega a los servidores que ya existen

El vhost por defecto lo definía `install.sh` en un heredoc. Es exactamente así como se quedó sin el bloque de 443: dos sitios donde podría vivir la misma configuración, y sólo uno se mantuvo.

Ahora lo escribe `_default_vhost` en el script, y el instalador lo obtiene llamando a `orbit nginx-rebuild` al final —cuando `orbit` y su configuración ya existen—. Hasta ese momento no hay ningún `server` declarado, así que nginx no sirve nada, que es la respuesta correcta mientras no haya nada que servir.

De ahí sale gratis lo importante: **`orbit nginx-rebuild` es lo que arregla un servidor instalado antes de este cambio**. `nginx_default_write` compara con `cmp` antes de escribir, así que en un servidor ya correcto no toca el fichero ni pide recarga.

Y `orbit doctor` lo comprueba, porque un servidor que nadie regenera no se entera solo. La comprobación `default-server` da **error** —no aviso— si falta el fichero o si no contiene `listen 443 ssl default_server`, y dice la orden que lo arregla. Es el mismo patrón que el formato de logs de §8.5: una mejora que vive fuera de los vhosts de las apps llega a los servidores viejos por `nginx-rebuild` y se detecta por `doctor`.

## 19.5 `orbit doctor --fix`, y las cuatro reglas de qué se puede arreglar solo

El diagnóstico ya sabía el arreglo de casi todo lo que detecta: lo llevaba escrito en el mensaje. La distancia entre saberlo y aplicarlo es una lista de reglas, no una lista de comandos.

Para que un arreglo se pueda aplicar solo tiene que cumplir **las cuatro**:

1. **No decide nada por ti.** Arrancar un servicio parado es reponer lo que ya se quería. Elegir qué borrar de un disco lleno, no.
2. **No hace falta hablar con nadie.** Nada interactivo, y nada que dependa de una contraseña, un navegador o un token que sólo tú tienes.
3. **Se deshace.** Reasignar un puerto se revierte con otro `orbit port`. Instalar paquetes en el servidor de alguien, no del todo.
4. **No toca producción a ciegas.** Un vhost se valida con `nginx -t` antes de recargar, igual que en el resto de Orbit.

Lo que pasa el filtro hoy son cinco: PostgreSQL parado, php-fpm parado, el servidor por defecto ausente o sin bloque 443, los puertos internos duplicados, y —desde la v1.3.5— **el vhost de una app registrada que no está**.

Ese último es el que mejor enseña por qué las reglas se miran una a una en vez de a ojo. Está al lado de dos detecciones que **no** llevan acción —una app parada y una app en mantenimiento—, y a primera vista se parece a las dos: las tres son webs que no responden. La diferencia está en la regla 1. Una unidad parada y un mantenimiento puesto pueden ser una decisión de alguien, y deshacerla es publicar lo que otro bajó a propósito; un vhost que falta no lo decide nadie, y además se regenera entero del descriptor, así que rehacerlo no inventa ningún dato. Cumple también la 4, porque `render_nginx` valida con `nginx -t` antes de recargar.

Lo que queda fuera, y por qué:

| Detección | Regla que incumple |
|---|---|
| `pnpm` o `hugo` sin instalar | 3 — instalar cosas en el servidor de alguien no es un diagnóstico |
| GitHub o Cloudflare sin conectar | 2 — hace falta un navegador y un token tuyo |
| Disco lleno | 1 — qué se borra lo decides tú |
| Certificado a punto de caducar | Se renueva solo, y `certbot` tiene límites de peticiones |
| `service-home` (§5.1) | Regenerar la unidad sin rehacer el build dejaría la caché de corepack vacía: hace falta un despliegue entero |
| App en mantenimiento (§5.5) | 1 — quitarlo publicaría una web que alguien pudo bajar a propósito. Lo mismo vale para el `php artisan down` de Laravel |
| App con proceso parada (§11.1) | 1 — puede estar parada porque alguien la paró; y si se muere en bucle, arrancarla apaga la señal y deja el fuego |

Tres decisiones de diseño que no son obvias:

**Se vuelve a diagnosticar al terminar, y se enseña.** Lo que cuenta es cómo queda el servidor, no lo que dijeron los comandos. Un arreglo que devuelve 0 y no arregla nada tiene que verse, y así se ve: el problema sigue en la lista de abajo.

**Arrancar no es estar vivo.** `_fix_service` lanza el `start` y **después** comprueba `is-active`. Una unidad puede aceptar el arranque y morirse acto seguido —es exactamente lo que hacía la app del §5.1—, y mirar sólo el código de salida de `systemctl start` diría «arreglado» sobre un servicio caído.

**Con puertos duplicados, se mueve la que NO está sirviendo.** La app viva es la que está atendiendo peticiones ahora mismo; moverla cortaría un servicio que funciona para arreglar otro que no. Si ninguna está viva se mueve la primera, que es una elección tan buena como cualquiera y al menos es reproducible.

Y una del contrato: **`doctor --fix --json` exige además `--yes`**. `confirm` escribe la pregunta por stdout, donde con `--json` sólo puede ir el JSON; y decidir por nuestra cuenta que quien automatiza ya ha dicho que sí sería aplicar cambios en un servidor sin que nadie los haya aceptado. El JSON gana además el campo `fixable`, que es lo que separa «hay consejo» de «hay botón» y permite a un cliente ofrecerlo sólo cuando hace algo.

## 20. Elegir en vez de escribir, y los dos modos

Cuatro cosas de esta sección salieron del mismo sitio: un usuario creando su primera app, un build que falla, y una shell.

### 20.1 El `exit` que se llevaba el menú por delante

El menú llamaba a cada comando así:

```bash
1) cmd_new || true; pause ;;
```

El `|| true` no servía para nada, y durante meses pareció que sí. `die()` termina en `exit 1`, y un `exit` **no se caza con `||`**: mata el proceso entero. Así que cualquier error dentro del menú cerraba Orbit, el mensaje pasaba volando y el usuario aparecía en la shell sin saber si había pasado algo o no.

El arreglo es un subshell, `( cmd_new )`: ahí dentro el `exit` termina el subshell y nada más. El error ya se ha impreso, se espera a que se lea, y se vuelve al menú.

Hay dos formas porque hay dos clases de comando. `_menu_run` pausa siempre. `_menu_live` —`logs`, `top`— sólo pausa si el comando falla: meter una tecla entre el panel a pantalla completa y el menú sería una molestia sin motivo.

### 20.2 `orbit new` no puede dejar media app y una shell

El asistente registra la app, crea la base de datos si se pidió, y **luego** despliega. Cuando el build fallaba, el `die` de `cmd_deploy` mataba el proceso: la app quedaba registrada y en nginx, sin ninguna versión publicada, sin certificado, y sin que nadie hubiera dicho nada de eso. Leído desde fuera es «Orbit no sabe crear apps», cuando el fallo estaba en el repositorio que se le pidió servir.

Ahora el despliegue va en un subshell y, si falla, el asistente **termina contando el estado**: qué existe (la app, su vhost, su carpeta, su base de datos), qué no (ninguna release publicada, ningún certificado), y cuál es el siguiente comando —`orbit deploy <app>`, sin repetir el asistente—.

La app se deja registrada a propósito. Deshacerlo obligaría a repetir el asistente entero por un fallo que casi siempre es un commit de más en el repositorio, y la salida ya dice cómo quitarla si de verdad se quiere empezar de cero.

Y se responde a la pregunta que se hace todo el mundo —«¿por qué falla en la primera, si no hay nada viejo?»— enseñando cómo comprobarlo sin Orbit por medio:

```
git clone --depth 1 -b main https://… /tmp/comprobar
cd /tmp/comprobar && pnpm install --frozen-lockfile --prod=false && pnpm build
```

El build se hace sobre un clon recién traído en una carpeta nueva. No hay nada heredado: el mismo commit falla igual en cualquier sitio. Eso no es un consuelo, es la información que hacía falta para saber dónde mirar.

### 20.3 Tres cosas que se tecleaban de memoria

La rama, el commit y el script que compila o arranca. Equivocarse en cualquiera de las tres **no da un error que hable de eso**: escribir `master` en un repo cuya rama es `main` da un fallo de git tres pantallas después.

- **La rama** sale de `git ls-remote --heads`, sin clonar nada. No se ordena alfabéticamente: `main` primero, luego `master`, `develop` y `dev`, y el resto detrás. Alfabético dejaría `develop` por delante de `main`, que es la que se quiere casi siempre.
- **Los pull requests** salen de `gh pr list`, si hay GitHub CLI conectado. Que no lo haya no es un error: el repositorio puede no estar en GitHub.
- **Los commits** salen de la caché local, que es lo que hay sin pedirle nada al remoto. En una app recién creada esa caché todavía no existe y entonces sólo se ofrecen la rama y los PRs.
- **Los scripts** salen del `package.json`, con lo que ejecuta cada uno al lado. Los nombres se los pone cada proyecto —`build`, `dev`, `dev:debug`— y no hay forma de adivinarlos: hay que leerlos. Siempre queda la opción de escribir otra cosa, porque un proyecto puede arrancar con algo que no está en `scripts`, y encerrar al usuario en la lista sería peor que no tener lista.

La búsqueda sale gratis: `choose()` ya usaba fzf cuando está instalado, que filtra según escribes.

**Desplegar un PR no cambia `A_BRANCH`.** Es una prueba, no una mudanza: la app sigue siendo de su rama para todo lo demás. Por eso se avisa de que lo desplegado no es la punta de la rama, y —si el autodespliegue está puesto— de que el próximo ciclo volverá a ella. Un despliegue fijado que se deshace solo sin avisar sería peor que no poder fijarlo.

### 20.4 El `choose()` que devolvía la pregunta

Escribiendo las pruebas de todo lo anterior apareció un fallo que llevaba ahí desde el principio: en la rama sin fzf, `choose()` llamaba a `ask`, que escribe la pregunta por la **salida normal**. Y la salida normal de `choose()` es el valor elegido. Así que sin fzf devolvía `Qué desplegar (número) [1]: main` en vez de `main`.

No se notaba porque `install.sh` instala fzf, así que en un servidor de verdad nunca se toma esa rama. Pero cualquiera que use Orbit sin fzf —un contenedor, un servidor ajeno, las propias pruebas— tenía `pick_app` devolviendo basura. La lista ya iba por `stderr`; le faltaba la pregunta.

### 20.5 Los dos modos

**Orbit a secas** decide por ti y pregunta lo justo. Es el modo con el que se despliega una web en dos minutos sin saber qué es un adaptador de SvelteKit.

**`orbit --eva`** no decide nada solo. EVA es *Extra-Vehicular Activity*: salir de la nave, sin asideros, tú a los mandos. Pasa por todos los campos en vez de preguntar «¿es correcto?», enseña los scripts del `package.json` para que elijas cuál compila y cuál arranca, ofrece los PRs y los commits al desplegar, y deja escribir el comando que quieras en cada paso. También acepta `--jedimaster`.

Los dos recorren **el mismo código**. El modo no es una rama paralela: es una variable que decide si se pregunta o se asume. Una segunda ruta «para expertos» acabaría siendo la que nadie prueba.

### 20.6 Lo que salió de probarlo de punta a punta

Las pruebas unitarias daban verde. Ejecutar el modo entero contra un repositorio de verdad —dos ramas, tres scripts de build, nginx sirviendo el resultado— encontró cuatro cosas que ninguna de ellas miraba.

**La rama se preguntaba dos veces.** El selector dejaba la elección en `branch` y justo después venía el `ask` de siempre, con lo elegido como valor por defecto. Funcionaba, pero obligaba a confirmar dos veces lo mismo. Ahora sólo se pregunta si el selector no ha dado nada.

**El spinner escribía una línea por fotograma sin terminal.** El `
` sólo borra la línea si hay un terminal detrás; redirigido a un fichero, cada fotograma se quedaba escrito. Un build de tres minutos dejaba **dos mil líneas iguales** tapando lo único que importaba de ese log — y ahí es justo donde va a parar la salida del autodespliegue y de cualquier `orbit deploy` en un cron. Sin terminal ya no se dibuja nada y se espera y ya.

**`git fetch origin <sha>` no sirve para desplegar un commit.** Un remoto sólo entrega SHAs sueltos si los anuncia, y casi ninguno lo hace salvo GitHub: contra un `file://`, contra Gitea o contra un GitLab con la opción apagada, `--ref 9581b91` fallaba con `couldn't find remote ref`. Y era innecesario, porque **el commit ya estaba ahí**: la caché guarda los últimos 50 de la rama, que son justamente los que ofrece el selector. Ahora se mira la caché primero y sólo se pide al remoto lo que no se tiene — que es el caso de los PRs y de las ramas, donde el fetch por nombre sí funciona. Si tampoco está, se dice por qué: puede ser más antiguo que la profundidad del clon.

**El aviso de `orbit new` daba por hecha la causa.** Decía «el build se ha hecho sobre un clon recién traído… el mismo commit falla igual en tu máquina» — pero en la prueba lo que había fallado era **nginx**, con el build correcto y la release ya activa. Mandar a mirar el repositorio cuando lo roto es un vhost es peor que no decir nada. Ahora se distingue mirando el disco, que no admite suposiciones: si existe el enlace `current`, el código compiló y el fallo es posterior, así que el mensaje manda a `nginx -t` y a `orbit doctor`; si no existe, sigue el discurso del repositorio.

Ninguna de las cuatro es exótica, y ninguna la habría encontrado una prueba unitaria: tres dependen de que haya o no un terminal, un remoto real y un servidor real, y la cuarta de qué se ha roto exactamente.

La misma pasada con el **modo sencillo** —crear, servir, desplegar, volver atrás, mantenimiento, redirecciones, copias, clonar y borrar— salió limpia salvo por una cosa, y es de las que más importan:

**`orbit doctor` se moría entero si faltaba `dig`.** `ip=$(dig +short …)` con `errexit`: un `command not found` sale con 127, la asignación hereda ese código y el diagnóstico se interrumpe. Y como se **recoge todo y se imprime al final**, no salía ningún diagnóstico — ni siquiera las diez comprobaciones que ya habían pasado. La herramienta que se ejecuta precisamente cuando algo va mal era la que se rompía primero.

`dig` viene de `dnsutils`, que instala `install.sh`, así que en un servidor de fábrica está. Pero eso es exactamente el razonamiento que llevó al fallo: doctor no puede dar por hecho el servidor que diagnostica. Ahora se comprueba una vez, se avisa una vez —no una por app— con el `apt-get` que lo arregla, y el resto del informe sale igual.

### 20.7 El menú, y el `errexit` que se apagaba solo

Recorrer las 19 opciones del menú encontró tres cosas, y la primera es la peor que ha salido en todo esto — porque **la había metido yo al arreglar el menú**.

#### Un subshell a la izquierda de `||` no tiene errexit

El arreglo de §20.1 era `( "$@" ) || _menu_err`. Contiene el `exit` de `die()`, sí. Pero bash **apaga errexit dentro de cualquier comando que forme parte de una lista `&&` o `||`**, y el subshell lo hereda. La consecuencia: todos los comandos lanzados desde el menú corrían **sin errexit**.

Se vio en `orbit github` con `gh` sin instalar:

```
sudo: gh: command not found
sudo: gh: command not found
  ✔ GitHub conectado para el usuario 'root'
```

Dos fallos seguidos y un éxito anunciado. El mismo comando fuera del menú abortaba correctamente al primero.

Lo que hace este caso digno de recordar es lo que **no** funciona como arreglo. Medido, no supuesto:

| Forma | ¿errexit dentro? |
|---|---|
| `( f ) \|\| true` | **no** |
| `( set -Eeuo pipefail; f ) \|\| true` | **no** — repetirlo dentro no lo reactiva |
| `if ! ( set -Eeuo pipefail; f ); then` | **no** |
| función auxiliar que haga lo correcto, llamada con `\|\|` | **no** — se hereda también a través de la llamada |
| `set +e; ( set -Eeuo pipefail; f ); rc=$?; set -e` | **sí** |

Sólo la última. El subshell tiene que quedar **suelto**, con el errexit del padre apagado a mano alrededor para que su fallo no mate al menú, y encendido a propósito dentro. Y no se puede factorizar en un ayudante compartido, porque llamarlo con `||` reintroduce el problema: por eso `_menu_run` y `_menu_live` repiten esas cuatro líneas en vez de compartirlas. Es la clase de duplicación que hay que dejar escrita, con el motivo al lado, o alguien la «limpia».

**El mismo fallo estaba en el banco de pruebas.** `tests/lib.sh` promete que `run()` ejecuta con las mismas opciones que en producción, pero se llamaba `run cmd && r=0 || r=$?` en 179 sitios — el contexto que apaga errexit. O sea que **ninguna prueba estaba ejerciendo errexit**: un comando que en el servidor aborta a mitad, aquí llegaba al final y devolvía 0. Cambiadas todas a `run cmd; r=$?`, y el aviso escrito en `lib.sh` junto a la función.

#### Lo que aparecía al encender errexit de verdad

Dos pruebas se cayeron en cuanto el harness dejó de mentir, y las dos eran bugs de verdad. La misma raíz: **`pipefail` + una asignación**.

`orbit restore` sobre un fichero que no es una copia salía con **código 2 y sin una sola línea**. `name="$(_restore_name "$file")"` — con `pipefail`, un `tar` que falla hace que la tubería salga con su código, la asignación lo hereda y errexit mata a orbit **antes** de llegar al `die` que explica qué pasa. El mensaje estaba escrito y era inalcanzable.

#### `orbit status` se comía la entrada estándar

```
  ●
  ● 15
  ●
  ● 0
  ● web    web.test (estática)
```

Eso son las teclas que se pulsaban después, pintadas como si fueran servicios. Al refactorizar `cmd_status` para compartir la lista con el JSON (§13.1), el `for s in nginx postgresql …` se convirtió en un `while read -r s` **y se quedó sin su `< <(_base_services)`**. Un `while read` sin redirección lee de stdin: la sección de servicios salía vacía —una sección que no dice nada y que nadie echa de menos— y de paso se tragaba lo que viniera detrás.

Dos síntomas de un carácter que falta, y ninguno de los dos habría salido en una prueba unitaria: la lista vacía no rompe nada, y para ver lo de stdin hace falta que haya algo detrás en la entrada. Un menú lo hay siempre.

### 20.8 El contrato JSON, consumido como lo haría un cliente

La prueba no fue mirar la salida: fue **escribir un cliente que no lee ni una línea de texto** —comprueba la versión del contrato, saca el inventario, decide a qué apps les falta certificado, lee el diagnóstico y los recursos— y ver si le llega todo lo que necesita. Encontró tres fallos, y los tres son de la misma familia: **el modo JSON contando algo distinto de lo que cuenta el modo texto**.

#### Un adorno delante del objeto

`orbit watch status --json` empezaba por `✔ Temporizador activo` y **luego** el JSON. Es decir, `orbit watch status --json | jq` daba un error de sintaxis. La regla de §13.1 —por la salida normal no va nada que no sea el JSON— rota por una línea decorativa.

Callarla no bastaba: esa línea es un dato, y el cliente se quedaba sin saber si el vigilante está encendido. Un panel que no pueda distinguirlo pinta en verde sobre una vigilancia apagada, porque los sujetos que enseña son historia y no estado. Así que la línea se calla en JSON **y** aparece como `timer_active`. El contrato admite campos nuevos; para eso está la regla de que se añaden y no se renombran.

#### «No he podido preguntar» no es «no hay ninguna»

El peor de los tres. Con PostgreSQL apagado:

```
$ orbit db list            → error de psql, código 2
$ orbit db list --json     → {"schema":1,"databases":[]}, código 0
```

El bucle se alimentaba directamente de la consulta con `2>/dev/null`, así que un servidor caído daba cero filas y eso se imprimía como una lista vacía. Las dos formas del mismo comando contaban cosas distintas, y la de las máquinas contaba la peligrosa: un script de copias que lea «no hay bases de datos» concluye que no hay nada que salvar y termina satisfecho.

La consulta va ahora a una variable **antes** de imprimir nada, para poder mirar si funcionó. Si no, se aborta como sin `--json`: error por `stderr`, código distinto de cero y **nada** por la salida normal. Un objeto vacío es una respuesta; un objeto vacío inventado es una mentira.

#### El mensaje que le dice a un cliente qué existe

Cuando se pide `--json` a un comando que no lo habla, el mensaje enumeraba «list, info, status, doctor, env list y top» — cuatro de los nueve que en realidad lo tienen. Quien probara `orbit db list --json` y leyera esa respuesta concluiría que no existe.

Dos listas separadas, la de siempre. Ahora el texto vive en `JSON_CMDS_HELP`, pegado al reconocedor, y hay una prueba que las cruza: cada comando que `_json_capable` acepta tiene que aparecer en el mensaje. Es el mismo remedio que `ORBIT_APP_FIELDS` (§8) y que el vhost por defecto (§19.3): cuando algo se puede escribir en dos sitios, o se escribe en uno o hay una prueba que los ata.

#### Lo que salió bien, y por qué merece decirse

Los diez comandos con `--json` devuelven JSON válido y `schema: 1`, con `--json` delante o detrás del comando. Ninguno se cuela una secuencia ANSI. Los catorce comandos que no lo hablan **se niegan** en vez de ignorarlo, que era la decisión de §13.1 y sigue en pie. `top --json` sin `--once` no se queda esperando: en modo máquina, una foto. Los casos raros —un `.env` vacío, una app recién creada sin desplegar, cero redirecciones— dan colecciones vacías y no errores. Y los `null` que aparecen son los correctos: una app estática no tiene CPU ni memoria porque no tiene proceso, y decir `0` ahí sería inventarse un dato.

### 20.9 El tic verde que salía de otro color, y de otro ancho

Llegó de alguien mirando su terminal: donde tenía que haber un tic verde había «un icono raro». En la misma pantalla, el resumen de `orbit new` sí pintaba un tic normal. Dos glifos con la misma función, distintos en la misma sesión: eso no es la fuente del usuario, es el carácter.

`ok()` usaba **`✔` U+2714 HEAVY CHECK MARK** y `orbit new` usaba **`✓` U+2713 CHECK MARK**. La diferencia no está en el dibujo: está en que **U+2714 figura en `emoji-data`** y U+2713 no. Un carácter que aparece en esa lista lo reclama la fuente de emoji en color —Noto Color Emoji en la mayoría de los Ubuntu—, y fontconfig se lo cede aunque la monoespaciada lo tuviera. A partir de ahí pasan dos cosas, y las dos son fallos:

- **Se pierde el color.** El `${GRN}` de delante no lo toca: un emoji lleva su propio verde metido en la fuente. Así que el tic «verde» era verde de otro verde, y `NO_COLOR=1` no lo apagaba.
- **Se pierde la columna.** El emoji ocupa dos celdas. Todo lo alineado detrás con `printf '%-18s'` —la lista de apps, el estado del vigilante— quedaba corrido una posición, y sólo en las líneas que llevaban tic.

Lo mismo con **`✖` U+2716**, que también está en la lista. Y un tercero por otro motivo: **`⎇` U+2387 ALTERNATIVE KEY SYMBOL** no es emoji, pero DejaVu Sans Mono —la monoespaciada por defecto de casi cualquier servidor— no lo trae, así que el selector de rama empezaba con un cuadrado vacío.

El arreglo es una **tabla de glifos** al lado del bloque de color, y ningún símbolo escrito a mano en un `printf`. Los que quedan (`✓ ✗ · ● ○ ◐ → ▸ » ✎ ❯ ◆`) tienen dos cosas en común: ninguno está en `emoji-data`, y todos los trae una monoespaciada corriente.

De paso resuelve el caso que estaba justo debajo: **una terminal que no habla UTF-8**. Un `LANG=C` por SSH —lo que trae un VPS recién creado hasta que alguien genera las locales, y precisamente donde se ejecuta `install.sh`— convierte cada símbolo de tres bytes en tres borrones, y el logotipo de bloques en seis líneas de basura. `_ui_unicode()` mira la misma variable que mira la libc (`LC_ALL`, `LC_CTYPE`, `LANG`, en ese orden) y, si no dice UTF-8, la tabla entera se cambia por ASCII de siete bits: `+ x ! . * o ~ -> > > * > * -`. No es bonito; se lee, que es lo que hacía falta. `UI_GLYPHS=unicode|ascii` lo decide a mano para los casos raros —un contenedor que pinta UTF-8 con `LANG` sin poner, o al revés.

Lo que la tabla **no** cubre, y se dice aquí para que nadie lo descubra a base de mirar: los `·` y los guiones largos que están dentro de las frases. Son parte del texto, no de la interfaz, y salen mal igual que los acentos. Arreglar eso de verdad es generar las locales, no cambiar un glifo.

La prueba que lo fija (`tests/ui_test.sh`) no comprueba «hay un tic», que es lo que se escribiría solo. Comprueba **que no vuelva a colarse ninguno de los dos que son emoji**, ni en `orbit` ni en `install.sh`, y que en la rama ASCII no salga ni un byte por encima de 0x7F. Es la misma forma de las de §19.3 y §20.8: cuando el fallo es «se usó lo que no tocaba», la prueba tiene que mirar lo que no tocaba, no lo que sí.

**Y la tabla tiene un segundo modo de fallo, que no es cosmético: usar un nombre que no está en ella.** El mismo cambio que trajo la tabla dejó `"$G_SEP"` en el banner de `install.sh` sin declararlo al otro lado. Con `set -u` eso no pinta mal: **mata**. Y la línea del banner corre justo después de comprobar que eres root, así que el instalador abortaba antes de tocar un paquete, en cualquier terminal y en los dos idiomas — un símbolo suelto convertido en «no se puede instalar Orbit». Ninguna prueba lo alcanzaba porque `install_test.sh` **extrae funciones sueltas** para no instalar al cargar el script, y el banner no era ninguna de ellas.

El arreglo de la clase, y no del nombre, son dos comprobaciones: el cruce de todos los `G_*` que cada script **usa** contra los que **declara** —en `install_test.sh` para el instalador, en `ui_test.sh` para `orbit`— y el banner **ejecutado de verdad**, con la tabla real y `set -u` puesto, en los dos caminos del logotipo. La regla que queda vale para cualquier tabla de este estilo: una variable de presentación que sólo se lee en un `printf` no falla donde se lee, falla donde no se declaró, y quien la busca a ojo la encuentra el día que un servidor se queda sin instalar.

---

## 22. `orbit init`, y por qué es el único comando sin root

El descriptor `orbit.json` existe desde antes (§18.9b, §13.x): permite que un repositorio declare qué es y cómo se despliega, y **manda sobre la detección**. `orbit init` es su reverso — escribe uno con lo que la detección encuentra — y por eso las dos funciones tienen que leerse juntas: si alguien añade una clave a `_read_descriptor` y no la ofrece aquí, el comando escribe un fichero que describe menos de lo que el despliegue entiende; si la ofrece aquí y no la lee allí, escribe un fichero que promete algo que no ocurre. La prueba del ida y vuelta (`init_test.sh`) es lo que mantiene honestos a los dos lados.

**No se auto-eleva a root, y es el único.** Todo lo demás en Orbit toca el servidor: la configuración, las unidades, los vhosts, y por eso el script se eleva solo en cuanto arranca. `init` escribe dentro del repositorio de quien lo ejecuta, así que elevarse sería peor que inútil: dejaría un `orbit.json` de root en su checkout, y a partir de ahí haría falta `sudo` hasta para borrarlo. Por lo mismo tampoco exige que Orbit esté instalado — se ejecuta dentro de un proyecto, que es justo donde puede no estarlo.

La decisión se toma **antes** del `sudo`, con `_first_word`, que devuelve el primer argumento que no es una opción. Reconoce las opciones que llevan valor (`--lang en`) porque confundir ese valor con el comando dejaría a `orbit --lang init deploy …` saltándose la elevación de un comando que sí la necesita. Es una función de cinco líneas con su sección de pruebas propia, y lo merece: está en el camino que decide quién corre como root.

**Con `--force`, el descriptor que se reescribe no participa en su propia regeneración.** `detect_stack` termina leyendo el `orbit.json` de la carpeta —es lo correcto en cualquier otro contexto, porque una declaración manda sobre una inferencia—, pero regenerando produce un híbrido: el tipo, el arranque y la carpeta web del fichero viejo con el build recién detectado, que no describe ni el proyecto ni lo que había antes. `DETECT_IGNORA_DESC` guarda **la ruta concreta** que hay que ignorar y no un sí/no, porque en un monorepo el descriptor de una subcarpeta sigue siendo una declaración válida y tiene que seguir mandando.

**Se niega a congelar la rama de repuesto.** Cuando la detección no reconoce nada deja `type=static` con la raíz como carpeta web —lo correcto para un sitio que es HTML, y «publica el código fuente» para cualquier otra cosa (§18.8)—, y hoy avisa de ello en cada despliegue. Escribir eso en el `orbit.json` sería peor que dejarlo pasar: como el descriptor pisa a la detección, **el aviso no volvería a salir nunca** y la decisión quedaría tomada para siempre sin que nadie la tomara. Así que si no se reconoció nada y no hay `index.html` en la raíz, `init` aborta y pide que se escriba el `type` a mano. Un sitio HTML de verdad sí pasa: ahí servir la raíz es la respuesta correcta, y negarse sería negarle el comando al caso más simple que existe.

---

## 21. El idioma, y por qué la clave es la propia frase

Orbit habla el idioma de quien lo está usando. El código está escrito en español —esa es la regla de siempre: mensajes de usuario en español, código y commits en inglés— y los demás idiomas son un catálogo que traduce cada frase.

### 21.1 La clave es el texto, no un nombre inventado

Lo primero que se descarta es lo que hace casi todo el mundo: claves simbólicas.

```bash
die "err.app_missing" "$n"          # ← lo que NO se hace
die "La app '%s' no existe." "$n"   # ← lo que se hace
```

Tres motivos, y ninguno es de gusto:

**Un mensaje sin traducir tiene que seguir siendo una frase.** Con claves simbólicas, un hueco en el catálogo saca `err.app_missing` por pantalla, que no es un error: es un fallo del programa asomando. Con la frase como clave, un hueco saca la frase en español, que es exactamente lo que salía antes de que existieran los idiomas.

**La llamada sigue diciendo lo que va a salir.** Quien lee `die "La app '%s' no existe. Mira 'orbit list'." "$n"` sabe qué ve el usuario sin abrir otro fichero. Con una clave hay que ir a buscarla, y a los seis meses nadie lo hace.

**No hay dos sitios que se puedan desincronizar.** Es la misma regla que `ORBIT_APP_FIELDS` (§8), el vhost por defecto (§19.3) y `JSON_CMDS_HELP` (§13): cuando algo se puede escribir en dos sitios, o se escribe en uno o hay una prueba que los ata. Aquí hay las dos cosas — el texto se escribe una vez, y `tests/i18n_test.sh` compara el catálogo con lo que hay de verdad en el código.

Es el modelo de gettext, sin gettext: `msgid` = la cadena original. Lo que no se copia de gettext son sus ficheros `.mo` binarios, que romperían el principio 5.

### 21.2 Por qué las variables salen fuera de la frase

Este es el cambio que tocó cuatrocientas líneas, y no había forma de evitarlo:

```bash
die "La app '$n' no existe."        # antes
die "La app '%s' no existe." "$n"   # ahora
```

Con la variable dentro de las comillas, lo que le llega a la función no es una frase sino «La app blog no existe», y no hay catálogo capaz de encontrar eso. El texto tiene que ser un formato de `printf` y las partes variables argumentos suyos. Las funciones de siempre —`ok`, `info`, `warn`, `err`, `die`, `title`, `hint`— cambiaron de recibir `"$*"` a recibir un mensaje y sus argumentos, así que los mensajes sin partes variables, que son la mitad, no hubo que tocarlos.

Dos efectos secundarios que conviene conocer:

- **Un `%` literal ahora se escribe `%%`.** Es lo que pide `printf`. Si se olvida, ese `%` se come el argumento siguiente y pinta cualquier cosa. La prueba busca las directivas que no son `%s` ni `%%`.
- **Un mensaje que no es una frase sino el contenido de una variable se pasa con formato explícito:** `info "%s" "$msg"`. El diagnóstico guarda sus mensajes para pintarlos luego, y sin el `%s` un `%` dentro del valor sería una directiva. Es el único sitio donde hace falta acordarse.
- **`_t` no formatea cuando no le pasan argumentos**, y eso no es una optimización. Hay funciones que no admiten argumentos detrás del mensaje —`spin` lleva el comando, `choose` lleva los elementos— así que su texto se compone antes con `"$(t …)"`. Formatear esa segunda vez es reinterpretar como formato un texto que ya es un resultado, y ahí dentro puede haber cualquier cosa: el comando de build del repositorio, un nombre de rama, una URL con `%XX`. Costaba esto, **en silencio**: con `A_BUILD='sh build.sh --tag 50%-done'` el spinner escribía `sh build.sh --tag 500one`, porque `%-d` es una directiva válida. Con un `%V` se filtraba `printf: invalid format character` al usuario. La regla que lo sostiene —y que comprueba la suite— es que **un mensaje con un `%` lleva siempre un `%s`**, o sea que siempre se le pasan argumentos.

Y un detalle que costó cuatro pruebas del contrato JSON: `printf -v` necesita `--` delante del formato. Hay mensajes que empiezan por guión —«--lines quiere un número», «--json sólo está en…»— y sin el `--` printf los toma por opciones suyas, se queja y devuelve 2. Los comandos que morían con uno de esos pasaron de salir con código 1 a salir con 2 sin que cambiara nada más.

### 21.3 Los colores son marcas, no variables

```bash
info "Actualízalo ${B}en tu máquina${R}, y súbelo:"   # ← rompe la clave
info "Actualízalo {b}en tu máquina{r}, y súbelo:"     # ← así
```

`${B}` se expande **antes** de que la función vea nada, así que la clave sería distinta según haya color o no: la misma frase serían dos entradas de catálogo, y en un terminal sin color no encontraría ninguna. Las marcas `{b}` `{d}` `{r}` y los siete colores se sustituyen dentro de `_t`, después de buscar en el catálogo. De paso son traducibles: quien traduce puede moverlas o quitarlas, y no tiene que saber qué es `$GRY`.

La sustitución sólo ocurre si el mensaje trae una `{`, así que las nueve cuartas partes de los mensajes no pagan nada por ella.

### 21.4 De dónde sale el idioma

De lo más concreto a lo más general:

| | Alcance |
|---|---|
| `orbit --lang en <comando>` | sólo esa orden |
| `ORBIT_LANG=en` en el entorno | esa sesión |
| `ORBIT_LANG="en"` en `/etc/orbit/orbit.conf` | ese servidor |
| `LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LANG` | quien esté mirando |
| `/etc/default/locale`, `/etc/locale.conf` | el sistema, cuando no hay entorno |
| español | el idioma fuente |

Que la configuración de Orbit vaya **por delante** del idioma del sistema es deliberado. La configuración es una decisión que alguien tomó sobre Orbit; el `LANG` de una sesión es ambiente. Si un servidor se instaló en inglés, que un administrador entre con `LANG=es_ES` no debería cambiarle el idioma a los avisos que le llegan a todo el equipo — y quien quiera leerlo en el suyo tiene la bandera y la variable de entorno.

Los dos ficheros del sistema no son un adorno: los sitios donde Orbit habla solo —el temporizador de vigilancia, el autodespliegue, una línea de cron— arrancan con el entorno vacío, y ahí «no hay `LANG`» no significa que nadie tenga idioma. Se leen con `grep` y no con `.`, porque son ficheros que edita cualquiera y sourcearlos sería ejecutar lo que haya dentro **como root**.

`C` y `POSIX` no cuentan como inglés. Son «ningún idioma», y tomarlas por inglés le cambiaría el idioma a medio servidor por el simple hecho de correr dentro de un cron.

### 21.5 La auto-elevación se lleva el idioma consigo

`orbit` se auto-eleva con `exec sudo -- "$0" "$@"`, y sudo rehace el entorno. `LANG` y `LC_*` sobreviven porque vienen en el `env_keep` que sudo trae de fábrica, pero `ORBIT_LANG` no, y una preferencia que se evapora al elevarse es peor que no tenerla. Se pasa como bandera:

```bash
[[ -n "$ORBIT_LANG_ENV" ]] && exec sudo -- "$0" --lang "$ORBIT_LANG_ENV" "$@"
```

Una bandera no depende de cómo esté escrito el sudoers de cada servidor, que es exactamente lo que no se puede dar por supuesto.

Por eso el núcleo de idiomas vive **antes** del bloque de elevación en el fichero: los dos primeros mensajes que puede dar Orbit —«necesita privilegios de root» y «no está instalado todavía»— salen antes de que exista el catálogo grande, y un mensaje de arranque en el idioma equivocado es justo el que peor se entiende. Esos tres los lleva `_i18n_boot`, que cabe en diez líneas; el catálogo entero se carga en `main`.

### 21.6 Lo que no se traduce, y por qué

La línea es: **lo que Orbit le dice a una persona se traduce; lo que escribe para otro programa, no.**

- **`/var/log/orbit/orbit.log`** se queda en español. Es un registro que se lee meses después y se filtra con `grep`; un fichero con tres idiomas mezclados según quién ejecutara cada orden es peor que uno en un idioma que no es el tuyo.
- **Los vhosts y las unidades de systemd** que Orbit genera llevan sus comentarios en español. Los consumen nginx y systemd; el comentario es incidental, y hacerlo depender del idioma de quien desplegó haría que el fichero cambiara de contenido sin que cambiara nada de verdad.
- **Los nombres de campo del JSON** no se tocan nunca, que es el contrato de §13. Sus **valores** en prosa —`error`, por ejemplo— sí siguen el idioma: son texto para una persona, y quien automatiza tiene `ok`, `failed_step` y el código de salida.
- **`install.sh` sí se traduce**, y sin copiar nada. Ver §21.6b.

### 21.6b El instalador comparte el mecanismo, no el texto

`install.sh` habla antes de que exista `/usr/local/bin/orbit`, así que no puede llamarlo. La tentación es copiarle el núcleo: son sesenta líneas, y dos copias de «qué idioma toca» se separan a la primera vez que alguien arregle un caso raro en una sola.

Lo que hace es sacarlo de `orbit`, que está al lado —hace falta de todas formas, el instalador no puede instalar nada sin él— entre dos marcas:

```bash
# >>> núcleo de idiomas · compartido con install.sh
…
# <<< núcleo de idiomas
```

No es una técnica nueva en este repositorio: `tests/lib.sh` lleva desde el principio cargando `orbit` entero menos su última línea. Lo que se comparte es el mecanismo; **el catálogo es suyo**, porque el instalador y `orbit` no dicen las mismas frases y compartir el texto no significaría nada.

Si el fichero no está o las marcas han desaparecido, el instalador cae a un `t` que es la identidad y se queda en español. Sin idioma se instala igual; sin `orbit` no, y de eso se ocupa el `die` de las comprobaciones. Hay una prueba que carga el trozo extraído a solas y comprueba que trae las ocho funciones y que resuelve.

**Y de aquí salió un fallo de verdad.** La condición era ésta:

```bash
if [[ -r "$SCRIPT_DIR/orbit" ]] && sed -n '/marca/,/marca/p' "$SCRIPT_DIR/orbit" | grep -q '^_lang_resolve() {'; then
```

Con `pipefail`, eso **nunca** es cierto. `grep -q` sale corriendo en cuanto encuentra la línea y cierra la tubería; `sed` recibe un SIGPIPE y muere con 141; `pipefail` se queda con el 141 y la condición falla. El instalador se quedaba en español para todo el mundo **sin decir nada**, que es la peor forma de fallar: no hay error, no hay traza, sólo un idioma que no es. Es la misma trampa de §10 con otro disfraz, y la lección es la de siempre: `pipefail` convierte «este comando terminó antes» en «esto ha fallado».

Ahora el trozo se saca a una variable y se comprueba dentro de bash, sin tuberías. Y la prueba no mira la condición: ejecuta la cabecera del instalador con `LANG=en_US.UTF-8` y comprueba que sale una frase en inglés, que es lo único que no se puede fingir.

### 21.7 Las dos pantallas que se traducen enteras

La ayuda (`usage`), el cuerpo del menú, las siete pantallas de `--help` por comando y el resumen final del instalador no pasan por el catálogo: hay una versión por idioma de cada una.

Son dos columnas alineadas a mano. Traducidas frase a frase, cada rótulo cambiaría de largo y la alineación se perdería sin que nadie lo viera hasta ejecutarlo. Escritas enteras, quien traduce las vuelve a alinear y ve el resultado de una vez. Es la excepción que confirma el criterio: el catálogo es para frases, no para maquetas.

### 21.8 Los rótulos que después se comparan

Tres selectores enseñan una lista y luego reconocen lo elegido comparando con el texto que enseñaron. Eso funciona mientras el idioma sea uno solo, y deja de funcionar en cuanto hay dos:

```bash
sel="$(choose 'Origen' 'Elegir un repo de mi GitHub' 'Escribir la URL')"
if [[ "$src" == "Elegir"* ]]; then     # ← en inglés no entra nunca
```

Se arregla guardando el rótulo traducido en una variable y comparando contra ella. Donde el reconocimiento es por un símbolo de delante —`⎇` la rama, `#` un PR— el símbolo se queda **fuera** del catálogo, para que ninguna traducción pueda llevárselo. Hay una prueba que lo comprueba.

### 21.8b Lo que el catálogo no ve, y la prueba que lo mira

Las comprobaciones de cobertura miran el **catálogo**: sacan del código todos los mensajes que pasan por `_t` y los cruzan con las claves. Eso deja un punto ciego enorme y evidente en cuanto se dice en voz alta: **lo que nunca llamó a `_t` no existe para ellas**.

Ahí se coló que `orbit list`, `orbit info` y `orbit status` salieran en español con `--lang en`. Eran `printf` crudos —`  Carga       %s`, `  Memoria     %s`— que el extractor no veía y que ninguna comprobación echaba de menos, porque para echar algo de menos hay que saber que existe. Un barrido manual tampoco los cazó: buscaba frases de dos palabras o más, y son etiquetas de una.

La prueba que sí lo caza no mira el código: **ejecuta cada comando en los dos idiomas y exige que la salida cambie**. Las líneas que legítimamente coinciden —`Host`, `Uptime`, `SSL`, los datos— se declaran a mano, así que una frase nueva sin traducir aparece por su nombre. No compara contra un texto fijo a propósito: eso obligaría a tocar la prueba cada vez que alguien mejora una frase, y una prueba que estorba acaba desactivada.

La lección general, que vale para cualquier cobertura: **una comprobación construida a partir del propio mecanismo sólo puede ver lo que usa el mecanismo.** Para ver lo que se le escapa hace falta mirar el resultado, no el camino.

### 21.9 Qué comprueba `tests/i18n_test.sh`

Lo que se ve a simple vista no hace falta probarlo. Lo que se prueba es lo que falla en silencio:

- **Que el catálogo no se quede atrás.** Se sacan del código todos los mensajes que pasan por `_t` —leyendo bash de verdad: comillas anidadas, `"$(…)"` dentro de la cadena, continuaciones de línea— y se cruzan con las claves del catálogo. Una clave que ya no está en el código es una frase que alguien cambió sin tocar la traducción: la vieja no se va a usar nunca más, y nadie se enteraría porque sale la española. Al revés no es un fallo, pero la lista de las que se escriben igual en los dos idiomas está escrita a mano, así que una frase nueva sin traducir aparece por su nombre.
- **Que las traducciones sepan `printf`.** Misma cuenta de `%s` en los dos lados, ningún `%` suelto, mismas marcas de color y ninguna inventada. Un `%s` de menos deja un hueco; uno de más pinta basura.
- **Que la salida cambie de verdad de idioma**, ejecutando los comandos. Ver §21.8b.
- **Que la clave del código sea byte a byte la del catálogo.** El extractor convierte los saltos de línea reales en `\n` para poder listar un mensaje por línea, y eso hacía que un mensaje escrito con un salto de verdad pareciera igual que su clave escrita con `\n` —dos caracteres—. No lo era: el catálogo no lo encontraba nunca, y las dos comprobaciones de cobertura lo daban por bueno. Ahora se busca cada mensaje en el array de verdad.
- **Que ningún mensaje lleve un `%` sin llevar también un `%s`.** Es la regla que sostiene que `_t` no formatee cuando no hay argumentos, y con ella que `"$(t …)"` sea seguro en cualquier posición.
- **La precedencia entera**, con los cinco orígenes, incluido que un idioma que no existe no deje a Orbit sin arrancar — ni siquiera al elevarse a root, donde la variable de entorno se convierte en bandera y las banderas sí se validan.
- **Que `C` y `POSIX` no sean inglés**, que es el error que dejaría medio servidor hablando otro idioma desde un cron.

La parte que lee el código necesita `python3`. Sin él la suite lo dice y se salta esa parte, y `make test-strict` —lo que ejecuta CI— falla por haberse saltado algo, que es la regla de §11.

### 21.10 Añadir un idioma

1. Añadir el código a `ORBIT_LANGS`.
2. Escribir `_i18n_xx()` copiando `_i18n_en()`, y traducir. Lo que falte sale en español.
3. Añadirlo al `case` de `_i18n_load`.
4. Escribir `_usage_xx` y `_menu_body_xx`.
5. En `install.sh`, añadir la rama al `case` de su `_i18n_load` y escribir `_resumen_xx`.
6. `make test` — el cruce del catálogo dirá qué sobra, en los dos ficheros.

El catálogo vive dentro de `orbit` y no en un fichero al lado a propósito: `install.sh` copia **un** fichero, y un idioma que dependa de otro fichero es un idioma que se pierde en cuanto alguien copia `orbit` a mano a otro servidor, que es exactamente lo que la gente hace.

---

## 23. Debian 12, y los tres sitios donde «casi igual» no era igual

Hasta la v1.3.0 el instalador decía Ubuntu 24.04 y el ROADMAP decía «Debian 12 debería funcionar casi tal cual». Auditarlo dio tres diferencias, y ninguna de las tres se parece a la que uno esperaría: no fue el gestor de paquetes ni la ruta de nginx —Debian y Ubuntu comparten empaquetado— sino **tres cosas que en Ubuntu llegaban solas**.

Desde la v1.3.3 sí se ha instalado de principio a fin en una máquina Debian con systemd, y lo que sigue cuenta las tres diferencias en el orden en que se supieron: primero auditadas contra los metadatos del archivo (v1.3.0), luego confirmadas por un contenedor de CI (v1.3.1) y por fin ejecutadas sobre hierro (v1.3.3). Merece la pena leerlo así porque **cada escalón encontró algo que el anterior no podía ver**, y el último encontró el más caro de todos (§23.6).

### 23.1 El pocket se llama al revés en cada distribución

El aviso de los pockets de apt (§10) existe porque una imagen sin `-security` no recibe parches aunque tenga unattended-upgrades puesto. Estaba escrito mirando `a=`, y eso es correcto en Ubuntu e **inerte en Debian**. Comprobado descargando los ficheros `Release` de los dos archivos:

| | `Suite:` (sale como `a=`) | `Codename:` (sale como `n=`) |
|---|---|---|
| Ubuntu `noble-security` | `noble-security` | `noble` |
| Debian `bookworm-security` | `oldstable-security` | `bookworm-security` |

**Cada una pone el dato en el campo que la otra deja fijo.** En Debian no existe ningún `a=bookworm`, así que la guarda del pocket base cortaba antes de mirar nada: el aviso no podía salir jamás, en la distribución donde más falta hace, y sin dar señal de estar apagado. Ahora se acepta cualquiera de los dos campos.

Y hay un motivo para no arreglarlo con `a=oldstable`, que es el atajo que parece obvio: **el `Suite:` de Debian se mueve solo**. Bookworm es `oldstable` hoy, era `stable` hace dos años y será `oldoldstable` sin que nadie toque nada. El codename es lo único que no cambia. Una comprobación escrita sobre el suite habría funcionado hasta la release siguiente de Debian y habría fallado sin tocarla nadie, que es la peor forma de caducar.

El campo se compara **entero**, envolviendo la política en comas: `bookworm` es subcadena de `bookworm-updates`, y con una comparación floja una máquina con sólo el pocket de actualizaciones daría el base por presente.

### 23.2 La versión de PHP no se sabe, se pregunta

`PHP_VER=8.3` era el único motivo real por el que el instalador no valía para Debian 12, que va por 8.2: doce `apt-get install php8.3-*` que allí no resuelven, o sea el paso entero al suelo. La tentación es una tabla de distribución a versión; caduca en la siguiente. El metapaquete `php-fpm` ya lo declara y lo mantiene otro:

```
Ubuntu 24.04   php-fpm 2:8.3+93ubuntu2   Depends: php8.3-fpm
Debian 12      php-fpm 2:8.2+93          Depends: php8.2-fpm
```

Un `PHP_VER` puesto en el entorno sigue ganando —así se instala contra un repositorio de terceros como Sury sin tocar el script— y si apt no contesta se sigue con el valor de cabecera en vez de abortar, porque esto es un paso del instalador y no una comprobación de seguridad. La versión elegida sale en la línea del paso, que es donde la va a buscar quien dude.

### 23.3 Lo que en Ubuntu venía en el paquete y en Debian no

Dos paquetes que en Ubuntu llegaban de rebote:

- **`sudo`.** No está en una Debian mínima: el instalador de Debian lo omite si le das contraseña de root. Y `orbit` se auto-eleva con `sudo` y ejecuta todos los builds con `sudo -u`, así que sin él no hay producto — y el fallo aparecería en el primer despliegue, lejos de aquí.
- **`python3-systemd`.** Lo necesita el `backend = systemd` de fail2ban, que es el correcto en una máquina cuyo sshd escribe en el journal. En Ubuntu es un `Depends` de fail2ban; **en Debian 12 sólo un `Recommends`**, así que una imagen instalada con `--no-install-recommends` —lo normal en las de nube— se quedaba sin él y fail2ban no arrancaba.

Y de ahí salió lo que de verdad importaba, que no es de Debian: los dos `systemctl` de fail2ban llevan `|| true` a propósito, para que un fallo ahí no tumbe la instalación entera, y justo después el instalador imprimía **«✔ fail2ban vigilando SSH» pasara lo que pasara**. Es la mentira de `notify test` de la v1.2.7 otra vez, en el paso que endurece el servidor. Ahora se pregunta `systemctl is-active` y, si no está en pie, se dice y se apunta dónde mirar. **Instalar un paquete no es tener un servicio funcionando**, y sólo lo segundo es lo que se anuncia.

### 23.5 Lo que un contenedor sí cierra, y por qué no es lo mismo que un VPS

Desde la v1.3.1 CI corre un segundo trabajo en `debian:12`. No es la instalación entera —eso sigue pendiente— pero contesta cuatro preguntas que **desde una máquina Ubuntu son literalmente incomprobables**, y las contesta el sistema y no un doble:

- **La suite entera pasa en Debian**, con `php8.2-fpm`.
- **`apt` de verdad dice 8.2** cuando se le pregunta qué PHP sirve. Hasta entonces eso lo afirmaba un `apt-cache` doblado, que es exactamente la clase de prueba que confirma lo que ya creías.
- **El aviso de pockets calla en un Debian bien configurado.** Es la medición en reposo, la que faltaba: la versión anterior de esa comprobación era inerte en Debian, y **por eso nadie la vio fallar nunca**. Un doble sólo demuestra que la lógica es correcta; esto demuestra que aquí dice lo que tiene que decir.
- **Los paquetes del instalador resuelven**, con `apt-get install --dry-run` sobre la lista entera y el `php${PHP_VER}-*` derivado de apt. Es el fallo original —doce paquetes inexistentes— y ya no puede volver en silencio.

Una nota sobre el privilegio, porque el reflejo es al revés: el contenedor corre **como root**, y eso no es algo que se tolere sino la condición que hace falta. `php-fpm` sólo baja de usuario si lo arranca root (§11), así que es el único camino donde la sección del aislamiento entre apps PHP demuestra algo. Se comprobó antes en local que la suite entera da lo mismo como root, para que un rojo allí signifique «Debian» y no «root».

### 23.4 Lo que sólo contestó la máquina

Eran tres cosas, y ninguna se puede afirmar desde una suite de pruebas ni desde un contenedor. Medidas en la v1.3.3 sobre una Debian 12 con systemd, partiendo de una instalación de escritorio sin `make`, sin `nginx`, sin `rsync` y sin `node`:

- **Los trece pasos terminan.** PHP 8.2 elegido preguntándole a apt de verdad, PostgreSQL 15.19, y fail2ban vigilando SSH de verdad —`Journal matches: _SYSTEMD_UNIT=sshd.service`—, que es la comprobación que §23.3 añadió para no anunciar un servicio muerto.
- **systemd levanta una app real.** Unidad activa y habilitada, corriendo como su propio usuario (`orbit-hola`, uid 994), con `ProtectHome=true` y el `HOME` redirigido dentro del directorio de la app —el arreglo de §5.1, ejercitado aquí en Debian—, contestando directa y por nginx, con `NRestarts=0`.
- **unattended-upgrades instala.** Reconoce los tres orígenes de Debian, `bookworm-security` incluido. Pero eso solo no demuestra nada: con el sistema recién actualizado no hay nada pendiente, y **el instrumento marca cero igual si está roto**. Así que se degradó `curl` a la versión vieja a propósito y se ejecutó sin `--dry-run`: `deb12u5` → `deb12u15`, «All upgrades installed». Que una configuración sea válida y que instale son dos afirmaciones distintas, y la que faltaba era la segunda.

Y una diferencia con Ubuntu que conviene tener escrita: el `50unattended-upgrades` de Debian permite también `label=Debian`, o sea el pocket base, no sólo el de seguridad. No es un fallo —es la política que trae la distribución, y aquí no se toca porque las dos traen la suya bien puesta— pero significa que en Debian entran además las actualizaciones de los point releases.

### 23.6 El perfil de ufw abría un puerto y tapaba el que hacía falta

Esto es lo que encontró la instalación de verdad, y es de otra categoría que las tres de arriba: **no es una diferencia entre distribuciones, es un fallo que estaba también en Ubuntu**, y sólo se cayó del árbol porque Debian lo rompió de forma ruidosa primero.

El paso 12 decía `ufw allow OpenSSH`. En la máquina de pruebas no había `openssh-server` instalado, y ese perfil lo trae ese paquete —en las dos distribuciones igual, comprobado extrayendo los dos `.deb`—, así que ufw contestó «Could not find a profile matching 'OpenSSH'» y, con `errexit`, el instalador murió en el paso **12 de 13**: `orbit` no llegaba a instalarse. Debian trae además un perfil `SSH` genérico que Ubuntu no tiene, así que renombrarlo habría arreglado una distribución rompiendo la otra.

Lo caro apareció al mirar por qué fallaba. El perfil declara:

```
[OpenSSH]
ports=22/tcp
```

A pelo. Así que en un servidor con sshd en otro puerto —de lo primero que hace cualquier guía de endurecimiento— el paso 12 abría el 22, tapaba el suyo, y **anunciaba «UFW activo: sólo SSH, 80 y 443»**. No hay error en ningún sitio. La sesión abierta sobrevive porque ufw deja pasar lo ESTABLECIDO, así que quien instala no nota nada: se entera al reconectar, cuando ya no puede. Es la misma familia que el «fail2ban vigilando SSH» de §23.3 —anunciar lo que no se ha comprobado— pero con la consecuencia peor que tiene este proyecto: quedarte fuera de tu propio servidor.

Medido antes de creérselo, con sshd escuchando sólo en 2222 y un cliente en su propio espacio de red. Desde localhost no habría valido: ufw deja pasar `lo` entero y todo habría parecido abierto siempre, que es el error de medición de §5.2 otra vez. Y con una pasada en reposo, sin cortafuegos, para saber qué marca el instrumento cuando no hay nada que medir:

| | puerto 2222 (sshd de verdad) | puerto 22 |
|---|---|---|
| sin cortafuegos | conecta | rechazado (no hay nadie) |
| `ufw allow OpenSSH` | **TIMEOUT** | abierto, sin nadie detrás |
| puertos preguntados | conecta | — |

**El arreglo es preguntar en vez de suponer.** `_ssh_puertos()` une cuatro fuentes, de más a menos fiable: el `SSH_CONNECTION` de la sesión que está instalando —la única que no puede equivocarse sobre dejarte fuera, aunque sólo llega si se conserva el entorno—, los sockets que escuchan, `sshd -T` con los `Include` ya resueltos, y el `sshd_config` como último recurso, donde la ausencia de `Port` significa 22 porque es lo que haría sshd. Se **unen** y no se elige una: un puerto de más sólo abre donde SSH ya atiende; uno de menos deja a alguien fuera.

Si las cuatro callan, no hay servidor SSH instalado y nadie puede estar entrando por ahí: se enciende el cortafuegos y se dice. Abrir el 22 «por si acaso» sería abrir un puerto donde no atiende nadie, que es justo lo que el paso 12 viene a evitar.

Dos detalles que no son decoración:

- **Las reglas van antes del `enable`.** Entre el `default deny` y el `enable` no puede haber nada que falle; el fallo original ocurría ahí y no encendió el cortafuegos de milagro, por el orden. Hay una prueba que vigila que ese orden se mantenga.
- **El `|| true` va dentro de la función**, no en quien la llama. Sin coincidencias el `grep` final devuelve 1, y bajo `pipefail` la asignación se queda con ese 1: capturada no se nota, llamada directa mata el instalador. Es exactamente la trampa de §10, y la prueba la ejerce **sin capturar** dentro de un subshell con las banderas puestas, porque capturándola no vería nada nunca.

### 23.6b Y el mismo `ufw`, informando al revés

De la misma tanda y con la misma forma, pero del lado de los informes: `orbit status` decía `○ ufw (inactive)` con el cortafuegos filtrando.

`ufw enable` hace dos cosas —carga las reglas en el kernel en ese momento y deja la unidad habilitada para el arranque siguiente— y una que no hace: arrancar la unidad. Así que hasta el primer reinicio `systemctl is-active ufw` contesta `inactive` sobre un cortafuegos que está funcionando. Comprobado en la máquina recién instalada: `ExecMainStartTimestamp` vacío y las reglas de 2222, 80 y 443 puestas en la cadena `ufw-user-input`; y comprobado por el otro lado tras el reinicio de §5.5, donde la misma orden ya contesta `active`. **El estado engañoso es justo el de recién instalado, que es cuando más se mira `orbit status`.**

Es el «instalar un paquete no es tener un servicio funcionando» de §23.3 del revés: allí el paquete estaba y el servicio no; aquí la unidad no ha corrido y la cosa sí está en pie. A `ufw` se le pregunta a `ufw`, y con `LC_ALL=C`, porque traduce su salida y la comparación es contra ese texto — sin fijar el idioma, un servidor en otra lengua contestaría que no. No es de Debian: en Ubuntu pasa igual.
