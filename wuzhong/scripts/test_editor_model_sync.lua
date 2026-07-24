local DungeonApp = require("App.DungeonApp")
local UI = require("urhox-libs/UI")

---@type table|nil
local app = nil
local state = "enter"
local elapsed = 0
local roomProof, pathProof = nil, nil
local resultPath = "D:/Maker/PCG/Maker-procedural-dungeon1.0/.tmp/editor-model-sync.result.txt"

local function WriteResult(message)
    ---@type File|nil
    local result = File(resultPath, FILE_WRITE)
    if not result or not result:IsOpen() then return false end
    result:WriteLine(message)
    result:Close()
    return true
end

local function Fail(message)
    WriteResult("FAIL " .. tostring(message))
    ErrorExit("[editor-model-sync] FAIL\n" .. tostring(message), 1)
end

local function LinkKey(link)
    return math.min(link.a, link.b) .. ":" .. math.max(link.a, link.b)
end

local function FindLink(links, key)
    for index, link in ipairs(links or {}) do
        if LinkKey(link) == key then return index, link end
    end
    return nil, nil
end

local function AssertEditorReady(label)
    local editor = app.editor3D
    if not editor:IsVisible() or not editor.overlayRoot then
        Fail(label .. " editor or overlay is not visible after rebuild"); return false
    end
    if editor.drag or editor.draw or editor.editorInteraction:IsCaptured() then
        Fail(label .. " retained stale gesture capture after rebuild"); return false
    end
    local pressed = editor.editorInteraction:Sample(true, true, false)
    local _, released = editor.editorInteraction:Sample(false, false, true)
    editor.editorInteraction:Reset(false)
    if not pressed or not released then
        Fail(label .. " next pointer press/release was swallowed after rebuild"); return false
    end
    return true
end

local function AssertExactTopView(editor)
    if not app.camera.orthographic or not app.forgeCamera:IsEditViewActive() then
        Fail("3D editor did not enter orthographic edit view"); return false
    end
    local centerRay = app.camera:GetScreenRay(0.5, 0.5)
    if math.abs(centerRay.direction.x) > 0.0001
        or math.abs(centerRay.direction.y + 1) > 0.0001
        or math.abs(centerRay.direction.z) > 0.0001 then
        Fail(string.format("3D editor camera is not exact top-down direction=(%.5f,%.5f,%.5f)",
            centerRay.direction.x, centerRay.direction.y, centerRay.direction.z))
        return false
    end
    local width, height = graphics:GetWidth(), graphics:GetHeight()
    local center = editor:ScreenToFloor(IntVector2(math.floor(width * 0.5), math.floor(height * 0.5)))
    local top = editor:ScreenToFloor(IntVector2(math.floor(width * 0.5), math.floor(height * 0.25)))
    if not center or not top or top.z >= center.z then
        Fail("3D editor top view screen-up is not aligned to world -Z"); return false
    end
    return true
end

local function AssertTopViewMouseControls()
    local controller = app.forgeCamera
    local originalInput, originalPointerCheck = input, UI.IsPointerOverUI
    local savedTarget = Vector3(controller.target.x, controller.target.y, controller.target.z)
    local savedSize = app.camera.orthoSize
    local fake = {
        mousePosition = IntVector2(math.floor(graphics:GetWidth() * 0.5), math.floor(graphics:GetHeight() * 0.5)),
        mouseMove = IntVector2(0, 0), mouseMoveWheel = 1,
        left = false, middle = false, right = false,
    }
    function fake:GetMouseButtonDown(button)
        return button == MOUSEB_LEFT and self.left
            or button == MOUSEB_MIDDLE and self.middle
            or button == MOUSEB_RIGHT and self.right
    end
    function fake:GetKeyDown(_) return false end
    function fake:GetScancodeDown(_) return false end
    local ok, reason = xpcall(function()
        input = fake
        UI.IsPointerOverUI = function() return false end
        if not controller:UpdateEditView(1 / 60, false) or app.camera.orthoSize >= savedSize then
            error("top-view mouse wheel did not zoom the orthographic camera")
        end
        fake.mouseMoveWheel, fake.middle = 0, true
        controller:UpdateEditView(1 / 60, false)
        local beforePan = Vector3(controller.target.x, controller.target.y, controller.target.z)
        fake.mousePosition = IntVector2(fake.mousePosition.x + 80, fake.mousePosition.y + 40)
        fake.mouseMove = IntVector2(80, 40)
        if not controller:UpdateEditView(1 / 60, false)
            or (math.abs(controller.target.x - beforePan.x) < 0.0001
                and math.abs(controller.target.z - beforePan.z) < 0.0001) then
            error("top-view middle-button drag did not pan")
        end
        fake.middle = false
        controller:UpdateEditView(1 / 60, false)
        local beforeRight = Vector3(controller.target.x, controller.target.y, controller.target.z)
        fake.right = true
        fake.mousePosition = IntVector2(fake.mousePosition.x + 120, fake.mousePosition.y + 60)
        fake.mouseMove = IntVector2(120, 60)
        if controller:UpdateEditView(1 / 60, false)
            or math.abs(controller.target.x - beforeRight.x) > 0.0001
            or math.abs(controller.target.z - beforeRight.z) > 0.0001 then
            error("right-button editor gesture leaked into top-view camera movement")
        end
    end, debug.traceback)
    input, UI.IsPointerOverUI = originalInput, originalPointerCheck
    controller.target = savedTarget
    controller.editLeftPanActive, controller.editPanAnchor = false, nil
    app.camera.orthoSize = savedSize
    controller:ApplyEditView()
    if not ok then Fail(reason); return false end
    return true
