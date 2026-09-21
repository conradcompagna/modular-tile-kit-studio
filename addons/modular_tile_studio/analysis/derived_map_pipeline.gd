@tool
class_name DerivedMapPipeline
extends RefCounted

## Deterministic map derivation (spec 21).
##
## Kept strictly separate from the ComfyUI provider. The AI stage produces
## estimates; this stage consumes them and derives everything that follows
## mathematically from recovered geometry:
##
##   "Use AI to infer visual properties that require understanding.
##    Use mathematics to derive everything that follows from that geometry."
##
## Every processor is independent and runs only when its inputs exist, so the
## pipeline degrades gracefully on a partially analyzed asset.

const K := preload("../utils/mts_constants.gd")

## Height is stored as a normalized grayscale PNG rather than raw depth.
##
## MoGe and CHORD write a normalized 0..1 height field; a raw depth output
## such as Marigold is normalized here before it is stored as height. The
## material factory consumes every source as the same neutral shape field.
## At runtime, the board's CHORD height-range setting turns that field into
## metres for the asset's current footprint, and per-material Height strength
## is the only material-side multiplier. GLB props remain out of scope because
## they render from their imported geometry/materials and have no surface
## G-buffer to derive.
##
## Derived maps are therefore baked at neutral strength. Their runtime physical
## range stays adjustable without regenerating a texture, while the source field
## itself remains unmodified and inspectable.
const HEIGHT_FILE := "height.png"
const AO_FILE := "ambient_occlusion.png"
const CAVITY_FILE := "cavity.png"
const CURVATURE_FILE := "curvature.png"
const DETAIL_NORMAL_FILE := "detail_normal.png"
const BENT_NORMAL_FILE := "bent_normal.png"
const RUNTIME_NORMAL_FILE := "normal_runtime.png"
const ORM_FILE := "orm.png"


## Run every processor whose inputs are satisfied. Returns every channel written, across every facing for a prop.
##
## An EXPLICIT, on-demand step -- see plugin.gd's _on_regenerate_derived /
## _run_derived_async, the same worker-thread action a PNG asset already
## triggers via its own "Regenerate Derived Maps" control. GLB import/rebuild
## (GLBAssetImporter._build_variants) no longer calls this synchronously:
## curvature/cavity/detail-normal/bent-normal are derived conveniences, not
## prerequisites for placing a prop, so generating them per facing on every
## import was import-time cost with no import-time benefit (spec 7.1 --
## expensive derivation belongs behind an explicit action, not baked into a
## destructive-regen path that runs whether or not anything consumes the
## result yet).
##
## PNG surfaces are the only asset kind with a gbuffer to derive maps from: a
## GLB prop renders from its own imported materials and has no gbuffer at all.
func process(asset: TileAsset) -> PackedStringArray:
	if asset == null or asset.is_prop() or asset.gbuffer == null:
		return PackedStringArray()

	var derived_dir := asset.derived_dir
	if derived_dir.is_empty():
		derived_dir = K.ASSETS_DIR.path_join(asset.asset_id).path_join("derived")

	return process_maps(asset.gbuffer, derived_dir)


