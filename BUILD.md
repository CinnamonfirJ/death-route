# Building, sharing & playing Dead Route

## Ready-made packages

`build/itch/` holds what you upload or send:

| File | What it is |
|---|---|
| `DeadRoute-web.zip` | Browser version (upload to itch.io) |
| `DeadRoute-windows.zip` | Windows game (one `.exe` inside) |
| `DeadRoute-android.apk` | Android (debug-signed; sideload) |

## Put the web version on itch.io (free)

1. Sign in at itch.io, go to **Dashboard > Create new project**.
2. **Kind of project: HTML**. Upload `build/itch/DeadRoute-web.zip` and tick
   **"This file will be played in the browser"**.
3. Embed options: **viewport 1280 x 720**, tick **Fullscreen button** and **Mobile friendly**
   (orientation: landscape). No "SharedArrayBuffer" option needed (built without threads).
4. Optionally also upload `DeadRoute-windows.zip` (Kind: Windows) and the `.apk` (Kind: Android)
   as downloads on the same page.
5. Visibility: **Restricted** (only people with the link + password) or **Public**. Save, and send
   your friends the page link.

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

All players must run the same build. Up to 4 players.

## Rebuilding

```
godot --headless --export-release "Windows Desktop" build/windows/DeadRoute.exe
godot --headless --export-release "Web" build/web/index.html
godot --headless --export-debug "Android" build/android/DeadRoute.apk
```

- Maps (`levels/*.txt`) and sounds (`assets/audio/`) are included by every preset.
- Sounds are generated: `python -I tools/gen_sfx.py assets/audio` (edit recipes there).
- Android release (Play Store): create a release keystore, set it under
  Project > Export > Android > Keystore > Release, then `--export-release`.
- `build/` has a `.gdignore` so Godot doesn't import the exported files.
