@tool
extends RefCounted

## Brush geometry behavior for MTSPlacementController.
## The host retains Godot identity, signals, and authoritative state.

## Return whether the active asset is a surface.
static func brush_is_surface(host: MTSPlacementController) -> bool:
	return host.brush_asset != null and host.brush_asset.is_surface()


## Return whether the active asset is a prop.
static func brush_is_prop(host: MTSPlacementController) -> bool:
	return host.brush_asset != null and host.brush_asset.is_prop()


## Return whether the active brush claims canonical solid voxels.
static func brush_is_volume(host: MTSPlacementController) -> bool:
	return host.brush_is_prop()


## Return the active surface brush's canonical unrotated footprint.
static func _brush_surface_footprint(host: MTSPlacementController) -> Vector2i:
	if host.brush_asset != null:
		return host.brush_asset.surface_footprint()
	return Vector2i.ZERO


## Return the active surface footprint after its visible quarter-turn.
static func _brush_rotated_surface_footprint(host: MTSPlacementController) -> Vector2i:
	var footprint := host._brush_surface_footprint()
	if MTSPlacementController.K.normalized_quarters(host.brush_quarters) % 2 == 1:
		return Vector2i(footprint.y, footprint.x)
	return footprint


## Build one surface placement from the active brush asset.
static func _surface_placement_for_origin(host: MTSPlacementController, origin: Vector3i) -> SurfacePlacement:
	var placement := SurfacePlacement.create(
		host.brush_asset.asset_id,
		origin,
		host.brush_face,
		host.brush_quarters
	)
	placement.presentation = host.brush_surface_presentation
	placement.grid_anchor = (
		host._surface_grid_anchor
		if placement.is_overlay()
		else SurfacePlacement.GridAnchor.CELL
	)
	# Copied, not referenced: each placement records the visible palette choice
	# used when stamped rather than reading mutable global brush state later.
	placement.match_underlying_palette = host.brush_match_underlying_palette
	host._conform_texture_surface_to_terrain(placement)
	return placement


## Assign the exact canonical heightfield faces receiving one surface stamp.
##
## Returning an error instead of a planar fallback makes the heightfield a hard
## prerequisite and keeps painted regions and native decals in true address space.
static func _conform_texture_surface_to_terrain(host: MTSPlacementController, placement: SurfacePlacement) -> String:
	if placement == null or placement.asset_id.is_empty():
		return ""
	if host.board == null or host.board.terrain == null or host.board.terrain.is_empty():
		placement.terrain_face_uids.clear()
		return "surface stamping requires a heightfield"
	if host.terrain_renderer == null:
		placement.terrain_face_uids.clear()
		return "surface stamping cannot access the heightfield renderer"
	var asset := host.board.resolve_surface_asset(placement)
	if asset == null or not asset.is_surface():
		placement.terrain_face_uids.clear()
		return "surface stamping requires a valid PNG surface asset"
	placement.terrain_face_uids = host.terrain_renderer.surface_face_uids_for_placement(
		placement,
		asset,
		host.surface_grid_stroke_size_m
	)
	if placement.terrain_face_uids.is_empty():
		return "surface stamp touches no heightfield faces"
	return ""


## Return whether the explicit Wall brush is aimed at a vertical terrain grid face.
##
## The visible support selector and the literal clicked face must both say wall.
## This prevents an intercepted side triangle from turning a Floor placement into
## hidden wall support, while a ground click can never satisfy the wall contract.
static func _prop_is_wall_supported(host: MTSPlacementController) -> bool:
	return (
		host.brush_prop_support == PropPlacement.SUPPORT_WALL
		and Vector3(MTSPlacementController.K.face_normal(host._active_prop_support_face)).y == 0.0
	)


## Return the single prop forward face authored by the rotation controls.
##
## Terrain support selects only where the prop lands; top and side targets never
## rewrite the orientation that the arrow, preview, collision, and GLB all share.
static func _resolved_prop_forward_face(host: MTSPlacementController) -> int:
	return host.brush_prop_forward_face


## Return the single prop yaw authored by the rotation controls.
static func _resolved_prop_yaw_eighths(host: MTSPlacementController) -> int:
	return host.brush_prop_yaw_eighths


