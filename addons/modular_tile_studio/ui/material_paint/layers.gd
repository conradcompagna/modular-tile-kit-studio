@tool
extends RefCounted

## Layers behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Allocate one stable palette entry and initialize it for exactly one visible workflow.
static func _allocate_layer(host: MaterialPaintPanel, asset_id: String, workflow: int, preset: int = MaterialPaintPanel.MaskPreset.NONE) -> int:
	var index := host._find_empty_layer()
	if index < 0:
		index = host._draft.add_layer(MaterialBlendProfile.default_layer(host._draft.layer_count()))
	var had_active_layers := host._draft.has_active_layers()
	var layer := MaterialBlendProfile.default_layer(index)
	layer["asset_id"] = asset_id
	layer["application_mode"] = (
		MaterialBlendProfile.ApplicationMode.BRUSH
		if workflow == MaterialPaintPanel.Workflow.PAINT
		else MaterialBlendProfile.ApplicationMode.PROCEDURAL
	)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	if workflow == MaterialPaintPanel.Workflow.PAINT:
		layer["masks"] = host._simple_mask_rules(preset, workflow, index)
	else:
		layer["masks"] = host._simple_mask_rules(preset, workflow, index)
	host._draft.set_layer(index, layer)
	if not had_active_layers:
		host._draft.blend_mode = MaterialBlendProfile.BlendMode.NORMALIZED_SPLAT
	host._selected_layers[workflow] = index
	host._pending_assets[workflow] = ""
	host._commit_profile(
		"Add brush material" if workflow == MaterialPaintPanel.Workflow.PAINT else "Add procedural material"
	)
	return index


## Build the exact stored mask stack represented by the visible preset controls.
static func _simple_mask_rules(host: MaterialPaintPanel, preset: int, workflow: int, layer_index: int) -> Array:
	var rules: Array = []
	if workflow == MaterialPaintPanel.Workflow.PAINT:
		rules.append(MaterialBlendProfile.default_rule(MaterialBlendProfile.MaskSource.PAINT, layer_index))
	if preset == MaterialPaintPanel.MaskPreset.NONE:
		return rules
	var rule := MaterialBlendProfile.default_rule(host._preset_source(preset), layer_index)
	rule["range_low_percent"] = host._range_low.value
	rule["range_high_percent"] = host._range_high.value
	rule["softness_percent"] = host._fade.value
	rule["strength_percent"] = host._influence.value
	rule["invert"] = host._invert.button_pressed
	rule["channel"] = 0
	if host._preset_uses_noise(preset):
		rule["noise_scale_m"] = host._noise_scale.value
		rule["noise_seed"] = roundi(host._noise_seed.value)
	if host._preset_uses_directional_bands(preset):
		rule["noise_angle_degrees"] = host._noise_angle.value
	rules.append(rule)
	return rules


## Copy the visible brush constraints while removing only its structural own-channel paint rule.
static func _procedural_rules_from_brush_layer(host: MaterialPaintPanel,
	brush_layer: Dictionary,
	brush_layer_index: int
) -> Array:
	var result: Array = []
	var masks_value: Variant = brush_layer.get("masks", [])
	if not (masks_value is Array):
		return result
	var removed_structural_rule := false
	for value: Variant in masks_value as Array:
		if not (value is Dictionary):
			continue
		var rule := value as Dictionary
		if (
			not removed_structural_rule
			and host._is_default_paint_rule(rule, brush_layer_index)
		):
			removed_structural_rule = true
			continue
		result.append(rule.duplicate(true))
	return result


