@tool
extends RefCounted

## Synchronization behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Serialize one canonical placement record for derived-node change detection.
##
## Resource identity remains stable while Select moves or asset switching edit the
## record in place, so the derived node stores this value-only snapshot instead.
static func _placement_spatial_signature(host: MTSStudioViewport, placement_record: Resource) -> String:
	if placement_record is SurfacePlacement:
		return JSON.stringify((placement_record as SurfacePlacement).to_json())
	if placement_record is PropPlacement:
		return JSON.stringify({
			"placement": (placement_record as PropPlacement).to_json(),
			"movement_collision_min_triangle_share_percent": (
				host.board.movement_collision_min_triangle_share_percent
				if host.board != null
				else 0.0
			),
		})
	push_error("[Tile Studio] cannot sign an unsupported placement Resource.")
	return ""


## Rebuild every derived visual for bind, load, reset, or explicit recovery.
##
## Normal painting does not call this path; _sync_board_incremental() preserves
## unrelated nodes and surface batches while BoardDocument remains authoritative.
static func rebuild_board(host: MTSStudioViewport, frame_after: bool = false) -> void:
	if host.board == null:
		return
	if not host._full_rebuild_has_bounds:
		host._full_rebuild_bounds = host.board.compute_bounds()
		host._full_rebuild_has_bounds = true

	for root: Node3D in [
		host.surfaces_root,
		host.surface_art_root,
		host.props_root,
		host.prop_art_root,
		host.gameplay_markers_root,
		host.particle_effects_root,
	]:
		if root == null:
			continue
		for child in root.get_children():
			root.remove_child(child)
			child.queue_free()

	host._surface_nodes_by_placement_id.clear()
	host._prop_nodes_by_placement_id.clear()
	host._prop_batches_by_key.clear()

	for surface: SurfacePlacement in host.board.surfaces:
		var surface_asset := host.board.resolve_surface_asset(surface)
		if surface_asset == null:
			push_error("[Tile Studio] surface has no resolvable asset.")
			continue
		var surface_node := host._build_surface_node(surface, surface_asset)
		host.surfaces_root.add_child(surface_node)
		host._surface_nodes_by_placement_id[surface.get_instance_id()] = surface_node

	for prop: PropPlacement in host.board.props:
		var prop_asset := host.board.resolve_prop_asset(prop)
		if prop_asset == null:
			push_error("[Tile Studio] prop has no resolvable asset.")
			continue
		var prop_node := host._build_prop_node(prop, prop_asset)
		host.props_root.add_child(prop_node)
		host._prop_nodes_by_placement_id[prop.get_instance_id()] = prop_node

	# Coverage changes emit synchronously and refresh terrain-supported GLB art.
	# Every prop root must therefore exist before coverage is allowed to change.
	host._ensure_world_surface_field_coverage()
	host._rebuild_world_contacts()
	host._rebuild_prop_art_batches()
	host._rebuild_gameplay_marker_visuals()
	host._rebuild_particle_effect_visuals()
	host._rebuild_reflection_probe(host._profile())

	if host.occupancy_overlay != null:
		host.occupancy_overlay.rebuild()
	if host.placement != null:
		# Rebuild the existing brush preview from the changed data without
		# reselecting that brush or changing Select/Paint ownership.
		host.placement.refresh_brush_preview()

	host._apply_slice()
	if frame_after:
		host._frame_board_from_bounds(host._full_rebuild_bounds)
	host._emit_status()
	host.request_render()
	host._full_rebuild_has_bounds = false


