extends SceneTree

## Focused regression for watertight mixed-mode terrain and bounded mesh rebuild input.

var failures: int = 0


## Defer the checks until global script classes are available to the SceneTree.
func _init() -> void:
	_run.call_deferred()


## Record one failed invariant with a precise diagnostic.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("TERRAIN HEIGHTFIELD CHECK FAILED: %s" % message)


## Create one completely filled rectangular terrain fixture at elevation zero.
func _filled_terrain(size: Vector2i) -> TerrainMesh:
	var terrain := TerrainMesh.create(Vector2i.ZERO, size)
	for z: int in size.y:
		for x: int in size.x:
			terrain.set_cell_filled(Vector2i(x, z), true)
	return terrain


## Return the exact side-band records owned by one cell edge.
func _side_records(
	terrain: TerrainMesh,
	cell: Vector2i,
	edge: int
) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for face: Dictionary in terrain.terrain_faces(8):
		if (
			int(face["kind"]) == TerrainMesh.FaceKind.SIDE
			and face["cell"] == cell
			and int(face["edge"]) == edge
		):
			found.append(face)
	return found


## Return whether one polygon contains a requested boundary vertex.
func _polygon_has_point(polygon: PackedVector3Array, expected: Vector3) -> bool:
	for point: Vector3 in polygon:
		if point.is_equal_approx(expected):
			return true
	return false


## Verify a flat step closes exactly against both endpoints of a sloped neighbour.
func _test_tapered_step_slope_wall() -> void:
	var terrain := _filled_terrain(Vector2i(2, 1))
	var stepped := Vector2i(0, 0)
	var sloped := Vector2i(1, 0)
	terrain.set_cell_top(stepped, PackedFloat32Array([1.0, 1.0, 1.0, 1.0]))
	terrain.set_cell_top(sloped, PackedFloat32Array([0.0, 0.0, 0.5, 0.5]))
	terrain.rebuild_side_faces_for_cell(stepped)
	terrain.rebuild_side_faces_for_cell(sloped)

	var profile := terrain.side_face(stepped, TerrainMesh.EDGE_EAST)
	_check(
		profile.size() == 6
		and is_equal_approx(float(profile[2]), 0.0)
		and is_equal_approx(float(profile[3]), 1.0)
		and is_equal_approx(float(profile[4]), 0.5)
		and is_equal_approx(float(profile[5]), 1.0),
		"a step/slope wall must store both neighbour endpoint heights"
	)

	var records := _side_records(terrain, stepped, TerrainMesh.EDGE_EAST)
	_check(records.size() == 1, "the tapered one-metre wall should emit one paint band")
	if records.size() != 1:
		return
	var polygon: PackedVector3Array = records[0]["polygon"]
	_check(
		_polygon_has_point(polygon, Vector3(1.0, 1.0, 0.0))
		and _polygon_has_point(polygon, Vector3(1.0, 1.0, 1.0))
		and _polygon_has_point(polygon, Vector3(1.0, 0.0, 0.0))
		and _polygon_has_point(polygon, Vector3(1.0, 0.5, 1.0)),
		"the visible wall polygon must touch both top faces at both shared endpoints"
	)
	if polygon.size() >= 3:
		var outward := (
			(polygon[1] - polygon[0]).cross(polygon[2] - polygon[0]).normalized()
		)
		_check(outward.dot(Vector3.RIGHT) > 0.99, "east wall winding must face east")

	# Triangulation is checked through triangle_records because that is the path the
	# live renderer builds its chunks from.
	var no_top_faces: Array[Dictionary] = []
	var side_faces: Array[Dictionary] = [records[0]]
	# This isolated side fixture has no authored edge subdivisions.
	var boundary_breakpoints: Dictionary = {}
	var built := MTSTerrainMeshBuilder.triangle_records(
		no_top_faces,
		side_faces,
		boundary_breakpoints
	)
	_check(
		built.size() == 2,
		"the tapered quad must fan-triangulate into two visible triangles"
	)


## Verify a height-order crossing splits ownership at one identical seam point.
func _test_crossing_step_slope_ownership() -> void:
	var terrain := _filled_terrain(Vector2i(2, 1))
	var left := Vector2i(0, 0)
	var right := Vector2i(1, 0)
	terrain.set_cell_top(left, PackedFloat32Array([1.0, 1.0, 1.0, 1.0]))
	terrain.set_cell_top(right, PackedFloat32Array([0.0, 0.0, 2.0, 2.0]))
	terrain.rebuild_side_faces_for_cell(left)
	terrain.rebuild_side_faces_for_cell(right)

	var left_profile := terrain.side_face(left, TerrainMesh.EDGE_EAST)
	var right_profile := terrain.side_face(right, TerrainMesh.EDGE_WEST)
	_check(
		left_profile.size() == 6
		and right_profile.size() == 6
		and is_equal_approx(float(left_profile[1]), 0.5)
		and is_equal_approx(float(right_profile[1]), 0.5),
		"a crossing edge must split into two complementary half-edge owners"
	)

	var crossing := Vector3(1.0, 1.0, 0.5)
	var left_records := _side_records(terrain, left, TerrainMesh.EDGE_EAST)
	var right_records := _side_records(terrain, right, TerrainMesh.EDGE_WEST)
	_check(
		left_records.size() == 1
		and right_records.size() == 1,
		"each side of a crossing should emit one triangular paint band"
	)
	if left_records.size() == 1 and right_records.size() == 1:
		var left_polygon: PackedVector3Array = left_records[0]["polygon"]
		var right_polygon: PackedVector3Array = right_records[0]["polygon"]
		_check(
			left_polygon.size() == 3
			and right_polygon.size() == 3
			and _polygon_has_point(left_polygon, crossing)
			and _polygon_has_point(right_polygon, crossing),
			"both crossing polygons must terminate on the identical interpolated point"
		)
		_check(
			left_records[0]["grid_cell"] != right_records[0]["grid_cell"]
			or int(left_records[0]["face"]) != int(right_records[0]["face"]),
			"complementary crossing faces must keep distinct stable grid addresses"
		)


