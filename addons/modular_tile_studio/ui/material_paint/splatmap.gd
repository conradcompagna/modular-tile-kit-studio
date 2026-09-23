@tool
extends RefCounted

## Splatmap behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Open the splatmap importer with the current four layer assignments made fully visible.
##
## Empty initial slots are suggested from distinct PNG assets, but suggestions stay inside this
## unapplied dialog and therefore cannot silently change the board.
static func _open_splatmap_import(host: MaterialPaintPanel) -> void:
	if host._splatmap_dialog == null:
		return
	var choices := host._surface_assets_newest_first()
	# Preserve a valid pending selection after a rejected assignment so reopening the
	# upload dialog does not force the user through the filesystem browser again.
	if (
		host._draft != null
		and host._splatmap_path.text.is_empty()
	):
		host._splatmap_path.text = host._draft.splatmap_source_path
	var desired_ids := PackedStringArray(["", "", "", ""])
	var claimed: Dictionary = {}
	if host._draft != null:
		for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
			var palette_index := host._draft.splatmap_palette_indices[channel_index]
			if palette_index < 0 or palette_index >= host._draft.layer_count():
				continue
			var current_id := String(host._draft.layer(palette_index).get("asset_id", ""))
			desired_ids[channel_index] = current_id
			if not current_id.is_empty():
				claimed[current_id] = true
	for channel_index: int in mini(3, MaterialBlendProfile.WEIGHTS_PER_TEXEL):
		if not desired_ids[channel_index].is_empty():
			continue
		for asset: TileAsset in choices:
			if not claimed.has(asset.asset_id):
				desired_ids[channel_index] = asset.asset_id
				claimed[asset.asset_id] = true
				break
	host._splatmap_slot_asset_state = desired_ids
	host._populate_splatmap_picker(choices)
	for layer_index: int in host._splatmap_slots.size():
		host._refresh_splatmap_slot_button(layer_index)
	host._update_splatmap_summary()
	host._splatmap_dialog.popup_centered_clamped(Vector2i(560, 500), 0.85)


## Open the native file picker without mutating the pending import.
static func _browse_splatmap(host: MaterialPaintPanel) -> void:
	if host._splatmap_file_dialog == null or host._splatmap_dialog == null:
		return
	host._splatmap_dialog.hide()
	host.call_deferred("_show_splatmap_file_dialog")


## Show the file picker only after the exclusive setup dialog has fully closed.
static func _show_splatmap_file_dialog(host: MaterialPaintPanel) -> void:
	host._splatmap_file_dialog.popup_centered_ratio(0.75)


## Store the exact chosen source path and return to the visible loading dialog.
static func _on_splatmap_file_selected(host: MaterialPaintPanel, path: String) -> void:
	host._splatmap_path.text = path
	host._update_splatmap_summary()
	host.call_deferred("_reopen_splatmap_dialog")


## Return to the loading dialog when the native file picker is cancelled.
static func _on_splatmap_file_dialog_canceled(host: MaterialPaintPanel) -> void:
	host.call_deferred("_reopen_splatmap_dialog")


## Reopen the clamped setup dialog so its Load button remains on screen.
static func _reopen_splatmap_dialog(host: MaterialPaintPanel) -> void:
	if host._splatmap_dialog != null:
		host._splatmap_dialog.popup_centered_clamped(Vector2i(560, 500), 0.85)


## Populate the shared RGBA thumbnail grid from the same newest-first asset sequence as painting.
static func _populate_splatmap_picker(host: MaterialPaintPanel, choices: Array[TileAsset]) -> void:
	host._splatmap_picker_gallery.clear()
	host._splatmap_picker_asset_ids.clear()
	var unused_index := host._splatmap_picker_gallery.add_item("Unused")
	host._splatmap_picker_gallery.set_item_tooltip(
		unused_index,
		"Do not import this RGBA channel or allocate a material layer for it."
	)
	host._splatmap_picker_asset_ids.append("")
	for asset: TileAsset in choices:
		var display := asset.display_name if not asset.display_name.is_empty() else asset.asset_id
		var thumbnail := host._load_asset_thumbnail(asset)
		var item_index := host._splatmap_picker_gallery.add_item(display, thumbnail)
		host._splatmap_picker_gallery.set_item_metadata(item_index, asset.asset_id)
		host._splatmap_picker_gallery.set_item_tooltip(
			item_index,
			"%s\n%s\nImported %s"
			% [display, asset.asset_id, String(asset.processing.get("imported_at", ""))]
		)
		host._splatmap_picker_asset_ids.append(asset.asset_id)


