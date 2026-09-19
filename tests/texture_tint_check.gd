extends SceneTree

## Focused regression check for per-texture tint ownership and every visible material consumer.

var _failures: int = 0


## Defer until the tree is ready so the inspector receives its normal Control lifecycle.
func _init() -> void:
	_run.call_deferred()


## Verify persistence, UI state, base/layer shader binding, and native Decal tinting.
func _run() -> void:
	var asset := _surface_asset()
	asset.surface_tint_color = Color(0.2, 0.45, 0.8)
	asset.surface_tint_strength = 0.35

	var saved_path := "user://texture_tint_check.tres"
	_check(
		ResourceSaver.save(asset, saved_path) == OK,
		"a texture with tint saves as one asset resource"
	)
	var restored := ResourceLoader.load(
		saved_path,
		"",
		ResourceLoader.CACHE_MODE_IGNORE
	) as TileAsset
	_check(
		restored != null
		and restored.surface_tint_color.is_equal_approx(asset.surface_tint_color)
		and is_equal_approx(restored.surface_tint_strength, asset.surface_tint_strength),
		"texture tint colour and strength reload without board-global state"
	)

	_check(
		not ProjectSettings.has_setting("shader_globals/mts_surface_tint"),
		"the removed board-global tint cannot multiply every texture a second time"
	)
	var factory := SurfaceMaterialFactory.new()
	var material := factory.get_material(asset) as ShaderMaterial
	_check(material != null, "a tinted texture builds the canonical surface material")
	if material != null:
		_check(
			not material.shader.code.contains("mts_surface_tint"),
			"the canonical shader has one per-texture tint path and no global tint path"
		)
		var base_tint: Color = material.get_shader_parameter("texture_tint_color")
		_check(
			base_tint.is_equal_approx(asset.surface_tint_color)
			and is_equal_approx(
				float(material.get_shader_parameter("texture_tint_strength")),
				asset.surface_tint_strength
			),
			"the base shader consumes this texture's exact tint controls"
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
		var layer_tint: Color = material.get_shader_parameter(
			"material_layer_0_tint_color"
		)
		_check(
			layer_tint.is_equal_approx(asset.surface_tint_color)
			and is_equal_approx(
				float(material.get_shader_parameter("material_layer_0_tint_strength")),
				asset.surface_tint_strength
			),
			"the same texture keeps its tint as a painted material layer"
		)

	var decal := Decal.new()
	_check(factory.configure_decal(decal, asset), "the texture configures a native Decal")
	var expected_decal_tint := Color.WHITE.lerp(
		asset.surface_tint_color,
		asset.surface_tint_strength
	)
	_check(
		decal.modulate.is_equal_approx(expected_decal_tint),
		"the native Decal consumes the same tint colour and strength"
	)
	decal.free()

	var inspector := AssetInspectorPanel.new()
	get_root().add_child(inspector)
	inspector.set_asset(asset)
	_check(
		inspector._surface_tint_picker != null
		and inspector._surface_tint_picker.color.is_equal_approx(asset.surface_tint_color)
		and inspector._surface_tint_strength_slider != null
		and is_equal_approx(
			inspector._surface_tint_strength_slider.value,
			asset.surface_tint_strength
		),
		"the selected texture inspector exposes the exact stored tint controls"
	)
	var edited_tint := Color(0.8, 0.3, 0.15)
	inspector._surface_tint_picker.color = edited_tint
	inspector._surface_tint_picker.popup_closed.emit()
	inspector._surface_tint_strength_slider.value = 0.6
	_check(
		asset.surface_tint_color.is_equal_approx(edited_tint)
		and is_equal_approx(asset.surface_tint_strength, 0.6),
		"the visible Tint controls edit the same asset values the renderer consumes"
	)
	inspector.free()

	if _failures > 0:
		push_error("texture_tint_check: %d failure(s)" % _failures)
		quit(1)
		return
	print("texture_tint_check: PASS")
	quit(0)


## Build one complete PNG surface asset without relying on project library data.
func _surface_asset() -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = "TEST_TEXTURE_TINT"
	asset.display_name = "Test Texture Tint"
	asset.source_type = MTSConstants.SourceType.IMAGE_SURFACE
	asset.source_path = "res://icon.svg"
	asset.grid_bounds = Vector3i.ONE
	asset.visual_size_m = Vector3(1.0, 1.0, 0.0)
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", asset.source_path)
	asset.gbuffer.set_channel("normal", asset.source_path)
	asset.gbuffer.set_channel("orm", asset.source_path)
	asset.gbuffer.set_channel("emission", asset.source_path)
	return asset


## Record one failure while letting the remaining tint consumers report their own result.
func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("texture_tint_check: %s" % message)
