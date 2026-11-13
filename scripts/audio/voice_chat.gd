extends Node
## Proximity voice chat (online matches).
##
## Browser capture reports its actual AudioContext rate. Native capture uses the muted VoiceMic bus.
## Both are resampled to MatchConfig.voice_sample_rate, mu-law packed to 8 bits and sent in
## ~60 ms chunks (unreliable RPC; the host relays to everyone else).
## Each remote player gets an AudioStreamPlayer2D ("Voice") on their handyman fed by an
## AudioStreamGenerator, so voices fade with distance and pan left/right around your
## own handyman (the AudioListener2D on the local player). Teammates and enemies alike.
##
## The host enables proximity voice for the room; each player opts in from Pause.

signal microphone_changed

var mic_enabled := false
var mic_status := "Off · Enable to talk to players nearby."
var _web_frames: JavaScriptObject
var _web_status: JavaScriptObject

const MIC_BUS := "VoiceMic"
const OUT_BUS := "Voice"
const CHUNK_SEC := 0.06
const MAX_PACKET := 4096
const MU := 255.0
## Seconds open mic keeps sending after the level drops (so words don't get clipped).
const HANGOVER := 0.4

var cfg: MatchConfig
var talking := false
var level := 0.0
## Stats (tests, debug overlay).
var packets_sent := 0
var frames_received := {}  # peer id -> mono samples received

var _capture: AudioEffectCapture
var _mic_player: AudioStreamPlayer
var _mic_on := false
var _send_buf := PackedFloat32Array()
var _resample_pos := 0.0
var _hang := 0.0
var _rate := 12000


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	cfg = MatchConfig.get_config()
	_rate = cfg.voice_sample_rate
	_setup_buses()
	GameManager.settings_changed.connect(_apply_settings)
	_apply_settings()


func _setup_buses() -> void:
	if AudioServer.get_bus_index(OUT_BUS) == -1:
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, OUT_BUS)
		AudioServer.set_bus_send(i, "Master")
	if AudioServer.get_bus_index(MIC_BUS) == -1:
		AudioServer.add_bus()
		var m := AudioServer.bus_count - 1
		AudioServer.set_bus_name(m, MIC_BUS)
		AudioServer.set_bus_mute(m, true)  # never play your own mic back to you
		_capture = AudioEffectCapture.new()
		_capture.buffer_length = 0.5
		AudioServer.add_bus_effect(m, _capture)


func _apply_settings() -> void:
	var i := AudioServer.get_bus_index(OUT_BUS)
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(float(GameManager.get_setting("voice_volume")), 0.0001)))
	AudioServer.set_bus_mute(i, bool(GameManager.get_setting("voice_mute_others")))


func set_microphone(enabled: bool) -> void:
	mic_enabled = enabled and Net.allows_voice() and Net.in_match
	if OS.has_feature("web"):
		var browser := JavaScriptBridge.get_interface("window")
		if _web_frames == null:
			_web_frames = JavaScriptBridge.create_callback(_receive_browser_frames)
			_web_status = JavaScriptBridge.create_callback(_receive_browser_status)
		if mic_enabled:
			browser.deadRouteStartVoice(_web_frames, _web_status)
		else:
			browser.deadRouteStopVoice()
	else:
		_set_mic(mic_enabled)
	_send_buf.clear()
	_resample_pos = 0.0
	_hang = 0.0
	talking = false
	mic_status = "Waiting for microphone…" if mic_enabled and OS.has_feature("web") else (
		"On · Nearby players can hear you." if mic_enabled else "Off · Enable to talk to players nearby.")
	microphone_changed.emit()


func _receive_browser_frames(args: Array) -> void:
	if not mic_enabled or args.size() != 2:
		return
	var bytes := JavaScriptBridge.js_buffer_to_packed_byte_array(args[0])
	var samples := bytes.to_float32_array()
	var frames := PackedVector2Array()
	frames.resize(samples.size())
	for i in samples.size():
		frames[i] = Vector2.ONE * samples[i]
	var rate := float(args[1])
	if rate > 0.0:
		feed(frames, rate, frames.size() / rate)


func _receive_browser_status(args: Array) -> void:
	if not mic_enabled or args.is_empty():
		return
	var ready := bool(args[0])
	mic_enabled = ready
	mic_status = "On · Nearby players can hear you." if ready else (
		"Microphone unavailable. Check browser permissions and try again.")
	microphone_changed.emit()


func _process(_delta: float) -> void:
	var in_room := Net.allows_voice() and Net.in_match
	if mic_enabled and not in_room:
		set_microphone(false)
	if not _mic_on or _capture == null:
		return
	var n := _capture.get_frames_available()
	var rate := AudioServer.get_mix_rate()
	if n > 0 and rate > 0.0:
		feed(_capture.get_buffer(n), rate, n / rate)


