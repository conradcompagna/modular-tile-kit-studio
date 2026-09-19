@tool
class_name TerrainSculptor
extends RefCounted

## Every sculpt operation that may write the canonical TerrainMesh.
##
## Two brush families, one surface
## ------------------------------
## The families differ in WHAT they move, and that difference is exactly the
## difference between a step and a slope:
##
##   STEP family   (STEP_UP, STEP_DOWN, QUANTIZE)
##       moves whole CELLS through TerrainMesh.set_cell_top_level(). A cell's
##       neighbours keep their own heights at the shared grid corner, so the
##       height difference that appears at the seam becomes a REAL VERTICAL WALL.
##       This is the blockout brush: pull a grid square up by the level height and
##       you get a square with four walls, not a mound.
##
##   SLOPE family  (RAISE, LOWER, FLATTEN, SMOOTH)
##       moves GRID CORNERS through TerrainMesh.set_lattice_corner_height(). Every
##       cell meeting that corner takes the identical height, so they genuinely
##       share it and the surface between them is continuous. This is the terrain
##       brush.
##
## Both families write the same TerrainMesh, so they coexist in one document and
## blend freely: running a slope brush across a stepped plateau simply moves the
## corners the step brush set, and any drop that survives is still a wall.
##
## Every brush uses one exact square footprint measured in whole metres. Footprint,
## stepped, and smooth tools derive from the same selected cells, so the targeter
## and every mutation path always agree.

const K := preload("../utils/mts_constants.gd")

## What a stroke does to the terrain it touches.
enum Mode {
	## Move whole cells by fixed level increments, creating real walls at the
	## seams. This is the verticality blockout brush.
	STEP_UP,
	STEP_DOWN,
	## Add or remove height with a smooth radial falloff for hills and hollows.
	RAISE,
	LOWER,
	## Pull corners toward one exact level sampled when the stroke began.
	FLATTEN,
	## Average neighbouring corners to soften whatever is already there.
	SMOOTH,
	## Snap whole cells to the nearest multiple of the step height, converting
	## organic relief into the crisp planes and walls architecture needs.
	QUANTIZE,
	## Pull whole stepped cells to the sampled level or a neighbour-smoothed level.
	STEP_FLATTEN,
	STEP_SMOOTH,
}

## The brush settings one stroke applies. Grouping them keeps the viewport's
## per-stroke call sites short and makes every value that shaped a stroke
## visible in one place.
class Settings extends RefCounted:
	var mode: int = Mode.STEP_UP
	## Full square side length in whole metres.
	var size_m: float = 1.0
	## Fixed increment used by the step and quantize modes.
	var step_m: float = 0.5
	## Blend amount for the continuous modes, 0..1.
	var strength: float = 0.5
	## Exact level the flatten mode pulls toward, sampled at stroke start.
	var flatten_target_m: float = 0.0
	## When true, slope modes refuse to move a corner that a real wall stands on.
	##
	## Only the SLOPE family can destroy a wall, because moving a shared grid
	## corner is exactly the operation that closes a vertical drop. The STEP family
	## creates walls rather than removing them, so this never restricts it.
	var protect_walls: bool = false

	## Build one independent copy so a live stroke cannot be changed by the UI mid-drag.
	func duplicate_settings() -> Settings:
		var copy := Settings.new()
		copy.mode = mode
		copy.size_m = size_m
		copy.step_m = step_m
		copy.strength = strength
		copy.flatten_target_m = flatten_target_m
		copy.protect_walls = protect_walls
		return copy


## Metres a full-strength continuous stroke moves terrain per applied pulse.
## The previous 0.25 m maximum is now one quarter of the visible Strength range,
## while maximum Strength produces a deliberately strong 1 m terrain change.
const RAISE_METRES_AT_FULL_STRENGTH: float = 1.0

var _grid: TerrainMesh
var _settings: Settings = Settings.new()

