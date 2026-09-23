@tool
class_name TileAsset
extends Resource

## One entry in the unified asset library (spec 9).
##
## PNG surfaces and GLB props share this type deliberately. The editor -- and
## later the LLM -- should reason about the asset abstraction, not about whether
## the art originated in Stable Diffusion or Meshy. Fields that only apply to one
## source type are grouped and simply left at defaults for the other.

const K := preload("../utils/mts_constants.gd")

## Neutral defaults shared by asset creation, the inspector reset action, and rendering tests.
const SURFACE_BRIGHTNESS_DEFAULT: float = 1.0
const SURFACE_CONTRAST_DEFAULT: float = 1.0
const SURFACE_SATURATION_DEFAULT: float = 1.0
const SURFACE_SHARPNESS_DEFAULT: float = 0.0
const SURFACE_HUE_SHIFT_DEFAULT_DEGREES: float = 0.0

## The explicit alpha contracts available to every terrain-painted PNG surface.
## AUTO uses native image alpha detection: fully opaque pixels select OPAQUE,
## while any transparent pixel selects CUTOUT; true translucency is opt-in.
enum SurfaceAlphaMode { AUTO, OPAQUE, CUTOUT, BLEND }

# --- Identity -------------------------------------------------------------

## Stable, machine-safe, semantic ID, e.g. "MONASTERY_FLOOR_01". This is the
## token the board JSON and the future LLM refer to, so it must not change once
## a board references it. Note a GLB source may back several assets (spec 51),
## so this is never derived from the filename alone.
@export var asset_id: String = ""
@export var display_name: String = ""
@export var source_type: K.SourceType = K.SourceType.IMAGE_SURFACE
@export var biome: String = ""

## DEPRECATED as stored data: the category is DERIVED from source_type.
##
## There are exactly two kinds of asset here -- a PNG painted onto a grid face
## and a GLB placed in a cell -- so the category is a restatement of the source
## type, not an independent choice. Leaving it free text meant every import
## coined its own spelling and the filter dropdown filled with near-duplicate
## shelves holding the same thing.
##
## Read through category_name() instead, which always answers from source_type.
## The
## field survives only so existing library .tres files keep loading with their
## saved string rather than erroring on an unknown property.
@export var category: String = ""

## DEPRECATED. Free-text tags duplicated what the id, name and the two fixed
## categories already say, and nothing ever searched them usefully. Kept only so
## saved assets still load; no UI reads or writes it.
@export var tags: PackedStringArray = PackedStringArray()

# --- Files ----------------------------------------------------------------

## The untouched original import. Never written to (spec 50).
@export var source_path: String = ""
@export var thumbnail_path: String = ""
## Folder holding every generated artefact for this asset.
@export var derived_dir: String = ""

## Whether this GLB prop must render from a validated derived runtime GLB.
##
## False explicitly selects source_path. True explicitly selects
## prop_runtime_path and fails if that artifact is absent; it never falls back.
@export var prop_mesh_optimization_enabled: bool = false
## Native ImporterMesh LOD ratio promoted to the derived runtime base mesh.
@export_range(0.125, 0.5, 0.125) var prop_mesh_target_ratio: float = 0.125
## Maximum embedded runtime texture edge, where zero preserves original size.
@export_enum("Original:0", "4096:4096", "2048:2048") var prop_max_texture_size: int = 2048
## Validated derived GLB used only while prop_mesh_optimization_enabled is true.
@export var prop_runtime_path: String = ""
## Inspectable source/output geometry and texture measurements from the last build.
@export var prop_runtime_metrics: Dictionary = {}

# --- Spatial --------------------------------------------------------------

## Real-world size of the visible art, in metres.
@export var visual_size_m: Vector3 = Vector3(1, 1, 1)
## Metric X/Y/Z extent of this asset's MoGe point cloud (spec 21), measured
## once at analysis time from the object's own valid geometry -- never from
## the board size the user typed in. Zero on any axis means "not analyzed";
## surface_material_factory.gd must treat that as absent, not as zero relief.
##
## X/Y double as the physical size the photographed content spanned when
## MoGe analyzed it, so a later resize can be compared with this recorded extent
## without treating the material map as a second placement coordinate.
@export var moge_extent_m: Vector3 = Vector3.ZERO
## Whole cells this asset claims on the lattice. For surfaces only X/Y of the
## face plane are meaningful; for props this is the full 3D box (spec 27).
@export var grid_bounds: Vector3i = Vector3i(1, 1, 1)
@export var anchor: K.AnchorMode = K.AnchorMode.BOTTOM_CENTER

# Source orientation is an invariant rather than asset state: PNG and GLB
# sources are Y-up, while board placement resources own every face, spin, and flip.

# --- Maps -----------------------------------------------------------------

@export var gbuffer: GBufferMapSet

# --- Surface settings -----------------------------------------------------

