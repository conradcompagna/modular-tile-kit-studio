@tool
class_name ImageAssetImporter
extends RefCounted

## PNG surface import (spec 12).
##
## The critical property is speed: import a PNG, state its size in metres, and
## paint with it immediately. No analysis, no waiting. Everything else is an
## enhancement layered on afterwards (spec 11).

const K := preload("../utils/mts_constants.gd")
const Remover := preload("background_remover.gd")

## Import `source_path` as a surface asset.
##
## `settings` accepts asset_id, display_name, biome, width_m, height_m, and
## remove_background. Every imported PNG is a terrain material.
func import_image(source_path: String, settings: Dictionary, library: AssetLibrary) -> TileAsset:
	if not FileAccess.file_exists(ProjectSettings.globalize_path(source_path)) and not FileAccess.file_exists(source_path):
		push_error("[Tile Studio] image not found: %s" % source_path)
		return null

	var width_m := maxi(1, int(settings.get("width_m", 1)))
	var height_m := maxi(1, int(settings.get("height_m", 1)))
	var desired_id := String(settings.get("asset_id", ""))
	if desired_id.is_empty():
		desired_id = source_path.get_file().get_basename()
	var asset_id := library.make_unique_id(desired_id)

	var asset_dir := K.ASSETS_DIR.path_join(asset_id)
	var source_dir := asset_dir.path_join("source")
	var derived_dir := asset_dir.path_join("derived")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(source_dir))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(derived_dir))

	# Copy the original in rather than referencing it in place. The source is
	# then owned by the library and never written to again (spec 50).
	var stored_source := source_dir.path_join(source_path.get_file())
	var copy_err := _copy_file(source_path, stored_source)
	if copy_err != OK:
		push_error("[Tile Studio] could not copy source image (%s)" % error_string(copy_err))
		return null

	# Background removal writes a SEPARATE file and leaves the stored original
	# untouched, so the cut can be redone or reverted later from the real source
	# rather than from an already-processed image (spec 50).
	var albedo_path := stored_source
	var background_report := {}
	if bool(settings.get("remove_background", false)):
		background_report = _remove_background(stored_source, derived_dir)
		var cut_path := String(background_report.get("path", ""))
		if not cut_path.is_empty():
			albedo_path = cut_path

	var asset := TileAsset.new()
	asset.asset_id = asset_id
	asset.display_name = String(settings.get("display_name", asset_id.capitalize()))
	asset.source_type = K.SourceType.IMAGE_SURFACE
	# Category is derived from source_type, never supplied. The stored field is
	# written once for the benefit of anything reading old .tres files directly.
	asset.category = K.category_name(K.SourceType.IMAGE_SURFACE)
	asset.biome = String(settings.get("biome", ""))
	asset.source_path = stored_source
	asset.derived_dir = derived_dir
	asset.visual_size_m = Vector3(width_m, height_m, 0.0)
	asset.grid_bounds = Vector3i(width_m, height_m, 1)
	# moge_extent_m stays Vector3.ZERO (its default) until MoGe Geometry
	# analysis actually measures this asset's point cloud -- there is no
	# relief to report from an import that has not analyzed anything yet.
	# PNG sources always enter in the canonical Y-up orientation. SurfacePlacement,
	# not the asset or importer, owns every rotation and flip used on a board.
	asset.anchor = K.AnchorMode.ORIGIN
	# The imported PNG is the albedo. That alone is a complete, paintable asset.
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", albedo_path)

	asset.thumbnail_path = _generate_thumbnail(albedo_path, derived_dir)
	asset.analysis_status = "not_analyzed"
	asset.processing = {
		"importer": "image",
		"imported_at": Time.get_datetime_string_from_system(),
		"original_source": source_path,
		"background_source": stored_source,
		"width_m": width_m,
		"height_m": height_m,
	}
	if not background_report.is_empty() \
	and not String(background_report.get("path", "")).is_empty():
		asset.processing["background_removed"] = background_report
		# Bind the removal to the canonical alpha channel so every consumer --
		# terrain material and native decal alike -- composes the same coverage
		# through get_visible_albedo(). Recording it only in `processing` left the
		# whole transparency system as metadata nothing rendered from.
		var removed_alpha := String(background_report.get("alpha_path", ""))
		if not removed_alpha.is_empty():
			asset.gbuffer.set_channel("alpha", removed_alpha)

	var save_path := asset_dir.path_join("asset.tres")
	var err := ResourceSaver.save(asset, save_path)
	if err != OK:
		push_warning("[Tile Studio] could not save asset resource (%s)" % error_string(err))
	else:
		asset.take_over_path(save_path)

	library.add_asset(asset)
	return asset


