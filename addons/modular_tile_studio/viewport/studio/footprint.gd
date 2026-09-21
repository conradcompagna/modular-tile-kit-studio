@tool
extends RefCounted

## Footprint behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Return the cell-centred footprint address under one viewport point.
static func _footprint_pick(host: MTSStudioViewport, mouse_pos: Vector2) -> Dictionary:
	var pick := host._height_brush_pick(mouse_pos)
	if not bool(pick.get("hit", false)):
		return {"hit": false}
	var point: Vector3 = pick.get("point", Vector3.ZERO)
	var cell := Vector2i(floori(point.x), floori(point.z))
	return {
		"hit": true,
		"cell": cell,
		"xz": Vector2(cell) + Vector2(0.5, 0.5),
		"point": point,
	}


## Return the one canonical cell footprint used by preview and mutation.
static func _footprint_targets(host: MTSStudioViewport,
	start_world_xz: Vector2,
	end_world_xz: Vector2
) -> PackedVector2Array:
	return TerrainSculptor.brush_cell_targets(
		start_world_xz,
		end_world_xz,
		float(host.surface_grid_stroke_size_m)
	)


## Pick and display Footprint Draw/Erase with the shared terrain targeter look.
static func _update_footprint_brush_preview(host: MTSStudioViewport, mouse_position: Vector2) -> Dictionary:
	if host.footprint_tool == MTSStudioViewport.FootprintTool.NONE or host.board == null:
		host._hide_height_brush_preview()
		return {}
	var pick := host._footprint_pick(mouse_position)
	if not bool(pick.get("hit", false)):
		host._hide_height_brush_preview()
		return {}
	host._draw_footprint_brush_preview(pick)
	return pick


## Draw exactly the cells one stationary footprint stamp would commit.
static func _draw_footprint_brush_preview(host: MTSStudioViewport, pick: Dictionary) -> void:
	if not is_instance_valid(host._height_brush_preview):
		return
	var targets := host._footprint_targets(pick["xz"], pick["xz"])
	var immediate_mesh := host._height_brush_preview.mesh as ImmediateMesh
	immediate_mesh.clear_surfaces()
	if targets.is_empty():
		host._hide_height_brush_preview()
		return
	host._draw_height_cell_targets(immediate_mesh, targets)
	host._height_brush_preview.visible = true
	host.request_render()


## Begin one footprint drag that draws or erases encounter cells.
static func _begin_footprint_stroke(host: MTSStudioViewport, mouse_pos: Vector2, erase: bool) -> void:
	if host.board == null:
		return
	var pick := host._update_footprint_brush_preview(mouse_pos)
	if pick.is_empty():
		return
	host._footprint_drawing = true
	host._footprint_erasing = erase
	host._footprint_stroke_cells.clear()
	host._footprint_stroke_before.clear()
	host._last_footprint_stamp_xz = pick["xz"]
	host._footprint_stroke_start_skirt_base_m = host.board.terrain.skirt_base_m
	host._terrain_dirty_cells = Rect2i()
	host._terrain_dirty_chunks.clear()
	host._apply_footprint_targets(host._footprint_targets(pick["xz"], pick["xz"]))
	host._draw_footprint_brush_preview(pick)


## Continue one footprint drag across every cell the pointer crosses.
static func _continue_footprint_stroke(host: MTSStudioViewport, mouse_pos: Vector2) -> void:
	var pick := host._update_footprint_brush_preview(mouse_pos)
	if not host._footprint_drawing or pick.is_empty():
		return
	var world_xz: Vector2 = pick["xz"]
	host._apply_footprint_targets(host._footprint_targets(host._last_footprint_stamp_xz, world_xz))
	host._last_footprint_stamp_xz = world_xz
	host._draw_footprint_brush_preview(pick)


