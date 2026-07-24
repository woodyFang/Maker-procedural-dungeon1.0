local PCGDungeonMeshInfoAdapter = {}
local PCGDungeonCoordinateSystem = require("Generation.PCGDungeonCoordinateSystem")

local function RoomId(marker)
    local attributes = marker.attributes or {}
    return tonumber(attributes.source_room_id) or -1
end

local function SourceMesh(rule)
    if rule.usage == "inherit" then return rule.mesh end
    if rule.usage == "prefab" then return rule.source_mesh end
    if rule.usage == "point_light_marker" then return rule.mesh end
    return nil
end

local function MarkersForRule(rule, markersByName)
    local source = markersByName[rule.marker] or {}
    if not rule.marker_group then return source end
    local result = {}
    for _, marker in ipairs(source) do
        if marker.groups and marker.groups[rule.marker_group] then
            result[#result + 1] = marker
        end
    end
    return result
end

local function MarkerCopy(marker, copyRule)
    local offset = copyRule and copyRule.local_offset_m or nil
    if type(offset) ~= "table" then return marker end
    local rotated = PCGDungeonCoordinateSystem.RotateMarkerVector(
        marker.orient or { 0, 0, 0, 1 }, offset)
    local position = marker.position or { 0, 0, 0 }
    return {
        position = {
            (position[1] or 0) + rotated[1],
            (position[2] or 0) + rotated[2],
            (position[3] or 0) + rotated[3],
        },
        orient = marker.orient,
        scale = marker.scale,
        pscale = marker.pscale,
        attributes = marker.attributes,
    }
end

local function BuildInstanceGroups(rules, markersByName)
    local groups, scheduled, instanceCount = {}, {}, 0
    for _, rule in ipairs(rules or {}) do
        local mesh = SourceMesh(rule)
        local markers = MarkersForRule(rule, markersByName)
        local key = tostring(rule.id or (tostring(mesh) .. "|" .. tostring(rule.marker)))
        if mesh and markers and #markers > 0 and not scheduled[key] then
            local group = {
                rule_id = rule.id,
                marker = rule.marker,
                marker_group = rule.marker_group,
                mesh = mesh,
                transforms = {},
                room_ids = {},
                floor_ids = {},
            }
            local copies = type(rule.marker_copies) == "table" and rule.marker_copies or { false }
            for _, marker in ipairs(markers) do
                for _, copyRule in ipairs(copies) do
                    local copiedMarker = MarkerCopy(marker, copyRule)
                    group.transforms[#group.transforms + 1] = PCGDungeonCoordinateSystem.PackMarkerTransform(
                        copiedMarker, rule.marker_yaw_offset_deg)
                    group.room_ids[#group.room_ids + 1] = RoomId(marker)
                    local floorId = tonumber(marker.attributes and marker.attributes.floor_id)
                    group.floor_ids[#group.floor_ids + 1] = floorId ~= nil and floorId or false
                end
            end
            groups[#groups + 1] = group
            scheduled[key] = true
            instanceCount = instanceCount + #group.transforms
        end
    end
    return groups, instanceCount
end

local function AppendPosition(vertices, position)
    vertices[#vertices + 1] = position[1] * 100
    vertices[#vertices + 1] = position[3] * 100
    vertices[#vertices + 1] = position[2] * 100
end

local function BuildGroundSurface(groundMarkers)
    local vertices, indices, triangleFloorIds = {}, {}, {}
    for _, marker in ipairs(groundMarkers or {}) do
        local position = marker.position
        local size = marker.attributes and marker.attributes.marker_size or { 5, 5, 5 }
        local floorId = marker.attributes and tonumber(marker.attributes.floor_id) or nil
        local halfX, halfZ = (size[1] or 5) * 0.5, (size[3] or size[1] or 5) * 0.5
        local base = #vertices // 3
        AppendPosition(vertices, { position[1] - halfX, position[2], position[3] - halfZ })
        AppendPosition(vertices, { position[1] + halfX, position[2], position[3] - halfZ })
        AppendPosition(vertices, { position[1] + halfX, position[2], position[3] + halfZ })
        AppendPosition(vertices, { position[1] - halfX, position[2], position[3] + halfZ })
        indices[#indices + 1] = base
        indices[#indices + 1] = base + 1
        indices[#indices + 1] = base + 2
        indices[#indices + 1] = base
        indices[#indices + 1] = base + 2
        indices[#indices + 1] = base + 3
        triangleFloorIds[#triangleFloorIds + 1] = floorId
        triangleFloorIds[#triangleFloorIds + 1] = floorId
    end
    return {
        name = "GroundScatterSurface", vertices_cm = vertices, indices = indices,
        triangle_floor_ids = triangleFloorIds,
    }
end

function PCGDungeonMeshInfoAdapter.Apply(meshInfo, markerResult, options)
    if type(meshInfo) ~= "table" or type(meshInfo.meshes) ~= "table" then
        return nil, "mesh_info rules are missing"
    end
    if type(markerResult) ~= "table" or type(markerResult.markers) ~= "table" then
        return nil, "PCG Dungeon Marker result is missing"
    end

    local markersByName = {}
    for _, marker in ipairs(markerResult.markers) do
        markersByName[marker.name] = markersByName[marker.name] or {}
        markersByName[marker.name][#markersByName[marker.name] + 1] = marker
    end
    local groups, instanceCount = BuildInstanceGroups(meshInfo.meshes, markersByName)
    options = options or {}
    local decorDensitiesByFloor = options.decorDensitiesByFloor
    meshInfo.scene = {
        schema_version = 1,
        instance_group_count = #groups,
        instance_count = instanceCount,
        instances = groups,
        surfaces = { BuildGroundSurface(markersByName.Ground) },
        scatter_density_by_floor = decorDensitiesByFloor,
    }
    return meshInfo, {
        markerCount = #markerResult.markers,
        faceCount = #(markerResult.faces or {}),
        markerTypeCount = 0,
        instanceGroupCount = #groups,
        sourceInstanceCount = instanceCount,
    }
end

return PCGDungeonMeshInfoAdapter
