@tool
extends SceneTree

## Headless verification of the spatial/data core.
##
## Run with:
##   godot --headless --script res://tests/run_tests.gd
##
## Covers the parts the spec says must not be got wrong: the coordinate and
## occupancy model, placement validation, save/load round-tripping, and the
## GLB scaling rules. Rendering and UI are verified interactively.

const K = preload("res://addons/modular_tile_studio/utils/mts_constants.gd")
const Canonicalizer = preload("res://addons/modular_tile_studio/importers/glb_canonicalizer.gd")
const DerivedPipeline = preload("res://addons/modular_tile_studio/analysis/derived_map_pipeline.gd")
const PlacementController = preload("res://addons/modular_tile_studio/viewport/placement_controller.gd")
const ProxyGenerator = preload("res://addons/modular_tile_studio/importers/proxy_generator.gd")
const Factory = preload("res://addons/modular_tile_studio/rendering/surface_material_factory.gd")
const ComfyProvider = preload("res://addons/modular_tile_studio/analysis/comfyui_provider.gd")

var _passed := 0
var _failed := 0


func _init() -> void:
	print("\n=== Modular Tile Kit Studio: core tests ===\n")

	_test_face_keys_and_normals()
	_test_surface_footprint_occupancy()
	_test_face_independence()
	_test_surface_overlap_rejected()
	_test_wall_rotation()
	_test_prop_occupancy_rotation()
	_test_prop_solid_collision()
	_test_surface_prop_coexistence()
	_test_footprint_grows_forward()
	_test_surface_sits_on_grid_line()
	_test_stair_step()
	_test_board_json_roundtrip()
	_test_legacy_blockout_import_round_trip()
	_test_proportional_scaling()
	_test_exact_stretch()
	_test_single_driver_axis()
	_test_grid_bounds_suggestion()
	_test_proxy_follows_shape()
	_test_gbuffer_optionality()
	_test_derived_maps()
	_test_vocabulary_export()
	_test_live_edit_updates_brush()
	_test_surface_preview_directionality()
	_test_look_profile_defaults_and_reset()
	_test_look_round_trip()
	_test_grade_ramp()
	_test_look_panels_build()
	_test_overlap_enforced_on_commit()
	_test_derived_channels_bake_into_runtime_maps()
	_test_moge_alpha_drives_transparency()
	_test_surface_alpha_modes()
	_test_particle_effect_round_trip_and_factory()
	_test_packed_material_map_is_unpacked()
	_test_level_asset_scope()

	print("\n=== %d passed, %d failed ===\n" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# --- Assertions -----------------------------------------------------------

func _check(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  PASS  %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [label, detail])


func _make_library() -> AssetLibrary:
	return AssetLibrary.new()


func _make_surface(library: AssetLibrary, id: String, w: int, h: int) -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = id
	asset.display_name = id
	asset.source_type = K.SourceType.IMAGE_SURFACE
	asset.grid_bounds = Vector3i(w, h, 1)
	asset.visual_size_m = Vector3(w, h, 0)
	asset.gbuffer = GBufferMapSet.new()
	library.add_asset(asset)
	return asset


func _make_prop(library: AssetLibrary, id: String, bounds: Vector3i, solid: Array[Vector3i]) -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = id
	asset.display_name = id
	asset.source_type = K.SourceType.GLB_PROP
	asset.grid_bounds = bounds
	asset.visual_size_m = Vector3(bounds)
	asset.gbuffer = GBufferMapSet.new()

	# The canonical voxel set is stored once. PropPlacement applies the same
	# complete orientation transform to this set and the source mesh at runtime.
	asset.prop_voxels.assign(solid)

	library.add_asset(asset)
	return asset


# --- Coordinate model -----------------------------------------------------

func _test_face_keys_and_normals() -> void:
	print("[coordinate model]")
	_check(K.face_key(Vector3i(4, 0, 7), K.Face.POS_Y) == "4,0,7,+Y", "face key format")
	_check(K.face_normal(K.Face.NEG_Z) == Vector3i(0, 0, -1), "NORTH is -Z")
	_check(K.face_from_name("+X") == K.Face.POS_X, "face name round-trip")
	_check(K.facing_from_name("W") == K.Facing.WEST, "facing name round-trip")
	# Every rotation axis has a deterministic quarter-turn result, including
	# pitch and roll. Four turns around one world axis return to the initial pose.
	var initial_prop_orientation := {
		"forward_face": K.Face.NEG_Z,
		"roll_quarters": 0,
		"yaw_eighths": 0,
	}
	var spun_prop_orientation := initial_prop_orientation
	for _turn in 8:
		spun_prop_orientation = K.rotate_prop_orientation(
			int(spun_prop_orientation["forward_face"]),
			int(spun_prop_orientation["roll_quarters"]),
			K.DIR_UP,
			true,
			int(spun_prop_orientation["yaw_eighths"])
		)
	_check(
		int(spun_prop_orientation["forward_face"])
		== int(initial_prop_orientation["forward_face"])
		and int(spun_prop_orientation["roll_quarters"])
		== int(initial_prop_orientation["roll_quarters"])
		and int(spun_prop_orientation["yaw_eighths"])
		== int(initial_prop_orientation["yaw_eighths"]),
		"eight prop yaw turns are identity"
	)
	var pitched_prop_orientation := K.rotate_prop_orientation(
		K.Face.NEG_Z,
		0,
		K.DIR_EAST,
		true
	)
	_check(
		int(pitched_prop_orientation["forward_face"]) != K.Face.NEG_Z,
		"prop pitch changes its forward face"
	)
	var rolled_prop_orientation := K.rotate_prop_orientation(
		K.Face.NEG_Z,
		0,
		K.DIR_SOUTH,
		true
	)
	_check(
		int(rolled_prop_orientation["forward_face"]) == K.Face.NEG_Z
		and int(rolled_prop_orientation["roll_quarters"]) != 0,
		"prop roll changes orientation without requiring a cardinal turn"
	)


func _test_surface_footprint_occupancy() -> void:
	print("[surface footprint]")
	var library := _make_library()
	var asset := _make_surface(library, "FLOOR_A", 2, 2)
	var placement := SurfacePlacement.create("FLOOR_A", Vector3i(0, 0, 0), K.Face.POS_Y, 0)
	var faces := placement.get_occupied_faces(asset)
	_check(faces.size() == 4, "2x2 floor occupies 4 faces", "got %d" % faces.size())

	var cells := {}
	for entry: Dictionary in faces:
		cells[K.face_key(entry["cell"], entry["face"])] = true
	_check(cells.size() == 4, "all four faces are distinct")

	var wall := _make_surface(library, "WALL_A", 3, 2)
	var wall_placement := SurfacePlacement.create("WALL_A", Vector3i(0, 0, 0), K.Face.POS_X, 0)
	_check(
		wall_placement.get_occupied_faces(wall).size() == 6,
		"3x2 wall occupies 6 faces"
	)


func _test_face_independence() -> void:
	print("[face independence]")
	# The rule that makes the whole model work: floor +Y, wall +X and wall -Z
	# may all meet at one coordinate because they are separate slots.
	var library := _make_library()
	_make_surface(library, "FLOOR_A", 1, 1)
	_make_surface(library, "WALL_A", 1, 1)
	var board := BoardDocument.new()
	board.bind_library(library)

	board.add_surface(SurfacePlacement.create("FLOOR_A", Vector3i(2, 0, 2), K.Face.POS_Y, 0))
	var east := SurfacePlacement.create("WALL_A", Vector3i(2, 0, 2), K.Face.POS_X, 0)
	var north := SurfacePlacement.create("WALL_A", Vector3i(2, 0, 2), K.Face.NEG_Z, 0)

	_check(board.validate_surface(east)["valid"], "east wall may share the floor's cell")
	board.add_surface(east)
	_check(board.validate_surface(north)["valid"], "north wall may join them too")
	board.add_surface(north)
	_check(board.surfaces.size() == 3, "three surfaces coexist at one coordinate")


func _test_surface_overlap_rejected() -> void:
	print("[surface overlap]")
	var library := _make_library()
	_make_surface(library, "FLOOR_A", 2, 2)
	var board := BoardDocument.new()
	board.bind_library(library)
	board.add_surface(SurfacePlacement.create("FLOOR_A", Vector3i(0, 0, 0), K.Face.POS_Y, 0))

	# Overlaps by one cell.
	var overlapping := SurfacePlacement.create("FLOOR_A", Vector3i(1, 0, 1), K.Face.POS_Y, 0)
	var result := board.validate_surface(overlapping)
	_check(not result["valid"], "overlapping the same face is rejected")
	_check(not String(result["reason"]).is_empty(), "rejection explains why", String(result["reason"]))

	# Clear of the first placement.
	var clear := SurfacePlacement.create("FLOOR_A", Vector3i(2, 0, 0), K.Face.POS_Y, 0)
	_check(board.validate_surface(clear)["valid"], "adjacent non-overlapping placement is allowed")


func _test_wall_rotation() -> void:
	print("[wall rotation]")
	var library := _make_library()
	var asset := _make_surface(library, "WALL_A", 3, 2)
	# A horizontal image rotated onto a vertical face must still claim 6 faces
	# and must extend vertically rather than flat.
	var placement := SurfacePlacement.create("WALL_A", Vector3i(0, 0, 0), K.Face.POS_Z, 0)
	var faces := placement.get_occupied_faces(asset)
	_check(faces.size() == 6, "rotated wall still occupies 6 faces")

	var max_y := -999
	for entry: Dictionary in faces:
		max_y = maxi(max_y, (entry["cell"] as Vector3i).y)
	_check(max_y == 1, "wall extends 2 cells vertically", "max y = %d" % max_y)


func _test_prop_occupancy_rotation() -> void:
	print("[prop occupancy]")
	var library := _make_library()
	# An L-shaped footprint so rotation is observable.
	var solid: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	var asset := _make_prop(library, "PILLAR_01", Vector3i(2, 4, 1), solid)

	var north := PropPlacement.create("PILLAR_01", Vector3i(5, 0, 5), K.Face.NEG_Z)
	# No terrain in this fixture, so the committed origin IS the base level.
	var north_cells := north.occupied_cells(asset, north.origin.y)
	_check(north_cells.has(Vector3i(6, 0, 5)), "north facing extends east")

	var east := PropPlacement.create("PILLAR_01", Vector3i(5, 0, 5), K.Face.POS_X)
	var east_cells := east.occupied_cells(asset, east.origin.y)
	_check(east_cells.has(Vector3i(5, 0, 6)), "east facing rotates the footprint")
	_check(not east_cells.has(Vector3i(6, 0, 5)), "old cell is released on rotation")

	# 3D occupancy: a tree occupies different voxels at different heights.
	var tree_solid: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 2, 0)]
	var tree := _make_prop(library, "TREE_01", Vector3i(3, 5, 3), tree_solid)
	var tree_placement := PropPlacement.create("TREE_01", Vector3i(0, 0, 0), K.Face.NEG_Z)
	var heights := {}
	for cell in tree_placement.occupied_cells(tree, tree_placement.origin.y):
		heights[cell.y] = true
	_check(heights.size() == 3, "prop occupancy spans three heights")


