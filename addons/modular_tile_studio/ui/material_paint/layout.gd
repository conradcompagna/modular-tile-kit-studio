@tool
extends RefCounted

## Layout behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Build the compact workflow and its contextual editors once when the panel enters the tree.
static func _ready(host: MaterialPaintPanel) -> void:
	host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	host.add_child(scroll)
	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(form)

	var title_row := HBoxContainer.new()
	form.add_child(title_row)
	var title := Label.new()
	title.text = "Surface Materials"
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	host._more_menu = MenuButton.new()
	host._more_menu.text = "More…"
	host._more_menu.tooltip_text = "Open the less-frequent appearance, mask-stack, paint-system, removal, and clearing actions."
	var more_popup := host._more_menu.get_popup()
	more_popup.add_item("Material Appearance…", MaterialPaintPanel.MoreAction.MATERIAL_APPEARANCE)
	more_popup.add_item("Full Mask Stack…", MaterialPaintPanel.MoreAction.MASK_STACK)
	more_popup.add_item("Paint System…", MaterialPaintPanel.MoreAction.PAINT_SYSTEM)
	more_popup.add_separator()
	more_popup.add_item("Remove Current Material…", MaterialPaintPanel.MoreAction.REMOVE_MATERIAL)
	more_popup.add_item("Remove Procedural Level Pass…", MaterialPaintPanel.MoreAction.REMOVE_LEVEL_PASS)
	more_popup.add_item("Clear Brush Paint…", MaterialPaintPanel.MoreAction.CLEAR_BRUSH_PAINT)
	more_popup.set_item_tooltip(more_popup.get_item_index(MaterialPaintPanel.MoreAction.MATERIAL_APPEARANCE), "Change the selected material's texture scale and height-aware blending.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MaterialPaintPanel.MoreAction.MASK_STACK), "Build up to four ordered mask conditions for the selected brush material.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MaterialPaintPanel.MoreAction.PAINT_SYSTEM), "Choose the splat algorithm, debug preview, paint resolution, and stylus-pressure behavior.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MaterialPaintPanel.MoreAction.REMOVE_MATERIAL), "Remove the selected brush material and clear only its face-local weights; this is undoable.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MaterialPaintPanel.MoreAction.REMOVE_LEVEL_PASS), "Remove the level-wide pass for the selected PNG without removing local brush strokes; this is undoable.")
	more_popup.set_item_tooltip(more_popup.get_item_index(MaterialPaintPanel.MoreAction.CLEAR_BRUSH_PAINT), "Clear all local material strokes while preserving procedural level passes; this is undoable.")
	more_popup.id_pressed.connect(host._on_more_action_selected)
	title_row.add_child(host._more_menu)

	host._no_constraint_mode = CheckButton.new()
	host._no_constraint_mode.text = "No Constraint"
	host._no_constraint_mode.tooltip_text = (
		"Paint the selected PNG over the base coat through a face-local RGBA layer. "
		+ "Pen and Tile both use the regular PNG brush orientation controlled by the arrow keys."
	)
	host._no_constraint_mode.toggled.connect(host._on_no_constraint_mode_toggled)
	form.add_child(host._no_constraint_mode)

	host._mask_paint_mode = CheckButton.new()
	host._mask_paint_mode.text = "Mask-based terrain painting"
	host._mask_paint_mode.tooltip_text = (
		"Enable the selected PNG and mask to paint terrain with the chosen circular pen "
		+ "or tile brush. Turn this off to release viewport input for other paint tools."
	)
	host._mask_paint_mode.toggled.connect(host._on_mask_paint_mode_toggled)
	form.add_child(host._mask_paint_mode)

	host._mask_preview = CheckButton.new()
	host._mask_preview.text = "Preview mask reach"
	host._mask_preview.tooltip_text = MaterialPaintPanel.MASK_PREVIEW_TOOLTIP
	host._mask_preview.toggled.connect(host._on_mask_preview_toggled)
	form.add_child(host._mask_preview)

	host._splatmap_mode = CheckButton.new()
	host._splatmap_mode.text = "Splatmap terrain mode"
	host._splatmap_mode.tooltip_text = (
		"Give the ordinary square base-coat brush ownership of terrain painting. Each stamp "
		+ "writes all assigned R/G/B/A materials from the loaded terrain-wide control map."
	)
	host._splatmap_mode.toggled.connect(host._on_splatmap_mode_toggled)
	form.add_child(host._splatmap_mode)
	host._splatmap_projection = host._add_option(
		form,
		"Projection",
		MaterialPaintPanel.SPLATMAP_PROJECTION_NAMES,
		"Choose the one terrain face direction sampled by the uploaded map. Changing it rebuilds the guide and brush lookup without clearing paint already stamped in any direction."
	)
	host._splatmap_projection.item_selected.connect(host._on_splatmap_projection_selected)
	host._splatmap_overlay = CheckButton.new()
	host._splatmap_overlay.text = "Show splatmap overlay"
	host._splatmap_overlay.tooltip_text = (
		"Show or hide the loaded RGBA source as a terrain-wide guide. This display-only "
		+ "overlay never creates paint and does not control whether the tile brush works."
	)
	host._splatmap_overlay.toggled.connect(host._on_splatmap_overlay_toggled)
	form.add_child(host._splatmap_overlay)
	host._splatmap_live_controls_box = VBoxContainer.new()
	host._splatmap_fill_empty_regions = CheckButton.new()
	host._splatmap_fill_empty_regions.text = "Fill empty regions with a base channel"
	host._splatmap_fill_empty_regions.tooltip_text = (
		"Replace black and near-black source pixels with the selected R, G, B, or A "
		+ "material. Off preserves the source's native RGBA weights."
	)
	host._splatmap_fill_empty_regions.toggled.connect(host._on_splatmap_live_option_changed)
	host._splatmap_live_controls_box.add_child(host._splatmap_fill_empty_regions)
	var empty_region_row := HBoxContainer.new()
	var empty_region_label := Label.new()
	empty_region_label.text = "Empty-region base"
	empty_region_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	empty_region_row.add_child(empty_region_label)
	host._splatmap_empty_region_channel = OptionButton.new()
	host._splatmap_empty_region_channel.tooltip_text = (
		"Choose which assigned splat material completely fills every empty source pixel."
	)
	for channel_index: int in MaterialPaintPanel.SPLATMAP_CHANNEL_NAMES.size():
		host._splatmap_empty_region_channel.add_item(
			MaterialPaintPanel.SPLATMAP_CHANNEL_NAMES[channel_index],
			channel_index
		)
	host._splatmap_empty_region_channel.item_selected.connect(host._on_splatmap_live_option_changed)
	empty_region_row.add_child(host._splatmap_empty_region_channel)
	host._splatmap_live_controls_box.add_child(empty_region_row)
	host._splatmap_channel_strengths_enabled = CheckButton.new()
	host._splatmap_channel_strengths_enabled.text = "Adjust channel strengths"
	host._splatmap_channel_strengths_enabled.tooltip_text = (
		"Multiply the visible R/G/B/A blend dynamically. Off preserves native source weights."
	)
	host._splatmap_channel_strengths_enabled.toggled.connect(host._on_splatmap_live_option_changed)
	host._splatmap_live_controls_box.add_child(host._splatmap_channel_strengths_enabled)
	host._splatmap_channel_strength_sliders.clear()
	for channel_name: String in ["R strength", "G strength", "B strength", "A strength"]:
		var strength_slider := host._add_slider(
			host._splatmap_live_controls_box,
			channel_name,
			0.0,
			400.0,
			1.0,
			100.0,
			"%",
			false,
			"Scale this channel at draw time while preserving the painted pixel's total coverage."
		)
		strength_slider.editable = false
		strength_slider.value_changed.connect(host._on_splatmap_live_option_changed)
		host._splatmap_channel_strength_sliders.append(strength_slider)
	form.add_child(host._splatmap_live_controls_box)
	host._splatmap_setup_button = Button.new()
	host._splatmap_setup_button.text = "LOAD / ASSIGN RGBA SPLATMAP…"
	host._splatmap_setup_button.tooltip_text = (
		"Load one terrain-wide control image and assign PNG materials to its R/G/B/A channels. "
		+ "A fully empty outer image frame is fitted to the terrain footprint automatically; "
		+ "the dialog otherwise only loads canonical inputs, and painting remains explicit."
	)
	host._splatmap_setup_button.pressed.connect(host._open_splatmap_import)
	form.add_child(host._splatmap_setup_button)
	host._splatmap_workflow_box = VBoxContainer.new()
	var splatmap_channels_label := Label.new()
	splatmap_channels_label.text = "Active RGBA material channel"
	splatmap_channels_label.tooltip_text = (
		"Inspect the four assigned materials. Every tile-brush stamp writes all channels together."
	)
	host._splatmap_workflow_box.add_child(splatmap_channels_label)
	host._splatmap_channel_gallery = ItemList.new()
	host._splatmap_channel_gallery.custom_minimum_size = Vector2(0.0, 116.0)
	host._splatmap_channel_gallery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._splatmap_channel_gallery.max_columns = 4
	host._splatmap_channel_gallery.icon_mode = ItemList.ICON_MODE_TOP
	host._splatmap_channel_gallery.fixed_icon_size = MaterialPaintPanel.MATERIAL_THUMBNAIL_SIZE
	host._splatmap_channel_gallery.fixed_column_width = 104
	host._splatmap_channel_gallery.same_column_width = true
	host._splatmap_channel_gallery.allow_reselect = true
	host._splatmap_channel_gallery.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	host._splatmap_channel_gallery.tooltip_text = (
		"These are the R/G/B/A materials painted together by the base-coat tile brush. "
		+ "Selecting a thumbnail only chooses which layer's procedural-mask controls are shown."
	)
	host._splatmap_channel_gallery.item_selected.connect(host._on_splatmap_channel_selected)
	host._splatmap_workflow_box.add_child(host._splatmap_channel_gallery)
	form.add_child(host._splatmap_workflow_box)

	host._add_separator(form)
	host._material_gallery_label = Label.new()
	host._material_gallery_label.text = "1  Paint PNG"
	host._material_gallery_label.tooltip_text = "Choose the PNG material visually. Selection alone never changes the map."
	form.add_child(host._material_gallery_label)
	host._material_gallery = ItemList.new()
	host._material_gallery.custom_minimum_size = Vector2(0.0, 116.0)
	host._material_gallery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._material_gallery.max_columns = 0
	host._material_gallery.icon_mode = ItemList.ICON_MODE_TOP
	host._material_gallery.fixed_icon_size = MaterialPaintPanel.MATERIAL_THUMBNAIL_SIZE
	host._material_gallery.fixed_column_width = 104
	host._material_gallery.same_column_width = true
	host._material_gallery.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	host._material_gallery.tooltip_text = "Select a PNG thumbnail. It paints only after you enable No Constraint, choose a mask, or arm a decal mode."
	host._material_gallery.item_selected.connect(host._on_material_selected)
	form.add_child(host._material_gallery)

	host._decal_mode = CheckButton.new()
	host._decal_mode.text = "Stamp as native decal"
	host._decal_mode.tooltip_text = (
		"Place the selected PNG as a Godot Decal with its albedo, normal, packed "
		+ "ORM, and emission maps. Native Decal has no height/parallax input."
	)
	host._decal_mode.toggled.connect(host._on_decal_mode_toggled)
	form.add_child(host._decal_mode)

	host._shader_decal_mode = CheckButton.new()
	host._shader_decal_mode.text = "Stamp into terrain material"
	host._shader_decal_mode.tooltip_text = (
		"Stamp the selected PNG and its original PBR maps once at the asset footprint. "
		+ "Opaque pixels replace the underlying coat, transparent pixels leave it visible, "
		+ "and the same terrain shader supplies lighting, parallax, fog, and grid rendering."
	)
	host._shader_decal_mode.toggled.connect(host._on_shader_decal_mode_toggled)
	form.add_child(host._shader_decal_mode)

	host._decal_edge_mode = CheckButton.new()
	host._decal_edge_mode.text = "Edge placement"
	host._decal_edge_mode.tooltip_text = (
		"Snap the decal centre to the nearest grid junction shared by four cells. "
		+ "The junction is saved without changing the decal's authored size."
	)
	host._decal_edge_mode.toggled.connect(host._on_decal_edge_mode_toggled)
	form.add_child(host._decal_edge_mode)

	host._match_underlying_palette = CheckButton.new()
	host._match_underlying_palette.text = "Match underlying albedo palette"
	host._match_underlying_palette.tooltip_text = (
		"Analyze the authored albedo beneath the decal footprint and remap the decal's "
		+ "opaque pixels to comparable colour mean and contrast. Alpha and all non-albedo "
		+ "material maps are preserved. The choice is saved on each placement."
	)
	host._match_underlying_palette.toggled.connect(host._on_palette_match_toggled)
	form.add_child(host._match_underlying_palette)

	host._mask_row = host._row(
		form,
		"2  Mask",
		"Restrict local brush strokes and the optional procedural pass by material data, level height, slope, contact, or noise."
	)
	host._mask = OptionButton.new()
	host._mask.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._mask.tooltip_text = "Choose where this material is allowed to appear; choosing a mask arms the brush."
	host._mask.item_selected.connect(host._on_mask_selected)
	host._mask_row.add_child(host._mask)

	host._range_low = host._add_slider(form, "Range low", 0.0, 100.0, 1.0, 0.0, "%", false, "Set the lowest mask value accepted by this material.")
	host._range_low_row = host._range_low.get_parent() as HBoxContainer
	host._range_low.value_changed.connect(host._on_range_low_changed)
	host._range_high = host._add_slider(form, "Range high", 0.0, 100.0, 1.0, 100.0, "%", false, "Set the highest mask value accepted by this material.")
	host._range_high_row = host._range_high.get_parent() as HBoxContainer
	host._range_high.value_changed.connect(host._on_range_high_changed)
	host._fade = host._add_slider(form, "Edge fade", 0.0, 100.0, 1.0, 10.0, "%", false, "Soften the mask boundary to fade naturally into the material underneath.")
	host._fade_row = host._fade.get_parent() as HBoxContainer
	host._fade.value_changed.connect(host._on_simple_mask_value_changed)
	host._influence = host._add_slider(form, "Influence", 0.0, 100.0, 1.0, 100.0, "%", false, "Scale the mask's final contribution without changing its selected range.")
	host._influence_row = host._influence.get_parent() as HBoxContainer
	host._influence.value_changed.connect(host._on_simple_mask_value_changed)
	host._invert = CheckButton.new()
	host._invert.text = "Invert mask"
	host._invert.tooltip_text = "Swap the mask's accepted and rejected regions after range and fade are evaluated."
	host._invert.toggled.connect(host._on_simple_mask_value_changed)
	form.add_child(host._invert)
	host._noise_scale = host._add_slider(form, "Noise scale", 0.01, 1000.0, 0.01, 2.0, " m", true, "Set the world-space size of noise features; larger values make broader patches.")
	host._noise_scale_row = host._noise_scale.get_parent() as HBoxContainer
	host._noise_scale.value_changed.connect(host._on_simple_mask_value_changed)
	host._noise_seed = host._add_spin(form, "Noise seed", -100000.0, 100000.0, 1.0, 0.0, "Choose a deterministic alternate noise pattern without changing its scale.")
	host._noise_seed_row = host._noise_seed.get_parent() as HBoxContainer
	host._noise_seed.value_changed.connect(host._on_simple_mask_value_changed)
	host._noise_angle = host._add_spin(form, "Band angle", 0.0, 360.0, 1.0, 0.0, "Set the world-space direction of directional bands explicitly.")
	host._noise_angle.suffix = "°"
	host._noise_angle_row = host._noise_angle.get_parent() as HBoxContainer
	host._noise_angle.value_changed.connect(host._on_simple_mask_value_changed)

	host._brush_box = VBoxContainer.new()
	form.add_child(host._brush_box)
	host._paint_target = host._add_option(
		host._brush_box,
		"Paint target",
		MaterialPaintPanel.PAINT_TARGET_NAMES,
		"Choose a continuous metric pen or the regular textured square Tile targeter. Both work on top and side faces and use the same arrow-key PNG orientation."
	)
	host._paint_target.item_selected.connect(host._on_paint_target_selected)
	host._brush_radius = host._add_spin(host._brush_box, "Pen radius", 0.01, 100.0, 0.01, 0.5, "Set the circular pen radius in world-space metres on either top or side faces.")
	host._brush_radius_row = host._brush_radius.get_parent() as HBoxContainer
	host._brush_radius.suffix = " m"
	host._brush_radius.value_changed.connect(host._on_brush_radius_changed)
	host._brush_opacity = host._add_slider(host._brush_box, "Brush strength", 0.0, 100.0, 1.0, 100.0, "%", false, "Set how much selected-channel weight one circular or tile stroke adds or removes; lower values build up gradually.")
	host._brush_opacity.value_changed.connect(host._on_brush_opacity_changed)
	host._hardness = host._add_slider(host._brush_box, "Brush edge", 0.0, 100.0, 1.0, 75.0, "%", false, "Control circular-pen falloff: 100% is a hard edge and lower values create a softer feather.")
	host._hardness_row = host._hardness.get_parent() as HBoxContainer
	host._hardness.value_changed.connect(host._on_brush_hardness_changed)

	host._status = Label.new()
	host._status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	host._status.tooltip_text = "Shows the next required action and whether a level-wide pass already exists for the selected PNG."
	form.add_child(host._status)

	host._add_separator(form)
	host._procedural_button = Button.new()
	host._procedural_button.text = "PROCEDURALLY PAINT LEVEL"
	host._procedural_button.tooltip_text = "Apply the currently visible PNG and mask across every matching PNG surface as one explicit undoable action. Local brush strokes are preserved."
	host._procedural_button.pressed.connect(host._apply_procedural_level)
	form.add_child(host._procedural_button)

	host._build_material_dialog()
	host._build_mask_dialog()
	host._build_splatmap_dialog()
	host._build_settings_dialog()
	host._build_confirmation_dialogs()
	host._populate_materials()
	host._refresh_main_controls()