## Derive every channel that can be computed from the maps already present.
##
## Operates on a bare GBufferMapSet, so a PNG asset and a single GLB facing get
## byte-identical treatment -- there is no asset type visible here to branch on.
##
## Source-aware: a rendered/AI/attached channel at another path always wins,
## while a channel already pointing at this pipeline's own output is refreshed
## when its upstream input changes. This prevents stale derived maps after a
## re-analysis without silently replacing explicit data.
func process_maps(maps: GBufferMapSet, derived_dir: String) -> PackedStringArray:
	var written := PackedStringArray()
	if maps == null or derived_dir.is_empty():
		return written

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(derived_dir))

	# MoGe's mask marks pixels where its geometry prediction is valid. It is
	# analysis metadata, not visible alpha, and only constrains maps derived from
	# that geometry. GLB captures normally have no explicit mask; their render
	# target alpha supplies equivalent coverage.
	var geometry_mask := _load_image(maps, "geometry_mask")

	# 1. Height. Normalized from whatever geometry channel exists.
	#
	# If the current height points at this pipeline's own output path, regenerate
	# it when depth changes. An explicitly attached/source height at another path
	# remains authoritative and is never overwritten.
	var height_path := derived_dir.path_join(HEIGHT_FILE)
	var height_image := _load_image(maps, "height")
	var depth_image := _load_image(maps, "depth")
	if depth_image != null and _derived_or_missing(maps, "height", height_path):
		height_image = normalize_height(depth_image, geometry_mask)
		if _save(height_image, height_path) == OK:
			maps.set_channel("height", height_path)
			written.append("height")

	# 2. Normal is NEVER derived here.
	#
	# Both real sources already produce a true normal alongside the geometry:
	# MoGe emits depth, normal and a separate validity mask from one inference,
	# and a GLB facing is
	# captured from the model's actual surface normals. A normal reconstructed
	# from a heightfield is strictly worse than either -- it can only describe
	# slopes the height map happened to resolve, and it cannot see an overhang
	# at all. Deriving one would mean computing a degraded copy of data already
	# sitting in the map set.
	#
	# An asset with height but no normal simply has no normal. That is a gap in
	# its analysis to be filled by running MoGe, not papered over here.

	# 3. AO by heightfield horizon sampling.
	var ao_path := derived_dir.path_join(AO_FILE)
	if height_image != null and _derived_or_missing(maps, "ambient_occlusion", ao_path):
		var ao := ambient_occlusion_from_height(height_image, geometry_mask)
		if _save(ao, ao_path) == OK:
			maps.set_channel("ambient_occlusion", ao_path)
			written.append("ambient_occlusion")

	# 4. Curvature, cavity, detail normal and bent normal from height.
	#
	# These are owned derivatives. A map supplied explicitly by analysis or a
	# source asset at another path always wins; pipeline-owned outputs refresh.
	if height_image != null:
		var curvature_path := derived_dir.path_join(CURVATURE_FILE)
		if _derived_or_missing(maps, "curvature", curvature_path):
			var curvature := curvature_from_height(height_image, geometry_mask)
			if _save(curvature, curvature_path) == OK:
				maps.set_channel("curvature", curvature_path)
				written.append("curvature")

		var cavity_path := derived_dir.path_join(CAVITY_FILE)
		if _derived_or_missing(maps, "cavity", cavity_path):
			var cavity := cavity_from_height(height_image, geometry_mask)
			if _save(cavity, cavity_path) == OK:
				maps.set_channel("cavity", cavity_path)
				written.append("cavity")

		var detail_path := derived_dir.path_join(DETAIL_NORMAL_FILE)
		if _derived_or_missing(maps, "detail_normal", detail_path):
			var detail := detail_normal_from_height(height_image, geometry_mask)
			if _save(detail, detail_path) == OK:
				maps.set_channel("detail_normal", detail_path)
				written.append("detail_normal")

		# Bent normal is a different quantity from the visible surface normal: it
		# points toward the average unoccluded hemisphere direction. A heightfield
		# cannot recover overhangs, but it can derive a useful tangent-space bent
		# direction from the same local horizon samples used for AO.
		var bent_path := derived_dir.path_join(BENT_NORMAL_FILE)
		if _derived_or_missing(maps, "bent_normal", bent_path):
			var bent := bent_normal_from_height(height_image, geometry_mask)
			if _save(bent, bent_path) == OK:
				maps.set_channel("bent_normal", bent_path)
				written.append("bent_normal")

	# 5. Bake detail relief into the one normal map consumed by the shader.
	#
	# The untouched analysis normal remains explicitly addressable so repeated
	# rebuilds always start from canonical analysis rather than compounding the
	# previously baked result.
	var runtime_normal_path := derived_dir.path_join(RUNTIME_NORMAL_FILE)
	var current_normal_path := maps.get_channel("normal")
	if not current_normal_path.is_empty() and current_normal_path != runtime_normal_path:
		maps.set_channel("analysis_normal", current_normal_path)
	var analysis_normal_img := _load_image(maps, "analysis_normal")
	var detail_normal_img := _load_image(maps, "detail_normal")
	if analysis_normal_img != null and detail_normal_img != null:
		var runtime_normal := combine_tangent_normals(
			analysis_normal_img,
			detail_normal_img,
			maps.get_strength("detail_normal")
		)
		if _save(runtime_normal, runtime_normal_path) == OK:
			maps.set_channel("normal", runtime_normal_path)
			written.append("normal")

	# 6. Bake the three primary material scalars into one runtime ORM texture.
	#
	# Cavity and curvature stay inspectable analysis maps, while their selected
	# strengths are applied here once instead of costing independent shader reads.
	# All three primary inputs must be real; no placeholder material data is invented.
	var ao_img := _load_image(maps, "ambient_occlusion")
	var rough_img := _load_image(maps, "roughness")
	var metal_img := _load_image(maps, "metallic")
	var cavity_img := _load_image(maps, "cavity")
	var curvature_img := _load_image(maps, "curvature")
	var orm_path := derived_dir.path_join(ORM_FILE)
	if ao_img != null and rough_img != null and metal_img != null and _derived_or_missing(maps, "orm", orm_path):
		var orm := pack_orm(
			ao_img,
			rough_img,
			metal_img,
			cavity_img,
			curvature_img,
			maps.get_strength("cavity"),
			maps.get_strength("curvature")
		)
		if _save(orm, orm_path) == OK:
			maps.set_channel("orm", orm_path)
			written.append("orm")

	return written


