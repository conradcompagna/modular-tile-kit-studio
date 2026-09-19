@tool
extends Node

const REPORT_PATH := "res://exports/blackridge_quarantine_revision/native_import_report.json"

## Schedule the bounded native import after returning control to the director.
func start() -> void:
	call_deferred("_run_import")

## Import the explicit BQR source batch with native sizing, occupancy and valid runtime optimization.
func _run_import() -> void:
	var bridge: Node = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false)
	var library: AssetLibrary = bridge.plugin.library
	var importer := GLBAssetImporter.new()
	var kit: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://exports/blackridge_quarantine_revision/kit.json"))
	var jobs: Array[Dictionary] = []
	for name: String in kit:
		var item: Dictionary = kit[name]
		var dims: Array = item["grid"]
		var axis: int = 1 if name.begins_with("propaganda_") else 0
		jobs.append({"id": item["asset_id"], "path": item["path"], "grid": Vector3i(dims[0], dims[1], dims[2]), "axis": axis, "optimize": false})
	for item: Dictionary in [
		{"name":"upright_specimen","grid":Vector3i(3,3,3),"axis":1},
		{"name":"occult_table","grid":Vector3i(3,2,3),"axis":2},
		{"name":"suspended_husk","grid":Vector3i(3,3,3),"axis":1}
	]:
		jobs.append({"id":"BQR_"+String(item["name"]).to_upper(), "path":"C:/Users/conra/Desktop/ModularTileKitStudio/assets/blackridge_quarantine_revision/meshy/"+item["name"]+".glb", "grid":item["grid"], "axis":item["axis"], "optimize":true})
	var results: Array[Dictionary] = []
	for index: int in jobs.size():
		var job: Dictionary = jobs[index]
		var id: String = job["id"]
		if library.has_asset(id):
			results.append({"id":id,"ok":true,"existing":true})
			continue
		_write_report({"status":"running","current":id,"completed":index,"total":jobs.size(),"results":results})
		# The hash-guarded upright exception never applies to any other asset.
		importer.runtime_optimizer = load("res://tools/bqr_upright_optimizer.gd").new() if id == "BQR_UPRIGHT_SPECIMEN" else load("res://addons/modular_tile_studio/importers/glb_runtime_optimizer.gd").new()
		var asset: TileAsset = await importer.import_glb(job["path"], {
			"asset_id":id,"display_name":id.replace("BQR_","").capitalize(),"biome":"blackridge_quarantine",
			"grid_size":job["grid"],"driver_axis":job["axis"],"stretch_to_grid":false,
			"optimize_mesh":job["optimize"],"mesh_target_ratio":0.5,"max_texture_size":2048
		},library)
		if asset == null:
			_write_report({"status":"failed","current":id,"results":results})
			queue_free()
			return
		if id == "BQR_UPRIGHT_SPECIMEN":
			# Rebuild the canonical pose and both scans from the actual installed optimized triangles.
			var installed: Node3D = importer._load_external_model(asset.prop_runtime_path)
			var measured: AABB = importer.canonicalizer.compute_bounds(installed)
			var plan: Dictionary = importer.canonicalizer.compute_grid_plan(measured.size,asset.requested_grid_size,asset.size_driver_axis,false)
			var generated: Dictionary = importer._build_prop_geometry(installed,measured,plan)
			installed.free()
			if not generated.get("ok",false):
				_write_report({"status":"failed","current":id,"error":"Installed optimized source geometry remeasure failed."})
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
			asset.processing["bounds_exception_report"]="res://reports/blackridge_quarantine_revision/UPRIGHT_OPTIMIZATION_EXCEPTION.json"
			ResourceSaver.save(asset,asset.resource_path)
		results.append({"id":id,"ok":true,"grid":str(asset.grid_bounds),"pose":str(asset.prop_pose_transform),
			"runtime_path":asset.prop_model_path(),"metrics":asset.prop_runtime_metrics,"voxels":asset.prop_voxels.size()})
		library.save()
	var image_importer := ImageAssetImporter.new()
	for name: String in ["exterior_brick","city_setts"]:
		var id: String = "BQR_"+name.to_upper()
		if library.has_asset(id):
			continue
		var directory: String = "res://assets/blackridge_quarantine_revision/"+name+"_chord/"
		var surface: TileAsset = image_importer.import_image(directory+"albedo.png", {
			"asset_id":id,"display_name":"BQR "+name.capitalize(),"biome":"blackridge_quarantine","width_m":2 if name == "exterior_brick" else 4,"height_m":2 if name == "exterior_brick" else 4,"remove_background":false
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
		push_error("[BQR] could not write native import report")
		return
	file.store_string(JSON.stringify(payload,"  "))
	file.close()
