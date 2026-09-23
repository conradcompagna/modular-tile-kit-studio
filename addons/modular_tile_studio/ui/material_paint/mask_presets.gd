@tool
extends RefCounted

## Mask presets behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Populate one explicit mask picker for both local strokes and the bottom procedural action.
static func _populate_mask_presets(host: MaterialPaintPanel, _workflow: int) -> void:
	host._mask.clear()
	host._mask.add_item("Choose a mask…", MaterialPaintPanel.MASK_SELECTION_REQUIRED)
	host._mask.set_item_disabled(0, true)
	host._mask.set_item_tooltip(
		0,
		"Choose one of the enabled masks below before any painting can begin."
	)
	for preset: int in range(MaterialPaintPanel.MaskPreset.BASE_HEIGHT_LOW, MaterialPaintPanel.MASK_PRESET_NAMES.size()):
		host._mask.add_item(MaterialPaintPanel.MASK_PRESET_NAMES[preset], preset)
		host._mask.set_item_tooltip(host._mask.item_count - 1, host._mask_preset_tooltip(preset))


## Explain every compact mask option without adding permanent instructional controls.
static func _mask_preset_tooltip(host: MaterialPaintPanel, preset: int) -> String:
	match preset:
		MaterialPaintPanel.MaskPreset.NONE:
			return "Allow the material everywhere the brush touches; the procedural button deliberately covers the whole level."
		MaterialPaintPanel.MaskPreset.BASE_HEIGHT_LOW, MaterialPaintPanel.MaskPreset.BASE_HEIGHT_HIGH:
			return "Use the selected PNG surface's own height channel, choosing its lower or upper percentage range."
		MaterialPaintPanel.MaskPreset.WORLD_HEIGHT_LOW, MaterialPaintPanel.MaskPreset.WORLD_HEIGHT_HIGH:
			return "Use the complete map-wide height field, choosing the bottom or top percentage of the level."
		MaterialPaintPanel.MaskPreset.BASE_CAVITY_LOW, MaterialPaintPanel.MaskPreset.BASE_CAVITY_HIGH:
			return "Use the PNG material's cavity channel to target recessed or exposed detail."
		MaterialPaintPanel.MaskPreset.BASE_CURVATURE_LOW, MaterialPaintPanel.MaskPreset.BASE_CURVATURE_HIGH:
			return "Use the PNG material's curvature channel to target concave or convex detail."
		MaterialPaintPanel.MaskPreset.BASE_AO_LOW, MaterialPaintPanel.MaskPreset.BASE_AO_HIGH:
			return "Use the PNG material's ambient-occlusion channel to target dark or exposed areas."
		MaterialPaintPanel.MaskPreset.BASE_ROUGHNESS_LOW, MaterialPaintPanel.MaskPreset.BASE_ROUGHNESS_HIGH:
			return "Use the PNG material's roughness channel to target smooth or rough areas."
		MaterialPaintPanel.MaskPreset.BASE_METALLIC_LOW, MaterialPaintPanel.MaskPreset.BASE_METALLIC_HIGH:
			return "Use the PNG material's metallic channel to target nonmetal or metal areas."
		MaterialPaintPanel.MaskPreset.BASE_LUMINANCE_LOW, MaterialPaintPanel.MaskPreset.BASE_LUMINANCE_HIGH:
			return "Use albedo brightness to target dark or light parts of the PNG surface."
		MaterialPaintPanel.MaskPreset.BASE_MATERIAL_ID_LOW, MaterialPaintPanel.MaskPreset.BASE_MATERIAL_ID_HIGH:
			return "Use the material-ID channel's lower or higher encoded percentage range."
		MaterialPaintPanel.MaskPreset.ABSOLUTE_ELEVATION_LOW, MaterialPaintPanel.MaskPreset.ABSOLUTE_ELEVATION_HIGH:
			return "Use absolute world elevation rather than the map-normalized height range."
		MaterialPaintPanel.MaskPreset.SURFACE_UP_LOW, MaterialPaintPanel.MaskPreset.SURFACE_UP_HIGH:
			return "Use surface orientation to target vertical faces or upward-facing surfaces."
		MaterialPaintPanel.MaskPreset.SURFACE_SLOPE_LOW, MaterialPaintPanel.MaskPreset.SURFACE_SLOPE_HIGH:
			return "Use derived slope to target gentle or steep terrain."
		MaterialPaintPanel.MaskPreset.SURFACE_BOTTOM, MaterialPaintPanel.MaskPreset.SURFACE_TOP:
			return "Use normalized height within each PNG surface to target its bottom or top."
		MaterialPaintPanel.MaskPreset.CONTACT_LOW, MaterialPaintPanel.MaskPreset.CONTACT_HIGH:
			return "Use the prop-contact field to target areas away from or near GLB footprints."
		MaterialPaintPanel.MaskPreset.SMOOTH_NOISE_LOW, MaterialPaintPanel.MaskPreset.SMOOTH_NOISE_HIGH:
			return "Use continuous multi-octave world noise for broad organic patches without square grid cells."
		MaterialPaintPanel.MaskPreset.RIDGED_NOISE_LOW, MaterialPaintPanel.MaskPreset.RIDGED_NOISE_HIGH:
			return "Use folded multi-octave noise for branching valleys or narrow ridges."
		MaterialPaintPanel.MaskPreset.CELLULAR_NOISE_LOW, MaterialPaintPanel.MaskPreset.CELLULAR_NOISE_HIGH:
			return "Use distance to irregular seeded points for rounded cell centres or broken borders."
		MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_LOW, MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_HIGH:
			return "Use noise-warped world-space bands with an explicit direction angle."
		MaterialPaintPanel.MaskPreset.CUSTOM:
			return "Open the complete ordered stack with every source, combine, channel, range, fade, influence, inversion, and noise control."
	return "Choose where this material may appear."


