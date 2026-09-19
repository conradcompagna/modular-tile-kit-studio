@tool
extends SceneTree

var _failed: int = 0


## Defer the terrain-paint integration probe until the SceneTree can initialize viewport resources.
func _init() -> void:
	_run.call_deferred()


## Exercise one continuous material stroke across exact heightfield faces without creating PNG geometry.
func _run() -> void:
	var library := AssetLibrary.new()
	var base := _surface_asset("INPUT_BASE", Vector2i(4, 4))
	var overlay := _surface_asset("INPUT_OVERLAY", Vector2i(4, 4))
	library.add_asset(base)
	library.add_asset(overlay)

	var board := BoardDocument.new()
	board.bind_library(library)
	board.terrain = _filled_terrain(Vector2i(4, 4))
	var base_surface := SurfacePlacement.create(
		base.asset_id,
		Vector3i.ZERO,
		MTSConstants.Face.POS_Y,
		0
	)
	for z: int in 4:
		for x: int in 4:
			base_surface.terrain_face_uids.append(
				TerrainMesh.cell_top_uid(Vector2i(x, z))
			)
	board.add_surface(base_surface)

	var brush_layer := MaterialBlendProfile.default_layer(0)
	brush_layer["enabled"] = true
	brush_layer["asset_id"] = overlay.asset_id
	brush_layer["application_mode"] = MaterialBlendProfile.ApplicationMode.BRUSH
	brush_layer["masks"] = [
		MaterialBlendProfile.default_rule(MaterialBlendProfile.MaskSource.PAINT, 0),
	]
	board.material_blend.set_layer(0, brush_layer)
	board.material_blend.enabled = true

	var viewport := MTSStudioViewport.new()
	viewport.size = Vector2(800, 600)
	get_root().add_child(viewport)
	await process_frame
	var factory := SurfaceMaterialFactory.new()
	viewport.bind(board, library, factory, null)
	viewport.frame_board()
	await process_frame
	await physics_frame

	# Reproduce the user-facing order that used to hide the complete terrain Fill
	# preview tree: choose a terrain drag tool first, then switch the top toolbar.
	viewport.set_tool(MTSPlacementController.Tool.PAINT)
	viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.RAISE)
	_check(
		not viewport.placement.visible,
		"ordinary terrain dragging hides the unrelated placement ghost"
	)
	viewport.set_tool(MTSPlacementController.Tool.FILL)
	_check(
		viewport.placement.terrain_fill_enabled and viewport.placement.visible,
		"terrain Fill arms its terrain target and keeps the shared preview owner visible"
	)

	# A hovered cell is derived preview state, not a clicked Fill vertex. It must
	# nevertheless show the exact outline before the first click.
	viewport.placement.hovered_cell = Vector3i(1, 0, 1)
	viewport.placement._refresh_fill_preview_from_hover()
	viewport.placement.update_preview_visibility()
	var terrain_fill_preview := viewport.placement.get_node_or_null(
		"PlacementPreview/FillPreview"
	) as Node3D
	var terrain_fill_guides := viewport.placement.get_node_or_null(
		"PlacementPreview/FillPreview/StampOutlinesAndPath"
	) as MeshInstance3D
	_check(
		terrain_fill_preview != null and terrain_fill_preview.is_visible_in_tree(),
		"terrain Fill displays its target before the first point is clicked"
	)
	_check(
		terrain_fill_guides != null
		and terrain_fill_guides.mesh != null
		and terrain_fill_guides.is_visible_in_tree(),
		"terrain Fill target guides contain visible geometry"
	)
	_check(
		viewport.placement.fill_vertex_count() == 0,
		"terrain Fill hover preview does not author a point"
	)
	viewport.placement.cancel_fill()
	viewport.set_height_sculpt_tool(MTSStudioViewport.HeightSculptTool.NONE)
	viewport.set_tool(MTSPlacementController.Tool.PAINT)

	var direct_root := viewport._surface_nodes_by_placement_id.get(
		base_surface.get_instance_id(),
		null
	) as Node3D
	_check(
		direct_root != null and direct_root.get_child_count() == 0,
		"the direct PNG owns metadata only and creates no quad, mesh, or collider"
	)

	var left_pick := viewport.terrain_renderer.pick_face(
		Vector3(1.9, 5.0, 1.5),
		Vector3.DOWN
	)
	var right_pick := viewport.terrain_renderer.pick_face(
		Vector3(2.1, 5.0, 1.5),
		Vector3.DOWN
	)
	_check(
		not left_pick.is_empty() and not right_pick.is_empty(),
		"canonical terrain picking resolves both sides of the grid seam"
	)
	var left_uid := String(left_pick.get("uid", ""))
	var right_uid := String(right_pick.get("uid", ""))
	_check(
		not left_uid.is_empty() and not right_uid.is_empty() and left_uid != right_uid,
		"adjacent terrain cells retain separate stable paint identities"
	)

	var chunk := Vector2i.ZERO
	var visual_ids_before := viewport.terrain_renderer.chunk_visual_instance_ids(chunk)
	var collision_id_before := viewport.terrain_renderer.chunk_collision_instance_id(chunk)
	var geometry_version_before := viewport.terrain_renderer.chunk_geometry_version(chunk)
	var mesh_ids_before := _terrain_mesh_ids(viewport)

	var start_hit := viewport._terrain_paint_hit(
		Vector3(1.9, 5.0, 1.5),
		Vector3(1.9, -5.0, 1.5)
	)
	var end_hit := viewport._terrain_paint_hit(
		Vector3(2.1, 5.0, 1.5),
		Vector3(2.1, -5.0, 1.5)
	)
	_check(
		String(start_hit.get("uid", "")) == left_uid
		and String(end_hit.get("uid", "")) == right_uid,
		"the viewport material targeter reports the exact heightfield face under the pointer"
	)

	viewport.set_material_brush_radius(0.2)
	viewport.set_material_pressure_controls(false, false)
	viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.PAINT)
	viewport._begin_material_paint(Vector2.ZERO, 1.0, false, start_hit)
	viewport._continue_material_paint(Vector2.ZERO, 1.0, false, end_hit)
	viewport._end_material_paint()
	await process_frame

	_check(
		viewport.surface_material_paint.has_image(left_uid)
		and viewport.surface_material_paint.has_image(right_uid),
		"one narrow world-space brush crosses the terrain-cell seam"
	)
	var left_image := viewport.surface_material_paint.image_for_uid(left_uid)
	var right_image := viewport.surface_material_paint.image_for_uid(right_uid)
	_check(
		_image_has_painted_weight(left_image)
		and _image_has_painted_weight(right_image),
		"both touched heightfield faces receive local splat pixels"
	)
	_check(
		_image_has_unpainted_weight(left_image)
		and _image_has_unpainted_weight(right_image),
		"the small brush leaves pixels outside its radius unchanged despite the 4 x 4 metre texture"
	)

	# Switch only the targeting shape: the same selected palette entry now receives
	# the exact face set produced by the existing one-metre base-coat tile targeter.
	viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
	viewport.set_surface_grid_stroke_size(1.0)
	viewport.set_material_brush_palette_index(0)
	viewport.set_material_brush_opacity(1.0)
	viewport.set_material_tile_paint_enabled(true)
	var tile_origin := Vector3i(1, 0, 1)
	viewport._on_terrain_material_tile_paint_requested(
		PackedStringArray([TerrainMesh.cell_top_uid(Vector2i(tile_origin.x, tile_origin.z))]),
		false,
		false,
		true
	)
	var tile_image := viewport.surface_material_paint.image_for_uid(left_uid)
	var tile_size := tile_image.get_size()
	_check(
		viewport.material_tile_paint_enabled
		and viewport.placement.terrain_splat_paint_enabled
		and tile_image.get_pixel(0, 0).r > 0.99
		and tile_image.get_pixel(tile_size.x - 1, 0).r > 0.99
		and tile_image.get_pixel(0, tile_size.y - 1).r > 0.99
		and tile_image.get_pixel(tile_size.x - 1, tile_size.y - 1).r > 0.99,
		"masked Tile brush fills the selected channel across the exact targeted terrain face"
	)
	_check(
		_image_has_unpainted_weight(right_image),
		"one-metre Tile brush leaves the adjacent untargeted terrain face unchanged"
	)

	viewport.set_material_tile_paint_enabled(false)

	var batch_key := String(
		viewport.surface_material_paint._batch_key_by_uid.get(left_uid, "")
	)
	var control_texture := viewport.surface_material_paint.batch_texture(batch_key)
	var batch_material := _terrain_material_for_batch(viewport, batch_key)
	_check(
		not batch_key.is_empty()
		and batch_material != null
		and batch_material.get_shader_parameter("material_control_tex") == control_texture,
		"paint weights feed the displayed terrain shader batch"
	)
	_check(
		batch_material != null
		and bool(batch_material.get_shader_parameter("terrain_triangle_instances"))
		and bool(batch_material.get_shader_parameter("material_layer_0_brush_authored")),
		"the canonical heavy shader renders the terrain triangles and brush mask"
	)

	# Mask constraint changes are uniform edits on the same live materials. Switching
	# back to paint-only is the exact No Constraint transition that previously rebuilt
	# every terrain batch.
	var constrained_profile_before := board.material_blend.to_json().duplicate(true)
	var constrained_layer := board.material_blend.layer(0)
	constrained_layer["masks"] = [
		MaterialBlendProfile.default_rule(MaterialBlendProfile.MaskSource.PAINT, 0),
		MaterialBlendProfile.default_rule(MaterialBlendProfile.MaskSource.BASE_HEIGHT, 0),
	]
	var material_ids_before_mask := _terrain_material_ids(viewport)
	board.material_blend.set_layer(0, constrained_layer)
	_check(
		viewport.refresh_material_profile_change(constrained_profile_before),
		"a non-height-field mask constraint refreshes successfully"
	)
	var no_constraint_profile_before := board.material_blend.to_json().duplicate(true)
	constrained_layer["masks"] = [
		MaterialBlendProfile.default_rule(MaterialBlendProfile.MaskSource.PAINT, 0),
	]
	board.material_blend.set_layer(0, constrained_layer)
	_check(
		viewport.refresh_material_profile_change(no_constraint_profile_before)
		and _terrain_material_ids(viewport) == material_ids_before_mask,
		"switching a painted layer to No Constraint preserves every terrain material instance"
	)

	_check(
		viewport.terrain_renderer.chunk_visual_instance_ids(chunk) == visual_ids_before
		and viewport.terrain_renderer.chunk_collision_instance_id(chunk) == collision_id_before
		and viewport.terrain_renderer.chunk_geometry_version(chunk) == geometry_version_before
		and _terrain_mesh_ids(viewport) == mesh_ids_before,
		"secondary material painting changes no terrain geometry, visual instance, or collision"
	)

	var original_resolution := left_image.get_size()
	_check(
		viewport.apply_material_paint_resolution(8, 32),
		"the visible paint-resolution action atomically resamples terrain masks"
	)
	await process_frame
	var reduced_resolution := board.material_blend.paint_resolution(Vector2i.ONE)
	var rebound_material := _terrain_material_for_batch(viewport, batch_key)
	_check(
		viewport.surface_material_paint.image_for_uid(left_uid).get_size() == reduced_resolution
		and reduced_resolution.x < original_resolution.x
		and rebound_material != null
		and rebound_material.get_shader_parameter("material_control_tex")
		== viewport.surface_material_paint.batch_texture(batch_key),
		"resolution changes replace only the derived control array bound to the same terrain batch"
	)
	_check(
		viewport.terrain_renderer.chunk_visual_instance_ids(chunk) == visual_ids_before
		and viewport.terrain_renderer.chunk_collision_instance_id(chunk) == collision_id_before
		and viewport.terrain_renderer.chunk_geometry_version(chunk) == geometry_version_before
		and _terrain_mesh_ids(viewport) == mesh_ids_before,
		"paint resolution never rebuilds terrain geometry or collision"
	)
	_check(board.surfaces.size() == 1, "the brush does not create additional PNG placements")
	_check(board.props.is_empty(), "the material brush never creates or edits GLB props")

	# A fifth palette entry must split only faces with a different local slot set, while
	# faces carrying the same set continue to share one renderer batch.
	var fifth_profile_before := board.material_blend.to_json().duplicate(true)
	var material_ids_before_unused_layer := _terrain_material_ids(viewport)
	var fifth_layer := MaterialBlendProfile.default_layer(
		board.material_blend.layer_count()
	)
	fifth_layer["enabled"] = true
	fifth_layer["asset_id"] = overlay.asset_id
	fifth_layer["application_mode"] = MaterialBlendProfile.ApplicationMode.BRUSH
	var fifth_palette_index := board.material_blend.layer_count()
	fifth_layer["masks"] = [
		MaterialBlendProfile.default_rule(
			MaterialBlendProfile.MaskSource.PAINT,
			fifth_palette_index
		),
		MaterialBlendProfile.default_rule(
			MaterialBlendProfile.MaskSource.BASE_HEIGHT,
			0
		),
	]
	fifth_palette_index = board.material_blend.add_layer(fifth_layer)
	_check(
		viewport.refresh_material_profile_change(fifth_profile_before)
		and _terrain_material_ids(viewport) == material_ids_before_unused_layer,
		"adding an unpainted palette layer preserves every terrain material instance"
	)
	await process_frame

	# Preview must evaluate its own transient recipe across every batch before the
	# selected palette entry has been allocated into any face-local RGBA slot.
	var preview_slots_before := viewport.surface_material_paint.palette_slots_for_uid(left_uid)
	viewport.set_material_mask_preview(true, fifth_palette_index)
	var preview_materials := viewport._all_surface_shader_materials()
	var preview_enabled_everywhere := not preview_materials.is_empty()
	for preview_material: ShaderMaterial in preview_materials:
		preview_enabled_everywhere = (
			preview_enabled_everywhere
			and bool(
				preview_material.get_shader_parameter(
					"material_mask_preview_enabled"
				)
			)
			and int(
				preview_material.get_shader_parameter(
					"material_mask_preview_count"
				)
			) == 2
		)
	_check(
		not preview_slots_before.has(fifth_palette_index)
		and preview_enabled_everywhere,
		"a fifth material previews on every eligible batch before any square is painted"
	)
	viewport.set_material_mask_preview(false, fifth_palette_index)
	viewport.set_material_brush_palette_index(fifth_palette_index)
	viewport.set_material_tile_paint_enabled(true)
	viewport._on_terrain_material_tile_paint_requested(
		PackedStringArray([left_uid]),
		false,
		false,
		true
	)
	await process_frame
	var left_fifth_slots := viewport.surface_material_paint.palette_slots_for_uid(left_uid)
	var left_fifth_batch := String(
		viewport.surface_material_paint._batch_key_by_uid.get(left_uid, "")
	)
	var right_identity_batch := String(
		viewport.surface_material_paint._batch_key_by_uid.get(right_uid, "")
	)
	_check(
		left_fifth_slots.has(fifth_palette_index)
		and left_fifth_batch != right_identity_batch,
		"a fifth palette material splits only the face whose local slot set changed"
	)
	viewport._on_terrain_material_tile_paint_requested(
		PackedStringArray([right_uid]),
		false,
		false,
		true
	)
	await process_frame
	_check(
		viewport.surface_material_paint.palette_slots_for_uid(right_uid)
		== left_fifth_slots
		and String(viewport.surface_material_paint._batch_key_by_uid.get(left_uid, ""))
		== String(viewport.surface_material_paint._batch_key_by_uid.get(right_uid, "")),
		"faces with the same four local palette slots continue to share one batch"
	)
	viewport.set_material_tile_paint_enabled(false)

	# Edge mode owns a distinct four-cell-junction target primitive. The ordinary
	# cell picker is not called before the renderer resolves the nearest vertex.
	var edge_decal_asset := _surface_asset("INPUT_EDGE_DECAL", Vector2i.ONE)
	library.add_asset(edge_decal_asset)
	viewport.arm_native_decal_brush(edge_decal_asset, false, true)
	var direct_edge_target := viewport.terrain_renderer.pick_grid_edge(
		Vector3(1.9, 5.0, 1.4),
		Vector3.DOWN
	)
	viewport.placement.update_hover_from_ray(
		Vector3(1.9, 5.0, 1.4),
		Vector3.DOWN
	)
	_check(
		direct_edge_target.get("cell", Vector3i.ZERO) == Vector3i(2, 0, 1)
		and int(direct_edge_target.get("grid_anchor", -1))
		== SurfacePlacement.GridAnchor.JUNCTION
		and viewport.placement.hovered_cell == Vector3i(2, 0, 1)
		and viewport.placement._surface_grid_anchor == SurfacePlacement.GridAnchor.JUNCTION,
		"decal Edge mode receives the nearest four-cell junction from its dedicated picker"
	)
	_check(
		viewport.placement.paint_at_hover(),
		"a junction-targeted decal commits through the ordinary placement controller"
	)
	var edge_decal := board.surfaces[board.surfaces.size() - 1]
	var edge_transform := SurfacePlacement.transform_for_size(
		edge_decal.origin,
		edge_decal.face,
		edge_decal.rotation_quarters,
		edge_decal.canonical_footprint(edge_decal_asset),
		edge_decal.grid_anchor
	)
	_check(
		edge_decal.origin == Vector3i(2, 0, 1)
		and edge_decal.grid_anchor == SurfacePlacement.GridAnchor.JUNCTION
		and edge_transform.origin.is_equal_approx(Vector3(2.0, 0.0, 1.0))
		and edge_decal.terrain_face_uids.has(left_uid)
		and edge_decal.terrain_face_uids.has(right_uid),
		"a saved 1 m decal centres on the shared junction without changing its size"
	)
	var edge_root := viewport._surface_nodes_by_placement_id.get(
		edge_decal.get_instance_id(),
		null
	) as Node3D
	var edge_projector := (
		edge_root.get_child(0) as Decal
		if edge_root != null and edge_root.get_child_count() > 0
		else null
	)
	_check(
		edge_projector != null
		and (edge_root.position + edge_projector.position).is_equal_approx(
			Vector3(2.0, 0.0, 1.0)
		)
		and is_equal_approx(edge_projector.size.x, 1.0)
		and is_equal_approx(edge_projector.size.z, 1.0),
		"the native projector remains exactly 1 x 1 m at the shared junction"
	)

	var surface_count_before_stack := board.surfaces.size()
	viewport.placement.update_hover_from_ray(
		Vector3(1.9, 5.0, 1.4),
		Vector3.DOWN
	)
	_check(
		viewport.placement.paint_at_hover(),
		"an overlapping native decal remains placeable"
	)
	var stacked_native_decal := board.surfaces[board.surfaces.size() - 1]
	_check(
		board.surfaces.size() == surface_count_before_stack + 1
		and board.surfaces.has(edge_decal)
		and board.surfaces.has(stacked_native_decal)
		and stacked_native_decal != edge_decal,
		"overlapping native decals coexist as separate selectable placements"
	)

	viewport.arm_shader_decal_brush(edge_decal_asset, false, true)
	viewport.placement.update_hover_from_ray(
		Vector3(1.9, 5.0, 1.4),
		Vector3.DOWN
	)
	_check(
		viewport.placement.paint_at_hover(),
		"a shader decal can coexist with overlapping native decals"
	)
	_check(
		board.surfaces.has(edge_decal)
		and board.surfaces.has(stacked_native_decal)
		and board.surfaces[board.surfaces.size() - 1].is_shader_decal(),
		"stamping a shader decal does not replace either native decal"
	)

	viewport.queue_free()
	await process_frame
	print("=== material viewport failures: %d ===" % _failed)
	quit(1 if _failed > 0 else 0)