## Verify a lattice slope applied after a step leaves one sealed triangular wall.
func _test_step_then_shared_corner_slope() -> void:
	var terrain := _filled_terrain(Vector2i(2, 1))
	var stepped := Vector2i(0, 0)
	terrain.set_cell_top_level(stepped, 1.0)
	terrain.set_lattice_corner_height(Vector2i(1, 0), 0.25)

	var profile := terrain.side_face(stepped, TerrainMesh.EDGE_EAST)
	_check(
		profile.size() == 6
		and is_equal_approx(float(profile[2]), 0.25)
		and is_equal_approx(float(profile[3]), 0.25)
		and is_equal_approx(float(profile[4]), 0.0)
		and is_equal_approx(float(profile[5]), 1.0),
		"a slope edit after a step must retain the surviving endpoint gap"
	)
	var records := _side_records(terrain, stepped, TerrainMesh.EDGE_EAST)
	_check(
		records.size() == 1
		and (records[0]["polygon"] as PackedVector3Array).size() == 3,
		"the zero-gap endpoint must become a clean triangle rather than a torn quad"
	)


## Verify removing footprint occupancy replaces an internal wall with only its skirt.
func _test_footprint_removal_clears_internal_wall() -> void:
	var terrain := _filled_terrain(Vector2i(2, 1))
	var remaining := Vector2i(0, 0)
	var removed := Vector2i(1, 0)
	terrain.set_cell_top_level(remaining, 1.0)
	_check(
		terrain.has_side_face(remaining, TerrainMesh.EDGE_EAST),
		"the raised cell must begin with one internal wall against its neighbour"
	)
	terrain.set_cell_filled(removed, false)
	_check(
		not terrain.has_side_face(remaining, TerrainMesh.EDGE_EAST),
		"removing the neighbour must clear the obsolete internal side profile"
	)
	var internal_sides := 0
	var boundary_skirts := 0
	for face: Dictionary in terrain.terrain_faces(8):
		if face["cell"] != remaining or int(face["edge"]) != TerrainMesh.EDGE_EAST:
			continue
		if int(face["kind"]) == TerrainMesh.FaceKind.SIDE:
			internal_sides += 1
		elif int(face["kind"]) == TerrainMesh.FaceKind.SKIRT:
			boundary_skirts += 1
	_check(
		internal_sides == 0 and boundary_skirts > 0,
		"the newly exposed edge must contain skirts without overlapping stale walls"
	)


## Verify a sloped footprint boundary closes as a complete one-metre shell.
func _test_sloped_boundary_skirt_closure() -> void:
	var terrain := _filled_terrain(Vector2i.ONE)
	terrain.set_cell_top(
		Vector2i.ZERO,
		PackedFloat32Array([0.25, 1.75, 0.25, 1.75])
	)
	var records: Array[Dictionary] = []
	for face: Dictionary in terrain.terrain_faces(8):
		if (
			int(face["kind"]) == TerrainMesh.FaceKind.SKIRT
			and face["cell"] == Vector2i.ZERO
			and int(face["edge"]) == TerrainMesh.EDGE_NORTH
		):
			records.append(face)
	_check(records.size() == 3, "the one-metre sloped skirt spans its three crossed levels")
	var total_area := 0.0
	var expected_vertices := {
		Vector3(0.0, 0.25, 0.0): false,
		Vector3(1.0, 1.75, 0.0): false,
		Vector3(0.0, terrain.skirt_base_m, 0.0): false,
		Vector3(1.0, terrain.skirt_base_m, 0.0): false,
	}
	for record: Dictionary in records:
		_check(record.has("polygon"), "every sloped skirt band exposes its exact polygon")
		var polygon: PackedVector3Array = record["polygon"]
		for point: Vector3 in polygon:
			for expected: Vector3 in expected_vertices.keys():
				if point.is_equal_approx(expected):
					expected_vertices[expected] = true
		for triangle: int in range(1, polygon.size() - 1):
			total_area += (
				(polygon[triangle] - polygon[0])
					.cross(polygon[triangle + 1] - polygon[0])
					.length()
					* 0.5
			)
		if polygon.size() >= 3:
			var outward := (
				(polygon[1] - polygon[0]).cross(polygon[2] - polygon[0]).normalized()
			)
			_check(outward.dot(Vector3.FORWARD) > 0.99, "north skirt winding faces north")
	for endpoint_found: bool in expected_vertices.values():
		_check(endpoint_found, "the skirt keeps every top and derived bottom endpoint")
	var expected_area := (
		(0.25 - terrain.skirt_base_m)
		+ (1.75 - terrain.skirt_base_m)
	) * 0.5
	_check(
		is_equal_approx(total_area, expected_area),
		"the band polygons exactly cover the slope down to the authored base"
	)


