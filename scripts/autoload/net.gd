extends Node
## Multiplayer: lobby, roster, match start, and the helpers gameplay code uses so
## it works the same offline and online.
##
## Online rooms use outbound WebSockets on every platform, including browsers.
##
## Authority model:
##   host (peer 1)  zombies, jobs, pickups, noise director, car respawns, run end
##   each peer      its own handyman (Player_<id>; the scene's "Player" is the host's)
##   driver         the car they're driving
## Anything that changes something you don't own is forwarded to its owner
## (see is_local_authority + the _rpc_* methods on Player/Zombie/Car/...).

signal roster_changed
signal status_changed(text: String)
signal all_peers_ready
signal local_player_spawned(player: Node)

const RoomPeer := preload("res://scripts/net/room_peer.gd")
const DEFAULT_PORT := 7777
const MAX_PLAYERS := 4
## Seconds between batched noise reports from clients to the host.
const NOISE_FLUSH := 0.1

var players := {}  # peer id -> {"name", "character", "team": int, "ready": bool}
## mode: "coop" (the classic run), "tdm" (Team Deathmatch) or "ffa" (Free For All).
## pizza_enemy: what an enemy can do with your pizza in versus ("steal" or "reset").
var settings := {"location": "hospital", "rival": false, "mode": "coop", "pizza_enemy": "steal"}
const MODES := ["coop", "tdm", "ffa"]
const MODE_NAMES := {"coop": "Co-op Run", "tdm": "Team Deathmatch", "ffa": "Free For All"}
var role := "crew"  # "crew" or "rival" (only the rival's own machine knows)
var my_name := "Handyman"
var in_match := false
var room_code := ""
var room_public := false
var room_error := ""

var _spawner: MultiplayerSpawner
var _ready_peers := {}
var _downed := {}
var _rival_id := 0
var _rival_exposed := false
var _noise_sum := 0.0
var _noise_pos := Vector2.ZERO
var _noise_cd := 0.0
var _sounds: Array = []


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	EventBus.noise_increased.connect(_on_local_noise)
	EventBus.sound_made.connect(_on_local_sound)


func _process(delta: float) -> void:
	if _noise_sum <= 0.0 and _sounds.is_empty():
		return
	if not is_online() or multiplayer.is_server():
		_noise_sum = 0.0
		_sounds.clear()
		return
	if _noise_sum > 0.0:
		_noise_cd -= delta
		if _noise_cd <= 0.0:
			_noise_cd = NOISE_FLUSH
			_rpc_noise.rpc_id(1, _noise_sum, _noise_pos)
			_noise_sum = 0.0
	if not _sounds.is_empty():
		_rpc_sounds.rpc_id(1, _sounds)
		_sounds = []


# ---------- State ----------

func is_online() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) \
		and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func is_host() -> bool:
	return is_online() and multiplayer.is_server()


## Host simulates shared things (zombies, jobs, pickups...). Offline you're the host.
func is_sim_authority() -> bool:
	return not is_online() or multiplayer.is_server()


func local_id() -> int:
	return multiplayer.get_unique_id() if is_online() else 1


## True when this machine owns `node` (always true offline).
func is_local_authority(node: Node) -> bool:
	return not is_online() or node.is_multiplayer_authority()


func peer_name(id: int) -> String:
	return players.get(id, {}).get("name", "Handyman %d" % id)


## Versus (TDM / FFA) is on for this lobby / match.
func is_versus() -> bool:
	return is_online() and settings.get("mode", "coop") in ["tdm", "ffa"]


## Team id: TDM 0 (red) / 1 (blue); FFA every player is their own team (= peer id).
func peer_team(id: int) -> int:
	if settings.get("mode", "coop") == "ffa":
		return id
	return int(players.get(id, {}).get("team", 0))


func peer_ready(id: int) -> bool:
	return id == 1 or bool(players.get(id, {}).get("ready", false))


func all_ready() -> bool:
	return players.keys().all(func(id: int) -> bool: return peer_ready(id))


func peer_character(id: int) -> StringName:
	return players.get(id, {}).get("character", GameManager.DEFAULT_CHARACTER)


func room_service_url() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--rooms-url="):
			return arg.trim_prefix("--rooms-url=").trim_suffix("/")
	return str(ProjectSettings.get_setting("dead_route/network/room_service", "")).trim_suffix("/")


