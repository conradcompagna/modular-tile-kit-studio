@tool
extends RefCounted

## Paint modes behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Return whether the top-level workflow delegates terrain input to the square base-coat brush.
static func _splatmap_mode_enabled(host: MaterialPaintPanel) -> bool:
	return host._draft != null and host._draft.splatmap_mode_enabled


## Return the visible transient switch that explicitly grants mask painting viewport input.
static func _mask_paint_mode_enabled(host: MaterialPaintPanel) -> bool:
	return host._mask_paint_mode != null and host._mask_paint_mode.button_pressed


## Return whether a complete local mask layer visibly delegates input to the tile targeter.
static func _uses_mask_tile_brush(host: MaterialPaintPanel) -> bool:
	if (
		not (host._mask_paint_mode_enabled() or host._no_constraint_mode_enabled())
		or host._splatmap_mode_enabled()
		or host._paint_target_mode() != MaterialPaintPanel.PaintTarget.TILE_BRUSH
		or host._stamp_mode_active()
	):
		return false
	return host._selected_layers[MaterialPaintPanel.Workflow.PAINT] >= 0


## Rebuild the four top-level RGBA channel thumbnails from the canonical material profile.
static func _populate_splatmap_channel_gallery(host: MaterialPaintPanel) -> void:
	if host._splatmap_channel_gallery == null:
		return
	host._splatmap_channel_gallery.clear()
	var channel_names := PackedStringArray(["R", "G", "B", "A"])
	for channel_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		var palette_index := (
			host._draft.splatmap_palette_indices[channel_index]
			if host._draft != null
			else -1
		)
		var mapping_valid := (
			host._draft != null
			and palette_index >= 0
			and palette_index < host._draft.layer_count()
		)
		var layer := host._draft.layer(palette_index) if mapping_valid else {}
		var asset_id := String(layer.get("asset_id", ""))
		var display := "Unassigned"
		var thumbnail: Texture2D = null
		var asset := host.library.get_asset(asset_id) if host.library != null and not asset_id.is_empty() else null
		if asset != null and asset.is_surface():
			display = asset.display_name if not asset.display_name.is_empty() else asset.asset_id
			thumbnail = host._load_asset_thumbnail(asset)
		var item_index := host._splatmap_channel_gallery.add_item(
			"%s · %s" % [channel_names[channel_index], display],
			thumbnail
		)
		host._splatmap_channel_gallery.set_item_metadata(item_index, palette_index)
		var brush_authored := (
			mapping_valid
			and not asset_id.is_empty()
			and host._layer_matches_workflow(layer, MaterialPaintPanel.Workflow.PAINT, palette_index)
		)
		host._splatmap_channel_gallery.set_item_disabled(item_index, not brush_authored)
		host._splatmap_channel_gallery.set_item_tooltip(
			item_index,
			(
				"%s channel → %s\n%s\nSelect this material for pen and procedural-mask controls."
				% [channel_names[channel_index], display, asset_id]
				if brush_authored
				else "%s channel is unassigned; use Load / Assign to configure it."
				% channel_names[channel_index]
			)
		)
		if brush_authored and palette_index == host._selected_layers[MaterialPaintPanel.Workflow.PAINT]:
			host._splatmap_channel_gallery.select(item_index)


## Select one canonical RGBA layer from its top-level thumbnail without reallocating any slot.
static func _on_splatmap_channel_selected(host: MaterialPaintPanel, item_index: int) -> void:
	if host._updating or host._draft == null or item_index < 0:
		return
	var layer_index := int(host._splatmap_channel_gallery.get_item_metadata(item_index))
	if layer_index < 0 or layer_index >= host._draft.layer_count():
		return
	var layer := host._draft.layer(layer_index)
	if not host._layer_matches_workflow(layer, MaterialPaintPanel.Workflow.PAINT, layer_index):
		return
	host._selected_layers[MaterialPaintPanel.Workflow.PAINT] = layer_index
	host._pending_assets[MaterialPaintPanel.Workflow.PAINT] = ""
	host._refresh_main_controls()