## Verify every cardinal side polygon winds away from the cell that owns it.
func _test_cardinal_side_winding() -> void:
	var terrain := _filled_terrain(Vector2i(3, 3))
	var centre := Vector2i(1, 1)
	terrain.set_cell_top_level(centre, 1.0)
	for edge: int in 4:
		var records := _side_records(terrain, centre, edge)
		_check(records.size() == 1, "each cardinal step edge must emit one side polygon")
		if records.size() != 1:
			continue
		var polygon: PackedVector3Array = records[0]["polygon"]
		_check(polygon.size() >= 3, "each cardinal side polygon must contain one triangle")
		if polygon.size() < 3:
			continue
		var normal := (
			(polygon[1] - polygon[0]).cross(polygon[2] - polygon[0]).normalized()
		)
		var direction := TerrainMesh.EDGE_NEIGHBOURS[edge]
		var expected := Vector3(float(direction.x), 0.0, float(direction.y))
		_check(
			normal.dot(expected) > 0.99,
			"side edge %d must wind outward toward its neighbour" % edge
		)


## Verify optional texture seeding identifies only top and bottom side-grid residuals.
func _test_thin_side_texture_seed_identity() -> void:
	var upper_sliver_terrain := _filled_terrain(Vector2i(2, 1))
	var upper_cell := Vector2i(0, 0)
	upper_sliver_terrain.set_cell_top_level(upper_cell, 2.05)
	var upper_records := _side_records(
		upper_sliver_terrain,
		upper_cell,
		TerrainMesh.EDGE_EAST
	)
	_check(upper_records.size() == 3, "a 2.05 m wall must expose two full bands and one top residual")
	if upper_records.size() == 3:
		var upper_sliver: Dictionary = upper_records[2]
		_check(
			float(upper_sliver["top_m"]) - float(upper_sliver["bottom_m"])
			< TerrainMesh.THIN_SIDE_TEXTURE_SEED_MAX_HEIGHT_M,
			"the top residual must be below the visible 0.1 m limit"
		)
		_check(
			String(upper_sliver.get("texture_seed_uid", ""))
			== TerrainMesh.band_uid(upper_cell, TerrainMesh.EDGE_EAST, 1),
			"a top residual must resolve to its nearest complete lower 1 m side square"
		)
		_check(
			String(upper_records[1].get("texture_seed_uid", "")).is_empty(),
			"a complete 1 m side square must never inherit another texture seed"
		)

	var lower_sliver_terrain := _filled_terrain(Vector2i(2, 1))
	var lower_cell := Vector2i(0, 0)
	lower_sliver_terrain.set_cell_top_level(lower_cell, 2.0)
	lower_sliver_terrain.set_cell_top_level(Vector2i(1, 0), 0.95)
	var lower_records := _side_records(
		lower_sliver_terrain,
		lower_cell,
		TerrainMesh.EDGE_EAST
	)
	_check(lower_records.size() == 2, "a 1.05 m wall must expose one bottom residual and one full band")
	if lower_records.size() == 2:
		var lower_sliver: Dictionary = lower_records[0]
		_check(
			String(lower_sliver.get("texture_seed_uid", ""))
			== TerrainMesh.band_uid(lower_cell, TerrainMesh.EDGE_EAST, 1),
			"a bottom residual must resolve to its nearest complete upper 1 m side square"
		)


## Verify a one-metre step targets and moves exactly one one-metre cell.
func _test_one_metre_step_target() -> void:
	var terrain := _filled_terrain(Vector2i(3, 3))
	var sculptor := TerrainSculptor.new(terrain)
	var settings := TerrainSculptor.Settings.new()
	settings.mode = TerrainSculptor.Mode.STEP_UP
	settings.size_m = 1.0
	settings.step_m = 1.0
	sculptor.configure(settings)
	var target := Vector2(1.5, 1.5)
	var cells := sculptor.cell_targets(target)
	_check(
		cells == PackedVector2Array([Vector2(1.0, 1.0)]),
		"a 1 m targeter must expose exactly the centred 1 m cell"
	)
	sculptor.begin_stroke()
	sculptor.stamp(target)
	sculptor.finish_stroke()
	for z: int in 3:
		for x: int in 3:
			var expected := 1.0 if Vector2i(x, z) == Vector2i(1, 1) else 0.0
			_check(
				is_equal_approx(terrain.cell_walk_height(Vector2i(x, z)), expected),
				"a 1 m step must not move a neighbouring cell"
			)


