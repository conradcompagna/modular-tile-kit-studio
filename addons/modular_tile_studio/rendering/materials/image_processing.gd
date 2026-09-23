@tool
extends RefCounted

## Image processing behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

## Albedo with an explicit visible-alpha map composited into its alpha channel.
##
## Godot has no separate alpha-texture slot: transparency is read from the
## albedo's own alpha. The MoGe validity mask is deliberately NOT used here;
## only a genuine alpha/cutout channel can change visible transparency.
##
## Returns the albedo untouched when there is no mask, which is the common case
## for a GLB card whose render already carries a correct cutout.
static func _albedo_with_alpha(host: SurfaceMaterialFactory, albedo: Texture2D, maps: GBufferMapSet) -> Texture2D:
	if maps == null:
		return albedo
	var alpha := maps.load_texture("alpha")
	if alpha == null:
		return albedo

	# delight_blend is part of the key because `albedo` here may already be
	# get_visible_albedo()'s
	# delight-blended pixels, and the path alone cannot distinguish one blend's
	# result from another's.
	var key := "albedo_alpha|%s|%s|delight=%.3f" % [
		maps.get_channel("albedo"),
		maps.get_channel("alpha"),
		maps.delight_blend,
	]
	var cached: Texture2D = host._composite_cache.get(key, null)
	if cached != null:
		return cached

	var albedo_image := albedo.get_image()
	if albedo_image == null:
		return albedo
	albedo_image = albedo_image.duplicate()
	if albedo_image.is_compressed() and albedo_image.decompress() != OK:
		return albedo
	albedo_image.convert(Image.FORMAT_RGBA8)

	var alpha_image := alpha.get_image()
	if alpha_image == null:
		return albedo
	alpha_image = alpha_image.duplicate()
	if alpha_image.is_compressed() and alpha_image.decompress() != OK:
		return albedo
	alpha_image.convert(Image.FORMAT_RGBA8)
	if alpha_image.get_size() != albedo_image.get_size():
		alpha_image.resize(
			albedo_image.get_width(),
			albedo_image.get_height(),
			Image.INTERPOLATE_BILINEAR
		)

	for y in albedo_image.get_height():
		for x in albedo_image.get_width():
			var colour := albedo_image.get_pixel(x, y)
			# Multiplied, not replaced: where the source art is already
			# transparent it stays transparent, and the mask can only ever cut
			# more away. A mask that failed to see a hole cannot fill it back in.
			colour.a *= alpha_image.get_pixel(x, y).r
			albedo_image.set_pixel(x, y, colour)

	var texture := ImageTexture.create_from_image(albedo_image)
	host._composite_cache[key] = texture
	return texture


## Return one albedo with its alpha hard-thresholded at the canonical cutoff.
##
## This is the image-space equivalent of the surface shader's
## ALPHA_SCISSOR_THRESHOLD, using the same SHADOW_ALPHA_CUTOFF value, so a CUTOUT
## asset resolves to the same visible edge whether it is drawn as a terrain
## material or projected as a native Decal.
static func _alpha_scissored(host: SurfaceMaterialFactory, albedo: Texture2D, cache_key: String) -> Texture2D:
	if albedo == null:
		return null
	var cached: Texture2D = host._composite_cache.get(cache_key, null)
	if cached != null:
		return cached

	var image := albedo.get_image()
	if image == null:
		return albedo
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		return albedo
	image.convert(Image.FORMAT_RGBA8)
	for y: int in image.get_height():
		for x: int in image.get_width():
			var colour := image.get_pixel(x, y)
			colour.a = 1.0 if colour.a >= SurfaceMaterialFactory.SHADOW_ALPHA_CUTOFF else 0.0
			image.set_pixel(x, y, colour)

	var texture := ImageTexture.create_from_image(image)
	host._composite_cache[cache_key] = texture
	return texture


