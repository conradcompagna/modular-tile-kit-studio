@tool
extends RefCounted

## Bind the depths candidate to actual native terrain faces and reject invalid occupancy before staging.
func run() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false).plugin
	var raw: Dictionary = plugin.board._read_board_json("res://exports/blackridge_depths_revision03/board_candidate.json")
	var document: Dictionary = raw.data
	var terrain: TerrainMesh = load("res://addons/modular_tile_studio/data/terrain_mesh.gd").from_json(document.terrain)
	# Derive canonical triangle diagonals and owned side profiles from the newly sculpted top quads.
	terrain.side_faces.clear()
	for z: int in terrain.size_cells.y:
		for x: int in terrain.size_cells.x:
			var cell := terrain.origin_cell + Vector2i(x,z)
			if terrain.is_cell_filled(cell):
				terrain._refresh_cell_top_diagonal(cell)
				terrain.rebuild_side_faces_for_cell(cell)
	document.terrain = terrain.to_json()
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
	board.save_json("res://exports/blackridge_depths_revision03/board_prepared.json")
	var report: Dictionary = {"ok": true, "props": board.props.size(), "cells": board.terrain.filled_cell_count(), "report": prepared.report}
	var file := FileAccess.open("res://reports/blackridge_depths_revision03/native_validation.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	return report
