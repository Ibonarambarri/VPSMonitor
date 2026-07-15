# VPS Monitor Web

VPS Monitor Web es el panel móvil y PWA del proyecto. Muestra métricas del host Linux, el inventario de Coolify y las alertas activas desde una interfaz adaptada a iPhone y otros navegadores modernos.

La aplicación web no recibe claves SSH. Las métricas se obtienen desde un `node-exporter` interno y el token de Coolify permanece exclusivamente en el servidor.

## Funciones

- Resumen de CPU, memoria, disco, carga y tiempo encendido.
- Historial reciente de CPU y memoria.
- Proyectos, entornos y recursos de Coolify.
- Alertas por umbrales y recursos degradados.
- Actualización automática y actualización manual.
- PWA instalable en la pantalla de inicio del iPhone.
- Notificaciones Web Push opcionales.
- Acceso mediante contraseña con cookie de sesión segura.
- Temas claro, oscuro y automático.

## Componentes

| Componente | Función |
| --- | --- |
| Servicio Node.js | Sirve la PWA, autentica, recopila datos y genera alertas. |
| `node-exporter` | Expone las métricas del host dentro de la red de Compose. |
| API de Coolify | Proporciona proyectos y recursos usando un token de lectura. |
| Volumen `vpsmonitor-data` | Conserva historial, estado y suscripciones push. |
| Service worker | Cachea únicamente el shell y los recursos estáticos. |

Ni las respuestas privadas de `/api` ni las credenciales se guardan en la caché del service worker.

## Requisitos

- Un host Linux con Docker Engine y Docker Compose, o una instalación de Coolify capaz de desplegar un recurso Compose.
- Un origen HTTPS dedicado para el panel.
- Un token de la API de Coolify limitado a `read`.
- Node.js 24 para desarrollo y pruebas fuera del contenedor.
- iOS 16.4 o posterior para Web Push en una PWA añadida a la pantalla de inicio.

## Desarrollo y pruebas

Desde este directorio:

```bash
npm ci
npm test
npm audit --omit=dev
```

Para validar los contenedores después de preparar las variables requeridas:

```bash
docker compose config --quiet
docker build --file Dockerfile --tag vpsmonitor-web:local .
```

El servidor se inicia con `npm start`, pero requiere todas las variables de entorno que valida `src/config.js`. Docker Compose utiliza `.env` para interpolar esos valores; Node.js no carga ese archivo automáticamente cuando se ejecuta directamente.

## Estructura

```text
Web/
├── public/              PWA sin frameworks
├── src/                 servidor, autenticación y recopiladores
├── test/                pruebas con el test runner de Node.js
├── Dockerfile           imagen de producción sin privilegios
├── docker-compose.yaml  servicio web, exporter y volumen
└── package.json
```

## Salud del servicio

- `/health/live`: confirma que el proceso HTTP responde.
- `/health/ready`: confirma que el almacenamiento y el servicio de dashboard están inicializados.

Los endpoints de salud no incluyen métricas ni credenciales. El dashboard y sus operaciones permanecen detrás de la sesión autenticada.

## Modelo de seguridad

- Contraseña almacenada únicamente como hash `scrypt`.
- Cookie `HttpOnly`, `Secure`, `SameSite=Strict` y con prefijo `__Host-`.
- Comprobación estricta del origen en operaciones que cambian estado.
- Límite de intentos de inicio de sesión.
- Token Coolify disponible solo para el proceso servidor.
- CSP estricta, HSTS y políticas que bloquean framing y capacidades innecesarias.
- Contenedores sin capacidades Linux, con filesystem de solo lectura y `no-new-privileges`.
- `node-exporter` accesible solo dentro de Compose.
- Sin montaje del socket de Docker.

El sistema usa una única cuenta administradora y no incorpora MFA ni gestión multiusuario. Si se expone a Internet, utiliza una contraseña única y larga, HTTPS y, cuando sea posible, una capa adicional de acceso o restricciones de red.

## Alcance de la monitorización

El Compose incluido mide el mismo host Linux donde se ejecuta `node-exporter`. No monitoriza otro VPS por SSH.

Si el panel se aloja en el mismo VPS que vigila, una caída completa de red, energía, Docker o almacenamiento puede impedir tanto la visualización como el envío de notificaciones. Para detectar esa clase de fallo hay que añadir una comprobación de disponibilidad externa e independiente.

Consulta [WEB_INSTALLATION.md](../WEB_INSTALLATION.md) para preparar secretos, desplegar en Coolify, instalar la PWA en iPhone, actualizar y desinstalar.