## Toggle splatmap paint ownership independently from the optional source overlay.
static func _on_splatmap_mode_toggled(host: MaterialPaintPanel, enabled: bool) -> void:
	if host._updating or host._draft == null:
		return
	host._draft.splatmap_mode_enabled = enabled
	if enabled:
		host._no_constraint_mode.set_pressed_no_signal(false)
		host._mask_paint_mode.set_pressed_no_signal(false)
		host._decal_mode.set_pressed_no_signal(false)
		host._shader_decal_mode.set_pressed_no_signal(false)
		host._mask_preview.set_pressed_no_signal(false)
		host._selected_layers[MaterialPaintPanel.Workflow.PAINT] = host._find_first_layer(MaterialPaintPanel.Workflow.PAINT)
		host._pending_assets[MaterialPaintPanel.Workflow.PAINT] = ""
	else:
		host._draft.splatmap_overlay_enabled = false
		host._splatmap_overlay.set_pressed_no_signal(false)
	host._commit_profile(
		"Enable splatmap terrain mode" if enabled else "Disable splatmap terrain mode"
	)
	host._refresh_main_controls()
	host.tile_brush_mode_changed.emit(host.uses_tile_brush())


## Explicitly arm or disarm mask-based terrain painting without changing its material recipe.
static func _on_mask_paint_mode_toggled(host: MaterialPaintPanel, enabled: bool) -> void:
	if host._updating:
		return
	if enabled:
		host._clear_other_paint_modes(host._mask_paint_mode)
	host._refresh_main_controls()
	host.tile_brush_mode_changed.emit(host.uses_tile_brush())


## Arm or release unconstrained layered PNG painting without changing the base coat.
static func _on_no_constraint_mode_toggled(host: MaterialPaintPanel, enabled: bool) -> void:
	if host._updating or host._draft == null:
		return
	if enabled:
		host._clear_other_paint_modes(host._no_constraint_mode)
		var asset_id := host._current_asset_id()
		if not asset_id.is_empty():
			host._ensure_no_constraint_layer(asset_id)
	host._refresh_main_controls()
	host.tile_brush_mode_changed.emit(host.uses_tile_brush())


## Switch the local mask workflow between the existing circular pen and tile targeter.
static func _on_paint_target_selected(host: MaterialPaintPanel, _index: int) -> void:
	if host._updating:
		return
	host._refresh_main_controls()
	host.tile_brush_mode_changed.emit(host.uses_tile_brush())


## Change the one visible source projection and rebuild preview and brush lookup immediately.
static func _on_splatmap_projection_selected(host: MaterialPaintPanel, _index: int) -> void:
	if host._updating or host._draft == null or host._splatmap_projection == null:
		return
	var projection := host._splatmap_projection.get_selected_id()
	var previous_projection := int(host._draft.splatmap_projection)
	if (
		host.viewport != null
		and not host._draft.splatmap_source_path.is_empty()
		and not host.viewport.splatmap_projection_available(projection)
	):
		host._splatmap_projection.select(
			host._splatmap_projection.get_item_index(previous_projection)
		)
		host._status.text = (
			"The terrain has no %s-facing surfaces; the previous projection is unchanged."
			% MaterialPaintPanel.SPLATMAP_PROJECTION_NAMES[projection]
		)
		return
	host._draft.splatmap_projection = projection as MaterialBlendProfile.SplatmapProjection
	if not host._commit_profile("Change splatmap projection"):
		host._status.text = "The selected splatmap projection could not be rebuilt."
		return
	host._refresh_main_controls()


## Toggle only the optional source-map guide while leaving paint ownership and weights unchanged.
static func _on_splatmap_overlay_toggled(host: MaterialPaintPanel, enabled: bool) -> void:
	if host._updating or host._draft == null:
		return
	if enabled and host._draft.splatmap_source_path.is_empty():
		host._splatmap_overlay.set_pressed_no_signal(false)
		host._status.text = "Load an RGBA splatmap before showing its source overlay."
		return
	host._draft.splatmap_overlay_enabled = enabled
	host._commit_profile(
		"Show splatmap source overlay" if enabled else "Hide splatmap source overlay"
	)
	host._refresh_main_controls()


