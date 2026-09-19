@tool
class_name MTSStudioBridge
extends Node

## HTTP command bus into the live Tile Studio workspace.
##
## The running editor owns the authoritative BoardDocument. This exposes it over
## a loopback HTTP port so an external agent drives exactly the same code paths
## the mouse does -- the same brush, the same validator, the same undo stack --
## rather than a parallel implementation that could pass while the UI is broken.
##
## Loopback only. It binds 127.0.0.1 and is not an authenticated service; it is a
## local automation seam for a single-user authoring tool.

const K := preload("../utils/mts_constants.gd")

const DEFAULT_PORT: int = 47850
## Guard against a runaway client blocking the editor's main thread.
const CLIENT_TIMEOUT_MS := 2000
const MAX_REQUESTS_PER_FRAME: int = 8
const MAX_BODY_BYTES: int = 4 * 1024 * 1024

signal command_handled(tool_name: String, ok: bool)

var port: int = DEFAULT_PORT
var main_panel: Control
var plugin: EditorPlugin

var _server: TCPServer
var _listening: bool = false
var _clients: Array[Dictionary] = []


func start(p_port: int = DEFAULT_PORT) -> bool:
	port = p_port
	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		# Most often the port is already held by a previous editor session.
		push_warning("[Tile Studio] MCP bridge could not bind 127.0.0.1:%d (%s)" % [port, error_string(err)])
		_listening = false
		return false
	_listening = true
	set_process(true)
	print("[Tile Studio] MCP bridge listening on http://127.0.0.1:%d" % port)
	return true


func stop() -> void:
	set_process(false)
	_listening = false
	if _server != null:
		_server.stop()
		_server = null


func is_listening() -> bool:
	return _listening


func _process(_delta: float) -> void:
	if not _listening or _server == null:
		return

	# Accept new connections without waiting for them to send anything.
	var accepted := 0
	while _server.is_connection_available() \
	and accepted < MAX_REQUESTS_PER_FRAME:

		var peer := _server.take_connection()
		if peer == null:
			break
		_clients.append({
			"peer": peer,
			"buffer": "",
			"content_length": -1,
			"deadline": Time.get_ticks_msec() + CLIENT_TIMEOUT_MS,
		})

		accepted += 1

	# Give every client one non-blocking pump this frame.
	for i in range(_clients.size() - 1, -1, -1):
		if _pump_client(_clients[i]):
			_clients.remove_at(i)


func _serve_raw(peer: StreamPeerTCP, raw: String) -> void:
	if raw.is_empty():
		peer.disconnect_from_host()
		return

	var header_end := raw.find("\r\n\r\n")
	if header_end < 0:
		_respond(peer, 400, {"ok": false, "error": "malformed request"})
		return
	var head := raw.substr(0, header_end)
	var body := raw.substr(header_end + 4)
	var first_line := head.get_slice("\r\n", 0)
	var method := first_line.get_slice(" ", 0)
	var path := first_line.get_slice(" ", 1)

	if method == "GET" and path.begins_with("/health"):
		_respond(peer, 200, {
			"ok": true,
			"server": "modular-tile-studio",
			"listening": true,
			"has_board": plugin != null and plugin.get("board") != null,
		})
		return

	if method != "POST" or not path.begins_with("/tool"):
		_respond(peer, 404, {"ok": false, "error": "unknown endpoint '%s'" % path})
		return

	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		_respond(peer, 400, {"ok": false, "error": "body must be a JSON object"})
		return

	var request: Dictionary = parsed
	var tool_name := String(request.get("tool", ""))
	var args: Dictionary = request.get("arguments", {})

	var result: Dictionary
	# A tool error must return a structured failure, never take the editor down.
	result = await _dispatch(tool_name, args)
	command_handled.emit(tool_name, bool(result.get("ok", false)))
	_respond(peer, 200 if result.get("ok", false) else 400, result)


