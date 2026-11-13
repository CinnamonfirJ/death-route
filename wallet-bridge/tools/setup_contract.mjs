// One-time setup for a freshly deployed Camp Commodities contract: registers every commodity
// from economy/pricing_rules.toml as a NEP-245 token id and makes the relayer an operator.
//
//   NEAR_MT_CONTRACT=camp.relayer.testnet node --env-file=wallet-bridge/.env wallet-bridge/tools/setup_contract.mjs
import { fileURLToPath } from "node:url";
import { connect, KeyPair, keyStores } from "near-api-js";
import { loadRules } from "../market.mjs";

const relayerId = process.env.NEAR_RELAYER_ACCOUNT;
const relayerKey = process.env.NEAR_RELAYER_KEY;
const contract = process.env.NEAR_MT_CONTRACT;
const network = process.env.NEAR_MT_NETWORK || "testnet";
if (!relayerId || !relayerKey || !contract) {
  console.error("Set NEAR_RELAYER_ACCOUNT, NEAR_RELAYER_KEY and NEAR_MT_CONTRACT.");
  process.exit(1);
}

const rules = loadRules(process.env.MARKET_RULES || fileURLToPath(new URL("../../economy/pricing_rules.toml", import.meta.url)));
const keyStore = new keyStores.InMemoryKeyStore();
await keyStore.setKey(network, relayerId, KeyPair.fromString(relayerKey));
const near = await connect({ networkId: network, nodeUrl: `https://rpc.${network}.near.org`, keyStore });
const relayer = await near.account(relayerId);
const gas = BigInt(30_000_000_000_000);

const isOperator = await relayer.viewFunction({ contractId: contract, methodName: "is_operator", args: { account_id: relayerId } });
if (!isOperator) {
  await relayer.functionCall({ contractId: contract, methodName: "add_operator", args: { account_id: relayerId }, gas });
  console.log(`${relayerId} is now an operator.`);
}
for (const [id, c] of Object.entries(rules.commodities)) {
  const base = { name: c.name, id: c.token_id, symbol: id.toUpperCase().slice(0, 8), icon: null,
    decimals: String(c.decimals ?? 0), base_uri: null, reference: null, copies: null, reference_hash: null };
  const token = { title: c.name, description: c.description || null, media: null, media_hash: null, issued_at: null,
    expires_at: null, starts_at: null, updated_at: null, extra: JSON.stringify({ game: "dead-route", commodity: id }),
    reference: null, reference_hash: null };
  const outcome = await relayer.functionCall({ contractId: contract, methodName: "register_token",
    args: { token_id: c.token_id, base, token }, gas });
  console.log(`token ${c.token_id} = ${c.name}  tx ${outcome.transaction.hash}`);
}
console.log(`Registered: ${JSON.stringify(await relayer.viewFunction({ contractId: contract, methodName: "mt_tokens", args: {} }))}`);
