local Themes = require("Config.Themes")
local ThemePacks = require("Config.ThemePacks")
local TopicSeeds = require("Config.TopicSeeds")
local RoomGroupColors = require("Config.RoomGroupColors")

local BuiltinRoomRules = {
    SCHEMA_VERSION = 2,
    SOURCE = "builtin-room-rules-v2",
}

local function Rule(kind, count, chance, scaleMin, scaleMax, extra)
    local rule = {
        kind = kind,
        count = count or 1,
        chance = chance == nil and 1 or chance,
        scaleMin = scaleMin or 0.92,
        scaleMax = scaleMax or scaleMin or 1.0,
    }
    if extra then
        for key, value in pairs(extra) do rule[key] = value end
    end
    return rule
end

local SCHOOL_ROOMS = {
    {
        key = "lobby", name = "大厅", purpose = "承担入口、接待和校园导览功能。",
        sortOrder = 1, roleKeys = { "entrance" }, ruleKey = "entrance",
        minCount = 1, maxCount = 1, minArea = 64,
    },
    {
        key = "classroom", name = "教室", purpose = "以课桌、教师桌和黑板形成清晰授课布局。",
        sortOrder = 2, roleKeys = { "combat", "secret" }, ruleKey = "combat",
        defaultGroup = true, minCount = 1, minArea = 35,
    },
    {
        key = "library", name = "图书馆", purpose = "使用成组书架形成安静的阅读和藏书区域。",
        sortOrder = 3, roleKeys = { "treasure" }, ruleKey = "treasure",
        minCount = 1, minArea = 40,
    },
    {
        key = "laboratory", name = "实验室", purpose = "使用实验台、地球仪和资料架表达科学教学。",
        sortOrder = 4, roleKeys = { "elite", "shrine" }, ruleKey = "elite",
        minCount = 1, minArea = 48,
    },
    {
        key = "cafeteria", name = "食堂", purpose = "使用餐桌和舞台构成大型公共活动空间。",
        sortOrder = 5, roleKeys = { "boss" }, ruleKey = "boss",
        minCount = 1, maxCount = 1, minArea = 80,
    },
}

