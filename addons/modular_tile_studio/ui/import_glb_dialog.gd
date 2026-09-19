@tool
class_name ImportGLBDialog
extends ConfirmationDialog

## GLB import dialog.
##
## Sizing is GRID-FIRST. The user types whole cells, not metres: set one grid
## dimension and the other two are calculated from the model's own proportions,
## with the resulting real mesh size reported underneath.
##
## Ticking "stretch" unlocks all three axes and makes the mesh fill the integer
## box exactly, at the cost of distorting it.

const K := preload("../utils/mts_constants.gd")
const Canonicalizer := preload("../importers/glb_canonicalizer.gd")

signal import_confirmed(source_path: String, settings: Dictionary)

var _source_path: String = ""
## Optional UI context; the importer ignores it and the plugin binds the finished GLB afterward.
var _assignment_monster_id: String = ""
var _original_size: Vector3 = Vector3.ONE
var _canonicalizer := Canonicalizer.new()

var _id_edit: LineEdit
var _name_edit: LineEdit
var _biome_edit: LineEdit
var _original_label: Label

var _grid_x: SpinBox
var _grid_y: SpinBox
var _grid_z: SpinBox

var _stretch_check: CheckBox
var _optimize_check: CheckBox
var _mesh_target: OptionButton
var _texture_limit: OptionButton

var _actual_label: Label
var _fit_label: Label
var _optimization_label: Label
var _source_info: Dictionary = {}


## Which axis the user last touched. That axis is exact; the others follow.
var _driver_axis: int = 1
var _updating: bool = false


## Build the bounded grid-first import form and its explicit optimization controls.
func _ready() -> void:
	title = "Import GLB Prop"
	ok_button_text = "Import"
	# Bounded, not just a minimum: ConfirmationDialog lays its buttons out below
	# the content, so content taller than the screen pushes Import/Cancel off the
	# bottom edge where they cannot be clicked. The fields live in a scroll
	# container instead, keeping the buttons always reachable.
	min_size = Vector2i(520, 420)
	max_size = Vector2i(900, 760)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(500, 380)
	add_child(scroll)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(root)

	var grid := GridContainer.new()
	grid.columns = 2
	root.add_child(grid)

	_id_edit = _add_field(grid, "Asset ID", LineEdit.new()) as LineEdit
	_name_edit = _add_field(grid, "Display Name", LineEdit.new()) as LineEdit
	# No category field: every GLB import lands in the one fixed "GLB Props"
	# category, so there is nothing to type and nothing to get wrong.
	_biome_edit = _add_field(grid, "Biome", LineEdit.new()) as LineEdit

	root.add_child(HSeparator.new())

	var original_title := Label.new()
	original_title.text = "ORIGINAL SIZE"
	root.add_child(original_title)
	_original_label = Label.new()
	_original_label.text = "X: -   Y: -   Z: -"
	root.add_child(_original_label)

	root.add_child(HSeparator.new())

	var title_label := Label.new()
	title_label.text = "GRID SIZE (metres / cells)"
	title_label.tooltip_text = "Set one axis and the other two are calculated from the model's own proportions."
	root.add_child(title_label)

	var sizing := GridContainer.new()
	sizing.columns = 2
	root.add_child(sizing)

	_grid_x = SpinBox.new()
	_grid_x.min_value = 1
	_grid_x.max_value = 128
	_grid_x.step = 1
	_add_field(sizing, "X", _grid_x)

	_grid_y = SpinBox.new()
	_grid_y.min_value = 1
	_grid_y.max_value = 128
	_grid_y.step = 1
	_add_field(sizing, "Y", _grid_y)

	_grid_z = SpinBox.new()
	_grid_z.min_value = 1
	_grid_z.max_value = 128
	_grid_z.step = 1
	_add_field(sizing, "Z", _grid_z)

	_grid_x.value_changed.connect(func(_v: float) -> void: _recalculate(0))
	_grid_y.value_changed.connect(func(_v: float) -> void: _recalculate(1))
	_grid_z.value_changed.connect(func(_v: float) -> void: _recalculate(2))

	_stretch_check = CheckBox.new()
	_stretch_check.text = "Stretch mesh exactly to grid box"
	_stretch_check.tooltip_text = (
		"Off: one grid axis drives proportional scale; "
		+ "the other grid dimensions are calculated automatically.\n"
		+ "On: X/Y/Z are independent and the mesh is stretched "
		+ "to exactly fill the integer grid box."
	)
	_stretch_check.toggled.connect(func(_pressed: bool) -> void: _recalculate(_driver_axis))
	root.add_child(_stretch_check)

	_actual_label = Label.new()
	_actual_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_actual_label)

	_fit_label = Label.new()
	_fit_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fit_label.add_theme_font_size_override("font_size", 10)
	root.add_child(_fit_label)

	root.add_child(HSeparator.new())

	var optimization_title := Label.new()
	optimization_title.text = "RUNTIME ASSET"
	root.add_child(optimization_title)

	_optimize_check = CheckBox.new()
	_optimize_check.text = "Optimize mesh"
	_optimize_check.tooltip_text = "Generate a validated runtime GLB from the untouched source using Godot's native mesh LOD optimizer."
	root.add_child(_optimize_check)

	var options_grid := GridContainer.new()
	options_grid.columns = 2
	root.add_child(options_grid)

	_mesh_target = OptionButton.new()
	_mesh_target.add_item("50% base triangles")
	_mesh_target.set_item_metadata(0, 0.5)
	_mesh_target.add_item("25% base triangles")
	_mesh_target.set_item_metadata(1, 0.25)
	_mesh_target.add_item("12.5% base triangles")
	_mesh_target.set_item_metadata(2, 0.125)
	_mesh_target.select(2)
	_add_field(options_grid, "Mesh target", _mesh_target)

	_texture_limit = OptionButton.new()
	_texture_limit.add_item("Original", 0)
	_texture_limit.add_item("4096", 4096)
	_texture_limit.add_item("2048", 2048)
	_texture_limit.select(2)
	_add_field(options_grid, "Texture maximum", _texture_limit)

	_optimization_label = Label.new()
	_optimization_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_optimization_label.add_theme_font_size_override("font_size", 10)
	root.add_child(_optimization_label)

	_optimize_check.toggled.connect(func(_enabled: bool) -> void: _update_optimization_estimate())
	_mesh_target.item_selected.connect(func(_index: int) -> void: _update_optimization_estimate())
	_texture_limit.item_selected.connect(func(_index: int) -> void: _update_optimization_estimate())

	var note := Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 10)
	note.text = "The source GLB is copied unchanged in canonical Y-up orientation. When optimization is enabled, rendering uses a separately validated runtime GLB; collision voxels still derive from the untouched source. Rotate or flip placement with the editor controls."
	root.add_child(note)

	confirmed.connect(_on_confirmed)


