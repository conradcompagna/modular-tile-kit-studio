@tool
class_name SurfaceMaterialFactory
extends RefCounted

const LifecycleFeature := preload("materials/lifecycle.gd")
const TexturesFeature := preload("materials/textures.gd")
const ShaderVariantsFeature := preload("materials/shader_variants.gd")
const SurfaceMaterialsFeature := preload("materials/surface_materials.gd")
const WorldFieldsFeature := preload("materials/world_fields.gd")
const AlbedoFeature := preload("materials/albedo.gd")
const ImageProcessingFeature := preload("materials/image_processing.gd")
const TerrainBatchesFeature := preload("materials/terrain_batches.gd")
const BlendControlsFeature := preload("materials/blend_controls.gd")
const LayerBindingFeature := preload("materials/layer_binding.gd")
const OrmFeature := preload("materials/orm.gd")

## Resolves the one canonical map set for both PNG presentation choices.
##
## Mesh-presented surfaces bind those maps and board-global controls to the one
## unified GPU shader. Native decals use a thin fixed-slot adapter over the same
## resolved albedo/alpha and stored normal/ORM/emission textures. Missing required
## input is reported; neither presentation substitutes unrelated art or materials.

const K := preload("../utils/mts_constants.gd")
const GPU_SURFACE_SHADER_PATH := "res://addons/modular_tile_studio/rendering/mts_surface_gpu.gdshader"

## Alpha below this does not cast a shadow.
##
## Deliberately low: it keeps soft edges and antialiased fringes casting, while
## fully transparent background pixels of a sprite cast nothing.
const SHADOW_ALPHA_CUTOFF := 0.35
## Every generated surface material stores the authored alpha contract needed to rebuild its shader variant.
const SURFACE_ALPHA_MODE_META := &"mts_surface_alpha_mode"
## Whether this material's own asset enables any texture variation.
##
## Stored per material because the shader variant is chosen when the material is
## built, while material-blend layers are bound later by configure_material_blend.
## That later call combines this asset-side answer with the layers' own answer to
## decide whether the lattice path must be compiled at all.
const SURFACE_ASSET_VARIATION_META := &"mts_surface_asset_variation"
## The combined answer the material's current shader variant actually reflects.
##
## Kept separate from the asset-only answer because a shader-source revision must
## rebuild the variant a material is already on, including a requirement that came
## from its layers rather than its own asset.
const SURFACE_EFFECTIVE_VARIATION_META := &"mts_surface_effective_variation"
## How many material-blend layer slots the material's current shader variant compiled.
##
## Stored for the same reason as the variation answer: a shader-source revision has
## to rebuild the exact variant a material is already on, and the layer requirement
## came from the board profile rather than from anything on the material itself.
const SURFACE_EFFECTIVE_LAYERS_META := &"mts_surface_effective_layers"
## Whether this material's compiled variant contains the board-wide height-field sampler.
const SURFACE_EFFECTIVE_WORLD_HEIGHT_META := &"mts_surface_effective_world_height"
## Four palette indices currently bound to the shader's R/G/B/A layer slots.
const SURFACE_BLEND_SLOT_MATERIALS_META := &"mts_surface_blend_slot_materials"
## How sharply a native decal rejects faces turned away from its projection axis.
##
## Only inside corners need this: the perpendicular wall there sits inside the
## projector box and would otherwise receive a smeared copy of the image. The
## authored face is square to the axis, so a mid strength leaves it untouched.
const DECAL_NORMAL_FADE := 0.5
## Rec. 709 weights keep saturation and sharpening tied to perceived brightness.
const IMAGE_LUMA_WEIGHTS := Vector3(0.2126, 0.7152, 0.0722)

## The board's global GPU-surface response and colour grade. Set by the
## viewport when a board is bound and again whenever the Rendering panel
## changes something. Null is tolerated for headless callers and tests, which
## then use the shipped defaults.
var aesthetics: AestheticProfile = null

## Shared board-wide height/interaction textures. The viewport owns this object
## and all surface ShaderMaterials point at the same ImageTextures. Updating an
## ImageTexture therefore changes the whole board without rebuilding placements.
var world_fields: MTSWorldSurfaceFields = null

