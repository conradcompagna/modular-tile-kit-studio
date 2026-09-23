@tool
extends RefCounted

## Sidecars behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Save each authored placement image as an immutable checksummed PNG sidecar.
static func save_sidecars(host: MTSSurfaceMaterialPaint,
	board_path: String,
	allowed_uids: Variant = null
) -> Dictionary:
	if board_path.is_empty():
		push_error("MTSSurfaceMaterialPaint: cannot save paint without a board path.")
		return {"error": ERR_INVALID_PARAMETER, "metadata": {}}
	var board_directory := board_path.get_base_dir()
	var directory_error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(board_directory)
	)
	if directory_error != OK:
		push_error(
			"MTSSurfaceMaterialPaint: cannot create paint sidecar directory '%s' (%s)."
			% [board_directory, error_string(directory_error)]
		)
		return {"error": directory_error, "metadata": {}}
	var entries: Array = []
	var uids := host._images_by_uid.keys()
	uids.sort()
	var board_stem := board_path.get_file().get_basename()
	for uid_value: Variant in uids:
		var uid := String(uid_value)
		if allowed_uids is Dictionary and not (allowed_uids as Dictionary).has(uid):
			continue
		if not host._uid_is_safe(uid):
			push_error("MTSSurfaceMaterialPaint: unsafe placement uid '%s'." % uid)
			return {"error": ERR_INVALID_DATA, "metadata": {}}
		var image := host.image_for_uid(uid)
		if image == null or image.is_empty():
			continue
		var png_bytes := image.save_png_to_buffer()
		if png_bytes.is_empty():
			push_error("MTSSurfaceMaterialPaint: cannot encode paint for '%s'." % uid)
			return {"error": ERR_CANT_CREATE, "metadata": {}}
		var checksum := host._sha256_bytes(png_bytes)
		# The canonical face UID ("t:4,8") contains characters no filesystem accepts,
		# so the file is named by a hash of that identity while the metadata entry
		# below keeps the real UID. The identity hash makes the name stable per face
		# and the content hash keeps immutable pixels at a distinct path.
		var filename := "%s.paint.%s.%s.png" % [
			board_stem,
			host._sha256_bytes(uid.to_utf8_buffer()).substr(0, 16),
			checksum.substr(0, 16),
		]
		var sidecar_path := board_directory.path_join(filename)
		if not FileAccess.file_exists(sidecar_path):
			var file := FileAccess.open(sidecar_path, FileAccess.WRITE)
			if file == null:
				var open_error := FileAccess.get_open_error()
				push_error(
					"MTSSurfaceMaterialPaint: cannot write '%s' (%s)."
					% [sidecar_path, error_string(open_error)]
				)
				return {"error": open_error, "metadata": {}}
			file.store_buffer(png_bytes)
			file.flush()
			var write_error := file.get_error()
			file.close()
			if write_error != OK:
				push_error(
					"MTSSurfaceMaterialPaint: cannot finish '%s' (%s)."
					% [sidecar_path, error_string(write_error)]
				)
				return {"error": write_error, "metadata": {}}
		var verification_bytes := FileAccess.get_file_as_bytes(sidecar_path)
		if host._sha256_bytes(verification_bytes) != checksum:
			push_error("MTSSurfaceMaterialPaint: paint sidecar checksum failed for '%s'." % uid)
			return {"error": ERR_FILE_CORRUPT, "metadata": {}}
		entries.append({
			"uid": uid,
			"file": filename,
			"file_sha256": checksum,
			"resolution": [image.get_width(), image.get_height()],
		})
	var slot_entries: Array = []
	var mapped_uids := host._palette_slots_by_uid.keys()
	mapped_uids.sort()
	for uid_value: Variant in mapped_uids:
		var uid := String(uid_value)
		if allowed_uids is Dictionary and not (allowed_uids as Dictionary).has(uid):
			continue
		if not host._uid_is_safe(uid):
			push_error("MTSSurfaceMaterialPaint: unsafe palette-mapping uid '%s'." % uid)
			return {"error": ERR_INVALID_DATA, "metadata": {}}
		slot_entries.append({
			"uid": uid,
			"palette_indices": Array(host.palette_slots_for_uid(uid)),
			"rotation_quarters": Array(host.slot_rotations_for_uid(uid)),
		})
	return {
		"error": OK,
		"metadata": {
			"version": MTSSurfaceMaterialPaint.METADATA_VERSION,
			"surfaces": entries,
			"material_slots": slot_entries,
		},
	}


