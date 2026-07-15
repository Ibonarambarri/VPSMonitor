import { createServer } from "node:http";
import { readFile, realpath, stat } from "node:fs/promises";
import { isIP } from "node:net";
import path from "node:path";
import { FixedWindowRateLimiter, readSessionCookie, SessionManager, verifyPassword } from "./auth.js";

const MIME_TYPES = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".ico", "image/x-icon"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".png", "image/png"],
  [".svg", "image/svg+xml; charset=utf-8"],
  [".webmanifest", "application/manifest+json; charset=utf-8"],
]);

const API_PATHS = new Set([
  "/api/session",
  "/api/login",
  "/api/logout",
  "/api/dashboard",
  "/api/refresh",
  "/api/push/key",
  "/api/push/subscribe",
]);

function applySecurityHeaders(response) {
  response.setHeader("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; manifest-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
  response.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("X-Frame-Options", "DENY");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("Permissions-Policy", "camera=(), geolocation=(), microphone=(), payment=(), usb=()");
  response.setHeader("Cross-Origin-Opener-Policy", "same-origin");
  response.setHeader("Cross-Origin-Resource-Policy", "same-origin");
}

function sendJSON(response, status, value, headers = {}) {
  const body = status === 204 ? "" : JSON.stringify(value);
  response.writeHead(status, {
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    ...headers,
  });
  response.end(body);
}

function sendAPIError(response, status, message, headers) {
  sendJSON(response, status, { error: message }, headers);
}

async function readJSON(request, response, maximumBytes) {
  if (request.headers["content-encoding"] && request.headers["content-encoding"] !== "identity") {
    sendAPIError(response, 415, "La codificación del cuerpo no está permitida.");
    return null;
  }
  const contentType = String(request.headers["content-type"] ?? "").split(";", 1)[0].trim().toLowerCase();
  if (contentType !== "application/json") {
    sendAPIError(response, 415, "Se requiere un cuerpo JSON.");
    return null;
  }
  const declared = request.headers["content-length"];
  if (declared !== undefined) {
    const length = Number(declared);
    if (!Number.isSafeInteger(length) || length < 0) {
      sendAPIError(response, 400, "El tamaño del cuerpo no es válido.");
      return null;
    }
    if (length > maximumBytes) {
      response.setHeader("Connection", "close");
      request.resume();
      sendAPIError(response, 413, "El cuerpo de la petición es demasiado grande.");
      return null;
    }
  }
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > maximumBytes) {
      response.setHeader("Connection", "close");
      sendAPIError(response, 413, "El cuerpo de la petición es demasiado grande.");
      return null;
    }
    chunks.push(chunk);
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks, length).toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("shape");
    return value;
  } catch {
    sendAPIError(response, 400, "El cuerpo JSON no es válido.");
    return null;
  }
}

function isAuthenticated(request, sessions) {
  const token = readSessionCookie(request.headers.cookie);
  return Boolean(token && sessions.verify(token));
}

function requireOrigin(request, response, appOrigin) {
  if (request.headers.origin !== appOrigin) {
    sendAPIError(response, 403, "Origen no permitido.");
    return false;
  }
  return true;
}

function requireAuthentication(request, response, sessions) {
  if (!isAuthenticated(request, sessions)) {
    sendAPIError(response, 401, "Autenticación requerida.");
    return false;
  }
  return true;
}

function normalizeIPAddress(value) {
  if (typeof value !== "string") return null;
  const candidate = value.trim().toLowerCase();
  if (!candidate || candidate.length > 64) return null;
  if (candidate.startsWith("::ffff:") && isIP(candidate.slice(7)) === 4) return candidate.slice(7);
  return isIP(candidate) ? candidate : null;
}

function isInternalAddress(address) {
  const version = isIP(address);
  if (version === 4) {
    const [first, second] = address.split(".").map(Number);
    return first === 10 || first === 127 ||
      (first === 169 && second === 254) ||
      (first === 172 && second >= 16 && second <= 31) ||
      (first === 192 && second === 168);
  }
  if (version === 6) {
    return address === "::1" || address.startsWith("fc") || address.startsWith("fd") ||
      /^fe[89ab]/.test(address);
  }
  return false;
}

function rateLimitAddress(address) {
  if (isIP(address) !== 6 || address.includes(".")) return address;
  const halves = address.split("::");
  if (halves.length > 2) return address;
  const left = halves[0] ? halves[0].split(":") : [];
  const right = halves[1] ? halves[1].split(":") : [];
  const missing = 8 - left.length - right.length;
  if (missing < 0 || (halves.length === 1 && missing !== 0)) return address;
  const groups = [...left, ...Array(missing).fill("0"), ...right];
  if (groups.length !== 8 || groups.some((group) => !/^[0-9a-f]{1,4}$/i.test(group))) return address;
  return `${groups.slice(0, 4).map((group) => Number.parseInt(group, 16).toString(16)).join(":")}::/64`;
}

