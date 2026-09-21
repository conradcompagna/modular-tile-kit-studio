@tool
extends RefCounted

## Material targets behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Give imported RGBA weights exclusive ownership of the existing terrain tile targeter.
static func set_splatmap_tile_paint_enabled(host: MTSStudioViewport, enabled: bool) -> void:
	var changed := host.splatmap_tile_paint_enabled != enabled
	if enabled:
		host.material_tile_paint_enabled = false
	host.splatmap_tile_paint_enabled = enabled
	host._refresh_terrain_material_tile_targeter()
	if changed and enabled and host.placement != null:
		host.placement.set_tool(MTSPlacementController.Tool.PAINT)
	host._emit_status()
	host.request_render()


## Give the selected mask-blended material channel ownership of the same tile targeter.
static func set_material_tile_paint_enabled(host: MTSStudioViewport, enabled: bool) -> void:
	var changed := host.material_tile_paint_enabled != enabled
	if enabled:
		host.splatmap_tile_paint_enabled = false
	host.material_tile_paint_enabled = enabled
	host._refresh_terrain_material_tile_targeter()
	if changed and enabled and host.placement != null:
		host.placement.set_tool(MTSPlacementController.Tool.PAINT)
	host._emit_status()
	host.request_render()


## Arm one explicit tile-paint owner while leaving the circular pen as a separate input path.
static func _refresh_terrain_material_tile_targeter(host: MTSStudioViewport) -> void:
	if host.placement == null:
		return
	var enabled := host.splatmap_tile_paint_enabled or host.material_tile_paint_enabled
	if not enabled:
		host._end_terrain_material_tile_stroke()
		host.placement.set_terrain_splat_paint(false)
		host._hide_height_brush_preview()
		host._refresh_placement_visibility()
		return
	# The base-coat controller is the only pointer owner in either tile mode.
	if host.material_paint_tool != MTSStudioViewport.MaterialPaintTool.NONE:
		host.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
	if host.height_sculpt_tool != MTSStudioViewport.HeightSculptTool.NONE:
		host.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.NONE)
	if host.footprint_tool != MTSStudioViewport.FootprintTool.NONE:
		host.set_footprint_tool(MTSStudioViewport.FootprintTool.NONE)
	host.disarm_native_decal_brush()
	# Explicit Tile modes are drawn only by PlacementController's canonical preview.
	host._hide_height_brush_preview()
	var validator := Callable(host, "_validate_splatmap_tile_targets")
	var face := host._splatmap_projection_face()
	var follow_hover_face := false
	if host.material_tile_paint_enabled:
		validator = Callable(host, "_validate_material_tile_targets")
		face = MTSStudioViewport.K.Face.POS_Y
		follow_hover_face = true
	host.placement.set_terrain_splat_paint(
		true,
		validator,
		face,
		follow_hover_face,
		host.material_tile_paint_enabled
	)
	host._refresh_placement_visibility()
	# Re-evaluate the parked pointer so switching modes displays the exact next target.
	if host.camera != null:
		host.placement.update_hover(host.camera, host._last_mouse)


## Validate one canonical base-coat target set for masked-channel tile painting.
static func _validate_material_tile_targets(host: MTSStudioViewport,
	target_uids: PackedStringArray,
	erase: bool,
	_replace_existing: bool
) -> Dictionary:
	if not host.material_tile_paint_enabled or host.surface_material_paint == null:
		return {"valid": false, "reason": "Masked material Tile brush is off."}
	if host.board == null or host.board.material_blend == null:
		return {"valid": false, "reason": "Open a board before painting material tiles."}
	var layer := host.board.material_blend.layer(host.material_brush_palette_index)
	if (
		not bool(layer.get("enabled", false))
		or String(layer.get("asset_id", "")).is_empty()
	):
		return {"valid": false, "reason": "Choose a material and mask before painting tiles."}
	for uid: String in target_uids:
		if not uid.is_empty() and (not erase or host.surface_material_paint.has_image(uid)):
			return {"valid": true, "reason": ""}
	return {
		"valid": false,
		"reason": (
			"No painted material tiles are inside this brush."
			if erase
			else "This tile brush covers no terrain faces."
		),
	}


