# Building, sharing & playing Dead Route

## Ready-made packages

`build/itch/` holds what you upload or send:

| File | What it is |
|---|---|
| `DeadRoute-web-playtest.zip` | Current browser playtest build (upload to itch.io) |
| `DeadRoute-windows.zip` | Windows game (one `.exe` inside) |
| `DeadRoute-android.apk` | Android (debug-signed; sideload) |

## Put the web version on itch.io (free)

1. In Godot, open **Editor → Manage Export Templates** and install the templates for the editor's exact version. Open **Project → Export → Web**. Use the **Compatibility** renderer, turn **Thread Support** and **Extension Support** off, and set **Canvas Resize Policy** to **Adaptive**. The preset already points to `tools/dead_route_web.html` and enables the mobile keyboard. The Web viewport scales up from 640×360 and caps the backing canvas at CSS pixel resolution.
2. Choose **Export Project**, clear **Export With Debug**, and save to `build/web/index.html`. Export into a fresh folder for a new version. Keep `index.html`, `index.js`, `index.wasm`, `index.pck`, the audio worklets, and the generated icons together. Zip the files with `index.html` at the ZIP root.
3. Serve that folder over HTTP for a local preview, for example with `python -m http.server 8000 --directory build/web`. Open `http://localhost:8000`, click **Tap to play**, and run the checklist below. For remote browser multiplayer, use a secure `wss://` room address.
4. Sign in to itch.io and open **Dashboard → Create new project**. Choose **Kind of project → HTML**, upload your ZIP, and select **This file will be played in the browser**.
5. Under **Embed options**, set the desktop viewport to **1280 × 720** and enable **Fullscreen Button** and **Mobile Friendly**. Keep **Click to Play** enabled. The Web page prompts touch players to rotate to landscape. The single-threaded build does not require the itch.io SharedArrayBuffer option.
6. Set **Visibility & access** to **Restricted** for an invite-only test, choose the appropriate access controls, and save. Preview it with a tester account before sharing. You can add a Windows download so volunteer hosts can run the same release.

