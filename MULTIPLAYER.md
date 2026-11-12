# Versus multiplayer: Team Deathmatch and Free For All

Open **Garage → Online Rooms** to create a room, choose a public room, or join a private room by its six-character code. The host can choose one of three modes:

| Mode | Who's against who |
|---|---|
| Co-op Run | Everyone vs the zombies (the original mode) |
| Team Deathmatch | RED vs BLUE. Players pick a side, or the host presses **Auto-balance** |
| Free For All | Everyone for themselves |

Up to 4 players. The host picks the mode, the map (Hospital, Camp, Route 9) and the
**Enemy pizza** rule. In versus modes everyone else presses **READY**; the host's **START MATCH** unlocks once
everyone is ready.

## How a match plays

- **Spawns.** TDM teams start on opposite sides of the map (left vs right). In FFA, players
  start as far apart as the map allows. Every spawn spot is checked to be on walkable,
  reachable ground. Each side also gets a car and its own pizza drop-off.
- **Objectives (per team; per player in FFA):**
  - finish the room's jobs (each team does them separately; `jobs_required`)
  - kill zombies (`zombie_kill_target`)
  - find and deliver your pizza
  The first side to finish everything wins. If the clock runs out, the highest score wins:
  jobs 100, pizza 300, zombies 5 each, player kills 25 each.
- **Pizzas.** There's no pizza at the start. Each side's pizza lands after 2-3 minutes, with
  "incoming" warnings at 30s and 10s. It always lands far from its own team, on ground you can
  walk to (navmesh path checked), never inside walls or props. Your team gets an arrow to it.
  Enemies only see it when they're close. Enemy pizza rule:
  - **Steal**: enemies can carry it off (they can't deliver it; it drops when they die or leave).
  - **Reset only**: an enemy touching it sends it to a new random spot.
- **Fighting.** Only the knife hurts players (guns still kill zombies, but bullets pass through
  players). **V** swaps gun/knife (short swap delay). No friendly fire in TDM. Dead players
  respawn after a few seconds on their own side with brief spawn protection, and drop any
  pizza they carried. The kill feed is at the top of the screen.
- **Health bars** float over every player: blue = you, green = teammates, red = enemies
  (in FFA, everyone else). Names show above them.

## Zombies (all modes, co-op too)

- They **see** only in front of them (a view cone) and only with a clear line of sight. Walls,
  buildings and props block it, so hiding works.
- They mostly **hear**. Each sound has a radius: shotgun 500, gunshot 420, horn (**H** in a
  car) 650, explosion 750, engine 230, sprinting 150, fights 160, jobs 220, walking 55,
  crouching (**C**) 0. Zombies in range walk to where the sound came from, not to where you are
  now. If they find nothing, they search for a few seconds, then go back to wandering.
- You hear their groans, shuffling feet and attacks from where they are (left/right panning,
  quieter with distance).

## Voice chat

Proximity voice: you hear nearby players (teammates and enemies) louder when close, fading
out by about 650 px. Settings (Garage or pause menu):

- **Voice chat mic**: off by default. Turn it on to be heard.
- **Push to talk (hold T)** or **Open mic** (voice activated).
- **Voice volume**, and **Mute other players**.

Browsers ask for microphone permission, and only allow it on https pages (itch.io is fine).
The Android build now requests the microphone permission.

## Tuning

Every number (match length, kill target, respawn time, knife damage/reach/cooldown, swap time,
pizza delay and distances, voice range, zombie sight cone and hearing radii) is in
**`resources/match_config.tres`**. Open it in the Inspector, or edit the defaults in
`scripts/systems/match_config.gd`.

## Who decides what (server authority)

The host is the referee (`scripts/autoload/match_state.gd`):

- **Knife hits:** the attacker's game sends "I hit X"; the host checks range, cooldown, teams
  and that both players are alive, then deals the damage.
- **Health:** each player's health is stored by their own game and synced to everyone. In
  versus, a player only accepts damage that comes from the host.
- **Zombies, jobs, pizzas, scores, timer, win/lose:** decided by the host and sent to everyone.
- **Leaving players:** their handyman is removed and any pizza they carried drops. In TDM the
  teams are rebalanced if one side ends up 2+ players bigger. In FFA their pizza and drop-off
  are removed.

## Test it with 2 players on one PC

**By hand (2 game windows):**
1. In the Godot editor: **Debug > Customize Run Instances...**, tick **Enable Multiple
   Instances**, set **2**, then press **Play** (F5). Two game windows open. Or export the
   Windows build and start the .exe twice.
2. Window 1: Garage → **Online Rooms** → **Create Room**. Set Mode to **Team Deathmatch**.
3. Window 2: Open **Online Rooms** and select the first window's room, or enter its code. Press **Join BLUE** and **READY**.
4. Window 1: **START MATCH**. You spawn on opposite sides. Walk to each other, press **V** for
   the knife and click to stab. Guns won't hurt each other.

**Automated (host + client game processes, no windows):**
```
powershell -ExecutionPolicy Bypass -File tests\run_versus_tests.ps1
```
It runs three suites: zombie senses, a full TDM match (lobby, teams, ready, spawns, knife
damage, guns doing nothing to players, no friendly fire, death/respawn/kill feed, voice
packets, pizza timing and placement, delivery, jobs, zombie kills, the win), and an FFA match
where the client steals the host's pizza and disconnects. If Godot isn't at the default path,
add `-Godot "C:\path\to\Godot_..._console.exe"`.

## Not covered yet

- The lobby is a menu screen, not a room you walk around in.
- Mute is for everyone at once; there's no per-player mute yet.
- Crouch and horn have keyboard keys (C, H) but no touch buttons yet.
- TDM team rebalancing on disconnect needs 3+ players and is not covered by the automated tests.
