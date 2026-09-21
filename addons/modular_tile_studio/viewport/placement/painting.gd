@tool
extends RefCounted

## Painting behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

# --- Mutation -------------------------------------------------------------

## Commit the brush at the hovered cell through the canonical batch pipeline.
##
## Paint passes one origin while Fill passes many, so validation, overlap
## reservation, undo behavior, and document mutation cannot diverge by tool.
static func paint_at_hover(host: MTSPlacementController) -> bool:
	if host.terrain_splat_paint_enabled:
		var splat_result := host._validate_terrain_splat_origin(
			host.hovered_cell,
			false,
			host.replace_enabled
		)
		if not bool(splat_result.get("valid", false)):
			host._reject(String(splat_result.get("reason", "splatmap tile is blocked")))
			return false
		host.last_rejection = ""
		var target_uids: PackedStringArray = splat_result.get(
			"target_uids",
			PackedStringArray()
		)
		host.terrain_material_tile_paint_requested.emit(
			target_uids,
			false,
			host.replace_enabled,
			false
		)
		return true
	if not host.has_brush() or host.board == null:
		host.last_rejection = "no brush or board"
		return false
	host.last_rejection = ""

	# Terrain paint is the primary way a PNG reaches the board. The visible brush
	# grid-stroke width owns the mutated face set, while asset size remains only the texture's
	# UV/repeat scale. The material blend palette remains a separate masking workflow.

	var origins: Array[Vector3i] = [host.hovered_cell]
	var evaluated := host._evaluate_placement_candidates(origins)
	var placements: Array[Resource] = evaluated["placements"]
	var displaced: Array[Resource] = evaluated["replacements"]
	if placements.is_empty():
		if bool(evaluated.get("occupied_surface_no_op", false)):
			return true
		host._reject(String(evaluated["first_rejection"]))
		return false

	# Every decal kind is stamped rather than painted, so the history entry names
	# them the same way; only terrain paint reads as "Paint surface". Expressed as
	# "not terrain paint" so a new render role cannot be silently mislabelled.
	var stamping_decal := (
		host.brush_is_surface()
		and host.brush_surface_presentation != SurfacePlacement.Presentation.TERRAIN_PAINT
	)
	var action := (
		"Stamp decal"
		if stamping_decal
		else "Paint surface" if host.brush_is_surface() else "Place prop"
	)
	if displaced.is_empty():
		host._commit_placements_bulk(placements, action)
	else:
		host._commit_replacements(
			placements,
			displaced,
			"Replace %d placement%s" % [
				displaced.size(),
				"" if displaced.size() == 1 else "s",
			]
		)
	return true


## Report a refused placement without committing it.
##
## Re-emits hover state so the preview and status bar show the conflict even
## when the pointer has not moved since the last evaluation -- clicking a second
## time on an occupied cell must still say why nothing happened.
static func _reject(host: MTSPlacementController, reason: String) -> void:
	host.hover_valid = false
	host.hover_reason = reason
	host.last_rejection = reason
	host._position_preview()
	host.hover_changed.emit(host.hovered_cell, false, reason)
	host.placement_rejected.emit(host.hovered_cell, reason)


## Return the terrain paint covering one lattice address, if any.
##
## Editor picking is addressed by lattice position while authored paint is keyed
## by the terrain face's stable UID, so this resolves one to the other through
## the live terrain records rather than assuming the two ever match directly.
static func _surface_at_address(host: MTSPlacementController, cell: Vector3i, face: int) -> SurfacePlacement:
	if host.board == null or host.terrain_renderer == null:
		return null
	var paint_uid := host.terrain_renderer.paint_uid_at(cell, face)
	if paint_uid.is_empty():
		return null
	return host.board.surface_at_paint_uid(paint_uid)


## Erase the terrain-paint placement or solid occupying the hovered address.
static func erase_at_hover(host: MTSPlacementController) -> void:
	if host.board == null:
		return
	if host.terrain_splat_paint_enabled:
		var splat_result := host._validate_terrain_splat_origin(
			host.hovered_cell,
			true,
			host.replace_enabled
		)
		if not bool(splat_result.get("valid", false)):
			host._reject(String(splat_result.get("reason", "splatmap tile is empty")))
			return
		var target_uids: PackedStringArray = splat_result.get(
			"target_uids",
			PackedStringArray()
		)
		host.terrain_material_tile_paint_requested.emit(
			target_uids,
			true,
			host.replace_enabled,
			false
		)
		return
	var surface := host._surface_at_address(host.hovered_cell, host.brush_face)
	if surface == null:
		for face: int in MTSPlacementController.K.FACE_NORMALS:
			surface = host._surface_at_address(host.hovered_cell, face)
			if surface != null:
				break
	if surface != null:
		host._commit_remove_surface(surface, "Erase surface")
		return

	var solid := host.board.solid_placement_at(host.hovered_cell)
	if solid is PropPlacement:
		host._commit_remove_prop(solid as PropPlacement, "Erase prop")
