@tool
class_name TerrainMesh
extends Resource

## The canonical tactical encounter surface: real faces, not a corner lattice.
##
## A corner lattice stores one height per grid corner and therefore cannot
## express a vertical drop: two quads separated by a 3 m fall share the corners
## between them, and any single-height-per-corner model is forced to turn that
## drop into a ramp. This resource stores what is actually there instead.
##
## Every cell owns:
##
##   - a TOP face: four explicit corner heights plus its canonical diagonal,
##     so it can be flat, sloped, or a non-planar saddle without changing shape
##   - up to four SIDE faces: real vertical walls with an owned sub-edge range
##     and bottom/top height at both endpoints, independent of anything the
##     neighbouring cell stores
##
## Because a side face carries its own endpoint profile, a 3 m drop between two
## quads is stored as a 3 m wall and stays a 3 m wall. A wall can taper to a
## triangle where a slope meets a step, or occupy only half an edge when the
## higher surface changes sides. Nothing is guessed by the renderer.
##
## Editing vocabulary
## ------------------
## There are exactly two ways to move terrain, and the difference between them is
## the difference between a step and a slope:
##
##   set_cell_top_level()      moves ONE cell's four corners. Neighbours keep
##                             their own heights at the shared grid corner, so a
##                             real wall appears at the seam. This is the step.
##   set_lattice_corner_height() moves EVERY cell corner meeting one grid corner
##                             to the same height, which is what makes adjacent
##                             cells share that corner and read as one continuous
##                             slope.
##
## Both rebuild the side faces around what they touched, so a drop that appears
## becomes a wall and a drop that closes stops being one. There is deliberately no
## third "move the corner but only for some cells" operation: that heuristic is
## what previously re-created shared-corner behaviour and destroyed every step.
##
## This is the single source of truth: the rendered mesh, the collision, the
## paintable faces, and the gameplay grid are all derived from it.

const K := preload("../utils/mts_constants.gd")

## Heights within this tolerance are one level. Far below the finest authored
## step, but large enough to absorb float error from repeated edits.
const LEVEL_EPSILON_M: float = 0.0005

## Edge ownership splits use a dimensionless parameter, so their tolerance must
## not reuse the metre tolerance above.
const EDGE_PARAMETER_EPSILON: float = 0.000001

## Optional side-texture seeding applies only to residual bands strictly shorter
## than one tenth of a metre; regular one-metre side-grid squares stay independent.
const THIN_SIDE_TEXTURE_SEED_MAX_HEIGHT_M: float = 0.1

## Bounded because an encounter map is hand-authored.
const MAX_AXIS_CELLS: int = 512

## Cell edges a side face can stand on, named for the neighbour they face.
enum { EDGE_NORTH, EDGE_EAST, EDGE_SOUTH, EDGE_WEST }

## Cell-space offset of the neighbour across each edge.
const EDGE_NEIGHBOURS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
]

## The two top-face corner indices along each edge, ordered so the emitted side
## face points away from the cell that owns it.
##
## Top corners are indexed 0=(x,z) 1=(x+1,z) 2=(x,z+1) 3=(x+1,z+1).
const EDGE_CORNER_INDICES: Array = [
	[0, 1],
	[1, 3],
	[3, 2],
	[2, 0],
]

## The XZ offset of each top-face corner within its cell.
const CORNER_OFFSETS: Array[Vector2i] = [
	Vector2i(0, 0),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(1, 1),
]

## The grid face each cell edge presents, so a terrain face is addressed in the
## same (cell, face) language a placed 1 m quad always used.
##
## NORTH faces the -Z neighbour and therefore stands on the cell's z-minimum
## edge, which is exactly where a NEG_Z unit face sits. The other three follow.
const EDGE_GRID_FACES: Array[int] = [
	K.Face.NEG_Z,
	K.Face.POS_X,
	K.Face.POS_Z,
	K.Face.NEG_X,
]

## Derived gameplay classifications, read back from a cell's top face.
enum CellForm { EMPTY, FLAT, RAMP, SADDLE }

## What one paintable 1 m terrain face is.
##
## TOP is walkable ground, SIDE is a real wall between two filled cells, and
## SKIRT is the outer shell that closes the map's boundary. All three are painted
## and picked identically; the kind exists so the UI can report them separately
## and so the skirt can be excluded from gameplay traversal later.
enum FaceKind { TOP, SIDE, SKIRT }

@export var size_cells: Vector2i = Vector2i.ZERO
@export var origin_cell: Vector2i = Vector2i.ZERO

## Row-major occupancy of the drawn footprint, one entry per cell.
@export var cell_mask: PackedByteArray = PackedByteArray()

## Row-major top-face corner heights, FOUR per cell rather than one per lattice
## corner. Adjacent cells therefore hold independent heights at the same grid
## corner, which is exactly what a vertical drop between two quads requires.
@export var top_heights: PackedFloat32Array = PackedFloat32Array()

## One canonical diagonal per top cell: 0 joins corners 0-3, 1 joins corners 1-2.
##
## Manual sculpting derives this deterministically after a height edit. A GLB
## import records the diagonal actually authored in Blender so saddle cells keep
## the same two planes rather than being retriangulated into a different shape.
@export var top_diagonals: PackedByteArray = PackedByteArray()

## Real vertical side faces, keyed by "x,z,edge".
##
## Each value is [start_t, end_t, start_bottom_m, start_top_m,
## end_bottom_m, end_top_m]. The edge parameter follows EDGE_CORNER_INDICES,
## so every stored profile has one explicit world-space interpretation.
@export var side_faces: Dictionary = {}

## Vertical depth of the terrain boundary shell below its current lowest top.
##
## Depth is the one authored value. The absolute base is derived from the live
## heightfield, so lowering terrain moves the shell down instead of clipping it
## against a stale world elevation.
@export_range(0.05, 256.0, 0.05) var skirt_depth_m: float = 1.0

## Absolute world elevation currently produced by the authored skirt depth.
var skirt_base_m: float:
	get:
		return lowest_top_height() - skirt_depth_m


## Create an empty terrain sized to one footprint rectangle.
static func create(p_origin_cell: Vector2i, p_size_cells: Vector2i) -> TerrainMesh:
	var terrain := TerrainMesh.new()
	terrain.origin_cell = p_origin_cell
	terrain.resize(p_size_cells)
	return terrain


## Allocate mask and per-cell top faces for an exact footprint size.
func resize(p_size_cells: Vector2i) -> void:
	size_cells = Vector2i(
		clampi(p_size_cells.x, 0, MAX_AXIS_CELLS),
		clampi(p_size_cells.y, 0, MAX_AXIS_CELLS)
	)
	cell_mask = PackedByteArray()
	top_heights = PackedFloat32Array()
	top_diagonals = PackedByteArray()
	side_faces = {}
	if size_cells.x <= 0 or size_cells.y <= 0:
		return
	var count := size_cells.x * size_cells.y
	cell_mask.resize(count)
	cell_mask.fill(0)
	top_heights.resize(count * 4)
	top_heights.fill(0.0)
	top_diagonals.resize(count)
	top_diagonals.fill(0)


## Return whether this terrain holds an authored footprint.
func is_empty() -> bool:
	return size_cells.x <= 0 or size_cells.y <= 0 or cell_mask.is_empty()