## Select the actual depth/alpha pipeline used by this PNG surface.
## AUTO is deterministic and inspectable; BLEND is never inferred because an
## antialiased cutout and intentionally translucent art cannot be distinguished.
@export var surface_alpha_mode: SurfaceAlphaMode = SurfaceAlphaMode.AUTO

## Height is an optional terrain material-parallax input. The image supplies
## its shorter pixel dimension; the board's height metres-per-source-pixel
## control converts that normalized range into view-dependent texture travel
## without changing terrain geometry, collision, or placement coordinates.

## Colour multiplied into this surface's albedo wherever the texture is used.
##
## The strength below blends from neutral white to this colour, so the stored
## colour can be changed without affecting the surface while strength is zero.
@export var surface_tint_color: Color = Color.WHITE
## Visible influence of surface_tint_color: zero is neutral and one is the full tint.
@export_range(0.0, 1.0, 0.01) var surface_tint_strength: float = 0.0

## Per-texture image adjustments are applied once to the resolved visible albedo.
## Neutral defaults leave imported pixels unchanged, and alpha is never modified.
##
## surface_sharpness is one signed detail axis rather than two competing controls:
## negative values low-pass luminance toward the neighbouring pixels and positive
## values push it away from them, so a single stored number always answers what
## happened to this texture's fine detail.
@export_range(0.0, 2.0, 0.01) var surface_brightness: float = SURFACE_BRIGHTNESS_DEFAULT
@export_range(0.0, 2.0, 0.01) var surface_contrast: float = SURFACE_CONTRAST_DEFAULT
@export_range(0.0, 2.0, 0.01) var surface_saturation: float = SURFACE_SATURATION_DEFAULT
@export_range(-1.0, 1.0, 0.01) var surface_sharpness: float = SURFACE_SHARPNESS_DEFAULT
@export_range(-180.0, 180.0, 0.1) var surface_hue_shift_degrees: float = SURFACE_HUE_SHIFT_DEFAULT_DEGREES

## Opt this terrain-painted surface into shader-side stochastic texture synthesis. The shader
## samples three deterministic random-phase copies on a triangular lattice and
## blends them coherently across every PBR channel, breaking obvious repetition
## without changing BoardDocument placements. Turn this off for authored motifs,
## trim sheets, readable symbols, or any texture whose exact layout matters.
@export var stochastic_tiling: bool = false

## Randomly rotate lattice patches in 90-degree steps for every use of this material.
##
## This is independent of stochastic phase offsets, and the shader rotates tangent-space
## normals back into the surface frame so lighting follows the visible texture orientation.
@export var random_texture_rotation: bool = false

## Randomly mirror lattice patches for every base or material-painted use of this asset.
##
## Mirroring is independent of stochastic phase offsets and uses the same deterministic
## asset and board seeds as rotation, keeping every PBR channel spatially coherent.
@export var random_texture_mirroring: bool = false

# --- Prop settings (canonical GLB model) ----------------------------------
#
# A prop is placed as its OWN real source mesh, rendered and shadowed by
# Godot's normal 3D pipeline -- there is no separate rendered/shelled
# representation to keep in sync with it any more (AGENTS.md 1.2). Only what
# sizing and collision genuinely need is stored: the canonical scale/centering
# pose and voxel set. PropPlacement applies one complete 24-state rigid
# orientation to that same source data at placement time, so visual art,
# collision, and occupancy cannot diverge into separate facing variants.

## Raw size of the untouched source GLB, in metres. The number every sizing
## calculation starts from, so a rebuild never compounds onto a previous scale.
@export var source_size_m: Vector3 = Vector3.ONE

## Authored NORTH-facing integer grid box.
@export var requested_grid_size: Vector3i = Vector3i.ONE

## Which grid axis drives proportional scaling.
## 0=X, 1=Y, 2=Z.
@export var size_driver_axis: int = 1

## false = proportional mesh inside integer box
## true  = nonuniformly stretch mesh exactly to integer box
@export var stretch_to_grid: bool = false

## Scale + centering transform (with no placement rotation) that maps the
## untouched source GLB into its canonical integer grid box. It is computed at
## import/rebuild time; PropPlacement applies the selected orientation to this
## pose and to the matching canonical or diagonal measured voxel set.
@export var prop_pose_transform: Transform3D = Transform3D.IDENTITY

## Canonical 1 m voxel set, measured from the source mesh in the unrotated grid
## box. Every cardinal placement is this set turned by a right angle, which maps
## the lattice onto itself exactly.
@export var prop_voxels: Array[Vector3i] = []

