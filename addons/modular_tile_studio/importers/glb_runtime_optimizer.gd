@tool
class_name GLBRuntimeOptimizer
extends RefCounted

## Builds one validated runtime GLB from an untouched canonical source GLB.
##
## The source file is authoritative and is never modified. A build is written to
## a temporary sibling, validated by decoding it again, and swapped into place
## only after geometry, UV, material, bounds, and texture checks pass.
##
## Mesh reduction uses Godot's ImporterMesh.generate_lods(), promotes the native
## LOD closest to the requested ratio to the new base surface, compacts every
## retained vertex attribute, and then asks Godot to generate fresh runtime LOD
## data from the reduced base before GLTF export.
const NORMAL_MERGE_ANGLE_DEGREES: float = 25.0
const NORMAL_SPLIT_ANGLE_DEGREES: float = 60.0
const MINIMUM_SIMPLIFIED_TRIANGLES: int = 8
const BOUNDS_RELATIVE_TOLERANCE: float = 0.001
const TARGET_RATIO_ALLOWANCE: float = 1.2


## Inspect one already decoded source hierarchy without mutating its resources.
func inspect_scene(model: Node3D) -> Dictionary:
	if model == null:
		return {}
	var unsupported := _unsupported_reason(model)
	var metrics := _scene_metrics(model)
	metrics["supported"] = unsupported.is_empty()
	metrics["unsupported_reason"] = unsupported
	return metrics


## Decode, optimize, export, validate, and atomically install one derived GLB.
func build_from_source(
	source_path: String,
	output_path: String,
	target_ratio: float,
	texture_size_limit: int
) -> Dictionary:
	if not _valid_target_ratio(target_ratio):
		return _failure("Unsupported mesh target %.3f; use 0.5, 0.25, or 0.125." % target_ratio)
	if texture_size_limit != 0 and texture_size_limit != 4096 and texture_size_limit != 2048:
		return _failure("Unsupported texture cap %d; use Original, 4096, or 2048." % texture_size_limit)

	var source_model := _load_external_model(source_path)
	if source_model == null:
		return _failure("The canonical source GLB could not be decoded.")

	var unsupported := _unsupported_reason(source_model)
	if not unsupported.is_empty():
		source_model.free()
		return _failure(unsupported)

	var source_metrics := _scene_metrics(source_model)
	var global_source := ProjectSettings.globalize_path(source_path)
	if not FileAccess.file_exists(global_source):
		global_source = source_path
	source_metrics["file_bytes"] = _file_length(global_source)
	var optimize_result := _optimize_scene(source_model, target_ratio, texture_size_limit)
	if not bool(optimize_result.get("ok", false)):
		source_model.free()
		return optimize_result

	var global_output := ProjectSettings.globalize_path(output_path)
	var output_dir := global_output.get_base_dir()
	var make_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if make_error != OK:
		source_model.free()
		return _failure("Could not create optimized GLB directory '%s' (%s)." % [
			output_dir,
			error_string(make_error),
		])

	var build_id := str(Time.get_ticks_usec())
	var pending_path := global_output + ".pending_" + build_id + ".glb"
	var export_error := _export_scene(source_model, pending_path)
	source_model.free()
	if export_error != OK:
		_remove_file_if_present(pending_path)
		return _failure("Could not export optimized GLB '%s' (%s)." % [
			pending_path,
			error_string(export_error),
		])

	var validation_model := _load_external_model(pending_path)
	if validation_model == null:
		_remove_file_if_present(pending_path)
		return _failure("The optimized GLB was written but could not be decoded for validation.")

	var output_metrics := _scene_metrics(validation_model)
	validation_model.free()
	var validation_error := _validate_output(
		source_metrics,
		output_metrics,
		target_ratio,
		texture_size_limit
	)
	if not validation_error.is_empty():
		_remove_file_if_present(pending_path)
		return _failure(validation_error)

	var install_error := _install_atomically(pending_path, global_output)
	if install_error != OK:
		_remove_file_if_present(pending_path)
		return _failure("Could not install optimized GLB '%s' (%s)." % [
			output_path,
			error_string(install_error),
		])

	output_metrics["file_bytes"] = _file_length(global_output)
	output_metrics["target_ratio"] = target_ratio
	output_metrics["texture_size_limit"] = texture_size_limit
	output_metrics["lod_generation"] = "Godot scene import (meshes/generate_lods=true)"
	return {
		"ok": true,
		"path": output_path,
		"source": source_metrics,
		"output": output_metrics,
		"built_at": Time.get_datetime_string_from_system(),
	}


