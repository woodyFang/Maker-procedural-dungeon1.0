local PCGDungeonAStar = {}

local EMPTY = 0
local ROOM = 1
local CORRIDOR = 2
local STAIR = 3
local HEADROOM = 4

-- Quantize scores to float32 so route tie-breaking remains deterministic.
local function Float32(value)
    return string.unpack("f", string.pack("f", value))
end

local INFINITY = Float32(1e30)
local EXISTING_PATH_COST = Float32(0.2)
local STAIR_MOVE_COST = Float32(4.5)

local function V(x, y, z) return { x or 0, y or 0, z or 0 } end
local function Sub(a, b) return V(a[1] - b[1], a[2] - b[2], a[3] - b[3]) end
local function Length2(a) return a[1] * a[1] + a[2] * a[2] + a[3] * a[3] end

local function GridIndex(x, y, z, nx, nz)
    return x + nx * (z + nz * y)
end

local function GridCoordinates(index, nx, nz)
    local x = index % nx
    local remainder = index // nx
    local z = remainder % nz
    local y = remainder // nz
    return x, y, z
end

local function InsideGrid(x, y, z, nx, ny, nz)
    return x >= 0 and x < nx and y >= 0 and y < ny and z >= 0 and z < nz
end

local function CellCenter(index, nx, nz, worldMin, cellSize)
    local x, y, z = GridCoordinates(index, nx, nz)
    return V(worldMin[1] + (x + 0.5) * cellSize,
        worldMin[2] + (y + 0.5) * cellSize,
        worldMin[3] + (z + 0.5) * cellSize)
end

local function PositionToGrid(position, nx, ny, nz, worldMin, cellSize)
    local x = math.floor((position[1] - worldMin[1]) / cellSize)
    local y = math.floor((position[2] - worldMin[2]) / cellSize)
    local z = math.floor((position[3] - worldMin[3]) / cellSize)
    if not InsideGrid(x, y, z, nx, ny, nz) then return -1 end
    return GridIndex(x, y, z, nx, nz)
end

local function Heuristic(fromCell, toCell, nx, nz)
    local ax, ay, az = GridCoordinates(fromCell, nx, nz)
    local bx, by, bz = GridCoordinates(toCell, nx, nz)
    return Float32(EXISTING_PATH_COST
        * (math.abs(ax - bx) + math.abs(ay - by) + math.abs(az - bz)))
end

local function TraversalCost(state, owner, startRoom, goalRoom)
    if state == EMPTY then return 1.0 end
    if state == CORRIDOR then return EXISTING_PATH_COST end
    if state == ROOM then
        if owner == startRoom or owner == goalRoom then return 1.0 end
        return 12.0
    end
    return INFINITY
end