## Sparse per-stroke record of the state before this stroke touched it.
##
## Both halves are needed because a step edit changes two things at once: the
## cell's own top face, and the side faces along every seam around it. Recording
## only the heights would make undo re-derive walls rather than restore the ones
## that were actually there, which would silently rewrite an imported map's
## authored walls on the first undo.
var _stroke_active: bool = false
var _stroke_cells_before: Dictionary = {}
var _stroke_sides_before: Dictionary = {}
## Maximum weight each corner has received during the active stroke. Recording the
## maximum rather than accumulating makes one drag independent of pointer event
## rate, so a slow drag and a fast drag over the same path give the same result.
var _stroke_max_weights: Dictionary = {}
## Heights captured when the current pointer or held pulse first reaches a corner.
##
## Flatten reads this pulse-local source so repeated input events inside one pulse
## stay normalized, while an intentional hold can start a new pulse and continue
## converging toward the visible target.
var _pulse_corner_heights: Dictionary = {}
## Cells already stepped by the active stroke. A step brush must move a cell by
## exactly one increment per stroke no matter how many times the pointer crosses
## it, or a single drag would stack many levels.
var _stroke_stepped: Dictionary = {}


## Bind the canonical terrain every stroke will write.
func _init(grid: TerrainMesh) -> void:
	_grid = grid


## Replace the brush settings used by subsequent strokes.
func configure(settings: Settings) -> void:
	_settings = settings.duplicate_settings()


## Return the settings currently applied to new strokes.
func settings() -> Settings:
	return _settings


## Return whether a stroke is currently recording.
func is_stroke_active() -> bool:
	return _stroke_active


## Return whether one mode moves whole cells rather than shared grid corners.
##
## This single predicate is what separates the two brush families, so no call site
## has to re-derive the distinction and they cannot drift apart.
static func mode_is_cell_based(mode: int) -> bool:
	return (
		mode == Mode.STEP_UP
		or mode == Mode.STEP_DOWN
		or mode == Mode.QUANTIZE
		or mode == Mode.STEP_FLATTEN
		or mode == Mode.STEP_SMOOTH
	)


## Begin one sculpt transaction that records only what it actually moves.
func begin_stroke() -> void:
	if _stroke_active:
		push_error("TerrainSculptor: cannot begin a stroke while another is active.")
		return
	_stroke_active = true
	_stroke_cells_before.clear()
	_stroke_sides_before.clear()
	_stroke_max_weights.clear()
	_pulse_corner_heights.clear()
	_stroke_stepped.clear()


## Begin one time-based brush pulse while preserving the stroke's original undo state.
##
## Clearing only influence guards lets a held pointer apply another deterministic
## increment; the before-state dictionaries remain intact so mouse-down through
## mouse-up still commits as one undo action.
func begin_pulse() -> void:
	if not _stroke_active:
		push_error("TerrainSculptor: cannot pulse outside an active stroke.")
		return
	_stroke_max_weights.clear()
	_pulse_corner_heights.clear()
	_stroke_stepped.clear()


## Record one cell's top face and every side face around it, once per stroke.
##
## The neighbours' side faces are captured too because raising a cell can remove a
## wall its neighbour owned, and undo has to put that wall back.
func _record_cell(cell: Vector2i) -> void:
	if not _stroke_active or _stroke_cells_before.has(cell):
		return
	_stroke_cells_before[cell] = _grid.cell_top(cell)
	var neighbourhood: Array[Vector2i] = [cell]
	for edge: int in 4:
		neighbourhood.append(cell + TerrainMesh.EDGE_NEIGHBOURS[edge])
	for around: Vector2i in neighbourhood:
		for edge: int in 4:
			var key := TerrainMesh.side_key(around, edge)
			if not _stroke_sides_before.has(key):
				_stroke_sides_before[key] = _grid.side_face(around, edge).duplicate()


## Record every cell meeting one grid corner before a slope edit moves them.
func _record_corner(corner: Vector2i) -> void:
	for index: int in 4:
		var cell := corner - TerrainMesh.CORNER_OFFSETS[index]
		if _grid.is_cell_filled(cell):
			_record_cell(cell)


