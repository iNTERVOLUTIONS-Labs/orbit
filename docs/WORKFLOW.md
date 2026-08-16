# Orbit · el ciclo de trabajo

> La versión larga de [DEVELOPMENT.md](DEVELOPMENT.md): cómo se elige qué construir, cómo se prueba y qué no se da por terminado. Está escrita para quien coge el proyecto y va a trabajar en él durante semanas, no para arreglar una errata.

---

**Orbit** es una plataforma de despliegue en Bash para VPS de Ubuntu 24.04. El trabajo no es esperar instrucciones: es que Orbit sea mejor, ciclo tras ciclo, decidiendo qué merece la pena construir.

## Antes de escribir una sola línea

Lee estos ficheros en este orden. No los ojees, léelos:

1. `docs/ARCHITECTURE.md` — cómo está construido y **por qué**. La sección 10 lista trampas de Bash que ya han causado bugs reales.
2. `ROADMAP.md` — lo planificado y, más importante, la sección "Fuera de alcance".
3. `CHANGELOG.md` — errores ya cometidos. No los repitas.
4. `orbit` completo. Son ~1.200 líneas. Léelas todas antes de tocar nada.
5. `install.sh` y las suites de `tests/`, empezando por `tests/lib.sh`.

Cuando termines, resume por escrito qué has entendido del modelo de despliegue y qué te preocupa. Si algo no te cuadra, dilo antes de empezar: casi todas las decisiones raras tienen un bug detrás, y preguntar sale más barato que deshacerlas.

---

## Principios innegociables

Cualquier cosa que hagas debe respetarlos. Si una funcionalidad los rompe, la funcionalidad se rediseña o se descarta.

1. **Orbit despliega repositorios de git, y nada más.** Coges un repo, se compila, se sirve y se mantiene actualizado. Nunca propongas soportar aplicaciones que se instalan desde una web y se actualizan solas —WordPress, foros, paneles—: el modelo de releases inmutables con symlink es **incompatible** con una aplicación que se modifica a sí misma, porque el siguiente despliegue borraría lo que ella escribió. Si una idea obliga a relajar ese modelo, se descarta. Esta regla manda sobre las demás.

2. **Sin demonios residentes.** Orbit se ejecuta, hace su trabajo y termina. Un temporizador de systemd que invoca `orbit <algo>` cada minuto **sí es aceptable**: no es un proceso vivo que Orbit tenga que mantener, es el sistema operativo llamando a un script. Un proceso Node escuchando en un puerto para recibir webhooks está en el límite y necesita justificación explícita.

3. **Si Orbit desaparece, el servidor sigue funcionando.** Todo lo que generas son artefactos estándar: vhosts de nginx, unidades de systemd, certificados de certbot, cron. Nunca inventes un formato que solo Orbit sepa leer para algo que el sistema ya sabe hacer.

4. **Fallar antes de tocar producción.** El build en una carpeta nueva, el symlink al final, `nginx -t` antes de recargar. Si tu cambio introduce un punto donde un fallo deja la web caída, está mal diseñado.

5. **Todo legible con `cat`.** Nada binario, nada de estado oculto.

6. **Sin dependencias nuevas** salvo justificación fuerte y añadidas a `install.sh`.

7. **Seguro por defecto.** No existe un modo inseguro que sea más cómodo.

---

## Tu ciclo de trabajo

Repítelo indefinidamente. Un ciclo = una funcionalidad terminada.

### 1 · Elegir

Coge lo siguiente del backlog, o propón algo mejor si lo ves. Justifica la elección en dos frases: qué problema real resuelve y a quién.

Prioriza por: dolor que quita > frecuencia de uso > esfuerzo. Una funcionalidad que ahorra media hora cada semana vale más que una espectacular que se usa una vez al año.

### 2 · Diseñar antes de teclear

Escribe, antes del código:
- Qué comandos nuevos aparecen y con qué sintaxis
- Qué ficheros se crean o modifican en el servidor
- Qué pasa si falla a mitad
- Qué pasa si el usuario lo ejecuta dos veces (**todo debe ser idempotente**)
- Cómo se prueba sin un servidor de producción

Si el diseño choca con un principio, párate y replantea. No lo fuerces.

### 3 · Implementar

Sigue las convenciones de `CONTRIBUTING.md`. En resumen:
- Bash 5, `set -Eeuo pipefail`, 2 espacios
- `local` en **todas** las variables de función, sin excepción
- Funciones privadas con guion bajo inicial
- Mensajes al usuario y comentarios en castellano; nombres de funciones y variables en inglés
- Todo lo que ejecute código de usuario pasa por `sudo -u "$DEPLOY_USER"`
- Cualquier campo nuevo de configuración se serializa con `_q()`

