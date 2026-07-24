local DungeonApp = require("App.DungeonApp")
local EditorGesture = require("UI.Editor.EditorGesture")

---@type table|nil
local app = nil
local elapsed = 0
local phase = "enter"
local generationBefore = 0
local commitStartedClock = 0
local dragTotalMs = 0
local dragChanged = 0
local dragOperations = 500
local resultPath = ".tmp/editor-performance.result.txt"

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
    ErrorExit("[editor-performance] FAIL\n" .. tostring(message), 1)
end

local function FindEditableRoom(editor)
    for index, room in ipairs(editor.rooms) do
        if room.floor == editor.floor and not room.locked then return index, room end
    end
    return nil, nil
end

local function RunDragBenchmark()
    local editor = app.editor2D
    local roomIndex, room = FindEditableRoom(editor)
    if not roomIndex or not room then Fail("missing editable room"); return end

    local stairEdit = editor:CaptureRoomStairEdit(roomIndex)
    editor.drag = {
        kind = "roomMove",
        index = roomIndex,
        startX = room.cx,
        startY = room.cy,
        start = { cx = room.cx, cy = room.cy },
        adaptive = editor:CaptureAdaptiveRoutes(stairEdit.pair and nil or roomIndex),
        stairEdit = stairEdit,
    }
    editor.editorInteraction:Capture()
    generationBefore = app.generationSerial or 0

    local started = os.clock()
    for index = 1, dragOperations do
        local offset = index % 2 == 0 and 1 or -1
        if EditorGesture.Apply(editor, room.cx + offset, room.cy) then
            dragChanged = dragChanged + 1
        end
    end
    dragTotalMs = (os.clock() - started) * 1000

    if (app.generationSerial or 0) ~= generationBefore then
        Fail("drag loop triggered authoritative generation")
        return
    end
    if dragChanged ~= dragOperations then
        Fail(string.format("only %d/%d drag operations changed the editor", dragChanged, dragOperations))
        return
    end

    commitStartedClock = os.clock()
    EditorGesture.Finish(editor, nil)
    phase = "wait-commit"
end

function Start()
    local ok, message = xpcall(function()
        app = DungeonApp.new()
        app.seed = 1337
        app.floorCount = 2
        app.roomCounts = { 21, 21 }
        app.loopRates = { 15, 15 }
        app:Start()
        app:ToggleEditorMode("2d")
        SubscribeToEvent("Update", "HandleEditorPerformanceUpdate")
    end, debug.traceback)
    if not ok then Fail(message) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleEditorPerformanceUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed > 30 then Fail("performance benchmark timed out"); return end

    if phase == "enter" and app.editorActive and not app.editorTransition and app.editor2D:IsVisible() then
        local ok, message = xpcall(RunDragBenchmark, debug.traceback)
        if not ok then Fail(message) end
    elseif phase == "wait-commit" and (app.generationSerial or 0) > generationBefore then
        local metrics = app.dungeonRenderer.lastBuildMetrics or {}
        local observedMs = (os.clock() - commitStartedClock) * 1000
        local message = string.format(
            "PASS operations=%d changed=%d dragTotalMs=%.3f dragAverageMs=%.5f " ..
            "dragGenerations=0 commitGenerations=%d debounceAndCommitMs=%.1f " ..
            "generationMs=%.1f rendererBuildMs=%.1f generationTotalMs=%.1f rooms=%d instances=%d",
            dragOperations, dragChanged, dragTotalMs, dragTotalMs / dragOperations,
            (app.generationSerial or 0) - generationBefore, observedMs,
            app.lastGenerationMs or -1, metrics.buildMs or -1, app.lastGenerationTotalMs or -1,
            app.dungeon and #app.dungeon.rooms or -1, metrics.instances or -1)
        WriteResult(message)
        ErrorExit("[editor-performance] " .. message, 0)
    end
end
