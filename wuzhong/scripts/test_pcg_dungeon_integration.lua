local PCGDungeonGenerator = require("Generation.PCGDungeonGenerator")
local PCGDungeonMarkerPipeline = require("Generation.PCGDungeonMarkerPipeline")
local PCGDungeonMeshInfoAdapter = require("Generation.PCGDungeonMeshInfoAdapter")
local PCGDungeonRenderer = require("Rendering.PCGDungeonRenderer")
local DungeonApp = require("App.DungeonApp")

local resultPath = ".tmp/pcg-dungeon-integration.result.txt"

local function WriteResult(message)
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    local result = File(resultPath, FILE_WRITE)
    if result and result:IsOpen() then
        result:WriteLine(message)
        result:Close()
    end
end

local function Check(condition, message)
    if not condition then error(message, 2) end
end

local function Near(actual, expected, tolerance)
    return math.abs(actual - expected) <= (tolerance or 0.000001)
end

local function PositionKey(position)
    return string.format("%.4f|%.4f|%.4f", position.x, position.y, position.z)
end

local function LightPositionSet(entries)
    local result = {}
    for _, entry in ipairs(entries or {}) do
        if entry.node then result[PositionKey(entry.node.worldPosition)] = true end
    end
    return result
end

local function MarkerPositionSet(markerResult)
    local lightMarkers, result = {
        Light = true, Light_Ambient = true, Light_Door = true,
        Light_Stair = true, Light_Hero = true, PillarPlacement = true,
    }, {}
    for _, marker in ipairs(markerResult.markers or {}) do
        if lightMarkers[marker.name] then
            local position = marker.position
            result[string.format("%s|%.4f|%.4f|%.4f", marker.name,
                position[1], position[2], position[3])] = true
        end
    end
    return result
end

local function SetsDiffer(a, b)
    for key in pairs(a) do if not b[key] then return true end end
    for key in pairs(b) do if not a[key] then return true end end
    return false
end

local function CountSceneLights(node)
    local count = node:GetComponent("Light") and 1 or 0
    for _, child in ipairs(node:GetChildren()) do count = count + CountSceneLights(child) end
    return count
end

local function InstanceHeightRange(renderer)
    local minimum, maximum = math.huge, -math.huge
    for _, nodes in pairs(renderer.groupInstanceNodes or {}) do
        for _, node in ipairs(nodes) do
            local y = node.worldPosition.y
            minimum, maximum = math.min(minimum, y), math.max(maximum, y)
        end
    end
    return minimum, maximum
end

local function ReadLightContracts()
    for _, path in ipairs({
        "assets/PCGDungeon/PCGDungeon.mesh_info.json",
        "PCGDungeon/PCGDungeon.mesh_info.json",
    }) do
        if cache:Exists(path) then
            local file = assert(cache:GetFile(path), "could not open " .. path)
            local data = cjson.decode(file:ReadString())
            file:Close()
            local contracts = {}
            for _, rule in ipairs(data.meshes or {}) do
                if rule.point_light_enabled == true then
                    contracts[rule.id] = {
                        brightness = rule.point_light_brightness,
                        range = rule.point_light_range_m,
                        variation = rule.point_light_radius_variation or 0,
                    }
                end
            end
            return contracts, data.light_defaults
        end
    end
    error("PCGDungeon.mesh_info.json was not found")
end

