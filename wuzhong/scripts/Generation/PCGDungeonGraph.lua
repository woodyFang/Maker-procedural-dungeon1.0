local PCGRandomStream = require("Generation.PCGRandomStream")

local PCGDungeonGraph = {}

local function V(x, y, z) return { x or 0, y or 0, z or 0 } end
local function Sub(a, b) return V(a[1] - b[1], a[2] - b[2], a[3] - b[3]) end
local function Add(a, b) return V(a[1] + b[1], a[2] + b[2], a[3] + b[3]) end
local function Scale(a, amount) return V(a[1] * amount, a[2] * amount, a[3] * amount) end
local function Dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function Cross(a, b)
    return V(a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3],
        a[1] * b[2] - a[2] * b[1])
end
local function Length2(a) return Dot(a, a) end
local function Distance(a, b) return math.sqrt(Length2(Sub(a, b))) end

local function CopyValue(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[key] = CopyValue(item, seen) end
    return result
end

local function SortedKey(values)
    table.sort(values)
    return table.concat(values, ":")
end

local function Circumsphere(a, b, c, d, epsilon)
    local ba, ca, da = Sub(b, a), Sub(c, a), Sub(d, a)
    local denominator = 2 * Dot(ba, Cross(ca, da))
    if math.abs(denominator) <= epsilon then return nil end
    local offset = Scale(Add(Add(
        Scale(Cross(ca, da), Length2(ba)),
        Scale(Cross(da, ba), Length2(ca))),
        Scale(Cross(ba, ca), Length2(da))), 1 / denominator)
    local radius2 = Length2(offset)
    if radius2 >= 1e30 then return nil end
    return Add(a, offset), radius2
end

local function AddUniqueEdge(edges, edgeKeys, a, b)
    local x, y = math.min(a, b), math.max(a, b)
    local key = x .. ":" .. y
    if edgeKeys[key] then return end
    edgeKeys[key] = true
    edges[#edges + 1] = { a = x, b = y }
end

function PCGDungeonGraph.BuildDelaunay(layout)
    local rooms = layout.rooms or {}
    local roomCount = #rooms
    local positions = {}
    local boundsMin, boundsMax
    for _, room in ipairs(rooms) do
        local p = room.position
        positions[#positions + 1] = V(p[1], p[2], p[3])
        boundsMin = boundsMin and V(math.min(boundsMin[1], p[1]), math.min(boundsMin[2], p[2]),
            math.min(boundsMin[3], p[3])) or V(p[1], p[2], p[3])
        boundsMax = boundsMax and V(math.max(boundsMax[1], p[1]), math.max(boundsMax[2], p[2]),
            math.max(boundsMax[3], p[3])) or V(p[1], p[2], p[3])
    end
    if roomCount < 2 then return { tets = {}, edges = {}, warning = "Delaunay requires at least two rooms" } end

    local size = Sub(boundsMax, boundsMin)
    local scale = math.max(1, size[1], size[2], size[3])
    local denominatorEpsilon = math.max(1, scale * scale * scale) * 1e-10
    local volumeEpsilon = math.max(1, scale * scale * scale) * 1e-8
    local sphereEpsilon = math.max(1, scale * scale) * 1e-6
    for index = 0, roomCount - 1 do
        local jitter = V(
            PCGRandomStream.Rand(PCGRandomStream.Affine(8147, index, 17.123)) - 0.5,
            PCGRandomStream.Rand(PCGRandomStream.Affine(8147, index, 41.731)) - 0.5,
            PCGRandomStream.Rand(PCGRandomStream.Affine(8147, index, 73.357)) - 0.5)
        positions[index + 1] = Add(positions[index + 1], Scale(jitter, scale * 1e-5))
    end

    local finalTets, edges, edgeKeys = {}, {}, {}
    if roomCount >= 4 then
        local center = Scale(Add(boundsMin, boundsMax), 0.5)
        local radius = scale * 64
        positions[#positions + 1] = Add(center, Scale(V(1, 1, 1), radius))
        positions[#positions + 1] = Add(center, Scale(V(-1, -1, 1), radius))
        positions[#positions + 1] = Add(center, Scale(V(-1, 1, -1), radius))
        positions[#positions + 1] = Add(center, Scale(V(1, -1, -1), radius))
        local active = { { roomCount, roomCount + 1, roomCount + 2, roomCount + 3 } }

        for inserted = 0, roomCount - 1 do
            local bad, faces, faceByKey = {}, {}, {}
            for tetIndex, tet in ipairs(active) do
                local sphereCenter, radius2 = Circumsphere(positions[tet[1] + 1], positions[tet[2] + 1],
                    positions[tet[3] + 1], positions[tet[4] + 1], denominatorEpsilon)
                if sphereCenter and Length2(Sub(positions[inserted + 1], sphereCenter)) <= radius2 + sphereEpsilon then
                    bad[tetIndex] = true
                    for _, face in ipairs({
                        { tet[1], tet[2], tet[3] }, { tet[1], tet[4], tet[2] },
                        { tet[1], tet[3], tet[4] }, { tet[2], tet[4], tet[3] },
                    }) do
                        local key = SortedKey({ face[1], face[2], face[3] })
                        local existing = faceByKey[key]
                        if existing then existing.count = existing.count + 1
                        else
                            existing = { a = tonumber(key:match("^(%-?%d+)")), count = 1 }
                            local values = {}
                            for value in key:gmatch("%-?%d+") do values[#values + 1] = tonumber(value) end
                            existing.a, existing.b, existing.c = values[1], values[2], values[3]
                            faceByKey[key], faces[#faces + 1] = existing, existing
                        end
                    end
                end
            end
            local rebuilt = {}
            for index, tet in ipairs(active) do if not bad[index] then rebuilt[#rebuilt + 1] = tet end end
            for _, face in ipairs(faces) do
                if face.count == 1 then
                    local a, b, c = positions[face.a + 1], positions[face.b + 1], positions[face.c + 1]
                    local volume6 = Dot(Sub(b, a), Cross(Sub(c, a), Sub(positions[inserted + 1], a)))
                    if math.abs(volume6) > volumeEpsilon then
                        rebuilt[#rebuilt + 1] = { face.a, face.b, face.c, inserted }
                    end
                end
            end
            active = rebuilt
        end

        local tetKeys = {}
        for _, tet in ipairs(active) do
            if tet[1] < roomCount and tet[2] < roomCount and tet[3] < roomCount and tet[4] < roomCount then
                local key = SortedKey({ tet[1], tet[2], tet[3], tet[4] })
                if not tetKeys[key] then tetKeys[key], finalTets[#finalTets + 1] = true, tet end
            end
        end
        for _, tet in ipairs(finalTets) do
            AddUniqueEdge(edges, edgeKeys, tet[1], tet[2])
            AddUniqueEdge(edges, edgeKeys, tet[1], tet[3])
            AddUniqueEdge(edges, edgeKeys, tet[1], tet[4])
            AddUniqueEdge(edges, edgeKeys, tet[2], tet[3])
            AddUniqueEdge(edges, edgeKeys, tet[2], tet[4])
            AddUniqueEdge(edges, edgeKeys, tet[3], tet[4])
        end
    end

    local warning
    if #edges == 0 then
        for a = 0, roomCount - 1 do
            for b = a + 1, roomCount - 1 do AddUniqueEdge(edges, edgeKeys, a, b) end
        end
        if roomCount >= 4 then warning = "Input was degenerate; emitted a complete fallback graph" end
    end
    local firstEdgePrimitive = roomCount * 6 + #finalTets
    for index, edge in ipairs(edges) do
        edge.sourcePrimitive = firstEdgePrimitive + index - 1
        edge.weight = Distance(rooms[edge.a + 1].position, rooms[edge.b + 1].position)
    end
    return { tets = finalTets, edges = edges, warning = warning, scale = scale }
end

function PCGDungeonGraph.BuildMst(layout, delaunay)
    local rooms, inputEdges = layout.rooms or {}, delaunay.edges or {}
    local roomCount = #rooms
    if roomCount < 2 or #inputEdges == 0 then
        return { edges = {}, mstEdges = {}, loopEdges = {}, connected = false,
            warning = "Prim requires rooms and Delaunay edges" }
    end
    local visited = {}
    visited[1] = true
    local visitedCount, mst, mstSources, fallbackCount, totalWeight = 1, {}, {}, 0, 0

    while visitedCount < roomCount do
        local bestWeight, bestEdge, fromIndex, toIndex = 1e30, nil, nil, nil
        for _, edge in ipairs(inputEdges) do
            local a, b = edge.a + 1, edge.b + 1
            if (visited[a] == true) ~= (visited[b] == true) and edge.weight < bestWeight then
                bestWeight, bestEdge = edge.weight, edge
                if visited[a] then fromIndex, toIndex = a, b else fromIndex, toIndex = b, a end
            end
        end
        local usedFallback = false
        if not bestEdge then
            for a = 1, roomCount do
                if visited[a] then
                    for b = 1, roomCount do
                        if not visited[b] then
                            local weight = Distance(rooms[a].position, rooms[b].position)
                            if weight < bestWeight then
                                bestWeight, fromIndex, toIndex, usedFallback = weight, a, b, true
                            end
                        end
                    end
                end
            end
        end
        if not toIndex then break end
        local output = {
            a = fromIndex - 1, b = toIndex - 1, weight = bestWeight,
            isMst = true, isLoop = false, isFallback = usedFallback,
            sourcePrimitive = bestEdge and bestEdge.sourcePrimitive or -1,
        }
        mst[#mst + 1] = output
        if usedFallback then fallbackCount = fallbackCount + 1
        else mstSources[bestEdge.sourcePrimitive] = true end
        visited[toIndex] = true
        visitedCount = visitedCount + 1
        totalWeight = totalWeight + bestWeight
    end

    local loops = {}
    for _, edge in ipairs(inputEdges) do
        if not mstSources[edge.sourcePrimitive]
            and PCGRandomStream.Rand(PCGRandomStream.Affine(19037, edge.sourcePrimitive, 37.719)) < 0.125 then
            loops[#loops + 1] = {
                a = edge.a, b = edge.b, weight = edge.weight,
                isMst = false, isLoop = true, isFallback = false,
                sourcePrimitive = edge.sourcePrimitive,
            }
        end
    end
    local graph = {}
    for _, edge in ipairs(mst) do graph[#graph + 1] = edge end
    for _, edge in ipairs(loops) do graph[#graph + 1] = edge end
    return {
        edges = graph, mstEdges = mst, loopEdges = loops,
        connected = visitedCount == roomCount,
        fallbackCount = fallbackCount,
        totalWeight = totalWeight,
        warning = visitedCount == roomCount and nil or "Input graph is disconnected; MST is incomplete",
    }
end

function PCGDungeonGraph.BuildAuthored(layout, editorEdges)
    local rooms, edges, mst, loops, errors = layout.rooms or {}, {}, {}, {}, {}
    local seen = {}
    for index, source in ipairs(editorEdges or {}) do
        local editorA = math.floor(tonumber(source.a) or 0)
        local editorB = math.floor(tonumber(source.b) or 0)
        local a, b = editorA - 1, editorB - 1
        local key = math.min(a, b) .. ":" .. math.max(a, b)
        if a < 0 or b < 0 or a >= #rooms or b >= #rooms then
            errors[#errors + 1] = "Editor edge " .. index .. " references an unknown room"
        elseif a == b then
            errors[#errors + 1] = "Editor edge " .. index .. " connects a room to itself"
        elseif seen[key] then
            errors[#errors + 1] = "Editor edge " .. index .. " duplicates " .. key
        else
            seen[key] = true
            local edge = CopyValue(source)
            edge.a, edge.b = a, b
            edge.isLoop = source.isLoop == true
            edge.isMst = not edge.isLoop
            edge.isFallback = false
            edge.sourcePrimitive = index - 1
            edge.weight = Distance(rooms[a + 1].position, rooms[b + 1].position)
            edge.kind = source.kind or (rooms[a + 1].floor ~= rooms[b + 1].floor and "stairs" or "corridor")
            edges[#edges + 1] = edge
            if edge.isLoop then loops[#loops + 1] = edge else mst[#mst + 1] = edge end
        end
    end

    local visited, queue = {}, {}
    if #rooms > 0 then visited[1], queue[1] = true, 1 end
    local head = 1
    while queue[head] do
        local room = queue[head]
        head = head + 1
        for _, edge in ipairs(edges) do
            local nextRoom
            if edge.a + 1 == room then nextRoom = edge.b + 1
            elseif edge.b + 1 == room then nextRoom = edge.a + 1 end
            if nextRoom and not visited[nextRoom] then
                visited[nextRoom] = true
                queue[#queue + 1] = nextRoom
            end
        end
    end
    local visitedCount = 0
    for _ in pairs(visited) do visitedCount = visitedCount + 1 end
    local connected = #rooms > 0 and visitedCount == #rooms
    if not connected then errors[#errors + 1] = "Editor graph is disconnected" end
    return {
        edges = edges,
        mstEdges = mst,
        loopEdges = loops,
        connected = connected and #errors == 0,
        fallbackCount = 0,
        totalWeight = 0,
        warning = errors[1],
        errors = errors,
        authored = true,
    }
end

function PCGDungeonGraph.Generate(layout, editorEdges)
    if editorEdges ~= nil then
        local graph = PCGDungeonGraph.BuildAuthored(layout, editorEdges)
        return {
            delaunay = { tets = {}, edges = graph.edges, authored = true },
            graph = graph,
        }
    end
    local delaunay = PCGDungeonGraph.BuildDelaunay(layout)
    return { delaunay = delaunay, graph = PCGDungeonGraph.BuildMst(layout, delaunay) }
end

return PCGDungeonGraph
