# Death Route

Death Route is a Godot 4.7 zombie-survival delivery game with solo play and WebSocket co-op. [Play in your browser](https://deathroute.fun/). Open [`project.godot`](project.godot) in Godot to run it locally. See [BUILD.md](BUILD.md) for exports and multiplayer setup.

**Track `games` · Games With Real Economies · The economy is the gameplay**

## The problem

A fixed-price shop gives players little reason to react to what other people scavenge or buy. Death Route makes those decisions matter on the next run. The ammo your friend buys during a firefight comes off the same shelf you shop from, and the medkits you haul back can lower what Doc offers the next courier.

## What we built

Death Route turns the market-town idea into a top-down zombie survival and pizza-delivery game for solo play or up to four players in online co-op. The Survivor Camp market connects what the crew brings home to what everyone can afford in the field.

- **Every 30 seconds**, make a choice under pressure. Scavenge a supply crate, pick up a pizza order, or spend this run's scrap at a field vendor for ammo, healing, a temporary shield, or a speed boost. The quick-buy menu opens over the merchant while zombies keep moving.
- **Every five minutes or so**, finish the orders and repair jobs, then clock out at Pizza Co. Bank the haul and trade in **Garage → Market**. A successful delivery route adds a Pizza Delivery Contract that Mama G can buy.
- **Each session**, check what Rusty, Doc, and Mama G have in stock. The field vendors and Garage share inventory across players. A crew can buy out the last box of ammo, sell into a glut, or pool scrap to reopen a bankrupt shop.

Each of the three merchants has its own NEAR testnet account, inventory, and treasury. The market engine uses a readable `economy/pricing_rules.toml` file to set prices from stock relative to a target. Selling medkits to Doc raises her stock and can lower her next offer. Buying reduces stock and can push prices up. Simulated daily demand consumes supplies and pays merchants, while upkeep drains their treasuries. Shops that fall below their treasury threshold close until players fund their reopening. These changes happen during play without a developer patch.

In **Garage → Market**, each quote shows the merchant's reasoning and its tooltip shows the calculation. **Fast-forward 7 Days** plays back a simulated week of trades, price movements, and possible shop closures in **24 seconds**. It runs as a preview by default.

## How NEAR fits in

One deployed NEP-245 contract on NEAR testnet holds all **five tradable commodity types** in the camp market. Medkits, Premium Ammo, Pizza Delivery Contracts, Flashlight Batteries, and Food Stock each have a token ID. Eligible signed-in players and the merchant accounts can hold balances on that contract. The bridge runs the shared market and its pricing rules. Scrap, weapons, vehicles, and route state remain off-chain.

Players sign in with Google or play as guests. The bridge provisions testnet accounts in the background. For eligible signed-in trades, the player accepts a quote and the game's relayer submits the transfer and covers gas. The normal loop uses Buy and Sell buttons without seed phrases, wallet popups, or gas prompts. Guests trade through the shared bridge ledger.

The game uses its own trade requests and the Camp Commodities contract's idempotent `relayed_transfer` method. Official NEAR Intents verification is outside the current integration.

## Judge walkthrough

1. **Make a field purchase.** Start a solo or co-op route, earn scrap, then approach Rusty and buy an Ammo Dump. The crew can keep moving while you buy. The purchase draws from the same merchant stock shown in the Garage.
2. **Move Doc's quote.** Bank a medkit haul, open **Garage → Market**, and note Doc's stock and buy offer. Sell several medkits while she has room and scrap. Compare her next offer and hover the quote to see the reasoning and calculation.
3. **Watch a week pass.** Select **Fast-forward 7 Days** and watch the stock, price, and closure events. If a shop is already closed in the live market, open its card to see the pooled reopening fund. Applying a simulation to the shared market requires a configured operator.
4. **See what settles on NEAR.** The contract lists the five token IDs and holds the merchant balances. The bridge handles the transaction outside the gameplay UI. [Camp Commodities on NEAR testnet](https://testnet.nearblocks.io/address/camp.deadroute-sponsor-7x29.testnet)

The optional minted shotgun uses a separate NFT entitlement check. See [AUTH_SETUP.md](AUTH_SETUP.md) for sign-in and [ECONOMY.md](ECONOMY.md) for the pricing model and deployment. [NEP-245 specification](https://github.com/near/NEPs/blob/master/neps/nep-0245.md)

## Play a route

1. Launch a solo run or create an online co-op room. Invite up to three other players with the room code.
2. Scavenge pizza and supply crates, hand the orders to their customers, and finish the route jobs.
   Approach Rusty, Doc, or Mama G to quick-buy supplies with your current run's scrap.
3. When orders and jobs are complete, follow the Pizza Co. marker and interact at the depot door.
   Any eligible co-op courier at the door can clock the crew out.
4. In the Garage, open **Market** to trade banked supplies, pool scrap for a closed shop, or select
   **Fast-forward 7 Days** to watch the simulation. Its default playback lasts 24 seconds.
   Applying a preview to the live market requires a configured market operator.

A successful run banks remaining scrap. A failed run banks half, rounded down. The title-screen
leaderboard shows the top eight successful runs from the local save, with the courier's display
name and map. Use **F** or the touch **LIGHT** button to toggle your flashlight. Switch between
Night and Classic under **Settings → Lighting**.

| Feature | Implementation |
| --- | --- |
| Pizza pickup and handoff | [PizzaCargo](scripts/pickups/pizza_cargo.gd) validates the carrier and distance. |
| Route checkout | [Location.request_checkout](scripts/locations/location.gd) validates the depot interaction on the host. |
| Supply crates and banking | [Location._spawn_supply_crates](scripts/locations/location.gd) places crates. [GameManager.end_run](scripts/autoload/game_manager.gd) banks the haul and records the pizza delivery commodity for a successful delivery route. |
| Field vendors and the market | [Field vendor](scripts/locations/field_vendor.gd), [market engine](wallet-bridge/market.mjs), and [pricing rules](economy/pricing_rules.toml). |

## Gameplay tuning

- Edit `resources/weapons/*.tres` for ammo, damage, reloads, wear, and tracers.
- Edit the Skitter and Guard scenes for health, speed, sound, and behavior. Their wave timing and frequency are exported on `NoiseDirector`.
- Select a pool under `AcidPools` in Camp or Route 9 to change its radii, tick damage, or bubble effects. Move its matching markers to relocate the loot.
- Generator sound, shake, and light are exported on the repair jobs. Flashlight range and intensity are exported on the player scene. Night ambient and flower settings are in `scripts/locations/room_lighting.gd`.

## Future route reward design

Put the reward contract and its tests in **`contracts/rewards/`** at the repository root. This is the proposed location for the contract project. The game team owns Google and wallet sign-in, account linking, and the backend that verifies completed runs. The contract developer owns reward issuance, authorization of the reward issuer, and duplicate-claim protection.

The integration point is a **verified successful route completion**. Use the rules in `Location.can_finish_route()` and `Location.request_checkout()` to define that result. In production, a trusted game service needs to verify and record the result before the reward backend submits it. The current co-op host is a player's device, and the run summary and scrap balance are computed locally. Keep those values for gameplay and display. Use a server-issued run ID and verified player identity as the inputs to reward issuance.

### Proposed contract inputs

| Field | Source |
| --- | --- |
| Run ID | Generated by the trusted game service and reused for retries. |
| Player ID | Stable game account ID resolved by the authentication backend for either sign-in method. |
| Recipient | Verified NEAR account linked to that player by the authentication backend. |
| Reward | Calculated from the agreed reward rules using the verified result. |

Agree on the contract method and argument names, who qualifies in co-op, the reward amount or asset, and whether players claim rewards or receive them automatically before wiring the backend. Make issuance idempotent for each eligible player and run, including retries after a timeout. Scrap remains off-chain. Movement, driving, combat, jobs, and the pizza handoff run entirely in Godot.

For integration testing, verify one eligible payout, a repeat submission for the same player and run, a failed route, and an unlinked recipient. Use a local contract test environment or NEAR testnet.
