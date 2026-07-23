-- Standalone stair-rule regression tower, ported/adapted from the reference
-- src/testing/stair-rule-map.js. It builds a fixed 4-floor tower with exactly
-- three stairs (wall-hugging L, wide straight, open L) and evaluates the stair
-- PCG contract against 12 named rules, isolated from room/decor/combat quality.
local MultiFloor = require("Generation.MultiFloor")

local StairRuleMap = {}

StairRuleMap.MAP = {
    id = "stair-rule-tower-v1",
    name = "楼梯 PCG 规则测试塔",
    width = 64,
    height = 48,
    floorCount = 4,
}

local function TestRoom(index, floor)
    return {
        id = index, cx = 32, cy = 24, w = 44, h = 32,
        floor = floor, depth = floor,
        roleHint = floor == 0 and "entrance" or nil,
    }
end

local function StairEdge(id, from, to, spec)
    spec.id = spec.id or ("stair-rule-" .. id)
    spec.mode = spec.mode or "locked"
    spec.landingDepth = spec.landingDepth or 2
    spec.wallMode = spec.wallMode or "wall-backed"
    return {
        id = id, a = from, b = to,
        isLoop = false, isCritical = true, isManual = true,
        stairSpec = spec,
    }
end

function StairRuleMap.Create()
    local map = StairRuleMap.MAP
    local rooms = {}
    for floor = 0, map.floorCount - 1 do rooms[floor + 1] = TestRoom(floor + 1, floor) end
    local edges = {
        StairEdge(1, 1, 2, { style = "l-turn", anchor = { x = 20, y = 8 }, direction = "east", width = 2, length = 8 }),
        StairEdge(2, 2, 3, { style = "straight", anchor = { x = 22, y = 24 }, direction = "east", width = 3, length = 8 }),
        StairEdge(3, 3, 4, { style = "l-turn", width = 2, length = 8 }),
    }
    local layout = MultiFloor.Build({
        width = map.width, height = map.height, floorCount = map.floorCount,
        rooms = rooms, edges = edges, entrance = 1, floorHeight = MultiFloor.FLOOR_HEIGHT,
    })
    layout.rooms = rooms
    layout.width, layout.height, layout.floorCount = map.width, map.height, map.floorCount
    layout.floorHeight = MultiFloor.FLOOR_HEIGHT
    return layout
end

local WALL = MultiFloor.Tiles.WALL
local FLOOR = MultiFloor.Tiles.FLOOR

local function CellSet(cells)
    local set = {}
    for _, cell in ipairs(cells or {}) do set[cell] = true end
    return set
end

local function SameCellSet(a, b)
    local sa, sb = CellSet(a), CellSet(b)
    local ca, cb = 0, 0
    for cell in pairs(sa) do ca = ca + 1; if not sb[cell] then return false end end
    for _ in pairs(sb) do cb = cb + 1 end
    return ca == cb
end

local function KeySet(edges)
    local set = {}
    for _, edge in ipairs(edges or {}) do set[edge.key] = true end
    return set
end

-- Every boundary edge is either a mandatory-open access edge (must carry neither
-- wall nor guard) or is protected by exactly one of wall / guard.
local function BoundaryPartitioned(boundary, openKeys, wallSegs, guardSegs)
    local wallKeys, guardKeys = KeySet(wallSegs), KeySet(guardSegs)
    for _, edge in ipairs(boundary or {}) do
        if openKeys[edge.key] then
            if wallKeys[edge.key] or guardKeys[edge.key] then return false end
        else
            local n = (wallKeys[edge.key] and 1 or 0) + (guardKeys[edge.key] and 1 or 0)
            if n ~= 1 then return false end
        end
    end
    return true
end

local function EveryCell(cells, fn)
    for _, cell in ipairs(cells or {}) do if not fn(cell) then return false end end
    return true
end

