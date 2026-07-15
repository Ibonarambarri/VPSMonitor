import { loadConfig, ConfigurationError } from "./config.js";
import { CoolifyClient } from "./coolify.js";
import { DashboardService } from "./dashboard.js";
import { NodeExporterClient } from "./exporter.js";
import { createHTTPServer, listen } from "./http.js";
import { PushService } from "./push.js";
import { JSONStore } from "./store.js";

const logger = {
  info(message) { console.log(message); },
  warn(message) { console.warn(message); },
  error(message) { console.error(message); },
};

async function main() {
  let config;
  try {
    config = loadConfig();
  } catch (error) {
    if (error instanceof ConfigurationError) {
      logger.error(`Configuración no válida: ${error.issues.join("; ")}`);
    } else {
      logger.error("No se pudo cargar la configuración");
    }
    process.exitCode = 1;
    return;
  }

  const store = new JSONStore(config.dataDirectory);
  const exporter = new NodeExporterClient({
    url: config.nodeExporterURL,
    timeoutMs: config.fetchTimeoutMs,
    maximumBytes: config.responseLimitBytes,
  });
  const coolify = new CoolifyClient({
    baseURL: config.coolifyBaseURL,
    token: config.coolifyToken,
    timeoutMs: config.fetchTimeoutMs,
    maximumBytes: config.responseLimitBytes,
  });
  const push = new PushService({ vapid: config.vapid, store, logger });
  const dashboard = new DashboardService({ config, store, exporter, coolify, push, logger });

  try {
    await dashboard.init({ refresh: false, schedule: true });
  } catch {
    logger.error("No se pudo inicializar el almacenamiento de la aplicación");
    process.exitCode = 1;
    return;
  }

  const server = createHTTPServer({ config, dashboard, push, store, logger });
  try {
    await listen(server, config);
  } catch {
    dashboard.stop();
    logger.error("No se pudo iniciar el servidor HTTP");
    process.exitCode = 1;
    return;
  }
  logger.info(`VPS Monitor Web escuchando en ${config.host}:${config.port}`);
  dashboard.refresh().catch(() => logger.warn("No se pudo completar el primer muestreo"));

  let closing = false;
  const shutdown = () => {
    if (closing) return;
    closing = true;
    dashboard.stop();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

await main();
