extends SceneTree

var failures: int = 0


## Start the focused terrain texture brush regression after global classes are available.
func _init() -> void:
	call_deferred("_run_checks")


## Record one failed invariant with a precise diagnostic.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("TERRAIN TEXTURE BRUSH CHECK FAILED: %s" % message)


## Create one direct PNG surface asset with an intentionally large authored footprint.
func _make_surface_asset(asset_id: String, footprint: Vector2i) -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = asset_id
	asset.source_type = MTSConstants.SourceType.IMAGE_SURFACE
	asset.grid_bounds = Vector3i(footprint.x, footprint.y, 1)
	return asset


## Verify the integer metre width selects a square tile-grid stamp independently of PNG dimensions.
func _test_grid_stroke_controls_face_selection(asset: TileAsset) -> void:
	var renderer := MTSTerrainRenderer.new()
	for z: int in range(-1, 2):
		for x: int in range(-1, 2):
			var cell := Vector3i(x, 0, z)
			var address := MTSConstants.face_key(cell, MTSConstants.Face.POS_Y)
			renderer._face_by_address[address] = {
				"grid_cell": cell,
				"face": MTSConstants.Face.POS_Y,
			}

	var target := SurfacePlacement.create(
		asset.asset_id,
		Vector3i.ZERO,
		MTSConstants.Face.POS_Y,
		0
	)
	var one_metre: Array[Vector3i] = renderer.surface_face_cells_for_placement(
		target,
		asset,
		null,
		1
	)
	var three_metres: Array[Vector3i] = renderer.surface_face_cells_for_placement(
		target,
		asset,
		null,
		3
	)
	_check(
		one_metre == [Vector3i.ZERO],
		"a 1 m grid stroke must target one face despite the asset's large footprint"
	)
	_check(
		three_metres.size() == 9
		and three_metres.has(Vector3i(-1, 0, -1))
		and three_metres.has(Vector3i(1, 0, 1)),
		"a 3 m grid stroke must target the centred 3 by 3 face square"
	)
	renderer.free()


## Verify the toolbar grid width and Materials pen radius have separate runtime owners.
func _test_paint_controls_are_independent() -> void:
	var viewport := MTSStudioViewport.new()
	viewport.set_surface_grid_stroke_size(5.0)
	viewport.set_material_brush_radius(2.25)
	_check(
		viewport.surface_grid_stroke_size_m == 5
		and is_equal_approx(viewport.material_brush_radius_m, 2.25),
		"setting either paint control must leave the other control unchanged"
	)
	viewport.set_material_brush_radius(3.5)
	_check(
		viewport.surface_grid_stroke_size_m == 5,
		"changing the radial pen must not alter the square grid stroke"
	)
	viewport.free()

	var panel := MaterialPaintPanel.new()
	root.add_child(panel)
	_check(
		panel._brush_radius != null
		and panel._brush_radius.suffix == " m"
		and is_equal_approx(panel._brush_radius.value, 0.5),
		"Materials must expose its own metre-based circular Pen radius control"
	)
	panel.free()


## Verify Path and Polygon Fill resolve one canonical placement on top and side faces.
func _test_fill_uses_heightfield_face_cells(asset: TileAsset) -> void:
	var library := AssetLibrary.new()
	library.assets = [asset]
	library.rebuild_index()
	var board := BoardDocument.new()
	board.bind_library(library)
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i(3, 3))
	for z: int in 3:
		for x: int in 3:
			board.terrain.set_cell_filled(Vector2i(x, z), true)

	var renderer := MTSTerrainRenderer.new()
	for z: int in 3:
		for x: int in 3:
			var top_cell := Vector3i(x, 0, z)
			renderer._face_by_address[MTSConstants.face_key(
				top_cell,
				MTSConstants.Face.POS_Y
			)] = {
				"grid_cell": top_cell,
				"face": MTSConstants.Face.POS_Y,
			}
	for y: int in 3:
		for z: int in 3:
			var side_cell := Vector3i(0, y, z)
			renderer._face_by_address[MTSConstants.face_key(
				side_cell,
				MTSConstants.Face.POS_X
			)] = {
				"grid_cell": side_cell,
				"face": MTSConstants.Face.POS_X,
			}

	var controller := MTSPlacementController.new()
	controller.board = board
	controller.library = library
	controller.terrain_renderer = renderer
	controller.brush_asset = asset
	controller.tool = MTSPlacementController.Tool.FILL
	controller.surface_grid_stroke_size_m = 1

	controller.brush_face = MTSConstants.Face.POS_Y
	controller.fill_shape = MTSPlacementController.FillShape.PATH
	var top_path_origins: Array[Vector3i] = controller._generate_fill_origins([
		Vector3i(0, 0, 0),
		Vector3i(2, 0, 0),
	])
	var top_path := controller._evaluate_placement_candidates(top_path_origins)
	var top_path_placement := (top_path["placements"] as Array)[0] as SurfacePlacement
	_check(
		(top_path["placements"] as Array).size() == 1
		and top_path_placement.terrain_face_cells.size() == 3,
		"top Path Fill must commit one placement containing its three exact terrain faces"
	)

	controller.fill_shape = MTSPlacementController.FillShape.POLYGON
	var top_polygon_origins: Array[Vector3i] = controller._generate_fill_origins([
		Vector3i(0, 0, 0),
		Vector3i(2, 0, 0),
		Vector3i(2, 0, 2),
		Vector3i(0, 0, 2),
	])
	var top_polygon := controller._evaluate_placement_candidates(top_polygon_origins)
	var top_polygon_placement := (top_polygon["placements"] as Array)[0] as SurfacePlacement
	_check(
		(top_polygon["placements"] as Array).size() == 1
		and top_polygon_placement.terrain_face_cells.size() == 9,
		"top Polygon Fill must cover every tile-grid face inside the polygon"
	)

	controller.brush_face = MTSConstants.Face.POS_X
	controller.fill_shape = MTSPlacementController.FillShape.PATH
	var side_path_origins: Array[Vector3i] = controller._generate_fill_origins([
		Vector3i(0, 0, 0),
		Vector3i(0, 2, 0),
	])
	var side_path := controller._evaluate_placement_candidates(side_path_origins)
	var side_path_placement := (side_path["placements"] as Array)[0] as SurfacePlacement
	_check(
		(side_path["placements"] as Array).size() == 1
		and side_path_placement.terrain_face_cells.size() == 3
		and side_path_placement.face == MTSConstants.Face.POS_X,
		"side Path Fill must follow vertical heightfield face bands"
	)

	controller.fill_shape = MTSPlacementController.FillShape.POLYGON
	var side_polygon_origins: Array[Vector3i] = controller._generate_fill_origins([
		Vector3i(0, 0, 0),
		Vector3i(0, 2, 0),
		Vector3i(0, 2, 2),
		Vector3i(0, 0, 2),
	])
	var side_polygon := controller._evaluate_placement_candidates(side_polygon_origins)
	var side_polygon_placement := (side_polygon["placements"] as Array)[0] as SurfacePlacement
	_check(
		(side_polygon["placements"] as Array).size() == 1
		and side_polygon_placement.terrain_face_cells.size() == 9
		and side_polygon_placement.face == MTSConstants.Face.POS_X,
		"side Polygon Fill must cover the vertical tile-grid region without planar quads"
	)
	controller.free()
	renderer.free()


