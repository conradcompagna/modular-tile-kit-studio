@tool
extends RefCounted

## Prepare the BQ board against the live native terrain model and reject invalid prop occupancy.
func run() -> Dictionary:
	var bridge: Node = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false)
	var plugin: Variant = bridge.plugin
	var raw: Dictionary = plugin.board._read_board_json("res://exports/blackridge_quarantine/board_candidate.json")
	var document: Dictionary = raw.data
	var terrain: TerrainMesh = load("res://addons/modular_tile_studio/data/terrain_mesh.gd").from_json(document.terrain)
	# Existing canonical candidates already own their exact painted face slots.
	var faces_to_initialize: Array = terrain.face_uid_set() if document.surface_material_paint.material_slots.is_empty() else []
	for uid: String in faces_to_initialize:
		document.surface_material_paint.material_slots.append({"uid": uid, "palette_indices": [0, 1, -1, -1], "rotation_quarters": [0, 0, 0, 0]})
	var prepared: Dictionary = plugin.board.prepare_json(document)
	if prepared.error != OK or not prepared.report.valid:
		return {"ok": false, "error": prepared.error, "report": prepared.report}
	var board: BoardDocument = prepared.board
	var occupied: Dictionary = {}
	var overlaps: Array[Dictionary] = []
	for index: int in board.props.size():
		for cell: Vector3i in board.prop_occupied_cells(board.props[index]):
			if occupied.has(cell):
				overlaps.append({"cell": cell, "a": occupied[cell], "b": index})
			occupied[cell] = index
	if not overlaps.is_empty():
		return {"ok": false, "overlaps": overlaps, "report": prepared.report}
	board.save_json("res://exports/blackridge_quarantine/board_prepared.json")
	return {"ok": true, "props": board.props.size(), "cells": board.terrain.filled_cell_count(), "report": prepared.report}
