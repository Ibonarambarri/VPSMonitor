import { createHash } from "node:crypto";
import { lookup as resolveDNS } from "node:dns";
import { Agent, request as httpsRequest } from "node:https";
import { BlockList, isIP } from "node:net";

const PUSH_TIMEOUT_MS = 8_000;
const PUSH_RESPONSE_LIMIT_BYTES = 65_536;

const NON_PUBLIC_ADDRESSES = new BlockList();
for (const [address, prefix] of [
  ["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8],
  ["169.254.0.0", 16], ["172.16.0.0", 12], ["192.0.0.0", 24], ["192.0.2.0", 24],
  ["192.168.0.0", 16], ["198.18.0.0", 15], ["198.51.100.0", 24], ["203.0.113.0", 24],
  ["224.0.0.0", 4], ["240.0.0.0", 4],
]) NON_PUBLIC_ADDRESSES.addSubnet(address, prefix, "ipv4");
for (const [address, prefix] of [
  ["::", 128], ["::1", 128], ["100::", 64],
  ["2001:db8::", 32], ["fc00::", 7], ["fe80::", 10], ["fec0::", 10], ["ff00::", 8],
]) NON_PUBLIC_ADDRESSES.addSubnet(address, prefix, "ipv6");

export function isPublicAddress(address, family) {
  const normalizedFamily = family === 4 ? "ipv4" : family === 6 ? "ipv6" : null;
  return Boolean(normalizedFamily && isIP(address) === family &&
    !NON_PUBLIC_ADDRESSES.check(address, normalizedFamily));
}

export function createPublicLookup(lookup = resolveDNS) {
  return function publicOnlyLookup(hostname, options, callback) {
    lookup(hostname, {
      all: true,
      family: options.family || 0,
      hints: options.hints,
      verbatim: true,
    }, (error, addresses) => {
      if (error) return callback(error);
      if (!addresses.length || addresses.some(({ address, family }) => !isPublicAddress(address, family))) {
        const blocked = new Error("Push endpoint resolved to a non-public address");
        blocked.code = "ENOTFOUND";
        return callback(blocked);
      }
      if (options.all) return callback(null, addresses);
      return callback(null, addresses[0].address, addresses[0].family);
    });
  };
}

export function createPushAgent(lookup = resolveDNS) {
  return new Agent({ keepAlive: false, lookup: createPublicLookup(lookup) });
}

export function sendBoundedPushRequest(details, {
  requestImpl = httpsRequest,
  timeoutMs = PUSH_TIMEOUT_MS,
  maximumBytes = PUSH_RESPONSE_LIMIT_BYTES,
} = {}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let response = null;
    let request;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(value);
    };
    const timer = setTimeout(() => {
      const error = new Error("Push request timed out");
      request?.destroy(error);
      response?.destroy();
      finish(error);
    }, timeoutMs);

    try {
      request = requestImpl(new URL(details.endpoint), {
        method: details.method,
        headers: details.headers,
        agent: details.agent,
      }, (incoming) => {
        response = incoming;
        let received = 0;
        incoming.on("data", (chunk) => {
          received += chunk.length;
          if (received > maximumBytes) {
            const error = new Error("Push response was too large");
            incoming.destroy();
            request.destroy(error);
            finish(error);
          }
        });
        incoming.on("aborted", () => finish(new Error("Push response was aborted")));
        incoming.on("error", (error) => finish(error));
        incoming.on("end", () => {
          const statusCode = incoming.statusCode ?? 0;
          if (statusCode < 200 || statusCode > 299) {
            const error = new Error("Push endpoint returned an unexpected status");
            error.statusCode = statusCode;
            finish(error);
          } else {
            finish(null, { statusCode });
          }
        });
      });
      request.on("error", (error) => finish(error));
      if (details.body) request.write(details.body);
      request.end();
    } catch (error) {
      request?.destroy();
      finish(error);
    }
  });
}

