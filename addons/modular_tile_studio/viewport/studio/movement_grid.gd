@tool
extends RefCounted

## Movement grid behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Activate movement-cell authoring and its temporary shaded grid overlay.
##
## Closing the panel disables this mode, ensuring the shading is editor chrome
## rather than hidden board rendering state.
static func set_movement_grid_mode(host: MTSStudioViewport, active: bool) -> void:
	host._movement_grid_active = active
	host.set_occupancy_mode(
		MTSStudioViewport.OccupancyOverlay.Mode.MOVEMENT_GRID
		if active
		else MTSStudioViewport.OccupancyOverlay.Mode.OFF
	)
	if active:
		host._update_movement_grid_hover(host._last_mouse)


## Return whether the movement panel currently owns cell input.
static func movement_grid_mode_active(host: MTSStudioViewport) -> bool:
	return host._movement_grid_active


## Select the next movement-cell action without mutating the board.
static func set_movement_grid_tool(host: MTSStudioViewport, tool: int) -> void:
	host._movement_grid_tool = clampi(
		tool,
		MTSStudioViewport.MovementGridTool.BLOCK,
		MTSStudioViewport.MovementGridTool.CLEAR_EFFECT
	)
	if host._movement_grid_active:
		host._update_movement_grid_hover(host._last_mouse)


## Stage the plain ground-effect label used by the Set Effect action.
static func set_movement_ground_effect_label(host: MTSStudioViewport, label: String) -> void:
	host._movement_ground_effect_label = label.strip_edges()
	if host._movement_grid_active:
		host._update_movement_grid_hover(host._last_mouse)


