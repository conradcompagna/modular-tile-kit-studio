@tool
extends RefCounted

## Material strokes behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Enable native stylus pressure independently for pen size and opacity.
static func set_material_pressure_controls(host: MTSStudioViewport, size_enabled: bool, opacity_enabled: bool) -> void:
	host.material_pressure_size_enabled = size_enabled
	host.material_pressure_opacity_enabled = opacity_enabled
	if host.board != null and host.board.material_blend != null:
		host.board.material_blend.pressure_controls_size = size_enabled
		host.board.material_blend.pressure_controls_opacity = opacity_enabled


## Return the exact canonical heightfield face under the material pointer.
##
## Painting writes only splat weights on the terrain receiver. A miss stays empty,
## so no other geometry can become an alternate target.
static func _material_surface_hit(host: MTSStudioViewport, mouse_position: Vector2) -> Dictionary:
	if host.camera == null or host.board == null or not Rect2(Vector2.ZERO, host.size).has_point(mouse_position):
		return {}
	var ray_origin := host.camera.project_ray_origin(mouse_position)
	var ray_end := ray_origin + host.camera.project_ray_normal(mouse_position) * 10000.0
	# Material painting has exactly one receiver: the canonical heightfield.
	# A terrain miss remains empty instead of falling through to legacy PNG bodies.
	return host._terrain_paint_hit(ray_origin, ray_end)


## Return a paint hit on the terrain surface, or an empty dictionary.
##
## The ray is intersected against the terrain's own collision faces, which are
## built from the same corner lattice as the visible mesh, so the brush lands
## exactly where the ground is drawn.
##
## The reported footprint is the whole encounter grid rather than any tile size:
## that is what frees terrain painting from stepping in tile-sized increments.
static func _terrain_paint_hit(host: MTSStudioViewport, ray_origin: Vector3, _ray_end: Vector3) -> Dictionary:
	if host.terrain_renderer == null or host.board == null or host.board.terrain.is_empty():
		return {}
	var pick: Dictionary = host.terrain_renderer.pick_face(
		ray_origin,
		(_ray_end - ray_origin).normalized()
	)
	if pick.is_empty():
		return {}
	var face: Dictionary = pick["face"]
	var uid := String(pick["uid"])
	var hit_normal: Vector3 = pick["normal"]
	var is_wall := bool(pick["is_wall"])
	return {
		# Paint is addressed by the terrain face's own canonical UID. No placement
		# record stands in for the face: terrain art comes from the painted palette
		# written against that identity, never from a base image.
		"terrain_face": face,
		"uid": uid,
		"footprint": host.terrain_renderer.paint_footprint_for_uid(uid),
		"uv": (pick["local_uv"] as Vector2).clamp(Vector2.ZERO, Vector2.ONE),
		"world_position": pick["point"],
		"normal_world": hit_normal,
		# The brush is projected along the face it actually hit, so a stroke keeps a
		# constant world size on a wall as well as on the ground.
		"paint_plane_normal_world": hit_normal,
		"tangent_world": (
			Vector3(-hit_normal.z, 0.0, hit_normal.x).normalized()
			if is_wall
			else Vector3.RIGHT
		),
		"binormal_world": Vector3.UP if is_wall else Vector3.BACK,
	}


## Return every terrain face one world-space brush capsule touches.
##
## The terrain equivalent of the PNG branch below: a stroke is one continuous
## world capsule, so it must write EVERY 1 m unit it crosses rather than clipping
## at the face under the cursor. Local UV endpoints are deliberately left
## unbounded so a stroke that starts on one unit and continues onto the next stays
## one capsule instead of becoming two square edge stamps.
static func _terrain_surface_stamps(host: MTSStudioViewport,
	start_world: Vector3,
	end_world: Vector3,
	radius_m: float
) -> Array[Dictionary]:
	var stamps: Array[Dictionary] = []
	if host.terrain_renderer == null:
		return stamps
	for face: Dictionary in host.terrain_renderer.faces_near_segment(
		start_world,
		end_world,
		radius_m
	):
		var uid := String(face["paint_uid"])
		stamps.append({
			"uid": uid,
			"footprint": host.terrain_renderer.paint_footprint_for_uid(uid),
			"start_uv": host.terrain_renderer.local_uv_for_face(face, start_world),
			"end_uv": host.terrain_renderer.local_uv_for_face(face, end_world),
		})
	return stamps


## Return every exact terrain face touched by one world-space brush capsule.
static func _material_surface_stamps(host: MTSStudioViewport,
	reference_hit: Dictionary,
	start_world: Vector3,
	end_world: Vector3,
	radius_m: float
) -> Array[Dictionary]:
	if (reference_hit.get("terrain_face", {}) as Dictionary).is_empty():
		return [] as Array[Dictionary]
	return host._terrain_surface_stamps(start_world, end_world, radius_m)


## Begin one sparse stroke and apply its first metric brush stamp.
static func _begin_material_paint(host: MTSStudioViewport,
	mouse_position: Vector2,
	pressure: float = 1.0,
	force_erase: bool = false,
	prepared_hit: Dictionary = {}
) -> void:
	if host.material_paint_tool == MTSStudioViewport.MaterialPaintTool.NONE or host.surface_material_paint == null:
		return
	host.surface_material_paint.begin_stroke()
	host._material_painting = true
	host._material_has_last_sample = false
	host._material_pending_sample = false
	host._material_pending_hit.clear()
	host._material_stroke_force_erase = force_erase
	host._apply_material_paint_hit(mouse_position, pressure, force_erase, prepared_hit)


