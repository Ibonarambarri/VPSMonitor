# Instalación de VPS Monitor Web

Esta guía describe el despliegue de la PWA con Docker Compose, especialmente como recurso de Coolify, y su instalación posterior en un iPhone.

## 1. Decidir dónde alojarlo

El Compose incluido ejecuta dos servicios:

- `web`, que sirve la PWA, consulta Coolify y genera alertas.
- `node-exporter`, que lee las métricas del host Linux donde se ejecuta el stack.

Por tanto, el panel muestra las métricas del host de Docker. No establece una conexión SSH con otro servidor.

### Limitación al usar el mismo VPS

Alojar el monitor en el VPS vigilado es sencillo y permite obtener sus métricas directamente, pero comparte el mismo punto de fallo. Si el host pierde energía, red, almacenamiento, Docker o el proxy HTTPS, el panel dejará de responder y no podrá enviar una notificación sobre esa caída total.

Para una vigilancia completa:

- Mantén este panel para métricas e incidencias de Coolify.
- Añade una comprobación externa del origen HTTPS y de los servicios realmente importantes.
- Sitúa esa comprobación en otra infraestructura y con un canal de avisos independiente.

El dashboard local no sustituye a un monitor externo de disponibilidad.

## 2. Requisitos

- Host Linux con Docker y Docker Compose, o una instalación de Coolify.
- Repositorio accesible por el sistema de despliegue.
- Origen HTTPS exclusivo para el panel.
- Token Coolify con permiso `read`, sin `read:sensitive`, `write`, `deploy` ni `root`.
- Contraseña administradora única de al menos 12 caracteres; se recomienda una longitud mayor.
- Node.js 24 en la máquina usada para generar el hash y ejecutar pruebas.

La PWA y las cookies seguras requieren HTTPS en producción. HTTP solo está admitido por la configuración durante desarrollo local.

## 3. Preparar la configuración

Entra en el directorio `Web` e instala las dependencias bloqueadas:

```bash
cd Web
npm ci
```

Usa `.env.example` únicamente como esquema. Para un despliegue local con Compose puedes copiarlo a `.env` y sustituir todos sus marcadores:

```bash
cp .env.example .env
```

No confirmes `.env` en Git ni pegues su contenido en incidencias o registros públicos.

### Generar el hash de contraseña

El servidor no acepta una contraseña en texto claro dentro de la configuración. Genera un hash `scrypt` desde `Web`:

```bash
read -s ADMIN_PASSWORD
export ADMIN_PASSWORD
node --input-type=module -e 'import { hashPassword } from "./src/auth.js"; console.log(await hashPassword(process.env.ADMIN_PASSWORD))'
unset ADMIN_PASSWORD
```

Introduce la contraseña cuando el shell quede esperando. Guarda solamente la salida del hash en `ADMIN_PASSWORD_HASH`.

### Generar el secreto de sesión

Genera al menos 32 bytes aleatorios con una herramienta criptográfica del sistema y guarda el resultado en `SESSION_SECRET`. El secreto debe ser diferente de la contraseña y no debe reutilizarse en otros servicios.

Cambiar `SESSION_SECRET` invalida todas las sesiones existentes. Cambiar el hash de contraseña también invalida las cookies emitidas con el hash anterior.

### Generar las claves Web Push

Después de `npm ci`:

```bash
npx --no-install web-push generate-vapid-keys
```

Guarda las salidas en `VAPID_PUBLIC_KEY` y `VAPID_PRIVATE_KEY`. Define también `VAPID_SUBJECT` con un contacto válido en formato `mailto:` o un origen HTTPS controlado por el responsable del servicio.

La clave privada VAPID es un secreto. No la entregues al navegador ni la publiques en Git.

## 4. Variables obligatorias