func _test_prop_solid_collision() -> void:
	print("[prop collision]")
	var library := _make_library()
	var solid: Array[Vector3i] = [Vector3i(0, 0, 0)]
	_make_prop(library, "ROCK_01", Vector3i(1, 1, 1), solid)
	var board := BoardDocument.new()
	board.bind_library(library)

	board.add_prop(PropPlacement.create("ROCK_01", Vector3i(3, 0, 3), K.Face.NEG_Z))
	var overlapping := PropPlacement.create("ROCK_01", Vector3i(3, 0, 3), K.Face.NEG_Z)
	_check(not board.validate_prop(overlapping)["valid"], "overlapping solid voxels rejected")

	var clear := PropPlacement.create("ROCK_01", Vector3i(4, 0, 3), K.Face.NEG_Z)
	_check(board.validate_prop(clear)["valid"], "adjacent prop allowed")


func _test_surface_prop_coexistence() -> void:
	print("[channel independence]")
	# Surfaces and props are different channels, so a pillar standing on a floor
	# is obviously legal.
	var library := _make_library()
	_make_surface(library, "FLOOR_A", 1, 1)
	var solid: Array[Vector3i] = [Vector3i(0, 0, 0)]
	_make_prop(library, "PILLAR_01", Vector3i(1, 3, 1), solid)

	var board := BoardDocument.new()
	board.bind_library(library)
	board.add_surface(SurfacePlacement.create("FLOOR_A", Vector3i(1, 0, 1), K.Face.POS_Y, 0))
	var prop := PropPlacement.create("PILLAR_01", Vector3i(1, 0, 1), K.Face.NEG_Z)
	_check(board.validate_prop(prop)["valid"], "a prop may stand on a floor surface")


func _test_footprint_grows_forward() -> void:
	print("[footprint direction]")
	# Regression: footprint axes were once taken from the quad's visual basis,
	# half of which points down-lattice. A 3-wide wall at x=-8 then occupied
	# -8/-9/-10 instead of -8/-7/-6, so adjacent tiles falsely collided.
	var library := _make_library()
	var wall := _make_surface(library, "WALL_A", 3, 2)
	var placement := SurfacePlacement.create("WALL_A", Vector3i(-8, 0, 0), K.Face.NEG_Z, 0)
	var keys := placement.face_keys(wall)
	_check(keys.has("-8,0,0,-Z"), "wall covers its origin cell")
	_check(keys.has("-7,0,0,-Z") and keys.has("-6,0,0,-Z"), "wall grows toward +X", str(keys))
	_check(not keys.has("-9,0,0,-Z"), "wall does not grow backward")

	var board := BoardDocument.new()
	board.bind_library(library)
	board.add_surface(placement)
	var neighbour := SurfacePlacement.create("WALL_A", Vector3i(-5, 0, 0), K.Face.NEG_Z, 0)
	_check(board.validate_surface(neighbour)["valid"], "adjacent wall segment is allowed")

	# Floors spread across the ground plane, both axes positive.
	var floor_asset := _make_surface(library, "FLOOR_B", 2, 2)
	var floor_placement := SurfacePlacement.create("FLOOR_B", Vector3i(4, 0, 7), K.Face.POS_Y, 0)
	var floor_keys := floor_placement.face_keys(floor_asset)
	_check(floor_keys.has("5,0,8,+Y"), "2x2 floor grows toward +X/+Z", str(floor_keys))
	_check(not floor_keys.has("4,0,6,+Y"), "floor does not grow toward -Z")

	# A quarter turn must swap which axis carries the width.
	var rotated := SurfacePlacement.create("WALL_A", Vector3i(0, 0, 0), K.Face.POS_Y, 1)
	var rotated_keys := rotated.face_keys(wall)
	_check(rotated_keys.size() == 6, "rotated footprint keeps its area")
	_check(rotated_keys.has("1,0,2,+Y"), "rotation swaps width onto the other axis", str(rotated_keys))


func _test_surface_sits_on_grid_line() -> void:
	print("[surface seating]")
	# Regression: the quad was displaced a full unit along its own normal, so a
	# wall straddled the grid line at the cell centre instead of standing on the
	# boundary, and floors floated at the top of their cell.
	var library := _make_library()
	var asset := _make_surface(library, "SURF_2X2", 2, 2)
	var nudge := 0.01

	# Walls stand exactly on the boundary plane their face names.
	var north := PlacementController.surface_transform(Vector3i(0, 0, 0), K.Face.NEG_Z, 0, asset)
	_check(absf(north.origin.z) < nudge, "-Z wall sits on z=0", str(north.origin))
	var south := PlacementController.surface_transform(Vector3i(0, 0, 0), K.Face.POS_Z, 0, asset)
	_check(absf(south.origin.z - 1.0) < nudge, "+Z wall sits on z=1", str(south.origin))
	var east := PlacementController.surface_transform(Vector3i(0, 0, 0), K.Face.POS_X, 0, asset)
	_check(absf(east.origin.x - 1.0) < nudge, "+X wall sits on x=1", str(east.origin))
	var west := PlacementController.surface_transform(Vector3i(0, 0, 0), K.Face.NEG_X, 0, asset)
	_check(absf(west.origin.x) < nudge, "-X wall sits on x=0", str(west.origin))

	# A floor is the surface you stand on, so it lies at the cell's own Y.
	var floor_tf := PlacementController.surface_transform(Vector3i(0, 0, 0), K.Face.POS_Y, 0, asset)
	_check(absf(floor_tf.origin.y) < nudge, "+Y floor lies at y=0", str(floor_tf.origin))
	var ceiling := PlacementController.surface_transform(Vector3i(0, 0, 0), K.Face.NEG_Y, 0, asset)
	_check(absf(ceiling.origin.y - 1.0) < nudge, "-Y ceiling lies at y=1", str(ceiling.origin))

	# In-plane, the quad centres on its own footprint: a 2-wide span centres at
	# 1.0 from the origin cell, not at the cell centre (0.5).
	_check(absf(north.origin.x - 1.0) < nudge, "2-wide wall centres on its footprint", str(north.origin))
	_check(absf(floor_tf.origin.x - 1.0) < nudge and absf(floor_tf.origin.z - 1.0) < nudge,
		"2x2 floor centres where its four cells meet", str(floor_tf.origin))

	# A 1x1 tile centres on the middle of its single cell.
	var single := _make_surface(library, "SURF_1X1", 1, 1)
	var one := PlacementController.surface_transform(Vector3i(3, 0, 5), K.Face.POS_Y, 0, single)
	_check(absf(one.origin.x - 3.5) < nudge and absf(one.origin.z - 5.5) < nudge,
		"1x1 floor centres in its cell", str(one.origin))


