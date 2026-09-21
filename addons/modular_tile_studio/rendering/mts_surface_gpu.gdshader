shader_type spatial;

// Modular Tile Studio unified PNG-surface and material-layer shader.
//
// One shader consumes the asset's authored maps and the board-wide effect
// controls.  The BoardDocument remains simple placement data; none of these
// controls belong in level JSON placements.
//
// Terrain and one-shot shader-decal height maps produce material-only parallax relief.
// Canonical heightfield vertices, collision, and placement data remain unchanged.

// This authored source is the CUTOUT contract; SurfaceMaterialFactory derives
// OPAQUE and BLEND variants by removing only the alpha tokens below.
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx, world_vertex_coords;

// Runtime fixed-isometric occlusion uses an opaque screen-door fade. Keeping the
// material in its existing render pipeline avoids recompiling hundreds of large
// terrain batches whenever a moving actor crosses behind authored architecture.

// The authored source is also the FULL-FEATURE contract. Every optional path is
// defined here, and SurfaceMaterialFactory derives cheaper variants by deleting
// a define for a feature the material provably does not use. Authoring the
// complete contract and subtracting from it means a material can never silently
// lose a feature: an incomplete derivation yields the full shader, not a broken
// one.
//
// MTS_TEXTURE_VARIATION compiles the three-copy stochastic lattice used by
// stochastic tiling, random rotation, and random mirroring. Without it every
// sample is a single fetch, which is the largest single compile-cost multiplier
// in this shader.
#define MTS_TEXTURE_VARIATION

// MTS_LAYER_COUNT compiles that many material-blend layers. Each layer costs five
// projected samples wherever height, albedo, normal and detail are resolved, so a
// board painting one layer has no reason to compile four. The factory rewrites the
// number to the count the board's profile actually enables; 0 removes every layer
// path and leaves the base surface alone.
#define MTS_LAYER_COUNT 4

// The board-wide height field exists only in variants whose material profile
// explicitly consumes WORLD_HEIGHT or displays its diagnostic. The factory
// removes this define for every other board, deleting the sampler and read.
#define MTS_WORLD_HEIGHT_FIELD

// -----------------------------------------------------------------------------
// Per-asset inputs
// -----------------------------------------------------------------------------

group_uniforms AssetTextures;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D height_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// R = ambient occlusion, G = roughness, B = metallic. Analysis-only cavity
// and curvature are baked into R/G before runtime, so this is the sole scalar
// PBR texture consumed by the shader.
uniform sampler2D orm_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D emission_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_id_tex : filter_linear_mipmap_anisotropic, repeat_enable;

group_uniforms AssetPresence;
uniform bool has_height = false;
uniform bool has_normal = false;
uniform bool has_orm = false;
uniform bool has_emission = false;
uniform bool has_detail_albedo = false;
uniform bool has_material_id = false;

group_uniforms AssetResponse;
uniform vec2 surface_size_m = vec2(1.0, 1.0);
uniform float albedo_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform vec4 texture_tint_color : source_color = vec4(1.0);
uniform float texture_tint_strength : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float normal_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float roughness_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float metallic_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float emission_strength : hint_range(0.0, 8.0, 0.01) = 1.0;
uniform float roughness_bias : hint_range(-1.0, 1.0, 0.01) = 0.0;
uniform float metallic_bias : hint_range(-1.0, 1.0, 0.01) = 0.0;
uniform float specular_strength : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float alpha_scissor : hint_range(0.0, 1.0, 0.01) = 0.35;
// How strongly packed material AO attenuates direct light. The board lighting
// profile overrides this on terrain batches; standalone surfaces use this default.
uniform float material_ao_light_affect : hint_range(0.0, 1.0, 0.01) = 0.25;

// Asset-level opt-in. This is the inspector checkbox requested for textures
// that benefit from true stochastic repetition suppression.  It does not alter
// the BoardDocument/placement JSON.
group_uniforms AssetTiling;
uniform bool stochastic_tiling = false;
uniform bool random_texture_rotation = false;
uniform bool random_texture_mirroring = false;
uniform float texture_variation_asset_seed = 0.0;

// -----------------------------------------------------------------------------
// Board-wide scalar effects live in Project Settings > Shader Globals. The
// factory updates them once when the active board profile changes, rather than
// copying identical values into every cached material. Per-board textures stay
// material-local because their lifetime is owned by the active board viewport.
// -----------------------------------------------------------------------------

global uniform float mts_parallax_master;
global uniform float mts_height_metres_per_source_pixel;
// Terrain MultiMeshes read exact face UVs and world vertices by INSTANCE_ID.
// Explicit world points keep projection scale and the true slope normal
// independent from the shared triangle's instance transform.
uniform bool terrain_triangle_instances = false;
uniform sampler2D terrain_instance_data_tex : filter_nearest, repeat_disable;
uniform int terrain_instance_data_width = 1;
// The factory supplies the height map's responsive short-edge sample count.
// Board controls convert it to metres at draw time. Parallax offsets sampling
// only; terrain geometry and collision remain canonical heightfield data.
uniform float parallax_source_short_edge_px = 0.0;
// The visible authoring grid is a fragment treatment on the terrain itself.
// It therefore shares its canonical vertices and cannot Z-fight, float, or
// describe a second planar surface.
uniform bool terrain_grid_is_top = false;
uniform bool terrain_show_top_grid = true;
uniform bool terrain_show_side_grid = false;
uniform vec4 terrain_top_grid_color = vec4(0.035, 0.10, 0.18, 0.82);
uniform vec4 terrain_side_grid_color = vec4(0.02, 0.20, 0.38, 0.90);
uniform float terrain_grid_line_width_px = 1.35;
#ifdef MTS_WORLD_HEIGHT_FIELD
uniform sampler2D g_world_height_tex : filter_linear, repeat_disable;
// xy = world XZ origin, zw = world XZ size in metres.
uniform vec4 g_world_height_rect = vec4(-128.0, -128.0, 256.0, 256.0);
#endif

global uniform float mts_stochastic_scale;
global uniform float mts_stochastic_blend_sharpness;
global uniform float mts_stochastic_seed;


global uniform bool mts_interaction_enabled;
uniform sampler2D g_interaction_tex : filter_linear, repeat_disable;
// Same world XZ mapping as the height field by default.
uniform vec4 g_interaction_rect = vec4(-128.0, -128.0, 256.0, 256.0);
// R is visual grime from real prop and wall/floor contacts.
global uniform float mts_contact_grime;
global uniform float mts_contact_grime_darkening;
global uniform float mts_contact_grime_fade;
global uniform float mts_contact_grime_noise;

// -----------------------------------------------------------------------------
// One-shot shader decals use the same PBR suffixes and MaterialLayerSample as
// painted layers. SurfacePlacement contributes only this non-repeating world-space
// addressing frame; the original source textures stay bound at their imported size.
// -----------------------------------------------------------------------------
group_uniforms ShaderDecal;
uniform bool shader_decal_enabled = false;
// These sampler declarations must match the ordinary material-layer sampler
// state because Godot specializes shared sampler-function arguments by state.
// One-shot behavior is enforced by placement-local UV clamping and coverage,
// never by the sampler's wrap mode.
uniform sampler2D shader_decal_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D shader_decal_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D shader_decal_orm_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D shader_decal_height_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D shader_decal_emission_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D shader_decal_detail_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool shader_decal_has_normal = false;
uniform bool shader_decal_has_height = false;
uniform bool shader_decal_has_emission = false;
uniform bool shader_decal_has_orm = false;
uniform bool shader_decal_has_detail_albedo = false;
uniform float shader_decal_albedo_strength = 1.0;
uniform vec4 shader_decal_tint_color : source_color = vec4(1.0);
uniform float shader_decal_tint_strength = 0.0;
uniform float shader_decal_normal_strength = 1.0;
uniform float shader_decal_ao_strength = 1.0;
uniform float shader_decal_roughness_strength = 1.0;
uniform float shader_decal_metallic_strength = 1.0;
uniform float shader_decal_roughness_bias = 0.0;
uniform float shader_decal_metallic_bias = 0.0;
uniform float shader_decal_emission_strength = 0.0;
uniform float shader_decal_specular_strength = 0.5;
uniform float shader_decal_parallax_source_short_edge_px = 0.0;
uniform vec3 shader_decal_origin = vec3(0.0);
uniform vec3 shader_decal_axis_u = vec3(1.0, 0.0, 0.0);
uniform vec3 shader_decal_axis_v = vec3(0.0, 1.0, 0.0);
uniform vec3 shader_decal_normal = vec3(0.0, 0.0, 1.0);
uniform vec2 shader_decal_footprint_m = vec2(1.0);
uniform vec3 shader_decal_palette_scale = vec3(1.0);
uniform vec3 shader_decal_palette_offset = vec3(0.0);

// -----------------------------------------------------------------------------
// Visible four-layer material blend inputs. The factory binds these exact
// names, so the UI recipe and shader consume one inspectable representation.
// -----------------------------------------------------------------------------

group_uniforms MaterialBlend;
uniform bool material_blend_enabled = false;
uniform int material_blend_mode = 0;
uniform int material_debug_view = 0;
uniform bool material_mask_preview_enabled = false;
// The preview owns one independent mask recipe so it can show reach before a
// palette entry occupies any face-local RGBA slot.
uniform bool material_mask_preview_brush_authored = false;
// Which texel slot the previewed palette entry occupies on this batch, or -1 when
// the batch does not carry it. The preview must exclude its own paint from the
// surface it masks against, exactly as the real layer gate does, or a already-painted
// entry would be shown masking on itself.
uniform int material_mask_preview_slot = -1;
uniform int material_mask_preview_count = 0;
uniform ivec4 material_mask_preview_sources = ivec4(0);
uniform ivec4 material_mask_preview_combines = ivec4(0);
uniform ivec4 material_mask_preview_channels = ivec4(0);
uniform ivec4 material_mask_preview_inversions = ivec4(0);
uniform ivec4 material_mask_preview_paint_available = ivec4(1);
uniform vec4 material_mask_preview_lows = vec4(0.0);
uniform vec4 material_mask_preview_highs = vec4(1.0);
uniform vec4 material_mask_preview_softness = vec4(0.0);
uniform vec4 material_mask_preview_strengths = vec4(1.0);
uniform vec4 material_mask_preview_noise_scales = vec4(1.0);
uniform vec4 material_mask_preview_noise_seeds = vec4(0.0);
uniform vec4 material_mask_preview_noise_angles = vec4(0.0);
uniform sampler2DArray material_control_tex : filter_linear, repeat_disable;
// The loaded terrain-wide RGBA source is an optional guide, independent from
// the canonical per-tile weights that the base-coat brush actually authors.
uniform bool splatmap_source_overlay_enabled = false;
// Weight data, not colour: no source_color hint, or the channels would be sRGB-decoded
// and the guide would disagree with the weights the same image paints.
uniform sampler2D splatmap_source_overlay_tex : filter_linear, repeat_disable;
uniform vec4 splatmap_source_overlay_rect = vec4(0.0, 0.0, 1.0, 1.0);
// Uses the same Top/North/South/East/West enum stored by MaterialBlendProfile.
uniform int splatmap_source_overlay_projection = 0;
// Zeroes every channel whose material slot is unassigned, so an opaque source image
// cannot show a fourth channel the terrain will never actually paint.
uniform vec4 splatmap_source_overlay_channel_mask = vec4(1.0);
// These visible main-panel controls reinterpret canonical RGBA paint at draw time.
// Preserving the original total keeps the base-coat coverage unchanged while ratios move.
uniform bool splatmap_channel_strengths_enabled = false;
uniform vec4 splatmap_channel_strengths = vec4(1.0);
uniform vec2 material_world_height_range = vec2(0.0, 1.0);
uniform vec2 material_world_elevation_range = vec2(0.0, 1.0);

#if MTS_LAYER_COUNT > 0
group_uniforms MaterialLayer1;
uniform bool material_layer_0_enabled = false;
uniform bool material_layer_0_brush_authored = false;
uniform bool material_layer_0_albedo_has_transparency = false;
uniform int material_layer_0_mask_dependencies = 0;
uniform sampler2D material_layer_0_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_0_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_0_orm_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_0_height_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_0_emission_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_0_detail_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool material_layer_0_has_normal = false;
uniform bool material_layer_0_has_height = false;
uniform bool material_layer_0_has_emission = false;
uniform bool material_layer_0_has_orm = false;
uniform bool material_layer_0_has_detail_albedo = false;
uniform float material_layer_0_albedo_strength = 1.0;
uniform vec4 material_layer_0_tint_color : source_color = vec4(1.0);
uniform float material_layer_0_tint_strength = 0.0;
uniform float material_layer_0_normal_strength = 1.0;
uniform float material_layer_0_ao_strength = 1.0;
uniform float material_layer_0_roughness_strength = 1.0;
uniform float material_layer_0_metallic_strength = 1.0;
uniform float material_layer_0_roughness_bias = 0.0;
uniform float material_layer_0_metallic_bias = 0.0;
uniform float material_layer_0_specular_strength = 0.5;
uniform float material_layer_0_opacity = 1.0;
uniform float material_layer_0_height_blend = 0.0;
// Source-height resolution × Height response for this painted layer.
uniform float material_layer_0_parallax_source_short_edge_px = 0.0;
uniform float material_layer_0_emission_strength = 0.0;
uniform vec2 material_layer_0_repeat_m = vec2(1.0);
uniform bool material_layer_0_stochastic_tiling = false;
uniform bool material_layer_0_random_texture_rotation = false;
uniform bool material_layer_0_random_texture_mirroring = false;
uniform float material_layer_0_variation_asset_seed = 0.0;
uniform int material_layer_0_mask_count = 0;
uniform ivec4 material_layer_0_mask_sources = ivec4(0);
uniform ivec4 material_layer_0_mask_combines = ivec4(0);
uniform ivec4 material_layer_0_mask_channels = ivec4(0);
uniform ivec4 material_layer_0_mask_inversions = ivec4(0);
uniform vec4 material_layer_0_mask_lows = vec4(0.0);
uniform vec4 material_layer_0_mask_highs = vec4(1.0);
uniform vec4 material_layer_0_mask_softness = vec4(0.0);
uniform vec4 material_layer_0_mask_strengths = vec4(1.0);
uniform vec4 material_layer_0_mask_noise_scales = vec4(1.0);
uniform vec4 material_layer_0_mask_noise_seeds = vec4(0.0);
uniform vec4 material_layer_0_mask_noise_angles = vec4(0.0);

#endif
#if MTS_LAYER_COUNT > 1
group_uniforms MaterialLayer2;
uniform bool material_layer_1_enabled = false;
uniform bool material_layer_1_brush_authored = false;
uniform bool material_layer_1_albedo_has_transparency = false;
uniform int material_layer_1_mask_dependencies = 0;
uniform sampler2D material_layer_1_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_1_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_1_orm_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_1_height_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_1_emission_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_1_detail_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool material_layer_1_has_normal = false;
uniform bool material_layer_1_has_height = false;
uniform bool material_layer_1_has_emission = false;
uniform bool material_layer_1_has_orm = false;
uniform bool material_layer_1_has_detail_albedo = false;
uniform float material_layer_1_albedo_strength = 1.0;
uniform vec4 material_layer_1_tint_color : source_color = vec4(1.0);
uniform float material_layer_1_tint_strength = 0.0;
uniform float material_layer_1_normal_strength = 1.0;
uniform float material_layer_1_ao_strength = 1.0;
uniform float material_layer_1_roughness_strength = 1.0;
uniform float material_layer_1_metallic_strength = 1.0;
uniform float material_layer_1_roughness_bias = 0.0;
uniform float material_layer_1_metallic_bias = 0.0;
uniform float material_layer_1_specular_strength = 0.5;
uniform float material_layer_1_opacity = 1.0;
uniform float material_layer_1_height_blend = 0.0;
// Source-height resolution × Height response for this painted layer.
uniform float material_layer_1_parallax_source_short_edge_px = 0.0;
uniform float material_layer_1_emission_strength = 0.0;
uniform vec2 material_layer_1_repeat_m = vec2(1.0);
uniform bool material_layer_1_stochastic_tiling = false;
uniform bool material_layer_1_random_texture_rotation = false;
uniform bool material_layer_1_random_texture_mirroring = false;
uniform float material_layer_1_variation_asset_seed = 0.0;
uniform int material_layer_1_mask_count = 0;
uniform ivec4 material_layer_1_mask_sources = ivec4(0);
uniform ivec4 material_layer_1_mask_combines = ivec4(0);
uniform ivec4 material_layer_1_mask_channels = ivec4(0);
uniform ivec4 material_layer_1_mask_inversions = ivec4(0);
uniform vec4 material_layer_1_mask_lows = vec4(0.0);
uniform vec4 material_layer_1_mask_highs = vec4(1.0);
uniform vec4 material_layer_1_mask_softness = vec4(0.0);
uniform vec4 material_layer_1_mask_strengths = vec4(1.0);
uniform vec4 material_layer_1_mask_noise_scales = vec4(1.0);
uniform vec4 material_layer_1_mask_noise_seeds = vec4(0.0);
uniform vec4 material_layer_1_mask_noise_angles = vec4(0.0);

#endif
#if MTS_LAYER_COUNT > 2
group_uniforms MaterialLayer3;
uniform bool material_layer_2_enabled = false;
uniform bool material_layer_2_brush_authored = false;
uniform bool material_layer_2_albedo_has_transparency = false;
uniform int material_layer_2_mask_dependencies = 0;
uniform sampler2D material_layer_2_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_2_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_2_orm_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_2_height_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_2_emission_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_2_detail_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool material_layer_2_has_normal = false;
uniform bool material_layer_2_has_height = false;
uniform bool material_layer_2_has_emission = false;
uniform bool material_layer_2_has_orm = false;
uniform bool material_layer_2_has_detail_albedo = false;
uniform float material_layer_2_albedo_strength = 1.0;
uniform vec4 material_layer_2_tint_color : source_color = vec4(1.0);
uniform float material_layer_2_tint_strength = 0.0;
uniform float material_layer_2_normal_strength = 1.0;
uniform float material_layer_2_ao_strength = 1.0;
uniform float material_layer_2_roughness_strength = 1.0;
uniform float material_layer_2_metallic_strength = 1.0;
uniform float material_layer_2_roughness_bias = 0.0;
uniform float material_layer_2_metallic_bias = 0.0;
uniform float material_layer_2_specular_strength = 0.5;
uniform float material_layer_2_opacity = 1.0;
uniform float material_layer_2_height_blend = 0.0;
// Source-height resolution × Height response for this painted layer.
uniform float material_layer_2_parallax_source_short_edge_px = 0.0;
uniform float material_layer_2_emission_strength = 0.0;
uniform vec2 material_layer_2_repeat_m = vec2(1.0);
uniform bool material_layer_2_stochastic_tiling = false;
uniform bool material_layer_2_random_texture_rotation = false;
uniform bool material_layer_2_random_texture_mirroring = false;
uniform float material_layer_2_variation_asset_seed = 0.0;
uniform int material_layer_2_mask_count = 0;
uniform ivec4 material_layer_2_mask_sources = ivec4(0);
uniform ivec4 material_layer_2_mask_combines = ivec4(0);
uniform ivec4 material_layer_2_mask_channels = ivec4(0);
uniform ivec4 material_layer_2_mask_inversions = ivec4(0);
uniform vec4 material_layer_2_mask_lows = vec4(0.0);
uniform vec4 material_layer_2_mask_highs = vec4(1.0);
uniform vec4 material_layer_2_mask_softness = vec4(0.0);
uniform vec4 material_layer_2_mask_strengths = vec4(1.0);
uniform vec4 material_layer_2_mask_noise_scales = vec4(1.0);
uniform vec4 material_layer_2_mask_noise_seeds = vec4(0.0);
uniform vec4 material_layer_2_mask_noise_angles = vec4(0.0);

