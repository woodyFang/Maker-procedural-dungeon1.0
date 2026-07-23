local PCGDungeonRenderer = {}
PCGDungeonRenderer.__index = PCGDungeonRenderer

local PCGDungeonCoordinateSystem = require("Generation.PCGDungeonCoordinateSystem")
local PCGDungeonMeshInfoAdapter = require("Generation.PCGDungeonMeshInfoAdapter")

local MANIFEST_CANDIDATES = {
    "assets/PCGDungeon/PCGDungeon.mesh_info.json",
    "PCGDungeon/PCGDungeon.mesh_info.json",
}
local LIGHT_MANIFEST_CANDIDATES = {
    "assets/PCGDungeon/PCGDungeon.lights.json",
    "PCGDungeon/PCGDungeon.lights.json",
}
local UINT32_MASK = 0xffffffff
local UE_UNITLESS_CM_TO_M2_SCALE = 0.0001
local LIGHT_UNIT_VALUE = {
    Unitless = 0,
    Candelas = 1,
    Lumens = 2,
}
local CELL_DEBUG_INSET = 0.96
-- Keep the selection plane on the same surface as SceneLayoutEditor room boxes.
-- Cell positions are cell centers, so subtract half a cell before applying the
-- small editor overlay lift.
local EDITOR_SELECTION_HEIGHT = 0.22
local CELL_DEBUG_STYLE = {
    room = { nodeName = "RoomVolumes", color = { 1.0, 0.5, 0.0, 1.0 } },
    corridor = { nodeName = "CorridorCells", color = { 0.0, 0.5, 1.0, 1.0 } },
    stair = { nodeName = "StairCells", color = { 0.0, 1.0, 0.0, 1.0 } },
}

-- UE 5.8 uses this fixed permutation table for FMath::PerlinNoise2D.
local PERM = {
    63, 9, 212, 205, 31, 128, 72, 59, 137, 203, 195, 170, 181, 115, 165, 40,
    116, 139, 175, 225, 132, 99, 222, 2, 41, 15, 197, 93, 169, 90, 228, 43,
    221, 38, 206, 204, 73, 17, 97, 10, 96, 47, 32, 138, 136, 30, 219, 78,
    224, 13, 193, 88, 134, 211, 7, 112, 176, 19, 106, 83, 75, 217, 85, 0,
    98, 140, 229, 80, 118, 151, 117, 251, 103, 242, 81, 238, 172, 82, 110, 4,
    227, 77, 243, 46, 12, 189, 34, 188, 200, 161, 68, 76, 171, 194, 57, 48,
    247, 233, 51, 105, 5, 23, 42, 50, 216, 45, 239, 148, 249, 84, 70, 125,
    108, 241, 62, 66, 64, 240, 173, 185, 250, 49, 6, 37, 26, 21, 244, 60,
    223, 255, 16, 145, 27, 109, 58, 102, 142, 253, 120, 149, 160, 124, 156, 79,
    186, 135, 127, 14, 121, 22, 65, 54, 153, 91, 213, 174, 24, 252, 131,
    192, 190, 202, 208, 35, 94, 231, 56, 95, 183, 163, 111, 147, 25, 67, 36,
    92, 236, 71, 166, 1, 187, 100, 130, 143, 237, 178, 158, 104, 184, 159, 177,
    52, 214, 230, 119, 87, 114, 201, 179, 198, 3, 248, 182, 39, 11, 152, 196,
    113, 20, 232, 69, 141, 207, 234, 53, 86, 180, 226, 74, 150, 218, 29, 133,
    8, 44, 123, 28, 146, 89, 101, 154, 220, 126, 155, 122, 210, 168, 254, 162,
    129, 33, 18, 209, 61, 191, 199, 157, 245, 55, 164, 167, 215, 246, 144, 107,
    235,
}
for index = 1, 256 do PERM[index + 256] = PERM[index] end

local function U32(value)
    return math.floor(value) & UINT32_MASK
end

local function RoundToInt(value)
    return value >= 0 and math.floor(value + 0.5) or math.ceil(value - 0.5)
end

local function HashCombine(a, c)
    local b = 0x9e3779b9
    a = U32(a + b)
    a = U32(a - b - c); a = U32(a ~ (c >> 13))
    b = U32(b - c - a); b = U32(b ~ U32(a << 8))
    c = U32(c - a - b); c = U32(c ~ (b >> 13))
    a = U32(a - b - c); a = U32(a ~ (c >> 12))
    b = U32(b - c - a); b = U32(b ~ U32(a << 16))
    c = U32(c - a - b); c = U32(c ~ (b >> 5))
    a = U32(a - b - c); a = U32(a ~ (c >> 3))
    b = U32(b - c - a); b = U32(b ~ U32(a << 10))
    c = U32(c - a - b); c = U32(c ~ (b >> 15))
    return c
end

local function PlacementHash(seed, transform, zeroIndex)
    local hash = U32(seed or 0)
    hash = HashCombine(hash, U32(RoundToInt(transform[1] * 100)))
    hash = HashCombine(hash, U32(RoundToInt(transform[2] * 100)))
    hash = HashCombine(hash, U32(RoundToInt(transform[3] * 100)))
    return HashCombine(hash, U32(zeroIndex))
end

local function ReadManifest()
    for _, path in ipairs(MANIFEST_CANDIDATES) do
        if cache:Exists(path) then
            local file = cache:GetFile(path)
            if not file then return nil, "manifest could not be opened: " .. path end
            local raw = file:ReadString()
            file:Close()
            local ok, data = pcall(cjson.decode, raw)
            if ok and type(data) == "table" then return data, path end
            return nil, "manifest JSON is invalid: " .. path
        end
    end
    return nil, "PCGDungeon.mesh_info.json was not found"
end

local function ReadLightManifest()
    for _, path in ipairs(LIGHT_MANIFEST_CANDIDATES) do
        if cache:Exists(path) then
            local file = cache:GetFile(path)
            if not file then return nil, "light manifest could not be opened: " .. path end
            local raw = file:ReadString()
            file:Close()
            local ok, data = pcall(cjson.decode, raw)
            if not ok or type(data) ~= "table" then return nil, "light manifest JSON is invalid: " .. path end
            if data.schema_version ~= 1 or type(data.profiles) ~= "table" or type(data.lights) ~= "table" then
                return nil, "light manifest schema is invalid: " .. path
            end
            return data, path
        end
    end
    return nil, "PCGDungeon.lights.json was not found"
end