func _pump_client(client: Dictionary) -> bool:
	var peer := client["peer"] as StreamPeerTCP
	if peer == null:
		return true

	peer.poll()

	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return true

	var available := peer.get_available_bytes()

	if available > 0:
		var chunk := peer.get_utf8_string(
			mini(available, MAX_BODY_BYTES)
		)

		client["buffer"] = String(client["buffer"]) + chunk

	var raw := String(client["buffer"])

	if raw.length() > MAX_BODY_BYTES:
		_respond(
			peer,
			413,
			{"ok": false, "error": "request too large"}
		)
		return true

	var header_end := raw.find("\r\n\r\n")

	if header_end >= 0 and int(client["content_length"]) < 0:
		var head := raw.substr(0, header_end).to_lower()
		var content_length := 0

		for line in head.split("\r\n"):
			if line.begins_with("content-length:"):
				content_length = int(
					line.get_slice(":", 1).strip_edges()
				)
				break

		client["content_length"] = content_length

	if header_end >= 0:
		var body_size := raw.length() - (header_end + 4)

		if body_size >= int(client["content_length"]):
			_serve_raw(peer, raw)
			return true

	if Time.get_ticks_msec() >= int(client["deadline"]):
		peer.disconnect_from_host()
		return true

	return false


func _respond(peer: StreamPeerTCP, status: int, payload: Dictionary) -> void:
	var body := JSON.stringify(payload)
	var body_bytes := body.to_utf8_buffer()
	var header := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [
		status, "OK" if status == 200 else "Error", body_bytes.size()
	]
	peer.put_data(header.to_utf8_buffer())
	peer.put_data(body_bytes)
	peer.poll()
	peer.disconnect_from_host()


# --- Tool dispatch --------------------------------------------------------
#
# Each tool drives the SAME objects the UI drives. Painting goes through the
# placement controller's brush and validator, so a bug in the interactive path
# shows up here too instead of being masked by a separate code path.

func _dispatch(tool_name: String, args: Dictionary) -> Dictionary:
	if plugin == null or main_panel == null:
		return {"ok": false, "error": "bridge is not bound to a live plugin"}

	var viewport: MTSStudioViewport = main_panel.get("viewport")
	var board: BoardDocument = plugin.get("board")
	var library: AssetLibrary = plugin.get("library")
	if viewport == null or board == null or library == null:
		return {"ok": false, "error": "studio is not fully initialised yet"}

	match tool_name:
		"studio_status":
			return _tool_status(viewport, board, library)
		"list_assets":
			return _tool_list_assets(library)
		"list_gameplay":
			return _tool_list_gameplay(board)
		"create_enemy_pack":
			return _tool_create_enemy_pack(args)
		"update_enemy_pack":
			return _tool_update_enemy_pack(args)
		"delete_enemy_pack":
			return _tool_delete_enemy_pack(args)
		"assign_enemy_markers_to_pack":
			return _tool_assign_enemy_markers_to_pack(args)
		"place_gameplay_marker":
			return _tool_place_gameplay_marker(viewport, board, args)
		"update_gameplay_marker":
			return _tool_update_gameplay_marker(args)
		"delete_gameplay_marker":
			return _tool_delete_gameplay_marker(args)
		"select_brush":
			return _tool_select_brush(viewport, library, args)
		"set_layer":
			return _tool_set_layer(viewport, args)
		"paint_surface":
			return _tool_paint_surface(viewport, board, library, args)
		"place_prop":
			return _tool_place_prop(viewport, board, library, args)
		"erase_at":
			return _tool_erase(viewport, board, args)
		"clear_board":
			board.clear()
			viewport.rebuild_board()
			return {"ok": true, "cleared": true}
		"frame_board":
			viewport.frame_board()
			return {"ok": true}
		"set_view":
			return _tool_set_view(viewport, args)
		"capture":
			return _tool_capture(viewport, args)
		"validate_board":
			return {"ok": true, "report": board.validate_all()}
		"list_recipes":
			return _tool_list_recipes()
		"analyze":
			return _tool_analyze(library, args)
		"asset_channels":
			return _tool_asset_channels(library, args)
		"import_glb":
			return await _tool_import_glb(library, args)
		"save_board":
			return _tool_save_board(board, args)
		_:
			return {"ok": false, "error": "unknown tool '%s'" % tool_name}


