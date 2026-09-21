@tool
extends RefCounted

## Layer binding behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

## Resolve and cache the immutable texture inputs used whenever an asset is bound as a layer.
##
## Terrain batches need distinct ShaderMaterials because their control textures
## differ, but the layer art does not. Resolving these inputs once per asset keeps
## a large board from repeatedly decoding albedo, generating mipmaps, scanning
## alpha and resolving ORM for every chunk surface. Asset invalidation removes
## this entry before any edited maps are rebound.
static func _resolved_layer_binding(host: SurfaceMaterialFactory, overlay: TileAsset) -> Dictionary:
	if overlay == null:
		return {}
	var cached: Dictionary = host._layer_binding_cache.get(overlay.asset_id, {})
	if not cached.is_empty():
		return cached
	var maps := overlay.gbuffer
	var albedo := host.get_visible_albedo(overlay)
	var normal := maps.load_texture("normal") if maps != null else null
	var height := maps.load_texture("height") if maps != null else null
	var emission := maps.load_texture("emission") if maps != null else null
	var detail_albedo := maps.load_texture("detail_albedo") if maps != null else null
	var orm := host._resolved_layer_orm(overlay) if SurfaceMaterialFactory._has_primary_orm_source(maps) else null
	var height_short_edge_px := 0.0
	if height != null:
		height_short_edge_px = float(mini(height.get_width(), height.get_height()))
	cached = {
		"maps": maps,
		"albedo": albedo,
		"normal": normal,
		"height": height,
		"emission": emission,
		"detail_albedo": detail_albedo,
		"orm": orm,
		"alpha_mode": host.resolved_alpha_mode(overlay, albedo),
		"height_short_edge_px": height_short_edge_px,
	}
	host._layer_binding_cache[overlay.asset_id] = cached
	return cached


## Bind the PBR textures and response values shared by tiled and one-shot layers.
##
## Keeping these exact suffixes common means shader decals cannot drift into a
## reduced lighting model while the material profile evolves.
static func _bind_pbr_layer_asset(host: SurfaceMaterialFactory,
	mat: ShaderMaterial,
	prefix: String,
	overlay: TileAsset
) -> void:
	var binding := host._resolved_layer_binding(overlay)
	var maps := binding.get("maps", null) as GBufferMapSet
	var albedo := binding.get("albedo", null) as Texture2D
	var normal := binding.get("normal", null) as Texture2D
	var height := binding.get("height", null) as Texture2D
	var emission := binding.get("emission", null) as Texture2D
	var detail_albedo := binding.get("detail_albedo", null) as Texture2D
	var orm := binding.get("orm", null) as Texture2D

	mat.set_shader_parameter(prefix + "albedo_tex", albedo if albedo != null else SurfaceMaterialFactory._error_texture())
	mat.set_shader_parameter(prefix + "normal_tex", normal if normal != null else SurfaceMaterialFactory._normal_texture())
	mat.set_shader_parameter(prefix + "orm_tex", orm if orm != null else host._neutral_orm_texture())
	mat.set_shader_parameter(prefix + "height_tex", height if height != null else SurfaceMaterialFactory._black_texture())
	mat.set_shader_parameter(prefix + "emission_tex", emission if emission != null else SurfaceMaterialFactory._black_texture())
	mat.set_shader_parameter(prefix + "detail_albedo_tex", detail_albedo if detail_albedo != null else SurfaceMaterialFactory._white_texture())
	mat.set_shader_parameter(prefix + "has_normal", normal != null)
	mat.set_shader_parameter(prefix + "has_height", height != null)
	mat.set_shader_parameter(prefix + "has_emission", emission != null)
	mat.set_shader_parameter(prefix + "has_orm", orm != null)
	mat.set_shader_parameter(prefix + "has_detail_albedo", detail_albedo != null)
	var parallax_source_short_edge_px := 0.0
	if height != null and overlay != null:
		parallax_source_short_edge_px = (
			float(binding.get("height_short_edge_px", 0.0))
			* (maps.get_strength("height") if maps != null else 1.0)
		)
	mat.set_shader_parameter(
		prefix + "parallax_source_short_edge_px",
		parallax_source_short_edge_px
	)
	mat.set_shader_parameter(
		prefix + "albedo_strength",
		maps.get_strength("albedo") if maps != null else 1.0
	)
	mat.set_shader_parameter(
		prefix + "tint_color",
		overlay.surface_tint_color if overlay != null else Color.WHITE
	)
	mat.set_shader_parameter(
		prefix + "tint_strength",
		clampf(overlay.surface_tint_strength, 0.0, 1.0) if overlay != null else 0.0
	)
	mat.set_shader_parameter(
		prefix + "normal_strength",
		maps.get_strength("normal") if maps != null else 1.0
	)
	mat.set_shader_parameter(
		prefix + "ao_strength",
		maps.get_strength("ambient_occlusion") if maps != null else 1.0
	)
	mat.set_shader_parameter(
		prefix + "roughness_strength",
		maps.get_strength("roughness") if maps != null else 1.0
	)
	mat.set_shader_parameter(
		prefix + "metallic_strength",
		maps.get_strength("metallic") if maps != null else 1.0
	)
	mat.set_shader_parameter(
		prefix + "roughness_bias",
		maps.get_bias("roughness") if maps != null else 0.0
	)
	mat.set_shader_parameter(
		prefix + "metallic_bias",
		maps.get_bias("metallic") if maps != null else 0.0
	)
	mat.set_shader_parameter(
		prefix + "emission_strength",
		maps.get_strength("emission") if maps != null else 0.0
	)
	mat.set_shader_parameter(
		prefix + "specular_strength",
		maps.specular_strength if maps != null else 0.5
	)


