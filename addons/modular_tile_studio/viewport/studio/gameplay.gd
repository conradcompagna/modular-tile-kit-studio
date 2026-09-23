@tool
extends RefCounted

## Gameplay behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Rebuild only gameplay-derived visuals after an external gameplay edit.
static func refresh_gameplay_visuals(host: MTSStudioViewport) -> void:
	host._rebuild_gameplay_marker_visuals()
	host._emit_status()
	host.request_render()


## Rebuild every derived view that can reference an asset removed from the open board.
static func refresh_level_asset_references(host: MTSStudioViewport) -> void:
	host._sync_board_incremental(
		MTSStudioViewport.PlacementController.BoardMutation.SURFACES
		| MTSStudioViewport.PlacementController.BoardMutation.PROPS
	)
	host.refresh_gameplay_visuals()
	host.refresh_material_blend_materials()


## Synchronize only gameplay marker visuals after a gameplay-tool mutation.
static func _sync_gameplay_marker_mutation(host: MTSStudioViewport) -> void:
	host._rebuild_gameplay_marker_visuals()
	host._emit_status()
	host.request_render()


## Synchronize only particle visuals after a particle-tool mutation.
static func _sync_particle_effect_mutation(host: MTSStudioViewport) -> void:
	host._rebuild_particle_effect_visuals()
	host._emit_status()
	host.request_render()


## Rebuild every derived particle node from the board's stable preset references.
## Return where one particle effect actually sits given its attachment mode.
##
## TERRAIN effects keep their authored X and Z and take Y from the canonical
## heightfield, so raising the ground under a campfire raises the campfire. WORLD
## effects keep the authored Y verbatim. An effect over unfilled terrain has no
## ground to attach to, so it keeps its authored position rather than snapping to
## an invented elevation.
static func _particle_effect_position(host: MTSStudioViewport, placement_record: ParticleEffectPlacement) -> Vector3:
	return placement_record.world_position(host.board.terrain if host.board != null else null)


## Rebuild every derived particle emitter from canonical board placements.
static func _rebuild_particle_effect_visuals(host: MTSStudioViewport) -> void:
	if host.particle_effects_root == null:
		return
	for child: Node in host.particle_effects_root.get_children():
		host.particle_effects_root.remove_child(child)
		child.queue_free()
	if host.board == null or host.particle_library == null or host.particle_factory == null:
		return
	for placement_record: ParticleEffectPlacement in host.board.particle_effects:
		if placement_record == null:
			push_error("[Tile Studio] Particle placement record is null.")
			continue
		var preset := host.particle_library.preset_by_id(placement_record.preset_id)
		if preset == null:
			push_error(
				"[Tile Studio] Particle placement '%s' references missing preset '%s'."
				% [placement_record.placement_id, placement_record.preset_id]
			)
			continue
		var emitter := host.particle_factory.build_emitter(preset, placement_record)
		if emitter == null:
			continue
		# A terrain-attached effect takes its height from the canonical heightfield
		# so sculpting moves it with the ground; a world effect keeps its authored Y.
		var emitter_position := host._particle_effect_position(placement_record)
		emitter.position = emitter_position
		emitter.set_meta("mts_layer_y", int(floorf(emitter_position.y)))
		host.particle_effects_root.add_child(emitter)
		host._apply_slice_to_node(emitter)


## Rebuild particle visuals after an explicit preset edit without changing board placement data.
static func refresh_particle_effects(host: MTSStudioViewport) -> void:
	host._rebuild_particle_effect_visuals()
	host._emit_status()
	host.request_render()


## Rebuild every derived marker gizmo from canonical gameplay marker resources.
static func _rebuild_gameplay_marker_visuals(host: MTSStudioViewport) -> void:
	if host.gameplay_markers_root == null:
		return
	for child: Node in host.gameplay_markers_root.get_children():
		host.gameplay_markers_root.remove_child(child)
		child.queue_free()
	if host.board == null:
		return
	for pack: EnemyPack in host.board.enemy_packs:
		if pack == null:
			push_error("[Tile Studio] enemy pack record is null.")
			continue
		var members_by_layer: Dictionary = {}
		for marker: GameplayMarker in host.board.gameplay_markers:
			if (
				marker == null
				or marker.marker_type != GameplayMarker.TYPE_ENEMY
				or marker.pack_id != pack.pack_id
			):
				continue
			var layer_y := marker.origin.y
			var layer_members: Array = members_by_layer.get(layer_y, [])
			layer_members.append(marker)
			members_by_layer[layer_y] = layer_members
		var sorted_layers: Array = members_by_layer.keys()
		sorted_layers.sort()
		for layer_value: Variant in sorted_layers:
			var layer_y := int(layer_value)
			var members: Array = members_by_layer[layer_y]
			var net := host._build_enemy_pack_net(pack, members, layer_y)
			host.gameplay_markers_root.add_child(net)
	for marker: GameplayMarker in host.board.gameplay_markers:
		if marker == null:
			push_error("[Tile Studio] gameplay marker record is null.")
			continue
		host.gameplay_markers_root.add_child(host._build_gameplay_marker_visual(marker))