func _test_stair_step() -> void:
	print("[stair step]")
	# The canonical multi-level shape: floor, a 1 m lip, then floor one level up.
	# All three must coexist and land at distinct heights.
	var library := _make_library()
	var tile := _make_surface(library, "STEP_TILE", 1, 1)
	var board := BoardDocument.new()
	board.bind_library(library)

	var lower := SurfacePlacement.create("STEP_TILE", Vector3i(0, 0, 0), K.Face.POS_Y, 0)
	_check(board.validate_surface(lower)["valid"], "lower floor places at y=0")
	board.add_surface(lower)

	# The lip is a vertical face on the side of the lower cell.
	var lip := SurfacePlacement.create("STEP_TILE", Vector3i(0, 0, 0), K.Face.POS_X, 0)
	_check(board.validate_surface(lip)["valid"], "lip places on the same cell's +X face")
	board.add_surface(lip)

	var upper := SurfacePlacement.create("STEP_TILE", Vector3i(1, 1, 0), K.Face.POS_Y, 0)
	_check(board.validate_surface(upper)["valid"], "upper floor places at y=1")
	board.add_surface(upper)

	var lower_tf := PlacementController.surface_transform(lower.origin, lower.face, 0, tile)
	var upper_tf := PlacementController.surface_transform(upper.origin, upper.face, 0, tile)
	var lip_tf := PlacementController.surface_transform(lip.origin, lip.face, 0, tile)
	_check(absf(upper_tf.origin.y - lower_tf.origin.y - 1.0) < 0.01,
		"upper floor sits exactly 1 m above the lower", "%.3f vs %.3f" % [upper_tf.origin.y, lower_tf.origin.y])
	_check(absf(lip_tf.origin.x - 1.0) < 0.01, "lip stands on the boundary between them", str(lip_tf.origin))
	_check(absf(lip_tf.origin.y - 0.5) < 0.01, "lip spans the 1 m rise", str(lip_tf.origin))

	# Y-slice is editor visibility only and must not drop board data.
	_check(board.surfaces.size() == 3, "all three pieces persist in the document")


# --- Serialization --------------------------------------------------------

func _test_board_json_roundtrip() -> void:
	print("[board JSON round-trip]")
	var library := _make_library()
	_make_surface(library, "FLOOR_A", 2, 2)
	_make_surface(library, "WALL_A", 3, 2)
	var solid: Array[Vector3i] = [Vector3i(0, 0, 0)]
	_make_prop(library, "PILLAR_01", Vector3i(1, 4, 1), solid)

	var board := BoardDocument.new()
	board.bind_library(library)
	board.board_name = "Test Courtyard"
	board.add_surface(SurfacePlacement.create("FLOOR_A", Vector3i(4, 0, 7), K.Face.POS_Y, 0))
	board.add_surface(SurfacePlacement.create("WALL_A", Vector3i(0, 0, 0), K.Face.POS_X, 2))
	board.add_prop(PropPlacement.create("PILLAR_01", Vector3i(8, 0, 10), K.Face.POS_X))

	var path := "user://test_board.json"
	_check(board.save_json(path) == OK, "board saves")

	var reloaded := BoardDocument.new()
	reloaded.bind_library(library)
	_check(reloaded.load_json(path) == OK, "board loads")
	_check(reloaded.surfaces.size() == 2, "surface count preserved")
	_check(reloaded.props.size() == 1, "prop count preserved")

	var surface := reloaded.surfaces[0]
	_check(surface.origin == Vector3i(4, 0, 7), "surface origin preserved")
	_check(surface.face == K.Face.POS_Y, "surface face preserved")

	var wall := reloaded.surfaces[1]
	_check(wall.rotation_quarters == 2, "surface rotation preserved")

	var prop := reloaded.props[0]
	_check(prop.origin == Vector3i(8, 0, 10), "prop origin preserved")
	_check(prop.forward_face == K.Face.POS_X and prop.roll_quarters == 0, "prop orientation preserved")

	# The exact JSON shape is the future LLM contract, so check it directly.
	var json := board.to_json()
	var first: Dictionary = (json["surfaces"] as Array)[0]
	_check(first["asset"] == "FLOOR_A", "JSON uses asset ids")
	_check(first["face"] == "+Y", "JSON uses canonical face spelling")
	_check((first["origin"] as Array) == [4, 0, 7], "JSON origin is an int triple")
	var first_prop: Dictionary = (json["props"] as Array)[0]
	_check(first_prop["forward"] == "+X", "JSON uses the complete forward face")
	_check(first_prop["roll"] == 0, "JSON stores the prop roll explicitly")

	_check(reloaded.validate_all()["valid"], "reloaded board validates")


## Verify the two answers the library's level filter is built on.
##
## used_asset_ids() must report exactly what the board references -- placements,
## monster visuals and palette layers alike -- while the separate import record
## must survive a save/load and must never double-count an import that has since
## been placed.
func _test_level_asset_scope() -> void:
	print("[level asset scope]")
	var library := _make_library()
	_make_surface(library, "FLOOR_A", 2, 2)
	_make_surface(library, "OVERLAY_A", 1, 1)
	_make_surface(library, "NEVER_USED", 1, 1)
	var solid: Array[Vector3i] = [Vector3i(0, 0, 0)]
	_make_prop(library, "PILLAR_01", Vector3i(1, 4, 1), solid)
	_make_prop(library, "IMPORTED_ONLY", Vector3i(1, 1, 1), solid)

	var board := BoardDocument.new()
	board.bind_library(library)
	board.board_name = "Scope Test"
	board.add_surface(SurfacePlacement.create("FLOOR_A", Vector3i(0, 0, 0), K.Face.POS_Y, 0))
	board.add_prop(PropPlacement.create("PILLAR_01", Vector3i(3, 0, 3), K.Face.POS_X))
	var overlay_layer := board.material_blend.layer(0)
	overlay_layer["asset_id"] = "OVERLAY_A"
	board.material_blend.set_layer(0, overlay_layer)

	# FLOOR_A is noted as an import too: it must count as used, not as a pending one.
	board.note_imported_asset("IMPORTED_ONLY")
	board.note_imported_asset("FLOOR_A")
	board.note_imported_asset("IMPORTED_ONLY")

	var used := board.used_asset_ids()
	_check(used.has("FLOOR_A"), "placed surface counts as used")
	_check(used.has("PILLAR_01"), "placed prop counts as used")
	_check(used.has("OVERLAY_A"), "palette layer asset counts as used")
	_check(not used.has("NEVER_USED"), "unreferenced library asset is not used")
	_check(not used.has("IMPORTED_ONLY"), "an unplaced import is not used")
	_check(board.imported_asset_ids.size() == 2, "imports are recorded once each")

	var path := "user://test_level_scope.json"
	_check(board.save_json(path) == OK, "board with imports saves")
	var reloaded := BoardDocument.new()
	reloaded.bind_library(library)
	_check(reloaded.load_json(path) == OK, "board with imports loads")
	_check(
		reloaded.imported_asset_ids == board.imported_asset_ids,
		"import record survives the JSON round-trip"
	)
	_check(reloaded.used_asset_ids().has("OVERLAY_A"), "reloaded palette layer still counts as used")

	reloaded.forget_imported_asset("IMPORTED_ONLY")
	_check(
		not reloaded.imported_asset_ids.has("IMPORTED_ONLY"),
		"deleting an asset drops it from the import record"
	)

	# A board saved before the import record existed is valid, just empty here.
	var legacy := BoardDocument.new()
	legacy.bind_library(library)
	_check(
		legacy.from_json({"version": 10, "name": "Legacy", "surfaces": [], "props": []}) == OK,
		"board without an import record still loads"
	)
	_check(legacy.imported_asset_ids.is_empty(), "missing import record reads as no imports")


