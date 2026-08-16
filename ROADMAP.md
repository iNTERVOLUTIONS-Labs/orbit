# Roadmap

Hacia dónde va Orbit. Las fechas son intenciones, no promesas: esto lo mantiene gente en su tiempo libre.

Si algo de aquí te interesa especialmente, abre un issue y dilo. El orden se ajusta según lo que la gente pida de verdad.

**Leyenda:** ✅ hecho · 🚧 en marcha · 📋 planificado · 💭 en estudio

---

## v1.0 · Base sólida ✅

La versión que existe hoy.

- ✅ Instalador para Ubuntu 24.04 con nginx, Node 22, PostgreSQL, PHP 8.3, Python
- ✅ Detección automática de Next, Astro, Vite, CRA, Nuxt, Express, PHP y Python
- ✅ Despliegues atómicos con releases y symlink
- ✅ Rollback automático si falla el health check
- ✅ HTTPS por DNS-01 con Cloudflare
- ✅ Menú interactivo y CLI
- ✅ Bases de datos PostgreSQL con copia diaria
- ✅ UFW, fail2ban, systemd endurecido
- ✅ Restauración de IPs reales de Cloudflare
- ✅ Protección contra el bucle de redirecciones

---

## v1.1 · Lo que falta para el uso diario 🚧

Objetivo: que no tengas que salir de Orbit para nada rutinario.