## Validate every saved paint image before any live authored pixels are replaced.
static func prepare_sidecars(host: MTSSurfaceMaterialPaint, board_path: String, metadata: Dictionary) -> Dictionary:
	if metadata.is_empty():
		return {"error": OK, "images": {}, "palette_slots": {}, "slot_rotations": {}}
	var surfaces_value: Variant = metadata.get("surfaces", [])
	if not surfaces_value is Array:
		push_error("MTSSurfaceMaterialPaint: sidecar surfaces must be an array.")
		return {"error": ERR_INVALID_DATA}
	var prepared_images: Dictionary = {}
	for entry_value: Variant in (surfaces_value as Array):
		if not entry_value is Dictionary:
			push_error("MTSSurfaceMaterialPaint: sidecar entry must be an object.")
			return {"error": ERR_INVALID_DATA}
		var entry: Dictionary = entry_value
		var uid := String(entry.get("uid", ""))
		var filename := String(entry.get("file", ""))
		var expected_hash := String(entry.get("file_sha256", ""))
		var resolution_value: Variant = entry.get("resolution", [])
		if (
			not host._uid_is_safe(uid)
			or filename.is_empty()
			or filename != filename.get_file()
			or expected_hash.is_empty()
			or not resolution_value is Array
			or (resolution_value as Array).size() != 2
			or prepared_images.has(uid)
		):
			push_error("MTSSurfaceMaterialPaint: invalid or duplicate sidecar entry '%s'." % uid)
			return {"error": ERR_INVALID_DATA}
		var sidecar_path := board_path.get_base_dir().path_join(filename)
		if not FileAccess.file_exists(sidecar_path):
			push_error("MTSSurfaceMaterialPaint: required sidecar '%s' is missing." % sidecar_path)
			return {"error": ERR_FILE_NOT_FOUND}
		var bytes := FileAccess.get_file_as_bytes(sidecar_path)
		if host._sha256_bytes(bytes) != expected_hash:
			push_error("MTSSurfaceMaterialPaint: sidecar checksum failed for '%s'." % uid)
			return {"error": ERR_FILE_CORRUPT}
		var image := Image.new()
		var load_error := image.load_png_from_buffer(bytes)
		if load_error != OK:
			push_error(
				"MTSSurfaceMaterialPaint: cannot decode '%s' (%s)."
				% [sidecar_path, error_string(load_error)]
			)
			return {"error": load_error}
		var saved_resolution: Array = resolution_value
		if image.get_size() != Vector2i(
			int(saved_resolution[0]),
			int(saved_resolution[1])
		):
			push_error("MTSSurfaceMaterialPaint: sidecar resolution mismatch for '%s'." % uid)
			return {"error": ERR_INVALID_DATA}
		if image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
		prepared_images[uid] = image
	var material_slots_value: Variant = metadata.get("material_slots", [])
	if not material_slots_value is Array:
		push_error("MTSSurfaceMaterialPaint: material_slots must be an array.")
		return {"error": ERR_INVALID_DATA}
	var prepared_slots: Dictionary = {}
	var prepared_rotations: Dictionary = {}
	for entry_value: Variant in material_slots_value as Array:
		if not entry_value is Dictionary:
			push_error("MTSSurfaceMaterialPaint: material slot entry must be an object.")
			return {"error": ERR_INVALID_DATA}
		var entry: Dictionary = entry_value
		var uid := String(entry.get("uid", ""))
		var indices_value: Variant = entry.get("palette_indices", [])
		var rotations_value: Variant = entry.get("rotation_quarters", [0, 0, 0, 0])
		if (
			not host._uid_is_safe(uid)
			or prepared_slots.has(uid)
			or not indices_value is Array
			or (indices_value as Array).size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
			or not rotations_value is Array
			or (rotations_value as Array).size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
		):
			push_error("MTSSurfaceMaterialPaint: invalid material slot entry '%s'." % uid)
			return {"error": ERR_INVALID_DATA}
		var slots := PackedInt32Array()
		for palette_value: Variant in indices_value as Array:
			var palette_index := int(palette_value)
			if palette_index < -1:
				push_error("MTSSurfaceMaterialPaint: invalid palette index on face '%s'." % uid)
				return {"error": ERR_INVALID_DATA}
			slots.append(palette_index)
		var rotations := PackedInt32Array()
		for rotation_value: Variant in rotations_value as Array:
			var rotation_quarters := int(rotation_value)
			if rotation_quarters < 0 or rotation_quarters > 3:
				push_error("MTSSurfaceMaterialPaint: invalid material orientation on face '%s'." % uid)
				return {"error": ERR_INVALID_DATA}
			rotations.append(rotation_quarters)
		prepared_slots[uid] = slots
		prepared_rotations[uid] = rotations
	return {
		"error": OK,
		"images": prepared_images,
		"palette_slots": prepared_slots,
		"slot_rotations": prepared_rotations,
	}


