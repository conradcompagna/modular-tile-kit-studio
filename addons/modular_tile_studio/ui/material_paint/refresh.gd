@tool
extends RefCounted

## Refresh behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Refresh the one visible local setup and the explicit procedural action from canonical state.
static func _refresh_main_controls(host: MaterialPaintPanel) -> void:
	if host._material_gallery == null or host._procedural_button == null:
		return
	host._updating = true
	var workflow := MaterialPaintPanel.Workflow.PAINT
	var splatmap_mode := host._splatmap_mode_enabled()
	var has_splatmap_source := (
		host._draft != null and not host._draft.splatmap_source_path.is_empty()
	)
	var has_splatmap_layers := host._draft != null and host._find_first_layer(MaterialPaintPanel.Workflow.PAINT) >= 0
	host._splatmap_mode.disabled = host._draft == null
	host._splatmap_mode.set_pressed_no_signal(splatmap_mode)
	host._splatmap_projection.get_parent().visible = splatmap_mode
	host._splatmap_projection.disabled = host._draft == null
	var projection := (
		int(host._draft.splatmap_projection)
		if host._draft != null
		else MaterialBlendProfile.SplatmapProjection.TOP
	)
	host._splatmap_projection.select(host._splatmap_projection.get_item_index(projection))
	host._splatmap_overlay.visible = splatmap_mode
	host._splatmap_overlay.disabled = not has_splatmap_source
	host._splatmap_overlay.set_pressed_no_signal(
		host._draft.splatmap_overlay_enabled if host._draft != null else false
	)
	host._splatmap_live_controls_box.visible = splatmap_mode
	host._splatmap_fill_empty_regions.disabled = host._draft == null
	host._splatmap_fill_empty_regions.set_pressed_no_signal(
		host._draft.splatmap_fill_empty_regions if host._draft != null else false
	)
	host._splatmap_empty_region_channel.disabled = host._draft == null
	host._splatmap_empty_region_channel.select(
		host._splatmap_empty_region_channel.get_item_index(
			host._draft.splatmap_empty_region_channel if host._draft != null else 0
		)
	)
	host._splatmap_channel_strengths_enabled.disabled = host._draft == null
	host._splatmap_channel_strengths_enabled.set_pressed_no_signal(
		host._draft.splatmap_channel_strengths_enabled if host._draft != null else false
	)
	var visible_strengths := (
		host._draft.splatmap_channel_strengths
		if host._draft != null
		else Vector4.ONE
	)
	var visible_strength_values := [
		visible_strengths.x,
		visible_strengths.y,
		visible_strengths.z,
		visible_strengths.w,
	]
	for channel_index: int in host._splatmap_channel_strength_sliders.size():
		host._splatmap_channel_strength_sliders[channel_index].set_value_no_signal(
			float(visible_strength_values[channel_index]) * 100.0
		)
	host._update_splatmap_live_controls()
	host._splatmap_setup_button.disabled = host._draft == null
	host._splatmap_workflow_box.visible = splatmap_mode
	host._material_gallery_label.visible = not splatmap_mode
	host._material_gallery.visible = not splatmap_mode
	host._no_constraint_mode.visible = not splatmap_mode
	host._mask_paint_mode.visible = not splatmap_mode
	host._mask_preview.visible = not splatmap_mode
	host._decal_mode.visible = not splatmap_mode
	host._shader_decal_mode.visible = not splatmap_mode
	host._decal_edge_mode.visible = host._stamp_mode_active() and not splatmap_mode
	host._decal_edge_mode.disabled = false
	host._populate_splatmap_channel_gallery()
	var layer_index := host._selected_layers[workflow]
	var pending_asset := host._pending_assets[workflow]
	var layer := host._draft.layer(layer_index) if host._draft != null and layer_index >= 0 else {}
	var asset_id := String(layer.get("asset_id", pending_asset))
	host._select_material(asset_id)
	host._populate_mask_presets(workflow)
	var preset := MaterialPaintPanel.MASK_SELECTION_REQUIRED
	if layer_index >= 0:
		preset = host._infer_mask_preset(layer, workflow, layer_index)
	var preset_item := host._mask.get_item_index(preset)
	if preset_item >= 0:
		host._mask.select(preset_item)
	host._refresh_simple_mask_values(layer, workflow, preset)
	var has_layer := layer_index >= 0
	var has_material := not asset_id.is_empty()
	# Stamp modes commit placements rather than editing face-local material weights, so the
	# main RGBA workflow hides and disarms them while it owns the base-coat brush.
	var decal_mode := host._stamp_mode_active()
	# This explicit ownership switch remains user-controlled even while its material setup is
	# incomplete. The status text exposes missing setup, and choosing another mode turns it off.
	var no_constraint_mode := host._no_constraint_mode_enabled()
	if no_constraint_mode and has_layer and preset != MaterialPaintPanel.MaskPreset.NONE:
		host._no_constraint_mode.set_pressed_no_signal(false)
		no_constraint_mode = false
	var has_mask_constraint := has_layer and preset != MaterialPaintPanel.MaskPreset.NONE
	if not has_mask_constraint:
		host._mask_paint_mode.set_pressed_no_signal(false)
	var mask_paint_mode := host._mask_paint_mode_enabled()
	host._no_constraint_mode.disabled = host._draft == null
	host._no_constraint_mode.set_pressed_no_signal(no_constraint_mode)
	host._mask_paint_mode.disabled = not has_mask_constraint or no_constraint_mode
	host._mask_row.visible = not no_constraint_mode and not splatmap_mode
	host._mask.disabled = not has_material or decal_mode or no_constraint_mode
	if not has_layer or decal_mode or splatmap_mode or no_constraint_mode:
		host._mask_preview.set_pressed_no_signal(false)
	host._mask_preview.visible = not splatmap_mode and not no_constraint_mode
	host._mask_preview.disabled = not has_layer or decal_mode or splatmap_mode or no_constraint_mode
	# The preview evaluates one stored layer's mask stack, so a PNG holding no splat
	# channel has nothing to show. Name that on the control itself rather than leaving a
	# greyed checkbox whose reason is only reachable through the status line.
	host._mask_preview.tooltip_text = host._mask_preview_tooltip(has_layer, decal_mode)
	var tile_target_selected := host._paint_target_mode() == MaterialPaintPanel.PaintTarget.TILE_BRUSH
	var local_layer_mode := mask_paint_mode or no_constraint_mode
	host._brush_box.visible = has_layer and local_layer_mode and not decal_mode and not splatmap_mode
	host._paint_target.disabled = not has_layer or not local_layer_mode or decal_mode or splatmap_mode
	if host._brush_radius_row != null:
		host._brush_radius_row.visible = not tile_target_selected
	if host._hardness_row != null:
		host._hardness_row.visible = not tile_target_selected
	# Palette matching is meaningful for either explicit decal presentation.
	if host._match_underlying_palette != null:
		host._match_underlying_palette.visible = decal_mode and not splatmap_mode
	var procedural_layer := host._find_layer_for_asset(asset_id, MaterialPaintPanel.Workflow.PROCEDURAL)
	if splatmap_mode:
		host._procedural_button.disabled = not has_splatmap_source or not has_splatmap_layers
		host._procedural_button.text = "PAINT ENTIRE TERRAIN FROM SPLATMAP"
	else:
		host._procedural_button.disabled = not has_layer or decal_mode
		host._procedural_button.text = (
			"UPDATE PROCEDURAL LEVEL PASS"
			if procedural_layer >= 0
			else "PROCEDURALLY PAINT LEVEL"
		)
	host._refresh_more_menu(has_layer and not decal_mode)
	host._updating = false
	host._update_viewport_tool()
	host._update_status()