function loginClientKey(request) {
  const socketAddress = normalizeIPAddress(request.socket.remoteAddress);
  if (!socketAddress || !isInternalAddress(socketAddress)) return socketAddress ?? "unknown";

  const forwarded = request.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.length <= 1_024) {
    const chain = forwarded.split(",");
    for (let index = chain.length - 1; index >= 0; index -= 1) {
      const address = normalizeIPAddress(chain[index]);
      if (address) return rateLimitAddress(address);
    }
  }
  const realAddress = normalizeIPAddress(request.headers["x-real-ip"]);
  return rateLimitAddress(realAddress ?? socketAddress);
}

function methodNotAllowed(response, allowed) {
  sendAPIError(response, 405, "Método no permitido.", { Allow: allowed.join(", ") });
}

async function serveStatic(request, response, publicDirectory, urlPath) {
  if (request.method !== "GET" && request.method !== "HEAD") return false;
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath);
  } catch {
    response.writeHead(400, { "Cache-Control": "no-store", "Content-Length": 0 });
    response.end();
    return true;
  }
  const parts = decoded.split("/");
  if (parts.some((part) => part === ".." || part.includes("\0"))) {
    response.writeHead(404, { "Cache-Control": "no-store", "Content-Length": 0 });
    response.end();
    return true;
  }
  const relative = decoded === "/" ? "index.html" : decoded.replace(/^\/+/, "");
  const root = await realpath(publicDirectory);
  let filename;
  try {
    filename = await realpath(path.resolve(root, relative));
    if (filename !== root && !filename.startsWith(`${root}${path.sep}`)) throw new Error("outside");
    const metadata = await stat(filename);
    if (!metadata.isFile()) throw new Error("not_file");
  } catch {
    return false;
  }
  const body = await readFile(filename);
  const extension = path.extname(filename).toLowerCase();
  const requiresRevalidation = relative === "index.html" || relative === "sw.js" ||
    extension === ".webmanifest" || extension === ".js" || extension === ".css";
  response.writeHead(200, {
    "Cache-Control": requiresRevalidation ? "no-cache" : "public, max-age=86400",
    "Content-Type": MIME_TYPES.get(extension) ?? "application/octet-stream",
    "Content-Length": body.length,
  });
  response.end(request.method === "HEAD" ? undefined : body);
  return true;
}

