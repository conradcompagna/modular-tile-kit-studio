@tool
extends SceneTree

var _failed: int = 0


## Defer the real slum_1 compatibility probe until all named project scripts are registered.
func _init() -> void:
	_run.call_deferred()


## Load the untouched version-11 board and every paint sidecar through the production migration path.
func _run() -> void:
	var board_path := "res://boards/slum_1.json"
	var file := FileAccess.open(board_path, FileAccess.READ)
	_check(file != null, "the unchanged slum_1 board JSON is readable")
	if file == null:
		_finish()
		return
	var text := file.get_as_text()
	var read_error := file.get_error()
	file.close()
	_check(read_error == OK, "the unchanged slum_1 board JSON reads without an I/O error")
	var parsed_value: Variant = JSON.parse_string(text)
	_check(parsed_value is Dictionary, "the unchanged slum_1 board JSON parses")
	if not parsed_value is Dictionary:
		_finish()
		return
	var parsed: Dictionary = parsed_value
	var original_paint: Dictionary = parsed.get("surface_material_paint", {})
	_check(
		int(parsed.get("version", 0)) == 11
		and int(original_paint.get("version", 0)) == 1
		and not original_paint.has("material_slots"),
		"slum_1 exercises the historical board and paint formats without a slot table"
	)

	var library := AssetLibrary.load_or_create()
	var live_board := BoardDocument.new()
	live_board.bind_library(library)
	var prepared_board_result := live_board.prepare_json(parsed)
	var prepared_board := prepared_board_result.get("board", null) as BoardDocument
	_check(
		int(prepared_board_result.get("error", FAILED)) == OK
		and prepared_board != null
		and prepared_board.version == BoardDocument.FORMAT_VERSION,
		"the production board loader migrates slum_1 to the current in-memory format"
	)
	if prepared_board == null:
		_finish()
		return

	var paint := MTSSurfaceMaterialPaint.new()
	paint.bind_profile(prepared_board.material_blend)
	var prepared_paint := paint.prepare_sidecars(
		board_path,
		prepared_board.surface_material_paint
	)
	var prepared_images: Dictionary = prepared_paint.get("images", {})
	var prepared_slots: Dictionary = prepared_paint.get("palette_slots", {})
	_check(
		int(prepared_paint.get("error", FAILED)) == OK
		and prepared_images.size() == (original_paint.get("surfaces", []) as Array).size()
		and prepared_slots.is_empty(),
		"all legacy slum_1 PNGs pass checksum and decode preflight before migration"
	)
	_check(
		paint.commit_prepared_sidecars(prepared_paint),
		"the fully prepared slum_1 paint set commits atomically"
	)
	if not prepared_images.is_empty():
		var first_uid := String(prepared_images.keys()[0])
		paint.register_face_palette(first_uid)
		_check(
			paint.palette_slots_for_uid(first_uid)
			== PackedInt32Array([0, 1, 2, 3]),
			"legacy slum_1 RGBA weights retain their historical palette meaning"
	)

	_finish()


## Record one explicit test result so silent migration errors cannot pass this probe.
func _check(condition: bool, message: String) -> void:
	if condition:
		print("  PASS  %s" % message)
		return
	_failed += 1
	push_error("  FAIL  %s" % message)


## Print the compatibility result and return a failing process code when any check failed.
func _finish() -> void:
	print("=== slum_1 palette migration failures: %d ===" % _failed)
	quit(1 if _failed > 0 else 0)