local function StairCells(fromCell, toCell, nx, nz)
    local ax, ay, az = GridCoordinates(fromCell, nx, nz)
    local bx, by, bz = GridCoordinates(toCell, nx, nz)
    local directionX = bx == ax and 0 or (bx > ax and 1 or -1)
    local directionZ = bz == az and 0 or (bz > az and 1 or -1)
    local lowerY, upperY = math.min(ay, by), math.max(ay, by)
    local cells = {}
    for step = 1, 2 do
        local x, z = ax + directionX * step, az + directionZ * step
        cells[#cells + 1] = GridIndex(x, lowerY, z, nx, nz)
        cells[#cells + 1] = GridIndex(x, upperY, z, nx, nz)
    end
    return cells
end

local function Contains(values, target)
    for _, value in ipairs(values) do if value == target then return true end end
    return false
end

local function ConflictsWithCurrentPath(currentCell, testCells, parents, parentMove, nx, nz)
    local node, guard, maximum = currentCell, 0, #parents
    while node >= 0 and guard <= maximum do
        if Contains(testCells, node) then return true end
        local previous = parents[node + 1]
        if previous >= 0 and parentMove[node + 1] == 1 then
            for _, occupied in ipairs(StairCells(previous, node, nx, nz)) do
                if Contains(testCells, occupied) then return true end
            end
        end
        node = previous
        guard = guard + 1
    end
    return false
end

local function OrderedConnections(layout, graph)
    local remaining, ordered = {}, {}
    for _, edge in ipairs(graph.edges or {}) do remaining[#remaining + 1] = edge end
    while #remaining > 0 do
        local bestPosition, bestPriority = 1, -INFINITY
        for index, edge in ipairs(remaining) do
            local a, b = layout.rooms[edge.a + 1], layout.rooms[edge.b + 1]
            local floorChange = a and b and math.abs(a.position[2] - b.position[2]) or 0
            local priority = (edge.isMst and 10000 or 0) + floorChange * 100
            if priority > bestPriority then bestPosition, bestPriority = index, priority end
        end
        ordered[#ordered + 1] = table.remove(remaining, bestPosition)
    end
    return ordered
end

local function AddDoor(doors, roomPosition, outsidePosition, cellSize, roomId, connectionId)
    local direction = Sub(outsidePosition, roomPosition)
    direction[2] = 0
    local length = math.sqrt(Length2(direction))
    local normal = length > 1e-8 and V(direction[1] / length, 0, direction[3] / length) or V(0, 0, 1)
    doors[#doors + 1] = {
        position = V(roomPosition[1] + normal[1] * cellSize * 0.5,
            roomPosition[2] - cellSize * 0.5,
            roomPosition[3] + normal[3] * cellSize * 0.5),
        normal = normal,
        source_room_id = roomId,
        source_connection_id = connectionId,
        source_cell_type = 5,
    }
end

-- The stair roles are oriented from the lower landing to the upper landing,
-- independently of the direction in which this A* connection was searched.
-- role 0/1 are the two lower-floor steps (near lower/upper landing), and
-- role 2/3 are their upper-floor headroom cells.
local function ValidateStairTopology(cellState, stairwellOwner, stairRole,
    stairLandingPairs, nx, ny, nz, stairCount)
    local cellsByStair = {}
    for cell = 0, nx * ny * nz - 1 do
        local stairwell = stairwellOwner[cell + 1]
        if stairwell and stairwell >= 0 then
            local bucket = cellsByStair[stairwell]
            if not bucket then bucket = {}; cellsByStair[stairwell] = bucket end
            bucket[#bucket + 1] = cell
        end
    end

    local errors = {}
    local function Error(stairwell, message)
        errors[#errors + 1] = string.format("stairwell %d: %s", stairwell, message)
    end
    local function State(cell)
        return cell >= 0 and cellState[cell + 1] or nil
    end
    local function SameCell(a, b)
        return a and b and a == b
    end

    for stairwell = 0, stairCount - 1 do
        local bucket = cellsByStair[stairwell] or {}
        local byRole = {}
        for _, cell in ipairs(bucket) do
            local role = stairRole[cell + 1]
            if byRole[role] then Error(stairwell, "duplicate stair role " .. tostring(role)) end
            byRole[role] = cell
        end
        if #bucket ~= 4 then Error(stairwell, "must occupy exactly 4 cells, got " .. #bucket) end
        for _, role in ipairs({ 0, 1, 2, 3 }) do
            if not byRole[role] then Error(stairwell, "missing stair role " .. role) end
        end

        local lowerA, lowerB = byRole[0], byRole[1]
        local upperA, upperB = byRole[2], byRole[3]
        if lowerA and lowerB and upperA and upperB then
            local ax, ay, az = GridCoordinates(lowerA, nx, nz)
            local bx, by, bz = GridCoordinates(lowerB, nx, nz)
            local cx, cy, cz = GridCoordinates(upperA, nx, nz)
            local dx, dz = bx - ax, bz - az
            if math.abs(dx) + math.abs(dz) ~= 1 or ay ~= by then
                Error(stairwell, "physical stair cells are not adjacent on one floor")
            end
            if cx ~= ax or cz ~= az or cy ~= ay + 1 then
                Error(stairwell, "headroom role 2 does not sit above physical role 0")
            end
            local dx3, dy3, dz3 = GridCoordinates(upperB, nx, nz)
            if dx3 ~= bx or dz3 ~= bz or dy3 ~= by + 1 then
                Error(stairwell, "headroom role 3 does not sit above physical role 1")
            end
            for _, cell in ipairs(bucket) do
                local state = State(cell)
                if state ~= STAIR and state ~= HEADROOM then
                    Error(stairwell, "occupied cell " .. cell .. " has non-stair state")
                end
            end

            local lowerLanding = GridIndex(ax - dx, ay, az - dz, nx, nz)
            local upperLanding = GridIndex(bx + dx, by + 1, bz + dz, nx, nz)
            if not InsideGrid(ax - dx, ay, az - dz, nx, ny, nz)
                or State(lowerLanding) ~= CORRIDOR then
                Error(stairwell, "lower landing is not a corridor cell")
            end
            if not InsideGrid(bx + dx, by + 1, bz + dz, nx, ny, nz)
                or State(upperLanding) ~= CORRIDOR then
                Error(stairwell, "upper landing is not a corridor cell")
            end

            local pairLower = stairLandingPairs[stairwell * 2 + 1]
            local pairUpper = stairLandingPairs[stairwell * 2 + 2]
            if not pairLower or not pairUpper
                or not ((SameCell(pairLower, lowerLanding) and SameCell(pairUpper, upperLanding))
                    or (SameCell(pairLower, upperLanding) and SameCell(pairUpper, lowerLanding))) then
                Error(stairwell, "landing pair does not match the two corridor endpoints")
            end
        end
    end
    return #errors == 0, errors
end

local function FindRoot(parent, index)
    while parent[index] ~= index do index = parent[index] end
    return index
end

function PCGDungeonAStar.Generate(layout, graph)
    local grid = layout.gridCells
    local nx = math.max(1, math.floor(grid[1] + 0.5))
    local ny = math.max(1, math.floor(grid[2] + 0.5))
    local nz = math.max(1, math.floor(grid[3] + 0.5))
    local cellCount = nx * ny * nz
    local cellSize = layout.cellSize
    local worldMin = layout.spaceMin
    local rooms = layout.rooms or {}

    local cellState, roomOwner, stairwellOwner = {}, {}, {}
    local stairRole, connectionOwner = {}, {}
    for cell = 0, cellCount - 1 do
        cellState[cell + 1], roomOwner[cell + 1], stairwellOwner[cell + 1] = EMPTY, -1, -1
        stairRole[cell + 1], connectionOwner[cell + 1] = -1, -1
        local center = CellCenter(cell, nx, nz, worldMin, cellSize)
        for _, room in ipairs(rooms) do
            local minimum, maximum = room.minimum, room.maximum
            if center[1] >= minimum[1] and center[1] < maximum[1]
                and center[2] >= minimum[2] and center[2] < maximum[2]
                and center[3] >= minimum[3] and center[3] < maximum[3] then
                cellState[cell + 1], roomOwner[cell + 1] = ROOM, room.id
                break
            end
        end
    end

    local ordered = OrderedConnections(layout, graph)
    local successfulPaths, failedPaths, failedMstPaths, failedLoopPaths = 0, 0, 0, 0
    local stairCount, corridorLinkCount, removedRoomSegments, expandedNodes = 0, 0, 0, 0
    local successfulPairs, successfulRoutes, stairLandingPairs, doors = {}, {}, {}, {}
    local directions = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

    for connectionIndex, edge in ipairs(ordered) do
        local connection = connectionIndex - 1
        local startRoomData, goalRoomData = rooms[edge.a + 1], rooms[edge.b + 1]
        local startRoom, goalRoom = startRoomData.id, goalRoomData.id
        local startCell = PositionToGrid(startRoomData.position, nx, ny, nz, worldMin, cellSize)
        local goalCell = PositionToGrid(goalRoomData.position, nx, ny, nz, worldMin, cellSize)
        local routeFailed = startCell < 0 or goalCell < 0
        local parents, parentMove, path

        if not routeFailed then
            local gScore, fScore, openSet = {}, {}, {}
            parents, parentMove = {}, {}
            for cell = 0, cellCount - 1 do
                gScore[cell + 1], fScore[cell + 1] = INFINITY, INFINITY
                parents[cell + 1], parentMove[cell + 1], openSet[cell + 1] = -1, 0, false
            end
            gScore[startCell + 1], fScore[startCell + 1], openSet[startCell + 1] = 0,
                Heuristic(startCell, goalCell, nx, nz), true
            local found = startCell == goalCell
            local searchIterations, maximumIterations = 0, cellCount * 32

            while not found and searchIterations < maximumIterations do
                local current, bestF = -1, INFINITY
                for cell = 0, cellCount - 1 do
                    if openSet[cell + 1] and fScore[cell + 1] < bestF then
                        current, bestF = cell, fScore[cell + 1]
                    end
                end
                if current < 0 then break end
                if current == goalCell then found = true; break end
                openSet[current + 1] = false
                searchIterations, expandedNodes = searchIterations + 1, expandedNodes + 1
                local cx, cy, cz = GridCoordinates(current, nx, nz)

                for _, direction in ipairs(directions) do
                    local tx, ty, tz = cx + direction[1], cy, cz + direction[2]
                    if InsideGrid(tx, ty, tz, nx, ny, nz) then
                        local neighbor = GridIndex(tx, ty, tz, nx, nz)
                        local state = cellState[neighbor + 1]
                        if state ~= STAIR and state ~= HEADROOM
                            and not ConflictsWithCurrentPath(current, { neighbor }, parents, parentMove, nx, nz) then
                            local candidateG = Float32(gScore[current + 1]
                                + TraversalCost(state, roomOwner[neighbor + 1], startRoom, goalRoom))
                            if candidateG < gScore[neighbor + 1] then
                                parents[neighbor + 1], parentMove[neighbor + 1] = current, 0
                                gScore[neighbor + 1] = candidateG
                                fScore[neighbor + 1] = Float32(candidateG
                                    + Heuristic(neighbor, goalCell, nx, nz))
                                openSet[neighbor + 1] = true
                            end
                        end
                    end
                end

                for vertical = -1, 1, 2 do
                    local ty = cy + vertical
                    if ty >= 0 and ty < ny then
                        for _, direction in ipairs(directions) do
                            local tx, tz = cx + direction[1] * 3, cz + direction[2] * 3
                            if InsideGrid(tx, ty, tz, nx, ny, nz) then
                                local neighbor = GridIndex(tx, ty, tz, nx, nz)
                                local currentState, neighborState = cellState[current + 1], cellState[neighbor + 1]
                                if (currentState == EMPTY or currentState == CORRIDOR)
                                    and (neighborState == EMPTY or neighborState == CORRIDOR) then
                                    local occupied = StairCells(current, neighbor, nx, nz)
                                    local blocked = false
                                    for _, cell in ipairs(occupied) do
                                        if cellState[cell + 1] ~= EMPTY then blocked = true; break end
                                    end
                                    if not blocked then
                                        local testCells = { neighbor }
                                        for _, cell in ipairs(occupied) do testCells[#testCells + 1] = cell end
                                        if not ConflictsWithCurrentPath(current, testCells,
                                            parents, parentMove, nx, nz) then
                                            -- Match the two left-associative float additions in float32.
                                            local candidateG = Float32(
                                                Float32(gScore[current + 1] + STAIR_MOVE_COST)
                                                + TraversalCost(neighborState, roomOwner[neighbor + 1],
                                                    startRoom, goalRoom))
                                            if candidateG < gScore[neighbor + 1] then
                                                parents[neighbor + 1], parentMove[neighbor + 1] = current, 1
                                                gScore[neighbor + 1] = candidateG
                                                fScore[neighbor + 1] = Float32(candidateG
                                                    + Heuristic(neighbor, goalCell, nx, nz))
                                                openSet[neighbor + 1] = true
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if not found and parents[goalCell + 1] >= 0 then found = true end
            if found then
                local reverse, node, guard = {}, goalCell, 0
                while node >= 0 and guard <= cellCount do
                    reverse[#reverse + 1] = node
                    if node == startCell then break end
                    node, guard = parents[node + 1], guard + 1
                end
                if #reverse > 0 and reverse[#reverse] == startCell then
                    path = {}
                    for index = #reverse, 1, -1 do path[#path + 1] = reverse[index] end
                else routeFailed = true end
            else routeFailed = true end
        end

        if routeFailed then
            failedPaths = failedPaths + 1
            if edge.isMst then failedMstPaths = failedMstPaths + 1 else failedLoopPaths = failedLoopPaths + 1 end
        else
            local routeStairs = {}
            for _, cell in ipairs(path) do
                if cellState[cell + 1] == EMPTY then cellState[cell + 1] = CORRIDOR end
            end
            for step = 2, #path do
                local fromCell, toCell = path[step - 1], path[step]
                local fromPosition = CellCenter(fromCell, nx, nz, worldMin, cellSize)
                local toPosition = CellCenter(toCell, nx, nz, worldMin, cellSize)
                local fromIsRoom = cellState[fromCell + 1] == ROOM
                local toIsRoom = cellState[toCell + 1] == ROOM
                if parentMove[toCell + 1] == 1 then
                    cellState[fromCell + 1], cellState[toCell + 1] = CORRIDOR, CORRIDOR
                    stairLandingPairs[#stairLandingPairs + 1] = fromCell
                    stairLandingPairs[#stairLandingPairs + 1] = toCell
                    local occupied = StairCells(fromCell, toCell, nx, nz)
                    -- StairCells is emitted in search order. Normalize its
                    -- roles to lower-landing -> upper-landing order so the
                    -- marker orientation stays correct when A* searches down.
                    local _, fromY = GridCoordinates(fromCell, nx, nz)
                    local _, toY = GridCoordinates(toCell, nx, nz)
                    local lowerCell = fromY < toY and fromCell or toCell
                    local upperCell = fromY < toY and toCell or fromCell
                    routeStairs[#routeStairs + 1] = {
                        stairwell_id = stairCount,
                        lower_cell = lowerCell,
                        upper_cell = upperCell,
                    }
                    local roles = fromY < toY and { 0, 2, 1, 3 } or { 1, 3, 0, 2 }
                    for index, cell in ipairs(occupied) do
                        cellState[cell + 1] = index % 2 == 1 and STAIR or HEADROOM
                        stairwellOwner[cell + 1] = stairCount
                        stairRole[cell + 1] = roles[index]
                        connectionOwner[cell + 1] = connection
                    end
                    if fromIsRoom then AddDoor(doors, fromPosition, toPosition,
                        cellSize, roomOwner[fromCell + 1], connection) end
                    if toIsRoom then AddDoor(doors, toPosition, fromPosition,
                        cellSize, roomOwner[toCell + 1], connection) end
                    stairCount = stairCount + 1
                else
                    if fromIsRoom and toIsRoom then
                        removedRoomSegments = removedRoomSegments + 1
                    else
                        if fromIsRoom then AddDoor(doors, fromPosition, toPosition,
                            cellSize, roomOwner[fromCell + 1], connection) end
                        if toIsRoom then AddDoor(doors, toPosition, fromPosition,
                            cellSize, roomOwner[toCell + 1], connection) end
                        corridorLinkCount = corridorLinkCount + 1
                    end
                end
            end
            successfulPaths = successfulPaths + 1
            successfulPairs[#successfulPairs + 1] = startRoom
            successfulPairs[#successfulPairs + 1] = goalRoom
            local routeCells = {}
            for index, cell in ipairs(path) do routeCells[index] = cell end
            successfulRoutes[#successfulRoutes + 1] = {
                connection_id = connection,
                a = edge.a,
                b = edge.b,
                cells = routeCells,
                stairs = routeStairs,
            }
        end
    end

    local componentParent = {}
    for room = 1, #rooms do componentParent[room] = room end
    for index = 1, #successfulPairs, 2 do
        local a, b = successfulPairs[index] + 1, successfulPairs[index + 1] + 1
        local rootA, rootB = FindRoot(componentParent, a), FindRoot(componentParent, b)
        if rootA ~= rootB then componentParent[rootB] = rootA end
    end
    local rootComponent = #rooms > 0 and FindRoot(componentParent, 1) or -1
    local unreachable = {}
    for room = 1, #rooms do
        local outside = PositionToGrid(rooms[room].position, nx, ny, nz, worldMin, cellSize) < 0
        if outside or FindRoot(componentParent, room) ~= rootComponent then
            unreachable[#unreachable + 1] = rooms[room].id
        end
    end

    local cells, corridorCellCount = {}, 0
    for cell = 0, cellCount - 1 do
        local state = cellState[cell + 1]
        if state ~= EMPTY then
            local x, y, z = GridCoordinates(cell, nx, nz)
            if state == CORRIDOR then corridorCellCount = corridorCellCount + 1 end
            cells[#cells + 1] = {
                id = cell,
                grid_index = cell,
                grid_coord = { x, y, z },
                position = CellCenter(cell, nx, nz, worldMin, cellSize),
                cell_type = state,
                room_id = roomOwner[cell + 1],
                floor_id = y,
                stairwell_id = stairwellOwner[cell + 1],
                stair_role = stairRole[cell + 1],
                connection_id = connectionOwner[cell + 1],
            }
        end
    end

    local allReachable = #rooms > 0 and #unreachable == 0
    local stairTopologyValid, stairTopologyErrors = ValidateStairTopology(
        cellState, stairwellOwner, stairRole, stairLandingPairs, nx, ny, nz, stairCount)
    local warning
    if #ordered == 0 then warning = "No dungeon graph edges were found"
    elseif not allReachable then warning = "Not every room is connected to room 0 by a carved route"
    elseif failedPaths > 0 then warning = "One or more graph connections could not be routed" end
    if not stairTopologyValid then
        warning = "One or more stairs violate the four-cell corridor landing contract"
            .. (stairTopologyErrors[1] and (": " .. stairTopologyErrors[1]) or "")
    end
    return {
        schemaVersion = 1,
        cells = cells,
        doors = doors,
        cellState = cellState,
        roomOwner = roomOwner,
        stairwellOwner = stairwellOwner,
        stairLandingPairs = stairLandingPairs,
        orderedEdges = ordered,
        successfulRoomPairs = successfulPairs,
        successfulRoutes = successfulRoutes,
        unreachableRoomIds = unreachable,
        allRoomsReachable = allReachable,
        connectedRoomCount = #rooms - #unreachable,
        successfulPaths = successfulPaths,
        failedPaths = failedPaths,
        failedMstPaths = failedMstPaths,
        failedLoopPaths = failedLoopPaths,
        stairCount = stairCount,
        stairCellCount = stairCount * 4,
        headroomCellCount = stairCount * 2,
        stairTopologyValid = stairTopologyValid,
        stairTopologyErrors = stairTopologyErrors,
        doorwayCount = #doors,
        corridorCellCount = corridorCellCount,
        corridorLinkCount = corridorLinkCount,
        removedRoomSegmentCount = removedRoomSegments,
        expandedNodes = expandedNodes,
        gridSize = V(nx, ny, nz),
        worldMin = V(worldMin[1], worldMin[2], worldMin[3]),
        cellSize = cellSize,
        warning = warning,
    }
end

return PCGDungeonAStar
