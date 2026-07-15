export class UpstreamError extends Error {
  constructor(code) {
    super("Upstream request failed");
    this.name = "UpstreamError";
    this.code = code;
  }
}

export async function readLimitedText(response, maximumBytes) {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maximumBytes) throw new UpstreamError("response_too_large");
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maximumBytes) {
        await reader.cancel();
        throw new UpstreamError("response_too_large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const combined = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    combined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(combined);
}

export async function fixedFetchText(fetchImpl, url, {
  timeoutMs,
  maximumBytes,
  headers = {},
}) {
  let response;
  try {
    response = await fetchImpl(url, {
      method: "GET",
      headers,
      redirect: "error",
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    throw new UpstreamError("network");
  }
  if (!response.ok) throw new UpstreamError("http_status");
  try {
    return await readLimitedText(response, maximumBytes);
  } catch (error) {
    if (error instanceof UpstreamError) throw error;
    throw new UpstreamError("invalid_encoding");
  }
}