## Materials are cached per key so repainting a 7x7 tile test does not rebuild
## dozens of identical materials. Invalidated when maps change, and dropped
## wholesale when the look changes.
var _cache: Dictionary = {}
## Asset ids remember their last complete cache key so a hit avoids image decoding and alpha scans.
var _material_cache_key_by_asset_id: Dictionary = {}

## Composited channel and adjusted albedo textures, keyed by their canonical
## source paths and authored controls. Pixel processing must not rerun per material build.
var _composite_cache: Dictionary = {}
## Fully resolved PBR layer inputs are cached per asset so hundreds of terrain
## batches bind shared textures without decoding and scanning the same images again.
var _layer_binding_cache: Dictionary = {}

## Live per-batch material duplicates, keyed by instance id.
##
## Terrain and blend batches each need their own ShaderMaterial, so they are
## duplicated out of the cache and are therefore NOT reachable through _cache.
## Board-level world and interaction textures are replaced wholesale when their
## bounds change. This registry is the one list that makes those updates reach
## every live material. Entries whose material has been freed are dropped on the
## next sweep, so it can never keep a released resource alive.
var _live_materials: Dictionary = {}
## This factory revision makes its own material cache follow the canonical shader file revision.
var _observed_surface_shader_source_hash: int = -1


func _register_live_material(mat: ShaderMaterial) -> ShaderMaterial:
	return LifecycleFeature._register_live_material(self, mat)


func _all_live_materials() -> Array[ShaderMaterial]:
	return LifecycleFeature._all_live_materials(self)


func _look() -> AestheticProfile:
	return LifecycleFeature._look(self)


func clear_cache() -> void:
	LifecycleFeature.clear_cache(self)


func invalidate(asset_id: String) -> void:
	LifecycleFeature.invalidate(self, asset_id)


# --- Unified GPU material helpers -----------------------------------------

static var _gpu_white: ImageTexture = null
static var _gpu_black: ImageTexture = null
static var _gpu_normal: ImageTexture = null
static var _gpu_error: ImageTexture = null
## Derived shader variants are cached by source revision, visible alpha contract, and culling choice.
static var _gpu_surface_shaders: Dictionary = {}
## The canonical source hash invalidates copied variants when the shader changes during an editor session.
static var _gpu_surface_shader_source_hash: int = -1


static func _solid_texture(colour: Color, format: int = Image.FORMAT_RGBA8) -> ImageTexture:
	return TexturesFeature._solid_texture(colour, format)


static func _white_texture() -> ImageTexture:
	return TexturesFeature._white_texture()


static func _black_texture() -> ImageTexture:
	return TexturesFeature._black_texture()


static func _normal_texture() -> ImageTexture:
	return TexturesFeature._normal_texture()


static func _error_texture() -> ImageTexture:
	return TexturesFeature._error_texture()


func resolved_alpha_mode(asset: TileAsset, visible_albedo: Texture2D = null) -> int:
	return ShaderVariantsFeature.resolved_alpha_mode(self, asset, visible_albedo)


func _surface_shader_source_code() -> String:
	return ShaderVariantsFeature._surface_shader_source_code(self)


func _ensure_surface_shader_source_current() -> void:
	ShaderVariantsFeature._ensure_surface_shader_source_current(self)


static func _asset_uses_texture_variation(asset: TileAsset) -> bool:
	return ShaderVariantsFeature._asset_uses_texture_variation(asset)


