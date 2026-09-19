import torch

# Copy this file into your ComfyUI install's custom_nodes/ folder (e.g.
# ComfyUI/custom_nodes/mts_moge_height.py) and restart ComfyUI so it registers
# the MTSMoGeHeight node used by
# addons/modular_tile_studio/analysis/recipes/moge_geometry_api.json.
#
# MoGe's MOGE_GEOMETRY output carries a metric-scale XYZ point map (points:
# B×H×W×3, camera space) plus a validity mask. The stock MoGeRender node only
# exposes a display-normalized depth/disparity image, which is not directly
# comparable across assets in real units. This node instead measures the
# actual X/Y/Z extent of the object's valid points once, in metres, so the
# Godot-side pipeline can scale relief per-asset instead of guessing a flat
# multiplier.
#
# Two corrections are applied so the result is usable as a TILE heightfield
# rather than as a photograph of a scene:
#
#   flatten_camera_plane -- MoGe reconstructs through a perspective camera, so
#     a flat surface photographed at any angle returns a Z that ramps across
#     the frame. That ramp is viewing geometry, not relief, and it previously
#     turned flat ground plates into visibly tilted slabs. Fitting a plane to
#     the reconstruction and keeping only the residual re-poses the surface as
#     though viewed head-on, leaving the image's pixels as the X/Y grid and Z
#     as pure push/pull about a flat base.
#
#   zero_edges -- a tile must meet its neighbours at a shared height. Without
#     this each tile's border ends wherever its own content happened to reach,
#     so abutting tiles disagree at the seam. Pinning the rim to 0 makes the
#     base plane the common reference every tile shares.
#
# Both are exposed as node inputs rather than hardcoded, so the analysis graph
# shows exactly what was applied to a given asset.


