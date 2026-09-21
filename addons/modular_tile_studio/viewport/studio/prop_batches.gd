@tool
extends RefCounted

## Prop batches behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Return the exact GLB batch keys touched by one canonical prop placement.
static func _prop_batch_keys(host: MTSStudioViewport, prop: PropPlacement, asset: TileAsset) -> PackedStringArray:
	var keys := PackedStringArray()
	if prop == null or asset == null:
		return keys
	var source_model := host._prop_model_for_asset(asset)
	if source_model == null:
		return keys
	for component: Dictionary in host._prop_mesh_components(source_model):
		var source_mesh := component["mesh_instance"] as MeshInstance3D
		if source_mesh != null:
			keys.append(host._prop_batch_key(prop, asset, source_mesh))
	return keys


## Rebuild every derived real-GLB batch after a full board rebuild or recovery.
static func _rebuild_prop_art_batches(host: MTSStudioViewport) -> void:
	if host.prop_art_root == null:
		return
	for child in host.prop_art_root.get_children():
		host.prop_art_root.remove_child(child)
		child.queue_free()
	host._prop_batches_by_key.clear()
	host._sync_prop_art_batches()


## Reconcile only GLB MultiMesh groups touched by the latest prop mutation.
##
## An empty affected set means an intentional full rebuild. Ordinary placement,
## drag, rotation, and deletion pass exact old/new keys so unrelated batches
## retain both their nodes and GPU instance buffers.
static func _sync_prop_art_batches(host: MTSStudioViewport, affected_keys: Dictionary = {}) -> void:
	if host.prop_art_root == null:
		return
	var groups := host._collect_prop_batch_groups(affected_keys)
	var keys_to_sync := affected_keys.duplicate()
	if keys_to_sync.is_empty():
		for key_value: Variant in groups.keys():
			keys_to_sync[String(key_value)] = true
		for key_value: Variant in host._prop_batches_by_key.keys():
			keys_to_sync[String(key_value)] = true

	for key_value: Variant in keys_to_sync.keys():
		var key := String(key_value)
		var batch := host._prop_batches_by_key.get(key, null) as MultiMeshInstance3D
		if not groups.has(key):
			if is_instance_valid(batch):
				host.prop_art_root.remove_child(batch)
				batch.queue_free()
			host._prop_batches_by_key.erase(key)
			continue
		if not is_instance_valid(batch):
			batch = MultiMeshInstance3D.new()
			host.prop_art_root.add_child(batch)
			host._prop_batches_by_key[key] = batch
		host._configure_prop_batch(batch, key, groups[key])


## Collect transforms only for requested GLB batches, or every batch for an explicit full rebuild.
##
## Filtering uses batch keys cached on each prop root, so unrelated high-poly GLB
## source hierarchies are never traversed by a local terrain edit.
static func _collect_prop_batch_groups(host: MTSStudioViewport, affected_keys: Dictionary = {}) -> Dictionary:
	var groups: Dictionary = {}
	if host.board == null or host.library == null:
		return groups

	for prop: PropPlacement in host.board.props:
		var asset := host.board.resolve_prop_asset(prop)
		if asset == null:
			continue
		var prop_root := host._prop_nodes_by_placement_id.get(prop.get_instance_id(), null) as Node3D
		if not is_instance_valid(prop_root):
			push_error("[Tile Studio] GLB batch has no spatial root for prop '%s'." % asset.asset_id)
			continue
		if not affected_keys.is_empty():
			var cached_keys_value: Variant = prop_root.get_meta(
				"mts_batch_keys",
				PackedStringArray()
			)
			var touches_affected_batch := false
			if cached_keys_value is PackedStringArray:
				for cached_key: String in cached_keys_value as PackedStringArray:
					if affected_keys.has(cached_key):
						touches_affected_batch = true
						break
			if not touches_affected_batch:
				continue
		var source_model := host._prop_model_for_asset(asset)
		if source_model == null:
			continue
		# Artwork begins at the same exact root transform as proxy and collision.
		var placement_transform := (
			prop_root.transform
			* prop.orientation_transform(asset)
			* asset.prop_pose_transform
		)
		for component: Dictionary in host._prop_mesh_components(source_model):
			var source_mesh := component["mesh_instance"] as MeshInstance3D
			var key := host._prop_batch_key(prop, asset, source_mesh)
			if not affected_keys.is_empty() and not affected_keys.has(key):
				continue
			var render_mesh := host._prop_render_mesh(source_mesh)
			if render_mesh == null:
				continue
			if not groups.has(key):
				groups[key] = {
					"asset": asset,
					"mesh": render_mesh,
					"layer_y": host._prop_slice_level(prop),
					"chunk_x": floori(float(prop.origin.x) / float(MTSStudioViewport.SURFACE_BATCH_CHUNK_SIZE_M)),
					"chunk_z": floori(float(prop.origin.z) / float(MTSStudioViewport.SURFACE_BATCH_CHUNK_SIZE_M)),
					"transforms": [],
				}
			var group: Dictionary = groups[key]
			var transforms: Array = group["transforms"]
			var component_transform: Transform3D = component["transform"]
			transforms.append(placement_transform * component_transform)

	return groups