static func _profile_uses_texture_variation(
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> bool:
	return ShaderVariantsFeature._profile_uses_texture_variation(profile, library, slot_materials)


static func _mask_dependency_bits(rules_value: Variant) -> int:
	return ShaderVariantsFeature._mask_dependency_bits(rules_value)


static func _profile_layer_count(
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> int:
	return ShaderVariantsFeature._profile_layer_count(profile, library, slot_materials)


static func _resolved_slot_materials(
	profile: MaterialBlendProfile,
	slot_materials: PackedInt32Array
) -> PackedInt32Array:
	return ShaderVariantsFeature._resolved_slot_materials(profile, slot_materials)


func _surface_shader(
	alpha_mode: int,
	uses_texture_variation: bool = true,
	layer_count: int = MaterialBlendProfile.WEIGHTS_PER_TEXEL,
	uses_world_height: bool = true
) -> Shader:
	return ShaderVariantsFeature._surface_shader(self, alpha_mode, uses_texture_variation, layer_count, uses_world_height)


func _build_gpu_surface_material(
	asset: TileAsset,
	albedo: Texture2D,
	maps: GBufferMapSet,
	parallax_source_short_edge_px: float,
	alpha_mode: int
) -> ShaderMaterial:
	return SurfaceMaterialsFeature._build_gpu_surface_material(self, asset, albedo, maps, parallax_source_short_edge_px, alpha_mode)


func _apply_global_shader_parameters(look: AestheticProfile) -> void:
	WorldFieldsFeature._apply_global_shader_parameters(self, look)


func _apply_board_resources_to_material(mat: ShaderMaterial) -> void:
	WorldFieldsFeature._apply_board_resources_to_material(self, mat)


func apply_global_effects(profile: AestheticProfile = null) -> void:
	WorldFieldsFeature.apply_global_effects(self, profile)


func get_visible_albedo(asset: TileAsset) -> Texture2D:
	return AlbedoFeature.get_visible_albedo(self, asset)


func _visible_albedo_with_mipmaps(texture: Texture2D, asset: TileAsset) -> Texture2D:
	return AlbedoFeature._visible_albedo_with_mipmaps(self, texture, asset)


func _image_adjustment_key_fragment(asset: TileAsset) -> String:
	return AlbedoFeature._image_adjustment_key_fragment(self, asset)


func _adjust_visible_albedo(texture: Texture2D, asset: TileAsset) -> Texture2D:
	return AlbedoFeature._adjust_visible_albedo(self, texture, asset)


func configure_decal(decal: Decal, asset: TileAsset) -> bool:
	return SurfaceMaterialsFeature.configure_decal(self, decal, asset)


func get_material(asset: TileAsset) -> Material:
	return SurfaceMaterialsFeature.get_material(self, asset)


static func height_image_short_edge_px(asset: TileAsset) -> float:
	return TexturesFeature.height_image_short_edge_px(asset)


func _albedo_with_alpha(albedo: Texture2D, maps: GBufferMapSet) -> Texture2D:
	return ImageProcessingFeature._albedo_with_alpha(self, albedo, maps)

func _alpha_scissored(albedo: Texture2D, cache_key: String) -> Texture2D:
	return ImageProcessingFeature._alpha_scissored(self, albedo, cache_key)


func _scaled_albedo(texture: Texture2D, key: String, strength: float) -> Texture2D:
	return ImageProcessingFeature._scaled_albedo(self, texture, key, strength)


func _blend_albedo_with_source(analyzed: Texture2D, source: Texture2D, key: String, blend: float) -> Texture2D:
	return ImageProcessingFeature._blend_albedo_with_source(self, analyzed, source, key, blend)


func _adjust_scalar_map(
	texture: Texture2D,
	key: String,
	strength: float,
	neutral: float,
	bias: float
) -> Texture2D:
	return ImageProcessingFeature._adjust_scalar_map(self, texture, key, strength, neutral, bias)


func get_asset_material_for_terrain_batch(
	asset: TileAsset,
	control_texture: Texture2DArray,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	world_height_range: Vector2,
	world_elevation_range: Vector2,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> Material:
	return TerrainBatchesFeature.get_asset_material_for_terrain_batch(self, asset, control_texture, profile, library, world_height_range, world_elevation_range, slot_materials)


func get_material_for_terrain_batch(
	control_texture: Texture2DArray,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	world_height_range: Vector2,
	world_elevation_range: Vector2,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> Material:
	return TerrainBatchesFeature.get_material_for_terrain_batch(self, control_texture, profile, library, world_height_range, world_elevation_range, slot_materials)


func _ensure_material_variant(
	mat: ShaderMaterial,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	slot_materials: PackedInt32Array
) -> void:
	ShaderVariantsFeature._ensure_material_variant(self, mat, profile, library, slot_materials)


func configure_material_blend(
	mat: ShaderMaterial,
	control_texture: Texture2DArray,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	world_height_range: Vector2,
	world_elevation_range: Vector2,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> void:
	BlendControlsFeature.configure_material_blend(self, mat, control_texture, profile, library, world_height_range, world_elevation_range, slot_materials)


func configure_splatmap_channel_strengths(
	mat: ShaderMaterial,
	profile: MaterialBlendProfile
) -> void:
	BlendControlsFeature.configure_splatmap_channel_strengths(self, mat, profile)


func configure_material_mask_preview(
	mat: ShaderMaterial,
	palette_index: int,
	profile: MaterialBlendProfile
) -> bool:
	return BlendControlsFeature.configure_material_mask_preview(self, mat, palette_index, profile)


func configure_material_layer_controls(
	mat: ShaderMaterial,
	palette_index: int,
	profile: MaterialBlendProfile,
	library: AssetLibrary
) -> void:
	BlendControlsFeature.configure_material_layer_controls(self, mat, palette_index, profile, library)


func configure_shader_decal(
	mat: ShaderMaterial,
	placement: SurfacePlacement,
	asset: TileAsset,
	palette_adjustment: Dictionary
) -> bool:
	return BlendControlsFeature.configure_shader_decal(self, mat, placement, asset, palette_adjustment)


func _resolved_layer_binding(overlay: TileAsset) -> Dictionary:
	return LayerBindingFeature._resolved_layer_binding(self, overlay)


func _bind_pbr_layer_asset(
	mat: ShaderMaterial,
	prefix: String,
	overlay: TileAsset
) -> void:
	LayerBindingFeature._bind_pbr_layer_asset(self, mat, prefix, overlay)


func _bind_material_layer(
	mat: ShaderMaterial,
	layer_index: int,
	layer: Dictionary,
	library: AssetLibrary,
	slot_materials: PackedInt32Array
) -> void:
	LayerBindingFeature._bind_material_layer(self, mat, layer_index, layer, library, slot_materials)


func _bind_layer_mask_rules(
	mat: ShaderMaterial,
	layer_index: int,
	rules_value: Variant,
	slot_materials: PackedInt32Array,
	parameter_prefix: String = "",
	owner_palette_index: int = -1,
	skip_structural_paint_rule: bool = false,
	allow_missing_paint_references: bool = false
) -> bool:
	return LayerBindingFeature._bind_layer_mask_rules(self, mat, layer_index, rules_value, slot_materials, parameter_prefix, owner_palette_index, skip_structural_paint_rule, allow_missing_paint_references)


static func _has_primary_orm_source(maps: GBufferMapSet) -> bool:
	return OrmFeature._has_primary_orm_source(maps)


func _resolved_layer_orm(asset: TileAsset) -> Texture2D:
	return OrmFeature._resolved_layer_orm(self, asset)


func _pack_orm_channels(
	ao: Texture2D,
	roughness: Texture2D,
	metallic: Texture2D
) -> Texture2D:
	return OrmFeature._pack_orm_channels(self, ao, roughness, metallic)


func _scalar_channel_image(
	texture: Texture2D,
	resolution: Vector2i,
	default_value: float
) -> Image:
	return OrmFeature._scalar_channel_image(self, texture, resolution, default_value)


func _neutral_orm_texture() -> ImageTexture:
	return OrmFeature._neutral_orm_texture(self)


func _neutral_material_control_array() -> Texture2DArray:
	return OrmFeature._neutral_material_control_array(self)


func _nonzero_range(value: Vector2) -> Vector2:
	return OrmFeature._nonzero_range(self, value)


func _error_material() -> Material:
	return SurfaceMaterialsFeature._error_material(self)


func terrain_material() -> ShaderMaterial:
	return TerrainBatchesFeature.terrain_material(self)


func _load_view_texture(path: String) -> Texture2D:
	return TexturesFeature._load_view_texture(self, path)
