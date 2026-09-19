@tool
extends SceneTree

## Generates the minimum demo kit (spec 55) as placeholder art.
##
##   godot --headless --script res://tools/make_demo_assets.gd
##
## These are deliberately simple procedural tiles, not finished art: their job is
## to exercise the pipeline (import -> paint -> tile -> save -> reload) before
## real Meshy/SD assets arrive. Each is generated to tile seamlessly so the
## tiling test has something honest to show.

const OUT_DIR := "res://tile_library/sources/images"

const TILE_PX := 256


func _init() -> void:
	print("\n=== generating demo surface tiles ===\n")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	_save(_stone_floor(Color(0.62, 0.58, 0.50), 4), "demo_floor_flagstone.png")
	_save(_stone_floor(Color(0.45, 0.47, 0.44), 2), "demo_floor_slab.png")
	_save(_sand_floor(), "demo_floor_sand.png")

	_save(_brick_wall(Color(0.60, 0.53, 0.43)), "demo_wall_brick.png")
	_save(_block_wall(Color(0.52, 0.50, 0.47)), "demo_wall_block.png")
	_save(_plaster_wall(), "demo_wall_plaster.png")

	_save(_corner_facade(), "demo_corner_facade.png")
	_save(_doorway(), "demo_doorway.png")

	print("\nDone. Import these with 'Import Image' in Tile Studio.")
	print("Suggested sizes: floors 2x2 m, walls 3x2 m, corner 2x2 m, doorway 2x3 m.\n")
	quit()


func _save(image: Image, filename: String) -> void:
	var path := OUT_DIR.path_join(filename)
	var err := image.save_png(ProjectSettings.globalize_path(path))
	if err == OK:
		print("  wrote %s" % path)
	else:
		print("  FAILED %s (%s)" % [path, error_string(err)])


# --- Generators -----------------------------------------------------------
#
# Every pattern wraps at the tile edge so repeats do not show a hard seam.

func _stone_floor(base: Color, blocks: int) -> Image:
	var image := Image.create(TILE_PX, TILE_PX, false, Image.FORMAT_RGBA8)
	var cell := TILE_PX / blocks
	for y in TILE_PX:
		for x in TILE_PX:
			var gx := x % cell
			var gy := y % cell
			# Mortar gutter between blocks.
			var is_joint := gx < 3 or gy < 3
			var shade := _noise(x, y, 0.09) * 0.14
			var colour := base.darkened(0.35) if is_joint else base.lightened(shade)
			# Per-block tint so the repeat is less obvious.
			if not is_joint:
				var block_id := (x / cell) * 31 + (y / cell) * 17
				colour = colour.lightened(fmod(float(block_id) * 0.137, 0.10) - 0.05)
			image.set_pixel(x, y, colour)
	return image


func _sand_floor() -> Image:
	var image := Image.create(TILE_PX, TILE_PX, false, Image.FORMAT_RGBA8)
	var base := Color(0.78, 0.68, 0.48)
	for y in TILE_PX:
		for x in TILE_PX:
			var ripple := sin(float(x) * TAU * 3.0 / TILE_PX + _noise(x, y, 0.05) * 2.0) * 0.04
			var grain := _noise(x, y, 0.5) * 0.10
			image.set_pixel(x, y, base.lightened(ripple + grain))
	return image


func _brick_wall(base: Color) -> Image:
	var image := Image.create(TILE_PX, TILE_PX, false, Image.FORMAT_RGBA8)
	var rows := 8
	var row_h := TILE_PX / rows
	var brick_w := TILE_PX / 4
	for y in TILE_PX:
		var row := y / row_h
		# Alternate courses offset by half a brick.
		var offset := (row % 2) * (brick_w / 2)
		for x in TILE_PX:
			var bx := (x + offset) % brick_w
			var by := y % row_h
			var is_joint := bx < 3 or by < 3
			var shade := _noise(x, y, 0.12) * 0.12
			var colour := base.darkened(0.40) if is_joint else base.lightened(shade)
			image.set_pixel(x, y, colour)
	return image


