extends Node
## Versus referee: Team Deathmatch ("tdm") and Free For All ("ffa").
##
## Server-authoritative. The host decides spawns, validates knife hits, counts kills,
## jobs and deliveries, spawns each team's pizza, runs the clock and picks the winner.
## Clients send requests (knife hits, deaths) and receive state (_rpc_state).
## Teams: TDM 0 = RED, 1 = BLUE. FFA: every player is their own team (team id = peer id).
## All tunable numbers live in MatchConfig (res://resources/match_config.tres).

signal state_changed
signal kill_feed(text: String, color: Color)

const TEAM_NAMES := ["RED", "BLUE"]
const TEAM_COLORS := [Color(0.95, 0.35, 0.3), Color(0.35, 0.6, 1.0)]
const FFA_COLORS := [Color(0.95, 0.35, 0.3), Color(0.35, 0.6, 1.0), Color(0.4, 0.9, 0.4), Color(1.0, 0.8, 0.3)]
const CUSTOMER_SCENE := "res://scenes/locations/delivery_customer.tscn"
const PIZZA_SCENE := "res://scenes/pickups/pizza_cargo.tscn"
const CAR_SCENE := "res://scenes/car/car.tscn"
const SYNC_INTERVAL := 0.5
## Seconds after a hit during which a death still counts as a kill for the attacker.
const KILL_CREDIT_TIME := 6.0

var cfg: MatchConfig
var active := false
var mode := "tdm"
var location: Location
var teams := {}        # peer id -> team id
var objectives := {}   # team id -> {"jobs": Array[String], "kills": int, "pizza": bool, "pk": int}
var time_left := 0.0
var pizza_eta := {}    # team id -> seconds until it spawns (<= 0: spawned)
var anchors := {}      # team id -> spawn anchor (world position)
var winner := -2       # -2 running, -1 draw, else team id

var _respawns := {}         # host: peer id -> seconds left
var _last_hit := {}         # host: victim peer -> [attacker peer, msec]
var _knife_ready_at := {}   # host: attacker peer -> msec
var _pizza_warned := {}     # host: team -> last warning bucket
var _sync_cd := 0.0
var _spread: Array[Vector2] = []  # host: walkable candidates (FFA spawns + respawns)


func _ready() -> void:
	cfg = MatchConfig.get_config()


# ---------- Lifecycle ----------

## Every machine, from Location._ready, when the lobby picked TDM or FFA.
func begin(loc: Location) -> void:
	location = loc
	active = true
	mode = Net.settings.get("mode", "tdm")
	winner = -2
	teams.clear()
	for id in Net.players:
		teams[id] = Net.peer_team(id)
	objectives.clear()
	pizza_eta.clear()
	for t in team_ids():
		objectives[t] = _blank()
		pizza_eta[t] = randf_range(cfg.pizza_delay_min, cfg.pizza_delay_max)
	time_left = cfg.match_time
	_respawns.clear()
	_last_hit.clear()
	_knife_ready_at.clear()
	_pizza_warned.clear()
	_refresh_hud.call_deferred()


func end() -> void:
	active = false
	location = null
	anchors.clear()
	_spread.clear()


func _blank() -> Dictionary:
	return {"jobs": [], "kills": 0, "pizza": false, "pk": 0}


