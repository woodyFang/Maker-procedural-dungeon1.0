import collections
import hou

path = r"D:\SUMI\Maker-procedural-dungeon1.0\wuzhong\assets\BgeoDungeon\HoudiniMarkerPoints.bgeo.sc"
geometry = hou.Geometry()
geometry.loadFromFile(path)
attribute_names = {attribute.name() for attribute in geometry.pointAttribs()}
print("attrs", sorted(name for name in attribute_names
                       if "direction" in name or name in ("N", "orient", "marker_name", "up", "marker_angle")))

for marker_name in ("Ground", "Wall", "Door", "WallSeparator", "Stair", "Ceil", "Light",
                    "Light_Ambient", "Light_Door", "Light_Stair", "Light_Hero",
                    "PillarPlacement", "PillarWebPlacement", "Curbstone01Placement"):
    pairs = collections.Counter()
    for point in geometry.points():
        if point.attribValue("marker_name") != marker_name:
            continue
        normal = tuple(round(float(value), 6) for value in point.attribValue("N"))
        orient = tuple(round(float(value), 6) for value in point.attribValue("orient"))
        angle = round(float(point.attribValue("marker_angle")), 6)
        extra = ()
        for attribute_name in ("placement_direction", "web_direction", "curbstone_facing_direction"):
            if attribute_name in attribute_names:
                value = point.attribValue(attribute_name)
                if any(abs(float(component)) > 1e-6 for component in value):
                    extra = (attribute_name, tuple(round(float(component), 6) for component in value))
                    break
        pairs[(normal, orient, angle, extra)] += 1
    print("---", marker_name, sum(pairs.values()))
    for key, count in sorted(pairs.items(), key=lambda item: str(item[0])):
        print(count, key)

for point in geometry.points():
    position = tuple(round(float(value), 6) for value in point.position())
    if point.attribValue("marker_name") == "Wall" and position == (25.0, 5.0, 12.5):
        print("probe wall", position, point.attribValue("N"), point.attribValue("orient"),
              point.attribValue("source_cell_type"), point.attribValue("source_room_id"),
              "stair", point.attribValue("source_stair_instance_id"),
              "role", point.attribValue("source_stair_role"),
              "length", point.attribValue("source_stair_length_index"),
              "height", point.attribValue("source_stair_height_index"),
              "end", point.attribValue("source_stair_end_type"))
