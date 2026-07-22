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

local function EditorEdges(layout, graph)
    local result = {}
    for index, source in ipairs(graph.edges or {}) do
        local edge = CopyValue(source)
        edge.id = index
        edge.a, edge.b = source.a + 1, source.b + 1
        edge.isLoop = source.isLoop == true
        edge.kind = source.kind or (layout.rooms[source.a + 1].floor ~= layout.rooms[source.b + 1].floor
            and "stairs" or "corridor")
        edge.connectorId = nil
        result[index] = edge
    end
    return result
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
    local graphResult = PCGDungeonGraph.Generate(layout,
        options.editorEnabled and options.editorEdges or nil)
    if not graphResult.graph.connected then
        local reason = graphResult.graph.warning or "PCG Dungeon graph is disconnected"
        return { valid = false, error = reason, layout = layout, graphResult = graphResult, errors = { reason } }
    end
    local routed = PCGDungeonAStar.Generate(layout, graphResult.graph)
    local valid = routed.allRoomsReachable and routed.failedMstPaths == 0
        and routed.stairTopologyValid ~= false
    local reason = valid and nil or (routed.warning or "PCG Dungeon A* failed to connect every room")
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
        edges = EditorEdges(layout, graphResult.graph),
        connectors = {},
        floorHeight = layout.cellSize,
        cellSize = layout.cellSize,
        width = (layout.editorGridCells or layout.gridCells)[1],
        height = (layout.editorGridCells or layout.gridCells)[3],
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
