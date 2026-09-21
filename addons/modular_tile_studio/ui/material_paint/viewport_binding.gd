@tool
extends RefCounted

## Viewport binding behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Arm the viewport brush only after both a visible PNG and an explicit mask exist.
static func _update_viewport_tool(host: MaterialPaintPanel) -> void:
	if host.viewport == null:
		return
	var splatmap_mode := host._splatmap_mode_enabled()
	var mask_paint_mode := host._mask_paint_mode_enabled()
	var no_constraint_mode := host._no_constraint_mode_enabled()
	var layer_index := host._selected_layers[MaterialPaintPanel.Workflow.PAINT]
	var local_layer_mode := (
		(mask_paint_mode or no_constraint_mode)
		and not splatmap_mode
		and layer_index >= 0
		and not host._stamp_mode_active()
	)
	var layer_asset: TileAsset = null
	if local_layer_mode and host._draft != null and host.library != null:
		var layer_asset_id := String(host._draft.layer(layer_index).get("asset_id", ""))
		layer_asset = host.library.get_asset(layer_asset_id)
	var local_input_ready := layer_asset != null and layer_asset.is_surface()
	var layer_tile_mode := (
		local_layer_mode
		and local_input_ready
		and host._paint_target_mode() == MaterialPaintPanel.PaintTarget.TILE_BRUSH
	)
	if layer_index >= 0:
		host.viewport.set_material_brush_palette_index(layer_index)
	if local_input_ready:
		host.viewport.set_material_layer_brush_asset(layer_asset)
	else:
		host.viewport.clear_material_layer_brush_asset()
	host.viewport.set_splatmap_tile_paint_enabled(splatmap_mode)
	host.viewport.set_material_tile_paint_enabled(layer_tile_mode)
	if splatmap_mode:
		# The visible mode delegates input exclusively to the ordinary base-coat
		# controller, which stamps every RGBA weight through one tile gesture.
		host.viewport.set_material_mask_preview(false, 0)
		host.viewport.disarm_native_decal_brush()
		host.viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
		return
	if host._stamp_mode_active():
		host.viewport.set_material_mask_preview(false, 0)
		var asset := host.library.get_asset(host._current_asset_id()) if host.library != null else null
		if asset == null or not asset.is_surface():
			host.viewport.disarm_native_decal_brush()
			return
		# The two stamp toggles differ only in the presentation they arm; each
		# commits an ordinary SurfacePlacement through the placement controller.
		if host._shader_decal_mode != null and host._shader_decal_mode.button_pressed:
			host.viewport.arm_shader_decal_brush(
				asset,
				(
					host._match_underlying_palette != null
					and host._match_underlying_palette.button_pressed
				),
				host._decal_edge_mode != null and host._decal_edge_mode.button_pressed
			)
		else:
			host.viewport.arm_native_decal_brush(
				asset,
				(
					host._match_underlying_palette != null
					and host._match_underlying_palette.button_pressed
				),
				host._decal_edge_mode != null and host._decal_edge_mode.button_pressed
			)
		return

	host.viewport.disarm_native_decal_brush()
	var preview_enabled := (
		mask_paint_mode
		and layer_index >= 0
		and host._mask_preview != null
		and host._mask_preview.button_pressed
	)
	host.viewport.set_material_mask_preview(preview_enabled, maxi(layer_index, 0))
	if layer_tile_mode:
		host.viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
	elif local_layer_mode and local_input_ready:
		host.viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.PAINT)
	else:
		host.viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)


