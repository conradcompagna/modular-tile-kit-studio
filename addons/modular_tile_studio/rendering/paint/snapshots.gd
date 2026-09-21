@tool
extends RefCounted

## Snapshots behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Return whether any regular-heightfield face currently owns authored RGBA pixels.
static func has_any_paint(host: MTSSurfaceMaterialPaint) -> bool:
	return not host._images_by_uid.is_empty()


## Estimate canonical CPU pixels and derived GPU array pixels for current or requested settings.
##
## Driver allocation overhead is intentionally excluded; the reported RGBA8 texel bytes are the
## inspectable portion controlled directly by the two resolution settings.
static func paint_memory_bytes(host: MTSSurfaceMaterialPaint, target_profile: MaterialBlendProfile = null) -> Dictionary:
	var cpu_bytes: int = 0
	var gpu_bytes: int = 0
	for uid_value: Variant in host._images_by_uid.keys():
		var uid := String(uid_value)
		var image := host.image_for_uid(uid)
		if image == null:
			continue
		var resolution := image.get_size()
		if target_profile != null:
			var footprint := host._registered_footprint(uid)
			if footprint == Vector2i.ZERO:
				push_error(
					"MTSSurfaceMaterialPaint: painted placement '%s' has no registered footprint."
					% uid
				)
				return {"error": ERR_DOES_NOT_EXIST}
			resolution = target_profile.paint_resolution(footprint)
		cpu_bytes += resolution.x * resolution.y * 4
	for record_value: Variant in host._batch_records.values():
		var record: Dictionary = record_value
		var uids: PackedStringArray = record.get("uids", PackedStringArray())
		var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
		if not host._batch_has_authored_paint_in(uids, host._images_by_uid, seed_uid_by_uid):
			continue
		var resolution := Vector2i.ZERO
		if target_profile != null:
			var footprint: Vector2i = record.get("footprint_m", Vector2i.ZERO)
			if footprint == Vector2i.ZERO:
				push_error("MTSSurfaceMaterialPaint: a painted batch has no footprint.")
				return {"error": ERR_INVALID_DATA}
			resolution = target_profile.paint_resolution(footprint)
		else:
			for uid: String in uids:
				var image := host.image_for_uid(uid)
				if image != null:
					resolution = image.get_size()
					break
		if resolution == Vector2i.ZERO:
			push_error("MTSSurfaceMaterialPaint: a painted batch has no image resolution.")
			return {"error": ERR_INVALID_DATA}
		gpu_bytes += resolution.x * resolution.y * uids.size() * 4
	var palette_slot_bytes := host._palette_slots_by_uid.size() * MaterialBlendProfile.WEIGHTS_PER_TEXEL * 4
	return {
		"error": OK,
		"cpu_bytes": cpu_bytes,
		"gpu_bytes": gpu_bytes,
		"palette_slot_bytes": palette_slot_bytes,
		"total_bytes": cpu_bytes + gpu_bytes + palette_slot_bytes,
		"painted_surfaces": host._images_by_uid.size(),
		"mapped_surfaces": host._palette_slots_by_uid.size(),
	}


## Encode the exact canonical images for one resolution-change undo record.
##
## PNG compression keeps the temporary undo snapshot smaller than duplicate live Images while
## preserving every RGBA8 weight exactly.
static func capture_png_snapshot(host: MTSSurfaceMaterialPaint) -> Dictionary:
	if host._stroke_active:
		push_error("MTSSurfaceMaterialPaint: cannot snapshot paint during an active stroke.")
		return {"error": ERR_BUSY}
	return host._capture_png_snapshot_for_images(host._images_by_uid)


## Encode one already-prepared replacement so redo data is validated before live state changes.
static func capture_prepared_png_snapshot(host: MTSSurfaceMaterialPaint, prepared: Dictionary) -> Dictionary:
	if int(prepared.get("error", FAILED)) != OK:
		push_error("MTSSurfaceMaterialPaint: cannot snapshot an invalid prepared replacement.")
		return {"error": ERR_INVALID_DATA}
	var images_value: Variant = prepared.get("images", null)
	if not images_value is Dictionary:
		push_error("MTSSurfaceMaterialPaint: prepared replacement has no canonical image set.")
		return {"error": ERR_INVALID_DATA}
	return host._capture_png_snapshot_for_images(images_value as Dictionary)


## Encode one canonical image dictionary without consulting or changing live paint state.
static func _capture_png_snapshot_for_images(host: MTSSurfaceMaterialPaint, images_by_uid: Dictionary) -> Dictionary:
	var pngs: Dictionary = {}
	for uid_value: Variant in images_by_uid.keys():
		var uid := String(uid_value)
		var image := images_by_uid.get(uid) as Image
		if image == null:
			continue
		var bytes := image.save_png_to_buffer()
		if bytes.is_empty():
			push_error("MTSSurfaceMaterialPaint: cannot encode paint snapshot '%s'." % uid)
			return {"error": ERR_CANT_CREATE}
		pngs[uid] = bytes
	return {"error": OK, "pngs": pngs}