func _tool_status(viewport: MTSStudioViewport, board: BoardDocument, library: AssetLibrary) -> Dictionary:
	return {
		"ok": true,
		"surfaces": board.surfaces.size(),
		"props": board.props.size(),
		"assets": library.assets.size(),
		"gameplay_markers": board.gameplay_markers.size(),
		"enemy_packs": board.enemy_packs.size(),
		"terrain_cells": board.terrain.filled_cell_count() if board.terrain != null else 0,
		"movement_collision_min_triangle_share_percent": (
			board.movement_collision_min_triangle_share_percent
		),
		"movement_manual_unwalkable_cells": board.movement_unwalkable_cells.size(),
		"movement_ground_effect_cells": board.movement_ground_effects.size(),
		"current_y": viewport.current_y,
		"brush": viewport.placement.brush_asset.asset_id if viewport.placement.brush_asset != null else "",
		"brush_prop_support": viewport.placement.brush_prop_support,
		"brush_surface_face": K.face_name(viewport.placement.brush_face),
		"brush_surface_rotation": viewport.placement.brush_quarters,
		"brush_prop_forward": K.face_name(viewport.placement.brush_prop_forward_face),
		"brush_prop_roll": viewport.placement.brush_prop_roll_quarters,
		"brush_prop_yaw": viewport.placement.brush_prop_yaw_eighths,
	}


## List asset-owned raw collision scans; the board status reports the one global filter.
func _tool_list_assets(library: AssetLibrary) -> Dictionary:
	var entries: Array = []
	for asset in library.assets:
		if asset == null:
			continue
		entries.append({
			"asset_id": asset.asset_id,
			"kind": "surface" if asset.is_surface() else "prop",
			"grid_bounds": [asset.grid_bounds.x, asset.grid_bounds.y, asset.grid_bounds.z],
			"visual_size_m": [asset.visual_size_m.x, asset.visual_size_m.y, asset.visual_size_m.z],
			"source_orientation": "Y_UP",
			"raw_voxels": asset.prop_voxels.size() if asset.is_prop() else 0,
			"raw_diagonal_voxels": asset.prop_voxels_diagonal.size() if asset.is_prop() else 0,
			"collision_measurements_ready": (
				asset.is_prop()
				and asset.prop_collision_measurements_ready()
			),
		})
	return {"ok": true, "assets": entries}

## List canonical pack, marker, and monster-visual records without derived scene-node state.
func _tool_list_gameplay(board: BoardDocument) -> Dictionary:
	var packs: Array = []
	for pack: EnemyPack in board.enemy_packs:
		if pack == null:
			continue
		packs.append({
			"id": pack.pack_id,
			"note": pack.note,
			"members": board.enemy_pack_member_count(pack.pack_id),
		})
	var markers: Array = []
	for marker: GameplayMarker in board.gameplay_markers:
		if marker != null:
			markers.append(marker.to_json())
	var monster_visuals: Array = []
	var monster_ids: Array = board.monster_visual_assets.keys()
	monster_ids.sort()
	for monster_id_value: Variant in monster_ids:
		var monster_id := String(monster_id_value)
		monster_visuals.append({
			"monster": monster_id,
			"asset": board.monster_visual_asset_id(monster_id),
		})
	return {
		"ok": true,
		"enemy_packs": packs,
		"gameplay_markers": markers,
		"monster_visuals": monster_visuals,
	}


## Create one enemy pack through the same plugin operation used by the Gameplay panel.
func _tool_create_enemy_pack(args: Dictionary) -> Dictionary:
	var pack_id_report := _string_argument(args, "id", false)
	if not bool(pack_id_report.get("valid", false)):
		return {"ok": false, "error": pack_id_report.get("reason", "invalid id")}
	var note_report := _string_argument(args, "note", false)
	if not bool(note_report.get("valid", false)):
		return {"ok": false, "error": note_report.get("reason", "invalid note")}
	var raw: Variant = plugin.call(
		"create_enemy_pack",
		String(pack_id_report["value"]),
		String(note_report["value"])
	)
	return _bridge_action_result(raw)


