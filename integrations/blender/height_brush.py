"""Modal height brush with explicit draw-handler cleanup."""
from .edit_model import HF_CORNER_NAMES
from bpy.types import Operator
import bpy
from .brush_drawing import hf_draw_screen_circle
from .edit_model import hf_extract_edit_model
from .brush_geometry import hf_face_cell
from .edit_model import hf_has_edit_attributes
from .brush_geometry import hf_local_radius_from_meters
from .edit_model import hf_rebuild_edit_mesh
from .brush_geometry import hf_view_ray_hit
from .units import meters_to_bu

class OBJECT_OT_heightfield_height_brush(Operator):
    bl_idname = "object.heightfield_height_brush"
    bl_label = "Raise / Lower Brush"
    bl_description = (
        "Raise or lower whole heightfield cells. LMB uses the selected action; "
        "hold Ctrl to temporarily invert it"
    )
    bl_options = {'REGISTER', 'UNDO', 'BLOCKING'}

    @classmethod
    def poll(cls, context):
        obj = context.active_object
        return (
            context.area is not None
            and context.area.type == 'VIEW_3D'
            and obj is not None
            and obj.type == 'MESH'
            and obj.mode == 'OBJECT'
            and hf_has_edit_attributes(obj)
        )

    def invoke(self, context, event):
        self._obj = context.active_object

        try:
            self._model = hf_extract_edit_model(self._obj)
        except Exception as exc:
            self.report({'ERROR'}, f"Could not start Height Brush: {exc}")
            return {'CANCELLED'}

        self._backup_mesh = self._obj.data.copy()
        self._smooth_edges = set(self._model["smooth_edges"])
        self._painting = False
        self._stroke_cells = set()
        self._last_hit = None
        self._hover_cell = None
        self._draw_handle = None

        try:
            context.window.cursor_modal_set('CROSSHAIR')
        except Exception:
            pass

        if context.scene.hf_settings.manual_brush_show_outline:
            try:
                self._draw_handle = bpy.types.SpaceView3D.draw_handler_add(
                    self._draw_callback,
                    (context,),
                    'WINDOW',
                    'POST_PIXEL',
                )
            except Exception:
                self._draw_handle = None

        context.window_manager.modal_handler_add(self)
        context.workspace.status_text_set(
            "Height Brush: LMB = selected Raise/Lower action | Ctrl+LMB = "
            "opposite | [ ] changes cell radius | MMB navigates | "
            "Enter/RMB commits | Esc cancels"
        )

        self._update_hit(context, event)
        context.area.tag_redraw()
        return {'RUNNING_MODAL'}

    def modal(self, context, event):
        if self._obj is None or self._obj.name not in bpy.data.objects:
            return self._finish(context, True)

        if event.type == 'ESC':
            return self._finish(context, True)

        if (
            event.type in {'RET', 'NUMPAD_ENTER', 'SPACE', 'RIGHTMOUSE'}
            and event.value == 'PRESS'
        ):
            return self._finish(context, False)

        if event.type == 'MIDDLEMOUSE':
            return {'PASS_THROUGH'}

        if event.type in {'WHEELUPMOUSE', 'WHEELDOWNMOUSE'}:
            return {'PASS_THROUGH'}

        if (
            event.type in {'LEFT_BRACKET', 'RIGHT_BRACKET'}
            and event.value == 'PRESS'
        ):
            settings = context.scene.hf_settings
            if event.type == 'RIGHT_BRACKET':
                settings.height_brush_radius_cells = min(
                    32,
                    settings.height_brush_radius_cells + 1,
                )
            else:
                settings.height_brush_radius_cells = max(
                    0,
                    settings.height_brush_radius_cells - 1,
                )
            context.area.tag_redraw()
            return {'RUNNING_MODAL'}

        if event.type == 'LEFTMOUSE':
            if event.value == 'PRESS':
                self._painting = True
                self._stroke_cells.clear()
                self._update_hit(context, event)
                self._paint(context, invert=event.ctrl)
                context.area.tag_redraw()
                return {'RUNNING_MODAL'}

            if event.value == 'RELEASE':
                self._painting = False
                self._stroke_cells.clear()
                return {'RUNNING_MODAL'}

        if event.type == 'MOUSEMOVE':
            self._update_hit(context, event)

            if self._painting:
                self._paint(context, invert=event.ctrl)

            context.area.tag_redraw()
            return {'RUNNING_MODAL'}

        return {'RUNNING_MODAL'}

    def _update_hit(self, context, event):
        self._last_hit, face_index = hf_view_ray_hit(
            context,
            self._obj,
            event.mouse_region_x,
            event.mouse_region_y,
        )
        self._hover_cell = hf_face_cell(self._obj, face_index)

        if (
            self._hover_cell is not None
            and self._hover_cell not in self._model["cells"]
        ):
            self._hover_cell = None

    def _paint(self, context, invert=False):
        if self._hover_cell is None:
            return

        settings = context.scene.hf_settings
        radius = settings.height_brush_radius_cells
        cx, cy = self._hover_cell

        targets = set()
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                pos = (cx + dx, cy + dy)
                if pos in self._model["cells"]:
                    targets.add(pos)

        targets.difference_update(self._stroke_cells)
        if not targets:
            return

        action = settings.height_brush_action
        if invert:
            action = 'LOWER' if action == 'RAISE' else 'RAISE'

        sign = 1.0 if action == 'RAISE' else -1.0

        respect_units = bool(
            self._obj.get(
                "hf_respect_scene_units",
                settings.respect_scene_units,
            )
        )
        delta_bu = meters_to_bu(
            context.scene,
            settings.height_brush_increment_m * sign,
            respect_units,
        )
        delta_m = settings.height_brush_increment_m * sign

        for cell_pos in targets:
            cell = self._model["cells"][cell_pos]

            for corner_name in HF_CORNER_NAMES:
                cell["base_corner_z"][corner_name] += delta_bu

            cell["height_m"] += delta_m

        self._stroke_cells.update(targets)

        hf_rebuild_edit_mesh(
            context,
            self._obj,
            self._model,
            self._smooth_edges,
        )

    def _draw_callback(self, context):
        if self._last_hit is None or self._obj is None:
            return

        settings = context.scene.hf_settings
        grid_m = float(
            self._obj.get("hf_grid_size_m", settings.grid_size_m)
        )
        radius_m = (
            settings.height_brush_radius_cells + 0.55
        ) * grid_m

        radius_local = hf_local_radius_from_meters(
            context,
            self._obj,
            radius_m,
        )

        color = (
            (0.2, 0.9, 0.35, 0.95)
            if settings.height_brush_action == 'RAISE'
            else (0.25, 0.55, 1.0, 0.95)
        )

        hf_draw_screen_circle(
            context,
            self._obj,
            self._last_hit,
            radius_local,
            color,
        )

    def _finish(self, context, cancelled):
        try:
            if self._draw_handle is not None:
                bpy.types.SpaceView3D.draw_handler_remove(
                    self._draw_handle,
                    'WINDOW',
                )
        except Exception:
            pass

        try:
            context.window.cursor_modal_restore()
        except Exception:
            pass

        try:
            context.workspace.status_text_set(None)
        except Exception:
            pass

        if cancelled:
            current_mesh = self._obj.data
            self._obj.data = self._backup_mesh
            context.view_layer.update()

            if current_mesh.users == 0:
                bpy.data.meshes.remove(current_mesh)

            self.report(
                {'INFO'},
                "Height Brush cancelled; starting mesh restored.",
            )
            if context.area:
                context.area.tag_redraw()
            return {'CANCELLED'}

        if self._backup_mesh.users == 0:
            bpy.data.meshes.remove(self._backup_mesh)

        self._obj["hf_manual_height_brush"] = True

        self.report(
            {'INFO'},
            "Height Brush edits committed.",
        )

        if context.area:
            context.area.tag_redraw()
        return {'FINISHED'}