- ✅ **`orbit port <app>`** — cambiar el puerto interno y reparar dos apps que se lo estén disputando
- ✅ **Suite de pruebas** — `make test` valida detección, puertos, vhost con nginx real y el ciclo de despliegue completo
- ✅ **`orbit deploy --all`** — actualizar todas las apps de una pasada, con resumen al final
- ✅ **Despliegue al hacer push** — resuelto **sondeando** con un temporizador, no con un endpoint. Un servidor de webhooks habría exigido un proceso escuchando en un puerto y superficie de ataque entrante; el sondeo cuesta un `git ls-remote` por app y no abre nada. Ver ARCHITECTURE §4
- ✅ **`orbit redirect`** — redirecciones de ruta y de dominio entero, con comodines y expresiones regulares
- ✅ **`orbit clone <app> <nuevo>`** — duplicar una app para montar un entorno de staging en `staging.midominio.com`. Hereda la configuración pero no los secretos, ni el certificado, ni el permiso de despliegue automático; las rutas absolutas se reapuntan a la copia y la app nace en mantenimiento para no contestar 502. Ver ARCHITECTURE §8.4
- ✅ **`orbit exec <app> <comando>`** — ejecutar algo dentro del contexto de la app, con su `.env` cargado. Imprescindible para migraciones de Prisma o Django.
- ✅ **`orbit env set|get|unset|list`** — editar variables sin abrir nano, y así poder usarlo desde scripts
- ✅ **Página de mantenimiento** — 503 con página de aviso, encendida por un fichero sin recargar nginx, y automática durante el reinicio del despliegue
- ✅ **Despacho de subcomandos unificado** — una sola regla para los ocho comandos que aceptan subcomando y app en el mismo sitio, y un argumento desconocido ya no se ignora en silencio. Ver ARCHITECTURE §8.3
- ✅ **`orbit logs --since`** — filtrar por tiempo sin recordar la sintaxis de journalctl, también en los logs de nginx. Obligó a añadir la marca de tiempo al formato de log, que no la llevaba. Ver ARCHITECTURE §8.5
- ✅ **Notificaciones** — Telegram, Discord, webhook genérico y correo por un relé SMTP tuyo, con filtro por nivel
- ✅ **`--json`** — salida legible por máquina en `list`, `info`, `status`, `doctor`, `top` y `env list`. Es el contrato del que cuelga cualquier interfaz: sin él, un panel acaba analizando tablas de texto y alinear una columna rompe cosas. Los campos se añaden, nunca se renombran. Ver ARCHITECTURE §13.1
- ✅ **`orbit new` sin preguntas** — cada dato se puede dar por argumento y `--yes` acepta los valores por defecto sin leer de la entrada. El asistente y el modo automático recorren el mismo código, para que no haya una mitad sin probar. Ver ARCHITECTURE §13.5
- ✅ **Recuperación de builds** — un fallo con firma conocida se arregla y se reintenta una vez, con lo aprendido guardado para el despliegue siguiente. Empezando por el que más duele: pnpm 11 bloqueando los scripts de instalación de `esbuild` o `sharp`. Ver ARCHITECTURE §14
- ✅ **Consejo cuando no hay arreglo** — lockfile desactualizado o ausente, disco lleno, versión de Node incompatible. No toca nada ni reintenta: dice qué significa el error y qué comando escribir. Ver ARCHITECTURE §14.5
- ✅ **Modo EVA** (`orbit --eva`) — el modo sin asideros: no decide nada solo, enseña los scripts del `package.json`, los PRs y los commits, y deja escribir el comando que quieras. El sencillo y el experto recorren el mismo código. Ver ARCHITECTURE §20.5
- ✅ **Elegir en vez de escribir** — la rama, el PR, el commit y el script que compila o arranca salen de una lista con búsqueda, en vez de teclearse de memoria. `orbit deploy --pick`, `--pr <n>`, `--ref <x>`
- ✅ **Un error ya no te tira a la shell desde el menú** — `die()` hace `exit`, y un `exit` no se caza con `|| true`. Ahora cada comando va en un subshell y se vuelve al menú. Ver ARCHITECTURE §20.1
- ✅ **`orbit new` no deja media app en silencio** — si el primer despliegue falla, el asistente cuenta qué existe, qué no y cuál es el siguiente comando. Ver ARCHITECTURE §20.2
- ✅ **Lockfile derivado: se resuelve la mitad que no llega a producción** — sólo altas, y sólo si todas son `devDependencies`. La frontera salió de medirlo, no de suponerlo: pnpm no reresuelve lo que no ha cambiado de especificador. Ver ARCHITECTURE §14.6
- ✅ **PHP dentro de una web estática** — el formulario de contacto de un Astro. Se detecta mirando el repositorio y se implementa como capacidad (`A_PHP`) y no como un tipo nuevo, para que los tipos no se multipliquen. De paso cierra una fuga: un `.php` en una estática se servía como código fuente. Ver ARCHITECTURE §15
- ✅ **`orbit backup` y `orbit restore`** — la configuración, el `.env`, las subidas y la base de datos de cada app en un `tar.gz` que se lee con `tar tzf`. El código no entra: está en git, que es mejor copia. Con `BACKUP_HOOK` para sacarlas del servidor sin que Orbit tenga que saber de S3. Ver ARCHITECTURE §17
- ✅ **`orbit restore --all`** — un servidor entero desde un directorio de copias, con la configuración global restaurada clave a clave: las preferencias vuelven, las rutas de esta máquina no. Ver ARCHITECTURE §17.5
- ✅ **El `www` sólo para dominios registrables** — a `blog.midominio.com` ya no se le propone `www.blog.midominio.com`, que no está en el DNS y puede tumbar la emisión del certificado. Ver ARCHITECTURE §16
- ✅ **Servidor por defecto también en el 443** — un dominio que no sirve nadie, o una app a la que aún no se le ha emitido el certificado, ya no acaban enseñando la web de la primera app desplegada. Se rechaza el saludo TLS, que es lo único honesto cuando no puede existir un certificado válido para ese nombre. `orbit nginx-rebuild` lo arregla en los servidores ya instalados y `orbit doctor` lo detecta. Ver ARCHITECTURE §19
- ✅ **El servidor vuelve solo tras un reinicio** — comprobado en la máquina de verdad, que es la única forma de comprobarlo: 34 verificaciones sobre el arranque en frío, 0 fallos y sin tocar nada, y repetidas a las dos horas para separar «arrancó» de «arranca y se muere en bucle», que `is-active` no distingue y el contador de reinicios sí. Lo que hace que funcione no es código de Orbit sino su ausencia — en el arranque no corre nada suyo: vuelve lo que systemd tenía apuntado, y el `enable` de cada unidad se reafirma en cada despliegue para que el disco no pueda contradecir a la configuración. Hasta aquí sólo estaba probada la mitad barata, parar todo y levantarlo desde una sesión que vive en esa máquina, que no ejercita ni el orden del arranque ni la pregunta de si la máquina vuelve. **Repetido en Debian 12** desde la v1.3.4: 14 comprobaciones, 0 fallos y cero intervención, sobre una distribución donde nadie lo había mirado. Ver ARCHITECTURE §5.5
- ✅ **La unidad de systemd declara su propio `HOME`** — el primer fallo real llegado de un servidor de verdad, y justo del punto ciego que este documento avisaba: una app de Node compilaba bien y no arrancaba nunca, con `EACCES` sobre la caché de corepack. `ProtectHome=true` tapa `/home`, donde caía el `HOME` que systemd deduce de `User=`. Arreglado sin abrir el cajón, con la primera suite de pruebas sobre la unidad generada. Ver ARCHITECTURE §5.1

