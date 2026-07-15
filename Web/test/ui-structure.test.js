import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const publicURL = new URL("../public/", import.meta.url);

test("projects are integrated in the Coolify summary and alerts stay separate", async () => {
  const html = await readFile(new URL("index.html", publicURL), "utf8");

  const coolifyStart = html.indexOf('<section class="group-card coolify-card"');
  const coolifyEnd = html.indexOf("</section>", coolifyStart);
  const coolifySection = html.slice(coolifyStart, coolifyEnd);

  assert.match(coolifySection, /id="projects-list"/);
  assert.doesNotMatch(html, /data-page="projects"/);
  assert.doesNotMatch(html, /data-route="projects"/);
  assert.doesNotMatch(html, /id="alert-preview"/);
  assert.match(html, /data-page="alerts"/);
  assert.match(html, /data-route="alerts"/);
});

test("the installable icon uses a monochrome server mark", async () => {
  const html = await readFile(new URL("index.html", publicURL), "utf8");
  const svg = await readFile(new URL("icons/vpsmonitor-mark-v3.svg", publicURL), "utf8");
  const manifest = JSON.parse(await readFile(new URL("manifest.webmanifest", publicURL), "utf8"));

  assert.match(svg, /fill="#fff"/);
  assert.match(svg, /stroke="#111"/);
  assert.doesNotMatch(svg, /#0a84ff|#007aff/i);
  assert.equal(svg.match(/<rect x=/g)?.length, 3);
  assert.match(html, /vpsmonitor-apple-touch-icon-v3-180\.png/);
  assert.match(html, /manifest\.webmanifest\?v=3/);
  assert.doesNotMatch(html, /apple-touch-icon-180\.png|icons\/favicon\.svg/);
  assert.deepEqual(manifest.icons.map((icon) => icon.src), [
    "/icons/vpsmonitor-mark-v3.svg",
    "/icons/vpsmonitor-icon-v3-192.png",
    "/icons/vpsmonitor-icon-v3-512.png",
    "/icons/vpsmonitor-icon-v3-maskable-512.png",
  ]);
  assert.equal(manifest.background_color, "#ffffff");
  assert.equal(manifest.theme_color, "#ffffff");
});

test("the mobile layout does not enforce a viewport wider than the device", async () => {
  const css = await readFile(new URL("styles.css", publicURL), "utf8");

  assert.doesNotMatch(css, /min-width:\s*320px/);
  assert.match(css, /grid-template-columns:\s*repeat\(3, 1fr\)/);
});
