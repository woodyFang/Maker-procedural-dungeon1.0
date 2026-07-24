local Random = require("Generation.Random")
local Delaunay = require("Generation.Delaunay")
local MultiFloor = require("Generation.MultiFloor")
local GeometryRules = require("Generation.GeometryRules")
local RoomLayout = require("Generation.RoomLayout")
local Themes = require("Config.Themes")
local ThemePacks = require("Config.ThemePacks")
local EnvironmentProfiles = require("Config.EnvironmentProfiles")

local DungeonGenerator = {}

local ROOM_GAP = 6
local ROOM_TYPES = {
    ENTRANCE = "entrance", COMBAT = "combat", ELITE = "elite",
    TREASURE = "treasure", SHRINE = "shrine", BOSS = "boss", SECRET = "secret",
}

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

-- Every floor owns deterministic random streams for layout, graph semantics,
-- carving and decoration. Changing one floor must not advance the random state
-- consumed by another floor.
local STREAM_LAYOUT = 0x13579bdf
local STREAM_GRAPH = 0x2468ace0
local STREAM_SEMANTICS = 0x6a09e667
local STREAM_FEATURES = 0xbb67ae85
local STREAM_CARVING = 0x3c6ef372
local STREAM_DECOR = 0xa54ff53a
local STREAM_NAME = 0x510e527f

local function StreamSeed(seed, floor, salt)
    local mixed = Random.IMul32(Random.U32(seed) ~ Random.U32(salt), 0x85ebca6b)
    mixed = Random.U32(mixed + Random.IMul32((floor or 0) + 1, 0xc2b2ae35))
    return Random.U32(mixed ~ (mixed >> 16))
end

local function FloorRandom(floorSeeds, floor, salt)
    local seed = floorSeeds[floor + 1] or floorSeeds[1] or 0
    return Random.new(StreamSeed(seed, floor, salt))
end

local function EdgeKey(a, b)
    if a > b then a, b = b, a end
    return tostring(a) .. ":" .. tostring(b)
end

local function Distance(a, b)
    local dx, dy = a.cx - b.cx, a.cy - b.cy
    return math.sqrt(dx * dx + dy * dy)
end

local function ClassifyRoom(width, height)
    local area = width * height
    local longest = math.max(width, height)
    if longest >= 13 or area >= 130 then return "large" end
    if longest >= 8 or area >= 64 then return "medium" end
    return "small"
end