## Verify every terrain action uses one exact square cell query.
func _test_shared_footprint_targets() -> void:
	var centre := Vector2(4.5, 4.5)
	var three_metres := TerrainSculptor.brush_cell_targets(centre, centre, 3.0)
	var two_metres := TerrainSculptor.brush_cell_targets(centre, centre, 2.0)
	var expected_two_metres := PackedVector2Array([
		Vector2(4.0, 4.0),
		Vector2(5.0, 4.0),
		Vector2(4.0, 5.0),
		Vector2(5.0, 5.0),
	])
	_check(three_metres.size() == 9, "a 3 m footprint must expose its centred nine cells")
	_check(
		two_metres == expected_two_metres,
		"a 2 m footprint must expose one exact 2 x 2 square without a cross"
	)


## Verify near-corner ray hits cannot make segment traversal overshoot forever.
##
## These endpoints reproduce both positive and negative versions of the former
## approximate-equality bug using ordinary triangle-raycast precision.
func _test_near_corner_segment_traversal() -> void:
	var positive := TerrainSculptor.brush_cell_targets(
		Vector2(0.5, 0.2),
		Vector2(1.0, 0.999999),
		1.0
	)
	_check(
		positive == PackedVector2Array([
			Vector2(0.0, 0.0),
			Vector2(1.0, 0.0),
		]),
		"a near positive grid corner must stop in its exact destination cell"
	)

	var negative := TerrainSculptor.brush_cell_targets(
		Vector2(-0.5, -0.8),
		Vector2(-1.0, -1.000001),
		1.0
	)
	_check(
		negative == PackedVector2Array([
			Vector2(-1.0, -1.0),
			Vector2(-1.0, -2.0),
		]),
		"a near negative grid corner must stop in its exact destination cell"
	)


## Verify maximum smooth Raise is four times the previous 0.25 m maximum.
func _test_stronger_smooth_strength() -> void:
	var terrain := _filled_terrain(Vector2i.ONE)
	var sculptor := TerrainSculptor.new(terrain)
	var settings := TerrainSculptor.Settings.new()
	settings.mode = TerrainSculptor.Mode.RAISE
	settings.size_m = 1.0
	settings.strength = 1.0
	sculptor.configure(settings)
	sculptor.begin_stroke()
	sculptor.stamp(Vector2(0.5, 0.5))
	sculptor.finish_stroke()
	_check(
		is_equal_approx(terrain.lattice_top_height(Vector2i.ZERO), 1.0),
		"maximum smooth Raise must move a fully targeted corner by 1 m per pulse"
	)


## Verify held sculpt pulses repeat deterministically within one undoable stroke.
func _test_held_step_pulses() -> void:
	var terrain := _filled_terrain(Vector2i.ONE)
	var sculptor := TerrainSculptor.new(terrain)
	var settings := TerrainSculptor.Settings.new()
	settings.mode = TerrainSculptor.Mode.STEP_UP
	settings.size_m = 1.0
	settings.step_m = 1.0
	sculptor.configure(settings)
	sculptor.begin_stroke()
	sculptor.stamp(Vector2(0.5, 0.5))
	sculptor.begin_pulse()
	sculptor.stamp(Vector2(0.5, 0.5))
	var stroke := sculptor.finish_stroke()
	_check(
		is_equal_approx(terrain.cell_walk_height(Vector2i.ZERO), 2.0),
		"two held step pulses must raise the stationary target by two levels"
	)
	_check(
		(stroke.get("cells", PackedVector2Array()) as PackedVector2Array).size() == 1,
		"repeated hold pulses must remain one compact undo stroke"
	)


