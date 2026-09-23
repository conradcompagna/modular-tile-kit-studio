@tool
class_name GameplayMarkersPanel
extends VBoxContainer

## Focused editor for non-enemy markers, monster placements/visuals, and enemy packs.

signal marker_brush_requested(
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
)
signal marker_update_requested(
	marker_id: String,
	marker_type: String,
	note: String,
	monster_id: String,
	pack_id: String
)
signal marker_delete_requested(marker_id: String)
signal enemy_pack_create_requested(pack_id: String, note: String)
signal enemy_pack_update_requested(pack_id: String, note: String)
signal enemy_pack_delete_requested(pack_id: String)
signal enemy_pack_assign_requested(
	marker_ids: PackedStringArray,
	pack_id: String
)
signal monster_visual_assign_requested(monster_id: String, asset_id: String)
signal monster_visual_clear_requested(monster_id: String)
signal monster_glb_import_requested(monster_id: String)
signal placement_enabled_requested(enabled: bool)

var board: BoardDocument
var library: AssetLibrary

var _workspaces: TabContainer

var _marker_scroll: ScrollContainer
var _marker_page: VBoxContainer
var _marker_help_label: Label
var _marker_type_option: OptionButton
var _marker_note_edit: TextEdit
var _marker_list: ItemList
var _marker_ids: PackedStringArray = PackedStringArray()
var _marker_actions: HBoxContainer
var _update_marker_button: Button
var _delete_marker_button: Button

var _monster_scroll: ScrollContainer
var _monster_page: VBoxContainer
var _monster_type_list: ItemList
var _monster_type_ids: PackedStringArray = PackedStringArray()
var _monster_edit: LineEdit
var _monster_note_edit: TextEdit
var _monster_list: ItemList
var _monster_marker_ids: PackedStringArray = PackedStringArray()
var _monster_actions: HBoxContainer
var _monster_visual_option: OptionButton
var _monster_visual_asset_ids: PackedStringArray = PackedStringArray()
var _monster_visual_size_label: Label
var _apply_monster_visual_button: Button
var _clear_monster_visual_button: Button
var _import_monster_glb_button: Button

var _pack_scroll: ScrollContainer
var _pack_page: VBoxContainer
var _enemy_list: ItemList
var _enemy_marker_ids: PackedStringArray = PackedStringArray()
var _pack_list: ItemList
var _pack_list_ids: PackedStringArray = PackedStringArray()
var _pack_id_edit: LineEdit
var _pack_note_edit: TextEdit
var _save_pack_button: Button
var _new_pack_button: Button
var _delete_pack_button: Button

var _status_label: Label


## Build three independently scrollable workspaces so unrelated controls never sprawl together.
func _ready() -> void:
	custom_minimum_size = Vector2(280, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)

	var title := Label.new()
	title.text = "GAMEPLAY"
	title.add_theme_font_size_override("font_size", 12)
	add_child(title)

	_workspaces = TabContainer.new()
	_workspaces.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_workspaces.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_workspaces)

	_build_marker_workspace()
	_build_monster_workspace()
	_build_pack_workspace()
	_workspaces.tab_changed.connect(_on_workspace_changed)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = "No board is bound."
	add_child(_status_label)

	refresh()


## Build only the controls required to place and edit non-enemy gameplay markers.
func _build_marker_workspace() -> void:
	_marker_scroll = ScrollContainer.new()
	_marker_scroll.name = "Markers"
	_marker_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_marker_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_marker_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_workspaces.add_child(_marker_scroll)

	_marker_page = VBoxContainer.new()
	_marker_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_marker_page.add_theme_constant_override("separation", 6)
	_marker_scroll.add_child(_marker_page)

	_marker_help_label = Label.new()
	_marker_help_label.text = "Choose a marker type and optional note, then click a grid cell."
	_marker_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_marker_page.add_child(_marker_help_label)

	_marker_type_option = OptionButton.new()
	for marker_type: String in GameplayMarker.TYPES:
		if marker_type == GameplayMarker.TYPE_ENEMY:
			continue
		_marker_type_option.add_item(marker_type.replace("_", " ").capitalize())
		_marker_type_option.set_item_metadata(
			_marker_type_option.item_count - 1,
			marker_type
		)
	_add_labeled_control("Type", _marker_type_option, _marker_page)

	_marker_note_edit = TextEdit.new()
	_marker_note_edit.custom_minimum_size = Vector2(0, 68)
	_marker_note_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_marker_note_edit.placeholder_text = "Optional context for this grid-cell marker."
	_add_labeled_control("Note (optional)", _marker_note_edit, _marker_page)

	_add_button(
		_marker_page,
		"Use as Brush",
		emit_current_brush,
		"Use the visible non-enemy marker fields for subsequent grid-cell clicks."
	)

	var marker_heading := Label.new()
	marker_heading.text = "Placed"
	_marker_page.add_child(marker_heading)

	_marker_list = ItemList.new()
	_marker_list.custom_minimum_size = Vector2(0, 130)
	_marker_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_marker_list.select_mode = ItemList.SELECT_SINGLE
	_marker_list.item_selected.connect(_on_marker_selected)
	_marker_page.add_child(_marker_list)

	_marker_actions = HBoxContainer.new()
	_marker_actions.add_theme_constant_override("separation", 4)
	_marker_page.add_child(_marker_actions)
	_update_marker_button = _add_button(
		_marker_actions,
		"Save Changes",
		_update_selected_marker,
		"Save the visible fields to the selected non-enemy marker."
	)
	_delete_marker_button = _add_button(
		_marker_actions,
		"Delete",
		_delete_selected_marker,
		"Delete the selected marker from its grid cell."
	)