## Run the visible whole-level action for either the loaded splatmap or one procedural material layer.
static func _apply_procedural_level(host: MaterialPaintPanel) -> void:
	if host._draft == null or host.viewport == null:
		return
	if host._splatmap_mode_enabled():
		if host._draft.splatmap_source_path.is_empty():
			host._status.text = "Load an RGBA splatmap before painting the entire terrain."
			return
		if host.viewport.paint_entire_terrain_from_splatmap():
			host._status.text = (
				"Painted every %s-projection terrain face from the loaded RGBA splatmap."
				% MaterialPaintPanel.SPLATMAP_PROJECTION_NAMES[int(host._draft.splatmap_projection)]
			)
		else:
			host._status.text = "Whole-terrain splatmap paint failed; existing terrain paint was preserved."
		return
	var brush_layer_index := host._selected_layers[MaterialPaintPanel.Workflow.PAINT]
	if brush_layer_index < 0:
		host._update_status()
		return
	var brush_layer := host._draft.layer(brush_layer_index)
	var asset_id := String(brush_layer.get("asset_id", ""))
	if asset_id.is_empty():
		return
	var draft_before_json := host._draft.to_json().duplicate(true)
	var selected_before := int(host._selected_layers[MaterialPaintPanel.Workflow.PROCEDURAL])
	var procedural_layer_index := host._find_layer_for_asset(
		asset_id,
		MaterialPaintPanel.Workflow.PROCEDURAL
	)
	var updating_existing := procedural_layer_index >= 0
	if procedural_layer_index < 0:
		procedural_layer_index = host._find_empty_layer()
	if procedural_layer_index < 0:
		procedural_layer_index = host._draft.add_layer(
			MaterialBlendProfile.default_layer(host._draft.layer_count())
		)
	var procedural_layer := MaterialBlendProfile.default_layer(procedural_layer_index)
	procedural_layer["asset_id"] = asset_id
	procedural_layer["application_mode"] = MaterialBlendProfile.ApplicationMode.PROCEDURAL
	procedural_layer["enabled"] = true
	procedural_layer["opacity_percent"] = 100.0
	procedural_layer["texture_scale_percent"] = float(
		brush_layer.get("texture_scale_percent", 100.0)
	)
	procedural_layer["height_blend_percent"] = float(
		brush_layer.get("height_blend_percent", 0.0)
	)
	procedural_layer["masks"] = host._procedural_rules_from_brush_layer(
		brush_layer,
		brush_layer_index
	)
	host._draft.set_layer(procedural_layer_index, procedural_layer)
	host._selected_layers[MaterialPaintPanel.Workflow.PROCEDURAL] = procedural_layer_index
	# A level-wide pass must be representable on every face before either the
	# palette recipe or any face mapping is committed.
	var assignment := host.viewport.assign_material_palette_to_all_faces(procedural_layer_index)
	if int(assignment.get("error", FAILED)) != OK:
		host._draft.from_json(draft_before_json)
		host._selected_layers[MaterialPaintPanel.Workflow.PROCEDURAL] = selected_before
		host._status.text = (
			"Cannot apply this level pass: terrain face '%s' already uses four painted "
			+ "materials. Existing palette and paint were preserved."
		) % String(assignment.get("face_uid", "unknown"))
		return
	var paint_patches: Dictionary = assignment.get("patches", {})
	host._commit_profile(
		(
			"Update procedural level pass"
			if updating_existing
			else "Procedurally paint level"
		),
		UndoRedo.MERGE_DISABLE,
		paint_patches
	)
	host._refresh_main_controls()


## Select one PNG visually without creating, enabling, or otherwise mutating a material layer.
static func _on_material_selected(host: MaterialPaintPanel, index: int) -> void:
	if host._updating or host._draft == null:
		return
	var asset_id := (
		host._material_asset_ids[index]
		if index >= 0 and index < host._material_asset_ids.size()
		else ""
	)
	if asset_id.is_empty():
		host._update_status()
		return
	var workflow := MaterialPaintPanel.Workflow.PAINT
	var existing := host._find_layer_for_asset(asset_id, workflow)
	if existing >= 0:
		host._selected_layers[workflow] = existing
		host._pending_assets[workflow] = ""
	else:
		host._selected_layers[workflow] = -1
		host._pending_assets[workflow] = asset_id
	if host._no_constraint_mode_enabled():
		host._ensure_no_constraint_layer(asset_id)
	host._refresh_main_controls()


## Ensure one selected PNG is stored as an enabled paint-only overlay layer.
static func _ensure_no_constraint_layer(host: MaterialPaintPanel, asset_id: String) -> int:
	if host._draft == null or asset_id.is_empty():
		return -1
	var workflow := MaterialPaintPanel.Workflow.PAINT
	var layer_index := host._find_layer_for_asset(asset_id, workflow)
	if layer_index < 0:
		return host._allocate_layer(asset_id, workflow, MaterialPaintPanel.MaskPreset.NONE)
	host._selected_layers[workflow] = layer_index
	host._pending_assets[workflow] = ""
	var layer := host._draft.layer(layer_index)
	var already_unconstrained := (
		host._infer_mask_preset(layer, workflow, layer_index) == MaterialPaintPanel.MaskPreset.NONE
		and bool(layer.get("enabled", false))
	)
	if already_unconstrained:
		return layer_index
	layer["masks"] = host._simple_mask_rules(MaterialPaintPanel.MaskPreset.NONE, workflow, layer_index)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	host._draft.set_layer(layer_index, layer)
	host._commit_profile("Set No Constraint material")
	return layer_index


