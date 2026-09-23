@tool
extends RefCounted

## Selection behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Return whether either visible material workflow delegates input to the tile targeter.
static func uses_tile_brush(host: MaterialPaintPanel) -> bool:
	return host._splatmap_mode_enabled() or host._uses_mask_tile_brush()


## Return whether the visible top-level unconstrained layer mode owns paint input.
static func _no_constraint_mode_enabled(host: MaterialPaintPanel) -> bool:
	return host._no_constraint_mode != null and host._no_constraint_mode.button_pressed


## Return the transient local targeting choice shown by the Paint target control.
static func _paint_target_mode(host: MaterialPaintPanel) -> int:
	if host._paint_target == null or host._paint_target.selected < 0:
		return MaterialPaintPanel.PaintTarget.CIRCULAR_PEN
	return host._paint_target.get_selected_id()


## Restore brush ownership only when the compact workflow is currently in Brush Paint mode.
static func activate(host: MaterialPaintPanel) -> void:
	host._update_viewport_tool()


## Return the one visible local-paint workflow; procedural work is now an explicit bottom action.
static func _workflow(host: MaterialPaintPanel) -> int:
	return MaterialPaintPanel.Workflow.PAINT


## Return the selected palette channel for the visible workflow or negative one when incomplete.
static func _current_layer_index(host: MaterialPaintPanel) -> int:
	return host._selected_layers[host._workflow()]


## Return the PNG represented by the visible thumbnail whether it is pending or already authored.
static func _current_asset_id(host: MaterialPaintPanel) -> String:
	var layer_index := host._selected_layers[MaterialPaintPanel.Workflow.PAINT]
	if host._draft != null and layer_index >= 0:
		return String(host._draft.layer(layer_index).get("asset_id", ""))
	return host._pending_assets[MaterialPaintPanel.Workflow.PAINT]


## Return whether one stored layer belongs to the local brush or explicit level action.
static func _layer_matches_workflow(host: MaterialPaintPanel, layer: Dictionary, workflow: int, _layer_index: int) -> bool:
	var expected_mode := (
		MaterialBlendProfile.ApplicationMode.BRUSH
		if workflow == MaterialPaintPanel.Workflow.PAINT
		else MaterialBlendProfile.ApplicationMode.PROCEDURAL
	)
	return int(layer.get("application_mode", expected_mode)) == expected_mode


## Find the first inspectable layer for one workflow so saved boards reopen on real stored state.
static func _find_first_layer(host: MaterialPaintPanel, workflow: int) -> int:
	if host._draft == null:
		return -1
	var first_disabled := -1
	for index: int in host._draft.layer_count():
		var layer := host._draft.layer(index)
		if String(layer.get("asset_id", "")).is_empty() or not host._layer_matches_workflow(layer, workflow, index):
			continue
		if bool(layer.get("enabled", false)):
			return index
		if first_disabled < 0:
			first_disabled = index
	return first_disabled


## Find the palette channel already assigned to one PNG and one workflow.
static func _find_layer_for_asset(host: MaterialPaintPanel, asset_id: String, workflow: int) -> int:
	if host._draft == null or asset_id.is_empty():
		return -1
	for index: int in host._draft.layer_count():
		var layer := host._draft.layer(index)
		if String(layer.get("asset_id", "")) == asset_id and host._layer_matches_workflow(layer, workflow, index):
			return index
	return -1


## Find one reusable empty palette entry without shifting any saved face indices.
static func _find_empty_layer(host: MaterialPaintPanel) -> int:
	if host._draft == null:
		return -1
	for index: int in host._draft.layer_count():
		if String(host._draft.layer(index).get("asset_id", "")).is_empty():
			return index
	return -1


## Populate a directly visible PNG thumbnail gallery with no GLB or decal entries.
static func _populate_materials(host: MaterialPaintPanel) -> void:
	if host._material_gallery == null:
		return
	host._material_gallery.clear()
	host._material_asset_ids.clear()
	if host.library == null:
		host._material_gallery.add_item("No PNG library")
		host._material_gallery.set_item_disabled(0, true)
		return
	var choices := host._surface_assets_newest_first()
	for asset: TileAsset in choices:
		var display := asset.display_name if not asset.display_name.is_empty() else asset.asset_id
		var index := host._material_gallery.add_item(display)
		host._material_asset_ids.append(asset.asset_id)
		var thumbnail := host._load_asset_thumbnail(asset)
		if thumbnail != null:
			host._material_gallery.set_item_icon(index, thumbnail)
		host._material_gallery.set_item_tooltip(index, "%s\n%s" % [display, asset.asset_id])
	if host._material_asset_ids.is_empty():
		host._material_gallery.add_item("No paintable PNGs")
		host._material_gallery.set_item_disabled(0, true)
		host._material_gallery.set_item_tooltip(
			0,
			"Import a direct non-decal PNG surface to make it available for material painting."
		)


## Load the same saved thumbnail or direct PNG preview used by the asset and Block Out panels.
static func _load_asset_thumbnail(host: MaterialPaintPanel, asset: TileAsset) -> Texture2D:
	if asset == null:
		return null
	for path: String in [asset.thumbnail_path, asset.source_path]:
		if path.is_empty():
			continue
		if ResourceLoader.exists(path):
			var cached := ResourceLoader.load(path) as Texture2D
			if cached != null:
				return cached
		var global_path := ProjectSettings.globalize_path(path)
		if not FileAccess.file_exists(global_path):
			continue
		var image := Image.new()
		if image.load(global_path) == OK:
			return ImageTexture.create_from_image(image)
	return null


## Return every paintable PNG ordered by its canonical import timestamp, newest first.
static func _surface_assets_newest_first(host: MaterialPaintPanel) -> Array[TileAsset]:
	var choices: Array[TileAsset] = []
	if host.library == null:
		return choices
	for asset: TileAsset in host.library.assets:
		if asset != null and asset.is_surface():
			choices.append(asset)
	choices.sort_custom(host._sort_assets_by_newest)
	return choices


## Compare canonical ISO import timestamps and use the stable asset id only to break exact ties.
static func _sort_assets_by_newest(host: MaterialPaintPanel, left: TileAsset, right: TileAsset) -> bool:
	var left_imported_at := String(left.processing.get("imported_at", ""))
	var right_imported_at := String(right.processing.get("imported_at", ""))
	if left_imported_at != right_imported_at:
		return left_imported_at > right_imported_at
	return left.asset_id.naturalnocasecmp_to(right.asset_id) < 0


## Select the PNG thumbnail whose parallel stable-id array matches canonical state.
static func _select_material(host: MaterialPaintPanel, asset_id: String) -> void:
	host._material_gallery.deselect_all()
	var index := host._material_asset_ids.find(asset_id)
	if index >= 0:
		host._material_gallery.select(index)
		host._material_gallery.ensure_current_is_visible()