### 4 · Probar de verdad

Nunca pruebes en un servidor de producción. Levanta un contenedor o una VM de Ubuntu 24.04.

Obligatorio en cada ciclo:

```bash
bash -n orbit && bash -n install.sh
shellcheck -S warning -s bash orbit install.sh tests/*.sh
bash tests/detect_test.sh
```

Según lo que toques:

- **`render_nginx`** → genera el vhost, `nginx -t`, arranca nginx y haz `curl` con cabecera `Host`. Prueba las dos ramas, con certificado y sin él. Y comprueba la no regresión del bucle de redirecciones:
  ```bash
  curl -sI -H 'Host: x.test' http://127.0.0.1/                              # 301
  curl -s  -H 'Host: x.test' -H 'X-Forwarded-Proto: https' http://127.0.0.1/ # sirve, NO redirige
  ```
- **`detect_stack`** → añade el caso a `tests/detect_test.sh` con un `package.json` mínimo. Y comprueba **qué pasa cuando no coincide nada**: la rama de repuesto deja `A_TYPE=static` con `A_OUTDIR="."`, o sea nginx sirviendo la raíz del repositorio. Para un sitio que es HTML eso está bien; para un stack nuevo significa publicar el código fuente y el `.env` (§18.8). Ante la duda, con proceso: un despliegue que falla en voz alta es mejor que uno que sale bien y enseña los secretos
- **flujo de despliegue** → prueba de principio a fin con un repo git local como origen, sustituyendo `systemctl` por una función vacía si el contenedor no tiene systemd
- **`save_app` o el formato de configuración** → prueba ida y vuelta con un valor que contenga `${VARIABLE}` y comillas simples

Cuando encuentres un bug, **antes de arreglarlo escribe la prueba que lo detecta**. Luego arréglalo y comprueba que la prueba pasa.

### 5 · Autoevaluar

Puntúa tu propio trabajo sobre 100 con esta rúbrica. **Si no llegas a 90, itera antes de dar el ciclo por terminado.** Sé duro contigo mismo: un 85 disfrazado de 92 solo perjudica al proyecto.

| Criterio | Peso | Qué se evalúa |
|---|---|---|
| Corrección | 25 | ¿Hace lo que dice? ¿Probado de verdad, no "debería funcionar"? |
| Robustez | 20 | ¿Idempotente? ¿Qué pasa si falla a mitad? ¿Y si el usuario mete basura? |
| Coherencia | 15 | ¿Encaja con los principios y el estilo existente, o parece pegado con cinta? |
| Seguridad | 15 | ¿Amplía la superficie de ataque? ¿Escala privilegios? ¿Filtra secretos? |
| Documentación | 15 | ¿Están actualizados USAGE, ARCHITECTURE, CHANGELOG y ROADMAP? |
| Experiencia de uso | 10 | ¿Es obvio cómo se usa? ¿Los mensajes de error dicen qué hacer? |

Escribe la puntuación con una frase por criterio explicando por qué. Si algo baja de 90, di exactamente qué vas a cambiar y hazlo.

### 6 · Documentar y cerrar

Ningún ciclo termina sin:
- `docs/USAGE.md` con los comandos nuevos
- `docs/ARCHITECTURE.md` si has cambiado un modelo o has tomado una decisión de diseño relevante, incluyendo el **por qué**
- `docs/TROUBLESHOOTING.md` si has descubierto un fallo confuso
- `CHANGELOG.md` en la sección Unreleased
- `ROADMAP.md` marcando lo hecho
- Un commit con formato convencional: `feat(deploy): add --all to deploy every app in one pass`

### 7 · Reflexionar

Antes del siguiente ciclo, contesta:
- ¿Qué he aprendido que debería estar documentado y no lo está?
- ¿Qué me ha costado más de lo que debería? Eso suele señalar una abstracción que falta.
- ¿He añadido deuda técnica? ¿Dónde?
- ¿Qué haría distinto?

Y entonces vuelve al paso 1.

---

## Backlog prioritario

Todo lo que hay aquí es desplegar repositorios de git mejor. Si se te ocurre algo que no encaje en esa frase, no pertenece a este backlog.

### A · Django en condiciones

Ahora mismo el soporte de Python es genérico y se queda corto. Django necesita:

