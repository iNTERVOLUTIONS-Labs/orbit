# Política de seguridad

## Versiones con soporte

| Versión | Soporte |
|---|---|
| 1.0.x | Sí |
| < 1.0 | No |

## Reportar una vulnerabilidad

**No abras un issue público.**

Escribe a **security@intervolutions.com** con:

- Descripción del problema
- Pasos para reproducirlo
- Impacto que estimas
- Si tienes una idea de arreglo, mejor

Recibirás respuesta en un plazo de 72 horas. Si es una vulnerabilidad real, se publicará un arreglo y se te dará crédito en el changelog salvo que prefieras lo contrario.

## Modelo de amenazas

Conviene ser explícito sobre qué protege Orbit y qué no.

### Sí protege

- Exposición a internet reducida a los puertos 22, 80 y 443
- Bases de datos y procesos de aplicación escuchando solo en localhost
- El código de las apps nunca corre como root
- Endurecimiento de systemd: `ProtectSystem=strict`, `NoNewPrivileges`, `ProtectHome`
- Fuerza bruta contra SSH mitigada con fail2ban
- Parches de seguridad del sistema aplicados automáticamente
- Ficheros sensibles (`.env`, `.git/`, volcados SQL) devuelven 403
- TLS moderno con HSTS
- `orbit firewall lock` restringe el origen a los rangos de Cloudflare

### No protege

Estos son límites conocidos y aceptados del diseño actual:

- **Las apps no están aisladas entre sí.** Todas corren como el usuario `deploy`, así que una app comprometida puede leer el `.env` de otra. El aislamiento por usuario está en el roadmap.
- **El código que despliegas se ejecuta con los permisos de `deploy` durante el build.** Orbit no audita tus dependencias. Una cadena de suministro comprometida en tu `package.json` se ejecutará.
- **Los secretos están en texto plano** en `shared/.env`, con permisos `0640`. No es una bóveda.
- **Orbit necesita root.** Un fallo en el propio script tiene consecuencias graves. Por eso el código intenta ser corto y legible.

### Recomendaciones para producción

1. Desactiva la autenticación por contraseña en SSH y usa solo claves
2. Ejecuta `orbit firewall lock` si todos tus dominios pasan por Cloudflare
3. Mantén Cloudflare en modo **Full (strict)**
4. Revisa `orbit doctor` de vez en cuando
5. Comprueba que las copias de `/var/backups/orbit` se están generando, y llévatelas fuera del servidor
6. No despliegues código en el que no confíes