## Build only monster placement and GLB appearance controls in their own workspace.
func _build_monster_workspace() -> void:
	_monster_scroll = ScrollContainer.new()
	_monster_scroll.name = "Monsters"
	_monster_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_monster_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_monster_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_workspaces.add_child(_monster_scroll)

	_monster_page = VBoxContainer.new()
	_monster_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_monster_page.add_theme_constant_override("separation", 6)
	_monster_scroll.add_child(_monster_page)

	var help := Label.new()
	help.text = (
		"Select a reusable monster type or enter a new Monster ID, then use it "
		+ "as the placement brush. A GLB assignment applies to every matching placement."
	)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_monster_page.add_child(help)

	var monster_types_heading := Label.new()
	monster_types_heading.text = "Monster Types"
	_monster_page.add_child(monster_types_heading)
	_monster_type_list = ItemList.new()
	_monster_type_list.custom_minimum_size = Vector2(0, 100)
	_monster_type_list.select_mode = ItemList.SELECT_SINGLE
	_monster_type_list.item_selected.connect(_on_monster_type_selected)
	_monster_page.add_child(_monster_type_list)

	_monster_edit = LineEdit.new()
	_monster_edit.placeholder_text = "goblin_scout"
	_monster_edit.tooltip_text = "Exact monster/content ID saved on enemy markers."
	_monster_edit.text_changed.connect(_on_monster_id_changed)
	_add_labeled_control("Monster ID", _monster_edit, _monster_page)

	_monster_note_edit = TextEdit.new()
	_monster_note_edit.custom_minimum_size = Vector2(0, 68)
	_monster_note_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_monster_note_edit.placeholder_text = "Optional context for this individual placement."
	_add_labeled_control("Placement note (optional)", _monster_note_edit, _monster_page)

	_add_button(
		_monster_page,
		"Place This Type",
		emit_monster_brush,
		"Use the selected or visible Monster ID as a Solo placement brush."
	)

	var placed_heading := Label.new()
	placed_heading.text = "Placed Monsters"
	_monster_page.add_child(placed_heading)

	_monster_list = ItemList.new()
	_monster_list.custom_minimum_size = Vector2(0, 120)
	_monster_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_monster_list.select_mode = ItemList.SELECT_SINGLE
	_monster_list.item_selected.connect(_on_monster_selected)
	_monster_page.add_child(_monster_list)

	_monster_actions = HBoxContainer.new()
	_monster_actions.add_theme_constant_override("separation", 4)
	_monster_page.add_child(_monster_actions)
	_add_button(
		_monster_actions,
		"Save Changes",
		_update_selected_monster,
		"Save Monster ID and note while preserving pack membership."
	)
	_add_button(
		_monster_actions,
		"Delete",
		_delete_selected_monster,
		"Delete the selected monster placement."
	)

	var visual_heading := Label.new()
	visual_heading.text = "GLB Visual"
	_monster_page.add_child(visual_heading)

	_monster_visual_option = OptionButton.new()
	_monster_visual_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_monster_visual_option.fit_to_longest_item = false
	_monster_visual_option.clip_text = true
	_monster_visual_option.item_selected.connect(_on_monster_visual_selected)
	_monster_page.add_child(_monster_visual_option)

	_monster_visual_size_label = Label.new()
	_monster_visual_size_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_monster_page.add_child(_monster_visual_size_label)

	var visual_actions := HBoxContainer.new()
	visual_actions.add_theme_constant_override("separation", 4)
	_monster_page.add_child(visual_actions)
	_apply_monster_visual_button = _add_button(
		visual_actions,
		"Apply",
		_apply_monster_visual,
		"Assign the selected imported GLB and its canonical size to this Monster ID."
	)
	_import_monster_glb_button = _add_button(
		visual_actions,
		"Import GLB",
		_request_monster_glb_import,
		"Import a GLB with the normal grid-first sizing dialog, then assign it here."
	)
	_clear_monster_visual_button = _add_button(
		visual_actions,
		"Clear",
		_clear_monster_visual,
		"Remove this Monster ID's GLB without changing its placements."
	)


