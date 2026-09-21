@tool
class_name ProxyGenerator
extends RefCounted

## Direct 1 m voxelization of the FINAL transformed source GLB.
##
## No persistent intermediate mesh representation exists.
##
## The exact same transform passed here is what places the real mesh at runtime.

const EMPTY: int = 0
const SURFACE: int = 1
const OUTSIDE: int = 2

const BOX_HALF := Vector3(
	0.5001,
	0.5001,
	0.5001
)

const NEIGHBOURS: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),

	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),

	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

# Box separating axes for the SAT test below. Hoisted to a constant because
# _triangle_intersects_cell runs once per (triangle, candidate cell) pair --
# for a multi-million-face import that is millions of calls, and rebuilding
# this same 3-element Vector3 array on every call was pure allocation churn.
const BOX_AXES: Array[Vector3] = [
	Vector3(1, 0, 0),
	Vector3(0, 1, 0),
	Vector3(0, 0, 1),
]


## Return every occupied 1 m voxel.
##
## Surface voxels come from exact triangle/AABB overlap tests.
## Empty cells enclosed by the surface are filled by an exterior flood.
##
## For an open source mesh the flood reaches the interior, leaving the surface
## shell solid instead of inventing a sealed volume.
func voxelize(
	model: Node3D,
	model_transform: Transform3D,
	grid_bounds: Vector3i
) -> Array[Vector3i]:
	var report := voxelize_report(model, model_transform, grid_bounds)
	var voxels: Array[Vector3i] = []
	voxels.assign(report.get("voxels", []))
	return voxels


## Return raw occupied voxels together with each cell's share of source triangles.
##
## The percentage is the number of source triangles intersecting one cell divided
## by the source model's total triangle count. A triangle may intersect more than
## one cell, so these percentages are independent evidence values and are not
## expected to sum to 100. Enclosed flood-filled cells have a zero-percent share.
func voxelize_report(
	model: Node3D,
	model_transform: Transform3D,
	grid_bounds: Vector3i
) -> Dictionary:

	var grid := Vector3i(
		maxi(1, grid_bounds.x),
		maxi(1, grid_bounds.y),
		maxi(1, grid_bounds.z)
	)

	var state := PackedByteArray()

	state.resize(
		grid.x
		* grid.y
		* grid.z
	)
	var triangle_hits := PackedInt32Array()
	triangle_hits.resize(state.size())

	var triangle_count := _mark_node_triangles(
		model,
		model_transform,
		state,
		triangle_hits,
		grid
	)

	_flood_exterior(
		state,
		grid
	)

	var out: Array[Vector3i] = []
	var triangle_shares_percent := PackedFloat32Array()

	for z in grid.z:
		for y in grid.y:
			for x in grid.x:
				var cell := Vector3i(
					x,
					y,
					z
				)

				# Anything not reached from outside is either:
				#
				# SURFACE
				# or enclosed interior.
				var cell_index := _index(cell, grid)
				if state[cell_index] != OUTSIDE:

					out.append(cell)
					triangle_shares_percent.append(
						100.0 * float(triangle_hits[cell_index]) / float(triangle_count)
						if triangle_count > 0
						else 0.0
					)

	return {
		"voxels": out,
		"triangle_shares_percent": triangle_shares_percent,
		"triangle_count": triangle_count,
	}


