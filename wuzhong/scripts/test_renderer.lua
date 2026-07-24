local DungeonGenerator = require("Generation.DungeonGenerator")
local NativeDungeonRenderer = require("Rendering.NativeDungeonRenderer")

---@type Scene|nil
local scene = nil
local elapsed = 0
local screenshotPath = ".tmp/renderer-smoke.png"

for _, argument in ipairs(GetArguments()) do
    local configuredPath = argument:match("^%-smoke_output=(.+)$")
    if configuredPath then
        screenshotPath = configuredPath
        break
    end
end

local function WriteSmokeResult(message)
    local result = File(screenshotPath .. ".result.txt", FILE_WRITE)
    if result:IsOpen() then
        result:WriteLine(message)
        result:Close()
    end
end

function Start()
    local ok, err = xpcall(function()
        scene = Scene()
        scene:CreateComponent("Octree")

        local zoneNode = scene:CreateChild("Zone")
        local zone = zoneNode:CreateComponent("Zone")
        zone.boundingBox = BoundingBox(Vector3(-1000, -1000, -1000), Vector3(1000, 1000, 1000))
        zone.ambientColor = Color(0.3, 0.38, 0.5, 1)
        zone.ambientIntensity = 1.25
        zone.fogColor = Color(0.08, 0.12, 0.2, 1)
        zone.fogStart = 450
        zone.fogEnd = 900

        local sunNode = scene:CreateChild("Sun")
        sunNode.rotation = Quaternion(52, -36, 0)
        local sun = sunNode:CreateComponent("Light")
        sun.lightType = LIGHT_DIRECTIONAL
        sun.color = Color(1, 0.9, 0.78, 1)
        sun.brightness = 1.3
        sun.castShadows = false

        local cameraNode = scene:CreateChild("Camera")
        cameraNode.position = Vector3(55, 52, -55)
        cameraNode:LookAt(Vector3(0, 2, 0))
        local camera = cameraNode:CreateComponent("Camera")
        camera.nearClip = 0.1
        camera.farClip = 1200
        renderer:SetViewport(0, Viewport:new(scene, camera))
        renderer.hdrRendering = false

        local dungeon = DungeonGenerator.Generate({
            seed = 1337, floorCount = 1, roomCountsByFloor = { 12 },
            settingKey = "hospital", theme = "sterile",
        })
        assert(dungeon.valid, table.concat(dungeon.errors, "; "))
        NativeDungeonRenderer.new(scene):Build(dungeon, "sterile", { settingKey = "hospital" })
        SubscribeToEvent("Update", "HandleRendererSmokeUpdate")
        print(string.format("[render-smoke] native hospital built rooms=%d floors=%d connectors=%d hash=%s",
            #dungeon.rooms, dungeon.floorCount, #dungeon.connectors, tostring(dungeon.hash)))
    end, debug.traceback)
    if not ok then
        WriteSmokeResult("FAIL startup\n" .. tostring(err))
        ErrorExit("[render-smoke] FAIL startup\n" .. tostring(err), 1)
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleRendererSmokeUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed >= 2.5 then
        local screenshot = Image()
        if not graphics:TakeScreenShot(screenshot)
            or not screenshot:SavePNG(screenshotPath) then
            WriteSmokeResult("FAIL screenshot capture")
            ErrorExit("[render-smoke] FAIL screenshot capture", 1)
            return
        end
        WriteSmokeResult("PASS native scene startup, geometry build, and 2.5s render loop")
        print("[render-smoke] PASS native scene startup and 2.5s render loop")
        UnsubscribeFromEvent("Update")
        engine:Exit()
    end
end
