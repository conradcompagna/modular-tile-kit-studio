@tool
extends RefCounted

## World contacts behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Rebuild the complete derived grime texture without moving canonical prop roots.
static func _rebuild_world_contacts(host: MTSStudioViewport) -> void:
	host._rebuild_world_contact_textures()


## Restamp visual contact grime without rebuilding geometry.
static func _rebuild_world_contact_textures(host: MTSStudioViewport) -> bool:
	if host.world_surface_fields == null or host.board == null or host.library == null:
		push_error("[Tile Studio] cannot rebuild contact textures without bound board fields.")
		return false
	host.world_surface_fields.clear_contacts(false)
	host._stamp_wall_floor_contacts(false)
	for prop: PropPlacement in host.board.props:
		var prop_asset := host.board.resolve_prop_asset(prop)
		if prop_asset == null:
			continue
		host._stamp_prop_contact(prop, prop_asset, false)
	host.world_surface_fields.upload_interaction()
	return true


## Update visual grime from only the structural and GLB contributors that changed.
static func _update_world_contacts(host: MTSStudioViewport,
	added_surfaces: Array[SurfacePlacement],
	removed_prop_contact_ids: PackedStringArray,
	added_props: Array[PropPlacement]
) -> void:
	if host.world_surface_fields == null or host.board == null or host.library == null:
		push_error("[Tile Studio] cannot update contacts without bound world fields.")
		return
	var contact_started_usec := Time.get_ticks_usec()
	for contact_id: String in removed_prop_contact_ids:
		host.world_surface_fields.remove_contact_source(contact_id, false)
	if not added_surfaces.is_empty():
		# A new floor can create contact under an existing wall. Wall contributors
		# retain stable ids, so restamping them changes only their own field pixels.
		host._stamp_wall_floor_contacts(false)
	var removed_finished_usec := Time.get_ticks_usec()
	for prop: PropPlacement in added_props:
		var prop_asset := host.board.resolve_prop_asset(prop)
		if prop_asset != null:
			host._stamp_prop_contact(prop, prop_asset, false)
	var stamped_finished_usec := Time.get_ticks_usec()
	host.world_surface_fields.upload_interaction()
	var uploaded_finished_usec := Time.get_ticks_usec()
	host._last_contact_profile_ms = {
		"remove": float(removed_finished_usec - contact_started_usec) / 1000.0,
		"stamp": float(stamped_finished_usec - removed_finished_usec) / 1000.0,
		"interaction_upload": float(uploaded_finished_usec - stamped_finished_usec) / 1000.0,
	}


## Return the exact XZ terrain cells covered by one surface placement.
##
## Occupied-face records are the canonical footprint, so large and clipped
## stamps never collapse back to their origin cell for paint invalidation.
static func _terrain_cells_for_surface(host: MTSStudioViewport, surface: SurfacePlacement) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if host.board == null or host.terrain_renderer == null or surface == null:
		return cells
	# Paint identifies its faces by stable UID, so the terrain renderer resolves
	# each one to the cell it currently occupies rather than trusting a stored
	# lattice address that sculpting may since have moved.
	for uid: String in surface.terrain_face_uids:
		var located: Dictionary = host.terrain_renderer.cell_for_paint_uid(uid)
		if located.is_empty():
			continue
		var cell_xz: Vector2i = located["cell"]
		if not cells.has(cell_xz):
			cells.append(cell_xz)
	return cells


## Reconfigure the editable field coverage for unusually large boards. This is
## an editor/rendering operation, deliberately absent from LLM placement JSON.
static func configure_world_surface_fields(host: MTSStudioViewport, origin_xz: Vector2, size_xz: Vector2, resolution: Vector2i = Vector2i(1024, 1024)) -> void:
	if host.world_surface_fields != null:
		host.world_surface_fields.configure(origin_xz, size_xz, resolution)
		host.rebuild_board()


## Refresh material consumers after a world-field texture changes.
##
## World fields are derived rendering data. They never move placement roots,
## collision, selection bounds, or GLB batches.
static func _on_world_surface_fields_changed(host: MTSStudioViewport, _kind: String) -> void:
	if host.material_factory != null:
		host.material_factory.world_fields = host.world_surface_fields
		host.material_factory.apply_global_effects(host.board.aesthetics if host.board != null else null)
	host.request_render()


