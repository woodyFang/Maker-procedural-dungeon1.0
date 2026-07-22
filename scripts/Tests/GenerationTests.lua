local Random = require("Generation.Random")
local DungeonGenerator = require("Generation.DungeonGenerator")
local MultiFloor = require("Generation.MultiFloor")
local StairContract = require("Generation.StairContract")
local GeometryRules = require("Generation.GeometryRules")
local MaterialRules = require("Rendering.ProceduralMaterialRules")
local PropBlueprints = require("Rendering.PropBlueprints")
local CustomizationStore = require("Config.CustomizationStore")
local ThemePacks = require("Config.ThemePacks")
local GenericThemeRules = require("Config.GenericThemeRules")
local PaletteData = require("Config.PaletteData")
local Themes = require("Config.Themes")
local BuiltinRoomRules = require("Config.BuiltinRoomRules")
local LocalRequirementPlanner = require("AI.LocalRequirementPlanner")
local CurrentFloorCue = require("Rendering.CurrentFloorCue")

local GenerationTests = {}

local function Check(condition, message)
    if not condition then error(message or "check failed", 2) end
end

local function CheckValid(dungeon, label)
    Check(dungeon ~= nil, label .. ": generator returned nil")
    Check(dungeon.valid, label .. ": " .. table.concat(dungeon.errors or {}, "; "))
    for _, room in ipairs(dungeon.rooms) do
        local layer = dungeon.layers[room.floor + 1]
        local cell = room.cy * dungeon.width + room.cx + 1
        Check(layer.bfs[cell] and layer.bfs[cell] >= 0,
            string.format("%s: room %d is unreachable", label, room.id))
    end
end

local function TestRandomDeterminism()
    local a, b = Random.new(20260714), Random.new(20260714)
    for i = 1, 64 do
        Check(a:Raw() == b:Raw(), "Mulberry32 diverged at sample " .. i)
    end
end

