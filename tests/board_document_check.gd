extends SceneTree

const Fixture := preload("res://tests/fixtures/public_board.gd")
const GOLDEN_PATH := "res://tests/fixtures/board_v13.json"
var failures := 0


func _init() -> void:
	var library := Fixture.library()
	var board := Fixture.board(library)
	var encoded := JSON.stringify(board.to_json(), "\t", true, true)
	if OS.get_cmdline_user_args().has("--record"):
		var golden := FileAccess.open(GOLDEN_PATH, FileAccess.WRITE)
		golden.store_string(encoded + "\n")
		golden.close()
	else:
		_check(encoded == FileAccess.get_file_as_string(GOLDEN_PATH).strip_edges(), "version 13 serialization matches the original implementation")
	_check(BoardDocument.serialized_data_errors(board.to_json()).is_empty(), "fixture satisfies persistent schema")
	var directory := "user://board_document_check_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("board.json")
	_check(board.save_json(path) == OK, "atomic save succeeds")
	var loaded := BoardDocument.new()
	loaded.bind_library(library)
	_check(loaded.load_json(path) == OK, "saved board reloads")
	_check(JSON.parse_string(JSON.stringify(loaded.to_json(), "", true, true)) == JSON.parse_string(encoded), "reload preserves every canonical field")
	_check(loaded.surface_at_paint_uid("t:0,0") != null, "paint index rebuilt after load")
	_check(loaded.shader_decals_at_paint_uid("t:0,0").size() == 1, "decal index rebuilt after load")
	_check(loaded.enemy_pack_member_count("guards") == 1, "gameplay indexes rebuilt after load")
	_check(loaded.movement_cell_is_unwalkable(Vector2i(-1, -1)), "movement exclusions survive reload")
	_check(loaded.movement_ground_effect(Vector2i.ZERO) == "mud", "movement effect survives reload")
	var original_name := loaded.board_name
	loaded.board_name = "Second save"
	_check(loaded.save_json(path) == OK, "replacement save succeeds")
	var backups := 0
	for name: String in DirAccess.get_files_at(directory):
		if name.begins_with("board.json.backup-"):
			backups += 1
			var prior := BoardDocument.new()
			prior.bind_library(library)
			_check(prior.load_json(directory.path_join(name)) == OK and prior.board_name == original_name, "backup retains previous board")
	_check(backups == 1, "replacement retains exactly one prior revision")
	# Validate a bad candidate before commit; the existing document stays usable.
	var invalid := loaded.to_json().duplicate(true)
	invalid["surfaces"] = "invalid"
	_check(not BoardDocument.serialized_data_errors(invalid).is_empty(), "invalid placement payload rejected")
	_check(loaded.board_name == "Second save", "candidate validation leaves live state intact")
	for name: String in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	DirAccess.remove_absolute(directory)
	print("Board document failures: %d" % failures)
	quit(1 if failures else 0)


func _check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		push_error(label)
