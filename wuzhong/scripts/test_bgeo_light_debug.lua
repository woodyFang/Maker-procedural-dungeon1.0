local BgeoDungeonRenderer = require("Rendering.BgeoDungeonRenderer")

---@type Scene|nil
local scene = nil
---@type BgeoDungeonRenderer|nil
local bgeoRenderer = nil
local elapsed = 0
local screenshotPath = ".tmp/bgeo-light-debug.png"

function Start()
    local ok, err = xpcall(function()
        scene = Scene()
        scene:CreateComponent("Octree")
        local cameraNode = scene:CreateChild("Camera")
        cameraNode.position = Vector3(0, 0, -20)
        cameraNode:LookAt(Vector3.ZERO)
        local camera = cameraNode:CreateComponent("Camera")
        renderer:SetViewport(0, Viewport:new(scene, camera))

        bgeoRenderer = BgeoDungeonRenderer.new(scene)
        local parent = scene:CreateChild("LightTest")
        local light = bgeoRenderer:AddPointLight(parent, {
            point_light_offset_cm = { 0, 0, 0 },
            point_light_color_srgb = { 255, 136, 68 },
            point_light_intensity = 250,
            point_light_attenuation_radius = 800,
            point_light_cast_shadows = false,
        }, 12345)

        assert(#bgeoRenderer.lights == 1, "point light was not registered for debug drawing")
        assert(math.abs(light.range - 8.0) < 0.001, "point light radius conversion is incorrect")
        local visible, count = bgeoRenderer:SetLightDebugVisible(true)
        assert(visible and count == 1, "light debug state did not enable")
        assert(bgeoRenderer.lightDebugRoot ~= nil, "light debug geometry was not created")
        SubscribeToEvent("Update", "HandleLightDebugUpdate")
    end, debug.traceback)

    if not ok then
        ErrorExit("[bgeo-light-debug] FAIL\n" .. tostring(err), 1)
        return
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleLightDebugUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed < 1.0 then return end
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    local screenshot = Image()
    local saved = graphics:TakeScreenShot(screenshot) and screenshot:SavePNG(screenshotPath)
    screenshot:Dispose()
    if not saved then
        ErrorExit("[bgeo-light-debug] FAIL screenshot capture", 1)
        return
    end
    print("[bgeo-light-debug] PASS point position and radius debug geometry")
    UnsubscribeFromEvent("Update")
    engine:Exit()
end

function Stop()
    renderer:SetViewport(0, nil)
    if bgeoRenderer then bgeoRenderer:Dispose(); bgeoRenderer = nil end
    if scene then scene:Dispose(); scene = nil end
end