## Bind one overlay asset, its resolved PBR inputs, and its ordered scalar mask rules.
static func _bind_material_layer(host: SurfaceMaterialFactory,
	mat: ShaderMaterial,
	layer_index: int,
	layer: Dictionary,
	library: AssetLibrary,
	slot_materials: PackedInt32Array
) -> void:
	var prefix := "material_layer_%d_" % layer_index
	var enabled := bool(layer.get("enabled", false))
	var asset_id := String(layer.get("asset_id", ""))
	var overlay := library.get_asset(asset_id) if library != null and not asset_id.is_empty() else null
	if enabled and (overlay == null or not overlay.is_surface()):
		push_error(
			"SurfaceMaterialFactory: material layer %d requires a terrain-paint PNG asset '%s'."
			% [layer_index + 1, asset_id]
		)
		enabled = false

	mat.set_shader_parameter(prefix + "enabled", enabled)
	# Brush-authored layers are always bounded by their exact splat weight; procedural
	# layers deliberately evaluate their visible mask stack without that local gate.
	mat.set_shader_parameter(
		prefix + "brush_authored",
		int(layer.get("application_mode", MaterialBlendProfile.ApplicationMode.BRUSH))
		== MaterialBlendProfile.ApplicationMode.BRUSH
	)
	var layer_binding := host._resolved_layer_binding(overlay)
	mat.set_shader_parameter(
		prefix + "albedo_has_transparency",
		enabled
		and overlay != null
		and int(layer_binding.get("alpha_mode", TileAsset.SurfaceAlphaMode.OPAQUE))
		!= TileAsset.SurfaceAlphaMode.OPAQUE
	)
	host._bind_pbr_layer_asset(mat, prefix, overlay)
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
	# Repeating layers retain their asset-level texture variation controls. A
	# one-shot shader decal bypasses repetition and therefore binds none of them.
	mat.set_shader_parameter(
		prefix + "stochastic_tiling",
		overlay.stochastic_tiling if overlay != null else false
	)
	mat.set_shader_parameter(
		prefix + "random_texture_rotation",
		overlay.random_texture_rotation if overlay != null else false
	)
	mat.set_shader_parameter(
		prefix + "random_texture_mirroring",
		overlay.random_texture_mirroring if overlay != null else false
	)
	mat.set_shader_parameter(
		prefix + "variation_asset_seed",
		float(absi(overlay.asset_id.hash()) % 10000) if overlay != null else 0.0
	)
	# Disabled or empty local slots bind neutral rule uniforms without trying
	# to resolve their placeholder paint reference through this face's palette.
	var rules_value: Variant = layer.get("masks", []) if enabled else []
	mat.set_shader_parameter(prefix + "mask_dependencies", SurfaceMaterialFactory._mask_dependency_bits(rules_value))
	if not host._bind_layer_mask_rules(
		mat,
		layer_index,
		rules_value,
		slot_materials
	):
		mat.set_shader_parameter(prefix + "enabled", false)


