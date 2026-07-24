local VolumetricFog = {}

local DEFAULT_GRID_PIXEL_SIZE = 16
local DEFAULT_GRID_SIZE_Z = 64
local DEFAULT_HISTORY_WEIGHT = 0.90

local function SetBool(object, name, value)
    object:SetAttribute(name, Variant(VAR_BOOL, value and "true" or "false"))
end

local function SetFloat(object, name, value)
    object:SetAttribute(name, Variant(VAR_FLOAT, tostring(value)))
end

local function SetColor(object, name, value)
    object:SetAttribute(name, Variant(VAR_COLOR, value:ToString()))
end

VolumetricFog.SetBool = SetBool
VolumetricFog.SetFloat = SetFloat
VolumetricFog.SetColor = SetColor

function VolumetricFog.ConfigureRenderer(enabled, config)
    renderer:SetVolumetricFogFroxelEnabled(enabled == true)
    if not enabled then return end
    config = config or {}
    renderer:SetVolumetricFogGridPixelSize(config.gridPixelSize or DEFAULT_GRID_PIXEL_SIZE)
    renderer:SetVolumetricFogGridSizeZ(config.gridSizeZ or DEFAULT_GRID_SIZE_Z)
    renderer:SetVolumetricFogHistoryWeight(config.historyWeight or DEFAULT_HISTORY_WEIGHT)
    renderer:SetVolumetricFogDebugMode(0)
end

function VolumetricFog.ConfigureZone(zone, enabled, config, scatteringColor)
    if not zone then return end
    config = config or {}
    zone.boundingBox = BoundingBox(Vector3(-1000, -1000, -1000), Vector3(1000, 1000, 1000))
    SetBool(zone, "Volumetric Fog Enabled", enabled == true)
    SetFloat(zone, "Volumetric Fog Density", enabled and (config.density or 0.001) or 0)
    SetFloat(zone, "Volumetric Fog Height", config.height or 2.0)
    SetFloat(zone, "Volumetric Fog Height Falloff", config.heightFalloff or 0)
    SetFloat(zone, "Volumetric Fog View Distance", config.viewDistance or 80.0)
    SetFloat(zone, "Volumetric Fog Start Distance", config.startDistance or 1.5)
    SetFloat(zone, "Volumetric Fog Phase G", config.phaseG or 0.55)
    SetFloat(zone, "Volumetric Fog Max Opacity", config.maxOpacity or 0.45)
    SetColor(zone, "Volumetric Fog Scattering Color", scatteringColor or Color(1, 1, 1, 1))
    SetColor(zone, "Volumetric Fog Emissive Color", Color(0, 0, 0, 1))
    SetColor(zone, "Volumetric Fog Absorption Color", config.absorptionColor or Color(0.08, 0.10, 0.12, 1))
    SetFloat(zone, "Volumetric Fog Absorption Intensity", config.absorptionIntensity or 0.01)
end

function VolumetricFog.ConfigureLight(light, enabled, intensity, shadows)
    if not light then return end
    local active = enabled == true
    SetBool(light, "Affect Volumetric Fog", active)
    SetFloat(light, "Volumetric Fog Intensity", active and (intensity or 1.0) or 0)
    SetBool(light, "Volumetric Fog Shadows", active and shadows == true)
end

return VolumetricFog