## Return whether an absolute cell lies inside the allocated rectangle.
func has_cell(cell: Vector2i) -> bool:
	var local := cell - origin_cell
	return (
		local.x >= 0
		and local.y >= 0
		and local.x < size_cells.x
		and local.y < size_cells.y
	)


## Return whether an absolute cell is part of the drawn footprint.
func is_cell_filled(cell: Vector2i) -> bool:
	if not has_cell(cell):
		return false
	var local := cell - origin_cell
	return cell_mask[local.y * size_cells.x + local.x] != 0


## Add or remove one footprint cell, keeping its authored top heights.
##
## Occupancy changes which edges are internal seams and which become boundary
## skirts. Rebuilding this cell and its four neighbours immediately prevents a
## removed neighbour from leaving a stale internal wall under the new skirt.
func set_cell_filled(cell: Vector2i, filled: bool) -> bool:
	if not has_cell(cell):
		return false
	var local := cell - origin_cell
	var index := local.y * size_cells.x + local.x
	var value := 1 if filled else 0
	if cell_mask[index] == value:
		return false
	cell_mask[index] = value
	_rebuild_side_faces_around(cell)
	return true


## Return the number of cells currently in the footprint.
func filled_cell_count() -> int:
	var total := 0
	for value: int in cell_mask:
		if value != 0:
			total += 1
	return total


## Return the index of one cell's first top-face height, or -1 when outside.
func _top_index(cell: Vector2i) -> int:
	if not has_cell(cell):
		return -1
	var local := cell - origin_cell
	return (local.y * size_cells.x + local.x) * 4


## Return one cell's canonical top-face diagonal.
func cell_top_diagonal(cell: Vector2i) -> int:
	var top_index := _top_index(cell)
	if top_index < 0:
		return 0
	return int(top_diagonals[top_index / 4])


## Store one cell's explicit top-face diagonal.
func set_cell_top_diagonal(cell: Vector2i, diagonal: int) -> bool:
	var top_index := _top_index(cell)
	if top_index < 0 or diagonal < 0 or diagonal > 1:
		return false
	var cell_index := top_index / 4
	if int(top_diagonals[cell_index]) == diagonal:
		return false
	top_diagonals[cell_index] = diagonal
	return true


## Derive the same stable diagonal manual sculpting used before it became stored data.
func _refresh_cell_top_diagonal(cell: Vector2i) -> void:
	var heights := cell_top(cell)
	set_cell_top_diagonal(
		cell,
		0 if absf(heights[0] - heights[3]) <= absf(heights[1] - heights[2]) else 1
	)


## Return one cell's four top-face corner heights.
##
## Order is fixed: 0=(x,z) 1=(x+1,z) 2=(x,z+1) 3=(x+1,z+1).
func cell_top(cell: Vector2i) -> PackedFloat32Array:
	var index := _top_index(cell)
	if index < 0:
		return PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	return PackedFloat32Array([
		top_heights[index],
		top_heights[index + 1],
		top_heights[index + 2],
		top_heights[index + 3],
	])


## Set all four of one cell's top-face corner heights.
func set_cell_top(cell: Vector2i, heights: PackedFloat32Array) -> bool:
	var index := _top_index(cell)
	if index < 0 or heights.size() != 4:
		return false
	var changed := false
	for corner: int in 4:
		if not is_equal_approx(top_heights[index + corner], heights[corner]):
			top_heights[index + corner] = heights[corner]
			changed = true
	if changed:
		_refresh_cell_top_diagonal(cell)
	return changed


## Set one corner of one cell's top face without touching any neighbour.
##
## This is the raw write. Callers that want a step use set_cell_top_level() and
## callers that want a slope use set_lattice_corner_height(); both wrap this and
## then rebuild the side faces the edit implies.
func set_cell_corner(cell: Vector2i, corner: int, height_m: float) -> bool:
	var index := _top_index(cell)
	if index < 0 or corner < 0 or corner > 3:
		return false
	if is_equal_approx(top_heights[index + corner], height_m):
		return false
	top_heights[index + corner] = height_m
	_refresh_cell_top_diagonal(cell)
	return true


## Return one cell's top-face corner height.
func cell_corner(cell: Vector2i, corner: int) -> float:
	var index := _top_index(cell)
	if index < 0 or corner < 0 or corner > 3:
		return 0.0
	return top_heights[index + corner]


## Move one whole cell's top face to a level and rebuild the walls it implies.
##
## This is the step operation. All four of the cell's own corners move together
## and NO neighbouring cell is touched, so the height difference that appears at
## each seam becomes a real vertical side face rather than a ramp. That is the
## entire reason terrain stores four corners per cell instead of one per lattice
## corner.
func set_cell_top_level(cell: Vector2i, height_m: float) -> bool:
	if not is_cell_filled(cell):
		return false
	var changed := false
	for corner: int in 4:
		if set_cell_corner(cell, corner, height_m):
			changed = true
	if changed:
		_rebuild_side_faces_around(cell)
	return changed


## Move one whole cell's top face by a signed amount, keeping its own slope.
##
## Used by the step brushes when the cell is already sloped: the offset preserves
## the authored gradient instead of flattening it, while the seams around the
## cell still become real walls.
func offset_cell_top(cell: Vector2i, delta_m: float) -> bool:
	if not is_cell_filled(cell) or is_zero_approx(delta_m):
		return false
	var changed := false
	for corner: int in 4:
		if set_cell_corner(cell, corner, cell_corner(cell, corner) + delta_m):
			changed = true
	if changed:
		_rebuild_side_faces_around(cell)
	return changed


## Move every cell corner meeting one grid corner to the same height.
##
## This is the slope operation. Because all four adjacent cells take the identical
## height at that grid corner, they genuinely share it and the surface between
## them is continuous -- which is what a slope is. Any residual drop against a
## cell further out still becomes a real wall, so slopes and steps coexist in one
## surface.
func set_lattice_corner_height(corner: Vector2i, height_m: float) -> bool:
	var changed := false
	var touched: Array[Vector2i] = []
	for index: int in 4:
		var cell := corner - CORNER_OFFSETS[index]
		if not is_cell_filled(cell):
			continue
		touched.append(cell)
		if set_cell_corner(cell, index, height_m):
			changed = true
	if changed:
		# Every edge incident to this lattice corner has both owning cells in
		# touched. Rebuilding those four cells once updates both sides of every
		# affected seam; expanding each one through its neighbours repeated the
		# same edge work five times per brush corner.
		for cell: Vector2i in touched:
			rebuild_side_faces_for_cell(cell)
	return changed


## Rebuild the side faces of one cell and of the four cells around it.
##
## Both neighbours of a seam must be reconsidered: raising a cell can create a
## wall it owns, and can equally remove a wall its neighbour owned.
func _rebuild_side_faces_around(cell: Vector2i) -> void:
	rebuild_side_faces_for_cell(cell)
	for edge: int in 4:
		rebuild_side_faces_for_cell(cell + EDGE_NEIGHBOURS[edge])


## Return whether any filled cell touches one absolute lattice corner.
func has_corner_coordinate(corner: Vector2i) -> bool:
	for offset: Vector2i in CORNER_OFFSETS:
		if has_cell(corner - offset):
			return true
	return false