## Replace the current compact preset immediately while preserving the complete custom editor path.
static func _on_mask_selected(host: MaterialPaintPanel, _index: int) -> void:
	if host._updating or host._draft == null:
		return
	var preset := host._mask.get_selected_id()
	if preset == MaterialPaintPanel.MASK_SELECTION_REQUIRED:
		return
	host._set_simple_mask_defaults(preset)
	var workflow := MaterialPaintPanel.Workflow.PAINT
	var layer_index := host._selected_layers[workflow]
	if preset == MaterialPaintPanel.MaskPreset.CUSTOM:
		if layer_index < 0 and not host._pending_assets[workflow].is_empty():
			layer_index = host._allocate_layer(
				host._pending_assets[workflow],
				workflow,
				MaterialPaintPanel.MaskPreset.NONE
			)
		if layer_index >= 0:
			host._open_mask_stack()
		return
	if layer_index < 0:
		if host._pending_assets[workflow].is_empty():
			host._update_status()
			return
		layer_index = host._allocate_layer(host._pending_assets[workflow], workflow, preset)
		if layer_index < 0:
			return
	var layer := host._draft.layer(layer_index)
	layer["masks"] = host._simple_mask_rules(preset, workflow, layer_index)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	host._draft.set_layer(layer_index, layer)
	# Choosing the mask completes the ordinary three-step workflow, so it arms
	# this material for painting while the visible toggle remains available to release input.
	host._mask_paint_mode.set_pressed_no_signal(true)
	host._clear_other_paint_modes(host._mask_paint_mode)
	host._commit_profile("Set brush mask")
	host._refresh_main_controls()


## Initialize a newly chosen simple mask to a useful low or high twenty-percent range.
static func _set_simple_mask_defaults(host: MaterialPaintPanel, preset: int) -> void:
	if preset < MaterialPaintPanel.MaskPreset.BASE_HEIGHT_LOW or preset > MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_HIGH:
		return
	if host._preset_uses_high_end(preset):
		host._range_low.set_value_no_signal(80.0)
		host._range_high.set_value_no_signal(100.0)
	else:
		host._range_low.set_value_no_signal(0.0)
		host._range_high.set_value_no_signal(20.0)
	host._fade.set_value_no_signal(10.0)
	host._influence.set_value_no_signal(100.0)
	host._invert.set_pressed_no_signal(false)
	host._noise_scale.set_value_no_signal(2.0)
	host._noise_seed.set_value_no_signal(0.0)
	host._noise_angle.set_value_no_signal(0.0)


## Keep Range High visibly valid when the user raises the lower bound past it.
static func _on_range_low_changed(host: MaterialPaintPanel, value: float) -> void:
	if not host._updating and value > host._range_high.value:
		host._range_high.set_value_no_signal(value)
	host._on_simple_mask_value_changed(value)


## Keep Range Low visibly valid when the user lowers the upper bound past it.
static func _on_range_high_changed(host: MaterialPaintPanel, value: float) -> void:
	if not host._updating and value < host._range_low.value:
		host._range_low.set_value_no_signal(value)
	host._on_simple_mask_value_changed(value)


## Update a simple mask's visible controls without changing material resources or geometry.
static func _on_simple_mask_value_changed(host: MaterialPaintPanel, _value: Variant) -> void:
	for slider: HSlider in [
		host._range_low,
		host._range_high,
		host._fade,
		host._influence,
		host._noise_scale,
	]:
		host._update_slider_label(slider)
	if host._updating or host._draft == null:
		return
	var preset := host._mask.get_selected_id()
	if preset < MaterialPaintPanel.MaskPreset.BASE_HEIGHT_LOW or preset > MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_HIGH:
		return
	var workflow := MaterialPaintPanel.Workflow.PAINT
	var layer_index := host._selected_layers[workflow]
	if layer_index < 0:
		return
	var layer := host._draft.layer(layer_index)
	layer["masks"] = host._simple_mask_rules(preset, workflow, layer_index)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	host._draft.set_layer(layer_index, layer)
	host._commit_profile("Adjust brush mask", UndoRedo.MERGE_ENDS)
	host._update_status()
