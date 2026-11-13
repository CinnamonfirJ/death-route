# Dead Route sign-in setup

On the web, players select **Sign in with Google** and choose an account in Google's account picker. The standalone desktop build uses a pairing code to link the browser to the game. Guest play is available from the title and account screens. The bridge provisions a sponsored NEAR testnet account in the background after Google verifies the player, and checks shotgun access in the Garage.

## Google Cloud

1. In Google Cloud, open project **death-route** and go to **Google Auth Platform → Clients**.
2. Open the existing Web application client. Under **Authorized redirect URIs**, add `https://deathroute.fun/oauth/callback` and `http://127.0.0.1:8787/oauth/callback` for local testing.
3. Under **Audience**, confirm the app is in production. The bridge requests the `openid` scope.
4. Set the repository's Actions secrets `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. GitHub Actions deploys both as private Cloudflare Worker variables.

[Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect)

## Host the bridge

GitHub Actions deploys the `dead-route-sign-in` Worker before publishing the game to Cloudflare Pages. The Pages service binding forwards sign-in requests on `deathroute.fun` to that Worker, and a Durable Object keeps sign-in state between requests. Set `NEAR_RELAYER_ACCOUNT`, `NEAR_RELAYER_KEY`, and `NEAR_ACCOUNT_ROOT_KEY` in the repository's Actions secrets so deployment installs them on the Worker. Set optional balance and item settings in **Cloudflare → Workers & Pages → dead-route-sign-in → Settings → Variables and Secrets**.

| Environment variable | Value |
| --- | --- |
| `WALLET_PUBLIC_URL` | `https://deathroute.fun` |
| `GAME_ORIGIN` | `https://deathroute.fun,https://dead-route.pages.dev` |
| `GOOGLE_CLIENT_ID` | Google Web application client ID |
| `GOOGLE_CLIENT_SECRET` | Google Web application client secret. Private. |
| `NEAR_RELAYER_ACCOUNT` | Dedicated, funded NEAR testnet sponsor account ID. Maximum 40 characters. |
| `NEAR_RELAYER_KEY` | Sponsor account's signing key. Private. |
| `NEAR_ACCOUNT_ROOT_KEY` | 32 random bytes in hex. Generate with `node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"`. Private. Back it up securely. |
| `NEAR_INITIAL_BALANCE` | Optional initial funding in yoctoNEAR. Default is 0.01 testnet NEAR. |
| `NEAR_NFT_NETWORK` | `testnet` for the provisioned accounts. |
| `NEAR_SHOTGUN_CONTRACT` | Public account ID of the testnet contract implementing `nft_token`. |
| `NEAR_SHOTGUN_TOKEN_ID` | Exact public token ID for the shotgun. |

To add an itch.io embed, append its exact iframe origin to `GAME_ORIGIN` in `wallet-bridge/wrangler.toml`.

The bridge derives a server-managed key and account ID from the verified Google subject, sponsor ID, and root secret. Keep the sponsor ID and root secret stable so returning players retain the same account. The sponsor pays testnet gas and initial storage funding. Google identities and signing keys stay on the server.

For local desktop testing, use the ignored `wallet-bridge/.env` and `npm --prefix wallet-bridge start`. The default local bridge URL is `http://127.0.0.1:8787`. Keep the credential JSON, local environment file, and signing keys out of the repository and deployment ZIP.

## Verify the setup

1. Open `https://deathroute.fun/healthz`. Check that `google_configured` is true and that `provisioning_configured` becomes true once you add the NEAR sponsor settings.
2. Sign in with a Google test account. Confirm the browser returns a success message and the game shows **Signed in with Google**.
3. Sign in again with the same account and verify it reuses the same sponsored testnet account. Check that the Garage unlocks the shotgun only for the account that owns the configured token.
4. Cancel sign-in and start a guest run to check the fallback.

[NEAR account model](https://docs.near.org/protocol/accounts-contracts/account-model)
