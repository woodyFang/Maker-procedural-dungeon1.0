local BgeoDungeonRenderer = require("Rendering.BgeoDungeonRenderer")
local ForgeCameraController = require("Input.ForgeCameraController")

---@type Scene|nil
local scene = nil
---@type BgeoDungeonRenderer|nil
local bgeoRenderer = nil
local elapsed = 0

function Start()
    local ok, err = xpcall(function()
        scene = Scene()
        scene:CreateComponent("Octree")

        local lightGroup = scene:CreateChild("LightGroup")
        local lightFile = cache:GetResource("XMLFile", "LightGroup/Night.xml")
        assert(lightFile, "night light group was not found")
        lightGroup:LoadXML(lightFile:GetRoot())

        local cameraNode = scene:CreateChild("Camera")
        local camera = cameraNode:CreateComponent("Camera")
        camera.nearClip, camera.farClip, camera.fov = 0.1, 1000, 45
        renderer:SetViewport(0, Viewport:new(scene, camera))
        renderer.hdrRendering = true

        bgeoRenderer = BgeoDungeonRenderer.new(scene)
        local built, stats = bgeoRenderer:Rebuild()
        assert(built, tostring(stats))
        assert(stats.lights > 0, "dark castle generated no point lights")

        local controller = ForgeCameraController.new(cameraNode, camera)
        controller.defaultTarget = Vector3(0, 7.5, 0)
        controller.defaultDistance = 132
        controller:Reset()
        local visible, count = bgeoRenderer:SetLightDebugVisible(true)
        assert(visible and count == stats.lights, "not all generated lights were registered")
        SubscribeToEvent("Update", "HandleBgeoLightDebugSceneUpdate")
    end, debug.traceback)
    if not ok then ErrorExit("[bgeo-light-debug-scene] FAIL\n" .. tostring(err), 1) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleBgeoLightDebugSceneUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed < 3.0 then return end
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    local screenshot = Image()
    local saved = graphics:TakeScreenShot(screenshot)
        and screenshot:SavePNG(".tmp/bgeo-light-debug-scene.png")
    screenshot:Dispose()
    if not saved then ErrorExit("[bgeo-light-debug-scene] FAIL screenshot", 1); return end
    print("[bgeo-light-debug-scene] PASS")
    UnsubscribeFromEvent("Update")
    engine:Exit()
end

function Stop()
    renderer:SetViewport(0, nil)
    if bgeoRenderer then bgeoRenderer:Dispose(); bgeoRenderer = nil end
    if scene then scene:Dispose(); scene = nil end
end
