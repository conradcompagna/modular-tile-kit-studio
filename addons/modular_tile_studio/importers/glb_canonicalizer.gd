@tool
class_name GLBCanonicalizer
extends RefCounted

const K := preload("../utils/mts_constants.gd")


## Bounds of the raw imported GLB in the GLB root's local coordinate system.
##
## Accumulates the COMPLETE nested transform hierarchy instead of depending on
## global_transform being valid before the imported tree enters a SceneTree.
func compute_bounds(root: Node3D) -> AABB:
	var result := {
		"found": false,
		"bounds": AABB(),
	}

	_accumulate_bounds(
		root,
		Transform3D.IDENTITY,
		result
	)

	if not bool(result["found"]):
		return AABB(
			Vector3.ZERO,
			Vector3.ONE
		)

	return result["bounds"]


func _accumulate_bounds(
	node: Node,
	parent_transform: Transform3D,
	result: Dictionary
) -> void:

	var current := parent_transform

	var node_3d := node as Node3D

	if node_3d != null:
		current = (
			parent_transform
			* node_3d.transform
		)

	var mesh_instance := node as MeshInstance3D

	if (
		mesh_instance != null
		and mesh_instance.mesh != null
	):
		var bounds := (
			current
			* mesh_instance.mesh.get_aabb()
		)

		if not bool(result["found"]):
			result["bounds"] = bounds
			result["found"] = true
		else:
			result["bounds"] = (
				(result["bounds"] as AABB)
				.merge(bounds)
			)

	for child in node.get_children():
		_accumulate_bounds(
			child,
			current,
			result
		)


## Grid-first sizing.
##
## PROPORTIONAL:
##
## User changes one integer grid dimension.
## That axis drives one uniform scale factor.
## Other actual dimensions follow the original proportions.
## Their grid dimensions are ceil(actual dimensions).
##
## Example:
##
## original 18.6 x 10 x 7.4
## requested Y = 5
##
## actual = 9.3 x 5 x 3.7
## grid   = 10  x 5 x 4
##
## STRETCH:
##
## All three grid dimensions become exact visual dimensions.
func compute_grid_plan(
	original_size: Vector3,
	requested_grid: Vector3i,
	driver_axis: int,
	stretch_to_grid: bool
) -> Dictionary:

	var safe := Vector3(
		maxf(original_size.x, 0.00001),
		maxf(original_size.y, 0.00001),
		maxf(original_size.z, 0.00001)
	)

	var requested := Vector3i(
		maxi(1, requested_grid.x),
		maxi(1, requested_grid.y),
		maxi(1, requested_grid.z)
	)

	driver_axis = clampi(
		driver_axis,
		0,
		2
	)

	if stretch_to_grid:
		var exact := Vector3(
			requested.x,
			requested.y,
			requested.z
		)

		var stretch_scale := Vector3(
			exact.x / safe.x,
			exact.y / safe.y,
			exact.z / safe.z
		)

		return {
			"grid_size": requested,
			"actual_size": exact,
			"scale": stretch_scale,
			"driver_axis": driver_axis,
			"stretch_to_grid": true,
		}

	var target_axis_size := float(
		requested[driver_axis]
	)

	var factor := (
		target_axis_size
		/ safe[driver_axis]
	)

	var actual := (
		safe
		* factor
	)

	var grid := suggest_grid_bounds(
		actual
	)

	# The driver axis is exact by definition.
	grid[driver_axis] = requested[driver_axis]

	return {
		"grid_size": grid,
		"actual_size": actual,
		"scale": Vector3(
			factor,
			factor,
			factor
		),
		"driver_axis": driver_axis,
		"stretch_to_grid": false,
	}


func suggest_grid_bounds(
	actual_size: Vector3
) -> Vector3i:

	return Vector3i(
		maxi(
			1,
			ceili(actual_size.x - 0.001)
		),
		maxi(
			1,
			ceili(actual_size.y - 0.001)
		),
		maxi(
			1,
			ceili(actual_size.z - 0.001)
		)
	)


## Transform the raw GLB into the canonical pose used for voxelization.
##
## Resulting mesh:
##
##   - actual geometry horizontally centred inside grid_bounds
##   - bottom aligned to Y=0
##
## No placement rotation occurs here. PropPlacement applies its complete cube
## orientation to this same canonical pose at placement time, rather than
## creating separate pre-rotated artifacts.
func compute_pose(
	raw_bounds: AABB,
	scale: Vector3,
	grid_bounds: Vector3i
) -> Dictionary:

	var scaled_basis := Basis.IDENTITY.scaled(scale)

	var raw_transform := Transform3D(
		scaled_basis,
		Vector3.ZERO
	)

	var transformed_bounds := (
		raw_transform
		* raw_bounds
	)

	var actual_size := transformed_bounds.size

	var mesh_offset := Vector3(
		(
			float(grid_bounds.x)
			- actual_size.x
		) * 0.5,
		0.0,
		(
			float(grid_bounds.z)
			- actual_size.z
		) * 0.5
	)

	# Move the transformed AABB minimum to mesh_offset.
	var translation := (
		mesh_offset
		- transformed_bounds.position
	)

	var final_transform := Transform3D(
		scaled_basis,
		translation
	)

	return {
		"transform": final_transform,
		"actual_size": actual_size,
		"mesh_offset": mesh_offset,
		"bounds": AABB(
			mesh_offset,
			actual_size
		),
	}
