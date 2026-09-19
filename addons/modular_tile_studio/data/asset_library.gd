@tool
class_name AssetLibrary
extends Resource

## The one unified library holding both PNG surfaces and GLB props (spec 8).
##
## Authoritative for asset metadata. Keeps an id -> asset index so placement
## validation never rescans (spec 47). This is also the object that will later
## hand the LLM its closed vocabulary.

const K := preload("../utils/mts_constants.gd")

signal library_changed()

@export var assets: Array[TileAsset] = []

var _index: Dictionary = {}


func rebuild_index() -> void:
	_index.clear()
	for asset in assets:
		if asset == null or asset.asset_id.is_empty():
			continue
		if _index.has(asset.asset_id):
			push_warning("AssetLibrary: duplicate asset_id '%s'" % asset.asset_id)
		_index[asset.asset_id] = asset


func get_asset(asset_id: String) -> TileAsset:
	if _index.size() != assets.size():
		rebuild_index()
	return _index.get(asset_id, null)


func has_asset(asset_id: String) -> bool:
	return get_asset(asset_id) != null


func add_asset(asset: TileAsset) -> void:
	if asset == null or asset.asset_id.is_empty():
		push_error("AssetLibrary: refusing to add an asset with no id")
		return
	if has_asset(asset.asset_id):
		push_warning("AssetLibrary: replacing existing asset '%s'" % asset.asset_id)
		remove_asset(asset.asset_id)
	assets.append(asset)
	_index[asset.asset_id] = asset
	library_changed.emit()


func remove_asset(asset_id: String) -> void:
	var asset := get_asset(asset_id)
	if asset == null:
		return
	assets.erase(asset)
	_index.erase(asset_id)
	library_changed.emit()


## Remove an asset AND every file it owns.
##
## remove_asset() only drops the index entry, which leaves the asset's folder --
## source GLB, four facings of impostor renders, proxy mesh, thumbnails -- on
## disk. Those run from tens to hundreds of megabytes each, so an asset the user
## deleted is expensive to keep: this is the call that actually reclaims it.
##
## Returns the number of bytes freed, so the caller can report what was removed
## rather than deleting silently.
func delete_asset_files(asset_id: String) -> int:
	var asset := get_asset(asset_id)
	if asset == null:
		return 0

	# Derive the folder from the asset's own recorded paths rather than assuming
	# the layout: an asset imported by an older version may sit elsewhere.
	var folder := ""
	if not asset.resource_path.is_empty():
		folder = asset.resource_path.get_base_dir()
	elif not asset.derived_dir.is_empty():
		folder = asset.derived_dir.get_base_dir()
	elif not asset.source_path.is_empty():
		folder = asset.source_path.get_base_dir().get_base_dir()

	var freed := 0
	# Only ever delete inside the library's own asset directory. A malformed or
	# hand-edited path must not be able to point this at the rest of the disk.
	if not folder.is_empty() and folder.begins_with(K.ASSETS_DIR):
		freed = _directory_size(folder)
		_delete_recursive(folder)
	else:
		push_warning("AssetLibrary: '%s' has no folder inside %s; index entry removed but no files deleted" % [
			asset_id, K.ASSETS_DIR
		])

	remove_asset(asset_id)
	return freed


## Total bytes of every file under `path`.
func _directory_size(path: String) -> int:
	var total := 0
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	for file in dir.get_files():
		var handle := FileAccess.open(path.path_join(file), FileAccess.READ)
		if handle != null:
			total += handle.get_length()
			handle.close()
	for sub in dir.get_directories():
		total += _directory_size(path.path_join(sub))
	return total


## Depth-first delete of a directory and everything in it.
func _delete_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file in dir.get_files():
		dir.remove(file)
	for sub in dir.get_directories():
		_delete_recursive(path.path_join(sub))
		dir.remove(sub)
	# Remove the now-empty folder itself.
	var parent := DirAccess.open(path.get_base_dir())
	if parent != null:
		parent.remove(path.get_file())