## Finish the active stroke and return its compact before/after undo patch.
##
## Cells and side faces whose state did not actually change are dropped, so a
## stroke that merely passed over already-correct terrain registers no undo step.
func finish_stroke() -> Dictionary:
	if not _stroke_active:
		return {}
	var cells := PackedVector2Array()
	var before_tops := PackedFloat32Array()
	var after_tops := PackedFloat32Array()
	for key: Variant in _stroke_cells_before.keys():
		var cell: Vector2i = key
		var before: PackedFloat32Array = _stroke_cells_before[key]
		var after := _grid.cell_top(cell)
		var moved := false
		for corner: int in 4:
			if not is_equal_approx(before[corner], after[corner]):
				moved = true
				break
		if not moved:
			continue
		cells.append(Vector2(cell))
		for corner: int in 4:
			before_tops.append(before[corner])
			after_tops.append(after[corner])

	var before_sides: Dictionary = {}
	var after_sides: Dictionary = {}
	for key: Variant in _stroke_sides_before.keys():
		var side_key := String(key)
		var before_span: Array = _stroke_sides_before[key]
		var after_span := _side_profile_by_key(side_key)
		if _profiles_match(before_span, after_span):
			continue
		before_sides[side_key] = before_span
		after_sides[side_key] = after_span

	_stroke_active = false
	_stroke_cells_before.clear()
	_stroke_sides_before.clear()
	_stroke_max_weights.clear()
	_pulse_corner_heights.clear()
	_stroke_stepped.clear()
	if cells.is_empty() and before_sides.is_empty():
		return {}
	return {
		"cells": cells,
		"before_tops": before_tops,
		"after_tops": after_tops,
		"before_sides": before_sides,
		"after_sides": after_sides,
	}


## Return the live endpoint profile stored under one "x,z,edge" key.
func _side_profile_by_key(key: String) -> Array:
	var parts := key.split(",")
	if parts.size() != 3:
		return []
	return _grid.side_face(
		Vector2i(int(parts[0]), int(parts[1])),
		int(parts[2])
	).duplicate()


