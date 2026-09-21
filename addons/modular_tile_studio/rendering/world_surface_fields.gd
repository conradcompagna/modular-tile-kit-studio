@tool
class_name MTSWorldSurfaceFields
extends RefCounted

## GPU-visible, board-wide fields used by mts_surface_gpu.gdshader.
##
## HEIGHT (FORMAT_RF)
##   R = signed world-Y displacement in metres. 0 = no world deformation.
##
## CONTACT (FORMAT_RF)
##   R = visual grime from prop silhouettes and wall/floor seams (0..1).
##
## Neither field is authored. The board TerrainMesh is the one canonical height
## source; this height image is its deterministic GPU projection. Contact grime
## is regenerated from authoritative placements and source geometry, but it never
## changes terrain geometry or prop placement.

signal fields_changed(kind: String)

## The default 64 m square yields sixteen editable texels per metre, preserving
## real GLB contact silhouettes and responsive sculpt brushes.
const DEFAULT_ORIGIN := Vector2(-32.0, -32.0)
const DEFAULT_SIZE := Vector2(64.0, 64.0)
const DEFAULT_RESOLUTION := Vector2i(1024, 1024)
## Thirty-two-pixel extrema blocks keep percentage-mask range updates local.
const HEIGHT_RANGE_BLOCK_SIZE := 32
## Height texels per metre used when terrain allocates its own field.
const TEXELS_PER_METER := 16.0

var world_origin_xz: Vector2 = DEFAULT_ORIGIN
var world_size_xz: Vector2 = DEFAULT_SIZE
var resolution: Vector2i = DEFAULT_RESOLUTION

## Height projected from the board TerrainGrid, plus its direct GPU texture.
## Rigid support planes are combined with this source in the vertex shader, so a
## prop can flatten the ground beneath it without a second height image.
var height_source_image: Image
var height_texture: ImageTexture
var interaction_image: Image
var interaction_texture: ImageTexture
## Block-local minima and maxima derive the world-height percentage range without rescanning the image.
var _height_range_blocks: Dictionary = {}

## Stable source id -> weighted grime contribution used for exact local removal.
var _contact_sources: Dictionary = {}
## Derived pixel -> source -> grime strength index for footprint-local max removal.
var _contact_contributors_by_pixel: Dictionary = {}
## A fresh interaction field is already clear, so the first board rebuild need not clear and reallocate it.
var _contacts_are_empty: bool = true


## Initialize default coverage unless a loader will provide exact prepared geometry immediately.
func _init(initialize_default: bool = true) -> void:
	if initialize_default:
		configure(DEFAULT_ORIGIN, DEFAULT_SIZE, DEFAULT_RESOLUTION)


## Recreate both fields over one explicit world-space XZ rectangle.
##
## Reconfiguration deliberately clears transient sculpting and derived contacts.
##
## Board binding suppresses notification because its one normal rebuild consumes
## the completed field; interactive reconfiguration still notifies immediately.
func configure(
	origin_xz: Vector2,
	size_xz: Vector2,
	p_resolution: Vector2i = DEFAULT_RESOLUTION,
	notify_change: bool = true
) -> void:
	_set_sampling_geometry(origin_xz, size_xz, p_resolution)
	height_source_image = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	height_source_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	height_texture = ImageTexture.create_from_image(height_source_image)
	_rebuild_height_range_blocks()
	_reset_interaction_resources()
	if notify_change:
		fields_changed.emit("all")


## Store one validated world-space sampling rectangle for every field resource.
func _set_sampling_geometry(
	origin_xz: Vector2,
	size_xz: Vector2,
	p_resolution: Vector2i
) -> void:
	world_origin_xz = origin_xz
	world_size_xz = Vector2(maxf(abs(size_xz.x), 0.001), maxf(abs(size_xz.y), 0.001))
	resolution = Vector2i(maxi(2, p_resolution.x), maxi(2, p_resolution.y))


## Allocate the transient interaction and support resources exactly once for the current geometry.
func _reset_interaction_resources() -> void:
	interaction_image = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
	interaction_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	interaction_texture = ImageTexture.create_from_image(interaction_image)

	_contact_sources.clear()
	_contact_contributors_by_pixel.clear()

	_contacts_are_empty = true