## Build only pack creation and click-drag membership organization controls.
func _build_pack_workspace() -> void:
	_pack_scroll = ScrollContainer.new()
	_pack_scroll.name = "Packs"
	_pack_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pack_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pack_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_workspaces.add_child(_pack_scroll)

	_pack_page = VBoxContainer.new()
	_pack_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pack_page.add_theme_constant_override("separation", 6)
	_pack_scroll.add_child(_pack_page)

	var pack_help := Label.new()
	pack_help.text = "Drag one or more monsters onto a pack. Drop on Solo to remove them."
	pack_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pack_page.add_child(pack_help)

	var enemies_heading := Label.new()
	enemies_heading.text = "Monsters"
	_pack_page.add_child(enemies_heading)
	_enemy_list = ItemList.new()
	_enemy_list.custom_minimum_size = Vector2(0, 130)
	_enemy_list.select_mode = ItemList.SELECT_MULTI
	_enemy_list.set_drag_forwarding(
		_get_enemy_drag_data,
		Callable(),
		Callable()
	)
	_pack_page.add_child(_enemy_list)

	var packs_heading := Label.new()
	packs_heading.text = "Packs"
	_pack_page.add_child(packs_heading)
	_pack_list = ItemList.new()
	_pack_list.custom_minimum_size = Vector2(0, 110)
	_pack_list.select_mode = ItemList.SELECT_SINGLE
	_pack_list.item_selected.connect(_on_pack_selected)
	_pack_list.set_drag_forwarding(
		Callable(),
		_can_drop_enemy_data,
		_drop_enemy_data
	)
	_pack_page.add_child(_pack_list)

	_pack_id_edit = LineEdit.new()
	_pack_id_edit.placeholder_text = "courtyard_ambush"
	_add_labeled_control("Pack ID", _pack_id_edit, _pack_page)

	_pack_note_edit = TextEdit.new()
	_pack_note_edit.custom_minimum_size = Vector2(0, 58)
	_pack_note_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_pack_note_edit.placeholder_text = "Explain how this enemy group behaves."
	_add_labeled_control("Pack note", _pack_note_edit, _pack_page)

	var pack_actions := HBoxContainer.new()
	pack_actions.add_theme_constant_override("separation", 4)
	_pack_page.add_child(pack_actions)
	_save_pack_button = _add_button(
		pack_actions,
		"Create Pack",
		_save_pack,
		"Create a pack or save the selected pack's note."
	)
	_new_pack_button = _add_button(
		pack_actions,
		"New",
		_start_new_pack,
		"Clear the pack form to create another pack."
	)
	_delete_pack_button = _add_button(
		pack_actions,
		"Delete",
		_delete_selected_pack,
		"Delete the selected pack only when it has no members."
	)


## Add one compact labeled field to the requested focused workspace.
func _add_labeled_control(
	label_text: String,
	control: Control,
	parent: Control
) -> VBoxContainer:
	var field := VBoxContainer.new()
	field.add_theme_constant_override("separation", 2)
	parent.add_child(field)
	var label := Label.new()
	label.text = label_text
	field.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.add_child(control)
	return field


## Add one compact action button with its explicit purpose in a tooltip.
func _add_button(
	parent: Control,
	text: String,
	callback: Callable,
	tooltip: String
) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


## Bind the authoritative board and library used by the three visible workspaces.
func bind(p_board: BoardDocument, p_library: AssetLibrary = null) -> void:
	board = p_board
	library = p_library
	if board != null and not board.board_changed.is_connected(refresh):
		board.board_changed.connect(refresh)
	if library != null and not library.library_changed.is_connected(refresh):
		library.library_changed.connect(refresh)
	refresh()


