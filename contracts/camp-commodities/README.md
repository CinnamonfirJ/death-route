# Camp Commodities (NEP-245)

One multi-token contract for every good traded at the Survivor Camp market. Token ids come from
[`economy/pricing_rules.toml`](../../economy/pricing_rules.toml): `1` Medkit, `2` Premium Ammo,
`3` Pizza Delivery Contract, `4` Flashlight Battery, `5` Food Stock. Courier wallets and
merchant NPC wallets both hold balances of these ids.

| Layer | Methods |
| --- | --- |
| NEP-245 core | `mt_transfer`, `mt_batch_transfer`, `mt_transfer_call`, `mt_batch_transfer_call`, `mt_resolve_transfer`, `mt_token`, `mt_balance_of`, `mt_batch_balance_of`, `mt_supply`, `mt_batch_supply` |
| NEP-245 metadata | `mt_metadata_contract`, `mt_metadata_token_all`, `mt_metadata_token_by_token_id`, `mt_metadata_base_by_token_id` |
| NEP-245 events | `mt_mint`, `mt_burn`, `mt_transfer` as `EVENT_JSON` logs (`standard: nep245`, `version: 1.0.0`) |
| Game relayer | `register_token`, `mt_mint`, `mt_burn`, `relayed_transfer(intent_id, …)`, `intent_executed`, `add_operator`, `remove_operator` |

`relayed_transfer` is how a player's trade intent reaches the chain. The wallet bridge matched
the intent off-chain (merchant, commodity, quantity, price), then calls this method as an
operator and pays the gas. The intent id makes it idempotent: a retry after a timeout returns
`false` and moves nothing. Approvals (NEP-245 approval management) are intentionally not
supported; the operator model replaces them for this game.

## Build and test

```sh
cd contracts/camp-commodities
cargo test
cargo near build non-reproducible-wasm      # -> target/near/camp_commodities.wasm
```

Plain `cargo build --target wasm32-unknown-unknown --release` also works and produces
`target/wasm32-unknown-unknown/release/camp_commodities.wasm`.

## Deploy to testnet

The relayer account from `wallet-bridge/.env` (`NEAR_RELAYER_ACCOUNT`) is the natural owner.
Deploy to a sub-account so the contract has its own address:

```sh
near account create-account fund-myself camp.RELAYER.testnet '2 NEAR' \
  autogenerate-new-keypair save-to-keychain sign-as RELAYER.testnet network-config testnet sign-with-keychain send

near contract deploy camp.RELAYER.testnet use-file target/near/camp_commodities.wasm \
  with-init-call new json-args '{"owner_id":"RELAYER.testnet"}' \
  prepaid-gas '30 Tgas' attached-deposit '0 NEAR' network-config testnet sign-with-keychain send
```

Then register the five commodities from the pricing file (uses the relayer key in `.env`):

```sh
NEAR_MT_CONTRACT=camp.RELAYER.testnet node --env-file=wallet-bridge/.env wallet-bridge/tools/setup_contract.mjs
```

Set `NEAR_MT_CONTRACT=camp.RELAYER.testnet` in `wallet-bridge/.env` and restart the bridge. Its
`/healthz` reports `"chain":"testnet"` and every haul and trade is mirrored on-chain in the
background. Merchant wallets (`rusty.RELAYER.testnet`, `doc.RELAYER.testnet`,
`mama-g.RELAYER.testnet`) are created on first use.

## Storage

The owner pays storage for all balances; NEP-145 storage management is not implemented. Each
balance row costs about 100 bytes, so a few thousand couriers fit comfortably in the 2 NEAR
funded above.
