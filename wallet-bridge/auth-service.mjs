import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { shotgunEntitlement } from "./near-entitlement.mjs";
import { provisioningReady, provisionAccount } from "./near-account.mjs";

const publicUrl = new URL(process.env.WALLET_PUBLIC_URL || "http://127.0.0.1:8787");
const callback = new URL("/oauth/callback", publicUrl).href;
const webOrigins = new Set((process.env.GAME_ORIGIN || "").split(",").map((origin) => origin.trim()));
const issuer = "https://accounts.google.com";
const clientId = process.env.GOOGLE_CLIENT_ID;
const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
const authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth";
const tokenEndpoint = "https://oauth2.googleapis.com/token";
const lifetime = 5 * 60_000;
const sessionLifetime = 60 * 60_000;
const jwks = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));
const googleReady = Boolean(clientId && clientSecret);

if (publicUrl.protocol !== "https:" && publicUrl.origin !== "http://127.0.0.1:8787") {
  throw new Error("WALLET_PUBLIC_URL requires HTTPS or the local desktop bridge URL.");
}


const randomToken = () => randomBytes(32).toString("base64url");
const hash = (value) => createHash("sha256").update(value);

function matches(value, expected) {
  return typeof value === "string" && value.length === expected.length &&
    timingSafeEqual(hash(value).digest(), hash(expected).digest());
}

async function readBody(req) {
  let body = "";
  for await (const chunk of req) {
    body += chunk.toString();
    if (body.length > 2048) throw new Error("Request too large");
  }
  if (req.headers["content-type"]?.split(";")[0] === "application/x-www-form-urlencoded") {
    return Object.fromEntries(new URLSearchParams(body));
  }
  const value = JSON.parse(body);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid body");
  return value;
}

function json(res, status, value) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(value));
}

function page(res, status, body) {
  res.writeHead(status, { "Content-Type": "text/html; charset=utf-8" });
  res.end(`<!doctype html><html lang="en"><meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1"><title>Dead Route Sign-In</title>
  <style>
    *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0d0b18;color:#fff2df;font:16px system-ui}
    main{background:#1a192e;border:1px solid #9a5960;width:min(420px,calc(100% - 32px));padding:28px}
    h1{margin:0;color:#ffc688;font-size:26px}p{line-height:1.55;color:#d1cede}
    label,input,button{display:block;width:100%}input,button{font:inherit;padding:10px;margin-top:10px;border:1px solid #9a5960}
    input{background:#0d0b18;color:#fff2df}button{background:#362238;color:#fff2df;cursor:pointer}
  </style><main><h1>Dead Route Sign-In</h1>${body}</main></html>`);
}

