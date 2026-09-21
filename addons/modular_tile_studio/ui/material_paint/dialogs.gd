@tool
extends RefCounted

## Dialogs behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Build the focused material dialog for the two non-overlapping layer appearance controls.
static func _build_material_dialog(host: MaterialPaintPanel) -> void:
	host._material_dialog = AcceptDialog.new()
	host._material_dialog.title = "Material Appearance"
	host._material_dialog.dialog_text = ""
	host.add_child(host._material_dialog)
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(430.0, 120.0)
	host._material_dialog.add_child(content)
	host._material_scale = host._add_slider(content, "Texture scale", 1.0, 800.0, 1.0, 100.0, "%", true, "Scale this material's texture repetition without changing the geometry or source PNG.")
	host._material_scale.value_changed.connect(host._on_material_settings_changed)
	host._material_height_blend = host._add_slider(content, "Height blend", 0.0, 100.0, 1.0, 0.0, "%", false, "Bias transitions using the incoming material's height channel so raised details overlap naturally.")
	host._material_height_blend.value_changed.connect(host._on_material_settings_changed)


## Build the complete mask-stack editor so every existing mask kernel remains directly controllable.
static func _build_mask_dialog(host: MaterialPaintPanel) -> void:
	host._mask_dialog = AcceptDialog.new()
	host._mask_dialog.title = "Mask Stack"
	host.add_child(host._mask_dialog)
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(480.0, 470.0)
	host._mask_dialog.add_child(content)
	host._rule_select = host._add_option(content, "Condition", PackedStringArray(["Condition 1"]), "Select which ordered mask condition the fields below edit.")
	host._rule_select.item_selected.connect(host._on_rule_selected)
	var buttons := HBoxContainer.new()
	host._add_rule_button = Button.new()
	host._add_rule_button.text = "Add condition"
	host._add_rule_button.tooltip_text = "Append another mask condition; up to four conditions are evaluated in order."
	host._add_rule_button.pressed.connect(host._add_mask_rule)
	buttons.add_child(host._add_rule_button)
	host._remove_rule_button = Button.new()
	host._remove_rule_button.text = "Remove condition"
	host._remove_rule_button.tooltip_text = "Remove the selected condition while keeping the remaining condition order intact."
	host._remove_rule_button.pressed.connect(host._remove_mask_rule)
	buttons.add_child(host._remove_rule_button)
	content.add_child(buttons)
	host._rule_source = host._add_option(content, "Source", MaterialPaintPanel.MASK_SOURCE_NAMES, "Choose the stored or derived channel sampled by this condition.")
	host._rule_source.item_selected.connect(host._on_rule_value_changed)
	host._rule_combine = host._add_option(content, "Combine", MaterialPaintPanel.COMBINE_NAMES, "Choose how this condition combines with the accumulated mask above it.")
	host._rule_combine.item_selected.connect(host._on_rule_value_changed)
	host._rule_channel = host._add_option(content, "Channel", PackedStringArray(["R", "G", "B", "A"]), "Choose the sampled component when the selected source contains multiple channels.")
	host._rule_channel.item_selected.connect(host._on_rule_value_changed)
	host._rule_low = host._add_spin(content, "Range low %", 0.0, 100.0, 1.0, 0.0, "Set the lowest source percentage accepted by this condition.")
	host._rule_low.value_changed.connect(host._on_rule_value_changed)
	host._rule_high = host._add_spin(content, "Range high %", 0.0, 100.0, 1.0, 100.0, "Set the highest source percentage accepted by this condition.")
	host._rule_high.value_changed.connect(host._on_rule_value_changed)
	host._rule_fade = host._add_spin(content, "Edge fade %", 0.0, 100.0, 1.0, 10.0, "Feather both ends of this condition's accepted range.")
	host._rule_fade.value_changed.connect(host._on_rule_value_changed)
	host._rule_strength = host._add_spin(content, "Influence %", 0.0, 100.0, 1.0, 100.0, "Scale this condition's contribution before it combines with the accumulated mask.")
	host._rule_strength.value_changed.connect(host._on_rule_value_changed)
	host._rule_invert = CheckButton.new()
	host._rule_invert.text = "Invert this condition"
	host._rule_invert.tooltip_text = "Swap accepted and rejected portions of this condition before combining it."
	host._rule_invert.toggled.connect(host._on_rule_value_changed)
	content.add_child(host._rule_invert)
	host._rule_noise_scale = host._add_spin(content, "Noise scale m", 0.01, 10000.0, 0.01, 2.0, "Set the world-space feature size for any of the four noise sources.")
	host._rule_noise_scale.value_changed.connect(host._on_rule_value_changed)
	host._rule_noise_seed = host._add_spin(content, "Noise seed", -100000.0, 100000.0, 1.0, 0.0, "Choose a deterministic alternate pattern for any of the four noise sources.")
	host._rule_noise_seed.value_changed.connect(host._on_rule_value_changed)
	host._rule_noise_angle = host._add_spin(content, "Band angle", 0.0, 360.0, 1.0, 0.0, "Set the explicit world-space direction used only by Directional Bands.")
	host._rule_noise_angle.suffix = "°"
	host._rule_noise_angle.value_changed.connect(host._on_rule_value_changed)


