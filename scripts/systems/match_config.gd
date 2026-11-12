class_name MatchConfig
extends Resource
## Every tunable number for versus matches, voice chat and zombie senses.
## Edit res://resources/match_config.tres in the Inspector (or this file's defaults).

@export_group("Match")
## Match length in seconds. When it runs out, the highest score wins.
@export var match_time := 900.0
## Zombies a team must kill (TDM) / a player must kill (FFA).
@export var zombie_kill_target := 15
## How many different jobs a team must complete (capped at the jobs in the room).
@export var jobs_required := 2
@export var respawn_time := 4.0
## Seconds of spawn protection after (re)spawning.
@export var spawn_protection := 2.0
## Score (used when the timer ends): per job, per zombie, per pizza, per player kill.
@export var score_job := 100
@export var score_zombie := 5
@export var score_pizza := 300
@export var score_player_kill := 25
## Zombie waves in versus are this much gentler than co-op.
@export_range(0.1, 2.0) var versus_wave_mult := 0.7

@export_group("Melee (knife)")
@export var knife_pvp_damage := 25.0
@export var knife_knockback := 150.0
@export var knife_cooldown := 0.42
@export var knife_reach := 42.0
## Extra reach the server tolerates when validating a hit (lag).
@export var knife_validate_slack := 36.0
## Seconds to swap between gun and knife (can't attack meanwhile).
@export var weapon_switch_time := 0.3

@export_group("Pizza")
## Seconds after the match starts before each team's pizza appears (random in range).
@export var pizza_delay_min := 120.0
@export var pizza_delay_max := 180.0
## The pizza never spawns closer than this to any member of the owning team.
@export var pizza_min_owner_distance := 700.0
## Enemies only see someone else's pizza within this distance.
@export var pizza_enemy_reveal_distance := 160.0
## "steal": enemies can carry it off (but never deliver it).
## "reset": an enemy touching it sends it to a new random spot.
@export_enum("steal", "reset") var pizza_enemy_action := "steal"

@export_group("Voice chat")
## Beyond this distance you can't hear someone at all.
@export var voice_max_distance := 650.0
## Higher = drops off faster with distance.
@export var voice_attenuation := 1.4
## Mic level (0..1) that counts as talking in open-mic mode.
@export var voice_open_mic_threshold := 0.02
## Network sample rate (lower = less bandwidth).
@export var voice_sample_rate := 12000

@export_group("Zombie senses")
@export var sight_range := 230.0
@export var sight_angle_deg := 110.0
## Zombies notice you this close even outside their view cone (still needs line of sight).
@export var sight_close_range := 40.0
## Seconds a zombie looks around after reaching a noise / last-seen spot.
@export var search_time := 4.0
## Hearing radius (px) of each sound. A zombie hears it if it's inside the radius.
@export var sound_gunshot := 420.0
@export var sound_shotgun := 500.0
@export var sound_knife := 70.0
@export var sound_fight := 160.0
@export var sound_sprint := 150.0
@export var sound_walk := 55.0
@export var sound_crouch := 0.0
@export var sound_engine := 230.0
@export var sound_horn := 650.0
@export var sound_crash := 380.0
@export var sound_explosion := 750.0
@export var sound_job := 220.0


static var _cached: MatchConfig


static func get_config() -> MatchConfig:
	if _cached == null:
		_cached = load("res://resources/match_config.tres")
		if _cached == null:
			_cached = MatchConfig.new()
	return _cached
