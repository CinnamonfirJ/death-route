# Dead Route sign-in setup

Players select **Sign in with Google**, confirm the game code, and return to play. Guest play is available from the title and account screens. The bridge provisions a sponsored NEAR testnet account in the background after Google verifies the player, and checks shotgun access when the player opens the Garage.

## Google Cloud

1. In Google Cloud, open project **death-route** and go to **Google Auth Platform → Clients**.
2. Open the existing Web application client. Under **Authorized redirect URIs**, add `https://auth.deathroute.fun/oauth/callback` and `http://127.0.0.1:8787/oauth/callback` for local testing.
3. Open **Audience** and add your testers if the app is still in testing. The bridge requests the `openid` scope.
4. Copy the client ID into `GOOGLE_CLIENT_ID` and put the client secret in the host's private environment as `GOOGLE_CLIENT_SECRET`.

[Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect)

## Host the bridge

Deploy the `wallet-bridge/` directory as a Node.js 22+ app. Install dependencies with `npm ci --omit=dev` and use `npm start` or `node server.mjs`. Attach `auth.deathroute.fun` to the app using the DNS record provided by the Node host. Keep the apex domain on Cloudflare Pages.

| Environment variable | Value |
| --- | --- |
| `WALLET_PUBLIC_URL` | `https://auth.deathroute.fun` |
| `WALLET_BIND` | `0.0.0.0` |
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

The host may supply `PORT`. Otherwise the bridge uses `WALLET_PORT` or defaults to `8787`. To add an itch.io embed, append its exact iframe origin to `GAME_ORIGIN`.

The bridge derives a server-managed key and account ID from the verified Google subject, sponsor ID, and root secret. Keep the sponsor ID and root secret stable so returning players retain the same account. The sponsor pays testnet gas and initial storage funding. Google identities and signing keys stay on the server.

For local desktop testing, use the ignored `wallet-bridge/.env` and `npm --prefix wallet-bridge start`. The default local bridge URL is `http://127.0.0.1:8787`. Keep the credential JSON, local environment file, and signing keys out of the repository and deployment ZIP.

## Verify the setup

1. Open `https://auth.deathroute.fun/healthz`. Check that both `google_configured` and `provisioning_configured` are true.
2. Sign in with a Google test account. Confirm the browser returns a success message and the game shows **Signed in with Google**.
3. Sign in again with the same account and verify it reuses the same sponsored testnet account. Check that the Garage unlocks the shotgun only for the account that owns the configured token.
4. Cancel sign-in and start a guest run to check the fallback.

[NEAR account model](https://docs.near.org/protocol/accounts-contracts/account-model)