func _set_mic(on: bool) -> void:
	_mic_on = on
	_send_buf.clear()
	talking = false
	if on:
		if _mic_player == null:
			_mic_player = AudioStreamPlayer.new()
			_mic_player.stream = AudioStreamMicrophone.new()
			_mic_player.bus = MIC_BUS
			_mic_player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
			add_child(_mic_player)
		_mic_player.play()
		if _capture:
			_capture.clear_buffer()
	elif _mic_player:
		_mic_player.stop()


# ---------- Sending ----------

## Captured stereo frames at `rate` Hz. Public so tests can inject audio without a mic.
func feed(frames: PackedVector2Array, rate: float, delta: float) -> void:
	var sum := 0.0
	for f in frames:
		sum += (f.x + f.y) * (f.x + f.y) * 0.25
	level = sqrt(sum / maxf(frames.size(), 1))
	if level >= cfg.voice_open_mic_threshold:
		_hang = HANGOVER
	else:
		_hang -= delta
	talking = Input.is_action_pressed(&"voice_talk") or _hang > 0.0
	if not talking or not Net.allows_voice() or not Net.in_match:
		_send_buf.clear()
		_resample_pos = 0.0
		return
	# Mono + linear-step resample to the network rate.
	var step := rate / float(_rate)
	while _resample_pos < frames.size():
		var i := int(_resample_pos)
		var f := frames[i].lerp(frames[mini(i + 1, frames.size() - 1)], _resample_pos - i)
		_send_buf.append(clampf((f.x + f.y) * 0.5, -1.0, 1.0))
		_resample_pos += step
	_resample_pos -= frames.size()
	var chunk := int(_rate * CHUNK_SEC)
	while _send_buf.size() >= chunk:
		_send(_send_buf.slice(0, chunk))
		_send_buf = _send_buf.slice(chunk)


func _send(samples: PackedFloat32Array) -> void:
	packets_sent += 1
	_rpc_voice.rpc(encode(samples))


static func encode(samples: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(samples.size())
	var norm := log(1.0 + MU)
	for i in samples.size():
		var x := clampf(samples[i], -1.0, 1.0)
		var y := log(1.0 + MU * absf(x)) / norm  # 0..1
		out[i] = int(round(y * 127.0)) + (128 if x < 0.0 else 0)
	return out


static func decode(bytes: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(bytes.size())
	for i in bytes.size():
		var b := bytes[i]
		var y := float(b & 127) / 127.0
		var x := (pow(1.0 + MU, y) - 1.0) / MU
		out[i] = -x if b >= 128 else x
	return out


# ---------- Receiving ----------

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_voice(bytes: PackedByteArray) -> void:
	var from := multiplayer.get_remote_sender_id()
	if not Net.allows_voice() or not Net.in_match or bytes.is_empty() or bytes.size() > MAX_PACKET or from == 0:
		return
	frames_received[from] = int(frames_received.get(from, 0)) + bytes.size()
	if GameManager.get_setting("voice_mute_others"):
		return
	var speaker := _speaker_for(from)
	if speaker == null:
		return
	var pb := speaker.get_stream_playback() as AudioStreamGeneratorPlayback
	if pb == null:
		return
	var samples := decode(bytes)
	var room := pb.get_frames_available()
	var frames := PackedVector2Array()
	frames.resize(mini(samples.size(), room))
	for i in frames.size():
		frames[i] = Vector2(samples[i], samples[i])
	pb.push_buffer(frames)


## The positional voice player on `peer`'s handyman (created on first use).
func _speaker_for(peer: int) -> AudioStreamPlayer2D:
	var p: Node2D = null
	for n in Net.player_nodes():
		if n.get_multiplayer_authority() == peer:
			p = n
			break
	if p == null:
		return null
	var s := p.get_node_or_null(^"Voice") as AudioStreamPlayer2D
	if s == null:
		s = AudioStreamPlayer2D.new()
		s.name = "Voice"
		var gen := AudioStreamGenerator.new()
		gen.mix_rate_mode = AudioStreamGenerator.MIX_RATE_CUSTOM
		gen.mix_rate = _rate
		gen.buffer_length = 0.4
		s.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
		s.stream = gen
		s.bus = OUT_BUS
		s.max_distance = cfg.voice_max_distance
		s.attenuation = cfg.voice_attenuation
		s.position = Vector2(0, -14)
		p.add_child(s)
	if not s.playing:
		s.play()
	return s