## Mark every transformed mesh triangle and return the model's total triangle count.
func _mark_node_triangles(
	node: Node,
	parent_transform: Transform3D,
	state: PackedByteArray,
	triangle_hits: PackedInt32Array,
	grid: Vector3i
) -> int:

	var current := parent_transform
	var triangle_count := 0

	var node_3d := node as Node3D

	if node_3d != null:
		current = (
			parent_transform
			* node_3d.transform
		)

	var instance := node as MeshInstance3D

	if (
		instance != null
		and instance.mesh != null
	):
		var mesh := instance.mesh

		for surface_index in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(
				surface_index
			)

			if arrays.is_empty():
				continue

			var vertices: PackedVector3Array = arrays[
				Mesh.ARRAY_VERTEX
			]

			var indices := PackedInt32Array()
			var index_data: Variant = arrays[Mesh.ARRAY_INDEX]
			if index_data is PackedInt32Array:
				indices = index_data as PackedInt32Array

			if indices.is_empty():
				for i in range(
					0,
					vertices.size() - 2,
					3
				):
					triangle_count += 1
					_mark_triangle(
						current * vertices[i],
						current * vertices[i + 1],
						current * vertices[i + 2],
						state,
						triangle_hits,
						grid
					)

			else:
				for i in range(
					0,
					indices.size() - 2,
					3
				):
					triangle_count += 1
					_mark_triangle(
						current * vertices[
							indices[i]
						],
						current * vertices[
							indices[i + 1]
						],
						current * vertices[
							indices[i + 2]
						],
						state,
						triangle_hits,
						grid
					)

	for child in node.get_children():
		triangle_count += _mark_node_triangles(
			child,
			current,
			state,
			triangle_hits,
			grid
		)
	return triangle_count


## Mark every cell touched by one triangle and increment that cell's evidence count.
func _mark_triangle(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	state: PackedByteArray,
	triangle_hits: PackedInt32Array,
	grid: Vector3i
) -> void:

	var tri_min := Vector3(
		minf(
			a.x,
			minf(b.x, c.x)
		),
		minf(
			a.y,
			minf(b.y, c.y)
		),
		minf(
			a.z,
			minf(b.z, c.z)
		)
	)

	var tri_max := Vector3(
		maxf(
			a.x,
			maxf(b.x, c.x)
		),
		maxf(
			a.y,
			maxf(b.y, c.y)
		),
		maxf(
			a.z,
			maxf(b.z, c.z)
		)
	)

	var min_cell := Vector3i(
		clampi(
			floori(tri_min.x),
			0,
			grid.x - 1
		),
		clampi(
			floori(tri_min.y),
			0,
			grid.y - 1
		),
		clampi(
			floori(tri_min.z),
			0,
			grid.z - 1
		)
	)

	var max_cell := Vector3i(
		clampi(
			floori(tri_max.x),
			0,
			grid.x - 1
		),
		clampi(
			floori(tri_max.y),
			0,
			grid.y - 1
		),
		clampi(
			floori(tri_max.z),
			0,
			grid.z - 1
		)
	)

	for z in range(
		min_cell.z,
		max_cell.z + 1
	):
		for y in range(
			min_cell.y,
			max_cell.y + 1
		):
			for x in range(
				min_cell.x,
				max_cell.x + 1
			):
				var cell := Vector3i(
					x,
					y,
					z
				)

				if _triangle_intersects_cell(
					a,
					b,
					c,
					cell
				):
					var cell_index := _index(cell, grid)
					state[cell_index] = SURFACE
					triangle_hits[cell_index] += 1


