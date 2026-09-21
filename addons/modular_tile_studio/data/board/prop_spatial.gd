@tool
extends RefCounted

## Prop spatial behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Return the exact world position one prop's artwork and voxel volume both stand at.
##
## X and Z are the authored address and Y is the exact canonical support height.
## Physical placement is never quantized. The gameplay grid and solid index derive
## integer lookup keys from overlaps with the resulting world boxes, but those keys
## are not another pose. Anything that is drawn, collided with, or picked -- the
## artwork, physics shapes, occupancy overlay, and selection volume -- reads this
## one answer, so a pad flattened to 2.9 m cannot leave its blocker at 2 m.
static func prop_world_origin(host: BoardDocument, placement: PropPlacement) -> Vector3:
	if placement == null:
		return Vector3.ZERO
	if placement.support == PropPlacement.SUPPORT_WALL:
		var asset := host.resolve_prop_asset(placement)
		if asset == null:
			push_error(
				"[Tile Studio] cannot pose unresolved wall prop '%s'." % placement.asset_id
			)
			return Vector3(placement.origin)
		return Vector3(placement.origin) + placement.wall_mount_offset(asset)
	return Vector3(
		float(placement.origin.x),
		host.prop_terrain_support_height(placement),
		float(placement.origin.z)
	)


## Return one prop's measured voxel volume as offsets from prop_world_origin.
##
## These are the same oriented voxels the collision shapes and the spatial proxy
## are built from, handed out unshifted so every consumer applies the one world
## pose above instead of baking an integer level into the addresses.
static func prop_local_voxels(host: BoardDocument, placement: PropPlacement) -> Array[Vector3i]:
	if placement == null:
		return []
	return placement.oriented_voxels(
		host.resolve_prop_asset(placement),
		host.movement_collision_min_triangle_share_percent
	)


## Return the exact world-space boxes occupied by one prop's measured voxel scan.
##
## Every box is the local scan translated by prop_world_origin, which is the same
## placement used by the GLB artwork and editor physics. Integer gameplay cells
## may be derived from these boxes, but they never become a second physical pose.
static func prop_world_voxel_boxes(host: BoardDocument, placement: PropPlacement) -> Array[AABB]:
	var boxes: Array[AABB] = []
	if placement == null:
		return boxes
	var world_origin := host.prop_world_origin(placement)
	for voxel: Vector3i in host.prop_local_voxels(placement):
		boxes.append(AABB(world_origin + Vector3(voxel), Vector3.ONE))
	return boxes


## Return the integer lattice cells intersected by one prop's real world voxel boxes.
##
## Tactical lookups remain cell-addressed, but their cells are derived from the
## physical boxes after the exact GLB translation is applied. A fractionally lifted
## one-metre box therefore intersects both levels it actually crosses instead of
## being moved wholesale to the floored support level.
static func prop_occupied_cells(host: BoardDocument, placement: PropPlacement) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var included: Dictionary = {}
	for box: AABB in host.prop_world_voxel_boxes(placement):
		var box_end := box.position + box.size
		var minimum_cell := Vector3i(
			floori(box.position.x + TerrainMesh.LEVEL_EPSILON_M),
			floori(box.position.y + TerrainMesh.LEVEL_EPSILON_M),
			floori(box.position.z + TerrainMesh.LEVEL_EPSILON_M)
		)
		var maximum_cell := Vector3i(
			floori(box_end.x - TerrainMesh.LEVEL_EPSILON_M),
			floori(box_end.y - TerrainMesh.LEVEL_EPSILON_M),
			floori(box_end.z - TerrainMesh.LEVEL_EPSILON_M)
		)
		for cell_x: int in range(minimum_cell.x, maximum_cell.x + 1):
			for cell_y: int in range(minimum_cell.y, maximum_cell.y + 1):
				for cell_z: int in range(minimum_cell.z, maximum_cell.z + 1):
					var cell := Vector3i(cell_x, cell_y, cell_z)
					if included.has(cell):
						continue
					included[cell] = true
					cells.append(cell)
	return cells