## Expand the editable field to contain one world rectangle without changing existing sculpt samples.
##
## Expansion extends the current pixel lattice by whole texels on each required
## side, so old canonical height pixels are copied exactly rather than resampled.
## Derived grime is cleared for the viewport to regenerate after replacement.
func ensure_coverage(required_world_rect: Rect2) -> bool:
	if height_source_image == null or height_source_image.is_empty():
		push_error("MTSWorldSurfaceFields: cannot expand an uninitialized height field.")
		return false
	var required_rect := required_world_rect.abs()
	if required_rect.size.x <= 0.0 or required_rect.size.y <= 0.0:
		push_error("MTSWorldSurfaceFields: required coverage must have positive world size.")
		return false
	var current_rect := Rect2(world_origin_xz, world_size_xz)
	if current_rect.encloses(required_rect):
		return false

	var sample_step := world_size_xz / Vector2(resolution - Vector2i.ONE)
	if sample_step.x <= 0.0 or sample_step.y <= 0.0:
		push_error("MTSWorldSurfaceFields: current field has invalid world-space sample spacing.")
		return false
	var extra_before_world := (world_origin_xz - required_rect.position).max(Vector2.ZERO)
	var extra_after_world := (required_rect.end - current_rect.end).max(Vector2.ZERO)
	var extra_before := Vector2i(
		ceili(extra_before_world.x / sample_step.x),
		ceili(extra_before_world.y / sample_step.y)
	)
	var extra_after := Vector2i(
		ceili(extra_after_world.x / sample_step.x),
		ceili(extra_after_world.y / sample_step.y)
	)
	var expanded_resolution := resolution + extra_before + extra_after
	var expanded_origin := world_origin_xz - Vector2(extra_before) * sample_step
	var expanded_size := Vector2(expanded_resolution - Vector2i.ONE) * sample_step

	# Build every replacement resource before changing live fields so allocation
	# failure cannot leave the renderer with mismatched rectangles and textures.
	var expanded_height_source := Image.create(
		expanded_resolution.x,
		expanded_resolution.y,
		false,
		Image.FORMAT_RF
	)
	if expanded_height_source == null or expanded_height_source.is_empty():
		push_error("MTSWorldSurfaceFields: failed to allocate expanded canonical height image.")
		return false
	expanded_height_source.fill(Color(0.0, 0.0, 0.0, 1.0))
	expanded_height_source.blit_rect(
		height_source_image,
		Rect2i(Vector2i.ZERO, resolution),
		extra_before
	)
	var expanded_height_texture := ImageTexture.create_from_image(expanded_height_source)

	var expanded_interaction := Image.create(
		expanded_resolution.x,
		expanded_resolution.y,
		false,
		Image.FORMAT_RF
	)
	if expanded_interaction == null or expanded_interaction.is_empty():
		push_error("MTSWorldSurfaceFields: failed to allocate expanded interaction image.")
		return false
	expanded_interaction.fill(Color(0.0, 0.0, 0.0, 1.0))
	var expanded_interaction_texture := ImageTexture.create_from_image(expanded_interaction)

	world_origin_xz = expanded_origin
	world_size_xz = expanded_size
	resolution = expanded_resolution
	height_source_image = expanded_height_source
	height_texture = expanded_height_texture
	_rebuild_height_range_blocks()
	interaction_image = expanded_interaction
	interaction_texture = expanded_interaction_texture

	_contact_sources.clear()
	_contact_contributors_by_pixel.clear()

	_contacts_are_empty = true
	fields_changed.emit("all")
	return true


## Return the exact world rectangle consumed by both shader samplers.
func shader_rect() -> Vector4:
	return Vector4(world_origin_xz.x, world_origin_xz.y, world_size_xz.x, world_size_xz.y)
## Clear every derived grime contributor while preserving the projected heightfield.
func clear_contacts(upload: bool = true) -> void:
	if interaction_image == null or _contacts_are_empty:
		return
	interaction_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	_contact_sources.clear()
	_contact_contributors_by_pixel.clear()
	_contacts_are_empty = true
	if upload:
		_upload_interaction()
