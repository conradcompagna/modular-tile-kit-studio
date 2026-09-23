@tool
extends RefCounted

## Mask stack behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Open the complete ordered mask editor for the selected material without adding a setup step.
static func _open_mask_stack(host: MaterialPaintPanel) -> void:
	if host._current_layer_index() < 0 or host._draft == null:
		return
	host._selected_rule = 0
	host._refresh_mask_dialog()
	host._mask_dialog.popup_centered(Vector2i(520, 620))


## Populate the mask source selector with palette entries for paint or RGBA components for derived maps.
static func _populate_rule_channel_options(host: MaterialPaintPanel, source: int, selected_id: int) -> void:
	host._rule_channel.clear()
	if source == MaterialBlendProfile.MaskSource.PAINT:
		for palette_index: int in host._draft.layer_count():
			var layer := host._draft.layer(palette_index)
			var asset_id := String(layer.get("asset_id", ""))
			var display := "Palette %d — Unassigned" % (palette_index + 1)
			if not asset_id.is_empty():
				var asset: TileAsset = host.library.get_asset(asset_id) if host.library != null else null
				display = (
					asset.display_name
					if asset != null and not asset.display_name.is_empty()
					else asset_id
				)
				display = "Palette %d — %s" % [palette_index + 1, display]
			host._rule_channel.add_item(display, palette_index)
			host._rule_channel.set_item_disabled(
				host._rule_channel.item_count - 1,
				asset_id.is_empty()
			)
		host._rule_channel.tooltip_text = (
			"Choose the board-palette material whose painted face weight this condition samples."
		)
	else:
		for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
			host._rule_channel.add_item(MaterialPaintPanel.SPLATMAP_CHANNEL_NAMES[channel_index], channel_index)
		host._rule_channel.tooltip_text = "Choose the R, G, B, or A component sampled from this derived source."
	var selected_item := host._rule_channel.get_item_index(selected_id)
	if selected_item >= 0:
		host._rule_channel.select(selected_item)


## Refresh every custom mask field from the one stored layer mask stack.
static func _refresh_mask_dialog(host: MaterialPaintPanel) -> void:
	var layer_index := host._current_layer_index()
	if layer_index < 0 or host._draft == null:
		return
	var masks := host._draft.layer_masks(layer_index)
	host._updating = true
	host._rule_select.clear()
	for index: int in masks.size():
		var name := "Brush strokes" if host._workflow() == MaterialPaintPanel.Workflow.PAINT and index == 0 else "Condition %d" % (index + 1)
		host._rule_select.add_item(name, index)
		host._rule_select.set_item_tooltip(
			index,
			(
				"Required local-stroke gate; add another condition to constrain it."
				if host._workflow() == MaterialPaintPanel.Workflow.PAINT and index == 0
				else "Ordered mask condition %d." % index
			)
		)
	host._selected_rule = clampi(host._selected_rule, 0, maxi(masks.size() - 1, 0))
	if not masks.is_empty():
		host._rule_select.select(host._selected_rule)
	var has_rule := not masks.is_empty()
	var protected_paint_rule := host._workflow() == MaterialPaintPanel.Workflow.PAINT and host._selected_rule == 0
	host._remove_rule_button.disabled = not has_rule or protected_paint_rule or masks.size() <= 1
	host._add_rule_button.disabled = masks.size() >= 4
	if has_rule:
		var rule: Dictionary = masks[host._selected_rule]
		var rule_source := int(rule.get("source", MaterialBlendProfile.MaskSource.PAINT))
		host._rule_source.select(host._rule_source.get_item_index(rule_source))
		host._rule_combine.select(host._rule_combine.get_item_index(int(rule.get("combine", 0))))
		var channel := (
			int(rule.get("paint_channel", layer_index))
			if rule_source == MaterialBlendProfile.MaskSource.PAINT
			else int(rule.get("channel", 0))
		)
		host._populate_rule_channel_options(rule_source, channel)
		host._rule_low.value = float(rule.get("range_low_percent", 0.0))
		host._rule_high.value = float(rule.get("range_high_percent", 100.0))
		host._rule_fade.value = float(rule.get("softness_percent", 10.0))
		host._rule_strength.value = float(rule.get("strength_percent", 100.0))
		host._rule_invert.button_pressed = bool(rule.get("invert", false))
		host._rule_noise_scale.value = float(rule.get("noise_scale_m", 2.0))
		host._rule_noise_seed.value = float(rule.get("noise_seed", 0))
		host._rule_noise_angle.value = float(rule.get("noise_angle_degrees", 0.0))
	host._rule_source.disabled = protected_paint_rule
	host._rule_combine.disabled = protected_paint_rule
	host._rule_channel.disabled = protected_paint_rule
	host._rule_low.editable = not protected_paint_rule
	host._rule_high.editable = not protected_paint_rule
	host._rule_fade.editable = not protected_paint_rule
	host._rule_strength.editable = not protected_paint_rule
	host._rule_invert.disabled = protected_paint_rule
	host._rule_noise_scale.editable = not protected_paint_rule
	host._rule_noise_seed.editable = not protected_paint_rule
	host._rule_noise_angle.editable = not protected_paint_rule
	var selected_source := (
		int(masks[host._selected_rule].get("source", MaterialBlendProfile.MaskSource.PAINT))
		if has_rule
		else MaterialBlendProfile.MaskSource.PAINT
	)
	var uses_noise := host._mask_source_uses_noise(selected_source)
	host._rule_noise_scale.get_parent().visible = uses_noise
	host._rule_noise_seed.get_parent().visible = uses_noise
	host._rule_noise_angle.get_parent().visible = (
		selected_source == MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS
	)
	host._updating = false


