-- Built-in procedural themes.
-- These presets are authored rules: they never require an AI prompt or asset generation.

local FixedThemes = {}

FixedThemes.MODE_ID = "fixedPCG"
FixedThemes.GENERATION_MODE = "fixed-programmatic"

FixedThemes.order = {
    "shadowCastle",
    "frozenSanctum",
    "abandonedWard",
    "modernCampus",
}

FixedThemes.presets = {
    shadowCastle = {
        id = "shadowCastle",
        externalScene = "bgeoManifest",
        lightingEnabled = false,
        directionalLight = false,
        label = "暗影古堡",
        description = "狭长石室、低回环率、重装饰",
        icon = "castle",
        settingKey = "dungeon",
        themeKey = "grim",
        seed = 5,
        floorCount = 3,
        floorHeight = 5.0,
        minRoomCells = { 1, 1, 1 },
        maxRoomCells = { 3, 1, 3 },
        roomCount = 22,
        loopRate = 8,
        decorDensity = 72,
        ruleSummary = "固定石堡布局规则",
    },
    frozenSanctum = {
        id = "frozenSanctum",
        label = "冰封圣殿",
        description = "宽阔房间、寒冰色调、少量装饰",
        icon = "ice",
        settingKey = "dungeon",
        themeKey = "frost",
        floorHeight = 5.6,
        roomCount = 15,
        loopRate = 6,
        decorDensity = 38,
        ruleSummary = "固定冰窟布局规则",
    },
    abandonedWard = {
        id = "abandonedWard",
        label = "废弃病区",
        description = "密集房间、更多回环、医院结构",
        icon = "hospital",
        settingKey = "hospital",
        themeKey = "abandoned",
        floorHeight = 4.2,
        roomCount = 24,
        loopRate = 18,
        decorDensity = 64,
        ruleSummary = "固定病区布局规则",
    },
    modernCampus = {
        id = "modernCampus",
        label = "现代校园",
        description = "中等房间、明亮色调、校园结构",
        icon = "school",
        settingKey = "school",
        themeKey = "schoolDay",
        floorHeight = 5.0,
        roomCount = 21,
        loopRate = 14,
        decorDensity = 58,
        ruleSummary = "固定校园布局规则",
    },
}

function FixedThemes.Get(id)
    return FixedThemes.presets[id]
end

function FixedThemes.All()
    local result = {}
    for _, id in ipairs(FixedThemes.order) do
        result[#result + 1] = FixedThemes.presets[id]
    end
    return result
end

return FixedThemes
