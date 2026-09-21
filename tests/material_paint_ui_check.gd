@tool
extends Node

var _failed: int = 0


## Defer the editor-only UI and undo probe until the root viewport is initialized.
func _ready() -> void:
	_run.call_deferred()


## Exercise the compact three-step workflows against the editor's real global undo manager.
func _run() -> void:
	if not Engine.is_editor_hint():
		push_error("Run this test through tools/run_godot_checks.py --suite editor.")
		get_tree().quit(1)
		return
	var library := AssetLibrary.new()
	var overlay := _surface_asset("OVERLAY")
	var older := _surface_asset("OLDER")
	var newest := _surface_asset("NEWEST")
	var alpha := _surface_asset("ALPHA")
	overlay.processing["imported_at"] = "2026-08-24T12:00:00"
	older.processing["imported_at"] = "2026-08-23T12:00:00"
	newest.processing["imported_at"] = "2026-08-25T12:00:00"
	alpha.processing["imported_at"] = "2026-08-22T12:00:00"
	for splat_asset: TileAsset in [overlay, older, newest, alpha]:
		for channel: String in ["normal", "roughness", "metallic", "height", "emission"]:
			splat_asset.gbuffer.set_channel(channel, "res://icon.svg")
	library.add_asset(older)
	library.add_asset(overlay)
	library.add_asset(newest)
	library.add_asset(alpha)
	var board := BoardDocument.new()
	board.bind_library(library)
	board.terrain = _filled_terrain(Vector2i(4, 4))
	var viewport := MTSStudioViewport.new()
	viewport.size = Vector2(800, 600)
	get_tree().root.add_child(viewport)
	await get_tree().process_frame
	var undo_manager := EditorInterface.get_editor_undo_redo()
	viewport.bind(board, library, SurfaceMaterialFactory.new(), undo_manager)
	var panel := MaterialPaintPanel.new()
	get_tree().root.add_child(panel)
	await get_tree().process_frame
	panel.bind(board, library, viewport)

	var toolbar_owner := TileStudioMain.new()
	toolbar_owner.viewport = viewport
	var toolbar := toolbar_owner._build_toolbar() as HBoxContainer
	get_tree().root.add_child(toolbar)
	await get_tree().process_frame
	var fill_index := toolbar_owner._fill_button.get_index()
	var path_index := toolbar_owner._fill_shape_option.get_index()
	var grid_stroke_index := toolbar_owner._surface_grid_stroke_size_spin.get_index()
	var grid_stroke_label := toolbar.get_child(path_index + 1) as Label
	_check(
		path_index == fill_index + 1
		and grid_stroke_index == path_index + 2
		and grid_stroke_label != null
		and grid_stroke_label.text == "Brush width",
		"the direct-texture Brush width sits immediately beside Fill and Path in the top bar"
	)
	var original_pen_radius: float = viewport.material_brush_radius_m
	toolbar_owner._surface_grid_stroke_size_spin.value = 3.0
	_check(
		viewport.surface_grid_stroke_size_m == 3
		and is_equal_approx(viewport.material_brush_radius_m, original_pen_radius),
		"the top-bar Grid stroke controls whole tile metres without changing the Materials pen"
	)
	_check(
		not toolbar_owner._surface_grid_stroke_size_spin.tooltip_text.is_empty(),
		"the top-bar Grid stroke explains that it does not resize the texture"
	)

	_check(
		panel.find_children("*", "TabBar", true, false).is_empty(),
		"local and procedural painting share one visible setup instead of separate menus"
	)
	_check(
		panel._material_gallery.icon_mode == ItemList.ICON_MODE_TOP,
		"the PNG chooser is a directly visible thumbnail gallery"
	)
	_check(
		panel._material_asset_ids[0] == newest.asset_id,
		"the regular material thumbnail gallery lists the newest imported asset first"
	)
	_check(
		panel._more_menu.get_popup().item_count == 7,
		"the overflow menu retains only secondary actions because splatmaps are top-level"
	)
	_check(
		panel._rule_source.item_count == 20 and panel._rule_combine.item_count == 5,
		"the focused mask stack exposes four noise kernels and every combine algorithm"
	)
	_check(
		panel._blend_mode.item_count == 2 and panel._debug_view.item_count == 8,
		"the focused system dialog retains splat algorithms and diagnostic previews"
	)
	_check(
		panel._splatmap_slots.size() == 4
		and panel._splatmap_slot_previews.size() == 4
		and panel._noise_angle != null
		and panel._rule_noise_angle != null,
		"RGBA thumbnail mapping and explicit directional-noise angles are directly controllable"
	)
	_check(
		panel._splatmap_mode != null
		and panel._splatmap_setup_button != null
		and panel._splatmap_channel_gallery.icon_mode == ItemList.ICON_MODE_TOP,
		"splatmap mode, setup, and the four painted channels are first-class Materials controls"
	)
	panel._open_splatmap_import()
	await get_tree().process_frame
	var splat_ok_button := panel._splatmap_dialog.get_ok_button()
	_check(
		panel._splatmap_dialog.visible
		and splat_ok_button.is_visible_in_tree()
		and splat_ok_button.position.y + splat_ok_button.size.y
		<= panel._splatmap_dialog.size.y,
		"the scrollable RGBA setup keeps its confirmation button inside the visible dialog"
	)
	panel._open_splatmap_slot_picker(0)
	await get_tree().process_frame
	_check(
		panel._splatmap_picker_gallery.icon_mode == ItemList.ICON_MODE_TOP
		and panel._splatmap_picker_asset_ids[1] == newest.asset_id
		and panel._splatmap_picker_gallery.get_item_icon(1) != null,
		"RGBA material assignment is a newest-first thumbnail gallery"
	)
	panel._splatmap_picker_popup.hide()
	panel._splatmap_dialog.hide()
	_check(
		panel._auto_texture_thin_side_slivers != null
		and not panel._auto_texture_thin_side_slivers.button_pressed
		and not board.material_blend.auto_texture_thin_side_slivers,
		"Paint System exposes thin side-strip seeding as an opt-in disabled control"
	)
	panel._auto_texture_thin_side_slivers.set_pressed_no_signal(true)
	panel._on_auto_texture_thin_side_slivers_toggled(true)
	_check(
		board.material_blend.auto_texture_thin_side_slivers
		and bool(board.material_blend.to_json().get("auto_texture_thin_side_slivers", false)),
		"enabling thin side-strip seeding stores the same visible setting the renderer consumes"
	)
	var visible_labels: PackedStringArray = []
	for value: Node in panel.find_children("*", "Label", true, false):
		visible_labels.append((value as Label).text)
	_check(
		not "Layer opacity %" in visible_labels,
		"redundant layer opacity is deleted instead of hidden in another dialog"
	)
	_check(
		"Pen radius" in visible_labels
		and not "Brush size" in visible_labels
		and not "Brush radius" in visible_labels,
		"the Materials panel owns the clearly named circular pen radius"
	)
	panel._brush_radius.value = 0.13
	_check(
		is_equal_approx(viewport.material_brush_radius_m, 0.13)
		and viewport.surface_grid_stroke_size_m == 3,
		"the Materials pen radius changes independently of the top-bar grid stroke"
	)
	var overlay_item := panel._material_asset_ids.find(overlay.asset_id)
	_check(overlay_item >= 0, "the visual PNG chooser contains direct surface assets")
	_check(
		panel._material_gallery.get_item_icon(overlay_item) != null,
		"each available PNG exposes its thumbnail rather than only a filename"
	)
	var before_selection := board.material_blend.to_json().duplicate(true)
	panel._material_gallery.select(overlay_item)
	panel._on_material_selected(overlay_item)
	_check(
		board.material_blend.to_json() == before_selection,
		"choosing a PNG thumbnail does not texture or otherwise mutate the map"
	)
	_check(
		panel._selected_layers[MaterialPaintPanel.Workflow.PAINT] < 0,
		"PNG selection waits for an explicit mask before allocating a palette entry"
	)
	_check(not panel._mask.disabled, "all mask choices become available after the PNG is selected")
	_check(
		panel._mask.get_item_index(MaterialPaintPanel.MaskPreset.NONE) < 0,
		"No Constraint is removed from the mask preset list"
	)
	_check(
		panel._no_constraint_mode.visible and not panel._no_constraint_mode.disabled,
		"No Constraint is exposed as its own top-level material paint mode"
	)
	var height_mask_item := panel._mask.get_item_index(
		MaterialPaintPanel.MaskPreset.BASE_HEIGHT_LOW
	)
	panel._mask.select(height_mask_item)
	panel._on_mask_selected(height_mask_item)
	var paint_layer := panel._selected_layers[MaterialPaintPanel.Workflow.PAINT]
	_check(paint_layer >= 0, "choosing the mask automatically assigns the palette entry")
	_check(
		int(panel._draft.layer(paint_layer).get("application_mode", -1))
		== MaterialBlendProfile.ApplicationMode.BRUSH,
		"the local layer remains explicitly classified as brush-authored state"
	)
	_check(
		panel._draft.layer_masks(paint_layer).size() == 2
		and int(panel._draft.layer_masks(paint_layer)[0].get("source", -1))
		== MaterialBlendProfile.MaskSource.PAINT,
		"local painting keeps its structural painted-channel gate before the visible mask"
	)
	_check(
		panel._range_low_row.visible
		and panel._range_high_row.visible
		and panel._fade_row.visible
		and panel._influence_row.visible
		and panel._invert.visible,
		"the main mask exposes range, fade, influence, and inversion controls"
	)
	_check(
		is_equal_approx(panel._range_low.value, 0.0)
		and is_equal_approx(panel._range_high.value, 20.0),
		"a low-height mask starts with a useful but fully editable bottom twenty percent"
	)
	_check(
		viewport.material_paint_tool == MTSStudioViewport.MaterialPaintTool.PAINT,
		"the actual viewport brush arms after PNG and mask are both explicit"
	)
	var circular_target_item := panel._paint_target.get_item_index(
		MaterialPaintPanel.PaintTarget.CIRCULAR_PEN
	)
	var tile_target_item := panel._paint_target.get_item_index(
		MaterialPaintPanel.PaintTarget.TILE_BRUSH
	)
	_check(
		panel._paint_target.item_count == 2
		and panel._paint_target.selected == circular_target_item
		and panel._brush_radius_row.visible
		and panel._hardness_row.visible,
		"local mask painting visibly defaults to the existing circular pen"
	)
	panel._paint_target.select(tile_target_item)
	panel._on_paint_target_selected(tile_target_item)
	_check(
		panel.uses_tile_brush()
		and viewport.material_tile_paint_enabled
		and viewport.placement.terrain_splat_paint_enabled
		and viewport.material_paint_tool == MTSStudioViewport.MaterialPaintTool.NONE
		and not panel._brush_radius_row.visible
		and not panel._hardness_row.visible,
		"Tile brush delegates the same selected mask layer to the base-coat tile targeter"
	)
	toolbar_owner._set_exclusive_authoring_toolbar_state(true, true)
	_check(
		not toolbar_owner._fill_button.disabled
		and not toolbar_owner._erase_button.disabled
		and not toolbar_owner._replace_button.disabled,
		"masked Tile brush keeps Paint, Replace, Erase, Path, and Polygon controls available"
	)
	panel._paint_target.select(circular_target_item)
	panel._on_paint_target_selected(circular_target_item)
	_check(
		not viewport.material_tile_paint_enabled
		and viewport.material_paint_tool == MTSStudioViewport.MaterialPaintTool.PAINT
		and panel._brush_radius_row.visible
		and panel._hardness_row.visible,
		"switching back restores the original circular pen without changing its settings"
	)
	panel._material_scale.value = 175.0
	_check(
		is_equal_approx(viewport.material_brush_radius_m, 0.13)
		and is_equal_approx(
			float(panel._draft.layer(paint_layer).get("texture_scale_percent", 0.0)),
			175.0
		),
		"texture repeat size changes independently of the top-bar brush radius"
	)
	# A brush layer receives shader uniforms only once a face actually uses it;
	# unpainted faces deliberately compile the cheaper zero-layer variant.
	_check(
		not viewport.surface_material_paint.has_any_paint(),
		"arming the brush creates no paint pixels and does not color the map"
	)
	var preview_uid := TerrainMesh.cell_top_uid(Vector2i.ZERO)
	viewport.surface_material_paint.begin_stroke()
	viewport.surface_material_paint.stamp_material_tile(preview_uid, paint_layer, 0.5, 0, false)
	viewport.surface_material_paint.finish_stroke()
	viewport.surface_material_paint.upload_dirty()
	viewport._flush_material_palette_slot_changes()
	viewport.refresh_material_blend_materials()
	var live_batch := _top_terrain_batch(viewport)
	_check(live_batch != null, "the material panel updates a canonical terrain batch")
	if live_batch == null:
		get_tree().quit(1)
		return
	var live_material_before := live_batch.material_override as ShaderMaterial
	var live_repeat: Vector2 = live_material_before.get_shader_parameter(
		"material_layer_0_repeat_m"
	)
	_check(
		is_equal_approx(live_repeat.x, 7.0)
		and is_equal_approx(live_repeat.y, 7.0)
		and is_equal_approx(viewport.material_brush_radius_m, 0.13),
		"the 4 x 4 metre texture repeats at 175 percent while the brush stays 0.13 metres"
	)
	panel._range_high.value = 45.0
	var live_mask_highs: Vector4 = live_material_before.get_shader_parameter(
		"material_layer_0_mask_highs"
	)
	_check(
		live_batch.material_override == live_material_before
		and is_equal_approx(live_mask_highs.y, 0.45),
		"mask sliders update only existing layer uniforms without recreating batch materials"
	)
	_check(
		not panel._mask_preview.disabled,
		"the mask-reach preview is an available top-level paint control"
	)
	var profile_before_preview := board.material_blend.to_json().duplicate(true)
	var preview_mesh_before := live_batch.multimesh.mesh
	panel._mask_preview.set_pressed_no_signal(true)
	panel._on_mask_preview_toggled(true)
	_check(
		viewport.material_mask_preview_enabled
		and viewport.material_mask_preview_palette_index == paint_layer
		and live_batch.multimesh.mesh == preview_mesh_before,
		"the visible checkbox overlays neon eligibility without changing surface geometry"
	)
	_check(
		board.material_blend.to_json() == profile_before_preview,
		"mask preview changes no authored profile or board data"
	)
	panel._mask_preview.set_pressed_no_signal(false)
	panel._on_mask_preview_toggled(false)
	_check(
		not viewport.material_mask_preview_enabled
		and live_batch.multimesh.mesh == preview_mesh_before,
		"disabling preview leaves the same full-detail surface mesh in place"
	)
	viewport.clear_surface_material_paint()
	viewport._draw_material_brush_preview({
		"world_position": Vector3.ZERO,
		"normal_world": Vector3.UP,
		"tangent_world": Vector3.RIGHT,
		"binormal_world": Vector3.FORWARD,
	})
	_check(
		viewport._material_brush_preview.visible
		and (viewport._material_brush_preview.mesh as ImmediateMesh).get_surface_count() == 1,
		"the viewport owns a visible world-space brush ring"
	)
	_check(_main_tooltips_are_complete(panel), "all primary paint controls and choices expose hover help")

	panel._paint_detail.value = 8.0
	panel._maximum_edge.value = 32.0
	_check(
		board.material_blend.paint_texels_per_metre == 64
		and board.material_blend.maximum_surface_edge_px == 512
		and not panel._apply_resolution_button.disabled,
		"resolution knobs remain pending until the explicit memory rebuild"
	)
	_check(
		panel._paint_memory_summary.text.contains("No brush masks are allocated"),
		"advanced settings show the requested canonical allocation consequence"
	)
	panel._apply_resolution_rebuild()
	_check(
		board.material_blend.paint_texels_per_metre == 8
		and board.material_blend.maximum_surface_edge_px == 32
		and panel._apply_resolution_button.disabled,
		"advanced texel-density and edge-cap controls update the canonical profile"
	)


	panel._apply_procedural_level()
	var procedural_layer := panel._selected_layers[MaterialPaintPanel.Workflow.PROCEDURAL]
	_check(procedural_layer >= 0, "the bottom button explicitly creates the level-wide pass")
	_check(
		int(panel._draft.layer(procedural_layer).get("application_mode", -1))
		== MaterialBlendProfile.ApplicationMode.PROCEDURAL,
		"the level pass remains explicit inspectable state instead of a mask heuristic"
	)
	_check(
		int(panel._draft.layer_masks(procedural_layer)[0].get("source", -1))
		== MaterialBlendProfile.MaskSource.BASE_HEIGHT,
		"the level pass reuses the visible mask without the local brush gate"
	)
	_check(
		panel._procedural_button.text == "UPDATE PROCEDURAL LEVEL PASS",
		"the one bottom action makes an existing level pass inspectable and updateable"
	)

	var history := undo_manager.get_history_undo_redo(0)
	_check(history != null and history.has_undo(), "procedural material changes enter global undo history")
	if history != null and history.has_undo():
		history.undo()
		_check(
			String(board.material_blend.layer(procedural_layer).get("asset_id", "")).is_empty(),
			"undo removes the already-applied procedural pass"
		)
		_check(
			panel._selected_layers[MaterialPaintPanel.Workflow.PROCEDURAL] < 0,
			"undo resynchronizes the compact UI with canonical board state"
		)
		history.redo()
		_check(
			String(board.material_blend.layer(procedural_layer).get("asset_id", "")) == overlay.asset_id,
			"redo restores the procedural pass"
		)

	panel._no_constraint_mode.set_pressed_no_signal(true)
	panel._on_no_constraint_mode_toggled(true)
	_check(
		panel._draft.layer_masks(paint_layer).size() == 1
		and int(panel._draft.layer_masks(paint_layer)[0].get("source", -1))
		== MaterialBlendProfile.MaskSource.PAINT
		and viewport.material_layer_brush_asset == overlay,
		"the top-level No Constraint mode stores only the painted gate and arms the selected PNG"
	)
	panel._apply_procedural_level()
	_check(
		panel._draft.layer_masks(procedural_layer).is_empty(),
		"No Constraint produces an unconstrained full-level pass from the same PNG recipe"
	)

	# Paint is addressed by canonical terrain face identity, not placement identity.
	var painted_uid := TerrainMesh.cell_top_uid(Vector2i(0, 0))
	viewport.surface_material_paint.begin_stroke()
	viewport.surface_material_paint.brush_segment(
		painted_uid,
		Vector2i.ONE,
		Vector2(0.5, 0.5),
		Vector2(0.5, 0.5),
		0.4,
		1.0,
		1.0,
		paint_layer,
		0,
		false
	)
	viewport.surface_material_paint.finish_stroke()
	panel._pending_remove_layer = paint_layer
	panel._remove_current_material()
	_check(
		String(board.material_blend.layer(paint_layer).get("asset_id", "")).is_empty()
		and not viewport.surface_material_paint.has_image(painted_uid),
		"material removal clears only the assigned palette material weights"
	)
	history.undo()
	_check(
		String(board.material_blend.layer(paint_layer).get("asset_id", "")) == overlay.asset_id
		and viewport.surface_material_paint.has_image(painted_uid),
		"material removal undo restores both its recipe and sparse paint pixels"
	)
	history.redo()
	_check(
		String(board.material_blend.layer(paint_layer).get("asset_id", "")).is_empty()
		and not viewport.surface_material_paint.has_image(painted_uid),
		"material removal redo clears the same palette material without touching the map"
	)

	var splat_source := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	splat_source.fill(Color(0.2, 0.3, 0.4, 0.1))
	var splat_path := "user://material_paint_ui_splat.png"
	_check(splat_source.save_png(splat_path) == OK, "the visible RGBA source exists for repeatable tile strokes")
	var splat_result := viewport.import_terrain_splatmap(
		splat_source,
		PackedStringArray([
			overlay.asset_id,
			older.asset_id,
			newest.asset_id,
			alpha.asset_id,
		]),
		splat_path
	)
	var top_uid := TerrainMesh.cell_top_uid(Vector2i.ZERO)
	var top_image := viewport.surface_material_paint.image_for_uid(top_uid)
	var top_weight := (
		top_image.get_pixel(top_image.get_width() / 2, top_image.get_height() / 2)
		if top_image != null
		else Color.BLACK
	)
	panel._on_material_profile_replayed(board.material_blend.to_json())
	_check(
		int(splat_result.get("error", FAILED)) == OK
		and int(splat_result.get("face_count", 0)) == 16
		and String(board.material_blend.layer(0).get("asset_id", "")) == overlay.asset_id
		and board.material_blend.splatmap_palette_indices[0] == 0
		and board.material_blend.blend_mode == MaterialBlendProfile.BlendMode.NORMALIZED_SPLAT
		and board.material_blend.debug_view == MaterialBlendProfile.DebugView.FINAL_MATERIAL
		and panel._splatmap_mode.button_pressed
		and panel._splatmap_workflow_box.visible
		and not panel._material_gallery.visible
		and panel._splatmap_channel_gallery.get_item_icon(0) != null
		and viewport.splatmap_tile_paint_enabled
		and viewport.placement.terrain_splat_paint_enabled
		and viewport.material_paint_tool == MTSStudioViewport.MaterialPaintTool.NONE
		and not panel._brush_box.visible
		and top_image == null
		and top_weight.is_equal_approx(Color.BLACK)
		and board.material_blend.splatmap_source_path == splat_path,
		"RGBA import configures four explicit palette assignments without repainting terrain"
	)
	toolbar_owner._set_exclusive_authoring_toolbar_state(true, true)
	_check(
		not toolbar_owner._fill_button.disabled
		and not toolbar_owner._erase_button.disabled
		and not toolbar_owner._replace_button.disabled,
		"splatmap mode retains the base-coat Fill, Erase, and Replace controls"
	)
	var splat_material := (_top_terrain_batch(viewport).material_override as ShaderMaterial)
	_check(
		splat_material != null,
		"splatmap setup keeps terrain on the canonical material path before painting"
	)
	history.undo()
	panel._on_material_profile_replayed(board.material_blend.to_json())
	_check(
		String(board.material_blend.layer(0).get("asset_id", "")).is_empty()
		and not viewport.surface_material_paint.has_image(top_uid)
		and board.material_blend.debug_view == MaterialBlendProfile.DebugView.FINAL_MATERIAL
		and not panel._splatmap_mode.button_pressed,
		"RGBA import undo restores the previous palette and visible mode without touching paint"
	)
	history.redo()
	panel._on_material_profile_replayed(board.material_blend.to_json())
	_check(
		String(board.material_blend.layer(0).get("asset_id", "")) == overlay.asset_id
		and not viewport.surface_material_paint.has_image(top_uid)
		and board.material_blend.debug_view == MaterialBlendProfile.DebugView.FINAL_MATERIAL
		and panel._splatmap_mode.button_pressed
		and viewport.splatmap_tile_paint_enabled,
		"RGBA import redo restores explicit assignments and tile-brush mode without painting"
	)

	# Clear one imported cell, then route a real Replace stroke through the
	# base-coat target handler so the assertion covers all four weights at once.
	viewport.surface_material_paint.begin_stroke()
	viewport.surface_material_paint.stamp_splatmap_tile(
		top_uid,
		null,
		PackedInt32Array([0, 1, 2, 3]),
		true
	)
	viewport.surface_material_paint.finish_stroke()
	viewport.placement.set_replace_enabled(true)
	viewport._on_terrain_material_tile_paint_requested(
		PackedStringArray([top_uid]),
		false,
		true,
		true
	)
	await get_tree().process_frame
	var stamped_image := viewport.surface_material_paint.image_for_uid(top_uid)
	var stamped_weight := stamped_image.get_pixel(
		stamped_image.get_width() / 2,
		stamped_image.get_height() / 2
	)
	_check(
		stamped_weight.r > 0.18
		and stamped_weight.g > 0.28
		and stamped_weight.b > 0.38
		and stamped_weight.a > 0.08,
		"one normal tile-brush Replace stroke paints all four splat textures together"
	)
	var painted_splat_material := (_top_terrain_batch(viewport).material_override as ShaderMaterial)
	var painted_channels_bound := painted_splat_material != null
	if painted_splat_material != null:
		for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
			painted_channels_bound = (
				painted_channels_bound
				and bool(painted_splat_material.get_shader_parameter(
					"material_layer_%d_has_normal" % slot_index
				))
				and bool(painted_splat_material.get_shader_parameter(
					"material_layer_%d_has_height" % slot_index
				))
				and bool(painted_splat_material.get_shader_parameter(
					"material_layer_%d_has_emission" % slot_index
				))
				and painted_splat_material.get_shader_parameter(
					"material_layer_%d_orm_tex" % slot_index
				) is Texture2D
			)
	_check(
		painted_channels_bound,
		"a painted RGBA face binds all four assigned materials through its local slots"
	)

	overlay.stochastic_tiling = true
	overlay.random_texture_rotation = true
	overlay.random_texture_mirroring = true
	var asset_inspector := AssetInspectorPanel.new()
	get_tree().root.add_child(asset_inspector)
	await get_tree().process_frame
	# This is the same explicit edit pipeline connected by plugin.gd: invalidate
	# the asset material cache, then refresh every base and painted use.
	asset_inspector.asset_edited.connect(func(edited_asset: TileAsset, geometry_changed: bool) -> void:
		viewport.material_factory.invalidate(edited_asset.asset_id)
		viewport.refresh_asset_instances(edited_asset.asset_id, geometry_changed)
	)
	asset_inspector.set_asset(overlay)
	var variation_controls: Dictionary[String, bool] = {}
	for value: Node in asset_inspector.find_children("*", "CheckBox", true, false):
		var checkbox := value as CheckBox
		variation_controls[checkbox.text] = checkbox.button_pressed
	_check(
		variation_controls.get("Stochastic tiling", false)
		and variation_controls.get("Random 90° texture rotation", false)
		and variation_controls.get("Random texture mirroring", false),
		"the asset inspector exposes all three independent texture-variation switches"
	)
	var weight_before_asset_edit := viewport.surface_material_paint.image_for_uid(top_uid).get_pixel(0, 0)
	var roughness_slider: HSlider = null
	var rotation_checkbox: CheckBox = null
	for value: Node in asset_inspector.find_children("*", "HSlider", true, false):
		var slider := value as HSlider
		if slider.tooltip_text.begins_with("Roughness "):
			roughness_slider = slider
			break
	for value: Node in asset_inspector.find_children("*", "CheckBox", true, false):
		var checkbox := value as CheckBox
		if checkbox.text == "Random 90° texture rotation":
			rotation_checkbox = checkbox
			break
	_check(
		roughness_slider != null and rotation_checkbox != null,
		"the assigned RGBA asset keeps visible PBR and tiling controls"
	)
	if roughness_slider != null and rotation_checkbox != null:
		roughness_slider.value = 0.42
		rotation_checkbox.button_pressed = false
		var refreshed_splat_material := (
			_top_terrain_batch(viewport).material_override as ShaderMaterial
		)
		var weight_after_asset_edit := viewport.surface_material_paint.image_for_uid(top_uid).get_pixel(0, 0)
		var refreshed_roughness := float(refreshed_splat_material.get_shader_parameter(
			"material_layer_0_roughness_strength"
		))
		var refreshed_rotation := bool(refreshed_splat_material.get_shader_parameter(
			"material_layer_0_random_texture_rotation"
		))
		_check(
			is_equal_approx(refreshed_roughness, roughness_slider.value)
			and not refreshed_rotation
			and weight_after_asset_edit.is_equal_approx(weight_before_asset_edit),
			(
				"Asset Inspector PBR and tiling edits update painted splat materials without "
				+ "repainting weights (roughness=%.3f rotation=%s before=%s after=%s)"
			) % [
				refreshed_roughness,
				str(refreshed_rotation),
				str(weight_before_asset_edit),
				str(weight_after_asset_edit),
			]
		)
	asset_inspector.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(splat_path))

	toolbar.queue_free()
	history.clear_history()
	toolbar_owner.free()
	panel.queue_free()
	viewport.queue_free()
	await get_tree().process_frame
	print("=== compact material UI failures: %d ===" % _failed)
	_finish.call_deferred(1 if _failed else 0)


