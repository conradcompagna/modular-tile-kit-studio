@tool
extends RefCounted

## Color math behavior for MTSSurfaceMaterialPaint.
## The host retains Godot identity, signals, and authoritative state.

## Report whether this layer has a shader-evaluated constraint beyond its paint gate.
##
## Such a constraint is only known per rendered texel, so changing competing paint
## channels here would destroy their authored weights before that mask is evaluated.
static func _layer_has_runtime_constraint(host: MTSSurfaceMaterialPaint, palette_index: int) -> bool:
	if host.profile == null:
		return false
	for rule_value: Variant in host.profile.layer_masks(palette_index):
		if not rule_value is Dictionary:
			continue
		var rule: Dictionary = rule_value
		if int(rule.get("source", MaterialBlendProfile.MaskSource.PAINT)) != MaterialBlendProfile.MaskSource.PAINT:
			return true
	return false


## Choose whether normalization is safe before the shader evaluates runtime masks.
static func _painted_layer_color(host: MTSSurfaceMaterialPaint,
	original: Color,
	channel: int,
	weight: float,
	erase: bool,
	normalize_before_runtime_masks: bool
) -> Color:
	if (
		host.profile != null
		and host.profile.blend_mode == MaterialBlendProfile.BlendMode.NORMALIZED_SPLAT
		and normalize_before_runtime_masks
	):
		return host._normalized_splat_color(original, channel, weight, erase)
	return host._independent_layer_color(original, channel, weight, erase)


## Blend one independent channel toward paint or erase using the original pixel.
static func _independent_layer_color(host: MTSSurfaceMaterialPaint,
	original: Color,
	channel: int,
	weight: float,
	erase: bool
) -> Color:
	var target := 0.0 if erase else 1.0
	return host._color_with_component(
		original,
		clampi(channel, 0, 3),
		lerpf(host._color_component(original, channel), target, clampf(weight, 0.0, 1.0))
	)


## Rebalance all competing weights while leaving the base material as implicit remainder.
static func _normalized_splat_color(host: MTSSurfaceMaterialPaint,
	original: Color,
	channel: int,
	weight: float,
	erase: bool
) -> Color:
	var selected := clampi(channel, 0, 3)
	var values := [
		clampf(original.r, 0.0, 1.0),
		clampf(original.g, 0.0, 1.0),
		clampf(original.b, 0.0, 1.0),
		clampf(original.a, 0.0, 1.0),
	]
	var original_selected := float(values[selected])
	var next_selected := lerpf(
		original_selected,
		0.0 if erase else 1.0,
		clampf(weight, 0.0, 1.0)
	)
	if erase:
		values[selected] = next_selected
		return Color(values[0], values[1], values[2], values[3])
	var other_total := 0.0
	for index: int in values.size():
		if index != selected:
			other_total += float(values[index])
	var base_weight := maxf(0.0, 1.0 - original_selected - other_total)
	var remaining := maxf(0.0, 1.0 - next_selected)
	var previous_remaining := other_total + base_weight
	var ratio := remaining / previous_remaining if previous_remaining > 0.000001 else 0.0
	for index: int in values.size():
		if index != selected:
			values[index] = float(values[index]) * ratio
	values[selected] = next_selected
	return Color(values[0], values[1], values[2], values[3])


## Return one Color component selected by the visible RGBA palette slot.
static func _color_component(host: MTSSurfaceMaterialPaint, color: Color, component: int) -> float:
	match clampi(component, 0, 3):
		0:
			return color.r
		1:
			return color.g
		2:
			return color.b
		_:
			return color.a


## Return a Color with exactly one RGBA component replaced.
static func _color_with_component(host: MTSSurfaceMaterialPaint, color: Color, component: int, value: float) -> Color:
	match clampi(component, 0, 3):
		0:
			color.r = value
		1:
			color.g = value
		2:
			color.b = value
		_:
			color.a = value
	return color


## Convert a normalized brush distance into one continuous hardness falloff.
static func _falloff(host: MTSSurfaceMaterialPaint, distance_ratio: float, hardness: float) -> float:
	if distance_ratio >= 1.0:
		return 0.0
	var clamped_hardness := clampf(hardness, 0.0, 1.0)
	var soft_start := lerpf(0.0, 0.92, clamped_hardness)
	if distance_ratio <= soft_start:
		return 1.0
	var edge_ratio := (
		(distance_ratio - soft_start)
		/ maxf(1.0 - soft_start, 0.0001)
	)
	return 1.0 - edge_ratio * edge_ratio * (3.0 - 2.0 * edge_ratio)


## Return squared metric distance from one point to a finite stroke segment.
##
## The hot loop rejects pixels outside the exact capsule before paying for a square root.
static func _point_segment_distance_squared(host: MTSSurfaceMaterialPaint,
	point: Vector2,
	start: Vector2,
	finish: Vector2
) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.0000001:
		return point.distance_squared_to(start)
	var ratio := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(start + segment * ratio)
