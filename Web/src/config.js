import path from "node:path";
import { fileURLToPath } from "node:url";

const defaultPublicDirectory = fileURLToPath(new URL("../public/", import.meta.url));

export class ConfigurationError extends Error {
  constructor(issues) {
    super("Invalid configuration");
    this.name = "ConfigurationError";
    this.issues = issues;
  }
}

function required(env, name, issues, minimumLength = 1) {
  const value = env[name]?.trim() ?? "";
  if (value.length < minimumLength) {
    issues.push(`${name} is required`);
  }
  return value;
}

function integer(env, name, fallback, issues, { minimum = 1, maximum = Number.MAX_SAFE_INTEGER } = {}) {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    issues.push(`${name} must be an integer between ${minimum} and ${maximum}`);
    return fallback;
  }
  return value;
}

function percentage(env, name, fallback, issues) {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0 || value > 100) {
    issues.push(`${name} must be between 0 and 100`);
    return fallback;
  }
  return value;
}

function fixedURL(raw, name, issues, protocols) {
  try {
    const url = new URL(raw);
    if (!protocols.includes(url.protocol)) throw new Error("protocol");
    if (url.username || url.password || url.search || url.hash) throw new Error("components");
    return url;
  } catch {
    issues.push(`${name} must be a fixed ${protocols.join(" or ")} URL without credentials, query, or fragment`);
    return null;
  }
}

function validateScryptHash(value, issues) {
  const parts = value.split("$");
  if (parts.length !== 6 || parts[0] !== "scrypt") {
    issues.push("ADMIN_PASSWORD_HASH must use the supported scrypt format");
    return;
  }
  const [cost, blockSize, parallelism] = parts.slice(1, 4).map(Number);
  if (!Number.isSafeInteger(cost) || cost < 16_384 || (cost & (cost - 1)) !== 0 ||
      !Number.isSafeInteger(blockSize) || blockSize < 8 || blockSize > 32 ||
      !Number.isSafeInteger(parallelism) || parallelism < 1 || parallelism > 8 ||
      !/^[A-Za-z0-9_-]{16,}$/.test(parts[4]) || !/^[A-Za-z0-9_-]{32,}$/.test(parts[5])) {
    issues.push("ADMIN_PASSWORD_HASH has unsafe or malformed scrypt parameters");
  }
}

