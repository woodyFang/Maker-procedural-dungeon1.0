local DungeonApp = require("App.DungeonApp")
local DungeonGenerator = require("Generation.DungeonGenerator")
local EditorGesture = require("UI.Editor.EditorGesture")
local StairEditing = require("UI.Editor.StairEditing")
local Profiler = require("urhox-libs/Profiler/Profiler")

---@type table|nil
local app = nil
local elapsed = 0
local phase = "enter"
local hotResults = {}
local commitResults = {}
local commitIndex = 0
local commitGenerationBefore = 0
local hotOperations = 300
local profilerInstalled = false
local commitTransactionActive = false

local function Fail(message)
    ErrorExit("[editor-operation-performance] FAIL\n" .. tostring(message), 1)
end

local function ResetEditor()
    local editor = app.editor2D
    editor.selected, editor.selectedLink = nil, nil
    editor:SyncDungeon(app.dungeon, app.currentFloor)
    editor.selected, editor.selectedLink = nil, nil
    editor.editorInteraction:Reset(false)
    app.dungeonRenderer:ClearEditorSelection()
    return editor
end

local function FindRoom(editor)
    for index, room in ipairs(editor.rooms) do
        if room.floor == editor.floor and not room.locked and not room.stairRoomPairId then return index, room end
    end
    for index, room in ipairs(editor.rooms) do
        if room.floor == editor.floor and not room.locked then return index, room end
    end
    return nil, nil
end

local function FindPath(editor, requireBend)
    for index, link in ipairs(editor.links) do
        local roomA, roomB = editor.rooms[link.a], editor.rooms[link.b]
        if link.kind ~= "stairs" and roomA and roomB
            and roomA.floor == editor.floor and roomB.floor == editor.floor then
            local route = editor:LinkRoute(link)
            if not requireBend or #route >= 3 then return index, link, route end
        end
    end
    return nil, nil, nil
end

local function FindStair(editor)
    for index, link in ipairs(editor.links) do
        if link.kind == "stairs" and link.stairSpec and link.connector then return index, link end
    end
    return nil, nil
end

local function Measure(name, operations, prepare, apply)
    local editor = ResetEditor()
    local context = prepare(editor)
    if not context then Fail("could not prepare operation " .. name); return end
    local generationBefore = app.generationSerial or 0
    local changed = 0
    local scopeName = "Hot." .. name
    Profiler:beginScope(scopeName)
    for index = 1, operations do
        if apply(editor, context, index) then changed = changed + 1 end
    end
    local totalMs = Profiler:endScope(scopeName)
    if (app.generationSerial or 0) ~= generationBefore then
        Fail(name .. " regenerated the dungeon while dragging")
        return
    end
    hotResults[#hotResults + 1] = {
        name = name, operations = operations, changed = changed,
        totalMs = totalMs, averageMs = totalMs / math.max(1, operations), generations = 0,
    }
    editor.drag, editor.draw = nil, nil
    editor.editorInteraction:Reset(false)
end

local function ProfileMethod(target, methodName, scopeName)
    local original = target[methodName]
    target[methodName] = function(self, ...)
        Profiler:beginScope(scopeName)
        local results = { original(self, ...) }
        Profiler:endScope(scopeName)
        return table.unpack(results)
    end
end

local function InstallCommitProfiler()
    if profilerInstalled then return end
    profilerInstalled = true

    local originalGenerate = DungeonGenerator.Generate
    DungeonGenerator.Generate = function(parameters)
        Profiler:beginScope("Commit.Generator")
        local result = originalGenerate(parameters)
        Profiler:endScope("Commit.Generator")
        return result
    end

    local originalTransaction = app.GenerateEditorWithRollback
    app.GenerateEditorWithRollback = function(self, ...)
        Profiler:beginScope("Commit.Transaction")
        commitTransactionActive = true
        local results = { originalTransaction(self, ...) }
        commitTransactionActive = false
        Profiler:endScope("Commit.Transaction")
        return table.unpack(results)
    end
    ProfileMethod(app, "RebuildView", "Commit.RendererBuild")
    ProfileMethod(app, "CaptureLastValidEditorState", "Commit.CaptureValidState")
    for _, entry in ipairs({
        { target = app.editor2D, name = "Commit.Sync2D" },
        { target = app.editor3D, name = "Commit.Sync3D" },
    }) do
        local originalSync = entry.target.SyncDungeon
        entry.target.SyncDungeon = function(self, ...)
            if not commitTransactionActive then return originalSync(self, ...) end
            Profiler:beginScope(entry.name)
            local results = { originalSync(self, ...) }
            Profiler:endScope(entry.name)
            return table.unpack(results)
        end
    end

    local originalCommit = app.editor2D.callbacks.onCommit
    app.editor2D.callbacks.onCommit = function(...)
        Profiler:beginScope("Commit.Callback")
        local results = { originalCommit(...) }
        Profiler:endScope("Commit.Callback")
        return table.unpack(results)
    end