## Return whether a ratio belongs to the deliberately small public option set.
func _valid_target_ratio(target_ratio: float) -> bool:
	return (
		is_equal_approx(target_ratio, 0.5)
		or is_equal_approx(target_ratio, 0.25)
		or is_equal_approx(target_ratio, 0.125)
	)


## Decode an external GLB through GLTFDocument and normalize importer mesh nodes.
func _load_external_model(source_path: String) -> Node3D:
	var global_path := ProjectSettings.globalize_path(source_path)
	if not FileAccess.file_exists(global_path):
		global_path = source_path
	if not FileAccess.file_exists(global_path):
		push_error("[Tile Studio] GLB optimizer source is missing: %s" % source_path)
		return null

	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var read_error := document.append_from_file(global_path, state)
	if read_error != OK:
		push_error("[Tile Studio] GLB optimizer could not read '%s' (%s)" % [
			source_path,
			error_string(read_error),
		])
		return null

	var generated := document.generate_scene(state)
	if generated == null:
		push_error("[Tile Studio] GLB optimizer generated no scene for '%s'." % source_path)
		return null

	var root := generated as Node3D
	if root == null:
		generated.free()
		push_error("[Tile Studio] GLB optimizer requires a Node3D root in '%s'." % source_path)
		return null

	if root.is_class("ImporterMeshInstance3D"):
		var wrapper := Node3D.new()
		wrapper.name = root.name
		root.name = "Mesh"
		wrapper.add_child(root)
		root = wrapper
	_convert_importer_meshes(root)
	return root


## Replace GLTF importer mesh nodes with ordinary MeshInstance3D nodes in place.
func _convert_importer_meshes(node: Node) -> void:
	for child in node.get_children():
		_convert_importer_meshes(child)

	if not node.is_class("ImporterMeshInstance3D"):
		return
	var parent := node.get_parent()
	if parent == null:
		return

	var replacement := MeshInstance3D.new()
	replacement.name = node.name
	var source_3d := node as Node3D
	if source_3d != null:
		replacement.transform = source_3d.transform
		replacement.visible = source_3d.visible

	var importer_mesh: Variant = node.get("mesh")
	if importer_mesh != null and importer_mesh.has_method("get_mesh"):
		replacement.mesh = importer_mesh.get_mesh()
	var skin: Variant = node.get("skin")
	if skin != null:
		replacement.skin = skin
	var skeleton: Variant = node.get("skeleton")
	if skeleton is NodePath:
		replacement.skeleton = skeleton

	for child in node.get_children():
		node.remove_child(child)
		replacement.add_child(child)

	var index := node.get_index()
	parent.remove_child(node)
	parent.add_child(replacement)
	parent.move_child(replacement, index)
	node.free()