local function ValidateManifest(data)
    if type(data.scene) ~= "table" then return false, "scene block is missing" end
    if data.scene.schema_version ~= 1 then return false, "unsupported scene schema" end
    if type(data.scene.instances) ~= "table" then return false, "scene.instances is missing" end
    if type(data.asset_bindings) ~= "table" then return false, "asset_bindings is missing" end
    if type(data.diagnostic_meshes) ~= "table"
        or type(data.diagnostic_meshes.light_volume) ~= "string"
        or type(data.diagnostic_meshes.cell_volume) ~= "string" then
        return false, "diagnostic_meshes is missing"
    end
    local lightDefaults, hasPointLights = data.light_defaults, false
    for _, rule in ipairs(data.meshes or {}) do
        if rule.point_light_enabled == true then hasPointLights = true; break end
    end
    if hasPointLights and (type(lightDefaults) ~= "table" or lightDefaults.type ~= "Point"
        or LIGHT_UNIT_VALUE[lightDefaults.light_units] == nil
        or type(lightDefaults.use_physical_values) ~= "boolean"
        or type(lightDefaults.radius_m) ~= "number"
        or type(lightDefaults.length_m) ~= "number"
        or type(lightDefaults.soft_radius_m) ~= "number"
        or type(lightDefaults.punctual) ~= "boolean"
        or type(lightDefaults.affect_volumetric_fog) ~= "boolean"
        or type(lightDefaults.volumetric_fog_intensity) ~= "number"
        or type(lightDefaults.cast_volumetric_shadow) ~= "boolean"
        or type(lightDefaults.shadow_constant_bias) ~= "number"
        or type(lightDefaults.shadow_slope_bias) ~= "number"
        or type(lightDefaults.shadow_normal_offset) ~= "number") then
        return false, "light_defaults does not match the UrhoX point-light contract"
    end
    if #data.scene.instances ~= (data.scene.instance_group_count or -1) then
        return false, "instance group count does not match manifest declaration"
    end
    local rulesById = {}
    for _, rule in ipairs(data.meshes or {}) do
        if rule.id then rulesById[rule.id] = true end
    end
    local instanceCount = 0
    for _, group in ipairs(data.scene.instances) do
        if type(group.mesh) ~= "string" or type(group.transforms) ~= "table" then
            return false, "invalid scene instance group"
        end
        for _, transform in ipairs(group.transforms) do
            if type(transform) ~= "table" or #transform ~= 10 then
                return false, "packed transform must contain 10 numbers"
            end
        end
        if type(group.room_ids) == "table" and #group.room_ids ~= #group.transforms then
            return false, "room_ids length does not match transforms"
        end
        if type(group.floor_ids) == "table" and #group.floor_ids ~= #group.transforms then
            return false, "floor_ids length does not match transforms"
        end
        if group.rule_id and not rulesById[group.rule_id] then
            return false, "scene instance group references unknown rule_id: " .. tostring(group.rule_id)
        end
        instanceCount = instanceCount + #group.transforms
    end
    if instanceCount ~= (data.scene.instance_count or -1) then
        return false, "instance count does not match manifest declaration"
    end

    local function ValidateAsset(assetPath, owner)
        local binding = type(assetPath) == "string" and data.asset_bindings[assetPath] or nil
        if type(binding) ~= "table" or type(binding.model_resource) ~= "string"
            or binding.model_resource == "" then
            return false, "missing asset binding for " .. tostring(owner) .. ": " .. tostring(assetPath)
        end
        return true
    end
    for _, rule in ipairs(data.meshes or {}) do
        if rule.point_light_enabled == true then
            local units = rule.point_light_units or lightDefaults.light_units
            if LIGHT_UNIT_VALUE[units] == nil then
                return false, "unsupported point-light units for " .. tostring(rule.id) .. ": " .. tostring(units)
            end
            if type(rule.point_light_brightness) ~= "number" or rule.point_light_brightness < 0 then
                return false, "point_light_brightness is invalid for " .. tostring(rule.id)
            end
            if type(rule.point_light_range_m) ~= "number" or rule.point_light_range_m < 0 then
                return false, "point_light_range_m is invalid for " .. tostring(rule.id)
            end
        end
        if rule.visible ~= false then
            if rule.usage == "prefab" then
                if type(rule.parts) ~= "table" or #rule.parts == 0 then
                    return false, "prefab parts are missing: " .. tostring(rule.id)
                end
                for index, part in ipairs(rule.parts) do
                    if part.visible ~= false then
                        local valid, reason = ValidateAsset(part.mesh,
                            tostring(rule.id) .. ".parts[" .. tostring(index) .. "]")
                        if not valid then return false, reason end
                    end
                end
            elseif rule.usage == "inherit" or rule.usage == "attach" then
                local valid, reason = ValidateAsset(rule.mesh, rule.id)
                if not valid then return false, reason end
            end
        end
    end
    for _, rule in ipairs(data.scatter_rules or {}) do
        if rule.enabled ~= false and rule.visible ~= false then
            local valid, reason = ValidateAsset(rule.mesh, rule.id)
            if not valid then return false, reason end
        end
    end
    return true
end

local function ConvertPosition(values)
    return PCGDungeonCoordinateSystem.PackedPositionToUrho(values)
end

local function ConvertScale(values)
    return PCGDungeonCoordinateSystem.PackedScaleToUrho(values)
end

local function ApplyPackedTransform(node, values, floorOffset)
    local position = ConvertPosition(values)
    position.y = position.y + (floorOffset or 0)
    node.position = position
    node.rotation = PCGDungeonCoordinateSystem.PackedQuaternionToUrho(values)
    node.scale = PCGDungeonCoordinateSystem.PackedTransformScaleToUrho(values)
end

local function IsIdentityRuleTransform(rule)
    local p, r, s = rule.offset_cm or { 0, 0, 0 }, rule.rotation_deg or { 0, 0, 0 }, rule.scale or { 1, 1, 1 }
    return p[1] == 0 and p[2] == 0 and p[3] == 0
        and r[1] == 0 and r[2] == 0 and r[3] == 0
        and s[1] == 1 and s[2] == 1 and s[3] == 1
end

local function ApplyRuleTransform(node, rule)
    node.position = ConvertPosition(rule.offset_cm)
    node.rotation = PCGDungeonCoordinateSystem.UERotatorToUrho(rule.rotation_deg)
    node.scale = ConvertScale(rule.scale)
end

local function CandidateSort(a, b)
    if a.hash == b.hash then return a.index < b.index end
    return a.hash < b.hash
end

local function SrgbChannelToLinear(value)
    local channel = math.max(0, math.min(255, value or 0)) / 255
    if channel <= 0.04045 then return channel / 12.92 end
    return ((channel + 0.055) / 1.055) ^ 2.4
end