# --- Processors -----------------------------------------------------------

## Rescale a depth/geometry image to full 0..1 relief while respecting the
## geometry-validity mask.
##
## A raw disparity/depth renderer supplies a relative field rather than metric
## metres, so this function maps valid pixels to 0..1. Invalid pixels are written
## black and never participate in the range estimate. This is the shared
## conversion for Marigold and older/custom depth recipes.
func normalize_height(depth: Image, mask: Image = null) -> Image:
	var w := depth.get_width()
	var h := depth.get_height()
	var depth_buf := _to_buffer_r(depth)
	var alpha_buf := _to_alpha_buffer(depth)
	var mask_buf: ImageBuffer = _to_buffer_r(mask) if mask != null else null

	var lo := INF
	var hi := -INF
	for i in w * h:
		var y := i / w
		var x := i % w
		if not _valid_pixel_buf(alpha_buf, mask_buf, x, y):
			continue
		var v := depth_buf.values[i]
		lo = minf(lo, v)
		hi = maxf(hi, v)

	var out := ImageBuffer.new(w, h)
	if not is_finite(lo) or not is_finite(hi):
		return _from_buffer_l8(out)

	var span := maxf(hi - lo, 0.00001)
	for i in w * h:
		var y := i / w
		var x := i % w
		if not _valid_pixel_buf(alpha_buf, mask_buf, x, y):
			out.values[i] = 0.0
			continue
		out.values[i] = (depth_buf.values[i] - lo) / span
	return _from_buffer_l8(out)


## Sobel gradients of the heightfield, encoded as a tangent-space normal map.
## Green is +Y up (OpenGL/glTF convention), matching Godot.
## Slope-to-normal conversion.
##
## No longer used for an asset's BASE normal -- MoGe and the GLB capture both
## supply a true one. It remains the arithmetic behind detail_normal_from_height,
## which converts the high-pass of the height field into fine surface grain, a
## genuinely different quantity from the base surface orientation.
func normal_from_height(height: Image, strength: float = 1.0) -> Image:
	var buf := _to_buffer_r(height)
	return _rgb8_buffer_to_image(_normal_from_height_buf(buf, strength), buf.width, buf.height)


## Buffer-native slope-to-normal, shared by the public wrapper above and
## detail_normal_from_height (which already has an ImageBuffer on hand and
## would otherwise pay to re-pack/re-unpack a PNG-shaped Image for no reason).
static func _normal_from_height_buf(height: ImageBuffer, strength: float = 1.0) -> PackedFloat32Array:
	var w := height.width
	var h := height.height
	var out := PackedFloat32Array()
	out.resize(w * h * 3)
	var scale := maxf(strength, 0.001) * 4.0
	for y in h:
		var row_base := y * w
		for x in w:
			var left := height.sample(x - 1, y)
			var right := height.sample(x + 1, y)
			var above := height.sample(x, y - 1)
			var below := height.sample(x, y + 1)
			# Image rows increase downward, while tangent-space +Y points toward
			# the top of the authored image. The surface normal opposes the
			# height gradient, so below-minus-above is Godot's OpenGL/Y+ sign.
			var normal := Vector3(
				(left - right) * scale,
				(below - above) * scale,
				1.0
			).normalized()
			var i := (row_base + x) * 3
			out[i + 0] = normal.x * 0.5 + 0.5
			out[i + 1] = normal.y * 0.5 + 0.5
			out[i + 2] = normal.z * 0.5 + 0.5
	return out


## Horizon-sampling AO from the recovered height field.
##
## Invalid geometry pixels stay neutral white so a MoGe validity mask can never
## create dark seams around areas the model explicitly said were unreliable.
func ambient_occlusion_from_height(height: Image, mask: Image = null, radius: int = 6, samples: int = 8) -> Image:
	var w := height.get_width()
	var h := height.get_height()
	var height_buf := _to_buffer_r(height)
	var alpha_buf := _to_alpha_buffer(height)
	var mask_buf: ImageBuffer = _to_buffer_r(mask) if mask != null else null
	var out := ImageBuffer.new(w, h)
	var relief := float(maxi(radius, 1))

	# The sample-direction offsets depend only on radius/samples, never on
	# (x, y), so they are identical for every pixel -- computed once here
	# instead of re-running cos()/sin()/round() per pixel per sample, which
	# was pure repeated work in the original loop.
	var offsets_x := PackedInt32Array()
	var offsets_y := PackedInt32Array()
	offsets_x.resize(samples)
	offsets_y.resize(samples)
	for sample_index in samples:
		var angle := TAU * float(sample_index) / float(samples)
		offsets_x[sample_index] = int(round(cos(angle) * radius))
		offsets_y[sample_index] = int(round(sin(angle) * radius))

	for y in h:
		var row_base := y * w
		for x in w:
			var i := row_base + x
			if not _valid_pixel_buf(alpha_buf, mask_buf, x, y):
				out.values[i] = 1.0
				continue
			var centre := height_buf.values[i]
			var occlusion := 0.0
			var valid_samples := 0
			for sample_index in samples:
				var sx := clampi(x + offsets_x[sample_index], 0, w - 1)
				var sy := clampi(y + offsets_y[sample_index], 0, h - 1)
				if not _valid_pixel_buf(alpha_buf, mask_buf, sx, sy):
					continue
				var neighbour := height_buf.values[sy * w + sx]
				occlusion += maxf(0.0, neighbour - centre) * relief
				valid_samples += 1
			occlusion = clampf(occlusion / float(maxi(valid_samples, 1)), 0.0, 1.0)
			out.values[i] = 1.0 - occlusion

	return _from_buffer_l8(out)


