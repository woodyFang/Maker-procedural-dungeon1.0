local DungeonApp = require("App.DungeonApp")
local PCGDungeonRenderer = require("Rendering.PCGDungeonRenderer")

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

        local pcgDungeonRenderer = PCGDungeonRenderer.new(scene)
        pcgDungeonRenderer:SetLightingEnabled(true)
        local rebuilt, stats = pcgDungeonRenderer:Rebuild()
        Check(rebuilt, "shadow castle PCG Dungeon rebuild failed: " .. tostring(stats))
        Check(stats.lights > 0, "shadow castle PCG Dungeon generated no local point lights")
        Check(pcgDungeonRenderer.lights[1] and pcgDungeonRenderer.lights[1].light.lightType == LIGHT_POINT,
            "shadow castle PCG Dungeon did not generate point lights")
        Check(app.lightGroupNode:GetComponent("Light", true) == nil,
            "shadow castle retained a directional Light component after PCG Dungeon rebuild")
        pcgDungeonRenderer:Dispose()

        pcgDungeonRenderer = PCGDungeonRenderer.new(scene)
        app.pcgDungeonRenderer = pcgDungeonRenderer
        app.currentFloor = 0
        app.roomCounts = { 8, 7, 7 }
        local firstBuilt, firstStats = app:RefreshPCGDungeon(false, { seed = 5, floorCount = 3 })
        Check(firstBuilt, "initial app-level Shadow Castle refresh failed: " .. tostring(firstStats))
        local firstHash = app.dungeon.hash
        local firstPositions = LightPositionSet(pcgDungeonRenderer.lights)
        local debugEnabled = pcgDungeonRenderer:SetLightDebugVisible(true)
        Check(debugEnabled and pcgDungeonRenderer.lightDebugRoot ~= nil,
            "light debug geometry was not available before refresh")
        local firstDebugRoot = pcgDungeonRenderer.lightDebugRoot

        local secondBuilt, secondStats = app:RefreshPCGDungeon(false, { seed = 6, floorCount = 3 })
        Check(secondBuilt, "second app-level Shadow Castle refresh failed: " .. tostring(secondStats))
        Check(app.dungeon.hash ~= firstHash, "app-level refresh did not change the dungeon layout")
        Check(SetsDiffer(firstPositions, LightPositionSet(pcgDungeonRenderer.lights)),
            "app-level refresh did not update point-light transforms")
        Check(pcgDungeonRenderer.lightDebugVisible and pcgDungeonRenderer.lightDebugRoot ~= nil
                and pcgDungeonRenderer.lightDebugRoot ~= firstDebugRoot,
            "app-level refresh did not rebuild point-light debug geometry")
        Check(secondStats.lights == #pcgDungeonRenderer.lights,
            "app-level refresh reported a stale point-light count")
        pcgDungeonRenderer:SetLightDebugVisible(false)

        app.activeFixedThemeId = nil
        Check(app:ClearInactivePCGDungeonScene(),
            "leaving shadow castle did not clear the inactive PCG Dungeon scene")
        Check(pcgDungeonRenderer.root == nil and pcgDungeonRenderer.stats == nil
                and #pcgDungeonRenderer.groups == 0 and #pcgDungeonRenderer.lights == 0,
            "shadow castle renderer retained assets or point lights")
        Check(pcgDungeonRenderer.lightDebugRoot == nil and pcgDungeonRenderer.cellDebugRoot == nil,
            "shadow castle renderer retained debug geometry")
        Check(scene:GetChild("PCGDungeon", true) == nil,
            "scene retained the Shadow Castle PCG Dungeon root")
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
