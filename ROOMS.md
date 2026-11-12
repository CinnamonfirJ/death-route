# Editing rooms

The three run maps are ordinary Godot scenes. Open them in the editor and edit them like any
other scene: paint tiles, drag props in, move things around. No code generates the layout.

| Room | Scene | Original reference screenshot |
|---|---|---|
| St. Mercy Hospital | `rooms/hospital.tscn` | `room_screenshots/hospital.png` |
| Survivor Camp | `rooms/camp.tscn` | `room_screenshots/camp.png` |
| Route 9 Gas & Junk | `rooms/wasteland.tscn` | `room_screenshots/wasteland.png` |

Each room also has an original `_layout.png` screenshot that leaves out zombies, people and cars that
move, so you can see the layout on its own. Screenshots are 1 pixel = 1 game pixel
(a tile is 32 x 32).

## What's in a room scene

```
Hospital (Room)
├─ Ground            TileMapLayer: dirt. Covers the whole playable area (this sets the map size)
├─ Roads             TileMapLayer: road surface
├─ Floors            TileMapLayer: indoor floor
├─ Landmarks         painted district names for navigation
├─ EdgeCanopy        animated perimeter sprites with a palette for each room
├─ Decals            blood splats and other effects at run time (leave empty)
├─ Entities          everything that stands up (sorted by height so things overlap correctly)
│  ├─ Walls          TileMapLayer: walls block movement and zombie paths
│  ├─ Player         where you start
│  ├─ Car            your starting car
│  ├─ DeliveryCustomer  who you bring the pizza to
│  ├─ Props          beds, tents, wrecks, crates... (solid obstacles)
│  ├─ Jobs           repair jobs; every job here must be done to finish the route
│  └─ Barrels        explosive barrels
├─ Markers           spots where things show up when a run starts (see below)
└─ NoiseDirector, CarSpawner, RunSummary, GameCamera, HUD   (leave these alone)
```

## Common edits

**Paint ground, roads, floors, walls.** Select the layer (`Ground`, `Roads`, `Floors` or
`Entities/Walls`), open the **TileMap** panel at the bottom, pick a tile and paint. Right-click
erases. Ground uses `assets/tilesets/outdoor_tiles.tres`. Roads, floors, and walls use
`assets/tilesets/room_tiles.tres`. In the room atlas, the first three rows are solid barriers,
the next three are road tiles, and the last row contains hospital floor patterns. The barrier
and road rows have 16 variants for different joins and edges. Update **Bounds** on
`EdgeCanopy` if you resize the ground rectangle.

**Add a prop.** In the FileSystem panel open `scenes/props/library/` (`hospital/`, `camp/`,
`wasteland/`) and drag a scene onto `Entities/Props`. A prop's position is where its base
touches the ground. In the Inspector:
- `Texture`: change what it looks like
- `Solid`: off = you can walk through it (rugs, signs)
- `Cast Shadow`: the soft shadow under it in game
- `Footprint`: how much of the sprite blocks movement

**Move or delete anything.** Select it and drag, or press Delete. Hold Ctrl while dragging to
snap to the grid.

**Add a job.** Instance `scenes/tasks/hold_task.tscn` under `Entities/Jobs` and set `Task Name`,
`Waypoint Label`, `Duration`, `Noise Per Sec`, `Reward Scrap`, `Tileset Id` + `Broken Region` (what it looks like,
e.g. `hospital` / `radio_desk`). For a fuel pump use `scenes/tasks/fuel_pump_task.tscn`.
The job image only appears in the game, not in the editor. Copying an existing job
(Ctrl+D) keeps its preview.

**Add barrels.** Instance `scenes/props/explosive_barrel.tscn` under `Entities/Barrels`.

## Markers

Markers are the spots where things appear when a run starts. In the editor they show an icon
and a label; in the game you don't see them. To add one, duplicate an existing marker (Ctrl+D)
or add a `Marker2D` under `Markers` and attach `scripts/rooms/room_marker.gd`. Then pick its
`Kind` in the Inspector:

| Kind | What happens |
|---|---|
| ZOMBIE_SPAWN | Waves of zombies come from these spots (spread them around the edges) |
| CAR_SPAWN | Where a replacement car can appear if yours is wrecked |
| PIZZA_SPOT | The pizza is hidden at **one** of these each run |
| SURVIVOR | A survivor to recruit (some are bitten, one may be a rival) |
| SPARE_CAR | A random car to take (50-100% health) |
| WALKER / LATCHER / STOPPER / BRUTE | A zombie of that type that's already there at the start |
| SCRAP / AMMO / FUEL / MEDKIT | A pickup. `Amount` = 0 uses the default amount |
| CREW_START | Where each co-op guest starts, in scene tree order |

A room needs at least: one PIZZA_SPOT, a few ZOMBIE_SPAWNs, and a few CAR_SPAWNs on roads.

## Test your changes

Open the room and press **F6** (Run Current Scene) to play it directly, or start the game and
pick the room in the Garage.

## Adding a new room

1. Duplicate a room scene (e.g. `rooms/camp.tscn` to `rooms/mall.tscn`), then edit it.
2. On the root node set `Location Id` (e.g. `mall`) and `Location Name`.
3. Add it to `LOCATIONS` in `scripts/autoload/game_manager.gd` so it shows up in the Garage.
