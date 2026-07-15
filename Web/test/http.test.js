import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createHTTPServer, listen } from "../src/http.js";

const password = "correct horse battery staple";
const passwordHash = "scrypt$16384$8$1$AQEBAQEBAQEBAQEBAQEBAQ$ABPHXRY1WrfMxKXBSXQDp5JR2GGGUi4Mh8TXxB4SUBU";

async function fixture(t, configOverrides = {}) {
  const publicDirectory = await mkdtemp(path.join(os.tmpdir(), "vpsmonitor-public-"));
  await writeFile(path.join(publicDirectory, "index.html"), "<!doctype html><title>VPS Monitor</title>");
  t.after(() => rm(publicDirectory, { recursive: true, force: true }));
  let refreshes = 0;
  const dashboardValue = {
    generatedAt: "2026-07-15T10:00:00.000Z", overallState: "healthy",
    server: {
      available: true, name: "vps", cpuPercent: 1, memoryUsedBytes: 1, memoryTotalBytes: 2,
      diskUsedBytes: 1, diskTotalBytes: 2, load1: 0, load5: 0, load15: 0, uptimeSeconds: 1, history: [],
    },
    coolify: { available: true, dashboardUrl: "https://coolify.example.com", projects: [] },
    alerts: [], errors: [],
  };
  const dashboard = {
    ready: false,
    getDashboard: () => dashboardValue,
    async refresh() { refreshes += 1; return dashboardValue; },
  };
  const push = {
    enabled: false,
    publicKey: null,
    async subscribe() { return { ok: false, reason: "disabled" }; },
    async unsubscribe() { return false; },
  };
  const config = {
    host: "127.0.0.1", port: 0,
    appOrigin: "https://monitor.example.com",
    publicDirectory,
    sessionSecret: "a secure test secret containing at least 32 characters",
    passwordHash,
    sessionTTLSeconds: 600,
    loginRateLimit: 3,
    loginGlobalRateLimit: 100,
    loginRateWindowMs: 60_000,
    requestBodyLimit: 256,
    ...configOverrides,
  };
  const server = createHTTPServer({ config, dashboard, push, logger: { warn() {} } });
  const address = await listen(server, config);
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return {
    baseURL: `http://127.0.0.1:${address.port}`,
    dashboard,
    refreshes: () => refreshes,
  };
}

function jsonRequest(body, headers = {}) {
  return {
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  };
}

test("health probes are public, bounded, and reflect readiness", async (t) => {
  const app = await fixture(t);
  const live = await fetch(`${app.baseURL}/health/live`);
  assert.equal(live.status, 200);
  assert.deepEqual(await live.json(), { status: "ok" });
  assert.equal(live.headers.get("cache-control"), "no-store");
  assert.equal(live.headers.get("x-content-type-options"), "nosniff");
  const starting = await fetch(`${app.baseURL}/health/ready`);
  assert.equal(starting.status, 503);
  app.dashboard.ready = true;
  assert.equal((await fetch(`${app.baseURL}/health/ready`)).status, 200);
});

test("critical API routes require auth and exact same-origin mutation requests", async (t) => {
  const app = await fixture(t);
  const unauthorized = await fetch(`${app.baseURL}/api/dashboard`);
  assert.equal(unauthorized.status, 401);
  assert.equal(unauthorized.headers.get("cache-control"), "no-store");

  const crossOrigin = await fetch(`${app.baseURL}/api/login`, {
    method: "POST",
    ...jsonRequest({ password }, { Origin: "https://evil.example.com" }),
  });
  assert.equal(crossOrigin.status, 403);

  const login = await fetch(`${app.baseURL}/api/login`, {
    method: "POST",
    ...jsonRequest({ password }, { Origin: "https://monitor.example.com" }),
  });
  assert.equal(login.status, 200);
  const setCookie = login.headers.get("set-cookie");
  assert.match(setCookie, /^__Host-vpsmonitor_session=/);
  assert.match(setCookie, /HttpOnly; Secure; SameSite=Strict$/);
  const cookie = setCookie.split(";", 1)[0];

  const dashboard = await fetch(`${app.baseURL}/api/dashboard`, { headers: { Cookie: cookie } });
  assert.equal(dashboard.status, 200);
  assert.equal((await dashboard.json()).server.name, "vps");

  const missingOrigin = await fetch(`${app.baseURL}/api/refresh`, { method: "POST", headers: { Cookie: cookie } });
  assert.equal(missingOrigin.status, 403);
  const refresh = await fetch(`${app.baseURL}/api/refresh`, {
    method: "POST",
    headers: { Cookie: cookie, Origin: "https://monitor.example.com" },
  });
  assert.equal(refresh.status, 200);
  assert.equal(app.refreshes(), 1);

  const key = await fetch(`${app.baseURL}/api/push/key`, { headers: { Cookie: cookie } });
  assert.deepEqual(await key.json(), { enabled: false, publicKey: null });

  const logout = await fetch(`${app.baseURL}/api/logout`, {
    method: "POST",
    headers: { Cookie: cookie, Origin: "https://monitor.example.com" },
  });
  assert.equal(logout.status, 204);
  assert.match(logout.headers.get("set-cookie"), /Max-Age=0/);
  const revoked = await fetch(`${app.baseURL}/api/dashboard`, { headers: { Cookie: cookie } });
  assert.equal(revoked.status, 401);
});