## Reject source features this static prop pipeline cannot preserve faithfully.
func _unsupported_reason(root: Node) -> String:
	if root is Skeleton3D:
		return "Static prop optimization does not support Skeleton3D nodes."
	if root is AnimationPlayer:
		return "Static prop optimization does not support animation tracks."
	var mesh_instance := root as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		if mesh_instance.skin != null or not mesh_instance.skeleton.is_empty():
			return "Static prop optimization does not support skinned mesh instances."
		if mesh_instance.mesh.get_blend_shape_count() > 0:
			return "Static prop optimization does not support blend shapes."
		for surface in mesh_instance.mesh.get_surface_count():
			if mesh_instance.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				return "Static prop optimization requires triangle mesh surfaces."
			var arrays := mesh_instance.mesh.surface_get_arrays(surface)
			if not _array_empty(arrays[Mesh.ARRAY_BONES]) or not _array_empty(arrays[Mesh.ARRAY_WEIGHTS]):
				return "Static prop optimization does not support bone or weight attributes."
			for custom_slot in [
				Mesh.ARRAY_CUSTOM0,
				Mesh.ARRAY_CUSTOM1,
				Mesh.ARRAY_CUSTOM2,
				Mesh.ARRAY_CUSTOM3,
			]:
				if not _array_empty(arrays[custom_slot]):
					return "Static prop optimization does not support custom vertex attributes."
	for child in root.get_children():
		var child_reason := _unsupported_reason(child)
		if not child_reason.is_empty():
			return child_reason
	return ""


## Reduce every mesh and resize its embedded material textures in one hierarchy.
func _optimize_scene(root: Node3D, target_ratio: float, texture_size_limit: int) -> Dictionary:
	var material_cache: Dictionary = {}
	var texture_cache: Dictionary = {}
	for mesh_instance: MeshInstance3D in _all_meshes(root):
		if mesh_instance.mesh == null:
			continue
		var reduced := _reduce_mesh(
			mesh_instance,
			target_ratio,
			texture_size_limit,
			material_cache,
			texture_cache
		)
		if not bool(reduced.get("ok", false)):
			return reduced
		mesh_instance.mesh = reduced["mesh"]
	return {"ok": true}


## Promote one native LOD per surface, compact attributes, and generate fresh LODs.
func _reduce_mesh(
	mesh_instance: MeshInstance3D,
	target_ratio: float,
	texture_size_limit: int,
	material_cache: Dictionary,
	texture_cache: Dictionary
) -> Dictionary:
	var source_mesh := mesh_instance.mesh
	var importer_mesh := ImporterMesh.from_mesh(source_mesh)
	importer_mesh.generate_lods(
		NORMAL_MERGE_ANGLE_DEGREES,
		NORMAL_SPLIT_ANGLE_DEGREES,
		[]
	)

	var reduced_mesh := ArrayMesh.new()
	for surface in importer_mesh.get_surface_count():
		var source_arrays := importer_mesh.get_surface_arrays(surface)
		var source_indices := _source_indices(source_arrays)
		var source_triangles := source_indices.size() / 3
		var selected_indices := source_indices
		if source_triangles > MINIMUM_SIMPLIFIED_TRIANGLES:
			selected_indices = _select_lod_indices(importer_mesh, surface, source_triangles, target_ratio)
			if selected_indices.is_empty():
				return _failure(
					"Godot generated no usable %.1f%% LOD for '%s' surface %d."
					% [target_ratio * 100.0, mesh_instance.name, surface]
				)

		var compact_result := _compact_surface(source_arrays, selected_indices)
		if not bool(compact_result.get("ok", false)):
			return compact_result
		var compact_arrays: Array = compact_result["arrays"]
		reduced_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, compact_arrays)

		var source_material := mesh_instance.get_active_material(surface)
		var material_result := _optimized_material(
			source_material,
			texture_size_limit,
			material_cache,
			texture_cache
		)
		if not bool(material_result.get("ok", false)):
			return material_result
		var reduced_surface := reduced_mesh.get_surface_count() - 1
		var reduced_material: Material = material_result.get("material", null)
		if reduced_material != null:
			reduced_mesh.surface_set_material(reduced_surface, reduced_material)
		reduced_mesh.surface_set_name(reduced_surface, importer_mesh.get_surface_name(surface))

	var runtime_importer := ImporterMesh.from_mesh(reduced_mesh)
	runtime_importer.generate_lods(
		NORMAL_MERGE_ANGLE_DEGREES,
		NORMAL_SPLIT_ANGLE_DEGREES,
		[]
	)
	return {"ok": true, "mesh": runtime_importer.get_mesh()}


