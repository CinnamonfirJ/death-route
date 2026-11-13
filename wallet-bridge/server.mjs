import http from "node:http";
import { fileURLToPath } from "node:url";
import { createHandler } from "./auth-service.mjs";
import { Market, loadRules } from "./market.mjs";
import { createChain } from "./nep245.mjs";

const rules = loadRules(fileURLToPath(new URL("../economy/pricing_rules.toml", import.meta.url)));
const market = new Market(rules, {
  chain: createChain(),
  persistPath: process.env.MARKET_DATA_FILE || fileURLToPath(new URL("data/market.json", import.meta.url)),
});
const bind = process.env.WALLET_BIND || "127.0.0.1";
const port = Number(process.env.WALLET_PORT || 8787);
http.createServer(createHandler({ market })).listen(port, bind, () => {
  console.log(`Death Route bridge listening at http://${bind}:${port}`);
});
