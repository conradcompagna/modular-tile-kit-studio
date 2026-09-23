@tool
class_name MTSConstants
extends RefCounted

## Single source of truth for the spatial language of Modular Tile Kit Studio.
##
## Everything spatial in the plugin resolves through this file: axes, cardinal
## directions, grid faces, and the fixed isometric camera. Spec 1.2 forbids a
## second coordinate convention living anywhere else in the plugin.
##
##   X = east/west, Y = vertical, Z = north/south, 1 unit = 1 metre.

## One Godot world unit is one metre. Not configurable -- the whole lattice
## assumes it (spec 1.1).
const METRES_PER_UNIT: float = 1.0

# --- Cardinal directions (spec 1.2) ---------------------------------------

const DIR_NORTH := Vector3i(0, 0, -1)
const DIR_SOUTH := Vector3i(0, 0, 1)
const DIR_EAST := Vector3i(1, 0, 0)
const DIR_WEST := Vector3i(-1, 0, 0)
const DIR_UP := Vector3i(0, 1, 0)
const DIR_DOWN := Vector3i(0, -1, 0)

## The six faces of a grid cell. Surfaces occupy these; props occupy volumes.
enum Face { POS_X, NEG_X, POS_Y, NEG_Y, POS_Z, NEG_Z }

## Cardinal facing for props. Order matters: rotating right steps N -> E -> S -> W
## (spec 38), and the index doubles as the quarter-turn count about +Y.
enum Facing { NORTH, EAST, SOUTH, WEST }

## Which persisted mesh measurement can represent one prop orientation exactly.
enum PropVoxelScan { UNSUPPORTED, CANONICAL, DIAGONAL }

const FACE_NORMALS: Dictionary = {
	Face.POS_X: Vector3i(1, 0, 0),
	Face.NEG_X: Vector3i(-1, 0, 0),
	Face.POS_Y: Vector3i(0, 1, 0),
	Face.NEG_Y: Vector3i(0, -1, 0),
	Face.POS_Z: Vector3i(0, 0, 1),
	Face.NEG_Z: Vector3i(0, 0, -1),
}

## Canonical serialized spelling of each face. These strings appear verbatim in
## the portable board JSON, so they are part of the LLM-facing contract
## (spec 44) and must never be renamed casually.
const FACE_NAMES: Dictionary = {
	Face.POS_X: "+X",
	Face.NEG_X: "-X",
	Face.POS_Y: "+Y",
	Face.NEG_Y: "-Y",
	Face.POS_Z: "+Z",
	Face.NEG_Z: "-Z",
}

const FACING_NAMES: Dictionary = {
	Facing.NORTH: "N",
	Facing.EAST: "E",
	Facing.SOUTH: "S",
	Facing.WEST: "W",
}

# --- Fixed isometric camera (spec 5) --------------------------------------

## True-isometric view direction. The camera sits along +(1,1,1) from its target
## and looks back at it, which yields yaw 45 deg / pitch -35.264 deg.
## Centralised so the projection can be retuned in exactly one place.
const ISO_CAMERA_DIRECTION := Vector3(1.0, 1.0, 1.0)

## Distance from target to camera. Orthographic, so this only has to clear the
## near plane and any tall geometry -- it does not affect apparent size.
const ISO_CAMERA_DISTANCE: float = 60.0

## Orientation an impostor card must have to face the fixed camera.
##
## The camera never rotates (spec 5), so a card can be oriented ONCE in the
## scene instead of being billboarded per frame. That matters beyond
## efficiency: BILLBOARD_ENABLED is a BaseMaterial3D feature, and a
## ShaderMaterial does not inherit it -- so the moment an impostor moved to a
## custom shader it silently stopped facing the camera while every comment
## still assumed it did. Orienting the mesh removes the assumption entirely.
##
## A card built this way has a constant camera-space depth across its whole
## surface, which is what lets the impostor shader use its plane as a stable
## reference for reconstructing per-pixel depth.
static func impostor_card_basis() -> Basis:
	var forward := ISO_CAMERA_DIRECTION.normalized()
	# The quad's +Z must point at the camera, its +Y must stay world-up-ish.
	var right := Vector3.UP.cross(forward).normalized()
	var up := forward.cross(right).normalized()
	return Basis(right, up, forward)


