-- 神殿遗迹 (temple) smoke test: regenerates + rebuilds the temple setting for
-- every palette (pools / lakes / graves are generation-time features), mirrors
-- the app's Night lighting preset and theme environment, verifies the
-- AtmosphereFX layer, runs the live update loop and captures one screenshot
-- per palette.
local DungeonGenerator = require("Generation.DungeonGenerator")
local NativeDungeonRenderer = require("Rendering.NativeDungeonRenderer")
local Themes = require("Config.Themes")

-- Sandbox: File()/SavePNG reject absolute paths; relative output lands in the
-- runtime savedata directory (…/temp/savedata/<id>/.tmp/).
local OUTPUT_DIR = ".tmp/"
local SETTING = "temple"
local PALETTES = { "templeGold", "templeMagma", "templeFrost", "templeGrim", "templeVine" }
local SETTLE_SECONDS = 2.4

---@type Scene|nil
local scene = nil
---@type Zone|nil
local zone = nil
---@type Light|nil
local sun = nil
---@type table
local dungeonRenderer = nil
local paletteIndex = 0
local elapsed = 0
local report = {}

local function HexColor(value, brightness)
    local factor = brightness or 1
    return Color(
        math.min(1, ((value >> 16) & 0xff) / 255 * factor),
        math.min(1, ((value >> 8) & 0xff) / 255 * factor),
        math.min(1, (value & 0xff) / 255 * factor), 1)
end

local function WriteResult(message)
    local result = File(OUTPUT_DIR .. "ruins-smoke.result.txt", FILE_WRITE)
    if result and result:IsOpen() then
        result:WriteLine(message)
        result:Close()
    end
end

local function BuildPalette(key)
    local theme = Themes.Resolve(SETTING, key)
    zone.fogColor = HexColor(theme.fog, 1.0)
    zone.fogStart, zone.fogEnd = 0, 1000
    zone.fogDensity = theme.fogDensity
    zone.ambientSource = AMBIENT_COLOR
    zone.ambientGradient = true
    zone.ambientStartColor = HexColor(theme.sky, 1.0)
    zone.ambientEndColor = HexColor(theme.ground, 1.0)
    zone.ambientColor = HexColor(theme.sky, 1.0)
    zone.ambientIntensity = theme.ambient
    zone.autoExposureEnabled = false
    zone.bloomPlusEnabled = theme.bloom == true
    sun.color = HexColor(theme.sun, 1.0)
    sun.brightness = theme.sunIntensity
    sun.castShadows = true

    -- Pools / lakes / graveyards are carved at generation time from the theme,
    -- so each palette gets its own generate + build (matching a user pressing
    -- generate after picking the palette).
    local dungeon = DungeonGenerator.Generate({
        seed = 20260724, floorCount = 1, roomCountsByFloor = { 14 },
        settingKey = SETTING, theme = key,
    })
    assert(dungeon.valid, key .. ": " .. table.concat(dungeon.errors or {}, "; "))
    dungeonRenderer:Build(dungeon, key, { settingKey = SETTING })
    local fx = dungeonRenderer.atmosphere
    assert(fx ~= nil, key .. ": atmosphere fx missing")
    assert(#fx.particles > 0, key .. ": no ambient particles")
    local line = string.format(
        "[ruins-smoke] %s particles=%d rays=%d spinners=%d orbiters=%d bobbers=%d wisps=%d pulse=%s nodes=%d",
        key, #fx.particles, #fx.rays, #fx.spinners, #fx.orbiters, #fx.bobbers, #fx.wisps,
        tostring(fx.pulse ~= nil), fx.nodeCount)
    print(line)
    report[#report + 1] = line
end

function Start()
    local ok, err = xpcall(function()
        scene = Scene()
        scene:CreateComponent("Octree")

        -- Mirror DungeonApp:LoadLightingPreset — the dungeon setting uses the
        -- Night light group; fall back to a bare zone + sun if it is missing.
        local lightGroup = scene:CreateChild("LightGroup")
        local presetFile = cache:GetResource("XMLFile", "LightGroup/Night.xml")
        if presetFile then
            lightGroup:LoadXML(presetFile:GetRoot())
            zone = lightGroup:GetComponent("Zone", true)
            sun = lightGroup:GetComponent("Light", true)
        end
        if not zone then
            zone = lightGroup:CreateComponent("Zone")
            zone.boundingBox = BoundingBox(Vector3(-1000, -1000, -1000), Vector3(1000, 1000, 1000))
            local sunNode = lightGroup:CreateChild("Sun")
            sunNode.rotation = Quaternion(52, -36, 0)
            sun = sunNode:CreateComponent("Light")
            sun.lightType = LIGHT_DIRECTIONAL
        end

        local cameraNode = scene:CreateChild("Camera")
        cameraNode.position = Vector3(34, 26, -34)
        cameraNode:LookAt(Vector3(0, 1, 0))
        local camera = cameraNode:CreateComponent("Camera")
        camera.nearClip = 0.1
        camera.farClip = 1200
        renderer:SetViewport(0, Viewport:new(scene, camera))

        dungeonRenderer = NativeDungeonRenderer.new(scene)
        paletteIndex = 1
        BuildPalette(PALETTES[paletteIndex])
        SubscribeToEvent("Update", "HandleRuinsSmokeUpdate")
    end, debug.traceback)
    if not ok then
        WriteResult("FAIL startup\n" .. tostring(err))
        ErrorExit("[ruins-smoke] FAIL startup\n" .. tostring(err), 1)
    end
end

local captureArmedAt = nil

---@param eventType string
---@param eventData UpdateEventData
function HandleRuinsSmokeUpdate(eventType, eventData)
    local ok, err = xpcall(function()
        local timeStep = eventData:GetFloat("TimeStep")
        elapsed = elapsed + timeStep
        dungeonRenderer:Update(timeStep)
        if elapsed < SETTLE_SECONDS then return end

        -- The BloomHDRPlus chain blocks backbuffer readback, so drop to the
        -- plain path for a few frames around the capture.
        if not captureArmedAt then
            zone.bloomPlusEnabled = false
            captureArmedAt = elapsed
            return
        end
        if elapsed - captureArmedAt < 0.2 then return end

        local palette = PALETTES[paletteIndex]
        local screenshot = Image()
        assert(graphics:TakeScreenShot(screenshot), palette .. ": screenshot capture failed")
        assert(screenshot:SavePNG(OUTPUT_DIR .. "ruins-smoke-" .. palette .. ".png"),
            palette .. ": screenshot save failed")
        print("[ruins-smoke] captured " .. palette)

        paletteIndex = paletteIndex + 1
        elapsed = 0
        captureArmedAt = nil
        if paletteIndex > #PALETTES then
            UnsubscribeFromEvent("Update")
            WriteResult("PASS\n" .. table.concat(report, "\n"))
            print("[ruins-smoke] PASS all palettes")
            engine:Exit()
            return
        end
        BuildPalette(PALETTES[paletteIndex])
    end, debug.traceback)
    if not ok then
        WriteResult("FAIL update\n" .. tostring(err))
        ErrorExit("[ruins-smoke] FAIL update\n" .. tostring(err), 1)
    end
end
