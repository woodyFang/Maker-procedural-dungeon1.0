-- Integration proof: adding a floating (disconnected) region must survive the
-- editor rebuild as a secret room instead of rolling the whole edit back.
local DungeonApp = require("App.DungeonApp")
local EditorGesture = require("UI.Editor.EditorGesture")

---@type table|nil
local app = nil
local resultPath = ".tmp/add-floating-region.result.txt"

local function WriteResult(message)
    local result = File(resultPath, FILE_WRITE)
    if result and result:IsOpen() then result:WriteLine(message); result:Close() end
end

local function Fail(message)
    WriteResult("FAIL " .. tostring(message))
    ErrorExit("[add-floating-region] FAIL\n" .. tostring(message), 1)
end

local function CountRooms(editor)
    return #editor.rooms, #app.dungeon.rooms
end

function Start()
    local ok, message = xpcall(function()
        app = DungeonApp.new()
        app.seed = 15838
        app.floorCount = 2
        app.roomCounts = { 8, 8 }
        app:Start()
        app:ToggleEditor(true)
        local editor = app.editor3D
        if not editor or #editor.rooms == 0 then Fail("editor did not sync generated rooms") end
        local baseRooms = #editor.rooms

        -- Proof 1: context-menu "add region" far away from everything.
        editor:AddRoomAt(200, 200)
        local added = editor.rooms[#editor.rooms]
        if #editor.rooms ~= baseRooms + 1 then Fail("AddRoomAt did not append a room") end
        if added.roleHint ~= "secret" then
            Fail("AddRoomAt left the floating region as roleHint=" .. tostring(added.roleHint))
        end
        if not app:GenerateEditorWithRollback(false) then
            Fail("generation rolled back after AddRoomAt: " ..
                table.concat(app.dungeon.errors or {}, "; "))
        end
        local editorCount, dungeonCount = CountRooms(app.editor3D)
        if editorCount ~= baseRooms + 1 or dungeonCount ~= baseRooms + 1 then
            Fail(string.format("floating region lost after rebuild editor=%d dungeon=%d expected=%d",
                editorCount, dungeonCount, baseRooms + 1))
        end
        local survived = app.dungeon.rooms[#app.dungeon.rooms]
        if survived.type ~= "secret" then
            Fail("generated floating region is not a secret room: " .. tostring(survived.type))
        end

        -- Proof 2: drag-drawn region goes through the same gate.
        editor = app.editor3D
        local drawBase = #editor.rooms
        editor.draw = { gx = 230, gy = 230, ex = 240, ey = 238 }
        EditorGesture.Finish(editor, nil)
        if #editor.rooms ~= drawBase + 1 then Fail("draw gesture did not create a room") end
        if editor.rooms[#editor.rooms].roleHint ~= "secret" then
            Fail("drawn floating region was not marked secret")
        end
        if not app:GenerateEditorWithRollback(false) then
            Fail("generation rolled back after drawn region: " ..
                table.concat(app.dungeon.errors or {}, "; "))
        end
        if #app.editor3D.rooms ~= drawBase + 1 then Fail("drawn region lost after rebuild") end

        -- Proof 3: connecting a path clears the secret flag again.
        editor = app.editor3D
        local target = #editor.rooms
        editor.links[#editor.links + 1] = {
            a = 1, b = target, kind = "corridor", width = 2, bends = {}, autoRoute = {},
        }
        editor:NormalizeConnectedSecretRooms()
        if editor.rooms[target].roleHint == "secret" then
            Fail("connected region kept its secret flag")
        end
        editor:Commit()
        if not app:GenerateEditorWithRollback(false) then
            Fail("generation rolled back after connecting the region: " ..
                table.concat(app.dungeon.errors or {}, "; "))
        end

        WriteResult(string.format("PASS rooms=%d links=%d valid=%s",
            #app.editor3D.rooms, #app.editor3D.links, tostring(app.dungeon.valid)))
        print("[add-floating-region] PASS add + draw + connect lifecycle")
    end, debug.traceback)
    if not ok then Fail(message) end
    engine:Exit()
end

function Stop()
    if app then app:Stop(); app = nil end
end
