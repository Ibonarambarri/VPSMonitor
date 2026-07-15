import assert from "node:assert/strict";
import test from "node:test";
import { parseNodeExporterMetrics, parsePrometheus } from "../src/prometheus.js";

const fixture = `
# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
node_cpu_seconds_total{cpu="0",mode="idle"} 60
node_cpu_seconds_total{cpu="0",mode="user"} 40
node_cpu_seconds_total{cpu="1",mode="idle"} 50
node_cpu_seconds_total{cpu="1",mode="user"} 50
node_cpu_seconds_total{cpu="0",mode="guest"} 20
node_cpu_seconds_total{cpu="0",mode="guest_nice"} 10
node_memory_MemTotal_bytes 1000
node_memory_MemAvailable_bytes 400
node_filesystem_size_bytes{device="/dev/vda1",fstype="ext4",mountpoint="/"} 2000
node_filesystem_avail_bytes{device="/dev/vda1",fstype="ext4",mountpoint="/"} 500
node_load1 0.5
node_load5 0.4
node_load15 0.3
node_time_seconds 1100
node_boot_time_seconds 100
ignored_metric NaN
`;

test("Prometheus parser handles labelled samples and ignores comments/non-finite values", () => {
  const parsed = parsePrometheus(fixture);
  assert.equal(parsed.get("node_cpu_seconds_total").length, 6);
  assert.deepEqual({ ...parsed.get("node_cpu_seconds_total")[0].labels }, { cpu: "0", mode: "idle" });
  assert.equal(parsed.has("ignored_metric"), false);
});

test("node_exporter metrics calculate deltas, usage, load, and uptime", () => {
  const result = parseNodeExporterMetrics(fixture, { total: 100, idle: 50 });
  assert.equal(result.metrics.cpuPercent, 40);
  assert.equal(result.metrics.memoryUsedBytes, 600);
  assert.equal(result.metrics.memoryTotalBytes, 1000);
  assert.equal(result.metrics.diskUsedBytes, 1500);
  assert.equal(result.metrics.diskTotalBytes, 2000);
  assert.deepEqual(
    [result.metrics.load1, result.metrics.load5, result.metrics.load15, result.metrics.uptimeSeconds],
    [0.5, 0.4, 0.3, 1000],
  );
  assert.deepEqual(result.cpuSnapshot, { total: 200, idle: 110 });
});

test("the first CPU sample returns a baseline rather than an invented percentage", () => {
  const result = parseNodeExporterMetrics(fixture);
  assert.equal(result.metrics.cpuPercent, null);
  assert.deepEqual(result.cpuSnapshot, { total: 200, idle: 110 });
});
