extends RefCounted

## Small, public terrain fixture; no user library, GLB, or external service.


static func library() -> AssetLibrary:
	var result := AssetLibrary.new()
	var asset := TileAsset.new()
	asset.asset_id = "FIXTURE_STONE"
	asset.display_name = "Fixture stone"
	asset.source_type = MTSConstants.SourceType.IMAGE_SURFACE
	asset.source_path = "res://icon.svg"
	asset.grid_bounds = Vector3i.ONE
	asset.visual_size_m = Vector3(1, 1, 0)
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", "res://icon.svg")
	result.add_asset(asset)
	return result


static func board(assets: AssetLibrary) -> BoardDocument:
	var result := BoardDocument.new()
	result.bind_library(assets)
	result.board_name = "Public courtyard fixture"
	result.biome = "stone"
	result.terrain = TerrainMesh.create(Vector2i(-1, -1), Vector2i(2, 2))
	for z in range(-1, 1):
		for x in range(-1, 1):
			result.terrain.set_cell_filled(Vector2i(x, z), true)
	result.terrain.set_lattice_corner_height(Vector2i.ZERO, 0.25)
	result.set_movement_cell_unwalkable(Vector2i(-1, -1), true)
	result.set_movement_ground_effect(Vector2i.ZERO, "mud")
	result.add_enemy_pack(EnemyPack.create("guards", "Courtyard sentries"))
	result.add_gameplay_marker(GameplayMarker.create(
		"sentry", GameplayMarker.TYPE_ENEMY, Vector3i.ZERO, "Watch the gate", "guard", "guards"
	))
	var paint := SurfacePlacement.create("FIXTURE_STONE", Vector3i.ZERO, MTSConstants.Face.POS_Y, 1)
	paint.placement_uid = "fixture-paint"
	paint.terrain_face_uids = PackedStringArray([TerrainMesh.cell_top_uid(Vector2i.ZERO)])
	result.add_surface(paint)
	var decal := SurfacePlacement.create("FIXTURE_STONE", Vector3i.ZERO, MTSConstants.Face.POS_Y, 0)
	decal.placement_uid = "fixture-decal"
	decal.presentation = SurfacePlacement.Presentation.SHADER_DECAL
	decal.terrain_face_uids = paint.terrain_face_uids.duplicate()
	result.add_surface(decal)
	result.note_imported_asset("FIXTURE_STONE")
	var slots: Array = []
	for uid: String in result.terrain.face_uid_set():
		slots.append({"uid": uid, "palette_indices": [-1, -1, -1, -1]})
	result.surface_material_paint = {"material_slots": slots}
	return result