## Laplacian of height: convex above 0.5, concave below.
## Invalid geometry pixels are neutral 0.5 because they should contribute no
## signed curvature when the renderer later composites this map into roughness.
func curvature_from_height(height: Image, mask: Image = null) -> Image:
	var w := height.get_width()
	var h := height.get_height()
	var height_buf := _to_buffer_r(height)
	var alpha_buf := _to_alpha_buffer(height)
	var mask_buf: ImageBuffer = _to_buffer_r(mask) if mask != null else null
	var out := ImageBuffer.new(w, h)

	for y in h:
		var row_base := y * w
		for x in w:
			var i := row_base + x
			if not _valid_pixel_buf(alpha_buf, mask_buf, x, y):
				out.values[i] = 0.5
				continue
			var centre := height_buf.values[i]
			var laplacian := (
				height_buf.sample(x - 1, y) + height_buf.sample(x + 1, y)
				+ height_buf.sample(x, y - 1) + height_buf.sample(x, y + 1)
				- 4.0 * centre
			)
			out.values[i] = clampf(0.5 - laplacian * 4.0, 0.0, 1.0)

	return _from_buffer_l8(out)


## High-frequency concavity derived from the recovered height field.
## Invalid pixels are neutral white because cavity is multiplied into AO.
func cavity_from_height(height: Image, mask: Image = null) -> Image:
	var w := height.get_width()
	var h := height.get_height()
	var height_buf := _to_buffer_r(height)
	var alpha_buf := _to_alpha_buffer(height)
	var mask_buf: ImageBuffer = _to_buffer_r(mask) if mask != null else null

	# The original blurred `height` unconditionally (clamped-edge sampling
	# only, no mask awareness) and only the OUTPUT pixel was gated by
	# validity -- this blurs the whole buffer once, same as before, just via
	# the separable two-pass filter instead of an O(r^2) resweep per pixel.
	var blurred_buf := _box_blur_buffer(height_buf, 2)

	var out := ImageBuffer.new(w, h)
	for y in h:
		var row_base := y * w
		for x in w:
			var i := row_base + x
			if not _valid_pixel_buf(alpha_buf, mask_buf, x, y):
				out.values[i] = 1.0
				continue
			var centre := height_buf.values[i]
			var blurred := blurred_buf.values[i]
			out.values[i] = clampf(1.0 + (centre - blurred) * 6.0, 0.0, 1.0)

	return _from_buffer_l8(out)


## Detail normal from the high-pass of height, for fine surface relief.
## Invalid geometry pixels are written as the neutral tangent-space normal.
func detail_normal_from_height(height: Image, mask: Image = null) -> Image:
	var w := height.get_width()
	var h := height.get_height()
	var height_buf := _to_buffer_r(height)
	var alpha_buf := _to_alpha_buffer(height)
	var mask_buf: ImageBuffer = _to_buffer_r(mask) if mask != null else null

	# Same "blur the whole buffer unconditionally, gate only the written
	# output" split as cavity_from_height -- see its comment.
	var blurred_buf := _box_blur_buffer(height_buf, 3)

	var high_pass := ImageBuffer.new(w, h)
	for y in h:
		var row_base := y * w
		for x in w:
			var i := row_base + x
			if not _valid_pixel_buf(alpha_buf, mask_buf, x, y):
				high_pass.values[i] = 0.5
				continue
			var detail := height_buf.values[i] - blurred_buf.values[i]
			var v := clampf(0.5 + detail * 3.0, 0.0, 1.0)
			# The original wrote high_pass into a real FORMAT_L8 Image, then
			# read it back through get_pixel() to compute the normal --
			# quantizing to a byte and back before the slope-to-normal step.
			# Reproducing that exact round-trip here (rather than keeping
			# full float precision) is what an OLD-vs-NEW comparison test
			# confirmed was needed for byte-identical output: this rewrite
			# is a speed change only, not a precision change.
			high_pass.values[i] = float(int(clampf(v * 255.0, 0.0, 255.0))) / 255.0

	var normal := _normal_from_height_buf(high_pass, 1.5)

	# Invalid pixels are overwritten to the neutral tangent-space normal AFTER
	# slope-to-normal conversion, exactly like the original operated on the
	# already-built `normal` Image in a second pass rather than pre-seeding
	# high_pass in a way that would also perturb valid neighbours' gradients.
	for y in h:
		var row_base := y * w
		for x in w:
			if not _valid_pixel_buf(alpha_buf, mask_buf, x, y):
				var i := (row_base + x) * 3
				normal[i + 0] = 0.5
				normal[i + 1] = 0.5
				normal[i + 2] = 1.0

	return _rgb8_buffer_to_image(normal, w, h)