class MTSMoGeHeight:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "moge_geometry": ("MOGE_GEOMETRY",),
                # Remove the camera-induced ramp. MoGe views the photo through a
                # perspective camera, so a perfectly FLAT surface still returns a
                # Z that slides smoothly across the frame -- purely viewing
                # geometry, not relief. Fitting and subtracting that plane
                # re-poses the point cloud as if viewed dead-on, which is what
                # makes a flat tile read as flat.
                "flatten_camera_plane": ("BOOLEAN", {"default": True}),
                # Force the outermost border of the map to 0 so a tile's edges
                # meet its neighbours at a common height instead of each tile
                # ending at whatever its own content happened to reach.
                "zero_edges": ("BOOLEAN", {"default": True}),
                # Width of that border as a fraction of the shorter image side.
                "edge_falloff": ("FLOAT", {
                    "default": 0.04, "min": 0.0, "max": 0.4, "step": 0.005,
                }),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    RETURN_NAMES = ("height",)
    FUNCTION = "execute"
    CATEGORY = "MTS"
    OUTPUT_NODE = True

    ## Fit z = a*x + b*y + c over the valid pixels and return the residual.
    ##
    ## Solved by least squares on the pixel grid rather than on the metric X/Y,
    ## because the pixel grid is exactly the UV space the height map is consumed
    ## in -- the tilt to cancel is the one visible across the IMAGE, and fitting
    ## in metric X/Y would leave a residual ramp wherever the reconstruction's
    ## own X/Y is itself skewed by the same perspective.
    ##
    ## The residual is the part of Z that the plane does not explain, i.e. real
    ## local relief with the camera's viewing ramp removed. Returned in metres,
    ## still signed, so downstream code can measure a true peak-to-trough range.
    def _remove_camera_plane(self, z, valid):
        height, width = z.shape

        device = z.device
        ys, xs = torch.meshgrid(
            torch.linspace(0.0, 1.0, height, device=device),
            torch.linspace(0.0, 1.0, width, device=device),
            indexing="ij",
        )

        vx = xs[valid]
        vy = ys[valid]
        vz = z[valid]

        if vz.numel() < 3:
            return z - vz.mean() if vz.numel() else z

        # Design matrix [x, y, 1] -> plane coefficients by least squares.
        design = torch.stack(
            [vx, vy, torch.ones_like(vx)], dim=1
        ).double()
        target = vz.double().unsqueeze(1)

        try:
            solution = torch.linalg.lstsq(design, target).solution
        except Exception:
            # A degenerate fit (e.g. all points collinear) means there is no
            # meaningful plane to remove; fall back to removing only the mean so
            # the result is still centred but never silently mis-tilted.
            return z - vz.mean()

        a, b, c = (float(solution[0]), float(solution[1]), float(solution[2]))
        plane = a * xs + b * ys + c

        return z - plane

    ## Smooth 0..1 border mask: 0 at the outermost pixels, 1 inside.
    ##
    ## Multiplying the height by this pins a tile's rim to the base plane so
    ## adjacent tiles share an edge height and the slab closes instead of ending
    ## on an arbitrary value. smoothstep rather than a linear ramp avoids a
    ## visible crease where the falloff begins.
    def _edge_mask(self, height, width, falloff, device):
        if falloff <= 0.0:
            return torch.ones((height, width), device=device)

        ys = torch.linspace(0.0, 1.0, height, device=device).unsqueeze(1)
        xs = torch.linspace(0.0, 1.0, width, device=device).unsqueeze(0)

        # Distance to the nearest border, in 0..0.5 image-fraction units.
        dist_y = torch.minimum(ys, 1.0 - ys)
        dist_x = torch.minimum(xs, 1.0 - xs)
        dist = torch.minimum(dist_y, dist_x)

        t = (dist / max(falloff, 0.000001)).clamp(0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)

    def execute(
        self,
        moge_geometry,
        flatten_camera_plane=True,
        zero_edges=True,
        edge_falloff=0.04,
    ):
        if "points" not in moge_geometry:
            raise ValueError("MoGe geometry contains no XYZ point map.")

        points = moge_geometry["points"].float()

        valid = torch.isfinite(points).all(dim=-1)

        if "mask" in moge_geometry:
            valid &= moge_geometry["mask"].bool()

        heights = []
        metrics = []

        for b in range(points.shape[0]):
            p = points[b]
            v = valid[b]

            if not v.any():
                raise ValueError("MoGe produced no valid XYZ points.")

            valid_points = p[v]

            xyz_min = valid_points.amin(dim=0)
            xyz_max = valid_points.amax(dim=0)
            extent = xyz_max - xyz_min

            # MoGe returns Z increasing away from the camera, so relief is
            # -Z: nearer to the camera is higher.
            relief = -p[..., 2]

            if flatten_camera_plane:
                relief = self._remove_camera_plane(relief, v)

            # Everything from here on is measured on the FLATTENED relief, so
            # z_extent_m reports true peak-to-trough depth rather than the
            # camera ramp that previously dominated it on flat surfaces.
            valid_relief = relief[v]
            relief_min = float(valid_relief.amin())
            relief_max = float(valid_relief.amax())
            relief_range = relief_max - relief_min

            # A surface whose residual relief is below this is flat to within
            # the reconstruction's own noise floor. Normalizing it anyway would
            # stretch that noise across the full 0..1 range and emit a map that
            # LOOKS like detailed relief while representing nothing -- which is
            # exactly how a flat ground plate acquired visible fake structure.
            # Emitting a genuinely flat map keeps "no measurable relief" honest
            # and legible in the map itself, not just in the reported metric.
            FLAT_EPSILON_M = 0.0005

            normalized = torch.zeros_like(relief)
            if relief_range > FLAT_EPSILON_M:
                normalized[v] = (
                    (valid_relief - relief_min) / relief_range
                ).clamp(0.0, 1.0)
            else:
                relief_range = 0.0

            if zero_edges:
                mask = self._edge_mask(
                    relief.shape[0], relief.shape[1], edge_falloff, relief.device
                )
                # Multiplying pulls the border to 0 while leaving interior
                # values on their own relative scale, which is what keeps the
                # tile's own relief intact but makes its rim meet its
                # neighbours at a shared height.
                normalized = normalized * mask

            heights.append(normalized.unsqueeze(-1).repeat(1, 1, 3))

            # After edge pinning the usable relief no longer spans the full
            # measured range, so report the range actually present in the
            # emitted map. Godot multiplies this by the map's 0..1 values, so a
            # mismatch here would scale every asset's relief incorrectly.
            emitted_span = float(normalized.amax() - normalized.amin())

            metrics.append({
                "x_extent_m": float(extent[0]),
                "y_extent_m": float(extent[1]),
                "z_extent_m": relief_range * emitted_span,
            })

        output = torch.stack(heights, dim=0)

        return {
            "ui": {
                "mts_moge_metrics": metrics,
            },
            "result": (output,),
        }


NODE_CLASS_MAPPINGS = {
    "MTSMoGeHeight": MTSMoGeHeight,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "MTSMoGeHeight": "MTS MoGe Metric Height",
}
