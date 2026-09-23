@tool
extends RefCounted

## Sculpt strokes behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Bind a sculptor to the live board terrain.
##
## The sculptor holds a direct reference to the canonical grid, so it is rebuilt
## whenever the board or its terrain resource is replaced.
static func _bind_terrain_sculptor(host: MTSStudioViewport) -> void:
	if host.board == null:
		host._terrain_sculptor = null
		return
	host._terrain_sculptor = TerrainSculptor.new(host.board.terrain)
	host._push_terrain_brush_settings()


## Push the visible brush values into the sculptor before a stroke uses them.
##
## Settings live in exactly one place at edit time: the UI writes these viewport
## fields, and this is the only path by which they reach a sculpt operation.
static func _push_terrain_brush_settings(host: MTSStudioViewport, flatten_target_m: float = 0.0) -> void:
	if host._terrain_sculptor == null:
		return
	var settings := TerrainSculptor.Settings.new()
	settings.mode = host._sculptor_mode_for_tool(host.height_sculpt_tool)
	# One canonical brush width: the toolbar's Brush width drives terrain targeting
	# and direct-texture stamping alike, so there is no second terrain-only size
	# that could disagree with the width the user can actually see.
	settings.size_m = float(host.surface_grid_stroke_size_m)
	settings.step_m = host.terrain_step_m
	settings.strength = host.height_brush_strength
	settings.flatten_target_m = flatten_target_m
	settings.protect_walls = host.terrain_protect_walls
	host._terrain_sculptor.configure(settings)


## Map one viewport sculpt tool to its single corresponding sculptor mode.
static func _sculptor_mode_for_tool(host: MTSStudioViewport, tool: int) -> int:
	match tool:
		MTSStudioViewport.HeightSculptTool.STEP_UP:
			return TerrainSculptor.Mode.STEP_UP
		MTSStudioViewport.HeightSculptTool.STEP_DOWN:
			return TerrainSculptor.Mode.STEP_DOWN
		MTSStudioViewport.HeightSculptTool.STEP_FLATTEN, MTSStudioViewport.HeightSculptTool.FLATTEN_FOOTPRINT:
			return TerrainSculptor.Mode.STEP_FLATTEN
		MTSStudioViewport.HeightSculptTool.STEP_SMOOTH:
			return TerrainSculptor.Mode.STEP_SMOOTH
		MTSStudioViewport.HeightSculptTool.LOWER:
			return TerrainSculptor.Mode.LOWER
		MTSStudioViewport.HeightSculptTool.FLATTEN:
			return TerrainSculptor.Mode.FLATTEN
		MTSStudioViewport.HeightSculptTool.SMOOTH:
			return TerrainSculptor.Mode.SMOOTH
		MTSStudioViewport.HeightSculptTool.QUANTIZE:
			return TerrainSculptor.Mode.QUANTIZE
		_:
			return TerrainSculptor.Mode.RAISE


## Begin one sculpt stroke and apply its first sample.
static func _begin_height_sculpt(host: MTSStudioViewport, mouse_pos: Vector2) -> void:
	var pick := host._update_height_brush_preview(mouse_pos)
	if not bool(pick.get("hit", false)):
		return
	if host.board == null or host.board.terrain.is_empty():
		push_error("[Tile Studio] Draw an encounter footprint before sculpting terrain.")
		return
	if host._terrain_sculptor == null:
		host._bind_terrain_sculptor()
	if host._terrain_sculptor == null:
		push_error("[Tile Studio] Terrain sculpt requested without a bound sculptor.")
		return
	var world_xz: Vector2 = pick["xz"]
	# Flatten samples its target once at stroke start so a drag pulls the whole
	# stroke toward the level the user actually clicked on.
	# Flatten footprint deliberately ignores the sampled elevation and returns the square to world zero.
	var flatten_target := (
		MTSStudioViewport.FOOTPRINT_FLATTEN_HEIGHT_M
		if host.height_sculpt_tool == MTSStudioViewport.HeightSculptTool.FLATTEN_FOOTPRINT
		else host.board.terrain.sample_world_height(world_xz, 0.0)
	)
	host._push_terrain_brush_settings(flatten_target)
	host._height_sculpting = true
	host._height_pending_motion = false
	host._height_repeat_elapsed_seconds = 0.0
	host._height_hold_repeating = false
	host._height_stroke_start_skirt_base_m = host.board.terrain.skirt_base_m
	host._last_height_stamp_xz = Vector2(INF, INF)
	host._terrain_dirty_cells = Rect2i()
	host._terrain_dirty_chunks.clear()
	host._terrain_sculptor.begin_stroke()
	host._apply_height_sculpt_stamp(world_xz)
	host._draw_height_brush_preview(pick)
	var cell: Vector3i = pick.get("cell", Vector3i.ZERO)
	host.hover_changed.emit(cell, true, "Terrain %s" % host.height_sculpt_tool_name().to_lower())


