@tool
extends RefCounted

## Bind generated metre cells and decals to native terrain faces, then validate the candidate in Tile Studio.
func run() -> Dictionary:
	var plugin: Variant = Engine.get_main_loop().root.find_child("MTSStudioBridge", true, false).plugin
	var raw: Dictionary = plugin.board._read_board_json("res://exports/belowward_cell/board_candidate.json")
	var document: Dictionary = raw.data
	var terrain: TerrainMesh = load("res://addons/modular_tile_studio/data/terrain_mesh.gd").from_json(document.terrain)
	for uid: String in terrain.face_uid_set():
		document.surface_material_paint.material_slots.append({"uid": uid, "palette_indices": [0, 1, -1, -1], "rotation_quarters": [0, 0, 0, 0]})
	document.particle_effects = [{"placement_id": "belowward_fissure_mist", "preset_id": "FISSURE_MIST", "position": [24, -8, 23], "attachment": "world", "enabled": true}]
	var constants: Script = load("res://addons/modular_tile_studio/utils/mts_constants.gd")
	var stamps: Array[Dictionary] = [
		{"origin": Vector3i(12, -5, 21), "face": constants.Face.POS_X, "size": 8, "asset": "BW_PRISON_GRIME_SOFT"},
		{"origin": Vector3i(8, 3, 20), "face": constants.Face.POS_Y, "size": 3, "asset": "BW_RACK_STAIN"},
		{"origin": Vector3i(5, 3, 17), "face": constants.Face.POS_Y, "size": 3, "asset": "BW_RACK_STAIN"},
	]
	var terrain_faces: Array = terrain.terrain_faces()
	for index: int in stamps.size():
		var stamp: Dictionary = stamps[index]
		var uids: Array[String] = []
		var origin: Vector3i = stamp.origin
		for face: Dictionary in terrain_faces:
			if face.face != stamp.face:
				continue
			var cell: Vector3i = face.grid_cell
			var covers: bool = false
			if stamp.face == constants.Face.POS_X:
				covers = cell.x == origin.x and cell.z >= origin.z and cell.z < origin.z + stamp.size and cell.y >= origin.y and cell.y < origin.y + stamp.size
			elif stamp.face == constants.Face.POS_Z:
				covers = cell.z == origin.z and cell.x >= origin.x and cell.x < origin.x + stamp.size and cell.y >= origin.y and cell.y < origin.y + stamp.size
			else:
				covers = cell.y == origin.y and cell.x >= origin.x and cell.x < origin.x + stamp.size and cell.z >= origin.z and cell.z < origin.z + stamp.size
			if covers:
				uids.append(face.paint_uid)
		document.surfaces.append({"uid": "belowward_decal_" + str(index), "asset": stamp.asset, "origin": [origin.x, origin.y, origin.z], "face": constants.face_name(stamp.face), "rotation": 0, "presentation": "shader_decal", "terrain_face_uids": uids})
	for asset_id: String in ["BW_PRISON_GRIME_SOFT", "BW_RACK_STAIN"]:
		document.imported_assets.append(asset_id)
	var prepared: Dictionary = plugin.board.prepare_json(document)
	if prepared.error != OK:
		return prepared
	var board: BoardDocument = prepared.board
	board.save_json("res://exports/belowward_cell/board_prepared.json")
	var cells: Dictionary = {}
	var pairs: Dictionary = {}
	for index: int in board.props.size():
		for cell: Vector3i in board.prop_occupied_cells(board.props[index]):
			if cells.has(cell):
				var other: int = cells[cell]
				pairs[str(other) + ":" + str(index)] = {"a": board.props[other].to_json(), "b": board.props[index].to_json()}
			cells[cell] = index
	return {"overlaps": pairs.values(), "report": prepared.report}
