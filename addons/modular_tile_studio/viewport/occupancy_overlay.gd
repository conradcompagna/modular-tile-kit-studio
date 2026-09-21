@tool
class_name MTSOccupancyOverlay
extends Node3D

## Editor-only visualisation of the board's SPATIAL truth (spec 34-37).
##
## The impostor cards and surface quads show appearance; this shows what the
## board actually claims. Those two are derived from different data and can
## silently disagree -- a prop whose voxel scan missed its base, a floor that
## reads as walkable but has a wall standing on it -- and without a way to look
## at the occupancy directly the only symptom is a game that plays wrong much
## later.
##
## Everything here is drawn from BoardDocument and the assets' occupancy arrays.
## Nothing is cached and nothing is written back: this is a read-only view, so it
## can never become a second source of truth about the board.

const K := preload("../utils/mts_constants.gd")

## What the overlay draws. OFF is the default: the overlay is a diagnostic, not
## part of the normal authoring view.
## A prop voxel either is part of the object or it is not. The old
## SOLID/OCCLUDER/VISUAL split described three volumes that could disagree
## with each other and with the artwork; there is now one set, measured
## from the mesh that was rendered.
enum Mode { OFF, SOLID, MOVEMENT_GRID }

## Colours are keyed to meaning, not to prettiness -- red reads as "blocked"
## at a glance, which is the judgement this view exists to support.
const COLOR_SOLID := Color(0.95, 0.30, 0.30, 0.42)
const COLOR_WALKABLE := Color(0.35, 0.95, 0.55, 0.40)
const COLOR_BLOCKED_FLOOR := Color(0.95, 0.45, 0.20, 0.40)
const COLOR_MANUALLY_UNWALKABLE := Color(0.95, 0.16, 0.22, 0.50)
const COLOR_GROUND_EFFECT := Color(0.16, 0.70, 0.95, 0.46)

var board: BoardDocument
var library: AssetLibrary

var mode: int = Mode.OFF

## Lifted just off the surfaces they annotate so the overlay never z-fights with
## the art it is drawn over.
const SURFACE_LIFT: float = 0.012

## Vertical relief across one cell beyond which a token cannot stand.
##
## Terrain is continuous, so "walkable" is a slope judgement rather than a
## question of whether a floor was painted. This threshold is the one place that
## judgement is made, and it is shown in the visible Movement Grid panel.
const MAX_WALKABLE_RELIEF_M: float = 0.6

var _mesh: MeshInstance3D
var _material: StandardMaterial3D
var _wire_mesh: MeshInstance3D
var _wire_material: StandardMaterial3D
var _wire_verts := PackedVector3Array()
var _wire_colors := PackedColorArray()


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Back faces culled, unlike the old flat-patch overlay which had to draw
	# both sides of every tile. The volumes are closed shells, so a back face is
	# always the inside of the far wall of the same prop: drawing it doubles the
	# alpha of every silhouette and makes a hollow shape look filled. Culling it
	# is what lets the shell read as a form with a near and a far side. Faces are
	# wound counter-clockwise seen from outside by _voxel_face_corners.
	_material.cull_mode = BaseMaterial3D.CULL_BACK
	# Vertex colours carry the per-cell classification, so one draw covers every
	# category rather than needing a material per class.
	_material.vertex_color_use_as_albedo = true
	# No depth write: the overlay is an annotation layer, and writing depth would
	# make it occlude the very geometry the user is trying to read it against.
	_material.no_depth_test = false
	_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	_mesh = MeshInstance3D.new()
	_mesh.name = "OccupancyMesh"
	_mesh.material_override = _material
	# Editor chrome: reference overlay, never a shadow caster.
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)

	# Cell edges, drawn as lines over the translucent shell.
	#
	# Without them a culled volume is a smooth silhouette with no indication of
	# where one voxel ends and the next begins -- correct as an outline, but it
	# no longer answers "how many cells tall is this?". The wireframe restores
	# the per-cell reading that insetting each cube used to provide, without
	# breaking the volume apart to do it.
	_wire_material = StandardMaterial3D.new()
	_wire_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_wire_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_wire_material.vertex_color_use_as_albedo = true
	_wire_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	_wire_mesh = MeshInstance3D.new()
	_wire_mesh.name = "OccupancyWireframe"
	_wire_mesh.material_override = _wire_material
	_wire_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_wire_mesh)
	visible = false


