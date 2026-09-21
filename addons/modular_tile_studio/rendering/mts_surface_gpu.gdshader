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

#include "shader/uniforms.gdshaderinc"
#include "shader/varyings.gdshaderinc"

#include "shader/texture_sampling.gdshaderinc"


#include "shader/paint_weights.gdshaderinc"

#include "shader/parallax.gdshaderinc"

#include "shader/normals.gdshaderinc"


#include "shader/world_fields.gdshaderinc"

#include "shader/material_layers.gdshaderinc"

#include "shader/material_masks.gdshaderinc"

#include "shader/vertex.gdshaderinc"

#include "shader/fragment.gdshaderinc"
