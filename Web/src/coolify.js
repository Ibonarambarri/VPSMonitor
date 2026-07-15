import { fixedFetchText, UpstreamError } from "./net.js";

const embeddedGroups = [
  ["applications", "Aplicación"],
  ["services", "Servicio"],
  ["databases", "Base de datos"],
  ["postgresqls", "PostgreSQL"],
  ["mysqls", "MySQL"],
  ["mariadbs", "MariaDB"],
  ["mongodbs", "MongoDB"],
  ["redis", "Redis"],
  ["keydbs", "KeyDB"],
  ["dragonflies", "Dragonfly"],
];

function identifier(value, fallback = "unknown") {
  const candidate = value?.uuid ?? value?.id;
  return candidate === undefined || candidate === null ? fallback : String(candidate);
}

function name(value, fallback) {
  return typeof value?.name === "string" && value.name.trim() ? value.name.trim() : fallback;
}

export function resourceState(status) {
  const value = String(status ?? "unknown").toLowerCase();
  if (["stop", "exit", "fail", "unhealthy"].some((part) => value.includes(part))) return "critical";
  if (["degraded", "starting", "restart"].some((part) => value.includes(part))) return "warning";
  if (["running", "healthy"].some((part) => value.includes(part))) return "healthy";
  return "unknown";
}

export function normalizeResourceURL(value) {
  if (typeof value !== "string") return null;
  const first = value.split(",", 1)[0].trim();
  if (!first) return null;
  const candidate = /^[a-z][a-z0-9+.-]*:/i.test(first) ? first : `https://${first}`;
  try {
    const url = new URL(candidate);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
    return url.toString();
  } catch {
    return null;
  }
}

function normalizeResource(value, type) {
  const status = typeof value?.status === "string" ? value.status : "unknown";
  return {
    id: identifier(value, `${type}:unknown`),
    name: name(value, type),
    type,
    status,
    state: resourceState(status),
    url: normalizeResourceURL(value?.fqdn),
  };
}

function normalizeInventory(values, fallbackType) {
  if (!Array.isArray(values)) return [];
  return values.flatMap((value) => {
    if (!Number.isSafeInteger(value?.environment_id)) return [];
    const type = typeof value.type === "string" && value.type.trim() ? value.type : fallbackType;
    return [{ environmentID: value.environment_id, resource: normalizeResource(value, type) }];
  });
}

function normalizeEnvironment(value, inventory) {
  const resources = [];
  for (const [key, type] of embeddedGroups) {
    if (Array.isArray(value?.[key])) {
      resources.push(...value[key].map((resource) => normalizeResource(resource, type)));
    }
  }
  if (Number.isSafeInteger(value?.id)) {
    resources.push(...inventory.filter((item) => item.environmentID === value.id).map((item) => item.resource));
  }
  const uniqueResources = [...new Map(resources.map((resource) => [resource.id, resource])).values()]
    .sort((left, right) => left.name.localeCompare(right.name, undefined, { numeric: true }));
  return {
    id: identifier(value, "environment:unknown"),
    name: name(value, "Entorno"),
    resources: uniqueResources,
  };
}

export function normalizeCoolifyProjects({ details, summaries, applications, services, databases }) {
  const inventory = [
    ...normalizeInventory(applications, "Aplicación"),
    ...normalizeInventory(services, "Servicio"),
    ...normalizeInventory(databases, "Base de datos"),
  ];
  const summariesByID = new Map((Array.isArray(summaries) ? summaries : [])
    .map((summary) => [identifier(summary, ""), summary])
    .filter(([id]) => id));
  return (Array.isArray(details) ? details : []).map((detail) => {
    const id = identifier(detail, "project:unknown");
    const fallback = summariesByID.get(id) ?? detail;
    return {
      id,
      name: name(detail, name(fallback, "Proyecto")),
      environments: (Array.isArray(detail?.environments) ? detail.environments : [])
        .map((environment) => normalizeEnvironment(environment, inventory)),
    };
  }).sort((left, right) => left.name.localeCompare(right.name, undefined, { numeric: true }));
}

function decodeJSON(text) {
  try {
    return JSON.parse(text);
  } catch {
    throw new UpstreamError("invalid_json");
  }
}

export class CoolifyClient {
  constructor({ baseURL, token, timeoutMs, maximumBytes, fetchImpl = globalThis.fetch }) {
    this.apiRoot = new URL(`${baseURL.replace(/\/$/, "")}/api/v1/`);
    this.token = token;
    this.timeoutMs = timeoutMs;
    this.maximumBytes = maximumBytes;
    this.fetchImpl = fetchImpl;
  }

  async get(path) {
    const url = new URL(path, this.apiRoot);
    if (url.origin !== this.apiRoot.origin || !url.pathname.startsWith(this.apiRoot.pathname)) {
      throw new UpstreamError("invalid_path");
    }
    const text = await fixedFetchText(this.fetchImpl, url, {
      timeoutMs: this.timeoutMs,
      maximumBytes: this.maximumBytes,
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${this.token}`,
      },
    });
    return decodeJSON(text);
  }

  async collect() {
    const [summaries, applications, services, databases] = await Promise.all([
      this.get("projects"),
      this.get("applications"),
      this.get("services"),
      this.get("databases"),
    ]);
    if (![summaries, applications, services, databases].every(Array.isArray)) {
      throw new UpstreamError("invalid_shape");
    }
    const details = await Promise.all(summaries.flatMap((summary) => {
      const id = typeof summary?.uuid === "string" ? summary.uuid : "";
      return id ? [this.get(`projects/${encodeURIComponent(id)}`)] : [];
    }));
    return normalizeCoolifyProjects({ details, summaries, applications, services, databases });
  }
}
