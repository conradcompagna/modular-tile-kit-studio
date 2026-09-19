@tool
extends Node

const REPORT_PATH := "res://exports/blackridge_depths_revision03/native_import_report.json"

## Schedule the bounded native import after returning control to the director.
func start() -> void:
	call_deferred("_run_import")

## Import the explicit BD3 source batch with native sizing, occupancy and valid runtime optimization.
func _run_import() -> void:
	var bridge: Node = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false)
	var library: AssetLibrary = bridge.plugin.library
	var importer := GLBAssetImporter.new()
	var kit: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://exports/blackridge_depths_revision03/kit.json"))
	var jobs: Array[Dictionary] = []
	for name: String in kit:
		var item: Dictionary = kit[name]
		var dims: Array = item["grid"]
		var axis: int = int(item["axis"])
		jobs.append({"id": item["asset_id"], "path": item["path"], "grid": Vector3i(dims[0], dims[1], dims[2]), "axis": axis, "optimize": false})
	var results: Array[Dictionary] = []
	for index: int in jobs.size():
		var job: Dictionary = jobs[index]
		var id: String = job["id"]
		if library.has_asset(id):
			results.append({"id":id,"ok":true,"existing":true})
			continue
		_write_report({"status":"running","current":id,"completed":index,"total":jobs.size(),"results":results})
		var asset: TileAsset = await importer.import_glb(job["path"], {
			"asset_id":id,"display_name":id.replace("BD3_","").capitalize(),"biome":"blackridge_depths",
			"grid_size":job["grid"],"driver_axis":job["axis"],"stretch_to_grid":false,
			"optimize_mesh":job["optimize"],"mesh_target_ratio":0.5,"max_texture_size":2048
		},library)
		if asset == null:
			_write_report({"status":"failed","current":id,"results":results})
			queue_free()
			return
		results.append({"id":id,"ok":true,"grid":str(asset.grid_bounds),"pose":str(asset.prop_pose_transform),
			"runtime_path":asset.prop_model_path(),"metrics":asset.prop_runtime_metrics,"voxels":asset.prop_voxels.size()})
		library.save()
	library.rebuild_index()
	var save_error: Error = library.save()
	_write_report({"status":"succeeded" if save_error == OK else "failed","save_error":save_error,"results":results})
	queue_free()

## Preserve a compact recoverable progress record without including remote secrets.
func _write_report(payload: Dictionary) -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[BD3] could not write native import report")
		return
	file.store_string(JSON.stringify(payload,"  "))
	file.close()
