local MultiFloor = {}
local Themes = require("Config.Themes")
local StairContract = require("Generation.StairContract")

-- Authoritative floor-to-floor height in metres. Rendering, cameras, editor
-- overlays and stair connectors must all derive their vertical spacing from it.
MultiFloor.SOURCE_FLOOR_HEIGHT = 5.0
MultiFloor.FLOOR_HEIGHT = 5.0
MultiFloor.VERTICAL_SCALE = MultiFloor.FLOOR_HEIGHT / MultiFloor.SOURCE_FLOOR_HEIGHT
MultiFloor.MIN_FLOOR_HEIGHT = 2.5
MultiFloor.MAX_FLOOR_HEIGHT = 8.0
-- Six floors is a usability/performance recommendation, not a generation cap.
MultiFloor.RECOMMENDED_MAX_FLOORS = 6
MultiFloor.STAIR_TARGET_STEP_RISE = 0.25
MultiFloor.STAIR_REQUIRED_HEADROOM = StairContract.REQUIRED_HEADROOM
MultiFloor.STAIR_MIN_WIDTH = StairContract.MIN_WIDTH
MultiFloor.STAIR_MAX_WIDTH = StairContract.MAX_WIDTH
MultiFloor.STAIR_WIDTH_STEP = StairContract.WIDTH_STEP
MultiFloor.Tiles = { VOID = 0, FLOOR = 1, WALL = 2, POOL = 3 }

function MultiFloor.NormalizeFloorHeight(value)
    value = tonumber(value) or MultiFloor.FLOOR_HEIGHT
    return math.max(MultiFloor.MIN_FLOOR_HEIGHT, math.min(MultiFloor.MAX_FLOOR_HEIGHT, value))
end

local function Index(x, y, width)
    return y * width + x + 1
end

local function Coordinates(index, width)
    local zero = index - 1
    return zero % width, math.floor(zero / width)
end

local function InBounds(x, y, width, height)
    return x >= 0 and y >= 0 and x < width and y < height
end

local function FilledArray(size, value)
    local result = {}
    for i = 1, size do result[i] = value end
    return result
end

