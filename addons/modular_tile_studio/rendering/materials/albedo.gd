@tool
extends RefCounted

## Albedo behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

# --- Input resolution -----------------------------------------------------
#
# The material factory owns the one visible-albedo resolution path. Both the
# committed GPU material and editor previews consume its result, so source/
# analyzed blending and visible alpha cannot drift between them.

## Resolve the exact albedo texture a PNG surface presents to the user.
##
## This applies the same analyzed/source blend and visible-alpha composition as
## the canonical GPU material. It reports missing art instead of replacing the
## selected asset with an unrelated preview texture.
static func get_visible_albedo(host: SurfaceMaterialFactory, asset: TileAsset) -> Texture2D:
	if asset == null:
		push_error("SurfaceMaterialFactory: visible albedo requested without a valid TileAsset.")
		return null

	var maps := asset.gbuffer
	var has_analyzed_albedo := maps != null and not maps.get_channel("albedo").is_empty()
	var albedo: Texture2D = maps.load_texture("albedo") if maps != null else null
	if albedo == null and not asset.source_path.is_empty():
		albedo = host._load_view_texture(asset.source_path)

	if has_analyzed_albedo and albedo != null and maps.delight_blend < 1.0 and not asset.source_path.is_empty():
		var source := host._load_view_texture(asset.source_path)
		if source != null:
			albedo = host._blend_albedo_with_source(
				albedo,
				source,
				"delight|%s|%s|%.3f" % [maps.get_channel("albedo"), asset.source_path, maps.delight_blend],
				maps.delight_blend
			)

	if albedo == null:
		push_error("[Tile Studio] surface '%s' has no usable visible albedo." % asset.asset_id)
		return null
	var visible_albedo := host._albedo_with_alpha(albedo, maps)
	return host._visible_albedo_with_mipmaps(
		host._adjust_visible_albedo(visible_albedo, asset),
		asset
	)


## Guarantee the visible albedo reaches the GPU carrying a full mip chain.
##
## The surface shader samples this texture through
## filter_linear_mipmap_anisotropic, and a shader decal's blend weight against
## the terrain beneath it IS this image's alpha. With only mip 0 present the GPU
## has nothing to filter with when the decal is minified, so its coverage swings
## between 0 and 1 as the camera moves and the decal appears to z-fight the
## terrain from far away while looking correct up close.
##
## This cannot be left to the source .import settings. Every branch of
## get_visible_albedo may compose a fresh Image at runtime, and Godot's detect-3D
## auto-reimport only upgrades textures it happens to observe bound to a 3D
## material -- which is why the library holds mipmapped normal/orm/height maps
## beside albedo maps that have no mip chain at all.
static func _visible_albedo_with_mipmaps(host: SurfaceMaterialFactory, texture: Texture2D, asset: TileAsset) -> Texture2D:
	if texture == null:
		return null
	var image := texture.get_image()
	if image == null:
		push_error(
			"[Tile Studio] Cannot read visible albedo pixels to build mipmaps for '%s'."
			% asset.asset_id
		)
		return texture
	if image.has_mipmaps():
		return texture

	# Keyed by the incoming texture instance: every producer feeding this point
	# already caches its own result, so an unchanged asset hands back the same
	# Texture2D and this rebuild happens once rather than once per terrain batch.
	var key := "albedo_mipmaps|%s|%d" % [asset.asset_id, texture.get_instance_id()]
	var cached: Texture2D = host._composite_cache.get(key, null)
	if cached != null:
		return cached

	image = image.duplicate()
	# generate_mipmaps() cannot operate on block-compressed data, so an imported
	# VRAM texture has to be expanded before the chain can be built.
	if image.is_compressed() and image.decompress() != OK:
		push_error(
			"[Tile Studio] Cannot decompress visible albedo to build mipmaps for '%s'."
			% asset.asset_id
		)
		return texture
	if image.generate_mipmaps() != OK:
		push_error(
			"[Tile Studio] Could not generate visible albedo mipmaps for '%s'."
			% asset.asset_id
		)
		return texture

	var mipmapped := ImageTexture.create_from_image(image)
	host._composite_cache[key] = mipmapped
	return mipmapped


## Serialize the five authored image adjustments into one stable cache-key fragment.
static func _image_adjustment_key_fragment(host: SurfaceMaterialFactory, asset: TileAsset) -> String:
	return "brightness=%.4f|contrast=%.4f|saturation=%.4f|sharpness=%.4f|hue=%.4f" % [
		asset.surface_brightness,
		asset.surface_contrast,
		asset.surface_saturation,
		asset.surface_sharpness,
		asset.surface_hue_shift_degrees,
	]