- ✅ **Orbit habla el idioma del sistema** — español e inglés, detectados de `LANG` y compañía, y de `/etc/default/locale` cuando no hay entorno (cron, temporizadores). `orbit --lang <código>` para una orden, `ORBIT_LANG` para una sesión, `orbit lang <código>` para el servidor. La clave de traducción es la propia frase en español, así que lo que falte sale en español y no en un identificador. Ver ARCHITECTURE §21
  - ✅ **`install.sh` también.** No copiando el núcleo sino sacándolo de `orbit`, que está al lado y hace falta de todas formas, entre dos marcas que lo delimitan — la misma técnica que ya usaba `tests/lib.sh`. Se comparte el mecanismo; el catálogo es suyo, porque no dicen las mismas frases. Ver ARCHITECTURE §21.6b
  - 💭 **Más idiomas.** Añadir uno son cuatro pasos y ninguna decisión de diseño (ARCHITECTURE §21.10); lo que hace falta es alguien que lo hable

---

## v1.2 · Más stacks 📋

- ✅ **Deno y Bun** como runtimes de primera clase. Entraron por la puerta de atrás: no se buscaba soportarlos, se comprobó qué hacía Orbit con ellos, y lo que hacía era **publicar el repositorio entero** —`GET /main.ts` devolvía 200 con el servidor dentro, medido contra nginx—, porque ninguno compila a una carpeta y la rama que no reconoce nada sirve la raíz del repo. De ahí sale la regla general: ante la duda, con proceso y no estático. Deno trajo tres excepciones propias —la caché fuera del repositorio, `deno task` al que no se le puede cambiar el puerto, y un cajón de arena de la aplicación que no se solapa con el de systemd— y Bun, la distinción entre ser el gestor de paquetes y ser el runtime. Ver ARCHITECTURE §18.8
- ✅ **SvelteKit, Remix/React Router 7 y Angular** en la detección automática, verificados compilando un proyecto real de cada uno. Ver ARCHITECTURE §18
- ✅ **Qwik**, que era lo que quedaba de esa línea, y traía el agujero de §18.8 otra vez: `vite` está en las `devDependencies` de **todos** los proyectos de Qwik, así que la rama de Vite se los quedaba y salían `static` en `dist/` con respaldo de SPA. Medido compilando: sin adaptador de servidor `dist/` no tiene `index.html`, o sea que el respaldo apunta a un fichero que no existe y la web entera devuelve 404 — y le pasaba igual a los adaptadores de Express y node-server, que son los que se usan en un VPS. Lo decide el adaptador, como en SvelteKit, pero aquí el adaptador **no es un paquete** y no se puede leer de las dependencias: `qwik add` deja un directorio `adapters/<nombre>/vite.config.ts`, y de ahí sale todo. El arranque viene del script `serve` que escribe el propio adaptador y nunca de `start`, que en Qwik es el servidor de desarrollo — el único stack de los diecinueve donde `start` no vale. Ver ARCHITECTURE §18.11
- ✅ **Laravel** con `artisan migrate`, `storage:link` y `storage/` compartido, verificado contra un proyecto real servido por nginx y php-fpm. Es el stack donde menos código nuevo hace falta y más decisiones hay que tomar: lo que trae es un **orden**, y cuatro de sus cinco pasos fallan en silencio si se hacen en otro. De ahí salieron dos correcciones que no eran de Laravel —`shared/storage` no se creaba nunca y las subidas se perdían, y las cachés generadas dentro del shell del build congelaban valores que bash había expandido— y la decisión de **no** escribir unidades de systemd para las colas: un worker residente convierte el despliegue atómico en uno a medias, y nada de lo que Orbit tiene sabría vigilarlo. Cuando toque, será un temporizador. Ver ARCHITECTURE §18.9
  - ✅ **`orbit queue`** por temporizador, con la conversación sobre latencia por delante y dicha por el propio comando al activarlo. Lo que costó no fue llamar a artisan: el ciclo tiene que **terminar** —`--stop-when-empty` no basta, porque una cola que crece más rápido de lo que se vacía convierte ese `queue:work` en el worker residente que este diseño evita, así que el `--max-time` sale del intervalo—, y el límite es **de la pasada y no de cada app**, porque tres apps ocupadas a 55 s dentro de una ventana de 60 dejarían una unidad en rojo cada minuto en un servidor sano. Y de ejecutarlo contra un Laravel de verdad salió un fallo que no era de las colas: desde Laravel 11 el defecto del framework es `database`, así que un `.env` sin `QUEUE_CONNECTION` —el que crea Orbit— encolaba sin que nadie lo ejecutara y el aviso se callaba. Ver ARCHITECTURE §18.9
  - ✅ **Laravel ya no tiene que estar en la raíz del repositorio.** Un monorepo con la API en `backend/` y el frontend al lado no casaba con ninguna rama y caía en la de repuesto, que es el octavo agujero de esa lista y de los peores: `A_OUTDIR="."` publica el repositorio entero **y** `_has_php` ponía `A_PHP=yes`, así que php-fpm además ejecutaba cualquier `.php` alcanzable por URL. Medido contra nginx: `GET /backend/composer.json` devolvía 200. `_find_app_package` no servía —lee `dependencies` de un `package.json`, y aquí la señal está en `composer.json`—, así que la búsqueda va aparte, a dos niveles, podando `vendor/`, y con una regla que salió de buscarle agujeros al cambio: si la raíz declara un framework de JavaScript, manda la raíz. El `.env` lo destapó la prueba de despliegue y no la de detección: Laravel lo busca junto a su `composer.json`, y sólo se enlazaba en la raíz de la release. Ver ARCHITECTURE §18.9b
  - ✅ **Health check y rollback también sin unidad.** Se le pide la portada a nginx como haría un visitante, y un 5xx devuelve el symlink a la release anterior. Arreglando eso salió algo peor: **php-fpm seguía sirviendo la release anterior** hasta que caducaba su caché de `realpath` (120 s), así que el despliegue no llegaba a existir para una app PHP y cualquier comprobación medía la release que ya estaba. Ver ARCHITECTURE §18.9
