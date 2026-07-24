-- Visual smoke: with nothing selected, stair gizmos must render above the
-- corridor canvas in the 3D editor. Saves a screenshot for manual inspection.
local DungeonApp = require("App.DungeonApp")

---@type table|nil
local app = nil
local elapsed = 0
local settled = 0
local resultPath = ".tmp/stair-top-layer.result.txt"

local function WriteResult(message)
    local result = File(resultPath, FILE_WRITE)
    if result and result:IsOpen() then result:WriteLine(message); result:Close() end
end

local function Fail(message)
    UnsubscribeFromEvent("Update")
    WriteResult("FAIL " .. tostring(message))
    ErrorExit("[stair-top-layer] FAIL\n" .. tostring(message), 1)
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
        SubscribeToEvent("Update", "HandleSmokeUpdate")
    end, debug.traceback)
    if not ok then Fail(message) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleSmokeUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    local editor = app and app.editor3D
    if not editor or not editor:IsVisible() then
        if elapsed > 12 then Fail("editor did not become visible") end
        return
    end
    settled = settled + eventData:GetFloat("TimeStep")
    if settled < 1.2 then return end

    local stairCount = 0
    for _, link in ipairs(editor.links) do
        if link.kind == "stairs" and link.connector then stairCount = stairCount + 1 end
    end
    if stairCount == 0 then Fail("seed produced no realized stair to inspect") end
    if editor.selectedLink then Fail("a link is unexpectedly selected") end

    local screenshot = Image()
    if not graphics:TakeScreenShot(screenshot) or not screenshot:SavePNG(".tmp/stair-top-layer.png") then
        Fail("screenshot capture failed")
        return
    end
    WriteResult(string.format("PASS stairs=%d floor=%d rooms=%d", stairCount, editor.floor, #editor.rooms))
    print("[stair-top-layer] PASS")
    UnsubscribeFromEvent("Update")
    engine:Exit()
end

function Stop()
    if app then app:Stop(); app = nil end
end