## Derive one adjusted albedo for every consumer while leaving source files and alpha untouched.
##
## The signed detail control changes luminance only, so neither softening nor
## sharpening can introduce coloured edge halos. Hue rotates in
## YIQ so perceived brightness remains stable, then saturation, contrast, and
## brightness operate in their visible UI order. The result is cached because a
## slider commit may otherwise walk the same image once per terrain batch.
static func _adjust_visible_albedo(host: SurfaceMaterialFactory, texture: Texture2D, asset: TileAsset) -> Texture2D:
	if texture == null or asset == null:
		push_error("SurfaceMaterialFactory: image adjustment requires a texture and TileAsset.")
		return null
	if asset.surface_image_adjustments_are_default():
		return texture

	var maps := asset.gbuffer
	var key := "image_adjust|%s|source=%s|albedo=%s|alpha=%s|delight=%.4f|%s" % [
		asset.asset_id,
		asset.source_path,
		maps.get_channel("albedo") if maps != null else "",
		maps.get_channel("alpha") if maps != null else "",
		maps.delight_blend if maps != null else 1.0,
		host._image_adjustment_key_fragment(asset),
	]
	var cached: Texture2D = host._composite_cache.get(key, null)
	if cached != null:
		return cached

	var image := texture.get_image()
	if image == null:
		push_error("[Tile Studio] Cannot read visible albedo pixels for '%s'." % asset.asset_id)
		return null
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		push_error("[Tile Studio] Cannot decompress visible albedo for '%s'." % asset.asset_id)
		return null
	image.convert(Image.FORMAT_RGBA8)
	var had_mipmaps := image.has_mipmaps()
	if had_mipmaps:
		image.clear_mipmaps()
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		push_error("[Tile Studio] Visible albedo for '%s' has invalid dimensions." % asset.asset_id)
		return null

	var source_bytes := image.get_data()
	var output_bytes := source_bytes.duplicate()
	var detail := asset.surface_sharpness
	var has_detail_adjustment := not is_zero_approx(detail)
	var hue_angle := deg_to_rad(asset.surface_hue_shift_degrees)
	var hue_cosine := cos(hue_angle)
	var hue_sine := sin(hue_angle)
	for y in height:
		var row_offset := y * width * 4
		for x in width:
			var index := row_offset + x * 4
			var rgb := Vector3(
				float(source_bytes[index]) / 255.0,
				float(source_bytes[index + 1]) / 255.0,
				float(source_bytes[index + 2]) / 255.0
			)

			if has_detail_adjustment:
				var left_index := row_offset + maxi(0, x - 1) * 4
				var right_index := row_offset + mini(width - 1, x + 1) * 4
				var above_index := maxi(0, y - 1) * width * 4 + x * 4
				var below_index := mini(height - 1, y + 1) * width * 4 + x * 4
				# Read neighbouring luminance as scalars so large textures do not allocate
				# four temporary colours and an index array for every source pixel.
				var neighbour_luminance := (
					float(source_bytes[left_index]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.x
					+ float(source_bytes[left_index + 1]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.y
					+ float(source_bytes[left_index + 2]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.z
					+ float(source_bytes[right_index]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.x
					+ float(source_bytes[right_index + 1]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.y
					+ float(source_bytes[right_index + 2]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.z
					+ float(source_bytes[above_index]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.x
					+ float(source_bytes[above_index + 1]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.y
					+ float(source_bytes[above_index + 2]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.z
					+ float(source_bytes[below_index]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.x
					+ float(source_bytes[below_index + 1]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.y
					+ float(source_bytes[below_index + 2]) * SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS.z
				) / (255.0 * 4.0)
				# One signed unsharp mask. A positive amount adds this pixel's
				# difference from its neighbours back onto it, and a negative amount
				# subtracts it, so -1 lands exactly on the neighbouring luminance
				# average and softens while +1 pulls away from it and sharpens.
				var edge_delta := (rgb.dot(SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS) - neighbour_luminance) * detail
				rgb += Vector3.ONE * edge_delta

			if not is_zero_approx(asset.surface_hue_shift_degrees):
				var yiq_luminance := 0.299 * rgb.x + 0.587 * rgb.y + 0.114 * rgb.z
				var in_phase := 0.595716 * rgb.x - 0.274453 * rgb.y - 0.321263 * rgb.z
				var quadrature := 0.211456 * rgb.x - 0.522591 * rgb.y + 0.311135 * rgb.z
				var rotated_in_phase := in_phase * hue_cosine - quadrature * hue_sine
				var rotated_quadrature := in_phase * hue_sine + quadrature * hue_cosine
				rgb = Vector3(
					yiq_luminance + 0.9563 * rotated_in_phase + 0.6210 * rotated_quadrature,
					yiq_luminance - 0.2721 * rotated_in_phase - 0.6474 * rotated_quadrature,
					yiq_luminance - 1.1070 * rotated_in_phase + 1.7046 * rotated_quadrature
				)

			var luminance := rgb.dot(SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS)
			rgb = Vector3.ONE * luminance + (rgb - Vector3.ONE * luminance) * asset.surface_saturation
			rgb = (rgb - Vector3.ONE * 0.5) * asset.surface_contrast + Vector3.ONE * 0.5
			rgb *= asset.surface_brightness
			output_bytes[index] = int(round(clampf(rgb.x, 0.0, 1.0) * 255.0))
			output_bytes[index + 1] = int(round(clampf(rgb.y, 0.0, 1.0) * 255.0))
			output_bytes[index + 2] = int(round(clampf(rgb.z, 0.0, 1.0) * 255.0))

	image.set_data(width, height, false, Image.FORMAT_RGBA8, output_bytes)
	if had_mipmaps:
		image.generate_mipmaps()
	var adjusted := ImageTexture.create_from_image(image)
	host._composite_cache[key] = adjusted
	return adjusted