end

local function PrepareRoomMove(editor)
    local index, room = FindRoom(editor)
    if not index then return nil end
    local stairEdit = editor:CaptureRoomStairEdit(index)
    editor.drag = {
        kind = "roomMove", index = index, startX = room.cx, startY = room.cy,
        start = { cx = room.cx, cy = room.cy },
        adaptive = editor:CaptureAdaptiveRoutes(stairEdit.pair and nil or index), stairEdit = stairEdit,
    }
    editor.editorInteraction:Capture()
    return { room = room, baseX = room.cx, baseY = room.cy }
end

local function PrepareRoomResize(editor)
    local index, room = FindRoom(editor)
    if not index then return nil end
    local stairEdit = editor:CaptureRoomStairEdit(index)
    local start = { cx = room.cx, cy = room.cy, w = room.w, h = room.h }
    editor.drag = {
        kind = "roomResize", index = index, mode = "resize-e", start = start,
        adaptive = editor:CaptureAdaptiveRoutes(stairEdit.pair and nil or index), stairEdit = stairEdit,
    }
    editor.editorInteraction:Capture()
    return { room = room, edgeX = start.cx + start.w * 0.5, centerY = start.cy }
end

local function PrepareLinkDoor(editor)
    local index, link = FindPath(editor, false)
    if not index then return nil end
    local room = editor.rooms[link.a]
    editor.drag = { kind = "linkDoor", link = index, which = "a", originalDoor = link.doorA }
    editor.editorInteraction:Capture()
    return { room = room }
end

local function PrepareLinkBend(editor)
    local index, link, route = FindPath(editor, true)
    if not index then return nil end
    route = editor:EnsureEditableRoute(link)
    if #link.bends == 0 and #route >= 3 then
        link.bends[1] = { x = route[2].x, y = route[2].y }
    end
    local bend = link.bends[1]
    if not bend then return nil end
    editor.drag = { kind = "linkBend", link = index, bendIndex = 1 }
    editor.editorInteraction:Capture()
    return { x = bend.x, y = bend.y }
end

local function PrepareLinkSegment(editor)
    local index, link = FindPath(editor, false)
    if not index then return nil end
    local route = editor:EnsureEditableRoute(link)
    if #route < 2 then return nil end
    local segment, length = 1, -1
    for candidate = 1, #route - 1 do
        local dx, dy = route[candidate + 1].x - route[candidate].x, route[candidate + 1].y - route[candidate].y
        local candidateLength = dx * dx + dy * dy
        if candidateLength > length then segment, length = candidate, candidateLength end
    end
    local a, b = route[segment], route[segment + 1]
    local startX, startY = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5
    editor.drag = {
        kind = "linkSegment", link = index, segment = segment,
        startX = startX, startY = startY, pending = true,
    }
    editor.editorInteraction:Capture()
    return { startX = startX, startY = startY, horizontal = math.abs(b.x - a.x) >= math.abs(b.y - a.y) }
end

local function PrepareStairMove(editor)
    local index = FindStair(editor)
    local stair = index and editor:CaptureStairDrag(index) or nil
    local anchor = stair and (stair.spec.previewAnchor or stair.spec.anchor or stair.connector.lower)
    if not stair or not anchor then return nil end
    editor.drag = {
        kind = "stairMove", link = index, startX = anchor.x, startY = anchor.y,
        anchor = { x = anchor.x, y = anchor.y }, stair = stair, lastDX = 0, lastDY = 0,
    }
    editor.editorInteraction:Capture()
    return { x = anchor.x, y = anchor.y }
end

