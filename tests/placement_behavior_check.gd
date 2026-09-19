extends SceneTree

var constants_script
var tile_asset_script
var asset_library_script
var board_document_script
var surface_placement_script
var prop_placement_script
var placement_controller_script
var blockout_slot_script

var failures: int = 0


## Start the focused placement regression after the SceneTree can host a camera.
func _init() -> void:
	constants_script = load("res://addons/modular_tile_studio/utils/mts_constants.gd")
	tile_asset_script = load("res://addons/modular_tile_studio/data/tile_asset.gd")
	asset_library_script = load("res://addons/modular_tile_studio/data/asset_library.gd")
	board_document_script = load("res://addons/modular_tile_studio/data/board_document.gd")
	surface_placement_script = load("res://addons/modular_tile_studio/data/surface_placement.gd")
	prop_placement_script = load("res://addons/modular_tile_studio/data/prop_placement.gd")
	placement_controller_script = load("res://addons/modular_tile_studio/viewport/placement_controller.gd")
	blockout_slot_script = load("res://addons/modular_tile_studio/data/blockout_slot.gd")
	call_deferred("_run_checks")


## Record one assertion with a precise failure message.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("PLACEMENT CHECK FAILED: %s" % message)


## Convert a voxel array into an order-independent set for exact occupancy checks.
func _voxel_key_set(cells: Array[Vector3i]) -> Dictionary:
	var keys: Dictionary = {}
	for cell: Vector3i in cells:
		keys["%d,%d,%d" % [cell.x, cell.y, cell.z]] = true
	return keys


## Compare two exact voxel sets while preserving their cells in any storage order.
func _check_voxel_set(
	actual: Array[Vector3i],
	expected: Array[Vector3i],
	message: String
) -> void:
	_check(
		_voxel_key_set(actual) == _voxel_key_set(expected),
		"%s (actual %s, expected %s)" % [message, actual, expected]
	)