end

local function AssertProjectedRoomHit(editor, roomIndex, label)
    local room = editor.rooms[roomIndex]
    local screen = room and app.camera:WorldToScreenPoint(editor:RoomWorldPosition(room, 0.22)) or nil
    if not screen then Fail(label .. " room could not be projected"); return false end
    local physical = IntVector2(math.floor(screen.x * graphics:GetWidth() + 0.5),
        math.floor(screen.y * graphics:GetHeight() + 0.5))
    local world = editor:ScreenToFloor(physical)
    local hit = world and editor:HitRoom(world) or nil
    if hit ~= roomIndex then
        Fail(label .. " screen ray did not hit the expected room"); return false
    end
    return true
end

local function RunPointerPipelineRoomDrag(editor, roomIndex, delta)
    local room = editor.rooms[roomIndex]
    local function PhysicalAt(gridX, gridY)
        local screen = app.camera:WorldToScreenPoint(editor:GridToWorld({ x = gridX, y = gridY }, 0.22))
        return IntVector2(math.floor(screen.x * graphics:GetWidth() + 0.5),
            math.floor(screen.y * graphics:GetHeight() + 0.5))
    end
    local originalInput, originalPointerCheck = input, UI.IsPointerOverUI
    local fake = {
        mousePosition = PhysicalAt(room.cx, room.cy), mouseMove = IntVector2(0, 0),
        mouseMoveWheel = 0, leftDown = true, leftPress = true, leftRelease = false,
    }
    function fake:GetMouseButtonDown(button) return button == MOUSEB_LEFT and self.leftDown end
    function fake:GetMouseButtonPress(button) return button == MOUSEB_LEFT and self.leftPress end
    function fake:GetMouseButtonRelease(button) return button == MOUSEB_LEFT and self.leftRelease end
    function fake:GetKeyDown(_) return false end
    function fake:GetKeyPress(_) return false end
    local ok, reason = xpcall(function()
        input = fake
        UI.IsPointerOverUI = function() return false end
        editor:Update(1 / 60)
        if not editor.drag or editor.drag.kind ~= "roomMove" or not editor.editorInteraction:IsCaptured() then
            error("pointer press did not create and capture a room drag")
        end
        fake.leftPress = false
        fake.mousePosition = PhysicalAt(room.cx + delta, room.cy)
        fake.mouseMove = IntVector2(delta == 0 and 0 or (delta > 0 and 12 or -12), 0)
        editor:Update(1 / 60)
        if room.cx ~= editor.drag.start.cx + delta then error("held pointer movement did not move the room") end
        fake.leftDown, fake.leftRelease = false, true
        fake.mouseMove = IntVector2(0, 0)
        editor:Update(1 / 60)
        if editor.drag or editor.editorInteraction:IsCaptured() then error("pointer release did not finish the room drag") end
    end, debug.traceback)
    input, UI.IsPointerOverUI = originalInput, originalPointerCheck
    if not ok then Fail(reason); return false end
    return true
end

local function BeginRoomProof()
    local editor = app.editor3D
    local first, second = nil, nil
    for index, room in ipairs(editor.rooms) do
        if room.floor == editor.floor then
            if not first then first = index elseif not second then second = index; break end
        end
    end
    if not first or not second then Fail("current floor has fewer than two editable rooms"); return end
    local room, peer = editor.rooms[first], editor.rooms[second]
    local delta = room.cx >= peer.cx and 1 or -1
    roomProof = {
        target = first, peer = second, expected = room.cx - peer.cx + delta,
        serial = app.generationSerial, root = app.dungeonRenderer.root,
    }
    room.cx = room.cx + delta
    editor:Commit()
    if not app.editorRebuildPending or app.generationSerial ~= roomProof.serial then
        Fail("room commit rebuilt synchronously or was not queued")
        return
    end
    state = "room-wait"
end

