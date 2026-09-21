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
