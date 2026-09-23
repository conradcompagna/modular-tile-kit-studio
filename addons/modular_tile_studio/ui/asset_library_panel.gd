@tool
class_name AssetLibraryPanel
extends VBoxContainer

## Left column: the one unified library holding PNG surfaces and GLB props
## (spec 8/42). Browse, filter, search, and select the current brush.
##
## The level filter narrows that same one list to what the open board accounts
## for. It never hides anything permanently: "All assets" is always one click
## away, and the status line always names the scope the list is under.

const K := preload("../utils/mts_constants.gd")

signal asset_selected(asset: TileAsset)
signal import_image_requested()
signal import_glb_requested()
## User asked to permanently delete an asset and its files. The panel does
## not act on this itself: deletion touches the board and the library, which
## the plugin owns.
signal delete_asset_requested(asset: TileAsset)
## User asked to remove every current-board reference while preserving the reusable library asset.
signal remove_asset_from_level_requested(asset: TileAsset)

## Sentinel id for the "All types" entry. Must not collide with any SourceType.
const FILTER_ALL: int = 999

## Level-scope ids. These live on their own OptionButton, so plain 0..2 cannot be
## confused with the SourceType values the type filter carries.
const LEVEL_ALL: int = 0
const LEVEL_USED: int = 1
const LEVEL_USED_OR_IMPORTED: int = 2
const CONTEXT_REMOVE_FROM_LEVEL: int = 1

## Dim colour marking an import the open level has not placed yet.
const UNPLACED_IMPORT_COLOR: Color = Color(0.62, 0.66, 0.74)

var library: AssetLibrary
## The open board the level filter describes. Null means no level to scope to.
var board: BoardDocument
## Canonical owner of material paint pixels and their face-local palette mappings.
var material_paint: MTSSurfaceMaterialPaint

var _search: LineEdit
var _level_filter: OptionButton
var _type_filter: OptionButton
var _category_filter: OptionButton
var _list: ItemList
var _count_label: Label
var _delete_button: Button
var _context_menu: PopupMenu
var _context_asset: TileAsset
var _filtered: Array[TileAsset] = []
## Guards the one coalesced refresh a batch of board edits asks for.
var _board_refresh_queued: bool = false


func _ready() -> void:
	custom_minimum_size = Vector2(240, 0)
	clip_contents = true
	add_theme_constant_override("separation", 4)

	var title := Label.new()
	title.text = "ASSET LIBRARY"
	title.add_theme_font_size_override("font_size", 12)
	add_child(title)

	# Import buttons live only on the toolbar; duplicating them here was noise.

	_search = LineEdit.new()
	_search.placeholder_text = "Search assets..."
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: refresh())
	add_child(_search)

	# Which assets the open level accounts for. One control rather than a pair of
	# checkboxes because the three scopes are mutually exclusive readings of the
	# same list, and the widest of them is just the plain library.
	_level_filter = OptionButton.new()
	_level_filter.add_item("All assets", LEVEL_ALL)
	_level_filter.add_item("Used in this level", LEVEL_USED)
	_level_filter.add_item("Used or imported here", LEVEL_USED_OR_IMPORTED)
	_level_filter.tooltip_text = (
		"All assets: the whole library.\n"
		+ "Used in this level: assets the open board places, paints with, or binds to a monster.\n"
		+ "Used or imported here: also shows assets imported while this level was open but not placed yet."
	)
	_level_filter.item_selected.connect(func(_i: int) -> void:
		_update_delete_button()
		refresh()
	)
	add_child(_level_filter)

	_type_filter = OptionButton.new()
	# IDs must be non-negative and distinct from the SourceType values.
	# add_item(text, -1) does NOT store -1: Godot falls back to the item index,
	# so "All types" at index 0 got id 0 == IMAGE_SURFACE and silently filtered
	# every prop out of the library. FILTER_ALL is an explicit sentinel instead.
	_type_filter.add_item("All types", FILTER_ALL)
	_type_filter.add_item("PNG Images", K.SourceType.IMAGE_SURFACE)
	_type_filter.add_item("GLB Props", K.SourceType.GLB_PROP)
	_type_filter.item_selected.connect(func(_i: int) -> void: refresh())
	add_child(_type_filter)

	_category_filter = OptionButton.new()
	_category_filter.item_selected.connect(func(_i: int) -> void: refresh())
	add_child(_category_filter)

	_list = ItemList.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# max_columns = 0 means "fit as many columns as the width allows" rather than
	# forcing a fixed count. Forcing 2 pushed the second column past the panel
	# edge, so thumbnails and names ran off-screen.
	_list.max_columns = 0
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.fixed_icon_size = Vector2i(64, 64)
	_list.fixed_column_width = 108
	_list.same_column_width = true
	# Long asset ids are clipped to the cell instead of widening it.
	_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_list.auto_height = false
	_list.allow_rmb_select = true
	_list.item_selected.connect(_on_item_selected)
	_list.item_clicked.connect(_on_item_clicked)
	add_child(_list)

	_context_menu = PopupMenu.new()
	_context_menu.add_item("Remove every use from this level", CONTEXT_REMOVE_FROM_LEVEL)
	_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	add_child(_context_menu)

	# The action follows the visible scope: a level view edits only the level,
	# while the all-assets view exposes the explicitly permanent library action.
	_delete_button = Button.new()
	_delete_button.pressed.connect(_on_delete_button_pressed)
	add_child(_delete_button)
	_update_delete_button()

	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 10)
	add_child(_count_label)


