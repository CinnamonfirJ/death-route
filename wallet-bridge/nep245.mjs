// NEP-245 chain adapter. The market engine records every balance change in its ledger; when a
// relayer account and the Camp Commodities contract are configured, this module mirrors those
// rows on NEAR testnet in the background. Players never sign, never see gas, never see a popup:
// the relayer (the game backend) is an operator on the contract and executes their intents.
//
// Without configuration it runs in "ledger-only" mode and every row is marked as such.
import { connect, KeyPair, keyStores } from "near-api-js";

const GAS = BigInt(30_000_000_000_000);
const EXPLORERS = { testnet: "https://testnet.nearblocks.io", mainnet: "https://nearblocks.io" };

export function createChain(env = process.env) {
  const relayerId = env.NEAR_RELAYER_ACCOUNT || "";
  const relayerKey = env.NEAR_RELAYER_KEY || "";
  const contract = env.NEAR_MT_CONTRACT || "";
  const network = env.NEAR_MT_NETWORK || "testnet";
  const enabled = Boolean(relayerId && relayerKey && contract && /^[a-z0-9][a-z0-9_.-]{0,62}$/.test(contract));
  let near;
  let queue = Promise.resolve();
  const ensured = new Set();

  async function relayer() {
    if (!near) {
      const keyStore = new keyStores.InMemoryKeyStore();
      await keyStore.setKey(network, relayerId, KeyPair.fromString(relayerKey));
      near = await connect({ networkId: network, nodeUrl: `https://rpc.${network}.near.org`, keyStore });
    }
    return near.account(relayerId);
  }

  function merchantAccount(short) {
    return relayerId ? `${short}.${relayerId}` : short;
  }

  /** Merchant wallets are sub-accounts of the relayer, controlled by the relayer's key. */
  async function ensureAccount(accountId) {
    if (ensured.has(accountId)) return;
    const account = await relayer();
    const provider = account.connection.provider;
    try {
      await provider.query({ request_type: "view_account", finality: "final", account_id: accountId });
    } catch (error) {
      if (error.type !== "AccountDoesNotExist" && error.cause?.name !== "UNKNOWN_ACCOUNT") throw error;
      const publicKey = KeyPair.fromString(relayerKey).getPublicKey();
      await account.createAccount(accountId, publicKey, BigInt(env.NEAR_INITIAL_BALANCE || "10000000000000000000000"));
    }
    ensured.add(accountId);
  }

  async function call(methodName, args) {
    const account = await relayer();
    const outcome = await account.functionCall({ contractId: contract, methodName, args, gas: GAS });
    return outcome.transaction?.hash || outcome.transaction_outcome?.id || "";
  }

  function resolveParty(row, who) {
    if (who.startsWith("merchant:")) return merchantAccount(row.merchant_account || who.slice("merchant:".length).replace("_", "-"));
    if (who === row.from || who === row.to) return row.account || "";
    return "";
  }

  /**
   * Mirror one ledger row. Returns fields merged into the row: { status, tx, explorer, note }.
   * Rows for guests (no NEAR account) stay ledger-only; the game still works for them.
   */
  async function mirror(row, tokenId) {
    if (!enabled) return { status: "ledger-only" };
    const work = queue.then(async () => {
      if (row.kind === "mint") {
        if (!row.account) return { status: "ledger-only", note: "guest courier, no NEAR account" };
        const tx = await call("mt_mint", { receiver_id: row.account, token_id: tokenId,
          amount: String(row.amount), memo: row.memo || null });
        return { status: "confirmed", tx, explorer: `${EXPLORERS[network] || EXPLORERS.testnet}/txns/${tx}` };
      }
      if (row.kind === "transfer") {
        const from = resolveParty(row, row.from);
        const to = resolveParty(row, row.to);
        if (!from || !to) return { status: "ledger-only", note: "guest courier, no NEAR account" };
        for (const id of [from, to]) if (id.endsWith(`.${relayerId}`)) await ensureAccount(id);
        const intent = row.intent || row.id;
        if (row.from.startsWith("merchant:")) {
          const operator = await relayer();
          const view = (methodName, args) => operator.viewFunction({ contractId: contract, methodName, args });
          if (!(await view("intent_executed", { intent_id: intent }))) {
            const balance = BigInt(await view("mt_balance_of", { account_id: from, token_id: tokenId }));
            const deficit = BigInt(row.amount) - balance;
            if (deficit > 0n) {
              await call("mt_mint", { receiver_id: from, token_id: tokenId, amount: String(deficit),
                memo: "Merchant shelf restock" });
            }
          }
        }
        const tx = await call("relayed_transfer", { intent_id: intent, sender_id: from, receiver_id: to,
          token_ids: [tokenId], amounts: [String(row.amount)], memo: row.memo || null });
        if (row.useNow) {
          await call("relayed_transfer", { intent_id: `${intent}:use`, sender_id: to, receiver_id: contract,
            token_ids: [tokenId], amounts: [String(row.amount)], memo: "Consumed on route" });
        }
        return { status: "confirmed", tx, explorer: `${EXPLORERS[network] || EXPLORERS.testnet}/txns/${tx}` };
      }
      return { status: "recorded" };
    });
    queue = work.catch(() => {});
    return work;
  }

  function describe() {
    return { mode: enabled ? network : "ledger-only", contract, relayer: relayerId,
      explorer: enabled ? `${EXPLORERS[network] || EXPLORERS.testnet}/address/${contract}` : "" };
  }

  return { enabled, network, contract, mirror, describe, merchantAccount, ensureAccount };
}
