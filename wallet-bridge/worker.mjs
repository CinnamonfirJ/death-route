import { DurableObject } from "cloudflare:workers";
import { createHandler } from "./auth-service.mjs";

export class SignInState extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    const sql = ctx.storage.sql;
    sql.exec("CREATE TABLE IF NOT EXISTS auth_state (kind TEXT, key TEXT, value TEXT, PRIMARY KEY (kind, key))");
    const store = (kind) => ({
      get: (key) => {
        if (typeof key !== "string") return undefined;
        const row = sql.exec("SELECT value FROM auth_state WHERE kind = ? AND key = ?", kind, key).toArray()[0];
        return row ? JSON.parse(row.value) : undefined;
      },
      set: (key, value) => sql.exec("INSERT OR REPLACE INTO auth_state VALUES (?, ?, ?)", kind, key, JSON.stringify(value)),
      delete: (key) => {
        if (typeof key === "string") sql.exec("DELETE FROM auth_state WHERE kind = ? AND key = ?", kind, key);
      },
      values: () => sql.exec("SELECT value FROM auth_state WHERE kind = ?", kind).toArray().map((row) => JSON.parse(row.value)),
      entries: () => sql.exec("SELECT key, value FROM auth_state WHERE kind = ?", kind).toArray()
        .map((row) => [row.key, JSON.parse(row.value)]),
      get size() {
        return sql.exec("SELECT count(*) AS count FROM auth_state WHERE kind = ?", kind).one().count;
      },
      [Symbol.iterator]() { return this.entries()[Symbol.iterator](); },
    });
    this.handle = createHandler({
      flows: store("flow"), states: store("state"), sessions: store("session"),
      background: (promise) => ctx.waitUntil(promise),
    });
  }

  async fetch(request) {
    // Remove expired session and pairing data even if the player never returns.
    if (await this.ctx.storage.getAlarm() === null) {
      await this.ctx.storage.setAlarm(Date.now() + 5 * 60_000);
    }
    const url = new URL(request.url);
    const reader = request.body?.getReader();
    const req = {
      method: request.method,
      url: url.pathname + url.search,
      headers: Object.fromEntries(request.headers),
      async *[Symbol.asyncIterator]() {
        if (!reader) return;
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            yield Buffer.from(value);
          }
        } finally {
          await reader.cancel();
        }
      },
    };
    const headers = new Headers();
    let status = 200;
    let response;
    await this.handle(req, {
      get headersSent() { return response !== undefined; },
      setHeader: (name, value) => headers.set(name, value),
      writeHead(code, fields = {}) {
        status = code;
        for (const [name, value] of Object.entries(fields)) headers.set(name, value);
      },
      end(body) { response = new Response(body ?? null, { status, headers }); },
    });
    return response ?? new Response("Sign-in unavailable", { status: 500 });
  }

  async alarm() {
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM auth_state WHERE kind IN ('flow', 'session') AND json_extract(value, '$.expires') <= ?", Date.now());
    sql.exec("DELETE FROM auth_state AS state WHERE kind = 'state' AND NOT EXISTS (SELECT 1 FROM auth_state AS flow WHERE flow.kind = 'flow' AND flow.key = json_extract(state.value, '$'))");
    if (sql.exec("SELECT 1 FROM auth_state LIMIT 1").toArray().length) {
      await this.ctx.storage.setAlarm(Date.now() + 5 * 60_000);
    }
  }
}

export default {
  fetch(request, env) {
    return env.SIGN_IN.getByName("production").fetch(request);
  },
};
