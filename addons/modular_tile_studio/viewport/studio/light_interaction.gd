@tool
extends RefCounted

## Light interaction behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Route surface placement, handle clicks, and active drags ahead of ordinary authoring tools.
static func _handle_light_handle_input(host: MTSStudioViewport, event: InputEvent) -> bool:
	if not host._light_handles_visible or host.board == null:
		return false
	if event is InputEventMouseMotion and host._light_drag_mode != MTSStudioViewport.LocalLightDragMode.NONE:
		host._continue_light_handle_drag((event as InputEventMouseMotion).position)
		return true
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if (
			button.button_index == MOUSE_BUTTON_RIGHT
			and button.pressed
			and host._local_light_placement_pending
		):
			host._local_light_placement_pending = false
			host.status_changed.emit("Local-light placement cancelled.")
			return true
		if button.button_index != MOUSE_BUTTON_LEFT:
			return false
		if button.pressed:
			if host._local_light_placement_pending:
				return host._place_local_light_on_surface(button.position)
			return host._begin_light_handle_drag(button.position)
		if host._light_drag_mode != MTSStudioViewport.LocalLightDragMode.NONE:
			host._finish_light_handle_drag()
			return true
	return false


## Create a light at the exact first collision point under the cursor.
static func _place_local_light_on_surface(host: MTSStudioViewport, screen_position: Vector2) -> bool:
	var hit := host._local_light_surface_hit(screen_position)
	if hit.is_empty():
		host.status_changed.emit(
			"No authored terrain under the cursor; the new light was not created."
		)
		return true
	var new_index := host.board.lighting.add_light(
		hit["position"] as Vector3,
		LightingProfile.DEFAULT_LOCAL_LIGHT_HEIGHT_M
	)
	if new_index < 0:
		host._local_light_placement_pending = false
		host.status_changed.emit(
			"This rig supports at most %d local lights." % LightingProfile.MAX_LIGHTS
		)
		return true
	host._local_light_placement_pending = false
	host._selected_light_handle = new_index
	host.board.notify_look_changed()
	host._sync_light_handles_from_profile()
	host.local_light_handle_selected.emit(new_index)
	host.local_light_handle_changed.emit(
		new_index,
		host._authored_light_surface_position(new_index),
		host._authored_light_height_offset(new_index)
	)
	host.status_changed.emit(
		"Created '%s' on authored terrain; drag the cyan grip to set height."
		% host._light_name(new_index)
	)
	return true


## Start one unambiguous map-position drag from the picked emitter glob.
static func _begin_light_handle_drag(host: MTSStudioViewport, screen_position: Vector2) -> bool:
	var light_index := host._pick_light_handle(screen_position)
	if light_index < 0:
		return false
	host.select_local_light_handle(light_index)
	host.local_light_handle_selected.emit(light_index)
	host._light_drag_mode = MTSStudioViewport.LocalLightDragMode.SURFACE
	host._light_drag_index = light_index
	host._light_drag_start_surface_position = host._authored_light_surface_position(light_index)
	host._light_drag_start_height_offset = host._authored_light_height_offset(light_index)
	# A pointer drag owns continuous rendering until release; UPDATE_ONCE can
	# otherwise disable the SubViewport between mouse-motion samples.
	if host.sub_viewport != null:
		host.sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.status_changed.emit(
		"Moving '%s' smoothly across authored terrain — release to commit."
		% host._light_name(light_index)
	)
	return true


## Preview the exact continuous terrain point under the map-position pointer.
static func _continue_light_handle_drag(host: MTSStudioViewport, screen_position: Vector2) -> void:
	if host._light_drag_index < 0 or host._light_drag_mode != MTSStudioViewport.LocalLightDragMode.SURFACE:
		return
	var hit := host._local_light_surface_hit(screen_position)
	if hit.is_empty():
		return
	host._preview_local_light_transform(
		host._light_drag_index,
		hit["position"] as Vector3,
		host._authored_light_height_offset(host._light_drag_index)
	)


## Finish one already-applied surface or height drag as a single editor undo action.
static func _finish_light_handle_drag(host: MTSStudioViewport) -> void:
	if host._light_drag_mode == MTSStudioViewport.LocalLightDragMode.NONE:
		return
	var light_index := host._light_drag_index
	var before_surface := host._light_drag_start_surface_position
	var before_height := host._light_drag_start_height_offset
	var after_surface := host._authored_light_surface_position(light_index)
	var after_height := host._authored_light_height_offset(light_index)
	host._light_drag_mode = MTSStudioViewport.LocalLightDragMode.NONE
	host._light_drag_index = -1
	if host.sub_viewport != null:
		host.sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if (
		before_surface.is_equal_approx(after_surface)
		and is_equal_approx(before_height, after_height)
	):
		return
	host.board.notify_look_changed()
	if host._height_undo_redo != null:
		host._height_undo_redo.create_action(
			"Move local light on terrain: %s" % host._light_name(light_index),
			UndoRedo.MERGE_DISABLE,
			null,
			false
		)
		host._height_undo_redo.add_do_method(
			host,
			"_apply_authored_light_transform",
			light_index,
			after_surface,
			after_height
		)
		host._height_undo_redo.add_undo_method(
			host,
			"_apply_authored_light_transform",
			light_index,
			before_surface,
			before_height
		)
		# The profile already owns the final pointer values, so history records
		# the action without applying the same lighting rebuild a second time.
		host._height_undo_redo.commit_action(false)
	host.status_changed.emit(
		"Placed '%s' at surface (%.2f, %.2f, %.2f), height %.2f m."
		% [
			host._light_name(light_index),
			after_surface.x,
			after_surface.y,
			after_surface.z,
			after_height,
		]
	)