## Remove one tracked grime source and recompute only pixels it previously touched.
func remove_contact_source(source_id: String, upload: bool = true) -> bool:
	if source_id.is_empty() or not _contact_sources.has(source_id):
		return false
	var removed_source: Dictionary = _contact_sources[source_id]
	var removed_weights: Dictionary = removed_source.get("contact_weights", {})
	_contact_sources.erase(source_id)
	for encoded_value: Variant in removed_weights.keys():
		var encoded := int(encoded_value)
		var contributors: Dictionary = _contact_contributors_by_pixel.get(encoded, {})
		contributors.erase(source_id)
		var contact_strength := 0.0
		for contribution_value: Variant in contributors.values():
			contact_strength = maxf(contact_strength, float(contribution_value))
		if contributors.is_empty():
			_contact_contributors_by_pixel.erase(encoded)
		else:
			_contact_contributors_by_pixel[encoded] = contributors
		var pixel := _decode_pixel(encoded)
		interaction_image.set_pixel(
			pixel.x,
			pixel.y,
			Color(contact_strength, 0.0, 0.0, 1.0)
		)
	if upload:
		_upload_interaction()
	return true
## Rasterize geometry-derived grime polygons into the one contact channel.
func stamp_contact_polygons(
	world_polygons: Array[PackedVector2Array],
	contact_feather_m: float = 0.35,
	strength: float = 1.0,
	upload: bool = true,
	contact_source_id: String = ""
) -> void:
	if interaction_image == null or world_polygons.is_empty():
		return
	strength = clampf(strength, 0.0, 1.0)
	contact_feather_m = maxf(contact_feather_m, 0.0)
	if not contact_source_id.is_empty():
		remove_contact_source(contact_source_id, false)

	var world_bounds := _polygon_union_bounds(world_polygons)
	if world_bounds.size == Vector2.ZERO:
		push_error("MTSWorldSurfaceFields: contact polygons have no world-space extent.")
		return
	var exact_pixels: Dictionary = {}
	var core_radius := _contact_core_radius_m()
	for polygon: PackedVector2Array in world_polygons:
		_rasterize_contact_polygon(polygon, core_radius, exact_pixels)
	if exact_pixels.is_empty():
		push_error("MTSWorldSurfaceFields: contact polygons produced no raster pixels.")
		return

	var contact_weights: Dictionary = {}
	for encoded_value: Variant in exact_pixels.keys():
		var encoded := int(encoded_value)
		var pixel := _decode_pixel(encoded)
		var contact_value := interaction_image.get_pixel(pixel.x, pixel.y)
		contact_value.r = maxf(contact_value.r, strength)
		interaction_image.set_pixel(pixel.x, pixel.y, contact_value)
		contact_weights[encoded] = 1.0
	if contact_feather_m > 0.0:
		_feather_contact_pixels(
			exact_pixels,
			contact_feather_m,
			strength,
			contact_weights
		)

	if not contact_source_id.is_empty():
		_contact_sources[contact_source_id] = {
			"contact_weights": contact_weights.duplicate(),
			"strength": strength,
		}
		_register_contact_source_contributions(
			contact_source_id,
			contact_weights,
			strength
		)
	_contacts_are_empty = false
	if upload:
		_upload_interaction()
## Index one source's weighted grime contribution by pixel.
func _register_contact_source_contributions(
	source_id: String,
	contact_weights: Dictionary,
	strength: float
) -> void:
	for encoded_value: Variant in contact_weights.keys():
		var encoded := int(encoded_value)
		var contributors: Dictionary = _contact_contributors_by_pixel.get(encoded, {})
		contributors[source_id] = strength * float(contact_weights[encoded_value])
		_contact_contributors_by_pixel[encoded] = contributors