## Return whether two side-face endpoint profiles describe the same wall.
func _profiles_match(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for index: int in first.size():
		if not is_equal_approx(float(first[index]), float(second[index])):
			return false
	return true


## Discard the active stroke recorder without reverting canonical terrain.
func cancel_stroke() -> void:
	_stroke_active = false
	_stroke_cells_before.clear()
	_stroke_sides_before.clear()
	_stroke_max_weights.clear()
	_pulse_corner_heights.clear()
	_stroke_stepped.clear()


## Apply one validated undo/redo patch to the canonical terrain.
##
## Top faces and side faces are both written literally rather than re-derived, so
## undoing a stroke over imported terrain restores the walls the file authored
## instead of substituting walls derived from the corner heights.
##
## Returns the absolute cell rectangle the patch touched so the caller can rebuild
## exactly the affected terrain rather than the whole board.
func apply_patch(
	cells: PackedVector2Array,
	tops: PackedFloat32Array,
	sides: Dictionary
) -> Rect2i:
	if cells.size() * 4 != tops.size():
		push_error("TerrainSculptor: patch needs exactly four top heights per cell.")
		return Rect2i()
	var touched := _CellBounds.new()
	for index: int in cells.size():
		var cell := Vector2i(cells[index])
		var heights := PackedFloat32Array([
			tops[index * 4],
			tops[index * 4 + 1],
			tops[index * 4 + 2],
			tops[index * 4 + 3],
		])
		if _grid.set_cell_top(cell, heights):
			touched.include(cell)
	for key: Variant in sides.keys():
		var parts := String(key).split(",")
		if parts.size() != 3:
			continue
		var cell := Vector2i(int(parts[0]), int(parts[1]))
		var edge := int(parts[2])
		var profile: Array = sides[key]
		if profile.size() == 6:
			_grid.set_side_face_profile(
				cell,
				edge,
				float(profile[0]),
				float(profile[1]),
				float(profile[2]),
				float(profile[3]),
				float(profile[4]),
				float(profile[5])
			)
		else:
			_grid.clear_side_face(cell, edge)
		touched.include(cell)
	return touched.bounds()


## Apply one brush sample at a world XZ point and return the cells it changed.
func stamp(world_xz: Vector2) -> Rect2i:
	return stamp_segment(world_xz, world_xz)


## Apply one continuous swept brush segment between two pointer samples.
##
## Sweeping rather than stamping separate discs is what keeps a fast drag from
## leaving a row of disconnected craters.
func stamp_segment(start_world_xz: Vector2, end_world_xz: Vector2) -> Rect2i:
	if _grid == null or _grid.is_empty():
		return Rect2i()
	if mode_is_cell_based(_settings.mode):
		return _stamp_cells(start_world_xz, end_world_xz)
	return _stamp_corners(start_world_xz, end_world_xz)


## Return the exact filled cells a cell-based stamp would edit at one target.
##
## The viewport uses this same query for its targeter, so the highlighted cells
## and the cells passed to the mutation path cannot drift into separate footprints.
func cell_targets(world_xz: Vector2) -> PackedVector2Array:
	return _cell_targets_for_segment(world_xz, world_xz)


## Return the canonical square cell footprint reached by one swept brush.
##
## Size is a whole-metre side length: 1 m selects one cell, 2 m selects an exact
## 2 x 2 square, and 3 m selects an exact 3 x 3 square. The segment traversal
## visits every grid cell crossed by the pointer, then expands that anchor into
## the same square used by footprint, stepped, and smooth terrain tools.
static func brush_cell_targets(
	start_world_xz: Vector2,
	end_world_xz: Vector2,
	size_m: float
) -> PackedVector2Array:
	var targets := PackedVector2Array()
	var included: Dictionary = {}
	var side_cells := maxi(roundi(size_m), 1)
	var lower_offset := (side_cells - 1) / 2
	for anchor: Vector2i in _segment_anchor_cells(start_world_xz, end_world_xz):
		var square_origin := anchor - Vector2i(lower_offset, lower_offset)
		for local_z: int in side_cells:
			for local_x: int in side_cells:
				var cell := square_origin + Vector2i(local_x, local_z)
				if included.has(cell):
					continue
				included[cell] = true
				targets.append(Vector2(cell))
	return targets


## Return each grid cell crossed by the pointer segment in traversal order.
##
## Grid DDA avoids gaps during fast drags without making the result depend on how
## many input events Godot delivered. An axis stops as soon as it reaches its
## destination coordinate, and the Manhattan cell distance is a hard iteration
## bound, so floating-point boundary noise can never overshoot into an endless loop.
static func _segment_anchor_cells(
	start_world_xz: Vector2,
	end_world_xz: Vector2
) -> Array[Vector2i]:
	var anchors: Array[Vector2i] = []
	if not start_world_xz.is_finite() or not end_world_xz.is_finite():
		push_error("TerrainSculptor: a brush segment requires finite world coordinates.")
		return anchors
	var current := Vector2i(floori(start_world_xz.x), floori(start_world_xz.y))
	var destination := Vector2i(floori(end_world_xz.x), floori(end_world_xz.y))
	anchors.append(current)
	if current == destination:
		return anchors

	var delta: Vector2 = end_world_xz - start_world_xz
	# Mouse-ray deltas are fractional metres. Derive the integer direction from
	# the float sign explicitly; signi() would truncate sub-metre deltas to zero
	# and leave the traversal unable to reach a different destination cell.
	var step_x: int = 1 if delta.x > 0.0 else (-1 if delta.x < 0.0 else 0)
	var step_y: int = 1 if delta.y > 0.0 else (-1 if delta.y < 0.0 else 0)
	var t_delta_x: float = absf(1.0 / delta.x) if step_x != 0 else INF
	var t_delta_y: float = absf(1.0 / delta.y) if step_y != 0 else INF
	var next_x: float = float(current.x + 1) if step_x > 0 else float(current.x)
	var next_y: float = float(current.y + 1) if step_y > 0 else float(current.y)
	var t_max_x: float = (
		(next_x - start_world_xz.x) / delta.x
		if step_x != 0
		else INF
	)
	var t_max_y: float = (
		(next_y - start_world_xz.y) / delta.y
		if step_y != 0
		else INF
	)
	var remaining_steps: int = (
		absi(destination.x - current.x)
		+ absi(destination.y - current.y)
	)

	while current != destination and remaining_steps > 0:
		var can_step_x: bool = current.x != destination.x
		var can_step_y: bool = current.y != destination.y
		if can_step_x and can_step_y and t_max_x == t_max_y:
			current += Vector2i(step_x, step_y)
			t_max_x += t_delta_x
			t_max_y += t_delta_y
		elif can_step_x and (not can_step_y or t_max_x < t_max_y):
			current.x += step_x
			t_max_x += t_delta_x
		elif can_step_y:
			current.y += step_y
			t_max_y += t_delta_y
		else:
			break
		anchors.append(current)
		remaining_steps -= 1
	if current != destination:
		push_error(
			"TerrainSculptor: brush traversal exhausted its finite cell bound."
		)
		return []
	return anchors


## Return every filled cell reached by one swept cell-based brush segment.
func _cell_targets_for_segment(
	start_world_xz: Vector2,
	end_world_xz: Vector2
) -> PackedVector2Array:
	var targets := PackedVector2Array()
	for target: Vector2 in brush_cell_targets(
		start_world_xz,
		end_world_xz,
		_settings.size_m
	):
		if _grid.is_cell_filled(Vector2i(target)):
			targets.append(target)
	return targets


## Move whole cells, so every seam the stroke creates becomes a real wall.
func _stamp_cells(start_world_xz: Vector2, end_world_xz: Vector2) -> Rect2i:
	var touched := _CellBounds.new()
	for target: Vector2 in _cell_targets_for_segment(start_world_xz, end_world_xz):
		var cell := Vector2i(target)
		if _apply_cell(cell):
			touched.include(cell)
	return touched.bounds()


## Move the shared corners of the exact square cells reached by this stroke.
##
## Deriving slope corners from the canonical cell targets makes Size mean the
## same visible square for footprint, stepped, and smooth tools. Each corner is
## applied once even when several targeted cells share it.
func _stamp_corners(start_world_xz: Vector2, end_world_xz: Vector2) -> Rect2i:
	var touched := _CellBounds.new()
	var included_corners: Dictionary = {}
	for target: Vector2 in brush_cell_targets(
		start_world_xz,
		end_world_xz,
		_settings.size_m
	):
		var cell := Vector2i(target)
		for corner_offset: Vector2i in TerrainMesh.CORNER_OFFSETS:
			var corner := cell + corner_offset
			if included_corners.has(corner):
				continue
			included_corners[corner] = true
			if not _corner_touches_footprint(corner):
				continue
			if _apply_corner(corner, 1.0):
				# A corner belongs to the four cells around it, so all four need
				# their geometry rebuilt.
				touched.include(corner - Vector2i.ONE)
				touched.include(corner)
	return touched.bounds()


## Return whether any cell sharing this corner is part of the drawn footprint.
##
## Sculpting is confined to the authored encounter footprint, so a stroke that
## strays past the edge cannot lift terrain that is not part of the map.
func _corner_touches_footprint(corner: Vector2i) -> bool:
	return (
		_grid.is_cell_filled(corner)
		or _grid.is_cell_filled(corner - Vector2i(1, 0))
		or _grid.is_cell_filled(corner - Vector2i(0, 1))
		or _grid.is_cell_filled(corner - Vector2i(1, 1))
	)


## Record one corner's pre-stroke state and return its usable delta weight.
##
## The returned weight is the increase over the maximum this corner has already
## received in the active stroke, so repeated passes converge on the brush's
## shape instead of compounding into ridges.
func _corner_stroke_weight(corner: Vector2i, weight: float) -> float:
	if not _stroke_active:
		return weight
	_record_corner(corner)
	var previous := float(_stroke_max_weights.get(corner, 0.0))
	if weight <= previous:
		return 0.0
	_stroke_max_weights[corner] = weight
	return weight - previous


## Return the height this corner had when the current pulse first reached it.
##
## One pulse stays independent of pointer event rate, while begin_pulse() clears
## this snapshot so a deliberate hold can continue converging toward its target.
func _corner_pulse_start_height(corner: Vector2i) -> float:
	if not _stroke_active:
		return _grid.lattice_top_height(corner)
	if _pulse_corner_heights.has(corner):
		return float(_pulse_corner_heights[corner])
	var height_m: float = _grid.lattice_top_height(corner)
	_pulse_corner_heights[corner] = height_m
	return height_m


## Apply the active cell mode to one whole cell and report whether it moved.
##
## Every mode here moves the cell alone, which is what leaves the neighbours in
## place and turns the resulting height difference into a real wall.
func _apply_cell(cell: Vector2i) -> bool:
	if _stroke_stepped.has(cell):
		return false
	_stroke_stepped[cell] = true
	_record_cell(cell)
	var step := maxf(_settings.step_m, 0.001)
	match _settings.mode:
		Mode.STEP_UP:
			return _apply_cell_step(cell, step, 1)
		Mode.STEP_DOWN:
			return _apply_cell_step(cell, step, -1)
		Mode.QUANTIZE:
			# Snapping the whole cell to one level is what converts organic relief
			# into an architectural plane; the drop to its neighbours then becomes
			# a wall rather than a smeared transition.
			var snapped := roundf(_grid.cell_walk_height(cell) / step) * step
			return _grid.set_cell_top_level(cell, snapped)
		Mode.STEP_FLATTEN:
			var flatten_level := roundf(_settings.flatten_target_m / step) * step
			return _grid.set_cell_top_level(cell, flatten_level)
		Mode.STEP_SMOOTH:
			var smooth_level := roundf(_cell_neighbour_average(cell) / step) * step
			return _grid.set_cell_top_level(cell, smooth_level)
	return false


## Return the mean walk height of one stepped cell and its filled neighbours.
##
## The result is quantized by STEP_SMOOTH so smoothing reduces abrupt level noise
## while retaining whole flat cells and explicit vertical walls.
func _cell_neighbour_average(cell: Vector2i) -> float:
	var total := _grid.cell_walk_height(cell)
	var count := 1.0
	for offset: Vector2i in TerrainMesh.EDGE_NEIGHBOURS:
		var neighbour := cell + offset
		if not _grid.is_cell_filled(neighbour):
			continue
		total += _grid.cell_walk_height(neighbour)
		count += 1.0
	return total / count


## Move one cell by exactly one fixed level, landing on an exact multiple.
##
## Stepping ignores brush falloff entirely. That is what keeps blocked-out terrain
## perfectly flat and its cells upright, and what makes two separately drawn areas
## at the same level meet flush with no seam.
func _apply_cell_step(cell: Vector2i, step: float, direction: int) -> bool:
	var current := _grid.cell_walk_height(cell)
	var level := roundi(current / step)
	var on_level := absf(current - float(level) * step) <= TerrainMesh.LEVEL_EPSILON_M
	if not on_level:
		# Terrain that is between levels resolves toward the stroke direction, so
		# stepping up from 0.3 with a 0.5 step reaches 0.5 rather than 1.0.
		level = ceili(current / step) if direction > 0 else floori(current / step)
	else:
		level += direction
	return _grid.set_cell_top_level(cell, float(level) * step)


## Apply the active slope mode to one grid corner and report whether it moved.
##
## Every mode here moves the corner for ALL cells that meet it, which is what
## makes them share it and produces a continuous slope rather than a step.
func _apply_corner(corner: Vector2i, weight: float) -> bool:
	# Protect Walls stops the stroke exactly where a wall stands. Moving this
	# corner would give every cell meeting it the same height, which is what
	# closes a vertical drop; refusing the write leaves the authored wall intact
	# and lets the rest of the stroke continue around it.
	if _settings.protect_walls and _grid.corner_carries_side_face(corner):
		return false
	var current := _grid.lattice_top_height(corner)
	match _settings.mode:
		Mode.FLATTEN:
			var flatten_weight := _corner_stroke_weight(corner, weight)
			if flatten_weight <= 0.0:
				return false
			var original := _corner_pulse_start_height(corner)
			var blend := clampf(
				float(_stroke_max_weights.get(corner, weight))
					* clampf(_settings.strength, 0.0, 1.0),
				0.0,
				1.0
			)
			return _grid.set_lattice_corner_height(
				corner,
				lerpf(original, _settings.flatten_target_m, blend)
			)
		Mode.SMOOTH:
			var smooth_weight := _corner_stroke_weight(corner, weight)
			if smooth_weight <= 0.0:
				return false
			return _grid.set_lattice_corner_height(
				corner,
				lerpf(
					current,
					_neighbour_average(corner),
					smooth_weight * clampf(_settings.strength, 0.0, 1.0)
				)
			)
		Mode.RAISE, Mode.LOWER:
			var delta_weight := _corner_stroke_weight(corner, weight)
			if delta_weight <= 0.0:
				return false
			var direction := 1.0 if _settings.mode == Mode.RAISE else -1.0
			var delta := (
				RAISE_METRES_AT_FULL_STRENGTH
				* clampf(_settings.strength, 0.0, 1.0)
				* direction
				* delta_weight
			)
			return _grid.set_lattice_corner_height(corner, current + delta)
	return false


## Return the mean height of one corner and its four lattice neighbours.
##
## Only corners inside the footprint contribute, so smoothing along the boundary
## does not drag the edge toward terrain that does not exist.
func _neighbour_average(corner: Vector2i) -> float:
	var total := _grid.lattice_top_height(corner)
	var count := 1.0
	for offset: Vector2i in [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1),
	]:
		var neighbour := corner + offset
		if not _grid.has_corner_coordinate(neighbour):
			continue
		if not _corner_touches_footprint(neighbour):
			continue
		total += _grid.lattice_top_height(neighbour)
		count += 1.0
	return total / count