## Describe either what the mask preview does or the exact reason it is unavailable.
##
## The checkbox reads one stored layer's mask stack, so it stays greyed while the selected
## PNG has no palette entry. Which of the two blocking states applies decides what the
## user has to do next, so the tooltip names the state instead of only the requirement.
static func _mask_preview_tooltip(host: MaterialPaintPanel, has_layer: bool, decal_mode: bool) -> String:
	if decal_mode:
		return (
			"Unavailable while a decal stamp owns the brush, because a stamp commits a "
			+ "placement instead of painting into a layer mask. Turn the stamp mode off to "
			+ "preview a mask."
		)
	if not has_layer:
		return (
			"Unavailable until the selected PNG is added to the board palette. Choose a "
			+ "mask to create its inspectable material entry."
		)
	return MaterialPaintPanel.MASK_PREVIEW_TOOLTIP


## Enable only the overflow actions that have a selected material to operate on.
static func _refresh_more_menu(host: MaterialPaintPanel, has_layer: bool) -> void:
	if host._more_menu == null:
		return
	var popup := host._more_menu.get_popup()
	for action: int in [
		MaterialPaintPanel.MoreAction.MATERIAL_APPEARANCE,
		MaterialPaintPanel.MoreAction.MASK_STACK,
		MaterialPaintPanel.MoreAction.REMOVE_MATERIAL,
	]:
		var item_index := popup.get_item_index(action)
		if item_index >= 0:
			popup.set_item_disabled(item_index, not has_layer)
	var remove_level_index := popup.get_item_index(MaterialPaintPanel.MoreAction.REMOVE_LEVEL_PASS)
	if remove_level_index >= 0:
		var asset_id := host._current_asset_id()
		popup.set_item_disabled(
			remove_level_index,
			host._find_layer_for_asset(asset_id, MaterialPaintPanel.Workflow.PROCEDURAL) < 0
		)


## Route the one compact overflow menu to focused non-overlapping editors or destructive actions.
static func _on_more_action_selected(host: MaterialPaintPanel, action: int) -> void:
	match action:
		MaterialPaintPanel.MoreAction.MATERIAL_APPEARANCE:
			host._open_material_settings()
		MaterialPaintPanel.MoreAction.MASK_STACK:
			host._open_mask_stack()
		MaterialPaintPanel.MoreAction.PAINT_SYSTEM:
			host._open_system_settings()
		MaterialPaintPanel.MoreAction.REMOVE_MATERIAL:
			host._request_remove_material()
		MaterialPaintPanel.MoreAction.REMOVE_LEVEL_PASS:
			host._request_remove_level_pass()
		MaterialPaintPanel.MoreAction.CLEAR_BRUSH_PAINT:
			host._request_clear_paint()