## Host, once every peer has loaded the room: spawn points, drop-offs, pizzas, cars.
func host_setup() -> void:
	# The navmesh was just baked; give the navigation server a couple of frames to sync.
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not active or location == null:
		return
	var rect := location.map_rect()
	_spread = _candidates(rect, 80.0)
	var ids := team_ids()
	if mode == "tdm":
		var mid := rect.get_center().y
		anchors[0] = _walkable_near(Vector2(rect.position.x + rect.size.x * 0.1, mid))
		anchors[1] = _walkable_near(Vector2(rect.end.x - rect.size.x * 0.1, mid))
	else:
		var pts := _spread_points(ids.size())
		for i in ids.size():
			anchors[ids[i]] = pts[i]
	var car_used := false
	for t in ids:
		var a: Vector2 = anchors[t]
		var toward := a.direction_to(rect.get_center())
		var drop := _walkable_near(a + toward * 70.0, 14.0)
		Net.spawn(location.entities, CUSTOMER_SCENE, {"name": "Dropoff_%d" % t, "team": t, "position": drop})
		Net.spawn(location.entities, PIZZA_SCENE, {"name": "Pizza_%d" % t, "team": t, "position": drop})
		var car_pos := _walkable_near(a + toward.orthogonal() * 70.0, 22.0)
		if not car_used:
			car_used = true
			location.start_car.global_position = car_pos
			location.start_car.rotation = 0.0
		else:
			Net.spawn(location.entities, CAR_SCENE, {"name": "TeamCar_%d" % t, "position": car_pos,
				"start_hp_ratio": 1.0, "start_fuel_ratio": 0.8})
	_rpc_anchors.rpc(anchors)
	_broadcast()


@rpc("authority", "reliable")
func _rpc_anchors(a: Dictionary) -> void:
	anchors = a


## Host: where `peer` starts the match.
func spawn_point(peer: int) -> Vector2:
	var t := team_of(peer)
	var mates := teams.keys().filter(func(id: int) -> bool: return teams[id] == t)
	mates.sort()
	var i := maxi(mates.find(peer), 0)
	var a: Vector2 = anchors.get(t, location.player.position)
	return _walkable_near(a + Vector2(0, (i - (mates.size() - 1) * 0.5) * 28.0))


# ---------- Teams ----------

func team_ids() -> Array:
	var out := []
	for id in teams:
		if not teams[id] in out:
			out.append(teams[id])
	if mode == "tdm":
		for t in [0, 1]:
			if not t in out:
				out.append(t)
	out.sort()
	return out


func team_of(peer: int) -> int:
	return int(teams.get(peer, Net.peer_team(peer)))


func local_team() -> int:
	return team_of(Net.local_id())


func are_enemies(a: int, b: int) -> bool:
	return active and a != b and team_of(a) != team_of(b)


func team_name(t: int) -> String:
	if mode == "tdm":
		return TEAM_NAMES[clampi(t, 0, 1)]
	return Net.peer_name(t)


func team_color(t: int) -> Color:
	if mode == "tdm":
		return TEAM_COLORS[clampi(t, 0, 1)]
	var ids := team_ids()
	return FFA_COLORS[maxi(ids.find(t), 0) % FFA_COLORS.size()]


func player_of(peer: int) -> Player:
	for p in Net.player_nodes():
		if p.get_multiplayer_authority() == peer:
			return p
	return null


func pizza_of(t: int) -> Node:
	return location.entities.get_node_or_null("Pizza_%d" % t) if location else null


func dropoff_of(t: int) -> Node:
	return location.entities.get_node_or_null("Dropoff_%d" % t) if location else null


# ---------- Knife fights (host validates) ----------

## Attacker's machine: its knife connected with `target` (a Player).
func request_knife_hit(target: Player, aim: Vector2) -> void:
	var victim := target.get_multiplayer_authority()
	if Net.is_host():
		_validate_hit(Net.local_id(), victim, aim)
	else:
		_rpc_knife_hit.rpc_id(1, victim, aim)


@rpc("any_peer", "reliable")
func _rpc_knife_hit(victim: int, aim: Vector2) -> void:
	if Net.is_host():
		_validate_hit(multiplayer.get_remote_sender_id(), victim, aim)