## Verify that a v3 blockout becomes a canonical board without losing its dimensions.
##
## This regression test covers the Open Board migration route: declarative
## geometry must compile before save/load, because BoardDocument stores the
## resulting placements rather than a second geometry representation.
##
## Only GLB props and surfaced boxes remain in the language; encounter ground is
## authored as terrain, so surface slots and surface_rect are rejected below.
func _test_legacy_blockout_import_round_trip() -> void:
	print("[legacy blockout import]")
	var compiler := BlockoutCompiler.new()
	var library := _make_library()
	var legacy := {
		"format": "mts_blockout",
		"version": 3,
		"name": "Legacy Courtyard",
		"slots": [
			{
				"name": "Legacy tent",
				"kind": "prop",
				"bounds_cells": [4, 2, 3],
			},
		],
		"geometry": [
			{
				"op": "prop",
				"slot": "Legacy tent",
				"origin": [0, 0, 0],
				"facing": "N",
				"attachment": "floor",
			},
		],
		"enemy_packs": [],
		"gameplay_markers": [],
	}
	# Props stand on terrain now, so the destination board supplies the ground the
	# imported prop is validated against.
	var ground := TerrainMesh.create(Vector2i(-2, -2), Vector2i(12, 12))
	for ground_z: int in 12:
		for ground_x: int in 12:
			ground.set_cell_filled(Vector2i(ground_x - 2, ground_z - 2), true)
	compiler.default_terrain = ground
	var result := compiler.compile(legacy, library)
	_check(bool(result.get("valid", false)), "v3 blockout compiles", str(result.get("errors", [])))
	if not bool(result.get("valid", false)):
		return

	var compiled: BoardDocument = result["board"] as BoardDocument
	var tent_slot := compiled.get_slot("Legacy tent")
	_check(compiled.props.size() == 1,
		"v3 geometry becomes canonical placements")
	_check(tent_slot != null and tent_slot.prop_bounds_cells == Vector3i(4, 2, 3),
		"v3 prop dimensions are retained")

	var reloaded := BoardDocument.new()
	reloaded.bind_library(library)
	reloaded.from_json(compiled.to_json())
	var reloaded_tent_slot := reloaded.get_slot("Legacy tent")
	_check(reloaded.props.size() == 1,
		"compiled placements survive the canonical save/load round trip")
	_check(reloaded_tent_slot != null and reloaded_tent_slot.prop_bounds_cells == Vector3i(4, 2, 3),
		"canonical save/load preserves the v3 prop dimensions")

	# Ground is terrain now, so the retired quad ops must fail loudly rather than
	# silently importing a second ground representation.
	var retired := legacy.duplicate(true)
	retired["slots"] = [{
		"name": "Legacy floor",
		"kind": "surface",
		"size_cells": [4, 3],
	}]
	retired["geometry"] = []
	var retired_result := compiler.compile(retired, library)
	_check(
		not bool(retired_result.get("valid", true)),
		"a retired surface slot is rejected instead of importing loose ground quads"
	)
	_check(reloaded.props[0].slot_id == "Legacy tent",
		"canonical prop retains its one slot reference")


# --- GLB scaling ----------------------------------------------------------

func _test_proportional_scaling() -> void:
	print("[proportional scaling]")
	var canon := Canonicalizer.new()
	# One explicit grid axis drives a uniform scale; all other dimensions derive
	# from the untouched source proportions.
	var original := Vector3(1.43, 5.72, 1.68)
	var plan := canon.compute_grid_plan(
		original,
		Vector3i(1, 4, 1),
		Vector3.AXIS_Y,
		false
	)
	var result: Vector3 = plan["actual_size"]
	_check(absf(result.y - 4.0) < 0.001, "Y reaches the requested 4 m")
	var factor := 4.0 / 5.72
	_check(absf(result.x - original.x * factor) < 0.001, "X scales proportionally")
	_check(absf(result.z - original.z * factor) < 0.001, "Z scales proportionally")
	_check((plan["scale"] as Vector3).is_equal_approx(Vector3.ONE * factor),
		"proportional sizing produces one uniform scale")


func _test_exact_stretch() -> void:
	print("[exact stretch]")
	var canon := Canonicalizer.new()
	var plan := canon.compute_grid_plan(
		Vector3(1.43, 5.72, 1.68),
		Vector3i(2, 4, 1),
		Vector3.AXIS_Y,
		true
	)
	var result: Vector3 = plan["actual_size"]
	_check(result.is_equal_approx(Vector3(2.0, 4.0, 1.0)),
		"stretch uses every exact requested grid dimension", str(result))
	_check(bool(plan["stretch_to_grid"]), "the plan exposes the authored stretch state")


func _test_single_driver_axis() -> void:
	print("[single proportional driver]")
	var canon := Canonicalizer.new()
	var plan := canon.compute_grid_plan(
		Vector3(2.0, 2.0, 2.0),
		Vector3i(99, 4, 99),
		Vector3.AXIS_Y,
		false
	)
	_check((plan["actual_size"] as Vector3).is_equal_approx(Vector3(4.0, 4.0, 4.0)),
		"proportional sizing derives non-driver dimensions from the source")
	_check((plan["grid_size"] as Vector3i) == Vector3i(4, 4, 4),
		"derived grid bounds expose the proportional result")


func _test_grid_bounds_suggestion() -> void:
	print("[grid bounds]")
	var canon := Canonicalizer.new()
	var suggested := canon.suggest_grid_bounds(Vector3(2.4, 6.8, 2.1))
	_check(suggested == Vector3i(3, 7, 3), "ceil of visual bounds", str(suggested))

	var raw_bounds := AABB(Vector3(-1, 0, -1), Vector3(2, 4, 2))
	var pose := canon.compute_pose(raw_bounds, Vector3.ONE, Vector3i(2, 4, 2))
	var transformed_bounds := (pose["transform"] as Transform3D) * raw_bounds
	_check(absf(transformed_bounds.position.y) < 0.001, "bottom sits on Y=0")
	_check(
		absf(transformed_bounds.position.x) < 0.001
		and absf(transformed_bounds.position.z) < 0.001,
		"the transformed mesh is centred inside its grid bounds"
	)


func _test_proxy_follows_shape() -> void:
	print("[proxy follows shape]")
	# Direct voxelization consumes the same final model transform used by the
	# visible GLB; no second proxy mesh representation exists.
	var post := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 3.0, 0.6)
	post.mesh = box
	post.position = Vector3(0, 1.5, 0)
	var root := Node3D.new()
	root.add_child(post)

	var generator := ProxyGenerator.new()
	var model_transform := Transform3D(
		Basis.IDENTITY,
		Vector3(1.5, 0.0, 1.5)
	)
	var solid: Array[Vector3i] = generator.voxelize(
		root,
		model_transform,
		Vector3i(3, 3, 3)
	)

	_check(solid.size() > 0, "post has solid cells")
	_check(solid.size() < 27, "post does not fill its whole grid box", "%d cells" % solid.size())
	var off_centre := false
	for cell: Vector3i in solid:
		if cell.x != 1 or cell.z != 1:
			off_centre = true
	_check(not off_centre, "solid cells stay in the centre column", str(solid))
	root.free()


# --- Maps -----------------------------------------------------------------

func _test_gbuffer_optionality() -> void:
	print("[g-buffer optionality]")
	var maps := GBufferMapSet.new()
	_check(maps.available_channels().is_empty(), "a new map set is empty")
	_check(not maps.has_channel("normal"), "absent channel reports absent")
	_check(maps.load_texture("normal") == null, "absent channel loads as null, not an error")
	maps.set_channel("albedo", "res://nonexistent.png")
	_check(maps.get_channel("albedo") == "res://nonexistent.png", "channel path is stored")
	_check(not maps.has_channel("albedo"), "a stored but unloadable path is not 'available'")


func _test_derived_maps() -> void:
	print("[derived maps]")
	var pipeline := DerivedPipeline.new()
	# A synthetic bump: derived maps must respond to real height variation.
	var height := Image.create(32, 32, false, Image.FORMAT_L8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 16, y - 16).length() / 16.0
			var v := clampf(1.0 - d, 0.0, 1.0)
			height.set_pixel(x, y, Color(v, v, v))

	var normal := pipeline.normal_from_height(height, 1.0)
	_check(normal.get_width() == 32, "normal map matches source size")
	var flat := normal.get_pixel(0, 0)
	# On the cone's west flank height rises with x, so the encoded normal tips
	# below the 0.5 neutral; on the east flank it tips above. Checking both
	# sides also proves the gradient has the right sign.
	var west_flank := normal.get_pixel(8, 16)
	var east_flank := normal.get_pixel(24, 16)
	var north_flank := normal.get_pixel(16, 8)
	var south_flank := normal.get_pixel(16, 24)
	_check(absf(flat.r - 0.5) < 0.06, "flat region encodes a neutral normal")
	_check(west_flank.r < 0.45, "west flank deflects the normal", "r=%.3f" % west_flank.r)
	_check(east_flank.r > 0.55, "east flank deflects the opposite way", "r=%.3f" % east_flank.r)
	# Godot's OpenGL tangent convention is green/+Y toward image-top. The
	# north half of a raised bump must therefore be green and the south half
	# magenta; this catches the exact height-derived inversion regression.
	_check(north_flank.g > 0.55, "north flank points along tangent +Y", "g=%.3f" % north_flank.g)
	_check(south_flank.g < 0.45, "south flank points along tangent -Y", "g=%.3f" % south_flank.g)

	var ao := pipeline.ambient_occlusion_from_height(height, null, 4, 8)
	_check(ao.get_pixel(16, 16).r >= ao.get_pixel(2, 2).r, "peak is less occluded than the flat surround")

	var curvature := pipeline.curvature_from_height(height)
	_check(curvature.get_width() == 32, "curvature generated")

	var orm := pipeline.pack_orm(ao, height, height)
	var texel := orm.get_pixel(16, 16)
	_check(absf(texel.r - ao.get_pixel(16, 16).r) < 0.02, "ORM red channel carries AO")


