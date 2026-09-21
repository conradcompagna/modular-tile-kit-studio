@tool
extends RefCounted

## Sculpt settings behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Select one explicit terrain sculpt mode.
##
## Selecting a sculpt tool leaves the footprint and material tools, because the
## three are separate authoring steps that must not receive the same drag.
static func set_height_sculpt_tool(host: MTSStudioViewport, tool: int) -> void:
	host._end_height_sculpt()
	host.height_sculpt_tool = clampi(tool, MTSStudioViewport.HeightSculptTool.NONE, MTSStudioViewport.HeightSculptTool.FLATTEN_FOOTPRINT)
	if host.height_sculpt_tool == MTSStudioViewport.HeightSculptTool.NONE:
		host._hide_height_brush_preview()
	else:
		host._update_height_brush_preview(host._last_mouse)
	if host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE:
		if host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE:
			host._end_material_paint()
			host.material_paint_tool = MTSStudioViewport.MaterialPaintTool.NONE
			host._hide_material_brush_preview()
			host.material_paint_tool_changed.emit(host.material_paint_tool)
		if host.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
			host._end_footprint_stroke()
			host.footprint_tool = MTSStudioViewport.FootprintTool.NONE
			host.footprint_tool_changed.emit(host.footprint_tool)
	host._push_terrain_brush_settings()
	host._sync_terrain_fill_arming()
	host._refresh_placement_visibility()
	if host.placement != null and host.placement.visible:
		host.placement.update_hover(host.camera, host._last_mouse)
	# Picking a sculpt tool deliberately changes NO look setting. Terrain elevation
	# is real geometry now, so it is visible whether or not placed surfaces are
	# configured to follow the ground; silently flipping a rendering toggle here was
	# hidden state the UI never showed.
	host.height_sculpt_tool_changed.emit(host.height_sculpt_tool)
	host._emit_status()
	host.request_render()


## Tell the placement controller whether Fill should commit a terrain shape.
##
## Terrain Fill is armed exactly when a terrain tool is selected, so the Terrain
## panel's visible tool is the single thing that decides what Fill will do. Only
## Footprint Draw may create cells; every other terrain tool edits existing ones.
##
## `p_placement_tool` is passed explicitly because set_tool() calls this BEFORE
## delegating to the controller, so the controller's own `tool` is still stale.
static func _sync_terrain_fill_arming(host: MTSStudioViewport, p_placement_tool: int = -1) -> void:
	if host.placement == null:
		return
	var active_tool := (
		p_placement_tool
		if p_placement_tool >= 0
		else host.placement.tool
	)
	var terrain_active := (
		host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE
		or host.footprint_tool != MTSStudioViewport.FootprintTool.NONE
	)
	host.placement.set_terrain_fill(
		terrain_active and active_tool == MTSPlacementController.Tool.FILL,
		host.footprint_tool == MTSStudioViewport.FootprintTool.DRAW
	)


## Apply one committed terrain Fill shape as a single undoable stroke.
##
## Fill reuses the ordinary stroke machinery rather than a parallel edit path: the
## same sculptor, the same dirty-region rebuild, and the same undo patch a dragged
## stroke produces. Each cell receives exactly ONE application, so filling with
## Raise moves every cell by one increment just as one click of the brush would.
static func _commit_terrain_fill(host: MTSStudioViewport, origins: Array[Vector3i]) -> void:
	if host.board == null or origins.is_empty():
		return
	if host.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
		host._commit_footprint_fill(origins)
		return
	if host.height_sculpt_tool == MTSStudioViewport.HeightSculptTool.NONE:
		return
	if host._terrain_sculptor == null:
		host._bind_terrain_sculptor()
	if host._terrain_sculptor == null:
		return

	# Flatten samples its target once for the whole shape, exactly as a drag does
	# at mouse-down, so every filled cell converges on one plane.
	# Fill mode obeys the same explicit zero plane as an ordinary flatten-footprint stroke.
	var flatten_target := (
		MTSStudioViewport.FOOTPRINT_FLATTEN_HEIGHT_M
		if host.height_sculpt_tool == MTSStudioViewport.HeightSculptTool.FLATTEN_FOOTPRINT
		else host._sample_terrain_flatten_target(origins)
	)
	host._push_terrain_brush_settings(flatten_target)
	var previous_skirt_base := host.board.terrain.skirt_base_m
	host._terrain_dirty_cells = Rect2i()
	host._terrain_dirty_chunks.clear()
	host._terrain_sculptor.begin_stroke()
	for origin: Vector3i in origins:
		# The centre of the cell, because the sculptor addresses brush samples in
		# world XZ and its own footprint expansion re-derives the square from there.
		var centre := Vector2(float(origin.x) + 0.5, float(origin.z) + 0.5)
		host._accumulate_terrain_dirty_cells(host._terrain_sculptor.stamp(centre))
	var stroke := host._terrain_sculptor.finish_stroke()
	host._preview_terrain_stroke(host._terrain_dirty_cells)
	host._refresh_dynamic_skirt(previous_skirt_base)
	host._finalize_terrain_region()
	host._register_terrain_sculpt_undo(stroke)
	host._emit_status()


## Return the level a filled Flatten shape converges on: its first editable cell.
##
## One sample for the whole shape is what makes Fill + Flatten produce a single
## plane. Sampling per cell would flatten each cell to its own height, which is
## no change at all.
static func _sample_terrain_flatten_target(host: MTSStudioViewport, origins: Array[Vector3i]) -> float:
	for origin: Vector3i in origins:
		var cell := Vector2i(origin.x, origin.z)
		if host.board.terrain.is_cell_filled(cell):
			return host.board.terrain.cell_walk_height(cell)
	return 0.0


