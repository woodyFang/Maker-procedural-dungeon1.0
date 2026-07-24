local RoomEditing = require("UI.Editor.RoomEditing")
local EditorGesture = require("UI.Editor.EditorGesture")
local EditorInteraction = require("UI.Editor.EditorInteraction")

local resultPath = ".tmp/room-edit-regression.result.txt"

local function Check(condition, message)
    if not condition then error(message or "room edit regression failed", 2) end
end

local function SameRoom(room, expected)
    return room.cx == expected.cx and room.cy == expected.cy
        and room.w == expected.w and room.h == expected.h
end

local function WriteResult(message)
    ---@type File|nil
    local result = File(resultPath, FILE_WRITE)
    if result and result:IsOpen() then result:WriteLine(message); result:Close() end
end

local function RunRegression()
    local editor = {
        rooms = { { cx = 20, cy = 18, w = 9, h = 7, floor = 0 } },
        links = {}, callbacks = {}, editorInteraction = EditorInteraction.new(),
        roomMinimumWidth = 1, roomMinimumHeight = 1,
        UpdateRoomStairEdit = function() end,
        ApplyAdaptiveRoutes = function() end,
        UpdateRoomVisual = function() end,
        RefreshOverlay = function() end,
        Commit = function(self) self.commits = (self.commits or 0) + 1 end,
        ResizeRoom = function(self, room, start, x, y, mode)
            local resized = RoomEditing.Resize(start, { x = x, y = y }, mode,
                self.roomMinimumWidth, self.roomMinimumHeight)
            room.cx, room.cy, room.w, room.h = resized.cx, resized.cy, resized.w, resized.h
        end,
    }
    local room = editor.rooms[1]

    for cycle = 1, 100 do
        local start = { cx = room.cx, cy = room.cy }
        local pointerStart = { x = room.cx + 0.25, y = room.cy - 0.25 }
        local delta = cycle % 2 == 0 and -1 or 1
        editor.drag = { kind = "roomMove", index = 1,
            startX = pointerStart.x, startY = pointerStart.y, start = start, adaptive = {} }
        editor.editorInteraction:Capture()
        Check(EditorGesture.Apply(editor, pointerStart.x + delta, pointerStart.y),
            "move did not apply cycle " .. cycle)
        Check(room.cx == start.cx + delta and room.cy == start.cy,
            "move did not follow pointer delta cycle " .. cycle)
        Check(EditorGesture.Finish(editor) and not editor.editorInteraction:IsCaptured(),
            "move did not release cycle " .. cycle)
    end

    local modes = { "resize-nw", "resize-ne", "resize-sw", "resize-se" }
    for cycle = 1, 100 do
        room.cx, room.cy, room.w, room.h = 20, 18, 9, 7
        local start = { cx = room.cx, cy = room.cy, w = room.w, h = room.h }
        local mode = modes[(cycle - 1) % #modes + 1]
        local direction = mode:match("^resize%-(.+)$")
        local west = direction:find("w", 1, true) ~= nil
        local north = direction:find("n", 1, true) ~= nil
        local corner = { x = start.cx + (west and -start.w or start.w) * 0.5,
            y = start.cy + (north and -start.h or start.h) * 0.5 }
        editor.drag = { kind = "roomResize", index = 1, mode = mode, start = start, adaptive = {} }
        editor.editorInteraction:Capture()
        Check(not EditorGesture.Apply(editor, corner.x, corner.y) and SameRoom(room, start),
            mode .. " changed room on press cycle " .. cycle)
        local inward = cycle % 2 == 0
        local pointer = {
            x = corner.x + (inward and (west and 1.2 or -1.2) or (west and -1.2 or 1.2)),
            y = corner.y + (inward and (north and 1.2 or -1.2) or (north and -1.2 or 1.2)),
        }
        local expected = RoomEditing.Resize(start, pointer, mode,
            editor.roomMinimumWidth, editor.roomMinimumHeight)
        Check(EditorGesture.Apply(editor, pointer.x, pointer.y) and SameRoom(room, expected),
            mode .. " did not follow pointer cycle " .. cycle)
        Check(not inward or (room.w < start.w and room.h < start.h),
            mode .. " did not shrink toward the room interior cycle " .. cycle)
        Check(EditorGesture.Finish(editor) and not editor.editorInteraction:IsCaptured(),
            mode .. " did not release cycle " .. cycle)
    end
    Check(editor.commits == 200, "not every gesture committed: " .. tostring(editor.commits))
    local defaultMinimum = RoomEditing.NormalizeRect({ x = 0, y = 0 }, { x = 1, y = 1 })
    local pcgMinimum = RoomEditing.NormalizeRect({ x = 0, y = 0 }, { x = 1, y = 1 }, 1, 1)
    Check(defaultMinimum.w == 5 and defaultMinimum.h == 5, "default minimum changed")
    Check(pcgMinimum.w == 1 and pcgMinimum.h == 1, "PCG minimum was not applied")
    return "PASS roomMove=100 roomResize=100 inward=50 corners=nw,ne,sw,se commits=200"
end

function Start()
    local ok, message = xpcall(RunRegression, debug.traceback)
    if not ok then
        WriteResult("FAIL " .. tostring(message))
        ErrorExit("[room-edit-test] FAIL\n" .. tostring(message), 1)
        return
    end
    WriteResult(message)
    print("[room-edit-test] " .. message)
    engine:Exit()
end