## Verify every visible stepped and smooth action accepts repeated held pulses.
func _test_all_sculpt_actions_repeat() -> void:
	var repeated_modes: Array[int] = [
		TerrainSculptor.Mode.STEP_UP,
		TerrainSculptor.Mode.STEP_DOWN,
		TerrainSculptor.Mode.RAISE,
		TerrainSculptor.Mode.LOWER,
	]
	var expected_heights: Array[float] = [1.0, -1.0, 1.0, -1.0]
	for index: int in repeated_modes.size():
		var terrain := _filled_terrain(Vector2i.ONE)
		var sculptor := TerrainSculptor.new(terrain)
		var settings := TerrainSculptor.Settings.new()
		settings.mode = repeated_modes[index]
		settings.size_m = 1.0
		settings.step_m = 0.5
		settings.strength = 0.5
		sculptor.configure(settings)
		sculptor.begin_stroke()
		sculptor.stamp(Vector2(0.5, 0.5))
		sculptor.begin_pulse()
		sculptor.stamp(Vector2(0.5, 0.5))
		sculptor.finish_stroke()
		_check(
			is_equal_approx(
				terrain.cell_walk_height(Vector2i.ZERO),
				expected_heights[index]
			),
			"held sculpt mode %d must apply one deterministic effect per pulse"
				% repeated_modes[index]
		)

	var flatten_terrain := _filled_terrain(Vector2i.ONE)
	var flatten_sculptor := TerrainSculptor.new(flatten_terrain)
	var flatten_settings := TerrainSculptor.Settings.new()
	flatten_settings.mode = TerrainSculptor.Mode.FLATTEN
	flatten_settings.size_m = 1.0
	flatten_settings.strength = 0.5
	flatten_settings.flatten_target_m = 1.0
	flatten_sculptor.configure(flatten_settings)
	flatten_sculptor.begin_stroke()
	flatten_sculptor.stamp(Vector2(0.5, 0.5))
	flatten_sculptor.begin_pulse()
	flatten_sculptor.stamp(Vector2(0.5, 0.5))
	flatten_sculptor.finish_stroke()
	_check(
		is_equal_approx(flatten_terrain.cell_walk_height(Vector2i.ZERO), 0.75),
		"held smooth Flatten must keep converging once per pulse"
	)

	var step_flatten_terrain := _filled_terrain(Vector2i.ONE)
	step_flatten_terrain.set_cell_top_level(Vector2i.ZERO, 0.2)
	var step_flatten_sculptor := TerrainSculptor.new(step_flatten_terrain)
	var step_flatten_settings := TerrainSculptor.Settings.new()
	step_flatten_settings.mode = TerrainSculptor.Mode.STEP_FLATTEN
	step_flatten_settings.size_m = 1.0
	step_flatten_settings.step_m = 0.5
	step_flatten_settings.flatten_target_m = 1.0
	step_flatten_sculptor.configure(step_flatten_settings)
	step_flatten_sculptor.begin_stroke()
	step_flatten_sculptor.stamp(Vector2(0.5, 0.5))
	step_flatten_sculptor.begin_pulse()
	step_flatten_sculptor.stamp(Vector2(0.5, 0.5))
	step_flatten_sculptor.finish_stroke()
	_check(
		is_equal_approx(
			step_flatten_terrain.cell_walk_height(Vector2i.ZERO),
			1.0
		),
		"held stepped Flatten must remain on its exact visible target level"
	)

	var smooth_terrain := _filled_terrain(Vector2i(3, 3))
	smooth_terrain.set_lattice_corner_height(Vector2i(2, 2), 2.0)
	var smooth_sculptor := TerrainSculptor.new(smooth_terrain)
	var smooth_settings := TerrainSculptor.Settings.new()
	smooth_settings.mode = TerrainSculptor.Mode.SMOOTH
	smooth_settings.size_m = 1.0
	smooth_settings.strength = 0.5
	smooth_sculptor.configure(smooth_settings)
	smooth_sculptor.begin_stroke()
	smooth_sculptor.stamp(Vector2(1.5, 1.5))
	var smooth_after_click := smooth_terrain.lattice_top_height(Vector2i(2, 2))
	smooth_sculptor.begin_pulse()
	smooth_sculptor.stamp(Vector2(1.5, 1.5))
	var smooth_after_hold := smooth_terrain.lattice_top_height(Vector2i(2, 2))
	smooth_sculptor.finish_stroke()
	_check(
		smooth_after_hold < smooth_after_click,
		"held smooth Smooth must continue reducing local height noise"
	)

	var step_smooth_terrain := _filled_terrain(Vector2i(3, 1))
	step_smooth_terrain.set_cell_top_level(Vector2i(1, 0), 2.0)
	var step_smooth_sculptor := TerrainSculptor.new(step_smooth_terrain)
	var step_smooth_settings := TerrainSculptor.Settings.new()
	step_smooth_settings.mode = TerrainSculptor.Mode.STEP_SMOOTH
	step_smooth_settings.size_m = 1.0
	step_smooth_settings.step_m = 0.5
	step_smooth_sculptor.configure(step_smooth_settings)
	step_smooth_sculptor.begin_stroke()
	step_smooth_sculptor.stamp(Vector2(1.5, 0.5))
	var step_smooth_after_click := step_smooth_terrain.cell_walk_height(Vector2i(1, 0))
	step_smooth_sculptor.begin_pulse()
	step_smooth_sculptor.stamp(Vector2(1.5, 0.5))
	var step_smooth_after_hold := step_smooth_terrain.cell_walk_height(Vector2i(1, 0))
	step_smooth_sculptor.finish_stroke()
	_check(
		step_smooth_after_hold < step_smooth_after_click,
		"held stepped Smooth must continue reducing stepped height noise"
	)


