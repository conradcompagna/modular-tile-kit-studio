@tool
extends SceneTree

var _failed: int = 0


## Defer the focused material-tile regression until global classes and viewport resources are ready.
func _init() -> void:
	_run.call_deferred()


## Record one failed invariant while allowing the remaining target-path checks to run.
func _check(condition: bool, message: String) -> void:
	if condition:
		print("  PASS  %s" % message)
		return
	_failed += 1
	push_error("MATERIAL TILE TARGETING CHECK FAILED: %s" % message)


## Exercise top and wall tile painting through the canonical base-coat target route.
func _run() -> void:
	var library := AssetLibrary.new()
	var base := _surface_asset("TILE_TARGET_BASE")
	var overlay := _surface_asset("TILE_TARGET_OVERLAY")
	library.add_asset(base)
	library.add_asset(overlay)

	var board := BoardDocument.new()
	board.bind_library(library)
	board.terrain = _stepped_terrain()
	var base_surface := SurfacePlacement.create(
		base.asset_id,
		Vector3i.ZERO,
		MTSConstants.Face.POS_Y,
		0
	)
	for z: int in 2:
		for x: int in 3:
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
	viewport.bind(board, library, SurfaceMaterialFactory.new(), null)
	await process_frame
	await physics_frame

	viewport.set_surface_grid_stroke_size(1.0)
	viewport.set_material_brush_palette_index(0)
	viewport.set_material_brush_opacity(1.0)
	viewport.set_material_layer_brush_asset(overlay)
	viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
	viewport.set_material_tile_paint_enabled(true)
	_check(
		viewport.material_paint_tool == MTSStudioViewport.MaterialPaintTool.NONE,
		"Tile mode leaves the free-floating pen path disarmed"
	)

	var top_origin := Vector3i(2, 0, 1)
	var top_uid := TerrainMesh.cell_top_uid(Vector2i(top_origin.x, top_origin.z))
	viewport.placement.update_hover_from_ray(
		Vector3(top_origin) + Vector3(0.5, 5.0, 0.5),
		Vector3.DOWN
	)
	var top_target_uids := viewport.placement.terrain_material_target_uids(
		top_origin,
		MTSConstants.Face.POS_Y
	)
	_check(
		viewport.placement.hovered_cell == top_origin
		and viewport.placement.terrain_splat_paint_face() == MTSConstants.Face.POS_Y
		and top_target_uids == PackedStringArray([top_uid]),
		"Top hover resolves exactly one base-coat tile UID"
	)
	_check(
		viewport.placement.brush_asset == overlay
		and viewport.placement._preview_mesh.material_override is ShaderMaterial
		and bool(
			(viewport.placement._preview_mesh.material_override as ShaderMaterial)
			.get_shader_parameter("has_albedo")
		)
		and viewport.placement._preview_arrow.visible,
		"Layer Tile reuses the selected PNG's textured preview and orientation arrow"
	)
	_check(
		viewport.placement.paint_at_hover(),
		"Top Tile stroke commits through PlacementController"
	)
	viewport._end_terrain_material_tile_stroke()
	_check(
		_image_is_full_channel(viewport.surface_material_paint.image_for_uid(top_uid), 0),
		"Top Tile stroke fills the complete selected face image"
	)
	viewport.placement.rotate_brush(MTSConstants.DIR_UP, true)
	var rotated_quarters := viewport.material_layer_rotation_quarters()
	_check(
		rotated_quarters != 0
		and viewport.placement._preview_root.visible
		and viewport.placement._preview_arrow.visible,
		"an ordinary Left-arrow brush step rotates the PNG without hiding its targeter"
	)
	_check(
		viewport.placement.paint_at_hover(),
		"repainting a full face can still commit a changed PNG orientation"
	)
	viewport._end_terrain_material_tile_stroke()
	var top_slot := viewport.surface_material_paint.weight_slot_for_palette(top_uid, 0)
	_check(
		top_slot >= 0
		and viewport.surface_material_paint.slot_rotations_for_uid(top_uid)[top_slot]
		== rotated_quarters,
		"Tile writes the regular brush quarter-turn into the targeted material slot"
	)
	_check(
		not viewport.surface_material_paint.has_image(
			TerrainMesh.cell_top_uid(Vector2i(1, 1))
		),
		"One-metre Top Tile stroke leaves its adjacent face untouched"
	)

	# Re-entering masked Tile mode restores hover-following until another explicit
	# direction key is pressed, so ordinary point-at-face painting remains available.
	viewport.set_material_tile_paint_enabled(false)
	viewport.set_material_tile_paint_enabled(true)
	var wall_target := _first_step_wall_target(viewport.terrain_renderer, board.terrain)
	_check(not wall_target.is_empty(), "The stepped fixture exposes a canonical side-wall UID")
	if not wall_target.is_empty():
		var wall_uid := String(wall_target.get("uid", ""))
		var wall_face := int(wall_target.get("face", -1))
		var wall_origin: Vector3i = wall_target.get("grid_cell", Vector3i.ZERO)
		var wall_polygon: PackedVector3Array = (
			viewport.terrain_renderer.face_polygon_for_paint_uid(wall_uid).duplicate()
		)
		_check(not wall_polygon.is_empty(), "The side-wall UID resolves to its rendered polygon")
		if not wall_polygon.is_empty():
			var wall_centre := Vector3.ZERO
			for point: Vector3 in wall_polygon:
				wall_centre += point
			wall_centre /= float(wall_polygon.size())
			var wall_normal := Vector3(MTSConstants.face_normal(wall_face))
			viewport.placement.update_hover_from_ray(
				wall_centre + wall_normal * 2.0,
				-wall_normal
			)
			var wall_target_uids := viewport.placement.terrain_material_target_uids(
				wall_origin,
				wall_face
			)
			_check(
				viewport.placement.hovered_cell == wall_origin
				and viewport.placement.terrain_splat_paint_face() == wall_face
				and wall_target_uids == PackedStringArray([wall_uid]),
				"Wall hover inherits the base-coat targeter's exact face and grid address"
			)
			for _repeat_index: int in 24:
				viewport.placement.update_hover_from_ray(
					wall_centre + wall_normal * 2.0,
					-wall_normal
				)
			var wall_polygon_after_hover := (
				viewport.terrain_renderer.face_polygon_for_paint_uid(wall_uid)
			)
			_check(
				viewport.placement._preview_root.visible
					and viewport.placement._preview_mesh.visible
					and viewport.placement._preview_mesh.mesh != null
					and not viewport._height_brush_preview.visible
					and wall_polygon_after_hover == wall_polygon,
				"Repeated side hover uses the base-coat preview without moving the face"
			)
			_check(
				viewport.placement.paint_at_hover(),
				"Wall Tile stroke commits through the same PlacementController route"
			)
			viewport._end_terrain_material_tile_stroke()
			_check(
				_image_is_full_channel(
					viewport.surface_material_paint.image_for_uid(wall_uid),
					0
				),
				"Wall Tile stroke fills the whole selected tile instead of a pen footprint"
			)
			var wall_slot := viewport.surface_material_paint.weight_slot_for_palette(wall_uid, 0)
			_check(
				wall_slot >= 0
				and viewport.surface_material_paint.slot_rotations_for_uid(wall_uid)[wall_slot]
				== rotated_quarters,
				"Wall Tile preserves the same selected PNG quarter-turn"
			)

			# A centered pen dab may reach the shared edge of a neighbouring wall band,
			# but its circular footprint has zero area there and must not create paint.
			var neighbouring_wall_uid := ""
			for candidate: Dictionary in viewport.terrain_renderer.splatmap_targets(
				wall_face
			):
				var candidate_origin: Vector3i = candidate.get(
					"grid_cell",
					Vector3i.ZERO
				)
				var candidate_uid := String(candidate.get("uid", ""))
				if (
					candidate_uid != wall_uid
					and candidate_origin.x == wall_origin.x
					and candidate_origin.z == wall_origin.z
				):
					neighbouring_wall_uid = candidate_uid
					break
			_check(
				not neighbouring_wall_uid.is_empty()
				and not viewport.surface_material_paint.has_image(
					neighbouring_wall_uid
				),
				"The stepped fixture exposes one initially unpainted adjacent wall band"
			)

			# The ordinary layered pen remains the same metric circular tool on side faces.
			viewport.set_material_tile_paint_enabled(false)
			viewport.set_material_brush_palette_index(1)
			viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.PAINT)
			var side_hit := viewport._terrain_paint_hit(
				wall_centre + wall_normal * 2.0,
				wall_centre - wall_normal * 2.0
			)
			viewport._draw_material_brush_preview(side_hit)
			_check(
				viewport._material_brush_preview.visible
					and not viewport._height_brush_preview.visible,
				"Layer pen side hover retains the circular material preview"
			)
			viewport._begin_material_paint(Vector2.ZERO, 1.0, false, side_hit)
			viewport._end_material_paint()
			var pen_slot := viewport.surface_material_paint.weight_slot_for_palette(
				wall_uid,
				1
			)
			_check(
				viewport.surface_material_paint.has_image(wall_uid)
					and not _image_is_full_channel(
						viewport.surface_material_paint.image_for_uid(wall_uid),
						1
					)
					and pen_slot >= 0
					and viewport.surface_material_paint.slot_rotations_for_uid(wall_uid)[
						pen_slot
					] == rotated_quarters,
				"Layer pen side stroke stays circular and consumes the same PNG orientation"
			)
			_check(
				not viewport.surface_material_paint.has_image(neighbouring_wall_uid),
				"A centered wall pen dab does not clamp onto and paint the adjacent wall band"
			)
			viewport.set_material_paint_tool(MTSStudioViewport.MaterialPaintTool.NONE)
			viewport.set_material_brush_palette_index(0)

	viewport.set_material_tile_paint_enabled(false)
	viewport.set_splatmap_tile_paint_enabled(true)
	viewport.placement.update_hover_from_ray(
		Vector3(top_origin) + Vector3(0.5, 5.0, 0.5),
		Vector3.DOWN
	)
	_check(
		viewport.placement._preview_root.visible
			and viewport.placement._preview_mesh.visible
			and viewport.placement._preview_mesh.mesh != null
			and not viewport._height_brush_preview.visible,
		"RGBA Tile mode uses the same base-coat PlacementController preview"
	)
	viewport.set_splatmap_tile_paint_enabled(false)
	viewport.queue_free()
	await process_frame
	print("=== material tile targeting failures: %d ===" % _failed)
	quit(1 if _failed > 0 else 0)


