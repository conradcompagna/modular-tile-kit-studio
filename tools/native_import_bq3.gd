@tool
extends Node

const REPORT_PATH := "res://exports/blackridge_quarantine_revision03/native_import_report.json"

## Schedule the explicitly owned seven-asset native import without blocking the editor.
func start() -> void:
	call_deferred("_run_import")

## Preserve literal architecture dimensions and optimize the one new Meshy kiosk through the native path.
func _run_import() -> void:
	var bridge: Node = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false)
	var library: AssetLibrary = bridge.plugin.library
	var importer := GLBAssetImporter.new()
	var jobs: Array[Dictionary] = []
	for filename: String in ["kit.json", "furnishing_kit.json"]:
		var kit: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://exports/blackridge_quarantine_revision03/"+filename))
		for name: String in kit:
			var item: Dictionary = kit[name]
			var dims: Array = item["grid"]
			jobs.append({"id":item["asset_id"],"path":item["path"],"grid":Vector3i(dims[0],dims[1],dims[2]),"axis":0,"optimize":false})
	jobs.append({"id":"BQ3_INSPECTION_KIOSK","path":"C:/Users/conra/Desktop/ModularTileKitStudio/assets/blackridge_quarantine_revision03/meshy/inspection_kiosk.glb","grid":Vector3i(3,3,3),"axis":1,"optimize":true})
	var results: Array[Dictionary] = []
	for index: int in jobs.size():
		var job: Dictionary = jobs[index]
		var id: String = job["id"]
		if library.has_asset(id):
			results.append({"id":id,"ok":true,"existing":true})
			continue
		_write_report({"status":"running","current":id,"completed":index,"total":jobs.size(),"results":results})
		var asset: TileAsset = await importer.import_glb(job["path"], {
			"asset_id":id,"display_name":id.replace("BQ3_","").capitalize(),"biome":"blackridge_quarantine",
			"grid_size":job["grid"],"driver_axis":job["axis"],"stretch_to_grid":false,
			"optimize_mesh":job["optimize"],"mesh_target_ratio":0.5,"max_texture_size":2048
		},library)
		if asset == null:
			_write_report({"status":"failed","current":id,"results":results})
			queue_free()
			return
		if bool(job["optimize"]):
			# The installed optimized triangles are the source of the final pose and both voxel scans.
			var installed: Node3D = importer._load_external_model(asset.prop_runtime_path)
			var measured: AABB = importer.canonicalizer.compute_bounds(installed)
			var plan: Dictionary = importer.canonicalizer.compute_grid_plan(measured.size,asset.requested_grid_size,asset.size_driver_axis,false)
			var generated: Dictionary = importer._build_prop_geometry(installed,measured,plan)
			installed.free()
			if not generated.get("ok",false):
				_write_report({"status":"failed","current":id,"error":"Installed optimized geometry remeasure failed."})
				queue_free()
				return
			asset.grid_bounds=plan["grid_size"]
			asset.requested_grid_size=plan["grid_size"]
			asset.visual_size_m=plan["actual_size"]
			asset.prop_pose_transform=generated["pose"]["transform"]
			asset.prop_voxels.assign(generated["voxels"])
			asset.prop_voxels_diagonal.assign(generated["diagonal_voxels"])
			asset.prop_voxel_triangle_shares_percent=generated["voxel_triangle_shares_percent"]
			asset.prop_voxel_diagonal_triangle_shares_percent=generated["diagonal_voxel_triangle_shares_percent"]
			asset.processing["collision_measurement_source"]=asset.prop_runtime_path
			ResourceSaver.save(asset,asset.resource_path)
		results.append({"id":id,"ok":true,"grid":str(asset.grid_bounds),"visual_size_m":str(asset.visual_size_m),"pose":str(asset.prop_pose_transform),"runtime_path":asset.prop_model_path(),"metrics":asset.prop_runtime_metrics,"voxels":asset.prop_voxels.size()})
		library.save()
	library.rebuild_index()
	var save_error: Error = library.save()
	_write_report({"status":"succeeded" if save_error == OK else "failed","save_error":save_error,"results":results})
	queue_free()

## Persist bounded progress and measurements without including remote credentials.
func _write_report(payload: Dictionary) -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(payload,"  "))
	file.close()
