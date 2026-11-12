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
3. Serve that folder over HTTP for a local preview, for example with `python -m http.server 8000 --directory build/web`. Open `http://localhost:8000`, click **Tap to play**, and run the checklist below. Online rooms use the room service configured in the build.
4. Sign in to itch.io and open **Dashboard → Create new project**. Choose **Kind of project → HTML**, upload your ZIP, and select **This file will be played in the browser**.
5. Under **Embed options**, set the desktop viewport to **1280 × 720** and enable **Fullscreen Button** and **Mobile Friendly**. Keep **Click to Play** enabled. The Web page prompts touch players to rotate to landscape. The single-threaded build does not require the itch.io SharedArrayBuffer option.
6. Set **Visibility & access** to **Restricted** for an invite-only test, choose the appropriate access controls, and save. Preview it with a tester account before sharing. You can add a Windows download for desktop players.

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

From the Garage, open **Online Rooms**. Choose **Create Room** and leave **List publicly** on for a room that appears in the browser. Turn it off to make the room code the only way in. Friends can select a public room or enter its six-character code. The host can create a room from the browser, desktop, or Android build. Use the same game release on all devices. A room holds four players, including its host. The host keeps the match running, so closing the host's game closes the room.

## Deploy the room service

1. In Cloudflare, enable the account's **workers.dev** subdomain under **Workers & Pages**.
2. Add the GitHub Actions secret **CLOUDFLARE_ROOMS_API_TOKEN**. Use an API token scoped to the account that owns Dead Route with **Account → Workers Scripts → Edit** and **Account → Account Settings → Read**. Keep the existing Pages token for the web upload.
3. Run **Build and deploy Dead Route** on **main**. The workflow deploys the relay, reads its public HTTPS URL, and sets that URL in the game before exporting it. For a separately deployed relay, set the GitHub repository variable **DEAD_ROUTE_ROOM_SERVICE** to its public HTTPS URL instead.
4. For manual desktop, Android, or itch exports, set **network/room_service** in **project.godot** to the same public HTTPS URL before exporting.

For a local test, run **npx --yes wrangler@4.161.0 dev --config online-rooms/wrangler.toml --port 8794**. Launch Godot with **-- --rooms-url=http://127.0.0.1:8794** after the engine arguments. The development service accepts local rooms without an account.

## Run the 345-person playtest

1. Test a four-person room across desktop, iPhone Safari, and Android Chrome. Verify joining, starting, zombie waves, driving, disconnects, and voice.
2. Schedule waves by time zone. The relay currently allows 48 rooms with four seats each. Run smaller waves and leave seats free for retests. A 345-player simultaneous event needs at least 87 rooms if hosts are also testers. Load test the relay before raising that limit.
3. Send each group the build link, time slot, room code, and feedback form. Ask for device, browser, map, room code, timestamp, and what went wrong.
4. If a host disconnects, start another room and share its new code.

## Smoke checklist before sharing

1. **Visuals.** Check the Garage header, upgrade rows and Start Run at 640×360. Confirm the title pools are green. In Settings, move Room Brightness left and right and verify the change in Night mode. In Night, look for readable corners, faint flower glow at the perimeter, and a subtle glow on a nearby zombie.
2. **Flashlight and generators.** Press F once, release, and check **LIGHT ON**. Press again and check **LIGHT OFF**. Repair plant power in Hospital or the crane generator in Route 9. In Night mode, check the light and vibration, then walk away until the hum fades.
3. **Weapons and zombies.** Find the orange Flare Pistol and cyan Needle SMG at the acid caches. Swap with **E**, fire, and reload. Confirm the HUD displays **OUT OF AMMO** or **BROKEN** when appropriate. Hear and compare the Skitter's rush and the Guard's stun resistance as waves advance.
4. **Acid.** Step into a Camp or Route 9 pool and check for a green tick and bubbling sound. Leave and confirm damage stops. Lure a zombie in. Check that you can walk around the pool.
5. **Mobile.** Launch in landscape on iPhone Safari and Android Chrome. Check the safe edges, sound, and the **Objectives** drawer. Move with the left thumb and drag the right stick past the ring to fire. Release it to stop. Switch to **Settings → Touch shooting → Advanced** to use a separate Fire button. Check reload, use, sprint, light, swap, and the car's **Shove**. Create a room on mobile and join from desktop.
6. **Account.** Follow the owner, nonowner and guest checks in [AUTH_SETUP.md](AUTH_SETUP.md).
7. **Release.** Open the itch link as an invited tester. Launch the uploaded browser ZIP and join a room by code and another from the public list.

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