## Build one compact net whose only input is canonical pack membership on one layer.
static func _build_enemy_pack_net(host: MTSStudioViewport,
	pack: EnemyPack,
	members: Array,
	layer_y: int
) -> Node3D:
	var root := Node3D.new()
	root.name = "EnemyPackNet_%s_Y%d" % [pack.pack_id, layer_y]
	root.set_meta("mts_pack_id", pack.pack_id)
	root.set_meta("mts_layer_y", layer_y)

	var points: Array[Vector3] = []
	var hub := Vector3(0.0, float(layer_y) + MTSStudioViewport.PACK_NET_HEIGHT_M, 0.0)
	for member_value: Variant in members:
		var marker := member_value as GameplayMarker
		if marker == null:
			continue
		var point := Vector3(marker.origin) + Vector3(
			0.5,
			MTSStudioViewport.PACK_NET_HEIGHT_M,
			0.5
		)
		points.append(point)
		hub += point
	if points.is_empty():
		return root
	hub /= float(points.size())

	var color := MTSGameplayMarkerController.pack_color(pack.pack_id)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(color.r, color.g, color.b, 0.78)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.render_priority = 2

	var immediate_mesh := ImmediateMesh.new()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, material)
	for point: Vector3 in points:
		host._add_enemy_pack_net_segment(
			immediate_mesh,
			point,
			hub,
			MTSStudioViewport.PACK_NET_WIDTH_M
		)
	var hub_points: Array[Vector3] = [
		hub + Vector3(MTSStudioViewport.PACK_NET_HUB_RADIUS_M, 0.0, 0.0),
		hub + Vector3(0.0, 0.0, MTSStudioViewport.PACK_NET_HUB_RADIUS_M),
		hub + Vector3(-MTSStudioViewport.PACK_NET_HUB_RADIUS_M, 0.0, 0.0),
		hub + Vector3(0.0, 0.0, -MTSStudioViewport.PACK_NET_HUB_RADIUS_M),
	]
	for hub_index in hub_points.size():
		host._add_enemy_pack_net_segment(
			immediate_mesh,
			hub_points[hub_index],
			hub_points[(hub_index + 1) % hub_points.size()],
			MTSStudioViewport.PACK_NET_WIDTH_M
		)
	immediate_mesh.surface_end()

	var net_mesh := MeshInstance3D.new()
	net_mesh.name = "Net"
	net_mesh.mesh = immediate_mesh
	net_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(net_mesh)
	host._apply_slice_to_node(root)
	return root


## Add one flat ribbon segment so a pack connection stays legible on the grid.
static func _add_enemy_pack_net_segment(host: MTSStudioViewport,
	immediate_mesh: ImmediateMesh,
	start: Vector3,
	end: Vector3,
	width: float
) -> void:
	var direction := end - start
	var horizontal_direction := Vector3(direction.x, 0.0, direction.z)
	if horizontal_direction.length_squared() <= 0.000001:
		return
	var side := Vector3(
		-horizontal_direction.z,
		0.0,
		horizontal_direction.x
	).normalized() * width * 0.5
	var start_left := start - side
	var start_right := start + side
	var end_left := end - side
	var end_right := end + side
	for vertex: Vector3 in [
		start_left,
		start_right,
		end_right,
		start_left,
		end_right,
		end_left,
	]:
		immediate_mesh.surface_add_vertex(vertex)


## Build one readable marker or its explicitly assigned GLB at the authored cell minimum.
## Return where one marker actually stands on the canonical terrain.
##
## The marker's authored address is its integer lattice cell, but the ground under
## that cell is at a real elevation the lattice cannot express. Deriving the drawn
## height from the terrain each rebuild is what keeps a marker on the surface after
## the heightfield beneath it is sculpted, instead of leaving it buried or floating.
## A marker over unfilled terrain has no ground to stand on, so it keeps its
## authored level rather than being silently relocated.
static func _marker_stand_position(host: MTSStudioViewport, marker: GameplayMarker) -> Vector3:
	var cell := Vector2i(marker.origin.x, marker.origin.z)
	if host.board == null or not host.board.terrain.is_cell_filled(cell):
		return Vector3(marker.origin)
	return Vector3(
		float(marker.origin.x),
		host.board.terrain.cell_walk_height(cell),
		float(marker.origin.z)
	)