local function VerifyFirstRoomAndBeginSecondRoomProof()
    if app.generationSerial <= roomProof.serial then return end
    if app.dungeonRenderer.root == roomProof.root then Fail("room edit did not replace the rendered model root"); return end
    local target, peer = app.dungeon.rooms[roomProof.target], app.dungeon.rooms[roomProof.peer]
    if not target or not peer or math.abs((target.cx - peer.cx) - roomProof.expected) > 0.001 then
        Fail("room edit did not reach the generated dungeon model")
        return
    end

    if not AssertEditorReady("first room edit") then return end
    local editor = app.editor3D
    local room, peer = editor.rooms[roomProof.target], editor.rooms[roomProof.peer]
    if not AssertProjectedRoomHit(editor, roomProof.target, "second room edit") then return end
    local delta = room.cx >= peer.cx and -1 or 1
    roomProof = {
        target = roomProof.target, peer = roomProof.peer,
        expected = room.cx - peer.cx + delta,
        serial = app.generationSerial, root = app.dungeonRenderer.root,
    }
    if not RunPointerPipelineRoomDrag(editor, roomProof.target, 0) then return end
    if app.editorRebuildPending then
        Fail("stationary room click queued a model rebuild"); return
    end
    if not RunPointerPipelineRoomDrag(editor, roomProof.target, delta) then return end
    if not app.editorRebuildPending or app.generationSerial ~= roomProof.serial then
        Fail("second room drag rebuilt synchronously or was not queued"); return
    end
    state = "room-2-wait"
end

local function VerifySecondRoomAndBeginPathProof()
    if app.generationSerial <= roomProof.serial then return end
    if app.dungeonRenderer.root == roomProof.root then Fail("second room edit did not replace the rendered model root"); return end
    local target, peer = app.dungeon.rooms[roomProof.target], app.dungeon.rooms[roomProof.peer]
    if not target or not peer or math.abs((target.cx - peer.cx) - roomProof.expected) > 0.001 then
        Fail("second room edit did not reach the generated dungeon model"); return
    end
    if not AssertEditorReady("second room edit") then return end

    local editor, pathIndex = app.editor3D, nil
    for index, link in ipairs(editor.links) do
        local roomA, roomB = editor.rooms[link.a], editor.rooms[link.b]
        if link.kind ~= "stairs" and roomA and roomB
            and roomA.floor == editor.floor and roomB.floor == editor.floor then
            pathIndex = index
            break
        end
    end
    if not pathIndex then Fail("current floor has no editable path"); return end
    local link = editor.links[pathIndex]
    pathProof = {
        key = LinkKey(link), before = #(link.bends or {}),
        serial = app.generationSerial, root = app.dungeonRenderer.root,
    }
    editor.selected, editor.selectedLink = nil, pathIndex
    editor:AddBend()
    if not app.editorRebuildPending or app.generationSerial ~= pathProof.serial then
        Fail("path commit rebuilt synchronously or was not queued")
        return
    end
    state = "path-wait"
end

local function VerifyPathProof()
    if app.generationSerial <= pathProof.serial then return end
    if app.dungeonRenderer.root == pathProof.root then Fail("path edit did not replace the rendered model root"); return end
    local _, rebuilt = FindLink(app.dungeon.edges, pathProof.key)
    if not rebuilt or #(rebuilt.bends or {}) <= pathProof.before then
        Fail("path edit did not reach the generated dungeon model")
        return
    end
    if not AssertEditorReady("third path edit") then return end
    if app.editorRebuildPending or app.editorDirty then Fail("model rebuild flags were not cleared"); return end
    local message = string.format("PASS repeatedRoomSerial=%d pathSerial=%d bends=%d valid=%s",
        roomProof.serial + 1, pathProof.serial + 1, #(rebuilt.bends or {}), tostring(app.dungeon.valid))
    WriteResult(message)
    print("[editor-model-sync] " .. message)
    UnsubscribeFromEvent("Update")
    ErrorExit("[editor-model-sync] " .. message, 0)
end

function Start()
    local ok, message = xpcall(function()
        app = DungeonApp.new()
        app.seed = 15838
        app.floorCount = 3
        app.roomCounts = { 10, 10, 10 }
        app.loopRates = { 12, 16, 20 }
        app:Start()
        app:ToggleEditor(true)
        SubscribeToEvent("Update", "HandleEditorModelSyncUpdate")
    end, debug.traceback)
    if not ok then Fail(message) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleEditorModelSyncUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed > 35 then Fail("live editor model rebuild timed out"); return end
    if state == "enter" and app.editorActive and not app.editorTransition and app.editor3D:IsVisible() then
        if not AssertExactTopView(app.editor3D) then return end
        if not AssertTopViewMouseControls() then return end
        BeginRoomProof()
    elseif state == "room-wait" then
        VerifyFirstRoomAndBeginSecondRoomProof()
    elseif state == "room-2-wait" then
        VerifySecondRoomAndBeginPathProof()
    elseif state == "path-wait" then
        VerifyPathProof()
    end
end

function Stop()
    if app then app:Stop(); app = nil end
end