## Gather static mesh components with transforms relative to the imported GLB root.
static func _prop_mesh_components(host: MTSStudioViewport, source_model: Node3D) -> Array[Dictionary]:
	var components: Array[Dictionary] = []
	if source_model == null:
		return components
	var cache_key := source_model.get_instance_id()
	if host._prop_mesh_components_cache.has(cache_key):
		var cached_components: Array[Dictionary] = host._prop_mesh_components_cache[cache_key]
		return cached_components
	for child in source_model.get_children():
		host._append_prop_mesh_components(
			child,
			Transform3D.IDENTITY,
			source_model.visible,
			components
		)
	host._prop_mesh_components_cache[cache_key] = components
	return components


## Preserve nested mesh transforms and visibility while rejecting animated data a static MultiMesh cannot represent.
static func _append_prop_mesh_components(host: MTSStudioViewport,
	node: Node,
	parent_transform: Transform3D,
	parent_visible: bool,
	components: Array[Dictionary]
) -> void:
	var node_transform := parent_transform
	var node_visible := parent_visible
	var node_3d := node as Node3D
	if node_3d != null:
		node_transform = parent_transform * node_3d.transform
		node_visible = parent_visible and node_3d.visible

	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and node_visible:
		if mesh_instance.skin != null:
			push_error(
				"[Tile Studio] GLB mesh '%s' uses skinning and cannot be rendered as a static MultiMesh prop."
				% mesh_instance.name
			)
		elif mesh_instance.mesh != null:
			components.append({
				"mesh_instance": mesh_instance,
				"transform": node_transform,
			})

	for child in node.get_children():
		host._append_prop_mesh_components(child, node_transform, node_visible, components)


## Return the derived material-preserving mesh used by one GLB component batch.
static func _prop_render_mesh(host: MTSStudioViewport, source: MeshInstance3D) -> Mesh:
	if source == null or source.mesh == null:
		return null
	var cache_key := "%d|%d|cull=%s" % [
		source.get_instance_id(),
		source.mesh.get_instance_id(),
		str(host._backface_culling_enabled()),
	]
	var cached := host._prop_render_mesh_cache.get(cache_key, null) as Mesh
	if cached != null:
		return cached

	var render_mesh := source.mesh.duplicate(false) as Mesh
	if render_mesh == null:
		push_error("[Tile Studio] Could not duplicate GLB mesh '%s' for MultiMesh rendering." % source.name)
		return null
	for surface_index in render_mesh.get_surface_count():
		render_mesh.surface_set_material(
			surface_index,
			host._prop_batch_material(source, surface_index)
		)
	host._prop_render_mesh_cache[cache_key] = render_mesh
	return render_mesh


## Return the exact authored material for one surface, optionally with the user-selected culling mode.
static func _prop_batch_material(host: MTSStudioViewport, source: MeshInstance3D, surface_index: int) -> Material:
	var material: Material = source.material_override
	if material == null:
		material = source.get_surface_override_material(surface_index)
	if material == null and source.mesh != null:
		material = source.mesh.surface_get_material(surface_index)
	if material == null or not host._backface_culling_enabled():
		return material

	var base_material := material as BaseMaterial3D
	if base_material == null:
		push_warning(
			"[Tile Studio] Back-face culling cannot override custom GLB material '%s' on '%s'."
			% [material.resource_path, source.name]
		)
		return material
	var culled_material := base_material.duplicate() as BaseMaterial3D
	if culled_material == null:
		push_error(
			"[Tile Studio] Failed to duplicate GLB material '%s' on '%s'."
			% [material.resource_path, source.name]
		)
		return null
	culled_material.cull_mode = BaseMaterial3D.CULL_BACK
	return culled_material


## Return the stable component batch key for one asset, Y layer, horizontal cull chunk, and source component.
static func _prop_batch_key(host: MTSStudioViewport, prop: PropPlacement, asset: TileAsset, source_mesh: MeshInstance3D) -> String:
	var chunk_x := floori(float(prop.origin.x) / float(MTSStudioViewport.SURFACE_BATCH_CHUNK_SIZE_M))
	var chunk_z := floori(float(prop.origin.z) / float(MTSStudioViewport.SURFACE_BATCH_CHUNK_SIZE_M))
	var model_path := asset.prop_model_path()
	if model_path.is_empty():
		return ""
	return "%s|component=%d|y=%d|chunk=%d,%d" % [
		model_path,
		source_mesh.get_instance_id(),
		host._prop_slice_level(prop),
		chunk_x,
		chunk_z,
	]


## Configure one reusable MultiMesh node with the canonical transforms of one GLB component group.
static func _configure_prop_batch(host: MTSStudioViewport,
	batch: MultiMeshInstance3D,
	key: String,
	group: Dictionary
) -> void:
	var mesh := group["mesh"] as Mesh
	var transforms: Array = group["transforms"]
	var multimesh := batch.multimesh
	if multimesh == null:
		multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		batch.multimesh = multimesh
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in transforms.size():
		multimesh.set_instance_transform(index, transforms[index] as Transform3D)

	var asset := group["asset"] as TileAsset
	batch.name = "PropBatch_%s_y%d_c%d_%d_m%d" % [
		asset.asset_id,
		int(group["layer_y"]),
		int(group["chunk_x"]),
		int(group["chunk_z"]),
		mesh.get_instance_id(),
	]
	batch.material_override = null
	batch.cast_shadow = host._visible_shadow_cast_setting()
	batch.extra_cull_margin = 8.0
	batch.set_meta("mts_batch_key", key)
	batch.set_meta("mts_asset_id", asset.asset_id)
	batch.set_meta("mts_layer_y", int(group["layer_y"]))
	host._apply_slice_to_node(batch)