test("login is rate-limited and JSON bodies are size-limited", async (t) => {
  const app = await fixture(t);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const response = await fetch(`${app.baseURL}/api/login`, {
      method: "POST",
      ...jsonRequest({ password: "wrong" }, { Origin: "https://monitor.example.com" }),
    });
    assert.equal(response.status, 401);
  }
  const limited = await fetch(`${app.baseURL}/api/login`, {
    method: "POST",
    ...jsonRequest({ password: "wrong" }, { Origin: "https://monitor.example.com" }),
  });
  assert.equal(limited.status, 429);
  assert.ok(Number(limited.headers.get("retry-after")) >= 1);

  const separateApp = await fixture(t);
  const oversized = await fetch(`${separateApp.baseURL}/api/login`, {
    method: "POST",
    ...jsonRequest({ password: "x".repeat(500) }, { Origin: "https://monitor.example.com" }),
  });
  assert.equal(oversized.status, 413);
});

test("login rate limits clients independently behind the trusted reverse proxy", async (t) => {
  const app = await fixture(t);
  const attempt = (client) => fetch(`${app.baseURL}/api/login`, {
    method: "POST",
    ...jsonRequest({ password: "wrong" }, {
      Origin: "https://monitor.example.com",
      "X-Forwarded-For": `192.0.2.123, ${client}`,
    }),
  });

  for (let count = 0; count < 3; count += 1) {
    assert.equal((await attempt("198.51.100.10")).status, 401);
  }
  assert.equal((await attempt("198.51.100.10")).status, 429);
  assert.equal((await attempt("198.51.100.11")).status, 401);
});

test("login rate limiting groups rotating IPv6 addresses by /64", async (t) => {
  const app = await fixture(t);
  const attempt = (client) => fetch(`${app.baseURL}/api/login`, {
    method: "POST",
    ...jsonRequest({ password: "wrong" }, {
      Origin: "https://monitor.example.com",
      "X-Forwarded-For": client,
    }),
  });
  for (const client of [
    "2001:4860:1234:5678::1",
    "2001:4860:1234:5678::2",
    "2001:4860:1234:5678::3",
  ]) assert.equal((await attempt(client)).status, 401);
  assert.equal((await attempt("2001:4860:1234:5678::4")).status, 429);
  assert.equal((await attempt("2001:4860:1234:5679::1")).status, 401);
});

test("login has a secondary global limit even when client addresses rotate", async (t) => {
  const app = await fixture(t, { loginGlobalRateLimit: 10, loginRateLimit: 10 });
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const response = await fetch(`${app.baseURL}/api/login`, {
      method: "POST",
      ...jsonRequest({ password: "wrong" }, {
        Origin: "https://monitor.example.com",
        "X-Forwarded-For": `198.51.100.${attempt + 1}`,
      }),
    });
    assert.equal(response.status, 401);
  }
  const limited = await fetch(`${app.baseURL}/api/login`, {
    method: "POST",
    ...jsonRequest({ password: "wrong" }, {
      Origin: "https://monitor.example.com",
      "X-Forwarded-For": "203.0.113.50",
    }),
  });
  assert.equal(limited.status, 429);
});

test("the server serves trusted static files without redirects", async (t) => {
  const app = await fixture(t);
  const response = await fetch(`${app.baseURL}/`, { redirect: "manual" });
  assert.equal(response.status, 200);
  assert.match(await response.text(), /VPS Monitor/);
  assert.equal(response.headers.get("content-security-policy")?.includes("frame-ancestors 'none'"), true);
  assert.equal((await fetch(`${app.baseURL}/missing`, { redirect: "manual" })).status, 404);
});
