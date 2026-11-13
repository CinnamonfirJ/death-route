# Dead Route sign-in setup

On the web, players select **Sign in with Google** and choose an account in Google's account picker. The standalone desktop build uses a pairing code to link the browser to the game. Guest play is available from the title and account screens. The bridge provisions a sponsored NEAR testnet account in the background after Google verifies the player, and checks shotgun access in the Garage.

## Google Cloud

1. In Google Cloud, open project **death-route** and go to **Google Auth Platform → Clients**.
2. Open the existing Web application client. Under **Authorized redirect URIs**, add `https://deathroute.fun/oauth/callback` and `http://127.0.0.1:8787/oauth/callback` for local testing.
3. Under **Audience**, confirm the app is in production. The bridge requests `openid profile` to sign in and read the player's display name.
4. Set the repository's Actions secrets `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. GitHub Actions deploys both as private Cloudflare Worker variables.

[Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect) · [Google Auth Platform audience](https://support.google.com/cloud/answer/15549945?hl=en)

## 2. Identify the shotgun NFT

1. Open your existing NFT contract in a NEAR explorer on the network where it was minted. Copy the **contract account ID** and the shotgun's exact **token ID**. The collection name, display name, and transaction hash are different values.
2. Confirm the contract implements `nft_token` and returns the token's `token_id` and `owner_id`. If you have NEAR CLI installed, run this read-only query with your real values.

   ```text
   near contract call-function as-read-only YOUR_CONTRACT_ID nft_token json-args '{"token_id":"YOUR_TOKEN_ID"}' network-config testnet now
   ```

   Replace `testnet` with `mainnet` if the token was minted there. If the query returns `null`, check the token ID and network. There is no minted shotgun contract address or token ID bundled with this project.
3. Open [MyNearWallet Testnet](https://testnet.mynearwallet.com/) or [MyNearWallet Mainnet](https://app.mynearwallet.com/) on the same network. You will select your own wallet when the game opens the approval page. The browser asks you to sign a message. The bridge checks the signature, the on-chain full-access public key, and the token's current owner. The wallet-connection flow performs read-only RPC calls. [NEAR message signing](https://github.com/near/NEPs/blob/master/neps/nep-0413.md) · [NEAR NFT standard](https://github.com/near/NEPs/blob/master/neps/nep-0171.md)

## 3. Run the Google bridge locally or on Hostinger

1. For desktop development, run `npm --prefix wallet-bridge start` from the project root after configuring the ignored `wallet-bridge/.env`. The local URL is `http://127.0.0.1:8787`. The health endpoint is `http://127.0.0.1:8787/healthz`.
2. In a Hostinger account with Node.js hosting, create a **Node.js Web App** and upload the bridge ZIP. Use Node.js 22 or newer and `server.mjs` as the entry file. In **Environment variables**, set the following before deploying. Leave the platform's `PORT` setting in place.

   | Setting | Value | Visibility |
   | --- | --- | --- |
   | `WALLET_PUBLIC_URL` | `https://deadroute.run` | Public |
   | `WALLET_BIND` | `0.0.0.0` | Server config |
   | `GOOGLE_CLIENT_ID` | `web.client_id` from the Google JSON | Public |
   | `GOOGLE_CLIENT_SECRET` | `web.client_secret` from the Google JSON | Secret |
   | `GAME_ORIGIN` | Exact origin of the game's iframe when hosted separately, with no trailing slash | Public |
   | `NEAR_NFT_NETWORK` | `testnet` or `mainnet`, matching your minted NFT | Public |
   | `NEAR_SHOTGUN_CONTRACT` | Exact NFT contract account ID | Public |
   | `NEAR_SHOTGUN_TOKEN_ID` | Exact shotgun token ID | Public |
   | `NEAR_MT_CONTRACT` | Camp Commodities NEP-245 contract account (optional; see [ECONOMY.md](ECONOMY.md)) | Public |
   | `MARKET_ALLOW_GUESTS` | `1` lets players trade at the camp market without signing in | Public |

3. Connect `deadroute.run` to the app in Hostinger. Once DNS and TLS are ready, open `https://deadroute.run/healthz` and check for `"google_configured":true`. If the game runs on itch.io, determine its iframe origin using `location.origin` in the iframe's browser console. Put that origin in `GAME_ORIGIN` and redeploy. The Web export uses `https://deadroute.run` as its bridge URL.
4. Keep the Google credential JSON, secret, relayer keys and recovery phrases out of source control and both deployment ZIPs. Google sign-in and connecting an existing NEAR wallet are separate actions. The legacy Auth0 configuration remains available when both direct Google values are blank.

[Deploy a Node.js app on Hostinger](https://www.hostinger.com/support/how-to-deploy-a-nodejs-website-in-hostinger/) · [Hostinger environment variables](https://www.hostinger.com/support/how-to-add-environment-variables-during-node-js-application-deployment/)

## 4. Verify it yourself

1. Open the title screen and choose **Sign in with Google → Continue with Google**. Confirm the code displayed in the game, approve in your browser, then return. The button reads **Signed in** and the Garage's Market tab shows *Trading as Google courier*. The NEAR account created behind that sign-in is never shown to the player.
2. Sign out and choose **Play as Guest**. The market still works under a guest id.
3. Stop the bridge and try sign-in. Confirm you see a clear error and can still select **Play as Guest**.

The shotgun stays locked unless a wallet that owns the configured NFT is linked through the legacy wallet flow, which the title screen no longer offers. The bridge keeps that flow (`method: "wallet"`) for tooling only.
