@tool
extends RefCounted

## Bind the intake candidate to actual native terrain faces and reject occupied-cell conflicts before staging.
func run() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false).plugin
	var raw: Dictionary = plugin.board._read_board_json("res://exports/blackridge_intake/board_candidate.json")
	var document: Dictionary = raw.data
	var terrain: TerrainMesh = load("res://addons/modular_tile_studio/data/terrain_mesh.gd").from_json(document.terrain)
	for uid: String in terrain.face_uid_set():
		document.surface_material_paint.material_slots.append({"uid": uid, "palette_indices": [0, 1, -1, -1], "rotation_quarters": [0, 0, 0, 0]})
	var prepared: Dictionary = plugin.board.prepare_json(document)
	if prepared.error != OK or not prepared.report.valid:
		return {"ok": false, "report": prepared.report}
	var board: BoardDocument = prepared.board
	var occupied: Dictionary = {}
	var overlaps: Array[Dictionary] = []
	for index: int in board.props.size():
		for cell: Vector3i in board.prop_occupied_cells(board.props[index]):
			if occupied.has(cell):
				var other: int = occupied[cell]
				overlaps.append({"cell": cell, "a": board.props[other].to_json(), "b": board.props[index].to_json()})
			else:
				occupied[cell] = index
	if not overlaps.is_empty():
		return {"ok": false, "overlaps": overlaps, "report": prepared.report}
	board.save_json("res://exports/blackridge_intake/board_prepared.json")
	return {"ok": true, "props": board.props.size(), "cells": board.terrain.filled_cell_count(), "markers": board.gameplay_markers.size(), "report": prepared.report}