#endif
#if MTS_LAYER_COUNT > 3
group_uniforms MaterialLayer4;
uniform bool material_layer_3_enabled = false;
uniform bool material_layer_3_brush_authored = false;
uniform bool material_layer_3_albedo_has_transparency = false;
uniform int material_layer_3_mask_dependencies = 0;
uniform sampler2D material_layer_3_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_3_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_3_orm_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_3_height_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_3_emission_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D material_layer_3_detail_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool material_layer_3_has_normal = false;
uniform bool material_layer_3_has_height = false;
uniform bool material_layer_3_has_emission = false;
uniform bool material_layer_3_has_orm = false;
uniform bool material_layer_3_has_detail_albedo = false;
uniform float material_layer_3_albedo_strength = 1.0;
uniform vec4 material_layer_3_tint_color : source_color = vec4(1.0);
uniform float material_layer_3_tint_strength = 0.0;
uniform float material_layer_3_normal_strength = 1.0;
uniform float material_layer_3_ao_strength = 1.0;
uniform float material_layer_3_roughness_strength = 1.0;
uniform float material_layer_3_metallic_strength = 1.0;
uniform float material_layer_3_roughness_bias = 0.0;
uniform float material_layer_3_metallic_bias = 0.0;
uniform float material_layer_3_specular_strength = 0.5;
uniform float material_layer_3_opacity = 1.0;
uniform float material_layer_3_height_blend = 0.0;
// Source-height resolution × Height response for this painted layer.
uniform float material_layer_3_parallax_source_short_edge_px = 0.0;
uniform float material_layer_3_emission_strength = 0.0;
uniform vec2 material_layer_3_repeat_m = vec2(1.0);
uniform bool material_layer_3_stochastic_tiling = false;
uniform bool material_layer_3_random_texture_rotation = false;
uniform bool material_layer_3_random_texture_mirroring = false;
uniform float material_layer_3_variation_asset_seed = 0.0;
uniform int material_layer_3_mask_count = 0;
uniform ivec4 material_layer_3_mask_sources = ivec4(0);
uniform ivec4 material_layer_3_mask_combines = ivec4(0);
uniform ivec4 material_layer_3_mask_channels = ivec4(0);
uniform ivec4 material_layer_3_mask_inversions = ivec4(0);
uniform vec4 material_layer_3_mask_lows = vec4(0.0);
uniform vec4 material_layer_3_mask_highs = vec4(1.0);
uniform vec4 material_layer_3_mask_softness = vec4(0.0);
uniform vec4 material_layer_3_mask_strengths = vec4(1.0);
uniform vec4 material_layer_3_mask_noise_scales = vec4(1.0);
uniform vec4 material_layer_3_mask_noise_seeds = vec4(0.0);
uniform vec4 material_layer_3_mask_noise_angles = vec4(0.0);

#endif
// -----------------------------------------------------------------------------
// Varyings
// -----------------------------------------------------------------------------

varying vec3 v_world_pos;
varying vec3 v_base_world_pos;
varying vec3 v_base_normal_world;
varying vec3 v_tangent_world;
varying vec3 v_binormal_world;
varying vec2 v_metric_uv;
varying vec2 v_surface_uv;
varying vec3 v_terrain_barycentric;
varying flat float v_terrain_boundary_mask;
varying flat float v_material_control_layer;
// 0 = base only, 1 = one fully weighted slot, 2 = mixed control texture.
varying flat float v_material_control_class;
varying flat float v_material_uniform_slot;
// The painting placement's authored in-plane rotation, in 0..3 quarter turns.
varying flat float v_texture_quarters;
// Each face-local RGBA overlay slot carries the regular PNG brush quarter turn.
varying flat vec4 v_material_texture_quarters;
// Stage built-ins are not visible inside user-defined functions, so vertex()
// republishes the camera position for the parallax helpers. The value is
// constant across every vertex, so interpolation reproduces it exactly.
varying flat vec3 v_camera_position_world;

// -----------------------------------------------------------------------------
// Utility / stochastic texture sampling
// -----------------------------------------------------------------------------

vec2 safe_size(vec2 size_m) {
	return max(abs(size_m), vec2(0.0001));
}

vec2 hash22(vec2 p, float seed) {
	vec2 q = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(q + vec2(seed * 17.17, seed * 43.11)) * 43758.5453123);
}

// Return a deterministic scalar hash for one lattice identifier and seed.
float hash12(vec2 p, float seed) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + seed * 17.17) * 43758.5453123);
}

// Turn a coordinate by an exact number of quarter turns.
vec2 rotate_quarter_turns(vec2 coord, int steps) {
	if (steps == 1) {
		return vec2(-coord.y, coord.x);
	}
	if (steps == 2) {
		return -coord;
	}
	if (steps == 3) {
		return vec2(coord.y, -coord.x);
	}
	return coord;
}

// Return shared lattice identifiers and continuous barycentric weights.
void variation_triangle(vec2 coord, out vec2 id0, out vec2 id1, out vec2 id2, out vec3 weights) {
	vec2 skewed = vec2(coord.x - 0.57735026919 * coord.y, 1.15470053838 * coord.y);
	vec2 cell = floor(skewed);
	vec2 fraction = fract(skewed);
	float diagonal = 1.0 - fraction.x - fraction.y;
	if (diagonal > 0.0) {
		weights = vec3(diagonal, fraction.y, fraction.x);
		id0 = cell;
		id1 = cell + vec2(0.0, 1.0);
		id2 = cell + vec2(1.0, 0.0);
	} else {
		weights = vec3(-diagonal, 1.0 - fraction.y, 1.0 - fraction.x);
		id0 = cell + vec2(1.0, 1.0);
		id1 = cell + vec2(1.0, 0.0);
		id2 = cell + vec2(0.0, 1.0);
	}
	weights = pow(max(weights, vec3(0.00001)), vec3(max(mts_stochastic_blend_sharpness, 0.01)));
	weights /= max(weights.x + weights.y + weights.z, 0.00001);
}

// Resolve one lattice copy's phase, quarter-turn, and mirror from explicit asset controls.
void texture_variation_descriptor(
	vec2 coord,
	vec2 lattice_id,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	out vec2 sample_coord,
	out int quarter_turns,
	out bool mirrored
) {
	float full_seed = asset_seed + mts_stochastic_seed;
	sample_coord = coord;
	if (use_stochastic_tiling) {
		sample_coord += hash22(lattice_id, full_seed);
	}
	quarter_turns = use_random_rotation ? int(floor(hash12(lattice_id, full_seed + 71.31) * 4.0)) : 0;
	mirrored = use_random_mirroring && hash12(lattice_id, full_seed + 149.73) >= 0.5;
	if (mirrored) {
		sample_coord.x = -sample_coord.x;
	}
	sample_coord = rotate_quarter_turns(sample_coord, quarter_turns);
}

// Apply the same rotation and mirror to texture gradients as to their coordinate.
vec2 texture_variation_direction(vec2 direction, int quarter_turns, bool mirrored) {
	if (mirrored) {
		direction.x = -direction.x;
	}
	return rotate_quarter_turns(direction, quarter_turns);
}

// Return a sampled tangent normal from varied texture space to the original surface frame.
vec2 texture_variation_normal_xy(vec2 normal_xy, int quarter_turns, bool mirrored) {
	normal_xy = rotate_quarter_turns(normal_xy, (4 - quarter_turns) & 3);
	if (mirrored) {
		normal_xy.x = -normal_xy.x;
	}
	return normal_xy;
}

// PNG maps always repeat; texture variation changes sampling synthesis only.
vec2 clamp_regular_coord(sampler2D tex, vec2 coord) {
	return coord;
}

// Sample one channel with any independently enabled texture-variation controls.
vec4 sample_surface_fragment(
	sampler2D tex,
	vec2 coord,
	vec2 grad_x,
	vec2 grad_y,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring
) {
#ifdef MTS_TEXTURE_VARIATION
	if (!use_stochastic_tiling && !use_random_rotation && !use_random_mirroring) {
		return textureGrad(tex, clamp_regular_coord(tex, coord), grad_x, grad_y);
	}
	vec2 id0;
	vec2 id1;
	vec2 id2;
	vec3 weights;
	variation_triangle(coord, id0, id1, id2, weights);
	vec2 coord0;
	vec2 coord1;
	vec2 coord2;
	int turns0;
	int turns1;
	int turns2;
	bool mirror0;
	bool mirror1;
	bool mirror2;
	texture_variation_descriptor(coord, id0, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord0, turns0, mirror0);
	texture_variation_descriptor(coord, id1, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord1, turns1, mirror1);
	texture_variation_descriptor(coord, id2, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord2, turns2, mirror2);
	return (
		textureGrad(tex, coord0, texture_variation_direction(grad_x, turns0, mirror0), texture_variation_direction(grad_y, turns0, mirror0)) * weights.x
		+ textureGrad(tex, coord1, texture_variation_direction(grad_x, turns1, mirror1), texture_variation_direction(grad_y, turns1, mirror1)) * weights.y
		+ textureGrad(tex, coord2, texture_variation_direction(grad_x, turns2, mirror2), texture_variation_direction(grad_y, turns2, mirror2)) * weights.z
	);
#else
	// SurfaceMaterialFactory compiled this variant for a material whose assets
	// enable no texture variation, so the three-copy lattice path does not exist
	// here at all. The runtime flags are always false in this variant.
	return textureGrad(tex, clamp_regular_coord(tex, coord), grad_x, grad_y);
#endif
}

// Sample vertex-stage data through the same explicit variation descriptor.
vec4 sample_surface_vertex(
	sampler2D tex,
	vec2 coord,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring
) {
#ifdef MTS_TEXTURE_VARIATION
	if (!use_stochastic_tiling && !use_random_rotation && !use_random_mirroring) {
		return textureLod(tex, clamp_regular_coord(tex, coord), 0.0);
	}
	vec2 id0;
	vec2 id1;
	vec2 id2;
	vec3 weights;
	variation_triangle(coord, id0, id1, id2, weights);
	vec2 coord0;
	vec2 coord1;
	vec2 coord2;
	int turns0;
	int turns1;
	int turns2;
	bool mirror0;
	bool mirror1;
	bool mirror2;
	texture_variation_descriptor(coord, id0, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord0, turns0, mirror0);
	texture_variation_descriptor(coord, id1, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord1, turns1, mirror1);
	texture_variation_descriptor(coord, id2, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord2, turns2, mirror2);
	return textureLod(tex, coord0, 0.0) * weights.x + textureLod(tex, coord1, 0.0) * weights.y + textureLod(tex, coord2, 0.0) * weights.z;
#else
	// No-variation variant: the lattice path is not compiled. See
	// sample_surface_fragment for the same contract on the fragment side.
	return textureLod(tex, clamp_regular_coord(tex, coord), 0.0);
#endif
}

// Return continuous blend weights for the map-wide X, Y, and Z projections.
vec3 world_projection_weights(vec3 world_normal) {
	vec3 weights = abs(normalize(world_normal));
	return weights / max(weights.x + weights.y + weights.z, 0.00001);
}

// Return this triangle's authored in-plane rotation as 0..3 quarter turns.
int surface_quarter_turns() {
	return int(round(v_texture_quarters)) & 3;
}

// Return one RGBA material slot's face-local regular PNG brush orientation.
int material_layer_quarter_turns(int material_slot) {
	if (material_slot == 0) {
		return int(round(v_material_texture_quarters.r)) & 3;
	}
	if (material_slot == 1) {
		return int(round(v_material_texture_quarters.g)) & 3;
	}
	if (material_slot == 2) {
		return int(round(v_material_texture_quarters.b)) & 3;
	}
	return int(round(v_material_texture_quarters.a)) & 3;
}

// Convert a tangent-plane world direction into the receiving face's exact UV delta.
//
// The solve uses fragment derivatives from the canonical triangle, so clipped side
// bands and sloped faces retain their real UV scale rather than assuming one metre.
vec2 surface_uv_direction_from_world(
	vec3 world_direction,
	vec3 world_ddx,
	vec3 world_ddy,
	vec2 uv_ddx,
	vec2 uv_ddy
) {
	float xx = dot(world_ddx, world_ddx);
	float xy = dot(world_ddx, world_ddy);
	float yy = dot(world_ddy, world_ddy);
	float determinant = xx * yy - xy * xy;
	if (abs(determinant) <= 0.0000000001) {
		return vec2(0.0);
	}
	float direction_x = dot(world_direction, world_ddx);
	float direction_y = dot(world_direction, world_ddy);
	float screen_x = (direction_x * yy - direction_y * xy) / determinant;
	float screen_y = (direction_y * xx - direction_x * xy) / determinant;
	return uv_ddx * screen_x + uv_ddy * screen_y;
}

// Convert one world point into the decal asset's placement-local 0..1 footprint.
vec2 shader_decal_uv_for_world_position(vec3 world_pos) {
	vec3 offset = world_pos - shader_decal_origin;
	return vec2(
		dot(offset, shader_decal_axis_u) / max(shader_decal_footprint_m.x, 0.0001) + 0.5,
		0.5 - dot(offset, shader_decal_axis_v) / max(shader_decal_footprint_m.y, 0.0001)
	);
}

// Convert a world direction into the matching decal-UV direction without translation.
vec2 shader_decal_uv_for_world_direction(vec3 world_direction) {
	return vec2(
		dot(world_direction, shader_decal_axis_u) / max(shader_decal_footprint_m.x, 0.0001),
		-dot(world_direction, shader_decal_axis_v) / max(shader_decal_footprint_m.y, 0.0001)
	);
}

// Return one only inside the authored footprint so clamp sampling cannot repeat edge pixels.
float shader_decal_inside(vec2 decal_uv) {
	vec2 lower = step(vec2(0.0), decal_uv);
	vec2 upper = step(decal_uv, vec2(1.0));
	return lower.x * lower.y * upper.x * upper.y;
}

// Sample normalized decal height, source response, and source-alpha coverage together.
vec3 sample_shader_decal_height(vec2 decal_uv, vec2 grad_x, vec2 grad_y) {
	if (!shader_decal_enabled || !shader_decal_has_height) {
		return vec3(0.5, 0.0, 0.0);
	}
	vec2 albedo_inset = 0.5 / max(
		vec2(textureSize(shader_decal_albedo_tex, 0)),
		vec2(1.0)
	);
	vec2 height_inset = 0.5 / max(
		vec2(textureSize(shader_decal_height_tex, 0)),
		vec2(1.0)
	);
	vec2 albedo_uv = clamp(decal_uv, albedo_inset, vec2(1.0) - albedo_inset);
	vec2 height_uv = clamp(decal_uv, height_inset, vec2(1.0) - height_inset);
	float coverage = textureGrad(shader_decal_albedo_tex, albedo_uv, grad_x, grad_y).a;
	coverage *= shader_decal_inside(decal_uv);
	float height = textureGrad(shader_decal_height_tex, height_uv, grad_x, grad_y).r;
	return vec3(
		height,
		shader_decal_parallax_source_short_edge_px,
		clamp(coverage, 0.0, 1.0)
	);
}

