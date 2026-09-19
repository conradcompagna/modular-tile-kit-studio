@tool
extends RefCounted

## Prepare the two staged revision03 documents with native asset poses and voxels, without touching the current editor board.
func run() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false).plugin
	var results: Array[Dictionary] = []
	for folder: String in ["blackridge_intake_revision03", "belowward_revision03"]:
		var raw: Dictionary = plugin.board._read_board_json("res://exports/" + folder + "/candidate.json")
		var prepared: Dictionary = plugin.board.prepare_json(raw.data)
		if prepared.error != OK or not prepared.report.valid:
			results.append({"folder": folder, "ok": false, "report": prepared.report})
			continue
		var board: BoardDocument = prepared.board
		var occupied: Dictionary = {}
		var overlaps: Array[Dictionary] = []
		var changed: Array[Dictionary] = []
		for index: int in board.props.size():
			var prop: PropPlacement = board.props[index]
			if prop.asset_id.begins_with("BI3_") or prop.asset_id.begins_with("BC3_") or prop.asset_id.begins_with("BR3_"):
				var asset: TileAsset = board.resolve_prop_asset(prop)
				changed.append({"id": prop.asset_id, "placement": prop.to_json(), "world_origin": board.prop_world_origin(prop), "pose": asset.prop_pose_transform, "size": asset.visual_size_m, "voxels": asset.prop_voxels.size(), "source": asset.source_path, "runtime": asset.prop_model_path(), "loadable": ResourceLoader.exists(asset.prop_model_path(), "PackedScene")})
			for cell: Vector3i in board.prop_occupied_cells(prop):
				if occupied.has(cell):
					overlaps.append({"cell": cell, "a": board.props[int(occupied[cell])].to_json(), "b": prop.to_json()})
				else:
					occupied[cell] = index
		var saved: int = board.save_json("res://exports/" + folder + "/prepared.json") if overlaps.is_empty() else ERR_INVALID_DATA
		var result: Dictionary = {"folder": folder, "ok": saved == OK, "save_error": saved, "props": board.props.size(), "cells": board.terrain.filled_cell_count(), "markers": board.gameplay_markers.size(), "overlaps": overlaps, "changed": changed, "report": prepared.report}
		var output := FileAccess.open("res://exports/" + folder + "/native_preparation.json", FileAccess.WRITE)
		output.store_string(JSON.stringify(result, "  "))
		output.close()
		results.append(result)
	return {"results": results}