## Return original indices, synthesizing a sequential triangle list if absent.
func _source_indices(arrays: Array) -> PackedInt32Array:
	var stored: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if not stored.is_empty():
		return stored.duplicate()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var generated := PackedInt32Array()
	for index in vertices.size():
		generated.append(index)
	return generated


## Choose the generated native LOD nearest the requested triangle ratio.
func _select_lod_indices(
	importer_mesh: ImporterMesh,
	surface: int,
	source_triangles: int,
	target_ratio: float
) -> PackedInt32Array:
	var best := PackedInt32Array()
	var best_distance := INF
	var maximum_triangles := ceili(float(source_triangles) * target_ratio * TARGET_RATIO_ALLOWANCE)
	for lod in importer_mesh.get_surface_lod_count(surface):
		var indices := importer_mesh.get_surface_lod_indices(surface, lod)
		if indices.is_empty() or indices.size() % 3 != 0:
			continue
		var triangles := indices.size() / 3
		if triangles > maximum_triangles:
			continue
		var distance := absf(float(triangles) / float(source_triangles) - target_ratio)
		if distance < best_distance:
			best_distance = distance
			best = indices
	return best


## Compact all conventional vertex attributes around one selected index buffer.
func _compact_surface(source_arrays: Array, selected_indices: PackedInt32Array) -> Dictionary:
	var vertices: PackedVector3Array = source_arrays[Mesh.ARRAY_VERTEX]
	if vertices.is_empty() or selected_indices.is_empty():
		return _failure("A mesh surface has no vertex or index data.")

	var remap: Dictionary = {}
	var vertex_order := PackedInt32Array()
	var compact_indices := PackedInt32Array()
	for old_index: int in selected_indices:
		if old_index < 0 or old_index >= vertices.size():
			return _failure("A generated LOD index points outside its source vertex array.")
		if not remap.has(old_index):
			remap[old_index] = vertex_order.size()
			vertex_order.append(old_index)
		compact_indices.append(int(remap[old_index]))

	var compact: Array = []
	compact.resize(Mesh.ARRAY_MAX)
	for slot in Mesh.ARRAY_MAX:
		if slot == Mesh.ARRAY_INDEX:
			compact[slot] = compact_indices
			continue
		var source_attribute: Variant = source_arrays[slot]
		if _array_empty(source_attribute):
			continue
		var stride := 4 if slot == Mesh.ARRAY_TANGENT else 1
		var remapped := _remap_attribute(source_attribute, vertex_order, stride)
		if remapped == null:
			return _failure("A vertex attribute could not be compacted without losing data.")
		compact[slot] = remapped
	return {"ok": true, "arrays": compact}


## Remap one packed vertex attribute while preserving its concrete packed type.
func _remap_attribute(source: Variant, vertex_order: PackedInt32Array, stride: int) -> Variant:
	if source == null:
		return null
	var output: Variant = source.duplicate()
	output.resize(0)
	for old_index: int in vertex_order:
		var first := old_index * stride
		if first < 0 or first + stride > source.size():
			return null
		for component in stride:
			output.append(source[first + component])
	return output