// Sample one material channel from a field anchored to the world origin.
//
// The coordinate permutations contain no face-dependent sign or tangent, so a
// grid square cannot mirror, offset, or rescale the pattern on its own. The one
// thing it may change is the authored quarter turn carried per placement.
vec4 sample_projected_fragment_oriented(
	sampler2D tex,
	vec2 planar_coord,
	vec2 planar_grad_x,
	vec2 planar_grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	int orientation_quarters
) {
	if (!terrain_triangle_instances) {
		return sample_surface_fragment(
			tex, planar_coord, planar_grad_x, planar_grad_y,
			use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring
		);
	}
	vec2 period_m = safe_size(repeat_m);
	if (use_stochastic_tiling) {
		period_m *= max(mts_stochastic_scale, 0.0001);
	}
	int steps = orientation_quarters & 3;
	vec2 coord_x = rotate_quarter_turns(vec2(-world_pos.z, world_pos.y), steps) / period_m;
	vec2 coord_y = rotate_quarter_turns(vec2(world_pos.x, -world_pos.z), steps) / period_m;
	vec2 coord_z = rotate_quarter_turns(vec2(world_pos.x, world_pos.y), steps) / period_m;
	vec3 weights = world_projection_weights(world_normal);
	// Axis-aligned walls and nearly all flat terrain need one projected fetch.
	// The threshold is intentionally exact enough to reject only numerical slope
	// noise; genuinely sloped faces retain the complete three-axis blend.
	if (weights.x >= 0.999) {
		return sample_surface_fragment(tex, coord_x, dFdx(coord_x), dFdy(coord_x), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	}
	if (weights.y >= 0.999) {
		return sample_surface_fragment(tex, coord_y, dFdx(coord_y), dFdy(coord_y), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	}
	if (weights.z >= 0.999) {
		return sample_surface_fragment(tex, coord_z, dFdx(coord_z), dFdy(coord_z), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	}
	return (
		sample_surface_fragment(tex, coord_x, dFdx(coord_x), dFdy(coord_x), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring) * weights.x
		+ sample_surface_fragment(tex, coord_y, dFdx(coord_y), dFdy(coord_y), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring) * weights.y
		+ sample_surface_fragment(tex, coord_z, dFdx(coord_z), dFdy(coord_z), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring) * weights.z
	);
}

// Sample the base coat through its authored regular terrain-paint orientation.
vec4 sample_projected_fragment_raw(
	sampler2D tex,
	vec2 planar_coord,
	vec2 planar_grad_x,
	vec2 planar_grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring
) {
	return sample_projected_fragment_oriented(
		tex, planar_coord, planar_grad_x, planar_grad_y,
		world_pos, world_normal, repeat_m, use_stochastic_tiling,
		asset_seed, use_random_rotation, use_random_mirroring,
		surface_quarter_turns()
	);
}


// Apply live RGBA multipliers while preserving the authored pixel's total coverage.
// This declaration precedes terrain_parallax_height because Godot resolves shader
// functions in source order and the parallax helpers are the first consumers.
const float MTS_PAINT_WEIGHT_THRESHOLD = 4.0 / 255.0;

// Remove 8-bit encoding noise while preserving meaningful authored base coverage.
// If the remaining base coat is itself at or below the same threshold, the
// painted survivors expand to full coverage so no downstream base channel is read.
vec4 prune_material_weights(vec4 weights) {
	vec4 positive = max(weights, vec4(0.0));
	float original_total = dot(positive, vec4(1.0));
	vec4 surviving = positive * step(vec4(MTS_PAINT_WEIGHT_THRESHOLD + 0.000001), positive);
	float surviving_total = dot(surviving, vec4(1.0));
	if (surviving_total <= 0.00001) {
		return vec4(0.0);
	}
	float original_base_weight = max(1.0 - original_total, 0.0);
	float resolved_painted_total = original_base_weight <= MTS_PAINT_WEIGHT_THRESHOLD
		? 1.0
		: original_total;
	return surviving * (resolved_painted_total / surviving_total);
}

vec4 adjusted_splatmap_channel_weights(vec4 weights) {
	vec4 native_weights = max(weights, vec4(0.0));
	if (!splatmap_channel_strengths_enabled) {
		return prune_material_weights(native_weights);
	}
	float native_total = dot(native_weights, vec4(1.0));
	vec4 adjusted = native_weights * max(splatmap_channel_strengths, vec4(0.0));
	float adjusted_total = dot(adjusted, vec4(1.0));
	if (native_total <= 0.00001 || adjusted_total <= 0.00001) {
		return vec4(0.0);
	}
	return prune_material_weights(adjusted * (native_total / adjusted_total));
}

// Resolve this fragment's canonical painted weights exactly once.
//
// Whole-face classification is carried by MultiMesh COLOR. Base-only and
// uniform faces therefore never touch the control array, while mixed faces
// perform the sole texture read reused by parallax, masks, and composition.
vec4 resolved_material_control_weights() {
	if (!material_blend_enabled) {
		return vec4(0.0);
	}
	if (terrain_triangle_instances && v_material_control_class < 0.5) {
		return vec4(0.0);
	}
	if (terrain_triangle_instances && v_material_control_class < 1.5) {
		vec4 uniform_weights = vec4(0.0);
		int slot = int(round(v_material_uniform_slot));
		if (slot == 0) {
			uniform_weights.r = 1.0;
		} else if (slot == 1) {
			uniform_weights.g = 1.0;
		} else if (slot == 2) {
			uniform_weights.b = 1.0;
		} else {
			uniform_weights.a = 1.0;
		}
		return adjusted_splatmap_channel_weights(uniform_weights);
	}
	return adjusted_splatmap_channel_weights(texture(
		material_control_tex,
		vec3(clamp(v_surface_uv, vec2(0.0), vec2(1.0)), v_material_control_layer)
	));
}

// Resolve which height sources contribute at this fragment and how strongly.
//
// The weights depend only on the painted splat control texture, never on the
// sampled world position, so they are constant along a parallax ray and both
// parallax modes read them from here. Restating this mix per mode would let the
// two modes disagree about the same painted surface.
void terrain_parallax_weights(
	vec4 painted_weights,
	out float base_weight,
	out vec4 layer_weights,
	out float total_weight,
	out float source_short_edge_px
) {
	base_weight = has_height ? 1.0 : 0.0;
	layer_weights = vec4(0.0);
	float base_source_px = has_height ? parallax_source_short_edge_px : 0.0;
	if (!material_blend_enabled) {
		total_weight = base_weight;
		source_short_edge_px = base_source_px;
		return;
	}

	// Only a layer this variant actually compiled can contribute; the others stay
	// zero, so a reduced variant blends exactly as the full shader would with
	// those layers disabled.
	vec4 layer_mask = vec4(0.0);
#if MTS_LAYER_COUNT > 0
	layer_mask.x = (material_layer_0_enabled && material_layer_0_has_height) ? 1.0 : 0.0;
#endif
#if MTS_LAYER_COUNT > 1
	layer_mask.y = (material_layer_1_enabled && material_layer_1_has_height) ? 1.0 : 0.0;
#endif
#if MTS_LAYER_COUNT > 2
	layer_mask.z = (material_layer_2_enabled && material_layer_2_has_height) ? 1.0 : 0.0;
#endif
#if MTS_LAYER_COUNT > 3
	layer_mask.w = (material_layer_3_enabled && material_layer_3_has_height) ? 1.0 : 0.0;
#endif
	layer_weights = max(painted_weights, vec4(0.0)) * layer_mask;
	base_weight *= max(1.0 - dot(max(painted_weights, vec4(0.0)), vec4(1.0)), 0.0);
	total_weight = base_weight + dot(layer_weights, vec4(1.0));
	if (total_weight <= 0.00001) {
		source_short_edge_px = 0.0;
		return;
	}
	float source_px_sum = base_source_px * base_weight;
#if MTS_LAYER_COUNT > 0
	source_px_sum += material_layer_0_parallax_source_short_edge_px * layer_weights.x;
#endif
#if MTS_LAYER_COUNT > 1
	source_px_sum += material_layer_1_parallax_source_short_edge_px * layer_weights.y;
#endif
#if MTS_LAYER_COUNT > 2
	source_px_sum += material_layer_2_parallax_source_short_edge_px * layer_weights.z;
#endif
#if MTS_LAYER_COUNT > 3
	source_px_sum += material_layer_3_parallax_source_short_edge_px * layer_weights.w;
#endif
	source_short_edge_px = source_px_sum / total_weight;
}

// Resolve the visible terrain height before offsetting texture samples.
//
// Direct terrain paint uses its own height map. Material-paint layers use their
// painted weights, so an artist's map painting is the sole source of which
// height relief appears in each terrain region.
void terrain_parallax_height(
	vec3 world_pos,
	vec3 world_normal,
	vec4 painted_weights,
	out float height,
	out float relief_range_m
) {
	height = 0.5;
	relief_range_m = 0.0;
	if (!terrain_triangle_instances) {
		return;
	}

	vec2 face_coord = v_surface_uv;
	vec2 face_grad_x = dFdx(face_coord);
	vec2 face_grad_y = dFdy(face_coord);

	float base_height = has_height ? sample_projected_fragment_raw(
		height_tex, face_coord, face_grad_x, face_grad_y,
		world_pos, world_normal, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
	).r : 0.5;

	float base_weight;
	vec4 layer_weights;
	float total_weight;
	float source_short_edge_px;
	terrain_parallax_weights(painted_weights, base_weight, layer_weights, total_weight, source_short_edge_px);
	if (!material_blend_enabled) {
		height = base_height;
	} else if (total_weight > 0.00001) {
		// Accumulated rather than summed in one expression so a layer this variant
		// did not compile contributes nothing without leaving a dangling term. Its
		// weight is already zero in layer_weights, so the result is identical to
		// the full shader with that layer disabled.
		float height_sum = base_height * base_weight;
#if MTS_LAYER_COUNT > 0
		height_sum += sample_projected_fragment_oriented(
			material_layer_0_height_tex, face_coord, face_grad_x, face_grad_y,
			world_pos, world_normal, material_layer_0_repeat_m,
			material_layer_0_stochastic_tiling, material_layer_0_variation_asset_seed,
			material_layer_0_random_texture_rotation, material_layer_0_random_texture_mirroring, material_layer_quarter_turns(0)
		).r * layer_weights.x;
#endif
#if MTS_LAYER_COUNT > 1
		height_sum += sample_projected_fragment_oriented(
			material_layer_1_height_tex, face_coord, face_grad_x, face_grad_y,
			world_pos, world_normal, material_layer_1_repeat_m,
			material_layer_1_stochastic_tiling, material_layer_1_variation_asset_seed,
			material_layer_1_random_texture_rotation, material_layer_1_random_texture_mirroring, material_layer_quarter_turns(1)
		).r * layer_weights.y;
#endif
#if MTS_LAYER_COUNT > 2
		height_sum += sample_projected_fragment_oriented(
			material_layer_2_height_tex, face_coord, face_grad_x, face_grad_y,
			world_pos, world_normal, material_layer_2_repeat_m,
			material_layer_2_stochastic_tiling, material_layer_2_variation_asset_seed,
			material_layer_2_random_texture_rotation, material_layer_2_random_texture_mirroring, material_layer_quarter_turns(2)
		).r * layer_weights.z;
#endif
#if MTS_LAYER_COUNT > 3
		height_sum += sample_projected_fragment_oriented(
			material_layer_3_height_tex, face_coord, face_grad_x, face_grad_y,
			world_pos, world_normal, material_layer_3_repeat_m,
			material_layer_3_stochastic_tiling, material_layer_3_variation_asset_seed,
			material_layer_3_random_texture_rotation, material_layer_3_random_texture_mirroring, material_layer_quarter_turns(3)
		).r * layer_weights.w;
#endif
		height = height_sum / total_weight;
	}

	relief_range_m = source_short_edge_px * mts_height_metres_per_source_pixel;
	// A one-shot decal is the topmost material at its source alpha. It uses the
	// same board-wide height conversion while changing only texture addressing.
	vec2 decal_coord = shader_decal_uv_for_world_position(world_pos);
	vec2 decal_grad_x = shader_decal_uv_for_world_direction(dFdx(world_pos));
	vec2 decal_grad_y = shader_decal_uv_for_world_direction(dFdy(world_pos));
	vec3 decal_height = sample_shader_decal_height(
		decal_coord, decal_grad_x, decal_grad_y
	);
	height = mix(height, decal_height.r, decal_height.b);
	float decal_relief_range_m = decal_height.g * mts_height_metres_per_source_pixel;
	relief_range_m = mix(relief_range_m, decal_relief_range_m, decal_height.b);
	relief_range_m *= mts_parallax_master;
}

// RETIRED: Offset terrain samples once using the visible painted height.
//
// This legacy implementation is intentionally retained as dead reference code.
// The active shader path never calls it; raymarching is the sole parallax system.
vec3 offset_parallax_sample_world_pos(vec3 world_pos, vec3 world_normal) {
	if (!terrain_triangle_instances) {
		return world_pos;
	}
	vec3 normal_ws = normalize(world_normal);
	float height;
	float relief_range_m;
	terrain_parallax_height(world_pos, normal_ws, resolved_material_control_weights(), height, relief_range_m);
	if (relief_range_m <= 0.0) {
		return world_pos;
	}
	vec3 view_ws = normalize(v_camera_position_world - world_pos);
	float view_normal_alignment = abs(dot(view_ws, normal_ws));
	vec3 view_parallel = view_ws - normal_ws * dot(view_ws, normal_ws);
	float parallel_length = length(view_parallel);
	if (parallel_length <= 0.0001) {
		return world_pos;
	}
	float travel_m = (height - 0.5) * relief_range_m / max(view_normal_alignment, 0.15);
	return world_pos - normalize(view_parallel) * travel_m;
}

// -----------------------------------------------------------------------------
// Deep parallax (occlusion mapping)
//
// The march must never call terrain_parallax_height. That function resolves the
// full visible height: triplanar (three projections) over stochastic variation
// (three lattice copies) for five sources, so up to forty-five texture fetches
// per evaluation. Marching it costs hundreds of fetches per fragment and, with
// an unbounded loop, expands to a pipeline the driver cannot compile in
// reasonable time or memory.
//
// Instead every per-ray constant is resolved once into MTSMarchSource, so each
// march step costs one textureGrad per contributing height source:
//
//     full-quality height  ->  hoist projection axis, lattice descriptor,
//                              splat weights and gradients
//                          ->  flat 2D coord + constant per-step advance
//                          ->  one fetch per source per step
//
// The trip count is a compile-time constant so the loop is always bounded.
// -----------------------------------------------------------------------------

const int MTS_PARALLAX_MAX_STEPS = 16;
const int MTS_PARALLAX_REFINE_STEPS = 4;

// One height source pre-resolved into the flat texture space the march walks.
struct MTSMarchSource {
	vec2 coord;
	vec2 advance;
	vec2 grad_x;
	vec2 grad_y;
	float weight;
};

// Return a source that contributes nothing and is never sampled.
//
// A variant compiled for fewer layers has no uniforms for the layers it dropped,
// so those slots are filled with this instead. Zero weight makes
// mts_march_source_height return early, and the matching MTS_LAYER_COUNT guard in
// mts_march_height removes the call altogether, so this is only ever a
// placeholder that keeps one function signature across every variant.
MTSMarchSource mts_inert_march_source() {
	MTSMarchSource source;
	source.coord = vec2(0.0);
	source.advance = vec2(0.0);
	source.grad_x = vec2(0.0);
	source.grad_y = vec2(0.0);
	source.weight = 0.0;
	return source;
}

// Return the strongest of the three world projections for one face normal.
//
// A parallax ray stays inside a single face and travels only centimetres, so the
// triplanar blend cannot shift meaningfully along it. Marching the dominant axis
// alone is therefore visually identical to marching the blend at a third of the
// cost, and the final shaded sample still uses the full triplanar path.
int mts_dominant_projection_axis(vec3 world_normal) {
	vec3 weights = abs(normalize(world_normal));
	if (weights.x >= weights.y && weights.x >= weights.z) {
		return 0;
	}
	if (weights.y >= weights.z) {
		return 1;
	}
	return 2;
}

// Project one world point, or one world-space direction, onto a single axis.
//
// This is exactly the per-axis mapping sample_projected_fragment_raw uses. It
// carries no translation term, which is what allows a direction to be projected
// by the same call and the march to advance by a constant 2D step.
vec2 mts_march_coord(vec3 world_point, int axis, int quarter_turns) {
	if (axis == 0) {
		return rotate_quarter_turns(vec2(-world_point.z, world_point.y), quarter_turns);
	}
	if (axis == 1) {
		return rotate_quarter_turns(vec2(world_point.x, -world_point.z), quarter_turns);
	}
	return rotate_quarter_turns(vec2(world_point.x, world_point.y), quarter_turns);
}

// Resolve one height source into ray-constant march state.
//
// The lattice descriptor is hoisted from the ray origin and reused for the whole
// ray. Stochastic variation only changes across tile boundaries metres apart,
// while the ray spans centimetres, so holding one descriptor keeps the marched
// height field registered to the pattern that will actually be shaded. Gradients
// are derived from the caller's world derivatives rather than dFdx/dFdy here,
// because the march runs inside branchy control flow where derivatives are
// undefined.
MTSMarchSource mts_make_march_source(
	vec3 origin,
	vec3 step_world,
	vec3 world_ddx,
	vec3 world_ddy,
	int axis,
	int quarter_turns,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	float weight
) {
	MTSMarchSource source;
	source.weight = weight;
	vec2 period_m = safe_size(repeat_m);
	if (use_stochastic_tiling) {
		period_m *= max(mts_stochastic_scale, 0.0001);
	}
	source.coord = mts_march_coord(origin, axis, quarter_turns) / period_m;
	source.advance = mts_march_coord(step_world, axis, quarter_turns) / period_m;
	source.grad_x = mts_march_coord(world_ddx, axis, quarter_turns) / period_m;
	source.grad_y = mts_march_coord(world_ddy, axis, quarter_turns) / period_m;
#ifdef MTS_TEXTURE_VARIATION
	if (use_stochastic_tiling || use_random_rotation || use_random_mirroring) {
		vec2 id0;
		vec2 id1;
		vec2 id2;
		vec3 lattice_weights;
		variation_triangle(source.coord, id0, id1, id2, lattice_weights);
		// The strongest lattice copy carries the pattern a viewer actually reads.
		vec2 lattice_id = id0;
		if (lattice_weights.y > lattice_weights.x && lattice_weights.y >= lattice_weights.z) {
			lattice_id = id1;
		} else if (lattice_weights.z > lattice_weights.x && lattice_weights.z > lattice_weights.y) {
			lattice_id = id2;
		}
		vec2 varied_coord;
		int varied_turns;
		bool varied_mirror;
		texture_variation_descriptor(
			source.coord, lattice_id, use_stochastic_tiling, asset_seed,
			use_random_rotation, use_random_mirroring,
			varied_coord, varied_turns, varied_mirror
		);
		// The descriptor's phase shift applies to the point only; the advance and
		// gradients are directions and take just its rotation and mirror.
		source.coord = varied_coord;
		source.advance = texture_variation_direction(source.advance, varied_turns, varied_mirror);
		source.grad_x = texture_variation_direction(source.grad_x, varied_turns, varied_mirror);
		source.grad_y = texture_variation_direction(source.grad_y, varied_turns, varied_mirror);
	}
#endif
	return source;
}

// Resolve one placement-local shader decal into ray-constant march state.
//
// Unlike tiled terrain layers this coordinate is the asset's exact 0..1 footprint,
// so it needs neither triplanar projection nor stochastic repetition.
MTSMarchSource mts_make_shader_decal_source(
	vec3 origin,
	vec3 step_world,
	vec3 world_ddx,
	vec3 world_ddy
) {
	MTSMarchSource source;
	source.coord = shader_decal_uv_for_world_position(origin);
	source.advance = shader_decal_uv_for_world_direction(step_world);
	source.grad_x = shader_decal_uv_for_world_direction(world_ddx);
	source.grad_y = shader_decal_uv_for_world_direction(world_ddy);
	source.weight = (shader_decal_enabled && shader_decal_has_height) ? 1.0 : 0.0;
	return source;
}

// Sample one source's weighted height contribution at a fractional march step.
//
// A source with no painted weight is skipped outright, so the common case of one
// or two active layers costs one or two fetches per step rather than five.
float mts_march_source_height(sampler2D tex, MTSMarchSource source, float step_index) {
	if (source.weight <= 0.0005) {
		return 0.0;
	}
	return textureGrad(
		tex,
		source.coord + source.advance * step_index,
		source.grad_x,
		source.grad_y
	).r * source.weight;
}

// Resolve the blended march height at a fractional step along the ray.
//
// The weights are pre-normalised by the caller, so this returns the same 0..1
// height terrain_parallax_height would report, built from single lookups.
float mts_march_height(
	MTSMarchSource base_source,
	MTSMarchSource layer_0_source,
	MTSMarchSource layer_1_source,
	MTSMarchSource layer_2_source,
	MTSMarchSource layer_3_source,
	MTSMarchSource decal_source,
	float empty_terrain_height,
	float step_index
) {
	// Accumulated so a layer this variant did not compile leaves no dangling term.
	// Its source carries zero weight regardless, so the marched field matches the
	// full shader with that layer disabled.
	float terrain_height = empty_terrain_height
		+ mts_march_source_height(height_tex, base_source, step_index);
#if MTS_LAYER_COUNT > 0
	terrain_height += mts_march_source_height(material_layer_0_height_tex, layer_0_source, step_index);
#endif
#if MTS_LAYER_COUNT > 1
	terrain_height += mts_march_source_height(material_layer_1_height_tex, layer_1_source, step_index);
#endif
#if MTS_LAYER_COUNT > 2
	terrain_height += mts_march_source_height(material_layer_2_height_tex, layer_2_source, step_index);
#endif
#if MTS_LAYER_COUNT > 3
	terrain_height += mts_march_source_height(material_layer_3_height_tex, layer_3_source, step_index);
#endif
	if (decal_source.weight <= 0.0) {
		return terrain_height;
	}
	vec2 decal_coord = decal_source.coord + decal_source.advance * step_index;
	vec2 height_inset = 0.5 / max(
		vec2(textureSize(shader_decal_height_tex, 0)),
		vec2(1.0)
	);
	vec2 albedo_inset = 0.5 / max(
		vec2(textureSize(shader_decal_albedo_tex, 0)),
		vec2(1.0)
	);
	vec2 height_uv = clamp(decal_coord, height_inset, vec2(1.0) - height_inset);
	vec2 albedo_uv = clamp(decal_coord, albedo_inset, vec2(1.0) - albedo_inset);
	float decal_height = textureGrad(
		shader_decal_height_tex, height_uv, decal_source.grad_x, decal_source.grad_y
	).r;
	float decal_coverage = textureGrad(
		shader_decal_albedo_tex, albedo_uv, decal_source.grad_x, decal_source.grad_y
	).a * shader_decal_inside(decal_coord);
	return mix(terrain_height, decal_height, clamp(decal_coverage, 0.0, 1.0));
}

// Raymarch the visible painted height to its true intersection with the view ray.
//
// The wall or terrain surface is the minimum plane. The march begins at the
// virtual top of the outward relief volume, walks back toward that plane until it
// meets the height field, and then bisects the crossed interval.
vec3 godot_raymarched_parallax_sample_world_pos(vec3 world_pos, vec3 world_normal, vec4 painted_weights) {
	if (!terrain_triangle_instances) {
		return world_pos;
	}

	// Derivatives are only defined in uniform control flow. The one return above
	// branches on a uniform, so it is identical for every fragment in the draw and
	// safe to precede them; every return below this point is per-fragment, so no
	// derivative may be taken after one. They double as the march's gradients.
	vec3 world_ddx = dFdx(world_pos);
	vec3 world_ddy = dFdy(world_pos);
	float metres_per_pixel = max(max(length(world_ddx), length(world_ddy)), 0.000001);

	float base_weight;
	vec4 layer_weights;
	float total_weight;
	float source_short_edge_px;
	terrain_parallax_weights(painted_weights, base_weight, layer_weights, total_weight, source_short_edge_px);
	vec2 decal_origin_uv = shader_decal_uv_for_world_position(world_pos);
	vec2 decal_ddx = shader_decal_uv_for_world_direction(world_ddx);
	vec2 decal_ddy = shader_decal_uv_for_world_direction(world_ddy);
	vec3 decal_origin_height = sample_shader_decal_height(
		decal_origin_uv, decal_ddx, decal_ddy
	);
	if (total_weight <= 0.00001 && decal_origin_height.b <= 0.00001) {
		return world_pos;
	}
	float terrain_relief_range_m = source_short_edge_px * mts_height_metres_per_source_pixel;
	float decal_relief_range_m = decal_origin_height.g * mts_height_metres_per_source_pixel;
	float relief_range_m = mix(
		terrain_relief_range_m,
		decal_relief_range_m,
		decal_origin_height.b
	) * mts_parallax_master;
	if (relief_range_m <= 0.0) {
		return world_pos;
	}

	// Relief thinner than a pixel cannot be seen, so the march fades out and then
	// stops entirely as the board is zoomed away. This is the largest single cost
	// control: a zoomed-out board pays nothing for deep parallax. Measuring it in
	// pixels rather than metres keeps it correct for both orthographic and
	// perspective cameras without consulting the projection.
	float relief_pixels = relief_range_m / metres_per_pixel;
	float quality = smoothstep(1.0, 4.0, relief_pixels);
	if (quality <= 0.0) {
		return world_pos;
	}

	vec3 normal_ws = normalize(world_normal);
	vec3 view_ws = normalize(v_camera_position_world - world_pos);
	float view_normal_alignment = abs(dot(view_ws, normal_ws));
	vec3 view_parallel = view_ws - normal_ws * dot(view_ws, normal_ws);
	if (length(view_parallel) <= 0.0001) {
		return world_pos;
	}

	// The sweep reaches from the receiver plane to the virtual top of the outward
	// relief volume. Its clamped denominator prevents an unbounded grazing trace.
	vec3 sweep = view_parallel * relief_range_m / max(view_normal_alignment, 0.15);

	// A flatter view spreads the same depth range over a longer sweep and needs
	// more steps to avoid stair-stepping. Isometric floors sit near 0.5 alignment,
	// which lands in the middle of this range.
	int steps = int(clamp(
		ceil(mix(float(MTS_PARALLAX_MAX_STEPS), 6.0, view_normal_alignment) * quality),
		2.0,
		float(MTS_PARALLAX_MAX_STEPS)
	));
	vec3 ray_origin_world = world_pos + sweep;
	vec3 step_world = -sweep / float(steps);

	int axis = mts_dominant_projection_axis(normal_ws);
	int quarter_turns = surface_quarter_turns();
	float inverse_total_weight = total_weight > 0.00001 ? 1.0 / total_weight : 0.0;
	float empty_terrain_height = total_weight > 0.00001 ? 0.0 : 0.5;

	MTSMarchSource base_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, quarter_turns,
		surface_size_m, stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring,
		base_weight * inverse_total_weight
	);
	// A layer this variant did not compile has no uniforms to read, so it is given
	// an inert source instead. mts_march_height skips it on the same condition,
	// so the inert source is never sampled; it exists only to keep one signature.
#if MTS_LAYER_COUNT > 0
	MTSMarchSource layer_0_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, material_layer_quarter_turns(0),
		material_layer_0_repeat_m, material_layer_0_stochastic_tiling,
		material_layer_0_variation_asset_seed, material_layer_0_random_texture_rotation,
		material_layer_0_random_texture_mirroring,
		layer_weights.x * inverse_total_weight
	);
#else
	MTSMarchSource layer_0_source = mts_inert_march_source();
#endif
#if MTS_LAYER_COUNT > 1
	MTSMarchSource layer_1_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, material_layer_quarter_turns(1),
		material_layer_1_repeat_m, material_layer_1_stochastic_tiling,
		material_layer_1_variation_asset_seed, material_layer_1_random_texture_rotation,
		material_layer_1_random_texture_mirroring,
		layer_weights.y * inverse_total_weight
	);
#else
	MTSMarchSource layer_1_source = mts_inert_march_source();
#endif
#if MTS_LAYER_COUNT > 2
	MTSMarchSource layer_2_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, material_layer_quarter_turns(2),
		material_layer_2_repeat_m, material_layer_2_stochastic_tiling,
		material_layer_2_variation_asset_seed, material_layer_2_random_texture_rotation,
		material_layer_2_random_texture_mirroring,
		layer_weights.z * inverse_total_weight
	);
