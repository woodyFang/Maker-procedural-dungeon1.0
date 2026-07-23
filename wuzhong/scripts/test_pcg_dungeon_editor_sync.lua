local DungeonApp = require("App.DungeonApp")
local FixedThemes = require("Config.FixedThemes")
local PCGDungeonGenerator = require("Generation.PCGDungeonGenerator")
local EditorData = require("UI.Editor.EditorData")

local RESULT_PATH = ".tmp/pcg-dungeon-editor-sync.result.txt"
local CELL_SIZE = 5.0

---@type table|nil
local app = nil

local function WriteResult(message)
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    local file = File(RESULT_PATH, FILE_WRITE)
    if file and file:IsOpen() then
        file:WriteLine(message)
        file:Close()
    end
end

local function Check(condition, message)
    if not condition then error(message, 2) end
end

local function CopyLinks(links)
    local result = {}
    for index, link in ipairs(links or {}) do result[index] = EditorData.CopyLink(link) end
    return result
end

local function GenerateEdited(base, rooms, links)
    return PCGDungeonGenerator.Generate({
        seed = base.seed,
        floorCount = base.floorCount,
        roomCountsByFloor = base.roomCountsByFloor,
        cellSize = CELL_SIZE,
        editorEnabled = true,
        editorRooms = rooms,
        editorEdges = links,
        editorGridCells = base.layout.editorGridCells or base.layout.gridCells,
    })
end

local function FindValidMove(base)
    local links = CopyLinks(base.edges)
    for roomIndex, room in ipairs(base.rooms) do
        for _, delta in ipairs({ 1, -1 }) do
            local rooms = EditorData.CopyRooms(base.rooms)
            rooms[roomIndex].cx = rooms[roomIndex].cx + delta
            local edited = GenerateEdited(base, rooms, links)
            if edited.valid then return roomIndex, delta, rooms, links, edited end
        end
    end
    error("no one-cell PCG room move produced a valid routed dungeon")
end

local function SelectRoom(editor, roomIndex)
    editor.selected, editor.selectedLink = roomIndex, nil
    editor:NotifySelection()
end

