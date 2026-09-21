@tool
extends RefCounted

## Framing behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Frame the primary selection from exact collision-derived geometry.
static func _frame_selection(host: MTSStudioViewport) -> void:
	if host.placement.selected != null:
		var collision_points := host._placement_collision_points(host.placement.selected)
		if not collision_points.is_empty():
			host.camera.frame_aabb(host._placement_collision_aabb(host.placement.selected))
			return
	host.camera.frame_point(Vector3(host.placement.hovered_cell) + Vector3(0.5, 0, 0.5))


static func _find_visual(host: MTSStudioViewport, target: Resource) -> Node3D:
	for root: Node3D in [
		host.surfaces_root,
		host.props_root,
		host.gameplay_markers_root,
	]:
		for child in root.get_children():
			var node := child as Node3D
			if node != null and node.get_meta("mts_placement", null) == target:
				return node
	return null


static func frame_board(host: MTSStudioViewport) -> void:
	host._frame_board_from_bounds(host._board_bounds())


## Frame one supplied board bound so a full rebuild does not calculate it again.
static func _frame_board_from_bounds(host: MTSStudioViewport, bounds: AABB) -> void:
	if host.board == null or host.board.is_empty():
		host.camera.frame_point(Vector3.ZERO, MTSStudioViewport.K.ISO_DEFAULT_ORTHO_SIZE)
		return
	host.camera.frame_aabb(bounds)


## Return the rebuild-scoped board bounds or calculate them for an independent action.
static func _board_bounds(host: MTSStudioViewport) -> AABB:
	if host._full_rebuild_has_bounds:
		return host._full_rebuild_bounds
	return host.board.compute_bounds() if host.board != null else AABB()


## Forward the canonical PlacementController hover state to the editor shell.
static func _on_hover_changed(host: MTSStudioViewport, cell: Vector3i, valid: bool, reason: String) -> void:
	host.hover_changed.emit(cell, valid, reason)
	host.request_render()


## Forward exact particle preview coordinates to the editor status bar.
static func _on_particle_hover_changed(host: MTSStudioViewport,
	position: Vector3,
	valid: bool,
	reason: String
) -> void:
	host.particle_hover_changed.emit(position, valid, reason)
	host.request_render()


static func _emit_status(host: MTSStudioViewport) -> void:
	var counts := "0 surfaces / 0 props / 0 markers / 0 particles"
	if host.board != null:
		counts = "%d surfaces / %d props / %d markers / %d packs / %d particles" % [
			host.board.surfaces.size(),
			host.board.props.size(),
			host.board.gameplay_markers.size(),
			host.board.enemy_packs.size(),
			host.board.particle_effects.size(),
		]
	var overlay := ""
	if host.occupancy_overlay != null and host.occupancy_overlay.mode != MTSStudioViewport.OccupancyOverlay.Mode.OFF:
		overlay = " | occupancy %s" % host.occupancy_overlay.mode_name()
	# Non-default placement modes state both their behavior and current data.
	if host.particle_effects != null and host.particle_effects.active:
		overlay += " | PARTICLE %s" % (
			"ERASE" if host.particle_effects.erase_mode else "PLACE"
		)
	elif host.gameplay_markers != null and host.gameplay_markers.active:
		overlay += " | GAMEPLAY MARKERS"
	elif (host.splatmap_tile_paint_enabled or host.material_tile_paint_enabled) and host.placement != null:
		var tile_mode_name := (
			"SPLATMAP BASE COAT | all RGBA channels"
			if host.splatmap_tile_paint_enabled
			else "LAYER MATERIAL TILE | selected RGBA slot"
		)
		overlay += " | %s width=%dm" % [tile_mode_name, host.surface_grid_stroke_size_m]
		if host.material_tile_paint_enabled:
			overlay += " | PNG rotation=%d°" % (host.material_layer_rotation_quarters() * 90)
		overlay += " | REPLACE %s" % ("ON" if host.placement.replace_enabled else "OFF")
		if host.placement.tool == MTSPlacementController.Tool.FILL:
			overlay += " | FILL %s | %d points | %d ready / %d blocked" % [
				host.placement.fill_shape_name(),
				host.placement.fill_vertex_count(),
				host.placement.fill_valid_count(),
				host.placement.fill_blocked_count(),
			]
			overlay += " | Enter commit | right-click/Backspace undo | Esc cancel"
		elif host.placement.tool == MTSPlacementController.Tool.ERASE:
			overlay += " | ERASE"
		else:
			overlay += " | left paint | right erase"
	elif host.placement != null and host.placement.tool == MTSPlacementController.Tool.ERASE:
		overlay += " | ERASE"
	elif host.placement != null and host.placement.tool == MTSPlacementController.Tool.SELECT:
		overlay += (
			" | SELECT %d | drag move | Left/Right yaw 45 | Up/Down pitch 90"
			+ " | Shift+Left/Right roll 90 | Shift+F flip | Delete remove"
		) % host.placement.selected_resources().size()
	elif host.placement != null and host.placement.tool == MTSPlacementController.Tool.FILL:
		overlay += " | FILL %s | %d points | %d ready / %d blocked" % [
			host.placement.fill_shape_name(),
			host.placement.fill_vertex_count(),
			host.placement.fill_valid_count(),
			host.placement.fill_blocked_count(),
		]
		overlay += " | Enter commit | right-click/Backspace undo | Esc cancel"
	if host.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
		overlay += " | FOOTPRINT %s | %d cells" % [
			host.footprint_tool_name(),
			host.board.terrain.filled_cell_count() if host.board != null else 0,
		]
	if host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE:
		overlay += " | TERRAIN %s width=%dm step=%.2fm strength=%.2f%s" % [
			host.height_sculpt_tool_name(),
			host.surface_grid_stroke_size_m,
			host.terrain_step_m,
			host.height_brush_strength,
			" | WALLS PROTECTED" if host.terrain_protect_walls else "",
		]
	if host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE:
		overlay += " | MATERIAL BRUSH r=%.2fm | PNG rotation=%d° | left paint | right erase" % [
			host.material_brush_radius_m,
			host.material_layer_rotation_quarters() * 90,
		]
	if host.camera != null:
		if host.camera.is_isometric():
			overlay += " | CAMERA FIXED ISO %d/%d (%s) | Q/E TURN" % [
				host.camera.get_fixed_isometric_direction_index() + 1,
				MTSCameraController.FIXED_ISOMETRIC_DIRECTION_COUNT,
				host.camera.get_fixed_isometric_direction_label(),
			]
		elif host.camera.is_rotatable_isometric():
			overlay += " | CAMERA ROTATABLE ISO"
		elif host.camera.is_top_down():
			overlay += " | CAMERA TOP DOWN"
	var terrain_summary := "no terrain"
	if host.board != null and not host.board.terrain.is_empty():
		terrain_summary = "terrain %d cells" % host.board.terrain.filled_cell_count()
	host.status_changed.emit("%s | %s%s" % [terrain_summary, counts, overlay])
