@tool
extends Node

const REPORT_PATH := "res://exports/blackridge_depths_revision/native_import_report.json"

## Schedule the bounded native import after returning control to the director.
func start() -> void:
	call_deferred("_run_import")

## Import the explicit BDR source batch with native sizing, occupancy and valid runtime optimization.
func _run_import() -> void:
	var bridge: Node = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false)
	var library: AssetLibrary = bridge.plugin.library
	var importer := GLBAssetImporter.new()
	var kit: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://exports/blackridge_depths_revision/kit.json"))
	var jobs: Array[Dictionary] = []
	for name: String in kit:
		var item: Dictionary = kit[name]
		var dims: Array = item["grid"]
		var axis: int = int(item["axis"])
		jobs.append({"id": item["asset_id"], "path": item["path"], "grid": Vector3i(dims[0], dims[1], dims[2]), "axis": axis, "optimize": false})
	jobs.append({"id":"BDR_BINDING_RELIQUARY","path":"C:/Users/conra/Desktop/ModularTileKitStudio/assets/blackridge_depths_revision/meshy/binding_reliquary.glb","grid":Vector3i(2,2,2),"axis":0,"optimize":true})
	var results: Array[Dictionary] = []
	for index: int in jobs.size():
		var job: Dictionary = jobs[index]
		var id: String = job["id"]
		if library.has_asset(id):
			results.append({"id":id,"ok":true,"existing":true})
			continue
		_write_report({"status":"running","current":id,"completed":index,"total":jobs.size(),"results":results})
		var asset: TileAsset = await importer.import_glb(job["path"], {
			"asset_id":id,"display_name":id.replace("BDR_","").capitalize(),"biome":"blackridge_depths",
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
	var image_importer := ImageAssetImporter.new()
	for name: String in ["bdr_floor_source","bdr_wall_source"]:
		var id: String = "BDR_FRACTURED_FLOOR" if name == "bdr_floor_source" else "BDR_MINERAL_WALL"
		if library.has_asset(id):
			continue
		var directory: String = "res://assets/blackridge_depths_revision/"+name+"_chord/"
		var surface: TileAsset = image_importer.import_image(directory+"albedo.png", {
			"asset_id":id,"display_name":"BDR "+name.capitalize(),"biome":"blackridge_depths","width_m":3 if name == "bdr_floor_source" else 4,"height_m":3 if name == "bdr_floor_source" else 4,"remove_background":false
		},library)
		if surface == null:
			_write_report({"status":"failed","current":id,"results":results})
			queue_free()
			return
		for channel: String in ["albedo","normal","roughness","metallic"]:
			var destination: String = surface.derived_dir.path_join(channel+".png")
			var copy_error: Error = DirAccess.copy_absolute(ProjectSettings.globalize_path(directory+channel+".png"),ProjectSettings.globalize_path(destination))
			if copy_error != OK:
				_write_report({"status":"failed","current":id,"channel":channel,"error":copy_error})
				queue_free()
				return
			surface.gbuffer.set_channel(channel,destination)
		surface.stochastic_tiling=true
		surface.random_texture_mirroring=true
		surface.random_texture_rotation=name == "bdr_floor_source"
		surface.analysis_status="complete"
		surface.processing["analysis_recipe"]="chord_material_api"
		surface.processing["analysis_source"]=directory+"job.json"
		ResourceSaver.save(surface,surface.resource_path)
		results.append({"id":id,"ok":true,"channels":["albedo","normal","roughness","metallic"]})
	library.rebuild_index()
	var save_error: Error = library.save()
	_write_report({"status":"succeeded" if save_error == OK else "failed","save_error":save_error,"results":results})
	queue_free()

## Preserve a compact recoverable progress record without including remote secrets.
func _write_report(payload: Dictionary) -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[BDR] could not write native import report")
		return
	file.store_string(JSON.stringify(payload,"  "))
	file.close()