## Rebuild every focused list while preserving stable selections.
func refresh() -> void:
	if (
		_marker_list == null
		or _monster_type_list == null
		or _monster_list == null
		or _enemy_list == null
		or _pack_list == null
	):
		return
	var previous_marker_id := selected_marker_id()
	var previous_monster_type_id := selected_monster_type_id()
	if previous_monster_type_id.is_empty() and _monster_edit != null:
		previous_monster_type_id = _monster_edit.text.strip_edges()
	var previous_monster_marker_id := selected_monster_marker_id()
	var previous_pack_id := selected_pack_id()

	_marker_list.clear()
	_marker_ids.clear()
	_monster_type_list.clear()
	_monster_type_ids.clear()
	_monster_list.clear()
	_monster_marker_ids.clear()
	_enemy_list.clear()
	_enemy_marker_ids.clear()
	_pack_list.clear()
	_pack_list_ids.clear()
	_pack_list.add_item("Solo (no pack)")
	_pack_list_ids.append("")

	if board == null:
		_status_label.text = "No board is bound."
		_populate_monster_visual_options()
		_update_action_state()
		return

	for monster_id: String in board.known_monster_ids():
		_add_monster_type_row(monster_id)

	for pack: EnemyPack in board.enemy_packs:
		if pack == null:
			continue
		var member_count := board.enemy_pack_member_count(pack.pack_id)
		var pack_index := _pack_list.add_item(
			"%s | %d enem%s" % [
				pack.pack_id,
				member_count,
				"y" if member_count == 1 else "ies",
			]
		)
		_pack_list.set_item_tooltip(pack_index, pack.note)
		_pack_list.set_item_custom_fg_color(
			pack_index,
			MTSGameplayMarkerController.pack_color(pack.pack_id)
		)
		_pack_list_ids.append(pack.pack_id)

	var monster_count := 0
	for marker: GameplayMarker in board.gameplay_markers:
		if marker == null:
			continue
		if marker.marker_type == GameplayMarker.TYPE_ENEMY:
			monster_count += 1
			_add_monster_rows(marker)
			continue
		var marker_index := _marker_list.add_item(
			"%s @ %d,%d,%d" % [
				marker.display_title(),
				marker.origin.x,
				marker.origin.y,
				marker.origin.z,
			]
		)
		_marker_list.set_item_custom_fg_color(
			marker_index,
			MTSGameplayMarkerController.marker_color(marker.marker_type)
		)
		_marker_list.set_item_tooltip(marker_index, marker.note)
		_marker_ids.append(marker.marker_id)

	if not previous_marker_id.is_empty():
		_select_marker_list_id(previous_marker_id)
	if not previous_monster_type_id.is_empty():
		_select_monster_type_list_id(previous_monster_type_id)
	if not previous_monster_marker_id.is_empty():
		_select_monster_marker_list_id(previous_monster_marker_id)
	if not previous_pack_id.is_empty():
		_select_pack_list_id(previous_pack_id)
	_populate_monster_visual_options()
	_status_label.text = "%d markers | %d monster placements | %d monster types | %d packs" % [
		_marker_ids.size(),
		monster_count,
		_monster_type_ids.size(),
		board.enemy_packs.size(),
	]
	_update_action_state()


## Add one reusable monster type derived from the board's canonical authored references.
func _add_monster_type_row(monster_id: String) -> void:
	var placement_count := 0
	for marker: GameplayMarker in board.gameplay_markers:
		if (
			marker != null
			and marker.marker_type == GameplayMarker.TYPE_ENEMY
			and marker.monster_id == monster_id
		):
			placement_count += 1
	var type_index := _monster_type_list.add_item(
		"%s | %d placed" % [monster_id, placement_count]
	)
	var visual_asset_id := board.monster_visual_asset_id(monster_id)
	_monster_type_list.set_item_tooltip(
		type_index,
		"No GLB visual assigned."
		if visual_asset_id.is_empty()
		else "GLB visual: %s" % visual_asset_id
	)
	_monster_type_ids.append(monster_id)


## Add one enemy placement to both the Monsters editor and the Packs drag source.
func _add_monster_rows(marker: GameplayMarker) -> void:
	var assignment := "Solo" if marker.pack_id.is_empty() else marker.pack_id
	var color := MTSGameplayMarkerController.marker_color(marker.marker_type)
	if not marker.pack_id.is_empty():
		color = MTSGameplayMarkerController.pack_color(marker.pack_id)

	var monster_index := _monster_list.add_item(
		"%s | %s @ %d,%d,%d" % [
			marker.monster_id,
			marker.marker_id,
			marker.origin.x,
			marker.origin.y,
			marker.origin.z,
		]
	)
	_monster_list.set_item_tooltip(monster_index, marker.note)
	_monster_list.set_item_custom_fg_color(monster_index, color)
	_monster_marker_ids.append(marker.marker_id)

	var enemy_index := _enemy_list.add_item(
		"%s | %s -> %s" % [
			marker.monster_id,
			marker.marker_id,
			assignment,
		]
	)
	_enemy_list.set_item_tooltip(enemy_index, marker.note)
	_enemy_list.set_item_custom_fg_color(enemy_index, color)
	_enemy_marker_ids.append(marker.marker_id)