## The same measurement taken again with the mesh turned 45 degrees, in the box
## MTSConstants.diagonal_scan_bounds() derives from grid_bounds.
##
## A right angle maps the lattice onto itself; 45 degrees does not, so a diagonal
## placement cannot be derived from prop_voxels without inflating it. It is scanned
## once here instead. All four diagonal headings are right-angle turns of this one
## set, and the 45-degree box is always square in XZ, so one scan covers them all.
##
## Empty on assets imported before diagonal scanning existed. Such assets cannot
## be placed diagonally until an explicit rebuild measures this set; the inspector
## exposes that state instead of substituting estimated occupancy.
@export var prop_voxels_diagonal: Array[Vector3i] = []

## Per-voxel percentage of the source mesh's triangles intersecting each canonical cell.
##
## This array is index-aligned with prop_voxels and remains unfiltered so changing
## the authored threshold never requires approximating or expanding old collision.
@export var prop_voxel_triangle_shares_percent: PackedFloat32Array = PackedFloat32Array()

## Per-voxel triangle shares for the exact 45-degree scan.
##
## This array is index-aligned with prop_voxels_diagonal and is turned by the same
## right-angle mapping as that measured scan for every diagonal placement.
@export var prop_voxel_diagonal_triangle_shares_percent: PackedFloat32Array = PackedFloat32Array()

## Whether floor instances of this GLB level their exact collision footprint.
##
## This is asset-authored state rather than a board-wide rendering preference, so
## different props on the same level can make independent terrain-contact choices.
@export var prop_contact_flatten: bool = true

## Whether this asset's flatten writes movable copies on neighbouring quads.
##
## Off changes only footprint-local corners for a crisp step. On propagates the
## same target plane into wall-free shared corners to form a sloped transition.
@export var prop_contact_flatten_smooth: bool = false

# --- Prop settings: DEPRECATED --------------------------------------------
#
# Every field below belongs to the pre-rework pipeline, which derived sprites
# and occupancy through separate anchors that were free to drift apart. They
# survive ONLY so existing library .tres files keep loading; nothing reads them.
# Delete them once every GLB in the library has been rebuilt once.

@export var solid_cells: Array[Vector3i] = []
@export var occluder_cells: Array[Vector3i] = []
@export var visual_cells: Array[Vector3i] = []
@export var view_renders: Dictionary = {}
@export var sprite_world_size: Dictionary = {}
@export var occupancy_is_derived: bool = false

# view_gbuffers, sprite_anchor_offset, depth_range, depth_origin and
# depth_anchor were deleted with the impostor renderer.
#
# They described a per-pixel depth window used to fake occlusion from a flat
# card. Placed surface and prop geometry now use Godot's normal depth buffer,
# so these legacy fields no longer participate in visibility.
#
# Godot drops unknown properties when loading an older .tres, so library assets
# still carrying them continue to load; the values are simply discarded.

# --- Processing metadata --------------------------------------------------

## Everything needed to reproduce the derived artefacts from the untouched
## source: target scale, stretch mode, proxy mode, render PPM, analysis recipes
## and model versions (spec 50).
@export var processing: Dictionary = {}
@export var analysis_status: String = "not_analyzed"


func _init() -> void:
	if gbuffer == null:
		gbuffer = GBufferMapSet.new()


## Restore every per-texture image adjustment to its exact neutral value.
func reset_surface_image_adjustments() -> void:
	surface_brightness = SURFACE_BRIGHTNESS_DEFAULT
	surface_contrast = SURFACE_CONTRAST_DEFAULT
	surface_saturation = SURFACE_SATURATION_DEFAULT
	surface_sharpness = SURFACE_SHARPNESS_DEFAULT
	surface_hue_shift_degrees = SURFACE_HUE_SHIFT_DEFAULT_DEGREES
	emit_changed()


## Return whether the image-adjustment group currently leaves the source pixels unchanged.
func surface_image_adjustments_are_default() -> bool:
	return (
		is_equal_approx(surface_brightness, SURFACE_BRIGHTNESS_DEFAULT)
		and is_equal_approx(surface_contrast, SURFACE_CONTRAST_DEFAULT)
		and is_equal_approx(surface_saturation, SURFACE_SATURATION_DEFAULT)
		and is_equal_approx(surface_sharpness, SURFACE_SHARPNESS_DEFAULT)
		and is_equal_approx(surface_hue_shift_degrees, SURFACE_HUE_SHIFT_DEFAULT_DEGREES)
	)


## The asset's category. Always derived, never stored: see the `category` field.
func category_name() -> String:
	return K.category_name(source_type)


## Return whether this asset is a PNG material intended for canonical terrain.
func is_surface() -> bool:
	return source_type == K.SourceType.IMAGE_SURFACE


## Return whether this asset is a canonical GLB prop.
func is_prop() -> bool:
	return source_type == K.SourceType.GLB_PROP