## Fade an albedo map toward neutral white while preserving every source alpha.
##
## This is the visual meaning of an albedo-channel strength knob: 0 removes the
## colour information without making the object disappear, 1 uses it exactly.
static func _scaled_albedo(host: SurfaceMaterialFactory, texture: Texture2D, key: String, strength: float) -> Texture2D:
	strength = clampf(strength, 0.0, 1.0)
	if is_equal_approx(strength, 1.0):
		return texture

	var cached: Texture2D = host._composite_cache.get(key, null)
	if cached != null:
		return cached

	var image := texture.get_image()
	if image == null:
		return texture
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		return texture
	image.convert(Image.FORMAT_RGBA8)

	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			image.set_pixel(x, y, Color(
				lerpf(1.0, pixel.r, strength),
				lerpf(1.0, pixel.g, strength),
				lerpf(1.0, pixel.b, strength),
				pixel.a
			))

	var adjusted := ImageTexture.create_from_image(image)
	host._composite_cache[key] = adjusted
	return adjusted


## Blend an analyzed albedo back toward the untouched source image, per pixel.
##
## `blend` 1.0 is the analyzed albedo exactly (Marigold's delit result, or
## whatever else produced this asset's "albedo" channel); 0.0 is the original
## source with none of the analysis colour correction. The analyzed albedo's
## own alpha is preserved throughout -- this only ever changes RGB, since the
## source image may have been authored with a different background/alpha
## convention than the analysis output.
static func _blend_albedo_with_source(host: SurfaceMaterialFactory, analyzed: Texture2D, source: Texture2D, key: String, blend: float) -> Texture2D:
	blend = clampf(blend, 0.0, 1.0)
	if is_equal_approx(blend, 1.0):
		return analyzed

	var cached: Texture2D = host._composite_cache.get(key, null)
	if cached != null:
		return cached

	var analyzed_image := analyzed.get_image()
	if analyzed_image == null:
		return analyzed
	analyzed_image = analyzed_image.duplicate()
	if analyzed_image.is_compressed() and analyzed_image.decompress() != OK:
		return analyzed
	analyzed_image.convert(Image.FORMAT_RGBA8)

	var source_image := source.get_image()
	if source_image == null:
		return analyzed
	source_image = source_image.duplicate()
	if source_image.is_compressed() and source_image.decompress() != OK:
		return analyzed
	source_image.convert(Image.FORMAT_RGBA8)
	if source_image.get_size() != analyzed_image.get_size():
		source_image.resize(
			analyzed_image.get_width(),
			analyzed_image.get_height(),
			Image.INTERPOLATE_BILINEAR
		)

	for y in analyzed_image.get_height():
		for x in analyzed_image.get_width():
			var lit := analyzed_image.get_pixel(x, y)
			var original := source_image.get_pixel(x, y)
			analyzed_image.set_pixel(x, y, Color(
				lerpf(original.r, lit.r, blend),
				lerpf(original.g, lit.g, blend),
				lerpf(original.b, lit.b, blend),
				lit.a
			))

	var blended := ImageTexture.create_from_image(analyzed_image)
	host._composite_cache[key] = blended
	return blended


## Apply a strength and additive bias to a single-channel material map.
##
## `neutral` defines what a zero-strength map means: AO/roughness fade toward 1
## while metallic fades toward 0. Values above strength 1 extrapolate and clamp,
## which gives the UI an intentional way to exaggerate recovered material data.
static func _adjust_scalar_map(host: SurfaceMaterialFactory,
	texture: Texture2D,
	key: String,
	strength: float,
	neutral: float,
	bias: float
) -> Texture2D:
	if is_equal_approx(strength, 1.0) and is_zero_approx(bias):
		return texture

	var cached: Texture2D = host._composite_cache.get(key, null)
	if cached != null:
		return cached

	var image := texture.get_image()
	if image == null:
		return texture
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		return texture
	image.convert(Image.FORMAT_RGBA8)

	for y in image.get_height():
		for x in image.get_width():
			var source := image.get_pixel(x, y)
			var value := clampf(lerpf(neutral, source.r, strength) + bias, 0.0, 1.0)
			image.set_pixel(x, y, Color(value, value, value, source.a))

	var adjusted := ImageTexture.create_from_image(image)
	host._composite_cache[key] = adjusted
	return adjusted