## Rebuild the GLB selector from project-owned prop assets and show the saved assignment.
func _populate_monster_visual_options() -> void:
	if _monster_visual_option == null:
		return
	var monster_id := _monster_edit.text.strip_edges() if _monster_edit != null else ""
	var assigned_asset_id := (
		board.monster_visual_asset_id(monster_id)
		if board != null and not monster_id.is_empty()
		else ""
	)
	_monster_visual_option.clear()
	_monster_visual_asset_ids.clear()
	_monster_visual_option.add_item("No GLB visual")
	_monster_visual_asset_ids.append("")

	if library != null:
		for asset: TileAsset in library.assets:
			if asset == null or not asset.is_prop():
				continue
			_monster_visual_option.add_item(
				"%s | %.2f x %.2f x %.2f m" % [
					asset.asset_id,
					asset.visual_size_m.x,
					asset.visual_size_m.y,
					asset.visual_size_m.z,
				]
			)
			_monster_visual_asset_ids.append(asset.asset_id)

	var selected_index := _monster_visual_asset_ids.find(assigned_asset_id)
	_monster_visual_option.select(maxi(selected_index, 0))
	_on_monster_visual_selected(_monster_visual_option.selected)


## Return the exact non-enemy marker type visible in the Markers workspace.
func current_marker_type() -> String:
	if _marker_type_option == null or _marker_type_option.selected < 0:
		return ""
	return String(
		_marker_type_option.get_item_metadata(_marker_type_option.selected)
	)


## Return the stable non-enemy marker id behind the current Markers selection.
func selected_marker_id() -> String:
	return _selected_item_id(_marker_list, _marker_ids)


## Return the stable reusable monster type behind the current type selection.
func selected_monster_type_id() -> String:
	return _selected_item_id(_monster_type_list, _monster_type_ids)


## Return the stable enemy marker id behind the current Monsters selection.
func selected_monster_marker_id() -> String:
	return _selected_item_id(_monster_list, _monster_marker_ids)


## Return the stable pack id behind the current Packs selection.
func selected_pack_id() -> String:
	return _selected_item_id(_pack_list, _pack_list_ids)


## Return one stable id from an ItemList without exposing row indexes as data.
func _selected_item_id(list: ItemList, ids: PackedStringArray) -> String:
	if list == null:
		return ""
	var selected := list.get_selected_items()
	if selected.is_empty():
		return ""
	var index := int(selected[0])
	if index < 0 or index >= ids.size():
		return ""
	return ids[index]


## Select one marker in its correct scoped workspace after placement or API mutation.
func select_marker_id(marker_id: String) -> void:
	if board == null:
		return
	var marker := board.get_gameplay_marker(marker_id)
	if marker == null:
		return
	if marker.marker_type == GameplayMarker.TYPE_ENEMY:
		_workspaces.current_tab = _workspaces.get_tab_idx_from_control(_monster_scroll)
		_select_monster_marker_list_id(marker_id)
		_load_monster_into_form(marker_id)
		return
	_workspaces.current_tab = _workspaces.get_tab_idx_from_control(_marker_scroll)
	_select_marker_list_id(marker_id)
	_load_marker_into_form(marker_id)


## Select one reusable Monster ID without borrowing note data from a placement.
func select_monster_id(monster_id: String) -> void:
	if board == null:
		return
	_workspaces.current_tab = _workspaces.get_tab_idx_from_control(_monster_scroll)
	_select_monster_type_list_id(monster_id)
	_monster_list.deselect_all()
	_monster_edit.text = monster_id
	_monster_note_edit.clear()
	_populate_monster_visual_options()
	_update_action_state()


## Activate only the placement behavior owned by the currently visible workspace.
func activate_current_workspace() -> void:
	_on_workspace_changed(_workspaces.current_tab)


## Keep pack management selection-only while activating the exact brush owned by other tabs.
func _on_workspace_changed(tab_index: int) -> void:
	var marker_tab := _workspaces.get_tab_idx_from_control(_marker_scroll)
	var monster_tab := _workspaces.get_tab_idx_from_control(_monster_scroll)
	var placement_enabled := tab_index == marker_tab or tab_index == monster_tab
	placement_enabled_requested.emit(placement_enabled)
	if tab_index == marker_tab:
		emit_current_brush()
	elif tab_index == monster_tab:
		emit_monster_brush()
	else:
		_status_label.text = "Pack management active: drag monsters to reorganize membership."