func _test_vocabulary_export() -> void:
	print("[LLM vocabulary]")
	var library := _make_library()
	_make_surface(library, "MONASTERY_FLOOR_01", 2, 2)
	var solid: Array[Vector3i] = [Vector3i(0, 0, 0)]
	_make_prop(library, "PILLAR_BROKEN_02", Vector3i(1, 4, 1), solid)

	var vocab := library.to_vocabulary_json()
	var entries: Array = vocab["assets"]
	_check(int(vocab["version"]) == 2, "canonical-orientation vocabulary version exported")
	_check(entries.size() == 2, "both assets exported")

	var surface: Dictionary = entries[0]
	_check(surface["channel"] == "surface", "surface channel tagged")
	_check(surface["source_orientation"] == "Y_UP", "surface source orientation is explicit")
	_check(not surface.has("default_face"), "surface asset carries no import-time face")
	_check((surface["legal_rotations"] as Array).size() == 4, "four legal rotations offered")

	var prop: Dictionary = entries[1]
	_check(prop["channel"] == "prop", "prop channel tagged")
	_check(prop["source_orientation"] == "Y_UP", "prop source orientation is explicit")
	_check(not prop.has("default_forward"), "prop asset carries no import-time facing")
	_check((prop["legal_forward_faces"] as Array).size() == 6, "six legal forward faces offered")
	_check((prop["legal_rolls"] as Array).size() == 4, "four legal prop rolls offered")

	# Unique id generation must not collide.
	var id_a := library.make_unique_id("Monastery Floor 01")
	_check(id_a == "MONASTERY_FLOOR_01_02", "colliding ids are suffixed", id_a)
	_check(library.make_unique_id("new wall!") == "NEW_WALL", "ids are sanitized")


# --- Live inspector edits -------------------------------------------------

## Asset edits must rebuild brush geometry without replacing editor orientation.
##
## The brush holds a live TileAsset reference, so a resize changes the preview
## immediately. Face, spin, forward, and roll remain transient placement state
## chosen only through the editor controls.
func _test_live_edit_updates_brush() -> void:
	print("[live inspector edits]")

	# --- Surfaces: resize ---
	var library := _make_library()
	var surface := _make_surface(library, "FLOOR_LIVE", 2, 2)
	var controller := PlacementController.new()
	controller.library = library
	controller.board = BoardDocument.new()
	controller.set_brush(surface)

	_check(
		controller.brush_asset.rotated_surface_footprint(controller.brush_quarters) == Vector2i(2, 2),
		"brush starts at the asset's authored size"
	)

	# The inspector edits the asset in place, exactly as the size spinbox does.
	surface.grid_bounds = Vector3i(4, 3, 1)
	surface.visual_size_m = Vector3(4, 3, 0)
	controller.refresh_brush()
	_check(
		controller.brush_asset.rotated_surface_footprint(controller.brush_quarters) == Vector2i(4, 3),
		"resizing the asset resizes the brush footprint",
		str(controller.brush_asset.rotated_surface_footprint(controller.brush_quarters))
	)

	# Every PNG starts Y-up; editor rotation is the only way to change its face.
	_check(controller.brush_face == K.Face.POS_Y, "surface brush starts canonical Y-up")
	controller.rotate_brush(K.DIR_UP, true)
	var hand_aimed := controller.brush_face
	surface.display_name = "renamed"
	controller.refresh_brush()
	_check(
		controller.brush_face == hand_aimed,
		"asset edits preserve the editor-selected surface orientation",
		K.face_name(controller.brush_face)
	)

	# --- Props: resize and complete orientation ---
	var prop := _make_prop(library, "PROP_LIVE", Vector3i(1, 1, 1), [Vector3i(0, 0, 0)] as Array[Vector3i])
	controller.set_brush(prop)
	_check(controller.brush_asset.grid_bounds == Vector3i(1, 1, 1), "prop brush starts at authored bounds")

	prop.grid_bounds = Vector3i(2, 1, 3)
	controller.refresh_brush()
	_check(
		K.oriented_prop_grid_bounds(
			controller.brush_asset.grid_bounds,
			controller.brush_prop_forward_face,
			controller.brush_prop_roll_quarters
		) == Vector3i(2, 1, 3),
		"resizing a prop resizes the brush volume",
		str(controller.brush_asset.grid_bounds)
	)

	_check(
		controller.brush_prop_forward_face == K.Face.NEG_Z
		and controller.brush_prop_roll_quarters == 0,
		"GLB brush starts in its canonical Y-up source orientation"
	)
	controller.set_prop_orientation(K.Face.POS_X, 0)
	controller.refresh_brush()
	_check(
		controller.brush_prop_forward_face == K.Face.POS_X
		and controller.brush_prop_roll_quarters == 0,
		"asset edits preserve the editor-selected prop orientation",
		K.face_name(controller.brush_prop_forward_face)
	)
	_check(
		K.oriented_prop_grid_bounds(
			controller.brush_asset.grid_bounds,
			controller.brush_prop_forward_face,
			controller.brush_prop_roll_quarters
		) == Vector3i(3, 1, 2),
		"the editor-rotated prop claims its rotated footprint"
	)

	# Every forward face and roll preserves volume, even when an axis moves into Y.
	for forward_face: int in K.FACE_NORMALS:
		for roll_quarters in 4:
			var oriented_bounds := K.oriented_prop_grid_bounds(
				prop.grid_bounds,
				forward_face,
				roll_quarters
			)
			_check(
				oriented_bounds.x * oriented_bounds.y * oriented_bounds.z
				== prop.grid_bounds.x * prop.grid_bounds.y * prop.grid_bounds.z,
				"every prop orientation preserves its box volume"
			)

	controller.set_prop_orientation(K.Face.NEG_Z, 0)
	controller.rotate_brush(K.DIR_EAST, true)
	_check(
		controller.brush_prop_forward_face != K.Face.NEG_Z,
		"prop pitch works directly from the canonical orientation"
	)
	controller.set_prop_orientation(K.Face.NEG_Z, 0)
	controller.rotate_brush(K.DIR_SOUTH, true)
	_check(
		controller.brush_prop_forward_face == K.Face.NEG_Z
		and controller.brush_prop_roll_quarters != 0,
		"prop roll works without a prior cardinal turn"
	)

	controller.free()


## Verify that PNG preview and production shaders preserve explicit surface directionality.
func _test_surface_preview_directionality() -> void:
	print("[surface preview directionality]")
	var library := _make_library()
	var asset := _make_surface(library, "PREVIEW_DIRECTION", 1, 1)
	asset.source_path = "res://icon.svg"

	var controller := PlacementController.new()
	controller.material_factory = Factory.new()
	var material := controller._build_surface_preview_material(asset, Color.WHITE) as ShaderMaterial
	_check(material != null, "surface preview uses a ShaderMaterial")
	if material != null:
		_check(bool(material.get_shader_parameter("has_albedo")),
			"surface preview receives the factory-resolved albedo")
		_check(
			material.shader != null
			and material.shader.code.contains("MODEL_NORMAL_MATRIX * NORMAL")
			and material.shader.code.contains("float camera_dot")
			and material.shader.code.contains("abs(authored_front_world.y)")
			and material.shader.code.contains(
				"mix(-camera_dot, camera_dot, horizontal_surface)"
			),
			"surface preview matches horizontal and vertical committed-side conventions"
		)
		_check(not material.shader.code.contains("FRONT_FACING"),
			"surface preview does not substitute triangle winding for authored front")

	var up_arrow := controller._build_surface_up_arrow()
	_check(up_arrow != null, "surface preview exposes an authored image-up arrow")
	if up_arrow != null:
		var arrow_arrays := up_arrow.surface_get_arrays(0)
		var arrow_vertices: PackedVector3Array = arrow_arrays[Mesh.ARRAY_VERTEX]
		_check(
			arrow_vertices.size() >= 3
			and arrow_vertices[0].y > arrow_vertices[1].y
			and arrow_vertices[0].y > arrow_vertices[2].y,
			"surface orientation arrow points along authored local +Y"
		)

	var orientation_keys := {}
	var all_fronts_match := true
	var all_frames_are_right_handed := true
	var all_solver_round_trips_match := true
	for face in range(6):
		for quarters in range(4):
			var transform := PlacementController.surface_transform(
				Vector3i.ZERO,
				face,
				quarters,
				asset
			)
			var front := Vector3i(transform.basis.z.round())
			var image_up := Vector3i(transform.basis.y.round())
			orientation_keys["%s|%s" % [front, image_up]] = true
			all_fronts_match = all_fronts_match and front == K.face_normal(face)
			all_frames_are_right_handed = (
				all_frames_are_right_handed
				and is_equal_approx(transform.basis.determinant(), 1.0)
			)
			var solved := K.surface_orientation_from_basis(transform.basis)
			all_solver_round_trips_match = (
				all_solver_round_trips_match
				and int(solved["face"]) == face
				and int(solved["rotation_quarters"]) == quarters
			)
	_check(orientation_keys.size() == 24,
		"all six faces and four spins have distinct front/image-up pairs")
	_check(all_fronts_match,
		"every surface transform preserves its selected authored front")
	_check(all_frames_are_right_handed,
		"every surface transform preserves winding and tangent handedness")
	_check(all_solver_round_trips_match,
		"the rotation solver round-trips all 24 surface orientations")

	var surface_shader := load("res://addons/modular_tile_studio/rendering/mts_surface_gpu.gdshader") as Shader
	_check(surface_shader != null, "production surface shader loads")
	if surface_shader != null:
		_check(surface_shader.code.contains("sqrt(max(1.0 - dot(xy, xy), 0.0))"),
			"production shader reconstructs positive Z for two-channel normal maps")
		_check(not surface_shader.code.contains("if (!FRONT_FACING)"),
			"production shader does not silently relight visible back faces")
		_check(not surface_shader.code.contains("use_godot_raymarched_parallax"),
			"production shader exposes no retired parallax algorithm switch")
		_check(surface_shader.code.contains("// RETIRED: Offset terrain samples once"),
			"production shader marks offset parallax as dead reference code")
		_check(surface_shader.code.contains("vec3 ray_origin_world = world_pos + sweep;"),
			"raymarch starts at the outward top of the relief volume")
		_check(surface_shader.code.contains(
			"vec3 resolved_offset_world = sweep + step_world * resolved_index;"
		), "raymarch resolves relief outward from the receiver plane")
		_check(surface_shader.code.contains(
			"return godot_raymarched_parallax_sample_world_pos(world_pos, world_normal);"
		), "raymarching is the sole active parallax path")
	controller.free()


