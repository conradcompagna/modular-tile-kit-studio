extends SceneTree

## Regression check proving terrain paint and native decal stamping coexist.

var _failures: int = 0


## Run the terrain paint and native Decal contract and return a failing process code on any violation.
func _init() -> void:
	_check_png_requires_terrain()
	_check_png_creates_no_spatial_render_node()
	_check_edge_anchor_selection_and_delete()
	_check_prepared_load_indexes_shader_decals()
	if _failures > 0:
		push_error("decal_surface_check: %d failure(s)" % _failures)
		quit(1)
		return
	print("decal_surface_check: PASS")
	quit(0)


## Record one failed invariant without hiding later diagnostics.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("decal_surface_check: %s" % message)


## Prove a PNG placement is invalid without exact terrain faces and indexed when conformed.
func _check_png_requires_terrain() -> void:
	var library := AssetLibrary.new()
	var asset := _surface_asset("TEST_TERRAIN_PAINT")
	library.add_asset(asset)
	var board := BoardDocument.new()
	board.bind_library(library)
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i.ONE)
	board.terrain.set_cell_filled(Vector2i.ZERO, true)

	var placement := SurfacePlacement.create(
		asset.asset_id,
		Vector3i.ZERO,
		MTSConstants.Face.POS_Y,
		0
	)
	_check(
		not bool(board.validate_surface(placement)["valid"]),
		"a PNG without exact terrain coverage must be rejected"
	)
	placement.terrain_face_uids = PackedStringArray(["t:0,0"])
	_check(
		bool(board.validate_surface(placement)["valid"]),
		"a PNG with an exact canonical terrain face must validate"
	)
	board.add_surface(placement)
	_check(
		board.surface_at_paint_uid("t:0,0") == placement,
		"terrain paint must use the one canonical directed-face index"
	)
	_check(
		not asset.has_method("is_decal")
		and not _has_property(asset, "surface_presentation")
		and not _has_property(asset, "decal_projection_depth_m"),
		"decal presentation must live on a placement, never on the reusable asset"
	)


## Prove a native Decal layers over ordinary terrain paint without creating mesh geometry.
func _check_png_creates_no_spatial_render_node() -> void:
	var asset := _surface_asset("TEST_NATIVE_DECAL")
	var paint := SurfacePlacement.create(
		asset.asset_id,
		Vector3i.ZERO,
		MTSConstants.Face.POS_Y,
		0
	)
	paint.terrain_face_uids = PackedStringArray(["t:0,0"])
	var decal := SurfacePlacement.create(
		asset.asset_id,
		Vector3i.ZERO,
		MTSConstants.Face.POS_Y,
		0
	)
	decal.presentation = SurfacePlacement.Presentation.DECAL
	decal.terrain_face_uids = paint.terrain_face_uids
	var library := AssetLibrary.new()
	library.add_asset(asset)
	var board := BoardDocument.new()
	board.bind_library(library)
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i.ONE)
	board.terrain.set_cell_filled(Vector2i.ZERO, true)
	board.add_surface(paint)
	_check(
		bool(board.validate_surface(decal)["valid"]),
		"a native decal must validate over terrain paint without claiming paint ownership"
	)
	board.add_surface(decal)
	var restored := SurfacePlacement.from_json(decal.to_json())
	_check(restored.is_decal(), "a decal placement must preserve its presentation in board JSON")
	_check(board.surfaces.size() == 2, "a native decal must layer over terrain paint")
	var viewport := MTSStudioViewport.new()
	viewport.board = board
	viewport.library = library
	viewport.material_factory = SurfaceMaterialFactory.new()
	var root := viewport._build_surface_node(decal, asset)
	_check(root != null, "the viewport must retain inspectable decal placement metadata")
	if root != null:
		var native_decal := root.get_child(0) as Decal
		_check(
			root.get_child_count() == 1 and native_decal != null,
			"a decal placement must create exactly one native Godot Decal node"
		)
		if native_decal != null:
			_check(
				native_decal.texture_albedo != null
				and native_decal.texture_normal != null
				and native_decal.texture_orm != null
				and native_decal.texture_emission != null,
				"the native Decal must receive its asset's supported PBR texture channels"
			)
		root.free()
	viewport.free()

	var material := SurfaceMaterialFactory.new().get_material(asset) as ShaderMaterial
	_check(
		material != null
		and material.shader != null
		and material.shader.code.contains("ALBEDO = albedo;")
		and material.shader.code.contains("ROUGHNESS = roughness_value;")
		and material.shader.code.contains("METALLIC = metallic_value;")
		and material.shader.code.contains("AO = clamp(ao_value, 0.0, 1.0);")
		and material.shader.code.contains("NORMAL = normalize(")
		and not material.shader.code.contains("BENT_NORMAL_MAP")
		and not material.shader.code.contains("bent_normal_tex")
		and not material.shader.code.contains("detail_normal_tex")
		and not material.shader.code.contains("cavity_tex")
		and not material.shader.code.contains("curvature_tex")
		and material.shader.code.contains("SPECULAR = clamp(specular_value, 0.0, 1.0);")
		and material.shader.code.contains("EMISSION = emission_value;"),
		"terrain PNGs use primary PBR outputs without derivative runtime samplers"
	)