## Emit the exact visible Markers form as the controller's next-click brush.
func emit_current_brush() -> void:
	var marker_type := current_marker_type()
	if marker_type.is_empty():
		return
	marker_brush_requested.emit(
		marker_type,
		_marker_note_edit.text,
		"",
		""
	)
	_status_label.text = "Marker brush active: %s" % marker_type


## Emit the exact Monsters form as a Solo enemy brush.
func emit_monster_brush() -> void:
	marker_brush_requested.emit(
		GameplayMarker.TYPE_ENEMY,
		_monster_note_edit.text,
		_monster_edit.text,
		""
	)
	_status_label.text = "Monster brush active: %s" % _monster_edit.text


## Load a selected non-enemy marker's exact stored fields.
func _on_marker_selected(_index: int) -> void:
	_load_marker_into_form(selected_marker_id())


## Populate the Markers form from one canonical non-enemy record.
func _load_marker_into_form(marker_id: String) -> void:
	if board == null:
		return
	var marker := board.get_gameplay_marker(marker_id)
	if marker == null or marker.marker_type == GameplayMarker.TYPE_ENEMY:
		return
	for index in _marker_type_option.item_count:
		if String(_marker_type_option.get_item_metadata(index)) == marker.marker_type:
			_marker_type_option.select(index)
			break
	_marker_note_edit.text = marker.note
	_update_action_state()


## Load one reusable monster type into the placement form with a fresh optional note.
func _on_monster_type_selected(_index: int) -> void:
	var monster_id := selected_monster_type_id()
	if monster_id.is_empty():
		return
	_monster_list.deselect_all()
	_monster_edit.text = monster_id
	_monster_note_edit.clear()
	_populate_monster_visual_options()
	_update_action_state()


## Load a selected enemy marker's exact fields into the Monsters form.
func _on_monster_selected(_index: int) -> void:
	_load_monster_into_form(selected_monster_marker_id())


## Populate the Monsters form while leaving pack membership in the Packs workspace.
func _load_monster_into_form(marker_id: String) -> void:
	if board == null:
		return
	var marker := board.get_gameplay_marker(marker_id)
	if marker == null or marker.marker_type != GameplayMarker.TYPE_ENEMY:
		return
	_monster_edit.text = marker.monster_id
	_select_monster_type_list_id(marker.monster_id)
	_monster_note_edit.text = marker.note
	_populate_monster_visual_options()
	_update_action_state()


## Submit an atomic update for the selected non-enemy marker.
func _update_selected_marker() -> void:
	var marker_id := selected_marker_id()
	if marker_id.is_empty():
		show_result({"valid": false, "reason": "select a gameplay marker to update"})
		return
	marker_update_requested.emit(
		marker_id,
		current_marker_type(),
		_marker_note_edit.text,
		"",
		""
	)


## Submit an enemy update while preserving membership owned by the Packs workspace.
func _update_selected_monster() -> void:
	var marker_id := selected_monster_marker_id()
	if marker_id.is_empty() or board == null:
		show_result({"valid": false, "reason": "select a monster placement to update"})
		return
	var marker := board.get_gameplay_marker(marker_id)
	if marker == null:
		show_result({"valid": false, "reason": "selected monster placement no longer exists"})
		return
	marker_update_requested.emit(
		marker_id,
		GameplayMarker.TYPE_ENEMY,
		_monster_note_edit.text,
		_monster_edit.text,
		marker.pack_id
	)


## Request deletion of only the selected non-enemy marker.
func _delete_selected_marker() -> void:
	var marker_id := selected_marker_id()
	if marker_id.is_empty():
		show_result({"valid": false, "reason": "select a gameplay marker to delete"})
		return
	marker_delete_requested.emit(marker_id)


## Request deletion of only the selected monster placement.
func _delete_selected_monster() -> void:
	var marker_id := selected_monster_marker_id()
	if marker_id.is_empty():
		show_result({"valid": false, "reason": "select a monster placement to delete"})
		return
	marker_delete_requested.emit(marker_id)