#else
	MTSMarchSource layer_2_source = mts_inert_march_source();
#endif
#if MTS_LAYER_COUNT > 3
	MTSMarchSource layer_3_source = mts_make_march_source(
		ray_origin_world, step_world, world_ddx, world_ddy, axis, material_layer_quarter_turns(3),
		material_layer_3_repeat_m, material_layer_3_stochastic_tiling,
		material_layer_3_variation_asset_seed, material_layer_3_random_texture_rotation,
		material_layer_3_random_texture_mirroring,
		layer_weights.w * inverse_total_weight
	);
#else
	MTSMarchSource layer_3_source = mts_inert_march_source();
#endif
	MTSMarchSource decal_source = mts_make_shader_decal_source(
		ray_origin_world, step_world, world_ddx, world_ddy
	);

	// Convert authored white-is-high height to depth measured from the virtual top,
	// then walk toward the receiver plane until the ray reaches that depth.
	float layer_depth = 1.0 / float(steps);
	float previous_index = 0.0;
	float resolved_index = float(steps);
	bool crossed = false;
	for (int i = 1; i <= MTS_PARALLAX_MAX_STEPS; i++) {
		if (i > steps) {
			break;
		}
		float index = float(i);
		float sampled_depth = 1.0 - mts_march_height(
			base_source, layer_0_source, layer_1_source, layer_2_source, layer_3_source,
			decal_source, empty_terrain_height, index
		);
		if (index * layer_depth >= sampled_depth) {
			resolved_index = index;
			crossed = true;
			break;
		}
		previous_index = index;
	}

	// Bisect the crossed interval so a hard edge resolves to a sharp contact
	// instead of the linear walk's visible stair step. Four halvings shrink the
	// residual error to a sixteenth of one step, which is below a pixel at every
	// zoom this fades out at.
	if (crossed) {
		float low_index = previous_index;
		float high_index = resolved_index;
		for (int refine = 0; refine < MTS_PARALLAX_REFINE_STEPS; refine++) {
			float mid_index = (low_index + high_index) * 0.5;
			float mid_depth = 1.0 - mts_march_height(
				base_source, layer_0_source, layer_1_source, layer_2_source, layer_3_source,
				decal_source, empty_terrain_height, mid_index
			);
			if (mid_index * layer_depth >= mid_depth) {
				high_index = mid_index;
			} else {
				low_index = mid_index;
			}
		}
		resolved_index = high_index;
	}

	// Scale the complete outward offset from the receiver plane so quality zero
	// returns exactly to canonical geometry without a zoom-distance pop.
	vec3 resolved_offset_world = sweep + step_world * resolved_index;
	return world_pos + resolved_offset_world * quality;
}

// Raymarching is the sole active parallax algorithm.
//
// The retired offset function remains above as dead reference code and is never
// selected by this shader.
vec3 parallax_sample_world_pos(vec3 world_pos, vec3 world_normal, vec4 painted_weights) {
	return godot_raymarched_parallax_sample_world_pos(world_pos, world_normal, painted_weights);
}

// Decode the two stored normal channels used by Godot's normal-map import path.
vec3 decode_sampled_normal(vec3 encoded) {
	vec2 xy = encoded.rg * 2.0 - 1.0;
	float z = sqrt(max(1.0 - dot(xy, xy), 0.0));
	return normalize(vec3(xy, z));
}

// Sample and reorient each varied normal copy before blending it in tangent space.
vec3 sample_surface_tangent_normal(
	sampler2D tex,
	vec2 coord,
	vec2 grad_x,
	vec2 grad_y,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring
) {
#ifdef MTS_TEXTURE_VARIATION
	if (!use_stochastic_tiling && !use_random_rotation && !use_random_mirroring) {
		return decode_sampled_normal(textureGrad(tex, coord, grad_x, grad_y).rgb);
	}
	vec2 id0;
	vec2 id1;
	vec2 id2;
	vec3 weights;
	variation_triangle(coord, id0, id1, id2, weights);
	vec2 coord0;
	vec2 coord1;
	vec2 coord2;
	int turns0;
	int turns1;
	int turns2;
	bool mirror0;
	bool mirror1;
	bool mirror2;
	texture_variation_descriptor(coord, id0, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord0, turns0, mirror0);
	texture_variation_descriptor(coord, id1, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord1, turns1, mirror1);
	texture_variation_descriptor(coord, id2, use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring, coord2, turns2, mirror2);
	vec3 normal0 = decode_sampled_normal(textureGrad(tex, coord0, texture_variation_direction(grad_x, turns0, mirror0), texture_variation_direction(grad_y, turns0, mirror0)).rgb);
	vec3 normal1 = decode_sampled_normal(textureGrad(tex, coord1, texture_variation_direction(grad_x, turns1, mirror1), texture_variation_direction(grad_y, turns1, mirror1)).rgb);
	vec3 normal2 = decode_sampled_normal(textureGrad(tex, coord2, texture_variation_direction(grad_x, turns2, mirror2), texture_variation_direction(grad_y, turns2, mirror2)).rgb);
	normal0.xy = texture_variation_normal_xy(normal0.xy, turns0, mirror0);
	normal1.xy = texture_variation_normal_xy(normal1.xy, turns1, mirror1);
	normal2.xy = texture_variation_normal_xy(normal2.xy, turns2, mirror2);
	return normalize(normal0 * weights.x + normal1 * weights.y + normal2 * weights.z);
#else
	// No-variation variant: the lattice path is not compiled, so no per-copy
	// normal reorientation is needed either.
	return decode_sampled_normal(textureGrad(tex, coord, grad_x, grad_y).rgb);
#endif
}