## Show and restore the direct result controls consumed by one simple mask preset.
static func _refresh_simple_mask_values(host: MaterialPaintPanel, layer: Dictionary, workflow: int, preset: int) -> void:
	var simple := (
		preset >= MaterialPaintPanel.MaskPreset.BASE_HEIGHT_LOW
		and preset <= MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_HIGH
	)
	host._range_low_row.visible = simple
	host._range_high_row.visible = simple
	host._fade_row.visible = simple
	host._influence_row.visible = simple
	host._invert.visible = simple
	var uses_noise := host._preset_uses_noise(preset)
	host._noise_scale_row.visible = uses_noise
	host._noise_seed_row.visible = uses_noise
	host._noise_angle_row.visible = host._preset_uses_directional_bands(preset)
	if not simple or layer.is_empty():
		return
	var masks_value: Variant = layer.get("masks", [])
	if not (masks_value is Array):
		return
	var masks: Array = masks_value
	var rule_index := 1 if workflow == MaterialPaintPanel.Workflow.PAINT else 0
	if rule_index >= masks.size() or not (masks[rule_index] is Dictionary):
		return
	var rule: Dictionary = masks[rule_index]
	host._range_low.set_value_no_signal(float(rule.get("range_low_percent", 0.0)))
	host._range_high.set_value_no_signal(float(rule.get("range_high_percent", 100.0)))
	host._fade.set_value_no_signal(float(rule.get("softness_percent", 10.0)))
	host._influence.set_value_no_signal(float(rule.get("strength_percent", 100.0)))
	host._invert.set_pressed_no_signal(bool(rule.get("invert", false)))
	host._noise_scale.set_value_no_signal(float(rule.get("noise_scale_m", 2.0)))
	host._noise_seed.set_value_no_signal(float(rule.get("noise_seed", 0)))
	host._noise_angle.set_value_no_signal(float(rule.get("noise_angle_degrees", 0.0)))
	for slider: HSlider in [
		host._range_low,
		host._range_high,
		host._fade,
		host._influence,
		host._noise_scale,
	]:
		host._update_slider_label(slider)


## Infer whether a stored mask stack maps exactly to a compact preset or needs the full editor.
static func _infer_mask_preset(host: MaterialPaintPanel, layer: Dictionary, workflow: int, layer_index: int) -> int:
	var masks_value: Variant = layer.get("masks", [])
	if not (masks_value is Array):
		return MaterialPaintPanel.MaskPreset.CUSTOM
	var masks: Array = masks_value
	var rule_index := 0
	if workflow == MaterialPaintPanel.Workflow.PAINT:
		if masks.is_empty() or not host._is_default_paint_rule(masks[0], layer_index):
			return MaterialPaintPanel.MaskPreset.CUSTOM
		if masks.size() == 1:
			return MaterialPaintPanel.MaskPreset.NONE
		if masks.size() != 2:
			return MaterialPaintPanel.MaskPreset.CUSTOM
		rule_index = 1
	elif masks.size() != 1:
		return MaterialPaintPanel.MaskPreset.CUSTOM
	var rule_value: Variant = masks[rule_index]
	if not (rule_value is Dictionary):
		return MaterialPaintPanel.MaskPreset.CUSTOM
	var rule: Dictionary = rule_value
	if (
		int(rule.get("combine", -1)) != MaterialBlendProfile.CombineOperation.MULTIPLY
		or int(rule.get("channel", 0)) != 0
	):
		return MaterialPaintPanel.MaskPreset.CUSTOM
	var low := float(rule.get("range_low_percent", 0.0))
	var high := float(rule.get("range_high_percent", 100.0))
	var uses_high_end := low + high > 100.0
	return host._preset_for_source(int(rule.get("source", -1)), uses_high_end)


