local EditorData = require("UI.Editor.EditorData")
local EditorSession = require("UI.Editor.EditorSession")
local RouteEditing = require("UI.Editor.RouteEditing")
local StairEditing = require("UI.Editor.StairEditing")
local StairWorkflow = require("UI.Editor.StairWorkflow")
local PathWorkflow = require("UI.Editor.PathWorkflow")
local EditorGizmos = require("UI.Editor.EditorGizmos")
local EditorInteraction = require("UI.Editor.EditorInteraction")
local EditorGesture = require("UI.Editor.EditorGesture")
local RoomEditing = require("UI.Editor.RoomEditing")
local CanvasViewport = require("UI.Editor.CanvasViewport")
local ContextMenu = require("UI.Editor.ContextMenu")
local MultiFloor = require("Generation.MultiFloor")
local RoomGroupColors = require("Config.RoomGroupColors")

local LayoutEditor = {}
LayoutEditor.__index = LayoutEditor

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function Inside(x, y, r) return r and x >= r.x and y >= r.y and x <= r.x + r.w and y <= r.y + r.h end
local function PointInsideCurrentFloorRoom(editor, x, y)
    for _, room in ipairs(editor.rooms or {}) do
        if room.floor == editor.floor
            and x >= room.cx - room.w * 0.5 and x <= room.cx + room.w * 0.5
            and y >= room.cy - room.h * 0.5 and y <= room.cy + room.h * 0.5 then
            return true
        end
    end
    return false
end
local CopyRooms = EditorData.CopyRooms
local CopyLink = EditorData.CopyLink
local CopyPoint = RouteEditing.CopyPoint
local Snap = RouteEditing.Snap
local DistanceToSegment = RouteEditing.DistanceToSegment

local function Fill(ctx, r, g, b, a) nvgFillColor(ctx, nvgRGBA(r, g, b, a or 255)) end
local function Stroke(ctx, r, g, b, a, width)
    nvgStrokeColor(ctx, nvgRGBA(r, g, b, a or 255)); nvgStrokeWidth(ctx, width or 1)
end
local function RoundedRect(ctx, x, y, w, h, radius, color)
    nvgBeginPath(ctx); nvgRoundedRect(ctx, x, y, w, h, radius)
    Fill(ctx, color[1], color[2], color[3], color[4]); nvgFill(ctx)
end

