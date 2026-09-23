@tool
extends RefCounted

## File io behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Read one board JSON object for staged verification or an explicit load.
static func _read_board_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": ERR_FILE_NOT_FOUND, "data": {}}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": FileAccess.get_open_error(), "data": {}}
	var text := file.get_as_text()
	var read_error := file.get_error()
	file.close()
	if read_error != OK:
		return {"error": read_error, "data": {}}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"error": ERR_PARSE_ERROR, "data": {}}
	return {"error": OK, "data": parsed}


## Return a unique timestamped backup path beside the board being replaced.
static func _next_backup_path(path: String) -> String:
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var base_path := "%s%s%s" % [path, BoardDocument.SAVE_BACKUP_SUFFIX, timestamp]
	var candidate := base_path
	var suffix: int = 2
	while FileAccess.file_exists(candidate):
		candidate = "%s-%d" % [base_path, suffix]
		suffix += 1
	return candidate


## Remove one exact staging file after a failed save attempt.
static func _remove_staging_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if remove_error != OK:
		push_error(
			"BoardDocument: could not remove staging file '%s' (%s)"
			% [path, error_string(remove_error)]
		)


## Commit one verified staging file while retaining the previous board as a backup.
##
## The old file is moved first and restored if the final rename fails, so there
## is never a point where a failed commit silently destroys the last valid board.
static func _commit_staged_board(staging_path: String, target_path: String) -> Error:
	var staging_absolute := ProjectSettings.globalize_path(staging_path)
	var target_absolute := ProjectSettings.globalize_path(target_path)
	var backup_path := ""
	if FileAccess.file_exists(target_path):
		backup_path = BoardDocument._next_backup_path(target_path)
		var backup_error := DirAccess.rename_absolute(
			target_absolute,
			ProjectSettings.globalize_path(backup_path)
		)
		if backup_error != OK:
			BoardDocument._remove_staging_file(staging_path)
			push_error(
				"BoardDocument: cannot preserve '%s' before saving (%s)"
				% [target_path, error_string(backup_error)]
			)
			return backup_error

	var commit_error := DirAccess.rename_absolute(staging_absolute, target_absolute)
	if commit_error == OK:
		if not backup_path.is_empty():
			print("[Tile Studio] Previous board preserved at %s" % backup_path)
		return OK

	if not backup_path.is_empty():
		var restore_error := DirAccess.rename_absolute(
			ProjectSettings.globalize_path(backup_path),
			target_absolute
		)
		if restore_error != OK:
			push_error(
				"BoardDocument: commit failed and previous board remains at '%s' (%s)"
				% [backup_path, error_string(restore_error)]
			)
	BoardDocument._remove_staging_file(staging_path)
	push_error(
		"BoardDocument: cannot commit staged save '%s' (%s)"
		% [target_path, error_string(commit_error)]
	)
	return commit_error


## Save validated portable board JSON through a verified atomic staging file.
static func save_json(host: BoardDocument, path: String) -> Error:
	var data := host.to_json()
	var persistence_errors := BoardDocument.serialized_data_errors(data)
	persistence_errors.append_array(host._serialized_count_errors(data))
	if not persistence_errors.is_empty():
		push_error(
			"BoardDocument: refusing destructive save to '%s'; existing file preserved: %s"
			% [path, "; ".join(persistence_errors)]
		)
		return ERR_INVALID_DATA

	var staging_path := "%s%s%d" % [path, BoardDocument.SAVE_STAGING_SUFFIX, Time.get_ticks_usec()]
	var file := FileAccess.open(staging_path, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		push_error(
			"BoardDocument: cannot stage '%s' (%s)" % [path, error_string(open_error)]
		)
		return open_error
	file.store_string(JSON.stringify(data, "	"))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		BoardDocument._remove_staging_file(staging_path)
		push_error(
			"BoardDocument: cannot finish staged save '%s' (%s)"
			% [path, error_string(write_error)]
		)
		return write_error

	var staged_result := BoardDocument._read_board_json(staging_path)
	var staged_error := int(staged_result.get("error", FAILED))
	if staged_error != OK:
		BoardDocument._remove_staging_file(staging_path)
		push_error(
			"BoardDocument: staged save for '%s' could not be read back (%s)"
			% [path, error_string(staged_error)]
		)
		return staged_error
	var staged_data: Dictionary = staged_result.get("data", {})
	var staged_errors := BoardDocument.serialized_data_errors(staged_data)
	if not staged_errors.is_empty():
		BoardDocument._remove_staging_file(staging_path)
		push_error(
			"BoardDocument: staged save verification failed for '%s'; existing file preserved"
			% path
		)
		return ERR_INVALID_DATA
	return BoardDocument._commit_staged_board(staging_path, path)


## Load one fully valid board JSON object without mutating this document on failure.
static func load_json(host: BoardDocument, path: String) -> Error:
	var read_result := BoardDocument._read_board_json(path)
	var read_error := int(read_result.get("error", FAILED))
	if read_error != OK:
		push_error(
			"BoardDocument: cannot load '%s' (%s); live board preserved"
			% [path, error_string(read_error)]
		)
		return read_error
	var parsed: Dictionary = read_result.get("data", {})
	var load_error := host.from_json(parsed)
	if load_error != OK:
		push_error("BoardDocument: '%s' was rejected; live board preserved" % path)
	return load_error
