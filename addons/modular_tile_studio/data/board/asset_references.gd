@tool
extends RefCounted

## Asset references behavior for BoardDocument.
## The host retains Godot identity, signals, and authoritative state.

## Record that one asset entered the library while this board was the open level.
##
## Deliberately silent: the import record only feeds the library panel's level
## view, so announcing board_changed here would rebuild every placement, mesh and
## collider for a change that moved nothing. The importer refreshes the library
## panel in the same step, which is where the new entry becomes visible.
static func note_imported_asset(host: BoardDocument, asset_id: String) -> void:
	if asset_id.is_empty():
		push_error("[Tile Studio] cannot record an import with no asset id.")
		return
	if host.imported_asset_ids.has(asset_id):
		return
	host.imported_asset_ids.append(asset_id)


## Drop one asset id from this board's import record.
##
## Called when the asset itself is deleted, so a saved board stops naming files
## that no longer exist.
static func forget_imported_asset(host: BoardDocument, asset_id: String) -> void:
	var index := host.imported_asset_ids.find(asset_id)
	if index >= 0:
		host.imported_asset_ids.remove_at(index)


## Return every asset id this board actually uses, in no particular order.
##
## Structural references are owned here. The paint owner supplies palette indices
## that truly affect a face, so merely configuring or clicking a material never
## causes it to appear as a used level asset.
static func used_asset_ids(host: BoardDocument,
	active_material_palette_indices: PackedInt32Array = PackedInt32Array()
) -> PackedStringArray:
	var seen: Dictionary = {}
	for placement: SurfacePlacement in host.surfaces:
		if placement != null and not placement.asset_id.is_empty():
			seen[placement.asset_id] = true
	for placement: PropPlacement in host.props:
		if placement != null and not placement.asset_id.is_empty():
			seen[placement.asset_id] = true
	for monster_value: Variant in host.monster_visual_assets.keys():
		var visual_id := host.monster_visual_asset_id(String(monster_value))
		if not visual_id.is_empty():
			seen[visual_id] = true
	host.material_blend.ensure_layers()
	for index: int in active_material_palette_indices:
		if index < 0 or index >= host.material_blend.layer_count():
			push_error("BoardDocument: active material palette index %d is invalid." % index)
			continue
		var layer_id := String(host.material_blend.layer(index).get("asset_id", ""))
		if not layer_id.is_empty():
			seen[layer_id] = true
	var used := PackedStringArray()
	for used_value: Variant in seen.keys():
		used.append(String(used_value))
	return used


## Validate one explicit monster-to-GLB assignment against the bound project library.
static func validate_monster_visual_assignment(host: BoardDocument,
	monster_id: String,
	asset_id: String
) -> Dictionary:
	if monster_id.is_empty() or monster_id != monster_id.strip_edges():
		return {"valid": false, "reason": "monster id must be a trimmed non-empty string"}
	if asset_id.is_empty() or asset_id != asset_id.strip_edges():
		return {"valid": false, "reason": "monster visual asset id must be a trimmed non-empty string"}
	if host._library == null:
		return {"valid": false, "reason": "asset library is not bound"}
	var asset := host._library.get_asset(asset_id)
	if asset == null:
		return {"valid": false, "reason": "unknown monster visual asset '%s'" % asset_id}
	if not asset.is_prop():
		return {"valid": false, "reason": "monster visual '%s' must be a GLB asset" % asset_id}
	return {"valid": true, "reason": ""}


## Assign one imported GLB to every placement that references the exact monster id.
static func set_monster_visual_asset(host: BoardDocument, monster_id: String, asset_id: String) -> Dictionary:
	var result := host.validate_monster_visual_assignment(monster_id, asset_id)
	if not bool(result.get("valid", false)):
		return result
	host.monster_visual_assets[monster_id] = asset_id
	host.board_changed.emit()
	return {
		"valid": true,
		"reason": "",
		"monster": monster_id,
		"asset": asset_id,
	}


## Remove one monster's visual assignment without changing any enemy placements.
static func clear_monster_visual_asset(host: BoardDocument, monster_id: String) -> Dictionary:
	if not host.monster_visual_assets.has(monster_id):
		return {"valid": false, "reason": "monster '%s' has no visual asset" % monster_id}
	host.monster_visual_assets.erase(monster_id)
	host.board_changed.emit()
	return {"valid": true, "reason": "", "monster": monster_id, "asset": ""}


## Resolve one assigned monster GLB while reporting invalid saved references locally.
static func resolve_monster_visual_asset(host: BoardDocument, monster_id: String) -> TileAsset:
	var asset_id := host.monster_visual_asset_id(monster_id)
	if asset_id.is_empty():
		return null
	if host._library == null:
		push_error("[Tile Studio] cannot resolve monster '%s' without an asset library." % monster_id)
		return null
	var asset := host._library.get_asset(asset_id)
	if asset == null or not asset.is_prop():
		push_error("[Tile Studio] monster '%s' references invalid GLB asset '%s'." % [monster_id, asset_id])
		return null
	return asset


## Resolve the visible asset for one direct asset reference.
##
## A missing asset returns null so callers report the unbound state rather than
## substituting a stand-in.
static func resolve_asset(host: BoardDocument, asset_id: String) -> TileAsset:
	if host._library == null or asset_id.is_empty():
		return null
	return host._library.get_asset(asset_id)


## Resolve the visible asset for one surface placement.
static func resolve_surface_asset(host: BoardDocument, placement: SurfacePlacement) -> TileAsset:
	if placement == null:
		return null
	return host.resolve_asset(placement.asset_id)


## Resolve the visible asset for one prop placement.
static func resolve_prop_asset(host: BoardDocument, placement: PropPlacement) -> TileAsset:
	if placement == null:
		return null
	return host.resolve_asset(placement.asset_id)
