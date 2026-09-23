@tool
extends RefCounted

## Surface materials behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

## Build the one ShaderMaterial used by every PNG surface path.
##
## The shader owns material-only height parallax and PBR sampling, so PNG
## surfaces always remain on that one shader path.
static func _build_gpu_surface_material(host: SurfaceMaterialFactory,
	asset: TileAsset,
	albedo: Texture2D,
	maps: GBufferMapSet,
	parallax_source_short_edge_px: float,
	alpha_mode: int
) -> ShaderMaterial:
	var asset_uses_variation := SurfaceMaterialFactory._asset_uses_texture_variation(asset)
	# A PNG surface carries no material-blend layers of its own: material_blend_enabled
	# stays false unless configure_material_blend is later called on this material,
	# and that call re-selects the variant with the real layer count.
	var shader := host._surface_shader(alpha_mode, asset_uses_variation, 0, false)
	if shader == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_meta(SurfaceMaterialFactory.SURFACE_ALPHA_MODE_META, alpha_mode)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_ASSET_VARIATION_META, asset_uses_variation)
	# No layers are bound yet, so the asset answer is the effective one until
	# configure_material_blend re-selects with the layers included.
	mat.set_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_VARIATION_META, asset_uses_variation)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_LAYERS_META, 0)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_WORLD_HEIGHT_META, false)
	# The canonical asset material contains only PBR channel state. Terrain
	# batches opt into the triangle-instance projection when they duplicate it.
	mat.set_shader_parameter("terrain_triangle_instances", false)

	# Albedo is already resolved by get_visible_albedo(), so this builder only
	# binds it. The explicit error texture keeps a missing required image visible.
	var visible_albedo: Texture2D = albedo if albedo != null else SurfaceMaterialFactory._error_texture()
	mat.set_shader_parameter("albedo_tex", visible_albedo)

	# Runtime materials bind only final primary channels. AO, roughness, and
	# metallic are packed once into ORM; derivative analysis maps never reach the shader.
	var height := maps.load_texture("height") if maps != null else null
	var normal := maps.load_texture("normal") if maps != null else null
	var orm := host._resolved_layer_orm(asset) if SurfaceMaterialFactory._has_primary_orm_source(maps) else null
	var emission := maps.load_texture("emission") if maps != null else null
	var detail_albedo := maps.load_texture("detail_albedo") if maps != null else null
	var material_id := maps.load_texture("material_id") if maps != null else null

	mat.set_shader_parameter("height_tex", height if height != null else SurfaceMaterialFactory._black_texture())
	mat.set_shader_parameter("normal_tex", normal if normal != null else SurfaceMaterialFactory._normal_texture())
	mat.set_shader_parameter("orm_tex", orm if orm != null else host._neutral_orm_texture())
	mat.set_shader_parameter("emission_tex", emission if emission != null else SurfaceMaterialFactory._black_texture())
	mat.set_shader_parameter("detail_albedo_tex", detail_albedo if detail_albedo != null else SurfaceMaterialFactory._white_texture())
	mat.set_shader_parameter("material_id_tex", material_id if material_id != null else SurfaceMaterialFactory._black_texture())

	mat.set_shader_parameter("has_height", height != null)
	mat.set_shader_parameter("has_normal", normal != null)
	mat.set_shader_parameter("has_orm", orm != null)
	mat.set_shader_parameter("has_emission", emission != null)
	mat.set_shader_parameter("has_detail_albedo", detail_albedo != null)
	mat.set_shader_parameter("has_material_id", material_id != null)

	var footprint := asset.surface_footprint()
	mat.set_shader_parameter("surface_size_m", Vector2(float(footprint.x), float(footprint.y)))
	# Parallax stays material-local. Its full source resolution and authored
	# Height strength define the lookup travel; terrain vertices stay canonical.
	var height_strength := maps.get_strength("height") if maps != null else 1.0
	var responsive_short_edge_px := 0.0
	if height != null and parallax_source_short_edge_px > 0.0:
		responsive_short_edge_px = parallax_source_short_edge_px * height_strength
	mat.set_shader_parameter("parallax_source_short_edge_px", responsive_short_edge_px)

	mat.set_shader_parameter("albedo_strength", maps.get_strength("albedo") if maps != null else 1.0)
	mat.set_shader_parameter("texture_tint_color", asset.surface_tint_color)
	mat.set_shader_parameter(
		"texture_tint_strength",
		clampf(asset.surface_tint_strength, 0.0, 1.0)
	)
	mat.set_shader_parameter("normal_strength", maps.get_strength("normal") if maps != null else 1.0)
	mat.set_shader_parameter("ao_strength", maps.get_strength("ambient_occlusion") if maps != null else 1.0)
	mat.set_shader_parameter("roughness_strength", maps.get_strength("roughness") if maps != null else 1.0)
	mat.set_shader_parameter("metallic_strength", maps.get_strength("metallic") if maps != null else 1.0)
	mat.set_shader_parameter("emission_strength", maps.get_strength("emission") if maps != null else 1.0)
	mat.set_shader_parameter("roughness_bias", maps.get_bias("roughness") if maps != null else 0.0)
	mat.set_shader_parameter("metallic_bias", maps.get_bias("metallic") if maps != null else 0.0)
	mat.set_shader_parameter("specular_strength", maps.specular_strength if maps != null else 0.5)
	mat.set_shader_parameter("alpha_scissor", SurfaceMaterialFactory.SHADOW_ALPHA_CUTOFF)

	# Every PBR channel consumes the same three independently authored texture
	# variation switches, so colour, relief, and lighting cannot drift apart.
	mat.set_shader_parameter("stochastic_tiling", asset.stochastic_tiling)
	mat.set_shader_parameter("random_texture_rotation", asset.random_texture_rotation)
	mat.set_shader_parameter("random_texture_mirroring", asset.random_texture_mirroring)
	# Stable asset-specific offset: changing board seed changes the whole board,
	# while two different materials do not accidentally share identical phases.
	mat.set_shader_parameter(
		"texture_variation_asset_seed",
		float(absi(asset.asset_id.hash()) % 10000)
	)

	host._apply_global_shader_parameters(host._look())
	host._apply_board_resources_to_material(mat)
	return mat


