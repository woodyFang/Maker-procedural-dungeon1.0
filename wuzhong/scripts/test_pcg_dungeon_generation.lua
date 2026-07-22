local PCGDungeonGenerator = require("Generation.PCGDungeonGenerator")

local function Check(condition, message)
    if not condition then error(message, 2) end
end

local function Near(a, b, epsilon)
    return math.abs((a or 0) - (b or 0)) <= (epsilon or 0.0001)
end

local function LoadFixture()
    local file = cache:GetFile("PCGDungeon/LegacyReference/GenerationFixture.json")
    Check(file ~= nil, "legacy reference generation fixture could not be opened")
    local raw = file:ReadString()
    file:Close()
    local ok, data = pcall(cjson.decode, raw)
    Check(ok and type(data) == "table", "legacy reference generation fixture is invalid JSON")
    return data
end

local function CheckVector(actual, expected, label)
    Check(#actual == #expected, label .. " vector length differs")
    for index = 1, #expected do
        Check(Near(actual[index], expected[index]), string.format(
            "%s[%d] differs: Lua=%g legacy reference=%g", label, index, actual[index], expected[index]))
    end
end

local function CheckIntegerArray(actual, expected, label)
    Check(#actual == #expected, string.format("%s length differs: Lua=%d legacy reference=%d",
        label, #actual, #expected))
    for index = 1, #expected do
        Check(actual[index] == expected[index], string.format(
            "%s[%d] differs: Lua=%s legacy reference=%s", label, index,
            tostring(actual[index]), tostring(expected[index])))
    end
end

local function SortedTetKey(tet)
    local values = { tet[1], tet[2], tet[3], tet[4] }
    table.sort(values)
    return table.concat(values, ":")
end

local function CheckStairContracts(astar, label)
    Check(astar.stairTopologyValid == true,
        label .. " stair topology validation failed: "
        .. table.concat(astar.stairTopologyErrors or {}, "; "))
    local byId, byStair = {}, {}
    for _, cell in ipairs(astar.cells) do
        byId[cell.id] = cell
        if cell.stairwell_id and cell.stairwell_id >= 0 then
            byStair[cell.stairwell_id] = byStair[cell.stairwell_id] or {}
            byStair[cell.stairwell_id][cell.stair_role] = cell
        end
    end
    for stairwell = 0, astar.stairCount - 1 do
        local cells = byStair[stairwell] or {}
        for _, role in ipairs({ 0, 1, 2, 3 }) do
            Check(cells[role] ~= nil, string.format(
                "%s stairwell %d is missing role %d", label, stairwell, role))
        end
        Check(cells[0].cell_type == 3 and cells[1].cell_type == 3,
            string.format("%s stairwell %d does not have two physical stair cells", label, stairwell))
        Check(cells[2].cell_type == 4 and cells[3].cell_type == 4,
            string.format("%s stairwell %d does not have two headroom cells", label, stairwell))
        local lower, upper = cells[0].grid_coord, cells[1].grid_coord
        Check(lower[2] == upper[2]
                and math.abs(lower[1] - upper[1]) + math.abs(lower[3] - upper[3]) == 1,
            string.format("%s stairwell %d physical cells are not adjacent", label, stairwell))
        Check(cells[2].grid_coord[1] == lower[1] and cells[2].grid_coord[2] == lower[2] + 1
                and cells[2].grid_coord[3] == lower[3]
                and cells[3].grid_coord[1] == upper[1] and cells[3].grid_coord[2] == upper[2] + 1
                and cells[3].grid_coord[3] == upper[3],
            string.format("%s stairwell %d headroom is not above both physical cells", label, stairwell))
        local dx, dz = upper[1] - lower[1], upper[3] - lower[3]
        local lowerLandingId = (lower[1] - dx)
            + astar.gridSize[1] * (lower[3] - dz + astar.gridSize[3] * lower[2])
        local upperLandingId = (upper[1] + dx)
            + astar.gridSize[1] * (upper[3] + dz + astar.gridSize[3] * (upper[2] + 1))
        Check(byId[lowerLandingId] and byId[lowerLandingId].cell_type == 2,
            string.format("%s stairwell %d lower landing is not a corridor", label, stairwell))
        Check(byId[upperLandingId] and byId[upperLandingId].cell_type == 2,
            string.format("%s stairwell %d upper landing is not a corridor", label, stairwell))
        local pairA = astar.stairLandingPairs[stairwell * 2 + 1]
        local pairB = astar.stairLandingPairs[stairwell * 2 + 2]
        Check((pairA == lowerLandingId and pairB == upperLandingId)
                or (pairA == upperLandingId and pairB == lowerLandingId),
            string.format("%s stairwell %d landing pair is disconnected", label, stairwell))
    end
end

function Start()
    print("[PCGDungeonGeneration] START")
    local ok, errorMessage = xpcall(function()
        local fixture = LoadFixture()
        local parameters = fixture.parameters
        local generated = PCGDungeonGenerator.Generate({
            seed = parameters.seed,
            roomCount = parameters.room_count,
            floorCount = parameters.floor_count,
            cellSize = parameters.cell_size,
        })
        log:Write(LOG_INFO, string.format("[PCGDungeonGeneration] actual valid=%s rooms=%s tets=%s edges=%s mst=%s loops=%s stairs=%s failedMst=%s",
            tostring(generated.valid), tostring(generated.roomCount),
            tostring(generated.delaunay and #generated.delaunay.tets),
            tostring(generated.delaunay and #generated.delaunay.edges),
            tostring(generated.graph and #generated.graph.mstEdges),
            tostring(generated.graph and #generated.graph.loopEdges),
            tostring(generated.astar and generated.astar.stairCount),
            tostring(generated.astar and generated.astar.failedMstPaths)))
        Check(generated.valid, "default float32 generation failed: " .. tostring(generated.error))
        Check(generated.roomCount == 22 and generated.astar.stairCount == 26,
            "default legacy reference room/stair counts were not reproduced")
        CheckStairContracts(generated.astar, "default")
        Check(generated.layout.attempts == fixture.layout.attempts,
            string.format("room attempts differ: Lua=%d legacy reference=%d",
                generated.layout.attempts, fixture.layout.attempts))
        CheckVector(generated.layout.gridCells, fixture.layout.grid_cells, "grid_cells")
        CheckVector(generated.layout.spaceMin, fixture.layout.space_min, "space_min")
        CheckVector(generated.layout.spaceMax, fixture.layout.space_max, "space_max")
        Check(#generated.rooms == #fixture.layout.rooms, "room count differs")
        for index, expected in ipairs(fixture.layout.rooms) do
            local actual = generated.rooms[index]
            Check(actual.id == expected.id and actual.floor == expected.floor,
                "room identity differs at index " .. index)
            CheckVector(actual.position, expected.position, "room position " .. expected.id)
            CheckVector(actual.size, expected.size, "room size " .. expected.id)
        end

        Check(#generated.delaunay.tets == #fixture.delaunay.tetrahedra,
            string.format("Delaunay tet count differs: Lua=%d legacy reference=%d",
                #generated.delaunay.tets, #fixture.delaunay.tetrahedra))
        local expectedTets = {}
        for _, tet in ipairs(fixture.delaunay.tetrahedra) do expectedTets[SortedTetKey(tet)] = true end
        for _, tet in ipairs(generated.delaunay.tets) do
            Check(expectedTets[SortedTetKey(tet)], "unexpected Delaunay tet " .. SortedTetKey(tet))
        end
        Check(#generated.delaunay.edges == #fixture.delaunay.edges,
            string.format("Delaunay edge count differs: Lua=%d legacy reference=%d",
                #generated.delaunay.edges, #fixture.delaunay.edges))
        for index, expected in ipairs(fixture.delaunay.edges) do
            local actual = generated.delaunay.edges[index]
            Check(actual.a == expected.a and actual.b == expected.b,
                string.format("Delaunay edge %d differs: Lua=%d-%d legacy reference=%d-%d",
                    index, actual.a, actual.b, expected.a, expected.b))
            Check(actual.sourcePrimitive == expected.source_primitive,
                "Delaunay primitive number differs at edge " .. index)
        end

        Check(#generated.graph.mstEdges == #fixture.graph.mst_edges, "MST edge count differs")
        for index, expected in ipairs(fixture.graph.mst_edges) do
            local actual = generated.graph.mstEdges[index]
            Check(actual.a == expected.a and actual.b == expected.b,
                string.format("MST edge %d differs: Lua=%d-%d legacy reference=%d-%d",
                    index, actual.a, actual.b, expected.a, expected.b))
        end
        Check(#generated.graph.loopEdges == #fixture.graph.loop_edges, "loop edge count differs")
        for index, expected in ipairs(fixture.graph.loop_edges) do
            local actual = generated.graph.loopEdges[index]
            Check(actual.a == expected.a and actual.b == expected.b,
                string.format("loop edge %d differs: Lua=%d-%d legacy reference=%d-%d",
                    index, actual.a, actual.b, expected.a, expected.b))
        end

        CheckIntegerArray(generated.astar.cellState, fixture.astar.cell_state, "cell_state")
        CheckIntegerArray(generated.astar.roomOwner, fixture.astar.room_owner, "room_owner")
        CheckIntegerArray(generated.astar.stairwellOwner, fixture.astar.stairwell_owner,
            "stairwell_owner")
        CheckIntegerArray(generated.astar.stairLandingPairs, fixture.astar.stair_landing_pairs,
            "stair_landing_pairs")
        CheckIntegerArray(generated.astar.successfulRoomPairs, fixture.astar.successful_room_pairs,
            "successful_room_pairs")
        Check(generated.astar.successfulPaths == fixture.astar.successful_paths
                and generated.astar.failedPaths == fixture.astar.failed_paths,
            "A* path counts differ")
        Check(generated.astar.doorwayCount == fixture.astar.doorway_count,
            "A* doorway count differs")
        Check(#generated.astar.doors == #fixture.astar.doors, "A* doorway array length differs")
        for index, expected in ipairs(fixture.astar.doors) do
            local actual = generated.astar.doors[index]
            Check(actual.source_room_id == expected.room_id
                    and actual.source_connection_id == expected.connection_id,
                "doorway relation differs at index " .. index)
            CheckVector(actual.position, expected.position, "doorway position " .. index)
            CheckVector(actual.normal, expected.normal, "doorway normal " .. index)
        end

        -- These cases contain A* score ties that diverge when Lua keeps its
        -- native double precision instead of matching legacy reference float32 floats.
        local precisionCases = {
            { seed = 3, paths = 35, stairs = 33, corridors = 99, doors = 70 },
            { seed = 9, paths = 34, stairs = 32, corridors = 124, doors = 68 },
            { seed = 13, paths = 33, stairs = 32, corridors = 100, doors = 66 },
            { seed = 15, paths = 33, stairs = 27, corridors = 96, doors = 70 },
            { seed = 17, paths = 37, stairs = 38, corridors = 140, doors = 74 },
            { seed = 18, paths = 37, stairs = 31, corridors = 128, doors = 74 },
        }
        for _, expected in ipairs(precisionCases) do
            local precisionResult = PCGDungeonGenerator.Generate({
                seed = expected.seed,
                roomCount = parameters.room_count,
                floorCount = parameters.floor_count,
                cellSize = parameters.cell_size,
            })
            Check(precisionResult.valid, "precision case failed for seed " .. expected.seed)
            local astar = precisionResult.astar
            Check(astar.successfulPaths == expected.paths
                    and astar.stairCount == expected.stairs
                    and astar.corridorCellCount == expected.corridors
                    and astar.doorwayCount == expected.doors,
                string.format(
                    "A* float parity differs for seed %d: paths=%d stairs=%d corridors=%d doors=%d",
                    expected.seed, astar.successfulPaths, astar.stairCount,
                    astar.corridorCellCount, astar.doorwayCount))
            CheckStairContracts(astar, "seed " .. expected.seed)
        end

        local repeatResult = PCGDungeonGenerator.Generate({
            seed = parameters.seed, roomCount = parameters.room_count,
            floorCount = parameters.floor_count, cellSize = parameters.cell_size,
        })
        Check(repeatResult.valid and repeatResult.hash == generated.hash,
            "same seed did not reproduce the same topology")
        local alternate = PCGDungeonGenerator.Generate({
            seed = parameters.seed + 1, roomCount = parameters.room_count,
            floorCount = parameters.floor_count, cellSize = parameters.cell_size,
        })
        Check(alternate.hash ~= generated.hash, "different seed did not change the topology")
        local passMessage = string.format(
            "[PCGDungeonGeneration] PASS rooms=%d delaunay=%d mst=%d loops=%d stairs=%d doors=%d hash=%s",
            generated.roomCount, #generated.delaunay.edges, #generated.graph.mstEdges,
            #generated.graph.loopEdges, generated.astar.stairCount,
            generated.astar.doorwayCount, generated.hash)
        ErrorExit(passMessage, 0)
    end, debug.traceback)
    if not ok then
        ErrorExit("[PCGDungeonGeneration] FAIL\n" .. tostring(errorMessage), 1)
        return
    end
end