## Update one enemy pack note while preserving its exact stable id.
func _tool_update_enemy_pack(args: Dictionary) -> Dictionary:
	var pack_id_report := _string_argument(args, "id", false)
	if not bool(pack_id_report.get("valid", false)):
		return {"ok": false, "error": pack_id_report.get("reason", "invalid id")}
	var note_report := _string_argument(args, "note", false)
	if not bool(note_report.get("valid", false)):
		return {"ok": false, "error": note_report.get("reason", "invalid note")}
	var raw: Variant = plugin.call(
		"update_enemy_pack",
		String(pack_id_report["value"]),
		String(note_report["value"])
	)
	return _bridge_action_result(raw)


## Delete one enemy pack through the document's explicit membership guard.
func _tool_delete_enemy_pack(args: Dictionary) -> Dictionary:
	var pack_id_report := _string_argument(args, "id", false)
	if not bool(pack_id_report.get("valid", false)):
		return {"ok": false, "error": pack_id_report.get("reason", "invalid id")}
	var raw: Variant = plugin.call(
		"delete_enemy_pack",
		String(pack_id_report["value"])
	)
	return _bridge_action_result(raw)


## Assign exact enemy marker ids to one pack through the same atomic operation as dragging.
func _tool_assign_enemy_markers_to_pack(args: Dictionary) -> Dictionary:
	var marker_ids_report := _string_array_argument(args, "marker_ids", false)
	if not bool(marker_ids_report.get("valid", false)):
		return {
			"ok": false,
			"error": marker_ids_report.get("reason", "invalid marker_ids"),
		}
	var pack_report := _string_argument(args, "pack", true)
	if not bool(pack_report.get("valid", false)):
		return {"ok": false, "error": pack_report.get("reason", "invalid pack")}
	var raw: Variant = plugin.call(
		"assign_enemy_markers_to_pack",
		marker_ids_report["values"],
		String(pack_report["value"])
	)
	return _bridge_action_result(raw)


## Place one marker through the dedicated controller used by interactive grid clicks.
func _tool_place_gameplay_marker(
	viewport: MTSStudioViewport,
	board: BoardDocument,
	args: Dictionary
) -> Dictionary:
	var parsed_cell := _integer_array_argument(args, "origin", 3)
	if not bool(parsed_cell.get("valid", false)):
		return {"ok": false, "error": parsed_cell.get("reason", "invalid origin")}
	var id_report := _string_argument(args, "id", false)
	if not bool(id_report.get("valid", false)):
		return {"ok": false, "error": id_report.get("reason", "invalid id")}
	var type_report := _string_argument(args, "type", false)
	if not bool(type_report.get("valid", false)):
		return {"ok": false, "error": type_report.get("reason", "invalid type")}
	var note_report := _string_argument(args, "note", false)
	if not bool(note_report.get("valid", false)):
		return {"ok": false, "error": note_report.get("reason", "invalid note")}
	var monster_report := _string_argument(args, "monster", true)
	if not bool(monster_report.get("valid", false)):
		return {"ok": false, "error": monster_report.get("reason", "invalid monster")}
	var pack_report := _string_argument(args, "pack", true)
	if not bool(pack_report.get("valid", false)):
		return {"ok": false, "error": pack_report.get("reason", "invalid pack")}
	var values: PackedInt32Array = parsed_cell["values"]
	viewport.gameplay_markers.set_brush(
		String(type_report["value"]),
		String(note_report["value"]),
		String(monster_report["value"]),
		String(pack_report["value"]),
		String(id_report["value"])
	)
	viewport.gameplay_markers.hovered_cell = Vector3i(
		values[0],
		values[1],
		values[2]
	)
	viewport.gameplay_markers._evaluate_hover()
	var raw := viewport.gameplay_markers.place_at_hover()
	var result := _bridge_action_result(raw)
	if bool(result.get("ok", false)):
		result["placed"] = {
			"id": id_report["value"],
			"type": type_report["value"],
			"origin": Array(values),
			"note": note_report["value"],
			"monster": monster_report["value"],
			"pack": pack_report["value"],
		}
		board.rebuild_gameplay_indexes()
	return result


## Update one marker through the same plugin operation used by the visible panel.
func _tool_update_gameplay_marker(args: Dictionary) -> Dictionary:
	for field: String in ["id", "type", "note", "monster", "pack"]:
		var allow_empty := field == "monster" or field == "pack"
		var report := _string_argument(args, field, allow_empty)
		if not bool(report.get("valid", false)):
			return {
				"ok": false,
				"error": report.get("reason", "invalid %s" % field),
			}
	var raw: Variant = plugin.call(
		"update_gameplay_marker",
		String(args["id"]),
		String(args["type"]),
		String(args["note"]),
		String(args["monster"]),
		String(args["pack"])
	)
	return _bridge_action_result(raw)