## Return the highest surface height at one absolute lattice corner.
##
## This is a READING helper for brush sampling and for draping the reference
## grid, not a coordinate the terrain stores. Where a vertical drop meets, several
## cells legitimately hold DIFFERENT heights at the same grid corner; the highest
## is the surface the user sees and is working on. Nothing may write terrain back
## through this value.
func lattice_top_height(corner: Vector2i) -> float:
	var highest := -INF
	for index: int in 4:
		var cell := corner - CORNER_OFFSETS[index]
		if not is_cell_filled(cell):
			continue
		highest = maxf(highest, cell_corner(cell, index))
	return 0.0 if highest == -INF else highest


## Return whether one owned side face genuinely reaches one local edge endpoint.
##
## Tapered side faces can occupy only part of an edge and end where the two top
## surfaces cross. Only a non-zero vertical span at t=0 or t=1 owns that endpoint;
## treating the whole edge as connected would freeze an unrelated second corner.
func side_face_touches_corner(cell: Vector2i, edge: int, local_corner: int) -> bool:
	if edge < EDGE_NORTH or edge > EDGE_WEST:
		return false
	var corner_indices: Array = EDGE_CORNER_INDICES[edge]
	var profile := side_face(cell, edge)
	if profile.is_empty():
		return false
	if local_corner == int(corner_indices[0]):
		return (
			float(profile[0]) <= EDGE_PARAMETER_EPSILON
			and float(profile[3]) - float(profile[2]) > LEVEL_EPSILON_M
		)
	if local_corner == int(corner_indices[1]):
		return (
			float(profile[1]) >= 1.0 - EDGE_PARAMETER_EPSILON
			and float(profile[5]) - float(profile[4]) > LEVEL_EPSILON_M
		)
	return false


## Return whether one cell seam's real wall reaches one of that cell's corners.
##
## A side face may be stored by either cell across the seam, so both owners are
## checked after translating the absolute endpoint into the neighbour's local
## corner index. Walls on other seams that merely meet the same absolute lattice
## coordinate do not belong to this cell corner.
func seam_side_face_touches_corner(
	cell: Vector2i,
	edge: int,
	local_corner: int
) -> bool:
	if edge < EDGE_NORTH or edge > EDGE_WEST:
		return false
	if local_corner not in EDGE_CORNER_INDICES[edge]:
		return false
	if side_face_touches_corner(cell, edge, local_corner):
		return true
	var neighbour := cell + EDGE_NEIGHBOURS[edge]
	var absolute_corner := cell + CORNER_OFFSETS[local_corner]
	var neighbour_corner := local_corner_index(neighbour, absolute_corner)
	if neighbour_corner < 0:
		return false
	return side_face_touches_corner(neighbour, (edge + 2) % 4, neighbour_corner)


## Return whether one specific quad corner belongs to an existing wall seam.
##
## Terrain stores four independent local corners per cell so vertical drops can
## exist. Smooth contact flatten asks this before sharing a boundary corner with a
## quad outside the footprint: sharing a corner a wall stands on would pull that
## wall's top edge down onto the pad and collapse it. Unrelated wall endpoints at
## the same absolute coordinate belong to other quads and do not answer true here.
func local_corner_carries_side_face(cell: Vector2i, local_corner: int) -> bool:
	if local_corner < 0 or local_corner >= CORNER_OFFSETS.size():
		return false
	for edge: int in 4:
		if seam_side_face_touches_corner(cell, edge, local_corner):
			return true
	return false


## Return whether any real vertical wall endpoint stands on one grid corner.
##
## This global diagnostic deliberately scans every quad sharing the coordinate. It
## is what the manual sculpt brush's Protect Walls option asks before moving a
## lattice corner, because that operation gives every quad meeting the coordinate
## the same height and would close the drop. Operations that preserve per-cell
## corner ownership must instead call local_corner_carries_side_face() for the
## exact quad corner being considered.
##
## Only stored side faces count. The boundary skirt is derived per enumeration
## rather than stored, so it is deliberately not treated as an authored wall.
func corner_carries_side_face(corner: Vector2i) -> bool:
	for index: int in 4:
		var cell := corner - CORNER_OFFSETS[index]
		if not is_cell_filled(cell):
			continue
		for edge: int in 4:
			if side_face_touches_corner(cell, edge, index):
				return true
	return false


## Return which of one cell's four top corners sits on one absolute lattice corner.
##
## Reasoning across a seam means comparing two cells at the same grid corner, and
## each cell indexes that corner differently, so the shared corner must be
## translated rather than assumed. Returns -1 when the corner is not on the cell.
func local_corner_index(cell: Vector2i, corner: Vector2i) -> int:
	var offset := corner - cell
	for index: int in 4:
		if CORNER_OFFSETS[index] == offset:
			return index
	return -1


## Return whether a real vertical wall currently stands on one cell's seam.
##
## Whichever cell is higher owns the stored face, so a seam has to be asked from
## both sides. Only stored side faces count: the boundary skirt is derived per
## enumeration rather than stored, so it is deliberately not an authored wall.
func seam_carries_side_face(cell: Vector2i, edge: int) -> bool:
	if edge < EDGE_NORTH or edge > EDGE_WEST:
		return false
	var neighbour := cell + EDGE_NEIGHBOURS[edge]
	return has_side_face(cell, edge) or has_side_face(neighbour, (edge + 2) % 4)


## Return whether levelling one whole cell to a height would close one seam's wall.
##
## The neighbour is taken at the height it holds now. Both ends of the seam must
## go flush for the wall to disappear, because each side of the seam interpolates
## linearly between its two endpoint heights: while either end keeps a real drop
## the wall survives, tapered to a triangle at worst.
func cell_level_closes_seam(cell: Vector2i, edge: int, height_m: float) -> bool:
	if edge < EDGE_NORTH or edge > EDGE_WEST:
		return false
	var neighbour := cell + EDGE_NEIGHBOURS[edge]
	if not is_cell_filled(cell) or not is_cell_filled(neighbour):
		return false
	var corner_indices: Array = EDGE_CORNER_INDICES[edge]
	for entry: Variant in corner_indices:
		var world_corner := cell + CORNER_OFFSETS[int(entry)]
		var neighbour_corner := local_corner_index(neighbour, world_corner)
		if neighbour_corner < 0:
			continue
		if absf(height_m - cell_corner(neighbour, neighbour_corner)) > LEVEL_EPSILON_M:
			return false
	return true


## Return the storage key for one cell edge.
static func side_key(cell: Vector2i, edge: int) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, edge]


## Record one rectangular real side face across a complete cell edge.
##
## Imported walls use this public operation because their authored rectangle has
## one bottom and one top. Sculpted walls use set_side_face_profile() so a
## step/slope transition retains both endpoint heights.
func set_side_face(cell: Vector2i, edge: int, bottom_m: float, top_m: float) -> void:
	set_side_face_profile(
		cell,
		edge,
		0.0,
		1.0,
		bottom_m,
		top_m,
		bottom_m,
		top_m
	)


