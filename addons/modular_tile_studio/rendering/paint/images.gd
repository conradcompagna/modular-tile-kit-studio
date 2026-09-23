@tool
extends RefCounted

## Images behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Return one immutable one-layer black array used by completely unpainted batches.
static func neutral_texture(host: MTSSurfaceMaterialPaint) -> Texture2DArray:
	if host._neutral_texture == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.0, 0.0, 0.0, 0.0))
		host._neutral_texture = Texture2DArray.new()
		var error := host._neutral_texture.create_from_images([image])
		if error != OK:
			push_error(
				"MTSSurfaceMaterialPaint: cannot create neutral control array (%s)."
				% error_string(error)
			)
			host._neutral_texture = null
	return host._neutral_texture


## Discard authored paint for faces the canonical terrain no longer owns.
##
## Called when terrain topology is erased. The images are dropped outright rather
## than retained for a later re-fill: the face they described is gone, so keeping
## its pixels would let deleted material reappear under a newly filled cell.
static func discard_paint_for_uids(host: MTSSurfaceMaterialPaint, uids: PackedStringArray) -> void:
	var rebuilt_batches: Dictionary = {}
	for uid: String in uids:
		if not host._images_by_uid.has(uid):
			continue
		var batch_key := String(host._batch_key_by_uid.get(uid, ""))
		host._images_by_uid.erase(uid)
		host._palette_slots_by_uid.erase(uid)
		host._slot_rotations_by_uid.erase(uid)
		host._dirty_uids.erase(uid)
		host._stroke_before.erase(uid)
		host._stroke_slots_before.erase(uid)
		host._stroke_rotations_before.erase(uid)
		host._stroke_max_weights.erase(uid)
		host._rebuild_seeded_batches_for_source(uid)
		if not batch_key.is_empty():
			rebuilt_batches[batch_key] = true
	for batch_value: Variant in rebuilt_batches.keys():
		var batch_key := String(batch_value)
		host._rebuild_batch_texture(batch_key)
		host.batch_texture_changed.emit(batch_key)


## Return whether one placement currently owns authored RGBA pixels.
static func has_image(host: MTSSurfaceMaterialPaint, placement_uid: String) -> bool:
	return host._images_by_uid.has(placement_uid)


## Return the canonical paint image without exposing a duplicate representation.
static func image_for_uid(host: MTSSurfaceMaterialPaint, placement_uid: String) -> Image:
	return host._images_by_uid.get(placement_uid, null) as Image


## Return the mean authored RGBA layer weights for one receiving terrain face.
##
## Palette analysis uses this derived summary to include splat-painted material
## albedos without creating a second stored representation of the paint image.
static func average_weights_for_uid(host: MTSSurfaceMaterialPaint, placement_uid: String) -> Color:
	var image := host.image_for_uid(placement_uid)
	if image == null or image.is_empty():
		return Color(0.0, 0.0, 0.0, 0.0)
	var sum := Color(0.0, 0.0, 0.0, 0.0)
	for y: int in image.get_height():
		for x: int in image.get_width():
			sum += image.get_pixel(x, y)
	var pixel_count := maxi(image.get_width() * image.get_height(), 1)
	return sum / float(pixel_count)