- ✅ **Django** con `collectstatic`, migraciones explícitas, ASGI y detección del módulo del proyecto
- ✅ **Flask y FastAPI** con detección del objeto real de la aplicación
- ✅ **Poetry y uv** además de `requirements.txt`
- ✅ **Go** compilando en el servidor y sirviendo el binario por systemd. Verificado con once proyectos reales —`net/http`, chi, Gin, `cmd/*/main.go`, varios binarios, cgo— y rompiéndolo a propósito ocho veces. Orbit **no instala** el toolchain, como con Hugo y por los mismos motivos con los números diez veces mayores: son 287 MB, el paquete de Ubuntu va por Go 1.22, y a diferencia de Node o PHP el runtime no lo necesita. Trajo tres excepciones que ningún otro stack tiene: un build que sale con 0 sin dejar binario, `go` que casi nunca está en el PATH, y `KillSignal=SIGINT` que se salta el apagado ordenado. Ver ARCHITECTURE §18.6
- ✅ **Hugo y Eleventy**. Hugo no lo instala Orbit —es un binario que la mayoría de servidores no necesita—: se detecta, se dice cómo instalarlo y `orbit doctor` lo comprueba si alguna app lo usa. **Jekyll** queda fuera por lo mismo pero con más peso: necesita Ruby entero, no un binario
- ✅ **La rama de repuesto ya no publica el código fuente en silencio.** Era de donde salían Deno y Bun, y una revisión adversarial encontró cuatro caminos más que seguían acabando en `A_TYPE=static` con `A_OUTDIR="."` — incluido un servidor de Node sin framework, que llevaba ahí desde siempre. Un `"start"` sin `"build"` es ahora una app con proceso, y cuando de verdad no se reconoce nada, se avisa de lo que se va a hacer. Ver ARCHITECTURE §18.8
- ✅ **Y el resto de stacks tampoco tenían que salir de la raíz.** Salió de auditar lo anterior: lo de Laravel no era de Laravel. Un Go en `backend/`, un Django en `backend/` y un Hugo en `site/` daban los tres `A_TYPE=static` con `A_OUTDIR="."`. En vez de parchear rama por rama —son dieciséis y crecen, y la que se olvidara fallaría hacia servir la carpeta equivocada—, `detect_stack` **se llama a sí misma** sobre la subcarpeta y una sola función traduce las coordenadas después. Añadir un stack nuevo no toca nada de eso. La pregunta que quedaba abierta —quién manda si la raíz declara algo— resultó tener una respuesta mejor que la prevista: la búsqueda sólo se llama desde donde la raíz **no** reconoce nada, con lo que la guardia especial que se había escrito para Laravel pasó a ser código inalcanzable y se quitó. Esa colocación costó una regresión encontrada probando: puesta antes de tiempo, un sitio estático con un `tools/pyproject.toml` al lado pasaba a ser una app de Python. Ver ARCHITECTURE §18.9b
  - ✅ **Y el `orbit.json` de la app, no sólo el del repositorio.** Una app que vive en `backend/` ya puede declararse a sí misma, con sus rutas relativas a su carpeta. Sale de la misma pieza: el descriptor se lee **dentro** de `detect_stack`, así que el de una subcarpeta lo recoloca la misma traducción de coordenadas que todo lo demás. Y una declaración manda sobre cualquier inferencia, así que es la única búsqueda de subcarpeta que va delante de las ramas de la raíz — un `orbit.json` no aparece por accidente, a diferencia de un `pyproject.toml`. Con lo que además desaparece el último caso en el que un stack que Orbit no reconoce se quedaba sin desplegar: se declara y ya
