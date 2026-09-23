@tool
class_name SurfacePlacement
extends Resource

## One image placement attached to exact canonical heightfield faces.
##
## TERRAIN_PAINT claims a face's base material, SHADER_DECAL composes into that
## material, and DECAL remains a native projected node. Overlay placements never
## claim paint occupancy, so their saved face attachments remain independent.

const K := preload("../utils/mts_constants.gd")

## The three explicit render roles for one stamped image placement.
##
## TERRAIN_PAINT claims the face's base material. DECAL projects through Godot's
## native decal pass. SHADER_DECAL is baked into per-face material arrays and read
## by the ordinary MTS terrain shader, so it shares lighting, parallax, fog, grids,
## and post-processing without a coplanar transparent draw.
enum Presentation { TERRAIN_PAINT, DECAL, SHADER_DECAL }

## The explicit grid anchor used by a surface placement.
##
## CELL keeps the ordinary footprint-minimum placement. JUNCTION stores the exact
## lattice vertex shared by the four surrounding face cells.
enum GridAnchor { CELL, JUNCTION }

## Shader decals use their height map through the board-wide parallax controls.
## No per-placement relief state or terrain/decal vertex displacement exists.

## Whether the decal albedo is remapped to the palette beneath its footprint.
##
## The choice is saved per placement because it changes the authored result and
## must be inspectable independently for native and shader decal placements.
@export var match_underlying_palette: bool = false
## The saved cell-centre or grid-edge anchor used by this exact placement.
@export var grid_anchor: GridAnchor = GridAnchor.CELL

@export var placement_uid: String = ""
@export var asset_id: String = ""
@export var origin: Vector3i = Vector3i.ZERO
@export var face: K.Face = K.Face.POS_Y
## In-plane rotation of the image, in 90 degree steps. Orthogonal only (spec 14).
@export var rotation_quarters: int = 0
## The placement's visible role; the material-paint UI writes this exact value.
@export var presentation: int = Presentation.TERRAIN_PAINT

## Stable TerrainMesh face identities receiving this placement.
##
## These are TerrainMesh.cell_top_uid / cell_side_uid strings ("t:x,z", "s:x,z,e,b")
## rather than integer lattice addresses. A cell's UID is invariant under sculpting,
## so either paint or decal stays attached when the terrain changes.
@export var terrain_face_uids: PackedStringArray = PackedStringArray()


## Assign a persistent random identity when this placement does not have one yet.
func _init() -> void:
	if placement_uid.is_empty():
		placement_uid = _new_uid()


## Return a new 128-bit hexadecimal identity for authored surface-local paint.
static func _new_uid() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


## Ensure migrated or programmatically created placements have a stable identity.
func ensure_uid() -> String:
	if placement_uid.is_empty():
		placement_uid = _new_uid()
	return placement_uid


## Create one terrain material region before exact face coverage is assigned.
static func create(p_asset_id: String, p_origin: Vector3i, p_face: int, p_quarters: int) -> SurfacePlacement:
	var placement := SurfacePlacement.new()
	placement.asset_id = p_asset_id
	placement.origin = p_origin
	placement.face = p_face
	placement.rotation_quarters = K.normalized_quarters(p_quarters)
	return placement


## Report whether this placement references valid authored input.
func reference_error() -> String:
	if asset_id.is_empty():
		return "surface placement at %s references no asset" % origin
	if presentation < Presentation.TERRAIN_PAINT or presentation > Presentation.SHADER_DECAL:
		return "surface placement at %s has an invalid presentation" % origin
	if grid_anchor < GridAnchor.CELL or grid_anchor > GridAnchor.JUNCTION:
		return "surface placement at %s has an invalid grid anchor" % origin
	if not is_overlay() and grid_anchor != GridAnchor.CELL:
		return "terrain paint at %s cannot use a decal grid-edge anchor" % origin
	return ""


## Return whether this placement creates a native Godot decal.
func is_decal() -> bool:
	return presentation == Presentation.DECAL


## Return whether this placement is an overlay drawn by the MTS surface shader.
func is_shader_decal() -> bool:
	return presentation == Presentation.SHADER_DECAL


## Return whether this placement layers over a face instead of claiming it.
##
## Every decal kind sits ON TOP of whatever material the face already shows, so
## none takes the face's paint slot and none displaces existing paint. Occupancy
## decisions ask this rather than naming a role, so adding a render role cannot
## leave it silently claiming a face it should only layer over.
func is_overlay() -> bool:
	return presentation != Presentation.TERRAIN_PAINT


## Return the unrotated spatial footprint declared by the canonical asset.
func canonical_footprint(asset: TileAsset) -> Vector2i:
	if asset == null:
		push_error("[Tile Studio] surface placement references missing asset '%s'." % asset_id)
		return Vector2i.ZERO
	return asset.surface_footprint()


## Return the spatial footprint after the authored in-plane quarter turn.
func rotated_footprint(asset: TileAsset) -> Vector2i:
	var footprint := canonical_footprint(asset)
	if K.normalized_quarters(rotation_quarters) % 2 == 1:
		return Vector2i(footprint.y, footprint.x)
	return footprint


## Return the positive lattice axes a footprint grows along for one grid face.
##
## These are occupancy axes, not visual texture axes. Cell placements grow from
## their origin, while edge placements use the same axes to name the pointed seam.
static func footprint_axes(p_face: int) -> Array:
	if K.is_horizontal_face(p_face):
		return [Vector3i(1, 0, 0), Vector3i(0, 0, 1)]
	if p_face == K.Face.POS_X or p_face == K.Face.NEG_X:
		return [Vector3i(0, 0, 1), Vector3i(0, 1, 0)]
	return [Vector3i(1, 0, 0), Vector3i(0, 1, 0)]


