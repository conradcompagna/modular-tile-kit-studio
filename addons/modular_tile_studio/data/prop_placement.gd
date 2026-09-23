@tool
class_name PropPlacement
extends Resource

## One GLB-derived prop placed on the lattice.
##
## Every prop takes its occupied voxels from exactly one imported asset. The
## integer origin is the minimum corner of the oriented occupancy box; its X and Z
## are the canonical lattice address used by occupancy, collision, and persistence.
##
## The elevation the prop rests at is NOT decided here. BoardDocument derives a
## floor prop's exact world height from the canonical terrain. origin.y remains the
## authored integer anchor and the fallback for boards with no terrain; it is
## authoritative physical height only for wall props. Both the measured voxel boxes
## and rendered pose read the same derived world origin, so sculpting the ground
## cannot leave collision at a different height from the model.

const K := preload("../utils/mts_constants.gd")

const SUPPORT_NONE: String = "none"
const SUPPORT_FLOOR: String = "floor"
const SUPPORT_WALL: String = "wall"

@export var asset_id: String = ""
@export var origin: Vector3i = Vector3i.ZERO

## World face the source model's local front (-Z) points toward.
@export var forward_face: K.Face = K.Face.NEG_Z

## Quarter turns around the model's front/back axis after forward_face is chosen.
@export_range(0, 3, 1) var roll_quarters: int = 0

## Horizontal yaw in 45-degree steps; 0/2/4/6 are cardinals and 1/3/5/7 are diagonals.
@export_range(0, 7, 1) var yaw_eighths: int = 0

## Every prop explicitly records whether its placement target was floor or wall terrain.
##
## This support contract is independent from forward/roll/yaw so changing the
## target face can never become a second rotation system.
@export_enum("none", "floor", "wall") var support: String = SUPPORT_NONE

## Exact terrain face that owns a wall mount; floor support always uses +Y.
##
## The face is captured from the raycast instead of inferred from model orientation,
## because support and authored GLB rotation are independent facts.
@export var support_face: K.Face = K.Face.POS_Y


## Create one prop placement with an explicit six-face orientation.
static func create(
	p_asset_id: String,
	p_origin: Vector3i,
	p_forward_face: int = K.Face.NEG_Z,
	p_roll_quarters: int = 0,
	p_yaw_eighths: int = 0
) -> PropPlacement:
	var placement := PropPlacement.new()
	placement.asset_id = p_asset_id
	placement.origin = p_origin
	placement.forward_face = p_forward_face
	placement.roll_quarters = K.normalized_quarters(p_roll_quarters)
	placement.yaw_eighths = K.normalized_yaw_eighths(p_yaw_eighths)
	return placement


## Report whether this placement references an asset at all.
func reference_error() -> String:
	if asset_id.is_empty():
		return "prop placement at %s references no asset" % origin
	if support not in [SUPPORT_NONE, SUPPORT_FLOOR, SUPPORT_WALL]:
		return "prop placement at %s has invalid support '%s'" % [origin, support]
	if support == SUPPORT_WALL and K.face_normal(support_face).y != 0:
		return "wall prop placement at %s has no vertical support face" % origin
	return ""


## Return the canonical unrotated box from the placement's authoritative asset.
func canonical_bounds(asset: TileAsset) -> Vector3i:
	if asset == null:
		push_error("[Tile Studio] prop placement references missing asset '%s'." % asset_id)
		return Vector3i.ZERO
	return asset.grid_bounds


## Return the rigid transform that maps the canonical prop box into this placement.
func orientation_transform(asset: TileAsset) -> Transform3D:
	var bounds := canonical_bounds(asset)
	if bounds == Vector3i.ZERO:
		return Transform3D.IDENTITY
	return K.prop_box_transform(bounds, forward_face, roll_quarters, yaw_eighths)


## Return the integer box occupied after the authored cube orientation.
func oriented_bounds(asset: TileAsset) -> Vector3i:
	var bounds := canonical_bounds(asset)
	if bounds == Vector3i.ZERO:
		return Vector3i.ZERO
	return K.oriented_prop_grid_bounds(bounds, forward_face, roll_quarters, yaw_eighths)


