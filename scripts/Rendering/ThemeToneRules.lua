local EnvironmentProfiles = require("Config.EnvironmentProfiles")

local ThemeToneRules = {}

-- Semantic tints are shared across settings. A hospital boss room and a ruins
-- boss room use the same role cue; their palette still supplies the base surface.
local ROOM_TINT = {
    entrance = 0x3fd0bb,
    combat = 0x8f95a3,
    elite = 0x9b6cf0,
    treasure = 0xd9a441,
    shrine = 0x5a8fe8,
    boss = 0xd8433a,
}

local SETTING_KEYS = { "dungeon", "temple", "hospital", "school" }

local function ClampByte(value)
    return math.max(0, math.min(255, math.floor(value + 0.5)))
end

local function Channels(value)
    return (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff
end

local function FromChannels(r, g, b)
    return (ClampByte(r) << 16) | (ClampByte(g) << 8) | ClampByte(b)
end

local function LerpColor(a, b, amount)
    local ar, ag, ab = Channels(a)
    local br, bg, bb = Channels(b)
    return FromChannels(ar + (br - ar) * amount, ag + (bg - ag) * amount, ab + (bb - ab) * amount)
end

local function MultiplyColor(value, factor)
    local r, g, b = Channels(value)
    return FromChannels(r * factor, g * factor, b * factor)
end

local function SaturateColor(value, amount)
    local r, g, b = Channels(value)
    local gray = (r + g + b) / 3
    return FromChannels(
        gray + (r - gray) * amount,
        gray + (g - gray) * amount,
        gray + (b - gray) * amount)
end

local function ContrastColor(value, amount)
    local r, g, b = Channels(value)
    local center = 127.5
    return FromChannels(
        center + (r - center) * amount,
        center + (g - center) * amount,
        center + (b - center) * amount)
end

local function ApplyPaletteVisibility(theme, tone, color)
    local accentAmount = tonumber(tone.paletteAccentTintAmount) or 0
    if accentAmount > 0 and type(theme.accentObject) == "number" then
        color = LerpColor(color, theme.accentObject, accentAmount)
    end
    color = SaturateColor(color, tonumber(tone.paletteSaturation) or 1.0)
    return ContrastColor(color, tonumber(tone.paletteContrast) or 1.0)
end

local function RangeValue(range, index, fallback)
    return type(range) == "table" and tonumber(range[index]) or fallback
end

local function Variation(color, range, rng)
    local low = RangeValue(range, 1, 1.0)
    local high = RangeValue(range, 2, low)
    local factor = rng and rng:Float(low, high) or (low + high) * 0.5
    return MultiplyColor(color, factor)
end

local function ToneFor(settingKey)
    local profile = EnvironmentProfiles.Resolve(settingKey)
    return profile.structureTone or {}
end

function ThemeToneRules.Resolve(settingKey)
    return ToneFor(settingKey)
end

function ThemeToneRules.RoomTint(role)
    return ROOM_TINT[role]
end

function ThemeToneRules.ResolveFloorColor(theme, tone, context)
    context = context or {}
    tone = tone or {}
    local color = context.corridor and theme.corridor or theme.floor
    color = ApplyPaletteVisibility(theme, tone, color)
    local role = context.room and context.room.type
    -- A planned room group carries its own muted identity color. Prefer it
    -- over the generic role tint so several rooms with the same gameplay role
    -- still read as different spaces; ungrouped rooms keep the legacy fallback.
    local semanticTint = context.room and context.room.roomGroupColor
        or (role ~= "combat" and role and ROOM_TINT[role])
    local semanticAmount = tonumber(tone.semanticTintAmount) or 0
    if semanticTint and semanticAmount > 0 then
        color = LerpColor(color, semanticTint, semanticAmount)
    end

    local surfaceAmount = tonumber(tone.surfaceTintAmount) or 0
    if context.surfaceTint and surfaceAmount > 0 then
        color = LerpColor(color, context.surfaceTint, surfaceAmount)
    end

    if context.isDoorway then
        color = MultiplyColor(color, tonumber(tone.doorwayGain) or 1.0)
    end

    local wallCount = math.max(0, math.min(
        tonumber(tone.edgeDarkenMaxWalls) or 0, math.floor(context.walls8 or 0)))
    color = MultiplyColor(color, 1 - (tonumber(tone.edgeDarkenStep) or 0) * wallCount)

    if context.checker then
        color = MultiplyColor(color, tonumber(tone.checkerGain) or 1.0)
    end
    return Variation(color, tone.floorVariation, context.rng)
end

function ThemeToneRules.ResolveWallColor(theme, tone, rng)
    tone = tone or {}
    local color = ApplyPaletteVisibility(theme, tone, theme.wall)
    return Variation(color, tone.wallVariation, rng)
end

function ThemeToneRules.ResolveCapColor(theme, tone, rng)
    tone = tone or {}
    local color = ApplyPaletteVisibility(theme, tone, theme.cap or theme.wall)
    return Variation(color, tone.capVariation, rng)
end

function ThemeToneRules.ResolveDoorColor(theme, tone)
    tone = tone or {}
    local color = ApplyPaletteVisibility(theme, tone, theme.wall)
    return MultiplyColor(color, tonumber(tone.doorwayGain) or 1.0)
end

local function ValidateRange(range, name)
    if type(range) ~= "table" then return false, name .. " must be a two-value range" end
    local low, high = tonumber(range[1]), tonumber(range[2])
    if not low or not high or low <= 0 or low > high or high > 1.5 then
        return false, name .. " has an invalid range"
    end
    return true
end

local function ValidateTone(tone, settingKey)
    if type(tone) ~= "table" then return false, settingKey .. " structure tone is missing" end
    local factors = {
        doorwayGain = { 0.5, 1.5 }, checkerGain = { 0.5, 1.5 },
        edgeDarkenStep = { 0, 0.5 }, semanticTintAmount = { 0, 1 },
        surfaceTintAmount = { 0, 1 }, paletteAccentTintAmount = { 0, 1 },
        paletteSaturation = { 0.5, 2.0 }, paletteContrast = { 0.5, 2.0 },
    }
    for name, limits in pairs(factors) do
        local value = tonumber(tone[name])
        if not value or value < limits[1] or value > limits[2] then
            return false, string.format("%s %s is outside %.2f..%.2f", settingKey, name, limits[1], limits[2])
        end
    end
    local maxWalls = tonumber(tone.edgeDarkenMaxWalls)
    if not maxWalls or maxWalls < 0 or maxWalls > 8 or maxWalls % 1 ~= 0 then
        return false, settingKey .. " edgeDarkenMaxWalls is invalid"
    end
    for _, name in ipairs({ "floorVariation", "wallVariation", "capVariation" }) do
        local valid, reason = ValidateRange(tone[name], settingKey .. " " .. name)
        if not valid then return false, reason end
    end
    if (tonumber(tone.surfaceTintAmount) or 0) > 0 and type(tone.surfaceTint) ~= "number" then
        return false, settingKey .. " surfaceTint is required when surfaceTintAmount is enabled"
    end
    return true
end

function ThemeToneRules.Validate()
    for _, settingKey in ipairs(SETTING_KEYS) do
        local valid, reason = ValidateTone(ToneFor(settingKey), settingKey)
        if not valid then return false, reason end
    end
    return true
end

return ThemeToneRules