## Unique, machine-safe id derived from a desired name, e.g. "Floor A" ->
## "FLOOR_A", suffixed if taken. Source filenames are intentionally not used as
## identity because one GLB may back several assets (spec 51).
func make_unique_id(desired: String) -> String:
	var base := desired.strip_edges().to_upper()
	var cleaned := ""
	for i in base.length():
		var c := base[i]
		if (c >= "A" and c <= "Z") or (c >= "0" and c <= "9"):
			cleaned += c
		elif c == " " or c == "-" or c == "_" or c == ".":
			cleaned += "_"
	while cleaned.contains("__"):
		cleaned = cleaned.replace("__", "_")
	cleaned = cleaned.strip_edges().trim_prefix("_").trim_suffix("_")
	if cleaned.is_empty():
		cleaned = "ASSET"
	if not has_asset(cleaned):
		return cleaned
	var n := 2
	while has_asset("%s_%02d" % [cleaned, n]):
		n += 1
	return "%s_%02d" % [cleaned, n]


func filter(source_type: int = -1, category: String = "", biome: String = "", search: String = "") -> Array[TileAsset]:
	var out: Array[TileAsset] = []
	var needle := search.strip_edges().to_lower()
	for asset in assets:
		if asset == null:
			continue
		if source_type >= 0 and asset.source_type != source_type:
			continue
		# Category is derived from the source type, so filtering by it must ask
		# the asset, not the stored string an old import happened to write.
		if not category.is_empty() and asset.category_name() != category:
			continue
		if not biome.is_empty() and asset.biome != biome:
			continue
		if not needle.is_empty():
			var hay := "%s %s %s %s" % [
				asset.asset_id, asset.display_name, asset.category_name(), asset.biome
			]
			if not hay.to_lower().contains(needle):
				continue
		out.append(asset)
	return out


## The two fixed categories, in a stable order.
##
## Deliberately NOT scanned from the assets present: the shelves exist whether or
## not anything is on them yet, so the filter does not change shape as the
## library fills up.
func categories() -> PackedStringArray:
	return PackedStringArray([
		K.category_name(K.SourceType.IMAGE_SURFACE),
		K.category_name(K.SourceType.GLB_PROP),
	])


func biomes() -> PackedStringArray:
	var out := PackedStringArray()
	for asset in assets:
		if asset != null and not asset.biome.is_empty() and not out.has(asset.biome):
			out.append(asset.biome)
	out.sort()
	return out


## Vocabulary export for future LLM prompting (spec 35). Not used to generate
## boards yet -- it only describes what a generator would legally be allowed to
## emit, which is why it lives beside the library rather than in a generator.
func to_vocabulary_json() -> Dictionary:
	var entries: Array = []
	for asset in assets:
		if asset == null:
			continue
		var entry := {
			"asset": asset.asset_id,
			"name": asset.display_name,
			"category": asset.category_name(),
			"biome": asset.biome,
			"channel": "surface" if asset.is_surface() else "prop",
			"source_orientation": "Y_UP",
		}
		if asset.is_surface():
			entry["size_cells"] = [asset.grid_bounds.x, asset.grid_bounds.y]
			entry["legal_faces"] = ["+Y", "-Y", "+X", "-X", "+Z", "-Z"]
			entry["legal_rotations"] = [0, 1, 2, 3]
		else:
			entry["grid_bounds"] = [asset.grid_bounds.x, asset.grid_bounds.y, asset.grid_bounds.z]
			entry["legal_forward_faces"] = ["+Y", "-Y", "+X", "-X", "+Z", "-Z"]
			entry["legal_rolls"] = [0, 1, 2, 3]
		entries.append(entry)
	return {"version": 2, "assets": entries}


static func load_or_create(path: String = K.LIBRARY_RESOURCE_PATH) -> AssetLibrary:
	if ResourceLoader.exists(path):
		var res := ResourceLoader.load(path)
		var lib := res as AssetLibrary
		if lib != null:
			lib.rebuild_index()
			return lib
		push_warning("AssetLibrary: '%s' exists but is not an AssetLibrary; creating a new one" % path)
	var library := AssetLibrary.new()
	library.resource_path = path
	return library


func save(path: String = K.LIBRARY_RESOURCE_PATH) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := ResourceSaver.save(self, path)
	if err != OK:
		push_error("AssetLibrary: save to '%s' failed (%s)" % [path, error_string(err)])
	return err
