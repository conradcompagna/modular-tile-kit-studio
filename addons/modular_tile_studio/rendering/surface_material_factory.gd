@tool
class_name SurfaceMaterialFactory
extends RefCounted

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


## Track one live batch material so board-resource updates can reach it.
##
## Returns the same material so call sites can register inline at the point of
## duplication, which is what keeps the registry from drifting out of step with
## the duplicates it exists to describe.
func _register_live_material(mat: ShaderMaterial) -> ShaderMaterial:
	if mat != null:
		_live_materials[mat.get_instance_id()] = weakref(mat)
	return mat


## Return every live material the factory owns: cached canonicals plus batch duplicates.
##
## Freed duplicates are pruned here rather than tracked by the renderer, so no
## caller has to remember to unregister a batch it released.
func _all_live_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for value: Variant in _cache.values():
		var cached := value as ShaderMaterial
		if cached != null:
			out.append(cached)
	var dead: Array = []
	for key: Variant in _live_materials.keys():
		var reference := _live_materials[key] as WeakRef
		if reference == null:
			dead.append(key)
			continue
		var live := reference.get_ref() as ShaderMaterial
		if live == null:
			dead.append(key)
			continue
		out.append(live)
	for key: Variant in dead:
		_live_materials.erase(key)
	return out


## Return the board profile currently bound to the renderer, creating shipped defaults only for headless/test callers.
func _look() -> AestheticProfile:
	if aesthetics == null:
		aesthetics = AestheticProfile.defaults()
	return aesthetics


## Drop every cached material and composite so no stale grade/shader-path or per-asset strength result stays resident. Used for a board-wide look change; a single asset's edit uses invalidate() instead.
func clear_cache() -> void:
	_cache.clear()
	_material_cache_key_by_asset_id.clear()
	_composite_cache.clear()
	_layer_binding_cache.clear()


## Invalidate one asset's cached materials and pixel composites after its maps, strengths or bias change (see plugin.gd's _on_asset_edited).
func invalidate(asset_id: String) -> void:
	_material_cache_key_by_asset_id.erase(asset_id)
	_layer_binding_cache.erase(asset_id)
	# Composited channels go too. They are keyed by source PATH and strength, so
	# a knob change reuses them safely -- but a re-analysis rewrites those files
	# in place behind the same path, and the cached composite would then be
	# stale art that no amount of rebuilding would refresh.
	_composite_cache.clear()

	for key: String in _cache.keys():
		# Keys are "<kind>|<asset_id>" or "<kind>|<asset_id>|<facing>".
		if key.contains("|" + asset_id):
			_cache.erase(key)


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
	var image := Image.create(1, 1, false, format)
	image.set_pixel(0, 0, colour)
	return ImageTexture.create_from_image(image)


static func _white_texture() -> ImageTexture:
	if _gpu_white == null:
		_gpu_white = _solid_texture(Color.WHITE)
	return _gpu_white


static func _black_texture() -> ImageTexture:
	if _gpu_black == null:
		_gpu_black = _solid_texture(Color(0.0, 0.0, 0.0, 1.0))
	return _gpu_black


static func _normal_texture() -> ImageTexture:
	if _gpu_normal == null:
		_gpu_normal = _solid_texture(Color(0.5, 0.5, 1.0, 1.0))
	return _gpu_normal


static func _error_texture() -> ImageTexture:
	if _gpu_error == null:
		_gpu_error = _solid_texture(Color(0.8, 0.3, 0.6, 1.0))
	return _gpu_error


## Resolve AUTO against the exact visible albedo consumed by the material.
##
## Native image detection distinguishes fully opaque images from images with any
## transparency. AUTO deliberately maps every transparent image to CUTOUT because
## only the artist can say whether fractional edge pixels mean true translucency.
func resolved_alpha_mode(asset: TileAsset, visible_albedo: Texture2D = null) -> int:
	if asset == null:
		push_error("SurfaceMaterialFactory: alpha mode requested without a TileAsset.")
		return TileAsset.SurfaceAlphaMode.OPAQUE
	if asset.surface_alpha_mode != TileAsset.SurfaceAlphaMode.AUTO:
		return asset.surface_alpha_mode

	var texture := visible_albedo if visible_albedo != null else get_visible_albedo(asset)
	if texture == null:
		push_error("SurfaceMaterialFactory: AUTO alpha could not inspect '%s' because its visible albedo is missing." % asset.asset_id)
		return TileAsset.SurfaceAlphaMode.OPAQUE
	var image := texture.get_image()
	if image == null:
		push_error("SurfaceMaterialFactory: AUTO alpha could not read '%s' visible albedo pixels." % asset.asset_id)
		return TileAsset.SurfaceAlphaMode.OPAQUE
	if image.detect_alpha() == Image.ALPHA_NONE:
		return TileAsset.SurfaceAlphaMode.OPAQUE
	return TileAsset.SurfaceAlphaMode.CUTOUT


## Read the authored shader file directly so a stale ResourceLoader handle cannot hide source edits.
func _surface_shader_source_code() -> String:
	var source_code := FileAccess.get_file_as_string(GPU_SURFACE_SHADER_PATH)
	if source_code.is_empty():
		push_error(
			"SurfaceMaterialFactory: canonical GPU shader source is missing or empty at '%s'."
			% GPU_SURFACE_SHADER_PATH
		)
	return source_code


## Make every canonical and live batch material consume the current authored shader file revision.
##
## The editor checks the file on every request because shader editing is live there.
## A running game observes the source once per factory: shipped source cannot change
## during that level build, and rereading the same large shader for every terrain
## batch previously made slum2 material construction take tens of seconds.
##
## Cached canonicals and batch-local duplicates are collected before the canonical
## cache is cleared. Each material's stored alpha contract then selects its exact
## regenerated variant; a missing contract is reported and preserves the previous
## valid shader.
func _ensure_surface_shader_source_current() -> void:
	if (
		not Engine.is_editor_hint()
		and _observed_surface_shader_source_hash >= 0
		and _observed_surface_shader_source_hash == _gpu_surface_shader_source_hash
	):
		return
	var source_code := _surface_shader_source_code()
	if source_code.is_empty():
		return
	var source_hash := source_code.hash()
	if (
		source_hash == _observed_surface_shader_source_hash
		and source_hash == _gpu_surface_shader_source_hash
	):
		return
	var materials_to_refresh := _all_live_materials()
	_observed_surface_shader_source_hash = source_hash
	if source_hash != _gpu_surface_shader_source_hash:
		_gpu_surface_shaders.clear()
		_gpu_surface_shader_source_hash = source_hash
	_cache.clear()
	_material_cache_key_by_asset_id.clear()
	for material: ShaderMaterial in materials_to_refresh:
		if not material.has_meta(SURFACE_ALPHA_MODE_META):
			push_error(
				"SurfaceMaterialFactory: a live surface material has no stored alpha contract; its previous shader was preserved."
			)
			continue
		var alpha_mode := int(material.get_meta(SURFACE_ALPHA_MODE_META))
		# Rebuild the exact variant this material is already on. The effective
		# answer is used rather than the asset-only one so a requirement that came
		# from the material's layers survives a shader-source revision. It defaults
		# to true so an unknown history yields the complete shader.
		var refreshed_shader := _surface_shader(
			alpha_mode,
			bool(material.get_meta(SURFACE_EFFECTIVE_VARIATION_META, true)),
			int(material.get_meta(
				SURFACE_EFFECTIVE_LAYERS_META, MaterialBlendProfile.WEIGHTS_PER_TEXEL
			)),
			bool(material.get_meta(SURFACE_EFFECTIVE_WORLD_HEIGHT_META, true))
		)
		if refreshed_shader == null:
			push_error(
				"SurfaceMaterialFactory: shader revision refresh failed for alpha mode %d; the previous shader was preserved."
				% alpha_mode
			)
			continue
		material.shader = refreshed_shader


