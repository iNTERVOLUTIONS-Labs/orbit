# Contribuir a Orbit

Gracias por querer echar una mano. Este documento explica cómo trabajar con el proyecto sin sorpresas.

## Antes de escribir código

Para cambios pequeños (un bug, una corrección de documentación) manda el PR directamente.

Para cambios grandes, **abre primero un issue**. Orbit tiene principios de diseño bastante estrictos y sería una lástima que dedicaras un fin de semana a algo que no encaja. Lee la sección de principios en [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) y el apartado "Fuera de alcance" del [ROADMAP.md](ROADMAP.md).

Si vas a quedarte más de un rato, empieza por [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): los principios, las trampas de Bash que ya han costado bugs y lo que las pruebas no ven. [docs/WORKFLOW.md](docs/WORKFLOW.md) es su versión larga, con el ciclo entero.

Los cuatro filtros que aplica cualquier propuesta, en este orden:

1. **¿Sigue siendo desplegar un repositorio de git?** Orbit hace eso y nada más. Cualquier cosa que se instale desde una web, se configure con un asistente y se actualice sola —WordPress, foros, paneles— está fuera, y no por falta de ganas: rompe el modelo de releases inmutables, porque la aplicación escribiría en un directorio que el siguiente despliegue va a sustituir.
2. **¿Añade un demonio o un servicio permanente?** Si la respuesta es sí, casi seguro que no entra.
3. **¿Deja el servidor funcionando si Orbit desaparece?** Si genera estado que solo Orbit entiende, hay que replantearlo.
4. **¿Añade una dependencia nueva?** Cada una necesita una justificación fuerte.

## Preparar el entorno

Necesitas un Ubuntu 24.04. Vale una VM, un contenedor o un VPS de pruebas.

```bash
git clone https://github.com/intervolutions/orbit.git
cd orbit
sudo bash install.sh
```

Para desarrollar sin reinstalar cada vez:

```bash
sudo install -m 0755 orbit /usr/local/bin/orbit
```

## Estilo de código

- **Bash 5** con `set -Eeuo pipefail`. Toda la lógica lo asume.
- **Sangría de 2 espacios**, nunca tabuladores.
- **Funciones privadas con guion bajo**: `_body_static`, `_q`, `_json_keys`.
- **`local` en todas las variables de función.** Sin excepciones: una variable de bucle sin `local` pisa la del que llama, y ya ha causado un bug.
- **Comillas siempre** salvo cuando quieras división de palabras a propósito, y en ese caso pon un comentario.
- **Mensajes y comentarios en castellano.** Los nombres de funciones y variables, en inglés.
- **Sin dependencias nuevas** que no instale `install.sh`.

## Antes de mandar el PR

```bash
make test     # sintaxis + shellcheck + las cuatro suites
```

`shellcheck -S warning` debe salir **limpio**, sin una sola línea. Si necesitas una excepción, ponle una directiva `# shellcheck disable=SCxxxx` con un comentario que explique por qué.

Las pruebas no necesitan servidor, ni root, ni el usuario `deploy`, y no tocan nada del sistema. `nginx_test.sh` y `deploy_test.sh` se saltan solas si falta `nginx` o `rsync`; instálalos si vas a tocar esas partes:

```bash
sudo apt-get install -y shellcheck nginx-light rsync
```

Además:

- Si tocas **`nginx_vhost`**: `tests/nginx_test.sh` ya valida con `nginx -t` y sirve las dos ramas, con certificado y sin él. Añade tu caso ahí.
- Si tocas **`detect_stack`**: añade el fixture a `tests/detect_test.sh`.
- Si tocas el **flujo de despliegue**: `tests/deploy_test.sh` lo ejercita entero contra un repo git local.
- Si tocas **`save_app`** o el formato de configuración: comprueba la ida y vuelta con un valor que contenga `${VARIABLE}` y comillas simples, **y busca quién más lee ese fichero con `grep` o `sed`**. Cambiar el formato sin revisar a los lectores ya costó el bug de los puertos duplicados.

Cuando encuentres un fallo, escribe primero la prueba que lo detecta. Debe fallar antes del arreglo.

## Versionado

**Cada PR sube la versión un parche.** Sin excepciones ni juicios de tamaño: un
PR de una línea y uno de mil suben lo mismo, porque la versión aquí responde a
«¿qué build es éste?», no a «¿cuánto cambió?».

- El número vive en **una sola línea de `orbit`** (`ORBIT_VERSION="X.Y.Z"`,
  justo después de cargar la configuración). `install.sh` lo extrae de ahí:
  no hay un segundo sitio que actualizar.
- El parche sube en uno: `1.0.1` → `1.0.2`.
- **El parche nunca pasa de 9.** Después de `X.Y.9` viene `X.(Y+1).0`:
  `1.0.9` → `1.1.0`. Lo mismo hacia arriba: tras `X.9.9`, `(X+1).0.0`.
- El mismo PR estrena la entrada de esa versión en `CHANGELOG.md` (lo que
  estuviera en «No publicado» pasa a la versión nueva, con fecha).

## Trampas conocidas

Están documentadas en [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), sección 10, pero las repito porque muerden:

- `shopt -s nullglob` está activo. Un `grep patrón "$dir"/*.cfg` sin ficheros se queda leyendo de stdin **para siempre**.
- `ls` con un glob vacío lista el directorio actual. Usa `find`.
- `printf '%-9s'` cuenta bytes, no caracteres. Los acentos descuadran las columnas.
- Con `set -u`, indexar un array fuera de rango aborta el script.

## Mensajes de commit

Formato convencional, en inglés:

```
fix(deploy): do not export NODE_ENV during build
feat(detect): add SvelteKit support
docs(architecture): explain the redirect loop guard
```

Tipos: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.

## Añadir soporte para un stack nuevo

Es la contribución más útil y la más fácil de empezar. Cuatro pasos:

1. En `detect_stack()`, añade la rama de detección. Cuidado con el orden: los indicadores se solapan y el primero que coincide gana.
2. Decide si es `static`, `node`, `php` o `python`. Si necesita un tipo nuevo, hará falta una función `_body_*` en la parte de nginx.
3. Define `A_BUILD` y, si es un proceso, `A_START`. Recuerda que `NODE_ENV` no está definido durante el build, a propósito.
4. Añade el caso a `tests/detect_test.sh` con un `package.json` mínimo.

## Reportar errores

Usa la plantilla de issue. Incluye siempre la salida de `orbit doctor`: ahorra tres mensajes de ida y vuelta.

Si es un fallo de despliegue, pega la salida completa del build, no solo la última línea. La causa real suele estar arriba del todo, como pasó con el error de PostCSS que en realidad era `NODE_ENV`.

## Vulnerabilidades de seguridad

No abras un issue público. Lee [SECURITY.md](SECURITY.md).

## Licencia

Al contribuir aceptas que tu código se publique bajo la licencia MIT del proyecto.