## Rasterize one contact polygon or degenerate projected triangle into a shared exact-pixel set.
func _rasterize_contact_polygon(
	polygon: PackedVector2Array,
	core_radius_m: float,
	exact_pixel_set: Dictionary
) -> void:
	if polygon.is_empty():
		return
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for point: Vector2 in polygon:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	var bounds := Rect2(minimum, maximum - minimum).grow(core_radius_m)
	var field_bounds := Rect2(world_origin_xz, world_size_xz)
	if not bounds.intersects(field_bounds, true):
		return

	var min_px := _world_to_pixel(bounds.position)
	var max_px := _world_to_pixel(bounds.end)
	var x0 := clampi(mini(min_px.x, max_px.x) - 1, 0, interaction_image.get_width())
	var x1 := clampi(maxi(min_px.x, max_px.x) + 2, 0, interaction_image.get_width())
	var y0 := clampi(mini(min_px.y, max_px.y) - 1, 0, interaction_image.get_height())
	var y1 := clampi(maxi(min_px.y, max_px.y) + 2, 0, interaction_image.get_height())

	# Detailed GLBs can contribute hundreds of thousands of triangles smaller
	# than one contact texel. Filling their at-most-2x2 pixel box is the exact
	# representable result at this field resolution and avoids redundant geometry
	# tests whose subpixel distinctions cannot reach the shader.
	if (x1 - x0) * (y1 - y0) <= 16:
		for y in range(y0, y1):
			for x in range(x0, x1):
				exact_pixel_set[y * interaction_image.get_width() + x] = true
		return

	for y in range(y0, y1):
		for x in range(x0, x1):
			var world_point := _pixel_to_world(Vector2i(x, y))
			var is_core := polygon.size() >= 3 and Geometry2D.is_point_in_polygon(world_point, polygon)
			if not is_core:
				for index in polygon.size():
					var start := polygon[index]
					var end := polygon[(index + 1) % polygon.size()]
					if _point_segment_distance(world_point, start, end) <= core_radius_m:
						is_core = true
						break
			if is_core:
				exact_pixel_set[y * interaction_image.get_width() + x] = true
## Feather one visual grime mask with an exact local Euclidean distance transform.
##
## This affects appearance only. Terrain flattening never consumes this mask.
func _feather_contact_pixels(
	exact_pixel_set: Dictionary,
	feather_m: float,
	strength: float,
	channel_weights: Dictionary
) -> void:
	if exact_pixel_set.is_empty() or feather_m <= 0.0:
		return
	var pixel_size := world_size_xz / Vector2(resolution - Vector2i.ONE)
	var radius_x := ceili(feather_m / pixel_size.x)
	var radius_y := ceili(feather_m / pixel_size.y)
	var exact_bounds := _encoded_pixel_bounds(exact_pixel_set.keys())
	var x0 := maxi(0, exact_bounds.position.x - radius_x)
	var y0 := maxi(0, exact_bounds.position.y - radius_y)
	var x1 := mini(resolution.x, exact_bounds.end.x + radius_x)
	var y1 := mini(resolution.y, exact_bounds.end.y + radius_y)
	var local_width := x1 - x0
	var local_height := y1 - y0
	if local_width <= 0 or local_height <= 0:
		return

	var horizontal_distances := PackedFloat32Array()
	horizontal_distances.resize(local_width * local_height)
	var line := PackedFloat32Array()
	line.resize(local_width)
	for local_y: int in local_height:
		line.fill(INF)
		var world_y := y0 + local_y
		for local_x: int in local_width:
			var world_x := x0 + local_x
			if exact_pixel_set.has(world_y * resolution.x + world_x):
				line[local_x] = 0.0
		var transformed := _distance_transform_1d_squared(line, pixel_size.x)
		var row_offset := local_y * local_width
		for local_x: int in local_width:
			horizontal_distances[row_offset + local_x] = transformed[local_x]

	line.resize(local_height)
	for local_x: int in local_width:
		for local_y: int in local_height:
			line[local_y] = horizontal_distances[local_y * local_width + local_x]
		var transformed := _distance_transform_1d_squared(line, pixel_size.y)
		for local_y: int in local_height:
			var distance_m := sqrt(transformed[local_y])
			if distance_m > feather_m:
				continue
			var weight := 1.0 - smoothstep(0.0, feather_m, distance_m)
			var target := Vector2i(x0 + local_x, y0 + local_y)
			var encoded := target.y * resolution.x + target.x
			var old_weight := float(channel_weights.get(encoded, 0.0))
			if weight <= old_weight:
				continue
			channel_weights[encoded] = weight
			var contact_value := interaction_image.get_pixel(target.x, target.y)
			contact_value.r = maxf(contact_value.r, strength * weight)
			interaction_image.set_pixel(target.x, target.y, contact_value)



