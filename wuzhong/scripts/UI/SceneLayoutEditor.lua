local UI = require("urhox-libs/UI")
local RouteEditing = require("UI.Editor.RouteEditing")
local ContextMenu = require("UI.Editor.ContextMenu")
local StairEditing = require("UI.Editor.StairEditing")
local StairWorkflow = require("UI.Editor.StairWorkflow")
local PathWorkflow = require("UI.Editor.PathWorkflow")
local EditorData = require("UI.Editor.EditorData")
local EditorViewport = require("UI.Editor.EditorViewport")
local EditorGizmos = require("UI.Editor.EditorGizmos")
local EditorInteraction = require("UI.Editor.EditorInteraction")
local EditorGesture = require("UI.Editor.EditorGesture")
local RoomEditing = require("UI.Editor.RoomEditing")
local EditorSession = require("UI.Editor.EditorSession")
local MultiFloor = require("Generation.MultiFloor")
local RoomGroupColors = require("Config.RoomGroupColors")

local SceneLayoutEditor = {}
SceneLayoutEditor.__index = SceneLayoutEditor

local function Clamp(value, low, high) return math.max(low, math.min(high, value)) end

local function Inside(x, y, rect)
    return rect and x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h end

local CopyRooms = EditorData.CopyRooms
local CopyPoint = RouteEditing.CopyPoint
local CopyLink = EditorData.CopyLink
local LinkKey = EditorData.LinkKey

local Snap = RouteEditing.Snap
local DistanceToSegment = RouteEditing.DistanceToSegment

local function HexColor(value, alpha)
    return Color(((value >> 16) & 0xff) / 255, ((value >> 8) & 0xff) / 255,
        (value & 0xff) / 255, alpha or 1)
end

local function CreateOverlayMaterial(color, alpha, emissive)
    local material = Material:new()
    material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    material:SetShaderParameter("MatDiffColor", Variant(HexColor(color, alpha)))
    material:SetShaderParameter("MatEmissiveColor", Variant(HexColor(emissive or color, 1)))
    material:SetShaderParameter("Metallic", Variant(0.0))
    material:SetShaderParameter("Roughness", Variant(0.32))
    return material
end

local function Fill(context, red, green, blue, alpha)
    nvgFillColor(context, nvgRGBA(red, green, blue, alpha or 255))
end

local function RoundedRect(context, x, y, width, height, radius, color)
    nvgBeginPath(context)
    nvgRoundedRect(context, x, y, width, height, radius)
    Fill(context, color[1], color[2], color[3], color[4])
    nvgFill(context)
end

function SceneLayoutEditor.new(scene, camera, eventObject, callbacks)
    local self = setmetatable({
        scene = scene,
        camera = camera,
        eventObject = eventObject,
        callbacks = callbacks or {},
        visible = false,
        mode = "select",
        floor = 0,
        floorCount = 1,
        rooms = {},
        links = {},
        connectors = {},
        selected = nil,
        selectedLink = nil,
        hoveredRoom = nil,
        hoveredLink = nil,
        rightPress = nil,
        blankPanActive = false,
        blankPanPressBlocked = false,
        linkStart = nil,
        drag = nil,
        draw = nil,
        dungeonWidth = 1,
        dungeonHeight = 1,
        generatedOffset = { x = 0, y = 0 },
        floorHeight = MultiFloor.FLOOR_HEIGHT,
        roomNodes = {},
        linkNodes = {},
        handleNodes = {},
        buttons = {},
        contextMenu = ContextMenu.new(),
        nextStairId = 1,
        stairSnapshot = nil,
        stairPlacing = false,
        stairPlacementStyle = "l-turn",
        groupMaterials = {},
        roomGroupsById = {},
        gizmoDescriptors = {},
        hoveredGizmo = nil,
        editorViewport = EditorViewport.new(camera),
        editorInteraction = EditorInteraction.new(),
        toolbarHover = nil,
    }, SceneLayoutEditor)

    self.materials = {
        normal = CreateOverlayMaterial(0x3dc7b8, 0.34, 0x177c74),
        hover = CreateOverlayMaterial(0x76e0d2, 0.46, 0x2a978b),
        selected = CreateOverlayMaterial(0xffa548, 0.58, 0xb85a18),
        locked = CreateOverlayMaterial(0x68758d, 0.32, 0x303846),
        manual = CreateOverlayMaterial(0xffb458, 0.78, 0xb8621f),
        link = CreateOverlayMaterial(0x59a7d8, 0.68, 0x235879),
        linkHover = CreateOverlayMaterial(0x8bcff4, 0.78, 0x347fa8),
        linkSelected = CreateOverlayMaterial(0xffa548, 0.84, 0xb85a18),
        doorHandle = CreateOverlayMaterial(0xffd36a, 0.92, 0xc48420),
        bendHandle = CreateOverlayMaterial(0xe8973f, 0.92, 0x9c4f18),
        preview = CreateOverlayMaterial(0x86e36e, 0.42, 0x3a8c31),
        entrance = CreateOverlayMaterial(0x3fd0bb, 0.48, 0x177c74),
        boss = CreateOverlayMaterial(0xd8433a, 0.48, 0x8f211b),
        secret = CreateOverlayMaterial(0xb86cff, 0.48, 0x7132a8),
        adjacentAbove = CreateOverlayMaterial(0x5a8fe8, 0.12, 0x31538c),
        adjacentBelow = CreateOverlayMaterial(0x9b6cf0, 0.12, 0x5d3c98),
        stair = CreateOverlayMaterial(0xe8973f, 0.72, 0x9c4f18),
        stairInvalid = CreateOverlayMaterial(0xff4848, 0.72, 0xa91f1f),
    }

    self.vg = nvgCreate(1)
    if self.vg then
        -- Keep editor canvas above the 3D viewport but below urhox-libs/UI (999990).
        nvgSetRenderOrder(self.vg, 999980)
        self.font = nvgCreateFont(self.vg, "forge3d", "Fonts/MiSans-Regular.ttf")
        eventObject:SubscribeToEvent(self.vg, "NanoVGRender", function() self:Render() end)
    else
        print("[SceneLayoutEditor] NanoVG context creation failed")
    end
    return self
end

function SceneLayoutEditor:GetViewMode()
    return "3d"
end

function SceneLayoutEditor:IsVisible()
    return self.visible
end

function SceneLayoutEditor:IsBlankPanActive()
    return self.visible and self.blankPanActive == true
end

function SceneLayoutEditor:SetVisible(visible)
    self.visible = visible
    self.drag, self.draw = nil, nil
    self.blankPanActive, self.blankPanPressBlocked = false, false
    self.editorInteraction:Reset(input:GetMouseButtonDown(MOUSEB_LEFT))
    self.hoveredRoom, self.hoveredLink = nil, nil
    self.rightPress = nil
    self.contextMenu:Close()
    if not visible then
        self.linkStart, self.stairPlacing = nil, false
        self:ClearOverlay()
    else
        self:RefreshOverlay()
        self:NotifySelection()
    end
end

function SceneLayoutEditor:NotifySelection()
    if self.callbacks.onSelection then
        self.callbacks.onSelection(self.selected, self.rooms[self.selected], "3d",
            self.selectedLink, self.links[self.selectedLink])
    end
end

function SceneLayoutEditor:SetFloor(floor)
    self.floor = floor
    self.stairPlacing = false
    self.selected, self.selectedLink, self.linkStart = nil, nil, nil
    self.hoveredRoom, self.hoveredLink = nil, nil
    self.contextMenu:Close()
    self:RefreshOverlay()
    self:NotifySelection()
end