## Return a rectangular regular heightfield with every allocated cell explicitly filled.
func _filled_terrain(size_cells: Vector2i) -> TerrainMesh:
	var terrain := TerrainMesh.create(Vector2i.ZERO, size_cells)
	for z: int in size_cells.y:
		for x: int in size_cells.x:
			terrain.set_cell_filled(Vector2i(x, z), true)
	return terrain


## Return whether a real stroke wrote at least one nonzero material weight.
func _image_has_painted_weight(image: Image) -> bool:
	if image == null:
		return false
	for y: int in image.get_height():
		for x: int in image.get_width():
			var color := image.get_pixel(x, y)
			if color.r + color.g + color.b + color.a > 0.0:
				return true
	return false


## Return whether one image retains at least one pixel outside the brush footprint.
func _image_has_unpainted_weight(image: Image) -> bool:
	if image == null:
		return false
	for y: int in image.get_height():
		for x: int in image.get_width():
			var color := image.get_pixel(x, y)
			if is_zero_approx(color.r + color.g + color.b + color.a):
				return true
	return false


## Return stable ShaderMaterial identities for every live terrain visual batch.
func _terrain_material_ids(viewport: MTSStudioViewport) -> PackedInt64Array:
	var ids := PackedInt64Array()
	for material: ShaderMaterial in viewport._all_surface_shader_materials():
		ids.append(material.get_instance_id())
	ids.sort()
	return ids