## Refresh the selected visual size whenever the GLB selector changes.
func _on_monster_visual_selected(index: int) -> void:
	if (
		_monster_visual_size_label == null
		or index < 0
		or index >= _monster_visual_asset_ids.size()
	):
		return
	var asset_id := _monster_visual_asset_ids[index]
	if asset_id.is_empty() or library == null:
		_monster_visual_size_label.text = "No GLB assigned; placements use centered pins."
		_update_action_state()
		return
	var asset := library.get_asset(asset_id)
	if asset == null:
		_monster_visual_size_label.text = "Selected GLB is missing from the library."
		_update_action_state()
		return
	_monster_visual_size_label.text = (
		"Grid box %d x %d x %d m | mesh %.2f x %.2f x %.2f m"
	) % [
		asset.grid_bounds.x,
		asset.grid_bounds.y,
		asset.grid_bounds.z,
		asset.visual_size_m.x,
		asset.visual_size_m.y,
		asset.visual_size_m.z,
	]
	_update_action_state()


## Refresh assignment controls and clear a stale type selection after manual ID edits.
func _on_monster_id_changed(text: String) -> void:
	var selected_type_id := selected_monster_type_id()
	if (
		_monster_type_list != null
		and not selected_type_id.is_empty()
		and selected_type_id != text.strip_edges()
	):
		_monster_type_list.deselect_all()
	_populate_monster_visual_options()
	_update_action_state()


## Assign the selected existing GLB to the exact visible Monster ID.
func _apply_monster_visual() -> void:
	var monster_id := _monster_edit.text
	var selected_index := _monster_visual_option.selected
	if selected_index <= 0 or selected_index >= _monster_visual_asset_ids.size():
		show_result({"valid": false, "reason": "select a GLB visual to apply"})
		return
	monster_visual_assign_requested.emit(
		monster_id,
		_monster_visual_asset_ids[selected_index]
	)


## Request a contextual GLB import whose sizing dialog will bind back to this Monster ID.
func _request_monster_glb_import() -> void:
	if _monster_edit.text.strip_edges().is_empty():
		show_result({"valid": false, "reason": "enter a Monster ID before importing a GLB"})
		return
	monster_glb_import_requested.emit(_monster_edit.text)


## Clear only the selected Monster ID's GLB assignment.
func _clear_monster_visual() -> void:
	if _monster_edit.text.strip_edges().is_empty():
		show_result({"valid": false, "reason": "enter or select a Monster ID"})
		return
	monster_visual_clear_requested.emit(_monster_edit.text)


## Load only a real selected pack into the separate pack editor.
func _on_pack_selected(_index: int) -> void:
	if board == null:
		return
	var pack := board.get_enemy_pack(selected_pack_id())
	if pack == null:
		_pack_id_edit.clear()
		_pack_note_edit.clear()
		_update_action_state()
		return
	_pack_id_edit.text = pack.pack_id
	_pack_note_edit.text = pack.note
	_update_action_state()


## Clear pack selection so the compact editor represents one new record.
func _start_new_pack() -> void:
	_pack_list.deselect_all()
	_pack_id_edit.clear()
	_pack_note_edit.clear()
	_update_action_state()
	_pack_id_edit.grab_focus()


## Create a new pack or save the selected pack's note through one primary action.
func _save_pack() -> void:
	var pack_id := selected_pack_id()
	if pack_id.is_empty():
		enemy_pack_create_requested.emit(_pack_id_edit.text, _pack_note_edit.text)
		return
	enemy_pack_update_requested.emit(pack_id, _pack_note_edit.text)


## Build drag data from exactly the selected monster placement rows.
func _get_enemy_drag_data(at_position: Vector2) -> Variant:
	var hovered_index := _enemy_list.get_item_at_position(at_position, true)
	if hovered_index < 0:
		return null
	var selected := _enemy_list.get_selected_items()
	if not selected.has(hovered_index):
		_enemy_list.select(hovered_index)
		selected = _enemy_list.get_selected_items()
	var marker_ids := PackedStringArray()
	for raw_index: int in selected:
		if raw_index >= 0 and raw_index < _enemy_marker_ids.size():
			marker_ids.append(_enemy_marker_ids[raw_index])
	if marker_ids.is_empty():
		return null
	var preview := Label.new()
	preview.text = "Move %d monster%s" % [
		marker_ids.size(),
		"" if marker_ids.size() == 1 else "s",
	]
	_enemy_list.set_drag_preview(preview)
	return {
		"kind": "gameplay_enemy_markers",
		"marker_ids": marker_ids,
	}


## Accept enemy drag data only when the cursor is over a real pack target row.
func _can_drop_enemy_data(at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary):
		return false
	var payload: Dictionary = data
	if String(payload.get("kind", "")) != "gameplay_enemy_markers":
		return false
	if not (payload.get("marker_ids", null) is PackedStringArray):
		return false
	return _pack_list.get_item_at_position(at_position, true) >= 0