func _test_overlap_enforced_on_commit() -> void:
	print("[overlap enforcement]")
	# The validators are tested above; this covers the GATE. A board that reports
	# a conflict but commits it anyway is the bug this exists to prevent.

	var library := _make_library()
	_make_surface(library, "FLOOR_E", 1, 1)
	_make_surface(library, "WALL_E", 1, 1)
	var solid: Array[Vector3i] = [Vector3i(0, 0, 0)]
	_make_prop(library, "ROCK_E", Vector3i(1, 1, 1), solid)

	var board := BoardDocument.new()
	board.bind_library(library)

	var controller := PlacementController.new()
	controller.library = library
	controller.board = board

	# --- Terrain paint: a PNG is stamped onto the grid, as it always was ---
	# This is the PRIMARY way art reaches the board. The placement record is
	# unchanged; only its geometry changed hands, because the heightfield already
	# provides the surface the texture is applied to and no quad is generated.
	controller.set_brush(library.get_asset("FLOOR_E"))
	controller.hovered_cell = Vector3i(0, 0, 0)
	controller._evaluate_hover()
	_check(
		controller.paint_at_hover(),
		"a terrain-paint PNG is stamped onto the grid"
	)
	_check(board.surfaces.size() == 1, "the placement reached the board",
		"surfaces = %d" % board.surfaces.size())
	_check(controller.last_rejection.is_empty(), "the stroke was not rejected",
		controller.last_rejection)

	# --- 3D: a prop may not land inside another prop's solid volume ---
	controller.set_brush(library.get_asset("ROCK_E"))
	controller.hovered_cell = Vector3i(5, 0, 5)
	_check(controller.paint_at_hover(), "first prop commits on empty ground")
	_check(not controller.paint_at_hover(), "second prop in the same voxel is refused")
	_check(board.props.size() == 1, "refused prop did not reach the board",
		"props = %d" % board.props.size())

	# --- A prop stands on terrain rather than on a painted quad ---
	var terrain_board := BoardDocument.new()
	terrain_board.bind_library(library)
	terrain_board.terrain = TerrainMesh.create(Vector2i(-2, -2), Vector2i(12, 12))
	for terrain_z: int in 12:
		for terrain_x: int in 12:
			terrain_board.terrain.set_cell_filled(
				Vector2i(terrain_x - 2, terrain_z - 2),
				true
			)
	controller.board = terrain_board
	controller.set_brush(library.get_asset("ROCK_E"))
	controller.hovered_cell = Vector3i(0, 0, 0)
	_check(controller.paint_at_hover(), "a prop may stand on terrain")
	_check(terrain_board.props.size() == 1, "the prop on terrain reached the board")
	controller.board = board

	# --- Document-level validation must catch overlap loaded from JSON ---
	var loaded := BoardDocument.new()
	loaded.bind_library(library)
	loaded.add_prop(PropPlacement.create("ROCK_E", Vector3i(2, 0, 2), K.Face.NEG_Z))
	loaded.add_prop(PropPlacement.create("ROCK_E", Vector3i(2, 0, 2), K.Face.NEG_Z))
	var report := loaded.validate_all()
	_check(not report["valid"], "validate_all rejects an overlapping prop pair")
	_check(report["errors"].size() > 0, "validate_all names the overlap",
		", ".join(report["errors"]))

	controller.free()


# --- Board look -----------------------------------------------------------
#
# Aesthetics and lighting are board state: they must reset cleanly per section,
# survive a save/load unchanged, and never leak from one board into the next.

func _test_look_profile_defaults_and_reset() -> void:
	print("[look profiles]")
	var look := AestheticProfile.new()
	_check(look.is_default(), "a fresh aesthetic profile is default")

	look.exposure = 0.4
	_check(not look.is_default(), "a modified profile no longer reports default")

	# Section reset must be surgical: resetting grade restores its fields without
	# changing any of the separate surface-GPU controls.
	look.reset_section(AestheticProfile.SECTION_GRADE)
	_check(is_equal_approx(look.exposure, 1.0), "grade reset restores exposure")
	look.reset_to_defaults()
	_check(look.is_default(), "reset_to_defaults clears everything")

	var rig := LightingProfile.new()
	_check(rig.is_default(), "a fresh lighting profile is default")
	rig.sun_azimuth_degrees = 90.0
	rig.ambient_energy = 1.5
	rig.add_light(Vector3(4, 3, 5))
	rig.reset_section(LightingProfile.SECTION_SUN)
	_check(is_equal_approx(rig.sun_azimuth_degrees, -38.0), "sun reset restores azimuth")
	_check(is_equal_approx(rig.ambient_energy, 1.5), "sun reset leaves ambient alone")
	_check(rig.lights.size() == 1, "sun reset does not delete local lights")

	for i in range(20):
		rig.add_light()
	_check(rig.lights.size() == LightingProfile.MAX_LIGHTS,
		"the light list is capped", "%d lights" % rig.lights.size())

	# Azimuth/elevation describes the source in compass space; Godot's
	# DirectionalLight3D rotation describes the opposite ray direction.
	rig.sun_elevation_degrees = 30.0
	rig.sun_azimuth_degrees = 45.0
	var rotation := rig.sun_rotation_degrees()
	var source_direction := -(Basis.from_euler(rotation * PI / 180.0) * Vector3.FORWARD)
	var source_horizontal := Vector2(source_direction.x, source_direction.z).normalized()
	_check(is_equal_approx(rotation.x, -30.0) and is_equal_approx(rotation.y, 135.0),
		"sun source bearing converts to Godot ray rotation", str(rotation))
	_check(source_horizontal.is_equal_approx(Vector2(sqrt(0.5), -sqrt(0.5))),
		"45-degree compass bearing comes from north-east", str(source_direction))
	_check(source_direction.y > 0.0, "positive sun elevation comes from above", str(source_direction))