## Return exact squared distances to the lower envelope of one-dimensional parabolas.
##
## Physical sample spacing is included in the envelope intersections, so unequal
## X/Z texel sizes still produce a circular world-space feather.
func _distance_transform_1d_squared(
	source: PackedFloat32Array,
	spacing_m: float
) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(source.size())
	result.fill(INF)
	if source.is_empty():
		return result

	var finite_sites := PackedInt32Array()
	for index: int in source.size():
		if is_finite(source[index]):
			finite_sites.append(index)
	if finite_sites.is_empty():
		return result

	var envelope_sites := PackedInt32Array()
	envelope_sites.resize(finite_sites.size())
	var boundaries := PackedFloat32Array()
	boundaries.resize(finite_sites.size() + 1)
	var envelope_index := 0
	envelope_sites[0] = finite_sites[0]
	boundaries[0] = -INF
	boundaries[1] = INF

	for site_index: int in range(1, finite_sites.size()):
		var site := finite_sites[site_index]
		var site_position := float(site) * spacing_m
		var intersection := 0.0
		while true:
			var previous_site := envelope_sites[envelope_index]
			var previous_position := float(previous_site) * spacing_m
			intersection = (
				(
					source[site]
					+ site_position * site_position
					- source[previous_site]
					- previous_position * previous_position
				)
				/ (2.0 * (site_position - previous_position))
			)
			if intersection > boundaries[envelope_index] or envelope_index == 0:
				break
			envelope_index -= 1
		envelope_index += 1
		envelope_sites[envelope_index] = site
		boundaries[envelope_index] = intersection
		boundaries[envelope_index + 1] = INF

	envelope_index = 0
	for index: int in source.size():
		var position := float(index) * spacing_m
		while boundaries[envelope_index + 1] < position:
			envelope_index += 1
		var site := envelope_sites[envelope_index]
		var delta := position - float(site) * spacing_m
		result[index] = delta * delta + source[site]
	return result
## Stamp wall/floor grime without changing terrain geometry.
func stamp_contact_segment(
	world_start: Vector2,
	world_end: Vector2,
	thickness_m: float = 0.08,
	feather_m: float = 0.35,
	strength: float = 1.0,
	upload: bool = true,
	contact_source_id: String = ""
) -> void:
	var direction := world_end - world_start
	if direction.length_squared() <= 0.0000001:
		push_error("MTSWorldSurfaceFields: wall/floor contact segment has zero length.")
		return
	var side := Vector2(
		-direction.y,
		direction.x
	).normalized() * maxf(thickness_m * 0.5, _contact_core_radius_m())
	var polygon := PackedVector2Array([
		world_start + side,
		world_end + side,
		world_end - side,
		world_start - side,
	])
	stamp_contact_polygons(
		[polygon],
		feather_m,
		strength,
		upload,
		contact_source_id
	)



## Push the canonical height image after an external canonical-terrain update.
func upload_height() -> void:

	_upload_height()


## Rebuild the GPU height image from the canonical terrain corner lattice.
##
## This is the one path by which authored height reaches the shader. The board's
## TerrainGrid is the only editable height representation in the project, so this
## image is a pure projection of it and is rebuilt wholesale rather than edited.
##
## Coverage expands to contain the terrain before projecting, so a footprint
## drawn outside the current field is represented exactly instead of clipped.
func project_terrain(terrain: TerrainMesh) -> bool:
	var has_terrain := terrain != null and not terrain.is_empty()
	var has_field := height_source_image != null and not height_source_image.is_empty()

	if not has_terrain:
		# No terrain and no field is the ordinary startup state, not an error.
		if not has_field:
			return true
		# A board that had terrain and lost it clears back to no deformation.
		height_source_image.fill(Color(0.0, 0.0, 0.0, 1.0))
		_rebuild_height_range_blocks()

		_upload_height()
		return true

	if not has_field:
		# Terrain arriving before any field exists allocates one sized to it,
		# which is what happens when a heightfield is imported into a fresh board.
		var terrain_rect := terrain.world_rect()
		configure(
			terrain_rect.position,
			terrain_rect.size,
			Vector2i(
				ceili(terrain_rect.size.x * TEXELS_PER_METER) + 1,
				ceili(terrain_rect.size.y * TEXELS_PER_METER) + 1
			),
			false
		)

	ensure_coverage(terrain.world_rect())

	# Every texel samples the terrain's own bilinear cell surface, so the GPU
	# displacement and the CPU gameplay heights come from one evaluation rule and
	# cannot disagree about where the ground is.
	for pixel_y: int in resolution.y:
		for pixel_x: int in resolution.x:
			var world_point := _pixel_to_world(Vector2i(pixel_x, pixel_y))
			height_source_image.set_pixel(
				pixel_x,
				pixel_y,
				Color(terrain.sample_world_height(world_point, 0.0), 0.0, 0.0, 1.0)
			)
	_rebuild_height_range_blocks()

	_upload_height()
	return true


