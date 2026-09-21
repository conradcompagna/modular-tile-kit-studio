@tool
extends RefCounted

## Lifecycle behavior for SurfaceMaterialFactory.
## The host retains Godot identity, signals, and authoritative state.

## Track one live batch material so board-resource updates can reach it.
##
## Returns the same material so call sites can register inline at the point of
## duplication, which is what keeps the registry from drifting out of step with
## the duplicates it exists to describe.
static func _register_live_material(host: SurfaceMaterialFactory, mat: ShaderMaterial) -> ShaderMaterial:
	if mat != null:
		host._live_materials[mat.get_instance_id()] = weakref(mat)
	return mat


## Return every live material the factory owns: cached canonicals plus batch duplicates.
##
## Freed duplicates are pruned here rather than tracked by the renderer, so no
## caller has to remember to unregister a batch it released.
static func _all_live_materials(host: SurfaceMaterialFactory) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for value: Variant in host._cache.values():
		var cached := value as ShaderMaterial
		if cached != null:
			out.append(cached)
	var dead: Array = []
	for key: Variant in host._live_materials.keys():
		var reference := host._live_materials[key] as WeakRef
		if reference == null:
			dead.append(key)
			continue
		var live := reference.get_ref() as ShaderMaterial
		if live == null:
			dead.append(key)
			continue
		out.append(live)
	for key: Variant in dead:
		host._live_materials.erase(key)
	return out


## Return the board profile currently bound to the renderer, creating shipped defaults only for headless/test callers.
static func _look(host: SurfaceMaterialFactory) -> AestheticProfile:
	if host.aesthetics == null:
		host.aesthetics = AestheticProfile.defaults()
	return host.aesthetics


## Drop every cached material and composite so no stale grade/shader-path or per-asset strength result stays resident. Used for a board-wide look change; a single asset's edit uses invalidate() instead.
static func clear_cache(host: SurfaceMaterialFactory) -> void:
	host._cache.clear()
	host._material_cache_key_by_asset_id.clear()
	host._composite_cache.clear()
	host._layer_binding_cache.clear()


## Invalidate one asset's cached materials and pixel composites after its maps, strengths or bias change (see plugin.gd's _on_asset_edited).
static func invalidate(host: SurfaceMaterialFactory, asset_id: String) -> void:
	host._material_cache_key_by_asset_id.erase(asset_id)
	host._layer_binding_cache.erase(asset_id)
	# Composited channels go too. They are keyed by source PATH and strength, so
	# a knob change reuses them safely -- but a re-analysis rewrites those files
	# in place behind the same path, and the cached composite would then be
	# stale art that no amount of rebuilding would refresh.
	host._composite_cache.clear()

	for key: String in host._cache.keys():
		# Keys are "<kind>|<asset_id>" or "<kind>|<asset_id>|<facing>".
		if key.contains("|" + asset_id):
			host._cache.erase(key)