## Prove edge decals save a four-cell junction, retain their size, and use normal selection deletion.
func _check_edge_anchor_selection_and_delete() -> void:
	var asset := _surface_asset("TEST_EDGE_DECAL")
	var library := AssetLibrary.new()
	library.add_asset(asset)
	var board := BoardDocument.new()
	board.bind_library(library)
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i.ONE)
	board.terrain.set_cell_filled(Vector2i.ZERO, true)
	var decal := SurfacePlacement.create(
		asset.asset_id,
		Vector3i(1, 0, 1),
		MTSConstants.Face.POS_Y,
		0
	)
	decal.presentation = SurfacePlacement.Presentation.DECAL
	decal.grid_anchor = SurfacePlacement.GridAnchor.JUNCTION
	decal.terrain_face_uids = PackedStringArray(["t:0,0"])
	board.add_surface(decal)
	var restored := SurfacePlacement.from_json(decal.to_json())
	var transform := SurfacePlacement.transform_for_size(
		decal.origin,
		decal.face,
		decal.rotation_quarters,
		Vector2i.ONE,
		decal.grid_anchor
	)
	var large_transform := SurfacePlacement.transform_for_size(
		decal.origin,
		decal.face,
		decal.rotation_quarters,
		Vector2i(4, 4),
		decal.grid_anchor
	)
	var wall_transform := SurfacePlacement.transform_for_size(
		Vector3i(2, 3, 5),
		MTSConstants.Face.POS_X,
		0,
		Vector2i(4, 4),
		SurfacePlacement.GridAnchor.JUNCTION
	)
	_check(
		restored.grid_anchor == SurfacePlacement.GridAnchor.JUNCTION
		and transform.origin.is_equal_approx(Vector3(1.0, 0.0, 1.0))
		and large_transform.origin.is_equal_approx(Vector3(1.0, 0.0, 1.0))
		and wall_transform.origin.is_equal_approx(Vector3(3.0, 3.0, 5.0)),
		"junction decals of any footprint retain their size around exact floor and wall vertices"
	)
	var edge_target := MTSTerrainRenderer.grid_edge_target_for_face(
		{
			"grid_cell": Vector3i.ZERO,
			"face": MTSConstants.Face.POS_Y,
		},
		Vector3(0.9, 0.0, 0.8),
		Vector3.UP
	)
	_check(
		edge_target.get("cell", Vector3i.ZERO) == Vector3i(1, 0, 1)
		and int(edge_target.get("grid_anchor", -1)) == SurfacePlacement.GridAnchor.JUNCTION
		and (edge_target.get("point", Vector3.ZERO) as Vector3).is_equal_approx(
			Vector3(1.0, 0.0, 1.0)
		),
		"the dedicated edge targeter returns the nearest shared lattice junction"
	)
	var wall_edge_target := MTSTerrainRenderer.grid_edge_target_for_face(
		{
			"grid_cell": Vector3i(2, 3, 4),
			"face": MTSConstants.Face.POS_X,
		},
		Vector3(3.0, 3.1, 4.9),
		Vector3.RIGHT
	)
	_check(
		wall_edge_target.get("cell", Vector3i.ZERO) == Vector3i(2, 3, 5)
		and int(wall_edge_target.get("grid_anchor", -1))
		== SurfacePlacement.GridAnchor.JUNCTION
		and (wall_edge_target.get("point", Vector3.ZERO) as Vector3).is_equal_approx(
			Vector3(3.0, 3.0, 5.0)
		),
		"the dedicated edge targeter returns the actual wall grid junction"
	)
	var viewport := MTSStudioViewport.new()
	viewport.board = board
	viewport.library = library
	viewport.material_factory = SurfaceMaterialFactory.new()
	viewport.surfaces_root = Node3D.new()
	viewport.props_root = Node3D.new()
	viewport.gameplay_markers_root = Node3D.new()
	viewport.add_child(viewport.surfaces_root)
	viewport.add_child(viewport.props_root)
	viewport.add_child(viewport.gameplay_markers_root)
	var visual := viewport._build_surface_node(decal, asset)
	viewport.surfaces_root.add_child(visual)
	viewport._surface_nodes_by_placement_id[decal.get_instance_id()] = visual
	get_root().add_child(viewport)
	_check(
		viewport._decal_at_terrain_hit(
			{"paint_uid": "t:0,0"},
			Vector3(1.0, 0.0, 1.0)
		) == decal,
		"the normal selection route resolves a decal through its projected footprint"
	)
	var controller := MTSPlacementController.new()
	controller.board = board
	controller.set_selected_placements([decal], decal)
	controller.delete_selection()
	_check(
		not board.surfaces.has(decal),
		"the existing selection Delete action removes the selected decal"
	)
	controller.free()
	viewport.free()


