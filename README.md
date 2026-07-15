# VPS Monitor

VPS Monitor es una aplicación nativa para macOS que vive en la barra de menús. Consulta las métricas de un servidor Linux por SSH, muestra el estado de proyectos y recursos de Coolify y permite abrir una sesión SSH interactiva en la terminal elegida.

## Funciones principales

- Métricas de CPU, memoria, disco, carga y tiempo encendido del VPS.
- Gráficas de CPU y RAM de la última hora.
- Estado agregado del servidor y de los proyectos, entornos y recursos de Coolify.
- Enlaces a los recursos publicados por Coolify.
- Actualización automática cada 60 segundos y reintento a los 15 segundos si una consulta falla.
- Botón para abrir SSH en Terminal de Apple, Warp o un lanzador personalizado.
- Inicio automático de la aplicación al entrar en la sesión de macOS.
- Token de Coolify almacenado en Keychain.

La aplicación no aparece en el Dock: se abre desde el icono de servidor de la barra de menús.

## Requisitos

- macOS 13 o posterior.
- Xcode 15 o posterior, o sus Command Line Tools con Swift 5.9 o posterior.
- Para las métricas: un servidor Linux accesible mediante SSH, con `procfs`, `awk`, `cut`, `uptime` y una versión de `df` compatible con GNU coreutils.
- Para Coolify: una instancia accesible y un token de API con permisos de solo lectura.
- Para abrir sesiones: Terminal de Apple, Warp o una terminal que admita un comando de lanzamiento configurable.

SSH y Coolify se pueden configurar por separado. La aplicación sigue siendo útil aunque solo se active una de las dos integraciones.

## Instalación rápida

Desde la raíz de una copia local del repositorio:

```bash
swift test
zsh Scripts/install.sh
```

No ejecutes el instalador con `sudo`. El script compila en modo `release`, instala `VPSMonitor.app` para el usuario actual, registra el inicio de sesión y abre la aplicación. Para actualizar o reinstalar, vuelve a ejecutar el mismo comando.

Después, abre el icono de VPS Monitor en la barra de menús, entra en **Ajustes**, completa las integraciones que quieras usar y pulsa **Guardar y probar**.

La guía [Instalación y configuración](INSTALLATION.md) explica el proceso completo, las terminales compatibles, la desinstalación y la solución de problemas.

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

## Desarrollo

El proyecto usa Swift Package Manager y no necesita dependencias externas:

```bash
swift build
swift test
swift run VPSMonitor
```

También puedes abrir `Package.swift` con Xcode y ejecutar el esquema **VPSMonitor**. El repositorio incluye un flujo de GitHub Actions que ejecuta `swift test` en macOS.

Hay una prueba de integración opcional que se omite cuando no están definidas sus variables de entorno. Nunca añadas credenciales reales al repositorio ni a un flujo ejecutado desde contribuciones no confiables.

## Seguridad y privacidad

- El token de Coolify se guarda en Keychain bajo el servicio `com.vpsmonitor.credentials`.
- El host, usuario, puerto, ruta de clave y preferencias se guardan en `UserDefaults`; no contienen la clave privada, pero pueden revelar detalles de infraestructura.
- La aplicación referencia la clave SSH en su ubicación original y no la copia dentro del paquete.
- La recogida de métricas ejecuta comandos de lectura sobre `/proc`, `df` y `uptime`.
- Los argumentos de la sesión SSH se construyen por separado y se validan antes de lanzar la terminal.
- La configuración de Warp contiene el comando SSH y se protege con permisos de archivo `0600`.

Usa un usuario SSH con privilegios mínimos, una clave dedicada cuando sea posible y un token Coolify limitado a lectura. No publiques salidas de diagnóstico sin revisar antes hosts, usuarios, rutas y nombres de proyectos.

## Licencia

Este repositorio todavía no incluye un archivo de licencia. Su publicación como repositorio público no concede por sí sola permisos de uso, copia, modificación o redistribución. Añade una licencia explícita antes de aceptar contribuciones o distribuir versiones a terceros.
