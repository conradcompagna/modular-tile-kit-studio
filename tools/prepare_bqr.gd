@tool
extends RefCounted

## Prepare the revised city through native terrain, surface records and measured prop occupancy without installing failures.
func run() -> Dictionary:
	var bridge: Node = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false)
	var plugin: Variant = bridge.plugin
	var raw: Dictionary = plugin.board._read_board_json("res://exports/blackridge_quarantine_revision/board_candidate.json")
	var document: Dictionary = raw.data
	var terrain: TerrainMesh = load("res://addons/modular_tile_studio/data/terrain_mesh.gd").from_json(document.terrain)
	for uid: String in terrain.face_uid_set():
		document.surface_material_paint.material_slots.append({"uid":uid,"palette_indices":[0,1,-1,-1],"rotation_quarters":[0,0,0,0]})
	var prepared: Dictionary = plugin.board.prepare_json(document)
	if prepared.error != OK or not prepared.report.valid:
		return {"ok":false,"error":prepared.error,"report":prepared.report}
	var board: BoardDocument = prepared.board
	var occupied: Dictionary = {}
	var overlaps: Array[Dictionary] = []
	for index: int in board.props.size():
		for cell: Vector3i in board.prop_occupied_cells(board.props[index]):
			if occupied.has(cell):
				overlaps.append({"cell":str(cell),"a":occupied[cell],"b":index,"asset_a":board.props[occupied[cell]].asset_id,"asset_b":board.props[index].asset_id})
			occupied[cell]=index
	var result: Dictionary = {"ok":overlaps.is_empty(),"props":board.props.size(),"cells":board.terrain.filled_cell_count(),"overlaps":overlaps,"report":prepared.report}
	var output := FileAccess.open("res://exports/blackridge_quarantine_revision/native_prepare_report.json",FileAccess.WRITE)
	output.store_string(JSON.stringify(result,"  "))
	output.close()
	if not overlaps.is_empty():
		return result
	board.save_json("res://exports/blackridge_quarantine_revision/board_prepared.json")
	return result
