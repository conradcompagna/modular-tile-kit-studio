@tool
class_name LookPanelBase
extends VBoxContainer

## Shared machinery for the two look panels (Aesthetics and Lighting).
##
## Both panels edit a profile that lives on the BoardDocument, both are built
## from the field tables the profiles declare, and both need the same
## slider-with-exact-value row ported from the Blackledger lighting dock. That
## common part lives here so the two panels stay genuinely independent windows
## without duplicating their controls.
##
## Subclasses implement rebuild() and call _changed() when a knob moves.

const LABEL_WIDTH: int = 148
const VALUE_WIDTH: int = 66

signal look_changed()

var board: BoardDocument

var _status: Label
var _body: VBoxContainer

## Rebuilding is how these panels refresh: at this control count it is instant,
## and it removes the entire class of bug where a slider keeps showing a value
## the profile no longer holds.
var _refreshing: bool = false


func _ready() -> void:
	_build_chrome()
	rebuild()


## Build the scroll column and status line.
##
## Called from _ready(), but also from bind() when a caller binds a board before
## the node has entered the tree -- which is the normal path, since the plugin
## hands the panel its document immediately after constructing it. Guarded so it
## only ever runs once.
func _build_chrome() -> void:
	if _body != null:
		return
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)

	# A scroll column, because the lighting panel with eight lights is taller
	# than any dock: controls that cannot be reached are no better than absent.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 5)
	scroll.add_child(_body)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color(0.62, 0.70, 0.86))
	add_child(_status)


func bind(p_board: BoardDocument) -> void:
	board = p_board
	_build_chrome()
	rebuild()


## Implemented by each panel.
func rebuild() -> void:
	pass


func _clear_body() -> void:
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()


## One change notification for every knob. Emitting on the document rather than
## calling the viewport directly keeps these panels pure editors of data.
func _changed() -> void:
	if _refreshing or board == null:
		return
	board.notify_look_changed()
	_update_status()
	look_changed.emit()


func _update_status() -> void:
	pass


# --- Generic field building -----------------------------------------------

## Build every control a profile declares for one section.
##
## The profiles own their field tables, so a knob added there appears here
## automatically and is covered by reset without a second edit.
func _profile_fields(
	parent: VBoxContainer,
	profile: Resource,
	section: String,
	fields: Array,
	color_fields: Array,
	toggle_fields: Array
) -> void:
	for definition: Array in toggle_fields:
		if String(definition[2]) != section:
			continue
		var toggle_key := String(definition[0])
		_toggle(parent, String(definition[1]), bool(profile.get(toggle_key)), String(definition[3]),
			func(value: bool) -> void:
				profile.set(toggle_key, value)
				_changed())

	for definition: Array in fields:
		if String(definition[5]) != section:
			continue
		var key := String(definition[0])
		# Field tables carry numeric Variants. Passing them into _slider's typed
		# float parameters performs Godot's normal numeric conversion without
		# trying to invoke a nonexistent runtime float constructor in @tool UI.
		_slider(parent, String(definition[1]), definition[2], definition[3],
			definition[4], profile.get(key), String(definition[6]),
			func(value: float) -> void:
				profile.set(key, value)
				_changed())

	for definition: Array in color_fields:
		if String(definition[2]) != section:
			continue
		var color_key := String(definition[0])
		_color(parent, String(definition[1]), profile.get(color_key), String(definition[3]),
			func(value: Color) -> void:
				profile.set(color_key, value)
				_changed())


