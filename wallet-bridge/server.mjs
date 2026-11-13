import { createServer } from "node:http";
<<<<<<< Updated upstream
import { createHandler } from "./auth-service.mjs";

const server = createServer(createHandler());
=======
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { connect, KeyPair, keyStores, utils } from "near-api-js";
import { network, shotgunEntitlement, verifyWallet, walletOrigin } from "./near-entitlement.mjs";
import { Market, loadRules } from "./market.mjs";
import { createChain } from "./nep245.mjs";

const publicUrl = new URL(process.env.WALLET_PUBLIC_URL || "http://127.0.0.1:8787");
const callback = new URL("/oauth/callback", publicUrl).href;
const walletCallback = new URL("/wallet/return", publicUrl).href;
const walletScript = await readFile(new URL("./wallet-browser.mjs", import.meta.url));
const webOrigin = process.env.GAME_ORIGIN;
const directGoogle = Boolean(process.env.GOOGLE_CLIENT_ID || process.env.GOOGLE_CLIENT_SECRET);
const issuer = directGoogle ? "https://accounts.google.com" :
  process.env.OIDC_ISSUER ? new URL(process.env.OIDC_ISSUER).origin + "/" : "";
const clientId = directGoogle ? process.env.GOOGLE_CLIENT_ID : process.env.OIDC_CLIENT_ID;
const clientSecret = directGoogle ? process.env.GOOGLE_CLIENT_SECRET : process.env.OIDC_CLIENT_SECRET;
const authorizationEndpoint = directGoogle ? "https://accounts.google.com/o/oauth2/v2/auth" :
  issuer ? new URL("authorize", issuer).href : "";
const tokenEndpoint = directGoogle ? "https://oauth2.googleapis.com/token" :
  issuer ? new URL("oauth/token", issuer).href : "";
const jwksEndpoint = directGoogle ? "https://www.googleapis.com/oauth2/v3/certs" :
  issuer ? new URL(".well-known/jwks.json", issuer).href : "";
const relayerId = process.env.NEAR_RELAYER_ACCOUNT;
const relayerKey = process.env.NEAR_RELAYER_KEY;
const lifetime = 5 * 60_000;
const flows = new Map();
const states = new Map();
const sessions = new Map();
const sessionLifetime = 60 * 60_000;
const jwks = jwksEndpoint ? createRemoteJWKSet(new URL(jwksEndpoint)) : null;
const googleReady = Boolean(issuer.startsWith("https://") && clientId && (!directGoogle || clientSecret));
// With a funded relayer, every Google identity gets its own NEAR account the relayer controls
// (the player never sees it). Without one, the identity is still stable for the camp market.
const relayerReady = Boolean(relayerKey && /^[a-z0-9][a-z0-9_.-]{0,33}\.testnet$/.test(relayerId || ""));

if (publicUrl.protocol !== "https:" && publicUrl.origin !== "http://127.0.0.1:8787") {
  throw new Error("WALLET_PUBLIC_URL requires HTTPS or the local desktop bridge URL.");
}

// Camp Market: merchant books + NEP-245 mirror. Rules live in economy/pricing_rules.toml.
const rulesPath = process.env.MARKET_RULES || fileURLToPath(new URL("../economy/pricing_rules.toml", import.meta.url));
const marketChain = createChain();
const market = new Market(loadRules(rulesPath), { chain: marketChain,
  persistPath: fileURLToPath(new URL(process.env.MARKET_DATA_FILE || "data/market.json", import.meta.url)) });
const allowGuests = (process.env.MARKET_ALLOW_GUESTS ?? "1") !== "0";
setInterval(() => market.tick(), 60_000).unref();