function Start()
    local ok, errorMessage = xpcall(function()
        local adapted = PCGDungeonMeshInfoAdapter.Apply({
            meshes = {
                { id = "coordinate_probe", usage = "inherit", marker = "Ground", mesh = "CoordinateProbe" },
            },
        }, {
            markers = {
                {
                    name = "Ground",
                    position = { 1, 2, 3 },
                    orient = { 0.1, 0.2, 0.3, 0.9 },
                    scale = { 2, 3, 4 },
                    pscale = 0.5,
                    attributes = { marker_size = { 2, 1, 4 } },
                },
            },
            faces = {},
        })
        local packed = adapted.scene.instances[1].transforms[1]
        Check(packed[1] == 100 and packed[2] == 300 and packed[3] == 200,
            "Y-up Marker position was not packed as UE Z-up (X, Z, Y)")
        Check(packed[4] == -0.1 and packed[5] == -0.3 and packed[6] == -0.2 and packed[7] == 0.9,
            "Y-up Marker quaternion did not account for the handedness-changing Y/Z swap")
        Check(packed[8] == 1 and packed[9] == 2 and packed[10] == 1.5,
            "Y-up Marker scale axes were not packed as UE Z-up (X, Z, Y)")

        local cardinalMarkers = PCGDungeonMarkerPipeline.GenerateFromTopology({
            cells = {},
            doors = {
                { position = { 1, 0, 10 }, normal = { 0, 0, 1 } },
                { position = { 2, 0, 20 }, normal = { -1, 0, 0 } },
                { position = { 3, 0, 30 }, normal = { 0, 0, -1 } },
                { position = { 4, 0, 40 }, normal = { 1, 0, 0 } },
            },
        }, { cellSize = 5.0 })
        local cardinalManifest = PCGDungeonMeshInfoAdapter.Apply({
            meshes = {
                { id = "door_arch01", usage = "inherit", marker = "Door",
                    mesh = "/Game/FantasyDungeon/meshes/Door/DoorArch01.DoorArch01",
                    marker_yaw_offset_deg = 90,
                    offset_cm = { 0, 0, 0 }, rotation_deg = { 0, 0, 0 }, scale = { 1, 1, 1 } },
                { id = "door_leaf02", usage = "attach", marker = "Door",
                    source_mesh = "/Game/FantasyDungeon/meshes/Door/DoorArch01.DoorArch01",
                    mesh = "/Game/FantasyDungeon/meshes/Door/Door02.Door02",
                    offset_cm = { -61.669051, 3.98934, -0.322654 },
                    rotation_deg = { 0, 0, 0 }, scale = { 1.1, 1.1, 1.1 } },
            },
            scatter_rules = {},
        }, cardinalMarkers)
        local transforms = cardinalManifest.scene.instances[1].transforms
        local half = math.sqrt(0.5)
        local expectedPacked = {
            { 100, 1000, 0, 0, 0, 0, 1 },
            { 200, 2000, 0, 0, 0, half, half },
            { 300, 3000, 0, 0, 0, -1, 0 },
            { 400, 4000, 0, 0, 0, -half, half },
        }
        for index, expected in ipairs(expectedPacked) do
            for component = 1, 7 do
                Check(math.abs(transforms[index][component] - expected[component]) < 0.00001,
                    string.format("DoorArch cardinal transform %d component %d is wrong", index, component))
            end
        end

        local stairManifest = PCGDungeonMeshInfoAdapter.Apply({
            meshes = {
                { id = "stair_stairs01", usage = "inherit", marker = "Stair", mesh = "Stairs01",
                    marker_yaw_offset_deg = 180,
                    marker_copies = {
                        { local_offset_m = { 0, 0, 0 } },
                        { local_offset_m = { 0, 2.5, 5 } },
                    } },
            },
        }, {
            markers = {
                { name = "Stair", position = { 0, 0, 0 }, orient = { 0, 0, 0, 1 }, attributes = {} },
            },
            faces = {},
        })
        local stairTransform = stairManifest.scene.instances[1].transforms[1]
        Check(math.abs(stairTransform[4]) < 0.00001 and math.abs(stairTransform[5]) < 0.00001
            and math.abs(stairTransform[6] + 1) < 0.00001 and math.abs(stairTransform[7]) < 0.00001,
            "Stairs01 raw Marker correction does not match fixed PCG Dungeon")
        local upperStairTransform = stairManifest.scene.instances[1].transforms[2]
        Check(#stairManifest.scene.instances[1].transforms == 2
            and math.abs(upperStairTransform[1]) < 0.00001
            and math.abs(upperStairTransform[2] - 500) < 0.00001
            and math.abs(upperStairTransform[3] - 250) < 0.00001,
            "Stairs01 second Copy-to-Points offset does not match fixed PCG Dungeon")

        local grouped = PCGDungeonMeshInfoAdapter.Apply({
            meshes = {
                {
                    id = "ground_room", marker = "Ground", marker_group = "marker_Ground_Room",
                    usage = "inherit", mesh = "SharedFloor",
                },
                {
                    id = "ground_corridor", marker = "Ground", marker_group = "marker_Ground_Corridor",
                    usage = "inherit", mesh = "SharedFloor",
                    material_overrides = { "Materials/pavement2.xml" },
                },
            },
        }, {
            markers = {
                {
                    name = "Ground", position = { 0, 0, 0 },
                    groups = { marker_Ground_Room = true }, attributes = {},
                },
                {
                    name = "Ground", position = { 5, 0, 0 },
                    groups = { marker_Ground_Corridor = true }, attributes = {},
                },
            },
            faces = {},
        })
        Check(grouped.scene.instance_group_count == 2 and grouped.scene.instance_count == 2,
            "room and corridor Ground markers were not split into unique rule groups")
        Check(grouped.scene.instances[1].rule_id == "ground_room"
            and grouped.scene.instances[2].rule_id == "ground_corridor",
            "Ground marker rule_id was not preserved by the mesh_info adapter")

        local app = DungeonApp.new()
        app.loopRates = { 8, 23 }
        local applied = app:ApplyPCGDungeonParameters({
            seed = 24681357, floorCount = 2, roomCountsByFloor = { 6, 8 },
        })
        Check(applied.seed == 24681357 and app.seed == applied.seed,
            "PCG Dungeon seed parameter was not applied")
        Check(app.floorCount == 2 and #app.roomCounts == 2,
            "PCG Dungeon floor parameter was not applied")
        Check(applied.roomCount == 14 and app.roomCounts[1] == 6 and app.roomCounts[2] == 8,
            "PCG Dungeon per-floor room parameters were not preserved")
        Check(Near(applied.loopRatesByFloor[1], 0.08) and Near(applied.loopRatesByFloor[2], 0.23),
            "PCG Dungeon per-floor loop rates were not normalized for graph generation")
        Check(app.pcgDungeonRoomCount == nil,
            "PCG Dungeon still retains a separate total room parameter")

        local unevenDungeon = PCGDungeonGenerator.Generate({
            seed = 5, floorCount = 3, roomCountsByFloor = { 6, 9, 7 }, cellSize = 5.0,
        })
        Check(unevenDungeon.valid, "uneven per-floor dungeon generation failed: "
            .. tostring(unevenDungeon.error))
        Check(unevenDungeon.roomCount == 22
                and unevenDungeon.roomCountsByFloor[1] == 6
                and unevenDungeon.roomCountsByFloor[2] == 9
                and unevenDungeon.roomCountsByFloor[3] == 7,
            "PCG Dungeon generation ignored exact per-floor counts")

        local dungeon = PCGDungeonGenerator.Generate({
            seed = 5,
            floorCount = 3,
            roomCount = 22,
            cellSize = 5.0,
        })
        Check(dungeon.valid, "parameterized dungeon generation failed: "
            .. table.concat(dungeon.errors or { tostring(dungeon.error) }, "; "))
        Check(dungeon.stats.floors == 3 and dungeon.roomCount == 22,
            "legacy reference total room/floor parameters were ignored")
        Check(dungeon.astar.stairCount == 26, "default legacy reference stair topology was not reproduced")
        for _, room in ipairs(dungeon.rooms) do
            Check(room.w >= 1 and room.w <= 3 and room.h >= 1 and room.h <= 3,
                "legacy reference room cell bounds were ignored")
        end
        local alternate = PCGDungeonGenerator.Generate({
            seed = 6, floorCount = 3, roomCount = 22, cellSize = 5.0,
        })
        Check(alternate.valid and alternate.hash ~= dungeon.hash,
            "changing the random seed did not change the dungeon layout")

        local markerResult = PCGDungeonMarkerPipeline.GenerateFromTopology(dungeon.topology, {
            cellSize = 5.0, pillarPlacementDistance = 1.2,
        })
        Check(#markerResult.markers > 0 and #markerResult.faces > 0,
            "legacy reference runtime flow produced no marker geometry")
        Check((markerResult.counts.Ground or 0) > 0, "runtime flow produced no Ground markers")
        Check((markerResult.counts.Door or 0) > 0, "runtime flow produced no Door markers")
        Check((markerResult.counts.Stair or 0) == 26, "runtime flow did not emit all legacy reference stairs")
        Check(markerResult.stairTopologyValid == true,
            "runtime flow emitted an invalid four-cell stair contract: "
            .. table.concat(markerResult.stairTopologyErrors or {}, "; "))

        local scene = Scene()
        scene:CreateComponent("Octree")

        local manifestDrivenRenderer = PCGDungeonRenderer.new(scene)
        local manifestDriven, manifestStats = manifestDrivenRenderer:BuildManifest({
            asset_bindings = {
                ConfiguredMesh = {
                    model_resource = "Models/Box.mdl",
                    material_resource = "Materials/pavement2.xml",
                },
            },
            diagnostic_meshes = {
                light_volume = "Models/Sphere.mdl",
                cell_volume = "Models/Box.mdl",
            },
            meshes = {
                {
                    id = "configurable_prefab", usage = "prefab", marker = "Wall",
                    source_mesh = "MarkerTransport", mesh = "LogicalPrefab",
                    visible = true, cast_shadow = false,
                    offset_cm = { 0, 0, 0 }, rotation_deg = { 0, 0, 0 }, scale = { 1, 1, 1 },
                    parts = {
                        {
                            id = "only", mesh = "ConfiguredMesh",
                            offset_cm = { 0, 0, 0 }, rotation_deg = { 0, 37, 0 }, scale = { 1, 1, 1 },
                        },
                    },
                },
            },
            scatter_rules = {},
            scene = {
                schema_version = 1, instance_group_count = 1, instance_count = 1,
                instances = {
                    {
                        rule_id = "configurable_prefab", marker = "Wall", mesh = "MarkerTransport",
                        transforms = { { 0, 0, 0, 0, 0, 0, 1, 1, 1, 1 } }, room_ids = { -1 },
                    },
                },
                surfaces = {},
            },
        }, "mesh-info-probe", nil, "disabled")
        Check(manifestDriven, "mesh_info-driven prefab probe failed: " .. tostring(manifestStats))
        Check(manifestStats.baseInstances == 1 and manifestStats.groups == 1,
            "prefab instance count was not controlled by mesh_info.parts")
        Check(manifestDrivenRenderer.resolvedMaterials["Prefab-configurable_prefab-only"]
                == "Materials/pavement2.xml",
            "model material was not resolved from mesh_info.asset_bindings")
        Check(manifestDrivenRenderer.groups[1].castShadows == false,
            "mesh_info cast_shadow was not applied to the generated group")
        manifestDrivenRenderer:Dispose()

        local pcgDungeonRenderer = PCGDungeonRenderer.new(scene)
        local preloaded, preloadStats = pcgDungeonRenderer:PreloadResources()
        Check(preloaded, "PCG Dungeon resources could not be queued for preload")
        Check(preloadStats.models > 0 and preloadStats.materials > 0 and preloadStats.failed == 0,
            "PCG Dungeon preload did not queue every manifest resource")
        pcgDungeonRenderer.preloadStats = { failed = 1 }
        local cachedFailureAccepted, cachedFailureStats = pcgDungeonRenderer:PreloadResources()
        Check(not cachedFailureAccepted and cachedFailureStats.failed == 1,
            "cached PCG Dungeon preload failure was incorrectly accepted as success")
        pcgDungeonRenderer.preloadStats = preloadStats
        local cellDebugData = {
            rooms = dungeon.rooms,
            cells = dungeon.topology.cells,
            cellSize = 5.0,
        }
        local rebuilt, stats = pcgDungeonRenderer:RebuildFromMarkers(markerResult, cellDebugData)
        Check(rebuilt, "dynamic mesh_info rebuild failed: " .. tostring(stats))
        Check(stats.source:find("pcg%-runtime") ~= nil, "fixed PCG Dungeon instances were still used")
        Check(stats.markerCount == #markerResult.markers, "Marker count was not carried into renderer stats")
        Check(stats.faceCount == #markerResult.faces, "face count was not carried into renderer stats")
        Check(stats.lights > 0 and not pcgDungeonRenderer.referenceLightsEnabled,
            "dynamic Marker lights did not replace fixed reference lights")
        Check(stats.markerLights > 0 and stats.referenceLights == 0,
            "light_marker instances did not create runtime point lights")
        local lightContracts, lightDefaults = ReadLightContracts()
        local pointLightCount, mappedRules = 0, {}
        for _, entry in ipairs(pcgDungeonRenderer.lights) do
            if entry.light and entry.light.lightType == LIGHT_POINT then
                pointLightCount = pointLightCount + 1
                local contract = lightContracts[entry.ruleId]
                Check(contract ~= nil, "missing UrhoX light contract for " .. tostring(entry.ruleId))
                mappedRules[entry.ruleId] = true
                local light = entry.light
                Check(Near(light.brightness, contract.brightness),
                    string.format("%s brightness mismatch: %.6f", entry.ruleId, light.brightness))
                Check(light.range >= contract.range * (1 - contract.variation) - 0.000001
                        and light.range <= contract.range * (1 + contract.variation) + 0.000001,
                    string.format("%s range mismatch: %.6f", entry.ruleId, light.range))
                Check(light.usePhysicalValues, entry.ruleId .. " does not use physical values")
                Check(light.castShadows,
                    entry.ruleId .. " did not enable Marker light shadow casting")
                Check(Near(light.shadowBias.constantBias, lightDefaults.shadow_constant_bias)
                        and Near(light.shadowBias.slopeScaledBias, lightDefaults.shadow_slope_bias)
                        and Near(light.shadowBias.normalOffset, lightDefaults.shadow_normal_offset),
                    entry.ruleId .. " shadow bias does not match mesh_info light_defaults")
                Check(light:GetAttribute("Light Units"):GetInt() == 0,
                    entry.ruleId .. " is not using Unitless units")
                Check(Near(light.radius, 0) and Near(light.length, 0),
                    entry.ruleId .. " is not a zero-size point emitter")
                Check(Near(light:GetAttribute("SoftRadius"):GetFloat(), 0),
                    entry.ruleId .. " soft radius mismatch")
                Check(light:GetAttribute("Punctual Light"):GetBool(),
                    entry.ruleId .. " did not enable punctual lighting")
                Check(light:GetAttribute("Affect Volumetric Fog"):GetBool(),
                    entry.ruleId .. " does not affect volumetric fog")
                Check(Near(light:GetAttribute("Volumetric Fog Intensity"):GetFloat(), 1),
                    entry.ruleId .. " volumetric fog intensity mismatch")
                Check(light:GetAttribute("Volumetric Fog Shadows"):GetBool() == light.castShadows,
                    entry.ruleId .. " volumetric shadow mismatch")
            end
        end
        Check(pointLightCount == stats.lights,
            "runtime light registry contains a non-point light")
        for ruleId in pairs(lightContracts) do
            Check(mappedRules[ruleId], "dynamic flow did not create " .. ruleId)
        end
        local originalLightPositions = LightPositionSet(pcgDungeonRenderer.lights)
        local originalMarkerPositions = MarkerPositionSet(markerResult)
        local originalRoot = pcgDungeonRenderer.root
        local alternateMarkerResult = PCGDungeonMarkerPipeline.GenerateFromTopology(alternate.topology, {
            cellSize = 5.0, pillarPlacementDistance = 1.2,
        })
        Check(SetsDiffer(originalMarkerPositions, MarkerPositionSet(alternateMarkerResult)),
            "changing the layout did not change the light-source Marker set")
        local alternateBuilt, alternateStats = pcgDungeonRenderer:RebuildFromMarkers(alternateMarkerResult, {
            rooms = alternate.rooms, cells = alternate.topology.cells, cellSize = 5.0,
        })
        Check(alternateBuilt, "alternate dynamic mesh_info rebuild failed: " .. tostring(alternateStats))
        Check(pcgDungeonRenderer.root ~= originalRoot, "refresh reused the old PCG Dungeon root node")
        Check(SetsDiffer(originalLightPositions, LightPositionSet(pcgDungeonRenderer.lights)),
            "point-light transforms were not refreshed for the alternate layout")
        Check(CountSceneLights(scene) == #pcgDungeonRenderer.lights,
            "refresh left stale point-light components in the scene")
        local restored, restoredStats = pcgDungeonRenderer:RebuildFromMarkers(markerResult, cellDebugData)
        Check(restored, "original layout restore failed: " .. tostring(restoredStats))
        Check(not SetsDiffer(originalLightPositions, LightPositionSet(pcgDungeonRenderer.lights)),
            "restoring the original Marker set produced different light transforms")
        Check(pcgDungeonRenderer.lightDebugVisible == false and pcgDungeonRenderer.lightDebugRoot == nil,
            "runtime point-light verification accidentally enabled debug geometry")
        Check(pcgDungeonRenderer.resolvedMaterials["PCGDungeon-ground_floor01_corridor"] == "Materials/pavement2.xml",
            "corridor Ground rule did not resolve Materials/pavement2.xml from mesh_info")
        local corridorMaterial = nil
        for _, group in ipairs(pcgDungeonRenderer.groups) do
            if group.node and group.node.name == "PCGDungeon-ground_floor01_corridor" then
                corridorMaterial = group:GetMaterial(0)
                break
            end
        end
        Check(corridorMaterial ~= nil,
            "corridor Ground group did not bind its resolved material resource")
        Check(corridorMaterial:GetTechnique(0) ~= nil,
            "corridor Ground material remained an unloaded white placeholder")
        Check(cache:GetResource("Texture2D", "Textures/pavement2_D.png") ~= nil,
            "corridor Ground base-color texture was not loaded")

        local allInstanceCount = stats.baseInstances + stats.attachedInstances + stats.scatterInstances
        local _, allMaximumY = InstanceHeightRange(pcgDungeonRenderer)
        local currentBuilt, currentStats = pcgDungeonRenderer:RebuildView({
            currentFloor = 0, viewMode = "current", floorHeight = 5.0,
        })
        Check(currentBuilt, "current-floor PCG view failed: " .. tostring(currentStats))
        local currentInstanceCount = currentStats.baseInstances
            + currentStats.attachedInstances + currentStats.scatterInstances
        Check(currentInstanceCount > 0 and currentInstanceCount < allInstanceCount,
            "current-floor PCG view did not reduce visible instances")
        Check(currentStats.lights > 0 and currentStats.lights < stats.lights,
            "current-floor PCG view did not reduce visible Marker lights")

        local neighborsBuilt, neighborsStats = pcgDungeonRenderer:RebuildView({
            currentFloor = 0, viewMode = "neighbors", floorHeight = 5.0,
        })
        Check(neighborsBuilt, "neighbor-floor PCG view failed: " .. tostring(neighborsStats))
        local neighborsInstanceCount = neighborsStats.baseInstances
            + neighborsStats.attachedInstances + neighborsStats.scatterInstances
        Check(neighborsInstanceCount > currentInstanceCount and neighborsInstanceCount < allInstanceCount,
            "neighbor-floor PCG view did not show exactly one additional floor range")

        local explodeBuilt, explodeStats = pcgDungeonRenderer:RebuildView({
            currentFloor = 0, viewMode = "explode", floorHeight = 5.0,
        })
        Check(explodeBuilt, "exploded PCG view failed: " .. tostring(explodeStats))
        local explodeInstanceCount = explodeStats.baseInstances
            + explodeStats.attachedInstances + explodeStats.scatterInstances
        local _, explodeMaximumY = InstanceHeightRange(pcgDungeonRenderer)
        Check(explodeInstanceCount == allInstanceCount,
            "exploded PCG view changed the full-scene instance count")
        Check(explodeMaximumY > allMaximumY + 5.0,
            "exploded PCG view did not increase vertical floor spacing")

        local allBuilt, restoredAllStats = pcgDungeonRenderer:RebuildView({
            currentFloor = 0, viewMode = "all", floorHeight = 5.0,
        })
        Check(allBuilt, "all-floor PCG view restore failed: " .. tostring(restoredAllStats))
        Check(restoredAllStats.baseInstances + restoredAllStats.attachedInstances
                + restoredAllStats.scatterInstances == allInstanceCount,
            "all-floor PCG view did not restore the full instance count")
        Check(restoredAllStats.lights == stats.lights,
            "all-floor PCG view did not restore all Marker lights")

        local originalGroups = stats.groups
        local originalInstances = stats.baseInstances + stats.attachedInstances + stats.scatterInstances
        local originalLights = stats.lights

        local cellDebugEnabled, cellStats = pcgDungeonRenderer:ToggleCellDebug()
        Check(cellDebugEnabled == true, "cell debug did not enable: " .. tostring(cellStats))
        Check(cellStats.rooms == #dungeon.rooms, "cell debug room volume count differs")
        Check(cellStats.corridors == dungeon.astar.corridorCellCount,
            "cell debug corridor count differs from A* canonical cells")
        Check(cellStats.physicalStairs == dungeon.astar.stairCount * 2,
            "cell debug physical stair count differs from legacy reference")
        Check(cellStats.headroom == dungeon.astar.stairCount * 2,
            "cell debug stair headroom count differs from legacy reference")
        Check(cellStats.stairs == dungeon.astar.stairCount * 4,
            "cell debug did not include all physical/headroom stair cells")
        Check(cellStats.total == cellStats.rooms + cellStats.corridors + cellStats.stairs,
            "cell debug total count is inconsistent")
        Check(pcgDungeonRenderer.cellDebugRoot ~= nil and pcgDungeonRenderer.root == nil,
            "cell debug did not replace the final dungeon view")
        Check(#pcgDungeonRenderer.groups == 0, "cell debug left dungeon render groups alive")

        local cellDebugDisabled, disabledStats = pcgDungeonRenderer:ToggleCellDebug()
        Check(cellDebugDisabled == false and disabledStats.total == 0,
            "cell debug did not report a clean disabled state")
        Check(pcgDungeonRenderer.cellDebugRoot == nil and pcgDungeonRenderer.root ~= nil and pcgDungeonRenderer.root:IsEnabled(),
            "disabling cell debug did not restore the final dungeon view")
        for _, group in ipairs(pcgDungeonRenderer.groups) do
            Check(group:IsEnabled() and group:GetNode():IsEnabled(),
                "disabling cell debug did not restore a dungeon render component and node")
        end
        Check(pcgDungeonRenderer.stats.groups == originalGroups,
            "disabling cell debug restored a different render group count")
        Check(pcgDungeonRenderer.stats.baseInstances + pcgDungeonRenderer.stats.attachedInstances
                + pcgDungeonRenderer.stats.scatterInstances == originalInstances,
            "disabling cell debug restored a different instance count")
        Check(pcgDungeonRenderer.stats.lights == originalLights,
            "disabling cell debug restored a different light count")

        local cellDebugAgain, cellDebugAgainStats = pcgDungeonRenderer:ToggleCellDebug()
        Check(cellDebugAgain == true and cellDebugAgainStats.total == cellStats.total,
            "cell debug could not be re-enabled before the refresh transition test")
        local refreshedInCellDebug, refreshedInCellDebugStats = pcgDungeonRenderer:RebuildFromMarkers(
            alternateMarkerResult, {
                rooms = alternate.rooms, cells = alternate.topology.cells, cellSize = 5.0,
            })
        Check(refreshedInCellDebug,
            "refresh while cell debug was active failed: " .. tostring(refreshedInCellDebugStats))
        Check(pcgDungeonRenderer.cellDebugVisible and pcgDungeonRenderer.root == nil and #pcgDungeonRenderer.lights == 0,
            "cell debug refresh unexpectedly retained live dungeon lights")
        local lightDebugEnabled, refreshedLightCount = pcgDungeonRenderer:SetLightDebugVisible(true)
        Check(lightDebugEnabled == true and refreshedLightCount == refreshedInCellDebugStats.lights,
            "switching from refreshed cell debug did not restore the latest point lights")
        Check(not pcgDungeonRenderer.cellDebugVisible and pcgDungeonRenderer.root ~= nil
                and pcgDungeonRenderer.lightDebugRoot ~= nil,
            "switching from cell debug did not restore dungeon and light-debug geometry")
        Check(CountSceneLights(scene) == refreshedLightCount,
            "cell-to-light debug transition restored stale Light components")
        Check(SetsDiffer(originalLightPositions, LightPositionSet(pcgDungeonRenderer.lights)),
            "cell-to-light debug transition restored the previous layout's point lights")
        pcgDungeonRenderer:SetLightDebugVisible(false)

        pcgDungeonRenderer:Dispose()
        scene:Dispose()
        local passMessage = string.format(
            "PASS floors=3 rooms=22 stairs=26 debugBoxes=%d restoredGroups=%d restoredInstances=%d restoredLights=%d",
            cellStats.total, originalGroups, originalInstances, originalLights)
        WriteResult(passMessage)
        print("[PCGDungeonIntegration] " .. passMessage)
        ErrorExit("[PCGDungeonIntegration] " .. passMessage, 0)
    end, debug.traceback)
    if not ok then
        WriteResult("FAIL\n" .. tostring(errorMessage))
        ErrorExit("[PCGDungeonIntegration] FAIL\n" .. tostring(errorMessage), 1)
        return
    end
end