[Godot Web export settings](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html) · [itch.io HTML5 upload and embed settings](https://itch.io/docs/creators/html5)

## Publish the web game to Cloudflare

The [GitHub Actions workflow](.github/workflows/deploy-web.yml) exports the game on every push to `main`. It packages the engine under Cloudflare Pages' 25 MiB file limit and deploys to the existing `dead-route` project. Source stays in GitHub; generated files stay out of Git.

1. In Cloudflare, open **My Profile → API Tokens → Create Token → Create Custom Token**. Grant **Account → Cloudflare Pages → Edit**, scoped to the account that owns `dead-route`.
2. In the GitHub repository, go to **Settings → Secrets and variables → Actions → New repository secret**. Name it `CLOUDFLARE_API_TOKEN` and paste the Cloudflare token into the secret value.
3. Open **Actions → Build and deploy Dead Route → Run workflow**, select `main`, and start the run. Future pushes to `main` publish automatically. If the secret is missing, the workflow builds an artifact and skips publishing.
4. Verify [dead-route.pages.dev](https://dead-route.pages.dev/) reaches **Tap to play** and opens the title screen. In Cloudflare, attach `deadroute.run` under **Workers & Pages → dead-route → Custom domains** and wait for it to become active before testing the same flow at the custom domain.

For a one-off dashboard upload, export the Web preset to `build/web/index.html`, then run `python tools/package_cloudflare_web.py build/web build/pages --zip build/DeadRoute-Cloudflare.zip` with a new or empty `build/pages` directory.

[Cloudflare Pages deployment from GitHub Actions](https://developers.cloudflare.com/pages/how-to/use-direct-upload-with-continuous-integration/)

Required credit for the car art is already in the Garage footer; also paste
`Racing Cars by Ibrahim Smati (itch.io/@ibrahim-smati), CC BY 4.0` into the page description.

## Playing together

One person **hosts** from the **PC or Android** version (browsers can't host). Everyone else joins:
Garage > **CO-OP** > paste the address in **Host IP / link** > **Join**.

### Same Wi-Fi
Host clicks **Host**. Friends type the host's local IP (e.g. `192.168.1.20`). Windows may ask to
allow the game through the firewall the first time: allow it on private networks.

### Over the internet / browser friends (recommended: free tunnel, no router setup)
Browsers on itch.io (https) may only use secure `wss://` connections, so the host shares a tunnel
link instead of an IP. With Cloudflare's free quick tunnel (no account needed):

1. Host installs `cloudflared` (https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).
2. Host starts the game, clicks **Host** (port 7777), then runs:
   `cloudflared tunnel --url http://localhost:7777`
3. It prints a link like `https://random-words.trycloudflare.com`. Share it.
4. Friends paste that link (https:// or wss:// both work) into **Host IP / link** and **Join**.
   Works from the browser, PC and Android versions alike.

(ngrok works the same way: `ngrok http 7777`.) Alternatively forward TCP 7777 on the host's router
and have PC/Android friends join the host's public IP; browser players still need the tunnel.
Use temporary tunnels for pilot rooms and stable endpoints for scheduled events. [Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)

All players must run the same build. Each match holds up to **four players including the host**. Browser clients can join a Windows or Android host. They need a secure tunnel when playing from itch.io.

## Run the 345-person playtest

1. Recruit a small pilot group first. Run a full four-person room with a wired desktop host, an iPhone Safari player, an Android Chrome player, and a desktop browser. Verify voice separately if you use it. Watch for stuttering, reconnects, and game-state delay during a full zombie wave and while driving.
2. Schedule waves by time zone and assign testers to four-person groups with a named host. If all 345 testers play simultaneously and hosts are among them, you need at least **87 rooms**. If every host is separate from the tester list, each host has three tester seats, so you need **115 rooms**. Smaller waves let the same hosts serve more testers.
3. Give each room a short code and its own WSS endpoint. For stable host URLs, set `network/room_codes={"DR01": "wss://ROOM_01_HOST", "DR02": "wss://ROOM_02_HOST"}` under `[dead_route]` in `project.godot` before exporting the shared build. In **Garage → CO-OP**, enter the code in the host field and press **Join**. If a tunnel URL changes, hand out the new WSS link directly. Codes are address shortcuts. They don't authenticate players or reserve seats.
4. For a large event, use separate stable host endpoints and test them under load before announcing capacity. Start with the number of concurrent rooms that passed your pilot, then add hosts gradually. Record join latency, disconnects, host frame time and upload usage. The current peer-hosted build has no central match server or automatic matchmaking.
5. Send testers the restricted itch page, version, time slot, room code or WSS link, and a link to one feedback form. Ask for device and browser, map, room code, timestamp and time zone, what they expected, what happened, and reproduction steps. Allow a screenshot or short clip. Keep Google and wallet sign-in optional for playtesters.
6. Keep one host spare per wave. If a host disconnects, assign the group a spare room and distribute its WSS link. Record the failed host and timestamp for diagnosis.

## Smoke checklist before sharing

1. **Visuals.** Check the Garage header, upgrade rows and Start Run at 640×360. Confirm the title pools are green. In Night, look for readable corners, faint flower glow at the perimeter, and a subtle glow on a nearby zombie.
2. **Flashlight and generators.** Press F once, release, and check **LIGHT ON**. Press again and check **LIGHT OFF**. Repair plant power in Hospital or the crane generator in Route 9. In Night mode, check the light and vibration, then walk away until the hum fades.
3. **Weapons and zombies.** Find the orange Flare Pistol and cyan Needle SMG at the acid caches. Swap with **E**, fire, and reload. Confirm the HUD displays **OUT OF AMMO** or **BROKEN** when appropriate. Hear and compare the Skitter's rush and the Guard's stun resistance as waves advance.
4. **Acid.** Step into a Camp or Route 9 pool and check for a green tick and bubbling sound. Leave and confirm damage stops. Lure a zombie in. Check that you can walk around the pool.
5. **Mobile.** Launch from the itch preview on iPhone Safari and Android Chrome in landscape. Check the safe edges, sound on first interaction, move while firing, reload, use, sprint, light, swap, and the car's **SHOVE**. Join a desktop host through WSS and finish one route together.
6. **Account.** Follow the owner, nonowner and guest checks in [AUTH_SETUP.md](AUTH_SETUP.md).
7. **Release.** Open the itch link as an invited tester. Launch the uploaded browser ZIP and join a room using the code and again using its direct WSS link.

## Rebuilding

```
godot --headless --export-release "Windows Desktop" build/windows/DeadRoute.exe
godot --headless --export-release "Web" build/web/index.html
godot --headless --export-debug "Android" build/android/DeadRoute.apk
```

- Rooms (`rooms/*.tscn`, see ROOMS.md) and sounds (`assets/audio/`) are included automatically.
- Sounds are generated: `python -I tools/gen_sfx.py assets/audio` (edit recipes there).
- Android release (Play Store): create a release keystore, set it under
  Project > Export > Android > Keystore > Release, then `--export-release`.
- `build/` has a `.gdignore` so Godot doesn't import the exported files.
