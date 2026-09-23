@tool
extends RefCounted

## Terrain batches behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

# --- Channel compositing --------------------------------------------------
#
# The unified shader consumes each PBR map directly. Preprocessing helpers
# therefore only prepare source/albedo pixels and never alter map semantics.
#
# Results are cached: these run per material build, and a 2K composite is far
# too expensive to redo whenever a knob moves.

## Return one asset-backed terrain material for exact heightfield triangles.
##
## Terrain Paint changes only this batch-local duplicate, so binding triangle
## projection and paint masks cannot mutate the cached canonical asset material.
static func get_asset_material_for_terrain_batch(host: SurfaceMaterialFactory,
	asset: TileAsset,
	control_texture: Texture2DArray,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	world_height_range: Vector2,
	world_elevation_range: Vector2,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> Material:
	var base := host.get_material(asset) as ShaderMaterial
	if base == null:
		return null
	var mat := host._register_live_material(base.duplicate() as ShaderMaterial)
	if mat == null:
		push_error("SurfaceMaterialFactory: cannot duplicate the terrain PNG material.")
		return null
	mat.set_shader_parameter("terrain_triangle_instances", true)
	if profile != null and profile.enabled:
		host.configure_material_blend(
			mat,
			control_texture,
			profile,
			library,
			world_height_range,
			world_elevation_range,
			slot_materials
		)
	return mat


## Return one batch-local terrain material with the same visible blend recipe as PNG surfaces.
##
## Terrain has no implicit base asset, so the neutral canonical terrain material
## is duplicated and receives the exact control texture, palette, and mask ranges
## consumed by every other surface batch.
static func get_material_for_terrain_batch(host: SurfaceMaterialFactory,
	control_texture: Texture2DArray,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	world_height_range: Vector2,
	world_elevation_range: Vector2,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> Material:
	var base := host.terrain_material()
	if base == null:
		return null
	# Top and side batches carry different grid presentation flags, so even a
	# neutral unpainted batch owns its material instance rather than mutating the
	# shared canonical terrain material.
	var mat := host._register_live_material(base.duplicate() as ShaderMaterial)
	if mat == null:
		push_error("SurfaceMaterialFactory: cannot duplicate the canonical terrain material.")
		return null
	mat.set_shader_parameter("terrain_triangle_instances", true)
	if profile != null and profile.enabled:
		host.configure_material_blend(
			mat,
			control_texture,
			profile,
			library,
			world_height_range,
			world_elevation_range,
			slot_materials
		)
	return mat


## Build the terrain's own material, which has no base PNG at all.
##
## Terrain is not a PNG surface: it is imported or drawn untextured, and every
## texture on it arrives by painting. Requiring a base asset is what forced the
## editor to invent a ground texture on import, so this path deliberately has no
## asset argument. The shader is the same one every painted surface uses, with
## neutral maps standing in for the channels a base PNG would have supplied.
static func terrain_material(host: SurfaceMaterialFactory) -> ShaderMaterial:
	host._ensure_surface_shader_source_current()
	var backface_culling_enabled := host._look().backface_culling_enabled
	var key := "terrain_gpu|cull=%s" % str(backface_culling_enabled)
	var cached := host._cache.get(key, null) as ShaderMaterial
	if cached != null:
		return cached

	# Terrain has no base PNG, so it contributes no texture variation of its own.
	# Any requirement comes from painted layers, which configure_material_blend
	# applies through _ensure_material_variant once those layers are bound.
	var shader := host._surface_shader(TileAsset.SurfaceAlphaMode.OPAQUE, false, 0, false)
	if shader == null:
		return null
	var mat := ShaderMaterial.new()
	# Opaque: terrain is solid ground, so it needs no alpha pipeline.
	mat.shader = shader
	mat.set_meta(SurfaceMaterialFactory.SURFACE_ALPHA_MODE_META, TileAsset.SurfaceAlphaMode.OPAQUE)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_ASSET_VARIATION_META, false)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_VARIATION_META, false)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_LAYERS_META, 0)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_WORLD_HEIGHT_META, false)
	# Painting consumes the canonical heightfield triangles directly.
	mat.set_shader_parameter("terrain_triangle_instances", true)
	mat.set_shader_parameter("terrain_show_top_grid", true)
	mat.set_shader_parameter("terrain_show_side_grid", false)

	# Untextured terrain renders as plain unlit-neutral ground. These are the
	# same neutral stand-ins the shader already expects for absent channels, so
	# no branch is added to the shader itself.
	mat.set_shader_parameter("albedo_tex", SurfaceMaterialFactory._white_texture())
	mat.set_shader_parameter("normal_tex", SurfaceMaterialFactory._normal_texture())
	mat.set_shader_parameter("has_height", false)
	mat.set_shader_parameter("has_emission", false)
	mat.set_shader_parameter("has_material_id", false)
	mat.set_shader_parameter("has_orm", false)
	mat.set_shader_parameter("parallax_source_short_edge_px", 0.0)
	mat.set_shader_parameter("stochastic_tiling", false)
	mat.set_shader_parameter("random_texture_rotation", false)
	mat.set_shader_parameter("random_texture_mirroring", false)
	mat.set_shader_parameter("texture_variation_asset_seed", 0.0)
	# One repetition per metre keeps painted materials at their real world scale.
	mat.set_shader_parameter("surface_size_m", Vector2.ONE)
	host._apply_board_resources_to_material(mat)

	host._cache[key] = mat
	return mat
