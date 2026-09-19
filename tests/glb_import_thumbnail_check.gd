extends SceneTree

var importer_script
var library_script


## Start the graphical integration check after the editor-style SceneTree exists.
func _init() -> void:
	importer_script = load("res://addons/modular_tile_studio/importers/glb_asset_importer.gd")
	library_script = load("res://addons/modular_tile_studio/data/asset_library.gd")
	call_deferred("_run_check")


## Import a real GLB through the production path and verify its saved thumbnail.
func _run_check() -> void:
	if DisplayServer.get_name() == "headless":
		print("glb_import_thumbnail_check: skipped (headless renderer has no safe offscreen 3D capture)")
		quit(0)
		return

	var source := "res://tile_library/assets/FOUNTAIN_REAL/source/Meshy_AI_Ancient_Stone_Fountai_0723053905_texture.glb"
	var importer = importer_script.new()
	var library = library_script.new()
	var asset: TileAsset = await importer.import_glb(
		source,
		{
			"asset_id": "__codex_glb_thumbnail_check__",
			"display_name": "Thumbnail Check",
		},
		library
	)
	if asset == null:
		push_error("GLB import thumbnail integration check produced no asset")
		quit(1)
		return

	var thumbnail_path := asset.thumbnail_path
	var image := Image.new()
	var load_error := image.load(ProjectSettings.globalize_path(thumbnail_path))
	var background := image.get_pixel(0, 0) if load_error == OK else Color.BLACK
	var differing_pixels := 0
	if load_error == OK:
		for y in image.get_height():
			for x in image.get_width():
				var pixel := image.get_pixel(x, y)
				var colour_delta := absf(pixel.r - background.r) + absf(pixel.g - background.g) + absf(pixel.b - background.b)
				if colour_delta > 0.06:
					differing_pixels += 1

	var removed_bytes: int = library.delete_asset_files(asset.asset_id)
	print("glb_import_thumbnail_check: path=%s, size=%dx%d, differing_pixels=%d, removed_bytes=%d" % [
		thumbnail_path,
		image.get_width(),
		image.get_height(),
		differing_pixels,
		removed_bytes,
	])
	if load_error != OK or differing_pixels == 0:
		quit(1)
		return
	quit(0)