## Bind the library this panel browses and the board its level filter describes.
##
## The library and board are long-lived plugin objects. Material paint is rebound
## separately because an atomic level load replaces that derived paint owner.
func bind(
	p_library: AssetLibrary,
	p_board: BoardDocument,
	p_material_paint: MTSSurfaceMaterialPaint = null
) -> void:
	library = p_library
	if library != null and not library.library_changed.is_connected(refresh):
		library.library_changed.connect(refresh)
	board = p_board
	if board != null and not board.board_changed.is_connected(_on_board_changed):
		board.board_changed.connect(_on_board_changed)
	set_material_paint(p_material_paint, false)
	# With no board there is no level to scope to, so the control reports that by
	# being unusable rather than by quietly listing everything under a level name.
	_level_filter.disabled = board == null
	if board == null:
		_level_filter.select(0)
	refresh()


## Rebind the canonical paint owner after an atomic level load replaces it.
##
## Used material ids come from this owner's actual nonzero face pixels, so keeping
## the old owner would omit every splat or masked-paint asset loaded with the level.
func set_material_paint(
	p_material_paint: MTSSurfaceMaterialPaint,
	refresh_panel: bool = true
) -> void:
	if material_paint == p_material_paint:
		if refresh_panel:
			refresh()
		return
	if (
		material_paint != null
		and material_paint.palette_usage_changed.is_connected(_on_board_changed)
	):
		material_paint.palette_usage_changed.disconnect(_on_board_changed)
	material_paint = p_material_paint
	if (
		material_paint != null
		and not material_paint.palette_usage_changed.is_connected(_on_board_changed)
	):
		material_paint.palette_usage_changed.connect(_on_board_changed)
	if refresh_panel:
		refresh()


## Make the shared action explicit about whether it edits the level or the library.
func _update_delete_button() -> void:
	if _delete_button == null:
		return
	if _selected_level_scope() == LEVEL_ALL:
		_delete_button.text = "Permanently Delete Library Asset"
		_delete_button.tooltip_text = (
			"Permanently delete the selected asset and every file it owns. "
			+ "This cannot be undone."
		)
	else:
		_delete_button.text = "Remove Selected Asset From Level"
		_delete_button.tooltip_text = (
			"Remove every use from this level only. The library files are preserved, "
			+ "and the change can be undone."
		)


