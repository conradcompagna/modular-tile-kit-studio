@tool
extends RefCounted

## Prepare the surgical connections while preserving all existing terrain and native material faces.
func run() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false).plugin
	var document: Dictionary = plugin.board._read_board_json("res://exports/belowward_connections/board_candidate.json").data
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
	board.save_json("res://exports/belowward_connections/board_prepared.json")
	var report: Dictionary = {"ok": true, "props": board.props.size(), "cells": board.terrain.filled_cell_count(), "report": prepared.report}
	var output := FileAccess.open("res://reports/belowward_connections/native_validation_01.json",FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	return report
