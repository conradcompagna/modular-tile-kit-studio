@tool
extends RefCounted

## Controls behavior for MaterialPaintPanel.
## The host retains Godot identity, signals, and authoritative state.

## Add one labeled row so every compact control names and explains the exact value it edits.
static func _row(host: MaterialPaintPanel, parent: Control, label_text: String, tooltip: String = "") -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 104.0
	row.tooltip_text = tooltip
	label.tooltip_text = tooltip
	row.add_child(label)
	parent.add_child(row)
	return row


## Add one horizontal separator without spending vertical space on another heading.
static func _add_separator(host: MaterialPaintPanel, parent: Control) -> void:
	parent.add_child(HSeparator.new())


## Add one percentage-style slider with a live numeric readout and return its editable range.
static func _add_slider(host: MaterialPaintPanel,
	parent: Control,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	suffix: String,
	exponential: bool = false,
	tooltip: String = ""
) -> HSlider:
	var row := host._row(parent, label_text, tooltip)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	slider.exp_edit = exponential
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.tooltip_text = tooltip
	row.add_child(slider)
	var value_label := Label.new()
	value_label.custom_minimum_size.x = 58.0
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.tooltip_text = tooltip
	row.add_child(value_label)
	host._slider_labels[slider] = {"label": value_label, "suffix": suffix}
	host._update_slider_label(slider)
	return slider


## Add one exact numeric field for values that are awkward to manipulate as a slider.
static func _add_spin(host: MaterialPaintPanel,
	parent: Control,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	tooltip: String = ""
) -> SpinBox:
	var row := host._row(parent, label_text, tooltip)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.tooltip_text = tooltip
	row.add_child(spin)
	return spin


## Add one labeled option list and populate IDs in the same order as its visible names.
static func _add_option(host: MaterialPaintPanel,
	parent: Control,
	label_text: String,
	names: PackedStringArray,
	tooltip: String = ""
) -> OptionButton:
	var row := host._row(parent, label_text, tooltip)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.tooltip_text = tooltip
	for index: int in names.size():
		option.add_item(names[index], index)
	row.add_child(option)
	return option


## Refresh one slider's readout so compact sliders never hide their exact authored value.
static func _update_slider_label(host: MaterialPaintPanel, slider: HSlider) -> void:
	var record: Dictionary = host._slider_labels.get(slider, {})
	var label := record.get("label", null) as Label
	if label == null:
		return
	var decimals := 2 if slider.step < 0.1 else 0
	label.text = ("%.*f%s" % [decimals, slider.value, String(record.get("suffix", ""))])
