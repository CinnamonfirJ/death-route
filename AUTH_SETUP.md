# Death Route sign-in setup

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

## 3. Run the bridge

- Production uses Cloudflare Pages and a Worker on [deathroute.fun](https://deathroute.fun/). The workflow deploys with `WALLET_PUBLIC_URL=https://deathroute.fun`. Check the [health endpoint](https://deathroute.fun/healthz) after deployment.
- For desktop development, configure the ignored `wallet-bridge/.env` and run `npm --prefix wallet-bridge start` from the project root. The local bridge is at `http://127.0.0.1:8787`.
- Keep the Google credential JSON, client secret, relayer keys, and recovery phrases out of source control. See [ECONOMY.md](ECONOMY.md) for the market contract settings.

## 4. Verify it yourself

1. On the web, choose **Sign in with Google**, pick your account, and return to the game. The account screen should show your display name. The standalone desktop build uses a browser pairing code.
2. Sign out and choose **Play as Guest**. The market works under a guest ID.
3. If you use the local bridge, stop it and try sign-in. Confirm the game reports the error and still offers guest play.

The shotgun unlocks when the provisioned NEAR account owns the configured NFT.