function StairRuleMap.Evaluate(map)
    local connectors = map.connectors or {}
    local checks = {}
    for _, connector in ipairs(connectors) do
        local contract = connector.contract or {}
        local lower = map.layers[connector.fromFloor + 1]
        local upper = map.layers[connector.toFloor + 1]
        local expectedOpenings = {}
        for _, record in ipairs(connector.sweptClearanceCells or {}) do
            if record.intersectsUpperSlab then expectedOpenings[#expectedOpenings + 1] = record.cell end
        end
        local openKeysOpening = {}
        for _, edge in ipairs(contract.openingAccessEdges or {}) do openKeysOpening[edge.key] = true end
        for _, edge in ipairs(contract.openingStairPassageEdges or {}) do openKeysOpening[edge.key] = true end
        local openKeysWell = KeySet(contract.stairwellAccessEdges)

        checks[#checks + 1] = {
            id = connector.id,
            adjacentFloor = connector.toFloor - connector.fromFloor == 1,
            reservedOnBothFloors = EveryCell(connector.sharedFootprintCells, function(cell)
                return lower.stairwellMask[cell] and upper.stairwellMask[cell] end),
            headroomTight = #(connector.openingCells or {}) > 0
                and #connector.openingCells < #(connector.shaftCells or {})
                and SameCellSet(connector.openingCells, expectedOpenings),
            landingsOpen = EveryCell(connector.lowerLandingCells, function(cell)
                    return lower.stairLanding[cell] and lower.grid[cell] == FLOOR end)
                and EveryCell(connector.upperLandingCells, function(cell)
                    return upper.stairLanding[cell] and upper.grid[cell] == FLOOR end),
            openingProtected = BoundaryPartitioned(contract.openingBoundaryEdges, openKeysOpening,
                connector.openingWallSegments, connector.openingGuardSegments),
            wellProtected = BoundaryPartitioned(contract.stairwellBoundaryEdges, openKeysWell,
                connector.stairWallSegments, connector.stairRailSegments),
            lTurnSeamsOpen = connector.style ~= "l-turn"
                or EveryCell(connector.stairwellInteriorCells, function(cell)
                    return lower.grid[cell] ~= WALL and upper.grid[cell] ~= WALL end),
            doubleHeightWallPolicy = connector.wallHeightPolicy == "opening-span-classified",
            stepContract = connector.stepCount == 20
                and math.abs(connector.stepRise - 0.25) < 1e-9
                and math.abs(connector.stepCount * connector.stepRise - connector.rise) < 1e-9,
        }
    end

    local function AllChecks(field)
        for _, check in ipairs(checks) do if not check[field] then return false end end
        return true
    end
    local styles = {}
    local straight
    for _, connector in ipairs(connectors) do
        styles[connector.style] = true
        if connector.style == "straight" then straight = connector end
    end
    local wallBacked = false
    for _, connector in ipairs(connectors) do
        local walls = #(connector.stairWallSegments or {}) + #(connector.openingWallSegments or {})
        local guards = #(connector.stairRailSegments or {}) + #(connector.openingGuardSegments or {})
        if walls > 0 and guards > 0 then wallBacked = true end
    end
    local audits = map.stairAudits or {}
    local auditsPass = #audits == #connectors
    for _, entry in ipairs(audits) do
        local a = entry.audit or {}
        if not (a.pass and a.traversable and a.reachable and a.wallsComplete and a.slabsComplete) then
            auditsPass = false
        end
    end

    local rules = {
        { id = "layout", label = "测试塔生成成功", pass = map.valid and #connectors == 3,
            detail = string.format("%d 层 / %d 部楼梯 / %d 个错误", map.floorCount, #connectors, #(map.errors or {})) },
        { id = "styles", label = "直跑与 L 型同时覆盖", pass = styles["straight"] and styles["l-turn"] or false },
        { id = "width", label = "1m 地砖卡尺缩放", pass = straight ~= nil and straight.width == 3 },
        { id = "reservation", label = "双层楼梯井占位正确", pass = AllChecks("reservedOnBothFloors") },
        { id = "slab", label = "楼板按净高精确开洞", pass = AllChecks("headroomTight") },
        { id = "landing", label = "上下落地与定向入口畅通", pass = AllChecks("landingsOpen") },
        { id = "protection", label = "墙体与护栏完整互斥",
            pass = AllChecks("openingProtected") and AllChecks("wellProtected") },
        { id = "wall-backed", label = "贴墙楼梯同时产生墙与护栏", pass = wallBacked },
        { id = "turn-seam", label = "L 型转角内部无横墙", pass = AllChecks("lTurnSeamsOpen") },
        { id = "steps", label = "层高与梯级契约一致", pass = AllChecks("stepContract") },
        { id = "reachability", label = "跨层连通验证通过",
            pass = map.valid and #(map.errors or {}) == 0 },
        { id = "per-stair-audit", label = "逐楼梯生成验收通过", pass = auditsPass },
    }
    local pass = true
    for _, rule in ipairs(rules) do if not rule.pass then pass = false end end
    return { pass = pass, rules = rules, connectorChecks = checks }
end

return StairRuleMap