## Verify a quick click applies once while a deliberate hold starts repeating later.
func _test_click_and_hold_timing() -> void:
	var click_terrain := _filled_terrain(Vector2i.ONE)
	var click_board := BoardDocument.new()
	click_board.terrain = click_terrain
	var click_viewport := MTSStudioViewport.new()
	click_viewport.board = click_board
	click_viewport._terrain_sculptor = TerrainSculptor.new(click_terrain)
	var click_settings := TerrainSculptor.Settings.new()
	click_settings.mode = TerrainSculptor.Mode.RAISE
	click_settings.size_m = 1.0
	click_settings.strength = 0.5
	click_viewport._terrain_sculptor.configure(click_settings)
	click_viewport._height_sculpting = true
	click_viewport._last_height_stamp_xz = Vector2(0.5, 0.5)
	click_viewport._terrain_sculptor.begin_stroke()
	click_viewport._apply_height_sculpt_stamp(Vector2(0.5, 0.5))
	var click_height := click_terrain.cell_walk_height(Vector2i.ZERO)
	click_viewport._advance_height_sculpt_hold(0.24)
	_check(
		is_equal_approx(click_terrain.cell_walk_height(Vector2i.ZERO), click_height),
		"a quick click must apply exactly once before the hold delay"
	)
	click_viewport._height_sculpting = false
	click_viewport._terrain_sculptor.finish_stroke()
	click_viewport.free()

	var hold_terrain := _filled_terrain(Vector2i.ONE)
	var hold_board := BoardDocument.new()
	hold_board.terrain = hold_terrain
	var hold_viewport := MTSStudioViewport.new()
	hold_viewport.board = hold_board
	hold_viewport._terrain_sculptor = TerrainSculptor.new(hold_terrain)
	var hold_settings := TerrainSculptor.Settings.new()
	hold_settings.mode = TerrainSculptor.Mode.RAISE
	hold_settings.size_m = 1.0
	hold_settings.strength = 0.5
	hold_viewport._terrain_sculptor.configure(hold_settings)
	hold_viewport._height_sculpting = true
	hold_viewport._last_height_stamp_xz = Vector2(0.5, 0.5)
	hold_viewport._terrain_sculptor.begin_stroke()
	hold_viewport._apply_height_sculpt_stamp(Vector2(0.5, 0.5))
	hold_viewport._advance_height_sculpt_hold(0.24)
	hold_viewport._height_pending_motion = true
	hold_viewport._height_pending_mouse_position = Vector2.ZERO
	hold_viewport._flush_pending_height_sculpt_motion()
	_check(
		is_equal_approx(hold_viewport._height_repeat_elapsed_seconds, 0.24),
		"queued pointer motion must not postpone a held same-cell repeat"
	)
	hold_viewport._advance_height_sculpt_hold(0.02)
	_check(
		is_equal_approx(hold_terrain.cell_walk_height(Vector2i.ZERO), 1.0),
		"a deliberate hold must add one bounded repeat after the delay"
	)
	hold_viewport._advance_height_sculpt_hold(0.05)
	_check(
		is_equal_approx(hold_terrain.cell_walk_height(Vector2i.ZERO), 1.5),
		"a continuing hold must repeatedly affect the same cell"
	)
	hold_viewport._height_sculpting = false
	hold_viewport._terrain_sculptor.finish_stroke()
	hold_viewport.free()


## Verify the derived skirt base follows the lowest terrain while depth stays authored.
func _test_dynamic_skirt_depth() -> void:
	var terrain := _filled_terrain(Vector2i(2, 1))
	terrain.skirt_depth_m = 1.25
	_check(
		is_equal_approx(terrain.skirt_base_m, -1.25),
		"flat zero terrain must derive its base from the visible skirt depth"
	)
	terrain.set_cell_top_level(Vector2i(1, 0), -2.0)
	_check(
		is_equal_approx(terrain.skirt_base_m, -3.25),
		"lowering terrain must move the derived skirt base by the same amount"
	)
	var saved := terrain.to_json()
	_check(
		saved.has("skirt_depth_m") and not saved.has("skirt_base_m"),
		"saved terrain must store depth as the one canonical skirt value"
	)


## Verify one Smooth-tool stroke reconciles paint only inside its dirty rectangle.
##
## The Smooth tool uses the continuous RAISE/LOWER/FLATTEN/SMOOTH modes. Its
## release path must never enumerate every face on the board for a local edit.
func _test_smooth_tool_scoped_reconciliation() -> void:
	var terrain := _filled_terrain(Vector2i(38, 37))
	var sculptor := TerrainSculptor.new(terrain)
	var settings := TerrainSculptor.Settings.new()
	settings.mode = TerrainSculptor.Mode.RAISE
	settings.size_m = 1.0
	settings.strength = 0.5
	sculptor.configure(settings)
	sculptor.begin_stroke()
	var dirty := sculptor.stamp(Vector2(18.5, 18.5))
	sculptor.finish_stroke()

	var board := BoardDocument.new()
	board.terrain = terrain
	var started := Time.get_ticks_usec()
	board.prune_orphaned_terrain_paint(dirty)
	var elapsed_usec := Time.get_ticks_usec() - started
	_check(
		dirty.size.x <= 5 and dirty.size.y <= 5,
		"a one-metre Smooth-tool stamp must keep one compact dirty rectangle"
	)
	_check(
		elapsed_usec < 100000,
		"Smooth-tool paint reconciliation must remain local and under 100 ms"
	)
	print("smooth scoped reconciliation: %d us for %s" % [elapsed_usec, dirty])