## Duplicate one material and replace only textures that exceed the visible cap.
func _optimized_material(
	source_material: Material,
	texture_size_limit: int,
	material_cache: Dictionary,
	texture_cache: Dictionary
) -> Dictionary:
	if source_material == null:
		return {"ok": true, "material": null}
	var material_key := source_material.get_instance_id()
	if material_cache.has(material_key):
		return {"ok": true, "material": material_cache[material_key]}
	if not source_material is BaseMaterial3D:
		return _failure("Static prop optimization requires imported BaseMaterial3D materials.")

	var material := source_material.duplicate(false) as Material
	if material == null:
		return _failure("An imported material could not be duplicated.")
	for property: Dictionary in material.get_property_list():
		var property_name := String(property.get("name", ""))
		if property_name.is_empty():
			continue
		var property_value: Variant = source_material.get(property_name)
		if not property_value is Texture2D:
			continue
		var texture := property_value as Texture2D
		var texture_result := _optimized_texture(texture, texture_size_limit, texture_cache)
		if not bool(texture_result.get("ok", false)):
			return texture_result
		material.set(property_name, texture_result["texture"])

	material_cache[material_key] = material
	return {"ok": true, "material": material}


## Resize one unique material texture while retaining its aspect ratio and pixels.
func _optimized_texture(
	source_texture: Texture2D,
	texture_size_limit: int,
	texture_cache: Dictionary
) -> Dictionary:
	var cache_key := "%d|%d" % [source_texture.get_instance_id(), texture_size_limit]
	if texture_cache.has(cache_key):
		return {"ok": true, "texture": texture_cache[cache_key]}
	if texture_size_limit <= 0:
		texture_cache[cache_key] = source_texture
		return {"ok": true, "texture": source_texture}

	var image := source_texture.get_image()
	if image == null or image.is_empty():
		return _failure("An embedded material texture could not be decoded.")
	if image.is_compressed():
		var decompress_error := image.decompress()
		if decompress_error != OK:
			return _failure("An embedded material texture could not be decompressed.")
	var longest := maxi(image.get_width(), image.get_height())
	if longest <= texture_size_limit:
		texture_cache[cache_key] = source_texture
		return {"ok": true, "texture": source_texture}

	var scale := float(texture_size_limit) / float(longest)
	image.resize(
		maxi(1, roundi(float(image.get_width()) * scale)),
		maxi(1, roundi(float(image.get_height()) * scale)),
		Image.INTERPOLATE_LANCZOS
	)
	var resized := ImageTexture.create_from_image(image)
	if resized == null:
		return _failure("A resized embedded material texture could not be created.")
	texture_cache[cache_key] = resized
	return {"ok": true, "texture": resized}


## Export one processed hierarchy as a binary GLB at an absolute pending path.
##
## GLTFDocument-generated nodes retain importer-only metadata that can make a
## second append_from_scene serialize an empty hierarchy after their mesh node
## has been replaced. A clean Node3D copy carries only the transforms and reduced
## meshes that belong in the derived GLB.
func _export_scene(root: Node3D, output_path: String) -> Error:
	var export_root := _clean_export_hierarchy(root)
	if export_root == null:
		return ERR_INVALID_DATA
	var document := GLTFDocument.new()
	document.image_format = "PNG"
	var state := GLTFState.new()
	var append_error := document.append_from_scene(export_root, state)
	if append_error != OK:
		export_root.free()
		return append_error
	var write_error := document.write_to_filesystem(state, output_path)
	export_root.free()
	return write_error


## Copy the static Node3D hierarchy without carrying GLTF importer-only metadata.
func _clean_export_hierarchy(source: Node3D) -> Node3D:
	var clean := _copy_export_node(source) as Node3D
	if clean == null:
		return null
	_assign_export_owners(clean, clean)
	return clean


## Mark every descendant as owned by the export root so GLTFDocument serializes it.
##
## GLTFDocument follows PackedScene ownership rules and otherwise writes only the
## unowned root node, producing a valid but empty 312-byte GLB.
func _assign_export_owners(node: Node, export_root: Node) -> void:
	for child: Node in node.get_children():
		child.owner = export_root
		_assign_export_owners(child, export_root)


