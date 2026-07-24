local BgeoDungeonRenderer = {}
BgeoDungeonRenderer.__index = BgeoDungeonRenderer

local FirstPersonDoorSystem = require("Gameplay.FirstPersonDoorSystem")
local HoudiniCoordinateSystem = require("Generation.HoudiniCoordinateSystem")
local HoudiniMeshInfoAdapter = require("Generation.HoudiniMeshInfoAdapter")

local MANIFEST_CANDIDATES = {
    "assets/BgeoDungeon/DungeonInstances.mesh_info.json",
    "BgeoDungeon/DungeonInstances.mesh_info.json",
}
local LIGHT_MANIFEST_CANDIDATES = {
    "assets/BgeoDungeon/DungeonMap.lights.json",
    "BgeoDungeon/DungeonMap.lights.json",
}
local UINT32_MASK = 0xffffffff
local UE_UNITLESS_CM_TO_M2_SCALE = 0.0001
local BRAZIER_LIGHT_FUNCTION = "/Game/HoudiniImports/Support/M_BrazierLightFlicker.M_BrazierLightFlicker"
local CELL_DEBUG_INSET = 0.96
local CELL_DEBUG_STYLE = {
    room = { nodeName = "RoomVolumes", color = { 1.0, 0.5, 0.0, 1.0 } },
    corridor = { nodeName = "CorridorCells", color = { 0.0, 0.5, 1.0, 1.0 } },
    stair = { nodeName = "StairCells", color = { 0.0, 1.0, 0.0, 1.0 } },
}