function normalizeSubscription(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  if (typeof value.endpoint !== "string" || value.endpoint.length > 2_048) return null;
  let endpoint;
  try {
    endpoint = new URL(value.endpoint);
  } catch {
    return null;
  }
  const hostname = endpoint.hostname.replace(/^\[|\]$/g, "");
  if (endpoint.protocol !== "https:" || endpoint.username || endpoint.password || isIP(hostname)) return null;
  const p256dh = value.keys?.p256dh;
  const auth = value.keys?.auth;
  if (typeof p256dh !== "string" || p256dh.length < 16 || p256dh.length > 512 ||
      typeof auth !== "string" || auth.length < 8 || auth.length > 256) return null;
  const expirationTime = value.expirationTime === null || value.expirationTime === undefined
    ? null
    : Number(value.expirationTime);
  if (expirationTime !== null && (!Number.isFinite(expirationTime) || expirationTime < 0)) return null;
  return {
    endpoint: endpoint.toString(),
    expirationTime,
    keys: { p256dh, auth },
  };
}

function endpointID(endpoint) {
  return createHash("sha256").update(endpoint).digest("base64url");
}

export class PushService {
  constructor({
    vapid,
    store,
    webPush = null,
    logger = console,
    agent = createPushAgent(),
    sendRequest = sendBoundedPushRequest,
  }) {
    this.vapid = vapid;
    this.store = store;
    this.webPush = webPush;
    this.logger = logger;
    this.agent = agent;
    this.sendRequest = sendRequest;
  }

  async init() {
    if (!this.vapid) return;
    if (!this.webPush) this.webPush = (await import("web-push")).default;
    this.webPush.setVapidDetails(this.vapid.subject, this.vapid.publicKey, this.vapid.privateKey);
  }

  get enabled() {
    return Boolean(this.vapid && this.webPush);
  }

  get publicKey() {
    return this.enabled ? this.vapid.publicKey : null;
  }

  async subscribe(value) {
    if (!this.enabled) return { ok: false, reason: "disabled" };
    const subscription = normalizeSubscription(value);
    if (!subscription) return { ok: false, reason: "invalid" };
    const id = endpointID(subscription.endpoint);
    await this.store.update((state) => {
      const existing = state.subscriptions.filter((item) => item.id !== id);
      state.subscriptions = [...existing, { id, subscription }].slice(-100);
    });
    return { ok: true };
  }

  async unsubscribe(value) {
    if (!value || typeof value.endpoint !== "string") return false;
    const id = endpointID(value.endpoint);
    let removed = false;
    await this.store.update((state) => {
      const next = state.subscriptions.filter((item) => item.id !== id);
      removed = next.length !== state.subscriptions.length;
      state.subscriptions = next;
    });
    return removed;
  }

  async notify(alerts) {
    if (!this.enabled) return;
    const entries = this.store.snapshot().subscriptions;
    if (!entries.length) return;
    const critical = alerts.filter((alert) => alert.severity === "critical").length;
    const payload = JSON.stringify({
      kind: alerts.length ? "alert" : "resolved",
      count: alerts.length,
      critical: critical > 0,
    });
    const expired = [];
    const results = await Promise.allSettled(entries.map(async (entry) => {
      try {
        const subscription = normalizeSubscription(entry.subscription);
        if (!subscription) {
          expired.push(entry.id);
          return;
        }
        const details = this.webPush.generateRequestDetails(subscription, payload, {
          TTL: 60,
          urgency: "high",
          agent: this.agent,
        });
        await this.sendRequest(details);
      } catch (error) {
        if (error?.statusCode === 404 || error?.statusCode === 410) expired.push(entry.id);
        else this.logger.warn?.("No se pudo entregar una notificación push");
      }
    }));
    void results;
    if (expired.length) {
      const expiredSet = new Set(expired);
      await this.store.update((state) => {
        state.subscriptions = state.subscriptions.filter((item) => !expiredSet.has(item.id));
      });
    }
  }
}
