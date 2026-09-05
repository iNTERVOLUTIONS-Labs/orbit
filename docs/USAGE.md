# Uso diario

Todos los comandos aceptan el nombre de la app como argumento. Si lo omites, Orbit te deja elegirla de una lista.

`dv` es un atajo de `orbit`. `dv list` funciona igual.

## Cómo se leen los comandos

La forma general es siempre la misma:

```
orbit <comando> [subcomando] [app] [argumentos…]
```

Los comandos con subcomandos (`env`, `redirect`, `watch`, `maintenance`, `autodeploy`, `queue`, `db`, `notify`, `firewall`) aceptan también el nombre de una app en el sitio del subcomando, y entonces usan el suyo por defecto:

```bash
orbit env mi-web           # = orbit env edit mi-web
orbit redirect mi-web      # = orbit redirect list mi-web
orbit maintenance mi-web   # = orbit maintenance status mi-web
orbit autodeploy mi-web    # = orbit autodeploy status mi-web
```

Tres reglas, iguales en todos:

1. **Si es un subcomando, es un subcomando.** Gana siempre al nombre de la app.
2. **Si no es un subcomando pero es una app que existe**, se usa el subcomando por defecto.
3. **Si no es ninguna de las dos cosas, el comando aborta** y dice qué esperaba. Nunca hace otra cosa en silencio.

De la primera regla se sigue el único caso incómodo: si tienes una app llamada `status`, `set`, `on` o `list`, el atajo no la alcanza. Escribe el subcomando entero y se resuelve:

```bash
orbit maintenance status status   # la app 'status'
orbit env edit set                # la app 'set'
```

Cuando eso pasa, Orbit te lo dice por `stderr` —nunca por la salida normal, para no romper `VALOR=$(orbit env get ...)`.

Y si no te acuerdas de los subcomandos de alguno, `--help` los lista:

```bash
orbit autodeploy --help
# uso: orbit autodeploy <enable|disable|every|once|status> [app]
```

## Crear una app sin asistente

`orbit new` pregunta una cosa detrás de otra, que es lo cómodo si estás delante. Si no lo estás —un script de aprovisionamiento, una plantilla de servidor, un cliente que habla por SSH— cada dato se puede dar por argumento:

```bash
orbit new --repo https://github.com/yo/mi-web.git \
          --domain mi-web.com \
          --email yo@mi-web.com \
          --yes
```

`--yes` es lo que convierte el asistente en un comando: **no pregunta nada y acepta el valor por defecto de cada pregunta**. Ojo con lo que eso significa, porque no es «que sí a todo»:

- La base de datos **no** se crea, porque esa pregunta tiene «no» por defecto. Se pide con `--db`.
- El editor del `.env` **no** se abre, por lo mismo.
- El certificado **sí** se emite, porque esa tiene «sí» por defecto. Se evita con `--no-ssl`.

Lo que no se puede adivinar se dice, no se inventa: sin `--repo` o sin `--domain` el comando aborta explicando cuál falta.

`orbit new --help` lista todas las opciones. Las que anulan la detección automática son útiles cuando tu proyecto no encaja en ningún molde:

```bash
orbit new --repo git@github.com:yo/api.git --name api --domain api.mi-web.com \
          --type node --build "" --start "node dist/server.js" --yes
```

`--build ""` es una respuesta, no un olvido: significa «esta app no se compila». Si no dices nada, vale lo que Orbit haya detectado.

**Sobre el certificado.** Let's Encrypt necesita un email y sin terminal no hay a quién pedírselo. Si lo pasas con `--email` (o ya está en `orbit.conf`), el certificado se emite. Si no, la app se crea y se despliega igual, se avisa, y lo emites luego con `orbit ssl mi-web`. No se aborta a medias: dejarte la app creada pero el comando en error es la peor de las dos opciones.

## Los dos modos

```bash
orbit …            # sencillo: decide por ti y pregunta lo justo
orbit --eva …      # EVA: no decide nada solo
```

**EVA** es *Extra-Vehicular Activity*: salir de la nave, sin asideros, tú a los mandos. En vez de preguntar «¿es correcto?» pasa por todos los campos, te enseña los scripts de tu `package.json` para que elijas cuál compila y cuál arranca, te ofrece los PRs y los commits al desplegar, y te deja escribir el comando que quieras en cada paso. También responde a `--jedimaster`.

Los dos modos recorren el mismo código: el modo decide si se pregunta o se asume, no hay una segunda ruta «para expertos».

## Desplegar

```bash
orbit deploy mi-web
```

### Desplegar un PR o un commit concretos

```bash
orbit deploy mi-web --pick        # elegir de una lista, con búsqueda
orbit deploy mi-web --pr 31       # un pull request, sin fusionarlo
orbit deploy mi-web --ref 1a2b3c4 # un commit
```

`--pick` te da la punta de la rama, los pull requests abiertos (si tienes GitHub conectado) y los últimos 20 commits.

**No cambia la rama de la app.** Es una prueba, no una mudanza: `orbit deploy mi-web` a secas vuelve a la punta de la rama, y si tienes el autodespliegue puesto el próximo ciclo lo hará solo. Orbit te lo avisa al desplegar.

### Elegir qué script compila y cuál arranca

Cuando corriges la detección —o siempre, en modo EVA— Orbit te enseña los scripts de tu `package.json` con lo que ejecuta cada uno:

```
   Comando de arranque
     1) pnpm start                · lo detectado
     2) pnpm run build            · vite build
     3) pnpm run dev              · vite
     4) pnpm run dev:debug        · NODE_OPTIONS=--inspect vite
     5) ✎ escribir otro comando
```

Es para casos como arrancar en modo depuración. Siempre puedes escribir otra cosa: un proyecto puede arrancar con algo que no esté en `scripts`.

Hace `git fetch`, copia el código a una release nueva, compila, mueve el symlink y reinicia. La versión anterior sigue sirviendo hasta el último momento.

Si el build falla, no pasa nada: la release nueva se borra y producción no se entera.

Si la app arranca pero no responde en 40 segundos, Orbit vuelve solo a la versión anterior y te enseña los logs.

### Cuando el build falla por algo que Orbit sabe arreglar

Hay fallos de build que no son culpa de tu código, que tienen un arreglo de una línea y que hasta ahora te obligaban a entrar por SSH. El más frecuente es este:

```
[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: esbuild@0.28.1
Run "pnpm approve-builds" to pick which dependencies should be allowed to run scripts.
```

Desde pnpm 11, una dependencia con scripts de instalación sin aprobar **hace fallar el install**, no solo avisa. Y sin esos scripts, paquetes como `esbuild` o `sharp` se quedan sin su binario.

Orbit reconoce ese fallo, lo arregla y reintenta:

```
  ✖ Compilando (pnpm install --frozen-lockfile --prod=false && p…)
      [ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: esbuild@0.28.1
  ! pnpm ha bloqueado los scripts de instalación de: esbuild
  · Sin ellos, paquetes como esbuild o sharp se quedan sin su binario.
  ✔ allowBuilds resuelto en esta release

  Para que Orbit no tenga que hacerlo cada vez, añade esto a
  pnpm-workspace.yaml en tu repositorio:

      allowBuilds:
        'esbuild': true

  ✔ Compilando de nuevo (pnpm install --frozen-lockfile --prod…)
  ✔ Recuperado: el arreglo se recuerda para el próximo despliegue
```

Lo que se recuerda va a la configuración de la app (`A_PNPM_ALLOW`), así que **el siguiente despliegue no falla**: el arreglo se aplica antes de compilar y sale a la primera.

Las reglas, que son lo que hace que esto no dé miedo:

- **Un reintento como mucho.** Nunca un bucle. Dos intentos y se acabó.
- **Solo fallos con firma conocida.** Un error de tu código no se reintenta: sería tardar el doble en darte la misma noticia.
- **Todo dentro de la release nueva.** Ni tu repositorio ni la caché de git se tocan, y producción sigue sirviendo la versión anterior mientras tanto.
- **Se explica siempre**, y se te dice qué cambiar en el repositorio para que Orbit no tenga que volver a hacerlo. El objetivo es que esto sobre.
- **Si tú lo has denegado, se respeta.** Un `esbuild: false` en tu `pnpm-workspace.yaml` es una decisión, no un descuido: Orbit no la sobreescribe.

### El lockfile que no cuadra con el package.json

El fallo de despliegue más común, y casi siempre el mismo accidente: un merge de PR donde el conflicto de `pnpm-lock.yaml` se resolvió quedándose con un lado.

Aquí Orbit **resuelve la mitad que no puede tocar producción**, y sólo esa:

- La deriva son sólo dependencias **añadidas** y **todas** están en `devDependencies` → las resuelve, reintenta y sigue. Se instalan para compilar y no llegan al runtime; lo que ya estaba fijado en el lockfile no se mueve.
- Un paquete añadido que está en `dependencies`, un especificador que han subido, o algo que han quitado → aborta, y te dice el nombre y el motivo. Ahí sí se publicaría una versión que no ha decidido nadie.

En una frase: **resuelve solo lo que no llega a producción.**

```
  ✖ Compilando (pnpm install --frozen-lockfile --prod=false && p…)
      [ERR_PNPM_OUTDATED_LOCKFILE] Cannot install with "frozen-lockfile"…
      * 1 dependencies were added: lodash@^4.17.21
  ! El lockfile no coincide con el package.json.
  · No lo resuelvo yo porque esto sí llega a producción:
      · lodash (dependencies)
  · Resolverlo aquí publicaría una versión que no ha decidido nadie.
  · Actualízalo en tu máquina y súbelo:
      pnpm install && git add pnpm-lock.yaml
      git commit -m 'actualiza pnpm-lock.yaml' && git push
```

Dos detalles que conviene saber. **Cuando sí lo resuelve, no se lo apunta**: la deriva es del commit y no de la app, así que el despliegue siguiente vuelve a instalar con el lockfile congelado, como debe ser. Y **sólo funciona con pnpm**, porque npm lista los paquetes que faltan del árbol entero —transitivas incluidas y ya resueltas— y yarn no nombra ninguno: sin saber cuál es la dependencia directa no se puede decidir si llega a producción. Necesita `jq` para leer el `package.json`; sin él se niega en vez de suponerlo.

### Y cuando no lo sabe arreglar, al menos lo explica

Reconoce cuatro situaciones, con pnpm, npm y yarn:

| Lo que ve | Lo que te dice |
|---|---|
| Lockfile desactualizado | El comando exacto para regenerarlo y subirlo |
| Falta el lockfile | Que mires tu `.gitignore`, que es la causa casi siempre |
| Disco lleno | Cómo hacer sitio, antes que cualquier otra cosa: un disco lleno provoca fallos raros más abajo |
| Node incompatible | Qué versión hay en el servidor y dónde mirar en tu `package.json` |

Esto no toca nada ni reintenta: solo te ahorra la búsqueda.

El otro fallo que sabe arreglar es quedarse sin memoria (`JavaScript heap out of memory`): reintenta dándole a Node hasta un 75 % de la memoria libre, y lo recuerda en `A_NODE_HEAP`. Si no hay memoria libre que darle, **no reintenta**: te dice que añadas swap o compiles fuera, porque repetir el intento solo cambiaría el error por una muerte a manos del OOM killer.

Para desactivarlo todo, en `/etc/orbit/orbit.conf`:

```bash
BUILD_RECOVERY="no"
```

Y para olvidar lo aprendido por una app, borra el valor en `/etc/orbit/apps/<app>.conf`. Lo puedes ver con `orbit info <app> --json | jq .app.config.pnpm_allow`.

## Desplegar todas de una vez

```bash
orbit deploy --all                # todas, pase lo que pase
orbit deploy --all --if-changed   # solo las que tengan commits nuevos
```

Cada app se despliega en su propio subproceso, así que un fallo no se lleva por delante el resto de la pasada. Al final tienes el resumen:

```
  ✔ mi-web
  ✖ tienda: el despliegue ha fallado

  1 correctas · 1 fallidas · 3 sin cambios
```

Devuelve un código de salida distinto de cero si alguna falló, para poder encadenarlo en un script.

## Desplegar solo al hacer push

```bash
orbit autodeploy enable mi-web
```

A partir de ahí, cada vez que avance la rama que sigue esa app, se despliega sola en menos de un minuto.

**No hay ningún webhook ni ningún puerto abierto.** Un temporizador de systemd pregunta con `git ls-remote` si la rama ha avanzado; si no, no hace nada. El razonamiento de por qué se sondea en vez de recibir webhooks está en ARCHITECTURE §4.

**Es un permiso por app.** Activarlo en `staging` no despliega `produccion`. Se marca en la configuración de cada app y hay que pedirlo una por una, precisamente para que nadie se encuentre con la web de producción actualizándose sin haberlo decidido.

