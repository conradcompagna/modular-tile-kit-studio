@tool
class_name ParticleEffectsPanel
extends ScrollContainer

## Provides a small custom-preset editor and placement mode for PNG-driven particle emitters.

signal preset_selected(preset_id: String)
signal authoring_mode_changed(enabled: bool, erase_mode: bool)
signal preset_changed(preset_id: String)
signal status_message(message: String)
## Emitted with a ParticleEffectPlacement.Attachment value for newly placed effects.
signal attachment_changed(attachment: int)

var board: BoardDocument
var library: ParticleEffectLibrary

var _root: VBoxContainer
var _selector: OptionButton
var _editor: VBoxContainer
var _mode: OptionButton
## Selects how newly placed emitters resolve their height against the terrain.
var _attachment: OptionButton
var _placement_count: Label
var _file_dialog: FileDialog
var _selected_id: String = ""
var _dirty: bool = false
var _refreshing: bool = false


## Build the persistent panel shell and PNG file picker.
func _ready() -> void:
	custom_minimum_size = Vector2(300, 0)
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root = VBoxContainer.new()
	_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_root)

	var title := Label.new()
	title.text = "CUSTOM PARTICLE EFFECTS"
	title.add_theme_font_size_override("font_size", 15)
	_root.add_child(title)

	var note := Label.new()
	note.text = "Import a transparent PNG, tune its native GPUParticles3D values, then place the emitter volume on the active grid layer."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.modulate = Color(0.68, 0.72, 0.78)
	_root.add_child(note)

	var import_button := Button.new()
	import_button.text = "New Preset from PNG…"
	import_button.pressed.connect(_open_png_dialog)
	_root.add_child(import_button)

	_selector = OptionButton.new()
	_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_selector.item_selected.connect(_on_preset_selected)
	_root.add_child(_selector)

	_mode = OptionButton.new()
	_mode.add_item("Place emitters", 0)
	_mode.add_item("Erase emitters", 1)
	_mode.item_selected.connect(func(index: int) -> void:
		authoring_mode_changed.emit(true, _mode.get_item_id(index) == 1))
	_root.add_child(_mode)

	# Attachment decides whether sculpting the ground carries the effect with it,
	# so it is an authored choice made before placing rather than a hidden default.
	_attachment = OptionButton.new()
	_attachment.add_item("Attach to terrain", ParticleEffectPlacement.Attachment.TERRAIN)
	_attachment.add_item("Free in world", ParticleEffectPlacement.Attachment.WORLD)
	_attachment.tooltip_text = (
		"Terrain-attached emitters follow the heightfield when it is sculpted."
		+ " World emitters keep the exact height they were placed at."
	)
	_attachment.item_selected.connect(func(index: int) -> void:
		attachment_changed.emit(_attachment.get_item_id(index)))
	_root.add_child(_attachment)

	_placement_count = Label.new()
	_placement_count.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_root.add_child(_placement_count)

	_editor = VBoxContainer.new()
	_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(_editor)

	_file_dialog = FileDialog.new()
	_file_dialog.title = "Choose Particle PNG"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = PackedStringArray(["*.png ; PNG Images"])
	_file_dialog.file_selected.connect(_import_png)
	add_child(_file_dialog)
	rebuild()


## Bind the current board and reusable project particle library, then display their authoritative state.
func bind(p_board: BoardDocument, p_library: ParticleEffectLibrary) -> void:
	if board != null and board.board_changed.is_connected(refresh_board_state):
		board.board_changed.disconnect(refresh_board_state)
	board = p_board
	library = p_library
	if board != null and not board.board_changed.is_connected(refresh_board_state):
		board.board_changed.connect(refresh_board_state)
	rebuild()


## Rebuild the preset selector, placement count, and current preset editor.
func rebuild() -> void:
	if _selector == null:
		return
	_refreshing = true
	_selector.clear()
	if library != null:
		for preset: ParticleEffectPreset in library.presets:
			if preset == null:
				continue
			_selector.add_item(preset.display_name)
			_selector.set_item_metadata(_selector.item_count - 1, preset.preset_id)
	if _selector.item_count > 0:
		var selected_index := 0
		for index in _selector.item_count:
			if String(_selector.get_item_metadata(index)) == _selected_id:
				selected_index = index
				break
		_selector.select(selected_index)
		_selected_id = String(_selector.get_item_metadata(selected_index))
	else:
		_selected_id = ""
	_refreshing = false
	_refresh_placement_count()
	_rebuild_editor()
	preset_selected.emit(_selected_id)
	authoring_mode_changed.emit(true, _mode != null and _mode.get_selected_id() == 1)


## Refresh board-dependent placement information without rebuilding preset controls.
func refresh_board_state() -> void:
	_refresh_placement_count()