const ISO_DEFAULT_ORTHO_SIZE: float = 16.0
const ISO_MIN_ORTHO_SIZE: float = 2.0
const ISO_MAX_ORTHO_SIZE: float = 120.0
const ISO_ROTATABLE_YAW_RADIANS_PER_SECOND: float = 1.65
const ISO_ZOOM_IN_FACTOR: float = 0.88
const ISO_ZOOM_OUT_FACTOR: float = 1.13
## Continuous logarithmic zoom rate used by held keyboard controls in both camera implementations.
## A 1.20/s rate traverses the useful zoom range in about the same time as a deliberate
## pan or orbit, while exponential integration keeps the motion frame-rate independent.
const ISO_ZOOM_RATE_PER_SECOND: float = 1.20

## Shared physics classification for authored GLB voxel volumes.
##
## The game uses these same bits for movement and projectile/LOS queries, so a voxel
## is one obstacle in every world-space system rather than a cover-only exception.
const MOVEMENT_BLOCKER_COLLISION_LAYER: int = 1 << 2
const LOS_BLOCKER_COLLISION_LAYER: int = 1 << 3
const GLB_BLOCKER_COLLISION_LAYER_MASK: int = MOVEMENT_BLOCKER_COLLISION_LAYER | LOS_BLOCKER_COLLISION_LAYER

const CAMERA_NEAR: float = 0.05
const CAMERA_FAR: float = 400.0

# --- Editor visibility modes ----------------------------------------------

## Y-slice visibility. Editor-only: never mutates board data (spec 7).
enum SliceMode { ALL, CURRENT_AND_BELOW, CURRENT_ONLY }

# --- Asset model ----------------------------------------------------------

enum SourceType { IMAGE_SURFACE, GLB_PROP }

## The library has exactly two categories, and they ARE the source types.
##
## Categories were free text, which meant every import invented its own ("Floors",
## "Props", "floor", "walls") and the filter dropdown filled up with near-
## duplicates that split the same shelf. There are only two kinds of thing in
## this tool -- a flat image painted onto a grid face, and a 3D model placed in a
## cell -- so the category is not a decision the user should have to make or be
## able to get wrong. It is derived, fixed, and never editable.
const CATEGORY_NAMES: Dictionary = {
	SourceType.IMAGE_SURFACE: "PNG Images",
	SourceType.GLB_PROP: "GLB Props",
}


## Fixed category name for a source type. The one place the strings live.
static func category_name(source_type: int) -> String:
	return CATEGORY_NAMES.get(source_type, CATEGORY_NAMES[SourceType.IMAGE_SURFACE])


enum AnchorMode { BOTTOM_CENTER, CENTER, ORIGIN }

# --- Project setting keys -------------------------------------------------

const SETTING_COMFY_URL := "modular_tile_studio/analysis/comfyui_server_url"
const SETTING_COMFY_RECIPES := "modular_tile_studio/analysis/recipe_directory"
const SETTING_COMFY_TIMEOUT := "modular_tile_studio/analysis/timeout_seconds"
const SETTING_COMFY_AUTOSTART := "modular_tile_studio/analysis/autostart_server"
const SETTING_COMFY_PYTHON := "modular_tile_studio/analysis/server_python_executable"
const SETTING_COMFY_MAIN := "modular_tile_studio/analysis/server_main_script"
const SETTING_COMFY_EXTRA_ARGS := "modular_tile_studio/analysis/server_extra_args"

## Loopback port for the MCP command bus into the live workspace.
const SETTING_BRIDGE_PORT := "modular_tile_studio/automation/bridge_port"

const LIBRARY_ROOT := "res://tile_library"
const LIBRARY_RESOURCE_PATH := "res://tile_library/library.tres"
const ASSETS_DIR := "res://tile_library/assets"
const SOURCE_IMAGES_DIR := "res://tile_library/sources/images"
const SOURCE_GLB_DIR := "res://tile_library/sources/glb"

# --- Face helpers ---------------------------------------------------------

static func face_normal(face: int) -> Vector3i:
	return FACE_NORMALS.get(face, Vector3i(0, 1, 0))


static func face_name(face: int) -> String:
	return FACE_NAMES.get(face, "+Y")


static func face_from_name(name: String) -> int:
	for face: int in FACE_NAMES:
		if FACE_NAMES[face] == name:
			return face
	return Face.POS_Y


