-- Visual smoke: third-person preview should frame the scene like a Diablo
-- style action RPG (steep look-down angle). Saves a screenshot to inspect.
local DungeonApp = require("App.DungeonApp")

---@type table|nil
local app = nil
local settled = 0
local elapsed = 0
local resultPath = ".tmp/third-person-view.result.txt"

local function WriteResult(message)
    local result = File(resultPath, FILE_WRITE)
    if result and result:IsOpen() then result:WriteLine(message); result:Close() end
end

local function Fail(message)
    UnsubscribeFromEvent("Update")
    WriteResult("FAIL " .. tostring(message))
    ErrorExit("[third-person-view] FAIL\n" .. tostring(message), 1)
end

function Start()
    local ok, message = xpcall(function()
        app = DungeonApp.new()
        app.seed = 15838
        app.floorCount = 2
        app.roomCounts = { 10, 10 }
        app:Start()
        SubscribeToEvent("Update", "HandlePreviewSmokeUpdate")
    end, debug.traceback)
    if not ok then Fail(message) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandlePreviewSmokeUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed > 15 then Fail("preview never became active") end
    if not app.preview:IsActive() then
        if not app.forgeCamera:IsTransitioning() then app:ActivatePreview("third") end
        return
    end
    if app.preview.phase ~= "active" then return end
    settled = settled + eventData:GetFloat("TimeStep")
    if settled < 0.8 then return end

    local pitch = app.preview.orbitPitch
    if math.abs(pitch - math.rad(50)) > 0.001 then
        Fail(string.format("orbitPitch expected %.3f got %.3f", math.rad(50), pitch))
    end
    local screenshot = Image()
    if not graphics:TakeScreenShot(screenshot) or not screenshot:SavePNG(".tmp/third-person-view.png") then
        Fail("screenshot capture failed")
        return
    end
    WriteResult(string.format("PASS pitch=%.2f distance=%.1f yawDeg=%.0f",
        pitch, app.preview.distance, math.deg(app.preview.yaw)))
    print("[third-person-view] PASS")
    UnsubscribeFromEvent("Update")
    engine:Exit()
end

function Stop()
    if app then app:Stop(); app = nil end
end
