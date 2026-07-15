import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { Agent } from "node:https";
import test from "node:test";
import {
  createPublicLookup,
  isPublicAddress,
  PushService,
  sendBoundedPushRequest,
} from "../src/push.js";

function fixture() {
  const state = {
    subscriptions: [{
      id: "subscription-1",
      subscription: {
        endpoint: "https://push.example.com/subscription-1",
        expirationTime: null,
        keys: { p256dh: "a".repeat(32), auth: "b".repeat(16) },
      },
    }],
  };
  const payloads = [];
  const options = [];
  const requests = [];
  const store = {
    snapshot: () => structuredClone(state),
    async update(callback) { await callback(state); },
  };
  const webPush = {
    setVapidDetails() {},
    generateRequestDetails(subscription, payload, requestOptions) {
      payloads.push(payload);
      options.push(requestOptions);
      return {
        endpoint: subscription.endpoint,
        method: "POST",
        headers: {},
        body: Buffer.from(payload),
        agent: requestOptions.agent,
      };
    },
  };
  const service = new PushService({
    vapid: { subject: "mailto:test@example.com", publicKey: "public", privateKey: "private" },
    store,
    webPush,
    async sendRequest(details) { requests.push(details); },
  });
  return { service, payloads, options, requests };
}

test("push payloads contain status counts but no resource details", async () => {
  const { service, payloads, options } = fixture();
  await service.init();
  await service.notify([{ severity: "critical", title: "private-project-name" }]);
  await service.notify([]);

  assert.deepEqual(payloads.map(JSON.parse), [
    { kind: "alert", count: 1, critical: true },
    { kind: "resolved", count: 0, critical: false },
  ]);
  assert.equal(payloads.join(" ").includes("private-project-name"), false);
  assert.equal(options.every((value) => value.agent instanceof Agent), true);
});

test("push subscriptions reject direct IP endpoints", async () => {
  const { service } = fixture();
  await service.init();
  const result = await service.subscribe({
    endpoint: "https://127.0.0.1/internal",
    expirationTime: null,
    keys: { p256dh: "a".repeat(32), auth: "b".repeat(16) },
  });
  assert.deepEqual(result, { ok: false, reason: "invalid" });
});

test("push DNS policy permits public addresses and blocks internal destinations", async () => {
  assert.equal(isPublicAddress("8.8.8.8", 4), true);
  assert.equal(isPublicAddress("127.0.0.1", 4), false);
  assert.equal(isPublicAddress("2607:f8b0:4005:805::200e", 6), true);
  assert.equal(isPublicAddress("::1", 6), false);

  const runLookup = (addresses) => new Promise((resolve) => {
    const lookup = createPublicLookup((_hostname, _options, callback) => callback(null, addresses));
    lookup("push.example.com", { all: false, family: 0, hints: 0 }, (error, address, family) => {
      resolve({ error, address, family });
    });
  });
  const allowed = await runLookup([{ address: "8.8.8.8", family: 4 }]);
  assert.equal(allowed.error, null);
  assert.deepEqual([allowed.address, allowed.family], ["8.8.8.8", 4]);

  const blocked = await runLookup([{ address: "10.0.0.5", family: 4 }]);
  assert.equal(blocked.error?.code, "ENOTFOUND");
});

function fakeRequest(responseFactory = null) {
  return (_url, _options, callback) => {
    const request = new EventEmitter();
    request.write = () => true;
    request.end = () => {
      if (!responseFactory) return;
      const response = responseFactory();
      callback(response);
    };
    request.destroy = (error) => {
      if (error) queueMicrotask(() => request.emit("error", error));
    };
    return request;
  };
}

test("bounded push transport enforces an absolute timeout and response limit", async () => {
  const details = { endpoint: "https://push.example.com/endpoint", method: "POST", headers: {}, body: null };
  await assert.rejects(
    sendBoundedPushRequest(details, { requestImpl: fakeRequest(), timeoutMs: 10 }),
    /timed out/,
  );

  const oversizedResponse = () => {
    const response = new EventEmitter();
    response.statusCode = 200;
    response.destroy = () => {};
    queueMicrotask(() => response.emit("data", Buffer.alloc(33)));
    return response;
  };
  await assert.rejects(
    sendBoundedPushRequest(details, {
      requestImpl: fakeRequest(oversizedResponse),
      timeoutMs: 100,
      maximumBytes: 32,
    }),
    /too large/,
  );
});
