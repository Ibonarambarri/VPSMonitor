import assert from "node:assert/strict";
import test from "node:test";
import {
  hashPassword,
  FixedWindowRateLimiter,
  readSessionCookie,
  SESSION_COOKIE_NAME,
  SessionManager,
  verifyPassword,
} from "../src/auth.js";
import { ConfigurationError, loadConfig } from "../src/config.js";

const password = "correct horse battery staple";
const passwordHash = "scrypt$16384$8$1$AQEBAQEBAQEBAQEBAQEBAQ$ABPHXRY1WrfMxKXBSXQDp5JR2GGGUi4Mh8TXxB4SUBU";

function environment(overrides = {}) {
  return {
    APP_ORIGIN: "https://monitor.example.com",
    ADMIN_PASSWORD_HASH: passwordHash,
    SESSION_SECRET: "a secure test secret containing at least 32 characters",
    NODE_EXPORTER_URL: "http://node-exporter:9100/metrics",
    COOLIFY_BASE_URL: "https://coolify-api.example.com",
    COOLIFY_DASHBOARD_URL: "https://coolify.example.com/admin",
    COOLIFY_API_TOKEN: "read-only-token",
    ...overrides,
  };
}

test("scrypt password hashes verify without storing the password", async () => {
  const encoded = await hashPassword(password, { salt: Buffer.alloc(16, 1) });
  assert.equal(encoded, passwordHash);
  assert.equal(await verifyPassword(password, encoded), true);
  assert.equal(await verifyPassword("incorrect password", encoded), false);
  assert.equal(await verifyPassword(password, "malformed"), false);
});

test("sessions are signed, expire, and use the required hardened cookie", () => {
  let now = 1_700_000_000_000;
  let generation = 0;
  const sessions = new SessionManager({
    secret: environment().SESSION_SECRET,
    passwordHash,
    ttlSeconds: 600,
    clock: () => now,
    generation: () => generation,
  });
  const token = sessions.create();
  assert.equal(sessions.verify(token)?.subject, "admin");
  assert.match(sessions.cookie(token), new RegExp(`^${SESSION_COOKIE_NAME}=`));
  assert.match(sessions.cookie(token), /; Path=\/; Max-Age=600; HttpOnly; Secure; SameSite=Strict$/);
  assert.equal(readSessionCookie(`unrelated=x; ${SESSION_COOKIE_NAME}=${token}`), token);
  assert.equal(sessions.verify(`${token.slice(0, -1)}x`), null);
  generation += 1;
  assert.equal(sessions.verify(token), null);
  const replacement = sessions.create();
  assert.equal(sessions.verify(replacement)?.subject, "admin");
  now += 601_000;
  assert.equal(sessions.verify(replacement), null);
});

test("rate limiter keeps a bounded least-recently-used key set", () => {
  let now = 1_700_000_000_000;
  const limiter = new FixedWindowRateLimiter({
    limit: 2,
    windowMs: 1_000,
    maximumEntries: 3,
    clock: () => now,
  });
  limiter.consume("one");
  limiter.consume("two");
  limiter.consume("three");
  limiter.consume("one");
  limiter.consume("four");
  assert.equal(limiter.entries.size, 3);
  assert.equal(limiter.entries.has("two"), false);
  assert.equal(limiter.entries.has("one"), true);

  now += 2_000;
  limiter.consume("five");
  assert.ok(limiter.entries.size <= 3);
});

test("configuration validates all numeric values and keeps Coolify URLs separate", () => {
  const config = loadConfig(environment({ PORT: "3443" }));
  assert.equal(config.port, 3443);
  assert.equal(config.coolifyBaseURL, "https://coolify-api.example.com");
  assert.equal(config.coolifyDashboardURL, "https://coolify.example.com/admin");
  assert.throws(() => loadConfig(environment({ PORT: "invalid" })), ConfigurationError);
});

test("HTTP origins are accepted only on localhost in development", () => {
  assert.equal(loadConfig(environment({
    NODE_ENV: "development",
    APP_ORIGIN: "http://127.0.0.1:3000",
  })).appOrigin, "http://127.0.0.1:3000");
  assert.throws(() => loadConfig(environment({ APP_ORIGIN: "http://localhost:3000" })), ConfigurationError);
  assert.throws(() => loadConfig(environment({
    NODE_ENV: "development",
    APP_ORIGIN: "http://monitor.example.com",
  })), ConfigurationError);
});