## Retain only the latest raw pointer endpoint because the next capsule covers the full intervening path.
static func _continue_material_paint(host: MTSStudioViewport,
	mouse_position: Vector2,
	pressure: float,
	pen_inverted: bool,
	prepared_hit: Dictionary = {}
) -> void:
	if not host._material_painting:
		return
	host._material_pending_sample = true
	host._material_pending_mouse_position = mouse_position
	host._material_pending_pressure = pressure
	host._material_pending_force_erase = pen_inverted or host._material_stroke_force_erase
	host._material_pending_hit = prepared_hit.duplicate()


## Apply at most one queued pointer endpoint before this frame's one dirty-layer upload.
static func _flush_pending_material_paint(host: MTSStudioViewport) -> void:
	if not host._material_painting or not host._material_pending_sample:
		return
	var mouse_position := host._material_pending_mouse_position
	var pressure := host._material_pending_pressure
	var force_erase := host._material_pending_force_erase
	var hit := host._material_pending_hit
	host._material_pending_sample = false
	host._material_pending_hit = {}
	if hit.is_empty():
		hit = host._update_material_brush_preview(mouse_position)
	else:
		host._draw_material_brush_preview(hit)
	host._apply_material_paint_hit(mouse_position, pressure, force_erase, hit)


## Apply one pointer sample as one world-space circular capsule across tile seams.
static func _apply_material_paint_hit(host: MTSStudioViewport,
	mouse_position: Vector2,
	pressure: float,
	force_erase: bool,
	prepared_hit: Dictionary = {}
) -> void:
	var hit := prepared_hit if not prepared_hit.is_empty() else host._material_surface_hit(mouse_position)
	if hit.is_empty():
		host._material_has_last_sample = false
		return
	var normalized_pressure := pressure if pressure > 0.0 else 1.0
	var radius := host.material_brush_radius_m
	var opacity := host.material_brush_opacity
	if host.material_pressure_size_enabled:
		radius *= normalized_pressure
	if host.material_pressure_opacity_enabled:
		opacity *= normalized_pressure
	var erase := (
		host.material_paint_tool == MTSStudioViewport.MaterialPaintTool.ERASE
		or force_erase
	)
	var terrain_face: Dictionary = hit.get("terrain_face", {})
	if host.placement != null and not terrain_face.is_empty():
		host.placement.align_surface_brush_face(int(terrain_face.get("face", MTSStudioViewport.K.Face.POS_Y)))
	var rotation_quarters := host.material_layer_rotation_quarters()
	var world_position: Vector3 = hit.get("world_position", Vector3.ZERO)
	var plane_normal: Vector3 = hit.get(
		"paint_plane_normal_world",
		hit.get("normal_world", Vector3.UP)
	)
	plane_normal = plane_normal.normalized()
	var start_world := world_position
	if (
		host._material_has_last_sample
		and plane_normal.dot(host._material_last_plane_normal) > 0.9999
		and absf(
			plane_normal.dot(world_position - host._material_last_world_position)
		) <= 0.001
	):
		start_world = host._material_last_world_position
	var changed := false
	for stamp: Dictionary in host._material_surface_stamps(
		hit,
		start_world,
		world_position,
		radius
	):
		if host.surface_material_paint.brush_segment(
			String(stamp["uid"]),
			stamp["footprint"],
			stamp["start_uv"],
			stamp["end_uv"],
			radius,
			host.material_brush_hardness,
			opacity,
			host.material_brush_palette_index,
			rotation_quarters,
			erase
		):
			changed = true
	if changed:
		host.request_render()
	host._material_has_last_sample = true
	host._material_last_world_position = world_position
	host._material_last_plane_normal = plane_normal


## Finish one stroke and register only its modified pixels with global undo.
static func _end_material_paint(host: MTSStudioViewport) -> void:
	if not host._material_painting:
		return
	host._flush_pending_material_paint()
	host._material_painting = false
	host._material_pending_sample = false
	host._material_pending_hit.clear()
	host._material_stroke_force_erase = false
	var stroke := (
		host.surface_material_paint.finish_stroke()
		if host.surface_material_paint != null
		else {}
	)
	host._material_has_last_sample = false
	host._register_material_paint_undo(stroke)


## Register an already-applied sparse material stroke without replaying it.
static func _register_material_paint_undo(host: MTSStudioViewport,
	stroke: Dictionary,
	action_name: String = ""
) -> void:
	if host._height_undo_redo == null or stroke.is_empty():
		return
	var patches_value: Variant = stroke.get("patches", {})
	if not patches_value is Dictionary:
		push_error("[Tile Studio] Material stroke produced an invalid undo patch.")
		return
	var patches: Dictionary = patches_value
	if patches.is_empty():
		return
	var resolved_action_name := (
		action_name
		if not action_name.is_empty()
		else "Paint material layer %d" % (host.material_brush_palette_index + 1)
	)
	host._height_undo_redo.create_action(
		resolved_action_name,
		UndoRedo.MERGE_DISABLE,
		null,
		false
	)
	host._height_undo_redo.add_do_method(
		host,
		"_apply_material_paint_patch",
		patches,
		"after"
	)
	host._height_undo_redo.add_undo_method(
		host,
		"_apply_material_paint_patch",
		patches,
		"before"
	)
	host._height_undo_redo.commit_action(false)


## Apply one sparse undo/redo patch and queue only its touched array layers.
static func _apply_material_paint_patch(host: MTSStudioViewport, patches: Dictionary, value_key: String) -> void:
	if host.surface_material_paint == null:
		push_error("[Tile Studio] Cannot replay material paint without its image owner.")
		return
	host.surface_material_paint.apply_patch(patches, value_key)
	host.request_render()
