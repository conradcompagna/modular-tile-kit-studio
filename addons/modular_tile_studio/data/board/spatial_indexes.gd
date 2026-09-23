@tool
extends RefCounted

## Spatial indexes behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Rebuild every derived occupancy index from canonical placements.
##
## Terrain paint is indexed by stable TerrainMesh UID rather than by lattice
## address, so an authored material stays attached to the face it was painted on
## no matter how the heightfield beneath it is later sculpted.
static func rebuild_indexes(host: BoardDocument) -> void:
	host.rebuild_gameplay_indexes()
	host._paint_uid_index.clear()
	host._solid_index.clear()
	host._prop_footprint_index.clear()

	host._shader_decal_uid_index.clear()
	for placement: SurfacePlacement in host.surfaces:
		# Only material paint owns a terrain paint UID. Native decals remain
		# independent projector nodes; one shader decal may share each receiving
		# terrain face through its ordinary material.
		if placement.is_overlay():
			if placement.is_shader_decal():
				host._index_shader_decal(placement)
			continue
		for uid: String in placement.terrain_face_uids:
			host._paint_uid_index[uid] = placement

	# Spatial lookup keys are rebuilt from each prop's exact world voxel boxes.
	for placement: PropPlacement in host.props:
		host._index_spatial_placement(placement)


## Return whether one spatial placement resource belongs to this document.
static func _placement_belongs_to_board(host: BoardDocument, placement: Resource) -> bool:
	if placement is SurfacePlacement:
		return host.surfaces.has(placement as SurfacePlacement)
	if placement is PropPlacement:
		return host.props.has(placement as PropPlacement)
	return false


## Validate one partial transform state before any canonical record is mutated.
static func _spatial_state_is_valid(host: BoardDocument, placement: Resource, state: Dictionary) -> bool:
	var allowed_keys: PackedStringArray
	if placement is SurfacePlacement:
		allowed_keys = PackedStringArray([
			"origin",
			"face",
			"rotation_quarters",
			"terrain_face_uids",
		])
	elif placement is PropPlacement:
		allowed_keys = PackedStringArray([
			"origin",
			"forward_face",
			"roll_quarters",
			"yaw_eighths",
		])
	else:
		push_error("[Tile Studio] cannot transform an unsupported placement resource.")
		return false

	for key_value: Variant in state.keys():
		var key := String(key_value)
		if key not in allowed_keys:
			push_error("[Tile Studio] unsupported spatial state key '%s'." % key)
			return false
	if state.has("origin") and typeof(state["origin"]) != TYPE_VECTOR3I:
		push_error("[Tile Studio] placement origin must be a Vector3i.")
		return false
	for key: String in ["face", "forward_face", "rotation_quarters", "roll_quarters", "yaw_eighths"]:
		if state.has(key) and typeof(state[key]) != TYPE_INT:
			push_error("[Tile Studio] placement orientation '%s' must be an integer." % key)
			return false
	if state.has("face") and not BoardDocument.K.FACE_NORMALS.has(int(state["face"])):
		push_error("[Tile Studio] surface face is outside the canonical face set.")
		return false
	if state.has("forward_face") and not BoardDocument.K.FACE_NORMALS.has(int(state["forward_face"])):
		push_error("[Tile Studio] placement forward face is outside the canonical face set.")
		return false
	if state.has("rotation_quarters") and int(state["rotation_quarters"]) not in range(4):
		push_error("[Tile Studio] surface rotation must be between 0 and 3 quarter turns.")
		return false
	if state.has("roll_quarters") and int(state["roll_quarters"]) not in range(4):
		push_error("[Tile Studio] placement roll must be between 0 and 3 quarter turns.")
		return false
	if state.has("yaw_eighths") and int(state["yaw_eighths"]) not in range(8):
		push_error("[Tile Studio] prop yaw must be between 0 and 7 eighth turns.")
		return false
	return true


