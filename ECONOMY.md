# The Camp Market: Dead Route's economy

The Survivor Camp is the market town. The survivors who run its stalls are agent merchants with
their own NEAR wallets. Everything a courier scavenges on a route is a commodity those merchants
buy and sell at prices that move with their stock, and every one of those commodities is a token
id on a single NEP-245 contract. The player never sees any of that machinery: they click **Sell**.

This document is the design on paper, then what each piece of the repository does.

## The loop

**Every 30 seconds (on the route).** The courier works a zombie-infested route using the flashlight, managing weapon wear, and hunting for pizza orders. Pizza spots that turn out empty hold a
**supply crate** instead (medkits, premium ammo, batteries, food stock). Every crate is camp-market
supply, so pushing one spot deeper is never wasted. Combat and survival are the mining phase.

**Every 5 minutes (back at camp).** The courier opens the Garage's **Market** tab and sells to
Rusty (ammo smuggler), Doc (medic) or Mama G (kitchen and dispatch). The price is shown with the
merchant's reasoning beside it:

> Medkits · pays 15 · charges 22 (stock 8/12)
> 💡 Standard rate for Medkits. Thank you for bringing them in.

Sell five and the price walks down unit by unit (15, 15, 14, 13, 12), because each unit lands on
her shelf before the next is priced. Keep flooding her and the line changes to *"The infirmary is
stacked to the ceiling with Medkits. I can't pay much."* A finished delivery mints one **Pizza
Delivery Contract**, the proof-of-delivery token Mama G's dispatch redeems at a premium. No wallet
popup, no gas prompt, no seed phrase: the balance updates and the merchant's stock changes.

**Every session (the macro economy).** The courier signs in with Google; the bridge links that
identity to an abstracted NEAR account. Market days roll every twenty minutes of bridge time. A
merchant who has been flooded sells at floor prices that don't cover her upkeep; a merchant whose
goods were hoarded has empty shelves and no income. Either way the ledger eventually reads *"Doc
(Camp Medic) went bankrupt. Shop closed."* and her card shows a reopen fund. Couriers pool scrap to
reopen her, then pick the next route by what the camp needs: "Ammo is cheap today, let's run a
combat-heavy route."

## Field vendors

Approach Rusty, Doc, or Mama G in any solo or co-op route to see their current stock in a small
menu above them. Purchases use scrap earned in the current run. Rusty sells ammo and a short
damage shield, Doc sells a healing shot with brief protection, and Mama G sells a speed boost.
Each use consumes one unit from the same shared merchant stock shown in the Garage.

The deployed Cloudflare sign-in worker also handles market requests and persists the books in
its Durable Object. For on-chain settlement, set the public GitHub Actions variable
`NEAR_MT_CONTRACT` to the deployed Camp Commodities account ID and `NEAR_MT_NETWORK` to
its network (defaults to `testnet`). The configured `NEAR_RELAYER_ACCOUNT` must be an operator
on that contract, and token IDs 1 through 5 must already be registered. Re-run the web workflow
after changing these values. This uses the deployed contract's existing methods. The game can
trade as a guest with the bridge ledger while chain settlement is being configured.

The week simulation is available to couriers as a preview. To give an operator the option to
apply it to the shared market, set the private Actions secret `MARKET_ADMIN_GOOGLE_SUB` to that
operator's verified Google subject. It is separate from the OAuth client ID.

## How it maps to the requirements

| Requirement | Where it lives |
| --- | --- |
| NEP-245 multi-token | [`contracts/camp-commodities`](contracts/camp-commodities): one contract, token ids `1` Medkit, `2` Premium Ammo, `3` Pizza Delivery Contract, `4` Battery, `5` Food Stock. Courier and merchant wallets hold balances of these ids. Core, metadata and events implemented; 10 unit tests. |
| Social login, no chain friction | Google sign-in in [`wallet-bridge/server.mjs`](wallet-bridge/server.mjs) provisions a NEAR testnet account per Google identity through the relayer. Trades go through plain buttons; the relayer signs and pays gas. Guests can trade too (balances stay in the bridge ledger). |
| Agent NPCs with wallets | Each merchant is a sub-account of the relayer (`rusty.<relayer>`, `doc.<relayer>`, `mama-g.<relayer>`), created on first use by [`wallet-bridge/nep245.mjs`](wallet-bridge/nep245.mjs). They buy and sell on their own from the pricing rules; the bridge is their brain. |
| Readable pricing rules with a tooltip | [`economy/pricing_rules.toml`](economy/pricing_rules.toml) is the only tuning surface. The bridge returns a `reason` line and the worked `formula` with every quote; the Garage shows the line under the price and the formula in the row tooltip. |
| Fast-forward (judge feature) | **FAST-FORWARD 7 DAYS** in the Market tab. The bridge simulates a week of synthetic couriers on a copy of the live books (deterministic seed) and the game plays it back: a price graph fills in day by day while the log prints *"Day 3: Doc (Camp Medic) went bankrupt. Shop closed."* A configured market operator can apply the simulation to the live market. |
| Game trade intents | A trade is an intent `{merchant, commodity, side, qty, intent_id, max_total}`. The bridge matches it against the books, then the relayer executes `relayed_transfer(intent_id, …)` on the contract, which is idempotent per intent id. The official NEAR Intents verifier is outside the current integration. |