- Detectar `manage.py` y `settings.py`, no solo `requirements.txt`
- `collectstatic` en el build, con nginx sirviendo `/static/` y `/media/` directamente desde disco. Que Django sirva estáticos en producción es un error de rendimiento clásico.
- `migrate` como paso separado y explícito. **Nunca lo ejecutes automáticamente sin avisar**: una migración destructiva en un despliegue automático es una forma excelente de perder datos. Ofrécelo como confirmación o como comando aparte.
- Elegir entre WSGI con gunicorn y ASGI con uvicorn según haya `asgi.py` y dependencias como Channels
- Detectar el módulo del proyecto en vez de asumir `app:app`
- `ALLOWED_HOSTS` y `CSRF_TRUSTED_ORIGINS` avisados o preconfigurados con el dominio
- Soporte para `pyproject.toml` con Poetry o uv, no solo `requirements.txt`

Mismo tratamiento para Flask y FastAPI, que son más simples pero comparten el 80 %.

### B · Redirecciones

Dos casos distintos, no los mezcles:

**Redirección de dominio entero.** `orbit redirect add viejo.com https://nuevo.com`. Genera un vhost dedicado que solo redirige, con su propio certificado. Sirve para dominios comprados por defensa de marca o migraciones.

**Redirecciones por ruta dentro de una app.** `orbit redirect add mi-web /precios /pricing`. Guárdalas en un fichero por app y renderízalas dentro del vhost al desplegar. Decide y documenta:
- 301 permanente por defecto, 302 con un flag
- Conservar o no la cadena de consulta
- Soporte para comodines y expresiones regulares
- Orden de evaluación: las más específicas primero

`orbit redirect list|rm` para completarlo. Las redirecciones deben sobrevivir a `orbit deploy` y a `orbit nginx-rebuild`.

### C · Alias y subdominios

Ya existe `A_ALIASES` pero es de segunda categoría. Elévalo:

- `orbit alias add mi-web tienda.midominio.com` y su `rm`, que regeneren el vhost y **reemitan el certificado incluyendo el alias nuevo**. Olvidar esto último es el fallo más probable aquí.
- Decidir si un alias sirve el mismo contenido o redirige al dominio canónico. Casi siempre se quiere lo segundo para SEO: `www` redirigiendo al dominio raíz o al revés. Hazlo configurable con un valor por defecto sensato y explica por qué en la documentación.
- **Certificados comodín**: con DNS-01 se puede pedir `*.midominio.com`. Eso permite crear subdominios sin emitir un certificado nuevo cada vez, y es la base para entornos de staging automáticos.
- `orbit clone mi-web staging` que duplique la app en `staging.midominio.com`, con su propia base de datos copiada y **protegida con autenticación básica** para que no la indexe Google.

### D · Watchdog

Que un proceso caído se note antes de que lo note un cliente.

**Implementación: temporizador de systemd que invoca `orbit watch` cada minuto.** No un demonio. Esto respeta el principio 1 y lo dices explícitamente en la documentación.

Qué debe comprobar:
- Cada app con proceso responde en su puerto interno
- nginx, PostgreSQL y php-fpm están vivos
- El disco no supera un umbral configurable
- Ningún certificado caduca en menos de 10 días
- La memoria no está en zona crítica

Qué debe hacer cuando algo falla:
- Reiniciar el servicio caído
- **Protección contra bucles**: si una app se ha reiniciado 3 veces en 10 minutos, deja de intentarlo, márcala como caída y avisa. Un watchdog que reinicia en bucle una app rota es peor que no tener watchdog.
- Guardar estado entre ejecuciones en un fichero simple bajo `/var/lib/orbit/`
- Notificar por webhook genérico, Telegram, Discord o correo. Diseña una capa de notificación reutilizable, porque la vas a querer también para avisar de despliegues fallidos.
- Registrar todo en un log consultable con `orbit watch --history`

`orbit watch --once` para ejecutarlo a mano y `orbit watch enable|disable` para el temporizador.

---

## Ideas para evaluar tú mismo

No están priorizadas. Estúdialas, descarta las que no encajen y justifica por qué. Algunas valen mucho más de lo que parecen.

**Purga de caché de Cloudflare al desplegar.** Tres líneas de API y elimina el "he desplegado pero sigo viendo lo viejo". Barato y muy agradecido.

**`orbit exec <app> <comando>`.** Ejecutar algo con el `.env` de la app cargado y en su directorio. Imprescindible para migraciones, seeds y depuración. Probablemente sea la funcionalidad con mejor relación valor/esfuerzo de toda la lista.