func room_connecting() -> bool:
	return multiplayer.multiplayer_peer is RoomPeer \
		and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING


# ---------- Players in the world ----------

func player_nodes() -> Array:
	return get_tree().get_nodes_in_group(&"player")


## The handyman this machine controls.
func local_player() -> Node:
	for p in player_nodes():
		if is_local_authority(p):
			return p
	return null


## The car a player is driving, as seen from this machine.
func car_of(player: Node) -> Node2D:
	if player.current_car != null:
		return player.current_car
	if is_online():
		var id: int = player.get_multiplayer_authority()
		for c in get_tree().get_nodes_in_group(&"cars"):
			if c.driver_id == id:
				return c
	return null


## Closest living player to `pos` (their car if they're driving), or null.
func nearest_target(pos: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for p in player_nodes():
		if p.is_dead():
			continue
		var t: Node2D = car_of(p) if not p.visible else p
		if t == null:
			t = p
		var d := pos.distance_squared_to(t.global_position)
		if d < best_d:
			best_d = d
			best = t
	return best


# ---------- State replication ----------

## Adds a MultiplayerSynchronizer ("NetSync") to `node` (online only).
## `always`: sent every tick (positions); `on_change`: sent when they change.
## Paths are relative to `node`, e.g. ".:position", "AnimatedSprite2D:flip_h".
func attach_sync(node: Node, always: Array, on_change: Array, interval := 1.0 / 30.0) -> void:
	if not is_online() or node.has_node(^"NetSync"):
		return
	var cfg := SceneReplicationConfig.new()
	for p in always:
		cfg.add_property(NodePath(p))
		cfg.property_set_replication_mode(NodePath(p), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	for p in on_change:
		cfg.add_property(NodePath(p))
		cfg.property_set_replication_mode(NodePath(p), SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "NetSync"
	sync.replication_config = cfg
	sync.replication_interval = interval
	sync.delta_interval = interval
	# New children don't inherit authority; the owner of `node` must also own its sync.
	# Set it before the sync enters the tree (changing it later confuses pending spawns).
	sync.set_multiplayer_authority(node.get_multiplayer_authority())
	sync.root_path = NodePath("..")
	node.add_child(sync)


# ---------- Spawning shared actors ----------

## Registered by a Location in online matches; replicates its Entities children.
func register_spawner(spawner: MultiplayerSpawner) -> void:
	_spawner = spawner
	spawner.spawn_function = _spawn_from_data


## Creates an actor. Offline (or no spawner): plain instantiate + add_child.
## Online host: through the MultiplayerSpawner so every peer gets it.
func spawn(parent: Node, scene_path: String, props: Dictionary) -> Node:
	if is_online() and _spawner != null and is_instance_valid(_spawner):
		if not multiplayer.is_server():
			push_warning("Net.spawn called on a client; ignored (%s)" % scene_path)
			return null
		return _spawner.spawn({"scene": scene_path, "props": props})
	var n := _spawn_from_data({"scene": scene_path, "props": props})
	parent.add_child(n, true)
	return n


func _spawn_from_data(data: Dictionary) -> Node:
	var n: Node = load(data.scene).instantiate()
	for key in data.props:
		n.set(key, data.props[key])
	return n


# ---------- Lobby ----------

func create_room(public_room: bool, location: StringName) -> Error:
	leave()
	room_public = public_room
	settings = {"location": String(location), "rival": false, "mode": "coop", "pizza_enemy": "steal"}
	return _open_room("create=1&public=%d&name=%s&location=%s" % [
		int(public_room), my_name.uri_encode(), String(location).uri_encode()])


func join_room(code: String) -> Error:
	leave()
	return _open_room("code=" + code.uri_encode())


func _open_room(query: String) -> Error:
	var url := room_service_url()
	if url.is_empty():
		status_changed.emit("Online rooms are unavailable in this build.")
		return ERR_UNCONFIGURED
	url = url.replace("https://", "wss://").replace("http://", "ws://")
	var peer := RoomPeer.new()
	var err := peer.open(url + "/play?" + query)
	if err != OK:
		status_changed.emit("Couldn't reach the room service.")
		return err
	peer.failed.connect(func(reason: String) -> void: room_error = reason)
	peer.welcomed.connect(func(code: String) -> void:
		room_code = code
		if is_host():
			players = {1: {"name": my_name, "character": GameManager.selected_character,
				"team": 0, "ready": true}}
			status_changed.emit("Room is open. Share code %s with friends." % code)
		roster_changed.emit())
	multiplayer.multiplayer_peer = peer
	status_changed.emit("Connecting to the room service…")
	roster_changed.emit()
	return OK


## Direct connection is retained for local integration tests and tools.
func host(port := DEFAULT_PORT) -> Error:
	leave()
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		status_changed.emit("Couldn't host on port %d (%s)" % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	players = {1: {"name": my_name, "character": GameManager.selected_character, "team": 0, "ready": true}}
	status_changed.emit("Hosting on port %d. Share your IP with friends." % port)
	roster_changed.emit()
	return OK


func join(address: String, port := DEFAULT_PORT) -> Error:
	leave()
	address = address.strip_edges()
	if address.is_empty():
		status_changed.emit("Enter a room code or host address.")
		return ERR_INVALID_PARAMETER
	var peer := WebSocketMultiplayerPeer.new()
	# A full ws:// or wss:// link (e.g. a Cloudflare/ngrok tunnel) is used as-is.
	# https:// links from tunnel tools are accepted too and mapped to wss://.
	var url := address
	if address.begins_with("https://"):
		url = "wss://" + address.trim_prefix("https://")
	elif address.begins_with("http://"):
		url = "ws://" + address.trim_prefix("http://")
	elif not address.begins_with("ws"):
		url = "ws://%s:%d" % [address, port]
	var err := peer.create_client(url)
	if err != OK:
		status_changed.emit("Couldn't connect (%s)" % error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	status_changed.emit("Connecting to %s..." % url)
	return OK


func leave() -> void:
	if multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	room_code = ""
	room_public = false
	room_error = ""
	role = "crew"
	in_match = false
	_spawner = null
	_ready_peers.clear()
	_downed.clear()
	roster_changed.emit()


func set_setting(key: String, value: Variant) -> void:
	if not is_host():
		return
	settings[key] = value
	var room_peer := multiplayer.multiplayer_peer as RoomPeer
	if room_peer:
		room_peer.advertise(settings)
	_rpc_roster.rpc(players, settings)
	roster_changed.emit()


func _on_peer_connected(_id: int) -> void:
	pass  # wait for the client to register its name


func _on_peer_disconnected(id: int) -> void:
	if is_host() and in_match:
		MatchState.on_peer_left(id)
	players.erase(id)
	_ready_peers.erase(id)
	_downed.erase(id)
	if is_host():
		_rpc_roster.rpc(players, settings)
		var scene := get_tree().current_scene
		var p: Node = scene.find_child("Player_%d" % id, true, false) if scene else null
		if p:
			p.queue_free()
		announce("%s left." % peer_name(id))
		_check_all_down()
	roster_changed.emit()


func _on_connected() -> void:
	_rpc_register.rpc_id(1, my_name, GameManager.selected_character)


func _on_connection_failed() -> void:
	var reason := room_error
	leave()
	status_changed.emit(reason if not reason.is_empty() else "Could not connect to the room service. Try again.")


func _on_server_disconnected() -> void:
	var was_in_match := in_match
	leave()
	status_changed.emit("Host disconnected.")
	if was_in_match:
		GameManager.goto_garage()


@rpc("any_peer", "reliable")
func _rpc_register(player_name: String, character: StringName) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if players.size() >= MAX_PLAYERS or in_match:
		multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	players[id] = {"name": player_name.strip_edges().left(16),
		"character": character if GameManager.PLAYABLE_CHARACTERS.has(character) else GameManager.DEFAULT_CHARACTER,
		"team": _smaller_team(), "ready": false}
	_rpc_roster.rpc(players, settings)
	roster_changed.emit()


# ---------- Teams + ready (lobby) ----------

func _smaller_team() -> int:
	var counts := [0, 0]
	for id in players:
		counts[clampi(int(players[id].get("team", 0)), 0, 1)] += 1
	return 0 if counts[0] <= counts[1] else 1


## Pick a TDM team (0 red / 1 blue).
func set_team(team: int) -> void:
	if not is_online() or in_match:
		return
	if is_host():
		_set_peer_field(1, "team", clampi(team, 0, 1))
	else:
		_rpc_set_team.rpc_id(1, team)


@rpc("any_peer", "reliable")
func _rpc_set_team(team: int) -> void:
	if is_host():
		_set_peer_field(multiplayer.get_remote_sender_id(), "team", clampi(team, 0, 1))


func set_ready(on: bool) -> void:
	if not is_online() or in_match:
		return
	if is_host():
		return  # the host is always ready: they press START
	_rpc_set_ready.rpc_id(1, on)


@rpc("any_peer", "reliable")
func _rpc_set_ready(on: bool) -> void:
	if is_host():
		_set_peer_field(multiplayer.get_remote_sender_id(), "ready", on)


## Host: split everyone evenly across the two teams.
func auto_balance() -> void:
	if not is_host() or in_match:
		return
	var ids := players.keys()
	ids.shuffle()
	for i in ids.size():
		players[ids[i]].team = i % 2
	_rpc_roster.rpc(players, settings)
	roster_changed.emit()


func _set_peer_field(id: int, key: String, value: Variant) -> void:
	if in_match or not players.has(id):
		return
	players[id][key] = value
	_rpc_roster.rpc(players, settings)
	roster_changed.emit()


func set_character(character: StringName) -> void:
	if not is_online() or in_match:
		return
	if is_host():
		_set_peer_character(1, character)
	else:
		_rpc_set_character.rpc_id(1, character)


@rpc("any_peer", "reliable")
func _rpc_set_character(character: StringName) -> void:
	if is_host():
		_set_peer_character(multiplayer.get_remote_sender_id(), character)


func _set_peer_character(id: int, character: StringName) -> void:
	if in_match or not players.has(id) or not GameManager.PLAYABLE_CHARACTERS.has(character):
		return
	players[id].character = character
	_rpc_roster.rpc(players, settings)
	roster_changed.emit()


@rpc("authority", "reliable")
func _rpc_roster(new_players: Dictionary, new_settings: Dictionary) -> void:
	players = new_players
	settings = new_settings
	status_changed.emit("Connected. Waiting for the host to start.")
	roster_changed.emit()


# ---------- Match flow ----------

func start_match() -> void:
	if not is_host():
		return
	if is_versus() and not all_ready():
		status_changed.emit("Waiting for everyone to press READY.")
		return
	_ready_peers.clear()
	_downed.clear()
	_rival_exposed = false
	_rival_id = 0
	multiplayer.multiplayer_peer.refuse_new_connections = true
	if settings.rival and players.size() >= 2 and not is_versus():
		_rival_id = players.keys().pick_random()
	for id in players:
		var r := "rival" if id == _rival_id else "crew"
		if id == 1:
			role = r
		else:
			_rpc_role.rpc_id(id, r)
	_rpc_start.rpc(settings.location)
	_begin(settings.location)


@rpc("authority", "reliable")
func _rpc_role(r: String) -> void:
	role = r


@rpc("authority", "reliable")
func _rpc_start(location: String) -> void:
	_begin(location)


func _begin(location: String) -> void:
	in_match = true
	GameManager.selected_location = StringName(location)
	GameManager.launch_run()


## Called by a Location once its static world is built.
func scene_ready() -> void:
	if not is_online():
		return
	if multiplayer.is_server():
		_mark_ready(1)
	else:
		_rpc_peer_ready.rpc_id(1)


@rpc("any_peer", "reliable")
func _rpc_peer_ready() -> void:
	_mark_ready(multiplayer.get_remote_sender_id())


func _mark_ready(id: int) -> void:
	_ready_peers[id] = true
	if players.keys().all(func(p: int) -> bool: return _ready_peers.has(p)):
		all_peers_ready.emit()


# ---------- Noise: clients report to the host's NoiseDirector ----------

func _on_local_noise(amount: float, pos: Vector2) -> void:
	if not is_online() or multiplayer.is_server():
		return  # the host's own noise goes straight to its NoiseDirector
	_noise_sum += amount
	_noise_pos = pos


@rpc("any_peer", "unreliable_ordered")
func _rpc_noise(amount: float, pos: Vector2) -> void:
	if not multiplayer.is_server():
		return
	EventBus.noise_increased.emit(amount, pos)


## Sound events (zombie hearing): clients batch theirs to the host.
func _on_local_sound(pos: Vector2, radius: float) -> void:
	if not is_online() or multiplayer.is_server() or radius <= 0.0:
		return
	if _sounds.size() < 32:
		_sounds.append(Vector3(pos.x, pos.y, radius))


@rpc("any_peer", "unreliable_ordered")
func _rpc_sounds(list: Array) -> void:
	if not multiplayer.is_server():
		return
	for v in list:
		if v is Vector3:
			EventBus.sound_made.emit(Vector2(v.x, v.y), minf(v.z, 1000.0))


## Host -> clients: meter level for the HUD.
func broadcast_noise(level: float, tier: int) -> void:
	if is_host():
		_rpc_noise_level.rpc(level, tier)


@rpc("authority", "unreliable_ordered")
func _rpc_noise_level(level: float, tier: int) -> void:
	var d := get_tree().get_first_node_in_group(&"noise_director")
	if d:
		var rising: bool = tier > d.tier
		d.level = level
		d.tier = tier
		if rising:
			EventBus.noise_threshold_reached.emit(tier)
	EventBus.noise_level_changed.emit(level, 100.0)


# ---------- Messages, pickups ----------

## Shows a HUD banner on every machine.
func announce(text: String) -> void:
	if is_online():
		_rpc_announce.rpc(text)
	else:
		EventBus.hud_message.emit(text)


@rpc("any_peer", "call_local", "reliable")
func _rpc_announce(text: String) -> void:
	EventBus.hud_message.emit(text)


## Host -> the peer whose handyman picked something up.
func grant(peer: int, kind: int, amount: int) -> void:
	if peer == local_id():
		_apply_grant(kind, amount)
	else:
		_rpc_grant.rpc_id(peer, kind, amount)


@rpc("authority", "reliable")
func _rpc_grant(kind: int, amount: int) -> void:
	_apply_grant(kind, amount)


func _apply_grant(kind: int, amount: int) -> void:
	var p := local_player()
	if p:
		Pickup.apply_to(p, kind, amount)


# ---------- Downed / run end ----------

func report_down(is_down: bool) -> void:
	if not is_online():
		return
	if multiplayer.is_server():
		_set_down(1, is_down)
	else:
		_rpc_down.rpc_id(1, is_down)


@rpc("any_peer", "reliable")
func _rpc_down(is_down: bool) -> void:
	_set_down(multiplayer.get_remote_sender_id(), is_down)


func _set_down(id: int, is_down: bool) -> void:
	if is_down:
		_downed[id] = true
		announce("%s is DOWN! Hold E on them to revive." % peer_name(id))
	else:
		_downed.erase(id)
	_check_all_down()


func _check_all_down() -> void:
	if not is_host() or not in_match or players.is_empty() or is_versus():
		return
	if players.keys().all(func(p: int) -> bool: return _downed.has(p)):
		get_tree().create_timer(2.0).timeout.connect(func() -> void: end_run(false))


func report_rival_exposed(reason: String) -> void:
	if multiplayer.is_server():
		_rival_exposed_on_host(local_id(), reason)
	else:
		_rpc_rival_exposed.rpc_id(1, reason)


@rpc("any_peer", "reliable")
func _rpc_rival_exposed(reason: String) -> void:
	_rival_exposed_on_host(multiplayer.get_remote_sender_id(), reason)


func _rival_exposed_on_host(id: int, reason: String) -> void:
	if _rival_exposed or id != _rival_id:
		return
	_rival_exposed = true
	announce("%s %s! They're the RIVAL!" % [peer_name(id), reason])


## Host only: ends a versus match for everyone. Each machine works out win/lose itself.
func end_versus(info: Dictionary) -> void:
	if not is_host() or not in_match:
		return
	in_match = false
	info["versus"] = true
	_rpc_end_run.rpc(false, info)
	_finish_local(false, info)


## Host only: ends the run for everyone.
func end_run(success: bool) -> void:
	if not is_host() or not in_match:
		return
	in_match = false
	var info := {"rival_id": _rival_id, "rival_name": peer_name(_rival_id) if _rival_id else "",
		"exposed": _rival_exposed}
	_rpc_end_run.rpc(success, info)
	_finish_local(success, info)


@rpc("authority", "reliable")
func _rpc_end_run(success: bool, info: Dictionary) -> void:
	in_match = false
	_finish_local(success, info)


func _finish_local(success: bool, info: Dictionary) -> void:
	var loc := get_tree().current_scene as Location
	if loc:
		loc.finish_networked(success, info)