---@return table<integer, table>
local function ScatterRooms(rng, count, floor, centerX, centerY, firstId)
    local radius = math.sqrt(math.max(1, count)) * 4.6
    local rooms = {}
    local largeCount = 0
    for i = 1, count do
        local roll = rng:Raw()
        local width, height
        if roll < 0.45 then
            width, height = rng:Int(5, 7), rng:Int(5, 7)
        elseif roll < 0.85 then
            width, height = rng:Int(8, 12), rng:Int(8, 12)
        else
            width, height = rng:Int(13, 18), rng:Int(13, 18)
            largeCount = largeCount + 1
        end
        local angle = rng:Float(0, math.pi * 2)
        local distance = radius * math.sqrt(rng:Raw())
        local cx = math.cos(angle) * distance + centerX
        local cy = math.sin(angle) * distance + centerY
        rooms[#rooms + 1] = {
            id = firstId + i - 1, cx = cx, cy = cy, sx0 = cx, sy0 = cy, w = width, h = height,
            arch = ClassifyRoom(width, height), shape = "rect", floor = floor,
            type = ROOM_TYPES.COMBAT, depth = 0, difficulty = 0.2, degree = 0,
        }
    end
    while largeCount < math.min(2, count) do
        local room = rooms[rng:Int(1, #rooms)]
        if room.arch ~= "large" then
            room.w, room.h = rng:Int(13, 18), rng:Int(13, 18)
            room.arch = "large"
            largeCount = largeCount + 1
        end
    end
    return rooms
end

local function SeparateRooms(rooms, iterations, onlyFloor)
    iterations = iterations or 300
    for _ = 1, iterations do
        local moved = false
        for i = 1, #rooms do
            for j = i + 1, #rooms do
                local a, b = rooms[i], rooms[j]
                if a.floor == b.floor and (onlyFloor == nil or a.floor == onlyFloor) then
                    local overlapX = (a.w + b.w + ROOM_GAP) * 0.5 - math.abs(a.cx - b.cx)
                    local overlapY = (a.h + b.h + ROOM_GAP) * 0.5 - math.abs(a.cy - b.cy)
                    if overlapX > 0 and overlapY > 0 and not (a.locked and b.locked) then
                        moved = true
                        if overlapX < overlapY then
                            local sign = a.cx <= b.cx and -1 or 1
                            if a.locked then b.cx = b.cx - sign * overlapX
                            elseif b.locked then a.cx = a.cx + sign * overlapX
                            else
                                a.cx = a.cx + sign * overlapX * 0.5
                                b.cx = b.cx - sign * overlapX * 0.5
                            end
                        else
                            local sign = a.cy <= b.cy and -1 or 1
                            if a.locked then b.cy = b.cy - sign * overlapY
                            elseif b.locked then a.cy = a.cy + sign * overlapY
                            else
                                a.cy = a.cy + sign * overlapY * 0.5
                                b.cy = b.cy - sign * overlapY * 0.5
                            end
                        end
                    end
                end
            end
        end
        if not moved then break end
    end
    for _, room in ipairs(rooms) do
        if onlyFloor == nil or room.floor == onlyFloor then
            room.cx = math.floor(room.cx + 0.5)
            room.cy = math.floor(room.cy + 0.5)
        end
    end
end

local function AddCandidate(candidates, seen, a, b)
    if a == b then return end
    if a > b then a, b = b, a end
    local key = EdgeKey(a, b)
    if not seen[key] then
        seen[key] = true
        candidates[#candidates + 1] = { a = a, b = b }
    end
end

local function FloorRoomIndices(rooms, floor)
    local result = {}
    for index, room in ipairs(rooms) do
        if room.floor == floor then result[#result + 1] = index end
    end
    return result
end

local function PickFloorAnchor(rooms, floor)
    for _, room in ipairs(rooms) do
        if room.floor == floor and room.semanticAnchor == true then return room end
    end
    local best, bestScore = nil, math.huge
    for _, room in ipairs(rooms) do
        if room.floor == floor then
            local score = room.cx * room.cx + room.cy * room.cy
            if score < bestScore or (score == bestScore and (not best or room.id < best.id)) then
                best, bestScore = room, score
            end
        end
    end
    return best
end

local function BuildFloorCandidates(rooms, roomIndices)
    local candidates, seen, points = {}, {}, {}
    for _, roomIndex in ipairs(roomIndices) do
        local room = rooms[roomIndex]
        points[#points + 1] = { x = room.cx, y = room.cy }
    end
    for _, edge in ipairs(Delaunay.Build(points)) do
        AddCandidate(candidates, seen, roomIndices[edge.a], roomIndices[edge.b])
    end
    if #candidates == 0 then
        for index = 1, #roomIndices - 1 do
            AddCandidate(candidates, seen, roomIndices[index], roomIndices[index + 1])
        end
    end
    return candidates
end

local function BuildFloorGraph(rooms, roomIndices, loopRate, rng)
    local candidates = BuildFloorCandidates(rooms, roomIndices)
    local adjacency = {}
    for _, roomId in ipairs(roomIndices) do adjacency[roomId] = {} end
    for index, candidate in ipairs(candidates) do
        local distance = Distance(rooms[candidate.a], rooms[candidate.b])
        adjacency[candidate.a][#adjacency[candidate.a] + 1] = { b = candidate.b, distance = distance, index = index }
        adjacency[candidate.b][#adjacency[candidate.b] + 1] = { b = candidate.a, distance = distance, index = index }
    end

    local inTree, treeIndices = {}, {}
    if roomIndices[1] then inTree[roomIndices[1]] = true end
    local inCount = roomIndices[1] and 1 or 0
    while inCount < #roomIndices do
        local best = nil
        for _, roomId in ipairs(roomIndices) do
            if inTree[roomId] then
                for _, candidate in ipairs(adjacency[roomId]) do
                    if not inTree[candidate.b] and (not best or candidate.distance < best.distance) then best = candidate end
                end
            end
        end
        if not best then break end
        inTree[best.b] = true
        inCount = inCount + 1
        treeIndices[best.index] = true
    end

    local mstLength, treeCount = 0, 0
    for index, candidate in ipairs(candidates) do
        if treeIndices[index] then
            mstLength = mstLength + Distance(rooms[candidate.a], rooms[candidate.b])
            treeCount = treeCount + 1
        end
    end
    local meanLength = mstLength / math.max(1, treeCount)
    local edges = {}
    for index, candidate in ipairs(candidates) do
        if treeIndices[index] then
            edges[#edges + 1] = { a = candidate.a, b = candidate.b, isLoop = false, isCritical = false }
        elseif Distance(rooms[candidate.a], rooms[candidate.b]) < meanLength * 2.2 and rng:Chance(loopRate) then
            edges[#edges + 1] = { a = candidate.a, b = candidate.b, isLoop = true, isCritical = false }
        end
    end

    -- Loop pruning is local to this floor, so another floor cannot lose a leaf
    -- when the current floor's loop rate changes.
    if #roomIndices >= 20 then
        local degree = {}
        for _, roomId in ipairs(roomIndices) do degree[roomId] = 0 end
        for _, edge in ipairs(edges) do
            degree[edge.a], degree[edge.b] = degree[edge.a] + 1, degree[edge.b] + 1
        end
        local leaves = 0
        for _, roomId in ipairs(roomIndices) do if degree[roomId] == 1 then leaves = leaves + 1 end end
        while leaves < 3 do
            local bestIndex, bestScore = nil, -1
            for index, edge in ipairs(edges) do
                if edge.isLoop then
                    local score = (degree[edge.a] == 2 and 10000 or 0)
                        + (degree[edge.b] == 2 and 10000 or 0)
                        + Distance(rooms[edge.a], rooms[edge.b])
                    if score > bestScore then bestIndex, bestScore = index, score end
                end
            end
            if not bestIndex then break end
            local edge = table.remove(edges, bestIndex)
            degree[edge.a], degree[edge.b] = degree[edge.a] - 1, degree[edge.b] - 1
            if degree[edge.a] == 1 then leaves = leaves + 1 end
            if degree[edge.b] == 1 then leaves = leaves + 1 end
        end
    end
    return edges
end

local function BuildGraph(rooms, floorCount, loopRates, floorSeeds)
    local edges = {}
    for floor = 0, floorCount - 1 do
        local roomIndices = FloorRoomIndices(rooms, floor)
        local floorEdges = BuildFloorGraph(rooms, roomIndices,
            loopRates[floor + 1] or loopRates[1] or 0.15,
            FloorRandom(floorSeeds, floor, STREAM_GRAPH))
        for _, edge in ipairs(floorEdges) do edges[#edges + 1] = edge end
    end

    -- Cross-floor topology is the only intentionally shared contract. Choose
    -- the closest pair so the stair solver receives a viable spatial bridge;
    -- changing floor N may therefore adjust the landing on N+1.
    for floor = 0, floorCount - 2 do
        local lower, upper, bestDistance = nil, nil, math.huge
        for _, roomA in ipairs(rooms) do
            if roomA.floor == floor then
                for _, roomB in ipairs(rooms) do
                    if roomB.floor == floor + 1 then
                        local distance = Distance(roomA, roomB)
                        if distance < bestDistance or (distance == bestDistance
                            and (not lower or roomA.id < lower.id or (roomA.id == lower.id and roomB.id < upper.id))) then
                            lower, upper, bestDistance = roomA, roomB, distance
                        end
                    end
                end
            end
        end
        if lower and upper then
            edges[#edges + 1] = { a = lower.id, b = upper.id, isLoop = false, isCritical = true }
        end
    end

    for _, room in ipairs(rooms) do room.degree = 0 end
    for index, edge in ipairs(edges) do
        edge.id = index
        if rooms[edge.a].floor == rooms[edge.b].floor then
            rooms[edge.a].degree = rooms[edge.a].degree + 1
            rooms[edge.b].degree = rooms[edge.b].degree + 1
        end
    end
    return edges
end

local function RefreshGeneratedStairAlternates(rooms, edges)
    for _, edge in ipairs(edges) do
        local roomA, roomB = rooms[edge.a], rooms[edge.b]
        if roomA and roomB and roomA.floor ~= roomB.floor and not edge.isManual then
            local lowerFloor, upperFloor = math.min(roomA.floor, roomB.floor), math.max(roomA.floor, roomB.floor)
            local candidates = {}
            for _, lower in ipairs(rooms) do
                if lower.floor == lowerFloor then
                    for _, upper in ipairs(rooms) do
                        if upper.floor == upperFloor then
                            candidates[#candidates + 1] = { a = lower.id, b = upper.id, distance = Distance(lower, upper) }
                        end
                    end
                end
            end
            table.sort(candidates, function(a, b)
                if a.distance ~= b.distance then return a.distance < b.distance end
                return a.a == b.a and a.b < b.b or a.a < b.a
            end)
            edge.stairAlternates = {}
            for index = 1, math.min(24, #candidates) do
                edge.stairAlternates[index] = { a = candidates[index].a, b = candidates[index].b }
            end
            if edge.stairAlternates[1] then
                edge.a, edge.b = edge.stairAlternates[1].a, edge.stairAlternates[1].b
            end
        end
    end
end

local function MergePreservedFloorEdges(rooms, generatedEdges, previousDungeon, changedFloor)
    if not previousDungeon or changedFloor == nil then return generatedEdges end
    local oldToNew, result = {}, {}
    for _, room in ipairs(rooms) do
        if room.sourceRoomId then oldToNew[room.sourceRoomId] = room.id end
    end
    for _, edge in ipairs(generatedEdges) do
        local roomA, roomB = rooms[edge.a], rooms[edge.b]
        if roomA.floor ~= roomB.floor or roomA.floor == changedFloor then
            edge.floorOrder = roomA.floor == roomB.floor and roomA.floor or math.min(roomA.floor, roomB.floor)
            result[#result + 1] = edge
        end
    end
    for oldIndex, edge in ipairs(previousDungeon.edges or {}) do
        local oldA, oldB = previousDungeon.rooms[edge.a], previousDungeon.rooms[edge.b]
        if oldA and oldB and oldA.floor == oldB.floor and oldA.floor ~= changedFloor
            and oldToNew[oldA.id] and oldToNew[oldB.id] then
            local bends = {}
            for _, point in ipairs(edge.bends or {}) do bends[#bends + 1] = { x = point.x, y = point.y } end
            local function CopyDoor(door)
                return door and { side = door.side, offset = door.offset } or nil
            end
            result[#result + 1] = {
                a = oldToNew[oldA.id], b = oldToNew[oldB.id],
                isLoop = edge.isLoop == true, isCritical = edge.isCritical == true,
                isManual = edge.isManual == true, isEditor = edge.isEditor == true,
                width = edge.width, bends = bends,
                doorA = CopyDoor(edge.doorA), doorB = CopyDoor(edge.doorB),
                floorOrder = oldA.floor, preservedOrder = oldIndex,
            }
        end
    end
    table.sort(result, function(a, b)
        local roomA1, roomA2 = rooms[a.a], rooms[a.b]
        local roomB1, roomB2 = rooms[b.a], rooms[b.b]
        local aStair, bStair = roomA1.floor ~= roomA2.floor, roomB1.floor ~= roomB2.floor
        if aStair ~= bStair then return not aStair end
        if (a.floorOrder or 0) ~= (b.floorOrder or 0) then return (a.floorOrder or 0) < (b.floorOrder or 0) end
        return (a.preservedOrder or a.id or 0) < (b.preservedOrder or b.id or 0)
    end)
    for _, room in ipairs(rooms) do room.degree = 0 end
    for index, edge in ipairs(result) do
        edge.id, edge.floorOrder, edge.preservedOrder = index, nil, nil
        if rooms[edge.a].floor == rooms[edge.b].floor then
            rooms[edge.a].degree = rooms[edge.a].degree + 1
            rooms[edge.b].degree = rooms[edge.b].degree + 1
        end
    end
    return result
end

local function DistancesFrom(source, adjacency)
    local distances = {}
    for i = 1, #adjacency do distances[i] = -1 end
    distances[source] = 0
    local queue, head = { source }, 1
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        for _, nextInfo in ipairs(adjacency[current]) do
            if distances[nextInfo.room] < 0 then
                distances[nextInfo.room] = distances[current] + 1
                queue[#queue + 1] = nextInfo.room
            end
        end
    end
    return distances
end

local function AssignSemantics(rooms, edges, floorCount, floorSeeds)
    local topFloor = floorCount - 1
    local boss = nil
    for _, room in ipairs(rooms) do if room.roleHint == "boss" then boss = room break end end
    if not boss then
        for _, room in ipairs(rooms) do
            if room.floor == topFloor and (not boss or room.w * room.h > boss.w * boss.h
                or (room.w * room.h == boss.w * boss.h and room.id < boss.id)) then boss = room end
        end
    end
    boss = boss or rooms[#rooms]

    local floorAdjacency = {}
    for floor = 0, floorCount - 1 do
        floorAdjacency[floor + 1] = {}
        for index = 1, #rooms do floorAdjacency[floor + 1][index] = {} end
    end
    for edgeIndex, edge in ipairs(edges) do
        local roomA, roomB = rooms[edge.a], rooms[edge.b]
        if roomA.floor == roomB.floor then
            local adjacency = floorAdjacency[roomA.floor + 1]
            adjacency[edge.a][#adjacency[edge.a] + 1] = { room = edge.b, edge = edgeIndex }
            adjacency[edge.b][#adjacency[edge.b] + 1] = { room = edge.a, edge = edgeIndex }
        end
    end

    local entrance = nil
    for _, room in ipairs(rooms) do if room.roleHint == "entrance" then entrance = room break end end
    if not entrance then
        local anchor = PickFloorAnchor(rooms, 0)
        local distances = anchor and DistancesFrom(anchor.id, floorAdjacency[1]) or {}
        local bestDistance = -1
        for _, room in ipairs(rooms) do
            if room.floor == 0 and room.id ~= boss.id then
                local distance = distances[room.id] or -1
                local preferred = room.degree == 1 and 1 or 0
                local currentPreferred = entrance and entrance.degree == 1 and 1 or 0
                if preferred > currentPreferred or (preferred == currentPreferred and distance > bestDistance) then
                    entrance, bestDistance = room, distance
                end
            end
        end
    end
    entrance = entrance or rooms[1]

    local maxDepth, criticalLength = 1, 0
    local treasureLimit = math.max(1, math.ceil(4 / floorCount))
    for floor = 0, floorCount - 1 do
        local floorRooms = {}
        for _, room in ipairs(rooms) do if room.floor == floor then floorRooms[#floorRooms + 1] = room end end
        local source = floor == 0 and entrance or (floor == topFloor and boss or PickFloorAnchor(rooms, floor))
        source = source or floorRooms[1]
        for _, room in ipairs(floorRooms) do room.semanticAnchor = room == source end
        local adjacency = floorAdjacency[floor + 1]
        local distances, parents, parentEdges = {}, {}, {}
        for index = 1, #rooms do distances[index], parents[index], parentEdges[index] = -1, 0, 0 end
        if source then
            distances[source.id] = 0
            local queue, head = { source.id }, 1
            while head <= #queue do
                local current = queue[head]
                head = head + 1
                for _, nextInfo in ipairs(adjacency[current]) do
                    if distances[nextInfo.room] < 0 then
                        distances[nextInfo.room] = distances[current] + 1
                        parents[nextInfo.room] = current
                        parentEdges[nextInfo.room] = nextInfo.edge
                        queue[#queue + 1] = nextInfo.room
                    end
                end
            end
        end

        local localMax, farthest = 1, source
        for _, room in ipairs(floorRooms) do
            local distance = math.max(0, distances[room.id])
            if distance > localMax then localMax, farthest = distance, room end
        end
        local criticalRooms = {}
        local current = farthest and farthest.id or 0
        while current > 0 do
            criticalRooms[current] = true
            local edgeIndex = parentEdges[current]
            if edgeIndex > 0 then
                edges[edgeIndex].isCritical = true
                criticalLength = criticalLength + 1
            end
            if source and current == source.id then break end
            current = parents[current]
        end

        for _, room in ipairs(floorRooms) do
            local localDepth = math.max(0, distances[room.id])
            room.depth = floor * 100 + localDepth
            local floorProgress = (floor + localDepth / localMax) / math.max(1, floorCount)
            room.difficulty = math.min(0.96, 0.15 + 0.8 * floorProgress)
            room.type = ROOM_TYPES.COMBAT
            maxDepth = math.max(maxDepth, room.depth)
        end

        local leaves = {}
        for _, room in ipairs(floorRooms) do
            if room.id ~= entrance.id and room.id ~= boss.id and room.degree == 1 then leaves[#leaves + 1] = room end
        end
        table.sort(leaves, function(a, b) return a.depth == b.depth and a.id < b.id or a.depth > b.depth end)
        for index = 1, math.min(treasureLimit, #leaves) do leaves[index].type = ROOM_TYPES.TREASURE end

        local shrineCandidates, eliteCandidates = {}, {}
        for _, room in ipairs(floorRooms) do
            local localDepth = math.max(0, distances[room.id])
            if room.type == ROOM_TYPES.COMBAT and not criticalRooms[room.id]
                and localDepth > localMax * 0.3 and localDepth < localMax * 0.85 then
                shrineCandidates[#shrineCandidates + 1] = room
            end
            if room.type == ROOM_TYPES.COMBAT and criticalRooms[room.id]
                and localDepth >= localMax * 0.55 and localDepth <= localMax * 0.85 then
                eliteCandidates[#eliteCandidates + 1] = room
            end
        end
        local semanticRng = FloorRandom(floorSeeds, floor, STREAM_SEMANTICS)
        for _ = 1, math.min(1, #shrineCandidates) do
            table.remove(shrineCandidates, semanticRng:Int(1, #shrineCandidates)).type = ROOM_TYPES.SHRINE
        end
        table.sort(eliteCandidates, function(a, b) return a.depth > b.depth end)
        for index = 1, math.min(1, #eliteCandidates) do eliteCandidates[index].type = ROOM_TYPES.ELITE end
    end

    entrance.type, entrance.difficulty = ROOM_TYPES.ENTRANCE, 0
    boss.type, boss.difficulty = ROOM_TYPES.BOSS, 1
    for _, room in ipairs(rooms) do if room.roleHint == "secret" then room.type = ROOM_TYPES.SECRET end end
    return entrance.id, boss.id, maxDepth, criticalLength
end

local function GroupSupportsRole(group, role)
    for _, key in ipairs(group.roleKeys or {}) do if key == role then return true end end
    return false
end

local function AssignRoomGroups(rooms, groups)
    if type(groups) ~= "table" or #groups == 0 then return {}, {} end
    local byId, counts, defaultGroup = {}, {}, nil
    for _, group in ipairs(groups) do
        byId[group.id] = group
        counts[group.id] = 0
        if group.defaultGroup == true then defaultGroup = group end
    end

    local explicit = {}
    for _, room in ipairs(rooms) do
        if room.roomGroupId then
            explicit[room.id] = true
            if byId[room.roomGroupId] then counts[room.roomGroupId] = counts[room.roomGroupId] + 1 end
        else
            local selected = nil
            for _, group in ipairs(groups) do
                if not group.defaultGroup and GroupSupportsRole(group, room.type) then
                    selected = group
                    break
                end
            end
            selected = selected or (defaultGroup and GroupSupportsRole(defaultGroup, room.type) and defaultGroup or nil)
            selected = selected or defaultGroup
            if selected then
                room.roomGroupId = selected.id
                counts[selected.id] = counts[selected.id] + 1
            end
        end
    end

    -- Semantic roles may not produce an elite/shrine/treasure room for every
    -- layout. Satisfy each generated group's minimum by deterministically
    -- converting an unlocked default room instead of silently dropping a plan.
    for _, group in ipairs(groups) do
        local required = math.max(0, math.floor(tonumber(group.minCount) or 0))
        while group ~= defaultGroup and counts[group.id] < required do
            local candidate, bestPenalty = nil, math.huge
            for _, room in ipairs(rooms) do
                if not explicit[room.id] and defaultGroup and room.roomGroupId == defaultGroup.id
                    and (counts[defaultGroup.id] or 0) > math.max(1, defaultGroup.minCount or 0) then
                    local area = room.w * room.h
                    local penalty = 0
                    if (group.minArea or 0) > 0 and area < group.minArea then penalty = group.minArea - area end
                    if (group.maxArea or 0) > 0 and area > group.maxArea then penalty = penalty + area - group.maxArea end
                    if penalty < bestPenalty or (penalty == bestPenalty and (not candidate or room.id < candidate.id)) then
                        candidate, bestPenalty = room, penalty
                    end
                end
            end
            if not candidate then break end
            counts[defaultGroup.id] = counts[defaultGroup.id] - 1
            candidate.roomGroupId = group.id
            counts[group.id] = counts[group.id] + 1
        end
    end
    return byId, counts
end

local function RebaseRooms(rooms, edges)
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for _, room in ipairs(rooms) do
        minX = math.min(minX, room.cx - math.ceil(room.w * 0.5))
        minY = math.min(minY, room.cy - math.ceil(room.h * 0.5))
        maxX = math.max(maxX, room.cx + math.ceil(room.w * 0.5))
        maxY = math.max(maxY, room.cy + math.ceil(room.h * 0.5))
    end
    for _, edge in ipairs(edges or {}) do
        local radius = math.ceil((edge.width or 2) * 0.5)
        for _, point in ipairs(edge.bends or {}) do
            minX, minY = math.min(minX, point.x - radius), math.min(minY, point.y - radius)
            maxX, maxY = math.max(maxX, point.x + radius), math.max(maxY, point.y + radius)
        end
        local spec = edge.stairSpec
        local anchor = spec and (spec.pending and spec.previewAnchor or spec.anchor)
        if anchor then
            -- A stair may be authored in empty space far from either endpoint
            -- room. Reserve a direction-independent envelope here; MultiFloor
            -- will resolve the exact legal contract and route both approaches.
            local length = math.max(6, tonumber(spec.pending and spec.previewLength or spec.length) or 10)
            local landing = math.max(1, tonumber(spec.pending and spec.previewLandingDepth or spec.landingDepth) or 2)
            local stairWidth = math.max(1, tonumber(spec.pending and spec.previewWidth or spec.width) or 2)
            local stairRadius = math.ceil(length + landing + stairWidth + 3)
            minX, minY = math.min(minX, anchor.x - stairRadius), math.min(minY, anchor.y - stairRadius)
            maxX, maxY = math.max(maxX, anchor.x + stairRadius), math.max(maxY, anchor.y + stairRadius)
        end
    end
    local padding = 5
    local offsetX, offsetY = padding - minX, padding - minY
    for _, room in ipairs(rooms) do
        room.sx0 = (room.sx0 or room.cx) + offsetX
        room.sy0 = (room.sy0 or room.cy) + offsetY
        room.cx = math.floor(room.cx + offsetX + 0.5)
        room.cy = math.floor(room.cy + offsetY + 0.5)
    end
    for _, edge in ipairs(edges or {}) do
        for _, point in ipairs(edge.bends or {}) do
            point.x = point.x + offsetX
            point.y = point.y + offsetY
        end
        for _, point in ipairs(edge.autoRoute or {}) do
            point.x = point.x + offsetX
            point.y = point.y + offsetY
        end
        local stairSpec = edge.stairSpec
        local function RebasePoint(point)
            if point then point.x, point.y = point.x + offsetX, point.y + offsetY end
        end
        if stairSpec then RebasePoint(stairSpec.anchor); RebasePoint(stairSpec.previewAnchor) end
    end
    return math.floor(maxX - minX + padding * 2 + 1), math.floor(maxY - minY + padding * 2 + 1),
        { x = offsetX, y = offsetY }
end

local function RebaseGeneratedRoomsByFloor(rooms, edges, floorCount)
    local padding, width, height = 5, 1, 1
    for floor = 0, floorCount - 1 do
        local minX, minY = math.huge, math.huge
        local maxX, maxY = -math.huge, -math.huge
        for _, room in ipairs(rooms) do
            if room.floor == floor then
                minX = math.min(minX, room.cx - math.ceil(room.w * 0.5))
                minY = math.min(minY, room.cy - math.ceil(room.h * 0.5))
                maxX = math.max(maxX, room.cx + math.ceil(room.w * 0.5))
                maxY = math.max(maxY, room.cy + math.ceil(room.h * 0.5))
            end
        end
        for _, edge in ipairs(edges or {}) do
            local roomA, roomB = rooms[edge.a], rooms[edge.b]
            if roomA and roomB and roomA.floor == floor and roomB.floor == floor then
                local radius = math.ceil((edge.width or 2) * 0.5)
                for _, point in ipairs(edge.bends or {}) do
                    minX, minY = math.min(minX, point.x - radius), math.min(minY, point.y - radius)
                    maxX, maxY = math.max(maxX, point.x + radius), math.max(maxY, point.y + radius)
                end
            end
        end
        if minX < math.huge then
            local offsetX, offsetY = padding - minX, padding - minY
            for _, room in ipairs(rooms) do
                if room.floor == floor then
                    room.sx0 = (room.sx0 or room.cx) + offsetX
                    room.sy0 = (room.sy0 or room.cy) + offsetY
                    room.cx = math.floor(room.cx + offsetX + 0.5)
                    room.cy = math.floor(room.cy + offsetY + 0.5)
                end
            end
            for _, edge in ipairs(edges or {}) do
                local roomA, roomB = rooms[edge.a], rooms[edge.b]
                if roomA and roomB and roomA.floor == floor and roomB.floor == floor then
                    for _, point in ipairs(edge.bends or {}) do
                        point.x, point.y = point.x + offsetX, point.y + offsetY
                    end
                    for _, point in ipairs(edge.autoRoute or {}) do
                        point.x, point.y = point.x + offsetX, point.y + offsetY
                    end
                end
            end
            width = math.max(width, math.floor(maxX - minX + padding * 2 + 1))
            height = math.max(height, math.floor(maxY - minY + padding * 2 + 1))
        end
    end
    return width, height
end

local function IsInterior(layer, x, y, width, height, roomId)
    for oy = -1, 1 do
        for ox = -1, 1 do
            local nx, ny = x + ox, y + oy
            if nx < 0 or ny < 0 or nx >= width or ny >= height then return false end
            if layer.roomId[MultiFloor.Index(nx, ny, width)] ~= roomId then return false end
        end
    end
    return true
end

local function Decorate(dungeon, floorSeeds, densities, settingKey, themeKey, roomGroupsById)
    local profile = EnvironmentProfiles.Resolve(settingKey)
    local theme = Themes.Resolve(settingKey, themeKey)
    for _, layer in ipairs(dungeon.layers) do
        local rng = FloorRandom(floorSeeds, layer.floor, STREAM_DECOR)
        local occupied = {}
        local density = densities[layer.floor + 1] or densities[1] or 0.6

        local function CanPlace(room, x, y)
            if x < 1 or y < 1 or x >= dungeon.width - 1 or y >= dungeon.height - 1 then return false end
            local cell = MultiFloor.Index(x, y, dungeon.width)
            return not occupied[cell]
                and layer.grid[cell] == MultiFloor.Tiles.FLOOR
                and layer.roomId[cell] == room.id
                and not layer.doorway[cell]
                and not layer.lakeMask[cell]
                and IsInterior(layer, x, y, dungeon.width, dungeon.height, room.id)
        end

        local function AddPropAt(room, kind, x, y, rotation, scale, extra)
            if not CanPlace(room, x, y) then return false end
            local cell = MultiFloor.Index(x, y, dungeon.width)
            occupied[cell] = true
            local prop = { kind=kind, x=x, y=y, roomId=room.id, rot=rotation or 0, scale=scale or 1 }
            for key, value in pairs(extra or {}) do prop[key] = value end
            layer.props[#layer.props + 1] = prop
            return true
        end

        local function AddProp(room, kind, options)
            options = options or {}
            local candidates = options.candidates or {
                { 0, 0 }, { -2, 0 }, { 2, 0 }, { 0, -2 }, { 0, 2 },
                { -2, -2 }, { 2, 2 }, { -2, 2 }, { 2, -2 },
            }
            for _, offset in ipairs(candidates) do
                local x, y = room.cx + offset[1], room.cy + offset[2]
                if CanPlace(room, x, y) then
                    local cell = MultiFloor.Index(x, y, dungeon.width)
                    occupied[cell] = true
                    layer.props[#layer.props + 1] = {
                        kind = kind, x = x, y = y, roomId = room.id,
                        rot = options.rot or rng:Float(0, math.pi * 2),
                        scale = options.scale or 1,
                    }
                    return { x = x, y = y }
                end
            end
            for _ = 1, options.tries or 24 do
                local x = rng:Int(math.floor(room.cx - room.w * 0.5) + 2,
                    math.ceil(room.cx + room.w * 0.5) - 2)
                local y = rng:Int(math.floor(room.cy - room.h * 0.5) + 2,
                    math.ceil(room.cy + room.h * 0.5) - 2)
                if CanPlace(room, x, y) then
                    local cell = MultiFloor.Index(x, y, dungeon.width)
                    occupied[cell] = true
                    layer.props[#layer.props + 1] = {
                        kind = kind, x = x, y = y, roomId = room.id,
                        rot = options.rot or rng:Float(0, math.pi * 2),
                        scale = options.scale or 1,
                    }
                    return { x = x, y = y }
                end
            end
            return false
        end

        -- Placement helpers a RoomLayout pattern uses. Both go through the
        -- validity-checked closures above, so a layout can only choose cells.
        local layoutPlace = { at = AddPropAt, prop = AddProp }

        local function DecorateHospitalRoom(room)
            local area = math.max(1, room.w * room.h)
            local roomy = area >= 95
            local function AddSupport(items)
                for _, item in ipairs(items) do
                    if item.when == nil or rng:Chance(item.when) then
                        AddProp(room, item.kind, {
                            rot = item.rot or (rng:Chance(0.5) and 0 or math.pi * 0.5),
                            scale = item.scale or rng:Float(0.82, 1.0),
                            tries = item.tries or 70,
                        })
                    end
                end
            end
            if room.type == ROOM_TYPES.ENTRANCE then
                AddProp(room, "nurseCounter", { rot = 0, scale = 1.15, tries = 80 })
                AddProp(room, "waitingBench", { rot = math.pi * 0.5, tries = 60 })
                if roomy then AddProp(room, "waitingBench", { rot = 0, scale = 0.9, tries = 60 }) end
                AddSupport({
                    { kind = "medCart", scale = 0.85, when = 0.85 },
                    { kind = "medCabinet", scale = 0.88, when = 0.65 },
                    { kind = "bioBin", scale = 0.78, when = 0.55 },
                })
            elseif room.type == ROOM_TYPES.BOSS then
                AddProp(room, "surgeryTable", { rot = rng:Chance(0.5) and 0 or math.pi * 0.5, scale = 1.18, tries = 110 })
                AddProp(room, "surgicalLamp", { rot = 0, scale = 1.05, tries = 80 })
                AddProp(room, "gurney", { rot = math.pi * 0.5, scale = 0.98, tries = 90 })
                AddProp(room, "cleanZone", { rot = 0, scale = 1.15, tries = 90 })
                AddSupport({
                    { kind = "monitor", scale = 0.95, when = 0.95 },
                    { kind = "medCart", scale = 0.86, when = 0.90 },
                    { kind = "oxygenTank", scale = 0.86, when = 0.85 },
                    { kind = "bioBin", scale = 0.80, when = 0.75 },
                    { kind = "medCabinet", scale = 0.90, when = 0.70 },
                })
            elseif room.type == ROOM_TYPES.SHRINE then
                AddProp(room, "mriScanner", { rot = rng:Chance(0.5) and 0 or math.pi * 0.5, scale = 1.08, tries = 110 })
                AddProp(room, "monitor", { rot = 0, scale = 0.95, tries = 80 })
                AddSupport({
                    { kind = "medCart", scale = 0.82, when = 0.85 },
                    { kind = "medCabinet", scale = 0.88, when = 0.75 },
                    { kind = "waitingBench", scale = 0.82, when = 0.60 },
                    { kind = "oxygenTank", scale = 0.78, when = 0.55 },
                })
            elseif room.type == ROOM_TYPES.TREASURE then
                AddProp(room, "doctorDesk", { rot = 0, scale = 1.05, tries = 90 })
                AddProp(room, "waitingBench", { rot = math.pi * 0.5, scale = 0.90, tries = 70 })
                AddSupport({
                    { kind = "medCabinet", scale = 0.92, when = 0.90 },
                    { kind = "monitor", scale = 0.78, when = 0.65 },
                    { kind = "medCart", scale = 0.78, when = 0.55 },
                    { kind = "bioBin", scale = 0.72, when = 0.45 },
                })
            elseif room.type == ROOM_TYPES.ELITE then
                AddProp(room, "examTable", { rot = rng:Chance(0.5) and 0 or math.pi * 0.5, scale = 1.02, tries = 90 })
                AddProp(room, "doctorDesk", { rot = 0, scale = 0.92, tries = 70 })
                AddSupport({
                    { kind = "monitor", scale = 0.90, when = 0.90 },
                    { kind = "medCart", scale = 0.85, when = 0.85 },
                    { kind = "medCabinet", scale = 0.86, when = 0.75 },
                    { kind = "privacyCurtain", scale = 0.92, when = 0.65 },
                    { kind = "oxygenTank", scale = 0.76, when = 0.45 },
                })
            else
                local ward = (((room.floorIndex or room.id) - 1) + room.depth) % 3 ~= 0
                if ward then
                    local bedCount = roomy and rng:Int(2, 3) or rng:Int(1, 2)
                    for index = 1, bedCount do
                        local rotation = index % 2 == 1 and 0 or math.pi * 0.5
                        local bed = AddProp(room, "hospitalBed", {
                            rot = rotation, scale = rng:Float(0.98, 1.08), tries = 100,
                        })
                        if bed and rng:Chance(0.85) then
                            local ivX = bed.x + (rotation == 0 and (index % 2 == 1 and -1 or 1) or 0)
                            local ivY = bed.y + (rotation == 0 and 0 or (index % 2 == 1 and -1 or 1))
                            if CanPlace(room, ivX, ivY) then
                                local cell = MultiFloor.Index(ivX, ivY, dungeon.width)
                                occupied[cell] = true
                                layer.props[#layer.props + 1] = {
                                    kind = "ivStand", x = ivX, y = ivY, roomId = room.id,
                                    rot = 0, scale = rng:Float(0.88, 1.0),
                                }
                            end
                        end
                    end
                    AddSupport({
                        { kind = "medCabinet", scale = 0.88, when = 0.70 },
                        { kind = "privacyCurtain", scale = 0.90, when = 0.65 },
                        { kind = "oxygenTank", scale = 0.76, when = 0.55 },
                        { kind = "bioBin", scale = 0.72, when = 0.45 },
                        { kind = "medCart", scale = 0.78, when = roomy and 0.55 or 0.35 },
                    })
                else
                    AddProp(room, "examTable", { rot = rng:Chance(0.5) and 0 or math.pi * 0.5, scale = 0.96, tries = 80 })
                    AddSupport({
                        { kind = "doctorDesk", scale = 0.85, when = 0.75 },
                        { kind = "medCabinet", scale = 0.85, when = 0.70 },
                        { kind = "medCart", scale = 0.78, when = 0.55 },
                        { kind = "monitor", scale = 0.78, when = 0.45 },
                        { kind = "bioBin", scale = 0.70, when = 0.35 },
                    })
                end
            end
        end

        local function DecorateDungeonRoom(room)
            -- Ruins room layout now runs on the generic RoomLayout patterns; the
            -- prop kinds are ruins DATA, the placement mechanics are shared.
            if room.type == ROOM_TYPES.ENTRANCE then
                RoomLayout.focal(room, rng, { kind = "ring", rot = 0, tries = 24 }, layoutPlace)
            elseif room.type == ROOM_TYPES.BOSS then
                RoomLayout.ring(room, rng, {
                    kind = "brazier", count = 6, angleSpan = 1,
                    anchor = "bossCrystal", anchorScale = 1.15,
                }, layoutPlace)
            elseif room.type == ROOM_TYPES.TREASURE then
                RoomLayout.focal(room, rng, { kind = "chest", tries = 24 }, layoutPlace)
            elseif room.type == ROOM_TYPES.SHRINE then
                RoomLayout.focal(room, rng, { kind = "shrineCrystal", tries = 24 }, layoutPlace)
            end

            if (room.type == ROOM_TYPES.COMBAT or room.type == ROOM_TYPES.ELITE or room.type == ROOM_TYPES.BOSS)
                and math.min(room.w, room.h) >= 10 and not room.grave and not room.lake then
                RoomLayout.grid(room, rng, {
                    kind = "pillar", centered = true, skipCenter = true,
                    stepThreshold = 14, stepBig = 4, stepSmall = 3,
                    scaleMin = 0.94, scaleMax = 1.06, rot = 0,
                }, layoutPlace)
            end
            if room.grave then
                RoomLayout.fill(room, rng, {
                    kind = "grave", step = 2, chance = 0.8, rotJitter = 0.3,
                    scaleMin = 0.85, scaleMax = 1.15,
                    anchor = "sarco", anchorMinDim = 10, anchorRotAxis = true, anchorScale = 1,
                }, layoutPlace)
                for _=1,4 do
                    AddPropAt(room,"candle",rng:Int(math.floor(room.cx-room.w*0.5)+1,math.ceil(room.cx+room.w*0.5)-1),
                        rng:Int(math.floor(room.cy-room.h*0.5)+1,math.ceil(room.cy+room.h*0.5)-1),0,rng:Float(0.85,1.2))
                end
            end
        end

        -- Apply one theme prop-rule. A rule may opt into a structured layout
        -- (grid/perimeter/ring/fill/focal); with no layout it falls back to the
        -- original random scatter, byte-for-byte, so existing themes are stable.
        local function ApplyRule(room, rule)
            local layout = rule.layout
            if layout and layout ~= "scatter" and RoomLayout[layout] then
                RoomLayout[layout](room, rng, rule, layoutPlace)
                return
            end
            for _ = 1, rule.count or 1 do
                if rng:Chance(rule.chance == nil and 1 or rule.chance) then
                    AddProp(room, rule.kind, {
                        rot = rule.rot or (rng:Chance(0.5) and 0 or math.pi * 0.5),
                        scale = rng:Float(rule.scaleMin or 0.92, rule.scaleMax or 1.0),
                        tries = 100,
                    })
                end
            end
        end

        local function DecorateRoomGroup(room, allowedProps)
            local group = roomGroupsById and roomGroupsById[room.roomGroupId] or nil
            if not group or type(group.propRules) ~= "table" or #group.propRules == 0 then return false end
            for _, rule in ipairs(group.propRules) do
                if not allowedProps or allowedProps[rule.kind] then ApplyRule(room, rule) end
            end
            return true
        end

        local function DecorateThemePackRoom(room, pack)
            if DecorateRoomGroup(room, pack.props) then return end
            local rules = pack.roomRules[room.type] or pack.roomRules.default or {}
            for _, rule in ipairs(rules) do
                if pack.props[rule.kind] then ApplyRule(room, rule) end
            end
        end

        for _, room in ipairs(dungeon.rooms) do
            if room.floor == layer.floor then
                if settingKey == "hospital" then
                    if not DecorateRoomGroup(room) then DecorateHospitalRoom(room) end
                elseif ThemePacks.Get(settingKey) then
                    DecorateThemePackRoom(room, ThemePacks.Get(settingKey))
                else
                    DecorateDungeonRoom(room)
                end

                local spawnCount = math.max(1, math.floor(room.w * room.h / 45 * (0.5 + room.difficulty)))
                if room.type == ROOM_TYPES.COMBAT or room.type == ROOM_TYPES.ELITE or room.type == ROOM_TYPES.BOSS then
                    local guard = 0
                    while spawnCount > 0 and guard < 120 do
                        guard = guard + 1
                        local x = rng:Int(math.floor(room.cx - room.w * 0.5) + 1, math.ceil(room.cx + room.w * 0.5) - 1)
                        local y = rng:Int(math.floor(room.cy - room.h * 0.5) + 1, math.ceil(room.cy + room.h * 0.5) - 1)
                        local cell = MultiFloor.Index(x, y, dungeon.width)
                        if layer.roomId[cell] == room.id and layer.grid[cell] == MultiFloor.Tiles.FLOOR
                            and not occupied[cell] and not layer.doorway[cell] and not layer.lakeMask[cell] then
                            occupied[cell] = true
                            layer.spawns[#layer.spawns + 1] = {
                                x = x, y = y, roomId = room.id,
                                tier = room.type == ROOM_TYPES.ELITE and 3 or math.max(1, math.ceil(room.difficulty * 3)),
                            }
                            spawnCount = spawnCount - 1
                        end
                    end
                end
            end
        end

        -- Generic floor-scatter richness (extracted from the ruins-only path).
        -- Every setting fills negative space with theme-coloured clutter; only
        -- the prop, density and scale come from its EnvironmentProfile.
        local scatter = profile.floorScatter
        if scatter then
            for cell, tile in ipairs(layer.grid) do
                if tile == MultiFloor.Tiles.FLOOR and not occupied[cell]
                    and not layer.doorway[cell] and not layer.lakeMask[cell] then
                    local roomId = layer.roomId[cell] or 0
                    local room = roomId > 0 and dungeon.rooms[roomId] or nil
                    local chance = density * scatter.baseChance
                    if scatter.difficultyBias then
                        chance = chance * (1.25 - 0.6 * (room and room.difficulty or 0.5))
                    end
                    if layer.corridor[cell] then chance = chance * scatter.corridorFactor end
                    if rng:Chance(chance) then
                        local x, y = MultiFloor.Coordinates(cell, dungeon.width)
                        layer.props[#layer.props + 1] = {
                            kind = scatter.kind, x = x, y = y, roomId = roomId,
                            rot = rng:Float(0, math.pi * 2),
                            scale = rng:Float(scatter.scaleMin or 0.6, scatter.scaleMax or 1.35),
                            v = rng:Int(0, (scatter.variants or 3) - 1),
                        }
                    end
                end
            end
        end

        local candidates = {}
        for cell, tile in ipairs(layer.grid) do
            if tile == MultiFloor.Tiles.WALL then
                local x, y = MultiFloor.Coordinates(cell, dungeon.width)
                local directions = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
                for _, direction in ipairs(directions) do
                    local nx, ny = x + direction[1], y + direction[2]
                    if nx >= 0 and ny >= 0 and nx < dungeon.width and ny < dungeon.height then
                        local neighbor = MultiFloor.Index(nx, ny, dungeon.width)
                        if layer.grid[neighbor] == MultiFloor.Tiles.FLOOR then
                            candidates[#candidates + 1] = {
                                x = x, y = y, dx = direction[1], dy = direction[2],
                                roomId = layer.roomId[neighbor],
                            }
                            break
                        end
                    end
                end
            end
        end
        -- Generic emphasis markers in high-tier rooms. The prop kind and the
        -- per-role counts are theme DATA; the pass hardcodes no ruins model.
        local reservedWall = {}
        local emphasis = profile.emphasis
        if emphasis then
            for _, room in ipairs(dungeon.rooms) do
                local target = room.floor == layer.floor and emphasis.roleTargets[room.type]
                if target then
                    local roomCandidates = {}
                    for _, candidate in ipairs(candidates) do
                        if candidate.roomId == room.id then roomCandidates[#roomCandidates + 1] = candidate end
                    end
                    rng:Shuffle(roomCandidates)
                    local placed = {}
                    for _, candidate in ipairs(roomCandidates) do
                        if #placed >= target then break end
                        local close = false
                        for _, other in ipairs(placed) do
                            if math.max(math.abs(other.x - candidate.x), math.abs(other.y - candidate.y))
                                < (emphasis.minSpacing or 4) then
                                close = true
                                break
                            end
                        end
                        if not close then
                            placed[#placed + 1] = candidate
                            reservedWall[MultiFloor.Index(candidate.x, candidate.y, dungeon.width)] = true
                            layer.props[#layer.props + 1] = {
                                kind = emphasis.kind, x = candidate.x, y = candidate.y,
                                dx = candidate.dx, dy = candidate.dy, roomId = room.id,
                                rot = 0, scale = 1,
                            }
                        end
                    end
                end
            end
        end

        -- Generic wall-fixture richness. "dense" spams a fixture on every clear
        -- candidate (feeding the torch light channel); "spaced" lays fixtures on
        -- a spacing grid from a priority decor list. No prop kind is hardcoded --
        -- the fixtures, accents and decor list all come from theme DATA.
        local fixtures = profile.wallFixtures
        if fixtures and fixtures.mode == "dense" then rng:Shuffle(candidates) end
        local decorList = profile.wallDecor
        if fixtures and fixtures.channel == "pack" then
            local pack = ThemePacks.Get(settingKey)
            decorList = pack and pack.wallRules or {}
        end
        local wallDecor = {}
        for _, candidate in ipairs(candidates) do
            local clear = not reservedWall[MultiFloor.Index(candidate.x, candidate.y, dungeon.width)]
            if clear and fixtures and fixtures.channel == "torch" then
                for _, torch in ipairs(layer.torches) do
                    if math.max(math.abs(torch.x - candidate.x), math.abs(torch.y - candidate.y))
                        < (fixtures.proximity or 5) then
                        clear = false
                        break
                    end
                end
            end
            if clear and fixtures then
                if fixtures.mode == "dense" then
                    if fixtures.channel == "torch" then
                        layer.torches[#layer.torches + 1] = candidate
                    end
                    for _, accent in ipairs(profile.wallAccents or {}) do
                        if (not accent.requireThemeFlag or theme[accent.requireThemeFlag])
                            and rng:Chance((accent.chanceBase or 0) + (accent.chanceDensity or 0) * density) then
                            layer.props[#layer.props + 1] = {
                                kind = accent.kind, x = candidate.x, y = candidate.y,
                                dx = candidate.dx, dy = candidate.dy, rot = 0,
                                scale = rng:Float(accent.scaleMin or 0.9, accent.scaleMax or 1.1),
                            }
                            break
                        end
                    end
                else
                    local close = false
                    for _, placed in ipairs(wallDecor) do
                        if math.max(math.abs(placed.x - candidate.x), math.abs(placed.y - candidate.y))
                            < (fixtures.spacing or 5) then
                            close = true
                            break
                        end
                    end
                    if not close then
                        for _, entry in ipairs(decorList or {}) do
                            local chance = (entry.chanceBase or entry.chance or 0)
                                + (entry.chanceDensity or 0) * density
                            if rng:Chance(chance) then
                                local neighbor = MultiFloor.Index(candidate.x + candidate.dx,
                                    candidate.y + candidate.dy, dungeon.width)
                                layer.props[#layer.props + 1] = {
                                    kind = entry.kind, x = candidate.x, y = candidate.y,
                                    dx = candidate.dx, dy = candidate.dy, rot = 0,
                                    roomId = layer.roomId[neighbor],
                                    scale = rng:Float(entry.scaleMin or 0.92, entry.scaleMax or 1.0),
                                }
                                wallDecor[#wallDecor + 1] = candidate
                                break
                            end
                        end
                    end
                end
            end
        end


        -- Generic region-feature decoration. The cells, enable flags, props and
        -- patch parameters come from the environment profile; the pass only
        -- executes the declared operations.
        local terrainDecor = profile.terrainDecor or {}
        local surfaceProps = terrainDecor.surfaceProps
        if surfaceProps and theme[surfaceProps.themeFlag] then
            for _, surfaceCell in ipairs(layer[surfaceProps.cells] or {}) do
                if rng:Chance(surfaceProps.chance or 0) then
                    layer.props[#layer.props+1] = {kind=surfaceProps.kind,x=surfaceCell.x,y=surfaceCell.y,
                        roomId=layer.roomId[MultiFloor.Index(surfaceCell.x,surfaceCell.y,dungeon.width)],
                        rot=rng:Float(0,math.pi*2),
                        scale=rng:Float(surfaceProps.scaleMin or 0.6,surfaceProps.scaleMax or 1.2)}
                end
            end
        end
        local breachSpec = terrainDecor.wallBreach
        if breachSpec and theme[breachSpec.themeFlag] then
            local sites = {}
            for _, candidate in ipairs(candidates) do
                if candidate.roomId > 0 then sites[#sites+1]=candidate end
            end
            rng:Shuffle(sites)
            local breaches = {}
            for _, site in ipairs(sites) do
                if #breaches >= (breachSpec.maxSites or 5) then break end
                local close=false
                for _, other in ipairs(breaches) do
                    if math.max(math.abs(other.x-site.x),math.abs(other.y-site.y))
                        < (breachSpec.spacing or 7) then close=true break end
                end
                if not close then breaches[#breaches+1]=site end
            end
            local secondary = breachSpec.secondary
            local secondaryMask={}
            for _, breach in ipairs(breaches) do
                layer.props[#layer.props+1]={kind=breachSpec.kind,x=breach.x,y=breach.y,
                    dx=breach.dx,dy=breach.dy,roomId=breach.roomId,rot=0,
                    scale=rng:Float(breachSpec.scaleMin or 0.9,breachSpec.scaleMax or 1.2)}
                if secondary then
                    for oy=-secondary.radius,secondary.radius do for ox=-secondary.radius,secondary.radius do
                        local x,y=breach.x+ox,breach.y+oy
                        if x>=0 and y>=0 and x<dungeon.width and y<dungeon.height then
                            local cell=MultiFloor.Index(x,y,dungeon.width)
                            if layer.grid[cell]==MultiFloor.Tiles.FLOOR and not secondaryMask[cell]
                                and rng:Chance(secondary.chance or 0) then
                                secondaryMask[cell]=true
                                layer.props[#layer.props+1]={kind=secondary.kind,x=x,y=y,roomId=layer.roomId[cell],
                                    rot=rng:Float(0,math.pi*2),scale=rng:Float(secondary.scaleMin or 0.7,secondary.scaleMax or 1.4)}
                            end
                        end
                    end end
                end
            end
        end

        -- Generic depth-gated ambient clutter (dungeon supplies "bones"). The
        -- prop kind, the theme flag that enables it, and the depth gate are all
        -- data -- the pass itself names no ruins model.
        local clutter = profile.ambientClutter
        if clutter and (not clutter.requireThemeFlag or theme[clutter.requireThemeFlag]) then
            for cell, tile in ipairs(layer.grid) do
                local roomId = layer.roomId[cell] or 0
                local room = roomId > 0 and dungeon.rooms[roomId] or nil
                if tile == MultiFloor.Tiles.FLOOR and not occupied[cell] and not layer.doorway[cell]
                    and (not clutter.avoidCorridor or not layer.corridor[cell])
                    and room and room.depth > (clutter.minDepth or 0)
                    and rng:Chance((clutter.chanceBase or 0) + (clutter.chanceDensity or 0) * density) then
                    local x, y = MultiFloor.Coordinates(cell, dungeon.width)
                    layer.props[#layer.props + 1] = {
                        kind = clutter.kind, x = x, y = y, roomId = roomId,
                        rot = rng:Float(0, math.pi * 2),
                        scale = rng:Float(clutter.scaleMin or 0.8, clutter.scaleMax or 1.2),
                    }
                end
            end
        end

        local edgeSpec = terrainDecor.poolEdges
        if edgeSpec and theme.pools and edgeSpec.poolModes[theme.pools.mode] then
            local probability=edgeSpec.poolModes[theme.pools.mode]
            local directions={{1,0},{-1,0},{0,1},{0,-1}}
            for _,pool in ipairs(layer.pools) do for _,direction in ipairs(directions) do
                local x,y=pool.x+direction[1],pool.y+direction[2]
                if x>=0 and y>=0 and x<dungeon.width and y<dungeon.height then
                    local cell=MultiFloor.Index(x,y,dungeon.width)
                    if layer.grid[cell]==MultiFloor.Tiles.FLOOR and rng:Chance(probability) then
                        layer.props[#layer.props+1]={kind=edgeSpec.kind,x=x,y=y,dx=direction[1],dy=direction[2],
                            roomId=layer.roomId[cell],rot=rng:Float(0,math.pi*2),
                            scale=rng:Float(edgeSpec.scaleMin or 0.9,edgeSpec.scaleMax or 1.5)}
                    end
                end
            end end
        end

        -- Generic corridor scatter (floor markings along paths). The prop list
        -- and rotation style are theme DATA; hospital supplies floorStripe /
        -- floorArrow, but any theme can decorate its corridors the same way.
        local corridorScatter = profile.corridorScatter
        if corridorScatter then
            for cell, tile in ipairs(layer.grid) do
                if layer.corridor[cell] and tile == MultiFloor.Tiles.FLOOR then
                    local x, y = MultiFloor.Coordinates(cell, dungeon.width)
                    for _, entry in ipairs(corridorScatter) do
                        if rng:Chance((entry.chanceBase or 0) + (entry.chanceDensity or 0) * density) then
                            local rot
                            if entry.rotMode == "quarter" then rot = rng:Int(0, 3) * math.pi * 0.5
                            else rot = rng:Chance(0.5) and 0 or math.pi * 0.5 end
                            layer.props[#layer.props + 1] = {
                                kind = entry.kind, x = x, y = y, rot = rot,
                                scale = rng:Float(entry.scaleMin or 0.85, entry.scaleMax or 1.08),
                            }
                            break
                        end
                    end
                end
            end
        end
    end
end

local function GenerateAttempt(seed, parameters)
    local floorCount = math.max(1, math.floor((parameters.floorCount or 2) + 0.5))
    local floorHeight = MultiFloor.NormalizeFloorHeight(parameters.floorHeight)
    local emptyScene = parameters.emptyScene == true
    local stableSeed = Random.U32(parameters.stableSeed or seed)
    local changedFloor = parameters.changedFloor
    local floorSeeds = {}
    for floor = 0, floorCount - 1 do
        floorSeeds[floor + 1] = changedFloor == floor and seed or stableSeed
    end
    local sourceCounts = parameters.roomCountsByFloor or {}
    local roomCounts = {}
    if emptyScene then
        for floor = 1, floorCount do roomCounts[floor] = 0 end
    else
        for floor = 1, #sourceCounts do roomCounts[floor] = sourceCounts[floor] end
        if #roomCounts == 0 then
            local total = math.max(6, math.floor((parameters.roomCount or 42) + 0.5))
            local base = math.floor(total / floorCount)
            for floor = 1, floorCount do roomCounts[floor] = base end
            for floor = 1, total - base * floorCount do roomCounts[floor] = roomCounts[floor] + 1 end
        end
        for floor = 1, floorCount do roomCounts[floor] = Clamp(math.floor((roomCounts[floor] or 21) + 0.5), 3, 50) end
    end
    local loopRates = parameters.loopRatesByFloor or { parameters.loopRate or 0.15 }
    local densities = parameters.decorDensitiesByFloor or { parameters.decorDensity or 0.6 }

    local rooms, nextId = {}, 1
    if emptyScene then
        -- Fixed PCG hands an intentionally empty, renderer-valid shell to the
        -- next generation stage. Colleagues can replace this branch with their
        -- authored room and prop rules without changing the UI contract.
    elseif parameters.editorEnabled and parameters.editorRooms and #parameters.editorRooms > 0 then
        for index, source in ipairs(parameters.editorRooms) do
            local width, height = Clamp(math.floor((source.w or 7) + 0.5), 5, 24), Clamp(math.floor((source.h or 7) + 0.5), 5, 24)
            rooms[index] = {
                id = index, cx = math.floor((source.cx or source.x or 0) + 0.5), cy = math.floor((source.cy or source.y or 0) + 0.5),
                sx0 = math.floor((source.cx or source.x or 0) + 0.5), sy0 = math.floor((source.cy or source.y or 0) + 0.5),
                w = width, h = height, arch = ClassifyRoom(width, height), shape = "rect",
                floor = Clamp(math.floor((source.floor or 0) + 0.5), 0, floorCount - 1),
                type = ROOM_TYPES.COMBAT, depth = 0, difficulty = 0.2, degree = 0,
                locked = source.locked == true, roleHint = source.roleHint, roomGroupId = source.roomGroupId,
                stairRoom = source.stairRoom == true, stairRoomPairId = source.stairRoomPairId,
            }
        end
        roomCounts = {}
        for floor = 1, floorCount do roomCounts[floor] = 0 end
        for _, room in ipairs(rooms) do roomCounts[room.floor + 1] = roomCounts[room.floor + 1] + 1 end
    else
        for floor = 0, floorCount - 1 do
            ---@type table<integer, table>
            local generated = {}
            if parameters.preserveDungeon and changedFloor ~= nil and floor ~= changedFloor then
                for _, source in ipairs(parameters.preserveDungeon.rooms or {}) do
                    if source.floor == floor then
                        generated[#generated + 1] = {
                            id = nextId + #generated, cx = source.cx, cy = source.cy,
                            sx0 = source.cx, sy0 = source.cy, w = source.w, h = source.h,
                            arch = source.arch or ClassifyRoom(source.w, source.h), shape = source.shape or "rect",
                            floor = floor, type = ROOM_TYPES.COMBAT, depth = 0, difficulty = 0.2, degree = 0,
                            locked = source.locked == true, roleHint = source.roleHint,
                            roomGroupId = source.roomGroupId, sourceRoomId = source.id,
                            semanticAnchor = source.semanticAnchor == true,
                        }
                    end
                end
            else
                generated = ScatterRooms(FloorRandom(floorSeeds, floor, STREAM_LAYOUT),
                    roomCounts[floor + 1], floor, 0, 0, nextId)
            end
            local generatedRooms = generated or {}
            for _, room in ipairs(generatedRooms) do rooms[#rooms + 1] = room end
            nextId = nextId + #generatedRooms
        end
    end
    local floorRoomIndices = {}
    for _, room in ipairs(rooms) do
        local key = room.floor + 1
        floorRoomIndices[key] = (floorRoomIndices[key] or 0) + 1
        room.floorIndex = floorRoomIndices[key]
    end
    -- Authored layouts are authoritative. Running the scatter separation pass here
    -- made a room jump again as soon as the user released the resize/move drag.
    if not emptyScene and not parameters.editorEnabled then
        SeparateRooms(rooms, nil, parameters.preserveDungeon and changedFloor or nil)
    end
    local edges = nil
    if parameters.editorEnabled and parameters.editorEdges ~= nil then
        edges = {}
        for _, room in ipairs(rooms) do room.degree = 0 end
        local seen = {}
        for _, source in ipairs(parameters.editorEdges) do
            local a, b = math.floor(source.a or 0), math.floor(source.b or 0)
            local key = math.min(a, b) .. ":" .. math.max(a, b)
            if a >= 1 and b >= 1 and a <= #rooms and b <= #rooms and a ~= b and not seen[key]
                and math.abs(rooms[a].floor - rooms[b].floor) <= 1 then
                local bends = {}
                for _, point in ipairs(source.bends or {}) do
                    bends[#bends + 1] = { x = tonumber(point.x) or 0, y = tonumber(point.y) or 0 }
                end
                local function CopyDoor(spec)
                    if not spec then return nil end
                    return { side = spec.side, offset = tonumber(spec.offset) or 0 }
                end
                local function CopyPoint(point)
                    if not point then return nil end
                    return { x = tonumber(point.x) or 0, y = tonumber(point.y) or 0 }
                end
                local function CopyStairSpec(spec)
                    if not spec then return nil end
                    return {
                        id = spec.id, mode = spec.mode or "stable-auto", pending = spec.pending == true,
                        anchor = CopyPoint(spec.anchor), previewAnchor = CopyPoint(spec.previewAnchor),
                        direction = spec.direction, previewDirection = spec.previewDirection,
                        style = spec.style or "l-turn", previewStyle = spec.previewStyle,
                        width = MultiFloor.NormalizeStairWidth(spec.width),
                        previewWidth = spec.previewWidth and MultiFloor.NormalizeStairWidth(spec.previewWidth) or nil,
                        length = tonumber(spec.length), previewLength = tonumber(spec.previewLength),
                        landingDepth = math.max(1, math.floor((tonumber(spec.landingDepth) or 2) + 0.5)),
                        previewLandingDepth = tonumber(spec.previewLandingDepth), manualPreview = spec.manualPreview == true,
                        lateralCenterOffset = tonumber(spec.lateralCenterOffset),
                        previewLateralCenterOffset = tonumber(spec.previewLateralCenterOffset),
                        allowFallback = spec.allowFallback == true,
                        candidateIndex = math.max(0, math.floor(tonumber(spec.candidateIndex) or 0)),
                    }
                end
                edges[#edges + 1] = {
                    id = #edges + 1, a = a, b = b, isLoop = source.isLoop == true,
                    isCritical = false, isManual = source.isManual == true,
                    isEditor = true, bends = bends,
                    width = Clamp(math.floor((tonumber(source.width) or 2) + 0.5), 1, 6),
                    doorA = CopyDoor(source.doorA), doorB = CopyDoor(source.doorB),
                    kind = source.kind, stairSpec = CopyStairSpec(source.stairSpec),
                }
                rooms[a].degree, rooms[b].degree = rooms[a].degree + 1, rooms[b].degree + 1
                seen[key] = true
            end
        end
    else
        edges = BuildGraph(rooms, floorCount, loopRates, floorSeeds)
        edges = MergePreservedFloorEdges(rooms, edges, parameters.preserveDungeon, changedFloor)
    end
    local entrance, boss, maxDepth, criticalLength = nil, nil, 1, 0
    if not emptyScene then
        entrance, boss, maxDepth, criticalLength = AssignSemantics(rooms, edges, floorCount, floorSeeds)
    end
    local roomGroupsById, roomGroupCounts = AssignRoomGroups(rooms, parameters.roomGroups)
    local settingKey = parameters.settingKey or "dungeon"
    local theme = Themes.Resolve(settingKey, parameters.theme or "ancient")
    local environment = EnvironmentProfiles.Resolve(settingKey)
    -- Generic room-feature selector. The feature field, eligibility and theme
    -- flag are profile data; this is no longer a dungeon-only lake/grave branch.
    for floor = 0, floorCount - 1 do
        local featureRng = FloorRandom(floorSeeds, floor, STREAM_FEATURES)
        for _, feature in ipairs(environment.roomFeatures or {}) do
            if theme[feature.themeFlag] then
                local candidates = {}
                for _, room in ipairs(rooms) do
                    local allowedShape = not feature.shapeNot or room.shape ~= feature.shapeNot
                    if room.floor == floor and feature.roomTypes[room.type]
                        and math.min(room.w, room.h) >= feature.minDim and allowedShape then
                        candidates[#candidates + 1] = room
                    end
                end
                for _ = 1, math.min(math.max(1, math.ceil(feature.count / floorCount)), #candidates) do
                    local selected = table.remove(candidates, featureRng:Int(1, #candidates))
                    if selected then selected[feature.roomField] = true end
                end
            end
        end
    end
    if floorCount > 1 and not parameters.editorEnabled then
        MultiFloor.CompactRoomsByFloor(rooms, floorCount, ROOM_GAP, 0.72, 300,
            parameters.preserveDungeon and changedFloor or nil)
    end
    local width, height, editorOffset
    if emptyScene then
        width, height = 1, 1
    elseif parameters.editorEnabled then
        width, height, editorOffset = RebaseRooms(rooms, edges)
    else
        width, height = RebaseGeneratedRoomsByFloor(rooms, edges, floorCount)
        RefreshGeneratedStairAlternates(rooms, edges)
    end
    local carvingRngByFloor = {}
    for floor = 0, floorCount - 1 do
        carvingRngByFloor[floor + 1] = FloorRandom(floorSeeds, floor, STREAM_CARVING)
    end
    local multi = MultiFloor.Build({
        width = width, height = height, floorCount = floorCount,
        floorHeight = floorHeight,
        rooms = rooms, edges = edges, entrance = entrance,
        changedFloor = changedFloor,
        settingKey = parameters.settingKey or "dungeon",
        theme = parameters.theme or "ancient", rng = carvingRngByFloor[1], rngByFloor = carvingRngByFloor,
    })
    local dungeon = {
        seed = seed, width = width, height = height, W = width, H = height,
        floorCount = floorCount, floorHeight = floorHeight,
        sceneInfo = {
            floorHeight = floorHeight,
            cellSize = GeometryRules.CELL_SIZE,
            gridWidth = width,
            gridHeight = height,
            worldWidth = width * GeometryRules.CELL_SIZE,
            worldDepth = height * GeometryRules.CELL_SIZE,
            totalHeight = floorCount * floorHeight,
        },
        rooms = rooms, edges = multi.edges, connectors = multi.connectors, layers = multi.layers,
        entrance = entrance, boss = boss, maxDepth = maxDepth,
        valid = multi.valid, errors = multi.errors, bfs3 = multi.bfs3,
        stairAudits = multi.stairAudits,
        passedStairs = multi.passedStairs,
        totalStairs = multi.totalStairs,
        theme = parameters.theme or "ancient",
        roomCountsByFloor = roomCounts, loopRatesByFloor = loopRates,
        decorDensitiesByFloor = densities,
        roomGroupCounts = roomGroupCounts,
        editorOffset = editorOffset,
        stats = {
            rooms = #rooms, edges = #multi.edges,
            loops = 0, criticalLength = criticalLength,
            floors = floorCount, reach = multi.reach,
        },
    }
    for _, edge in ipairs(multi.edges) do if edge.isLoop then dungeon.stats.loops = dungeon.stats.loops + 1 end end
    Decorate(dungeon, floorSeeds, densities, parameters.settingKey or "dungeon", parameters.theme or "ancient",
        roomGroupsById)
    local floorTiles = 0
    for _, layer in ipairs(dungeon.layers) do
        for _, tile in ipairs(layer.grid) do if tile == MultiFloor.Tiles.FLOOR then floorTiles = floorTiles + 1 end end
    end
    dungeon.stats.floorTiles = floorTiles
    dungeon.sceneInfo.floorArea = floorTiles * GeometryRules.CELL_SIZE * GeometryRules.CELL_SIZE
    if emptyScene then
        dungeon.name = "固定空场景"
    else
        local nameA = { "沉没", "遗忘", "寂静", "空洞", "古老", "破碎", "无名", "陨落" }
        local nameB = { "大厅", "病区", "中庭", "深层", "节点", "回廊", "核心区", "资料库" }
        if parameters.settingKey == "hospital" then
            nameA = { "废弃", "静默", "隔离", "苍白", "失序", "封锁", "无菌", "深夜" }
            nameB = { "病区", "诊疗楼", "手术区", "急诊层", "隔离舱", "住院部", "地下病房", "档案室" }
        end
        local nameRng = Random.new(StreamSeed(stableSeed, 0, STREAM_NAME))
        dungeon.name = nameA[nameRng:Int(1, #nameA)] .. nameB[nameRng:Int(1, #nameB)]
    end
    dungeon.hash = MultiFloor.StructuralHash(dungeon)
    return dungeon
end

function DungeonGenerator.Generate(parameters)
    parameters = parameters or {}
    local originalSeed = Random.U32(parameters.seed or 1337)
    parameters.stableSeed = originalSeed
    local attemptSeed = originalSeed
    local last = nil
    for attempt = 1, 8 do
        last = GenerateAttempt(attemptSeed, parameters)
        last.requestedSeed = originalSeed
        last.attempts = attempt
        if last.valid then return last end
        attemptSeed = Random.U32(Random.IMul32(attemptSeed, 9301) + 49297)
    end
    return last
end

DungeonGenerator.RoomTypes = ROOM_TYPES

return DungeonGenerator