local function DrawRoomNumber(vg, rect, index)
    local label = string.format("#%d", index)
    local widthLimit = math.max(1, rect.w - 6)
    local fontSize = math.max(4, math.min(9, rect.h * 0.36, widthLimit / (#label * 0.62)))
    nvgFontSize(vg, fontSize); Fill(vg, 236, 238, 243, 230)
    local baseline = rect.y + math.min(math.max(1, rect.h - 1), math.max(fontSize + 1, rect.h * 0.42))
    nvgText(vg, rect.x + 3, baseline, label, nil)
end

function LayoutEditor.new(eventObject, callbacks)
    local self = setmetatable({
        eventObject = eventObject, callbacks = callbacks or {}, visible = false, mode = "select",
        floor = 0, floorCount = 1, floorHeight = MultiFloor.FLOOR_HEIGHT,
        dungeonWidth = 1, dungeonHeight = 1, rooms = {}, links = {},
        roomMinimumWidth = RoomEditing.DEFAULT_MINIMUM_SIZE,
        roomMinimumHeight = RoomEditing.DEFAULT_MINIMUM_SIZE,
        generatedOffset = { x = 0, y = 0 },
        editorWorldScale = 1,
        editorSwapAxes = false,
        editorCenterOffset = 0.5,
        selected = nil, selectedLink = nil, linkStart = nil, drag = nil, draw = nil,
        panel = nil, canvas = nil, roomRects = {}, buttons = {}, scale = 1, originX = 0, originY = 0,
        hoveredRoom = nil, hoveredLink = nil, hoveredGizmo = nil,
        blankPanActive = false, pan = nil, nextStairId = 1, stairSnapshot = nil,
        stairPlacing = false, stairPlacementStyle = "l-turn", gizmoDescriptors = {},
        editorViewport = CanvasViewport.new(), editorInteraction = EditorInteraction.new(),
        contextMenu = ContextMenu.new(),
        roomGroupsById = {},
    }, LayoutEditor)
    self.vg = nvgCreate(1)
    if self.vg then
        nvgSetRenderOrder(self.vg, 999980)
        self.font = nvgCreateFont(self.vg, "forge", "Fonts/MiSans-Regular.ttf")
        eventObject:SubscribeToEvent(self.vg, "NanoVGRender", function() self:Render() end)
    else
        print("[LayoutEditor] NanoVG context creation failed")
    end
    return self
end

function LayoutEditor:SyncDungeon(dungeon, floor, roomGroups)
    local selected = self.selected
    local selectedKey = EditorData.LinkKey(self.links[self.selectedLink])
    self.roomGroupsById = {}
    for _, group in ipairs(roomGroups or {}) do
        if group and group.id then self.roomGroupsById[group.id] = group end
    end
    self.rooms = CopyRooms(dungeon and dungeon.rooms or {})
    self.links = {}
    for _, edge in ipairs(dungeon and dungeon.edges or {}) do
        local link = CopyLink(edge)
        if edge.connectorId then
            for _, connector in ipairs(dungeon and dungeon.connectors or {}) do
                if connector.id == edge.connectorId then link.connector = connector; break end
            end
        end
        EditorData.EnsureStairSpec(link, edge)
        self.links[#self.links + 1] = link
    end
    self.floor = floor or self.floor
    self.floorCount = dungeon and dungeon.floorCount or self.floorCount
    self.dungeonWidth = dungeon and dungeon.width or self.dungeonWidth
    self.dungeonHeight = dungeon and dungeon.height or self.dungeonHeight
    self.roomMinimumWidth, self.roomMinimumHeight = RoomEditing.ResolveMinimumSize(dungeon)
    self.generatedOffset = { x = 0, y = 0 }
    self.editorWorldScale = math.max(0.001, tonumber(dungeon and dungeon.editorWorldScale) or 1)
    self.editorSwapAxes = dungeon and dungeon.editorSwapAxes == true or false
    self.editorCenterOffset = tonumber(dungeon and dungeon.editorCenterOffset)
    if self.editorCenterOffset == nil then self.editorCenterOffset = 0.5 end
    self.floorHeight = MultiFloor.FLOOR_HEIGHT
    self.selected = self.rooms[selected] and selected or nil
    self.selectedLink = nil
    for index, link in ipairs(self.links) do
        if EditorData.LinkKey(link) == selectedKey then self.selectedLink = index; break end
    end
    self.linkStart, self.drag, self.draw = nil, nil, nil
    self.editorViewport.fitted = false
    self:NotifySelection()
end

function LayoutEditor:NotifySelection()
    if self.callbacks.onSelection then
        self.callbacks.onSelection(self.selected, self.rooms[self.selected], "2d",
            self.selectedLink, self.links[self.selectedLink])
    end
end

function LayoutEditor:SetFloor(floor)
    self.floor = floor; self.selected, self.selectedLink, self.linkStart = nil, nil, nil
    self.editorViewport.fitted = false
    self:NotifySelection()
end
function LayoutEditor:IsVisible() return self.visible end
function LayoutEditor:GetViewMode() return "2d" end
function LayoutEditor:IsPointerInsidePanel()
    if not self.visible or not self.panel then return false end
    local dpr = math.max(1, graphics:GetDPR())
    local position = input.mousePosition
    return Inside(position.x / dpr, position.y / dpr, self.panel)
end
function LayoutEditor:SetVisible(visible)
    self.visible = visible
    self.drag, self.draw, self.pan = nil, nil, nil
    self.blankPanActive = false
    self.editorInteraction:Reset(input:GetMouseButtonDown(MOUSEB_LEFT))
    self.contextMenu:Close()
    if not visible then self.linkStart = nil end
    if visible then self:NotifySelection() end
end
function LayoutEditor:GetRooms() return CopyRooms(self.rooms) end

function LayoutEditor:GetLinks()
    local result = {}
    for i, link in ipairs(self.links) do result[i] = CopyLink(link) end
    return result
end

function LayoutEditor:SyncEditorState(source)
    return EditorSession.Apply(self, EditorSession.Capture(source))
end

function LayoutEditor:SyncGeneratedStairs(dungeon)
    if not dungeon then return false end
    self.dungeonWidth = dungeon.width or self.dungeonWidth
    self.dungeonHeight = dungeon.height or self.dungeonHeight
    self.generatedOffset = {
        x = dungeon.editorOffset and dungeon.editorOffset.x or 0,
        y = dungeon.editorOffset and dungeon.editorOffset.y or 0,
    }
    local connectors = {}
    for _, connector in ipairs(dungeon.connectors or {}) do connectors[connector.id] = connector end
    local generated = {}
    for _, edge in ipairs(dungeon.edges or {}) do generated[EditorData.LinkKey(edge)] = edge end
    local changed = false
    for _, link in ipairs(self.links) do
        if link.kind == "stairs" then
            local edge = generated[EditorData.LinkKey(link)]
            local connector = edge and connectors[edge.connectorId]
            if connector then
                link.connector = EditorData.CopyConnector(connector, dungeon.editorOffset)
                local spec = link.stairSpec
                if spec then
                    spec.candidateIndex = connector.candidateIndex or spec.candidateIndex or 0
                    spec.candidateCount = connector.candidateCount or spec.candidateCount or 1
                    spec.invalid, spec.error = false, nil
                    if spec.pending then
                        spec.previewAnchor = CopyPoint(link.connector.lower)
                        spec.previewDirection = connector.direction
                        spec.previewLength = connector.length
                        spec.previewStyle = connector.style
                        spec.previewWidth = connector.width
                    end
                end
                changed = true
            end
        end
    end
    if changed then self.gizmoDescriptors = EditorGizmos.Build(self, self.editorViewport) end
    return changed
end

function LayoutEditor:Commit()
    EditorData.ResolvePendingConnections(self.rooms, self.links)
    for i, room in ipairs(self.rooms) do room.id = i end
    if self.callbacks.onCommit then self.callbacks.onCommit(self:GetRooms(), self:GetLinks()) end
end

function LayoutEditor:Preview()
    if self.callbacks.onPreview then self.callbacks.onPreview(self:GetRooms(), self:GetLinks()) end
end

function LayoutEditor:PreviewDraw()
    if not self.callbacks.onPreview then return end
    local rooms = self:GetRooms()
    if self.draw then
        local minX, maxX = math.min(self.draw.gx, self.draw.ex), math.max(self.draw.gx, self.draw.ex)
        local minY, maxY = math.min(self.draw.gy, self.draw.ey), math.max(self.draw.gy, self.draw.ey)
        if maxX - minX >= 3 and maxY - minY >= 3 then
            rooms[#rooms + 1] = {
                id = #rooms + 1,
                cx = math.floor((minX + maxX) * 0.5 + 0.5),
                cy = math.floor((minY + maxY) * 0.5 + 0.5),
                w = Clamp(math.floor(maxX - minX + 0.5), 5, 24),
                h = Clamp(math.floor(maxY - minY + 0.5), 5, 24),
                floor = self.floor,
            }
        end
    end
    self.callbacks.onPreview(rooms, self:GetLinks())
end

function LayoutEditor:SetSelectedRoomGroup(groupId)
    local room = self.rooms[self.selected]
    if not room then return false, "请先在二维编辑器中选择一个房间。" end
    room.roomGroupId = groupId
    self:Commit()
    self:NotifySelection()
    return true
end

function LayoutEditor:ClearRoomGroup(groupId)
    for _, room in ipairs(self.rooms) do if room.roomGroupId == groupId then room.roomGroupId = nil end end
    self:NotifySelection()
end

function LayoutEditor:DoorSpecPoint(room, spec)
    if not room or not spec then return nil end
    local side = spec.side
    local offset = Clamp(tonumber(spec.offset) or 0, -0.82, 0.82)
    if side == "north" or side == "n" then
        return { x = room.cx + room.w * 0.5 * offset, y = room.cy - room.h * 0.5, side = "north" }
    elseif side == "south" or side == "s" then
        return { x = room.cx + room.w * 0.5 * offset, y = room.cy + room.h * 0.5, side = "south" }
    elseif side == "west" or side == "w" then
        return { x = room.cx - room.w * 0.5, y = room.cy + room.h * 0.5 * offset, side = "west" }
    elseif side == "east" or side == "e" then
        return { x = room.cx + room.w * 0.5, y = room.cy + room.h * 0.5 * offset, side = "east" }
    end
    return nil
end

function LayoutEditor:PointToDoorSpec(room, point)
    local distances = {
        { side = "north", value = math.abs(point.y - (room.cy - room.h * 0.5)) },
        { side = "south", value = math.abs(point.y - (room.cy + room.h * 0.5)) },
        { side = "west", value = math.abs(point.x - (room.cx - room.w * 0.5)) },
        { side = "east", value = math.abs(point.x - (room.cx + room.w * 0.5)) },
    }
    table.sort(distances, function(a, b) return a.value < b.value end)
    local side = distances[1].side
    local offset = (side == "north" or side == "south")
        and (point.x - room.cx) / math.max(1, room.w * 0.5)
        or (point.y - room.cy) / math.max(1, room.h * 0.5)
    return { side = side, offset = Clamp(offset, -0.82, 0.82) }
end

function LayoutEditor:AutomaticDoorPoint(room, other)
    local dx, dy = other.cx - room.cx, other.cy - room.cy
    local halfWidth, halfHeight = math.max(1, room.w * 0.5), math.max(1, room.h * 0.5)
    if math.abs(dx) / halfWidth >= math.abs(dy) / halfHeight then
        return { x = room.cx + (dx >= 0 and halfWidth or -halfWidth),
            y = room.cy + Clamp(dy, -halfHeight * 0.82, halfHeight * 0.82),
            side = dx >= 0 and "east" or "west" }
    end
    return { x = room.cx + Clamp(dx, -halfWidth * 0.82, halfWidth * 0.82),
        y = room.cy + (dy >= 0 and halfHeight or -halfHeight),
        side = dy >= 0 and "south" or "north" }
end

function LayoutEditor:LinkEndpoints(link)
    local roomA, roomB = self.rooms[link.a], self.rooms[link.b]
    if not roomA or not roomB or roomA.floor ~= roomB.floor then return nil, nil end
    return self:DoorSpecPoint(roomA, link.doorA) or self:AutomaticDoorPoint(roomA, roomB),
        self:DoorSpecPoint(roomB, link.doorB) or self:AutomaticDoorPoint(roomB, roomA)
end

function LayoutEditor:LinkRoute(link)
    local startPoint, endPoint = self:LinkEndpoints(link)
    if not startPoint or not endPoint then return {} end
    local points = { startPoint }
    if link.bends and #link.bends > 0 then
        for _, point in ipairs(link.bends) do points[#points + 1] = CopyPoint(point) end
    elseif not link.doorA and not link.doorB and link.autoRoute and #link.autoRoute > 1 then
        points = {}
        for _, point in ipairs(link.autoRoute) do points[#points + 1] = CopyPoint(point) end
        points = RouteEditing.Simplify(points)
        points[1].side, points[#points].side = startPoint.side, endPoint.side
        return points
    elseif math.abs(startPoint.x - endPoint.x) > 0.01 and math.abs(startPoint.y - endPoint.y) > 0.01 then
        if math.abs(startPoint.x - endPoint.x) >= math.abs(startPoint.y - endPoint.y) then
            points[#points + 1] = { x = endPoint.x, y = startPoint.y }
        else
            points[#points + 1] = { x = startPoint.x, y = endPoint.y }
        end
    end
    points[#points + 1] = endPoint
    return points
end

function LayoutEditor:DisplayLinkRoute(link)
    local route = self:LinkRoute(link)
    local automatic = link and (not link.bends or #link.bends == 0) and not link.doorA and not link.doorB
        and link.autoRoute and #link.autoRoute > 1
    local offset = automatic and RouteEditing.CorridorCenterOffset(link.width) or 0
    if offset == 0 or #route < 2 then return route end
    local displayed = {}
    for index, point in ipairs(route) do
        displayed[index] = { x = point.x + offset, y = point.y + offset, side = point.side }
    end
    local function FixEndpoint(index, neighborIndex)
        local endpoint, neighbor = route[index], route[neighborIndex]
        if endpoint.y == neighbor.y and endpoint.x ~= neighbor.x then displayed[index].x = endpoint.x
        elseif endpoint.x == neighbor.x and endpoint.y ~= neighbor.y then displayed[index].y = endpoint.y end
    end
    FixEndpoint(1, 2); FixEndpoint(#route, #route - 1)
    return displayed
end

function LayoutEditor:RefreshOverlay()
    if not self.canvas then return end
    self.gizmoDescriptors = EditorGizmos.Build(self, self.editorViewport)
end

function LayoutEditor:UpdateRoomVisual(_) end
function LayoutEditor:UpdateDrawPreview() end

function LayoutEditor:ScreenToFloor(mousePosition)
    local dpr = math.max(1, graphics:GetDPR())
    local gridX, gridY = self.editorViewport:ScreenToGrid(mousePosition.x / dpr, mousePosition.y / dpr)
    return { x = gridX, y = 0, z = gridY }
end

function LayoutEditor:WorldToGrid(point)
    return point.x, point.z
end

function LayoutEditor:HitRoom(point)
    local gridX, gridY = self:WorldToGrid(point)
    for index = #self.rooms, 1, -1 do
        local room = self.rooms[index]
        if room.floor == self.floor and gridX >= room.cx - room.w * 0.5 and gridX <= room.cx + room.w * 0.5
            and gridY >= room.cy - room.h * 0.5 and gridY <= room.cy + room.h * 0.5 then
            return index, gridX, gridY
        end
    end
    return nil, gridX, gridY
end

function LayoutEditor:HitTolerance()
    return math.max(0.35, 10 / math.max(0.01, self.editorViewport.scale))
end

function LayoutEditor:HitLink(gridX, gridY)
    -- Runtime A* routes include room endpoint cells. Room cells must win the
    -- first click so an underlying corridor cannot steal room selection.
    if PointInsideCurrentFloorRoom(self, gridX, gridY) then return nil end
    local best, tolerance = nil, self:HitTolerance()
    for linkIndex, link in ipairs(self.links) do
        local roomA, roomB = self.rooms[link.a], self.rooms[link.b]
        local route = nil
        if link.runtimeGenerated then
            local runtimeHit = EditorGizmos.HitRuntimeLink(link, self.floor, gridX, gridY, tolerance)
            if runtimeHit and (not best or runtimeHit.distance < best.distance) then
                runtimeHit.index = linkIndex
                best = runtimeHit
            end
        elseif roomA and roomB and roomA.floor ~= roomB.floor and link.connector
            and (roomA.floor == self.floor or roomB.floor == self.floor) then
            local segments = StairEditing.VisualSegments(link.connector)
            route = {}
            for _, stairSegment in ipairs(segments) do
                route[#route + 1] = stairSegment.start
                route[#route + 1] = stairSegment.finish
            end
        elseif roomA and roomB and roomA.floor == self.floor and roomB.floor == self.floor then
            route = self:DisplayLinkRoute(link)
        end
        if route and not link.runtimeGenerated then
            local linkTolerance = math.max(tolerance, ((link.connector and link.connector.width) or link.width or 2) * 0.5)
            for segment = 1, #route - 1 do
                local distance = DistanceToSegment(gridX, gridY, route[segment], route[segment + 1])
                if distance <= linkTolerance and (not best or distance < best.distance) then
                    best = { index = linkIndex, segment = segment, distance = distance,
                        stair = roomA.floor ~= roomB.floor }
                end
            end
        end
    end
    return best
end

function LayoutEditor:ResizeRoom(room, start, gridX, gridY, mode)
    local resized = RoomEditing.Resize(start, { x = gridX, y = gridY }, mode,
        self.roomMinimumWidth, self.roomMinimumHeight)
    room.cx, room.cy, room.w, room.h = resized.cx, resized.cy, resized.w, resized.h
end

function LayoutEditor:AddBend()
    local link = self.links[self.selectedLink]
    if not link or link.runtimeGenerated or link.kind == "stairs" then return end
    local route, bestSegment, bestLength = self:LinkRoute(link), nil, -1
    for segment = 1, #route - 1 do
        local dx, dy = route[segment + 1].x - route[segment].x, route[segment + 1].y - route[segment].y
        local length = dx * dx + dy * dy
        if length > bestLength then bestSegment, bestLength = segment, length end
    end
    if not bestSegment then return end
    route = self:EnsureEditableRoute(link)
    local a, b = route[bestSegment], route[bestSegment + 1]
    table.insert(link.bends, bestSegment, { x = Snap((a.x + b.x) * 0.5), y = Snap((a.y + b.y) * 0.5) })
    link.isManual, link.autoRoute = true, {}
    self:Commit()
end

function LayoutEditor:MarkDisconnectedRoomsSecret()
    local adjacency, seen = {}, {}
    for index = 1, #self.rooms do adjacency[index] = {} end
    for _, link in ipairs(self.links) do
        if adjacency[link.a] and adjacency[link.b] then
            adjacency[link.a][#adjacency[link.a] + 1] = link.b
            adjacency[link.b][#adjacency[link.b] + 1] = link.a
        end
    end
    local entrance = 1
    for index, room in ipairs(self.rooms) do if room.roleHint == "entrance" then entrance = index; break end end
    local queue, head = { entrance }, 1; seen[entrance] = true
    while head <= #queue do
        local current = queue[head]; head = head + 1
        for _, neighbor in ipairs(adjacency[current] or {}) do
            if not seen[neighbor] then seen[neighbor] = true; queue[#queue + 1] = neighbor end
        end
    end
    for index, room in ipairs(self.rooms) do if not seen[index] then room.roleHint = "secret" end end
end

function LayoutEditor:NormalizeConnectedSecretRooms()
    local adjacency, seen = {}, {}
    for index = 1, #self.rooms do adjacency[index] = {} end
    for _, link in ipairs(self.links) do
        if adjacency[link.a] and adjacency[link.b] then
            adjacency[link.a][#adjacency[link.a] + 1] = link.b
            adjacency[link.b][#adjacency[link.b] + 1] = link.a
        end
    end
    for start = 1, #self.rooms do
        if not seen[start] then
            local queue, component, head, hasNormal = { start }, {}, 1, false; seen[start] = true
            while head <= #queue do
                local current = queue[head]; head = head + 1; component[#component + 1] = current
                if self.rooms[current].roleHint ~= "secret" then hasNormal = true end
                for _, neighbor in ipairs(adjacency[current]) do
                    if not seen[neighbor] then seen[neighbor] = true; queue[#queue + 1] = neighbor end
                end
            end
            if hasNormal then
                for _, index in ipairs(component) do if self.rooms[index].roleHint == "secret" then self.rooms[index].roleHint = nil end end
            end
        end
    end
end

function LayoutEditor:DeleteSelected()
    if self.selectedLink then
        local link = self.links[self.selectedLink]
        if link and link.kind == "stairs" and not link.runtimeGenerated then return self:DeleteSelectedStair() end
        table.remove(self.links, self.selectedLink)
        self.selectedLink = nil
        self:MarkDisconnectedRoomsSecret()
        self:Commit()
        return
    end
    if not self.selected then return end
    local room = self.rooms[self.selected]
    if not room or room.locked then return end
    local removed = self.selected
    for i = #self.links, 1, -1 do
        local link = self.links[i]
        if link.a == removed or link.b == removed then
            table.remove(self.links, i)
        else
            if link.a > removed then link.a = link.a - 1 end
            if link.b > removed then link.b = link.b - 1 end
        end
    end
    table.remove(self.rooms, self.selected)
    self.selected = nil
    self:NotifySelection()
    self:Commit()
end

function LayoutEditor:SetMode(mode)
    self.mode, self.linkStart, self.stairPlacing = mode, nil, false
    if self.callbacks.onStatus then
        local names = { select = "选择/移动", draw = "绘制房间", connect = "连接房间" }
        self.callbacks.onStatus("2D 编辑模式：" .. (names[mode] or mode))
    end
end

function LayoutEditor:AdjustPathWidth(delta)
    local link = self.links[self.selectedLink]
    if not link or link.runtimeGenerated or link.kind == "stairs" then return end
    local width = Clamp((link.width or 2) + delta, 1, 6)
    if width ~= link.width then link.width, link.isManual = width, true; self:Commit() end
end

function LayoutEditor:SetSelectedRole(role)
    local room = self.rooms[self.selected]
    if not room then return end
    if role == "secret" then
        room.roleHint = room.roleHint == role and nil or role
    else
        local nextRole = room.roleHint == role and nil or role
        if nextRole then
            for _, other in ipairs(self.rooms) do if other.roleHint == role then other.roleHint = nil end end
        end
        room.roleHint = nextRole
    end
    self:Commit(); self:NotifySelection()
end

function LayoutEditor:MoveSelectedRoomFloor(delta)
    local room = self.rooms[self.selected]
    if not room then return false end
    local target = Clamp((room.floor or 0) + delta, 0, self.floorCount - 1)
    if target == room.floor then return false end
    for _, link in ipairs(self.links) do
        if link.a == self.selected or link.b == self.selected then
            local other = self.rooms[link.a == self.selected and link.b or link.a]
            if other and math.abs((other.floor or 0) - target) > 1 then return false end
        end
    end
    room.floor = target
    for _, link in ipairs(self.links) do
        if link.a == self.selected or link.b == self.selected then
            local other = self.rooms[link.a == self.selected and link.b or link.a]
            link.kind = other and other.floor ~= target and "stairs" or "corridor"
            link.bends, link.autoRoute = {}, {}
            if link.kind == "stairs" then
                link.stairSpec = link.stairSpec or { id = "stair-" .. self.nextStairId,
                    mode = "stable-auto", width = 2, landingDepth = 2 }
                self.nextStairId = self.nextStairId + 1
            else link.stairSpec, link.connector = nil, nil end
        end
    end
    self.floor = target; self.editorViewport.fitted = false
    self:Commit(); self:NotifySelection()
    return true
end

function LayoutEditor:AddRoomAt(gridX, gridY)
    self.rooms[#self.rooms + 1] = { cx = Snap(gridX), cy = Snap(gridY), w = 12, h = 9,
        floor = self.floor, locked = false }
    self.selected, self.selectedLink = #self.rooms, nil
    self:NotifySelection(); self:Commit()
end

function LayoutEditor:ContextItems(kind, context)
    if kind == "blank" then return { { action = "addRoom", label = "添加房间" } } end
    if kind == "room" then
        local room = self.rooms[context.room]
        return {
            { action = "lockRoom", label = room and room.locked and "解锁房间" or "锁定房间" },
            { action = "floorUp", label = "移动到上一层" },
            { action = "floorDown", label = "移动到下一层" },
            { action = "entrance", label = "设置/取消入口" },
            { action = "boss", label = "设置/取消终点" },
            { action = "secret", label = "设置/取消密室" },
            { action = "roomGroup", label = "分配房间组" },
            { action = "addStair", label = "从此房间添加楼梯" },
            { action = "deleteRoom", label = "删除房间", danger = true },
        }
    end
    if kind == "stair" then
        local selectedLink = self.links[context.link]
        if selectedLink and selectedLink.runtimeGenerated then
            return { { action = "deleteLink", label = "删除路径", danger = true } }
        end
        local spec = selectedLink and selectedLink.stairSpec
        return {
            { action = "rotateStair", label = "旋转楼梯 90°" },
            { action = "stairStyleL", label = "切换为 L 型楼梯" },
            { action = "stairStyleStraight", label = "切换为直梯" },
            { action = "toggleStairLock", label = spec and spec.mode == "locked" and "切换为稳定自动" or "锁定楼梯位置" },
            { action = "deleteStair", label = "删除楼梯", danger = true },
        }
    end
    if kind == "path" then
        local selectedLink = self.links[context.link]
        if selectedLink and selectedLink.runtimeGenerated then
            return { { action = "deleteLink", label = "删除路径", danger = true } }
        end
        return {
            { action = "addBendHere", label = "在此添加折点" },
            { action = "straightenLink", label = "正交拉直路径" },
            { action = "resetLink", label = "重置路径形状" },
            { action = "narrow", label = "路径变窄" },
            { action = "widen", label = "路径变宽" },
            { action = "deleteLink", label = "删除路径", danger = true },
        }
    end
    return {}
end

function LayoutEditor:OpenContextMenu(logicalX, logicalY)
    if not self.canvas or not Inside(logicalX, logicalY, self.canvas) then return end
    local gridX, gridY = self.editorViewport:ScreenToGrid(logicalX, logicalY)
    local handle = EditorGizmos.Hit(self.gizmoDescriptors, logicalX, logicalY)
    local hit = self:HitRoom({ x = gridX, y = 0, z = gridY })
    local path = not hit and self:HitLink(gridX, gridY) or nil
    local kind, context
    if handle and handle.kind ~= "roomResize" and self.selectedLink then
        local link = self.links[self.selectedLink]
        kind = link and link.kind == "stairs" and "stair" or "path"
        context = { link = self.selectedLink, segment = path and path.segment,
            x = gridX, y = gridY, which = handle.which, bendIndex = handle.bendIndex }
    elseif path then
        self.selected, self.selectedLink = nil, path.index
        kind, context = path.stair and "stair" or "path",
            { link = path.index, segment = path.segment, x = gridX, y = gridY }
    elseif hit then
        self.selected, self.selectedLink = hit, nil
        kind, context = "room", { room = hit, x = gridX, y = gridY }
    else
        self.selected, self.selectedLink = nil, nil
        kind, context = "blank", { x = gridX, y = gridY }
    end
    self:NotifySelection()
    local dpr = math.max(1, graphics:GetDPR())
    self.contextMenu:Open(logicalX, logicalY, self:ContextItems(kind, context), context,
        graphics:GetWidth() / dpr, graphics:GetHeight() / dpr)
end

function LayoutEditor:HandleContextAction(item, context)
    if not item or not context then return end
    local action = item.action
    if action == "addRoom" then self:AddRoomAt(context.x, context.y)
    elseif action == "deleteRoom" then self.selected = context.room; self:DeleteSelected()
    elseif action == "lockRoom" then
        local room = self.rooms[context.room]; if room then room.locked = not room.locked; self:Commit() end
    elseif action == "floorUp" then self.selected = context.room; self:MoveSelectedRoomFloor(1)
    elseif action == "floorDown" then self.selected = context.room; self:MoveSelectedRoomFloor(-1)
    elseif action == "entrance" or action == "boss" or action == "secret" then
        self.selected = context.room; self:SetSelectedRole(action)
    elseif action == "roomGroup" then
        self.selected = context.room; self:NotifySelection()
        if self.callbacks.onRoomGroupMenu then self.callbacks.onRoomGroupMenu() end
    elseif action == "addStair" then self.selected = context.room; self:BeginAddStair()
    elseif action == "narrow" then self.selectedLink = context.link; self:AdjustPathWidth(-1)
    elseif action == "widen" then self.selectedLink = context.link; self:AdjustPathWidth(1)
    elseif action == "deleteLink" then self.selectedLink = context.link; self:DeleteSelected()
    elseif action == "straightenLink" then
        local link = self.links[context.link]; if link then self.selectedLink = context.link; self:StraightenLink(link) end
    elseif action == "resetLink" then
        local link = self.links[context.link]
        if link then link.bends, link.doorA, link.doorB, link.autoRoute = {}, nil, nil, {}; link.isManual = true; self:Commit() end
    elseif action == "addBendHere" then
        local link = self.links[context.link]
        if link then
            self:EnsureEditableRoute(link)
            local insertAt = Clamp(context.segment or (#link.bends + 1), 1, #link.bends + 1)
            table.insert(link.bends, insertAt, { x = Snap(context.x), y = Snap(context.y) })
            link.autoRoute, link.isManual = {}, true; self:NormalizeLink(link); self:Commit()
        end
    elseif action == "rotateStair" then self.selectedLink = context.link; self:RotateSelectedStair()
    elseif action == "stairStyleL" then self.selectedLink = context.link; self:SetSelectedStairStyle("l-turn")
    elseif action == "stairStyleStraight" then self.selectedLink = context.link; self:SetSelectedStairStyle("straight")
    elseif action == "toggleStairLock" then self.selectedLink = context.link; self:ToggleSelectedStairLock()
    elseif action == "deleteStair" then self.selectedLink = context.link; self:DeleteSelectedStair() end
end

function LayoutEditor:HandleToolbar(mx, my)
    for action, rect in pairs(self.buttons) do
        if Inside(mx, my, rect) then
            if action == "view3d" then
                if self.callbacks.onViewMode then self.callbacks.onViewMode("3d") end
            elseif action == "narrow" then self:AdjustPathWidth(-1)
            elseif action == "widen" then self:AdjustPathWidth(1)
            elseif action == "addBend" then self:AddBend()
            elseif action == "deletePath" then self:DeleteSelected()
            elseif action == "addStair" then self:BeginAddStair()
            elseif action == "rotateStair" then self:RotateSelectedStair()
            elseif action == "stairStyleL" then self:SetSelectedStairStyle("l-turn")
            elseif action == "stairStyleStraight" then self:SetSelectedStairStyle("straight")
            elseif action == "lockStair" then self:ToggleSelectedStairLock()
            elseif action == "confirmStair" then self:ConfirmSelectedStair()
            elseif action == "cancelStair" then self:CancelSelectedStair()
            elseif action == "deleteStair" then self:DeleteSelectedStair()
            elseif action == "fit" then self.editorViewport:Fit(self.rooms, self.floor)
            else self:SetMode(action) end
            return true
        end
    end
    return false
end

function LayoutEditor:LegacyUpdate(_)
    if not self.visible then return end
    local dpr = math.max(1, graphics:GetDPR())
    local pos = input.mousePosition
    local mx, my = pos.x / dpr, pos.y / dpr

    if input:GetKeyPress(KEY_ESCAPE) then
        if self.callbacks.onClose then self.callbacks.onClose() end
        return
    end
    if input:GetKeyPress(KEY_TAB) then
        if self.callbacks.onViewMode then self.callbacks.onViewMode("3d") end
        return
    end
    if input:GetKeyPress(KEY_DELETE) or input:GetKeyPress(KEY_BACKSPACE) then self:DeleteSelected() end
    if input:GetKeyPress(KEY_L) and self.selected and self.rooms[self.selected] then
        self.rooms[self.selected].locked = not self.rooms[self.selected].locked
        self:Commit()
    end

    if input:GetMouseButtonPress(MOUSEB_LEFT) then
        for mode, rect in pairs(self.buttons) do
            if Inside(mx, my, rect) then
                if mode == "view3d" then
                    if self.callbacks.onViewMode then self.callbacks.onViewMode("3d") end
                else
                    self.mode, self.linkStart = mode, nil
                end
                return
            end
        end
        if not Inside(mx, my, self.panel) then return end
        local hit = nil
        for i = #self.roomRects, 1, -1 do
            if Inside(mx, my, self.roomRects[i]) then hit = self.roomRects[i].index; break end
        end
        if self.mode == "select" and hit then
            self.selected = hit
            self:NotifySelection()
            local room = self.rooms[hit]
            if not room.locked then self.drag = { index = hit, x = mx, y = my, cx = room.cx, cy = room.cy } end
        elseif self.mode == "draw" and not hit then
            self.draw = { x = mx, y = my, ex = mx, ey = my }
        elseif self.mode == "connect" and hit then
            if self.linkStart and self.linkStart ~= hit then
                local exists = false
                for _, link in ipairs(self.links) do
                    if (link.a == self.linkStart and link.b == hit) or (link.a == hit and link.b == self.linkStart) then exists = true end
                end
                if not exists then self.links[#self.links + 1] = { a = self.linkStart, b = hit, isLoop = true, isManual = true } end
                self.selected, self.linkStart = hit, nil
                self:NotifySelection()
                if self.callbacks.onStatus then self.callbacks.onStatus("已建立房间连接；生成器会重算最短走廊") end
                self:Commit()
            else
                self.linkStart, self.selected = hit, hit
                self:NotifySelection()
            end
        else
            self.selected = hit
            self:NotifySelection()
        end
    end

    if input:GetMouseButtonDown(MOUSEB_LEFT) then
        if self.drag then
            local room = self.rooms[self.drag.index]
            room.cx = math.floor(self.drag.cx + (mx - self.drag.x) / self.scale + 0.5)
            room.cy = math.floor(self.drag.cy + (my - self.drag.y) / self.scale + 0.5)
        elseif self.draw then
            self.draw.ex, self.draw.ey = mx, my
        end
    end

    if input:GetMouseButtonRelease(MOUSEB_LEFT) then
        if self.drag then
            self.drag = nil
            self:Commit()
        elseif self.draw then
            local x1, x2 = math.min(self.draw.x, self.draw.ex), math.max(self.draw.x, self.draw.ex)
            local y1, y2 = math.min(self.draw.y, self.draw.ey), math.max(self.draw.y, self.draw.ey)
            if x2 - x1 >= 18 and y2 - y1 >= 18 then
                local room = {
                    cx = math.floor(((x1 + x2) * 0.5 - self.originX) / self.scale + 0.5),
                    cy = math.floor(((y1 + y2) * 0.5 - self.originY) / self.scale + 0.5),
                    w = Clamp(math.floor((x2 - x1) / self.scale + 0.5), 5, 24),
                    h = Clamp(math.floor((y2 - y1) / self.scale + 0.5), 5, 24), floor = self.floor,
                }
                self.rooms[#self.rooms + 1] = room
                self.selected = #self.rooms
                self:NotifySelection()
                self:Commit()
            end
            self.draw = nil
        end
    end
end

function LayoutEditor:LegacyRender()
    if not self.visible or not self.vg then return end
    local dpr = math.max(1, graphics:GetDPR())
    local width, height = graphics:GetWidth() / dpr, graphics:GetHeight() / dpr
    local pw, ph = math.min(680, width - 330), math.min(660, height - 36)
    local px, py = width - pw - 18, 18
    self.panel = { x = px, y = py, w = pw, h = ph }
    nvgBeginFrame(self.vg, width, height, dpr)

    RoundedRect(self.vg, px, py, pw, ph, 10, { 8, 11, 18, 247 })
    nvgBeginPath(self.vg); nvgRoundedRect(self.vg, px, py, pw, ph, 10)
    Stroke(self.vg, 70, 79, 104, 230, 1); nvgStroke(self.vg)
    nvgFontFace(self.vg, "forge"); nvgTextAlign(self.vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFontSize(self.vg, 17); Fill(self.vg, 230, 233, 240, 255)
    nvgText(self.vg, px + 18, py + 25, "布局编辑器", nil)
    nvgFontSize(self.vg, 10); Fill(self.vg, 130, 140, 158, 255)
    nvgText(self.vg, px + 18, py + 48, string.format(
        "第 %d 层 · L 锁定/解锁 · Delete/Backspace 删除 · Tab 返回三维 · Esc 完成", self.floor + 1), nil)

    self.buttons = {}
    local viewRect = { x = px + pw - 66, y = py + 12, w = 48, h = 28 }
    self.buttons.view3d = viewRect
    RoundedRect(self.vg, viewRect.x, viewRect.y, viewRect.w, viewRect.h, 5, { 170, 94, 37, 255 })
    nvgFontSize(self.vg, 11); Fill(self.vg, 255, 236, 210, 255)
    nvgText(self.vg, viewRect.x + 12, viewRect.y + 14, "三维", nil)
    local bx, by, bw = px + 18, py + 65, 92
    local labels = { select = "选择 / 移动", draw = "绘制房间", connect = "连接房间" }
    for _, mode in ipairs({ "select", "draw", "connect" }) do
        local rect = { x = bx, y = by, w = bw, h = 31 }; self.buttons[mode] = rect
        local active = self.mode == mode
        RoundedRect(self.vg, rect.x, rect.y, rect.w, rect.h, 5, active and { 170, 94, 37, 255 } or { 25, 31, 45, 255 })
        nvgFontSize(self.vg, 11); Fill(self.vg, active and 255 or 180, active and 236 or 187, active and 210 or 202, 255)
        nvgText(self.vg, rect.x + 10, rect.y + 16, labels[mode], nil)
        bx = bx + bw + 7
    end

    local cx, cy, cw, ch = px + 18, py + 110, pw - 36, ph - 143
    RoundedRect(self.vg, cx, cy, cw, ch, 5, { 12, 16, 25, 255 })
    nvgScissor(self.vg, cx, cy, cw, ch)
    local floorRooms, minX, minY, maxX, maxY = {}, math.huge, math.huge, -math.huge, -math.huge
    for i, room in ipairs(self.rooms) do
        if room.floor == self.floor then
            floorRooms[#floorRooms + 1] = { index = i, room = room }
            minX, minY = math.min(minX, room.cx - room.w * 0.5), math.min(minY, room.cy - room.h * 0.5)
            maxX, maxY = math.max(maxX, room.cx + room.w * 0.5), math.max(maxY, room.cy + room.h * 0.5)
        end
    end
    if #floorRooms == 0 then minX, minY, maxX, maxY = 0, 0, 40, 30 end
    self.scale = math.min((cw - 50) / math.max(1, maxX - minX), (ch - 50) / math.max(1, maxY - minY))
    self.scale = Clamp(self.scale, 1.2, 9)
    self.originX = cx + cw * 0.5 - (minX + maxX) * 0.5 * self.scale
    self.originY = cy + ch * 0.5 - (minY + maxY) * 0.5 * self.scale
    self.roomRects = {}

    for _, link in ipairs(self.links) do
        local a, b = self.rooms[link.a], self.rooms[link.b]
        if a and b and a.floor == self.floor and b.floor == self.floor then
            nvgBeginPath(self.vg)
            nvgMoveTo(self.vg, self.originX + a.cx * self.scale, self.originY + a.cy * self.scale)
            nvgLineTo(self.vg, self.originX + b.cx * self.scale, self.originY + b.cy * self.scale)
            Stroke(self.vg, link.isManual and 232 or 91, link.isManual and 151 or 117, link.isManual and 63 or 143, 210, link.isManual and 2.5 or 1.3)
            nvgStroke(self.vg)
        end
    end

    nvgBeginPath(self.vg)
    for _, edgeRoom in ipairs(floorRooms) do
        local room = edgeRoom.room
        nvgCircle(self.vg, self.originX + room.cx * self.scale, self.originY + room.cy * self.scale, 1.5)
    end
    Fill(self.vg, 88, 103, 128, 160); nvgFill(self.vg)

    for _, item in ipairs(floorRooms) do
        local room, i = item.room, item.index
        local rect = { index = i, x = self.originX + (room.cx - room.w * 0.5) * self.scale,
            y = self.originY + (room.cy - room.h * 0.5) * self.scale,
            w = room.w * self.scale, h = room.h * self.scale }
        self.roomRects[#self.roomRects + 1] = rect
        local selected = self.selected == i
        local group = self.roomGroupsById[room.roomGroupId]
        local groupColor = group and RoomGroupColors.ToRGBA(
            RoomGroupColors.Parse(group.color, RoomGroupColors.Default(group, 1)), 245)
        local color = selected and { 231, 145, 58, 235 }
            or (room.locked and { 77, 86, 105, 240 } or groupColor or { 46, 63, 78, 245 })
        RoundedRect(self.vg, rect.x, rect.y, rect.w, rect.h, 3, color)
        nvgBeginPath(self.vg); nvgRoundedRect(self.vg, rect.x, rect.y, rect.w, rect.h, 3)
        Stroke(self.vg, selected and 255 or 114, selected and 215 or 132, selected and 157 or 151, 255, selected and 2 or 1); nvgStroke(self.vg)
        DrawRoomNumber(self.vg, rect, i)
    end
    if self.draw then
        local x, y = math.min(self.draw.x, self.draw.ex), math.min(self.draw.y, self.draw.ey)
        local w, h = math.abs(self.draw.ex - self.draw.x), math.abs(self.draw.ey - self.draw.y)
        nvgBeginPath(self.vg); nvgRect(self.vg, x, y, w, h); Fill(self.vg, 230, 145, 58, 70); nvgFill(self.vg)
        Stroke(self.vg, 240, 165, 80, 255, 2); nvgStroke(self.vg)
    end
    nvgResetScissor(self.vg)
    nvgFontSize(self.vg, 10); Fill(self.vg, 126, 136, 154, 255)
    nvgText(self.vg, px + 18, py + ph - 17,
        "选择：鼠标左键拖拽房间  |  绘制：鼠标左键在空白处拖出新房间  |  连接：鼠标左键依次点击两个房间", nil)
    nvgEndFrame(self.vg)
end

function LayoutEditor:Render()
    if not self.visible or not self.vg then return end
    local dpr = math.max(1, graphics:GetDPR())
    local width, height = graphics:GetWidth() / dpr, graphics:GetHeight() / dpr
    local pw, ph = math.min(720, width - 330), math.min(700, height - 36)
    local px, py = width - pw - 18, 18
    local cx, cy, cw, ch = px + 18, py + 142, pw - 36, ph - 176
    self.panel, self.canvas = { x = px, y = py, w = pw, h = ph }, { x = cx, y = cy, w = cw, h = ch }
    self.editorViewport:SetRect(cx, cy, cw, ch)
    if not self.editorViewport.fitted then self.editorViewport:Fit(self.rooms, self.floor) end
    self.scale, self.originX, self.originY = self.editorViewport.scale,
        self.editorViewport.originX, self.editorViewport.originY
    self.gizmoDescriptors = EditorGizmos.Build(self, self.editorViewport)

    nvgBeginFrame(self.vg, width, height, dpr)
    RoundedRect(self.vg, px, py, pw, ph, 10, { 8, 11, 18, 247 })
    nvgBeginPath(self.vg); nvgRoundedRect(self.vg, px, py, pw, ph, 10)
    Stroke(self.vg, 70, 79, 104, 230, 1); nvgStroke(self.vg)
    nvgFontFace(self.vg, "forge"); nvgTextAlign(self.vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFontSize(self.vg, 17); Fill(self.vg, 230, 233, 240, 255)
    nvgText(self.vg, px + 18, py + 25, "2D 布局编辑器", nil)
    nvgFontSize(self.vg, 10); Fill(self.vg, 130, 140, 158, 255)
    nvgText(self.vg, px + 18, py + 48, string.format(
        "第 %d/%d 层 · 拖动轻量预览 · 松手同步 3D · 滚轮缩放 · 空白左键/Alt+左键/中键平移 · Tab 返回 3D",
        self.floor + 1, self.floorCount), nil)

    self.buttons = {}
    local function Button(action, label, x, y, buttonWidth, active)
        local rect = { x = x, y = y, w = buttonWidth, h = 30 }; self.buttons[action] = rect
        RoundedRect(self.vg, x, y, buttonWidth, 30, 5,
            active and { 170, 94, 37, 255 } or { 25, 31, 45, 255 })
        nvgFontSize(self.vg, 11); Fill(self.vg, active and 255 or 185,
            active and 236 or 194, active and 210 or 207, 255)
        nvgText(self.vg, x + 9, y + 15, label, nil)
        return x + buttonWidth + 7
    end
    local bx, by = px + 18, py + 65
    bx = Button("select", "选择 / 移动", bx, by, 92, self.mode == "select")
    bx = Button("draw", "绘制房间", bx, by, 78, self.mode == "draw")
    bx = Button("connect", "连接房间", bx, by, 78, self.mode == "connect")
    bx = Button("addStair", "+ 楼梯", bx, by, 66, self.stairPlacing)
    bx = Button("fit", "适配视图", bx, by, 72, false)
    Button("view3d", "3D", px + pw - 58, py + 65, 40, false)

    local selectedLink = self.links[self.selectedLink]
    bx, by = px + 18, py + 103
    if selectedLink and selectedLink.runtimeGenerated then
        Button("deletePath", "删除路径", bx, by, 78, false)
    elseif selectedLink and selectedLink.kind == "stairs" then
        local spec = selectedLink.stairSpec or {}
        local style = spec.previewStyle or spec.style or "l-turn"
        bx = Button("stairStyleL", "L 型", bx, by, 52, style == "l-turn")
        bx = Button("stairStyleStraight", "直梯", bx, by, 52, style == "straight")
        bx = Button("rotateStair", "旋转 90°", bx, by, 74, false)
        bx = Button("lockStair", spec.mode == "locked" and "稳定自动" or "锁定位置", bx, by, 78, false)
        if spec.pending then
            bx = Button("confirmStair", "确认楼梯", bx, by, 74, false)
            Button("cancelStair", "取消", bx, by, 52, false)
        else Button("deleteStair", "删除楼梯", bx, by, 74, false) end
    elseif selectedLink then
        bx = Button("narrow", "宽度 -", bx, by, 66, false)
        bx = Button("widen", "宽度 +", bx, by, 66, false)
        bx = Button("addBend", "添加折点", bx, by, 78, false)
        Button("deletePath", "删除路径", bx, by, 78, false)
        nvgFontSize(self.vg, 10); Fill(self.vg, 218, 166, 95, 255)
        nvgText(self.vg, px + pw - 80, by + 15, "W " .. tostring(selectedLink.width or 2), nil)
    else
        nvgFontSize(self.vg, 10); Fill(self.vg, 126, 136, 154, 255)
        local selectedRoom = self.rooms[self.selected]
        nvgText(self.vg, bx, by + 15, selectedRoom
            and string.format("房间 #%d · %dx%d%s", self.selected, selectedRoom.w, selectedRoom.h,
                selectedRoom.locked and " · 已锁定" or "")
            or "选择房间、路径或楼梯后显示对应操作", nil)
    end

    RoundedRect(self.vg, cx, cy, cw, ch, 5, { 12, 16, 25, 255 })
    nvgScissor(self.vg, cx, cy, cw, ch)

    -- Cross-floor visual stack: adjacent floor ghost -> stairs/corridors ->
    -- current-floor rooms. This matches the Three.js editor and keeps the
    -- current floor authoritative without hiding stairs behind the ghost layer.
    for index, room in ipairs(self.rooms) do
        local delta = (room.floor or 0) - self.floor
        if math.abs(delta) == 1 then
            local p = self.editorViewport:GridToScreen({ x = room.cx - room.w * 0.5, y = room.cy - room.h * 0.5 })
            nvgBeginPath(self.vg); nvgRect(self.vg, p.x, p.y, room.w * self.scale, room.h * self.scale)
            Fill(self.vg, delta < 0 and 128 or 76, 91, delta < 0 and 190 or 158, 28); nvgFill(self.vg)
        end
    end
    EditorGizmos.RenderBackground(self, self.vg, self.editorViewport, self.gizmoDescriptors)

    self.roomRects = {}
    for index, room in ipairs(self.rooms) do
        if room.floor == self.floor then
            local p = self.editorViewport:GridToScreen({ x = room.cx - room.w * 0.5, y = room.cy - room.h * 0.5 })
            local rect = { index = index, x = p.x, y = p.y, w = room.w * self.scale, h = room.h * self.scale }
            self.roomRects[#self.roomRects + 1] = rect
            local selected = self.selected == index
            local group = self.roomGroupsById[room.roomGroupId]
            local groupColor = group and RoomGroupColors.ToRGBA(
                RoomGroupColors.Parse(group.color, RoomGroupColors.Default(group, 1)), 245)
            local color = selected and { 231, 145, 58, 235 }
                or (room.locked and { 77, 86, 105, 240 }
                    or groupColor
                    or (room.roleHint == "secret" and { 112, 65, 151, 238 } or { 46, 63, 78, 245 }))
            RoundedRect(self.vg, rect.x, rect.y, rect.w, rect.h, 3, color)
            nvgBeginPath(self.vg); nvgRoundedRect(self.vg, rect.x, rect.y, rect.w, rect.h, 3)
            Stroke(self.vg, selected and 255 or 114, selected and 215 or 132,
                selected and 157 or 151, 255, selected and 2 or 1); nvgStroke(self.vg)
            DrawRoomNumber(self.vg, rect, index)
        end
    end
    EditorGizmos.RenderForeground(self, self.vg, self.editorViewport, self.gizmoDescriptors)
    if self.draw then
        local p0 = self.editorViewport:GridToScreen({ x = math.min(self.draw.gx, self.draw.ex),
            y = math.min(self.draw.gy, self.draw.ey) })
        local p1 = self.editorViewport:GridToScreen({ x = math.max(self.draw.gx, self.draw.ex),
            y = math.max(self.draw.gy, self.draw.ey) })
        nvgBeginPath(self.vg); nvgRect(self.vg, p0.x, p0.y, p1.x - p0.x, p1.y - p0.y)
        Fill(self.vg, 230, 145, 58, 70); nvgFill(self.vg); Stroke(self.vg, 240, 165, 80, 255, 2); nvgStroke(self.vg)
    end
    nvgResetScissor(self.vg)
    nvgFontSize(self.vg, 10); Fill(self.vg, 126, 136, 154, 255)
    nvgText(self.vg, px + 18, py + ph - 17,
        "左键：编辑 · 右键：上下文操作 · L：锁定 · Delete：删除 · Esc：完成", nil)
    self.contextMenu:Render(self.vg)
    nvgEndFrame(self.vg)
end

function LayoutEditor:Update(_)
    if not self.visible then return end
    local dpr = math.max(1, graphics:GetDPR())
    local mousePosition = input.mousePosition
    local mx, my = mousePosition.x / dpr, mousePosition.y / dpr
    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    local leftPressed, leftReleased = self.editorInteraction:Sample(leftDown,
        input:GetMouseButtonPress(MOUSEB_LEFT), input:GetMouseButtonRelease(MOUSEB_LEFT))
    local middleDown = input:GetMouseButtonDown(MOUSEB_MIDDLE)
    local altDown = input:GetKeyDown(KEY_LALT) or input:GetKeyDown(KEY_RALT)
    self.contextMenu:UpdateHover(mx, my)

    if self.canvas and Inside(mx, my, self.canvas) and input.mouseMoveWheel ~= 0 then
        self.editorViewport:ZoomAt(mx, my, input.mouseMoveWheel)
    end
    self.gizmoDescriptors = self.canvas and EditorGizmos.Build(self, self.editorViewport) or {}
    self.hoveredGizmo = EditorGizmos.Hit(self.gizmoDescriptors, mx, my)

    if input:GetMouseButtonPress(MOUSEB_MIDDLE) or (leftPressed and altDown) then
        self.pan = { x = mx, y = my, originX = self.editorViewport.originX,
            originY = self.editorViewport.originY, button = middleDown and "middle" or "left" }
        return
    end
    if self.pan then
        local stillDown = self.pan.button == "middle" and middleDown or leftDown
        if stillDown then
            self.editorViewport.originX = self.pan.originX + mx - self.pan.x
            self.editorViewport.originY = self.pan.originY + my - self.pan.y
        else self.pan = nil end
        return
    end

    if input:GetKeyPress(KEY_ESCAPE) then
        if self.drag or self.draw then
            self.drag, self.draw = nil, nil; self.editorInteraction:Release(); return
        end
        if self.contextMenu:IsOpen() then self.contextMenu:Close(); return end
        if self.stairPlacing and self:CancelSelectedStair() then return end
        local selectedLink = self.links[self.selectedLink]
        if selectedLink and selectedLink.stairSpec and selectedLink.stairSpec.pending
            and self:CancelSelectedStair() then return end
        if self.callbacks.onClose then self.callbacks.onClose() end
        return
    end
    if input:GetKeyPress(KEY_TAB) then
        if self.callbacks.onViewMode then self.callbacks.onViewMode("3d") end
        return
    end
    if input:GetKeyPress(KEY_DELETE) or input:GetKeyPress(KEY_BACKSPACE) then
        local link = self.links[self.selectedLink]
        if link and link.runtimeGenerated then self:DeleteSelected()
        elseif link and link.kind == "stairs" then self:DeleteSelectedStair()
        elseif self.selectedLink or self.selected then self:DeleteSelected() end
        return
    end
    if input:GetKeyPress(KEY_L) and self.selected and self.rooms[self.selected] then
        self.rooms[self.selected].locked = not self.rooms[self.selected].locked
        self:Commit(); return
    end

    if input:GetMouseButtonPress(MOUSEB_RIGHT) then
        self:OpenContextMenu(mx, my)
        return
    end

    if leftPressed and not altDown then
        if self.drag or self.draw or self.editorInteraction:IsCaptured() then EditorGesture.Finish(self, nil) end
        if self.contextMenu:IsOpen() then
            local context = self.contextMenu.context
            local item, consumed = self.contextMenu:Hit(mx, my)
            if item then self:HandleContextAction(item, context) end
            if item or consumed then return end
        end
        if self:HandleToolbar(mx, my) then return end
        if not self.canvas or not Inside(mx, my, self.canvas) then return end
        local gridX, gridY = self.editorViewport:ScreenToGrid(mx, my)
        local hit = self:HitRoom({ x = gridX, y = 0, z = gridY })
        if self.stairPlacing then
            if hit then self:PlaceStairAt(hit, gridX, gridY) end
            return
        end
        if self.mode == "select" then
            local handle = self.hoveredGizmo
            local roomHandle = handle and handle.kind == "roomResize" and handle.mode or nil
            local linkHandle = handle and handle.kind ~= "roomResize" and handle or nil
            local path = not hit and not roomHandle and not linkHandle and self:HitLink(gridX, gridY) or nil
            if roomHandle and self.selected then
                local room = self.rooms[self.selected]
                if not room.locked then
                    local stairEdit = self:CaptureRoomStairEdit(self.selected)
                    self.drag = { kind = "roomResize", index = self.selected, mode = roomHandle,
                        start = { cx = room.cx, cy = room.cy, w = room.w, h = room.h },
                        adaptive = self:CaptureAdaptiveRoutes(stairEdit.pair and nil or self.selected),
                        stairEdit = stairEdit }
                end
            elseif linkHandle and self.selectedLink then
                local link = self.links[self.selectedLink]
                if linkHandle.kind == "stairRotate" or linkHandle.kind == "stairWidth" then
                    local stair = self:CaptureStairDrag(self.selectedLink)
                    if stair then
                        local direction = stair.spec.previewDirection or stair.spec.direction or stair.connector.direction
                        self.drag = { kind = linkHandle.kind, link = self.selectedLink, stair = stair,
                            lastDirection = direction, appliedDirection = direction,
                            lastWidth = stair.spec.previewWidth or stair.spec.width or stair.connector.width }
                    end
                else
                    if linkHandle.kind == "bend" then self:EnsureEditableRoute(link) end
                    self.drag = { kind = "link" .. (linkHandle.kind == "door" and "Door" or "Bend"),
                        link = self.selectedLink, which = linkHandle.which, bendIndex = linkHandle.bendIndex,
                        originalDoor = RouteEditing.CopyDoor(linkHandle.which == "a" and link.doorA or link.doorB) }
                end
            elseif path then
                self.selected, self.selectedLink = nil, path.index; self:NotifySelection()
                if path.runtime then
                    self.drag = nil
                elseif path.stair then
                    local stair = self:CaptureStairDrag(path.index)
                    local anchor = stair and (stair.spec.previewAnchor or stair.spec.anchor or stair.connector.lower)
                    if stair and anchor then
                        self.drag = { kind = "stairMove", link = path.index, startX = gridX, startY = gridY,
                            anchor = CopyPoint(anchor), stair = stair, lastDX = 0, lastDY = 0 }
                    end
                else
                    self.drag = { kind = "linkSegment", link = path.index, segment = path.segment,
                        startX = gridX, startY = gridY, pending = true }
                end
            elseif hit then
                local wasSelected = self.selected == hit and self.selectedLink == nil
                self.selected, self.selectedLink = hit, nil; self:NotifySelection()
                local room = self.rooms[hit]
                if wasSelected and not room.locked then
                    local stairEdit = self:CaptureRoomStairEdit(hit)
                    self.drag = { kind = "roomMove", index = hit, startX = gridX, startY = gridY,
                        start = { cx = room.cx, cy = room.cy },
                        adaptive = self:CaptureAdaptiveRoutes(stairEdit.pair and nil or hit), stairEdit = stairEdit }
                end
            else
                self.selected, self.selectedLink = nil, nil; self:NotifySelection()
                self.blankPanActive = true
                self.pan = { x = mx, y = my, originX = self.editorViewport.originX,
                    originY = self.editorViewport.originY, button = "left" }
            end
        elseif self.mode == "draw" and not hit then
            self.draw = { gx = gridX, gy = gridY, ex = gridX, ey = gridY }
        elseif self.mode == "connect" and hit then
            if self.linkStart and self.linkStart ~= hit then
                local startRoom, targetRoom = self.rooms[self.linkStart], self.rooms[hit]
                if startRoom.floor == targetRoom.floor then
                    local existing = EditorData.FindLink(self.links, self.linkStart, hit)
                    if not existing then
                        self.links[#self.links + 1] = { a = self.linkStart, b = hit, kind = "corridor",
                            isLoop = true, isManual = true, width = 2, bends = {}, autoRoute = {} }
                    end
                    self.selected, self.selectedLink, self.linkStart = nil, existing or #self.links, nil
                    self:NormalizeConnectedSecretRooms(); self:Commit()
                elseif self.callbacks.onStatus then
                    self.callbacks.onStatus("跨层连接请使用楼梯工具；普通路径只连接同层房间。")
                end
            else
                self.linkStart, self.selected, self.selectedLink = hit, hit, nil; self:NotifySelection()
            end
        else self.selected, self.selectedLink = hit, nil; self:NotifySelection() end
        if self.drag or self.draw then self.editorInteraction:Capture() end
    end

    if leftDown and not altDown and not self.pan then
        local gridX, gridY = self.editorViewport:ScreenToGrid(mx, my)
        if self.drag then EditorGesture.Apply(self, gridX, gridY)
        elseif self.draw then EditorGesture.UpdateDraw(self, gridX, gridY) end
    end
    if leftReleased then
        if not self.pan then EditorGesture.Finish(self, mousePosition) end
        self.pan, self.blankPanActive = nil, false
    end
end

function LayoutEditor:Dispose()
    self.editorInteraction:Release()
    if self.vg then nvgDelete(self.vg); self.vg = nil end
end

PathWorkflow.Install(LayoutEditor, { CopyLink = CopyLink })
StairWorkflow.Install(LayoutEditor, { CopyRooms = CopyRooms, CopyLink = CopyLink })

return LayoutEditor