local TEMPLE_ROOMS = {
    {
        key = "pilgrimage-gate", name = "朝圣门厅",
        purpose = "以中央门环、对称陶瓮和墙面徽章构成进入神域的第一处仪式空间。",
        sortOrder = 1, roleKeys = { "entrance" }, ruleKey = "entrance",
        minCount = 1, maxCount = 1, minArea = 64,
        propRules = {
            Rule("ring", 1, 1.0, 1.0, 1.0, { layout = "focal", rot = 0 }),
            Rule("templeUrn", 4, 1.0, 0.82, 1.02, { layout = "perimeter", step = 3, max = 4 }),
            Rule("templeMedallion", 1, 1.0, 0.94, 1.02, { layout = "focal", tries = 30 }),
        },
    },
    {
        key = "rune-sanctum", name = "符文圣坛",
        purpose = "以中央圣晶、四方石碑和克制的符文秩序形成神殿的静默祭坛。",
        sortOrder = 2, roleKeys = { "shrine" }, ruleKey = "shrine",
        minCount = 1, minArea = 52,
        propRules = {
            Rule("shrineCrystal", 1, 1.0, 1.0, 1.0, { layout = "focal", tries = 36 }),
            Rule("obelisk", 4, 1.0, 0.92, 1.04,
                { layout = "ring", radius = 3, angleJitter = false }),
            Rule("templeUrn", 2, 1.0, 0.82, 0.96, { layout = "perimeter", step = 4, max = 2 }),
        },
    },
    {
        key = "astral-gallery", name = "星象观礼台",
        purpose = "以环形石碑、中心晶簇和规整柱列表达神殿观测天象与迎接神辉的高阶空间。",
        sortOrder = 3, roleKeys = { "elite" }, ruleKey = "elite",
        minCount = 1, minArea = 64,
        propRules = {
            Rule("obelisk", 4, 1.0, 0.90, 1.04,
                { layout = "ring", radius = 3.5, angleJitter = false }),
            Rule("crystalCluster", 1, 1.0, 1.0, 1.18, { layout = "focal", tries = 36 }),
            Rule("pillar", 4, 1.0, 0.94, 1.04,
                { layout = "grid", step = 4, centered = true, skipCenter = true, rot = 0, max = 4 }),
        },
    },
    {
        key = "relic-vault", name = "神藏宝库",
        purpose = "以中央宝箱、环形金堆和低亮度晶簇构成庄严而不喧闹的圣物收藏空间。",
        sortOrder = 4, roleKeys = { "treasure" }, ruleKey = "treasure",
        minCount = 1, minArea = 48,
        propRules = {
            Rule("chest", 1, 1.0, 1.0, 1.0, { layout = "focal", tries = 36 }),
            Rule("goldPile", 3, 1.0, 0.84, 1.16,
                { layout = "ring", radius = 2.5, angleJitter = false }),
            Rule("crystalCluster", 1, 1.0, 0.82, 1.02, { layout = "focal", tries = 30 }),
        },
    },
    {
        key = "guardian-seat", name = "守护神座",
        purpose = "以边缘守护巨像、中央晶碑和环形圣火鼎构成神殿的最终试炼空间。",
        sortOrder = 5, roleKeys = { "boss" }, ruleKey = "boss",
        minCount = 1, maxCount = 1, minArea = 80,
        propRules = {
            Rule("guardianStatue", 1, 1.0, 1.18, 1.30,
                { layout = "edgeFocal", side = "south", edgeInset = 2, rot = 0, tries = 36 }),
            Rule("brazier", 4, 1.0, 0.92, 1.04,
                { layout = "ring", radius = 3.5, angleJitter = false, anchor = "bossCrystal", anchorScale = 1.12 }),
        },
    },
    {
        key = "processional-ruin", name = "断垣祭仪殿",
        purpose = "以柱阵、残拱和断柱保留神殿仪式轴线，作为普通战斗与秘密区域的统一基底。",
        sortOrder = 6, roleKeys = { "combat", "secret" }, ruleKey = "default",
        defaultGroup = true, minCount = 1, minArea = 35,
        propRules = {
            Rule("pillar", 4, 1.0, 0.94, 1.06,
                { layout = "grid", step = 3, centered = true, skipCenter = true, rot = 0, max = 4 }),
            Rule("archRuin", 1, 1.0, 0.95, 1.10, { layout = "focal", tries = 30 }),
            Rule("brokenPillar", 2, 1.0, 0.90, 1.12, { layout = "focal", tries = 28 }),
            Rule("templeUrn", 2, 1.0, 0.80, 0.98, { layout = "perimeter", step = 4, max = 2 }),
        },
    },
}

-- Combat/secret rooms share the processional room identity in the UI, but
-- their physical composition rotates between several temple-specific courts.
-- Every variant keeps a pillar lattice as the common architectural grammar and
-- adds a different focal/edge story so repeated rooms remain recognizable.
local TEMPLE_VISUAL_VARIANTS = {
    ["processional-ruin"] = {
        {
            Rule("pillar", 4, 1.0, 0.94, 1.06,
                { layout = "grid", step = 3, centered = true, skipCenter = true, rot = 0, max = 4 }),
            Rule("archRuin", 1, 1.0, 0.95, 1.10, { layout = "focal", tries = 30 }),
            Rule("templeUrn", 2, 1.0, 0.80, 0.98, { layout = "perimeter", step = 4, max = 2 }),
        },
        {
            Rule("pillar", 4, 1.0, 0.94, 1.06,
                { layout = "grid", step = 4, centered = true, skipCenter = true, rot = 0, max = 4 }),
            Rule("obelisk", 4, 1.0, 0.88, 1.00,
                { layout = "ring", radius = 2.8, angleJitter = false }),
            Rule("brokenPillar", 1, 1.0, 0.90, 1.08, { layout = "edgeFocal", side = "north", edgeInset = 1, tries = 28 }),
        },
        {
            Rule("pillar", 4, 1.0, 0.94, 1.06,
                { layout = "grid", step = 3, centered = true, skipCenter = true, rot = 0, max = 4 }),
            Rule("crystalCluster", 1, 1.0, 0.82, 1.02, { layout = "focal", tries = 30 }),
            Rule("brokenPillar", 2, 1.0, 0.90, 1.12, { layout = "perimeter", step = 4, max = 2 }),
        },
    },
}