## Return stable solid keys derived from one prop's exact world voxel boxes.
static func prop_solid_keys(host: BoardDocument, placement: PropPlacement) -> PackedStringArray:
	var keys := PackedStringArray()
	for cell: Vector3i in host.prop_occupied_cells(placement):
		keys.append(BoardDocument.K.voxel_key(cell))
	return keys


## Add one prop to the derived horizontal footprint index.
static func _index_prop_footprint(host: BoardDocument, placement: PropPlacement) -> void:
	if placement == null:
		return
	for cell: Vector2i in placement.footprint_cells(host.resolve_prop_asset(placement)):
		var indexed: Array[PropPlacement] = []
		for value: Variant in host._prop_footprint_index.get(cell, []) as Array:
			var existing := value as PropPlacement
			if existing != null:
				indexed.append(existing)
		if not indexed.has(placement):
			indexed.append(placement)
		host._prop_footprint_index[cell] = indexed


## Remove one prop from the derived horizontal footprint index.
static func _unindex_prop_footprint(host: BoardDocument, placement: PropPlacement) -> void:
	if placement == null:
		return
	for cell: Vector2i in placement.footprint_cells(host.resolve_prop_asset(placement)):
		var indexed: Array[PropPlacement] = []
		for value: Variant in host._prop_footprint_index.get(cell, []) as Array:
			var existing := value as PropPlacement
			if existing != null and existing != placement:
				indexed.append(existing)
		if indexed.is_empty():
			host._prop_footprint_index.erase(cell)
		else:
			host._prop_footprint_index[cell] = indexed


## Return only floor props whose horizontal footprints touch the supplied regions.
static func props_touching_terrain_regions(host: BoardDocument,
	regions: Array[Rect2i]
) -> Array[PropPlacement]:
	var result: Array[PropPlacement] = []
	var included: Dictionary = {}
	for region: Rect2i in regions:
		if region.size.x <= 0 or region.size.y <= 0:
			continue
		for local_z: int in region.size.y:
			for local_x: int in region.size.x:
				var cell := region.position + Vector2i(local_x, local_z)
				for value: Variant in host._prop_footprint_index.get(cell, []) as Array:
					var placement := value as PropPlacement
					if (
						placement == null
						or placement.support != PropPlacement.SUPPORT_FLOOR
						or included.has(placement.get_instance_id())
					):
						continue
					included[placement.get_instance_id()] = true
					result.append(placement)
	return result


## Snapshot old occupancy keys for props supported by terrain about to change.
##
## Terrain owns support height, so the old keys must be captured before the
## canonical height write; deriving them afterwards would leave stale voxels at
## the previous level.
static func capture_prop_support_state(host: BoardDocument, regions: Array[Rect2i]) -> Dictionary:
	var placements := host.props_touching_terrain_regions(regions)
	var solid_keys_by_id: Dictionary = {}
	for placement: PropPlacement in placements:
		solid_keys_by_id[placement.get_instance_id()] = host.prop_solid_keys(placement)
	return {
		"placements": placements,
		"solid_keys_by_id": solid_keys_by_id,
	}


## Reconcile only the prop supports captured before one regional terrain write.
static func reconcile_prop_support_state(host: BoardDocument, snapshot: Dictionary) -> Array[PropPlacement]:
	var reconciled: Array[PropPlacement] = []
	var solid_keys_by_id: Dictionary = snapshot.get("solid_keys_by_id", {})
	for value: Variant in snapshot.get("placements", []) as Array:
		var placement := value as PropPlacement
		if placement == null:
			continue
		var previous_keys: PackedStringArray = solid_keys_by_id.get(
			placement.get_instance_id(),
			PackedStringArray()
		)
		for key: String in previous_keys:
			if host._solid_index.get(key, null) == placement:
				host._solid_index.erase(key)
		for key: String in host.prop_solid_keys(placement):
			host._solid_index[key] = placement
		reconciled.append(placement)
	return reconciled