## Apply one exact local-light anchor and height for undo, redo, or another explicit action.
static func _apply_authored_light_transform(host: MTSStudioViewport,
	light_index: int,
	surface_position: Vector3,
	height_offset: float
) -> void:
	if host.board == null or light_index < 0 or light_index >= host.board.lighting.lights.size():
		push_error("[Tile Studio] Cannot move missing local light index %d." % light_index)
		return
	var lights: Array[Dictionary] = host.board.lighting.lights
	var entry: Dictionary = lights[light_index]
	entry["surface_position"] = surface_position
	entry["height_offset"] = clampf(
		height_offset,
		0.0,
		LightingProfile.MAX_LOCAL_LIGHT_HEIGHT_M
	)
	lights[light_index] = entry
	host.board.notify_look_changed()
	host.select_local_light_handle(light_index)
	host.local_light_handle_changed.emit(
		light_index,
		surface_position,
		float(entry["height_offset"])
	)


## Update canonical transform values and their two derived viewport manifestations during drag.
static func _preview_local_light_transform(host: MTSStudioViewport,
	light_index: int,
	surface_position: Vector3,
	height_offset: float
) -> void:
	if host.board == null or light_index < 0 or light_index >= host.board.lighting.lights.size():
		return
	var lights: Array[Dictionary] = host.board.lighting.lights
	var entry: Dictionary = lights[light_index]
	entry["surface_position"] = surface_position
	entry["height_offset"] = clampf(
		height_offset,
		0.0,
		LightingProfile.MAX_LOCAL_LIGHT_HEIGHT_M
	)
	lights[light_index] = entry
	host._update_light_handle_transform(light_index)
	var emitter_position := LightingProfile.local_light_world_position(entry)
	for child: Node in host.lights_root.get_children():
		if int(child.get_meta(MTSStudioViewport.LIGHT_INDEX_META, -1)) == light_index and child is Light3D:
			(child as Light3D).position = emitter_position
			break
	host.local_light_handle_changed.emit(
		light_index,
		surface_position,
		float(entry["height_offset"])
	)
	host.request_render()


## Pick the exact displayed terrain triangle continuously under the pointer.
##
## Light placement shares MTSTerrainRenderer's canonical face picker with prop
## placement and material painting. Sparse placement collision bodies caused
## freezes across gaps and multi-metre snaps when the next body was reached.
static func _local_light_surface_hit(host: MTSStudioViewport, screen_position: Vector2) -> Dictionary:
	if (
		host.camera == null
		or host.terrain_renderer == null
		or host.board == null
		or host.board.terrain.is_empty()
		or not Rect2(Vector2.ZERO, host.size).has_point(screen_position)
	):
		return {}
	var pick := host.terrain_renderer.pick_face(
		host.camera.project_ray_origin(screen_position),
		host.camera.project_ray_normal(screen_position)
	)
	if pick.is_empty():
		return {}
	return {
		"position": pick["point"],
		"normal": pick["normal"],
		"terrain_face": pick["face"],
	}


## Return the nearest visible emitter glob inside its fixed screen-space click radius.
static func _pick_light_handle(host: MTSStudioViewport, screen_position: Vector2) -> int:
	if host.camera == null:
		return -1
	var picked: int = -1
	var closest_squared := MTSStudioViewport.LIGHT_HANDLE_PICK_RADIUS_PX * MTSStudioViewport.LIGHT_HANDLE_PICK_RADIUS_PX
	for light_index: int in host._light_handle_nodes.size():
		var core := host._light_handle_nodes[light_index].get_node_or_null("Core") as MeshInstance3D
		if core == null:
			continue
		var world_position := core.global_position
		if host.camera.is_position_behind(world_position):
			continue
		var handle_screen := host.camera.unproject_position(world_position)
		var distance_squared := screen_position.distance_squared_to(handle_screen)
		if distance_squared <= closest_squared:
			closest_squared = distance_squared
			picked = light_index
	return picked


## Return one exact authored surface anchor without consulting derived scene nodes.
static func _authored_light_surface_position(host: MTSStudioViewport, light_index: int) -> Vector3:
	if host.board == null or light_index < 0 or light_index >= host.board.lighting.lights.size():
		return Vector3.ZERO
	return host.board.lighting.lights[light_index].get("surface_position", Vector3.ZERO)


## Return one exact authored height offset clamped to the visible panel's range.
static func _authored_light_height_offset(host: MTSStudioViewport, light_index: int) -> float:
	if host.board == null or light_index < 0 or light_index >= host.board.lighting.lights.size():
		return 0.0
	return clampf(
		float(host.board.lighting.lights[light_index].get("height_offset", 0.0)),
		0.0,
		LightingProfile.MAX_LOCAL_LIGHT_HEIGHT_M
	)


## Return a readable name for status and undo text without inventing a fallback light.
static func _light_name(host: MTSStudioViewport, light_index: int) -> String:
	if host.board == null or light_index < 0 or light_index >= host.board.lighting.lights.size():
		return "missing light"
	return String(host.board.lighting.lights[light_index].get("name", "Light"))


## Return the current board's single authoritative lighting profile.
static func _profile(host: MTSStudioViewport) -> LightingProfile:
	return host.board.lighting if host.board != null else null
