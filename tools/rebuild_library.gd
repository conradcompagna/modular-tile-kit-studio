@tool
extends SceneTree

## Rebuild the library index from the assets actually present on disk.
##
## The index holds ext_resource references, so deleting an asset folder leaves a
## dangling entry that makes the library fail to load cleanly. Rescanning is the
## honest repair: the folders are the source of truth, the index is a cache of
## them.
##
## Run:  godot --headless --script tools/rebuild_library.gd

const K := preload("res://addons/modular_tile_studio/utils/mts_constants.gd")


func _init() -> void:
	var root := K.ASSETS_DIR
	var dir := DirAccess.open(root)
	if dir == null:
		print("[rebuild] no asset directory at %s" % root)
		quit()
		return

	var library := AssetLibrary.new()
	var loaded := 0
	var skipped := 0

	var names := dir.get_directories()
	names.sort()
	for name in names:
		var tres := root.path_join(name).path_join("asset.tres")
		if not FileAccess.file_exists(ProjectSettings.globalize_path(tres)):
			continue
		var asset: TileAsset = load(tres)
		if asset == null:
			print("[rebuild] SKIP unreadable %s" % tres)
			skipped += 1
			continue
		library.add_asset(asset)
		loaded += 1
		print("[rebuild] %s (%s)" % [
			asset.asset_id, "surface" if asset.is_surface() else "prop"
		])

	if ResourceSaver.save(library, K.LIBRARY_RESOURCE_PATH) == OK:
		print("")
		print("[rebuild] wrote %s with %d assets (%d skipped)" % [
			K.LIBRARY_RESOURCE_PATH, loaded, skipped
		])
	else:
		push_error("[rebuild] could not save library")
	quit()
