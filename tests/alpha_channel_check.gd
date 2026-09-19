extends SceneTree

## Prove that a background-removed surface reaches the renderer WITH its alpha.
##
## The shader assigns ALPHA = albedo_sample.a, so whatever get_visible_albedo()
## returns is exactly what decides transparency for both terrain paint and native
## decals. This reports, per surface asset, whether that composed texture actually
## carries coverage -- which is the single fact the black-border bug turned on.

const Remover := preload("res://addons/modular_tile_studio/importers/background_remover.gd")


## Defer until global script classes are registered for the SceneTree.
func _init() -> void:
	_run.call_deferred()


## Describe how much of one image is transparent, or -1 when it has no alpha.
func _transparent_fraction(image: Image) -> float:
	if image == null:
		return -1.0
	if image.detect_alpha() == Image.ALPHA_NONE:
		return -1.0
	var copy := image.duplicate() as Image
	if copy.is_compressed() and copy.decompress() != OK:
		return -1.0
	copy.convert(Image.FORMAT_RGBA8)
	# Sampled on a grid rather than per pixel: this is a report, and a 2k source
	# would otherwise spend seconds here for a number quoted to one decimal.
	var step := maxi(1, copy.get_width() / 128)
	var clear := 0
	var total := 0
	for y: int in range(0, copy.get_height(), step):
		for x: int in range(0, copy.get_width(), step):
			total += 1
			if copy.get_pixel(x, y).a < 0.35:
				clear += 1
	return float(clear) / float(maxi(total, 1))


## Report every surface asset's recorded cut, bound alpha channel, and composed alpha.
func _run() -> void:
	var library := AssetLibrary.load_or_create()
	var factory := SurfaceMaterialFactory.new()
	var broken := 0
	var repairable := 0
	var fine := 0

	for asset: TileAsset in library.assets:
		if asset == null or not asset.is_surface() or asset.gbuffer == null:
			continue
		var report: Dictionary = asset.processing.get("background_removed", {})
		var cut_path := String(report.get("path", ""))
		if cut_path.is_empty():
			continue

		var has_alpha_channel := asset.gbuffer.has_channel("alpha")
		var composed := factory.get_visible_albedo(asset)
		var composed_clear := (
			_transparent_fraction(composed.get_image())
			if composed != null
			else -1.0
		)
		var status := ""
		if composed_clear >= 0.0:
			status = "OK          composed alpha present (%.0f%% clear)" % (composed_clear * 100.0)
			fine += 1
		elif has_alpha_channel:
			status = "BROKEN      alpha channel bound but composed albedo is opaque"
			broken += 1
		else:
			status = "NEEDS REPAIR no alpha channel bound; cut exists on disk"
			repairable += 1
		print("%-12s %s" % [asset.asset_id.substr(0, 44), status])

	print("")
	print("SUMMARY ok=%d needs_repair=%d broken=%d" % [fine, repairable, broken])
	quit()
