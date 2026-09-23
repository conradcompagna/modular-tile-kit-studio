@tool
extends RefCounted

## Blend controls behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

## Update one existing batch material after a visible recipe or control texture change.
static func configure_material_blend(host: SurfaceMaterialFactory,
	mat: ShaderMaterial,
	control_texture: Texture2DArray,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	world_height_range: Vector2,
	world_elevation_range: Vector2,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> void:
	if mat == null or profile == null:
		push_error("SurfaceMaterialFactory: material blend configuration requires material and profile.")
		return
	profile.ensure_layers()
	var resolved_slots := SurfaceMaterialFactory._resolved_slot_materials(profile, slot_materials)
	# The variant was chosen from this material's own asset when it was built;
	# layers are only known here and may add a variation requirement. Re-selecting
	# now keeps the material on exactly the variant its complete feature set needs.
	host._ensure_material_variant(mat, profile, library, resolved_slots)
	host._apply_board_resources_to_material(mat)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_BLEND_SLOT_MATERIALS_META, resolved_slots.duplicate())
	mat.set_shader_parameter("material_blend_enabled", profile.enabled)
	mat.set_shader_parameter("material_blend_mode", int(profile.blend_mode))
	mat.set_shader_parameter("material_debug_view", int(profile.debug_view))
	host.configure_splatmap_channel_strengths(mat, profile)
	mat.set_shader_parameter(
		"material_control_tex",
		control_texture if control_texture != null else host._neutral_material_control_array()
	)
	mat.set_shader_parameter("material_world_height_range", host._nonzero_range(world_height_range))
	mat.set_shader_parameter("material_world_elevation_range", host._nonzero_range(world_elevation_range))
	for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		var palette_index := resolved_slots[slot_index]
		var layer := (
			profile.layer(palette_index)
			if palette_index >= 0 and palette_index < profile.layer_count()
			else MaterialBlendProfile.default_layer(0)
		)
		host._bind_material_layer(mat, slot_index, layer, library, resolved_slots)


## Bind the visible RGBA strength controls without recreating textures or material recipes.
static func configure_splatmap_channel_strengths(host: SurfaceMaterialFactory,
	mat: ShaderMaterial,
	profile: MaterialBlendProfile
) -> void:
	if mat == null or profile == null:
		push_error("SurfaceMaterialFactory: splatmap strengths require material and profile.")
		return
	var enabled := (
		profile.splatmap_mode_enabled
		and profile.splatmap_channel_strengths_enabled
	)
	mat.set_shader_parameter("splatmap_channel_strengths_enabled", enabled)
	mat.set_shader_parameter(
		"splatmap_channel_strengths",
		profile.splatmap_channel_strengths if enabled else Vector4.ONE
	)


## Bind one selected palette recipe to the dedicated transient preview uniforms.
##
## Preview rules are independent of the batch's four authored material slots, so a
## newly added fifth material can show its eligible reach before any face is painted.
static func configure_material_mask_preview(host: SurfaceMaterialFactory,
	mat: ShaderMaterial,
	palette_index: int,
	profile: MaterialBlendProfile
) -> bool:
	if (
		mat == null
		or profile == null
		or palette_index < 0
		or palette_index >= profile.layer_count()
	):
		push_error("SurfaceMaterialFactory: mask preview requires a valid palette entry.")
		return false
	var slots_value: Variant = mat.get_meta(
		SurfaceMaterialFactory.SURFACE_BLEND_SLOT_MATERIALS_META,
		PackedInt32Array()
	)
	if not slots_value is PackedInt32Array:
		push_error("SurfaceMaterialFactory: mask preview material has no palette-slot mapping.")
		return false
	var layer := profile.layer(palette_index)
	var brush_authored := (
		int(layer.get("application_mode", MaterialBlendProfile.ApplicationMode.BRUSH))
		== MaterialBlendProfile.ApplicationMode.BRUSH
	)
	mat.set_shader_parameter(
		"material_mask_preview_brush_authored",
		brush_authored
	)
	# The preview must exclude this entry's own paint from the surface it masks
	# against, exactly as the real layer gate does. A batch that does not carry the
	# entry reports -1, which excludes nothing: the entry would land on top of
	# everything already painted there.
	mat.set_shader_parameter(
		"material_mask_preview_slot",
		(slots_value as PackedInt32Array).find(palette_index)
	)
	return host._bind_layer_mask_rules(
		mat,
		0,
		layer.get("masks", []),
		slots_value as PackedInt32Array,
		"material_mask_preview_",
		palette_index,
		brush_authored,
		true
	)


