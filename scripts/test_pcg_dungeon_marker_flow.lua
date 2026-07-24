local DungeonGenerator = require("Generation.DungeonGenerator")
local PCGDungeonMarkerPipeline = require("Generation.PCGDungeonMarkerPipeline")
local PCGDungeonMeshInfoAdapter = require("Generation.PCGDungeonMeshInfoAdapter")

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
    CheckQuaternion(marker.orient, reference[key], marker.name .. " orientation differs from legacy reference PCG Dungeon for " .. key)
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
        local scaled = value * 1000
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
            "%s transform %d differs from fixed PCG Dungeon: fixed=%s dynamic=%s",
            mesh, index, fixed[index], dynamic[index]))
    end
end

function Start()
    local ok, errorMessage = xpcall(function()
        local referenceValid, report = PCGDungeonMarkerPipeline.RunReferenceValidation()
        Check(referenceValid, table.concat(report.errors or { "reference validation failed" }, "\n"))
        Check(report.markerCount == 2443, "reference marker count changed")
        Check(report.faceCount == 838, "reference face count changed")
        Check(report.markerTypeCount == 14, "reference marker type count changed")
        for _, marker in ipairs(report.result.markers) do CheckReferenceOrientation(marker) end

        local meshFile = cache:GetFile("assets/PCGDungeon/PCGDungeon.mesh_info.json")
            or cache:GetFile("PCGDungeon/PCGDungeon.mesh_info.json")
        Check(meshFile ~= nil, "mesh_info could not be opened for fixed PCG Dungeon parity")
        local meshInfo = cjson.decode(meshFile:ReadString()); meshFile:Close()
        local fixedScene = meshInfo.scene
        local adapted = PCGDungeonMeshInfoAdapter.Apply(meshInfo, report.result)
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
            string.format("dynamic instance count differs: reference=%d dynamic=%d",
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

        local densityAdapted = PCGDungeonMeshInfoAdapter.Apply(meshInfo, report.result, {
            decorDensitiesByFloor = { 0.25, 0.5, 0.75 },
        })
        local densityScene = densityAdapted.scene
        Check(densityScene.scatter_density_by_floor[1] == 0.25
                and densityScene.scatter_density_by_floor[2] == 0.5
                and densityScene.scatter_density_by_floor[3] == 0.75,
            "per-floor scatter density multipliers were not preserved")
        local densitySurface = densityScene.surfaces[1]
        Check(#densitySurface.triangle_floor_ids == #densitySurface.indices / 3,
            "ground scatter surface lost triangle floor metadata")
        local observedFloors = {}
        for _, floorId in ipairs(densitySurface.triangle_floor_ids) do observedFloors[floorId] = true end
        Check(observedFloors[0] and observedFloors[1] and observedFloors[2],
            "ground scatter surface did not retain all dungeon floors")

        local orientationProbe = PCGDungeonMarkerPipeline.GenerateFromTopology({
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

        local stairInteriorProbe = PCGDungeonMarkerPipeline.GenerateFromTopology({
            cells = {
                { id = 0, grid_index = 0, grid_coord = { 0, 0, 0 }, position = { 0, 2.5, 0 },
                    cell_type = 3, room_id = -1, floor_id = 0, stairwell_id = 0, stair_role = 0, connection_id = 0 },
                { id = 1, grid_index = 1, grid_coord = { 1, 0, 0 }, position = { 5, 2.5, 0 },
                    cell_type = 3, room_id = -1, floor_id = 0, stairwell_id = 0, stair_role = 1, connection_id = 0 },
                { id = 2, grid_index = 2, grid_coord = { 0, 1, 0 }, position = { 0, 7.5, 0 },
                    cell_type = 4, room_id = -1, floor_id = 1, stairwell_id = 0, stair_role = 2, connection_id = 0 },
                { id = 3, grid_index = 3, grid_coord = { 1, 1, 0 }, position = { 5, 7.5, 0 },
                    cell_type = 4, room_id = -1, floor_id = 1, stairwell_id = 0, stair_role = 3, connection_id = 0 },
                { id = 4, grid_index = 4, grid_coord = { -1, 0, 0 }, position = { -5, 2.5, 0 },
                    cell_type = 2, room_id = -1, floor_id = 0, stairwell_id = -1, stair_role = -1, connection_id = 0 },
                { id = 5, grid_index = 5, grid_coord = { 2, 1, 0 }, position = { 10, 7.5, 0 },
                    cell_type = 2, room_id = -1, floor_id = 1, stairwell_id = -1, stair_role = -1, connection_id = 0 },
                { id = 6, grid_index = 6, grid_coord = { 0, 0, 1 }, position = { 0, 2.5, 5 },
                    cell_type = 3, room_id = -1, floor_id = 0, stairwell_id = 1, stair_role = 0, connection_id = 1 },
                { id = 7, grid_index = 7, grid_coord = { 1, 0, 1 }, position = { 5, 2.5, 5 },
                    cell_type = 3, room_id = -1, floor_id = 0, stairwell_id = 1, stair_role = 1, connection_id = 1 },
                { id = 8, grid_index = 8, grid_coord = { 0, 1, 1 }, position = { 0, 7.5, 5 },
                    cell_type = 4, room_id = -1, floor_id = 1, stairwell_id = 1, stair_role = 2, connection_id = 1 },
                { id = 9, grid_index = 9, grid_coord = { 1, 1, 1 }, position = { 5, 7.5, 5 },
                    cell_type = 4, room_id = -1, floor_id = 1, stairwell_id = 1, stair_role = 3, connection_id = 1 },
                { id = 10, grid_index = 10, grid_coord = { -1, 0, 1 }, position = { -5, 2.5, 5 },
                    cell_type = 2, room_id = -1, floor_id = 0, stairwell_id = -1, stair_role = -1, connection_id = 1 },
                { id = 11, grid_index = 11, grid_coord = { 2, 1, 1 }, position = { 10, 7.5, 5 },
                    cell_type = 2, room_id = -1, floor_id = 1, stairwell_id = -1, stair_role = -1, connection_id = 1 },
            },
            doors = {},
        }, { cellSize = 5 })
        Check(stairInteriorProbe.stairTopologyValid,
            "adjacent stair marker probe has an invalid stair topology")
        Check(stairInteriorProbe.removedStairInteriorMarkerCount == 4,
            "markers between adjacent stair cells were not removed")
        for _, marker in ipairs(stairInteriorProbe.branches.walls) do
            local betweenStairs = math.abs(marker.position[3] - 2.5) < 0.001
                and (math.abs(marker.position[1]) < 0.001 or math.abs(marker.position[1] - 5) < 0.001)
                and (math.abs(marker.position[2]) < 0.001 or math.abs(marker.position[2] - 5) < 0.001)
            Check(not betweenStairs, "a wall marker remains between two stair cells")
        end

        local oppositeDirectionProbe = PCGDungeonMarkerPipeline.GenerateFromTopology({
            cells = {
                { id = 0, grid_index = 0, grid_coord = { 0, 0, 0 }, position = { 0, 2.5, 0 },
                    cell_type = 3, room_id = -1, floor_id = 0, stairwell_id = 0, stair_role = 0, connection_id = 0 },
                { id = 1, grid_index = 1, grid_coord = { 1, 0, 0 }, position = { 5, 2.5, 0 },
                    cell_type = 3, room_id = -1, floor_id = 0, stairwell_id = 0, stair_role = 1, connection_id = 0 },
                { id = 2, grid_index = 2, grid_coord = { 0, 1, 0 }, position = { 0, 7.5, 0 },
                    cell_type = 4, room_id = -1, floor_id = 1, stairwell_id = 0, stair_role = 2, connection_id = 0 },
                { id = 3, grid_index = 3, grid_coord = { 1, 1, 0 }, position = { 5, 7.5, 0 },
                    cell_type = 4, room_id = -1, floor_id = 1, stairwell_id = 0, stair_role = 3, connection_id = 0 },
                { id = 4, grid_index = 4, grid_coord = { -1, 0, 0 }, position = { -5, 2.5, 0 },
                    cell_type = 2, room_id = -1, floor_id = 0, stairwell_id = -1, stair_role = -1, connection_id = 0 },
                { id = 5, grid_index = 5, grid_coord = { 2, 1, 0 }, position = { 10, 7.5, 0 },
                    cell_type = 2, room_id = -1, floor_id = 1, stairwell_id = -1, stair_role = -1, connection_id = 0 },
                { id = 6, grid_index = 6, grid_coord = { 1, 0, 1 }, position = { 5, 2.5, 5 },
                    cell_type = 3, room_id = -1, floor_id = 0, stairwell_id = 1, stair_role = 0, connection_id = 1 },
                { id = 7, grid_index = 7, grid_coord = { 0, 0, 1 }, position = { 0, 2.5, 5 },
                    cell_type = 3, room_id = -1, floor_id = 0, stairwell_id = 1, stair_role = 1, connection_id = 1 },
                { id = 8, grid_index = 8, grid_coord = { 1, 1, 1 }, position = { 5, 7.5, 5 },
                    cell_type = 4, room_id = -1, floor_id = 1, stairwell_id = 1, stair_role = 2, connection_id = 1 },
                { id = 9, grid_index = 9, grid_coord = { 0, 1, 1 }, position = { 0, 7.5, 5 },
                    cell_type = 4, room_id = -1, floor_id = 1, stairwell_id = 1, stair_role = 3, connection_id = 1 },
                { id = 10, grid_index = 10, grid_coord = { 2, 0, 1 }, position = { 10, 2.5, 5 },
                    cell_type = 2, room_id = -1, floor_id = 0, stairwell_id = -1, stair_role = -1, connection_id = 1 },
                { id = 11, grid_index = 11, grid_coord = { -1, 1, 1 }, position = { -5, 7.5, 5 },
                    cell_type = 2, room_id = -1, floor_id = 1, stairwell_id = -1, stair_role = -1, connection_id = 1 },
            },
            doors = {},
        }, { cellSize = 5 })
        Check(oppositeDirectionProbe.stairTopologyValid,
            "opposite stair marker probe has an invalid stair topology")
        Check(oppositeDirectionProbe.removedStairInteriorMarkerCount == 0,
            "markers between opposite stair cells were removed")
        local retainedBetweenOppositeStairs = 0
        for _, marker in ipairs(oppositeDirectionProbe.branches.walls) do
            local betweenStairs = math.abs(marker.position[3] - 2.5) < 0.001
                and (math.abs(marker.position[1]) < 0.001 or math.abs(marker.position[1] - 5) < 0.001)
                and (math.abs(marker.position[2]) < 0.001 or math.abs(marker.position[2] - 5) < 0.001)
            if betweenStairs then retainedBetweenOppositeStairs = retainedBetweenOppositeStairs + 1 end
        end
        Check(retainedBetweenOppositeStairs == 4,
            "markers between opposite stair cells were not retained")

        local dungeon = DungeonGenerator.Generate({
            seed = 20260720, floorCount = 2, roomCount = 18,
            settingKey = "dungeon", theme = "grim", loopRate = 0.08,
            decorDensity = 0.72,
        })
        Check(dungeon.valid, "runtime dungeon fixture is invalid")
        local generated = PCGDungeonMarkerPipeline.GenerateFromDungeon(dungeon)
        Check(#generated.markers > 0, "runtime dungeon produced no markers")
        Check(#generated.faces > 0, "runtime dungeon produced no boundary faces")
        for _, name in ipairs({ "Ground", "Wall", "Door", "WallSeparator", "Ceil", "Light" }) do
            Check((generated.counts[name] or 0) > 0, "runtime dungeon is missing " .. name)
        end
        local message = string.format(
            "[PCGDungeonMarkerFlow] PASS reference=%d markers/%d faces runtime=%d markers/%d faces",
            report.markerCount, report.faceCount, #generated.markers, #generated.faces)
        ErrorExit(message, 0)
    end, debug.traceback)
    if not ok then
        ErrorExit("[PCGDungeonMarkerFlow] FAIL\n" .. tostring(errorMessage), 1)
        return
    end
end