- 💭 **Aplicaciones Docker** — si el repo trae `Dockerfile`, construir y correr el contenedor con proxy delante
- 💭 **MySQL y MariaDB** junto a PostgreSQL
- 💭 **Redis** como servicio opcional para cachés y colas

---

## v1.3 · Observabilidad 📋

Ahora mismo sabes que algo va mal cuando alguien te lo dice.

- ✅ **`orbit top`** — panel en terminal con CPU, memoria y peticiones por app, actualizado en vivo. La CPU sale de restar dos lecturas del cgroup y las peticiones de las últimas líneas del log de nginx, con el tope anunciado. Sin puertos, sin demonios y sin dependencias nuevas. Ver ARCHITECTURE §13.6
- ✅ **Vigilancia** — `orbit watch` por temporizador de systemd, con reinicio automático y protección contra bucles
- ✅ **Métricas de despliegue** — `orbit metrics [app]`: cuánto tarda cada build, cuántos han fallado y si va a peor. Una línea TSV por despliegue en `/var/lib/orbit/deploys.tsv`, escrita por el propio `orbit deploy` — sin recolector, sin base de datos y sin proceso nuevo, y legible con `cat`. Tres decisiones con contenido: el build se cronometra **aparte** del despliegue, porque es lo único que crece con el proyecto; se enseña la **mediana** y no la media, porque un build que una vez tardó 400 s no describe ningún despliegue real; y la **tendencia se calla** con menos de seis builds, porque dos datos no son una tendencia y fingirla es peor que no tenerla. Ver ARCHITECTURE §18.10
- ✅ **`orbit doctor --fix`** — arregla los problemas que puede arreglar sin decidir nada por ti: servicios parados, el servidor por defecto y los puertos duplicados. La lista de lo que **no** toca es la parte importante, y sale de cuatro reglas explícitas. Ver ARCHITECTURE §19.5
  - ✅ **Y dice cuándo una app registrada no tiene vhost**, desde la v1.3.5: nginx no la sirve, el visitante recibe la conexión cerrada del servidor por defecto —ni 404 ni 502, `curl` dice `000`— y no lo veía ninguna de las tres preguntas que se hacen: `nginx -t` pasa porque lo que falta no es sintaxis sino un fichero, `orbit list` pintaba `php-fpm`, que es una constante, y doctor salía entero en verde. Éste **sí** lleva acción, al revés que los dos de abajo: un vhost que falta no lo decide nadie, y se regenera del descriptor. Salió de una app que la propia suite de pruebas había dejado sin vhost al lanzarla como root (ARCHITECTURE §11.1)
  - ✅ **Y dice cuándo una app está en mantenimiento**, que era la asimetría que quedaba: contaba el `php artisan down` de Laravel y se callaba el propio de Orbit. Importa porque el testigo vive en `shared/` y **sobrevive al arranque de la máquina** —donde no corre nada de Orbit—, así que un despliegue muerto de mala manera podía dejar una web en 503 sin que ninguna herramienta lo reconociera como caída. Sin acción, por la regla 1: publicar una web que alguien bajó a propósito es peor que dejarla bajada
- ✅ **Avisos por correo** mediante un relé SMTP tuyo, con `curl`, que ya era dependencia y habla SMTP. Lo que bloqueaba esto eran dos cosas y la segunda no era del correo: un VPS limpio no puede entregar —sin MTA, con el puerto 25 bloqueado y sin reputación, lo que saliera iría a spam—, y **el subsistema entero fallaba en silencio**, porque `orbit notify test` llamaba a `notify`, que se traga los fallos por diseño, y anunciaba «Enviado» con un token caducado, un webhook borrado o una contraseña mal escrita. Ahora cada canal se prueba por separado y se dice cuál falló y por qué. Con contraseña, TLS obligatorio
- 💭 **Exportador de Prometheus** para quien ya tenga Grafana
- ✅ **Analítica de acceso** — `orbit traffic [app] [--since 7d]`: peticiones, IPs distintas, errores, tiempos y rutas más pedidas, leyendo el log que nginx ya escribe. Sin cookies, sin JavaScript y sin nada nuevo corriendo. Lo que hace legítimo el resultado no es la suma sino lo que se dice sobre ella: son **IPs y no personas**, lo automático se cuenta **aparte** —en un VPS con IP pública buena parte del tráfico son escáneres buscando `/.git/config`—, y una ventana que el log ya no cubre se anuncia **recortada** en vez de devolver un número más pequeño y callarse. Ver ARCHITECTURE §13.8

