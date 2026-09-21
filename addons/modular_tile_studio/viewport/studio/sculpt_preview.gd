@tool
extends RefCounted

## Sculpt preview behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Project a viewport point onto the canonical terrain address used by its brush family.
##
## Slope tools retain the continuous hit point; the canonical square query then uses
## lattice corners. Cell-based tools anchor to the picked cell centre so a click
## near a shared corner cannot accidentally step all four neighbouring cells.
static func _height_brush_pick(host: MTSStudioViewport, mouse_pos: Vector2) -> Dictionary:
	if host.placement == null or host.camera == null:
		return {"hit": false}
	var pick := host.placement.pick_cell(host.camera, mouse_pos)
	if not bool(pick.get("hit", false)):
		return {"hit": false}
	var cell: Vector3i = pick.get("cell", Vector3i.ZERO)
	var point: Vector3 = pick.get("point", Vector3.ZERO)
	var world_xz := Vector2(point.x, point.z)
	if TerrainSculptor.mode_is_cell_based(host._sculptor_mode_for_tool(host.height_sculpt_tool)):
		world_xz = Vector2(float(cell.x) + 0.5, float(cell.z) + 0.5)
	return {"hit": true, "xz": world_xz, "cell": cell, "point": point}


## Build the transient sculpt targeter without adding state to the saved board.
static func _build_height_brush_preview(host: MTSStudioViewport) -> void:
	host._height_brush_fill_material = StandardMaterial3D.new()
	host._height_brush_fill_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	host._height_brush_fill_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	host._height_brush_fill_material.albedo_color = Color(0.12, 0.86, 1.0, 0.22)
	host._height_brush_fill_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	host._height_brush_fill_material.no_depth_test = true
	host._height_brush_fill_material.render_priority = 10
	host._height_brush_line_material = StandardMaterial3D.new()
	host._height_brush_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	host._height_brush_line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	host._height_brush_line_material.albedo_color = Color(0.12, 0.86, 1.0, 1.0)
	host._height_brush_line_material.no_depth_test = true
	host._height_brush_line_material.render_priority = 11
	host._height_brush_preview = MeshInstance3D.new()
	host._height_brush_preview.name = "TerrainBrushPreview"
	host._height_brush_preview.mesh = ImmediateMesh.new()
	host._height_brush_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host._height_brush_preview.visible = false
	host.world_root.add_child(host._height_brush_preview)


## Hide the sculpt targeter whenever its tool or pointer has no valid receiver.
static func _hide_height_brush_preview(host: MTSStudioViewport) -> void:
	if is_instance_valid(host._height_brush_preview) and host._height_brush_preview.visible:
		host._height_brush_preview.visible = false
		host.request_render()


## Redraw whichever terrain authoring tool currently owns the shared targeter.
static func _update_active_terrain_brush_preview(host: MTSStudioViewport, mouse_position: Vector2) -> Dictionary:
	if host.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
		return host._update_footprint_brush_preview(mouse_position)
	return host._update_height_brush_preview(mouse_position)


## Pick terrain and redraw the exact live sculpt target under the pointer.
static func _update_height_brush_preview(host: MTSStudioViewport, mouse_position: Vector2) -> Dictionary:
	if host.height_sculpt_tool == MTSStudioViewport.HeightSculptTool.NONE or host.board == null or host.board.terrain.is_empty():
		host._hide_height_brush_preview()
		return {}
	var pick := host._height_brush_pick(mouse_position)
	if not bool(pick.get("hit", false)):
		host._hide_height_brush_preview()
		return {}
	host._draw_height_brush_preview(pick)
	return pick


## Draw the exact square cell targets shared by every terrain brush family.
##
## The preview queries the configured sculptor, so footprint membership cannot
## diverge from the cells whose shared corners a smooth stroke will move.
static func _draw_height_brush_preview(host: MTSStudioViewport, pick: Dictionary) -> void:
	if not is_instance_valid(host._height_brush_preview) or host.board == null:
		return
	var immediate_mesh := host._height_brush_preview.mesh as ImmediateMesh
	immediate_mesh.clear_surfaces()
	if host._terrain_sculptor == null:
		host._bind_terrain_sculptor()
	if host._terrain_sculptor == null:
		host._hide_height_brush_preview()
		return
	var targets := host._terrain_sculptor.cell_targets(pick["xz"])
	if targets.is_empty():
		host._hide_height_brush_preview()
		return
	host._draw_height_cell_targets(immediate_mesh, targets)
	host._height_brush_preview.visible = immediate_mesh.get_surface_count() > 0
	host.request_render()


## Add translucent tops and cyan borders for every whole cell the active tool targets.
static func _draw_height_cell_targets(host: MTSStudioViewport,
	immediate_mesh: ImmediateMesh,
	targets: PackedVector2Array,
	valid: bool = true
) -> void:
	# A blocked splat target remains visible in red, matching the ordinary
	# base-coat preview instead of disappearing and looking like no brush exists.
	host._height_brush_fill_material.albedo_color = (
		Color(0.12, 0.86, 1.0, 0.22)
		if valid
		else Color(1.0, 0.18, 0.12, 0.22)
	)
	host._height_brush_line_material.albedo_color = (
		Color(0.12, 0.86, 1.0, 1.0)
		if valid
		else Color(1.0, 0.18, 0.12, 1.0)
	)
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, host._height_brush_fill_material)
	for target: Vector2 in targets:
		var cell := Vector2i(target)
		var points := host._height_preview_cell_points(cell)
		for index: int in [0, 2, 3, 0, 3, 1]:
			immediate_mesh.surface_add_vertex(points[index])
	immediate_mesh.surface_end()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES, host._height_brush_line_material)
	for target: Vector2 in targets:
		var points := host._height_preview_cell_points(Vector2i(target))
		for edge: Array in [[0, 1], [1, 3], [3, 2], [2, 0]]:
			immediate_mesh.surface_add_vertex(points[int(edge[0])])
			immediate_mesh.surface_add_vertex(points[int(edge[1])])
	immediate_mesh.surface_end()


## Return one cell's four canonical top corners raised just above the visible surface.
static func _height_preview_cell_points(host: MTSStudioViewport, cell: Vector2i) -> PackedVector3Array:
	var heights := host.board.terrain.cell_top(cell)
	var points := PackedVector3Array()
	for corner: int in 4:
		var offset: Vector2i = TerrainMesh.CORNER_OFFSETS[corner]
		points.append(Vector3(
			float(cell.x + offset.x),
			heights[corner] + MTSStudioViewport.HEIGHT_BRUSH_PREVIEW_OFFSET_M,
			float(cell.y + offset.y)
		))
	return points