local function TestRouteTurnPenalty()
    local width, height = 48, 40
    local layer = {
        grid = {}, roomId = {}, corridor = {}, corridorOwner = {},
        stairMask = {}, stairwellMask = {}, stairClearance = {},
        stairLanding = {}, slabOpening = {},
    }
    local x, y = 2, 2
    local function MarkCorridor(px, py) layer.corridor[py * width + px + 1] = true end
    MarkCorridor(x, y)
    -- Existing cheap cells form the excessive staircase visible in the
    -- regression. Three's directional turn cost must prefer fewer, longer runs.
    for _ = 1, 8 do
        for _ = 1, 4 do x = x + 1; MarkCorridor(x, y) end
        for _ = 1, 3 do y = y + 1; MarkCorridor(x, y) end
    end
    local options = { width = width, height = height, startRoomId = 1, goalRoomId = 2 }
    local route = MultiFloor.RouteAStar(layer, { x = 2, y = 2 }, { x = x, y = y }, options)
    local noTurnPenalty = MultiFloor.RouteAStar(layer, { x = 2, y = 2 }, { x = x, y = y }, {
        width = width, height = height, startRoomId = 1, goalRoomId = 2,
        turnCost = 0, reverseCost = 0,
    })
    Check(route and noTurnPenalty, "turn-penalty route search failed")
    Check(#route.points < #noTurnPenalty.points,
        string.format("turn penalty did not reduce folds: default=%d zero=%d",
            #route.points, #noTurnPenalty.points))

    local openLayer = {
        grid = {}, roomId = {}, corridor = {}, corridorOwner = {},
        stairMask = {}, stairwellMask = {}, stairClearance = {},
        stairLanding = {}, slabOpening = {},
    }
    local openRoute = MultiFloor.RouteAStar(openLayer, { x = 2, y = 2 }, { x = 35, y = 26 }, options)
    Check(openRoute and #openRoute.points <= 3,
        "unobstructed route retained more than one bend")
end

local function TestStairContractHeadroomAndProtection()
    local contract, reason = StairContract.Build({
        mapWidth = 48, mapHeight = 48,
        lower = { x = 8, y = 20 }, direction = "east",
        run = 10, width = 2, landingDepth = 2,
        sideClearance = 0, style = "straight",
        floorHeight = 5.0, stepCount = 20,
    })
    Check(contract ~= nil, reason)
    Check(contract.width == 2 and contract.stepCount == 20,
        "stair contract lost its metre width or step count")
    Check(#contract.openingCells > 0 and #contract.openingCells < #contract.shaftCells,
        "strict headroom opening did not stay smaller than the physical stair shaft")
    local openingSet = StairContract.CellSet(contract.openingCells)
    local sawOpening = false
    for _, item in ipairs(contract.sweptClearanceCells) do
        local expected = item.treadElevation < 5.0 - StairContract.EPSILON
            and item.clearanceTop > 5.0 + StairContract.EPSILON
        Check(not not openingSet[item.cell] == expected,
            "opening membership diverged from strict swept-clearance rule")
        if openingSet[item.cell] then sawOpening = true end
    end
    Check(sawOpening, "headroom test did not produce a slab opening")
    local strictBoundary = StairContract.Build({
        mapWidth = 32, mapHeight = 32,
        lower = { x = 6, y = 12 }, direction = "east",
        run = 8, width = 1, landingDepth = 2,
        sideClearance = 0, style = "straight",
        floorHeight = 5.0, stepCount = 10,
    })
    local strictOpeningSet = StairContract.CellSet(strictBoundary.openingCells)
    local sawExactBoundary = false
    for _, item in ipairs(strictBoundary.sweptClearanceCells) do
        if math.abs(item.clearanceTop - 5.0) < StairContract.EPSILON then
            sawExactBoundary = true
            Check(not strictOpeningSet[item.cell],
                "equal-to-slab headroom incorrectly opened the slab")
        end
    end
    Check(sawExactBoundary, "headroom test did not cover the exact slab boundary")
    Check(#contract.openingAccessEdges > 0 and #contract.openingStairPassageEdges > 0,
        "opening contract did not classify both mandatory passages")

    for _, style in ipairs({ "straight", "l-turn" }) do
        for _, direction in ipairs({ "east", "south", "west", "north" }) do
            local candidate, candidateReason = StairContract.Build({
                mapWidth = 64, mapHeight = 64,
                lower = { x = 28, y = 28 }, direction = direction,
                run = 10, width = 3, landingDepth = 2,
                sideClearance = 1, style = style,
                floorHeight = 4.2, stepCount = 17,
            })
            Check(candidate ~= nil, string.format("%s %s: %s", style, direction, tostring(candidateReason)))
            Check(candidate.style == style and candidate.width == 3,
                "stair contract changed style or metre width")
            Check(math.abs(candidate.stepRise * candidate.stepCount - 4.2) < 0.000001,
                "configurable stair contract did not reach the target floor")
        end
    end
end

local function TestStairWidthMetreGrid()
    Check(StairContract.NormalizeWidth(0.2) == 1
        and StairContract.NormalizeWidth(1.49) == 1
        and StairContract.NormalizeWidth(1.51) == 2
        and StairContract.NormalizeWidth(4.6) == 5
        and StairContract.NormalizeWidth(9) == 5,
        "stair width is not normalized to the 1m / 1..5m contract")
end

local function TestDungeonDeterminism()
    local options = { seed = 424242, floorCount = 3, roomCount = 30, loopRate = 0.16 }
    local a = DungeonGenerator.Generate(options)
    local b = DungeonGenerator.Generate(options)
    CheckValid(a, "determinism A")
    CheckValid(b, "determinism B")
    Check(a.hash == b.hash, string.format("same seed produced hashes %s and %s", a.hash, b.hash))
end

local function FloorRoomSignature(dungeon, floor)
    ---@type table<integer, integer>
    local localIds, values = {}, {}
    for _, room in ipairs(dungeon.rooms) do
        if room.floor == floor then
            localIds[room.id] = #values + 1
            values[#values + 1] = string.format("room:%d:%d:%d:%d:%s:%d:%.4f",
                room.cx, room.cy, room.w, room.h, tostring(room.type), room.depth - floor * 100, room.difficulty)
        end
    end
    for _, edge in ipairs(dungeon.edges) do
        local a, b = localIds[edge.a], localIds[edge.b]
        if a and b then
            values[#values + 1] = string.format("edge:%d:%d:%s:%s",
                a, b, tostring(edge.isLoop == true), tostring(edge.isCritical == true))
        end
    end
    return table.concat(values, "|")
end

local function FloorDecorSignature(dungeon, floor)
    local layer = dungeon.layers[floor + 1]
    local values = {}
    for _, prop in ipairs(layer.props) do
        values[#values + 1] = string.format("prop:%s:%d:%d:%.4f:%.3f",
            prop.kind, prop.x, prop.y, prop.rot or 0, prop.scale or 1)
    end
    for _, spawn in ipairs(layer.spawns) do
        values[#values + 1] = string.format("spawn:%d:%d:%d", spawn.tier or 1, spawn.x, spawn.y)
    end
    return table.concat(values, "|")
end

local function SignatureDifference(a, b)
    local left, right = {}, {}
    for value in string.gmatch(a, "[^|]+") do left[#left + 1] = value end
    for value in string.gmatch(b, "[^|]+") do right[#right + 1] = value end
    for index = 1, math.max(#left, #right) do
        if left[index] ~= right[index] then
            return string.format("item %d: %s <> %s", index, tostring(left[index]), tostring(right[index]))
        end
    end
    return "no item difference"
end

local function GenerateIsolationCase(roomCounts, loopRates, densities, changedFloor, preserveDungeon)
    return DungeonGenerator.Generate({
        seed = 2026071501,
        floorCount = 3,
        roomCountsByFloor = roomCounts,
        loopRatesByFloor = loopRates,
        decorDensitiesByFloor = densities,
        changedFloor = changedFloor,
        preserveDungeon = preserveDungeon,
        settingKey = "hospital",
        theme = "sterile",
    })
end

local function TestFloorSettingIsolation()
    local baseline = GenerateIsolationCase({ 12, 12, 12 }, { 0.12, 0.16, 0.20 }, { 0.55, 0.65, 0.75 })
    CheckValid(baseline, "floor isolation baseline")

    local roomChanged = GenerateIsolationCase({ 17, 12, 12 }, { 0.12, 0.16, 0.20 }, { 0.55, 0.65, 0.75 }, 0, baseline)
    CheckValid(roomChanged, "floor isolation room count")
    local baselineFloor2, changedFloor2 = FloorRoomSignature(baseline, 1), FloorRoomSignature(roomChanged, 1)
    Check(baselineFloor2 == changedFloor2,
        "changing floor 1 room count changed floor 2 room layout: " .. SignatureDifference(baselineFloor2, changedFloor2))
    Check(FloorRoomSignature(baseline, 2) == FloorRoomSignature(roomChanged, 2),
        "changing floor 1 room count changed floor 3 room layout")
    -- Stair placement is the explicit cross-floor contract. A changed room
    -- count may move stair landings and the fixtures immediately around them,
    -- but it must not regenerate another floor's room graph.

    local loopChanged = GenerateIsolationCase({ 12, 12, 12 }, { 0.38, 0.16, 0.20 }, { 0.55, 0.65, 0.75 }, 0, baseline)
    CheckValid(loopChanged, "floor isolation loop rate")
    Check(FloorRoomSignature(baseline, 1) == FloorRoomSignature(loopChanged, 1)
            and FloorRoomSignature(baseline, 2) == FloorRoomSignature(loopChanged, 2),
        "changing floor 1 loop rate changed another floor")

    local decorChanged = GenerateIsolationCase({ 12, 12, 12 }, { 0.12, 0.16, 0.20 }, { 0.95, 0.65, 0.75 })
    CheckValid(decorChanged, "floor isolation decor density")
    Check(FloorRoomSignature(baseline, 1) == FloorRoomSignature(decorChanged, 1)
            and FloorRoomSignature(baseline, 2) == FloorRoomSignature(decorChanged, 2),
        "changing floor 1 decor density changed another floor layout")
    Check(FloorDecorSignature(baseline, 1) == FloorDecorSignature(decorChanged, 1)
            and FloorDecorSignature(baseline, 2) == FloorDecorSignature(decorChanged, 2),
        "changing floor 1 decor density changed another floor decoration")
end

local function TestCurrentFloorCueBounds()
    local dungeon = {
        width = 8,
        height = 6,
        layers = {
            { grid = {} },
            { grid = {} },
        },
    }
    local layer = dungeon.layers[2]
    for y = 1, 4 do
        for x = 2, 6 do
            layer.grid[y * dungeon.width + x + 1] = 1
        end
    end

    Check(CurrentFloorCue.Bounds(dungeon, 0) == nil,
        "empty floor produced a current-floor cue")
    local bounds = CurrentFloorCue.Bounds(dungeon, 1)
    Check(bounds ~= nil, "occupied floor did not produce a current-floor cue")
    Check(math.abs(bounds.centerGridX - 4) < 0.000001
            and math.abs(bounds.centerGridY - 2.5) < 0.000001,
        "current-floor cue was not centered on occupied cells")
    Check(bounds.width > 5 and bounds.depth > 4,
        "current-floor cue did not include an outer visibility margin")

    local currentMarkers = CurrentFloorCue.CornerMarkers(bounds, "current")
    local neighborMarkers = CurrentFloorCue.CornerMarkers(bounds, "neighbors")
    Check(#currentMarkers == 12 and #neighborMarkers == 12,
        "current-floor cue did not create three markers for each corner")
    local kinds = { xLeg = 0, zLeg = 0, post = 0 }
    for _, marker in ipairs(currentMarkers) do kinds[marker.kind] = kinds[marker.kind] + 1 end
    Check(kinds.xLeg == 4 and kinds.zLeg == 4 and kinds.post == 4,
        "current-floor cue did not create four L markers and four posts")
    Check(neighborMarkers[3].sy > currentMarkers[3].sy,
        "multi-floor corner posts were not emphasized")
end

local function TestSingleFloor()
    local dungeon = DungeonGenerator.Generate({ seed = 9001, floorCount = 1, roomCount = 18 })
    CheckValid(dungeon, "single floor")
    Check(math.abs(dungeon.floorHeight - 5.0) < 0.000001,
        "generated dungeon floor height is not the unified 5.00m")
    Check(dungeon.floorHeight == MultiFloor.FLOOR_HEIGHT,
        "generated dungeon floor height diverged from MultiFloor.FLOOR_HEIGHT")
    Check(math.abs(MultiFloor.VERTICAL_SCALE - 1.0) < 0.000001,
        "5.00m baseline vertical scale is not 1.0")
    Check(#dungeon.connectors == 0, "single-floor dungeon created stair connectors")
end

local function TestMultiFloorSeeds()
    for seed = 1, 20 do
        local dungeon = DungeonGenerator.Generate({
            seed = seed * 7919,
            floorCount = 3,
            roomCountsByFloor = { 10, 10, 10 },
            loopRatesByFloor = { 0.12, 0.16, 0.2 },
        })
        CheckValid(dungeon, "multifloor seed " .. seed)
        Check(#dungeon.connectors >= dungeon.floorCount - 1,
            "multifloor seed " .. seed .. ": too few stair connectors")
        for _, connector in ipairs(dungeon.connectors) do
            Check(connector.toFloor == connector.fromFloor + 1,
                "connector skips a floor")
            Check(math.abs(connector.rise - MultiFloor.FLOOR_HEIGHT) < 0.000001,
                "connector rise diverged from the unified floor height")
            Check(math.abs(connector.stepRise * connector.stepCount - connector.rise) < 0.000001,
                "stair steps do not reach the next 5.00m floor")
            Check(connector.style == "straight" or connector.style == "l-turn",
                "connector has no supported stair style")
            Check((connector.style == "l-turn") == (connector.turn ~= nil),
                "connector style and turn geometry disagree")
            Check((connector.firstFlightSteps or 0) + (connector.secondFlightSteps or 0) == connector.stepCount,
                "stair flight step split does not match total step count")
            local lowerLayer = dungeon.layers[connector.fromFloor + 1]
            local upperLayer = dungeon.layers[connector.toFloor + 1]
            local lowerIndex = connector.lower.y * dungeon.width + connector.lower.x + 1
            local upperIndex = connector.upper.y * dungeon.width + connector.upper.x + 1
            Check(lowerLayer.stairLanding[lowerIndex] or lowerLayer.stairMask[lowerIndex],
                "lower stair endpoint is not reserved")
            Check(upperLayer.stairLanding[upperIndex] or upperLayer.stairMask[upperIndex],
                "upper stair endpoint is not reserved")
            Check(connector.audit and connector.audit.pass,
                "generated connector did not pass its per-stair spatial audit")
            for _, openingCell in ipairs(connector.openingCells) do
                Check(lowerLayer.stairMask[openingCell], "lower stair shaft is missing")
                Check(upperLayer.slabOpening[openingCell], "upper slab opening is missing")
            end
        end
    end
end

local function TestBeyondRecommendedFloorCount()
    local floorCount = MultiFloor.RECOMMENDED_MAX_FLOORS + 1
    local roomCounts = {}
    for floor = 1, floorCount do roomCounts[floor] = 6 end
    local dungeon = DungeonGenerator.Generate({
        seed = 2026072101,
        floorCount = floorCount,
        roomCountsByFloor = roomCounts,
    })
    CheckValid(dungeon, "beyond recommended floor count")
    Check(dungeon.floorCount == floorCount,
        "generator truncated a valid floor count to the six-floor recommendation")
    Check(#dungeon.connectors >= floorCount - 1,
        "dungeon above the recommended floor count is missing adjacent-floor connectors")
    for _, connector in ipairs(dungeon.connectors) do
        Check(connector.toFloor == connector.fromFloor + 1,
            "dungeon above the recommendation created a connector that skips a floor")
        Check(math.abs(connector.stepRise * connector.stepCount - dungeon.floorHeight) < 0.000001,
            "dungeon above the recommendation created a stair with the wrong rise")
    end
end

local function TestSixFloorShaftRegression()
    -- This seed once let an upper-floor A* route cross its own future shaft;
    -- cutting the slab then disconnected floors 3-6.
    local dungeon = DungeonGenerator.Generate({
        seed = 3394068386,
        floorCount = 6,
        roomCountsByFloor = { 8, 9, 10, 6, 7, 8 },
    })
    CheckValid(dungeon, "six-floor shaft regression")
    Check(#dungeon.connectors >= 5, "six-floor dungeon is missing required connectors")
end

local function PropSignature(dungeon)
    local values = {}
    for _, layer in ipairs(dungeon.layers) do
        for _, prop in ipairs(layer.props) do
            values[#values + 1] = string.format("%d:%s:%d:%d:%.4f:%.3f",
                layer.floor, prop.kind, prop.x, prop.y, prop.rot or 0, prop.scale or 1)
        end
        for _, spawn in ipairs(layer.spawns) do
            values[#values + 1] = string.format("%d:spawn%d:%d:%d",
                layer.floor, spawn.tier or 1, spawn.x, spawn.y)
        end
    end
    return table.concat(values, "|")
end

local function TestHospitalPropMigration()
    local options = {
        seed = 20260715, floorCount = 3, roomCount = 30,
        settingKey = "hospital", theme = "sterile",
        decorDensitiesByFloor = { 0.72, 0.72, 0.72 },
    }
    local a = DungeonGenerator.Generate(options)
    local b = DungeonGenerator.Generate(options)
    CheckValid(a, "hospital props")
    Check(PropSignature(a) == PropSignature(b), "hospital prop layout is not deterministic")

    local kinds, propCount = {}, 0
    for _, layer in ipairs(a.layers) do
        for _, prop in ipairs(layer.props) do
            kinds[prop.kind] = true
            propCount = propCount + 1
            Check(PropBlueprints.Get(prop.kind) ~= nil, "missing blueprint for " .. tostring(prop.kind))
        end
        for _, spawn in ipairs(layer.spawns) do
            Check(PropBlueprints.Get("spawn" .. tostring(spawn.tier)) ~= nil,
                "missing spawn blueprint tier " .. tostring(spawn.tier))
        end
    end
    Check(propCount >= 20, "hospital decor coverage is unexpectedly sparse")
    Check(kinds.hospitalBed or kinds.examTable, "hospital generated no clinical bed/table")
    Check(kinds.nurseCounter, "hospital entrance generated no nurse counter")
    Check(kinds.surgeryTable, "hospital boss room generated no surgery table")
    Check(kinds.wallLight or kinds.wallChart or kinds.hospitalSign, "hospital generated no wall fixtures")
    Check(kinds.floorStripe or kinds.floorArrow, "hospital generated no corridor markings")
end

local function TestDungeonPropBlueprintCoverage()
    for _, theme in ipairs({ "ancient", "molten", "frost", "grim", "verdant" }) do
        local dungeon = DungeonGenerator.Generate({
            seed = 88100 + #theme * 97, floorCount = 2, roomCount = 24,
            settingKey = "dungeon", theme = theme,
        })
        CheckValid(dungeon, "blueprint coverage " .. theme)
        for _, layer in ipairs(dungeon.layers) do
            for _, prop in ipairs(layer.props) do
                Check(PropBlueprints.Get(prop.kind) ~= nil,
                    string.format("theme %s has unsupported prop %s", theme, tostring(prop.kind)))
            end
        end
    end
end

local function TestSchoolThemePackStability()
    local pack = ThemePacks.Get("school")
    local validPack, packReason = ThemePacks.Validate(pack, nil, MaterialRules.PROFILES)
    Check(validPack, packReason)
    Check(pack.schemaVersion == ThemePacks.SCHEMA_VERSION and ThemePacks.SCHEMA_VERSION == 2,
        "school ThemePack was not migrated to the vertical-contract schema")
    Check(pack.verticalProfile.authoredFloorHeight == MultiFloor.SOURCE_FLOOR_HEIGHT
            and pack.verticalProfile.authoredVerticalScale == 1.0,
        "school ThemePack does not declare the shared 5m / 1.0 art baseline")
    local missingProfile = {}
    for key, value in pairs(pack) do missingProfile[key] = value end
    missingProfile.verticalProfile = nil
    local validMissing, missingReason = ThemePacks.Validate(missingProfile, nil, MaterialRules.PROFILES)
    Check(not validMissing and tostring(missingReason):find("vertical profile", 1, true) ~= nil,
        "ThemePack validation accepted a pack without the 5m vertical contract")
    local wrongBaseline = {}
    for key, value in pairs(pack) do wrongBaseline[key] = value end
    wrongBaseline.verticalProfile = {}
    for key, value in pairs(pack.verticalProfile) do wrongBaseline.verticalProfile[key] = value end
    wrongBaseline.verticalProfile.authoredFloorHeight = 4.0
    local validBaseline = ThemePacks.Validate(wrongBaseline, nil, MaterialRules.PROFILES)
    Check(not validBaseline, "ThemePack validation accepted the retired 4m baseline")
    local wrongScale = {}
    for key, value in pairs(pack) do wrongScale[key] = value end
    wrongScale.verticalProfile = {}
    for key, value in pairs(pack.verticalProfile) do wrongScale.verticalProfile[key] = value end
    wrongScale.verticalProfile.authoredVerticalScale = 1.25
    Check(not ThemePacks.Validate(wrongScale, nil, MaterialRules.PROFILES),
        "ThemePack validation accepted a non-1.0 authored scale")
    local badDoor = {}
    for key, value in pairs(pack) do badDoor[key] = value end
    badDoor.structure = {}
    for key, value in pairs(pack.structure) do badDoor.structure[key] = value end
    badDoor.structure.doorLintelBase = 2.58
    Check(not ThemePacks.Validate(badDoor, nil, MaterialRules.PROFILES),
        "ThemePack validation accepted a door frame above the minimum wall top")
    local badMount = {}
    for key, value in pairs(pack) do badMount[key] = value end
    badMount.props = {}
    for key, value in pairs(pack.props) do badMount.props[key] = value end
    badMount.props.schoolWallLight = {}
    for key, value in pairs(pack.props.schoolWallLight) do badMount.props.schoolWallLight[key] = value end
    badMount.props.schoolWallLight.height = 3.0
    Check(not ThemePacks.Validate(badMount, nil, MaterialRules.PROFILES),
        "ThemePack validation accepted a wall fixture above the minimum wall top")
    local brightProp = {}
    for key, value in pairs(pack) do brightProp[key] = value end
    brightProp.props = {}
    for key, value in pairs(pack.props) do brightProp.props[key] = value end
    brightProp.props.schoolClock = {}
    for key, value in pairs(pack.props.schoolClock) do brightProp.props.schoolClock[key] = value end
    brightProp.props.schoolClock.color = 0xf4f4f4
    local validBrightProp, brightPropReason = ThemePacks.Validate(brightProp, nil, MaterialRules.PROFILES)
    Check(not validBrightProp and tostring(brightPropReason):find("too bright", 1, true) ~= nil,
        "ThemePack validation accepted an over-bright non-emissive prop color")
    local falseFullHeight = {}
    for key, value in pairs(pack) do falseFullHeight[key] = value end
    falseFullHeight.verticalProfile = {}
    for key, value in pairs(pack.verticalProfile) do falseFullHeight.verticalProfile[key] = value end
    falseFullHeight.verticalProfile.wallMode = "full-height"
    Check(not ThemePacks.Validate(falseFullHeight, nil, MaterialRules.PROFILES),
        "ThemePack validation accepted a short partition as a 5m full-height wall")
    local falseFullHeightColumn = {}
    for key, value in pairs(pack) do falseFullHeightColumn[key] = value end
    falseFullHeightColumn.verticalProfile = {}
    for key, value in pairs(pack.verticalProfile) do
        falseFullHeightColumn.verticalProfile[key] = value
    end
    falseFullHeightColumn.verticalProfile.columnMode = "full-height"
    falseFullHeightColumn.structure = {}
    for key, value in pairs(pack.structure) do falseFullHeightColumn.structure[key] = value end
    falseFullHeightColumn.structure.columnHeight = 1.8
    Check(not ThemePacks.Validate(falseFullHeightColumn, nil, MaterialRules.PROFILES),
        "ThemePack validation accepted a short prop column as a 5m full-height column")
    Check(pack.spawnVisual and pack.spawnVisual.geometry == "schoolSpawnMarker",
        "school ThemePack has no school-specific spawn visual")
    local resolvedKey = ThemePacks.ResolvePrompt("现代校园教室、图书馆和实验室", "新学校", "dungeon")
    Check(resolvedKey == "school", "school prompt did not resolve to the school ThemePack")

    local deterministicOptions = {
        seed = 2026071501, floorCount = 1, roomCount = 30,
        settingKey = "school", theme = "schoolDay",
        decorDensitiesByFloor = { 0.72 },
    }
    local a = DungeonGenerator.Generate(deterministicOptions)
    local b = DungeonGenerator.Generate(deterministicOptions)
    CheckValid(a, "school deterministic A")
    CheckValid(b, "school deterministic B")
    Check(PropSignature(a) == PropSignature(b), "school prop layout is not deterministic")

    local coverage, totalProps, minimumProps = {}, 0, math.huge
    for seedIndex = 1, 12 do
        local dungeon = DungeonGenerator.Generate({
            seed = 73000 + seedIndex * 3571,
            floorCount = 1,
            roomCountsByFloor = { 28 },
            settingKey = "school", theme = pack.palettes[(seedIndex - 1) % #pack.palettes + 1],
            decorDensitiesByFloor = { 0.68 },
        })
        CheckValid(dungeon, "school stability seed " .. seedIndex)
        local seedProps = 0
        for _, layer in ipairs(dungeon.layers) do
            Check(#layer.torches == 0, "school seed generated dungeon torches")
            for _, prop in ipairs(layer.props) do
                seedProps = seedProps + 1
                coverage[prop.kind] = true
                Check(prop.kind ~= "debris" and prop.kind ~= "banner" and prop.kind ~= "grave"
                        and prop.kind ~= "roots" and prop.kind ~= "bones",
                    "school seed leaked dungeon prop " .. tostring(prop.kind))
                Check(PropBlueprints.Get(prop.kind) ~= nil,
                    "school ThemePack has no blueprint for " .. tostring(prop.kind))
            end
        end
        minimumProps = math.min(minimumProps, seedProps)
        totalProps = totalProps + seedProps
    end
    Check(minimumProps >= 20, "school ThemePack produced an unexpectedly sparse seed")
    Check(totalProps >= 360, "school ThemePack average prop coverage is too sparse")
    for _, kind in ipairs({ "schoolReception", "schoolStudentDesk", "schoolLabBench",
        "schoolBookshelf", "schoolStage", "schoolLocker", "schoolWallLight" }) do
        Check(coverage[kind], "school ThemePack never generated " .. kind)
    end
end

local function TestSchoolRequirementPlannerFlow()
    local pack = ThemePacks.Get("school")
    local topic = {
        id = "custom-school-flow", label = "学校", baseSettingKey = "school",
        prompt = "参考双点学校，生成教室、图书馆、实验室、食堂和大厅",
        packStatus = "ready",
    }
    local plan, reason = LocalRequirementPlanner.Compile(topic, pack, 7)
    Check(plan ~= nil, reason)
    Check(plan.schemaVersion == 1 and plan.source == LocalRequirementPlanner.SOURCE,
        "planner metadata is incomplete")
    Check(plan.verticalProfile.authoredFloorHeight == 5.0
            and plan.verticalProfile.floorHeight == 5.0
            and plan.verticalProfile.verticalScale == 1.0,
        "planner output does not carry the active 5m vertical profile")
    for _, group in ipairs(plan.roomGroups) do
        Check(group.prompt:find("5.00 米层高", 1, true) ~= nil
                and group.prompt:find("纵向比例 1.0", 1, true) ~= nil,
            "AI room prompt omitted the shared 5m vertical rule")
    end
    Check(#plan.roomGroups == 5, "school planner did not create five specific rooms")
    for _, room in ipairs(plan.roomGroups) do
        Check(room.ruleClass == "specific-room" and room.topicId == topic.id,
            "theme-generated space semantics were not marked as topic-specific room records")
    end
    local validGroups, groupReason = ThemePacks.ValidateRoomGroups(pack, plan.roomGroups)
    Check(validGroups, groupReason)

    topic.plannerSource = plan.source
    topic.compiledFromRevision = plan.compiledFromRevision
    topic.compiledSpecVersion = plan.schemaVersion
    topic.compiledRoomGroupCount = #plan.roomGroups
    local normalized = CustomizationStore.Normalize({
        customSettings = { topic }, roomGroups = plan.roomGroups,
        activeCustomSettingId = topic.id, revision = 7,
    })
    Check(#normalized.roomGroups == 5, "generated specific rooms were lost during save normalization")
    local topicRooms = LocalRequirementPlanner.GroupsForTopic(normalized.roomGroups, topic.id)
    Check(#topicRooms == 5, "generated specific rooms are not available to the topic-scoped room UI")
    Check(topicRooms[1].ruleClass == "specific-room",
        "specific-room classification was lost before the room UI could consume it")
    Check(normalized.roomGroups[1].topicId == topic.id and #normalized.roomGroups[1].propRules > 0,
        "compiled parent link or prop rules were lost")
    Check(normalized.customSettings[1].compiledRoomGroupCount == 5,
        "compiled topic metadata was lost")

    local options = {
        seed = 2026071601, floorCount = 1, roomCountsByFloor = { 28 },
        settingKey = "school", theme = "schoolDay", decorDensitiesByFloor = { 0.72 },
        roomGroups = normalized.roomGroups,
    }
    local a = DungeonGenerator.Generate(options)
    local b = DungeonGenerator.Generate(options)
    CheckValid(a, "planned school A")
    CheckValid(b, "planned school B")
    Check(PropSignature(a) == PropSignature(b), "planned school props are not deterministic")

    local assignmentA, assignmentB = {}, {}
    for _, room in ipairs(a.rooms) do assignmentA[#assignmentA + 1] = room.id .. ":" .. tostring(room.roomGroupId) end
    for _, room in ipairs(b.rooms) do assignmentB[#assignmentB + 1] = room.id .. ":" .. tostring(room.roomGroupId) end
    Check(table.concat(assignmentA, "|") == table.concat(assignmentB, "|"),
        "planned room assignments are not deterministic")

    local expectedProp = {
        ["generated-custom-school-flow-lobby"] = "schoolReception",
        ["generated-custom-school-flow-classroom"] = "schoolStudentDesk",
        ["generated-custom-school-flow-library"] = "schoolBookshelf",
        ["generated-custom-school-flow-laboratory"] = "schoolLabBench",
        ["generated-custom-school-flow-cafeteria"] = "schoolStage",
    }
    local roomGroupByRoom, seenGroup, seenRequiredProp = {}, {}, {}
    for _, room in ipairs(a.rooms) do
        Check(expectedProp[room.roomGroupId] ~= nil, "generated room has no planned room group")
        roomGroupByRoom[room.id] = room.roomGroupId
        seenGroup[room.roomGroupId] = true
    end
    for _, layer in ipairs(a.layers) do
        for _, prop in ipairs(layer.props) do
            local groupId = roomGroupByRoom[prop.roomId]
            if groupId and expectedProp[groupId] == prop.kind then seenRequiredProp[groupId] = true end
        end
    end
    for groupId in pairs(expectedProp) do
        Check(seenGroup[groupId], "planned group was not assigned: " .. groupId)
        Check(seenRequiredProp[groupId], "planned group rule was not executed: " .. groupId)
    end
end

local function TestBuiltinRoomRuleFlow()
    local valid, reason = BuiltinRoomRules.Validate()
    Check(valid, reason)

    local materialized, changed, mergeReason = LocalRequirementPlanner.EnsureBuiltinRoomGroups({
        { id = "manual-hospital-chapel", settingKey = "hospital", name = "临时祈祷室",
            prompt = "保留用户房间", source = "manual" },
    })
    Check(materialized ~= nil and changed, mergeReason)
    local hospitalRooms = LocalRequirementPlanner.GroupsForContext(materialized, nil, "hospital")
    local schoolRooms = LocalRequirementPlanner.GroupsForContext(materialized, nil, "school")
    Check(#hospitalRooms == 8, "hospital built-ins or manual room were not materialized")
    Check(#schoolRooms == 5, "school built-ins were not materialized")
    Check(#LocalRequirementPlanner.GroupsForContext(materialized, nil, "dungeon") == 0,
        "built-in hospital or school room leaked into dungeon")

    local foundManual, foundHospitalBed, foundClassroom = false, false, false
    for _, room in ipairs(hospitalRooms) do
        Check(room.topicId == nil and room.settingKey == "hospital", "hospital room has an invalid scope")
        if room.id == "manual-hospital-chapel" then foundManual = true end
        if room.id == "builtin-hospital-ward" then foundHospitalBed = true end
    end
    for _, room in ipairs(schoolRooms) do
        Check(room.topicId == nil and room.settingKey == "school", "school room has an invalid scope")
        if room.id == "builtin-school-classroom" then foundClassroom = true end
    end
    Check(foundManual and foundHospitalBed and foundClassroom,
        "materialized room identities are incomplete")

    local again, changedAgain = LocalRequirementPlanner.EnsureBuiltinRoomGroups(materialized)
    Check(not changedAgain and #again == #materialized, "built-in room materialization is not idempotent")

    local schoolRoomsBeforeManualEdit = LocalRequirementPlanner.GroupsForContext(materialized, nil, "school")
    local editedBuiltin = CustomizationStore.FindById(schoolRoomsBeforeManualEdit, "builtin-school-classroom")
    editedBuiltin.name = "多媒体教室"
    editedBuiltin.source = "manual"
    editedBuiltin.locked = true
    local afterManualEdit, changedAfterManualEdit = LocalRequirementPlanner.EnsureBuiltinRoomGroups(materialized)
    Check(not changedAfterManualEdit,
        "manually edited built-in room triggered a duplicate or replacement")
    local preservedEdit = CustomizationStore.FindById(afterManualEdit, "builtin-school-classroom")
    Check(preservedEdit and preservedEdit.name == "多媒体教室" and preservedEdit.source == "manual",
        "manual edit of a built-in room was overwritten")

    local normalized = CustomizationStore.Normalize({ roomGroups = afterManualEdit })
    local normalizedHospital = LocalRequirementPlanner.GroupsForContext(normalized.roomGroups, nil, "hospital")
    local normalizedSchool = LocalRequirementPlanner.GroupsForContext(normalized.roomGroups, nil, "school")
    Check(#normalizedHospital == 8 and #normalizedSchool == 5,
        "built-in room scopes were lost during persistence normalization")
    local preservedBuiltin = CustomizationStore.FindById(normalized.roomGroups, "builtin-hospital-ward")
    Check(preservedBuiltin and preservedBuiltin.source == "builtin",
        "built-in room lifecycle source was lost during normalization")

    local cases = {
        {
            settingKey = "hospital", theme = "sterile", rooms = normalizedHospital,
            expected = {
                ["builtin-hospital-reception"] = "nurseCounter",
                ["builtin-hospital-ward"] = "hospitalBed",
                ["builtin-hospital-nurse-station"] = "nurseCounter",
                ["builtin-hospital-examination"] = "examTable",
                ["builtin-hospital-mri"] = "mriScanner",
                ["builtin-hospital-surgery"] = "surgeryTable",
                ["builtin-hospital-isolation"] = "privacyCurtain",
            },
        },
        {
            settingKey = "school", theme = "schoolDay", rooms = normalizedSchool,
            expected = {
                ["builtin-school-lobby"] = "schoolReception",
                ["builtin-school-classroom"] = "schoolStudentDesk",
                ["builtin-school-library"] = "schoolBookshelf",
                ["builtin-school-laboratory"] = "schoolLabBench",
                ["builtin-school-cafeteria"] = "schoolStage",
            },
        },
    }
    for _, case in ipairs(cases) do
        local dungeon = DungeonGenerator.Generate({
            seed = 2026072201, floorCount = 1, roomCountsByFloor = { 32 },
            settingKey = case.settingKey, theme = case.theme,
            roomGroups = case.rooms, decorDensitiesByFloor = { 0.72 },
        })
        CheckValid(dungeon, "built-in " .. case.settingKey)
        local groupByRoom, seenGroup, seenProp = {}, {}, {}
        for _, room in ipairs(dungeon.rooms) do
            Check(case.expected[room.roomGroupId] ~= nil,
                case.settingKey .. " generated an unscoped room assignment")
            groupByRoom[room.id] = room.roomGroupId
            seenGroup[room.roomGroupId] = true
        end
        for _, layer in ipairs(dungeon.layers) do
            for _, prop in ipairs(layer.props) do
                local groupId = groupByRoom[prop.roomId]
                if groupId and case.expected[groupId] == prop.kind then seenProp[groupId] = true end
            end
        end
        for groupId in pairs(case.expected) do
            Check(seenGroup[groupId], case.settingKey .. " did not assign " .. groupId)
            Check(seenProp[groupId], case.settingKey .. " did not execute " .. groupId)
        end
    end
end

local function TestGenericThemeRuleFlow()
    local topic = {
        id = "custom-generic-flow", label = "深海研究站", baseSettingKey = "hospital",
        prompt = "海沟中的金属研究站和观景窗", packStatus = "ready",
        generationMode = "generic", floorHeight = 4.2,
    }
    local contract = GenericThemeRules.Resolve(topic.baseSettingKey)
    Check(contract.baseSettingKey == "hospital" and contract.roomDefinitionsOptional,
        "generic contract did not preserve the selected base system or optional-room rule")
    Check(contract.materialMode == "installed-pbr-profiles"
            and contract.aiAssetStatus == "not-connected",
        "generic contract does not accurately describe its installed material and AI asset state")
    Check(contract.modelGenerationRules.lengthUnit == "meter"
            and contract.modelGenerationRules.allowPlaceholder == false
            and contract.modelGenerationRules.exactCountsOwnedBy == "region",
        "generic contract does not expose the theme model-generation rules")
    Check(contract.colorRules.format == "#RRGGBB"
            and contract.colorRules.semanticRoles
            and #contract.colorRules.fields == #PaletteData.COLOR_FIELDS,
        "generic contract does not expose the semantic color rules")
    Check(contract.acceptanceRules.requireImportedModel
            and contract.acceptanceRules.requireColorPalette
            and contract.acceptanceRules.requireRenderedLuminanceCheck
            and contract.acceptanceRules.requireScaleInMeters
            and contract.acceptanceRules.requireStableAssetId
            and contract.acceptanceRules.requirePlacementCheck
            and contract.acceptanceRules.rejectBlockedOpenings,
        "generic contract does not expose the acceptance gate")
    local plan, reason = GenericThemeRules.Compile(topic, 9)
    Check(plan ~= nil, reason)
    Check(plan.generationMode == "generic" and plan.source == GenericThemeRules.SOURCE,
        "generic compile metadata is incomplete")
    Check(plan.baseSettingKey == "hospital" and #plan.roomGroups == 0,
        "generic compile changed the base system or invented room definitions")
    Check(plan.verticalProfile.floorHeight == 4.2
            and math.abs(plan.verticalProfile.verticalScale - 0.84) < 0.000001,
        "generic compile did not carry the configured floor height")
    Check(plan.modelGenerationRules and plan.colorRules and plan.acceptanceRules,
        "generic compile did not carry the generation, color and acceptance rules")

    local validRender = GenericThemeRules.ValidateRenderedLuminance({
        uiExcluded = true, meanLuminance = 0.46,
        blackPixelRatio = 0.03, whitePixelRatio = 0.01, emissiveCoverage = 0.02,
    })
    Check(validRender, "balanced rendered luminance was rejected")
    local darkRender, darkReason = GenericThemeRules.ValidateRenderedLuminance({
        uiExcluded = true, meanLuminance = 0.05,
        blackPixelRatio = 0.03, whitePixelRatio = 0.01, emissiveCoverage = 0.02,
    })
    Check(not darkRender and tostring(darkReason):find("too dark", 1, true) ~= nil,
        "over-dark rendered luminance was accepted")
    local brightRender, brightReason = GenericThemeRules.ValidateRenderedLuminance({
        uiExcluded = true, meanLuminance = 0.94,
        blackPixelRatio = 0.01, whitePixelRatio = 0.04, emissiveCoverage = 0.02,
    })
    Check(not brightRender and tostring(brightReason):find("too bright", 1, true) ~= nil,
        "over-bright rendered luminance was accepted")

    local incompleteContract = {}
    for key, value in pairs(contract) do incompleteContract[key] = value end
    incompleteContract.acceptanceRules = nil
    local validIncomplete, incompleteReason = GenericThemeRules.Validate(topic, incompleteContract)
    Check(not validIncomplete and tostring(incompleteReason):find("acceptance", 1, true) ~= nil,
        "generic validation accepted a contract without the acceptance gate")
end

local function TestConfigurableFloorHeight()
    local floorHeight = 4.2
    local dungeon = DungeonGenerator.Generate({
        seed = 2026072001, floorCount = 2, roomCount = 22,
        floorHeight = floorHeight, settingKey = "hospital", theme = "sterile",
    })
    CheckValid(dungeon, "configurable floor height")
    Check(math.abs(dungeon.floorHeight - floorHeight) < 0.000001,
        "dungeon did not retain the configured floor height")
    Check(dungeon.sceneInfo and math.abs(dungeon.sceneInfo.totalHeight - floorHeight * 2) < 0.000001,
        "scene information did not use the configured floor height")
    for _, connector in ipairs(dungeon.connectors) do
        Check(math.abs(connector.rise - floorHeight) < 0.000001,
            "stair rise did not follow the configured floor height")
        Check(math.abs(connector.stepRise * connector.stepCount - floorHeight) < 0.000001,
            "stair steps do not sum to the configured floor height")
    end
end

local function TestThreeParityContracts()
    local expected = {
        molten = "pools", frost = "lakes", grim = "graves", verdant = "roots",
    }
    for theme, feature in pairs(expected) do
        local dungeon = DungeonGenerator.Generate({
            seed = 24681357, floorCount = 1, roomCount = 30,
            settingKey = "dungeon", theme = theme, decorDensity = 0.7, loopRate = 0.25,
        })
        CheckValid(dungeon, "three parity " .. theme)
        local leaves, corridorEdges, archCount, featureCount = 0, 0, 0, 0
        for _, room in ipairs(dungeon.rooms) do if room.degree == 1 then leaves = leaves + 1 end end
        for _, edge in ipairs(dungeon.edges) do if edge.kind == "corridor" then corridorEdges = corridorEdges + 1 end end
        for _, layer in ipairs(dungeon.layers) do
            archCount = archCount + #layer.arches
            if feature == "pools" then featureCount = featureCount + #layer.pools
            elseif feature == "lakes" then featureCount = featureCount + #layer.lakeCells
            else
                for _, prop in ipairs(layer.props) do
                    if (feature == "graves" and prop.kind == "grave")
                        or (feature == "roots" and prop.kind == "roots") then featureCount = featureCount + 1 end
                end
            end
        end
        Check(leaves >= 3, theme .. ": loop insertion removed too many leaf rooms")
        Check(archCount == corridorEdges * 2,
            string.format("%s: expected two authored door frames per corridor, got %d for %d", theme, archCount, corridorEdges))
        Check(featureCount > 0, theme .. ": missing generated theme feature " .. feature)
    end
end

local function TestGeometrySeamContracts()
    local valid, reason = GeometryRules.Validate()
    Check(valid, reason)
    local verticalProfile = GeometryRules.CurrentVerticalProfile()
    Check(verticalProfile.authoredFloorHeight == 5.0
            and verticalProfile.floorHeight == 5.0
            and verticalProfile.verticalScale == 1.0,
        "general geometry rules are not using the 5m / 1.0 vertical profile")
    Check(GeometryRules.SEAM_EPSILON >= 0.002,
        "seam overlap is below the 2mm minimum")
    Check(GeometryRules.FloorSealSize() >= GeometryRules.CELL_SIZE + GeometryRules.SEAM_EPSILON * 2,
        "floor seal does not overlap both cell boundaries")
    Check(GeometryRules.FLOOR_SEAL_TOP < GeometryRules.FLOOR_Y_JITTER_MIN,
        "floor seal intrudes into the visible walking surface")
    Check(GeometryRules.FLOOR_SEAL_TOP
            >= GeometryRules.SHALLOW_FLOOR_BOTTOM + GeometryRules.FLOOR_Y_JITTER_MAX,
        "floor seal can separate from a jittered hospital tile")
    Check(GeometryRules.DUNGEON_FLOOR_BRICK_SIZE == GeometryRules.MIN_VISIBLE_FLOOR_SIZE,
        "dungeon brick size diverged from wall-floor overlap calculations")
    Check(GeometryRules.DungeonFloorBrickGap() >= GeometryRules.DUNGEON_FLOOR_BRICK_GAP_MIN
            and GeometryRules.DungeonFloorBrickGap() <= GeometryRules.DUNGEON_FLOOR_BRICK_GAP_MAX,
        "dungeon floor no longer has a readable brick joint")
    Check(math.abs(GeometryRules.DUNGEON_FLOOR_BRICK_CHAMFER - 0.030) < 0.000001,
        "dungeon floor brick chamfer must remain at the subtle 3cm profile")
    Check(GeometryRules.WallFloorHorizontalOverlap() >= GeometryRules.SEAM_EPSILON,
        "wall foot does not intersect the narrowest visible floor tile")
    Check(GeometryRules.WallFloorVerticalOverlap() >= GeometryRules.SEAM_EPSILON,
        "wall foot does not intersect the floor structural seal")
    local dungeonWallMin, dungeonWallMax = GeometryRules.WallHeightRange(MultiFloor.VERTICAL_SCALE, false)
    Check(math.abs(dungeonWallMin - 1.75) < 0.000001 and math.abs(dungeonWallMax - 2.25) < 0.000001,
        "dungeon walls diverged from their authored height at scale 1.0")
    local hospitalWallMin, hospitalWallMax = GeometryRules.WallHeightRange(MultiFloor.VERTICAL_SCALE, true)
    Check(math.abs(hospitalWallMin - 2.17) < 0.000001 and math.abs(hospitalWallMax - 2.33) < 0.000001,
        "hospital walls diverged from their authored height at scale 1.0")
    local schoolWallMin = (GeometryRules.SCHOOL_WALL_HEIGHT - GeometryRules.SCHOOL_WALL_HEIGHT_VARIATION)
        * MultiFloor.VERTICAL_SCALE
    local schoolWallMax = (GeometryRules.SCHOOL_WALL_HEIGHT + GeometryRules.SCHOOL_WALL_HEIGHT_VARIATION)
        * MultiFloor.VERTICAL_SCALE
    Check(math.abs(schoolWallMin - 2.51) < 0.000001 and math.abs(schoolWallMax - 2.59) < 0.000001,
        "school walls diverged from their authored height at scale 1.0")
end

local function TestMaterialSeparationContracts()
    local valid, reason = MaterialRules.Validate()
    Check(valid, reason)
    local profiles = MaterialRules.PROFILES
    local dungeonRoughnessGap = profiles.dungeonWall.roughness - profiles.dungeonFloor.roughness
    Check(dungeonRoughnessGap >= 0.12 and dungeonRoughnessGap <= 0.24,
        "dungeon stone bricks are not slightly smoother than their wall")
    local dungeonSpecularGap = profiles.dungeonFloor.specular - profiles.dungeonWall.specular
    Check(dungeonSpecularGap >= 0.12 and dungeonSpecularGap <= 0.24,
        "dungeon stone-brick reflection is not restrained")
    Check(profiles.dungeonFloor.roughness >= 0.68 and profiles.dungeonFloor.roughness <= 0.76
            and profiles.dungeonFloor.metalness <= 0.02,
        "dungeon floor no longer reads as rough non-metallic stone brick")
    local hospitalRoughnessGap = profiles.hospitalWall.roughness - profiles.hospitalFloor.roughness
    Check(hospitalRoughnessGap >= 0.15 and hospitalRoughnessGap <= 0.30,
        "hospital floor is not slightly smoother than its wall")
    local hospitalSpecularGap = profiles.hospitalFloor.specular - profiles.hospitalWall.specular
    Check(hospitalSpecularGap >= 0.15 and hospitalSpecularGap <= 0.35,
        "hospital floor reflection is not restrained")
    Check(profiles.dungeonCap.roughness >= 0.70 and profiles.dungeonCap.specular <= 0.35,
        "wall cap became glossier than the structural wall family")
    Check(profiles.schoolWall.roughness - profiles.schoolFloor.roughness >= 0.30,
        "school floor and painted wall no longer have distinct PBR response")
    Check(profiles.schoolTrim.metalness >= 0.50 and profiles.schoolWood.metalness <= 0.05,
        "school metal lockers and wooden furniture no longer read as different materials")
end

local function TestCustomizationNormalization()
    local data = CustomizationStore.Normalize({
        customSettings = {
            { id = "custom-4", label = "  Ice Temple  ", baseSettingKey = "hospital", prompt = "blue ice", packStatus = "draft" },
            { id = "custom-4", label = "duplicate id", baseSettingKey = "dungeon" },
            { id = "custom-8", label = "ice temple", baseSettingKey = "unknown" },
            { id = "custom-9", label = "Ruins", baseSettingKey = "unknown", floorHeight = 4.2,
                plannerSource = "generic-programmatic-v1" },
            { id = "", label = "invalid" },
        },
        roomGroups = {
            { id = "room-group-3", name = " Boss Room ", prompt = "arena" },
            { id = "room-group-7", name = "boss room", prompt = "duplicate name" },
            { id = "hospital-boss", settingKey = "hospital", name = "Boss Room", prompt = "hospital arena" },
        },
        customPalettes = {
            { id = "custom-palette-5", label = " Moon Violet ", baseSettingKey = "dungeon",
                basePaletteKey = "ancient", prompt = "moonlit violet stone",
                colors = {
                    floor = "#716D86", corridor = "#625E76", wall = "#504D63", pillar = "#5C5870",
                    accentObject = "#B45CFF", cloth = "#713B8F", flame = "#C07BFF", flameCore = "#F2DEFF",
                } },
            { id = "custom-palette-5", label = "duplicate palette", colors = {} },
            { id = "custom-palette-9", label = "moon violet", colors = {} },
        },
        nextCustomSettingId = 2,
        nextRoomGroupId = 1,
        nextCustomPaletteId = 2,
        activeCustomSettingId = "custom-4",
    })
    Check(#data.customSettings == 2, "customization normalization kept duplicate or invalid themes")
    Check(data.customSettings[1].label == "Ice Temple", "custom theme label was not trimmed")
    Check(data.customSettings[1].baseSettingKey == "hospital", "valid base setting was lost")
    Check(data.customSettings[1].packStatus == "draft", "draft ThemePack status was lost")
    Check(data.customSettings[2].packStatus == "ready", "legacy ThemePack did not migrate to ready")
    Check(data.customSettings[2].generationMode == "generic",
        "generic planner metadata did not migrate to generic generation mode")
    Check(data.customSettings[2].floorHeight == 4.2,
        "custom topic floor height was lost during normalization")
    Check(data.customSettings[2].baseSettingKey == "dungeon", "invalid base setting did not fall back")
    Check(data.nextCustomSettingId == 10, "next custom theme id was not repaired")
    Check(data.activeCustomSettingId == "custom-4", "valid active custom theme was cleared")
    Check(#data.roomGroups == 2 and data.nextRoomGroupId == 4,
        "room normalization did not deduplicate names by scope or repair ids")
    Check(data.roomGroups[1].settingKey == "dungeon",
        "legacy unscoped room did not migrate to the dungeon setting")
    Check(data.roomGroups[2].settingKey == "hospital",
        "base-setting room lost its hospital scope")
    local dungeonRooms = LocalRequirementPlanner.GroupsForContext(data.roomGroups, nil, "dungeon")
    local hospitalRooms = LocalRequirementPlanner.GroupsForContext(data.roomGroups, nil, "hospital")
    local schoolRooms = LocalRequirementPlanner.GroupsForContext(data.roomGroups, nil, "school")
    Check(#dungeonRooms == 1 and dungeonRooms[1].id == "room-group-3",
        "legacy Boss room escaped its migrated dungeon scope")
    Check(#hospitalRooms == 1 and hospitalRooms[1].id == "hospital-boss",
        "hospital-scoped room is not isolated to hospital")
    Check(#schoolRooms == 0, "dungeon or hospital room leaked into school")
    Check(#data.customPalettes == 1 and data.nextCustomPaletteId == 6,
        "custom palette normalization did not validate or repair ids")
    Check(data.customPalettes[1].colors.accentObject == 0xb45cff,
        "AI palette hex data was not normalized")

    local encoded = PaletteData.EncodeAIData(data.customPalettes[1].colors)
    local decoded = PaletteData.DecodeAIData(encoded)
    Check(decoded and decoded.flameCore == 0xf2deff, "AI palette JSON did not round-trip")
    Themes.SetCustomPalettes(data.customPalettes)
    local runtimePalette = Themes.Get("custom-palette-5")
    Check(Themes.IsPaletteForSetting("custom-palette-5", "dungeon"),
        "custom palette was not registered for its setting")
    Check(runtimePalette.wall == 0x504d63 and runtimePalette.fog == Themes.ancient.fog,
        "custom palette did not override model colors while preserving its base environment")
    Themes.SetCustomPalettes({})

    local missingActive = CustomizationStore.Normalize({
        customSettings = data.customSettings,
        activeCustomSettingId = "custom-404",
    })
    Check(missingActive.activeCustomSettingId == nil, "missing active custom theme was retained")

    local schoolData = CustomizationStore.Normalize({
        customSettings = { { id = "custom-12", label = "School", baseSettingKey = "school", prompt = "campus" } },
    })
    Check(schoolData.customSettings[1].baseSettingKey == "school", "school ThemePack was not persisted")

    local scopedNames = CustomizationStore.Normalize({
        roomGroups = {
            { id = "topic-a-lobby", topicId = "topic-a", name = "大厅", prompt = "A大厅" },
            { id = "topic-b-lobby", topicId = "topic-b", name = "大厅", prompt = "B大厅" },
        },
    })
    Check(#scopedNames.roomGroups == 2, "same room name was not scoped by parent topic")
    Check(#LocalRequirementPlanner.GroupsForContext(scopedNames.roomGroups, "topic-a", "dungeon") == 1,
        "topic A room is not visible in topic A")
    Check(#LocalRequirementPlanner.GroupsForContext(scopedNames.roomGroups, "topic-b", "dungeon") == 1,
        "topic B room is not visible in topic B")
    Check(#LocalRequirementPlanner.GroupsForContext(scopedNames.roomGroups, nil, "dungeon") == 0,
        "custom-topic room leaked into the base dungeon setting")
end

local function TestEditorRoomGroupPropagation()
    local dungeon = DungeonGenerator.Generate({
        seed = 71357,
        floorCount = 1,
        editorEnabled = true,
        editorRooms = {
            { cx = 12, cy = 14, w = 7, h = 7, floor = 0, roomGroupId = "room-group-7" },
            { cx = 26, cy = 14, w = 7, h = 7, floor = 0 },
        },
        editorEdges = {
            { a = 1, b = 2, isManual = true, width = 2 },
        },
        settingKey = "hospital",
        theme = "sterile",
    })
    CheckValid(dungeon, "editor room group propagation")
    Check(dungeon.rooms[1].roomGroupId == "room-group-7",
        "editor room group assignment was lost during generation")
    Check(dungeon.rooms[2].roomGroupId == nil,
        "unassigned editor room received a room group")
end

local function TestPinnedEditorStairContract()
    local dungeon = DungeonGenerator.Generate({
        seed = 7152026,
        floorCount = 2,
        editorEnabled = true,
        editorRooms = {
            { cx = 20, cy = 20, w = 24, h = 12, floor = 0, roleHint = "entrance" },
            { cx = 20, cy = 20, w = 24, h = 12, floor = 1, roleHint = "boss" },
        },
        editorEdges = {
            { a = 1, b = 2, kind = "stairs", isManual = true, width = 2,
                stairSpec = { id = "stair-test", mode = "locked", anchor = { x = 9, y = 20 },
                    direction = "east", width = 2, length = 10, landingDepth = 2 } },
        },
        settingKey = "hospital",
        theme = "sterile",
    })
    CheckValid(dungeon, "pinned editor stair")
    Check(#dungeon.connectors == 1, "pinned editor stair did not create one connector")
    local edge, connector = dungeon.edges[1], dungeon.connectors[1]
    Check(edge.stairSpec and edge.stairSpec.id == "stair-test", "stair identity was not preserved")
    Check(connector.direction == "east" and connector.length == 10 and connector.width == 2,
        "pinned stair dimensions or direction changed")
    Check(connector.lower.x == edge.stairSpec.anchor.x and connector.lower.y == edge.stairSpec.anchor.y,
        "pinned stair anchor changed during generation")
    Check(dungeon.editorOffset and connector.lower.x - dungeon.editorOffset.x == 9
        and connector.lower.y - dungeon.editorOffset.y == 20,
        "editor rebase offset did not preserve the pinned stair's authored position")
    Check(connector.mode == "locked" and connector.candidateCount == 1,
        "pinned stair mode or candidate contract was not preserved")
    local platform = MultiFloor.StairTurnPlatformMetrics(connector)
    Check(platform ~= nil, "pinned L stair has no turn platform metrics")
    Check(math.abs(platform.first.start.y - (connector.lower.y + 0.5)) < 0.000001,
        "even-width stair first flight is not centered on its authored strip")
    Check(math.abs(platform.center.x - (connector.lower.x + 6)) < 0.000001
        and math.abs(platform.center.y - (connector.lower.y + 0.5)) < 0.000001,
        "L stair platform is still centered on the old turn anchor")
    Check(connector.upper.x == connector.lower.x + 6 and connector.upper.y == connector.lower.y + 7,
        "upper stair socket does not match the rendered second-flight endpoint")
end

local function TestPendingEditorStairPreview()
    local dungeon = DungeonGenerator.Generate({
        seed = 7152027,
        floorCount = 2,
        editorEnabled = true,
        editorRooms = {
            { cx = 20, cy = 20, w = 20, h = 16, floor = 0, roleHint = "entrance" },
            { cx = 20, cy = 20, w = 20, h = 16, floor = 1, roleHint = "boss" },
        },
        editorEdges = {
            { a = 1, b = 2, kind = "stairs", isManual = true,
                stairSpec = { id = "stair-preview", mode = "stable-auto", pending = true, width = 2 } },
        },
        settingKey = "hospital",
        theme = "sterile",
    })
    CheckValid(dungeon, "pending editor stair")
    local spec = dungeon.edges[1].stairSpec
    Check(spec and spec.pending and spec.anchor == nil and spec.previewAnchor ~= nil,
        "pending stair was committed instead of returned as a preview")
    Check(spec.previewDirection ~= nil and spec.previewLength ~= nil and spec.candidateCount > 0,
        "pending stair preview did not include a legal candidate")
end

function GenerationTests.Run()
    local tests = {
        { "random determinism", TestRandomDeterminism },
        { "stair metre width", TestStairWidthMetreGrid },
        { "stair headroom contract", TestStairContractHeadroomAndProtection },
        { "route turn penalty", TestRouteTurnPenalty },
        { "dungeon determinism", TestDungeonDeterminism },
        { "floor setting isolation", TestFloorSettingIsolation },
        { "current floor cue bounds", TestCurrentFloorCueBounds },
        { "single floor", TestSingleFloor },
        { "20 multifloor seeds", TestMultiFloorSeeds },
        { "beyond recommended floors", TestBeyondRecommendedFloorCount },
        { "six-floor shaft regression", TestSixFloorShaftRegression },
        { "hospital prop migration", TestHospitalPropMigration },
        { "dungeon prop blueprints", TestDungeonPropBlueprintCoverage },
        { "school ThemePack stability", TestSchoolThemePackStability },
        { "school AI requirement flow", TestSchoolRequirementPlannerFlow },
        { "built-in room rule flow", TestBuiltinRoomRuleFlow },
        { "generic theme rule flow", TestGenericThemeRuleFlow },
        { "configurable floor height", TestConfigurableFloorHeight },
        { "three parity contracts", TestThreeParityContracts },
        { "geometry seam contracts", TestGeometrySeamContracts },
        { "material separation", TestMaterialSeparationContracts },
        { "customization normalization", TestCustomizationNormalization },
        { "editor room groups", TestEditorRoomGroupPropagation },
        { "pinned editor stair", TestPinnedEditorStairContract },
        { "pending stair preview", TestPendingEditorStairPreview },
    }
    local started = os.clock()
    for _, test in ipairs(tests) do
        local testStarted = os.clock()
        test[2]()
        print(string.format("[test] PASS %-24s %.3fs", test[1], os.clock() - testStarted))
    end
    print(string.format("[test] PASS all %d suites in %.3fs", #tests, os.clock() - started))
    return true
end

function GenerationTests.RunSchool()
    local started = os.clock()
    TestSchoolThemePackStability()
    TestSchoolRequirementPlannerFlow()
    print(string.format("[test] PASS school ThemePack + requirement flow %.3fs", os.clock() - started))
    return true
end

function GenerationTests.RunBuiltinRooms()
    local started = os.clock()
    TestBuiltinRoomRuleFlow()
    print(string.format("[test] PASS built-in hospital + school room flow %.3fs", os.clock() - started))
    return true
end

function GenerationTests.RunCustomization()
    local started = os.clock()
    TestCustomizationNormalization()
    print(string.format("[test] PASS customization draft migration %.3fs", os.clock() - started))
    return true
end

return GenerationTests