---

## Orbit Desktop · la interfaz gráfica, fuera del servidor 💭

**Repositorio aparte.** Aquí solo se apunta lo que a Orbit le toca hacer para que exista.

La idea en una frase: una aplicación que corre **en tu portátil**, entra por **SSH con tus claves de siempre** y ejecuta `orbit … --json`. El servidor no gana ni un proceso, ni un puerto, ni un fichero de estado; tiene exactamente el mismo estatus que tu terminal. Por eso no rompe ninguno de los seis principios, y por eso puede existir cuando un panel web no puede.

- ✅ **El contrato `--json`**, que es de lo que se alimenta. Hecho en la v1.1
- ✅ **Comandos que no preguntan**, empezando por `orbit new --yes`. Hecho en la v1.1
- ✅ **`--json` en el resto** — `version`, `db list`, `redirect list` y `watch status`. `orbit version --json` da la versión de Orbit y la del contrato por separado, para que un cliente sepa si puede hablar
- ✅ **Comandos destructivos sin terminal** — `orbit rollback <app> <release>` y `orbit remove <app> -y [--purge]`. `--purge` va aparte a propósito: quitar la app de nginx se deshace, borrar sus datos no
- ✅ **`orbit deploy --all --json`** — el contrato por lotes. Resultaron ser **seis** finales por app y no cuatro: desplegada, fallida, al día, remoto mudo, rama desaparecida, y saltada por venir del mismo commit que ya rompió el build. Los recuentos van desglosados por los seis y no agrupados, porque confundir «al día» con «no he podido preguntar» es el fallo que ya costó un arreglo en la versión en prosa. Dentro de cada app va el objeto de `orbit deploy <app> --json` **sin recortar**: una forma, dos comandos. Escribirlo destapó tres cosas que no eran del contrato — cada despliegue del lote corría sin `errexit`, el resumen en prosa escribía por stdout, y el motivo de un remoto mudo era la última línea de git («and the repository exists.») en vez del primer `fatal:`—. Ver ARCHITECTURE §13.6bb
- ✅ **`orbit deploy --json`** — el resultado del despliegue como objeto. La decisión pendiente resultó no obligar a elegir: por stdout va **un solo objeto**, como en todos los demás comandos, y el progreso es opcional (`--progress`), una línea por suceso y por stderr. Ver ARCHITECTURE §13.6b
- 💭 **Un grupo `orbit-admin`** con regla de `sudoers` limitada a `/usr/local/bin/orbit`, para no tener que entrar como root. Honestidad por delante: sigue siendo equivalente a root, porque `orbit exec` existe
- ✅ **Salida de progreso legible** durante `deploy`: `--progress` emite un suceso por línea en stderr, para que el cliente pueda enseñar una barra en vez de un bloque de texto al final
- ✅ **La latencia del contrato**, que es la de la interfaz: cada pantalla del cliente es un `orbit … --json` por SSH, así que lo que tarde este lado se suma al viaje y no se esconde detrás de él. Los ayudantes JSON escriben por stdout y estaban **capturados**, o sea un proceso por campo para mover un texto de stdout a stdout. Con 40 apps y contando los `clone()` con `strace`: `list --json` pasa de 842 procesos y 630 ms a 242 y 250 ms, y `orbit list` —el comando que más se teclea— de 327 y 330 ms a 167 y 190. La salida no cambia ni un byte, comprobado carácter a carácter contra la versión anterior, que es el único criterio de éxito que admite un cambio de rendimiento sobre un contrato. Ver ARCHITECTURE §13.6d

Restricción de diseño, la misma que la de la v2.0 y por el mismo motivo: **la interfaz nunca escribe en `/etc/nginx`, `/etc/orbit` ni systemd. Solo invoca `orbit`.** El día que genere un vhost por su cuenta habrá dos verdades sobre cómo se despliega.

Y un efecto secundario que conviene no perder de vista: un cliente que habla SSH con varios servidores **es** el `orbit remote add` de aquí abajo, sin plano de control.

---

## v2.0 · Multiservidor 💭

El salto grande, y donde hay que ir con cuidado para no convertir esto en Kubernetes.

