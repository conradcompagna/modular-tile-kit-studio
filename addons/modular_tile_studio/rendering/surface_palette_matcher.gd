@tool
class_name MTSSurfacePaletteMatcher
extends RefCounted

## Computes optional decal palette adjustments from the original albedo textures.
##
## Palette analysis samples a bounded grid, but rendering always uses the authored
## GPU textures directly and never resizes, rewrites, or replaces their pixels.

const ALPHA_EPSILON: float = 0.001
const PALETTE_STDDEV_FLOOR: float = 0.025
const PALETTE_SCALE_MIN: float = 0.35
const PALETTE_SCALE_MAX: float = 2.5
const PALETTE_SAMPLE_GRID_EDGE: int = 96


## Return the affine RGB transform used by a shader decal's existing material layer.
static func shader_adjustment(
	placement: SurfacePlacement,
	board: BoardDocument,
	library: AssetLibrary,
	material_factory: SurfaceMaterialFactory,
	paint: MTSSurfaceMaterialPaint
) -> Dictionary:
	if placement == null or not placement.match_underlying_palette:
		return {}
	var stats := _source_and_target_stats(
		placement,
		board,
		library,
		material_factory,
		paint
	)
	if stats.is_empty():
		return {}
	return _palette_transform(stats["source"], stats["target"])


## Return the multiplicative RGB tint supported by Godot's native Decal node.
static func native_adjustment(
	placement: SurfacePlacement,
	board: BoardDocument,
	library: AssetLibrary,
	material_factory: SurfaceMaterialFactory,
	paint: MTSSurfaceMaterialPaint
) -> Dictionary:
	if placement == null or not placement.match_underlying_palette:
		return {}
	var stats := _source_and_target_stats(
		placement,
		board,
		library,
		material_factory,
		paint
	)
	if stats.is_empty():
		return {}
	return {"modulate": _native_palette_modulate(stats["source"], stats["target"])}


## Resolve the source and receiving palettes required by either decal presentation.
static func _source_and_target_stats(
	placement: SurfacePlacement,
	board: BoardDocument,
	library: AssetLibrary,
	material_factory: SurfaceMaterialFactory,
	paint: MTSSurfaceMaterialPaint
) -> Dictionary:
	if board == null or library == null or material_factory == null:
		push_error("[Tile Studio] Decal palette matching requires a board, library, and material factory.")
		return {}
	var asset := library.get_asset(placement.asset_id)
	if asset == null or not asset.is_surface():
		push_error(
			"[Tile Studio] Decal '%s' references missing surface asset '%s'."
			% [placement.ensure_uid(), placement.asset_id]
		)
		return {}
	var palette_stats_cache: Dictionary = {}
	var source_stats := _asset_palette_stats(
		asset,
		material_factory,
		palette_stats_cache
	)
	var target_stats := _underlying_palette_stats(
		placement,
		board,
		library,
		material_factory,
		paint,
		palette_stats_cache
	)
	if source_stats.is_empty() or target_stats.is_empty():
		push_error(
			"[Tile Studio] Decal '%s' cannot resolve source and underlying albedo palettes."
			% placement.ensure_uid()
		)
		return {}
	return {"source": source_stats, "target": target_stats}


