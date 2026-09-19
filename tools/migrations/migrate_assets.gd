@tool
extends SceneTree

## One-shot library migration.
##
## Two jobs, both of which exist because the data on disk predates fixes to the
## code that produced it:
##
##   Props with completely empty impostor renders are reported. An empty
##      render means the offscreen capture failed at import (blank PNGs), so the
##      prop draws as nothing. They are listed, not deleted, because deleting
##      board-referenced assets is destructive -- the caller decides.
##
## Run:  godot --headless --script tools/migrate_assets.gd

const K := preload("res://addons/modular_tile_studio/utils/mts_constants.gd")


func _init() -> void:
	var root := "res://tile_library/assets"
	var dir := DirAccess.open(root)
	if dir == null:
		print("[migrate] no asset directory at %s" % root)
		quit()
		return

	var empty_props: Array[String] = []
	var good_props := 0

	for name in dir.get_directories():
		var tres := root.path_join(name).path_join("asset.tres")
		if not FileAccess.file_exists(ProjectSettings.globalize_path(tres)):
			continue
		var asset: TileAsset = load(tres)
		if asset == null:
			continue

		if asset.is_prop():
			if _prop_renders_are_empty(asset):
				empty_props.append(asset.asset_id)
			else:
				good_props += 1

	print("")
	print("[migrate] props with usable renders: %d" % good_props)
	print("[migrate] props with EMPTY renders: %d" % empty_props.size())
	for id in empty_props:
		print("    %s" % id)
	quit()


## True when every facing's render is missing, unreadable, or fully transparent.
##
## Sampled on a coarse lattice rather than per pixel: a render that contains any
## art at all lights up immediately, and this runs over the whole library.
func _prop_renders_are_empty(asset: TileAsset) -> bool:
	for facing_name in ["N", "E", "S", "W"]:
		var path: String = asset.view_renders.get(facing_name, "")
		if path.is_empty():
			continue
		var image := Image.new()
		if image.load(ProjectSettings.globalize_path(path)) != OK or image.is_empty():
			continue
		var w := image.get_width()
		var h := image.get_height()
		var step: int = maxi(1, int(mini(w, h) / 64))
		var x := 0
		while x < w:
			var y := 0
			while y < h:
				if image.get_pixel(x, y).a > 0.02:
					return false
				y += step
			x += step
	return true