## Update one palette entry's live controls on every batch that actually binds it.
##
## The material metadata resolves the board palette index to this batch's local
## shader slot, so slider input never assumes palette index N means RGBA slot N.
static func configure_material_layer_controls(host: SurfaceMaterialFactory,
	mat: ShaderMaterial,
	palette_index: int,
	profile: MaterialBlendProfile,
	library: AssetLibrary
) -> void:
	if mat == null or profile == null or palette_index < 0 or palette_index >= profile.layer_count():
		push_error("SurfaceMaterialFactory: live material controls require a valid palette entry.")
		return
	var slots_value: Variant = mat.get_meta(
		SurfaceMaterialFactory.SURFACE_BLEND_SLOT_MATERIALS_META,
		PackedInt32Array()
	)
	if not slots_value is PackedInt32Array:
		push_error("SurfaceMaterialFactory: live material has no inspectable palette-slot mapping.")
		return
	var slots: PackedInt32Array = slots_value
	var slot_index := slots.find(palette_index)
	if slot_index < 0:
		return
	var layer := profile.layer(palette_index)
	var prefix := "material_layer_%d_" % slot_index
	var asset_id := String(layer.get("asset_id", ""))
	var overlay := library.get_asset(asset_id) if library != null and not asset_id.is_empty() else null
	if bool(layer.get("enabled", false)) and (overlay == null or not overlay.is_surface()):
		push_error(
			"SurfaceMaterialFactory: palette entry %d has invalid PNG asset '%s'."
			% [palette_index, asset_id]
		)
		return
	mat.set_shader_parameter(
		prefix + "opacity",
		clampf(float(layer.get("opacity_percent", 100.0)) / 100.0, 0.0, 1.0)
	)
	mat.set_shader_parameter(
		prefix + "height_blend",
		clampf(float(layer.get("height_blend_percent", 0.0)) / 100.0, 0.0, 1.0)
	)
	var footprint := overlay.surface_footprint() if overlay != null else Vector2i.ONE
	var scale := maxf(float(layer.get("texture_scale_percent", 100.0)) / 100.0, 0.01)
	mat.set_shader_parameter(
		prefix + "repeat_m",
		Vector2(maxi(1, footprint.x), maxi(1, footprint.y)) * scale
	)
	if not host._bind_layer_mask_rules(mat, slot_index, layer.get("masks", []), slots):
		mat.set_shader_parameter(prefix + "enabled", false)


## Bind one shader decal as a one-shot instance of the ordinary PBR material layer.
##
## The original GPU textures remain bound directly. Placement supplies only the
## world-space addressing frame and optional palette transform.
static func configure_shader_decal(host: SurfaceMaterialFactory,
	mat: ShaderMaterial,
	placement: SurfacePlacement,
	asset: TileAsset,
	palette_adjustment: Dictionary
) -> bool:
	if mat == null:
		push_error("SurfaceMaterialFactory: cannot bind a shader decal to a null material.")
		return false
	if placement == null:
		mat.set_shader_parameter("shader_decal_enabled", false)
		return true
	if asset == null or not asset.is_surface():
		push_error(
			"SurfaceMaterialFactory: shader decal '%s' requires surface asset '%s'."
			% [placement.ensure_uid(), placement.asset_id]
		)
		return false
	var footprint := placement.canonical_footprint(asset)
	if footprint.x <= 0 or footprint.y <= 0:
		push_error(
			"SurfaceMaterialFactory: shader decal '%s' has an invalid footprint."
			% placement.ensure_uid()
		)
		return false
	var placement_transform := SurfacePlacement.transform_for_size(
		placement.origin,
		placement.face,
		placement.rotation_quarters,
		footprint,
		placement.grid_anchor
	)
	host._bind_pbr_layer_asset(mat, "shader_decal_", asset)
	mat.set_shader_parameter("shader_decal_origin", placement_transform.origin)
	mat.set_shader_parameter(
		"shader_decal_axis_u",
		placement_transform.basis.x.normalized()
	)
	mat.set_shader_parameter(
		"shader_decal_axis_v",
		placement_transform.basis.y.normalized()
	)
	mat.set_shader_parameter(
		"shader_decal_normal",
		placement_transform.basis.z.normalized()
	)
	mat.set_shader_parameter(
		"shader_decal_footprint_m",
		Vector2(float(footprint.x), float(footprint.y))
	)
	mat.set_shader_parameter(
		"shader_decal_palette_scale",
		palette_adjustment.get("scale", Vector3.ONE)
	)
	mat.set_shader_parameter(
		"shader_decal_palette_offset",
		palette_adjustment.get("offset", Vector3.ZERO)
	)
	mat.set_shader_parameter("shader_decal_enabled", true)
	return true