## Open the filesystem picker used to copy one PNG into the project library.
func _open_png_dialog() -> void:
	_file_dialog.popup_centered_ratio(0.72)


## Import one PNG as a neutral custom preset without inventing an effect style.
func _import_png(path: String) -> void:
	if library == null:
		status_message.emit("Particle library is not available.")
		return
	var preset := library.import_png(path)
	if preset == null:
		status_message.emit("Particle PNG import failed; see the Godot error log.")
		return
	_selected_id = preset.preset_id
	_dirty = false
	rebuild()
	status_message.emit("Imported particle preset '%s'." % preset.display_name)


## Select the reusable preset represented by one selector row.
func _on_preset_selected(index: int) -> void:
	if _refreshing or index < 0 or index >= _selector.item_count:
		return
	_selected_id = String(_selector.get_item_metadata(index))
	_dirty = false
	_rebuild_editor()
	preset_selected.emit(_selected_id)


## Rebuild all simulation controls for the exact selected preset.
func _rebuild_editor() -> void:
	for child in _editor.get_children():
		child.queue_free()
	var preset := _selected_preset()
	if preset == null:
		_note("Import a PNG to create your first reusable particle preset.")
		return

	_heading("PRESET")
	var id_label := Label.new()
	id_label.text = "ID: %s" % preset.preset_id
	id_label.selectable = true
	_editor.add_child(id_label)
	_text("Name", preset.display_name, func(value: String) -> void:
		preset.display_name = value
		if _selector.selected >= 0:
			_selector.set_item_text(_selector.selected, value)
		_mark_dirty())
	var texture_label := Label.new()
	texture_label.text = "PNG: %s" % preset.texture_path
	texture_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	texture_label.selectable = true
	_editor.add_child(texture_label)

	_heading("EMISSION")
	_spin("Amount", 1.0, 100000.0, 1.0, preset.amount, func(value: float) -> void:
		preset.amount = int(value)
		_mark_dirty())
	_spin("Lifetime (s)", 0.01, 120.0, 0.01, preset.lifetime_seconds, func(value: float) -> void:
		preset.lifetime_seconds = value
		_mark_dirty())
	_spin("Explosiveness", 0.0, 1.0, 0.01, preset.explosiveness, func(value: float) -> void:
		preset.explosiveness = value
		_mark_dirty())
	_spin("Emission randomness", 0.0, 1.0, 0.01, preset.emission_randomness, func(value: float) -> void:
		preset.emission_randomness = value
		_mark_dirty())
	_toggle("One shot", preset.one_shot, func(value: bool) -> void:
		preset.one_shot = value
		_mark_dirty())
	_spin("Fixed seed", 0.0, 2147483647.0, 1.0, preset.fixed_seed, func(value: float) -> void:
		preset.fixed_seed = int(value)
		_mark_dirty())
	_vector3("Emitter box (m)", preset.emission_box_size_m, 0.01, 256.0, 0.01, func(value: Vector3) -> void:
		preset.emission_box_size_m = value
		_mark_dirty())

	_heading("MOTION")
	_vector3("Direction", preset.direction, -1.0, 1.0, 0.01, func(value: Vector3) -> void:
		preset.direction = value
		_mark_dirty())
	_spin("Spread (degrees)", 0.0, 180.0, 0.1, preset.spread_degrees, func(value: float) -> void:
		preset.spread_degrees = value
		_mark_dirty())
	_spin("Velocity min", 0.0, 256.0, 0.01, preset.initial_velocity_min, func(value: float) -> void:
		preset.initial_velocity_min = value
		_mark_dirty())
	_spin("Velocity max", 0.0, 256.0, 0.01, preset.initial_velocity_max, func(value: float) -> void:
		preset.initial_velocity_max = value
		_mark_dirty())
	_vector3("Gravity", preset.gravity, -256.0, 256.0, 0.01, func(value: Vector3) -> void:
		preset.gravity = value
		_mark_dirty())
	_spin("Angular velocity min", -720.0, 720.0, 0.1, preset.angular_velocity_min, func(value: float) -> void:
		preset.angular_velocity_min = value
		_mark_dirty())
	_spin("Angular velocity max", -720.0, 720.0, 0.1, preset.angular_velocity_max, func(value: float) -> void:
		preset.angular_velocity_max = value
		_mark_dirty())

	_heading("APPEARANCE")
	_spin("Size min (m)", 0.001, 64.0, 0.001, preset.particle_size_min_m, func(value: float) -> void:
		preset.particle_size_min_m = value
		_mark_dirty())
	_spin("Size max (m)", 0.001, 64.0, 0.001, preset.particle_size_max_m, func(value: float) -> void:
		preset.particle_size_max_m = value
		_mark_dirty())
	_color("Tint", preset.tint, func(value: Color) -> void:
		preset.tint = value
		_mark_dirty())
	_spin("Fade in fraction", 0.01, 0.49, 0.01, preset.fade_in_fraction, func(value: float) -> void:
		preset.fade_in_fraction = value
		_mark_dirty())
	_spin("Fade out fraction", 0.01, 0.49, 0.01, preset.fade_out_fraction, func(value: float) -> void:
		preset.fade_out_fraction = value
		_mark_dirty())
	_spin("Emission energy", 0.0, 32.0, 0.01, preset.emission_energy, func(value: float) -> void:
		preset.emission_energy = value
		_mark_dirty())

	var save_button := Button.new()
	save_button.text = "Save Preset" if _dirty else "Preset Saved"
	save_button.disabled = not _dirty
	save_button.pressed.connect(_save_selected)
	_editor.add_child(save_button)
	_note("Left click uses the current mode; right click always erases the nearest emitter in the cell.")