function SceneLayoutEditor:SyncDungeon(dungeon, floor, roomGroups)
    local selectedRoom = self.selected
    local selectedKey = LinkKey(self.links[self.selectedLink])
    self.roomGroupsById = {}
    for _, group in ipairs(roomGroups or {}) do
        if group and group.id then self.roomGroupsById[group.id] = group end
    end
    self.groupMaterials = {}
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
        if link.stairSpec and link.connector then
            link.stairSpec.previewAnchor = CopyPoint(link.connector.lower)
            link.stairSpec.previewDirection = link.connector.direction
            link.stairSpec.previewLength = link.connector.length
            link.stairSpec.previewStyle = link.connector.style or link.stairSpec.style
            link.stairSpec.previewWidth = link.connector.width or link.stairSpec.width
            link.stairSpec.previewLandingDepth = link.connector.landingDepth or link.stairSpec.landingDepth
            link.stairSpec.candidateIndex = link.connector.candidateIndex or link.stairSpec.candidateIndex
            link.stairSpec.candidateCount = link.connector.candidateCount or link.stairSpec.candidateCount
            link.stairSpec.invalid = false
            link.stairSpec.error = nil
        elseif link.stairSpec then
            link.stairSpec.invalid = true
            link.stairSpec.error = "楼梯位置与现有区域、路径或其他楼梯冲突"
        end
        self.links[#self.links + 1] = link
    end
    self.floor = floor or self.floor
    self.floorCount = dungeon and dungeon.floorCount or self.floorCount
    self.connectors = dungeon and dungeon.connectors or {}
    self.dungeonWidth = dungeon and dungeon.width or 1
    self.dungeonHeight = dungeon and dungeon.height or 1
    self.generatedOffset = { x = 0, y = 0 }
    self.floorHeight = dungeon and dungeon.floorHeight or MultiFloor.FLOOR_HEIGHT
    self.selected = self.rooms[selectedRoom] and selectedRoom or nil
    self.selectedLink = nil
    for index, link in ipairs(self.links) do
        if LinkKey(link) == selectedKey then self.selectedLink = index; break end
    end
    self.linkStart, self.drag, self.draw = nil, nil, nil
    self.hoveredRoom, self.hoveredLink = nil, nil
    self:RefreshOverlay()
    self:NotifySelection()
end

function SceneLayoutEditor:GetRooms()
    return CopyRooms(self.rooms)
end

function SceneLayoutEditor:GetLinks()
    local result = {}
    for index, link in ipairs(self.links) do
        result[index] = CopyLink(link)
    end
    return result
end

function SceneLayoutEditor:SyncEditorState(source)
    return EditorSession.Apply(self, EditorSession.Capture(source))
end

function SceneLayoutEditor:Commit()
    for index, room in ipairs(self.rooms) do room.id = index end
    if self.callbacks.onCommit then
        self.callbacks.onCommit(self:GetRooms(), self:GetLinks())
    end
end

function SceneLayoutEditor:SetSelectedRoomGroup(groupId)
    local room = self.rooms[self.selected]
    if not room then return false, "请先在三维编辑器中选择一个房间。" end
    room.roomGroupId = groupId
    self:Commit()
    self:NotifySelection()
    return true
end

function SceneLayoutEditor:ClearRoomGroup(groupId)
    for _, room in ipairs(self.rooms) do if room.roomGroupId == groupId then room.roomGroupId = nil end end
    self:RefreshOverlay()
    self:NotifySelection()
end

function SceneLayoutEditor:ClearOverlay()
    if self.overlayRoot then
        self.overlayRoot:Remove()
        self.overlayRoot = nil
    end
    self.roomNodes = {}
    self.linkNodes = {}
    self.handleNodes = {}
    self.previewNode = nil
end

function SceneLayoutEditor:RoomWorldPosition(room, localY)
    local offset = self.generatedOffset or { x = 0, y = 0 }
    return Vector3(
        room.cx + offset.x - self.dungeonWidth * 0.5 + 0.5,
        room.floor * self.floorHeight + (localY or 0),
        room.cy + offset.y - self.dungeonHeight * 0.5 + 0.5
    )
end

function SceneLayoutEditor:AddBox(parent, name, position, scale, material)
    local node = parent:CreateChild(name)
    node.position = position
    node.scale = scale
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    model:SetMaterial(material)
    model.castShadows = false
    return node, model
end

function SceneLayoutEditor:DoorSpecPoint(room, spec)
    if not room or not spec then return nil end
    local side = tostring(spec.side or "east")
    if side == "n" then side = "north" elseif side == "s" then side = "south"
    elseif side == "w" then side = "west" elseif side == "e" then side = "east" end
    local offset = Clamp(tonumber(spec.offset) or 0, -0.82, 0.82)
    if side == "north" then return { x = room.cx + offset * room.w * 0.5, y = room.cy - room.h * 0.5, side = side } end
    if side == "south" then return { x = room.cx + offset * room.w * 0.5, y = room.cy + room.h * 0.5, side = side } end
    if side == "west" then return { x = room.cx - room.w * 0.5, y = room.cy + offset * room.h * 0.5, side = side } end
    return { x = room.cx + room.w * 0.5, y = room.cy + offset * room.h * 0.5, side = "east" }
end

function SceneLayoutEditor:PointToDoorSpec(room, point)
    local x0, x1 = room.cx - room.w * 0.5, room.cx + room.w * 0.5
    local y0, y1 = room.cy - room.h * 0.5, room.cy + room.h * 0.5
    local distances = {
        { side = "north", value = math.abs(point.y - y0) },
        { side = "south", value = math.abs(point.y - y1) },
        { side = "west", value = math.abs(point.x - x0) },
        { side = "east", value = math.abs(point.x - x1) },
    }
    table.sort(distances, function(a, b) return a.value < b.value end)
    local side = distances[1].side
    local offset = (side == "north" or side == "south")
        and (point.x - room.cx) / math.max(1, room.w * 0.5)
        or (point.y - room.cy) / math.max(1, room.h * 0.5)
    return { side = side, offset = Clamp(offset, -0.82, 0.82) }
end

function SceneLayoutEditor:AutomaticDoorPoint(room, other)
    local dx, dy = other.cx - room.cx, other.cy - room.cy
    local halfWidth, halfHeight = math.max(1, room.w * 0.5), math.max(1, room.h * 0.5)
    if math.abs(dx) / halfWidth >= math.abs(dy) / halfHeight then
        return {
            x = room.cx + (dx >= 0 and halfWidth or -halfWidth),
            y = room.cy + Clamp(dy, -halfHeight * 0.82, halfHeight * 0.82),
            side = dx >= 0 and "east" or "west",
        }
    end
    return {
        x = room.cx + Clamp(dx, -halfWidth * 0.82, halfWidth * 0.82),
        y = room.cy + (dy >= 0 and halfHeight or -halfHeight),
        side = dy >= 0 and "south" or "north",
    }
end

function SceneLayoutEditor:LinkEndpoints(link)
    local roomA, roomB = self.rooms[link.a], self.rooms[link.b]
    if not roomA or not roomB or roomA.floor ~= roomB.floor then return nil, nil end
    local startPoint = self:DoorSpecPoint(roomA, link.doorA) or self:AutomaticDoorPoint(roomA, roomB)
    local endPoint = self:DoorSpecPoint(roomB, link.doorB) or self:AutomaticDoorPoint(roomB, roomA)
    return startPoint, endPoint
end

function SceneLayoutEditor:LinkRoute(link)
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

function SceneLayoutEditor:DisplayLinkRoute(link)
    local route = self:LinkRoute(link)
    local auto = link and (not link.bends or #link.bends == 0) and not link.doorA and not link.doorB
        and link.autoRoute and #link.autoRoute > 1
    local offset = auto and RouteEditing.CorridorCenterOffset(link.width) or 0
    if offset == 0 or #route < 2 then return route end
    local displayed = {}
    for index, point in ipairs(route) do displayed[index] = { x = point.x + offset, y = point.y + offset, side = point.side } end
    local function FixEndpoint(index, neighborIndex)
        local endpoint, neighbor = route[index], route[neighborIndex]
        if endpoint.y == neighbor.y and endpoint.x ~= neighbor.x then displayed[index].x = endpoint.x
        elseif endpoint.x == neighbor.x and endpoint.y ~= neighbor.y then displayed[index].y = endpoint.y end
    end
    FixEndpoint(1, 2)
    FixEndpoint(#route, #route - 1)
    return displayed
end

function SceneLayoutEditor:GridToWorld(point, localY)
    local offset = self.generatedOffset or { x = 0, y = 0 }
    return Vector3(point.x + offset.x - self.dungeonWidth * 0.5 + 0.5,
        self.floor * self.floorHeight + (localY or 0),
        point.y + offset.y - self.dungeonHeight * 0.5 + 0.5)
end

function SceneLayoutEditor:AddLinkSegment(parent, link, linkIndex, segmentIndex, aPoint, bPoint, widthScale)
    local a, b = self:GridToWorld(aPoint, 0.34), self:GridToWorld(bPoint, 0.34)
    local delta = b - a
    local length = math.sqrt(delta.x * delta.x + delta.z * delta.z)
    if length < 0.01 then return end
    local node = parent:CreateChild("EditorLink-" .. linkIndex .. "-" .. segmentIndex)
    node.position = (a + b) * 0.5
    node.rotation = Quaternion(math.deg(math.atan(delta.x, delta.z)), Vector3.UP)
    local minimumWidth = widthScale and RouteEditing.CORRIDOR_MIN_WORLD_WIDTH or 0.35
    node.scale = Vector3(math.max(minimumWidth, (link.width or 2) * (widthScale or 1)), 0.07, length)
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    model:SetMaterial(self.selectedLink == linkIndex and self.materials.linkSelected
        or (self.hoveredLink == linkIndex and self.materials.linkHover
            or (link.isManual and self.materials.manual or self.materials.link)))
    model.castShadows = false
    self.linkNodes[#self.linkNodes + 1] = { node = node, model = model, link = linkIndex }
end

function SceneLayoutEditor:AddLink(parent, link, index)
    local roomA, roomB = self.rooms[link.a], self.rooms[link.b]
    if not roomA or not roomB or roomA.floor ~= self.floor or roomB.floor ~= self.floor then return end
    local route = self:DisplayLinkRoute(link)
    for segment = 1, #route - 1 do
        self:AddLinkSegment(parent, link, index, segment, route[segment], route[segment + 1],
            RouteEditing.CORRIDOR_VISUAL_SCALE)
    end
end

function SceneLayoutEditor:AddStairLink(parent, link, index)
    local roomA, roomB = self.rooms[link.a], self.rooms[link.b]
    if not roomA or not roomB or math.abs((roomA.floor or 0) - (roomB.floor or 0)) ~= 1 then return end
    if roomA.floor ~= self.floor and roomB.floor ~= self.floor then return end
    local connector = link.connector
    if not connector or not connector.lower or not connector.upper then return end
    local material = link.stairSpec and link.stairSpec.invalid and self.materials.stairInvalid or self.materials.stair
    local pseudo = { width = connector.width or (link.stairSpec and link.stairSpec.width) or 2, isManual = true }
    local segments, platform = StairEditing.VisualSegments(connector)
    for segmentIndex, segment in ipairs(segments) do
        self:AddLinkSegment(parent, pseudo, index, segmentIndex, segment.start, segment.finish)
        local entry = self.linkNodes[#self.linkNodes]
        if entry then entry.model:SetMaterial(material); entry.stair = true end
    end
    if platform then
        local node, model = self:AddBox(parent, "EditorStairPlatform-" .. index,
            self:GridToWorld(platform.center, 0.34),
            Vector3(platform.visualSpan, 0.07, platform.visualSpan), material)
        self.linkNodes[#self.linkNodes + 1] = { node = node, model = model, link = index, stair = true }
    end
end

function SceneLayoutEditor:RoomMaterial(room, selected, hovered)
    if selected then return self.materials.selected end
    if hovered then return self.materials.hover end
    if room.locked then return self.materials.locked end
    if room.roomGroupId then
        local group = self.roomGroupsById[room.roomGroupId]
        if group then
            local material = self.groupMaterials[room.roomGroupId]
            if not material then
                local color = RoomGroupColors.Parse(group.color,
                    RoomGroupColors.Default(group, 1))
                material = CreateOverlayMaterial(color, 0.44, color)
                self.groupMaterials[room.roomGroupId] = material
            end
            return material
        end
    end
    if room.roleHint == "entrance" then return self.materials.entrance end
    if room.roleHint == "boss" then return self.materials.boss end
    if room.roleHint == "secret" then return self.materials.secret end
    return self.materials.normal
end

function SceneLayoutEditor:RefreshOverlay()
    self:ClearOverlay()
    if not self.visible or not self.scene then return end
    self.overlayRoot = self.scene:CreateChild("Dungeon3DEditorOverlay")
    for _, room in ipairs(self.rooms) do
        local delta = (room.floor or 0) - self.floor
        if math.abs(delta) == 1 then
            self:AddBox(self.overlayRoot, "AdjacentRoom", self:RoomWorldPosition(room, delta > 0 and -self.floorHeight + 0.12 or self.floorHeight + 0.12),
                Vector3(room.w, 0.035, room.h), delta > 0 and self.materials.adjacentAbove or self.materials.adjacentBelow)
        end
    end
    for index, link in ipairs(self.links) do
        if link.kind == "stairs" or (self.rooms[link.a] and self.rooms[link.b]
            and self.rooms[link.a].floor ~= self.rooms[link.b].floor) then
            self:AddStairLink(self.overlayRoot, link, index)
        elseif not self.vg then
            -- NanoVG renders corridors as one continuous, direction-independent
            -- stroke. Keep segmented PBR boxes only as a renderer fallback;
            -- drawing both layers makes horizontal and vertical runs differ.
            self:AddLink(self.overlayRoot, link, index)
        end
    end
    for index, room in ipairs(self.rooms) do
        if room.floor == self.floor then
            local material = self:RoomMaterial(room, false)
            local node, model = self:AddBox(
                self.overlayRoot,
                "EditorRoom-" .. index,
                self:RoomWorldPosition(room, 0.22),
                Vector3(room.w, 0.10, room.h),
                material
            )
            self.roomNodes[index] = { node = node, model = model }
        end
    end
    self:RefreshSelectionMaterials()
end

function SceneLayoutEditor:RefreshScreenGizmos(logicalX, logicalY)
    self.editorViewport:Update()
    self.gizmoDescriptors = EditorGizmos.Build(self, self.editorViewport)
    self.hoveredGizmo = logicalX and logicalY and EditorGizmos.Hit(self.gizmoDescriptors, logicalX, logicalY) or nil
    return self.hoveredGizmo
end

function SceneLayoutEditor:RefreshSelectionMaterials()
    for index, entry in pairs(self.roomNodes) do
        local room = self.rooms[index]
        local material = self:RoomMaterial(room, self.selected == index, self.hoveredRoom == index)
        entry.model:SetMaterial(material)
    end
    for _, entry in ipairs(self.linkNodes) do
        local link = self.links[entry.link]
        if entry.stair then
            entry.model:SetMaterial(link and link.stairSpec and link.stairSpec.invalid and self.materials.stairInvalid
                or (self.selectedLink == entry.link and self.materials.linkSelected
                    or (self.hoveredLink == entry.link and self.materials.linkHover or self.materials.stair)))
        else
            entry.model:SetMaterial(self.selectedLink == entry.link and self.materials.linkSelected
                or (self.hoveredLink == entry.link and self.materials.linkHover
                    or (link and link.isManual and self.materials.manual or self.materials.link)))
        end
    end
end

function SceneLayoutEditor:UpdateSceneHover(mousePosition)
    local roomIndex, linkIndex = nil, nil
    if not self.drag and not self.contextMenu:IsOpen() and not UI.IsPointerOverUI() then
        local world = self:ScreenToFloor(mousePosition)
        if world then
            local hit, gridX, gridY = self:HitRoom(world)
            roomIndex = hit
            if not hit then
                local link = self:HitLink(gridX, gridY)
                linkIndex = link and link.index or nil
            end
        end
    end
    if roomIndex ~= self.hoveredRoom or linkIndex ~= self.hoveredLink then
        self.hoveredRoom, self.hoveredLink = roomIndex, linkIndex
        self:RefreshSelectionMaterials()
    end
end

function SceneLayoutEditor:UpdateRoomVisual(index)
    local room, entry = self.rooms[index], self.roomNodes[index]
    if room and entry then
        entry.node.position = self:RoomWorldPosition(room, 0.22)
        entry.node.scale = Vector3(room.w, 0.10, room.h)
    end
end

function SceneLayoutEditor:UpdateDrawPreview()
    if not self.draw then
        if self.previewNode then self.previewNode:Remove(); self.previewNode = nil end
        return
    end
    local minX, maxX = math.min(self.draw.gx, self.draw.ex), math.max(self.draw.gx, self.draw.ex)
    local minY, maxY = math.min(self.draw.gy, self.draw.ey), math.max(self.draw.gy, self.draw.ey)
    local width, height = math.max(0.2, maxX - minX), math.max(0.2, maxY - minY)
    if not self.previewNode then
        self.previewNode = self:AddBox(self.overlayRoot, "EditorDrawPreview", Vector3(0, 0, 0),
            Vector3(1, 1, 1), self.materials.preview)
    end
    self.previewNode.position = Vector3(
        (minX + maxX) * 0.5 - self.dungeonWidth * 0.5 + 0.5,
        self.floor * self.floorHeight + 0.29,
        (minY + maxY) * 0.5 - self.dungeonHeight * 0.5 + 0.5
    )
    self.previewNode.scale = Vector3(width, 0.12, height)
end

-- Interaction regions (top view of the current floor):
--
--   +---------------- room.w ----------------+
--   |                                        |
--   |             (room.cx, room.cy)         | room.h
--   |                                        |
--   +----------------------------------------+
--
-- A left-click ray is intersected with the current floor's horizontal plane.
-- The resulting X/Z point selects the room rectangle. Border points are included;
-- reverse iteration makes the most recently generated overlapping room win.
function SceneLayoutEditor:ScreenToFloor(mousePosition)
    local width, height = graphics:GetWidth(), graphics:GetHeight()
    if width <= 0 or height <= 0 then return nil end
    local ray = self.camera:GetScreenRay(mousePosition.x / width, mousePosition.y / height)
    if math.abs(ray.direction.y) < 0.0001 then return nil end
    local planeY = self.floor * self.floorHeight + 0.22
    local distance = (planeY - ray.origin.y) / ray.direction.y
    if distance < 0 then return nil end
    return ray.origin + ray.direction * distance
end

function SceneLayoutEditor:WorldToGrid(point)
    local offset = self.generatedOffset or { x = 0, y = 0 }
    return point.x + self.dungeonWidth * 0.5 - 0.5 - offset.x,
        point.z + self.dungeonHeight * 0.5 - 0.5 - offset.y
end

function SceneLayoutEditor:HitRoom(point)
    local gridX, gridY = self:WorldToGrid(point)
    for index = #self.rooms, 1, -1 do
        local room = self.rooms[index]
        if room.floor == self.floor
            and gridX >= room.cx - room.w * 0.5 and gridX <= room.cx + room.w * 0.5
            and gridY >= room.cy - room.h * 0.5 and gridY <= room.cy + room.h * 0.5 then
            return index, gridX, gridY
        end
    end
    return nil, gridX, gridY
end

function SceneLayoutEditor:HitTolerance()
    local dpr = math.max(1, graphics:GetDPR())
    local logicalHeight = math.max(1, graphics:GetHeight() / dpr)
    return math.max(0.7, (self.camera.orthoSize or 30) * 10 / logicalHeight)
end

function SceneLayoutEditor:HitRoomHandle(gridX, gridY)
    local room = self.rooms[self.selected]
    if not room or room.floor ~= self.floor then return nil end
    local tolerance = self:HitTolerance()
    local handles = {
        { mode = "resize-nw", x = room.cx - room.w * 0.5, y = room.cy - room.h * 0.5 },
        { mode = "resize-ne", x = room.cx + room.w * 0.5, y = room.cy - room.h * 0.5 },
        { mode = "resize-sw", x = room.cx - room.w * 0.5, y = room.cy + room.h * 0.5 },
        { mode = "resize-se", x = room.cx + room.w * 0.5, y = room.cy + room.h * 0.5 },
    }
    for _, handle in ipairs(handles) do
        if math.sqrt((gridX - handle.x)^2 + (gridY - handle.y)^2) <= tolerance then return handle.mode end
    end
    local x0, x1 = room.cx - room.w * 0.5, room.cx + room.w * 0.5
    local y0, y1 = room.cy - room.h * 0.5, room.cy + room.h * 0.5
    if gridX >= x0 - tolerance and gridX <= x1 + tolerance then
        if math.abs(gridY - y0) <= tolerance then return "resize-n" end
        if math.abs(gridY - y1) <= tolerance then return "resize-s" end
    end
    if gridY >= y0 - tolerance and gridY <= y1 + tolerance then
        if math.abs(gridX - x0) <= tolerance then return "resize-w" end
        if math.abs(gridX - x1) <= tolerance then return "resize-e" end
    end
    return nil
end

function SceneLayoutEditor:HitLinkHandle(gridX, gridY)
    local link = self.links[self.selectedLink]
    if not link then return nil end
    if link.kind == "stairs" and link.connector and link.connector.lower and link.connector.upper then
        local tolerance = self:HitTolerance()
        local rotate, width = StairEditing.RotationHandle(link.connector), StairEditing.WidthHandle(link.connector)
        if rotate and math.sqrt((gridX - rotate.x)^2 + (gridY - rotate.y)^2) <= tolerance then
            return { kind = "stairRotate", point = rotate }
        end
        if width and math.sqrt((gridX - width.x)^2 + (gridY - width.y)^2) <= tolerance then
            return { kind = "stairWidth", point = width }
        end
        return nil
    end
    local route, tolerance = self:DisplayLinkRoute(link), self:HitTolerance()
    for index, point in ipairs(route) do
        if math.sqrt((gridX - point.x)^2 + (gridY - point.y)^2) <= tolerance then
            if index == 1 then return { kind = "door", which = "a", point = point } end
            if index == #route then return { kind = "door", which = "b", point = point } end
            return { kind = "bend", bendIndex = index - 1, point = point }
        end
    end
    return nil
end

function SceneLayoutEditor:HitLink(gridX, gridY)
    local best, tolerance = nil, self:HitTolerance()
    for linkIndex, link in ipairs(self.links) do
        local roomA, roomB = self.rooms[link.a], self.rooms[link.b]
        if roomA and roomB and roomA.floor ~= roomB.floor and link.connector
            and (roomA.floor == self.floor or roomB.floor == self.floor) then
            local stairSegments = StairEditing.VisualSegments(link.connector)
            local linkTolerance = math.max(tolerance, (link.connector.width or 2) * 0.5)
            for segment, stairSegment in ipairs(stairSegments) do
                local distance = DistanceToSegment(gridX, gridY, stairSegment.start, stairSegment.finish)
                if distance <= linkTolerance and (not best or distance < best.distance) then
                    best = { index = linkIndex, segment = segment, distance = distance, stair = true }
                end
            end
        elseif roomA and roomB and roomA.floor == self.floor and roomB.floor == self.floor then
            local route = self:DisplayLinkRoute(link)
            local linkTolerance = math.max(tolerance, (link.width or 2) * 0.5)
            for segment = 1, #route - 1 do
                local distance = DistanceToSegment(gridX, gridY, route[segment], route[segment + 1])
                if distance <= linkTolerance and (not best or distance < best.distance) then
                    best = { index = linkIndex, segment = segment, distance = distance }
                end
            end
        end
    end
    return best
end

function SceneLayoutEditor:ResizeRoom(room, start, gridX, gridY, mode)
    local resized = RoomEditing.Resize(start, { x = gridX, y = gridY }, mode)
    room.cx, room.cy, room.w, room.h = resized.cx, resized.cy, resized.w, resized.h
end

function SceneLayoutEditor:AddBend()
    local link = self.links[self.selectedLink]
    if not link then return end
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

function SceneLayoutEditor:MarkDisconnectedRoomsSecret()
    if #self.rooms <= 1 then return end
    local adjacency = {}
    for index = 1, #self.rooms do adjacency[index] = {} end
    for _, link in ipairs(self.links) do
        if adjacency[link.a] and adjacency[link.b] then
            adjacency[link.a][#adjacency[link.a] + 1] = link.b
            adjacency[link.b][#adjacency[link.b] + 1] = link.a
        end
    end
    local seen, components = {}, {}
    for start = 1, #self.rooms do
        if not seen[start] then
            local queue, component, head = { start }, {}, 1
            seen[start] = true
            while head <= #queue do
                local roomIndex = queue[head]
                head = head + 1
                component[#component + 1] = roomIndex
                for _, neighbor in ipairs(adjacency[roomIndex]) do
                    if not seen[neighbor] then seen[neighbor] = true; queue[#queue + 1] = neighbor end
                end
            end
            components[#components + 1] = component
        end
    end
    if #components <= 1 then return end
    local main = components[1]
    for _, component in ipairs(components) do
        local priority = false
        for _, roomIndex in ipairs(component) do
            local hint = self.rooms[roomIndex].roleHint
            if hint == "entrance" or hint == "boss" then priority = true; break end
        end
        if priority or #component > #main then main = component end
        if priority then break end
    end
    local inMain = {}
    for _, roomIndex in ipairs(main) do inMain[roomIndex] = true end
    for roomIndex, room in ipairs(self.rooms) do
        if not inMain[roomIndex] then room.roleHint = "secret" end
    end
end

function SceneLayoutEditor:NormalizeConnectedSecretRooms()
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
            local queue, component, head, hasNormal = { start }, {}, 1, false
            seen[start] = true
            while head <= #queue do
                local roomIndex = queue[head]
                head = head + 1
                component[#component + 1] = roomIndex
                if self.rooms[roomIndex].roleHint ~= "secret" then hasNormal = true end
                for _, neighbor in ipairs(adjacency[roomIndex]) do
                    if not seen[neighbor] then seen[neighbor] = true; queue[#queue + 1] = neighbor end
                end
            end
            if hasNormal then
                for _, roomIndex in ipairs(component) do
                    if self.rooms[roomIndex].roleHint == "secret" then self.rooms[roomIndex].roleHint = nil end
                end
            end
        end
    end
end

function SceneLayoutEditor:DeleteSelected()
    if self.selectedLink then
        table.remove(self.links, self.selectedLink)
        self.selectedLink = nil
        self:MarkDisconnectedRoomsSecret()
        self:Commit()
        return
    end
    if not self.selected then return end
    local room = self.rooms[self.selected]
    if not room then return end
    local removed = self.selected
    for index = #self.links, 1, -1 do
        local link = self.links[index]
        if link.a == removed or link.b == removed then
            table.remove(self.links, index)
        else
            if link.a > removed then link.a = link.a - 1 end
            if link.b > removed then link.b = link.b - 1 end
        end
    end
    table.remove(self.rooms, removed)
    self.selected = nil
    self:NotifySelection()
    self:Commit()
end

function SceneLayoutEditor:SetMode(mode)
    self.mode = mode
    self.linkStart, self.stairPlacing = nil, false
    if self.callbacks.onStatus then
        local modeLabels = { select = "选择与移动", draw = "绘制房间", connect = "连接房间" }
        self.callbacks.onStatus("三维编辑模式：" .. (modeLabels[mode] or mode))
    end
end

function SceneLayoutEditor:AdjustPathWidth(delta)
    local link = self.links[self.selectedLink]
    if not link then return end
    local nextWidth = Clamp((link.width or 2) + delta, 1, 6)
    if nextWidth == link.width then return end
    link.width, link.isManual = nextWidth, true
    self:Commit()
end

function SceneLayoutEditor:SetSelectedRole(role)
    local room = self.rooms[self.selected]
    if not room then return end
    if role == "secret" then
        room.roleHint = room.roleHint == "secret" and nil or "secret"
        if room.roleHint == "secret" then
            for index = #self.links, 1, -1 do
                if self.links[index].a == self.selected or self.links[index].b == self.selected then table.remove(self.links, index) end
            end
            self.selectedLink = nil
        end
    else
        local nextValue = room.roleHint == role and nil or role
        if nextValue then
            for _, other in ipairs(self.rooms) do if other.roleHint == role then other.roleHint = nil end end
        end
        room.roleHint = nextValue
    end
    self:Commit()
end

function SceneLayoutEditor:MoveSelectedRoomFloor(delta)
    local room = self.rooms[self.selected]
    if not room then return false end
    local target = Clamp((room.floor or 0) + delta, 0, self.floorCount - 1)
    if target == room.floor then return false end
    for _, link in ipairs(self.links) do
        if link.a == self.selected or link.b == self.selected then
            local otherIndex = link.a == self.selected and link.b or link.a
            local other = self.rooms[otherIndex]
            if other and math.abs((other.floor or 0) - target) > 1 then
                if self.callbacks.onStatus then self.callbacks.onStatus("移动后会产生跨越两层以上的连接，请先删除该连接。") end
                return false
            end
        end
    end
    room.floor = target
    for _, link in ipairs(self.links) do
        if link.a == self.selected or link.b == self.selected then
            local other = self.rooms[link.a == self.selected and link.b or link.a]
            link.kind = other and other.floor ~= target and "stairs" or "corridor"
            link.bends, link.autoRoute = {}, {}
            if link.kind == "stairs" then
                link.stairSpec = link.stairSpec or { id = "stair-" .. self.nextStairId, mode = "stable-auto", width = 2, landingDepth = 2 }
                self.nextStairId = self.nextStairId + 1
            else
                link.stairSpec, link.connector = nil, nil
            end
        end
    end
    self.floor = target
    self:Commit()
    return true
end

function SceneLayoutEditor:AddRoomAt(gridX, gridY)
    self.rooms[#self.rooms + 1] = {
        cx = Snap(gridX), cy = Snap(gridY), w = 12, h = 9, floor = self.floor,
        locked = false, roleHint = nil, roomGroupId = nil,
    }
    self.selected, self.selectedLink = #self.rooms, nil
    self:NotifySelection()
    self:Commit()
end

function SceneLayoutEditor:ContextItems(kind, context)
    if kind == "blank" then return { { action = "addRoom", label = "添加区域" } } end
    if kind == "room" then
        local room = self.rooms[context.room]
        local lockLabel = room and room.locked and "解锁区域" or "锁定区域"
        return {
            { action = "deleteRoom", label = "删除区域", danger = true },
            { action = "lockRoom", label = lockLabel },
            { action = "floorUp", label = "移动到上一层" },
            { action = "floorDown", label = "移动到下一层" },
            { action = "connect", label = "连接路径到这里" },
            { action = "entrance", label = "设为/取消起点" },
            { action = "boss", label = "设为/取消终点" },
            { action = "secret", label = "设为/取消密室" },
            { action = "roomGroup", label = "赋予房间组…" },
            { action = "addStair", label = "从此区域添加楼梯" },
        }
    end
    if kind == "link" then
        if context.stair then
            local spec = self.links[context.link] and self.links[context.link].stairSpec
            return {
                { action = "rotateStair", label = "旋转楼梯 90°" },
                { action = "stairStyleL", label = "切换为 L 型楼梯" },
                { action = "stairStyleStraight", label = "切换为直梯" },
                { action = "toggleStairLock", label = spec and spec.mode == "locked" and "切换为稳定自动" or "锁定楼梯位置" },
                { action = "deleteStair", label = "删除楼梯", danger = true },
            }
        end
        return {
            { action = "addBendHere", label = "在此添加转折点" },
            { action = "straightenLink", label = "打直路径" },
            { action = "resetLink", label = "重置路径形状" },
            { action = "narrow", label = "路径变窄" },
            { action = "widen", label = "路径变宽" },
            { action = "deleteLink", label = "删除路径", danger = true },
        }
    end
    if kind == "bend" then return { { action = "deleteBend", label = "删除转折点", danger = true } } end
    if kind == "door" then return { { action = "resetDoor", label = "重置门槽点" } } end
    return {}
end

function SceneLayoutEditor:OpenContextMenu(mousePosition, logicalX, logicalY)
    if UI.IsPointerOverUI() then return end
    local world = self:ScreenToFloor(mousePosition)
    if not world then return end
    local hit, gridX, gridY = self:HitRoom(world)
    local kind, context
    local screenHandle = self:RefreshScreenGizmos(logicalX, logicalY)
    local handle = screenHandle and screenHandle.kind ~= "roomResize" and screenHandle or self:HitLinkHandle(gridX, gridY)
    if handle and self.selectedLink then
        kind = handle.kind == "bend" and "bend" or (handle.kind == "door" and "door" or "link")
        context = { link = self.selectedLink, bendIndex = handle.bendIndex, which = handle.which,
            x = gridX, y = gridY, stair = handle.kind:find("stair", 1, true) ~= nil }
    else
        local path = self:HitLink(gridX, gridY)
        if path then
            self.selected, self.selectedLink = nil, path.index
            kind, context = "link", { link = path.index, segment = path.segment, x = gridX, y = gridY, stair = path.stair == true }
        elseif hit then
            self.selected, self.selectedLink = hit, nil
            kind, context = "room", { room = hit, x = gridX, y = gridY }
            self:NotifySelection()
        else
            self.selected, self.selectedLink = nil, nil
            kind, context = "blank", { x = gridX, y = gridY }
            self:NotifySelection()
        end
    end
    self:RefreshOverlay()
    local dpr = math.max(1, graphics:GetDPR())
    self.contextMenu:Open(logicalX, logicalY, self:ContextItems(kind, context), context,
        graphics:GetWidth() / dpr, graphics:GetHeight() / dpr)
end

function SceneLayoutEditor:DeleteLinkAt(index)
    local link = self.links[index]
    if not link then return end
    table.remove(self.links, index)
    self.selectedLink = nil
    self:MarkDisconnectedRoomsSecret()
    self:Commit()
end

function SceneLayoutEditor:HandleContextAction(item, context)
    if not item or not context then return end
    local action = item.action
    if action == "addRoom" then self:AddRoomAt(context.x, context.y)
    elseif action == "deleteRoom" then self.selected = context.room; self:DeleteSelected()
    elseif action == "lockRoom" then
        local room = self.rooms[context.room]
        if room then room.locked = not room.locked; self:Commit() end
    elseif action == "floorUp" then self.selected = context.room; self:MoveSelectedRoomFloor(1)
    elseif action == "floorDown" then self.selected = context.room; self:MoveSelectedRoomFloor(-1)
    elseif action == "connect" then self.selected, self.linkStart, self.mode = context.room, context.room, "connect"; self:NotifySelection(); self:RefreshOverlay()
    elseif action == "entrance" then self.selected = context.room; self:SetSelectedRole("entrance")
    elseif action == "boss" then self.selected = context.room; self:SetSelectedRole("boss")
    elseif action == "secret" then self.selected = context.room; self:SetSelectedRole("secret")
    elseif action == "roomGroup" then
        self.selected = context.room; self:NotifySelection()
        if self.callbacks.onRoomGroupMenu then self.callbacks.onRoomGroupMenu() end
    elseif action == "addStair" then self:BeginAddStair()
    elseif action == "narrow" then self.selectedLink = context.link; self:AdjustPathWidth(-1)
    elseif action == "widen" then self.selectedLink = context.link; self:AdjustPathWidth(1)
    elseif action == "deleteLink" then self:DeleteLinkAt(context.link)
    elseif action == "straightenLink" then
        local link = self.links[context.link]
        if link then self.selectedLink = context.link; self:StraightenLink(link) end
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
    elseif action == "deleteBend" then
        local link = self.links[context.link]
        if link and link.bends and link.bends[context.bendIndex] then table.remove(link.bends, context.bendIndex); self:NormalizeLink(link); self:Commit() end
    elseif action == "resetDoor" then
        local link = self.links[context.link]
        if link then if context.which == "a" then link.doorA = nil else link.doorB = nil end; self:NormalizeLink(link); self:Commit() end
    elseif action == "rotateStair" then self.selectedLink = context.link; self:RotateSelectedStair()
    elseif action == "stairStyleL" then self.selectedLink = context.link; self:SetSelectedStairStyle("l-turn")
    elseif action == "stairStyleStraight" then self.selectedLink = context.link; self:SetSelectedStairStyle("straight")
    elseif action == "toggleStairLock" then self.selectedLink = context.link; self:ToggleSelectedStairLock()
    elseif action == "deleteStair" then self.selectedLink = context.link; self:DeleteSelectedStair()
    end
end

function SceneLayoutEditor:HandleToolbar(mx, my)
    for action, rect in pairs(self.buttons) do
        if Inside(mx, my, rect) then
            if action == "view2d" then
                if self.callbacks.onViewMode then self.callbacks.onViewMode("2d") end
            elseif action == "narrow" then
                self:AdjustPathWidth(-1)
            elseif action == "widen" then
                self:AdjustPathWidth(1)
            elseif action == "addBend" then
                self:AddBend()
            elseif action == "deletePath" then
                if self.selectedLink then self:DeleteSelected() end
            elseif action == "addStair" then
                self:BeginAddStair()
            elseif action == "rotateStair" then
                self:RotateSelectedStair()
            elseif action == "stairStyleL" then
                self:SetSelectedStairStyle("l-turn")
            elseif action == "stairStyleStraight" then
                self:SetSelectedStairStyle("straight")
            elseif action == "lockStair" then
                self:ToggleSelectedStairLock()
            elseif action == "confirmStair" then
                self:ConfirmSelectedStair()
            elseif action == "cancelStair" then
                self:CancelSelectedStair()
            elseif action == "deleteStair" then
                self:DeleteSelectedStair()
            else
                self:SetMode(action)
            end
            return true
        end
    end
    return false
end

function SceneLayoutEditor:Update(_)
    if not self.visible then return end
    local dpr = math.max(1, graphics:GetDPR())
    local mousePosition = input.mousePosition
    local logicalX, logicalY = mousePosition.x / dpr, mousePosition.y / dpr
    local altDown = input:GetKeyDown(KEY_LALT) or input:GetKeyDown(KEY_RALT)
    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    local rightDown = input:GetMouseButtonDown(MOUSEB_RIGHT)
    local rightPressed = input:GetMouseButtonPress(MOUSEB_RIGHT)
    local rightReleased = input:GetMouseButtonRelease(MOUSEB_RIGHT)
    local leftPressed, leftReleased = self.editorInteraction:Sample(leftDown,
        input:GetMouseButtonPress(MOUSEB_LEFT), input:GetMouseButtonRelease(MOUSEB_LEFT))
    self.contextMenu:UpdateHover(logicalX, logicalY)
    self:UpdateSceneHover(mousePosition)
    if not UI.IsPointerOverUI() and not self.contextMenu:IsOpen() then
        self:RefreshScreenGizmos(logicalX, logicalY)
    else
        self.hoveredGizmo = nil
    end
    self.toolbarHover = nil
    for action, rect in pairs(self.buttons) do
        if Inside(logicalX, logicalY, rect) then self.toolbarHover = action; break end
    end

    if input:GetKeyPress(KEY_ESCAPE) then
        if self.drag then self.drag = nil; self.editorInteraction:Release(); self:RefreshOverlay(); return end
        if self.contextMenu:IsOpen() then self.contextMenu:Close(); return end
        if self.stairPlacing and self:CancelSelectedStair() then return end
        local selectedLink = self.links[self.selectedLink]
        if selectedLink and selectedLink.stairSpec and selectedLink.stairSpec.pending and self:CancelSelectedStair() then return end
        if self.callbacks.onClose then self.callbacks.onClose() end
        return
    end
    if input:GetKeyPress(KEY_TAB) then
        if self.callbacks.onViewMode then self.callbacks.onViewMode("2d") end
        return
    end
    if input:GetKeyPress(KEY_DELETE) or input:GetKeyPress(KEY_BACKSPACE) then
        local selectedLink = self.links[self.selectedLink]
        if selectedLink and selectedLink.kind == "stairs" then self:DeleteSelectedStair()
        elseif selectedLink and selectedLink.bends and #selectedLink.bends > 0 then
            selectedLink.bends, selectedLink.doorA, selectedLink.doorB = {}, nil, nil
            self:Commit()
        elseif self.selected then self:DeleteSelected() end
        return
    end
    if input:GetKeyPress(KEY_L) and self.selected and self.rooms[self.selected] then
        self.rooms[self.selected].locked = not self.rooms[self.selected].locked
        self:Commit()
        return
    end

    if rightPressed then
        self.blankPanActive = false
        self.rightPress = { x = logicalX, y = logicalY, moved = false }
    end
    if self.rightPress and rightDown then
        local dx, dy = logicalX - self.rightPress.x, logicalY - self.rightPress.y
        if dx * dx + dy * dy > 16 then self.rightPress.moved = true end
    end
    if rightReleased and self.rightPress then
        local openMenu = not self.rightPress.moved
        self.rightPress = nil
        if openMenu then
            if self.stairPlacing then self:CancelSelectedStair(); return end
            self:OpenContextMenu(mousePosition, logicalX, logicalY)
            return
        end
    end

    if leftPressed and not altDown then
        self.blankPanActive = false
        self.blankPanPressBlocked = false
        -- A missed release must never poison the next edit. Finalize any stale
        -- gesture before resolving this press into a new room/path/stair drag.
        if self.drag or self.draw or self.editorInteraction:IsCaptured() then
            EditorGesture.Finish(self, nil)
        end
        if self.contextMenu:IsOpen() then
            local context = self.contextMenu.context
            local item, consumed = self.contextMenu:Hit(logicalX, logicalY)
            if item then self:HandleContextAction(item, context) end
            if consumed or item then self.blankPanPressBlocked = true; return end
        end
        if self:HandleToolbar(logicalX, logicalY) then self.blankPanPressBlocked = true; return end
        if UI.IsPointerOverUI() then self.blankPanPressBlocked = true; return end
        local world = self:ScreenToFloor(mousePosition)
        if not world then self.blankPanPressBlocked = true; return end
        local hit, gridX, gridY = self:HitRoom(world)
        if self.stairPlacing then
            if hit then self:PlaceStairAt(hit, gridX, gridY)
            elseif self.callbacks.onStatus then self.callbacks.onStatus("请在当前层的区域内部点击放置楼梯。") end
            self.blankPanPressBlocked = true
            return
        end
        if self.mode == "select" then
            local screenHandle = self.hoveredGizmo
            local roomHandle = screenHandle and screenHandle.kind == "roomResize" and screenHandle.mode or nil
            local linkHandle = screenHandle and screenHandle.kind ~= "roomResize" and screenHandle or nil
            if not roomHandle and not linkHandle then
                roomHandle = self:HitRoomHandle(gridX, gridY)
                linkHandle = not roomHandle and self:HitLinkHandle(gridX, gridY) or nil
            end
            local path = not roomHandle and not linkHandle and self:HitLink(gridX, gridY) or nil
            if roomHandle and self.selected then
                local room = self.rooms[self.selected]
                local stairEdit = self:CaptureRoomStairEdit(self.selected)
                self.drag = { kind = "roomResize", index = self.selected, mode = roomHandle,
                    start = { cx = room.cx, cy = room.cy, w = room.w, h = room.h },
                    adaptive = self:CaptureAdaptiveRoutes(stairEdit.pair and nil or self.selected), stairEdit = stairEdit }
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
                self.selected, self.selectedLink = nil, path.index
                self:NotifySelection()
                local link = self.links[path.index]
                if path.stair then
                    local stair = self:CaptureStairDrag(path.index)
                    local anchor = stair and (stair.spec.previewAnchor or stair.spec.anchor or stair.connector.lower)
                    if stair and anchor then self.drag = { kind = "stairMove", link = path.index,
                        startX = gridX, startY = gridY, anchor = CopyPoint(anchor), stair = stair,
                        lastDX = 0, lastDY = 0 } end
                else
                    self.drag = { kind = "linkSegment", link = path.index, segment = path.segment,
                        startX = gridX, startY = gridY, pending = true }
                end
                self:RefreshSelectionMaterials()
            elseif hit then
                self.selected, self.selectedLink = hit, nil
                self:NotifySelection()
                local room = self.rooms[hit]
                local stairEdit = self:CaptureRoomStairEdit(hit)
                self.drag = { kind = "roomMove", index = hit,
                    startX = gridX, startY = gridY,
                    start = { cx = room.cx, cy = room.cy },
                    adaptive = self:CaptureAdaptiveRoutes(stairEdit.pair and nil or hit), stairEdit = stairEdit }
            else
                self.selected, self.selectedLink = nil, nil
                self.blankPanActive = true
                self:NotifySelection()
                self:RefreshOverlay()
            end
        elseif self.mode == "draw" and not hit then
            self.draw = { gx = gridX, gy = gridY, ex = gridX, ey = gridY }
            self:UpdateDrawPreview()
        elseif self.mode == "connect" and hit then
            if self.linkStart and self.linkStart ~= hit then
                local startRoom, targetRoom = self.rooms[self.linkStart], self.rooms[hit]
                local floorDifference = math.abs((startRoom.floor or 0) - (targetRoom.floor or 0))
                if floorDifference > 0 then
                    if self.callbacks.onStatus then self.callbacks.onStatus(floorDifference == 1
                        and "跨层连接请使用“楼梯”，普通连接只用于同层路径。"
                        or "不能跨越两层以上直接连接。") end
                    self.linkStart = nil
                    return
                end
                local existingIndex = EditorData.FindLink(self.links, self.linkStart, hit)
                if not existingIndex then
                    self.links[#self.links + 1] = {
                        a = self.linkStart, b = hit, isLoop = true, isManual = true,
                        width = 2, bends = {}, autoRoute = {},
                    }
                end
                self.selected, self.selectedLink, self.linkStart = nil, existingIndex or #self.links, nil
                self:NotifySelection()
                self:NormalizeConnectedSecretRooms()
                self:Commit()
            else
                self.linkStart, self.selected, self.selectedLink = hit, hit, nil
                self:NotifySelection()
                self:RefreshOverlay()
            end
            else
                self.selected, self.selectedLink = hit, nil
                self:NotifySelection()
                self:RefreshOverlay()
            end
            if self.drag or self.draw then self.editorInteraction:Capture() end
    end

    if leftDown and not altDown and self.mode == "select" and not self.blankPanActive
        and not self.blankPanPressBlocked and not self.drag and not self.draw
        and not self.editorInteraction:IsCaptured() and not UI.IsPointerOverUI()
        and not self.contextMenu:IsOpen() then
        local world = self:ScreenToFloor(mousePosition)
        if world then
            local hit, gridX, gridY = self:HitRoom(world)
            local handle = self.hoveredGizmo or self:HitRoomHandle(gridX, gridY) or self:HitLinkHandle(gridX, gridY)
            local path = not handle and self:HitLink(gridX, gridY) or nil
            if not hit and not handle and not path then self.blankPanActive = true end
        end
    end

    if leftDown and not altDown
        and (self.editorInteraction:IsCaptured() or not UI.IsPointerOverUI()) then
        local world = self:ScreenToFloor(mousePosition)
        if world then
            local gridX, gridY = self:WorldToGrid(world)
            if self.drag then
                EditorGesture.Apply(self, gridX, gridY)
            elseif self.draw then
                EditorGesture.UpdateDraw(self, gridX, gridY)
            end
        end
    end

    if leftReleased then
        EditorGesture.Finish(self, mousePosition)
        self.blankPanActive, self.blankPanPressBlocked = false, false
    end
end

function SceneLayoutEditor:RenderButton(action, label, x, y, width, active)
    local rect = { x = x, y = y, w = width, h = 30 }
    self.buttons[action] = rect
    local hovered = self.toolbarHover == action
    local pressed = hovered and input:GetMouseButtonDown(MOUSEB_LEFT)
    RoundedRect(self.vg, x, y, width, 30, 5,
        active and { 179, 100, 38, 255 }
            or (pressed and { 64, 75, 96, 255 } or (hovered and { 42, 51, 70, 255 } or { 27, 34, 48, 245 })))
    nvgFontSize(self.vg, 11)
    Fill(self.vg, active and 255 or 191, active and 237 or 199, active and 214 or 213, 255)
    nvgText(self.vg, x + 10, y + 15, label, nil)
end

function SceneLayoutEditor:Render()
    if not self.visible or not self.vg then return end
    local dpr = math.max(1, graphics:GetDPR())
    local width, height = graphics:GetWidth() / dpr, graphics:GetHeight() / dpr
    local panelWidth, panelHeight = math.min(470, width - 330), 178
    local panelX, panelY = width - panelWidth - 18, 18

    nvgBeginFrame(self.vg, width, height, dpr)
    self.editorViewport:Update()
    EditorGizmos.Render(self, self.vg, self.editorViewport, self.gizmoDescriptors)
    RoundedRect(self.vg, panelX, panelY, panelWidth, panelHeight, 9, { 8, 11, 18, 238 })
    nvgFontFace(self.vg, "forge3d")
    nvgTextAlign(self.vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFontSize(self.vg, 14)
    Fill(self.vg, 232, 235, 242, 255)
    nvgText(self.vg, panelX + 14, panelY + 18, "布局编辑器", nil)
    nvgFontSize(self.vg, 9)
    Fill(self.vg, 135, 145, 164, 255)
    nvgText(self.vg, panelX + 104, panelY + 18,
        "WASD/方向键：移动相机  |  Shift：加速  |  滚轮：缩放", nil)

    self.buttons = {}
    local x, y = panelX + 14, panelY + 40
    self:RenderButton("select", "选择 / 移动", x, y, 102, self.mode == "select")
    x = x + 109
    self:RenderButton("draw", "绘制房间", x, y, 88, self.mode == "draw")
    x = x + 95
    self:RenderButton("connect", "连接房间", x, y, 78, self.mode == "connect")
    x = x + 85
    self:RenderButton("view2d", "二维平面", x, y, 72, false)
    x = x + 79
    self:RenderButton("addStair", "＋ 楼梯", x, y, 64, self.stairPlacing)

    nvgFontSize(self.vg, 9)
    Fill(self.vg, 138, 149, 168, 255)
    local modeHints = {
        select = "选择：鼠标左键拖拽房间/控制点；在空白处拖拽可平移画面",
        draw = "绘制：在空白处按住鼠标左键，拖出一个新房间",
        connect = "连接：使用鼠标左键依次点击两个房间",
    }
    nvgText(self.vg, panelX + 14, panelY + 87, modeHints[self.mode] or "", nil)
    nvgText(self.vg, panelX + 14, panelY + 104,
        "透视相机：空白/Alt+左键或中键平移 · 右键拖拽旋转 · 右键单击菜单  |  Tab：二维", nil)

    local selectedRoom = self.rooms[self.selected]
    local selectedStair = self.links[self.selectedLink]
    local selectedSpec = selectedStair and selectedStair.kind == "stairs" and selectedStair.stairSpec or nil
    local selectedText = selectedSpec and ("楼梯 · "
        .. ((selectedSpec.previewStyle or selectedSpec.style) == "straight" and "直梯" or "L 型")
        .. " · 宽 " .. tostring(selectedSpec.previewWidth or selectedSpec.width or 2)
        .. (selectedSpec.pending and " · 待确认" or (selectedSpec.mode == "locked" and " · 已锁定" or " · 稳定自动")))
        or (self.selected and ("房间 #" .. self.selected
            .. (selectedRoom and selectedRoom.roleHint and (" · " .. selectedRoom.roleHint) or "")) or "未选择房间")
    nvgText(self.vg, panelX + 14, panelY + 121,
        selectedText .. "  |  L：锁定/解锁  |  Delete/Backspace：删除  |  第 " .. (self.floor + 1) .. " 层", nil)
    if self.selectedLink and self.links[self.selectedLink] then
        local link = self.links[self.selectedLink]
        x, y = panelX + 14, panelY + 137
        if link.kind == "stairs" then
            local spec = link.stairSpec or {}
            local style = spec.previewStyle or spec.style or "l-turn"
            self:RenderButton("stairStyleL", "L 型", x, y, 52, style == "l-turn"); x = x + 59
            self:RenderButton("stairStyleStraight", "直梯", x, y, 52, style == "straight"); x = x + 59
            self:RenderButton("rotateStair", "旋转 90°", x, y, 68, false); x = x + 75
            self:RenderButton("lockStair", spec.mode == "locked" and "稳定自动" or "锁定位置", x, y, 78, false); x = x + 85
            if spec.pending then
                self:RenderButton("confirmStair", "确认楼梯", x, y, 78, false); x = x + 85
                self:RenderButton("cancelStair", "取消", x, y, 58, false)
            else
                self:RenderButton("deleteStair", "删除楼梯", x, y, 78, false)
            end
        else
            self:RenderButton("narrow", "Width -", x, y, 70, false)
            x = x + 77
            self:RenderButton("widen", "Width +", x, y, 70, false)
            x = x + 77
            self:RenderButton("addBend", "Add Bend", x, y, 82, false)
            x = x + 89
            self:RenderButton("deletePath", "Delete Path", x, y, 92, false)
            nvgFontSize(self.vg, 9)
            Fill(self.vg, 218, 166, 95, 255)
            nvgText(self.vg, panelX + panelWidth - 62, panelY + 152, "W " .. (link.width or 2), nil)
        end
    elseif self.stairPlacing then
        x, y = panelX + 14, panelY + 137
        self:RenderButton("stairStyleL", "L 型", x, y, 72, self.stairPlacementStyle == "l-turn"); x = x + 79
        self:RenderButton("stairStyleStraight", "直梯", x, y, 72, self.stairPlacementStyle == "straight")
    end
    self.contextMenu:Render(self.vg)
    nvgEndFrame(self.vg)
end

function SceneLayoutEditor:Dispose()
    self.editorInteraction:Release()
    self:ClearOverlay()
    if self.vg then
        nvgDelete(self.vg)
        self.vg = nil
    end
end

PathWorkflow.Install(SceneLayoutEditor, { CopyLink = CopyLink })
StairWorkflow.Install(SceneLayoutEditor, { CopyRooms = CopyRooms, CopyLink = CopyLink })

return SceneLayoutEditor
