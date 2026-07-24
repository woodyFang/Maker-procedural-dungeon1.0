local PaletteData = require("Config.PaletteData")

local Themes = {}

Themes.settings = {
    dungeon = { key = "dungeon", label = "遗迹", description = "石质建筑与地下空间",
        themePalettes = {} },
    hospital = { key = "hospital", label = "医院", description = "现代医疗建筑与设施",
        themePalettes = { "sterile", "abandoned", "emergency" } },
    school = { key = "school", label = "学校", description = "教室、图书馆与校园设施",
        themePalettes = { "schoolDay", "schoolClassic", "schoolEvening" } },
}
Themes.defaultPalettes = { "ancient", "molten", "frost", "grim", "verdant" }
Themes.settingOrder = { "dungeon", "hospital", "school" }
Themes.order = { "ancient", "molten", "frost", "grim", "verdant", "sterile", "abandoned", "emergency",
    "schoolDay", "schoolClassic", "schoolEvening" }

local function Theme(key, label, accent, background, sky, ground, ambient, sun, sunIntensity,
    floor, corridor, wall, pillar, accentObject, flame, flameCore)
    return {
        key = key, label = label, accent = accent,
        background = background, fog = background, fogDensity = 0.0025,
        sky = sky, ground = ground, ambient = ambient,
        sun = sun, sunIntensity = sunIntensity,
        floor = floor, corridor = corridor, wall = wall,
        pillar = pillar, accentObject = accentObject,
        flame = flame, flameCore = flameCore,
    }
end

Themes.ancient = Theme("ancient", "暖灰", 0xe8973f, 0x07080d, 0x2e3a52, 0x0a0b10, 0.55, 0xffe8c8, 0.85,
    0x8a8f9c, 0x6d7380, 0x5c626e, 0x6a707e, 0xd9a441, 0xffa640, 0xfff3c8)
Themes.molten = Theme("molten", "暖橙", 0xff8642, 0x0c0605, 0x6b3419, 0x160503, 0.55, 0xffd9b0, 0.5,
    0x7a685c, 0x614f44, 0x503e34, 0x5e4a3e, 0xff5a1f, 0xff8c26, 0xffe9b0)
Themes.frost = Theme("frost", "冷蓝", 0x7fd4ff, 0x060a12, 0x3a5a80, 0x0a0e18, 0.5, 0xcfe4ff, 0.82,
    0x93a0b2, 0x78848f, 0x60708a, 0x70809a, 0xbfe4ff, 0x86d9ff, 0xe8f7ff)
Themes.grim = Theme("grim", "暗绿", 0x9fe66a, 0x070a07, 0x2c4030, 0x070a06, 0.52, 0xbfd8b0, 0.45,
    0x7c8276, 0x62685c, 0x4f5549, 0x5c6254, 0x41602c, 0x8fe05a, 0xe9ffd0)
Themes.verdant = Theme("verdant", "青绿", 0x59d68f, 0x060c09, 0x2f5a46, 0x08120c, 0.6, 0xd8f0c8, 0.8,
    0x848e7e, 0x6a7560, 0x556050, 0x606c5c, 0x2fa38a, 0x62e0a8, 0xe6fff0)
Themes.sterile = Theme("sterile", "冷白", 0x5fd1c7, 0x05090a, 0x6f8f8a, 0x050909, 0.42, 0xb7d6cf, 0.48,
    0x7d8884, 0x697572, 0x5b6662, 0x66716d, 0x5fd1c7, 0x5fd1c7, 0xcffaf3)
Themes.abandoned = Theme("abandoned", "灰绿", 0x79b65f, 0x050807, 0x47654d, 0x050806, 0.44, 0xa9c39b, 0.5,
    0x747c72, 0x626c63, 0x535c53, 0x60685d, 0x79b65f, 0x83d86b, 0xe8ffd8)
Themes.emergency = Theme("emergency", "警示红", 0xff5b4f, 0x0a0607, 0x7a4544, 0x080505, 0.42, 0xffc1b8, 0.52,
    0x756e6e, 0x675f5f, 0x5d5353, 0x695b59, 0xff5b4f, 0xff6d5f, 0xffeee8)
Themes.schoolDay = Theme("schoolDay", "晴日青", 0x3f9b84, 0x101719, 0x7d9597, 0x18201e, 0.38, 0xd7e0d4, 0.47,
    0x919e98, 0x84928a, 0x9ca7a0, 0x929e96, 0x3f9b84, 0xd7bd8e, 0xd9e1c7)