## Write a background-stripped copy of `source_path` into `derived_dir`.
##
## Returns the new path plus what was removed, or an empty path when there was
## nothing to cut. Failure is non-fatal by design: the asset still imports with
## its untouched source, because an image that imports uncut is far better than
## an import that refuses to happen.
##
## The result is deliberately NOT cropped. The user has already stated this
## tile's size in whole metres, and cropping would silently re-frame the art
## inside those metres -- a floor would shrink away from the cell edges it was
## authored to meet. The backdrop simply becomes transparent in place.
func _remove_background(source_path: String, derived_dir: String) -> Dictionary:
	var image := Image.new()
	if image.load(ProjectSettings.globalize_path(source_path)) != OK:
		push_warning("[Tile Studio] could not read '%s' to remove its background" % source_path)
		return {}

	var result := Remover.remove_background(image, false)
	if not result.ok():
		push_warning("[Tile Studio] background removal skipped: %s" % result.error)
		return {}
	if result.removed_pixels == 0:
		# Nothing on the border was edge-connected to a single colour, so there
		# is no backdrop here and no reason to write a second file.
		return {"removed_pixels": 0, "path": ""}

	var out := derived_dir.path_join("albedo_nobg.png")
	if result.image.save_png(ProjectSettings.globalize_path(out)) != OK:
		push_warning("[Tile Studio] could not write '%s'" % out)
		return {}

	# The cut is ALSO written as a standalone alpha channel. The albedo image is
	# rewritten as RGB by map analysis, so transparency kept only inside it would
	# be silently destroyed the first time the asset is analyzed.
	var alpha_path := derived_dir.path_join("alpha.png")
	if not Remover.write_alpha_mask(result.image, alpha_path):
		alpha_path = ""

	return {
		"path": out,
		"alpha_path": alpha_path,
		"removed_pixels": result.removed_pixels,
		"removed_fraction": result.removed_fraction(),
		"background": result.background_description(),
	}


## Copy one untouched import source into its library-owned canonical path.
func _copy_file(from: String, to: String) -> Error:
	var src := ProjectSettings.globalize_path(from)
	var dst := ProjectSettings.globalize_path(to)
	if not FileAccess.file_exists(src):
		src = from
	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		return ERR_FILE_CANT_READ
	var file := FileAccess.open(dst, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(bytes)
	file.close()
	return OK


## Rebuild an asset's library thumbnail from whatever its source file now holds.
##
## The thumbnail is a snapshot, so any edit to the source leaves it showing the
## art from before -- which for background removal means the library keeps
## displaying the very plate the user just removed.
func regenerate_thumbnail(asset: TileAsset) -> String:
	if asset == null or asset.source_path.is_empty():
		return ""
	var derived_dir := asset.derived_dir
	if derived_dir.is_empty():
		derived_dir = asset.source_path.get_base_dir().get_base_dir().path_join("derived")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(derived_dir))
	return _generate_thumbnail(asset.source_path, derived_dir)


## Square thumbnail for the library grid.
func _generate_thumbnail(source_path: String, derived_dir: String, size: int = 128) -> String:
	var image := Image.new()
	var global_source := ProjectSettings.globalize_path(source_path)
	if image.load(global_source) != OK:
		return source_path
	image.resize(size, size, Image.INTERPOLATE_LANCZOS)
	var out := derived_dir.path_join("thumbnail.png")
	if image.save_png(ProjectSettings.globalize_path(out)) != OK:
		return source_path
	return out