## Queue the latest sculpt pointer position for one bounded update this frame.
##
## Godot can deliver several mouse-motion events between rendered frames. Keeping
## only the newest endpoint avoids rebuilding the same terrain chunk repeatedly;
## the swept segment still covers every cell between the last applied point and it.
static func _queue_height_sculpt_motion(host: MTSStudioViewport, mouse_pos: Vector2) -> void:
	if not host._height_sculpting:
		host._update_height_brush_preview(mouse_pos)
		return
	host._height_pending_motion = true
	host._height_pending_mouse_position = mouse_pos


## Apply the latest queued pointer endpoint without changing the held cadence.
##
## Mouse devices can emit motion events while effectively stationary. The hold
## timer remains independent of that event rate so one cell keeps receiving
## pulses until the button is released.
static func _flush_pending_height_sculpt_motion(host: MTSStudioViewport) -> void:
	if not host._height_pending_motion:
		return
	var mouse_position := host._height_pending_mouse_position
	host._height_pending_motion = false
	host._continue_height_sculpt(mouse_position)


## Continue one stroke through an exact swept segment between rendered samples.
static func _continue_height_sculpt(host: MTSStudioViewport, mouse_pos: Vector2) -> void:
	var pick := host._update_height_brush_preview(mouse_pos)
	if not host._height_sculpting or pick.is_empty():
		return
	var world_xz: Vector2 = pick["xz"]
	if host._last_height_stamp_xz.x == INF:
		host._apply_height_sculpt_stamp(world_xz)
	elif not host._last_height_stamp_xz.is_equal_approx(world_xz):
		host._apply_height_sculpt_segment(host._last_height_stamp_xz, world_xz)
	host._draw_height_brush_preview(pick)
	var cell: Vector3i = pick.get("cell", Vector3i.ZERO)
	host.hover_changed.emit(cell, true, "Terrain %s" % host.height_sculpt_tool_name().to_lower())


## End the active stroke and register one compact undo action for it.
static func _end_height_sculpt(host: MTSStudioViewport) -> void:
	if not host._height_sculpting:
		return
	# Commit the newest pointer endpoint before closing the stroke so releasing
	# between rendered frames cannot drop the visible tail of the gesture.
	host._flush_pending_height_sculpt_motion()
	host._height_sculpting = false
	host._height_pending_motion = false
	host._height_repeat_elapsed_seconds = 0.0
	host._height_hold_repeating = false
	host._last_height_stamp_xz = Vector2(INF, INF)
	if host._terrain_sculptor == null:
		return
	var stroke := host._terrain_sculptor.finish_stroke()
	host._refresh_dynamic_skirt(host._height_stroke_start_skirt_base_m)
	host._finalize_terrain_region()
	host._register_terrain_sculpt_undo(stroke)


## Rebuild every boundary chunk once when a terrain edit moves the derived base.
static func _refresh_dynamic_skirt(host: MTSStudioViewport, previous_base_m: float) -> void:
	if host.terrain_renderer == null or host.board == null:
		return
	if is_equal_approx(previous_base_m, host.board.terrain.skirt_base_m):
		return
	var changed_chunks := host.terrain_renderer.refresh_visual_chunks(
		host.board.terrain,
		host.terrain_renderer.boundary_chunks(),
		host.surface_material_paint,
		host.board
	)
	for chunk: Vector2i in changed_chunks:
		host._terrain_dirty_chunks[chunk] = true
	host._apply_terrain_material_chunks(changed_chunks)


