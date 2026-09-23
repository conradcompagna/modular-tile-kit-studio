@tool
extends RefCounted

## Orm behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

## Return whether a map set can provide the packed runtime scalar channels.
##
## A stored ORM is authoritative; separate primary AO, roughness, and metallic
## maps are packed only when that baked artifact is absent.
static func _has_primary_orm_source(maps: GBufferMapSet) -> bool:
	return (
		maps != null
		and (
			maps.has_channel("orm")
			or maps.has_channel("ambient_occlusion")
			or maps.has_channel("roughness")
			or maps.has_channel("metallic")
		)
	)


## Return a cached ORM texture resolved only from final primary scalar channels.
##
## Analysis-only cavity and curvature files are intentionally absent here. Their
## authored bake operation must fold them into ORM before runtime consumption.
static func _resolved_layer_orm(host: SurfaceMaterialFactory, asset: TileAsset) -> Texture2D:
	if asset == null or asset.gbuffer == null:
		return host._neutral_orm_texture()
	var maps := asset.gbuffer
	var direct := maps.load_texture("orm")
	if direct != null:
		return direct
	var key := "layer_orm|%s|%s|%s|%s" % [
		asset.asset_id,
		maps.get_channel("ambient_occlusion"),
		maps.get_channel("roughness"),
		maps.get_channel("metallic"),
	]
	var cached := host._composite_cache.get(key, null) as Texture2D
	if cached != null:
		return cached
	var packed := host._pack_orm_channels(
		maps.load_texture("ambient_occlusion"),
		maps.load_texture("roughness"),
		maps.load_texture("metallic")
	)
	host._composite_cache[key] = packed
	return packed


## Combine resolved scalar textures into one runtime ORM image for overlay sampling.
static func _pack_orm_channels(host: SurfaceMaterialFactory,
	ao: Texture2D,
	roughness: Texture2D,
	metallic: Texture2D
) -> Texture2D:
	var resolution := Vector2i.ONE
	for texture: Texture2D in [ao, roughness, metallic]:
		if texture != null:
			resolution = Vector2i(
				maxi(resolution.x, texture.get_width()),
				maxi(resolution.y, texture.get_height())
			)
	var ao_image := host._scalar_channel_image(ao, resolution, 1.0)
	var roughness_image := host._scalar_channel_image(roughness, resolution, 1.0)
	var metallic_image := host._scalar_channel_image(metallic, resolution, 0.0)
	var packed := Image.create(
		resolution.x,
		resolution.y,
		false,
		Image.FORMAT_RGB8
	)
	for y: int in resolution.y:
		for x: int in resolution.x:
			packed.set_pixel(
				x,
				y,
				Color(
					ao_image.get_pixel(x, y).r,
					roughness_image.get_pixel(x, y).r,
					metallic_image.get_pixel(x, y).r,
					1.0
				)
			)
	return ImageTexture.create_from_image(packed)


## Return one decompressed, resized scalar image or a constant explicit value.
static func _scalar_channel_image(host: SurfaceMaterialFactory,
	texture: Texture2D,
	resolution: Vector2i,
	default_value: float
) -> Image:
	var image: Image = texture.get_image() if texture != null else null
	if image == null:
		image = Image.create(
			resolution.x,
			resolution.y,
			false,
			Image.FORMAT_RGBA8
		)
		image.fill(Color(default_value, default_value, default_value, 1.0))
		return image
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		push_error("SurfaceMaterialFactory: cannot decompress a material layer channel.")
		image = Image.create(
			resolution.x,
			resolution.y,
			false,
			Image.FORMAT_RGBA8
		)
		image.fill(Color(default_value, default_value, default_value, 1.0))
		return image
	image.convert(Image.FORMAT_RGBA8)
	if image.get_size() != resolution:
		image.resize(resolution.x, resolution.y, Image.INTERPOLATE_LANCZOS)
	return image


## Return one explicit AO=1, roughness=1, metallic=0 packed texture.
static func _neutral_orm_texture(host: SurfaceMaterialFactory) -> ImageTexture:
	var texture: ImageTexture = host._composite_cache.get("neutral_layer_orm", null)
	if texture != null:
		return texture
	var image := Image.create(1, 1, false, Image.FORMAT_RGB8)
	image.fill(Color(1.0, 1.0, 0.0, 1.0))
	texture = ImageTexture.create_from_image(image)
	host._composite_cache["neutral_layer_orm"] = texture
	return texture


## Return one black Texture2DArray for batch materials that have no painted pixels yet.
static func _neutral_material_control_array(host: SurfaceMaterialFactory) -> Texture2DArray:
	var cached := host._composite_cache.get("neutral_material_control_array", null) as Texture2DArray
	if cached != null:
		return cached
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var texture := Texture2DArray.new()
	var create_error := texture.create_from_images([image])
	if create_error != OK:
		push_error(
			"SurfaceMaterialFactory: cannot create neutral material control array (%s)."
			% error_string(create_error)
		)
		return null
	host._composite_cache["neutral_material_control_array"] = texture
	return texture


## Prevent a normalized shader range from dividing by zero on a flat board.
static func _nonzero_range(host: SurfaceMaterialFactory, value: Vector2) -> Vector2:
	if not value.is_finite():
		return Vector2(0.0, 1.0)
	if value.y - value.x < 0.000001:
		return Vector2(value.x, value.x + 0.000001)
	return value