## Atomically replace authored paint after every referenced PNG passed validation.
static func commit_prepared_sidecars(host: MTSSurfaceMaterialPaint, prepared: Dictionary) -> bool:
	if int(prepared.get("error", FAILED)) != OK:
		push_error("MTSSurfaceMaterialPaint: cannot commit invalid prepared paint.")
		return false
	var images_value: Variant = prepared.get("images", {})
	var palette_slots_value: Variant = prepared.get("palette_slots", {})
	var slot_rotations_value: Variant = prepared.get("slot_rotations", {})
	if (
		not images_value is Dictionary
		or not palette_slots_value is Dictionary
		or not slot_rotations_value is Dictionary
	):
		push_error("MTSSurfaceMaterialPaint: prepared paint images or material slots are invalid.")
		return false
	host._images_by_uid = (images_value as Dictionary).duplicate()
	host._palette_slots_by_uid = (palette_slots_value as Dictionary).duplicate(true)
	host._slot_rotations_by_uid = (slot_rotations_value as Dictionary).duplicate(true)
	host._dirty_uids.clear()
	host._stroke_before.clear()
	host._stroke_slots_before.clear()
	if host._stroke_rotations_before == null:
		host._stroke_rotations_before = {}
	host._stroke_rotations_before.clear()
	host._stroke_max_weights.clear()
	host._stroke_active = false
	for key_value: Variant in host._batch_records.keys():
		var key := String(key_value)
		host._rebuild_batch_texture(key)
		host.batch_texture_changed.emit(key)
	host.palette_usage_changed.emit()
	return true


## Return the SHA-256 checksum that binds immutable PNG bytes to board JSON.
static func _sha256_bytes(host: MTSSurfaceMaterialPaint, bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	var start_error := context.start(HashingContext.HASH_SHA256)
	if start_error != OK:
		push_error("MTSSurfaceMaterialPaint: cannot initialize SHA-256.")
		return ""
	var update_error := context.update(bytes)
	if update_error != OK:
		push_error("MTSSurfaceMaterialPaint: cannot hash paint bytes.")
		return ""
	return context.finish().hex_encode()


## Accept exactly the canonical TerrainMesh face identities and reject anything else.
##
## Paint is keyed by the sculpt-stable face UIDs minted in TerrainMesh: "t:X,Z" for a
## cell top, "s:X,Z,edge,band" for an internal side band, and "k:X,Z,edge,band" for a
## boundary-skirt band. Those identities contain ':' and ',' which can never appear in a
## filename, so sidecars are named by checksum and this check validates identity only.
static func _uid_is_safe(host: MTSSurfaceMaterialPaint, uid: String) -> bool:
	if uid.is_empty():
		return false
	var parts := uid.split(":")
	if parts.size() != 2:
		return false
	var fields := parts[1].split(",")
	match parts[0]:
		"t":
			if fields.size() != 2:
				return false
		"s", "k":
			if fields.size() != 4:
				return false
		_:
			return false
	for field: String in fields:
		if field.is_empty():
			return false
		# Cell coordinates are signed because the authored footprint may extend
		# into negative lattice space; band and edge indices are never negative.
		var digits := field.substr(1) if field.begins_with("-") else field
		if digits.is_empty() or not digits.is_valid_int():
			return false
	return true