```bash
orbit autodeploy status      # qué apps y cuándo se desplegaron
orbit autodeploy --once      # comprobar ahora, sin esperar al minuto
orbit autodeploy disable mi-web
```

Cuando ninguna app queda en automático, el temporizador se detiene solo.

### Si un commit rompe el build

Se te avisa una vez y **no se reintenta**. Orbit apunta el commit que falló y espera a que llegue uno nuevo; reintentar el mismo cada minuto llenaría el log y el teléfono sin arreglar nada.

```
  ○ mi-web            main (commit a1b2c3d falló; espero uno nuevo)
```

Producción sigue con la versión anterior, como en cualquier despliegue fallido. Cuando subas el arreglo, se despliega solo.

Si lo que has corregido no está en el código —una variable del `.env`, por ejemplo— pídelo a mano y se intenta igual:

```bash
orbit deploy mi-web
```

### Si Orbit no consigue preguntarle al remoto

Esto es distinto de «no hay commits nuevos», y por eso se dice distinto:

```
  ✖ mi-web: no he podido preguntar al remoto · Repository not found
  ○ mi-web            main (no consigo hablar con el remoto)
```

Pasa cuando el token de GitHub caduca, cuando el repositorio se renombra o se hace privado, o cuando la red falla. Mientras dure, **la app no se está actualizando** aunque su web siga funcionando con la versión vieja.

Recibes un aviso cuando empieza y otro cuando se arregla —uno de cada, no uno cada cinco minutos— y aparece en `orbit autodeploy status` y en `orbit doctor`. Para ver el error completo de git:

```bash
orbit deploy mi-web
```

Si el mensaje es que la rama ya no existe, se arregla cambiándola, no esperando:

```
  ○ mi-web            master (esa rama ya no existe en el remoto)
```

### Cada cuánto se comprueba

Un minuto por defecto:

```bash
orbit autodeploy every 5
```

Con muchas apps en automático puede interesarte subirlo: es una petición de red por app y ciclo.

El intervalo va escrito **dentro** de la unidad de systemd, así que cambiarlo en `/etc/orbit/orbit.conf` a mano no basta. `orbit autodeploy every` reescribe la unidad y reinicia el temporizador; si editas el fichero por tu cuenta, `orbit autodeploy status` te avisa de que la unidad se ha quedado atrás.

**Configura los avisos antes.** Un despliegue automático que falla sin avisar es peor que no tenerlo, porque crees que tu web está actualizada y no lo está. `orbit autodeploy enable` te lo recuerda si no tienes ningún canal.

## Quién visita tu web

```bash
orbit traffic                 # una línea por app, últimas 24 h
orbit traffic mi-web          # el detalle de una
orbit traffic mi-web --since 7d --top 20
```

Sale del log de acceso que nginx ya escribe: **sin cookies, sin JavaScript y sin nada nuevo corriendo**. No hay que añadir un script a la página ni pedirle permiso a nadie, porque no se guarda nada que no estuviera ya en el servidor.

```
  Peticiones       13897  (13526 automáticas, 97%)
  IPs distintas    60
  Transferido      35M
  Errores          4551 (32%)  4xx 213 · 5xx 4338
  Respuesta        mitad ≤ 10 ms · 95% ≤ 25 ms · máx 139 ms

  Por hora  █▂▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  19 h · máx 10830/h
```

### Cómo leerlo sin engañarte

- **Son IPs distintas, no personas.** Sin cookies no hay forma de distinguir dos pestañas de dos visitantes, y llamarlas «visitas» sería inventar precisión.
- **Lo automático va aparte.** En un servidor con IP pública, buena parte del tráfico son escáneres buscando `/.git/config` o `/wp-login`; si se sumaran a las visitas, el número no diría nada. Por eso las rutas y las referencias sólo cuentan lo que no se anuncia como bot.
- **La ventana puede salir recortada, y se avisa.** logrotate se lleva los logs a los 14 días: pedir 30 en un servidor de dos semanas da una respuesta más pequeña que la pregunta, y eso se dice antes de los números.
- **Los tiempos van por tramos** (`≤ 100 ms`). Es lo que se puede afirmar sin ordenar un millón de números en cada consulta.
- **Lo que sirvió Cloudflare no está aquí.** Esto es lo que llegó al servidor.

`orbit traffic --json` lo devuelve entero, con `complete: false` cuando la ventana no se pudo cubrir — un cliente que pinte una gráfica necesita saberlo.

## Colas de Laravel

```bash
orbit queue enable mi-tienda
```

A partir de ahí, un temporizador de systemd vacía la cola cada minuto: cada ciclo ejecuta `php artisan queue:work --stop-when-empty` dentro de la release activa y termina cuando no queda trabajo.

**Lo que se paga es latencia, y conviene decidirlo antes de encenderlo.** Un trabajo encolado puede tardar hasta un ciclo entero en empezar. Para correos, informes, miniaturas o webhooks salientes es irrelevante; para una cola que tiene que responder en segundos, esto no vale y lo que necesitas es un worker residente, que Orbit no monta. El porqué está en ARCHITECTURE §18.9, y en corto es que un worker que no termina nunca se queda con el código de la release anterior después de cada despliegue.

**Es un permiso por app**, como el autodespliegue: se pide una por una y un clon no lo hereda —un staging que vacía la cola manda de verdad los correos que se encuentre dentro—.

```bash
orbit queue status           # qué apps, con qué conexión, y si el timer vive
orbit queue run mi-tienda    # un ciclo ahora, sin esperar al temporizador
orbit queue every 5          # cada cuántos minutos
orbit queue disable mi-tienda
```

Cuando ninguna app queda con cola, el temporizador se detiene solo.

### Lo que hace un ciclo, y lo que no

Cada ciclo corre **como el usuario de la app** y desde la release a la que apunta `current` en ese momento, resuelta una sola vez: si un despliegue mueve el symlink a mitad de ciclo, el worker termina en la release en la que empezó en vez de mezclar dos.

Un ciclo **no se ejecuta** si la app está en mantenimiento —durante un despliegue, o porque alguien la bajó a propósito— ni si el ciclo anterior sigue en marcha. Eso no es un fallo y no aparece como tal.

Y ningún ciclo puede durar más que la ventana del temporizador: el `--max-time` sale del intervalo, y con varias apps el tiempo se reparte entre ellas por orden. La cola que se quede sin tiempo no pierde nada — sus trabajos siguen ahí y la pasada siguiente empieza por ella.

Se procesa **la cola por defecto** de la conexión por defecto. Si tienes colas con nombre (`high`, `emails`) necesitas tu propio temporizador llamando a `orbit exec`.

### Cuando algo va mal

Un ciclo que falla —la base de datos no contesta, falta el `vendor/`— deja `orbit-queue.service` en rojo. Es a propósito: es el único aviso que hay de que los trabajos se están apilando, porque una cola sin procesar no da ningún error, la web sigue contestando 200 y los correos simplemente no salen. Se avisa **una vez** por canal de notificaciones, no una vez por minuto, y `orbit doctor` lo cuenta.

El ciclo siguiente que salga bien lo pone en verde solo.

```bash
journalctl -u orbit-queue -n 30
```

`orbit doctor` también avisa del caso contrario, que se lee peor porque no hay nada rojo en ninguna parte: una app con `QUEUE_CONNECTION=database` y **nadie** que ejecute la cola.

## Página de mantenimiento

```bash
orbit maintenance on mi-web
orbit maintenance on mi-web "Migrando la base de datos, volvemos a las 18:00"
orbit maintenance off mi-web
orbit maintenance status        # qué apps están en mantenimiento y por qué
orbit maintenance edit mi-web   # cambiar la página
```

Mientras está puesto, la web responde **503 con una página de aviso** en vez de servir la aplicación. Sirve para una migración larga, para tocar una base de datos o para cualquier cosa durante la que prefieras que nadie entre a medias.

**No hace falta recargar nginx.** El interruptor es un fichero, `shared/maintenance.on`, y nginx comprueba si existe en cada petición. Encenderlo es instantáneo, no puede dejar la configuración rota y funciona igual si lo haces a mano:

```bash
touch /srv/apps/mi-web/shared/maintenance.on    # encender
rm /srv/apps/mi-web/shared/maintenance.on       # apagar
```

### Por qué 503 y no una página normal

Un 503 con `Retry-After` es la señal correcta para los buscadores: significa «vuelve luego», no «esta página ya no existe». Servir un 200 con un cartel de «estamos de obras» le dice a Google que ese es el contenido definitivo de tu web, y eso sí hace daño.

### El motivo

El texto que pases se muestra en la página, y se guarda aparte de ella:

```
/srv/apps/mi-web/shared/maintenance.html    la página   (tuya, no se toca)
/srv/apps/mi-web/shared/maintenance.reason  el motivo   (una línea)
```

Así puedes cambiar el mensaje sin tocar la maqueta, y rediseñar la página sin perder el mensaje. Cambiarlo es instantáneo, como encenderlo:

```bash
orbit maintenance on mi-web "Ampliando el disco, unos 20 minutos"
```

Si no pasas ninguno, el párrafo queda vacío y no se muestra. Al quitar el mantenimiento el motivo se borra, para que el de hoy no reaparezca la semana que viene.

El texto se escapa antes de meterlo en la página, así que un `<` o un `&` no rompen la maqueta.

Si tu página viene de una versión anterior de Orbit no tiene el hueco donde va el motivo. Orbit te avisa y te dice qué línea añadir:

```html
<p class="motivo"><!--# include file="maintenance.reason" --></p>
```

### La página es tuya

Está en `/srv/apps/mi-web/shared/maintenance.html`, sobrevive a los despliegues y puedes editarla. Orbit escribe una por defecto la primera vez y **no la vuelve a tocar**.

No lleva recursos externos a propósito: si lo que está caído es justo la aplicación que servía los estilos, una página que depende de ella no se vería.

### Durante los despliegues, sola

En las apps con proceso (Node, Python), `orbit deploy` la enciende justo antes de reiniciar y la apaga en cuanto la app responde. Ese hueco de uno o dos segundos, en el que antes se veía un **502 Bad Gateway**, ahora es la página de aviso.

Si prefieres que no lo haga, en `/etc/orbit/apps/mi-web.conf`:

```bash
A_MAINT_AUTO='no'
```

Si ya lo habías puesto tú a mano, el despliegue **no te lo quita** al terminar.

Un despliegue que muriera a mitad no puede dejar la web en mantenimiento para siempre: el testigo se retira pase lo que pase. Y por si acaso, `orbit watch` avisa si una app lleva más de 30 minutos en mantenimiento, que casi siempre significa que alguien se olvidó.

### Lo que sigue funcionando

`/.well-known/acme-challenge/` **no** se pone en mantenimiento, para que certbot pueda renovar los certificados aunque la web esté cerrada. Es la razón por la que la condición vive dentro de `location /` y no a nivel de servidor: a nivel de servidor se evalúa antes de elegir el `location` y también devolvería 503 a la validación, con lo que la renovación fallaría en silencio.

## Una web estática con PHP dentro

El caso típico: un sitio de Astro, Vite o Eleventy con un `contacto.php` que procesa el formulario. Orbit lo detecta solo al crear la app:

```
  Detección automática
    Tipo        static
    Build       pnpm build
    Carpeta web dist
    PHP         sí (los .php se pasan a php-fpm)
```

El tipo sigue siendo `static` —el 99 % del sitio son ficheros— y lo que se añade es una capacidad: nginx sirve todo desde disco **menos** los `.php`, que van a php-fpm. No hace falta configurar nada.

**Dónde tiene que estar el fichero.** Se detecta mirando el repositorio, pero se sirve desde la carpeta compilada. En Astro y en Vite, lo que pones en `public/` se copia tal cual a `dist/`; lo que está en `src/` lo procesa el build y no llega. Si Orbit no encuentra ningún `.php` en la carpeta publicada te lo dice al desplegar:

```
  ! Esta app ejecuta PHP pero no hay ningún .php en /srv/apps/mi-web/current/dist
  ·   El build no lo ha copiado a la carpeta de salida. En Astro y Vite,
  ·   los ficheros de public/ sí se copian tal cual: prueba a moverlo ahí.
```

**Y si tus endpoints viven fuera de la carpeta compilada, no hace falta moverlos.** Es el caso típico: un Astro con una carpeta `api/` en la raíz del repositorio. `astro build` sólo copia `public/` a `dist/`, así que `api/` se queda fuera y nginx, que sirve `dist/`, devolvería 404 en todos los endpoints con la web viéndose perfecta.

