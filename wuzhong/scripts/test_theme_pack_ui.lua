local DungeonApp = require("App.DungeonApp")

---@type table|nil
local app = nil
local elapsed = 0

function Start()
    app = DungeonApp.new()
    app:Start()
    app.panel:OpenCustomSettingModal()
    app.panel.customNameField:SetValue("现代学校")
    app.panel.customBaseSettingDropdown:SetValue("school")
    app.panel.customPromptField:SetValue("现代校园教室、图书馆和实验室，明亮耐用的公共建筑材质")
    SubscribeToEvent("Update", "HandleThemePackUIUpdate")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleThemePackUIUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed >= 2.0 then
        print("[theme-pack-ui] READY step one description form visible")
        UnsubscribeFromEvent("Update")
    end
end

function Stop()
    if app then app:Stop(); app = nil end
end