## Bind the supported PBR channels from the canonical map set to one native Godot Decal.
##
## This is an adapter, not a second material path: albedo resolution and alpha
## composition still go through get_visible_albedo(), while normal, resolved ORM,
## and emission use the exact stored textures inspected by the terrain material.
## Godot Decal has no height or parallax input, so a height map cannot influence
## this native node and is deliberately not approximated.
static func configure_decal(host: SurfaceMaterialFactory, decal: Decal, asset: TileAsset) -> bool:
	if decal == null:
		push_error("[Tile Studio] Cannot configure a missing native Decal node.")
		return false
	if asset == null or not asset.is_surface():
		push_error("[Tile Studio] Native decal configuration requires a surface asset.")
		return false

	var maps := asset.gbuffer
	var albedo := host.get_visible_albedo(asset)
	if albedo == null:
		return false
	# A native Decal exposes no alpha-scissor input, so a CUTOUT asset's hard edge
	# has to be produced in the image itself. Without this the decal alpha-BLENDS
	# art the asset explicitly declares as cutout, which would be a second
	# transparency behaviour for one authored setting.
	if host.resolved_alpha_mode(asset, albedo) == TileAsset.SurfaceAlphaMode.CUTOUT:
		albedo = host._alpha_scissored(
			albedo,
			"decal_scissor|%s|%s|%s|delight=%.3f|%s" % [
				asset.asset_id,
				maps.get_channel("albedo") if maps != null else "",
				maps.get_channel("alpha") if maps != null else "",
				maps.delight_blend if maps != null else 1.0,
				host._image_adjustment_key_fragment(asset) + "|albedo=" + str(albedo.get_rid()),
			]
		)
		if albedo == null:
			return false
	# Native Decal consumes the same one packed scalar-PBR texture as terrain.
	var orm: Texture2D = (
		host._resolved_layer_orm(asset)
		if SurfaceMaterialFactory._has_primary_orm_source(maps)
		else null
	)

	decal.texture_albedo = albedo
	decal.texture_normal = maps.load_texture("normal") if maps != null else null
	decal.texture_orm = orm
	decal.texture_emission = maps.load_texture("emission") if maps != null else null
	decal.albedo_mix = maps.get_strength("albedo") if maps != null else 1.0
	var decal_tint := Color.WHITE.lerp(
		asset.surface_tint_color,
		clampf(asset.surface_tint_strength, 0.0, 1.0)
	)
	decal_tint.a = 1.0
	decal.modulate = decal_tint
	decal.emission_energy = maps.get_strength("emission") if maps != null else 1.0
	# The stamped footprint is exact, not a projector fade around a hidden border.
	decal.upper_fade = 0.0
	decal.lower_fade = 0.0
	# A projector box reaches past the authored face at an inside corner, where the
	# perpendicular wall also falls inside it. With no normal fade a Decal projects
	# onto that wall too, smearing the image along it and reading as edge tearing.
	# Fading by surface orientation rejects the perpendicular face while leaving the
	# authored face, which faces the projection axis directly, at full strength.
	decal.normal_fade = SurfaceMaterialFactory.DECAL_NORMAL_FADE
	return true


