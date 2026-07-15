import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { buildAlerts, overallState } from "../src/alerts.js";
import { DashboardService } from "../src/dashboard.js";
import { JSONStore } from "../src/store.js";

const thresholds = {
  cpuWarning: 80, cpuCritical: 90,
  memoryWarning: 80, memoryCritical: 90,
  diskWarning: 80, diskCritical: 90,
};

test("threshold and unhealthy-resource alerts determine the aggregate state", () => {
  const alerts = buildAlerts({
    server: {
      available: true, cpuPercent: 85,
      memoryUsedBytes: 95, memoryTotalBytes: 100,
      diskUsedBytes: 10, diskTotalBytes: 100,
    },
    coolify: {
      available: true,
      projects: [{ id: "p", name: "Project", environments: [{ id: "e", name: "prod", resources: [{
        id: "app", name: "API", status: "running:unhealthy", state: "critical", type: "Aplicación", url: null,
      }] }] }],
    },
    thresholds,
    observedAt: "2026-07-15T10:00:00.000Z",
  });
  assert.deepEqual(alerts.map(({ id, severity }) => [id, severity]), [
    ["coolify:app", "critical"],
    ["server:memory", "critical"],
    ["server:cpu", "warning"],
  ]);
  assert.equal(overallState(alerts), "critical");
});

test("dashboard refresh persists bounded history and notifies only on alert-set changes", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "vpsmonitor-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const store = new JSONStore(directory);
  const notifications = [];
  const push = {
    async init() {},
    async notify(alerts) { notifications.push(alerts.map((alert) => alert.id)); },
  };
  let sequence = 0;
  const exporter = { async collect() {
    sequence += 1;
    return {
      cpuSnapshot: { total: sequence * 100, idle: sequence * 50 },
      metrics: {
        cpuPercent: 95, memoryUsedBytes: 50, memoryTotalBytes: 100,
        diskUsedBytes: 20, diskTotalBytes: 100, load1: 1, load5: 0.5, load15: 0.25, uptimeSeconds: 100,
      },
    };
  } };
  const coolify = { async collect() { return []; } };
  let now = Date.parse("2026-07-15T10:00:00.000Z");
  const service = new DashboardService({
    config: {
      serverName: "test-vps", coolifyDashboardURL: "https://coolify.example.com",
      thresholds, historyLimit: 2, samplerIntervalMs: 60_000,
    },
    store, exporter, coolify, push,
    clock: () => new Date(now += 60_000),
    logger: { warn() {} },
  });
  await service.init({ refresh: false, schedule: false });
  await service.refresh();
  await service.refresh();
  await service.refresh();
  const dashboard = service.getDashboard();
  assert.equal(dashboard.server.history.length, 2);
  assert.equal(dashboard.overallState, "critical");
  assert.equal(notifications.length, 1);
  assert.equal(store.snapshot().dashboard.generatedAt, dashboard.generatedAt);
});