## Validate one base-coat stamp against the terrain faces the brush actually covers.
##
## Restamping a tile from the control map is the normal operation, not an overwrite
## hazard: the weights come from the projection, so painting the same square twice is
## idempotent. Only erase needs existing paint, so only erase is gated on finding it.
static func _validate_splatmap_tile_targets(host: MTSStudioViewport,
	target_uids: PackedStringArray,
	erase: bool,
	_replace_existing: bool
) -> Dictionary:
	if not host.splatmap_tile_paint_enabled:
		return {"valid": false, "reason": "Splatmap Terrain Mode is off."}
	if not host._ensure_splatmap_projection():
		return {
			"valid": false,
			"reason": "Load an RGBA control map before painting splatmap tiles.",
		}
	var has_mutable_cell := false
	for uid: String in target_uids:
		if not host._splatmap_target_by_uid.has(uid):
			continue
		if not erase or host.surface_material_paint.has_image(uid):
			has_mutable_cell = true
			break
	if has_mutable_cell:
		return {"valid": true, "reason": ""}
	return {
		"valid": false,
		"reason": (
			"No painted splat tiles are inside this brush."
			if erase
			else "This brush covers no terrain faces in the selected projection."
		),
	}


## Begin one tile-material stroke so dragged Paint, Erase, Path, and Fill share one undo action.
static func _begin_terrain_material_tile_stroke(host: MTSStudioViewport) -> bool:
	if host._terrain_material_tile_stroke_active:
		return true
	if host.surface_material_paint == null:
		return false
	if host.splatmap_tile_paint_enabled and not host._ensure_splatmap_projection():
		return false
	if not host.splatmap_tile_paint_enabled and not host.material_tile_paint_enabled:
		return false
	host.surface_material_paint.begin_stroke()
	host._terrain_material_tile_stroke_active = true
	return true


## Finish one tile-material stroke and register its exact sparse RGBA change with global undo.
static func _end_terrain_material_tile_stroke(host: MTSStudioViewport) -> void:
	if not host._terrain_material_tile_stroke_active:
		return
	host._terrain_material_tile_stroke_active = false
	var stroke := host.surface_material_paint.finish_stroke()
	var action := (
		"Paint splatmap base coat"
		if host.splatmap_tile_paint_enabled
		else "Paint masked material tiles"
	)
	host._register_material_paint_undo(stroke, action)


## Apply the face UIDs already resolved by the canonical base-coat targeter.
static func _on_terrain_material_tile_paint_requested(host: MTSStudioViewport,
	target_uids: PackedStringArray,
	erase: bool,
	_replace_existing: bool,
	finish_stroke: bool
) -> void:
	if (
		target_uids.is_empty()
		or (not host.splatmap_tile_paint_enabled and not host.material_tile_paint_enabled)
	):
		return
	if not host._begin_terrain_material_tile_stroke():
		return
	var changed := false
	for uid: String in target_uids:
		if uid.is_empty() or (erase and not host.surface_material_paint.has_image(uid)):
			continue
		if host.splatmap_tile_paint_enabled:
			# Imported RGBA weights are sampled only after the shared targeter identifies the face.
			var target: Dictionary = host._splatmap_target_by_uid.get(uid, {})
			if target.is_empty():
				continue
			var cell: Vector2i = target.get("projection_cell", Vector2i.ZERO)
			var weights := null if erase else host._splatmap_tile_weights(cell)
			if not erase and weights == null:
				continue
			if host.surface_material_paint.stamp_splatmap_tile(
				uid,
				weights,
				host.board.material_blend.splatmap_palette_indices,
				erase
			):
				changed = true
		elif host.surface_material_paint.stamp_material_tile(
			uid,
			host.material_brush_palette_index,
			host.material_brush_opacity,
			host.material_layer_rotation_quarters(),
			erase
		):
			# The shader applies the selected world-space mask to this full-tile gate.
			changed = true
	if changed:
		host.request_render()
	if finish_stroke:
		host._end_terrain_material_tile_stroke()