## Return the canonical GPU surface material for one asset and its current map response.
static func get_material(host: SurfaceMaterialFactory, asset: TileAsset) -> Material:
	host._ensure_surface_shader_source_current()
	if asset == null:
		return host._error_material()
	var known_key := String(
		host._material_cache_key_by_asset_id.get(asset.asset_id, "")
	)
	if not known_key.is_empty():
		var known_material: Material = host._cache.get(known_key, null)
		if known_material != null:
			return known_material
		host._material_cache_key_by_asset_id.erase(asset.asset_id)

	# Resolve the actual visible pixels before selecting an alpha pipeline so AUTO
	# and the shader consume the same composited image rather than separate guesses.
	var albedo := host.get_visible_albedo(asset)
	var alpha_mode := host.resolved_alpha_mode(asset, albedo)
	# The source image's short-edge pixel count is part of material identity:
	# regenerated maps at a new resolution must not reuse the old parallax uniform.
	var maps := asset.gbuffer
	var height_short_edge_px := SurfaceMaterialFactory.height_image_short_edge_px(asset)
	# Height strength and stochastic tiling both affect uniforms, so each needs a
	# distinct cached material even when the source maps are otherwise identical.
	var height_strength: float = maps.get_strength("height") if maps != null else 1.0
	# This mix changes the composited albedo pixels before the shader receives
	# them, so it is also part of the material's visible identity.
	var generated_albedo_blend: float = clampf(maps.delight_blend, 0.0, 1.0) if maps != null else 1.0
	var backface_culling_enabled := host._look().backface_culling_enabled
	var key := "surface_gpu|%s|%.4f|%.4f|albedo=%.4f|%s|tint=%.4f,%.4f,%.4f|tint_strength=%.4f|stoch=%s|rot=%s|mirror=%s|cull=%s|alpha=%d" % [
		asset.asset_id,
		height_short_edge_px,
		height_strength,
		generated_albedo_blend,
		host._image_adjustment_key_fragment(asset),
		asset.surface_tint_color.r,
		asset.surface_tint_color.g,
		asset.surface_tint_color.b,
		clampf(asset.surface_tint_strength, 0.0, 1.0),
		str(asset.stochastic_tiling),
		str(asset.random_texture_rotation),
		str(asset.random_texture_mirroring),
		str(backface_culling_enabled),
		alpha_mode,
	]

	var cached: Material = host._cache.get(key, null)
	if cached != null:
		return cached

	var mat := host._build_gpu_surface_material(
		asset,
		albedo,
		maps,
		height_short_edge_px,
		alpha_mode
	)
	host._cache[key] = mat
	host._material_cache_key_by_asset_id[asset.asset_id] = key
	return mat


## Report an asset without a usable visible texture instead of silently switching renderers.
static func _error_material(host: SurfaceMaterialFactory) -> Material:
	push_error("SurfaceMaterialFactory: surface material requested without a valid TileAsset.")
	return null
