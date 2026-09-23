@tool
class_name MovementGridPanel
extends VBoxContainer

## Board-wide movement-grid controls and compact editing feedback.
##
## The panel owns no duplicate state: its controls stage values, while the
## BoardDocument remains the sole saved source for collision, walkability, and labels.

signal collision_threshold_apply_requested(threshold_percent: float)
signal collision_measurement_requested()
signal editing_tool_changed(tool: int)
signal ground_effect_label_changed(label: String)

enum EditingTool {
	BLOCK = 0,
	RESTORE_AUTO = 1,
	SET_EFFECT = 2,
	CLEAR_EFFECT = 3,
}

var _board: BoardDocument
var _threshold_spin: SpinBox
var _threshold_preview: Label
var _tool_option: OptionButton
var _effect_label: LineEdit
var _summary_label: Label
var _feedback_label: Label


## Build the panel controls once it enters the editor tree.
func _ready() -> void:
	_build_controls()
	_refresh_from_board()


## Bind the panel directly to the board whose values it edits and previews.
func bind(board: BoardDocument) -> void:
	if _board != null and _board.board_changed.is_connected(_on_board_changed):
		_board.board_changed.disconnect(_on_board_changed)
	_board = board
	if _board != null and not _board.board_changed.is_connected(_on_board_changed):
		_board.board_changed.connect(_on_board_changed)
	_refresh_from_board()


## Return the currently selected cell-editing action for viewport synchronization.
func editing_tool() -> int:
	if _tool_option == null:
		return EditingTool.BLOCK
	return _tool_option.get_selected_id()


## Return the staged ground-effect label exactly as the viewport should author it.
func ground_effect_label() -> String:
	if _effect_label == null:
		return ""
	return _effect_label.text.strip_edges()


## Show the result of previewing or applying the board-wide collision threshold.
func show_collision_result(report: Dictionary) -> void:
	if _threshold_preview == null:
		return
	var raw_count := int(report.get("raw_voxel_count", 0))
	var active_count := int(report.get("active_voxel_count", 0))
	var removed_count := int(report.get("removed_voxel_count", 0))
	if bool(report.get("valid", false)):
		_threshold_preview.text = (
			"%d raw voxels -> %d active (%d ignored), across %d instances."
			% [
				raw_count,
				active_count,
				removed_count,
				int(report.get("placed_instance_count", 0)),
			]
		)
		return
	var missing: PackedStringArray = report.get(
		"missing_measurement_asset_ids",
		PackedStringArray()
	)
	if not missing.is_empty():
		_threshold_preview.text = (
			"Cannot apply: %d placed GLB assets need triangle-share measurement. "
			+ "Click Measure Placed GLBs."
		) % missing.size()
		return
	var errors: PackedStringArray = report.get("errors", PackedStringArray())
	_threshold_preview.text = (
		"Cannot apply: %s" % errors[0]
		if not errors.is_empty()
		else "Cannot apply this collision threshold."
	)


## Show the last authored cell and its complete saved movement state.
func show_cell_feedback(cell: Vector2i, state: Dictionary) -> void:
	if _feedback_label == null:
		return
	var pieces: PackedStringArray = PackedStringArray()
	pieces.append("unwalkable" if bool(state.get("unwalkable", false)) else "automatic walkability")
	var effect := String(state.get("ground_effect", ""))
	if not effect.is_empty():
		pieces.append("effect: %s" % effect)
	_feedback_label.text = "Cell (%d, %d): %s." % [cell.x, cell.y, ", ".join(pieces)]