## Return the exact currently selected library resource.
func _selected_preset() -> ParticleEffectPreset:
	return library.preset_by_id(_selected_id) if library != null else null


## Mark in-memory settings dirty, rebuild live emitters, and leave disk mutation behind the explicit Save button.
func _mark_dirty() -> void:
	if _refreshing:
		return
	_dirty = true
	preset_changed.emit(_selected_id)
	var last := _editor.get_child(_editor.get_child_count() - 2) if _editor.get_child_count() >= 2 else null
	if last is Button:
		(last as Button).text = "Save Preset"
		(last as Button).disabled = false


## Persist the selected preset library after validating required ranges.
func _save_selected() -> void:
	var preset := _selected_preset()
	if preset == null:
		return
	if not preset.is_valid():
		status_message.emit("Preset is incomplete: check PNG, size, velocity, and emitter dimensions.")
		return
	if library.save_library():
		_dirty = false
		_rebuild_editor()
		status_message.emit("Saved particle preset '%s'." % preset.display_name)


## Update the visible count of current-board emitter placements.
func _refresh_placement_count() -> void:
	if _placement_count == null:
		return
	if board == null:
		_placement_count.text = "No board bound."
		return
	_placement_count.text = "%d emitter placement%s on this board." % [
		board.particle_effects.size(),
		"" if board.particle_effects.size() == 1 else "s",
	]


## Add one compact section heading to the preset editor.
func _heading(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.modulate = Color(0.82, 0.86, 0.92)
	_editor.add_child(label)


## Add one wrapped explanatory note to the preset editor.
func _note(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 10)
	label.modulate = Color(0.62, 0.67, 0.74)
	_editor.add_child(label)


## Add one labelled text field and forward committed text to its exact resource value.
func _text(label_text: String, value: String, changed: Callable) -> LineEdit:
	var row := _row(label_text)
	var edit := LineEdit.new()
	edit.text = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_submitted.connect(func(next: String) -> void: changed.call(next))
	edit.focus_exited.connect(func() -> void: changed.call(edit.text))
	row.add_child(edit)
	return edit


## Add one labelled numeric field with the authored range shown directly by SpinBox.
func _spin(
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	changed: Callable
) -> SpinBox:
	var row := _row(label_text)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(func(next: float) -> void: changed.call(next))
	row.add_child(spin)
	return spin


## Add one labelled three-axis value whose three visible components form the consumed Vector3.
func _vector3(
	label_text: String,
	value: Vector3,
	minimum: float,
	maximum: float,
	step: float,
	changed: Callable
) -> HBoxContainer:
	var row := _row(label_text)
	var fields: Array[SpinBox] = []
	for component in 3:
		var spin := SpinBox.new()
		spin.min_value = minimum
		spin.max_value = maximum
		spin.step = step
		spin.value = value[component]
		spin.custom_minimum_size = Vector2(64, 0)
		fields.append(spin)
		row.add_child(spin)
	var commit := func(_next: float) -> void:
		changed.call(Vector3(fields[0].value, fields[1].value, fields[2].value))
	for spin: SpinBox in fields:
		spin.value_changed.connect(commit)
	return row


## Add one labelled boolean control.
func _toggle(label_text: String, value: bool, changed: Callable) -> CheckBox:
	var row := _row(label_text)
	var control := CheckBox.new()
	control.button_pressed = value
	control.toggled.connect(func(next: bool) -> void: changed.call(next))
	row.add_child(control)
	return control


## Add one labelled colour control.
func _color(label_text: String, value: Color, changed: Callable) -> ColorPickerButton:
	var row := _row(label_text)
	var control := ColorPickerButton.new()
	control.color = value
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.color_changed.connect(func(next: Color) -> void: changed.call(next))
	row.add_child(control)
	return control


## Create the common two-column row used by every particle preset field.
func _row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(132, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	_editor.add_child(row)
	return row
