# Instalación paso a paso

Escrito para alguien que nunca ha configurado un servidor. Si ya sabes lo que haces, el resumen es: clona el repo, `sudo bash install.sh`, `orbit github`, `orbit cf-token`, `orbit new`.

## Lo que necesitas

- Un VPS con **Ubuntu 24.04 LTS** recién creado. Vale cualquier proveedor: OVH, Hetzner, DigitalOcean, Contabo. **Debian 12** también vale: el instalador se adapta solo, y desde la v1.3.3 está instalado de principio a fin en una máquina Debian de verdad —los trece pasos, una app con proceso levantada por systemd, unattended-upgrades trayendo parches— y reiniciado desde la v1.3.4, volviendo solo.
- Al menos **1 GB de RAM**. Con 2 GB o más vas holgado si compilas proyectos Next en el servidor.
- Un **dominio** y acceso a su DNS.
- Una cuenta de **Cloudflare**. Es gratis y opcional, pero te simplifica mucho la vida.

Anota la **IP del servidor** que te ha dado tu proveedor. Va a aparecer varias veces.

---

## Paso 1 · Entrar en el servidor

Abre una terminal en tu ordenador. En Windows sirve PowerShell, en Mac y Linux la app Terminal.

```bash
ssh root@TU-IP
```

Sustituye `TU-IP` por la de tu servidor. Te pedirá la contraseña que te dio el proveedor.

La primera vez te preguntará si confías en el servidor. Escribe `yes` y pulsa Enter.

> Si tu proveedor te da un usuario distinto de root, por ejemplo `ubuntu`, usa ese y añade `sudo` delante de los comandos de instalación.

---

## Paso 2 · Descargar Orbit

```bash
cd /root
git clone https://github.com/intervolutions/orbit.git
cd orbit
```

Si el servidor no trae git todavía:

```bash
apt update && apt install -y git
```

---

## Paso 3 · Ejecutar el instalador

```bash
bash install.sh
```

Tarda entre 5 y 10 minutos. Verás pasar 13 pasos.

Qué instala y para qué:

| Componente | Para qué sirve |
|---|---|
| nginx | El servidor web que atiende a los visitantes |
| Node.js 22 + pnpm | Para compilar y correr tus proyectos React, Next y Astro |
| PostgreSQL | Bases de datos |
| PHP 8.3 FPM + Composer | Para tus scripts en PHP |
| Python 3 + venv | Para tus scripts en Python |
| Certbot | Certificados HTTPS gratis de Let's Encrypt |
| GitHub CLI | Conexión con tu cuenta de GitHub |
| UFW + fail2ban | Cortafuegos y bloqueo de intentos de intrusión |
| 4 GB de swap | Para que los builds grandes no se queden sin memoria |

Al terminar verás un recuadro verde con el resumen. **Esto se hace una sola vez en la vida del servidor.**

---

## Paso 4 · Conectar tu cuenta de GitHub

```bash
orbit github
```

Te mostrará un código de ocho caracteres, tipo `AB12-CD34`.

1. Cópialo
2. Abre `https://github.com/login/device` en el navegador de tu ordenador
3. Pega el código y autoriza

Vuelve a la terminal y verás la confirmación.

Esto es lo que permite a Orbit listarte tus repositorios y clonar los privados.

---

## Paso 5 · Guardar tu token de Cloudflare

Primero hay que crearlo. En tu navegador:

1. Entra en `https://dash.cloudflare.com/profile/api-tokens`
2. Pulsa **Create Token**
3. Elige la plantilla **Edit zone DNS** y pulsa "Use template"
4. En *Zone Resources* selecciona **Include → All zones**
5. **Continue to summary** y luego **Create Token**
6. Copia el token. Solo se muestra una vez.

Ahora en el servidor:

```bash
orbit cf-token
```

Pega el token cuando te lo pida.

**Por qué hace falta:** para emitir certificados HTTPS validando por DNS. Es el método bueno, porque funciona con el proxy de Cloudflare activado sin que tengas que desactivar nada.

---

## Paso 6 · Configurar el dominio en Cloudflare

Esto se hace **una vez por cada dominio**.

En el panel de Cloudflare, dentro del dominio, ve a **DNS → Records** y crea:

| Type | Name | Content | Proxy status |
|---|---|---|---|
| A | `@` | tu IP | Proxied (nube naranja) |
| A | `www` | tu IP | Proxied (nube naranja) |

Después ve a **SSL/TLS → Overview** y pon el modo en **Full (strict)**.

> Esto importa. Si lo dejas en "Flexible", Cloudflare hablará con tu servidor sin cifrar. Orbit trae una protección para que aun así no entres en un bucle de redirecciones, pero la configuración correcta es Full (strict).

Opcional y recomendable: en **SSL/TLS → Edge Certificates**, activa **Always Use HTTPS**.

---

## Paso 7 · Desplegar tu primera web

```bash
orbit new
```

O abre el menú con `orbit` y elige la opción 1. Hacen lo mismo.

Te preguntará, en este orden:

1. **Origen del código** → "Elegir un repo de mi GitHub"
2. **Repositorio** → se abre un buscador, escribe unas letras y pulsa Enter
3. **Nombre corto de la app** → te propone uno, acepta con Enter
4. **Rama** → normalmente `main`
5. **Dominio principal** → `midominio.com`, sin `https://` y sin `www`
6. **Dominios extra** → te propone `www.midominio.com`, acepta con Enter

Entonces clona el repo y te enseña lo que ha detectado:

```
Detección automática
  Tipo        next
  Gestor      pnpm
  Build       pnpm install --frozen-lockfile --prod=false && pnpm run build
  Start       pnpm run start
```

Si está bien, responde `s`. Si no, responde `n` y lo defines tú.

Después:

- **¿Crear base de datos PostgreSQL?** Si tu app la necesita, di que sí. Crea usuario y base, y escribe la `DATABASE_URL` en el `.env` automáticamente.
- **¿Editar el .env?** Di que sí si necesitas claves de API u otras variables. Se abre `nano`: escribe, luego `Ctrl+O`, `Enter`, `Ctrl+X`.
- Compila y arranca la web.
- **¿Emitir certificado HTTPS?** Di que sí.

Cuando termine:

```
✔ mi-web desplegada  →  https://midominio.com
```

Ábrelo en el navegador. Ya está.

---

## Paso 8 · Asegurar el acceso SSH

Este paso es opcional pero muy recomendable. Elimina la posibilidad de que alguien adivine tu contraseña.

**En tu ordenador**, si no tienes clave SSH todavía:

```bash
ssh-keygen -t ed25519
ssh-copy-id root@TU-IP
```

Comprueba que puedes entrar sin que te pida contraseña:

```bash
ssh root@TU-IP
```

**Solo cuando estés seguro de que funciona**, en el servidor:

```bash
nano /etc/ssh/sshd_config
```

Busca y cambia estas dos líneas:

```
PasswordAuthentication no
PermitRootLogin prohibit-password
```

Guarda con `Ctrl+O`, `Enter`, `Ctrl+X`, y aplica:

```bash
systemctl restart ssh
```

> **No hagas esto sin haber comprobado antes que entras con la clave.** Si te equivocas, te quedas fuera del servidor y hay que recuperarlo desde el panel del proveedor.

### Blindaje adicional

Si todos tus dominios pasan por Cloudflare:

```bash
orbit firewall lock
```

Con esto los puertos 80 y 443 solo aceptan conexiones desde los rangos de Cloudflare. Nadie llega a tu servidor escribiendo la IP, y desaparecen los escaneos automáticos.

Si algún dominio está en "DNS only" (nube gris), dejará de funcionar. Para deshacerlo: `orbit firewall unlock`.

---

## Comprobar que todo está bien

```bash
orbit doctor
```

Revisa nginx, PostgreSQL, pnpm, la conexión con GitHub, el token de Cloudflare, el disco, y para cada web si nginx la sirve, si su proceso está vivo, si está en mantenimiento, si el DNS resuelve y cuándo caduca su certificado.

Lo que puede arreglar solo lo arregla con `orbit doctor --fix`. Lo que no —porque decidirlo es tuyo, como qué borrar de un disco lleno o si levantar una web que alguien bajó a propósito— te lo dice y no lo toca.

---

## Siguiente paso

Lee [USAGE.md](USAGE.md) para el día a día, o [TROUBLESHOOTING.md](TROUBLESHOOTING.md) si algo no va.