## Project only the terrain texels reached by one already-haloed edit rectangle.
##
## The live field must already cover the terrain; allocation and coverage changes
## remain explicit board-wide operations. Only touched pixels and height-range
## blocks are recomputed before one texture upload.
func project_terrain_region(terrain: TerrainMesh, affected_cells: Rect2i) -> bool:
	var regions: Array[Rect2i] = [affected_cells]
	return project_terrain_regions(terrain, regions)


## Project disjoint terrain regions into one image update and one GPU upload.
##
## Each region is sampled independently and overlapping pixels are deduplicated,
## so distant GLB instances never expand into one rectangle covering the map
## between them.
func project_terrain_regions(
	terrain: TerrainMesh,
	affected_regions: Array[Rect2i]
) -> bool:
	if terrain == null or terrain.is_empty():
		push_error("MTSWorldSurfaceFields: regional projection requires non-empty terrain.")
		return false
	if height_source_image == null or height_source_image.is_empty():
		push_error("MTSWorldSurfaceFields: regional projection requires an initialized field.")
		return false
	var field_rect := Rect2(world_origin_xz, world_size_xz)
	if not field_rect.encloses(terrain.world_rect()):
		push_error(
			"MTSWorldSurfaceFields: regional projection cannot change field coverage; "
			+ "resize the board field explicitly first."
		)
		return false

	var dirty_blocks: Dictionary = {}
	var visited_pixels: Dictionary = {}
	for affected_cells: Rect2i in affected_regions:
		if affected_cells.size.x <= 0 or affected_cells.size.y <= 0:
			continue
		var changed_world_rect := Rect2(
			Vector2(affected_cells.position),
			Vector2(affected_cells.size)
		)
		var pixel_bounds := _world_rect_pixel_bounds(changed_world_rect)
		for pixel_y: int in range(pixel_bounds.position.y, pixel_bounds.end.y):
			for pixel_x: int in range(pixel_bounds.position.x, pixel_bounds.end.x):
				var pixel := Vector2i(pixel_x, pixel_y)
				if visited_pixels.has(pixel):
					continue
				visited_pixels[pixel] = true
				var world_point := _pixel_to_world(pixel)
				height_source_image.set_pixel(
					pixel_x,
					pixel_y,
					Color(
						terrain.sample_world_height(world_point, 0.0),
						0.0,
						0.0,
						1.0
					)
				)
				dirty_blocks[_height_range_block_key(pixel)] = true
	for block_value: Variant in dirty_blocks.keys():
		_refresh_height_range_block(block_value as Vector2i)
	if not visited_pixels.is_empty():
		_upload_height("height_regions")
	return true


## Push batched contact-image edits to the GPU once.
func upload_interaction() -> void:
	_upload_interaction()


