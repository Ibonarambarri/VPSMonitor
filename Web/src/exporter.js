import { fixedFetchText } from "./net.js";
import { parseNodeExporterMetrics } from "./prometheus.js";

export class NodeExporterClient {
  constructor({ url, timeoutMs, maximumBytes, fetchImpl = globalThis.fetch }) {
    this.url = url;
    this.timeoutMs = timeoutMs;
    this.maximumBytes = maximumBytes;
    this.fetchImpl = fetchImpl;
  }

  async collect(previousCPUSnapshot) {
    const text = await fixedFetchText(this.fetchImpl, this.url, {
      timeoutMs: this.timeoutMs,
      maximumBytes: this.maximumBytes,
      headers: { Accept: "text/plain; version=0.0.4" },
    });
    return parseNodeExporterMetrics(text, previousCPUSnapshot);
  }
}