## Register one already-applied stroke with the editor's global history.
static func _register_terrain_sculpt_undo(host: MTSStudioViewport, stroke: Dictionary) -> void:
	if host._height_undo_redo == null or stroke.is_empty():
		return
	# A sculpt edit changes two things at once: the cells' own top faces and the
	# side faces along every seam around them. Both halves travel in the patch so
	# undo RESTORES the walls that were there rather than re-deriving walls from the
	# corner heights, which would quietly rewrite an imported map's authored walls.
	var cells_value: Variant = stroke.get("cells", PackedVector2Array())
	var before_tops: Variant = stroke.get("before_tops", PackedFloat32Array())
	var after_tops: Variant = stroke.get("after_tops", PackedFloat32Array())
	var before_sides: Variant = stroke.get("before_sides", {})
	var after_sides: Variant = stroke.get("after_sides", {})
	if (
		not cells_value is PackedVector2Array
		or not before_tops is PackedFloat32Array
		or not after_tops is PackedFloat32Array
		or not before_sides is Dictionary
		or not after_sides is Dictionary
	):
		push_error("[Tile Studio] Terrain stroke produced an invalid undo patch.")
		return
	var cells: PackedVector2Array = cells_value
	if cells.is_empty() and (before_sides as Dictionary).is_empty():
		return
	host._height_undo_redo.create_action(
		"Sculpt terrain: %s" % host.height_sculpt_tool_name(),
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	host._height_undo_redo.add_do_method(
		host,
		"_apply_terrain_sculpt_patch",
		cells,
		after_tops,
		after_sides
	)
	host._height_undo_redo.add_undo_method(
		host,
		"_apply_terrain_sculpt_patch",
		cells,
		before_tops,
		before_sides
	)
	# The live stroke is already canonical, so committing without execution avoids
	# redoing the writes and the terrain rebuild that followed them.
	host._height_undo_redo.commit_action(false)


## Apply one undo/redo terrain patch to only its affected terrain chunks.
static func _apply_terrain_sculpt_patch(host: MTSStudioViewport,
	cells: PackedVector2Array,
	tops: PackedFloat32Array,
	sides: Dictionary
) -> void:
	if host.board == null:
		push_error("[Tile Studio] Cannot replay a terrain patch without a bound board.")
		return
	if host._terrain_sculptor == null:
		host._bind_terrain_sculptor()
	if host._terrain_sculptor == null:
		return
	var previous_skirt_base := host.board.terrain.skirt_base_m
	var affected_cells := host._terrain_sculptor.apply_patch(cells, tops, sides)
	host._terrain_dirty_cells = affected_cells
	host._terrain_dirty_chunks.clear()
	host._preview_terrain_stroke(affected_cells)
	host._refresh_dynamic_skirt(previous_skirt_base)
	host._finalize_terrain_region()


## Apply one brush sample to the canonical terrain corners.
static func _apply_height_sculpt_stamp(host: MTSStudioViewport, world_xz: Vector2) -> void:
	if host._terrain_sculptor == null:
		return
	var touched := host._terrain_sculptor.stamp(world_xz)
	host._accumulate_terrain_dirty_cells(touched)
	host._last_height_stamp_xz = world_xz
	host._preview_terrain_stroke(touched)


## Apply one continuous swept segment to the canonical terrain corners.
static func _apply_height_sculpt_segment(host: MTSStudioViewport, start_world_xz: Vector2, end_world_xz: Vector2) -> void:
	if host._terrain_sculptor == null:
		return
	var touched := host._terrain_sculptor.stamp_segment(start_world_xz, end_world_xz)
	host._accumulate_terrain_dirty_cells(touched)
	host._last_height_stamp_xz = end_world_xz
	host._preview_terrain_stroke(touched)


## Grow the cell rectangle one in-progress stroke has invalidated.
static func _accumulate_terrain_dirty_cells(host: MTSStudioViewport, touched: Rect2i) -> void:
	if touched.size.x <= 0 or touched.size.y <= 0:
		return
	if host._terrain_dirty_cells.size.x <= 0 or host._terrain_dirty_cells.size.y <= 0:
		host._terrain_dirty_cells = touched
	else:
		host._terrain_dirty_cells = host._terrain_dirty_cells.merge(touched)


## Show the in-progress stroke without paying for the full derived rebuild.
##
## Material mask ranges are deliberately deferred to stroke end because they
## depend on the finished surface; recomputing them per pointer event would make
## a drag progressively slower on a large encounter map.
static func _preview_terrain_stroke(host: MTSStudioViewport, affected_cells: Rect2i) -> void:
	if host.terrain_renderer == null or host.board == null:
		return
	var changed_chunks := host.terrain_renderer.refresh_visual_region(
		host.board.terrain,
		affected_cells,
		host.surface_material_paint,
		host.board
	)
	for chunk: Vector2i in changed_chunks:
		host._terrain_dirty_chunks[chunk] = true
	host._apply_terrain_material_chunks(changed_chunks)
	host.request_render()


## Release authored material whose terrain face disappeared in an optional cell scope.
##
## Sculpting supplies its dirty rectangle so paint cleanup remains local. Clearing
## the complete terrain omits the scope because every face must then be reconciled.
static func _reconcile_terrain_paint(host: MTSStudioViewport, affected_cells: Rect2i = Rect2i()) -> void:
	if host.board == null:
		return
	var released := host.board.prune_orphaned_terrain_paint(affected_cells)
	if released.is_empty():
		return
	if host.surface_material_paint != null:
		host.surface_material_paint.discard_paint_for_uids(released)
	# The board's saved sidecar metadata is rebuilt from live images on save, but
	# dropping the entries now keeps the in-memory document honest immediately.
	var surviving: Array = []
	for entry_value: Variant in host.board.surface_material_paint.get("surfaces", []) as Array:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		if not released.has(String(entry.get("uid", ""))):
			surviving.append(entry)
	if host.board.surface_material_paint.has("surfaces"):
		host.board.surface_material_paint["surfaces"] = surviving


## Finalize collision and derived regional data once for the completed edit.
static func _finalize_terrain_region(host: MTSStudioViewport) -> void:
	if host.board == null:
		return
	var changed_chunks: Array[Vector2i] = []
	for chunk_value: Variant in host._terrain_dirty_chunks.keys():
		changed_chunks.append(chunk_value as Vector2i)
	if host.terrain_renderer != null:
		host.terrain_renderer.finalize_collision_chunks(changed_chunks)
	# Sculpting can remove side bands without deleting top cells. Reconcile only the
	# dirty rectangle so vanished wall paint is released without a full-board scan.
	host._reconcile_terrain_paint(host._terrain_dirty_cells)
	if host.world_surface_fields != null and host._terrain_dirty_cells.size.x > 0:
		var coverage_expanded := host._ensure_world_surface_field_coverage()
		if coverage_expanded:
			# A resized texture changes every UV, so repopulating it is the one
			# explicit case where a complete projection is actually required.
			host.world_surface_fields.project_terrain(host.board.terrain)
		elif not host.board.terrain.is_empty():
			host.world_surface_fields.project_terrain_region(
				host.board.terrain,
				host._terrain_dirty_cells
			)
	# The ground moved, so every prop's derived base level may have moved with it.
	# Re-deriving the occupancy index here keeps the solid voxels, the stored base
	# levels and the artwork re-posed below on one answer; without it a later removal
	# would compute different keys from the ones the prop was indexed under.
	host.board.rebuild_indexes()
	host._sync_prop_support_offsets()
	# A shader decal needs no geometry resync: its derived face arrays are rebuilt
	# when the terrain material is rebound, and its relief remains material parallax
	# over the canonical terrain triangles.
	# Markers and ground-attached effects derive their height from the terrain, so
	# they are re-derived here for the same reason prop support is re-synced above.
	host._rebuild_gameplay_marker_visuals()
	host._rebuild_particle_effect_visuals()
	host._refresh_material_mask_ranges(true)
	host.terrain_changed.emit()
	host._terrain_dirty_cells = Rect2i()
	host._terrain_dirty_chunks.clear()
	host.request_render()
