@tool
extends RefCounted

const ShaderSource := preload("../shader_source.gd")

## Shader variants behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

## Resolve AUTO against the exact visible albedo consumed by the material.
##
## Native image detection distinguishes fully opaque images from images with any
## transparency. AUTO deliberately maps every transparent image to CUTOUT because
## only the artist can say whether fractional edge pixels mean true translucency.
static func resolved_alpha_mode(host: SurfaceMaterialFactory, asset: TileAsset, visible_albedo: Texture2D = null) -> int:
	if asset == null:
		push_error("SurfaceMaterialFactory: alpha mode requested without a TileAsset.")
		return TileAsset.SurfaceAlphaMode.OPAQUE
	if asset.surface_alpha_mode != TileAsset.SurfaceAlphaMode.AUTO:
		return asset.surface_alpha_mode

	var texture := visible_albedo if visible_albedo != null else host.get_visible_albedo(asset)
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
static func _surface_shader_source_code(host: SurfaceMaterialFactory) -> String:
	var source_code := ShaderSource.read_expanded(SurfaceMaterialFactory.GPU_SURFACE_SHADER_PATH)
	if source_code.is_empty():
		push_error(
			"SurfaceMaterialFactory: canonical GPU shader source is missing or empty at '%s'."
			% SurfaceMaterialFactory.GPU_SURFACE_SHADER_PATH
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
static func _ensure_surface_shader_source_current(host: SurfaceMaterialFactory) -> void:
	if (
		not Engine.is_editor_hint()
		and host._observed_surface_shader_source_hash >= 0
		and host._observed_surface_shader_source_hash == SurfaceMaterialFactory._gpu_surface_shader_source_hash
	):
		return
	var source_code := host._surface_shader_source_code()
	if source_code.is_empty():
		return
	var source_hash := source_code.hash()
	if (
		source_hash == host._observed_surface_shader_source_hash
		and source_hash == SurfaceMaterialFactory._gpu_surface_shader_source_hash
	):
		return
	var materials_to_refresh := host._all_live_materials()
	host._observed_surface_shader_source_hash = source_hash
	if source_hash != SurfaceMaterialFactory._gpu_surface_shader_source_hash:
		SurfaceMaterialFactory._gpu_surface_shaders.clear()
		SurfaceMaterialFactory._gpu_surface_shader_source_hash = source_hash
	host._cache.clear()
	host._material_cache_key_by_asset_id.clear()
	for material: ShaderMaterial in materials_to_refresh:
		if not material.has_meta(SurfaceMaterialFactory.SURFACE_ALPHA_MODE_META):
			push_error(
				"SurfaceMaterialFactory: a live surface material has no stored alpha contract; its previous shader was preserved."
			)
			continue
		var alpha_mode := int(material.get_meta(SurfaceMaterialFactory.SURFACE_ALPHA_MODE_META))
		# Rebuild the exact variant this material is already on. The effective
		# answer is used rather than the asset-only one so a requirement that came
		# from the material's layers survives a shader-source revision. It defaults
		# to true so an unknown history yields the complete shader.
		var refreshed_shader := host._surface_shader(
			alpha_mode,
			bool(material.get_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_VARIATION_META, true)),
			int(material.get_meta(
				SurfaceMaterialFactory.SURFACE_EFFECTIVE_LAYERS_META, MaterialBlendProfile.WEIGHTS_PER_TEXEL
			)),
			bool(material.get_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_WORLD_HEIGHT_META, true))
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
	for layer_index: int in SurfaceMaterialFactory._resolved_slot_materials(profile, slot_materials):
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
		if SurfaceMaterialFactory._asset_uses_texture_variation(overlay):
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
	var slots := SurfaceMaterialFactory._resolved_slot_materials(profile, slot_materials)
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
static func _surface_shader(host: SurfaceMaterialFactory,
	alpha_mode: int,
	uses_texture_variation: bool = true,
	layer_count: int = MaterialBlendProfile.WEIGHTS_PER_TEXEL,
	uses_world_height: bool = true
) -> Shader:
	host._ensure_surface_shader_source_current()
	var source_code := host._surface_shader_source_code()
	if source_code.is_empty():
		return null
	var resolved_layer_count := clampi(layer_count, 0, MaterialBlendProfile.WEIGHTS_PER_TEXEL)
	var backface_culling_enabled := host._look().backface_culling_enabled
	var key := "%d|%s|%s|%d|%s" % [
		alpha_mode,
		str(backface_culling_enabled),
		str(uses_texture_variation),
		resolved_layer_count,
		str(uses_world_height),
	]
	var cached: Shader = SurfaceMaterialFactory._gpu_surface_shaders.get(key, null)
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
	SurfaceMaterialFactory._gpu_surface_shaders[key] = shader
	return shader


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
static func _ensure_material_variant(host: SurfaceMaterialFactory,
	mat: ShaderMaterial,
	profile: MaterialBlendProfile,
	library: AssetLibrary,
	slot_materials: PackedInt32Array
) -> void:
	if not mat.has_meta(SurfaceMaterialFactory.SURFACE_ALPHA_MODE_META):
		push_error(
			"SurfaceMaterialFactory: cannot re-select a shader variant without the material's stored alpha contract; its previous shader was preserved."
		)
		return
	var uses_variation: bool = (
		bool(mat.get_meta(SurfaceMaterialFactory.SURFACE_ASSET_VARIATION_META, true))
		or SurfaceMaterialFactory._profile_uses_texture_variation(profile, library, slot_materials)
	)
	var layer_count := SurfaceMaterialFactory._profile_layer_count(profile, library, slot_materials)
	var uses_world_height := profile.uses_world_height()
	var shader := host._surface_shader(
		int(mat.get_meta(SurfaceMaterialFactory.SURFACE_ALPHA_MODE_META)),
		uses_variation,
		layer_count,
		uses_world_height
	)
	if shader == null:
		push_error(
			"SurfaceMaterialFactory: shader variant selection failed; the previous shader was preserved."
		)
		return
	mat.set_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_VARIATION_META, uses_variation)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_LAYERS_META, layer_count)
	mat.set_meta(SurfaceMaterialFactory.SURFACE_EFFECTIVE_WORLD_HEIGHT_META, uses_world_height)
	if mat.shader != shader:
		mat.shader = shader