| Variable | Contenido esperado |
| --- | --- |
| `APP_ORIGIN` | Origen HTTPS público exacto del panel, sin ruta, query ni fragmento. |
| `SERVER_NAME` | Alias no sensible que se mostrará en la interfaz. |
| `ADMIN_PASSWORD_HASH` | Hash `scrypt` generado con el comando anterior. |
| `SESSION_SECRET` | Secreto aleatorio independiente de al menos 32 caracteres. |
| `COOLIFY_BASE_URL` | URL base HTTPS de la API de Coolify. El sufijo de API se añade internamente. |
| `COOLIFY_API_TOKEN` | Token limitado a lectura. |
| `COOLIFY_DASHBOARD_URL` | URL HTTPS que abrirá el botón **Abrir Coolify**. |
| `VAPID_PUBLIC_KEY` | Clave pública de Web Push. |
| `VAPID_PRIVATE_KEY` | Clave privada de Web Push. |
| `VAPID_SUBJECT` | Contacto `mailto:` u origen HTTPS del emisor. |

Compose proporciona valores conservadores para intervalo de muestreo, historial, duración de sesión y recursos de contenedor. Revisa `docker-compose.yaml` y `src/config.js` antes de cambiar parámetros avanzados.

`APP_ORIGIN` debe coincidir exactamente con el origen que ve el navegador. Una diferencia de esquema, host o puerto hará que el servidor rechace el login y las operaciones de escritura.

## 5. Validar antes del despliegue

Con las variables preparadas:

```bash
npm test
npm audit --omit=dev
docker compose config --quiet
docker build --file Dockerfile --tag vpsmonitor-web:local .
```

La validación de Compose confirma interpolación y sintaxis, pero no sustituye la validación que el servicio realiza al arrancar.

## 6. Desplegar como recurso de Coolify

Los nombres exactos de las opciones pueden variar entre versiones de Coolify, pero el flujo es:

1. Crea un recurso **Docker Compose** conectado al repositorio.
2. Selecciona `Web` como directorio base.
3. Selecciona `docker-compose.yaml` como archivo Compose.
4. Añade las variables de la tabla anterior desde el almacén de secretos de Coolify.
5. Asocia el origen HTTPS al servicio `web` y a su puerto interno `3000`.
6. No publiques el puerto de `node-exporter` ni lo asocies a un origen público.
7. Conserva el volumen `vpsmonitor-data` entre despliegues.
8. Despliega y espera a que el servicio `web` aparezca como saludable.

El Compose usa `expose`, no una publicación directa de puertos. El tráfico público debe llegar únicamente a `web` a través del proxy HTTPS administrado por Coolify.

`node-exporter` monta `/proc`, `/sys` y la raíz del host en modo de solo lectura. Aunque no tiene capacidades Linux ni acceso público, dispone de visibilidad amplia de métricas y metadatos del host. No conviertas ese servicio en público y limita quién puede modificar el Compose.

## 7. Comprobar el despliegue

Después de desplegar:

1. Confirma que el recurso y sus dos servicios están activos.
2. Abre el origen HTTPS del panel.
3. Inicia sesión con la contraseña original, no con el hash.
4. Comprueba CPU, RAM, disco y uptime.
5. Comprueba que aparecen los proyectos de Coolify.
6. Pulsa **Actualizar** y verifica que cambia la hora de la muestra.
7. Pulsa **Abrir Coolify** y confirma que abre el dashboard esperado sin incluir credenciales en la URL.

Los endpoints `/health/live` y `/health/ready` permiten integrar comprobaciones de salud sin exponer métricas.

## 8. Añadir la PWA al iPhone

Web Push requiere iOS 16.4 o posterior y que la web se ejecute como aplicación de pantalla de inicio.

1. Abre el origen HTTPS del panel en el iPhone.
2. Inicia sesión.
3. Pulsa **Compartir** en el navegador.
4. Elige **Añadir a pantalla de inicio**.
5. Confirma con **Añadir**.
6. Cierra la pestaña y abre VPS Monitor desde el nuevo icono.

La aplicación se abrirá sin la interfaz habitual del navegador. El service worker conserva solo el shell estático: después de una recarga sin red no mostrará datos privados antiguos desde una caché persistente.

### Activar notificaciones

1. Abre la PWA desde su icono.
2. Entra en **Ajustes**.
3. Pulsa **Activar** en **Alertas push**.
4. Acepta el permiso de iOS.

El aviso de pantalla bloqueada es genérico. Para ver nombres, métricas y detalles hay que abrir la aplicación e iniciar una sesión válida.