## Bilinearly sample the canonical height image at one world XZ coordinate.
func sample_height_world(world_xz: Vector2) -> float:
	if height_source_image == null:
		return 0.0
	var uv := (world_xz - world_origin_xz) / world_size_xz
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return 0.0
	var fx := uv.x * float(height_source_image.get_width() - 1)
	var fy := uv.y * float(height_source_image.get_height() - 1)
	var x0 := clampi(int(floor(fx)), 0, height_source_image.get_width() - 1)
	var y0 := clampi(int(floor(fy)), 0, height_source_image.get_height() - 1)
	var x1 := mini(x0 + 1, height_source_image.get_width() - 1)
	var y1 := mini(y0 + 1, height_source_image.get_height() - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var a := lerpf(
		height_source_image.get_pixel(x0, y0).r,
		height_source_image.get_pixel(x1, y0).r,
		tx
	)
	var b := lerpf(
		height_source_image.get_pixel(x0, y1).r,
		height_source_image.get_pixel(x1, y1).r,
		tx
	)
	return lerpf(a, b, ty)


## Apply one callable across a swept brush while recording sparse undo state.
func _brush_segment_pixel_bounds(
	start_world_xz: Vector2,
	end_world_xz: Vector2,
	radius_m: float
) -> Rect2i:
	var minimum := start_world_xz.min(end_world_xz) - Vector2.ONE * radius_m
	var maximum := start_world_xz.max(end_world_xz) + Vector2.ONE * radius_m
	return _world_rect_pixel_bounds(Rect2(minimum, maximum - minimum))


## Convert one world rectangle to its padded, clamped field pixel bounds.
func _world_rect_pixel_bounds(world_rect: Rect2) -> Rect2i:
	var rect := world_rect.abs()
	var min_px := _world_to_pixel(rect.position)
	var max_px := _world_to_pixel(rect.end)
	var x0 := clampi(mini(min_px.x, max_px.x) - 1, 0, resolution.x)
	var x1 := clampi(maxi(min_px.x, max_px.x) + 2, 0, resolution.x)
	var y0 := clampi(mini(min_px.y, max_px.y) - 1, 0, resolution.y)
	var y1 := clampi(maxi(min_px.y, max_px.y) + 2, 0, resolution.y)
	return Rect2i(x0, y0, maxi(0, x1 - x0), maxi(0, y1 - y0))


## Return one point brush pixel's smooth radial weight.
func _brush_segment_weight(
	pixel: Vector2i,
	start_world_xz: Vector2,
	end_world_xz: Vector2,
	radius_m: float,
	hardness: float
) -> float:
	var point := _pixel_to_world(pixel)
	var distance_ratio := (
		_point_segment_distance(point, start_world_xz, end_world_xz)
		/ maxf(radius_m, 0.0001)
	)
	if distance_ratio >= 1.0:
		return 0.0
	hardness = clampf(hardness, 0.0, 1.0)
	var soft_start := lerpf(0.0, 0.92, hardness)
	if distance_ratio <= soft_start:
		return 1.0
	var edge_ratio := (distance_ratio - soft_start) / maxf(1.0 - soft_start, 0.0001)
	return 1.0 - edge_ratio * edge_ratio * (3.0 - 2.0 * edge_ratio)


## Return the union bounds of every supplied contact polygon.
func _polygon_union_bounds(world_polygons: Array[PackedVector2Array]) -> Rect2:
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var has_point := false
	for polygon: PackedVector2Array in world_polygons:
		for point: Vector2 in polygon:
			minimum.x = minf(minimum.x, point.x)
			minimum.y = minf(minimum.y, point.y)
			maximum.x = maxf(maximum.x, point.x)
			maximum.y = maxf(maximum.y, point.y)
			has_point = true
	if not has_point:
		return Rect2()
	return Rect2(minimum, maximum - minimum)


## Return the shortest Euclidean distance from a point to a finite segment.
func _point_segment_distance(point: Vector2, start: Vector2, end: Vector2) -> float:
	var segment := end - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.0000001:
		return point.distance_to(start)
	var ratio := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * ratio)


## Return half the smaller world-space texel so degenerate contacts stay represented.
func _contact_core_radius_m() -> float:
	var texel_size := world_size_xz / Vector2(resolution)
	return minf(texel_size.x, texel_size.y) * 0.5



## Return the inclusive pixel bounds of compact row-major indices.
func _encoded_pixel_bounds(encoded_values: Array) -> Rect2i:
	if encoded_values.is_empty():
		return Rect2i()
	var minimum := Vector2i(resolution.x, resolution.y)
	var maximum := Vector2i(-1, -1)
	for encoded_value: Variant in encoded_values:
		var pixel := _decode_pixel(int(encoded_value))
		minimum = minimum.min(pixel)
		maximum = maximum.max(pixel)
	return Rect2i(minimum, maximum - minimum + Vector2i.ONE)


## Decode one row-major pixel index used by compact support masks.
func _decode_pixel(encoded: int) -> Vector2i:
	return Vector2i(
		encoded % resolution.x,
		floori(float(encoded) / float(resolution.x))
	)


## Convert one world XZ point to the nearest field pixel.
func _world_to_pixel(world_xz: Vector2) -> Vector2i:
	var uv := (world_xz - world_origin_xz) / world_size_xz
	return Vector2i(
		roundi(uv.x * float(resolution.x - 1)),
		roundi(uv.y * float(resolution.y - 1))
	)


