@tool
class_name ImportImageDialog
extends ConfirmationDialog

## PNG import dialog (spec 12).
##
## Dimensions are stated in whole metres so the image maps cleanly onto grid
## faces. The user should reach "painting with it" seconds after choosing a file.

const Remover := preload("../importers/background_remover.gd")

signal import_confirmed(source_path: String, settings: Dictionary)

var _source_path: String = ""
var _preview: TextureRect
var _id_edit: LineEdit
var _name_edit: LineEdit
var _biome_edit: LineEdit
var _width_spin: SpinBox
var _height_spin: SpinBox
var _link_dimensions_check: CheckBox
var _remove_background_check: CheckBox
var _hint: Label
var _aspect_label: Label
var _aspect_warning: Label
var _background_note: Label
var _source_aspect: float = 0.0
## Prevent the mirrored SpinBox assignment from recursively changing the source field.
var _synchronizing_dimensions: bool = false
## Untouched source pixels, so toggling the checkbox re-cuts the preview
## without re-reading the file from disk each time.
var _source_image: Image = null


## Construct the PNG import form and wire its visible controls to their matching settings.
func _ready() -> void:
	title = "Import Image Surface"
	ok_button_text = "Import"
	# Bounded so the Import/Cancel buttons can never be pushed off-screen by tall
	# content; the fields scroll instead. See import_glb_dialog for detail.
	min_size = Vector2i(480, 400)
	max_size = Vector2i(900, 720)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(460, 360)
	add_child(scroll)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(root)

	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(0, 160)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(_preview)

	var grid := GridContainer.new()
	grid.columns = 2
	root.add_child(grid)

	_id_edit = _add_field(grid, "Asset ID", LineEdit.new()) as LineEdit
	_id_edit.tooltip_text = "Stable, machine-safe, semantic. Boards and the future LLM refer to this."
	_name_edit = _add_field(grid, "Display Name", LineEdit.new()) as LineEdit
	# No category field: every image import lands in the one fixed "PNG Images"
	# category, so there is nothing to type and nothing to get wrong.
	_biome_edit = _add_field(grid, "Biome", LineEdit.new()) as LineEdit

	_width_spin = SpinBox.new()
	_width_spin.min_value = 1
	_width_spin.max_value = 64
	_width_spin.value = 1
	_width_spin.value_changed.connect(func(value: float) -> void: _on_dimension_changed(value, _height_spin))
	_add_field(grid, "Width (m)", _width_spin)

	_height_spin = SpinBox.new()
	_height_spin.min_value = 1
	_height_spin.max_value = 64
	_height_spin.value = 1
	_height_spin.value_changed.connect(func(value: float) -> void: _on_dimension_changed(value, _width_spin))
	_add_field(grid, "Height (m)", _height_spin)

	_link_dimensions_check = CheckBox.new()
	_link_dimensions_check.text = "Link planar dimensions"
	_link_dimensions_check.button_pressed = true
	_link_dimensions_check.tooltip_text = "When enabled, entering a whole-metre value in either field copies it to the other. Turn this off to import a rectangular PNG surface. The same two dimensions become the active face axes (X/Y or X/Z) when placed."
	_link_dimensions_check.toggled.connect(_on_dimension_link_toggled)
	_add_field(grid, "Size behavior", _link_dimensions_check)


	var orientation_note := Label.new()
	orientation_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	orientation_note.add_theme_font_size_override("font_size", 10)
	orientation_note.modulate = Color(0.65, 0.68, 0.75)
	orientation_note.text = "Imported Y-up. Rotate or flip the brush in the editor before placement."
	root.add_child(orientation_note)

	# Background removal at import, because that is when it is nearly always
	# wanted: AI-generated tile art arrives on a flat plate, and painting with the
	# plate still attached puts an opaque rectangle over the grid. Off by default
	# -- it rewrites the art, so it must be a choice the user makes, not one made
	# for them. The same operation stays available in the inspector afterwards.
	_remove_background_check = CheckBox.new()
	_remove_background_check.button_pressed = false
	_remove_background_check.text = "Remove background"
	_remove_background_check.tooltip_text = "Clear the flat plate behind the art, in place.

Only pixels that exactly match the border colour AND connect to the image edge are removed, so a shape enclosed by the artwork survives even if it is the same colour. Art on a busy or gradient background is left alone rather than damaged.

The art is not cropped or re-framed: it keeps the metre size you set above. The stored original is never modified -- the cut is written as a separate file."
	_remove_background_check.toggled.connect(func(_pressed: bool) -> void: _update_preview())
	_add_field(grid, "Background", _remove_background_check)

	_aspect_label = Label.new()
	_aspect_label.add_theme_font_size_override("font_size", 11)
	_aspect_label.text = "Source: -"
	root.add_child(_aspect_label)

	# Warns when the chosen metre size would stretch the artwork, rather than
	# quietly changing the numbers.
	_aspect_warning = Label.new()
	_aspect_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_aspect_warning.add_theme_font_size_override("font_size", 10)
	_aspect_warning.modulate = Color(1.0, 0.75, 0.4)
	root.add_child(_aspect_warning)

	# Says what the cut actually did, so the checkbox is never a leap of faith:
	# the preview above shows the result and this reports how much went.
	_background_note = Label.new()
	_background_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_background_note.add_theme_font_size_override("font_size", 10)
	root.add_child(_background_note)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_font_size_override("font_size", 10)
	_hint.text = "No AI processing is required. The image becomes paintable immediately; analysis is optional and can be run later."
	root.add_child(_hint)

	confirmed.connect(_on_confirmed)


