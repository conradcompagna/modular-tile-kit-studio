@tool
extends RefCounted

## Brush behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Apply one continuous circular brush segment in a placement's local metric plane.
##
## UV endpoints may remain outside this placement so one world-space stroke can cross tile
## seams without clamping into square edge stamps. The hot loop retains stroke dictionaries
## locally and skips pixels whose strongest influence did not increase.
static func brush_segment(host: MTSSurfaceMaterialPaint,
	placement_uid: String,
	footprint_m: Vector2i,
	start_uv: Vector2,
	end_uv: Vector2,
	radius_m: float,
	hardness: float,
	opacity: float,
	palette_index: int,
	rotation_quarters: int,
	erase: bool
) -> bool:
	if host.profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot paint without a bound profile.")
		return false
	if (
		placement_uid.is_empty()
		or radius_m <= 0.0
		or opacity <= 0.0
		or not start_uv.is_finite()
		or not end_uv.is_finite()
	):
		return false
	var image := host.image_for_uid(placement_uid)
	var resolution := (
		image.get_size()
		if image != null
		else host.profile.paint_resolution(footprint_m)
	)
	if resolution.x <= 0 or resolution.y <= 0:
		push_error("MTSSurfaceMaterialPaint: invalid paint resolution for '%s'." % placement_uid)
		return false
	var width := resolution.x
	var height := resolution.y
	var footprint := Vector2(maxi(1, footprint_m.x), maxi(1, footprint_m.y))
	var start_m := start_uv * footprint
	var end_m := end_uv * footprint
	var minimum_m := start_m.min(end_m) - Vector2.ONE * radius_m
	var maximum_m := start_m.max(end_m) + Vector2.ONE * radius_m
	var x0 := clampi(floori(minimum_m.x / footprint.x * width), 0, width)
	var y0 := clampi(floori(minimum_m.y / footprint.y * height), 0, height)
	var x1 := clampi(ceili(maximum_m.x / footprint.x * width) + 1, 0, width)
	var y1 := clampi(ceili(maximum_m.y / footprint.y * height) + 1, 0, height)
	if x0 >= x1 or y0 >= y1:
		return false
	var slot_index := host._ensure_palette_slot(placement_uid, palette_index, not erase)
	if slot_index < 0:
		return false
	var normalize_before_runtime_masks := not host._layer_has_runtime_constraint(palette_index)
	var before_by_pixel: Dictionary = host._stroke_before.get(placement_uid, {})
	var maximum_weights: Dictionary = host._stroke_max_weights.get(placement_uid, {})
	var radius_squared := radius_m * radius_m
	var image_created := false
	var paint_reached_pixel := false
	var changed := false
	for y: int in range(y0, y1):
		for x: int in range(x0, x1):
			var point_m := Vector2(
				(float(x) + 0.5) / float(width) * footprint.x,
				(float(y) + 0.5) / float(height) * footprint.y
			)
			var distance_squared := host._point_segment_distance_squared(
				point_m,
				start_m,
				end_m
			)
			if distance_squared >= radius_squared:
				continue
			var distance_ratio := sqrt(distance_squared) / maxf(radius_m, 0.0001)
			var weight := host._falloff(distance_ratio, hardness) * clampf(opacity, 0.0, 1.0)
			if weight <= 0.0:
				continue
			paint_reached_pixel = true
			var encoded := y * width + x
			var maximum_weight := weight
			if host._stroke_active:
				var previous_weight := float(maximum_weights.get(encoded, 0.0))
				if weight <= previous_weight:
					continue
				maximum_weights[encoded] = weight
			var current := (
				image.get_pixel(x, y)
				if image != null
				else Color(0.0, 0.0, 0.0, 0.0)
			)
			var original := current
			if host._stroke_active:
				if before_by_pixel.has(encoded):
					original = before_by_pixel[encoded]
				else:
					before_by_pixel[encoded] = current
				maximum_weight = float(maximum_weights[encoded])
			var next := host._painted_layer_color(
				original,
				slot_index,
				maximum_weight,
				erase,
				normalize_before_runtime_masks
			)
			if next == current:
				continue
			if image == null:
				image = Image.create(width, height, false, Image.FORMAT_RGBA8)
				image.fill(Color(0.0, 0.0, 0.0, 0.0))
				host._images_by_uid[placement_uid] = image
				image_created = true
			image.set_pixel(x, y, next)
			changed = true
	if host._stroke_active:
		if not before_by_pixel.is_empty():
			host._stroke_before[placement_uid] = before_by_pixel
		if not maximum_weights.is_empty():
			host._stroke_max_weights[placement_uid] = maximum_weights
	var rotation_changed := (
		host._set_slot_rotation(placement_uid, slot_index, rotation_quarters)
		if paint_reached_pixel and not erase
		else false
	)
	if changed:
		var batch_texture_created := false
		if image_created:
			batch_texture_created = host._ensure_registered_batch_texture(placement_uid)
		if not batch_texture_created:
			host._dirty_uids[placement_uid] = true
		host.paint_changed.emit(placement_uid)
	return changed or rotation_changed