## Return whether one paint rule is the automatic bridge between the brush and its palette channel.
static func _is_default_paint_rule(host: MaterialPaintPanel, value: Variant, layer_index: int) -> bool:
	if not (value is Dictionary):
		return false
	var rule: Dictionary = value
	return (
		int(rule.get("source", -1)) == MaterialBlendProfile.MaskSource.PAINT
		and int(rule.get("paint_channel", -1)) == layer_index
		and int(rule.get("combine", -1)) == MaterialBlendProfile.CombineOperation.MULTIPLY
		and is_equal_approx(float(rule.get("range_low_percent", -1.0)), 0.0)
		and is_equal_approx(float(rule.get("range_high_percent", -1.0)), 100.0)
		and is_equal_approx(float(rule.get("softness_percent", -1.0)), 10.0)
		and is_equal_approx(float(rule.get("strength_percent", -1.0)), 100.0)
		and not bool(rule.get("invert", false))
	)


## Return whether a compact preset is one of the four continuous world-space noises.
static func _preset_uses_noise(host: MaterialPaintPanel, preset: int) -> bool:
	return (
		preset >= MaterialPaintPanel.MaskPreset.SMOOTH_NOISE_LOW
		and preset <= MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_HIGH
	)


## Return whether a compact preset needs the explicit directional-band angle.
static func _preset_uses_directional_bands(host: MaterialPaintPanel, preset: int) -> bool:
	return preset in [
		MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_LOW,
		MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_HIGH,
	]


## Return whether one stored mask source consumes noise scale and seed controls.
static func _mask_source_uses_noise(host: MaterialPaintPanel, source: int) -> bool:
	return (
		source >= MaterialBlendProfile.MaskSource.SMOOTH_NOISE
		and source <= MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS
	)