## Record one real side face over an explicit owned portion of a cell edge.
##
## The stored top must remain above the stored bottom at both endpoints. A
## zero-height endpoint is valid and produces a triangle, which is exactly the
## closure required where a slope reaches a stepped plateau.
func set_side_face_profile(
	cell: Vector2i,
	edge: int,
	start_t: float,
	end_t: float,
	start_bottom_m: float,
	start_top_m: float,
	end_bottom_m: float,
	end_top_m: float
) -> void:
	if edge < EDGE_NORTH or edge > EDGE_WEST:
		push_error("TerrainMesh: side-face edge %d is not one of the four cell edges." % edge)
		return
	if start_t < 0.0 or end_t > 1.0 or end_t - start_t <= EDGE_PARAMETER_EPSILON:
		push_error(
			"TerrainMesh: side-face edge range %.6f..%.6f must lie inside 0..1."
			% [start_t, end_t]
		)
		return
	var start_bottom := minf(start_bottom_m, start_top_m)
	var start_top := maxf(start_bottom_m, start_top_m)
	var end_bottom := minf(end_bottom_m, end_top_m)
	var end_top := maxf(end_bottom_m, end_top_m)
	if (
		start_top - start_bottom <= LEVEL_EPSILON_M
		and end_top - end_bottom <= LEVEL_EPSILON_M
	):
		side_faces.erase(side_key(cell, edge))
		return
	side_faces[side_key(cell, edge)] = [
		start_t,
		end_t,
		start_bottom,
		start_top,
		end_bottom,
		end_top,
	]


## Return one edge's six-value owned endpoint profile, or an empty array.
func side_face(cell: Vector2i, edge: int) -> Array:
	var value: Variant = side_faces.get(side_key(cell, edge), null)
	if value is Array and (value as Array).size() == 6:
		return value
	return []


## Return whether one cell edge carries a real vertical face.
func has_side_face(cell: Vector2i, edge: int) -> bool:
	return not side_face(cell, edge).is_empty()


## Remove one edge's side face.
func clear_side_face(cell: Vector2i, edge: int) -> void:
	side_faces.erase(side_key(cell, edge))


## Return every stored side profile with explicit edge and endpoint data.
func side_face_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for key: Variant in side_faces.keys():
		var parts := String(key).split(",")
		if parts.size() != 3:
			continue
		var profile: Array = side_faces[key]
		if profile.size() != 6:
			continue
		records.append({
			"cell": Vector2i(int(parts[0]), int(parts[1])),
			"edge": int(parts[2]),
			"start_t": float(profile[0]),
			"end_t": float(profile[1]),
			"start_bottom_m": float(profile[2]),
			"start_top_m": float(profile[3]),
			"end_bottom_m": float(profile[4]),
			"end_top_m": float(profile[5]),
		})
	return records


## Return the total number of paintable bands across every side face.
func side_face_band_count() -> int:
	var total := 0
	for record: Dictionary in side_face_records():
		total += side_face_bands(record["cell"], record["edge"]).size()
	return total


## Split one span into whole 1 m paintable bands from its bottom upward.
##
## Side faces are painted and addressed on the same 1 m lattice as the ground, so
## a tall wall becomes a stack of 1 m faces rather than one stretched quad.
static func bands_in_span(bottom_m: float, top_m: float) -> Array:
	var bands: Array = []
	var band_bottom := bottom_m
	while top_m - band_bottom > LEVEL_EPSILON_M:
		# Advance to the next whole metre above the current bottom. Guarding with
		# a strict comparison matters for negative heights, where floor() can land
		# on or below band_bottom and the loop would never advance.
		var next_metre := floorf(band_bottom) + 1.0
		if next_metre - band_bottom <= LEVEL_EPSILON_M:
			next_metre = band_bottom + 1.0
		var band_top := minf(next_metre, top_m)
		bands.append([band_bottom, band_top])
		band_bottom = band_top
	return bands


## Split one side profile into the vertical metre bands its geometry reaches.
func side_face_bands(cell: Vector2i, edge: int) -> Array:
	var profile := side_face(cell, edge)
	if profile.is_empty():
		return []
	var lowest := minf(float(profile[2]), float(profile[4]))
	var highest := maxf(float(profile[3]), float(profile[5]))
	return bands_in_span(lowest, highest)


## Derive the exact vertical closure between one cell and all four neighbours.
func rebuild_side_faces_for_cell(cell: Vector2i) -> void:
	for edge: int in 4:
		rebuild_side_face_for_edge(cell, edge)


## Derive the exact vertical closure for one explicitly requested cell edge.
##
## The importer uses this narrow operation only after proving the source GLB
## contains that wall, so a malformed file cannot gain a wall it did not author.
## Opposite winding is aligned before comparison, and a height-order crossing is
## split into complementary owned segments meeting at one deterministic point.
func rebuild_side_face_for_edge(cell: Vector2i, edge: int) -> void:
	if edge < EDGE_NORTH or edge > EDGE_WEST:
		push_error("TerrainMesh: side-face edge %d is not one of the four cell edges." % edge)
		return
	if not is_cell_filled(cell):
		clear_side_face(cell, edge)
		return
	var neighbour: Vector2i = cell + EDGE_NEIGHBOURS[edge]
	if not is_cell_filled(neighbour):
		clear_side_face(cell, edge)
		return
	var corner_indices: Array = EDGE_CORNER_INDICES[edge]
	var opposite := (edge + 2) % 4
	var neighbour_indices: Array = EDGE_CORNER_INDICES[opposite]
	var start_top := cell_corner(cell, int(corner_indices[0]))
	var end_top := cell_corner(cell, int(corner_indices[1]))
	# Opposite edge winding runs the other way in world space, so reversing its
	# indices aligns both height pairs to the same edge parameter.
	var start_bottom := cell_corner(neighbour, int(neighbour_indices[1]))
	var end_bottom := cell_corner(neighbour, int(neighbour_indices[0]))
	var start_gap := start_top - start_bottom
	var end_gap := end_top - end_bottom
	if start_gap <= LEVEL_EPSILON_M and end_gap <= LEVEL_EPSILON_M:
		clear_side_face(cell, edge)
		return
	if start_gap >= -LEVEL_EPSILON_M and end_gap >= -LEVEL_EPSILON_M:
		set_side_face_profile(
			cell,
			edge,
			0.0,
			1.0,
			start_bottom,
			start_top,
			end_bottom,
			end_top
		)
		return
	var crossing_t := clampf(start_gap / (start_gap - end_gap), 0.0, 1.0)
	var crossing_height := lerpf(start_top, end_top, crossing_t)
	if start_gap > LEVEL_EPSILON_M:
		set_side_face_profile(
			cell,
			edge,
			0.0,
			crossing_t,
			start_bottom,
			start_top,
			crossing_height,
			crossing_height
		)
	else:
		set_side_face_profile(
			cell,
			edge,
			crossing_t,
			1.0,
			crossing_height,
			crossing_height,
			end_bottom,
			end_top
		)


## Return whether one cell's top face is level within tolerance.
func is_cell_level(cell: Vector2i) -> bool:
	var heights := cell_top(cell)
	var lowest := heights[0]
	var highest := heights[0]
	for height: float in heights:
		lowest = minf(lowest, height)
		highest = maxf(highest, height)
	return highest - lowest <= LEVEL_EPSILON_M


## Return the walkable height of one cell as the centre of its top face.
func cell_walk_height(cell: Vector2i) -> float:
	var heights := cell_top(cell)
	return (heights[0] + heights[1] + heights[2] + heights[3]) * 0.25


