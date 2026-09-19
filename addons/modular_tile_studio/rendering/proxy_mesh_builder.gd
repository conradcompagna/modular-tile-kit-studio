@tool
class_name MTSProxyMeshBuilder
extends RefCounted

## Build an invisible triangle mesh from stored 1 m voxels.
##
## This mesh is ephemeral runtime/editor geometry.
## It is NOT canonical asset data.

static func voxel_mesh(
	voxels: Array[Vector3i]
) -> ArrayMesh:

	var vertices := PackedVector3Array()

	for cell in voxels:
		_append_cube(
			vertices,
			Vector3(cell)
		)

	var arrays := []
	arrays.resize(
		Mesh.ARRAY_MAX
	)

	arrays[Mesh.ARRAY_VERTEX] = (
		vertices
	)

	var mesh := ArrayMesh.new()

	if not vertices.is_empty():
		mesh.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES,
			arrays
		)

	return mesh


## Build line contours around every exact collision voxel.
##
## Placement previews use these same cells for validation, collision, and picking,
## so diagonal GLB rotations reveal their complete snapped footprint before paint.
static func voxel_outline_mesh(
	voxels: Array[Vector3i],
	expansion: float = 0.015
) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var edge_indices := PackedInt32Array([
		0, 1, 0, 2, 0, 4,
		1, 3, 1, 5,
		2, 3, 2, 6,
		3, 7,
		4, 5, 4, 6,
		5, 7,
		6, 7,
	])
	for cell: Vector3i in voxels:
		var minimum := Vector3(cell) - Vector3.ONE * expansion
		var maximum := Vector3(cell) + Vector3.ONE * (1.0 + expansion)
		var corners := PackedVector3Array([
			Vector3(minimum.x, minimum.y, minimum.z),
			Vector3(maximum.x, minimum.y, minimum.z),
			Vector3(minimum.x, maximum.y, minimum.z),
			Vector3(maximum.x, maximum.y, minimum.z),
			Vector3(minimum.x, minimum.y, maximum.z),
			Vector3(maximum.x, minimum.y, maximum.z),
			Vector3(minimum.x, maximum.y, maximum.z),
			Vector3(maximum.x, maximum.y, maximum.z),
		])
		for corner_index: int in edge_indices:
			vertices.append(corners[corner_index])

	var outline := ArrayMesh.new()
	if vertices.is_empty():
		return outline
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	outline.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return outline


## Build the single collision-derived preview pair used by placement and selection.
##
## Both meshes consume the identical voxel array so translucent volume, crisp
## contours, validation, collision, and picking can never describe different shapes.
static func collision_preview_meshes(voxels: Array[Vector3i]) -> Dictionary:
	return {
		"volume": voxel_mesh(voxels),
		"contours": voxel_outline_mesh(voxels),
	}


## Build the twelve expanded box edges used to make blockout corners explicit.
##
## The tiny expansion is local display geometry only; the authored minimum corner,
## dimensions, collision, and placement data remain unchanged.
static func box_outline_mesh(size: Vector3, expansion: float = 0.015) -> ArrayMesh:
	var minimum := Vector3.ONE * -expansion
	var maximum := size + Vector3.ONE * expansion
	var corners := PackedVector3Array([
		Vector3(minimum.x, minimum.y, minimum.z),
		Vector3(maximum.x, minimum.y, minimum.z),
		Vector3(minimum.x, maximum.y, minimum.z),
		Vector3(maximum.x, maximum.y, minimum.z),
		Vector3(minimum.x, minimum.y, maximum.z),
		Vector3(maximum.x, minimum.y, maximum.z),
		Vector3(minimum.x, maximum.y, maximum.z),
		Vector3(maximum.x, maximum.y, maximum.z),
	])
	var edge_indices := PackedInt32Array([
		0, 1, 0, 2, 0, 4,
		1, 3, 1, 5,
		2, 3, 2, 6,
		3, 7,
		4, 5, 4, 6,
		5, 7,
		6, 7,
	])
	var vertices := PackedVector3Array()
	for corner_index: int in edge_indices:
		vertices.append(corners[corner_index])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var outline := ArrayMesh.new()
	outline.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return outline


## Append one unit cube's outward triangles at the supplied minimum corner.
static func _append_cube(
	out: PackedVector3Array,
	p: Vector3
) -> void:

	var p000 := p + Vector3(0, 0, 0)
	var p100 := p + Vector3(1, 0, 0)
	var p010 := p + Vector3(0, 1, 0)
	var p110 := p + Vector3(1, 1, 0)

	var p001 := p + Vector3(0, 0, 1)
	var p101 := p + Vector3(1, 0, 1)
	var p011 := p + Vector3(0, 1, 1)
	var p111 := p + Vector3(1, 1, 1)


	_quad(
		out,
		p000,
		p010,
		p110,
		p100
	)

	_quad(
		out,
		p101,
		p111,
		p011,
		p001
	)

	_quad(
		out,
		p001,
		p011,
		p010,
		p000
	)

	_quad(
		out,
		p100,
		p110,
		p111,
		p101
	)

	_quad(
		out,
		p010,
		p011,
		p111,
		p110
	)

	_quad(
		out,
		p001,
		p000,
		p100,
		p101
	)


## Append one consistently wound quad as two triangles.
static func _quad(
	out: PackedVector3Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3
) -> void:

	out.append(a)
	out.append(b)
	out.append(c)

	out.append(a)
	out.append(c)
	out.append(d)
