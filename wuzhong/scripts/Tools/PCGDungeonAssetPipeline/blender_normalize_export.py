"""Normalize screened FantasyDungeon meshes and export them by Marker.

Run with Blender, not the system Python:

    blender.exe --background --factory-startup --python blender_normalize_export.py

The Unreal source assets and intermediate FBX files are read-only inputs. Blender
work files, final FBX files, catalogs, and validation reports are written below
OUTPUT_ROOT.
"""

import argparse
import csv
import json
import math
import os
import re
import sys
import traceback
from collections import Counter
from datetime import datetime, timezone

import bpy
from mathutils import Vector


OUTPUT_ROOT = os.environ.get(
    "PCG_ASSET_OUTPUT_ROOT",
    r"D:\SUMIT\ProjectCity\Exports\FantasyDungeonByMarker",
)
INVENTORY_PATH = os.path.join(OUTPUT_ROOT, "catalog", "unreal_inventory.json")
FINAL_CATALOG_PATH = os.path.join(OUTPUT_ROOT, "catalog", "asset_catalog.json")
FINAL_CSV_PATH = os.path.join(OUTPUT_ROOT, "catalog", "asset_catalog.csv")
VALIDATION_REPORT_PATH = os.path.join(
    OUTPUT_ROOT, "catalog", "blender_validation_report.json"
)

FBX_AXIS_FORWARD = "Z"
FBX_AXIS_UP = "Y"
EPSILON = 1.0e-5

PIVOT_NOTES = {
    "cell_center_floor": "单格水平中心的地面接触平面；地板实体向下延伸",
    "wall_segment_center_floor": "墙段水平中心的墙脚接触平面",
    "door_frame_base_center": "门洞/门框水平中心的地面基准面",
    "door_hinge_base": "门扇真实铰链边的底部；优先保留已位于铰链底部的源 Pivot",
    "wall_endpoint_base": "墙端点、转角柱或连接件的底部中心",
    "stair_lower_start_floor": "楼梯下层起步边中心；附属件使用自身底部安装中心",
    "ceil_underside_center": "天花室内可见底面中心，实体向上延伸",
    "pillar_base_floor": "落地装饰底座支撑面的中心",
    "corner_mount": "角落/安装面挂点；保留源资产定义的安装原点并要求人工复核",
    "curbstone_segment_center_floor": "墙脚石段的水平中心和底面接触平面",
    "scatter_bottom_center": "最低支撑带投影凸包的面积中心，不取任意最低顶点",
    "light_emission_center": "灯具包围盒中心的自动发光点代理；必须结合灯泡/火焰位置人工复核",
}

TARGET_Z_AXIS_DIRECTIONS = {
    "Ground": "grid_forward",
    "Wall": "along_wall_segment",
    "Door": "along_door_width",
    "WallSeparator": "canonical_asset_forward",
    "Stair": "stair_upward_travel",
    "Ceil": "grid_forward",
    "PillarPlacement": "decoration_forward",
    "PillarWebPlacement": "decoration_spread_direction",
    "Curbstone01Placement": "along_wall_segment",
    "GroundScatterSurface": "asset_reference_forward",
    "Light": "fixture_length_or_spread",
}


def parse_arguments():
    arguments = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", default=INVENTORY_PATH)
    parser.add_argument("--output-root", default=OUTPUT_ROOT)
    parser.add_argument("--asset-id", action="append", default=[])
    parser.add_argument("--limit", type=int, default=0)
    return parser.parse_args(arguments)


def round_number(value, digits=6):
    number = round(float(value), digits)
    return 0.0 if abs(number) < 10 ** (-digits) else number


def round_vector(value, digits=6):
    return [round_number(component, digits) for component in value]


def safe_name(value):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("._")


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0
    scene.unit_settings.length_unit = "METERS"
    scene["pipeline"] = "PCGDungeonAssetPipeline"
    scene["blender_work_axis"] = "X right, Y horizontal, Z up"
    scene["target_axis"] = "X right, Y up, Z forward"
    scene["fbx_axis_forward"] = FBX_AXIS_FORWARD
    scene["fbx_axis_up"] = FBX_AXIS_UP


