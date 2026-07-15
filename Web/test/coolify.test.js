import assert from "node:assert/strict";
import test from "node:test";
import {
  CoolifyClient,
  normalizeCoolifyProjects,
  normalizeResourceURL,
  resourceState,
} from "../src/coolify.js";

test("Coolify status precedence matches the macOS client", () => {
  assert.equal(resourceState("running:unhealthy"), "critical");
  assert.equal(resourceState("restarting"), "warning");
  assert.equal(resourceState("running:healthy"), "healthy");
  assert.equal(resourceState("mystery"), "unknown");
  assert.equal(normalizeResourceURL("api.example.com,other.example.com"), "https://api.example.com/");
  assert.equal(normalizeResourceURL("javascript:alert(1)"), null);
});

test("Coolify inventory is grouped, deduplicated, and normalized by environment", () => {
  const project = {
    uuid: "project-1",
    name: "Proyecto",
    environments: [{ id: 7, uuid: "env-1", name: "production", applications: [{
      uuid: "app-1", name: "API old", status: "running:healthy",
    }] }],
  };
  const projects = normalizeCoolifyProjects({
    details: [project],
    summaries: [project],
    applications: [{
      uuid: "app-1", name: "API", status: "running:healthy", environment_id: 7,
      fqdn: "https://api.example.com",
    }],
    services: [{ uuid: "service-1", name: "Worker", status: "stopped", environment_id: 7 }],
    databases: [],
  });
  assert.equal(projects[0].environments[0].resources.length, 2);
  assert.deepEqual(projects[0].environments[0].resources.map(({ id, state }) => [id, state]), [
    ["app-1", "healthy"],
    ["service-1", "critical"],
  ]);
});

test("Coolify client uses only fixed API paths and a server-side bearer token", async () => {
  const calls = [];
  const responses = new Map([
    ["/api/v1/projects", [{ uuid: "project-1", name: "Proyecto" }]],
    ["/api/v1/applications", []],
    ["/api/v1/services", []],
    ["/api/v1/databases", []],
    ["/api/v1/projects/project-1", { uuid: "project-1", name: "Proyecto", environments: [] }],
  ]);
  const fetchImpl = async (url, options) => {
    calls.push({ url: url.toString(), options });
    return new Response(JSON.stringify(responses.get(new URL(url).pathname)), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };
  const client = new CoolifyClient({
    baseURL: "https://coolify.example.com",
    token: "private-token",
    timeoutMs: 1_000,
    maximumBytes: 100_000,
    fetchImpl,
  });
  const projects = await client.collect();
  assert.equal(projects[0].id, "project-1");
  assert.equal(calls.length, 5);
  assert.ok(calls.every((call) => call.url.startsWith("https://coolify.example.com/api/v1/")));
  assert.ok(calls.every((call) => call.options.headers.Authorization === "Bearer private-token"));
  assert.ok(calls.every((call) => call.options.redirect === "error" && call.options.method === "GET"));
});
