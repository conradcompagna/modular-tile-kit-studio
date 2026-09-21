extends SceneTree

var constants_script: Script
var tile_asset_script: Script
var prop_placement_script: Script

var failures: int = 0


## Start the focused diagonal occupancy regression after scripts are available.
func _init() -> void:
	constants_script = load("res://addons/modular_tile_studio/utils/mts_constants.gd") as Script
	tile_asset_script = load("res://addons/modular_tile_studio/data/tile_asset.gd") as Script
	prop_placement_script = load("res://addons/modular_tile_studio/data/prop_placement.gd") as Script
	call_deferred("_run_checks")


## Record one assertion with a precise failure message.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error("DIAGONAL VOXEL CHECK FAILED: %s" % message)


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


## Verify one 45-degree scan maps exactly and missing scans remain explicit errors.
func _run_checks() -> void:
	var K: Variant = constants_script
	var asset: TileAsset = tile_asset_script.new()
	asset.asset_id = "DIAGONAL_SCAN"
	asset.source_type = K.SourceType.GLB_PROP
	asset.grid_bounds = Vector3i(2, 2, 1)
	asset.prop_voxels = [Vector3i.ZERO]
	# The asymmetry catches a correct voxel count translated into the wrong corner.
	asset.prop_voxels_diagonal = [
		Vector3i(1, 0, 0),
		Vector3i(2, 0, 0),
		Vector3i(0, 0, 1),
	]

	var diagonal_bounds: Vector3i = K.diagonal_scan_bounds(asset.grid_bounds)
	var canonical_centre: Vector3 = Vector3(asset.grid_bounds) * 0.5
	var diagonal_transform: Transform3D = K.prop_box_transform(
		asset.grid_bounds,
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

	var expected_by_yaw: Dictionary = {
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
		var placement: PropPlacement = prop_placement_script.create(
			asset.asset_id,
			Vector3i.ZERO,
			K.Face.NEG_Z,
			0,
			yaw_eighths
		)
		var expected: Array[Vector3i] = []
		expected.assign(expected_by_yaw[yaw_eighths])
		_check_voxel_set(
			placement.oriented_voxels(asset),
			expected,
			"one 45-degree scan should rotate exactly into yaw %d" % yaw_eighths
		)

	var missing_scan_asset: TileAsset = tile_asset_script.new()
	missing_scan_asset.asset_id = "MISSING_DIAGONAL_SCAN"
	missing_scan_asset.source_type = K.SourceType.GLB_PROP
	missing_scan_asset.grid_bounds = Vector3i(2, 2, 1)
	missing_scan_asset.prop_voxels = [Vector3i.ZERO]
	var missing_scan_placement: PropPlacement = prop_placement_script.create(
		missing_scan_asset.asset_id,
		Vector3i.ZERO,
		K.Face.NEG_Z,
		0,
		1
	)
	_check(
		missing_scan_placement.voxel_scan_error(missing_scan_asset).contains(
			"no 45-degree voxel scan"
		),
		"a missing diagonal scan should be rejected instead of inflating canonical voxels"
	)

	print("diagonal_prop_voxel_check: %d failures" % failures)
	quit(failures)