## Return whether one asset enables any of the three texture-variation controls.
##
## The three controls share one compiled path in the shader, so any of them being
## on requires the full lattice variant.
static func _asset_uses_texture_variation(asset: TileAsset) -> bool:
	if asset == null:
		return false
	return (
		asset.stochastic_tiling
		or asset.random_texture_rotation
		or asset.random_texture_mirroring
	)


## Return whether any enabled layer of a material-blend profile enables texture variation.
##
## Layers are plain dictionaries, and a layer resolves its controls from the
## TileAsset it references. The enabled/asset validity test mirrors
## _bind_material_layer exactly: a layer that binding would reject contributes no
## variation requirement, so the two cannot disagree about which layers are live.
static func _profile_uses_texture_variation(
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> bool:
	if profile == null or not profile.enabled or library == null:
		return false
	for layer_index: int in _resolved_slot_materials(profile, slot_materials):
		if layer_index < 0 or layer_index >= profile.layer_count():
			continue
		var layer := profile.layer(layer_index)
		if not bool(layer.get("enabled", false)):
			continue
		var asset_id := String(layer.get("asset_id", ""))
		if asset_id.is_empty():
			continue
		var overlay := library.get_asset(asset_id)
		if overlay == null or not overlay.is_surface():
			continue
		if _asset_uses_texture_variation(overlay):
			return true
	return false


## Pack the exact mask-source dependencies for one layer into an inspectable bit set.
static func _mask_dependency_bits(rules_value: Variant) -> int:
	if not rules_value is Array:
		return 0
	var dependencies := 0
	for rule_value: Variant in rules_value as Array:
		if not rule_value is Dictionary:
			continue
		var source := clampi(
			int((rule_value as Dictionary).get("source", MaterialBlendProfile.MaskSource.PAINT)),
			MaterialBlendProfile.MaskSource.PAINT,
			MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS
		)
		dependencies |= 1 << source
	return dependencies


## Return how many material-blend texel slots one batch actually needs compiled.
##
## This is the highest live SLOT plus one, not the number of live materials: the
## shader addresses slots positionally through layer_weights.xyzw, so a batch whose
## only live material sits in slot 3 still needs four slots compiled. The
## enabled/asset test mirrors _bind_material_layer so binding and variant selection
## cannot disagree. slot_materials maps each texel slot to a palette index, or -1
## where the batch leaves that slot unused.
static func _profile_layer_count(
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> int:
	if profile == null or not profile.enabled or library == null:
		return 0
	var slots := _resolved_slot_materials(profile, slot_materials)
	var required_slots: int = 0
	for slot_index: int in slots.size():
		var layer_index := slots[slot_index]
		if layer_index < 0 or layer_index >= profile.layer_count():
			continue
		var layer := profile.layer(layer_index)
		if not bool(layer.get("enabled", false)):
			continue
		var asset_id := String(layer.get("asset_id", ""))
		if asset_id.is_empty():
			continue
		var overlay := library.get_asset(asset_id)
		if overlay == null or not overlay.is_surface():
			continue
		required_slots = slot_index + 1
	return required_slots


## Return the palette index each of the four texel slots carries for one batch.
##
## A batch that supplies no explicit mapping is bound identically to the historical
## model, where texel slot N carried palette entry N. That identity mapping is the
## only one a board with four or fewer materials can have, so it is the correct
## answer rather than a stand-in for a missing one.
static func _resolved_slot_materials(
	profile: MaterialBlendProfile,
	slot_materials: PackedInt32Array
) -> PackedInt32Array:
	if slot_materials.size() == MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		return slot_materials
	if not slot_materials.is_empty():
		push_error(
			"SurfaceMaterialFactory: a batch slot mapping must name exactly %d slots, got %d."
			% [MaterialBlendProfile.WEIGHTS_PER_TEXEL, slot_materials.size()]
		)
	var identity := PackedInt32Array()
	for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		identity.append(slot_index if slot_index < profile.layer_count() else -1)
	return identity


## Return a shader derived from the one authored source for the exact alpha, culling and feature contract.
##
## OPAQUE removes every alpha write so Godot keeps the surface in the opaque depth
## pipeline, CUTOUT retains scissor testing, and BLEND retains continuous alpha.
##
## uses_texture_variation deletes the stochastic-lattice define when no asset on
## this material enables tiling, rotation or mirroring. That path turns every
## sample into three fetches plus lattice maths, so removing it is the single
## largest compile-cost saving available here. It defaults to true because the
## authored source is the complete contract: a caller that cannot prove the
## feature is unused must get the full shader rather than a silently reduced one.
func _surface_shader(
	alpha_mode: int,
	uses_texture_variation: bool = true,
	layer_count: int = MaterialBlendProfile.WEIGHTS_PER_TEXEL,
	uses_world_height: bool = true
) -> Shader:
	_ensure_surface_shader_source_current()
	var source_code := _surface_shader_source_code()
	if source_code.is_empty():
		return null
	var resolved_layer_count := clampi(layer_count, 0, MaterialBlendProfile.WEIGHTS_PER_TEXEL)
	var backface_culling_enabled := _look().backface_culling_enabled
	var key := "%d|%s|%s|%d|%s" % [
		alpha_mode,
		str(backface_culling_enabled),
		str(uses_texture_variation),
		resolved_layer_count,
		str(uses_world_height),
	]
	var cached: Shader = _gpu_surface_shaders.get(key, null)
	if cached != null:
		return cached

	const DOUBLE_SIDED_TOKEN := "render_mode cull_disabled,"
	const CULLED_TOKEN := "render_mode cull_back,"
	const DEPTH_PREPASS_TOKEN := "depth_prepass_alpha, "
	const ALPHA_TOKEN := "ALPHA = albedo_sample.a;"
	const SCISSOR_TOKEN := "ALPHA_SCISSOR_THRESHOLD = alpha_scissor;"
	const VARIATION_DEFINE_TOKEN := "#define MTS_TEXTURE_VARIATION"
	const LAYER_COUNT_DEFINE_TOKEN := "#define MTS_LAYER_COUNT 4"
	const WORLD_HEIGHT_DEFINE_TOKEN := "#define MTS_WORLD_HEIGHT_FIELD"
	# Test independent tokens because Shader.code preserves the source file's line
	# endings, which may be CRLF on Windows and must not affect renderer behavior.
	if (
		not source_code.contains(DOUBLE_SIDED_TOKEN)
		or not source_code.contains(ALPHA_TOKEN)
		or not source_code.contains(SCISSOR_TOKEN)
		or not source_code.contains(VARIATION_DEFINE_TOKEN)
		or not source_code.contains(LAYER_COUNT_DEFINE_TOKEN)
		or not source_code.contains(WORLD_HEIGHT_DEFINE_TOKEN)
	):
		push_error("SurfaceMaterialFactory: canonical GPU shader is missing its required render, alpha or feature token.")
		return null

	if resolved_layer_count != MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		# Every material-layer path is guarded by `#if MTS_LAYER_COUNT > n`, so
		# lowering the number removes those layers' uniforms and all five of their
		# projected samples from the compiled program. Layers above the count carry
		# zero painted weight anyway, so the visible result is unchanged.
		source_code = source_code.replace(
			LAYER_COUNT_DEFINE_TOKEN,
			"#define MTS_LAYER_COUNT %d" % resolved_layer_count
		)

	if not uses_texture_variation:
		# Deleting the define removes the lattice branch from the compiled program
		# entirely. The stochastic_tiling/rotation/mirroring uniforms still exist and
		# are still written; they are simply always false on this variant, so the
		# visible result is identical to the full shader with them turned off.
		source_code = source_code.replace(VARIATION_DEFINE_TOKEN, "")
	if not uses_world_height:
		# World height is board data used only by an explicit mask source or debug view.
		# Removing its define deletes the sampler and read instead of binding a field
		# that this material recipe can never observe.
		source_code = source_code.replace(WORLD_HEIGHT_DEFINE_TOKEN, "")

	match alpha_mode:
		TileAsset.SurfaceAlphaMode.OPAQUE:
			source_code = source_code.replace(DEPTH_PREPASS_TOKEN, "")
			source_code = source_code.replace(ALPHA_TOKEN, "")
			source_code = source_code.replace(SCISSOR_TOKEN, "")
		TileAsset.SurfaceAlphaMode.CUTOUT:
			pass
		TileAsset.SurfaceAlphaMode.BLEND:
			source_code = source_code.replace(SCISSOR_TOKEN, "")
		_:
			push_error("SurfaceMaterialFactory: unresolved alpha mode %d reached shader construction." % alpha_mode)
			return null

	if backface_culling_enabled:
		source_code = source_code.replace(DOUBLE_SIDED_TOKEN, CULLED_TOKEN)
	var shader := Shader.new()
	shader.code = source_code
	_gpu_surface_shaders[key] = shader
	return shader


## Build the one ShaderMaterial used by every PNG surface path.
##
## The shader owns material-only height parallax and PBR sampling, so PNG
## surfaces always remain on that one shader path.
func _build_gpu_surface_material(
	asset: TileAsset,
	albedo: Texture2D,
	maps: GBufferMapSet,
	parallax_source_short_edge_px: float,
	alpha_mode: int
) -> ShaderMaterial:
	var asset_uses_variation := _asset_uses_texture_variation(asset)
	# A PNG surface carries no material-blend layers of its own: material_blend_enabled
	# stays false unless configure_material_blend is later called on this material,
	# and that call re-selects the variant with the real layer count.
	var shader := _surface_shader(alpha_mode, asset_uses_variation, 0, false)
	if shader == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_meta(SURFACE_ALPHA_MODE_META, alpha_mode)
	mat.set_meta(SURFACE_ASSET_VARIATION_META, asset_uses_variation)
	# No layers are bound yet, so the asset answer is the effective one until
	# configure_material_blend re-selects with the layers included.
	mat.set_meta(SURFACE_EFFECTIVE_VARIATION_META, asset_uses_variation)
	mat.set_meta(SURFACE_EFFECTIVE_LAYERS_META, 0)
	mat.set_meta(SURFACE_EFFECTIVE_WORLD_HEIGHT_META, false)
	# The canonical asset material contains only PBR channel state. Terrain
	# batches opt into the triangle-instance projection when they duplicate it.
	mat.set_shader_parameter("terrain_triangle_instances", false)

	# Albedo is already resolved by get_visible_albedo(), so this builder only
	# binds it. The explicit error texture keeps a missing required image visible.
	var visible_albedo: Texture2D = albedo if albedo != null else _error_texture()
	mat.set_shader_parameter("albedo_tex", visible_albedo)

	# Runtime materials bind only final primary channels. AO, roughness, and
	# metallic are packed once into ORM; derivative analysis maps never reach the shader.
	var height := maps.load_texture("height") if maps != null else null
	var normal := maps.load_texture("normal") if maps != null else null
	var orm := _resolved_layer_orm(asset) if _has_primary_orm_source(maps) else null
	var emission := maps.load_texture("emission") if maps != null else null
	var detail_albedo := maps.load_texture("detail_albedo") if maps != null else null
	var material_id := maps.load_texture("material_id") if maps != null else null

	mat.set_shader_parameter("height_tex", height if height != null else _black_texture())
	mat.set_shader_parameter("normal_tex", normal if normal != null else _normal_texture())
	mat.set_shader_parameter("orm_tex", orm if orm != null else _neutral_orm_texture())
	mat.set_shader_parameter("emission_tex", emission if emission != null else _black_texture())
	mat.set_shader_parameter("detail_albedo_tex", detail_albedo if detail_albedo != null else _white_texture())
	mat.set_shader_parameter("material_id_tex", material_id if material_id != null else _black_texture())

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
	mat.set_shader_parameter("alpha_scissor", SHADOW_ALPHA_CUTOFF)

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

	_apply_global_shader_parameters(_look())
	_apply_board_resources_to_material(mat)
	return mat


## Publish scalar look values for the active board through Godot's project-wide
## shader-global store. The editor binds one board at a time, while each board
## keeps its own AestheticProfile as the authoritative persisted value.
func _apply_global_shader_parameters(look: AestheticProfile) -> void:
	if look == null:
		return
	RenderingServer.global_shader_parameter_set("mts_parallax_master", look.parallax_master)
	RenderingServer.global_shader_parameter_set(
		"mts_height_metres_per_source_pixel", look.height_metres_per_source_pixel
	)
	RenderingServer.global_shader_parameter_set("mts_stochastic_scale", look.stochastic_scale)
	RenderingServer.global_shader_parameter_set("mts_stochastic_blend_sharpness", look.stochastic_blend_sharpness)
	RenderingServer.global_shader_parameter_set("mts_stochastic_seed", look.stochastic_seed)
	RenderingServer.global_shader_parameter_set("mts_interaction_enabled", look.interaction_effects_enabled)
	RenderingServer.global_shader_parameter_set("mts_contact_grime", look.contact_grime)
	RenderingServer.global_shader_parameter_set("mts_contact_grime_darkening", look.contact_grime_darkening)
	RenderingServer.global_shader_parameter_set("mts_contact_grime_fade", look.contact_grime_fade)
	RenderingServer.global_shader_parameter_set("mts_contact_grime_noise", look.contact_grime_noise)


## Bind the active board's textures and world rectangles to one material.
##
## Textures stay material-local because they are Resources owned by the board
## viewport; raymarched parallax is now the shader's sole algorithm.
func _apply_board_resources_to_material(mat: ShaderMaterial) -> void:
	if mat == null:
		return
	var uses_world_height := bool(mat.get_meta(SURFACE_EFFECTIVE_WORLD_HEIGHT_META, true))
	if world_fields != null:
		if uses_world_height:
			mat.set_shader_parameter("g_world_height_tex", world_fields.height_texture)
			mat.set_shader_parameter("g_world_height_rect", world_fields.shader_rect())
		mat.set_shader_parameter("g_interaction_tex", world_fields.interaction_texture)
		mat.set_shader_parameter("g_interaction_rect", world_fields.shader_rect())
	else:
		if uses_world_height:
			mat.set_shader_parameter("g_world_height_tex", _black_texture())
		mat.set_shader_parameter("g_interaction_tex", _black_texture())


## Apply a board look without rebuilding geometry or materials.
##
## Scalar controls update the native shader-global store. Cached materials also
## receive the active board textures used by the sole raymarched parallax path.
func apply_global_effects(profile: AestheticProfile = null) -> void:
	if profile != null:
		aesthetics = profile
	var look := _look()
	_apply_global_shader_parameters(look)
	# Live batch duplicates are included: they render the board and would keep a
	# replaced world-field or interaction texture if only the cache were updated.
	for shader_mat: ShaderMaterial in _all_live_materials():
		_apply_board_resources_to_material(shader_mat)


# --- Input resolution -----------------------------------------------------
#
# The material factory owns the one visible-albedo resolution path. Both the
# committed GPU material and editor previews consume its result, so source/
# analyzed blending and visible alpha cannot drift between them.

## Resolve the exact albedo texture a PNG surface presents to the user.
##
## This applies the same analyzed/source blend and visible-alpha composition as
## the canonical GPU material. It reports missing art instead of replacing the
## selected asset with an unrelated preview texture.
func get_visible_albedo(asset: TileAsset) -> Texture2D:
	if asset == null:
		push_error("SurfaceMaterialFactory: visible albedo requested without a valid TileAsset.")
		return null

	var maps := asset.gbuffer
	var has_analyzed_albedo := maps != null and not maps.get_channel("albedo").is_empty()
	var albedo: Texture2D = maps.load_texture("albedo") if maps != null else null
	if albedo == null and not asset.source_path.is_empty():
		albedo = _load_view_texture(asset.source_path)

	if has_analyzed_albedo and albedo != null and maps.delight_blend < 1.0 and not asset.source_path.is_empty():
		var source := _load_view_texture(asset.source_path)
		if source != null:
			albedo = _blend_albedo_with_source(
				albedo,
				source,
				"delight|%s|%s|%.3f" % [maps.get_channel("albedo"), asset.source_path, maps.delight_blend],
				maps.delight_blend
			)

	if albedo == null:
		push_error("[Tile Studio] surface '%s' has no usable visible albedo." % asset.asset_id)
		return null
	var visible_albedo := _albedo_with_alpha(albedo, maps)
	return _visible_albedo_with_mipmaps(
		_adjust_visible_albedo(visible_albedo, asset),
		asset
	)


## Guarantee the visible albedo reaches the GPU carrying a full mip chain.
##
## The surface shader samples this texture through
## filter_linear_mipmap_anisotropic, and a shader decal's blend weight against
## the terrain beneath it IS this image's alpha. With only mip 0 present the GPU
## has nothing to filter with when the decal is minified, so its coverage swings
## between 0 and 1 as the camera moves and the decal appears to z-fight the
## terrain from far away while looking correct up close.
##
## This cannot be left to the source .import settings. Every branch of
## get_visible_albedo may compose a fresh Image at runtime, and Godot's detect-3D
## auto-reimport only upgrades textures it happens to observe bound to a 3D
## material -- which is why the library holds mipmapped normal/orm/height maps
## beside albedo maps that have no mip chain at all.
func _visible_albedo_with_mipmaps(texture: Texture2D, asset: TileAsset) -> Texture2D:
	if texture == null:
		return null
	var image := texture.get_image()
	if image == null:
		push_error(
			"[Tile Studio] Cannot read visible albedo pixels to build mipmaps for '%s'."
			% asset.asset_id
		)
		return texture
	if image.has_mipmaps():
		return texture

	# Keyed by the incoming texture instance: every producer feeding this point
	# already caches its own result, so an unchanged asset hands back the same
	# Texture2D and this rebuild happens once rather than once per terrain batch.
	var key := "albedo_mipmaps|%s|%d" % [asset.asset_id, texture.get_instance_id()]
	var cached: Texture2D = _composite_cache.get(key, null)
	if cached != null:
		return cached

	image = image.duplicate()
	# generate_mipmaps() cannot operate on block-compressed data, so an imported
	# VRAM texture has to be expanded before the chain can be built.
	if image.is_compressed() and image.decompress() != OK:
		push_error(
			"[Tile Studio] Cannot decompress visible albedo to build mipmaps for '%s'."
			% asset.asset_id
		)
		return texture
	if image.generate_mipmaps() != OK:
		push_error(
			"[Tile Studio] Could not generate visible albedo mipmaps for '%s'."
			% asset.asset_id
		)
		return texture

	var mipmapped := ImageTexture.create_from_image(image)
	_composite_cache[key] = mipmapped
	return mipmapped


## Serialize the five authored image adjustments into one stable cache-key fragment.
func _image_adjustment_key_fragment(asset: TileAsset) -> String:
	return "brightness=%.4f|contrast=%.4f|saturation=%.4f|sharpness=%.4f|hue=%.4f" % [
		asset.surface_brightness,
		asset.surface_contrast,
		asset.surface_saturation,
		asset.surface_sharpness,
		asset.surface_hue_shift_degrees,
	]


## Derive one adjusted albedo for every consumer while leaving source files and alpha untouched.
##
## The signed detail control changes luminance only, so neither softening nor
## sharpening can introduce coloured edge halos. Hue rotates in
## YIQ so perceived brightness remains stable, then saturation, contrast, and
## brightness operate in their visible UI order. The result is cached because a
## slider commit may otherwise walk the same image once per terrain batch.
func _adjust_visible_albedo(texture: Texture2D, asset: TileAsset) -> Texture2D:
	if texture == null or asset == null:
		push_error("SurfaceMaterialFactory: image adjustment requires a texture and TileAsset.")
		return null
	if asset.surface_image_adjustments_are_default():
		return texture

	var maps := asset.gbuffer
	var key := "image_adjust|%s|source=%s|albedo=%s|alpha=%s|delight=%.4f|%s" % [
		asset.asset_id,
		asset.source_path,
		maps.get_channel("albedo") if maps != null else "",
		maps.get_channel("alpha") if maps != null else "",
		maps.delight_blend if maps != null else 1.0,
		_image_adjustment_key_fragment(asset),
	]
	var cached: Texture2D = _composite_cache.get(key, null)
	if cached != null:
		return cached

	var image := texture.get_image()
	if image == null:
		push_error("[Tile Studio] Cannot read visible albedo pixels for '%s'." % asset.asset_id)
		return null
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		push_error("[Tile Studio] Cannot decompress visible albedo for '%s'." % asset.asset_id)
		return null
	image.convert(Image.FORMAT_RGBA8)
	var had_mipmaps := image.has_mipmaps()
	if had_mipmaps:
		image.clear_mipmaps()
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		push_error("[Tile Studio] Visible albedo for '%s' has invalid dimensions." % asset.asset_id)
		return null

	var source_bytes := image.get_data()
	var output_bytes := source_bytes.duplicate()
	var detail := asset.surface_sharpness
	var has_detail_adjustment := not is_zero_approx(detail)
	var hue_angle := deg_to_rad(asset.surface_hue_shift_degrees)
	var hue_cosine := cos(hue_angle)
	var hue_sine := sin(hue_angle)
	for y in height:
		var row_offset := y * width * 4
		for x in width:
			var index := row_offset + x * 4
			var rgb := Vector3(
				float(source_bytes[index]) / 255.0,
				float(source_bytes[index + 1]) / 255.0,
				float(source_bytes[index + 2]) / 255.0
			)

			if has_detail_adjustment:
				var left_index := row_offset + maxi(0, x - 1) * 4
				var right_index := row_offset + mini(width - 1, x + 1) * 4
				var above_index := maxi(0, y - 1) * width * 4 + x * 4
				var below_index := mini(height - 1, y + 1) * width * 4 + x * 4
				# Read neighbouring luminance as scalars so large textures do not allocate
				# four temporary colours and an index array for every source pixel.
				var neighbour_luminance := (
					float(source_bytes[left_index]) * IMAGE_LUMA_WEIGHTS.x
					+ float(source_bytes[left_index + 1]) * IMAGE_LUMA_WEIGHTS.y
					+ float(source_bytes[left_index + 2]) * IMAGE_LUMA_WEIGHTS.z
					+ float(source_bytes[right_index]) * IMAGE_LUMA_WEIGHTS.x
					+ float(source_bytes[right_index + 1]) * IMAGE_LUMA_WEIGHTS.y
					+ float(source_bytes[right_index + 2]) * IMAGE_LUMA_WEIGHTS.z
					+ float(source_bytes[above_index]) * IMAGE_LUMA_WEIGHTS.x
					+ float(source_bytes[above_index + 1]) * IMAGE_LUMA_WEIGHTS.y
					+ float(source_bytes[above_index + 2]) * IMAGE_LUMA_WEIGHTS.z
					+ float(source_bytes[below_index]) * IMAGE_LUMA_WEIGHTS.x
					+ float(source_bytes[below_index + 1]) * IMAGE_LUMA_WEIGHTS.y
					+ float(source_bytes[below_index + 2]) * IMAGE_LUMA_WEIGHTS.z
				) / (255.0 * 4.0)
				# One signed unsharp mask. A positive amount adds this pixel's
				# difference from its neighbours back onto it, and a negative amount
				# subtracts it, so -1 lands exactly on the neighbouring luminance
				# average and softens while +1 pulls away from it and sharpens.
				var edge_delta := (rgb.dot(IMAGE_LUMA_WEIGHTS) - neighbour_luminance) * detail
				rgb += Vector3.ONE * edge_delta

			if not is_zero_approx(asset.surface_hue_shift_degrees):
				var yiq_luminance := 0.299 * rgb.x + 0.587 * rgb.y + 0.114 * rgb.z
				var in_phase := 0.595716 * rgb.x - 0.274453 * rgb.y - 0.321263 * rgb.z
				var quadrature := 0.211456 * rgb.x - 0.522591 * rgb.y + 0.311135 * rgb.z
				var rotated_in_phase := in_phase * hue_cosine - quadrature * hue_sine
				var rotated_quadrature := in_phase * hue_sine + quadrature * hue_cosine
				rgb = Vector3(
					yiq_luminance + 0.9563 * rotated_in_phase + 0.6210 * rotated_quadrature,
					yiq_luminance - 0.2721 * rotated_in_phase - 0.6474 * rotated_quadrature,
					yiq_luminance - 1.1070 * rotated_in_phase + 1.7046 * rotated_quadrature
				)

			var luminance := rgb.dot(IMAGE_LUMA_WEIGHTS)
			rgb = Vector3.ONE * luminance + (rgb - Vector3.ONE * luminance) * asset.surface_saturation
			rgb = (rgb - Vector3.ONE * 0.5) * asset.surface_contrast + Vector3.ONE * 0.5
			rgb *= asset.surface_brightness
			output_bytes[index] = int(round(clampf(rgb.x, 0.0, 1.0) * 255.0))
			output_bytes[index + 1] = int(round(clampf(rgb.y, 0.0, 1.0) * 255.0))
			output_bytes[index + 2] = int(round(clampf(rgb.z, 0.0, 1.0) * 255.0))

	image.set_data(width, height, false, Image.FORMAT_RGBA8, output_bytes)
	if had_mipmaps:
		image.generate_mipmaps()
	var adjusted := ImageTexture.create_from_image(image)
	_composite_cache[key] = adjusted
	return adjusted


## Bind the supported PBR channels from the canonical map set to one native Godot Decal.
##
## This is an adapter, not a second material path: albedo resolution and alpha
## composition still go through get_visible_albedo(), while normal, resolved ORM,
## and emission use the exact stored textures inspected by the terrain material.
## Godot Decal has no height or parallax input, so a height map cannot influence
## this native node and is deliberately not approximated.
func configure_decal(decal: Decal, asset: TileAsset) -> bool:
	if decal == null:
		push_error("[Tile Studio] Cannot configure a missing native Decal node.")
		return false
	if asset == null or not asset.is_surface():
		push_error("[Tile Studio] Native decal configuration requires a surface asset.")
		return false

	var maps := asset.gbuffer
	var albedo := get_visible_albedo(asset)
	if albedo == null:
		return false
	# A native Decal exposes no alpha-scissor input, so a CUTOUT asset's hard edge
	# has to be produced in the image itself. Without this the decal alpha-BLENDS
	# art the asset explicitly declares as cutout, which would be a second
	# transparency behaviour for one authored setting.
	if resolved_alpha_mode(asset, albedo) == TileAsset.SurfaceAlphaMode.CUTOUT:
		albedo = _alpha_scissored(
			albedo,
			"decal_scissor|%s|%s|%s|delight=%.3f|%s" % [
				asset.asset_id,
				maps.get_channel("albedo") if maps != null else "",
				maps.get_channel("alpha") if maps != null else "",
				maps.delight_blend if maps != null else 1.0,
				_image_adjustment_key_fragment(asset) + "|albedo=" + str(albedo.get_rid()),
			]
		)
		if albedo == null:
			return false
	# Native Decal consumes the same one packed scalar-PBR texture as terrain.
	var orm: Texture2D = (
		_resolved_layer_orm(asset)
		if _has_primary_orm_source(maps)
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
	decal.normal_fade = DECAL_NORMAL_FADE
	return true


## Return the canonical GPU surface material for one asset and its current map response.
func get_material(asset: TileAsset) -> Material:
	_ensure_surface_shader_source_current()
	if asset == null:
		return _error_material()
	var known_key := String(
		_material_cache_key_by_asset_id.get(asset.asset_id, "")
	)
	if not known_key.is_empty():
		var known_material: Material = _cache.get(known_key, null)
		if known_material != null:
			return known_material
		_material_cache_key_by_asset_id.erase(asset.asset_id)

	# Resolve the actual visible pixels before selecting an alpha pipeline so AUTO
	# and the shader consume the same composited image rather than separate guesses.
	var albedo := get_visible_albedo(asset)
	var alpha_mode := resolved_alpha_mode(asset, albedo)
	# The source image's short-edge pixel count is part of material identity:
	# regenerated maps at a new resolution must not reuse the old parallax uniform.
	var maps := asset.gbuffer
	var height_short_edge_px := height_image_short_edge_px(asset)
	# Height strength and stochastic tiling both affect uniforms, so each needs a
	# distinct cached material even when the source maps are otherwise identical.
	var height_strength: float = maps.get_strength("height") if maps != null else 1.0
	# This mix changes the composited albedo pixels before the shader receives
	# them, so it is also part of the material's visible identity.
	var generated_albedo_blend: float = clampf(maps.delight_blend, 0.0, 1.0) if maps != null else 1.0
	var backface_culling_enabled := _look().backface_culling_enabled
	var key := "surface_gpu|%s|%.4f|%.4f|albedo=%.4f|%s|tint=%.4f,%.4f,%.4f|tint_strength=%.4f|stoch=%s|rot=%s|mirror=%s|cull=%s|alpha=%d" % [
		asset.asset_id,
		height_short_edge_px,
		height_strength,
		generated_albedo_blend,
		_image_adjustment_key_fragment(asset),
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

	var cached: Material = _cache.get(key, null)
	if cached != null:
		return cached

	var mat := _build_gpu_surface_material(
		asset,
		albedo,
		maps,
		height_short_edge_px,
		alpha_mode
	)
	_cache[key] = mat
	_material_cache_key_by_asset_id[asset.asset_id] = key
	return mat


## Return the shorter pixel dimension of one source height map.
##
## The image supplies the source sample count; the board's parallax scale turns
## it into material lookup travel without changing terrain geometry.
static func height_image_short_edge_px(asset: TileAsset) -> float:
	if asset == null or not asset.is_surface() or asset.gbuffer == null:
		return 0.0
	var height_texture := asset.gbuffer.load_texture("height")
	if height_texture == null:
		return 0.0

	var image_size := Vector2i(height_texture.get_width(), height_texture.get_height())
	if image_size.x <= 0 or image_size.y <= 0:
		push_error("[Tile Studio] Height map for '%s' has invalid image dimensions." % asset.asset_id)
		return 0.0
	return float(mini(image_size.x, image_size.y))



## Albedo with an explicit visible-alpha map composited into its alpha channel.
##
## Godot has no separate alpha-texture slot: transparency is read from the
## albedo's own alpha. The MoGe validity mask is deliberately NOT used here;
## only a genuine alpha/cutout channel can change visible transparency.
##
## Returns the albedo untouched when there is no mask, which is the common case
## for a GLB card whose render already carries a correct cutout.
func _albedo_with_alpha(albedo: Texture2D, maps: GBufferMapSet) -> Texture2D:
	if maps == null:
		return albedo
	var alpha := maps.load_texture("alpha")
	if alpha == null:
		return albedo

	# delight_blend is part of the key because `albedo` here may already be
	# get_visible_albedo()'s
	# delight-blended pixels, and the path alone cannot distinguish one blend's
	# result from another's.
	var key := "albedo_alpha|%s|%s|delight=%.3f" % [
		maps.get_channel("albedo"),
		maps.get_channel("alpha"),
		maps.delight_blend,
	]
	var cached: Texture2D = _composite_cache.get(key, null)
	if cached != null:
		return cached

	var albedo_image := albedo.get_image()
	if albedo_image == null:
		return albedo
	albedo_image = albedo_image.duplicate()
	if albedo_image.is_compressed() and albedo_image.decompress() != OK:
		return albedo
	albedo_image.convert(Image.FORMAT_RGBA8)

	var alpha_image := alpha.get_image()
	if alpha_image == null:
		return albedo
	alpha_image = alpha_image.duplicate()
	if alpha_image.is_compressed() and alpha_image.decompress() != OK:
		return albedo
	alpha_image.convert(Image.FORMAT_RGBA8)
	if alpha_image.get_size() != albedo_image.get_size():
		alpha_image.resize(
			albedo_image.get_width(),
			albedo_image.get_height(),
			Image.INTERPOLATE_BILINEAR
		)

	for y in albedo_image.get_height():
		for x in albedo_image.get_width():
			var colour := albedo_image.get_pixel(x, y)
			# Multiplied, not replaced: where the source art is already
			# transparent it stays transparent, and the mask can only ever cut
			# more away. A mask that failed to see a hole cannot fill it back in.
			colour.a *= alpha_image.get_pixel(x, y).r
			albedo_image.set_pixel(x, y, colour)

	var texture := ImageTexture.create_from_image(albedo_image)
	_composite_cache[key] = texture
	return texture

## Return one albedo with its alpha hard-thresholded at the canonical cutoff.
##
## This is the image-space equivalent of the surface shader's
## ALPHA_SCISSOR_THRESHOLD, using the same SHADOW_ALPHA_CUTOFF value, so a CUTOUT
## asset resolves to the same visible edge whether it is drawn as a terrain
## material or projected as a native Decal.
func _alpha_scissored(albedo: Texture2D, cache_key: String) -> Texture2D:
	if albedo == null:
		return null
	var cached: Texture2D = _composite_cache.get(cache_key, null)
	if cached != null:
		return cached

	var image := albedo.get_image()
	if image == null:
		return albedo
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		return albedo
	image.convert(Image.FORMAT_RGBA8)
	for y: int in image.get_height():
		for x: int in image.get_width():
			var colour := image.get_pixel(x, y)
			colour.a = 1.0 if colour.a >= SHADOW_ALPHA_CUTOFF else 0.0
			image.set_pixel(x, y, colour)

	var texture := ImageTexture.create_from_image(image)
	_composite_cache[cache_key] = texture
	return texture


## Fade an albedo map toward neutral white while preserving every source alpha.
##
## This is the visual meaning of an albedo-channel strength knob: 0 removes the
## colour information without making the object disappear, 1 uses it exactly.
func _scaled_albedo(texture: Texture2D, key: String, strength: float) -> Texture2D:
	strength = clampf(strength, 0.0, 1.0)
	if is_equal_approx(strength, 1.0):
		return texture

	var cached: Texture2D = _composite_cache.get(key, null)
	if cached != null:
		return cached

	var image := texture.get_image()
	if image == null:
		return texture
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		return texture
	image.convert(Image.FORMAT_RGBA8)

	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			image.set_pixel(x, y, Color(
				lerpf(1.0, pixel.r, strength),
				lerpf(1.0, pixel.g, strength),
				lerpf(1.0, pixel.b, strength),
				pixel.a
			))

	var adjusted := ImageTexture.create_from_image(image)
	_composite_cache[key] = adjusted
	return adjusted


## Blend an analyzed albedo back toward the untouched source image, per pixel.
##
## `blend` 1.0 is the analyzed albedo exactly (Marigold's delit result, or
## whatever else produced this asset's "albedo" channel); 0.0 is the original
## source with none of the analysis colour correction. The analyzed albedo's
## own alpha is preserved throughout -- this only ever changes RGB, since the
## source image may have been authored with a different background/alpha
## convention than the analysis output.
func _blend_albedo_with_source(analyzed: Texture2D, source: Texture2D, key: String, blend: float) -> Texture2D:
	blend = clampf(blend, 0.0, 1.0)
	if is_equal_approx(blend, 1.0):
		return analyzed

	var cached: Texture2D = _composite_cache.get(key, null)
	if cached != null:
		return cached

	var analyzed_image := analyzed.get_image()
	if analyzed_image == null:
		return analyzed
	analyzed_image = analyzed_image.duplicate()
	if analyzed_image.is_compressed() and analyzed_image.decompress() != OK:
		return analyzed
	analyzed_image.convert(Image.FORMAT_RGBA8)

	var source_image := source.get_image()
	if source_image == null:
		return analyzed
	source_image = source_image.duplicate()
	if source_image.is_compressed() and source_image.decompress() != OK:
		return analyzed
	source_image.convert(Image.FORMAT_RGBA8)
	if source_image.get_size() != analyzed_image.get_size():
		source_image.resize(
			analyzed_image.get_width(),
			analyzed_image.get_height(),
			Image.INTERPOLATE_BILINEAR
		)

	for y in analyzed_image.get_height():
		for x in analyzed_image.get_width():
			var lit := analyzed_image.get_pixel(x, y)
			var original := source_image.get_pixel(x, y)
			analyzed_image.set_pixel(x, y, Color(
				lerpf(original.r, lit.r, blend),
				lerpf(original.g, lit.g, blend),
				lerpf(original.b, lit.b, blend),
				lit.a
			))

	var blended := ImageTexture.create_from_image(analyzed_image)
	_composite_cache[key] = blended
	return blended


## Apply a strength and additive bias to a single-channel material map.
##
## `neutral` defines what a zero-strength map means: AO/roughness fade toward 1
## while metallic fades toward 0. Values above strength 1 extrapolate and clamp,
## which gives the UI an intentional way to exaggerate recovered material data.
func _adjust_scalar_map(
	texture: Texture2D,
	key: String,
	strength: float,
	neutral: float,
	bias: float
) -> Texture2D:
	if is_equal_approx(strength, 1.0) and is_zero_approx(bias):
		return texture

	var cached: Texture2D = _composite_cache.get(key, null)
	if cached != null:
		return cached

	var image := texture.get_image()
	if image == null:
		return texture
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		return texture
	image.convert(Image.FORMAT_RGBA8)

	for y in image.get_height():
		for x in image.get_width():
			var source := image.get_pixel(x, y)
			var value := clampf(lerpf(neutral, source.r, strength) + bias, 0.0, 1.0)
			image.set_pixel(x, y, Color(value, value, value, source.a))

	var adjusted := ImageTexture.create_from_image(image)
	_composite_cache[key] = adjusted
	return adjusted


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
func get_asset_material_for_terrain_batch(
	asset: TileAsset,
	control_texture: Texture2DArray,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	world_height_range: Vector2,
	world_elevation_range: Vector2,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> Material:
	var base := get_material(asset) as ShaderMaterial
	if base == null:
		return null
	var mat := _register_live_material(base.duplicate() as ShaderMaterial)
	if mat == null:
		push_error("SurfaceMaterialFactory: cannot duplicate the terrain PNG material.")
		return null
	mat.set_shader_parameter("terrain_triangle_instances", true)
	if profile != null and profile.enabled:
		configure_material_blend(
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
func get_material_for_terrain_batch(
	control_texture: Texture2DArray,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	world_height_range: Vector2,
	world_elevation_range: Vector2,
	slot_materials: PackedInt32Array = PackedInt32Array()
) -> Material:
	var base := terrain_material()
	if base == null:
		return null
	# Top and side batches carry different grid presentation flags, so even a
	# neutral unpainted batch owns its material instance rather than mutating the
	# shared canonical terrain material.
	var mat := _register_live_material(base.duplicate() as ShaderMaterial)
	if mat == null:
		push_error("SurfaceMaterialFactory: cannot duplicate the canonical terrain material.")
		return null
	mat.set_shader_parameter("terrain_triangle_instances", true)
	if profile != null and profile.enabled:
		configure_material_blend(
			mat,
			control_texture,
			profile,
			library,
			world_height_range,
			world_elevation_range,
			slot_materials
		)
	return mat


## Move one material onto the shader variant its complete feature set requires.
##
## The variant is chosen at build time from the material's own asset, because
## material-blend layers are not bound until configure_material_blend runs. A
## layer whose asset enables tiling, rotation or mirroring needs the lattice path
## compiled, so the two answers are combined here.
##
## The asset-side meta defaults to true when absent: an unknown history must
## produce the complete shader rather than one silently missing a feature.
## _surface_shader caches per variant, so an unchanged variant returns the same
## Shader instance and the assignment below is skipped.
func _ensure_material_variant(
	mat: ShaderMaterial,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	slot_materials: PackedInt32Array
) -> void:
	if not mat.has_meta(SURFACE_ALPHA_MODE_META):
		push_error(
			"SurfaceMaterialFactory: cannot re-select a shader variant without the material's stored alpha contract; its previous shader was preserved."
		)
		return
	var uses_variation: bool = (
		bool(mat.get_meta(SURFACE_ASSET_VARIATION_META, true))
		or _profile_uses_texture_variation(profile, library, slot_materials)
	)
	var layer_count := _profile_layer_count(profile, library, slot_materials)
	var uses_world_height := profile.uses_world_height()
	var shader := _surface_shader(
		int(mat.get_meta(SURFACE_ALPHA_MODE_META)),
		uses_variation,
		layer_count,
		uses_world_height
	)
	if shader == null:
		push_error(
			"SurfaceMaterialFactory: shader variant selection failed; the previous shader was preserved."
		)
		return
	mat.set_meta(SURFACE_EFFECTIVE_VARIATION_META, uses_variation)
	mat.set_meta(SURFACE_EFFECTIVE_LAYERS_META, layer_count)
	mat.set_meta(SURFACE_EFFECTIVE_WORLD_HEIGHT_META, uses_world_height)
	if mat.shader != shader:
		mat.shader = shader


## Update one existing batch material after a visible recipe or control texture change.
func configure_material_blend(
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
	var resolved_slots := _resolved_slot_materials(profile, slot_materials)
	# The variant was chosen from this material's own asset when it was built;
	# layers are only known here and may add a variation requirement. Re-selecting
	# now keeps the material on exactly the variant its complete feature set needs.
	_ensure_material_variant(mat, profile, library, resolved_slots)
	_apply_board_resources_to_material(mat)
	mat.set_meta(SURFACE_BLEND_SLOT_MATERIALS_META, resolved_slots.duplicate())
	mat.set_shader_parameter("material_blend_enabled", profile.enabled)
	mat.set_shader_parameter("material_blend_mode", int(profile.blend_mode))
	mat.set_shader_parameter("material_debug_view", int(profile.debug_view))
	configure_splatmap_channel_strengths(mat, profile)
	mat.set_shader_parameter(
		"material_control_tex",
		control_texture if control_texture != null else _neutral_material_control_array()
	)
	mat.set_shader_parameter("material_world_height_range", _nonzero_range(world_height_range))
	mat.set_shader_parameter("material_world_elevation_range", _nonzero_range(world_elevation_range))
	for slot_index: int in MaterialBlendProfile.WEIGHTS_PER_TEXEL:
		var palette_index := resolved_slots[slot_index]
		var layer := (
			profile.layer(palette_index)
			if palette_index >= 0 and palette_index < profile.layer_count()
			else MaterialBlendProfile.default_layer(0)
		)
		_bind_material_layer(mat, slot_index, layer, library, resolved_slots)


## Bind the visible RGBA strength controls without recreating textures or material recipes.
func configure_splatmap_channel_strengths(
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
func configure_material_mask_preview(
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
		SURFACE_BLEND_SLOT_MATERIALS_META,
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
	return _bind_layer_mask_rules(
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
func configure_material_layer_controls(
	mat: ShaderMaterial,
	palette_index: int,
	profile: MaterialBlendProfile,
	library: AssetLibrary
) -> void:
	if mat == null or profile == null or palette_index < 0 or palette_index >= profile.layer_count():
		push_error("SurfaceMaterialFactory: live material controls require a valid palette entry.")
		return
	var slots_value: Variant = mat.get_meta(
		SURFACE_BLEND_SLOT_MATERIALS_META,
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
	if not _bind_layer_mask_rules(mat, slot_index, layer.get("masks", []), slots):
		mat.set_shader_parameter(prefix + "enabled", false)


## Bind one shader decal as a one-shot instance of the ordinary PBR material layer.
##
## The original GPU textures remain bound directly. Placement supplies only the
## world-space addressing frame and optional palette transform.
func configure_shader_decal(
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
	_bind_pbr_layer_asset(mat, "shader_decal_", asset)
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


## Resolve and cache the immutable texture inputs used whenever an asset is bound as a layer.
##
## Terrain batches need distinct ShaderMaterials because their control textures
## differ, but the layer art does not. Resolving these inputs once per asset keeps
## a large board from repeatedly decoding albedo, generating mipmaps, scanning
## alpha and resolving ORM for every chunk surface. Asset invalidation removes
## this entry before any edited maps are rebound.
func _resolved_layer_binding(overlay: TileAsset) -> Dictionary:
	if overlay == null:
		return {}
	var cached: Dictionary = _layer_binding_cache.get(overlay.asset_id, {})
	if not cached.is_empty():
		return cached
	var maps := overlay.gbuffer
	var albedo := get_visible_albedo(overlay)
	var normal := maps.load_texture("normal") if maps != null else null
	var height := maps.load_texture("height") if maps != null else null
	var emission := maps.load_texture("emission") if maps != null else null
	var detail_albedo := maps.load_texture("detail_albedo") if maps != null else null
	var orm := _resolved_layer_orm(overlay) if _has_primary_orm_source(maps) else null
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
		"alpha_mode": resolved_alpha_mode(overlay, albedo),
		"height_short_edge_px": height_short_edge_px,
	}
	_layer_binding_cache[overlay.asset_id] = cached
	return cached


## Bind the PBR textures and response values shared by tiled and one-shot layers.
##
## Keeping these exact suffixes common means shader decals cannot drift into a
## reduced lighting model while the material profile evolves.
func _bind_pbr_layer_asset(
	mat: ShaderMaterial,
	prefix: String,
	overlay: TileAsset
) -> void:
	var binding := _resolved_layer_binding(overlay)
	var maps := binding.get("maps", null) as GBufferMapSet
	var albedo := binding.get("albedo", null) as Texture2D
	var normal := binding.get("normal", null) as Texture2D
	var height := binding.get("height", null) as Texture2D
	var emission := binding.get("emission", null) as Texture2D
	var detail_albedo := binding.get("detail_albedo", null) as Texture2D
	var orm := binding.get("orm", null) as Texture2D

	mat.set_shader_parameter(prefix + "albedo_tex", albedo if albedo != null else _error_texture())
	mat.set_shader_parameter(prefix + "normal_tex", normal if normal != null else _normal_texture())
	mat.set_shader_parameter(prefix + "orm_tex", orm if orm != null else _neutral_orm_texture())
	mat.set_shader_parameter(prefix + "height_tex", height if height != null else _black_texture())
	mat.set_shader_parameter(prefix + "emission_tex", emission if emission != null else _black_texture())
	mat.set_shader_parameter(prefix + "detail_albedo_tex", detail_albedo if detail_albedo != null else _white_texture())
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
func _bind_material_layer(
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
	var layer_binding := _resolved_layer_binding(overlay)
	mat.set_shader_parameter(
		prefix + "albedo_has_transparency",
		enabled
		and overlay != null
		and int(layer_binding.get("alpha_mode", TileAsset.SurfaceAlphaMode.OPAQUE))
		!= TileAsset.SurfaceAlphaMode.OPAQUE
	)
	_bind_pbr_layer_asset(mat, prefix, overlay)
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
	mat.set_shader_parameter(prefix + "mask_dependencies", _mask_dependency_bits(rules_value))
	if not _bind_layer_mask_rules(
		mat,
		layer_index,
		rules_value,
		slot_materials
	):
		mat.set_shader_parameter(prefix + "enabled", false)


## Bind four ordered rules to either one local layer or the dedicated preview recipe.
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


## Return whether a map set can provide the packed runtime scalar channels.
##
## A stored ORM is authoritative; separate primary AO, roughness, and metallic
## maps are packed only when that baked artifact is absent.
static func _has_primary_orm_source(maps: GBufferMapSet) -> bool:
	return (
		maps != null
		and (
			maps.has_channel("orm")
			or maps.has_channel("ambient_occlusion")
			or maps.has_channel("roughness")
			or maps.has_channel("metallic")
		)
	)


## Return a cached ORM texture resolved only from final primary scalar channels.
##
## Analysis-only cavity and curvature files are intentionally absent here. Their
## authored bake operation must fold them into ORM before runtime consumption.
func _resolved_layer_orm(asset: TileAsset) -> Texture2D:
	if asset == null or asset.gbuffer == null:
		return _neutral_orm_texture()
	var maps := asset.gbuffer
	var direct := maps.load_texture("orm")
	if direct != null:
		return direct
	var key := "layer_orm|%s|%s|%s|%s" % [
		asset.asset_id,
		maps.get_channel("ambient_occlusion"),
		maps.get_channel("roughness"),
		maps.get_channel("metallic"),
	]
	var cached := _composite_cache.get(key, null) as Texture2D
	if cached != null:
		return cached
	var packed := _pack_orm_channels(
		maps.load_texture("ambient_occlusion"),
		maps.load_texture("roughness"),
		maps.load_texture("metallic")
	)
	_composite_cache[key] = packed
	return packed


## Combine resolved scalar textures into one runtime ORM image for overlay sampling.
func _pack_orm_channels(
	ao: Texture2D,
	roughness: Texture2D,
	metallic: Texture2D
) -> Texture2D:
	var resolution := Vector2i.ONE
	for texture: Texture2D in [ao, roughness, metallic]:
		if texture != null:
			resolution = Vector2i(
				maxi(resolution.x, texture.get_width()),
				maxi(resolution.y, texture.get_height())
			)
	var ao_image := _scalar_channel_image(ao, resolution, 1.0)
	var roughness_image := _scalar_channel_image(roughness, resolution, 1.0)
	var metallic_image := _scalar_channel_image(metallic, resolution, 0.0)
	var packed := Image.create(
		resolution.x,
		resolution.y,
		false,
		Image.FORMAT_RGB8
	)
	for y: int in resolution.y:
		for x: int in resolution.x:
			packed.set_pixel(
				x,
				y,
				Color(
					ao_image.get_pixel(x, y).r,
					roughness_image.get_pixel(x, y).r,
					metallic_image.get_pixel(x, y).r,
					1.0
				)
			)
	return ImageTexture.create_from_image(packed)


## Return one decompressed, resized scalar image or a constant explicit value.
func _scalar_channel_image(
	texture: Texture2D,
	resolution: Vector2i,
	default_value: float
) -> Image:
	var image: Image = texture.get_image() if texture != null else null
	if image == null:
		image = Image.create(
			resolution.x,
			resolution.y,
			false,
			Image.FORMAT_RGBA8
		)
		image.fill(Color(default_value, default_value, default_value, 1.0))
		return image
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		push_error("SurfaceMaterialFactory: cannot decompress a material layer channel.")
		image = Image.create(
			resolution.x,
			resolution.y,
			false,
			Image.FORMAT_RGBA8
		)
		image.fill(Color(default_value, default_value, default_value, 1.0))
		return image
	image.convert(Image.FORMAT_RGBA8)
	if image.get_size() != resolution:
		image.resize(resolution.x, resolution.y, Image.INTERPOLATE_LANCZOS)
	return image


## Return one explicit AO=1, roughness=1, metallic=0 packed texture.
func _neutral_orm_texture() -> ImageTexture:
	var texture: ImageTexture = _composite_cache.get("neutral_layer_orm", null)
	if texture != null:
		return texture
	var image := Image.create(1, 1, false, Image.FORMAT_RGB8)
	image.fill(Color(1.0, 1.0, 0.0, 1.0))
	texture = ImageTexture.create_from_image(image)
	_composite_cache["neutral_layer_orm"] = texture
	return texture


## Return one black Texture2DArray for batch materials that have no painted pixels yet.
func _neutral_material_control_array() -> Texture2DArray:
	var cached := _composite_cache.get("neutral_material_control_array", null) as Texture2DArray
	if cached != null:
		return cached
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var texture := Texture2DArray.new()
	var create_error := texture.create_from_images([image])
	if create_error != OK:
		push_error(
			"SurfaceMaterialFactory: cannot create neutral material control array (%s)."
			% error_string(create_error)
		)
		return null
	_composite_cache["neutral_material_control_array"] = texture
	return texture


## Prevent a normalized shader range from dividing by zero on a flat board.
func _nonzero_range(value: Vector2) -> Vector2:
	if not value.is_finite():
		return Vector2(0.0, 1.0)
	if value.y - value.x < 0.000001:
		return Vector2(value.x, value.x + 0.000001)
	return value


## Report an asset without a usable visible texture instead of silently switching renderers.
func _error_material() -> Material:
	push_error("SurfaceMaterialFactory: surface material requested without a valid TileAsset.")
	return null


## Build the terrain's own material, which has no base PNG at all.
##
## Terrain is not a PNG surface: it is imported or drawn untextured, and every
## texture on it arrives by painting. Requiring a base asset is what forced the
## editor to invent a ground texture on import, so this path deliberately has no
## asset argument. The shader is the same one every painted surface uses, with
## neutral maps standing in for the channels a base PNG would have supplied.
func terrain_material() -> ShaderMaterial:
	_ensure_surface_shader_source_current()
	var backface_culling_enabled := _look().backface_culling_enabled
	var key := "terrain_gpu|cull=%s" % str(backface_culling_enabled)
	var cached := _cache.get(key, null) as ShaderMaterial
	if cached != null:
		return cached

	# Terrain has no base PNG, so it contributes no texture variation of its own.
	# Any requirement comes from painted layers, which configure_material_blend
	# applies through _ensure_material_variant once those layers are bound.
	var shader := _surface_shader(TileAsset.SurfaceAlphaMode.OPAQUE, false, 0, false)
	if shader == null:
		return null
	var mat := ShaderMaterial.new()
	# Opaque: terrain is solid ground, so it needs no alpha pipeline.
	mat.shader = shader
	mat.set_meta(SURFACE_ALPHA_MODE_META, TileAsset.SurfaceAlphaMode.OPAQUE)
	mat.set_meta(SURFACE_ASSET_VARIATION_META, false)
	mat.set_meta(SURFACE_EFFECTIVE_VARIATION_META, false)
	mat.set_meta(SURFACE_EFFECTIVE_LAYERS_META, 0)
	mat.set_meta(SURFACE_EFFECTIVE_WORLD_HEIGHT_META, false)
	# Painting consumes the canonical heightfield triangles directly.
	mat.set_shader_parameter("terrain_triangle_instances", true)
	mat.set_shader_parameter("terrain_show_top_grid", true)
	mat.set_shader_parameter("terrain_show_side_grid", false)

	# Untextured terrain renders as plain unlit-neutral ground. These are the
	# same neutral stand-ins the shader already expects for absent channels, so
	# no branch is added to the shader itself.
	mat.set_shader_parameter("albedo_tex", _white_texture())
	mat.set_shader_parameter("normal_tex", _normal_texture())
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
	_apply_board_resources_to_material(mat)

	_cache[key] = mat
	return mat


## Load a freshly written render, tolerating the resource filesystem not having
## imported it yet.
##
## Renders are produced during import and used moments later, so ResourceLoader
## often does not know them. Falling back to a direct Image load avoids the race
## that would otherwise leave a just-imported prop invisible.
func _load_view_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if ResourceLoader.exists(path):
		var res := ResourceLoader.load(path) as Texture2D
		if res != null:
			return res
	var global_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global_path):
		var image := Image.new()
		if image.load(global_path) == OK and not image.is_empty():
			return ImageTexture.create_from_image(image)
	return null