def mesh_objects():
    return [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]


def prepare_single_mesh(asset_id):
    objects = mesh_objects()
    if not objects:
        raise RuntimeError("FBX import contains no mesh object")

    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        world_matrix = obj.matrix_world.copy()
        obj.parent = None
        obj.matrix_world = world_matrix
        obj.hide_set(False)
        obj.hide_viewport = False
        obj.hide_render = False
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]

    # Bake Unreal's imported 0.01 object scale and any parent transforms into metres.
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    if len(objects) > 1:
        bpy.ops.object.join()

    obj = bpy.context.view_layer.objects.active
    obj.name = safe_name(asset_id)
    obj.data.name = obj.name + "_Mesh"
    return obj


def apply_axis_normalization(record, obj):
    rotation = record.get("axis_normalization_rotation_blender_deg")
    if rotation is None:
        if record.get("target_marker") == "Door" and record.get("subtype") in {
            "DoorLeaf",
            "DoorFrame",
            "Jail",
        }:
            rotation = [0.0, 0.0, -90.0]
        else:
            rotation = [0.0, 0.0, 0.0]
    if len(rotation) != 3 or not all(math.isfinite(float(value)) for value in rotation):
        raise RuntimeError("axis normalization rotation must contain three finite degrees")

    rotation = [float(value) for value in rotation]
    obj.rotation_euler = tuple(math.radians(value) for value in rotation)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return rotation


def apply_uniform_normalization(obj, scale):
    scale = float(scale)
    if not math.isfinite(scale) or scale <= 0:
        raise RuntimeError("normalization_uniform_scale must be a positive number")
    obj.scale = (scale, scale, scale)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return scale


def vertex_positions(obj):
    matrix = obj.matrix_world
    return [matrix @ vertex.co for vertex in obj.data.vertices]


def bounds_from_positions(positions):
    if not positions:
        raise RuntimeError("mesh has no vertices")
    minimum = Vector(
        (
            min(point.x for point in positions),
            min(point.y for point in positions),
            min(point.z for point in positions),
        )
    )
    maximum = Vector(
        (
            max(point.x for point in positions),
            max(point.y for point in positions),
            max(point.z for point in positions),
        )
    )
    return minimum, maximum


def cross_2d(origin, a, b):
    return (a[0] - origin[0]) * (b[1] - origin[1]) - (
        a[1] - origin[1]
    ) * (b[0] - origin[0])


def convex_hull_2d(points):
    unique = sorted(set((round(x, 8), round(y, 8)) for x, y in points))
    if len(unique) <= 2:
        return unique
    lower = []
    for point in unique:
        while len(lower) >= 2 and cross_2d(lower[-2], lower[-1], point) <= 0:
            lower.pop()
        lower.append(point)
    upper = []
    for point in reversed(unique):
        while len(upper) >= 2 and cross_2d(upper[-2], upper[-1], point) <= 0:
            upper.pop()
        upper.append(point)
    return lower[:-1] + upper[:-1]


def polygon_centroid(points):
    if not points:
        return 0.0, 0.0
    if len(points) < 3:
        return (
            sum(point[0] for point in points) / len(points),
            sum(point[1] for point in points) / len(points),
        )

    twice_area = 0.0
    centroid_x = 0.0
    centroid_y = 0.0
    for index, point in enumerate(points):
        following = points[(index + 1) % len(points)]
        cross = point[0] * following[1] - following[0] * point[1]
        twice_area += cross
        centroid_x += (point[0] + following[0]) * cross
        centroid_y += (point[1] + following[1]) * cross
    if abs(twice_area) < EPSILON:
        return (
            sum(point[0] for point in points) / len(points),
            sum(point[1] for point in points) / len(points),
        )
    return centroid_x / (3.0 * twice_area), centroid_y / (3.0 * twice_area)


