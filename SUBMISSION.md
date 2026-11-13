# Death Route

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

- [Play Death Route](https://deathroute.fun/)
- [Camp Commodities on NEAR testnet](https://testnet.nearblocks.io/address/camp.deadroute-sponsor-7x29.testnet)
- [Source and README](https://github.com/CinnamonfirJ/death-route#readme)