## Switch between terrain material painting and one-click native decal stamping.
##
## This is transient tool state only: committing a decal writes presentation on
## the placement itself, while ordinary material painting still writes its layer.
static func _on_decal_mode_toggled(host: MaterialPaintPanel, enabled: bool) -> void:
	if host._updating:
		return
	# One placement has one render role, so arming this disarms the others.
	if enabled:
		host._clear_other_paint_modes(host._decal_mode)
	host._refresh_main_controls()
	host.tile_brush_mode_changed.emit(host.uses_tile_brush())


## Switch between terrain material painting and one-click shader-decal stamping.
##
## A shader decal is committed as a SurfacePlacement exactly like a native decal.
## Its original maps are sampled once through the terrain's ordinary material-layer
## path, with placement-local addressing instead of tiled repetition.
static func _on_shader_decal_mode_toggled(host: MaterialPaintPanel, enabled: bool) -> void:
	if host._updating:
		return
	if enabled:
		host._clear_other_paint_modes(host._shader_decal_mode)
	host._refresh_main_controls()
	host.tile_brush_mode_changed.emit(host.uses_tile_brush())


## Refresh the active decal brush when the visible grid-edge toggle changes.
static func _on_decal_edge_mode_toggled(host: MaterialPaintPanel, _enabled: bool) -> void:
	if host._updating:
		return
	host._update_viewport_tool()
	host._update_status()


## Turn off every local paint or stamp toggle except the one just armed.
##
## One visible mode owns viewport input at a time, so changing modes cannot leave
## the masked painter active behind a decal brush or another placement workflow.
static func _clear_other_paint_modes(host: MaterialPaintPanel, keep: CheckButton) -> void:
	for toggle: CheckButton in [
		host._no_constraint_mode,
		host._mask_paint_mode,
		host._decal_mode,
		host._shader_decal_mode,
	]:
		if toggle != null and toggle != keep:
			toggle.set_pressed_no_signal(false)


## Push the visible palette-match choice into the armed decal brush immediately.
##
## The toggle changes only subsequently authored placements.
static func _on_palette_match_toggled(host: MaterialPaintPanel, _enabled: bool) -> void:
	if host._updating:
		return
	host._update_viewport_tool()
	host._update_status()


## Return whether one asset carries the height map a decal's relief is built from.
##
## Asked of the asset's own map set rather than assumed, so the panel can say that
## relief is unavailable instead of stamping a decal that silently renders flat.
static func _asset_has_height_map(host: MaterialPaintPanel, asset: TileAsset) -> bool:
	if asset == null or asset.gbuffer == null:
		return false
	return asset.gbuffer.load_texture("height") != null


## Return whether any stamp mode currently owns the brush.
##
## Both suppress the material-layer controls for the same reason: they commit a
## placement rather than painting into a layer's mask.
static func _stamp_mode_active(host: MaterialPaintPanel) -> bool:
	return (
		(host._decal_mode != null and host._decal_mode.button_pressed)
		or (host._shader_decal_mode != null and host._shader_decal_mode.button_pressed)
	)


## Forward the visible diagnostic checkbox without committing profile or board state.
static func _on_mask_preview_toggled(host: MaterialPaintPanel, _enabled: bool) -> void:
	if host._updating:
		return
	host._update_viewport_tool()


## Route the Materials-owned circular pen radius only to the sparse touch-up painter.
static func _on_brush_radius_changed(host: MaterialPaintPanel, value: float) -> void:
	if host.viewport != null:
		host.viewport.set_material_brush_radius(value)


## Route brush strength directly to the sparse painter without creating a layer-opacity duplicate.
static func _on_brush_opacity_changed(host: MaterialPaintPanel, value: float) -> void:
	host._update_slider_label(host._brush_opacity)
	if host.viewport != null:
		host.viewport.set_material_brush_opacity(value / 100.0)


## Route brush edge hardness directly to the sparse painter's existing capsule kernel.
static func _on_brush_hardness_changed(host: MaterialPaintPanel, value: float) -> void:
	host._update_slider_label(host._hardness)
	if host.viewport != null:
		host.viewport.set_material_brush_hardness(value / 100.0)
