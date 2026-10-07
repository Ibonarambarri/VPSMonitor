# Instalación y configuración

Esta guía cubre la preparación del equipo y del servidor, la instalación o actualización de VPS Monitor, su configuración, el inicio automático, la desinstalación y los problemas más habituales.

## 1. Preparar macOS

VPS Monitor requiere macOS 13 o posterior y Swift 5.9 o posterior. Si no tienes Xcode, instala las Command Line Tools:

```bash
xcode-select --install
```

Comprueba la herramienta disponible:

```bash
swift --version
```

Terminal de Apple está incluida en macOS. Warp y cualquier otra terminal deben estar instaladas antes de seleccionarlas en la aplicación.

## 2. Preparar el acceso SSH

La monitorización se conecta con `/usr/bin/ssh` y activa estas opciones:

- `BatchMode=yes`, para impedir solicitudes interactivas.
- `IdentitiesOnly=yes`, para limitar las identidades ofrecidas.
- `ConnectTimeout=8` y `ServerAliveInterval=10`, para detectar conexiones caídas.
- `ControlMaster=auto` y `ControlPersist=300`, para reutilizar una sola conexión entre comprobaciones. El socket se crea en `~/Library/Caches/vpsm`.

Cada comprobación tiene además un límite de 25 segundos: una orden remota bloqueada nunca detiene las siguientes.

Antes de configurar la aplicación:

1. Comprueba que puedes entrar al servidor con la clave elegida.
2. Acepta manualmente la clave del host para que quede registrada en `known_hosts`.
3. Asegura la clave privada con permisos restrictivos, normalmente `0600`.
4. Si la clave tiene frase de paso, cárgala previamente en un agente SSH accesible desde tu sesión gráfica.
5. Usa un usuario remoto que pueda leer `/proc` y ejecutar `df`. Para ver el estado de los contenedores, ese usuario debe poder ejecutar `docker ps` (por ejemplo, perteneciendo al grupo `docker`); si no puede, la sección se oculta.

El servidor debe ser Linux con `procfs` y las utilidades POSIX habituales (`sh`, `awk`, `df`, `sort`, `head`). La app no depende de la shell de inicio de sesión del usuario remoto.

## 3. Preparar Coolify

Esta integración es opcional. Crea un token de API restringido a lectura y conserva la URL base de la instancia. En la aplicación se introduce la URL sin el sufijo `/api/v1`; VPS Monitor lo añade automáticamente.

El cliente realiza peticiones de lectura para descubrir proyectos, aplicaciones, servicios y bases de datos. No inicia despliegues ni cambia la configuración de Coolify.

## 4. Instalar

Desde la raíz de una copia local del repositorio, ejecuta primero las pruebas y luego el instalador:

```bash
swift test
zsh Scripts/install.sh
```

No uses `sudo`. El instalador:

1. Compila el ejecutable en modo `release`.
2. Construye y firma localmente `VPSMonitor.app`.
3. Instala la aplicación en `~/Applications/VPSMonitor.app`.
4. Instala el agente de inicio en `~/Library/LaunchAgents/com.vpsmonitor.app.plist`.
5. Registra el agente en la sesión gráfica actual.
6. Comprueba que la aplicación arranca.

La firma predeterminada es ad hoc. Si necesitas firmar con una identidad ya disponible en tu llavero, puedes indicarla sin modificar el script:

```bash
VPSMONITOR_SIGNING_IDENTITY='IDENTIDAD_DE_FIRMA' zsh Scripts/install.sh
```

La identidad ad hoc cambia al recompilar. Por ello, macOS puede volver a solicitar el permiso de Automatización de Terminal después de una reinstalación. Usa una identidad de firma estable si necesitas conservar ese consentimiento entre versiones.

El script conserva temporalmente la versión anterior y la restaura si no puede registrar el inicio automático o si la aplicación nueva no arranca.

### Ejecutar sin instalar

Para desarrollo local:

```bash
swift run VPSMonitor
```

También puedes abrir `Package.swift` con Xcode y ejecutar el esquema **VPSMonitor**. Estos métodos no instalan el agente de inicio de sesión.

## 5. Configurar la aplicación

VPS Monitor es un agente de barra de menús y no muestra icono en el Dock. Pulsa su icono de servidor y abre **Ajustes** desde el menú de opciones.

### VPS

La barra lateral de Ajustes lista los VPS configurados. Usa **+** para añadir otro y **−** para eliminar el seleccionado; siempre debe quedar al menos uno. Cada VPS tiene:

- **Nombre:** aparece en el selector del panel y en las notificaciones.
- Su propio acceso SSH, Coolify, token y terminal.
- Botones **Probar SSH** y **Probar Coolify**, que comprueban la conexión sin guardar.

