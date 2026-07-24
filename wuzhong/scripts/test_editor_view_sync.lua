local DungeonApp = require("App.DungeonApp")
local MultiFloor = require("Generation.MultiFloor")

---@type table|nil
local app = nil
local elapsed = 0
local phase = "enter"
local roomIndex, pathIndex = nil, nil
local expectedX, expectedY = nil, nil
local generationBeforePreview = 0
local generationAfterCommit = 0
local resultPath = ".tmp/editor-view-sync.result.txt"

local function WriteResult(message)
    ---@type File|nil
    local result = File(resultPath, FILE_WRITE)
    if not result or not result:IsOpen() then return false end
    result:WriteLine(message); result:Close(); return true
end

local function Fail(message)
    WriteResult("FAIL " .. tostring(message))
    ErrorExit("[editor-view-sync] FAIL\n" .. tostring(message), 1)
end

local function FindEditablePath(editor)
    for index, link in ipairs(editor.links) do
        local roomA, roomB = editor.rooms[link.a], editor.rooms[link.b]
        if link.kind ~= "stairs" and roomA and roomB
            and roomA.floor == editor.floor and roomB.floor == editor.floor then return index end
    end
    return nil
end

local function FindStairLink(editor)
    for index, link in ipairs(editor.links) do
        if link.kind == "stairs" and link.connector and link.connector.lower then return index, link end
    end
    return nil, nil
end