## Add one aligned label/control pair to a two-column options grid.
func _add_field(grid: GridContainer, label_text: String, control: Control) -> Control:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)
	return control


## Prepare the grid-first import form for a prop or one contextual Monster ID.
func setup(
	source_path: String,
	suggested_id: String,
	info: Dictionary,
	assignment_monster_id: String = ""
) -> void:
	_source_path = source_path
	_source_info = info.duplicate(true)
	_assignment_monster_id = assignment_monster_id
	_id_edit.text = suggested_id
	_name_edit.text = source_path.get_file().get_basename().capitalize()

	_original_size = info.get("size", Vector3.ONE)
	_original_label.text = "X: %.3f m    Y: %.3f m    Z: %.3f m" % [
		_original_size.x, _original_size.y, _original_size.z
	]

	var suggested := _canonicalizer.suggest_grid_bounds(_original_size)

	_updating = true
	_grid_x.value = suggested.x
	_grid_y.value = suggested.y
	_grid_z.value = suggested.z
	_updating = false

	# Height is the dimension people actually think in for a prop.
	_driver_axis = 1
	_stretch_check.button_pressed = false
	_optimize_check.button_pressed = false
	_mesh_target.select(2)
	_texture_limit.select(2)

	_recalculate(_driver_axis)
	_update_optimization_estimate()