## Prepare bilinearly resampled canonical images and every affected GPU array before committing.
##
## Preparation is atomic: a failed image or Texture2DArray allocation leaves the current profile,
## canonical images, and batch textures untouched.
static func prepare_resolution_rebuild(host: MTSSurfaceMaterialPaint, target_profile: MaterialBlendProfile) -> Dictionary:
	if target_profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot rebuild resolution without a profile.")
		return {"error": ERR_INVALID_PARAMETER}
	if host._stroke_active:
		push_error("MTSSurfaceMaterialPaint: cannot rebuild resolution during an active stroke.")
		return {"error": ERR_BUSY}
	var prepared_images: Dictionary = {}
	for uid_value: Variant in host._images_by_uid.keys():
		var uid := String(uid_value)
		var source := host.image_for_uid(uid)
		if source == null:
			continue
		var footprint := host._registered_footprint(uid)
		if footprint == Vector2i.ZERO:
			push_error(
				"MTSSurfaceMaterialPaint: cannot resize unregistered painted placement '%s'."
				% uid
			)
			return {"error": ERR_DOES_NOT_EXIST}
		var resolution := target_profile.paint_resolution(footprint)
		var resized := source.duplicate() as Image
		if resized == null:
			push_error("MTSSurfaceMaterialPaint: cannot duplicate paint image '%s'." % uid)
			return {"error": ERR_CANT_CREATE}
		if resized.get_size() != resolution:
			resized.resize(resolution.x, resolution.y, Image.INTERPOLATE_BILINEAR)
		prepared_images[uid] = resized
	return host._prepare_image_replacement(prepared_images)


## Decode an exact undo snapshot and prepare all derived arrays before restoring it.
static func prepare_png_snapshot(host: MTSSurfaceMaterialPaint, snapshot: Dictionary) -> Dictionary:
	if host._stroke_active:
		push_error("MTSSurfaceMaterialPaint: cannot restore paint during an active stroke.")
		return {"error": ERR_BUSY}
	var pngs_value: Variant = snapshot.get("pngs", {})
	if int(snapshot.get("error", FAILED)) != OK or not pngs_value is Dictionary:
		push_error("MTSSurfaceMaterialPaint: cannot restore an invalid paint snapshot.")
		return {"error": ERR_INVALID_DATA}
	var prepared_images: Dictionary = {}
	for uid_value: Variant in (pngs_value as Dictionary).keys():
		var uid := String(uid_value)
		var bytes_value: Variant = (pngs_value as Dictionary)[uid_value]
		if not bytes_value is PackedByteArray:
			push_error("MTSSurfaceMaterialPaint: snapshot '%s' is not PNG bytes." % uid)
			return {"error": ERR_INVALID_DATA}
		var image := Image.new()
		var load_error := image.load_png_from_buffer(bytes_value as PackedByteArray)
		if load_error != OK:
			push_error(
				"MTSSurfaceMaterialPaint: cannot decode paint snapshot '%s' (%s)."
				% [uid, error_string(load_error)]
			)
			return {"error": load_error}
		if image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
		prepared_images[uid] = image
	return host._prepare_image_replacement(prepared_images)


## Commit one fully prepared canonical image set and its already-created GPU arrays.
static func commit_prepared_images(host: MTSSurfaceMaterialPaint, prepared: Dictionary) -> bool:
	if int(prepared.get("error", FAILED)) != OK:
		push_error("MTSSurfaceMaterialPaint: cannot commit an invalid image replacement.")
		return false
	var images_value: Variant = prepared.get("images", {})
	var states_value: Variant = prepared.get("batch_states", {})
	if not images_value is Dictionary or not states_value is Dictionary:
		push_error("MTSSurfaceMaterialPaint: prepared image replacement is incomplete.")
		return false
	if (states_value as Dictionary).size() != host._batch_records.size():
		push_error("MTSSurfaceMaterialPaint: prepared batch state count is incomplete.")
		return false
	for key_value: Variant in (states_value as Dictionary).keys():
		var batch_key := String(key_value)
		var state_value: Variant = (states_value as Dictionary)[key_value]
		if not state_value is Dictionary or not host._batch_records.has(batch_key):
			push_error(
				"MTSSurfaceMaterialPaint: prepared batch state '%s' is invalid."
				% batch_key
			)
			return false
	host._images_by_uid = (images_value as Dictionary).duplicate()
	for key_value: Variant in (states_value as Dictionary).keys():
		var batch_key := String(key_value)
		var state: Dictionary = (states_value as Dictionary)[key_value]
		host._apply_batch_texture_state(batch_key, state)
	host._dirty_uids.clear()
	host._stroke_before.clear()
	host._stroke_slots_before.clear()
	if host._stroke_rotations_before == null:
		host._stroke_rotations_before = {}
	host._stroke_rotations_before.clear()
	host._stroke_max_weights.clear()
	host._stroke_active = false
	for key_value: Variant in host._batch_records.keys():
		host.batch_texture_changed.emit(String(key_value))
	host.palette_usage_changed.emit()
	return true
