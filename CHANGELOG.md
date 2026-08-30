# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).
Este proyecto sigue [versionado semántico](https://semver.org/lang/es/).

## [No publicado]

### El contrato, terminado por donde le faltaba: un cliente ya no necesita parsear texto

Sale de auditar el contrato desde fuera, escribiendo el cliente de escritorio de §13.4 contra él. El método importa más que los cambios: **no se leyó el script, se ejecutó**, con un banco de 40 apps y llamando a `main()`. Y eso destapó lo primero de la lista, que llevaba versiones documentado y muerto.

**`orbit doctor --fix --json --yes` no existía.** Está en `USAGE.md` y razonado en §19.5, y moría con «no sé qué es «--yes»». `--yes` no es una bandera global —el bucle de `main` sólo conoce `--json`, `--eva` y `--lang`— y `ASSUME_YES` sólo se asignaba dentro de `cmd_new`, sobre una copia local. La guarda de `doctor` la exige y no había forma de dársela: **el camino estaba muerto por las dos ramas**. Ahora `cmd_doctor` la reconoce, y sólo él. Hacerla global habría sido más corto y es justo lo que no se hace: hoy la reconocen `new`, `remove`, `restore` y `migrate`, cada uno con su significado local, y uno de ellos borra datos.

**`orbit backup list --json` y `orbit backup verify --json`.** `list` imprimía una tabla de anchura fija con el tamaño en `du -h`, o sea que quien quisiera esos datos acababa cortando por columnas —y a partir de ahí alinear una columna es un cambio incompatible— y reinterpretando un «1,2G» escrito con el separador decimal de este servidor. Ahora el tamaño va en bytes y la fecha en ISO-8601 con huso. La copia de la configuración global sale con `"app": null` y `"kind": "config"`, porque no es de ninguna app. Y `verified` es `null` en `list`: «no lo he comprobado en esta llamada» no es «está mal», y abrir cada fichero cuesta. En `verify`, el `ok` de arriba es booleano y sigue **la misma regla que el código de salida**, para que quien mire el objeto y quien mire el `exit` no puedan discrepar nunca.

**`orbit logs --json`, y la única excepción del contrato.** `logs` es el único comando cuya salida es un flujo sin final, así que un objeto no se puede cerrar nunca con `--follow` y una ventana de siete días serían cientos de megas en memoria antes del primer byte. Se emite NDJSON, y la excepción **se declara en la propia salida**: la primera línea es un `meta` con el `schema`. De paso gana algo que la salida en prosa pierde, porque `tail` mezcla los dos ficheros de nginx sin decir cuál es cuál: **`stream` distingue el log de acceso del de error**, que es la primera pregunta de cualquiera que mira un log. La marca de tiempo sale del propio log y no se inventa —el de acceso lleva huso, el de error no, y el formato viejo da `ts: null`—, y con `--json` no se sigue en vivo por defecto, que es la misma regla que `orbit top`: en modo máquina, una foto. Ver §13.9.

**Y la promesa del contrato gana su otra mitad.** §13.1 decía «si hay que romper, sube `schema`», y le faltaba decir qué pasa después. Un cliente que sólo lea eso sólo puede concluir que un `schema` mayor puede ser cualquier cosa, y negarse a hablar — que es la peor forma de romper algo que todavía funcionaba. Ahora hay tres garantías permanentes escritas: la forma de `version --json`, la separación de stdout y stderr, y que **lo que no existe siga siendo `null`** y nunca un cero.

### Y la prueba que faltaba, que es la que habría cazado lo primero

`tests/cli_test.sh`, 41 comprobaciones. Las otras 33 suites cargan las funciones **sin `main`** —`tests/lib.sh` corta la última línea a propósito, y hace bien— así que las 110 líneas del bucle de banderas, `_json_strip`, `_lang_strip`, la criba de `_json_capable` y el árbol de despacho **no las ejecutaba nadie**. `doctorfix_test.sh` llama a `cmd_doctor --fix` como función, saltándose justo donde vive `ASSUME_YES`: la prueba pasaba y el comando no funcionaba. Es la lección de §13.6c otra vez — *la prueba tiene que ejercer el camino*.

La suite invoca el script **como binario**, y la lista de comandos con JSON la saca del propio `_json_capable` en vez de escribirla a mano: si una gana una entrada y la otra no, la que se queda corta miente.

Dos cosas quedan **fijadas y no arregladas**, a propósito, porque cambiarlas afecta a más de veinte comandos y merece su propia discusión:

- **Sin terminal, un comando sin app no aborta: elige la primera por orden alfabético y sale con 0.** Con `orbit restart` eso es reiniciar la app equivocada sin que nada lo diga. Sólo se protegen `info --json`, `deploy --json`, `rollback` y ahora `logs --json`.
- **`--json` detrás de un comando que no lo habla se ignora en silencio** —`orbit restart web --json` sale con 0— porque `main` sólo lo saca de los argumentos cuando el comando dice hablarlo, y no todos filtran lo que no conocen. Delante sí muere. Para un cliente la regla práctica es **`--json` siempre delante**.

Escribirlo con una prueba es lo que hace que el día que cambie sea porque alguien quiso.

### Lo que salió por el camino

- **`_j_str` no escapa `<`, `>`, `&` ni `'`, y hace bien**: su trabajo es producir JSON válido, no HTML seguro. No se toca. Queda escrito porque es una frontera que el servidor no tiene por qué cruzar y un cliente gráfico sí — y el escapado de HTML se hace donde se genera el HTML.
- **Dos fallos propios, los dos del mismo tipo y los dos ya arreglados:** una función que devolvía dos valores capturada con `$( )`, donde el segundo se perdía en el subshell; y un contador al final de una tubería, que hacía que el `end` de `logs` anunciara siempre cero líneas. Es la trampa que obliga a `_top_measure` a dejar su resultado en globales, encontrada dos veces en un día.
- **Y una que `bash -n` dio por buena:** un comentario con apóstrofos escrito **dentro** del programa de `awk`, que va entre comillas simples de bash. Las comillas casaban por casualidad y el script arrancaba. Lo cazó `shellcheck` con SC1078, que es exactamente para lo que está en el `Makefile`.

## [1.3.6] - 2026-08-16

### La guía de desarrollo deja de vivir en la raíz

Sólo documentación: no se toca ni una línea de comportamiento.

La guía que abría el repositorio pasa a `docs/DEVELOPMENT.md` y su versión larga a `docs/WORKFLOW.md`, las dos con el mismo contenido —los siete principios, las trampas de Bash que ya han costado bugs reales, lo que las pruebas unitarias no ven y el estado del proyecto— y sin el marco de herramienta concreta con el que estaban escritas. Las 31 referencias cruzadas de `orbit`, `tests/`, `CHANGELOG.md` y `ARCHITECTURE.md` apuntan a la ruta nueva.

Que la guía estuviera en la raíz era lo que la hacía visible, así que ahora `CONTRIBUTING.md` enlaza las dos: un documento que nadie encuentra no documenta nada.

## [1.3.5] - 2026-08-16

### La suite de pruebas borró el vhost de una app de verdad

Lanzar `make test-strict` **como root** en el servidor Debian dejó una app registrada, compilada, con su pool de php-fpm escrito, su release en `current` y su unidad viva, cuyo dominio no atendía nadie. Sin un error: las 32 suites en verde, 2.512 comprobaciones, 0 fallos.

`isolate_test` termina con un `cmd_remove tienda`, y `cmd_remove` borraba el vhost por su ruta absoluta. En esa máquina había una app llamada `tienda`, así que la prueba se llevó por delante el vhost de verdad. El arnés ya redirigía `/etc/orbit`, `/srv/apps`, las cuatro rutas de systemd, `/etc/php` y las altas de usuarios —cada una con su incidente detrás—, y nginx era el único que se había quedado fuera, porque `nginx_file()` devolvía la ruta a pelo y el enlace de `sites-enabled` estaba repetido a mano en cinco sitios: no había dónde desviarlo.

- Las dos rutas pasan a `NGINX_AVAILABLE`/`NGINX_ENABLED`, y todo va por `nginx_file`/`nginx_link`. El arnés las reapunta a su árbol temporal.
- `unit_test` vigila **la clase**: prohíbe que la ruta escrita a mano vuelva a aparecer en `orbit`, porque la sexta línea la escribe alguien dentro de seis meses. Es la forma de la comprobación de glifos de la v1.2.8 y de la de los `awk` de la v1.3.0.
- ARCHITECTURE §11 decía «ninguna suite toca `/etc/nginx`». La frase llevaba ahí siendo falsa; ahora está corregida y contada en §11.1.

**Cómo se encontró, que es la parte reutilizable:** no leyendo las suites, sino montándoles un sistema falso encima. Un `unshare -m` con copias montadas sobre `/etc/nginx`, `/etc/orbit`, `/etc/php` y `/etc/systemd/system`, testigos plantados con los nombres de app que usan las pruebas, y cada suite lanzada por separado. Señaló `isolate_test` a la primera, y tras el arreglo la sonda sale limpia.

### Y ninguna de las tres preguntas que se hacen veía la web muerta

Lo peor no fue el borrado sino la hora que pasó sin que nada lo dijera. `nginx -t` pasa —lo que falta no es sintaxis, es un fichero—, `orbit list` pintaba `php-fpm`, que es una constante y no puede acusar a nadie, y `orbit doctor` salía entero en verde. El visitante recibía la conexión cerrada del servidor por defecto: ni 404 ni 502, `curl` dice `000`.

Las tres fuentes lo dicen ahora, que es lo que hace que la respuesta no dependa de a cuál preguntes:

- **`orbit doctor`** comprueba que cada app registrada tenga su vhost, fichero **y** enlace —con el fichero puesto y el enlace ausente nginx no lo carga, que es el mismo agujero por la otra mitad—. Éste sí lleva acción de `--fix`, al revés que el mantenimiento o una unidad parada: aquéllos pueden ser una decisión de alguien, y un vhost que falta no lo decide nadie.
- **`orbit list`** pinta `sin vhost`, y gana sobre todo lo demás incluido el mantenimiento: sin vhost no se sirve ni la página de 503.
- **`orbit list --json` y `orbit info --json`** ganan `state.served`. Campo nuevo, `schema` sin mover: los campos se añaden y nunca se renombran.

Medido en la máquina de verdad: `doctor` acusó la app, `doctor --fix` regeneró el vhost del descriptor y el dominio volvió de `000` a `200` con sus datos intactos.

### Corregido — `orbit list` decía `running` con la web devolviendo 503

Una app en mantenimiento salía en el listado como si estuviera sirviendo. El dato ya existía **en el mismo comando**: `orbit list --json` traía `"maintenance": true` y `orbit top` ya pintaba `manten.`. O sea que la salida humana y la de máquina del mismo comando se contradecían, y la que fallaba era la que mira una persona.

## [1.3.4] - 2026-08-15

### La máquina Debian se ha reiniciado de verdad, y vuelve sola

La v1.3.3 dio Debian 12 por instalado sin haberla reiniciado. Ya está: 14 comprobaciones sobre la máquina recién arrancada, **0 fallos y cero intervención** — los seis servicios base, el cortafuegos, la app con proceso con `NRestarts=0` y su web contestando 200 por nginx.

Es la misma prueba que §5.5 hizo en su día sobre Ubuntu, y el resultado no es mérito de Orbit: en el arranque no corre nada suyo, vuelve lo que systemd tenía apuntado. Lo que se comprueba es que esté apuntado bien **en una distribución donde nadie lo había comprobado**.

De paso cierra por el otro lado el informe de `ufw` de la v1.3.3: antes del reinicio `systemctl is-active ufw` decía `inactive` con el cortafuegos filtrando; después dice `active`, porque ahora la unidad sí ha corrido. Confirma que el estado engañoso era exactamente el de recién instalado, que es cuando más se mira `orbit status`. Queda escrito en §23.6b.

### Y la lección: el instrumento no puede formar parte de lo que mide

La primera pasada dio 13 de 14, y el fallo no era de la máquina. La comprobación estaba enganchada a `multi-user.target`, así que **formaba parte del arranque**: mientras corría, el arranque no podía estar terminado por definición, y `systemctl is-system-running` contestaba `starting`. `systemd-analyze blame` lo dejaba a la vista poniéndola la primera de todas con 46 segundos, que eran su propio margen de espera.

Se saca de la transacción de arranque con un temporizador `OnBootSec=2min`. Dos minutos y no cuarenta y cinco segundos por lo de siempre: con `Restart=always`, una app que arranca y se muere en bucle da `is-active` igual que una sana, y lo que las separa es el contador de reinicios, que necesita tiempo para contar.

Es la sonda de tráfico de §5.2 otra vez en otro plano —allí la medición se acusaba a sí misma por pasarse del `limit_req`, aquí por existir— y el mismo día el mismo script se había cazado a sí mismo con un glob `orbit-*.service` que incluía su propia unidad. **Antes de creerte una medición, comprueba si estás dentro de lo que estás midiendo.**

### Y el aviso de Debian que la v1.3.3 se dejó donde más importa

El README y `INSTALL.md` seguían diciendo «todavía no se ha instalado en una máquina Debian de verdad, así que si eliges Debian eres el primero». La v1.3.3 movió el estado en el ROADMAP y en ARCHITECTURE y **se olvidó de los dos sitios que lee quien va a instalar**, que son precisamente los que la v1.3.0 puso ahí a propósito para que nadie se metiera sin saber en qué. Se quedaba corto en vez de pasarse, que es el lado bueno del error, pero seguía siendo falso.

Sin cambios en `orbit` ni en `install.sh` más allá de la versión: esto es documentación y una lección de método.

## [1.3.3] - 2026-08-15

### Debian 12 pasa a ✅ — instalado de principio a fin en una máquina de verdad

Lo que quedaba pendiente estaba escrito en ARCHITECTURE §23.4 y eran tres cosas que **ni la suite ni el contenedor de CI podían contestar**: que los trece pasos terminen, que systemd levante una app real, y que unattended-upgrades traiga de verdad los parches con la configuración por defecto de Debian. Las tres están medidas ahora sobre una Debian 12 con systemd de verdad, partiendo de una máquina sin `make`, sin `nginx`, sin `rsync` y sin `node`.

- **Los trece pasos terminan**, con PHP 8.2 elegido preguntándole a apt —el corazón de §23.2, ahora contra apt real y no contra un `apt-cache` doblado—, PostgreSQL 15.19, y fail2ban vigilando SSH de verdad (`Journal matches: _SYSTEMD_UNIT=sshd.service`), que es la comprobación que la v1.3.0 añadió para no volver a anunciar un servicio muerto.
- **systemd levanta una app real**: unidad `orbit-hola` activa y habilitada, corriendo como su propio usuario `orbit-hola` (uid 994), con `ProtectHome=true` y el `HOME` redirigido dentro del directorio de la app —el arreglo de §5.1, funcionando en Debian—, respondiendo directa y a través de nginx, con `NRestarts=0`.
- **unattended-upgrades instala.** Reconoce los tres orígenes de Debian incluido `bookworm-security`, pero eso solo es una medición en reposo: con el sistema recién actualizado no hay nada pendiente y el instrumento marca cero aunque estuviera roto. Así que se degradó `curl` a la versión vieja a propósito y se ejecutó sin `--dry-run`: `7.88.1-10+deb12u5` → `u15`, «All upgrades installed». **Que la configuración sea válida y que instale son dos afirmaciones distintas**, y sólo la segunda es la que estaba pendiente.

### Corregido — el cortafuegos abría el puerto 22 y tapaba el SSH de verdad

Lo encontró el paso 12 muriéndose en la primera instalación real. `ufw allow OpenSSH` falla en una máquina sin `openssh-server` instalado, porque **el perfil lo trae ese paquete** —en Debian y en Ubuntu igual, comprobado extrayendo los dos `.deb`— y con `errexit` eso tumba el instalador en el paso 12 de 13: `orbit` no llega a instalarse. Debian trae además un perfil `SSH` genérico que Ubuntu no tiene, así que renombrarlo arreglaría una distribución rompiendo la otra.

Pero al mirar por qué fallaba apareció el defecto grande, **que estaba también en Ubuntu y no da ningún error**: el perfil declara `ports=22/tcp` a pelo. Un servidor con sshd en otro puerto —de lo primero que hace cualquier guía de endurecimiento— recibía un cortafuegos que abre el 22 y **tapa el suyo**. Sale en verde, anuncia «SSH, 80 y 443», y la sesión abierta sobrevive porque ufw deja pasar lo ESTABLECIDO: te enteras al reconectar, cuando ya no puedes.

Medido, no razonado: con sshd escuchando sólo en 2222 y un cliente en otro espacio de red —desde localhost no vale, ufw deja pasar `lo` entero y todo parecería abierto—, el puerto 2222 daba **TIMEOUT** con el código viejo y el 22 quedaba abierto sin nadie detrás. Antes se midió en reposo, sin cortafuegos, para saber qué marca el instrumento cuando no hay nada que medir.

- **Ahora se le pregunta a SSH en qué puerto está**, con cuatro fuentes que se unen de más a menos fiable: el `SSH_CONNECTION` de la sesión que está instalando —la única que no puede equivocarse sobre dejarte fuera—, los sockets que escuchan, `sshd -T` con los `Include` ya resueltos, y el `sshd_config` como último recurso. Se unen y no se elige: un puerto de más sólo abre donde SSH ya atiende, uno de menos deja a alguien fuera.
- **Y si no hay ningún SSH**, se dice y se sigue: las cuatro fuentes en silencio significan que no hay servidor instalado y nadie puede estar entrando por ahí. Abrir el 22 «por si acaso» sería abrir un puerto donde no atiende nadie.
- Las reglas van **antes** del `enable`, que es lo que evita que un fallo a mitad deje el cortafuegos levantado sin por dónde entrar. Hay prueba de que ese orden se mantiene.
- 20 comprobaciones nuevas en `install_test`, y las seis mutaciones del código de verdad se han ejecutado para ver que ponen la prueba en rojo — incluida quitar el `|| true`, que es el que separa «no encuentro nada» de «me muero».

### Corregido — `orbit status` anunciaba el cortafuegos apagado con el cortafuegos puesto

`ufw enable` hace dos cosas: carga las reglas en el kernel **en ese momento** y deja la unidad habilitada para el arranque siguiente. Lo que no hace es arrancar la unidad, así que hasta el primer reinicio `systemctl is-active ufw` contesta `inactive` con el cortafuegos filtrando de verdad. Medido en la máquina recién instalada: `ExecMainStartTimestamp` vacío y las reglas de 2222, 80 y 443 puestas en la cadena `ufw-user-input`.

O sea que `orbit status` decía `○ ufw (inactive)` **justo después de instalar, que es cuando más se mira**, y lo mismo el `--json`. Es el «instalar un paquete no es tener un servicio funcionando» de §23.3 del revés: aquí la unidad no ha corrido y la cosa sí está en pie. Ahora a `ufw` se le pregunta a `ufw`, con `LC_ALL=C` porque traduce su salida y la comparación es contra el texto — sin fijar el idioma, un servidor en otra lengua diría que no. No es de Debian: pasa igual en Ubuntu.

### Corregido — `orbit doctor` no miraba si las apps estaban vivas

Con la unidad de una app parada y su web devolviendo 502, el diagnóstico salía entero en verde y sin mencionarlo: nginx válido, PostgreSQL activo, disco bien. `orbit list` sí decía `stopped`, o sea que **el dato existía y no estaba donde se pregunta «¿qué va mal?»**. Salió comprobando el arranque en frío de un servidor.

Ahora se cuenta como error, con el comando para ver por qué. **Sin acción de `--fix`**, por lo mismo que el mantenimiento: una app puede estar parada porque alguien la paró, y levantar lo que otro bajó a propósito es peor que dejarlo — y si se está muriendo en bucle, arrancarla no arregla nada, apaga la señal y deja el fuego. Se distingue de una web estática, que no está parada: es que no tiene nada que arrancar.

### Corregido — `orbit new` sin terminal salía con 1 habiendo ido bien

Un `orbit new --repo … --name … --domain …` lanzado desde un script dejaba la app **creada, desplegada y sirviendo**, y devolvía 1. El `confirm` del certificado se quedaba con su valor por defecto —que es «sí»— porque `read` falla con EOF al instante sin terminal, y `cmd_ssl` moría pidiendo un correo que nadie podía teclear.

La guarda que lo cubría ya existía y **su propio comentario decía «sin terminal no hay a quién pedírselo»**, pero la condición sólo miraba `--yes`. Ahora mira las dos cosas, con el `! -t 0` que ya usan el rellenado del `.env` y el `doctor --fix --json`.

Y la raíz, un escalón más abajo: `confirm` hacía `read -r a || true`, así que no distinguía «el usuario pulsó Enter» de «no había usuario». La respuesta no cambia —cambiarla rompería a quien ya automatiza— pero ahora lo dice, porque un «sí» que no ha dicho nadie no puede pasar por un «sí» del usuario cuando lo que hay detrás es emitir un certificado público con límites de frecuencia. Va sólo en `confirm` y no en `ask`: `confirm` contesta por código de salida y su stdout no lo lee nadie, mientras que la salida de `ask` sí se captura en sitios donde añadir texto ya costó un bug.

**Y el primer intento de esto estaba mal, que es la parte que merece leerse.** Miraba `! -t 0`, o sea «no hay terminal» — y **una tubería tampoco es un terminal y sí trae respuesta**: `echo n | orbit …` dejó de contestar que no y se quedaba con el valor por defecto. Lo cazó `i18n_test`, que le pasa las respuestas justo así. Lo que separa «alguien ha contestado» de «no había nadie» no es de dónde viene la entrada sino si `read` **consigue leer algo** — con la coletilla de que `read` devuelve 1 también cuando lee una línea sin salto final (`printf n | …`), y ahí sí ha contestado alguien. Cuatro comprobaciones nuevas cubren justo esa frontera.

### Añadido — el paso de la swap dice cuánta hay, porque tenerla no es tener suficiente

El paso 2 crea 4 GB de swap para que un build grande tenga aire, y su guarda mira si **existe** swap, no cuánta. Una máquina que ya trae 512 MB de fábrica pasaba por ahí con un «Ya existe swap, no toco nada» y se quedaba igual de justa.

Salió en la máquina de la instalación real, y con consecuencia concreta: 3.880 MB de RAM y 975 MB de swap al 100 %, con `shellcheck` sobre `orbit` muriéndose por falta de memoria — o sea que `make lint`, que es lo que corre CI, no cabía. Es la lección de la guarda de `python3-venv` de la v1.3.1 otra vez: **preguntar si algo está no es preguntar si llega.**

No se toca lo que el administrador ya montó, que esa parte estaba bien: lo que faltaba era decir cuánto hay, y avisar por debajo de 2 GB —la mitad de lo que este paso habría creado— con el comando exacto para añadirla. 12 comprobaciones nuevas, con los dos lados del umbral y el caso de que `free` no conteste.

### Corregido — un servidor de Node con paso de build se publicaba como sitio estático

Salió al desplegar la primera app con proceso: un servidor sin framework con `build` y `start` en el `package.json` se detectaba como **`static` con `A_OUTDIR='dist'`**.

La rama que atrapa «servidor sin framework» pedía «tiene `start` y **no** tiene `build`», y ese «no build» dejaba abierta la mitad peor del mismo agujero de §18.8. Un servidor en TypeScript —`"build": "tsc"`, `"start": "node dist/server.js"`— tiene las dos cosas, así que caía al `else` y salía estático apuntando a `dist`. Y ahí **no salta ni el aviso de la carpeta que no existe, porque tsc la crea**: nginx publica el servidor compilado tan tranquilo y la app no se arranca nunca. La rama de `express`, tres líneas más arriba, ya lo hacía bien; ésta se había quedado con media regla.

**Tener un paso de build no dice que seas un sitio estático** —lo tienen casi todos los servidores compilados—; tener `start` sí dice que hay algo que arrancar. Ante la duda, con proceso: equivocarse hacia el proceso da un despliegue que falla en voz alta y hace rollback; equivocarse hacia `static` da uno que sale bien y publica el código.

Verificado en los dos sentidos sobre las 308 comprobaciones de `detect_test`: con la condición vieja, cuatro en rojo; con la nueva, todas en verde y ningún control movido.

## [1.3.2] - 2026-08-13

### Corregido — el autodespliegue no funcionaba en Debian, y no daba ningún error

Lo encontró el trabajo de CI en Debian que añadió la v1.3.1, en su tercera pasada. Es el hallazgo que justifica el job entero.

`_remote_head` sacaba el SHA de `git ls-remote` con `awk '$1 ~ /^[0-9a-f]{40}$/'`. **El awk de Debian 12 no entiende `{40}`**: trae mawk 1.3.4 snapshot `20200120`, que se lo come como cuatro caracteres literales, mientras que Ubuntu 24.04 trae el snapshot `20240123`, que sí implementa los intervalos. Mismo número de versión, comportamiento distinto, y `mawk -W version` es el único sitio donde se ve la diferencia.

Lo que pasaba en un servidor Debian, y por qué es de los peores: `git ls-remote` **contesta perfectamente** y el SHA está ahí, pero Orbit no lo reconoce y concluye «no he podido preguntar al remoto». En cada pasada. Así que **el autodespliegue deja de desplegar y nadie se entera** — que es exactamente la confusión entre «sin cambios» y «no he podido preguntar» que ese código se escribió para evitar, entrando por una puerta que nadie miraba.

Ninguna prueba podía verlo: el runner de Ubuntu trae gawk, y el mawk de Ubuntu es el nuevo.

- **Lo hace bash y no awk.** El `=~` usa la regex de glibc, que siempre trae intervalos, así que no depende de qué awk esté instalado. De paso desaparecen dos forks.
- **Y se comprueba la clase entera**, no esa línea: `unit_test` cruza `orbit` e `install.sh` buscando expresiones de intervalo dentro de cualquier `awk`, descartando comentarios —el arreglo lleva al lado el ejemplo de lo que no hay que escribir, y una prueba que prohíba documentar la trampa acaba borrando el motivo—. Verificado en los dos sentidos: en rojo con la línea original y con una mutación nueva, en verde sin ellas.

### Y dos diferencias del entorno, no del código

Las dos son de la misma familia que las tres de la v1.3.0 —cosas que en Ubuntu llegaban solas— y las encontró el mismo trabajo:

- **Dentro de un contenedor, los pasos de CI corren con `sh`, no con bash.** En el runner de Ubuntu salen con `/usr/bin/bash -e {0}`; en el contenedor, con `sh -e {0}`, o sea dash. El primer paso que escribió `set -Eeuo pipefail` murió con «Illegal option -o pipefail». Ese error ruidoso es el caso afortunado: el que da miedo es un bashismo que dash interprete de otra manera **sin quejarse**. Ya va declarado.
- **`procps`, `iproute2` y `curl` no están en un contenedor pelado.** `ps`, `ss` y `curl` los usan las pruebas de nginx y de puertos, y en el runner venían puestos.

La lección, que ya tenía media entrada en `docs/DEVELOPMENT.md` («Ubuntu trae mawk, sin asort, sin strftime») y ahora tiene la otra media: **dos sistemas con el mismo número de versión de la misma herramienta no son la misma herramienta.**

## [1.3.1] - 2026-08-13

### Añadido — CI corre también en Debian 12, y le pregunta al sistema lo que no se puede saber desde Ubuntu

La v1.3.0 dejó Debian en 🚧 con el motivo escrito: lo probado eran las decisiones, no la instalación. Un contenedor no cierra eso del todo —no hay systemd, no se puede levantar nada— pero sí cierra tres cosas que desde una máquina Ubuntu son literalmente incomprobables, y las tres las contesta **el sistema y no un doble de prueba**:

- **La suite entera pasa en Debian 12.** Las 32 suites, con `php8.2-fpm` en vez de `php8.3-fpm`, que era justo el nombre que no existía allí.
- **`apt` de verdad contesta 8.2** a la pregunta de qué PHP sirve este sistema. Hasta ahora eso lo afirmaba un `apt-cache` doblado.
- **El aviso de pockets no salta en un Debian bien configurado.** Es la **medición en reposo**, y es la que faltaba: la versión anterior de esa comprobación era inerte en Debian, y precisamente por eso nadie la vio fallar nunca. Si esta afirmación se rompe, o la imagen oficial ha cambiado o la comprobación se ha vuelto a romper, y las dos cosas hay que mirarlas.

Y una cuarta, en seco: **los paquetes del instalador resuelven en Debian 12**, comprobado con `apt-get install --dry-run` sobre la lista entera y con el `php${PHP_VER}-*` derivado de apt. Es lo que se rompía —doce paquetes inexistentes— y ahora no puede volver sin que CI lo diga.

El contenedor corre como root, y eso no es algo que haya que tolerar: es el único camino donde php-fpm baja de privilegios de verdad, que es lo que necesita la sección del aislamiento entre apps PHP. Comprobado antes en local —la suite entera como root da los mismos 2.447— para que un rojo ahí signifique «Debian» y no «root».

### Y el trabajo de Debian encontró lo primero, en su primera pasada

Salió en rojo, y no por Debian: por una **guarda que medía lo que no era**. `python_test.sh` ya se saltaba solo cuando faltaba `python3-venv`, y la comprobación era `python3 -m venv --help` — que **contesta que sí aunque el paquete no esté**, porque el módulo `venv` viene en la biblioteca estándar y lo que falta es `ensurepip`, que sólo se nota al crear el entorno de verdad.

O sea que la guarda daba paso y las pruebas se ponían **en rojo con 16 fallos acusando al despliegue de Python de Orbit**, que estaba perfectamente. El tercer estado, otra vez, en una suite que creía tenerlo resuelto.

En el runner de Ubuntu esto era invisible: allí `python3-venv` viene puesto, así que la guarda nunca se ejercitaba. Hizo falta un sistema donde de verdad faltara. Ahora la guarda **crea un entorno**, y se ha comprobado en los dos sentidos reproduciendo la condición en local con un `python3` de mentira: con la vieja pasa —y la tanda se caería—, con la nueva se salta diciéndolo.

La lección, que ya está en `docs/DEVELOPMENT.md` con otros disfraces: **preguntarle a una herramienta si existe no es preguntarle si funciona.** Cuando la guarda sea barata de ejecutar de verdad, ejecútala.

### Corregido — la quinta cifra derivada, en el fichero con más autoridad

`.github/workflows/lint.yml` explica **por qué CI instala** `rsync`, `jq`, `nginx` y `php-fpm`: porque sin ellos la tanda sale en verde habiendo probado dos tercios. Lo decía con los números de hace ocho versiones —«1.232 comprobaciones contra 1.916», cuando son 1.662 contra 2.447— y llamaba al paso «las 25 suites», que son 32. Es el fichero que le explica a quien llega por qué el verde de CI significa algo.

No entró en la v1.2.9 con las otras cuatro por un motivo que merece quedar escrito: el token con el que se subían las ramas **no tenía permiso para tocar `.github/workflows/`**, así que GitHub rechazaba el push. Un fichero puede quedarse sin arreglar porque el arreglo no cabe por el canal, y eso no se parece a «nadie lo ha visto».

Y de paso, el consejo que da `make test-strict` cuando algo se salta decía «instala php8.3-fpm»: el nombre lleva la versión dentro, así que en Debian mandaba a instalar un paquete que no existe.

## [1.3.0] - 2026-08-13

### Añadido — Debian 12, y las tres cosas que en Ubuntu llegaban solas

El ROADMAP llevaba desde el principio un «Debian 12 debería funcionar casi tal cual». Auditarlo dio tres diferencias, y ninguna estaba donde se esperaba: Debian y Ubuntu comparten el empaquetado, así que no fue apt, ni las rutas de nginx, ni `www-data`. Fueron **tres cosas que en Ubuntu venían de rebote**.

- **El aviso de los pockets de apt era inerte en Debian.** Existe porque una imagen sin `-security` no recibe parches aunque tenga unattended-upgrades puesto, y estaba escrito mirando el campo `Suite`. Comprobado descargando los ficheros `Release` de los dos archivos: Ubuntu nombra el pocket en `Suite:` (`noble-security`, con `Codename: noble`) y Debian en `Codename:` (`bookworm-security`, con `Suite: oldstable-security`) — **cada una pone el dato en el campo que la otra deja fijo**. En Debian no existe ningún `a=bookworm`, así que la guarda cortaba antes de mirar y el aviso no podía salir jamás, en la distribución donde más falta hace y sin dar señal de estar apagado. Ahora se acepta cualquiera de los dos campos, comparándolos enteros porque `bookworm` es subcadena de `bookworm-updates`.
- **`PHP_VER=8.3` era el único motivo real por el que no se podía instalar**: Debian 12 va por 8.2, o sea doce `php8.3-*` que allí no resuelven. Se le pregunta al metapaquete `php-fpm`, que ya lo declara en su `Depends` y lo mantiene otro, en vez de una tabla de distribuciones que caduca en la siguiente. Un `PHP_VER` del entorno sigue ganando, que es como se instala contra Sury sin tocar el script.
- **`sudo` y `python3-systemd` no vienen de serie.** El primero lo omite el instalador de Debian si le das contraseña de root, y `orbit` se auto-eleva con él y ejecuta todos los builds con `sudo -u`: sin él no hay producto, y el fallo aparecería en el primer despliegue y no durante la instalación. El segundo lo necesita el `backend = systemd` de fail2ban; en Ubuntu es un `Depends` de fail2ban y en Debian sólo un `Recommends`, así que una imagen instalada con `--no-install-recommends` —lo normal en las de nube— se quedaba sin él.

El aviso de distribución mira ahora `ID` además de `VERSION_ID` —«12» era Debian 12 pero también un Ubuntu inventado, y el mensaje decía «Ubuntu» pasara lo que pasara— y el banner nombra lo que ha encontrado en vez de afirmar «Ubuntu 24.04 LTS» sobre un Debian.

**Lo que esto no es, dicho aquí y en el README:** no se ha instalado Orbit de principio a fin en una máquina Debian. Lo probado son las decisiones, una a una y contra los metadatos reales del archivo de Debian; queda por saber que los trece pasos terminen y que unattended-upgrades traiga de verdad los parches con la configuración por defecto de allí. Por eso en el ROADMAP está en 🚧 y no en ✅.

### Corregido — el instalador decía «fail2ban vigilando SSH» sobre un servicio muerto

Esta salió de lo anterior y no es de Debian. Los dos `systemctl` de fail2ban llevan `|| true` **a propósito**, para que un fallo ahí no tumbe la instalación entera — y justo después venía un `ok` incondicional. Cualquier motivo por el que fail2ban no arranque, incluido el `python3-systemd` de arriba, daba exactamente la misma línea verde en el paso que endurece el servidor.

Ahora se pregunta `systemctl is-active` y, si no está en pie, se dice y se apunta dónde mirar. Es la lección de `notify test` de la v1.2.7: **instalar un paquete no es tener un servicio funcionando**, y sólo lo segundo se puede anunciar.

### Y un rasgo de `errexit` que no estaba escrito en ningún sitio

Salió revisando el código nuevo antes de darlo por bueno. `apt-cache show` de un paquete que no existe **sale con 100** —medido—, y bajo `pipefail` la asignación hereda ese 100: con `errexit`, eso mata el instalador entero en el paso 8, sin un mensaje, en cualquier sistema sin el metapaquete `php-fpm`. Lleva `|| true`, que es lo que manda `docs/DEVELOPMENT.md` cuando «no he podido» es una respuesta válida.

Lo que no estaba escrito es por qué no saltaba. Comprobado ejecutándolo en bash 5.2.21:

```
f                    llamada directa          → muere, rc=100
_v="$(f)"            capturada                → sobrevive, y _v trae la salida parcial
local x="$(falla)"   declaración + asignación → no falla nunca: se mira el estado de 'local'
```

**La misma función es letal o inofensiva según cómo la llame quien la llama.** Aquí se la llamaba de la forma que sobrevive, o sea que estaba a una línea de distancia de un instalador que muere en silencio — y una prueba que la ejerciera capturándola no habría podido verlo nunca. La prueba nueva la llama **sin capturar**, dentro de un subshell con las banderas puestas, y se ha verificado quitando el `|| true` para comprobar que se pone en rojo con ese mismo 100.

De escribir esa prueba salió la tercera: el `set +e … set -e` que documenta `docs/DEVELOPMENT.md` da por hecho que errexit estaba encendido, y `tests/lib.sh` corre **sin** errexit — así que ese `set -e` no restaura nada, lo **enciende** para todo lo que viene detrás. La sección siguiente, que ejerce un fallo a propósito, dejó de reportar y se llevó la suite por delante.

### Y la quinta cifra derivada, que estaba en el sitio con más autoridad

La v1.2.9 volvió a medir cuatro números documentados que se habían quedado atrás. Faltaba uno, y era el peor sitio posible: el comentario de `.github/workflows/lint.yml` que explica **por qué CI instala esas herramientas** decía «1.232 comprobaciones contra 1.916», y el nombre del paso decía «las 25 suites» cuando son 32. Es el fichero que le explica a quien llega por qué el verde de CI significa algo — con los números de hace ocho versiones.

### Y una prueba que se cayó por donde se escribió, no por lo que decía

Meter la tanda de Debian en medio de `install_test.sh` tumbó dos comprobaciones de la sección siguiente sin que nada suyo hubiera cambiado: heredaban el fichero de política que les dejaba la sección anterior. Ahora esa sección fija el suyo. **Una prueba que depende del estado que le dejó otra falla el día que alguien escribe entre las dos, y acusa a quien no es** — que es la misma familia que el doble que no puede fallar.

## [1.2.9] - 2026-08-13

### Corregido — `orbit env get` devolvía el secreto de otra variable

La clave se metía **cruda en una expresión regular** en los tres sitios que leen un `.env`, menos en el que borra, que ya la comparaba literal. O sea que los dos no podían coincidir nunca, y con una clave que llevara un metacarácter se contradecían de la peor forma posible. Reproducido contra el código anterior, con un `.env` que tiene `FOOXBAR` y pidiendo `FOO.BAR`:

- **`orbit env get app FOO.BAR` imprimía `secreto-de-otra`** — el valor de otra variable, por stdout, bajo un nombre que no es el suyo. Y stdout es exactamente donde va a parar: la interfaz de este comando es `VALOR=$(orbit env get app CLAVE)`.
- **`orbit env unset app FOO.BAR` decía «eliminada» y no borraba nada**, porque el que decide si existe casaba y el que borra no. Quien quita una credencial filtrada se quedaba creyendo que ya no estaba.

El punto es el metacarácter barato; el mismo agujero lo abrían `*`, `[` o `^`. Ahora hay **una sola función** que decide si una línea es de una clave (`_env_line_matches`), y la usan los tres, así que no pueden volver a discrepar. De paso `get` y `unset` validan el nombre igual que `set` —una clave con metacaracteres no puede existir en un `.env`, así que pedirla es siempre un error de quien la escribe—: eso es el cinturón, la comparación literal son los tirantes.

`_env_read` deja de ser un `sed` con la clave interpolada y pasa a ser un bucle de bash. Sigue haciendo lo mismo que phpdotenv, que es lo que se decidió en §18.9: gana la última asignación, se aceptan `export` y sangría, y las comillas exteriores se quitan.

### Corregido — `free_port` podía entregar un puerto ocupado

`ss -ltn | grep -q ":$p "` es exactamente el patrón que la cabecera de `docs/DEVELOPMENT.md` prohíbe desde que costó el fallo del núcleo de idiomas: `grep -q` sale corriendo al primer acierto, `ss` recibe un SIGPIPE y muere con 141, y `pipefail` se queda con ese 141 — así que la condición es falsa **aunque el puerto esté ocupado**. Estaba en `free_port` y en `_port_taken_by_other`, una vez por puerto candidato.

Hoy no saltaba porque la salida de `ss` cabe en el buffer de la tubería —unos 64 KB, más de mil sockets—, y por eso llevaba ahí sin dar la cara. El modo de fallo cuando salta es el peor posible: Orbit entrega un puerto que ya tiene otro proceso, y la unidad nueva muere con `EADDRINUSE` en el bucle de `Restart=always`. Medido con un productor que no cabe en el buffer: la tubería devuelve 141 y la comprobación miente.

Ahora `ss` se lee **una vez** a una tabla en memoria (`_listening_into`) y se consulta ahí. La prueba nueva reproduce el caso con un doble de 40.000 líneas cuyo acierto está en la primera; se comprueban también IPv6 —`[::]:3004` tiene sus propios dos puntos, y el puerto es lo que sigue a los **últimos**— y que la cabecera de `ss` no se cuente como puerto ocupado.

Y el mismo patrón en `install.sh`: `swapon --show | grep -q .` decía «no hay swap» justo cuando sí la hay, y lo que va detrás es un `fallocate` sobre `/swapfile` — crear de cero un fichero que puede estar montado como swap en ese momento.

### Cambiado — el contrato `--json` cuesta la mitad, y la lista también

Los ayudantes JSON (`_j_str`, `_j_num`, `_j_bool`, `_j_list`) **escriben por stdout**, igual que el `printf` que los rodeaba, así que cada `"$(_j_str …)"` sólo añadía un fork para recoger lo que ya iba al mismo sitio. Se llaman en vez de capturarse. Lo mismo con las siete palabras traducidas de `orbit list`, que no dependen de la app y estaban dentro del bucle, y con un `printf -v` en lugar de `"$(printf …)"` para rellenar una columna a nueve caracteres.

Medido con 40 apps, contando los `clone()` de verdad con `strace`:

| | antes | ahora |
|---|---|---|
| `orbit list --json` | 842 procesos, 630 ms | 242, 250 ms |
| `orbit list` | 327 procesos, 330 ms | 167, 190 ms |
| `free_port` | 80 procesos, 100 ms | 0, 42 ms |

Importa porque es de lo que vive Orbit Desktop (§13.4): su latencia es la de la interfaz. `list` es además el comando que más se teclea y la portada del menú.

**La salida no cambia ni un byte**, y eso se ha comprobado en vez de suponerlo: el volcado de `list --json`, `info --json` y las comprobaciones de puertos con cuatro apps —tipos distintos, alias, releases, certificado, mantenimiento, comillas y `%` dentro de los valores— es idéntico carácter a carácter al del código anterior.

De contar releases con un glob en lugar de `find | sort | wc -l` salen tres forks por app; con `nullglob` puesto, cero releases son cero elementos.

### Corregido — una suite entera de pruebas llevaba desde su commit sin ejecutarse

`tests/provision_test.sh` no estaba en el `Makefile`. Son **36 comprobaciones** de lo que declara un `orbit.json`: credenciales generadas, que un redespliegue no le cambie a nadie la contraseña, travesía de rutas y escritura a través de enlaces simbólicos.

No lo vio nadie porque el recuento del final **sólo suma las suites que sí se lanzaron**: un fichero ausente de la lista no deja hueco en ninguna parte, y las otras 31 salían en verde. Ni saltada ni en rojo — es que no estaba.

- **Entra en `make test`**, y al ejecutarla apareció debajo el tercer estado de siempre: sin `jq` se ponía **en rojo** en vez de saltarse, porque sin `jq` no se aplica ningún descriptor (ARCHITECTURE §18.9b) y sus primeras afirmaciones dejan de ser ciertas *por diseño*. Ya se salta anunciándolo; comprobados los dos caminos, con `jq` (36) y sin él (31).
- **`make check` cruza la clase entera**: los ficheros `tests/*_test.sh` que hay contra los que el target `test` invoca, y falla si sobra alguno. Es la forma de la comprobación de glifos de la v1.2.8 — se compara el conjunto, no el nombre que se te ocurra. Verificado poniéndolo en rojo antes de arreglarlo.

Con esto son **32 suites y 2.434 comprobaciones**, y de paso se han vuelto a medir las dos cifras que documentaban qué se prueba sin las herramientas opcionales: eran «1.232 contra 1.916» en `docs/DEVELOPMENT.md` y «777 contra 1.510» en el `Makefile`, dos pares que ya no coincidían ni entre sí. Medido apartando `jq`, `rsync`, `nginx` y `php-fpm` del `PATH`: **1.649 contra 2.434**.

### Y una lección de método, porque la primera versión de estas notas traía dos cifras falsas

Los números de arriba están medidos **después** de escribir el cambio, no durante. Los comentarios del código traían de la primera pasada un «1.240 procesos en un `orbit list --json`» que no existe —`_app_config_json` sólo lo llama `_info_json`, o sea **una** app y 62 forks— y un «873 ms» para la tabla que no se reproduce por ningún lado: son 330. Ninguna de las dos cambiaba la decisión de hacer el cambio, y las dos habrían sobrevivido a tres revisiones, porque una cifra dentro de un comentario no la comprueba nadie. Es la misma clase de dato que el «8 sitios» que eran 11.

## [1.2.8] - 2026-08-12

### Corregido — el instalador moría en el banner, y no instalaba nada

`install.sh` imprimía `"$G_SEP"` en la línea de la versión y ese nombre **no estaba en su tabla de glifos**. Con `set -u` eso no es un símbolo que falta: es un `unbound variable` que mata el script, y la línea del banner corre justo después de comprobar que eres root — o sea que el instalador abortaba antes de tocar un solo paquete, en cualquier terminal y en los dos idiomas.

Viene de `60bc7cb`, que cambió el `·` literal del banner por la variable de la tabla y no la añadió al otro lado. `orbit` no tenía el problema; era sólo el instalador.

- **`G_SEP` entra en la tabla**, con su versión ASCII para la terminal sin UTF-8, que es exactamente donde más se instala
- **Y la prueba mira la clase entera, no el nombre**: `install_test.sh` cruza todos los `G_*` que el script usa contra los que declara, y ejecuta el banner de verdad con `set -u` puesto en los dos caminos del logotipo. `ui_test.sh` hace el mismo cruce sobre `orbit`

La lección, que es la de siempre en este fichero: estas pruebas extraían funciones sueltas de `install.sh` para no instalar al cargarlo, y así **ninguna llegaba a ejecutar el banner**. Lo que no se ejecuta no está probado, por muchas comprobaciones que haya alrededor.

## [1.2.7] - 2026-08-12

### Añadido — avisos por correo, y un `notify test` que dice la verdad

El correo llevaba en el ROADMAP desde el principio con su motivo escrito al lado: «un VPS limpio no puede enviarlo y falla en silencio». Eran dos problemas, y **el segundo no era del correo**.

- **La entrega va por un relé tuyo**, con `curl`, que ya era dependencia y habla SMTP desde hace veinte años. Orbit no monta un MTA y no va a montarlo: un VPS limpio no tiene con qué entregar, casi todos los proveedores bloquean el puerto 25 de salida, y lo poco que saliera sin reputación acabaría en spam de quien tenía que leerlo. Con relé lo entrega quien ya sabe hacerlo. Cero dependencias nuevas (principio 6) y nada residente (principio 2)
- **Varios destinatarios**, separados por comas: un aviso que sólo puede ir a una persona se pierde en cuanto esa persona está de vacaciones
- **Con contraseña, TLS obligatorio**, y no es configurable: un `AUTH` sin cifrar entrega la contraseña del correo de alguien a cualquiera que mire la red. Sin contraseña no se exige, porque ese caso es un relé en la propia máquina y exigirlo sólo impediría usarlo
- **El charset va declarado.** Todos los mensajes de Orbit llevan acentos y comillas españolas, y sin la cabecera el cliente los pinta como bytes sueltos

### Corregido — `orbit notify test` anunciaba «Enviado» pasara lo que pasara

Esta es la mitad que no era del correo, y la que de verdad valía la pena. `notify test` llamaba a `notify`, que **se traga los fallos por diseño** —lo llama el vigilante a mitad de un arreglo, y un aviso que no sale no puede tumbar el reinicio que estaba en marcha—, y luego imprimía «Enviado» sin mirar nada. Un token caducado, un webhook borrado y una contraseña mal escrita daban exactamente la misma línea verde.

Los canales pasan a ser una función cada uno, con la misma forma, y `test` los prueba **uno a uno** diciendo cuál ha fallado, con qué código de curl y con la última línea de curl, que es la que dice si fue «Login denied» o «Could not resolve host». Sale con código distinto de cero si alguno falló, para que un script lo note. `notify` sigue tragándoselos, que es su trabajo.

La prueba nueva (`tests/notify_test.sh`) levanta un **servidor SMTP de mentira de verdad** —acepta la conversación entera y guarda el mensaje— porque con curl de por medio la única forma de saber que el correo sale es que algo lo reciba. Siete mutaciones ejecutadas una a una: quitar el TLS obligatorio, quedarse con un solo destinatario, no declarar el charset, hacer que `test` vuelva a mentir, contar un token de Telegram sin chat como canal, dejar que un canal roto tumbe a quien llama y saltarse el nivel mínimo.

Y verificado en el servidor de pruebas contra el binario instalado, en los dos sentidos: con el relé escuchando, `mail: enviado` y el mensaje entero en el buzón; con el relé apagado, `mail: no ha salido (curl 7)` y el motivo debajo.

## [1.2.6] - 2026-08-12

### Añadido — `orbit traffic`: analítica de acceso sin analítica

Lo que quedaba de la v1.3 junto a las métricas y el vigilante. `orbit traffic [app] [--since 7d]` suma el log de acceso que nginx **ya** escribe: peticiones, IPs distintas, bytes, reparto por código, tiempos de respuesta, rutas más pedidas, referencias externas y una gráfica por hora. Sin cookies, sin JavaScript en la página de nadie y sin un solo proceso nuevo — la misma decisión que en §18.10, leer lo que ya existe en vez de montar un recolector, y la razón por la que esto cabe en Orbit cuando un panel web no cabe.

Lo que hace legítimo el resultado no es la suma, es lo que se dice sobre ella:

- **Son IPs, no personas**, y el comando lo repite cada vez. Sin cookies no hay forma de distinguir dos pestañas de dos visitantes, y llamarlas «visitas» sería inventar precisión
- **Lo automático se cuenta aparte.** En el servidor de pruebas, con una IP pública y un dominio real, **el 97% del tráfico eran escáneres** buscando `/.git/config`, `/wp-login` o `/server-status`. Sumarlos a las visitas convierte cualquier medición en ruido; el reparto usa una lista conservadora de agentes que se anuncian como automáticos, porque meter ahí navegadores raros convertiría el número en una opinión
- **Una ventana que el log ya no cubre se anuncia recortada.** logrotate se lleva los logs a los catorce días, así que `--since 30d` en un servidor de dos semanas tiene una respuesta más pequeña que la pregunta. Devolverla sin decir nada es el peor final posible, porque un número siempre parece una respuesta. En el contrato es el campo `complete`
- **Los percentiles salen de cubos y se dicen como «≤ X»**, que es exactamente lo que un cubo puede afirmar. Ordenar un millón de tiempos dentro de mawk no es ordenarlos: es escribir un quicksort en awk
- **Sólo se abren los ficheros que pueden aportar algo:** el mtime de un rotado es posterior a su última línea, así que uno más viejo que el corte no se abre. Es la diferencia entre leer un fichero y leer quince
- `orbit traffic --json` entra en el contrato; la barra por horas se cae a ASCII en una terminal sin UTF-8, como el resto de los símbolos (§20.9)

Tres cosas salieron de ejecutarlo y no de escribirlo. **`date -d "2026-08-11 20:00:00 +1 hour"` devuelve las 22:00**, porque el «+1» se lee como huso horario: la serie se rellena con aritmética de epoch. **Una hora sin tráfico es un cero y no una hora que desaparece**, porque saltársela encoge los huecos y dibuja dos picos separados por un día como si fueran seguidos. Y **más de dos días no caben en una línea de terminal**, así que se agrupa por días y se dice en la etiqueta.

Documentación: ARCHITECTURE §13.8 y USAGE. `tests/traffic_test.sh`, nueva, con nueve mutaciones ejecutadas una a una para comprobar que se pone en rojo — no quitar la cadena de consulta de las rutas, contar los bots como visitas, quitar el filtro de ventana, callar el aviso de horizonte, abrir los rotados viejos, volver al suelo en el percentil, contar las referencias propias, quitar el techo de claves y saltarse los huecos de la serie. De escribirla salieron dos trampas ya documentadas, mordiendo en su propio terreno: un `?` sin comillas que **nullglob** se llevó entero, y una variable `B` en la prueba que pisaba la marca de negrita de `orbit` y volcaba el análisis dentro de cada título.

## [1.2.5] - 2026-08-12

### Añadido — `orbit queue`: las colas de Laravel, por temporizador y sin worker residente

Era lo que quedaba de §18.9, y estaba escrito desde entonces cómo tendría que ser: un temporizador y no un proceso que no termina. `orbit queue enable <app>` y cada minuto un ciclo de `queue:work --stop-when-empty` dentro de la release activa. El razonamiento de por qué **no** hay un worker residente sigue donde estaba —carga el código una vez y se queda con la release anterior después de cada despliegue, y la respuesta de Laravel a eso (`queue:restart`) no reinicia nada sino que deja una señal en la caché—; lo que hay aquí es la otra mitad.

Lo que costó no fue llamar a artisan. Fueron las cuatro decisiones de alrededor, y tres salieron de buscarle agujeros al cambio antes de que hubiera un servidor donde probarlo:

- **El ciclo tiene que terminar, y su límite se deriva del intervalo.** `--stop-when-empty` no basta: una cola que recibe trabajos más rápido de lo que los ejecuta no se vacía nunca, y ese `queue:work` se convierte —por el camino largo y sin que nadie lo decida— en el worker residente que este diseño evita. Va con `--max-time`, y su valor es `QUEUE_EVERY × 60 − 5` y no un ajuste aparte: si un ciclo pudiera durar más que su propio periodo, el siguiente arrancaría con el anterior dentro
- **Y el límite es de la pasada, no de cada app.** Con tres apps ocupadas, tres ciclos de 55 s son 165 s dentro de una ventana de 60: systemd mataría la pasada al llegar a su `TimeoutStartSec` y dejaría **una unidad en rojo cada minuto en un servidor sano**, que es justo el ruido que vuelve inútil la única señal que tiene este comando. La pasada reparte un presupuesto y la app que se queda sin tiempo no pierde nada: sus trabajos siguen ahí y la siguiente empieza por ella
- **`current` se resuelve una vez, al empezar.** Con el `cd` sobre el symlink a secas, un despliegue a mitad de ciclo deja al worker abriendo unos ficheros de una release y otros de la siguiente, que es peor que cualquiera de las dos
- **Lo ejecuta el usuario de la app** y no el de despliegue (§5.3). Es el descuido que ya costó cuatro fallos en Laravel, Go y el `.env`
- **Un ciclo fallido deja la unidad en rojo y ahí se queda hasta que otro salga bien**, como en el autodespliegue: una cola sin procesar no da ningún error —la web contesta 200 y los correos simplemente no salen—, así que ese rojo es todo el aviso que hay. `orbit doctor` lo cuenta sin apagarlo, y la notificación va por el vigilante, que avisa de la transición y no del estado: con el temporizador pasando cada minuto, avisar del estado serían sesenta mensajes iguales por hora
- **Saltarse un ciclo no es fallar**, y se distingue: app en mantenimiento —durante un despliegue, o porque alguien la bajó a propósito—, sin release, o el ciclo anterior todavía dentro
- **La latencia se dice al activarlo**, no cuando alguien pregunte por qué un correo tardó un minuto. Es el precio del diseño, y para una cola que tiene que contestar en segundos la respuesta honesta es que esto no sirve
- `orbit queue status --json` entra en el contrato, `orbit info --json` gana el campo `queue`, y un clon no hereda el permiso — un staging que vacía la cola manda de verdad los correos que se encuentre

### Corregido — que no haya `QUEUE_CONNECTION` no significa que no haya cola

Esto lo encontró ejecutar el producto en el servidor de pruebas, no ninguna revisión: **desde Laravel 11 el valor por defecto del framework es `database`, no `sync`**. Y el `.env` que crea Orbit no trae la clave, porque el esqueleto de Laravel tampoco. O sea que la app encolaba en la base de datos, no lo ejecutaba nadie, y el aviso que existe precisamente para contar ese silencio se callaba, porque leía una clave ausente como un «no». Se comprobó contra un Laravel 13 recién desplegado: `orbit doctor` no decía nada de una cola que llevaba días acumulando.

Ahora el valor se lee del `.env` y, si no está, del `env('QUEUE_CONNECTION', '…')` de `config/queue.php`, que es la declaración autorizada. Si no se puede leer ninguno de los dos se calla, como antes: un aviso falso en cada despliegue es peor que un aviso que falta (la lección de `ALLOWED_HOSTS`).

Documentación: ARCHITECTURE §18.9 y USAGE. `tests/queue_test.sh`, nueva, con las mutaciones que tienen que ponerla en rojo ejecutadas una a una — quitarle `--stop-when-empty`, quitarle `--max-time`, no descontar el presupuesto entre apps, ejecutarla como `deploy`, quitarle el cerrojo, dejar de resolver el symlink y no devolver fallo. Y ejercitado de punta a punta en el VPS contra un Laravel de verdad.

## [1.2.4] - 2026-08-12

### Añadido — Qwik, que era el último stack pendiente del ROADMAP y llegó con su agujero puesto

Se detecta Qwik y lo que decide todo es el adaptador, como en SvelteKit. Lo que **no** es como en SvelteKit es cómo se encuentra: allí el adaptador es un paquete y basta con mirar las dependencias, y aquí no lo es —los adaptadores viven dentro de `qwik-city`, así que ninguno aparece en el `package.json`—. Lo que sí deja `qwik add` es un directorio, `adapters/<nombre>/vite.config.ts`, y esa es la señal. Verificado compilando cuatro proyectos de verdad de `npm create qwik@latest` 1.20.0, uno por adaptador.

- **`vite` está en las `devDependencies` de todo proyecto de Qwik**, así que la rama de Vite se lo llevaba entero: `static`, `dist/`, respaldo de SPA. Medido sobre los proyectos compilados: **sin adaptador de servidor, `dist/` no tiene `index.html`** —ni una sola página, sólo los bundles y un `404.html`—, o sea que el respaldo apunta a un fichero que no existe. No es una degradación: es la web entera en 404. Le pasaba igual a los adaptadores de Express y de node-server, que son los dos que la gente usa en un VPS
- **Y el adaptador de Express le añade `express` a las `dependencies`**, así que ni siquiera esa segunda señal salvaba el caso: la rama de Vite está antes que la de Express en el encadenado. La de Qwik va delante de las dos, y por eso
- **El arranque sale del script `serve`**, que es lo que escribe el propio adaptador y su declaración autorizada. Nunca de `start`: en Qwik `start` es `vite --open --mode ssr`, o sea el servidor de **desarrollo**. Es el único de los diecinueve stacks donde `start` no arranca la app en producción, y el genérico lo habría cogido — la mutación que lo prueba deja `vite --open --mode ssr` como orden de arranque de producción en ocho comprobaciones
- **El tipo dice el runtime**: `node` para express, node-server y fastify; `bun` y `deno` para los suyos, porque de ahí salen el binario que exige `orbit doctor` y lo que enseña `orbit list`. Comprobado arrancando el `node-server` compilado: lee `PORT`, escucha en él y devuelve 200 con el HTML servido desde el servidor
- **El adaptador `static` es el único que deja un sitio servible**, y va sin respaldo de SPA: prerenderiza una página por ruta y emite un `404.html` de verdad, que con el respaldo no se usaría jamás
- **Sin adaptador, o con uno de Cloudflare, Vercel, Netlify, AWS o Azure, se avisa y se va con proceso** (§18.8): así el despliegue falla en voz alta y hay rollback, en vez de publicar un sitio roto que parece desplegado. El aviso dice qué ejecutar, porque un despliegue que falla sin explicar por qué manda a depurar nginx
- **Qwik 2 (`@qwik.dev/core`, `@qwik.dev/router`) se reconoce igual.** Renombró los paquetes y mantuvo la convención de adaptadores, que es de lo que cuelga todo lo demás
- Monorepos incluidos, sin tocar nada: la traducción de coordenadas de §18.9b se encarga, y las pruebas lo fijan con la app en `apps/web`

Documentación: ARCHITECTURE §18.11. 21 comprobaciones nuevas en `tests/detect_test.sh`, y las tres mutaciones que tienen que ponerlas en rojo, ejecutadas.

## [1.2.3] - 2026-08-12

### Corregido — el tic verde era un emoji, y salía de otro color y de otro ancho

Estaba escrito desde el 7 de agosto en la rama de la web, sin mergear. La web se ha ido a su propio repositorio; esto no era de la web y se queda.

- **`✔` (U+2714) y `✖` (U+2716) están en `emoji-data`.** No lo parecen —en un editor salen como texto— pero fontconfig se los cede a la fuente de emoji en color, y a partir de ahí el `${GRN}` de delante no pinta nada (el emoji trae su propio verde, y `NO_COLOR=1` tampoco lo apaga) y ocupa **dos celdas**, así que todo lo alineado detrás con `printf '%-18s'` quedaba corrido una posición, y sólo en las líneas con tic. `✓` (U+2713) y `✗` (U+2717) no están en esa lista: los pinta la monoespaciada y obedecen al color. El script usaba los dos pares mezclados, y por eso el mismo servidor enseñaba un tic normal en un sitio y un icono raro en otro
- **`⎇` (U+2387) era un cuadrado vacío.** No es emoji, pero DejaVu Sans Mono —la monoespaciada por defecto de casi cualquier servidor— no lo trae, así que el selector de rama empezaba con un tofu
- **Los símbolos pasan a una tabla única** (`G_OK`, `G_ERR`, `G_ON`, …) al lado del bloque de color, y no queda ninguno escrito a mano dentro de un `printf`. Mismo arreglo en `install.sh`

### Añadido — repuesto en ASCII para las terminales que no hablan UTF-8

Un `LANG=C` por SSH —lo que trae un VPS recién creado hasta que alguien genera las locales, y justo donde se ejecuta `install.sh`— convertía cada símbolo de tres bytes en tres borrones, y el logotipo de bloques en seis líneas de basura. Ahora se mira la misma variable que mira la libc (`LC_ALL`, `LC_CTYPE`, `LANG`, en ese orden) y, si no dice UTF-8, la tabla entera se cambia por ASCII de siete bits. `UI_GLYPHS=unicode|ascii` lo fuerza para los casos raros.

- **Lo que la tabla no cubre, dicho aquí para que nadie lo descubra mirando**: los `·` y las rayas que están dentro de las frases. Son texto, no interfaz, y salen mal igual que los acentos; arreglarlo de verdad es generar las locales
- **El `✎` del selector de scripts sale de la clave de traducción.** Dentro, cada idioma tendría que repetir el glifo y la tabla no podría cambiarlo por ASCII — y un selector es lo último que uno quiere ilegible en la terminal donde el problema existe
- La prueba (`tests/ui_test.sh`) no comprueba «hay un tic», que es lo que se escribiría solo: comprueba **que no vuelva a colarse ninguno de los dos que son emoji**, ni en `orbit` ni en `install.sh`, y que en la rama ASCII no salga ni un byte por encima de 0x7F. Y `tests/lib.sh` fija `LC_ALL` a UTF-8, porque si no media suite compararía contra `✓` o contra `+` según la máquina

Documentación: nueva sección ARCHITECTURE §20.9.

## [1.2.2] - 2026-08-12

### Corregido — el diagnóstico contaba el mantenimiento de Laravel y se callaba el suyo

Salió de auditar lo único que quedaba del reinicio: qué deja un despliegue que muere a mitad. De los tres residuos posibles, dos ya estaban cubiertos —la release a medio construir nunca llega a `current`, y la unidad puente ni se hace `enable` ni se retira sin oír antes a la canónica— y el tercero era el testigo de mantenimiento.

- **`orbit doctor` dice ahora que una app está en mantenimiento**, y desde cuándo. Ya lo decía del `php artisan down` de Laravel, que es el mismo agujero por el otro lado; el propio de Orbit era el que no se mencionaba, y es el que puede dejar un despliegue muerto
- **Sin acción, tampoco con `--fix`.** Un mantenimiento se pone a mano y con motivo: publicar una web que alguien había bajado a propósito es peor que dejarla bajada. Es la misma regla del autodespliegue en rojo de la 1.2.0, y la mutación de ponerle una acción la caza la prueba
- **Sin umbral, a diferencia del vigilante, y es deliberado.** `orbit watch` corre cada minuto y **notifica**, así que espera a `WATCH_MAINT_MAX` para no dar una alarma falsa por un mantenimiento de dos minutos. El diagnóstico lo pregunta una persona ahora mismo, y «esta web responde 503» nunca es ruido cuando lo que se pregunta es qué va mal
- **Y una comprobación que valía la pena hacer en vez de razonar**: con un `reboot` ordenado el testigo no se queda, porque **bash sí ejecuta la trampa `EXIT` cuando lo mata un SIGTERM** — lo contrario de lo que se diría de memoria. El residuo sólo aparece sin SIGTERM: `reboot -f`, corte de luz, o un SIGKILL por agotar el `TimeoutStopSec`

### Documentación — el reinicio, repetido a las dos horas, y el inventario que no cuadraba

- **El script de comprobación se volvió a pasar a la hora y cincuenta minutos del arranque**, y responde a otra pregunta que la primera pasada: una comprobación a los dos minutos no distingue «arrancó» de «arranca y se muere en bucle», porque con `Restart=always` las dos dan `is-active`. Lo que las separa es el contador de reinicios, y sigue en 0
- **Las 34 comprobaciones son 11 sitios y 6 pools de php-fpm, no 8 sitios**: ese número venía de la tanda anterior y se arrastró a mano. Con 8 la cuenta no sale, y queda escrito de qué se compone el total para que no vuelva a pasar
- Lo que sigue sin medirse en la máquina es el reinicio ocurriendo **a mitad de un despliegue**, pero ya no como razonamiento entero: los tres residuos están enumerados, dos tienen código que los cubre y el tercero tiene prueba (ARCHITECTURE §5.5)

## [1.2.1] - 2026-08-12

### Verificado — la máquina se ha reiniciado de verdad, y ha vuelto sola

Era la mitad que faltaba de la tanda del VPS, y la única que no se podía hacer desde dentro. **34 comprobaciones sobre el servidor recién arrancado, 0 fallos, cero intervención**: las 5 apps con proceso levantadas por systemd, nginx y php-fpm con sus 6 pools, y los 11 sitios sirviendo. (Esta entrada decía «8 sitios» al publicarse: era el inventario de la tanda anterior, y con 8 las 34 comprobaciones no cuadran. Corregido en la 1.2.2.)

- **Lo que hace que funcione es que Orbit no participa.** En el arranque no corre nada suyo —ni un `orbit boot`, ni una unidad que recorra las apps, ni un `ExecStartPre` que repare nada—: vuelve lo que systemd tenía apuntado, en cuatro sitios y ninguno propiedad de Orbit. Es el principio 3 en su forma literal: si el binario desaparece del disco, la máquina arranca igual
- **El `enable` se reafirma en cada despliegue**, no sólo al crear la app, por el mismo motivo por el que la unidad se reescribe entera: que el disco no pueda contradecir a la configuración
- **`After=…postgresql.service` ordena, no garantiza.** Quien sostiene el caso raro es `Restart=always` con `RestartSec=3`; el orden está para que el log del arranque no se llene de cadáveres, no como red de seguridad
- **Y queda dicho qué se saltaba la prueba barata** —parar todo y levantarlo desde una sesión que vive en la máquina—: el orden real del arranque, las dependencias que en frío aún no están, y si la máquina vuelve siquiera. `systemd-analyze verify` valida la sintaxis de una unidad y no dice nada de eso
- **Lo que sigue sin medirse**, para que no se dé por cubierto: un reinicio **a mitad de despliegue**. Por diseño es inofensivo —la unidad puente no se hace `enable`, y la canónica arranca sobre lo que apunte `current`—, pero eso es el razonamiento, no una medición

Documentación: nueva sección ARCHITECTURE §5.5. Sin cambios de comportamiento.

## [1.2.0] - 2026-08-12

### Corregido — un autodespliegue fallido dejaba el servidor en «degraded» sin que nadie lo dijera

Lo vio la tanda del VPS al romper un build a propósito. **La unidad en rojo no es el fallo**: es deliberada, es el aviso de que el automático no está funcionando, y la pasada siguiente la pone en verde sola. Lo que fallaba era el silencio alrededor.

- **`systemctl is-system-running` pasa a decir «degraded»** en cuanto hay una unidad en `failed` —lo que mira media monitorización— y **`orbit doctor` no lo mencionaba**. El sitio al que uno va a preguntar qué pasa era justo el que se callaba. Ahora lo dice, con el comando para ver qué ocurrió
- **Y no lo arregla solo, a propósito.** Un `reset-failed` automático borraría la única señal de que los despliegues automáticos están fallando: apagar la alarma no es apagar el fuego. Va sin acción, así que `--fix` lo deja en rojo. La mutación de ponerle una lo caza
- **Quien sí lo limpia es `orbit autodeploy disable`**, y ahí sí toca: al retirar el temporizador ya no hay pasada siguiente que pueda ponerlo en verde, así que ese `failed` se quedaba **para siempre**, y con él un servidor que se lee como degradado por una unidad que nadie va a volver a ejecutar
- **Comprobado en el servidor** con la unidad forzada a fallar: doctor lo cuenta, `--fix` la deja en rojo, y `autodeploy disable` la devuelve a `inactive`

## [1.1.9] - 2026-08-12

### Cambiado — lo que dejó la segunda tanda: los seis stacks con proceso, y lo que sigue sin probarse

Documentación. Next, Django, Laravel, Go, Bun y Deno están ya desplegados de punta a punta en un VPS, y **cada uno menos Bun y Deno trajo un fallo**.

- **El patrón de los cuatro últimos queda escrito junto**, porque es uno solo: todos vienen del refactor del aislamiento (§5.3) y todos son el mismo descuido —un sitio que siguió usando el usuario de antes— en un rincón distinto. La pregunta al cambiar quién ejecuta algo no es «¿he cambiado la función?» sino **«¿quién más escribía en lo que ahora es de otro?»**
- **Del arranque tras reiniciar se dice qué mitad está probada**: parar todo y levantarlo deja las 5 apps con proceso, nginx y php-fpm en pie y los 8 sitios sirviendo, con las unidades `enabled` y validadas. El reinicio de verdad no se puede hacer desde una sesión que vive en la máquina, así que queda un script de 34 comprobaciones en `/root/COMPROBAR-TRAS-REINICIO.sh`
- **Y dos cosas del entorno que no son de Orbit pero cuestan una hora**: los toolchains de Go, Bun y Deno hay que instalarlos a mano donde los vea el `PATH` de las unidades, y el Bun por defecto **muere con SIGILL** en un Xeon sin AVX2
- **Más un residuo**: un autodespliegue fallido deja `orbit-autodeploy.service` en `failed` para siempre y la máquina se lee como `degraded` hasta un `systemctl reset-failed`. `orbit doctor` no lo dice

## [1.1.8] - 2026-08-12

### Corregido — `~/.cache` era de root, y con eso Go no se podía desplegar

Salió al desplegar un **Go** de verdad en el VPS, que era de los stacks con proceso que faltaban:

```
failed to initialize build cache at …/shared/home/.cache/go-build:
mkdir …/.cache/go-build: permission denied
```

- **`install -d -o X a/b/c` le pone el dueño al último componente, no a la ruta.** Los intermedios los crea quien ejecuta, que aquí es root, así que `~/.cache` y `~/.cache/node` quedaban de `root:root` dentro del HOME de la app
- **Node nunca se enteró** porque Orbit le crea la ruta **entera** de corepack: la hoja lleva dueño y no necesita crear nada más. Cualquier otra herramienta que quiera su propia carpeta dentro del caché —`go build` y su `.cache/go-build`— se estrella, y **Go no se podía desplegar en ninguna app aislada**
- **Deno se libró por casualidad**: su `DENO_DIR` está en `shared/deno`, fuera de `.cache`
- **Ahora los niveles van en una lista** (`app_home_tree`), que usan el render de la unidad y el build — una lista y no dos, por el mismo motivo de siempre. La prueba comprueba que a la llamada van los cuatro niveles, que es lo único que se puede ver sin root

### Verificado — Go, Bun y Deno de punta a punta en el servidor

Los tres detectados, compilados, arrancados por systemd con su usuario propio y sirviendo. Dos apuntes del camino: Orbit **no instala** estos toolchains a propósito (§18.6), así que hubo que ponerlos a mano en `/usr/local/bin`, que es donde los ve el `PATH` de las unidades; y el binario por defecto de Bun **muere con SIGILL** en un Xeon sin AVX2 — hay que usar su build `baseline`, y eso no es cosa de Orbit pero conviene saberlo antes de perseguir el fallo.

## [1.1.7] - 2026-08-12

### Corregido — el aislamiento de `unit_test` se perdía a mitad de fichero

Continuación de la v1.1.7 anterior… mejor dicho, de lo que arregló la **1.0.7**: aquello tapó una sección y el fallo seguía vivo en el resto del fichero. Lo destapó tener más apps en el servidor.

- **`unit_test.sh` ya doblaba `ss` desde la primera línea**, con el motivo escrito al lado: sin él, el resultado depende de lo que escuche la máquina. Pero una sección intermedia lo sustituye por un doble con salida propia y terminaba con `unset -f systemctl ss` — y eso **devuelve el `ss` de verdad** a todo lo que viene después
- **Se notaba distinto según cuántas apps hubiera**: con una en el 3001 caía la sección de `orbit port` (arreglado en la 1.0.7, tapando sólo esa); al aparecer dos más en el 3004 y el 3005 empezó a caer también «web4 recibe 3004». La misma causa cambiando de sitio
- **Ahora se repone en vez de quitarse**, que es lo que hace que la regla valga para el fichero entero, y la comprobación de la 1.0.7 se queda con el comentario que explica por qué. La mutación de volver al `unset` pone cuatro en rojo con las apps de prueba levantadas

## [1.1.6] - 2026-08-11

### Corregido — `orbit new --db` sobre Laravel creaba la base de datos y dejaba la web en 500

Tercer hallazgo del Laravel del VPS, y el más fácil de vivir sin entender: Orbit creaba el PostgreSQL, lo anunciaba en verde, y la app contestaba 500 a todo con la base recién hecha al lado sin usar.

- **Laravel no lee `DATABASE_URL`.** Mira `DB_CONNECTION`, y su valor por defecto es **sqlite**, así que se iba a buscar un `database/database.sqlite` que no existe: «Database file at path […] does not exist» en cada petición
- **Ahora, cuando la app es Laravel, se escriben también `DB_CONNECTION=pgsql` y `DB_URL`**, que son las dos que Laravel sí entiende. No es meterse en la configuración de nadie: Orbit ya escribe la `APP_KEY` en ese mismo fichero, y acaba de crear la base de datos que esas dos líneas describen
- **Y el aviso que debía cubrir esto se saltaba justo el caso peor.** Existía —«esta app usa sqlite y el fichero vive dentro de la release»— pero pedía **ver** un `database/database.sqlite`, y el esqueleto de Laravel no lo trae: está en su `.gitignore`. Así que la app recién clonada, la que va a estrellarse seguro, era exactamente la que no avisaba. Ahora salta sin `DB_CONNECTION` exista el fichero o no, y dice cuál de las dos cosas va a pasar: perder los datos en el despliegue siguiente, o el 500 en cada petición
- **Comprobado de punta a punta**: `orbit db create` → `orbit deploy` → `orbit migrate` aplicando las migraciones sobre PostgreSQL → sesiones en base de datos y la web en 200

## [1.1.5] - 2026-08-11

### Corregido — dos sitios que el aislamiento por app dejó atrás, y con ellos Laravel entero

Salieron al desplegar un **Laravel** de verdad en el VPS. Los dos son el mismo descuido: cuando la v1.0.3 separó el fetcher del builder (§5.3), estos dos sitios se quedaron con el sombrero de antes.

- **Las cachés de artisan corrían como `deploy`.** Desde §5.3 la release es del usuario de la app, así que `config:cache` moría con «Failed to open stream: Permission denied» sobre `bootstrap/cache/`, y el despliegue abortaba **siempre**: con el aislamiento puesto —o sea, en toda app creada desde la v1.0.3— **Laravel no se podía desplegar en absoluto**. Los otros dos pasos de artisan ya usaban `as_app`; sólo este se quedó atrás
- **Y la suite no podía verlo**, que es lo que lo mantuvo vivo: doblaba `as_deploy` y `as_app` al mismo shell, así que el reparto de papeles —lo único que sostiene §5.3— era invisible. Ahora los dobles **apuntan quién** habría corrido cada cosa, y se comprueba que las cachés y el enlace de storage van con el usuario de la app y que el código lo sigue trayendo el fetcher
- **`_env_write` le robaba el `.env` al usuario de la app.** Terminaba con un `chown "$(app_user)"`, y `app_user()` lee las **globales**: quien llega sin `load_app` —`orbit db create <app>` es el caso real— obtenía `deploy`. El efecto se ve entero en un servidor: `orbit db create` sobre un Laravel aislado dejaba el `.env` en `deploy:deploy`, y el build siguiente moría con `EACCES` leyendo **su propio fichero**. El arreglo del PR #10 estaba en la llamada, y esta línea lo deshacía tres más abajo
- **Ya no se adivina: se conserva.** Reescribir con `cat >` mantiene el inodo —por eso el symlink de la release sigue valiendo— y con él el dueño, así que no había nada que tocar. Quien crea el fichero es quien le pone dueño, y los cuatro sitios que llaman aquí lo crean antes con el suyo

## [1.1.4] - 2026-08-11

### Corregido — `ALLOWED_HOSTS = ['*']` recibía en cada despliegue un aviso falso

Primer fallo salido de desplegar un **Django** de verdad en el VPS, que es lo que quedaba del punto 1 del ROADMAP: la web contestaba 200 y Orbit avisaba de que iba a contestar 400.

- **La lista se dividía sin comillas** (`for h in $hosts`), y eso además de partir por comas **expande comodines**: un `'*'` —que en Django permite cualquier host— se convertía en los nombres de fichero del directorio de turno, así que la comparación con `*` no se hacía nunca. Con un directorio vacío y `nullglob` era todavía peor: el bucle ni se ejecutaba
- **El aviso decía que Django respondería 400 Bad Request** y mandaba a editar un `settings.py` que estaba perfectamente. Y se repetía en **cada** despliegue, que es como se enseña a ignorar los avisos
- **Se divide con `read -ra`**, que parte por el separador sin expandir nada
- **La prueba que faltaba era la simétrica**: la suite comprobaba que el aviso **sale** cuando el dominio no está, y nadie había escrito que **no salga** cuando sí está. Ahora se comprueban los seis casos —`*`, exacto, dentro de una lista, el punto inicial de los subdominios, uno ajeno y vacío— y desde un directorio **con ficheros**, porque en uno vacío el fallo se disfraza

### Verificado — Django, de punta a punta y en un servidor de verdad

Sin cambios de código: era el hueco que dejaba la primera tanda, que sólo probó Next. Detección (`manage.py` → django/pip), build con venv y `collectstatic`, `/static/` servido por nginx, gunicorn bajo systemd con su usuario propio, PostgreSQL, migraciones **avisadas y nunca aplicadas**, y —rompiéndolo a propósito con un `ALLOWED_HOSTS` que no incluía el dominio— el health check recibiendo el 400, el despliegue **fallando en el paso `service`** y **producción sin enterarse**. El reinicio sin corte y el rollback automático quedan así confirmados en un segundo stack.

## [1.1.3] - 2026-08-11

### Corregido — `orbit isolate` dejaba a la app un segundo sin poder leer su `.env`

Lo que quedó anotado como pendiente en la primera tanda de VPS, medido y cerrado.

- **El `.env` es el único fichero 0640 de `shared/`**, y por eso el único que puede quedarse sin lector a mitad de la migración. Al cambiar de dueño, quien sirve sigue siendo el **pool compartido** —que corre como `deploy`— hasta que nginx mueve el tráfico al socket propio: en ese hueco la app contesta **sin su configuración**, y el aislamiento tampoco está puesto todavía. Medido con una sonda a 15 req/s durante un `orbit isolate` real: **3 peticiones servidas sin `.env`**
- **No hay orden que lo evite**, y es lo que hace el arreglo menos obvio: invertirlo deja al pool nuevo sirviendo mientras el `.env` es todavía de `deploy`, y falla exactamente igual
- **Por eso hay un relevo**: durante el cambio el `.env` lo leen los dos —dueño el usuario nuevo, grupo el viejo— y el grupo se cierra **después** de mover el tráfico y de drenar nginx (por lo mismo del §5.2: los workers viejos siguen hablándole al socket compartido un instante más). No abre nada que no estuviera abierto: antes de migrar, el `.env` **era** de `deploy`
- **Con el arreglo, cero fallos** en la misma sonda, y el estado final es el de siempre: `.env` 0640 del usuario de la app, que lee el suyo y no el de la vecina
- **Dos comprobaciones, no una**, y la segunda se ganó a pulso: cerrar el grupo **antes** de mover el tráfico es la otra forma de tener el mismo agujero, y la mutación que lo hacía pasaba en verde hasta que se añadió. Ver ARCHITECTURE §5.4

## [1.1.2] - 2026-08-11

### Cambiado — lo que dejó por escrito la primera tanda en un VPS de verdad

Documentación. `docs/DEVELOPMENT.md` decía que una app con proceso no se había probado nunca fuera del contenedor, y ya no es cierto: se ejercitaron la unidad de systemd, el rollback automático, el reinicio sin corte bajo tráfico, el aislamiento por app, el vigilante, el autodespliegue, certbot con un dominio real detrás de Cloudflare y el ciclo de copia y restauración con base de datos.

- **Los cuatro fallos que salieron** quedan resumidos donde estaba el aviso, con el enlace a su sección
- **Y la lección de método, que costó una hora**: la primera medición de 502 se acusó a sí misma, porque la sonda iba a ~100 req/s contra un `limit_req` de 40 r/s y los 503 del rate limiting parecían un corte del despliegue. Antes de creerse una medición hay que ver qué marca **en reposo**
- **Tres trampas de proceso**, todas caídas al escribir estas pruebas: `pgrep -f` y `pkill -f` se encuentran a **sí mismos** —una vez mató la sesión a mitad de prueba—, y `kill -0` sobre un proceso de otro usuario contesta «permiso denegado», que en bash es el mismo falso que «no existe»
- **Y lo que sigue sin probarse se dice con todas las letras**: Django y los demás stacks con proceso, DNS-01 con token de Cloudflare, el arranque tras reiniciar la máquina, y la ventana de ~1 s de `orbit isolate` en la que el `.env` ya cambió de dueño y nginx aún habla con el pool compartido

## [1.1.1] - 2026-08-11

### Corregido — los certificados se emitían pero **no podían renovarse nunca**

El hallazgo más serio de la tanda en un VPS, porque es de los que no se notan hasta noventa días después. `orbit ssl` emitía el certificado sin problema; `certbot renew --dry-run` fallaba siempre:

```
Invalid response from https://…/.well-known/acme-challenge/…: 404
```

- **La causa es el orden de fases de nginx.** La redirección a HTTPS es un `if` a nivel de `server`, y nginx corre la fase *rewrite* del `server` **antes** de elegir el `location`. Incluir el snippet de ACME más arriba no servía de nada: el `location ^~ /.well-known/acme-challenge/` no llegaba a mirarse, y el reto se comía el 301 igual que cualquier otra ruta
- **Y por eso no se veía: la emisión sí funciona.** Cuando se emite el primero, el vhost todavía no tiene bloque HTTPS ni redirección, así que certbot valida sin estorbo. La redirección se escribe **después**, con el certificado ya puesto — justo a tiempo de romper todas las renovaciones siguientes. El certificado caduca en silencio
- **El arreglo es el patrón de bandera**, porque nginx no encadena condiciones en un solo `if`: el reto de ACME y el visitante que ya viene por HTTPS son ahora dos excepciones a la misma redirección
- **La suite tenía el caso simétrico en verde**, que es lo instructivo: comprobaba que el reto pasa por el servidor **por defecto** —el caso de la emisión— y nadie había escrito el de la renovación, que es el reto contra el vhost de una app que **ya tiene certificado**. Ahora son tres comprobaciones con nginx de verdad, y la tercera —que lo demás **sigue** redirigiendo— existe para que «arreglarlo» quitando la redirección entera no salga en verde
- **Comprobado de las dos formas**: la suite, y `certbot renew --dry-run` contra un dominio real detrás de Cloudflare, que pasó de fallar siempre a «all simulated renewals succeeded». Ver ARCHITECTURE §6

## [1.1.0] - 2026-08-11

### Corregido — tras un primer despliegue fallido, Orbit decía «esto no es tu código» cuando sí lo era

Desplegando en un VPS una rama con un `import` que no existe: compila, activa la release y se estrella en bucle. Orbit contestaba esto:

> El build fue bien, así que esto no es tu código: se ha roto algo entre la release y nginx.
>
>     sudo nginx -t
>     orbit doctor

Las dos frases eran falsas y los dos comandos, inútiles: lo que fallaba era el arranque de la app.

- **La causa es que sólo se miraba el symlink `current`.** El razonamiento original —«si hay release activa, el código compiló y lo que falló es posterior»— es correcto para una estática, donde después sólo queda nginx. Pero en una app con proceso el symlink se mueve **antes** del health check, así que una release que compila y no arranca deja en disco exactamente el mismo rastro que un vhost roto
- **Ahora se le pregunta al puerto.** Con release activa, app con proceso y nadie contestando, el mensaje dice que lo que no arranca es el proceso y manda a `orbit logs` y a `journalctl`. Si la app sí responde, vuelve el mensaje de nginx, que ahí es el correcto
- **Y las variables se leen con `${A_TYPE-}`, no a pelo.** La primera versión las usaba directamente y con `nounset` un `A_TYPE` sin definir mataba la función **a mitad del mensaje**, dejando al usuario con media explicación justo cuando acababa de fallarle el despliegue. Lo cazó la suite, que llama a esta función sin cargar la app

## [1.0.9] - 2026-08-11

### Corregido — los saltos de línea de cuatro mensajes salían como un `\n` literal

Visto en un servidor de verdad, al mirar lo que Orbit contesta cuando un primer despliegue falla:

```
El build fue bien, así que esto no es tu código: se ha roto\n    algo entre la release y nginx.
```

- **La causa está en una decisión correcta de `_t`**: cuando el mensaje no lleva argumentos **no se pasa por el formateador**, y eso está bien razonado donde se decide — dentro puede venir un `%` de un comando de build, y reinterpretarlo se comió argumentos y filtró «invalid format character» en su día. El efecto colateral es que un `\n` escrito en la frase llega **literal**, y `printf "%s"` lo saca tal cual
- **Cuatro sitios lo hacían**: la pista de `pnpm-workspace.yaml`, los dos mensajes de dónde mirar tras un primer despliegue fallido y el uso de `orbit top`. Salía en los dos idiomas, porque el catálogo guarda la misma frase con el mismo `\n`
- **La regla, que los bloques de uso ya cumplían: una frase con `\n` se imprime con `%b`.** `%b` interpreta las barras del argumento pero **no** sus `%`, así que no reintroduce el problema que `_t` evita
- **La prueba es del tipo que caza los que vengan**: recorre el código, junta los mensajes que llevan `\n` y exige que todos se impriman con `%b`. Antes del arreglo nombra los cuatro

## [1.0.8] - 2026-08-11

### Corregido — el reinicio «sin corte» daba 502, y sólo se veía en un servidor de verdad

El hallazgo del punto 1 del ROADMAP: ejercitar en un VPS lo que sólo existe dentro de systemd. Con tráfico real durante el despliegue, el reinicio sin corte de la v1.0.2 dejaba **1-2 respuestas 502 por despliegue** — justo lo que prometía eliminar. Medido: 5 respuestas 502 en 3 despliegues; con el arreglo, **0 en 5**.

- **La causa es que `systemctl reload nginx` vuelve cuando entrega la señal, no cuando el cambio está aplicado.** Durante ese instante los workers de nginx anteriores a la recarga siguen atendiendo con la configuración **vieja**. Orbit paraba el proceso al que nginx acababa de dejar de apuntar **10 ms** después de la recarga, así que las peticiones que todavía iban hacia ese puerto morían con él
- **Pasa dos veces por despliegue**, una por cada mitad del relevo: al mover el tráfico al puente y pararse la unidad canónica, y al volver al puerto canónico y retirarse el puente. Las dos tienen la misma frontera y el mismo arreglo. La tercera es el puente huérfano que recoge el despliegue siguiente
- **`nginx_drain` espera a que los workers de antes de la recarga hayan terminado** antes de parar nada. Cuesta ~0,2 s por recarga con tráfico
- **Es un mejor esfuerzo, y a propósito**: un cliente con keep-alive puede retener un worker viejo hasta 75 s, y bloquear ahí el despliegue sería peor que el 502. Al agotarse el plazo (10 s) se sigue
- **Dos trampas que costó escribir, y las dos estaban ya fichadas en este proyecto.** `kill -0` sobre un worker de `www-data` contesta «permiso denegado», que en bash es el mismo falso que «no existe»: la comprobación daba por drenado **siempre**. Y `pgrep -f 'worker process'` se encuentra a sí mismo y a cualquier shell que lleve la frase escrita, con lo que la espera no terminaba nunca. Se mira `/proc`, que no depende del dueño, y se buscan los workers con `ps -C`, que compara el ejecutable
- **La prueba fija el orden**, que es lo único que separa «sin corte» de «con corte»: entre mover nginx y parar el proceso viejo tiene que haber un drenaje, en las dos mitades. Quitar cualquiera de las dos llamadas pone en rojo su comprobación y sólo la suya. Ver ARCHITECTURE §5.2

## [1.0.7] - 2026-08-11

### Corregido — `unit_test` miraba los puertos de la máquina, y en un servidor de verdad se ponía en rojo

Encontrado al ejercitar el punto 1 del ROADMAP en un VPS: `make test` sale en verde en el contenedor de desarrollo y con **3 fallos** en un servidor que tenga Orbit funcionando. No fallaba el producto; fallaba el aislamiento de la prueba.

- **La sección `orbit port` de `unit_test.sh` no doblaba `ss`.** La sección anterior sí lo hace, pero termina con `unset -f systemctl ss`, así que a partir de ahí `free_port` y `_port_taken_by_other` consultaban los puertos **de la máquina**. Con una app de Orbit escuchando en el 3001 —lo primero que hay en cualquier servidor con esto instalado—, `orbit port web1` la daba por ocupada y movía la app: `sin conflicto no mueve` obtenía 3005 en vez de 3001
- **Es el tercer estado otra vez**, el que este proyecto lleva fichando desde lo de `jq`: ni probado ni saltado, sino **en rojo acusando a código sano** y mandándote a depurar `cmd_port`, que está bien. Y es de los que sólo se ven fuera del contenedor, porque hace falta que algo escuche de verdad
- **El arreglo es una línea** —`ss() { :; }` entre los dobles de esa sección, que es lo que ya declaraba el comentario de al lado: ahí se prueba la lógica de decisión, no el sistema—. Quitarla vuelve a poner las tres comprobaciones en rojo con una app viva en el 3001, y sólo esas tres

## [1.0.6] - 2026-08-11

### Arreglado — el instalador escondía el error de apt, y no miraba los pockets

Las dos cosas las encontró **un servidor de verdad en los primeros cinco minutos**, que es justo lo que el contenedor de desarrollo no puede hacer. Una imagen de Ubuntu 24.04.1 con `Suites: noble` a secas —sin `-updates` ni `-security`— dejaba `build-essential` y `libssl-dev` sin resolver, y lo único que veía quien instalaba era «held broken packages» y un número de línea.

- **`apt_install`, en un solo sitio para las nueve llamadas.** Callado mientras va bien y, al fallar, repite el mismo comando **sin `-qq`** para que apt explique qué paquete no puede resolver y por qué. El `-qq` con la salida a `/dev/null` estaba escondiendo exactamente el dato que hacía falta, en las nueve
- **Los pockets se comprueban antes de instalar nada**, y también al fallar. Sin `-updates`, los paquetes instalados de un point release son más nuevos que los del pocket original y cualquier dependencia de versión exacta deja de resolverse. Y sin `-security` **el servidor no recibe parches** —aunque el propio instalador ponga `unattended-upgrades`, que sin ese pocket no tiene de dónde traer nada—: eso es más grave que el atasco, y ahora se dice
- **Es un aviso, no un portazo**: hay espejos que sirven todo desde un solo pocket. Se dice qué falta, por qué importa y cómo tiene que quedar la línea `Suites:` — enseñando el resultado y no un `sed`, porque el fichero de fuentes se llama distinto en el formato deb822 y en el clásico
- Suite nueva (`tests/install_test.sh`): las funciones se extraen de `install.sh` por nombre, con la misma técnica que ya usan `tests/lib.sh` y el propio instalador para el núcleo de idiomas. Mutación ejecutada — devolverle el `-qq` al reintento pone la prueba en rojo
- **La revisión del PR encontró dos formas de que el aviso mintiera**, y las dos eran ciertas. Con `/var/lib/apt/lists` sin poblar —una imagen recién hecha, o un `apt-get clean`— `apt-cache` no ve ningún repositorio y el aviso acusaba entero a un sistema perfectamente configurado; ahora la comprobación va **después** del `apt-get update` y, si ni siquiera se ve el pocket base, se calla en vez de adivinar. Y el consejo daba por hecho el formato deb822: en el formato clásico (`.list`) no existe la línea `Suites:` —el pocket es el tercer término de cada línea `deb URI pocket componentes`—, así que seguirlo no arreglaba nada y dejaba el fichero roto. El formato se detecta y cada uno recibe su instrucción

## [1.0.5] - 2026-08-11

### Añadido — `orbit init`: la configuración de despliegue viaja con el código

El descriptor `orbit.json` existía desde hace tiempo y manda sobre la detección; lo que faltaba era la forma de escribir el primero sin copiarlo de la documentación.

- **`orbit init [directorio] [--force]`** escribe un `orbit.json` con lo que la detección encuentra: tipo, orden de build, de arranque, carpeta web, docroot, SPA y PHP. Sólo las claves que tienen valor — una clave vacía en un fichero que alguien va a editar a mano invita a rellenarla con cualquier cosa
- **Es el reverso exacto de lo que lee el despliegue**, y hay una prueba de ida y vuelta que lo mantiene así: lo que `init` escribe, `_read_descriptor` lo vuelve a leer igual. Si los dos lados se separan, el fichero dice una cosa y el despliegue hace otra
- **No se auto-eleva a root, y es el único comando que no lo hace.** Escribe dentro del repositorio de quien lo ejecuta, así que elevarse dejaría un fichero de root en su checkout y haría falta `sudo` hasta para borrarlo. Tampoco exige que Orbit esté instalado: se ejecuta dentro de un proyecto, que es justo donde puede no estarlo. La decisión se toma antes del `sudo`, y la función que la toma reconoce las opciones con valor —`--lang en`— para que ese valor no se confunda con el comando
- **Se niega a congelar la rama de repuesto de la detección.** Cuando no se reconoce nada, la detección deja `static` sirviendo la raíz del repositorio y avisa en cada despliegue de que eso publicaría el código fuente. Escribirlo en el descriptor sería peor que dejarlo pasar: como el descriptor pisa a la detección, ese aviso no volvería a salir nunca. Así que sin `index.html` en la raíz, `init` aborta y pide el `type` a mano — y un sitio HTML de verdad sí pasa, porque ahí servir la raíz es lo correcto
- **No pisa un `orbit.json` que ya exista** sin `--force`: dentro puede haber un bloque `env` escrito a mano que la detección no sabe reproducir. Ver ARCHITECTURE §22
- **Y `--force` regenera desde el proyecto, no desde el fichero viejo.** Lo cazó la revisión del PR: `detect_stack` termina leyendo el `orbit.json` que haya, así que con el anterior todavía en su sitio salía un **híbrido** —el tipo, el arranque y la carpeta web de antes mezclados con el build recién detectado—, un fichero que no describía ni el proyecto ni lo que había. Ahora el descriptor que se va a reescribir queda fuera de su propia regeneración; el de una subcarpeta, en un monorepo, sigue mandando, porque lo que se ignora es una ruta concreta y no «los descriptores»

## [1.0.4] - 2026-08-11

### Añadido — un pool de php-fpm por app: la otra mitad del aislamiento

Lo que la v1.0.3 dejó fuera a propósito, y que el propio documento de seguridad admitía: **el código de una página PHP no lo ejecuta la app, lo ejecuta php-fpm**. Con un pool único, todas las apps PHP del servidor corrían como el mismo usuario, así que el dueño de los ficheros daba igual y un `file_get_contents` desde cualquier `.php` se llevaba el `.env` de todas las demás. Ninguna regla de nginx tapa eso, porque nginx no llega a ver la lectura.

- **Cada app PHP aislada tiene su propio pool**, corriendo como su usuario y con su propio socket, y el vhost habla con ese socket. Las apps sin aislar siguen en el pool compartido de siempre
- **`orbit isolate` ya acepta apps PHP** (antes las rechazaba diciendo que no aportaba nada, lo cual era cierto sin pool propio) y les crea usuario y pool a la vez. Sólo se sigue negando con una estática, que no ejecuta nada
- **El socket lo elige el usuario, no el tipo**: una sola condición para las dos cosas, de modo que el estado intermedio peligroso —usuario propio con pool compartido, donde php-fpm ya no puede leer el `.env` que acaba de cambiar de dueño— no se puede representar
- **`open_basedir` como cinturón sobre los tirantes**: el aislamiento real es de dueños, pero un fichero de otra app al que alguien le abriera los permisos sigue estando fuera de alcance
- **El pool se retira con la app, siempre y antes del `userdel`**: uno huérfano apuntando a un usuario que ya no existe deja a php-fpm negándose a arrancar, y con él **todas** las apps PHP del servidor
- **Probado con dos pools de verdad**, que es lo único de todo el aislamiento que el contenedor puede demostrar: la misma sonda en dos apps, la dueña lee su `.env` y la de al lado recibe `DENEGADO`. La mutación de devolver el socket compartido lo pone en rojo. Ver ARCHITECTURE §5.4

### Arreglado — la prueba nueva destapó dos fallos del arnés, ninguno del producto

- El `chmod -R a+rX` que el árbol de pruebas necesita para que php-fpm lea las webs dejaba el `.env` de la app legible por todo el mundo, así que la comprobación de aislamiento habría pasado **sin comprobar nada**. Los permisos de producción se restauran ahora en la propia sección que depende de ellos, donde ningún `chmod` posterior los deshace
- Y **php-fpm sólo baja de privilegios si lo arranca root**: en CI, que corre como un usuario normal, las directivas `user` de los pools se ignoraban en silencio, los dos pools eran el mismo usuario y la prueba se ponía en rojo **acusando a código que estaba bien** — el tercer estado, otra vez. La sección pide ahora el privilegio (root o `sudo` sin contraseña) y, si no lo hay, se salta en voz alta; `test-strict` se niega a dar por buena una tanda con saltos. La suite sigue siendo rootless: es la única sección que pide más, y lo pide porque sin ello la propiedad no existe. Comprobados los tres caminos ejecutándolos: root, no-root con sudo (lo que hace el CI) y sin privilegio

La comprobación de que la app dueña **sí** lee su fichero es la que convierte el «denegado» de la otra en una afirmación.

### Arreglado — dos agujeros más que encontró la revisión del PR

- **Las apps PHP nuevas no nacían aisladas.** La condición del alta y del clonado miraba sólo si la app tenía proceso, así que una app PHP recién creada —justo la que más lo necesita, porque su código lo ejecuta php-fpm y no ella— seguía compartiendo pool con todas las demás hasta que alguien se acordara de `orbit isolate`. Ahora nacen con su usuario y su pool
- **`orbit isolate` daba por buena una app rota.** Si php-fpm no cargaba el pool, el fallo se descartaba y el vhost pasaba igual al socket nuevo: `nginx -t` no comprueba que un socket exista, así que nginx recargaba tan contento y el sitio contestaba 502 con el comando anunciando que la app había quedado aislada. Ahora el pool se escribe y se **verifica** —que el socket aparezca, que es la única señal que no miente— **antes de tocar un solo fichero**, y si no carga no se cambia nada: ni dueños, ni configuración, ni vhost

## [1.0.3] - 2026-08-10

### Añadido — aislamiento por app: un usuario de sistema por aplicación

El límite que la sección «Qué NO protege» llevaba admitiendo desde el principio: todas las apps corrían como `deploy`, y una comprometida podía leer el `.env` de todas las demás. Ya no.

- **Las apps con proceso nuevas nacen con su propio usuario** (`orbit-<app>`), y las anteriores se migran con **`orbit isolate <app>`**. `APP_ISOLATION="no"` en `orbit.conf` lo apaga para las que se creen después
- **Dos papeles donde había uno.** El *fetcher* (`as_deploy`: git, gh, la caché) sigue siendo `deploy`, que es quien tiene las credenciales — el usuario de una app no tiene por qué poder leer las llaves con las que se clonan los repos. El *builder* (`as_app`: compilar, la release, `shared/`, artisan) corre como el usuario de la app. Sin `A_USER`, el builder resuelve a `deploy` y todo se comporta exactamente como antes
- **El nombre del usuario es determinista** y siempre vale para `useradd` (≤32, sin puntos, sufijo con hash si hubo que sanear): un `orbit restore` en un servidor nuevo recrea el mismo usuario que dice la copia
- **`orbit remove` se lleva el usuario propio** — con guarda: un `A_USER='deploy'` escrito a mano no puede acabar en un `userdel` del usuario que despliega el servidor
- **Sólo apps con proceso, y se dice por qué**: una estática no ejecuta nada, y una app PHP con usuario propio sería teatro — sus páginas las ejecuta el pool compartido de php-fpm. El aislamiento PHP exige un pool por app y queda en el roadmap
- Suite propia (`tests/isolate_test.sh`) con `useradd`/`userdel` doblados y la mutación ejecutada: devolverle a la unidad el `User=deploy` pone la prueba en rojo. Ver ARCHITECTURE §5.3
- **La revisión adversarial encontró tres agujeros de dueño, y los tres eran reales.** El patrón común: resolver el usuario desde los globales cuando la app llegaba por nombre. `orbit db create <app>` suelto dejaba el `.env` de una app aislada con un dueño que su builder no puede leer; el clone, con los globales ya del clon, **le robaba el `.env` al original** y le enseñaba sus secretos; y `remove` sin `--purge` borraba al único dueño de los ficheros que decía conservar. Ahora el dueño sale de la app nombrada (`app_user_of`), el usuario solo se va con los datos, y las pruebas se escribieron antes del arreglo: las siete estaban en rojo contra el código anterior

## [1.0.2] - 2026-08-10

### Añadido — reinicio sin corte

El hueco de uno o dos segundos al desplegar una app con proceso —lo que tapaba la página de mantenimiento— ya no existe. La frase del roadmap, hecha código: levantar el proceso nuevo, esperar a que responda y solo entonces retirar el viejo.

- **La release nueva arranca como unidad puente** (`orbit-<app>-next`) en un puerto libre, con el proceso viejo aún sirviendo. Solo cuando pasa el health check, nginx —cuya recarga no corta conexiones— le pasa el tráfico; la unidad canónica se reinicia ya con una release verificada, y el puente se retira
- **Una release rota ya no toca producción.** Antes: parar el proceso, descubrir que el nuevo no responde, restaurar y rearrancar. Ahora el fallo ocurre en el puente, antes de mover nada: el proceso viejo ni se entera. Es el principio 4 aplicado al reinicio
- **El estado en reposo no cambia**: una unidad, un puerto, un vhost. Ni `watch`, ni `logs`, ni `port` tienen que saber que el puente existe; si el servidor se reinicia a mitad de despliegue, lo que vuelve es la unidad canónica
- **`DEPLOY_OVERLAP="no"`** en `orbit.conf` devuelve el camino clásico (con su página de mantenimiento), necesario si una app lee el puerto de su propio `.env` en vez del `PORT` que le pasa la unidad. El primer despliegue y una app parada usan el camino clásico por definición
- La secuencia está fijada con dobles que saben fallar: adelantar el `restart` de la canónica —el código de antes— pone dos comprobaciones en rojo. La unidad puente lleva su propia sección en `systemd_test.sh`. Lo que ningún doble ve —systemd y nginx de verdad bajo tráfico— sigue siendo la primera deuda del ROADMAP. Ver ARCHITECTURE §5.2
- **La revisión adversarial del PR encontró cuatro agujeros, y verde no es hecho, otra vez.** El más caro: el override del vhost pisaba la `A_PORT` global, así que el health check de la canónica medía el puerto del puente —que ya sabíamos que respondía— y podía dar por bueno un despliegue con la canónica muerta y nginx a punto de apuntarle. Además: el symlink se movía antes de verificar el puente (hasta 40 s de 404 en los estáticos con hash), un puente huérfano se retiraba sin comprobar que la canónica de verdad contestara («activa» para systemd no es «sana»), y la vuelta al puerto canónico se daba por hecha aunque la recarga de nginx fallara. Los cuatro arreglados con prueba que los fija — la suite ahora apunta también *a qué puerto* se le pregunta la salud, y la mutación de quitar la recarga de la app la pone en rojo

## [1.0.1] - 2026-08-10

### Añadido — la versión sube con cada PR, y se lee de un solo sitio

- **Política de versionado**: cada PR sube el parche en uno (`1.0.1` → `1.0.2`) y el parche nunca pasa de 9 — tras `X.Y.9` viene `X.(Y+1).0`. Escrita en CONTRIBUTING §Versionado y en docs/DEVELOPMENT.md, que es lo primero que se lee al entrar al proyecto
- **La versión vive en una sola línea de `orbit`.** Antes había dos declaraciones (`install.sh` y seis valores de repuesto repartidos por `orbit`) y un conf que la congelaba: `orbit.conf` guardaba la versión del día de la instalación y, como sólo se escribe la primera vez, tras actualizar `orbit --version` seguía anunciando la vieja. Ahora el script manda —fija su versión después de cargar el conf—, `install.sh` la extrae de esa línea igual que hace con el núcleo de idiomas, y al reinstalar retira la clave heredada del conf para que un `cat` no cuente otra historia

### Arreglado — la suite de nginx acusaba a código sano si php-fpm no era el 8.3

El tercer estado otra vez, el que ya costó los 16 fallos fantasma de `jq`: `tests/nginx_test.sh` buscaba `php-fpm8.3` por su nombre y, con otra versión instalada (pasó con 8.4), no se saltaba — se ponía **en rojo**, con 28 fallos. La copia del snippet `fastcgi-php.conf` vivía dentro del bloque de php-fpm, pero los vhosts PHP lo incluyen siempre, así que `nginx -t` moría y arrastraba todo lo que venía detrás.

- La suite acepta cualquier `php-fpm*` ejecutable: para lo que se prueba —que nginx pasa los `.php` a un pool— la versión da igual
- El snippet se copia siempre que exista, y si el paquete de nginx no lo trae, se escribe un equivalente mínimo: la validación ya no depende de qué variante de nginx esté instalada
- Con php-fpm 8.4 la suite pasa entera ejecutando PHP de verdad: 93 comprobaciones, antes 34

### Añadido — `orbit.json` puede declarar sus variables, y Orbit las consigue

Casi todo despliegue tiene un apartado que dice «entra por SSH, copia el fichero de ejemplo, genera un token, pégalo». Tres pasos a mano, y el primero no necesitaba a nadie.

- **`orbit.json` admite `env`.** El repositorio declara qué variables hacen falta y de dónde salen; el despliegue las consigue. `"generate": "hex:24"` (también `base64:N` y `uuid`) las produce sin preguntar nada; `"prompt": "…"` pregunta una vez, y con `"secret": true` sin eco por pantalla
- **Nunca se pisa un valor que ya exista.** Un redespliegue no puede cambiarle la contraseña a nadie, y lo que hayas puesto con `orbit env set` manda sobre cualquier generación posterior
- **Sin nadie al teclado no se bloquea.** Con `--yes`, en autodeploy o en CI, lo que había que preguntar se anota y se avisa con el comando exacto para ponerlo después, en vez de dejar el despliegue esperando a un teclado que no existe
- **El bloque se relee en cada despliegue** y `orbit env` opera sobre el mismo fichero que la provisión, no sobre `shared/.env` por su cuenta
- **No se escribe a través de enlaces simbólicos.** `shared/` es del usuario de despliegue, así que una app comprometida podría apuntar su `.env` a un fichero del sistema; como la provisión corre como root, seguirlo lo reescribiría y le cambiaría el dueño. Se comprueba el fichero y cada directorio del camino
- **`file` apunta el `.env` donde la app espera leerlo** (por defecto, `shared/.env`). Importa para PHP: nginx no pasa las variables de `shared/.env` por FastCGI, y hacer que las pasara metería la contraseña dentro de la configuración de nginx, que es más legible que un `.env` con permisos `0640`. Declarando el fichero también en `shared`, se enlaza en la release y la app lo lee ella misma

### Añadido — `orbit metrics`, métricas de despliegue sin una pieza nueva

La pregunta que contesta es **«¿esto va a peor?»**, y todo lo demás sale de ahí.

- **Una línea TSV por despliegue** en `/var/lib/orbit/deploys.tsv`, escrita por el propio `orbit deploy`. Sin recolector, sin base de datos y sin proceso nuevo: el principio 2 no se toca porque no hay nada corriendo, y el 5 tampoco porque el histórico se lee con `cat`, se filtra con `grep` y se suma con `awk`. El JSON se genera al leer, que es donde hace falta
- **También apunta los que fallan**, con el paso donde se rompió y el motivo — que es la mitad de lo que pide la métrica, y son justo los despliegues que no llegan al final del código. Se escribe desde el manejador de salida, el único sitio por el que pasan los dos finales
- **El build se cronometra aparte del despliegue.** Clonar, mover un symlink y recargar nginx son más o menos constantes; lo que crece con el proyecto es compilar
- **La mediana, no la media**: un build que normalmente tarda 30 s y una vez tardó 400 porque el servidor estaba ocupado tiene una media que no describe ningún despliegue real
- **Y la tendencia se calla cuando no hay datos para tenerla.** Con menos de seis builds correctos no se calcula nada y se dice por qué, en vez de enseñar un número que alguien usaría para decidir. En el contrato eso es `null` y no `0`: el cero es un valor y significa «igual»
- `orbit metrics --json` para un cliente, y `orbit metrics <app>` añade los últimos diez despliegues uno por línea
- El histórico se poda a `METRICS_KEEP` (2.000 por defecto) y no entra en las copias de seguridad: es observabilidad derivada, no configuración, y las medianas de otra máquina no describen ésta

### Añadido — `orbit deploy --all --json`, el contrato por lotes

Era la última pieza que le faltaba al contrato del que cuelga cualquier interfaz. Estuvo rechazado a propósito mientras no existía: aceptar la opción y devolver prosa le promete a un cliente un objeto que no va a llegar.

- **Seis finales por app, no dos**: `deployed`, `failed`, `unchanged`, `unreachable`, `gone` y `skipped`. Los recuentos van desglosados por los seis y no agrupados en «correctas / fallidas» — confundir «al día» con «no he podido preguntar» es exactamente el fallo que ya obligó a arreglar el resumen en prosa, y un contrato no puede repetirlo
- **Dentro de cada app va el objeto de `orbit deploy <app> --json` sin recortar.** Una forma, dos comandos. Por eso `result` es un objeto anidado y no unos campos aplanados: aplanarlos perdería `rolled_back`, `recovered` y `previous`, que son justo lo que un panel necesita para enseñar distinto lo que es distinto. En las apps que no se desplegaron `result` es `null` y el motivo va en `error`
- **`ok` es la misma regla que el código de salida** —ni fallos ni apps sin contacto—, para que un cliente que mire el objeto y otro que mire el código de salida no puedan discrepar
- **Una pasada sin apps devuelve la colección vacía**, no un silencio: con stdout en blanco no se distingue «no había nada» de «algo se rompió»
- **`--progress` también en el lote**, con un suceso por app; y el suceso de paso lleva ahora el nombre de la app, porque en un lote los dos niveles comparten canal y un paso sin dueño no se puede atribuir. Es un campo **añadido**, que es lo que el contrato permite

### Corregido — tres cosas que salieron de escribirlo, y ninguna era del contrato

- **`deploy --all` corría cada despliegue sin `errexit`.** Estaba escrito `if ( cmd_deploy "$n" ); then`, y dentro de un `if` bash apaga errexit **y se hereda**: media orden que fallara seguía adelante y podía anunciar un éxito que no había ocurrido. Es la trampa que documenta docs/DEVELOPMENT.md, y estaba en el camino por el que pasa el autodespliegue, que corre sin nadie delante. El primer intento de arreglo **se quedó a medias** —quitar el `if` y poner `set +e … rc=$? … set -e` no basta, porque el hijo hereda el errexit apagado del padre— y se comportaba exactamente igual que lo que sustituía. Ahora lleva las dos mitades, con una prueba que lo fija
- **El resumen en prosa de `--all` escribía por stdout.** Nunca había convivido con un contrato, así que la regla «con `--json`, por stdout sólo el objeto» se cumplía sola. Ahora sale por `$UI_FD`, como todo lo que lee una persona
- **El motivo de un remoto que no contesta era la última línea de git.** git termina su queja con un párrafo de ayuda de cuatro líneas, así que salía «and the repository exists.» — un trozo de frase suelto. Daba igual mientras sólo lo leyera una persona junto al resto del mensaje; dentro del contrato es lo único que un panel enseñaría. Ahora se coge el primer `fatal:`
- **Y los despliegues que fallaban no decían por qué**: cinco `die` de `cmd_deploy` —fetch, clone, build, reintento del build, y una app de tipo redirección— dejaban `error: null` en el objeto. En un lote eso son varias apps fallidas sin un motivo entre todas

### Corregido — la ayuda de `deploy` y la de `remove` salían en una sola línea

- Con los `\n` a la vista, y desde siempre, en el comando que más se usa. `t` imprime con `%s`, que no interpreta escapes. Se arregla en los dos sitios que imprimen, con `%b`, y no en `t`: la usan setecientos mensajes y ahí un backslash literal cambiaría de significado. De paso, el `%s` de `--purge` se había quedado sin sustituir

### Añadido — el `orbit.json` de la app, y no sólo el del repositorio

- **Una app que vive en `backend/` ya puede declarar su despliegue**, con las rutas relativas a su propia carpeta, que es donde está el fichero y donde piensa quien lo escribe. Antes el descriptor se leía sólo de la raíz: en un monorepo quedaba fuera justo el que más lo necesita, y si además el stack no lo reconocía ningún heurístico, no había forma de desplegarlo
- **Sale de la misma pieza que lo anterior.** El descriptor se lee **dentro** de `detect_stack`, sobre la carpeta que de verdad se está detectando, en vez de leerlo quien la llama; y como detectar un monorepo es esa función llamándose a sí misma sobre la subcarpeta, el `orbit.json` de `backend/` lo recoloca la misma traducción de coordenadas que todo lo demás. Leerlo desde fuera obligaría a recolocar dos veces y a acertar las dos
- **Una declaración manda sobre cualquier inferencia**, así que una subcarpeta con `orbit.json` es la única búsqueda de subcarpeta que va delante de las ramas de la raíz — pero sólo si es un descriptor que se vaya a **aplicar**: uno roto o sin `type` se llevaba la detección hacia esa carpeta y ya no se podía volver a la raíz, dejando sin servir un sitio perfectamente detectable. Y las rutas de `shared` que declare esa app también se recolocan, o el despliegue enlaza una carpeta por la que no pasa nadie y los datos se pierden en silencio. Es el reverso exacto de la regresión del ciclo anterior: aquello eran indicios —un `pyproject.toml` puede ser de una carpeta de utilidades—, y un `orbit.json` no aparece por accidente. Si la raíz trae el suyo, gana la raíz sin mirar dentro

### Corregido — dos cosas que sólo se vieron ejecutándolo

- **La rama de repuesto avisaba de que iba a publicar el código fuente… y tres líneas después el descriptor la desmentía.** Un `backend/` con su `orbit.json` y nada que ningún heurístico reconozca pasaba por el «no reconozco este repositorio». Asustar y contradecirse en el mismo párrafo
- **El aviso de dónde está la app salía sin la carpeta**: «La app está en : …». `_declared_stack_dir` vaciaba el global del que sale ese nombre antes de comprobar si la búsqueda estaba apagada, y la llamada recursiva pasa por ahí otra vez, así que le borraba el nombre a quien lo había puesto. La prueba no lo cogía porque buscaba la frase y no el nombre — y la prueba que se escribió para fijarlo tampoco podía fallar, porque usaba el `run` de la suite, que lanza un subshell del que el global no sale. Las dos cosas arregladas

### Añadido — ningún stack tiene que estar ya en la raíz del repositorio

Continuación directa de lo de Laravel, y la auditoría de aquello es lo que lo destapó: **no era de Laravel**. Un Go en `backend/`, un Django en `backend/` y un Hugo en `site/` daban los tres `A_TYPE=static` con `A_OUTDIR="."`, o sea nginx sirviendo el repositorio entero.

- **`detect_stack` se llama a sí misma sobre la subcarpeta, y una sola función traduce las coordenadas después.** La alternativa era que cada rama compusiera sus rutas: son dieciséis y crecen, y la que se olvidara fallaría **hacia servir la carpeta equivocada**, que es justo el modo de fallo que hay que evitar. Con esto, añadir un stack nuevo no toca nada de la parte de monorepos, y Deno, Bun y los npm anidados salieron gratis
- **Go, Django y Hugo, verificados uno a uno.** Go compila y arranca dentro de su carpeta; Django crea el venv, hace `collectstatic` y migra dentro de la suya, y `STATIC_ROOT` sale ya relativo a la raíz de la release —que era la señal de que la convención de rutas estaba bien elegida—; Hugo no necesitó ni una línea propia, sólo que `A_OUTDIR` pasara de `public` a `site/public`
- **Con varias apps desplegables se elige una y se dicen todas.** Un vhost sirve una app. Entre stacks manda el orden de la rama principal; dentro de un stack, los nombres de siempre (`backend`, `api`, `server`…), como con los binarios de Go
- **`--appdir` dirige la detección en vez de ser un campo que se pisa al final.** Es lo que hace que la segunda app de un monorepo se pueda desplegar de verdad (`orbit new otra --appdir frontend`); antes dejaba `A_BUILD` y `A_START` apuntando a la raíz, o sea una app que no compilaba —o peor, que compilaba lo que no era—. Y la carpeta tiene que existir: con una errata, el build moría con «cd: no such file or directory» sin decir de dónde salía esa ruta

### Corregido — de la revisión adversarial de este mismo cambio

- **La búsqueda de subcarpetas estaba colocada demasiado pronto en la cadena.** Iba delante de la rama de `package.json` razonando que un workspace no es una app desplegable — cierto para los workspaces, y falso para todo lo demás, porque de paso se adelantaba a `composer.json`, a `requirements.txt` y a `index.html`. Medido: un sitio estático con un `tools/pyproject.toml` al lado pasaba a ser una app de Python, y una app PHP con su documentación en `site/` pasaba a ser un Hugo; en los dos casos la web de verdad dejaba de servirse. Ahora sólo se mira dentro cuando la raíz no reconoce nada. Lo encontró probarlo, no leerlo
- **Y de ahí salió que la guardia «si la raíz declara un framework, manda la raíz» era código inalcanzable**, porque esa raíz se lleva su propia rama mucho antes. Se ha quitado: la regla sigue viva y ahora es estructural. Código muerto que aparenta una protección es peor que no tener nada
- **El paso que aborta un despliegue de Go sin ejecutable miraba en la raíz de la release**, así que con la app en `backend/` no comprobaba nada. Igual que `_django_probe`, que lanza el `python` del venv y necesita `manage.py` al lado

### Añadido — Laravel ya no tiene que estar en la raíz del repositorio

- **Un monorepo con la API en `backend/` y el frontend al lado se detecta y se despliega.** Antes no casaba con ninguna rama de `detect_stack` —ni `package.json` en la raíz, ni `composer.json`, ni `.php` sueltos, ni `index.html`— y caía en la de repuesto, que es de donde salían los siete agujeros de §18.8. Éste es el octavo y de los peores, porque son dos cosas a la vez: `A_OUTDIR="."` pone el `root` de nginx en la raíz del repositorio **y** `_has_php` encuentra los `.php` de Laravel dentro y activa `A_PHP=yes`, así que php-fpm además ejecuta cualquier `.php` alcanzable por URL, fuera de su docroot y sin el front controller. Medido con nginx y php-fpm de verdad, con el docroot en la raíz: `GET /backend/composer.json` → 200 con el contenido, `GET /frontend/src/app.js` → 200 con el código
- **No se reutiliza `_find_app_package`**, que resuelve los monorepos de npm: lee `dependencies` de un `package.json` y aquí no hay ninguno que leer. La búsqueda va aparte, con las mismas dos convenciones —dos niveles, `backend/` y `apps/api/`— y podando `vendor/` y `node_modules/`, donde un Laravel es una dependencia y no la app
- **Si la raíz declara un framework de JavaScript, manda la raíz.** Un monorepo de JS que trae un Laravel de ejemplo en `playgrounds/laravel/` existe, y sin esta regla se desplegaría el ejemplo en vez de la app. Con el Laravel *en* la raíz no hace falta la cautela: ahí `artisan` y `bootstrap/app.php` **son** el repositorio. Salió de buscarle agujeros al cambio, no de una prueba en rojo
- **Con varios Laravel se elige por nombre y se dice cuál**, igual que con los binarios de Go. Y si al lado hay un frontend con su propio `package.json`, se avisa de que no se compila ni se sirve: quien manda es Laravel y su vhost sirve su `public/`
- Las rutas se componen con dos funciones que no se pueden confundir —`_app_root` hacia dentro, `_app_sub` hacia fuera— siguiendo la convención que ya usaba `A_OUTDIR` en los monorepos de npm: lo que se guarda en la configuración es relativo a la raíz de la release, con la subcarpeta ya dentro. Por eso el vhost no tiene que saber nada de `A_APPDIR`

### Corregido — el `.env` que Laravel no encontraba

- **El `.env` se enlazaba sólo en la raíz de la release, y Laravel lo busca junto a su `composer.json`.** El despliegue de un monorepo moría en el paso de la `APP_KEY`: `key:generate` no encontraba `.env`, salía con 1, y se abortaba con un mensaje que hablaba de la clave y no de dónde estaba buscándola. Ahora se enlaza también dentro de la app. No se acota a Laravel: cualquier framework que lea su `.env` junto a su manifiesto —Next y Vite lo hacen— estaba en el mismo caso, con el enlace de la raíz sirviéndole de nada. Lo destapó la prueba de despliegue, no la de detección: la de detección salía verde
- **Los consejos que imprime Orbit llevan el `cd` puesto.** `orbit exec <app> 'php artisan key:generate --force'` deja en la raíz de la release, así que en un monorepo el comando que Orbit te dice que escribas fallaba con «Could not open input file: artisan» — y justo en el momento en que estás atascado

### Seguridad — las rutas que declara el repositorio en su `orbit.json`

- **`appdir`, `outdir` y `docroot` se validan.** Con este cambio `appdir` decide sobre qué carpeta actúa el `rm -rf` que sustituye `storage/` por el enlace al compartido, así que se validan como todo lo que llega a un vhost (§18.7): nada absoluto, nada con `..`, y sin guion inicial —una carpeta llamada `-rf` convierte el `cd` del build en un puñado de opciones—. Una ruta que no vale se ignora y se dice, que es lo que deja al descubierto la errata
- Con la honestidad por delante: **esto no es una frontera de seguridad**. El mismo `orbit.json` declara `build`, que es una orden de shell y corre como el usuario de despliegue, igual que los scripts de un `package.json`; un repositorio hostil ya ejecuta código por diseño. Lo que evita son dos averías corrientes: un `..` que saca las rutas del despliegue fuera de la carpeta de la app, y un `;` en `docroot` que escribe un vhost ilegible — y como el fichero se enlaza en `sites-enabled` **antes** del `nginx -t`, eso tumba la configuración del servidor entero: ninguna otra app se despliega y ningún certificado se renueva

### Corregido — `make test` sin `jq` acusaba a quien no era

Salió de auditar la propia suite, no de un bug del producto. La promesa era que una suite sin su herramienta **se salta y lo dice**; había un tercer estado sin documentar.

- **Sin `jq`, tres bloques no se saltaban: se ponían en rojo.** 16 fallos repartidos entre la detección de Angular, el selector de scripts del `package.json` y el recuperador de lockfiles — todos apuntando a código que estaba perfectamente bien. Las tres funciones tienen su camino de respaldo declarado sin `jq` (`_detect_angular` deduce el nombre del proyecto del directorio; `_pkg_scripts` no devuelve nada; `_dep_section` devuelve vacío y con eso `_recover_lockfile` se **niega** a descongelar, que es la dirección segura), así que lo que fallaba eran las afirmaciones de las pruebas, no el producto. Ni probado ni saltado: mandándote a depurar lo que no era
- Ahora los tres anuncian el salto como el resto de la suite, de modo que `make test` sin herramientas sale **en verde con 1.164 comprobaciones** en vez de en rojo con 16 fallos falsos, y `make test-strict` —el que se niega a mentir— los cuenta entre lo que no se ha ejecutado. Con todo instalado son 1.763

### Añadido — el PHP que el build no copia, y el dato que el despliegue borraba

Las dos salieron del mismo sitio: un proyecto real —un Astro con cuatro endpoints PHP— que en Orbit se veía perfecto y tenía **los cuatro formularios en 404**.

- **Una carpeta con `.php` fuera de la carpeta compilada ahora se sirve desde donde está.** `astro build` —y vite, y eleventy— sólo copian a `dist/` lo que esté en `public/`, así que un `api/` en la raíz del repositorio se quedaba fuera del docroot: 12 ficheros PHP en el repo, **0** en lo que servía nginx. La documentación de despliegue de ese proyecto lo llama «el error nº 1» y lo resolvía subiendo la carpeta aparte con un segundo `rsync`. Ahora `/api/contact.php` responde sin tocar el proyecto, y sin `alias`: se usa `root` con la raíz de la release, que es lo que hace que `SCRIPT_FILENAME` salga bien sin tocar nada de fastcgi
- **`orbit.json` admite `shared`: lo que la app escribe y no puede vivir en una release.** Cada despliegue rehace la release entera, así que las credenciales puestas a mano, los mensajes sin entregar, las estadísticas y los logs desaparecían en el despliegue siguiente — y la web seguía funcionando, así que no se notaba hasta buscar un dato y no encontrarlo. Se declaran una vez y a partir de ahí es automático: se crean en `shared/` la primera vez —con lo que traiga el repositorio, que sirve de semilla y no se vuelve a pisar— y se enlazan en cada release, así que el código las sigue viendo donde siempre
- **Y de ahí sale gratis la parte de seguridad.** Lo que dentro de una carpeta publicada apunta a `shared/` es, por el modelo de §4, dato en tiempo de ejecución: se niega, sin heurística ni lista de nombres. Medido en ese proyecto antes del cambio: `/api/undelivered/2026-01-01.eml` devolvía **200 con el currículum de un candidato**, y `/api/telemetry-data/stats.json` también. Su documentación traía cuatro reglas de nginx escritas a mano para taparlo; ahora salen solas de dónde está cada cosa
- **`.eml` entra en la lista de extensiones que no se sirven** dentro de esas carpetas, junto a `.env` y `.sql`

### Corregido — el despliegue no llegaba a existir para una app PHP

- **php-fpm seguía sirviendo la release anterior después de moverse el symlink.** Guarda en su caché de `realpath` a qué release apunta `current`, con un TTL de 120 s por defecto, así que durante hasta dos minutos los visitantes recibían el código de antes — y **mezclado**, porque nginx sí resuelve el symlink en cada petición: la web salía con los estáticos nuevos y el HTML viejo. Medido activando a propósito una release cuyo `index.php` revienta: `200 con la portada vieja` recién activada, `500` —la release de verdad— tras recargar php-fpm. Ahora se recarga con `reload` (SIGUSR2, sin cortar ninguna petición) al activar y también al volver atrás, porque si no el rollback deja el symlink bien y la web en 500. Vale para `laravel`, `php` y cualquier estática con PHP dentro
- **El health check vale para los tres tipos que sirve php-fpm**: `laravel`, `php` a secas y una estática con `.php` dentro. En los dos primeros la portada la ejecuta php-fpm, así que un error de sintaxis o una extensión que falta salen como 5xx y se cogen —comprobado rompiendo el punto de entrada de una app PHP real: 500, rollback, y la portada de vuelta—. En una estática la portada la sirve nginx desde disco, así que ahí esto comprueba que el sitio sigue en pie y no que el formulario de contacto funcione; se dice con todas las letras en vez de aparentar más. Una estática **sin** PHP no pasa por nada de esto: no hay caché de por medio ni proceso que comprobar
- **Y una app Laravel ya tiene health check.** No lleva unidad, así que no pasaba por el del paso 6 ni por su rollback: una release que compilaba bien y reventaba **al servir** se publicaba y se quedaba, con el resumen diciendo que todo había ido bien. Ahora se le pide la portada a nginx como haría un visitante —por el puerto 80 y con la cabecera que evita el redirect, así que no hace falta TLS ni saber si hay certificado— y un 5xx devuelve el symlink a la release anterior. Se acepta cualquier cosa que no sea 5xx: un 404 en la portada puede ser correcto y no es asunto de Orbit. Se salta en mantenimiento, incluido el `php artisan down`, porque ahí el 503 es la respuesta correcta
- **`curl` escribe `000` cuando ni siquiera conecta, y además sale con 7.** Un `|| printf '000'` detrás daba `000000`, que no casaba con ningún patrón de fallo: un servidor que no contestaba se daba por sano. Lo encontró un despliegue de prueba con nginx en otro puerto, no las pruebas unitarias — ellas siempre tenían un servidor vivo al otro lado

### Seguridad — de dos revisiones adversariales de Laravel

- **El `.env` de una app se ejecutaba como root en cada despliegue.** `_env_read` hacía `source` del fichero, así que una línea `APP_DEBUG=$(id -un > /tmp/x)` se ejecutaba con todos los privilegios en el siguiente `orbit deploy`. Y el `.env` lo escribe el usuario de despliegue, que es también el de php-fpm: cualquier ejecución de código en cualquier app PHP del servidor podía dejar ahí una línea y esperar — con autodespliegue, ese despliegue lo lanza un temporizador sin nadie delante. Reproducido: `¿se ejecutó lo del .env? SÍ, y corrió como: root`. Ahora se lee con `sed`, sin interpretar nada
- **El bloque que protege las carpetas de subidas apagaba el snippet de seguridad justo ahí.** Un prefijo `^~` hace que nginx deje de mirar **todas** las expresiones regulares, no sólo la de `.php` — y `orbit-security.conf` deniega `.env`, `.sql`, `.sqlite`, `.log`, `.yaml`… con una `location` de expresión regular. Un fichero subido con uno de esos nombres se servía entero: `/storage/robado.env` → **200 con `APP_KEY=base64:SECRETO`**, mientras la misma extensión fuera del prefijo daba 403. La regla estaba del revés: se aplicaba donde el contenido lo pone el repositorio y se apagaba donde lo elige un desconocido. Seis comprobaciones nuevas, todas en rojo sin el arreglo
- **Un nombre de fichero del repositorio podía dejar a nginx sin poder recargar en todo el servidor.** Los nombres de los enlaces descubiertos se interpolaban sin validar dentro del vhost: un enlace llamado `mal;dentro` escribe una directiva que nginx no puede leer, y como el vhost se enlaza en `sites-enabled` **antes** del `nginx -t`, a partir de ahí no se despliega ninguna otra app ni se renueva ningún certificado

### Corregido — de las mismas revisiones

- **Un paréntesis en una contraseña rompía todo lo que iba detrás del `.env`.** El `source` de `_env_read` aborta ahí, y todas las claves siguientes se leían vacías — mientras que phpdotenv las lee sin problema. En Laravel eso significaba `APP_KEY` vacía y por tanto **regenerada en cada despliegue**, invalidando sesiones, cookies firmadas y todo lo cifrado en la base de datos, mientras Orbit imprimía «se queda en shared/.env, no se toca más». Y los cuatro avisos del despliegue callaban a la vez
- **`detect_stack` devolvía 1 y `orbit new` se moría en silencio justo después de clonar.** Su última orden era un `[[ -f composer.json ]] && …`, así que cualquier estática con un `.php` y sin `composer.json` —el caso de §18.7, un Astro con su formulario— salía con 1, y `cmd_new` la llama bajo `errexit` sin `|| true`. Ni error, ni `die`, ni nada: la app quedaba a medias en disco. Es la trampa que documenta docs/DEVELOPMENT.md, en el camino de entrada del producto
- **Los prefijos de subidas se comían rutas vivas de la aplicación.** `uploads`, `upload`, `files` y `media` se emitían existieran o no como carpeta, y sin `try_files`: en una app cuyo tráfico entero pasa por un front controller, `/media/{id}` o `/files/{uuid}/download` respondían **404 de nginx** sin llegar nunca a la app. Ahora sólo se emiten si la carpeta existe, y el bloque devuelve el control a `index.php`
- **El paso que comparte `storage/` no miraba el tipo de app.** Cualquier repositorio con un `storage/` en la raíz veía esa carpeta enlazada a `shared/` y sembrada con `--ignore-existing`, así que **un fichero del repositorio bajo `storage/` se copiaba una vez y no se actualizaba nunca más**: la release dejaba de ser lo que dice git, sin aviso. Ahora es sólo de Laravel y siembra el esqueleto, no el contenido
- **Los pasos de Laravel que dejan la web rota ahora abortan el despliegue.** Sin unidad no hay health check ni rollback automático, así que un `warn` perdido entre veinte líneas y un «✔ desplegada» al final sustituían una web que funcionaba por una que devuelve 500 en todo. `config:cache` es además el mejor comprobante previo que tiene esta clase de app, y falla antes de mover el symlink
- **Un `.env` sin salto de línea final corrompía su última clave.** `DB_PASSWORD=hunter2` pasaba a valer `hunter2APP_KEY=`, y como ya no quedaba una línea `APP_KEY=` que sustituir, `key:generate` salía con 0 sin escribir nada y Orbit anunciaba en verde una clave que no existía. Ahora se comprueba el resultado, no el código de salida
- **`storage:link --force` no hace nada si `public/storage` es una carpeta de verdad**: artisan dice «link already exists» y sale con 0, dejando todas las subidas en 404 para siempre
- **Laravel 8 y 9 se quedaban sin compilar los assets**, en silencio: Laravel Mix no tiene script `build`, sus nombres son `dev`/`watch`/`prod`/`production`. Y si no hay ninguno reconocible, ahora se dice
- **`--type laravel` no existía como bandera** —la lista de validación se quedó atrás respecto a la ayuda, y también le faltaban `bun` y `deno`— y no fijaba `A_DOCROOT=public`, así que corregir a mano un tipo mal detectado dejaba a nginx sirviendo la raíz del repositorio **y ejecutando** cualquier `.php` de dentro
- **El aviso de migraciones callaba cuando no podía comprobarlo.** Si artisan no arranca o la base de datos no contesta, la salida no casa con nada: el silencio significaba «todo aplicado» *y* «no llego a la base de datos», que son los dos estados que hay que distinguir al terminar de desplegar
- **`php artisan down` sobrevivía al despliegue sin que nadie lo dijera.** Su bandera vive en `storage/framework/`, que ahora es compartido: el despliegue anunciaba «desplegada» y el JSON decía `ok:true` sobre una web que devuelve 503 a todo el mundo
- **Las copias de una app Laravel se llenaban de sesiones, vistas compiladas y logs**: 411 de los 415 ficheros de una copia recién hecha. Se excluyen por el mismo criterio que ya se aplica a `shared/home`
- **La rama sin `jq` de `_composer_requires` no decía lo mismo que la de `jq`**: sacaba paquetes de `conflict`, `replace`, `suggest` y `config.allow-plugins`, y se quedaba vacía con un `composer.json` que llevara un espacio antes de los dos puntos. Equivocarse en una máquina y no en otra es peor que equivocarse
- **`orbit list` decía «estatico» de una app PHP o Laravel**, que es justo la palabra del fallo que la detección existe para evitar
- **`migrate --pretend` promete menos de lo que parece**: suprime el SQL, pero el resto del código de la migración se ejecuta igual. Ahora se dice donde se enseña el plan
- **El `artisan` de mentira de las pruebas no hacía nada**, así que se podían borrar `key:generate`, `storage:link` y `config:cache` uno a uno y `make test` seguía en verde. Ahora apunta lo que le piden y escribe de verdad: los cuatro mutantes se detectan

### Añadido — Laravel

- **Laravel como tipo propio**, no como «una app PHP con más cosas». Se detecta por tres señales a la vez —`artisan`, `laravel/framework` entre los `require` y `bootstrap/app.php`—, porque cada una por separado se equivoca en un proyecto real: Lumen también trae `artisan`, y cualquier paquete que se pruebe contra Laravel declara `laravel/framework` en `require-dev`. Comprobado contra ocho proyectos, con `jq` y sin `jq`
- **Y va delante de la rama de `package.json`**, que es lo que estaba roto: el esqueleto de Laravel trae `vite` en `devDependencies` y un script `build`, así que un `composer create-project laravel/laravel` salía **`A_TYPE=static` con `A_OUTDIR=dist`** — una carpeta que Laravel no genera jamás. En un servidor eso es la web entera en 404. Medido sobre un proyecto real
- **El despliegue hace lo que hay que hacer, en el orden en que hay que hacerlo**: siembra `shared/storage`, genera la `APP_KEY` si falta (una sola vez), rehace `storage:link` y cachea configuración y rutas. Y `view:cache` **no**, a propósito: escribe en `storage/`, que es compartido, y hace un `view:clear` primero, así que la release nueva borraba las vistas compiladas de la anterior — medido, 21 ficheros antes y 0 después
- **`orbit migrate` enseña el SQL exacto** con `migrate --pretend --force`, sentencia a sentencia, antes de preguntar. Y al terminar un despliegue avisa si quedan pendientes: `migrate:status` devuelve **0 haya pendientes o no**, así que se mira el texto y no el código de salida — y fuera de una tubería con `grep -q`, que es la trampa de los 141 que documenta docs/DEVELOPMENT.md
- **Cuatro avisos de cosas que dejan el build en verde y la web rota o insegura**: `APP_DEBUG=true`, `DB_CONNECTION=sqlite` sin el driver instalado, una cola configurada sin nadie que la ejecute —los trabajos se apilan sin un solo error mientras la web responde 200— y el PHP del build contra el del pool
- **`orbit doctor` reconoce el `php artisan down`.** Su bandera vive en `storage/framework/maintenance.php`, que ahora es compartido: sobrevive a los despliegues y la hereda cualquier release futura, incluido el despliegue que iba a arreglar el problema. Y `orbit maintenance status` diría que está apagado, porque mira otro fichero

### Corregido — encontrado metiendo Laravel

- **`shared/storage` no se creaba nunca, y las subidas se perdían en silencio.** La línea que sustituye `storage/` por el compartido sólo se activaba si `shared/storage` ya existía, así que en la práctica no se activaba jamás: logs, sesiones y subidas de usuarios se borraban en el despliegue siguiente sin un mensaje. Y crearlo a mano era peor —un `shared/storage` vacío deja la app devolviendo 500 en **todo**, con «Please provide a valid cache path.» y el cuerpo vacío para el visitante—. Ahora se siembra con el esqueleto que trae el propio repositorio, con `--ignore-existing` para no pisar jamás lo que ya haya. Siete de las diez comprobaciones nuevas se ponen en rojo sin el arreglo
- **Las cachés de Laravel no pueden generarse dentro del shell del build.** `_build_run` hace `set -a; . ./.env`, o sea que **exporta** las variables; y Dotenv usa `createImmutable`, así que no las pisa. Resultado: dentro del build gana el valor que ha interpretado bash y en tiempo de petición gana el de Dotenv. Con `APP_NAME='mi$app'` en el `.env`, medido: `mi$app` con php-fpm y `mi` en el build — y `config:cache` **congela el malo**. Una contraseña con un `$` dentro queda cacheada truncada y el síntoma es un «authentication failed» sin nada que lo explique. Peor: sin `config:cache` la app funcionaría. Ahora van en un paso aparte, con el entorno tal y como lo verá php-fpm
- **`orbit env set` sobre un Laravel decía que no había nada que reiniciar, y se callaba.** Con `config:cache`, Laravel deja de leer el `.env`: alguien podía cambiar la contraseña de la base de datos y ver que no pasaba nada. Ahora dice que se aplica al volver a desplegar — y no se regenera la caché sobre la release activa, que sería lo cómodo y mutaría una release ya publicada

### Seguridad — cuatro caminos más al mismo agujero, de una revisión adversarial

El soporte de Deno y Bun entró con las pruebas en verde, y una revisión hecha a propósito para romperlo encontró **cuatro repositorios más** que seguían acabando en `A_TYPE=static` con `A_OUTDIR="."`, o sea nginx sirviendo la raíz del repositorio. Los cuatro reproducidos, y las 21 comprobaciones nuevas se ponen en rojo (17 de 21) contra la versión anterior.

- **`bun.lock` en el `.gitignore`**, que es lo normal en mucha gente. `A_PKG` sólo vale `bun` si el lockfile está en el repositorio, y la comprobación empezaba exigiendo eso: un `package.json` que decía literalmente `"start": "bun run server.ts"` no se llegaba ni a mirar. La señal más fuerte de todas, tapada por una puerta puesta antes que ella
- **`bunfig.toml` sin `package.json`.** `_is_bun_app` sólo se llamaba desde dentro de la rama que exige `package.json`, así que su propia comprobación de `bunfig.toml` era código muerto
- **Deno importando por URL o `jsr:` a pelo**, sin `deno.json` ni `deno.lock`: nada que reconocer. Ahora vale el criterio de Hugo, la forma de un proyecto que se ejecuta
- **Un servidor de Node sin framework** —el `http` de la biblioteca estándar y nada más—, que llevaba ahí desde siempre: tiene `start` y no tiene `build`, que es justo lo contrario de un sitio compilado
- **Y cuando de verdad no se reconoce nada, se dice.** La rama de repuesto avisa de que va a servir el repositorio tal cual y de lo que eso significa, en vez de hacerlo en silencio

### Corregido — de la misma revisión

- **`deno install --frozen` sin lockfile sale con 1** y vuelca el diff del lockfile que acaba de calcular: ese repositorio no se podía desplegar **nunca**. `--frozen` sólo si hay `deno.lock`, que es la regla que ya seguía la rama de Node
- **Lo que decide entre `deno run` y `deno serve` es el `export default`, no el literal `Deno.serve`.** Fresh, Oak y cualquier cosa que llame a `app.listen()` no lo escriben, y `deno serve` sobre un módulo sin default falla **saliendo con 0** — systemd lo ve como una salida limpia, lo reinicia, y sólo lo caza el health check 40 s después. Es el «éxito mudo» del build de Go, otra vez. Y si el repositorio declara una tarea `build`, ahora se ejecuta
- **`jq` no sabe leer JSONC**, que es el motivo de existir de `deno.jsonc`: salía con 5 y sin imprimir nada, así que en una máquina con `jq` —la normal— un repositorio con `deno.jsonc` se quedaba sin fichero de arranque aunque su tarea lo dijera con todas las letras. Y el respaldo sin `jq` no entendía las tareas escritas como objeto: cada rama fallaba donde la otra acertaba
- **La tarea del repositorio manda sobre los nombres de siempre.** Un `main.ts` que es una herramienta de línea de órdenes y un `"start": "deno run -A src/server.ts"` arrancaban el fichero equivocado
- **Un `deno.lock` suelto convertía una app de Node en una app de Deno.** Basta con que alguien haya ejecutado `deno` una vez en el repositorio
- **Una app de tipo `bun` podía compilarse con pnpm**: el tipo salía de una señal y el gestor de otra, así que el diagnóstico exigía un binario y el build necesitaba el otro
- **`orbit doctor` daba verde a un bun/deno que el servicio no puede ejecutar.** El build va por `bash -lc`, que lee los perfiles de login; la unidad lleva un `PATH` fijo. Una herramienta en `$HOME/.bun/bin` con el `PATH` en el `.profile` compila y luego el servicio muere con 127. Ahora se pregunta dos veces y se dice cuál de las dos falla, porque se arreglan distinto

### Seguridad — un repositorio de Deno o de Bun se publicaba entero

- **El código fuente de una app de Deno se servía por HTTP.** Ninguno de los dos se detectaba, y la rama que no reconoce nada acaba en `A_TYPE=static` con `A_OUTDIR="."`: nginx sirviendo la raíz del repositorio. Como Deno y Bun no compilan a una carpeta —lo que se despliega *es* el fuente—, eso significaba publicar el servidor entero. Medido contra nginx antes de tocar nada: `GET /main.ts` devolvía **200 y el fichero completo**, y el `.env` iba con él. La prueba se escribió antes del arreglo: sin él, 22 de las 27 comprobaciones nuevas se ponen en rojo
- **La regla que sale de ahí, y que vale para el siguiente stack que entre: ante la duda, con proceso y no estático.** Equivocarse hacia «app con proceso» da un despliegue que falla en voz alta y con rollback; equivocarse hacia «estático» da uno que sale bien y publica el código. Y si se reconoce el stack pero no el fichero de arranque, se avisa y se deja el tipo puesto en vez de dejar que la app resbale hasta la rama estática. Ver ARCHITECTURE §18.8

### Añadido — Deno y Bun

- **Deno como stack de primera clase**: se detecta por `deno.lock` o por un `deno.json` que declare `tasks`, `imports`, `importMap` o `workspace`, se instala con `deno install --frozen`, se comprueban los tipos con `deno check` y se sirve por proxy como cualquier app con proceso
- **`DENO_DIR` fijo en `shared/deno`**, y es el fallo de corepack (§5.1) otra vez: Deno no deja `node_modules` en el repositorio, se lo baja todo a una caché que por defecto vive en el `HOME` — y el `HOME` del build no es el de la unidad, así que el build salía bien y el servicio se estrellaba al arrancar. Medido: con la caché apuntando a otro sitio, `--cached-only` aborta con «Specifier not found in cache»
- **Orbit no arranca con `deno task`**, aunque el repositorio lo traiga: a una tarea no se le puede cambiar el puerto. `deno task start -- --port 3999` ejecuta `deno serve main.ts '--' '--port' '3999'` —los argumentos entran detrás del fichero— y sigue escuchando en el 8000. Medido. Orbit compone la orden él, con `--port` y `--host 127.0.0.1`, porque `deno serve` tampoco lee `PORT` del entorno y sin `--host` se asoma a `0.0.0.0`
- **Los permisos de Deno son de la aplicación, no del servidor.** Orbit pone el mínimo con el que funciona una web normal y lo deja a la vista en `A_START` para que se edite; si el `deno.json` declara `permissions`, gana el repositorio y Orbit sólo pasa `-P`. Lo que no se concede —`write`, `run`, `ffi`, `sys`— es justo lo que systemd no puede negar dentro del directorio de la app: los dos cajones se complementan
- **Bun, distinguiendo sus dos papeles**: como gestor de paquetes de un proyecto que sigue siendo de Node sólo cambia el `install`; como runtime, cambia el proceso que arranca systemd. La pregunta sólo se hace cuando ningún framework ha coincidido, así que un Next instalado con bun sigue siendo Next. Hono, que corre en los dos, lo decide su `"start"`
- **`bun.lock` ya no se lee como npm.** Antes un repositorio con `bun.lock` se instalaba con `npm`, que es un gestor distinto con un lockfile que no existe
- **`orbit doctor` pregunta por bun y deno como el usuario de despliegue, no como root.** Sus instaladores dejan el binario en el `HOME` de quien los ejecuta, y luego se enlaza a `/usr/local/bin`: con `/root` en modo 700, `command -v` desde root dice que sí y **todos los builds mueren** con «command not found». Medido en el contenedor de desarrollo con `bunx`: root lo encuentra, cualquier otro usuario no. Si existe para root pero no para `deploy`, el diagnóstico lo dice tal cual, porque es un fallo distinto
- **Orbit no instala ninguno de los dos**, por el precedente de Hugo (§18.4) y de Go (§18.6)

### Seguridad — lo que sube un visitante ya no se ejecuta

- **Ejecución remota de código en cualquier app PHP que guarde subidas bajo su docroot.** `location ~ \.php$` casa con cualquier ruta acabada en `.php`, venga de donde venga el fichero. `php artisan storage:link` —y cualquier app que suba a una carpeta bajo el docroot— deja un directorio escribible por los visitantes dentro de lo que sirve nginx: subir un `avatar.php` y pedirlo devolvía **200 y lo ejecutaba**, y en producción el pool de php-fpm corre como el usuario de despliegue, dueño del código y del `.env` de **todas** las apps del servidor. Reproducido con nginx y php-fpm de verdad antes de tocar nada, y con la prueba escrita antes de creerse el arreglo: sin él se pone en rojo con un 200 y el fuente por delante
- **La regla no es una lista de nombres, es el modelo de releases**: la release es código inmutable que viene de git y `shared/` es lo que se escribe en tiempo de ejecución, así que lo que se alcanza por un enlace a `shared/` es dato y nunca código. Se calcula recorriendo el docroot, más `storage` siempre —el vhost se regenera desde `orbit port` o `orbit restore`, cuando puede no haber release— y más los nombres de siempre de las carpetas de subidas, que ya es heurística y está dicho como tal. Ver ARCHITECTURE §18.7
- **Las subidas legítimas se siguen sirviendo.** Cerrar el agujero rompiendo las fotos no es cerrarlo, y hay una comprobación que lo fija

### Corregido — de una revisión adversarial del cambio de idiomas

- **Un texto ya montado se volvía a interpretar como formato de printf.** `spin "$(t "Compilando (%s…)" "$A_BUILD")"` produce la frase con el comando ya dentro, y `spin` la pasaba otra vez por `printf`: el comando de build del repositorio, el nombre de la rama o una URL con `%XX` acababan siendo **el formato**. Con `A_BUILD='sh build.sh --tag 50%-done'` el spinner escribía `sh build.sh --tag 500one` —`%-d` es una directiva válida— y con un `%V` se filtraba «printf: invalid format character» al usuario. Todo en silencio y con código 0. Ahora `_t` no formatea cuando no le pasan argumentos, lo que mata la clase entera de una vez y hace que `"$(t …)"` sea seguro en cualquier posición. La regla que lo sostiene —un mensaje con `%` lleva siempre `%s`— es una prueba
- **`orbit list`, `orbit info`, `orbit status` y las siete pantallas de `--help` por comando salían en español con `--lang en`.** Eran `printf` crudos que nunca llamaban a `t`, así que el extractor no los veía y las comprobaciones de cobertura no podían echarlos de menos. La prueba nueva no mira el código: ejecuta cada comando en los dos idiomas y exige que la salida cambie. Ver ARCHITECTURE §21.8b
- **Un mensaje no podía traducirse nunca, y la prueba lo daba por bueno.** El de `orbit logs` con una opción desconocida se escribía con un salto de línea real y su clave con `\n` —dos caracteres—: cadenas distintas, así que el catálogo no la encontraba jamás. Pasaba desapercibido porque el extractor normalizaba los saltos antes de comparar, y las dos comprobaciones veían lo mismo a los dos lados. Hay ahora una comprobación byte a byte contra el array de verdad
- **Un `ORBIT_LANG` mal escrito dejaba a Orbit inservible… sólo si no eras root.** Al auto-elevarse, la variable se convierte en bandera, y las banderas sí se validan: un `export ORBIT_LANG=klingon` en un `.bashrc` abortaba cualquier orden para ese usuario y funcionaba para root, que no se eleva. Ahora sólo se pasa lo que existe
- **La rama de repuesto de `install.sh` no sustituía las marcas de color**: sin `orbit` al lado escribía `{b}orbit{r}` tal cual. Tiene que rendir igual que el núcleo, no sólo no romperse
- **`--` termina las banderas en `_lang_strip`**, para poder guardar un valor que se llame literalmente `--lang`

### Añadido — Go

- **Go como stack de primera clase**: se detecta, se compila con `go build -trimpath -o bin/app`, se sirve por proxy y se vigila como cualquier app con proceso. Verificado con once proyectos reales —`net/http`, chi, Gin, `cmd/*/main.go`, varios binarios, cgo, `go:embed`— y rompiéndolo a propósito ocho veces para recoger las firmas de error
- **Orbit no instala Go**, igual que no instala Hugo y por los mismos motivos con los números diez veces mayores: 287 MB de toolchain, el paquete de Ubuntu va por Go 1.22 (fuera de soporte), y —a diferencia de Node o PHP— el runtime no lo necesita, sólo el build. Se detecta, se dice cómo instalarlo cuando falla, y `orbit doctor` lo comprueba si alguna app lo usa. Ver ARCHITECTURE §18.6
- **La detección exige `go.mod` Y un paquete `main`**, no una de las dos: `hugo mod init` escribe un `go.mod` en la raíz del sitio, así que un Hugo con módulos es indistinguible de un repositorio de Go si sólo se mira el nombre del fichero. Y el `main` se busca leyendo los `.go`, porque puede vivir en `servidor.go`
- **Go va delante de `package.json`**: un servidor que empaqueta su frontend con `go:embed` tiene los dos ficheros en la raíz, y la rama de Node lo habría publicado como estático apuntando a un `dist/` que nadie genera — el fallo del monorepo otra vez
- **La caché de módulos no necesita configuración**: el build ya corre con `-H`, así que cae en `/home/deploy`, fuera de la release y compartida entre apps. Medido: 19,8 s en frío contra 0,57 s en una release nueva

### Corregido — encontrado metiendo Go

- **Un build de Go puede salir con código 0 y no dejar ningún binario.** `go build -o bin/app .` sobre un repositorio sin `package main` sale con **rc=0** y escribe un archivo `ar` de 2,8 KB en modo 0644. Sin comprobarlo llegaba a producción: symlink movido, systemd arrancando, «Permission denied», `Restart=always`, cuarenta segundos de health check y rollback — y el mensaje hablando de permisos, que es exactamente la pista falsa que costó los 36 reinicios de §5.1. Hay un paso 4c que comprueba `-x bin/app` con la release aún sin activar
- **`KillSignal=SIGINT` se salta el apagado ordenado de Go.** El patrón que trae la documentación de Go atrapa `SIGTERM`, muchas veces sólo `SIGTERM`: con `SIGINT` la app muere en seco con exit 130 y las peticiones en vuelo cortadas. La unidad usa ahora una señal u otra según el tipo
- **`go` casi nunca está en el PATH.** go.dev te dice que descomprimas en `/usr/local/go` y te deja a ti la línea del perfil, que se escribe en el perfil de quien la escribe y no en el de `deploy`. Se añade en el build y en `orbit exec`, al final para que un Go del sistema siga ganando; y `orbit doctor` mira los dos sitios, porque decir que falta Go donde Go funciona manda a arreglar lo que no está roto
- **El verificador del catálogo se saltaba los mensajes con un `$` escapado**, así que esas frases no se podían traducir y nadie se habría enterado. Ahora distingue una expansión de verdad de un dólar literal

### Añadido — Orbit habla tu idioma

- **Orbit detecta el idioma del sistema y habla en él.** Hoy son dos, español e inglés. No hay nada que configurar para el caso normal: si tu sesión está en inglés, Orbit está en inglés
- **`orbit --lang <código> <comando>`** para una sola orden, **`ORBIT_LANG`** en el entorno para una sesión, **`orbit lang <código>`** para dejarlo fijo en el servidor. La bandera vale delante y detrás del comando, como `--json`
- **Sin entorno también hay idioma.** El vigilante, el autodespliegue y cualquier línea de `cron` arrancan con el entorno vacío, así que se leen `/etc/default/locale` y `/etc/locale.conf` — con `grep` y no con `.`, porque son ficheros que edita cualquiera y sourcearlos sería ejecutar lo que haya dentro como root. `C` y `POSIX` no cuentan como inglés: son «ningún idioma», y tomarlas por inglés habría cambiado el idioma de medio servidor por correr dentro de un cron
- **La preferencia sobrevive a la auto-elevación.** `sudo` rehace el entorno; `LANG` y `LC_*` vienen en su `env_keep` de fábrica, pero `ORBIT_LANG` no. Se pasa como bandera al reexec, que no depende de cómo esté escrito el sudoers de cada servidor
- **`tests/i18n_test.sh`**, 91 comprobaciones: la precedencia entera, la normalización de códigos regionales, el formateo, las marcas de color y —lo que de verdad falla en silencio— el cruce del catálogo con el código, en `orbit` y en `install.sh`

- **El instalador también habla los dos idiomas**, y sin copiar nada: `install.sh` saca el núcleo de `orbit` —que está al lado, y hace falta de todas formas— con `sed`, entre dos marcas que lo delimitan. Es la misma técnica que ya usaba `tests/lib.sh`. Se comparte el mecanismo; el catálogo es suyo, porque el instalador y `orbit` no dicen las mismas frases. Sin `orbit` al lado, o sin las marcas, se queda en español en vez de romperse

### Cambiado — cómo se escribe un mensaje

- **La clave de traducción es la frase en español, no un nombre inventado.** Es el modelo de gettext sin gettext. Con claves simbólicas, un hueco en el catálogo saca `err.app_missing` por pantalla; con la frase, saca la frase en español, que es lo que salía antes de que existieran los idiomas. Y la llamada sigue diciendo lo que ve el usuario sin abrir otro fichero
- **Las partes variables salen de la frase y pasan a ser argumentos**: `die "La app '%s' no existe." "$n"`. Con la variable dentro de las comillas, lo que llega no es una frase sino «La app blog no existe», y no hay catálogo que encuentre eso. `ok`, `info`, `warn`, `err`, `die`, `title` y `hint` reciben ahora un mensaje y sus argumentos en vez de `"$*"`; los mensajes sin partes variables, que son la mitad, no hubo que tocarlos
- **Los colores dentro de un mensaje se escriben `{b}` `{d}` `{r}`** y no `${B}`. `${B}` se expande antes de que la traducción vea nada, así que la misma frase sería dos claves distintas según haya color o no. Se sustituyen después de buscar en el catálogo, y sólo si el mensaje trae una `{`
- **La ayuda y el menú se traducen enteros**, con una función por idioma, y no frase a frase: son dos columnas alineadas a mano, y traducirlas por trozos las desalinearía sin que nadie lo viera hasta ejecutarlas
- **El catálogo vive dentro de `orbit`.** `install.sh` copia un fichero, y un idioma que dependa de otro fichero al lado se pierde en cuanto alguien copia `orbit` a mano a otro servidor
- **No cambian de idioma** el log de `/var/log/orbit`, los comentarios de los vhosts y las unidades generadas, ni los nombres de campo del JSON. Los valores en prosa del JSON —`error`— sí; para automatizar están `ok`, `failed_step` y el código de salida. Ver ARCHITECTURE §21

### Corregido — encontrado al traducir

- **`printf -v` sin `--` convertía un mensaje en un error del intérprete.** Hay mensajes que empiezan por guión —«--lines quiere un número», «--json sólo está en…»— y sin el `--` printf los toma por opciones suyas, se queja y devuelve 2. Los cinco comandos que morían con uno de esos pasaban de salir con código 1 a salir con 2, y lo cazaron las pruebas del contrato JSON
- **Tres selectores reconocían lo elegido comparando con el texto que habían enseñado.** `«Elegir un repo de mi GitHub»`, `«✎ escribir otro comando»` y `«∅ ninguno»` se escribían dos veces: una para pintarlas y otra para compararlas. Eso funciona mientras el idioma sea uno solo. Ahora el rótulo se guarda en una variable y se compara contra ella, y donde el reconocimiento va por un símbolo de delante —`⎇`, `#`— el símbolo se queda fuera del catálogo, con una prueba que lo comprueba
- **Había texto escondido dentro de expansiones**, donde ningún catálogo lo alcanza: `${A_PORT:+ (puerto interno $A_PORT)}` y `${flags:+, $flags}`. Se convierten en dos mensajes completos
- **`sed … | grep -q` bajo `pipefail` no es nunca cierto, y dejó al instalador mudo.** Es la condición que decide si se carga el núcleo de idiomas: `grep -q` sale corriendo en cuanto encuentra la línea y cierra la tubería, `sed` recibe un SIGPIPE y muere con 141, y `pipefail` se queda con ese 141. El instalador se quedaba en español para todo el mundo **sin decir nada** — no hay error, no hay traza, sólo un idioma que no es. La misma trampa de `pipefail` que ya documentaba ARCHITECTURE §10, con otro disfraz. Ahora el trozo se saca a una variable y se comprueba dentro de bash, sin tuberías, y la prueba no mira la condición: ejecuta la cabecera del instalador con `LANG=en_US.UTF-8` y comprueba que sale una frase en inglés
- **Un `\n` dentro de un mensaje se imprimía literalmente.** `orbit logs` con una opción desconocida enseñaba `Opción desconocida: -x\n  uso: …` con la barra y la ene, porque el texto llegaba como argumento de un `%s` y printf sólo interpreta escapes en el formato. Ahora el mensaje **es** el formato, y el salto de línea es un salto de línea

### Corregido — encontrado al ampliar CI

- **Una prueba pasaba o fallaba según la máquina, sin que Orbit cambiara.** La del diagnóstico sin `dig` lo simulaba recortando el `PATH` a `/usr/bin:/bin`, y que eso funcione depende de dónde esté instalado `dig`: en el contenedor de desarrollo no estaba y en el runner de CI sí, así que la misma prueba daba dos resultados. La detección pasa a una función (`_have_dig`) que la prueba fija, y de paso se comprueba **la otra mitad** —con `dig` disponible se mira cada dominio—, que hasta ahora no miraba nadie

- **Las pruebas escribían unidades reales en `/etc/systemd/system`.** `subcmd_test` llamaba a `orbit autodeploy on` sin redirigir nada, así que dejaba un `orbit-autodeploy.timer` de verdad en la máquina de quien ejecutara la tanda **como root** — y como root sí escribe, la prueba pasaba. En CI, que corre sin privilegios, el mismo camino fallaba al escribir. Un fallo que sólo aparece según quién ejecute las pruebas es lo peor de las dos formas
- Se arregla en el banco de pruebas y no suite a suite: `tests/lib.sh` redirige **las cuatro** rutas de unidad a su directorio temporal, así que ninguna prueba tiene que acordarse. Las que quieren inspeccionar el fichero generado las redefinen después y su definición gana
- Las unidades del vigilante pasan a tener función propia (`watch_unit`, `watch_service`), como ya la tenían el servicio de una app y el autodespliegue: sin ella no había forma de redirigirlas

### Corregido — encontrado revisando el PR

- **`health_wait` escribía en stdout, y con `--json` eso rompía el objeto.** La cabecera, los puntos y el salto de línea iban directos a la salida normal, así que en una app **con servicio** el texto precedía al JSON y `jq` no podía analizarlo. No lo cazó ninguna prueba porque todas las de `--json` usaban una app estática, que no tiene servicio y nunca pasa por ahí. Todo va ahora por `$UI_FD`
- **La detección de terminal miraba el descriptor equivocado.** `[[ -t 1 ]]` pregunta por stdout aunque la presentación esté saliendo por stderr; ahora se pregunta por el destino real (`_ui_tty`). Mismo arreglo en el spinner
- **`rolled_back: true` cuando no se había restaurado nada.** En el primer despliegue de una app no hay release anterior: no se restaura, `current` se queda apuntando a la que acaba de fallar, y el objeto decía que había habido rollback. Para quien automatiza eso significa «producción está a salvo», que era exactamente lo contrario. El testigo se pone ahora **dentro** de la rama que restaura, y si no hay a dónde volver se dice
- **Dos trampas de `EXIT` peleándose.** `cmd_deploy` ponía la suya para emitir el JSON pasara lo que pasara, y `_maint_deploy_on` —que corre después, justo antes de reiniciar— la **sustituía**: `trap` reemplaza, no encadena. Resultado: el único fallo posterior a ese punto, el del health check, salía sin objeto — y es justo el que dispara el rollback. Ahora hay un solo manejador de salida para todo el despliegue
- **`orbit backup verify` ejecutaba el `app.conf` de la copia.** Se cargaba con `.` dentro de un subshell, que aísla las variables pero **no los efectos**: ficheros, procesos y red se habrían quedado hechos, y **como root**. Y este comando existe precisamente para apuntarlo a un fichero del que no te fías. Ahora se **lee** el nombre en vez de ejecutarlo, y de paso se comprueba que el manifiesto y el `app.conf` hablen de la misma app. `orbit restore` nunca lo ejecutó, así que era un agujero nuevo y no uno heredado
- **El HOME del servicio se colaba en todas las copias.** `shared/home` es caché —el gestor de paquetes que baja corepack y lo que cada librería deje ahí— y `_backup_one` lo copiaba entero, multiplicando el tamaño de cada copia y de cada generación conservada por datos que caducan. Se excluye, y el recuento de `ficheros_shared` se calcula después de excluirlo para que `verify` no eche en falta lo que nunca se guardó
- **`orbit deploy --all --json` prometía un objeto que no llegaba.** Marcar `deploy` entero como capaz de JSON aceptaba también `--all`, que despacha a `cmd_deploy_all` y devuelve el resumen en prosa. Ahora se rechaza con el comando alternativo escrito: un lote tiene cuatro resultados posibles por app —desplegada, al día, remoto mudo, rama desaparecida— y merece su propio contrato, no uno improvisado

### Añadido

- **`orbit deploy --json`** — el resultado del despliegue como un objeto: la release nueva y la anterior, el commit con su asunto, si hubo rollback, si hubo recuperación de build, cuánto tardó y, si falló, **en qué paso**. Era la última pieza que le faltaba al contrato para que un cliente pudiera enseñar un despliegue
- **La pregunta que dejaba abierta el ROADMAP —streaming o sólo resultado— resultó no obligar a elegir.** Por stdout va **un solo objeto**, como en todos los demás comandos: si `deploy` emitiera una línea por paso sería el único cuyo `--json` no es un documento JSON, `orbit deploy --json | jq .` daría error de sintaxis y cada cliente cargaría para siempre con un caso especial. Un contrato con una excepción son dos contratos
- **`--progress`** añade el progreso, una línea de JSON por suceso, **por stderr** y sólo si se pide. Quien quiera una barra la tiene; quien sólo quiera saber si ha ido bien no se entera de que existe
- **Un despliegue que falla también contesta.** Como los fallos salen por `die`, que hace `exit`, un `trap … EXIT` emite el objeto con `ok:false` y `failed_step`. Sin eso, un cliente tendría un código de salida y un texto en castellano escrito para una persona
- **Con `--json` no se pregunta nunca**: sin nombre de app aborta en vez de sacar el selector, y `--pick` está prohibido. `pick_app` escribe por stdout, que es donde va el objeto. Ver ARCHITECTURE §13.6b

### Cambiado

- **La regla «con `--json`, por stdout sólo el JSON» pasa de convención a estructura.** Se cumplía a mano, comando por comando, y funcionaba porque los comandos con `--json` se bifurcan pronto y no vuelven a hablar. `deploy` hace veinte cosas y cuenta cada una, así que mantenerlo a base de acordarse era cuestión de tiempo. Ahora `ok`, `info`, `warn`, `title`, `hr` y el spinner escriben en `$UI_FD`, que vale 1 normalmente y **2 con `--json`**: no hay forma de que un `✔` acabe dentro del objeto. De paso, eso es lo que permite que `--progress` no pise nada

- **`orbit doctor --fix`** — el diagnóstico ya sabía el arreglo de casi todo lo que detecta; ahora lo aplica cuando es seguro. Hoy son cuatro: PostgreSQL parado, php-fpm parado, el servidor por defecto ausente o sin bloque 443, y los puertos internos duplicados
- **La lista de lo que NO arregla es la parte importante**, y sale de cuatro reglas: no decide nada por ti, no hace falta hablar con nadie, se deshace, y no toca producción a ciegas. Quedan fuera instalar `pnpm` o `hugo` (instalar cosas en el servidor de alguien no es un diagnóstico), conectar GitHub o Cloudflare (hace falta un navegador y un token tuyo), liberar disco (qué se borra lo decides tú) y renovar certificados (se renuevan solos y hay límites de peticiones). Ver ARCHITECTURE §19.5
- **Se vuelve a diagnosticar al terminar y se enseña cómo queda.** Lo que cuenta es el estado del servidor, no lo que dijeron los comandos: un arreglo que devuelve 0 y no arregla nada tiene que verse
- **Arrancar no es estar vivo.** El arreglo de un servicio lanza el `start` y *después* comprueba `is-active`: una unidad puede aceptar el arranque y morirse acto seguido —es justo lo que hacía la app del §5.1— y mirar sólo el código de `systemctl start` diría «arreglado» sobre un servicio caído
- **Con puertos duplicados se mueve la que NO está sirviendo.** La app viva está atendiendo peticiones ahora mismo; moverla cortaría un servicio que funciona para arreglar otro que no
- **`doctor --fix --json` exige además `--yes`**: `confirm` escribe por stdout, donde con `--json` sólo puede ir el JSON, y dar por hecho que quien automatiza ya ha dicho que sí sería aplicar cambios sin que nadie los acepte. El JSON gana el campo **`fixable`**, que separa «hay consejo» de «hay botón»
- La entrada 15 del menú ofrece los arreglos además de enseñar el diagnóstico
- **Nueva suite `tests/doctorfix_test.sh`** (22 comprobaciones), centrada en lo delicado: que **no** toca lo que está bien, que un arreglo que aborta a mitad no cuenta como éxito, y que no se mueve la app que está sirviendo

- **`orbit backup verify [fichero]`** — comprueba que de una copia se puede **volver**, no sólo que el fichero está. Sin argumento, todas las que haya. Era lo que quedaba abierto del capítulo de copias: «hoy sabes que el fichero existe, no que se pueda volver de él»
- **Cada copia se verifica nada más crearla, y antes de pasársela al `BACKUP_HOOK`.** Mandar a S3 una copia rota es peor que no mandarla: te crea la sensación de estar cubierto. Si la verificación falla, el comando falla
- Se comprueba que el `.tar.gz` se abre entero, que lleva `manifest` y `app.conf` —lo mismo que exige `orbit restore` antes de tocar nada—, que el `app.conf` se puede leer, y que **lo que el manifiesto promete está dentro**: la base de datos, el `.env` y el número de ficheros de `shared/`. Para eso el manifiesto gana los campos `entorno=` y `ficheros_shared=`
- **Las copias de versiones anteriores siguen valiendo.** No traen los campos nuevos, así que esas dos comprobaciones se saltan; rechazarlas convertiría todo tu histórico en chatarra al actualizar
- Lo que **no** hace, a propósito: restaurar sobre una base de pruebas para ver si el SQL se aplica. Sería la única comprobación completa de verdad, pero exige crear y borrar bases en el servidor de producción, y una herramienta de verificación que puede romper lo que verifica no vale. Ver ARCHITECTURE §17.4b

### Corregido

- **Una copia podía decir que llevaba la base de datos y no llevarla, sin un solo aviso.** `pg_dump "$db" | gzip > fichero` — si `pg_dump` falla, **gzip escribe igualmente un `.gz` válido de contenido vacío** y la línea siguiente marcaba el manifiesto con `base_de_datos=si`. El fallo tampoco se propagaba: `_backup_one` se llama desde `if out="$(_backup_one …)"`, y dentro de un `if` bash apaga `errexit`, así que `pipefail` no saltaba. Ahora el código de salida se recoge con el único patrón que funciona (`set +e; ( set -Eeuo pipefail; … ); rc=$?; set -e`) y, si el volcado falla, **no hay copia**: mejor ninguna que una que miente
- **Tres de las cuatro formas de romperse una copia pasan `gzip -t`**: el `.gz` vacío del `pg_dump` fallido, el volcado cortado a la mitad por un OOM, y el `.env` que falta. Sólo el `.tar.gz` truncado por un disco lleno se cazaba antes. Comprobado rompiendo las cuatro a mano
- **La marca de volcado completo no es la última línea.** Desde PostgreSQL 16.13 el volcado acaba en `\unrestrict <token>`, *después* de `-- PostgreSQL database dump complete`. Mirar sólo el final daría por rota una copia buena en cualquier servidor al día. Y la marca empieza por `--`, así que sin `grep -e` delante grep la toma por una opción y la comprobación diría «no está» **siempre**: daría por rotas todas las copias. Las dos trampas están comprobadas contra un PostgreSQL 16 de verdad, no leídas
- **El `pg_dump` de mentira de las pruebas no se parecía a uno de verdad**: no llevaba la marca de cierre, así que ninguna prueba podía ejercer la comprobación de integridad. Ahora imita la estructura real, `\unrestrict` incluido

- **Logotipo en el menú**, con un barrido de entrada y un satélite que da una vuelta. Aparece **sólo si cabe** —46 columnas y 40 líneas— porque el menú ya son treinta y tantas líneas y seis más harían desaparecer por arriba justo lo que hay que leer; en una ventana pequeña se queda el rótulo compacto de siempre. Se anima únicamente la primera vuelta: volver del diagnóstico por décima vez y esperar otra vez al satélite convertiría un detalle simpático en un peaje
- **Los rótulos de sección del menú llegan hasta el borde** y las tres acaban en la misma columna. La raya se calcula contando **caracteres** y no bytes, que es lo que hacía `printf '%-*s'`: con `GESTIÓN` e `INFRAESTRUCTURA` la raya salía dos columnas más larga y las secciones no cuadraban. La misma trampa que documenta ARCHITECTURE §10, aquí a simple vista
- **La interfaz se adapta al ancho de la terminal** (entre 40 y 100 columnas) en vez de suponer 66 fijas, que en una ventana estrecha —un móvil por SSH, una pantalla partida— envolvían la raya a dos líneas. **Redirigida se queda en 66**, para que un log de `cron`, un `orbit deploy | tee` o un informe de fallo pegado en un issue salgan exactamente igual que antes
- **`NO_COLOR` se respeta**, con cualquier valor, incluso vacío ([no-color.org](https://no-color.org)). También `TERM=dumb`. Antes sólo se miraba si había terminal, así que quien pone `NO_COLOR` en su entorno tenía que tratar a Orbit como la excepción
- **`UI_ANIM="no"`** en `/etc/orbit/orbit.conf` apaga las animaciones enteras. Se apagan además solas sin terminal o sin color: una animación no puede ser obligatoria, porque quien trabaja por una SSH lenta o con un lector de pantalla la quiere quieta
- **La ruedecita de los procesos largos enseña el tiempo a partir de los cinco segundos.** Antes no, y a propósito: parpadeando desde el principio parece una cuenta atrás, cuando lo único que hace falta saber en un build largo es que sigue vivo
- **Nueva suite `tests/ui_test.sh`** (26 comprobaciones). No comprueba que quede bonito —eso no lo sabe una prueba— sino que la decoración no se cuela donde no debe: que el rótulo redirigido no lleva ni un escape ni un `\r`, que los acentos no descuadran los rótulos, y que la pausa de las animaciones ni gira en vacío ni se come el teclado

### Cambiado — rendimiento

Medido con 40 apps, que es donde se nota. Nada de esto cambia lo que hace Orbit: las 999 comprobaciones anteriores siguen dando exactamente el mismo resultado.

- **`app_names` es 180 veces más rápida** (81 ms → 0,45 ms por llamada). Arrancaba un `basename` por app, y por ahí pasan `list`, `status`, `doctor` y el rótulo del menú. Se sustituye por expansión de parámetros, que es equivalente porque `check_name` ya impide que un nombre lleve `/`
- **`app_count`, 360 veces** (77 ms → 0,2 ms): el glob a un array y contar elementos, sin la tubería a `wc -w`
- **`used_ports`, 30 veces** (230 ms → 7,6 ms). El coste no era el `sed` de dentro sino el `$(…)` de fuera: un fork por app sólo para recoger una línea. `_port_of_into` deja el puerto en `REPLY` y no hace falta capturar nada. `_port_taken_by_other` la llama una vez por candidato mientras busca hueco libre, así que esto se multiplicaba
- **`save_app`, 10 veces** (36 ms → 3,5 ms): abría el fichero 31 veces en modo añadir y lanzaba 31 subshells para entrecomillar. Ahora las 31 líneas se arman en memoria y se escriben de una. Además de más rápido es **más seguro**: si algo falla a mitad, el truncado y la escritura ocurren en la misma redirección, así que el fichero anterior sigue entero
- **La ruedecita ya no arranca un `sleep` por fotograma.** Eran doce por segundo durante todo el build: más de dos mil procesos en un build de tres minutos, sólo para dibujar. Se sustituye por un `read` con tiempo de espera sobre una tubería abierta por los dos extremos — **no sobre `/dev/null`**, que da EOF al instante y dejaría el bucle girando en vacío a toda velocidad, que es lo contrario de lo que se busca. Comprobado midiéndolo, y hay una prueba que lo fija

- **SvelteKit, Remix/React Router 7, Angular, Hugo y Eleventy** en la detección automática. Ninguno se dedujo de la documentación: se generó un proyecto con la herramienta oficial de cada uno, se compiló y se miró la carpeta de salida. Tres de los cinco resultaron distintos de lo que dice la mitad de internet. Ver ARCHITECTURE §18
- **SvelteKit se detecta por el adaptador**, no por el framework: `adapter-node` es un proceso (`node build`), `adapter-static` es un sitio en `build/`. Se mira el paquete instalado y no el fichero de configuración, porque `sv create` ya **no escribe `svelte.config.js`**: el adaptador se configura dentro de `vite.config.ts`. Con `adapter-auto` —el que trae el scaffold, y que sólo funciona en Vercel o Netlify— se elige proceso a propósito: si nos equivocamos, la app no arranca y hay rollback, mientras que tratarlo como estático publicaría el JavaScript del servidor
- **Remix es React Router desde 2025** (`create-remix` te manda a `create-react-router`). Se reconocen los dos por el paquete que *sirve* —`@react-router/serve`, `@remix-run/serve`—, no por `react-router` a secas, que es la librería de rutas de cualquier SPA de React: detectarlo así habría convertido en «proceso» a miles de sitios estáticos. Con `ssr: false` se sirve como SPA desde `build/client`
- **Angular** lee su `angular.json`: la carpeta de salida lleva dentro el nombre del proyecto, que no tiene por qué ser el del repositorio, y desde Angular 17 el builder nuevo mete además un subdirectorio `browser`. Comprobado compilando un Angular 20: `dist/<proyecto>/browser`, y con `@angular/ssr`, `dist/<proyecto>/server/server.mjs`
- **Hugo** se reconoce por su forma —`hugo.toml`, o `config.toml` junto a `content/` y `layouts/`— y **va antes que la detección de Node**: muchos sitios de Hugo llevan un `package.json` para Tailwind, y detectando Node primero se compilaban a un `dist/` inexistente. Su `package.json`, si lo hay, se usa para instalar dependencias antes de `hugo --minify`. Orbit **no instala Hugo**: es un binario que la mayoría de servidores no necesita, así que se detecta, se dice cómo instalarlo cuando falta y `orbit doctor` lo comprueba sólo si alguna app lo usa
- El orden de la cadena de detección es parte del diseño: cuatro de los cinco se construyen con Vite, así que si la rama de `vite` siguiera donde estaba, SvelteKit, Remix y una SPA de React Router se habrían clasificado como «SPA estática en `dist/`», una carpeta que ninguno de los tres genera
- **`orbit restore --all` levanta un servidor entero de una tirada.** El caso para el que existe todo esto: la máquina se ha perdido, hay un Ubuntu nuevo con Orbit instalado y un directorio con las copias. De cada app se coge la más reciente —leyendo el manifiesto, no el nombre del fichero, porque un nombre de app puede llevar guiones y puntos—, se enseña el plan entero y se pregunta **una vez**: encadenar veinte confirmaciones a las tres de la mañana no es seguridad, es una carrera de clics
- **La configuración global se restaura clave a clave, no fichero a fichero.** `orbit.conf` mezcla dos cosas: lo que describe a **este** servidor (`APPS_DIR`, `DEPLOY_USER`, `PHP_VER`) y lo que son preferencias tuyas (`LETSENCRYPT_EMAIL`, `KEEP_RELEASES`, los umbrales de `watch`, los ajustes de copias). Volcar el fichero entero deja un servidor recién montado apuntando a rutas que no existen; no restaurar nada obliga a reconfigurar a mano lo que ya decidiste una vez. La lista blanca es la única opción que acierta en los dos casos. `notify.conf` sí vuelve entero: no describe al servidor, dice a quién avisar. Ver ARCHITECTURE §17.5
- **El código no se despliega solo**, ni siquiera en `--all`: traerlo tarda, puede fallar y necesita GitHub conectado. O lo pides con `--deploy`, o se te imprimen los comandos ya escritos, uno por app
- **`orbit backup` y `orbit restore` completos.** Hasta ahora sólo se copiaban las bases de datos, y eso dejaba fuera lo único que de verdad no se recupera de ninguna parte: el `.env`. Cada copia es un `.tar.gz` con la configuración de la app, sus redirecciones, el `shared/` entero —secretos, subidas y página de mantenimiento— y el volcado de PostgreSQL. `orbit backup [app] | --all | list` y `orbit restore <fichero>`
- **El código no entra en la copia, a propósito.** Está en git, que es mejor copia que cualquier cosa que pudiera hacer Orbit, y meterlo multiplicaría el tamaño sin añadir nada. Restaurar no es «volver al estado anterior»: es dejar en su sitio lo que no está en git y desplegar, y el comando te lo dice al terminar con el nombre ya escrito
- **El rol de PostgreSQL se recrea con la contraseña que dice el `.env` restaurado.** Es el detalle que separa una restauración que funciona de una que lo parece: un `pg_dump` no lleva el rol, así que crearlo con una contraseña nueva haría que la app fallara horas después con `password authentication failed` sin que nada apuntara a la restauración
- **Formato abierto**: un `tar.gz` que se lee con `tar tzf`, con un manifiesto en texto plano que dice de qué app es, de qué repositorio sale el código y qué hacer con el fichero. Quien lo encuentre dentro de dos años sin Orbit delante puede reconstruir la app a mano
- **`BACKUP_HOOK`** para sacar cada copia del servidor: recibe la ruta del fichero recién creado y hace con él lo que sepa —`rclone`, `scp`, lo que tengas—. Orbit no habla con S3 ni debería: sería una dependencia, unas credenciales y un proveedor elegidos por ti. Si el hook falla se dice en voz alta, porque un envío que falla en silencio te crea la sensación de estar cubierto
- El **token de Cloudflare no se copia**: se regenera en treinta segundos y su ausencia hace que una copia robada no sirva para tomar el control de tu DNS. Las copias se guardan `0600` en un directorio `0700` y se borran a los `BACKUP_KEEP` días
- **PHP dentro de un proyecto que no es PHP.** Una web estática con un `contacto.php` ya no necesita configuración: se detecta al crear la app, nginx sirve los ficheros desde disco y le pasa los `.php` a php-fpm. Se implementa como **capacidad** (`A_PHP`) y no como un tipo nuevo: los tipos se multiplican —`static+php`, `next+php`, `static+python`— y cada combinación pediría su rama en la generación del vhost; una capacidad ortogonal es un campo más. Se detecta mirando el repositorio, podando `node_modules`, `vendor`, `.git` y `.cache`, porque un `.php` de ejemplo dentro de un paquete de npm no convierte tu web en una app PHP. Se fuerza con `--php yes|no` o con `"php": true` en `orbit.json`. Ver ARCHITECTURE §15
- Si el repo trae además `composer.json`, sus dependencias se instalan en el build sin perder el de la parte estática
- El despliegue **avisa si la capacidad está activa y no hay ningún `.php` en la carpeta publicada**, que es lo que pasa cuando el fichero está en `src/` en vez de en `public/`: en Astro y Vite sólo lo segundo se copia tal cual. Es el aviso que convierte «el formulario da 404 y no sé por qué» en una frase
- `orbit doctor` comprueba que php-fpm está vivo **si alguna app lo necesita**, y nombra cuáles
- El bloque de PHP del vhost vive ahora en un solo sitio para las apps PHP y para las estáticas con PHP: con dos copias, alguien endurecería una y la otra se quedaría atrás
- **Un build que falla por algo que Orbit no debe arreglar, al menos se explica.** No es lo mismo «no lo arreglo» que «no digo nada»: lo segundo te deja delante de un volcado de log a las once de la noche. Reconoce cuatro clases —lockfile desactualizado, lockfile ausente, disco lleno y versión de Node incompatible— con pnpm, npm y yarn, y escribe el comando exacto con **el gestor de paquetes de tu app**. El disco lleno se mira primero, porque provoca fallos raros más abajo y mirarlo al final sería dar el consejo del síntoma en lugar del de la causa. Las firmas están copiadas de la salida real de pnpm 11.20, npm 10.9 y yarn 4.5, ejecutadas a propósito para verlas
- **Un build que falla por algo con arreglo conocido se arregla y se reintenta**, en vez de dejarte entrar por SSH a las once de la noche. El caso que lo motivó es pnpm 11, que desde 2026 **falla** —ya no avisa— cuando una dependencia trae scripts de instalación sin aprobar: `[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: esbuild@0.28.1`. Orbit reconoce la firma, escribe el `allowBuilds` en la release, reintenta **una vez** y se lo apunta para que el despliegue siguiente salga a la primera. Ver ARCHITECTURE §14
- Las cinco reglas que hacen que eso no dé miedo: como mucho **un** reintento (dos intentos de build, nunca tres); solo fallos con firma conocida —un error de tu código no se reintenta, sería tardar el doble en dar la misma noticia—; todo dentro de la release nueva, sin tocar el repositorio ni la caché; lo aprendido se guarda en la configuración de la app; y se te dice qué cambiar en el repositorio para que Orbit no tenga que volver a hacerlo
- **Un `allowBuilds: false` se respeta.** Si tu `pnpm-workspace.yaml` deniega un paquete a propósito, Orbit no lo sobreescribe para que el build pase: lo dice y no reintenta
- **Segundo remedio: quedarse sin memoria.** Ante un `JavaScript heap out of memory` se reintenta con hasta un 75 % de la memoria **libre** (tope de 4 GB) y se recuerda en `A_NODE_HEAP`. Si no hay memoria libre que dar, **no se reintenta**: se explica que hace falta swap o compilar fuera, porque prometerle a Node una memoria que no existe solo cambia el error por una muerte a manos del OOM killer. El `NODE_OPTIONS` de tu `.env` sigue mandando sobre el calculado
- Todo esto se apaga con `BUILD_RECOVERY="no"` en `/etc/orbit/orbit.conf`
- **Deliberadamente NO se recupera un lockfile desactualizado.** Reintentar sin `--frozen-lockfile` publicaría en producción versiones que no están en tu lockfile, sin que nadie lo haya decidido. La recuperación puede arreglar *cómo* se compila; nunca *qué* se compila. Ver ARCHITECTURE §14.5

- **`orbit rollback <app> <release>`** sin selector, y **`orbit remove <app> -y [--purge]`** sin confirmación interactiva: los dos únicos comandos que quedaban sin forma no interactiva. `--yes` sigue significando «acepta lo que está por defecto» y no «que sí a todo», así que **`remove --yes` no borra tus ficheros**: para eso está `--purge`, que es una decisión aparte porque es un daño aparte —quitar la app de nginx se deshace volviéndola a crear, pero borrar `/srv/apps/<app>` se lleva releases, `.env` y subidas
- `orbit rollback` sin release y sin terminal **aborta explicando cómo se nombra**, en vez de elegir la primera de la lista, que es la que ya está activa. También rechaza una release que no existe —enseñando las que hay— y no hace nada si le pides volver a la que ya sirve
- **`--json` también en `version`, `db list`, `redirect list` y `watch status`.** `orbit version --json` da la versión de Orbit y la del contrato **por separado**: Orbit puede subir de versión sin que el contrato cambie, y un cliente que las confundiera se negaría a hablar sin motivo
- **`--json` en `list`, `info`, `status`, `doctor`, `top` y `env list`.** Es el contrato del que cuelga cualquier interfaz: sin él, un panel o un script acaban analizando tablas de texto con `awk`, y a partir de ahí alinear una columna rompe cosas en otra máquina sin que nada lo relacione con el commit que lo causó. La bandera vale delante o detrás del comando, y en uno que no la soporta **aborta diciéndolo** en vez de ignorarla: ignorarla en silencio le haría creer al cliente que va a leer JSON. **Promesa del formato: los campos se añaden, nunca se renombran ni cambian de tipo**; para romperlo habría que subir `schema`, que viaja en todas las respuestas. Ver ARCHITECTURE §13.1
- Un dato que no existe sale como `null`, nunca como cero ni cadena vacía: el puerto de una web estática no es el puerto 0, y su servicio no está `stopped` sino a `null`, porque no hay ningún proceso que arrancar. Confundir «no aplica» con «está caída» pinta una alarma donde no pasa nada
- `orbit env list --json` da **solo los nombres**, igual que su versión de tabla. Un panel que enseñe el `.env` entero filtra la contraseña de la base de datos en la primera captura que alguien pegue en un issue
- **`orbit top`**, panel en vivo con CPU, memoria y peticiones por minuto de cada app. Se refresca cada dos segundos, `q` sale y `r` refresca al momento; al salir el terminal queda como estaba. No abre ningún puerto, no deja nada corriendo y no añade dependencias: mide con systemd, con el log de nginx y con el disco. `--once` da un solo fotograma —y es lo que hace solo si rediriges la salida—, `--interval=N` cambia el refresco
- El porcentaje de CPU es una **diferencia entre dos lecturas** del cgroup, así que la primera no da número y se pinta como desconocido en vez de inventar un cero. Una app parada tira su muestra anterior, para que al arrancar de nuevo no aparezca un pico que nunca ocurrió, y un contador que retrocede tras un reinicio se ignora en vez de dar un negativo
- Las peticiones se cuentan sobre las últimas 5000 líneas del log (`TOP_LOG_LINES`), no sobre el fichero entero, porque el de una web con tráfico son cientos de megas y esto se refresca cada dos segundos. **Si un minuto llena ese tope el número sale con un `+` detrás**: un número corto sin avisar se lee como «hay poco tráfico», que es justo lo contrario de lo que pasa
- **`orbit new` funciona sin nadie delante**: `--repo`, `--name`, `--domain`, `--branch`, `--aliases`, `--email`, `--db`, `--no-ssl` y las que anulan la detección (`--type`, `--build`, `--start`, `--outdir`, `--appdir`, `--spa`, `--docroot`). Cada una es **el valor por defecto de su pregunta**, y `--yes` acepta esos valores sin leer de la entrada, de modo que el asistente y el modo automático recorren el mismo código y no hay una mitad sin probar. `--yes` no es «que sí a todo»: la base de datos no se crea y el editor del `.env` no se abre, porque esas preguntas tienen «no» por defecto. Ver ARCHITECTURE §13.5
- Los argumentos de `orbit new` se validan **antes de clonar**: descubrir que el tipo no existe después de bajarse el repositorio es tarde y deja basura en el disco
- `orbit new --yes` sin email de Let's Encrypt configurado **avisa y sigue** en vez de abortar: morir ahí dejaría la app creada y desplegada pero el comando en error, que es la peor de las dos opciones. El certificado se emite luego con `orbit ssl`

### Añadido

- **Modo EVA** (`orbit --eva`, también `--jedimaster`). *Extra-Vehicular Activity*: salir de la nave sin asideros. Orbit a secas decide por ti y pregunta lo justo; con `--eva` no decide nada solo — pasa por todos los campos, enseña los scripts del `package.json`, ofrece los PRs y los commits al desplegar, y deja escribir el comando que quieras en cada paso. Los dos modos recorren **el mismo código**: el modo es una variable que decide si se pregunta o se asume, no una segunda ruta que acabaría siendo la que nadie prueba. Ver ARCHITECTURE §20.5
- **La rama se elige de una lista** en `orbit new`, sacada de `git ls-remote --heads` sin clonar nada. No va en orden alfabético: `main` primero, luego `master`, `develop` y `dev`. Alfabético dejaría `develop` por delante de `main`, que es la que se quiere casi siempre. Escribir `master` en un repo cuya rama es `main` no daba un error que hablara de eso: daba un fallo de git tres pantallas después
- **`orbit deploy --pick`** para elegir qué desplegar de una lista: la punta de la rama, un **pull request sin fusionar** (`--pr 31`) o un **commit concreto** (`--ref 1a2b3c4`). Los PRs salen de `gh pr list` si hay GitHub CLI conectado; los commits, de la caché local. Con búsqueda, porque `choose()` ya usaba fzf
- **Desplegar un PR no cambia la rama de la app.** Es una prueba, no una mudanza: se avisa de que lo desplegado no es la punta de la rama y, si el autodespliegue está puesto, de que el próximo ciclo volverá a ella. Un despliegue fijado que se deshace solo y sin avisar sería peor que no poder fijarlo
- **Los comandos de build y arranque se eligen de los scripts del `package.json`**, con lo que ejecuta cada uno al lado. Los nombres se los pone cada proyecto —`build`, `dev`, `dev:debug`— y no hay forma de adivinarlos: hay que leerlos. Siempre se puede escribir otra cosa, porque un proyecto puede arrancar con algo que no está en `scripts`
- **Entrada 19 en el menú** para desplegar un PR o un commit, y el modo EVA se anuncia debajo de las opciones cuando está activo

### Corregido

- **Una app de Node cuyo repositorio fija el gestor de paquetes compilaba bien y luego no arrancaba nunca**, reiniciando en bucle con `EACCES: permission denied, opendir '/home/deploy/.cache/node/corepack/v1/pnpm'`. No era un permiso de disco: la unidad lleva `ProtectHome=true`, que **tapa `/home` con un tmpfs en modo 000**, y el `HOME` que systemd deduce de `User=deploy` cae justo debajo. Con `"packageManager": "pnpm@…"` en el `package.json`, el `pnpm` del arranque es el lanzador de corepack y su caché vive ahí. La unidad declara ahora su propio `HOME` dentro de `/srv/apps/<app>/shared/home`, que ya está en `ReadWritePaths` y por tanto es legible **y** escribible. Ver ARCHITECTURE §5.1
- **El arreglo no abre el cajón.** `ProtectHome=read-only` habría bastado para que arrancara y habría dejado a la app leer las claves SSH de `deploy` y las de cualquier otro usuario del servidor; el principio 7 dice que no hay un modo inseguro más cómodo. `ProtectHome=true` sigue tal cual, y hay pruebas que fallan si alguien lo relaja
- **`COREPACK_HOME` se fija explícita y no se deja heredar de `HOME`**: el `.env` de la app se carga *antes* que las líneas `Environment=`, así que un `XDG_CACHE_HOME` escrito ahí movería la caché y devolvería el mismo error sin nada que lo explicara
- **El build usa la misma caché que el arranque**, que es lo que hacía el fallo tan difícil de ver: el build no corre dentro de la unidad —usa `sudo -u deploy -H`, sin cajón— así que compilaba con `/home` a la vista y sólo se estrellaba después, con la release ya activa. Se mueve **sólo** la caché de corepack; el almacén de pnpm sigue compartido en `/home/deploy`, porque uno por app multiplicaría el disco de cada dependencia repetida
- **`orbit doctor` avisa de las unidades escritas antes de este cambio** (`service-home`) y remite a `orbit deploy`. No lo arregla él: regenerar la unidad sin rehacer el build dejaría la caché vacía, y el despliegue hace las dos cosas en el orden bueno
- **Nueva suite `tests/systemd_test.sh`** (23 comprobaciones) sobre la unidad generada, que hasta ahora no verificaba ninguna prueba pese a ser lo más delicado que escribe Orbit. La ruta del fichero pasa a una función (`svc_unit`) para poder leerla sin root, como ya se hacía con las unidades de `watch` y del autodespliegue
- **`orbit db list --json` decía `{"databases":[]}` con código 0 cuando PostgreSQL no contestaba.** Sin `--json` el mismo caso sale con error: las dos formas del mismo comando contaban cosas distintas, y la de las máquinas contaba la peligrosa — un script de copias que lea «no hay bases de datos» concluye que no hay nada que salvar. La consulta va ahora a una variable antes de imprimir nada, y si falla se aborta como sin `--json`. Un objeto vacío es una respuesta; uno inventado es una mentira. Ver ARCHITECTURE §20.8
- **`orbit watch status --json` no era JSON:** empezaba por `✔ Temporizador activo` y luego el objeto, así que `| jq` daba error de sintaxis. Callar la línea no bastaba, porque es un dato: ahora es el campo **`timer_active`**, y sin él un panel pintaría en verde sobre una vigilancia apagada, ya que los sujetos que enseña serían historia y no estado
- **El mensaje que rechaza `--json` nombraba cuatro de los nueve comandos que sí lo tienen**, así que quien probaba `orbit db list --json` y lo leía concluía que no existía. El texto vive ahora en `JSON_CMDS_HELP`, pegado al reconocedor, con una prueba que cruza las dos listas para que no se vuelvan a separar
- **Los comandos lanzados desde el menú corrían sin `errexit`**, así que uno que fallaba a mitad seguía adelante y anunciaba un éxito que no había ocurrido: `orbit github` decía «GitHub conectado» después de que `gh` fallara dos veces por no estar instalado. La causa es el propio arreglo anterior: bash apaga errexit dentro de cualquier comando que forme parte de una lista `&&` o `||`, y el subshell lo hereda — volver a poner `set -Eeuo pipefail` dentro **no** lo reactiva, ni esconderlo detrás de una función auxiliar. El subshell tiene que quedar suelto, con el errexit del padre apagado a mano alrededor. Ver ARCHITECTURE §20.7
- **El banco de pruebas tenía el mismo fallo**: `run cmd && r=0 || r=$?`, en 179 sitios, ejecutaba con errexit apagado — o sea que ninguna prueba lo estaba ejerciendo, y un comando que en el servidor aborta a mitad aquí llegaba al final devolviendo 0. Cambiadas a `run cmd; r=$?`, con el aviso escrito junto a la función en `tests/lib.sh`. Al encenderlo de verdad afloraron dos bugs que estaban tapados
- **`orbit restore` sobre un fichero que no es una copia salía con código 2 y sin una sola línea.** Con `pipefail`, un `tar` que falla hace que la tubería salga con su código, la asignación lo hereda y errexit mataba a orbit **antes** del `die` que explica qué pasa: el mensaje estaba escrito y era inalcanzable
- **`orbit status` se comía la entrada estándar y no listaba ningún servicio.** Al refactorizar para compartir la lista con la salida JSON, el `for s in nginx postgresql …` se convirtió en un `while read -r s` sin su `< <(_base_services)`. Un `while read` sin redirección lee de stdin: desde el menú pintaba como servicios las teclas que pulsabas después
- **`orbit doctor` se moría entero si faltaba `dig`**, y sin imprimir nada: la asignación `ip=$(dig …)` salía con 127 y `errexit` cortaba la recogida, que es lo que se imprime al final — así que se perdían también las comprobaciones que ya habían pasado. La herramienta que se ejecuta cuando algo va mal era la primera en romperse. Ahora se comprueba una vez, se avisa una vez —no una por app— con el `apt-get install dnsutils` que lo arregla, y el resto del informe sale igual
- **El spinner escribía una línea por cada fotograma cuando la salida no era un terminal.** El `\r` sólo borra la línea si hay un terminal detrás; redirigido a un fichero cada fotograma se quedaba escrito, y un build de tres minutos dejaba dos mil líneas iguales tapando el resto del log — justo donde va a parar la salida del autodespliegue y de cualquier `orbit deploy` en un cron
- **`orbit deploy --ref <commit>` fallaba con `couldn't find remote ref` en casi cualquier remoto que no fuera GitHub.** `git fetch origin <sha>` sólo funciona si el servidor anuncia SHAs sueltos. Y era innecesario: el commit ya estaba en la caché, que guarda los últimos 50 de la rama — los mismos que ofrece el selector. Ahora se mira ahí primero y sólo se pide al remoto lo que no se tiene, que es el caso de los PRs y las ramas. Si tampoco está, se explica que puede ser más antiguo que la profundidad del clon
- **La rama se preguntaba dos veces** en `orbit new`: el selector dejaba la elección hecha y el `ask` de siempre volvía a pedirla con ese valor por defecto
- **El aviso de `orbit new` cuando falla el primer despliegue daba por hecho que había fallado el build.** Si lo que se rompía era nginx —con el código ya compilado y la release activa— seguía mandando a mirar el repositorio, que es el sitio equivocado. Ahora se distingue mirando si existe el enlace `current`: con release publicada manda a `nginx -t` y `orbit doctor`; sin ella, al repositorio. Ver ARCHITECTURE §20.6
- **Un error dentro del menú cerraba Orbit y te dejaba en la shell.** El menú llamaba a cada comando con `cmd_new || true`, y ese `|| true` no servía para nada: `die()` termina en `exit 1`, y un `exit` no se caza con `||` — mata el proceso entero. El mensaje de error pasaba volando y no había forma de saber qué había ocurrido. Ahora cada comando va en un subshell, donde el `exit` se queda dentro, se espera a que se lea el error y se vuelve al menú. `logs` y `top` sólo pausan si fallan, para no meter una tecla entre el panel a pantalla completa y el menú. Ver ARCHITECTURE §20.1
- **`orbit new` dejaba media app y una shell cuando el primer despliegue fallaba.** El asistente registra la app y crea la base de datos *antes* de desplegar, así que el `die` de `cmd_deploy` mataba el proceso con la app ya registrada, sin ninguna versión publicada, sin certificado y sin que nadie dijera nada de eso. Leído desde fuera es «Orbit no sabe crear apps», cuando el fallo estaba en el repositorio. Ahora el asistente termina contando el estado —qué existe, qué no, y que el siguiente paso es `orbit deploy <app>` sin repetir el asistente— y explica cómo comprobar sin Orbit por medio que el mismo commit falla igual en cualquier sitio: el build se hace sobre un clon recién traído en una carpeta nueva, no hay nada heredado de otro despliegue. Ver ARCHITECTURE §20.2
- **`choose()` devolvía la pregunta pegada a la respuesta en un servidor sin fzf.** La lista ya iba por `stderr`, pero la pregunta la escribe `ask` por la salida normal — que es justo lo que `choose()` devuelve. Sin fzf, `pick_app` daba `App (número) [1]: mi-web` en vez de `mi-web`. No se notaba porque `install.sh` instala fzf; cualquiera que usara Orbit sin él tenía todos los selectores rotos. Ver ARCHITECTURE §20.4
- **Un lockfile desactualizado bloqueaba el despliegue aunque la deriva no pudiera tocar producción.** El caso real: un merge de PR que añadió `playwright` al `package.json` sin regenerar `pnpm-lock.yaml`. Orbit se negaba en bloque con el argumento de que instalar sin `--frozen-lockfile` publicaría versiones que nadie ha decidido. Medirlo demostró que **eso es falso en la mitad de los casos**: con una resolución vieja fijada a mano (`semver` en 7.3.5 bajo el rango `^7.3.5`, que permite 7.8.5), un install sin congelar dejó `semver` clavado en 7.3.5 y resolvió sólo el paquete nuevo. pnpm no reresuelve lo que no ha cambiado de especificador. Ver ARCHITECTURE §14.6
- **La frontera nueva, en una frase: Orbit resuelve solo lo que no llega a producción.** Si la deriva son sólo altas y **todas** están en `devDependencies`, se resuelven, se reintenta una vez y el despliegue sigue: se instalan para compilar y no viajan al runtime. Un especificador subido, una baja, o un paquete añadido que esté en `dependencies` siguen abortando — y ahí sí se publicaría una versión que no ha decidido nadie. Una sola dependencia de producción en el lote estropea el lote entero: el install es uno solo
- **Este remedio es el único que no se recuerda**, a diferencia de `A_PNPM_ALLOW` y `A_NODE_HEAP`. La deriva es una propiedad del commit, no de la app: apuntarla dejaría la app instalando sin lockfile congelado para siempre, cuando el despliegue siguiente —con el lockfile ya arreglado— funciona solo
- **Sólo con pnpm, y se dice por qué.** npm lista los paquetes que faltan del árbol entero, transitivas incluidas y ya resueltas (`Missing: is-number@3.0.0 from lock file`), y yarn no nombra ninguno; sin saber cuál es la dependencia directa no se puede decidir si llega a producción. Sin `jq` tampoco se puede clasificar, y Orbit se niega en vez de suponerlo
- **El consejo dice explícitamente que el arreglo va en tu máquina y no en el servidor**, que es el error que comete todo el mundo la primera vez y que no da ninguna pista de por qué no ha servido: `releases/` se copia con `rsync --exclude '.git'` y no es un repositorio, y `cache/` empieza cada despliegue con `git reset --hard`, así que se lleva por delante cualquier arreglo local. Y termina con el comando que sigue: `orbit deploy <app>`
- **El consejo ahora nombra el paquete y el motivo** en vez de dar una frase genérica: qué se añadió, qué se quitó y a qué le han cambiado la versión pedida. Y recomienda `git add pnpm-lock.yaml` en lugar de `git commit -am`, que se llevaría por delante cualquier otro fichero tocado del árbol de trabajo
- **Un dominio que no sirve ninguna app enseñaba, por HTTPS, la web de la primera app desplegada.** El servidor por defecto de nginx sólo cubría el puerto 80. Sin un `default_server` para el 443, una petición HTTPS cuyo SNI no coincide con ningún `server_name` la atiende **el primer bloque `listen 443 ssl`** que encuentra nginx, y ése es la primera app por orden alfabético. Apuntar un dominio cualquiera a la IP del servidor bastaba para ver la web de otro. Ver ARCHITECTURE §19
- **El mismo fallo con otra cara: una app recién creada enseñaba la web de otra hasta que se le emitía el certificado.** Entre `orbit new` y `orbit ssl` no hay certificado, así que el vhost de la app nueva no tiene bloque de 443 y su dominio caía en el mismo sitio. Por HTTP iba bien, lo que hacía que pareciera un problema de contenido —«será que le falta el `index.html`»— cuando no lo era: una app **con** certificado y sin `index.html` devuelve un 403 y no filtra nada
- Ahora el servidor por defecto **rechaza el saludo TLS** en el 443 (`ssl_reject_handshake`) y mantiene el `444` en el 80. No lleva certificado a propósito: no puede existir uno válido para un nombre que este servidor no sirve, y presentar el de otro dominio sólo cambia la filtración por un aviso del navegador. Detrás de Cloudflare el visitante ve un **525**, que dice la verdad. El desafío de Let's Encrypt sigue pasando por el 80, porque el primer certificado de una app se emite antes de que su vhost sepa de HTTPS
- **`sudo orbit nginx-rebuild` es lo que arregla un servidor ya instalado.** El vhost por defecto lo definía `install.sh` en un heredoc, que es justo cómo se quedó sin el bloque de 443: ahora hay una sola definición, la del script, y el instalador la obtiene llamando a `nginx-rebuild` al final. Se reescribe sólo si ha cambiado
- **`orbit doctor` lo comprueba** (`default-server`) y lo marca como **error**, no como aviso, si falta el fichero o si no cubre el 443. Un servidor que nadie regenera no se entera solo
- Las pruebas de HTTPS estaban en verde por el motivo equivocado: usaban `curl -k -H 'Host: …' https://127.0.0.1:PUERTO/`, que **no envía SNI** —el SNI sale del host de la URL, y ahí era una IP—, así que lo que ejercitaban era precisamente la caída al servidor por defecto. Reescritas con `--resolve`

### Cambiado

- **Los campos de configuración de una app se declaran en un solo sitio** (`ORBIT_APP_FIELDS`). Los leen `load_app`, `save_app` y el JSON. Antes había tres listas y añadir un campo era acordarse de tres: el que se olvidaba en `load_app` no se vaciaba entre apps y se quedaba **con el valor de la app cargada justo antes**, un fallo que solo aparece al recorrer varias seguidas, que es lo que hace `orbit list`
- `orbit doctor` recoge los diagnósticos primero y los pinta después, para que la tabla y el JSON no puedan decir cosas distintas. Sigue **saliendo con código 0** aunque encuentre problemas, a propósito: hay scripts que lo tienen encadenado con `&&` desde antes. Para decidir con el resultado está `.summary.error` del JSON
- Los días que le quedan a un certificado se calculan en un único sitio (`cert_days_left`), que ya usaban por separado `orbit watch` y `orbit doctor`. No hay certificado y quedan cero días dejan de compartir valor: lo primero es «no hay» y lo segundo es una emergencia
- **Todos los comandos con subcomandos despachan igual.** `env`, `redirect`, `watch`, `maintenance`, `autodeploy`, `db`, `notify` y `firewall` pasan ahora por un único `_subcmd`, con tres reglas iguales para los ocho: si el primer argumento es un subcomando, es un subcomando; si no, y es una app que existe, se usa el subcomando por defecto; si no es ninguna de las dos cosas, se aborta diciendo qué se esperaba. El razonamiento está en ARCHITECTURE §8.3
- **Un argumento que Orbit no entiende ya no se ignora.** `orbit maintenance loquesea` y `orbit autodeploy loquesea` respondían con el estado global —parecía que había funcionado— y `orbit redirect loquesea` imprimía la ayuda. Los tres abortan ahora con código 1 y nombran los subcomandos válidos
- **`orbit <comando> --help` funciona en los ocho** y sale con código 0. Los seis que no traían ayuda propia la obtienen de la misma declaración que usa el despacho, así que no puede quedarse desfasada
- `orbit maintenance <app>` y `orbit autodeploy <app>` muestran el estado **de esa app**, no el del servidor entero; `orbit redirect <app>` lista las suyas. Es la misma forma corta que ya tenía `orbit env <app>`
- Una app llamada como un subcomando (`status`, `set`, `on`…) sigue siendo alcanzable por la forma larga —`orbit maintenance status status`— y Orbit lo dice **por `stderr`** cuando detecta el choque, para no romper `VALOR=$(orbit env get app CLAVE)`

### Añadido

- **`orbit logs --since <cuándo>`** para ver una ventana de tiempo concreta: `2h`, `30m`, `3d`, `hoy`, `ayer`, `'10:00'` o una fecha ISO. Funciona con el journal y con los logs de nginx, que se filtran por su propia marca de tiempo. Con `--since` no se sigue en vivo —has pedido un tramo— salvo que añadas `-f`
- `orbit logs --nginx` muestra los logs de nginx aunque la app tenga proceso: un **502** lo escribe nginx y no aparece en el journal de la aplicación. Y `--lines N` cambia cuántas se enseñan
- **`orbit clone <app> <nuevo> [--domain d] [--branch r]`** para montar un staging a partir de una app que ya funciona. Hereda tipo, repo, rama, build, arranque, migraciones, redirecciones y página de mantenimiento; **no hereda** los valores del `.env`, el certificado, los dominios extra, el puerto ni el permiso de despliegue automático. Del `.env` se copian los nombres con el valor vacío, para que se vea qué falta por rellenar sin arrastrar la contraseña de producción; con `--with-env` se copian tal cual, avisando de lo que implica
- Las rutas absolutas de la configuración (`A_MEDIA_ROOT`, `A_STATIC_ROOT`) se **reapuntan a la carpeta de la copia**. Copiadas literalmente, el staging habría servido y sobrescrito las subidas de producción. Si apuntan fuera de la app, se avisa en vez de adivinar
- La copia **nace en mantenimiento**, con la página del original y un motivo que dice que aún no se ha desplegado: sin release, su dominio habría contestado 502. La validación de certbot sigue pasando, así que el certificado se puede emitir antes del primer despliegue
- Si `nginx -t` rechaza el vhost de la copia, se deshace todo —configuración, directorio, redirecciones y vhost—: una copia a medias con el dominio ya enganchado es peor que no tener copia
- **Motivo del mantenimiento**: `orbit maintenance on mi-web "Migrando la base de datos, volvemos a las 18:00"`. Se guarda en `shared/maintenance.reason`, aparte de la página, de modo que cambiar el mensaje no toca la maqueta y rediseñar la maqueta no pierde el mensaje. Se escapa antes de insertarlo, se borra al quitar el mantenimiento y aparece en `orbit maintenance status`
- **Página de mantenimiento** (`orbit maintenance on|off|status|edit <app>`): la web responde **503 con una página de aviso** en lugar de servir la aplicación. El interruptor es un fichero en `shared/`, así que encenderlo es instantáneo y **no hace falta recargar nginx**; funciona igual con un `touch` a mano. La página vive en `shared/maintenance.html`, sobrevive a los despliegues y Orbit no la vuelve a tocar una vez creada
- `orbit deploy` la pone sola durante el reinicio de las apps con proceso, de modo que el hueco en el que antes se veía un **502 Bad Gateway** pasa a ser una página honesta. Se desactiva por app con `A_MAINT_AUTO='no'`, y si ya la habías puesto tú a mano el despliegue no te la quita
- `orbit watch` avisa si una app lleva más de `WATCH_MAINT_MAX` minutos (30 por defecto) en mantenimiento
- **`orbit env get|set|unset|list <app>`** para tocar variables de entorno sin abrir un editor, y por tanto desde un script. `get` imprime solo el valor y devuelve código distinto de cero si la clave no existe, de modo que se puede distinguir «vacía» de «no está». `list` muestra solo los nombres: los valores son secretos. Los cambios no reinician la app salvo que se pida con `--restart`
- **`orbit autodeploy every <minutos>`** para cambiar cada cuánto se mira el remoto. El intervalo va dentro de la unidad de systemd, así que el comando la reescribe y reinicia el temporizador; `orbit autodeploy status` avisa si alguien editó `orbit.conf` a mano y la unidad se quedó atrás
- **`orbit deploy --all [--if-changed]`** para desplegar todas las apps de una pasada, cada una en su propio subproceso —un fallo no se lleva por delante el resto— y con resumen final. Devuelve código distinto de cero si alguna falló
- **`orbit autodeploy enable|disable|status <app>`**: la app se despliega sola cuando avanza su rama. Se sondea con un temporizador de systemd y `git ls-remote`, **sin webhooks ni puertos abiertos**; el análisis de las dos opciones está en ARCHITECTURE §4. Es un permiso **por app**, para que activarlo en `staging` no despliegue `produccion`
- Un commit que rompe el build se avisa una vez y **no se reintenta**: se guarda el SHA que falló y se espera a que llegue uno nuevo. Pedirlo a mano sí reintenta, que es la vía para volver a probar tras corregir algo que no está en el código
- **`orbit watch`**, vigilancia por temporizador de systemd. Comprueba cada minuto que las apps responden en su puerto interno, que nginx, PostgreSQL y php-fpm están vivos, el disco, la memoria y la caducidad de los certificados. Reinicia lo que se ha caído; el disco, la memoria y los certificados **solo avisan**, nunca actúan. `enable`, `disable`, `status`, `--once` y `--history`. **No hay ningún demonio**: es systemd invocando un script que termina
- **Protección contra bucles de reinicio**: 3 reinicios en 10 minutos y Orbit se rinde, marca la app como caída y avisa. La ventana se reinicia sola, de modo que tres reinicios repartidos por el día siguen siendo tres incidentes con derecho a intento
- **Capa de avisos reutilizable** (`orbit notify setup|test|status`) por Telegram, Discord o webhook genérico, con filtro por nivel. Se avisa de la **transición**, no del estado: una app caída de madrugada genera un mensaje, no trescientos
- **`orbit redirect`** para redirecciones de ruta (`orbit redirect add mi-web /precios /pricing`) y de dominio entero (`orbit redirect add viejo.com https://nuevo.com`). Admite comodines (`/blog/*` → `/noticias/*`) y expresiones regulares (`~^/p/(\d{3})$` → `/producto/$1`). 301 por defecto, con `--302`, `--307` y `--308`. Las reglas viven en `/etc/orbit/redirects/<app>.list`, legibles con `cat`, y se vuelven a escribir en cada `orbit deploy` y `orbit nginx-rebuild`
- Las redirecciones **conservan la cadena de consulta** por defecto, al contrario que `return` de nginx. Perder `?utm_source=` rompe la atribución de las campañas sin que nadie lo note. `--no-query` la descarta a propósito
- **Soporte de Django, Flask y FastAPI en condiciones.** Se detecta el framework, el gestor de dependencias (`uv.lock`, `poetry.lock`, `requirements.txt` o `pyproject.toml` a secas) y el módulo real de la aplicación, en lugar de asumir `app:app`. El nombre del proyecto Django sale de `DJANGO_SETTINGS_MODULE` leído de `manage.py`, así que funciona con `config/`, `src/` o cualquier distribución. Se elige `uvicorn` en vez de `gunicorn` cuando hay un servidor ASGI de verdad en las dependencias, no por la mera existencia de `asgi.py`
- **Estáticos de Django servidos por nginx.** El build ejecuta `collectstatic` y, con el venv ya montado, Orbit le pregunta a Django por `STATIC_URL`, `STATIC_ROOT`, `MEDIA_URL` y `MEDIA_ROOT` y genera los bloques `location`. Con `DEBUG=False` Django no sirve estáticos en absoluto, así que sin esto la web sale sin CSS
- **`orbit migrate [app] [--yes]`** que enseña el plan completo antes de pedir confirmación. `orbit deploy` **nunca** aplica migraciones; solo comprueba si hay pendientes y avisa con el comando exacto
- Avisos al desplegar Django de los tres fallos que más veces dejan una web rota o expuesta en un VPS: `DEBUG=True`, dominio ausente de `ALLOWED_HOSTS` y `MEDIA_ROOT` dentro de la release
- **`orbit exec <app> [comando]`** para ejecutar algo en la release activa como usuario `deploy` y con el entorno real de la app: su `.env`, `PORT`, `HOST` y `NODE_ENV=production`, respetando la misma precedencia que la unidad de systemd (el `.env` primero, las variables fijas después). Sin comando abre una shell. El `PATH` lleva por delante `node_modules/.bin` y `.venv/bin` de la release. La salida es la del comando, sin decoración, y el código de salida se propaga
- `orbit port [app] [puerto]` para cambiar el puerto interno de una app. Sin número solo actúa si detecta un conflicto, así que es idempotente
- `orbit doctor` avisa de puertos internos duplicados entre apps
- Suite de pruebas con arnés compartido (`tests/lib.sh`): `unit_test.sh` (puertos y conteo de apps), `exec_test.sh` (entorno de `orbit exec`), `python_test.sh` (proyecto Django real de principio a fin y arranque real de Flask y FastAPI), `redirect_test.sh` (redirecciones servidas por nginx de verdad), `watch_test.sh` (transiciones, bucles de reinicio y avisos), `autodeploy_test.sh` (despliegue en lote y automático contra repos git reales), `env_test.sh` (ida y vuelta del `.env` con valores que llevan `$` y comillas), `maintenance_test.sh` (el 503 servido por nginx real y la validación de certbot intacta), `nginx_test.sh` (vhost validado con nginx de verdad, ambas ramas de certificado, no regresión del bucle de redirecciones) y `deploy_test.sh` (ciclo de despliegue completo contra un repo git local, incluido el caso de build fallido). `make test` las ejecuta todas

### Corregido

- **Un `.php` dentro de una web estática se servía tal cual, entregando el código fuente.** nginx no trae `php` en `mime.types`, así que el fichero salía como `application/octet-stream` y el navegador se lo descargaba entero, con las credenciales que llevara dentro. Le pasa a cualquier sitio de Astro o Vite con un formulario de contacto en PHP. Ahora, o lo ejecuta php-fpm, o devuelve **404** —y 404 y no 403, que confirmaría que el fichero está ahí. Comprobado contra nginx de verdad, y hay una prueba que vuelve a fallar si alguien deshace el arreglo. **Si te descargaba el fichero, cambia las credenciales que llevara dentro**
- **Una app en mantenimiento seguía ejecutando PHP.** El guard sólo estaba en `location /`, así que una petición directa a un `.php` se saltaba el 503: la web decía «volvemos enseguida» mientras el formulario seguía mandando correos
- **A un subdominio se le proponía `www.`**. Para `blog.midominio.com` se ofrecía `www.blog.midominio.com`, que no usa nadie y que no está en el DNS. El daño no es cosmético: ese alias entra en la petición de certificado, y Let's Encrypt valida **todos** los nombres del lote o no emite ninguno, así que un alias fantasma puede dejar sin HTTPS un dominio que funcionaba. Ahora el `www` sólo se propone para dominios registrables —`midominio.com`, `midominio.co.uk`, `midominio.com.ar`—, y la duda se resuelve siempre hacia el «no»: equivocarse ahí cuesta escribir `--aliases` una vez, y equivocarse al revés cuesta un certificado. Ver ARCHITECTURE §16
- **`orbit env list` moría en silencio con un `.env` vacío.** Con `pipefail`, el `grep` que busca las claves devuelve 1 cuando no encuentra ninguna, la asignación hereda ese 1 y `errexit` se lleva el comando por delante con código 1 y sin una línea de salida. La rama que anuncia «el .env está vacío» era, hasta ahora, inalcanzable. Lo encontró la prueba del contrato JSON, que es el primer sitio donde se miró ese caso
- **`confirm` anunciaba `[S/n]` cuando el valor por defecto era «no».** Varias llamadas pasan el valor de un campo —`confirm "¿Es una SPA?" "$A_SPA"`—, donde el no se escribe `no` y no `n`, y la comparación era por igualdad exacta. Respetaba el no, pero después de haber dicho lo contrario, que es la peor combinación posible
- **`orbit port <app> <puerto>` aceptaba un puerto ocupado por otro proceso** si el servicio de la app estaba en marcha. La excepción «quien escucha en ese puerto soy yo» se aplicaba a cualquier puerto en vez de sólo al suyo, así que con la app viva `orbit port mi-web 5432` pasaba la validación, se guardaba y regeneraba nginx y systemd, y el reinicio fallaba o nginx acababa haciendo de proxy a PostgreSQL
- **`orbit redirect add <dominio>` no comprobaba si ese dominio ya lo servía otra app.** nginx acepta dos vhosts con el mismo `server_name` avisando sólo por el log y se queda con uno según el orden de los `include`: la redirección funcionaba o no según cómo se llamaran los ficheros, y podía tapar el dominio de la app existente en el siguiente `nginx-rebuild`. Ahora se rechaza nombrando a la app que lo tiene, mirando también los alias
- **El autodespliegue se paraba en silencio si no podía preguntar al remoto.** «No hay commits nuevos» y «no he podido preguntar» devolvían lo mismo, así que con el token caducado, el repositorio renombrado o la red caída el temporizador anotaba «sin cambios» cada cinco minutos y terminaba **en verde**. La web seguía sirviendo la versión vieja sin dar ninguna señal. Ahora son cuatro respuestas distintas, la pasada devuelve error —de modo que `systemctl status orbit-autodeploy` lo enseña en rojo— y se avisa **por transición**: un mensaje cuando empieza y otro cuando se arregla, no uno cada pasada
- El motivo exacto que dio git (`Repository not found`, `could not read Username`, `Could not resolve host`) sale en el aviso, porque los tres se arreglan de forma distinta. Y **«la rama ya no existe en el remoto» es un caso aparte**, con su propio mensaje: eso se corrige cambiando la rama, no esperando a que vuelva la red
- `orbit autodeploy status` y `orbit doctor` señalan las apps cuyo remoto lleva rato mudo
- **Los logs de nginx no llevaban la fecha.** El formato `orbit` empezaba por la IP: una línea que no se puede situar en el tiempo sirve para contar, no para depurar, y hacía imposible cualquier filtro. Ahora empieza por `[$time_local]`. Como ese formato vive en la configuración base y no se regenera con los vhosts, `orbit nginx-rebuild` corrige la línea en los servidores ya instalados, con copia y validación
- `orbit logs` de una app recién creada abortaba porque `tail` no encontraba los ficheros; ahora dice que todavía no hay nada
- **El nombre de una app ya se valida.** Acaba siendo un fichero de configuración, una unidad de systemd y un vhost; uno con `/` o `..` escribía fuera de `/etc/orbit/apps`. `orbit new` y `orbit clone` lo rechazan
- `render_nginx` ya no deja escapar el error de `systemctl reload nginx`: la configuración está escrita y validada, así que se avisa en vez de fallar en silencio. Es la misma trampa que ya se había corregido en `systemctl daemon-reload`
- Documentada una trampa de bash 5.2 en ARCHITECTURE §10: `patsub_replacement` viene activado por defecto, así que `&` en el reemplazo de `${var//patrón/reemplazo}` significa «lo que ha coincidido» y `${s//</&lt;}` produce `<lt;`. No da error, solo corrompe la salida
- **`db_create` escribía `DATABASE_URL` entre comillas dobles.** Si la contraseña hubiera llevado un `$`, bash lo habría expandido al cargar el `.env` y la app habría recibido una URL truncada. Hoy no ocurría porque el generador usa base64 y nunca produce `$`, pero era el mismo fallo que ya costó `_q()` esperando a que alguien editara el fichero a mano. Ahora pasa por el mismo entrecomillado seguro
- `systemctl daemon-reload` sin proteger mataba `orbit watch enable` y `render_systemd` por `errexit` justo después de escribir las unidades, sin decir nada, en cualquier entorno donde systemd no conteste
- **Las redirecciones degradaban a `http://` detrás de Cloudflare.** nginx convierte `return 301 /pricing` en una URL absoluta usando el esquema de la conexión con el origen, que con Cloudflare es el puerto 80 aunque el visitante venga por HTTPS. Los vhosts generados ahora llevan `absolute_redirect off`, así que la respuesta es relativa y el navegador conserva su esquema. Afectaba también a las redirecciones que nginx genera solo, como añadir la barra final a un directorio, de modo que ocurría en cualquier web estática desde el primer día
- **El build de Python fallaba siempre con `pyproject.toml`.** Se generaba `pip install -r requirements.txt` aunque el proyecto no tuviera ese fichero, de modo que ningún proyecto con Poetry o uv podía desplegarse
- **`app:app` como punto de entrada para todo.** Un comando sintácticamente correcto que no levanta nada: en Django ese objeto no existe, y en FastAPI o Flask solo acierta por casualidad
- **Colisión de puertos.** `free_port()` buscaba `A_PORT="3001"` con comillas dobles, pero `save_app()` serializa con comillas simples desde que se arregló la expansión de `${PORT}`. El grep no coincidía nunca y la única defensa que quedaba era `ss`, que solo ve puertos con algo escuchando. Al registrar una app nueva con otra parada, las dos recibían el mismo puerto: la segunda unidad moría con `EADDRINUSE` en el bucle de `Restart=always`
- `banner()` contaba las apps con `ls "$APPS_CONF"/*.conf | wc -l`. Con `nullglob` y cero apps, `ls` se queda sin argumentos y lista el directorio de trabajo: un servidor recién instalado decía tener tantas apps como ficheros hubiera en el directorio desde el que invocaras Orbit
- Dos despliegues dentro del mismo segundo compartían carpeta de release, de forma que la versión "anterior" a la que volver era la que se acababa de sobrescribir. Ahora la marca de tiempo se desambigua con un sufijo
- `mapfile -t rels` y `mapfile -t repos` no eran `local` y pisaban el ámbito del llamador
- `make lint` no pasaba: había 20 avisos de shellcheck, incluidos los SC2046 que CONTRIBUTING daba por marcados y no lo estaban

### Cambiado

- **Regla 1: Orbit despliega repositorios de git, y nada más.** Queda escrito en ARCHITECTURE §1, en el "Fuera de alcance" del ROADMAP, en los filtros de CONTRIBUTING y en el README. Las aplicaciones que se instalan desde una web y se actualizan solas —WordPress, foros, paneles— están fuera por incompatibilidad de diseño, no por falta de esfuerzo: una aplicación que se modifica a sí misma no cabe en un modelo de releases inmutables, porque el siguiente despliegue borraría lo que ella escribió. Se han retirado del backlog y de la documentación
- `make lint` fija `LC_ALL=C.UTF-8`: shellcheck aborta al imprimir un aviso con acentos si la configuración regional no es UTF-8, y en cron o systemd `LANG` suele venir vacía
- Nuevos campos en la configuración de cada app: `A_PYMGR`, `A_PYFW`, `A_MIGRATE`, `A_STATIC_URL`, `A_STATIC_ROOT`, `A_MEDIA_URL`, `A_MEDIA_ROOT`, `A_REDIRECT`, `A_REDIRECT_CODE`, `A_AUTODEPLOY`, `A_AUTOFAIL` y `A_MAINT_AUTO`. Las configuraciones existentes siguen cargando sin tocar nada: `load_app` pone los campos a vacío antes de leer el fichero

- `render_nginx` se divide en `nginx_vhost` (genera el vhost por la salida estándar) y `render_nginx` (lo instala, valida y recarga). Permite validar la plantilla con `nginx -t` sin escribir en `/etc/nginx`
- Las rutas de los certificados se centralizan en `cert_file`, `cert_key` y `has_cert`
- El bucle de espera del health check pasa a `health_wait`, reutilizable
- `pick_app` sustituye a `require_apps` más `choose ... $(app_names)` en los diez sitios donde se repetía

## [1.0.0] - 2026-08-05

Primera versión pública.

### Añadido

- Instalador para Ubuntu 24.04 con nginx, Node 22 y pnpm, PostgreSQL, PHP 8.3 FPM, Python, Certbot, GitHub CLI, UFW y fail2ban
- Detección automática de stack para Next.js, Astro, Vite, Create React App, Nuxt, Express, Fastify, Koa, NestJS, Hono, PHP y Python
- Despliegues atómicos con carpetas de release y symlink `current`
- Rollback automático cuando la app no supera el health check
- `orbit rollback` para volver a cualquiera de las 5 últimas releases
- Emisión de certificados por DNS-01 con la API de Cloudflare, compatible con el proxy activado
- Menú interactivo y CLI equivalentes
- Creación de bases de datos PostgreSQL con `DATABASE_URL` escrita en el `.env`
- Copia de seguridad diaria de bases de datos con retención de 14 días
- `orbit firewall lock` para restringir el origen a los rangos de Cloudflare
- `orbit doctor` con diagnóstico de nginx, servicios, DNS y caducidad de certificados
- Restauración de IPs reales de Cloudflare en nginx
- Auto-elevación con sudo cuando se invoca sin privilegios

### Corregido durante el desarrollo

Se listan porque son trampas que pueden reaparecer:

- Directivas `gzip` y `access_log` duplicadas frente al `nginx.conf` por defecto de Ubuntu, que impedían arrancar nginx
- Uso de `http2 on;` en nginx 1.24, donde esa directiva no existe todavía
- `listen [::]:80` incondicional, que tumbaba nginx en servidores sin IPv6
- Cuelgue infinito cuando `grep` recibía un glob vacío y pasaba a leer de stdin
- Variable de bucle sin `local` que pisaba la del llamador en `detect_stack`
- Serialización de la configuración con comillas dobles, que expandía literales como `${PORT}` al recargar
- `NODE_ENV=production` durante el build, que hacía que npm y pnpm se saltaran las devDependencies y provocaba fallos de PostCSS y de resolución de módulos TypeScript
- Bucle infinito de redirecciones cuando la zona de Cloudflare está en modo Flexible
- Directorio base sin el propietario correcto, que impedía desplegar apps registradas a mano
- Columnas descuadradas en `orbit list` por contar bytes en lugar de caracteres