## Verify Replace skips the selected texture and trims other textures at face granularity.
func _test_replace_is_texture_and_face_granular(
	selected_asset: TileAsset,
	other_asset: TileAsset
) -> void:
	var library := AssetLibrary.new()
	library.assets = [selected_asset, other_asset]
	library.rebuild_index()
	var board := BoardDocument.new()
	board.bind_library(library)
	var controller := MTSPlacementController.new()
	controller.board = board
	controller.library = library
	controller.set_replace_enabled(true)

	var existing_same := SurfacePlacement.create(
		selected_asset.asset_id,
		Vector3i(10, 0, 10),
		MTSConstants.Face.POS_Y,
		0
	)
	existing_same.terrain_face_cells = [
		Vector3i(10, 0, 10),
		Vector3i(11, 0, 10),
	]
	board.add_surface(existing_same)
	var same_candidate := SurfacePlacement.create(
		selected_asset.asset_id,
		Vector3i(11, 0, 10),
		MTSConstants.Face.POS_Y,
		0
	)
	same_candidate.terrain_face_cells = [
		Vector3i(11, 0, 10),
		Vector3i(12, 0, 10),
	]
	_check(
		controller._retain_faces_not_using_brush_asset(same_candidate)
		and same_candidate.terrain_face_cells == [Vector3i(12, 0, 10)],
		"same-texture faces must remain owned by their existing placement"
	)

	board.clear()
	var existing_other := SurfacePlacement.create(
		other_asset.asset_id,
		Vector3i(20, 0, 20),
		MTSConstants.Face.POS_Y,
		0
	)
	existing_other.terrain_face_cells = [
		Vector3i(20, 0, 20),
		Vector3i(21, 0, 20),
		Vector3i(22, 0, 20),
	]
	board.add_surface(existing_other)
	var exact_replacement := SurfacePlacement.create(
		selected_asset.asset_id,
		Vector3i(21, 0, 20),
		MTSConstants.Face.POS_Y,
		0
	)
	exact_replacement.terrain_face_cells = [Vector3i(21, 0, 20)]
	var replacements: Array[Resource] = [exact_replacement]
	var displaced: Array[Resource] = [existing_other]
	controller._commit_replacements(replacements, displaced, "Focused granular replacement")

	var left := board.surface_at(Vector3i(20, 0, 20), MTSConstants.Face.POS_Y)
	var centre := board.surface_at(Vector3i(21, 0, 20), MTSConstants.Face.POS_Y)
	var right := board.surface_at(Vector3i(22, 0, 20), MTSConstants.Face.POS_Y)
	_check(
		left != null
		and centre != null
		and right != null
		and left.asset_id == other_asset.asset_id
		and centre.asset_id == selected_asset.asset_id
		and right.asset_id == other_asset.asset_id,
		"replacing one face must preserve untouched faces from the wider placement"
	)
	controller.free()


## Run the focused checks and return their failure count to the shell.
func _run_checks() -> void:
	var selected_asset := _make_surface_asset("SELECTED", Vector2i(4, 4))
	var other_asset := _make_surface_asset("OTHER", Vector2i(4, 4))
	_test_grid_stroke_controls_face_selection(selected_asset)
	_test_paint_controls_are_independent()
	_test_fill_uses_heightfield_face_cells(selected_asset)
	_test_replace_is_texture_and_face_granular(selected_asset, other_asset)
	print("terrain_texture_brush_check: %d failures" % failures)
	quit(failures)