En el panel, pulsa el nombre del VPS o su tarjeta de resumen para cambiar de servidor. Todos los VPS se comprueban en segundo plano y cualquiera de ellos puede generar alertas.

### Coolify

- **URL:** URL base de la instancia, sin `/api/v1`.
- **Token:** token de API con alcance de lectura.

Cada token se guarda en Keychain. El resto de valores se guarda en el dominio de preferencias `com.vpsmonitor.app`.

Tras instalar una versión nueva, macOS puede pedir permiso una vez por token para que VPS Monitor lo lea. Introduce la contraseña de tu sesión y pulsa **Permitir siempre**: la firma local cambia en cada compilación y Keychain la trata como otra aplicación.

### Servidor SSH

- **Host o IP:** nombre o dirección del servidor, sin incluir el usuario.
- **Usuario:** cuenta remota; utiliza la menos privilegiada que permita leer las métricas.
- **Puerto:** entero entre `1` y `65535`.
- **Ruta de la clave privada:** admite una ruta absoluta o una ruta que empiece por `~`. Se puede dejar vacía si la configuración SSH efectiva ya resuelve una identidad válida.

### Actualización y alertas

- **Comprobar el servidor:** cada 10 s, 30 s, 1 min o 5 min mientras el panel está cerrado. Coolify se consulta como mucho cada 30 s.
- **En directo con el panel abierto:** actualiza cada 2 s mientras el panel está visible.
- **Mostrar CPU en la barra de menús:** añade el porcentaje de CPU junto al icono.
- **Notificaciones de macOS** y umbrales de CPU, memoria y disco. CPU y memoria deben superar el umbral durante 3 minutos seguidos; las alertas se resuelven al bajar 5 puntos por debajo del umbral. El servidor se considera caído tras dos comprobaciones fallidas consecutivas.

Las notificaciones requieren la app instalada con `Scripts/install.sh`; con `swift run` no están disponibles. La primera vez macOS pedirá permiso.

Pulsa **Guardar y probar**. La vista se actualizará inmediatamente. Cuando una consulta falla, se repite en 15 segundos como máximo.

## 6. Elegir la terminal SSH

El botón de terminal junto al título se activa cuando host, usuario y puerto son válidos. La sesión interactiva reutiliza también la clave configurada.

### Terminal de Apple

Selecciona **Terminal de Apple** en Ajustes. La primera apertura puede mostrar una solicitud para que VPS Monitor controle Terminal.

Si la rechazaste, abre **Ajustes del Sistema > Privacidad y seguridad > Automatización** y habilita Terminal para VPS Monitor. Para reiniciar la decisión y provocar una solicitud nueva:

```bash
tccutil reset AppleEvents com.vpsmonitor.app
```

### Warp

Selecciona **Warp** en Ajustes. VPS Monitor comprueba que la versión estable de Warp esté instalada, escribe el Tab Config:

```text
~/.warp/tab_configs/com_vpsmonitor_app_ssh.toml
```

y abre una ventana nueva mediante el esquema `warp://`. El archivo se reemplaza al abrir otra sesión y queda con permisos `0600`.

Dentro del Tab Config se ejecuta un comando convencional `ssh -p … -i … usuario@host`, sin invocar directamente `/usr/bin/ssh`, para que la detección de sesiones SSH de Warp pueda ofrecer **Warpify**. Si la sesión abre con la interfaz SSH clásica, usa `⌘P`, ejecuta **Warpify SSH Session** y comprueba que la detección SSH esté habilitada y que el host no figure en la lista de exclusión. Warp puede solicitar permiso para usar o instalar `tmux` en el servidor.

### Terminal personalizada

Selecciona **Personalizada** e indica:

- La ruta absoluta a un ejecutable. También se admite `~` al principio de la ruta.
- Sus argumentos, uno por línea.
- `{ssh}` como una línea completa, en el punto donde el lanzador espera el ejecutable SSH y sus argumentos.

Patrón mínimo para un ejecutable compatible con `-e`:

```text
-e
{ssh}
```

Patrón orientativo para `/usr/bin/open`, si la aplicación de terminal elegida acepta argumentos de proceso:

```text
-a
NOMBRE_DE_LA_TERMINAL
--args
-e
{ssh}
```

Cada línea se pasa como un argumento independiente: no se interpreta como código de shell ni se divide por espacios. La sintaxis exacta depende de la interfaz de línea de comandos de la terminal. No escribas `{ssh}` dentro de otra cadena, por ejemplo `--command={ssh}`; debe ocupar su propia línea.

## 7. Inicio automático, actualización y reinstalación

El instalador registra un `LaunchAgent` con `RunAtLoad`. Puedes comprobar su estado con:

```bash
launchctl print "gui/$UID/com.vpsmonitor.app"
```

Para actualizar o reparar una instalación, sitúate en una copia actualizada del proyecto y vuelve a ejecutar:

