@tool
extends SceneTree

var _failed: int = 0
var _paint_script: Script = load(
	"res://addons/modular_tile_studio/rendering/surface_material_paint.gd"
)


## Exercise sparse painting, splat normalization, persistence, height ranges, and shader binding.
func _init() -> void:
	print("\n=== Material paint pipeline check ===")
	var profile := MaterialBlendProfile.new()
	profile.enabled = true
	profile.blend_mode = MaterialBlendProfile.BlendMode.NORMALIZED_SPLAT
	profile.splatmap_source_path = "user://terrain_rgba.png"
	var painter := _paint_script.new() as MTSSurfaceMaterialPaint
	painter.bind_profile(profile)

	# Paint is keyed by canonical TerrainMesh face identities, so the test paints a
	# real terrain face rather than a synthetic placement UID.
	var uid := TerrainMesh.cell_top_uid(Vector2i(0, 0))
	painter.register_batch("BASE|0|0|0", PackedStringArray([uid]), Vector2i(2, 2))
	_check(
		painter.control_classification_for_uid(uid)
		== Vector2i(MTSSurfaceMaterialPaint.CONTROL_CLASS_BASE_ONLY, -1),
		"an unpainted face is classified for the base-only shader path"
	)
	_check(
		is_zero_approx(painter.instance_layer_color("BASE|0|0|0", uid).b),
		"the base-only classification reaches the instance-colour shader metadata"
	)
	painter.begin_stroke()
	_check(
		painter.brush_segment(
			uid,
			Vector2i(2, 2),
			Vector2(0.5, 0.5),
			Vector2(0.75, 0.5),
			0.3,
			0.8,
			0.9,
			0,
			0,
			false
		),
		"a metric swept brush changes pixels"
	)
	var recorded_pixel_count := (
		painter._stroke_before.get(uid, {}) as Dictionary
	).size()
	for _sample: int in 24:
		painter.brush_segment(
			uid,
			Vector2i(2, 2),
			Vector2(0.5, 0.5),
			Vector2(0.75, 0.5),
			0.3,
			0.8,
			0.9,
			0,
			0,
			false
		)
	_check(
		(painter._stroke_before.get(uid, {}) as Dictionary).size()
		== recorded_pixel_count,
		"overlapping drag samples do not rewrite or duplicate sparse undo data"
	)
	var stroke := painter.finish_stroke()
	_check(not stroke.is_empty(), "one stroke records a sparse undo patch")
	_check(
		painter.control_classification_for_uid(uid).x
		== MTSSurfaceMaterialPaint.CONTROL_CLASS_MIXED,
		"a partially painted face is classified for the single-read mixed path"
	)
	_check(
		is_equal_approx(painter.instance_layer_color("BASE|0|0|0", uid).b, 1.0),
		"the mixed classification reaches the instance-colour shader metadata"
	)
	_check(
		painter.upload_dirty() == 0,
		"first-touch array creation does not repeat the same placement upload"
	)
	var image := painter.image_for_uid(uid)
	var center := image.get_pixel(image.get_width() / 2, image.get_height() / 2)
	_check(
		center.r + center.g + center.b + center.a <= 1.001,
		"true splat weights stay normalized"
	)
	var far_corner := image.get_pixel(0, 0)
	_check(
		is_zero_approx(
			far_corner.r + far_corner.g + far_corner.b + far_corner.a
		),
		"pixels outside the circular capsule remain exactly unchanged"
	)
	var patches: Dictionary = stroke.get("patches", {})
	painter.apply_patch(patches, "before")
	painter.upload_dirty()
	var restored := image.get_pixel(image.get_width() / 2, image.get_height() / 2)
	_check(restored.is_equal_approx(Color(0, 0, 0, 0)), "sparse undo restores original pixels")
	painter.apply_patch(patches, "after")
	painter.upload_dirty()
	var channel_clear := painter.clear_palette_material(0)
	_check(not channel_clear.is_empty(), "channel removal records a sparse undo patch")
	_check(not painter.has_image(uid), "channel removal prunes a now-empty canonical image")
	painter.apply_patch(channel_clear, "before")
	painter.upload_dirty()
	var channel_restored := painter.image_for_uid(uid)
	_check(
		channel_restored != null
		and channel_restored.get_pixel(
			channel_restored.get_width() / 2,
			channel_restored.get_height() / 2
		).r > 0.0,
		"palette-material undo restores only its changed pixels"
	)

	var original_face_bytes := channel_restored.get_data()
	# A fifth board material must consume a face-local zero-weight slot without
	# changing the RGBA meaning or pixels of any other face.
	var fifth_palette_index := profile.add_layer(
		MaterialBlendProfile.default_layer(profile.layer_count())
	)
	var fifth_layer := profile.layer(fifth_palette_index)
	fifth_layer["asset_id"] = "FIFTH"
	fifth_layer["enabled"] = true
	profile.set_layer(fifth_palette_index, fifth_layer)
	_check(profile.layer_count() == 5, "the board palette grows beyond four materials")
	var fifth_uid := TerrainMesh.cell_top_uid(Vector2i(5, 0))
	painter.register_batch("FIFTH_FACE", PackedStringArray([fifth_uid]), Vector2i.ONE)
	var original_fifth_slots := painter.palette_slots_for_uid(fifth_uid)
	_check(
		not painter.used_palette_indices().has(fifth_palette_index),
		"configuring a material without paint does not make it a used level asset"
	)
	painter.begin_stroke()
	_check(
		painter.stamp_material_tile(fifth_uid, fifth_palette_index, 1.0, 1, false),
		"a fifth palette material paints onto a face with a reusable local slot"
	)
	var fifth_stroke := painter.finish_stroke()
	var fifth_slots := painter.palette_slots_for_uid(fifth_uid)
	_check(
		painter.used_palette_indices().has(fifth_palette_index)
		and fifth_slots.has(fifth_palette_index)
		and painter.slot_rotations_for_uid(fifth_uid)[
			fifth_slots.find(fifth_palette_index)
		] == 1
		and painter.palette_slots_for_uid(uid) == original_fifth_slots
		and painter.image_for_uid(uid).get_data() == original_face_bytes,
		"face-local assignment leaves another face's RGBA mapping and PNG bytes unchanged"
	)
	var fifth_patches: Dictionary = fifth_stroke.get("patches", {})
	painter.apply_patch(fifth_patches, "before")
	_check(
		not painter.used_palette_indices().has(fifth_palette_index)
		and painter.palette_slots_for_uid(fifth_uid) == original_fifth_slots
		and painter.slot_rotations_for_uid(fifth_uid) == PackedInt32Array([0, 0, 0, 0]),
		"paint undo restores the face's exact previous palette mapping"
	)
	painter.apply_patch(fifth_patches, "after")
	_check(
		painter.used_palette_indices().has(fifth_palette_index)
		and painter.palette_slots_for_uid(fifth_uid) == fifth_slots
		and painter.slot_rotations_for_uid(fifth_uid)[
			fifth_slots.find(fifth_palette_index)
		] == 1,
		"paint redo restores the face's fifth-material mapping"
	)
	_check(
		painter.control_classification_for_uid(fifth_uid)
		== Vector2i(
			MTSSurfaceMaterialPaint.CONTROL_CLASS_UNIFORM_LAYER,
			fifth_slots.find(fifth_palette_index)
		),
		"a fully weighted face names its one shader layer without a control read"
	)
	var uniform_instance_color: Color = painter.instance_layer_color(
		"FIFTH_FACE",
		fifth_uid
	)
	_check(
		is_equal_approx(uniform_instance_color.b, 0.5)
		and is_equal_approx(
			uniform_instance_color.a,
			float(fifth_slots.find(fifth_palette_index)) / 3.0
		),
		"the uniform layer and slot reach the instance-colour shader metadata"
	)

	# A face whose four components all carry real weight cannot accept a fifth
	# material, and the preflight must leave every face mapping untouched.
	var full_uid := TerrainMesh.cell_top_uid(Vector2i(6, 0))
	painter.register_batch("FULL_FACE", PackedStringArray([full_uid]), Vector2i.ONE)
	var full_template := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	full_template.fill(Color(0.25, 0.25, 0.25, 0.25))
	painter.begin_stroke()
	painter.stamp_splatmap_tile(
		full_uid,
		full_template,
		PackedInt32Array([0, 1, 2, 3]),
		false
	)
	painter.finish_stroke()
	_check(
		painter.control_classification_for_uid(full_uid).x
		== MTSSurfaceMaterialPaint.CONTROL_CLASS_MIXED,
		"four live control components remain on the mixed shader path"
	)
	var full_slots_before := painter.palette_slots_for_uid(full_uid)
	var full_assignment := painter.assign_palette_to_faces(
		fifth_palette_index,
		PackedStringArray([full_uid])
	)
	_check(
		int(full_assignment.get("error", OK)) == ERR_BUSY
		and painter.palette_slots_for_uid(full_uid) == full_slots_before,
		"a genuinely full face rejects a fifth material without partial mutation"
	)

	# A thin side band must read from its complete 1 m source without gaining a
	# duplicate authored image, then give way immediately to direct sliver paint.
	var seeded_painter := _paint_script.new() as MTSSurfaceMaterialPaint
	seeded_painter.bind_profile(profile)
	var source_uid := TerrainMesh.cell_top_uid(Vector2i(2, 2))
	var thin_side_uid := TerrainMesh.band_uid(
		Vector2i(2, 2),
		TerrainMesh.EDGE_EAST,
		2
	)
	seeded_painter.register_batch(
		"THIN_SIDE_SEED",
		PackedStringArray([source_uid, thin_side_uid]),
		Vector2i.ONE,
		{thin_side_uid: source_uid}
	)
	seeded_painter.begin_stroke()
	seeded_painter.brush_segment(
		source_uid,
		Vector2i.ONE,
		Vector2(0.5, 0.5),
		Vector2(0.5, 0.5),
		0.4,
		1.0,
		1.0,
		0,
		0,
		false
	)
	seeded_painter.finish_stroke()
	var source_image := seeded_painter.image_for_uid(source_uid)
	_check(
		source_image != null
		and not seeded_painter.has_image(thin_side_uid)
		and seeded_painter._visible_image_for_uid(
			thin_side_uid,
			seeded_painter._images_by_uid,
			{thin_side_uid: source_uid}
		) == source_image,
		"an unpainted thin side band reads its nearest full-square source image"
	)
	seeded_painter.begin_stroke()
	seeded_painter.brush_segment(
		thin_side_uid,
		Vector2i.ONE,
		Vector2(0.5, 0.5),
		Vector2(0.5, 0.5),
		0.4,
		1.0,
		1.0,
		1,
		0,
		false
	)
	seeded_painter.finish_stroke()
	_check(
		seeded_painter.has_image(thin_side_uid)
		and seeded_painter._visible_image_for_uid(
			thin_side_uid,
			seeded_painter._images_by_uid,
			{thin_side_uid: source_uid}
		) == seeded_painter.image_for_uid(thin_side_uid),
		"direct paint on a thin side band overrides its derived source image"
	)

	var resolution_snapshot := painter.capture_png_snapshot()
	_check(
		int(resolution_snapshot.get("error", FAILED)) == OK,
		"resolution rebuild captures exact compressed undo paint"
	)
	var low_memory_profile := MaterialBlendProfile.new()
	low_memory_profile.from_json(profile.to_json())
	low_memory_profile.paint_texels_per_metre = 8
	low_memory_profile.maximum_surface_edge_px = 32
	var current_memory := painter.paint_memory_bytes()
	var requested_memory := painter.paint_memory_bytes(low_memory_profile)
	_check(
		int(current_memory.get("total_bytes", 0))
		> int(requested_memory.get("total_bytes", 0)),
		"visible lower resolution settings calculate a smaller canonical plus GPU allocation"
	)
	var low_resolution_prepared := painter.prepare_resolution_rebuild(low_memory_profile)
	_check(
		int(low_resolution_prepared.get("error", FAILED)) == OK
		and painter.commit_prepared_images(low_resolution_prepared),
		"paint resolution rebuild prepares every image and texture array before committing"
	)
	_check(
		painter.image_for_uid(uid).get_size()
		== low_memory_profile.paint_resolution(Vector2i(2, 2)),
		"committed paint uses the requested texel density and edge cap"
	)
	var exact_restore_prepared := painter.prepare_png_snapshot(resolution_snapshot)
	_check(
		int(exact_restore_prepared.get("error", FAILED)) == OK
		and painter.commit_prepared_images(exact_restore_prepared),
		"resolution undo restores the exact pre-resample PNG weights"
	)
	channel_restored = painter.image_for_uid(uid)
	_check(
		channel_restored.get_size() == profile.paint_resolution(Vector2i(2, 2)),
		"resolution undo restores the original canonical dimensions"
	)

	var board_path := "user://material_paint_check/board.json"
	var saved := painter.save_sidecars(board_path)
	_check(int(saved.get("error", FAILED)) == OK, "paint sidecar saves with checksum metadata")
	var saved_metadata: Dictionary = saved.get("metadata", {})
	_check(
		int(saved_metadata.get("version", 0)) == 3
		and (saved_metadata.get("material_slots", []) as Array).size() >= 3,
		"paint metadata version 3 persists face-local palette mappings and orientations"
	)
	# Boundary-skirt walls use canonical k: identities and must survive the same sidecar save.
	var skirt_uid := "k:-1,-14,0,1"
	var skirt_painter := _paint_script.new() as MTSSurfaceMaterialPaint
	skirt_painter.bind_profile(profile)
	skirt_painter.register_batch(
		"SKIRT|0|0|0",
		PackedStringArray([skirt_uid]),
		Vector2i.ONE
	)
	skirt_painter.begin_stroke()
	skirt_painter.stamp_material_tile(skirt_uid, 3, 1.0, 0, false)
	skirt_painter.finish_stroke()
	var skirt_saved := skirt_painter.save_sidecars(
		board_path,
		{skirt_uid: true}
	)
	var skirt_metadata: Dictionary = skirt_saved.get("metadata", {})
	var skirt_entries: Array = skirt_metadata.get("surfaces", [])
	_check(
		int(skirt_saved.get("error", FAILED)) == OK
		and skirt_entries.size() == 1
		and String((skirt_entries[0] as Dictionary).get("uid", "")) == skirt_uid,
		"boundary-skirt wall paint saves with its canonical k: UID"
	)
	var filtered := painter.save_sidecars(board_path, {})
	var filtered_metadata: Dictionary = filtered.get("metadata", {})
	var filtered_entries: Array = filtered_metadata.get("surfaces", [])
	_check(filtered_entries.is_empty(), "save metadata omits paint retained only for undo")
	var restored_painter := _paint_script.new() as MTSSurfaceMaterialPaint
	restored_painter.bind_profile(profile)
	var prepared := restored_painter.prepare_sidecars(
		board_path,
		saved.get("metadata", {})
	)
	_check(int(prepared.get("error", FAILED)) == OK, "paint sidecar preflight succeeds")
	_check(restored_painter.commit_prepared_sidecars(prepared), "prepared paint commits atomically")
	_check(restored_painter.has_image(uid), "restored paint keeps the placement UID")
	_check(
		restored_painter.slot_rotations_for_uid(fifth_uid)
		== painter.slot_rotations_for_uid(fifth_uid),
		"paint sidecars restore each face-local material PNG orientation"
	)

	# Version-1 sidecars had no mapping table, so registration must derive the historical
	# identity meaning without altering any saved RGBA weight byte.
	var legacy_metadata := (saved.get("metadata", {}) as Dictionary).duplicate(true)
	legacy_metadata["version"] = 1
	legacy_metadata.erase("material_slots")
	var legacy_painter := _paint_script.new() as MTSSurfaceMaterialPaint
	legacy_painter.bind_profile(profile)
	var legacy_prepared := legacy_painter.prepare_sidecars(board_path, legacy_metadata)
	_check(
		int(legacy_prepared.get("error", FAILED)) == OK
		and legacy_painter.commit_prepared_sidecars(legacy_prepared),
		"version-1 paint sidecars load without an explicit face mapping"
	)
	legacy_painter.register_face_palette(uid)
	_check(
		legacy_painter.palette_slots_for_uid(uid) == PackedInt32Array([0, 1, 2, 3])
		and legacy_painter.image_for_uid(uid).get_data()
		== painter.image_for_uid(uid).get_data(),
		"version-1 RGBA bytes keep their historical palette identity during migration"
	)

	var clear_all_patch := restored_painter.clear_all_paint()
	_check(not clear_all_patch.is_empty(), "clear brush paint records a sparse undo patch")
	_check(not restored_painter.has_image(uid), "clear brush paint removes canonical images")
	restored_painter.apply_patch(clear_all_patch, "before")
	_check(restored_painter.has_image(uid), "clear brush paint undo recreates canonical images")

	var roundtrip_library := AssetLibrary.new()
	roundtrip_library.add_asset(_surface_asset("BASE"))
	var board := BoardDocument.new()
	board.bind_library(roundtrip_library)
	# The painted UID must resolve to real canonical terrain during strict board validation.
	board.terrain = TerrainMesh.create(Vector2i.ZERO, Vector2i.ONE)
	board.terrain.set_cell_filled(Vector2i.ZERO, true)
	# A surface placement is exactly the set of canonical terrain faces it paints,
	# so the roundtrip asserts that terrain identity survives board JSON.
	var painted_surface := SurfacePlacement.new()
	painted_surface.asset_id = "BASE"
	painted_surface.terrain_face_uids = PackedStringArray([uid])
	board.surfaces.append(painted_surface)
	board.material_blend.from_json(profile.to_json())
	# Version 2 persists a mapping for every canonical terrain face, including
	# unpainted boundary bands; the PNG list remains sparse and unchanged.
	var roundtrip_metadata := (saved.get("metadata", {}) as Dictionary).duplicate(true)
	var roundtrip_surfaces: Array = []
	for entry_value: Variant in roundtrip_metadata.get("surfaces", []) as Array:
		var entry: Dictionary = entry_value
		if String(entry.get("uid", "")) == uid:
			roundtrip_surfaces.append(entry.duplicate(true))
	var roundtrip_slots: Array = []
	for terrain_uid_value: Variant in board.terrain.face_uid_set().keys():
		roundtrip_slots.append({
			"uid": String(terrain_uid_value),
			"palette_indices": [0, 1, 2, 3],
		})
	roundtrip_metadata["surfaces"] = roundtrip_surfaces
	roundtrip_metadata["material_slots"] = roundtrip_slots
	board.surface_material_paint = roundtrip_metadata
	var board_copy := BoardDocument.new()
	board_copy.bind_library(roundtrip_library)
	board_copy.from_json(board.to_json())
	_check(
		board_copy.surfaces[0].terrain_face_uids.has(uid),
		"board JSON preserves the stable painted terrain face UID"
	)
	_check(
		board_copy.material_blend.blend_mode
		== MaterialBlendProfile.BlendMode.NORMALIZED_SPLAT
		and board_copy.material_blend.splatmap_source_path
		== profile.splatmap_source_path,
		"board JSON preserves the true splat recipe and its canonical RGBA source"
	)

	# One opaque RGB-style source proves unused alpha is cleared while the map
	# is distributed continuously over canonical top-face images.
	var import_profile := MaterialBlendProfile.new()
	var import_painter := _paint_script.new() as MTSSurfaceMaterialPaint
	import_painter.bind_profile(import_profile)
	var left_uid := TerrainMesh.cell_top_uid(Vector2i(0, 0))
	var right_uid := TerrainMesh.cell_top_uid(Vector2i(1, 0))
	import_painter.register_batch(
		"IMPORT|TOP",
		PackedStringArray([left_uid, right_uid]),
		Vector2i.ONE
	)
	var splat_source := Image.create(2, 1, false, Image.FORMAT_RGBA8)
	splat_source.set_pixel(0, 0, Color(1.0, 0.0, 0.0, 1.0))
	splat_source.set_pixel(1, 0, Color(0.0, 1.0, 0.0, 1.0))
	var splat_targets: Array[Dictionary] = [
		{"uid": left_uid, "projection_cell": Vector2i(0, 0)},
		{"uid": right_uid, "projection_cell": Vector2i(1, 0)},
	]
	var splat_channels := PackedByteArray([1, 1, 1, 0])
	var projected_source := import_painter.prepare_splatmap_source(
		splat_source,
		splat_channels,
		false,
		0
	)
	_check(projected_source != null, "RGBA splatmap source prepares with its channel mask")
	var splat_bounds_result := import_painter.splatmap_terrain_bounds(splat_targets)
	_check(
		int(splat_bounds_result.get("error", FAILED)) == OK
		and splat_bounds_result.get("terrain_bounds", Rect2i()) == Rect2i(0, 0, 2, 1),
		"splatmap bounds cover exactly the registered top faces without reading pixels"
	)
	var splat_bounds: Rect2i = splat_bounds_result["terrain_bounds"]
	import_painter.begin_stroke()
	for target: Dictionary in splat_targets:
		var projected_tile := import_painter.build_splatmap_tile(
			projected_source,
			splat_bounds,
			target["projection_cell"] as Vector2i,
			splat_channels
		)
		_check(
			projected_tile != null,
			"each terrain cell samples its own region of the projected control map"
		)
		import_painter.stamp_splatmap_tile(
			String(target["uid"]),
			projected_tile,
			PackedInt32Array([0, 1, 2, -1]),
			false
		)
	import_painter.finish_stroke()
	var imported_left := import_painter.image_for_uid(left_uid).get_pixel(32, 32)
	var imported_right := import_painter.image_for_uid(right_uid).get_pixel(32, 32)
	_check(
		imported_left.r > imported_left.g and imported_right.g > imported_right.r,
		"top-down splatmap spans adjacent world-X terrain cells"
	)
	_check(
		is_zero_approx(imported_left.a) and is_zero_approx(imported_right.a),
		"unused alpha stays empty even when the source image is opaque"
	)
	var tile_template := import_painter.image_for_uid(left_uid).duplicate() as Image
	tile_template.fill(Color(0.1, 0.2, 0.3, 0.4))
	import_painter.begin_stroke()
	_check(
		import_painter.stamp_splatmap_tile(
			left_uid,
			tile_template,
			PackedInt32Array([0, 1, 2, 3]),
			false
		),
		"one tile stamp changes the canonical RGBA image"
	)
	var tile_stroke := import_painter.finish_stroke()
	var tile_weight := import_painter.image_for_uid(left_uid).get_pixel(32, 32)
	_check(
		not tile_stroke.is_empty()
		and absf(tile_weight.r - 0.1) < 0.01
		and absf(tile_weight.g - 0.2) < 0.01
		and absf(tile_weight.b - 0.3) < 0.01
		and absf(tile_weight.a - 0.4) < 0.01,
		"one base-coat tile stamp records every RGBA channel in the same undo stroke"
	)

	# Masked tile paint writes only one complete painted gate; the shader remains
	# responsible for sampling its world-space height, cavity, curvature, or slope mask.
	import_painter.begin_stroke()
	_check(
		import_painter.stamp_material_tile(right_uid, 2, 1.0, 0, false),
		"one masked material tile stamp changes its selected channel"
	)
	var masked_tile_stroke := import_painter.finish_stroke()
	var masked_tile_image := import_painter.image_for_uid(right_uid)
	var masked_tile_size := masked_tile_image.get_size()
	_check(
		not masked_tile_stroke.is_empty()
		and masked_tile_image.get_pixel(0, 0).b > 0.99
		and masked_tile_image.get_pixel(masked_tile_size.x - 1, 0).b > 0.99
		and masked_tile_image.get_pixel(0, masked_tile_size.y - 1).b > 0.99
		and masked_tile_image.get_pixel(masked_tile_size.x - 1, masked_tile_size.y - 1).b > 0.99,
		"masked tile targeting fills the complete selected face gate"
	)

	# The height mask range is derived from projected terrain rather than from a
	# directly edited image, so the range is checked through that one path.
	var fields := MTSWorldSurfaceFields.new()
	fields.configure(Vector2.ZERO, Vector2(2, 2), Vector2i(64, 64), false)
	var range_grid := TerrainMesh.create(Vector2i(0, 0), Vector2i(2, 2))
	for cell_z: int in 2:
		for cell_x: int in 2:
			range_grid.set_cell_filled(Vector2i(cell_x, cell_z), true)
	range_grid.set_lattice_corner_height(Vector2i(1, 1), 2.5)
	fields.project_terrain(range_grid)
	var height_range := fields.height_value_range()
	_check(
		is_equal_approx(height_range.x, 0.0) and height_range.y > 2.0,
		"world-height percentage range follows the projected terrain"
	)

	var library := AssetLibrary.new()
	var base := _surface_asset("BASE")
	var overlay := _surface_asset("OVERLAY")
	for channel: String in [
		"normal",
		"bent_normal",
		"ambient_occlusion",
		"roughness",
		"metallic",
		"height",
		"emission",
		"detail_normal",
		"detail_albedo",
	]:
		overlay.gbuffer.set_channel(channel, "res://icon.svg")
	overlay.gbuffer.set_strength("albedo", 0.72)
	overlay.gbuffer.set_strength("normal", 0.63)
	overlay.gbuffer.set_strength("bent_normal", 0.54)
	overlay.gbuffer.set_strength("ambient_occlusion", 0.45)
	overlay.gbuffer.set_strength("roughness", 0.36)
	overlay.gbuffer.set_strength("metallic", 0.27)
	overlay.gbuffer.set_strength("detail_normal", 0.18)
	overlay.gbuffer.set_strength("emission", 1.7)
	overlay.gbuffer.set_bias("roughness", -0.12)
	overlay.gbuffer.set_bias("metallic", 0.14)
	overlay.gbuffer.specular_strength = 0.81
	base.stochastic_tiling = false
	base.random_texture_rotation = false
	base.random_texture_mirroring = false
	overlay.stochastic_tiling = true
	overlay.random_texture_rotation = true
	overlay.random_texture_mirroring = true
	library.add_asset(base)
	library.add_asset(overlay)
	var layer := profile.layer(0)
	layer["enabled"] = true
	layer["asset_id"] = overlay.asset_id
	layer["application_mode"] = MaterialBlendProfile.ApplicationMode.BRUSH
	var directional_rule := MaterialBlendProfile.default_rule(
		MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS,
		0
	)
	directional_rule["noise_scale_m"] = 5.0
	directional_rule["noise_seed"] = 9
	directional_rule["noise_angle_degrees"] = 37.0
	layer["masks"] = [
		MaterialBlendProfile.default_rule(
			MaterialBlendProfile.MaskSource.PAINT,
			0
		),
		directional_rule,
	]
	profile.set_layer(0, layer)
	# This profile deliberately has one live directional layer so dependency
	# assertions are not contaminated by unrelated palette entries used earlier.
	for other_layer_index: int in range(1, profile.layer_count()):
		var other_layer: Dictionary = profile.layer(other_layer_index)
		other_layer["enabled"] = false
		profile.set_layer(other_layer_index, other_layer)
	restored_painter.register_batch("BASE|0|0|0", PackedStringArray([uid]), Vector2i(2, 2))
	var factory := SurfaceMaterialFactory.new()
	factory.world_fields = fields
	factory.aesthetics = AestheticProfile.defaults()
	var material := factory.get_asset_material_for_terrain_batch(
		base,
		restored_painter.batch_texture("BASE|0|0|0"),
		profile,
		library,
		height_range,
		Vector2(0, 10)
	) as ShaderMaterial
	_check(material != null, "canonical PNG shader accepts the material paint recipe")
	if material != null:
		_check(
			bool(material.get_shader_parameter("material_blend_enabled")),
			"batch material receives the enabled blend state"
		)
		_check(
			material.get_shader_parameter("material_control_tex") is Texture2DArray,
			"batch material receives one layered sparse control texture"
		)
		var shader_code: String = material.shader.code
		_check(
			shader_code.count("material_control_tex,") == 1,
			"the complete mixed fragment path reads the control array exactly once"
		)
		_check(
			shader_code.contains("v_material_control_class < 0.5")
			and shader_code.contains("v_material_control_class < 1.5"),
			"base-only and uniform faces bypass the control texture in the shader"
		)
		_check(
			shader_code.contains("MTS_PAINT_WEIGHT_THRESHOLD")
			and shader_code.contains(
				"original_base_weight <= MTS_PAINT_WEIGHT_THRESHOLD"
			)
			and shader_code.contains("coverage <= MTS_PAINT_WEIGHT_THRESHOLD"),
			"the shader applies the shared 4/255 pruning and transparent-channel cutoff"
		)
		_check(
			shader_code.contains("weights.x >= 0.999")
			and shader_code.contains("weights.y >= 0.999")
			and shader_code.contains("weights.z >= 0.999"),
			"axis-aligned projections use the exact one-axis triplanar path"
		)
		_check(
			not shader_code.contains("#define MTS_WORLD_HEIGHT_FIELD"),
			"a profile without world-height consumers compiles out that field sampler"
		)
		var expected_dependencies: int = (
			(1 << MaterialBlendProfile.MaskSource.PAINT)
			| (1 << MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS)
		)
		_check(
			int(material.get_shader_parameter("material_layer_0_mask_dependencies"))
			== expected_dependencies,
			"the material exposes only its active mask-source dependency bits"
		)
		_check(
			shader_code.contains(
				"uniform float material_ao_light_affect : hint_range(0.0, 1.0, 0.01) = 0.25;"
			),
			"standalone terrain materials default AO light influence to 0.25"
		)
		_check(
			not shader_code.contains("bent_normal_tex")
			and not shader_code.contains("detail_normal_tex")
			and not shader_code.contains("cavity_tex")
			and not shader_code.contains("curvature_tex"),
			"analysis-only derivative sampler names are absent from the runtime shader"
		)
		_check(
			not shader_code.contains("uniform sampler2D ao_tex")
			and not shader_code.contains("uniform sampler2D roughness_tex")
			and not shader_code.contains("uniform sampler2D metallic_tex"),
			"runtime scalar PBR uses resolved ORM instead of separate sampler fallbacks"
		)
		_check(
			material.shader.code.contains("material_layer_mask"),
			"shader contains automatic percentage-mask evaluation"
		)
		_check(
			bool(material.get_shader_parameter("material_layer_0_brush_authored")),
			"brush material binds the explicit local splat gate"
		)
		_check(
			not bool(material.get_shader_parameter("stochastic_tiling"))
			and bool(material.get_shader_parameter("material_layer_0_stochastic_tiling"))
			and bool(material.get_shader_parameter("material_layer_0_random_texture_rotation"))
			and bool(material.get_shader_parameter("material_layer_0_random_texture_mirroring")),
			"overlay variation switches remain independent from the regular base asset"
		)
		var bound_sources: Vector4i = material.get_shader_parameter(
			"material_layer_0_mask_sources"
		)
		var bound_angles: Vector4 = material.get_shader_parameter(
			"material_layer_0_mask_noise_angles"
		)
		_check(
			bound_sources.y == MaterialBlendProfile.MaskSource.DIRECTIONAL_BANDS
			and is_equal_approx(bound_angles.y, 37.0),
			"directional mask source and its explicit angle reach the shader"
		)
		_check(
			material.shader.code.contains(
				"constraint_mask * painted_gate"
			)
			and material.shader.code.contains(
				"material_component(painted_weights, layer_index)"
			),
			"zero brush weight remains exact zero after every optional mask operation"
		)
		_check(
			material.shader.code.contains("material_mask_preview_enabled")
			and material.shader.code.contains("layer_constraints"),
			"mask preview reuses the shader's pre-paint eligibility result"
		)
		_check(
			not material.shader.code.contains("&& !material_mask_preview_enabled")
			and not material.shader.code.contains("if (!material_mask_preview_enabled)"),
			"mask preview preserves final PBR sampling and material blending"
		)
		_check(
			material.shader.code.contains(
				"transition_band = 4.0 * transition * (1.0 - transition);"
			),
			"height-aware blending preserves zero and full mask endpoints"
		)
		_check(
			material.shader.code.contains(
				"material_world_pos, v_base_normal_world, surface_size_m,"
			)
			and material.shader.code.contains(
				"material_world_pos, v_base_normal_world, repeat_m,"
			),
			"base and overlay PBR channels share the canonical world projection"
		)
		_check(
			material.shader.code.contains(
				"vec2 coord_x = rotate_quarter_turns(vec2(-world_pos.z, world_pos.y), steps) / period_m;"
			)
			and material.shader.code.contains(
				"vec2 coord_y = rotate_quarter_turns(vec2(world_pos.x, -world_pos.z), steps) / period_m;"
			)
			and material.shader.code.contains(
				"vec2 coord_z = rotate_quarter_turns(vec2(world_pos.x, world_pos.y), steps) / period_m;"
			)
			and material.shader.code.contains(
				"vec3 weights = world_projection_weights(world_normal);"
			),
			"terrain projection uses one fixed map-wide triplanar field"
		)
		_check(
			bool(material.get_shader_parameter("material_layer_0_has_normal"))
			and bool(material.get_shader_parameter("material_layer_0_has_orm"))
			and bool(material.get_shader_parameter("material_layer_0_has_height"))
			and bool(material.get_shader_parameter("material_layer_0_has_emission"))
			and bool(material.get_shader_parameter("material_layer_0_has_detail_albedo"))
			and material.get_shader_parameter("material_layer_0_has_bent_normal") == null
			and material.get_shader_parameter("material_layer_0_has_detail_normal") == null,
			"overlay layer binds primary runtime channels and no derivative flags"
		)
		_check(
			is_equal_approx(float(material.get_shader_parameter("material_layer_0_albedo_strength")), 0.72)
			and is_equal_approx(float(material.get_shader_parameter("material_layer_0_normal_strength")), 0.63)
			and is_equal_approx(float(material.get_shader_parameter("material_layer_0_ao_strength")), 0.45)
			and is_equal_approx(float(material.get_shader_parameter("material_layer_0_roughness_strength")), 0.36)
			and is_equal_approx(float(material.get_shader_parameter("material_layer_0_metallic_strength")), 0.27)
			and is_equal_approx(float(material.get_shader_parameter("material_layer_0_emission_strength")), 1.7)
			and is_equal_approx(float(material.get_shader_parameter("material_layer_0_roughness_bias")), -0.12)
			and is_equal_approx(float(material.get_shader_parameter("material_layer_0_metallic_bias")), 0.14)
			and is_equal_approx(float(material.get_shader_parameter("material_layer_0_specular_strength")), 0.81)
			and material.get_shader_parameter("material_layer_0_bent_normal_strength") == null
			and material.get_shader_parameter("material_layer_0_detail_normal_strength") == null,
			"overlay layer keeps live primary PBR controls and no derivative controls"
		)
		_check(
			material.shader.code.contains("float material_smooth_noise(")
			and material.shader.code.contains("float material_ridged_noise(")
			and material.shader.code.contains("float material_cellular_noise(")
			and material.shader.code.contains("float material_directional_bands(")
			and not material.shader.code.contains("material_noise_value"),
			"four continuous world-space masks replace the square-cell hash"
		)
		_check(
			material.shader.code.contains("texture_variation_normal_xy")
			and material.shader.code.contains("sample_surface_tangent_normal"),
			"rotated and mirrored normal maps return to the original tangent frame"
		)
		_check(
			material.shader.code.contains("ALBEDO = albedo;")
			and material.shader.code.contains("ROUGHNESS = roughness_value;")
			and material.shader.code.contains("METALLIC = metallic_value;")
			and material.shader.code.contains("AO = clamp(ao_value, 0.0, 1.0);")
			and material.shader.code.contains("NORMAL = normalize(")
			and not material.shader.code.contains("BENT_NORMAL_MAP")
			and material.shader.code.contains("SPECULAR = clamp(specular_value, 0.0, 1.0);")
			and material.shader.code.contains("EMISSION = emission_value;"),
			"the runtime shader writes primary Godot PBR outputs only"
		)

	var procedural_layer := layer.duplicate(true)
	procedural_layer["application_mode"] = MaterialBlendProfile.ApplicationMode.PROCEDURAL
	procedural_layer["masks"] = [
		MaterialBlendProfile.default_rule(
			MaterialBlendProfile.MaskSource.WORLD_HEIGHT,
			0
		),
	]
	profile.set_layer(0, procedural_layer)
	var procedural_material := factory.get_asset_material_for_terrain_batch(
		base,
		restored_painter.batch_texture("BASE|0|0|0"),
		profile,
		library,
		height_range,
		Vector2(0, 10)
	) as ShaderMaterial
	_check(procedural_material != null, "procedural material uses the same canonical PNG shader")
	if procedural_material != null:
		_check(
			procedural_material.shader.code.contains(
				"#define MTS_WORLD_HEIGHT_FIELD"
			),
			"a WORLD_HEIGHT rule restores the field sampler in that material variant"
		)
		_check(
			not bool(
				procedural_material.get_shader_parameter(
					"material_layer_0_brush_authored"
				)
			),
			"procedural painted-channel masks retain percentage-range evaluation"
		)

	print("=== material paint failures: %d ===\n" % _failed)
	quit(1 if _failed > 0 else 0)


## Create one minimal direct PNG surface asset for shader-binding tests.
func _surface_asset(asset_id: String) -> TileAsset:
	var asset := TileAsset.new()
	asset.asset_id = asset_id
	asset.display_name = asset_id
	asset.source_type = 0
	asset.source_path = "res://icon.svg"
	asset.grid_bounds = Vector3i(2, 2, 1)
	asset.visual_size_m = Vector3(2, 2, 0)
	asset.gbuffer = GBufferMapSet.new()
	asset.gbuffer.set_channel("albedo", "res://icon.svg")
	return asset


## Record one assertion while keeping all checks visible in headless output.
func _check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS  %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s" % label)