## Remove only one placement's current entries from the derived spatial indexes.
static func _unindex_spatial_placement(host: BoardDocument, placement: Resource) -> void:
	if placement is SurfacePlacement:
		var surface := placement as SurfacePlacement
		if surface.is_overlay():
			# Shader decals own no face but ARE drawn, so their own index has to
			# follow every move; native decals are drawn as their own nodes.
			if surface.is_shader_decal():
				host._unindex_shader_decal(surface)
			return
		for uid: String in surface.terrain_face_uids:
			if host._paint_uid_index.get(uid, null) == surface:
				host._paint_uid_index.erase(uid)
		return
	if placement is PropPlacement:
		var prop := placement as PropPlacement
		for key: String in host.prop_solid_keys(prop):
			if host._solid_index.get(key, null) == placement:
				host._solid_index.erase(key)
		host._unindex_prop_footprint(prop)


## Apply one already validated partial transform state to its canonical resource.
static func _apply_spatial_state(host: BoardDocument, placement: Resource, state: Dictionary) -> void:
	if state.has("origin"):
		placement.set("origin", state["origin"])
	if placement is SurfacePlacement:
		if state.has("face"):
			(placement as SurfacePlacement).face = int(state["face"])
		if state.has("rotation_quarters"):
			(placement as SurfacePlacement).rotation_quarters = int(state["rotation_quarters"])
		if state.has("terrain_face_uids"):
			var face_uids := PackedStringArray()
			for uid_value: Variant in state["terrain_face_uids"] as Array:
				face_uids.append(String(uid_value))
			(placement as SurfacePlacement).terrain_face_uids = face_uids
	elif placement is PropPlacement:
		if state.has("forward_face"):
			(placement as PropPlacement).forward_face = int(state["forward_face"])
		if state.has("roll_quarters"):
			(placement as PropPlacement).roll_quarters = int(state["roll_quarters"])
		if state.has("yaw_eighths"):
			(placement as PropPlacement).yaw_eighths = int(state["yaw_eighths"])


## Add only one placement's current entries to the derived spatial indexes.
static func _index_spatial_placement(host: BoardDocument, placement: Resource) -> void:
	if placement is SurfacePlacement:
		var surface := placement as SurfacePlacement
		if surface.is_overlay():
			if surface.is_shader_decal():
				host._index_shader_decal(surface)
			return
		for uid: String in surface.terrain_face_uids:
			host._paint_uid_index[uid] = surface
		return
	if placement is PropPlacement:
		var prop := placement as PropPlacement
		for key: String in host.prop_solid_keys(prop):
			host._solid_index[key] = placement
		host._index_prop_footprint(prop)


## Apply placement transforms while reindexing only the records that changed.
##
## Every old entry is removed before any record changes, so grouped moves remain
## atomic even when selected placements exchange cells. The caller owns the one
## scoped editor notification after this canonical mutation succeeds.
static func apply_placement_spatial_states(host: BoardDocument,
	targets: Array[Resource],
	states: Array[Dictionary]
) -> bool:
	if targets.size() != states.size():
		push_error("[Tile Studio] cannot apply mismatched placement transform state.")
		return false
	var seen_ids: Dictionary = {}
	for index: int in targets.size():
		var target := targets[index]
		if target == null or not host._placement_belongs_to_board(target):
			push_error("[Tile Studio] cannot transform a placement outside this board.")
			return false
		var instance_id := target.get_instance_id()
		if seen_ids.has(instance_id):
			push_error("[Tile Studio] cannot transform one placement twice in a single action.")
			return false
		seen_ids[instance_id] = true
		if not host._spatial_state_is_valid(target, states[index]):
			return false

	for target: Resource in targets:
		host._unindex_spatial_placement(target)
	for index: int in targets.size():
		host._apply_spatial_state(targets[index], states[index])
	for target: Resource in targets:
		host._index_spatial_placement(target)
	return true