func _block_wall(base: Color) -> Image:
	var image := Image.create(TILE_PX, TILE_PX, false, Image.FORMAT_RGBA8)
	var cell := TILE_PX / 3
	for y in TILE_PX:
		for x in TILE_PX:
			var is_joint := (x % cell) < 4 or (y % cell) < 4
			var shade := _noise(x, y, 0.07) * 0.16
			image.set_pixel(x, y, base.darkened(0.35) if is_joint else base.lightened(shade))
	return image


func _plaster_wall() -> Image:
	var image := Image.create(TILE_PX, TILE_PX, false, Image.FORMAT_RGBA8)
	var base := Color(0.80, 0.75, 0.66)
	for y in TILE_PX:
		for x in TILE_PX:
			var blotch := _noise(x, y, 0.03) * 0.12
			var grain := _noise(x, y, 0.9) * 0.05
			# A crack running down the tile, wrapping at the edges.
			var crack := 0.0
			var crack_x := TILE_PX * 0.4 + sin(float(y) * TAU / TILE_PX * 2.0) * 12.0
			if absf(float(x) - crack_x) < 1.5:
				crack = -0.25
			image.set_pixel(x, y, base.lightened(blotch + grain + crack))
	return image


func _corner_facade() -> Image:
	var image := Image.create(TILE_PX, TILE_PX, false, Image.FORMAT_RGBA8)
	var base := Color(0.58, 0.54, 0.47)
	for y in TILE_PX:
		for x in TILE_PX:
			# Quoin stones stepping up the left edge mark this as a corner piece.
			var in_quoin := x < TILE_PX / 4 and ((y / (TILE_PX / 8)) % 2 == 0)
			var shade := _noise(x, y, 0.08) * 0.12
			var colour := base.lightened(shade)
			if in_quoin:
				colour = colour.lightened(0.14)
			if x % (TILE_PX / 4) < 3 or y % (TILE_PX / 4) < 3:
				colour = colour.darkened(0.35)
			image.set_pixel(x, y, colour)
	return image


func _doorway() -> Image:
	# 2 x 3 m, so the source is twice as tall as it is wide.
	var w := TILE_PX
	var h := TILE_PX * 3 / 2
	var image := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var base := Color(0.56, 0.52, 0.46)
	var opening := Rect2i(int(w * 0.28), int(h * 0.30), int(w * 0.44), int(h * 0.70))
	for y in h:
		for x in w:
			if opening.has_point(Vector2i(x, y)):
				# Dark interior with a suggestion of depth.
				var depth := float(y - opening.position.y) / float(maxi(opening.size.y, 1))
				image.set_pixel(x, y, Color(0.06, 0.05, 0.05).lightened(depth * 0.10))
				continue
			var shade := _noise(x, y, 0.08) * 0.12
			var colour := base.lightened(shade)
			# Arch highlight over the opening.
			var arch := Vector2(x - opening.get_center().x, y - opening.position.y)
			if arch.length() < opening.size.x * 0.62 and y < opening.position.y:
				colour = colour.lightened(0.12)
			if x % (w / 4) < 3 or y % (h / 6) < 3:
				colour = colour.darkened(0.30)
			image.set_pixel(x, y, colour)
	return image


## Cheap tileable value noise: sampled on a torus so it wraps at the edges.
func _noise(x: int, y: int, frequency: float) -> float:
	var fx := float(x) / TILE_PX * TAU
	var fy := float(y) / TILE_PX * TAU
	var scale := maxf(frequency, 0.001) * 40.0
	var v := sin(fx * scale) * cos(fy * scale * 1.31)
	v += sin(fx * scale * 2.17 + 1.3) * cos(fy * scale * 0.71 + 0.7) * 0.5
	v += sin((fx + fy) * scale * 3.11 + 2.1) * 0.25
	return clampf(v * 0.5 + 0.5, 0.0, 1.0) - 0.5