## Fill one selected material channel across a complete targeted terrain face.
##
## This writes only the structural painted gate. The material shader samples the selected
## layer's height, cavity, curvature, slope, and other world-space mask rules from their
## canonical fields, so tile targeting does not duplicate or bake the mask calculation.
static func stamp_material_tile(host: MTSSurfaceMaterialPaint,
	placement_uid: String,
	palette_index: int,
	opacity: float,
	rotation_quarters: int,
	erase: bool
) -> bool:
	if host.profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot stamp a material tile without a profile.")
		return false
	if placement_uid.is_empty() or not host._batch_key_by_uid.has(placement_uid):
		push_error(
			"MTSSurfaceMaterialPaint: material tile '%s' is not a registered terrain face."
			% placement_uid
		)
		return false
	var weight := clampf(opacity, 0.0, 1.0)
	if weight <= 0.0:
		return false
	var footprint := host._registered_footprint(placement_uid)
	var image := host.image_for_uid(placement_uid)
	var resolution := (
		image.get_size()
		if image != null
		else host.profile.paint_resolution(footprint)
	)
	if resolution.x <= 0 or resolution.y <= 0:
		push_error(
			"MTSSurfaceMaterialPaint: material tile '%s' has an invalid resolution."
			% placement_uid
		)
		return false
	var selected_channel := host._ensure_palette_slot(placement_uid, palette_index, not erase)
	if selected_channel < 0:
		return false
	var normalize_before_runtime_masks := not host._layer_has_runtime_constraint(palette_index)
	var before_by_pixel: Dictionary = host._stroke_before.get(placement_uid, {})
	var maximum_weights: Dictionary = host._stroke_max_weights.get(placement_uid, {})
	var image_created := false
	var changed := false
	for y: int in resolution.y:
		for x: int in resolution.x:
			var encoded := y * resolution.x + x
			var maximum_weight := weight
			if host._stroke_active:
				var previous_weight := float(maximum_weights.get(encoded, 0.0))
				if weight <= previous_weight:
					continue
				maximum_weights[encoded] = weight
			var current := (
				image.get_pixel(x, y)
				if image != null
				else Color(0.0, 0.0, 0.0, 0.0)
			)
			var original := current
			if host._stroke_active:
				if before_by_pixel.has(encoded):
					original = before_by_pixel[encoded]
				else:
					before_by_pixel[encoded] = current
				maximum_weight = float(maximum_weights[encoded])
			var next := host._painted_layer_color(
				original,
				selected_channel,
				maximum_weight,
				erase,
				normalize_before_runtime_masks
			)
			if next == current:
				continue
			if image == null:
				image = Image.create(
					resolution.x,
					resolution.y,
					false,
					Image.FORMAT_RGBA8
				)
				image.fill(Color(0.0, 0.0, 0.0, 0.0))
				host._images_by_uid[placement_uid] = image
				image_created = true
			image.set_pixel(x, y, next)
			changed = true
	if host._stroke_active:
		if not before_by_pixel.is_empty():
			host._stroke_before[placement_uid] = before_by_pixel
		if not maximum_weights.is_empty():
			host._stroke_max_weights[placement_uid] = maximum_weights
	var rotation_changed := (
		host._set_slot_rotation(placement_uid, selected_channel, rotation_quarters)
		if not erase
		else false
	)
	if changed:
		var batch_texture_created := false
		if image_created:
			batch_texture_created = host._ensure_registered_batch_texture(placement_uid)
		if not batch_texture_created:
			host._dirty_uids[placement_uid] = true
		host.paint_changed.emit(placement_uid)
	return changed or rotation_changed