local function ColorFromRule(rule, hash)
    local values = rule.point_light_color_srgb or { 255, 255, 255 }
    local palette = rule.point_light_color_palette
    if type(palette) == "table" and #palette > 0 then
        local colorHash = HashCombine(hash, 0x6e624eb7)
        local text = tostring(palette[(colorHash % #palette) + 1]):sub(1, 6)
        local packed = tonumber(text, 16)
        if packed then values = { (packed >> 16) & 255, (packed >> 8) & 255, packed & 255 } end
    end
    return Color(
        SrgbChannelToLinear(values[1]),
        SrgbChannelToLinear(values[2]),
        SrgbChannelToLinear(values[3]),
        1)
end

local function LightSetting(rule, defaults, name, fallback)
    local value = rule and rule["point_light_" .. name] or nil
    if value == nil and defaults then
        value = defaults[name]
        if value == nil and name == "units" then value = defaults.light_units end
        if value == nil and name == "radius_m" then value = defaults.radius end
        if value == nil and name == "length_m" then value = defaults.length end
        if value == nil and name == "soft_radius_m" then value = defaults.soft_radius end
    end
    if value == nil then return fallback end
    return value
end

local function PhysicalBrightness(rule, defaults, intensityNoise)
    local mappedBrightness = tonumber(LightSetting(rule, defaults, "brightness", nil))
    local intensity = (mappedBrightness or rule.point_light_intensity or 100)
        * (1 + intensityNoise * (rule.point_light_intensity_variation or 0))
    if mappedBrightness then return math.max(0, intensity) end
    if LightSetting(rule, defaults, "units", "Unitless") == "Unitless" then
        return intensity * UE_UNITLESS_CM_TO_M2_SCALE
    end
    return intensity
end

local function PointLightRange(rule, defaults, radiusNoise)
    local range = tonumber(LightSetting(rule, defaults, "range_m", nil))
    if not range then range = (rule.point_light_attenuation_radius or 700) * 0.01 end
    return math.max(0, range * (1 + radiusNoise * (rule.point_light_radius_variation or 0)))
end

local function SetFloatAttribute(light, name, value)
    light:SetAttribute(name, Variant(VAR_FLOAT, tostring(tonumber(value) or 0)))
end

local function ConfigurePointLight(light, rule, defaults, brightness, range, castShadows)
    local units = LightSetting(rule, defaults, "units", "Unitless")
    light.lightType = LIGHT_POINT
    light.usePhysicalValues = LightSetting(rule, defaults, "use_physical_values", true) == true
    light:SetAttribute("Light Units", Variant(VAR_INT, tostring(LIGHT_UNIT_VALUE[units] or 0)))
    light.brightness = math.max(0, brightness or 0)
    light.range = math.max(0, range or 0)
    light.radius = math.max(0, tonumber(LightSetting(rule, defaults, "radius_m", 0)) or 0)
    light.length = math.max(0, tonumber(LightSetting(rule, defaults, "length_m", 0)) or 0)
    SetFloatAttribute(light, "SoftRadius", LightSetting(rule, defaults, "soft_radius_m", 0))
    light:SetAttribute("Punctual Light", Variant(LightSetting(rule, defaults, "punctual", true) == true))
    light.castShadows = castShadows == true
    light.shadowBias = BiasParameters(
        math.max(0, tonumber(LightSetting(rule, defaults, "shadow_constant_bias", 0.00002)) or 0),
        math.max(0, tonumber(LightSetting(rule, defaults, "shadow_slope_bias", 0)) or 0),
        math.max(0, tonumber(LightSetting(rule, defaults, "shadow_normal_offset", 0)) or 0))

    local affectVolumetricFog = LightSetting(rule, defaults, "affect_volumetric_fog", true) == true
    local volumetricFogIntensity = math.max(0,
        tonumber(LightSetting(rule, defaults, "volumetric_fog_intensity", 1)) or 0)
    local volumetricFogShadows = light.castShadows
        and LightSetting(rule, defaults, "cast_volumetric_shadow", true) == true
    light:SetAttribute("Affect Volumetric Fog", Variant(affectVolumetricFog))
    SetFloatAttribute(light, "Volumetric Fog Intensity", volumetricFogIntensity)
    light:SetAttribute("Volumetric Fog Shadows", Variant(volumetricFogShadows))

    if LightSetting(rule, defaults, "use_temperature", false) == true then
        light:SetAttribute("Use Temperature", Variant(true))
        SetFloatAttribute(light, "Temperature", LightSetting(rule, defaults, "temperature_kelvin", 6500))
    end
end

local function Grad2(hash, x, y)
    local mode = hash & 7
    if mode == 0 then return x end
    if mode == 1 then return x + y end
    if mode == 2 then return y end
    if mode == 3 then return -x + y end
    if mode == 4 then return -x end
    if mode == 5 then return -x - y end
    if mode == 6 then return -y end
    return x - y
end

local function SmoothCurve(value)
    return value * value * value * (value * (value * 6 - 15) + 10)
end

local function Lerp(a, b, amount)
    return a + (b - a) * amount
end

local function PerlinNoise2D(x, y)
    local xFloor, yFloor = math.floor(x), math.floor(y)
    local xi, yi = xFloor & 255, yFloor & 255
    x, y = x - xFloor, y - yFloor
    local xm1, ym1 = x - 1, y - 1
    local aa = PERM[xi + 1] + yi
    local ab, ba = aa + 1, PERM[xi + 2] + yi
    local bb = ba + 1
    local u, v = SmoothCurve(x), SmoothCurve(y)
    return Lerp(
        Lerp(Grad2(PERM[aa + 1], x, y), Grad2(PERM[ba + 1], xm1, y), u),
        Lerp(Grad2(PERM[ab + 1], x, ym1), Grad2(PERM[bb + 1], xm1, ym1), u),
        v)
end

local function NewRandomStream(seed)
    return { seed = U32(seed) }
end

local function RandomFraction(stream)
    stream.seed = U32(stream.seed * 196314165 + 907633515)
    local bits = 0x3f800000 | (stream.seed >> 9)
    return string.unpack("<f", string.pack("<I4", bits)) - 1
end

local function RandomRange(stream, minimum, maximum)
    return minimum + (maximum - minimum) * RandomFraction(stream)
end

function PCGDungeonRenderer.new(scene)
    return setmetatable({
        scene = scene, root = nil, groups = {}, lights = {}, stats = nil, previewStart = nil,
        resolvedMaterials = {},
        lightDebugVisible = false, lightDebugRoot = nil,
        lightDebugMaterial = nil, lightDebugMarkerMaterial = nil, elapsed = 0,
        cellDebugVisible = false, cellDebugRoot = nil, cellDebugMaterials = {},
        cellDebugData = nil, cellDebugStats = nil, cachedBuild = nil,
        selectionRoot = nil, selectionMaterial = nil, selectionDungeon = nil,
        selectionRoomIndex = nil, selectionRoomId = nil, selectionCellCount = 0,
        selectionSurfaceY = nil,
        groupInstanceNodes = {}, assetBindings = nil, diagnosticMeshes = nil, lightDefaults = nil,
        referenceLightsEnabled = false,
        lightingEnabled = true,
        preloadStats = nil,
        viewOptions = nil,
    }, PCGDungeonRenderer)
end

local function NormalizeFloorIndex(value)
    value = tonumber(value)
    if value == nil or value < 0 then return nil end
    return math.max(0, math.floor(value + 0.5))
end

function PCGDungeonRenderer:NormalizeViewOptions(options)
    options = options or {}
    local mode = options.viewMode
    if mode ~= "current" and mode ~= "neighbors" and mode ~= "all" and mode ~= "explode" then
        mode = "all"
    end
    local floorHeight = tonumber(options.floorHeight)
        or (self.viewOptions and self.viewOptions.floorHeight) or 5.0
    floorHeight = math.max(0.001, floorHeight)
    return {
        currentFloor = NormalizeFloorIndex(options.currentFloor)
            or (self.viewOptions and self.viewOptions.currentFloor) or 0,
        viewMode = mode,
        floorHeight = floorHeight,
        floorSpacing = mode == "explode" and 2.2 or 1.0,
    }
end

function PCGDungeonRenderer:FloorVisible(floor, options)
    options = options or self.viewOptions or self:NormalizeViewOptions()
    if floor == nil then return true end
    if options.viewMode == "current" then return floor == options.currentFloor end
    if options.viewMode == "neighbors" then return math.abs(floor - options.currentFloor) <= 1 end
    return true
end

function PCGDungeonRenderer:FloorOffset(floor, options)
    options = options or self.viewOptions or self:NormalizeViewOptions()
    return (tonumber(floor) or 0) * options.floorHeight * (options.floorSpacing - 1.0)
end

function PCGDungeonRenderer:TransformFloor(transform, explicitFloor, marker, options)
    options = options or self.viewOptions or self:NormalizeViewOptions()
    local floor = NormalizeFloorIndex(explicitFloor)
    if floor ~= nil then return floor end
    local position = ConvertPosition(transform)
    floor = math.floor(position.y / options.floorHeight + 0.000001)
    -- Ceiling markers sit one floor above the walkable surface they cap.
    if string.lower(tostring(marker or "")) == "ceil" then floor = floor - 1 end
    return math.max(0, floor)
end

function PCGDungeonRenderer:SetLightingEnabled(enabled)
    local value = enabled ~= false
    if self.lightingEnabled == value then return value end
    self.lightingEnabled = value
    if not value then
        self:ClearLightDebugGeometry()
        self.lightDebugVisible = false
        for _, entry in ipairs(self.lights) do
            if entry.node then entry.node:Dispose() end
        end
        self.lights = {}
        if self.stats then self.stats.lights = 0 end
    end
    return value
end

function PCGDungeonRenderer:ClearLightDebugGeometry()
    if self.lightDebugRoot then self.lightDebugRoot:Dispose(); self.lightDebugRoot = nil end
    if self.lightDebugMaterial then self.lightDebugMaterial:Dispose(); self.lightDebugMaterial = nil end
    if self.lightDebugMarkerMaterial then
        self.lightDebugMarkerMaterial:Dispose()
        self.lightDebugMarkerMaterial = nil
    end
end

function PCGDungeonRenderer:ClearCellDebugGeometry()
    if self.cellDebugRoot then self.cellDebugRoot:Dispose(); self.cellDebugRoot = nil end
    for _, material in ipairs(self.cellDebugMaterials or {}) do material:Dispose() end
    self.cellDebugMaterials = {}
    self.cellDebugStats = nil
end

function PCGDungeonRenderer:DestroyDungeonGeometry()
    self:ClearLightDebugGeometry()
    if self.root then self.root:Dispose(); self.root = nil end
    self.selectionRoot = nil
    self.selectionCellCount, self.selectionSurfaceY = 0, nil
    self.groups = {}
    self.groupInstanceNodes = {}
    self.resolvedMaterials = {}
    self.assetBindings = nil
    self.diagnosticMeshes = nil
    self.lightDefaults = nil
    self.lights = {}
end

function PCGDungeonRenderer:RestoreDungeonGeometry()
    if self.root then return true, self.stats end
    local build = self.cachedBuild
    if not build then return false, "cached PCG Dungeon build is unavailable" end
    return self:BuildManifest(build.data, build.source, build.lightData, build.lightSource,
        build.pipelineStats, build.viewOptions)
end

function PCGDungeonRenderer:RebuildView(viewOptions)
    local build = self.cachedBuild
    if not build then return false, "cached PCG Dungeon build is unavailable" end
    local normalized = self:NormalizeViewOptions(viewOptions)
    local keepCellDebug = self.cellDebugVisible == true
    if keepCellDebug then
        self.cellDebugVisible = false
        self:ClearCellDebugGeometry()
    end
    self:DestroyDungeonGeometry()
    local ok, result = self:BuildManifest(build.data, build.source, build.lightData,
        build.lightSource, build.pipelineStats, normalized)
    if not ok then
        self:DestroyDungeonGeometry()
        return false, result
    end
    build.viewOptions = normalized
    if keepCellDebug then
        self.cellDebugVisible = true
        local debugOk, debugReason = self:RefreshCellDebugGeometry()
        if not debugOk then
            self.cellDebugVisible = false
            log:Write(LOG_ERROR, "[PCGDungeon] cell debug view restore failed: " .. tostring(debugReason))
        end
    else
        self:RefreshEditorSelection()
    end
    return true, result
end

function PCGDungeonRenderer:Clear()
    self:ClearLightDebugGeometry()
    self:ClearCellDebugGeometry()
    for _, group in ipairs(self.groups) do
        if group then group:RemoveAllInstanceNodes() end
    end
    self.groups = {}
    self.groupInstanceNodes = {}
    self.resolvedMaterials = {}
    self.assetBindings = nil
    self.diagnosticMeshes = nil
    self.lightDefaults = nil
    self.lights = {}
    if self.root then self.root:Dispose(); self.root = nil end
    self.selectionRoot = nil
    self.selectionCellCount, self.selectionSurfaceY = 0, nil
    self.stats = nil
    self.previewStart = nil
    self.cellDebugData = nil
    self.cachedBuild = nil
    self.viewOptions = nil
    self.elapsed = 0
    self.referenceLightsEnabled = false
end

local function FindPreviewStart(data)
    local bestPosition, bestFloor, bestDistance = nil, math.huge, math.huge
    for _, group in ipairs(data.scene.instances or {}) do
        if string.lower(group.marker or "") == "ground" then
            for _, transform in ipairs(group.transforms or {}) do
                local position = ConvertPosition(transform)
                local distance = position.x * position.x + position.z * position.z
                if position.y < bestFloor - 0.001
                    or (math.abs(position.y - bestFloor) <= 0.001 and distance < bestDistance) then
                    bestPosition, bestFloor, bestDistance = position, position.y, distance
                end
            end
        end
    end
    return (bestPosition or Vector3.ZERO) + Vector3(0, 1.7, 0)
end

function PCGDungeonRenderer:GetPreviewStart()
    local position = self.previewStart or Vector3(0, 1.7, 0)
    return Vector3(position.x, position.y, position.z)
end

local function MaterialOverridePath(rule)
    local overrides = rule and rule.material_overrides or nil
    if type(overrides) ~= "table" or #overrides == 0 then return nil end
    local first = overrides[1]
    if type(first) == "string" then return first end
    if type(first) == "table" then return first.material or first.path end
    return nil
end

local function AddPreloadResource(resources, seen, resourceType, path)
    if type(path) ~= "string" or path == "" then return end
    local key = resourceType .. "\0" .. path
    if seen[key] then return end
    seen[key] = true
    resources[#resources + 1] = { type = resourceType, path = path }
end

local function AddMaterialOverrides(resources, seen, rule)
    for _, override in ipairs(rule and rule.material_overrides or {}) do
        local path = type(override) == "string" and override
            or type(override) == "table" and (override.material or override.path)
            or nil
        AddPreloadResource(resources, seen, "Material", path)
    end
end

function PCGDungeonRenderer:PreloadResources()
    if self.preloadStats then
        return self.preloadStats.failed == 0, self.preloadStats
    end
    local data, source = ReadManifest()
    if not data then return false, source end
    local valid, reason = ValidateManifest(data)
    if not valid then return false, reason end

    local resources, seen = {}, {}
    for _, binding in pairs(data.asset_bindings) do
        if type(binding) == "table" then
            AddPreloadResource(resources, seen, "Model", binding.model_resource)
            AddPreloadResource(resources, seen, "Material", binding.material_resource)
        end
    end
    for _, rule in ipairs(data.meshes or {}) do
        AddMaterialOverrides(resources, seen, rule)
        for _, part in ipairs(rule.parts or {}) do AddMaterialOverrides(resources, seen, part) end
    end
    for _, rule in ipairs(data.scatter_rules or {}) do AddMaterialOverrides(resources, seen, rule) end
    for _, modelPath in pairs(data.diagnostic_meshes or {}) do
        AddPreloadResource(resources, seen, "Model", modelPath)
    end
    table.sort(resources, function(a, b)
        if a.type == b.type then return a.path < b.path end
        return a.type < b.type
    end)

    local started, models, materials, failed = os.clock(), 0, 0, {}
    for _, resource in ipairs(resources) do
        local loaded = cache:GetResource(resource.type, resource.path)
        if loaded then
            if resource.type == "Model" then models = models + 1 else materials = materials + 1 end
        else
            failed[#failed + 1] = resource.type .. ":" .. resource.path
        end
    end
    self.preloadStats = {
        source = source,
        models = models,
        materials = materials,
        failed = #failed,
        loadMs = (os.clock() - started) * 1000,
    }
    print(string.format(
        "[PCGDungeon] preload complete models=%d materials=%d failed=%d loadMs=%.1f source=%s",
        models, materials, #failed, self.preloadStats.loadMs, tostring(source)))
    if #failed > 0 then
        log:Write(LOG_ERROR, "[PCGDungeon] preload failed: " .. table.concat(failed, ", "))
        return false, self.preloadStats
    end
    return true, self.preloadStats
end

function PCGDungeonRenderer:CreateGroup(name, assetPath, rule, inheritedRule)
    local binding = self.assetBindings and self.assetBindings[assetPath] or nil
    if type(binding) ~= "table" then
        print("[PCGDungeon] missing asset binding for " .. tostring(assetPath))
        return nil
    end
    local modelPath = binding.model_resource
    local model = cache:GetResource("Model", modelPath)
    if not model then
        print("[PCGDungeon] missing model " .. tostring(modelPath) .. " for " .. tostring(assetPath))
        return nil
    end
    local node = self.root:CreateChild(name)
    local group = node:CreateComponent("StaticModelGroup")
    group:SetModel(model)
    local materialPath = MaterialOverridePath(rule)
        or MaterialOverridePath(inheritedRule)
        or binding.material_resource
    if materialPath then
        local material = cache:GetResource("Material", materialPath)
        if material then
            group:SetMaterial(material)
            self.resolvedMaterials[name] = materialPath
        else
            print("[PCGDungeon] missing material " .. materialPath .. " for " .. name)
        end
    end
    local castShadow = rule and rule.cast_shadow
    if castShadow == nil and inheritedRule then castShadow = inheritedRule.cast_shadow end
    group.castShadows = castShadow ~= false
    self.groups[#self.groups + 1] = group
    return group, node
end

function PCGDungeonRenderer:AddGroupInstance(group, node)
    group:AddInstanceNode(node)
    local nodes = self.groupInstanceNodes[group]
    if not nodes then
        nodes = {}
        self.groupInstanceNodes[group] = nodes
    end
    nodes[#nodes + 1] = node
end

function PCGDungeonRenderer:AddRuleInstance(group, parent, transform, rule, suffix, partRule,
    floor, viewOptions)
    local marker = parent:CreateChild("Marker-" .. suffix)
    ApplyPackedTransform(marker, transform, self:FloorOffset(floor, viewOptions))
    local instance = marker
    if not IsIdentityRuleTransform(rule) then
        instance = marker:CreateChild("Offset")
        ApplyRuleTransform(instance, rule)
    end
    if partRule and not IsIdentityRuleTransform(partRule) then
        local part = instance:CreateChild("PrefabPart")
        ApplyRuleTransform(part, partRule)
        instance = part
    end
    local range = rule.override_uniform_scale_range
    if type(range) == "table" and #range == 2 then
        -- Hash the transform itself so a floor remains visually stable when
        -- another floor is temporarily filtered out of the candidate list.
        local hash = PlacementHash(rule.selection_seed or 0, transform, 0)
        local alpha = HashCombine(hash, 0xb5297a4d) / UINT32_MASK
        local uniform = range[1] + (range[2] - range[1]) * alpha
        instance.scale = Vector3(uniform, uniform, uniform)
    end
    self:AddGroupInstance(group, instance)
    return instance
end

function PCGDungeonRenderer:AddPointLight(parent, rule, hash)
    local node = parent:CreateChild("PointLight")
    node.position = ConvertPosition(rule.point_light_offset_cm)
    node.rotation = PCGDungeonCoordinateSystem.UERotatorToUrho(rule.point_light_rotation_deg)
    node.scale = Vector3(1, 1, 1)
    local light = node:CreateComponent("Light")
    light.color = ColorFromRule(rule, hash)
    local intensityNoise = ((hash & 0xffff) / 32767.5) - 1
    local radiusNoise = (((hash >> 16) & 0xffff) / 32767.5) - 1
    local baseBrightness = PhysicalBrightness(rule, self.lightDefaults, intensityNoise)
    local range = PointLightRange(rule, self.lightDefaults, radiusNoise)
    ConfigurePointLight(light, rule, self.lightDefaults, baseBrightness, range,
        rule.point_light_cast_shadows == true)
    self.lights[#self.lights + 1] = {
        node = node,
        light = light,
        baseBrightness = baseBrightness,
        lightFunction = rule.point_light_function_material,
        isBrazier = rule.component_group == "brazier_fire_point_light",
        ruleId = rule.id,
        marker = rule.marker,
    }
    return light
end

function PCGDungeonRenderer:BuildReferenceLights(data, viewOptions)
    if not self.lightingEnabled then return 0 end
    local root = self.root:CreateChild("ReferenceLights")
    local count = 0
    for index, record in ipairs(data.lights) do
        local profile = type(record) == "table" and data.profiles[record[4]] or nil
        local color = profile and profile.color or nil
        if type(record) ~= "table" or #record ~= 6 or type(color) ~= "table" or #color ~= 3 then
            return nil, "invalid reference light record " .. tostring(index)
        end
        local floor = self:TransformFloor({ 0, 0, record[2] * 100 }, nil, nil, viewOptions)
        if self:FloorVisible(floor, viewOptions) then
            local node = root:CreateChild("ReferenceLight-" .. index)
            node.position = Vector3(record[1], record[2] + self:FloorOffset(floor, viewOptions), record[3])
            node.scale = Vector3(1, 1, 1)
            local light = node:CreateComponent("Light")
            light.color = Color(color[1], color[2], color[3], 1)
            ConfigurePointLight(light, nil, data.defaults, profile.brightness, record[5], record[6] == true)
            self.lights[#self.lights + 1] = {
                node = node,
                light = light,
                baseBrightness = profile.brightness,
                lightFunction = profile.light_function,
                isBrazier = profile.light_function ~= nil,
            }
            count = count + 1
        end
    end
    return count
end

function PCGDungeonRenderer:SetLightDebugVisible(visible)
    if visible == true and self.cellDebugVisible then
        local disabled, reason = self:SetCellDebugVisible(false)
        if disabled == nil then
            self.lightDebugVisible = false
            return nil, reason
        end
    end
    self.lightDebugVisible = visible == true
    self:RefreshLightDebugGeometry()
    print(string.format("[PCGDungeon] light debug=%s lights=%d",
        tostring(self.lightDebugVisible), #self.lights))
    return self.lightDebugVisible, #self.lights
end

function PCGDungeonRenderer:ToggleLightDebug()
    return self:SetLightDebugVisible(not self.lightDebugVisible)
end

function PCGDungeonRenderer:RefreshLightDebugGeometry()
    self:ClearLightDebugGeometry()
    if not self.lightDebugVisible or #self.lights == 0 then return end

    local spherePath = self.diagnosticMeshes and self.diagnosticMeshes.light_volume or nil
    local sphere = spherePath and cache:GetResource("Model", spherePath) or nil
    if not sphere then
        log:Write(LOG_ERROR, "[PCGDungeon] missing diagnostic light-volume model "
            .. tostring(spherePath))
        return
    end

    local root = self.scene:CreateChild("PointLightDebugGeometry")
    local radiusMaterial = Material:new()
    radiusMaterial:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    radiusMaterial:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.32, 0.04, 0.006)))
    radiusMaterial:SetShaderParameter("MatEmissiveColor", Variant(Color(0.25, 0.055, 0.005, 1.0)))
    radiusMaterial:SetShaderParameter("Metallic", Variant(0.0))
    radiusMaterial:SetShaderParameter("Roughness", Variant(1.0))
    radiusMaterial.cullMode = CULL_NONE

    local radiusRoot = root:CreateChild("LightRadiusVolumes")
    local radiusGroup = radiusRoot:CreateComponent("StaticModelGroup")
    radiusGroup:SetModel(sphere)
    radiusGroup:SetMaterial(radiusMaterial)
    radiusGroup.castShadows = false
    radiusGroup.occludee = false

    local markerMaterial = Material:new()
    markerMaterial:SetTechnique(0, cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml"))
    markerMaterial:SetShaderParameter("MatDiffColor", Variant(Color(0.15, 4.0, 3.2, 1.0)))
    markerMaterial.cullMode = CULL_NONE

    local markerRoot = root:CreateChild("LightPositionMarkers")
    local markerGroup = markerRoot:CreateComponent("StaticModelGroup")
    markerGroup:SetModel(sphere)
    markerGroup:SetMaterial(markerMaterial)
    markerGroup.castShadows = false
    markerGroup.occludee = false

    local sphereSize = sphere.boundingBox.size
    local sphereDiameter = math.max(sphereSize.x, math.max(sphereSize.y, sphereSize.z))

    for _, entry in ipairs(self.lights) do
        local node, light = entry.node, entry.light
        if node and light then
            local center = node.worldPosition
            local radius = math.max(0, light.range)

            local radiusNode = radiusRoot:CreateChild("LightRadius")
            radiusNode.position = center
            local radiusScale = sphereDiameter > 0 and radius * 2 / sphereDiameter or radius * 2
            radiusNode.scale = Vector3(radiusScale, radiusScale, radiusScale)
            radiusGroup:AddInstanceNode(radiusNode)

            local markerNode = markerRoot:CreateChild("LightPosition")
            markerNode.position = center
            local markerDiameter = math.max(0.24, math.min(0.55, radius * 0.05))
            local markerScale = sphereDiameter > 0 and markerDiameter / sphereDiameter or markerDiameter
            markerNode.scale = Vector3(markerScale, markerScale, markerScale)
            markerGroup:AddInstanceNode(markerNode)
        end
    end
    self.lightDebugRoot = root
    self.lightDebugMaterial = radiusMaterial
    self.lightDebugMarkerMaterial = markerMaterial
    print(string.format("[PCGDungeon] built light debug geometry lights=%d radiusGroups=1", #self.lights))
end

local function DungeonPosition(value)
    value = value or { 0, 0, 0 }
    return Vector3(value[3] or 0, value[2] or 0, value[1] or 0)
end

local function DungeonSize(value)
    value = value or { 1, 1, 1 }
    return Vector3(value[3] or 1, value[2] or 1, value[1] or 1)
end

local function CreateCellDebugMaterial(color)
    local technique = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")
    if not technique then return nil, "missing Techniques/PBR/PBRNoTexture.xml for cell debug" end
    local material = Material:new()
    material:SetTechnique(0, technique)
    material:SetShaderParameter("MatDiffColor", Variant(Color(color[1], color[2], color[3], color[4])))
    material:SetShaderParameter("MatEmissiveColor", Variant(Color(
        color[1] * 1.5, color[2] * 1.5, color[3] * 1.5, 1.0)))
    material:SetShaderParameter("Metallic", Variant(0.0))
    material:SetShaderParameter("Roughness", Variant(0.85))
    material.cullMode = CULL_NONE
    return material
end

local function AddCellDebugInstance(parent, model, material, modelBounds, center, size, name)
    local modelSize, modelCenter = modelBounds.size, modelBounds.center
    local scale = Vector3(
        size.x * CELL_DEBUG_INSET / math.max(0.000001, modelSize.x),
        size.y * CELL_DEBUG_INSET / math.max(0.000001, modelSize.y),
        size.z * CELL_DEBUG_INSET / math.max(0.000001, modelSize.z))
    local node = parent:CreateChild(name)
    node.position = center - Vector3(
        modelCenter.x * scale.x, modelCenter.y * scale.y, modelCenter.z * scale.z)
    node.scale = scale
    local drawable = node:CreateComponent("StaticModel")
    drawable:SetModel(model)
    drawable:SetMaterial(material)
    drawable.castShadows = false
    drawable.occludee = false
end

function PCGDungeonRenderer:RefreshEditorSelection()
    if self.selectionRoot then self.selectionRoot:Dispose(); self.selectionRoot = nil end
    self.selectionCellCount, self.selectionSurfaceY = 0, nil
    if not self.root or self.cellDebugVisible or self.selectionRoomId == nil then return end
    local data = self.cellDebugData
    if not data or type(data.cells) ~= "table" then return end
    local cubePath = self.diagnosticMeshes and self.diagnosticMeshes.cell_volume or "Models/Box.mdl"
    local cube = cache:GetResource("Model", cubePath)
    if not cube then return end
    if not self.selectionMaterial then
        self.selectionMaterial = CreateCellDebugMaterial({ 1.0, 0.32, 0.02, 1.0 })
        if not self.selectionMaterial then return end
    end

    local cellSize = tonumber(data.cellSize) or 5.0
    local root = self.root:CreateChild("EditorSelectionHighlight")
    for _, cell in ipairs(data.cells) do
        if tonumber(cell.cell_type) == 1 and tonumber(cell.room_id) == self.selectionRoomId then
            local surfaceY = cell.position[2] - cellSize * 0.5 + EDITOR_SELECTION_HEIGHT
            if self.selectionSurfaceY == nil then self.selectionSurfaceY = surfaceY end
            AddCellDebugInstance(root, cube, self.selectionMaterial, cube.boundingBox,
                DungeonPosition(cell.position) + Vector3(0, EDITOR_SELECTION_HEIGHT - cellSize * 0.5, 0),
                Vector3(cellSize, 0.12, cellSize), "SelectedRoomCell-" .. tostring(cell.id))
            self.selectionCellCount = self.selectionCellCount + 1
        end
    end
    if self.selectionCellCount > 0 then self.selectionRoot = root else root:Dispose() end
end

function PCGDungeonRenderer:SetEditorSelection(dungeon, roomIndex)
    self.selectionDungeon = dungeon
    self.selectionRoomIndex = roomIndex
    self.selectionRoomId = roomIndex and roomIndex - 1 or nil
    self:RefreshEditorSelection()
end

function PCGDungeonRenderer:ClearEditorSelection()
    if self.selectionRoot then self.selectionRoot:Dispose(); self.selectionRoot = nil end
    self.selectionDungeon = nil
    self.selectionRoomIndex = nil
    self.selectionRoomId = nil
    self.selectionCellCount, self.selectionSurfaceY = 0, nil
end

function PCGDungeonRenderer:SetCellDebugVisible(visible)
    if visible == true and self.lightDebugVisible then
        self.lightDebugVisible = false
        self:ClearLightDebugGeometry()
    end
    self.cellDebugVisible = visible == true
    local ok, statsOrReason
    if self.cellDebugVisible then
        ok, statsOrReason = self:RefreshCellDebugGeometry()
    else
        self:ClearCellDebugGeometry()
        ok, statsOrReason = self:RestoreDungeonGeometry()
        if ok then
            self:RefreshEditorSelection()
            statsOrReason = { rooms = 0, corridors = 0, stairs = 0, total = 0 }
        end
    end
    if not ok then
        self.cellDebugVisible = false
        self:ClearCellDebugGeometry()
        return nil, statsOrReason
    end
    print(string.format("[PCGDungeon] cell debug=%s boxes=%d",
        tostring(self.cellDebugVisible), statsOrReason.total or 0))
    return self.cellDebugVisible, statsOrReason
end

function PCGDungeonRenderer:ToggleCellDebug()
    return self:SetCellDebugVisible(not self.cellDebugVisible)
end

function PCGDungeonRenderer:RefreshCellDebugGeometry()
    self:ClearCellDebugGeometry()
    if not self.cellDebugVisible then
        return true, { rooms = 0, corridors = 0, stairs = 0, total = 0 }
    end
    local data = self.cellDebugData
    if not data or type(data.rooms) ~= "table" or type(data.cells) ~= "table" then
        return false, "PCG Dungeon canonical cells are unavailable"
    end

    local cubePath = self.diagnosticMeshes and self.diagnosticMeshes.cell_volume or nil
    local cube = cubePath and cache:GetResource("Model", cubePath) or nil
    if not cube then return false, "missing diagnostic cell-volume model " .. tostring(cubePath) end
    local modelBounds = cube.boundingBox
    local root = self.scene:CreateChild("PCGDungeonCellDebug")
    local groupRoots, materials, materialsByKey = {}, {}, {}

    for _, key in ipairs({ "room", "corridor", "stair" }) do
        local style = CELL_DEBUG_STYLE[key]
        local material, reason = CreateCellDebugMaterial(style.color)
        if not material then
            root:Dispose()
            for _, created in ipairs(materials) do created:Dispose() end
            return false, reason
        end
        materials[#materials + 1] = material
        local groupRoot = root:CreateChild(style.nodeName)
        materialsByKey[key], groupRoots[key] = material, groupRoot
    end

    local stats = { rooms = 0, corridors = 0, stairs = 0, physicalStairs = 0, headroom = 0 }
    for _, room in ipairs(data.rooms) do
        if room.position and room.size then
            stats.rooms = stats.rooms + 1
            AddCellDebugInstance(groupRoots.room, cube, materialsByKey.room, modelBounds,
                DungeonPosition(room.position), DungeonSize(room.size), "Room-" .. tostring(room.id))
        end
    end

    local cellSize = math.max(0.001, tonumber(data.cellSize) or 5.0)
    local cellDimensions = Vector3(cellSize, cellSize, cellSize)
    for _, cell in ipairs(data.cells) do
        local cellType = tonumber(cell.cell_type)
        if cell.position and cellType == 2 then
            stats.corridors = stats.corridors + 1
            AddCellDebugInstance(groupRoots.corridor, cube, materialsByKey.corridor, modelBounds,
                DungeonPosition(cell.position), cellDimensions, "Corridor-" .. tostring(cell.id))
        elseif cell.position and (cellType == 3 or cellType == 4) then
            stats.stairs = stats.stairs + 1
            if cellType == 3 then stats.physicalStairs = stats.physicalStairs + 1
            else stats.headroom = stats.headroom + 1 end
            AddCellDebugInstance(groupRoots.stair, cube, materialsByKey.stair, modelBounds,
                DungeonPosition(cell.position), cellDimensions, "Stair-" .. tostring(cell.id))
        end
    end
    stats.total = stats.rooms + stats.corridors + stats.stairs
    self.cellDebugRoot, self.cellDebugMaterials, self.cellDebugStats = root, materials, stats
    self:DestroyDungeonGeometry()
    print(string.format(
        "[PCGDungeon] built cell debug rooms=%d corridors=%d stairs=%d physical=%d headroom=%d",
        stats.rooms, stats.corridors, stats.stairs, stats.physicalStairs, stats.headroom))
    return true, stats
end

function PCGDungeonRenderer:BuildBase(data, transformsByMesh, roomsByMesh, floorsByMesh, viewOptions)
    local inheritByMesh, prefabBySource, lightByMesh, rulesById = {}, {}, {}, {}
    for _, rule in ipairs(data.meshes or {}) do
        if rule.id then rulesById[rule.id] = rule end
        if rule.usage == "prefab" then prefabBySource[rule.source_mesh] = rule
        elseif rule.usage == "point_light_marker" then lightByMesh[rule.mesh] = rule
        elseif rule.usage == "inherit" and not inheritByMesh[rule.mesh] then inheritByMesh[rule.mesh] = rule end
    end
    local count = 0
    for _, source in ipairs(data.scene.instances) do
        local visibleTransforms, visibleRooms, visibleFloors = {}, {}, {}
        for index, transform in ipairs(source.transforms) do
            local floor = self:TransformFloor(transform, (source.floor_ids or {})[index], source.marker, viewOptions)
            if self:FloorVisible(floor, viewOptions) then
                visibleTransforms[#visibleTransforms + 1] = transform
                visibleRooms[#visibleRooms + 1] = (source.room_ids or {})[index] or -1
                visibleFloors[#visibleFloors + 1] = floor
            end
        end
        if #visibleTransforms > 0 then
            transformsByMesh[source.mesh] = transformsByMesh[source.mesh] or {}
            roomsByMesh[source.mesh] = roomsByMesh[source.mesh] or {}
            floorsByMesh[source.mesh] = floorsByMesh[source.mesh] or {}
            for index, transform in ipairs(visibleTransforms) do
                transformsByMesh[source.mesh][#transformsByMesh[source.mesh] + 1] = transform
                roomsByMesh[source.mesh][#roomsByMesh[source.mesh] + 1] = visibleRooms[index]
                floorsByMesh[source.mesh][#floorsByMesh[source.mesh] + 1] = visibleFloors[index]
            end
        end
        local selectedRule = source.rule_id and rulesById[source.rule_id] or nil
        local prefab = selectedRule and selectedRule.usage == "prefab" and selectedRule
            or prefabBySource[source.mesh]
        local rule = selectedRule and selectedRule.usage == "inherit" and selectedRule
            or inheritByMesh[source.mesh]
        if #visibleTransforms > 0 and prefab and prefab.visible ~= false then
            for partIndex, part in ipairs(prefab.parts or {}) do
                if part.visible ~= false then
                    local partId = part.id or tostring(partIndex)
                    local group, node = self:CreateGroup(
                        "Prefab-" .. prefab.id .. "-" .. partId, part.mesh, part, prefab)
                    if group then
                        for index, transform in ipairs(visibleTransforms) do
                            self:AddRuleInstance(group, node, transform, prefab, index - 1, part,
                                visibleFloors[index], viewOptions)
                            count = count + 1
                        end
                    end
                end
            end
        elseif #visibleTransforms > 0 and rule and rule.visible ~= false and not lightByMesh[source.mesh] then
            local group, node = self:CreateGroup("PCGDungeon-" .. rule.id, rule.mesh, rule)
            if group then
                for index, transform in ipairs(visibleTransforms) do
                    self:AddRuleInstance(group, node, transform, rule, index - 1, nil,
                        visibleFloors[index], viewOptions)
                    count = count + 1
                end
            end
        end
    end
    return count
end

function PCGDungeonRenderer:BuildAttachments(data, transformsByMesh, floorsByMesh, viewOptions)
    local count, lightCount = 0, 0
    for _, rule in ipairs(data.meshes or {}) do
        if rule.usage == "attach" and rule.visible ~= false then
            local transforms = transformsByMesh[rule.source_mesh]
            local group, node = nil, nil
            if transforms then group, node = self:CreateGroup("Attach-" .. rule.id, rule.mesh, rule) end
            if transforms and group then
                local candidates = {}
                for index, transform in ipairs(transforms) do
                    candidates[#candidates + 1] = {
                        index = index, hash = PlacementHash(rule.selection_seed or 0, transform, 0),
                    }
                end
                table.sort(candidates, CandidateSort)
                local selected = math.max(0, math.min(#transforms, RoundToInt(#transforms * (rule.density or 1))))
                for candidateIndex = 1, selected do
                    local candidate = candidates[candidateIndex]
                    local instance = self:AddRuleInstance(
                        group, node, transforms[candidate.index], rule, candidate.index - 1, nil,
                        floorsByMesh[rule.source_mesh][candidate.index], viewOptions)
                    if rule.point_light_enabled and self.lightingEnabled and not self.referenceLightsEnabled then
                        self:AddPointLight(instance, rule, candidate.hash)
                        lightCount = lightCount + 1
                    end
                    count = count + 1
                end
            end
        end
    end
    return count, lightCount
end

local function AppendCandidates(target, candidates, count)
    table.sort(candidates, CandidateSort)
    for index = 1, math.min(count, #candidates) do target[#target + 1] = candidates[index] end
end

function PCGDungeonRenderer:BuildMarkerLights(data, transformsByMesh, roomsByMesh, floorsByMesh,
    viewOptions)
    if not self.lightingEnabled or self.referenceLightsEnabled then return 0 end
    local count = 0
    local lightRoot = self.root:CreateChild("ManifestLights")
    for _, rule in ipairs(data.meshes or {}) do
        if rule.usage == "point_light_marker" and rule.point_light_enabled ~= false then
            local transforms, roomIds = transformsByMesh[rule.mesh], roomsByMesh[rule.mesh]
            if transforms then
                local candidates = {}
                for index, transform in ipairs(transforms) do
                    candidates[#candidates + 1] = {
                        index = index, hash = PlacementHash(rule.selection_seed or 0, transform, 0),
                        localOffset = nil,
                    }
                end
                local selected = {}
                if (rule.minimum_per_room or 0) > 0 and #roomIds == #transforms then
                    local byRoom, unowned = {}, {}
                    for _, candidate in ipairs(candidates) do
                        local roomId = roomIds[candidate.index]
                        if roomId and roomId >= 0 then
                            byRoom[roomId] = byRoom[roomId] or {}
                            byRoom[roomId][#byRoom[roomId] + 1] = candidate
                        else
                            unowned[#unowned + 1] = candidate
                        end
                    end
                    for _, roomCandidates in pairs(byRoom) do
                        table.sort(roomCandidates, CandidateSort)
                        local sourceCount = math.max(
                            math.min(rule.minimum_per_room, #roomCandidates),
                            math.min(#roomCandidates, RoundToInt(#roomCandidates * (rule.density or 1))))
                        AppendCandidates(selected, roomCandidates, sourceCount)
                        for duplicateIndex = #roomCandidates, rule.minimum_per_room - 1 do
                            local source = roomCandidates[(duplicateIndex % #roomCandidates) + 1]
                            local duplicate = {
                                index = source.index,
                                hash = HashCombine(source.hash, U32(duplicateIndex + 1)),
                                localOffset = {},
                            }
                            local offset = rule.minimum_room_duplicate_offset_cm or { 0, 0, 0 }
                            local multiple = duplicateIndex - #roomCandidates + 1
                            duplicate.localOffset = { offset[1] * multiple, offset[2] * multiple, offset[3] * multiple }
                            selected[#selected + 1] = duplicate
                        end
                    end
                    AppendCandidates(selected, unowned, RoundToInt(#unowned * (rule.density or 1)))
                else
                    AppendCandidates(selected, candidates, RoundToInt(#candidates * (rule.density or 1)))
                end
                for _, candidate in ipairs(selected) do
                    local marker = lightRoot:CreateChild(rule.id .. "-" .. candidate.index)
                    local floor = floorsByMesh[rule.mesh][candidate.index]
                    ApplyPackedTransform(marker, transforms[candidate.index],
                        self:FloorOffset(floor, viewOptions))
                    local parent = marker
                    if candidate.localOffset then
                        parent = marker:CreateChild("DuplicateOffset")
                        parent.position = ConvertPosition(candidate.localOffset)
                    end
                    self:AddPointLight(parent, rule, candidate.hash)
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function Cross(a, b)
    return {
        a[2] * b[3] - a[3] * b[2],
        a[3] * b[1] - a[1] * b[3],
        a[1] * b[2] - a[2] * b[1],
    }
end

local function VectorLength(value)
    return math.sqrt(value[1] * value[1] + value[2] * value[2] + value[3] * value[3])
end

function PCGDungeonRenderer:BuildScatter(data, viewOptions)
    local surfaces = {}
    for _, surface in ipairs(data.scene.surfaces or {}) do surfaces[string.lower(surface.name)] = surface end
    local sharedAccepted, total = {}, 0
    for _, rule in ipairs(data.scatter_rules or {}) do
        local surface = surfaces[string.lower(rule.surface or "")]
        if rule.enabled ~= false and rule.visible ~= false and surface then
            local group, node = self:CreateGroup("Scatter-" .. rule.id, rule.mesh, rule)
            if group then
                local vertices, indices = surface.vertices_cm or {}, surface.indices or {}
                local accepted = rule.spacing_group and sharedAccepted[rule.spacing_group] or nil
                if not accepted then
                    accepted = {}
                    if rule.spacing_group then sharedAccepted[rule.spacing_group] = accepted end
                end
                local minimumSpacing = rule.min_spacing_cm or rule.cluster_min_spacing_cm or 0
                local noiseScale = rule.noise_scale_cm or rule.cluster_scale_cm or 1000
                local noiseThreshold = rule.noise_threshold or rule.cluster_threshold or 0
                local noiseSeed = rule.noise_seed or rule.cluster_seed or rule.seed or 0
                local yawRange = rule.random_yaw_deg or { 0, 360 }
                local scaleRange = rule.uniform_scale_range or { 1, 1 }
                local offset = rule.offset_cm or { 0, 0, 0 }
                for offsetIndex = 1, #indices, 3 do
                    -- Dynamic PCG surfaces carry one floor id per triangle so
                    -- each floor's decoration slider scales every scatter rule.
                    local triangleIndex = (offsetIndex - 1) // 3
                    local floorId = surface.triangle_floor_ids
                        and surface.triangle_floor_ids[triangleIndex + 1] or nil
                    local ia, ib, ic = indices[offsetIndex] * 3 + 1, indices[offsetIndex + 1] * 3 + 1, indices[offsetIndex + 2] * 3 + 1
                    local a = { vertices[ia], vertices[ia + 1], vertices[ia + 2] }
                    local b = { vertices[ib], vertices[ib + 1], vertices[ib + 2] }
                    local c = { vertices[ic], vertices[ic + 1], vertices[ic + 2] }
                    if floorId == nil then
                        local averageY = (a[2] + b[2] + c[2]) / 3
                        floorId = self:TransformFloor({ 0, 0, averageY }, nil, nil, viewOptions)
                    end
                    local densityMultiplier = self:FloorVisible(floorId, viewOptions) and 1 or 0
                    if densityMultiplier > 0 and floorId ~= nil
                        and type(data.scene.scatter_density_by_floor) == "table" then
                        local configured = tonumber(data.scene.scatter_density_by_floor[floorId + 1])
                        if configured ~= nil then
                            densityMultiplier = math.max(0, math.min(1, configured))
                        end
                    end
                    local cross = Cross({ b[1] - a[1], b[2] - a[2], b[3] - a[3] },
                        { c[1] - a[1], c[2] - a[2], c[3] - a[3] })
                    local area = 0.5 * VectorLength(cross)
                    if area > 0.000001 then
                        local stream = NewRandomStream(HashCombine(U32(rule.seed or 0), U32(triangleIndex)))
                        local exact = area / 10000 * (rule.candidate_density_per_square_meter or 0)
                            * densityMultiplier
                        local candidateCount = math.floor(exact)
                        if RandomFraction(stream) < exact - candidateCount then candidateCount = candidateCount + 1 end
                        for _ = 1, candidateCount do
                            local root = math.sqrt(RandomFraction(stream))
                            local along = RandomFraction(stream)
                            local location = {
                                (1 - root) * a[1] + root * (1 - along) * b[1] + root * along * c[1],
                                (1 - root) * a[2] + root * (1 - along) * b[2] + root * along * c[2],
                                (1 - root) * a[3] + root * (1 - along) * b[3] + root * along * c[3],
                            }
                            local nx = location[1] / noiseScale + noiseSeed * 0.0137
                            local ny = location[2] / noiseScale - noiseSeed * 0.0211
                            if PerlinNoise2D(nx, ny) * 0.5 + 0.5 >= noiseThreshold then
                                local allowed = true
                                for _, existing in ipairs(accepted) do
                                    local dx, dy, dz = location[1] - existing[1], location[2] - existing[2], location[3] - existing[3]
                                    if dx * dx + dy * dy + dz * dz < minimumSpacing * minimumSpacing then
                                        allowed = false; break
                                    end
                                end
                                if allowed then
                                    local yaw = RandomRange(stream, yawRange[1], yawRange[2])
                                    local scale = RandomRange(stream, scaleRange[1], scaleRange[2])
                                    location = { location[1] + offset[1], location[2] + offset[2], location[3] + offset[3] }
                                    local instance = node:CreateChild(rule.id .. "-" .. total)
                                    local position = ConvertPosition(location)
                                    position.y = position.y + self:FloorOffset(floorId, viewOptions)
                                    instance.position = position
                                    instance.rotation = PCGDungeonCoordinateSystem.UEScatterRotation(
                                        cross, rule.local_up_axis, yaw, rule.align_to_normal == true)
                                    instance.scale = Vector3(scale, scale, scale)
                                    self:AddGroupInstance(group, instance)
                                    accepted[#accepted + 1] = location
                                    total = total + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return total
end

function PCGDungeonRenderer:BuildManifest(data, source, lightData, lightSource, pipelineStats,
    viewOptions)
    local started = os.clock()
    local valid, reason = ValidateManifest(data)
    if not valid then return false, reason end
    viewOptions = self:NormalizeViewOptions(viewOptions)
    self.viewOptions = viewOptions
    self.referenceLightsEnabled = lightData ~= nil
    self.assetBindings = data.asset_bindings
    self.diagnosticMeshes = data.diagnostic_meshes
    self.lightDefaults = data.light_defaults
    if not self.lightingEnabled then
        print("[PCGDungeon] all scene lights disabled")
    elseif not lightData then
        print("[PCGDungeon] reference lights unavailable; using deterministic fallback: " .. tostring(lightSource))
    end
    self.previewStart = FindPreviewStart(data)
    self.root = self.scene:CreateChild("PCGDungeon")
    local transformsByMesh, roomsByMesh, floorsByMesh = {}, {}, {}
    local baseCount = self:BuildBase(data, transformsByMesh, roomsByMesh, floorsByMesh, viewOptions)
    local attachCount, companionLights = self:BuildAttachments(data, transformsByMesh, floorsByMesh, viewOptions)
    local markerLights = self:BuildMarkerLights(
        data, transformsByMesh, roomsByMesh, floorsByMesh, viewOptions)
    local referenceLights = 0
    if lightData then
        referenceLights, reason = self:BuildReferenceLights(lightData, viewOptions)
        if not referenceLights then return false, reason end
    end
    local scatterCount = self:BuildScatter(data, viewOptions)
    self.stats = {
        source = source,
        sourceInstances = data.scene.instance_count,
        baseInstances = baseCount,
        attachedInstances = attachCount,
        scatterInstances = scatterCount,
        lights = referenceLights + companionLights + markerLights,
        referenceLights = referenceLights,
        companionLights = companionLights,
        markerLights = markerLights,
        lightSource = self.lightingEnabled
            and (lightData and lightSource or "deterministic fallback") or "disabled",
        groups = #self.groups,
        markerCount = pipelineStats and pipelineStats.markerCount or nil,
        faceCount = pipelineStats and pipelineStats.faceCount or nil,
        buildMs = (os.clock() - started) * 1000,
    }
    self:RefreshLightDebugGeometry()
    self:RefreshEditorSelection()
    print(string.format(
        "[PCGDungeon] refreshed source=%d base=%d attached=%d scatter=%d lights=%d groups=%d buildMs=%.1f",
        self.stats.sourceInstances, baseCount, attachCount, scatterCount, self.stats.lights,
        self.stats.groups, self.stats.buildMs))
    return true, self.stats
end

function PCGDungeonRenderer:Rebuild()
    self:Clear()
    self.cellDebugVisible = false
    local data, source = ReadManifest()
    if not data then return false, source end
    local lightData, lightSource = ReadLightManifest()
    local ok, result = self:BuildManifest(data, source, lightData, lightSource, nil,
        { viewMode = "all", currentFloor = 0 })
    if ok then
        self.cachedBuild = {
            data = data, source = source, lightData = lightData, lightSource = lightSource,
            viewOptions = self.viewOptions,
        }
    end
    return ok, result
end

function PCGDungeonRenderer:RebuildFromMarkers(markerResult, cellDebugData, viewOptions)
    self:Clear()
    local data, source = ReadManifest()
    if not data then return false, source end
    local adapted, pipelineStats = PCGDungeonMeshInfoAdapter.Apply(data, markerResult, cellDebugData)
    if not adapted then return false, pipelineStats end
    local ok, result = self:BuildManifest(adapted, "pcg-runtime + " .. source,
        nil, "dynamic Marker lights", pipelineStats, viewOptions)
    if not ok then return false, result end
    self.cachedBuild = {
        data = adapted,
        source = "pcg-runtime + " .. source,
        lightData = nil,
        lightSource = "dynamic Marker lights",
        pipelineStats = pipelineStats,
        viewOptions = self.viewOptions,
    }
    self.cellDebugData = cellDebugData
    local debugOk, debugReason = self:RefreshCellDebugGeometry()
    if not debugOk then
        log:Write(LOG_ERROR, "[PCGDungeon] cell debug rebuild failed: " .. tostring(debugReason))
        self.cellDebugVisible = false
        self:ClearCellDebugGeometry()
    end
    self:RefreshEditorSelection()
    return true, result
end

function PCGDungeonRenderer:Update(timeStep)
    self.elapsed = self.elapsed + math.max(0, timeStep or 0)
    for _, entry in ipairs(self.lights) do
        if entry.isBrazier then
            local position = entry.node.worldPosition
            -- UE light function uses WorldPos.xy in centimeters. UE X/Y map to UrhoX Z/X.
            local phase = position.z * 1.3 + position.x * 1.7
            local multiplier = 0.94
                + 0.04 * math.sin(self.elapsed * 2.7 + phase)
                + 0.02 * math.sin(self.elapsed * 7.1 + phase * 1.73)
            entry.light.brightness = entry.baseBrightness * multiplier
        end
    end
end

function PCGDungeonRenderer:Dispose()
    self:ClearEditorSelection()
    self:Clear()
    if self.selectionMaterial then self.selectionMaterial:Dispose(); self.selectionMaterial = nil end
end

return PCGDungeonRenderer
