"""Persisted scene settings for heightfield authoring."""
from bpy.props import BoolProperty
from bpy.props import EnumProperty
from bpy.props import FloatProperty
from bpy.props import IntProperty
from bpy.types import PropertyGroup

class HF_Settings(PropertyGroup):
    output_mode: EnumProperty(
        name="Output",
        description="How the sampled grid is turned into geometry",
        items=[
            (
                'STEPPED',
                "Stepped Tiles",
                "One flat height per grid square; adds vertical faces between different heights",
            ),
            (
                'SURFACE',
                "Connected Surface",
                "Shared grid vertices form a continuous heightfield with sloped quads",
            ),
        ],
        default='STEPPED',
    )

    grid_size_m: FloatProperty(
        name="Grid Size (m)",
        description="Horizontal square size in meters",
        default=1.0,
        min=0.001,
        soft_max=10.0,
        precision=3,
    )

    snap_height: BoolProperty(
        name="Snap Heights",
        description="Quantize sampled heights to a fixed vertical increment",
        default=True,
    )

    height_step_m: FloatProperty(
        name="Height Step (m)",
        description="Vertical quantization increment in meters",
        default=1.0,
        min=0.001,
        soft_max=10.0,
        precision=3,
    )

    height_snap_mode: EnumProperty(
        name="Height Rounding",
        description="How sampled heights are quantized",
        items=[
            ('NEAREST', "Nearest", "Snap to the nearest height step"),
            ('FLOOR', "Floor", "Always snap downward"),
            ('CEIL', "Ceiling", "Always snap upward"),
        ],
        default='NEAREST',
    )

    grid_origin_x_m: FloatProperty(
        name="Grid Origin X (m)",
        description="World-space X origin used to align the grid",
        default=0.0,
        precision=3,
    )

    grid_origin_y_m: FloatProperty(
        name="Grid Origin Y (m)",
        description="World-space Y origin used to align the grid",
        default=0.0,
        precision=3,
    )

    height_origin_m: FloatProperty(
        name="Height Origin Z (m)",
        description="World-space Z origin used for vertical snapping",
        default=0.0,
        precision=3,
    )

    include_modifiers: BoolProperty(
        name="Use Evaluated Mesh",
        description="Sample the mesh after its modifiers have been evaluated",
        default=True,
    )

    respect_scene_units: BoolProperty(
        name="Respect Scene Unit Scale",
        description="Interpret the numeric size fields as real meters using Scene Unit Scale",
        default=True,
    )

    create_step_walls: BoolProperty(
        name="Create Step Walls",
        description="Create vertical faces wherever neighboring stepped cells have different heights",
        default=True,
    )

    band_step_walls: BoolProperty(
        name="Band Step Walls",
        description="Split vertical step faces into one height-step band per quad",
        default=True,
    )

    smooth_low_transitions: BoolProperty(
        name="Smooth Low Steps",
        description=(
            "After the stepped pass, connect neighboring cells whose vertical "
            "difference is at or below the smoothing threshold"
        ),
        default=False,
    )

    smooth_threshold_m: FloatProperty(
        name="Smooth Threshold (m)",
        description=(
            "Maximum vertical difference between neighboring cells that may be "
            "converted from a hard step into a connected slope"
        ),
        default=0.5,
        min=0.0,
        soft_max=5.0,
        precision=3,
    )

    smooth_threshold_basis: EnumProperty(
        name="Threshold Basis",
        description="Which heights are compared when deciding whether an edge is gentle",
        items=[
            (
                'SOURCE',
                "Original Samples",
                "Compare the unsnapped source samples; best for removing quantization stairs",
            ),
            (
                'OUTPUT',
                "Stepped Output",
                "Compare the post-snap stepped heights; useful when processing an already-stepped mesh",
            ),
        ],
        default='SOURCE',
    )

    boundary_skirt: BoolProperty(
        name="Boundary Skirt",
        description="Create vertical faces around exposed outer edges down to a base elevation",
        default=False,
    )

    boundary_base_mode: EnumProperty(
        name="Boundary Base",
        items=[
            ('SOURCE_MIN', "Source Minimum", "Use the source mesh's lowest Z as the boundary base"),
            ('CUSTOM', "Custom", "Use a custom world-space Z base"),
        ],
        default='SOURCE_MIN',
    )

    boundary_base_m: FloatProperty(
        name="Base Z (m)",
        description="Custom world-space Z for the bottom of boundary skirts",
        default=0.0,
        precision=3,
    )

    hide_source: BoolProperty(
        name="Hide Source",
        description="Hide the source object in the viewport after a successful conversion",
        default=False,
    )

    max_cells: IntProperty(
        name="Safety Cell Limit",
        description="Abort instead of accidentally creating an enormous grid",
        default=250000,
        min=100,
        soft_max=1000000,
    )

    manual_brush_show_outline: BoolProperty(
        name="Show Brush Outline",
        description="Show the current manual brush footprint in the 3D viewport",
        default=True,
    )

    slope_brush_radius_m: FloatProperty(
        name="Slope Radius (m)",
        description="Horizontal radius used to paint hard stair edges into slopes",
        default=0.65,
        min=0.05,
        soft_max=10.0,
        precision=2,
    )

    height_brush_action: EnumProperty(
        name="Height Action",
        description="Default direction for the manual height brush",
        items=[
            ('RAISE', "Raise", "Raise touched heightfield cells"),
            ('LOWER', "Lower", "Lower touched heightfield cells"),
        ],
        default='RAISE',
    )

    height_brush_increment_m: FloatProperty(
        name="Height Nudge (m)",
        description="Amount each touched cell moves per brush stroke",
        default=0.25,
        min=0.001,
        soft_max=5.0,
        precision=3,
    )

    height_brush_radius_cells: IntProperty(
        name="Height Radius (cells)",
        description="0 edits only the clicked cell; 1 edits a 3x3 neighborhood; and so on",
        default=0,
        min=0,
        max=32,
    )