export function createRequestHandler({ config, dashboard, push, store = null, logger = console, clock }) {
  let localSessionGeneration = 0;
  const currentSessionGeneration = () => {
    const value = store?.getSessionGeneration?.();
    return Number.isSafeInteger(value) && value >= 0 ? value : localSessionGeneration;
  };
  const revokeSessions = async () => {
    if (store?.update) {
      await store.update((state) => {
        const current = Number.isSafeInteger(state.sessionGeneration) && state.sessionGeneration >= 0
          ? state.sessionGeneration
          : 0;
        state.sessionGeneration = current + 1;
      });
    } else {
      localSessionGeneration += 1;
    }
  };
  const sessions = new SessionManager({
    secret: config.sessionSecret,
    passwordHash: config.passwordHash,
    ttlSeconds: config.sessionTTLSeconds,
    clock,
    generation: currentSessionGeneration,
  });
  const limiter = new FixedWindowRateLimiter({
    limit: config.loginRateLimit,
    windowMs: config.loginRateWindowMs,
    clock,
  });
  const globalLimiter = new FixedWindowRateLimiter({
    limit: config.loginGlobalRateLimit ?? 100,
    windowMs: config.loginRateWindowMs,
    maximumEntries: 1,
    clock,
  });

  return async function handle(request, response) {
    applySecurityHeaders(response);
    let url;
    try {
      url = new URL(request.url, "http://localhost");
    } catch {
      sendAPIError(response, 400, "Petición no válida.");
      return;
    }
    const pathname = url.pathname;
    try {
      if (pathname === "/health/live") {
        if (request.method !== "GET") return methodNotAllowed(response, ["GET"]);
        return sendJSON(response, 200, { status: "ok" });
      }
      if (pathname === "/health/ready") {
        if (request.method !== "GET") return methodNotAllowed(response, ["GET"]);
        return sendJSON(response, dashboard.ready ? 200 : 503, { status: dashboard.ready ? "ready" : "starting" });
      }
      if (pathname === "/api/session") {
        if (request.method !== "GET") return methodNotAllowed(response, ["GET"]);
        return sendJSON(response, 200, { authenticated: isAuthenticated(request, sessions) });
      }
      if (pathname === "/api/login") {
        if (request.method !== "POST") return methodNotAllowed(response, ["POST"]);
        if (!requireOrigin(request, response, config.appOrigin)) return;
        const key = loginClientKey(request);
        const rate = limiter.consume(key);
        const globalRate = rate.allowed
          ? globalLimiter.consume("all")
          : { allowed: true, retryAfterSeconds: 0 };
        if (!rate.allowed || !globalRate.allowed) {
          return sendAPIError(response, 429, "Demasiados intentos. Inténtalo más tarde.", {
            "Retry-After": Math.max(rate.retryAfterSeconds, globalRate.retryAfterSeconds),
          });
        }
        const body = await readJSON(request, response, config.requestBodyLimit);
        if (!body) return;
        const valid = typeof body.password === "string" && await verifyPassword(body.password, config.passwordHash);
        if (!valid) return sendAPIError(response, 401, "Credenciales no válidas.");
        limiter.reset(key);
        return sendJSON(response, 200, { authenticated: true }, { "Set-Cookie": sessions.cookie(sessions.create()) });
      }
      if (pathname === "/api/logout") {
        if (request.method !== "POST") return methodNotAllowed(response, ["POST"]);
        if (!requireOrigin(request, response, config.appOrigin)) return;
        const token = readSessionCookie(request.headers.cookie);
        if (token && sessions.verify(token)) await revokeSessions();
        return sendJSON(response, 204, null, { "Set-Cookie": sessions.clearCookie() });
      }
      if (pathname === "/api/dashboard") {
        if (request.method !== "GET") return methodNotAllowed(response, ["GET"]);
        if (!requireAuthentication(request, response, sessions)) return;
        return sendJSON(response, 200, dashboard.getDashboard());
      }
      if (pathname === "/api/refresh") {
        if (request.method !== "POST") return methodNotAllowed(response, ["POST"]);
        if (!requireOrigin(request, response, config.appOrigin) || !requireAuthentication(request, response, sessions)) return;
        return sendJSON(response, 200, await dashboard.refresh());
      }
      if (pathname === "/api/push/key") {
        if (request.method !== "GET") return methodNotAllowed(response, ["GET"]);
        if (!requireAuthentication(request, response, sessions)) return;
        return sendJSON(response, 200, { enabled: push.enabled, publicKey: push.publicKey });
      }
      if (pathname === "/api/push/subscribe") {
        if (request.method !== "POST" && request.method !== "DELETE") return methodNotAllowed(response, ["POST", "DELETE"]);
        if (!requireOrigin(request, response, config.appOrigin) || !requireAuthentication(request, response, sessions)) return;
        const body = await readJSON(request, response, config.requestBodyLimit);
        if (!body) return;
        if (request.method === "DELETE") {
          await push.unsubscribe(body.subscription ?? body);
          return sendJSON(response, 204, null);
        }
        const result = await push.subscribe(body.subscription ?? body);
        if (!result.ok && result.reason === "disabled") return sendAPIError(response, 503, "Las notificaciones push no están configuradas.");
        if (!result.ok) return sendAPIError(response, 400, "La suscripción push no es válida.");
        return sendJSON(response, 201, { subscribed: true });
      }
      if (API_PATHS.has(pathname)) return methodNotAllowed(response, []);
      if (await serveStatic(request, response, config.publicDirectory, pathname)) return;
      response.writeHead(404, { "Cache-Control": "no-store", "Content-Length": 0 });
      response.end();
    } catch {
      logger.warn?.("Petición HTTP no completada");
      if (!response.headersSent) sendAPIError(response, 500, "No se pudo completar la petición.");
      else response.destroy();
    }
  };
}

export function createHTTPServer(options) {
  const server = createServer(createRequestHandler(options));
  server.requestTimeout = 15_000;
  server.headersTimeout = 5_000;
  server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 64;
  server.maxRequestsPerSocket = 100;
  server.on("clientError", (_error, socket) => {
    if (socket.writable) socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
  });
  return server;
}

export function listen(server, { host, port }) {
  return new Promise((resolve, reject) => {
    const onError = (error) => reject(error);
    server.once("error", onError);
    server.listen(port, host, () => {
      server.off("error", onError);
      resolve(server.address());
    });
  });
}