## Return canonical voxel occupancy under one explicit board-owned threshold.
func canonical_voxels(
	asset: TileAsset,
	threshold_percent: float = 0.0
) -> Array[Vector3i]:
	var voxels: Array[Vector3i] = []
	var bounds := canonical_bounds(asset)
	if bounds == Vector3i.ZERO:
		return voxels
	voxels.assign(asset.filtered_prop_voxels(false, threshold_percent))
	return voxels


## Return the asset's filtered 45-degree voxel scan used by every diagonal heading.
##
## Empty when the asset predates diagonal scanning; voxel_scan_error makes that
## missing authored state visible and prevents diagonal placement until rebuild.
func canonical_diagonal_voxels(
	asset: TileAsset,
	threshold_percent: float = 0.0
) -> Array[Vector3i]:
	var voxels: Array[Vector3i] = []
	if asset == null or canonical_bounds(asset) == Vector3i.ZERO:
		return voxels
	voxels.assign(asset.filtered_prop_voxels(true, threshold_percent))
	return voxels


## Return why this placement cannot derive exact occupancy from a measured scan.
##
## Board validation uses the same scan classification as oriented_voxels, so the
## editor rejects missing or unsupported occupancy before it mutates the document.
func voxel_scan_error(
	asset: TileAsset,
	threshold_percent: float = 0.0
) -> String:
	if asset == null:
		return "unknown asset '%s'" % asset_id
	var label := asset.asset_id if not asset.asset_id.is_empty() else asset_id
	var scan_kind := K.prop_voxel_scan_kind(
		forward_face,
		roll_quarters,
		yaw_eighths
	)
	if scan_kind == K.PropVoxelScan.UNSUPPORTED:
		return "'%s' orientation has no exact measured voxel scan" % label
	if scan_kind == K.PropVoxelScan.CANONICAL and asset.prop_voxels.is_empty():
		return "'%s' has no canonical voxel scan; rebuild the asset" % label
	if scan_kind == K.PropVoxelScan.DIAGONAL and asset.prop_voxels_diagonal.is_empty():
		return "'%s' has no 45-degree voxel scan; rebuild before diagonal placement" % label
	var filter_error := asset.prop_collision_filter_error(
		scan_kind == K.PropVoxelScan.DIAGONAL,
		threshold_percent
	)
	if not filter_error.is_empty():
		return filter_error
	return ""


## Return the matching measured voxel set under one board threshold and orientation.
func oriented_voxels(
	asset: TileAsset,
	threshold_percent: float = 0.0
) -> Array[Vector3i]:
	var bounds := canonical_bounds(asset)
	if bounds == Vector3i.ZERO:
		return []
	return K.oriented_prop_voxels(
		canonical_voxels(asset, threshold_percent),
		canonical_diagonal_voxels(asset, threshold_percent),
		bounds,
		forward_face,
		roll_quarters,
		yaw_eighths,
		asset_id
	)


## Return the visible GLB bounds after its canonical pose and placement orientation.
##
## Import centres the real mesh horizontally inside its integer box and aligns its
## bottom to Y=0. Reconstructing that exact AABB from the stored real size keeps wall
## contact derived from the same canonical sizing data as the rendered source GLB.
func oriented_visual_bounds(asset: TileAsset) -> AABB:
	var grid_size := Vector3(canonical_bounds(asset))
	var visual_size := asset.visual_size_m if asset != null else Vector3.ZERO
	if visual_size.x <= 0.0 or visual_size.y <= 0.0 or visual_size.z <= 0.0:
		push_error("[Tile Studio] prop '%s' has no valid visual size for wall mounting." % asset_id)
		return AABB()
	var canonical_visual_bounds := AABB(
		Vector3(
			(grid_size.x - visual_size.x) * 0.5,
			0.0,
			(grid_size.z - visual_size.z) * 0.5
		),
		visual_size
	)
	return orientation_transform(asset) * canonical_visual_bounds