## Copy one static spatial node and its children for deterministic GLB export.
func _copy_export_node(source: Node) -> Node:
	var source_spatial := source as Node3D
	if source_spatial == null:
		return null

	var clean_spatial: Node3D
	var source_mesh := source as MeshInstance3D
	if source_mesh != null:
		var clean_mesh := MeshInstance3D.new()
		clean_mesh.mesh = source_mesh.mesh
		clean_spatial = clean_mesh
	else:
		clean_spatial = Node3D.new()
	clean_spatial.name = source.name
	clean_spatial.transform = source_spatial.transform
	clean_spatial.visible = source_spatial.visible

	for child: Node in source.get_children():
		var clean_child := _copy_export_node(child)
		if clean_child != null:
			clean_spatial.add_child(clean_child)
	return clean_spatial


## Measure geometry, material, texture, and bounds costs for one hierarchy.
func _scene_metrics(root: Node3D) -> Dictionary:
	var triangles := 0
	var vertices := 0
	var surfaces := 0
	var uv_surfaces := 0
	var material_surfaces := 0
	var lod_levels := 0
	var textures: Dictionary = {}
	var materials: Dictionary = {}
	for mesh_instance: MeshInstance3D in _all_meshes(root):
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		var metric_importer := ImporterMesh.from_mesh(mesh)
		for surface in mesh.get_surface_count():
			surfaces += 1
			var arrays := mesh.surface_get_arrays(surface)
			var surface_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var surface_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			vertices += surface_vertices.size()
			triangles += (
				surface_indices.size() / 3
				if not surface_indices.is_empty()
				else surface_vertices.size() / 3
			)
			if not _array_empty(arrays[Mesh.ARRAY_TEX_UV]):
				uv_surfaces += 1
			var material := mesh_instance.get_active_material(surface)
			if material != null:
				material_surfaces += 1
				materials[material.get_instance_id()] = true
				for texture: Texture2D in _material_textures(material):
					textures[texture.get_instance_id()] = texture
			lod_levels += metric_importer.get_surface_lod_count(surface)

	var texture_bytes := 0
	var texture_max_dimension := 0
	for texture: Texture2D in textures.values():
		var width := texture.get_width()
		var height := texture.get_height()
		texture_max_dimension = maxi(texture_max_dimension, maxi(width, height))
		texture_bytes += int(ceil(float(width * height * 4) * 4.0 / 3.0))

	return {
		"triangles": triangles,
		"vertices": vertices,
		"surfaces": surfaces,
		"uv_surfaces": uv_surfaces,
		"material_surfaces": material_surfaces,
		"materials": materials.size(),
		"textures": textures.size(),
		"texture_max_dimension": texture_max_dimension,
		"estimated_texture_bytes": texture_bytes,
		"lod_levels": lod_levels,
		"bounds": _scene_bounds(root),
	}


## Collect unique Texture2D properties exposed by one imported material.
func _material_textures(material: Material) -> Array[Texture2D]:
	var textures: Array[Texture2D] = []
	var seen: Dictionary = {}
	for property: Dictionary in material.get_property_list():
		var property_name := String(property.get("name", ""))
		if property_name.is_empty():
			continue
		var property_value: Variant = material.get(property_name)
		if not property_value is Texture2D:
			continue
		var texture := property_value as Texture2D
		if seen.has(texture.get_instance_id()):
			continue
		seen[texture.get_instance_id()] = true
		textures.append(texture)
	return textures


## Calculate hierarchy bounds using explicit parent transforms outside a SceneTree.
func _scene_bounds(root: Node3D) -> AABB:
	var state := {"found": false, "bounds": AABB()}
	_accumulate_bounds(root, Transform3D.IDENTITY, state)
	return state["bounds"]