## Approximate a tangent-space bent normal from the recovered height field.
##
## Each of eight horizon directions contributes in proportion to how open that
## direction is. Higher neighbours suppress their direction, so the resulting
## XY vector points away from nearby occluders while Z keeps the direction in
## the upper hemisphere. Neutral, fully symmetric surroundings resolve to the
## standard flat normal (0.5, 0.5, 1.0). This is deterministic and uses only
## geometry already accepted by the height/AO pipeline.
func bent_normal_from_height(height: Image, mask: Image = null, radius: int = 8, samples: int = 8) -> Image:
	var w := height.get_width()
	var h := height.get_height()
	var height_buf := _to_buffer_r(height)
	var alpha_buf := _to_alpha_buffer(height)
	var mask_buf: ImageBuffer = _to_buffer_r(mask) if mask != null else null
	var safe_radius := maxi(radius, 1)
	var safe_samples := maxi(samples, 1)

	# Direction/offset depend only on sample_index and the radius/sample
	# count, never on (x, y) -- hoisted out of the pixel loop for the same
	# reason as ambient_occlusion_from_height's offsets above.
	var dir_x := PackedFloat32Array()
	var dir_y := PackedFloat32Array()
	var offsets_x := PackedInt32Array()
	var offsets_y := PackedInt32Array()
	dir_x.resize(safe_samples)
	dir_y.resize(safe_samples)
	offsets_x.resize(safe_samples)
	offsets_y.resize(safe_samples)
	for sample_index in safe_samples:
		var angle := TAU * float(sample_index) / float(safe_samples)
		dir_x[sample_index] = cos(angle)
		dir_y[sample_index] = sin(angle)
		offsets_x[sample_index] = int(round(dir_x[sample_index] * safe_radius))
		offsets_y[sample_index] = int(round(dir_y[sample_index] * safe_radius))

	var out := PackedFloat32Array()
	out.resize(w * h * 3)

	for y in h:
		var row_base := y * w
		for x in w:
			var out_i := (row_base + x) * 3
			if not _valid_pixel_buf(alpha_buf, mask_buf, x, y):
				out[out_i + 0] = 0.5
				out[out_i + 1] = 0.5
				out[out_i + 2] = 1.0
				continue

			var centre := height_buf.values[row_base + x]
			var direction_sum := Vector2.ZERO
			var weight_sum := 0.0

			for sample_index in safe_samples:
				var sx := clampi(x + offsets_x[sample_index], 0, w - 1)
				var sy := clampi(y + offsets_y[sample_index], 0, h - 1)
				if not _valid_pixel_buf(alpha_buf, mask_buf, sx, sy):
					continue

				var neighbour := height_buf.values[sy * w + sx]
				var rise := maxf(0.0, neighbour - centre)
				var openness := clampf(1.0 - rise * float(safe_radius), 0.0, 1.0)
				direction_sum += Vector2(dir_x[sample_index], dir_y[sample_index]) * openness
				weight_sum += openness

			var lateral := Vector2.ZERO
			if weight_sum > 0.0001:
				lateral = direction_sum / weight_sum

			var bent := Vector3(lateral.x, -lateral.y, 1.0).normalized()
			out[out_i + 0] = bent.x * 0.5 + 0.5
			out[out_i + 1] = bent.y * 0.5 + 0.5
			out[out_i + 2] = bent.z * 0.5 + 0.5

	return _rgb8_buffer_to_image(out, w, h)


