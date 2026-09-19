extends SceneTree

## Focused regression coverage for offline PBR channel baking and material AO defaults.

var _failures: PackedStringArray = PackedStringArray()


## Run the isolated checks immediately; modified project scripts are loaded explicitly by path below.
func _init() -> void:
	_run()


## Exercise the exact former runtime blend formulas against tiny deterministic images.
func _run() -> void:
	var pipeline_script: Script = load("res://addons/modular_tile_studio/analysis/derived_map_pipeline.gd")
	var map_set_script: Script = load("res://addons/modular_tile_studio/data/gbuffer_map_set.gd")
	var lighting_script: Script = load("res://addons/modular_tile_studio/data/lighting_profile.gd")
	var pipeline: Variant = pipeline_script.new()
	var maps: Variant = map_set_script.new()
	var lighting: Variant = lighting_script.new()

	var ao := _pixel_image(Color(0.8, 0.8, 0.8, 1.0))
	var roughness := _pixel_image(Color(0.4, 0.4, 0.4, 1.0))
	var metallic := _pixel_image(Color(0.2, 0.2, 0.2, 1.0))
	var cavity := _pixel_image(Color(0.5, 0.5, 0.5, 1.0))
	var curvature := _pixel_image(Color(0.75, 0.75, 0.75, 1.0))
	var orm: Image = pipeline.pack_orm(
		ao,
		roughness,
		metallic,
		cavity,
		curvature,
		1.0,
		1.0
	)
	var packed := orm.get_pixel(0, 0)
	# RGBA8 input and RGB8 output both use Godot's truncating byte conversion, so
	# 0.5 becomes 127/255 and the multiplied AO result becomes exactly 101/255.
	_check(is_equal_approx(packed.r, 101.0 / 255.0), "Cavity was not baked into ORM AO.")
	_check(is_equal_approx(packed.g, 38.0 / 255.0), "Curvature was not baked into ORM roughness.")
	_check(is_equal_approx(packed.b, 51.0 / 255.0), "Metallic did not survive ORM packing.")

	var base_normal := _pixel_image(Color(0.5, 0.5, 1.0, 1.0))
	var detail_normal := _pixel_image(Color(0.75, 0.5, 0.9330127, 1.0))
	var unchanged: Image = pipeline.combine_tangent_normals(base_normal, detail_normal, 0.0)
	var combined: Image = pipeline.combine_tangent_normals(base_normal, detail_normal, 1.0)
	_check(unchanged.get_pixel(0, 0).r == base_normal.get_pixel(0, 0).r, "Zero detail strength changed the base normal.")
	_check(combined.get_pixel(0, 0).r > unchanged.get_pixel(0, 0).r, "Detail normal was not baked into the primary normal.")

	_check(maps.is_bake_strength("cavity"), "Cavity is not identified as a bake-time control.")
	_check(maps.is_bake_strength("curvature"), "Curvature is not identified as a bake-time control.")
	_check(maps.is_bake_strength("detail_normal"), "Detail normal is not identified as a bake-time control.")
	_check(not maps.is_bake_strength("ambient_occlusion"), "Live AO strength was incorrectly converted to a bake-only control.")
	_check(is_equal_approx(lighting.material_ao_light_affect, 0.25), "Material AO light affect did not default to 0.25.")
	_check(not lighting.ssao_enabled, "SSAO must remain disabled by default.")

	if _failures.is_empty():
		print("RUNTIME_MAP_BAKE_CHECK: PASS")
		quit(0)
		return
	for failure: String in _failures:
		push_error("RUNTIME_MAP_BAKE_CHECK: %s" % failure)
	quit(1)


## Create one uncompressed RGBA test image with a single known pixel.
func _pixel_image(value: Color) -> Image:
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, value)
	return image


## Record one failed invariant while allowing the remaining checks to run.
func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
