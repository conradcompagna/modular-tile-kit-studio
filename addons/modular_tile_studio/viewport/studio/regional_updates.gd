@tool
extends RefCounted

## Regional updates behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Synchronize only prop roots named by one GLB contact transaction.
static func _sync_contact_prop_nodes(host: MTSStudioViewport,
	support_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement]
) -> Dictionary:
	var affected_batch_keys: Dictionary = {}
	var removed_contact_ids := PackedStringArray()
	var props_to_stamp: Array[PropPlacement] = []
	var removed_ids: Dictionary = {}
	for prop: PropPlacement in removed_props:
		if prop == null:
			continue
		removed_ids[prop.get_instance_id()] = true
		var root := host._prop_nodes_by_placement_id.get(
			prop.get_instance_id(),
			null
		) as Node3D
		if not is_instance_valid(root):
			continue
		for key: String in (
			root.get_meta("mts_batch_keys", PackedStringArray())
			as PackedStringArray
		):
			affected_batch_keys[key] = true
		var contact_id := String(root.get_meta("mts_contact_id", ""))
		if not contact_id.is_empty():
			removed_contact_ids.append(contact_id)
		host.props_root.remove_child(root)
		root.queue_free()
		host._prop_nodes_by_placement_id.erase(prop.get_instance_id())

	for prop: PropPlacement in support_props:
		if prop == null or removed_ids.has(prop.get_instance_id()):
			continue
		var root := host._prop_nodes_by_placement_id.get(
			prop.get_instance_id(),
			null
		) as Node3D
		if not is_instance_valid(root):
			continue
		var old_keys := (
			root.get_meta("mts_batch_keys", PackedStringArray())
			as PackedStringArray
		)
		var old_contact_id := String(root.get_meta("mts_contact_id", ""))
		var moved := host._apply_prop_support_offset(root)
		var asset := host.board.resolve_prop_asset(prop)
		if asset == null:
			continue
		var current_keys := host._prop_batch_keys(prop, asset)
		root.set_meta("mts_batch_keys", current_keys)
		root.set_meta("mts_spatial_signature", host._placement_spatial_signature(prop))
		var current_contact_id := (
			host._prop_contact_id(prop)
			if prop.support != PropPlacement.SUPPORT_WALL
			else ""
		)
		root.set_meta("mts_contact_id", current_contact_id)
		if moved:
			for key: String in old_keys:
				affected_batch_keys[key] = true
			for key: String in current_keys:
				affected_batch_keys[key] = true
		if old_contact_id != current_contact_id:
			if not old_contact_id.is_empty():
				removed_contact_ids.append(old_contact_id)
			if not current_contact_id.is_empty():
				props_to_stamp.append(prop)

	for prop: PropPlacement in added_props:
		if prop == null:
			continue
		var asset := host.board.resolve_prop_asset(prop)
		if asset == null:
			push_error("[Tile Studio] added contact prop has no resolvable asset.")
			continue
		var root := host._build_prop_node(prop, asset)
		host.props_root.add_child(root)
		host._prop_nodes_by_placement_id[prop.get_instance_id()] = root
		for key: String in (
			root.get_meta("mts_batch_keys", PackedStringArray())
			as PackedStringArray
		):
			affected_batch_keys[key] = true
		if prop.support != PropPlacement.SUPPORT_WALL:
			props_to_stamp.append(prop)
		host._apply_slice_to_node(root)

	if not affected_batch_keys.is_empty():
		host._sync_prop_art_batches(affected_batch_keys)
	return {
		"removed_contact_ids": removed_contact_ids,
		"props_to_stamp": props_to_stamp,
	}


## Refresh wall and prop contact contributors only inside changed terrain regions.
static func _refresh_world_contacts_for_terrain_regions(host: MTSStudioViewport,
	regions: Array[Rect2i],
	removed_prop_contact_ids: PackedStringArray,
	props_to_stamp: Array[PropPlacement]
) -> void:
	if host.world_surface_fields == null or host.board == null or host.board.terrain == null:
		return
	var removed_wall_ids: Dictionary = {}
	for region: Rect2i in regions:
		for local_z: int in region.size.y:
			for local_x: int in region.size.x:
				var cell := region.position + Vector2i(local_x, local_z)
				for edge: int in 4:
					var source_id := "wall|%s" % TerrainMesh.band_uid(cell, edge, 0)
					if removed_wall_ids.has(source_id):
						continue
					removed_wall_ids[source_id] = true
					host.world_surface_fields.remove_contact_source(source_id, false)
	for contact_id: String in removed_prop_contact_ids:
		host.world_surface_fields.remove_contact_source(contact_id, false)

	var stamped_wall_ids: Dictionary = {}
	for region: Rect2i in regions:
		for face: Dictionary in host.board.terrain.terrain_faces(
			host.terrain_chunk_cells(),
			region
		):
			if (
				int(face["kind"]) != TerrainMesh.FaceKind.SIDE
				or int(face["band"]) != 0
			):
				continue
			var source_id := "wall|%s" % String(face["paint_uid"])
			if stamped_wall_ids.has(source_id):
				continue
			stamped_wall_ids[source_id] = true
			var segment := host._wall_contact_segment(
				face["grid_cell"] as Vector3i,
				int(face["face"])
			)
			if segment.is_empty():
				continue
			host.world_surface_fields.stamp_contact_segment(
				segment[0],
				segment[1],
				0.08,
				0.35,
				1.0,
				false,
				source_id
			)
	var stamped_props: Dictionary = {}
	for prop: PropPlacement in props_to_stamp:
		if prop == null or stamped_props.has(prop.get_instance_id()):
			continue
		stamped_props[prop.get_instance_id()] = true
		var asset := host.board.resolve_prop_asset(prop)
		if asset != null:
			host._stamp_prop_contact(prop, asset, false)
	host.world_surface_fields.upload_interaction()


