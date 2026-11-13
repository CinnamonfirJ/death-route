import { providers } from "near-api-js";

export const accountPattern = /^(?=.{2,64}$)[a-z0-9]+(?:[._-][a-z0-9]+)*$/;
export const network = process.env.NEAR_NFT_NETWORK || "testnet";
if (!["testnet", "mainnet"].includes(network)) throw new Error("NEAR_NFT_NETWORK must be testnet or mainnet.");
const contract = process.env.NEAR_SHOTGUN_CONTRACT;
const tokenId = process.env.NEAR_SHOTGUN_TOKEN_ID;
const rpc = new providers.JsonRpcProvider({ url: `https://rpc.${network}.near.org` });

export async function shotgunEntitlement(accountId, accountNetwork, provider = rpc) {
  if (!contract || !accountPattern.test(contract) || !tokenId) {
    return { shotgun_owned: false };
  }
  if (accountNetwork !== network) {
    return { shotgun_owned: false };
  }
  try {
    const result = await provider.query({ request_type: "call_function", finality: "final",
      account_id: contract, method_name: "nft_token",
      args_base64: Buffer.from(JSON.stringify({ token_id: tokenId })).toString("base64") });
    const token = JSON.parse(Buffer.from(result.result).toString("utf8"));
    const owned = token?.token_id === tokenId && token.owner_id === accountId;
    return { shotgun_owned: owned };
  } catch {
    return { error: "Item access could not be checked." };
  }
}
