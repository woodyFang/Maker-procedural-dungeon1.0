local RouteEditing = require("UI.Editor.RouteEditing")
local StairContract = require("Generation.StairContract")

local EditorData = {}

local function CopyValue(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[CopyValue(key, seen)] = CopyValue(item, seen) end
    return result
end

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

function EditorData.CopyRooms(rooms)
    local result = {}
    for index, room in ipairs(rooms or {}) do
        result[index] = {
            id = index,
            cx = room.cx,
            cy = room.cy,
            w = room.w,
            h = room.h,
            floor = room.floor,
            locked = room.locked == true,
            roleHint = room.roleHint,
            type = room.type,
            roomGroupId = room.roomGroupId,
            stairRoom = room.stairRoom == true,
            stairRoomPairId = room.stairRoomPairId,
            pendingConnection = room.pendingConnection == true,
        }
    end
    return result
end

function EditorData.HasPendingConnections(rooms)
    for _, room in ipairs(rooms or {}) do
        if room.pendingConnection == true then return true end
    end
    return false
end

function EditorData.ResolvePendingConnections(rooms, links)
    local adjacency, visited, changed = {}, {}, false
    for index = 1, #(rooms or {}) do adjacency[index] = {} end
    for _, link in ipairs(links or {}) do
        if adjacency[link.a] and adjacency[link.b] then
            adjacency[link.a][#adjacency[link.a] + 1] = link.b
            adjacency[link.b][#adjacency[link.b] + 1] = link.a
        end
    end
    -- A newly drawn component becomes scene-ready after it reaches any room
    -- that already belongs to the generated graph.
    for start = 1, #(rooms or {}) do
        if not visited[start] then
            local queue, component, head, reachesScene = { start }, {}, 1, false
            visited[start] = true
            while head <= #queue do
                local index = queue[head]
                head = head + 1
                component[#component + 1] = index
                if rooms[index].pendingConnection ~= true then reachesScene = true end
                for _, neighbor in ipairs(adjacency[index]) do
                    if not visited[neighbor] then
                        visited[neighbor] = true
                        queue[#queue + 1] = neighbor
                    end
                end
            end
            if reachesScene then
                for _, index in ipairs(component) do
                    if rooms[index].pendingConnection == true then
                        rooms[index].pendingConnection = false
                        changed = true
                    end
                end
            end
        end
    end
    return changed
end

function EditorData.CopyStairSpec(spec)
    if not spec then return nil end
    return {
        id = spec.id, mode = spec.mode or "stable-auto", pending = spec.pending == true,
        anchor = RouteEditing.CopyPoint(spec.anchor), previewAnchor = RouteEditing.CopyPoint(spec.previewAnchor),
        direction = spec.direction, previewDirection = spec.previewDirection,
        style = spec.style or "l-turn", previewStyle = spec.previewStyle,
        width = StairContract.NormalizeWidth(spec.width),
        previewWidth = spec.previewWidth and StairContract.NormalizeWidth(spec.previewWidth) or nil,
        length = tonumber(spec.length), previewLength = tonumber(spec.previewLength),
        landingDepth = tonumber(spec.landingDepth) or 2,
        previewLandingDepth = tonumber(spec.previewLandingDepth), manualPreview = spec.manualPreview == true,
        candidateIndex = tonumber(spec.candidateIndex) or 0,
        candidateCount = tonumber(spec.candidateCount) or 0,
        invalid = spec.invalid == true, error = spec.error,
    }
end

function EditorData.CopyConnector(connector, offset)
    if not connector then return nil end
    local seen = {}
    local function CopyValue(value)
        if type(value) ~= "table" then return value end
        if seen[value] then return seen[value] end
        local result = {}
        seen[value] = result
        for key, item in pairs(value) do result[key] = CopyValue(item) end
        return result
    end
    local result = CopyValue(connector)
    local dx, dy = tonumber(offset and offset.x) or 0, tonumber(offset and offset.y) or 0
    local function Localize(point)
        if point and tonumber(point.x) and tonumber(point.y) then
            point.x, point.y = point.x - dx, point.y - dy
        end
    end
    for _, key in ipairs({ "lower", "turn", "upper", "lowerApproach", "upperApproach",
        "lowerApproachGate", "upperApproachGate", "lowerApproachRouteCell", "upperApproachRouteCell" }) do
        Localize(result[key])
    end
    for _, key in ipairs({ "lowerRoute", "upperRoute" }) do
        for _, point in ipairs(result[key] or {}) do Localize(point) end
    end
    return result
end

function EditorData.CopyLink(link)
    local bends, route = {}, {}
    for _, point in ipairs(link.bends or {}) do bends[#bends + 1] = RouteEditing.CopyPoint(point) end
    for _, point in ipairs(link.autoRoute or link.route or {}) do route[#route + 1] = RouteEditing.CopyPoint(point) end
    return {
        a = link.a,
        b = link.b,
        isLoop = link.isLoop == true,
        isManual = link.isManual == true,
        width = Clamp(math.floor((tonumber(link.width or link.carvedWidth) or 2) + 0.5), 1, 6),
        bends = bends,
        doorA = RouteEditing.CopyDoor(link.doorA),
        doorB = RouteEditing.CopyDoor(link.doorB),
        autoRoute = route,
        kind = link.kind,
        connectorId = link.connectorId,
        stairSpec = EditorData.CopyStairSpec(link.stairSpec),
        runtimeGenerated = link.runtimeGenerated == true,
        runtimeRoutes = CopyValue(link.runtimeRoutes or {}),
        runtimeStairs = CopyValue(link.runtimeStairs or {}),
    }
end

function EditorData.LinkKey(link)
    if not link then return nil end
    return math.min(link.a, link.b) .. ":" .. math.max(link.a, link.b)
end

function EditorData.EnsureStairSpec(link, edge)
    if link.runtimeGenerated or link.kind ~= "stairs" or not link.connector or link.stairSpec then return end
    link.stairSpec = {
        id = link.connector.stairId or ("stair-edge-" .. tostring(edge.id or edge.connectorId)),
        mode = link.connector.mode or "stable-auto", pending = false,
        style = link.connector.style or "l-turn",
        anchor = RouteEditing.CopyPoint(link.connector.lower), direction = link.connector.direction,
        width = StairContract.NormalizeWidth(link.connector.width or link.width or 2),
        length = link.connector.length, landingDepth = link.connector.landingDepth or 2,
        candidateIndex = link.connector.candidateIndex or 0,
        candidateCount = link.connector.candidateCount or 0, invalid = false,
    }
end

function EditorData.FindLink(links, a, b, excludedIndex)
    for index, link in ipairs(links or {}) do
        if index ~= excludedIndex and ((link.a == a and link.b == b) or (link.a == b and link.b == a)) then
            return index
        end
    end
    return nil
end

return EditorData