Themes.schoolClassic = Theme("schoolClassic", "学院绿", 0x356f52, 0x121713, 0x788a7d, 0x1c211c, 0.37, 0xd4c6a6, 0.45,
    0x918571, 0x837a66, 0x9c968b, 0x918c7e, 0x356f52, 0xd6b789, 0xd8c9a7)
Themes.schoolEvening = Theme("schoolEvening", "放学橙", 0xe0a545, 0x11151b, 0x5e6d7a, 0x17191f, 0.36, 0xc9b39a, 0.42,
    0x707d81, 0x667279, 0x828c8b, 0x737f7f, 0xe0a545, 0xc7a16c, 0xcbb58d)

-- Rendering values are kept byte-for-byte with the Three.js palette specs.
-- The compact constructor above supplies UI-friendly defaults; this table
-- restores fields used by procedural generation and model colouring.
local exact = {
    ancient = { fog = 0x07080d, fogDensity = 0.0021, cap = 0x757b88, debris = { 0x4c515e, 0x60584a },
        cloth = 0x7d2c26, torchLight = { 0xff8c3a, 1.5, 9.5 }, particles = { kind = 0, color = 0xaab4cc, n = 110 } },
    molten = { fog = 0x1a0b04, fogDensity = 0.0028, cap = 0x6b5546, debris = { 0x4a382e, 0x60462f },
        cloth = 0x7d2416, torchLight = { 0xff7326, 1.7, 10 },
        pools = { mode = 0, colA = 0x2b0d05, colB = 0xff5a1f, glow = 1.55, amount = 0.16, pits = 2 },
        particles = { kind = 1, color = 0xffa050, n = 240 } },
    frost = { fog = 0x0b1522, fogDensity = 0.0024, cap = 0x8194ac, debris = { 0x55617a, 0x6d7a90 },
        cloth = 0x2b4d70, torchLight = { 0x6fc4ff, 1.35, 9.5 },
        pools = { mode = 1, colA = 0x4a86c0, colB = 0xbfe4ff, glow = 0.55, amount = 0 },
        lakes = true, icicles = true, particles = { kind = 2, color = 0xdff0ff, n = 260 } },
    grim = { fog = 0x0a130a, fogDensity = 0.0030, cap = 0x666c5e, debris = { 0x4a4f44, 0x5e5c48 },
        cloth = 0x33461f, torchLight = { 0x77d94a, 1.35, 9 },
        pools = { mode = 3, colA = 0x0a1207, colB = 0x41602c, glow = 0.6, amount = 0.05, pits = 1 },
        graveyards = true, bones = true, particles = { kind = 3, color = 0x9fe66a, n = 150 } },
    verdant = { fog = 0x091510, fogDensity = 0.0023, cap = 0x6e7a66, debris = { 0x49543f, 0x5c644c },
        cloth = 0x1f5038, torchLight = { 0x4ad98e, 1.3, 9 },
        pools = { mode = 2, colA = 0x0c3532, colB = 0x2fa38a, glow = 0.6, amount = 0.05, pits = 1 },
        roots = true, shafts = true, particles = { kind = 4, color = 0x8fe6b8, n = 200 } },
    sterile = { fog = 0x071011, fogDensity = 0.0025, floor = 0x6f7975, corridor = 0x626d69,
        ambient = 0.48, sunIntensity = 0.58,
        wall = 0x56615d, cap = 0x78837f, pillar = 0x5d6865, debris = { 0x434b49, 0x747f7b },
        cloth = 0x1f6f66, torchLight = { 0x58c8bf, 0.62, 7.5 },
        pools = { mode = 2, colA = 0x071918, colB = 0x2f8f86, glow = 0.22, amount = 0.025, pits = 1 },
        particles = { kind = 0, color = 0xa9d8d1, n = 120 } },
    abandoned = { fog = 0x08100b, fogDensity = 0.0029, floor = 0x687067, corridor = 0x5c655d,
        ambient = 0.48, sunIntensity = 0.62,
        wall = 0x515951, cap = 0x737b72, pillar = 0x596156, debris = { 0x3f473d, 0x6d705d },
        cloth = 0x2b5730, torchLight = { 0x72c95d, 0.75, 8 },
        pools = { mode = 3, colA = 0x071008, colB = 0x36562e, glow = 0.38, amount = 0.045, pits = 1 },
        bones = true, particles = { kind = 3, color = 0xa2df88, n = 140 } },
    emergency = { fog = 0x14090a, fogDensity = 0.0026, floor = 0x6f6868, corridor = 0x625c5c,
        ambient = 0.46, sunIntensity = 0.62,
        wall = 0x5a5050, cap = 0x7c7371, pillar = 0x625654, debris = { 0x493f3e, 0x7d6c66 },
        cloth = 0x8c2f2a, torchLight = { 0xff4d42, 0.85, 8.5 },
        pools = { mode = 3, colA = 0x160706, colB = 0x74322d, glow = 0.45, amount = 0.035, pits = 1 },
        particles = { kind = 0, color = 0xffb3aa, n = 120 } },
    schoolDay = { fog = 0x101719, fogDensity = 0.0018, floor = 0x919e98, corridor = 0x84928a,
        wall = 0x9ca7a0, cap = 0xacb5ae, pillar = 0x929e96, ambient = 0.48, sunIntensity = 0.60,
        debris = { 0x65716c, 0x8b7558 }, cloth = 0x356f52,
        torchLight = { 0xd7bd8e, 0.58, 8.0 }, particles = { kind = 0, color = 0xb8c8bf, n = 80 } },
    schoolClassic = { fog = 0x121713, fogDensity = 0.0020, floor = 0x918571, corridor = 0x837a66,
        wall = 0x9c968b, cap = 0xaea898, pillar = 0x918c7e, ambient = 0.47, sunIntensity = 0.58,
        debris = { 0x625d50, 0x80613f }, cloth = 0x2e6047,
        torchLight = { 0xd6b789, 0.60, 8.0 }, particles = { kind = 0, color = 0xc4bca8, n = 80 } },
    schoolEvening = { fog = 0x11151b, fogDensity = 0.0022, floor = 0x707d81, corridor = 0x667279,
        wall = 0x828c8b, cap = 0x979d98, pillar = 0x737f7f, ambient = 0.46, sunIntensity = 0.56,
        debris = { 0x535b5e, 0x765f47 }, cloth = 0x8a5d2d,
        torchLight = { 0xc7a16c, 0.64, 8.5 }, particles = { kind = 0, color = 0xaeb8bd, n = 90 } },
}
for key, values in pairs(exact) do
    for field, value in pairs(values) do Themes[key][field] = value end