local MATERIAL_BY_MODEL = {
    floor01 = "Materials/pavement2.xml",
    wall01 = "Materials/brick2.xml",
    curbstone01 = "Materials/curbstone.xml",
    curbstone04 = "Materials/curbstone.xml",
    cross = "Materials/Jail.xml",
    wall01arch1 = "Materials/brick2.xml",
    doorarch01 = "Materials/DoorArch.xml",
    door02 = "Materials/Door1.xml",
    column03 = "Materials/column.xml",
    roaster02 = "Materials/Chandelier.xml",
    stairs01 = "Materials/Stairs.xml",
    roof11 = "Materials/Roof02.xml",
    spiderweb04 = "Materials/SpiderWeb.xml",
    brick01 = "Materials/BrickDamage.xml",
    brick02 = "Materials/BrickDamage.xml",
    brick03 = "Materials/BrickDamage.xml",
    brick04 = "Materials/BrickDamage.xml",
    brick05 = "Materials/BrickDamage.xml",
    brick06 = "Materials/BrickDamage.xml",
    rock01 = "Materials/BrickDamage.xml",
    rock02 = "Materials/BrickDamage.xml",
    rock03 = "Materials/BrickDamage.xml",
    bone01 = "Materials/Bones.xml",
    bone02 = "Materials/Bones.xml",
    bone03 = "Materials/Bones.xml",
    scull01 = "Materials/Bones.xml",
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

local function AssetName(path)
    local segment = tostring(path or ""):match("([^/]+)$") or ""
    return segment:match("^([^.]+)") or segment
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
    return nil, "DungeonInstances.mesh_info.json was not found"
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
    return nil, "DungeonMap.lights.json was not found"
end

local function ValidateManifest(data)
    if type(data.scene) ~= "table" then return false, "scene block is missing" end
    if data.scene.schema_version ~= 1 then return false, "unsupported scene schema" end
    if type(data.scene.instances) ~= "table" then return false, "scene.instances is missing" end
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
        if group.rule_id and not rulesById[group.rule_id] then
            return false, "scene instance group references unknown rule_id: " .. tostring(group.rule_id)
        end
        instanceCount = instanceCount + #group.transforms
    end
    if instanceCount ~= (data.scene.instance_count or -1) then
        return false, "instance count does not match manifest declaration"
    end
    return true
end

local function ConvertPosition(values)
    return HoudiniCoordinateSystem.PackedPositionToUrho(values)
end

local function ConvertScale(values)
    return HoudiniCoordinateSystem.PackedScaleToUrho(values)
end

local function ApplyPackedTransform(node, values)
    node.position = ConvertPosition(values)
    node.rotation = HoudiniCoordinateSystem.PackedQuaternionToUrho(values)
    node.scale = HoudiniCoordinateSystem.PackedTransformScaleToUrho(values)
end

local function IsIdentityRuleTransform(rule)
    local p, r, s = rule.offset_cm or { 0, 0, 0 }, rule.rotation_deg or { 0, 0, 0 }, rule.scale or { 1, 1, 1 }
    return p[1] == 0 and p[2] == 0 and p[3] == 0
        and r[1] == 0 and r[2] == 0 and r[3] == 0
        and s[1] == 1 and s[2] == 1 and s[3] == 1
end

local function ApplyRuleTransform(node, rule)
    node.position = ConvertPosition(rule.offset_cm)
    node.rotation = HoudiniCoordinateSystem.UERotatorToUrho(rule.rotation_deg)
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

local function PhysicalBrightness(rule, intensityNoise)
    local intensity = (rule.point_light_intensity or 100)
        * (1 + intensityNoise * (rule.point_light_intensity_variation or 0))
    if (rule.point_light_units or "Unitless") == "Unitless" then
        return intensity * UE_UNITLESS_CM_TO_M2_SCALE
    end
    return intensity
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

function BgeoDungeonRenderer.new(scene)
    return setmetatable({
        scene = scene, root = nil, groups = {}, lights = {}, stats = nil, previewStart = nil,
        resolvedMaterials = {},
        doorSystem = FirstPersonDoorSystem.new(),
        lightDebugVisible = false, lightDebugRoot = nil,
        lightDebugMaterial = nil, lightDebugMarkerMaterial = nil, elapsed = 0,
        cellDebugVisible = false, cellDebugRoot = nil, cellDebugMaterials = {},
        cellDebugData = nil, cellDebugStats = nil, cachedBuild = nil,
        groupInstanceNodes = {},
        referenceLightsEnabled = false,
        lightingEnabled = true,
    }, BgeoDungeonRenderer)
end

function BgeoDungeonRenderer:SetLightingEnabled(enabled)
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

function BgeoDungeonRenderer:ClearLightDebugGeometry()
    if self.lightDebugRoot then self.lightDebugRoot:Dispose(); self.lightDebugRoot = nil end
    if self.lightDebugMaterial then self.lightDebugMaterial:Dispose(); self.lightDebugMaterial = nil end
    if self.lightDebugMarkerMaterial then
        self.lightDebugMarkerMaterial:Dispose()
        self.lightDebugMarkerMaterial = nil
    end
end

function BgeoDungeonRenderer:ClearCellDebugGeometry()
    if self.cellDebugRoot then self.cellDebugRoot:Dispose(); self.cellDebugRoot = nil end
    for _, material in ipairs(self.cellDebugMaterials or {}) do material:Dispose() end
    self.cellDebugMaterials = {}
    self.cellDebugStats = nil
end

function BgeoDungeonRenderer:DestroyDungeonGeometry()
    self:ClearLightDebugGeometry()
    self.doorSystem:Clear()
    if self.root then self.root:Dispose(); self.root = nil end
    self.groups = {}
    self.groupInstanceNodes = {}
    self.resolvedMaterials = {}
    self.lights = {}
end

function BgeoDungeonRenderer:RestoreDungeonGeometry()
    if self.root then return true, self.stats end
    local build = self.cachedBuild
    if not build then return false, "cached Shadow Castle build is unavailable" end
    return self:BuildManifest(build.data, build.source, build.lightData, build.lightSource, build.pipelineStats)
end

function BgeoDungeonRenderer:Clear()
    self:ClearLightDebugGeometry()
    self:ClearCellDebugGeometry()
    for _, group in ipairs(self.groups) do
        if group then group:RemoveAllInstanceNodes() end
    end
    self.groups = {}
    self.groupInstanceNodes = {}
    self.resolvedMaterials = {}
    self.lights = {}
    self.doorSystem:Clear()
    if self.root then self.root:Dispose(); self.root = nil end
    self.stats = nil
    self.previewStart = nil
    self.cellDebugData = nil
    self.cachedBuild = nil
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

function BgeoDungeonRenderer:GetPreviewStart()
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

function BgeoDungeonRenderer:CreateGroup(name, unrealPath, rule)
    local modelName = AssetName(unrealPath)
    local model = cache:GetResource("Model", "Models/" .. modelName .. ".mdl")
    if not model then
        print("[BgeoDungeon] missing model Models/" .. modelName .. ".mdl")
        return nil
    end
    local node = self.root:CreateChild(name)
    local group = node:CreateComponent("StaticModelGroup")
    group:SetModel(model)
    local materialPath = MaterialOverridePath(rule) or MATERIAL_BY_MODEL[string.lower(modelName)]
    local material = materialPath and cache:GetResource("Material", materialPath) or nil
    if material then group:SetMaterial(material) end
    self.resolvedMaterials[name] = materialPath
    group.castShadows = true
    self.groups[#self.groups + 1] = group
    return group, node
end

function BgeoDungeonRenderer:AddGroupInstance(group, node)
    group:AddInstanceNode(node)
    local nodes = self.groupInstanceNodes[group]
    if not nodes then
        nodes = {}
        self.groupInstanceNodes[group] = nodes
    end
    nodes[#nodes + 1] = node
end

function BgeoDungeonRenderer:AddRuleInstance(group, parent, transform, rule, suffix, partYaw)
    local marker = parent:CreateChild("Marker-" .. suffix)
    ApplyPackedTransform(marker, transform)
    local instance = marker
    if not IsIdentityRuleTransform(rule) then
        instance = marker:CreateChild("Offset")
        ApplyRuleTransform(instance, rule)
    end
    if partYaw and partYaw ~= 0 then
        local part = instance:CreateChild("PrefabPart")
        part.rotation = Quaternion(partYaw, Vector3.UP)
        instance = part
    end
    local range = rule.override_uniform_scale_range
    if type(range) == "table" and #range == 2 then
        local hash = PlacementHash(rule.selection_seed or 0, transform, tonumber(suffix) or 0)
        local alpha = HashCombine(hash, 0xb5297a4d) / UINT32_MASK
        local uniform = range[1] + (range[2] - range[1]) * alpha
        instance.scale = Vector3(uniform, uniform, uniform)
    end
    self:AddGroupInstance(group, instance)
    return instance
end

function BgeoDungeonRenderer:AddPointLight(parent, rule, hash)
    local node = parent:CreateChild("PointLight")
    node.position = ConvertPosition(rule.point_light_offset_cm)
    local light = node:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.color = ColorFromRule(rule, hash)
    local intensityNoise = ((hash & 0xffff) / 32767.5) - 1
    local radiusNoise = (((hash >> 16) & 0xffff) / 32767.5) - 1
    local baseBrightness = PhysicalBrightness(rule, intensityNoise)
    light.usePhysicalValues = true
    light.brightness = baseBrightness
    light.range = (rule.point_light_attenuation_radius or 700) * 0.01
        * (1 + radiusNoise * (rule.point_light_radius_variation or 0))
    light.radius = 0
    light.length = 0
    light.castShadows = rule.point_light_cast_shadows == true
    light:SetAttribute("Affect Volumetric Fog", Variant(true))
    -- Numeric Lua variants are Double; this serialized attribute requires Float.
    light:SetAttribute("Volumetric Fog Intensity", Variant(VAR_FLOAT, "1"))
    light:SetAttribute("Volumetric Fog Shadows", Variant(light.castShadows))
    self.lights[#self.lights + 1] = {
        node = node,
        light = light,
        baseBrightness = baseBrightness,
        lightFunction = rule.point_light_function_material,
    }
    return light
end

function BgeoDungeonRenderer:BuildReferenceLights(data)
    if not self.lightingEnabled then return 0 end
    local root = self.root:CreateChild("DungeonMapLights")
    local count = 0
    for index, record in ipairs(data.lights) do
        local profile = type(record) == "table" and data.profiles[record[4]] or nil
        local color = profile and profile.color or nil
        if type(record) ~= "table" or #record ~= 6 or type(color) ~= "table" or #color ~= 3 then
            return nil, "invalid DungeonMap light record " .. tostring(index)
        end
        local node = root:CreateChild("DungeonMapLight-" .. index)
        node.position = Vector3(record[1], record[2], record[3])
        local light = node:CreateComponent("Light")
        light.lightType = LIGHT_POINT
        light.color = Color(color[1], color[2], color[3], 1)
        light.usePhysicalValues = true
        light.brightness = profile.brightness
        light.range = record[5]
        light.radius = 0
        light.length = 0
        light.castShadows = record[6] == true
        light:SetAttribute("Affect Volumetric Fog", Variant(true))
        light:SetAttribute("Volumetric Fog Intensity", Variant(VAR_FLOAT, "1"))
        light:SetAttribute("Volumetric Fog Shadows", Variant(light.castShadows))
        self.lights[#self.lights + 1] = {
            node = node,
            light = light,
            baseBrightness = profile.brightness,
            lightFunction = profile.light_function,
        }
        count = count + 1
    end
    return count
end

function BgeoDungeonRenderer:SetLightDebugVisible(visible)
    if visible == true and self.cellDebugVisible then
        self.cellDebugVisible = false
        self:ClearCellDebugGeometry()
    end
    self.lightDebugVisible = visible == true
    self:RefreshLightDebugGeometry()
    print(string.format("[BgeoDungeon] light debug=%s lights=%d",
        tostring(self.lightDebugVisible), #self.lights))
    return self.lightDebugVisible, #self.lights
end

function BgeoDungeonRenderer:ToggleLightDebug()
    return self:SetLightDebugVisible(not self.lightDebugVisible)
end

function BgeoDungeonRenderer:RefreshLightDebugGeometry()
    self:ClearLightDebugGeometry()
    if not self.lightDebugVisible or #self.lights == 0 then return end

    local sphere = cache:GetResource("Model", "Models/Sphere.mdl")
    if not sphere then
        log:Write(LOG_ERROR, "[BgeoDungeon] missing Models/Sphere.mdl for light debug")
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
    print(string.format("[BgeoDungeon] built light debug geometry lights=%d radiusGroups=1", #self.lights))
end

local function HoudiniPosition(value)
    value = value or { 0, 0, 0 }
    return Vector3(value[3] or 0, value[2] or 0, value[1] or 0)
end

local function HoudiniSize(value)
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

function BgeoDungeonRenderer:SetCellDebugVisible(visible)
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
        if ok then statsOrReason = { rooms = 0, corridors = 0, stairs = 0, total = 0 } end
    end
    if not ok then
        self.cellDebugVisible = false
        self:ClearCellDebugGeometry()
        return nil, statsOrReason
    end
    print(string.format("[BgeoDungeon] cell debug=%s boxes=%d",
        tostring(self.cellDebugVisible), statsOrReason.total or 0))
    return self.cellDebugVisible, statsOrReason
end

function BgeoDungeonRenderer:ToggleCellDebug()
    return self:SetCellDebugVisible(not self.cellDebugVisible)
end

function BgeoDungeonRenderer:RefreshCellDebugGeometry()
    self:ClearCellDebugGeometry()
    if not self.cellDebugVisible then
        return true, { rooms = 0, corridors = 0, stairs = 0, total = 0 }
    end
    local data = self.cellDebugData
    if not data or type(data.rooms) ~= "table" or type(data.cells) ~= "table" then
        return false, "Shadow Castle canonical cells are unavailable"
    end

    local cube = cache:GetResource("Model", "Models/Box.mdl")
    if not cube then return false, "missing Models/Box.mdl for cell debug" end
    local modelBounds = cube.boundingBox
    local root = self.scene:CreateChild("ShadowCastleCellDebug")
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
                HoudiniPosition(room.position), HoudiniSize(room.size), "Room-" .. tostring(room.id))
        end
    end

    local cellSize = math.max(0.001, tonumber(data.cellSize) or 5.0)
    local cellDimensions = Vector3(cellSize, cellSize, cellSize)
    for _, cell in ipairs(data.cells) do
        local cellType = tonumber(cell.cell_type)
        if cell.position and cellType == 2 then
            stats.corridors = stats.corridors + 1
            AddCellDebugInstance(groupRoots.corridor, cube, materialsByKey.corridor, modelBounds,
                HoudiniPosition(cell.position), cellDimensions, "Corridor-" .. tostring(cell.id))
        elseif cell.position and (cellType == 3 or cellType == 4) then
            stats.stairs = stats.stairs + 1
            if cellType == 3 then stats.physicalStairs = stats.physicalStairs + 1
            else stats.headroom = stats.headroom + 1 end
            AddCellDebugInstance(groupRoots.stair, cube, materialsByKey.stair, modelBounds,
                HoudiniPosition(cell.position), cellDimensions, "Stair-" .. tostring(cell.id))
        end
    end
    stats.total = stats.rooms + stats.corridors + stats.stairs
    self.cellDebugRoot, self.cellDebugMaterials, self.cellDebugStats = root, materials, stats
    self:DestroyDungeonGeometry()
    print(string.format(
        "[BgeoDungeon] built cell debug rooms=%d corridors=%d stairs=%d physical=%d headroom=%d",
        stats.rooms, stats.corridors, stats.stairs, stats.physicalStairs, stats.headroom))
    return true, stats
end

function BgeoDungeonRenderer:BuildBase(data, transformsByMesh, roomsByMesh)
    local inheritByMesh, prefabBySource, lightByMesh, rulesById = {}, {}, {}, {}
    for _, rule in ipairs(data.meshes or {}) do
        if rule.id then rulesById[rule.id] = rule end
        if rule.usage == "prefab" then prefabBySource[rule.source_mesh] = rule
        elseif rule.usage == "point_light_marker" then lightByMesh[rule.mesh] = rule
        elseif rule.usage == "inherit" and not inheritByMesh[rule.mesh] then inheritByMesh[rule.mesh] = rule end
    end
    local count = 0
    for _, source in ipairs(data.scene.instances) do
        transformsByMesh[source.mesh] = transformsByMesh[source.mesh] or {}
        roomsByMesh[source.mesh] = roomsByMesh[source.mesh] or {}
        for index, transform in ipairs(source.transforms) do
            transformsByMesh[source.mesh][#transformsByMesh[source.mesh] + 1] = transform
            roomsByMesh[source.mesh][#roomsByMesh[source.mesh] + 1] = (source.room_ids or {})[index] or -1
        end
        local selectedRule = source.rule_id and rulesById[source.rule_id] or nil
        local prefab = selectedRule and selectedRule.usage == "prefab" and selectedRule
            or prefabBySource[source.mesh]
        local rule = selectedRule and selectedRule.usage == "inherit" and selectedRule
            or inheritByMesh[source.mesh]
        if prefab then
            local group, node = self:CreateGroup("Prefab-" .. prefab.id,
                "/Game/FantasyDungeon/meshes/Wall/Wall01.Wall01", prefab)
            if group then
                for index, transform in ipairs(source.transforms) do
                    self:AddRuleInstance(group, node, transform, prefab, index - 1, 0)
                    self:AddRuleInstance(group, node, transform, prefab, index - 1, 180)
                    count = count + 2
                end
            end
        elseif rule and rule.visible ~= false and not lightByMesh[source.mesh] then
            local group, node = self:CreateGroup("BGEO-" .. rule.id, source.mesh, rule)
            if group then
                for index, transform in ipairs(source.transforms) do
                    self:AddRuleInstance(group, node, transform, rule, index - 1)
                    count = count + 1
                end
            end
        end
    end
    return count
end

function BgeoDungeonRenderer:BuildAttachments(data, transformsByMesh)
    local count, lightCount = 0, 0
    for _, rule in ipairs(data.meshes or {}) do
        if rule.usage == "attach" then
            local transforms = transformsByMesh[rule.source_mesh]
            local group, node = nil, nil
            if transforms then group, node = self:CreateGroup("Attach-" .. rule.id, rule.mesh, rule) end
            if transforms and group then
                local candidates = {}
                for index, transform in ipairs(transforms) do
                    candidates[#candidates + 1] = {
                        index = index, hash = PlacementHash(rule.selection_seed or 0, transform, index - 1),
                    }
                end
                table.sort(candidates, CandidateSort)
                local selected = math.max(0, math.min(#transforms, RoundToInt(#transforms * (rule.density or 1))))
                for candidateIndex = 1, selected do
                    local candidate = candidates[candidateIndex]
                    local instance = self:AddRuleInstance(
                        group, node, transforms[candidate.index], rule, candidate.index - 1)
                    if rule.interactive_door == true then
                        self.doorSystem:Register(instance, rule,
                            string.format("%s-%d", rule.id or "door", candidate.index - 1))
                    end
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

function BgeoDungeonRenderer:BuildMarkerLights(data, transformsByMesh, roomsByMesh)
    if not self.lightingEnabled or self.referenceLightsEnabled then return 0 end
    local count = 0
    local lightRoot = self.root:CreateChild("ManifestLights")
    for _, rule in ipairs(data.meshes or {}) do
        if rule.usage == "point_light_marker" then
            local transforms, roomIds = transformsByMesh[rule.mesh], roomsByMesh[rule.mesh]
            if transforms then
                local candidates = {}
                for index, transform in ipairs(transforms) do
                    candidates[#candidates + 1] = {
                        index = index, hash = PlacementHash(rule.selection_seed or 0, transform, index - 1),
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
                    ApplyPackedTransform(marker, transforms[candidate.index])
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

function BgeoDungeonRenderer:BuildScatter(data)
    local surfaces = {}
    for _, surface in ipairs(data.scene.surfaces or {}) do surfaces[string.lower(surface.name)] = surface end
    local sharedAccepted, total = {}, 0
    for _, rule in ipairs(data.scatter_rules or {}) do
        local surface = surfaces[string.lower(rule.surface or "")]
        if rule.enabled ~= false and surface then
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
                    local ia, ib, ic = indices[offsetIndex] * 3 + 1, indices[offsetIndex + 1] * 3 + 1, indices[offsetIndex + 2] * 3 + 1
                    local a = { vertices[ia], vertices[ia + 1], vertices[ia + 2] }
                    local b = { vertices[ib], vertices[ib + 1], vertices[ib + 2] }
                    local c = { vertices[ic], vertices[ic + 1], vertices[ic + 2] }
                    local cross = Cross({ b[1] - a[1], b[2] - a[2], b[3] - a[3] },
                        { c[1] - a[1], c[2] - a[2], c[3] - a[3] })
                    local area = 0.5 * VectorLength(cross)
                    if area > 0.000001 then
                        local triangleIndex = (offsetIndex - 1) // 3
                        local stream = NewRandomStream(HashCombine(U32(rule.seed or 0), U32(triangleIndex)))
                        local exact = area / 10000 * (rule.candidate_density_per_square_meter or 0)
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
                                    instance.position = ConvertPosition(location)
                                    instance.rotation = HoudiniCoordinateSystem.UEScatterRotation(
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

function BgeoDungeonRenderer:BuildManifest(data, source, lightData, lightSource, pipelineStats)
    local valid, reason = ValidateManifest(data)
    if not valid then return false, reason end
    self.referenceLightsEnabled = lightData ~= nil
    if not self.lightingEnabled then
        print("[BgeoDungeon] all scene lights disabled")
    elseif not lightData then
        print("[BgeoDungeon] exact DungeonMap lights unavailable; using deterministic fallback: " .. tostring(lightSource))
    end
    self.previewStart = FindPreviewStart(data)
    self.root = self.scene:CreateChild("BgeoDungeon")
    local transformsByMesh, roomsByMesh = {}, {}
    local baseCount = self:BuildBase(data, transformsByMesh, roomsByMesh)
    local attachCount, companionLights = self:BuildAttachments(data, transformsByMesh)
    local markerLights = self:BuildMarkerLights(data, transformsByMesh, roomsByMesh)
    local referenceLights = 0
    if lightData then
        referenceLights, reason = self:BuildReferenceLights(lightData)
        if not referenceLights then return false, reason end
    end
    local scatterCount = self:BuildScatter(data)
    self.stats = {
        source = source,
        sourceInstances = data.scene.instance_count,
        baseInstances = baseCount,
        attachedInstances = attachCount,
        scatterInstances = scatterCount,
        lights = referenceLights + companionLights + markerLights,
        lightSource = self.lightingEnabled
            and (lightData and lightSource or "deterministic fallback") or "disabled",
        doors = self.doorSystem:GetDoorCount(),
        groups = #self.groups,
        markerCount = pipelineStats and pipelineStats.markerCount or nil,
        faceCount = pipelineStats and pipelineStats.faceCount or nil,
    }
    self:RefreshLightDebugGeometry()
    print(string.format(
        "[BgeoDungeon] refreshed source=%d base=%d attached=%d scatter=%d lights=%d doors=%d groups=%d",
        self.stats.sourceInstances, baseCount, attachCount, scatterCount, self.stats.lights,
        self.stats.doors, self.stats.groups))
    return true, self.stats
end

function BgeoDungeonRenderer:Rebuild()
    self:Clear()
    self.cellDebugVisible = false
    local data, source = ReadManifest()
    if not data then return false, source end
    local lightData, lightSource = ReadLightManifest()
    local ok, result = self:BuildManifest(data, source, lightData, lightSource)
    if ok then
        self.cachedBuild = { data = data, source = source, lightData = lightData, lightSource = lightSource }
    end
    return ok, result
end

function BgeoDungeonRenderer:RebuildFromHoudini(markerResult, cellDebugData)
    self:Clear()
    local data, source = ReadManifest()
    if not data then return false, source end
    local adapted, pipelineStats = HoudiniMeshInfoAdapter.Apply(data, markerResult)
    if not adapted then return false, pipelineStats end
    local ok, result = self:BuildManifest(adapted, "houdini-runtime + " .. source,
        nil, "dynamic Marker lights", pipelineStats)
    if not ok then return false, result end
    self.cachedBuild = {
        data = adapted,
        source = "houdini-runtime + " .. source,
        lightData = nil,
        lightSource = "dynamic Marker lights",
        pipelineStats = pipelineStats,
    }
    self.cellDebugData = cellDebugData
    local debugOk, debugReason = self:RefreshCellDebugGeometry()
    if not debugOk then
        log:Write(LOG_ERROR, "[BgeoDungeon] cell debug rebuild failed: " .. tostring(debugReason))
        self.cellDebugVisible = false
        self:ClearCellDebugGeometry()
    end
    return true, result
end

function BgeoDungeonRenderer:InteractNearestDoor(position, forward)
    return self.doorSystem:InteractNearestDoor(position, forward)
end

function BgeoDungeonRenderer:Update(timeStep)
    self.elapsed = self.elapsed + math.max(0, timeStep or 0)
    for _, entry in ipairs(self.lights) do
        if entry.lightFunction == BRAZIER_LIGHT_FUNCTION then
            local position = entry.node.worldPosition
            -- UE light function uses WorldPos.xy in centimeters. UE X/Y map to UrhoX Z/X.
            local phase = position.z * 1.3 + position.x * 1.7
            local multiplier = 0.94
                + 0.04 * math.sin(self.elapsed * 2.7 + phase)
                + 0.02 * math.sin(self.elapsed * 7.1 + phase * 1.73)
            entry.light.brightness = entry.baseBrightness * multiplier
        end
    end
    self.doorSystem:Update(timeStep)
end

function BgeoDungeonRenderer:Dispose()
    self:Clear()
end

return BgeoDungeonRenderer