## Exercise structural-floor picking, slice filtering, and footprint-aligned
## Fill math in the same classes used by the editor.
func _run_checks() -> void:
	var K: Variant = constants_script
	var library: AssetLibrary = asset_library_script.new()

	var floor_asset: TileAsset = tile_asset_script.new()
	floor_asset.asset_id = "FLOOR"
	floor_asset.source_type = K.SourceType.IMAGE_SURFACE
	floor_asset.grid_bounds = Vector3i.ONE

	var prop_asset: TileAsset = tile_asset_script.new()
	prop_asset.asset_id = "PROP"
	prop_asset.source_type = K.SourceType.GLB_PROP
	prop_asset.grid_bounds = Vector3i(2, 1, 3)
	for z in prop_asset.grid_bounds.z:
		for y in prop_asset.grid_bounds.y:
			for x in prop_asset.grid_bounds.x:
				prop_asset.prop_voxels.append(Vector3i(x, y, z))
	var prop_diagonal_bounds: Vector3i = K.diagonal_scan_bounds(prop_asset.grid_bounds)
	for z in prop_diagonal_bounds.z:
		for y in prop_diagonal_bounds.y:
			for x in prop_diagonal_bounds.x:
				prop_asset.prop_voxels_diagonal.append(Vector3i(x, y, z))

	var replacement_prop_asset: TileAsset = tile_asset_script.new()
	replacement_prop_asset.asset_id = "PROP_REPLACEMENT"
	replacement_prop_asset.source_type = K.SourceType.GLB_PROP
	replacement_prop_asset.grid_bounds = prop_asset.grid_bounds
	replacement_prop_asset.prop_voxels.assign(prop_asset.prop_voxels)
	replacement_prop_asset.prop_voxels_diagonal.assign(prop_asset.prop_voxels_diagonal)

	# This asymmetric scan makes a wrong corner translation visible even when every
	# diagonal heading happens to keep the same voxel count.
	var diagonal_scan_asset: TileAsset = tile_asset_script.new()
	diagonal_scan_asset.asset_id = "DIAGONAL_SCAN"
	diagonal_scan_asset.source_type = K.SourceType.GLB_PROP
	diagonal_scan_asset.grid_bounds = Vector3i(2, 2, 1)
	diagonal_scan_asset.prop_voxels = [Vector3i.ZERO]
	diagonal_scan_asset.prop_voxels_diagonal = [
		Vector3i(1, 0, 0),
		Vector3i(2, 0, 0),
		Vector3i(0, 0, 1),
	]

	var missing_diagonal_asset: TileAsset = tile_asset_script.new()
	missing_diagonal_asset.asset_id = "MISSING_DIAGONAL_SCAN"
	missing_diagonal_asset.source_type = K.SourceType.GLB_PROP
	missing_diagonal_asset.grid_bounds = Vector3i(2, 2, 1)
	missing_diagonal_asset.prop_voxels = [Vector3i.ZERO]

	var fill_asset: TileAsset = tile_asset_script.new()
	fill_asset.asset_id = "FILL"
	fill_asset.source_type = K.SourceType.IMAGE_SURFACE
	fill_asset.grid_bounds = Vector3i(2, 3, 1)

	library.assets.clear()
	library.assets.append(floor_asset)
	library.assets.append(prop_asset)
	library.assets.append(replacement_prop_asset)
	library.assets.append(diagonal_scan_asset)
	library.assets.append(missing_diagonal_asset)
	library.assets.append(fill_asset)
	library.rebuild_index()

	var board: BoardDocument = board_document_script.new()
	board.bind_library(library)

	var canonical_centre: Vector3 = Vector3(diagonal_scan_asset.grid_bounds) * 0.5
	var diagonal_bounds: Vector3i = K.diagonal_scan_bounds(diagonal_scan_asset.grid_bounds)
	var diagonal_transform: Transform3D = K.prop_box_transform(
		diagonal_scan_asset.grid_bounds,
		K.Face.NEG_Z,
		0,
		1
	)
	_check(
		(diagonal_transform * canonical_centre).is_equal_approx(
			Vector3(diagonal_bounds) * 0.5
		),
		"diagonal art should be centred inside the same integer box as its voxel scan"
	)

	var expected_diagonal_voxels: Dictionary = {
		1: [
			Vector3i(1, 0, 0),
			Vector3i(2, 0, 0),
			Vector3i(0, 0, 1),
		],
		3: [
			Vector3i(0, 0, 1),
			Vector3i(0, 0, 0),
			Vector3i(1, 0, 2),
		],
		5: [
			Vector3i(1, 0, 2),
			Vector3i(0, 0, 2),
			Vector3i(2, 0, 1),
		],
		7: [
			Vector3i(2, 0, 1),
			Vector3i(2, 0, 2),
			Vector3i(1, 0, 0),
		],
	}
	for yaw_eighths: int in [1, 3, 5, 7]:
		var diagonal_placement: PropPlacement = prop_placement_script.create(
			diagonal_scan_asset.asset_id,
			Vector3i.ZERO,
			K.Face.NEG_Z,
			0,
			yaw_eighths
		)
		var expected_voxels: Array[Vector3i] = []
		expected_voxels.assign(expected_diagonal_voxels[yaw_eighths])
		_check_voxel_set(
			diagonal_placement.oriented_voxels(diagonal_scan_asset),
			expected_voxels,
			"one 45-degree scan should rotate exactly into yaw %d" % yaw_eighths
		)

	var missing_scan_placement: PropPlacement = prop_placement_script.create(
		missing_diagonal_asset.asset_id,
		Vector3i.ZERO,
		K.Face.NEG_Z,
		0,
		1
	)
	var missing_scan_report: Dictionary = board.validate_prop(missing_scan_placement)
	_check(
		not bool(missing_scan_report.get("valid", true))
		and String(missing_scan_report.get("reason", "")).contains("no 45-degree voxel scan"),
		"a missing diagonal scan should reject placement instead of inflating canonical voxels"
	)

	var ground: SurfacePlacement = surface_placement_script.create(
		floor_asset.asset_id,
		Vector3i(0, 0, 0),
		K.Face.POS_Y,
		0
	)
	var elevated: SurfacePlacement = surface_placement_script.create(
		floor_asset.asset_id,
		Vector3i(0, 5, 5),
		K.Face.POS_Y,
		0
	)
	board.add_surface(ground)
	board.add_surface(elevated)
	_check(board.floor_levels() == [0, 5], "floor index should contain both structural Y levels")

	var controller: MTSPlacementController = placement_controller_script.new()
	controller.board = board
	controller.library = library
	controller.set_brush(prop_asset)

	# This ray is the center ray of a camera at (0, 10, 10) looking at the
	# origin. Its intersection with Y=5 is the elevated floor cell (0, 5, 5).
	var ray_origin := Vector3(0, 10, 10)
	var ray_direction := Vector3(0, -1, -1).normalized()
	controller.current_y = 0
	controller.slice_mode = K.SliceMode.ALL
	var elevated_pick: Dictionary = controller._pick_structural_floor_from_ray(
		ray_origin,
		ray_direction
	)
	_check(
		bool(elevated_pick.get("hit", false))
		and elevated_pick.get("cell", Vector3i(-1, -1, -1)).y == 5,
		"prop ray should choose the first visible elevated floor"
	)

	controller.slice_mode = K.SliceMode.CURRENT_ONLY
	var current_pick: Dictionary = controller._pick_structural_floor_from_ray(
		ray_origin,
		ray_direction
	)
	_check(
		bool(current_pick.get("hit", false))
		and current_pick.get("cell", Vector3i(-1, -1, -1)).y == 0,
		"CURRENT_ONLY should exclude elevated support floors"
	)

	controller.current_y = 5
	var elevated_slice_pick: Dictionary = controller._pick_structural_floor_from_ray(
		ray_origin,
		ray_direction
	)
	_check(
		bool(elevated_slice_pick.get("hit", false))
		and elevated_slice_pick.get("cell", Vector3i(-1, -1, -1)).y == 5,
		"current elevated slice should select its support floor"
	)

	board.remove_surface(elevated)
	_check(board.floor_levels() == [0], "removing a floor should release its indexed Y level")

	controller.set_brush(fill_asset)
	controller.brush_face = K.Face.POS_Y
	controller.brush_quarters = 0
	controller.set_fill_shape(placement_controller_script.FillShape.PATH)
	controller.fill_vertices.append(Vector3i(10, 0, 10))
	controller.fill_vertices.append(Vector3i(16, 0, 10))

	var line_origins: Array[Vector3i] = controller._generate_fill_origins(
		controller.fill_vertices
	)
	_check(
		line_origins.size() == 4,
		"a two-point path should include both endpoints on the footprint lattice"
	)
	_check(
		line_origins[1] == Vector3i(12, 0, 10),
		"path spacing should equal the rotated surface footprint width"
	)

	controller.set_fill_shape(placement_controller_script.FillShape.POLYGON)
	controller.fill_vertices.append(Vector3i(10, 0, 10))
	controller.fill_vertices.append(Vector3i(16, 0, 10))
	controller.fill_vertices.append(Vector3i(16, 0, 16))
	controller.fill_vertices.append(Vector3i(10, 0, 16))
	var polygon_origins: Array[Vector3i] = controller._generate_fill_origins(
		controller.fill_vertices
	)
	_check(
		polygon_origins.size() == 12,
		"a 6x6 polygon should include all twelve centre-sampled 2x3 border stamps"
	)

	controller.brush_face = K.Face.POS_X
	controller.fill_vertices.clear()
	controller.fill_vertices.append(Vector3i(4, 2, 10))
	controller.fill_vertices.append(Vector3i(4, 2, 16))
	controller.fill_vertices.append(Vector3i(4, 8, 16))
	controller.fill_vertices.append(Vector3i(4, 8, 10))
	var wall_origins: Array[Vector3i] = controller._generate_fill_origins(
		controller.fill_vertices
	)
	_check(
		wall_origins.size() == 12,
		"a vertical 6x6 polygon should include the same twelve border stamps"
	)
	for wall_origin: Vector3i in wall_origins:
		_check(
			wall_origin.x == 4,
			"sideways Fill must keep every surface origin on its locked face plane"
		)

	board.clear()
	var evaluated_surfaces: Dictionary = controller._evaluate_placement_candidates(
		wall_origins
	)
	var valid_surface_origins: Array = evaluated_surfaces["valid_origins"]
	_check(
		valid_surface_origins.size() == 12,
		"an empty board should validate every sideways surface stamp"
	)

	controller.set_brush(prop_asset)
	# Enter the SceneTree with a prop brush so _ready() creates the real preview
	# nodes without requiring a surface texture in this geometry-focused fixture.
	root.add_child(controller)
	controller.set_prop_orientation(K.Face.POS_X, 0)
	_check(
		controller._brush_box() == Vector3i(3, 1, 2),
		"sideways GLB orientation should rotate its canonical 2x1x3 box"
	)
	controller.rotate_brush(K.DIR_UP, true)
	_check(
		controller.brush_prop_yaw_eighths == 1,
		"one horizontal arrow step should store a 45-degree GLB yaw"
	)
	_check(
		controller._brush_box() == Vector3i(4, 1, 4),
		"diagonal GLB yaw should reserve the transformed 4x1x4 AABB"
	)
	var diagonal_asset_prop := controller._prop_placement_for_origin(Vector3i.ZERO)
	_check(
		diagonal_asset_prop.yaw_eighths == 1,
		"direct GLB placement should retain the diagonal yaw"
	)

	# Terrain support records attachment separately, so moving the target from a
	# top face to a side face cannot override the brush's one orientation state.
	controller._active_prop_support_face = K.Face.POS_X
	_check(
		controller._resolved_prop_forward_face() == K.Face.POS_X
		and controller._resolved_prop_yaw_eighths() == 1,
		"a side target must retain the brush's canonical forward face and yaw"
	)
	var side_target_prop := controller._prop_placement_for_origin(Vector3i.ZERO)
	_check(
		side_target_prop.support == prop_placement_script.SUPPORT_WALL,
		"a side target should persist wall support without changing rotation"
	)
	controller._active_prop_support_face = K.Face.POS_Y
	_check(
		controller._resolved_prop_forward_face() == K.Face.POS_X
		and controller._resolved_prop_yaw_eighths() == 1,
		"a top target must use the same canonical rotation state as a side target"
	)
	var top_target_prop := controller._prop_placement_for_origin(Vector3i.ZERO)
	_check(
		top_target_prop.support == prop_placement_script.SUPPORT_FLOOR,
		"a top target should persist floor support independently from rotation"
	)
	# The collider preview must use the complete oriented footprint, not the one
	# triangle under the pointer. A farther voxel stands on 3.4 m terrain here.
	board.terrain = TerrainMesh.create(Vector2i(4, 4), Vector2i(4, 4))
	for z: int in range(4, 8):
		for x: int in range(4, 8):
			board.terrain.set_cell_filled(Vector2i(x, z), true)
			board.terrain.set_cell_top_level(Vector2i(x, z), 2.0)
	board.terrain.set_cell_top_level(Vector2i(7, 7), 3.4)
	prop_asset.prop_contact_flatten = false
	controller._apply_hover_pick({
		"hit": true,
		"cell": Vector3i(4, 2, 4),
		"point": Vector3(4.25, 2.75, 4.25),
		"terrain_face": {"face": K.Face.POS_Y},
	})
	_check(
		is_equal_approx(controller._preview_box.transform.origin.y, 3.4),
		"GLB collision preview should share the committed art's full-footprint support height"
	)
	prop_asset.prop_contact_flatten = true

	var diagonal_slot: Variant = blockout_slot_script.create_prop(
		"Diagonal GLB Blockout",
		Vector3i(2, 1, 3)
	)
	controller.set_blockout_only_mode(true)
	controller.set_slot_brush(diagonal_slot)
	controller.rotate_brush(K.DIR_UP, true)
	_check(
		controller.brush_prop_yaw_eighths == 1
		and controller._brush_box() == Vector3i(4, 1, 4),
		"GLB blockout brush should expose the same diagonal bounds"
	)
	var diagonal_slot_prop := controller._prop_placement_for_origin(Vector3i.ZERO)
	_check(
		diagonal_slot_prop.slot_id == diagonal_slot.slot_id
		and diagonal_slot_prop.yaw_eighths == 1,
		"GLB blockout placement should retain the diagonal yaw"
	)
	controller.set_blockout_only_mode(false)
	controller.set_brush(prop_asset)
	controller.set_prop_orientation(K.Face.POS_X, 0)

	controller.set_fill_shape(placement_controller_script.FillShape.PATH)
	controller.fill_vertices.append(Vector3i(0, 0, 0))
	controller.hovered_cell = Vector3i(12, 0, 0)
	controller._refresh_fill_candidates()
	_check(
		controller._fill_active_origins.size() == 1
		and controller._fill_preview_origins.size() == 5,
		"hovering a path endpoint should preview every intermediate 3m GLB stamp"
	)
	_check(
		controller._fill_preview_valid.multimesh != null
		and controller._fill_preview_valid.multimesh.instance_count == 5,
		"the live path volume should render all five pending footprint boxes"
	)
	_check(
		board.props.is_empty(),
		"previewing a path must not mutate BoardDocument before Enter"
	)
	controller.cancel_fill()

	controller.set_fill_shape(placement_controller_script.FillShape.POLYGON)
	controller.fill_vertices.append(Vector3i(0, 0, 0))
	controller.fill_vertices.append(Vector3i(6, 0, 0))
	controller.fill_vertices.append(Vector3i(6, 0, 4))
	controller.hovered_cell = Vector3i(0, 0, 4)
	controller._refresh_fill_candidates()
	_check(
		controller._fill_preview_origins.size() == 9,
		"hovering the fourth polygon point should preview its border and full 6x4 interior"
	)
	_check(
		board.props.is_empty(),
		"polygon setup must remain provisional until Enter commits it"
	)
	controller.cancel_fill()

	controller.set_fill_shape(placement_controller_script.FillShape.PATH)
	controller.fill_vertices.append(Vector3i(0, 0, 0))
	controller.fill_vertices.append(Vector3i(6, 0, 0))
	controller.fill_vertices.append(Vector3i(6, 0, 4))
	var route_origins: Array[Vector3i] = controller._generate_fill_origins(
		controller.fill_vertices
	)
	_check(
		route_origins.size() == 5,
		"a multi-segment prop path should follow every clicked corner without duplicates"
	)
	_check(
		route_origins[3] == Vector3i(6, 0, 2),
		"GLB path spacing should use the oriented box on each plane axis"
	)

	controller.set_fill_shape(placement_controller_script.FillShape.POLYGON)
	controller.fill_vertices.append(Vector3i(0, 0, 0))
	controller.fill_vertices.append(Vector3i(12, 0, 0))
	controller.fill_vertices.append(Vector3i(12, 0, 8))
	var diagonal_polygon_origins: Array[Vector3i] = controller._generate_fill_origins(
		controller.fill_vertices
	)
	_check(
		diagonal_polygon_origins.size() == 15,
		"a diagonal polygon should retain every centre-sampled border and interior stamp"
	)

	controller.fill_vertices.clear()
	controller.fill_vertices.append(Vector3i(0, 0, 0))
	controller.fill_vertices.append(Vector3i(6, 0, 0))
	controller.fill_vertices.append(Vector3i(6, 0, 4))
	controller.fill_vertices.append(Vector3i(0, 0, 4))
	var prop_polygon_origins: Array[Vector3i] = controller._generate_fill_origins(
		controller.fill_vertices
	)
	_check(
		prop_polygon_origins.size() == 9,
		"a 6x4 polygon should include all nine centre-sampled oriented GLB boxes"
	)

	controller.set_tool(placement_controller_script.Tool.FILL)
	controller._refresh_fill_candidates()
	_check(
		controller._fill_preview_valid.visible
		and controller._fill_preview_valid.multimesh != null,
		"Fill should make its accepted footprint batch visible before Enter"
	)
	if controller._fill_preview_valid.multimesh != null:
		var preview_box := controller._fill_preview_valid.multimesh.mesh as BoxMesh
		_check(
			controller._fill_preview_valid.multimesh.instance_count == 9,
			"Fill preview should contain one visible box per pending GLB stamp"
		)
		_check(
			preview_box != null and preview_box.size == Vector3(3, 1, 2),
			"each GLB preview box should expose its real oriented footprint"
		)
	_check(
		controller._fill_preview_guides.visible
		and controller._fill_preview_guides.mesh != null,
		"Fill should show stamp outlines and the clicked path before Enter"
	)

	var evaluated_props: Dictionary = controller._evaluate_placement_candidates(
		prop_polygon_origins
	)
	var prop_placements: Array[Resource] = evaluated_props["placements"]
	_check(
		prop_placements.size() == 9,
		"generic candidate validation should accept all non-overlapping GLB stamps"
	)

	var overlapping_origins: Array[Vector3i] = [
		Vector3i(20, 0, 20),
		Vector3i(21, 0, 20),
	]
	var overlap_report: Dictionary = controller._evaluate_placement_candidates(
		overlapping_origins
	)
	_check(
		(overlap_report["valid_origins"] as Array).size() == 1
		and (overlap_report["blocked_origins"] as Array).size() == 1,
		"generic batch validation should reserve GLB voxels between candidates"
	)

	var board_change_count := [0]
	board.board_changed.connect(func() -> void: board_change_count[0] += 1)
	controller._commit_placements_bulk(prop_placements, "Test GLB polygon Fill")
	_check(board.props.size() == 9, "bulk GLB Fill should add every validated prop")
	_check(
		board_change_count[0] == 1,
		"bulk GLB Fill should notify BoardDocument exactly once"
	)

	board.clear()
	controller.hovered_cell = Vector3i(20, 0, 20)
	_check(
		controller.paint_at_hover(),
		"single Paint should use the same generic placement pipeline"
	)
	_check(board.props.size() == 1, "single Paint should still place exactly one prop")

	# Direct finished assets still reject an occupied volume with Replace off,
	# then atomically displace it when the same toggle is enabled.
	board.clear()
	controller.set_blockout_only_mode(false)
	controller.set_replace_enabled(false)
	controller.set_brush(prop_asset)
	controller.hovered_cell = Vector3i(30, 0, 30)
	_check(controller.paint_at_hover(), "initial finished prop should paint")
	controller.set_brush(replacement_prop_asset)
	_check(
		not controller.paint_at_hover(),
		"finished prop should remain rejected when Replace is disabled"
	)
	_check(
		board.props.size() == 1 and board.props[0].asset_id == "PROP",
		"disabled Replace must preserve the original finished prop"
	)
	controller.set_replace_enabled(true)
	_check(
		controller.paint_at_hover(),
		"finished prop should paint over an occupied volume when Replace is enabled"
	)
	_check(
		board.props.size() == 1
		and board.props[0].asset_id == "PROP_REPLACEMENT",
		"enabled Replace must remove the finished prop and keep only the new one"
	)

	# Blockout slots exercise the identical replacement boundary without relying
	# on a bound visual asset: their authored slot reference is the canonical
	# identity that must replace the occupied surface.
	board.clear()
	var original_slot: Variant = blockout_slot_script.create_surface(
		"Blockout Original",
		Vector2i.ONE
	)
	var replacement_slot: Variant = blockout_slot_script.create_surface(
		"Blockout Replacement",
		Vector2i.ONE
	)
	board.add_slot(original_slot)
	board.add_slot(replacement_slot)
	controller.set_blockout_only_mode(true)
	controller.set_replace_enabled(false)
	controller.set_slot_brush(original_slot)
	controller.hovered_cell = Vector3i(40, 0, 40)
	_check(controller.paint_at_hover(), "initial blockout surface should paint")
	controller.set_slot_brush(replacement_slot)
	controller.set_replace_enabled(true)
	_check(
		controller.paint_at_hover(),
		"blockout surface should paint over an occupied surface when Replace is enabled"
	)
	_check(
		board.surfaces.size() == 1
		and board.surfaces[0].slot_id == "Blockout Replacement",
		"enabled Replace must remove the original blockout slot placement"
	)

	# Contact flatten is a permissive placement action over the exact voxel
	# projection. A tall terrain cell inside the asset's grid box but outside its
	# voxels must remain untouched and must never reject the GLB.
	board.clear()
	var irregular_prop_asset: TileAsset = tile_asset_script.new()
	irregular_prop_asset.asset_id = "IRREGULAR_PROP"
	irregular_prop_asset.source_type = K.SourceType.GLB_PROP
	irregular_prop_asset.grid_bounds = Vector3i(3, 1, 1)
	irregular_prop_asset.prop_voxels = [
		Vector3i(0, 0, 0),
		Vector3i(2, 0, 0),
	]
	library.assets.append(irregular_prop_asset)
	library.rebuild_index()
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i(3, 1))
	for x: int in 3:
		board.terrain.set_cell_filled(Vector2i(x, 0), true)
	board.terrain.set_cell_top_level(Vector2i(0, 0), 0.0)
	board.terrain.set_cell_top_level(Vector2i(1, 0), 7.0)
	board.terrain.set_cell_top_level(Vector2i(2, 0), 2.0)
	irregular_prop_asset.prop_contact_flatten = true
	irregular_prop_asset.prop_contact_flatten_smooth = false
	controller.set_replace_enabled(false)
	controller.set_brush(irregular_prop_asset)
	controller.hovered_cell = Vector3i.ZERO
	controller._evaluate_hover()
	_check(
		controller.hover_valid,
		"terrain relief and voxel-footprint holes must never block a GLB placement"
	)
	_check(
		controller.paint_at_hover(),
		"enabled contact flatten should place the GLB after adjusting terrain"
	)
	_check(
		board.props.size() == 1,
		"contact flatten should commit the GLB instead of treating terrain as a validator"
	)
	for footprint_x: int in [0, 2]:
		var flattened_top := board.terrain.cell_top(Vector2i(footprint_x, 0))
		_check(
			flattened_top.size() == 4
			and is_equal_approx(flattened_top[0], 2.0)
			and is_equal_approx(flattened_top[1], 2.0)
			and is_equal_approx(flattened_top[2], 2.0)
			and is_equal_approx(flattened_top[3], 2.0),
			"every voxel-footprint quad should use the native whole-cell flatten plane"
		)
	_check(
		is_equal_approx(board.terrain.cell_walk_height(Vector2i(1, 0)), 7.0),
		"a non-voxel hole inside the grid bounds must remain untouched"
	)

	# Smooth footprint flatten keeps the complete support footprint level while
	# shared boundary corners make the first outside quad the transition slope.
	board.clear()
	var smooth_prop_asset: TileAsset = tile_asset_script.new()
	smooth_prop_asset.asset_id = "SMOOTH_PROP"
	smooth_prop_asset.source_type = K.SourceType.GLB_PROP
	smooth_prop_asset.grid_bounds = Vector3i.ONE
	smooth_prop_asset.prop_voxels = [Vector3i.ZERO]
	library.assets.append(smooth_prop_asset)
	library.rebuild_index()
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i(2, 1))
	for x: int in 2:
		board.terrain.set_cell_filled(Vector2i(x, 0), true)
	board.terrain.set_cell_top_level(Vector2i(0, 0), 0.0)
	board.terrain.set_cell_top_level(Vector2i(1, 0), 0.0)
	# Raising only the outer grid corners tilts the first quad through shared
	# corners, so the seam at x=1 stays flush and stores no side face.
	board.terrain.set_lattice_corner_height(Vector2i(0, 0), 2.0)
	board.terrain.set_lattice_corner_height(Vector2i(0, 1), 2.0)
	_check(
		not board.terrain.seam_carries_side_face(Vector2i(0, 0), TerrainMesh.EDGE_EAST),
		"a shared-corner ramp must not store a wall at its flush seam"
	)
	smooth_prop_asset.prop_contact_flatten = true
	smooth_prop_asset.prop_contact_flatten_smooth = true
	controller.set_brush(smooth_prop_asset)
	controller.hovered_cell = Vector3i.ZERO
	_check(
		controller.paint_at_hover(),
		"smooth contact flatten should place the GLB after adjusting terrain"
	)
	_check(
		board.terrain.cell_relief(Vector2i(0, 0)) <= TerrainMesh.LEVEL_EPSILON_M
		and is_equal_approx(board.terrain.cell_walk_height(Vector2i(0, 0)), 2.0),
		"smooth contact flatten should make every footprint corner share one plane"
	)
	_check(
		board.terrain.cell_relief(Vector2i(1, 0)) > TerrainMesh.LEVEL_EPSILON_M,
		"smooth contact flatten should slope the adjacent quad through shared corners"
	)

	# A real wall stands on the footprint quad's east seam. Stepped contact flatten
	# levels the pad to the height ordinary placement already stands the GLB at, and
	# the surviving drop is rebuilt as a shorter wall rather than left as a hole.
	board.clear()
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i(2, 1))
	for x: int in 2:
		board.terrain.set_cell_filled(Vector2i(x, 0), true)
		board.terrain.set_cell_top_level(Vector2i(x, 0), 0.0)
	# Authored the way an import authors one: explicit corner heights followed by the
	# derivation that turns the resulting drop into a stored wall.
	board.terrain.set_cell_top(
		Vector2i(0, 0),
		PackedFloat32Array([0.0, 2.0, 0.0, 2.0])
	)
	board.terrain.rebuild_side_faces_for_cell(Vector2i(0, 0))
	board.terrain.rebuild_side_faces_for_cell(Vector2i(1, 0))
	_check(
		board.terrain.seam_carries_side_face(Vector2i(0, 0), TerrainMesh.EDGE_EAST),
		"the wall-edge fixture should begin with one real side face"
	)
	var wall_support_m := board.terrain.cell_walk_height(Vector2i(0, 0))
	smooth_prop_asset.prop_contact_flatten = true
	smooth_prop_asset.prop_contact_flatten_smooth = false
	controller.set_brush(smooth_prop_asset)
	controller.hovered_cell = Vector3i.ZERO
	_check(
		controller.paint_at_hover(),
		"stepped contact flatten should place against a real wall"
	)
	_check(
		board.terrain.cell_relief(Vector2i(0, 0)) <= TerrainMesh.LEVEL_EPSILON_M
		and is_equal_approx(
			board.terrain.cell_walk_height(Vector2i(0, 0)),
			wall_support_m
		),
		"stepped contact flatten must level the whole footprint quad onto the placed height"
	)
	_check(
		board.terrain.seam_carries_side_face(Vector2i(0, 0), TerrainMesh.EDGE_EAST)
		and is_equal_approx(board.terrain.cell_walk_height(Vector2i(1, 0)), 0.0),
		"the surviving drop must be rebuilt as a real wall instead of an open seam"
	)

	# The same fixture in smooth mode moves the shared lattice corners instead, so the
	# neighbouring quad slopes away over its own width and the seam goes flush.
	board.clear()
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i(2, 1))
	for x: int in 2:
		board.terrain.set_cell_filled(Vector2i(x, 0), true)
		board.terrain.set_cell_top_level(Vector2i(x, 0), 0.0)
	board.terrain.set_cell_top(
		Vector2i(0, 0),
		PackedFloat32Array([0.0, 2.0, 0.0, 2.0])
	)
	board.terrain.rebuild_side_faces_for_cell(Vector2i(0, 0))
	board.terrain.rebuild_side_faces_for_cell(Vector2i(1, 0))
	smooth_prop_asset.prop_contact_flatten = true
	smooth_prop_asset.prop_contact_flatten_smooth = true
	controller.set_brush(smooth_prop_asset)
	controller.hovered_cell = Vector3i.ZERO
	_check(
		controller.paint_at_hover(),
		"smooth contact flatten should place against a real wall"
	)
	_check(
		board.terrain.cell_relief(Vector2i(0, 0)) <= TerrainMesh.LEVEL_EPSILON_M
		and is_equal_approx(
			board.terrain.cell_walk_height(Vector2i(0, 0)),
			wall_support_m
		),
		"smooth contact flatten must level every footprint corner onto the placed height"
	)
	_check(
		board.terrain.cell_relief(Vector2i(1, 0)) > TerrainMesh.LEVEL_EPSILON_M
		and not board.terrain.seam_carries_side_face(
			Vector2i(0, 0),
			TerrainMesh.EDGE_EAST
		),
		"smooth contact flatten must slope the neighbour through the now-shared corners"
	)

	# The invariant the tearing defect violated. A GLB dropped onto a raised plateau
	# moves quads that walls stand on, so after the commit every seam whose two sides
	# hold different heights must carry a real side face, and every flush seam must
	# carry none. Writing corners without rebuilding left moved quads beside walls
	# that no longer reached them, which is the hole that appeared in the surface.
	board.clear()
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i(3, 3))
	for z: int in 3:
		for x: int in 3:
			board.terrain.set_cell_filled(Vector2i(x, z), true)
			board.terrain.set_cell_top_level(Vector2i(x, z), 0.0)
	board.terrain.set_cell_top_level(Vector2i(1, 1), 1.5)
	board.terrain.set_cell_top(
		Vector2i(1, 1),
		PackedFloat32Array([1.5, 1.5, 1.5, 0.9])
	)
	board.terrain.rebuild_side_faces_for_cell(Vector2i(1, 1))
	smooth_prop_asset.prop_contact_flatten = true
	smooth_prop_asset.prop_contact_flatten_smooth = false
	controller.set_brush(smooth_prop_asset)
	controller.hovered_cell = Vector3i(1, 0, 1)
	_check(
		controller.paint_at_hover(),
		"stepped contact flatten should place on an uneven raised plateau"
	)
	_check(
		board.terrain.cell_relief(Vector2i(1, 1)) <= TerrainMesh.LEVEL_EPSILON_M,
		"the plateau quad under the GLB should be level after the commit"
	)
	_check(
		_terrain_seams_agree_with_heights(board.terrain, Vector2i(3, 3)),
		"every seam left by contact flatten must be a real wall or genuinely flush"
	)

	# Enabling one asset setting after placement reapplies it to every existing
	# floor instance in one terrain transaction.
	board.clear()
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i(3, 1))
	for x: int in 3:
		board.terrain.set_cell_filled(Vector2i(x, 0), true)
		board.terrain.set_cell_top_level(Vector2i(x, 0), 0.0)
	board.terrain.set_lattice_corner_height(Vector2i(0, 0), 2.0)
	board.terrain.set_lattice_corner_height(Vector2i(3, 1), 3.0)
	smooth_prop_asset.prop_contact_flatten = false
	var first_existing := PropPlacement.create(
		smooth_prop_asset.asset_id,
		Vector3i.ZERO,
		K.Face.POS_Z,
		0,
		0
	)
	first_existing.support = PropPlacement.SUPPORT_FLOOR
	var second_existing := PropPlacement.create(
		smooth_prop_asset.asset_id,
		Vector3i(2, 0, 0),
		K.Face.POS_Z,
		0,
		0
	)
	second_existing.support = PropPlacement.SUPPORT_FLOOR
	var existing_instances: Array[PropPlacement] = [
		first_existing,
		second_existing,
	]
	board.add_props_bulk(existing_instances)
	smooth_prop_asset.prop_contact_flatten = true
	smooth_prop_asset.prop_contact_flatten_smooth = false
	_check(
		controller.apply_asset_contact_flatten(smooth_prop_asset.asset_id) == 2,
		"enabling per-asset flatten should process every existing floor instance"
	)
	_check(
		board.terrain.cell_relief(Vector2i(0, 0)) <= TerrainMesh.LEVEL_EPSILON_M
		and is_equal_approx(board.terrain.cell_walk_height(Vector2i(0, 0)), 2.0)
		and board.terrain.cell_relief(Vector2i(2, 0)) <= TerrainMesh.LEVEL_EPSILON_M
		and is_equal_approx(board.terrain.cell_walk_height(Vector2i(2, 0)), 3.0),
		"all existing instances should flatten their own exact footprint"
	)

	# Two adjacent complete wall edges protect the union of their endpoints: three
	# corners stay fixed and the one remaining corner is still flattened.
	board.clear()
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i(2, 2))
	for z: int in 2:
		for x: int in 2:
			board.terrain.set_cell_filled(Vector2i(x, z), true)
			board.terrain.set_cell_top_level(Vector2i(x, z), 0.0)
	for corner_index: int in [1, 2, 3]:
		board.terrain.set_cell_corner(Vector2i.ZERO, corner_index, 2.0)
	_check(
		board.terrain.seam_carries_side_face(Vector2i.ZERO, TerrainMesh.EDGE_EAST)
		and board.terrain.seam_carries_side_face(
			Vector2i.ZERO,
			TerrainMesh.EDGE_SOUTH
		),
		"the corner fixture should begin with two adjacent complete wall edges"
	)
	smooth_prop_asset.prop_contact_flatten = true
	smooth_prop_asset.prop_contact_flatten_smooth = true
	controller.set_brush(smooth_prop_asset)
	controller.hovered_cell = Vector3i.ZERO
	_check(
		controller.paint_at_hover(),
		"smooth contact flatten should use the one corner free at a wall intersection"
	)
	_check(
		board.terrain.cell_relief(Vector2i.ZERO) <= TerrainMesh.LEVEL_EPSILON_M
		and is_equal_approx(board.terrain.cell_walk_height(Vector2i.ZERO), 2.0),
		"the one unprotected wall-intersection corner should reach the support plane"
	)
	_check(
		board.terrain.seam_carries_side_face(Vector2i.ZERO, TerrainMesh.EDGE_EAST)
		and board.terrain.seam_carries_side_face(
			Vector2i.ZERO,
			TerrainMesh.EDGE_SOUTH
		),
		"both adjacent walls must survive flattening their one available corner"
	)

	controller.free()
	controller = null
	board = null
	library = null
	floor_asset = null
	prop_asset = null
	replacement_prop_asset = null
	diagonal_scan_asset = null
	missing_diagonal_asset = null
	fill_asset = null
	constants_script = null
	tile_asset_script = null
	asset_library_script = null
	board_document_script = null
	surface_placement_script = null
	prop_placement_script = null
	placement_controller_script = null
	blockout_slot_script = null

	print("placement_behavior_check: %d failures" % failures)
	quit(failures)