func _test_look_round_trip() -> void:
	print("[look round trip]")
	var board := BoardDocument.new()
	board.aesthetics.exposure = 0.6
	board.lighting.tonemap_mode = 3
	board.lighting.sky_enabled = true
	board.lighting.sky_energy_multiplier = 1.4
	board.lighting.reflection_probe_enabled = true
	board.lighting.sdfgi_enabled = true
	board.lighting.ssao_enabled = true
	board.lighting.glow_enabled = true
	board.lighting.ssil_enabled = true
	board.lighting.ssr_enabled = true
	board.lighting.fog_enabled = true
	board.lighting.fog_height_density = 0.08
	board.lighting.volumetric_fog_enabled = true
	board.lighting.volumetric_fog_length_m = 48.0
	board.lighting.add_light(Vector3(2, 4, 6))
	board.lighting.lights[0]["name"] = "Brazier"
	board.lighting.lights[0]["type"] = LightingProfile.LocalLightType.SPOT
	board.lighting.lights[0]["intensity"] = 7.5
	board.lighting.lights[0]["light_size"] = 0.35
	board.lighting.lights[0]["spot_angle"] = 32.0

	var path := "user://look_round_trip_test.json"
	_check(board.save_json(path) == OK, "a board with a look saves")

	var reloaded := BoardDocument.new()
	_check(reloaded.load_json(path) == OK, "it loads back")
	_check(is_equal_approx(reloaded.aesthetics.exposure, 0.6), "a grade exposure survives the round trip")
	_check(reloaded.lighting.tonemap_mode == 3, "tonemap survives the round trip")
	_check(reloaded.lighting.sky_enabled
		and is_equal_approx(reloaded.lighting.sky_energy_multiplier, 1.4),
		"sky and image-lighting settings survive the round trip")
	_check(reloaded.lighting.reflection_probe_enabled
		and reloaded.lighting.sdfgi_enabled,
		"reflection and global-illumination settings survive the round trip")
	_check(
		reloaded.lighting.ssao_enabled
		and reloaded.lighting.glow_enabled
		and reloaded.lighting.ssil_enabled
		and reloaded.lighting.ssr_enabled,
		"screen-space lighting settings survive the round trip"
	)
	_check(
		reloaded.lighting.fog_enabled
		and reloaded.lighting.volumetric_fog_enabled
		and is_equal_approx(reloaded.lighting.fog_height_density, 0.08)
		and is_equal_approx(reloaded.lighting.volumetric_fog_length_m, 48.0),
		"depth, height, and volumetric fog survive the round trip"
	)
	_check(reloaded.lighting.lights.size() == 1, "local lights survive the round trip")
	if reloaded.lighting.lights.size() == 1:
		var light: Dictionary = reloaded.lighting.lights[0]
		_check(String(light["name"]) == "Brazier", "a light keeps its name")
		_check((light["position"] as Vector3).is_equal_approx(Vector3(2, 4, 6)),
			"a light keeps its position", str(light["position"]))
		_check(int(light["type"]) == LightingProfile.LocalLightType.SPOT,
			"a local light keeps its Omni or Spot type")
		_check(
			is_equal_approx(float(light["light_size"]), 0.35)
			and is_equal_approx(float(light["spot_angle"]), 32.0),
			"spot size and cone settings survive the round trip"
		)

	# A board saved before the look existed must load the DEFAULTS, not whatever
	# the previously open board happened to be set to.
	var legacy := BoardDocument.new()
	legacy.aesthetics.exposure = 3.3
	legacy.lighting.ambient_energy = 3.0
	legacy.from_json({"version": 1, "name": "Legacy", "surfaces": [], "props": []})
	_check(legacy.aesthetics.is_default(), "a board with no look block loads default aesthetics")
	_check(legacy.lighting.is_default(), "a board with no look block loads default lighting")

	# Hex colours are still accepted, so a profile exported from the plate tools
	# can be pasted in.
	var imported := LightingProfile.new()
	imported.from_json({"sun_color": "#ff8000"})
	_check(imported.sun_color.is_equal_approx(Color(1.0, 0.5019608, 0.0)),
		"a hex colour from an imported profile still parses", str(imported.sun_color))


func _test_grade_ramp() -> void:
	print("[colour grade]")
	var viewport := MTSStudioViewport.new()
	var look := AestheticProfile.new()

	_check(viewport._grade_ramp(look) == null,
		"a neutral grade needs no correction ramp")

	look.shadow_lift = 1.0
	var lifted: GradientTexture1D = viewport._grade_ramp(look)
	_check(lifted != null, "shadow lift produces a ramp")
	if lifted != null:
		var gradient := lifted.gradient
		# Gradient seeds itself with stops at 0 and 1; the ramp must not inherit
		# them on top of its own endpoints.
		_check(gradient.get_point_count() == 32,
			"the ramp has no leftover seed stops", "%d points" % gradient.get_point_count())
		_check(is_equal_approx(gradient.get_color(0).r, 0.0), "the ramp stays anchored at black")
		_check(is_equal_approx(gradient.get_color(gradient.get_point_count() - 1).r, 1.0),
			"the ramp stays anchored at white")
		_check(gradient.sample(0.25).r > 0.25, "shadow lift brightens the quarter tone")
		var monotonic := true
		var previous := -1.0
		for index in gradient.get_point_count():
			var value := gradient.get_color(index).r
			if value < previous:
				monotonic = false
			previous = value
		_check(monotonic, "the ramp never folds back on itself")

	look.shadow_lift = 0.0
	look.highlight_compression = 1.0
	var compressed: GradientTexture1D = viewport._grade_ramp(look)
	_check(compressed != null, "highlight compression produces a ramp")
	if compressed != null:
		var top := compressed.gradient.get_color(compressed.gradient.get_point_count() - 1).r
		_check(top < 1.0, "highlight compression rolls the top off", "%f" % top)

	viewport.free()


## The two look panels must build and stay bound to the right board.
##
## They are built by hand rather than from a scene, and the plugin binds a
## document immediately after constructing them -- before they enter the tree --
## so the build path has to tolerate that ordering.
func _test_look_panels_build() -> void:
	print("[look panels]")
	var board := BoardDocument.new()

	var aesthetics := AestheticsPanel.new()
	aesthetics.bind(board)
	# Board-wide surface and grade controls remain here while per-texture strengths
	# live in the Asset Inspector, so the panel still has a non-empty control count.
	var has_parallax_algorithm_toggle := false
	for toggle_field: Array in AestheticProfile.TOGGLE_FIELDS:
		if str(toggle_field[0]) == "godot_raymarched_parallax_enabled":
			has_parallax_algorithm_toggle = true
	_check(not has_parallax_algorithm_toggle,
		"the rendering panel exposes no retired parallax algorithm toggle")
	_check(_count_panel_controls(aesthetics) > 5,
		"the rendering panel builds its controls when bound before _ready",
		"%d controls" % _count_panel_controls(aesthetics))

	var lighting := LightingPanel.new()
	lighting.bind(board)
	var before := _count_panel_controls(lighting)
	_check(before > 45,
		"the lighting panel builds the complete sky, GI, screen, fog, and light controls",
		"%d controls" % before)

	board.lighting.add_light(Vector3(1, 2, 3))
	lighting.rebuild()
	_check(_count_panel_controls(lighting) > before, "adding a light adds its editor controls")

	board.aesthetics.exposure = 2.2
	board.reset_aesthetics()
	aesthetics.rebuild()
	_check(board.aesthetics.is_default(), "the rendering reset restores defaults")

	board.reset_lighting()
	lighting.rebuild()
	_check(board.lighting.is_default(), "the lighting reset restores defaults")
	_check(board.lighting.lights.is_empty(), "the lighting reset clears local lights")

	# Opening a different board must not leave a panel editing the old one.
	var other := BoardDocument.new()
	other.aesthetics.exposure = 2.75
	aesthetics.bind(other)
	_check(is_equal_approx(aesthetics.board.aesthetics.exposure, 2.75),
		"a panel follows a rebind to another board")

	aesthetics.free()
	lighting.free()


