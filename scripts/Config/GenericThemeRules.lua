local Themes = require("Config.Themes")
local PaletteData = require("Config.PaletteData")
local GeometryRules = require("Generation.GeometryRules")

local GenericThemeRules = {
    SCHEMA_VERSION = 1,
    SOURCE = "generic-programmatic-v1",
    GENERATION_MODE = "generic",
}

GenericThemeRules.RENDER_LUMINANCE = {
    minMean = 0.12,
    maxMean = 0.82,
    maxBlackPixelRatio = 0.08,
    maxWhitePixelRatio = 0.03,
    maxEmissiveCoverage = 0.06,
}

local function Contains(items, value)
    for _, item in ipairs(items or {}) do
        if item == value then return true end
    end
    return false
end

local function ValidateContract(contract)
    local modelRules = contract.modelGenerationRules
    if type(modelRules) ~= "table"
        or modelRules.lengthUnit ~= "meter"
        or modelRules.allowPlaceholder ~= false
        or modelRules.exactCountsOwnedBy ~= "region" then
        return false, "theme model-generation rules are incomplete"
    end
    local colorRules = contract.colorRules
    if type(colorRules) ~= "table"
        or colorRules.format ~= "#RRGGBB"
        or colorRules.semanticRoles ~= true then
        return false, "theme color rules are incomplete"
    end
    local luminance = colorRules.renderLuminance
    if type(luminance) ~= "table"
        or luminance.minMean ~= GenericThemeRules.RENDER_LUMINANCE.minMean
        or luminance.maxMean ~= GenericThemeRules.RENDER_LUMINANCE.maxMean
        or luminance.maxBlackPixelRatio ~= GenericThemeRules.RENDER_LUMINANCE.maxBlackPixelRatio
        or luminance.maxWhitePixelRatio ~= GenericThemeRules.RENDER_LUMINANCE.maxWhitePixelRatio
        or luminance.maxEmissiveCoverage ~= GenericThemeRules.RENDER_LUMINANCE.maxEmissiveCoverage then
        return false, "theme rendered-luminance rules are incomplete"
    end
    for _, field in ipairs(PaletteData.COLOR_FIELDS) do
        if not Contains(colorRules.fields, field) then
            return false, "theme color rules are missing " .. field
        end
    end
    local acceptance = contract.acceptanceRules
    if type(acceptance) ~= "table"
        or acceptance.requireImportedModel ~= true
        or acceptance.requireMaterial ~= true
        or acceptance.requireCollision ~= true
        or acceptance.requireColorPalette ~= true
        or acceptance.requireRenderedLuminanceCheck ~= true
        or acceptance.requireScaleInMeters ~= true
        or acceptance.requireStableAssetId ~= true
        or acceptance.requirePlacementCheck ~= true
        or acceptance.rejectPlaceholder ~= true
        or acceptance.rejectBlockedOpenings ~= true then
        return false, "theme acceptance rules are incomplete"
    end
    return true
end

local function Trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ResolveSettingKey(key)
    return type(key) == "string" and Themes.settings[key] and key or "temple"
end

-- This is the always-available executable contract. It deliberately reuses the
-- installed procedural structure, prop and PBR systems; it does not pretend
-- that an external AI model-generation service has already produced assets.
function GenericThemeRules.Resolve(baseSettingKey)
    local key = ResolveSettingKey(baseSettingKey)
    local setting = Themes.GetSetting(key)
    return {
        schemaVersion = GenericThemeRules.SCHEMA_VERSION,
        source = GenericThemeRules.SOURCE,
        generationMode = GenericThemeRules.GENERATION_MODE,
        baseSettingKey = key,
        baseSettingLabel = setting.label,
        structureRules = { "楼层", "区域", "走廊", "门", "楼梯" },
        placementRules = { "固定种子复现", "避开门口", "避开主通道", "保持可通行" },
        roomDefinitionsOptional = true,
        materialMode = "installed-pbr-profiles",
        assetMode = "installed-base-assets",
        aiAssetStatus = "not-connected",
        modelGenerationRules = {
            lengthUnit = "meter",
            allowPlaceholder = false,
            exactCountsOwnedBy = "region",
            requiredMetadata = {
                "assetId", "bounds", "pivot", "forward", "collision", "materials", "performance",
            },
        },
        colorRules = {
            format = "#RRGGBB",
            semanticRoles = true,
            fields = PaletteData.COLOR_FIELDS,
            derivedFields = { "cap", "debris", "torchLight", "particles" },
            renderLuminance = GenericThemeRules.RENDER_LUMINANCE,
        },
        acceptanceRules = {
            requireImportedModel = true,
            requireMaterial = true,
            requireCollision = true,
            requireColorPalette = true,
            requireRenderedLuminanceCheck = true,
            requireScaleInMeters = true,
            requireStableAssetId = true,
            requirePlacementCheck = true,
            rejectPlaceholder = true,
            rejectBlockedOpenings = true,
        },
    }