## Validate and atomically apply the board-wide GLB collision threshold.
static func apply_movement_collision_threshold(host: MTSStudioViewport, threshold_percent: float) -> Dictionary:
	if host.board == null:
		return {"valid": false, "errors": PackedStringArray(["No board is bound."])}
	var report := host.board.movement_collision_filter_report(threshold_percent)
	if not bool(report.get("valid", false)):
		host.status_changed.emit("Movement collision filter was not applied.")
		return report
	var before := host.board.movement_collision_min_triangle_share_percent
	var after := float(report["threshold_percent"])
	if is_equal_approx(before, after):
		return report
	if host._height_undo_redo == null:
		host._apply_movement_collision_threshold(after)
		return report
	host._height_undo_redo.create_action(
		"Set global movement collision filter",
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	host._height_undo_redo.add_do_method(
		host,
		"_apply_movement_collision_threshold",
		after
	)
	host._height_undo_redo.add_undo_method(
		host,
		"_apply_movement_collision_threshold",
		before
	)
	host._height_undo_redo.commit_action()
	return report


## Apply one collision threshold during direct editing, undo, or redo.
static func _apply_movement_collision_threshold(host: MTSStudioViewport, threshold_percent: float) -> void:
	if host.board == null:
		return
	var report := host.board.set_movement_collision_min_triangle_share_percent(
		threshold_percent
	)
	if not bool(report.get("valid", false)):
		push_error("[Tile Studio] movement collision threshold replay failed.")
		return
	host.refresh_movement_grid_collision()


## Rebuild only prop spatial roots and the movement overlay after collision filtering.
##
## Terrain meshes, surface materials, lighting, and unrelated assets remain
## untouched; every placed prop root is marked stale because the rule is global.
static func refresh_movement_grid_collision(host: MTSStudioViewport) -> void:
	if host.board == null:
		return
	host.board.rebuild_indexes()
	host._voxel_mesh_cache.clear()
	for prop: PropPlacement in host.board.props:
		var node := host._prop_nodes_by_placement_id.get(
			prop.get_instance_id(),
			null
		) as Node3D
		if is_instance_valid(node):
			node.set_meta("mts_spatial_signature", "stale-movement-collision")
	host._sync_board_incremental(MTSStudioViewport.PlacementController.BoardMutation.PROPS)
	if host.occupancy_overlay != null:
		host.occupancy_overlay.rebuild()
	host._emit_status()
	host.request_render()


## Consume movement-grid pointer input before ordinary placement tools.
static func _handle_movement_grid_input(host: MTSStudioViewport, event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		if host.camera != null and host.camera.is_panning():
			return false
		var motion := event as InputEventMouseMotion
		host._last_mouse = motion.position
		host._update_movement_grid_hover(motion.position)
		return true
	if not event is InputEventMouseButton:
		return false
	var button := event as InputEventMouseButton
	if button.button_index in [
		MOUSE_BUTTON_MIDDLE,
		MOUSE_BUTTON_WHEEL_UP,
		MOUSE_BUTTON_WHEEL_DOWN,
	]:
		return false
	if button.button_index == MOUSE_BUTTON_LEFT:
		host._last_mouse = button.position
		host._update_movement_grid_hover(button.position)
		if button.pressed:
			host._commit_movement_grid_cell(button.position)
		return true
	if button.button_index == MOUSE_BUTTON_RIGHT:
		return true
	return false


## Pick one top terrain cell through the renderer's canonical triangle data.
static func _movement_grid_hit(host: MTSStudioViewport, mouse_position: Vector2) -> Dictionary:
	if (
		host.camera == null
		or host.terrain_renderer == null
		or host.board == null
		or host.board.terrain.is_empty()
		or not Rect2(Vector2.ZERO, host.size).has_point(mouse_position)
	):
		return {}
	var pick := host.terrain_renderer.pick_face(
		host.camera.project_ray_origin(mouse_position),
		host.camera.project_ray_normal(mouse_position)
	)
	if pick.is_empty() or bool(pick.get("is_wall", false)):
		return {}
	var face := pick["face"] as Dictionary
	var grid_cell: Vector3i = face["grid_cell"]
	var cell := Vector2i(grid_cell.x, grid_cell.z)
	if not host.board.movement_cell_exists(cell):
		return {}
	return {
		"cell": cell,
		"point": pick["point"],
	}


## Publish movement state for the exact terrain cell under the pointer.
static func _update_movement_grid_hover(host: MTSStudioViewport, mouse_position: Vector2) -> void:
	var hit := host._movement_grid_hit(mouse_position)
	if hit.is_empty():
		host.hover_changed.emit(Vector3i.ZERO, false, "Move over a terrain top cell.")
		host.request_render()
		return
	var cell: Vector2i = hit["cell"]
	var state := host.board.movement_cell_state(cell)
	var reason := (
		"Movement cell (%d, %d): %s"
		% [
			cell.x,
			cell.y,
			"manually unwalkable"
			if bool(state.get("unwalkable", false))
			else "automatic walkability",
		]
	)
	var effect := String(state.get("ground_effect", ""))
	if not effect.is_empty():
		reason += " | effect: %s" % effect
	host.hover_changed.emit(
		Vector3i(
			cell.x,
			TerrainMesh.level_of_height(float((hit["point"] as Vector3).y)),
			cell.y
		),
		true,
		reason
	)
	host.request_render()


## Turn the current movement action into one undoable canonical cell edit.
static func _commit_movement_grid_cell(host: MTSStudioViewport, mouse_position: Vector2) -> void:
	var hit := host._movement_grid_hit(mouse_position)
	if hit.is_empty():
		host.status_changed.emit("Movement Grid: click a terrain top cell.")
		return
	var cell: Vector2i = hit["cell"]
	var before := host.board.movement_cell_state(cell)
	var after := before.duplicate(true)
	match host._movement_grid_tool:
		MTSStudioViewport.MovementGridTool.BLOCK:
			after["unwalkable"] = true
		MTSStudioViewport.MovementGridTool.RESTORE_AUTO:
			after["unwalkable"] = false
		MTSStudioViewport.MovementGridTool.SET_EFFECT:
			if host._movement_ground_effect_label.is_empty():
				host.status_changed.emit("Movement Grid: enter a ground-effect label first.")
				return
			after["ground_effect"] = host._movement_ground_effect_label
		MTSStudioViewport.MovementGridTool.CLEAR_EFFECT:
			after["ground_effect"] = ""
	if before == after:
		host.movement_grid_cell_changed.emit(cell, before)
		return
	if host._height_undo_redo == null:
		host._apply_movement_cell_state(cell, after)
		return
	host._height_undo_redo.create_action(
		"Edit movement cell",
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	host._height_undo_redo.add_do_method(
		host,
		"_apply_movement_cell_state",
		cell,
		after
	)
	host._height_undo_redo.add_undo_method(
		host,
		"_apply_movement_cell_state",
		cell,
		before
	)
	host._height_undo_redo.commit_action()


## Replay one movement cell from canonical state during direct editing, undo, or redo.
static func _apply_movement_cell_state(host: MTSStudioViewport, cell: Vector2i, state: Dictionary) -> void:
	if host.board == null:
		return
	host.board.apply_movement_cell_state(cell, state)
	if host.occupancy_overlay != null:
		host.occupancy_overlay.rebuild()
	host.movement_grid_cell_changed.emit(cell, host.board.movement_cell_state(cell))
	host._update_movement_grid_hover(host._last_mouse)
	host.request_render()