## Triangle/AABB separating-axis test.
##
## Cheapest rejections run first: the three box-axis tests below are a plain
## min/max compare with no cross product, and reject the large majority of
## candidate cells (anything whose AABB overlaps the cell but the triangle
## itself does not reach) before paying for the 9 edge-cross-axis tests or the
## triangle-plane test, each of which needs a Vector3.cross(). For a
## multi-million-face import this ordering is the difference between millions
## of cheap dot products and millions of cross products.
func _triangle_intersects_cell(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	cell: Vector3i
) -> bool:

	var centre := (
		Vector3(cell)
		+ Vector3(
			0.5,
			0.5,
			0.5
		)
	)

	var v0 := a - centre
	var v1 := b - centre
	var v2 := c - centre

	# Box X/Y/Z axes.
	if (
		maxf(
			v0.x,
			maxf(v1.x, v2.x)
		) < -BOX_HALF.x
		or
		minf(
			v0.x,
			minf(v1.x, v2.x)
		) > BOX_HALF.x
	):
		return false

	if (
		maxf(
			v0.y,
			maxf(v1.y, v2.y)
		) < -BOX_HALF.y
		or
		minf(
			v0.y,
			minf(v1.y, v2.y)
		) > BOX_HALF.y
	):
		return false

	if (
		maxf(
			v0.z,
			maxf(v1.z, v2.z)
		) < -BOX_HALF.z
		or
		minf(
			v0.z,
			minf(v1.z, v2.z)
		) > BOX_HALF.z
	):
		return false

	var e0 := v1 - v0
	var e1 := v2 - v1
	var e2 := v0 - v2

	# Triangle plane.
	var normal := e0.cross(
		e1
	)

	if not _axis_overlap(
		normal,
		v0,
		v1,
		v2
	):
		return false

	# 9 edge x box-axis SAT axes. BOX_AXES is a hoisted constant -- see its
	# declaration -- and edges are indexed directly rather than boxed into a
	# throwaway Array, since this loop runs 9 times per surviving candidate.
	for box_axis in BOX_AXES:
		if not _axis_overlap(e0.cross(box_axis), v0, v1, v2):
			return false
		if not _axis_overlap(e1.cross(box_axis), v0, v1, v2):
			return false
		if not _axis_overlap(e2.cross(box_axis), v0, v1, v2):
			return false

	return true


func _axis_overlap(
	axis: Vector3,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3
) -> bool:

	if axis.length_squared() < 0.0000000001:
		return true

	var p0 := v0.dot(axis)
	var p1 := v1.dot(axis)
	var p2 := v2.dot(axis)

	var minimum := minf(
		p0,
		minf(p1, p2)
	)

	var maximum := maxf(
		p0,
		maxf(p1, p2)
	)

	var radius := (
		BOX_HALF.x * absf(axis.x)
		+ BOX_HALF.y * absf(axis.y)
		+ BOX_HALF.z * absf(axis.z)
	)

	return not (
		minimum > radius
		or maximum < -radius
	)


func _flood_exterior(
	state: PackedByteArray,
	grid: Vector3i
) -> void:

	var queue: Array[Vector3i] = []

	for z in grid.z:
		for y in grid.y:
			_enqueue(
				Vector3i(0, y, z),
				state,
				grid,
				queue
			)

			_enqueue(
				Vector3i(
					grid.x - 1,
					y,
					z
				),
				state,
				grid,
				queue
			)

	for x in grid.x:
		for z in grid.z:
			_enqueue(
				Vector3i(x, 0, z),
				state,
				grid,
				queue
			)

			_enqueue(
				Vector3i(
					x,
					grid.y - 1,
					z
				),
				state,
				grid,
				queue
			)

	for x in grid.x:
		for y in grid.y:
			_enqueue(
				Vector3i(x, y, 0),
				state,
				grid,
				queue
			)

			_enqueue(
				Vector3i(
					x,
					y,
					grid.z - 1
				),
				state,
				grid,
				queue
			)

	var head := 0

	while head < queue.size():
		var cell := queue[head]
		head += 1

		for direction in NEIGHBOURS:
			var next := (
				cell
				+ direction
			)

			if (
				next.x < 0
				or next.y < 0
				or next.z < 0
				or next.x >= grid.x
				or next.y >= grid.y
				or next.z >= grid.z
			):
				continue

			_enqueue(
				next,
				state,
				grid,
				queue
			)


func _enqueue(
	cell: Vector3i,
	state: PackedByteArray,
	grid: Vector3i,
	queue: Array[Vector3i]
) -> void:

	var index := _index(
		cell,
		grid
	)

	if state[index] != EMPTY:
		return

	state[index] = OUTSIDE

	queue.append(cell)


static func _index(
	cell: Vector3i,
	grid: Vector3i
) -> int:

	return (
		cell.x
		+ grid.x * (
			cell.y
			+ grid.y * cell.z
		)
	)
