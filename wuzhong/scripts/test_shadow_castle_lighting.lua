local DungeonApp = require("App.DungeonApp")
local BgeoDungeonRenderer = require("Rendering.BgeoDungeonRenderer")

local function Check(condition, message)
    if not condition then error(message, 2) end
end

local function LightPositionSet(entries)
    local result = {}
    for _, entry in ipairs(entries or {}) do
        local position = entry.node.worldPosition
        result[string.format("%.4f|%.4f|%.4f", position.x, position.y, position.z)] = true
    end
    return result
end

local function SetsDiffer(a, b)
    for key in pairs(a) do if not b[key] then return true end end
    for key in pairs(b) do if not a[key] then return true end end
    return false
end

function Start()
    local ok, errorMessage = xpcall(function()
        local scene = Scene()
        scene:CreateComponent("Octree")
        local app = DungeonApp.new()
        app.scene = scene
        app.activeFixedThemeId = "shadowCastle"
        app.settingKey = "dungeon"
        app.themeKey = "grim"

        app:ApplyTheme()
        Check(app.zone ~= nil, "shadow castle lost its environment zone")
        Check(app.lightPreset == "LightGroup/Night.xml:environment-only",
            "shadow castle did not retain its Night material environment")
        local envSpec = app.zone:GetAttribute("Env Spec Texture"):GetResourceRef()
        Check(envSpec and envSpec.name == "Cube/Night/NightSpecularHDR.dds",
            "shadow castle lost the Night IBL specular texture")
        Check(math.abs(app.zone.ambientIntensity - 5.0) < 0.0001,
            "shadow castle environment intensity mismatch")
        Check(app.sun == nil, "shadow castle retained a directional light reference")
        Check(app.lightGroupNode:GetComponent("Light", true) == nil,
            "shadow castle retained a directional Light component")

        local bgeoRenderer = BgeoDungeonRenderer.new(scene)
        bgeoRenderer:SetLightingEnabled(true)
        local rebuilt, stats = bgeoRenderer:Rebuild()
        Check(rebuilt, "shadow castle BGEO rebuild failed: " .. tostring(stats))
        Check(stats.lights > 0, "shadow castle BGEO generated no local point lights")
        Check(bgeoRenderer.lights[1] and bgeoRenderer.lights[1].light.lightType == LIGHT_POINT,
            "shadow castle BGEO did not generate point lights")
        Check(app.lightGroupNode:GetComponent("Light", true) == nil,
            "shadow castle retained a directional Light component after BGEO rebuild")
        bgeoRenderer:Dispose()

        bgeoRenderer = BgeoDungeonRenderer.new(scene)
        app.bgeoRenderer = bgeoRenderer
        app.currentFloor = 0
        app.roomCounts = { 8, 7, 7 }
        local firstBuilt, firstStats = app:RefreshShadowCastle(false, { seed = 5, floorCount = 3 })
        Check(firstBuilt, "initial app-level Shadow Castle refresh failed: " .. tostring(firstStats))
        local firstHash = app.dungeon.hash
        local firstPositions = LightPositionSet(bgeoRenderer.lights)
        local debugEnabled = bgeoRenderer:SetLightDebugVisible(true)
        Check(debugEnabled and bgeoRenderer.lightDebugRoot ~= nil,
            "light debug geometry was not available before refresh")
        local firstDebugRoot = bgeoRenderer.lightDebugRoot

        local secondBuilt, secondStats = app:RefreshShadowCastle(false, { seed = 6, floorCount = 3 })
        Check(secondBuilt, "second app-level Shadow Castle refresh failed: " .. tostring(secondStats))
        Check(app.dungeon.hash ~= firstHash, "app-level refresh did not change the dungeon layout")
        Check(SetsDiffer(firstPositions, LightPositionSet(bgeoRenderer.lights)),
            "app-level refresh did not update point-light transforms")
        Check(bgeoRenderer.lightDebugVisible and bgeoRenderer.lightDebugRoot ~= nil
                and bgeoRenderer.lightDebugRoot ~= firstDebugRoot,
            "app-level refresh did not rebuild point-light debug geometry")
        Check(secondStats.lights == #bgeoRenderer.lights,
            "app-level refresh reported a stale point-light count")
        bgeoRenderer:SetLightDebugVisible(false)

        app.activeFixedThemeId = nil
        Check(app:ClearInactiveBgeoScene(),
            "leaving shadow castle did not clear the inactive BGEO scene")
        Check(bgeoRenderer.root == nil and bgeoRenderer.stats == nil
                and #bgeoRenderer.groups == 0 and #bgeoRenderer.lights == 0,
            "shadow castle renderer retained assets or point lights")
        Check(bgeoRenderer.lightDebugRoot == nil and bgeoRenderer.cellDebugRoot == nil,
            "shadow castle renderer retained debug geometry")
        Check(scene:GetChild("BgeoDungeon", true) == nil,
            "scene retained the Shadow Castle BGEO root")
        app:ApplyTheme()
        Check(app.sun ~= nil, "directional light was not restored after leaving shadow castle")
        Check(app.lightGroupNode:GetComponent("Light", true) ~= nil,
            "restored lighting preset has no directional Light component")

        scene:Dispose()
        ErrorExit("[ShadowCastleLighting] PASS local point lights, no directional sun, and preset restore", 0)
    end, debug.traceback)
    if not ok then
        ErrorExit("[ShadowCastleLighting] FAIL\n" .. tostring(errorMessage), 1)
        return
    end
end
