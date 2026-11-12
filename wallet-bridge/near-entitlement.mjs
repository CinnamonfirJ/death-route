import { createHash } from "node:crypto";
import { providers, utils } from "near-api-js";

export const accountPattern = /^(?=.{2,64}$)[a-z0-9]+(?:[._-][a-z0-9]+)*$/;
export const network = process.env.NEAR_NFT_NETWORK || "testnet";
if (!["testnet", "mainnet"].includes(network)) throw new Error("NEAR_NFT_NETWORK must be testnet or mainnet.");
export const walletOrigin = network === "testnet" ? "https://testnet.mynearwallet.com" : "https://app.mynearwallet.com";
const contract = process.env.NEAR_SHOTGUN_CONTRACT;
const tokenId = process.env.NEAR_SHOTGUN_TOKEN_ID;
const rpc = new providers.JsonRpcProvider({ url: `https://rpc.${network}.near.org` });

function borshString(value) {
  const data = Buffer.from(value, "utf8");
  const size = Buffer.alloc(4);
  size.writeUInt32LE(data.length);
  return Buffer.concat([size, data]);
}

export function messageDigest({ message, nonce, recipient, callbackUrl }) {
  const tag = Buffer.alloc(4);
  tag.writeUInt32LE(2 ** 31 + 413);
  const serialized = Buffer.concat([tag, borshString(message), nonce, borshString(recipient),
    Buffer.from([1]), borshString(callbackUrl)]);
  return createHash("sha256").update(serialized).digest();
}

export async function verifyWallet(proof, challenge, provider = rpc) {
  const { accountId, publicKey, signature } = proof;
  if (typeof accountId !== "string" || !accountPattern.test(accountId) ||
      typeof publicKey !== "string" || !/^ed25519:[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(publicKey) ||
      typeof signature !== "string" || !/^[A-Za-z0-9+/]{86}==$/.test(signature)) return false;
  const key = utils.PublicKey.from(publicKey);
  if (!key.verify(messageDigest(challenge), Buffer.from(signature, "base64"))) return false;
  const access = await provider.query({ request_type: "view_access_key", finality: "final",
    account_id: accountId, public_key: key.toString() });
  return access.permission === "FullAccess";
}

export async function shotgunEntitlement(accountId, accountNetwork, provider = rpc) {
  if (!contract || !accountPattern.test(contract) || !tokenId) {
    return { shotgun_owned: false, ownership_message: "Shotgun NFT is not configured." };
  }
  if (accountNetwork !== network) {
    return { shotgun_owned: false, ownership_message: `Connect a ${network} wallet to check shotgun ownership.` };
  }
  try {
    const result = await provider.query({ request_type: "call_function", finality: "final",
      account_id: contract, method_name: "nft_token",
      args_base64: Buffer.from(JSON.stringify({ token_id: tokenId })).toString("base64") });
    const token = JSON.parse(Buffer.from(result.result).toString("utf8"));
    const owned = token?.token_id === tokenId && token.owner_id === accountId;
    return { shotgun_owned: owned, ownership_message: owned ? "Shotgun unlocked." : "This wallet does not own the shotgun NFT." };
  } catch {
    return { shotgun_owned: false, ownership_message: "NEAR ownership check failed. Try again." };
  }
}