## Switch the full mask editor to one stored condition without modifying its values.
static func _on_rule_selected(host: MaterialPaintPanel, index: int) -> void:
	if host._updating:
		return
	host._selected_rule = index
	host._refresh_mask_dialog()


## Append one explicit mask condition while preserving the shader's four-rule kernel limit.
static func _add_mask_rule(host: MaterialPaintPanel) -> void:
	var layer_index := host._current_layer_index()
	if layer_index < 0 or host._draft == null:
		return
	var masks := host._draft.layer_masks(layer_index)
	if masks.size() >= 4:
		host._status.text = "Each material supports four ordered mask conditions."
		return
	masks.append(MaterialBlendProfile.default_rule(MaterialBlendProfile.MaskSource.BASE_HEIGHT, layer_index))
	host._draft.set_layer_masks(layer_index, masks)
	host._selected_rule = masks.size() - 1
	host._commit_profile("Add material mask condition")
	host._refresh_mask_dialog()
	host._refresh_main_controls()


## Remove one optional mask condition while retaining the mandatory brush bridge in Paint mode.
static func _remove_mask_rule(host: MaterialPaintPanel) -> void:
	var layer_index := host._current_layer_index()
	if layer_index < 0 or host._draft == null:
		return
	var masks := host._draft.layer_masks(layer_index)
	if masks.size() <= 1 or (host._workflow() == MaterialPaintPanel.Workflow.PAINT and host._selected_rule == 0):
		return
	masks.remove_at(host._selected_rule)
	host._draft.set_layer_masks(layer_index, masks)
	host._selected_rule = clampi(host._selected_rule, 0, masks.size() - 1)
	host._commit_profile("Remove material mask condition")
	host._refresh_mask_dialog()
	host._refresh_main_controls()


## Commit one full mask rule edit directly to the same layer consumed by the compact presets.
static func _on_rule_value_changed(host: MaterialPaintPanel, _value: Variant) -> void:
	if host._updating or host._draft == null:
		return
	var layer_index := host._current_layer_index()
	if layer_index < 0:
		return
	var masks := host._draft.layer_masks(layer_index)
	if host._selected_rule < 0 or host._selected_rule >= masks.size():
		return
	var rule: Dictionary = masks[host._selected_rule]
	var protected_paint_rule := host._workflow() == MaterialPaintPanel.Workflow.PAINT and host._selected_rule == 0
	if protected_paint_rule:
		return
	var previous_source := int(rule.get("source", MaterialBlendProfile.MaskSource.PAINT))
	var source := host._rule_source.get_selected_id()
	if source != previous_source:
		host._updating = true
		host._populate_rule_channel_options(
			source,
			layer_index if source == MaterialBlendProfile.MaskSource.PAINT else 0
		)
		host._updating = false
	rule["source"] = source
	rule["combine"] = host._rule_combine.get_selected_id()
	if source == MaterialBlendProfile.MaskSource.PAINT:
		rule["paint_channel"] = host._rule_channel.get_selected_id()
	else:
		rule["channel"] = host._rule_channel.get_selected_id()
	rule["range_low_percent"] = host._rule_low.value
	rule["range_high_percent"] = host._rule_high.value
	rule["softness_percent"] = host._rule_fade.value
	rule["strength_percent"] = host._rule_strength.value
	rule["invert"] = host._rule_invert.button_pressed
	rule["noise_scale_m"] = host._rule_noise_scale.value
	rule["noise_seed"] = roundi(host._rule_noise_seed.value)
	rule["noise_angle_degrees"] = host._rule_noise_angle.value
	masks[host._selected_rule] = rule
	host._draft.set_layer_masks(layer_index, masks)
	var layer := host._draft.layer(layer_index)
	layer["enabled"] = true
	layer["opacity_percent"] = 100.0
	host._draft.set_layer(layer_index, layer)
	host._commit_profile("Edit material mask condition", UndoRedo.MERGE_ENDS)
	host._refresh_main_controls()