## Delete one exact marker id through the shared plugin operation.
func _tool_delete_gameplay_marker(args: Dictionary) -> Dictionary:
	var id_report := _string_argument(args, "id", false)
	if not bool(id_report.get("valid", false)):
		return {"ok": false, "error": id_report.get("reason", "invalid id")}
	var raw: Variant = plugin.call(
		"delete_gameplay_marker",
		String(id_report["value"])
	)
	return _bridge_action_result(raw)


## Convert one plugin operation report to the bridge's stable ok/error envelope.
func _bridge_action_result(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {"ok": false, "error": "studio action returned no report"}
	var result: Dictionary = raw
	if bool(result.get("valid", false)):
		var success := result.duplicate(true)
		success["ok"] = true
		return success
	var error := String(result.get("reason", ""))
	if error.is_empty():
		var errors: Array = result.get("errors", [])
		if not errors.is_empty():
			error = String(errors[0])
	if error.is_empty():
		error = "studio action failed"
	return {
		"ok": false,
		"error": error,
		"errors": result.get("errors", []),
	}


## Read one exact required string without converting JSON numbers or booleans.
func _string_argument(
	args: Dictionary,
	key: String,
	allow_empty: bool
) -> Dictionary:
	if not args.has(key) or not (args[key] is String):
		return {"valid": false, "reason": "%s must be a string" % key}
	var value: String = args[key]
	if not allow_empty and value.is_empty():
		return {"valid": false, "reason": "%s must be non-empty" % key}
	return {"valid": true, "reason": "", "value": value}


## Read one exact string array without converting primitive values or empty ids.
func _string_array_argument(
	args: Dictionary,
	key: String,
	allow_empty_values: bool
) -> Dictionary:
	var raw: Variant = args.get(key, null)
	if not (raw is Array):
		return {"valid": false, "reason": "%s must be an array of strings" % key}
	var values := PackedStringArray()
	for component: Variant in raw:
		if not (component is String):
			return {"valid": false, "reason": "%s must contain only strings" % key}
		var value: String = component
		if not allow_empty_values and value.is_empty():
			return {"valid": false, "reason": "%s cannot contain an empty string" % key}
		values.append(value)
	return {"valid": true, "reason": "", "values": values}


## Read one required integer array without silently truncating API coordinates.
func _integer_array_argument(
	args: Dictionary,
	key: String,
	required_size: int
) -> Dictionary:
	var raw: Variant = args.get(key, null)
	if not (raw is Array) or (raw as Array).size() != required_size:
		return {
			"valid": false,
			"reason": "%s must contain exactly %d integers" % [key, required_size],
		}
	var values := PackedInt32Array()
	for component: Variant in raw:
		if not (component is int or component is float):
			return {"valid": false, "reason": "%s contains a non-number" % key}
		var numeric := float(component)
		if numeric != floorf(numeric):
			return {"valid": false, "reason": "%s values must be integers" % key}
		values.append(int(numeric))
	return {"valid": true, "reason": "", "values": values}


## Read one quarter turn without silently normalizing an invalid API value.
func _quarter_turn_argument(
	args: Dictionary,
	key: String,
	default_value: int
) -> Dictionary:
	var raw: Variant = args.get(key, default_value)
	if not (raw is int or raw is float):
		return {"valid": false, "reason": "%s must be an integer from 0 through 3" % key}
	var numeric := float(raw)
	if numeric != floorf(numeric) or numeric < 0.0 or numeric > 3.0:
		return {"valid": false, "reason": "%s must be an integer from 0 through 3" % key}
	return {"valid": true, "reason": "", "value": int(numeric)}


## Select one finished library asset as the ordinary editor brush.
func _tool_select_brush(viewport: MTSStudioViewport, library: AssetLibrary, args: Dictionary) -> Dictionary:
	var asset := library.get_asset(String(args.get("asset_id", "")))
	if asset == null:
		return {"ok": false, "error": "no such asset '%s'" % args.get("asset_id", "")}
	viewport.placement.set_brush(asset)
	if asset.is_surface() and args.has("face"):
		viewport.placement.set_brush_face(K.face_from_name(String(args["face"])))
	elif asset.is_prop():
		var forward_face := K.facing_to_forward_face(K.facing_from_name(String(args.get("facing", "N"))))
		if args.has("forward"):
			forward_face = K.face_from_name(String(args["forward"]))
		viewport.placement.set_prop_orientation(
			forward_face,
			int(args.get("roll", 0)),
			int(args.get("yaw", 0))
		)
	return {
		"ok": true,
		"brush": asset.asset_id,
		"surface_face": K.face_name(viewport.placement.brush_face),
		"surface_rotation": viewport.placement.brush_quarters,
		"prop_forward": K.face_name(viewport.placement.brush_prop_forward_face),
		"prop_roll": viewport.placement.brush_prop_roll_quarters,
		"prop_yaw": viewport.placement.brush_prop_yaw_eighths,
	}


func _tool_set_layer(viewport: MTSStudioViewport, args: Dictionary) -> Dictionary:
	viewport.current_y = int(args.get("y", 0))
	return {"ok": true, "current_y": viewport.current_y}


## Paint a surface through the placement controller, exactly as a click would.
func _tool_paint_surface(viewport: MTSStudioViewport, board: BoardDocument, library: AssetLibrary, args: Dictionary) -> Dictionary:
	var asset := library.get_asset(String(args.get("asset_id", "")))
	if asset == null:
		return {"ok": false, "error": "no such asset '%s'" % args.get("asset_id", "")}
	if not asset.is_surface():
		return {"ok": false, "error": "'%s' is a prop; use place_prop" % asset.asset_id}

	var cell := _cell_from(args)
	var face := K.face_from_name(String(args.get("face", "+Y")))
	var quarters := int(args.get("rotation", 0))

	# Drive the real brush so this exercises the interactive path.
	viewport.placement.set_brush(asset)
	viewport.placement.set_brush_face(face)
	viewport.placement.brush_quarters = quarters
	viewport.placement.hovered_cell = cell
	viewport.placement._evaluate_hover()

	# Gated, exactly as a click is: two surfaces may not claim one grid face.
	# Reported as a failure rather than a warning so a generator driving this
	# bridge cannot mistake a refused placement for a board it actually built.
	if not viewport.placement.paint_at_hover():
		return {"ok": false, "error": viewport.placement.last_rejection, "cell": [cell.x, cell.y, cell.z]}
	# paint_at_hover emits board_mutated, so no second viewport refresh is needed.
	return {"ok": true, "placed": {"asset": asset.asset_id, "cell": [cell.x, cell.y, cell.z], "face": K.face_name(face)}}


func _tool_place_prop(viewport: MTSStudioViewport, board: BoardDocument, library: AssetLibrary, args: Dictionary) -> Dictionary:
	var asset := library.get_asset(String(args.get("asset_id", "")))
	if asset == null:
		return {"ok": false, "error": "no such asset '%s'" % args.get("asset_id", "")}
	if not asset.is_prop():
		return {"ok": false, "error": "'%s' is a surface; use paint_surface" % asset.asset_id}

	var cell := _cell_from(args)
	var forward_face := K.facing_to_forward_face(K.facing_from_name(String(args.get("facing", "N"))))
	if args.has("forward"):
		forward_face = K.face_from_name(String(args["forward"]))
	var roll_quarters := int(args.get("roll", 0))
	var yaw_eighths := int(args.get("yaw", 0))

	viewport.placement.set_brush(asset)
	viewport.placement.set_prop_orientation(
		forward_face,
		roll_quarters,
		yaw_eighths
	)
	viewport.placement.hovered_cell = cell
	viewport.placement._evaluate_hover()

	# Gated: two props may not share a SOLID voxel. Standing on a surface is
	# always legal -- those are separate channels and never conflict.
	if not viewport.placement.paint_at_hover():
		return {"ok": false, "error": viewport.placement.last_rejection, "cell": [cell.x, cell.y, cell.z]}
	# paint_at_hover emits board_mutated, so no second viewport refresh is needed.
	return {
		"ok": true,
		"placed": {
			"asset": asset.asset_id,
			"cell": [cell.x, cell.y, cell.z],
			"forward": K.face_name(forward_face),
			"roll": K.normalized_quarters(roll_quarters),
			"yaw": K.normalized_yaw_eighths(yaw_eighths),
		},
	}


func _tool_erase(viewport: MTSStudioViewport, _board: BoardDocument, args: Dictionary) -> Dictionary:
	viewport.placement.hovered_cell = _cell_from(args)
	if args.has("face"):
		viewport.placement.brush_face = K.face_from_name(String(args["face"]))
	# erase_at_hover emits board_mutated after the canonical placement removal.
	viewport.placement.erase_at_hover()
	return {"ok": true}


func _tool_set_view(viewport: MTSStudioViewport, args: Dictionary) -> Dictionary:
	if args.has("target"):
		var t: Array = args["target"]
		if t.size() >= 3:
			viewport.camera.target = Vector3(float(t[0]), float(t[1]), float(t[2]))
	if args.has("zoom"):
		viewport.camera.ortho_size = float(args["zoom"])
	if args.has("grid"):
		viewport.set_grid_visible(bool(args["grid"]))
	if args.has("side_grid"):
		viewport.set_lattice_visible(bool(args["side_grid"]))
	return {
		"ok": true,
		"target": [viewport.camera.target.x, viewport.camera.target.y, viewport.camera.target.z],
		"zoom": viewport.camera.ortho_size,
	}


## Grab the studio viewport exactly as the user sees it, and write it to disk.
##
## This is the proof mechanism: the image comes from the same SubViewport the
## editor draws, not from a separate offscreen scene assembled for the occasion.
func _tool_capture(viewport: MTSStudioViewport, args: Dictionary) -> Dictionary:
	var path := String(args.get("path", "res://captures/studio_capture.png"))
	var global_path := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())

	# The workspace only has a size while it is the visible main screen. Capturing
	# with the tab hidden yields a 2x2 stub, so switch to it first.
	if not main_panel.visible:
		EditorInterface.set_main_screen_editor("Tile Studio")
		main_panel.visible = true
	if viewport.sub_viewport.size.x < 16 or viewport.sub_viewport.size.y < 16:
		return {
			"ok": false,
			"error": "viewport is %s; open the Tile Studio tab in the editor and retry" % str(viewport.sub_viewport.size),
		}

	var texture := viewport.sub_viewport.get_texture()
	if texture == null:
		return {"ok": false, "error": "viewport has no texture yet"}
	var image := texture.get_image()
	if image == null or image.is_empty():
		return {"ok": false, "error": "viewport image is empty"}
	var err := image.save_png(global_path)
	if err != OK:
		return {"ok": false, "error": "could not write '%s' (%s)" % [global_path, error_string(err)]}
	return {
		"ok": true,
		"path": global_path,
		"size": [image.get_width(), image.get_height()],
	}


