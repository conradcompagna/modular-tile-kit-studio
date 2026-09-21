@tool
extends RefCounted

## Textures behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

static func _solid_texture(colour: Color, format: int = Image.FORMAT_RGBA8) -> ImageTexture:
	var image := Image.create(1, 1, false, format)
	image.set_pixel(0, 0, colour)
	return ImageTexture.create_from_image(image)


static func _white_texture() -> ImageTexture:
	if SurfaceMaterialFactory._gpu_white == null:
		SurfaceMaterialFactory._gpu_white = SurfaceMaterialFactory._solid_texture(Color.WHITE)
	return SurfaceMaterialFactory._gpu_white


static func _black_texture() -> ImageTexture:
	if SurfaceMaterialFactory._gpu_black == null:
		SurfaceMaterialFactory._gpu_black = SurfaceMaterialFactory._solid_texture(Color(0.0, 0.0, 0.0, 1.0))
	return SurfaceMaterialFactory._gpu_black


static func _normal_texture() -> ImageTexture:
	if SurfaceMaterialFactory._gpu_normal == null:
		SurfaceMaterialFactory._gpu_normal = SurfaceMaterialFactory._solid_texture(Color(0.5, 0.5, 1.0, 1.0))
	return SurfaceMaterialFactory._gpu_normal


static func _error_texture() -> ImageTexture:
	if SurfaceMaterialFactory._gpu_error == null:
		SurfaceMaterialFactory._gpu_error = SurfaceMaterialFactory._solid_texture(Color(0.8, 0.3, 0.6, 1.0))
	return SurfaceMaterialFactory._gpu_error


## Return the shorter pixel dimension of one source height map.
##
## The image supplies the source sample count; the board's parallax scale turns
## it into material lookup travel without changing terrain geometry.
static func height_image_short_edge_px(asset: TileAsset) -> float:
	if asset == null or not asset.is_surface() or asset.gbuffer == null:
		return 0.0
	var height_texture := asset.gbuffer.load_texture("height")
	if height_texture == null:
		return 0.0

	var image_size := Vector2i(height_texture.get_width(), height_texture.get_height())
	if image_size.x <= 0 or image_size.y <= 0:
		push_error("[Tile Studio] Height map for '%s' has invalid image dimensions." % asset.asset_id)
		return 0.0
	return float(mini(image_size.x, image_size.y))


## Load a freshly written render, tolerating the resource filesystem not having
## imported it yet.
##
## Renders are produced during import and used moments later, so ResourceLoader
## often does not know them. Falling back to a direct Image load avoids the race
## that would otherwise leave a just-imported prop invisible.
static func _load_view_texture(host: SurfaceMaterialFactory, path: String) -> Texture2D:
	if path.is_empty():
		return null
	if ResourceLoader.exists(path):
		var res := ResourceLoader.load(path) as Texture2D
		if res != null:
			return res
	var global_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global_path):
		var image := Image.new()
		if image.load(global_path) == OK and not image.is_empty():
			return ImageTexture.create_from_image(image)
	return null
