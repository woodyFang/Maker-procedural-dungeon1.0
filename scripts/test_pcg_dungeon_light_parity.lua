local PCGDungeonRenderer = require("Rendering.PCGDungeonRenderer")

---@type Scene|nil
local scene = nil
---@type table|nil
local pcgDungeon = nil

local function Near(actual, expected, tolerance)
    return math.abs(actual - expected) <= (tolerance or 0.000001)
end

local function ColorKey(color)
    return string.format("%.6f %.6f %.6f", color.r, color.g, color.b)
end

local function ReadExactLights()
    for _, path in ipairs({
        "assets/PCGDungeon/PCGDungeon.lights.json",
        "PCGDungeon/PCGDungeon.lights.json",
    }) do
        if cache:Exists(path) then
            local file = assert(cache:GetFile(path), "could not open " .. path)
            local data = cjson.decode(file:ReadString())
            file:Close()
            return data, path
        end
    end
    error("PCGDungeon.lights.json was not found")
end

local function CountSceneLights(node, counts)
    local light = node:GetComponent("Light")
    if light then
        counts.total = counts.total + 1
        if light.lightType == LIGHT_DIRECTIONAL then counts.directional = counts.directional + 1 end
        if light.lightType == LIGHT_POINT then counts.point = counts.point + 1 end
    end
    for _, child in ipairs(node:GetChildren()) do CountSceneLights(child, counts) end
end

function Start()
    local ok, err = xpcall(function()
        scene = Scene()
        scene:CreateComponent("Octree")
        pcgDungeon = PCGDungeonRenderer.new(scene)
        local built, stats = pcgDungeon:Rebuild()
        assert(built, tostring(stats))
        assert(stats.lights == 366, "DungeonMap light count mismatch: " .. tostring(stats.lights))
        assert(stats.lightSource and stats.lightSource:find("PCGDungeon.lights.json", 1, true),
            "exact DungeonMap light manifest was not used: " .. tostring(stats.lightSource))
        print("[pcg-dungeon-light-parity] rebuilt 366 lights")

        local sceneCounts = { total = 0, directional = 0, point = 0 }
        CountSceneLights(scene, sceneCounts)
        assert(sceneCounts.total == 366 and sceneCounts.point == 366,
            string.format("scene light count mismatch total=%d point=%d", sceneCounts.total, sceneCounts.point))
        assert(sceneCounts.directional == 0, "PCG Dungeon retained an extra directional light")
        print("[pcg-dungeon-light-parity] scene count and types verified")

        local brightness, colors = {}, {}
        local shadowTrue, shadowFalse, functionCount = 0, 0, 0
        local minRange, maxRange = math.huge, -math.huge
        local exact = ReadExactLights()
        assert(#exact.lights == #pcgDungeon.lights, "exact light record count mismatch")
        for index, entry in ipairs(pcgDungeon.lights) do
            local light = entry.light
            local record = exact.lights[index]
            local profile = exact.profiles[record[4]]
            local position = entry.node.worldPosition
            assert(Near(position.x, record[1]) and Near(position.y, record[2]) and Near(position.z, record[3]),
                "position mismatch at light " .. index)
            assert(Near(light.color.r, profile.color[1]) and Near(light.color.g, profile.color[2])
                    and Near(light.color.b, profile.color[3]), "color mismatch at light " .. index)
            assert(Near(light.brightness, profile.brightness), "brightness mismatch at light " .. index)
            assert(Near(light.range, record[5]), "range mismatch at light " .. index)
            assert(light.castShadows == record[6], "shadow mismatch at light " .. index)
            local brightnessKey = string.format("%.2f", light.brightness)
            brightness[brightnessKey] = (brightness[brightnessKey] or 0) + 1
            local colorKey = ColorKey(light.color)
            colors[colorKey] = (colors[colorKey] or 0) + 1
            minRange, maxRange = math.min(minRange, light.range), math.max(maxRange, light.range)
            if light.castShadows then shadowTrue = shadowTrue + 1 else shadowFalse = shadowFalse + 1 end
            if entry.lightFunction then functionCount = functionCount + 1 end

            assert(light.usePhysicalValues, "point light is not using physical values")
            assert(light:GetAttribute("Light Units"):GetInt() == 0,
                "point light is not using Unitless units")
            assert(Near(light.radius, 0) and Near(light.length, 0), "point light is not punctual")
            assert(Near(light:GetAttribute("SoftRadius"):GetFloat(), 0),
                "point light soft radius mismatch")
            assert(light:GetAttribute("Punctual Light"):GetBool(),
                "point light did not enable punctual lighting")
            assert(light:GetAttribute("Affect Volumetric Fog"):GetBool(), "volumetric fog is disabled")
            assert(Near(light:GetAttribute("Volumetric Fog Intensity"):GetFloat(), 1),
                "volumetric fog intensity mismatch")
            assert(light:GetAttribute("Volumetric Fog Shadows"):GetBool() == light.castShadows,
                "volumetric fog shadow mismatch")
        end
        print("[pcg-dungeon-light-parity] per-light physical and volumetric attributes verified")
        print(string.format(
            "[pcg-dungeon-light-parity] distribution brightness=.01:%s,.03:%s shadows=%d/%d functions=%d range=%.6f..%.6f",
            tostring(brightness["0.01"]), tostring(brightness["0.03"]), shadowTrue, shadowFalse,
            functionCount, minRange, maxRange))
        for colorKey, colorCount in pairs(colors) do
            print(string.format("[pcg-dungeon-light-parity] color %s count=%d", colorKey, colorCount))
        end

        assert(brightness["0.01"] == 268 and brightness["0.03"] == 98,
            string.format("brightness distribution mismatch 0.01=%s 0.03=%s",
                tostring(brightness["0.01"]), tostring(brightness["0.03"])))
        assert(colors["1.000000 0.407240 0.147027"] == 98, "brazier color distribution mismatch")
        assert(colors["0.309469 0.623960 1.000000"] == 94, "blue palette A distribution mismatch")
        assert(colors["0.313989 0.456411 1.000000"] == 94, "blue palette B distribution mismatch")
        assert(colors["1.000000 0.597202 0.508881"] == 80, "warm palette distribution mismatch")
        assert(shadowTrue == 140 and shadowFalse == 226,
            string.format("shadow distribution mismatch true=%d false=%d", shadowTrue, shadowFalse))
        assert(functionCount == 98, "brazier light function count mismatch: " .. tostring(functionCount))
        assert(Near(minRange, 4.60891, 0.0001) and Near(maxRange, 21.5137, 0.0001),
            string.format("range distribution mismatch min=%.6f max=%.6f", minRange, maxRange))
        print("[pcg-dungeon-light-parity] exported parameter distributions verified")

        pcgDungeon:Update(1.0)
        local animated = 0
        for _, entry in ipairs(pcgDungeon.lights) do
            if entry.lightFunction and not Near(entry.light.brightness, entry.baseBrightness) then
                animated = animated + 1
            end
        end
        assert(animated == 98, "not all brazier light functions were updated: " .. tostring(animated))

        ErrorExit("[pcg-dungeon-light-parity] PASS total=366 directional=0 physical=366 functions=98", 0)
    end, debug.traceback)

    if not ok then ErrorExit("[pcg-dungeon-light-parity] FAIL\n" .. tostring(err), 1) end
end

function Stop()
    if pcgDungeon then pcgDungeon:Dispose() end
    if scene then scene:Dispose() end
    pcgDungeon, scene = nil, nil
end
