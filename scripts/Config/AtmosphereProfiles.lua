-- Named atmosphere presets ("氛围预设").
--
-- An atmosphere is the MOOD ENVELOPE of a scene: how dark it sits, how thick
-- the depth fog reads, how the firelight breathes, how much the frame corners
-- press in. It is deliberately hue-free -- every color keeps coming from the
-- active palette (Themes / PaletteData), so an atmosphere can never fight the
-- palette system or the neutral-structure rule. The other two atmosphere axes
-- stay where they already live:
--
--   placement policy  EnvironmentProfiles.<setting>.atmosphere
--                     (which rooms receive which AtmosphereFX pass)
--   colors / counts   theme.particles / theme.fx / theme.torchLight
--
-- Resolution order: palette override (theme.atmosphereKey) -> per-setting
-- default (DEFAULTS) -> NEUTRAL. The neutral preset reproduces the legacy
-- behavior exactly (identity scales plus the renderer's historical flicker
-- constants), so settings without an authored atmosphere render unchanged.
--
-- Validate() bounds every knob so an authored atmosphere cannot break the
-- final-frame brightness acceptance in docs/generation-rules.md §2.10.

local AtmosphereProfiles = {
    SCHEMA_VERSION = 1,
    NEUTRAL_KEY = "neutral",
}

-- Preset schema (all factors multiply the palette-provided base values):
--
-- lighting.ambientScale     zone ambient intensity factor
-- lighting.sunScale         directional light brightness factor
-- lighting.fogDensityScale  depth-fog density factor (also feeds the froxel
--                           volume density when a setting opts into it)
-- post.vignette             vignette intensity, 0 disables the pass
-- torch.scale               torch / stair firelight brightness factor
-- torch.flicker             brightness envelope for flickering point lights:
--                           base + sin(t*speedA + phase) * ampA
--                                + sin(t*speedB + phase*phaseScale) * ampB
--                           The peak (base + ampA + ampB) is authored to sit
--                           at ~1.0 so `base brightness` keeps meaning "the
--                           brightest the light ever gets".
AtmosphereProfiles.presets = {
    -- Identity preset: exactly the pre-atmosphere behavior. Settings without
    -- an authored mood resolve here and must render byte-identical frames.
    neutral = {
        key = "neutral", label = "中性",
        description = "无情绪加工：完全采用配色自带的光照与历史火光行为。",
        lighting = { ambientScale = 1.0, sunScale = 1.0, fogDensityScale = 1.0 },
        post = { vignette = 0 },
        torch = {
            scale = 1.0,
            flicker = { base = 0.90, ampA = 0.07, speedA = 7.3,
                ampB = 0.03, speedB = 13.1, phaseScale = 0.37 },
        },
    },
    -- First authored atmosphere: the ruins default. Dim the ambient/moon so
    -- torch pools own the frame, thicken the depth fog for enclosure, press a
    -- light vignette into the corners and let the fire breathe deeper. The
    -- torch boost intentionally offsets the dimmed base light so the average
    -- frame brightness stays inside the §2.10 acceptance band.
    dungeonDepths = {
        key = "dungeonDepths", label = "幽邃地牢",
        description = "黑暗压迫、薄雾封闭、火光摇曳的经典地牢情绪。",
        lighting = { ambientScale = 0.90, sunScale = 0.82, fogDensityScale = 1.30 },
        post = { vignette = 1.6 },
        torch = {
            scale = 1.12,
            flicker = { base = 0.86, ampA = 0.10, speedA = 6.9,
                ampB = 0.04, speedB = 12.7, phaseScale = 0.37 },
        },
    },
}

AtmosphereProfiles.order = { "neutral", "dungeonDepths" }

-- Per-setting default mood. Settings absent here stay neutral; palettes may
-- still opt into a specific preset through theme.atmosphereKey.
AtmosphereProfiles.DEFAULTS = {
    dungeon = "dungeonDepths",
}

function AtmosphereProfiles.Get(key)
    return AtmosphereProfiles.presets[key] or AtmosphereProfiles.presets.neutral
end

function AtmosphereProfiles.Resolve(settingKey, theme)
    local override = type(theme) == "table" and theme.atmosphereKey or nil
    if override and AtmosphereProfiles.presets[override] then
        return AtmosphereProfiles.presets[override]
    end
    return AtmosphereProfiles.Get(AtmosphereProfiles.DEFAULTS[settingKey])