## Return the lowest of one cell's four top-face corners.
func cell_lowest_corner(cell: Vector2i) -> float:
	var heights := cell_top(cell)
	return minf(minf(heights[0], heights[1]), minf(heights[2], heights[3]))


## Return the vertical span across one cell's top face.
func cell_relief(cell: Vector2i) -> float:
	var heights := cell_top(cell)
	var lowest := heights[0]
	var highest := heights[0]
	for height: float in heights:
		lowest = minf(lowest, height)
		highest = maxf(highest, height)
	return highest - lowest


## Classify one cell's gameplay form purely from its own top face.
func classify_cell(cell: Vector2i) -> CellForm:
	if not is_cell_filled(cell):
		return CellForm.EMPTY
	if is_cell_level(cell):
		return CellForm.FLAT
	var heights := cell_top(cell)
	# A bilinear patch is planar exactly when its diagonal sums agree.
	if absf((heights[0] + heights[3]) - (heights[1] + heights[2])) <= LEVEL_EPSILON_M * 2.0:
		return CellForm.RAMP
	return CellForm.SADDLE


## Return the stable display name of one derived cell form.
func cell_form_name(form: CellForm) -> String:
	match form:
		CellForm.FLAT:
			return "Flat"
		CellForm.RAMP:
			return "Ramp"
		CellForm.SADDLE:
			return "Saddle"
		_:
			return "Empty"


## Return one cell's outward XZ gradient in metres per metre.
func cell_gradient(cell: Vector2i) -> Vector2:
	var heights := cell_top(cell)
	return Vector2(
		((heights[1] + heights[3]) - (heights[0] + heights[2])) * 0.5,
		((heights[2] + heights[3]) - (heights[0] + heights[1])) * 0.5
	)


## Return the height of one cell's top face at a local 0..1 position.
func sample_cell_height(cell: Vector2i, local_xz: Vector2) -> float:
	var heights := cell_top(cell)
	var u := clampf(local_xz.x, 0.0, 1.0)
	var v := clampf(local_xz.y, 0.0, 1.0)
	return lerpf(
		lerpf(heights[0], heights[1], u),
		lerpf(heights[2], heights[3], u),
		v
	)


## Return the terrain height at one absolute world XZ point.
##
## This reads only the TOP surface, so it cannot see a vertical wall. It is for
## gameplay walk heights and for sampling, never for picking: picking goes through
## the real triangles so a wall band can be hit.
func sample_world_height(world_xz: Vector2, fallback_m: float = 0.0) -> float:
	var cell := Vector2i(floori(world_xz.x), floori(world_xz.y))
	if not is_cell_filled(cell):
		return fallback_m
	return sample_cell_height(cell, world_xz - Vector2(cell))


## Return the lowest authored top-face corner across the whole footprint.
func lowest_top_height() -> float:
	var lowest := INF
	for local_z: int in size_cells.y:
		for local_x: int in size_cells.x:
			var cell := origin_cell + Vector2i(local_x, local_z)
			if not is_cell_filled(cell):
				continue
			for height: float in cell_top(cell):
				lowest = minf(lowest, height)
	return 0.0 if lowest == INF else lowest


## Return the highest authored top-face corner across the whole footprint.
func highest_top_height() -> float:
	var highest := -INF
	for local_z: int in size_cells.y:
		for local_x: int in size_cells.x:
			var cell := origin_cell + Vector2i(local_x, local_z)
			if not is_cell_filled(cell):
				continue
			for height: float in cell_top(cell):
				highest = maxf(highest, height)
	return 0.0 if highest == -INF else highest


## Return the absolute cell rectangle covering the drawn footprint.
func filled_bounds_cells() -> Rect2i:
	var minimum := Vector2i(MAX_AXIS_CELLS, MAX_AXIS_CELLS)
	var maximum := Vector2i(-MAX_AXIS_CELLS, -MAX_AXIS_CELLS)
	var found := false
	for local_z: int in size_cells.y:
		for local_x: int in size_cells.x:
			if cell_mask[local_z * size_cells.x + local_x] == 0:
				continue
			found = true
			minimum = minimum.min(Vector2i(local_x, local_z))
			maximum = maximum.max(Vector2i(local_x, local_z))
	if not found:
		return Rect2i(origin_cell, Vector2i.ZERO)
	return Rect2i(origin_cell + minimum, maximum - minimum + Vector2i.ONE)


## Return the world-space XZ rectangle spanned by the allocated grid.
func world_rect() -> Rect2:
	return Rect2(Vector2(origin_cell), Vector2(size_cells))


# -----------------------------------------------------------------------------
# Paintable 1 m faces
# -----------------------------------------------------------------------------

## Return the paint chunk one absolute cell belongs to.
##
## Floor division rather than GDScript's truncating integer division, because a
## board authored at negative coordinates would otherwise fold two different
## chunks onto the same key around zero.
static func chunk_of_cell(cell: Vector2i, chunk_cells: int) -> Vector2i:
	var size := maxi(chunk_cells, 1)
	return Vector2i(
		floori(float(cell.x) / float(size)),
		floori(float(cell.y) / float(size))
	)


## Return the stable paint identity of one cell's ground face.
##
## Ground is painted per CELL, exactly as it was when every cell was its own 1 m
## quad. A texture therefore lands at its authored size on the grid; spanning the
## coordinate across a larger area is what stretches one image over the whole
## surface instead of tiling it.
static func cell_top_uid(cell: Vector2i) -> String:
	return "t:%d,%d" % [cell.x, cell.y]


## Return the stable paint identity of one side-face band.
##
## Bands are numbered from the bottom of the face upward so the lower bands keep
## their authored paint when a wall grows taller.
static func band_uid(cell: Vector2i, edge: int, band: int) -> String:
	return "s:%d,%d,%d,%d" % [cell.x, cell.y, edge, band]


## Return the whole-metre lattice level one elevation sits on.
##
## The epsilon keeps a face whose bottom is an exact metre from being pushed a
## level down by float error accumulated through repeated edits.
static func level_of_height(height_m: float) -> int:
	return floori(height_m + LEVEL_EPSILON_M)


## Return the paint identities this terrain owns inside an optional cell rectangle.
##
## An empty rectangle inspects the complete terrain for destructive resets. Sculpt
## strokes pass their dirty rectangle so paint reconciliation remains proportional
## to the edited cells instead of rescanning the complete board. Keys are UIDs; the
## value is always true so callers can use a Dictionary as a cheap set.
func face_uid_set(bounds: Rect2i = Rect2i()) -> Dictionary:
	var uids: Dictionary = {}
	for face: Dictionary in terrain_faces(8, bounds):
		uids[String(face["paint_uid"])] = true
	return uids