## Level every footprint quad onto one plane as a step, walls included.
##
## This is set_cell_top_level, the step operation TerrainMesh documents: all four
## of a cell's own corners move together and NO neighbouring cell is touched, so
## every height difference that appears at a seam is rebuilt as a real vertical
## side face. Corners are deliberately never written one at a time here. A quad
## with two corners moved and two left behind is not a preserved wall: it is a
## non-planar saddle whose triangulation flips, sitting beside a stale side face
## that no longer reaches it, which is exactly how the surface tore.
##
## No corner needs protecting for a wall to survive. Because each cell stores its
## own four corners, the cell across a seam keeps its authored heights no matter
## what the footprint does, and the wall between them is re-derived at its new
## height by the rebuild.
func flatten_cells(cells: Array[Vector2i], height_m: float) -> Dictionary:
	if not _stroke_active:
		push_error("TerrainSculptor: flatten_cells requires an active stroke.")
		return {"bounds": Rect2i(), "flattened_cell_count": 0}

	var touched := _CellBounds.new()
	var flattened_cell_count := 0
	for cell: Vector2i in cells:
		if not _grid.is_cell_filled(cell):
			continue
		# _record_cell snapshots this cell's top plus the side faces of it and its
		# four neighbours -- precisely the twenty side keys set_cell_top_level goes
		# on to rebuild -- so the undo patch carries every wall the step changes.
		_record_cell(cell)
		if _grid.set_cell_top_level(cell, height_m):
			touched.include(cell)
			flattened_cell_count += 1
	return {
		"bounds": touched.bounds(),
		"flattened_cell_count": flattened_cell_count,
	}