Orbit las sirve desde donde están: cualquier carpeta de primer nivel con `.php` dentro que no esté en la carpeta compilada recibe su propio bloque, y `/api/contact.php` funciona sin tocar el proyecto. No hay que subir nada aparte ni duplicar el `rsync`.

Se puede forzar en los dos sentidos, por si tienes un `.php` en el repo que no quieres que se ejecute:

```bash
orbit new … --php yes      # actívalo aunque no lo detecte
orbit new … --php no       # no lo actives aunque lo detecte
```

O declararlo en el `orbit.json` del repo, junto al resto:

```json
{ "type": "static", "outdir": "dist", "php": true }
```

Para una app que ya existe, cambia `A_PHP` en `/etc/orbit/apps/<app>.conf` y ejecuta `orbit nginx-rebuild`.

**Si tu app NO ejecuta PHP**, un `.php` que se cuele en la carpeta publicada devuelve 404. No es una limitación: servirlo entregaría el código fuente, porque nginx no tiene `php` en `mime.types` y el navegador se lo descarga como fichero, con lo que lleve dentro.

### Las subidas no se ejecutan

Si tu app PHP guarda lo que suben los usuarios en una carpeta bajo el docroot —`storage/` de Laravel, `uploads/`, `media/`— Orbit **desactiva ahí la ejecución de código**. Un `.php` subido por un visitante devuelve 404 en vez de ejecutarse.

Las carpetas protegidas son las que Orbit sabe que son escribibles (cualquier enlace del docroot que acabe en `shared/`, y `storage` siempre) más los nombres de siempre: `uploads`, `upload`, `files`, `media`.

Los ficheros normales se sirven igual: una foto en `/storage/foto.jpg` sigue llegando. Lo único que deja de funcionar es ejecutar código desde ahí, que no es un caso de uso — es la forma habitual de que se cuelen en un servidor.

Si tu aplicación necesita ejecutar un `.php` que vive en una de esas rutas, muévelo: cualquier fichero que forme parte de tu código tiene que venir del repositorio, no de una carpeta de subidas.

## Dominios y subdominios

Al crear una app se propone `www.<tu-dominio>` como dominio extra **solo si es un dominio de los que se compran**:

```
midominio.com          → propone www.midominio.com
midominio.co.uk        → propone www.midominio.co.uk
blog.midominio.com     → no propone nada
```

A un subdominio no se le pone `www` porque nadie escribe `www.blog.midominio.com` y, sobre todo, porque ese nombre no está en tu DNS: Let's Encrypt valida **todos** los nombres del certificado o no emite ninguno, así que un alias fantasma puede dejar sin HTTPS un dominio que funcionaba.

Si tu caso no encaja en la regla, lo dices tú y ya está:

```bash
orbit new … --aliases "www.midominio.com tienda.midominio.com"
orbit new … --aliases ""      # ninguno
```

## Frameworks que necesitan un detalle

La mayoría se detectan y ya está. Estos cuatro tienen una particularidad que conviene conocer.

### SvelteKit

Lo que decide cómo se despliega **no es SvelteKit, es el adaptador**:

| Adaptador | Orbit lo trata como |
|---|---|
| `@sveltejs/adapter-node` | proceso, arrancado con `node build` |
| `@sveltejs/adapter-static` | sitio estático servido desde `build/` |
| `@sveltejs/adapter-auto` | proceso, **y no va a compilar** |

`adapter-auto` es el que trae el proyecto recién creado y solo funciona en Vercel, Netlify y similares. En tu propio servidor el build falla, y Orbit te dice cuál instalar:

```bash
pnpm add -D @sveltejs/adapter-node      # si tienes rutas de servidor
pnpm add -D @sveltejs/adapter-static    # si es todo prerenderizable
```

Cambia el import del adaptador —hoy vive en `vite.config.ts`, antes en `svelte.config.js`— y vuelve a desplegar: Orbit detecta el tipo nuevo solo.

### Remix y React Router

`create-remix` te manda hoy a `create-react-router`: Remix v2 se fusionó con React Router v7. Orbit reconoce los dos, y usa tu script `start` si lo tienes.

Con `ssr: false` en `react-router.config.ts` tu proyecto es una SPA y se sirve como estático desde `build/client`. Ojo: `react-router` a secas —la librería de rutas de cualquier SPA de React— no cuenta como framework de servidor, y eso es lo correcto.

### Angular

La carpeta de salida lleva dentro **el nombre del proyecto**, que Orbit lee de tu `angular.json` y que no tiene por qué ser el del repositorio:

```
dist/mi-proyecto/browser/     ← lo que sirve nginx
dist/mi-proyecto/server/      ← con @angular/ssr, lo que arranca systemd
```

Si instalas `@angular/ssr`, Orbit pasa a tratarlo como proceso automáticamente.

### Go

Se detecta por `go.mod` **y** por tener algún paquete `main` — las dos cosas, porque un sitio de Hugo con Hugo Modules también trae `go.mod`.

```
A_BUILD   go build -trimpath -o bin/app .
A_START   ./bin/app
```

Con varios binarios en `cmd/`, Orbit elige el que parece el servidor (`cmd/server`, `cmd/api`, `cmd/web`…) y te dice cuál ha elegido. Si no es ése:

```bash
orbit new --build 'go build -trimpath -o bin/app ./cmd/loquesea'
```

**Tu app tiene que leer `PORT`.** Orbit exporta `PORT` y `HOST=127.0.0.1` y espera que el servidor escuche ahí. En Python Orbit genera el servidor y controla dónde escucha; en Go el servidor es tu código. Si detecta que no nombras `PORT`, te avisa al crear la app. Si tu servidor recibe la dirección por un flag, pásasela tú:

```bash
orbit new --start './bin/app --addr 127.0.0.1:$PORT'
```

**Go no lo instala Orbit.** Son unos 290 MB de toolchain que sólo hace falta para compilar —el binario desplegado no lo usa— y que la mayoría de servidores no necesita. Se instala así, y `orbit doctor` lo comprueba si alguna app tuya lo usa:

```bash
curl -fsSL https://go.dev/dl/go1.24.7.linux-amd64.tar.gz | sudo tar -C /usr/local -xz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
```

El paquete de Ubuntu (`golang-go`) va por Go 1.22, fuera de soporte: con él, cualquier repo cuyo `go.mod` pida una versión más nueva se descarga un toolchain de 214 MB en el primer despliegue.

La caché de módulos vive en `/home/deploy`, fuera de las releases y compartida entre apps: el primer build tarda, los siguientes no. Si te quedas sin disco, `go clean -modcache` libera bastante.

### Laravel

Se detecta por tres cosas a la vez: `artisan` en la raíz, `laravel/framework` entre los `require` del `composer.json` y `bootstrap/app.php`. Las tres, porque Lumen también trae `artisan` y cualquier paquete que se pruebe contra Laravel declara `laravel/framework` en `require-dev`.

```
A_TYPE     laravel
A_DOCROOT  public                (fijo)
A_BUILD    composer install --no-dev --optimize-autoloader --no-interaction
           (+ el install y el build de tus assets si hay package.json)
A_MIGRATE  php artisan migrate --force
```

No hay proceso ni puerto: la sirve php-fpm, como cualquier app PHP.

**Lo que hace el despliegue por ti**, después del build y con el entorno limpio:

- **Siembra `shared/storage`** con el esqueleto que trae tu repo la primera vez, y lo enlaza. Ahí viven los logs, las sesiones y las subidas de tus usuarios, y por eso está fuera de la release: sobrevive a los despliegues y al rollback.
- **Genera `APP_KEY`** si falta, una sola vez. No se regenera nunca: hacerlo invalidaría todas las sesiones y todo lo que la app haya cifrado.
- **`php artisan storage:link --force`**, en cada despliegue, porque el enlace que crea lleva dentro el nombre de la release.
- **`config:cache` y `route:cache`**. `view:cache` no, a propósito: escribe en `storage/`, que es compartido, y borraría las vistas compiladas de la release anterior.

**Un cambio en el `.env` no se nota hasta el siguiente despliegue.** Con `config:cache`, Laravel deja de leer el `.env`: lo lee de `bootstrap/cache/config.php`, que es de esa release. Orbit te lo recuerda al hacer `orbit env set`. Vuelve a desplegar y ya está:

```bash
orbit env set mi-app DB_PASSWORD 'otra'
orbit deploy mi-app
```

**Migraciones, nunca solas.** Al terminar un despliegue Orbit mira si quedan pendientes y te avisa. Para aplicarlas:

```bash
orbit migrate mi-app        # enseña el SQL exacto y pregunta antes
```

**Las colas no se ejecutan solas.** Orbit no levanta workers. Si tu `.env` dice algo distinto de `sync`, te lo dice al desplegar, porque una cola que nadie ejecuta no da ningún error: los trabajos se apilan y la web sigue respondiendo 200 mientras los correos no salen. Mientras tanto:

```bash
orbit exec mi-app 'php artisan queue:work --stop-when-empty'
```

**Cuidado con la versión de PHP.** El servidor sirve las páginas con la que diga `PHP_VER` (por defecto 8.3, que es la de Ubuntu 24.04), y un Laravel reciente puede pedir 8.4. Si el `php` con el que compila el build y el del pool no son el mismo, el build sale en verde y la web devuelve 500 con «Composer detected issues in your platform». Orbit te avisa si no coinciden.

**Si tu ruta acaba en `.yaml`, `.sql` o `.log` y da 403**, no es Laravel: es el snippet de seguridad de nginx, que deniega esas extensiones para todas las apps. Es la única arista conocida de servir Laravel con Orbit.

**El despliegue comprueba que la web responde, y vuelve atrás si no.** Después de activar la release, Orbit recarga php-fpm —sin esa recarga php-fpm seguiría sirviendo la versión anterior durante hasta dos minutos— y le pide la portada a nginx como haría un visitante. Si contesta un 5xx, devuelve el symlink a la release anterior y te lo dice. Un 404 no cuenta como fallo: una API sin ruta raíz es perfectamente válida. Y si la app está en mantenimiento —el de Orbit o un `php artisan down`— la comprobación se salta, para que puedas desplegar el arreglo de una web que está caída a propósito.

Esto vale igual para una app **PHP** a secas y para una **web estática con `.php` dentro**. Con una diferencia que conviene saber: en Laravel y en PHP la portada la ejecuta php-fpm, así que un error de sintaxis o una extensión que falte se detectan; en una estática la portada la sirve nginx desde disco, así que ahí la comprobación dice que tu sitio sigue en pie, no que tu formulario de contacto funcione. Una estática sin PHP no pasa por nada de esto.

**Si el despliegue aborta con «Laravel no ha podido cachear su configuración»**, es que Laravel no arranca: suele faltar el `vendor/`, o `php` no está en el `PATH` del usuario de despliegue, o un proveedor revienta al iniciarse. Se comprueba antes de mover el symlink a propósito, porque una app Laravel no tiene health check ni rollback automático: si se publicara, la web se quedaría en 500 y nadie la devolvería sola. Míralo con `orbit exec <app> 'php artisan config:cache'`.

**Un CMS sobre Laravel (Statamic, October, Winter) se detecta pero no encaja.** Se administran desde su propio panel y escriben dentro del repositorio; cada despliegue rehace la carpeta y se lleva lo que hayas instalado desde allí. Orbit te lo dice y te deja decidir.

### Deno

Se detecta por `deno.lock`, por un `deno.json` que declare `tasks`, `imports`, `importMap` o `workspace`, o —si no hay ninguno de los dos, que pasa cuando importas por URL o `jsr:` a pelo— por un fichero de entrada que use la API de `Deno.`. Un `deno.json` que sólo configura `deno fmt` en un proyecto de Node no cuenta, y un framework de JavaScript en el `package.json` manda por encima de todo: un Next instalado con `deno install` sigue siendo Next.

```
A_BUILD   deno install --frozen && deno check main.ts     (--frozen sólo si hay deno.lock)
A_START   deno run --cached-only --allow-net --allow-env --allow-read=. main.ts
```

Si tu repo declara una tarea `build`, se ejecuta con `deno task build` entre el install y el `check`.

**Qué fichero y cómo se arranca.** El fichero sale de tu tarea `start` (o `serve`, o `dev`) si la declaras, y sólo si no la hay se buscan los nombres de siempre (`main.ts`, `mod.ts`, `server.ts`…). Y si ese fichero **exporta un `default`** —lo que espera `deno serve`— Orbit arranca con `deno serve --port $PORT --host 127.0.0.1`, porque `deno serve` no lee `PORT` del entorno y sin `--host` escucha en `0.0.0.0`. Si no lo exporta, arranca con `deno run` y el puerto lo lee tu código de `PORT`.

