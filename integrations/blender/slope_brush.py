"""Modal slope brush with explicit draw-handler cleanup."""
from bpy.types import Operator
import bpy
from .edit_model import hf_distance_point_segment_2d
from .brush_drawing import hf_draw_screen_circle
from .edit_model import hf_edge_segment_xy
from .edit_model import hf_extract_edit_model
from .edit_model import hf_hard_edges
from .edit_model import hf_has_edit_attributes
from .brush_geometry import hf_local_radius_from_meters
from .edit_model import hf_rebuild_edit_mesh
from .brush_geometry import hf_view_ray_hit

class OBJECT_OT_heightfield_slope_brush(Operator):
    bl_idname = "object.heightfield_slope_brush"
    bl_label = "Slope Brush"
    bl_description = (
        "Paint hard stepped transitions into connected sloped quads. "
        "Left-drag paints; Enter or right-click commits; Esc cancels"
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
            self.report({'ERROR'}, f"Could not start Slope Brush: {exc}")
            return {'CANCELLED'}

        self._backup_mesh = self._obj.data.copy()
        self._base_smooth_edges = set(self._model["smooth_edges"])
        self._painted_edges = set()
        self._candidate_edges = hf_hard_edges(
            self._model,
            self._base_smooth_edges,
        )
        self._painting = False
        self._last_hit = None
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
            "Slope Brush: LMB drag paints slopes | Ctrl+Wheel or [ ] changes "
            "radius | MMB navigates | Enter/RMB commits | Esc cancels"
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
            if event.ctrl:
                factor = (
                    1.15
                    if event.type == 'WHEELUPMOUSE'
                    else 1.0 / 1.15
                )
                settings = context.scene.hf_settings
                settings.slope_brush_radius_m = max(
                    0.05,
                    min(100.0, settings.slope_brush_radius_m * factor),
                )
                context.area.tag_redraw()
                return {'RUNNING_MODAL'}
            return {'PASS_THROUGH'}

        if (
            event.type in {'LEFT_BRACKET', 'RIGHT_BRACKET'}
            and event.value == 'PRESS'
        ):
            factor = (
                1.15
                if event.type == 'RIGHT_BRACKET'
                else 1.0 / 1.15
            )
            settings = context.scene.hf_settings
            settings.slope_brush_radius_m = max(
                0.05,
                min(100.0, settings.slope_brush_radius_m * factor),
            )
            context.area.tag_redraw()
            return {'RUNNING_MODAL'}

        if event.type == 'LEFTMOUSE':
            if event.value == 'PRESS':
                self._painting = True
                self._update_hit(context, event)
                self._paint(context)
                context.area.tag_redraw()
                return {'RUNNING_MODAL'}

            if event.value == 'RELEASE':
                self._painting = False
                return {'RUNNING_MODAL'}

        if event.type == 'MOUSEMOVE':
            self._update_hit(context, event)

            if self._painting:
                self._paint(context)

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

    def _paint(self, context):
        if self._last_hit is None:
            return

        radius = hf_local_radius_from_meters(
            context,
            self._obj,
            context.scene.hf_settings.slope_brush_radius_m,
        )
        current_smooth = (
            self._base_smooth_edges
            | self._painted_edges
        )

        additions = set()

        for edge in self._candidate_edges:
            if edge in current_smooth:
                continue

            (ax, ay), (bx, by) = hf_edge_segment_xy(
                self._model,
                edge,
            )

            distance = hf_distance_point_segment_2d(
                self._last_hit.x,
                self._last_hit.y,
                ax,
                ay,
                bx,
                by,
            )

            if distance <= radius:
                additions.add(edge)

        if not additions:
            return

        self._painted_edges.update(additions)

        hf_rebuild_edit_mesh(
            context,
            self._obj,
            self._model,
            self._base_smooth_edges | self._painted_edges,
        )

    def _draw_callback(self, context):
        if self._last_hit is None or self._obj is None:
            return

        radius = hf_local_radius_from_meters(
            context,
            self._obj,
            context.scene.hf_settings.slope_brush_radius_m,
        )
        hf_draw_screen_circle(
            context,
            self._obj,
            self._last_hit,
            radius,
            (1.0, 0.55, 0.12, 0.95),
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
                "Slope Brush cancelled; starting mesh restored.",
            )
            if context.area:
                context.area.tag_redraw()
            return {'CANCELLED'}

        if self._backup_mesh.users == 0:
            bpy.data.meshes.remove(self._backup_mesh)

        self._obj["hf_manual_slope_brush"] = True
        self._obj["hf_manual_smooth_edge_count"] = len(
            self._painted_edges
        )

        self.report(
            {'INFO'},
            f"Slope Brush committed {len(self._painted_edges):,} "
            "hard-edge conversion(s).",
        )

        if context.area:
            context.area.tag_redraw()
        return {'FINISHED'}