static func facing_name(facing: int) -> String:
	return FACING_NAMES.get(facing, "N")


static func facing_from_name(name: String) -> int:
	for facing: int in FACING_NAMES:
		if FACING_NAMES[facing] == name:
			return facing
	return Facing.NORTH


## Convert a legacy upright cardinal facing into the equivalent prop forward face.
##
## This keeps existing boards visually identical when their four-way placements
## are loaded into the explicit cube-orientation model.
static func facing_to_forward_face(facing: int) -> int:
	match facing:
		Facing.NORTH:
			return Face.NEG_Z
		Facing.EAST:
			return Face.POS_X
		Facing.SOUTH:
			return Face.POS_Z
		Facing.WEST:
			return Face.NEG_X
	return Face.NEG_Z


## Return the enum value whose normal matches an exact lattice direction.
static func face_from_normal(normal: Vector3i) -> int:
	for face: int in FACE_NORMALS:
		if FACE_NORMALS[face] == normal:
			return face
	return Face.POS_Y


## Normalize a quarter-turn count so every orientation has one serialized spelling.
static func normalized_quarters(quarters: int) -> int:
	return ((quarters % 4) + 4) % 4


## Normalize an eighth-turn yaw count so every 45-degree step has one spelling.
static func normalized_yaw_eighths(yaw_eighths: int) -> int:
	return ((yaw_eighths % 8) + 8) % 8


## Build the rigid transform for a prop whose local front (-Z) points at forward_face.
##
## Roll is a quarter turn about that front/back axis. Horizontal forward faces
## keep local +Y world-up at roll zero, preserving the previous N/E/S/W poses;
## vertical forward faces use world +Z as their stable zero-roll reference.
static func prop_orientation_basis(
	forward_face: int,
	roll_quarters: int,
	yaw_eighths: int = 0
) -> Basis:
	var forward := Vector3(face_normal(forward_face))
	var back := -forward
	var reference_up := Vector3.UP if absf(forward.y) < 0.5 else Vector3.BACK
	var right := reference_up.cross(back).normalized()
	var up := back.cross(right).normalized()
	var base := Basis(right, up, back)
	var roll := Basis(Vector3.BACK, PI * 0.5 * float(normalized_quarters(roll_quarters)))
	var yaw := Basis(Vector3.UP, PI * 0.25 * float(normalized_yaw_eighths(yaw_eighths)))
	return yaw * base * roll


## Decompose one exact right-angle prop transform into its forward face and roll.
##
## World-axis arrow-key rotations are always orthogonal, so trying the four
## legal rolls is clearer and safer than extracting unstable Euler angles.
static func prop_orientation_from_basis(basis: Basis) -> Dictionary:
	var forward := -basis.z
	var snapped_forward := Vector3i(
		roundi(forward.x),
		roundi(forward.y),
		roundi(forward.z)
	)
	var forward_face := face_from_normal(snapped_forward)
	for roll in 4:
		var candidate := prop_orientation_basis(forward_face, roll)
		if (
			candidate.x.is_equal_approx(basis.x)
			and candidate.y.is_equal_approx(basis.y)
			and candidate.z.is_equal_approx(basis.z)
		):
			return {"forward_face": forward_face, "roll_quarters": roll}
	push_error("[Tile Studio] prop orientation was not an orthogonal quarter turn.")
	return {"forward_face": forward_face, "roll_quarters": 0}


## Rotate a prop orientation by one step about its visible yaw-aligned axes.
##
## World Y remains the eight-step horizontal yaw. X and Z rotate the orthogonal
## base pose inside that yaw frame, allowing pitch and roll at diagonal headings
## while preserving one canonical forward-face, roll, and yaw record.
static func rotate_prop_orientation(
	forward_face: int,
	roll_quarters: int,
	axis: Vector3i,
	positive: bool,
	yaw_eighths: int = 0
) -> Dictionary:
	if axis == Vector3i.ZERO:
		push_error("[Tile Studio] cannot rotate a prop around a zero axis.")
		return {
			"forward_face": forward_face,
			"roll_quarters": normalized_quarters(roll_quarters),
			"yaw_eighths": normalized_yaw_eighths(yaw_eighths),
		}

	# Horizontal prop turning is deliberately eight-step: four cardinals plus
	# four diagonals. The separate yaw value keeps the visible heading explicit.
	if axis == Vector3i.UP:
		var yaw_step := 1 if positive else -1
		return {
			"forward_face": forward_face,
			"roll_quarters": normalized_quarters(roll_quarters),
			"yaw_eighths": normalized_yaw_eighths(yaw_eighths + yaw_step),
		}

	# Pitch and roll operate on the exact orthogonal base before its stored yaw
	# is applied. This is the yaw-aligned frame the user sees, and it remains
	# representable by the existing canonical fields for every diagonal heading.
	var preserved_yaw := normalized_yaw_eighths(yaw_eighths)
	var angle := (PI * 0.5) * (1.0 if positive else -1.0)
	var base_rotation := Basis(Vector3(axis).normalized(), angle)
	var rotated_base := base_rotation * prop_orientation_basis(
		forward_face,
		roll_quarters
	)
	var result := prop_orientation_from_basis(rotated_base)
	result["yaw_eighths"] = preserved_yaw
	return result