## Draw or erase the exact canonical target list, expanding only for Draw.
static func _apply_footprint_targets(host: MTSStudioViewport, targets: PackedVector2Array) -> void:
	if host.board == null or targets.is_empty():
		return
	var area := Rect2i(Vector2i(targets[0]), Vector2i.ONE)
	for target: Vector2 in targets:
		area = area.merge(Rect2i(Vector2i(target), Vector2i.ONE))
	if not host._footprint_erasing:
		# Drawing outside the allocated lattice grows it; erasing never does,
		# because removing cells cannot require new storage.
		if host.board.terrain.is_empty():
			host.board.terrain = TerrainMesh.create(area.position, area.size)
			host._bind_terrain_sculptor()
		else:
			host.board.terrain.expand_to_include(area)
	var changed_cells := Rect2i()
	for target: Vector2 in targets:
		var cell := Vector2i(target)
		if host._footprint_stroke_cells.has(cell):
			continue
		host._footprint_stroke_cells[cell] = true
		var was_filled := host.board.terrain.is_cell_filled(cell)
		if host.board.terrain.set_cell_filled(cell, not host._footprint_erasing):
			host._footprint_stroke_before[cell] = was_filled
			var cell_rect := Rect2i(cell, Vector2i.ONE)
			changed_cells = (
				cell_rect
				if changed_cells.size.x <= 0
				else changed_cells.merge(cell_rect)
			)
	if changed_cells.size.x > 0:
		# Occupancy changes affect the edited cells plus cardinal wall/skirt owners.
		var affected_cells := changed_cells.grow(1)
		host._accumulate_terrain_dirty_cells(affected_cells)
		host._preview_terrain_stroke(affected_cells)


## Finish one footprint drag and register it as a single undo action.
static func _end_footprint_stroke(host: MTSStudioViewport) -> void:
	if not host._footprint_drawing:
		return
	host._footprint_drawing = false
	host._last_footprint_stamp_xz = Vector2(INF, INF)
	var edited_cells := PackedVector2Array()
	var before_values := PackedByteArray()
	var after_values := PackedByteArray()
	for key: Variant in host._footprint_stroke_before.keys():
		var cell: Vector2i = key
		edited_cells.append(Vector2(cell))
		before_values.append(1 if bool(host._footprint_stroke_before[key]) else 0)
		after_values.append(0 if host._footprint_erasing else 1)
	host._footprint_stroke_cells.clear()
	host._footprint_stroke_before.clear()
	host._refresh_dynamic_skirt(host._footprint_stroke_start_skirt_base_m)
	host._finalize_terrain_region()
	if edited_cells.is_empty() or host._height_undo_redo == null:
		return
	host._height_undo_redo.create_action(
		"Erase footprint" if host._footprint_erasing else "Draw footprint",
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	host._height_undo_redo.add_do_method(
		host,
		"_apply_footprint_patch",
		edited_cells,
		after_values
	)
	host._height_undo_redo.add_undo_method(
		host,
		"_apply_footprint_patch",
		edited_cells,
		before_values
	)
	host._height_undo_redo.commit_action(false)


## Apply one undo/redo footprint patch to only its affected terrain chunks.
static func _apply_footprint_patch(host: MTSStudioViewport,
	cells: PackedVector2Array,
	values: PackedByteArray
) -> void:
	if host.board == null or cells.size() != values.size():
		push_error("[Tile Studio] Cannot replay an invalid footprint patch.")
		return
	var previous_skirt_base := host.board.terrain.skirt_base_m
	var changed_cells := Rect2i()
	for index: int in cells.size():
		var cell := Vector2i(cells[index])
		if not host.board.terrain.set_cell_filled(cell, values[index] != 0):
			continue
		var cell_rect := Rect2i(cell, Vector2i.ONE)
		changed_cells = (
			cell_rect
			if changed_cells.size.x <= 0
			else changed_cells.merge(cell_rect)
		)
	if changed_cells.size.x <= 0:
		return
	var affected_cells := changed_cells.grow(1)
	host._terrain_dirty_cells = affected_cells
	host._terrain_dirty_chunks.clear()
	host._preview_terrain_stroke(affected_cells)
	host._refresh_dynamic_skirt(previous_skirt_base)
	host._finalize_terrain_region()