## Return the first renderer target belonging to a real authored step side rather than a skirt.
func _first_step_wall_target(
	renderer: MTSTerrainRenderer,
	terrain: TerrainMesh
) -> Dictionary:
	var side_records := terrain.side_face_records()
	if side_records.is_empty():
		return {}
	var side_record: Dictionary = side_records[0]
	var cell: Vector2i = side_record.get("cell", Vector2i.ZERO)
	var edge := int(side_record.get("edge", -1))
	if edge < TerrainMesh.EDGE_NORTH or edge > TerrainMesh.EDGE_WEST:
		return {}
	var wall_uid := TerrainMesh.band_uid(cell, edge, 0)
	var wall_face := int(TerrainMesh.EDGE_GRID_FACES[edge])
	for target: Dictionary in renderer.splatmap_targets(wall_face):
		if String(target.get("uid", "")) == wall_uid:
			return target
	return {}


## Return a small terrain with one two-metre step and therefore real vertical side bands.
func _stepped_terrain() -> TerrainMesh:
	var terrain := TerrainMesh.create(Vector2i.ZERO, Vector2i(3, 2))
	for z: int in 2:
		for x: int in 3:
			terrain.set_cell_filled(Vector2i(x, z), true)
	terrain.set_cell_top_level(Vector2i.ZERO, 2.0)
	return terrain


## Create one minimal direct PNG material asset for the terrain and blend layer.
func _surface_asset(asset_id: String) -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = asset_id
	asset.display_name = asset_id
	asset.source_type = MTSConstants.SourceType.IMAGE_SURFACE
	asset.grid_bounds = Vector3i.ONE
	asset.visual_size_m = Vector3(1.0, 1.0, 0.0)
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", "res://icon.svg")
	return asset


## Return whether every pixel stores full weight in exactly the selected RGBA channel.
func _image_is_full_channel(image: Image, channel: int) -> bool:
	if image == null or image.is_empty():
		return false
	for y: int in image.get_height():
		for x: int in image.get_width():
			var color := image.get_pixel(x, y)
			var selected: float = 0.0
			match channel:
				0:
					selected = color.r
				1:
					selected = color.g
				2:
					selected = color.b
				_:
					selected = color.a
			if selected < 0.99:
				return false
	return true
