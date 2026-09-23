@tool
extends RefCounted

## Paint history behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Register an already-applied material-profile edit with optional sparse channel removal.
##
## Procedural rules store only small JSON dictionaries, while a removed painted channel carries
## sparse changed pixels, so undo never snapshots geometry, GLBs, or complete board textures.
static func register_material_profile_undo(host: MTSStudioViewport,
	before_json: Dictionary,
	after_json: Dictionary,
	action_name: String,
	merge_mode: int = UndoRedo.MERGE_DISABLE,
	paint_patches: Dictionary = {}
) -> void:
	if host._height_undo_redo == null:
		return
	if before_json == after_json and paint_patches.is_empty():
		return
	host._height_undo_redo.create_action(action_name, merge_mode, null, false)
	host._height_undo_redo.add_do_method(host, "_apply_material_profile_json", after_json.duplicate(true))
	if not paint_patches.is_empty():
		host._height_undo_redo.add_do_method(
			host,
			"_apply_material_paint_patch",
			paint_patches.duplicate(true),
			"after"
		)
	host._height_undo_redo.add_undo_method(host, "_apply_material_profile_json", before_json.duplicate(true))
	if not paint_patches.is_empty():
		host._height_undo_redo.add_undo_method(
			host,
			"_apply_material_paint_patch",
			paint_patches.duplicate(true),
			"before"
		)
	host._height_undo_redo.commit_action(false)


## Replay one material profile and its ordered sparse paint edits for board-wide undo or redo.
##
## Undo reverses the patch order because several removed palette entries may have
## touched the same face-local slots during the original atomic operation.
static func replay_material_profile_and_patches(host: MTSStudioViewport,
	profile_json: Dictionary,
	paint_patch_steps: Array,
	value_key: String,
	reverse_patches: bool = false
) -> void:
	host._apply_material_profile_json(profile_json)
	var ordered_steps := paint_patch_steps.duplicate(true)
	if reverse_patches:
		ordered_steps.reverse()
	for patches_value: Variant in ordered_steps:
		if not patches_value is Dictionary:
			push_error("[Tile Studio] Material removal undo contains an invalid paint patch.")
			continue
		host._apply_material_paint_patch(patches_value as Dictionary, value_key)
	host.request_render()


## Apply one saved material profile during undo or redo through the same scoped refresh planner.
static func _apply_material_profile_json(host: MTSStudioViewport, profile_json: Dictionary) -> void:
	if host.board == null or host.board.material_blend == null:
		push_error("[Tile Studio] Cannot replay a material profile without an active board.")
		return
	var before_json := host.board.material_blend.to_json().duplicate(true)
	host.board.material_blend.from_json(profile_json)
	if not host.refresh_material_profile_change(before_json):
		push_error("[Tile Studio] Material profile replay could not refresh its visible source projection.")
	host.material_profile_replayed.emit(profile_json.duplicate(true))