func set_mode(p_mode: int) -> void:
	mode = p_mode
	visible = mode != Mode.OFF
	rebuild()


func mode_name() -> String:
	match mode:
		Mode.SOLID:
			return "SOLID"
		Mode.MOVEMENT_GRID:
			return "MOVEMENT_GRID"
	return "OFF"


## Redraw from the document. Called whenever the board mutates; at MVP scale the
## whole overlay rebuilds faster than tracking deltas would cost to maintain.
func rebuild() -> void:
	if _mesh == null:
		return
	if mode == Mode.OFF or board == null or library == null:
		_mesh.mesh = null
		return

	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	# Collected alongside the triangles rather than in a second pass: the edges
	# to draw are exactly the edges of the faces that survived culling, so
	# deriving them anywhere else would mean redoing the culling to find them.
	_wire_verts = PackedVector3Array()
	_wire_colors = PackedColorArray()

	if mode == Mode.SOLID:
		_build_prop_voxels(verts, colors)
	if mode == Mode.MOVEMENT_GRID:
		_build_surface_faces(verts, colors)
	if mode == Mode.MOVEMENT_GRID:
		# The floor tiles say WHERE movement is blocked; the blocking volumes
		# say WHAT blocks it and how far up. Drawn as edges only, so the
		# walkability colours underneath stay readable -- a filled shell over
		# the floor would hide the very tiles this mode exists to show. Without
		# this a prop standing on a cell that carries no floor surface leaves no
		# mark at all, and the mode silently under-reports what is blocked.
		_build_blocker_outlines()

	_mesh.mesh = _surface_mesh(Mesh.PRIMITIVE_TRIANGLES, verts, colors)
	_wire_mesh.mesh = _surface_mesh(Mesh.PRIMITIVE_LINES, _wire_verts, _wire_colors)
	_wire_verts = PackedVector3Array()
	_wire_colors = PackedColorArray()


func _surface_mesh(primitive: int, verts: PackedVector3Array, colors: PackedColorArray) -> ArrayMesh:
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(primitive, arrays)
	return mesh


# --- Props ----------------------------------------------------------------

