@tool
extends RefCounted

## Strokes behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Begin one event-rate-independent sparse paint transaction.
static func begin_stroke(host: MTSSurfaceMaterialPaint) -> void:
	if host._stroke_active:
		push_error("MTSSurfaceMaterialPaint: a paint stroke is already active.")
		return
	host._stroke_active = true
	host._stroke_before.clear()
	host._stroke_slots_before.clear()
	if host._stroke_rotations_before == null:
		host._stroke_rotations_before = {}
	host._stroke_rotations_before.clear()
	host._stroke_max_weights.clear()


## Finish one stroke and return its exact sparse pixel-and-slot undo patches.
static func finish_stroke(host: MTSSurfaceMaterialPaint) -> Dictionary:
	if not host._stroke_active:
		return {}
	var patches: Dictionary = {}
	var changed_uids: Dictionary = {}
	for uid_value: Variant in host._stroke_before.keys():
		changed_uids[uid_value] = true
	for uid_value: Variant in host._stroke_slots_before.keys():
		changed_uids[uid_value] = true
	for uid_value: Variant in host._stroke_rotations_before.keys():
		changed_uids[uid_value] = true
	for uid_value: Variant in changed_uids.keys():
		var uid := String(uid_value)
		var image := host.image_for_uid(uid)
		var before_by_pixel: Dictionary = host._stroke_before.get(uid, {})
		var encoded_pixels := before_by_pixel.keys()
		encoded_pixels.sort()
		var pixels := PackedInt32Array()
		var before := PackedColorArray()
		var after := PackedColorArray()
		if image != null:
			for encoded_value: Variant in encoded_pixels:
				var encoded := int(encoded_value)
				var pixel := Vector2i(
					encoded % image.get_width(),
					floori(float(encoded) / float(image.get_width()))
				)
				pixels.append(encoded)
				before.append(before_by_pixel[encoded_value])
				after.append(image.get_pixel(pixel.x, pixel.y))
		var slots_before: PackedInt32Array = host._stroke_slots_before.get(
			uid,
			host.palette_slots_for_uid(uid)
		)
		var rotations_before: PackedInt32Array = host._stroke_rotations_before.get(
			uid,
			host.slot_rotations_for_uid(uid)
		)
		patches[uid] = {
			"resolution": image.get_size() if image != null else Vector2i.ZERO,
			"pixels": pixels,
			"before": before,
			"after": after,
			"slots_before": slots_before,
			"slots_after": host.palette_slots_for_uid(uid),
			"rotations_before": rotations_before,
			"rotations_after": host.slot_rotations_for_uid(uid),
		}
	host._stroke_active = false
	host._stroke_before.clear()
	host._stroke_slots_before.clear()
	host._stroke_rotations_before.clear()
	host._stroke_max_weights.clear()
	if not patches.is_empty():
		host.palette_usage_changed.emit()
	return {"patches": patches} if not patches.is_empty() else {}


## Cancel the recorder without changing pixels when an external owner aborts input.
static func cancel_stroke_recording(host: MTSSurfaceMaterialPaint) -> void:
	host._stroke_active = false
	host._stroke_before.clear()
	host._stroke_slots_before.clear()
	host._stroke_rotations_before.clear()
	host._stroke_max_weights.clear()


## Apply one sparse undo/redo payload and queue only affected pixels and batches.
static func apply_patch(host: MTSSurfaceMaterialPaint, patches: Dictionary, value_key: String) -> void:
	if value_key != "before" and value_key != "after":
		push_error("MTSSurfaceMaterialPaint: patch value key must be 'before' or 'after'.")
		return
	for uid_value: Variant in patches.keys():
		var uid := String(uid_value)
		var patch: Dictionary = patches[uid_value]
		var resolution_value: Variant = patch.get("resolution", Vector2i.ZERO)
		var pixels_value: Variant = patch.get("pixels", PackedInt32Array())
		var colors_value: Variant = patch.get(value_key, PackedColorArray())
		var slots_value: Variant = patch.get(
			"slots_%s" % value_key,
			host.palette_slots_for_uid(uid)
		)
		var rotations_value: Variant = patch.get(
			"rotations_%s" % value_key,
			host.slot_rotations_for_uid(uid)
		)
		if (
			not resolution_value is Vector2i
			or not pixels_value is PackedInt32Array
			or not colors_value is PackedColorArray
			or not slots_value is PackedInt32Array
			or not rotations_value is PackedInt32Array
		):
			push_error("MTSSurfaceMaterialPaint: invalid sparse patch for '%s'." % uid)
			continue
		var slots: PackedInt32Array = slots_value
		var rotations: PackedInt32Array = rotations_value
		if (
			slots.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
			or rotations.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL
		):
			push_error("MTSSurfaceMaterialPaint: undo material mapping is invalid for '%s'." % uid)
			continue
		host._set_palette_slots(uid, slots, false)
		host._set_slot_rotations(uid, rotations, false)
		var resolution: Vector2i = resolution_value
		var pixels: PackedInt32Array = pixels_value
		var colors: PackedColorArray = colors_value
		if pixels.size() != colors.size() or pixels.is_empty():
			continue
		var image := host.image_for_uid(uid)
		var batch_texture_created := false
		if image == null:
			image = Image.create(
				resolution.x,
				resolution.y,
				false,
				Image.FORMAT_RGBA8
			)
			image.fill(Color(0.0, 0.0, 0.0, 0.0))
			host._images_by_uid[uid] = image
			batch_texture_created = host._ensure_registered_batch_texture(uid)
		if image.get_size() != resolution:
			push_error("MTSSurfaceMaterialPaint: undo resolution does not match '%s'." % uid)
			continue
		for index: int in pixels.size():
			var encoded := pixels[index]
			var pixel := Vector2i(
				encoded % resolution.x,
				floori(float(encoded) / float(resolution.x))
			)
			image.set_pixel(pixel.x, pixel.y, colors[index])
		if value_key == "after" and not host._image_has_weight(image):
			host._images_by_uid.erase(uid)
			host._dirty_uids.erase(uid)
			var batch_key := String(host._batch_key_by_uid.get(uid, ""))
			if not batch_key.is_empty():
				host._rebuild_batch_texture(batch_key)
				host.batch_texture_changed.emit(batch_key)
		else:
			if not batch_texture_created:
				host._dirty_uids[uid] = true
		host.paint_changed.emit(uid)
	if not patches.is_empty():
		host.palette_usage_changed.emit()