local function PrepareStairRotate(editor)
    local index = FindStair(editor)
    local stair = index and editor:CaptureStairDrag(index) or nil
    if not stair then return nil end
    local direction = stair.spec.previewDirection or stair.spec.direction or stair.connector.direction
    local lower, upper = stair.connector.lower, stair.connector.upper
    if not lower or not upper then return nil end
    editor.drag = {
        kind = "stairRotate", link = index, stair = stair,
        lastDirection = direction, appliedDirection = direction,
    }
    editor.editorInteraction:Capture()
    return { x = (lower.x + upper.x) * 0.5, y = (lower.y + upper.y) * 0.5 }
end

local function PrepareStairWidth(editor)
    local index = FindStair(editor)
    local stair = index and editor:CaptureStairDrag(index) or nil
    if not stair then return nil end
    local segments = StairEditing.VisualSegments(stair.connector)
    local startPoint = segments[1] and segments[1].start
    local finishPoint = segments[1] and segments[1].finish
    if not startPoint or not finishPoint then return nil end
    local dx, dy = finishPoint.x - startPoint.x, finishPoint.y - startPoint.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return nil end
    editor.drag = {
        kind = "stairWidth", link = index, stair = stair,
        lastWidth = stair.spec.previewWidth or stair.spec.width or stair.connector.width,
    }
    editor.editorInteraction:Capture()
    return {
        centerX = (startPoint.x + finishPoint.x) * 0.5,
        centerY = (startPoint.y + finishPoint.y) * 0.5,
        perpendicularX = -dy / length, perpendicularY = dx / length,
    }
end

local function RunHotBenchmarks()
    Measure("room_move", hotOperations, PrepareRoomMove, function(editor, context, index)
        local offset = index % 2 == 1 and 1 or 0
        return EditorGesture.Apply(editor, context.baseX + offset, context.baseY)
    end)
    Measure("room_resize", hotOperations, PrepareRoomResize, function(editor, context, index)
        local offset = index % 2 == 1 and 1 or 0
        return EditorGesture.Apply(editor, context.edgeX + offset, context.centerY)
    end)
    Measure("corridor_door", hotOperations, PrepareLinkDoor, function(editor, context, index)
        local offset = index % 2 == 1 and 1 or -1
        return EditorGesture.Apply(editor, context.room.cx + context.room.w * 0.5, context.room.cy + offset)
    end)
    Measure("corridor_bend", hotOperations, PrepareLinkBend, function(editor, context, index)
        local offset = index % 2 == 1 and 1 or 0
        return EditorGesture.Apply(editor, context.x + offset, context.y)
    end)
    Measure("corridor_segment", hotOperations, PrepareLinkSegment, function(editor, context, index)
        local offset = index % 2 == 1 and 1 or 0
        local x = context.startX + (context.horizontal and 0 or offset)
        local y = context.startY + (context.horizontal and offset or 0)
        return EditorGesture.Apply(editor, x, y)
    end)
    Measure("stair_move", hotOperations, PrepareStairMove, function(editor, context, index)
        local offset = index % 2 == 1 and 1 or 0
        return EditorGesture.Apply(editor, context.x + offset, context.y)
    end)
    Measure("stair_rotate", hotOperations, PrepareStairRotate, function(editor, context, index)
        local direction = index % 2 == 1 and 1 or -1
        return EditorGesture.Apply(editor, context.x + direction * 12, context.y)
    end)
    Measure("stair_width", hotOperations, PrepareStairWidth, function(editor, context, index)
        local width = index % 2 == 1 and 3.0 or 1.5
        local distance = width * 0.5 + 1
        return EditorGesture.Apply(editor,
            context.centerX + context.perpendicularX * distance,
            context.centerY + context.perpendicularY * distance)
    end)
    Measure("room_draw_preview", hotOperations, function(editor)
        editor.draw = { gx = 4, gy = 4, ex = 10, ey = 10 }
        return { x = 10, y = 10 }
    end, function(editor, context, index)
        local offset = index % 2 == 1 and 1 or 0
        return EditorGesture.UpdateDraw(editor, context.x + offset, context.y)
    end)
    Measure("selection_highlight", 120, function(editor)
        local roomIndex = FindRoom(editor)
        local linkIndex = FindPath(editor, false)
        return roomIndex and linkIndex and { room = roomIndex, link = linkIndex } or nil
    end, function(editor, context, index)
        if index % 2 == 1 then
            editor.selected, editor.selectedLink = context.room, nil
        else
            editor.selected, editor.selectedLink = nil, context.link
        end
        editor:NotifySelection()
        return true
    end)
end

