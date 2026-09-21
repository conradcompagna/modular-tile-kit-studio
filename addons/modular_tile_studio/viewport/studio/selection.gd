@tool
extends RefCounted

## Selection behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Rebuild selection from the same collision-derived preview pair used by placement.
##
## PNG surfaces retain their real plane collider. Props and surfaced boxes pass
## their exact occupied voxels to ProxyMeshBuilder, with no visual AABB substitute.
static func _refresh_selection_highlights(host: MTSStudioViewport) -> void:
	if host.selection_highlight_root == null:
		return
	host.selection_highlight_root.position = Vector3.ZERO
	for child: Node in host.selection_highlight_root.get_children():
		# Detach first so a same-frame rotation refresh can reuse the stable names
		# consumed by tests and diagnostics instead of receiving Godot's auto-suffix.
		host.selection_highlight_root.remove_child(child)
		child.queue_free()
	if host.placement == null or host.board == null:
		return
	var volume_material := StandardMaterial3D.new()
	volume_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	volume_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	volume_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	volume_material.albedo_color = Color(0.1, 0.8, 1.0, 0.16)
	volume_material.no_depth_test = true
	volume_material.render_priority = 12
	var outline_material := StandardMaterial3D.new()
	outline_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outline_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	outline_material.albedo_color = Color(0.1, 0.8, 1.0, 0.95)
	outline_material.no_depth_test = true
	outline_material.render_priority = 13

	for placement_record: Resource in host.placement.selected_resources():
		var visual := host._find_visual(placement_record)
		# Slice state belongs to the placement visual itself. Ancestor Control
		# visibility must not suppress construction of the collision overlay, which
		# is also exercised while the editor panel is off-screen or headless.
		if visual == null or not visual.visible:
			continue
		if placement_record is SurfacePlacement:
			# The highlight traces the exact terrain faces the paint covers, so a
			# selection on sloped or stepped ground follows the real surface
			# instead of floating a flat rectangle over it.
			var surface := placement_record as SurfacePlacement
			var asset := host.board.resolve_surface_asset(surface)
			if asset == null or host.terrain_renderer == null:
				continue
			var preview_geometry := host.terrain_renderer.surface_preview_meshes(surface, asset)
			var outline_mesh := preview_geometry.get("outline", null) as Mesh
			if outline_mesh == null:
				continue
			var surface_contours := MeshInstance3D.new()
			surface_contours.name = "SelectionCollisionContours"
			surface_contours.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			surface_contours.mesh = outline_mesh
			# The offset is display-only and leaves the collider on the exact face.
			surface_contours.position += Vector3(MTSStudioViewport.K.face_normal(surface.face)) * 0.02
			surface_contours.material_override = outline_material
			host.selection_highlight_root.add_child(surface_contours)
			continue

		var collision_voxels := host._placement_collision_voxels(placement_record)
		if collision_voxels.is_empty():
			continue
		var collision_preview := MTSStudioViewport.ProxyMeshBuilder.collision_preview_meshes(collision_voxels)
		# The mesh is built from the placement's local voxel volume, so both nodes
		# stand at its one canonical world pose -- the same pose the physics shapes
		# and the artwork are posed at.
		var collision_origin := host._placement_collision_origin(placement_record)

		var collision_volume := MeshInstance3D.new()
		collision_volume.name = "SelectionCollisionVolume"
		collision_volume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		collision_volume.mesh = collision_preview["volume"] as Mesh
		collision_volume.position = collision_origin
		collision_volume.material_override = volume_material
		host.selection_highlight_root.add_child(collision_volume)

		var collision_contours := MeshInstance3D.new()
		collision_contours.name = "SelectionCollisionContours"
		collision_contours.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		collision_contours.mesh = collision_preview["contours"] as Mesh
		collision_contours.position = collision_origin
		collision_contours.material_override = outline_material
		host.selection_highlight_root.add_child(collision_contours)


## Return whether exact projected collision geometry overlaps a marquee rectangle.
static func _placement_intersects_screen_rect(host: MTSStudioViewport,
	placement_record: Resource,
	screen_rect: Rect2
) -> bool:
	if host.camera == null:
		return false
	var visual := host._find_visual(placement_record)
	if visual == null or not visual.is_visible_in_tree():
		return false
	var collision_points := host._placement_collision_points(placement_record)
	if collision_points.is_empty():
		return false
	var projected_minimum := Vector2(INF, INF)
	var projected_maximum := Vector2(-INF, -INF)
	var projected_point_count := 0
	for point: Vector3 in collision_points:
		if host.camera.is_position_behind(point):
			continue
		var projected := host.camera.unproject_position(point)
		projected_minimum = projected_minimum.min(projected)
		projected_maximum = projected_maximum.max(projected)
		projected_point_count += 1
	if projected_point_count == 0:
		return false
	return screen_rect.intersects(
		Rect2(projected_minimum, projected_maximum - projected_minimum),
		true
	)