Si se deniega el permiso, se debe rehabilitar desde los ajustes de notificaciones del sistema. El navegador no puede cambiar esa decisión por sí solo.

## 9. Persistencia y copias de seguridad

El volumen `vpsmonitor-data` contiene:

- Último dashboard e historial de métricas.
- Estado usado para detectar cambios de alertas.
- Suscripciones Web Push, incluidos endpoints y claves públicas de suscripción.

Trátalo como información privada. Inclúyelo en la política de copias de seguridad solo si necesitas conservar historial y suscripciones, y protege las copias con el mismo nivel que el resto de secretos operativos.

Los secretos de entorno no se guardan en ese volumen; los administra Coolify o el mecanismo de despliegue elegido.

## 10. Actualizar

En Coolify, actualiza la revisión del repositorio y vuelve a desplegar el recurso. Confirma después:

- Estado saludable de `web`.
- Persistencia del volumen.
- Acceso al dashboard.
- Actualización de métricas.
- Suscripción push desde el iPhone.

Con Docker Compose gestionado manualmente:

```bash
docker compose up --detach --build
docker compose ps
```

Una actualización del service worker puede requerir cerrar y volver a abrir la PWA para activar la nueva versión del shell.

## 11. Desinstalar

En iPhone, mantén pulsado el icono y elimina la aplicación web. Después elimina o bloquea sus notificaciones desde los ajustes del sistema si siguen apareciendo.

En Coolify, elimina el recurso. Decide expresamente si se debe conservar el volumen antes de confirmar la eliminación.

Con Docker Compose manual:

```bash
docker compose down
```

Ese comando conserva el volumen. Para eliminar también historial y suscripciones, y solo después de comprobar que no necesitas recuperarlos:

```bash
docker compose down --volumes
```

La eliminación del volumen es irreversible.

## 12. Solución de problemas

### El contenedor web no arranca

- Comprueba que todas las variables requeridas estén definidas.
- Revisa que `SESSION_SECRET` tenga longitud suficiente.
- Regenera el hash si el formato `scrypt` no es válido.
- Asegura que las tres variables VAPID estén presentes y pertenezcan al mismo par.
- Ejecuta `docker compose config --quiet` antes de desplegar otra vez.

### El inicio de sesión devuelve origen no permitido

`APP_ORIGIN` no coincide exactamente con el origen HTTPS usado por el navegador. Corrige la variable y vuelve a desplegar. No añadas rutas ni una barra final significativa.

### No aparecen métricas

- Confirma que `node-exporter` está activo.
- Verifica que el despliegue permite los montajes de solo lectura incluidos en Compose.
- Recuerda que se miden los recursos del host donde corre Docker.
- No publiques `node-exporter` para intentar resolver el problema.

### Coolify no está disponible

- Comprueba la URL base HTTPS.
- Comprueba que el token no haya caducado o sido revocado.
- Confirma que su único permiso necesario sea `read`.
- Verifica conectividad saliente desde el contenedor `web`.

### Las notificaciones no se activan

- Usa iOS 16.4 o posterior.
- Abre la PWA desde el icono de la pantalla de inicio.
- Comprueba el par VAPID y su contacto.
- Revisa que iOS no tenga el permiso bloqueado.
- Recuerda que una caída total del VPS impide al propio VPS enviar el aviso.

### El panel está desactualizado tras un despliegue

Cierra completamente la PWA y vuelve a abrirla. Si continúa mostrando el shell anterior, elimina la aplicación web de la pantalla de inicio, borra los datos del sitio y añádela de nuevo.

## 13. Lista de seguridad

- HTTPS obligatorio y `APP_ORIGIN` exacto.
- Contraseña larga, única y no compartida.
- Token Coolify con permiso `read` solamente.
- Secretos únicamente en el almacén de variables del despliegue.
- Nunca publicar `node-exporter` ni el volumen de datos.
- Mantener Docker, imágenes y dependencias actualizados.
- Revisar `npm audit` y las pruebas antes de desplegar.
- Copias del volumen cifradas y con acceso limitado.
- Monitor externo para detectar la caída completa del VPS.