## Build one stable support identifier from the prop's canonical placement record.
static func _prop_contact_id(host: MTSStudioViewport, prop: PropPlacement) -> String:
	if prop == null:
		return ""
	return "%s|%d,%d,%d|%s" % [
		prop.asset_id,
		prop.origin.x,
		prop.origin.y,
		prop.origin.z,
		prop.orientation_key(),
	]


## Stamp grime lines where a terrain wall meets the ground at its base.
##
## Contacts derive from the terrain's own side faces rather than from whether a
## PNG happened to be painted there, so an unpainted wall and a painted wall of
## identical geometry produce identical grime. Only the lowest band of each wall
## is stamped, because that is the band that actually touches the floor.
static func _stamp_wall_floor_contacts(host: MTSStudioViewport, upload: bool = true) -> void:
	if host.world_surface_fields == null or host.board == null or host.board.terrain == null:
		return
	if host.board.terrain.is_empty():
		if upload:
			host.world_surface_fields.upload_interaction()
		return
	for face: Dictionary in host.board.terrain.terrain_faces(host.terrain_chunk_cells()):
		if int(face["kind"]) != TerrainMesh.FaceKind.SIDE:
			continue
		if int(face["band"]) != 0:
			continue
		var cell: Vector2i = face["cell"]
		var grid_face := int(face["face"])
		var grid_cell := Vector3i(
			cell.x,
			TerrainMesh.level_of_height(float(face["bottom_m"])),
			cell.y
		)
		var segment := host._wall_contact_segment(grid_cell, grid_face)
		if segment.is_empty():
			continue
		host.world_surface_fields.stamp_contact_segment(
			segment[0],
			segment[1],
			0.08,
			0.35,
			1.0,
			false,
			"wall|%s" % String(face["paint_uid"])
		)
	if upload:
		host.world_surface_fields.upload_interaction()


## Convert one occupied wall cell into its exact one-metre world XZ base segment.
static func _wall_contact_segment(host: MTSStudioViewport, cell: Vector3i, face: int) -> PackedVector2Array:
	match face:
		MTSStudioViewport.K.Face.POS_X:
			var positive_x := float(cell.x + 1)
			return PackedVector2Array([
				Vector2(positive_x, float(cell.z)),
				Vector2(positive_x, float(cell.z + 1)),
			])
		MTSStudioViewport.K.Face.NEG_X:
			var negative_x := float(cell.x)
			return PackedVector2Array([
				Vector2(negative_x, float(cell.z)),
				Vector2(negative_x, float(cell.z + 1)),
			])
		MTSStudioViewport.K.Face.POS_Z:
			var positive_z := float(cell.z + 1)
			return PackedVector2Array([
				Vector2(float(cell.x), positive_z),
				Vector2(float(cell.x + 1), positive_z),
			])
		_:
			var negative_z := float(cell.z)
			return PackedVector2Array([
				Vector2(float(cell.x), negative_z),
				Vector2(float(cell.x + 1), negative_z),
			])


## Stamp only the visual low-mesh contact grime for one floor prop.
static func _stamp_prop_contact(host: MTSStudioViewport, prop: PropPlacement, asset: TileAsset, upload: bool = true) -> void:
	if (
		host.world_surface_fields == null
		or host.board == null
		or host.board.aesthetics == null
		or prop == null
		or asset == null
	):
		return
	# A wall-mounted prop keeps its explicit face attachment and has no floor contact.
	if prop.support == PropPlacement.SUPPORT_WALL:
		return
	var contact_polygons := host._prop_contact_polygons(prop, asset)
	if contact_polygons.is_empty():
		push_error(
			"[Tile Studio] '%s' produced no real contact silhouette; contact was not replaced with its grid box."
			% asset.asset_id
		)
		return
	host.world_surface_fields.stamp_contact_polygons(
		contact_polygons,
		0.35,
		1.0,
		upload,
		host._prop_contact_id(prop)
	)