## Bind four ordered rules to either one local layer or the dedicated preview recipe.
static func _bind_layer_mask_rules(host: SurfaceMaterialFactory,
	mat: ShaderMaterial,
	layer_index: int,
	rules_value: Variant,
	slot_materials: PackedInt32Array,
	parameter_prefix: String = "",
	owner_palette_index: int = -1,
	skip_structural_paint_rule: bool = false,
	allow_missing_paint_references: bool = false
) -> bool:
	var rules: Array = rules_value if rules_value is Array else []
	var sources := Vector4i.ZERO
	var combines := Vector4i.ZERO
	var channels := Vector4i.ZERO
	var inversions := Vector4i.ZERO
	var lows := Vector4.ZERO
	var highs := Vector4.ONE
	var softness := Vector4.ZERO
	var strengths := Vector4.ONE
	var noise_scales := Vector4.ONE
	var noise_seeds := Vector4.ZERO
	var noise_angles := Vector4.ZERO
	var paint_availability := Vector4i.ONE
	var count := mini(rules.size(), 4)
	var valid := true
	for rule_index: int in count:
		var rule_value: Variant = rules[rule_index]
		if not rule_value is Dictionary:
			continue
		var rule: Dictionary = rule_value
		var source := clampi(
			int(rule.get("source", MaterialBlendProfile.MaskSource.PAINT)),
			MaterialBlendProfile.MaskSource.PAINT,
			MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS
		)
		sources[rule_index] = source
		combines[rule_index] = clampi(
			int(rule.get("combine", MaterialBlendProfile.CombineOperation.MULTIPLY)),
			MaterialBlendProfile.CombineOperation.MULTIPLY,
			MaterialBlendProfile.CombineOperation.MINIMUM
		)
		if source == MaterialBlendProfile.MaskSource.PAINT:
			if skip_structural_paint_rule and rule_index == 0:
				# The first PAINT rule declares brush ownership; preview intentionally
				# evaluates reach before any authored weight exists.
				channels[rule_index] = 0
			else:
				var referenced_palette := int(rule.get("paint_channel", -1))
				var referenced_slot := slot_materials.find(referenced_palette)
				if referenced_slot < 0 and allow_missing_paint_references:
					# A face that does not carry the referenced palette has exactly zero
					# weight for it; the availability vector makes that absence explicit.
					channels[rule_index] = 0
					paint_availability[rule_index] = 0
				elif referenced_slot < 0:
					var owner := (
						owner_palette_index
						if owner_palette_index >= 0
						else slot_materials[layer_index]
					)
					push_error(
						"SurfaceMaterialFactory: palette entry %d references painted palette entry %d, which this face does not carry."
						% [owner, referenced_palette]
					)
					valid = false
					channels[rule_index] = 0
				else:
					channels[rule_index] = referenced_slot
		else:
			channels[rule_index] = clampi(int(rule.get("channel", 0)), 0, 3)
		inversions[rule_index] = 1 if bool(rule.get("invert", false)) else 0
		lows[rule_index] = clampf(
			float(rule.get("range_low_percent", 0.0)) / 100.0,
			0.0,
			1.0
		)
		highs[rule_index] = clampf(
			float(rule.get("range_high_percent", 100.0)) / 100.0,
			0.0,
			1.0
		)
		softness[rule_index] = clampf(
			float(rule.get("softness_percent", 10.0)) / 100.0,
			0.0,
			1.0
		)
		strengths[rule_index] = clampf(
			float(rule.get("strength_percent", 100.0)) / 100.0,
			0.0,
			1.0
		)
		noise_scales[rule_index] = maxf(
			float(rule.get("noise_scale_m", 2.0)),
			0.01
		)
		noise_seeds[rule_index] = float(int(rule.get("noise_seed", 0)))
		noise_angles[rule_index] = clampf(
			float(rule.get("noise_angle_degrees", 0.0)),
			0.0,
			360.0
		)
	var prefix := (
		parameter_prefix
		if not parameter_prefix.is_empty()
		else "material_layer_%d_mask_" % layer_index
	)
	mat.set_shader_parameter(prefix + "count", count)
	mat.set_shader_parameter(prefix + "sources", sources)
	mat.set_shader_parameter(prefix + "combines", combines)
	mat.set_shader_parameter(prefix + "channels", channels)
	mat.set_shader_parameter(prefix + "inversions", inversions)
	mat.set_shader_parameter(prefix + "lows", lows)
	mat.set_shader_parameter(prefix + "highs", highs)
	mat.set_shader_parameter(prefix + "softness", softness)
	mat.set_shader_parameter(prefix + "strengths", strengths)
	mat.set_shader_parameter(prefix + "noise_scales", noise_scales)
	mat.set_shader_parameter(prefix + "noise_seeds", noise_seeds)
	mat.set_shader_parameter(prefix + "noise_angles", noise_angles)
	if allow_missing_paint_references:
		mat.set_shader_parameter(prefix + "paint_available", paint_availability)
	return valid
