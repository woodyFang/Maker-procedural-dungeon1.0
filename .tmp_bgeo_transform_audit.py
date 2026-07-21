import collections
import hou

path = r"D:\SUMI\Maker-procedural-dungeon1.0\wuzhong\assets\BgeoDungeon\DungeonInstances.bgeo.sc"
geometry = hou.Geometry()
geometry.loadFromFile(path)
print("point attributes", [attribute.name() for attribute in geometry.pointAttribs()])
for point in geometry.points()[:8]:
    print("point", point.number(), tuple(round(float(value), 6) for value in point.position()))
    for name in ("name", "mesh", "marker_name", "N", "orient", "up", "scale"):
        attribute = geometry.findPointAttrib(name)
        if attribute is not None:
            value = point.attribValue(attribute)
            print(" ", name, value)

print("--- instance orientation groups ---")
groups = collections.defaultdict(collections.Counter)
for point in geometry.points():
    marker_name = point.attribValue("marker_name")
    asset_path = point.attribValue("unreal_instance")
    if marker_name not in ("Wall", "Door", "Stair", "WallSeparator", "PillarPlacement",
                            "PillarWebPlacement", "Curbstone01Placement"):
        continue
    normal = tuple(round(float(value), 6) for value in point.attribValue("N"))
    orient = tuple(round(float(value), 6) for value in point.attribValue("orient"))
    groups[(marker_name, asset_path)][(normal, orient)] += 1
for group_key in sorted(groups):
    print("---", group_key, sum(groups[group_key].values()))
    for pair, count in sorted(groups[group_key].items(), key=lambda item: str(item[0])):
        print(count, pair)

raw = hou.Geometry()
raw.loadFromFile(r"D:\SUMI\Maker-procedural-dungeon1.0\wuzhong\assets\BgeoDungeon\HoudiniMarkerPoints.bgeo.sc")
raw_by_key = collections.defaultdict(list)
for point in raw.points():
    key = (point.attribValue("marker_name"), tuple(round(float(value), 6) for value in point.position()))
    raw_by_key[key].append(point)
print("--- raw to instance ---")
seen = set()
for point in geometry.points():
    marker_name = point.attribValue("marker_name")
    asset_path = point.attribValue("unreal_instance")
    if marker_name not in ("Door", "Stair"):
        continue
    position = tuple(round(float(value), 6) for value in point.position())
    key = (marker_name, asset_path, position, tuple(round(float(value), 6) for value in point.attribValue("N")))
    if key in seen:
        continue
    seen.add(key)
    candidates = raw_by_key[(marker_name, position)]
    if not candidates:
        continue
    raw_point = min(candidates, key=lambda candidate: sum(
        (float(a) - float(b)) ** 2 for a, b in zip(candidate.attribValue("N"), point.attribValue("N"))))
    print(marker_name, asset_path, "N", point.attribValue("N"),
          "raw", raw_point.attribValue("orient"), "final", point.attribValue("orient"))

print("--- stair instance pairs ---")
raw_stairs = collections.defaultdict(list)
for point in raw.points():
    if point.attribValue("marker_name") == "Stair":
        raw_stairs[int(point.attribValue("source_stair_instance_id"))].append(point)
final_stairs = collections.defaultdict(list)
for point in geometry.points():
    if point.attribValue("marker_name") == "Stair" and "Stairs01.Stairs01" in point.attribValue("unreal_instance"):
        final_stairs[int(point.attribValue("source_stair_instance_id"))].append(point)
for stair_id in sorted(raw_stairs)[:6]:
    print("stair", stair_id)
    for label, points in (("raw", raw_stairs[stair_id]), ("final", final_stairs[stair_id])):
        for point in points:
            print(" ", label, "P", tuple(round(float(v), 6) for v in point.position()),
                  "N", tuple(round(float(v), 6) for v in point.attribValue("N")),
                  "q", tuple(round(float(v), 6) for v in point.attribValue("orient")),
                  "length", point.attribValue("source_stair_length_index"),
                  "height", point.attribValue("source_stair_height_index"))