## Build one prop placement from the active brush asset.
static func _prop_placement_for_origin(host: MTSPlacementController, origin: Vector3i) -> PropPlacement:
	var forward_face := host._resolved_prop_forward_face()
	var yaw_eighths := host._resolved_prop_yaw_eighths()
	var placement := PropPlacement.create(
		host.brush_asset.asset_id,
		origin,
		forward_face,
		host.brush_prop_roll_quarters,
		yaw_eighths
	)
	# Support and orientation are independent canonical facts. Recording the
	# targeted terrain kind and exact hit face prevents a wall click from becoming
	# hidden rotation or losing the plane needed for real-mesh contact.
	placement.support = (
		PropPlacement.SUPPORT_WALL
		if host._prop_is_wall_supported()
		else PropPlacement.SUPPORT_FLOOR
	)
	placement.support_face = (
		host._active_prop_support_face
		if placement.support == PropPlacement.SUPPORT_WALL
		else MTSPlacementController.K.Face.POS_Y
	)
	# The elevation a floor prop rests at is derived from the canonical terrain
	# whenever it is needed rather than stored here, so sculpting the ground under
	# a prop cannot leave a stale height recorded against it.
	return placement


## Return the canonical preview tint used by every brush.
static func _brush_color(host: MTSPlacementController) -> Color:
	return Color(0.4, 0.9, 1.0)


## Return the canonical box owned by the active prop asset.
static func _brush_prop_canonical_bounds(host: MTSPlacementController) -> Vector3i:
	if host.brush_asset != null:
		return host.brush_asset.grid_bounds
	return Vector3i.ONE


## Return the canonical diagonal-aware transform for one brush placement origin.
static func _brush_prop_transform_for_origin(host: MTSPlacementController, origin: Vector3i) -> Transform3D:
	var transform := MTSPlacementController.K.prop_box_transform(
		host._brush_prop_canonical_bounds(),
		host._resolved_prop_forward_face(),
		host.brush_prop_roll_quarters,
		host._resolved_prop_yaw_eighths() if host.brush_is_prop() else 0
	)
	transform.origin += Vector3(origin)
	return transform


## Return the centre transform for a BoxMesh that represents one prop footprint.
static func _brush_prop_center_transform(host: MTSPlacementController, origin: Vector3i) -> Transform3D:
	var corner_transform := host._brush_prop_transform_for_origin(origin)
	return Transform3D(
		corner_transform.basis,
		corner_transform * (Vector3(host._brush_prop_canonical_bounds()) * 0.5)
	)


## Return the exact oriented collision voxels that one prop brush stamp will reserve.
##
## Preview, validation, committed collision, and selection all consume this same
## PropPlacement transform, including 45-degree yaw expansion onto the grid.
static func _brush_prop_preview_voxels(host: MTSPlacementController) -> Array[Vector3i]:
	if not host.brush_is_prop():
		return []
	var candidate := host._prop_placement_for_origin(Vector3i.ZERO)
	return candidate.oriented_voxels(host.brush_asset)


## Return the smallest axis-aligned box containing every exact preview collision voxel.
static func _brush_prop_preview_bounds(host: MTSPlacementController) -> AABB:
	var voxels := host._brush_prop_preview_voxels()
	if voxels.is_empty():
		return AABB()
	var minimum := Vector3(voxels[0])
	var maximum := minimum + Vector3.ONE
	for voxel: Vector3i in voxels:
		minimum = minimum.min(Vector3(voxel))
		maximum = maximum.max(Vector3(voxel) + Vector3.ONE)
	return AABB(minimum, maximum - minimum)


## Return the exact integer AABB occupied by the current volume brush.
static func _brush_box(host: MTSPlacementController) -> Vector3i:
	if host.brush_is_prop():
		return Vector3i(host._brush_prop_preview_bounds().size)
	return MTSPlacementController.K.oriented_prop_grid_bounds(
		host._brush_prop_canonical_bounds(),
		host.brush_prop_forward_face,
		host.brush_prop_roll_quarters,
		0
	)


## World transform for a surface quad on a given cell + face + rotation.
##
## Shared by the preview and the committed geometry so what the user sees while
## hovering is exactly what lands. Built from the SAME footprint axes that
## get_occupied_faces uses, so the art always covers the cells the placement
## actually claims.
static func surface_transform(
	cell: Vector3i,
	face: int,
	quarters: int,
	asset: TileAsset,
	grid_anchor: int = SurfacePlacement.GridAnchor.CELL
) -> Transform3D:
	if asset == null:
		push_error("[Tile Studio] cannot transform a surface without an asset.")
		return Transform3D.IDENTITY
	var canonical_footprint := asset.surface_footprint()
	return MTSPlacementController.surface_transform_for_size(
		cell,
		face,
		quarters,
		canonical_footprint,
		grid_anchor
	)


## Build a surface transform from one explicit unrotated footprint.
##
## Keeping this pure size path lets placeholders, highlights, collisions, and
## finished art share exactly the same placement math.
static func surface_transform_for_size(
	cell: Vector3i,
	face: int,
	quarters: int,
	canonical_footprint: Vector2i,
	grid_anchor: int = SurfacePlacement.GridAnchor.CELL
) -> Transform3D:
	return SurfacePlacement.transform_for_size(
		cell,
		face,
		quarters,
		canonical_footprint,
		grid_anchor
	)
