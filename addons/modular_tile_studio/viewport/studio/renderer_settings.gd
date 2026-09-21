@tool
extends RefCounted

## Renderer settings behavior for MTSStudioViewport.
## The host retains Godot identity, signals, and authoritative state.

## Apply `setting` to every MeshInstance3D/GeometryInstance3D in `node`'s tree.
##
## A duplicated GLTF scene is a hierarchy of many mesh nodes, not one -- unlike
## the single-quad Art card, cast_shadow has to be set on each of them for the
## whole prop to actually cast.
static func _set_cast_shadow_recursive(host: MTSStudioViewport, node: Node, setting: int) -> void:
	var instance := node as GeometryInstance3D
	if instance != null:
		instance.cast_shadow = setting
	for child in node.get_children():
		host._set_cast_shadow_recursive(child, setting)


## Return whether the active board explicitly enables back-face culling.
static func _backface_culling_enabled(host: MTSStudioViewport) -> bool:
	return (
		host.board != null
		and host.board.aesthetics != null
		and host.board.aesthetics.backface_culling_enabled
	)


## Return the visible-geometry shadow mode selected in the Rendering window.
static func _visible_shadow_cast_setting(host: MTSStudioViewport) -> int:
	if (
		host.board != null
		and host.board.aesthetics != null
		and host.board.aesthetics.one_sided_shadows_enabled
	):
		return GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED


## Return a compact signature for renderer options that require live geometry updates.
static func _current_renderer_settings_signature(host: MTSStudioViewport) -> String:
	if host.board == null or host.board.aesthetics == null:
		return ""
	return "%s|%s" % [
		str(host.board.aesthetics.backface_culling_enabled),
		str(host.board.aesthetics.one_sided_shadows_enabled),
	]


## Apply the visible renderer toggles without rebuilding placement nodes or batches.
static func _apply_renderer_settings_to_existing_geometry(host: MTSStudioViewport) -> void:
	# Terrain visuals own their own cast-shadow state through the terrain
	# renderer, so only the GLB batches need reconciling here.
	# GLB batch meshes are derived from the original per-surface materials,
	# so a renderer-toggle rebuild is required to replace the material copies.
	host._sync_prop_art_batches()
	host.request_render()


## Apply back-face culling to compatible materials in one duplicated GLB hierarchy.
static func _set_backface_culling_recursive(host: MTSStudioViewport, node: Node, enabled: bool) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null:
		host._set_mesh_backface_culling(mesh_instance, enabled)
	for child in node.get_children():
		host._set_backface_culling_recursive(child, enabled)


## Derive per-instance GLB material overrides while preserving exact authored materials for disable.
static func _set_mesh_backface_culling(host: MTSStudioViewport, mesh_instance: MeshInstance3D, enabled: bool) -> void:
	if mesh_instance.mesh == null:
		return

	var state_value: Variant = (
		mesh_instance.get_meta(MTSStudioViewport.ORIGINAL_MATERIAL_STATE_META)
		if mesh_instance.has_meta(MTSStudioViewport.ORIGINAL_MATERIAL_STATE_META)
		else null
	)
	var state: Dictionary
	if state_value is Dictionary:
		state = state_value
	else:
		var surface_overrides: Array = []
		for surface_index in mesh_instance.mesh.get_surface_count():
			surface_overrides.append(
				mesh_instance.get_surface_override_material(surface_index)
			)
		state = {
			"material_override": mesh_instance.material_override,
			"surface_overrides": surface_overrides,
		}
		mesh_instance.set_meta(MTSStudioViewport.ORIGINAL_MATERIAL_STATE_META, state)

	var original_override := state.get("material_override", null) as Material
	var original_surface_overrides: Array = state.get("surface_overrides", [])
	mesh_instance.material_override = original_override
	for surface_index in mini(
		mesh_instance.mesh.get_surface_count(),
		original_surface_overrides.size()
	):
		mesh_instance.set_surface_override_material(
			surface_index,
			original_surface_overrides[surface_index] as Material
		)

	if not enabled:
		return

	if original_override != null:
		var override_base := original_override as BaseMaterial3D
		if override_base == null:
			push_warning(
				"[Tile Studio] Back-face culling cannot override custom material '%s' on '%s'."
				% [original_override.resource_path, mesh_instance.name]
			)
			return
		var culled_override := override_base.duplicate() as BaseMaterial3D
		if culled_override == null:
			push_error("[Tile Studio] Failed to duplicate GLB material override on '%s'." % mesh_instance.name)
			return
		culled_override.cull_mode = BaseMaterial3D.CULL_BACK
		mesh_instance.material_override = culled_override
		return

	for surface_index in mesh_instance.mesh.get_surface_count():
		var source_material: Material = null
		if surface_index < original_surface_overrides.size():
			source_material = original_surface_overrides[surface_index] as Material
		if source_material == null:
			source_material = mesh_instance.mesh.surface_get_material(surface_index)
		if source_material == null:
			continue
		var source_base := source_material as BaseMaterial3D
		if source_base == null:
			push_warning(
				"[Tile Studio] Back-face culling cannot override custom material '%s' on '%s' surface %d."
				% [source_material.resource_path, mesh_instance.name, surface_index]
			)
			continue
		var culled_surface := source_base.duplicate() as BaseMaterial3D
		if culled_surface == null:
			push_error(
				"[Tile Studio] Failed to duplicate GLB material on '%s' surface %d."
				% [mesh_instance.name, surface_index]
			)
			continue
		culled_surface.cull_mode = BaseMaterial3D.CULL_BACK
		mesh_instance.set_surface_override_material(surface_index, culled_surface)
