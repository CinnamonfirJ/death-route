extends MultiplayerPeerExtension
## Transports Godot multiplayer packets over the room relay. The room creator
## remains peer 1, so the existing simulation and RPC authorities still apply.

signal welcomed(code: String)
signal failed(reason: String)

const CONNECT_TIMEOUT_MS := 10000
const MAX_PAYLOAD := 65536
const MAX_QUEUED_PACKETS := 4096

var _socket := WebSocketPeer.new()
var _state := CONNECTION_DISCONNECTED
var _id := 0
var _deadline := 0
var _target := 0
var _transfer_mode := TRANSFER_MODE_RELIABLE
var _transfer_channel := 0
var _packets: Array[PackedByteArray] = []
var _sender := 0
var _refusing := false


func open(url: String) -> Error:
	_socket.inbound_buffer_size = 1024 * 1024
	_socket.outbound_buffer_size = 1024 * 1024
	_socket.max_queued_packets = MAX_QUEUED_PACKETS
	var result := _socket.connect_to_url(url)
	if result == OK:
		_state = CONNECTION_CONNECTING
		_deadline = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	return result


func advertise(settings: Dictionary) -> void:
	_send_control({"type": "settings", "mode": settings.mode, "location": settings.location})


func _send_control(message: Dictionary) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(message))


func _poll() -> void:
	if _state == CONNECTION_DISCONNECTED:
		return
	_socket.poll()
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		if _socket.was_string_packet():
			_control(JSON.parse_string(packet.get_string_from_utf8()))
		elif _state == CONNECTION_CONNECTED and packet.size() > 4:
			if _packets.size() < MAX_QUEUED_PACKETS:
				_packets.append(packet)
	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_state = CONNECTION_DISCONNECTED
	elif _state == CONNECTION_CONNECTING and Time.get_ticks_msec() >= _deadline:
		failed.emit("The room service took too long to respond.")
		_close()


func _control(value: Variant) -> void:
	if not value is Dictionary:
		return
	var message: Dictionary = value
	var id := int(message.get("id", 0))
	match message.get("type", ""):
		"welcome":
			if _state != CONNECTION_CONNECTING or id <= 0:
				return
			_id = id
			_state = CONNECTION_CONNECTED
			welcomed.emit(String(message.code))
			for peer in message.peers:
				peer_connected.emit(int(peer))
		"joined":
			if _state == CONNECTION_CONNECTED and id > 1:
				peer_connected.emit(id)
		"left":
			if _state == CONNECTION_CONNECTED and id > 1:
				peer_disconnected.emit(id)
		"error":
			failed.emit(String(message.get("message", "Could not enter the room.")))


func _put_packet_script(payload: PackedByteArray) -> Error:
	if _state != CONNECTION_CONNECTED:
		return ERR_UNCONFIGURED
	if payload.size() > MAX_PAYLOAD:
		return ERR_INVALID_PARAMETER
	var packet := PackedByteArray()
	packet.resize(4)
	packet.encode_s32(0, _target)
	packet.append_array(payload)
	return _socket.send(packet)


func _get_packet_script() -> PackedByteArray:
	var packet: PackedByteArray = _packets.pop_front()
	_sender = packet.decode_s32(0)
	return packet.slice(4)


func _get_packet_peer() -> int:
	# SceneMultiplayer reads the sender before taking the packet from the queue.
	return _packets[0].decode_s32(0) if not _packets.is_empty() else _sender


func _get_available_packet_count() -> int:
	return _packets.size()


func _get_max_packet_size() -> int:
	return MAX_PAYLOAD


func _get_packet_channel() -> int:
	return 0


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return TRANSFER_MODE_RELIABLE


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _transfer_mode


func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_transfer_mode = mode


func _set_target_peer(peer: int) -> void:
	_target = peer


func _is_server() -> bool:
	return _id == 1


func _is_server_relay_supported() -> bool:
	return false


func _get_unique_id() -> int:
	return _id


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return _state


func _set_refuse_new_connections(enable: bool) -> void:
	_refusing = enable
	if enable and _id == 1:
		_send_control({"type": "start"})


func _is_refusing_new_connections() -> bool:
	return _refusing


func _disconnect_peer(peer: int, _force: bool) -> void:
	if _id == 1:
		_send_control({"type": "kick", "id": peer})
	elif peer == 1:
		_close()


func _close() -> void:
	_socket.close()
	_state = CONNECTION_DISCONNECTED
	_packets.clear()
