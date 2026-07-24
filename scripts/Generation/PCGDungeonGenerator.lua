local PCGDungeonRooms = require("Generation.PCGDungeonRooms")
local PCGDungeonGraph = require("Generation.PCGDungeonGraph")
local PCGDungeonAStar = require("Generation.PCGDungeonAStar")

local PCGDungeonGenerator = {}

local function CopyValue(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[key] = CopyValue(item, seen) end
    return result
end

local function EdgeKey(a, b)
    return math.min(a, b) .. ":" .. math.max(a, b)
end

local function GridCoordinates(index, nx, nz)
    local x = index % nx
    local remainder = index // nx
    return x, remainder // nz, remainder % nz
end

local function EditorPoint(layout, routed, cell)
    local nx, nz = routed.gridSize[1], routed.gridSize[3]
    local x, floor, z = GridCoordinates(cell, nx, nz)
    local cellSize = routed.cellSize
    local worldX = routed.worldMin[1] + (x + 0.5) * cellSize
    local worldZ = routed.worldMin[3] + (z + 0.5) * cellSize
    return {
        x = (worldX - layout.layoutWorldMin[1]) / cellSize,
        y = (worldZ - layout.layoutWorldMin[3]) / cellSize,
    }, floor
end

local function SimplifyRoute(points)
    local result = {}
    for _, point in ipairs(points or {}) do
        local count = #result
        if count >= 2 then
            local a, b = result[count - 1], result[count]
            local abx, aby = b.x - a.x, b.y - a.y
            local bcx, bcy = point.x - b.x, point.y - b.y
            if math.abs(abx * bcy - aby * bcx) < 0.000001
                and abx * bcx + aby * bcy >= 0 then
                result[count] = point
            else result[#result + 1] = point end
        elseif count == 0 or result[count].x ~= point.x or result[count].y ~= point.y then
            result[#result + 1] = point
        end
    end
    return result
end

local function RuntimeRoutes(layout, routed, route)
    local result, active = {}, nil
    for _, cell in ipairs(route.cells or {}) do
        local point, floor = EditorPoint(layout, routed, cell)
        if not active or active.floor ~= floor then
            if active and #active.points > 1 then
                active.points = SimplifyRoute(active.points)
                result[#result + 1] = active
            end
            active = { floor = floor, points = { point } }
        else
            active.points[#active.points + 1] = point
        end
    end
    if active and #active.points > 1 then
        active.points = SimplifyRoute(active.points)
        result[#result + 1] = active
    end
    return result
end

local function DirectionName(dx, dy)
    if math.abs(dx) >= math.abs(dy) then return dx >= 0 and "east" or "west" end
    return dy >= 0 and "south" or "north"
end

local function RuntimeStairs(layout, routed, route, connectors)
    local result = {}
    for _, stair in ipairs(route.stairs or {}) do
        local lower, fromFloor = EditorPoint(layout, routed, stair.lower_cell)
        local upper, toFloor = EditorPoint(layout, routed, stair.upper_cell)
        local dx, dy = upper.x - lower.x, upper.y - lower.y
        local length = math.sqrt(dx * dx + dy * dy)
        local connector = {
            id = "pcg-stair-" .. tostring(stair.stairwell_id),
            stairId = "pcg-stair-" .. tostring(stair.stairwell_id),
            mode = "runtime",
            style = "straight",
            lower = lower,
            upper = upper,
            fromFloor = fromFloor,
            toFloor = toFloor,
            direction = DirectionName(dx, dy),
            directionVector = length > 0 and { x = dx / length, y = dy / length } or { x = 1, y = 0 },
            length = length,
            width = 1,
            landingDepth = 1,
            rise = layout.cellSize,
            stepCount = 12,
            stairwellId = stair.stairwell_id,
            connectionId = route.connection_id,
        }
        connectors[#connectors + 1] = connector
        result[#result + 1] = connector
    end
    return result
end

local function EditorEdges(layout, graph, routed)
    local result, connectors, routesByKey = {}, {}, {}
    for _, route in ipairs(routed.successfulRoutes or {}) do
        routesByKey[EdgeKey(route.a, route.b)] = route
    end
    for index, source in ipairs(graph.edges or {}) do
        local edge = CopyValue(source)
        edge.id = index
        edge.a, edge.b = source.a + 1, source.b + 1
        edge.isLoop = source.isLoop == true
        edge.kind = source.kind or (layout.rooms[source.a + 1].floor ~= layout.rooms[source.b + 1].floor
            and "stairs" or "corridor")
        local route = routesByKey[EdgeKey(source.a, source.b)]
        edge.runtimeGenerated = route ~= nil
        edge.width = route and 1 or edge.width
        edge.runtimeRoutes = route and RuntimeRoutes(layout, routed, route) or {}
        edge.runtimeStairs = route and RuntimeStairs(layout, routed, route, connectors) or {}
        edge.connectorId = edge.runtimeStairs[1] and edge.runtimeStairs[1].id or nil
        result[index] = edge
    end
    return result, connectors
end

local function HashText(text)
    local hash = 2166136261
    for index = 1, #text do
        hash = ((hash ~ text:byte(index)) * 16777619) & 0xffffffff
    end
    return string.format("%08x", hash)
end

local function TopologyHash(layout, graphResult, routed)
    local values = { layout.seed, layout.floorCount, layout.placedRoomCount }
    for _, room in ipairs(layout.rooms) do
        values[#values + 1] = string.format("r%d:%g,%g,%g:%g,%g,%g", room.id,
            room.position[1], room.position[2], room.position[3],
            room.size[1], room.size[2], room.size[3])
    end
    for _, edge in ipairs(graphResult.graph.edges) do
        values[#values + 1] = string.format("e%d,%d:%d:%d", edge.a, edge.b,
            edge.isMst and 1 or 0, edge.sourcePrimitive)
    end
    for _, cell in ipairs(routed.cells) do
        values[#values + 1] = string.format("c%d:%d:%d", cell.id, cell.cell_type, cell.stairwell_id)
    end
    return HashText(table.concat(values, "|"))
end

function PCGDungeonGenerator.Generate(options)
    options = options or {}
    local layout = PCGDungeonRooms.Generate(options)
    if layout.valid == false or layout.placedRoomCount ~= layout.targetRoomCount then
        local reason = layout.warning or "PCG Dungeon room layout is invalid"
        return { valid = false, error = reason, layout = layout, errors = layout.errors or { reason } }
    end
    local loopRates = options.loopRatesByFloor
    if loopRates == nil then loopRates = options.loopRate end
    local graphResult = PCGDungeonGraph.Generate(layout,
        options.editorEnabled and options.editorEdges or nil, loopRates)
    if not graphResult.graph.connected then
        local reason = graphResult.graph.warning or "PCG Dungeon graph is disconnected"
        return { valid = false, error = reason, layout = layout, graphResult = graphResult, errors = { reason } }
    end
    local routed = PCGDungeonAStar.Generate(layout, graphResult.graph)
    local valid = routed.allRoomsReachable and routed.failedMstPaths == 0
        and routed.stairTopologyValid ~= false
    local reason = valid and nil or (routed.warning or "PCG Dungeon A* failed to connect every room")
    local editorEdges, connectors = EditorEdges(layout, graphResult.graph, routed)
    return {
        schemaVersion = 1,
        valid = valid,
        error = reason,
        errors = reason and { reason } or {},
        requestedSeed = layout.seed,
        seed = layout.seed,
        floorCount = layout.floorCount,
        roomCount = layout.placedRoomCount,
        roomCountsByFloor = layout.roomCountsByFloor,
        rooms = layout.rooms,
        edges = editorEdges,
        connectors = connectors,
        floorHeight = layout.cellSize,
        cellSize = layout.cellSize,
        editorWorldScale = layout.cellSize,
        editorSwapAxes = true,
        editorCenterOffset = 0,
        editorRoomMinimumWidth = 1,
        editorRoomMinimumHeight = 1,
        width = (layout.editorGridCells or layout.gridCells)[1],
        height = (layout.editorGridCells or layout.gridCells)[3],
        sceneInfo = {
            floorHeight = layout.cellSize,
            cellSize = layout.cellSize,
            gridWidth = (layout.editorGridCells or layout.gridCells)[1],
            gridHeight = (layout.editorGridCells or layout.gridCells)[3],
            worldWidth = (layout.editorGridCells or layout.gridCells)[3] * layout.cellSize,
            worldDepth = (layout.editorGridCells or layout.gridCells)[1] * layout.cellSize,
            totalHeight = layout.floorCount * layout.cellSize,
        },
        hash = TopologyHash(layout, graphResult, routed),
        topology = { cells = routed.cells, doors = routed.doors },
        layout = layout,
        delaunay = graphResult.delaunay,
        graph = graphResult.graph,
        astar = routed,
        stats = {
            floors = layout.floorCount,
            rooms = layout.placedRoomCount,
            delaunayEdges = #graphResult.delaunay.edges,
            delaunayTets = #graphResult.delaunay.tets,
            mstEdges = #graphResult.graph.mstEdges,
            loopEdges = #graphResult.graph.loopEdges,
            stairs = routed.stairCount,
            corridors = routed.corridorCellCount,
            doors = routed.doorwayCount,
        },
    }
end

return PCGDungeonGenerator
