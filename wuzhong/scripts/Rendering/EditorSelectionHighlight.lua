local MultiFloor = require("Generation.MultiFloor")

local EditorSelectionHighlight = {}

local function SameEdge(a, b)
    return a and b and ((a.a == b.a and a.b == b.b) or (a.a == b.b and a.b == b.a))
end

local function AddBeam(renderer, parent, name, a, b, thickness)
    local delta = b - a
    local length = math.sqrt(delta.x * delta.x + delta.z * delta.z)
    if length < 0.01 then return nil end
    local node = parent:CreateChild(name)
    node.position = (a + b) * 0.5
    node.rotation = Quaternion(math.deg(math.atan(delta.x, delta.z)), Vector3.UP)
    node.scale = Vector3(thickness or 0.13, thickness or 0.13, length)
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    model:SetMaterial(renderer.selectionMaterial)
    model.castShadows = false
    return node
end

local function AddMarker(renderer, parent, name, position, scale)
    local node = parent:CreateChild(name)
    node.position = position
    node.scale = scale or Vector3(0.24, 0.10, 0.24)
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    model:SetMaterial(renderer.selectionMaterial)
    model.castShadows = false
    return node
end

local function FindSelectedEdge(renderer, dungeon)
    local candidate = dungeon and dungeon.edges and dungeon.edges[renderer.selectionLinkIndex]
    if SameEdge(candidate, renderer.selectionLink) then return candidate end
    for _, edge in ipairs(dungeon and dungeon.edges or {}) do
        if SameEdge(edge, renderer.selectionLink) then return edge end
    end
    return renderer.selectionLink and nil or candidate
end

local function AddRoom(renderer, root, dungeon, room)
    local halfWidth, halfHeight = room.w * 0.5 + 0.12, room.h * 0.5 + 0.12
    local points = {
        { x = room.cx - halfWidth, y = room.cy - halfHeight },
        { x = room.cx + halfWidth, y = room.cy - halfHeight },
        { x = room.cx + halfWidth, y = room.cy + halfHeight },
        { x = room.cx - halfWidth, y = room.cy + halfHeight },
    }
    for index = 1, 4 do
        local nextIndex = index % 4 + 1
        local ax, ay, az = renderer:WorldPosition(dungeon, points[index].x, points[index].y, room.floor, 0.42)
        local bx, by, bz = renderer:WorldPosition(dungeon, points[nextIndex].x, points[nextIndex].y, room.floor, 0.42)
        AddBeam(renderer, root, "SelectedRoomEdge-" .. index,
            Vector3(ax, ay, az), Vector3(bx, by, bz), 0.14)
    end
    local x, y, z = renderer:WorldPosition(dungeon, room.cx, room.cy, room.floor, 0.45)
    AddMarker(renderer, root, "SelectedRoomCenter", Vector3(x, y, z), Vector3(0.34, 0.10, 0.34))
end

local function AddRoute(renderer, root, dungeon, edge)
    local roomA = dungeon.rooms[edge.a]
    if not roomA then return end
    local route = edge.route
    if not route or #route < 2 then
        local roomB = dungeon.rooms[edge.b]
        if not roomB then return end
        route = { { x = roomA.cx, y = roomA.cy }, { x = roomB.cx, y = roomB.cy } }
    end
    for index = 1, #route - 1 do
        local a, b = route[index], route[index + 1]
        local ax, ay, az = renderer:WorldPosition(dungeon, a.x, a.y, roomA.floor, 0.46)
        local bx, by, bz = renderer:WorldPosition(dungeon, b.x, b.y, roomA.floor, 0.46)
        AddBeam(renderer, root, "SelectedPath-" .. index,
            Vector3(ax, ay, az), Vector3(bx, by, bz), 0.18)
    end
end

local function AddStair(renderer, root, dungeon, connector)
    local platform = MultiFloor.StairTurnPlatformMetrics(connector)
    local firstRatio = (connector.firstFlightSteps or 0) / math.max(1, connector.stepCount or 1)
    local points
    if platform then
        points = { { point = platform.first.start, ratio = 0 },
            { point = platform.first.finish, ratio = firstRatio },
            { point = platform.second.start, ratio = firstRatio },
            { point = platform.second.finish, ratio = 1 } }
    else
        local direction = connector.directionVector or { x = 1, y = 0 }
        points = { { point = MultiFloor.StairRunCenter(connector.lower, direction,
            connector.width, connector.lateralCenterOffset), ratio = 0 },
            { point = MultiFloor.StairRunCenter(connector.upper, direction,
                connector.width, connector.lateralCenterOffset), ratio = 1 } }
    end
    for segment = 1, #points - 1 do
        local a, b = points[segment], points[segment + 1]
        local dx, dy = b.point.x - a.point.x, b.point.y - a.point.y
        local samples = math.max(2, math.ceil(math.sqrt(dx * dx + dy * dy) / 0.65))
        for sample = segment == 1 and 0 or 1, samples do
            local t = sample / samples
            local gridX = a.point.x + dx * t
            local gridY = a.point.y + dy * t
            local floorRatio = a.ratio + (b.ratio - a.ratio) * t
            local x, lowerY, z = renderer:WorldPosition(dungeon, gridX, gridY, connector.fromFloor, 0.46)
            local upperY = connector.toFloor * dungeon.floorHeight * renderer.floorSpacing
                + 0.46 * (dungeon.floorHeight / MultiFloor.SOURCE_FLOOR_HEIGHT)
            local y = lowerY + (upperY - lowerY) * floorRatio
            AddMarker(renderer, root, "SelectedStair-" .. segment .. "-" .. sample,
                Vector3(x, y, z), Vector3(0.24, 0.10, 0.24))
        end
    end
end

function EditorSelectionHighlight.Refresh(renderer)
    if renderer.selectionRoot then renderer.selectionRoot:Remove(); renderer.selectionRoot = nil end
    local dungeon = renderer.selectionDungeon
    if not renderer.root or not dungeon
        or (not renderer.selectionRoomIndex and not renderer.selectionLinkIndex) then return end
    local root = renderer.root:CreateChild("EditorSelectionHighlight")
    renderer.selectionRoot = root
    local room = dungeon.rooms and dungeon.rooms[renderer.selectionRoomIndex]
    if room then AddRoom(renderer, root, dungeon, room) end
    local edge = FindSelectedEdge(renderer, dungeon)
    if edge then
        local connector = nil
        if edge.connectorId then
            for _, item in ipairs(dungeon.connectors or {}) do
                if item.id == edge.connectorId then connector = item; break end
            end
        end
        if connector then AddStair(renderer, root, dungeon, connector)
        else AddRoute(renderer, root, dungeon, edge) end
    end
end

function EditorSelectionHighlight.Set(renderer, dungeon, roomIndex, linkIndex, link)
    renderer.selectionDungeon = dungeon
    renderer.selectionRoomIndex = roomIndex
    renderer.selectionLinkIndex = linkIndex
    renderer.selectionLink = link
    EditorSelectionHighlight.Refresh(renderer)
end

function EditorSelectionHighlight.Clear(renderer)
    if renderer.selectionRoot then renderer.selectionRoot:Remove(); renderer.selectionRoot = nil end
    renderer.selectionDungeon, renderer.selectionRoomIndex = nil, nil
    renderer.selectionLinkIndex, renderer.selectionLink = nil, nil
end

return EditorSelectionHighlight