## Request one atomic membership change when selected monsters are dropped on a pack.
func _drop_enemy_data(at_position: Vector2, data: Variant) -> void:
	if not _can_drop_enemy_data(at_position, data):
		return
	var target_index := _pack_list.get_item_at_position(at_position, true)
	var payload: Dictionary = data
	var marker_ids: PackedStringArray = payload["marker_ids"]
	_pack_list.select(target_index)
	enemy_pack_assign_requested.emit(marker_ids, _pack_list_ids[target_index])


## Request deletion of the selected pack through the board's membership guard.
func _delete_selected_pack() -> void:
	var pack_id := selected_pack_id()
	if pack_id.is_empty():
		show_result({"valid": false, "reason": "select an enemy pack to delete"})
		return
	enemy_pack_delete_requested.emit(pack_id)


## Preserve one stable non-enemy marker selection after list rebuilding.
func _select_marker_list_id(marker_id: String) -> void:
	var index := _marker_ids.find(marker_id)
	if index < 0:
		return
	_marker_list.select(index)
	_marker_list.ensure_current_is_visible()


## Preserve one stable reusable monster type selection after list rebuilding.
func _select_monster_type_list_id(monster_id: String) -> void:
	var index := _monster_type_ids.find(monster_id)
	if index < 0:
		return
	_monster_type_list.select(index)
	_monster_type_list.ensure_current_is_visible()


## Preserve one stable monster placement selection after list rebuilding.
func _select_monster_marker_list_id(marker_id: String) -> void:
	var index := _monster_marker_ids.find(marker_id)
	if index < 0:
		return
	_monster_list.select(index)
	_monster_list.ensure_current_is_visible()


## Preserve one stable pack-list selection after list rebuilding.
func _select_pack_list_id(pack_id: String) -> void:
	var index := _pack_list_ids.find(pack_id)
	if index < 0:
		return
	_pack_list.select(index)
	_pack_list.ensure_current_is_visible()


## Show actions only while their corresponding scoped record or value is selected.
func _update_action_state() -> void:
	if _marker_actions == null:
		return
	_marker_actions.visible = not selected_marker_id().is_empty()
	_monster_actions.visible = not selected_monster_marker_id().is_empty()

	var pack_selected := not selected_pack_id().is_empty()
	_save_pack_button.text = "Save Changes" if pack_selected else "Create Pack"
	_new_pack_button.visible = pack_selected
	_delete_pack_button.visible = pack_selected
	_pack_id_edit.editable = not pack_selected

	var monster_id := _monster_edit.text.strip_edges()
	var selected_visual_index := _monster_visual_option.selected
	_apply_monster_visual_button.disabled = (
		monster_id.is_empty()
		or selected_visual_index <= 0
		or selected_visual_index >= _monster_visual_asset_ids.size()
	)
	_import_monster_glb_button.disabled = monster_id.is_empty()
	_clear_monster_visual_button.disabled = (
		board == null
		or monster_id.is_empty()
		or board.monster_visual_asset_id(monster_id).is_empty()
	)


## Show one exact board operation result beside the controls that caused it.
func show_result(result: Dictionary) -> void:
	if _status_label == null:
		return
	if bool(result.get("valid", false)):
		if result.has("marker_count"):
			var count := int(result["marker_count"])
			var target := String(result.get("pack", ""))
			var target_text := "Solo" if target.is_empty() else target
			_status_label.text = "Moved %d monster%s to %s." % [
				count,
				"" if count == 1 else "s",
				target_text,
			]
			_status_label.modulate = Color(0.55, 0.95, 0.62)
			return
		if result.has("monster") and result.has("asset"):
			var monster_id := String(result["monster"])
			var asset_id := String(result["asset"])
			_status_label.text = (
				"Cleared GLB for %s." % monster_id
				if asset_id.is_empty()
				else "Assigned %s to %s." % [asset_id, monster_id]
			)
			_status_label.modulate = Color(0.55, 0.95, 0.62)
			select_monster_id(monster_id)
			return
		var record_id := String(result.get("marker", result.get("pack", "")))
		_status_label.text = "Saved %s." % record_id
		_status_label.modulate = Color(0.55, 0.95, 0.62)
		if result.has("marker"):
			select_marker_id(String(result["marker"]))
		return
	_status_label.text = "Rejected: %s" % String(
		result.get("reason", "unknown gameplay operation error")
	)
	_status_label.modulate = Color(1.0, 0.55, 0.48)
