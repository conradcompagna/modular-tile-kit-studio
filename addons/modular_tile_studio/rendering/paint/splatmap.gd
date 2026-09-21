@tool
extends RefCounted

## Splatmap behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Return the canonical two-dimensional rectangle for one validated directional face set.
##
## This resolves only the explicit projection lattice the control image is stretched across;
## it reads no pixels and allocates no images. Individual face weights are sampled later.
static func splatmap_terrain_bounds(host: MTSSurfaceMaterialPaint, targets: Array[Dictionary]) -> Dictionary:
	if host.profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot resolve splatmap bounds without a profile.")
		return {"error": ERR_UNCONFIGURED}
	if targets.is_empty():
		push_error("MTSSurfaceMaterialPaint: the selected projection has no terrain faces.")
		return {"error": ERR_DOES_NOT_EXIST}
	var minimum_cell := Vector2i(2147483647, 2147483647)
	var maximum_cell := Vector2i(-2147483648, -2147483648)
	for target: Dictionary in targets:
		var uid := String(target.get("uid", ""))
		var cell_value: Variant = target.get("projection_cell", null)
		if uid.is_empty() or not cell_value is Vector2i or not host._batch_key_by_uid.has(uid):
			push_error("MTSSurfaceMaterialPaint: splatmap target is not a registered projected face.")
			return {"error": ERR_INVALID_DATA}
		var cell := cell_value as Vector2i
		minimum_cell = minimum_cell.min(cell)
		maximum_cell = maximum_cell.max(cell)
	var terrain_size := maximum_cell - minimum_cell + Vector2i.ONE
	if terrain_size.x <= 0 or terrain_size.y <= 0:
		return {"error": ERR_INVALID_DATA}
	return {
		"error": OK,
		"terrain_bounds": Rect2i(minimum_cell, terrain_size),
		"face_count": targets.size(),
	}


## Return one readable RGBA8 control source with the requested empty-region policy applied.
##
## When extension is enabled, a deterministic eight-neighbour wavefront copies each nearest
## valid source texel into zero-weight regions. Live channel strengths remain shader state and
## therefore never change which source pixels count as authored colour.
static func prepare_splatmap_source(host: MTSSurfaceMaterialPaint,
	source_image: Image,
	active_channels: PackedByteArray,
	fill_empty_regions: bool,
	empty_region_channel: int
) -> Image:
	if source_image == null or source_image.is_empty():
		push_error("MTSSurfaceMaterialPaint: cannot prepare an empty splatmap image.")
		return null
	if active_channels.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: splatmap preparation requires four channel states.")
		return null
	var readable := source_image.duplicate() as Image
	if readable == null:
		return null
	if readable.is_compressed():
		var decompress_error := readable.decompress()
		if decompress_error != OK:
			push_error(
				"MTSSurfaceMaterialPaint: cannot decompress splatmap (%s)."
				% error_string(decompress_error)
			)
			return null
	if readable.get_format() != Image.FORMAT_RGBA8:
		readable.convert(Image.FORMAT_RGBA8)
	var fitted_source := host._crop_empty_splatmap_border(readable, active_channels)
	if fitted_source == null:
		return null
	if not fill_empty_regions:
		return fitted_source
	return host._fill_empty_splatmap_regions(
		fitted_source,
		active_channels,
		empty_region_channel
	)