## Map one compact preset to the exact mask kernel already consumed by the shader.
static func _preset_source(host: MaterialPaintPanel, preset: int) -> int:
	match preset:
		MaterialPaintPanel.MaskPreset.BASE_HEIGHT_LOW, MaterialPaintPanel.MaskPreset.BASE_HEIGHT_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_HEIGHT
		MaterialPaintPanel.MaskPreset.WORLD_HEIGHT_LOW, MaterialPaintPanel.MaskPreset.WORLD_HEIGHT_HIGH:
			return MaterialBlendProfile.MaskSource.WORLD_HEIGHT
		MaterialPaintPanel.MaskPreset.BASE_CAVITY_LOW, MaterialPaintPanel.MaskPreset.BASE_CAVITY_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_CAVITY
		MaterialPaintPanel.MaskPreset.BASE_CURVATURE_LOW, MaterialPaintPanel.MaskPreset.BASE_CURVATURE_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_CURVATURE
		MaterialPaintPanel.MaskPreset.BASE_AO_LOW, MaterialPaintPanel.MaskPreset.BASE_AO_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_AO
		MaterialPaintPanel.MaskPreset.BASE_ROUGHNESS_LOW, MaterialPaintPanel.MaskPreset.BASE_ROUGHNESS_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_ROUGHNESS
		MaterialPaintPanel.MaskPreset.BASE_METALLIC_LOW, MaterialPaintPanel.MaskPreset.BASE_METALLIC_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_METALLIC
		MaterialPaintPanel.MaskPreset.BASE_LUMINANCE_LOW, MaterialPaintPanel.MaskPreset.BASE_LUMINANCE_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_ALBEDO_LUMINANCE
		MaterialPaintPanel.MaskPreset.BASE_MATERIAL_ID_LOW, MaterialPaintPanel.MaskPreset.BASE_MATERIAL_ID_HIGH:
			return MaterialBlendProfile.MaskSource.BASE_MATERIAL_ID
		MaterialPaintPanel.MaskPreset.ABSOLUTE_ELEVATION_LOW, MaterialPaintPanel.MaskPreset.ABSOLUTE_ELEVATION_HIGH:
			return MaterialBlendProfile.MaskSource.ABSOLUTE_ELEVATION
		MaterialPaintPanel.MaskPreset.SURFACE_UP_LOW, MaterialPaintPanel.MaskPreset.SURFACE_UP_HIGH:
			return MaterialBlendProfile.MaskSource.SURFACE_UP
		MaterialPaintPanel.MaskPreset.SURFACE_SLOPE_LOW, MaterialPaintPanel.MaskPreset.SURFACE_SLOPE_HIGH:
			return MaterialBlendProfile.MaskSource.SURFACE_SLOPE
		MaterialPaintPanel.MaskPreset.SURFACE_BOTTOM:
			return MaterialBlendProfile.MaskSource.SURFACE_BOTTOM
		MaterialPaintPanel.MaskPreset.SURFACE_TOP:
			return MaterialBlendProfile.MaskSource.SURFACE_TOP
		MaterialPaintPanel.MaskPreset.CONTACT_LOW, MaterialPaintPanel.MaskPreset.CONTACT_HIGH:
			return MaterialBlendProfile.MaskSource.CONTACT
		MaterialPaintPanel.MaskPreset.SMOOTH_NOISE_LOW, MaterialPaintPanel.MaskPreset.SMOOTH_NOISE_HIGH:
			return MaterialBlendProfile.MaskSource.SMOOTH_NOISE
		MaterialPaintPanel.MaskPreset.RIDGED_NOISE_LOW, MaterialPaintPanel.MaskPreset.RIDGED_NOISE_HIGH:
			return MaterialBlendProfile.MaskSource.RIDGED_NOISE
		MaterialPaintPanel.MaskPreset.CELLULAR_NOISE_LOW, MaterialPaintPanel.MaskPreset.CELLULAR_NOISE_HIGH:
			return MaterialBlendProfile.MaskSource.CELLULAR_NOISE
		MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_LOW, MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_HIGH:
			return MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS
	return MaterialBlendProfile.MaskSource.PAINT


## Return whether a compact preset keeps the highest rather than lowest percentage range.
static func _preset_uses_high_end(host: MaterialPaintPanel, preset: int) -> bool:
	return preset in [
		MaterialPaintPanel.MaskPreset.BASE_HEIGHT_HIGH,
		MaterialPaintPanel.MaskPreset.WORLD_HEIGHT_HIGH,
		MaterialPaintPanel.MaskPreset.BASE_CAVITY_HIGH,
		MaterialPaintPanel.MaskPreset.BASE_CURVATURE_HIGH,
		MaterialPaintPanel.MaskPreset.BASE_AO_HIGH,
		MaterialPaintPanel.MaskPreset.BASE_ROUGHNESS_HIGH,
		MaterialPaintPanel.MaskPreset.BASE_METALLIC_HIGH,
		MaterialPaintPanel.MaskPreset.BASE_LUMINANCE_HIGH,
		MaterialPaintPanel.MaskPreset.BASE_MATERIAL_ID_HIGH,
		MaterialPaintPanel.MaskPreset.ABSOLUTE_ELEVATION_HIGH,
		MaterialPaintPanel.MaskPreset.SURFACE_UP_HIGH,
		MaterialPaintPanel.MaskPreset.SURFACE_SLOPE_HIGH,
		MaterialPaintPanel.MaskPreset.SURFACE_BOTTOM,
		MaterialPaintPanel.MaskPreset.SURFACE_TOP,
		MaterialPaintPanel.MaskPreset.CONTACT_HIGH,
		MaterialPaintPanel.MaskPreset.SMOOTH_NOISE_HIGH,
		MaterialPaintPanel.MaskPreset.RIDGED_NOISE_HIGH,
		MaterialPaintPanel.MaskPreset.CELLULAR_NOISE_HIGH,
		MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_HIGH,
	]