static func _build_gameplay_marker_visual(host: MTSStudioViewport, marker: GameplayMarker) -> Node3D:
	var root := Node3D.new()
	root.name = "GameplayMarker_%s" % marker.marker_id
	var stand_position := host._marker_stand_position(marker)
	root.position = stand_position
	root.set_meta("mts_placement", marker)
	# The lattice level stays the marker's canonical address for slicing, while the
	# drawn height comes from the terrain so sculpting carries the marker with it.
	root.set_meta("mts_layer_y", marker.origin.y)
	root.set_meta(
		"mts_bounds",
		AABB(
			stand_position + Vector3(0.2, 0.0, 0.2),
			Vector3(0.6, 1.5, 0.6)
		)
	)

	var color := MTSGameplayMarkerController.marker_color(marker.marker_type)
	if marker.marker_type == GameplayMarker.TYPE_ENEMY and not marker.pack_id.is_empty():
		color = MTSGameplayMarkerController.pack_color(marker.pack_id)
	# Enemy pins identify the reusable monster type instead of an incidental
	# placement sequence such as enemy_1; other marker labels keep their ID.
	var marker_title := (
		marker.monster_id
		if marker.marker_type == GameplayMarker.TYPE_ENEMY
		else marker.marker_id
	)

	var visual_asset_id := ""
	if host.board != null and marker.marker_type == GameplayMarker.TYPE_ENEMY:
		visual_asset_id = host.board.monster_visual_asset_id(marker.monster_id)
	if not visual_asset_id.is_empty():
		var visual_asset := host.board.resolve_monster_visual_asset(marker.monster_id)
		if visual_asset == null:
			host._add_gameplay_marker_label(root, marker_title, Color(1.0, 0.25, 0.2), 1.28)
			host._apply_slice_to_node(root)
			return root
		var monster_visual := host._instantiate_monster_visual(marker.monster_id, visual_asset)
		if monster_visual == null:
			host._add_gameplay_marker_label(root, marker_title, Color(1.0, 0.25, 0.2), 1.28)
			host._apply_slice_to_node(root)
			return root
		root.add_child(monster_visual)
		root.set_meta(
			"mts_bounds",
			AABB(stand_position, Vector3(visual_asset.grid_bounds))
		)
		host._add_gameplay_marker_label(
			root,
			marker_title,
			color,
			maxf(visual_asset.visual_size_m.y + 0.25, 1.28)
		)
		host._apply_slice_to_node(root)
		return root

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = true
	material.render_priority = 3

	# The saved origin is the unit cell minimum. Local X/Z values of 0.5 derive
	# the visible cell centre while the canonical placement root stays unchanged.
	var stem := MeshInstance3D.new()
	stem.name = "Stem"
	var stem_mesh := CylinderMesh.new()
	stem_mesh.top_radius = 0.08
	stem_mesh.bottom_radius = 0.08
	stem_mesh.height = 0.7
	stem_mesh.radial_segments = 12
	stem.mesh = stem_mesh
	stem.position = Vector3(0.5, 0.35, 0.5)
	stem.material_override = material
	stem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(stem)

	var head := MeshInstance3D.new()
	head.name = "Head"
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.26
	head_mesh.height = 0.52
	head_mesh.radial_segments = 16
	head_mesh.rings = 8
	head.mesh = head_mesh
	head.position = Vector3(0.5, 0.82, 0.5)
	head.material_override = material
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)

	host._add_gameplay_marker_label(root, marker_title, color, 1.28)
	host._apply_slice_to_node(root)
	return root


## Instantiate one project-owned monster GLB from the same canonical pose used by prop sizing.
static func _instantiate_monster_visual(host: MTSStudioViewport, monster_id: String, asset: TileAsset) -> Node3D:
	var source_model := host._prop_model_for_asset(asset)
	if source_model == null:
		push_error("[Tile Studio] monster '%s' GLB could not be loaded." % monster_id)
		return null
	var visual := source_model.duplicate() as Node3D
	if visual == null:
		push_error("[Tile Studio] monster '%s' GLB hierarchy could not be instantiated." % monster_id)
		return null
	visual.name = "MonsterVisual"
	visual.transform = asset.prop_pose_transform
	host._set_backface_culling_recursive(
		visual,
		host.board.aesthetics.backface_culling_enabled
	)
	return visual


## Add the one-title-only label shared by pin and GLB monster presentations.
static func _add_gameplay_marker_label(host: MTSStudioViewport,
	root: Node3D,
	title: String,
	color: Color,
	height_m: float
) -> void:
	var label := Label3D.new()
	label.name = "MarkerLabel"
	label.position = Vector3(0.5, height_m, 0.5)
	label.text = title
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.no_depth_test = true
	label.font_size = 16
	label.outline_size = 5
	label.pixel_size = 0.003
	label.modulate = color
	root.add_child(label)