func _validate_hit(attacker: int, victim: int, aim: Vector2) -> void:
	if not active or winner != -2 or not are_enemies(attacker, victim):
		return
	var a := player_of(attacker)
	var v := player_of(victim)
	if a == null or v == null or a.is_dead() or v.is_dead() or not a.visible or not v.visible:
		return
	if a.global_position.distance_to(v.global_position) > cfg.knife_reach + cfg.knife_validate_slack:
		return
	var now := Time.get_ticks_msec()
	if now < int(_knife_ready_at.get(attacker, 0)):
		return
	_knife_ready_at[attacker] = now + int(cfg.knife_cooldown * 800.0)  # 20% lag tolerance
	_last_hit[victim] = [attacker, now]
	var kb := aim.normalized() * cfg.knife_knockback
	v.receive_pvp_hit(cfg.knife_pvp_damage, kb, attacker)
	EventBus.sound_made.emit(v.global_position, cfg.sound_fight)
	EventBus.noise_increased.emit(3.0, v.global_position)
	_rpc_hit_fx.rpc(v.global_position + Vector2(0, -12), kb)
	_hit_fx(v.global_position + Vector2(0, -12), kb)


@rpc("authority", "unreliable")
func _rpc_hit_fx(pos: Vector2, kb: Vector2) -> void:
	_hit_fx(pos, kb)


func _hit_fx(pos: Vector2, kb: Vector2) -> void:
	Fx.blood(pos, kb, 8)
	Sfx.play(&"knife_hit", pos)


# ---------- Deaths + respawns ----------

## The local player just died (DeadState). Tell the host.
func report_local_death() -> void:
	if Net.is_host():
		_on_death(Net.local_id())
	else:
		_rpc_died.rpc_id(1)


@rpc("any_peer", "reliable")
func _rpc_died() -> void:
	if Net.is_host():
		_on_death(multiplayer.get_remote_sender_id())


func _on_death(victim: int) -> void:
	if not active or _respawns.has(victim):
		return
	var killer := 0
	var hit: Array = _last_hit.get(victim, [])
	if not hit.is_empty() and Time.get_ticks_msec() - int(hit[1]) < KILL_CREDIT_TIME * 1000.0:
		killer = int(hit[0])
	_last_hit.erase(victim)
	var text := ""
	var color := Color(0.85, 0.85, 0.85)
	if killer != 0 and killer != victim:
		var kt := team_of(killer)
		objectives[kt].pk += 1
		text = "%s  [knife]  %s" % [Net.peer_name(killer), Net.peer_name(victim)]
		color = team_color(kt)
	else:
		text = "%s was eaten" % Net.peer_name(victim)
	_rpc_feed.rpc(text, color)
	_rpc_feed_local(text, color)
	_respawns[victim] = cfg.respawn_time
	_broadcast()


@rpc("authority", "reliable")
func _rpc_feed(text: String, color: Color) -> void:
	_rpc_feed_local(text, color)


func _rpc_feed_local(text: String, color: Color) -> void:
	kill_feed.emit(text, color)


func _respawn(peer: int) -> void:
	var p := player_of(peer)
	if p == null:
		return
	var pos := _respawn_point(peer)
	if peer == Net.local_id():
		p.respawn_at(pos, cfg.spawn_protection)
	else:
		p._rpc_respawn.rpc_id(peer, pos, cfg.spawn_protection)


func _respawn_point(peer: int) -> Vector2:
	var t := team_of(peer)
	if mode == "tdm" or _spread.is_empty():
		return spawn_point(peer)
	# FFA: the spot farthest from every living enemy.
	var best: Vector2 = anchors.get(t, _spread[0])
	var best_d := -1.0
	for c in _spread:
		var d := INF
		for p in Net.player_nodes():
			var id: int = p.get_multiplayer_authority()
			if id != peer and not p.is_dead():
				d = minf(d, c.distance_to(p.global_position))
		if d > best_d:
			best_d = d
			best = c
	return best


# ---------- Objectives ----------

## Host: a zombie died; `peer` hit it last (0 = nobody / environment).
func on_zombie_killed(peer: int) -> void:
	if not active or winner != -2 or peer == 0 or not teams.has(peer):
		return
	objectives[team_of(peer)].kills += 1
	_check_win()
	_broadcast()