local HOSPITAL_ROOMS = {
    {
        key = "reception", name = "接待大厅", purpose = "承担入口、挂号、分诊和候诊功能。",
        sortOrder = 1, roleKeys = { "entrance" }, minCount = 1, maxCount = 1, minArea = 64,
        propRules = {
            Rule("nurseCounter", 1, 1.0, 1.08, 1.16),
            Rule("waitingBench", 2, 1.0, 0.88, 1.0),
            Rule("medCart", 1, 0.72, 0.80, 0.90),
        },
    },
    {
        key = "ward", name = "病房", purpose = "以病床、输液架和隐私帘构成住院护理空间。",
        sortOrder = 2, roleKeys = { "combat", "secret" }, defaultGroup = true,
        minCount = 1, minArea = 35,
        propRules = {
            Rule("hospitalBed", 2, 1.0, 0.98, 1.08),
            Rule("ivStand", 2, 0.88, 0.88, 1.0),
            Rule("privacyCurtain", 1, 0.72, 0.88, 0.98),
            Rule("medCabinet", 1, 0.68, 0.84, 0.94),
        },
    },
    {
        key = "nurse-station", name = "护士站", purpose = "形成病区护理、记录和物资调度中心。",
        sortOrder = 3, roleKeys = { "treasure" }, minCount = 1, minArea = 40,
        propRules = {
            Rule("nurseCounter", 1, 1.0, 0.98, 1.08),
            Rule("monitor", 2, 0.90, 0.82, 0.94),
            Rule("medCabinet", 2, 0.86, 0.86, 0.98),
            Rule("medCart", 1, 0.72, 0.78, 0.90),
        },
    },
    {
        key = "examination", name = "检查室", purpose = "使用检查床、医生桌和监护设备表达门诊检查功能。",
        sortOrder = 4, roleKeys = { "elite" }, minCount = 1, minArea = 42,
        propRules = {
            Rule("examTable", 1, 1.0, 0.98, 1.06),
            Rule("doctorDesk", 1, 0.88, 0.86, 0.98),
            Rule("monitor", 1, 0.90, 0.84, 0.96),
            Rule("medCart", 1, 0.72, 0.80, 0.90),
        },
    },
    {
        key = "mri", name = "MRI 室", purpose = "以 MRI 扫描设备和监护终端构成医学影像空间。",
        sortOrder = 5, roleKeys = { "shrine" }, minCount = 1, minArea = 52,
        propRules = {
            Rule("mriScanner", 1, 1.0, 1.02, 1.10),
            Rule("monitor", 1, 1.0, 0.90, 1.0),
            Rule("medCart", 1, 0.72, 0.78, 0.88),
            Rule("oxygenTank", 1, 0.55, 0.74, 0.84),
        },
    },
    {
        key = "surgery", name = "手术室", purpose = "使用手术台、无影灯和生命支持设备构成核心手术空间。",
        sortOrder = 6, roleKeys = { "boss" }, minCount = 1, maxCount = 1, minArea = 80,
        propRules = {
            Rule("surgeryTable", 1, 1.0, 1.10, 1.20),
            Rule("surgicalLamp", 1, 1.0, 0.98, 1.08),
            Rule("gurney", 1, 0.92, 0.92, 1.02),
            Rule("cleanZone", 1, 1.0, 1.08, 1.18),
            Rule("monitor", 1, 0.92, 0.88, 1.0),
        },
    },
    {
        key = "isolation", name = "隔离区", purpose = "以隔离帘、病床和独立医疗设备形成受控病区。",
        sortOrder = 7, roleKeys = { "secret" }, minCount = 1, minArea = 38,
        propRules = {
            Rule("hospitalBed", 1, 1.0, 0.98, 1.06),
            Rule("privacyCurtain", 2, 1.0, 0.90, 1.0),
            Rule("oxygenTank", 1, 0.86, 0.78, 0.88),
            Rule("bioBin", 1, 0.82, 0.72, 0.82),
        },
    },
}

local REGISTRY = {
    dungeon = {},
    temple = TEMPLE_ROOMS,
    hospital = HOSPITAL_ROOMS,
    school = SCHOOL_ROOMS,
}

local function CopyList(values)
    local result = {}
    for index, value in ipairs(values or {}) do result[index] = value end
    return result