local function StartCommitBenchmark()
    local editor = ResetEditor()
    local context = PrepareRoomMove(editor)
    if not context then Fail("could not prepare commit benchmark"); return end
    EditorGesture.Apply(editor, context.baseX + 1, context.baseY)
    EditorGesture.Apply(editor, context.baseX, context.baseY)
    commitGenerationBefore = app.generationSerial or 0
    Profiler:beginScope("Commit.ReleaseToObserved")
    Profiler:beginScope("Commit.ReleaseCallback")
    EditorGesture.Finish(editor, nil)
    local releaseCallbackMs = Profiler:endScope("Commit.ReleaseCallback")
    commitResults[#commitResults + 1] = { releaseCallbackMs = releaseCallbackMs, pending = true }
    phase = "wait-commit"
end

local function Finish()
    local lines = {}
    for _, result in ipairs(hotResults) do
        lines[#lines + 1] = string.format(
            "HOT name=%s operations=%d changed=%d totalMs=%.3f averageMs=%.5f dragGenerations=%d",
            result.name, result.operations, result.changed, result.totalMs, result.averageMs, result.generations)
    end
    for index, result in ipairs(commitResults) do
        lines[#lines + 1] = string.format(
            "COMMIT run=%d generations=%d releaseCallbackMs=%.1f observedMs=%.1f generationMs=%.1f rendererBuildMs=%.1f totalMs=%.1f instances=%d",
            index, result.generations, result.releaseCallbackMs, result.observedMs, result.generationMs,
            result.rendererBuildMs, result.totalMs, result.instances)
    end
    Profiler:recordMemory()
    local memory = Profiler:getMemoryStats()
    lines[#lines + 1] = string.format("MEMORY currentMB=%.2f peakMB=%.2f trendKB=%.1f samples=%d",
        memory.current / 1024, memory.peak / 1024, memory.trend, memory.samples)
    for _, hotspot in ipairs(Profiler:getHotspots(40)) do
        lines[#lines + 1] = string.format(
            "PROFILE name=%s calls=%d totalMs=%.3f averageMs=%.3f minMs=%.3f maxMs=%.3f sessionPercent=%.2f",
            hotspot.name, hotspot.callCount, hotspot.totalTime * 1000,
            hotspot.avgTime * 1000, hotspot.minTime * 1000, hotspot.maxTime * 1000,
            hotspot.percentOfSession)
    end
    for _, hotspot in ipairs(Profiler:getGCHotspots(30)) do
        lines[#lines + 1] = string.format(
            "GC name=%s totalKB=%.2f samples=%d averageKB=%.2f",
            hotspot.name, hotspot.totalAlloc, hotspot.samples, hotspot.avgAlloc)
    end
    lines[#lines + 1] = "PASS hotKinds=" .. tostring(#hotResults) .. " commitRuns=" .. tostring(#commitResults)
    ErrorExit("[editor-operation-performance]\n" .. table.concat(lines, "\n"), 0)
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
        Profiler:reset()
        Profiler:setEnabled(true)
        Profiler:recordMemory()
        SubscribeToEvent("Update", "HandleEditorOperationPerformanceUpdate")
    end, debug.traceback)
    if not ok then Fail(message) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleEditorOperationPerformanceUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed > 45 then Fail("operation performance benchmark timed out"); return end
    if phase == "enter" and app.editorActive and not app.editorTransition and app.editor2D:IsVisible() then
        local ok, message = xpcall(RunHotBenchmarks, debug.traceback)
        if not ok then Fail(message); return end
        InstallCommitProfiler()
        commitIndex = 1
        StartCommitBenchmark()
    elseif phase == "wait-commit" and (app.generationSerial or 0) > commitGenerationBefore then
        local metrics = app.dungeonRenderer.lastBuildMetrics or {}
        local observedMs = Profiler:endScope("Commit.ReleaseToObserved")
        local result = commitResults[#commitResults]
        result.pending = nil
        result.generations = (app.generationSerial or 0) - commitGenerationBefore
        result.observedMs = observedMs
        result.generationMs = app.lastGenerationMs or -1
        result.rendererBuildMs = metrics.buildMs or -1
        result.totalMs = app.lastGenerationTotalMs or -1
        result.instances = metrics.instances or -1
        if commitResults[#commitResults].generations ~= 1 then
            Fail("one commit triggered more than one generation"); return
        end
        if commitIndex < 3 then
            commitIndex = commitIndex + 1
            StartCommitBenchmark()
        else
            Finish()
        end
    end
end
