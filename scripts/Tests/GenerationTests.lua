local Random = require("Generation.Random")
local DungeonGenerator = require("Generation.DungeonGenerator")
local MultiFloor = require("Generation.MultiFloor")
local StairContract = require("Generation.StairContract")
local DoorContract = require("Generation.DoorContract")
local GeometryRules = require("Generation.GeometryRules")
local MaterialRules = require("Rendering.ProceduralMaterialRules")
local ThemeToneRules = require("Rendering.ThemeToneRules")
local EnvironmentProfiles = require("Config.EnvironmentProfiles")
local AtmosphereProfiles = require("Config.AtmosphereProfiles")
local PropBlueprints = require("Rendering.PropBlueprints")
local DungeonGeometry = require("Rendering.DungeonGeometryLibrary")
local CustomizationStore = require("Config.CustomizationStore")
local ThemePacks = require("Config.ThemePacks")
local GenericThemeRules = require("Config.GenericThemeRules")
local PaletteData = require("Config.PaletteData")
local Themes = require("Config.Themes")
local BuiltinRoomRules = require("Config.BuiltinRoomRules")
local TopicSeeds = require("Config.TopicSeeds")
local LocalRequirementPlanner = require("AI.LocalRequirementPlanner")
local PaletteAIProvider = require("AI.PaletteAIProvider")

local GenerationTests = {}

local function Check(condition, message)
    if not condition then error(message or "check failed", 2) end
end