## Resolve the one GLB path the renderer is explicitly configured to consume.
##
## Missing optimized output is a visible build failure, not permission to render
## the untouched source through a hidden compatibility path.
func prop_model_path() -> String:
	var selected := prop_runtime_path if prop_mesh_optimization_enabled else source_path
	var role := "optimized runtime" if prop_mesh_optimization_enabled else "canonical source"
	if selected.is_empty():
		push_error("[Tile Studio] Prop '%s' has no %s GLB path." % [asset_id, role])
		return ""
	if not FileAccess.file_exists(ProjectSettings.globalize_path(selected)):
		push_error("[Tile Studio] Prop '%s' %s GLB is missing: %s" % [asset_id, role, selected])
		return ""
	return selected


## Return whether the selected prop GLB currently exists and can be requested.
func prop_model_is_ready() -> bool:
	var selected := prop_runtime_path if prop_mesh_optimization_enabled else source_path
	return (
		not selected.is_empty()
		and FileAccess.file_exists(ProjectSettings.globalize_path(selected))
	)


## Return whether both measured voxel sets carry complete triangle-share evidence.
func prop_collision_measurements_ready() -> bool:
	return (
		not prop_voxels.is_empty()
		and not prop_voxels_diagonal.is_empty()
		and prop_voxel_triangle_shares_percent.size() == prop_voxels.size()
		and (
			prop_voxel_diagonal_triangle_shares_percent.size()
			== prop_voxels_diagonal.size()
		)
	)


## Return one raw measured scan after applying a caller-owned triangle-share threshold.
##
## The TileAsset owns only source-derived measurements. BoardDocument owns the one
## global threshold used by every placement on that level, so no GLB can silently
## disagree with the movement grid or with another instance of the same asset.
func filtered_prop_voxels(
	diagonal: bool,
	threshold_percent: float = 0.0
) -> Array[Vector3i]:
	var source_voxels: Array[Vector3i] = []
	source_voxels.assign(prop_voxels_diagonal if diagonal else prop_voxels)
	var threshold := clampf(threshold_percent, 0.0, 100.0)
	if threshold <= 0.0:
		return source_voxels
	var shares := (
		prop_voxel_diagonal_triangle_shares_percent
		if diagonal
		else prop_voxel_triangle_shares_percent
	)
	if shares.size() != source_voxels.size():
		push_error(
			"[Tile Studio] Prop '%s' cannot apply the board's %.3f%% collision filter without a complete %s triangle-share scan."
			% [asset_id, threshold, "diagonal" if diagonal else "canonical"]
		)
		return []
	var filtered: Array[Vector3i] = []
	for voxel_index: int in source_voxels.size():
		if shares[voxel_index] >= threshold:
			filtered.append(source_voxels[voxel_index])
	return filtered


## Return why one board-owned collision threshold cannot supply this measured scan.
func prop_collision_filter_error(
	diagonal: bool,
	threshold_percent: float
) -> String:
	var threshold := clampf(threshold_percent, 0.0, 100.0)
	if threshold <= 0.0:
		return ""
	var source_voxels := prop_voxels_diagonal if diagonal else prop_voxels
	var shares := (
		prop_voxel_diagonal_triangle_shares_percent
		if diagonal
		else prop_voxel_triangle_shares_percent
	)
	var scan_name := "45-degree" if diagonal else "canonical"
	if shares.size() != source_voxels.size():
		return "'%s' needs a rebuilt %s triangle-share scan before the board's %.3f%% collision filter can be used" % [
			asset_id,
			scan_name,
			threshold,
		]
	if filtered_prop_voxels(diagonal, threshold).is_empty():
		return "the board's %.3f%% collision filter removes every %s voxel from '%s'" % [
			threshold,
			scan_name,
			asset_id,
		]
	return ""


## Footprint of a surface asset on its own face plane, in whole cells.
## Width runs along the face's local X, height along its local Y.
func surface_footprint() -> Vector2i:
	return Vector2i(maxi(1, grid_bounds.x), maxi(1, grid_bounds.y))


## Footprint of a surface after `quarters` in-plane 90 degree turns.
##
## An odd number of quarters swaps which axis carries the width. The terrain
## coverage transform and authored UV projection must use the same rotated size.
func rotated_surface_footprint(quarters: int) -> Vector2i:
	var footprint := surface_footprint()
	if ((quarters % 4) + 4) % 4 % 2 == 1:
		return Vector2i(footprint.y, footprint.x)
	return footprint


## Return a compact inspectable description for asset-list presentation.
func summary() -> String:
	if is_surface():
		return "%s  %dx%d m  Y-up source" % [
			asset_id, grid_bounds.x, grid_bounds.y
		]
	var runtime_state := "optimized" if prop_mesh_optimization_enabled else "source"
	if not prop_model_is_ready():
		runtime_state += " missing"
	return "%s  %.2fx%.2fx%.2f m  %s" % [
		asset_id, visual_size_m.x, visual_size_m.y, visual_size_m.z, runtime_state
	]