## Apply one committed Fill shape as a footprint draw or erase stroke.
static func _commit_footprint_fill(host: MTSStudioViewport, origins: Array[Vector3i]) -> void:
	# Each Fill origin is one brush stamp, so it expands through the SAME canonical
	# square a dragged footprint stroke uses. Passing the bare origins would have
	# made a wide brush fill a sparse lattice instead of a solid region.
	var targets := PackedVector2Array()
	var included: Dictionary = {}
	for origin: Vector3i in origins:
		var centre := Vector2(float(origin.x) + 0.5, float(origin.z) + 0.5)
		for target: Vector2 in host._footprint_targets(centre, centre):
			var cell := Vector2i(target)
			if included.has(cell):
				continue
			included[cell] = true
			targets.append(target)
	if targets.is_empty():
		return
	# _end_footprint_stroke() is the one place that builds the footprint undo entry
	# and finalizes the region, so the Fill commit enters and leaves through the
	# same drag state rather than duplicating that logic.
	host._footprint_drawing = true
	host._footprint_erasing = host.footprint_tool == MTSStudioViewport.FootprintTool.ERASE
	host._footprint_stroke_cells.clear()
	host._footprint_stroke_before.clear()
	host._footprint_stroke_start_skirt_base_m = host.board.terrain.skirt_base_m
	host._terrain_dirty_cells = Rect2i()
	host._terrain_dirty_chunks.clear()
	host._apply_footprint_targets(targets)
	host._end_footprint_stroke()
	host._emit_status()


## Set whether the slope brushes are forbidden from moving corners that carry walls.
static func set_terrain_protect_walls(host: MTSStudioViewport, enabled: bool) -> void:
	host.terrain_protect_walls = enabled
	host._push_terrain_brush_settings()
	host._emit_status()


## Clamp the fixed level increment used by the step and quantize modes.
##
## This is the sculpt level height: every stepped corner lands on an exact
## multiple of it, which is what lets separately drawn areas meet flush.
static func set_terrain_step(host: MTSStudioViewport, step_m: float) -> void:
	host.terrain_step_m = clampf(step_m, 0.05, 8.0)
	host._push_terrain_brush_settings()
	host._emit_status()


## Clamp the blend strength used by the continuous sculpt modes.
static func set_height_brush_strength(host: MTSStudioViewport, strength: float) -> void:
	host.height_brush_strength = clampf(strength, 0.01, 1.0)
	host._push_terrain_brush_settings()
	host._emit_status()


## Select one explicit footprint drawing mode.
static func set_footprint_tool(host: MTSStudioViewport, tool: int) -> void:
	host._end_footprint_stroke()
	host.footprint_tool = clampi(tool, MTSStudioViewport.FootprintTool.NONE, MTSStudioViewport.FootprintTool.ERASE)
	if host.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
		# Footprint editing and sculpting are separate authoring steps, so
		# entering one always leaves the other.
		if host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE:
			host.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.NONE)
		if host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE:
			host._end_material_paint()
			host.material_paint_tool = MTSStudioViewport.MaterialPaintTool.NONE
			host._hide_material_brush_preview()
			host.material_paint_tool_changed.emit(host.material_paint_tool)
	host._sync_terrain_fill_arming()
	host._refresh_placement_visibility()
	if host.footprint_tool == MTSStudioViewport.FootprintTool.NONE:
		host._hide_height_brush_preview()
	else:
		host._update_footprint_brush_preview(host._last_mouse)
	host.footprint_tool_changed.emit(host.footprint_tool)
	host._emit_status()
	host.request_render()


## Return a stable display name for the active footprint mode.
static func footprint_tool_name(host: MTSStudioViewport) -> String:
	match host.footprint_tool:
		MTSStudioViewport.FootprintTool.DRAW:
			return "DRAW"
		MTSStudioViewport.FootprintTool.ERASE:
			return "ERASE"
		_:
			return "OFF"


## Return a stable display name for the active transient sculpt mode.
static func height_sculpt_tool_name(host: MTSStudioViewport) -> String:
	match host.height_sculpt_tool:
		MTSStudioViewport.HeightSculptTool.STEP_UP:
			return "STEPPED RAISE"
		MTSStudioViewport.HeightSculptTool.STEP_DOWN:
			return "STEPPED LOWER"
		MTSStudioViewport.HeightSculptTool.STEP_FLATTEN:
			return "STEPPED FLATTEN"
		MTSStudioViewport.HeightSculptTool.STEP_SMOOTH:
			return "STEPPED SMOOTH"
		MTSStudioViewport.HeightSculptTool.FLATTEN_FOOTPRINT:
			return "FLATTEN FOOTPRINT"
		MTSStudioViewport.HeightSculptTool.RAISE:
			return "RAISE"
		MTSStudioViewport.HeightSculptTool.LOWER:
			return "LOWER"
		MTSStudioViewport.HeightSculptTool.FLATTEN:
			return "FLATTEN"
		MTSStudioViewport.HeightSculptTool.SMOOTH:
			return "SMOOTH"
		MTSStudioViewport.HeightSculptTool.QUANTIZE:
			return "ANGULAR"
		_:
			return "OFF"