## Stamp one whole terrain tile with every RGBA weight from the loaded control-map template.
##
## The template contains only blend weights; every PBR texture and tiling value remains
## live on its assigned TileAsset, so asset-panel edits update existing splat paint.
static func stamp_splatmap_tile(host: MTSSurfaceMaterialPaint,
	placement_uid: String,
	template_image: Image,
	palette_slots: PackedInt32Array,
	erase: bool
) -> bool:
	if host.profile == null:
		push_error("MTSSurfaceMaterialPaint: cannot stamp a splat tile without a profile.")
		return false
	if placement_uid.is_empty() or not host._batch_key_by_uid.has(placement_uid):
		push_error(
			"MTSSurfaceMaterialPaint: splat tile '%s' is not a registered terrain face."
			% placement_uid
		)
		return false
	if not erase and not host.set_splatmap_palette_slots(placement_uid, palette_slots):
		return false
	var image := host.image_for_uid(placement_uid)
	if erase and image == null:
		return false
	var resolution := (
		image.get_size()
		if image != null
		else template_image.get_size()
		if template_image != null
		else host.profile.paint_resolution(Vector2i.ONE)
	)
	if resolution.x <= 0 or resolution.y <= 0:
		push_error(
			"MTSSurfaceMaterialPaint: splat tile '%s' has an invalid resolution."
			% placement_uid
		)
		return false
	if template_image != null and template_image.get_size() != resolution:
		push_error(
			"MTSSurfaceMaterialPaint: splat template resolution %s does not match tile '%s' resolution %s."
			% [template_image.get_size(), placement_uid, resolution]
		)
		return false
	var before_by_pixel: Dictionary = host._stroke_before.get(placement_uid, {})
	var image_created := false
	var changed := false
	for y: int in resolution.y:
		for x: int in resolution.x:
			var current := (
				image.get_pixel(x, y)
				if image != null
				else Color(0.0, 0.0, 0.0, 0.0)
			)
			var next := (
				Color(0.0, 0.0, 0.0, 0.0)
				if erase or template_image == null
				else template_image.get_pixel(x, y)
			)
			if next == current:
				continue
			var encoded := y * resolution.x + x
			if host._stroke_active and not before_by_pixel.has(encoded):
				before_by_pixel[encoded] = current
			if image == null:
				image = Image.create(
					resolution.x,
					resolution.y,
					false,
					Image.FORMAT_RGBA8
				)
				image.fill(Color(0.0, 0.0, 0.0, 0.0))
				host._images_by_uid[placement_uid] = image
				image_created = true
			image.set_pixel(x, y, next)
			changed = true
	if host._stroke_active and not before_by_pixel.is_empty():
		host._stroke_before[placement_uid] = before_by_pixel
	if changed:
		var batch_texture_created := false
		if image_created:
			batch_texture_created = host._ensure_registered_batch_texture(placement_uid)
		if not batch_texture_created:
			host._dirty_uids[placement_uid] = true
		host.paint_changed.emit(placement_uid)
	return changed
