import { createHmac, createPrivateKey, createPublicKey } from "node:crypto";
import { connect, KeyPair, keyStores, utils } from "near-api-js";

const networkId = "testnet";
const sponsor = process.env.NEAR_RELAYER_ACCOUNT;
const sponsorKey = process.env.NEAR_RELAYER_KEY;
const rootKey = process.env.NEAR_ACCOUNT_ROOT_KEY;
const balance = process.env.NEAR_INITIAL_BALANCE || "10000000000000000000000";
const validBalance = /^[1-9][0-9]{0,22}$/.test(balance);
export const provisioningReady = Boolean(
  /^[a-z0-9]+(?:[._-][a-z0-9]+)*\.testnet$/.test(sponsor || "") &&
  sponsor.length <= 40 && sponsorKey && /^[a-f0-9]{64}$/i.test(rootKey || "") && validBalance
);
let client;
let sponsorQueue = Promise.resolve();

export function accountIdentity(subject, parent, secret) {
  // The same verified Google subject always maps to the same sponsored account.
  const digest = (purpose) => createHmac("sha256", Buffer.from(secret, "hex"))
    .update(JSON.stringify(["dead-route", "accounts.google.com", networkId, parent, purpose, subject]))
    .digest();
  const accountId = `dr-${digest("account").toString("hex").slice(0, 20)}.${parent}`;
  const pkcs8 = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), digest("ed25519")]);
  const privateKey = createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
  const publicBytes = createPublicKey(privateKey).export({ format: "jwk" }).x;
  const publicKey = utils.PublicKey.from(`ed25519:${utils.serialize.base_encode(Buffer.from(publicBytes, "base64url"))}`);
  return { accountId, publicKey };
}

export async function provisionAccount(subject) {
  if (!provisioningReady) return null;
  if (!client) {
    const keyStore = new keyStores.InMemoryKeyStore();
    await keyStore.setKey(networkId, sponsor, KeyPair.fromString(sponsorKey));
    client = await connect({ networkId, nodeUrl: "https://rpc.testnet.near.org", keyStore });
  }
  const { accountId, publicKey } = accountIdentity(subject, sponsor, rootKey);
  const provider = client.connection.provider;
  const checkKey = () => provider.query({
    request_type: "view_access_key", finality: "final", account_id: accountId, public_key: publicKey.toString(),
  });
  let access;
  try {
    access = await checkKey();
  } catch (error) {
    if (error.type !== "AccountDoesNotExist" && error.cause?.name !== "UNKNOWN_ACCOUNT") throw error;
    try {
      const creation = sponsorQueue.then(async () => {
        // Recheck after waiting to avoid submitting a second creation on retry.
        try {
          await checkKey();
        } catch (error) {
          if (error.type !== "AccountDoesNotExist" && error.cause?.name !== "UNKNOWN_ACCOUNT") throw error;
          await (await client.account(sponsor)).createAccount(accountId, publicKey, BigInt(balance));
        }
      });
      sponsorQueue = creation.catch(() => {});
      await creation;
    } catch (creationError) {
      // Another instance may have created it, or the reply may have been lost.
      try {
        access = await checkKey();
      } catch {
        throw creationError;
      }
    }
    access ??= await checkKey();
  }
  if (access.permission !== "FullAccess") throw new Error("Unexpected account key permission");
  return { accountId, accountNetwork: networkId };
}