export function loadConfig(env = process.env) {
  const issues = [];
  const nodeEnvironment = env.NODE_ENV?.trim() || "production";
  const appOriginRaw = required(env, "APP_ORIGIN", issues);
  const allowedOriginProtocols = nodeEnvironment === "development" ? ["https:", "http:"] : ["https:"];
  const appOrigin = fixedURL(appOriginRaw, "APP_ORIGIN", issues, allowedOriginProtocols);
  if (appOrigin?.protocol === "http:" && !["localhost", "127.0.0.1", "[::1]"].includes(appOrigin.hostname)) {
    issues.push("APP_ORIGIN may use HTTP only for a local development hostname");
  }
  if (appOrigin && appOrigin.pathname !== "/") {
    issues.push("APP_ORIGIN must not contain a path");
  }

  const passwordHash = required(env, "ADMIN_PASSWORD_HASH", issues);
  if (passwordHash) validateScryptHash(passwordHash, issues);
  const sessionSecret = required(env, "SESSION_SECRET", issues, 32);

  const nodeExporterRaw = required(env, "NODE_EXPORTER_URL", issues);
  const nodeExporterURL = fixedURL(nodeExporterRaw, "NODE_EXPORTER_URL", issues, ["http:", "https:"]);

  const coolifyRaw = required(env, "COOLIFY_BASE_URL", issues);
  const coolifyURL = fixedURL(coolifyRaw, "COOLIFY_BASE_URL", issues, ["https:"]);
  const coolifyDashboardRaw = env.COOLIFY_DASHBOARD_URL?.trim() || coolifyRaw;
  const coolifyDashboardURL = fixedURL(coolifyDashboardRaw, "COOLIFY_DASHBOARD_URL", issues, ["https:"]);
  const coolifyToken = required(env, "COOLIFY_API_TOKEN", issues, 8);
  if (/\p{Cc}/u.test(coolifyToken)) issues.push("COOLIFY_API_TOKEN contains control characters");

  const vapidValues = [env.VAPID_SUBJECT, env.VAPID_PUBLIC_KEY, env.VAPID_PRIVATE_KEY]
    .map((value) => value?.trim() ?? "");
  const vapidCount = vapidValues.filter(Boolean).length;
  if (vapidCount !== 0 && vapidCount !== 3) {
    issues.push("VAPID_SUBJECT, VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY must be configured together");
  }
  if (vapidValues[0] && !/^(mailto:|https:)/.test(vapidValues[0])) {
    issues.push("VAPID_SUBJECT must be a mailto: or https: URI");
  }

  const thresholds = {
    cpuWarning: percentage(env, "CPU_WARNING_PERCENT", 80, issues),
    cpuCritical: percentage(env, "CPU_CRITICAL_PERCENT", 90, issues),
    memoryWarning: percentage(env, "MEMORY_WARNING_PERCENT", 80, issues),
    memoryCritical: percentage(env, "MEMORY_CRITICAL_PERCENT", 90, issues),
    diskWarning: percentage(env, "DISK_WARNING_PERCENT", 80, issues),
    diskCritical: percentage(env, "DISK_CRITICAL_PERCENT", 90, issues),
  };
  for (const [warning, critical] of [
    ["cpuWarning", "cpuCritical"],
    ["memoryWarning", "memoryCritical"],
    ["diskWarning", "diskCritical"],
  ]) {
    if (thresholds[critical] < thresholds[warning]) {
      issues.push(`${critical} must be greater than or equal to ${warning}`);
    }
  }

  const numbers = {
    port: integer(env, "PORT", 3000, issues, { maximum: 65_535 }),
    sessionTTLSeconds: integer(env, "SESSION_TTL_SECONDS", 43_200, issues, { minimum: 300, maximum: 2_592_000 }),
    loginRateLimit: integer(env, "LOGIN_RATE_LIMIT", 5, issues, { minimum: 1, maximum: 100 }),
    loginGlobalRateLimit: integer(env, "LOGIN_GLOBAL_RATE_LIMIT", 100, issues, { minimum: 10, maximum: 10_000 }),
    loginRateWindowMs: integer(env, "LOGIN_RATE_WINDOW_MS", 900_000, issues, { minimum: 1_000, maximum: 86_400_000 }),
    requestBodyLimit: integer(env, "REQUEST_BODY_LIMIT_BYTES", 32_768, issues, { minimum: 1_024, maximum: 1_048_576 }),
    fetchTimeoutMs: integer(env, "FETCH_TIMEOUT_MS", 8_000, issues, { minimum: 500, maximum: 60_000 }),
    responseLimitBytes: integer(env, "UPSTREAM_RESPONSE_LIMIT_BYTES", 2_097_152, issues, { minimum: 16_384, maximum: 16_777_216 }),
    samplerIntervalMs: integer(env, "SAMPLER_INTERVAL_MS", 60_000, issues, { minimum: 1_000, maximum: 3_600_000 }),
    historyLimit: integer(env, "HISTORY_LIMIT", 1_440, issues, { minimum: 2, maximum: 100_000 }),
  };

  if (issues.length) throw new ConfigurationError(issues);

  const normalizedCoolify = new URL(coolifyURL);
  normalizedCoolify.pathname = normalizedCoolify.pathname
    .replace(/\/api\/v1\/?$/, "")
    .replace(/\/$/, "");

  return Object.freeze({
    nodeEnvironment,
    host: env.HOST?.trim() || "0.0.0.0",
    port: numbers.port,
    appOrigin: appOrigin.origin,
    publicDirectory: path.resolve(env.PUBLIC_DIR?.trim() || defaultPublicDirectory),
    dataDirectory: path.resolve(env.DATA_DIR?.trim() || path.join(process.cwd(), "data")),
    passwordHash,
    sessionSecret,
    sessionTTLSeconds: numbers.sessionTTLSeconds,
    loginRateLimit: numbers.loginRateLimit,
    loginGlobalRateLimit: numbers.loginGlobalRateLimit,
    loginRateWindowMs: numbers.loginRateWindowMs,
    requestBodyLimit: numbers.requestBodyLimit,
    fetchTimeoutMs: numbers.fetchTimeoutMs,
    responseLimitBytes: numbers.responseLimitBytes,
    samplerIntervalMs: numbers.samplerIntervalMs,
    historyLimit: numbers.historyLimit,
    nodeExporterURL: nodeExporterURL.toString(),
    serverName: env.SERVER_NAME?.trim() || nodeExporterURL.hostname,
    coolifyBaseURL: normalizedCoolify.toString().replace(/\/$/, ""),
    coolifyDashboardURL: coolifyDashboardURL.toString().replace(/\/$/, ""),
    coolifyToken,
    thresholds: Object.freeze(thresholds),
    vapid: vapidCount === 3 ? Object.freeze({
      subject: vapidValues[0],
      publicKey: vapidValues[1],
      privateKey: vapidValues[2],
    }) : null,
  });
}
