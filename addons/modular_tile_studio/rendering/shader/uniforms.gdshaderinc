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