## Route the selected asset through the action represented by the visible scope.
func _on_delete_button_pressed() -> void:
	var selected := _selected_asset()
	if selected == null:
		return
	if _selected_level_scope() == LEVEL_ALL:
		delete_asset_requested.emit(selected)
	else:
		remove_asset_from_level_requested.emit(selected)


## Follow board edits, because the level view is derived from board state.
##
## A brush stroke emits board_changed once per placed cell, so the rebuild is
## coalesced to one per frame instead of reloading every thumbnail per cell.
func _on_board_changed() -> void:
	if _selected_level_scope() == LEVEL_ALL:
		return  # Nothing in the plain library list depends on the board.
	if _board_refresh_queued:
		return
	_board_refresh_queued = true
	_refresh_after_board_change.call_deferred()


## Run the single coalesced refresh a batch of board edits asked for.
func _refresh_after_board_change() -> void:
	_board_refresh_queued = false
	refresh()


## The level scope currently selected, as one of the LEVEL_* ids.
func _selected_level_scope() -> int:
	if _level_filter == null or _level_filter.selected < 0:
		return LEVEL_ALL
	return _level_filter.get_item_id(_level_filter.selected)


## Asset ids the open level accounts for, split by how each one got here.
##
## Returns {"used": Dictionary, "imported_unused": Dictionary}, both id sets. An
## id lands in exactly one of them: once an import is placed it is simply used,
## which is what keeps the two counts in the status line adding up to the list.
func _level_asset_ids() -> Dictionary:
	var used: Dictionary = {}
	var imported_unused: Dictionary = {}
	if board == null:
		return {"used": used, "imported_unused": imported_unused}
	var active_material_indices := PackedInt32Array()
	if material_paint != null:
		active_material_indices = material_paint.used_palette_indices()
	for used_id: String in board.used_asset_ids(active_material_indices):
		used[used_id] = true
	for imported_id: String in board.imported_asset_ids:
		if not used.has(imported_id):
			imported_unused[imported_id] = true
	return {"used": used, "imported_unused": imported_unused}


## Spell out what the list is showing, so a short list never looks like a bug.
func _describe_counts(level_scope: int, used_shown: int, imported_shown: int) -> String:
	if level_scope == LEVEL_ALL:
		return "%d of %d assets" % [_filtered.size(), library.assets.size()]
	if board == null:
		return "No board bound"
	if level_scope == LEVEL_USED:
		return "%d used in %s (%d in library)" % [
			used_shown, board.board_name, library.assets.size()
		]
	return "%s: %d used, %d imported unused (%d in library)" % [
		board.board_name, used_shown, imported_shown, library.assets.size()
	]