def scatter_support_pivot(positions, minimum, maximum):
    height = maximum.z - minimum.z
    support_band = max(0.005, min(0.05, height * 0.05))
    support_points = [
        (point.x, point.y)
        for point in positions
        if point.z <= minimum.z + support_band + EPSILON
    ]
    if len(support_points) < 3:
        support_points = [(point.x, point.y) for point in positions if point.z <= minimum.z + EPSILON]
    hull = convex_hull_2d(support_points)
    if not hull:
        return Vector(
            ((minimum.x + maximum.x) * 0.5, (minimum.y + maximum.y) * 0.5, minimum.z)
        ), 0, support_band
    center_x, center_y = polygon_centroid(hull)
    return Vector((center_x, center_y, minimum.z)), len(hull), support_band


def source_origin_is_hinge(obj, minimum, maximum):
    origin = obj.matrix_world.translation
    horizontal_edge_distance = min(
        abs(origin.x - minimum.x),
        abs(origin.x - maximum.x),
        abs(origin.y - minimum.y),
        abs(origin.y - maximum.y),
    )
    return abs(origin.z - minimum.z) <= 0.10 and horizontal_edge_distance <= 0.15


def choose_pivot(record, obj, positions, minimum, maximum):
    center = (minimum + maximum) * 0.5
    rule = record["pivot_rule"]
    details = {"method": "bounding_box"}

    if rule == "cell_center_floor":
        pivot = Vector((center.x, center.y, maximum.z))
        details["method"] = "horizontal_bbox_center_top_surface"
    elif rule in {
        "wall_segment_center_floor",
        "wall_endpoint_base",
        "pillar_base_floor",
        "curbstone_segment_center_floor",
    }:
        pivot = Vector((center.x, center.y, minimum.z))
        details["method"] = "horizontal_bbox_center_bottom"
    elif rule == "door_frame_base_center":
        # Arch-only pieces often retain an intentional origin below their geometry.
        floor_z = 0.0 if minimum.z >= -0.15 else minimum.z
        pivot = Vector((center.x, center.y, floor_z))
        details["method"] = "horizontal_bbox_center_source_floor_datum"
    elif rule == "door_hinge_base":
        if source_origin_is_hinge(obj, minimum, maximum):
            pivot = obj.matrix_world.translation.copy()
            details["method"] = "preserved_verified_source_hinge_origin"
        else:
            candidates = [
                Vector((minimum.x, center.y, minimum.z)),
                Vector((maximum.x, center.y, minimum.z)),
                Vector((center.x, minimum.y, minimum.z)),
                Vector((center.x, maximum.y, minimum.z)),
            ]
            source_origin = obj.matrix_world.translation
            pivot = min(candidates, key=lambda value: (value - source_origin).length_squared)
            details["method"] = "nearest_bottom_bbox_edge_to_source_origin"
    elif rule == "stair_lower_start_floor":
        is_stair_body = record.get("source_relative_path", "").lower().startswith(
            "stairs/stairs"
        )
        if is_stair_body:
            pivot = Vector((center.x, minimum.y, minimum.z))
            details["method"] = "stair_width_center_lower_start_edge"
        else:
            pivot = Vector((center.x, center.y, minimum.z))
            details["method"] = "stair_attachment_bottom_center"
    elif rule == "ceil_underside_center":
        pivot = Vector((center.x, center.y, minimum.z))
        details["method"] = "horizontal_bbox_center_underside"
    elif rule == "corner_mount":
        pivot = obj.matrix_world.translation.copy()
        details["method"] = "preserved_source_mount_origin"
        details["manual_review"] = "确认源 Pivot 位于实际角落安装点"
    elif rule == "scatter_bottom_center":
        pivot, hull_vertex_count, support_band = scatter_support_pivot(
            positions, minimum, maximum
        )
        details["method"] = "bottom_support_band_convex_hull_centroid"
        details["support_hull_vertex_count"] = hull_vertex_count
        details["support_band_m"] = round_number(support_band)
    elif rule == "light_emission_center":
        pivot = center
        details["method"] = "bbox_center_emission_proxy"
        details["manual_review"] = "确认 Pivot 与灯泡、火焰或实际安装点一致"
    else:
        raise RuntimeError("unsupported pivot_rule: {}".format(rule))
    return pivot, details


