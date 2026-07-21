local DungeonApp = require("App.DungeonApp")

---@type table|nil
local app = nil
local elapsed = 0
local phase = 0
local screenshotPath = ".tmp/upload-ui-smoke.png"

local function SaveScreenshot(path)
    local screenshot = Image()
    local saved = graphics:TakeScreenShot(screenshot) and screenshot:SavePNG(path)
    screenshot:Dispose()
    return saved
end

function Start()
    local ok, err = xpcall(function()
        app = DungeonApp.new()
        app:Start()
        app.panel:OpenCustomSettingModal(nil)
        SubscribeToEvent("Update", "HandleUploadUISmokeUpdate")
    end, debug.traceback)
    if not ok then ErrorExit("[upload-ui-smoke] FAIL\n" .. tostring(err), 1) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUploadUISmokeUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed < (phase == 0 and 2.5 or 1.0) then return end
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    if phase == 0 then
        if not SaveScreenshot(screenshotPath) then ErrorExit("[upload-ui-smoke] FAIL upload screenshot", 1); return end
        app.panel:OpenImageHistory("custom")
        phase, elapsed = 1, 0
        return
    end
    if not SaveScreenshot(".tmp/upload-history-smoke.png") then
        ErrorExit("[upload-ui-smoke] FAIL screenshot", 1)
        return
    end
    print("[upload-ui-smoke] PASS upload + history modals")
    UnsubscribeFromEvent("Update")
    engine:Exit()
end

function Stop()
    if app then app:Stop(); app = nil end
end
