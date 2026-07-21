local DungeonApp = require("App.DungeonApp")

local function Check(condition, message)
    if not condition then error(message, 2) end
end

function Start()
    local ok, errorMessage = xpcall(function()
        local scene = Scene()
        local app = DungeonApp.new()
        app.scene = scene
        app.activeFixedThemeId = "shadowCastle"
        app.settingKey = "dungeon"
        app.themeKey = "grim"

        app:ApplyTheme()
        Check(app.zone ~= nil, "shadow castle lost its environment zone")
        Check(app.sun == nil, "shadow castle retained a directional light reference")
        Check(app.lightGroupNode:GetComponent("Light", true) == nil,
            "shadow castle retained a directional Light component")

        app.activeFixedThemeId = nil
        app:ApplyTheme()
        Check(app.sun ~= nil, "directional light was not restored after leaving shadow castle")
        Check(app.lightGroupNode:GetComponent("Light", true) ~= nil,
            "restored lighting preset has no directional Light component")

        scene:Dispose()
        print("[ShadowCastleLighting] PASS directional removed in castle and restored elsewhere")
    end, debug.traceback)
    if not ok then
        ErrorExit("[ShadowCastleLighting] FAIL\n" .. tostring(errorMessage), 1)
        return
    end
    engine:Exit()
end
