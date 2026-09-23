@tool
extends RefCounted

## Surface indexes behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Return the surface placement painting one stable terrain face.
static func surface_at_paint_uid(host: BoardDocument, paint_uid: String) -> SurfacePlacement:
	return host._paint_uid_index.get(paint_uid, null) as SurfacePlacement


## Return the shader decal assigned to one terrain face as a typed array.
##
## The array shape keeps indexing code uniform, while validation enforces the
## direct-material invariant that at most one shader decal covers a face.
static func shader_decals_at_paint_uid(host: BoardDocument, paint_uid: String) -> Array[SurfacePlacement]:
	var found: Array[SurfacePlacement] = []
	var stored: Variant = host._shader_decal_uid_index.get(paint_uid, null)
	if stored is Array:
		for placement_value: Variant in stored as Array:
			var placement := placement_value as SurfacePlacement
			if placement != null:
				found.append(placement)
	return found


## Return whether any shader decal is currently attached to terrain.
##
## The renderer uses this index to group only affected faces into direct-material
## batches; no image or texture-array artifact is allocated.
static func has_shader_decals(host: BoardDocument) -> bool:
	return not host._shader_decal_uid_index.is_empty()


## Record one shader decal against every terrain face it covers.
static func _index_shader_decal(host: BoardDocument, placement: SurfacePlacement) -> void:
	for uid: String in placement.terrain_face_uids:
		var stored: Variant = host._shader_decal_uid_index.get(uid, null)
		var bucket: Array = stored if stored is Array else []
		if not bucket.has(placement):
			bucket.append(placement)
		host._shader_decal_uid_index[uid] = bucket


## Remove one shader decal from every terrain face it covered.
static func _unindex_shader_decal(host: BoardDocument, placement: SurfacePlacement) -> void:
	for uid: String in placement.terrain_face_uids:
		var stored: Variant = host._shader_decal_uid_index.get(uid, null)
		if not stored is Array:
			continue
		var bucket: Array = stored
		bucket.erase(placement)
		if bucket.is_empty():
			host._shader_decal_uid_index.erase(uid)
		else:
			host._shader_decal_uid_index[uid] = bucket


## Return the canonical solid placement occupying one voxel.
static func solid_placement_at(host: BoardDocument, cell: Vector3i) -> Resource:
	return host._solid_index.get(BoardDocument.K.voxel_key(cell), null) as Resource


## Return the prop claiming one solid voxel.
static func prop_at(host: BoardDocument, cell: Vector3i) -> PropPlacement:
	return host.solid_placement_at(cell) as PropPlacement