## Return whether every authored paint control and choice provides concise hover guidance.
func _main_tooltips_are_complete(panel: MaterialPaintPanel) -> bool:
	var controls: Array[Control] = [
		panel._more_menu,
		panel._no_constraint_mode,
		panel._splatmap_mode,
		panel._splatmap_setup_button,
		panel._splatmap_channel_gallery,
		panel._splatmap_picker_gallery,
		panel._mask_preview,
		panel._material_gallery,
		panel._mask,
		panel._range_low,
		panel._range_high,
		panel._fade,
		panel._influence,
		panel._invert,
		panel._noise_scale,
		panel._noise_seed,
		panel._noise_angle,
		panel._paint_target,
		panel._brush_opacity,
		panel._hardness,
		panel._procedural_button,
		panel._material_scale,
		panel._material_height_blend,
		panel._rule_select,
		panel._add_rule_button,
		panel._remove_rule_button,
		panel._rule_source,
		panel._rule_combine,
		panel._rule_channel,
		panel._rule_low,
		panel._rule_high,
		panel._rule_fade,
		panel._rule_strength,
		panel._rule_invert,
		panel._rule_noise_scale,
		panel._rule_noise_seed,
		panel._rule_noise_angle,
		panel._splatmap_path,
		panel._blend_mode,
		panel._debug_view,
		panel._paint_detail,
		panel._maximum_edge,
		panel._paint_memory_summary,
		panel._apply_resolution_button,
		panel._pressure_size,
		panel._pressure_opacity,
		panel._auto_texture_thin_side_slivers,
	]
	for control: Control in controls:
		if control.tooltip_text.strip_edges().is_empty():
			return false
	for control: Button in panel._splatmap_slots:
		if control.tooltip_text.strip_edges().is_empty():
			return false
	for index: int in panel._material_gallery.item_count:
		if panel._material_gallery.get_item_tooltip(index).strip_edges().is_empty():
			return false
	for index: int in panel._mask.item_count:
		if panel._mask.get_item_tooltip(index).strip_edges().is_empty():
			return false
	var more_popup := panel._more_menu.get_popup()
	for index: int in more_popup.item_count:
		if not more_popup.is_item_separator(index) and more_popup.get_item_tooltip(index).strip_edges().is_empty():
			return false
	return true


