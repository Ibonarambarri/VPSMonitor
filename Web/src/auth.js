import {
  createHash,
  createHmac,
  randomBytes,
  scrypt as nodeScrypt,
  timingSafeEqual,
} from "node:crypto";
import { promisify } from "node:util";

const scrypt = promisify(nodeScrypt);
export const SESSION_COOKIE_NAME = "__Host-vpsmonitor_session";

function scryptMemory(cost, blockSize) {
  return Math.max(32 * 1024 * 1024, 256 * cost * blockSize);
}

function decodeHash(encoded) {
  const parts = encoded.split("$");
  if (parts.length !== 6 || parts[0] !== "scrypt") throw new Error("Malformed password hash");
  const cost = Number(parts[1]);
  const blockSize = Number(parts[2]);
  const parallelism = Number(parts[3]);
  const salt = Buffer.from(parts[4], "base64url");
  const hash = Buffer.from(parts[5], "base64url");
  if (!Number.isSafeInteger(cost) || cost < 16_384 || (cost & (cost - 1)) !== 0 ||
      !Number.isSafeInteger(blockSize) || blockSize < 8 || blockSize > 32 ||
      !Number.isSafeInteger(parallelism) || parallelism < 1 || parallelism > 8 ||
      salt.length < 12 || hash.length < 24) {
    throw new Error("Malformed password hash");
  }
  return { cost, blockSize, parallelism, salt, hash };
}

export async function hashPassword(password, {
  cost = 16_384,
  blockSize = 8,
  parallelism = 1,
  salt = randomBytes(16),
  length = 32,
} = {}) {
  if (typeof password !== "string" || password.length < 12 || password.length > 1_024) {
    throw new TypeError("Password must contain between 12 and 1024 characters");
  }
  const derived = await scrypt(password, salt, length, {
    N: cost,
    r: blockSize,
    p: parallelism,
    maxmem: scryptMemory(cost, blockSize),
  });
  return `scrypt$${cost}$${blockSize}$${parallelism}$${salt.toString("base64url")}$${Buffer.from(derived).toString("base64url")}`;
}

export async function verifyPassword(password, encoded) {
  if (typeof password !== "string" || password.length > 1_024) return false;
  let parsed;
  try {
    parsed = decodeHash(encoded);
  } catch {
    return false;
  }
  const derived = await scrypt(password, parsed.salt, parsed.hash.length, {
    N: parsed.cost,
    r: parsed.blockSize,
    p: parsed.parallelism,
    maxmem: scryptMemory(parsed.cost, parsed.blockSize),
  });
  const candidate = Buffer.from(derived);
  return candidate.length === parsed.hash.length && timingSafeEqual(candidate, parsed.hash);
}

function sign(value, secret) {
  return createHmac("sha256", secret).update(value).digest("base64url");
}

export class SessionManager {
  constructor({ secret, passwordHash, ttlSeconds = 43_200, clock = () => Date.now(), generation = () => 0 }) {
    this.secret = Buffer.from(secret, "utf8");
    this.ttlSeconds = ttlSeconds;
    this.clock = clock;
    this.generation = generation;
    this.version = createHash("sha256").update(passwordHash).digest("base64url").slice(0, 16);
  }

  create() {
    const issuedAt = Math.floor(this.clock() / 1_000);
    const payload = Buffer.from(JSON.stringify({
      sub: "admin",
      iat: issuedAt,
      exp: issuedAt + this.ttlSeconds,
      v: this.version,
      g: this.generation(),
    })).toString("base64url");
    return `${payload}.${sign(payload, this.secret)}`;
  }

  verify(token) {
    if (typeof token !== "string" || token.length > 4_096) return null;
    const [payload, signature, extra] = token.split(".");
    if (!payload || !/^[A-Za-z0-9_-]+$/.test(payload) ||
        !/^[A-Za-z0-9_-]{43}$/.test(signature) || extra !== undefined) return null;
    const expected = Buffer.from(sign(payload, this.secret), "base64url");
    let actual;
    try {
      actual = Buffer.from(signature, "base64url");
    } catch {
      return null;
    }
    if (actual.toString("base64url") !== signature ||
        expected.length !== actual.length || !timingSafeEqual(expected, actual)) return null;
    try {
      const value = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
      const now = Math.floor(this.clock() / 1_000);
      if (value.sub !== "admin" || value.v !== this.version ||
          value.g !== this.generation() ||
          !Number.isSafeInteger(value.iat) || !Number.isSafeInteger(value.exp) ||
          value.iat > now + 60 || value.exp <= now || value.exp - value.iat !== this.ttlSeconds) {
        return null;
      }
      return { subject: value.sub, expiresAt: value.exp };
    } catch {
      return null;
    }
  }

  cookie(token) {
    return `${SESSION_COOKIE_NAME}=${token}; Path=/; Max-Age=${this.ttlSeconds}; HttpOnly; Secure; SameSite=Strict`;
  }

  clearCookie() {
    return `${SESSION_COOKIE_NAME}=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; Secure; SameSite=Strict`;
  }
}

export function readSessionCookie(header) {
  if (typeof header !== "string" || header.length > 16_384) return null;
  for (const part of header.split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0) continue;
    const name = part.slice(0, separator).trim();
    if (name === SESSION_COOKIE_NAME) return part.slice(separator + 1).trim();
  }
  return null;
}

export class FixedWindowRateLimiter {
  constructor({ limit, windowMs, clock = () => Date.now(), maximumEntries = 4_096 }) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.clock = clock;
    this.maximumEntries = maximumEntries;
    this.entries = new Map();
  }

  consume(key) {
    const now = this.clock();
    let entry = this.entries.get(key);
    if (!entry || entry.resetAt <= now) entry = { count: 0, resetAt: now + this.windowMs };
    entry.count += 1;
    this.entries.delete(key);
    if (this.entries.size >= this.maximumEntries) {
      let scanned = 0;
      for (const [candidate, candidateEntry] of this.entries) {
        if (candidateEntry.resetAt <= now) this.entries.delete(candidate);
        scanned += 1;
        if (scanned >= 64 || this.entries.size < this.maximumEntries) break;
      }
      if (this.entries.size >= this.maximumEntries) {
        this.entries.delete(this.entries.keys().next().value);
      }
    }
    this.entries.set(key, entry);
    return {
      allowed: entry.count <= this.limit,
      retryAfterSeconds: Math.max(1, Math.ceil((entry.resetAt - now) / 1_000)),
    };
  }

  reset(key) {
    this.entries.delete(key);
  }
}
