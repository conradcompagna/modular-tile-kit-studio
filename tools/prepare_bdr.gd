@tool
extends RefCounted

## Bind the depths candidate to actual native terrain faces and reject invalid occupancy before staging.
func run() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false).plugin
	var raw: Dictionary = plugin.board._read_board_json("res://exports/blackridge_depths_revision/board_candidate.json")
	var document: Dictionary = raw.data
	var terrain: TerrainMesh = load("res://addons/modular_tile_studio/data/terrain_mesh.gd").from_json(document.terrain)
	for uid: String in terrain.face_uid_set():
		document.surface_material_paint.material_slots.append({"uid": uid, "palette_indices": [0, 1, -1, -1], "rotation_quarters": [0, 0, 0, 0]})
	var prepared: Dictionary = plugin.board.prepare_json(document)
	if prepared.error != OK or not prepared.report.valid:
		return {"ok": false, "report": prepared.report}
	var board: BoardDocument = prepared.board
	var cells: Dictionary = {}
	var pairs: Dictionary = {}
	for index: int in board.props.size():
		for cell: Vector3i in board.prop_occupied_cells(board.props[index]):
			if cells.has(cell):
				var other: int = cells[cell]
				pairs[str(other) + ":" + str(index)] = {"a": board.props[other].to_json(), "b": board.props[index].to_json()}
			cells[cell] = index
	if not pairs.is_empty():
		return {"ok": false, "overlaps": pairs.values(), "report": prepared.report}
	board.save_json("res://exports/blackridge_depths_revision/board_prepared.json")
	var report: Dictionary = {"ok": true, "props": board.props.size(), "cells": board.terrain.filled_cell_count(), "report": prepared.report}
	var file := FileAccess.open("res://reports/blackridge_depths/native_validation_revision.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	return report