- 💭 **`orbit remote add <nombre> <host>`** — gestionar varios servidores desde tu portátil por SSH
- 💭 **`orbit migrate <app> <servidor>`** — mover una app de un servidor a otro con su base de datos
- 💭 **Builds remotos** — compilar en una máquina potente y enviar solo el artefacto al servidor pequeño
- 💭 **Configuración declarativa** — un `orbit.yml` en el repo que describa cómo se despliega, versionado junto al código

Restricción de diseño: si esto exige un plano de control, un demonio o un clúster, se descarta. Orbit debe seguir siendo un script sin estado.

---

## Ideas sueltas 💭

Sin planificar, abiertas a debate.

- ✅ **Aislamiento por app** — un usuario de sistema por aplicación en vez de un `deploy` compartido: una app comprometida ya no puede leer el `.env` de otra. Las apps con proceso nuevas nacen aisladas; las anteriores se migran con `orbit isolate <app>`. El fetcher (git/gh, credenciales) sigue siendo `deploy`; el builder y el proceso son de la app. Ver ARCHITECTURE §5.3
- ✅ **Un pool de php-fpm por app** — la otra mitad, y la que de verdad cierra el agujero en PHP: sus páginas no las ejecuta la app sino php-fpm, así que con un pool único el dueño de los ficheros daba igual y cualquier `.php` leía el `.env` de las demás. Cada app PHP aislada tiene ahora su pool, su usuario y su socket. Es lo único del aislamiento que se puede demostrar sin un VPS: dos pools de verdad en `nginx_test.sh`. Ver ARCHITECTURE §5.4

**Panel HTML estático.** Una página de solo lectura para ver el estado desde el móvil, **regenerada por el temporizador de `orbit watch`** que ya corre cada minuto y servida por nginx como un site más de Orbit. No contradice el principio de "sin demonios" porque no es un proceso: es un fichero. Protegido con Cloudflare Access sobre un subdominio proxied, encaja con `orbit firewall lock`, que ya deja 80 y 443 accesibles solo desde rangos de Cloudflare. Nunca escribe valores del `.env`. Aplazado, no descartado: ver ARCHITECTURE §13.7.

**Copias de seguridad y restauración.** Hecho: `orbit backup [app] | --all | list`, `orbit restore <fichero>` y `orbit restore --all [--deploy]` para levantar un servidor completo. La configuración global se restaura clave a clave —las preferencias sí, las rutas de este servidor no—, y el rol de PostgreSQL se recrea con la contraseña que espera el `.env`. Y **verificar** también: `orbit backup verify` comprueba que de una copia se puede volver, y cada copia se verifica nada más crearla y antes de enviarla fuera. De paso destapó un bug real —un `pg_dump` fallido dejaba un `.gz` vacío y el manifiesto decía llevar la base de datos—. Ver ARCHITECTURE §17.4b

**Soporte para otras distribuciones.** ✅ **Debian 12**, desde la v1.3.0: el instalador se adapta solo, y auditarlo dio tres diferencias que ninguna estaba donde se esperaba —Debian y Ubuntu comparten empaquetado, así que no fue apt ni las rutas de nginx—. Las tres eran **cosas que en Ubuntu llegaban solas**: el aviso de los pockets de apt estaba escrito sobre el campo `Suite`, que en Debian nombra el pocket al revés (`a=oldstable-security` frente a `n=bookworm-security`), o sea que **era inerte justo en la distribución donde más falta hace**; `PHP_VER=8.3` no existe en Debian 12 y ahora se le pregunta al metapaquete `php-fpm` en vez de mantener una tabla que caduca; y `sudo` y `python3-systemd` no vienen de serie —el segundo es un `Recommends` allí y un `Depends` en Ubuntu, así que fail2ban se quedaba sin arrancar—. De eso salió el hallazgo que no es de Debian: el instalador imprimía «fail2ban vigilando SSH» sobre un servicio muerto. Desde la v1.3.1 CI corre un segundo trabajo en `debian:12` que cierra cuatro preguntas que desde Ubuntu no se podían contestar —la suite entera pasa allí, `apt` de verdad dice 8.2, el aviso de pockets calla en un Debian bien configurado (la medición en reposo, que es la que faltaba) y los paquetes del instalador resuelven en seco—.

Y desde la **v1.3.3 está ✅**: instalado de principio a fin en una Debian 12 con systemd de verdad, partiendo de una máquina sin `make`, sin `nginx` y sin `node`. Los trece pasos terminan, systemd levanta una app con proceso —unidad activa, su propio usuario, `NRestarts=0`, respondiendo por nginx— y unattended-upgrades **instala** de verdad, comprobado degradando un paquete a propósito porque con el sistema al día el instrumento marca cero aunque esté roto. Lo caro fue lo que salió por el camino: el paso 12 murió en `ufw allow OpenSSH`, y al mirar por qué apareció que ese perfil abre el 22 a pelo —o sea que **un servidor con sshd en otro puerto se quedaba fuera del suyo, en Ubuntu también, y sin un solo error**. Ver ARCHITECTURE §23. Rocky y Alma requieren reescribir la parte de paquetes.