## Return whether a real wall stands on one exact quad corner, owned by either side.
##
## A side face is stored once, on whichever cell of a seam is the higher one, so
## asking only the quad about to be written would miss a wall its neighbour owns
## and then shorten it. Both seams incident to the corner are inspected from both
## sides. Only the two edges that actually meet the corner can match, because
## side_face_touches_corner rejects an endpoint the stored profile does not reach.
func _quad_corner_carries_wall(cell: Vector2i, local_corner: int) -> bool:
	var corner := cell + TerrainMesh.CORNER_OFFSETS[local_corner]
	for edge: int in 4:
		if _grid.side_face_touches_corner(cell, edge, local_corner):
			return true
		var neighbour := cell + TerrainMesh.EDGE_NEIGHBOURS[edge]
		if not _grid.is_cell_filled(neighbour):
			continue
		var neighbour_corner := _grid.local_corner_index(neighbour, corner)
		if neighbour_corner < 0:
			continue
		if _grid.side_face_touches_corner(neighbour, (edge + 2) % 4, neighbour_corner):
			return true
	return false


## Rebuild the derived vertical closure around every cell one contact write moved.
##
## TerrainMesh derives each side face from the height difference between the two
## cells meeting at a seam, so a corner written directly leaves the old wall
## profile describing heights that no longer exist -- the wall stops reaching the
## ground and the surface reads as torn. Both cells of every affected seam are
## rebuilt, which is the same neighbourhood set_cell_top_level() covers for one
## stepped cell. It runs once after every write so a seam between two footprint
## cells is never derived while the second cell still holds its old height.
func _rebuild_contact_side_faces(written_cells: Dictionary) -> void:
	var rebuilt: Dictionary = {}
	for key: Variant in written_cells:
		var cell: Vector2i = key
		var neighbourhood: Array[Vector2i] = [cell]
		for edge: int in 4:
			neighbourhood.append(cell + TerrainMesh.EDGE_NEIGHBOURS[edge])
		for around: Vector2i in neighbourhood:
			if rebuilt.has(around):
				continue
			rebuilt[around] = true
			_grid.rebuild_side_faces_for_cell(around)