Orbit **no** usa `deno task` para arrancar, aunque tu repo lo tenga: a una tarea no se le puede cambiar el puerto (los argumentos entran detrás del fichero y `deno serve` los ignora), y el puerto lo asigna Orbit.

**Los permisos son tuyos.** Orbit pone el mínimo con el que funciona una web normal y lo deja escrito en `A_START` para que lo edites:

```bash
orbit env set miapp --start 'deno run --cached-only --allow-net --allow-env --allow-read=. --allow-write=./tmp main.ts'
```

Si tu `deno.json` declara `permissions`, Orbit no se los pisa: arranca con `-P` y manda tu fichero.

**La caché no está en el repo.** Deno no crea `node_modules`: se lo baja todo a `DENO_DIR`, que Orbit fija en `shared/deno` para que el build y el servicio miren al mismo sitio. No la borres entre despliegues; si te quedas sin disco, `deno clean` la vacía y el siguiente despliegue la rehace.

**Deno no lo instala Orbit.** `curl -fsSL https://deno.land/install.sh | sh`, y **copia el binario a `/usr/local/bin`** — si se queda en el `HOME` de root, funciona para ti y falla en todos los despliegues. `orbit doctor` lo comprueba preguntando como el usuario de despliegue, precisamente por eso.

### Bun

Bun puede ser dos cosas distintas, y Orbit las distingue:

- **Gestor de paquetes** de un proyecto que sigue siendo de Node: basta con que haya `bun.lock`. Cambia el `install` a `bun install --frozen-lockfile` y nada más; un Next instalado con bun sigue siendo un Next.
- **Runtime**: cuando ningún framework coincide y el repo dice que arranca con bun (`"start": "bun run …"`), o trae `bunfig.toml` o `@types/bun` con un `Bun.serve` dentro. No hace falta que el `bun.lock` esté commiteado, y un servidor de Bun sin `package.json` también vale.

```
A_BUILD   bun install --frozen-lockfile
A_START   bun run start        (o 'bun run index.ts' si no hay script)
```

Hono corre en Node y en Bun con el mismo `package.json`: quien decide es tu `"start"`.

**Bun no lo instala Orbit.** `curl -fsSL https://bun.sh/install | bash`, y la misma advertencia que con Deno: el binario tiene que quedar donde lo vea el usuario de despliegue, no en el `HOME` de root.

### Hugo

Se detecta por `hugo.toml` (o por `config.toml` junto a `content/` y `layouts/`), compila con `hugo --minify` y sirve `public/`. Si tu sitio lleva un `package.json` para Tailwind, sus dependencias se instalan antes de compilar.

**Hugo no lo instala Orbit.** Es un binario que la mayoría de servidores no necesita, así que instálalo tú:

```bash
sudo apt-get install -y hugo
```