## Return a stable key for every serialized prop orientation.
static func prop_orientation_key(
	forward_face: int,
	roll_quarters: int,
	yaw_eighths: int = 0
) -> String:
	return "%s:%d:%d" % [
		face_name(forward_face),
		normalized_quarters(roll_quarters),
		normalized_yaw_eighths(yaw_eighths),
	]


## Return the transformed AABB of one canonical prop box for a rigid basis.
static func _prop_oriented_aabb(bounds: Vector3i, basis: Basis) -> AABB:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for x in [0.0, float(bounds.x)]:
		for y in [0.0, float(bounds.y)]:
			for z in [0.0, float(bounds.z)]:
				var transformed := basis * Vector3(x, y, z)
				minimum.x = minf(minimum.x, transformed.x)
				minimum.y = minf(minimum.y, transformed.y)
				minimum.z = minf(minimum.z, transformed.z)
				maximum.x = maxf(maximum.x, transformed.x)
				maximum.y = maxf(maximum.y, transformed.y)
				maximum.z = maxf(maximum.z, transformed.z)
	return AABB(minimum, maximum - minimum)


## Return the integer reservation box that contains the transformed GLB geometry.
static func oriented_prop_grid_bounds(
	bounds: Vector3i,
	forward_face: int,
	roll_quarters: int,
	yaw_eighths: int = 0
) -> Vector3i:
	var basis := prop_orientation_basis(
		forward_face,
		roll_quarters,
		yaw_eighths
	)
	var aabb := _prop_oriented_aabb(bounds, basis)
	return Vector3i(
		maxi(1, ceili(aabb.size.x - 0.00001)),
		maxi(1, ceili(aabb.size.y - 0.00001)),
		maxi(1, ceili(aabb.size.z - 0.00001))
	)
## Map the canonical prop box into its oriented integer reservation without moving its placement root.
##
## The source box rotates about its centre and is then centred inside the exact
## integer box reported by oriented_prop_grid_bounds. Cardinal rotations have no
## fractional slack, so their established transforms are unchanged. Diagonal
## rotations split their fractional slack evenly on both sides; that symmetry is
## what makes one measured 45-degree voxel scan rotate exactly into the other three
## diagonal headings without shifting either the art or occupancy to another corner.
static func prop_box_transform(
	bounds: Vector3i,
	forward_face: int,
	roll_quarters: int,
	yaw_eighths: int = 0
) -> Transform3D:
	var basis := prop_orientation_basis(
		forward_face,
		roll_quarters,
		yaw_eighths
	)
	var target_bounds := oriented_prop_grid_bounds(
		bounds,
		forward_face,
		roll_quarters,
		yaw_eighths
	)
	var source_centre := Vector3(bounds) * 0.5
	var target_centre := Vector3(target_bounds) * 0.5
	return Transform3D(basis, target_centre - basis * source_centre)



static func diagonal_yaw_basis() -> Basis:
	return Basis(Vector3.UP, PI * 0.25)


## Return the orientation a prop's diagonal voxel scan is taken in.
##
## One scan covers all four diagonal headings, so the importer scans this pose and
## oriented_prop_voxels rotates it by right angles to reach the other three.
static func diagonal_scan_orientation() -> Dictionary:
	return {"forward_face": Face.NEG_Z, "roll_quarters": 0, "yaw_eighths": 1}