## Derive one footprint-wide target palette from the materials already on its faces.
static func _underlying_palette_stats(
	placement: SurfacePlacement,
	board: BoardDocument,
	library: AssetLibrary,
	material_factory: SurfaceMaterialFactory,
	paint: MTSSurfaceMaterialPaint,
	palette_stats_cache: Dictionary
) -> Dictionary:
	var accumulator := {
		"weight": 0.0,
		"mean_sum": Vector3.ZERO,
		"second_sum": Vector3.ZERO,
	}
	for uid: String in placement.terrain_face_uids:
		var base_placement := board.surface_at_paint_uid(uid)
		if base_placement != null:
			_accumulate_asset_palette(
				accumulator,
				library.get_asset(base_placement.asset_id),
				1.0,
				material_factory,
				palette_stats_cache
			)
		if board.material_blend == null or paint == null:
			continue
		var weights: Color = paint.average_weights_for_uid(uid)
		var slot_weights := PackedFloat32Array([weights.r, weights.g, weights.b, weights.a])
		var palette_slots := paint.palette_slots_for_uid(uid)
		for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
			var weight := slot_weights[slot_index]
			if weight <= ALPHA_EPSILON:
				continue
			# RGBA is local to this face; the saved slot mapping identifies the
			# board-palette material whose albedo contributes to the target.
			var palette_index := palette_slots[slot_index]
			if palette_index < 0 or palette_index >= board.material_blend.layer_count():
				continue
			var layer := board.material_blend.layer(palette_index)
			if not bool(layer.get("enabled", false)):
				continue
			var asset_id := String(layer.get("asset_id", ""))
			if asset_id.is_empty():
				continue
			_accumulate_asset_palette(
				accumulator,
				library.get_asset(asset_id),
				weight,
				material_factory,
				palette_stats_cache
			)
	var total_weight := float(accumulator["weight"])
	if total_weight <= ALPHA_EPSILON:
		return {}
	var mean: Vector3 = accumulator["mean_sum"] / total_weight
	var second: Vector3 = accumulator["second_sum"] / total_weight
	var variance := Vector3(
		maxf(second.x - mean.x * mean.x, 0.0),
		maxf(second.y - mean.y * mean.y, 0.0),
		maxf(second.z - mean.z * mean.z, 0.0)
	)
	return {
		"mean": mean,
		"stddev": Vector3(sqrt(variance.x), sqrt(variance.y), sqrt(variance.z)),
	}


## Add one material's alpha-weighted palette moments to an aggregate target.
static func _accumulate_asset_palette(
	accumulator: Dictionary,
	asset: TileAsset,
	weight: float,
	material_factory: SurfaceMaterialFactory,
	palette_stats_cache: Dictionary
) -> void:
	if asset == null or weight <= ALPHA_EPSILON:
		return
	var stats := _asset_palette_stats(asset, material_factory, palette_stats_cache)
	if stats.is_empty():
		return
	var mean: Vector3 = stats["mean"]
	var stddev: Vector3 = stats["stddev"]
	accumulator["weight"] = float(accumulator["weight"]) + weight
	accumulator["mean_sum"] = (
		accumulator["mean_sum"] as Vector3
		+ mean * weight
	)
	accumulator["second_sum"] = (
		accumulator["second_sum"] as Vector3
		+ Vector3(
			stddev.x * stddev.x + mean.x * mean.x,
			stddev.y * stddev.y + mean.y * mean.y,
			stddev.z * stddev.z + mean.z * mean.z
		) * weight
	)


## Return cached palette moments for one asset's visible original-resolution albedo.
static func _asset_palette_stats(
	asset: TileAsset,
	material_factory: SurfaceMaterialFactory,
	palette_stats_cache: Dictionary
) -> Dictionary:
	if asset == null:
		return {}
	if palette_stats_cache.has(asset.asset_id):
		return palette_stats_cache[asset.asset_id]
	var texture := material_factory.get_visible_albedo(asset)
	if texture == null:
		return {}
	var image := _texture_image(texture)
	if image == null:
		return {}
	var maps := asset.gbuffer
	var albedo_strength: float = maps.get_strength("albedo") if maps != null else 1.0
	var tint := Color.WHITE.lerp(
		asset.surface_tint_color,
		clampf(asset.surface_tint_strength, 0.0, 1.0)
	)
	var stats := _image_palette_stats(image, albedo_strength, tint)
	if not stats.is_empty():
		palette_stats_cache[asset.asset_id] = stats
	return stats


## Return a readable source image without modifying the imported texture resource.
static func _texture_image(texture: Texture2D) -> Image:
	if texture == null:
		return null
	var image := texture.get_image()
	if image == null or image.is_empty():
		return null
	if image.is_compressed():
		image = image.duplicate()
		var error := image.decompress()
		if error != OK:
			push_error(
				"[Tile Studio] Palette analysis could not decompress an albedo image (error %d)."
				% error
			)
			return null
	return image


