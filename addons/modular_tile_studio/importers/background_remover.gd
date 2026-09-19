@tool
class_name BackgroundRemover
extends RefCounted

## Exact, edge-connected background removal for imported PNG surfaces.
##
## Ported from the HTML level editor's decal cropper, and deliberately kept
## EXACT rather than tolerance-based. The images this tool imports are generated
## art on a flat backdrop, so the background is one literal colour: matching it
## exactly removes the backdrop and nothing else. A tolerance would start eating
## into the artwork's own darks the moment the backdrop and the art share a
## family of colours, and it would do so invisibly.
##
## The fill starts from the border and only reaches inward through matching
## pixels, so an enclosed region of the same colour -- a window in a wall, the
## sky inside an archway -- survives, because it is not connected to the edge.

## Write one RGBA image's alpha channel out as a standalone coverage mask.
##
## Visible transparency is stored as its OWN canonical GBuffer channel rather than
## being left inside the albedo image, because the map analysis pipeline rewrites
## the derived albedo as RGB. An alpha baked only into that image is therefore
## discarded the first time an asset is analyzed, which is exactly how a
## background-removed surface came back as an opaque black rectangle.
##
## The `alpha` channel is consumed as a greyscale mask read from the RED
## component, so coverage is written into R, G and B and the mask file itself is
## left fully opaque.
static func write_alpha_mask(source: Image, out_path: String) -> bool:
	if source == null or source.is_empty():
		push_error("[Tile Studio] cannot write an alpha mask from a missing image.")
		return false
	if out_path.is_empty():
		push_error("[Tile Studio] cannot write an alpha mask without a target path.")
		return false
	var rgba := source.duplicate() as Image
	if rgba.is_compressed() and rgba.decompress() != OK:
		push_error("[Tile Studio] cannot decompress art to extract its alpha for '%s'." % out_path)
		return false
	rgba.convert(Image.FORMAT_RGBA8)
	var mask := Image.create_empty(
		rgba.get_width(),
		rgba.get_height(),
		false,
		Image.FORMAT_RGBA8
	)
	for y: int in rgba.get_height():
		for x: int in rgba.get_width():
			var coverage := rgba.get_pixel(x, y).a
			mask.set_pixel(x, y, Color(coverage, coverage, coverage, 1.0))
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(out_path.get_base_dir())
	)
	if mask.save_png(ProjectSettings.globalize_path(out_path)) != OK:
		push_error("[Tile Studio] could not write alpha mask '%s'." % out_path)
		return false
	return true


## Result of a removal: the processed image plus what was done to it.
##
## Reported rather than returned silently so the caller can tell the user how
## much was removed and refuse a run that would erase the whole image.
class Result extends RefCounted:
	var image: Image
	var removed_pixels: int = 0
	var background_is_transparent: bool = false
	var background_color: Color = Color(0, 0, 0, 0)
	var crop_rect: Rect2i = Rect2i()
	var source_size: Vector2i = Vector2i.ZERO
	var error: String = ""

	func ok() -> bool:
		return error.is_empty() and image != null

	## Human-readable account of what was treated as background.
	func background_description() -> String:
		if background_is_transparent:
			return "already transparent"
		return "#" + background_color.to_html(false)

	## Fraction of the source the background occupied, 0..1.
	func removed_fraction() -> float:
		var total := source_size.x * source_size.y
		if total <= 0:
			return 0.0
		return float(removed_pixels) / float(total)