def move_pivot_to_origin(obj, pivot):
    inverse = obj.matrix_world.inverted()
    local_pivot = inverse @ pivot
    for vertex in obj.data.vertices:
        vertex.co -= local_pivot
    obj.location = (0.0, 0.0, 0.0)
    obj.rotation_euler = (0.0, 0.0, 0.0)
    obj.scale = (1.0, 1.0, 1.0)
    obj.data.update()


def add_asset_metadata(obj, record, pivot_source, pivot_details, scale, axis_rotation):
    marker = record["target_marker"]
    obj["asset_id"] = record["asset_id"]
    obj["source_asset"] = record["source_asset"]
    obj["target_marker"] = marker
    obj["pivot_rule"] = record["pivot_rule"]
    obj["pivot_note"] = PIVOT_NOTES[record["pivot_rule"]]
    obj["pivot_position_target_m"] = [0.0, 0.0, 0.0]
    obj["pivot_source_blender_m"] = round_vector(pivot_source)
    obj["pivot_method"] = pivot_details["method"]
    obj["x_axis_direction"] = record["x_axis_direction"]
    obj["y_axis_direction"] = record["y_axis_direction"]
    obj["z_axis_direction"] = TARGET_Z_AXIS_DIRECTIONS.get(marker, "asset_defined")
    obj["uniform_scale"] = True
    obj["normalization_uniform_scale"] = scale
    obj["blender_work_up_axis"] = "+Z"
    obj["target_up_axis"] = "+Y"
    obj["target_axis_mapping"] = "Blender X->target X, Blender Z->target Y, Blender Y->target Z"
    obj["axis_normalization_rotation_blender_deg"] = axis_rotation
    obj["fbx_axis_forward"] = FBX_AXIS_FORWARD
    obj["fbx_axis_up"] = FBX_AXIS_UP


def ensure_output_directories(output_root, marker):
    marker_root = os.path.join(output_root, "ByMarker", marker)
    model_directory = os.path.join(marker_root, "Models")
    blender_directory = os.path.join(marker_root, "Blender")
    os.makedirs(model_directory, exist_ok=True)
    os.makedirs(blender_directory, exist_ok=True)
    return model_directory, blender_directory


def export_asset(obj, fbx_path, blend_path):
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.wm.save_as_mainfile(
        filepath=blend_path,
        check_existing=False,
        compress=True,
    )
    # Blender creates a numbered backup when the same output is regenerated.
    # The backup is not part of the fixed delivery layout.
    backup_path = blend_path + "1"
    if os.path.isfile(backup_path):
        os.remove(backup_path)
    bpy.ops.export_scene.fbx(
        filepath=fbx_path,
        check_existing=False,
        use_selection=True,
        global_scale=1.0,
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_NONE",
        use_space_transform=True,
        bake_space_transform=False,
        object_types={"MESH"},
        use_mesh_modifiers=True,
        mesh_smooth_type="OFF",
        use_mesh_edges=False,
        use_tspace=False,
        use_triangles=False,
        use_custom_props=True,
        bake_anim=False,
        path_mode="AUTO",
        embed_textures=False,
        axis_forward=FBX_AXIS_FORWARD,
        axis_up=FBX_AXIS_UP,
    )


def close_enough_vector(actual, expected, tolerance=2.0e-4):
    return all(abs(float(a) - float(b)) <= tolerance for a, b in zip(actual, expected))


