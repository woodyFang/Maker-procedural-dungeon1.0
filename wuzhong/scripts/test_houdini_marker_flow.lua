local DungeonGenerator = require("Generation.DungeonGenerator")
local HoudiniMarkerPipeline = require("Generation.HoudiniMarkerPipeline")
local HoudiniMeshInfoAdapter = require("Generation.HoudiniMeshInfoAdapter")

local function Check(condition, message)
    if not condition then error(message, 2) end
end

local function DirectionKey(normal)
    return string.format("%d,%d", math.floor((normal[1] or 0) * 1000 + 0.5),
        math.floor((normal[3] or 0) * 1000 + 0.5))
end

local function CheckQuaternion(actual, expected, message)
    local dot = 0
    for index = 1, 4 do dot = dot + (actual[index] or 0) * (expected[index] or 0) end
    Check(math.abs(math.abs(dot) - 1) < 0.00001, message)
end

local HALF = math.sqrt(0.5)
local LOCAL_X_REFERENCE = {
    ["1000,0"] = { 0, 0, 0, 1 }, ["-1000,0"] = { 0, 1, 0, 0 },
    ["0,1000"] = { 0, -HALF, 0, HALF }, ["0,-1000"] = { 0, HALF, 0, HALF },
}
local LOCAL_FORWARD_REFERENCE = {
    ["1000,0"] = { 0, HALF, 0, HALF }, ["-1000,0"] = { 0, -HALF, 0, HALF },
    ["0,1000"] = { 0, 0, 0, 1 }, ["0,-1000"] = { 0, 1, 0, 0 },
}
local PILLAR_REFERENCE = {
    ["1000,0"] = { 0, 0, 0, 1 }, ["-1000,0"] = { 0, -0.027412, 0, 0.999624 },
    ["0,1000"] = { 0, -0.013707, 0, 0.999906 }, ["0,-1000"] = { 0, 0.013707, 0, 0.999906 },
    ["707,707"] = { 0, -0.006854, 0, 0.999977 }, ["707,-707"] = { 0, 0.006854, 0, 0.999977 },
    ["-707,707"] = { 0, -0.020560, 0, 0.999789 }, ["-707,-707"] = { 0, 0.020560, 0, 0.999789 },
}
local WEB_REFERENCE = {
    ["707,707"] = { 0, -0.382683, 0, 0.923880 }, ["707,-707"] = { 0, 0.382683, 0, 0.923880 },
    ["-707,707"] = { 0, -0.923880, 0, 0.382683 }, ["-707,-707"] = { 0, 0.923880, 0, 0.382683 },
}

local function CheckReferenceOrientation(marker)
    local reference = nil
    if marker.name == "Wall" or marker.name == "Door" or marker.name == "Light_Door"
        or marker.name == "Curbstone01Placement" then
        reference = LOCAL_X_REFERENCE
    elseif marker.name == "Stair" or marker.name == "Light_Stair" then
        reference = LOCAL_FORWARD_REFERENCE
    elseif marker.name == "PillarPlacement" then
        reference = PILLAR_REFERENCE
    elseif marker.name == "PillarWebPlacement" then
        reference = WEB_REFERENCE
    else
        CheckQuaternion(marker.orient, { 0, 0, 0, 1 }, marker.name .. " reference orientation is not identity")
        return
    end
    local key = DirectionKey(marker.normal)
    Check(reference[key] ~= nil, marker.name .. " has an unexpected reference direction " .. key)
    CheckQuaternion(marker.orient, reference[key], marker.name .. " orientation differs from Houdini BGEO for " .. key)
    if marker.name == "Light_Door" or marker.name == "Light_Stair"
        or marker.name == "PillarPlacement" or marker.name == "PillarWebPlacement" then
        Check(math.abs(marker.angle or 0) < 0.00001, marker.name .. " marker_angle should remain zero")
    end
end

local function CanonicalTransformKey(transform)
    local quaternion = { transform[4], transform[5], transform[6], transform[7] }
    local sign = 1
    if quaternion[4] < -0.000001 then sign = -1
    elseif math.abs(quaternion[4]) <= 0.000001 then
        for index = 1, 3 do
            if math.abs(quaternion[index]) > 0.000001 then
                if quaternion[index] < 0 then sign = -1 end
                break
            end
        end
    end
    local values = {}
    for index = 1, 10 do
        local value = transform[index] or 0
        if index >= 4 and index <= 7 then value = value * sign end
        local scaled = value * 10000
        values[index] = tostring(scaled >= 0 and math.floor(scaled + 0.5) or math.ceil(scaled - 0.5))
    end
    return table.concat(values, "|")
end