## Estimate alpha-weighted RGB moments from a bounded grid over the original image.
static func _image_palette_stats(
	image: Image,
	albedo_strength: float,
	tint: Color
) -> Dictionary:
	if image == null or image.is_empty():
		return {}
	var columns := mini(image.get_width(), PALETTE_SAMPLE_GRID_EDGE)
	var rows := mini(image.get_height(), PALETTE_SAMPLE_GRID_EDGE)
	var total_weight := 0.0
	var mean_sum := Vector3.ZERO
	var second_sum := Vector3.ZERO
	for sample_y: int in rows:
		var y := mini(
			floori((float(sample_y) + 0.5) * float(image.get_height()) / float(rows)),
			image.get_height() - 1
		)
		for sample_x: int in columns:
			var x := mini(
				floori((float(sample_x) + 0.5) * float(image.get_width()) / float(columns)),
				image.get_width() - 1
			)
			var color := image.get_pixel(x, y)
			if color.a <= ALPHA_EPSILON:
				continue
			var rgb := Vector3(
				lerpf(1.0, color.r, albedo_strength) * tint.r,
				lerpf(1.0, color.g, albedo_strength) * tint.g,
				lerpf(1.0, color.b, albedo_strength) * tint.b
			)
			total_weight += color.a
			mean_sum += rgb * color.a
			second_sum += Vector3(rgb.x * rgb.x, rgb.y * rgb.y, rgb.z * rgb.z) * color.a
	if total_weight <= ALPHA_EPSILON:
		return {}
	var mean := mean_sum / total_weight
	var second := second_sum / total_weight
	var variance := Vector3(
		maxf(second.x - mean.x * mean.x, 0.0),
		maxf(second.y - mean.y * mean.y, 0.0),
		maxf(second.z - mean.z * mean.z, 0.0)
	)
	return {
		"mean": mean,
		"stddev": Vector3(sqrt(variance.x), sqrt(variance.y), sqrt(variance.z)),
	}


## Return the per-channel affine transform that matches source mean and contrast.
static func _palette_transform(
	source_stats: Dictionary,
	target_stats: Dictionary
) -> Dictionary:
	var source_mean: Vector3 = source_stats["mean"]
	var source_stddev: Vector3 = source_stats["stddev"]
	var target_mean: Vector3 = target_stats["mean"]
	var target_stddev: Vector3 = target_stats["stddev"]
	var scale := Vector3(
		clampf(
			target_stddev.x / maxf(source_stddev.x, PALETTE_STDDEV_FLOOR),
			PALETTE_SCALE_MIN,
			PALETTE_SCALE_MAX
		),
		clampf(
			target_stddev.y / maxf(source_stddev.y, PALETTE_STDDEV_FLOOR),
			PALETTE_SCALE_MIN,
			PALETTE_SCALE_MAX
		),
		clampf(
			target_stddev.z / maxf(source_stddev.z, PALETTE_STDDEV_FLOOR),
			PALETTE_SCALE_MIN,
			PALETTE_SCALE_MAX
		)
	)
	return {"scale": scale, "offset": target_mean - source_mean * scale}


## Return a mean-matching RGB multiplier for Godot's tint-only native decal API.
static func _native_palette_modulate(
	source_stats: Dictionary,
	target_stats: Dictionary
) -> Color:
	var source_mean: Vector3 = source_stats["mean"]
	var target_mean: Vector3 = target_stats["mean"]
	return Color(
		clampf(
			target_mean.x / maxf(source_mean.x, PALETTE_STDDEV_FLOOR),
			PALETTE_SCALE_MIN,
			PALETTE_SCALE_MAX
		),
		clampf(
			target_mean.y / maxf(source_mean.y, PALETTE_STDDEV_FLOOR),
			PALETTE_SCALE_MIN,
			PALETTE_SCALE_MAX
		),
		clampf(
			target_mean.z / maxf(source_mean.z, PALETTE_STDDEV_FLOOR),
			PALETTE_SCALE_MIN,
			PALETTE_SCALE_MAX
		),
		1.0
	)