## Crop only the fully empty outer frame so source content meets the terrain footprint exactly.
##
## Internal black regions remain canonical native weights. The crop uses the same explicit
## active-channel threshold as optional base filling, so preview and authored tiles stay aligned.
static func _crop_empty_splatmap_border(host: MTSSurfaceMaterialPaint,
	source_image: Image,
	active_channels: PackedByteArray
) -> Image:
	var left := 0
	var right := source_image.get_width() - 1
	var top := 0
	var bottom := source_image.get_height() - 1
	while left <= right and host._splatmap_column_is_empty(source_image, left, active_channels):
		left += 1
	while right >= left and host._splatmap_column_is_empty(source_image, right, active_channels):
		right -= 1
	if left > right:
		push_error(
			"MTSSurfaceMaterialPaint: splatmap has no visible weights in its assigned channels."
		)
		return null
	while top <= bottom and host._splatmap_row_is_empty(
		source_image,
		top,
		left,
		right,
		active_channels
	):
		top += 1
	while bottom >= top and host._splatmap_row_is_empty(
		source_image,
		bottom,
		left,
		right,
		active_channels
	):
		bottom -= 1
	var occupied_region := Rect2i(
		Vector2i(left, top),
		Vector2i(right - left + 1, bottom - top + 1)
	)
	if occupied_region.position == Vector2i.ZERO and occupied_region.size == source_image.get_size():
		return source_image
	var cropped := source_image.get_region(occupied_region)
	if cropped == null or cropped.is_empty():
		push_error("MTSSurfaceMaterialPaint: occupied splatmap border crop is empty.")
		return null
	return cropped


## Return whether one source column contains no visible assigned-channel weight.
static func _splatmap_column_is_empty(host: MTSSurfaceMaterialPaint,
	source_image: Image,
	column: int,
	active_channels: PackedByteArray
) -> bool:
	for pixel_y: int in source_image.get_height():
		if (
			host._strongest_active_splat_component(
				source_image.get_pixel(column, pixel_y),
				active_channels
			)
			> MTSSurfaceMaterialPaint.SPLATMAP_EMPTY_COMPONENT_THRESHOLD
		):
			return false
	return true


## Return whether one fitted source row contains no visible assigned-channel weight.
static func _splatmap_row_is_empty(host: MTSSurfaceMaterialPaint,
	source_image: Image,
	row: int,
	left: int,
	right: int,
	active_channels: PackedByteArray
) -> bool:
	for pixel_x: int in range(left, right + 1):
		if (
			host._strongest_active_splat_component(
				source_image.get_pixel(pixel_x, row),
				active_channels
			)
			> MTSSurfaceMaterialPaint.SPLATMAP_EMPTY_COMPONENT_THRESHOLD
		):
			return false
	return true


## Return the strongest assigned component used by border fitting and empty-region filling.
static func _strongest_active_splat_component(host: MTSSurfaceMaterialPaint,
	weight: Color,
	active_channels: PackedByteArray
) -> float:
	var strongest := 0.0
	if active_channels[0] != 0:
		strongest = maxf(strongest, weight.r)
	if active_channels[1] != 0:
		strongest = maxf(strongest, weight.g)
	if active_channels[2] != 0:
		strongest = maxf(strongest, weight.b)
	if active_channels[3] != 0:
		strongest = maxf(strongest, weight.a)
	return strongest


## Replace every effectively black source texel with one explicit base channel.
##
## A small per-component threshold treats PNG encoding noise as black while preserving all
## visibly weighted pixels. Direct assignment avoids the seams produced by nearest-seed waves.
static func _fill_empty_splatmap_regions(host: MTSSurfaceMaterialPaint,
	source_image: Image,
	active_channels: PackedByteArray,
	empty_region_channel: int
) -> Image:
	if empty_region_channel < 0 or empty_region_channel >= MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: empty-region base channel is outside R/G/B/A.")
		return null
	if active_channels[empty_region_channel] == 0:
		push_error(
			"MTSSurfaceMaterialPaint: empty-region base channel %d has no assigned material."
			% empty_region_channel
		)
		return null
	var base_weight := Color(0.0, 0.0, 0.0, 0.0)
	match empty_region_channel:
		0:
			base_weight.r = 1.0
		1:
			base_weight.g = 1.0
		2:
			base_weight.b = 1.0
		3:
			base_weight.a = 1.0
	for pixel_y: int in source_image.get_height():
		for pixel_x: int in source_image.get_width():
			var weight := source_image.get_pixel(pixel_x, pixel_y)
			if (
				host._strongest_active_splat_component(weight, active_channels)
				<= MTSSurfaceMaterialPaint.SPLATMAP_EMPTY_COMPONENT_THRESHOLD
			):
				source_image.set_pixel(pixel_x, pixel_y, base_weight)
	return source_image