let near;
let provisioning = Promise.resolve();
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
  <meta name="viewport" content="width=device-width,initial-scale=1"><title>Dead Route Wallet</title>
  <style>
    *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0d0b18;color:#fff2df;font:16px system-ui}
    main{background:#1a192e;border:1px solid #9a5960;width:min(420px,calc(100% - 32px));padding:28px}
    h1{margin:0;color:#ffc688;font-size:26px}p{line-height:1.55;color:#d1cede}
    label,input,button{display:block;width:100%}input,button{font:inherit;padding:10px;margin-top:10px;border:1px solid #9a5960}
    input{background:#0d0b18;color:#fff2df}button{background:#362238;color:#fff2df;cursor:pointer}
  </style><main><h1>Dead Route Wallet</h1>${body}</main></html>`);
}

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

function browserFlow(req, state, method) {
  const flow = activeFlow(states.get(state));
  const browser = (req.headers.cookie || "").match(/(?:^|; )dr_wallet=([^;]+)/)?.[1];
  return flow?.method === method && flow.browser && matches(browser, flow.browser) ? flow : null;
}

function walletChallenge(flow) {
  return { message: "Sign in to Dead Route and check shotgun NFT ownership.",
    nonce: flow.walletNonce, recipient: publicUrl.host, callbackUrl: walletCallback };
}

/**
 * Ends a sign-in. `playerId` is the stable identity the camp market uses: the NEAR account when
 * one exists, otherwise a hash of the Google subject. Either way the player gets a session.
 */
async function finishAccount(flow, accountId, accountNetwork, playerId = accountId) {
  const ownership = accountId ? await shotgunEntitlement(accountId, accountNetwork) :
    { shotgun_owned: false, ownership_message: "" };
  if (!activeFlow(flow.id)) return;
  const session = playerId ? randomToken() : "";
  const now = Date.now();
  for (const [key, value] of sessions) if (value.expires <= now) sessions.delete(key);
  if (session && sessions.size >= 1000) throw new Error("Too many sessions");
  if (session) sessions.set(session, { accountId, accountNetwork, playerId, expires: now + sessionLifetime });
  flow.result = { signed_in: true, account_id: accountId, account_network: accountNetwork,
    session, ...ownership };
}

async function walletFor(subject) {
  if (!near) {
    const keyStore = new keyStores.InMemoryKeyStore();
    await keyStore.setKey("testnet", relayerId, KeyPair.fromString(relayerKey));
    near = await connect({ networkId: "testnet", nodeUrl: "https://rpc.testnet.near.org", keyStore });
  }
  const relayer = await near.account(relayerId);
  const path = `jwt#${issuer}#${subject}`;
  const accountId = `dr-${hash(path).digest("hex").slice(0, 20)}.${relayerId}`;
  // Direct Google sign-in: the relayer's key controls the player's account (custodial, invisible).
  // Legacy NEAR Auth provider: the account is bound to the MPC-derived key for that identity.
  const publicKey = directGoogle ? KeyPair.fromString(relayerKey).getPublicKey() :
    utils.PublicKey.from(await relayer.viewFunction({
      contractId: "v1.signer-prod.testnet",
      methodName: "derived_public_key",
      args: { path, predecessor: "fast-auth.testnet", domain_id: 1 },
    }));
  const provider = near.connection.provider;
  const accessKey = () => provider.query({
    request_type: "view_access_key", finality: "final",
    account_id: accountId, public_key: publicKey.toString(),
  });
  let key;
  try {
    key = await accessKey();
  } catch (error) {
    if (error.type !== "AccountDoesNotExist" && error.cause?.name !== "UNKNOWN_ACCOUNT") throw error;
    await relayer.createAccount(accountId, publicKey,
      BigInt(process.env.NEAR_INITIAL_BALANCE || "10000000000000000000000"));
    key = await accessKey();
  }
  if (key.permission !== "FullAccess") throw new Error("Wallet key has insufficient access");
  return accountId;
}

async function finishLogin(req, res, url) {
  const state = url.searchParams.get("state");
  const flow = browserFlow(req, state, "google");
  if (!flow) {
    return page(res, 400, "<p>This sign-in expired. Start again in the game.</p>");
  }
  states.delete(state);
  res.setHeader("Set-Cookie", pairingCookie("", 0, "google"));
  try {
    const code = url.searchParams.get("code");
    if (!code) throw new Error("Authorization rejected");
    const form = new URLSearchParams({
      grant_type: "authorization_code", client_id: clientId, code,
      redirect_uri: callback, code_verifier: flow.verifier,
    });
    if (clientSecret) form.set("client_secret", clientSecret);
    const response = await fetch(tokenEndpoint, {
      method: "POST", body: form, redirect: "error", signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error("Token exchange failed");
    const { id_token: idToken } = await response.json();
    const { payload } = await jwtVerify(idToken, jwks, {
      issuer: directGoogle ? [issuer, "accounts.google.com"] : issuer,
      audience: clientId, algorithms: ["RS256"], requiredClaims: ["exp", "sub", "nonce"],
    });
    if (payload.nonce !== flow.nonce || typeof payload.sub !== "string" || !payload.sub ||
        (!directGoogle && !payload.sub.startsWith("google-oauth2|")) ||
        (payload.azp !== undefined && payload.azp !== clientId)) {
      throw new Error("Invalid Google login");
    }
    let accountId = "";
    if (relayerReady) {
      const work = provisioning.then(() => {
        if (!activeFlow(flow.id)) throw new Error("Pairing expired");
        return walletFor(payload.sub);
      });
      provisioning = work.catch(() => {});
      try {
        accountId = await work;
      } catch (error) {
        console.error("NEAR account provisioning failed; continuing without one:", error.message);
      }
    }
    const playerId = accountId || `google:${hash(`${issuer}#${payload.sub}`).digest("hex").slice(0, 24)}`;
    await finishAccount(flow, accountId, accountId ? "testnet" : "", playerId);
    page(res, 200, "<p>Google sign-in is complete. Return to Dead Route.</p>");
  } catch (error) {
    console.error("Google sign-in failed:", error.message);
    flow.error = "Google sign-in could not be completed. Try again or play as a guest.";
    page(res, 502, "<p>Google sign-in could not be completed. Return to Dead Route to retry.</p>");
  }
}

/** Who is trading: a verified session (Google or wallet) or, when allowed, a guest id. */
function identify(body) {
  const identity = sessions.get(body.session);
  if (identity && identity.expires > Date.now()) {
    return { id: identity.playerId || identity.accountId, account: identity.accountId };
  }
  if (allowGuests && typeof body.guest_id === "string" && /^[a-z0-9]{8,40}$/.test(body.guest_id)) {
    return { id: `guest:${body.guest_id}`, account: "" };
  }
  return null;
}

async function marketRoute(req, res, action) {
  if (req.method === "GET" && action === "state") return json(res, 200, market.snapshot());
  if (req.method !== "POST") return json(res, 404, { error: "Page unavailable." });
  const body = await readBody(req);
  const who = identify(body);
  if (action === "state") return json(res, 200, market.snapshot(who ? who.id : ""));
  if (!who) return json(res, 401, { error: "Sign in (or continue as a guest) to trade at the camp." });
  switch (action) {
    case "trade":
      return json(res, 200, market.trade({ player: who.id, account: who.account, merchant: String(body.merchant || ""),
        commodity: String(body.commodity || ""), side: String(body.side || ""), qty: body.qty,
        intentId: typeof body.intent_id === "string" ? body.intent_id.slice(0, 64) : "",
        maxTotal: body.max_total === undefined ? undefined : Number(body.max_total) }));
    case "haul":
      return json(res, 200, market.recordHaul({ player: who.id, account: who.account,
        runId: typeof body.run_id === "string" ? body.run_id.slice(0, 80) : "",
        haul: body.haul && typeof body.haul === "object" ? body.haul : {} }));
    case "invest":
      return json(res, 200, market.invest({ player: who.id, merchant: String(body.merchant || ""), scrap: body.scrap }));
    case "fast-forward":
      return json(res, 200, market.fastForward({ days: body.days, seed: body.seed, apply: body.apply === true }));
    case "ledger":
      return json(res, 200, { ok: true, rows: market.ledger(who.id), chain: marketChain.describe() });
    default:
      return json(res, 404, { error: "Page unavailable." });
  }
}

function pairingCookie(value, age, method) {
  const secure = publicUrl.protocol === "https:" ? "; Secure" : "";
  const path = method === "wallet" ? "/wallet" : "/oauth/callback";
  return `dr_wallet=${value}; Max-Age=${age}; Path=${path}; HttpOnly; SameSite=Lax${secure}`;
}

async function route(req, res) {
  const url = new URL(req.url, publicUrl);
  if (req.method === "GET" && url.pathname === "/healthz") {
    return json(res, 200, { service: "dead-route-wallet-bridge", google_configured: googleReady,
      market: { day: market.state.day, chain: marketChain.describe().mode, guests: allowGuests } });
  }
  if (url.pathname.startsWith("/api/market/")) return marketRoute(req, res, url.pathname.slice("/api/market/".length));
  if (req.method === "POST" && url.pathname === "/api/device/start") {
    const method = (await readBody(req)).method === "wallet" ? "wallet" : "google";
    if (method === "google" && !googleReady) {
      return json(res, 503, { error: "Google sign-in is not set up on this bridge yet (GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in wallet-bridge/.env). Play as a guest for now." });
    }
    for (const flow of flows.values()) activeFlow(flow.id);
    if (flows.size >= 250) return json(res, 429, { error: "Wallet service is busy. Try again in a few minutes." });
    const flow = { method, id: randomToken(), secret: randomToken(), code: String(randomInt(100000, 1000000)),
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
      return json(res, 401, { error: "Wallet session expired. Connect your wallet again." });
    }
    if (Date.now() - (identity.lastCheck || 0) < 2_000) {
      return json(res, 429, { error: "Wait a moment and retry the ownership check." });
    }
    identity.lastCheck = Date.now();
    return json(res, 200, await shotgunEntitlement(identity.accountId, identity.accountNetwork));
  }
  if (req.method === "GET" && url.pathname === "/wallet") {
    const flow = activeFlow(url.searchParams.get("flow"));
    if (!flow || flow.browser) return page(res, 400, "<p>Start a new sign-in in Dead Route.</p>");
    return page(res, 200, `<p>Enter the code shown in Dead Route to confirm this sign-in.</p>
      <form method="post" action="/wallet"><input type="hidden" name="flow" value="${flow.id}">
      <label for="code">Game code</label><input id="code" name="code" inputmode="numeric" pattern="[0-9]{6}"
      maxlength="6" autocomplete="one-time-code" required><button>${flow.method === "wallet" ? "Continue to wallet" : "Continue with Google"}</button></form>`);
  }
  if (req.method === "POST" && url.pathname === "/wallet") {
    if (req.headers.origin !== publicUrl.origin) return page(res, 403, "<p>Open sign-in from Dead Route.</p>");
    const { flow: id, code } = await readBody(req);
    const flow = activeFlow(id);
    if (!flow || flow.browser) return page(res, 400, "<p>Start a new sign-in in Dead Route.</p>");
    if (!matches(code, flow.code)) {
      if (++flow.attempts >= 5) removeFlow(flow);
      return page(res, 400, "<p>The code did not match. Go back and check the code in Dead Route.</p>");
    }
    flow.state = randomToken();
    flow.nonce = randomToken();
    flow.verifier = randomToken();
    flow.browser = randomToken();
    states.set(flow.state, flow.id);
    const cookie = pairingCookie(flow.browser, 300, flow.method);
    if (flow.method === "wallet") {
      flow.walletNonce = randomBytes(32);
      res.writeHead(303, { Location: "/wallet/approve?state=" + flow.state, "Set-Cookie": cookie });
      return res.end();
    }
    const authorize = new URL(authorizationEndpoint);
    authorize.search = new URLSearchParams({
      client_id: clientId, response_type: "code", scope: "openid", redirect_uri: callback,
      state: flow.state, nonce: flow.nonce,
      code_challenge: hash(flow.verifier).digest("base64url"), code_challenge_method: "S256",
    });
    if (!directGoogle) authorize.searchParams.set("connection", "google-oauth2");
    res.writeHead(303, { Location: authorize.href, "Set-Cookie": cookie });
    return res.end();
  }
  if (req.method === "GET" && url.pathname === "/wallet/approve") {
    const flow = browserFlow(req, url.searchParams.get("state"), "wallet");
    if (!flow) return page(res, 400, "<p>This pairing expired. Start again in Dead Route.</p>");
    const challenge = walletChallenge(flow);
    const sign = new URL("/sign-message", walletOrigin);
    sign.search = new URLSearchParams({ ...challenge, nonce: challenge.nonce.toString("base64"), state: flow.state });
    return page(res, 200, `<p>Sign a message in MyNearWallet on ${network} to prove account ownership.</p>
      <button data-sign-url="${sign.href.replaceAll("&", "&amp;")}">Open MyNearWallet</button>
      <p id="wallet-status" role="status"></p><script type="module" src="/wallet/browser.mjs"></script>`);
  }
  if (req.method === "GET" && url.pathname === "/wallet/return") {
    return page(res, 200, '<p id="wallet-status" role="status">Checking wallet…</p><script type="module" src="/wallet/browser.mjs"></script>');
  }
  if (req.method === "GET" && url.pathname === "/wallet/browser.mjs") {
    res.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8" });
    return res.end(walletScript);
  }
  if (req.method === "POST" && url.pathname === "/wallet/complete") {
    if (req.headers.origin !== publicUrl.origin) return json(res, 403, { message: "Open wallet sign-in from Dead Route." });
    const proof = await readBody(req);
    const flow = browserFlow(req, proof.state, "wallet");
    if (!flow) return json(res, 400, { message: "This pairing expired. Start again in Dead Route." });
    states.delete(flow.state);
    res.setHeader("Set-Cookie", pairingCookie("", 0, "wallet"));
    try {
      if (proof.canceled || !await verifyWallet(proof, walletChallenge(flow))) throw new Error("Signature rejected");
      await finishAccount(flow, proof.accountId, network);
      return json(res, 200, { message: "Wallet connected. Return to Dead Route." });
    } catch {
      flow.error = "Wallet verification failed. Connect again or continue as guest.";
      return json(res, 400, { message: flow.error });
    }
  }
  if (req.method === "GET" && url.pathname === "/oauth/callback") return finishLogin(req, res, url);
  return json(res, 404, { error: "Page unavailable." });
}

const server = createServer(async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Content-Security-Policy", "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'");
  if (req.url.startsWith("/api/") && req.headers.origin) {
    if (req.headers.origin !== webOrigin && req.headers.origin !== publicUrl.origin) {
      return json(res, 403, { error: "This game origin is not configured." });
    }
    res.setHeader("Access-Control-Allow-Origin", req.headers.origin);
    res.setHeader("Vary", "Origin");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST");
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
});
>>>>>>> Stashed changes
server.listen(Number(process.env.PORT || process.env.WALLET_PORT || 8787),
  process.env.WALLET_BIND || (process.env.PORT ? "0.0.0.0" : "127.0.0.1"), () => {
  console.log(`Dead Route sign-in listening for ${process.env.WALLET_PUBLIC_URL || "http://127.0.0.1:8787"}.`);
});
