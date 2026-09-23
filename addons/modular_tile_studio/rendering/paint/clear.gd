@tool
extends RefCounted

## Clear behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Remove every authored paint image, rebuild registered batches as neutral, and return its undo patch.
static func clear_all_paint(host: MTSSurfaceMaterialPaint) -> Dictionary:
	var patches := host._build_clear_patches(-1)
	host._images_by_uid.clear()
	host._stroke_before.clear()
	host._stroke_slots_before.clear()
	if host._stroke_rotations_before == null:
		host._stroke_rotations_before = {}
	host._stroke_rotations_before.clear()
	host._stroke_max_weights.clear()
	host._stroke_active = false
	host._dirty_uids.clear()
	for key_value: Variant in host._batch_records.keys():
		var key := String(key_value)
		host._rebuild_batch_texture(key)
		host.batch_texture_changed.emit(key)
	if not patches.is_empty():
		host.palette_usage_changed.emit()
	return patches


## Remove one palette material from every face that carries it and return its undo patch.
##
## Each face may carry the palette entry in a different RGBA slot, so this scans the
## explicit face mappings and clears only the corresponding local component. Slot and
## pixel changes travel in one patch so undo cannot restore one without the other.
static func clear_palette_material(host: MTSSurfaceMaterialPaint, palette_index: int) -> Dictionary:
	if host.profile == null or palette_index < 0 or palette_index >= host.profile.layer_count():
		push_error(
			"MTSSurfaceMaterialPaint: cannot clear missing palette index %d."
			% palette_index
		)
		return {}
	var patches := host._build_palette_clear_patches(palette_index)
	if patches.is_empty():
		return {}
	host.apply_patch(patches, "after")
	var batches_to_rebuild: Dictionary = {}
	for uid_value: Variant in patches.keys():
		var uid := String(uid_value)
		var image := host.image_for_uid(uid)
		if image == null or host._image_has_weight(image):
			continue
		host._images_by_uid.erase(uid)
		host._dirty_uids.erase(uid)
		var batch_key := String(host._batch_key_by_uid.get(uid, ""))
		if not batch_key.is_empty():
			batches_to_rebuild[batch_key] = true
	# A removed empty image changes the GPU array back to its neutral layer; rebuild
	# only the registered batches that contained one of those images.
	for batch_value: Variant in batches_to_rebuild.keys():
		var batch_key := String(batch_value)
		host._rebuild_batch_texture(batch_key)
		host.batch_texture_changed.emit(batch_key)
	return patches


## Build sparse before/after colors for the explicit Clear Brush Paint command.
static func _build_clear_patches(host: MTSSurfaceMaterialPaint, channel: int) -> Dictionary:
	var patches: Dictionary = {}
	for uid_value: Variant in host._images_by_uid.keys():
		var uid := String(uid_value)
		var image := host.image_for_uid(uid)
		if image == null:
			continue
		var pixels := PackedInt32Array()
		var before := PackedColorArray()
		var after := PackedColorArray()
		for y: int in image.get_height():
			for x: int in image.get_width():
				var current := image.get_pixel(x, y)
				var next := (
					Color(0.0, 0.0, 0.0, 0.0)
					if channel < 0
					else host._color_with_component(current, channel, 0.0)
				)
				if next == current:
					continue
				pixels.append(y * image.get_width() + x)
				before.append(current)
				after.append(next)
		if not pixels.is_empty():
			patches[uid] = {
				"resolution": image.get_size(),
				"pixels": pixels,
				"before": before,
				"after": after,
			}
	return patches


## Build one atomic pixel-and-slot patch for removing a palette entry everywhere.
static func _build_palette_clear_patches(host: MTSSurfaceMaterialPaint, palette_index: int) -> Dictionary:
	var patches: Dictionary = {}
	for uid_value: Variant in host._palette_slots_by_uid.keys():
		var uid := String(uid_value)
		var slots := host.palette_slots_for_uid(uid)
		var slot_index := slots.find(palette_index)
		if slot_index < 0:
			continue
		var image := host.image_for_uid(uid)
		var pixels := PackedInt32Array()
		var before := PackedColorArray()
		var after := PackedColorArray()
		var resolution := image.get_size() if image != null else Vector2i.ZERO
		if image != null:
			for y: int in image.get_height():
				for x: int in image.get_width():
					var current := image.get_pixel(x, y)
					var next := host._color_with_component(current, slot_index, 0.0)
					if next == current:
						continue
					pixels.append(y * image.get_width() + x)
					before.append(current)
					after.append(next)
		var after_slots := slots.duplicate()
		after_slots[slot_index] = -1
		var before_rotations := host.slot_rotations_for_uid(uid)
		var after_rotations := before_rotations.duplicate()
		after_rotations[slot_index] = 0
		patches[uid] = {
			"resolution": resolution,
			"pixels": pixels,
			"before": before,
			"after": after,
			"slots_before": slots,
			"slots_after": after_slots,
			"rotations_before": before_rotations,
			"rotations_after": after_rotations,
		}
	return patches


## Return whether one canonical image still contains any material weight after channel removal.
static func _image_has_weight(host: MTSSurfaceMaterialPaint, image: Image) -> bool:
	for y: int in image.get_height():
		for x: int in image.get_width():
			var color := image.get_pixel(x, y)
			if color.r > 0.0 or color.g > 0.0 or color.b > 0.0 or color.a > 0.0:
				return true
	return false
