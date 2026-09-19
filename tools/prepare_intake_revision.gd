@tool
extends RefCounted

## Prepare only the current staged Intake revision and reject native resource or occupied-voxel errors.
func run() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge",true,false).plugin
	var raw: Dictionary = plugin.board._read_board_json("res://exports/blackridge_intake_revision/candidate.json")
	var prepared: Dictionary = plugin.board.prepare_json(raw.data)
	if prepared.error != OK or not prepared.report.valid:
		return {"ok":false,"report":prepared.report}
	var board: BoardDocument = prepared.board
	var occupied: Dictionary = {}
	var overlaps: Array[Dictionary] = []
	for index: int in board.props.size():
		for cell: Vector3i in board.prop_occupied_cells(board.props[index]):
			if occupied.has(cell):
				var other: int = occupied[cell]
				overlaps.append({"cell":cell,"a":board.props[other].to_json(),"b":board.props[index].to_json()})
			else:
				occupied[cell]=index
	if not overlaps.is_empty():
		return {"ok":false,"overlaps":overlaps,"report":prepared.report}
	var saved := board.save_json("res://exports/blackridge_intake_revision/prepared.json")
	return {"ok":saved==OK,"save_error":saved,"props":board.props.size(),"cells":board.terrain.filled_cell_count(),"markers":board.gameplay_markers.size(),"report":prepared.report}
