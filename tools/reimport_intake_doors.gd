@tool
extends RefCounted

## Install the three corrected door sources without changing any shared asset or authored pose.
func copy_sources() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false).plugin
	var importer := GLBAssetImporter.new()
	var paths := PackedStringArray()
	for name: String in ["authority_door", "arrival_door", "service_door"]:
		var asset: TileAsset = plugin.library.get_asset("BIR_" + name.to_upper())
		var source := "res://assets/blackridge_intake_revision/" + name + ".glb"
		var error := importer._copy_file(source, asset.source_path)
		if error != OK:
			return {"ok": false, "asset": asset.asset_id, "error": error}
		paths.append(asset.source_path)
	return {"ok": true, "reimport_paths": paths}

## Recalculate each corrected door from the freshly reimported canonical GLB and update its native thumbnail.
func rebuild_assets() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false).plugin
	var importer := GLBAssetImporter.new()
	var results: Array[Dictionary] = []
	for name: String in ["authority_door", "arrival_door", "service_door"]:
		var asset: TileAsset = plugin.library.get_asset("BIR_" + name.to_upper())
		var scene: PackedScene = ResourceLoader.load(asset.source_path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE)
		if scene == null or not importer.rebuild_prop(asset, {"rebuild_geometry": true, "optimize_mesh": false}):
			return {"ok": false, "asset": asset.asset_id}
		var model: Node3D = scene.instantiate()
		var thumbnail: Image = await importer._render_thumbnail(model, asset.prop_pose_transform, 128)
		model.queue_free()
		if thumbnail == null or thumbnail.save_png(asset.thumbnail_path) != OK:
			return {"ok": false, "asset": asset.asset_id, "phase": "thumbnail"}
		results.append({"id": asset.asset_id, "voxels": asset.prop_voxels.size(), "size": asset.visual_size_m, "triangles": asset.processing.get("collision_triangle_count", 0)})
	plugin.library.rebuild_index()
	var saved: int = plugin.library.save()
	var report := {"ok": saved == OK, "results": results}
	var file := FileAccess.open("res://exports/blackridge_intake_revision/door_refresh.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	return report