def validate_roundtrip(fbx_path, expected_dimensions, record):
    reset_scene()
    bpy.ops.import_scene.fbx(
        filepath=fbx_path,
        global_scale=1.0,
        use_custom_props=True,
        use_anim=False,
    )
    objects = mesh_objects()
    errors = []
    if len(objects) != 1:
        errors.append("roundtrip_mesh_object_count={}".format(len(objects)))
        return errors, {}

    obj = objects[0]
    actual_dimensions = [float(value) for value in obj.dimensions]
    if not close_enough_vector(actual_dimensions, expected_dimensions):
        errors.append(
            "roundtrip_dimensions_mismatch actual={} expected={}".format(
                round_vector(actual_dimensions), round_vector(expected_dimensions)
            )
        )
    if obj.matrix_world.translation.length > 2.0e-4:
        errors.append(
            "roundtrip_pivot_not_at_origin={}".format(
                round_vector(obj.matrix_world.translation)
            )
        )
    if max(obj.scale) - min(obj.scale) > EPSILON:
        errors.append("roundtrip_object_scale_is_not_uniform={}".format(round_vector(obj.scale)))
    if obj.get("pivot_rule") != record["pivot_rule"]:
        errors.append("roundtrip_pivot_rule_metadata_missing")
    if obj.get("x_axis_direction") != record["x_axis_direction"]:
        errors.append("roundtrip_x_axis_metadata_missing")
    if obj.get("y_axis_direction") != record["y_axis_direction"]:
        errors.append("roundtrip_y_axis_metadata_missing")
    uniform_metadata = obj.get("uniform_scale")
    if uniform_metadata is not True and uniform_metadata != 1:
        errors.append("roundtrip_uniform_scale_metadata_missing")

    positions = vertex_positions(obj)
    minimum, maximum = bounds_from_positions(positions)
    center = (minimum + maximum) * 0.5
    rule = record["pivot_rule"]
    pivot_tolerance = 5.0e-4
    if rule == "cell_center_floor":
        if abs(center.x) > pivot_tolerance or abs(center.y) > pivot_tolerance:
            errors.append("ground_pivot_not_at_horizontal_center")
        if abs(maximum.z) > pivot_tolerance:
            errors.append("ground_top_surface_not_at_pivot")
    elif rule in {
        "wall_segment_center_floor",
        "wall_endpoint_base",
        "pillar_base_floor",
        "curbstone_segment_center_floor",
        "ceil_underside_center",
    }:
        if abs(center.x) > pivot_tolerance or abs(center.y) > pivot_tolerance:
            errors.append("bottom_or_underside_pivot_not_at_horizontal_center")
        if abs(minimum.z) > pivot_tolerance:
            errors.append("bottom_or_underside_not_at_pivot")
    elif rule == "door_frame_base_center":
        if abs(center.x) > pivot_tolerance or abs(center.y) > pivot_tolerance:
            errors.append("door_frame_pivot_not_at_horizontal_center")
    elif rule == "door_hinge_base":
        horizontal_edge_distance = min(
            abs(minimum.x), abs(maximum.x), abs(minimum.y), abs(maximum.y)
        )
        if abs(minimum.z) > 0.10 or horizontal_edge_distance > 0.15:
            errors.append("door_hinge_pivot_not_near_bottom_edge")
    elif rule == "stair_lower_start_floor":
        is_stair_body = record.get("source_relative_path", "").lower().startswith(
            "stairs/stairs"
        )
        if abs(center.x) > pivot_tolerance or abs(minimum.z) > pivot_tolerance:
            errors.append("stair_pivot_not_at_width_center_or_floor")
        if is_stair_body and abs(minimum.y) > pivot_tolerance:
            errors.append("stair_body_pivot_not_at_lower_start_edge")
        if not is_stair_body and abs(center.y) > pivot_tolerance:
            errors.append("stair_attachment_pivot_not_at_bottom_center")
    elif rule == "scatter_bottom_center":
        support_pivot, _, _ = scatter_support_pivot(positions, minimum, maximum)
        if abs(minimum.z) > pivot_tolerance:
            errors.append("scatter_bottom_not_at_pivot")
        if abs(support_pivot.x) > pivot_tolerance or abs(support_pivot.y) > pivot_tolerance:
            errors.append("scatter_support_area_center_not_at_pivot")
    elif rule == "light_emission_center":
        if center.length > pivot_tolerance:
            errors.append("light_emission_proxy_not_at_bbox_center")
    if record.get("target_marker") == "Door" and record.get("subtype") in {
        "DoorLeaf",
        "DoorFrame",
        "Jail",
    }:
        dimensions = maximum - minimum
        if dimensions.x > dimensions.y + pivot_tolerance:
            errors.append("door_normal_axis_is_wider_than_door_width_axis")
    return errors, {
        "roundtrip_bbox_blender_m": round_vector(maximum - minimum),
        "roundtrip_bbox_min_blender_m": round_vector(minimum),
        "roundtrip_bbox_max_blender_m": round_vector(maximum),
        "roundtrip_origin_m": round_vector(obj.matrix_world.translation),
        "roundtrip_object_scale": round_vector(obj.scale),
        "roundtrip_object_count": len(objects),
    }