## Drop released terrain-paint pixels from the live image cache and sidecar metadata.
static func _discard_released_terrain_paint(host: MTSStudioViewport, released: PackedStringArray) -> void:
	if released.is_empty():
		return
	if host.surface_material_paint != null:
		host.surface_material_paint.discard_paint_for_uids(released)
	var surviving: Array = []
	for entry_value: Variant in host.board.surface_material_paint.get("surfaces", []) as Array:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		if not released.has(String(entry.get("uid", ""))):
			surviving.append(entry)
	if host.board.surface_material_paint.has("surfaces"):
		host.board.surface_material_paint["surfaces"] = surviving


## Reposition only gameplay marker visuals whose cells touch changed terrain.
static func _refresh_gameplay_markers_for_terrain_regions(host: MTSStudioViewport,
	regions: Array[Rect2i]
) -> void:
	if host.gameplay_markers_root == null or host.board == null:
		return
	var changed_cells: Dictionary = {}
	for region: Rect2i in regions:
		for local_z: int in region.size.y:
			for local_x: int in region.size.x:
				changed_cells[
					region.position + Vector2i(local_x, local_z)
				] = true
	for child_value: Node in host.gameplay_markers_root.get_children():
		var root := child_value as Node3D
		if root == null:
			continue
		var marker := root.get_meta("mts_placement", null) as GameplayMarker
		if marker == null:
			continue
		var cell := Vector2i(marker.origin.x, marker.origin.z)
		if not changed_cells.has(cell):
			continue
		var previous_position := root.position
		root.position = host._marker_stand_position(marker)
		var bounds_value: Variant = root.get_meta("mts_bounds", null)
		if bounds_value is AABB:
			var bounds := bounds_value as AABB
			bounds.position += root.position - previous_position
			root.set_meta("mts_bounds", bounds)
		host._apply_slice_to_node(root)


## Reposition only terrain-attached particle roots whose cells changed.
static func _refresh_particle_effects_for_terrain_regions(host: MTSStudioViewport,
	regions: Array[Rect2i]
) -> void:
	if host.particle_effects_root == null or host.board == null:
		return
	var changed_cells: Dictionary = {}
	for region: Rect2i in regions:
		for local_z: int in region.size.y:
			for local_x: int in region.size.x:
				changed_cells[
					region.position + Vector2i(local_x, local_z)
				] = true
	for child_value: Node in host.particle_effects_root.get_children():
		var root := child_value as Node3D
		if root == null:
			continue
		var placement := root.get_meta(
			"mts_particle_placement",
			null
		) as ParticleEffectPlacement
		if (
			placement == null
			or placement.attachment != ParticleEffectPlacement.Attachment.TERRAIN
		):
			continue
		var cell := Vector2i(
			floori(placement.position.x),
			floori(placement.position.z)
		)
		if not changed_cells.has(cell):
			continue
		root.position = host._particle_effect_position(placement)
		root.set_meta("mts_layer_y", int(floorf(root.position.y)))
		host._apply_slice_to_node(root)


## Refresh only the height-range shader input changed by regional terrain contact.
static func _refresh_regional_material_height_range(host: MTSStudioViewport) -> void:
	if host.world_surface_fields == null:
		return
	host._material_world_height_range = host.world_surface_fields.height_value_range()
	for material: ShaderMaterial in host._all_surface_shader_materials():
		material.set_shader_parameter(
			"material_world_height_range",
			host._material_world_height_range
		)


## Synchronize one atomic GLB contact patch without any board-wide rebuild.
static func _sync_prop_terrain_regions(host: MTSStudioViewport,
	regions: Array[Rect2i],
	support_props: Array[PropPlacement],
	added_props: Array[PropPlacement],
	removed_props: Array[PropPlacement],
	terrain_paint_uids: PackedStringArray
) -> void:
	if host.board == null or host.board.terrain == null or regions.is_empty():
		return
	var changed_chunks: Array[Vector2i] = []
	if host.terrain_renderer != null:
		changed_chunks = host.terrain_renderer.refresh_visual_regions(
			host.board.terrain,
			regions,
			host.surface_material_paint,
			host.board
		)
		host.terrain_renderer.finalize_collision_chunks(changed_chunks)
		host._apply_terrain_material_chunks(changed_chunks)
	var released := host.board.prune_terrain_paint_uids(terrain_paint_uids)
	host._discard_released_terrain_paint(released)
	if host.world_surface_fields != null:
		host.world_surface_fields.project_terrain_regions(host.board.terrain, regions)

	var prop_sync := host._sync_contact_prop_nodes(
		support_props,
		added_props,
		removed_props
	)
	host._refresh_world_contacts_for_terrain_regions(
		regions,
		prop_sync.get("removed_contact_ids", PackedStringArray()),
		prop_sync.get("props_to_stamp", []) as Array[PropPlacement]
	)
	host._refresh_gameplay_markers_for_terrain_regions(regions)
	host._refresh_particle_effects_for_terrain_regions(regions)
	host._refresh_regional_material_height_range()
	if host.occupancy_overlay != null and host.occupancy_overlay.mode != MTSStudioViewport.OccupancyOverlay.Mode.OFF:
		# The diagnostic is intentionally monolithic; only an explicitly visible
		# overlay pays its complete redraw, while ordinary contact edits stay local.
		host.occupancy_overlay.rebuild()
	if not added_props.is_empty() or not removed_props.is_empty():
		host._rebuild_reflection_probe(host._profile())
	host._refresh_selection_highlights()
	host.terrain_changed.emit()
	host._emit_status()
	host.request_render()
