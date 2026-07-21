local DungeonApp = require("App.DungeonApp")

---@type table|nil
local app = nil

function Start()
    app = DungeonApp.new()
    app:Start()
end

function Stop()
    if app then app:Stop() end
end