local function CheckValid(dungeon, label)
    Check(dungeon ~= nil, label .. ": generator returned nil")
    Check(dungeon.valid, label .. ": " .. table.concat(dungeon.errors or {}, "; "))
    for _, room in ipairs(dungeon.rooms) do
        local layer = dungeon.layers[room.floor + 1]
        local accessCell = nil
        for cell, roomId in ipairs(layer.roomId or {}) do
            if roomId == room.id and layer.bfs[cell] and layer.bfs[cell] >= 0 then
                accessCell = cell
                break
            end
        end
        Check(accessCell ~= nil,
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
        run = 9, width = 1, landingDepth = 2,
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
            local elevationsByCell = {}
            local minElevation, maxElevation = math.huge, -math.huge
            for _, item in ipairs(connector.sweptClearanceCells or {}) do
                elevationsByCell[item.cell] = item
                minElevation = math.min(minElevation, item.treadElevation)
                maxElevation = math.max(maxElevation, item.treadElevation)
                Check(item.treadElevation >= -StairContract.EPSILON
                        and item.treadElevation <= connector.rise + StairContract.EPSILON,
                    "stair tread elevation escaped connector rise")
            end
            Check(minElevation >= -StairContract.EPSILON and maxElevation <= connector.rise + StairContract.EPSILON,
                "stair swept clearance has no valid elevation range")
            for _, openingCell in ipairs(connector.openingCells) do
                Check(lowerLayer.stairMask[openingCell], "lower stair shaft is missing")
                Check(upperLayer.slabOpening[openingCell], "upper slab opening is missing")
                Check(elevationsByCell[openingCell]
                        and elevationsByCell[openingCell].intersectsUpperSlab,
                    "upper opening is not backed by a swept tread record")
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

local function TestWallLightShapeContract()
    local geometry = DungeonGeometry.GEO.wallLight
    Check(geometry and geometry.count > 0, "wallLight geometry is missing")

    local blueprint = PropBlueprints.Get("wallLight")
    Check(blueprint and blueprint.mount == "wall", "wallLight blueprint lost its wall mount")
    local parts = {}
    for _, part in ipairs(blueprint.parts) do parts[part.model] = true end
    Check(parts.roundedBox and parts.cylinder and parts.torus and parts.disc,
        "wallLight blueprint did not keep the backplate, round head, rim and lens")

    local schoolBlueprint = PropBlueprints.Get("schoolWallLight")
    Check(schoolBlueprint and schoolBlueprint.mount == "wall"
            and #schoolBlueprint.parts == #blueprint.parts,
        "school wall light did not keep the redesigned silhouette")

    local pack = ThemePacks.Get("school")
    Check(pack.props.schoolWallLight.geometry == "wallLight"
            and pack.props.schoolWallLight.material == "glow"
            and pack.props.schoolWallLight.emitsLight == true,
        "school wall light contract no longer targets the emissive wallLight geometry")
end

local TEMPLE_SET_PIECES = {
    obelisk = true, guardianStatue = true, crystalCluster = true,
    archRuin = true, brokenPillar = true, templeBanner = true,
    templeMedallion = true, templeUrn = true, goldPile = true, pathRune = true,
}

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
                -- The showcase kit belongs to 神殿遗迹 only; the plain ruins
                -- setting must keep its original dressing.
                Check(not TEMPLE_SET_PIECES[prop.kind],
                    string.format("dungeon leaked temple set piece %s", tostring(prop.kind)))
            end
        end
    end
end

local function TestTempleSettingCoverage()
    local seen = {}
    for _, theme in ipairs({ "templeGold", "templeMagma", "templeFrost", "templeGrim", "templeVine" }) do
        local dungeon = DungeonGenerator.Generate({
            seed = 90100 + #theme * 131, floorCount = 2, roomCount = 24,
            settingKey = "temple", theme = theme,
        })
        CheckValid(dungeon, "temple coverage " .. theme)
        for _, layer in ipairs(dungeon.layers) do
            for _, prop in ipairs(layer.props) do
                seen[prop.kind] = true
                Check(PropBlueprints.Get(prop.kind) ~= nil,
                    string.format("temple theme %s has unsupported prop %s", theme, tostring(prop.kind)))
            end
        end
        local resolved = Themes.Resolve("temple", theme)
        Check(resolved.bloom == true, "temple palette " .. theme .. " must enable bloom")
        Check(type(resolved.fx) == "table", "temple palette " .. theme .. " is missing fx data")
        Check(type(resolved.fx.emissiveScale) == "number" and resolved.fx.emissiveScale < 0.6,
            "temple palette " .. theme .. " emissive budget is too high")
        Check(type(resolved.particles) == "table" and (resolved.particles.n or 0) > 0,
            "temple palette " .. theme .. " is missing its particle field")
    end
    for kind in pairs(TEMPLE_SET_PIECES) do
        Check(seen[kind], "temple setting never generated set piece " .. kind)
    end
    local profile = EnvironmentProfiles.Resolve("temple")
    Check(type(profile.atmosphere) == "table" and type(profile.structureRuin) == "table",
        "temple profile is missing its showcase layers")
    Check(type(profile.atmosphere.volumetricFog) == "table"
            and profile.atmosphere.volumetricFog.gridSizeZ >= 64
            and profile.atmosphere.volumetricFog.localVolumeExtinction > 0,
        "temple profile is missing real volumetric fog tuning")
    Check(profile.structure.wallHeight >= 2.8
            and profile.structure.doorLintelBase > 2.0
            and profile.structure.torchMountHeight > 1.5,
        "temple walls, door frames and lanterns did not rise with the taller hall")
    Check(profile.structure.floorInlay.material == "gild"
            and profile.spawnVisual.material == "gild",
        "temple floor matrix and spawn markers must use non-emissive gilt")
    Check(type(profile.floorScatter.group) == "table"
            and profile.floorScatter.group.memberMin >= 2
            and profile.floorScatter.group.memberMax >= profile.floorScatter.group.memberMin,
        "temple floor clutter must use irregular groups")
    Check(type(profile.denseRoomChance) == "number"
            and profile.denseRoomChance > 0.05 and profile.denseRoomChance < 0.25,
        "temple dense-room ratio must remain a sparse minority")
    Check(profile.atmosphere.runeCircles.roomTypes.boss
            and not profile.atmosphere.runeCircles.roomTypes.shrine,
        "temple shrine floor must not receive a second emissive rune circle")
    Check(DungeonGeometry.GEO.templeCarpet and DungeonGeometry.GEO.templeCarpetBorder
            and DungeonGeometry.GEO.templeCarpetStripe,
        "temple color richness kit is missing carpet geometry")
    for _, paletteKey in ipairs({ "templeGold", "templeMagma", "templeFrost", "templeGrim", "templeVine" }) do
        Check(type(Themes.Get(paletteKey).clothAccent) == "number",
            "temple palette is missing a fabric accent color: " .. paletteKey)
    end
    local dungeonAtmosphere = EnvironmentProfiles.Resolve("dungeon").atmosphere
    Check(type(dungeonAtmosphere) == "table"
            and type(dungeonAtmosphere.particles) == "table"
            and type(dungeonAtmosphere.pulse) == "table",
        "plain dungeon lost its dust-and-firelight atmosphere layer")
    Check(dungeonAtmosphere.godRays == nil and dungeonAtmosphere.runeCircles == nil
            and dungeonAtmosphere.animatedProps == nil and dungeonAtmosphere.volumetricFog == nil,
        "plain dungeon atmosphere must stay a dust layer, not clone the temple miracles")
    Check(dungeonAtmosphere.particles.perFloorCap <= profile.atmosphere.particles.perFloorCap
            and dungeonAtmosphere.particles.totalCap <= profile.atmosphere.particles.totalCap,
        "plain dungeon particle budget must stay at or below the temple showcase budget")
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
    local hospitalTopicId = TopicSeeds.IdForSetting("hospital")
    local schoolTopicId = TopicSeeds.IdForSetting("school")
    local templeTopicId = TopicSeeds.IdForSetting("temple")
    local hospitalRooms = LocalRequirementPlanner.GroupsForTopic(materialized, hospitalTopicId)
    local schoolRooms = LocalRequirementPlanner.GroupsForTopic(materialized, schoolTopicId)
    local templeRooms = LocalRequirementPlanner.GroupsForTopic(materialized, templeTopicId)
    Check(#hospitalRooms == 8, "hospital seed rooms or manual room were not materialized")
    Check(#schoolRooms == 5, "school seed rooms were not materialized")
    Check(#templeRooms == 6, "temple signature rooms were not materialized")
    Check(#LocalRequirementPlanner.GroupsForTopic(materialized, TopicSeeds.IdForSetting("dungeon")) == 0,
        "hospital, school or temple seed room leaked into dungeon")
    local shrineSeed = CustomizationStore.FindById(templeRooms, "seed-temple-rune-sanctum")
    Check(shrineSeed and shrineSeed.propRules[2].layout == "ring"
            and shrineSeed.propRules[2].radius == 3,
        "temple structured room layout was not materialized")
    local processionalVariants = BuiltinRoomRules.VisualVariants(
        "temple", "seed-temple-processional-ruin")
    Check(processionalVariants and #processionalVariants == 3,
        "temple processional rooms did not expose distinct visual variants")
    for _, variant in ipairs(processionalVariants or {}) do
        local hasPillar = false
        for _, rule in ipairs(variant) do if rule.kind == "pillar" then hasPillar = true end end
        Check(hasPillar, "temple visual variant lost its common pillar grammar")
    end

    local foundManual, foundHospitalBed, foundClassroom = false, false, false
    for _, room in ipairs(hospitalRooms) do
        Check(room.topicId == hospitalTopicId and room.settingKey == nil, "hospital room has an invalid scope")
        if room.id == "manual-hospital-chapel" then foundManual = true end
        if room.id == "seed-hospital-ward" then foundHospitalBed = true end
    end
    for _, room in ipairs(schoolRooms) do
        Check(room.topicId == schoolTopicId and room.settingKey == nil, "school room has an invalid scope")
        if room.id == "seed-school-classroom" then foundClassroom = true end
    end
    Check(foundManual and foundHospitalBed and foundClassroom,
        "materialized room identities are incomplete")

    local again, changedAgain = LocalRequirementPlanner.EnsureBuiltinRoomGroups(materialized)
    Check(not changedAgain and #again == #materialized, "seed room materialization is not idempotent")

    local schoolRoomsBeforeManualEdit = LocalRequirementPlanner.GroupsForTopic(materialized, schoolTopicId)
    local editedBuiltin = CustomizationStore.FindById(schoolRoomsBeforeManualEdit, "seed-school-classroom")
    editedBuiltin.name = "多媒体教室"
    editedBuiltin.source = "manual"
    editedBuiltin.locked = true
    local afterManualEdit, changedAfterManualEdit = LocalRequirementPlanner.EnsureBuiltinRoomGroups(materialized)
    Check(not changedAfterManualEdit,
        "manually edited seed room triggered a duplicate or replacement")
    local preservedEdit = CustomizationStore.FindById(afterManualEdit, "seed-school-classroom")
    Check(preservedEdit and preservedEdit.name == "多媒体教室" and preservedEdit.source == "manual",
        "manual edit of a seed room was overwritten")

    local normalized = CustomizationStore.Normalize({ roomGroups = afterManualEdit })
    local normalizedHospital = LocalRequirementPlanner.GroupsForTopic(normalized.roomGroups, hospitalTopicId)
    local normalizedSchool = LocalRequirementPlanner.GroupsForTopic(normalized.roomGroups, schoolTopicId)
    local normalizedTemple = LocalRequirementPlanner.GroupsForTopic(normalized.roomGroups, templeTopicId)
    Check(#normalizedHospital == 8 and #normalizedSchool == 5 and #normalizedTemple == 6,
        "seed room scopes were lost during persistence normalization")
    local normalizedShrine = CustomizationStore.FindById(normalizedTemple, "seed-temple-rune-sanctum")
    Check(normalizedShrine and normalizedShrine.propRules[2].layout == "ring"
            and normalizedShrine.propRules[2].radius == 3,
        "temple structured layout fields were lost during persistence normalization")
    local preservedBuiltin = CustomizationStore.FindById(normalized.roomGroups, "seed-hospital-ward")
    Check(preservedBuiltin and preservedBuiltin.source == "seed",
        "seed room lifecycle source was lost during normalization")

    local cases = {
        {
            settingKey = "hospital", theme = "sterile", rooms = normalizedHospital,
            expected = {
                ["seed-hospital-reception"] = "nurseCounter",
                ["seed-hospital-ward"] = "hospitalBed",
                ["seed-hospital-nurse-station"] = "nurseCounter",
                ["seed-hospital-examination"] = "examTable",
                ["seed-hospital-mri"] = "mriScanner",
                ["seed-hospital-surgery"] = "surgeryTable",
                ["seed-hospital-isolation"] = "privacyCurtain",
            },
        },
        {
            settingKey = "school", theme = "schoolDay", rooms = normalizedSchool,
            expected = {
                ["seed-school-lobby"] = "schoolReception",
                ["seed-school-classroom"] = "schoolStudentDesk",
                ["seed-school-library"] = "schoolBookshelf",
                ["seed-school-laboratory"] = "schoolLabBench",
                ["seed-school-cafeteria"] = "schoolStage",
            },
        },
        {
            settingKey = "temple", theme = "templeGold", rooms = normalizedTemple,
            expected = {
                ["seed-temple-pilgrimage-gate"] = "ring",
                ["seed-temple-rune-sanctum"] = "shrineCrystal",
                ["seed-temple-astral-gallery"] = "obelisk",
                ["seed-temple-relic-vault"] = "chest",
                ["seed-temple-guardian-seat"] = "guardianStatue",
                ["seed-temple-processional-ruin"] = "pillar",
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

local function CreateDoorTestLayer(width, height, room)
    local layer = {
        grid = {}, roomId = {}, corridor = {}, doorway = {},
        stairMask = {}, stairWallMask = {}, stairClearance = {}, stairLanding = {}, slabOpening = {},
    }
    for cell = 1, width * height do
        layer.grid[cell], layer.roomId[cell] = MultiFloor.Tiles.VOID, 0
    end
    local x0 = math.ceil(room.cx - room.w * 0.5)
    local x1 = math.floor(room.cx + room.w * 0.5)
    local y0 = math.ceil(room.cy - room.h * 0.5)
    local y1 = math.floor(room.cy + room.h * 0.5)
    for y = y0, y1 do
        for x = x0, x1 do
            local cell = y * width + x + 1
            layer.grid[cell], layer.roomId[cell] = MultiFloor.Tiles.FLOOR, room.id
        end
    end
    return layer
end

local function TestDoorContract()
    local width, height = 32, 24
    local room = { id = 1, cx = 6, cy = 6, w = 5, h = 5, floor = 0 }
    local other = { cx = 18, cy = 6 }
    local layer = CreateDoorTestLayer(width, height, room)
    local defaultPoint = DoorContract.RoomDoorPoint(room, other, 0)
    local resolved = DoorContract.ResolveWallDoor(layer, width, height, room,
        defaultPoint, defaultPoint, 3, true)
    Check(resolved and resolved.side == "east" and resolved.x == 8 and resolved.y == 6,
        "default door did not resolve to the real east wall")
    local approach = DoorContract.DoorApproach(resolved)
    Check(approach.x == 10 and approach.y == 6,
        "door approach did not extend along the wall normal")

    DoorContract.MarkDoor(layer, width, height, resolved, 3)
    for _, y in ipairs({ 5, 6, 7 }) do
        Check(layer.doorway[y * width + 8 + 1], "wide door did not mark its full tangent span")
    end
    local arch = DoorContract.BuildArch(layer, width, height, room, resolved, 3)
    Check(arch and arch.x == 8 and arch.y == 6
            and math.abs(arch.interfaceX - 8.5) < 0.000001
            and math.abs(arch.interfaceY - 6) < 0.000001,
        "door arch did not use the resolved wall interface")

    local cornerRoom = { id = 2, cx = 6, cy = 6, w = 5, h = 1, floor = 0 }
    local cornerLayer = CreateDoorTestLayer(width, height, cornerRoom)
    local cornerDoor = DoorContract.ResolveWallDoor(cornerLayer, width, height, cornerRoom,
        { x = 8, y = 6, side = "east" }, { x = 8, y = 6, side = "east" }, 1, false)
    Check(not cornerDoor, "door was generated without wall support on both frame sides")

    local blocked = CreateDoorTestLayer(width, height, room)
    for y = 4, 8 do
        for x = 9, 10 do blocked.grid[y * width + x + 1] = MultiFloor.Tiles.WALL end
    end
    local rejected = DoorContract.ResolveWallDoor(blocked, width, height, room,
        { x = 8, y = 6, side = "east" }, { x = 8, y = 6, side = "east" }, 2, false)
    Check(not rejected, "blocked custom door silently changed or accepted its wall")
    local fallback = DoorContract.ResolveWallDoor(blocked, width, height, room,
        { x = 8, y = 6, side = "east" }, { x = 8, y = 6, side = "east" }, 2, true)
    Check(fallback and fallback.side ~= "east",
        "automatic door did not fall back to another legal wall")
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
        local leaves, corridorEdges, archCount, droppedArches, featureCount = 0, 0, 0, 0, 0
        for _, room in ipairs(dungeon.rooms) do if room.degree == 1 then leaves = leaves + 1 end end
        for _, edge in ipairs(dungeon.edges) do if edge.kind == "corridor" then corridorEdges = corridorEdges + 1 end end
        for _, layer in ipairs(dungeon.layers) do
            archCount = archCount + #layer.arches
            droppedArches = droppedArches + (layer.droppedArches or 0)
            for _, arch in ipairs(layer.arches) do
                Check(arch.interfaceX ~= nil and arch.interfaceY ~= nil
                        and arch.anchorX ~= nil and arch.anchorY ~= nil,
                    theme .. ": generated arch is missing the generic wall interface")
            end
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
        -- Every corridor still owns two door slots, but a frame renders only
        -- when the final wall grid supports both posts; unsupported frames are
        -- dropped and must remain a small minority.
        Check(archCount + droppedArches == corridorEdges * 2,
            string.format("%s: expected two door slots per corridor, got %d + %d for %d",
                theme, archCount, droppedArches, corridorEdges))
        Check(droppedArches * 4 <= corridorEdges * 2,
            string.format("%s: too many floating door frames were dropped (%d of %d)",
                theme, droppedArches, corridorEdges * 2))
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

local function ColorStrength(color)
    return ((color >> 16) & 0xff) + ((color >> 8) & 0xff) + (color & 0xff)
end

local function ColorDistance(a, b)
    return math.abs(((a >> 16) & 0xff) - ((b >> 16) & 0xff))
        + math.abs(((a >> 8) & 0xff) - ((b >> 8) & 0xff))
        + math.abs((a & 0xff) - (b & 0xff))
end

local function TestThemeToneContracts()
    local valid, reason = ThemeToneRules.Validate()
    Check(valid, reason)
    local cases = {
        { setting = "dungeon", theme = "ancient" },
        { setting = "hospital", theme = "sterile" },
        { setting = "school", theme = "schoolDay" },
    }
    for _, item in ipairs(cases) do
        local theme = Themes.Get(item.theme)
        local tone = EnvironmentProfiles.Resolve(item.setting).structureTone
        local baseFloor = theme.floor
        local plain = ThemeToneRules.ResolveFloorColor(theme, tone, {
            walls8 = 0, checker = false,
        })
        local corridorBase = theme.corridor
        local corridor = ThemeToneRules.ResolveFloorColor(theme, tone, {
            corridor = true, walls8 = 0, checker = false,
        })
        local doorway = ThemeToneRules.ResolveFloorColor(theme, tone, {
            walls8 = 0, checker = false, isDoorway = true,
        })
        local edge = ThemeToneRules.ResolveFloorColor(theme, tone, {
            walls8 = tone.edgeDarkenMaxWalls, checker = false,
        })
        local role = ThemeToneRules.ResolveFloorColor(theme, tone, {
            walls8 = 0, checker = false, room = { type = "boss" },
        })
        local visibilityDelta = ColorDistance(plain, baseFloor)
        local corridorDelta = ColorDistance(corridor, corridorBase)
        if item.setting == "dungeon" then
            Check(visibilityDelta == 0 and corridorDelta == 0,
                item.setting .. ": ruins palette changed unexpectedly before tone rules")
        else
            Check(visibilityDelta >= 4 and corridorDelta >= 4,
                string.format("%s: palette visibility modulation is too weak floor=%d corridor=%d",
                    item.setting, visibilityDelta, corridorDelta))
        end
        Check(ColorStrength(doorway) > ColorStrength(plain),
            item.setting .. ": doorway tone did not brighten the floor")
        Check(ColorStrength(edge) < ColorStrength(plain),
            item.setting .. ": wall-edge tone did not darken the floor")
        Check(role ~= plain, item.setting .. ": room semantic tint did not affect the floor")

        local wall = ThemeToneRules.ResolveWallColor(theme, tone)
        local cap = ThemeToneRules.ResolveCapColor(theme, tone)
        if item.setting ~= "dungeon" then
            Check(ColorDistance(wall, theme.wall) >= 4,
                item.setting .. ": wall palette visibility modulation is too weak")
            Check(ColorDistance(cap, theme.cap) >= 4,
                item.setting .. ": cap palette visibility modulation is too weak")
        end

        local stableA = ThemeToneRules.ResolveFloorColor(theme, tone, {
            walls8 = 1, checker = true, room = { type = "elite" }, rng = Random.new(9917),
        })
        local stableB = ThemeToneRules.ResolveFloorColor(theme, tone, {
            walls8 = 1, checker = true, room = { type = "elite" }, rng = Random.new(9917),
        })
        Check(stableA == stableB, item.setting .. ": tone variation is not deterministic")
        Check(ThemeToneRules.ResolveWallColor(theme, tone, Random.new(3)) ~= nil,
            item.setting .. ": wall tone did not resolve")
        Check(ThemeToneRules.ResolveCapColor(theme, tone, Random.new(3)) ~= nil,
            item.setting .. ": cap tone did not resolve")
    end
end

local function TestThemeQualityProfiles()
    local cases = {
        { setting = "dungeon", theme = "ancient", required = { "floorScatter", "emphasis", "wallFixtures", "ambientClutter", "atmosphere" } },
        { setting = "temple", theme = "templeGold", required = { "floorScatter", "emphasis", "wallFixtures", "ambientClutter", "atmosphere", "structureRuin" } },
        { setting = "hospital", theme = "sterile", required = { "floorScatter", "emphasis", "wallFixtures", "ambientClutter", "corridorScatter" } },
        { setting = "school", theme = "schoolDay", required = { "floorScatter", "emphasis", "wallFixtures", "ambientClutter" } },
    }
    for _, item in ipairs(cases) do
        local profile = EnvironmentProfiles.Resolve(item.setting)
        for _, field in ipairs(item.required) do
            Check(type(profile[field]) == "table" and next(profile[field]) ~= nil,
                item.setting .. ": missing visual quality layer " .. field)
        end
        local fixtureSpacing = profile.wallFixtures.spacing or 4
        Check(fixtureSpacing <= 4,
            item.setting .. ": wall fixtures are too sparse for the quality baseline")
        Check(profile.emphasis.roleTargets.elite and profile.emphasis.roleTargets.boss,
            item.setting .. ": high-tier emphasis targets are incomplete")
        local theme = Themes.Get(item.theme)
        Check(type(theme.ambient) == "number" and theme.ambient >= 0.45,
            item.setting .. ": ambient quality baseline is too low")
        Check(type(theme.sunIntensity) == "number" and theme.sunIntensity >= 0.55,
            item.setting .. ": sun quality baseline is too low")
    end
    local pack = ThemePacks.Get("school")
    Check(pack and pack.wallRules and #pack.wallRules >= 4,
        "school: wall quality pack is incomplete")
end

local function TestAtmosphereMoodPresets()
    local valid, reason = AtmosphereProfiles.Validate()
    Check(valid, reason)

    -- Resolution chain: palette override -> per-setting default -> neutral.
    Check(AtmosphereProfiles.Resolve("dungeon", Themes.Get("ancient")).key == "dungeonDepths",
        "dungeon setting did not resolve its default mood")
    for _, settingKey in ipairs({ "temple", "hospital", "school" }) do
        local palette = Themes.Get(Themes.DefaultPaletteForSetting(settingKey))
        Check(AtmosphereProfiles.Resolve(settingKey, palette).key == AtmosphereProfiles.NEUTRAL_KEY,
            settingKey .. " must stay on the neutral mood until its own atmosphere is authored")
    end
    Check(AtmosphereProfiles.Resolve("dungeon", { atmosphereKey = "neutral" }).key == "neutral",
        "palette atmosphereKey override was ignored")
    Check(AtmosphereProfiles.Resolve("dungeon", { atmosphereKey = "no-such-mood" }).key == "dungeonDepths",
        "unknown palette atmosphereKey must fall back to the setting default")

    -- Neutral must be a strict identity so un-authored settings render unchanged.
    local sterile = Themes.Get("sterile")
    local neutral = AtmosphereProfiles.ComputeLighting(sterile, AtmosphereProfiles.Get("neutral"))
    Check(neutral.fogDensity == sterile.fogDensity
            and neutral.ambientIntensity == sterile.ambient
            and neutral.sunBrightness == sterile.sunIntensity
            and neutral.vignetteIntensity == 0,
        "neutral mood is no longer an identity envelope")
    local legacyFlicker = AtmosphereProfiles.FlickerEnvelope(AtmosphereProfiles.Get("neutral"))
    Check(legacyFlicker.base == 0.90 and legacyFlicker.ampA == 0.07 and legacyFlicker.speedA == 7.3
            and legacyFlicker.ampB == 0.03 and legacyFlicker.speedB == 13.1,
        "neutral flicker drifted from the legacy renderer constants")

    -- The dungeon mood darkens and thickens, but every built-in ruins palette
    -- must stay above the readability floor backing the §2.10 acceptance.
    local mood = AtmosphereProfiles.Get("dungeonDepths")
    for _, paletteKey in ipairs({ "ancient", "molten", "frost", "grim", "verdant" }) do
        local theme = Themes.Get(paletteKey)
        local lit = AtmosphereProfiles.ComputeLighting(theme, mood)
        Check(lit.fogDensity > theme.fogDensity and lit.ambientIntensity < theme.ambient
                and lit.sunBrightness < theme.sunIntensity,
            paletteKey .. ": dungeon mood must darken the base light and thicken the fog")
        Check(lit.ambientIntensity >= 0.40 and lit.sunBrightness >= 0.30,
            paletteKey .. ": dungeon mood dimmed the base light below the readability floor")
        Check(lit.vignetteIntensity > 0 and lit.vignetteIntensity <= 3,
            paletteKey .. ": dungeon vignette must stay subtle")
    end
    Check(AtmosphereProfiles.TorchScale(mood) > 1.0,
        "dungeon mood must return brightness through the torch pools")
    local moodFlicker = AtmosphereProfiles.FlickerEnvelope(mood)
    Check(moodFlicker.ampA + moodFlicker.ampB > legacyFlicker.ampA + legacyFlicker.ampB,
        "dungeon firelight should breathe deeper than the neutral envelope")
end

local function TestPaletteAIContract()
    local colors = {
        floor = "#6E7078", corridor = "#575A63", wall = "#454852", pillar = "#5D606A",
        accentObject = "#C06BFF", cloth = "#6F4C91", flame = "#E58BFF", flameCore = "#F4E4FF",
    }
    local request = PaletteAIProvider.BuildRequest("冷峻紫灰石材和洋红符文", "月蚀紫", "dungeon",
        cjson.encode(colors))
    Check(request.operation == "palette.generate", "AI palette request operation changed")
    Check(request.prompt:find("冷峻紫灰", 1, true) ~= nil, "AI palette prompt lost user description")
    Check(#request.fields == #PaletteData.COLOR_FIELDS, "AI palette request field contract changed")
    for _, field in ipairs(PaletteData.COLOR_FIELDS) do
        local found = false
        for _, requestedField in ipairs(request.fields) do
            if requestedField == field then found = true; break end
        end
        Check(found, "AI palette request omitted field " .. field)
    end

    local direct, directReason = PaletteAIProvider.DecodeResponse(cjson.encode(colors))
    Check(direct and direct.floor == 0x6e7078, directReason or "direct AI palette response failed")
    local wrapped, wrappedReason = PaletteAIProvider.DecodeResponse(cjson.encode({ colors = colors }))
    Check(wrapped and wrapped.flameCore == 0xf4e4ff,
        wrappedReason or "wrapped AI palette response failed")
    local openAIResponse = cjson.encode({ choices = { {
        message = { content = "```json\n" .. cjson.encode({ colors = colors }) .. "\n```" },
    } } })
    local openAI, openAIReason = PaletteAIProvider.DecodeResponse(openAIResponse)
    Check(openAI and openAI.accentObject == 0xc06bff,
        openAIReason or "OpenAI-compatible palette response failed")

    local invalid = {}
    for field, value in pairs(colors) do invalid[field] = value end
    invalid.flameCore = "#ZZZZZZ"
    local rejected = PaletteAIProvider.DecodeResponse(cjson.encode(invalid))
    Check(rejected == nil, "invalid AI palette color was accepted")
    local unavailable, unavailableReason = PaletteAIProvider.Generate(request)
    Check(unavailable == false and unavailableReason == PaletteAIProvider.UNAVAILABLE_REASON,
        "unavailable AI provider did not expose the integration boundary")
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
    Check(#data.customSettings == 6, "customization normalization kept duplicate or invalid themes")
    Check(data.customSettings[1].label == "Ice Temple", "custom theme label was not trimmed")
    Check(data.customSettings[1].baseSettingKey == "hospital", "valid base setting was lost")
    Check(data.customSettings[1].packStatus == "draft", "draft ThemePack status was lost")
    Check(data.customSettings[2].packStatus == "ready", "legacy ThemePack did not migrate to ready")
    Check(data.customSettings[2].generationMode == "generic",
        "generic planner metadata did not migrate to generic generation mode")
    Check(data.customSettings[2].floorHeight == 4.2,
        "custom topic floor height was lost during normalization")
    Check(data.customSettings[2].baseSettingKey == "dungeon", "invalid base setting did not fall back")
    Check(CustomizationStore.FindById(data.customSettings, TopicSeeds.IdForSetting("dungeon"))
            and CustomizationStore.FindById(data.customSettings, TopicSeeds.IdForSetting("hospital"))
            and CustomizationStore.FindById(data.customSettings, TopicSeeds.IdForSetting("school")),
        "initial topics were not materialized alongside custom topics")
    Check(data.nextCustomSettingId == 10, "next custom theme id was not repaired")
    Check(data.activeCustomSettingId == "custom-4", "valid active custom theme was cleared")
    Check(#data.roomGroups == 2 and data.nextRoomGroupId == 4,
        "room normalization did not deduplicate names by scope or repair ids")
    Check(data.roomGroups[1].topicId == TopicSeeds.IdForSetting("dungeon"),
        "legacy unscoped room did not migrate to the dungeon topic")
    Check(data.roomGroups[2].topicId == TopicSeeds.IdForSetting("hospital"),
        "base-setting room lost its hospital topic scope")
    local dungeonRooms = LocalRequirementPlanner.GroupsForTopic(data.roomGroups, TopicSeeds.IdForSetting("dungeon"))
    local hospitalRooms = LocalRequirementPlanner.GroupsForTopic(data.roomGroups, TopicSeeds.IdForSetting("hospital"))
    local schoolRooms = LocalRequirementPlanner.GroupsForTopic(data.roomGroups, TopicSeeds.IdForSetting("school"))
    Check(#dungeonRooms == 1 and dungeonRooms[1].id == "room-group-3",
        "legacy Boss room escaped its migrated dungeon topic")
    Check(#hospitalRooms == 1 and hospitalRooms[1].id == "hospital-boss",
        "hospital-scoped room is not isolated to its topic")
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

    local defaultBase = Themes.GetDefaultPalettes()[1]
    Check(defaultBase == "ancient", "default palette ordering changed unexpectedly")
    Check(Themes.IsPaletteForSetting("ancient", "hospital"),
        "default palettes must be selectable across themes")
    Check(not Themes.IsPaletteForSetting("sterile", "school"),
        "theme palettes must remain scoped to their theme")
    Check(Themes.GetPaletteGroup("ancient", "school") == "default",
        "default palette group was not resolved")
    Check(Themes.GetPaletteGroup("schoolDay", "school") == "theme",
        "theme palette group was not resolved")
    Check(Themes.GetPaletteGroup("schoolDay", "hospital") == nil,
        "foreign theme palette unexpectedly resolved")
    local hospitalDefault = Themes.Resolve("hospital", "ancient")
    Check(hospitalDefault.floor == Themes.ancient.floor and hospitalDefault.torchLight[2] == Themes.sterile.torchLight[2],
        "default palette did not retain theme-specific rendering behavior")

    Themes.SetCustomPalettes({ {
        schemaVersion = PaletteData.SCHEMA_VERSION,
        id = "custom-default-palette", label = "通用测试", paletteGroup = "default",
        baseSettingKey = "dungeon", basePaletteKey = "ancient",
        colors = {
            floor = 0x707070, corridor = 0x606060, wall = 0x505050, pillar = 0x686868,
            accentObject = 0x3fa9d0, cloth = 0x426070, flame = 0x5fcfff, flameCore = 0xdff8ff,
        },
    } })
    Check(Themes.IsPaletteForSetting("custom-default-palette", "school"),
        "custom default palette was not shared across themes")
    Check(Themes.GetPaletteGroup("custom-default-palette", "hospital") == "default",
        "custom default palette group was not retained")
    Themes.SetCustomPalettes({})

    local missingActive = CustomizationStore.Normalize({
        customSettings = data.customSettings,
        activeCustomSettingId = "custom-404",
    })
    Check(missingActive.activeCustomSettingId == TopicSeeds.DEFAULT_ID,
        "missing active custom theme did not fall back to the initial temple topic")

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

local function TestAnywhereEditorStairFallback()
    local far = DungeonGenerator.Generate({
        seed = 7152028,
        floorCount = 2,
        editorEnabled = true,
        editorRooms = {
            { cx = 0, cy = 0, w = 10, h = 10, floor = 0, roleHint = "entrance" },
            { cx = 0, cy = 0, w = 10, h = 10, floor = 1, roleHint = "boss" },
        },
        editorEdges = {
            { a = 1, b = 2, kind = "stairs", isManual = true,
                stairSpec = { id = "stair-anywhere", mode = "locked", pending = true,
                    previewAnchor = { x = 80, y = 60 }, previewDirection = "east",
                    previewStyle = "l-turn", previewWidth = 2, previewLength = 8,
                    previewLandingDepth = 2, allowFallback = true } },
        },
        settingKey = "hospital",
        theme = "sterile",
    })
    CheckValid(far, "far blank-space editor stair")
    local farConnector = far.connectors[1]
    Check(farConnector and far.editorOffset
        and farConnector.lower.x - far.editorOffset.x == 80
        and farConnector.lower.y - far.editorOffset.y == 60,
        "editor map bounds clipped a stair authored far from every room")
    Check(far.edges[1].stairSpec.allowFallback == true,
        "blank-space stair lost its PCG fallback policy")

    local blocked = DungeonGenerator.Generate({
        seed = 7152029,
        floorCount = 2,
        editorEnabled = true,
        editorRooms = {
            { cx = 0, cy = 18, w = 10, h = 10, floor = 0, roleHint = "entrance" },
            { cx = 0, cy = 18, w = 10, h = 10, floor = 1, roleHint = "boss" },
            { cx = 18, cy = 18, w = 8, h = 8, floor = 0, roleHint = "secret" },
        },
        editorEdges = {
            { a = 1, b = 3, isManual = true, width = 1 },
            { a = 1, b = 2, kind = "stairs", isManual = true,
                stairSpec = { id = "stair-fallback", mode = "locked", pending = true,
                    previewAnchor = { x = 18, y = 18 }, previewDirection = "east",
                    previewStyle = "l-turn", previewWidth = 2, previewLength = 8,
                    previewLandingDepth = 2, allowFallback = true } },
        },
        settingKey = "hospital",
        theme = "sterile",
    })
    CheckValid(blocked, "blocked blank-space stair fallback")
    local connector = blocked.connectors[1]
    Check(connector and connector.fallbackUsed == true,
        "PCG did not activate fallback for a blocked authored stair point")
    Check(connector.lower.x - blocked.editorOffset.x ~= 18
        or connector.lower.y - blocked.editorOffset.y ~= 18
        or connector.direction ~= "east",
        "PCG fallback left the stair on the blocked contract")
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
        { "door contract", TestDoorContract },
        { "dungeon determinism", TestDungeonDeterminism },
        { "floor setting isolation", TestFloorSettingIsolation },
        { "single floor", TestSingleFloor },
        { "20 multifloor seeds", TestMultiFloorSeeds },
        { "beyond recommended floors", TestBeyondRecommendedFloorCount },
        { "six-floor shaft regression", TestSixFloorShaftRegression },
        { "hospital prop migration", TestHospitalPropMigration },
        { "wall light shape", TestWallLightShapeContract },
        { "dungeon prop blueprints", TestDungeonPropBlueprintCoverage },
        { "temple setting coverage", TestTempleSettingCoverage },
        { "school ThemePack stability", TestSchoolThemePackStability },
        { "school AI requirement flow", TestSchoolRequirementPlannerFlow },
        { "built-in room rule flow", TestBuiltinRoomRuleFlow },
        { "generic theme rule flow", TestGenericThemeRuleFlow },
        { "configurable floor height", TestConfigurableFloorHeight },
        { "three parity contracts", TestThreeParityContracts },
        { "geometry seam contracts", TestGeometrySeamContracts },
        { "material separation", TestMaterialSeparationContracts },
        { "theme tone contracts", TestThemeToneContracts },
        { "theme quality profiles", TestThemeQualityProfiles },
        { "atmosphere mood presets", TestAtmosphereMoodPresets },
        { "palette AI contract", TestPaletteAIContract },
        { "customization normalization", TestCustomizationNormalization },
        { "editor room groups", TestEditorRoomGroupPropagation },
        { "pinned editor stair", TestPinnedEditorStairContract },
        { "anywhere stair fallback", TestAnywhereEditorStairFallback },
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