## Verify bounded terrain face generation stays proportional to the dirty region.
func _test_bounded_face_scope() -> void:
	var terrain := _filled_terrain(Vector2i(32, 32))
	var dirty := Rect2i(Vector2i(8, 8), Vector2i(3, 3))
	var bounded_started := Time.get_ticks_usec()
	var bounded := terrain.terrain_faces(8, dirty)
	var bounded_usec := Time.get_ticks_usec() - bounded_started
	var full_started := Time.get_ticks_usec()
	var full := terrain.terrain_faces(8)
	var full_usec := Time.get_ticks_usec() - full_started
	var grouped := MTSTerrainMeshBuilder.group_faces_by_chunk(bounded, 8)

	_check(bounded.size() == 9, "a 3x3 dirty rectangle must produce exactly nine top faces")
	var full_top_count := 0
	for face: Dictionary in full:
		if int(face["kind"]) == TerrainMesh.FaceKind.TOP:
			full_top_count += 1
	_check(full_top_count == 1024, "the full fixture exposes all 1024 top faces")
	_check(grouped.size() == 1, "a dirty rectangle inside one chunk must rebuild one chunk")
	_check(
		bounded.size() * 100 < full.size(),
		"bounded face generation must inspect less than one percent of this board"
	)
	print(
		"terrain bounded scope: %d faces/%d full, %d chunk, %d us/%d us"
		% [bounded.size(), full.size(), grouped.size(), bounded_usec, full_usec]
	)


## Return whether one rebuilt side face closes exactly the span between two heights.
##
## A wall that merely still exists is not proof the surface is intact. The tear this
## guards against is a stored profile whose endpoints no longer meet the tops it
## stands between, which draws as a floating sliver with a hole beside it.
func _seam_spans(
	terrain: TerrainMesh,
	cell: Vector2i,
	edge: int,
	bottom_m: float,
	top_m: float
) -> bool:
	var profile := terrain.side_face(cell, edge)
	if profile.size() != 6:
		return false
	return (
		is_equal_approx(float(profile[2]), bottom_m)
		and is_equal_approx(float(profile[3]), top_m)
		and is_equal_approx(float(profile[4]), bottom_m)
		and is_equal_approx(float(profile[5]), top_m)
	)


## Verify GLB contact flatten levels its pad without collapsing the wall at its edge.
##
## Both modes run on one fixture: a 3 m plateau beside flat ground, with the pad
## placed against the plateau so the wall stands on the pad's BOUNDARY. A wall
## inside a footprint is what the flatten exists to remove, so preservation is only
## ever asserted at the perimeter. Each mode must additionally leave the rebuilt
## side face reaching the ground it now stands between, which is what separates a
## real wall from the torn seam a raw corner write used to leave behind.
func _test_contact_flatten_preserves_walls() -> void:
	var stepped_terrain := _filled_terrain(Vector2i(4, 1))
	stepped_terrain.set_cell_top_level(Vector2i(0, 0), 3.0)
	_check(
		stepped_terrain.seam_carries_side_face(Vector2i(0, 0), TerrainMesh.EDGE_EAST),
		"fixture must start with a real wall on the plateau seam"
	)

	var stepped_pad: Array[Vector2i] = [Vector2i(1, 0), Vector2i(2, 0)]
	var stepped_sculptor := TerrainSculptor.new(stepped_terrain)
	stepped_sculptor.begin_stroke()
	var stepped_result := stepped_sculptor.flatten_cells(stepped_pad, 1.0)
	stepped_sculptor.finish_stroke()
	_check(
		int(stepped_result.get("flattened_cell_count", 0)) == 2,
		"the stepped pad must report both of its quads as flattened"
	)
	_check(
		stepped_terrain.cell_relief(Vector2i(1, 0)) <= TerrainMesh.LEVEL_EPSILON_M
		and stepped_terrain.cell_relief(Vector2i(2, 0)) <= TerrainMesh.LEVEL_EPSILON_M,
		"every stepped footprint quad must end completely level"
	)
	_check(
		is_equal_approx(stepped_terrain.cell_walk_height(Vector2i(0, 0)), 3.0),
		"the stepped flatten must not touch the plateau outside its footprint"
	)
	_check(
		_seam_spans(stepped_terrain, Vector2i(0, 0), TerrainMesh.EDGE_EAST, 1.0, 3.0),
		"the plateau wall must be rebuilt down to the new pad instead of tearing"
	)

	# Smooth mode shares each boundary corner with the quad outside the pad, which is
	# what produces the ramp -- except where sharing it would shorten a wall.
	var smooth_terrain := _filled_terrain(Vector2i(4, 1))
	smooth_terrain.set_cell_top_level(Vector2i(0, 0), 3.0)
	var smooth_pad: Array[Vector2i] = [Vector2i(1, 0), Vector2i(2, 0)]
	var smooth_sculptor := TerrainSculptor.new(smooth_terrain)
	smooth_sculptor.begin_stroke()
	smooth_sculptor.flatten_cells_smooth(smooth_pad, 1.0)
	smooth_sculptor.finish_stroke()
	_check(
		smooth_terrain.cell_relief(Vector2i(1, 0)) <= TerrainMesh.LEVEL_EPSILON_M
		and smooth_terrain.cell_relief(Vector2i(2, 0)) <= TerrainMesh.LEVEL_EPSILON_M,
		"smooth mode must level its pad as completely as the stepped mode does"
	)
	_check(
		is_equal_approx(smooth_terrain.cell_walk_height(Vector2i(0, 0)), 3.0),
		"the walled boundary corner must not drag the plateau down onto the pad"
	)
	_check(
		_seam_spans(smooth_terrain, Vector2i(0, 0), TerrainMesh.EDGE_EAST, 1.0, 3.0),
		"the wall smooth mode declined to share must still close the drop exactly"
	)
	_check(
		is_equal_approx(smooth_terrain.cell_corner(Vector2i(3, 0), 0), 1.0)
		and is_equal_approx(smooth_terrain.cell_corner(Vector2i(3, 0), 2), 1.0),
		"the wall-free boundary corner must be shared so the ground ramps into the pad"
	)
	_check(
		not smooth_terrain.seam_carries_side_face(Vector2i(2, 0), TerrainMesh.EDGE_EAST),
		"a shared boundary corner must leave a continuous slope, not a wall"
	)

	# A pad clear of every wall must flatten completely, so the perimeter rule can
	# never be satisfied by simply refusing to work.
	var clear_terrain := _filled_terrain(Vector2i(4, 1))
	clear_terrain.set_cell_top_level(Vector2i(0, 0), 3.0)
	var clear_pad: Array[Vector2i] = [Vector2i(2, 0), Vector2i(3, 0)]
	var clear_sculptor := TerrainSculptor.new(clear_terrain)
	clear_sculptor.begin_stroke()
	var clear_result := clear_sculptor.flatten_cells(clear_pad, 2.0)
	clear_sculptor.finish_stroke()
	_check(
		int(clear_result.get("flattened_cell_count", 0)) == 2,
		"a pad clear of every wall must flatten both of its quads"
	)
	_check(
		is_equal_approx(clear_terrain.cell_walk_height(Vector2i(2, 0)), 2.0)
		and is_equal_approx(clear_terrain.cell_walk_height(Vector2i(3, 0)), 2.0),
		"both clear quads must reach the requested contact height"
	)