## Strip the edge-connected background from `source` and crop to what remains.
##
## `crop` trims the result to the bounding box of the surviving pixels. That is
## usually what you want for a prop-like cutout, but it changes the image's
## aspect -- for a tile whose metre size is already chosen, pass false so the
## art stays registered to its original frame.
static func remove_background(source: Image, crop: bool = true) -> Result:
	var result := Result.new()
	if source == null or source.is_empty():
		result.error = "no image"
		return result

	var image := source.duplicate() as Image
	# The fill compares and writes RGBA8 directly; anything else (indexed, RGB,
	# 16-bit) has to be normalised first or get_pixel/set_pixel quantise
	# differently on the way in and out.
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)

	var width := image.get_width()
	var height := image.get_height()
	result.source_size = Vector2i(width, height)

	var background := _dominant_border_color(image)
	result.background_is_transparent = background.a <= 0.0
	result.background_color = background

	# Flood fill inward from every border pixel that matches the background.
	var visited := PackedByteArray()
	visited.resize(width * height)
	var queue := PackedInt32Array()
	var head := 0

	for index in _border_indices(width, height):
		var x := index % width
		var y := index / width
		if visited[index] == 1:
			continue
		if not _matches(image.get_pixel(x, y), background):
			continue
		visited[index] = 1
		queue.append(index)

	while head < queue.size():
		var index := queue[head]
		head += 1
		var x := index % width
		var y := index / width
		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var nx: int = x + offset.x
			var ny: int = y + offset.y
			if nx < 0 or ny < 0 or nx >= width or ny >= height:
				continue
			var neighbour: int = ny * width + nx
			if visited[neighbour] == 1:
				continue
			if not _matches(image.get_pixel(nx, ny), background):
				continue
			visited[neighbour] = 1
			queue.append(neighbour)

	# Clear the whole connected background in one pass. Colour is zeroed along
	# with alpha so bilinear filtering cannot bleed the old backdrop back in as a
	# halo around the cut edge.
	var removed := 0
	for y in height:
		for x in width:
			if visited[y * width + x] == 1:
				image.set_pixel(x, y, Color(0, 0, 0, 0))
				removed += 1
	result.removed_pixels = removed

	var bounds := _opaque_bounds(image)
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		result.error = "removing the background would erase the whole image"
		return result
	result.crop_rect = bounds

	if crop and bounds != Rect2i(0, 0, width, height):
		image = image.get_region(bounds)

	result.image = image
	return result


## The colour the border is mostly made of.
##
## A majority vote over the border rather than a single corner sample: one
## stray pixel -- a signature, a compression artefact, a bit of art running to
## the edge -- would otherwise pick the background for the whole image.
static func _dominant_border_color(image: Image) -> Color:
	var counts := {}
	var width := image.get_width()
	var best_key := ""
	var best_count := 0
	var best_color := Color(0, 0, 0, 0)
	for index in _border_indices(width, image.get_height()):
		var pixel := image.get_pixel(index % width, index / width)
		# Every fully transparent pixel is the same background regardless of the
		# RGB the encoder happened to leave underneath it.
		var key := "transparent" if pixel.a <= 0.0 else _color_key(pixel)
		var count: int = int(counts.get(key, 0)) + 1
		counts[key] = count
		if count > best_count:
			best_count = count
			best_key = key
			best_color = Color(0, 0, 0, 0) if key == "transparent" else pixel
	return best_color


## Indices of every pixel on the outer ring of the image.
static func _border_indices(width: int, height: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for x in width:
		out.append(x)
		if height > 1:
			out.append((height - 1) * width + x)
	for y in range(1, maxi(1, height - 1)):
		out.append(y * width)
		if width > 1:
			out.append(y * width + width - 1)
	return out


## Exact match against the background, in 8-bit terms.
##
## Compared at byte resolution rather than with Color's floats: the pixels came
## from an 8-bit PNG, so two texels that encode the same byte must compare
## equal even after the float round-trip.
static func _matches(pixel: Color, background: Color) -> bool:
	if background.a <= 0.0:
		return pixel.a <= 0.0
	return _color_key(pixel) == _color_key(background)


static func _color_key(color: Color) -> String:
	return "%d,%d,%d,%d" % [
		roundi(color.r * 255.0), roundi(color.g * 255.0),
		roundi(color.b * 255.0), roundi(color.a * 255.0)
	]


## Bounding box of everything still visible. Empty size means nothing survived.
static func _opaque_bounds(image: Image) -> Rect2i:
	var width := image.get_width()
	var height := image.get_height()
	var min_x := width
	var min_y := height
	var max_x := -1
	var max_y := -1
	for y in height:
		for x in width:
			if image.get_pixel(x, y).a <= 0.0:
				continue
			min_x = mini(min_x, x)
			min_y = mini(min_y, y)
			max_x = maxi(max_x, x)
			max_y = maxi(max_y, y)
	if max_x < min_x or max_y < min_y:
		return Rect2i(0, 0, 0, 0)
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