func _count_panel_controls(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		if child is HSlider or child is CheckBox or child is ColorPickerButton 		or child is OptionButton or child is LineEdit or child is Button:
			total += 1
		total += _count_panel_controls(child)
	return total



## Verify derivative analysis is retained for inspection but compiled out of runtime shading.
##
## Cavity and curvature are baked into ORM while detail normal is baked into the
## primary runtime normal, so their files remain inspectable without costing
## separate texture bindings or samples each frame.
func _test_derived_channels_bake_into_runtime_maps() -> void:
	print("[derived channels bake into runtime maps]")

	var stand_in := "res://icon.svg"
	var asset := TileAsset.new()
	asset.asset_id = "baked_channel_probe"
	asset.source_type = K.SourceType.IMAGE_SURFACE
	asset.source_path = stand_in
	asset.gbuffer = GBufferMapSet.new()
	for channel in [
		"albedo", "normal", "analysis_normal", "height", "orm",
		"cavity", "curvature", "detail_normal", "bent_normal",
	]:
		asset.gbuffer.set_channel(channel, stand_in)

	var factory := Factory.new()
	var material := factory.get_material(asset) as ShaderMaterial
	_check(material != null, "PNG surfaces use the canonical GPU ShaderMaterial")
	if material == null:
		return

	var shader_code := material.shader.code
	_check(bool(material.get_shader_parameter("has_orm")),
		"the packed ORM map reaches the runtime material")
	_check(
		not shader_code.contains("cavity_tex")
		and not shader_code.contains("curvature_tex")
		and not shader_code.contains("detail_normal_tex")
		and not shader_code.contains("bent_normal_tex"),
		"analysis-only derivative maps declare no runtime samplers"
	)
	_check(asset.gbuffer.is_bake_strength("cavity")
		and asset.gbuffer.is_bake_strength("curvature")
		and asset.gbuffer.is_bake_strength("detail_normal"),
		"derivative strengths are explicit bake controls")
	_check(not asset.gbuffer.is_bake_strength("ambient_occlusion")
		and not asset.gbuffer.is_bake_strength("roughness")
		and not asset.gbuffer.is_bake_strength("metallic"),
		"primary PBR response controls remain live runtime controls")


## MoGe emits a real alpha mask beside depth and normal. Throwing it away meant
## falling back on whatever alpha the source PNG happened to carry.
func _test_moge_alpha_drives_transparency() -> void:
	print("[analysis alpha drives transparency]")

	var stand_in := "res://icon.svg"
	var without := TileAsset.new()
	without.asset_id = "alpha_probe_without"
	without.source_type = K.SourceType.IMAGE_SURFACE
	without.source_path = stand_in
	without.gbuffer = GBufferMapSet.new()
	without.gbuffer.set_channel("albedo", stand_in)

	var with_alpha := TileAsset.new()
	with_alpha.asset_id = "alpha_probe_with"
	with_alpha.source_type = K.SourceType.IMAGE_SURFACE
	with_alpha.source_path = stand_in
	with_alpha.gbuffer = GBufferMapSet.new()
	with_alpha.gbuffer.set_channel("albedo", stand_in)
	with_alpha.gbuffer.set_channel("alpha", stand_in)

	var factory := Factory.new()
	factory.aesthetics = AestheticProfile.defaults()
	var plain := factory.get_material(without) as ShaderMaterial
	var masked := factory.get_material(with_alpha) as ShaderMaterial
	_check(plain != null and masked != null,
		"analysis alpha stays on the canonical GPU material path")
	if plain == null or masked == null:
		return
	_check(
		masked.get_shader_parameter("albedo_tex")
		!= plain.get_shader_parameter("albedo_tex"),
		"an analysis alpha mask is composited into the albedo Godot samples"
	)
	_check(masked.get_shader_parameter("albedo_tex") is Texture2D,
		"the masked albedo remains a real texture")


## Verify AUTO and explicit alpha settings choose the intended depth pipeline.
func _test_surface_alpha_modes() -> void:
	print("[surface alpha modes]")
	var factory := Factory.new()
	factory.aesthetics = AestheticProfile.defaults()
	var asset := TileAsset.new()
	asset.asset_id = "surface_alpha_test"
	asset.source_type = K.SourceType.IMAGE_SURFACE
	asset.surface_alpha_mode = TileAsset.SurfaceAlphaMode.AUTO

	var opaque_image := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
	opaque_image.fill(Color.WHITE)
	var alpha_image := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
	alpha_image.fill(Color(1.0, 1.0, 1.0, 0.4))
	var opaque_texture := ImageTexture.create_from_image(opaque_image)
	var alpha_texture := ImageTexture.create_from_image(alpha_image)

	_check(
		factory.resolved_alpha_mode(asset, opaque_texture)
		== TileAsset.SurfaceAlphaMode.OPAQUE,
		"AUTO keeps fully opaque PNGs in the opaque depth pipeline"
	)
	_check(
		factory.resolved_alpha_mode(asset, alpha_texture)
		== TileAsset.SurfaceAlphaMode.CUTOUT,
		"AUTO routes PNGs with alpha to the cutout depth pipeline"
	)

	var opaque_shader: Shader = factory._surface_shader(TileAsset.SurfaceAlphaMode.OPAQUE)
	var cutout_shader: Shader = factory._surface_shader(TileAsset.SurfaceAlphaMode.CUTOUT)
	var blend_shader: Shader = factory._surface_shader(TileAsset.SurfaceAlphaMode.BLEND)
	_check(opaque_shader != null and not opaque_shader.code.contains("ALPHA ="),
		"opaque shader writes no alpha")
	_check(cutout_shader != null and cutout_shader.code.contains("ALPHA_SCISSOR_THRESHOLD ="),
		"cutout shader uses alpha scissor")
	_check(
		blend_shader != null
		and blend_shader.code.contains("ALPHA =")
		and not blend_shader.code.contains("ALPHA_SCISSOR_THRESHOLD ="),
		"translucent shader blends continuously without cutout"
	)


## Verify particle placement data and the native GPUParticles3D factory together.
func _test_particle_effect_round_trip_and_factory() -> void:
	print("[custom particle effects]")
	var preset_script: Script = load(
		"res://addons/modular_tile_studio/data/particle_effect_preset.gd"
	)
	var placement_script: Script = load(
		"res://addons/modular_tile_studio/data/particle_effect_placement.gd"
	)
	var factory_script: Script = load(
		"res://addons/modular_tile_studio/rendering/particle_effect_factory.gd"
	)
	var preset := preset_script.new() as ParticleEffectPreset
	preset.preset_id = "HEADLESS_PARTICLE"
	preset.display_name = "Headless Particle"
	preset.texture_path = "res://icon.svg"
	preset.amount = 37
	var placement := placement_script.new() as ParticleEffectPlacement
	placement.initialize(preset.preset_id, Vector3(1.5, 2.0, 3.5))

	var board := BoardDocument.new()
	_check(board.add_particle_effect(placement), "a complete particle placement enters the board")
	var reloaded := BoardDocument.new()
	reloaded.from_json(board.to_json())
	_check(reloaded.particle_effects.size() == 1,
		"particle placements survive board JSON round-trip")
	if reloaded.particle_effects.size() == 1:
		var restored: ParticleEffectPlacement = reloaded.particle_effects[0]
		_check(restored.preset_id == preset.preset_id,
			"particle placement keeps its reusable preset ID")
		_check(restored.position.is_equal_approx(placement.position),
			"particle placement keeps its exact authored world position")

	var factory := factory_script.new() as ParticleEffectFactory
	var root := factory.build_emitter(preset, placement)
	_check(root != null, "a valid custom preset builds one native emitter")
	if root == null:
		return
	var particles := root.get_node("Emitter") as GPUParticles3D
	_check(particles != null, "the emitter owns GPUParticles3D")
	if particles != null:
		_check(particles.amount == 37, "the preset amount reaches GPUParticles3D")
		_check(particles.process_material is ParticleProcessMaterial,
			"the preset motion reaches ParticleProcessMaterial")
		_check(particles.draw_pass_1 is QuadMesh,
			"the uploaded image is drawn on the particle billboard quad")
	_check(root.position.is_equal_approx(placement.position),
		"the emitter root uses the canonical placement position")
	root.free()


## Marigold IID appearance returns roughness and metallicity PACKED into one
## image (R=roughness, G=metallicity). Registering that image under a single
## channel name keeps the red and silently discards the metallicity the model
## already computed -- so the packed layout is declared in the recipe and split
## on download.
func _test_packed_material_map_is_unpacked() -> void:
	print("[packed material map]")

	var provider := ComfyProvider.new()

	# The recipe must declare the layout, or there is nothing to split on.
	var recipe_path := "res://addons/modular_tile_studio/analysis/recipes/marigold_appearance.recipe.json"
	var recipe: Dictionary = {}
	if FileAccess.file_exists(recipe_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(recipe_path))
		if parsed is Dictionary:
			recipe = parsed

	var spec := provider._unpack_spec(recipe, "11", 0)
	_check(not spec.is_empty(),
		"the appearance recipe declares its packed material layout")
	_check(String(spec.get("r", "")) == "roughness",
		"the packed image's red channel is roughness", str(spec))
	_check(String(spec.get("g", "")) == "metallic",
		"the packed image's green channel is metallicity -- no longer discarded",
		str(spec))

	# A synthetic packed image: R and G deliberately different, so a split that
	# quietly used one channel for both would be caught.
	var packed := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	packed.fill(Color(0.8, 0.3, 0.0, 1.0))
	var dir := "user://test_unpack"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var packed_path := dir.path_join("material.png")
	_check(packed.save_png(ProjectSettings.globalize_path(packed_path)) == OK,
		"the packed probe image was written")

	var written := provider._unpack_channels(packed_path, spec, dir)
	_check(written.has("roughness") and written.has("metallic"),
		"unpacking produces BOTH channels", str(written.keys()))

	var roughness := Image.new()
	var metallic := Image.new()
	if written.has("roughness"):
		roughness.load(ProjectSettings.globalize_path(String(written["roughness"])))
	if written.has("metallic"):
		metallic.load(ProjectSettings.globalize_path(String(written["metallic"])))

	if not roughness.is_empty() and not metallic.is_empty():
		_check(absf(roughness.get_pixel(4, 4).r - 0.8) < 0.02,
			"roughness comes from the RED channel",
			"%f" % roughness.get_pixel(4, 4).r)
		_check(absf(metallic.get_pixel(4, 4).r - 0.3) < 0.02,
			"metallicity comes from the GREEN channel, not a copy of red",
			"%f" % metallic.get_pixel(4, 4).r)

	# The interleaved source must not survive: it looks like a channel map but
	# is really two of them, and anything loading it would get roughness with
	# metallicity smeared through the green channel.
	_check(not FileAccess.file_exists(packed_path),
		"the packed source is removed once split")

	# An image with no declared layout is left exactly as it is.
	_check(provider._unpack_channels(packed_path, {}, dir).is_empty(),
		"an unpacked image with no layout is passed through untouched")

	# And the split channels must actually reach the renderer.
	var stand_in := "res://icon.svg"
	var asset := TileAsset.new()
	asset.asset_id = "unpacked_metal_probe"
	asset.source_type = K.SourceType.IMAGE_SURFACE
	asset.source_path = stand_in
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", stand_in)
	asset.gbuffer.set_channel("metallic", stand_in)

	var factory := Factory.new()
	factory.aesthetics = AestheticProfile.defaults()
	var mat := factory.get_material(asset) as ShaderMaterial
	_check(
		mat != null
		and bool(mat.get_shader_parameter("has_metallic"))
		and mat.get_shader_parameter("metallic_tex") is Texture2D,
		"a metallic map reaches the canonical GPU material Godot renders"
	)