function Start()
    local ok, errorMessage = xpcall(function()
        local base = PCGDungeonGenerator.Generate({
            seed = 5, floorCount = 3, roomCount = 22, cellSize = CELL_SIZE,
        })
        Check(base.valid, base.error or "base PCG dungeon is invalid")
        Check(base.hash == "0270de1c" and base.astar.stairCount == 26,
            "random PCG generation no longer matches the canonical topology")
        Check(#base.edges > 0 and #base.connectors == base.astar.stairCount
                and base.floorHeight == CELL_SIZE,
            "PCG dungeon does not expose the editor edge/floor contract")
        Check(base.editorWorldScale == CELL_SIZE and base.editorSwapAxes == true
                and base.editorCenterOffset == 0,
            "PCG dungeon does not expose its runtime-to-editor coordinate transform")
        Check(base.editorRoomMinimumWidth == 1 and base.editorRoomMinimumHeight == 1,
            "PCG dungeon does not expose its 1x1 editor room minimum")
        for index, room in ipairs(base.rooms) do
            Check(room.id == index - 1, "PCG internal room numbering is not zero based")
        end
        local runtimeStairCount, runtimeRouteCount = 0, 0
        for _, edge in ipairs(base.edges) do
            Check(edge.a >= 1 and edge.a <= #base.rooms and edge.b >= 1 and edge.b <= #base.rooms,
                "editor edge endpoint is outside the one-based room range")
            Check(edge.runtimeGenerated and #(edge.runtimeRoutes or {}) > 0,
                "editor edge does not expose its routed A* path")
            Check(edge.width == 1, "PCG editor path width does not match one A* cell")
            runtimeStairCount = runtimeStairCount + #(edge.runtimeStairs or {})
            runtimeRouteCount = runtimeRouteCount + #(edge.runtimeRoutes or {})
        end
        Check(runtimeStairCount == base.astar.stairCount and runtimeRouteCount >= #base.edges,
            "runtime path/stair projection differs from the canonical A* result")
        local connectorIds = {}
        for _, connector in ipairs(base.connectors) do
            Check(connector.id == "pcg-stair-" .. tostring(connector.stairwellId)
                    and not connectorIds[connector.id]
                    and connector.fromFloor + 1 == connector.toFloor
                    and connector.style == "straight" and connector.width == 1,
                "PCG stair connector does not match the A* landing contract")
            connectorIds[connector.id] = true
        end

        local unchanged = GenerateEdited(base, EditorData.CopyRooms(base.rooms), CopyLinks(base.edges))
        Check(unchanged.valid, "unchanged editor layout is invalid: " .. tostring(unchanged.error))
        local roomIndex, delta, movedRooms, links, moved = FindValidMove(base)
        Check(moved.rooms[roomIndex].id == roomIndex - 1,
            "edited room index no longer maps to the same internal room id")
        Check(math.abs(moved.rooms[roomIndex].position[1]
                - base.rooms[roomIndex].position[1] - delta * CELL_SIZE) < 0.0001,
            "one editor grid step did not move the PCG room by one cell size")

        local overlapRooms = EditorData.CopyRooms(movedRooms)
        local peerIndex
        for index, room in ipairs(overlapRooms) do
            if index ~= roomIndex and room.floor == overlapRooms[roomIndex].floor then
                peerIndex = index
                break
            end
        end
        Check(peerIndex ~= nil, "no same-floor room exists for overlap rollback proof")
        overlapRooms[roomIndex].cx = overlapRooms[peerIndex].cx
        overlapRooms[roomIndex].cy = overlapRooms[peerIndex].cy
        overlapRooms[roomIndex].w = overlapRooms[peerIndex].w
        overlapRooms[roomIndex].h = overlapRooms[peerIndex].h
        local invalid = GenerateEdited(base, overlapRooms, links)
        Check(not invalid.valid and tostring(invalid.error):find("overlap", 1, true) ~= nil,
            "overlapping editor rooms were not rejected")

        app = DungeonApp.new()
        app.seed = 5
        app.floorCount = 3
        app.roomCounts = { 8, 7, 7 }
        app:Start()
        local preset = FixedThemes.Get("shadowCastle")
        app.activeFixedThemeId = preset.id
        app.settingKey, app.themeKey = preset.settingKey, preset.themeKey
        app.floorHeight = preset.floorHeight
        local built, buildReason = app:RefreshPCGDungeon(false, {
            seed = 5, floorCount = 3, roomCountsByFloor = { 8, 7, 7 },
        })
        Check(built, "app PCG scene build failed: " .. tostring(buildReason))
        app:ToggleEditor(true, "2d")
        Check(app.editorActive and app.editor2D:IsVisible(), "2D editor did not remain visible")
        Check(#app.editor2D.rooms == #app.dungeon.rooms and #app.editor2D.links == #app.dungeon.edges,
            "2D editor did not receive the PCG room/edge model")
        Check(app.editor2D.roomMinimumWidth == 1 and app.editor2D.roomMinimumHeight == 1
                and app.editor3D.roomMinimumWidth == 1 and app.editor3D.roomMinimumHeight == 1,
            "castle editors did not receive the PCG room size constraints")

        local shrinkIndex, shrinkMode, shrinkPointer
        for index, room in ipairs(app.editor2D.rooms) do
            if room.w > 1 then
                shrinkIndex, shrinkMode = index, "resize-e"
                shrinkPointer = { x = room.cx + room.w * 0.5 - 1.2, y = room.cy }
                break
            elseif room.h > 1 then
                shrinkIndex, shrinkMode = index, "resize-s"
                shrinkPointer = { x = room.cx, y = room.cy + room.h * 0.5 - 1.2 }
                break
            end
        end
        Check(shrinkIndex ~= nil, "generated castle has no room larger than 1x1 for resize proof")
        local shrinkRoom = app.editor2D.rooms[shrinkIndex]
        local shrinkStart = { cx = shrinkRoom.cx, cy = shrinkRoom.cy, w = shrinkRoom.w, h = shrinkRoom.h }
        app.editor2D:ResizeRoom(shrinkRoom, shrinkStart, shrinkPointer.x, shrinkPointer.y, shrinkMode)
        Check(shrinkRoom.w >= 1 and shrinkRoom.h >= 1
                and (shrinkRoom.w < shrinkStart.w or shrinkRoom.h < shrinkStart.h),
            "2D castle room did not shrink toward its interior")
        shrinkRoom.cx, shrinkRoom.cy, shrinkRoom.w, shrinkRoom.h =
            shrinkStart.cx, shrinkStart.cy, shrinkStart.w, shrinkStart.h

        local appRoomIndex, appDelta = FindValidMove(app.dungeon)
        SelectRoom(app.editor2D, appRoomIndex)
        Check(app.pcgDungeonRenderer.selectionRoomId == appRoomIndex - 1
                and app.pcgDungeonRenderer.selectionCellCount > 0,
            "2D selection did not highlight the matching PCG room")
        app.editorMode, app.editor = "3d", app.editor3D
        SelectRoom(app.editor3D, appRoomIndex)
        Check(app.pcgDungeonRenderer.selectionRoomId == appRoomIndex - 1
                and app.pcgDungeonRenderer.selectionCellCount > 0,
            "3D selection did not highlight the matching PCG room")
        app.editorMode, app.editor = "2d", app.editor2D
        local firstRoot = app.pcgDungeonRenderer.root
        local firstSerial = app.generationSerial
        app.editor2D.rooms[appRoomIndex].cx = app.editor2D.rooms[appRoomIndex].cx + appDelta
        app.editor2D:Commit()
        Check(app:GenerateEditorWithRollback(false), "first PCG editor move failed")
        Check(app.generationSerial > firstSerial and app.pcgDungeonRenderer.root ~= firstRoot,
            "first PCG editor move did not rebuild the castle root")
        Check(app.editor2D:IsVisible() and app.editor2D.selected == appRoomIndex,
            "first rebuild lost editor visibility or room selection")
        Check(app.pcgDungeonRenderer.selectionRoomId == appRoomIndex - 1,
            "first rebuild lost the PCG selection mapping")

        local secondRoot = app.pcgDungeonRenderer.root
        app.editor2D.rooms[appRoomIndex].cx = app.editor2D.rooms[appRoomIndex].cx - appDelta
        app.editor2D:Commit()
        Check(app:GenerateEditorWithRollback(false), "second PCG editor move failed")
        Check(app.pcgDungeonRenderer.root ~= secondRoot and app.editor2D.selected == appRoomIndex,
            "second PCG editor move did not rebuild while preserving selection")

        local validX, validY = app.dungeon.rooms[appRoomIndex].cx, app.dungeon.rooms[appRoomIndex].cy
        local editorPeer
        for index, room in ipairs(app.editor2D.rooms) do
            if index ~= appRoomIndex and room.floor == app.editor2D.rooms[appRoomIndex].floor then
                editorPeer = index
                break
            end
        end
        Check(editorPeer ~= nil, "app overlap rollback has no same-floor peer")
        local target, peer = app.editor2D.rooms[appRoomIndex], app.editor2D.rooms[editorPeer]
        target.cx, target.cy, target.w, target.h = peer.cx, peer.cy, peer.w, peer.h
        app.editor2D:Commit()
        Check(not app:GenerateEditorWithRollback(false), "invalid overlap unexpectedly committed")
        Check(math.abs(app.dungeon.rooms[appRoomIndex].cx - validX) < 0.0001
                and math.abs(app.dungeon.rooms[appRoomIndex].cy - validY) < 0.0001,
            "invalid overlap did not roll back to the last valid castle")
        Check(app.editor2D:IsVisible() and app.editor2D.selected == appRoomIndex,
            "rollback lost editor visibility or selected room number")
        app.editorDirty, app.editorRebuildPending = false, false
        app:ToggleEditor(false)
        Check(app.pcgDungeonRenderer.selectionRoomId == nil
                and app.pcgDungeonRenderer.selectionRoot == nil,
            "closing the editor left a PCG room highlight in the castle")

        local onSetting = app.panel and app.panel.callbacks and app.panel.callbacks.onSetting
        Check(type(onSetting) == "function", "AI setting switch callback is unavailable")
        onSetting("school")
        local switchedState = app:State()
        Check(switchedState.topicMode == "base" and switchedState.activeFixedThemeId == nil
                and switchedState.settingKey == "school" and switchedState.themeKey == "schoolDay",
            "fixed PCG to AI setting switch did not update topic state")
        Check(switchedState.floorCount == 2
                and switchedState.roomCounts[1] == 21 and switchedState.roomCounts[2] == 21
                and switchedState.loopRates[1] == 15 and switchedState.loopRates[2] == 15
                and switchedState.decorDensities[1] == 60 and switchedState.decorDensities[2] == 60,
            "fixed PCG parameters leaked into the AI scene panel state")
        for _, editor in ipairs({ app.editor2D, app.editor3D }) do
            Check(editor.editorWorldScale == 1 and editor.editorSwapAxes == false
                    and editor.editorCenterOffset == 0.5,
                "fixed PCG coordinate transform leaked into the AI editor view")
            Check(editor.roomMinimumWidth == 5 and editor.roomMinimumHeight == 5,
                "fixed PCG room minimum leaked into the AI editor view")
        end

        local message = string.format("PASS rooms=%d edges=%d selected=%d serial=%d",
            #app.dungeon.rooms, #app.dungeon.edges, appRoomIndex, app.generationSerial)
        WriteResult(message)
        print("[PCGDungeonEditorSync] " .. message)
        ErrorExit("[PCGDungeonEditorSync] " .. message, 0)
    end, debug.traceback)
    if not ok then
        WriteResult("FAIL\n" .. tostring(errorMessage))
        ErrorExit("[PCGDungeonEditorSync] FAIL\n" .. tostring(errorMessage), 1)
    end
end

function Stop()
    if app then app:Stop(); app = nil end
end