def process_asset(record, output_root):
    reset_scene()
    source_fbx = record.get("intermediate_fbx")
    if not source_fbx or not os.path.isfile(source_fbx):
        raise RuntimeError("intermediate FBX is missing: {}".format(source_fbx))

    bpy.ops.import_scene.fbx(
        filepath=source_fbx,
        global_scale=1.0,
        use_custom_props=True,
        use_anim=False,
    )
    obj = prepare_single_mesh(record["asset_id"])
    axis_rotation = apply_axis_normalization(record, obj)
    normalization_scale = apply_uniform_normalization(
        obj, record.get("normalization_uniform_scale", 1.0)
    )
    positions = vertex_positions(obj)
    minimum, maximum = bounds_from_positions(positions)
    pivot, pivot_details = choose_pivot(record, obj, positions, minimum, maximum)
    move_pivot_to_origin(obj, pivot)
    add_asset_metadata(
        obj, record, pivot, pivot_details, normalization_scale, axis_rotation
    )

    normalized_positions = vertex_positions(obj)
    normalized_minimum, normalized_maximum = bounds_from_positions(normalized_positions)
    dimensions_blender = normalized_maximum - normalized_minimum
    dimensions_target = Vector(
        (dimensions_blender.x, dimensions_blender.z, dimensions_blender.y)
    )

    model_directory, blender_directory = ensure_output_directories(
        output_root, record["target_marker"]
    )
    filename = safe_name(record["asset_id"])
    fbx_path = os.path.join(model_directory, filename + ".fbx")
    blend_path = os.path.join(blender_directory, filename + ".blend")
    export_asset(obj, fbx_path, blend_path)

    errors, roundtrip = validate_roundtrip(fbx_path, dimensions_blender, record)
    manual_review = []
    if pivot_details.get("manual_review"):
        manual_review.append(pivot_details["manual_review"])
    if record.get("target_marker") == "Stair" and record.get("usage_hint") == "attach":
        manual_review.append("在完整楼梯校准场景中确认附属件安装点和上行方向")
    if record.get("target_marker") == "Wall" and record.get("usage_hint") == "attach":
        manual_review.append("确认墙面附属件的局部 +X 为安装面外法线并核对正面")

    result = dict(record)
    result.update(
        {
            "screened_normalized_bbox_ue_m": record.get("normalized_bbox_m"),
            "normalized_bbox_m": round_vector(dimensions_target),
            "normalized_bbox_blender_m": round_vector(dimensions_blender),
            "pivot_position_m": [0.0, 0.0, 0.0],
            "pivot_source_blender_m": round_vector(pivot),
            "pivot_note": PIVOT_NOTES[record["pivot_rule"]],
            "pivot_method": pivot_details["method"],
            "pivot_details": pivot_details,
            "z_axis_direction": TARGET_Z_AXIS_DIRECTIONS.get(
                record["target_marker"], "asset_defined"
            ),
            "uniform_scale": True,
            "baked_object_scale": [1.0, 1.0, 1.0],
            "blender_work_up_axis": "+Z",
            "target_up_axis": "+Y",
            "target_axis_mapping": "Blender X->target X, Blender Z->target Y, Blender Y->target Z",
            "axis_normalization_rotation_blender_deg": axis_rotation,
            "fbx_axis_forward": FBX_AXIS_FORWARD,
            "fbx_axis_up": FBX_AXIS_UP,
            "blender_file": blend_path,
            "export_path": fbx_path,
            "export_format": "FBX 7.4 binary",
            "validation_status": "passed" if not errors else "failed",
            "validation_errors": errors,
            "manual_review_required": bool(manual_review),
            "manual_review_notes": manual_review,
            "roundtrip": roundtrip,
        }
    )
    return result


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)