## Return stable mesh identities for every live terrain visual batch.
func _terrain_mesh_ids(viewport: MTSStudioViewport) -> PackedInt64Array:
	var ids := PackedInt64Array()
	for value: Variant in viewport.terrain_renderer.chunk_instances():
		var instance := value as MultiMeshInstance3D
		if instance != null and instance.multimesh != null and instance.multimesh.mesh != null:
			ids.append(instance.multimesh.mesh.get_instance_id())
	return ids


## Return the visible heavy shader bound to one exact terrain paint batch.
func _terrain_material_for_batch(
	viewport: MTSStudioViewport,
	batch_key: String
) -> ShaderMaterial:
	for value: Variant in viewport.terrain_renderer.chunk_instances():
		var instance := value as MultiMeshInstance3D
		if (
			instance != null
			and String(instance.get_meta("mts_batch_key", "")) == batch_key
		):
			return instance.material_override as ShaderMaterial
	return null


## Create one minimal direct PNG material with an explicit world-space repeat size.
func _surface_asset(asset_id: String, texture_size_m: Vector2i) -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = asset_id
	asset.display_name = asset_id
	asset.source_type = 0
	asset.source_path = "res://icon.svg"
	asset.grid_bounds = Vector3i(texture_size_m.x, texture_size_m.y, 1)
	asset.visual_size_m = Vector3(texture_size_m.x, texture_size_m.y, 0.0)
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", "res://icon.svg")
	return asset


## Record one integration assertion without hiding a failed condition.
func _check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS  %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s" % label)