end

-- Pure lighting math so the envelope is testable headless. Callers assign the
-- returned values onto Zone / Light; hue fields never pass through here.
function AtmosphereProfiles.ComputeLighting(theme, preset)
    preset = preset or AtmosphereProfiles.presets.neutral
    local lighting = preset.lighting or {}
    local post = preset.post or {}
    return {
        fogDensity = (theme.fogDensity or 0.001) * (lighting.fogDensityScale or 1.0),
        ambientIntensity = (theme.ambient or 0.5) * (lighting.ambientScale or 1.0),
        sunBrightness = (theme.sunIntensity or 0.8) * (lighting.sunScale or 1.0),
        vignetteIntensity = post.vignette or 0,
    }
end

function AtmosphereProfiles.FlickerEnvelope(preset)
    local torch = preset and preset.torch or nil
    return torch and torch.flicker or AtmosphereProfiles.presets.neutral.torch.flicker
end

function AtmosphereProfiles.TorchScale(preset)
    local torch = preset and preset.torch or nil
    return torch and torch.scale or 1.0
end

local function InRange(value, low, high)
    return type(value) == "number" and value >= low and value <= high
end

local function ValidatePreset(preset, key)
    if type(preset) ~= "table" then return false, key .. " preset is missing" end
    if preset.key ~= key then return false, key .. " preset key mismatch" end
    local lighting = preset.lighting
    if type(lighting) ~= "table" then return false, key .. " lighting envelope is missing" end
    if not InRange(lighting.ambientScale, 0.6, 1.4) then
        return false, key .. " ambientScale is outside 0.6..1.4"
    end
    if not InRange(lighting.sunScale, 0.6, 1.4) then
        return false, key .. " sunScale is outside 0.6..1.4"
    end
    if not InRange(lighting.fogDensityScale, 0.5, 2.0) then
        return false, key .. " fogDensityScale is outside 0.5..2.0"
    end
    local post = preset.post
    if type(post) ~= "table" or not InRange(post.vignette, 0, 4) then
        return false, key .. " vignette is outside 0..4"
    end
    local torch = preset.torch
    if type(torch) ~= "table" or not InRange(torch.scale, 0.7, 1.4) then
        return false, key .. " torch scale is outside 0.7..1.4"
    end
    local flicker = torch.flicker
    if type(flicker) ~= "table" then return false, key .. " flicker envelope is missing" end
    for _, field in ipairs({ "base", "ampA", "speedA", "ampB", "speedB", "phaseScale" }) do
        if type(flicker[field]) ~= "number" then
            return false, key .. " flicker." .. field .. " is missing"
        end
    end
    local peak = flicker.base + flicker.ampA + flicker.ampB
    local trough = flicker.base - flicker.ampA - flicker.ampB
    if peak < 0.95 or peak > 1.05 then
        return false, key .. " flicker peak must stay near 1.0 (base means max brightness)"
    end
    if trough < 0.6 then
        return false, key .. " flicker trough dips below 0.6 and would read as strobing"
    end
    if not InRange(flicker.speedA, 0.5, 20) or not InRange(flicker.speedB, 0.5, 20) then
        return false, key .. " flicker speeds are outside 0.5..20"
    end
    return true
end

function AtmosphereProfiles.Validate()
    local seen = {}
    for _, key in ipairs(AtmosphereProfiles.order) do
        seen[key] = true
        local valid, reason = ValidatePreset(AtmosphereProfiles.presets[key], key)
        if not valid then return false, reason end
    end
    for key in pairs(AtmosphereProfiles.presets) do
        if not seen[key] then return false, key .. " preset is not registered in order" end
    end
    local neutral = AtmosphereProfiles.presets.neutral
    if neutral.lighting.ambientScale ~= 1.0 or neutral.lighting.sunScale ~= 1.0
        or neutral.lighting.fogDensityScale ~= 1.0 or neutral.post.vignette ~= 0
        or neutral.torch.scale ~= 1.0 then
        return false, "neutral preset drifted from the identity envelope"
    end
    for settingKey, presetKey in pairs(AtmosphereProfiles.DEFAULTS) do
        if not AtmosphereProfiles.presets[presetKey] then
            return false, "default atmosphere for " .. settingKey .. " references unknown preset " .. tostring(presetKey)
        end
    end
    return true
end

return AtmosphereProfiles