## Build the one canonical world transform for a surface with an explicit size.
##
## Placements, placeholders, collisions, and finished art all call this function
## so they cannot drift into separate coordinate conventions.
static func transform_for_size(
	cell: Vector3i,
	p_face: int,
	quarters: int,
	canonical_footprint: Vector2i,
	grid_anchor: int = GridAnchor.CELL
) -> Transform3D:
	var normalized_quarters := K.normalized_quarters(quarters)
	var footprint := canonical_footprint
	if normalized_quarters % 2 == 1:
		footprint = Vector2i(footprint.y, footprint.x)

	var axes := footprint_axes(p_face)
	var axis_u := Vector3(axes[0])
	var axis_v := Vector3(axes[1])
	var normal := Vector3(K.face_normal(p_face))
	var centre := Vector3(cell) + (axis_u * footprint.x + axis_v * footprint.y) * 0.5
	if grid_anchor == GridAnchor.JUNCTION:
		# Edge mode stores the exact grid vertex under the decal centre. Its basis
		# and authored footprint remain unchanged, so a 1 m decal stays 1 m.
		centre = Vector3(cell)

	# Positive side faces use the owning cell as their minimum coordinate, while
	# the -Y convention stores the cell immediately below its visible plane.
	if p_face == K.Face.NEG_Y:
		centre += Vector3(0, 1, 0)
	elif p_face == K.Face.POS_X or p_face == K.Face.POS_Z:
		centre += normal.abs()

	return Transform3D(K.face_basis(p_face, normalized_quarters), centre)


## Return the stable saved name of this placement's render role.
func presentation_name() -> String:
	match presentation:
		Presentation.DECAL:
			return "decal"
		Presentation.SHADER_DECAL:
			return "shader_decal"
		_:
			return "terrain_paint"


## Parse one saved render role, defaulting to ordinary terrain paint.
##
## An unknown name is reported because silently changing an authored presentation
## would make saved placement data disagree with the editor.
static func presentation_from_name(name: String) -> int:
	match name:
		"decal":
			return Presentation.DECAL
		"shader_decal":
			return Presentation.SHADER_DECAL
		"terrain_paint":
			return Presentation.TERRAIN_PAINT
		_:
			push_error(
				"[Tile Studio] unknown surface presentation '%s'; using terrain paint." % name
			)
			return Presentation.TERRAIN_PAINT


## Return the stable saved name of this placement's cell or junction anchor.
func grid_anchor_name() -> String:
	match grid_anchor:
		GridAnchor.CELL:
			return "cell"
		GridAnchor.JUNCTION:
			return "junction"
		_:
			push_error("[Tile Studio] cannot serialize invalid surface grid anchor %d." % grid_anchor)
			return "invalid"


## Parse one saved cell or junction anchor without silently accepting unknown data.
static func grid_anchor_from_name(name: String) -> int:
	match name:
		"cell":
			return GridAnchor.CELL
		"junction":
			return GridAnchor.JUNCTION
		_:
			push_error("[Tile Studio] unknown surface grid anchor '%s'." % name)
			return -1


## Serialize the placement and its stable terrain attachment.
func to_json() -> Dictionary:
	var data := {
		"uid": ensure_uid(),
		"asset": asset_id,
		"origin": [origin.x, origin.y, origin.z],
		"face": K.face_name(face),
		"rotation": K.normalized_quarters(rotation_quarters),
		"presentation": presentation_name(),
	}
	if not terrain_face_uids.is_empty():
		data["terrain_face_uids"] = Array(terrain_face_uids)
	# Palette matching changes both decal presentations and is therefore saved only
	# for those roles; terrain paint never consumes the setting.
	if is_overlay():
		data["match_underlying_palette"] = match_underlying_palette
		if grid_anchor != GridAnchor.CELL:
			data["grid_anchor"] = grid_anchor_name()
	return data


## Load one saved surface placement exactly as written.
static func from_json(data: Dictionary) -> SurfacePlacement:
	var placement := SurfacePlacement.new()
	var saved_uid := String(data.get("uid", ""))
	if not saved_uid.is_empty():
		placement.placement_uid = saved_uid
	placement.asset_id = String(data.get("asset", ""))
	var saved_origin: Array = data.get("origin", [0, 0, 0])
	if saved_origin.size() >= 3:
		placement.origin = Vector3i(
			int(saved_origin[0]),
			int(saved_origin[1]),
			int(saved_origin[2])
		)
	placement.face = K.face_from_name(String(data.get("face", "+Y")))
	placement.rotation_quarters = K.normalized_quarters(int(data.get("rotation", 0)))
	placement.presentation = presentation_from_name(
		String(data.get("presentation", "terrain_paint"))
	)
	placement.match_underlying_palette = bool(
		data.get("match_underlying_palette", false)
	)
	placement.grid_anchor = grid_anchor_from_name(String(data.get("grid_anchor", "cell")))
	var saved_uids: Variant = data.get("terrain_face_uids", [])
	if saved_uids is Array:
		for uid_value: Variant in saved_uids as Array:
			var uid := String(uid_value)
			if not uid.is_empty() and not placement.terrain_face_uids.has(uid):
				placement.terrain_face_uids.append(uid)
	return placement
