local DungeonApp = require("App.DungeonApp")

---@type table|nil
local app = nil
local elapsed = 0
local opened = false
local record = nil

function Start()
    app = DungeonApp.new()
    app:Start()
    record = {
        id = "context-preview", label = "现代学校", prompt = "现代学校",
        baseSettingKey = "school", packStatus = "ready",
    }
    app.customSettings = { record }
    app.panel:SetState(app:State())
    SubscribeToEvent("Update", "HandleThemePackContextUpdate")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleThemePackContextUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if not opened and elapsed >= 1.0 then
        opened = true
        app.panel:OpenCustomSettingContextMenu(record, { x = 250, y = 360 })
    end
    if elapsed >= 3.0 then
        print("[theme-pack-ui] READY context menu visible")
        UnsubscribeFromEvent("Update")
    end
end

function Stop()
    if app then app:Stop(); app = nil end
end