local function ApplyThemeCarving(layers, rooms, width, height, options)
    if options.settingKey ~= "dungeon" or not options.rng then return end
    local theme = Themes.Get(options.theme or "ancient")
    local function NearDoor(layer, x, y, distance)
        for oy = -distance, distance do
            for ox = -distance, distance do
                local nx, ny = x + ox, y + oy
                if InBounds(nx, ny, width, height) and layer.doorway[Index(nx, ny, width)] then return true end
            end
        end
        return false
    end
    for _, layer in ipairs(layers) do
        local rng = options.rngByFloor and options.rngByFloor[layer.floor + 1] or options.rng
        local pools = layer.pools
        if theme.pools and (theme.pools.amount or 0) > 0 then
            local candidates = {}
            for y = 1, height - 2 do
                for x = 1, width - 2 do
                    local cell = Index(x, y, width)
                    if layer.grid[cell] == MultiFloor.Tiles.WALL and not NearDoor(layer, x, y, 2) then
                        local adjacent = 0
                        if layer.grid[Index(x+1,y,width)] == MultiFloor.Tiles.FLOOR then adjacent = adjacent + 1 end
                        if layer.grid[Index(x-1,y,width)] == MultiFloor.Tiles.FLOOR then adjacent = adjacent + 1 end
                        if layer.grid[Index(x,y+1,width)] == MultiFloor.Tiles.FLOOR then adjacent = adjacent + 1 end
                        if layer.grid[Index(x,y-1,width)] == MultiFloor.Tiles.FLOOR then adjacent = adjacent + 1 end
                        if adjacent == 1 then candidates[#candidates + 1] = { x=x, y=y } end
                    end
                end
            end
            rng:Shuffle(candidates)
            local target = math.floor(#candidates * theme.pools.amount + 0.5)
            for _, candidate in ipairs(candidates) do
                if #pools >= target then break end
                local close = false
                for _, pool in ipairs(pools) do
                    if math.max(math.abs(pool.x-candidate.x), math.abs(pool.y-candidate.y)) < 3 then close=true break end
                end
                if not close then
                    layer.grid[Index(candidate.x,candidate.y,width)] = MultiFloor.Tiles.POOL
                    pools[#pools+1] = candidate
                end
            end
        end
        if theme.pools and theme.pools.pits then
            for _, room in ipairs(rooms) do
                if room.floor == layer.floor and (room.type == "combat" or room.type == "elite")
                    and not room.lake and not room.grave then
                    local remaining = math.min(theme.pools.pits, math.floor(room.w*room.h/45)+1)
                    local guard = 0
                    while remaining > 0 and guard < 40 do
                        guard = guard + 1
                        local x = rng:Int(math.floor(room.cx-room.w*0.5)+2, math.ceil(room.cx+room.w*0.5)-2)
                        local y = rng:Int(math.floor(room.cy-room.h*0.5)+2, math.ceil(room.cy+room.h*0.5)-2)
                        local cell = Index(x,y,width)
                        local valid = InBounds(x,y,width,height) and layer.roomId[cell] == room.id
                            and layer.grid[cell] == MultiFloor.Tiles.FLOOR and not layer.doorway[cell]
                            and not (x == room.cx and y == room.cy)
                        for oy=-1,1 do for ox=-1,1 do
                            if not valid or layer.grid[Index(x+ox,y+oy,width)] ~= MultiFloor.Tiles.FLOOR then valid=false end
                        end end
                        for _, pool in ipairs(pools) do
                            if math.max(math.abs(pool.x-x),math.abs(pool.y-y)) < 4 then valid=false break end
                        end
                        if valid then
                            layer.grid[cell]=MultiFloor.Tiles.POOL
                            pools[#pools+1]={x=x,y=y}
                            remaining=remaining-1
                        end
                    end
                end
            end
        end
        for _, room in ipairs(rooms) do
            if room.floor == layer.floor and room.lake then
                for y=math.floor(room.cy-room.h*0.5)+2,math.ceil(room.cy+room.h*0.5)-2 do
                    for x=math.floor(room.cx-room.w*0.5)+2,math.ceil(room.cx+room.w*0.5)-2 do
                        if InBounds(x,y,width,height) then
                            local cell=Index(x,y,width)
                            local solid=false
                            if layer.roomId[cell] == room.id and layer.grid[cell] == MultiFloor.Tiles.FLOOR and not layer.doorway[cell] then
                                for oy=-1,1 do for ox=-1,1 do
                                    if layer.grid[Index(x+ox,y+oy,width)] ~= MultiFloor.Tiles.FLOOR then solid=true end
                                end end
                                if not solid then
                                    layer.lakeMask[cell]=true
                                    layer.lakeCells[#layer.lakeCells+1]={x=x,y=y}
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function MultiFloor.CreateLayer(floor, width, height)
    local total = width * height
    return {
        floor = floor,
        grid = FilledArray(total, MultiFloor.Tiles.VOID),
        roomId = FilledArray(total, 0),
        corridor = {},
        corridorOwner = {},
        doorway = {},
        stairMask = {},
        stairwellMask = {},
        stairClearance = {},
        stairLanding = {},
        stairWallMask = {},
        stairNoWallMask = {},
        stairOwner = {},
        sweptClearance = {},
        openingBoundary = {},
        slabOpening = {},
        bfs = FilledArray(total, -1),
        maxBfs = 0,
        props = {},
        spawns = {},
        torches = {},
        pools = {},
        lakeMask = {},
        lakeCells = {},
        arches = {},
    }
end

function MultiFloor.NormalizeStairWidth(width)
    return StairContract.NormalizeWidth(width)
end

local function StairGridSpan(width)
    return StairContract.GridSpan(width)
end

local function StairLateralCenterOffset(width, preservedOffset)
    return StairContract.LateralCenterOffset(width, preservedOffset)
end

local function WidthOffsets(width, lateralCenterOffset)
    return StairContract.WidthOffsets(width, lateralCenterOffset)
end

local function RoomDoorPoint(a, b, margin)
    margin = margin or 1
    local dx = b.cx - a.cx
    local dy = b.cy - a.cy
    local halfWidth = math.max(1, a.w * 0.5 - margin)
    local halfHeight = math.max(1, a.h * 0.5 - margin)
    if math.abs(dx) / halfWidth >= math.abs(dy) / halfHeight then
        return {
            x = math.floor(a.cx + (dx >= 0 and halfWidth or -halfWidth) + 0.5),
            y = math.floor(a.cy + math.max(-halfHeight, math.min(halfHeight, dy)) + 0.5),
            side = dx >= 0 and "east" or "west",
        }
    end
    return {
        x = math.floor(a.cx + math.max(-halfWidth, math.min(halfWidth, dx)) + 0.5),
        y = math.floor(a.cy + (dy >= 0 and halfHeight or -halfHeight) + 0.5),
        side = dy >= 0 and "south" or "north",
    }
end

local function DoorSpecPoint(room, spec)
    if not room or not spec then return nil end
    local side = tostring(spec.side or "east")
    if side == "n" then side = "north" end
    if side == "s" then side = "south" end
    if side == "w" then side = "west" end
    if side == "e" then side = "east" end
    local offset = math.max(-0.82, math.min(0.82, tonumber(spec.offset) or 0))
    if side == "north" then return { x = room.cx + offset * room.w * 0.5, y = room.cy - room.h * 0.5, side = side } end
    if side == "south" then return { x = room.cx + offset * room.w * 0.5, y = room.cy + room.h * 0.5, side = side } end
    if side == "west" then return { x = room.cx - room.w * 0.5, y = room.cy + offset * room.h * 0.5, side = side } end
    return { x = room.cx + room.w * 0.5, y = room.cy + offset * room.h * 0.5, side = "east" }
end

local function SimplifyCells(cells, width)
    if #cells == 0 then return {} end
    local firstX, firstY = Coordinates(cells[1], width)
    local points = { { x = firstX, y = firstY } }
    local lastDx, lastDy = 0, 0
    for i = 2, #cells do
        local ax, ay = Coordinates(cells[i - 1], width)
        local bx, by = Coordinates(cells[i], width)
        local dx, dy = bx - ax, by - ay
        if i == 2 then
            lastDx, lastDy = dx, dy
        elseif dx ~= lastDx or dy ~= lastDy then
            points[#points + 1] = { x = ax, y = ay }
            lastDx, lastDy = dx, dy
        end
    end
    local endX, endY = Coordinates(cells[#cells], width)
    local last = points[#points]
    if not last or last.x ~= endX or last.y ~= endY then
        points[#points + 1] = { x = endX, y = endY }
    end
    return points
end

local function HeapPush(heapNodes, heapScores, node, score)
    local index = #heapNodes + 1
    while index > 1 do
        local parent = math.floor(index / 2)
        if heapScores[parent] <= score then break end
        heapNodes[index] = heapNodes[parent]
        heapScores[index] = heapScores[parent]
        index = parent
    end
    heapNodes[index] = node
    heapScores[index] = score
end

local function HeapPop(heapNodes, heapScores)
    local firstNode = heapNodes[1]
    local lastNode = table.remove(heapNodes)
    local lastScore = table.remove(heapScores)
    if #heapNodes > 0 then
        local index = 1
        while true do
            local left = index * 2
            local right = left + 1
            if left > #heapNodes then break end
            local child = left
            if right <= #heapNodes and heapScores[right] < heapScores[left] then child = right end
            if heapScores[child] >= lastScore then break end
            heapNodes[index] = heapNodes[child]
            heapScores[index] = heapScores[child]
            index = child
        end
        heapNodes[index] = lastNode
        heapScores[index] = lastScore
    end
    return firstNode
end

function MultiFloor.RouteAStar(layer, startPoint, goalPoint, options)
    options = options or {}
    local width = assert(options.width, "RouteAStar requires width")
    local height = assert(options.height, "RouteAStar requires height")
    local sx = math.max(0, math.min(width - 1, math.floor(startPoint.x + 0.5)))
    local sy = math.max(0, math.min(height - 1, math.floor(startPoint.y + 0.5)))
    local gx = math.max(0, math.min(width - 1, math.floor(goalPoint.x + 0.5)))
    local gy = math.max(0, math.min(height - 1, math.floor(goalPoint.y + 0.5)))
    local startIndex = Index(sx, sy, width)
    local goalIndex = Index(gx, gy, width)
    local startRoomId = options.startRoomId or 0
    local goalRoomId = options.goalRoomId or 0

    -- Match Three's route search: direction is part of the state. A cell-only
    -- A* considers every equally short staircase-shaped path equivalent and
    -- can retain many alternating turns. Directional states let us charge for
    -- bends without discarding a straighter arrival at the same cell.
    local directions = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    local directionCount = #directions
    local function StateIndex(cell, direction)
        return (cell - 1) * directionCount + direction
    end
    local function StateCell(state)
        return math.floor((state - 1) / directionCount) + 1
    end
    local function StateDirection(state)
        return ((state - 1) % directionCount) + 1
    end

    local corridorCost = options.corridorCost or 0.75
    local turnCost = options.turnCost or 0.85
    local reverseCost = options.reverseCost or 1.5
    local scores = {}
    local parents = {}
    local closed = {}
    local heapNodes, heapScores = {}, {}
    local function Heuristic(x, y)
        return (math.abs(x - gx) + math.abs(y - gy)) * 0.35
    end
    for direction = 1, directionCount do
        local state = StateIndex(startIndex, direction)
        scores[state] = 0
        HeapPush(heapNodes, heapScores, state, Heuristic(sx, sy))
    end
    local goalState = nil
    local guard = 0

    while #heapNodes > 0 and guard < width * height * directionCount * 4 do
        guard = guard + 1
        local currentState = HeapPop(heapNodes, heapScores)
        if not closed[currentState] then
            closed[currentState] = true
            local current = StateCell(currentState)
            local previousDirection = StateDirection(currentState)
            if current == goalIndex then
                goalState = currentState
                break
            end
            local cx, cy = Coordinates(current, width)
            for directionIndex, direction in ipairs(directions) do
                local nx, ny = cx + direction[1], cy + direction[2]
                if InBounds(nx, ny, width, height) then
                    local nextIndex = Index(nx, ny, width)
                    local nextState = StateIndex(nextIndex, directionIndex)
                    -- stairwellMask includes rectangular filler corners. Three
                    -- only blocks physical treads, landings, clearance and the
                    -- slab opening so those ordinary floor corners remain usable.
                    local stairBlocked = layer.stairMask[nextIndex] or layer.stairClearance[nextIndex]
                        or layer.stairLanding[nextIndex] or layer.slabOpening[nextIndex]
                    local contractBlocked = options.blockedCells and options.blockedCells[nextIndex]
                    if not closed[nextState]
                        and (not contractBlocked or nextIndex == goalIndex or nextIndex == startIndex)
                        and (options.allowStairs or not stairBlocked or nextIndex == goalIndex or nextIndex == startIndex) then
                        local roomId = layer.roomId[nextIndex] or 0
                        local step = layer.corridor[nextIndex] and corridorCost or 1.0
                        if options.preferredRoomId and roomId ~= options.preferredRoomId
                            and not layer.corridor[nextIndex] then
                            step = step + 8
                        end
                        if roomId > 0 and roomId ~= startRoomId and roomId ~= goalRoomId then
                            step = step + 25
                        elseif roomId > 0 then
                            step = step + 2.5
                        end
                        if math.abs(nx - sx) + math.abs(ny - sy) <= 4
                            or math.abs(nx - gx) + math.abs(ny - gy) <= 4 then
                            step = math.max(0.35, step - 0.4)
                        end
                        if directionIndex ~= previousDirection then
                            local previous = directions[previousDirection]
                            local reverse = direction[1] == -previous[1] and direction[2] == -previous[2]
                            step = step + (reverse and reverseCost or turnCost)
                        end
                        local nextScore = (scores[currentState] or math.huge) + step
                        if nextScore < (scores[nextState] or math.huge) then
                            scores[nextState] = nextScore
                            parents[nextState] = currentState
                            HeapPush(heapNodes, heapScores, nextState, nextScore + Heuristic(nx, ny))
                        end
                    end
                end
            end
        end
    end

    if not goalState then return nil end
    local reversed = {}
    local currentState = goalState
    while currentState do
        local current = StateCell(currentState)
        reversed[#reversed + 1] = current
        if current == startIndex then break end
        currentState = parents[currentState]
    end
    if reversed[#reversed] ~= startIndex then return nil end
    local cells = {}
    for i = #reversed, 1, -1 do cells[#cells + 1] = reversed[i] end
    return { cells = cells, points = SimplifyCells(cells, width), cost = scores[goalState] }
end

local function StampCell(layer, x, y, width, owner, mapWidth, mapHeight)
    for _, ox in ipairs(WidthOffsets(width)) do
        for _, oy in ipairs(WidthOffsets(width)) do
            local nx, ny = x + ox, y + oy
            if InBounds(nx, ny, mapWidth, mapHeight) then
                local cell = Index(nx, ny, mapWidth)
                layer.grid[cell] = MultiFloor.Tiles.FLOOR
                layer.corridor[cell] = true
                if not layer.corridorOwner[cell] then layer.corridorOwner[cell] = owner end
            end
        end
    end
end

local function CarveCells(layer, cells, width, owner, mapWidth, mapHeight)
    for _, cell in ipairs(cells) do
        local x, y = Coordinates(cell, mapWidth)
        StampCell(layer, x, y, width, owner, mapWidth, mapHeight)
    end
end

local function CarvePolyline(layer, points, corridorWidth, owner, mapWidth, mapHeight)
    local cells, seen = {}, {}
    for index = 1, #points - 1 do
        local a, b = points[index], points[index + 1]
        local span = math.max(math.abs(b.x - a.x), math.abs(b.y - a.y))
        local steps = math.max(1, math.ceil(span * 2))
        for step = 0, steps do
            local t = step / steps
            local x = math.floor(a.x + (b.x - a.x) * t + 0.5)
            local y = math.floor(a.y + (b.y - a.y) * t + 0.5)
            if InBounds(x, y, mapWidth, mapHeight) then
                local cell = Index(x, y, mapWidth)
                if not seen[cell] then
                    seen[cell] = true
                    cells[#cells + 1] = cell
                end
            end
        end
    end
    CarveCells(layer, cells, corridorWidth, owner, mapWidth, mapHeight)
    return cells
end

local function MarkDoor(layer, point, width, height)
    local x, y = math.floor(point.x + 0.5), math.floor(point.y + 0.5)
    if InBounds(x, y, width, height) then layer.doorway[Index(x, y, width)] = true end
end

local function RasterizeRooms(layers, rooms, width, height)
    for _, room in ipairs(rooms) do
        local layer = layers[room.floor + 1]
        local x0 = math.max(0, math.floor(room.cx - room.w * 0.5))
        local x1 = math.min(width - 1, math.ceil(room.cx + room.w * 0.5))
        local y0 = math.max(0, math.floor(room.cy - room.h * 0.5))
        local y1 = math.min(height - 1, math.ceil(room.cy + room.h * 0.5))
        for y = y0, y1 do
            for x = x0, x1 do
                if math.abs(x - room.cx) <= math.max(1, room.w * 0.5)
                    and math.abs(y - room.cy) <= math.max(1, room.h * 0.5) then
                    local cell = Index(x, y, width)
                    layer.grid[cell] = MultiFloor.Tiles.FLOOR
                    layer.roomId[cell] = room.id
                end
            end
        end
    end
end

function MultiFloor.CompactRoomsByFloor(rooms, floorCount, gap, scale, iterations, onlyFloor)
    gap = gap or 6
    scale = scale or 0.72
    iterations = iterations or 300
    local before = {}
    for i, room in ipairs(rooms) do before[i] = { x = room.cx, y = room.cy } end

    for floor = 0, floorCount - 1 do
        if onlyFloor ~= nil and floor ~= onlyFloor then goto continue_floor end
        local floorRooms = {}
        local cx, cy = 0, 0
        for _, room in ipairs(rooms) do
            if room.floor == floor then
                floorRooms[#floorRooms + 1] = room
                cx, cy = cx + room.cx, cy + room.cy
            end
        end
        if #floorRooms > 0 then
            cx, cy = cx / #floorRooms, cy / #floorRooms
            for _, room in ipairs(floorRooms) do
                room.cx = (room.cx - cx) * scale
                room.cy = (room.cy - cy) * scale
            end
            for _ = 1, iterations do
                local moved = false
                for i = 1, #floorRooms do
                    for j = i + 1, #floorRooms do
                        local a, b = floorRooms[i], floorRooms[j]
                        local overlapX = (a.w + b.w + gap) * 0.5 - math.abs(a.cx - b.cx)
                        local overlapY = (a.h + b.h + gap) * 0.5 - math.abs(a.cy - b.cy)
                        if overlapX > 0 and overlapY > 0 then
                            moved = true
                            if overlapX < overlapY then
                                local sign = a.cx <= b.cx and -1 or 1
                                a.cx = a.cx + sign * overlapX * 0.5
                                b.cx = b.cx - sign * overlapX * 0.5
                            else
                                local sign = a.cy <= b.cy and -1 or 1
                                a.cy = a.cy + sign * overlapY * 0.5
                                b.cy = b.cy - sign * overlapY * 0.5
                            end
                        end
                    end
                end
                if not moved then break end
            end
        end
        ::continue_floor::
    end
    local movedRooms = 0
    for i, room in ipairs(rooms) do
        room.cx = math.floor(room.cx + 0.5)
        room.cy = math.floor(room.cy + 0.5)
        if room.cx ~= math.floor(before[i].x + 0.5) or room.cy ~= math.floor(before[i].y + 0.5) then
            movedRooms = movedRooms + 1
        end
    end
    return movedRooms
end

local function StairStripCells(width, height, from, direction, firstStep, lastStep, stairWidth, lateralCenterOffset)
    local cells = {}
    local perpendicular = { x = -direction.y, y = direction.x }
    for step = firstStep, lastStep do
        for _, offset in ipairs(WidthOffsets(stairWidth, lateralCenterOffset)) do
            local x = from.x + direction.x * step + perpendicular.x * offset
            local y = from.y + direction.y * step + perpendicular.y * offset
            if not InBounds(x, y, width, height) then return nil end
            cells[#cells + 1] = Index(x, y, width)
        end
    end
    return cells
end

local function StairwellWidthOffsets(stairWidth, sideClearance, lateralCenterOffset)
    local base = WidthOffsets(stairWidth, lateralCenterOffset)
    sideClearance = math.max(0, math.floor((sideClearance or 1) + 0.5))
    local result = {}
    for offset = base[1] - sideClearance, base[#base] + sideClearance do result[#result + 1] = offset end
    return result
end

local function StairStripCellsWithOffsets(width, height, from, direction, firstStep, lastStep, offsets)
    local cells, perpendicular = {}, { x = -direction.y, y = direction.x }
    for step = firstStep, lastStep do
        for _, offset in ipairs(offsets) do
            local x = from.x + direction.x * step + perpendicular.x * offset
            local y = from.y + direction.y * step + perpendicular.y * offset
            if not InBounds(x, y, width, height) then return nil end
            cells[#cells + 1] = Index(x, y, width)
        end
    end
    return cells
end

local function UniqueCells(...)
    local result, seen = {}, {}
    for _, group in ipairs({ ... }) do
        for _, cell in ipairs(group or {}) do
            if not seen[cell] then seen[cell] = true; result[#result + 1] = cell end
        end
    end
    return result
end

local function RectangularEnvelope(cells, width, height)
    if not cells or #cells == 0 then return nil end
    local minX, maxX, minY, maxY = width - 1, 0, height - 1, 0
    for _, cell in ipairs(cells) do
        local x, y = Coordinates(cell, width)
        minX, maxX = math.min(minX, x), math.max(maxX, x)
        minY, maxY = math.min(minY, y), math.max(maxY, y)
    end
    local result = {}
    for y = minY, maxY do for x = minX, maxX do result[#result + 1] = Index(x, y, width) end end
    return result
end

local function StairTurnDirection(direction)
    local nextNames = { east = "south", south = "west", west = "north", north = "east" }
    return { x = -direction.y, y = direction.x, name = nextNames[direction.name] }
end

local function NormalizeStairStyle(style)
    return style == "straight" and "straight" or "l-turn"
end

local function StairEndpoints(lower, direction, run, style)
    if NormalizeStairStyle(style) == "straight" then
        return nil, { x = lower.x + direction.x * run, y = lower.y + direction.y * run }, direction, run, 0
    end
    local firstRun = math.max(3, math.floor(run * 0.5))
    local secondRun = math.max(3, run - firstRun)
    local secondDirection = StairTurnDirection(direction)
    local turn = { x = lower.x + direction.x * firstRun, y = lower.y + direction.y * firstRun }
    return turn, { x = turn.x + secondDirection.x * secondRun,
        y = turn.y + secondDirection.y * secondRun }, secondDirection, firstRun, secondRun
end

local function StairRunCenter(point, direction, stairWidth, lateralCenterOffset)
    return StairContract.RunCenter(point, direction, stairWidth, lateralCenterOffset)
end

local function StairTurnPlatformMetrics(connector)
    return StairContract.TurnPlatformMetrics(connector)
end

local function VisualUpperCell(point, direction)
    return StairContract.VisualUpperCell(point, direction)
end

local function VisualPlatformCells(width, height, platform)
    if not platform then return nil end
    local firstX = math.ceil(platform.center.x - platform.visualSpan * 0.5 - 0.000000001)
    local firstY = math.ceil(platform.center.y - platform.visualSpan * 0.5 - 0.000000001)
    local result = {}
    for y = firstY, firstY + platform.gridSpan - 1 do
        for x = firstX, firstX + platform.gridSpan - 1 do
            if not InBounds(x, y, width, height) then return nil end
            result[#result + 1] = Index(x, y, width)
        end
    end
    return result
end

local function VisualStripCells(width, height, startPoint, endPoint, visualWidth)
    if not startPoint or not endPoint then return nil end
    local span, result = StairGridSpan(visualWidth), {}
    if math.abs(endPoint.x - startPoint.x) >= math.abs(endPoint.y - startPoint.y) then
        local firstX = math.ceil(math.min(startPoint.x, endPoint.x) - 0.000000001)
        local lastX = math.ceil(math.max(startPoint.x, endPoint.x) - 0.000000001) - 1
        local firstY = math.ceil((startPoint.y + endPoint.y) * 0.5 - visualWidth * 0.5 - 0.000000001)
        for y = firstY, firstY + span - 1 do for x = firstX, lastX do
            if not InBounds(x, y, width, height) then return nil end
            result[#result + 1] = Index(x, y, width)
        end end
    else
        local firstY = math.ceil(math.min(startPoint.y, endPoint.y) - 0.000000001)
        local lastY = math.ceil(math.max(startPoint.y, endPoint.y) - 0.000000001) - 1
        local firstX = math.ceil((startPoint.x + endPoint.x) * 0.5 - visualWidth * 0.5 - 0.000000001)
        for y = firstY, lastY do for x = firstX, firstX + span - 1 do
            if not InBounds(x, y, width, height) then return nil end
            result[#result + 1] = Index(x, y, width)
        end end
    end
    return result
end

local function StairTurnPadCells(width, height, turn, firstDirection, secondDirection, stairWidth)
    local result = {}
    local firstPerpendicular = { x = -firstDirection.y, y = firstDirection.x }
    local secondPerpendicular = { x = -secondDirection.y, y = secondDirection.x }
    for _, a in ipairs(WidthOffsets(stairWidth)) do
        for _, b in ipairs(WidthOffsets(stairWidth)) do
            local x = turn.x + firstPerpendicular.x * a + secondPerpendicular.x * b
            local y = turn.y + firstPerpendicular.y * a + secondPerpendicular.y * b
            if not InBounds(x, y, width, height) then return nil end
            result[#result + 1] = Index(x, y, width)
        end
    end
    return result
end

local function BuildStairContract(width, height, lower, direction, run, stairWidth, landingDepth, sideClearance,
    requestedStyle, preservedLateralCenterOffset, floorHeight, stepCount)
    return StairContract.Build({
        mapWidth = width,
        mapHeight = height,
        lower = lower,
        direction = direction,
        run = run,
        width = stairWidth,
        landingDepth = landingDepth,
        sideClearance = sideClearance,
        style = requestedStyle,
        lateralCenterOffset = preservedLateralCenterOffset,
        floorHeight = floorHeight,
        stepCount = stepCount,
        headroom = MultiFloor.STAIR_REQUIRED_HEADROOM,
        wallMode = "wall-backed",
    })
end


MultiFloor.StairRunCenter = StairRunCenter
MultiFloor.StairTurnPlatformMetrics = StairTurnPlatformMetrics
MultiFloor.StairVisualUpperCell = VisualUpperCell

local function StairContractClear(lowerLayer, upperLayer, contract, lowerRoomId, upperRoomId, allowRoomAdaptation)
    local function Blocked(layer, cell)
        return layer.stairMask[cell] or layer.stairwellMask[cell] or layer.stairClearance[cell]
            or layer.stairLanding[cell] or layer.stairWallMask[cell] or layer.slabOpening[cell]
    end
    for _, cell in ipairs(contract.sharedFootprintCells or {}) do
        if Blocked(lowerLayer, cell) or Blocked(upperLayer, cell) then return false end
        local lowerOwner, upperOwner = lowerLayer.roomId[cell] or 0, upperLayer.roomId[cell] or 0
        if not allowRoomAdaptation and lowerOwner > 0 and lowerOwner ~= lowerRoomId then return false end
        if not allowRoomAdaptation and upperOwner > 0 and upperOwner ~= upperRoomId then return false end
    end
    for _, cell in ipairs(contract.shaftCells) do
        local lowerOwner = lowerLayer.roomId[cell] or 0
        local upperOwner = upperLayer.roomId[cell] or 0
        -- Stacked rooms: the stair may live inside the two rooms it connects.
        -- Only foreign-room ownership is a conflict (matches reference).
        local roomConflict = (lowerOwner > 0 and lowerOwner ~= lowerRoomId)
            or (upperOwner > 0 and upperOwner ~= upperRoomId)
        if Blocked(lowerLayer, cell) or Blocked(upperLayer, cell)
            or lowerLayer.corridor[cell] or upperLayer.corridor[cell] or roomConflict then
            return false
        end
    end
    for _, cell in ipairs(contract.lowerLandingCells) do
        local owner = lowerLayer.roomId[cell] or 0
        if Blocked(lowerLayer, cell) or (owner > 0 and owner ~= lowerRoomId) then return false end
    end
    for _, cell in ipairs(contract.upperLandingCells) do
        local owner = upperLayer.roomId[cell] or 0
        if Blocked(upperLayer, cell) or (owner > 0 and owner ~= upperRoomId) then return false end
    end
    return true
end

local function DirectionByName(name)
    local directions = {
        east = { x = 1, y = 0, name = "east" },
        west = { x = -1, y = 0, name = "west" },
        south = { x = 0, y = 1, name = "south" },
        north = { x = 0, y = -1, name = "north" },
    }
    return directions[name]
end

local function ReserveStair(lowerLayer, upperLayer, contract, connectorId)
    contract.ownerId = connectorId
    for _, cell in ipairs(contract.sharedFootprintCells or {}) do
        for _, layer in ipairs({ lowerLayer, upperLayer }) do
            layer.corridor[cell] = nil
            layer.corridorOwner[cell] = nil
            layer.doorway[cell] = nil
            layer.stairwellMask[cell] = true
            layer.stairOwner[cell] = connectorId
        end
    end
    for _, cell in ipairs(contract.lowerNoWallCells or {}) do
        lowerLayer.stairNoWallMask[cell] = true
        lowerLayer.stairOwner[cell] = connectorId
    end
    for _, cell in ipairs(contract.upperNoWallCells or {}) do
        upperLayer.stairNoWallMask[cell] = true
        upperLayer.stairOwner[cell] = connectorId
    end
    for _, cell in ipairs(contract.lowerLandingCells) do
        lowerLayer.grid[cell] = MultiFloor.Tiles.FLOOR
        lowerLayer.corridor[cell] = true
        lowerLayer.corridorOwner[cell] = connectorId
        lowerLayer.stairLanding[cell] = true
        lowerLayer.stairOwner[cell] = connectorId
    end
    for _, cell in ipairs(contract.upperLandingCells) do
        upperLayer.grid[cell] = MultiFloor.Tiles.FLOOR
        upperLayer.corridor[cell] = true
        upperLayer.corridorOwner[cell] = connectorId
        upperLayer.stairLanding[cell] = true
        upperLayer.stairOwner[cell] = connectorId
    end
    local openingSet = StairContract.CellSet(contract.openingCells)
    for _, cell in ipairs(contract.shaftCells) do
        lowerLayer.grid[cell] = MultiFloor.Tiles.FLOOR
        lowerLayer.corridor[cell] = true
        lowerLayer.corridorOwner[cell] = connectorId
        lowerLayer.roomId[cell] = 0
        lowerLayer.stairMask[cell] = true
        lowerLayer.stairClearance[cell] = true
        lowerLayer.stairOwner[cell] = connectorId
        if not openingSet[cell] then
            upperLayer.grid[cell] = MultiFloor.Tiles.FLOOR
            upperLayer.roomId[cell] = 0
            upperLayer.stairOwner[cell] = connectorId
        end
    end
    for _, item in ipairs(contract.sweptClearanceCells or {}) do
        upperLayer.stairClearance[item.cell] = true
        upperLayer.sweptClearance[item.cell] = item
        upperLayer.stairOwner[item.cell] = connectorId
    end
    for _, cell in ipairs(contract.openingCells or {}) do
        upperLayer.grid[cell] = MultiFloor.Tiles.VOID
        upperLayer.corridor[cell] = nil
        upperLayer.corridorOwner[cell] = connectorId
        upperLayer.roomId[cell] = 0
        upperLayer.slabOpening[cell] = true
        upperLayer.stairOwner[cell] = connectorId
    end
    for _, edge in ipairs(contract.openingBoundaryEdges or {}) do
        upperLayer.openingBoundary[edge.key] = connectorId
    end
end

local function ConnectorCandidates(aDoor, bDoor, width, height, run, style)
    local result, seen = {}, {}
    local directions = {
        { x = 1, y = 0, name = "east" }, { x = -1, y = 0, name = "west" },
        { x = 0, y = 1, name = "south" }, { x = 0, y = -1, name = "north" },
    }
    local dx, dy = bDoor.x - aDoor.x, bDoor.y - aDoor.y
    local length = math.max(1, math.sqrt(dx * dx + dy * dy))
    local perpendicular = { x = -dy / length, y = dx / length }
    for step = 1, 9 do
        local t = step / 10
        for _, offset in ipairs({ 0, -4, 4, -8, 8, -12, 12, -16, 16 }) do
            local anchor = {
                x = math.floor(aDoor.x + dx * t + perpendicular.x * offset + 0.5),
                y = math.floor(aDoor.y + dy * t + perpendicular.y * offset + 0.5),
            }
            for _, direction in ipairs(directions) do
                local key = anchor.x .. ":" .. anchor.y .. ":" .. direction.name
                local _, upper = StairEndpoints(anchor, direction, run, style)
                local upperX, upperY = upper.x, upper.y
                if not seen[key] and InBounds(anchor.x, anchor.y, width, height)
                    and InBounds(upperX, upperY, width, height) then
                    seen[key] = true
                    result[#result + 1] = { lower = anchor, direction = direction }
                end
            end
        end
    end
    table.sort(result, function(a, b)
        local function Score(candidate)
            local _, upper = StairEndpoints(candidate.lower, candidate.direction, run, style)
            local ux, uy = upper.x, upper.y
            return math.abs(aDoor.x - candidate.lower.x) + math.abs(aDoor.y - candidate.lower.y)
                + math.abs(bDoor.x - ux) + math.abs(bDoor.y - uy)
        end
        local sa, sb = Score(a), Score(b)
        if sa ~= sb then return sa < sb end
        if a.lower.x ~= b.lower.x then return a.lower.x < b.lower.x end
        if a.lower.y ~= b.lower.y then return a.lower.y < b.lower.y end
        return a.direction.name < b.direction.name
    end)
    return result
end

-- Stacked/overlapping rooms prefer an in-footprint stairwell. Search the plan
-- overlap of the two rooms for anchors whose full reservation fits inside it.
local function OverlappingRoomCandidates(lowerRoom, upperRoom, width, height, run, stairWidth,
    landingDepth, style, lateralCenterOffset, floorHeight, stepCount)
    local result = {}
    local x0 = math.ceil(math.max(lowerRoom.cx - lowerRoom.w / 2, upperRoom.cx - upperRoom.w / 2))
    local x1 = math.floor(math.min(lowerRoom.cx + lowerRoom.w / 2, upperRoom.cx + upperRoom.w / 2))
    local y0 = math.ceil(math.max(lowerRoom.cy - lowerRoom.h / 2, upperRoom.cy - upperRoom.h / 2))
    local y1 = math.floor(math.min(lowerRoom.cy + lowerRoom.h / 2, upperRoom.cy + upperRoom.h / 2))
    if x1 < x0 or y1 < y0 then return result end
    local directions = {
        { x = 1, y = 0, name = "east" }, { x = -1, y = 0, name = "west" },
        { x = 0, y = 1, name = "south" }, { x = 0, y = -1, name = "north" },
    }
    for _, direction in ipairs(directions) do
        for y = y0, y1 do
            for x = x0, x1 do
                local contract = BuildStairContract(width, height, { x = x, y = y }, direction, run,
                    stairWidth, landingDepth, 0, style, lateralCenterOffset, floorHeight, stepCount)
                if contract then
                    local fits = true
                    for _, cell in ipairs(contract.sharedFootprintCells) do
                        local cx, cy = Coordinates(cell, width)
                        if cx < x0 or cx > x1 or cy < y0 or cy > y1 then fits = false; break end
                    end
                    if fits then
                        result[#result + 1] = { lower = { x = x, y = y }, direction = direction, sharedRoomOverlap = true }
                    end
                end
            end
        end
    end
    return result
end

local function PlaceConnector(edge, rooms, layers, width, height, connectorId, floorHeight)
    local roomA, roomB = rooms[edge.a], rooms[edge.b]
    local lowerRoom, upperRoom
    if roomA.floor < roomB.floor then lowerRoom, upperRoom = roomA, roomB else lowerRoom, upperRoom = roomB, roomA end
    local lowerLayer = layers[lowerRoom.floor + 1]
    local upperLayer = layers[upperRoom.floor + 1]
    local lowerDoor = RoomDoorPoint(lowerRoom, upperRoom)
    local upperDoor = RoomDoorPoint(upperRoom, lowerRoom)
    local spec = edge.stairSpec or {}
    local style = NormalizeStairStyle(spec.pending and (spec.previewStyle or spec.style) or spec.style)
    local requestedLength = spec.pending and spec.previewLength or spec.length
    floorHeight = MultiFloor.NormalizeFloorHeight(floorHeight)
    local run = math.max(6, math.floor((tonumber(requestedLength)
        or math.ceil(floorHeight / 0.5)) + 0.5))
    local stepCount = math.max(1, math.ceil(floorHeight / MultiFloor.STAIR_TARGET_STEP_RISE))
    local stepRise = floorHeight / stepCount
    local requestedWidth = spec.pending and spec.previewWidth or spec.width
    local stairWidth = StairContract.NormalizeWidth(
        tonumber(requestedWidth) or (edge.isCritical and 3 or 2))
    local requestedLanding = spec.pending and spec.previewLandingDepth or spec.landingDepth
    local landingDepth = math.max(1, math.min(4, math.floor((tonumber(requestedLanding) or 2) + 0.5)))
    local anchor = spec.pending and spec.previewAnchor or spec.anchor
    local direction = DirectionByName(spec.pending and spec.previewDirection or spec.direction)
    local pinned = anchor ~= nil and direction ~= nil
    local allowRoomAdaptation = pinned or spec.pending == true
        or lowerRoom.stairRoom == true or upperRoom.stairRoom == true
    local candidates
    if pinned then
        candidates = {{
            lower = { x = math.floor(anchor.x + 0.5), y = math.floor(anchor.y + 0.5) },
            direction = direction,
        }}
    else
        candidates = {}
        for _, candidate in ipairs(OverlappingRoomCandidates(lowerRoom, upperRoom, width, height, run,
            stairWidth, landingDepth, style, spec.lateralCenterOffset, floorHeight, stepCount)) do
            candidates[#candidates + 1] = candidate
        end
        for _, candidate in ipairs(ConnectorCandidates(lowerDoor, upperDoor, width, height, run, style)) do
            candidates[#candidates + 1] = candidate
        end
        -- Prefer in-footprint overlap anchors, then door proximity, and cap the
        -- list (like the reference's 48) so the A* legality loop stays bounded
        -- even when a large room overlap yields thousands of raw anchors.
        local function Proximity(candidate)
            local _, upper = StairEndpoints(candidate.lower, candidate.direction, run, style)
            return math.abs(lowerDoor.x - candidate.lower.x) + math.abs(lowerDoor.y - candidate.lower.y)
                + math.abs(upperDoor.x - upper.x) + math.abs(upperDoor.y - upper.y)
        end
        table.sort(candidates, function(a, b)
            local ao, bo = a.sharedRoomOverlap and 1 or 0, b.sharedRoomOverlap and 1 or 0
            if ao ~= bo then return ao > bo end
            local pa, pb = Proximity(a), Proximity(b)
            if pa ~= pb then return pa < pb end
            if a.lower.x ~= b.lower.x then return a.lower.x < b.lower.x end
            if a.lower.y ~= b.lower.y then return a.lower.y < b.lower.y end
            return a.direction.name < b.direction.name
        end)
        while #candidates > 48 do table.remove(candidates) end
    end
    local legal = {}

    for _, candidate in ipairs(candidates) do
        local sideClearance = (pinned or allowRoomAdaptation) and 0 or 1
        local contract = BuildStairContract(width, height, candidate.lower, candidate.direction, run,
            stairWidth, landingDepth, sideClearance, style, spec.lateralCenterOffset,
            floorHeight, stepCount)
        if contract
            and StairContractClear(lowerLayer, upperLayer, contract, lowerRoom.id, upperRoom.id, allowRoomAdaptation) then
            -- The upper approach sits beyond the future slab opening. Without
            -- reserving the proposed shaft during A*, a shortest path can cross
            -- back over it and then be severed when ReserveStair cuts the hole.
            local proposedShaft = {}
            for _, cell in ipairs(contract.shaftCells) do proposedShaft[cell] = true end
            local lowerRoute = MultiFloor.RouteAStar(lowerLayer, lowerDoor, contract.lowerApproach, {
                width = width, height = height, startRoomId = lowerRoom.id, goalRoomId = lowerRoom.id,
                blockedCells = proposedShaft,
            })
            local upperRoute = MultiFloor.RouteAStar(upperLayer, contract.upperApproach, upperDoor, {
                width = width, height = height, startRoomId = upperRoom.id, goalRoomId = upperRoom.id,
                blockedCells = proposedShaft,
            })
            if lowerRoute and upperRoute then
                -- Prefer an in-footprint stairwell when the two rooms overlap.
                local sharedRoomOverlap = true
                for _, cell in ipairs(contract.sharedFootprintCells) do
                    if (lowerLayer.roomId[cell] or 0) ~= lowerRoom.id
                        or (upperLayer.roomId[cell] or 0) ~= upperRoom.id then
                        sharedRoomOverlap = false
                        break
                    end
                end
                local score = lowerRoute.cost + upperRoute.cost + run + landingDepth * 2
                    - (sharedRoomOverlap and 1000 or 0)
                legal[#legal + 1] = {
                    contract = contract, lowerRoute = lowerRoute, upperRoute = upperRoute,
                    score = score, sharedRoomOverlap = sharedRoomOverlap,
                }
            end
        end
    end
    table.sort(legal, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        if a.contract.lower.x ~= b.contract.lower.x then return a.contract.lower.x < b.contract.lower.x end
        if a.contract.lower.y ~= b.contract.lower.y then return a.contract.lower.y < b.contract.lower.y end
        return a.contract.direction.name < b.contract.direction.name
    end)
    local candidateCount = #legal
    local requestedIndex = pinned and 1 or math.max(1, math.floor((tonumber(spec.candidateIndex) or 0) + 1))
    local selectedIndex = candidateCount > 0 and ((requestedIndex - 1) % candidateCount) + 1 or nil
    local best = selectedIndex and legal[selectedIndex] or nil
    if not best then return nil end

    CarveCells(lowerLayer, best.lowerRoute.cells, stairWidth, edge.id, width, height)
    CarveCells(upperLayer, best.upperRoute.cells, stairWidth, edge.id, width, height)
    ReserveStair(lowerLayer, upperLayer, best.contract, connectorId)
    MarkDoor(lowerLayer, lowerDoor, width, height)
    MarkDoor(upperLayer, upperDoor, width, height)
    lowerLayer.doorway[Index(best.contract.lower.x, best.contract.lower.y, width)] = true
    upperLayer.doorway[Index(best.contract.upper.x, best.contract.upper.y, width)] = true

    local connector = {
        id = connectorId, edgeId = edge.id, kind = "stairs",
        style = style,
        fromFloor = lowerRoom.floor, toFloor = upperRoom.floor,
        lower = best.contract.lower, turn = best.contract.turn, upper = best.contract.upper,
        lowerApproach = best.contract.lowerApproach, upperApproach = best.contract.upperApproach,
        direction = best.contract.direction.name,
        directionVector = { x = best.contract.direction.x, y = best.contract.direction.y },
        secondDirection = best.contract.secondDirection.name,
        secondDirectionVector = { x = best.contract.secondDirection.x, y = best.contract.secondDirection.y },
        width = stairWidth, length = run, rise = floorHeight,
        lateralCenterOffset = best.contract.lateralCenterOffset,
        stepCount = stepCount, stepRise = stepRise, treadDepth = run / stepCount,
        firstRun = best.contract.firstRun, secondRun = best.contract.secondRun,
        firstFlightSteps = best.contract.firstFlightSteps,
        secondFlightSteps = best.contract.secondFlightSteps,
        landingDepth = landingDepth,
        openingCells = best.contract.openingCells,
        slabOpeningCells = best.contract.openingCells,
        shaftCells = best.contract.shaftCells,
        headroomCells = best.contract.headroomCells,
        sweptClearanceCells = best.contract.sweptClearanceCells,
        stairwellInteriorCells = best.contract.stairwellInteriorCells,
        lowerLandingCells = best.contract.lowerLandingCells,
        upperLandingCells = best.contract.upperLandingCells,
        sharedFootprintCells = best.contract.sharedFootprintCells,
        wallMode = best.contract.wallMode,
        contract = best.contract,
        lowerRoute = best.lowerRoute.points, upperRoute = best.upperRoute.points,
        mode = spec.mode or "stable-auto", candidateIndex = selectedIndex - 1,
        candidateCount = candidateCount, stairId = spec.id,
    }
    edge.connectorId = connectorId
    edge.lowerRoute = connector.lowerRoute
    edge.upperRoute = connector.upperRoute
    edge.route = nil
    edge.carvedWidth = stairWidth
    local committedAnchor, committedDirection, committedLength, committedStyle, committedWidth = nil, nil, nil, nil, nil
    local previewAnchor, previewDirection, previewLength, previewStyle, previewWidth = nil, nil, nil, nil, nil
    if spec.pending then
        previewAnchor = { x = best.contract.lower.x, y = best.contract.lower.y }
        previewDirection, previewLength, previewStyle, previewWidth = best.contract.direction.name, run, style, stairWidth
    else
        committedAnchor = { x = best.contract.lower.x, y = best.contract.lower.y }
        committedDirection, committedLength, committedStyle, committedWidth = best.contract.direction.name, run, style, stairWidth
    end
    edge.stairSpec = {
        id = spec.id, mode = spec.mode or "stable-auto", pending = spec.pending == true,
        anchor = committedAnchor, previewAnchor = previewAnchor,
        direction = committedDirection, previewDirection = previewDirection,
        style = committedStyle or style, previewStyle = previewStyle,
        width = committedWidth or stairWidth, previewWidth = previewWidth,
        length = committedLength, previewLength = previewLength,
        landingDepth = landingDepth, previewLandingDepth = spec.pending and landingDepth or nil,
        lateralCenterOffset = best.contract.lateralCenterOffset,
        manualPreview = spec.manualPreview == true, candidateIndex = selectedIndex - 1,
        candidateCount = candidateCount, invalid = false,
    }
    return connector
end

local function BuildWalls(layer, width, height)
    local floorCells = {}
    for cell, tile in ipairs(layer.grid) do
        if tile == MultiFloor.Tiles.FLOOR then floorCells[#floorCells + 1] = cell end
    end
    for _, cell in ipairs(floorCells) do
        local x, y = Coordinates(cell, width)
        for oy = -1, 1 do
            for ox = -1, 1 do
                local nx, ny = x + ox, y + oy
                if InBounds(nx, ny, width, height) then
                    local neighbor = Index(nx, ny, width)
                    if layer.grid[neighbor] == MultiFloor.Tiles.VOID and not layer.slabOpening[neighbor]
                        and not layer.stairNoWallMask[neighbor] then
                        layer.grid[neighbor] = MultiFloor.Tiles.WALL
                    end
                end
            end
        end
    end
end

-- Robust representative floor cell for a room: its center if walkable, else the
-- nearest same-room floor cell, else any floor cell in its bounding box. Rooms
-- whose center is consumed by a slab opening must not be treated as unreachable.
local function RoomAccessCell(room, layer, width, height)
    if not room or not layer then return nil end
    local cx = math.max(0, math.min(width - 1, math.floor((room.cx or 0) + 0.5)))
    local cy = math.max(0, math.min(height - 1, math.floor((room.cy or 0) + 0.5)))
    local center = Index(cx, cy, width)
    if layer.grid[center] == MultiFloor.Tiles.FLOOR and not layer.slabOpening[center] then
        return center
    end
    local best, bestDistance = nil, math.huge
    for cell = 1, width * height do
        if layer.grid[cell] == MultiFloor.Tiles.FLOOR and not layer.slabOpening[cell]
            and layer.roomId[cell] == room.id then
            local x, y = Coordinates(cell, width)
            local d = math.abs(x - cx) + math.abs(y - cy)
            if d < bestDistance then best, bestDistance = cell, d end
        end
    end
    if best then return best end
    if room.w and room.h then
        local x0 = math.max(0, math.floor(room.cx - room.w / 2))
        local x1 = math.min(width - 1, math.ceil(room.cx + room.w / 2))
        local y0 = math.max(0, math.floor(room.cy - room.h / 2))
        local y1 = math.min(height - 1, math.ceil(room.cy + room.h / 2))
        for y = y0, y1 do
            for x = x0, x1 do
                local cell = Index(x, y, width)
                if layer.grid[cell] == MultiFloor.Tiles.FLOOR and not layer.slabOpening[cell] then
                    local d = math.abs(x - cx) + math.abs(y - cy)
                    if d < bestDistance then best, bestDistance = cell, d end
                end
            end
        end
    end
    return best
end

function MultiFloor.Validate(layers, rooms, connectors, entranceId, width, height)
    local floorSize = width * height
    local distance = FilledArray(floorSize * #layers, -1)
    local transitions = {}
    local invalidConnectors = {}
    local function GlobalIndex(floor, cell) return floor * floorSize + cell end
    local function AddTransition(from, to)
        transitions[from] = transitions[from] or {}
        transitions[from][#transitions[from] + 1] = to
    end

    for _, connector in ipairs(connectors) do
        local lowerLayer = layers[connector.fromFloor + 1]
        local upperLayer = layers[connector.toFloor + 1]
        local lowerCell = Index(connector.lower.x, connector.lower.y, width)
        local upperCell = Index(connector.upper.x, connector.upper.y, width)
        local valid = connector.toFloor - connector.fromFloor == 1
            and lowerLayer and upperLayer
            and lowerLayer.stairLanding[lowerCell] and upperLayer.stairLanding[upperCell]
            and lowerLayer.grid[lowerCell] == MultiFloor.Tiles.FLOOR
            and upperLayer.grid[upperCell] == MultiFloor.Tiles.FLOOR
        if valid then
            for _, cell in ipairs(connector.openingCells) do
                if not lowerLayer.stairMask[cell] or not upperLayer.slabOpening[cell]
                    or not upperLayer.stairClearance[cell] then
                    valid = false
                    break
                end
            end
        end
        local audit = connector.contract and StairContract.Audit(
            connector.contract, lowerLayer, upperLayer, MultiFloor.Tiles) or {
                contractComplete = false, traversable = false, slabsComplete = false,
                wallsComplete = false, reachable = false, pass = false,
                reasons = { "missing-contract" },
            }
        audit.pass = audit.pass and valid
        if not valid and #audit.reasons == 0 then audit.reasons[#audit.reasons + 1] = "invalid-endpoint" end
        connector.audit = audit
        if not audit.pass then invalidConnectors[#invalidConnectors + 1] = connector.id end
        local lowerGlobal = GlobalIndex(connector.fromFloor, lowerCell)
        local upperGlobal = GlobalIndex(connector.toFloor, upperCell)
        if audit.pass then
            AddTransition(lowerGlobal, upperGlobal)
            AddTransition(upperGlobal, lowerGlobal)
        end
    end

    local entranceRoom = entranceId and rooms[entranceId]
    if not entranceRoom then
        for _, layer in ipairs(layers) do
            layer.bfs = FilledArray(floorSize, -1)
            layer.maxBfs = 0
        end
        return {
            valid = #invalidConnectors == 0, distance = distance, reach = 0,
            unreachableRooms = {}, unreachableConnectors = {}, invalidConnectors = invalidConnectors,
            stairAudits = {}, passedStairs = 0, totalStairs = #connectors,
        }
    end
    local startCell = RoomAccessCell(entranceRoom, layers[entranceRoom.floor + 1], width, height)
        or Index(entranceRoom.cx, entranceRoom.cy, width)
    local start = GlobalIndex(entranceRoom.floor, startCell)
    local queue, head = { start }, 1
    distance[start] = 0
    local reach = 0
    local directions = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        reach = reach + 1
        local floor = math.floor((current - 1) / floorSize)
        local localCell = current - floor * floorSize
        local x, y = Coordinates(localCell, width)
        for _, direction in ipairs(directions) do
            local nx, ny = x + direction[1], y + direction[2]
            if InBounds(nx, ny, width, height) then
                local nextCell = Index(nx, ny, width)
                local nextGlobal = GlobalIndex(floor, nextCell)
                if distance[nextGlobal] < 0 and layers[floor + 1].grid[nextCell] == MultiFloor.Tiles.FLOOR then
                    distance[nextGlobal] = distance[current] + 1
                    queue[#queue + 1] = nextGlobal
                end
            end
        end
        for _, nextGlobal in ipairs(transitions[current] or {}) do
            if distance[nextGlobal] < 0 then
                distance[nextGlobal] = distance[current] + 1
                queue[#queue + 1] = nextGlobal
            end
        end
    end

    local unreachableRooms = {}
    for _, room in ipairs(rooms) do
        if room.roleHint ~= "secret" then
            local cell = RoomAccessCell(room, layers[room.floor + 1], width, height)
                or Index(room.cx, room.cy, width)
            if distance[GlobalIndex(room.floor, cell)] < 0 then unreachableRooms[#unreachableRooms + 1] = room.id end
        end
    end
    local unreachableConnectors = {}
    for _, connector in ipairs(connectors) do
        local lower = GlobalIndex(connector.fromFloor, Index(connector.lower.x, connector.lower.y, width))
        local upper = GlobalIndex(connector.toFloor, Index(connector.upper.x, connector.upper.y, width))
        if distance[lower] < 0 or distance[upper] < 0 then
            unreachableConnectors[#unreachableConnectors + 1] = connector.id
        end
    end

    for _, layer in ipairs(layers) do
        local maxDistance = 0
        local offset = layer.floor * floorSize
        for cell = 1, floorSize do
            layer.bfs[cell] = distance[offset + cell]
            maxDistance = math.max(maxDistance, layer.bfs[cell])
        end
        layer.maxBfs = maxDistance
    end
    local stairAudits, passedStairs = {}, 0
    for _, connector in ipairs(connectors) do
        local audit = connector.audit or { pass = false, reachable = false, reasons = { "missing-audit" } }
        local lower = GlobalIndex(connector.fromFloor, Index(connector.lower.x, connector.lower.y, width))
        local upper = GlobalIndex(connector.toFloor, Index(connector.upper.x, connector.upper.y, width))
        audit.reachable = distance[lower] >= 0 and distance[upper] >= 0
        audit.pass = audit.pass and audit.reachable
        if not audit.reachable then audit.reasons[#audit.reasons + 1] = "stair-endpoint-unreachable" end
        if audit.pass then passedStairs = passedStairs + 1 end
        stairAudits[#stairAudits + 1] = { id = connector.id, audit = audit }
    end
    return {
        valid = #unreachableRooms == 0 and #unreachableConnectors == 0 and #invalidConnectors == 0,
        distance = distance, reach = reach,
        unreachableRooms = unreachableRooms,
        unreachableConnectors = unreachableConnectors,
        invalidConnectors = invalidConnectors,
        stairAudits = stairAudits,
        passedStairs = passedStairs,
        totalStairs = #connectors,
    }
end

function MultiFloor.Build(options)
    local width, height = options.width, options.height
    local floorHeight = MultiFloor.NormalizeFloorHeight(options.floorHeight)
    local rooms, edges = options.rooms, options.edges
    local layers = {}
    for floor = 0, options.floorCount - 1 do
        layers[#layers + 1] = MultiFloor.CreateLayer(floor, width, height)
    end
    RasterizeRooms(layers, rooms, width, height)

    local activeEdges, errors = {}, {}
    for index, edge in ipairs(edges) do
        edge.id = edge.id or index
        local difference = math.abs(rooms[edge.a].floor - rooms[edge.b].floor)
        if difference == 0 then
            edge.kind = "corridor"
            edge.floor = rooms[edge.a].floor
            activeEdges[#activeEdges + 1] = edge
        elseif difference == 1 then
            edge.kind = "stairs"
            edge.floor = nil
            activeEdges[#activeEdges + 1] = edge
        elseif not edge.isLoop or edge.isManual then
            errors[#errors + 1] = "edge " .. edge.id .. " crosses " .. difference .. " floors"
        end
    end
    table.sort(activeEdges, function(a, b)
        local function Priority(edge)
            local roomA, roomB = rooms[edge.a], rooms[edge.b]
            local isStair = roomA and roomB and roomA.floor ~= roomB.floor
            -- Finish each floor's corridor network before reserving stair
            -- shafts. A stair is allowed to adjust its landing, but must not
            -- make an otherwise valid same-floor corridor unroutable.
            local touchesChangedFloor = isStair and options.changedFloor ~= nil
                and (roomA.floor == options.changedFloor or roomB.floor == options.changedFloor)
            local base = isStair and (touchesChangedFloor and 8 or 4) or 0
            if edge.isCritical then return base end
            if not edge.isLoop then return base + 1 end
            if not edge.isManual then return base + 2 end
            return base + 3
        end
        local pa, pb = Priority(a), Priority(b)
        return pa == pb and a.id < b.id or pa < pb
    end)

    local connectors = {}
    for _, edge in ipairs(activeEdges) do
        local roomA, roomB = rooms[edge.a], rooms[edge.b]
        if edge.kind == "corridor" then
            local layer = layers[edge.floor + 1]
            local startPoint = DoorSpecPoint(roomA, edge.doorA) or RoomDoorPoint(roomA, roomB)
            local goalPoint = DoorSpecPoint(roomB, edge.doorB) or RoomDoorPoint(roomB, roomA)
            local corridorWidth = math.max(1, math.min(6,
                math.floor((edge.width or (edge.isCritical and 3 or 2)) + 0.5)))
            local route = nil
            if edge.isEditor and edge.bends and #edge.bends > 0 then
                local points = { startPoint }
                for _, bend in ipairs(edge.bends) do points[#points + 1] = { x = bend.x, y = bend.y } end
                points[#points + 1] = goalPoint
                route = { points = points, cells = CarvePolyline(layer, points, corridorWidth, edge.id, width, height) }
            else
                route = MultiFloor.RouteAStar(layer, startPoint, goalPoint, {
                    width = width, height = height, startRoomId = roomA.id, goalRoomId = roomB.id,
                })
                if route then CarveCells(layer, route.cells, corridorWidth, edge.id, width, height) end
            end
            if route then
                MarkDoor(layer, startPoint, width, height)
                MarkDoor(layer, goalPoint, width, height)
                local centerOffset = corridorWidth % 2 == 0 and 0.5 or 0
                layer.arches[#layer.arches + 1] = {
                    x = startPoint.x + ((startPoint.side == "north" or startPoint.side == "south") and centerOffset or 0),
                    y = startPoint.y + ((startPoint.side == "east" or startPoint.side == "west") and centerOffset or 0),
                    anchorX = startPoint.x, anchorY = startPoint.y, side = startPoint.side,
                    len = corridorWidth, roomId = roomA.id,
                }
                layer.arches[#layer.arches + 1] = {
                    x = goalPoint.x + ((goalPoint.side == "north" or goalPoint.side == "south") and centerOffset or 0),
                    y = goalPoint.y + ((goalPoint.side == "east" or goalPoint.side == "west") and centerOffset or 0),
                    anchorX = goalPoint.x, anchorY = goalPoint.y, side = goalPoint.side,
                    len = corridorWidth, roomId = roomB.id,
                }
                edge.route = route.points
                edge.carvedWidth = corridorWidth
            else
                errors[#errors + 1] = "edge " .. edge.id .. " has no A* route"
            end
        else
            local connector = nil
            local alternates = edge.stairAlternates or { { a = edge.a, b = edge.b } }
            for _, pair in ipairs(alternates) do
                edge.a, edge.b = pair.a, pair.b
                connector = PlaceConnector(edge, rooms, layers, width, height, #connectors + 1, floorHeight)
                if connector then break end
            end
            if connector then connectors[#connectors + 1] = connector
            else errors[#errors + 1] = "edge " .. edge.id .. " has no legal stair candidate" end
        end
    end
    for _, layer in ipairs(layers) do BuildWalls(layer, width, height) end
    ApplyThemeCarving(layers, rooms, width, height, options)
    for _, connector in ipairs(connectors) do
        local lowerLayer = layers[connector.fromFloor + 1]
        local upperLayer = layers[connector.toFloor + 1]
        StairContract.FinalizeProtection(connector.contract, lowerLayer, upperLayer, MultiFloor.Tiles)
        for _, cell in ipairs(connector.contract.doubleHeightWallCells or {}) do
            lowerLayer.stairWallMask[cell] = "double-height"
            upperLayer.stairWallMask[cell] = "double-height"
        end
        for _, cell in ipairs(connector.contract.lowerSingleHeightWallCells or {}) do
            lowerLayer.stairWallMask[cell] = "single-height"
        end
        for _, cell in ipairs(connector.contract.upperSingleHeightWallCells or {}) do
            upperLayer.stairWallMask[cell] = "single-height"
        end
        connector.openingAccessEdges = connector.contract.openingAccessEdges
        connector.openingStairPassageEdges = connector.contract.openingStairPassageEdges
        connector.openingWallSegments = connector.contract.openingWallSegments
        connector.openingGuardSegments = connector.contract.openingGuardSegments
        connector.stairWallSegments = connector.contract.stairWallSegments
        connector.stairRailSegments = connector.contract.stairRailSegments
        connector.wallFinishSegments = connector.contract.wallFinishSegments
        connector.doubleHeightWallCells = connector.contract.doubleHeightWallCells
        connector.lowerSingleHeightWallCells = connector.contract.lowerSingleHeightWallCells
        connector.upperSingleHeightWallCells = connector.contract.upperSingleHeightWallCells
        -- Fixed policy tags (parity with reference; walls come from the contract,
        -- height class is decided by the upper-slab opening span).
        connector.wallGeneration = "stair-contract"
        connector.wallHeightPolicy = "opening-span-classified"
    end
    local validation = MultiFloor.Validate(layers, rooms, connectors, options.entrance, width, height)
    for _, id in ipairs(validation.unreachableRooms) do errors[#errors + 1] = "room " .. id .. " is unreachable" end
    for _, id in ipairs(validation.unreachableConnectors) do errors[#errors + 1] = "connector " .. id .. " is unreachable" end
    for _, id in ipairs(validation.invalidConnectors) do errors[#errors + 1] = "connector " .. id .. " violates spatial contract" end
    return {
        layers = layers, edges = activeEdges, connectors = connectors,
        bfs3 = validation.distance, reach = validation.reach,
        stairAudits = validation.stairAudits,
        passedStairs = validation.passedStairs,
        totalStairs = validation.totalStairs,
        valid = validation.valid and #errors == 0, errors = errors,
    }
end

function MultiFloor.StructuralHash(dungeon)
    local hash = 2166136261
    local function Feed(value)
        value = math.floor(value or 0)
        hash = ((hash ~ (value & 0xff)) * 16777619) & 0xffffffff
        hash = ((hash ~ ((value >> 8) & 0xff)) * 16777619) & 0xffffffff
    end
    for _, room in ipairs(dungeon.rooms or {}) do
        Feed(room.id); Feed(room.floor); Feed(room.cx); Feed(room.cy)
    end
    for _, edge in ipairs(dungeon.edges or {}) do
        Feed(edge.a); Feed(edge.b); Feed(edge.kind == "stairs" and 1 or 0)
    end
    for _, connector in ipairs(dungeon.connectors or {}) do
        Feed(connector.fromFloor); Feed(connector.toFloor)
        Feed(connector.lower.x); Feed(connector.lower.y)
        Feed(connector.upper.x); Feed(connector.upper.y)
        Feed(connector.width); Feed(connector.length); Feed(connector.stepCount)
        Feed(connector.style == "straight" and 1 or 2)
        if connector.turn then Feed(connector.turn.x); Feed(connector.turn.y) end
    end
    for _, layer in ipairs(dungeon.layers or {}) do
        for _, value in ipairs(layer.grid) do Feed(value) end
        for cell = 1, #layer.grid do
            Feed(layer.corridor[cell] and 1 or 0)
            Feed(layer.stairMask[cell] and 1 or 0)
            Feed(layer.stairwellMask[cell] and 1 or 0)
            Feed(layer.stairLanding[cell] and 1 or 0)
            Feed(layer.slabOpening[cell] and 1 or 0)
        end
    end
    return string.format("%08x", hash & 0xffffffff)
end

MultiFloor.Index = Index
MultiFloor.Coordinates = Coordinates

return MultiFloor