## Level every footprint quad onto one plane and ramp the ground into it.
##
## The pad itself is unconditional: every corner of every footprint quad reaches
## the plane, so the surface the model stands on is always flat. The slope is what
## happens outside it. A boundary corner with no wall standing on it is written on
## the neighbouring quads too, so those quads genuinely share the coordinate and
## fall away over their own width -- the same continuity set_lattice_corner_height()
## produces, expressed one quad corner at a time so the footprint can be treated
## differently from its surroundings.
##
## A boundary corner that a wall already stands on is written only on the footprint
## side. Sharing it would pull that wall's top edge down onto the pad and collapse
## the wall, which is the one thing this mode must not do; leaving the outside quad
## alone turns the remaining difference back into a real vertical face when the side
## faces are rebuilt. Nothing inside the footprint is ever protected -- a wall
## between two cells the GLB stands on is exactly what the flatten exists to remove.
func flatten_cells_smooth(cells: Array[Vector2i], height_m: float) -> Dictionary:
	if not _stroke_active:
		push_error("TerrainSculptor: flatten_cells_smooth requires an active stroke.")
		return {"bounds": Rect2i(), "flattened_cell_count": 0}

	var footprint: Dictionary = {}
	var footprint_corners: Dictionary = {}
	for cell: Vector2i in cells:
		if not _grid.is_cell_filled(cell):
			continue
		footprint[cell] = true
		for offset: Vector2i in TerrainMesh.CORNER_OFFSETS:
			footprint_corners[cell + offset] = true

	var touched := _CellBounds.new()
	var moved_cells: Dictionary = {}
	for key: Variant in footprint_corners:
		var corner: Vector2i = key
		# Records all four quads meeting the corner, and the side faces around each,
		# before any of them is written, so undo restores the walls this rebuilds.
		_record_corner(corner)
		for corner_index: int in 4:
			var affected_cell := corner - TerrainMesh.CORNER_OFFSETS[corner_index]
			if not _grid.is_cell_filled(affected_cell):
				continue
			if (
				not footprint.has(affected_cell)
				and _quad_corner_carries_wall(affected_cell, corner_index)
			):
				continue
			if _grid.set_cell_corner(affected_cell, corner_index, height_m):
				touched.include(affected_cell)
				moved_cells[affected_cell] = true
	_rebuild_contact_side_faces(moved_cells)
	return {
		"bounds": touched.bounds(),
		"flattened_cell_count": moved_cells.size(),
	}


