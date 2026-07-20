local DungeonGenerator = require("Generation.DungeonGenerator")
local NativeDungeonRenderer = require("Rendering.NativeDungeonRenderer")
local Themes = require("Config.Themes")
local ThemePacks = require("Config.ThemePacks")
local LocalRequirementPlanner = require("AI.LocalRequirementPlanner")

---@type Scene|nil
local scene = nil
local elapsed = 0
local captureAttempted = false
local screenshotPath = ".tmp/school-renderer-smoke.png"
local holdVisual = false

for _, argument in ipairs(GetArguments()) do
    local configuredPath = argument:match("^%-smoke_output=(.+)$")
    if configuredPath then
        screenshotPath = configuredPath
    elseif argument == "-hold_visual" then
        holdVisual = true
    end
end

local function HexColor(hex, alpha)
    return Color(
        ((hex >> 16) & 0xff) / 255,
        ((hex >> 8) & 0xff) / 255,
        (hex & 0xff) / 255,
        alpha or 1.0)
end

local function WriteResult(message)
    local result = File(screenshotPath .. ".result.txt", FILE_WRITE)
    if result and result:IsOpen() then
        result:WriteLine(message)
        result:Close()
    end
end

local function CountProps(dungeon)
    local count = 0
    for _, layer in ipairs(dungeon.layers or {}) do
        count = count + #(layer.props or {})
    end
    return count
end

function Start()
    local ok, err = xpcall(function()
        local theme = Themes.Get("schoolDay")
        scene = Scene()
        scene:CreateComponent("Octree")

        local zoneNode = scene:CreateChild("Zone")
        local zone = zoneNode:CreateComponent("Zone")
        zone.boundingBox = BoundingBox(Vector3(-1000, -1000, -1000), Vector3(1000, 1000, 1000))
        zone.ambientSource = AMBIENT_COLOR
        zone.ambientGradient = true
        zone.ambientStartColor = HexColor(theme.sky)
        zone.ambientEndColor = HexColor(theme.ground)
        zone.ambientColor = HexColor(theme.sky)
        zone.ambientIntensity = theme.ambient
        zone.fogColor = HexColor(theme.fog)
        zone.fogStart = 350
        zone.fogEnd = 850

        local sunNode = scene:CreateChild("Sun")
        sunNode.rotation = Quaternion(52, -36, 0)
        local sun = sunNode:CreateComponent("Light")
        sun.lightType = LIGHT_DIRECTIONAL
        sun.color = HexColor(theme.sun)
        sun.brightness = theme.sunIntensity
        sun.castShadows = true
        sun.shadowBias = BiasParameters(0.00025, 0.5)

        local cameraNode = scene:CreateChild("Camera")
        cameraNode.position = Vector3(49, 58, -49)
        cameraNode:LookAt(Vector3(0, 1.6, 0))
        local camera = cameraNode:CreateComponent("Camera")
        camera.nearClip = 0.1
        camera.farClip = 1200
        camera.fov = 42
        renderer:SetViewport(0, Viewport:new(scene, camera))
        renderer.hdrRendering = false

        local plan, planReason = LocalRequirementPlanner.Compile({
            id = "renderer-school", label = "学校",
            prompt = "教室、图书馆、实验室、食堂和大厅",
        }, ThemePacks.Get("school"), 1)
        assert(plan, planReason)
        local dungeon = DungeonGenerator.Generate({
            seed = 1337,
            floorCount = 1,
            roomCountsByFloor = { 12 },
            decorDensitiesByFloor = { 0.78 },
            settingKey = "school",
            theme = "schoolDay",
            roomGroups = plan.roomGroups,
        })
        assert(dungeon.valid, table.concat(dungeon.errors, "; "))
        NativeDungeonRenderer.new(scene):Build(dungeon, "schoolDay", { settingKey = "school" })
        SubscribeToEvent("Update", "HandleSchoolRendererUpdate")
        print(string.format("[school-render-smoke] built rooms=%d groups=%d props=%d hash=%s",
            #dungeon.rooms, #plan.roomGroups, CountProps(dungeon), tostring(dungeon.hash)))
    end, debug.traceback)
    if not ok then
        WriteResult("FAIL startup\n" .. tostring(err))
        ErrorExit("[school-render-smoke] FAIL startup\n" .. tostring(err), 1)
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleSchoolRendererUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed >= 3.0 and not captureAttempted then
        captureAttempted = true
        if holdVisual then
            print("[school-render-smoke] READY school ThemePack visual held for host capture")
            return
        end
        UnsubscribeFromEvent("Update")
        local screenshot = Image()
        if not graphics:TakeScreenShot(screenshot) or not screenshot:SavePNG(screenshotPath) then
            WriteResult("FAIL screenshot capture")
            ErrorExit("[school-render-smoke] FAIL screenshot capture", 1)
            return
        end
        WriteResult("PASS school ThemePack generation, geometry build, PBR render, and 3s frame loop")
        print("[school-render-smoke] PASS school ThemePack render")
        engine:Exit()
    end
end