// The Node host uses memory. Cloudflare supplies persistent stores so a
// suspended instance cannot lose a sign-in between the browser and game.
export function createHandler({ flows = new Map(), states = new Map(), sessions = new Map(),
  background = () => {} } = {}) {
  const pendingAccounts = new Map();

  function removeFlow(flow) {
    flows.delete(flow.id);
    states.delete(flow.state);
  }

  function activeFlow(id) {
    const flow = flows.get(id);
    if (!flow || flow.expires > Date.now()) return flow;
    removeFlow(flow);
    return undefined;
  }

  function browserFlow(req, state) {
    const flow = activeFlow(states.get(state));
    const browser = (req.headers.cookie || "").match(/(?:^|; *)dr_signin=([^;]+)/)?.[1];
    return flow?.browser && matches(browser, flow.browser) ? flow : null;
  }

  function finishAccount(flow, subject) {
    if (!activeFlow(flow.id)) throw new Error("Pairing expired");
    const now = Date.now();
    for (const [key, value] of sessions) if (value.expires <= now) sessions.delete(key);
    if (sessions.size >= 1000) throw new Error("Too many sessions");
    const session = randomToken();
    const identity = { subject, account: null, expires: now + sessionLifetime, lastCheck: 0 };
    sessions.set(session, identity);
    flow.result = { signed_in: true, session, shotgun_owned: false };
    flows.set(flow.id, flow);
    if (provisioningReady) refreshItems(session, identity);
  }

  function refreshItems(session, identity) {
    if (!identity.account) {
      let work = pendingAccounts.get(identity.subject);
      if (!work) {
        work = provisionAccount(identity.subject).catch((error) => {
          console.error("Player account setup failed", error.type || error.name);
          return null;
        }).finally(() => pendingAccounts.delete(identity.subject));
        pendingAccounts.set(identity.subject, work);
      }
      background(work.then((account) => {
        const current = sessions.get(session);
        if (account && current?.expires > Date.now()) {
          sessions.set(session, { ...current, account });
        }
      }));
    }
  }

  async function finishLogin(req, res, url) {
    const state = url.searchParams.get("state");
    const flow = browserFlow(req, state);
    if (!flow) {
      return page(res, 400, "<p>This sign-in expired. Start again in the game.</p>");
    }
    states.delete(state);
    res.setHeader("Set-Cookie", pairingCookie("", 0));
    try {
      const code = url.searchParams.get("code");
      if (!code) throw new Error("Authorization rejected");
      const form = new URLSearchParams({
        grant_type: "authorization_code", client_id: clientId, code,
        redirect_uri: callback, code_verifier: flow.verifier,
      });
      form.set("client_secret", clientSecret);
      const response = await fetch(tokenEndpoint, {
        method: "POST", body: form, redirect: "error", signal: AbortSignal.timeout(10_000),
      });
      if (!response.ok) throw new Error("Token exchange failed");
      const { id_token: idToken } = await response.json();
      const { payload } = await jwtVerify(idToken, jwks, {
        issuer: [issuer, "accounts.google.com"],
        audience: clientId, algorithms: ["RS256"], requiredClaims: ["exp", "sub", "nonce"],
      });
      if (payload.nonce !== flow.nonce || typeof payload.sub !== "string" || !payload.sub ||
          (payload.azp !== undefined && payload.azp !== clientId)) {
        throw new Error("Invalid Google login");
      }
      finishAccount(flow, payload.sub);
      page(res, 200, "<p>Google sign-in is complete. Return to Dead Route.</p>");
    } catch {
      flow.error = "Google sign-in could not be completed. Try again or play as a guest.";
      if (activeFlow(flow.id)) flows.set(flow.id, flow);
      page(res, 502, "<p>Google sign-in could not be completed. Return to Dead Route to retry.</p>");
    }
  }

  function pairingCookie(value, age) {
    const secure = publicUrl.protocol === "https:" ? "; Secure" : "";
    return `dr_signin=${value}; Max-Age=${age}; Path=/oauth/callback; HttpOnly; SameSite=Lax${secure}`;
  }

  async function route(req, res) {
    const url = new URL(req.url, publicUrl);
    if (req.method === "GET" && url.pathname === "/healthz") {
      return json(res, 200, { service: "dead-route-sign-in", google_configured: googleReady, provisioning_configured: provisioningReady });
    }
    if (req.method === "POST" && url.pathname === "/api/device/start") {
      const { method } = await readBody(req);
      if (method !== undefined && method !== "google") {
        return json(res, 400, { error: "Use Google to sign in." });
      }
      if (!googleReady) {
        return json(res, 503, { error: "Google sign-in is unavailable. You can play as a guest." });
      }
      for (const flow of flows.values()) activeFlow(flow.id);
      if (flows.size >= 250) return json(res, 429, { error: "Sign-in is busy. Try again in a few minutes." });
      const flow = { id: randomToken(), secret: randomToken(), code: String(randomInt(100000, 1000000)),
        expires: Date.now() + lifetime, attempts: 0 };
      flows.set(flow.id, flow);
      return json(res, 200, { id: flow.id, secret: flow.secret, code: flow.code });
    }
    if (req.method === "POST" && url.pathname === "/api/device/poll") {
      const { id, secret } = await readBody(req);
      const flow = activeFlow(id);
      if (!flow || !matches(secret, flow.secret)) return json(res, 404, { error: "This sign-in code expired." });
      if (!flow.result && !flow.error) return json(res, 200, { pending: true });
      removeFlow(flow);
      return json(res, 200, flow.result || { error: flow.error });
    }
    if (req.method === "POST" && url.pathname === "/api/entitlement") {
      const { session } = await readBody(req);
      const identity = sessions.get(session);
      if (!identity || identity.expires <= Date.now()) {
        sessions.delete(session);
        return json(res, 401, { error: "Your sign-in expired. Sign in again." });
      }
      if (Date.now() - (identity.lastCheck || 0) < 2_000) {
        return json(res, 429, { error: "Please try again in a moment." });
      }
      identity.lastCheck = Date.now();
      sessions.set(session, identity);
      if (!identity.account) {
        if (provisioningReady) refreshItems(session, identity);
        return json(res, 200, provisioningReady ? { pending: true } : { shotgun_owned: false });
      }
      return json(res, 200, await shotgunEntitlement(identity.account.accountId, identity.account.accountNetwork));
    }
    if (req.method === "GET" && url.pathname === "/signin") {
      const flow = activeFlow(url.searchParams.get("flow"));
      if (!flow || flow.browser) return page(res, 400, "<p>Start a new sign-in in Dead Route.</p>");
      return page(res, 200, `<p>Enter the code shown in Dead Route to confirm this sign-in.</p>
        <form method="post" action="/signin"><input type="hidden" name="flow" value="${flow.id}">
        <label for="code">Game code</label><input id="code" name="code" inputmode="numeric" pattern="[0-9]{6}"
        maxlength="6" autocomplete="one-time-code" required><button>Continue with Google</button></form>`);
    }
    if (req.method === "POST" && url.pathname === "/signin") {
      if (req.headers.origin !== publicUrl.origin) return page(res, 403, "<p>Open sign-in from Dead Route.</p>");
      const { flow: id, code } = await readBody(req);
      const flow = activeFlow(id);
      if (!flow || flow.browser) return page(res, 400, "<p>Start a new sign-in in Dead Route.</p>");
      if (!matches(code, flow.code)) {
        if (++flow.attempts >= 5) removeFlow(flow);
        else flows.set(flow.id, flow);
        return page(res, 400, "<p>The code did not match. Go back and check the code in Dead Route.</p>");
      }
      flow.state = randomToken();
      flow.nonce = randomToken();
      flow.verifier = randomToken();
      flow.browser = randomToken();
      states.set(flow.state, flow.id);
      flows.set(flow.id, flow);
      const cookie = pairingCookie(flow.browser, 300);
      const authorize = new URL(authorizationEndpoint);
      authorize.search = new URLSearchParams({
        client_id: clientId, response_type: "code", scope: "openid", redirect_uri: callback,
        state: flow.state, nonce: flow.nonce,
        code_challenge: hash(flow.verifier).digest("base64url"), code_challenge_method: "S256",
      });
      res.writeHead(303, { Location: authorize.href, "Set-Cookie": cookie });
      return res.end();
    }
    if (req.method === "GET" && url.pathname === "/oauth/callback") return finishLogin(req, res, url);
    return json(res, 404, { error: "Page unavailable." });
  }

  return async (req, res) => {
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'");
    if (req.url.startsWith("/api/") && req.headers.origin) {
      if (!webOrigins.has(req.headers.origin) && req.headers.origin !== publicUrl.origin) {
        return json(res, 403, { error: "This game origin is not configured." });
      }
      res.setHeader("Access-Control-Allow-Origin", req.headers.origin);
      res.setHeader("Vary", "Origin");
      res.setHeader("Access-Control-Allow-Methods", "POST");
      res.setHeader("Access-Control-Allow-Headers", "Content-Type");
      if (req.method === "OPTIONS") {
        res.writeHead(204);
        return res.end();
      }
    }
    try {
      await route(req, res);
    } catch {
      if (!res.headersSent) json(res, 400, { error: "Invalid request." });
    }
  };
}