## Construct the global collision and cell-authoring controls in visible order.
func _build_controls() -> void:
	add_theme_constant_override("separation", 10)

	var title := Label.new()
	title.text = "Movement Grid"
	title.add_theme_font_size_override("font_size", 18)
	add_child(title)

	var collision_heading := Label.new()
	collision_heading.text = "Global GLB Collision Filter"
	collision_heading.add_theme_font_size_override("font_size", 15)
	add_child(collision_heading)

	var collision_help := Label.new()
	collision_help.text = (
		"Ignore a collision voxel when it contains less than this share of the "
		+ "asset's mesh triangles. This applies to every placed GLB and instance."
	)
	collision_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(collision_help)

	var threshold_row := HBoxContainer.new()
	add_child(threshold_row)
	var threshold_label := Label.new()
	threshold_label.text = "Minimum mesh share (%)"
	threshold_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	threshold_row.add_child(threshold_label)
	_threshold_spin = SpinBox.new()
	_threshold_spin.min_value = 0.0
	_threshold_spin.max_value = 100.0
	_threshold_spin.step = 0.001
	_threshold_spin.allow_greater = false
	_threshold_spin.custom_arrow_step = 0.01
	_threshold_spin.value_changed.connect(_on_threshold_staged)
	threshold_row.add_child(_threshold_spin)

	_threshold_preview = Label.new()
	_threshold_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_threshold_preview)

	var collision_buttons := HBoxContainer.new()
	add_child(collision_buttons)
	var apply_button := Button.new()
	apply_button.text = "Apply Global Filter"
	apply_button.pressed.connect(_on_apply_collision_pressed)
	collision_buttons.add_child(apply_button)
	var measure_button := Button.new()
	measure_button.text = "Measure Placed GLBs"
	measure_button.tooltip_text = (
		"Explicitly scan placed legacy GLBs that do not yet store per-voxel triangle shares."
	)
	measure_button.pressed.connect(_on_measure_collision_pressed)
	collision_buttons.add_child(measure_button)

	add_child(HSeparator.new())
	var editing_heading := Label.new()
	editing_heading.text = "Paint Movement Cells"
	editing_heading.add_theme_font_size_override("font_size", 15)
	add_child(editing_heading)

	_tool_option = OptionButton.new()
	_tool_option.add_item("Make Unwalkable", EditingTool.BLOCK)
	_tool_option.add_item("Restore Automatic Walkability", EditingTool.RESTORE_AUTO)
	_tool_option.add_item("Set Ground Effect Label", EditingTool.SET_EFFECT)
	_tool_option.add_item("Clear Ground Effect Label", EditingTool.CLEAR_EFFECT)
	_tool_option.item_selected.connect(_on_tool_selected)
	add_child(_tool_option)

	_effect_label = LineEdit.new()
	_effect_label.placeholder_text = "Ground effect label, e.g. fire hazard or wet ground"
	_effect_label.max_length = BoardDocument.MOVEMENT_GROUND_EFFECT_LABEL_MAX_LENGTH
	_effect_label.text_changed.connect(_on_effect_label_changed)
	add_child(_effect_label)

	var editing_help := Label.new()
	editing_help.text = (
		"Left-click a terrain cell to apply the selected action. Orange cells are "
		+ "blocked by GLB collision, red cells are manually unwalkable, cyan cells "
		+ "have a label, and green cells remain open."
	)
	editing_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(editing_help)

	_feedback_label = Label.new()
	_feedback_label.text = "Hover or click a terrain cell to inspect it."
	_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_feedback_label)

	_summary_label = Label.new()
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_summary_label)
	_on_tool_selected(0)


## Refresh visible controls whenever canonical board state changes.
func _on_board_changed() -> void:
	_refresh_from_board()


## Refresh stored values and board-wide counts without changing staged text.
func _refresh_from_board() -> void:
	if not is_node_ready() or _threshold_spin == null:
		return
	if _board == null:
		_threshold_spin.value = 0.0
		_threshold_preview.text = "No board is bound."
		_summary_label.text = ""
		return
	_threshold_spin.set_value_no_signal(
		_board.movement_collision_min_triangle_share_percent
	)
	show_collision_result(_board.movement_collision_filter_report())
	_summary_label.text = (
		"%d manually unwalkable cells; %d labeled ground-effect cells."
		% [
			_board.movement_unwalkable_cells.size(),
			_board.movement_ground_effects.size(),
		]
	)


## Preview a staged threshold without mutating board collision.
func _on_threshold_staged(value: float) -> void:
	if _board == null:
		return
	show_collision_result(_board.movement_collision_filter_report(value))


## Ask the viewport to atomically commit the staged global threshold.
func _on_apply_collision_pressed() -> void:
	collision_threshold_apply_requested.emit(float(_threshold_spin.value))


## Request explicit measurement of any placed legacy GLBs that lack triangle shares.
func _on_measure_collision_pressed() -> void:
	collision_measurement_requested.emit()


## Synchronize the active viewport action and label-field availability.
func _on_tool_selected(index: int) -> void:
	var tool := _tool_option.get_item_id(index)
	_effect_label.editable = tool == EditingTool.SET_EFFECT
	editing_tool_changed.emit(tool)


## Send the staged descriptive label to the viewport as the user types.
func _on_effect_label_changed(value: String) -> void:
	ground_effect_label_changed.emit(value.strip_edges())