## Open the thumbnail selector for one explicit RGBA channel without changing its assignment.
static func _open_splatmap_slot_picker(host: MaterialPaintPanel, layer_index: int) -> void:
	if (
		host._splatmap_picker_popup == null
		or layer_index < 0
		or layer_index >= host._splatmap_slots.size()
	):
		return
	host._active_splatmap_slot = layer_index
	var channel_names := PackedStringArray(["R · Layer 1", "G · Layer 2", "B · Layer 3", "A · Layer 4"])
	host._splatmap_picker_title.text = "Choose %s material — newest first" % channel_names[layer_index]
	host._splatmap_picker_gallery.deselect_all()
	var selected_item := host._splatmap_picker_asset_ids.find(host._splatmap_slot_asset_state[layer_index])
	if selected_item < 0:
		selected_item = 0
	host._splatmap_picker_gallery.select(selected_item)
	host._splatmap_picker_gallery.ensure_current_is_visible()
	host._splatmap_picker_popup.popup_centered_clamped(Vector2i(680, 500), 0.85)


## Store one thumbnail choice into its visible RGBA slot and close the shared picker.
static func _on_splatmap_picker_selected(host: MaterialPaintPanel, item_index: int) -> void:
	if (
		host._active_splatmap_slot < 0
		or host._active_splatmap_slot >= host._splatmap_slot_asset_state.size()
		or item_index < 0
		or item_index >= host._splatmap_picker_asset_ids.size()
	):
		return
	host._splatmap_slot_asset_state[host._active_splatmap_slot] = host._splatmap_picker_asset_ids[item_index]
	host._refresh_splatmap_slot_button(host._active_splatmap_slot)
	host._update_splatmap_summary()
	host._splatmap_picker_popup.hide()


## Refresh one compact channel button from the exact stable asset id it currently represents.
static func _refresh_splatmap_slot_button(host: MaterialPaintPanel, layer_index: int) -> void:
	if layer_index < 0 or layer_index >= host._splatmap_slots.size():
		return
	var asset_id := host._splatmap_slot_asset_state[layer_index]
	var display := "Unused — choose a material…"
	var thumbnail: Texture2D = null
	if not asset_id.is_empty():
		var asset := host.library.get_asset(asset_id) if host.library != null else null
		if asset == null or not asset.is_surface():
			push_error("MaterialPaintPanel: RGBA slot references unavailable surface asset '%s'." % asset_id)
			display = "%s — unavailable" % asset_id
		else:
			display = asset.display_name if not asset.display_name.is_empty() else asset.asset_id
			thumbnail = host._load_asset_thumbnail(asset)
	host._splatmap_slot_previews[layer_index].texture = thumbnail
	host._splatmap_slot_labels[layer_index].text = display
	host._splatmap_slots[layer_index].tooltip_text = (
		"Selected: %s. Open the newest-first thumbnail library for this RGBA channel."
		% display
	)


## Return the four stable asset ids represented by the visible RGBA thumbnail buttons.
static func _splatmap_slot_asset_ids(host: MaterialPaintPanel) -> PackedStringArray:
	var asset_ids := PackedStringArray()
	for asset_id: String in host._splatmap_slot_asset_state:
		asset_ids.append(asset_id)
	return asset_ids


## Return the four main-panel channel-strength sliders as normalized multipliers.
static func _visible_splatmap_strengths(host: MaterialPaintPanel) -> Vector4:
	if host._splatmap_channel_strength_sliders.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		return Vector4.ONE
	return Vector4(
		host._splatmap_channel_strength_sliders[0].value / 100.0,
		host._splatmap_channel_strength_sliders[1].value / 100.0,
		host._splatmap_channel_strength_sliders[2].value / 100.0,
		host._splatmap_channel_strength_sliders[3].value / 100.0
	)


## Enable the four main-panel strength sliders only when adjustment is visibly armed.
static func _update_splatmap_live_controls(host: MaterialPaintPanel) -> void:
	if host._splatmap_empty_region_channel != null:
		host._splatmap_empty_region_channel.disabled = host._draft == null
		for channel_index: int in MaterialPaintPanel.SPLATMAP_CHANNEL_NAMES.size():
			var asset_id := ""
			var assigned := false
			if host._draft != null:
				var layer := host._draft.layer(channel_index)
				asset_id = String(layer.get("asset_id", ""))
				assigned = bool(layer.get("enabled", false)) and not asset_id.is_empty()
			host._splatmap_empty_region_channel.set_item_text(
				channel_index,
				"%s — %s" % [
					MaterialPaintPanel.SPLATMAP_CHANNEL_NAMES[channel_index],
					asset_id if assigned else "Unassigned",
				]
			)
			host._splatmap_empty_region_channel.set_item_disabled(channel_index, not assigned)
	var strengths_enabled := (
		host._splatmap_channel_strengths_enabled != null
		and host._splatmap_channel_strengths_enabled.button_pressed
	)
	for slider: HSlider in host._splatmap_channel_strength_sliders:
		slider.editable = strengths_enabled
		host._update_slider_label(slider)


## Return whether one visible RGBA input maps to an enabled palette material.
static func _splatmap_channel_assigned(host: MaterialPaintPanel, channel: int) -> bool:
	if host._draft == null or channel < 0 or channel >= MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		return false
	var palette_index := host._draft.splatmap_palette_indices[channel]
	if palette_index < 0 or palette_index >= host._draft.layer_count():
		return false
	var layer := host._draft.layer(palette_index)
	return (
		bool(layer.get("enabled", false))
		and not String(layer.get("asset_id", "")).is_empty()
	)


