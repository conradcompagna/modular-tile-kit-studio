@tool
extends Node

## Run one isolated Godot ImporterMesh reduction so its exact failure remains
## inspectable without altering the valid TileAsset resource or board.
const REPORT_PATH := "res://exports/blackridge_intake/optimizer_diagnostic.json"

## Start the isolated diagnostic outside the short editor bridge request window.
func start() -> void:
	_write_report({"status": "started"})
	call_deferred("_run")

## Ask the same native optimizer used by rebuild_prop to reduce the authority gate
## and persist only its structured result for review.
func _run() -> void:
	var bridge: Node = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false)
	if bridge == null:
		_write_report({"status": "failed", "error": "MTSStudioBridge not found"})
		queue_free()
		return
	var asset: TileAsset = bridge.plugin.library.get_asset("BI_AUTHORITY_GATE")
	if asset == null:
		_write_report({"status": "failed", "error": "BI_AUTHORITY_GATE missing"})
		queue_free()
		return
	var optimizer: GLBRuntimeOptimizer = load("res://addons/modular_tile_studio/importers/glb_runtime_optimizer.gd").new()
	var output_path := asset.derived_dir.path_join("diagnostic_runtime_optimized.glb")
	var result: Dictionary = optimizer.build_from_source(asset.source_path, output_path, 0.5, 2048)
	_write_report({"status": "succeeded" if bool(result.get("ok", false)) else "failed", "result": result})
	queue_free()

## Write the diagnostic payload so no optimizer exception or timeout is mistaken for
## a successful runtime reduction.
func _write_report(payload: Dictionary) -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[BI] could not write optimizer diagnostic")
		return
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
