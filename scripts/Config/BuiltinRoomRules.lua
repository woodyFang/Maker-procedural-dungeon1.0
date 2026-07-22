local Themes = require("Config.Themes")
local ThemePacks = require("Config.ThemePacks")
local TopicSeeds = require("Config.TopicSeeds")

local BuiltinRoomRules = {
    SCHEMA_VERSION = 1,
    SOURCE = "builtin-room-rules-v1",
}

local function Rule(kind, count, chance, scaleMin, scaleMax)
    return {
        kind = kind,
        count = count or 1,
        chance = chance == nil and 1 or chance,
        scaleMin = scaleMin or 0.92,
        scaleMax = scaleMax or scaleMin or 1.0,
    }
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
    for _, value in ipairs(values or {}) do
        result[#result + 1] = Rule(value.kind, value.count, value.chance, value.scaleMin, value.scaleMax)
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
