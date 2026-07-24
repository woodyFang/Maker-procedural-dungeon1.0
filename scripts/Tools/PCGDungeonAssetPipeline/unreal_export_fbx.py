import json
import os
import re

import unreal


SOURCE_CONTENT_ROOT = "/Game/FantasyDungeon/meshes"
OUTPUT_ROOT = os.environ.get(
    "PCG_ASSET_OUTPUT_ROOT",
    r"D:\SUMIT\ProjectCity\Exports\FantasyDungeonByMarker",
)
MODE = os.environ.get("PCG_ASSET_MODE", "inventory").lower()


def marker_metadata(relative_path, name):
    folder = relative_path.split("/")[0]
    lower_name = name.lower()

    if folder in {"Bones", "BrickDamage"}:
        return "GroundScatterSurface", folder, "scatter", "scatter_bottom_center", \
            "random_yaw_reference", "up"
    if folder == "Floor":
        return "Ground", folder, "inherit", "cell_center_floor", "grid_right", "up"
    if folder == "Wall":
        if "arch" in lower_name:
            return "Door", "WallArch", "inherit", "door_frame_base_center", \
                "door_normal", "up"
        usage = "inherit" if re.match(r"^wall(?:damaged)?\d+$", lower_name) else "attach"
        return "Wall", folder, usage, "wall_segment_center_floor", "wall_outward", "up"
    if folder == "Door":
        if "arch" in lower_name or "curb" in lower_name:
            pivot = "door_frame_base_center"
            subtype = "DoorFrame"
        else:
            pivot = "door_hinge_base"
            subtype = "DoorLeaf"
        return "Door", subtype, "attach", pivot, "door_normal", "up"
    if folder == "Arch":
        return "Door", folder, "inherit", "door_frame_base_center", "door_normal", "up"
    if folder == "Column":
        return "WallSeparator", folder, "inherit", "wall_endpoint_base", \
            "canonical_or_rule", "up"
    if folder == "Stairs":
        usage = "inherit" if lower_name.startswith("stairs") else "attach"
        return "Stair", folder, usage, "stair_lower_start_floor", "stair_width", "up"
    if folder == "Roof":
        return "Ceil", folder, "inherit", "ceil_underside_center", "grid_right", "up"
    if folder == "curbstone":
        return "Curbstone01Placement", folder, "inherit", \
            "curbstone_segment_center_floor", "wall_outward", "up"
    if folder == "SpiderWeb":
        return "PillarWebPlacement", folder, "inherit", "corner_mount", \
            "corner_inward", "up"
    if folder == "Chandelier":
        if lower_name.startswith("roaster"):
            return "PillarPlacement", "Brazier", "attach", "pillar_base_floor", \
                "room_inward", "up"
        return "Light", folder, "attach", "light_emission_center", "fixture_front", "up"
    if folder in {"Chain", "Mechanism", "Tapestry"}:
        return "Wall", folder, "attach", "wall_segment_center_floor", "wall_outward", "up"
    if folder == "Jail":
        marker = "Door" if "door" in lower_name else "Wall"
        pivot = "door_hinge_base" if "door" in lower_name else "wall_segment_center_floor"
        return marker, folder, "attach", pivot, \
            "door_normal" if marker == "Door" else "wall_outward", "up"
    if folder == "Sewerage":
        marker = "Ground" if any(token in lower_name for token in ("water", "grid", "sewerage")) \
            else "Wall"
        pivot = "cell_center_floor" if marker == "Ground" else "wall_segment_center_floor"
        return marker, folder, "attach", pivot, \
            "grid_right" if marker == "Ground" else "wall_outward", "up"
    return "Unclassified", folder, "review", "manual", "manual", "up"


def axis_normalization_rotation(marker, subtype):
    # Assets authored under Door/ (and JailDoor) use X as width and Y as
    # thickness. Rotate them so final local +X is the door normal and the
    # source width maps to target local Z. Arch/ and WallArch assets already
    # use X as their normal and require no correction.
    if marker == "Door" and subtype in {"DoorLeaf", "DoorFrame", "Jail"}:
        return [0.0, 0.0, -90.0]
    return [0.0, 0.0, 0.0]


def screen_candidate(marker, subtype, usage, size_m):
    x, y, z = size_m
    horizontal_max = max(x, y)
    horizontal_min = min(x, y)
    reasons = []
    uniform_scale = 1.0

    if sum(1 for value in size_m if value > 0.0001) < 2:
        reasons.append("degenerate_bounds")
    if marker == "Ground":
        if horizontal_max > 5.25 or z > 1.0:
            reasons.append("outside_ground_cell_envelope")
    elif marker == "Wall":
        if horizontal_max > 5.25 or horizontal_min > 1.25 or z > 5.25:
            reasons.append("outside_wall_segment_envelope")
    elif marker == "Door":
        if horizontal_max > 5.25 or z > 5.25:
            reasons.append("outside_door_cell_envelope")
    elif marker == "WallSeparator":
        if horizontal_max > 1.8 or z > 5.25:
            reasons.append("outside_separator_envelope")
        elif horizontal_max > 1.5:
            uniform_scale = min(uniform_scale, 1.5 / horizontal_max)
    elif marker == "Stair":
        height_limit = 3.5 if usage == "inherit" else 5.25
        if horizontal_max > 5.25 or z > height_limit:
            reasons.append("outside_single_stair_copy_envelope")
    elif marker == "Ceil":
        if horizontal_max > 5.25 or z > 5.25:
            reasons.append("outside_ceil_cell_envelope")
    elif marker == "PillarPlacement":
        if horizontal_max > 1.5 or z > 3.5:
            reasons.append("outside_pillar_placement_envelope")
    elif marker == "PillarWebPlacement":
        if max(size_m) > 1.2:
            uniform_scale = min(uniform_scale, 1.2 / max(size_m))
    elif marker == "Curbstone01Placement":
        if horizontal_max > 5.25 or horizontal_min > 0.8 or z > 0.9:
            reasons.append("outside_curbstone_envelope")
    elif marker == "GroundScatterSurface":
        if horizontal_max > 1.2:
            uniform_scale = min(uniform_scale, 1.2 / horizontal_max)
        if z > 0.9:
            uniform_scale = min(uniform_scale, 0.9 / z)
    elif marker == "Light":
        if horizontal_max > 3.0 or z > 5.0:
            reasons.append("outside_visible_light_fixture_envelope")
    elif marker == "Unclassified":
        reasons.append("unclassified")

    status = "approved" if not reasons else "rejected"
    return status, reasons, round(uniform_scale, 8)


