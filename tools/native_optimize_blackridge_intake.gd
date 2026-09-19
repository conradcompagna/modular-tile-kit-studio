@tool
extends Node

## Persist the meshoptimizer pass so reduction progress remains inspectable while
## Godot's native ImporterMesh LOD generation runs outside the bridge request.
const REPORT_PATH := "res://exports/blackridge_intake/native_optimize_report.json"

## Keep the optimization set explicit and limited to the BI assets authored for
## this floor; the canonical source GLBs remain untouched in each asset folder.
const ASSET_IDS: Array[String] = [
	"BI_AUTHORITY_GATE",
	"BI_DESCENT_ARCH",
	"BI_AUTHORITY_BANNER",
	"BI_RECORDS_SHELF",
	"BI_HOLDING_GATE",
	"BI_HOLDING_BENCH",
	"BI_PROPERTY_CART",
	"BI_CELL_A1",
	"BI_CELL_A2",
	"BI_CELL_B1"
]

## Start the deferred reduction pass so the editor bridge returns before the
## first Godot ImporterMesh LOD scan finishes.
func start() -> void:
	_write_report({"status": "started", "completed": 0, "total": ASSET_IDS.size(), "results": []})
	call_deferred("_run_optimization")

## Rebuild only each asset's runtime GLB from its stored source, preserving the
## native voxel measurements imported in the first pass.
func _run_optimization() -> void:
	var bridge: Node = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false)
	if bridge == null:
		_write_report({"status": "failed", "error": "MTSStudioBridge not found"})
		queue_free()
		return
	var plugin: Variant = bridge.plugin
	var library: AssetLibrary = plugin.library
	var importer: GLBAssetImporter = plugin.glb_importer
	var results: Array[Dictionary] = []
	var failures: Array[String] = []
	for index: int in ASSET_IDS.size():
		var asset_id := ASSET_IDS[index]
		var asset: TileAsset = library.get_asset(asset_id)
		if asset == null:
			results.append({"id": asset_id, "ok": false, "error": "asset missing from library"})
			_write_report({"status": "failed", "completed": index, "total": ASSET_IDS.size(), "results": results})
			queue_free()
			return
		var ok := importer.rebuild_prop(asset, {
			"rebuild_geometry": false,
			"optimize_mesh": true,
			"mesh_target_ratio": 0.5,
			"max_texture_size": 2048
		})
		results.append({
			"id": asset_id,
			"ok": ok,
			"runtime_path": asset.prop_runtime_path,
			"runtime_metrics": asset.prop_runtime_metrics
		})
		_write_report({"status": "running", "completed": index + 1, "total": ASSET_IDS.size(), "results": results})
		if not ok:
			failures.append(asset_id)
	library.rebuild_index()
	var save_error := library.save()
	if save_error != OK:
		_write_report({"status": "failed", "error": "asset library save failed", "code": save_error, "results": results})
		queue_free()
		return
	_write_report({
		"status": "succeeded" if failures.is_empty() else "completed_with_failures",
		"completed": ASSET_IDS.size(),
		"total": ASSET_IDS.size(),
		"failures": failures,
		"results": results
	})
	queue_free()

## Write one compact JSON snapshot for the root verification pass to consume.
func _write_report(payload: Dictionary) -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[BI] could not write native optimization report")
		return
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
