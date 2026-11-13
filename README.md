# Death Route

Death Route is a Godot 4.7 zombie-survival delivery game with solo play and WebSocket co-op. Open [`project.godot`](project.godot) in Godot to run it locally. See [BUILD.md](BUILD.md) for exports and multiplayer setup.

## The problem

A fixed-price shop gives players little reason to react to what other players scavenge or buy. We wanted the supply run, the field purchase, and the camp market to affect each other while players stay focused on surviving the route.

## What we built

Death Route is a top-down zombie survival and pizza-delivery game for solo play or up to four players in online co-op. Crews fight, drive, scavenge supplies, deliver orders, finish repair jobs, and return to Pizza Co. to clock out. During the run, players spend earned scrap at field vendors for ammo, healing, a temporary damage shield, or a speed boost. The Garage Market and field vendors draw from shared merchant stock. Selling medkits increases stock and can lower the next quote. Buying can raise prices or sell a shelf out. Merchants can go bankrupt, and players can pool scrap to reopen them. The Garage's Fast-forward 7 Days mode previews a simulated week of prices, stock, and shop closures.

## How NEAR fits in

Players can sign in with Google or play as guests. The bridge provisions NEAR testnet accounts in the background and uses the deployed Camp Commodities NEP-245 contract for five tradable commodity types: Medkits, Premium Ammo, Pizza Delivery Contracts, Flashlight Batteries, and Food Stock. For eligible signed-in trades, the game relayer submits transfers and pays gas in the background. Players trade through game buttons without a seed phrase, wallet popup, or gas prompt. Guest trades use the shared market ledger, and scrap stays off-chain.

The bridge uses the game's relayer and the Camp Commodities contract's idempotent
`relayed_transfer` method. The official NEAR Intents verifier is outside the current integration.
The [deployed testnet contract](https://testnet.nearblocks.io/address/camp.deadroute-sponsor-7x29.testnet)
contains the five commodity token IDs. The optional minted shotgun uses a separate NFT entitlement
check. See [AUTH_SETUP.md](AUTH_SETUP.md) and [ECONOMY.md](ECONOMY.md) for implementation and setup.

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
