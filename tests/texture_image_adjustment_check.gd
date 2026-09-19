extends SceneTree

## Focused regression check for per-texture image adjustments and their reset action.

const SOURCE_PATH := "user://texture_image_adjustment_source.png"

var _failures: int = 0


## Defer until the tree is ready so the custom inspector receives its normal Control lifecycle.
func _init() -> void:
	_run.call_deferred()


## Verify persistence, pixel processing, every material consumer, UI editing, and reset behavior.
func _run() -> void:
	_check(_write_source_image(), "the deterministic image-adjustment fixture saves")
	var asset := _surface_asset()
	var factory := SurfaceMaterialFactory.new()
	var neutral_texture := factory.get_visible_albedo(asset)
	_check(neutral_texture != null, "the neutral texture resolves its visible albedo")

	asset.surface_sharpness = 1.0
	var sharpened_texture := factory.get_visible_albedo(asset)
	_check(
		sharpened_texture != null
		and not _texture_pixel_rgb(sharpened_texture).is_equal_approx(
			_texture_pixel_rgb(neutral_texture)
		),
		"Sharpness alone changes a luminance edge"
	)

	asset.surface_sharpness = -1.0
	var softened_texture := factory.get_visible_albedo(asset)
	# The fixture's centre pixel is darker than its neighbours, so the one signed
	# detail axis has to move it in opposite directions: softening onto the
	# neighbouring luminance average and sharpening away from it.
	_check(
		softened_texture != null
		and sharpened_texture != null
		and neutral_texture != null
		and _pixel_luminance(softened_texture) > _pixel_luminance(neutral_texture)
		and _pixel_luminance(sharpened_texture) < _pixel_luminance(neutral_texture),
		"Negative detail softens the centre pixel while positive detail sharpens it"
	)

	asset.surface_brightness = 1.25
	asset.surface_contrast = 1.3
	asset.surface_saturation = 0.45
	asset.surface_sharpness = 0.6
	asset.surface_hue_shift_degrees = 52.0
	var adjusted_texture := factory.get_visible_albedo(asset)
	_check(adjusted_texture != null, "the five authored image adjustments produce one visible albedo")
	if adjusted_texture != null and neutral_texture != null:
		var adjusted_pixel := adjusted_texture.get_image().get_pixel(1, 1)
		var neutral_pixel := neutral_texture.get_image().get_pixel(1, 1)
		_check(
			not Vector3(adjusted_pixel.r, adjusted_pixel.g, adjusted_pixel.b).is_equal_approx(
				Vector3(neutral_pixel.r, neutral_pixel.g, neutral_pixel.b)
			),
			"the combined controls visibly change RGB"
		)
		_check(
			is_equal_approx(adjusted_pixel.a, neutral_pixel.a),
			"image adjustments preserve the source alpha exactly"
		)

	var saved_path := "user://texture_image_adjustment_check.tres"
	_check(ResourceSaver.save(asset, saved_path) == OK, "the adjusted texture saves as one asset resource")
	var restored := ResourceLoader.load(
		saved_path,
		"",
		ResourceLoader.CACHE_MODE_IGNORE
	) as TileAsset
	_check(
		restored != null
		and is_equal_approx(restored.surface_brightness, asset.surface_brightness)
		and is_equal_approx(restored.surface_contrast, asset.surface_contrast)
		and is_equal_approx(restored.surface_saturation, asset.surface_saturation)
		and is_equal_approx(restored.surface_sharpness, asset.surface_sharpness)
		and is_equal_approx(restored.surface_hue_shift_degrees, asset.surface_hue_shift_degrees),
		"all five image adjustments reload from the texture asset"
	)

	factory.invalidate(asset.asset_id)
	var material := factory.get_material(asset) as ShaderMaterial
	_check(material != null, "the adjusted texture builds the canonical surface material")
	if material != null and adjusted_texture != null:
		var base_albedo := material.get_shader_parameter("albedo_tex") as Texture2D
		_check(
			base_albedo != null
			and _texture_pixel_rgb(base_albedo).is_equal_approx(_texture_pixel_rgb(adjusted_texture)),
			"base terrain consumes the adjusted visible albedo"
		)

		var library := AssetLibrary.new()
		library.add_asset(asset)
		var profile := MaterialBlendProfile.new()
		profile.enabled = true
		var layer := profile.layer(0)
		layer["enabled"] = true
		layer["asset_id"] = asset.asset_id
		profile.set_layer(0, layer)
		factory.configure_material_blend(
			material,
			null,
			profile,
			library,
			Vector2(0.0, 1.0),
			Vector2(0.0, 1.0)
		)
		var layer_albedo := material.get_shader_parameter("material_layer_0_albedo_tex") as Texture2D
		_check(
			layer_albedo != null
			and _texture_pixel_rgb(layer_albedo).is_equal_approx(_texture_pixel_rgb(adjusted_texture)),
			"painted material layers consume the same adjusted visible albedo"
		)

	var decal := Decal.new()
	_check(factory.configure_decal(decal, asset), "the adjusted texture configures a native Decal")
	_check(
		decal.texture_albedo != null
		and adjusted_texture != null
		and _texture_pixel_rgb(decal.texture_albedo).is_equal_approx(
			_texture_pixel_rgb(adjusted_texture)
		),
		"native Decals consume the same adjusted visible albedo"
	)
	decal.free()

	var inspector := AssetInspectorPanel.new()
	get_root().add_child(inspector)
	inspector.set_asset(asset)
	_check(
		inspector._surface_image_adjustment_sliders.size() == 5
		and is_equal_approx(
			(inspector._surface_image_adjustment_sliders["brightness"] as HSlider).value,
			asset.surface_brightness
		)
		and is_equal_approx(
			(inspector._surface_image_adjustment_sliders["hue_shift_degrees"] as HSlider).value,
			asset.surface_hue_shift_degrees
		),
		"the selected texture inspector exposes the exact stored image adjustments"
	)
	(inspector._surface_image_adjustment_sliders["contrast"] as HSlider).value = 0.75
	_check(
		is_equal_approx(asset.surface_contrast, 0.75),
		"an image-adjustment slider edits the same TileAsset value rendering consumes"
	)
	_check(
		inspector._surface_image_adjustment_reset_button != null
		and not inspector._surface_image_adjustment_reset_button.disabled,
		"Reset image adjustments is available while any value is non-neutral"
	)
	inspector._surface_image_adjustment_reset_button.pressed.emit()
	_check(
		asset.surface_image_adjustments_are_default(),
		"Reset image adjustments restores all five neutral defaults together"
	)
	_check(
		asset.surface_tint_color == Color.WHITE
		and is_zero_approx(asset.surface_tint_strength),
		"resetting image adjustments does not silently change the separate Tint controls"
	)
	inspector.free()

	if _failures > 0:
		push_error("texture_image_adjustment_check: %d failure(s)" % _failures)
		quit(1)
		return
	print("texture_image_adjustment_check: PASS")
	quit(0)