## Resolve the complete visible placement group covered by one screen-space marquee.
static func _placements_in_screen_rect(host: MTSStudioViewport, screen_rect: Rect2) -> Array[Resource]:
	var found: Array[Resource] = []
	if host.board == null:
		return found
	for surface: SurfacePlacement in host.board.surfaces:
		if host._placement_intersects_screen_rect(surface, screen_rect):
			found.append(surface)
	for prop: PropPlacement in host.board.props:
		if host._placement_intersects_screen_rect(prop, screen_rect):
			found.append(prop)
	return found


## Start either a placement drag or an empty-space marquee without changing board data.
static func _begin_select_interaction(host: MTSStudioViewport, mouse_pos: Vector2, additive: bool) -> void:
	host._select_dragging = true
	host._select_drag_start = mouse_pos
	host._select_drag_target = host._placement_at_pointer(mouse_pos)
	host._select_drag_has_start_cell = false
	host._select_drag_last_valid_delta = Vector3i.ZERO
	if host.selection_highlight_root != null:
		host.selection_highlight_root.position = Vector3.ZERO
	if host._select_drag_target == null:
		return
	if additive:
		host.placement.toggle_selected_placement(host._select_drag_target)
	elif not host.placement.is_selected(host._select_drag_target):
		host.placement.set_selected_placements([host._select_drag_target], host._select_drag_target)
	var pick := host.placement.pick_cell(host.camera, mouse_pos)
	if bool(pick.get("hit", false)):
		host._select_drag_start_cell = pick.get("cell", Vector3i.ZERO)
		host._select_drag_has_start_cell = true


## Move the existing collision preview to the last valid snapped drag location.
##
## No placement data changes here. Mouse-up passes this accepted delta to the
## normal move operation once, so dragging cannot create a parallel transform path.
static func _continue_select_interaction(host: MTSStudioViewport, mouse_pos: Vector2) -> void:
	if not host._select_dragging or host._select_drag_target == null or not host._select_drag_has_start_cell:
		return
	var pick := host.placement.pick_cell(host.camera, mouse_pos)
	if not bool(pick.get("hit", false)):
		return
	var cell: Vector3i = pick.get("cell", Vector3i.ZERO)
	var requested_delta := cell - host._select_drag_start_cell
	var rejection := (
		""
		if requested_delta == Vector3i.ZERO
		else host.placement.selection_move_error(requested_delta)
	)
	if rejection.is_empty():
		host._select_drag_last_valid_delta = requested_delta
		if host.selection_highlight_root != null:
			host.selection_highlight_root.position = Vector3(requested_delta)
		host.hover_changed.emit(cell, true, "Drop %d selected placement%s at %s" % [
			host.placement.selected_resources().size(),
			"" if host.placement.selected_resources().size() == 1 else "s",
			requested_delta,
		])
	else:
		host.hover_changed.emit(cell, false, "%s; last valid delta %s" % [
			rejection,
			host._select_drag_last_valid_delta,
		])
	host.request_render()


## Finish a click, marquee, or one collision-validated selection drop.
static func _end_select_interaction(host: MTSStudioViewport, mouse_pos: Vector2, additive: bool) -> void:
	if not host._select_dragging:
		return
	var dragged := host._select_drag_start.distance_to(mouse_pos) >= MTSStudioViewport.SELECT_DRAG_THRESHOLD_PX
	if host._select_drag_target != null and dragged and host._select_drag_has_start_cell:
		host._continue_select_interaction(mouse_pos)
		if host.selection_highlight_root != null:
			host.selection_highlight_root.position = Vector3.ZERO
		host.placement.move_selection_by(host._select_drag_last_valid_delta)
	elif host._select_drag_target == null and dragged:
		var marquee := Rect2(host._select_drag_start, mouse_pos - host._select_drag_start).abs()
		var marquee_selection := host._placements_in_screen_rect(marquee)
		if additive:
			marquee_selection.append_array(host.placement.selected_resources())
		host.placement.set_selected_placements(marquee_selection)
	elif host._select_drag_target == null:
		host.placement.clear_selection()
	if host.selection_highlight_root != null:
		host.selection_highlight_root.position = Vector3.ZERO
	host._select_dragging = false
	host._select_drag_target = null
	host._select_drag_has_start_cell = false
	host._select_drag_last_valid_delta = Vector3i.ZERO
	host._emit_status()
	host.request_render()