## Return one native source weight after explicit channel masking and normalization.
static func _normalized_splat_weight(host: MTSSurfaceMaterialPaint,
	weight: Color,
	active_channels: PackedByteArray
) -> Color:
	weight.r *= float(active_channels[0])
	weight.g *= float(active_channels[1])
	weight.b *= float(active_channels[2])
	weight.a *= float(active_channels[3])
	var total := weight.r + weight.g + weight.b + weight.a
	if total <= 0.0:
		return Color(0.0, 0.0, 0.0, 0.0)
	return Color(
		weight.r / total,
		weight.g / total,
		weight.b / total,
		weight.a / total
	)


## Return the RGBA weights one terrain cell covers inside the stretched control image.
##
## The control image is stretched across the terrain's whole cell rectangle, so a cell
## owns exactly its proportional sub-rectangle of source pixels. Cropping that region
## and letting Image.resize() filter it keeps the work in engine code: one tile costs
## two native calls instead of the per-pixel script loop this replaces.
static func build_splatmap_tile(host: MTSSurfaceMaterialPaint,
	source_image: Image,
	terrain_bounds: Rect2i,
	projection_cell: Vector2i,
	active_channels: PackedByteArray
) -> Image:
	if host.profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot build a splat tile without a profile.")
		return null
	if active_channels.size() != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		push_error("MTSSurfaceMaterialPaint: a splat tile requires four explicit channel states.")
		return null
	if source_image == null or source_image.is_empty():
		push_error("MTSSurfaceMaterialPaint: cannot build a splat tile from an empty source.")
		return null
	if terrain_bounds.size.x <= 0 or terrain_bounds.size.y <= 0:
		push_error("MTSSurfaceMaterialPaint: splat tile bounds are empty.")
		return null
	var cell_index := projection_cell - terrain_bounds.position
	if (
		cell_index.x < 0
		or cell_index.y < 0
		or cell_index.x >= terrain_bounds.size.x
		or cell_index.y >= terrain_bounds.size.y
	):
		push_error(
			"MTSSurfaceMaterialPaint: projection cell %s is outside splatmap bounds %s."
			% [projection_cell, terrain_bounds]
		)
		return null
	var source_size := source_image.get_size()
	var start := Vector2i(
		floori(float(cell_index.x) / float(terrain_bounds.size.x) * float(source_size.x)),
		floori(float(cell_index.y) / float(terrain_bounds.size.y) * float(source_size.y))
	)
	var end := Vector2i(
		ceili(float(cell_index.x + 1) / float(terrain_bounds.size.x) * float(source_size.x)),
		ceili(float(cell_index.y + 1) / float(terrain_bounds.size.y) * float(source_size.y))
	)
	# A control image coarser than the terrain can map a whole cell inside one source
	# texel, so the region is widened to a single pixel rather than becoming empty.
	start.x = clampi(start.x, 0, maxi(source_size.x - 1, 0))
	start.y = clampi(start.y, 0, maxi(source_size.y - 1, 0))
	end.x = clampi(maxi(end.x, start.x + 1), start.x + 1, source_size.x)
	end.y = clampi(maxi(end.y, start.y + 1), start.y + 1, source_size.y)
	var tile := source_image.get_region(Rect2i(start, end - start))
	if tile == null or tile.is_empty():
		push_error(
			"MTSSurfaceMaterialPaint: splat tile region for projection cell %s is empty."
			% projection_cell
		)
		return null
	var resolution := host.profile.paint_resolution(Vector2i.ONE)
	if tile.get_size() != resolution:
		tile.resize(resolution.x, resolution.y, Image.INTERPOLATE_BILINEAR)
	if tile.get_format() != Image.FORMAT_RGBA8:
		tile.convert(Image.FORMAT_RGBA8)
	# Store normalized native source ratios. The shader applies visible strength
	# controls at draw time so existing brush strokes respond immediately to slider changes.
	for pixel_y: int in resolution.y:
		for pixel_x: int in resolution.x:
			tile.set_pixel(
				pixel_x,
				pixel_y,
				host._normalized_splat_weight(
					tile.get_pixel(pixel_x, pixel_y),
					active_channels
				)
			)
	return tile