## Rebuild the visible list from the library, the search box, and the filters.
##
## The list is rebuilt whole rather than reconciled item by item: it runs on a
## library change, a filter change, or one coalesced batch of board edits per
## frame, and a reconciliation pass would be a second representation of what the
## ItemList already holds.
func refresh() -> void:
	if _list == null:
		return
	_list.clear()
	_filtered.clear()
	if library == null:
		_count_label.text = "No library"
		return

	_refresh_categories()

	var type_id := FILTER_ALL
	if _type_filter.selected >= 0:
		type_id = _type_filter.get_item_id(_type_filter.selected)
	if type_id == FILTER_ALL:
		type_id = -1  # AssetLibrary.filter treats negative as "any type"
	var category := ""
	if _category_filter.selected > 0:
		category = _category_filter.get_item_text(_category_filter.selected)

	# AssetLibrary is board-agnostic on purpose, so the level scope is applied here
	# instead: this panel is the one place where "what exists" and "what this level
	# accounts for" meet. Both id sets stay empty under LEVEL_ALL, which makes every
	# asset fall through the two skips below unchanged.
	var level_scope := _selected_level_scope()
	var used_ids: Dictionary = {}
	var imported_unused_ids: Dictionary = {}
	if level_scope != LEVEL_ALL:
		var level_ids := _level_asset_ids()
		used_ids = level_ids["used"]
		imported_unused_ids = level_ids["imported_unused"]

	var used_shown := 0
	var imported_shown := 0
	for asset: TileAsset in library.filter(type_id, category, "", _search.text):
		var is_used: bool = used_ids.has(asset.asset_id)
		var is_imported_unused: bool = imported_unused_ids.has(asset.asset_id)
		if level_scope == LEVEL_USED and not is_used:
			continue
		if level_scope == LEVEL_USED_OR_IMPORTED and not is_used and not is_imported_unused:
			continue
		_filtered.append(asset)
		if is_used:
			used_shown += 1
		elif is_imported_unused:
			imported_shown += 1

		var tooltip := "%s\n%s" % [asset.display_name, asset.summary()]
		if is_imported_unused:
			tooltip += "\nImported for this level, not placed yet."
		var index := _list.add_item(asset.asset_id)
		_list.set_item_tooltip(index, tooltip)
		var icon := _load_icon(asset)
		if icon != null:
			_list.set_item_icon(index, icon)
		if is_imported_unused:
			# The merged scope shows two different things at once, so the unplaced
			# imports are dimmed AND say so in the tooltip: colour alone would be a
			# code to learn, and a tooltip alone would need a hover to notice.
			_list.set_item_custom_fg_color(index, UNPLACED_IMPORT_COLOR)
	_count_label.text = _describe_counts(level_scope, used_shown, imported_shown)


func _refresh_categories() -> void:
	var previous := ""
	if _category_filter.selected > 0:
		previous = _category_filter.get_item_text(_category_filter.selected)
	_category_filter.clear()
	_category_filter.add_item("All categories")
	var idx := 1
	for category in library.categories():
		_category_filter.add_item(category)
		if category == previous:
			_category_filter.select(idx)
		idx += 1


func _load_icon(asset: TileAsset) -> Texture2D:
	for path in [asset.thumbnail_path, asset.source_path]:
		if path.is_empty():
			continue
		if ResourceLoader.exists(path):
			var tex := ResourceLoader.load(path) as Texture2D
			if tex != null:
				return tex
		# Freshly generated files may not be in the resource cache yet.
		var global_path := ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(global_path):
			var image := Image.new()
			if image.load(global_path) == OK:
				return ImageTexture.create_from_image(image)
	return null


## Asset behind the current list selection, or null when nothing is selected.
func _selected_asset() -> TileAsset:
	if _list == null or library == null:
		return null
	var selection := _list.get_selected_items()
	if selection.is_empty():
		return null
	return library.get_asset(_list.get_item_text(selection[0]))


func _on_item_selected(index: int) -> void:
	if index < 0 or index >= _filtered.size():
		return
	asset_selected.emit(_filtered[index])


## Open the level-only removal action for the exact asset under a right-click.
func _on_item_clicked(index: int, at_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	if _selected_level_scope() == LEVEL_ALL or index < 0 or index >= _filtered.size():
		return
	var asset := _filtered[index]
	var level_ids := _level_asset_ids()
	if (
		not (level_ids["used"] as Dictionary).has(asset.asset_id)
		and not (level_ids["imported_unused"] as Dictionary).has(asset.asset_id)
	):
		return
	_context_asset = asset
	_list.select(index)
	_context_menu.set_item_disabled(0, false)
	_context_menu.set_item_text(0, "Remove every use from this level")
	_context_menu.position = Vector2i(_list.get_screen_position() + at_position)
	_context_menu.popup()


## Forward the explicit context-menu command to the plugin that owns board-wide undo.
func _on_context_menu_id_pressed(id: int) -> void:
	if id != CONTEXT_REMOVE_FROM_LEVEL or _context_asset == null:
		return
	remove_asset_from_level_requested.emit(_context_asset)
	_context_asset = null


func select_asset(asset: TileAsset) -> void:
	var index := _filtered.find(asset)
	if index >= 0:
		_list.select(index)