// Reorient three globally projected normal samples into the terrain surface frame.
vec3 sample_projected_tangent_normal_oriented(
	sampler2D tex,
	vec2 planar_coord,
	vec2 planar_grad_x,
	vec2 planar_grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec3 surface_tangent,
	vec3 surface_binormal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	int orientation_quarters
) {
	if (!terrain_triangle_instances) {
		return sample_surface_tangent_normal(
			tex, planar_coord, planar_grad_x, planar_grad_y,
			use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring
		);
	}
	vec3 geometry_normal = normalize(world_normal);
	vec2 period_m = safe_size(repeat_m);
	if (use_stochastic_tiling) {
		period_m *= max(mts_stochastic_scale, 0.0001);
	}
	int steps = orientation_quarters & 3;
	vec2 coord_x = rotate_quarter_turns(vec2(-world_pos.z, world_pos.y), steps) / period_m;
	vec2 coord_y = rotate_quarter_turns(vec2(world_pos.x, -world_pos.z), steps) / period_m;
	vec2 coord_z = rotate_quarter_turns(vec2(world_pos.x, world_pos.y), steps) / period_m;
	int normal_steps = (4 - steps) & 3;
	vec3 weights = world_projection_weights(geometry_normal);
	float sign_x = geometry_normal.x < 0.0 ? -1.0 : 1.0;
	float sign_y = geometry_normal.y < 0.0 ? -1.0 : 1.0;
	float sign_z = geometry_normal.z < 0.0 ? -1.0 : 1.0;
	// Match the scalar-channel fast path: an effectively cardinal projection
	// decodes and reorients exactly one normal sample.
	if (weights.x >= 0.999) {
		vec3 normal_x = sample_surface_tangent_normal(tex, coord_x, dFdx(coord_x), dFdy(coord_x), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
		normal_x.xy = rotate_quarter_turns(normal_x.xy, normal_steps);
		vec3 sampled_world_normal = normalize(vec3(normal_x.z * sign_x, normal_x.y, -normal_x.x));
		return normalize(vec3(
			dot(sampled_world_normal, normalize(surface_tangent)),
			dot(sampled_world_normal, normalize(surface_binormal)),
			dot(sampled_world_normal, geometry_normal)
		));
	}
	if (weights.y >= 0.999) {
		vec3 normal_y = sample_surface_tangent_normal(tex, coord_y, dFdx(coord_y), dFdy(coord_y), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
		normal_y.xy = rotate_quarter_turns(normal_y.xy, normal_steps);
		vec3 sampled_world_normal = normalize(vec3(normal_y.x, normal_y.z * sign_y, -normal_y.y));
		return normalize(vec3(
			dot(sampled_world_normal, normalize(surface_tangent)),
			dot(sampled_world_normal, normalize(surface_binormal)),
			dot(sampled_world_normal, geometry_normal)
		));
	}
	if (weights.z >= 0.999) {
		vec3 normal_z = sample_surface_tangent_normal(tex, coord_z, dFdx(coord_z), dFdy(coord_z), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
		normal_z.xy = rotate_quarter_turns(normal_z.xy, normal_steps);
		vec3 sampled_world_normal = normalize(vec3(normal_z.x, normal_z.y, normal_z.z * sign_z));
		return normalize(vec3(
			dot(sampled_world_normal, normalize(surface_tangent)),
			dot(sampled_world_normal, normalize(surface_binormal)),
			dot(sampled_world_normal, geometry_normal)
		));
	}
	vec3 normal_x = sample_surface_tangent_normal(tex, coord_x, dFdx(coord_x), dFdy(coord_x), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	vec3 normal_y = sample_surface_tangent_normal(tex, coord_y, dFdx(coord_y), dFdy(coord_y), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	vec3 normal_z = sample_surface_tangent_normal(tex, coord_z, dFdx(coord_z), dFdy(coord_z), use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring);
	normal_x.xy = rotate_quarter_turns(normal_x.xy, normal_steps);
	normal_y.xy = rotate_quarter_turns(normal_y.xy, normal_steps);
	normal_z.xy = rotate_quarter_turns(normal_z.xy, normal_steps);
	vec3 world_normal_x = normalize(vec3(normal_x.z * sign_x, normal_x.y, -normal_x.x));
	vec3 world_normal_y = normalize(vec3(normal_y.x, normal_y.z * sign_y, -normal_y.y));
	vec3 world_normal_z = normalize(vec3(normal_z.x, normal_z.y, normal_z.z * sign_z));
	vec3 sampled_world_normal = normalize(
		world_normal_x * weights.x + world_normal_y * weights.y + world_normal_z * weights.z
	);
	return normalize(vec3(
		dot(sampled_world_normal, normalize(surface_tangent)),
		dot(sampled_world_normal, normalize(surface_binormal)),
		dot(sampled_world_normal, geometry_normal)
	));
}

// Decode the base coat normal through its authored regular terrain-paint orientation.
vec3 sample_projected_tangent_normal(
	sampler2D tex,
	vec2 planar_coord,
	vec2 planar_grad_x,
	vec2 planar_grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec3 surface_tangent,
	vec3 surface_binormal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring
) {
	return sample_projected_tangent_normal_oriented(
		tex, planar_coord, planar_grad_x, planar_grad_y,
		world_pos, world_normal, surface_tangent, surface_binormal,
		repeat_m, use_stochastic_tiling, asset_seed,
		use_random_rotation, use_random_mirroring,
		surface_quarter_turns()
	);
}


vec2 world_rect_uv(vec2 world_xz, vec4 rect) {
	vec2 size_m = max(abs(rect.zw), vec2(0.0001));
	return (world_xz - rect.xy) / size_m;
}

bool uv_inside_01(vec2 uv) {
	return uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0;
}

vec4 sample_interaction_fragment(vec2 world_xz) {
	if (!mts_interaction_enabled) {
		return vec4(0.0);
	}
	vec2 uv = world_rect_uv(world_xz, g_interaction_rect);
	if (!uv_inside_01(uv)) {
		return vec4(0.0);
	}
	return texture(g_interaction_tex, uv);
}

// -----------------------------------------------------------------------------
// Material-layer sampling and mask composition
// -----------------------------------------------------------------------------

struct MaterialLayerAddressing {
	bool one_shot;
	int quarter_turns;
	vec3 axis_u;
	vec3 axis_v;
	vec3 normal;
	vec3 palette_scale;
	vec3 palette_offset;
};

struct MaterialLayerSample {
	vec3 albedo;
	vec3 tangent_normal;
	vec3 orm;
	float height;
	vec3 emission;
	float specular;
	// How much of this layer's ART exists at this fragment, straight from the
	// layer albedo's own alpha.
	//
	// This is INDEPENDENT of the painted mask weight: the mask says where the
	// user brushed the layer, this says where the image has pixels at all. They
	// are multiplied at composition time. Without it a background-removed PNG
	// composited its transparent region as opaque black at full mask weight,
	// which is what stamped a black rectangle around cut-out art.
	float coverage;
};

// Return the neutral addressing state used by every repeating splat layer.
MaterialLayerAddressing tiled_material_layer_addressing(int material_slot) {
	MaterialLayerAddressing addressing;
	addressing.one_shot = false;
	addressing.quarter_turns = material_layer_quarter_turns(material_slot);
	addressing.axis_u = vec3(1.0, 0.0, 0.0);
	addressing.axis_v = vec3(0.0, 1.0, 0.0);
	addressing.normal = vec3(0.0, 0.0, 1.0);
	addressing.palette_scale = vec3(1.0);
	addressing.palette_offset = vec3(0.0);
	return addressing;
}

// Return placement-local addressing for the one-shot shader-decal layer.
MaterialLayerAddressing shader_decal_material_layer_addressing() {
	MaterialLayerAddressing addressing;
	addressing.one_shot = true;
	addressing.quarter_turns = 0;
	addressing.axis_u = normalize(shader_decal_axis_u);
	addressing.axis_v = normalize(shader_decal_axis_v);
	addressing.normal = normalize(shader_decal_normal);
	addressing.palette_scale = shader_decal_palette_scale;
	addressing.palette_offset = shader_decal_palette_offset;
	return addressing;
}

// Sample either the existing repeating projection or one exact non-repeating UV.
vec4 sample_material_layer_raw(
	sampler2D tex,
	vec2 coord,
	vec2 grad_x,
	vec2 grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	MaterialLayerAddressing addressing
) {
	if (addressing.one_shot) {
		vec2 texel_inset = 0.5 / max(vec2(textureSize(tex, 0)), vec2(1.0));
		vec2 bounded_uv = clamp(coord, texel_inset, vec2(1.0) - texel_inset);
		return textureGrad(tex, bounded_uv, grad_x, grad_y);
	}
	return sample_projected_fragment_oriented(
		tex, coord, grad_x, grad_y, world_pos, world_normal, repeat_m,
		use_stochastic_tiling, asset_seed, use_random_rotation, use_random_mirroring,
		addressing.quarter_turns
	);
}

// Decode a normal through the same addressing choice and return receiver tangent space.
vec3 sample_material_layer_tangent_normal(
	sampler2D tex,
	vec2 coord,
	vec2 grad_x,
	vec2 grad_y,
	vec3 world_pos,
	vec3 world_normal,
	vec3 tangent_world,
	vec3 binormal_world,
	vec2 repeat_m,
	bool use_stochastic_tiling,
	float asset_seed,
	bool use_random_rotation,
	bool use_random_mirroring,
	MaterialLayerAddressing addressing
) {
	if (!addressing.one_shot) {
		return sample_projected_tangent_normal_oriented(
			tex, coord, grad_x, grad_y, world_pos, world_normal,
			tangent_world, binormal_world, repeat_m,
			use_stochastic_tiling, asset_seed,
			use_random_rotation, use_random_mirroring,
			addressing.quarter_turns
		);
	}
	vec2 texel_inset = 0.5 / max(vec2(textureSize(tex, 0)), vec2(1.0));
	vec2 bounded_uv = clamp(coord, texel_inset, vec2(1.0) - texel_inset);
	// Use the same RG decode as every existing material layer. Godot's imported
	// normal path reconstructs positive Z; treating stored B as authoritative can
	// turn a valid normal inward and blacken the entire stamped region.
	vec3 sampled = decode_sampled_normal(textureGrad(
		tex, bounded_uv, grad_x, grad_y
	).rgb);
	vec3 receiver_normal = normalize(world_normal);
	// UV V runs opposite the placement basis Y, matching the 0.5-local_y mapping.
	// The receiving terrain geometry owns outward Z; placement contributes only
	// the image's in-plane U/V orientation.
	vec3 sampled_world = normalize(
		addressing.axis_u * sampled.x
		- addressing.axis_v * sampled.y
		+ receiver_normal * sampled.z
	);
	return normalize(vec3(
		dot(sampled_world, tangent_world),
		dot(sampled_world, binormal_world),
		dot(sampled_world, receiver_normal)
	));
}

// Return a layer sample that contributes nothing to the composite.
//
// A variant compiled for fewer layers has no uniforms for the layers it dropped,
// so those slots take this instead. Zero coverage and zero painted weight both
// exclude it at composition time, so it cannot tint, light, or occlude anything.
MaterialLayerSample mts_inert_material_layer() {
	MaterialLayerSample layer;
	layer.albedo = vec3(0.0);
	layer.tangent_normal = vec3(0.0, 0.0, 1.0);
	layer.orm = vec3(1.0, 1.0, 0.0);
	layer.height = 0.0;
	layer.emission = vec3(0.0);
	layer.specular = 0.5;
	layer.coverage = 0.0;
	return layer;
}

float material_component(vec4 value, int component) {
	if (component == 0) {
		return value.r;
	}
	if (component == 1) {
		return value.g;
	}
	if (component == 2) {
		return value.b;
	}
	return value.a;
}

int material_int_component(ivec4 value, int component) {
	if (component == 0) {
		return value.r;
	}
	if (component == 1) {
		return value.g;
	}
	if (component == 2) {
		return value.b;
	}
	return value.a;
}

// Return whether a layer can affect this fragment before any texture fetches.
bool material_layer_is_active(bool enabled, bool brush_authored, float painted_weight) {
	return enabled && (!brush_authored || painted_weight > MTS_PAINT_WEIGHT_THRESHOLD);
}

// Test one packed mask-source dependency written by SurfaceMaterialFactory.
bool material_has_dependency(int dependencies, int source) {
	return (dependencies & (1 << source)) != 0;
}

// Return whether one active layer is guaranteed to replace its share with opaque art.
bool material_layer_guarantees_opaque_coat(
	bool brush_authored,
	bool albedo_has_transparency,
	float opacity,
	float height_blend,
	int mask_count
) {
	return (
		brush_authored
		&& !albedo_has_transparency
		&& opacity >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD
		&& height_blend <= MTS_PAINT_WEIGHT_THRESHOLD
		&& mask_count <= 1
	);
}

// Return whether the base coat can contribute visible PBR channels at this fragment.
//
// Normalized splat can omit the base only when painted coverage is full and every
// active layer is an opaque, unconstrained coat. Ordered layering can omit it when
// any such layer fully replaces everything beneath it. Diagnostics deliberately
// retain the base because they inspect the pre-composite material channels.
bool material_base_coat_needed(vec4 painted_weights) {
	if (!terrain_triangle_instances || !material_blend_enabled) {
		return true;
	}
	if (material_debug_view != 0 || material_mask_preview_enabled) {
		return true;
	}
	if (material_blend_mode == 1) {
		if (dot(painted_weights, vec4(1.0)) < 1.0 - MTS_PAINT_WEIGHT_THRESHOLD) {
			return true;
		}
		bool all_active_layers_are_opaque = true;
#if MTS_LAYER_COUNT > 0
		if (material_layer_is_active(material_layer_0_enabled, material_layer_0_brush_authored, painted_weights.r)) {
			all_active_layers_are_opaque = all_active_layers_are_opaque && material_layer_guarantees_opaque_coat(material_layer_0_brush_authored, material_layer_0_albedo_has_transparency, material_layer_0_opacity, material_layer_0_height_blend, material_layer_0_mask_count);
		}
#endif
#if MTS_LAYER_COUNT > 1
		if (material_layer_is_active(material_layer_1_enabled, material_layer_1_brush_authored, painted_weights.g)) {
			all_active_layers_are_opaque = all_active_layers_are_opaque && material_layer_guarantees_opaque_coat(material_layer_1_brush_authored, material_layer_1_albedo_has_transparency, material_layer_1_opacity, material_layer_1_height_blend, material_layer_1_mask_count);
		}
#endif
#if MTS_LAYER_COUNT > 2
		if (material_layer_is_active(material_layer_2_enabled, material_layer_2_brush_authored, painted_weights.b)) {
			all_active_layers_are_opaque = all_active_layers_are_opaque && material_layer_guarantees_opaque_coat(material_layer_2_brush_authored, material_layer_2_albedo_has_transparency, material_layer_2_opacity, material_layer_2_height_blend, material_layer_2_mask_count);
		}
#endif
#if MTS_LAYER_COUNT > 3
		if (material_layer_is_active(material_layer_3_enabled, material_layer_3_brush_authored, painted_weights.a)) {
			all_active_layers_are_opaque = all_active_layers_are_opaque && material_layer_guarantees_opaque_coat(material_layer_3_brush_authored, material_layer_3_albedo_has_transparency, material_layer_3_opacity, material_layer_3_height_blend, material_layer_3_mask_count);
		}
#endif
		return !all_active_layers_are_opaque;
	}
	bool has_full_opaque_layer = false;
#if MTS_LAYER_COUNT > 0
	has_full_opaque_layer = has_full_opaque_layer || (painted_weights.r >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD && material_layer_guarantees_opaque_coat(material_layer_0_brush_authored, material_layer_0_albedo_has_transparency, material_layer_0_opacity, material_layer_0_height_blend, material_layer_0_mask_count));
#endif
#if MTS_LAYER_COUNT > 1
	has_full_opaque_layer = has_full_opaque_layer || (painted_weights.g >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD && material_layer_guarantees_opaque_coat(material_layer_1_brush_authored, material_layer_1_albedo_has_transparency, material_layer_1_opacity, material_layer_1_height_blend, material_layer_1_mask_count));
#endif
#if MTS_LAYER_COUNT > 2
	has_full_opaque_layer = has_full_opaque_layer || (painted_weights.b >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD && material_layer_guarantees_opaque_coat(material_layer_2_brush_authored, material_layer_2_albedo_has_transparency, material_layer_2_opacity, material_layer_2_height_blend, material_layer_2_mask_count));
#endif
#if MTS_LAYER_COUNT > 3
	has_full_opaque_layer = has_full_opaque_layer || (painted_weights.a >= 1.0 - MTS_PAINT_WEIGHT_THRESHOLD && material_layer_guarantees_opaque_coat(material_layer_3_brush_authored, material_layer_3_albedo_has_transparency, material_layer_3_opacity, material_layer_3_height_blend, material_layer_3_mask_count));
#endif
	return !has_full_opaque_layer;
}

// Return whether any active mask at this fragment consumes one base/world source.
bool material_base_source_needed(vec4 painted_weights, int source) {
	if (material_mask_preview_enabled) {
		return true;
	}
	bool needed = false;
#if MTS_LAYER_COUNT > 0
	needed = needed || (material_layer_is_active(material_layer_0_enabled, material_layer_0_brush_authored, painted_weights.r) && material_has_dependency(material_layer_0_mask_dependencies, source));
#endif
#if MTS_LAYER_COUNT > 1
	needed = needed || (material_layer_is_active(material_layer_1_enabled, material_layer_1_brush_authored, painted_weights.g) && material_has_dependency(material_layer_1_mask_dependencies, source));
#endif
#if MTS_LAYER_COUNT > 2
	needed = needed || (material_layer_is_active(material_layer_2_enabled, material_layer_2_brush_authored, painted_weights.b) && material_has_dependency(material_layer_2_mask_dependencies, source));
#endif
#if MTS_LAYER_COUNT > 3
	needed = needed || (material_layer_is_active(material_layer_3_enabled, material_layer_3_brush_authored, painted_weights.a) && material_has_dependency(material_layer_3_mask_dependencies, source));
#endif
	return needed;
}

// Return whether final mask/height blending needs a second base-height lookup.
bool material_base_height_needed(vec4 painted_weights) {
	if (!has_height) {
		return false;
	}
	if (material_debug_view == 6 || material_mask_preview_enabled || material_base_source_needed(painted_weights, 1)) {
		return true;
	}
	bool needed = false;
#if MTS_LAYER_COUNT > 0
	needed = needed || (material_layer_is_active(material_layer_0_enabled, material_layer_0_brush_authored, painted_weights.r) && material_layer_0_has_height && material_layer_0_height_blend > MTS_PAINT_WEIGHT_THRESHOLD);
#endif
#if MTS_LAYER_COUNT > 1
	needed = needed || (material_layer_is_active(material_layer_1_enabled, material_layer_1_brush_authored, painted_weights.g) && material_layer_1_has_height && material_layer_1_height_blend > MTS_PAINT_WEIGHT_THRESHOLD);
#endif
#if MTS_LAYER_COUNT > 2
	needed = needed || (material_layer_is_active(material_layer_2_enabled, material_layer_2_brush_authored, painted_weights.b) && material_layer_2_has_height && material_layer_2_height_blend > MTS_PAINT_WEIGHT_THRESHOLD);
#endif
#if MTS_LAYER_COUNT > 3
	needed = needed || (material_layer_is_active(material_layer_3_enabled, material_layer_3_brush_authored, painted_weights.a) && material_layer_3_has_height && material_layer_3_height_blend > MTS_PAINT_WEIGHT_THRESHOLD);
#endif
	return needed;
}

float material_normalized_range(float value, vec2 value_range) {
	float width = max(value_range.y - value_range.x, 0.000001);
	return clamp((value - value_range.x) / width, 0.0, 1.0);
}

// Interpolate hashed lattice values so the mask varies continuously across world space.
float material_value_noise(vec2 point, float seed) {
	vec2 cell = floor(point);
	vec2 fraction = fract(point);
	vec2 blend = fraction * fraction * (3.0 - 2.0 * fraction);
	float value_00 = hash12(cell, seed);
	float value_10 = hash12(cell + vec2(1.0, 0.0), seed);
	float value_01 = hash12(cell + vec2(0.0, 1.0), seed);
	float value_11 = hash12(cell + vec2(1.0, 1.0), seed);
	return mix(mix(value_00, value_10, blend.x), mix(value_01, value_11, blend.x), blend.y);
}

// Sum four rotated octaves to produce broad, non-grid-aligned smooth variation.
float material_smooth_noise(vec2 world_xz, float scale_m, float seed) {
	vec2 point = world_xz / max(scale_m, 0.01);
	float value = 0.0;
	float amplitude = 0.5333333;
	float total = 0.0;
	for (int octave = 0; octave < 4; octave++) {
		value += material_value_noise(point, seed + float(octave) * 31.7) * amplitude;
		total += amplitude;
		point = vec2(point.x * 0.6 + point.y * 0.8, -point.x * 0.8 + point.y * 0.6) * 2.03 + vec2(11.7, -9.2);
		amplitude *= 0.5;
	}
	return value / max(total, 0.00001);
}

// Fold smooth noise around its midpoint to form sharper branching ridges.
float material_ridged_noise(vec2 world_xz, float scale_m, float seed) {
	float ridge = 1.0 - abs(material_smooth_noise(world_xz, scale_m, seed) * 2.0 - 1.0);
	return ridge * ridge;
}

// Measure distance to seeded cell points for rounded patches and irregular borders.
float material_cellular_noise(vec2 world_xz, float scale_m, float seed) {
	vec2 point = world_xz / max(scale_m, 0.01);
	vec2 base_cell = floor(point);
	float nearest_squared = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = base_cell + vec2(float(x), float(y));
			vec2 feature = cell + hash22(cell, seed);
			vec2 delta = feature - point;
			nearest_squared = min(nearest_squared, dot(delta, delta));
		}
	}
	return clamp(sqrt(nearest_squared) * 1.41421356, 0.0, 1.0);
}

// Warp world-space stripes with smooth noise while keeping their direction explicit.
float material_directional_bands(vec2 world_xz, float scale_m, float seed, float angle_degrees) {
	float angle = radians(angle_degrees);
	vec2 axis = vec2(cos(angle), sin(angle));
	float warp = material_smooth_noise(world_xz, scale_m * 3.0, seed + 47.0) - 0.5;
	float phase = dot(world_xz, axis) / max(scale_m, 0.01) + warp * 0.65 + seed * 0.013;
	return sin(phase * TAU) * 0.5 + 0.5;
}

// Resolve one explicit material-mask source without substituting another algorithm.
float material_source_value(
	int source,
	int channel,
	vec4 painted_weights,
	vec4 material_id_value,
	float base_height,
	float base_ao,
	float base_roughness,
	float base_metallic,
	float base_luminance,
	float world_height,
	float elevation,
	float surface_up,
	vec2 local_uv,
	float contact,
	vec2 world_xz,
	float noise_scale,
	float noise_seed,
	float noise_angle_degrees
) {
	if (source == 0) {
		return material_component(painted_weights, channel);
	}
	if (source == 1) {
		return base_height;
	}
	// Legacy cavity/curvature mask recipes now read their baked ORM channels.
	// The runtime cannot recover the pre-bake derivative fields independently.
	if (source == 2) {
		return base_ao;
	}
	if (source == 3) {
		return base_roughness;
	}
	if (source == 4) {
		return base_ao;
	}
	if (source == 5) {
		return base_roughness;
	}
	if (source == 6) {
		return base_metallic;
	}
	if (source == 7) {
		return base_luminance;
	}
	if (source == 8) {
		return material_component(material_id_value, channel);
	}
	if (source == 9) {
		return world_height;
	}
	if (source == 10) {
		return elevation;
	}
	if (source == 11) {
		return surface_up;
	}
	if (source == 12) {
		return 1.0 - surface_up;
	}
	if (source == 13) {
		return 1.0 - clamp(local_uv.y, 0.0, 1.0);
	}
	if (source == 14) {
		return clamp(local_uv.y, 0.0, 1.0);
	}
	if (source == 15) {
		return contact;
	}
	if (source == 16) {
		return material_smooth_noise(world_xz, noise_scale, noise_seed);
	}
	if (source == 17) {
		return material_ridged_noise(world_xz, noise_scale, noise_seed);
	}
	if (source == 18) {
		return material_cellular_noise(world_xz, noise_scale, noise_seed);
	}
	return material_directional_bands(world_xz, noise_scale, noise_seed, noise_angle_degrees);
}

float material_range_mask(float value, float low, float high, float softness) {
	float minimum_value = min(low, high);
	float maximum_value = max(low, high);
	float edge = max(softness, 0.00001);
	float lower = minimum_value <= 0.0
		? 1.0
		: smoothstep(minimum_value - edge, minimum_value + edge, value);
	float upper = maximum_value >= 1.0
		? 1.0
		: 1.0 - smoothstep(maximum_value - edge, maximum_value + edge, value);
	return clamp(lower * upper, 0.0, 1.0);
}

// Rec. 709 luma, shared by the base coat and by every painted layer so the
// Albedo mask source cannot mean two different things at two call sites.
const vec3 MTS_LUMINANCE_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);

// The mask inputs describing the surface a layer is painted ONTO: the base coat
// plus every other layer already painted at this texel.
//
// Cavity and curvature recipes consume the AO/roughness values into which those
// analyses were baked. Material ID remains base-coat-only because layers carry
// no equivalent channel.
struct MaterialSurfaceBeneath {
	float height;
	float ao;
	float roughness;
	float metallic;
	float luminance;
};

// Return one channel of the surface beneath a slot, given that slot's own paint
// already removed from the weights.
//
// The base coat occupies whatever coverage the painted layers leave, which is the
// same remainder the normalized composite computes further down. A face whose base
// coat has been fully painted over therefore contributes none of it here, which is
// the entire point: the mask reads what is actually on the square.
float material_channel_beneath(
	vec4 layer_channel,
	vec4 present_weights,
	float base_channel
) {
	float present_total = dot(present_weights, vec4(1.0));
	float base_weight = max(1.0 - present_total, 0.0);
	return (base_channel * base_weight + dot(layer_channel, present_weights))
		/ max(base_weight + present_total, 0.0001);
}

// Resolve every composite-able mask input for one slot in a single pass.
//
// Weighting the lower layers by authored paint x art coverage -- rather than by each
// lower layer's own resolved mask -- is what keeps this non-circular AND independent
// of slot order: every slot excludes only itself and includes all others equally. So a
// layer masks on "where the layers under me were brushed and have pixels", not on
// "what those layers' masks finally let through". Making that exact would require
// evaluating masks in slot order, and slot order is allocated per face rather than
// authored, so it would make the same two materials stack differently on neighbouring
// tiles for reasons nothing in the UI shows.
MaterialSurfaceBeneath material_surface_beneath(
	int slot,
	vec4 layer_presence,
	vec4 layer_height_channel,
	vec4 layer_ao_channel,
	vec4 layer_roughness_channel,
	vec4 layer_metallic_channel,
	vec4 layer_luminance_channel,
	float base_height,
	float base_ao,
	float base_roughness,
	float base_metallic,
	float base_luminance
) {
	// Slot -1 excludes nothing, which is exactly what the preview needs for a palette
	// entry this face does not carry yet: it would land on top of everything present.
	vec4 others = layer_presence * vec4(
		slot == 0 ? 0.0 : 1.0,
		slot == 1 ? 0.0 : 1.0,
		slot == 2 ? 0.0 : 1.0,
		slot == 3 ? 0.0 : 1.0
	);
	MaterialSurfaceBeneath result;
	result.height = material_channel_beneath(layer_height_channel, others, base_height);
	result.ao = material_channel_beneath(layer_ao_channel, others, base_ao);
	result.roughness = material_channel_beneath(layer_roughness_channel, others, base_roughness);
	result.metallic = material_channel_beneath(layer_metallic_channel, others, base_metallic);
	result.luminance = material_channel_beneath(layer_luminance_channel, others, base_luminance);
	return result;
}

// Evaluate one material's ordered mask constraints with an explicit paint-coverage gate.
//
// Real brush layers apply their authored splat weight, while the reach preview disables
// that gate but still skips rule zero because it remains the brush's structural rule.
vec2 material_layer_masks(
	int count,
	ivec4 sources,
	ivec4 combines,
	ivec4 channels,
	ivec4 inversions,
	vec4 lows,
	vec4 highs,
	vec4 softness,
	vec4 strengths,
	vec4 noise_scales,
	vec4 noise_seeds,
	vec4 noise_angles,
	int layer_index,
	bool brush_authored,
	bool apply_painted_gate,
	vec4 painted_weights,
	ivec4 painted_channel_available,
	vec4 material_id_value,
	float base_height,
	float base_ao,
	float base_roughness,
	float base_metallic,
	float base_luminance,
	float world_height,
	float elevation,
	float surface_up,
	vec2 local_uv,
	float contact,
	vec2 world_xz
) {
	bool painted_gate_enabled = brush_authored && apply_painted_gate;
	float painted_gate = painted_gate_enabled
		? material_component(painted_weights, layer_index)
		: 1.0;
	// A brush layer absent from this texel cannot be revived by any later mask
	// operation, so avoid its complete rule stack here.
	if (painted_gate_enabled && painted_gate <= MTS_PAINT_WEIGHT_THRESHOLD) {
		return vec2(0.0);
	}
	float result = 1.0;
	for (int rule_index = 0; rule_index < 4; rule_index++) {
		// Rule zero records the brush layer's structural channel assignment. The
		// exact splat weight is applied after every optional constraint so no
		// combine operation can create coverage outside authored brush pixels.
		if (rule_index >= count || (brush_authored && rule_index == 0)) {
			continue;
		}
		int source = material_int_component(sources, rule_index);
		int channel = material_int_component(channels, rule_index);
		float source_value = material_source_value(
			source,
			channel,
			painted_weights,
			material_id_value,
			base_height,
			base_ao,
			base_roughness,
			base_metallic,
			base_luminance,
			world_height,
			elevation,
			surface_up,
			local_uv,
			contact,
			world_xz,
			material_component(noise_scales, rule_index),
			material_component(noise_seeds, rule_index),
			material_component(noise_angles, rule_index)
		);
		// A referenced palette entry absent from this face has exactly zero
		// painted weight; preview availability records that fact explicitly.
		if (
			source == 0
			&& material_int_component(painted_channel_available, rule_index) == 0
		) {
			source_value = 0.0;
		}
		float rule = material_range_mask(
			source_value,
			material_component(lows, rule_index),
			material_component(highs, rule_index),
			material_component(softness, rule_index)
		);
		if (material_int_component(inversions, rule_index) != 0) {
			rule = 1.0 - rule;
		}
		float strength = clamp(material_component(strengths, rule_index), 0.0, 1.0);
		int combine = material_int_component(combines, rule_index);
		if (combine == 0) {
			result *= mix(1.0, rule, strength);
		} else if (combine == 1) {
			result += rule * strength;
		} else if (combine == 2) {
			result -= rule * strength;
		} else if (combine == 3) {
			result = max(result, rule * strength);
		} else {
			result = min(result, mix(1.0, rule, strength));
		}
	}
	float constraint_mask = clamp(result, 0.0, 1.0);
	return vec2(constraint_mask * painted_gate, constraint_mask);
}

MaterialLayerSample sample_material_layer(
	bool enabled,
	vec2 metric_uv,
	// Resolved once by fragment() and shared by every channel this layer samples.
	vec3 material_world_pos,
	MaterialLayerAddressing addressing,
	sampler2D albedo_texture,
	sampler2D normal_texture,
	sampler2D orm_texture,
	sampler2D height_texture,
	sampler2D emission_texture,
	sampler2D detail_albedo_texture,
	bool has_layer_normal,
	bool has_layer_height,
	bool has_layer_emission,
	bool has_layer_orm,
	bool has_layer_detail_albedo,
	float layer_albedo_strength,
	vec4 layer_tint_color,
	float layer_tint_strength,
	float layer_normal_strength,
	float layer_ao_strength,
	float layer_roughness_strength,
	float layer_metallic_strength,
	float layer_roughness_bias,
	float layer_metallic_bias,
	float layer_emission_strength,
	float layer_specular_strength,
	vec2 repeat_m,
	bool layer_stochastic_tiling,
	float layer_variation_asset_seed,
	bool layer_random_texture_rotation,
	bool layer_random_texture_mirroring
) {
	MaterialLayerSample layer;
	layer.albedo = vec3(1.0);
	layer.tangent_normal = vec3(0.0, 0.0, 1.0);
	layer.orm = vec3(1.0, 1.0, 0.0);
	layer.height = 0.5;
	layer.emission = vec3(0.0);
	layer.specular = 0.5;
	// Fully covering by default, so a layer with no albedo texture keeps behaving
	// exactly as it did before coverage existed.
	layer.coverage = 1.0;
	if (!enabled) {
		return layer;
	}

	vec2 overlay_coord = addressing.one_shot
		? shader_decal_uv_for_world_position(material_world_pos)
		: metric_uv * safe_size(surface_size_m) / safe_size(repeat_m);
	vec2 overlay_grad_x = dFdx(overlay_coord);
	vec2 overlay_grad_y = dFdy(overlay_coord);
	// Sampled as vec4: the alpha is this layer's own coverage and is carried
	// through to composition instead of being dropped with the .rgb swizzle.
	vec4 raw_albedo_sample = sample_material_layer_raw(
		albedo_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
		material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
	);
	layer.coverage = clamp(raw_albedo_sample.a, 0.0, 1.0);
	if (addressing.one_shot) {
		layer.coverage *= shader_decal_inside(overlay_coord);
	}
	layer.albedo = mix(vec3(1.0), raw_albedo_sample.rgb, clamp(layer_albedo_strength, 0.0, 1.0));
	// Strength blends the multiplier from neutral white to the asset's exact tint.
	layer.albedo *= mix(vec3(1.0), layer_tint_color.rgb, clamp(layer_tint_strength, 0.0, 1.0));
	layer.albedo = layer.albedo * addressing.palette_scale + addressing.palette_offset;
	// Transparent art contributes no downstream PBR channels. Height used by the
	// parallax intersection was already resolved by the dedicated march, so this
	// final-shading return cannot flatten relief in neighbouring covered texels.
	if (layer.coverage <= MTS_PAINT_WEIGHT_THRESHOLD) {
		return layer;
	}
	if (has_layer_detail_albedo) {
		vec3 detail_color = sample_material_layer_raw(
			detail_albedo_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		).rgb;
		layer.albedo *= mix(vec3(1.0), detail_color, 0.35);
	}
	if (has_layer_orm) {
		vec3 raw_orm = sample_material_layer_raw(
			orm_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		).rgb;
		layer.orm.r = 1.0 + (raw_orm.r - 1.0) * clamp(layer_ao_strength, 0.0, 1.0);
		layer.orm.g = clamp(
			1.0 + (raw_orm.g - 1.0) * clamp(layer_roughness_strength, 0.0, 1.0)
				+ layer_roughness_bias,
			0.0,
			1.0
		);
		layer.orm.b = clamp(
			raw_orm.b * clamp(layer_metallic_strength, 0.0, 1.0)
				+ layer_metallic_bias,
			0.0,
			1.0
		);
	}
	if (has_layer_normal && layer_normal_strength > 0.0) {
		vec3 sampled_normal = sample_material_layer_tangent_normal(
			normal_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, v_tangent_world,
			v_binormal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		);
		layer.tangent_normal = normalize(mix(
			vec3(0.0, 0.0, 1.0),
			sampled_normal,
			clamp(layer_normal_strength, 0.0, 1.0)
		));
	}
	if (has_layer_height) {
		layer.height = sample_material_layer_raw(
			height_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		).r;
	}
	if (has_layer_emission) {
		layer.emission = sample_material_layer_raw(
			emission_texture, overlay_coord, overlay_grad_x, overlay_grad_y,
			material_world_pos, v_base_normal_world, repeat_m,
			layer_stochastic_tiling, layer_variation_asset_seed,
			layer_random_texture_rotation, layer_random_texture_mirroring,
			addressing
		).rgb * layer_emission_strength;
	}
	layer.specular = clamp(layer_specular_strength, 0.0, 1.0);
	return layer;
}

float material_height_blend(
	float weight,
	float layer_height,
	float base_height,
	float strength,
	bool has_layer_height
) {
	if (!has_layer_height || strength <= 0.0) {
		return weight;
	}
	// Height can bias only an existing transition. Preserving both endpoints
	// prevents height data from inventing procedural or brush coverage.
	float transition = clamp(weight, 0.0, 1.0);
	float transition_band = 4.0 * transition * (1.0 - transition);
	return clamp(
		transition + (layer_height - base_height) * strength * transition_band,
		0.0,
		1.0
	);
}

void material_mix_layer(
	MaterialLayerSample layer,
	float weight,
	inout vec3 albedo,
	inout vec3 tangent_normal,
	inout float roughness,
	inout float metallic,
	inout float ao,
	inout vec3 emission,
	inout float specular
) {
	// `weight` already has this layer's art coverage folded into it by the caller,
	// which is what keeps the LAYER and NORMALIZED_SPLAT modes agreeing about
	// where a transparent region contributes nothing.
	float amount = clamp(weight, 0.0, 1.0);
	albedo = mix(albedo, layer.albedo, amount);
	tangent_normal = normalize(mix(tangent_normal, layer.tangent_normal, amount));
	roughness = mix(roughness, layer.orm.g, amount);
	metallic = mix(metallic, layer.orm.b, amount);
	ao = mix(ao, layer.orm.r, amount);
	emission = mix(emission, layer.emission, amount);
	specular = mix(specular, layer.specular, amount);
}

// -----------------------------------------------------------------------------
// Vertex stage
// -----------------------------------------------------------------------------

void vertex() {
	// world_vertex_coords presents this entire authored frame in world space.
	// Transforming it through MODEL_MATRIX again applies each terrain triangle's
	// affine instance transform twice and makes adjacent halves shade differently.
	vec3 base_world = VERTEX;
	vec3 base_normal_world = normalize(NORMAL);
	vec3 tangent_world = normalize(TANGENT);
	vec3 binormal_world = normalize(BINORMAL);
	v_camera_position_world = CAMERA_POSITION_WORLD;

	// Terrain-specific UV and world-point data is indexed by MultiMesh INSTANCE_ID.
	// Terrain keeps one canonical heightfield geometry; all relief is material-only.
	v_surface_uv = UV;
	v_terrain_barycentric = vec3(0.0);
	v_terrain_boundary_mask = 0.0;
	v_texture_quarters = 0.0;
	v_material_texture_quarters = vec4(0.0);
	// Non-terrain surface assets have no face classification and retain the full
	// material-control path if blending is explicitly enabled on them.
	v_material_control_class = 2.0;
	v_material_uniform_slot = 0.0;
	if (terrain_triangle_instances) {
		int row_width = max(terrain_instance_data_width, 1);
		int data_base = INSTANCE_ID * 6;
		ivec2 data_coord_0 = ivec2(data_base % row_width, data_base / row_width);
		ivec2 data_coord_1 = ivec2((data_base + 1) % row_width, (data_base + 1) / row_width);
		ivec2 data_coord_2 = ivec2((data_base + 2) % row_width, (data_base + 2) / row_width);
		ivec2 data_coord_3 = ivec2((data_base + 3) % row_width, (data_base + 3) / row_width);
		ivec2 data_coord_4 = ivec2((data_base + 4) % row_width, (data_base + 4) / row_width);
		ivec2 data_coord_5 = ivec2((data_base + 5) % row_width, (data_base + 5) / row_width);
		vec4 terrain_uv_data_0 = texelFetch(terrain_instance_data_tex, data_coord_0, 0);
		vec4 terrain_uv_data_1 = texelFetch(terrain_instance_data_tex, data_coord_1, 0);
		vec3 world_point_0 = texelFetch(terrain_instance_data_tex, data_coord_2, 0).xyz;
		vec3 world_point_1 = texelFetch(terrain_instance_data_tex, data_coord_3, 0).xyz;
		vec3 world_point_2 = texelFetch(terrain_instance_data_tex, data_coord_4, 0).xyz;
		v_material_texture_quarters = texelFetch(terrain_instance_data_tex, data_coord_5, 0);
		v_terrain_boundary_mask = terrain_uv_data_1.z;
		// The painting placement's quarter turn rides in this texel's spare
		// channel, so a rotation never changes the per-instance data size.
		v_texture_quarters = terrain_uv_data_1.w;
		v_terrain_barycentric = vec3(1.0 - UV.x - UV.y, UV.x, UV.y);
		// Derive material projection from canonical world vertices rather than
		// VERTEX, whose MultiMesh transform stage is renderer implementation detail.
		base_world = (
			world_point_0 * v_terrain_barycentric.x
			+ world_point_1 * v_terrain_barycentric.y
			+ world_point_2 * v_terrain_barycentric.z
		);
		vec3 triangle_normal = cross(
			world_point_1 - world_point_0,
			world_point_2 - world_point_0
		);
		if (dot(triangle_normal, triangle_normal) > 0.0) {
			// Projection follows the actual sloped triangle instead of flattening
			// texture features to a cardinal heightfield direction.
			base_normal_world = normalize(triangle_normal);
		}
		v_surface_uv = (
			terrain_uv_data_0.xy
			+ UV.x * terrain_uv_data_0.zw
			+ UV.y * terrain_uv_data_1.xy
		);
		// Build the slope-aware frame used for lighting and normal-map conversion.
		if (abs(base_normal_world.y) > 0.9999) {
			tangent_world = vec3(1.0, 0.0, 0.0);
			binormal_world = vec3(0.0, 0.0, -sign(base_normal_world.y));
		} else {
			tangent_world = normalize(cross(vec3(0.0, 1.0, 0.0), base_normal_world));
			binormal_world = normalize(cross(base_normal_world, tangent_world));
		}
	}

	v_base_world_pos = base_world;
	v_base_normal_world = base_normal_world;
	v_tangent_world = tangent_world;
	v_binormal_world = binormal_world;
	// Two normalized color bytes address up to 65,536 sparse surface layers.
	v_material_control_layer = floor(COLOR.r * 255.0 + 0.5) + floor(COLOR.g * 255.0 + 0.5) * 256.0;
	// Blue carries three exact classification states; alpha carries a 0..3 slot.
	v_material_control_class = floor(COLOR.b * 2.0 + 0.5);
	v_material_uniform_slot = floor(COLOR.a * 3.0 + 0.5);

	// Retain a surface-local metric coordinate only for non-terrain surface assets.
	// Terrain samplers ignore this coordinate and use the canonical world point,
	// so no triangle-local frame can reset the map-wide material field.
	vec2 period_m = safe_size(surface_size_m) * max(mts_stochastic_scale, 0.0001);
	vec2 metric_m = vec2(dot(base_world, tangent_world), dot(base_world, binormal_world));
	v_metric_uv = metric_m / period_m;
	v_world_pos = base_world;
}

// -----------------------------------------------------------------------------
// Tangent-frame helpers
// -----------------------------------------------------------------------------

// Derive the tangent frame from the canonical terrain world positions. Parallax
// offsets texture sampling only, so lighting remains attached to real geometry.
void surface_tangent_frame(vec2 coord, out vec3 tangent_ws, out vec3 binormal_ws, out vec3 normal_ws) {
	vec3 dpdx = dFdx(v_world_pos);
	vec3 dpdy = dFdy(v_world_pos);
	vec2 dtdx = dFdx(coord);
	vec2 dtdy = dFdy(coord);

	float determinant = dtdx.x * dtdy.y - dtdx.y * dtdy.x;
	if (abs(determinant) < 0.0000001) {
		tangent_ws = normalize(v_tangent_world);
		binormal_ws = normalize(v_binormal_world);
		normal_ws = normalize(cross(tangent_ws, binormal_ws));
	} else {
		float inv_det = 1.0 / determinant;
		tangent_ws = normalize((dpdx * dtdy.y - dpdy * dtdx.y) * inv_det);
		binormal_ws = normalize((-dpdx * dtdy.x + dpdy * dtdx.x) * inv_det);
		normal_ws = normalize(cross(tangent_ws, binormal_ws));
	}

	// Keep the generated frame on the same side as the authored surface. A
	// visible back face intentionally retains the opposite lighting direction
	// so an upside-down placement is obvious instead of silently corrected.
	if (dot(normal_ws, normalize(v_base_normal_world)) < 0.0) {
		normal_ws = -normal_ws;
		binormal_ws = -binormal_ws;
	}
}

// -----------------------------------------------------------------------------
// Fragment stage
// -----------------------------------------------------------------------------

// Return the anti-aliased coverage of canonical polygon edges only.
// Internal fan and quad diagonals have no boundary bit and remain invisible.
float terrain_grid_factor() {
	vec3 derivative_width = max(
		fwidth(v_terrain_barycentric) * max(terrain_grid_line_width_px, 0.5),
		vec3(0.00001)
	);
	float coverage = 0.0;
	// Bit 0: point 0 to point 1, whose opposite barycentric coordinate is Z.
	if (mod(v_terrain_boundary_mask, 2.0) >= 1.0) {
		coverage = max(coverage, 1.0 - smoothstep(
			0.0, derivative_width.z, v_terrain_barycentric.z
		));
	}
	// Bit 1: point 1 to point 2, whose opposite coordinate is X.
	if (mod(floor(v_terrain_boundary_mask * 0.5), 2.0) >= 1.0) {
		coverage = max(coverage, 1.0 - smoothstep(
			0.0, derivative_width.x, v_terrain_barycentric.x
		));
	}
	// Bit 2: point 2 to point 0, whose opposite coordinate is Y.
	if (mod(floor(v_terrain_boundary_mask * 0.25), 2.0) >= 1.0) {
		coverage = max(coverage, 1.0 - smoothstep(
			0.0, derivative_width.y, v_terrain_barycentric.y
		));
	}
	return coverage;
}

void fragment() {
	// A stable per-pixel threshold reads as transparency while retaining opaque
	// depth behavior. The instance uniform changes without duplicating materials or
	// selecting a transparent shader variant during character movement.

	// Terrain channels sample one map-wide triplanar field from canonical world
	// position. Non-terrain assets retain their authored face projection.
	vec2 base_coord = v_metric_uv;
	vec2 grad_x = dFdx(base_coord);
	vec2 grad_y = dFdy(base_coord);

	vec2 coord = base_coord;
	// Resolve the control field before parallax and keep it for every later stage.
	// This is the only material_control_tex call in the complete fragment path.
	vec4 painted_weights = resolved_material_control_weights();

	// The parallax offset depends only on this fragment's world position and
	// normal, so it is resolved once and shared by every channel below. Resolving
	// it per channel inlined the whole height-blend chain into each sample and
	// made the shader take tens of seconds to compile on first draw.
	vec3 material_world_pos = parallax_sample_world_pos(
		v_base_world_pos, v_base_normal_world, painted_weights
	);
	bool sample_base_coat = material_base_coat_needed(painted_weights);

	vec4 albedo_sample = vec4(1.0);
	if (sample_base_coat) {
		albedo_sample = sample_projected_fragment_raw(
			albedo_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, surface_size_m,
			stochastic_tiling, texture_variation_asset_seed,
			random_texture_rotation, random_texture_mirroring
		);
	}
	vec3 albedo = mix(vec3(1.0), albedo_sample.rgb, clamp(albedo_strength, 0.0, 1.0));
	// Strength zero is exactly neutral; strength one applies the selected asset tint.
	albedo *= mix(vec3(1.0), texture_tint_color.rgb, clamp(texture_tint_strength, 0.0, 1.0));

	// Detail albedo is an optional high-frequency overlay using the same coherent
	// stochastic coordinates as every other map.
	if (sample_base_coat && has_detail_albedo) {
		vec3 detail_color = sample_projected_fragment_raw(
			detail_albedo_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
		).rgb;
		albedo *= mix(vec3(1.0), detail_color, 0.35);
	}

	// One packed ORM fetch is the complete runtime scalar-PBR contract. Cavity
	// and curvature have already been baked into R/G, while the live controls
	// below still adjust AO, roughness, and metallic independently.
	vec3 orm_value = vec3(1.0, 1.0, 0.0);
	if (sample_base_coat && has_orm) {
		orm_value = sample_projected_fragment_raw(
			orm_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
		).rgb;
	}

	float roughness_value = 1.0;
	if (sample_base_coat && has_orm) {
		roughness_value = 1.0 + (orm_value.g - 1.0) * roughness_strength;
	}
	roughness_value = clamp(roughness_value + roughness_bias, 0.0, 1.0);

	float metallic_value = 0.0;
	if (sample_base_coat && has_orm) {
		metallic_value = orm_value.b * metallic_strength;
	}
	metallic_value = clamp(metallic_value + metallic_bias, 0.0, 1.0);

	float ao_value = 1.0;
	if (sample_base_coat && has_orm) {
		ao_value = 1.0 + (orm_value.r - 1.0) * ao_strength;
	}

	vec3 tangent_ws;
	vec3 binormal_ws;
	vec3 geometry_normal_ws;
	surface_tangent_frame(coord, tangent_ws, binormal_ws, geometry_normal_ws);
	// Do not turn a visible back face into a second front face. Keeping the
	// authored frame makes the production material expose reversed placement in
	// the same directionally dark way as the paint preview.

	vec3 tangent_normal = vec3(0.0, 0.0, 1.0);
	if (sample_base_coat && has_normal && normal_strength > 0.0) {
		vec3 sampled_n = sample_projected_tangent_normal(
			normal_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, v_tangent_world,
			v_binormal_world, surface_size_m,
			stochastic_tiling, texture_variation_asset_seed,
			random_texture_rotation, random_texture_mirroring
		);
		// Blend the whole vector from flat to authored. Scaling XY alone left a
		// near-zero Z unchanged, so even the lowest setting could renormalize a
		// steep texel back into an almost horizontal, incorrectly dark normal.
		tangent_normal = normalize(mix(
			vec3(0.0, 0.0, 1.0),
			sampled_n,
			clamp(normal_strength, 0.0, 1.0)
		));
	}
	vec3 emission_value = vec3(0.0);
	if (sample_base_coat && has_emission) {
		emission_value += sample_projected_fragment_raw(
			emission_tex, coord, grad_x, grad_y,
			material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
		).rgb * emission_strength;
	}
	float specular_value = clamp(specular_strength, 0.0, 1.0);

	// Contact is sampled once and shared by automatic masks and the final grime pass.
	vec4 interaction = sample_interaction_fragment(v_base_world_pos.xz);
	float base_height_value = material_base_height_needed(painted_weights) ? sample_projected_fragment_raw(
		height_tex, coord, grad_x, grad_y,
		material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
	).r : 0.5;
	vec4 material_id_value = (has_material_id && material_base_source_needed(painted_weights, 8)) ? sample_projected_fragment_raw(
		material_id_tex, coord, grad_x, grad_y,
		material_world_pos, v_base_normal_world, surface_size_m,
		stochastic_tiling, texture_variation_asset_seed,
		random_texture_rotation, random_texture_mirroring
	) : vec4(0.0);
	float base_luminance = dot(albedo, MTS_LUMINANCE_WEIGHTS);
	// AO, roughness and metallic are the only base values whose live variables are
	// later rewritten in place -- by the composited layers, the shader decal and the
	// contact grime pass. Snapshotting them here, exactly as base_luminance already
	// does, gives material_surface_beneath() one stable base-coat term regardless of
	// where in fragment() its result is consumed.
	float base_ao_value = ao_value;
	float base_roughness_value = roughness_value;
	float base_metallic_value = metallic_value;
	float normalized_world_height = 0.0;
#ifdef MTS_WORLD_HEIGHT_FIELD
	if (material_debug_view == 7 || material_base_source_needed(painted_weights, 9)) {
		vec2 world_height_uv = world_rect_uv(v_base_world_pos.xz, g_world_height_rect);
		float raw_world_height = uv_inside_01(world_height_uv)
			? texture(g_world_height_tex, world_height_uv).r
			: material_world_height_range.x;
		normalized_world_height = material_normalized_range(
			raw_world_height,
			material_world_height_range
		);
	}
#endif
	float normalized_elevation = material_normalized_range(
		v_base_world_pos.y,
		material_world_elevation_range
	);
	float surface_up = abs(normalize(v_base_normal_world).y);

#if MTS_LAYER_COUNT > 0
	MaterialLayerSample layer_0 = sample_material_layer(
		material_layer_is_active(material_layer_0_enabled, material_layer_0_brush_authored, painted_weights.r), v_metric_uv, material_world_pos, tiled_material_layer_addressing(0),
		material_layer_0_albedo_tex, material_layer_0_normal_tex,
		material_layer_0_orm_tex, material_layer_0_height_tex, material_layer_0_emission_tex,
		material_layer_0_detail_albedo_tex,
		material_layer_0_has_normal, material_layer_0_has_height, material_layer_0_has_emission,
		material_layer_0_has_orm,
		material_layer_0_has_detail_albedo,
		material_layer_0_albedo_strength, material_layer_0_tint_color, material_layer_0_tint_strength,
		material_layer_0_normal_strength,
		material_layer_0_ao_strength, material_layer_0_roughness_strength, material_layer_0_metallic_strength,
		material_layer_0_roughness_bias, material_layer_0_metallic_bias,
		material_layer_0_emission_strength, material_layer_0_specular_strength, material_layer_0_repeat_m,
		material_layer_0_stochastic_tiling, material_layer_0_variation_asset_seed,
		material_layer_0_random_texture_rotation, material_layer_0_random_texture_mirroring
	);
#else
	MaterialLayerSample layer_0 = mts_inert_material_layer();
#endif
#if MTS_LAYER_COUNT > 1
	MaterialLayerSample layer_1 = sample_material_layer(
		material_layer_is_active(material_layer_1_enabled, material_layer_1_brush_authored, painted_weights.g), v_metric_uv, material_world_pos, tiled_material_layer_addressing(1),
		material_layer_1_albedo_tex, material_layer_1_normal_tex,
		material_layer_1_orm_tex, material_layer_1_height_tex, material_layer_1_emission_tex,
		material_layer_1_detail_albedo_tex,
		material_layer_1_has_normal, material_layer_1_has_height, material_layer_1_has_emission,
		material_layer_1_has_orm,
		material_layer_1_has_detail_albedo,
		material_layer_1_albedo_strength, material_layer_1_tint_color, material_layer_1_tint_strength,
		material_layer_1_normal_strength,
		material_layer_1_ao_strength, material_layer_1_roughness_strength, material_layer_1_metallic_strength,
		material_layer_1_roughness_bias, material_layer_1_metallic_bias,
		material_layer_1_emission_strength, material_layer_1_specular_strength, material_layer_1_repeat_m,
		material_layer_1_stochastic_tiling, material_layer_1_variation_asset_seed,
		material_layer_1_random_texture_rotation, material_layer_1_random_texture_mirroring
	);
#else
	MaterialLayerSample layer_1 = mts_inert_material_layer();
#endif
#if MTS_LAYER_COUNT > 2
	MaterialLayerSample layer_2 = sample_material_layer(
		material_layer_is_active(material_layer_2_enabled, material_layer_2_brush_authored, painted_weights.b), v_metric_uv, material_world_pos, tiled_material_layer_addressing(2),
		material_layer_2_albedo_tex, material_layer_2_normal_tex,
		material_layer_2_orm_tex, material_layer_2_height_tex, material_layer_2_emission_tex,
		material_layer_2_detail_albedo_tex,
		material_layer_2_has_normal, material_layer_2_has_height, material_layer_2_has_emission,
		material_layer_2_has_orm,
		material_layer_2_has_detail_albedo,
		material_layer_2_albedo_strength, material_layer_2_tint_color, material_layer_2_tint_strength,
		material_layer_2_normal_strength,
		material_layer_2_ao_strength, material_layer_2_roughness_strength, material_layer_2_metallic_strength,
		material_layer_2_roughness_bias, material_layer_2_metallic_bias,
		material_layer_2_emission_strength, material_layer_2_specular_strength, material_layer_2_repeat_m,
		material_layer_2_stochastic_tiling, material_layer_2_variation_asset_seed,
		material_layer_2_random_texture_rotation, material_layer_2_random_texture_mirroring
	);
#else
	MaterialLayerSample layer_2 = mts_inert_material_layer();
#endif
#if MTS_LAYER_COUNT > 3
	MaterialLayerSample layer_3 = sample_material_layer(
		material_layer_is_active(material_layer_3_enabled, material_layer_3_brush_authored, painted_weights.a), v_metric_uv, material_world_pos, tiled_material_layer_addressing(3),
		material_layer_3_albedo_tex, material_layer_3_normal_tex,
		material_layer_3_orm_tex, material_layer_3_height_tex, material_layer_3_emission_tex,
		material_layer_3_detail_albedo_tex,
		material_layer_3_has_normal, material_layer_3_has_height, material_layer_3_has_emission,
		material_layer_3_has_orm,
		material_layer_3_has_detail_albedo,
		material_layer_3_albedo_strength, material_layer_3_tint_color, material_layer_3_tint_strength,
		material_layer_3_normal_strength,
		material_layer_3_ao_strength, material_layer_3_roughness_strength, material_layer_3_metallic_strength,
		material_layer_3_roughness_bias, material_layer_3_metallic_bias,
		material_layer_3_emission_strength, material_layer_3_specular_strength, material_layer_3_repeat_m,
		material_layer_3_stochastic_tiling, material_layer_3_variation_asset_seed,
		material_layer_3_random_texture_rotation, material_layer_3_random_texture_mirroring
	);
#else
	MaterialLayerSample layer_3 = mts_inert_material_layer();
#endif
	// A shader decal is one more MaterialLayerSample. Its addressing state is the
	// sole distinction from the tiled profile layers above.
	MaterialLayerSample shader_decal_layer = sample_material_layer(
		shader_decal_enabled, v_metric_uv, material_world_pos,
		shader_decal_material_layer_addressing(),
		shader_decal_albedo_tex, shader_decal_normal_tex,
		shader_decal_orm_tex, shader_decal_height_tex, shader_decal_emission_tex,
		shader_decal_detail_albedo_tex,
		shader_decal_has_normal, shader_decal_has_height, shader_decal_has_emission,
		shader_decal_has_orm,
		shader_decal_has_detail_albedo,
		shader_decal_albedo_strength, shader_decal_tint_color,
		shader_decal_tint_strength, shader_decal_normal_strength,
		shader_decal_ao_strength,
		shader_decal_roughness_strength, shader_decal_metallic_strength,
		shader_decal_roughness_bias,
		shader_decal_metallic_bias, shader_decal_emission_strength,
		shader_decal_specular_strength, shader_decal_footprint_m,
		false, 0.0, false, false
	);

	// What is ALREADY on this texel: authored paint weight times each layer's own art
	// coverage. Layers this variant did not compile return coverage 0.0 from
	// mts_inert_material_layer(), so they drop out of every sum below without a guard.
	vec4 layer_presence = painted_weights * vec4(
		layer_0.coverage, layer_1.coverage, layer_2.coverage, layer_3.coverage
	);
	vec4 layer_height_channel = vec4(
		layer_0.height, layer_1.height, layer_2.height, layer_3.height
	);
	vec4 layer_ao_channel = vec4(
		layer_0.orm.r, layer_1.orm.r, layer_2.orm.r, layer_3.orm.r
	);
	vec4 layer_roughness_channel = vec4(
		layer_0.orm.g, layer_1.orm.g, layer_2.orm.g, layer_3.orm.g
	);
	vec4 layer_metallic_channel = vec4(
		layer_0.orm.b, layer_1.orm.b, layer_2.orm.b, layer_3.orm.b
	);
	vec4 layer_luminance_channel = vec4(
		dot(layer_0.albedo, MTS_LUMINANCE_WEIGHTS),
		dot(layer_1.albedo, MTS_LUMINANCE_WEIGHTS),
		dot(layer_2.albedo, MTS_LUMINANCE_WEIGHTS),
		dot(layer_3.albedo, MTS_LUMINANCE_WEIGHTS)
	);

	vec4 layer_weights = vec4(0.0);
	vec4 layer_constraints = vec4(0.0);
	if (material_blend_enabled) {
#if MTS_LAYER_COUNT > 0
		MaterialSurfaceBeneath beneath_0 = material_surface_beneath(
			0, layer_presence, layer_height_channel, layer_ao_channel,
			layer_roughness_channel, layer_metallic_channel, layer_luminance_channel,
			base_height_value, base_ao_value, base_roughness_value,
			base_metallic_value, base_luminance
		);
		vec2 layer_0_masks = material_layer_masks(
			material_layer_0_mask_count,
			material_layer_0_mask_sources, material_layer_0_mask_combines,
			material_layer_0_mask_channels, material_layer_0_mask_inversions, material_layer_0_mask_lows,
			material_layer_0_mask_highs, material_layer_0_mask_softness, material_layer_0_mask_strengths,
			material_layer_0_mask_noise_scales, material_layer_0_mask_noise_seeds,
			material_layer_0_mask_noise_angles, 0, material_layer_0_brush_authored, true, painted_weights, ivec4(1),
			material_id_value, beneath_0.height, beneath_0.ao,
			beneath_0.roughness, beneath_0.metallic, beneath_0.luminance, normalized_world_height,
			normalized_elevation, surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		layer_weights.r = layer_0_masks.x * material_layer_0_opacity * float(material_layer_0_enabled);
		layer_constraints.r = layer_0_masks.y * float(material_layer_0_enabled);
#endif
#if MTS_LAYER_COUNT > 1
		MaterialSurfaceBeneath beneath_1 = material_surface_beneath(
			1, layer_presence, layer_height_channel, layer_ao_channel,
			layer_roughness_channel, layer_metallic_channel, layer_luminance_channel,
			base_height_value, base_ao_value, base_roughness_value,
			base_metallic_value, base_luminance
		);
		vec2 layer_1_masks = material_layer_masks(
			material_layer_1_mask_count,
			material_layer_1_mask_sources, material_layer_1_mask_combines,
			material_layer_1_mask_channels, material_layer_1_mask_inversions, material_layer_1_mask_lows,
			material_layer_1_mask_highs, material_layer_1_mask_softness, material_layer_1_mask_strengths,
			material_layer_1_mask_noise_scales, material_layer_1_mask_noise_seeds,
			material_layer_1_mask_noise_angles, 1, material_layer_1_brush_authored, true, painted_weights, ivec4(1),
			material_id_value, beneath_1.height, beneath_1.ao,
			beneath_1.roughness, beneath_1.metallic, beneath_1.luminance, normalized_world_height,
			normalized_elevation, surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		layer_weights.g = layer_1_masks.x * material_layer_1_opacity * float(material_layer_1_enabled);
		layer_constraints.g = layer_1_masks.y * float(material_layer_1_enabled);
#endif
#if MTS_LAYER_COUNT > 2
		MaterialSurfaceBeneath beneath_2 = material_surface_beneath(
			2, layer_presence, layer_height_channel, layer_ao_channel,
			layer_roughness_channel, layer_metallic_channel, layer_luminance_channel,
			base_height_value, base_ao_value, base_roughness_value,
			base_metallic_value, base_luminance
		);
		vec2 layer_2_masks = material_layer_masks(
			material_layer_2_mask_count,
			material_layer_2_mask_sources, material_layer_2_mask_combines,
			material_layer_2_mask_channels, material_layer_2_mask_inversions, material_layer_2_mask_lows,
			material_layer_2_mask_highs, material_layer_2_mask_softness, material_layer_2_mask_strengths,
			material_layer_2_mask_noise_scales, material_layer_2_mask_noise_seeds,
			material_layer_2_mask_noise_angles, 2, material_layer_2_brush_authored, true, painted_weights, ivec4(1),
			material_id_value, beneath_2.height, beneath_2.ao,
			beneath_2.roughness, beneath_2.metallic, beneath_2.luminance, normalized_world_height,
			normalized_elevation, surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		layer_weights.b = layer_2_masks.x * material_layer_2_opacity * float(material_layer_2_enabled);
		layer_constraints.b = layer_2_masks.y * float(material_layer_2_enabled);
#endif
#if MTS_LAYER_COUNT > 3
		MaterialSurfaceBeneath beneath_3 = material_surface_beneath(
			3, layer_presence, layer_height_channel, layer_ao_channel,
			layer_roughness_channel, layer_metallic_channel, layer_luminance_channel,
			base_height_value, base_ao_value, base_roughness_value,
			base_metallic_value, base_luminance
		);
		vec2 layer_3_masks = material_layer_masks(
			material_layer_3_mask_count,
			material_layer_3_mask_sources, material_layer_3_mask_combines,
			material_layer_3_mask_channels, material_layer_3_mask_inversions, material_layer_3_mask_lows,
			material_layer_3_mask_highs, material_layer_3_mask_softness, material_layer_3_mask_strengths,
			material_layer_3_mask_noise_scales, material_layer_3_mask_noise_seeds,
			material_layer_3_mask_noise_angles, 3, material_layer_3_brush_authored, true, painted_weights, ivec4(1),
			material_id_value, beneath_3.height, beneath_3.ao,
			beneath_3.roughness, beneath_3.metallic, beneath_3.luminance, normalized_world_height,
			normalized_elevation, surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		layer_weights.a = layer_3_masks.x * material_layer_3_opacity * float(material_layer_3_enabled);
		layer_constraints.a = layer_3_masks.y * float(material_layer_3_enabled);
#endif

			// A layer this variant did not compile already carries zero weight, so
			// skipping its height blend leaves the composite unchanged.
#if MTS_LAYER_COUNT > 0
			layer_weights.r = material_height_blend(layer_weights.r, layer_0.height, base_height_value, material_layer_0_height_blend, material_layer_0_has_height);
#endif
#if MTS_LAYER_COUNT > 1
			layer_weights.g = material_height_blend(layer_weights.g, layer_1.height, base_height_value, material_layer_1_height_blend, material_layer_1_has_height);
#endif
#if MTS_LAYER_COUNT > 2
			layer_weights.b = material_height_blend(layer_weights.b, layer_2.height, base_height_value, material_layer_2_height_blend, material_layer_2_has_height);
#endif
#if MTS_LAYER_COUNT > 3
			layer_weights.a = material_height_blend(layer_weights.a, layer_3.height, base_height_value, material_layer_3_height_blend, material_layer_3_has_height);
#endif

			// Fold each layer's own art coverage into its weight. The painted mask
			// says WHERE the user brushed a layer; the layer albedo's alpha says
			// where that image has pixels at all. Multiplying them here gates both
			// composition modes below, and every channel within them, from one
			// place -- so a background-removed PNG stops contributing its
			// transparent region as opaque black with a flat normal.
			layer_weights.r *= layer_0.coverage;
			layer_weights.g *= layer_1.coverage;
			layer_weights.b *= layer_2.coverage;
			layer_weights.a *= layer_3.coverage;

			if (material_blend_mode == 1) {
				float overlay_total = layer_weights.r + layer_weights.g + layer_weights.b + layer_weights.a;
				float base_weight = max(1.0 - overlay_total, 0.0);
				float total_weight = max(base_weight + overlay_total, 0.00001);
				albedo = (
					albedo * base_weight + layer_0.albedo * layer_weights.r
					+ layer_1.albedo * layer_weights.g + layer_2.albedo * layer_weights.b
					+ layer_3.albedo * layer_weights.a
				) / total_weight;
				tangent_normal = normalize(
					tangent_normal * base_weight + layer_0.tangent_normal * layer_weights.r
					+ layer_1.tangent_normal * layer_weights.g + layer_2.tangent_normal * layer_weights.b
					+ layer_3.tangent_normal * layer_weights.a
				);
				ao_value = (ao_value * base_weight + layer_0.orm.r * layer_weights.r + layer_1.orm.r * layer_weights.g + layer_2.orm.r * layer_weights.b + layer_3.orm.r * layer_weights.a) / total_weight;
				roughness_value = (roughness_value * base_weight + layer_0.orm.g * layer_weights.r + layer_1.orm.g * layer_weights.g + layer_2.orm.g * layer_weights.b + layer_3.orm.g * layer_weights.a) / total_weight;
				metallic_value = (metallic_value * base_weight + layer_0.orm.b * layer_weights.r + layer_1.orm.b * layer_weights.g + layer_2.orm.b * layer_weights.b + layer_3.orm.b * layer_weights.a) / total_weight;
				emission_value = (emission_value * base_weight + layer_0.emission * layer_weights.r + layer_1.emission * layer_weights.g + layer_2.emission * layer_weights.b + layer_3.emission * layer_weights.a) / total_weight;
				specular_value = (specular_value * base_weight + layer_0.specular * layer_weights.r + layer_1.specular * layer_weights.g + layer_2.specular * layer_weights.b + layer_3.specular * layer_weights.a) / total_weight;
			} else {
				material_mix_layer(layer_0, layer_weights.r, albedo, tangent_normal, roughness_value, metallic_value, ao_value, emission_value, specular_value);
				material_mix_layer(layer_1, layer_weights.g, albedo, tangent_normal, roughness_value, metallic_value, ao_value, emission_value, specular_value);
				material_mix_layer(layer_2, layer_weights.b, albedo, tangent_normal, roughness_value, metallic_value, ao_value, emission_value, specular_value);
				material_mix_layer(layer_3, layer_weights.a, albedo, tangent_normal, roughness_value, metallic_value, ao_value, emission_value, specular_value);
			}
	}

	// Apply the one-shot decal through the same weighted PBR layer mixer. At full
	// source alpha it replaces the coat; transparent pixels contribute nothing.
	float shader_decal_weight = shader_decal_enabled ? shader_decal_layer.coverage : 0.0;
	material_mix_layer(
		shader_decal_layer,
		shader_decal_weight,
		albedo,
		tangent_normal,
		roughness_value,
		metallic_value,
		ao_value,
		emission_value,
		specular_value
	);

	vec3 final_normal_ws = normalize(
		tangent_ws * tangent_normal.x
		+ binormal_ws * tangent_normal.y
		+ geometry_normal_ws * tangent_normal.z
	);
	NORMAL = normalize((VIEW_MATRIX * vec4(final_normal_ws, 0.0)).xyz);

	// Contact R is the one geometry-derived distance field for GLB silhouettes
	// and wall/floor seams. Contact grime is its sole reach gain: higher values
	// cross the fixed boundary farther out without introducing a second size model.
	float floor_like = pow(abs(normalize(v_base_normal_world).y), 8.0);
	float stored_contact = clamp(interaction.r, 0.0, 1.0);
	float contact_response = stored_contact * max(mts_contact_grime, 0.0);
	float contour_threshold = 0.25;
	float breakup_coverage = 1.0;
	if (mts_contact_grime_noise > 0.0 && stored_contact > 0.0001) {
		float noise_amount = clamp(mts_contact_grime_noise, 0.0, 1.0);
		// Broad noise moves the actual iso-contour in and out. Unlike colour
		// modulation, changing this threshold changes which fragments belong to
		// the mask, so the silhouette no longer remains a mechanically even band.
		float contour_noise = material_smooth_noise(v_base_world_pos.xz, 1.1, 0.0);
		contour_threshold = clamp(
			contour_threshold + (contour_noise - 0.5) * 0.65 * noise_amount,
			0.03,
			0.65
		);
		// A separately seeded patch field perforates the mask. The hard zeroes are
		// intentional: at high noise, disconnected grime patches replace the
		// continuous line instead of merely tinting that line lighter and darker.
		float breakup_noise =
			material_smooth_noise(v_base_world_pos.xz, 0.48, 61.0) * 0.55
			+ (1.0 - material_cellular_noise(v_base_world_pos.xz, 0.34, 149.0)) * 0.45;
		float breakup_cutoff = mix(0.25, 0.68, noise_amount);
		breakup_coverage = smoothstep(
			breakup_cutoff - 0.08,
			breakup_cutoff + 0.08,
			breakup_noise
		);
	}
	// Fade is opacity falloff inside the already-selected boundary. Both forms
	// become zero at the same contour threshold, so changing fade softens the
	// mask instead of retracting or extending its outer edge.
	float hard_contact = step(contour_threshold, contact_response);
	float faded_contact = smoothstep(contour_threshold, 1.0, contact_response);
	float contact_mask = mix(
		hard_contact,
		faded_contact,
		clamp(mts_contact_grime_fade, 0.0, 1.0)
	);
	contact_mask *= breakup_coverage * step(0.0001, stored_contact);
	float grime = clamp(contact_mask * floor_like, 0.0, 1.0);
	albedo *= 1.0 - grime * mts_contact_grime_darkening;
	roughness_value = mix(roughness_value, 1.0, grime * 0.25);

	// Debug choices visualize the exact stored or derived percentage masks.
	if (material_debug_view >= 1 && material_debug_view <= 4) {
		float debug_mask = material_component(layer_weights, material_debug_view - 1);
		albedo = vec3(debug_mask);
	} else if (material_debug_view == 5) {
		albedo = painted_weights.rgb;
	} else if (material_debug_view == 6) {
		albedo = vec3(base_height_value);
	} else if (material_debug_view == 7) {
		albedo = vec3(normalized_world_height);
	}
	// Source overlay is deliberately last among diagnostics: turning it on
	// shows the exact terrain-wide guide without changing painted RGBA weights.
	if (splatmap_source_overlay_enabled) {
		// The selected face direction owns one explicit two-dimensional world plane.
		// Vertical rows use 1-Y so the image's top row maps to the highest wall band,
		// exactly matching the integer projection cells sampled by the brush.
		vec2 overlay_position = v_base_world_pos.xz;
		bool overlay_face_matches = terrain_grid_is_top;
		vec3 overlay_normal = normalize(v_base_normal_world);
		if (splatmap_source_overlay_projection == 1) {
			overlay_position = vec2(v_base_world_pos.x, 1.0 - v_base_world_pos.y);
			overlay_face_matches = !terrain_grid_is_top && overlay_normal.z < -0.5;
		} else if (splatmap_source_overlay_projection == 2) {
			overlay_position = vec2(v_base_world_pos.x, 1.0 - v_base_world_pos.y);
			overlay_face_matches = !terrain_grid_is_top && overlay_normal.z > 0.5;
		} else if (splatmap_source_overlay_projection == 3) {
			overlay_position = vec2(v_base_world_pos.z, 1.0 - v_base_world_pos.y);
			overlay_face_matches = !terrain_grid_is_top && overlay_normal.x > 0.5;
		} else if (splatmap_source_overlay_projection == 4) {
			overlay_position = vec2(v_base_world_pos.z, 1.0 - v_base_world_pos.y);
			overlay_face_matches = !terrain_grid_is_top && overlay_normal.x < -0.5;
		}
		if (overlay_face_matches) {
			vec2 overlay_uv = (
				overlay_position - splatmap_source_overlay_rect.xy
			) / max(splatmap_source_overlay_rect.zw, vec2(0.0001));
			vec4 source_weights = adjusted_splatmap_channel_weights(
				texture(
					splatmap_source_overlay_tex,
					clamp(overlay_uv, vec2(0.0), vec2(1.0))
				) * splatmap_source_overlay_channel_mask
			);
			// Four weights cannot be shown in three display channels literally, so each
			// slot gets one legend colour and the result is the weighted average of the
			// slots present here. That reads as "which material wins on this square",
			// which is what the guide exists to answer.
			const vec3 slot_1_colour = vec3(0.94, 0.22, 0.20);
			const vec3 slot_2_colour = vec3(0.24, 0.86, 0.30);
			const vec3 slot_3_colour = vec3(0.26, 0.48, 0.98);
			const vec3 slot_4_colour = vec3(0.98, 0.83, 0.18);
			float total_weight = dot(source_weights, vec4(1.0));
			vec3 slot_mix = (
				source_weights.r * slot_1_colour
				+ source_weights.g * slot_2_colour
				+ source_weights.b * slot_3_colour
				+ source_weights.a * slot_4_colour
			) / max(total_weight, 0.0001);
			// Where the map carries no weight the terrain has nothing to paint, so that
			// region stays neutral grey instead of being tinted by an arbitrary slot.
			albedo = mix(vec3(0.12), slot_mix, clamp(total_weight, 0.0, 1.0));
		}
	}
	if (material_mask_preview_enabled) {
		// The tint is drawn here, after compositing, but every value fed to the mask
		// must be the same input the layer gate above consumed -- otherwise the overlay
		// stops being a prediction of what the brush will do. That means the surface
		// beneath this entry's own slot, never the live roughness/metallic/AO variables,
		// which describe the finished surface by this point.
		MaterialSurfaceBeneath beneath_preview = material_surface_beneath(
			material_mask_preview_slot, layer_presence, layer_height_channel,
			layer_ao_channel, layer_roughness_channel, layer_metallic_channel,
			layer_luminance_channel, base_height_value, base_ao_value,
			base_roughness_value, base_metallic_value, base_luminance
		);
		vec2 preview_masks = material_layer_masks(
			material_mask_preview_count,
			material_mask_preview_sources, material_mask_preview_combines,
			material_mask_preview_channels, material_mask_preview_inversions,
			material_mask_preview_lows, material_mask_preview_highs,
			material_mask_preview_softness, material_mask_preview_strengths,
			material_mask_preview_noise_scales, material_mask_preview_noise_seeds,
			material_mask_preview_noise_angles, 0,
			material_mask_preview_brush_authored, false, painted_weights,
			material_mask_preview_paint_available,
			material_id_value, beneath_preview.height,
			beneath_preview.ao, beneath_preview.roughness,
			beneath_preview.metallic, beneath_preview.luminance,
			normalized_world_height, normalized_elevation,
			surface_up, v_surface_uv, interaction.r, v_base_world_pos.xz
		);
		float preview_mask = preview_masks.y;
		vec3 preview_green = vec3(0.02, 1.0, 0.16);
		// Dim rejected areas and tint accepted strength with a fixed diagnostic
		// green; this is transient presentation and never enters authored state.
		albedo = mix(albedo * 0.22, preview_green, preview_mask);
	}

	// Draw the grid on these exact terrain fragments after every material layer.
	// Top and side toggles select face batches; neither path owns any geometry.
	bool show_terrain_grid = terrain_triangle_instances && (
		(terrain_grid_is_top && terrain_show_top_grid)
		|| (!terrain_grid_is_top && terrain_show_side_grid)
	);
	if (show_terrain_grid && v_terrain_boundary_mask > 0.0) {
		vec4 grid_color = terrain_grid_is_top
			? terrain_top_grid_color
			: terrain_side_grid_color;
		float grid_coverage = terrain_grid_factor() * grid_color.a;
		albedo = mix(albedo, grid_color.rgb, grid_coverage);
	}

	ALBEDO = albedo;
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
	SPECULAR = clamp(specular_value, 0.0, 1.0);
	AO = clamp(ao_value, 0.0, 1.0);
	// The board lighting profile exposes this direct-light response explicitly;
	// zero retains indirect-only AO, while larger values make packed AO visible
	// under direct light without enabling the separate screen-space AO pass.
	AO_LIGHT_AFFECT = clamp(material_ao_light_affect, 0.0, 1.0);
	EMISSION = emission_value;

	// CUTOUT preserves the PNG silhouette with depth and shadows; the factory
	// removes these writes for OPAQUE or removes scissor alone for BLEND.
	ALPHA = albedo_sample.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
}