local function TransformKeysForMesh(scene, mesh)
    local result = {}
    for _, group in ipairs(scene.instances or {}) do
        if group.mesh == mesh then
            for _, transform in ipairs(group.transforms or {}) do
                result[#result + 1] = CanonicalTransformKey(transform)
            end
        end
    end
    table.sort(result)
    return result
end

local function CheckAssetTransformParity(fixedScene, dynamicScene, mesh)
    local fixed = TransformKeysForMesh(fixedScene, mesh)
    local dynamic = TransformKeysForMesh(dynamicScene, mesh)
    Check(#fixed == #dynamic, string.format("%s instance count differs: fixed=%d dynamic=%d",
        mesh, #fixed, #dynamic))
    for index = 1, #fixed do
        Check(fixed[index] == dynamic[index], string.format(
            "%s transform %d differs from fixed BGEO: fixed=%s dynamic=%s",
            mesh, index, fixed[index], dynamic[index]))
    end
end

function Start()
    local ok, errorMessage = xpcall(function()
        local referenceValid, report = HoudiniMarkerPipeline.RunReferenceValidation()
        Check(referenceValid, table.concat(report.errors or { "reference validation failed" }, "\n"))
        Check(report.markerCount == 2443, "reference marker count changed")
        Check(report.faceCount == 838, "reference face count changed")
        Check(report.markerTypeCount == 14, "reference marker type count changed")
        for _, marker in ipairs(report.result.markers) do CheckReferenceOrientation(marker) end

        local meshFile = cache:GetFile("BgeoDungeon/DungeonInstances.mesh_info.json")
            or cache:GetFile("assets/BgeoDungeon/DungeonInstances.mesh_info.json")
        Check(meshFile ~= nil, "mesh_info could not be opened for fixed BGEO parity")
        local meshInfo = cjson.decode(meshFile:ReadString()); meshFile:Close()
        local fixedScene = meshInfo.scene
        local adapted = HoudiniMeshInfoAdapter.Apply(meshInfo, report.result)
        for _, marker in ipairs(report.result.markers) do
            if marker.name == "Wall" and math.abs(marker.position[1] - 25) < 0.001
                and math.abs(marker.position[2] - 5) < 0.001 and math.abs(marker.position[3] - 12.5) < 0.001 then
                print(string.format("[OrientationProbe] N=%g,%g,%g stair=%s role=%s length=%s height=%s",
                    marker.normal[1], marker.normal[2], marker.normal[3],
                    tostring(marker.attributes.source_stair_instance_id), tostring(marker.attributes.source_stair_role),
                    tostring(marker.attributes.source_stair_length_index), tostring(marker.attributes.source_stair_height_index)))
            end
        end
        Check(adapted.scene.instance_count == fixedScene.instance_count,
            string.format("dynamic instance count differs: fixed=%d dynamic=%d",
                fixedScene.instance_count, adapted.scene.instance_count))
        for _, mesh in ipairs({
            "/Game/FantasyDungeon/meshes/Floor/Floor01.Floor01",
            "/Game/FantasyDungeon/meshes/Wall/Wall01.Wall01",
            "/Game/FantasyDungeon/meshes/Wall/wall01Arch1.wall01Arch1",
            "/Game/FantasyDungeon/meshes/Door/DoorArch01.DoorArch01",
            "/Game/FantasyDungeon/meshes/Column/Column03.Column03",
            "/Engine/BasicShapes/Plane.Plane",
            "/Game/FantasyDungeon/meshes/Stairs/Stairs01.Stairs01",
            "/Game/FantasyDungeon/meshes/Roof/Roof11.Roof11",
            "/Game/FantasyDungeon/meshes/curbstone/curbstone01.curbstone01",
        }) do
            CheckAssetTransformParity(fixedScene, adapted.scene, mesh)
        end

        local orientationProbe = HoudiniMarkerPipeline.GenerateFromTopology({
            cells = {
                {
                    id = 0, grid_index = 0, grid_coord = { 0, 0, 0 },
                    position = { 0, 2.5, 0 }, cell_type = 1, room_id = 1,
                    floor_id = 0, stairwell_id = -1, stair_role = -1, connection_id = -1,
                },
            },
            doors = {},
        }, { cellSize = 5 })
        local wallDirections = 0
        for _, marker in ipairs(orientationProbe.markers) do
            if marker.name == "Wall" then
                CheckReferenceOrientation(marker)
                wallDirections = wallDirections + 1
            end
        end
        Check(wallDirections == 4, "wall orientation probe did not emit four boundary walls")

        local dungeon = DungeonGenerator.Generate({
            seed = 20260720, floorCount = 2, roomCount = 18,
            settingKey = "dungeon", theme = "grim", loopRate = 0.08,
            decorDensity = 0.72,
        })
        Check(dungeon.valid, "runtime dungeon fixture is invalid")
        local generated = HoudiniMarkerPipeline.GenerateFromDungeon(dungeon)
        Check(#generated.markers > 0, "runtime dungeon produced no markers")
        Check(#generated.faces > 0, "runtime dungeon produced no boundary faces")
        for _, name in ipairs({ "Ground", "Wall", "Door", "WallSeparator", "Ceil", "Light" }) do
            Check((generated.counts[name] or 0) > 0, "runtime dungeon is missing " .. name)
        end
        local message = string.format(
            "[HoudiniMarkerFlow] PASS reference=%d markers/%d faces runtime=%d markers/%d faces",
            report.markerCount, report.faceCount, #generated.markers, #generated.faces)
        print(message)
    end, debug.traceback)
    if not ok then
        ErrorExit("[HoudiniMarkerFlow] FAIL\n" .. tostring(errorMessage), 1)
        return
    end
    engine:Exit()
end