## Describe the one missing step or confirm local and level-wide actions without backend jargon.
static func _update_status(host: MaterialPaintPanel) -> void:
	if host._status == null:
		return
	if host._draft == null:
		host._status.text = "Open or create a board to texture its PNG surfaces."
		return
	if host._splatmap_mode_enabled():
		if host._draft.splatmap_source_path.is_empty():
			host._status.text = "Load an RGBA splatmap to arm the square base-coat terrain brush."
		else:
			var overlay_state := "ON" if host._draft.splatmap_overlay_enabled else "OFF"
			var empty_region_state := "native empty regions"
			if host._draft.splatmap_fill_empty_regions:
				empty_region_state = "%s base fill ON" % MaterialPaintPanel.SPLATMAP_CHANNEL_NAMES[
					host._draft.splatmap_empty_region_channel
				]
			var strength_state := "native RGBA strengths"
			if host._draft.splatmap_channel_strengths_enabled:
				var strengths := host._draft.splatmap_channel_strengths * 100.0
				strength_state = "R %.0f%% · G %.0f%% · B %.0f%% · A %.0f%%" % [
					strengths.x,
					strengths.y,
					strengths.z,
					strengths.w,
				]
			host._status.text = (
				"Splatmap loaded on %s; empty outer frame fitted to the terrain footprint; "
				+ "overlay %s; %s; %s. The square base-coat brush paints all four RGBA "
				+ "materials together on matching terrain faces."
			) % [
				MaterialPaintPanel.SPLATMAP_PROJECTION_NAMES[int(host._draft.splatmap_projection)],
				overlay_state,
				empty_region_state,
				strength_state,
			]
		return
	if host._stamp_mode_active():
		var shader_decal := (
			host._shader_decal_mode != null and host._shader_decal_mode.button_pressed
		)
		var decal_asset_id := host._current_asset_id()
		var kind := "shader" if shader_decal else "native"
		var anchor_note := (
			" Edge placement snaps the image centre to a four-cell grid junction."
			if host._decal_edge_mode != null and host._decal_edge_mode.button_pressed
			else ""
		)
		if decal_asset_id.is_empty():
			host._status.text = (
				"Select a PNG, then click a terrain face to stamp a %s decal.%s"
				% [kind, anchor_note]
			)
		elif shader_decal:
			var decal_asset := (
				host.library.get_asset(decal_asset_id) if host.library != null else null
			)
			var footprint_size := (
				decal_asset.surface_footprint()
				if decal_asset != null
				else Vector2i.ONE
			)
			var palette_note := (
				" Palette matching is ON."
				if (
					host._match_underlying_palette != null
					and host._match_underlying_palette.button_pressed
				)
				else ""
			)
			if not host._asset_has_height_map(decal_asset):
				host._status.text = (
					"'%s' has no height map, so it will stamp flat. The albedo, normal, "
					+ "ORM, and emission maps still join the terrain material.%s"
				) % [decal_asset_id, palette_note + anchor_note]
			else:
				host._status.text = (
					"Click a terrain face to compose %s as one image across its %d x %d "
					+ "footprint. Its height map uses the existing board-wide parallax "
					+ "controls; no separate geometry or transparent draw is created.%s"
				) % [
					decal_asset_id,
					footprint_size.x,
					footprint_size.y,
					palette_note + anchor_note,
				]
		else:
			host._status.text = (
				"Click a terrain face to stamp %s as a native decal. Albedo, normal, "
				+ "ORM, and emission apply; height/parallax does not.%s"
			) % [decal_asset_id, anchor_note]
		return
	var workflow := MaterialPaintPanel.Workflow.PAINT
	var layer_index := host._selected_layers[workflow]
	var pending_asset := host._pending_assets[workflow]
	if layer_index < 0 and pending_asset.is_empty():
		host._status.text = "Step 1: choose the PNG material you want to use."
		return
	if layer_index < 0:
		host._status.text = (
			"Step 2: choose a mask for '%s'. Selecting the PNG has not changed the map."
			% pending_asset
		)
		return
	var layer := host._draft.layer(layer_index)
	var asset_id := String(layer.get("asset_id", ""))
	if host._no_constraint_mode_enabled():
		var unconstrained_instruction := (
			"Use tile Paint, Replace, Erase, Path, or Polygon from the top toolbar."
			if host._uses_mask_tile_brush()
			else "Paint with left drag; right drag erases."
		)
		host._status.text = (
			"No Constraint ON: %s Arrow keys rotate the PNG for both Pen and Tile. "
			+ "'%s' layers over the base coat without replacing it."
		) % [unconstrained_instruction, asset_id]
		return
	if not host._mask_paint_mode_enabled():
		host._status.text = (
			"Step 3: turn on Mask-based terrain painting when this layer should own "
			+ "viewport paint input."
		)
		return
	var has_level_pass := host._find_layer_for_asset(asset_id, MaterialPaintPanel.Workflow.PROCEDURAL) >= 0
	var paint_instruction := (
		"Use tile Paint, Replace, Erase, Path, or Polygon from the top toolbar."
		if host._uses_mask_tile_brush()
		else "Paint with left drag; right drag erases."
	)
	host._status.text = "Mask-based terrain painting ON: %s %s %s" % [
		paint_instruction,
		asset_id,
		(
			"The level pass is active; the bottom button updates it."
			if has_level_pass
			else "The bottom button applies this setup level-wide."
		),
	]