## Return the integer box a prop's diagonal voxel scan is measured in.
##
## Derived from the canonical box rather than stored, so it cannot drift from the
## grid_bounds the scan was taken against.
static func diagonal_scan_bounds(bounds: Vector3i) -> Vector3i:
	var pose := diagonal_scan_orientation()
	return oriented_prop_grid_bounds(
		bounds,
		int(pose["forward_face"]),
		int(pose["roll_quarters"]),
		int(pose["yaw_eighths"])
	)


## Return whether a basis maps the cubic lattice onto itself.
##
## Only such a basis can move a scanned voxel set without resampling: every cell
## lands squarely on one other cell. A 45-degree yaw fails this test, which is the
## whole reason a diagonal placement needs a scan of its own rather than a rotation
## of the cardinal one.
static func is_lattice_basis(basis: Basis) -> bool:
	for axis: Vector3 in [basis.x, basis.y, basis.z]:
		for component: float in [axis.x, axis.y, axis.z]:
			if absf(component - roundf(component)) > 0.0001:
				return false
	return true


## Move one scanned voxel set into its destination box by a right-angle basis.
##
## The caller must already have established that `basis` maps the lattice onto
## itself; each source cell centre then lands squarely inside exactly one
## destination cell, so no rounding rule or epsilon is needed. The transformed box
## minimum is restored to the origin, matching how prop_box_transform anchors the
## geometry that was scanned.
static func _mapped_prop_voxels(
	voxels: Array[Vector3i],
	bounds: Vector3i,
	basis: Basis
) -> Array[Vector3i]:
	var mapped: Array[Vector3i] = []
	var seen: Dictionary = {}
	var offset := -_prop_oriented_aabb(bounds, basis).position
	for voxel: Vector3i in voxels:
		var centre := basis * (Vector3(voxel) + Vector3(0.5, 0.5, 0.5)) + offset
		var cell := Vector3i(
			floori(centre.x),
			floori(centre.y),
			floori(centre.z)
		)
		var key := voxel_key(cell)
		if seen.has(key):
			continue
		seen[key] = true
		mapped.append(cell)
	return mapped


## Identify the one measured voxel scan that can represent an orientation exactly.
##
## Validation and occupancy generation share this classification so the UI cannot
## accept a pose that the backend later approximates with different geometry.
static func prop_voxel_scan_kind(
	forward_face: int,
	roll_quarters: int,
	yaw_eighths: int = 0
) -> int:
	var target_basis := prop_orientation_basis(
		forward_face,
		roll_quarters,
		yaw_eighths
	)
	if is_lattice_basis(target_basis):
		return PropVoxelScan.CANONICAL
	var diagonal_remainder := target_basis * diagonal_yaw_basis().inverse()
	if is_lattice_basis(diagonal_remainder):
		return PropVoxelScan.DIAGONAL
	return PropVoxelScan.UNSUPPORTED


## Return the grid cells one prop's scanned geometry occupies in one orientation.
##
## Loose voxels are never rotated through a non-lattice angle. Exactly one measured
## set is selected and moved by a basis that maps the lattice onto itself:
##
##   cardinal heading  ->  the canonical scan, turned by a right angle
##   diagonal heading  ->  the 45-degree scan, turned by a right angle
##
## Missing scans and unsupported poses are explicit errors. Returning an inflated
## reservation would reintroduce a second geometry model and make empty cells collide.
static func oriented_prop_voxels(
	voxels: Array[Vector3i],
	diagonal_voxels: Array[Vector3i],
	bounds: Vector3i,
	forward_face: int,
	roll_quarters: int,
	yaw_eighths: int = 0,
	asset_label: String = ""
) -> Array[Vector3i]:
	var label := asset_label if not asset_label.is_empty() else "<prop>"
	var scan_kind := prop_voxel_scan_kind(
		forward_face,
		roll_quarters,
		yaw_eighths
	)
	if scan_kind == PropVoxelScan.CANONICAL:
		if voxels.is_empty():
			push_error(
				"[Tile Studio] '%s' has no canonical voxel scan. Rebuild the asset before placing it."
				% label
			)
			return []
		var target_basis := prop_orientation_basis(
			forward_face,
			roll_quarters,
			yaw_eighths
		)
		return _mapped_prop_voxels(voxels, bounds, target_basis)

	if scan_kind == PropVoxelScan.DIAGONAL:
		if diagonal_voxels.is_empty():
			push_error(
				("[Tile Studio] '%s' has no 45-degree voxel scan. "
				+ "Rebuild the asset before placing it diagonally.") % label
			)
			return []
		var target_basis := prop_orientation_basis(
			forward_face,
			roll_quarters,
			yaw_eighths
		)
		var diagonal_remainder := target_basis * diagonal_yaw_basis().inverse()
		return _mapped_prop_voxels(
			diagonal_voxels,
			diagonal_scan_bounds(bounds),
			diagonal_remainder
		)

	push_error(
		("[Tile Studio] '%s' has an orientation that neither measured voxel scan "
		+ "can represent exactly.") % label
	)
	return []


