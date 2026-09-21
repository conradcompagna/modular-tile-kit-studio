@tool
extends RefCounted

## Batches behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Register one derived terrain-face batch without allocating paint for it.
##
## Batches are keyed by the canonical TerrainMesh face UIDs the caller is drawing,
## so paint identity is the terrain's own identity and no placement record stands
## between the two. A Texture2DArray is created only when this batch already has
## authored paint.
static func register_batch(host: MTSSurfaceMaterialPaint,
	batch_key: String,
	face_uids: PackedStringArray,
	footprint_m: Vector2i,
	seed_uid_by_uid: Dictionary = {}
) -> void:
	if batch_key.is_empty():
		push_error("MTSSurfaceMaterialPaint: cannot register an empty batch key.")
		return
	var uids := PackedStringArray()
	var valid_seeds: Dictionary = {}
	for uid: String in face_uids:
		if uid.is_empty():
			continue
		uids.append(uid)
		var seed_uid := String(seed_uid_by_uid.get(uid, ""))
		if not seed_uid.is_empty() and seed_uid != uid:
			valid_seeds[uid] = seed_uid
		host.register_face_palette(uid, seed_uid)
		host._batch_key_by_uid[uid] = batch_key
	host._batch_records[batch_key] = {
		"uids": uids,
		"footprint_m": footprint_m,
		"seed_uid_by_uid": valid_seeds,
		"texture": null,
		"layer_by_uid": {},
		"resolution": Vector2i.ZERO,
		"multimesh": null,
		"instance_indices_by_uid": {},
	}
	if host._batch_has_authored_paint(uids, valid_seeds):
		host._rebuild_batch_texture(batch_key)


## Unregister a removed derived batch while retaining paint for undo or movement.
static func unregister_batch(host: MTSSurfaceMaterialPaint, batch_key: String) -> void:
	if not host._batch_records.has(batch_key):
		return
	var record: Dictionary = host._batch_records[batch_key]
	var uids: PackedStringArray = record.get("uids", PackedStringArray())
	for uid: String in uids:
		if String(host._batch_key_by_uid.get(uid, "")) == batch_key:
			host._batch_key_by_uid.erase(uid)
	host._batch_records.erase(batch_key)


## Return the current array texture for one batch or the exact neutral array.
static func batch_texture(host: MTSSurfaceMaterialPaint, batch_key: String) -> Texture2DArray:
	var record: Dictionary = host._batch_records.get(batch_key, {})
	var texture := record.get("texture", null) as Texture2DArray
	return texture if texture != null else host.neutral_texture()


## Classify one face's complete control image without changing its canonical pixels.
##
## The result is `(class, uniform_slot)`. A uniform layer is reported only when
## every texel has the same component at least `1 - 4/255` and all competing
## components are encoding noise. Any partial coverage remains mixed so the
## shader continues to sample the exact authored control image.
static func control_classification_for_uid(host: MTSSurfaceMaterialPaint, placement_uid: String) -> Vector2i:
	var batch_key := String(host._batch_key_by_uid.get(placement_uid, ""))
	var record: Dictionary = host._batch_records.get(batch_key, {})
	var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
	var image := host._visible_image_for_uid(placement_uid, host._images_by_uid, seed_uid_by_uid)
	if image == null or image.is_empty():
		return Vector2i(MTSSurfaceMaterialPaint.CONTROL_CLASS_BASE_ONLY, -1)
	var uniform_slot := -1
	var saw_empty_texel := false
	for y: int in image.get_height():
		for x: int in image.get_width():
			var pixel := image.get_pixel(x, y)
			var active_slot := -1
			for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
				var weight := host._color_component(pixel, slot_index)
				if weight <= MTSSurfaceMaterialPaint.SPLATMAP_EMPTY_COMPONENT_THRESHOLD:
					continue
				if active_slot >= 0 or weight < 1.0 - MTSSurfaceMaterialPaint.SPLATMAP_EMPTY_COMPONENT_THRESHOLD:
					return Vector2i(MTSSurfaceMaterialPaint.CONTROL_CLASS_MIXED, -1)
				active_slot = slot_index
			if active_slot < 0:
				saw_empty_texel = true
				if uniform_slot >= 0:
					return Vector2i(MTSSurfaceMaterialPaint.CONTROL_CLASS_MIXED, -1)
				continue
			if saw_empty_texel:
				return Vector2i(MTSSurfaceMaterialPaint.CONTROL_CLASS_MIXED, -1)
			if uniform_slot < 0:
				uniform_slot = active_slot
			elif uniform_slot != active_slot:
				return Vector2i(MTSSurfaceMaterialPaint.CONTROL_CLASS_MIXED, -1)
	if uniform_slot < 0:
		return Vector2i(MTSSurfaceMaterialPaint.CONTROL_CLASS_BASE_ONLY, -1)
	return Vector2i(MTSSurfaceMaterialPaint.CONTROL_CLASS_UNIFORM_LAYER, uniform_slot)