## Commit one main-panel source option through the shared scoped refresh planner.
static func _on_splatmap_live_option_changed(host: MaterialPaintPanel, _value: Variant) -> void:
	if host._updating or host._draft == null or host.board == null or host.viewport == null:
		return
	var selected_base_channel := host._splatmap_empty_region_channel.get_selected_id()
	if (
		host._splatmap_fill_empty_regions.button_pressed
		and not host._splatmap_channel_assigned(selected_base_channel)
	):
		host._refresh_main_controls()
		host._status.text = "Assign a material to the selected empty-region base channel first."
		return
	var previous_fill := host._draft.splatmap_fill_empty_regions
	var previous_base_channel := host._draft.splatmap_empty_region_channel
	host._draft.splatmap_fill_empty_regions = host._splatmap_fill_empty_regions.button_pressed
	host._draft.splatmap_empty_region_channel = selected_base_channel
	host._draft.splatmap_channel_strengths_enabled = (
		host._splatmap_channel_strengths_enabled.button_pressed
	)
	host._draft.splatmap_channel_strengths = host._visible_splatmap_strengths()
	var rebuild_source := (
		previous_fill != host._draft.splatmap_fill_empty_regions
		or previous_base_channel != host._draft.splatmap_empty_region_channel
	)
	if not host._commit_profile(
		(
			"Change splatmap empty-region base fill"
			if rebuild_source
			else "Adjust splatmap channel strengths"
		),
		UndoRedo.MERGE_ENDS
	):
		host._refresh_main_controls()
		host._status.text = "Splatmap settings could not be applied; the previous state was restored."
		return
	host._update_splatmap_live_controls()
	host._update_status()


## Show the exact channel mapping and whether the explicit import action is ready.
static func _update_splatmap_summary(host: MaterialPaintPanel) -> void:
	if host._splatmap_summary == null or host._splatmap_dialog == null:
		return
	var asset_ids := host._splatmap_slot_asset_ids()
	var mappings := PackedStringArray()
	var channel_names := PackedStringArray(["R", "G", "B", "A"])
	var active_count := 0
	for layer_index: int in asset_ids.size():
		var asset_id := asset_ids[layer_index]
		var display := "Unused"
		if not asset_id.is_empty():
			active_count += 1
			var asset := host.library.get_asset(asset_id) if host.library != null else null
			display = (
				asset.display_name
				if asset != null and not asset.display_name.is_empty()
				else asset_id
			)
		mappings.append("%s → %s" % [channel_names[layer_index], display])
	var has_path := host._splatmap_path != null and not host._splatmap_path.text.is_empty()
	host._splatmap_summary.text = (
		" · ".join(mappings)
		+ "\nLoad this source and its four material assignments. Main-panel projection, "
		+ "empty-region extension, and channel strengths remain unchanged. Reassigning a "
		+ "channel affects future stamps; existing faces keep their recorded local slots."
	)
	host._splatmap_dialog.get_ok_button().disabled = not has_path or active_count == 0


## Load the visible source and slot mapping without changing canonical terrain paint.
static func _apply_splatmap_import(host: MaterialPaintPanel) -> void:
	if host.viewport == null or host._splatmap_path == null:
		return
	var source := Image.new()
	var load_error := source.load(host._splatmap_path.text)
	if load_error != OK:
		host._status.text = "Splatmap could not be loaded: %s." % error_string(load_error)
		return
	var result := host.viewport.import_terrain_splatmap(
		source,
		host._splatmap_slot_asset_ids(),
		host._splatmap_path.text
	)
	if int(result.get("error", FAILED)) != OK:
		host._status.text = String(result.get(
			"message",
			"Splatmap load failed; the previous materials and paint are unchanged."
		))
		return
	if host._draft == null:
		host._draft = MaterialBlendProfile.new()
	host._draft.from_json(host.board.material_blend.to_json())
	host._selected_layers[MaterialPaintPanel.Workflow.PAINT] = host._find_first_layer(MaterialPaintPanel.Workflow.PAINT)
	host._selected_layers[MaterialPaintPanel.Workflow.PROCEDURAL] = host._find_first_layer(MaterialPaintPanel.Workflow.PROCEDURAL)
	host._pending_assets[MaterialPaintPanel.Workflow.PAINT] = ""
	host._pending_assets[MaterialPaintPanel.Workflow.PROCEDURAL] = ""
	host._refresh_main_controls()
	host.tile_brush_mode_changed.emit(host.uses_tile_brush())
	var bounds: Rect2i = result.get("terrain_bounds", Rect2i())
	host._status.text = (
		"Loaded the RGBA source over %d %s-projection faces at bounds %s. Terrain paint "
		+ "is unchanged, the square face brush is active, and the overlay is off."
	) % [
		int(result.get("face_count", 0)),
		MaterialPaintPanel.SPLATMAP_PROJECTION_NAMES[int(host._draft.splatmap_projection)],
		str(bounds),
	]
