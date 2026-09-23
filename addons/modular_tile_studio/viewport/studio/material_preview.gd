@tool
extends RefCounted

## Material preview behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Refresh percentage-mask ranges from canonical height blocks and board bounds.
##
## Existing materials receive two scalar pairs only when requested; no mesh,
## texture array, contact field, collision, or GLB data is rebuilt.
static func _refresh_material_mask_ranges(host: MTSStudioViewport, update_existing_materials: bool = true) -> void:
	host._material_world_height_range = (
		host.world_surface_fields.height_value_range()
		if host.world_surface_fields != null
		else Vector2.ZERO
	)
	if host.board != null:
		var bounds := host._board_bounds()
		host._material_world_elevation_range = Vector2(
			bounds.position.y,
			bounds.end.y
		)
	else:
		host._material_world_elevation_range = Vector2(0.0, 1.0)
	if is_equal_approx(
		host._material_world_elevation_range.x,
		host._material_world_elevation_range.y
	):
		host._material_world_elevation_range.y += 1.0
	if not update_existing_materials:
		return
	for material: ShaderMaterial in host._all_surface_shader_materials():
		material.set_shader_parameter(
			"material_world_height_range",
			host._material_world_height_range
		)
		material.set_shader_parameter(
			"material_world_elevation_range",
			host._material_world_elevation_range
		)


## Return the live terrain materials without scene-wide scans.
##
## Terrain owns every visible surface material now, so this is simply the
## terrain renderer's batch materials with duplicates removed.
static func _all_surface_shader_materials(host: MTSStudioViewport) -> Array[ShaderMaterial]:
	var materials: Array[ShaderMaterial] = []
	if host.terrain_renderer == null:
		return materials
	var seen: Dictionary = {}
	for material: ShaderMaterial in host.terrain_renderer.terrain_shader_materials():
		if seen.has(material.get_instance_id()):
			continue
		seen[material.get_instance_id()] = true
		materials.append(material)
	return materials


## Apply the visible transient mask-preview choice to existing batch materials in place.
##
## The stored selection is a board palette index, while each batch receives a dedicated
## preview recipe that never consumes or changes one of its four authored RGBA slots.
static func set_material_mask_preview(host: MTSStudioViewport, enabled: bool, palette_index: int) -> void:
	host.material_mask_preview_enabled = enabled
	host.material_mask_preview_palette_index = maxi(palette_index, 0)
	for material: ShaderMaterial in host._all_surface_shader_materials():
		host._apply_material_mask_preview_to_material(material)
	host.request_render()


## Bind the selected recipe to one batch's transient preview uniforms.
static func _apply_material_mask_preview_to_material(host: MTSStudioViewport, material: ShaderMaterial) -> void:
	if material == null:
		return
	var preview_ready := false
	if (
		host.material_mask_preview_enabled
		and host.material_factory != null
		and host.board != null
		and host.material_mask_preview_palette_index < host.board.material_blend.layer_count()
	):
		preview_ready = host.material_factory.configure_material_mask_preview(
			material,
			host.material_mask_preview_palette_index,
			host.board.material_blend
		)
	material.set_shader_parameter(
		"material_mask_preview_enabled",
		host.material_mask_preview_enabled and preview_ready
	)


## Rebind one terrain batch after its first sparse control array is allocated.
##
## Only the heavy shader's control-array binding changes; terrain geometry,
## collision, contacts, other batches, and GLBs remain untouched.
static func _refresh_material_paint_batch(host: MTSStudioViewport, batch_key: String) -> void:
	if not MTSTerrainRenderer.is_terrain_batch_key(batch_key):
		push_error(
			"[Tile Studio] material paint reported non-terrain batch '%s'." % batch_key
		)
		return
	# Layer indices are assigned when the terrain batch is registered, even while
	# its control array is neutral. Allocating the first real array therefore
	# changes only the heavy shader binding; geometry and collision stay resident.
	if host.terrain_renderer != null and host.surface_material_paint != null:
		var chunk := MTSTerrainRenderer.chunk_from_batch_key(batch_key)
		for surface: Dictionary in host.terrain_renderer.chunk_surfaces(chunk):
			if String(surface["key"]) != batch_key:
				continue
			var material := host._terrain_surface_material(chunk, surface)
			if material != null:
				host.terrain_renderer.set_chunk_surface_material(
					chunk,
					int(surface["surface_index"]),
					material
				)
	host.request_render()


## Queue one face-local palette change for a single batched visual refresh this frame.
static func _on_material_palette_slots_changed(host: MTSStudioViewport, placement_uid: String) -> void:
	if host.terrain_renderer == null:
		return
	var cell_record := host.terrain_renderer.cell_for_paint_uid(placement_uid)
	if cell_record.is_empty():
		return
	var cell: Vector2i = cell_record["cell"]
	var changed_cell := Rect2i(cell, Vector2i.ONE)
	host._pending_material_slot_cells = (
		changed_cell
		if host._pending_material_slot_cells.size == Vector2i.ZERO
		else host._pending_material_slot_cells.merge(changed_cell)
	)
	if host._material_slot_refresh_queued:
		return
	host._material_slot_refresh_queued = true
	host.call_deferred("_flush_material_palette_slot_changes")


## Regroup only chunks whose faces changed RGBA palette meaning.
##
## Collision and canonical terrain remain resident. Multiple face assignments in one
## input frame merge into this one visual-batch rebuild, bounding the draw-call update.
static func _flush_material_palette_slot_changes(host: MTSStudioViewport) -> void:
	host._material_slot_refresh_queued = false
	var changed_cells := host._pending_material_slot_cells
	host._pending_material_slot_cells = Rect2i()
	if (
		changed_cells.size == Vector2i.ZERO
		or host.terrain_renderer == null
		or host.surface_material_paint == null
		or host.board == null
	):
		return
	var changed_chunks := host.terrain_renderer.refresh_paint_for_cells(
		changed_cells,
		host.surface_material_paint,
		host.board
	)
	host._apply_terrain_material_chunks(changed_chunks)
	host.request_render()
