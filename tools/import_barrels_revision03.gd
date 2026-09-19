@tool
extends RefCounted

## Import the new two-metre cluster using X as sizing authority so the literal sub-adult cask heights remain unchanged.
func run() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false).plugin
	var asset: TileAsset = plugin.library.get_asset("BR3_BARREL_CLUSTER")
	if asset == null:
		asset = await GLBAssetImporter.new().import_glb("C:/Users/conra/Desktop/ModularTileKitStudio/assets/blackridge_barrels_revision03/barrel_cluster.glb", {"asset_id": "BR3_BARREL_CLUSTER", "display_name": "Ordinary coopered casks — 1.10 / 0.90 / 0.70 m", "biome": "blackridge_revision03", "grid_size": Vector3i(2,2,2), "driver_axis": 0, "stretch_to_grid": false, "optimize_mesh": false}, plugin.library)
	if asset == null:
		return {"ok": false}
	plugin.library.rebuild_index()
	var saved: int = plugin.library.save()
	var report := {"ok": saved == OK, "asset": asset.asset_id, "actual_size": asset.visual_size_m, "grid": asset.grid_bounds, "pose": asset.prop_pose_transform, "voxels": asset.prop_voxels.size(), "source": asset.source_path}
	var file := FileAccess.open("res://exports/blackridge_barrels_revision03/native_import.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	return report