## Decompose a surface basis into its face normal and in-plane quarter turn.
##
## Surface placements use the same complete orientation approach as props, but their
## local +Z is the painted face normal rather than a model's backward axis.
static func surface_orientation_from_basis(basis: Basis) -> Dictionary:
	var normal := basis.z
	var snapped_normal := Vector3i(
		roundi(normal.x),
		roundi(normal.y),
		roundi(normal.z)
	)
	var face := face_from_normal(snapped_normal)
	for quarters in 4:
		var candidate := face_basis(face, quarters)
		if (
			candidate.x.is_equal_approx(basis.x)
			and candidate.y.is_equal_approx(basis.y)
			and candidate.z.is_equal_approx(basis.z)
		):
			return {"face": face, "rotation_quarters": quarters}
	push_error("[Tile Studio] surface orientation was not an orthogonal quarter turn.")
	return {"face": face, "rotation_quarters": 0}


## Rotate a surface placement by one world-axis quarter turn without changing its authored face.
##
## This preserves all 24 face-and-spin states, so a card can always flip from
## its current orientation rather than only after a particular cardinal turn.
static func rotate_surface_orientation(
	face: int,
	rotation_quarters: int,
	axis: Vector3i,
	positive: bool
) -> Dictionary:
	if axis == Vector3i.ZERO:
		push_error("[Tile Studio] cannot rotate a surface around a zero axis.")
		return {
			"face": face,
			"rotation_quarters": normalized_quarters(rotation_quarters),
		}
	var angle := (PI * 0.5) * (1.0 if positive else -1.0)
	var world_rotation := Basis(Vector3(axis).normalized(), angle)
	var rotated := world_rotation * face_basis(face, rotation_quarters)
	return surface_orientation_from_basis(rotated)


## A face is horizontal when its normal runs along the vertical axis. Floors and
## ceilings behave differently from walls when building quad geometry.
static func is_horizontal_face(face: int) -> bool:
	return face == Face.POS_Y or face == Face.NEG_Y


## Stable string key identifying one occupied grid face, e.g. "4,0,7,+Y".
## Used as the surface-occupancy dictionary key (spec 15).
static func face_key(cell: Vector3i, face: int) -> String:
	return "%d,%d,%d,%s" % [cell.x, cell.y, cell.z, face_name(face)]


## Stable string key identifying one occupied voxel, e.g. "8,0,10".
static func voxel_key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]


## Basis that maps a unit quad in the XY plane onto the given grid face.
##
## The quad mesh is authored in the XY plane facing +Z, so each face needs a
## rotation carrying +Z onto the face normal. `quarters` then spins the image
## within its own plane in 90 degree steps (spec 13/14).
static func face_basis(face: int, quarters: int) -> Basis:
	var basis := Basis.IDENTITY
	match face:
		Face.POS_Y:
			# +Z -> +Y : lay the quad flat, image top pointing north.
			basis = Basis(Vector3(1, 0, 0), -PI * 0.5)
		Face.NEG_Y:
			basis = Basis(Vector3(1, 0, 0), PI * 0.5)
		Face.POS_Z:
			basis = Basis.IDENTITY
		Face.NEG_Z:
			basis = Basis(Vector3(0, 1, 0), PI)
		Face.POS_X:
			basis = Basis(Vector3(0, 1, 0), PI * 0.5)
		Face.NEG_X:
			basis = Basis(Vector3(0, 1, 0), -PI * 0.5)
	# In-plane spin happens about the face normal, i.e. the quad's own +Z.
	var spin := Basis(Vector3(0, 0, 1), PI * 0.5 * float(quarters))
	return basis * spin