end

function GenericThemeRules.Validate(topic, contract)
    if type(topic) ~= "table" then return false, "题材数据无效。" end
    if Trim(topic.label) == "" then return false, "题材组名称不能为空。" end
    if Trim(topic.prompt) == "" and not topic.imagePath then
        return false, "请填写提示词或添加参考图。"
    end
    contract = contract or GenericThemeRules.Resolve(topic.baseSettingKey)
    if contract.schemaVersion ~= GenericThemeRules.SCHEMA_VERSION
        or contract.source ~= GenericThemeRules.SOURCE
        or not Themes.settings[contract.baseSettingKey] then
        return false, "通用生成规则版本或参考生成体系无效。"
    end
    local validContract, contractReason = ValidateContract(contract)
    if not validContract then return false, contractReason end
    return true
end

function GenericThemeRules.ValidateRenderedLuminance(metrics)
    if type(metrics) ~= "table" or metrics.uiExcluded ~= true then
        return false, "render metrics must be measured after excluding UI pixels"
    end
    local mean = tonumber(metrics.meanLuminance)
    local blackRatio = tonumber(metrics.blackPixelRatio)
    local whiteRatio = tonumber(metrics.whitePixelRatio)
    local emissiveCoverage = tonumber(metrics.emissiveCoverage or 0)
    if not mean or not blackRatio or not whiteRatio or not emissiveCoverage then
        return false, "render luminance metrics are incomplete"
    end
    if mean < 0 or mean > 1 or blackRatio < 0 or blackRatio > 1
        or whiteRatio < 0 or whiteRatio > 1 or emissiveCoverage < 0 or emissiveCoverage > 1 then
        return false, "render luminance metrics must be normalized to 0..1"
    end
    if mean < GenericThemeRules.RENDER_LUMINANCE.minMean then
        return false, "rendered scene is too dark"
    end
    if mean > GenericThemeRules.RENDER_LUMINANCE.maxMean then
        return false, "rendered scene is too bright"
    end
    if blackRatio > GenericThemeRules.RENDER_LUMINANCE.maxBlackPixelRatio then
        return false, "rendered scene has too many crushed-black pixels"
    end
    if whiteRatio > GenericThemeRules.RENDER_LUMINANCE.maxWhitePixelRatio then
        return false, "rendered scene has too many clipped-white pixels"
    end
    if emissiveCoverage > GenericThemeRules.RENDER_LUMINANCE.maxEmissiveCoverage then
        return false, "emissive highlights cover too much of the rendered scene"
    end
    return true
end

function GenericThemeRules.Compile(topic, revision)
    local contract = GenericThemeRules.Resolve(topic and topic.baseSettingKey)
    local valid, reason = GenericThemeRules.Validate(topic, contract)
    if not valid then return nil, reason end
    return {
        schemaVersion = contract.schemaVersion,
        source = contract.source,
        generationMode = contract.generationMode,
        compiledFromRevision = math.max(0, math.floor(tonumber(revision) or 0)),
        topicId = topic.id,
        baseSettingKey = contract.baseSettingKey,
        verticalProfile = GeometryRules.CurrentVerticalProfile(topic.floorHeight),
        referenceImageAvailable = topic.imagePath ~= nil,
        modelGenerationRules = contract.modelGenerationRules,
        colorRules = contract.colorRules,
        acceptanceRules = contract.acceptanceRules,
        roomGroups = {},
    }
end

return GenericThemeRules