## Pack the shader's final R=AO, G=roughness, B=metallic values, including the selected analysis-map bake strengths.
##
## The formulas intentionally match the former material-factory composites:
## cavity multiplies broad AO toward its fine occlusion, while signed curvature
## smooths convex edges and roughens concave creases around neutral mid-grey.
func pack_orm(
	ao: Image,
	roughness: Image,
	metallic: Image,
	cavity: Image = null,
	curvature: Image = null,
	cavity_strength: float = 1.0,
	curvature_strength: float = 1.0
) -> Image:
	var w := ao.get_width()
	var h := ao.get_height()
	var ao_buf := _to_buffer_r(ao)
	var rough_buf := _to_buffer_r(roughness)
	var metal_buf := _to_buffer_r(metallic)
	var cavity_buf: ImageBuffer = _to_buffer_r(cavity) if cavity != null else null
	var curvature_buf: ImageBuffer = _to_buffer_r(curvature) if curvature != null else null
	var cavity_mix := clampf(cavity_strength, 0.0, 1.0)
	var curvature_mix := clampf(curvature_strength, 0.0, 1.0)

	var out := PackedFloat32Array()
	out.resize(w * h * 3)
	for y in h:
		var row_base := y * w
		for x in w:
			var pixel_index := row_base + x
			var output_index := pixel_index * 3
			var ao_value := ao_buf.values[pixel_index]
			if cavity_buf != null:
				var cavity_value := cavity_buf.sample_scaled(x, y, w, h)
				ao_value *= lerpf(1.0, cavity_value, cavity_mix)
			var roughness_value := rough_buf.sample_scaled(x, y, w, h)
			if curvature_buf != null:
				var curvature_value := curvature_buf.sample_scaled(x, y, w, h)
				roughness_value += (0.5 - curvature_value) * curvature_mix
			out[output_index + 0] = clampf(ao_value, 0.0, 1.0)
			out[output_index + 1] = clampf(roughness_value, 0.0, 1.0)
			out[output_index + 2] = metal_buf.sample_scaled(x, y, w, h)

	return _rgb8_buffer_to_image(out, w, h)


## Combine a source normal and derived detail normal with the exact tangent-space rule formerly used per fragment.
func combine_tangent_normals(base_normal: Image, detail_normal: Image, strength: float) -> Image:
	var base := base_normal.duplicate() as Image
	var detail := detail_normal.duplicate() as Image
	if base.is_compressed() and base.decompress() != OK:
		return base_normal.duplicate() as Image
	if detail.is_compressed() and detail.decompress() != OK:
		return base_normal.duplicate() as Image
	var w := base.get_width()
	var h := base.get_height()
	if detail.get_size() != Vector2i(w, h):
		detail.resize(w, h, Image.INTERPOLATE_BILINEAR)
	base.convert(Image.FORMAT_RGBAF)
	detail.convert(Image.FORMAT_RGBAF)
	var base_values := base.get_data().to_float32_array()
	var detail_values := detail.get_data().to_float32_array()
	var out := PackedFloat32Array()
	out.resize(w * h * 3)
	var blend := clampf(strength, 0.0, 1.0)
	for pixel_index in w * h:
		var source_index := pixel_index * 4
		var output_index := pixel_index * 3
		var base_value := Vector3(
			base_values[source_index + 0] * 2.0 - 1.0,
			base_values[source_index + 1] * 2.0 - 1.0,
			base_values[source_index + 2] * 2.0 - 1.0
		).normalized()
		var detail_value := Vector3(
			detail_values[source_index + 0] * 2.0 - 1.0,
			detail_values[source_index + 1] * 2.0 - 1.0,
			detail_values[source_index + 2] * 2.0 - 1.0
		).normalized()
		var combined := Vector3(
			base_value.x + detail_value.x,
			base_value.y + detail_value.y,
			maxf(base_value.z * detail_value.z, 0.001)
		).normalized()
		var baked := base_value.lerp(combined, blend).normalized()
		out[output_index + 0] = baked.x * 0.5 + 0.5
		out[output_index + 1] = baked.y * 0.5 + 0.5
		out[output_index + 2] = baked.z * 0.5 + 0.5
	return _rgb8_buffer_to_image(out, w, h)


# --- Raw-buffer access ------------------------------------------------------
#
# Every processor below used to call Image.get_pixel()/set_pixel() per texel.
# Each of those calls allocates a Color, branches on format and does bounds
# checking -- on a multi-million-pixel GLB capture, done per neighbour sample
# in AO/cavity/detail-normal/bent-normal, that dominated GLB import time. The
# maths is unchanged; only the access pattern is. See ImageBuffer below.

