@tool
extends SceneTree

## Arithmetic checks for the grid-first sizing and variant posing.
##
## These are the calculations every derived artefact depends on, and they are
## pure functions of numbers, so they can be verified without rendering
## anything. If these are wrong, every voxel set and every PNG is wrong too.
##
## Run:
##   godot --headless --path . --script tools/test_grid_sizing.gd

const K := preload("res://addons/modular_tile_studio/utils/mts_constants.gd")
const Canonicalizer := preload("res://addons/modular_tile_studio/importers/glb_canonicalizer.gd")

var _passed := 0
var _failed := 0


func _init() -> void:
	var c := Canonicalizer.new()

	_heading("Spec worked example: 18.6 x 10 x 7.4, height 5, proportional")

	var plan := c.compute_grid_plan(
		Vector3(18.6, 10.0, 7.4),
		Vector3i(1, 5, 1),
		1,
		false
	)

	_eq_v3i("grid box", plan["grid_size"], Vector3i(10, 5, 4))
	_near_v3("actual mesh", plan["actual_size"], Vector3(9.3, 5.0, 3.7))
	_near_v3("uniform scale", plan["scale"], Vector3(0.5, 0.5, 0.5))

	_heading("Same model, stretch to the same box")

	var stretched := c.compute_grid_plan(
		Vector3(18.6, 10.0, 7.4),
		Vector3i(10, 5, 4),
		1,
		true
	)

	_eq_v3i("grid box", stretched["grid_size"], Vector3i(10, 5, 4))
	_near_v3("actual mesh fills box", stretched["actual_size"], Vector3(10.0, 5.0, 4.0))

	_heading("Driver axis is exact by definition")

	for axis in [0, 1, 2]:
		var driven := c.compute_grid_plan(
			Vector3(3.3, 7.1, 2.4),
			Vector3i(6, 6, 6),
			axis,
			false
		)
		var grid: Vector3i = driven["grid_size"]
		_check("axis %d lands on 6" % axis, grid[axis] == 6)

	_heading("Complete prop orientation: every facing and roll preserves volume")

	var canonical_box := Vector3i(10, 5, 4)
	_eq_v3i(
		"upright north box",
		K.oriented_prop_grid_bounds(canonical_box, K.Face.NEG_Z, 0),
		Vector3i(10, 5, 4)
	)
	_eq_v3i(
		"upright east box",
		K.oriented_prop_grid_bounds(canonical_box, K.Face.POS_X, 0),
		Vector3i(4, 5, 10)
	)
	for forward_face: int in K.FACE_NORMALS:
		for roll_quarters in 4:
			var oriented_box := K.oriented_prop_grid_bounds(
				canonical_box,
				forward_face,
				roll_quarters
			)
			_check(
				"%s roll %d preserves volume" % [K.face_name(forward_face), roll_quarters],
				oriented_box.x * oriented_box.y * oriented_box.z
				== canonical_box.x * canonical_box.y * canonical_box.z
			)

	_heading("NORTH pose: centred in X/Z, bottom-aligned in Y")

	# A raw mesh sitting somewhere arbitrary in its own space.
	var raw := AABB(Vector3(-9.3, 2.0, 4.0), Vector3(18.6, 10.0, 7.4))
	var box := Vector3i(10, 5, 4)

	var pose := c.compute_pose(
		raw,
		Vector3(0.5, 0.5, 0.5),
		box
	)

	var actual: Vector3 = pose["actual_size"]
	var offset: Vector3 = pose["mesh_offset"]

	# The mesh must sit exactly on the box floor.
	_check("bottom aligned (Y offset 0)", absf(offset.y) < 0.0001)

	# And be centred horizontally: equal slack on both sides.
	var slack_x := float(box.x) - actual.x
	var slack_z := float(box.z) - actual.z
	_check("centred in X", absf(offset.x - slack_x * 0.5) < 0.0001)
	_check("centred in Z", absf(offset.z - slack_z * 0.5) < 0.0001)

	# The mesh must fit inside the integer box it claims.
	_check("fits box in X", actual.x <= float(box.x) + 0.0001)
	_check("fits box in Y", actual.y <= float(box.y) + 0.0001)
	_check("fits box in Z", actual.z <= float(box.z) + 0.0001)

	# The transform must actually put the mesh where the pose claims.
	var placed: AABB = (pose["transform"] as Transform3D) * raw
	_check("transform lands on offset", placed.position.is_equal_approx(offset))

	_heading("Grid bounds never collapse below one cell")

	_eq_v3i(
		"tiny model still claims a cell",
		c.suggest_grid_bounds(Vector3(0.01, 0.01, 0.01)),
		Vector3i(1, 1, 1)
	)

	# A size already on a whole metre must not be rounded up to the next cell.
	_eq_v3i(
		"exact metres do not over-claim",
		c.suggest_grid_bounds(Vector3(4.0, 3.0, 2.0)),
		Vector3i(4, 3, 2)
	)

	print("\n=====================================")
	print("  %d passed, %d failed" % [_passed, _failed])
	print("=====================================")

	quit(0 if _failed == 0 else 1)


func _heading(text: String) -> void:
	print("\n--- %s" % text)


func _check(label: String, ok: bool) -> void:
	if ok:
		_passed += 1
		print("  PASS  %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s" % label)


func _eq_v3i(label: String, got: Vector3i, want: Vector3i) -> void:
	_check("%s: got %v, want %v" % [label, got, want], got == want)


func _near_v3(label: String, got: Vector3, want: Vector3) -> void:
	var ok := (
		absf(got.x - want.x) < 0.001
		and absf(got.y - want.y) < 0.001
		and absf(got.z - want.z) < 0.001
	)
	_check("%s: got %v, want %v" % [label, got, want], ok)