function Start()
    local ok, message = xpcall(function()
        app = DungeonApp.new()
        app.seed = 15838
        app.floorCount = 3
        app.roomCounts = { 10, 10, 10 }
        app.loopRates = { 12, 16, 20 }
        app:Start()
        app:ToggleEditorMode("2d")
        SubscribeToEvent("Update", "HandleEditorViewSyncUpdate")
    end, debug.traceback)
    if not ok then Fail(message) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleEditorViewSyncUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed > 20 then Fail("2D/3D editor view synchronization timed out"); return end
    if phase == "enter" and app.editorActive and not app.editorTransition and app.editor2D:IsVisible() then
        if app.camera.orthographic or app.forgeCamera:IsEditViewActive() then
            Fail("2D editor entry unexpectedly switched the 3D camera to top orthographic view"); return
        end
        if not app.forgeCamera.enabled then
            Fail("2D editor entry disabled the 3D perspective camera controls"); return
        end
        local editor = app.editor2D
        for index, room in ipairs(editor.rooms) do
            if room.floor == editor.floor then roomIndex = index; break end
        end
        pathIndex = FindEditablePath(editor)
        if not roomIndex or not pathIndex then Fail("missing editable room or path"); return end
        editor.selected, editor.selectedLink = roomIndex, nil
        editor:NotifySelection()
        if not app.dungeonRenderer.selectionRoot or app.dungeonRenderer.selectionRoomIndex ~= roomIndex then
            Fail("2D room selection did not create a 3D highlight"); return
        end
        editor.selected, editor.selectedLink = nil, pathIndex
        editor:NotifySelection()
        if not app.dungeonRenderer.selectionRoot or app.dungeonRenderer.selectionLinkIndex ~= pathIndex then
            Fail("2D path selection did not create a 3D highlight"); return
        end
        editor.selected, editor.selectedLink = roomIndex, pathIndex
        editor.rooms[roomIndex].cx = editor.rooms[roomIndex].cx + 1
        editor.links[pathIndex].width = 3
        expectedX = editor.rooms[roomIndex].cx
        generationBeforePreview = app.generationSerial or 0
        editor:Preview()
        phase, elapsed = "verify-lightweight-preview", 0
    elseif phase == "verify-lightweight-preview" and elapsed > 0.30 then
        if (app.generationSerial or 0) ~= generationBeforePreview then
            Fail("2D pointer preview regenerated the authoritative dungeon"); return
        end
        local editor = app.editor2D
        editor:Commit()
        generationAfterCommit = app.generationSerial or 0
        phase, elapsed = "verify-committed-rebuild", 0
    elseif phase == "verify-committed-rebuild" and (app.generationSerial or 0) > generationAfterCommit then
        if not app.dungeon or not app.editor3D.rooms[roomIndex] or not app.dungeon.rooms[roomIndex]
            or app.editor3D.rooms[roomIndex].cx ~= app.dungeon.rooms[roomIndex].cx then
            Fail("2D commit did not rebuild and synchronize the generated 3D result"); return
        end
        local editor = app.editor2D
        local stairIndex = FindStairLink(editor)
        if not stairIndex then Fail("missing stair for 2D-to-3D selection highlight check"); return end
        editor.selected, editor.selectedLink = nil, stairIndex
        editor:NotifySelection()
        if not app.dungeonRenderer.selectionRoot or app.dungeonRenderer.selectionLinkIndex ~= stairIndex then
            Fail("2D stair selection did not create a 3D highlight"); return
        end
        editor.selected, editor.selectedLink = roomIndex, pathIndex
        editor:NotifySelection()
        local offset = app.dungeon.editorOffset or { x = 0, y = 0 }
        if editor.generatedOffset.x ~= offset.x or editor.generatedOffset.y ~= offset.y
            or app.dungeon.rooms[roomIndex].cx ~= editor.rooms[roomIndex].cx + offset.x
            or app.dungeon.rooms[roomIndex].cy ~= editor.rooms[roomIndex].cy + offset.y then
            Fail("2D committed edit lost the local-to-generated coordinate mapping"); return
        end
        if app.editor3D.rooms[roomIndex].cx ~= expectedX or app.editor3D.links[pathIndex].width ~= 3 then
            Fail("2D commit was not mirrored into the hidden 3D editor"); return
        end
        app:SetEditorMode("3d")
        phase, elapsed = "verify-3d", 0
    elseif phase == "verify-3d" and not app.editorTransition and app.editor3D:IsVisible() then
        if (app.generationSerial or 0) ~= generationAfterCommit + 1 then
            Fail("one 2D commit triggered more than one dungeon generation"); return
        end
        local editor = app.editor3D
        if not editor:IsVisible() or app.editor ~= editor then Fail("3D editor did not become active"); return end
        if app.dungeonRenderer.selectionRoot then
            Fail("2D selection highlight remained active in the 3D editor"); return
        end
        if not app.camera.orthographic or not app.forgeCamera:IsEditViewActive() then
            Fail("3D editor did not switch to the orthographic top view"); return
        end
        local centerRay = app.camera:GetScreenRay(0.5, 0.5)
        if math.abs(centerRay.direction.x) > 0.0001
            or math.abs(centerRay.direction.y + 1) > 0.0001
            or math.abs(centerRay.direction.z) > 0.0001 then
            Fail("3D editor top view is not exactly vertical"); return
        end
        if editor.rooms[roomIndex].cx ~= expectedX or editor.links[pathIndex].width ~= 3 then
            Fail("direct 2D edits were not synchronized into 3D"); return
        end
        local room = editor.rooms[roomIndex]
        local world = editor:RoomWorldPosition(room, 0)
        local generated = app.dungeon.rooms[roomIndex]
        local expectedWorldX = generated.cx - app.dungeon.width * 0.5 + 0.5
        local expectedWorldZ = generated.cy - app.dungeon.height * 0.5 + 0.5
        if math.abs(world.x - expectedWorldX) > 0.000001 or math.abs(world.z - expectedWorldZ) > 0.000001 then
            Fail("3D editor overlay did not align with the generated dungeon"); return
        end
        local _, stair = FindStairLink(editor)
        if not stair then Fail("missing generated stair for coordinate linkage check"); return end
        local generatedConnector = nil
        for _, connector in ipairs(app.dungeon.connectors or {}) do
            if connector.id == stair.connector.id then generatedConnector = connector; break end
        end
        if not generatedConnector then Fail("generated stair connector was not preserved across views"); return end
        local stairWorld = editor:GridToWorld(stair.connector.lower, 0)
        local expectedStairX = generatedConnector.lower.x - app.dungeon.width * 0.5 + 0.5
        local expectedStairZ = generatedConnector.lower.y - app.dungeon.height * 0.5 + 0.5
        if math.abs(stairWorld.x - expectedStairX) > 0.000001
            or math.abs(stairWorld.z - expectedStairZ) > 0.000001 then
            Fail("2D stair position did not align with the generated 3D stair"); return
        end
        local offset = app.dungeon.editorOffset or { x = 0, y = 0 }
        if stair.connector.upper.x + offset.x ~= generatedConnector.upper.x
            or stair.connector.upper.y + offset.y ~= generatedConnector.upper.y then
            Fail("2D upper stair socket did not align with the generated 3D connector"); return
        end
        local localPlatform = MultiFloor.StairTurnPlatformMetrics(stair.connector)
        local generatedPlatform = MultiFloor.StairTurnPlatformMetrics(generatedConnector)
        if localPlatform and generatedPlatform
            and (math.abs(localPlatform.center.x + offset.x - generatedPlatform.center.x) > 0.000001
                or math.abs(localPlatform.center.y + offset.y - generatedPlatform.center.y) > 0.000001
                or math.abs(localPlatform.second.finish.x + offset.x - generatedPlatform.second.finish.x) > 0.000001
                or math.abs(localPlatform.second.finish.y + offset.y - generatedPlatform.second.finish.y) > 0.000001) then
            Fail("2D turn platform and second flight did not align with the generated 3D stair"); return
        end
        if editor.floorHeight ~= MultiFloor.FLOOR_HEIGHT or editor.floorHeight ~= 5.0 then
            Fail("3D editor did not retain the UrhoX five-meter floor contract"); return
        end
        editor.rooms[roomIndex].cy = editor.rooms[roomIndex].cy + 1
        editor.links[pathIndex].width = 4
        expectedY = editor.rooms[roomIndex].cy
        editor:Commit()
        if app.editor2D.rooms[roomIndex].cy ~= expectedY or app.editor2D.links[pathIndex].width ~= 4 then
            Fail("3D commit was not mirrored into the hidden 2D editor"); return
        end
        app:SetEditorMode("2d")
        phase, elapsed = "verify-2d", 0
    elseif phase == "verify-2d" and elapsed > 0.35 then
        local editor = app.editor2D
        if not editor:IsVisible() or app.editor ~= editor then Fail("2D editor did not become active again"); return end
        if not app.dungeonRenderer.selectionRoot then
            Fail("2D selection highlight was not restored after switching back from 3D"); return
        end
        if editor.rooms[roomIndex].cx ~= expectedX or editor.rooms[roomIndex].cy ~= expectedY
            or editor.links[pathIndex].width ~= 4 then
            Fail("3D edits were not synchronized back into 2D"); return
        end
        if editor.floorHeight ~= MultiFloor.FLOOR_HEIGHT then Fail("2D floor height changed during view synchronization"); return end
        if not editor.canvas or not editor.editorViewport.fitted or editor.editorViewport.scale <= 0 then
            Fail("direct 2D canvas did not render and fit its viewport"); return
        end
        local message = string.format("PASS room=%d path=%d x=%.1f y=%.1f width=%d floorHeight=%.1f",
            roomIndex, pathIndex, expectedX, expectedY, editor.links[pathIndex].width, editor.floorHeight)
        WriteResult(message); print("[editor-view-sync] " .. message)
        UnsubscribeFromEvent("Update"); ErrorExit("[editor-view-sync] " .. message, 0)
    end
end

function Stop()
    if app then app:Stop(); app = nil end
end