## A single-channel (FORMAT_L8) image unpacked once into a flat float array.
##
## Godot's own Image::_get_color_at_ofs for FORMAT_L8 (core/io/image.cpp) is
## `l = byte / 255.0`, replicated to R=G=B, A=1 -- verified against Godot
## 4.6's source directly rather than assumed, since a wrong byte layout here
## would silently corrupt every derived map. values[] holds exactly that same
## `byte / 255.0`, row-major, top-to-bottom (offset = y * width + x), so
## sampling this buffer reads identically to the old image.get_pixel(x,y).r.
class ImageBuffer:
	var width: int
	var height: int
	var values: PackedFloat32Array

	func _init(w: int, h: int) -> void:
		width = w
		height = h
		values.resize(w * h)

	## Clamped sample, replacing every _sample(image, x, y) call site.
	func sample(x: int, y: int) -> float:
		var cx := clampi(x, 0, width - 1)
		var cy := clampi(y, 0, height - 1)
		return values[cy * width + cx]

	func set_value(x: int, y: int, v: float) -> void:
		values[y * width + x] = v

	## Sample at a position normalized against a DIFFERENT reference w/h,
	## replacing _sample_scaled(image, x, y, w, h) -- lets pack_orm tolerate
	## channels that came back at different resolutions, same as before.
	func sample_scaled(x: int, y: int, ref_w: int, ref_h: int) -> float:
		var sx := clampi(int(float(x) / float(maxi(ref_w, 1)) * width), 0, width - 1)
		var sy := clampi(int(float(y) / float(maxi(ref_h, 1)) * height), 0, height - 1)
		return values[sy * width + sx]


## Unpack an image's RED channel into an ImageBuffer, matching get_pixel(x,y).r.
##
## Height/depth/AO/etc. sources are produced by this pipeline as FORMAT_L8,
## where R=G=B, so reading the red channel is correct for those.
## An externally-attached "depth" map (see normalize_height's legacy path
## comment) is not guaranteed to be L8, so this unpacks via Image's own
## convert(FORMAT_RF) rather than assuming a byte layout for a format this
## pipeline does not control -- one conversion per image, not per pixel, so it
## does not reintroduce the per-texel get_pixel() cost this rewrite removes.
static func _to_buffer_r(image: Image) -> ImageBuffer:
	var w := image.get_width()
	var h := image.get_height()
	var buffer := ImageBuffer.new(w, h)
	var as_float := image.duplicate() as Image
	as_float.convert(Image.FORMAT_RF)
	var bytes := as_float.get_data()
	var floats := bytes.to_float32_array()
	for i in buffer.values.size():
		buffer.values[i] = floats[i]
	return buffer


## Unpack an image's ALPHA channel into an ImageBuffer, matching get_pixel(x,y).a.
##
## Same reasoning as _to_buffer_r: converts once via Image.convert rather than
## assuming a byte layout, since callers here may be format-legacy PNGs whose
## exact encoding this pipeline does not control. FORMAT_L8 has no alpha byte
## and Image::_get_color_at_ofs (core/io/image.cpp) returns a constant 1 for
## it, which Image.convert(FORMAT_RGBAF) reproduces -- an L8 source therefore
## comes back always-valid here, matching the original get_pixel(x,y).a
## behaviour exactly.
static func _to_alpha_buffer(image: Image) -> ImageBuffer:
	var w := image.get_width()
	var h := image.get_height()
	var buffer := ImageBuffer.new(w, h)
	var as_float := image.duplicate() as Image
	as_float.convert(Image.FORMAT_RGBAF)
	var bytes := as_float.get_data()
	var floats := bytes.to_float32_array()
	for i in buffer.values.size():
		buffer.values[i] = floats[i * 4 + 3]
	return buffer


## Pack an ImageBuffer's values back into an L8 Image via one set_data() call.
##
## Byte formula matches Image::_set_color_at_ofs's FORMAT_L8 case EXACTLY
## (core/io/image.cpp: `uint8_t(CLAMP(p_color.get_v() * 255.0, 0, 255))`) --
## a raw truncating cast, NOT round-to-nearest. Using `+ 0.5` here (rounding)
## instead of truncating was the actual bug an OLD-vs-NEW comparison test
## caught: it silently produced a systematically different byte than
## get_pixel/set_pixel would have, drifting by +-1/255 on every output pixel
## and compounding through every downstream neighbour-difference calculation
## (curvature's Laplacian amplified a 1-bit input drift into a 17-bit output
## error in that test). int() in GDScript truncates toward zero for a
## non-negative float, matching uint8_t(...) here.
static func _from_buffer_l8(buffer: ImageBuffer) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(buffer.values.size())
	for i in buffer.values.size():
		bytes[i] = int(clampf(buffer.values[i] * 255.0, 0.0, 255.0))
	var image := Image.create_empty(buffer.width, buffer.height, false, Image.FORMAT_L8)
	image.set_data(buffer.width, buffer.height, false, Image.FORMAT_L8, bytes)
	return image