## Recipes the live provider can see, including whether the backend is up.
func _tool_list_recipes() -> Dictionary:
	var provider := plugin.get("provider") as ComfyUIProvider
	if provider == null:
		return {"ok": false, "error": "analysis provider not initialised"}
	var entries: Array = []
	for recipe: Dictionary in provider.list_recipes():
		entries.append({
			"name": recipe.get("name", ""),
			"workflow": recipe.get("workflow", ""),
			"outputs": recipe.get("outputs", {}),
			"requires_setup": recipe.get("requires_setup", false),
		})
	return {
		"ok": true,
		"available": provider.is_available(),
		"server": provider.base_url(),
		"recipes": entries,
	}


## Kick off a real analysis job through the plugin's own provider, so this
## exercises the same upload/queue/poll/assign path the Analyze button uses.
func _tool_analyze(library: AssetLibrary, args: Dictionary) -> Dictionary:
	var provider := plugin.get("provider") as ComfyUIProvider
	if provider == null:
		return {"ok": false, "error": "analysis provider not initialised"}
	if not provider.is_available():
		return {"ok": false, "error": "ComfyUI not reachable at %s" % provider.base_url()}

	var asset := library.get_asset(String(args.get("asset_id", "")))
	if asset == null:
		return {"ok": false, "error": "no such asset '%s'" % args.get("asset_id", "")}

	var wanted := String(args.get("recipe", "")).to_lower()
	var chosen: Dictionary = {}
	for recipe: Dictionary in provider.list_recipes():
		if String(recipe.get("name", "")).to_lower().contains(wanted):
			chosen = recipe
			break
	if chosen.is_empty():
		return {"ok": false, "error": "no recipe matching '%s'" % wanted}

	var job_id: String = provider.analyze(asset, chosen)
	if job_id.is_empty():
		return {"ok": false, "error": "provider refused the job"}
	return {"ok": true, "job_id": job_id, "recipe": chosen.get("name", ""), "asset": asset.asset_id}


