local DungeonApp = require("App.DungeonApp")

---@type table|nil
local app = nil
local elapsed = 0

function Start()
    app = DungeonApp.new()
    app:Start()
    app.panel:OpenCustomSettingModal()
    app.panel.customNameField:SetValue("现代学校")
    app.panel.customPromptField:SetValue("现代校园教室、图书馆和实验室，明亮耐用的公共建筑材质")
    app.panel.customBaseSettingDropdown:SetValue("school")
    app.panel:RefreshCustomSettingPlan()
    SubscribeToEvent("Update", "HandleThemePackStepTwoUpdate")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleThemePackStepTwoUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed >= 2.0 then
        local screenshot = Image()
        local saved = graphics:TakeScreenShot(screenshot) and screenshot:SavePNG(".tmp/theme-pack-one-page.png")
        screenshot:Dispose()
        if not saved then ErrorExit("[theme-pack-ui] FAIL one-page screenshot", 1); return end
        print("[theme-pack-ui] READY one-page input and generation plan visible")
        UnsubscribeFromEvent("Update")
        engine:Exit()
    end
end

function Stop()
    if app then app:Stop(); app = nil end
end