## Host: team `t` finished the job named `job`.
func on_job_done(job: String, t: int) -> void:
	if not active or winner != -2 or has_job(t, job):
		return
	objectives[t].jobs.append(job)
	_rpc_feed.rpc("%s fixed: %s" % [team_name(t), job], team_color(t))
	_rpc_feed_local("%s fixed: %s" % [team_name(t), job], team_color(t))
	_check_win()
	_broadcast()


func has_job(t: int, job: String) -> bool:
	return objectives.has(t) and job in objectives[t].jobs


## Host: team `t` delivered its pizza.
func on_pizza_delivered(t: int) -> void:
	if not active or winner != -2 or not objectives.has(t):
		return
	objectives[t].pizza = true
	Net.announce("%s delivered their pizza!" % team_name(t))
	_check_win()
	_broadcast()


func jobs_needed() -> int:
	return mini(cfg.jobs_required, location.tasks.size()) if location else cfg.jobs_required


func team_done(t: int) -> bool:
	var o: Dictionary = objectives[t]
	return o.jobs.size() >= jobs_needed() and o.kills >= cfg.zombie_kill_target and o.pizza


func score(t: int) -> int:
	var o: Dictionary = objectives.get(t, _blank())
	return o.jobs.size() * cfg.score_job + o.kills * cfg.score_zombie \
		+ (cfg.score_pizza if o.pizza else 0) + o.pk * cfg.score_player_kill


func _check_win() -> void:
	for t in team_ids():
		if objectives.has(t) and team_done(t):
			_finish(t, "%s completed every objective!" % team_name(t))
			return


func _finish(t: int, reason: String) -> void:
	if winner != -2:
		return
	winner = t
	_broadcast()
	var board: Array[String] = []
	var ids := team_ids()
	ids.sort_custom(func(a: int, b: int) -> bool: return score(a) > score(b))
	for id in ids:
		var o: Dictionary = objectives[id]
		board.append("%s  %d pts   jobs %d · zombies %d · pizza %s · kills %d" % [team_name(id), score(id),
			o.jobs.size(), o.kills, "yes" if o.pizza else "no", o.pk])
	Net.end_versus({"winner": t, "winner_name": team_name(t) if t >= 0 else "", "reason": reason,
		"board": "\n".join(board), "mode": mode})


# ---------- Clock, pizzas, respawns (host) ----------

func _physics_process(delta: float) -> void:
	if not active or location == null or not Net.is_sim_authority() or winner != -2 \
			or get_tree().paused:
		return
	time_left -= delta
	if time_left <= 0.0:
		var ids := team_ids()
		ids.sort_custom(func(a: int, b: int) -> bool: return score(a) > score(b))
		var tie := ids.size() > 1 and score(ids[0]) == score(ids[1])
		_finish(-1 if tie else ids[0], "Time's up!")
		return
	for peer in _respawns.keys():
		_respawns[peer] -= delta
		if _respawns[peer] <= 0.0:
			_respawns.erase(peer)
			_respawn(peer)
	if not anchors.is_empty():
		for t in pizza_eta:
			if pizza_eta[t] <= 0.0:
				continue
			pizza_eta[t] -= delta
			_warn_pizza(t)
			if pizza_eta[t] <= 0.0:
				spawn_pizza(t)
	_sync_cd -= delta
	if _sync_cd <= 0.0:
		_broadcast()


func _warn_pizza(t: int) -> void:
	var left: float = pizza_eta[t]
	for mark in [30, 10]:
		if left <= mark and int(_pizza_warned.get(t, 999)) > mark:
			_pizza_warned[t] = mark
			Net.announce("%s pizza incoming in %ds!" % [team_name(t), mark])


## Host: drops team `t`'s pizza at a fresh valid spot (start of match, or "reset").
func spawn_pizza(t: int) -> void:
	var pizza := pizza_of(t)
	if pizza == null:
		return
	pizza_eta[t] = 0.0
	pizza.place(find_pizza_spot(t))
	Net.announce("%s pizza has landed somewhere. Find it!" % team_name(t))
	_broadcast()