end

local BUILTIN_ORDER = {}
for index, key in ipairs(Themes.order) do BUILTIN_ORDER[index] = key end
local BUILTIN_DEFAULT_PALETTES = {}
for index, palette in ipairs(Themes.defaultPalettes) do BUILTIN_DEFAULT_PALETTES[index] = palette end
local BUILTIN_THEME_PALETTES = {}
local BUILTIN_SETTING_PALETTES = {}
for key, setting in pairs(Themes.settings) do
    BUILTIN_THEME_PALETTES[key] = {}
    BUILTIN_SETTING_PALETTES[key] = {}
    for index, palette in ipairs(setting.themePalettes) do
        BUILTIN_THEME_PALETTES[key][index] = palette
        BUILTIN_SETTING_PALETTES[key][#BUILTIN_SETTING_PALETTES[key] + 1] = palette
    end
    for _, palette in ipairs(BUILTIN_DEFAULT_PALETTES) do
        BUILTIN_SETTING_PALETTES[key][#BUILTIN_SETTING_PALETTES[key] + 1] = palette
    end
end
local customPaletteKeys = {}

local function Contains(items, value)
    for _, item in ipairs(items or {}) do if item == value then return true end end
    return false
end

function Themes.SetCustomPalettes(records)
    for key in pairs(customPaletteKeys) do Themes[key] = nil end
    customPaletteKeys = {}
    Themes.order = {}
    for index, key in ipairs(BUILTIN_ORDER) do Themes.order[index] = key end
    for settingKey, palettes in pairs(BUILTIN_THEME_PALETTES) do
        local setting = Themes.settings[settingKey]
        setting.themePalettes = {}
        for index, key in ipairs(palettes) do setting.themePalettes[index] = key end
    end
    Themes.defaultPalettes = {}
    for index, key in ipairs(BUILTIN_DEFAULT_PALETTES) do Themes.defaultPalettes[index] = key end

    for _, record in ipairs(type(records) == "table" and records or {}) do
        local group = record.paletteGroup == "default" and "default" or "theme"
        local settingKey = record.baseSettingKey
        local setting = Themes.settings[settingKey]
        local builtinPool = group == "default" and BUILTIN_DEFAULT_PALETTES or BUILTIN_THEME_PALETTES[settingKey]
        if not builtinPool or #builtinPool == 0 then builtinPool = BUILTIN_DEFAULT_PALETTES end
        local baseKey = Contains(builtinPool, record.basePaletteKey) and record.basePaletteKey
            or (builtinPool and builtinPool[1])
        local runtime = baseKey and PaletteData.CreateRuntimeTheme(record, Themes[baseKey]) or nil
        if setting and runtime and type(record.id) == "string" and not Themes[record.id] then
            Themes[record.id] = runtime
            runtime.paletteGroup = group
            customPaletteKeys[record.id] = true
            Themes.order[#Themes.order + 1] = record.id
            if group == "default" then
                Themes.defaultPalettes[#Themes.defaultPalettes + 1] = record.id
            else
                setting.themePalettes[#setting.themePalettes + 1] = record.id
            end
        end
    end
end

function Themes.IsCustom(key)
    return customPaletteKeys[key] == true
end

function Themes.GetDefaultPalettes()
    return Themes.defaultPalettes
end

function Themes.GetThemePalettes(settingKey)
    return Themes.GetSetting(settingKey).themePalettes
end

function Themes.GetPalettes(settingKey)
    local result = {}
    for _, key in ipairs(Themes.GetDefaultPalettes()) do result[#result + 1] = key end
    for _, key in ipairs(Themes.GetThemePalettes(settingKey)) do result[#result + 1] = key end
    return result
end

function Themes.GetPaletteGroup(key, settingKey)
    if Contains(Themes.GetDefaultPalettes(), key) then return "default" end
    if Contains(Themes.GetThemePalettes(settingKey), key) then return "theme" end
    return nil
end

function Themes.IsPaletteForSetting(key, settingKey)
    return Themes.GetPaletteGroup(key, settingKey) ~= nil
end

function Themes.GetBuiltinDefaultPalettes()
    return BUILTIN_DEFAULT_PALETTES
end

function Themes.GetBuiltinThemePalettes(settingKey)
    return BUILTIN_THEME_PALETTES[settingKey] or BUILTIN_THEME_PALETTES.dungeon
end

function Themes.GetBuiltinPalettes(settingKey)
    return BUILTIN_SETTING_PALETTES[settingKey] or BUILTIN_SETTING_PALETTES.dungeon
end

function Themes.Get(key) return Themes[key] or Themes.ancient end
function Themes.GetSetting(key) return Themes.settings[key] or Themes.settings.dungeon end

local DEFAULT_THEME_BY_SETTING = {
    dungeon = "ancient",
    hospital = "sterile",
    school = "schoolDay",
}

function Themes.Resolve(settingKey, paletteKey)
    local resolvedSetting = Themes.GetSetting(settingKey).key
    local palette = Themes.Get(paletteKey)
    if Themes.GetPaletteGroup(paletteKey, resolvedSetting) ~= "default" or resolvedSetting == "dungeon" then
        return palette
    end
    local base = Themes.Get(DEFAULT_THEME_BY_SETTING[resolvedSetting])
    local colors = {}
    for _, field in ipairs(PaletteData.COLOR_FIELDS) do colors[field] = palette[field] end
    local themed = PaletteData.CreateRuntimeTheme({
        id = palette.key,
        label = palette.label,
        colors = colors,
    }, base)
    themed.isCustom = palette.isCustom
    themed.paletteGroup = "default"
    return themed
end

function Themes.Next(key, settingKey)
    local pool = Themes.GetPalettes(settingKey)
    for index, value in ipairs(pool) do
        if value == key then return pool[index % #pool + 1] end
    end
    return pool[1]
end

function Themes.NextSetting(key)
    for index, value in ipairs(Themes.settingOrder) do
        if value == key then return Themes.settingOrder[index % #Themes.settingOrder + 1] end
    end
    return Themes.settingOrder[1]
end

function Themes.RandomPalette(settingKey, current)
    local pool = Themes.GetPalettes(settingKey)
    if #pool <= 1 then return pool[1] end
    local start = math.random(1, #pool)
    if pool[start] == current then start = start % #pool + 1 end
    return pool[start]
end

return Themes