```bash
zsh Scripts/install.sh
```

La configuración existente y los tokens de Keychain no se eliminan durante una reinstalación. Las versiones 1.1 y 1.2 se migran automáticamente, incluidas sus gráficas recientes.

## 8. Desinstalar

Para detener el agente y retirar la aplicación del usuario actual:

```bash
launchctl bootout "gui/$UID/com.vpsmonitor.app" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.vpsmonitor.app.plist"
rm -rf "$HOME/Applications/VPSMonitor.app"
```

Esto conserva la configuración. Si también quieres borrar todas las preferencias, el historial, el token y el Tab Config de Warp, ejecuta además:

```bash
defaults delete com.vpsmonitor.app 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/VPSMonitor" "$HOME/Library/Caches/vpsm"
for service in com.vpsmonitor.credentials com.vpsmonitor.credentials.v2 com.vpsmonitor.credentials.v3; do
    while security delete-generic-password -s "$service" >/dev/null 2>&1; do :; done
done
rm -f "$HOME/.warp/tab_configs/com_vpsmonitor_app_ssh.toml"
```

El último bloque es irreversible: comprueba que no necesitas esos valores antes de ejecutarlo.

## 9. Solución de problemas

### El instalador indica que falta Swift

Instala Xcode o sus Command Line Tools, confirma `swift --version` y vuelve a ejecutar el script. Si has cambiado de Xcode, verifica qué instalación está seleccionada con `xcode-select -p`.

### La aplicación no aparece

Busca el icono de servidor en la barra de menús; no aparece en el Dock. Puedes abrir manualmente la instalación con:

```bash
open "$HOME/Applications/VPSMonitor.app"
```

Después comprueba el agente con `launchctl print "gui/$UID/com.vpsmonitor.app"`. Una reinstalación vuelve a generar y registrar el archivo correspondiente.

### SSH funciona en Terminal, pero no en el monitor

La consulta de métricas no puede mostrar preguntas de contraseña, frase de paso ni confirmación de host. Comprueba la misma conexión con `BatchMode=yes` y sustituye los marcadores en mayúsculas por tus valores:

```text
/usr/bin/ssh -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=8 -p PUERTO -i RUTA_DE_CLAVE USUARIO@HOST 'sh -c "head -n 1 /proc/stat"'
```

Revisa también:

- Que la clave del host ya esté en `known_hosts`.
- Que la ruta de la clave exista para el usuario que ejecuta la app.
- Que la clave privada tenga permisos adecuados.
- Que una clave cifrada esté cargada en el agente SSH.
- Que el servidor tenga las herramientas Linux requeridas.

### El botón SSH está desactivado

Guarda un host y un usuario no vacíos, un puerto entre `1` y `65535` y una ruta de clave sin caracteres de control. Si has seleccionado una terminal personalizada, comprueba también que el ejecutable exista y que los argumentos contengan exactamente una línea `{ssh}`. La existencia de la clave se comprueba al pulsar el botón.

### macOS bloquea Terminal de Apple

Concede el permiso en **Ajustes del Sistema > Privacidad y seguridad > Automatización**. Si VPS Monitor no aparece, usa el comando `tccutil` descrito en la sección de Terminal de Apple e intenta abrir la sesión otra vez.

### Warp no se abre

Confirma que la versión estable de Warp está instalada y que puede abrirse manualmente. Revisa que el usuario tenga permiso para crear `~/.warp/tab_configs`. Las variantes con otro identificador de aplicación no se detectan como la versión estable.

### La terminal personalizada falla

Comprueba que el ejecutable exista, sea ejecutable y resuelva a una ruta absoluta. Verifica que `{ssh}` figure una sola vez como línea independiente y adapta los argumentos a la documentación de tu terminal.

### Coolify responde con error

- Comprueba que la URL sea la base de la instancia y no incluya una ruta de recurso.
- Renueva el token si la API responde con un error de autenticación o autorización.
- Verifica que el token pueda leer proyectos, aplicaciones, servicios y bases de datos.
- Evita copiar mensajes completos a incidencias públicas sin ocultar primero datos de infraestructura.

## 10. Pruebas y CI

Ejecuta la suite local con:

```bash
swift test
```

Las pruebas en vivo se omiten salvo que estén definidas sus variables: `VPSMONITOR_TEST_COOLIFY_URL` y `VPSMONITOR_TEST_COOLIFY_TOKEN` para Coolify; `VPSMONITOR_TEST_SSH_HOST` y `VPSMONITOR_TEST_SSH_KEY` (y opcionalmente `VPSMONITOR_TEST_SSH_USER` y `VPSMONITOR_TEST_SSH_PORT`) para SSH. No guardes sus valores en archivos versionados ni los expongas a flujos de CI procedentes de código no confiable.