## A reachable spot far from every member of team `t` (see MatchConfig: Pizza).
func find_pizza_spot(t: int) -> Vector2:
	var owners: Array[Vector2] = []
	for p in Net.player_nodes():
		if team_of(p.get_multiplayer_authority()) == t:
			owners.append(p.global_position)
	var from: Vector2 = anchors.get(t, location.player.global_position)
	if owners.is_empty():
		owners.append(from)
	var cands: Array[Vector2] = []
	var markers := location._pizza_spawn_spots().duplicate()
	markers.shuffle()
	cands.append_array(markers)
	var rect := location.map_rect().grow(-48.0)
	for i in 300:
		cands.append(Vector2(randf_range(rect.position.x, rect.end.x), randf_range(rect.position.y, rect.end.y)))
	var min_d := cfg.pizza_min_owner_distance
	for attempt in 4:
		for c in cands:
			if is_pizza_spot_ok(c, owners, from, min_d):
				return c
		min_d *= 0.8  # small map: relax a little and try again
	# Last resort: the reachable candidate farthest from the owners.
	var best := from
	var best_d := -1.0
	for c in cands:
		if not is_walkable(c, 10.0) or not reachable(from, c):
			continue
		var d := INF
		for o in owners:
			d = minf(d, c.distance_to(o))
		if d > best_d:
			best_d = d
			best = c
	return best


func is_pizza_spot_ok(c: Vector2, owners: Array[Vector2], from: Vector2, min_d: float) -> bool:
	for o in owners:
		if c.distance_to(o) < min_d:
			return false
	return is_walkable(c, 10.0) and reachable(from, c)


# ---------- Walkable ground ----------

func _nav_map() -> RID:
	return location.nav_region.get_navigation_map()


## On the navmesh and not overlapping walls, props, barrels or jobs.
func is_walkable(p: Vector2, radius := 10.0) -> bool:
	if location == null or not location.map_rect().grow(-24.0).has_point(p):
		return false
	for pool in get_tree().get_nodes_in_group(&"acid_pool"):
		if pool.contains(p, radius):
			return false
	var q := NavigationServer2D.map_get_closest_point(_nav_map(), p)
	if q.distance_to(p) > 4.0:
		return false
	var shape := CircleShape2D.new()
	shape.radius = radius
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape
	params.transform = Transform2D(0.0, p)
	params.collision_mask = 1 | 128
	return location.get_world_2d().direct_space_state.intersect_shape(params, 1).is_empty()


## A navmesh path from `from` actually ends at `to`.
func reachable(from: Vector2, to: Vector2) -> bool:
	var start := NavigationServer2D.map_get_closest_point(_nav_map(), from)
	var path := NavigationServer2D.map_get_path(_nav_map(), start, to, true)
	return path.size() > 0 and path[path.size() - 1].distance_to(to) < 12.0


## Nearest walkable spot to `p` (spiral search).
func _walkable_near(p: Vector2, radius := 10.0) -> Vector2:
	if is_walkable(p, radius):
		return p
	for ring in range(1, 30):
		var r := ring * 20.0
		var steps := 8 + ring * 4
		for i in steps:
			var c := p + Vector2.from_angle(TAU * i / steps) * r
			if is_walkable(c, radius):
				return c
	return p