## Map one stored source and range direction back to its compact visible preset.
static func _preset_for_source(host: MaterialPaintPanel, source: int, high_end: bool) -> int:
	match source:
		MaterialBlendProfile.MaskSource.BASE_HEIGHT:
			return MaterialPaintPanel.MaskPreset.BASE_HEIGHT_HIGH if high_end else MaterialPaintPanel.MaskPreset.BASE_HEIGHT_LOW
		MaterialBlendProfile.MaskSource.WORLD_HEIGHT:
			return MaterialPaintPanel.MaskPreset.WORLD_HEIGHT_HIGH if high_end else MaterialPaintPanel.MaskPreset.WORLD_HEIGHT_LOW
		MaterialBlendProfile.MaskSource.BASE_CAVITY:
			return MaterialPaintPanel.MaskPreset.BASE_CAVITY_HIGH if high_end else MaterialPaintPanel.MaskPreset.BASE_CAVITY_LOW
		MaterialBlendProfile.MaskSource.BASE_CURVATURE:
			return MaterialPaintPanel.MaskPreset.BASE_CURVATURE_HIGH if high_end else MaterialPaintPanel.MaskPreset.BASE_CURVATURE_LOW
		MaterialBlendProfile.MaskSource.BASE_AO:
			return MaterialPaintPanel.MaskPreset.BASE_AO_HIGH if high_end else MaterialPaintPanel.MaskPreset.BASE_AO_LOW
		MaterialBlendProfile.MaskSource.BASE_ROUGHNESS:
			return MaterialPaintPanel.MaskPreset.BASE_ROUGHNESS_HIGH if high_end else MaterialPaintPanel.MaskPreset.BASE_ROUGHNESS_LOW
		MaterialBlendProfile.MaskSource.BASE_METALLIC:
			return MaterialPaintPanel.MaskPreset.BASE_METALLIC_HIGH if high_end else MaterialPaintPanel.MaskPreset.BASE_METALLIC_LOW
		MaterialBlendProfile.MaskSource.BASE_ALBEDO_LUMINANCE:
			return MaterialPaintPanel.MaskPreset.BASE_LUMINANCE_HIGH if high_end else MaterialPaintPanel.MaskPreset.BASE_LUMINANCE_LOW
		MaterialBlendProfile.MaskSource.BASE_MATERIAL_ID:
			return MaterialPaintPanel.MaskPreset.BASE_MATERIAL_ID_HIGH if high_end else MaterialPaintPanel.MaskPreset.BASE_MATERIAL_ID_LOW
		MaterialBlendProfile.MaskSource.ABSOLUTE_ELEVATION:
			return MaterialPaintPanel.MaskPreset.ABSOLUTE_ELEVATION_HIGH if high_end else MaterialPaintPanel.MaskPreset.ABSOLUTE_ELEVATION_LOW
		MaterialBlendProfile.MaskSource.SURFACE_UP:
			return MaterialPaintPanel.MaskPreset.SURFACE_UP_HIGH if high_end else MaterialPaintPanel.MaskPreset.SURFACE_UP_LOW
		MaterialBlendProfile.MaskSource.SURFACE_SLOPE:
			return MaterialPaintPanel.MaskPreset.SURFACE_SLOPE_HIGH if high_end else MaterialPaintPanel.MaskPreset.SURFACE_SLOPE_LOW
		MaterialBlendProfile.MaskSource.SURFACE_BOTTOM:
			return MaterialPaintPanel.MaskPreset.SURFACE_BOTTOM if high_end else MaterialPaintPanel.MaskPreset.CUSTOM
		MaterialBlendProfile.MaskSource.SURFACE_TOP:
			return MaterialPaintPanel.MaskPreset.SURFACE_TOP if high_end else MaterialPaintPanel.MaskPreset.CUSTOM
		MaterialBlendProfile.MaskSource.CONTACT:
			return MaterialPaintPanel.MaskPreset.CONTACT_HIGH if high_end else MaterialPaintPanel.MaskPreset.CONTACT_LOW
		MaterialBlendProfile.MaskSource.SMOOTH_NOISE:
			return MaterialPaintPanel.MaskPreset.SMOOTH_NOISE_HIGH if high_end else MaterialPaintPanel.MaskPreset.SMOOTH_NOISE_LOW
		MaterialBlendProfile.MaskSource.RIDGED_NOISE:
			return MaterialPaintPanel.MaskPreset.RIDGED_NOISE_HIGH if high_end else MaterialPaintPanel.MaskPreset.RIDGED_NOISE_LOW
		MaterialBlendProfile.MaskSource.CELLULAR_NOISE:
			return MaterialPaintPanel.MaskPreset.CELLULAR_NOISE_HIGH if high_end else MaterialPaintPanel.MaskPreset.CELLULAR_NOISE_LOW
		MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS:
			return MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_HIGH if high_end else MaterialPaintPanel.MaskPreset.DIRECTIONAL_BANDS_LOW
	return MaterialPaintPanel.MaskPreset.CUSTOM
