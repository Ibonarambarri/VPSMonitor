import { alertSignature, buildAlerts, overallState } from "./alerts.js";

function emptyServer(name, history = []) {
  return {
    available: false,
    name,
    cpuPercent: 0,
    memoryUsedBytes: 0,
    memoryTotalBytes: 0,
    diskUsedBytes: 0,
    diskTotalBytes: 0,
    load1: 0,
    load5: 0,
    load15: 0,
    uptimeSeconds: 0,
    history,
  };
}

function emptyCoolify(dashboardUrl, projects = []) {
  return { available: false, dashboardUrl, projects };
}

function memoryPercent(server) {
  return server.memoryTotalBytes > 0 ? server.memoryUsedBytes / server.memoryTotalBytes * 100 : 0;
}

export class DashboardService {
  constructor({ config, store, exporter, coolify, push, clock = () => new Date(), logger = console }) {
    this.config = config;
    this.store = store;
    this.exporter = exporter;
    this.coolify = coolify;
    this.push = push;
    this.clock = clock;
    this.logger = logger;
    this.dashboard = null;
    this.ready = false;
    this.refreshing = null;
    this.timer = null;
  }

  async init({ refresh = true, schedule = true } = {}) {
    const state = await this.store.init();
    await this.push.init();
    this.dashboard = state.dashboard;
    this.ready = true;
    if (refresh) await this.refresh();
    if (schedule) {
      this.timer = setInterval(() => {
        this.refresh().catch(() => this.logger.warn?.("No se pudo completar el muestreo periódico"));
      }, this.config.samplerIntervalMs);
      this.timer.unref?.();
    }
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  getDashboard() {
    if (this.dashboard) return structuredClone(this.dashboard);
    const generatedAt = this.clock().toISOString();
    const server = emptyServer(this.config.serverName);
    const coolify = emptyCoolify(this.config.coolifyDashboardURL);
    const alerts = buildAlerts({ server, coolify, thresholds: this.config.thresholds, observedAt: generatedAt });
    return { generatedAt, overallState: overallState(alerts), server, coolify, alerts, errors: [] };
  }

  async refresh() {
    if (this.refreshing) return this.refreshing;
    this.refreshing = this.performRefresh().finally(() => {
      this.refreshing = null;
    });
    return this.refreshing;
  }

  async performRefresh() {
    const previousState = this.store.snapshot();
    const previous = this.dashboard;
    const [serverResult, coolifyResult] = await Promise.allSettled([
      this.exporter.collect(previousState.cpuSnapshot),
      this.coolify.collect(),
    ]);
    const generatedAt = this.clock().toISOString();
    const errors = [];

    let server;
    let cpuSnapshot = previousState.cpuSnapshot;
    if (serverResult.status === "fulfilled") {
      const collected = serverResult.value;
      cpuSnapshot = collected.cpuSnapshot ?? cpuSnapshot;
      server = {
        available: true,
        name: this.config.serverName,
        ...collected.metrics,
        cpuPercent: collected.metrics.cpuPercent ?? previous?.server?.cpuPercent ?? 0,
        history: Array.isArray(previous?.server?.history) ? previous.server.history : [],
      };
      server.history = [...server.history, {
        timestamp: generatedAt,
        cpuPercent: server.cpuPercent,
        memoryPercent: memoryPercent(server),
      }].slice(-this.config.historyLimit);
    } else {
      server = previous?.server
        ? { ...previous.server, available: false, name: this.config.serverName }
        : emptyServer(this.config.serverName);
      errors.push("No se pudieron actualizar las métricas del servidor.");
    }

    let coolify;
    if (coolifyResult.status === "fulfilled") {
      coolify = {
        available: true,
        dashboardUrl: this.config.coolifyDashboardURL,
        projects: coolifyResult.value,
      };
    } else {
      coolify = previous?.coolify
        ? { ...previous.coolify, available: false, dashboardUrl: this.config.coolifyDashboardURL }
        : emptyCoolify(this.config.coolifyDashboardURL);
      errors.push("No se pudo actualizar el inventario de Coolify.");
    }

    const alerts = buildAlerts({ server, coolify, thresholds: this.config.thresholds, observedAt: generatedAt });
    const dashboard = {
      generatedAt,
      overallState: overallState(alerts),
      server,
      coolify,
      alerts,
      errors,
    };
    const nextSignature = alertSignature(alerts);
    await this.store.update((state) => {
      state.dashboard = dashboard;
      state.cpuSnapshot = cpuSnapshot;
      state.alertSignature = nextSignature;
    });
    this.dashboard = dashboard;
    if (nextSignature !== previousState.alertSignature) {
      void this.push.notify(alerts).catch(() => this.logger.warn?.("No se pudieron enviar las notificaciones"));
    }
    return this.getDashboard();
  }
}