func _candidates(rect: Rect2, step: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var center := _walkable_near(rect.get_center())
	var y := rect.position.y + step * 0.5
	while y < rect.end.y:
		var x := rect.position.x + step * 0.5
		while x < rect.end.x:
			var c := Vector2(x, y)
			if is_walkable(c, 12.0) and reachable(center, c):
				out.append(c)
			x += step
		y += step
	return out


## FFA: n spots spread as far apart as possible (farthest-point sampling).
func _spread_points(n: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if _spread.is_empty():
		for i in n:
			out.append(location.player.position + Vector2(40 * i, 0))
		return out
	out.append(_spread.pick_random())
	while out.size() < n:
		var best := _spread[0]
		var best_d := -1.0
		for c in _spread:
			var d := INF
			for o in out:
				d = minf(d, c.distance_to(o))
			if d > best_d:
				best_d = d
				best = c
		out.append(best)
	return out


# ---------- Disconnects ----------

## Host, before the peer is removed from Net.players.
func on_peer_left(id: int) -> void:
	if not active:
		return
	var t := team_of(id)
	teams.erase(id)
	_respawns.erase(id)
	_last_hit.erase(id)
	if mode == "ffa":
		objectives.erase(t)
		pizza_eta.erase(t)
		for n in [pizza_of(t), dropoff_of(t)]:
			if n:
				n.queue_free()
	elif mode == "tdm":
		_rebalance.call_deferred()
	_broadcast.call_deferred()


func _rebalance() -> void:
	var members := {0: [], 1: []}
	for id in teams:
		members[teams[id]].append(id)
	var big := 0 if members[0].size() > members[1].size() else 1
	if members[big].size() - members[1 - big].size() < 2:
		return
	var moved: int = members[big].back()
	teams[moved] = 1 - big
	if Net.players.has(moved):
		Net.players[moved].team = 1 - big
	Net.announce("%s moved to %s to even the teams." % [Net.peer_name(moved), team_name(1 - big)])
	_broadcast()
	_respawn(moved)


# ---------- State sync + HUD ----------

func _broadcast() -> void:
	_sync_cd = SYNC_INTERVAL
	if Net.is_host():
		_rpc_state.rpc(teams, objectives, time_left, pizza_eta, winner)
	_refresh_hud()


@rpc("authority", "unreliable_ordered")
func _rpc_state(t: Dictionary, o: Dictionary, left: float, eta: Dictionary, w: int) -> void:
	if not active:
		return
	teams = t
	objectives = o
	time_left = left
	pizza_eta = eta
	winner = w
	_refresh_hud()


func _process(delta: float) -> void:
	if active and not Net.is_sim_authority() and winner == -2:
		time_left = maxf(time_left - delta, 0.0)  # smooth clock between syncs


func _refresh_hud() -> void:
	if not active:
		return
	var t := local_team()
	var o: Dictionary = objectives.get(t, _blank())
	var lines: Array[String] = []
	var clock := "%d:%02d" % [int(time_left) / 60, int(time_left) % 60]
	lines.append("%s  ·  %s  ·  %s" % ["TEAM DEATHMATCH" if mode == "tdm" else "FREE FOR ALL",
		team_name(t) if mode == "tdm" else "YOU", clock])
	lines.append("%s Jobs %d/%d" % [_box(o.jobs.size() >= jobs_needed()), o.jobs.size(), jobs_needed()])
	lines.append("%s Zombies %d/%d" % [_box(o.kills >= cfg.zombie_kill_target), mini(o.kills, cfg.zombie_kill_target),
		cfg.zombie_kill_target])
	lines.append("%s Pizza: %s" % [_box(o.pizza), pizza_status(t)])
	var scores: Array[String] = []
	for id in team_ids():
		scores.append("%s %d" % [team_name(id), score(id)])
	lines.append(" · ".join(scores))
	EventBus.objective_changed.emit("\n".join(lines))
	EventBus.pizza_status_changed.emit("Pizza: " + pizza_status(t))
	state_changed.emit()


func pizza_status(t: int) -> String:
	var o: Dictionary = objectives.get(t, _blank())
	if o.pizza:
		return "delivered"
	var eta: float = pizza_eta.get(t, 0.0)
	if eta > 0.0:
		return "incoming %d:%02d" % [int(eta) / 60, int(eta) % 60]
	var pizza := pizza_of(t)
	if pizza and pizza.carrier_id != 0:
		return "carried by %s" % Net.peer_name(pizza.carrier_id)
	return "find it!"


func _box(done: bool) -> String:
	return "[x]" if done else "[ ]"