## Write a small colour-and-luminance edge fixture whose centre pixel also carries fractional alpha.
func _write_source_image() -> bool:
	var image := Image.create(3, 3, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.18, 0.42, 0.66, 0.35))
	image.set_pixel(1, 1, Color(0.88, 0.16, 0.08, 0.65))
	return image.save_png(ProjectSettings.globalize_path(SOURCE_PATH)) == OK


## Build one complete PNG surface asset without relying on project library data.
func _surface_asset() -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = "TEST_TEXTURE_IMAGE_ADJUSTMENTS"
	asset.display_name = "Test Texture Image Adjustments"
	asset.source_type = MTSConstants.SourceType.IMAGE_SURFACE
	asset.source_path = SOURCE_PATH
	asset.grid_bounds = Vector3i.ONE
	asset.visual_size_m = Vector3(1.0, 1.0, 0.0)
	asset.surface_alpha_mode = TileAsset.SurfaceAlphaMode.BLEND
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", SOURCE_PATH)
	return asset


## Return the centre pixel RGB used by every material-consumer comparison.
func _texture_pixel_rgb(texture: Texture2D) -> Vector3:
	var pixel := texture.get_image().get_pixel(1, 1)
	return Vector3(pixel.r, pixel.g, pixel.b)


## Return the centre pixel's luminance under the same weights the adjustment pass uses.
func _pixel_luminance(texture: Texture2D) -> float:
	return _texture_pixel_rgb(texture).dot(SurfaceMaterialFactory.IMAGE_LUMA_WEIGHTS)


## Record one failure while allowing all independent adjustment consumers to report.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("texture_image_adjustment_check: %s" % message)