## Pack a flat [r,g,b, r,g,b, ...] float array back into an RGB8 Image via one set_data() call.
##
## width/height are not recoverable from a flat PackedFloat32Array alone, so
## the caller passes the same w/h it used to build the array (always the
## source ImageBuffer's own dimensions -- see _normal_from_height_buf).
## Byte formula matches Image::_set_color_at_ofs's FORMAT_RGB8 case exactly
## (truncating cast, not round-to-nearest) -- see _from_buffer_l8's comment
## for why this specific detail matters.
static func _rgb8_buffer_to_image(rgb: PackedFloat32Array, w: int, h: int) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(rgb.size())
	for i in rgb.size():
		bytes[i] = int(clampf(rgb[i] * 255.0, 0.0, 255.0))
	var image := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	image.set_data(w, h, false, Image.FORMAT_RGB8, bytes)
	return image


# --- Helpers --------------------------------------------------------------

## True when a channel is absent or already points at this pipeline's own output.
##
## This is the provenance rule that keeps regeneration honest: derived outputs
## refresh when their upstream map changes, while a map attached/generated by a
## different source path remains authoritative and is never silently replaced.
func _derived_or_missing(maps: GBufferMapSet, channel: String, expected_path: String) -> bool:
	var current := maps.get_channel(channel)
	return current.is_empty() or current == expected_path


## Whether one geometry-derived texel is valid, sampling pre-unpacked alpha buffers.
##
## An explicit MoGe mask wins when present. Otherwise the source image alpha is
## used, which naturally masks transparent GLB render targets while treating
## ordinary opaque PNG analysis maps as fully valid. mask_w/mask_h are the
## mask buffer's own dimensions -- the mask is commonly a different resolution
## than source, so the lookup is nearest-neighbour remapped exactly like the
## original mask.get_pixel(mx, my) call was.
static func _valid_pixel_buf(
	source_alpha: ImageBuffer,
	mask: ImageBuffer,
	x: int,
	y: int
) -> bool:
	if source_alpha.values[y * source_alpha.width + x] <= 0.001:
		return false
	if mask == null:
		return true
	var mx := clampi(int(float(x) / float(maxi(source_alpha.width, 1)) * mask.width), 0, mask.width - 1)
	var my := clampi(int(float(y) / float(maxi(source_alpha.height, 1)) * mask.height), 0, mask.height - 1)
	return mask.values[my * mask.width + mx] >= 0.5


## Average a square neighbourhood via a separable two-pass box blur.
##
## The original _box_blur re-swept the full (2r+1)x(2r+1) window from scratch
## for every pixel: O(r^2) samples per pixel, called per pixel, so a radius-3
## call (called by detail_normal_from_height) touched 49 texels per output
## texel. A box filter is separable -- horizontal-then-vertical produces the
## IDENTICAL average, since averaging is linear and commutes across axes --
## so this instead does one O(r) horizontal pass over the whole image, then
## one O(r) vertical pass over the result: O(r) per pixel, not O(r^2), with no
## change in the numeric result (both compute the same sum / same count).
static func _box_blur_buffer(source: ImageBuffer, radius: int) -> ImageBuffer:
	var w := source.width
	var h := source.height
	var horizontal := ImageBuffer.new(w, h)
	for y in h:
		var row_base := y * w
		for x in w:
			var total := 0.0
			for dx in range(-radius, radius + 1):
				var cx := clampi(x + dx, 0, w - 1)
				total += source.values[row_base + cx]
			horizontal.values[row_base + x] = total / float(radius * 2 + 1)

	var out := ImageBuffer.new(w, h)
	for y in h:
		for x in w:
			var total := 0.0
			for dy in range(-radius, radius + 1):
				var cy := clampi(y + dy, 0, h - 1)
				total += horizontal.values[cy * w + x]
			out.values[y * w + x] = total / float(radius * 2 + 1)

	return out


## Load one map directly from disk when possible so fresh generated files do not depend on an editor import scan.
func _load_image(maps: GBufferMapSet, channel: String) -> Image:
	var path := maps.get_channel(channel)
	if path.is_empty():
		return null
	var image := Image.new()
	# Prefer loading from disk so freshly written files are picked up without
	# waiting for a filesystem rescan.
	var global_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global_path):
		if image.load(global_path) == OK:
			return image
	if ResourceLoader.exists(path):
		var tex := ResourceLoader.load(path) as Texture2D
		if tex != null:
			return tex.get_image()
	return null


## Save one deterministic derived image and report the concrete path on failure.
func _save(image: Image, path: String) -> Error:
	if image == null:
		return ERR_INVALID_DATA
	var global_path := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	var err := image.save_png(global_path)
	if err != OK:
		push_warning("[Tile Studio] could not save derived map '%s' (%s)" % [path, error_string(err)])
	return err