## Encode the control-array layer, fast-path class, and uniform slot in MultiMesh COLOR.
##
## Red and green retain the existing 16-bit array layer. Blue stores the class in
## three exact normalized states, while alpha stores the uniform RGBA slot. Every
## triangle of one face receives identical values, so the shader reads them flat.
static func instance_layer_color(host: MTSSurfaceMaterialPaint, batch_key: String, placement_uid: String) -> Color:
	var record: Dictionary = host._batch_records.get(batch_key, {})
	var layer_by_uid: Dictionary = record.get("layer_by_uid", {})
	var layer := int(layer_by_uid.get(placement_uid, 0))
	var classification := host.control_classification_for_uid(placement_uid)
	var uniform_slot := maxi(classification.y, 0)
	return Color(
		float(layer & 255) / 255.0,
		float((layer >> 8) & 255) / 255.0,
		float(classification.x) / 2.0,
		float(uniform_slot) / 3.0
	)


## Bind one derived MultiMesh to its face UIDs so paint edits refresh fast-path metadata in place.
static func bind_batch_instance_colors(host: MTSSurfaceMaterialPaint,
	batch_key: String,
	multimesh: MultiMesh,
	instance_indices_by_uid: Dictionary
) -> void:
	if not host._batch_records.has(batch_key):
		push_error("MTSSurfaceMaterialPaint: cannot bind instance colors for unknown batch '%s'." % batch_key)
		return
	var record: Dictionary = host._batch_records[batch_key]
	record["multimesh"] = multimesh
	record["instance_indices_by_uid"] = instance_indices_by_uid
	host._batch_records[batch_key] = record
	host._refresh_batch_instance_colors(batch_key)


## Upload every touched placement once for the current frame and nothing else.
static func upload_dirty(host: MTSSurfaceMaterialPaint) -> int:
	var uploaded := 0
	var dirty := host._dirty_uids.keys()
	host._dirty_uids.clear()
	for uid_value: Variant in dirty:
		var uid := String(uid_value)
		var batch_key := String(host._batch_key_by_uid.get(uid, ""))
		if batch_key.is_empty():
			continue
		var record: Dictionary = host._batch_records.get(batch_key, {})
		var texture := record.get("texture", null) as Texture2DArray
		var layer_by_uid: Dictionary = record.get("layer_by_uid", {})
		var layer := int(layer_by_uid.get(uid, -1))
		var image := host.image_for_uid(uid)
		if texture == null or layer < 0 or image == null:
			continue
		texture.update_layer(image, layer)
		host._refresh_instance_colors_for_uid(uid)
		uploaded += 1
		uploaded += host._upload_seeded_layers(uid, image)
	return uploaded


## Allocate a batch array when its first placement becomes painted and report whether it already contains the new pixels.
static func _ensure_registered_batch_texture(host: MTSSurfaceMaterialPaint, placement_uid: String) -> bool:
	var batch_key := String(host._batch_key_by_uid.get(placement_uid, ""))
	if batch_key.is_empty():
		return false
	var record: Dictionary = host._batch_records.get(batch_key, {})
	if record.get("texture", null) != null:
		return false
	if not host._rebuild_batch_texture(batch_key):
		return false
	host.batch_texture_changed.emit(batch_key)
	return true


## Rebuild one derived array after load or structural membership changes.
static func _rebuild_batch_texture(host: MTSSurfaceMaterialPaint, batch_key: String) -> bool:
	var state := host._build_batch_texture_state(batch_key, host._images_by_uid)
	if int(state.get("error", FAILED)) != OK:
		return false
	host._apply_batch_texture_state(batch_key, state)
	host._refresh_batch_instance_colors(batch_key)
	return true