## Build the focused RGBA import dialog that maps visible assets directly to four paint slots.
##
## Import is an explicit expensive action; choosing a path or slot changes no board state until
## the user presses Load, and the displayed orientation is the one the backend consumes.
static func _build_splatmap_dialog(host: MaterialPaintPanel) -> void:
	host._splatmap_dialog = AcceptDialog.new()
	host._splatmap_dialog.title = "Load RGBA Terrain Splatmap"
	host._splatmap_dialog.get_ok_button().text = "LOAD SPLATMAP"
	host._splatmap_dialog.confirmed.connect(host._apply_splatmap_import)
	host.add_child(host._splatmap_dialog)
	var content_scroll := ScrollContainer.new()
	content_scroll.custom_minimum_size = Vector2(520.0, 340.0)
	content_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	host._splatmap_dialog.add_child(content_scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_scroll.add_child(content)
	var note := Label.new()
	note.text = (
		"R/G/B/A become material slots 1/2/3/4. Projection is selected in the main panel. "
		+ "Top uses +X/+Z; North and South use +X/high-to-low Y; East and West use "
		+ "+Z/high-to-low Y. Leave A unused for an opaque RGB image."
	)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(note)
	var path_row := host._row(content, "Control map", "Choose one PNG, JPEG, or WebP RGBA weight field.")
	host._splatmap_path = LineEdit.new()
	host._splatmap_path.editable = false
	host._splatmap_path.placeholder_text = "Choose an RGBA splatmap image…"
	host._splatmap_path.tooltip_text = "The external RGBA image sampled over the selected direction's complete terrain-face bounds."
	host._splatmap_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(host._splatmap_path)
	var browse := Button.new()
	browse.text = "Browse…"
	browse.pressed.connect(host._browse_splatmap)
	path_row.add_child(browse)
	host._splatmap_slots.clear()
	host._splatmap_slot_previews.clear()
	host._splatmap_slot_labels.clear()
	var channel_names := PackedStringArray(["R · Layer 1", "G · Layer 2", "B · Layer 3", "A · Layer 4"])
	for layer_index: int in channel_names.size():
		var slot_row := host._row(
			content,
			channel_names[layer_index],
			"Choose the PNG material rendered wherever this control-map channel has weight."
		)
		var slot := Button.new()
		slot.custom_minimum_size.y = 54.0
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.tooltip_text = "Open the newest-first thumbnail library for this RGBA channel."
		slot.pressed.connect(host._open_splatmap_slot_picker.bind(layer_index))
		slot_row.add_child(slot)
		var slot_content := HBoxContainer.new()
		slot_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot_content.offset_left = 8.0
		slot_content.offset_top = 5.0
		slot_content.offset_right = -8.0
		slot_content.offset_bottom = -5.0
		slot_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(slot_content)
		var preview := TextureRect.new()
		preview.custom_minimum_size = Vector2(44.0, 44.0)
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_content.add_child(preview)
		var selected_label := Label.new()
		selected_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		selected_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		selected_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		selected_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_content.add_child(selected_label)
		var disclosure := Label.new()
		disclosure.text = "▾"
		disclosure.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		disclosure.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_content.add_child(disclosure)
		host._splatmap_slots.append(slot)
		host._splatmap_slot_previews.append(preview)
		host._splatmap_slot_labels.append(selected_label)
	host._splatmap_summary = Label.new()
	host._splatmap_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(host._splatmap_summary)
	host._splatmap_picker_popup = PopupPanel.new()
	host.add_child(host._splatmap_picker_popup)
	var picker_content := VBoxContainer.new()
	picker_content.custom_minimum_size = Vector2(650.0, 450.0)
	host._splatmap_picker_popup.add_child(picker_content)
	host._splatmap_picker_title = Label.new()
	host._splatmap_picker_title.text = "Choose material — newest first"
	picker_content.add_child(host._splatmap_picker_title)
	host._splatmap_picker_gallery = ItemList.new()
	host._splatmap_picker_gallery.custom_minimum_size = Vector2(650.0, 420.0)
	host._splatmap_picker_gallery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._splatmap_picker_gallery.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host._splatmap_picker_gallery.icon_mode = ItemList.ICON_MODE_TOP
	host._splatmap_picker_gallery.fixed_icon_size = MaterialPaintPanel.MATERIAL_THUMBNAIL_SIZE
	host._splatmap_picker_gallery.fixed_column_width = 112
	host._splatmap_picker_gallery.same_column_width = true
	host._splatmap_picker_gallery.max_columns = 5
	host._splatmap_picker_gallery.allow_reselect = true
	host._splatmap_picker_gallery.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	host._splatmap_picker_gallery.tooltip_text = "Choose by thumbnail; materials are ordered from newest import to oldest."
	host._splatmap_picker_gallery.item_selected.connect(host._on_splatmap_picker_selected)
	picker_content.add_child(host._splatmap_picker_gallery)
	host._splatmap_file_dialog = FileDialog.new()
	host._splatmap_file_dialog.title = "Choose RGBA Splatmap"
	host._splatmap_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	host._splatmap_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	# The native Windows browser generates bounded shell thumbnails instead of asking
	# Godot to decode every unrelated image in the current filesystem directory.
	host._splatmap_file_dialog.use_native_dialog = true
	host._splatmap_file_dialog.display_mode = FileDialog.DISPLAY_THUMBNAILS
	host._splatmap_file_dialog.add_filter("*.png, *.jpg, *.jpeg, *.webp", "Image files")
	host._splatmap_file_dialog.file_selected.connect(host._on_splatmap_file_selected)
	host._splatmap_file_dialog.canceled.connect(host._on_splatmap_file_dialog_canceled)
	host.add_child(host._splatmap_file_dialog)


## Build one compact system dialog for global algorithms that do not belong in either workflow.
static func _build_settings_dialog(host: MaterialPaintPanel) -> void:
	host._settings_dialog = AcceptDialog.new()
	host._settings_dialog.title = "Paint System"
	host.add_child(host._settings_dialog)
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(450.0, 405.0)
	host._settings_dialog.add_child(content)
	host._blend_mode = host._add_option(
		content,
		"Splat algorithm",
		PackedStringArray(["Independent layers", "True normalized splat"]),
		"Independent layers overlap in order; normalized splat shares one total weight among the base and painted materials."
	)
	host._blend_mode.item_selected.connect(host._on_system_settings_changed)
	host._debug_view = host._add_option(content, "Debug preview", MaterialPaintPanel.DEBUG_NAMES, "Replace the beauty view with one exact mask or source channel for diagnosis; Final Material restores normal rendering.")
	host._debug_view.item_selected.connect(host._on_system_settings_changed)
	host._paint_detail = host._add_spin(
		content,
		"Paint texels / metre",
		float(MaterialBlendProfile.MIN_TEXELS_PER_METRE),
		float(MaterialBlendProfile.MAX_TEXELS_PER_METRE),
		4.0,
		64.0,
		"Set canonical brush-mask detail per world metre. Low values save CPU and GPU memory but make mask edges coarser."
	)
	host._paint_detail.value_changed.connect(host._on_resolution_settings_changed)
	host._maximum_edge = host._add_spin(
		content,
		"Maximum edge px",
		float(MaterialBlendProfile.MIN_SURFACE_EDGE_PX),
		float(MaterialBlendProfile.MAX_SURFACE_EDGE_PX),
		16.0,
		512.0,
		"Cap either dimension of each placement mask. This is the strongest memory limit for large surfaces."
	)
	host._maximum_edge.value_changed.connect(host._on_resolution_settings_changed)
	host._paint_memory_summary = Label.new()
	host._paint_memory_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	host._paint_memory_summary.tooltip_text = "Shows canonical CPU RGBA8 bytes plus derived GPU Texture2DArray RGBA8 texel bytes; graphics-driver overhead is excluded."
	content.add_child(host._paint_memory_summary)
	host._apply_resolution_button = Button.new()
	host._apply_resolution_button.text = "APPLY PAINT MASK RESOLUTION"
	host._apply_resolution_button.tooltip_text = "Atomically resample existing canonical masks and rebuild only their derived texture arrays; the operation has an exact compressed undo snapshot."
	host._apply_resolution_button.pressed.connect(host._request_resolution_rebuild)
	content.add_child(host._apply_resolution_button)
	host._pressure_size = CheckButton.new()
	host._pressure_size.text = "Stylus pressure controls brush size"
	host._pressure_size.tooltip_text = "When enabled, pen pressure multiplies the visible brush radius for each pointer sample."
	host._pressure_size.toggled.connect(host._on_system_settings_changed)
	content.add_child(host._pressure_size)
	host._pressure_opacity = CheckButton.new()
	host._pressure_opacity.text = "Stylus pressure controls brush strength"
	host._pressure_opacity.tooltip_text = "When enabled, pen pressure multiplies how strongly each stroke changes splat weight."
	host._pressure_opacity.toggled.connect(host._on_system_settings_changed)
	content.add_child(host._pressure_opacity)
	host._auto_texture_thin_side_slivers = CheckButton.new()
	host._auto_texture_thin_side_slivers.text = "Auto-texture <0.1 m side slivers"
	host._auto_texture_thin_side_slivers.tooltip_text = (
		"When enabled, an unpainted side strip shorter than 0.1 m at a wall's top or "
		+ "bottom uses the nearest complete 1 m square on that same side grid. "
		+ "Direct paint on the strip always overrides this derived seed."
	)
	host._auto_texture_thin_side_slivers.toggled.connect(host._on_auto_texture_thin_side_slivers_toggled)
	content.add_child(host._auto_texture_thin_side_slivers)


## Build explicit confirmations for operations that remove or resample canonical authored weights.
static func _build_confirmation_dialogs(host: MaterialPaintPanel) -> void:
	host._remove_dialog = ConfirmationDialog.new()
	host._remove_dialog.title = "Remove Paint Material"
	host._remove_dialog.dialog_text = "Remove this material and clear its face-local weights from every painted PNG surface?"
	host._remove_dialog.confirmed.connect(host._remove_current_material)
	host.add_child(host._remove_dialog)
	host._clear_dialog = ConfirmationDialog.new()
	host._clear_dialog.title = "Clear Brush Paint"
	host._clear_dialog.dialog_text = "Clear every authored brush stroke while preserving procedural material rules?"
	host._clear_dialog.confirmed.connect(host._clear_brush_paint)
	host.add_child(host._clear_dialog)
	host._resolution_dialog = ConfirmationDialog.new()
	host._resolution_dialog.title = "Rebuild Paint Mask Resolution"
	host._resolution_dialog.confirmed.connect(host._apply_resolution_rebuild)
	host.add_child(host._resolution_dialog)
