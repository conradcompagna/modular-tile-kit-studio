@tool
extends Node

## Persist the import progress so a long native GLB pass remains inspectable after
## the editor bridge returns control to the caller.
const REPORT_PATH := "res://exports/blackridge_intake/native_import_report.json"

## Keep the BI import job list explicit so each source, identity, grid and
## optimization setting remains auditable in the generated report.
var _jobs: Array[Dictionary] = [
	{"id": "BI_AUTHORITY_GATE", "name": "BI Authority Gate", "file": "authority_gate.glb", "grid": Vector3i(12, 12, 3)},
	{"id": "BI_DESCENT_ARCH", "name": "BI Descent Arch", "file": "descent_arch.glb", "grid": Vector3i(6, 6, 2)},
	{"id": "BI_AUTHORITY_BANNER", "name": "BI Authority Banner", "file": "authority_banner.glb", "grid": Vector3i(3, 8, 1)},
	{"id": "BI_RECORDS_SHELF", "name": "BI Records Shelf", "file": "records_shelf.glb", "grid": Vector3i(3, 3, 1)},
	{"id": "BI_HOLDING_GATE", "name": "BI Holding Gate", "file": "holding_gate.glb", "grid": Vector3i(6, 3, 1)},
	{"id": "BI_HOLDING_BENCH", "name": "BI Holding Bench", "file": "holding_bench.glb", "grid": Vector3i(3, 2, 1)},
	{"id": "BI_PROPERTY_CART", "name": "BI Property Cart", "file": "property_cart.glb", "grid": Vector3i(3, 2, 2)},
	{"id": "BI_CELL_A1", "name": "BI Cell A1", "file": "cell_a1.glb", "grid": Vector3i(4, 5, 2)},
	{"id": "BI_CELL_A2", "name": "BI Cell A2", "file": "cell_a2.glb", "grid": Vector3i(4, 5, 2)},
	{"id": "BI_CELL_B1", "name": "BI Cell B1", "file": "cell_b1.glb", "grid": Vector3i(4, 5, 2)}
]

## Start the deferred import so the editor bridge can return immediately while
## each native voxel scan, thumbnail render and optional runtime optimization runs.
func start() -> void:
	_write_report({"status": "started", "completed": 0, "total": _jobs.size(), "results": []})
	call_deferred("_run_import")

## Import every BI source through the native importer and save the library only
## after all ten assets have completed successfully.
func _run_import() -> void:
	var bridge: Node = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false)
	if bridge == null:
		_write_report({"status": "failed", "error": "MTSStudioBridge not found"})
		queue_free()
		return
	var plugin: Variant = bridge.plugin
	var library: AssetLibrary = plugin.library
	var importer := GLBAssetImporter.new()
	var results: Array[Dictionary] = []
	for index: int in _jobs.size():
		var job: Dictionary = _jobs[index]
		var desired_id := String(job["id"])
		if library.has_asset(desired_id):
			results.append({"id": desired_id, "ok": true, "skipped": true, "resolved_id": desired_id})
			_write_report({"status": "running", "completed": index + 1, "total": _jobs.size(), "results": results})
			continue
		var source_path := "C:/Users/conra/Desktop/ModularTileKitStudio/assets/blackridge_intake/" + String(job["file"])
		var settings: Dictionary = {
			"asset_id": desired_id,
			"display_name": String(job["name"]),
			"biome": "blackridge_intake",
			"grid_size": job["grid"],
			"driver_axis": 0,
			"stretch_to_grid": true,
			"optimize_mesh": false,
			"mesh_target_ratio": 0.25,
			"max_texture_size": 2048
		}
		var asset: TileAsset = await importer.import_glb(source_path, settings, library)
		if asset == null:
			results.append({"id": desired_id, "ok": false, "error": "native importer returned null"})
			_write_report({"status": "failed", "completed": index, "total": _jobs.size(), "results": results})
			queue_free()
			return
		results.append({
			"id": desired_id,
			"ok": true,
			"skipped": false,
			"resolved_id": asset.asset_id,
			"source": asset.source_path,
			"runtime_path": asset.prop_runtime_path,
			"runtime_optimization": asset.prop_runtime_metrics
		})
		_write_report({"status": "running", "completed": index + 1, "total": _jobs.size(), "results": results})
	library.rebuild_index()
	var save_error := library.save()
	if save_error != OK:
		_write_report({"status": "failed", "error": "asset library save failed", "code": save_error, "results": results})
		queue_free()
		return
	_write_report({"status": "succeeded", "completed": _jobs.size(), "total": _jobs.size(), "results": results})
	queue_free()

## Write one compact JSON snapshot so the root agent can verify native progress
## without inspecting transient editor state.
func _write_report(payload: Dictionary) -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[BI] could not write native import report")
		return
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
