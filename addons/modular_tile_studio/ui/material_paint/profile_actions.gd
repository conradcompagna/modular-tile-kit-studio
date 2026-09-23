@tool
extends RefCounted

## Profile actions behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Ask for explicit confirmation before clearing one palette material's weights everywhere.
static func _request_remove_material(host: MaterialPaintPanel) -> void:
	host._pending_remove_layer = host._current_layer_index()
	if host._pending_remove_layer >= 0:
		host._remove_dialog.title = "Remove Brush Material"
		host._remove_dialog.dialog_text = "Remove this brush material and clear its face-local weights from every painted PNG surface?"
		host._remove_dialog.popup_centered()


## Ask before removing only the level-wide pass associated with the visible PNG thumbnail.
static func _request_remove_level_pass(host: MaterialPaintPanel) -> void:
	host._pending_remove_layer = host._find_layer_for_asset(
		host._current_asset_id(),
		MaterialPaintPanel.Workflow.PROCEDURAL
	)
	if host._pending_remove_layer >= 0:
		host._remove_dialog.title = "Remove Procedural Level Pass"
		host._remove_dialog.dialog_text = "Remove this level-wide pass while preserving the selected material's local brush strokes?"
		host._remove_dialog.popup_centered()


## Remove one palette material atomically and clear only its corresponding sparse weights.
static func _remove_current_material(host: MaterialPaintPanel) -> void:
	if host._pending_remove_layer < 0 or host._draft == null:
		return
	var removed_layer := host._pending_remove_layer
	var removed_mode := int(
		host._draft.layer(removed_layer).get(
			"application_mode",
			MaterialBlendProfile.ApplicationMode.BRUSH
		)
	)
	host._pending_remove_layer = -1
	var paint_patches: Dictionary = {}
	if host.viewport != null and host.viewport.surface_material_paint != null:
		paint_patches = host.viewport.surface_material_paint.clear_palette_material(removed_layer)
	host._draft.set_layer(removed_layer, MaterialBlendProfile.default_layer(removed_layer))
	var splatmap_slots := host._draft.splatmap_palette_indices.duplicate()
	for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		if splatmap_slots[channel_index] == removed_layer:
			splatmap_slots[channel_index] = -1
	host._draft.splatmap_palette_indices = splatmap_slots
	for workflow: int in [MaterialPaintPanel.Workflow.PAINT, MaterialPaintPanel.Workflow.PROCEDURAL]:
		if host._selected_layers[workflow] == removed_layer:
			host._selected_layers[workflow] = host._find_first_layer(workflow)
	host._commit_profile(
		(
			"Remove procedural level pass"
			if removed_mode == MaterialBlendProfile.ApplicationMode.PROCEDURAL
			else "Remove brush material"
		),
		UndoRedo.MERGE_DISABLE,
		paint_patches
	)
	host._refresh_main_controls()


## Ask for explicit confirmation before clearing every canonical brush-authored weight image.
static func _request_clear_paint(host: MaterialPaintPanel) -> void:
	host._clear_dialog.popup_centered()


## Clear brush-authored splat images while leaving all procedural layer rules unchanged.
static func _clear_brush_paint(host: MaterialPaintPanel) -> void:
	if host.viewport == null:
		return
	host.viewport.clear_surface_material_paint(true)
	host._status.text = "Brush paint cleared; procedural materials and source PNGs were preserved."


## Commit the visible profile through the viewport's scoped refresh planner.
##
## A failed source-projection change restores both the canonical board profile and
## its visible draft before any undo entry is registered.
static func _commit_profile(host: MaterialPaintPanel,
	action_name: String = "Change surface material",
	merge_mode: int = UndoRedo.MERGE_DISABLE,
	paint_patches: Dictionary = {}
) -> bool:
	if host.board == null or host.viewport == null or host._draft == null:
		return false
	var before_json := host.board.material_blend.to_json().duplicate(true)
	for index: int in host._draft.layer_count():
		var layer := host._draft.layer(index)
		layer["opacity_percent"] = 100.0
		if String(layer.get("asset_id", "")).is_empty():
			layer["enabled"] = false
		host._draft.set_layer(index, layer)
	host._draft.enabled = host._draft.has_active_layers()
	var after_json := host._draft.to_json().duplicate(true)
	if before_json == after_json and paint_patches.is_empty():
		host._update_status()
		return true
	host.board.material_blend.from_json(after_json)
	host.viewport.set_material_pressure_controls(
		host._draft.pressure_controls_size,
		host._draft.pressure_controls_opacity
	)
	if not host.viewport.refresh_material_profile_change(before_json):
		host.board.material_blend.from_json(before_json)
		host._draft.from_json(before_json)
		host.viewport.set_material_pressure_controls(
			host._draft.pressure_controls_size,
			host._draft.pressure_controls_opacity
		)
		if not host.viewport.refresh_material_profile_change(after_json):
			push_error("[Tile Studio] The previous material profile could not be restored visibly.")
		host._update_status()
		return false
	host.viewport.register_material_profile_undo(
		before_json,
		after_json,
		action_name,
		merge_mode,
		paint_patches
	)
	host._update_status()
	return true