## Prepare every registered batch texture against one candidate canonical image dictionary.
static func _prepare_image_replacement(host: MTSSurfaceMaterialPaint, prepared_images: Dictionary) -> Dictionary:
	for uid_value: Variant in prepared_images.keys():
		var uid := String(uid_value)
		if not host._batch_key_by_uid.has(uid):
			push_error(
				"MTSSurfaceMaterialPaint: replacement contains unregistered placement '%s'."
				% uid
			)
			return {"error": ERR_DOES_NOT_EXIST}
	var batch_states: Dictionary = {}
	for key_value: Variant in host._batch_records.keys():
		var batch_key := String(key_value)
		var state := host._build_batch_texture_state(batch_key, prepared_images)
		if int(state.get("error", FAILED)) != OK:
			return {"error": int(state.get("error", FAILED))}
		batch_states[batch_key] = state
	return {
		"error": OK,
		"images": prepared_images,
		"batch_states": batch_states,
	}


## Build one Texture2DArray state without mutating its live batch record.
static func _build_batch_texture_state(host: MTSSurfaceMaterialPaint,
	batch_key: String,
	images_by_uid: Dictionary
) -> Dictionary:
	if not host._batch_records.has(batch_key):
		push_error("MTSSurfaceMaterialPaint: batch '%s' is not registered." % batch_key)
		return {"error": ERR_DOES_NOT_EXIST}
	var record: Dictionary = host._batch_records[batch_key]
	var uids: PackedStringArray = record.get("uids", PackedStringArray())
	var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
	if not host._batch_has_authored_paint_in(uids, images_by_uid, seed_uid_by_uid):
		return {
			"error": OK,
			"texture": null,
			"layer_by_uid": {},
			"resolution": Vector2i.ZERO,
		}
	var resolution := Vector2i.ZERO
	for uid: String in uids:
		var existing := host._visible_image_for_uid(uid, images_by_uid, seed_uid_by_uid)
		if existing != null:
			resolution = existing.get_size()
			break
	if resolution.x <= 0 or resolution.y <= 0:
		push_error("MTSSurfaceMaterialPaint: batch '%s' has no valid paint resolution." % batch_key)
		return {"error": ERR_INVALID_DATA}
	var images: Array[Image] = []
	var layer_by_uid: Dictionary = {}
	for index: int in uids.size():
		var uid := uids[index]
		var image := host._visible_image_for_uid(uid, images_by_uid, seed_uid_by_uid)
		if image == null:
			image = Image.create(
				resolution.x,
				resolution.y,
				false,
				Image.FORMAT_RGBA8
			)
			image.fill(Color(0.0, 0.0, 0.0, 0.0))
		elif image.get_size() != resolution:
			push_error(
				(
					"MTSSurfaceMaterialPaint: batch '%s' contains mixed paint resolutions; "
					+ "use the visible resolution rebuild before painting."
				) % batch_key
			)
			return {"error": ERR_INVALID_DATA}
		images.append(image)
		layer_by_uid[uid] = index
	var texture := Texture2DArray.new()
	var create_error := texture.create_from_images(images)
	if create_error != OK:
		push_error(
			"MTSSurfaceMaterialPaint: cannot create batch array '%s' (%s)."
			% [batch_key, error_string(create_error)]
		)
		return {"error": create_error}
	return {
		"error": OK,
		"texture": texture,
		"layer_by_uid": layer_by_uid,
		"resolution": resolution,
	}


## Replace only derived texture fields in one already-registered batch record.
static func _apply_batch_texture_state(host: MTSSurfaceMaterialPaint, batch_key: String, state: Dictionary) -> void:
	var record: Dictionary = host._batch_records[batch_key]
	record["texture"] = state.get("texture", null)
	record["layer_by_uid"] = state.get("layer_by_uid", {})
	record["resolution"] = state.get("resolution", Vector2i.ZERO)
	host._batch_records[batch_key] = record


## Refresh every triangle's control fast-path metadata after a structural batch change.
static func _refresh_batch_instance_colors(host: MTSSurfaceMaterialPaint, batch_key: String) -> void:
	var record: Dictionary = host._batch_records.get(batch_key, {})
	var multimesh := record.get("multimesh", null) as MultiMesh
	if multimesh == null:
		return
	var indices_by_uid: Dictionary = record.get("instance_indices_by_uid", {})
	for uid_value: Variant in indices_by_uid.keys():
		host._refresh_instance_colors_for_uid(String(uid_value))


