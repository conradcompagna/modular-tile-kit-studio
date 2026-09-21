@tool
extends RefCounted

## Paint resolution behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Apply one explicit canonical paint-resolution change and retain an exact compressed undo snapshot when global history is available.
##
## Existing images and all derived arrays are prepared before any live state changes, so allocation
## failure leaves the board and its current paint untouched.
static func apply_material_paint_resolution(host: MTSStudioViewport,
	texels_per_metre: int,
	maximum_edge_px: int
) -> bool:
	if (
		host.board == null
		or host.board.material_blend == null
		or host.surface_material_paint == null
	):
		push_error("[Tile Studio] Cannot rebuild paint resolution without an active board painter.")
		return false
	var before_json := host.board.material_blend.to_json().duplicate(true)
	var target_profile := MaterialBlendProfile.new()
	target_profile.from_json(before_json)
	target_profile.paint_texels_per_metre = clampi(
		texels_per_metre,
		MaterialBlendProfile.MIN_TEXELS_PER_METRE,
		MaterialBlendProfile.MAX_TEXELS_PER_METRE
	)
	target_profile.maximum_surface_edge_px = clampi(
		maximum_edge_px,
		MaterialBlendProfile.MIN_SURFACE_EDGE_PX,
		MaterialBlendProfile.MAX_SURFACE_EDGE_PX
	)
	var after_json := target_profile.to_json().duplicate(true)
	if before_json == after_json:
		return true
	var snapshot := host.surface_material_paint.capture_png_snapshot()
	if int(snapshot.get("error", FAILED)) != OK:
		return false
	var prepared := host.surface_material_paint.prepare_resolution_rebuild(target_profile)
	if int(prepared.get("error", FAILED)) != OK:
		return false
	if not host._commit_material_paint_resolution(after_json, prepared):
		return false
	if host._height_undo_redo != null:
		host._height_undo_redo.create_action(
			"Rebuild paint mask resolution",
			UndoRedo.MERGE_DISABLE,
			null,
			false
		)
		host._height_undo_redo.add_do_method(
			host,
			"_rebuild_material_paint_resolution_from_json",
			after_json.duplicate(true)
		)
		host._height_undo_redo.add_undo_method(
			host,
			"_restore_material_paint_resolution_snapshot",
			before_json.duplicate(true),
			snapshot
		)
		host._height_undo_redo.commit_action(false)
	return true


## Rebuild current canonical images to one saved profile during resolution redo.
static func _rebuild_material_paint_resolution_from_json(host: MTSStudioViewport, profile_json: Dictionary) -> void:
	if host.surface_material_paint == null:
		push_error("[Tile Studio] Cannot redo paint resolution without its image owner.")
		return
	var target_profile := MaterialBlendProfile.new()
	target_profile.from_json(profile_json)
	var prepared := host.surface_material_paint.prepare_resolution_rebuild(target_profile)
	if int(prepared.get("error", FAILED)) != OK:
		push_error("[Tile Studio] Paint resolution redo could not prepare its images.")
		return
	host._commit_material_paint_resolution(profile_json, prepared)


## Restore exact pre-resize PNG weights and their saved profile during resolution undo.
static func _restore_material_paint_resolution_snapshot(host: MTSStudioViewport,
	profile_json: Dictionary,
	snapshot: Dictionary
) -> void:
	if host.surface_material_paint == null:
		push_error("[Tile Studio] Cannot undo paint resolution without its image owner.")
		return
	var prepared := host.surface_material_paint.prepare_png_snapshot(snapshot)
	if int(prepared.get("error", FAILED)) != OK:
		push_error("[Tile Studio] Paint resolution undo could not decode its exact snapshot.")
		return
	host._commit_material_paint_resolution(profile_json, prepared)


## Commit a prepared image replacement before publishing its matching visible profile.
static func _commit_material_paint_resolution(host: MTSStudioViewport,
	profile_json: Dictionary,
	prepared: Dictionary
) -> bool:
	if host.board == null or host.board.material_blend == null or host.surface_material_paint == null:
		push_error("[Tile Studio] Cannot commit paint resolution without an active board.")
		return false
	if not host.surface_material_paint.commit_prepared_images(prepared):
		return false
	host.board.material_blend.from_json(profile_json)
	host._invalidate_splatmap_projection()
	host.surface_material_paint.bind_profile(host.board.material_blend)
	host.material_profile_replayed.emit(profile_json.duplicate(true))
	host.request_render()
	return true