## Return every paintable 1 m face of this terrain.
##
## One record per face of the rendered surface: one TOP per filled cell, one SIDE
## per 1 m band of every wall, and one SKIRT per 1 m band of the boundary shell.
## This is the single interface between the heightfield and everything downstream --
## the mesh builder, paint system, picking, and prop placement all read these
## records rather than re-deriving faces for themselves.
##
## Each record carries both identities a face needs:
##
##   paint_uid   stable across sculpting, so authored paint survives an edit
##   grid_cell   the integer (x, level, z) lattice address plus its K.Face, which
##               is exactly how a placed 1 m quad was addressed
##
## `bounds` limits the scan to one absolute cell rectangle; an empty rectangle
## means the whole footprint.
func terrain_faces(chunk_cells: int = 8, bounds: Rect2i = Rect2i()) -> Array[Dictionary]:
	var faces: Array[Dictionary] = []
	if is_empty():
		return faces
	var scan := Rect2i(origin_cell, size_cells)
	if bounds.size.x > 0 and bounds.size.y > 0:
		scan = scan.intersection(bounds)
	if scan.size.x <= 0 or scan.size.y <= 0:
		return faces

	for local_z: int in scan.size.y:
		for local_x: int in scan.size.x:
			var cell := scan.position + Vector2i(local_x, local_z)
			if not is_cell_filled(cell):
				continue
			faces.append(_top_face_record(cell, chunk_cells))
			for edge: int in 4:
				for record: Dictionary in _side_face_records_for_edge(cell, edge):
					faces.append(record)
	faces.append_array(_skirt_face_records(scan))
	return faces


## Build the TOP face record for one filled cell.
##
## The quad is emitted in the canonical corner order 0=(x,z) 1=(x+1,z) 2=(x,z+1)
## 3=(x+1,z+1), which every consumer relies on.
func _top_face_record(cell: Vector2i, chunk_cells: int) -> Dictionary:
	var heights := cell_top(cell)
	var base := Vector2(cell)
	var chunk := chunk_of_cell(cell, chunk_cells)
	return {
		"kind": FaceKind.TOP,
		"cell": cell,
		"edge": -1,
		"band": 0,
		"chunk": chunk,
		"grid_cell": Vector3i(cell.x, level_of_height(cell_lowest_corner(cell)), cell.y),
		"face": K.Face.POS_Y,
		"quad": PackedVector3Array([
			Vector3(base.x, heights[0], base.y),
			Vector3(base.x + 1.0, heights[1], base.y),
			Vector3(base.x, heights[2], base.y + 1.0),
			Vector3(base.x + 1.0, heights[3], base.y + 1.0),
		]),
		"diagonal": cell_top_diagonal(cell),
		"paint_uid": cell_top_uid(cell),
	}


## Build one exact convex polygon per 1 m band of a stored side profile.
##
## Clipping the endpoint profile against horizontal bands preserves the real
## sloped boundary. Approximating each band as a rectangle is what left visible
## triangular holes where a stepped cell met a sloped cell.
func _side_face_records_for_edge(cell: Vector2i, edge: int) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var profile := side_face(cell, edge)
	if profile.is_empty():
		return records
	var bands := side_face_bands(cell, edge)
	var visible_bands: Array[Dictionary] = []
	for band_index: int in bands.size():
		var span: Array = bands[band_index]
		var polygon := _side_polygon_for_band(
			cell,
			edge,
			profile,
			float(span[0]),
			float(span[1])
		)
		if polygon.size() < 3:
			continue
		visible_bands.append({
			"band": band_index,
			"bottom_m": float(span[0]),
			"top_m": float(span[1]),
			"polygon": polygon,
		})
	for band_data: Dictionary in visible_bands:
		var band_index := int(band_data["band"])
		var bottom_m := float(band_data["bottom_m"])
		var top_m := float(band_data["top_m"])
		var texture_seed_uid := ""
		if top_m - bottom_m < THIN_SIDE_TEXTURE_SEED_MAX_HEIGHT_M:
			# A residual top or bottom strip borrows only from a complete 1 m square
			# on this same side grid. Keeping the seed as a derived UID preserves one
			# canonical painted source and leaves manual sliver paint authoritative.
			var sliver_centre := (bottom_m + top_m) * 0.5
			var nearest_distance := INF
			for candidate: Dictionary in visible_bands:
				var candidate_bottom := float(candidate["bottom_m"])
				var candidate_top := float(candidate["top_m"])
				if absf((candidate_top - candidate_bottom) - 1.0) > LEVEL_EPSILON_M:
					continue
				var distance := absf((candidate_bottom + candidate_top) * 0.5 - sliver_centre)
				if distance >= nearest_distance:
					continue
				nearest_distance = distance
				texture_seed_uid = band_uid(cell, edge, int(candidate["band"]))
		records.append({
			"kind": FaceKind.SIDE,
			"cell": cell,
			"edge": edge,
			"band": band_index,
			"chunk": Vector2i.ZERO,
			"grid_cell": Vector3i(cell.x, level_of_height(bottom_m), cell.y),
			"face": EDGE_GRID_FACES[edge],
			"bottom_m": bottom_m,
			"top_m": top_m,
			"start_t": float(profile[0]),
			"end_t": float(profile[1]),
			"polygon": band_data["polygon"],
			"paint_uid": band_uid(cell, edge, band_index),
			"texture_seed_uid": texture_seed_uid,
		})
	return records


## Clip one owned endpoint profile to a vertical band and return outward winding.
func _side_polygon_for_band(
	cell: Vector2i,
	edge: int,
	profile: Array,
	band_bottom_m: float,
	band_top_m: float
) -> PackedVector3Array:
	var profile_polygon: Array[Vector2] = [
		Vector2(float(profile[0]), float(profile[3])),
		Vector2(float(profile[1]), float(profile[5])),
		Vector2(float(profile[1]), float(profile[4])),
		Vector2(float(profile[0]), float(profile[2])),
	]
	profile_polygon = _clip_profile_polygon_y(profile_polygon, band_top_m, false)
	profile_polygon = _clip_profile_polygon_y(profile_polygon, band_bottom_m, true)
	profile_polygon = _deduplicate_profile_polygon(profile_polygon)
	var vertices := PackedVector3Array()
	if profile_polygon.size() < 3:
		return vertices
	var corner_indices: Array = EDGE_CORNER_INDICES[edge]
	var edge_start := Vector2(cell + CORNER_OFFSETS[int(corner_indices[0])])
	var edge_end := Vector2(cell + CORNER_OFFSETS[int(corner_indices[1])])
	for point: Vector2 in profile_polygon:
		var world_xz := edge_start.lerp(edge_end, point.x)
		vertices.append(Vector3(world_xz.x, point.y, world_xz.y))
	return vertices


## Clip a convex profile polygon against one horizontal half-plane.
func _clip_profile_polygon_y(
	points: Array[Vector2],
	height_m: float,
	keep_above: bool
) -> Array[Vector2]:
	var clipped: Array[Vector2] = []
	if points.is_empty():
		return clipped
	var previous := points[points.size() - 1]
	var previous_inside := (
		previous.y >= height_m - LEVEL_EPSILON_M
		if keep_above
		else previous.y <= height_m + LEVEL_EPSILON_M
	)
	for current: Vector2 in points:
		var current_inside := (
			current.y >= height_m - LEVEL_EPSILON_M
			if keep_above
			else current.y <= height_m + LEVEL_EPSILON_M
		)
		if current_inside != previous_inside:
			var delta_y := current.y - previous.y
			if absf(delta_y) > LEVEL_EPSILON_M:
				var travel := clampf((height_m - previous.y) / delta_y, 0.0, 1.0)
				clipped.append(previous.lerp(current, travel))
		if current_inside:
			clipped.append(current)
		previous = current
		previous_inside = current_inside
	return clipped