def vector_values(vector):
    return [round(float(vector.x), 6), round(float(vector.y), 6), round(float(vector.z), 6)]


def export_static_mesh(mesh, filename):
    os.makedirs(os.path.dirname(filename), exist_ok=True)
    task = unreal.AssetExportTask()
    task.set_editor_property("object", mesh)
    task.set_editor_property("filename", filename)
    task.set_editor_property("automated", True)
    task.set_editor_property("prompt", False)
    task.set_editor_property("replace_identical", True)

    options = unreal.FbxExportOption()
    options.set_editor_property("ascii", False)
    options.set_editor_property("collision", False)
    options.set_editor_property("level_of_detail", False)
    options.set_editor_property("vertex_color", True)
    task.set_editor_property("options", options)
    return bool(unreal.Exporter.run_asset_export_task(task))


def main():
    catalog_dir = os.path.join(OUTPUT_ROOT, "catalog")
    intermediate_dir = os.path.join(OUTPUT_ROOT, "intermediate_fbx")
    os.makedirs(catalog_dir, exist_ok=True)

    registry = unreal.AssetRegistryHelpers.get_asset_registry()
    assets = registry.get_assets_by_path(SOURCE_CONTENT_ROOT, recursive=True)
    records = []
    exported = 0

    for asset_data in sorted(assets, key=lambda item: str(item.package_name).lower()):
        class_name = str(asset_data.asset_class_path.asset_name)
        if class_name != "StaticMesh":
            continue

        mesh = asset_data.get_asset()
        if mesh is None:
            unreal.log_warning("Failed to load {}".format(asset_data.package_name))
            continue

        package_name = str(asset_data.package_name)
        relative_path = package_name.replace(SOURCE_CONTENT_ROOT + "/", "", 1)
        name = str(asset_data.asset_name)
        marker, subtype, usage, pivot_rule, x_axis, y_axis = marker_metadata(relative_path, name)
        axis_rotation = axis_normalization_rotation(marker, subtype)

        bounds = mesh.get_bounds()
        extent_cm = vector_values(bounds.box_extent)
        origin_cm = vector_values(bounds.origin)
        size_m = [round(value * 0.02, 6) for value in extent_cm]
        status, reasons, uniform_scale = screen_candidate(marker, subtype, usage, size_m)
        normalized_bbox_m = [round(value * uniform_scale, 6) for value in size_m]

        export_relative = os.path.splitext(relative_path)[0] + ".fbx"
        export_path = os.path.join(intermediate_dir, export_relative.replace("/", os.sep))
        exported_ok = False
        if MODE == "export" and status == "approved":
            exported_ok = export_static_mesh(mesh, export_path)
            if exported_ok:
                exported += 1
            else:
                status = "rejected"
                reasons.append("unreal_fbx_export_failed")

        materials = []
        try:
            for static_material in mesh.get_editor_property("static_materials"):
                material = static_material.get_editor_property("material_interface")
                materials.append(material.get_path_name() if material else None)
        except Exception as error:
            materials.append("material_scan_error:{}".format(error))

        record = {
            "asset_id": "{}__{}".format(marker, name),
            "source_asset": package_name,
            "source_relative_path": relative_path,
            "source_class": class_name,
            "target_marker": marker,
            "subtype": subtype,
            "usage_hint": usage,
            "source_bbox_m": size_m,
            "normalized_bbox_m": normalized_bbox_m,
            "source_bounds_origin_cm": origin_cm,
            "pivot_rule": pivot_rule,
            "pivot_note": "Set by Blender marker normalization",
            "axis_rule": "{}_x__{}_y".format(x_axis, y_axis),
            "axis_normalization_rotation_blender_deg": axis_rotation,
            "x_axis_direction": x_axis,
            "y_axis_direction": y_axis,
            "uniform_scale": True,
            "normalization_uniform_scale": uniform_scale,
            "screening_status": status,
            "screening_reasons": reasons,
            "material_assets": materials,
            "intermediate_fbx": export_path if MODE == "export" and exported_ok else None,
        }
        records.append(record)

    summary = {
        "source_content_root": SOURCE_CONTENT_ROOT,
        "output_root": OUTPUT_ROOT,
        "mode": MODE,
        "static_mesh_count": len(records),
        "approved_count": sum(1 for item in records if item["screening_status"] == "approved"),
        "rejected_count": sum(1 for item in records if item["screening_status"] == "rejected"),
        "exported_count": exported,
    }
    inventory = {"summary": summary, "assets": records}
    output_file = os.path.join(catalog_dir, "unreal_inventory.json")
    with open(output_file, "w", encoding="utf-8") as stream:
        json.dump(inventory, stream, ensure_ascii=False, indent=2)

    unreal.log("PCG_ASSET_PIPELINE_SUMMARY {}".format(json.dumps(summary)))


main()
