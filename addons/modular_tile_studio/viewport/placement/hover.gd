@tool
extends RefCounted

## Hover behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Update the cursor placement through the target primitive selected by the visible mode.
static func update_hover(host: MTSPlacementController, camera: Camera3D, mouse_pos: Vector2) -> void:
	var pick: Dictionary
	if host._uses_surface_edge_targeter():
		pick = host._pick_grid_edge(camera, mouse_pos)
	elif host.tool == MTSPlacementController.Tool.FILL and host.has_fill_vertices():
		pick = host._pick_fill_cell(camera, mouse_pos)
	else:
		pick = host.pick_cell(camera, mouse_pos)
	host._apply_hover_pick(pick)


## Update the cursor placement from one explicit ray through the selected target primitive.
##
## Tests and bridge callers use this entry point, while editor mouse input reaches
## the same _apply_hover_pick() path through update_hover().
static func update_hover_from_ray(host: MTSPlacementController, origin: Vector3, direction: Vector3) -> void:
	var pick: Dictionary
	if host._uses_surface_edge_targeter() and host.terrain_renderer != null:
		pick = host.terrain_renderer.pick_grid_edge(origin, direction)
		if pick.is_empty():
			pick = {"hit": false}
	else:
		pick = host.pick_terrain_from_ray(origin, direction)
	host._apply_hover_pick(pick)


## Apply one pick record to the transient hover and rebuild the exact preview.
static func _apply_hover_pick(host: MTSPlacementController, pick: Dictionary) -> void:
	if not bool(pick.get("hit", false)):
		host._surface_grid_anchor = SurfacePlacement.GridAnchor.CELL
		if host._preview_root != null:
			host._preview_root.visible = false
		return

	host._surface_grid_anchor = (
		int(pick.get("grid_anchor", SurfacePlacement.GridAnchor.CELL))
		if bool(pick.get("grid_edge", false))
		else SurfacePlacement.GridAnchor.CELL
	)
	var picked_cell: Vector3i = pick["cell"]
	var terrain_face: Dictionary = pick.get("terrain_face", {})
	if not terrain_face.is_empty():
		host._active_prop_support_face = int(terrain_face["face"])
		if (
			host.terrain_splat_paint_enabled
			and host._terrain_splat_follow_hover_face
			and (host.tool != MTSPlacementController.Tool.FILL or host.fill_vertices.is_empty())
		):
			# Masked tile paint follows the pointed terrain face until Fill pins its plane.
			host._terrain_splat_face = host._active_prop_support_face
		if host.brush_is_surface() and host.brush_asset != null:
			# Texture painting follows the face actually hit, so the same cursor
			# naturally targets both top cells and every directed side band.
			host.brush_face = int(terrain_face["face"])
	elif host.tool != MTSPlacementController.Tool.FILL or not host.has_fill_vertices():
		host._active_prop_support_face = MTSPlacementController.K.Face.POS_Y

	if host.brush_is_prop() and host._prop_is_wall_supported() and not pick.has("point"):
		host.hover_valid = false
		host.hover_reason = "terrain wall pick has no world point"
		push_error("[Tile Studio] terrain wall pick has no world point.")
		if host._preview_root != null:
			host._preview_root.visible = false
		host.hover_changed.emit(host.hovered_cell, false, host.hover_reason)
		return

	var previous_hovered_cell := host.hovered_cell
	host.hovered_cell = host._prop_origin_for_pick(picked_cell, pick)
	host._evaluate_hover()
	host._position_preview()
	if (
		host.tool == MTSPlacementController.Tool.FILL
		and host._fill_is_armed()
		and (
			(host._fill_targets_terrain() and host.fill_vertices.is_empty())
			or (host.has_fill_vertices() and host.hovered_cell != previous_hovered_cell)
		)
	):
		# Terrain Fill has no ordinary asset ghost, so its uncommitted hovered cell
		# must enter the same preview pipeline before the first point is clicked.
		host._refresh_fill_preview_from_hover()
	host.update_preview_visibility()
	host.hover_changed.emit(host.hovered_cell, host.hover_valid, host.hover_reason)


## Convert a terrain face address into a prop's canonical minimum-corner origin.
##
## TOP faces already store their minimum lattice corner. A wall face instead
## stores the terrain cell that owns it, so the exact picked face point determines
## the outside edge of the prop's oriented AABB. No display-only offset is applied.
static func _prop_origin_for_pick(host: MTSPlacementController,
	picked_cell: Vector3i,
	terrain_pick: Dictionary
) -> Vector3i:
	if not host.brush_is_prop() or not host._prop_is_wall_supported():
		return picked_cell

	var origin := picked_cell
	var face_point: Vector3 = terrain_pick["point"]
	var normal := MTSPlacementController.K.face_normal(host._active_prop_support_face)
	var bounds := host._brush_box()
	if normal.x > 0:
		origin.x = roundi(face_point.x)
	elif normal.x < 0:
		origin.x = roundi(face_point.x) - bounds.x
	elif normal.z > 0:
		origin.z = roundi(face_point.z)
	elif normal.z < 0:
		origin.z = roundi(face_point.z) - bounds.z
	return origin


## Evaluate whether the current hover can be committed without occupancy conflicts.
static func _evaluate_hover(host: MTSPlacementController) -> void:
	if host.board == null:
		host.hover_valid = false
		host.hover_reason = ""
		return
	host.hover_valid = false
	host.hover_reason = ""
	if host.terrain_splat_paint_enabled:
		var splat_result := host._validate_terrain_splat_origin(
			host.hovered_cell,
			host.tool == MTSPlacementController.Tool.ERASE,
			host.replace_enabled
		)
		host.hover_valid = bool(splat_result.get("valid", false))
		host.hover_reason = String(splat_result.get("reason", ""))
		return
	if not host.has_brush():
		return
	var candidate := host._placement_for_origin(host.hovered_cell)
	var result := host._validate_placement(candidate)
	host.hover_valid = bool(result["valid"])
	host.hover_reason = String(result["reason"])