## Verify a footprint-flatten stroke returns complete occupied cells to the exact zero plane.
##
## This uses the stepped cell operation because footprint flattening must move all four
## corners together, retain occupancy, rebuild real walls, and ignore smooth-brush strength.
func _test_flatten_footprint_zero_plane() -> void:
	var terrain := _filled_terrain(Vector2i(2, 1))
	terrain.set_cell_top_level(Vector2i(0, 0), 2.5)
	terrain.set_cell_top_level(Vector2i(1, 0), 1.0)
	var sculptor := TerrainSculptor.new(terrain)
	var settings := TerrainSculptor.Settings.new()
	settings.mode = TerrainSculptor.Mode.STEP_FLATTEN
	settings.size_m = 1.0
	settings.step_m = 0.5
	settings.strength = 0.01
	settings.flatten_target_m = 0.0
	sculptor.configure(settings)
	sculptor.begin_stroke()
	sculptor.stamp(Vector2(0.5, 0.5))
	sculptor.stamp(Vector2(1.5, 0.5))
	sculptor.finish_stroke()

	var zero_plane := true
	for cell: Vector2i in [Vector2i(0, 0), Vector2i(1, 0)]:
		for corner_index: int in 4:
			zero_plane = zero_plane and is_equal_approx(
				terrain.cell_corner(cell, corner_index),
				0.0,
			)
	_check(zero_plane, "flatten footprint must put every touched corner at exactly zero")
	_check(
		terrain.filled_cell_count() == 2
		and terrain.is_cell_filled(Vector2i(0, 0))
		and terrain.is_cell_filled(Vector2i(1, 0)),
		"flatten footprint must preserve every touched footprint cell",
	)
	_check(
		is_equal_approx(terrain.skirt_base_m, -terrain.skirt_depth_m),
		"the derived skirt base must follow the new zero-height terrain minimum",
	)


## Run every focused invariant and exit nonzero when any one fails.
func _run() -> void:
	_test_tapered_step_slope_wall()
	_test_crossing_step_slope_ownership()
	_test_step_then_shared_corner_slope()
	_test_footprint_removal_clears_internal_wall()
	_test_sloped_boundary_skirt_closure()
	_test_cardinal_side_winding()
	_test_thin_side_texture_seed_identity()
	_test_one_metre_step_target()
	_test_shared_footprint_targets()
	_test_near_corner_segment_traversal()
	_test_stronger_smooth_strength()
	_test_held_step_pulses()
	_test_all_sculpt_actions_repeat()
	_test_click_and_hold_timing()
	_test_dynamic_skirt_depth()
	_test_smooth_tool_scoped_reconciliation()
	_test_bounded_face_scope()
	_test_contact_flatten_preserves_walls()
	_test_flatten_footprint_zero_plane()
	print("terrain_heightfield_check: %d failures" % failures)
	quit(failures)
