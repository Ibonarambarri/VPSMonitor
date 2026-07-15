import { constants } from "node:fs";
import { mkdir, open, readFile, rename, unlink } from "node:fs/promises";
import path from "node:path";
import { randomBytes } from "node:crypto";

const initialState = Object.freeze({
  version: 1,
  dashboard: null,
  cpuSnapshot: null,
  alertSignature: "",
  subscriptions: [],
  sessionGeneration: 0,
});

function normalizedState(value) {
  if (!value || value.version !== 1 || typeof value !== "object" || Array.isArray(value)) {
    return structuredClone(initialState);
  }
  return {
    version: 1,
    dashboard: value.dashboard && typeof value.dashboard === "object" ? value.dashboard : null,
    cpuSnapshot: value.cpuSnapshot && typeof value.cpuSnapshot === "object" ? value.cpuSnapshot : null,
    alertSignature: typeof value.alertSignature === "string" ? value.alertSignature : "",
    subscriptions: Array.isArray(value.subscriptions) ? value.subscriptions : [],
    sessionGeneration: Number.isSafeInteger(value.sessionGeneration) && value.sessionGeneration >= 0
      ? value.sessionGeneration
      : 0,
  };
}

export class JSONStore {
  constructor(directory) {
    this.directory = directory;
    this.file = path.join(directory, "state.json");
    this.state = structuredClone(initialState);
    this.queue = Promise.resolve();
  }

  async init() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    try {
      const text = await readFile(this.file, { encoding: "utf8", flag: constants.O_RDONLY | constants.O_NOFOLLOW });
      this.state = normalizedState(JSON.parse(text));
    } catch (error) {
      if (error.code !== "ENOENT" && error.code !== "ELOOP" && !(error instanceof SyntaxError)) throw error;
      await this.persist(this.state);
    }
    return this.snapshot();
  }

  snapshot() {
    return structuredClone(this.state);
  }

  getSessionGeneration() {
    return this.state.sessionGeneration;
  }

  async update(mutator) {
    const operation = this.queue.then(async () => {
      const draft = this.snapshot();
      const result = await mutator(draft);
      this.state = normalizedState(result ?? draft);
      await this.persist(this.state);
      return this.snapshot();
    });
    this.queue = operation.catch(() => undefined);
    return operation;
  }

  async persist(state) {
    const temporary = path.join(this.directory, `.state-${process.pid}-${randomBytes(8).toString("hex")}.tmp`);
    let handle;
    try {
      handle = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
      await handle.writeFile(`${JSON.stringify(state)}\n`, "utf8");
      await handle.sync();
      await handle.close();
      handle = null;
      await rename(temporary, this.file);
    } finally {
      await handle?.close().catch(() => undefined);
      await unlink(temporary).catch(() => undefined);
    }
  }
}
