const metricLine = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+([^\s]+)(?:\s+\d+)?$/;
const labelPart = /\s*([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"\s*(?:,|$)/gy;

function decodeLabel(value) {
  return value.replace(/\\([\\"n])/g, (_, escaped) => escaped === "n" ? "\n" : escaped);
}

function parseLabels(source) {
  const labels = Object.create(null);
  if (source === undefined || source === "") return labels;
  labelPart.lastIndex = 0;
  let consumed = 0;
  let match;
  while ((match = labelPart.exec(source)) !== null) {
    labels[match[1]] = decodeLabel(match[2]);
    consumed = labelPart.lastIndex;
  }
  if (consumed !== source.length) return null;
  return labels;
}

export function parsePrometheus(text) {
  if (typeof text !== "string") throw new TypeError("Prometheus input must be text");
  const metrics = new Map();
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = metricLine.exec(line);
    if (!match) continue;
    const value = Number(match[3]);
    const labels = parseLabels(match[2]);
    if (!Number.isFinite(value) || !labels) continue;
    const samples = metrics.get(match[1]) ?? [];
    samples.push({ labels, value });
    metrics.set(match[1], samples);
  }
  return metrics;
}

function firstValue(metrics, name, predicate = () => true) {
  return metrics.get(name)?.find((sample) => predicate(sample.labels))?.value ?? null;
}

function nonNegative(value) {
  return Number.isFinite(value) && value >= 0 ? value : 0;
}

export function parseNodeExporterMetrics(text, previousCPUSnapshot = null) {
  const samples = parsePrometheus(text);
  const cpuSamples = samples.get("node_cpu_seconds_total") ?? [];
  let total = 0;
  let idle = 0;
  for (const sample of cpuSamples) {
    // Linux already includes guest time in user/nice, so counting these modes again inflates the total.
    if (sample.labels.mode === "guest" || sample.labels.mode === "guest_nice") continue;
    total += nonNegative(sample.value);
    if (sample.labels.mode === "idle") idle += nonNegative(sample.value);
  }

  const cpuSnapshot = total > 0 ? { total, idle } : null;
  let cpuPercent = null;
  if (cpuSnapshot && previousCPUSnapshot) {
    const totalDelta = total - Number(previousCPUSnapshot.total);
    const idleDelta = idle - Number(previousCPUSnapshot.idle);
    if (totalDelta > 0 && idleDelta >= 0 && idleDelta <= totalDelta) {
      cpuPercent = Math.min(100, Math.max(0, (1 - idleDelta / totalDelta) * 100));
    }
  }

  const memoryTotalBytes = nonNegative(firstValue(samples, "node_memory_MemTotal_bytes"));
  let memoryAvailableBytes = firstValue(samples, "node_memory_MemAvailable_bytes");
  if (!Number.isFinite(memoryAvailableBytes)) {
    memoryAvailableBytes = [
      "node_memory_MemFree_bytes",
      "node_memory_Buffers_bytes",
      "node_memory_Cached_bytes",
      "node_memory_SReclaimable_bytes",
    ].reduce((sum, name) => sum + nonNegative(firstValue(samples, name)), 0);
  }
  const memoryUsedBytes = Math.max(0, memoryTotalBytes - nonNegative(memoryAvailableBytes));

  const rootFilesystem = (samples.get("node_filesystem_size_bytes") ?? []).find(({ labels }) =>
    labels.mountpoint === "/" && labels.fstype !== "rootfs",
  ) ?? (samples.get("node_filesystem_size_bytes") ?? []).find(({ labels }) => labels.mountpoint === "/");
  const diskTotalBytes = nonNegative(rootFilesystem?.value);
  const device = rootFilesystem?.labels.device;
  const fstype = rootFilesystem?.labels.fstype;
  const diskAvailableBytes = nonNegative(firstValue(samples, "node_filesystem_avail_bytes", (labels) =>
    labels.mountpoint === "/" && (!device || labels.device === device) && (!fstype || labels.fstype === fstype),
  ));

  let uptimeSeconds = firstValue(samples, "node_uptime_seconds");
  if (!Number.isFinite(uptimeSeconds)) {
    const currentTime = firstValue(samples, "node_time_seconds");
    const bootTime = firstValue(samples, "node_boot_time_seconds");
    uptimeSeconds = Number.isFinite(currentTime) && Number.isFinite(bootTime) ? currentTime - bootTime : 0;
  }

  return {
    cpuSnapshot,
    metrics: {
      cpuPercent,
      memoryUsedBytes,
      memoryTotalBytes,
      diskUsedBytes: Math.max(0, diskTotalBytes - diskAvailableBytes),
      diskTotalBytes,
      load1: nonNegative(firstValue(samples, "node_load1")),
      load5: nonNegative(firstValue(samples, "node_load5")),
      load15: nonNegative(firstValue(samples, "node_load15")),
      uptimeSeconds: nonNegative(uptimeSeconds),
    },
  };
}