**Reinicio sin corte.** Levantar el proceso nuevo en un puerto distinto, esperar a que responda, cambiar el `upstream` de nginx y recargar, y solo entonces matar el viejo. Elimina el hueco de uno o dos segundos.

**Página de mantenimiento.** Un HTML estático que nginx sirve con código 503 mientras dura un despliegue largo o una migración.

**Aislamiento por aplicación.** Un usuario de sistema por app en vez de un `deploy` compartido. Mejora la seguridad de forma notable pero complica permisos y copias. Analiza si el coste vale la pena y documenta la conclusión sea cual sea.

**`orbit backup` completo y `orbit restore`.** Ahora solo se copian las bases de datos. Faltan los `.env`, la configuración, el contenido de `shared/` y una restauración de servidor entero en un comando. Y subida opcional a almacenamiento externo, porque una copia que vive en el mismo disco que los datos no es una copia.

**Cron por aplicación.** `orbit cron add mi-web "0 3 * * *" "node scripts/limpiar.js"` generando temporizadores de systemd. Muchas apps lo necesitan y ahora hay que hacerlo a mano.

**`orbit doctor --fix`.** Que además de detectar arregle lo que sea seguro arreglar.

**`orbit top`.** Panel en terminal con CPU, memoria y peticiones por app.

**Despliegue por webhook.** Push a main y se despliega solo. Es lo que más se pide y lo que más tensiona el principio 1. Explora alternativas antes de meter un servidor HTTP: un temporizador que consulte GitHub cada minuto es feo pero respeta el principio, y para un VPS personal la latencia de un minuto no molesta a nadie. Analiza las dos opciones y decide con argumentos.

**Soporte de Docker.** Si el repo trae `Dockerfile`, construir y correr el contenedor con nginx delante. Amplía muchísimo el alcance sin romper nada de lo existente.

**Compresión Brotli.** Requiere módulo de nginx. Mide si compensa antes de añadir la complejidad.

**Rotación y consulta de logs de aplicación.** journald ya rota, pero `orbit logs --since` y una vista agregada de todas las apps serían útiles.

**Idioma.** Hecho: Orbit habla español e inglés y detecta cuál según el sistema. La clave de traducción es la propia frase en español —el modelo de gettext, sin gettext— así que un mensaje nuevo sin traducir sale en español y no rompe nada. Lo que sí obliga: las partes variables van fuera de la frase (`die "La app '%s' no existe." "$n"`), los colores se escriben `{b}` `{r}` y no `${B}`, y un `%` literal se escribe `%%`. Ver ARCHITECTURE §21. `install.sh` también habla los dos: no copia el núcleo, lo saca de `orbit` con `sed` entre dos marcas (§21.6b), así que si tocas ese bloque no lo saques de entre las marcas.

---

## Cómo comportarte

**Trabaja en ciclos completos.** No dejes tres funcionalidades a medias. Una terminada, probada y documentada vale más que cinco al 70 %.

**Sé escéptico con tu propio código.** "Debería funcionar" no es haberlo probado. Si no lo has ejecutado, no está hecho.

**Cuando algo te sorprenda, investiga hasta entenderlo.** El bug de `NODE_ENV` que rompía las devDependencies parecía un error de PostCSS y era otra cosa completamente distinta. La primera explicación que se te ocurra probablemente sea incorrecta.

**Documenta el por qué, no el qué.** El código ya dice qué hace. ARCHITECTURE.md existe para explicar por qué se eligió eso y no la alternativa obvia.

**Sé honesto sobre los límites.** Si una funcionalidad tiene una contrapartida, escríbela en la documentación. Un proyecto que avisa de sus puntos débiles genera más confianza que uno que los esconde.

**No añadas complejidad sin pelearla.** Cada línea de Bash es una línea que alguien tendrá que entender a las tres de la mañana con una web caída.

**Si un cambio choca con un principio, dilo y propón alternativas.** No lo metas a la fuerza ni lo abandones en silencio.

**Sobre CI:** no dependas de GitHub Actions para validar. Ejecuta las pruebas en local y da por bueno el trabajo tú mismo.

---

## Formato de cada entrega

Al terminar un ciclo, en la descripción del PR:

1. **Qué has construido** y qué problema resuelve, en dos frases
2. **Decisiones de diseño** que has tomado y las alternativas que descartaste
3. **Cómo lo has probado**, con los comandos exactos y su salida
4. **Autoevaluación** con la rúbrica y la puntuación por criterio
5. **Qué sigue** y por qué has elegido eso para el próximo ciclo

Y entonces vuelve al paso 1.
