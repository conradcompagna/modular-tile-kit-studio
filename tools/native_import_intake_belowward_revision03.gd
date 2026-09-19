@tool
extends Node

## Start a deferred native import job and persist progress so timeouts cannot duplicate assets.
func start() -> void:
	_write({"status":"started","results":[]})
	call_deferred("_run")

## Import the four revision03 sources with the native canonical pose and measured occupancy using the canonical plugin paths.
func _run() -> void:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge",true,false).plugin
	var jobs: Array = JSON.parse_string(FileAccess.get_file_as_string("res://exports/blackridge_intake_revision03/kit.json")).values()
	jobs.append(JSON.parse_string(FileAccess.get_file_as_string("res://exports/blackridge_intake_revision03/stele_finished.json")))
	jobs.append_array(JSON.parse_string(FileAccess.get_file_as_string("res://exports/belowward_revision03/kit.json")).values())
	var importer: GLBAssetImporter = GLBAssetImporter.new()
	var results: Array[Dictionary] = []
	for job: Dictionary in jobs:
		var id := String(job.asset_id)
		var asset: TileAsset = plugin.library.get_asset(id)
		if asset == null:
			var g: Array = job.grid
			asset = await importer.import_glb(String(job.path),{"asset_id":id,"display_name":id.replace("BIR_","Intake ").replace("_"," "),"biome":"blackridge_revision03","grid_size":Vector3i(g[0],g[1],g[2]),"driver_axis":int(job.driver_axis),"stretch_to_grid":false,"optimize_mesh":id=="BI3_PANOPTICON_STELE","mesh_target_ratio":0.5,"max_texture_size":2048},plugin.library)
		if asset == null:
			_write({"status":"failed","asset":id,"results":results})
			queue_free()
			return
		results.append({"id":id,"grid":asset.grid_bounds,"pose":asset.prop_pose_transform,"source":asset.source_path,"voxels":asset.prop_voxels.size(),"actual_size":asset.visual_size_m,"runtime":asset.prop_model_path(),"processing":asset.processing})
		_write({"status":"running","completed":results.size(),"results":results})
	plugin.library.rebuild_index()
	var saved: int = plugin.library.save()
	_write({"status":"succeeded" if saved==OK else "failed","save_error":saved,"results":results})
	EditorInterface.get_resource_filesystem().scan()
	queue_free()

## Write each completed phase into a local report rather than relying on transient editor output.
func _write(payload: Dictionary) -> void:
	var file := FileAccess.open("res://exports/blackridge_intake_revision03/native_import.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(payload,"  "))
	file.close()