## Recompute the derived dimensions.
##
## `edited_axis` names the axis the user typed in, so proportional mode scales
## from that axis rather than fighting whichever field was touched last.
func _recalculate(edited_axis: int) -> void:
	if _updating:
		return

	_driver_axis = clampi(edited_axis, 0, 2)

	var requested := Vector3i(
		int(_grid_x.value),
		int(_grid_y.value),
		int(_grid_z.value)
	)

	var plan := _canonicalizer.compute_grid_plan(
		_original_size,
		requested,
		_driver_axis,
		_stretch_check.button_pressed
	)

	var calculated_grid: Vector3i = plan["grid_size"]
	var actual: Vector3 = plan["actual_size"]

	# Reflect the calculated cells back into the fields the user did not type in.
	if not _stretch_check.button_pressed:
		_updating = true
		_grid_x.value = calculated_grid.x
		_grid_y.value = calculated_grid.y
		_grid_z.value = calculated_grid.z
		_updating = false

	_actual_label.text = (
		"Grid box: %d x %d x %d m\nActual mesh: %.3f x %.3f x %.3f m"
	) % [
		calculated_grid.x, calculated_grid.y, calculated_grid.z,
		actual.x, actual.y, actual.z,
	]

	var slack := Vector3(
		float(calculated_grid.x) - actual.x,
		float(calculated_grid.y) - actual.y,
		float(calculated_grid.z) - actual.z
	)

	if _stretch_check.button_pressed:
		_fit_label.modulate = Color(0.8, 0.8, 0.6)
		_fit_label.text = "Exact stretch: mesh fills the whole grid box, distorting its proportions."
	else:
		var worst := maxf(slack.x, maxf(slack.y, slack.z))
		_fit_label.modulate = (
			Color(0.55, 0.85, 0.6) if worst < 0.35
			else Color(0.8, 0.8, 0.6) if worst < 0.7
			else Color(1.0, 0.75, 0.4)
		)
		_fit_label.text = (
			"Unused box space: %.3f m X, %.3f m Y, %.3f m Z. "
			+ "Mesh is centred in X/Z and sits on Y=0."
		) % [slack.x, slack.y, slack.z]


## Show source costs and the deterministic target selected for the derived GLB.
func _update_optimization_estimate() -> void:
	if _optimization_label == null:
		return
	_mesh_target.disabled = not _optimize_check.button_pressed
	_texture_limit.disabled = not _optimize_check.button_pressed
	var triangles := int(_source_info.get("triangles", 0))
	var vertices := int(_source_info.get("vertices", 0))
	var textures := int(_source_info.get("textures", 0))
	var maximum_texture := int(_source_info.get("texture_max_dimension", 0))
	var supported := bool(_source_info.get("supported", true))
	if not supported:
		_optimization_label.modulate = Color(1.0, 0.55, 0.45)
		_optimization_label.text = "Optimization unavailable: %s" % String(
			_source_info.get("unsupported_reason", "unsupported source content")
		)
		_optimize_check.disabled = true
		return
	_optimize_check.disabled = false
	_optimization_label.modulate = Color(0.65, 0.72, 0.82)
	if not _optimize_check.button_pressed:
		_optimization_label.text = (
			"Source rendering: %s triangles, %s vertices, %d textures, maximum %d px."
			% [_grouped(triangles), _grouped(vertices), textures, maximum_texture]
		)
		return
	var ratio := float(_mesh_target.get_selected_metadata())
	var texture_cap := _texture_limit.get_selected_id()
	var texture_text := "original size" if texture_cap == 0 else "%d px maximum" % texture_cap
	_optimization_label.text = (
		"Source: %s triangles, %s vertices. Expected base target: about %s triangles; "
		+ "%d embedded textures at %s. Exact measured output appears in the Asset Inspector after validation."
	) % [
		_grouped(triangles),
		_grouped(vertices),
		_grouped(roundi(float(triangles) * ratio)),
		textures,
		texture_text,
	]


## Add thousands separators so large mesh statistics remain readable.
func _grouped(value: int) -> String:
	var digits := str(absi(value))
	var output := ""
	var count := 0
	for index in range(digits.length() - 1, -1, -1):
		output = digits[index] + output
		count += 1
		if count % 3 == 0 and index > 0:
			output = "," + output
	return ("-" if value < 0 else "") + output


## Emit one import request and preserve optional Monster-ID assignment context.
func _on_confirmed() -> void:
	var settings := {
		"asset_id": _id_edit.text,
		"display_name": _name_edit.text,
		"biome": _biome_edit.text,
		"grid_size": Vector3i(
			int(_grid_x.value),
			int(_grid_y.value),
			int(_grid_z.value)
		),
		"driver_axis": _driver_axis,
		"stretch_to_grid": _stretch_check.button_pressed,
		"optimize_mesh": _optimize_check.button_pressed,
		"mesh_target_ratio": float(_mesh_target.get_selected_metadata()),
		"max_texture_size": _texture_limit.get_selected_id(),
	}
	if not _assignment_monster_id.is_empty():
		settings["_monster_visual_id"] = _assignment_monster_id
	import_confirmed.emit(_source_path, settings)