end

local function CopyRules(values)
    local result = {}
    local extraKeys = {
        "layout", "step", "rowStep", "colStep", "margin", "max", "rot", "centered",
        "skipCenter", "stepThreshold", "stepBig", "stepSmall", "radius", "angleSpan",
        "angleJitter", "anchor", "anchorScale", "anchorMinDim", "anchorRot", "anchorRotAxis",
        "tries", "side", "edgeInset",
    }
    for _, value in ipairs(values or {}) do
        local extra = {}
        for _, key in ipairs(extraKeys) do
            if value[key] ~= nil then extra[key] = value[key] end
        end
        result[#result + 1] = Rule(value.kind, value.count, value.chance, value.scaleMin, value.scaleMax, extra)
    end
    return result
end

function BuiltinRoomRules.SettingKeys()
    local result = {}
    for index, settingKey in ipairs(Themes.settingOrder) do result[index] = settingKey end
    return result
end

function BuiltinRoomRules.Get(settingKey)
    return REGISTRY[settingKey]
end

function BuiltinRoomRules.VisualVariants(settingKey, groupId)
    if settingKey ~= "temple" or type(groupId) ~= "string" then return nil end
    local prefix = "seed-" .. settingKey .. "-"
    local key = groupId:sub(1, #prefix) == prefix and groupId:sub(#prefix + 1) or groupId
    local variants = TEMPLE_VISUAL_VARIANTS[key]
    if not variants then return nil end
    local result = {}
    for index, rules in ipairs(variants) do result[index] = CopyRules(rules) end
    return result
end

function BuiltinRoomRules.Materialize(settingKey, topicId)
    local definitions = REGISTRY[settingKey]
    if not definitions then return nil, "未知题材生成体系：" .. tostring(settingKey) end
    local setting = Themes.GetSetting(settingKey)
    local pack = ThemePacks.Get(settingKey)
    local rooms = {}
    for _, definition in ipairs(definitions) do
        local propRules = definition.propRules
        if not propRules and pack then
            propRules = pack.roomRules[definition.ruleKey] or pack.roomRules.default
        end
        rooms[#rooms + 1] = {
            id = string.format("seed-%s-%s", settingKey, definition.key),
            topicId = topicId,
            name = definition.name,
            color = RoomGroupColors.Default(definition, definition.sortOrder),
            prompt = string.format("题材“%s”中的%s。%s", setting.label, definition.name, definition.purpose),
            ruleClass = "specific-room",
            source = "seed",
            locked = false,
            plannerSource = BuiltinRoomRules.SOURCE,
            compiledFromRevision = 0,
            compiledSpecVersion = BuiltinRoomRules.SCHEMA_VERSION,
            sortOrder = definition.sortOrder,
            roleKeys = CopyList(definition.roleKeys),
            defaultGroup = definition.defaultGroup == true,
            minCount = definition.minCount or 1,
            maxCount = definition.maxCount or 0,
            minArea = definition.minArea or 0,
            maxArea = definition.maxArea or 0,
            propRules = CopyRules(propRules),
        }
    end
    return rooms
end

function BuiltinRoomRules.Validate()
    for _, settingKey in ipairs(Themes.settingOrder) do
        local definitions = REGISTRY[settingKey]
        if type(definitions) ~= "table" then return false, settingKey .. " has no room registry entry" end
        local ids, names, defaultCount = {}, {}, 0
        for _, room in ipairs(BuiltinRoomRules.Materialize(settingKey,
            TopicSeeds.IdForSetting(settingKey)) or {}) do
            if ids[room.id] or names[room.name] then return false, settingKey .. " has duplicate room identity" end
            if room.topicId ~= TopicSeeds.IdForSetting(settingKey) or room.settingKey ~= nil then
                return false, settingKey .. " room has an invalid topic scope"
            end
            if room.defaultGroup then defaultCount = defaultCount + 1 end
            if #room.roleKeys == 0 or #room.propRules == 0 then
                return false, settingKey .. " room has no executable role or prop rules"
            end
            ids[room.id], names[room.name] = true, true
        end
        if #definitions > 0 and defaultCount ~= 1 then
            return false, settingKey .. " requires exactly one default room"
        end
    end
    return true
end

return BuiltinRoomRules