## Which G-buffer channels an asset currently carries, for polling a job's effect.
func _tool_asset_channels(library: AssetLibrary, args: Dictionary) -> Dictionary:
	var asset := library.get_asset(String(args.get("asset_id", "")))
	if asset == null:
		return {"ok": false, "error": "no such asset"}
	var channels: Array = []
	if asset.gbuffer != null:
		for c in asset.gbuffer.available_channels():
			channels.append({"channel": c, "path": asset.gbuffer.get_channel(c)})
	return {
		"ok": true,
		"asset": asset.asset_id,
		"status": asset.analysis_status,
		"channels": channels,
	}


## Import a GLB through the plugin's real importer, so sizing and voxelization
## run exactly as the Import GLB dialog runs them. The prop is placed as its
## own real source mesh at runtime -- there is no rendered view to report.
func _tool_import_glb(library: AssetLibrary, args: Dictionary) -> Dictionary:
	var importer := plugin.get("glb_importer") as GLBAssetImporter
	if importer == null:
		return {"ok": false, "error": "GLB importer not initialised"}
	var source := String(args.get("path", ""))
	if source.is_empty():
		return {"ok": false, "error": "no path given"}

	var settings := {
		"asset_id": String(args.get("asset_id", "")),
		"display_name": String(args.get("display_name", "")),
		"target": args.get("target", {}),
		"proportional": bool(args.get("proportional", true)),
	}
	var asset: TileAsset = await importer.import_glb(source, settings, library)
	if asset == null:
		return {"ok": false, "error": "import failed; see the editor log"}
	library.save()
	# The bridge imports into the same library the dialog does, so the open level
	# records the import the same way. Without this the library's level view would
	# silently miss everything an agent brought in. The panel is refreshed after the
	# note because the library's own change signal fired during the import, before
	# the board knew about the asset.
	var board := plugin.get("board") as BoardDocument
	if board == null:
		push_error(
			"[Tile Studio] bridge imported '%s' with no open board to record it against."
			% asset.asset_id
		)
	else:
		board.note_imported_asset(asset.asset_id)
		if main_panel != null:
			main_panel.library_panel.refresh()
	EditorInterface.get_resource_filesystem().scan()

	return {
		"ok": true,
		"asset_id": asset.asset_id,
		"visual_size": [asset.visual_size_m.x, asset.visual_size_m.y, asset.visual_size_m.z],
		"grid_bounds": [asset.grid_bounds.x, asset.grid_bounds.y, asset.grid_bounds.z],
		"raw_voxels": asset.prop_voxels.size(),
		"raw_diagonal_voxels": asset.prop_voxels_diagonal.size(),
		"collision_measurements_ready": asset.prop_collision_measurements_ready(),
	}


func _tool_save_board(board: BoardDocument, args: Dictionary) -> Dictionary:
	var path := String(args.get("path", "res://boards/mcp_board.json"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var err := board.save_json(path)
	if err != OK:
		return {"ok": false, "error": error_string(err)}
	return {"ok": true, "path": ProjectSettings.globalize_path(path)}


func _cell_from(args: Dictionary) -> Vector3i:
	var cell: Variant = args.get("cell", null)
	if cell is Array and (cell as Array).size() >= 3:
		var c: Array = cell
		return Vector3i(int(c[0]), int(c[1]), int(c[2]))
	return Vector3i(int(args.get("x", 0)), int(args.get("y", 0)), int(args.get("z", 0)))