## Convert one field pixel to its exact world XZ sample position.
func _pixel_to_world(pixel: Vector2i) -> Vector2:
	var uv := Vector2(
		float(pixel.x) / float(maxi(resolution.x - 1, 1)),
		float(pixel.y) / float(maxi(resolution.y - 1, 1))
	)
	return world_origin_xz + uv * world_size_xz



## Return the exact min/max height used by percentage-based world-height masks.
##
## The reduction touches only the small extrema dictionary; changed strokes
## recompute only the thirty-two-pixel blocks containing their modified pixels.
func height_value_range() -> Vector2:
	if height_source_image == null:
		return Vector2.ZERO
	if _height_range_blocks.is_empty():
		_rebuild_height_range_blocks()
	var minimum := INF
	var maximum := -INF
	for range_value: Variant in _height_range_blocks.values():
		var block_range := range_value as Vector2
		minimum = minf(minimum, block_range.x)
		maximum = maxf(maximum, block_range.y)
	if is_inf(minimum) or is_inf(maximum):
		return Vector2.ZERO
	return Vector2(minimum, maximum)


## Rebuild the extrema index when a new canonical image is configured or loaded.
func _rebuild_height_range_blocks() -> void:
	_height_range_blocks.clear()
	if height_source_image == null:
		return
	var block_count := Vector2i(
		ceili(float(resolution.x) / float(HEIGHT_RANGE_BLOCK_SIZE)),
		ceili(float(resolution.y) / float(HEIGHT_RANGE_BLOCK_SIZE))
	)
	for block_y: int in block_count.y:
		for block_x: int in block_count.x:
			_refresh_height_range_block(Vector2i(block_x, block_y))


## Refresh each unique extrema block touched by encoded sparse-stroke pixels.
func _refresh_height_range_blocks_for_encoded_pixels(encoded_pixels: Array) -> void:
	var blocks: Dictionary = {}
	for encoded_value: Variant in encoded_pixels:
		var pixel := _decode_pixel(int(encoded_value))
		blocks[_height_range_block_key(pixel)] = true
	for block_value: Variant in blocks.keys():
		_refresh_height_range_block(block_value as Vector2i)


## Refresh each unique extrema block touched by an undo or redo patch.
func _refresh_height_range_blocks_for_pixels(pixels: Array[Vector2i]) -> void:
	var blocks: Dictionary = {}
	for pixel: Vector2i in pixels:
		blocks[_height_range_block_key(pixel)] = true
	for block_value: Variant in blocks.keys():
		_refresh_height_range_block(block_value as Vector2i)


## Scan one small image block and replace its exact minimum and maximum.
func _refresh_height_range_block(block: Vector2i) -> void:
	if height_source_image == null:
		return
	var start := block * HEIGHT_RANGE_BLOCK_SIZE
	var end := Vector2i(
		mini(start.x + HEIGHT_RANGE_BLOCK_SIZE, resolution.x),
		mini(start.y + HEIGHT_RANGE_BLOCK_SIZE, resolution.y)
	)
	var minimum := INF
	var maximum := -INF
	for y: int in range(start.y, end.y):
		for x: int in range(start.x, end.x):
			var height := height_source_image.get_pixel(x, y).r
			minimum = minf(minimum, height)
			maximum = maxf(maximum, height)
	_height_range_blocks[block] = Vector2(minimum, maximum)


## Return the canonical extrema-block coordinate for one image pixel.
func _height_range_block_key(pixel: Vector2i) -> Vector2i:
	return Vector2i(
		pixel.x / HEIGHT_RANGE_BLOCK_SIZE,
		pixel.y / HEIGHT_RANGE_BLOCK_SIZE
	)


## Upload the canonical height image and identify preview versus bulk changes.
func _upload_height(change_kind: String = "height") -> void:
	if height_texture == null:
		height_texture = ImageTexture.create_from_image(height_source_image)
	else:
		height_texture.update(height_source_image)
	fields_changed.emit(change_kind)


## Upload the derived contact image and announce the committed change.
func _upload_interaction() -> void:
	if interaction_texture == null:
		interaction_texture = ImageTexture.create_from_image(interaction_image)
	else:
		interaction_texture.update(interaction_image)
	fields_changed.emit("interaction")
