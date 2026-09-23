@tool
extends RefCounted

## Material targets behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Arm the existing base-coat controller as the exclusive terrain material tile brush.
##
## Imported RGBA splatmaps retain the neutral target, while secondary PNG paint reuses
## the regular surface brush asset, face, quarter-turn, textured preview, and arrow.
static func set_terrain_splat_paint(host: MTSPlacementController,
	enabled: bool,
	target_validator: Callable = Callable(),
	projection_face: int = MTSPlacementController.K.Face.POS_Y,
	follow_hover_face: bool = false,
	uses_surface_brush: bool = false
) -> void:
	if enabled and not target_validator.is_valid():
		push_error("MTSPlacementController: terrain material tile paint needs a cell validator.")
		return
	if enabled and projection_face not in [
		MTSPlacementController.K.Face.POS_Y,
		MTSPlacementController.K.Face.NEG_Z,
		MTSPlacementController.K.Face.POS_Z,
		MTSPlacementController.K.Face.POS_X,
		MTSPlacementController.K.Face.NEG_X,
	]:
		push_error("MTSPlacementController: terrain material paint requires a visible face.")
		return
	if (
		host.terrain_splat_paint_enabled == enabled
		and (
			not enabled
			or (
				host._terrain_material_target_validator == target_validator
				and host._terrain_splat_face == projection_face
				and host._terrain_splat_follow_hover_face == follow_hover_face
				and host._terrain_splat_uses_surface_brush == uses_surface_brush
			)
		)
	):
		return
	host.terrain_splat_paint_enabled = enabled
	host._terrain_material_target_validator = target_validator if enabled else Callable()
	host._terrain_splat_face = projection_face if enabled else MTSPlacementController.K.Face.POS_Y
	host._terrain_splat_follow_hover_face = follow_hover_face if enabled else false
	host._terrain_splat_uses_surface_brush = uses_surface_brush if enabled else false
	if enabled:
		host.terrain_fill_enabled = false
		host.terrain_fill_allows_new_cells = false
	host._reset_fill_state()
	host._evaluate_hover()
	if enabled:
		host._position_preview()
	elif host.has_brush():
		host._rebuild_preview()
	host.update_preview_visibility()


## Return the face direction currently owned by the visible material tile targeter.
static func terrain_splat_paint_face(host: MTSPlacementController) -> int:
	return host._terrain_splat_face


## Return stable face UIDs from the established base-coat tile targeter.
##
## Direct texture placement and both RGBA material modes call the same renderer route,
## so wall-plane axes, even-width centring, and face isolation have one owner.
static func terrain_material_target_uids(host: MTSPlacementController, origin: Vector3i, face: int) -> PackedStringArray:
	if host.terrain_renderer == null:
		return PackedStringArray()
	return host.terrain_renderer.surface_face_uids_for_grid_stroke(
		origin,
		face,
		host.surface_grid_stroke_size_m
	)


## Resolve and deduplicate one Paint or Fill gesture through the same tile targeter.
static func terrain_material_target_uids_for_origins(host: MTSPlacementController,
	origins: Array[Vector3i],
	face: int
) -> PackedStringArray:
	var unique_uids: Dictionary = {}
	for origin: Vector3i in origins:
		for uid: String in host.terrain_material_target_uids(origin, face):
			unique_uids[uid] = true
	var target_uids := PackedStringArray()
	for uid_value: Variant in unique_uids.keys():
		target_uids.append(String(uid_value))
	target_uids.sort()
	return target_uids


## Return whether one terrain origin passes the viewport's canonical material-tile rules.
static func _validate_terrain_splat_origin(host: MTSPlacementController,
	origin: Vector3i,
	erase: bool,
	replace_existing: bool
) -> Dictionary:
	if not host.terrain_splat_paint_enabled or not host._terrain_material_target_validator.is_valid():
		return {"valid": false, "reason": "terrain material tile paint is not armed"}
	if host._active_prop_support_face != host._terrain_splat_face:
		return {
			"valid": false,
			"reason": "Point at a terrain face matching the active tile-paint direction.",
		}
	var target_uids := host.terrain_material_target_uids(origin, host._terrain_splat_face)
	var result: Variant = host._terrain_material_target_validator.call(
		target_uids,
		erase,
		replace_existing
	)
	if not result is Dictionary:
		push_error("MTSPlacementController: material tile validator returned invalid data.")
		return {"valid": false, "reason": "material tile validation failed"}
	var validated_result: Dictionary = result as Dictionary
	# Commit consumes the exact UIDs validation approved, so one click cannot be
	# retargeted by a second coordinate conversion after the preview was accepted.
	validated_result["target_uids"] = target_uids
	return validated_result
