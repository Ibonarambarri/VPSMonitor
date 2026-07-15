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
  const svg = await readFile(new URL("icons/favicon.svg", publicURL), "utf8");
  const manifest = JSON.parse(await readFile(new URL("manifest.webmanifest", publicURL), "utf8"));

  assert.match(svg, /fill="#fff"/);
  assert.match(svg, /stroke="#111"/);
  assert.doesNotMatch(svg, /#0a84ff|#007aff/i);
  assert.equal(manifest.background_color, "#ffffff");
  assert.equal(manifest.theme_color, "#ffffff");
});
