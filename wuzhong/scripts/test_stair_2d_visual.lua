local DungeonApp = require("App.DungeonApp")

---@type table|nil
local app = nil
local elapsed = 0
local selected = false
local screenshotPath = ".tmp/stair-2d-fixed.png"

local function Fail(message)
    ErrorExit("[stair-2d-visual] FAIL\n" .. tostring(message), 1)
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
        SubscribeToEvent("Update", "HandleStair2DVisualUpdate")
    end, debug.traceback)
    if not ok then Fail(message) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleStair2DVisualUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    local editor = app and app.editor2D
    if not selected and editor and editor:IsVisible() and editor.canvas then
        for index, link in ipairs(editor.links) do
            local a, b = editor.rooms[link.a], editor.rooms[link.b]
            if link.kind == "stairs" and link.connector and a and b
                and (a.floor == editor.floor or b.floor == editor.floor) then
                editor.selected, editor.selectedLink = nil, index
                editor:NotifySelection()
                selected, elapsed = true, 0
                break
            end
        end
        if not selected then Fail("no visible generated stair") end
    elseif selected and elapsed > 0.6 then
        local screenshot = Image()
        if not graphics:TakeScreenShot(screenshot) or not screenshot:SavePNG(screenshotPath) then
            Fail("screenshot capture failed")
            return
        end
        print("[stair-2d-visual] PASS screenshot=" .. screenshotPath)
        UnsubscribeFromEvent("Update")
        engine:Exit()
    elseif elapsed > 12 then Fail("visual verification timed out") end
end

function Stop()
    if app then app:Stop(); app = nil end
end