def write_csv(path, records):
    fields = [
        "asset_id",
        "source_asset",
        "target_marker",
        "subtype",
        "usage_hint",
        "normalized_bbox_m",
        "pivot_rule",
        "pivot_note",
        "pivot_position_m",
        "x_axis_direction",
        "y_axis_direction",
        "z_axis_direction",
        "uniform_scale",
        "normalization_uniform_scale",
        "validation_status",
        "manual_review_required",
        "blender_file",
        "export_path",
    ]
    with open(path, "w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for record in records:
            row = {}
            for field in fields:
                value = record.get(field)
                row[field] = json.dumps(value, ensure_ascii=False) if isinstance(value, list) else value
            writer.writerow(row)


def main():
    args = parse_arguments()
    with open(args.inventory, "r", encoding="utf-8") as stream:
        inventory = json.load(stream)

    selected_ids = set(args.asset_id)
    candidates = [
        record
        for record in inventory.get("assets", [])
        if record.get("screening_status") == "approved"
        and (not selected_ids or record.get("asset_id") in selected_ids)
    ]
    if args.limit > 0:
        candidates = candidates[: args.limit]

    results = []
    failures = []
    for index, record in enumerate(candidates, 1):
        asset_id = record.get("asset_id", "unknown")
        print(
            "PCG_ASSET_PROCESS {}/{} {}".format(index, len(candidates), asset_id),
            flush=True,
        )
        try:
            results.append(process_asset(record, args.output_root))
        except Exception as error:
            failure = {
                "asset_id": asset_id,
                "source_asset": record.get("source_asset"),
                "target_marker": record.get("target_marker"),
                "error": str(error),
                "traceback": traceback.format_exc(),
            }
            failures.append(failure)
            print("PCG_ASSET_FAILURE {} {}".format(asset_id, error), flush=True)

    now = datetime.now(timezone.utc).isoformat()
    marker_counts = dict(sorted(Counter(record["target_marker"] for record in results).items()))
    summary = {
        "generated_at_utc": now,
        "source_inventory": args.inventory,
        "output_root": args.output_root,
        "blender_version": bpy.app.version_string,
        "blender_work_up_axis": "+Z",
        "target_up_axis": "+Y",
        "target_axis_mapping": "Blender X->target X, Blender Z->target Y, Blender Y->target Z",
        "fbx_axis_forward": FBX_AXIS_FORWARD,
        "fbx_axis_up": FBX_AXIS_UP,
        "candidate_count": len(candidates),
        "exported_count": len(results),
        "passed_count": sum(record["validation_status"] == "passed" for record in results),
        "failed_validation_count": sum(
            record["validation_status"] != "passed" for record in results
        ),
        "manual_review_count": sum(record["manual_review_required"] for record in results),
        "pipeline_failure_count": len(failures),
        "marker_counts": marker_counts,
    }
    catalog = {"summary": summary, "assets": results}
    report = {
        "summary": summary,
        "failed_assets": failures,
        "validation_failures": [
            {
                "asset_id": record["asset_id"],
                "errors": record["validation_errors"],
            }
            for record in results
            if record["validation_status"] != "passed"
        ],
        "manual_review_assets": [
            {
                "asset_id": record["asset_id"],
                "target_marker": record["target_marker"],
                "notes": record["manual_review_notes"],
            }
            for record in results
            if record["manual_review_required"]
        ],
    }

    catalog_directory = os.path.join(args.output_root, "catalog")
    write_json(os.path.join(catalog_directory, "asset_catalog.json"), catalog)
    write_json(os.path.join(catalog_directory, "blender_validation_report.json"), report)
    write_csv(os.path.join(catalog_directory, "asset_catalog.csv"), results)
    print("PCG_ASSET_PIPELINE_SUMMARY {}".format(json.dumps(summary)), flush=True)

    if failures or summary["failed_validation_count"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