## Refresh only the triangles owned by one changed face after a paint upload.
static func _refresh_instance_colors_for_uid(host: MTSSurfaceMaterialPaint, placement_uid: String) -> void:
	var batch_key := String(host._batch_key_by_uid.get(placement_uid, ""))
	var record: Dictionary = host._batch_records.get(batch_key, {})
	var multimesh := record.get("multimesh", null) as MultiMesh
	if multimesh == null:
		return
	var indices_by_uid: Dictionary = record.get("instance_indices_by_uid", {})
	var indices_value: Variant = indices_by_uid.get(placement_uid, PackedInt32Array())
	if not indices_value is PackedInt32Array:
		return
	var color := host.instance_layer_color(batch_key, placement_uid)
	for instance_index: int in indices_value as PackedInt32Array:
		if instance_index >= 0 and instance_index < multimesh.instance_count:
			multimesh.set_instance_color(instance_index, color)


## Return the canonical metric footprint registered for one placement.
static func _registered_footprint(host: MTSSurfaceMaterialPaint, placement_uid: String) -> Vector2i:
	var batch_key := String(host._batch_key_by_uid.get(placement_uid, ""))
	if batch_key.is_empty() or not host._batch_records.has(batch_key):
		return Vector2i.ZERO
	var record: Dictionary = host._batch_records[batch_key]
	return record.get("footprint_m", Vector2i.ZERO) as Vector2i


## Return whether one registered batch has direct paint or an enabled derived side seed.
static func _batch_has_authored_paint(host: MTSSurfaceMaterialPaint,
	uids: PackedStringArray,
	seed_uid_by_uid: Dictionary = {}
) -> bool:
	return host._batch_has_authored_paint_in(uids, host._images_by_uid, seed_uid_by_uid)


## Return whether the supplied image dictionary can visibly paint any batch placement.
static func _batch_has_authored_paint_in(host: MTSSurfaceMaterialPaint,
	uids: PackedStringArray,
	images_by_uid: Dictionary,
	seed_uid_by_uid: Dictionary = {}
) -> bool:
	for uid: String in uids:
		if host._visible_image_for_uid(uid, images_by_uid, seed_uid_by_uid) != null:
			return true
	return false


## Return a face's manual paint first, otherwise its explicit thin-side source image.
##
## The caller supplies seed mappings only while the visible board option is enabled.
## This keeps the full square canonical, lets manual sliver paint override it, and
## avoids copying another independent paint image into the board.
static func _visible_image_for_uid(host: MTSSurfaceMaterialPaint,
	uid: String,
	images_by_uid: Dictionary,
	seed_uid_by_uid: Dictionary
) -> Image:
	var manual_image := images_by_uid.get(uid, null) as Image
	if manual_image != null:
		return manual_image
	var seed_uid := String(seed_uid_by_uid.get(uid, ""))
	return images_by_uid.get(seed_uid, null) as Image if not seed_uid.is_empty() else null


## Upload every unpainted thin-side layer that visibly resolves from one changed source image.
static func _upload_seeded_layers(host: MTSSurfaceMaterialPaint, source_uid: String, source_image: Image) -> int:
	var uploaded := 0
	for record_value: Variant in host._batch_records.values():
		var record: Dictionary = record_value
		var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
		var texture := record.get("texture", null) as Texture2DArray
		var layer_by_uid: Dictionary = record.get("layer_by_uid", {})
		if texture == null:
			continue
		for target_value: Variant in seed_uid_by_uid.keys():
			var target_uid := String(target_value)
			if (
				String(seed_uid_by_uid[target_value]) != source_uid
				or host._images_by_uid.has(target_uid)
			):
				continue
			var layer := int(layer_by_uid.get(target_uid, -1))
			if layer < 0:
				continue
			texture.update_layer(source_image, layer)
			host._refresh_instance_colors_for_uid(target_uid)
			uploaded += 1
	return uploaded


## Rebuild every derived batch that loses an explicit thin-side source image.
static func _rebuild_seeded_batches_for_source(host: MTSSurfaceMaterialPaint, source_uid: String) -> void:
	for batch_key_value: Variant in host._batch_records.keys():
		var batch_key := String(batch_key_value)
		var record: Dictionary = host._batch_records[batch_key]
		var seed_uid_by_uid: Dictionary = record.get("seed_uid_by_uid", {})
		for target_value: Variant in seed_uid_by_uid.keys():
			if String(seed_uid_by_uid[target_value]) != source_uid:
				continue
			host._rebuild_batch_texture(batch_key)
			host.batch_texture_changed.emit(batch_key)
			break