## Remove coincident clip vertices so zero-height endpoints become clean triangles.
func _deduplicate_profile_polygon(points: Array[Vector2]) -> Array[Vector2]:
	var unique: Array[Vector2] = []
	for point: Vector2 in points:
		if unique.is_empty() or not unique[unique.size() - 1].is_equal_approx(point):
			unique.append(point)
	if unique.size() > 1 and unique[0].is_equal_approx(unique[unique.size() - 1]):
		unique.remove_at(unique.size() - 1)
	return unique


## Build one exact polygon per 1 m band of the boundary skirt.
##
## A boundary edge is one whose neighbour is outside the footprint. Each polygon
## follows both top endpoints down to the authored absolute base plane, preserving
## the exact boundary topology of an imported Blender heightfield.
##
## The base plane is read ONCE here and passed down. skirt_base_m is a computed
## property whose getter scans every cell through lowest_top_height(), so reading
## it per boundary edge made this loop cost O(boundary_edges * total_cells) and
## dominated every sculpt stroke on a large imported map. Terrain cannot mutate
## while one enumeration runs, so the hoisted value is identical to what each
## individual read would have returned; this changes cost, never geometry.
func _skirt_face_records(scan: Rect2i) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var base_m := skirt_base_m
	for local_z: int in scan.size.y:
		for local_x: int in scan.size.x:
			var cell := scan.position + Vector2i(local_x, local_z)
			if not is_cell_filled(cell):
				continue
			for edge: int in 4:
				if is_cell_filled(cell + EDGE_NEIGHBOURS[edge]):
					continue
				var profile := _skirt_profile(cell, edge, base_m)
				if profile.is_empty():
					continue
				var highest := maxf(float(profile[3]), float(profile[5]))
				var bands := bands_in_span(base_m, highest)
				for band_index: int in bands.size():
					var span: Array = bands[band_index]
					var polygon := _side_polygon_for_band(
						cell,
						edge,
						profile,
						float(span[0]),
						float(span[1])
					)
					if polygon.size() < 3:
						continue
					records.append({
						"kind": FaceKind.SKIRT,
						"cell": cell,
						"edge": edge,
						"band": band_index,
						"chunk": Vector2i.ZERO,
						"grid_cell": Vector3i(
							cell.x,
							level_of_height(float(span[0])),
							cell.y
						),
						"face": EDGE_GRID_FACES[edge],
						"bottom_m": float(span[0]),
						"top_m": float(span[1]),
						"start_t": float(profile[0]),
						"end_t": float(profile[1]),
						"polygon": polygon,
						"paint_uid": "k:%d,%d,%d,%d" % [
							cell.x,
							cell.y,
							edge,
							band_index,
						],
					})
	return records


## Return the owned edge profile between one boundary slope and its base.
##
## When the authored surface crosses below the base, only the portion above the
## base is emitted; its zero-height crossing closes at one exact interpolated
## point rather than generating inverted shell geometry.
##
## The base plane arrives as a parameter because its source, skirt_base_m, is a
## computed property that rescans the whole heightfield on every read. Taking it
## once per enumeration in _skirt_face_records() keeps this function off that
## quadratic path; the value is the same one the property would have returned.
func _skirt_profile(cell: Vector2i, edge: int, base_m: float) -> Array:
	var corner_indices: Array = EDGE_CORNER_INDICES[edge]
	var start_top := cell_corner(cell, int(corner_indices[0]))
	var end_top := cell_corner(cell, int(corner_indices[1]))
	var start_gap := start_top - base_m
	var end_gap := end_top - base_m
	if start_gap <= LEVEL_EPSILON_M and end_gap <= LEVEL_EPSILON_M:
		return []
	if start_gap >= -LEVEL_EPSILON_M and end_gap >= -LEVEL_EPSILON_M:
		return [
			0.0,
			1.0,
			base_m,
			maxf(start_top, base_m),
			base_m,
			maxf(end_top, base_m),
		]
	var crossing_t := clampf(start_gap / (start_gap - end_gap), 0.0, 1.0)
	if start_gap > LEVEL_EPSILON_M:
		return [
			0.0,
			crossing_t,
			base_m,
			start_top,
			base_m,
			base_m,
		]
	return [
		crossing_t,
		1.0,
		base_m,
		base_m,
		base_m,
		end_top,
	]


## Grow the allocated rectangle to contain one cell rectangle, preserving data.
func expand_to_include(required_cells: Rect2i) -> bool:
	if required_cells.size.x <= 0 or required_cells.size.y <= 0:
		return false
	var required := required_cells.abs()
	var next_rect := required
	if not is_empty():
		next_rect = Rect2i(origin_cell, size_cells).merge(required)
	if (
		not is_empty()
		and next_rect.position == origin_cell
		and next_rect.size == size_cells
	):
		return false
	if next_rect.size.x > MAX_AXIS_CELLS or next_rect.size.y > MAX_AXIS_CELLS:
		push_error(
			"TerrainMesh: footprint %dx%d exceeds the %d cell limit."
			% [next_rect.size.x, next_rect.size.y, MAX_AXIS_CELLS]
		)
		return false

	var previous_origin := origin_cell
	var previous_size := size_cells
	var previous_mask := cell_mask
	var previous_tops := top_heights
	var previous_diagonals := top_diagonals
	var previous_sides := side_faces.duplicate(true)

	origin_cell = next_rect.position
	resize(next_rect.size)
	if previous_size.x <= 0 or previous_size.y <= 0:
		return true

	for local_z: int in previous_size.y:
		for local_x: int in previous_size.x:
			var source_index := local_z * previous_size.x + local_x
			var absolute := previous_origin + Vector2i(local_x, local_z)
			if previous_mask[source_index] != 0:
				set_cell_filled(absolute, true)
			var target_index := _top_index(absolute)
			if target_index < 0:
				continue
			for corner: int in 4:
				top_heights[target_index + corner] = previous_tops[source_index * 4 + corner]
			top_diagonals[target_index / 4] = previous_diagonals[source_index]
	# Side faces are keyed by absolute cell, so they survive verbatim.
	side_faces = previous_sides
	return true


## Return an independent copy.
func duplicate_terrain() -> TerrainMesh:
	var copy := TerrainMesh.new()
	copy.origin_cell = origin_cell
	copy.size_cells = size_cells
	copy.cell_mask = cell_mask.duplicate()
	copy.top_heights = top_heights.duplicate()
	copy.top_diagonals = top_diagonals.duplicate()
	copy.side_faces = side_faces.duplicate(true)
	copy.skirt_depth_m = skirt_depth_m
	return copy