## Return whether both owners of one seam hold the same height at both endpoints.
##
## Each cell stores its own four corners, so a seam is flush only when the two
## quads independently agree at each end of the shared edge.
func _seam_is_flush(terrain: TerrainMesh, cell: Vector2i, edge: int) -> bool:
	var neighbour := cell + TerrainMesh.EDGE_NEIGHBOURS[edge]
	for entry: Variant in TerrainMesh.EDGE_CORNER_INDICES[edge]:
		var local_corner := int(entry)
		var world_corner := cell + TerrainMesh.CORNER_OFFSETS[local_corner]
		var neighbour_corner := terrain.local_corner_index(neighbour, world_corner)
		if neighbour_corner < 0:
			return false
		if not is_equal_approx(
			terrain.cell_corner(cell, local_corner),
			terrain.cell_corner(neighbour, neighbour_corner)
		):
			return false
	return true


## Return whether every internal seam's stored wall matches the heights around it.
##
## This is the no-tear invariant: a drop with no side face is an open hole, and a
## side face with no drop is a wall standing in mid-air. Either one means a write
## moved terrain without rebuilding the seams it changed.
func _terrain_seams_agree_with_heights(terrain: TerrainMesh, size: Vector2i) -> bool:
	for z: int in size.y:
		for x: int in size.x:
			var cell := Vector2i(x, z)
			if not terrain.is_cell_filled(cell):
				continue
			for edge: int in 4:
				var neighbour := cell + TerrainMesh.EDGE_NEIGHBOURS[edge]
				if not terrain.is_cell_filled(neighbour):
					continue
				var flush := _seam_is_flush(terrain, cell, edge)
				if flush == terrain.seam_carries_side_face(cell, edge):
					push_error(
						"seam %s edge %d is %s but %s a wall"
						% [
							cell,
							edge,
							"flush" if flush else "a drop",
							"carries" if flush else "carries no",
						]
					)
					return false
	return true
