# VPS Monitor

VPS Monitor ofrece dos interfaces complementarias para vigilar un servidor Linux y sus recursos de Coolify:

- Una aplicación nativa para macOS que vive en la barra de menús, obtiene métricas por SSH y abre sesiones interactivas en la terminal elegida.
- Una PWA móvil, pensada para iPhone, que obtiene métricas mediante `node-exporter`, muestra alertas y puede enviar notificaciones Web Push.

La PWA no recibe claves SSH ni expone el token de Coolify al navegador.

## Funciones principales

- Métricas de CPU, memoria, disco, carga y tiempo encendido del VPS.
- Gráficas de CPU y RAM de la última hora.
- Estado agregado del servidor y de los proyectos, entornos y recursos de Coolify.
- Enlaces a los recursos publicados por Coolify.
- Actualización automática cada 60 segundos y reintento a los 15 segundos si una consulta falla.
- Botón para abrir SSH en Terminal de Apple, Warp o un lanzador personalizado.
- Inicio automático de la aplicación al entrar en la sesión de macOS.
- Token de Coolify almacenado en Keychain.
- Panel móvil con login, temas claro y oscuro y navegación adaptada a pantallas pequeñas.
- Instalación en la pantalla de inicio del iPhone.
- Alertas por uso de recursos y estado de servicios.
- Notificaciones push opcionales con contenido genérico.

La aplicación macOS no aparece en el Dock: se abre desde el icono de servidor de la barra de menús.

## Requisitos

### Aplicación macOS

- macOS 13 o posterior.
- Xcode 15 o posterior, o sus Command Line Tools con Swift 5.9 o posterior.
- Para las métricas: un servidor Linux accesible mediante SSH, con `procfs`, `awk`, `cut`, `uptime` y una versión de `df` compatible con GNU coreutils.
- Para Coolify: una instancia accesible y un token de API con permisos de solo lectura.
- Para abrir sesiones: Terminal de Apple, Warp o una terminal que admita un comando de lanzamiento configurable.

SSH y Coolify se pueden configurar por separado. La aplicación sigue siendo útil aunque solo se active una de las dos integraciones.

### PWA

- Host Linux con Docker Compose o un recurso Docker Compose administrado por Coolify.
- Origen HTTPS dedicado.
- Token Coolify limitado al permiso `read`.
- Node.js 24 para desarrollo y pruebas.
- iOS 16.4 o posterior para usar Web Push desde la PWA instalada en iPhone.

## Instalación rápida

### macOS

Desde la raíz de una copia local del repositorio:

```bash
swift test
zsh Scripts/install.sh
```

No ejecutes el instalador con `sudo`. El script compila en modo `release`, instala `VPSMonitor.app` para el usuario actual, registra el inicio de sesión y abre la aplicación. Para actualizar o reinstalar, vuelve a ejecutar el mismo comando.

Después, abre el icono de VPS Monitor en la barra de menús, entra en **Ajustes**, completa las integraciones que quieras usar y pulsa **Guardar y probar**.

La guía [Instalación y configuración](INSTALLATION.md) explica el proceso completo, las terminales compatibles, la desinstalación y la solución de problemas.

### Web e iPhone

El servicio web se despliega desde `Web/docker-compose.yaml`. Antes de publicarlo hay que generar el hash de contraseña, el secreto de sesión, las claves VAPID y configurar un token Coolify de lectura.

Consulta [Instalación de VPS Monitor Web](WEB_INSTALLATION.md) para desplegarlo en Coolify con Docker Compose, validar la configuración, añadirlo a la pantalla de inicio del iPhone y activar notificaciones.

## Configuración resumida

### Servidor SSH

Indica el host, usuario, puerto y ruta de la clave privada. La monitorización usa SSH en modo no interactivo, por lo que la clave debe funcionar sin pedir datos en esa sesión. Conecta manualmente una vez desde una terminal para comprobar el acceso y aceptar la clave del host.

El botón con el símbolo de terminal, situado junto al título, abre una sesión SSH interactiva con los mismos host, usuario, puerto y clave.

### Coolify

Indica la URL base de la instancia, sin añadir `/api/v1`, y un token de API de lectura. VPS Monitor consulta proyectos, aplicaciones, servicios y bases de datos; no realiza operaciones de despliegue ni modifica recursos.

### Terminal SSH

- **Terminal de Apple:** puede solicitar permiso de Automatización la primera vez.
- **Warp:** crea un Tab Config local administrado por VPS Monitor, ejecuta un comando `ssh` reconocible por Warpify y abre una ventana nueva.
- **Personalizada:** ejecuta un binario indicado por el usuario. Los argumentos se escriben uno por línea y deben contener `{ssh}` en una línea independiente.

### Panel web

La PWA recopila las métricas del host Docker mediante un `node-exporter` interno. El servicio Node.js consulta Coolify, conserva el historial en un volumen y entrega al navegador únicamente datos tras una sesión autenticada.

El botón **Abrir Coolify** utiliza una URL HTTPS configurada en el servidor y nunca añade credenciales. El service worker solo cachea el shell estático; no persiste respuestas privadas de `/api`.

## Desarrollo

El proyecto usa Swift Package Manager y no necesita dependencias externas:

```bash
swift build
swift test
swift run VPSMonitor
```

También puedes abrir `Package.swift` con Xcode y ejecutar el esquema **VPSMonitor**. El repositorio incluye un flujo de GitHub Actions que ejecuta `swift test` en macOS.

Para la aplicación web:

```bash
cd Web
npm ci
npm test
npm audit --omit=dev
```

El CI también valida Docker Compose y construye la imagen web.

Hay una prueba de integración opcional que se omite cuando no están definidas sus variables de entorno. Nunca añadas credenciales reales al repositorio ni a un flujo ejecutado desde contribuciones no confiables.

## Seguridad y privacidad

- El token de Coolify se guarda en Keychain bajo el servicio `com.vpsmonitor.credentials`.
- El host, usuario, puerto, ruta de clave y preferencias se guardan en `UserDefaults`; no contienen la clave privada, pero pueden revelar detalles de infraestructura.
- La aplicación referencia la clave SSH en su ubicación original y no la copia dentro del paquete.
- La recogida de métricas ejecuta comandos de lectura sobre `/proc`, `df` y `uptime`.
- Los argumentos de la sesión SSH se construyen por separado y se validan antes de lanzar la terminal.
- La configuración de Warp contiene el comando SSH y se protege con permisos de archivo `0600`.
- El token de Coolify y las claves VAPID del panel web permanecen en el servidor.
- La contraseña web se almacena como hash `scrypt` y la sesión usa una cookie segura no accesible desde JavaScript.
- `node-exporter` no publica su puerto y los contenedores se ejecutan sin capacidades Linux adicionales.

Usa un usuario SSH con privilegios mínimos, una clave dedicada cuando sea posible y un token Coolify limitado a lectura. No publiques salidas de diagnóstico sin revisar antes hosts, usuarios, rutas y nombres de proyectos.

Si la PWA se aloja en el mismo VPS que monitoriza, una caída total también detendrá el panel y sus notificaciones. Complementa ese despliegue con una comprobación externa e independiente.

## Licencia

Este repositorio todavía no incluye un archivo de licencia. Su publicación como repositorio público no concede por sí sola permisos de uso, copia, modificación o redistribución. Añade una licencia explícita antes de aceptar contribuciones o distribuir versiones a terceros.