## Synchronize only placement-derived nodes affected by the latest board mutation.
##
## BoardDocument remains authoritative. The instance-id maps are derived lookup
## tables that let an add/remove preserve every unrelated collision node, prop
## hierarchy, and surface batch.
static func _sync_board_incremental(host: MTSStudioViewport,
	mutation_mask: int = MTSStudioViewport.PlacementController.BoardMutation.ALL
) -> void:
	if host.board == null or host.library == null:
		return
	if (mutation_mask & MTSStudioViewport.PlacementController.BoardMutation.ALL) == 0:
		push_error("[Tile Studio] incremental sync received no board category.")
		return
	var terrain_changed_in_action := (
		mutation_mask & MTSStudioViewport.PlacementController.BoardMutation.TERRAIN
	) != 0
	if terrain_changed_in_action:
		host.refresh_terrain()
	var sync_started_usec := Time.get_ticks_usec()

	# Coverage is expanded only after new roots exist. The field's changed signal
	# may then synchronize terrain support without observing a half-built board.
	var world_field_expanded := false
	var current_surface_ids: Dictionary = {}
	var added_surfaces: Array[SurfacePlacement] = []
	var removed_surfaces: Array[SurfacePlacement] = []

	if (mutation_mask & MTSStudioViewport.PlacementController.BoardMutation.SURFACES) != 0:
		for surface: SurfacePlacement in host.board.surfaces:
			var placement_id := surface.get_instance_id()
			current_surface_ids[placement_id] = true
			var existing_surface_node := host._surface_nodes_by_placement_id.get(
				placement_id,
				null
			) as Node3D
			if is_instance_valid(existing_surface_node):
				var current_signature := host._placement_spatial_signature(surface)
				if (
					String(existing_surface_node.get_meta("mts_spatial_signature", ""))
					== current_signature
				):
					continue
				removed_surfaces.append(surface)
				host.surfaces_root.remove_child(existing_surface_node)
				existing_surface_node.queue_free()
				host._surface_nodes_by_placement_id.erase(placement_id)

			var surface_asset := host.board.resolve_surface_asset(surface)
			if surface_asset == null:
				push_error("[Tile Studio] added surface has no resolvable asset.")
				continue
			var surface_node := host._build_surface_node(surface, surface_asset)
			host.surfaces_root.add_child(surface_node)
			host._surface_nodes_by_placement_id[placement_id] = surface_node
			added_surfaces.append(surface)
			host._apply_slice_to_node(surface_node)

		for placement_id_value: Variant in host._surface_nodes_by_placement_id.keys():
			var placement_id := int(placement_id_value)
			if current_surface_ids.has(placement_id):
				continue
			var surface_node := host._surface_nodes_by_placement_id.get(
				placement_id,
				null
			) as Node3D
			if is_instance_valid(surface_node):
				var removed_surface := surface_node.get_meta(
					"mts_placement",
					null
				) as SurfacePlacement
				if removed_surface != null:
					removed_surfaces.append(removed_surface)
				host.surfaces_root.remove_child(surface_node)
				surface_node.queue_free()
			host._surface_nodes_by_placement_id.erase(placement_id)

	var current_prop_ids: Dictionary = {}
	var added_props: Array[PropPlacement] = []
	var removed_props: Array[PropPlacement] = []
	var removed_prop_contact_ids := PackedStringArray()
	var affected_prop_batch_keys: Dictionary = {}

	if (mutation_mask & MTSStudioViewport.PlacementController.BoardMutation.PROPS) != 0:
		for prop: PropPlacement in host.board.props:
			var placement_id := prop.get_instance_id()
			current_prop_ids[placement_id] = true
			var existing_prop_node := host._prop_nodes_by_placement_id.get(
				placement_id,
				null
			) as Node3D
			if is_instance_valid(existing_prop_node):
				var current_signature := host._placement_spatial_signature(prop)
				if (
					String(existing_prop_node.get_meta("mts_spatial_signature", ""))
					== current_signature
				):
					continue
				for batch_key: String in (
					existing_prop_node.get_meta("mts_batch_keys", PackedStringArray())
					as PackedStringArray
				):
					affected_prop_batch_keys[batch_key] = true
				var previous_contact_id := String(
					existing_prop_node.get_meta("mts_contact_id", "")
				)
				if not previous_contact_id.is_empty():
					removed_prop_contact_ids.append(previous_contact_id)
				removed_props.append(prop)
				host.props_root.remove_child(existing_prop_node)
				existing_prop_node.queue_free()
				host._prop_nodes_by_placement_id.erase(placement_id)

			var prop_asset := host.board.resolve_prop_asset(prop)
			if prop_asset == null:
				push_error("[Tile Studio] added prop has no resolvable asset.")
				continue
			var prop_node := host._build_prop_node(prop, prop_asset)
			host.props_root.add_child(prop_node)
			host._prop_nodes_by_placement_id[placement_id] = prop_node
			for batch_key: String in (
				prop_node.get_meta("mts_batch_keys", PackedStringArray())
				as PackedStringArray
			):
				affected_prop_batch_keys[batch_key] = true
			added_props.append(prop)
			host._apply_slice_to_node(prop_node)

		for placement_id_value: Variant in host._prop_nodes_by_placement_id.keys():
			var placement_id := int(placement_id_value)
			if current_prop_ids.has(placement_id):
				continue
			var prop_node := host._prop_nodes_by_placement_id.get(
				placement_id,
				null
			) as Node3D
			if is_instance_valid(prop_node):
				for batch_key: String in (
					prop_node.get_meta("mts_batch_keys", PackedStringArray())
					as PackedStringArray
				):
					affected_prop_batch_keys[batch_key] = true
				var previous_contact_id := String(
					prop_node.get_meta("mts_contact_id", "")
				)
				if not previous_contact_id.is_empty():
					removed_prop_contact_ids.append(previous_contact_id)
				var removed_prop := prop_node.get_meta(
					"mts_placement",
					null
				) as PropPlacement
				if removed_prop != null:
					removed_props.append(removed_prop)
				host.props_root.remove_child(prop_node)
				prop_node.queue_free()
			host._prop_nodes_by_placement_id.erase(placement_id)

	world_field_expanded = host._ensure_world_surface_field_coverage()
	var surfaces_changed := not added_surfaces.is_empty() or not removed_surfaces.is_empty()
	var props_changed := not added_props.is_empty() or not removed_props.is_empty()
	var terrain_paint_cells := Rect2i()
	var ordinary_added_surfaces: Array[SurfacePlacement] = []
	var ordinary_removed_surfaces: Array[SurfacePlacement] = []
	for entry: Array in [[added_surfaces, ordinary_added_surfaces], [removed_surfaces, ordinary_removed_surfaces]]:
		for surface: SurfacePlacement in entry[0] as Array:
			var terrain_cells := host._terrain_cells_for_surface(surface)
			if terrain_cells.is_empty():
				(entry[1] as Array[SurfacePlacement]).append(surface)
				continue
			for terrain_cell: Vector2i in terrain_cells:
				var cell_rect := Rect2i(terrain_cell, Vector2i.ONE)
				terrain_paint_cells = (
					cell_rect
					if terrain_paint_cells.size.x <= 0
					else terrain_paint_cells.merge(cell_rect)
				)
	if terrain_paint_cells.size.x > 0 and host.terrain_renderer != null:
		var terrain_paint_chunks := host.terrain_renderer.refresh_paint_for_cells(
			terrain_paint_cells,
			host.surface_material_paint,
			host.board
		)
		host._apply_terrain_material_chunks(terrain_paint_chunks)

	var contacts_started_usec := Time.get_ticks_usec()
	if (
		terrain_changed_in_action
		or world_field_expanded
		or not ordinary_removed_surfaces.is_empty()
	):
		host._rebuild_world_contacts()
	elif (
		not ordinary_added_surfaces.is_empty()
		or not removed_prop_contact_ids.is_empty()
		or not added_props.is_empty()
	):
		host._update_world_contacts(
			ordinary_added_surfaces,
			removed_prop_contact_ids,
			added_props
		)
	var contacts_finished_usec := Time.get_ticks_usec()

	if props_changed:
		host._sync_prop_art_batches(affected_prop_batch_keys)
	var batches_finished_usec := Time.get_ticks_usec()

	if (
		host.occupancy_overlay != null
		and host.occupancy_overlay.mode != MTSStudioViewport.OccupancyOverlay.Mode.OFF
		and (surfaces_changed or props_changed or terrain_changed_in_action)
	):
		host.occupancy_overlay.rebuild()
	if surfaces_changed or props_changed or terrain_changed_in_action:
		host._rebuild_reflection_probe(host._profile())

	var sync_finished_usec := Time.get_ticks_usec()
	host._last_incremental_profile_ms = {
		"scan_and_nodes": float(contacts_started_usec - sync_started_usec) / 1000.0,
		"contacts": float(contacts_finished_usec - contacts_started_usec) / 1000.0,
		"prop_batches": float(batches_finished_usec - contacts_finished_usec) / 1000.0,
		"finalize": float(sync_finished_usec - batches_finished_usec) / 1000.0,
		"total": float(sync_finished_usec - sync_started_usec) / 1000.0,
	}
	host._emit_status()
	host.request_render()
