@tool
extends SceneTree

## One-shot migration of pre-rework GLB props onto the facing-variant pipeline.
##
## Old props stored their spatial truth as three separate things -- an occupancy
## voxel set, a set of sprite anchors, and a depth window -- each derived through
## its own path and each free to drift from the others. There is no arithmetic
## that can reconcile them after the fact, so this does not try to convert
## anything: it re-derives every prop from its untouched source GLB, which is
## the whole point of having kept the source.
##
## The old sizing INTENT is preserved. A prop that was authored proportionally at
## 3 m tall is rebuilt proportionally at 3 cells tall; one that was stretched to
## an exact box is rebuilt stretched to that same box.
##
## Run with a REAL rendering driver -- NOT --headless:
##
##   godot --path . --script tools/migrate_glb_props.gd
##
## The rebuild renders each facing through a SubViewport and waits on
## RenderingServer.frame_post_draw. Godot's headless dummy driver never draws a
## frame, so that signal never arrives and the migration hangs rather than
## failing. A windowed run is what actually produces the images.

const K := preload("res://addons/modular_tile_studio/utils/mts_constants.gd")
const GLBImporter := preload("res://addons/modular_tile_studio/importers/glb_asset_importer.gd")


func _init() -> void:
	# The renderer awaits process_frame, which only ever arrives once the tree is
	# running. _init() executes before that, so the work is deferred by one idle
	# frame rather than being started here.
	_run.call_deferred()


func _run() -> void:
	var library := AssetLibrary.load_or_create()

	if library == null:
		push_error("[migrate] could not open the asset library")
		quit(1)
		return

	var importer := GLBImporter.new()

	# The renderer needs a node inside a live tree to host its SubViewport.
	var host := Node.new()
	root.add_child(host)

	var props: Array[TileAsset] = []
	for asset in library.assets:
		if asset != null and asset.is_prop():
			props.append(asset)

	if props.is_empty():
		print("[migrate] no GLB props in the library; nothing to do.")
		quit(0)
		return

	print("[migrate] %d GLB prop(s) to rebuild.\n" % props.size())

	var succeeded := 0
	var failed := 0

	for asset in props:
		var settings := _settings_for(asset)

		print("[migrate] %s -> grid %d x %d x %d, driver axis %d, stretch %s" % [
			asset.asset_id,
			settings["grid_size"].x,
			settings["grid_size"].y,
			settings["grid_size"].z,
			settings["driver_axis"],
			str(settings["stretch_to_grid"]),
		])

		var ok: bool = importer.rebuild_prop(asset, settings)

		if ok:
			succeeded += 1
		else:
			failed += 1
			push_error("[migrate] FAILED: %s (left untouched)" % asset.asset_id)

	library.save()

	print("\n[migrate] done: %d rebuilt, %d failed." % [succeeded, failed])

	if failed > 0:
		print("[migrate] failed props keep their previous data and can be retried.")

	quit(0 if failed == 0 else 1)


## Recover the sizing intent an old asset was authored with.
##
## Old assets recorded metres and a stretch mode rather than cells and a driver
## axis. The grid box is the cells that size already claimed, so it converts
## directly; the driver axis is taken as the one whose old target was a whole
## number, since that is the number the user actually typed.
func _settings_for(asset: TileAsset) -> Dictionary:
	var stretched := String(asset.processing.get("stretch_mode", "proportional")) == "exact"

	# grid_bounds is what the old pipeline already claimed on the lattice.
	var grid := Vector3i(
		maxi(1, asset.grid_bounds.x),
		maxi(1, asset.grid_bounds.y),
		maxi(1, asset.grid_bounds.z)
	)

	if grid == Vector3i.ONE and asset.visual_size_m != Vector3.ZERO:
		grid = Vector3i(
			maxi(1, ceili(asset.visual_size_m.x - 0.001)),
			maxi(1, ceili(asset.visual_size_m.y - 0.001)),
			maxi(1, ceili(asset.visual_size_m.z - 0.001))
		)

	return {
		"grid_size": grid,
		"driver_axis": _driver_axis_for(asset),
		"stretch_to_grid": stretched,
	}


## Which axis the user most likely typed.
##
## Under the old proportional mode exactly one axis was entered by hand and the
## rest were computed from it, so the hand-entered one is whichever came out a
## round number. Height is the tiebreak: it is the dimension people actually
## think in for a prop, and it is what the new dialog defaults to.
func _driver_axis_for(asset: TileAsset) -> int:
	var target: Array = asset.processing.get("target_size", [])

	if target.size() >= 3:
		# Prefer Y when it is already whole.
		for axis in [1, 0, 2]:
			var value := float(target[axis])
			if absf(value - roundf(value)) < 0.0001:
				return axis

	return 1
