function percent(used, total) {
  return total > 0 ? used / total * 100 : 0;
}

function metricAlert({ id, title, value, warning, critical, source, observedAt }) {
  const severity = value >= critical ? "critical" : value >= warning ? "warning" : null;
  if (!severity) return null;
  return {
    id,
    severity,
    title,
    message: `${title}: ${value.toFixed(1)} %`,
    source,
    observedAt,
  };
}

function resourceAlerts(projects, observedAt) {
  const alerts = [];
  for (const project of projects) {
    for (const environment of project.environments) {
      for (const resource of environment.resources) {
        if (resource.state !== "critical" && resource.state !== "warning") continue;
        alerts.push({
          id: `coolify:${resource.id}`,
          severity: resource.state,
          title: `${resource.name} requiere atención`,
          message: `${project.name} / ${environment.name}: ${resource.status}`,
          source: "coolify",
          observedAt,
        });
      }
    }
  }
  return alerts;
}

export function buildAlerts({ server, coolify, thresholds, observedAt }) {
  const alerts = [];
  if (!server.available) {
    alerts.push({
      id: "node-exporter:unavailable",
      severity: "critical",
      title: "Servidor no disponible",
      message: "No se han podido actualizar las métricas del servidor.",
      source: "node-exporter",
      observedAt,
    });
  } else {
    alerts.push(
      metricAlert({ id: "server:cpu", title: "CPU alta", value: server.cpuPercent, warning: thresholds.cpuWarning, critical: thresholds.cpuCritical, source: "node-exporter", observedAt }),
      metricAlert({ id: "server:memory", title: "Memoria alta", value: percent(server.memoryUsedBytes, server.memoryTotalBytes), warning: thresholds.memoryWarning, critical: thresholds.memoryCritical, source: "node-exporter", observedAt }),
      metricAlert({ id: "server:disk", title: "Disco lleno", value: percent(server.diskUsedBytes, server.diskTotalBytes), warning: thresholds.diskWarning, critical: thresholds.diskCritical, source: "node-exporter", observedAt }),
    );
  }
  if (!coolify.available) {
    alerts.push({
      id: "coolify:unavailable",
      severity: "warning",
      title: "Coolify no disponible",
      message: "No se ha podido actualizar el inventario de Coolify.",
      source: "coolify",
      observedAt,
    });
  } else {
    alerts.push(...resourceAlerts(coolify.projects, observedAt));
  }
  return alerts.filter(Boolean).sort((left, right) => {
    const rank = { critical: 0, warning: 1 };
    return rank[left.severity] - rank[right.severity] || left.title.localeCompare(right.title);
  });
}

export function overallState(alerts) {
  if (alerts.some((alert) => alert.severity === "critical")) return "critical";
  if (alerts.some((alert) => alert.severity === "warning")) return "warning";
  return "healthy";
}

export function alertSignature(alerts) {
  return alerts.map(({ id, severity }) => `${id}:${severity}`).sort().join("|");
}