## Set every cell of one absolute rectangle to an exact level.
##
## The footprint tool uses this to give newly drawn ground one explicit starting
## elevation instead of leaving it at an implicit zero. It is cell-based, so
## drawing a raised region against existing ground produces a wall at the join.
func set_region_level(cell_rect: Rect2i, height_m: float) -> Rect2i:
	var touched := _CellBounds.new()
	for z: int in range(cell_rect.position.y, cell_rect.end.y):
		for x: int in range(cell_rect.position.x, cell_rect.end.x):
			var cell := Vector2i(x, z)
			if not _grid.is_cell_filled(cell):
				continue
			_record_cell(cell)
			if _grid.set_cell_top_level(cell, height_m):
				touched.include(cell)
	return touched.bounds()


## Accumulates the absolute cell rectangle a batch of edits touched.
class _CellBounds extends RefCounted:
	var _has_any: bool = false
	var _minimum: Vector2i = Vector2i.ZERO
	var _maximum: Vector2i = Vector2i.ZERO

	## Grow the accumulated bounds to contain one edited cell.
	func include(cell: Vector2i) -> void:
		if not _has_any:
			_has_any = true
			_minimum = cell
			_maximum = cell
			return
		_minimum = _minimum.min(cell)
		_maximum = _maximum.max(cell)

	## Return the absolute cell rectangle whose geometry the edits invalidated.
	##
	## Grown by one cell on every side because a cell's walls are shared with its
	## neighbours, so their geometry changes too.
	func bounds() -> Rect2i:
		if not _has_any:
			return Rect2i()
		var low := _minimum - Vector2i.ONE
		var high := _maximum + Vector2i.ONE
		return Rect2i(low, high - low + Vector2i.ONE)