## Return the derived translation that puts the real GLB back surface on its wall plane.
##
## The placement origin already puts the oriented integer box against the picked
## face. This removes only the visible inset introduced when a thinner proportional
## mesh was centred inside that box; there is no authored or guessed wall offset.
func wall_mount_offset(asset: TileAsset) -> Vector3:
	if support != SUPPORT_WALL:
		return Vector3.ZERO
	var support_normal_i := K.face_normal(support_face)
	if support_normal_i.y != 0:
		push_error(
			"[Tile Studio] wall prop '%s' has non-vertical support face %s."
			% [asset_id, K.face_name(support_face)]
		)
		return Vector3.ZERO
	var visual_bounds := oriented_visual_bounds(asset)
	if not visual_bounds.has_volume():
		return Vector3.ZERO
	var oriented_grid_size := Vector3(oriented_bounds(asset))
	var visible_inset_m := 0.0
	match support_face:
		K.Face.POS_X:
			visible_inset_m = visual_bounds.position.x
		K.Face.NEG_X:
			visible_inset_m = (
				oriented_grid_size.x
				- (visual_bounds.position.x + visual_bounds.size.x)
			)
		K.Face.POS_Z:
			visible_inset_m = visual_bounds.position.z
		K.Face.NEG_Z:
			visible_inset_m = (
				oriented_grid_size.z
				- (visual_bounds.position.z + visual_bounds.size.z)
			)
		_:
			push_error("[Tile Studio] wall prop '%s' has unsupported support face." % asset_id)
			return Vector3.ZERO
	if visible_inset_m < -0.001:
		push_error(
			"[Tile Studio] wall prop '%s' extends %.3f m beyond its oriented grid box."
			% [asset_id, -visible_inset_m]
		)
		return Vector3.ZERO
	# Sub-millimetre negative values can arise from rotated-AABB precision only.
	visible_inset_m = maxf(0.0, visible_inset_m)
	return -Vector3(support_normal_i) * visible_inset_m


## Return the compact orientation key used by visual and proxy caches.
func orientation_key() -> String:
	return K.prop_orientation_key(forward_face, roll_quarters, yaw_eighths)


## Return the unique terrain cells under this prop's oriented voxel occupancy.
##
## Projecting the canonical voxels onto XZ preserves holes and irregular outlines;
## no grid-bounds rectangle or visual-mesh hull can silently enlarge the footprint.
##
## Projected straight from the oriented voxels because this footprint decides the
## terrain support height that translates the complete world-space voxel volume.
## Only X and Z are involved, so nothing is lost.
func footprint_cells(asset: TileAsset) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var included: Dictionary = {}
	for offset: Vector3i in oriented_voxels(asset):
		var cell := Vector2i(origin.x + offset.x, origin.z + offset.z)
		if included.has(cell):
			continue
		included[cell] = true
		cells.append(cell)
	return cells


## Serialize the exact reference, orientation, origin, and support contract.
func to_json() -> Dictionary:
	var data := {
		"asset": asset_id,
		"origin": [origin.x, origin.y, origin.z],
		"forward": K.face_name(forward_face),
		"roll": K.normalized_quarters(roll_quarters),
		"yaw": K.normalized_yaw_eighths(yaw_eighths),
	}
	if support != SUPPORT_NONE:
		data["support"] = support
	if support == SUPPORT_WALL:
		data["support_face"] = K.face_name(support_face)
	return data


## Load one prop record, migrating old four-way direct-facing saves on input.
##
## Records written while props stored their own support_height_m simply drop it:
## the elevation is derived from the canonical terrain, so an old saved value has
## no authority over where the prop now stands.
static func from_json(data: Dictionary) -> PropPlacement:
	var placement := PropPlacement.new()
	placement.asset_id = String(data.get("asset", ""))
	placement.support = String(data.get("support", SUPPORT_NONE))
	if data.has("support_face"):
		placement.support_face = K.face_from_name(String(data["support_face"]))
	elif placement.support == SUPPORT_WALL:
		push_error(
			"[Tile Studio] saved wall prop '%s' has no support face; exact wall contact cannot be derived."
			% placement.asset_id
		)
	var saved_origin: Array = data.get("origin", [0, 0, 0])
	if saved_origin.size() >= 3:
		placement.origin = Vector3i(
			int(saved_origin[0]),
			int(saved_origin[1]),
			int(saved_origin[2])
		)
	if data.has("forward"):
		placement.forward_face = K.face_from_name(String(data.get("forward", "-Z")))
		placement.roll_quarters = K.normalized_quarters(int(data.get("roll", 0)))
		placement.yaw_eighths = K.normalized_yaw_eighths(int(data.get("yaw", 0)))
	else:
		var legacy_facing := K.facing_from_name(String(data.get("facing", "N")))
		placement.forward_face = K.facing_to_forward_face(legacy_facing)
		placement.roll_quarters = 0
		placement.yaw_eighths = 0
	return placement