## Prove a staged board load leaves shader decals resolvable through the render lookup.
##
## commit_prepared_load() adopts a detached candidate's canonical records, and the
## terrain renderer finds a face's decal only through shader_decals_at_paint_uid().
## An adopt path that rebuilds some indexes but not the shader-decal one loads every
## decal into the document while rendering none of them -- a state the saved JSON
## cannot show, so it only ever surfaces as art silently missing after a reload.
func _check_prepared_load_indexes_shader_decals() -> void:
	var asset := _surface_asset("TEST_STAGED_SHADER_DECAL")
	var library := AssetLibrary.new()
	library.add_asset(asset)

	var staged := BoardDocument.new()
	staged.bind_library(library)
	staged.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i.ONE)
	staged.terrain.set_cell_filled(Vector2i.ZERO, true)
	var paint := SurfacePlacement.create(
		asset.asset_id,
		Vector3i.ZERO,
		MTSConstants.Face.POS_Y,
		0
	)
	paint.presentation = SurfacePlacement.Presentation.TERRAIN_PAINT
	paint.terrain_face_uids = PackedStringArray(["t:0,0"])
	staged.add_surface(paint)
	var decal := SurfacePlacement.create(
		asset.asset_id,
		Vector3i.ZERO,
		MTSConstants.Face.POS_Y,
		0
	)
	decal.presentation = SurfacePlacement.Presentation.SHADER_DECAL
	decal.terrain_face_uids = PackedStringArray(["t:0,0"])
	staged.add_surface(decal)
	# Version 13 persists an explicit palette mapping for every terrain face,
	# including unpainted skirt faces; this fixture must obey the save contract.
	var material_slots: Array = []
	for uid: String in staged.terrain.face_uid_set():
		material_slots.append({"uid": uid, "palette_indices": [-1, -1, -1, -1]})
	staged.surface_material_paint = {"material_slots": material_slots}

	# The receiving document starts with no decal index at all, which is exactly the
	# state a previously loaded board leaves behind before it adopts the next one.
	var live := BoardDocument.new()
	live.bind_library(library)
	_check(
		not live.has_shader_decals(),
		"a fresh document must start with no indexed shader decals"
	)

	var prepared: Dictionary = live.prepare_json(staged.to_json())
	_check(
		int(prepared.get("error", FAILED)) == OK and prepared.get("board", null) != null,
		"a board carrying one shader decal must stage without error"
	)
	if prepared.get("board", null) == null:
		return
	_check(
		live.commit_prepared_load(prepared["board"] as BoardDocument),
		"a staged board prepared from the same library must commit"
	)

	_check(
		live.has_shader_decals(),
		"an adopted board must report the shader decals it just loaded"
	)
	_check(
		live.shader_decals_at_paint_uid("t:0,0").size() == 1,
		"an adopted shader decal must resolve through the face lookup the renderer uses"
	)
	# The same adopt path owns the paint index, so proving one index is rebuilt must
	# not come at the cost of silently dropping another.
	var owner_placement := live.surface_at_paint_uid("t:0,0")
	_check(
		owner_placement != null and not owner_placement.is_shader_decal(),
		"terrain paint must still own its face after a staged load"
	)


## Create one minimal PNG material asset for terrain-path checks.
func _surface_asset(asset_id: String) -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = asset_id
	asset.display_name = asset_id
	asset.source_type = MTSConstants.SourceType.IMAGE_SURFACE
	asset.source_path = "res://icon.svg"
	asset.grid_bounds = Vector3i.ONE
	asset.visual_size_m = Vector3(1.0, 1.0, 0.0)
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", "res://icon.svg")
	asset.gbuffer.set_channel("normal", "res://icon.svg")
	asset.gbuffer.set_channel("orm", "res://icon.svg")
	asset.gbuffer.set_channel("emission", "res://icon.svg")
	return asset


## Return whether one Object still publishes a named serialized property.
func _has_property(object: Object, property_name: String) -> bool:
	for property: Dictionary in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false
