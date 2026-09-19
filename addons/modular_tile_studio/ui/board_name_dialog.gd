@tool
class_name BoardNameDialog
extends ConfirmationDialog

## Asks for a level's name.
##
## One dialog serves the two moments that need naming -- saving an untitled
## board and renaming an existing one -- because both ask the same question and
## should not answer it two slightly different ways.
##
## A board is a level the user will look for by name later. Leaving that to a
## default filename means a boards folder of untitled_board.json, and the tool
## has no other place the name can come from.

## The chosen name, plus the purpose the dialog was opened for, so one listener
## can distinguish saving an untitled board from renaming the open one.
signal name_confirmed(board_name: String, purpose: String)

var _name_edit: LineEdit
var _message: Label
var _error: Label
var _purpose: String = ""


func _ready() -> void:
	title = "Name Board"
	ok_button_text = "OK"
	min_size = Vector2i(420, 0)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_message)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "e.g. Monastery Courtyard"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Enter confirms, so naming a board is type-and-go rather than reaching for
	# the mouse. text_submitted fires before the dialog would otherwise close, so
	# the same validation runs either way.
	_name_edit.text_submitted.connect(func(_v: String) -> void: _try_confirm())
	_name_edit.text_changed.connect(func(_v: String) -> void: _validate())
	root.add_child(_name_edit)

	_error = Label.new()
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.add_theme_font_size_override("font_size", 10)
	_error.modulate = Color(1.0, 0.6, 0.5)
	root.add_child(_error)

	# get_ok_button() only exists once the dialog is in the tree, which it is by
	# the time _ready runs.
	confirmed.connect(_on_confirmed)


## Open the dialog for one of the naming moments.
##
## `purpose` is echoed back with the result rather than being acted on here: the
## dialog's job is to collect a name, and saving or renaming belongs to the plugin
## that owns the document.
func ask(purpose: String, current_name: String, prompt: String) -> void:
	_purpose = purpose
	_message.text = prompt
	_name_edit.text = current_name
	_validate()
	popup_centered()
	# Selected rather than merely focused, so typing replaces the suggestion
	# instead of appending to it.
	_name_edit.grab_focus()
	_name_edit.select_all()


## Empty names are refused rather than quietly replaced with a default: a board
## called "Untitled Board" because the user pressed Enter too fast is exactly
## the problem naming is meant to solve.
func _validate() -> bool:
	var clean := _name_edit.text.strip_edges()
	var valid := not clean.is_empty()
	_error.text = "" if valid else "A board needs a name."
	var ok_button := get_ok_button()
	if ok_button != null:
		ok_button.disabled = not valid
	return valid


## Confirm from the Enter key, matching what the OK button would do.
func _try_confirm() -> void:
	if not _validate():
		return
	hide()
	_on_confirmed()


func _on_confirmed() -> void:
	var clean := _name_edit.text.strip_edges()
	if clean.is_empty():
		return
	name_confirmed.emit(clean, _purpose)