## Add one labelled, expanding control to the dialog's two-column form.
func _add_field(grid: GridContainer, label_text: String, control: Control) -> Control:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)
	return control


## Reset the reusable dialog for one selected PNG source and display its source aspect.
func setup(source_path: String, suggested_id: String) -> void:
	_source_path = source_path
	_id_edit.text = suggested_id
	_name_edit.text = source_path.get_file().get_basename().capitalize()
	var image := Image.new()
	var global_path := ProjectSettings.globalize_path(source_path)
	if image.load(global_path) == OK:
		_source_image = image
		_update_preview()
		# Deliberately NOT guessed from the pixel aspect. Inferring metre sizes
		# silently reinterprets the user's art -- a 1536x1024 image intended as a
		# 2x3 wall would import as 3x2 and be wrong with no visible cause. The
		# source aspect is reported instead so the user decides.
		var w := image.get_width()
		var h := image.get_height()
		var ratio := float(w) / maxf(1.0, float(h))
		_source_aspect = ratio
		_aspect_label.text = "Source: %d x %d px  (aspect %.3f : 1)" % [w, h, ratio]
		_hint.text = "Set the physical size yourself -- it is never inferred from the image. For the source aspect to be preserved, width/height should be close to %.2f : 1. No AI processing is required; the image is paintable as soon as you import it." % ratio
		_update_aspect_warning()


## Copy an edited planar dimension into its paired field while the visible link is enabled.
func _on_dimension_changed(value: float, paired_spin: SpinBox) -> void:
	if _synchronizing_dimensions:
		return
	if _link_dimensions_check != null and _link_dimensions_check.button_pressed:
		_synchronizing_dimensions = true
		paired_spin.value = value
		_synchronizing_dimensions = false
	_update_aspect_warning()


## Reapply the visible size-link choice immediately so the two displayed values remain truthful.
func _on_dimension_link_toggled(link_dimensions: bool) -> void:
	if not link_dimensions:
		_update_aspect_warning()
		return
	_on_dimension_changed(_width_spin.value, _height_spin)


## Show the image exactly as it will be imported, cut or uncut.
##
## The checkbox previews rather than promises. Exact background removal either
## lands cleanly or does something visibly wrong (art that touches the border
## bleeds out through the edge), and the only way to know which is to look --
## so the toggle re-cuts the preview and reports what it removed.
func _update_preview() -> void:
	if _preview == null or _source_image == null:
		return

	if _remove_background_check == null or not _remove_background_check.button_pressed:
		_preview.texture = ImageTexture.create_from_image(_source_image)
		if _background_note != null:
			_background_note.text = ""
		return

	# Uncropped, matching the importer: cropping here would preview a framing
	# the import does not produce.
	var result := Remover.remove_background(_source_image, false)
	if not result.ok():
		_preview.texture = ImageTexture.create_from_image(_source_image)
		_background_note.modulate = Color(1.0, 0.55, 0.5)
		_background_note.text = "Cannot remove the background: %s. The image will import unchanged." % result.error
		return

	_preview.texture = ImageTexture.create_from_image(result.image)
	var percent := result.removed_fraction() * 100.0
	if result.removed_pixels == 0:
		_background_note.modulate = Color(1.0, 0.75, 0.4)
		_background_note.text = "No flat background found at the border, so nothing would be removed. The image will import unchanged."
	elif percent > 92.0:
		# Almost everything went: the border colour ran through the artwork.
		# Reported loudly rather than silently importing a nearly empty tile.
		_background_note.modulate = Color(1.0, 0.55, 0.5)
		_background_note.text = "This would remove %.0f%% of the image (background %s) -- the border colour reaches through the artwork. Check the preview before importing." % [
			percent, result.background_description()
		]
	else:
		_background_note.modulate = Color(0.55, 0.85, 0.6)
		_background_note.text = "Removes %.0f%% of the image (background %s). The stored original is kept unchanged." % [
			percent, result.background_description()
		]


## Report — never silently correct — a size that would distort the artwork.
func _update_aspect_warning() -> void:
	if _aspect_warning == null:
		return
	if _source_aspect <= 0.0:
		_aspect_warning.text = ""
		return
	var chosen := float(_width_spin.value) / maxf(1.0, float(_height_spin.value))
	# 2% tolerance: art authored for a grid is rarely pixel-exact.
	if absf(chosen - _source_aspect) / _source_aspect < 0.02:
		_aspect_warning.text = ""
		return
	var suggestion := ""
	# Offer whole-metre sizes that do match, so the user has a concrete option.
	for h in range(1, 9):
		var w := _source_aspect * float(h)
		if absf(w - round(w)) < 0.03 and round(w) >= 1.0:
			suggestion = "  Exact matches: %d x %d m." % [int(round(w)), h]
			break
	_aspect_warning.text = "%d x %d m does not match the source aspect (%.3f : 1), so the image will be stretched to fit.%s" % [
		int(_width_spin.value), int(_height_spin.value), _source_aspect, suggestion
	]


## Emit exactly the metre dimensions and background choice visible in the import form.
func _on_confirmed() -> void:
	var settings := {
		"asset_id": _id_edit.text,
		"display_name": _name_edit.text,
		"biome": _biome_edit.text,
		"width_m": int(_width_spin.value),
		"height_m": int(_height_spin.value),
		"remove_background": _remove_background_check.button_pressed,
	}
	import_confirmed.emit(_source_path, settings)