## Merge each mesh AABB through its full authored hierarchy transform.
func _accumulate_bounds(node: Node, parent_transform: Transform3D, state: Dictionary) -> void:
	var local_transform := Transform3D.IDENTITY
	var node_3d := node as Node3D
	if node_3d != null:
		local_transform = node_3d.transform
	var world_transform := parent_transform * local_transform
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		var transformed := world_transform * mesh_instance.mesh.get_aabb()
		if bool(state["found"]):
			state["bounds"] = (state["bounds"] as AABB).merge(transformed)
		else:
			state["bounds"] = transformed
			state["found"] = true
	for child in node.get_children():
		_accumulate_bounds(child, world_transform, state)


## Collect ordinary mesh instances recursively for processing and measurement.
func _all_meshes(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null:
		result.append(mesh_instance)
	for child in node.get_children():
		result.append_array(_all_meshes(child))
	return result


## Verify that the written GLB meets the requested deterministic contract.
func _validate_output(
	source: Dictionary,
	output: Dictionary,
	target_ratio: float,
	texture_size_limit: int
) -> String:
	if int(output.get("surfaces", 0)) != int(source.get("surfaces", 0)):
		return "Optimized GLB validation failed: mesh surface count changed."
	if int(output.get("uv_surfaces", 0)) != int(source.get("uv_surfaces", 0)):
		return "Optimized GLB validation failed: UV-bearing surface count changed."
	if int(output.get("material_surfaces", 0)) != int(source.get("material_surfaces", 0)):
		return "Optimized GLB validation failed: material-bearing surface count changed."

	var source_triangles := int(source.get("triangles", 0))
	var output_triangles := int(output.get("triangles", 0))
	var allowed_triangles := ceili(float(source_triangles) * target_ratio * TARGET_RATIO_ALLOWANCE) + 64
	if source_triangles <= 0 or output_triangles <= 0 or output_triangles > allowed_triangles:
		return (
			"Optimized GLB validation failed: %d output triangles exceed the %d-triangle contract."
			% [output_triangles, allowed_triangles]
		)

	if texture_size_limit > 0 and int(output.get("texture_max_dimension", 0)) > texture_size_limit:
		return "Optimized GLB validation failed: an embedded texture exceeds %d pixels." % texture_size_limit

	var source_bounds: AABB = source.get("bounds", AABB())
	var output_bounds: AABB = output.get("bounds", AABB())
	if not _bounds_match(source_bounds, output_bounds):
		return "Optimized GLB validation failed: transformed bounds changed by more than 0.1%."
	return ""


## Compare centres and sizes with a relative tolerance based on source extent.
func _bounds_match(source: AABB, output: AABB) -> bool:
	var extent := maxf(source.size.length(), 0.001)
	var tolerance := extent * BOUNDS_RELATIVE_TOLERANCE
	return (
		source.position.distance_to(output.position) <= tolerance
		and source.size.distance_to(output.size) <= tolerance
	)


## Replace a validated output while restoring the prior file if installation fails.
func _install_atomically(pending_path: String, final_path: String) -> Error:
	var previous_path := final_path + ".previous"
	_remove_file_if_present(previous_path)
	var had_previous := FileAccess.file_exists(final_path)
	if had_previous:
		var move_previous := DirAccess.rename_absolute(final_path, previous_path)
		if move_previous != OK:
			return move_previous
	var move_pending := DirAccess.rename_absolute(pending_path, final_path)
	if move_pending != OK:
		if had_previous:
			DirAccess.rename_absolute(previous_path, final_path)
		return move_pending
	_remove_file_if_present(previous_path)
	return OK


## Remove one exact temporary or previous file when it exists.
func _remove_file_if_present(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Return one file's byte length without loading the whole GLB into memory.
func _file_length(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var length := file.get_length()
	file.close()
	return length


## Treat null and empty packed arrays uniformly while inspecting mesh channels.
func _array_empty(value: Variant) -> bool:
	return value == null or value.size() == 0


## Build a consistent failure result and report the same actionable message.
func _failure(message: String) -> Dictionary:
	push_error("[Tile Studio] %s" % message)
	return {"ok": false, "error": message}