## Return an independent copy containing only one absolute cell rectangle.
##
## Contact-flatten previews use this bounded copy so distant instances never make
## an atomic undo calculation duplicate or scan terrain between their footprints.
func duplicate_region(bounds: Rect2i) -> TerrainMesh:
	var clipped := Rect2i(origin_cell, size_cells).intersection(bounds)
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return TerrainMesh.new()
	var copy := TerrainMesh.create(clipped.position, clipped.size)
	copy.skirt_depth_m = skirt_depth_m
	for local_z: int in clipped.size.y:
		for local_x: int in clipped.size.x:
			var cell := clipped.position + Vector2i(local_x, local_z)
			var source_index := _top_index(cell)
			var destination_index := copy._top_index(cell)
			if source_index < 0 or destination_index < 0:
				continue
			var source_cell_index := source_index / 4
			var destination_cell_index := destination_index / 4
			copy.cell_mask[destination_cell_index] = cell_mask[source_cell_index]
			copy.top_diagonals[destination_cell_index] = (
				top_diagonals[source_cell_index]
			)
			for corner: int in 4:
				copy.top_heights[destination_index + corner] = (
					top_heights[source_index + corner]
				)
	for key_value: Variant in side_faces.keys():
		var key := String(key_value)
		var parts := key.split(",")
		if parts.size() != 3:
			continue
		var cell := Vector2i(int(parts[0]), int(parts[1]))
		if clipped.has_point(cell):
			copy.side_faces[key] = (side_faces[key_value] as Array).duplicate()
	return copy


## Validate the stored schema without reference to any board.
func validate_definition() -> PackedStringArray:
	var errors := PackedStringArray()
	if size_cells.x < 0 or size_cells.y < 0:
		errors.append("terrain has negative size %s" % size_cells)
		return errors
	if size_cells.x > MAX_AXIS_CELLS or size_cells.y > MAX_AXIS_CELLS:
		errors.append(
			"terrain %dx%d exceeds the %d cell limit"
			% [size_cells.x, size_cells.y, MAX_AXIS_CELLS]
		)
	if not is_finite(skirt_depth_m) or skirt_depth_m <= 0.0:
		errors.append("terrain skirt depth must be a positive finite distance")
	if is_empty():
		if (
			not cell_mask.is_empty()
			or not top_heights.is_empty()
			or not top_diagonals.is_empty()
		):
			errors.append("empty terrain must not store mask or face data")
		return errors
	var count := size_cells.x * size_cells.y
	if cell_mask.size() != count:
		errors.append(
			"terrain mask holds %d entries but the %dx%d footprint needs %d"
			% [cell_mask.size(), size_cells.x, size_cells.y, count]
		)
	if top_heights.size() != count * 4:
		errors.append(
			"terrain top faces hold %d entries but %d cells need %d"
			% [top_heights.size(), count, count * 4]
		)
	if top_diagonals.size() != count:
		errors.append(
			"terrain top diagonals hold %d entries but %d cells need %d"
			% [top_diagonals.size(), count, count]
		)
	for diagonal: int in top_diagonals:
		if diagonal < 0 or diagonal > 1:
			errors.append("terrain top-face diagonal %d is not 0 or 1" % diagonal)
			break
	for height: float in top_heights:
		if not is_finite(height):
			errors.append("terrain top-face height is not finite")
			break
	for key: Variant in side_faces.keys():
		var profile_value: Variant = side_faces[key]
		if not profile_value is Array or (profile_value as Array).size() != 6:
			errors.append("terrain side face '%s' needs one six-value endpoint profile" % key)
			continue
		var profile: Array = profile_value
		var finite_profile := true
		for value: Variant in profile:
			if not is_finite(float(value)):
				finite_profile = false
				break
		if not finite_profile:
			errors.append("terrain side face '%s' contains a non-finite value" % key)
			continue
		if (
			float(profile[0]) < 0.0
			or float(profile[1]) > 1.0
			or float(profile[1]) - float(profile[0]) <= EDGE_PARAMETER_EPSILON
		):
			errors.append("terrain side face '%s' has an invalid edge range" % key)
		if (
			float(profile[3]) + LEVEL_EPSILON_M < float(profile[2])
			or float(profile[5]) + LEVEL_EPSILON_M < float(profile[4])
		):
			errors.append("terrain side face '%s' has a top below its bottom" % key)
	return errors


## Serialize the canonical footprint, top faces, and side faces.
func to_json() -> Dictionary:
	var tops := []
	tops.resize(top_heights.size())
	for index: int in top_heights.size():
		tops[index] = top_heights[index]
	var mask := []
	mask.resize(cell_mask.size())
	for index: int in cell_mask.size():
		mask[index] = int(cell_mask[index])
	var diagonals := []
	diagonals.resize(top_diagonals.size())
	for index: int in top_diagonals.size():
		diagonals[index] = int(top_diagonals[index])
	return {
		"origin_cell": [origin_cell.x, origin_cell.y],
		"size_cells": [size_cells.x, size_cells.y],
		"cell_mask": mask,
		"top_heights": tops,
		"top_diagonals": diagonals,
		"side_faces": side_faces.duplicate(true),
		"skirt_depth_m": skirt_depth_m,
	}


## Parse one saved terrain without inventing missing faces.
static func from_json(data: Dictionary) -> TerrainMesh:
	var terrain := TerrainMesh.new()
	var origin_values: Array = data.get("origin_cell", [])
	if origin_values.size() >= 2:
		terrain.origin_cell = Vector2i(int(origin_values[0]), int(origin_values[1]))
	var size_values: Array = data.get("size_cells", [])
	if size_values.size() >= 2:
		terrain.size_cells = Vector2i(int(size_values[0]), int(size_values[1]))
	var mask_values: Array = data.get("cell_mask", [])
	terrain.cell_mask = PackedByteArray()
	terrain.cell_mask.resize(mask_values.size())
	for index: int in mask_values.size():
		terrain.cell_mask[index] = 1 if int(mask_values[index]) != 0 else 0
	var top_values: Array = data.get("top_heights", [])
	terrain.top_heights = PackedFloat32Array()
	terrain.top_heights.resize(top_values.size())
	for index: int in top_values.size():
		terrain.top_heights[index] = float(top_values[index])
	var diagonal_values: Array = data.get("top_diagonals", [])
	var cell_count := terrain.size_cells.x * terrain.size_cells.y
	terrain.top_diagonals = PackedByteArray()
	terrain.top_diagonals.resize(cell_count)
	if diagonal_values.size() == cell_count:
		for index: int in diagonal_values.size():
			terrain.top_diagonals[index] = clampi(int(diagonal_values[index]), 0, 1)
	else:
		# Boards saved before diagonals became explicit reproduce the exact
		# deterministic choice their renderer previously made from the heights.
		for local_z: int in terrain.size_cells.y:
			for local_x: int in terrain.size_cells.x:
				terrain._refresh_cell_top_diagonal(
					terrain.origin_cell + Vector2i(local_x, local_z)
				)
	var side_values: Variant = data.get("side_faces", {})
	if side_values is Dictionary:
		for key: Variant in (side_values as Dictionary).keys():
			var profile_value: Variant = (side_values as Dictionary)[key]
			if not profile_value is Array:
				continue
			var profile: Array = profile_value
			if profile.size() == 6:
				terrain.side_faces[String(key)] = [
					float(profile[0]),
					float(profile[1]),
					float(profile[2]),
					float(profile[3]),
					float(profile[4]),
					float(profile[5]),
				]
			elif profile.size() == 2:
				# Saved scalar walls are migrated explicitly into one full-edge
				# rectangle; this preserves their authored geometry without
				# inventing slope endpoint information that was never stored.
				terrain.side_faces[String(key)] = [
					0.0,
					1.0,
					float(profile[0]),
					float(profile[1]),
					float(profile[0]),
					float(profile[1]),
				]
	terrain.skirt_depth_m = float(data.get("skirt_depth_m", 1.0))
	return terrain