La versión de Ubuntu va por detrás; si tu tema pide una más nueva, baja el binario de [github.com/gohugoio/hugo/releases](https://github.com/gohugoio/hugo/releases) a `/usr/local/bin`. `orbit doctor` te avisa si falta y alguna app lo necesita.

## Monorepos

Si tu repo es un workspace —`apps/web`, `packages/api`— Orbit busca solo el paquete que declara el framework y lo enseña al darte de alta:

```
    Tipo        next
    Subcarpeta  apps/web  (monorepo)
```

El `install` y el `build` se siguen lanzando desde la raíz, que es lo correcto en un workspace; lo que cambia es el arranque (`pnpm --dir apps/web run start`) y las rutas donde nginx busca los ficheros.

Si prefieres no dejarlo a la inferencia, pon un `orbit.json` en la raíz del repo:

```json
{
  "type": "node",
  "appdir": "apps/web",
  "start": "node apps/web/run.js"
}
```

Campos admitidos: `type`, `appdir`, `build`, `start`, `outdir`, `spa`, `docroot`, `php`, `shared` y `env`. Con `type` presente, Orbit no infiere nada. Viaja con tu código, así que se revisa en el mismo PR que lo cambia.

### `shared`: lo que tu app escribe y no puede vivir en una release

Cada despliegue **rehace la release entera**. Todo lo que tu aplicación escriba dentro de ella —credenciales que pusiste a mano, ficheros subidos, estadísticas, logs— desaparece en el siguiente despliegue. Es la diferencia con un hosting clásico, donde el directorio es el mismo para siempre, y no se nota hasta que buscas un dato y no está.

Decláralo y ya está:

```json
{
  "type": "static",
  "outdir": "dist",
  "php": true,
  "shared": ["api/config.local.php", "api/undelivered", "api/telemetry-data", "api/logs"]
}
```

Cada entrada se crea en `shared/` la primera vez y se enlaza en cada release, así que tu código las sigue viendo donde siempre (`__DIR__ . '/undelivered'` funciona igual). Si el repositorio trae algo en esa ruta —un fichero de ejemplo, una carpeta con su `.gitignore`— se usa de **semilla** la primera vez y no se vuelve a pisar: lo que edites en producción se queda.

Vale para ficheros y para carpetas, y las rutas son relativas a la raíz del repo. Una ruta que se salga de ahí se descarta y se dice cuál.

**Y de propina, dejan de servirse.** Lo que apunta a `shared/` es dato en tiempo de ejecución, así que Orbit lo niega en nginx: un `.eml` con un currículum dentro de `api/undelivered/` devuelve 404 en vez de descargarse. No hace falta escribir ninguna regla.

### `env`: las variables que tu app necesita, sin pasos manuales

Casi todo despliegue tiene un apartado en su documentación que dice «entra por SSH, copia el fichero de ejemplo, genera un token, pégalo». Son tres pasos a mano, y el primero no necesitaba a nadie: un token aleatorio lo genera mejor el ordenador.

Declara qué variables hacen falta y de dónde salen:

```json
{
  "type": "static",
  "outdir": "dist",
  "php": true,
  "shared": ["api/.env", "api/undelivered"],
  "env": {
    "file": "api/.env",
    "vars": {
      "IV_STATS_TOKEN": { "generate": "hex:24", "desc": "Token del panel de estadísticas" },
      "IV_SMTP_USER":   { "prompt": "Cuenta SMTP" },
      "IV_SMTP_PASS":   { "prompt": "Contraseña de aplicación", "secret": true }
    }
  }
}
```

En el despliegue, para cada variable **que aún no tenga valor**:

| Declaración | Qué hace Orbit |
|---|---|
| `"generate": "hex:24"` | La genera y sigue. No pregunta nada. También `base64:N` y `uuid`. |
| `"prompt": "…"` | Pregunta una vez. Con `"secret": true` no se ve al teclearla. |

**Nunca se pisa un valor que ya exista.** Un redespliegue no puede cambiarle la contraseña a nadie, y un valor que hayas puesto tú a mano con `orbit env set` manda sobre cualquier generación posterior. Basta con que la clave **exista**, aunque esté vacía: `orbit env set app CLAVE ''` es la forma de desactivar algo opcional, y volver a generársela en cada despliegue sería deshacer una decisión tuya.

**El bloque se relee en cada despliegue**, de la release recién sacada. Añadir una variable al `orbit.json` basta; no hay que recrear la app.

`orbit env get/set/list/edit` operan sobre ese mismo fichero, no sobre otro.

Y si no hay nadie al teclado —`--yes`, autodeploy, CI—, las que había que preguntar no bloquean el despliegue: se avisa de cuáles faltan con el comando exacto para ponerlas después.

```
✓ 1 variable(s) generada(s) en api/.env
⚠ Faltan por definir: IV_SMTP_USER IV_SMTP_PASS
  orbit env set mi-web IV_SMTP_USER '<valor>'
  orbit env set mi-web IV_SMTP_PASS '<valor>'
```

`file` es opcional y por defecto vale `.env` en la raíz de `shared/`. Se apunta a otro sitio cuando la app espera leerlo ella misma: en el ejemplo, `api/.env` está también en `shared`, así que se enlaza dentro de la release y el PHP lo encuentra al lado de su código. Eso es a propósito y no un rodeo: nginx no pasa las variables de `shared/.env` a PHP por FastCGI, y hacer que las pasara metería la contraseña dentro de la configuración de nginx —más legible que un `.env` con permisos `0640`—.

El fichero se crea con `0640` y propiedad del usuario de despliegue, y como está bajo `shared/`, nginx ya lo niega.

Y no se escribe a través de enlaces simbólicos. `shared/` es del usuario de despliegue a propósito —la app escribe ahí—, así que una app comprometida podría cambiar su `.env` por un enlace a un fichero del sistema; la provisión corre como root, de modo que seguirlo reescribiría ese fichero y le cambiaría el dueño. Se comprueba el fichero y cada directorio del camino, y si hay un enlace se avisa y no se toca nada.

## Montar un staging a partir de una app que ya funciona

```bash
orbit clone mi-web staging --domain staging.midominio.com
```

Duplica la configuración de `mi-web` en una app nueva: mismo repo, misma rama, mismo build, mismo comando de arranque. Puerto interno nuevo, dominio nuevo.

**Lo que no se copia, a propósito:**

| | Por qué |
|---|---|
| los **valores** del `.env` | un `DATABASE_URL` heredado haría que el staging escribiese en la base de datos de producción |
| el certificado HTTPS | es de otro dominio; emítelo con `orbit ssl staging` |
| los dominios extra | los alias son del original |
| el despliegue automático | es un permiso, y activarlo en producción no debe activarlo en la copia |
| las releases | el build se hizo con el entorno del original |

Del `.env` sí se copian los **nombres** de las variables, con el valor vacío, junto con los comentarios. Así ves de un vistazo qué falta por rellenar:

```bash
orbit env staging          # o uno a uno: orbit env set staging DATABASE_URL '...'
```

Si sabes lo que haces y quieres los valores tal cual, `--with-env`. Orbit te avisa de lo que eso significa.

### La copia nace en mantenimiento

Todavía no tiene código desplegado, así que su dominio responde **503 con la página de aviso** en vez de un 502. La secuencia completa:

```bash
orbit clone mi-web staging --domain staging.midominio.com
orbit env staging                    # rellenar los valores
orbit db create staging              # si usa base de datos
orbit deploy staging
orbit maintenance off staging
orbit ssl staging
```

El certificado se puede emitir antes del despliegue: la validación de Let's Encrypt pasa por delante de la página de mantenimiento.

### Otras opciones

```bash
orbit clone mi-web pruebas --domain pruebas.midominio.com --branch develop
```

`--branch` clona apuntando a otra rama, que suele ser justo lo que quieres en un staging. Sin `--domain` ni nombre, Orbit los pregunta y propone `staging-mi-web` y `staging.midominio.com`.

## Ver el estado

```bash
orbit list
```

```
APP              TIPO     DOMINIO                        PUERTO  ESTADO    SSL
criticabits      next     criticabits.com                3001    activo    sí
estropealo       static   estropealo.com                 -       estatico  sí
brokenufo        static   brokenufo.com                  -       estatico  no
```

Para el detalle de una:

```bash
orbit info mi-web
```

Repositorio, rama, dominios, comandos, puerto interno, ruta, último despliegue y número de releases guardadas.

## El panel en vivo

```bash
orbit top
```

```
  ORBIT top  vps · 3 apps · 18:42:07
────────────────────────────────────────────────────────────────────────────────
  APP              TIPO    ESTADO         CPU     MEM   REQ/min DOMINIO
────────────────────────────────────────────────────────────────────────────────
  criticabits      next    activo        2,4%    184M        37 criticabits.com
  estropealo       static  —                ·       ·        12 estropealo.com
  brokenufo        next    manten.       0,0%     92M         0 brokenufo.com
────────────────────────────────────────────────────────────────────────────────
  carga 0.31 0.22 0.18 · memoria 2,1Gi/12Gi · disco 41%
  refresco 2s · q salir · r refrescar ya
```

Se refresca cada dos segundos. `q` sale, `r` refresca al momento sin esperar. Al salir, el terminal queda como estaba: el panel no se queda pegado en el historial.

- **`orbit top --once`** pinta un solo fotograma y termina. Es lo que sale también si rediriges la salida a un fichero, porque un panel que se refresca dentro de una tubería solo sirve para llenar el disco.
- **`orbit top --interval=5`** cambia cada cuántos segundos se refresca. Por defecto son 2, o lo que digas en `TOP_INTERVAL` dentro de `orbit.conf`.

Qué significa cada columna:

| Columna | De dónde sale | Cuándo pone `·` |
|---|---|---|
| CPU | Diferencia entre dos lecturas de `CPUUsageNSec` del cgroup | En la primera lectura, o si la unidad no lleva contabilidad de CPU |
| MEM | `MemoryCurrent` del cgroup de la unidad | Si la app no tiene servicio (estáticas y PHP) |
| REQ/min | Líneas del último minuto en el log de acceso de nginx | Si el log aún no lleva la fecha (ver `orbit logs --since`) |

El estado `—` de las estáticas no es un error: es que no hay ningún proceso que arrancar, y eso no es lo mismo que estar parada.

**Por qué la CPU puede pasar del 100 %.** Es porcentaje de un núcleo, como en `top`. Una app que ocupa dos núcleos enteros marca 200 %.

**El número de peticiones tiene un tope.** Se leen las últimas 5000 líneas del log, no el fichero entero, porque esto se refresca cada dos segundos y el log de una web con tráfico son cientos de megas. Si un minuto llena ese tope, el número sale con un `+` detrás (`5000+`) para que no lo leas como tráfico exacto. Se cambia con `TOP_LOG_LINES` en `orbit.conf`.

## Logs

```bash
orbit logs mi-web
```

Para apps de Node y Python muestra el journal del servicio. Para webs estáticas, los logs de acceso y error de nginx. Sal con `Ctrl+C`.

### Una ventana de tiempo concreta

```bash
orbit logs mi-web --since 2h        # las últimas dos horas
orbit logs mi-web --since 30m
orbit logs mi-web --since hoy
orbit logs mi-web --since ayer
orbit logs mi-web --since '10:00'   # desde las diez de hoy
orbit logs mi-web --since 2026-08-01
```

Con `--since` no se sigue en vivo: has pedido un tramo, se enseña y se acaba. Si además quieres seguir mirando, añade `-f`.

Funciona igual con el journal y con los logs de nginx, aunque por debajo son cosas distintas: al journal se le pasa la fecha y los de nginx se filtran por su marca de tiempo.

### Otras opciones

```bash
orbit logs mi-web --lines 500       # 80 por defecto
orbit logs mi-web --nginx           # los de nginx aunque la app tenga proceso
```

`--nginx` es el que quieres cuando la web da **502**: ese error lo escribe nginx, y en el journal de la aplicación no aparece.

### Para un programa: `--json`

```bash
orbit logs mi-web --json --since 1h
orbit logs mi-web --json --follow          # el flujo, si lo quieres en vivo
```

Aquí `--json` **no** da un objeto: da **NDJSON**, una línea de JSON por línea de
log. Es la única excepción del contrato y está así a propósito — un log con
`--follow` no termina nunca, así que no hay un momento en el que se pueda cerrar
un objeto, y una ventana de siete días serían cientos de megas en memoria antes
de imprimir el primer byte.

Para que no haya que adivinarlo, **la primera línea siempre es un `meta`** que
lleva el `schema` y dice qué viene detrás:

```
{"schema":1,"event":"meta","app":"mi-web","source":"nginx","unit":null,"since":null,"follow":false,"lines":80}
{"event":"line","ts":"2026-08-29T14:02:11+02:00","stream":"access","text":"…"}
{"event":"line","ts":"2026-08-29T14:03:01","stream":"error","text":"…"}
{"event":"end","lines":2,"truncated":false}
```

Cuatro cosas que conviene saber:

- **`stream` dice de qué log viene cada línea** — `journal`, `access` o `error`.
  La salida normal no lo distingue, porque `tail` mezcla los dos ficheros de
  nginx sin decir cuál es cuál.
- **`ts` sale del propio log y no se inventa.** El de acceso lleva huso y sale
  con él; el de error no lo lleva y sale sin él, que quiere decir «hora local
  del servidor». Un log del formato viejo, sin marca, da `"ts": null` — y ése es
  el momento de pasarle `orbit nginx-rebuild`.
- **`truncated` avisa de que se llegó al tope de `--lines`**, y el tope es por
  fuente, igual que `tail -n N fichero1 fichero2` da N de cada uno.
- **Con `--json` no se sigue en vivo por defecto**, como en `orbit top`: en modo
  máquina, una foto. Con `--follow` sí, y entonces **no hay `end`**: un flujo que
  no termina no tiene final que anunciar.

```bash
# Sólo los errores de nginx de la última hora
orbit logs mi-web --json --since 1h | jq -r 'select(.stream=="error") | .text'

# ¿Me he dejado líneas fuera?
orbit logs mi-web --json | jq -r 'select(.event=="end") | .truncated'
```

### Si `--since` te dice que el log no lleva fecha

Los servidores instalados antes de agosto de 2026 tienen un formato de log sin marca de tiempo, y sin ella no hay nada que filtrar. Se arregla una vez:

```bash
orbit nginx-rebuild
```

Las líneas que ya estaban escritas siguen sin fecha —no se pueden inventar—, pero las nuevas sí la llevan.

### Directamente, si prefieres

```bash
journalctl -u orbit-mi-web -f
tail -f /var/log/nginx/mi-web.access.log
```

## Volver atrás

```bash
orbit rollback mi-web
```

Te muestra las últimas releases y vuelves a la que elijas al instante. Se conservan las 5 últimas.

## Variables de entorno

```bash
orbit env mi-web                      # abrir el .env en el editor
orbit env list mi-web                 # qué claves hay
orbit env get mi-web DATABASE_URL     # ver una
orbit env set mi-web API_KEY sk_live  # añadir o cambiar
orbit env unset mi-web API_KEY        # quitar
```

El fichero es `/srv/apps/mi-web/shared/.env`: sobrevive a los despliegues y se enlaza dentro de cada release.

### Desde un script

`get` imprime **solo el valor**, sin adornos, y devuelve un código distinto de cero si la clave no existe. Así se distingue «vacía» de «no está»:

```bash
CLAVE="$(orbit env get mi-web API_KEY)" || echo "no está configurada"
orbit env set otra-app API_KEY "$CLAVE"
```

`list` muestra **solo los nombres**. Los valores son secretos y están a un `orbit env get` de distancia; así no acaban en el historial del shell ni en una captura de pantalla por escribir un comando de listado.

### Los cambios no reinician nada por defecto

Un script que configura cinco variables no debería reiniciar la app cinco veces. Orbit te lo recuerda al terminar, y `--restart` lo hace cuando quieres:

```bash
orbit env set mi-web API_KEY sk_live --restart
```

### Cómo se guardan los valores, y qué no se acepta

Se escriben **entre comillas simples**. No es un capricho: el `.env` lo leen dos programas distintos, bash con `source` (el build y `orbit exec`) y systemd como `EnvironmentFile`. Con comillas dobles, bash expande lo que haya dentro:

```
PASSWORD="p$assw0rd"     →  la app recibe  p
PASSWORD='p$assw0rd'     →  la app recibe  p$assw0rd
```

Es el mismo fallo que ya costó un bug con los comandos de arranque, y por eso `orbit env set` usa el mismo entrecomillado seguro que la configuración de las apps.

La contrapartida: **un valor con una comilla simple dentro se rechaza**. bash la escapa como `'\''` y systemd no entiende ese escape, de modo que el mismo valor se leería distinto según lo lance el servicio o `orbit exec`. Antes que guardar algo que se comporta de dos maneras, Orbit te lo dice y te manda al editor.

Los valores que ya tengas escritos con comillas dobles, sin comillas o con `export` delante se siguen leyendo sin tocar nada.

## Arrancar, parar, reiniciar

```bash
orbit restart mi-web
orbit stop mi-web
orbit start mi-web
```

Solo aplica a apps de Node y Python. Las webs estáticas no tienen proceso: para actualizarlas se usa `orbit deploy`.

## Vigilancia

```bash
orbit notify setup     # Telegram, Discord o webhook
orbit watch enable     # comprobar cada minuto
```

A partir de ahí te enteras tú antes que tus clientes.

**No hay ningún demonio.** `orbit watch enable` instala un temporizador de systemd que llama a `orbit watch --quiet` cada minuto. Es el sistema operativo invocando un script que hace su trabajo y termina, no un proceso que Orbit tenga que mantener vivo. Puedes comprobarlo:

```bash
systemctl list-timers orbit-watch.timer
ps aux | grep orbit          # no hay nada
```

### Qué comprueba y qué hace

| Comprueba | Si falla |
|---|---|
| Cada app con proceso responde en su puerto interno | La reinicia |
| nginx, PostgreSQL y php-fpm están vivos | Los reinicia |
| El disco no supera el umbral (90 % por defecto) | Solo avisa |
| Queda memoria disponible (10 % por defecto) | Solo avisa |
| Ningún certificado caduca en menos de 10 días | Solo avisa |

Los tres últimos **solo avisan, nunca actúan**. Borrar ficheros o matar procesos por su cuenta convertiría un aviso en una pérdida de datos.

Que la unidad de systemd esté «activa» no basta: se comprueba que la app **responde de verdad** en su puerto. Un proceso vivo pero colgado no le sirve de nada a un visitante.

### Protección contra bucles

Si una app se reinicia **3 veces en 10 minutos**, Orbit deja de intentarlo, la marca como caída y avisa. Un watchdog que reinicia en bucle una app rota consume el servidor y esconde el problema: es peor que no tener watchdog.

La ventana se reinicia sola. Tres reinicios en diez minutos son un bucle; tres repartidos a lo largo del día son tres incidentes distintos, y cada uno merece su intento.

Cuando la app vuelve, el contador se pone a cero y recibes el aviso de que ha vuelto.

### Los avisos no se repiten

Se avisa de la **transición**, no del estado. Si una app se cae a las 3 de la mañana recibes un mensaje, no 300. Cuando vuelve, recibes otro.

```bash
orbit watch              # comprobar ahora y ver el resumen
orbit watch --history    # qué ha pasado
orbit watch status       # ¿está activo el temporizador?
orbit watch disable
```

El historial solo anota cambios: **un servidor sano no escribe nada**. Si registrara cada comprobación, en un mes habría 43.000 líneas y nadie volvería a mirarlo.

El estado vive en `/var/lib/orbit/watch.state` y se lee con `cat`:

```
# sujeto estado desde_epoch intentos ultimo_intento_epoch
app:mi-web fallo 1785943663 2 1785943663
disco ok 0 0 0
```

### Umbrales

En `/etc/orbit/orbit.conf`:

```bash
WATCH_DISK_MAX="90"     # % de disco a partir del cual avisar
WATCH_MEM_MIN="10"      # % de memoria disponible mínimo
WATCH_CERT_DAYS="10"    # días de margen antes de que caduque un certificado
WATCH_MAX_TRIES="3"     # reinicios antes de rendirse
WATCH_WINDOW="600"      # ventana en segundos de esos reinicios
```

### Avisos

```bash
orbit notify setup    # configurar
orbit notify test     # comprobar que llegan
orbit notify status   # ver qué hay configurado
```

Cuatro canales: **Telegram**, **Discord**, **correo** y un **webhook genérico** que recibe un POST con JSON:

```json
{"level":"crit","host":"vps","message":"…","time":"2026-08-05T15:27:37+00:00"}
```

#### El correo va por un relé tuyo

Orbit **no monta un servidor de correo**. Un VPS limpio no puede entregar: no hay MTA, el puerto 25 de salida suele estar bloqueado por el proveedor, y lo poco que saliera sin reputación acabaría en la carpeta de spam de quien tuviera que leerlo. Así que el correo lo entrega quien ya sabe hacerlo — tu proveedor de siempre — y Orbit sólo habla SMTP con él, con `curl`, que ya estaba instalado.

```
Correo de destino                 avisos@midominio.com
Servidor SMTP (smtps://host:465)  smtps://smtp.gmail.com:465
Remitente                         orbit@midominio.com
Usuario SMTP                      yo@midominio.com
Contraseña SMTP                   ····
```

Con Gmail hace falta una **contraseña de aplicación**, no la de tu cuenta. Con Fastmail, SES, Postmark o el relé de tu empresa, sus credenciales de siempre.

Puedes poner **varios destinatarios** separados por comas: un aviso que sólo puede ir a una persona se pierde en cuanto esa persona está de vacaciones.

**Si hay contraseña, se exige TLS** y no es configurable: un `AUTH` sin cifrar entrega la contraseña de tu correo a cualquiera que mire la red. Sin contraseña no se exige, porque ese caso es un relé en la propia máquina o en la red local.

#### `orbit notify test` comprueba de verdad

Prueba **canal a canal** y dice cuál ha fallado y por qué:

```
  ✓ telegram: enviado
  ✗ mail: no ha salido (curl 67)
  ·   curl: (67) Login denied
```

Antes llamaba a la misma función que usa el vigilante, que se traga los fallos a propósito —un aviso que no sale no puede tumbar el arreglo que estaba en marcha— y por eso decía «Enviado» con un token caducado o una contraseña mal escrita. Un canal de avisos que miente sobre sí mismo es peor que no tenerlo: dejas de mirar el servidor confiando en que ya te avisará.

Que salga en verde significa que el mensaje salió de tu servidor. Si no llega, el problema está en el destino — spam, filtro, chat equivocado — y ahí Orbit ya no ve nada.


`NOTIFY_MIN_LEVEL` filtra por gravedad: `info` (incluye las recuperaciones), `warn` (por defecto) o `crit` (solo lo grave).

**No hay correo, y es deliberado.** Un VPS recién instalado no puede enviarlo: sin un relé SMTP configurado, el mensaje se queda en la cola o lo tira el destinatario por falta de SPF y DKIM, y **falla en silencio**. Un aviso que no llega es peor que no tener avisos, porque te hace creer que estás cubierto. Entrará cuando exista `orbit mail setup`.

## Redirecciones

Dos cosas distintas que conviene no mezclar: mover rutas **dentro** de una web, y mudar un **dominio entero** a otro.

### Rutas dentro de una app

```bash
orbit redirect add mi-web /precios /pricing
orbit redirect add mi-web '/blog/*' '/noticias/*'
orbit redirect add mi-web '~^/p/(\d{3})$' '/producto/$1'
orbit redirect add mi-web /promo https://otra-web.com/oferta --302
orbit redirect list mi-web
orbit redirect rm mi-web /precios
```

Tres formas de escribir el origen:

| Forma | Ejemplo | Qué hace |
|---|---|---|
| Exacta | `/precios` | Solo esa ruta. Es lo que quieres el 95 % de las veces |
| Comodín | `/blog/*` → `/noticias/*` | `*` captura el resto y lo pega en el destino |
| Expresión regular | `~^/p/(\d{3})$` → `/producto/$1` | Todo el poder de nginx, con `$1`…`$9` |

**Comillas simples**, siempre que uses `*`, `$` o `\`: si no, las expande tu shell antes de que Orbit las vea.

### Decisiones que conviene conocer

**301 por defecto.** Es lo correcto para un cambio definitivo y es lo que consolida el posicionamiento. Usa `--302` si la redirección es temporal, o `--307` y `--308` si necesitas que se conserve el método POST. Ten en cuenta que un 301 lo cachea el navegador **para siempre**: si te equivocas, quien ya lo haya visitado seguirá redirigido aunque quites la regla. Empieza con `--302` si tienes dudas.

**La cadena de consulta se conserva.** `/precios?utm_source=boletin` acaba en `/pricing?utm_source=boletin`. Esto no es lo que hace nginx por defecto: `return` la descarta, y perder `?utm_source=` en una redirección rompe la atribución de las campañas sin que nadie se dé cuenta hasta que mira las analíticas a fin de mes. Con `--no-query` se descarta a propósito. Si tu destino ya lleva `?`, la original no se añade.

**Orden de evaluación: lo más específico primero.** Las exactas ganan siempre (así funciona `location =` en nginx). Entre comodines y expresiones regulares gana la primera que coincide, así que Orbit las ordena de patrón más largo a más corto: `/blog/viejo/*` se evalúa antes que `/blog/*`.

**Sobreviven a todo.** Las reglas viven en `/etc/orbit/redirects/<app>.list`, fuera del vhost, y se vuelven a escribir en cada `orbit deploy` y en cada `orbit nginx-rebuild`. Editar el vhost a mano no serviría: se regenera.

```bash
cat /etc/orbit/redirects/mi-web.list
```

```
# Redirecciones de mi-web · una por línea:  origen destino [código] [noquery]
/precios /pricing 301
/blog/* /noticias/* 301
~^/p/(\d{3})$ /producto/$1 302
```

Puedes editarlo a mano y aplicarlo con `orbit nginx-rebuild`.

### Dominio entero

```bash
orbit redirect add viejo.com https://nuevo.com
orbit ssl viejo.com
```

Genera un vhost dedicado que solo redirige, conservando ruta y cadena de consulta: `viejo.com/blog/x?a=1` → `https://nuevo.com/blog/x?a=1`.

Sirve para dominios comprados por defensa de marca y para migraciones. **Necesita su propio certificado**: si alguien entra por `https://viejo.com` y no hay certificado, verá un aviso del navegador antes de llegar a la redirección. Por eso Orbit te recuerda ejecutar `orbit ssl`.

Es una app más a todos los efectos: aparece en `orbit list` con el tipo `redirect`, se renueva el certificado sola y se quita con `orbit remove viejo.com`. Lo único que no admite es `orbit deploy`, porque no hay código detrás.

## Django, Flask y FastAPI

Orbit detecta el framework, el gestor de dependencias y el módulo real de la aplicación. No hay que decirle nada.

| En el repo | Detecta | Arranca con |
|---|---|---|
| `manage.py` | Django (WSGI) | `gunicorn <proyecto>.wsgi:application` |
| `manage.py` + `channels`/`daphne` | Django (ASGI) | `uvicorn <proyecto>.asgi:application` |
| `fastapi` en las dependencias | FastAPI | `uvicorn <modulo>:<objeto>` |
| `flask` en las dependencias | Flask | `gunicorn <modulo>:<objeto>` |

El nombre del proyecto Django sale de `DJANGO_SETTINGS_MODULE` en tu `manage.py`, así que funciona igual si tu paquete se llama `config`, `core` o cualquier otra cosa. Y el objeto de Flask o FastAPI se busca en el fichero donde está de verdad: si tu app se llama `api` y vive en `app/main.py`, arranca `app.main:api`.

| Fichero de bloqueo | Instala con |
|---|---|
| `uv.lock` | `uv sync --frozen --no-dev` |
| `poetry.lock` | `poetry install --only main --no-root` |
| `requirements.txt` | `pip install -r requirements.txt` |
| solo `pyproject.toml` | `pip install .` |

`uv` y `poetry` se instalan **dentro del venv de cada app**, no en el sistema. Así cada proyecto usa la versión que le convenga y el servidor no acumula herramientas globales.

### Estáticos

Para Django, el build ejecuta `collectstatic` y nginx sirve `/static/` y `/media/` **directamente desde disco**. Esto no es una optimización opcional: con `DEBUG=False` Django no sirve estáticos en absoluto, así que sin esto tu web sale sin CSS.

Orbit no adivina las rutas: después de compilar le pregunta a Django por `STATIC_URL`, `STATIC_ROOT`, `MEDIA_URL` y `MEDIA_ROOT` y las guarda en la configuración de la app. Necesitas tener esto en `settings.py`:

```python
STATIC_ROOT = BASE_DIR / 'staticfiles'
```

Si no lo tienes, el build falla y te lo dice. La versión anterior sigue en producción mientras tanto.

**Aviso importante sobre `MEDIA_ROOT`.** Si apunta dentro del proyecto, lo que suban tus usuarios vivirá dentro de la release y **desaparecerá en el siguiente despliegue**. Orbit te avisa. Apúntalo a una ruta estable:

```python
MEDIA_ROOT = '/srv/apps/mi-web/shared/media'
```

### Migraciones: nunca automáticas

```bash
orbit migrate mi-web          # enseña el plan y pide confirmación
orbit migrate mi-web --yes    # sin preguntar, para scripts
```

`orbit deploy` **no aplica migraciones jamás**. Una migración que borra una columna ejecutada sin querer en un despliegue automático es una forma excelente de perder datos. Lo que sí hace es comprobarlo al terminar y avisarte:

```
  ! Hay migraciones sin aplicar (o no he podido comprobarlo).
  ! Revísalas y aplícalas con:  orbit migrate mi-web
```

Así no se te olvida, pero tampoco pasa nada sin que lo mires. `orbit migrate` te enseña primero el plan completo, operación por operación, antes de preguntar.

Para un framework que no sea Django, define el comando en `A_MIGRATE` dentro de `/etc/orbit/apps/<app>.conf`:

```bash
A_MIGRATE='./.venv/bin/alembic upgrade head'
```

### Lo que Orbit comprueba al desplegar

Al terminar un despliegue de Django te avisa de las tres cosas que más veces dejan una web rota o expuesta en un VPS:

- **`DEBUG=True`** en producción, que enseña trazas con rutas y variables a cualquiera
- **El dominio no está en `ALLOWED_HOSTS`**, que hace que Django responda `400 Bad Request` a todo
- **`MEDIA_ROOT` dentro de la release**, que borra las subidas en el siguiente despliegue

## Ejecutar algo dentro de la app

```bash
orbit exec mi-web npx prisma migrate deploy
orbit exec mi-web ./.venv/bin/python manage.py migrate
orbit exec mi-web php artisan queue:work --once
orbit exec mi-web                                  # shell interactiva
```

Ejecuta el comando **en la release activa, como usuario `deploy` y con el mismo entorno que la app tiene cuando corre de verdad**: su `.env`, su `PORT`, su `HOST` y `NODE_ENV=production`.

Eso último importa: en la unidad de systemd, `EnvironmentFile` va antes que las líneas `Environment=`, así que un `NODE_ENV` escrito en tu `.env` pierde frente al de la unidad. `orbit exec` reproduce esa misma precedencia. Si no lo hiciera, depurarías un entorno que no es el que tienes en producción.

El `PATH` lleva por delante `node_modules/.bin` y `.venv/bin` de la release, así que puedes escribir `orbit exec mi-web prisma migrate deploy` sin el `npx`.

### Las dos formas de escribir el comando

```bash
orbit exec mi-web echo 'un argumento con espacios'    # se respeta tal cual
orbit exec mi-web 'echo uno && echo dos'              # va a bash -lc
```

Todo lo que escribas después del nombre de la app se ejecuta directamente, así que las comillas de cada argumento se conservan. La excepción: **un solo argumento que contenga espacios o metacaracteres** (`| & ; < > $ \``) se interpreta como una orden de shell, para que las tuberías y los `&&` funcionen como esperas.

### La salida es la del comando

No hay decoración de Orbit por medio y el código de salida se propaga, así que se puede encadenar:

```bash
orbit exec mi-web node -e 'console.log(process.env.DATABASE_URL)' | cut -d@ -f2
orbit exec mi-web sh -c 'exit 3'; echo $?      # 3
```

Los avisos de Orbit van a `stderr` precisamente para no colarse en una tubería.

### Para qué NO usarlo

Para instalar dependencias o compilar. Aquí `NODE_ENV=production` está activo y npm y pnpm se saltarían las `devDependencies`, que es el fallo mejor documentado de este proyecto (ver TROUBLESHOOTING). Orbit te avisa si lo intentas. Para eso está `orbit deploy`, que compila con el entorno correcto y en una carpeta aparte.

### Nota sobre el `.env`

`orbit exec` carga el `.env` con `source`, igual que hace el build. systemd, en cambio, lo *interpreta* como pares `CLAVE=valor` sin ejecutar nada. Para valores normales el resultado es idéntico; si escribes sustituciones de shell dentro del `.env` (`FOO=$(hostname)`), aquí se ejecutarán y en el servicio no.

En el log de `/var/log/orbit/orbit.log` queda anotada la app, **no el comando**: una orden puede llevar una contraseña delante y el log no es sitio para secretos.

## Puerto interno

Las apps de Node y Python escuchan en un puerto de `127.0.0.1` que Orbit reparte solo, empezando por el 3001. Normalmente no hay que tocarlo. Cuando sí:

```bash
orbit port mi-web          # comprueba si choca y, si choca, lo mueve a uno libre
orbit port mi-web 3010     # fija uno concreto
```

Sin número es **idempotente y seguro**: si el puerto actual no choca con nadie no cambia nada, y solo mueve la app cuando detecta un conflicto. Con número, rechaza el cambio si ese puerto ya lo tiene otra app.

Regenera la unidad de systemd y el vhost, y reinicia la app. Si nginx rechazara la configuración, revierte el puerto y no toca el servicio.

Lo necesitas cuando `orbit doctor` avisa de puertos duplicados, o cuando otro programa del servidor ocupa el rango que usa Orbit.

## Dominios

```bash
orbit domain mi-web
```

Cambia el dominio principal o añade alias. Regenera el vhost y te ofrece reemitir el certificado.

Recuerda crear también el registro A en Cloudflare antes.

## Certificados

```bash
orbit ssl mi-web
```

Emite o renueva el certificado de Let's Encrypt. Con el token de Cloudflare guardado usa validación por DNS, que funciona con el proxy activado.

La renovación automática ya está configurada mediante el temporizador de certbot. No hay que hacer nada.

## Eliminar una app

```bash
orbit remove mi-web
```

Te pide escribir el nombre para confirmar. Después pregunta aparte si quieres borrar también los ficheros de `/srv/apps`.

Los certificados no se borran, por si vuelves a usar el dominio.

---

## Bases de datos

```bash
orbit db create mi-web     # crea rol y base, escribe DATABASE_URL en el .env
orbit db list              # lista todas las bases
orbit db shell mi_web      # abre psql
orbit db backup mi-web     # copia comprimida en /var/backups/orbit
```

Los guiones del nombre de la app se convierten en guiones bajos para el nombre de la base, porque PostgreSQL no admite guiones sin comillas.

Hay una **copia automática de todas las bases cada día a las 4:30**, con retención de 14 días.

PostgreSQL solo escucha en localhost. Para conectarte con un cliente gráfico usa un túnel SSH:

```bash
ssh -L 5432:localhost:5432 root@TU-IP
```

Y en TablePlus, DBeaver o pgAdmin conectas a `localhost:5432` con las credenciales que hay en el `.env` de la app.

---

## Servidor

```bash
orbit status     # memoria, disco, carga, servicios y apps
orbit doctor     # diagnóstico completo con DNS y certificados
```

```bash
orbit firewall status
orbit firewall lock      # solo Cloudflare puede llegar a 80 y 443
orbit firewall unlock    # abrir a todo el mundo
```

```bash
orbit cf-update          # refrescar los rangos de IP de Cloudflare
orbit nginx-rebuild      # regenerar todos los vhosts
```

`nginx-rebuild` es útil después de actualizar Orbit, para que todas las apps reciban las mejoras de las plantillas. Regenera además el **servidor por defecto** —el que contesta a los nombres que no sirve ninguna app—, que vive fuera de los vhosts: un nombre desconocido cierra la conexión en el 80 y rechaza el saludo TLS en el 443, en vez de acabar en la primera app de la lista. `orbit doctor` avisa si a tu servidor le falta.

---

## Trabajar a mano

Orbit no te encierra. Todo lo que genera es estándar.

```bash
# El clon de git tal cual llegó del repositorio
cd /srv/apps/mi-web/cache

# Probar un build sin lanzar un despliegue entero
sudo -u deploy bash -lc 'cd /srv/apps/mi-web/cache && pnpm run build'

# Ver la configuración de nginx generada
cat /etc/nginx/sites-available/orbit-mi-web.conf

# Ver la unidad de systemd
systemctl cat orbit-mi-web

# La configuración de la app
cat /etc/orbit/apps/mi-web.conf
```

Los vhosts de `/etc/nginx/sites-available/orbit-*.conf` **se regeneran en cada despliegue**. No los edites a mano: si necesitas algo especial, abre un issue para que se añada a la plantilla.

---

## Copias de seguridad

```bash
orbit backup mi-web        # una app
orbit backup --all         # todas, más la configuración global
orbit backup list          # qué copias hay
orbit backup verify        # comprueba que de ellas se puede volver
orbit restore <fichero>    # devolver una copia a su sitio
```

`list` y `verify` hablan JSON, para quien no sea una persona:

```bash
orbit backup list --json
orbit backup verify --json
```

El tamaño va en **bytes** y la fecha en ISO-8601 con huso, no en `1,2G` ni en
`2026-08-29 03:15`: eso es presentación, y reinterpretarla al otro lado obliga a
saber la configuración regional de este servidor. La copia de la configuración
global sale con `"app": null` y `"kind": "config"`, porque no es de ninguna app.

En `list`, `verified` es **`null`**: quiere decir «no lo he comprobado en esta
llamada», que no es lo mismo que «está mal» — abrir cada fichero cuesta, y no se
hace de gratis. Quien quiera la respuesta usa `verify`.

En `verify`, el `ok` de arriba es un booleano y sigue **la misma regla que el
código de salida**: falso si alguna copia está rota, igual que el `exit 1`. Los
recuentos van aparte, en `good` y `bad`.

```bash
# ¿Puedo dormir tranquilo?
orbit backup verify --json | jq -e '.ok' >/dev/null && echo "todas se pueden restaurar"

# Cuánto ocupan las copias, en bytes
orbit backup list --json | jq '.bytes'
```

Cada copia es un `.tar.gz` que se lee con `tar tzf` sin necesitar Orbit:

```
mi-web-20260806-101010.tar.gz
├── manifest          qué lleva dentro, en texto plano
├── app.conf          la configuración de la app
├── redirects.list    sus redirecciones, si tiene
├── database.sql.gz   volcado de PostgreSQL, si tiene
└── shared/           el .env, la página de mantenimiento y las subidas
```

### El código no se copia, y es a propósito

Está en git. Git es una copia de seguridad del código mejor que cualquier cosa que pudiera hacer Orbit, y meterlo aquí multiplicaría el tamaño del fichero sin añadir nada que no tengas ya.

Lo que **no** está en git es justo lo que se guarda: los secretos del `.env`, lo que han subido tus usuarios, la configuración de la app y su base de datos. Restaurar es poner todo eso en su sitio y desplegar:

```bash
orbit restore /var/backups/orbit/mi-web-20260806-101010.tar.gz
orbit deploy mi-web
```

Ese segundo comando te lo recuerda el primero, con el nombre ya puesto.

### Levantar un servidor entero

El caso para el que existe todo esto: la máquina se ha perdido, tienes un Ubuntu nuevo con Orbit instalado y un directorio con las copias.

```bash
orbit restore --all                    # desde /var/backups/orbit
orbit restore --all /mnt/copias        # o desde donde las tengas
orbit restore --all --deploy           # y que además traiga el código
```

Te enseña el plan antes de tocar nada y pregunta **una vez**:

```
Restaurar el servidor entero
  Copias en /var/backups/orbit

  blog               blog-20260806-030000.tar.gz     2026-08-06 03:00
  tienda             tienda-20260806-030000.tar.gz   2026-08-06 03:00
  preferencias       _orbit-conf-20260806-030000.tar.gz

  2 apps · el código se trae de git después
```

De cada app coge **la más reciente**. Y de la configuración global restaura solo tus preferencias —`LETSENCRYPT_EMAIL`, `KEEP_RELEASES`, los umbrales de `orbit watch`, los ajustes de copias— **nunca** lo que describe a este servidor: `APPS_DIR`, `DEPLOY_USER` y `PHP_VER` los escribió el instalador de esta máquina y son los que valen. Los avisos (`notify.conf`) sí vuelven enteros: ese fichero no describe al servidor, dice a quién avisar.

Sin `--deploy` no se despliega nada: traer el código tarda, puede fallar y necesita GitHub conectado, así que se te dan los comandos escritos y decides tú.

### Qué pasa con la base de datos

Se restaura sola, y con un detalle que importa: **el rol de PostgreSQL se recrea con la contraseña que dice el `.env` restaurado**. Si se creara con una nueva, la app arrancaría y daría `password authentication failed` mucho más tarde, sin relación aparente con la restauración.

Si la base ya existe, se pregunta antes de cargar el volcado encima. Y si PostgreSQL no está en marcha, se restaura todo lo demás y se te dice el comando exacto para cargar el volcado después.

### Sacarlas del servidor

Una copia que vive en el mismo disco que los datos no es una copia. Orbit no sabe de S3, de rclone ni de scp —y no debería—, así que te pasa el fichero a un comando tuyo:

```bash
# en /etc/orbit/orbit.conf — con comillas SIMPLES, ver más abajo
BACKUP_HOOK='rclone copy --'
BACKUP_HOOK='scp -q -- copias@otro-servidor:/copias/'
BACKUP_HOOK='/usr/local/bin/subir-a-s3.sh'
```

El comando recibe la ruta del fichero recién creado **como último argumento**, igual que en `find -exec`. Si tu hook es algo más que un comando suelto, nómbralo tú y entonces no se añade nada al final:

```bash
BACKUP_HOOK='gpg -e -r yo@midominio.com -o - "$ORBIT_BACKUP_FILE" | aws s3 cp - s3://copias/'
```

**Comillas simples en `orbit.conf`, no dobles.** El fichero se carga con `source`, así que un `$ORBIT_BACKUP_FILE` entre comillas dobles se expandiría —a nada— en ese momento y no cuando se ejecuta el hook. Con comillas simples el texto llega intacto.

El hook se ejecuta **como root**, así que la configuración de `rclone` o las claves SSH que use tienen que ser las de root. Si falla, se te dice claramente que la copia solo está en este servidor: un envío que falla en silencio es peor que no tener envío, porque te crea la sensación de estar cubierto.

### Cuánto se guarda

Las copias se borran a los **14 días** (`BACKUP_KEEP` en `orbit.conf`) y viven en `/var/backups/orbit` (`BACKUP_DIR`), un directorio `0700` con ficheros `0600`: llevan tus secretos dentro.

**El token de Cloudflare no se copia.** Se vuelve a generar en treinta segundos con `orbit cf-token`, y dejarlo fuera significa que una copia robada no sirve para tomar el control de tu DNS.

### Una copia diaria de todo

El instalador ya deja una copia diaria de las bases de datos. Para copiarlo todo:

```bash
# /etc/cron.d/orbit-backup
0 3 * * * root /usr/local/bin/orbit backup --all >/var/log/orbit/backup.log 2>&1
```

---

## Salida para máquinas: `--json`

Todo lo que Orbit enseña por pantalla está pensado para que lo lea una persona: columnas alineadas, colores, castellano. Si un script tiene que leer eso, acaba analizando tablas, y entonces alinear una columna se convierte en un cambio que rompe cosas sin que nadie lo vea venir.

`--json` separa las dos cosas:

```bash
orbit version --json          # con qué versión hablas, y qué versión tiene el contrato
orbit list --json
orbit info mi-web --json
orbit status --json
orbit doctor --json
orbit top --json
orbit env list mi-web --json
orbit db list --json
orbit redirect list [app] --json
orbit watch status --json
orbit backup list --json
orbit backup verify [fichero] --json
orbit logs <app> --json        # NDJSON: una línea por línea de log, ver abajo
orbit github status --json     # si este servidor tiene GitHub conectado
orbit github repos --json      # y qué repositorios ve
orbit github branches <url> --json
```

La bandera vale delante o detrás del comando: `orbit --json list` y `orbit list --json` son lo mismo. En un comando que no tiene salida JSON, aborta diciéndolo —ignorarla en silencio te haría creer que lo que vas a leer es JSON cuando no lo es.

**La promesa del formato:** los campos **se añaden, nunca se renombran ni cambian de tipo**. Puedes depender de ellos. Si algún día hubiera que romperlo, subiría el número de `schema`, que va en todas las respuestas.

**Y si algún día `schema` sube**, cambiará el nombre o el significado de algún campo. Lo que **no cambia nunca, ni entre versiones de `schema`**, son tres cosas: la forma de `orbit version --json`, que por stdout vaya un solo objeto y lo demás por stderr, y que **lo que no existe sea `null`** y no un cero. Un script que sólo dependa de esas tres sigue funcionando pase lo que pase.

```bash
# Las apps que están paradas y deberían estar arriba
orbit list --json | jq -r '.apps[] | select(.state.service=="stopped") | .name'

# Las que nginx no está sirviendo: registradas y con el dominio sin atender
orbit list --json | jq -r '.apps[] | select(.state.served == false) | .name'

# Certificados a menos de 15 días
orbit list --json | jq -r '.apps[].name' | while read -r a; do
  orbit info "$a" --json | jq -r 'select(.app.state.cert_days < 15) | .app.name'
done

# ¿Hay algo roto?
[[ "$(orbit doctor --json | jq '.summary.error')" == "0" ]] || echo "revisa el servidor"
```

Un par de decisiones que conviene conocer:

- **Un dato que no existe es `null`, nunca cero ni cadena vacía.** El puerto de una web estática es `null` porque no tiene puerto; el 0 sería un puerto. Lo mismo con `service`: una estática no está `stopped`, está a `null`, porque no hay ningún proceso que arrancar.
- **`state.served` es lo primero que hay que mirar.** Dice si nginx tiene el vhost de esa app, fichero y enlace. Con `false` el dominio no lo atiende nadie —la petición cae en el servidor por defecto y el visitante recibe la conexión cerrada, ni 404 ni 502—, así que ningún otro campo del estado describe lo que está recibiendo. Ni siquiera `maintenance`: sin vhost no se sirve tampoco la página de 503. `orbit doctor --fix` lo regenera del descriptor.
- **`config` es el fichero de la app tal cual**, y por eso todos sus valores son cadenas: en el fichero lo son. Los datos con tipo —el puerto como número, las banderas como booleano— están en `state`, que es lo que Orbit deduce mirando systemd, el disco y los certificados.
- **Los valores del `.env` no salen por aquí.** `orbit env list --json` da los nombres y nada más. Un panel que enseñe el `.env` entero es un panel que filtra la contraseña de la base de datos en una captura de pantalla.
- **`orbit doctor` sigue saliendo con código 0** aunque encuentre problemas, porque hay scripts que lo tienen encadenado con `&&` desde antes. Para decidir con el resultado, mira `.summary.error`.
- **Una colección vacía significa «no hay», nunca «no he podido preguntar».** Si Orbit no puede obtener el dato —PostgreSQL apagado, por ejemplo— aborta: error por `stderr`, código distinto de cero y **nada** por la salida normal. Nunca verás `[]` como forma de decir que algo falló, así que puedes fiarte de una lista vacía. Mira el código de salida antes de pasarle la salida a `jq`.
- **`orbit top --json` no se queda en vivo**, ni siquiera sin `--once`: en modo máquina siempre es una foto.

### Comandos que ya no necesitan un terminal

Un contrato de lectura no basta: un cliente también tiene que poder *hacer* cosas, y hasta ahora los comandos que preguntan solo se dejaban usar con alguien delante.

```bash
orbit new --repo … --domain … --yes      # el asistente entero, sin preguntas
orbit rollback mi-web 20260805-041230    # sin selector: la release se nombra
orbit remove mi-web --yes                # sin escribir el nombre para confirmar
orbit remove mi-web --yes --purge        # y además borra /srv/apps/mi-web
orbit port mi-web 3005                   # ya era no interactivo
orbit env set mi-web CLAVE valor
orbit maintenance on mi-web "Volvemos a las 18:00"
```

Dos detalles con intención:

- **`--yes` no es «que sí a todo», es «acepta lo que está por defecto».** Por eso `orbit new --yes` no crea la base de datos y `orbit remove --yes` no borra tus ficheros: esas dos preguntas tienen «no» por defecto. Para lo segundo está `--purge`, que es una segunda decisión porque es un segundo daño: quitar la app de nginx se deshace volviéndola a crear, pero borrar `/srv/apps/mi-web` se lleva las releases, el `.env` y las subidas de tus usuarios.
- **`orbit rollback` sin release y sin terminal aborta** en vez de elegir por ti. La primera de la lista es la que ya está activa, así que «elegir la primera» habría sido no hacer nada mientras se reinicia el servicio.

### Elegir repositorio y rama desde un cliente

`orbit new` sin `--repo` te ofrece tus repositorios y, después, las ramas del
que elijas. Está bien para una persona y **no le sirve a un programa**: el
selector necesita un terminal —`fzf`, o una lista numerada que alguien lee— y
con `--yes`, que es como invoca `new` cualquier cliente, ni se llega a él.

Las tres preguntas que hay detrás de ese selector salen ahora por su cuenta:

```bash
orbit github status --json
# {"schema":1,"connected":true,"account":"davabe","deploy_user":"deploy"}

orbit github repos --json
# {"schema":1,"connected":true,"account":"davabe","limit":200,"truncated":false,
#  "repos":[{"name_with_owner":"davabe/tienda","private":true,
#            "default_branch":"main","description":"La tienda",
#            "updated_at":"2026-09-04T22:25:55Z"}]}

orbit github branches https://github.com/davabe/tienda.git --json
# {"schema":1,"repo":"https://github.com/davabe/tienda.git",
#  "branches":["main","develop"]}
```

Son de **sólo lectura**. Conectar sigue siendo `orbit github` a secas y sigue
necesitando un navegador: el flujo de GitHub da un código de un solo uso, y eso
no se puede automatizar sin que el token pase por sitios donde no tiene que
estar.

Cuatro cosas que conviene saber, y las cuatro por el mismo motivo:

- **La cuenta es la del servidor, no la tuya.** Estos repositorios los ve el
  usuario de despliegue con su propio `gh`, que es **el que va a clonar**. Un
  cliente que enseñe la lista de otra cuenta está ofreciendo repositorios que
  este servidor puede no alcanzar, y eso no se descubre hasta el clon.
- **Sin conectar, la lista es vacía y `connected` es `false`.** No es lo mismo
  que una cuenta sin repositorios, y confundirlas te haría enseñar «no tienes
  repos» a quien sólo tiene el servidor sin conectar.
- **`truncated` es «puede haber más», no «hay más».** Llegan los que caben en
  `--limit` (200 por defecto, `orbit github repos 50 --json` para cambiarlo); si
  llegan justo esos, desde aquí no se puede saber si hay otro sin pedir otra
  página.
- **Un repositorio vacío da `default_branch: null`**, y `branches` una lista
  vacía. No se rellena con `main`: un cliente que clonara `--branch main` de un
  repositorio sin ramas fallaría, y la culpa sería del que se inventó el dato.

### Orbit Desktop

El destino natural de este contrato es **Orbit Desktop**, un cliente gráfico que vivirá en su propio repositorio y que **no instala nada en el servidor**: corre en tu portátil, entra por SSH con tus claves de siempre y ejecuta `orbit … --json`. El servidor no gana ni un proceso, ni un puerto, ni un fichero de estado.

Mientras tanto, ese mismo contrato ya funciona con lo que tengas a mano:

```bash
ssh mi-vps orbit list --json | jq .
ssh mi-vps orbit version --json | jq -r .contract    # ¿habla mi versión del contrato?
```

## Desplegar desde un script

```bash
orbit deploy mi-web --json               # un objeto, al terminar
orbit deploy mi-web --json --progress    # y el avance por stderr, según ocurre
```

Por **stdout va un solo objeto**, igual que en todos los demás comandos, así que `| jq .` funciona:

```json
{
  "schema": 1, "app": "mi-web", "ok": true,
  "release": "20260807-031500", "previous": "20260806-221000",
  "commit": { "sha": "a1b2c3d", "subject": "arregla el formulario", "ref": null },
  "rolled_back": false, "recovered": false,
  "duration_s": 84, "failed_step": null, "error": null
}
```

`rolled_back` y `recovered` están para que puedas enseñar distinto lo que **es** distinto: en uno salió mal y se volvió atrás; en el otro Orbit arregló el build por su cuenta y reintentó. Y `previous` te ahorra una llamada si quieres ofrecer el rollback.

**Si falla, también contesta**, con `ok: false` y `failed_step` diciendo dónde se rompió (`code`, `release`, `build`, `activate`, `service`, `nginx`).

Con `--progress`, por **stderr** sale una línea de JSON por suceso, legible según llega:

```
{"event":"step","step":"code","status":"start","elapsed_s":0}
{"event":"step","step":"code","status":"ok","elapsed_s":3}
{"event":"step","step":"build","status":"start","elapsed_s":3}
```

Dos cosas que conviene saber: con `--json` **todo lo que Orbit le cuenta a una persona sale por stderr**, no por stdout — así el objeto nunca se ensucia. Y **no se pregunta nunca**: hay que dar el nombre de la app, y `--pick` no vale, porque al otro lado no hay nadie que conteste.

## Diagnóstico, y arreglarlo

```bash
orbit doctor          # qué va mal
orbit doctor --fix    # y arréglalo, si se puede sin decidir por ti
```

`--fix` enseña el diagnóstico, te dice **cuáles sabe arreglar solo**, pregunta una vez y los aplica. Al terminar vuelve a diagnosticar y enseña cómo queda: lo que cuenta es el estado del servidor, no lo que dijeron los comandos.

Arregla cuatro cosas: PostgreSQL parado, php-fpm parado, el servidor por defecto ausente o sin bloque 443, y los puertos internos duplicados (moviendo la app que **no** está sirviendo, no la que sí).

Lo que **no** toca, y no es una carencia:

| No arregla | Por qué |
|---|---|
| `pnpm` o `hugo` sin instalar | Instalar cosas en tu servidor no es un diagnóstico |
| GitHub o Cloudflare sin conectar | Hace falta un navegador y un token tuyo |
| Disco lleno | Qué se borra lo decides tú |
| Certificado por caducar | Se renueva solo, y `certbot` tiene límites de peticiones |
| Una unidad anterior al `HOME` propio | Necesita un despliegue entero: `orbit deploy <app>` |

Desde un script:

```bash
orbit doctor --json | jq '.checks[] | select(.fixable)'   # qué tiene botón
orbit doctor --fix --json --yes                            # aplicarlo sin preguntar
```

`--fix --json` **exige `--yes`**: sin terminal no se puede preguntar, y dar por hecho que has dicho que sí sería aplicar cambios en tu servidor sin que los aceptes.

## La interfaz: color, ancho y animaciones

Orbit se adapta a la terminal que tenga delante y no pinta nada cuando no hay nadie mirando.

**El color se apaga solo** en tres casos, y no son el mismo:

| Caso | Por qué |
|---|---|
| La salida va a una tubería o a un fichero | Los códigos de escape acabarían dentro de tu log o de tu `tee` |
| `TERM=dumb` | Hay terminal, pero no entiende secuencias de escape |
| `NO_COLOR` con cualquier valor | Es una convención ([no-color.org](https://no-color.org)) que respetan `curl`, `ripgrep` y `systemd` |

```bash
NO_COLOR=1 orbit list      # sin color, aunque estés en una terminal
orbit list | tee salida    # sin color por su cuenta: no hace falta decírselo
```

**El ancho** sale de la terminal: las rayas y los rótulos llegan hasta el borde, entre 40 y 100 columnas. Redirigido, se queda en los 66 de siempre, así que un log o un informe de fallo salen igual que antes.

**El logotipo grande** sólo aparece en el menú, y sólo si la ventana es de al menos 46 columnas y 40 líneas. En una más pequeña se pinta el rótulo compacto: el menú ya son treinta y tantas líneas y seis más harían desaparecer por arriba justo lo que hay que leer.

**Las animaciones** —el barrido del logotipo al abrir el menú y la ruedecita de los procesos largos— se apagan enteras con:

```bash
UI_ANIM="no"     # en /etc/orbit/orbit.conf
```

Se apagan además solas siempre que no haya terminal o no haya color, así que en `cron`, en el autodespliegue y en cualquier salida redirigida nunca se dibuja un fotograma. Ninguna anima más de medio segundo, y sólo la primera vuelta del menú: volver del diagnóstico por décima vez y tener que esperar otra vez convertiría un detalle en un peaje.

## El idioma

Orbit habla el idioma del sistema. Si tu sesión está en inglés, Orbit está en inglés; si está en español, en español. No hay nada que configurar para el caso normal.

```bash
orbit lang                     qué idioma habla ahora, y cuáles sabe
orbit lang en                  cambiarlo en este servidor, para siempre
orbit --lang en list           sólo para esta orden
export ORBIT_LANG=en           sólo para esta sesión
```

De momento son dos, **español** e **inglés**. El español es el idioma en el que está escrito el programa, así que una frase que todavía no esté traducida sale en español en vez de salir rota.

**De dónde saca el idioma**, de lo más concreto a lo más general:

| | Alcance |
|---|---|
| `orbit --lang en <comando>` | sólo esa orden |
| `ORBIT_LANG=en` en el entorno | esa sesión |
| `ORBIT_LANG="en"` en `/etc/orbit/orbit.conf` | ese servidor — lo escribe `orbit lang` |
| `LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LANG` | tu sesión |
| `/etc/default/locale` o `/etc/locale.conf` | el sistema, cuando no hay entorno |

Que la configuración vaya por delante del `LANG` de tu sesión es a propósito: un servidor que se puso en inglés sigue avisando en inglés a todo el equipo aunque tú entres con el tuyo, y para leerlo en el tuyo tienes la bandera y la variable.

`LANG=C` y `LANG=POSIX` no cuentan como inglés: son «ningún idioma». Es lo que hay dentro de `cron` y de un temporizador de `systemd`, y por eso ahí Orbit mira `/etc/default/locale` — si no, el vigilante y el autodespliegue cambiarían de idioma sólo por no tener entorno.

**Lo que no cambia de idioma:**

- `/var/log/orbit/orbit.log`, que es un registro para leer meses después y filtrar con `grep`.
- Los comentarios de los vhosts y las unidades que Orbit genera.
- Los **nombres de campo** del JSON, que son un contrato. Sus valores en prosa —`error`— sí siguen el idioma; para automatizar están `ok`, `failed_step` y el código de salida.

```bash
orbit --lang en deploy web --json    # el objeto sale igual; el "error", en inglés
```

**El instalador también.** `sudo bash install.sh` habla el idioma del sistema y acepta `--lang`, así que la primera pantalla que ves ya está en el tuyo:

```bash
sudo bash install.sh --lang en
```

## Ficheros importantes

```
/usr/local/bin/orbit                  la herramienta
/etc/orbit/orbit.conf                 configuración global (incluido ORBIT_LANG)
/etc/orbit/apps/<app>.conf            configuración de cada web
/etc/orbit/cloudflare.ini             token de Cloudflare, solo root
/srv/apps/<app>/                      código, releases y datos compartidos
/etc/nginx/sites-available/orbit-*    vhosts generados
/etc/systemd/system/orbit-*.service   servicios de las apps
/var/backups/orbit/                   copias de las bases de datos
/var/log/orbit/orbit.log              historial de despliegues
```