## Return a rectangular regular heightfield with every allocated cell explicitly filled.
func _filled_terrain(size_cells: Vector2i) -> TerrainMesh:
	var terrain := TerrainMesh.create(Vector2i.ZERO, size_cells)
	for z: int in size_cells.y:
		for x: int in size_cells.x:
			terrain.set_cell_filled(Vector2i(x, z), true)
	return terrain


## Return the first top-surface heightfield batch rendered by the viewport.
func _top_terrain_batch(viewport: MTSStudioViewport) -> MultiMeshInstance3D:
	var first_top_batch: MultiMeshInstance3D = null
	for value: Variant in viewport.terrain_renderer.chunk_instances():
		var instance := value as MultiMeshInstance3D
		if (
			instance == null
			or not String(instance.get_meta("mts_batch_key", "")).contains(",t,")
		):
			continue
		if first_top_batch == null:
			first_top_batch = instance
		var material := instance.material_override as ShaderMaterial
		if material == null:
			continue
		var slots_value: Variant = material.get_meta(
			SurfaceMaterialFactory.SURFACE_BLEND_SLOT_MATERIALS_META,
			PackedInt32Array()
		)
		if slots_value is PackedInt32Array and (slots_value as PackedInt32Array).has(0):
			return instance
	return first_top_batch


## Create one minimal 4 x 4 metre direct PNG material for the real panel workflow.
func _surface_asset(asset_id: String) -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = asset_id
	asset.display_name = asset_id
	asset.source_type = 0
	asset.source_path = "res://icon.svg"
	asset.grid_bounds = Vector3i(4, 4, 1)
	asset.visual_size_m = Vector3(4, 4, 0)
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", "res://icon.svg")
	return asset


## Record one editor integration assertion without hiding a failed condition.
func _check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS  %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s" % label)


## Let fixture locals release their rendering resources before engine teardown.
func _finish(code: int) -> void:
	get_tree().quit(code)