## Slider plus a typed exact value, ported from the Blackledger dock.
##
## A slider alone cannot express "exposure 0.76" reliably, and a spinbox alone
## loses the feel of sweeping a value while watching the board. Having both is
## what makes these usable as tuning knobs.
func _slider(
	parent: VBoxContainer,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	tooltip: String,
	on_change: Callable
) -> HSlider:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	label.tooltip_text = tooltip
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(110, 0)
	slider.tooltip_text = tooltip
	row.add_child(slider)

	var exact := LineEdit.new()
	exact.custom_minimum_size = Vector2(VALUE_WIDTH, 0)
	exact.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	exact.select_all_on_focus = true
	exact.text = _format(value, step)
	exact.tooltip_text = "Type an exact value between %s and %s" % [_format(minimum, step), _format(maximum, step)]
	row.add_child(exact)

	slider.set_meta("exact", exact)
	slider.set_meta("step", step)

	# value_changed fires every frame while dragging, so on_change (a material
	# rebuild / cache clear / board rebuild) only runs there when the change did
	# NOT come from a drag -- i.e. an arrow-key nudge or a script-driven set.
	# The number beside the slider still updates live so dragging keeps its
	# feel; the expensive work waits for drag_ended, which Range fires exactly
	# once when the mouse button is released.
	slider.value_changed.connect(func(next: float) -> void:
		exact.text = _format(next, step)
		if not _refreshing and not slider.has_meta("_dragging"):
			on_change.call(next))
	slider.drag_started.connect(func() -> void:
		slider.set_meta("_dragging", true))
	# Always commit on release, regardless of Range's own value_changed flag --
	# relying on that flag meant a release Range did not consider a "real"
	# change (e.g. ending a drag back at the starting value after an
	# intermediate move) silently dropped the edit with no error, which is a
	# strictly worse failure mode than committing one extra time.
	slider.drag_ended.connect(func(_value_changed: bool) -> void:
		slider.remove_meta("_dragging")
		if not _refreshing:
			on_change.call(slider.value))
	var commit := func() -> void:
		var typed := exact.text.strip_edges()
		if typed.is_valid_float():
			slider.value = clampf(typed.to_float(), minimum, maximum)
		exact.text = _format(slider.value, step)
	exact.text_submitted.connect(func(_text: String) -> void: commit.call())
	exact.focus_exited.connect(commit)
	return slider


## Move a slider without firing its callback, for refreshes.
func _set_slider(slider: HSlider, value: float) -> void:
	slider.set_value_no_signal(value)
	var exact: LineEdit = slider.get_meta("exact")
	if exact != null:
		exact.text = _format(value, float(slider.get_meta("step")))


## Format exact values with enough decimal places to represent the control's declared step.
func _format(value: float, step: float) -> String:
	var decimals := 0
	var scaled_step := absf(step)
	while decimals < 8 and not is_equal_approx(scaled_step, roundf(scaled_step)):
		scaled_step *= 10.0
		decimals += 1
	return ("%%.%df" % decimals) % value


func _color(parent: VBoxContainer, label_text: String, value: Color, tooltip: String, on_change: Callable) -> ColorPickerButton:
	var picker := ColorPickerButton.new()
	picker.color = value
	picker.custom_minimum_size = Vector2(0, 24)
	picker.edit_alpha = false
	picker.color_changed.connect(func(next: Color) -> void:
		if not _refreshing:
			on_change.call(next))
	_labelled(parent, label_text, picker, tooltip)
	return picker


func _toggle(parent: VBoxContainer, label_text: String, value: bool, tooltip: String, on_change: Callable) -> CheckBox:
	var check := CheckBox.new()
	check.text = label_text
	check.button_pressed = value
	check.tooltip_text = tooltip
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check.toggled.connect(func(next: bool) -> void:
		if not _refreshing:
			on_change.call(next))
	parent.add_child(check)
	return check


func _text(parent: VBoxContainer, label_text: String, value: String, tooltip: String, on_change: Callable) -> LineEdit:
	var field := LineEdit.new()
	field.text = value
	field.text_changed.connect(func(next: String) -> void:
		if not _refreshing:
			on_change.call(next))
	_labelled(parent, label_text, field, tooltip)
	return field


func _labelled(parent: VBoxContainer, label_text: String, control: Control, tooltip: String) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	label.tooltip_text = tooltip
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	control.tooltip_text = tooltip
	row.add_child(control)


## A section heading with its own reset, so tuning the grade never costs the
## surface work and vice versa.
func _section(parent: VBoxContainer, title: String, on_reset: Callable) -> void:
	parent.add_child(HSeparator.new())
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)

	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.72, 0.80, 0.94))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var reset := Button.new()
	reset.text = "Reset"
	reset.tooltip_text = "Return this section to its defaults. Nothing else on the board changes."
	reset.pressed.connect(on_reset)
	row.add_child(reset)


func _reset_all_row(parent: VBoxContainer, text: String, on_reset: Callable) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var reset := Button.new()
	reset.text = text
	reset.tooltip_text = "Return every knob on this tab to its shipped default."
	reset.pressed.connect(on_reset)
	row.add_child(reset)


func _note(parent: VBoxContainer, text: String) -> void:
	var note := Label.new()
	note.text = text
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", Color(0.60, 0.64, 0.70))
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(note)