**Certificados de origen de Cloudflare.** Válidos 15 años y sin renovación. Más simples que Let's Encrypt para quien ya está detrás de Cloudflare y no piensa salir.

- ✅ **Reinicio sin corte** — levantar el proceso nuevo, esperar a que responda y solo entonces retirar el viejo. La release nueva arranca como unidad puente (`orbit-<app>-next`) en un puerto libre; si no pasa el health check, el proceso viejo ni se ha enterado — el fallo ocurre antes de tocar producción, no después. El estado en reposo no cambia: una unidad, un puerto, un vhost. `DEPLOY_OVERLAP="no"` devuelve el camino clásico para apps que no leen `$PORT`. **Ejercitado ya en un VPS real bajo tráfico**, y de ahí salió que no era del todo sin corte: daba 1-2 respuestas 502 por despliegue, porque `systemctl reload nginx` vuelve cuando entrega la señal y el proceso viejo se paraba 10 ms después, con peticiones aún en vuelo hacia él. Con el drenaje, 0 en 5 despliegues. Ver ARCHITECTURE §5.2

- ✅ **`orbit init`** — escribe un `orbit.json` dentro del proyecto con lo que la detección encuentra, para que la configuración de despliegue viaje con el código. Es el reverso exacto de lo que lee el despliegue, así que lo escrito se vuelve a leer igual. Es el único comando que **no** se auto-eleva a root ni exige que Orbit esté instalado: escribe en el repositorio de quien lo ejecuta, y un fichero de root en un checkout ajeno sería un incordio para siempre. Y se niega a escribir la rama de repuesto de la detección —`static` sirviendo la raíz— cuando no hay un `index.html`: el descriptor manda sobre la detección, así que eso congelaría «publica el código fuente» sin que nadie lo hubiera decidido. Ver ARCHITECTURE §22

---

## Fuera de alcance

Cosas que Orbit **no** va a hacer, para que nadie pierda el tiempo proponiéndolas:

- **Aplicaciones que se actualizan a sí mismas.** WordPress, foros como XenForo o Invision, paneles de administración. No es una cuestión de esfuerzo: el modelo de releases inmutables con symlink es **incompatible** con una aplicación que se modifica sola. WordPress se actualiza desde su panel, instala plugins y escribe en su propio directorio; el siguiente despliegue se lo llevaría por delante. Soportarlo exigiría una segunda clase de aplicación con docroot estable, sin build y con su propia copia de seguridad: un segundo producto dentro del primero. Para eso hay herramientas mejores.
- **Instalar software que no viene de tu repositorio.** Orbit despliega lo que tú escribes y versionas. Si algo se descarga de una web oficial, se instala con un asistente web y se actualiza solo, no es trabajo de Orbit.
- **Orquestación de contenedores.** Si necesitas eso, necesitas Kubernetes o Nomad.
- **Balanceo de carga entre servidores.** Cloudflare o un balanceador dedicado lo hacen mejor.
- **Gestión de DNS.** Cloudflare ya tiene panel y API.
- **Alojamiento gestionado.** Orbit es una herramienta, no un servicio.
- **Un panel web corriendo en el servidor.** Ni Plesk ni cPanel ni nada parecido. `orbit` se auto-eleva a root y `orbit exec` ejecuta comandos arbitrarios: un panel web encima de eso no es un panel, es una shell de root expuesta a internet, y es la clase de producto más atacada del hosting. Además convertiría a Orbit en competidor de Coolify, CapRover y Plesk, que tienen equipos. El razonamiento completo, con la alternativa que sí encaja, está en ARCHITECTURE §13.3.
- **Una interfaz gráfica dentro de este repositorio.** El terminal es el interfaz de `orbit`, y el panel en vivo es `orbit top`. La interfaz con ratón es **Orbit Desktop**, que va aparte (ver abajo) precisamente para que este repositorio siga siendo un fichero de Bash.
- **Soporte para Windows Server.** No.

---

## Cómo influir en esto

- Abre un issue con la etiqueta `enhancement` describiendo el problema que tienes, no la solución que imaginas
- Vota con 👍 en los issues existentes, se mira antes de priorizar
- Mándalo implementado: un PR bien hecho salta la cola

Lee [CONTRIBUTING.md](CONTRIBUTING.md) antes de escribir código.
