local DungeonApp = require("App.DungeonApp")
local StairEditing = require("UI.Editor.StairEditing")
local EditorGesture = require("UI.Editor.EditorGesture")
local RoomEditing = require("UI.Editor.RoomEditing")

---@type table|nil
local app = nil
local elapsed = 0
local configured = false
local hoveredRoomProof = nil
local screenshotPath = ".tmp/editor-integration.png"

for _, argument in ipairs(GetArguments()) do
    local configuredPath = argument:match("^%-smoke_output=(.+)$")
    if configuredPath then screenshotPath = configuredPath; break end
end

local function WriteResult(message)
    ---@type File|nil
    local result = File(screenshotPath .. ".result.txt", FILE_WRITE)
    if not result then return false end
    if result:IsOpen() then result:WriteLine(message); result:Close(); return true end
    return false
end

local function Fail(message)
    UnsubscribeFromEvent("Update")
    WriteResult("FAIL " .. tostring(message))
    ErrorExit("[editor-integration] FAIL\n" .. tostring(message), 1)
end

local function SamePoint(a, b)
    return a and b and math.abs(a.x - b.x) < 0.0001 and math.abs(a.y - b.y) < 0.0001
end

local function VerifyConnectedRoutes(editor, roomIndex, cycle)
    for linkIndex, link in ipairs(editor.links) do
        if link.kind ~= "stairs" and (link.a == roomIndex or link.b == roomIndex) then
            local startPoint, endPoint = editor:LinkEndpoints(link)
            local route = editor:LinkRoute(link)
            if startPoint and endPoint then
                if not SamePoint(route[1], startPoint) or not SamePoint(route[#route], endPoint) then
                    Fail(string.format("path %d did not follow moved room on cycle %d", linkIndex, cycle))
                    return false
                end
                for segment = 1, #route - 1 do
                    local a, b = route[segment], route[segment + 1]
                    if math.abs(a.x - b.x) > 0.0001 and math.abs(a.y - b.y) > 0.0001 then
                        Fail(string.format("path %d became diagonal at segment %d on cycle %d",
                            linkIndex, segment, cycle))
                        return false
                    end
                end
            end
        end
    end
    return true
end

local function StairNodeCount(editor, linkIndex)
    local count = 0
    for _, entry in ipairs(editor.linkNodes or {}) do
        if entry.stair and entry.link == linkIndex then count = count + 1 end
    end
    return count
end

local function RouteSignature(route)
    local parts = {}
    for _, point in ipairs(route or {}) do
        parts[#parts + 1] = string.format("%.4f,%.4f", point.x or 0, point.y or 0)
    end
    return table.concat(parts, "|")
end

local function RouteIsOrthogonal(route)
    for index = 1, #(route or {}) - 1 do
        local a, b = route[index], route[index + 1]
        if math.abs(a.x - b.x) > 0.0001 and math.abs(a.y - b.y) > 0.0001 then return false end
    end
    return true
end

local function RunPathSelectionProof(editor, pathIndex)
    local link = editor.links[pathIndex]
    local route = editor:DisplayLinkRoute(link)
    if #route < 2 then Fail("selection proof path has no visible segment"); return false end
    local before = RouteSignature(route)
    local bendsBefore, autoBefore = #(link.bends or {}), #(link.autoRoute or {})
    local a, b = route[1], route[2]
    local startX, startY = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5
    editor.selected, editor.selectedLink = nil, pathIndex
    editor.drag = { kind = "linkSegment", link = pathIndex, segment = 1,
        startX = startX, startY = startY, pending = true }
    editor.editorInteraction:Capture()
    if EditorGesture.Apply(editor, startX, startY) then
        Fail("selecting a real path was treated as movement"); return false
    end
    if not EditorGesture.Finish(editor) then Fail("path selection did not release"); return false end
    link = editor.links[pathIndex]
    if RouteSignature(editor:DisplayLinkRoute(link)) ~= before
        or #(link.bends or {}) ~= bendsBefore or #(link.autoRoute or {}) ~= autoBefore then
        Fail("real path moved or changed data when selected"); return false
    end
    print("[editor-integration] path selection stability PASS")
    return true
end

local function RunDiscreteStairProof(editor, stairIndex)
    editor.selected, editor.selectedLink = nil, stairIndex
    local link = editor.links[stairIndex]
    local originalDirection = link.stairSpec.previewDirection or link.stairSpec.direction
    if not editor:RotateSelectedStair() then Fail("discrete stair rotation failed"); return false end
    link = editor.links[stairIndex]
    if (link.stairSpec.previewDirection or link.stairSpec.direction) == originalDirection
        or StairNodeCount(editor, stairIndex) ~= (link.connector.turn and 3 or 1) then
        Fail("stair rotation changed data but did not refresh live geometry"); return false
    end
    if not editor:SetSelectedStairStyle("straight") then Fail("straight stair style failed"); return false end
    link = editor.links[stairIndex]
    if link.connector.turn or StairNodeCount(editor, stairIndex) ~= 1 then
        Fail("straight stair style left stale L geometry"); return false
    end
    if not editor:SetSelectedStairStyle("l-turn") then Fail("L stair style failed"); return false end
    link = editor.links[stairIndex]
    if not link.connector.turn or StairNodeCount(editor, stairIndex) ~= 3 then
        Fail("L stair style did not rebuild both live flights and turn platform"); return false
    end

    local targetWidth = 4
    local segments = StairEditing.VisualSegments(link.connector)
    local startPoint, finishPoint = segments[1].start, segments[1].finish
    local dx, dy = finishPoint.x - startPoint.x, finishPoint.y - startPoint.y
    local length = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    local centerX, centerY = (startPoint.x + finishPoint.x) * 0.5, (startPoint.y + finishPoint.y) * 0.5
    local pointerX = centerX - dy / length * (targetWidth * 0.5 + 1)
    local pointerY = centerY + dx / length * (targetWidth * 0.5 + 1)
    local stairDrag = editor:CaptureStairDrag(stairIndex)
    editor.drag = { kind = "stairWidth", link = stairIndex, stair = stairDrag,
        lastWidth = link.stairSpec.previewWidth or link.stairSpec.width }
    editor.editorInteraction:Capture()
    if not EditorGesture.Apply(editor, pointerX, pointerY) or not EditorGesture.Finish(editor) then
        Fail("stair width drag lifecycle failed"); return false
    end
    link = editor.links[stairIndex]
    local width = link.stairSpec.previewWidth or link.stairSpec.width
    if math.abs(width - targetWidth) > 0.001 or StairNodeCount(editor, stairIndex) ~= 3 then
        Fail("stair width edit did not survive geometry refresh"); return false
    end

    app:Generate(true, false)
    if not app.dungeon or not app.dungeon.valid then
        Fail("dungeon became invalid after stair edits"); return false
    end
    local rebuilt = editor.links[stairIndex]
    if not rebuilt or not rebuilt.connector or not rebuilt.stairSpec or rebuilt.stairSpec.invalid then
        Fail("edited stair did not survive editor-state regeneration"); return false
    end
    print("[editor-integration] discrete stair edit + regeneration PASS")
    return true
end

local function RunRepeatedEditProof(editor, roomIndex, stairIndex)
    local room = editor.rooms[roomIndex]
    for cycle = 1, 8 do
        local startX, delta = room.cx, cycle % 2 == 0 and -1 or 1
        local stairEdit = editor:CaptureRoomStairEdit(roomIndex)
        editor.drag = {
            kind = "roomMove", index = roomIndex, startX = room.cx, startY = room.cy,
            start = { cx = room.cx, cy = room.cy },
            adaptive = editor:CaptureAdaptiveRoutes(stairEdit.pair and nil or roomIndex),
            stairEdit = stairEdit,
        }
        editor.editorInteraction:Capture()
        if not EditorGesture.Apply(editor, room.cx + delta, room.cy) or room.cx ~= startX + delta then
            Fail("real room drag failed on cycle " .. cycle); return false
        end
        if not VerifyConnectedRoutes(editor, roomIndex, cycle) then return false end
        if not EditorGesture.Finish(editor) or editor.drag or editor.editorInteraction:IsCaptured() then
            Fail("real room drag did not release on cycle " .. cycle); return false
        end
    end

    local original = { cx = room.cx, cy = room.cy, w = room.w, h = room.h }
    local initialStairEdit = editor:CaptureRoomStairEdit(roomIndex)
    local pairIndex = initialStairEdit.pair
    local pair = pairIndex and editor.rooms[pairIndex] or nil
    local originalPair = pair and { cx = pair.cx, cy = pair.cy, w = pair.w, h = pair.h } or nil
    room.w = room.w % 2 == 0 and room.w + 1 or room.w
    room.h = room.h % 2 == 0 and room.h + 1 or room.h
    editor:UpdateRoomVisual(roomIndex)
    local resizeBase = { cx = room.cx, cy = room.cy, w = room.w, h = room.h }
    if pair then
        pair.cx, pair.cy, pair.w, pair.h = resizeBase.cx, resizeBase.cy, resizeBase.w, resizeBase.h
        editor:UpdateRoomVisual(pairIndex)
    end
    local modes = { "resize-nw", "resize-ne", "resize-sw", "resize-se" }
    for cycle = 1, 8 do
        local mode = modes[(cycle - 1) % #modes + 1]
        local direction = mode:match("^resize%-(.+)$") or mode
        local west = direction:find("w", 1, true) ~= nil
        local north = direction:find("n", 1, true) ~= nil
        local corner = {
            x = resizeBase.cx + (west and -resizeBase.w or resizeBase.w) * 0.5,
            y = resizeBase.cy + (north and -resizeBase.h or resizeBase.h) * 0.5,
        }
        local stairEdit = editor:CaptureRoomStairEdit(roomIndex)
        editor.drag = { kind = "roomResize", index = roomIndex, mode = mode,
            start = { cx = resizeBase.cx, cy = resizeBase.cy, w = resizeBase.w, h = resizeBase.h },
            adaptive = editor:CaptureAdaptiveRoutes(stairEdit.pair and nil or roomIndex), stairEdit = stairEdit }
        editor.editorInteraction:Capture()
        if EditorGesture.Apply(editor, corner.x, corner.y) then
            Fail(string.format("real %s changed geometry on press cycle %d start=(%.3f,%.3f %.3fx%.3f) corner=(%.3f,%.3f) result=(%.3f,%.3f %.3fx%.3f)",
                mode, cycle, resizeBase.cx, resizeBase.cy, resizeBase.w, resizeBase.h,
                corner.x, corner.y, room.cx, room.cy, room.w, room.h)); return false
        end
        local pointer = { x = corner.x + (west and -1.2 or 1.2),
            y = corner.y + (north and -1.2 or 1.2) }
        local expected = RoomEditing.Resize(resizeBase, pointer, mode)
        if not EditorGesture.Apply(editor, pointer.x, pointer.y)
            or room.cx ~= expected.cx or room.cy ~= expected.cy
            or room.w ~= expected.w or room.h ~= expected.h then
            Fail("real " .. mode .. " did not follow pointer cycle " .. cycle); return false
        end
        if not EditorGesture.Finish(editor) or editor.drag or editor.editorInteraction:IsCaptured() then
            Fail("real " .. mode .. " did not release cycle " .. cycle); return false
        end
        room.cx, room.cy, room.w, room.h = resizeBase.cx, resizeBase.cy, resizeBase.w, resizeBase.h
        editor:UpdateRoomVisual(roomIndex)
        if stairEdit.pair and editor.rooms[stairEdit.pair] then
            local pair = editor.rooms[stairEdit.pair]
            pair.cx, pair.cy, pair.w, pair.h = resizeBase.cx, resizeBase.cy, resizeBase.w, resizeBase.h
            editor:UpdateRoomVisual(stairEdit.pair)
        end
    end
    room.cx, room.cy, room.w, room.h = original.cx, original.cy, original.w, original.h
    editor:UpdateRoomVisual(roomIndex)
    if pair and originalPair then
        pair.cx, pair.cy, pair.w, pair.h = originalPair.cx, originalPair.cy, originalPair.w, originalPair.h
        editor:UpdateRoomVisual(pairIndex)
    end

    local pathIndex = nil
    for index, link in ipairs(editor.links) do
        local roomA, roomB = editor.rooms[link.a], editor.rooms[link.b]
        if link.kind ~= "stairs" and roomA and roomB
            and roomA.floor == editor.floor and roomB.floor == editor.floor then
            pathIndex = index
            break
        end
    end
    if not pathIndex then Fail("generated dungeon has no editable current-floor path"); return false end
    local path = editor.links[pathIndex]
    for cycle = 1, 8 do
        local route = editor:EnsureEditableRoute(path)
        if #route < 2 then Fail("real path has no editable segment"); return false end
        local segment = #route >= 3 and 2 or 1
        local a, b = route[segment], route[segment + 1]
        local startX, startY = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5
        local horizontal = math.abs(b.x - a.x) >= math.abs(b.y - a.y)
        local delta = cycle % 2 == 0 and -4 or 4
        editor.drag = {
            kind = "linkSegment", link = pathIndex, segment = segment,
            startX = startX, startY = startY, route = route,
            snapTargets = editor:ControlSnapTargets({ a, b }),
        }
        editor.editorInteraction:Capture()
        local targetX, targetY = horizontal and startX or startX + delta,
            horizontal and startY + delta or startY
        if not EditorGesture.Apply(editor, targetX, targetY) then
            Fail("real path drag failed on cycle " .. cycle); return false
        end
        if not EditorGesture.Finish(editor) or editor.drag or editor.editorInteraction:IsCaptured() then
            Fail("real path drag did not release on cycle " .. cycle); return false
        end
    end

    for cycle = 1, 8 do
        local stair = editor:CaptureStairDrag(stairIndex)
        if not stair then Fail("real stair could not start drag on cycle " .. cycle); return false end
        local anchor = stair.spec.previewAnchor or stair.spec.anchor or stair.connector.lower
        local delta = cycle % 2 == 0 and -1 or 1
        editor.drag = {
            kind = "stairMove", link = stairIndex, startX = 0, startY = 0,
            anchor = { x = anchor.x, y = anchor.y }, stair = stair,
            lastDX = 0, lastDY = 0,
        }
        editor.editorInteraction:Capture()
        if not EditorGesture.Apply(editor, delta, 0) then
            Fail("real stair drag failed on cycle " .. cycle); return false
        end
        if not EditorGesture.Finish(editor) or editor.drag or editor.editorInteraction:IsCaptured() then
            Fail("real stair drag did not release on cycle " .. cycle); return false
        end
    end
    print(string.format("[editor-integration] repeated edits PASS room=8 resize=8 path=8 stair=8 pathIndex=%d", pathIndex))
    return true
end

local function ConfigureEditorProof()
    local editor = app and app.editor3D
    if not editor or not editor:IsVisible() then return false end
    local stairIndex, pathIndex = nil, nil
    for index, link in ipairs(editor.links) do
        if link.kind == "stairs" and link.connector then stairIndex = index; break end
    end
    for index, link in ipairs(editor.links) do
        local roomA, roomB = editor.rooms[link.a], editor.rooms[link.b]
        if link.kind ~= "stairs" and roomA and roomB and roomA.floor == editor.floor and roomB.floor == editor.floor then
            pathIndex = index
            break
        end
    end
    if not stairIndex then Fail("generated dungeon has no realized stair connector"); return true end
    if not pathIndex then Fail("generated dungeon has no editable current-floor path"); return true end
    local stair = editor.links[stairIndex]
    if not stair.connector or not stair.stairSpec then
        Fail("generated stair was not synchronized as an editable contract")
        return true
    end

    local roomItems = editor:ContextItems("room", { room = 1 })
    local stairItems = editor:ContextItems("link", { link = stairIndex, stair = true })
    local pathItems = editor:ContextItems("link", { link = pathIndex, stair = false })
    local straightenItem = nil
    for _, item in ipairs(pathItems) do
        if item.action == "straightenLink" then straightenItem = item; break end
    end
    if #roomItems < 9 or #stairItems < 3 then
        Fail(string.format("context menus incomplete room=%d stair=%d", #roomItems, #stairItems))
        return true
    end
    if not straightenItem then Fail("path context menu is missing straighten path"); return true end

    editor.selected, editor.selectedLink = nil, stairIndex
    editor:RefreshOverlay()
    local dpr = math.max(1, graphics:GetDPR())
    local logicalWidth, logicalHeight = graphics:GetWidth() / dpr, graphics:GetHeight() / dpr
    local hoveredRoom = nil
    for index, room in ipairs(editor.rooms) do
        if room.floor == editor.floor then
            local world = editor:RoomWorldPosition(room, 0.22)
            local roundTripX, roundTripY = editor:WorldToGrid(world)
            local roomNode = editor.roomNodes[index] and editor.roomNodes[index].node
            local expectedX = room.cx - editor.dungeonWidth * 0.5 + 0.5
            local expectedZ = room.cy - editor.dungeonHeight * 0.5 + 0.5
            if math.abs(roundTripX - room.cx) > 0.0001 or math.abs(roundTripY - room.cy) > 0.0001
                or not roomNode or math.abs(roomNode.position.x - expectedX) > 0.0001
                or math.abs(roomNode.position.z - expectedZ) > 0.0001 then
                Fail("editor overlay does not match the renderer half-cell coordinate contract")
                return true
            end
            local screen = app.camera:WorldToScreenPoint(editor:RoomWorldPosition(room, 0.22))
            if screen.x > 0.18 and screen.x < 0.72 and screen.y > 0.15 and screen.y < 0.85 then
                local physical = IntVector2(math.floor(screen.x * graphics:GetWidth() + 0.5),
                    math.floor(screen.y * graphics:GetHeight() + 0.5))
                input:SetMousePosition(physical)
                editor:UpdateSceneHover(physical)
                if editor.hoveredRoom == index then hoveredRoom = index; break end
            end
        end
    end
    if not hoveredRoom then Fail("screen ray did not hover any current-floor room"); return true end
    hoveredRoomProof = hoveredRoom
    if not RunPathSelectionProof(editor, pathIndex) then return true end
    if not RunRepeatedEditProof(editor, hoveredRoom, stairIndex) then return true end
    editor:HandleContextAction(straightenItem, { link = pathIndex })
    local straightened = editor.links[pathIndex]
    if not straightened or not straightened.isManual
        or #(straightened.autoRoute or {}) > 0 then
        Fail("path context straighten action did not author the whole route")
        return true
    end
    if not RouteIsOrthogonal(editor:DisplayLinkRoute(straightened)) then
        Fail("path context straighten action left a diagonal segment")
        return true
    end
    if not RunDiscreteStairProof(editor, stairIndex) then return true end
    local rebuiltPath = editor.links[pathIndex]
    if not rebuiltPath or not RouteIsOrthogonal(editor:DisplayLinkRoute(rebuiltPath)) then
        Fail("straightened path lost horizontal/vertical alignment after dungeon regeneration")
        return true
    end

    local menuX, menuY = logicalWidth * 0.5, logicalHeight * 0.32
    editor.contextMenu:Open(menuX, menuY, stairItems,
        { link = stairIndex, stair = true }, logicalWidth, logicalHeight)
    local firstRect = editor.contextMenu.rects[1]
    editor.contextMenu:UpdateHover(firstRect.x + 4, firstRect.y + 4)
    local hitItem, consumed = editor.contextMenu:Hit(firstRect.x + 4, firstRect.y + 4)
    if not consumed or not hitItem or hitItem.action ~= "rotateStair" then
        Fail("logical-coordinate context menu hit test failed")
        return true
    end
    editor.contextMenu:Open(menuX, menuY, stairItems,
        { link = stairIndex, stair = true }, logicalWidth, logicalHeight)
    configured = true
    print(string.format("[editor-integration] configured stair=%d mode=%s hoverRoom=%d roomMenu=%d stairMenu=%d dpr=%.2f",
        stairIndex, tostring(stair.stairSpec.mode), hoveredRoom, #roomItems, #stairItems, dpr))
    return true
end

function Start()
    local ok, message = xpcall(function()
        app = DungeonApp.new()
        -- Use one of the deterministic multi-floor validation seeds so this UI
        -- test exercises a realized stair instead of a generator failure case.
        app.seed = 15838
        app.floorCount = 3
        app.roomCounts = { 10, 10, 10 }
        app.loopRates = { 12, 16, 20 }
        app:Start()
        app:ToggleEditor(true)
        SubscribeToEvent("Update", "HandleEditorIntegrationUpdate")
    end, debug.traceback)
    if not ok then Fail(message) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleEditorIntegrationUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if not configured then ConfigureEditorProof() end
    if configured and elapsed >= 2.0 then
        local screenshot = Image()
        if not graphics:TakeScreenShot(screenshot) or not screenshot:SavePNG(screenshotPath) then
            Fail("screenshot capture failed")
            return
        end
        local editor = app.editor3D
        local stair = editor.links[editor.selectedLink]
        WriteResult(string.format("PASS editorVisible=%s stairEditable=%s contextOpen=%s hoverRoom=%s rooms=%d links=%d",
            tostring(editor:IsVisible()), tostring(stair and stair.stairSpec ~= nil),
            tostring(editor.contextMenu:IsOpen()), tostring(hoveredRoomProof), #editor.rooms, #editor.links))
        print("[editor-integration] PASS 3D editor, generated stair contract, context menu, and screenshot")
        UnsubscribeFromEvent("Update")
        engine:Exit()
    elseif elapsed > 12 then
        Fail("editor transition did not complete within 12 seconds")
    end
end

function Stop()
    if app then app:Stop(); app = nil end
end