## Draw each prop's occupancy as its actual 3D voxel volume.
##
## This is the shape a character collides with -- an arch's legs with open air
## between them, a fountain's basin ring, a tree's trunk under a wider canopy --
## and none of that survives being projected onto the floor. An earlier version
## flattened the voxels to one tile per column, which drew a 5x5 diamond for a
## fountain whose bowl only fills a ring, and drew a tree and a pillar
## identically. The volume is the whole point of a voxel scan, so the volume is
## what gets drawn.
##
## The volume is drawn from the prop's LOCAL voxel scan translated by
## BoardDocument.prop_world_origin -- the identical pose its collision shapes and
## its artwork are built at. Drawing it from the whole-metre occupancy addresses
## instead put this overlay up to a metre away from the model it describes as soon
## as the ground under the prop stopped being a whole number of metres high.
func _build_prop_voxels(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	for prop in board.props:
		var solid := _cell_set(board.prop_local_voxels(prop))
		_add_voxel_volume(
			verts,
			colors,
			solid,
			solid,
			COLOR_SOLID,
			board.prop_world_origin(prop)
		)


## Cells as a set keyed for O(1) neighbour lookup.
func _cell_set(cells: Array[Vector3i]) -> Dictionary:
	var out := {}
	for cell in cells:
		out[K.voxel_key(cell)] = cell
	return out

## The six axis directions, as the face they open onto.
const NEIGHBOURS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## Emit the outward-facing shell of one voxel set at a given world position.
##
## Culling is decided in the set's own local addresses, so the world position only
## translates the finished shell and never changes which faces survive.
func _add_voxel_volume(
	verts: PackedVector3Array,
	colors: PackedColorArray,
	cells: Dictionary,
	occluding: Dictionary,
	color: Color,
	world_origin: Vector3
) -> void:
	for key: String in cells:
		var cell: Vector3i = cells[key]
		for dir in NEIGHBOURS:
			if occluding.has(K.voxel_key(cell + dir)):
				continue
			_add_voxel_face(verts, colors, cell, dir, color, world_origin)


## One face of one voxel, on the boundary the direction names.
##
## Drawn flush with the cell boundary rather than inset. An inset shrinks every
## cube away from its neighbours, which for a culled shell would open a visible
## crack along every interior seam -- the cells are one continuous volume and
## should read as one surface. Per-cell detail comes from the wireframe pass
## instead, which is additive and cannot break the silhouette.
func _add_voxel_face(
	verts: PackedVector3Array,
	colors: PackedColorArray,
	cell: Vector3i,
	dir: Vector3i,
	color: Color,
	world_origin: Vector3
) -> void:
	var q := _voxel_face_corners(cell, dir, world_origin)
	_add_quad(verts, colors, q[0], q[1], q[2], q[3], color)
	_add_outline(q[0], q[1], q[2], q[3], color)


## The same face, edges only. Used where the fill would hide what is underneath.
func _add_voxel_face_outline(
	cell: Vector3i,
	dir: Vector3i,
	color: Color,
	world_origin: Vector3
) -> void:
	var q := _voxel_face_corners(cell, dir, world_origin)
	_add_outline(q[0], q[1], q[2], q[3], color)


## Corners of one voxel face, wound consistently.
##
## Shared by the filled and outline passes so the two can never trace different
## geometry for the same face.
func _voxel_face_corners(cell: Vector3i, dir: Vector3i, world_origin: Vector3) -> Array:
	var n := Vector3(dir)
	# The face plane: the far side of the cell for positive directions, the
	# near side for negative ones, translated by the placement's world pose.
	var origin := Vector3(cell) + n.max(Vector3.ZERO) + world_origin

	# Two in-plane axes for whichever axis the direction runs along, ordered so
	# that u x v points OUT of the cell. Back-face culling depends on this: the
	# naive fixed ordering winds three of the six directions inward, which culls
	# exactly the faces nearest the camera and leaves the volume looking
	# inside-out with its far wall showing through.
	var u: Vector3
	var v: Vector3
	if absi(dir.x) == 1:
		u = Vector3(0, 1, 0)
		v = Vector3(0, 0, 1)
	elif absi(dir.y) == 1:
		u = Vector3(0, 0, 1)
		v = Vector3(1, 0, 0)
	else:
		u = Vector3(1, 0, 0)
		v = Vector3(0, 1, 0)
	# u x v points along +axis; for a face opening the other way, swap the axes
	# to reverse the winding.
	if dir.x + dir.y + dir.z < 0:
		var swap := u
		u = v
		v = swap

	return [origin, origin + u, origin + u + v, origin + v]


## Edges of every prop's SOLID volume, with no fill.
##
## Shares the culling of the filled pass so the outline traces the volume's
## silhouette and cell divisions rather than every hidden interior edge.
func _build_blocker_outlines() -> void:
	for prop in board.props:
		var solid := _cell_set(board.prop_local_voxels(prop))
		var world_origin := board.prop_world_origin(prop)
		for key: String in solid:
			var cell: Vector3i = solid[key]
			for dir in NEIGHBOURS:
				if solid.has(K.voxel_key(cell + dir)):
					continue
				_add_voxel_face_outline(cell, dir, COLOR_SOLID, world_origin)


# --- Surfaces -------------------------------------------------------------

## Draw the tactical walkability of the canonical gameplay grid.
##
## This reads BoardDocument.gameplay_grid(), the same derived surface characters
## actually walk on, so the overlay can never disagree with the terrain: an
## unpainted cell is as walkable as a painted one, and a slope reports the relief
## that makes it climbable or not. A cell is blocked when a prop fills the space
## above it or when its own relief is too steep to stand on.
func _build_surface_faces(
	verts: PackedVector3Array,
	colors: PackedColorArray
) -> void:
	var blocked := _solid_voxel_set()

	for entry: Dictionary in board.gameplay_grid():
		var cell: Vector2i = entry["cell"]
		var walk_height_m := float(entry["walk_height_m"])
		var relief_m := float(entry["relief_m"])
		# Standing room is the lattice cell the token occupies, which is the one
		# containing the walk height rather than a fixed integer floor level.
		var stand_cell := Vector3i(
			cell.x,
			TerrainMesh.level_of_height(walk_height_m),
			cell.y
		)
		var automatically_blocked := (
			blocked.has(K.voxel_key(stand_cell))
			or relief_m > MAX_WALKABLE_RELIEF_M
		)
		var color := COLOR_WALKABLE
		if bool(entry.get("manually_unwalkable", false)):
			color = COLOR_MANUALLY_UNWALKABLE
		elif not String(entry.get("ground_effect", "")).is_empty():
			color = COLOR_GROUND_EFFECT
		elif automatically_blocked:
			color = COLOR_BLOCKED_FLOOR
		_add_terrain_cell_quad(
			verts,
			colors,
			cell,
			walk_height_m,
			color
		)


## Every whole-metre cell any prop marks SOLID, keyed for O(1) lookup.
##
## This is the only place the overlay still reads whole-metre occupancy addresses,
## because the question it answers -- can a token stand in this lattice cell -- is
## the gameplay grid's question, not a drawing position. Nothing here is rendered.
func _solid_voxel_set() -> Dictionary:
	var out := {}
	for prop in board.props:
		for cell in board.prop_occupied_cells(prop):
			out[K.voxel_key(cell)] = true
	return out


# --- Geometry helpers -----------------------------------------------------

## Quad lying on one terrain cell's real sculpted top.
##
## The four corner heights come from TerrainMesh itself, so the overlay follows
## slopes and steps exactly instead of floating a flat tile at an integer level
## and implying the ground is somewhere it is not. The walk height is used only
## when a corner is unavailable, which happens for a cell outside the field.
func _add_terrain_cell_quad(
	verts: PackedVector3Array,
	colors: PackedColorArray,
	cell: Vector2i,
	walk_height_m: float,
	color: Color
) -> void:
	var terrain := board.terrain
	var pad := 0.03
	var heights := PackedFloat32Array([
		walk_height_m, walk_height_m, walk_height_m, walk_height_m
	])
	if terrain != null and terrain.has_cell(cell):
		heights = terrain.cell_top(cell)

	# Corner order matches TerrainMesh: 0=(x,z) 1=(x+1,z) 2=(x,z+1) 3=(x+1,z+1).
	var base := Vector2(cell)
	var a := Vector3(base.x + pad, heights[0] + SURFACE_LIFT, base.y + pad)
	var b := Vector3(base.x + 1.0 - pad, heights[1] + SURFACE_LIFT, base.y + pad)
	var c := Vector3(base.x + 1.0 - pad, heights[3] + SURFACE_LIFT, base.y + 1.0 - pad)
	var d := Vector3(base.x + pad, heights[2] + SURFACE_LIFT, base.y + 1.0 - pad)
	_add_quad(verts, colors, a, b, c, d, color)
	_add_outline(a, b, c, d, color)


func _add_quad(verts: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	for p in [a, b, c, a, c, d]:
		verts.append(p)
		colors.append(color)


## Cell-boundary lines around one quad.
##
## Opaque and slightly brighter than the fill: the fill states the volume, the
## edges state where the cells divide it, and a line at the fill's own alpha
## would vanish into it.
func _add_outline(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	var line := Color(
		minf(1.0, color.r + 0.25),
		minf(1.0, color.g + 0.25),
		minf(1.0, color.b + 0.25),
		minf(1.0, color.a + 0.35)
	)
	for pair in [[a, b], [b, c], [c, d], [d, a]]:
		_wire_verts.append(pair[0])
		_wire_verts.append(pair[1])
		_wire_colors.append(line)
		_wire_colors.append(line)