## The pricing algorithm

```
mid   = clamp(base − (inventory − ideal) × elasticity,  base × 0.25,  base × 3.0)
bid   = floor(mid × (1 − spread))      # what the merchant pays a courier
ask   = ceil (mid × (1 + spread))      # what the merchant charges
```

Each unit of a batch is priced after the previous one moved inventory. A merchant only buys while
her treasury covers the bid and her shelf is under `max`. Every market day the camp population
buys `daily_use` units at the ask price (her income) and she pays `daily_upkeep` (her cost). Below
`min_treasury` at day end she is bankrupt until couriers pool `reopen_cost`. The inventory/ideal
ratio picks the voice line: `glut`, `high`, `balanced`, `low`, `scarce`, plus `sold_out`, `broke`
and `closed`. All of it, including every line of dialogue, is in the TOML.

## Architecture

```
Godot client                       Wallet bridge (Node)                     NEAR testnet
─────────────                      ────────────────────                     ────────────
Route: Pickup CRATE_* ──► run_haul
Run end: GameManager.end_run ─────► POST /api/market/haul ─────────────────► mt_mint (relayer)
Garage ▸ Market tab   ◄──────────── POST /api/market/state (every 4 s)
  Sell / Buy  ────────────────────► POST /api/market/trade ───────────────► relayed_transfer
  Invest to reopen ───────────────► POST /api/market/invest
  Fast-forward ───────────────────► POST /api/market/fast-forward (copy of the books)
                                    market.mjs  ← economy/pricing_rules.toml
                                    nep245.mjs  ← NEAR_RELAYER_* + NEAR_MT_CONTRACT
```

- **Scrap stays off-chain** in the local save, as before. The bridge tells the client the scrap
  delta of each trade; buys carry a `max_total` so a price move between quote and click can only
  make the trade smaller, never dearer.
- **Commodity balances live in the bridge** (the production Durable Object, or `wallet-bridge/data/market.json` on the local server) and are mirrored to
  the contract in the background. Each ledger row records `pending`, `confirmed` with a tx hash and
  explorer link, `failed`, or `ledger-only` (guest or no contract configured). Trades never wait on
  the chain.
- **Co-op** needs nothing extra: all couriers trade against the same books on the bridge, so a
  partner dumping medkits moves Doc's price for you within one poll.
- **Trust boundary.** The game client is trusted for scrap and for the contents of a haul, exactly
  as it is trusted for scrap today (see README). Hauls are idempotent per run id. A trusted match
  server would be the place to verify hauls for a competitive release.

## Run it

```sh
# 1. Bridge (market works immediately in ledger-only mode; Google and NEAR are optional)
cp wallet-bridge/.env.example wallet-bridge/.env
npm --prefix wallet-bridge install
npm --prefix wallet-bridge start           # http://127.0.0.1:8787/healthz

# 2. Game: open project.godot, Play, Garage ▸ Market. Guests trade under a stable guest id.

# 3. Optional: real NEP-245 on testnet
cd contracts/camp-commodities && cargo near build non-reproducible-wasm   # see its README to deploy
# then set NEAR_RELAYER_ACCOUNT, NEAR_RELAYER_KEY, NEAR_MT_CONTRACT in wallet-bridge/.env
```

Tests: `npm --prefix wallet-bridge test` (engine), `cargo test` in the contract folder, and
`godot --headless -s tests/market/market_test.gd -- --save=user://market_test.save` (banks hauls,
builds the UI, and round-trips a trade when a bridge is listening on 8787).

## Judge demo, three minutes

1. Open the Garage ▸ **Market**. Point at the account line and the stock and price quotes.
2. Sell medkits to Doc one at a time. Read her line change as the price slides. Hover a row for
   the worked formula.
3. Sell the Pizza Delivery Contract to Mama G: the delivery itself is the valuable token.
4. Press **FAST-FORWARD 7 DAYS**. Watch the graph and the log; Doc goes bust around day 3 with the
   default rules. Press **APPLY TO LIVE MARKET** as the configured operator, close, and show her card: *CLOSED · bankrupt*,
   reopen fund `0 / 200`. Invest, reopen, trade again.
5. Open [`economy/pricing_rules.toml`](economy/pricing_rules.toml) and change Doc's `elasticity`
   or a voice line. Restart the bridge. The game shows the new behaviour with no client patch.
