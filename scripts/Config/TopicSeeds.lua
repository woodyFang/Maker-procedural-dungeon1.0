local MultiFloor = require("Generation.MultiFloor")

local TopicSeeds = {
    SCHEMA_VERSION = 1,
    SOURCE = "seed-theme-v1",
    DEFAULT_ID = "theme-dungeon",
    order = { "theme-dungeon", "theme-hospital", "theme-school" },
}

TopicSeeds.records = {
    ["theme-dungeon"] = {
        id = "theme-dungeon", label = "遗迹", prompt = "石质建筑与地下空间",
        baseSettingKey = "dungeon", floorHeight = MultiFloor.FLOOR_HEIGHT,
        packStatus = "ready", generationMode = "generic", plannerSource = TopicSeeds.SOURCE,
    },
    ["theme-hospital"] = {
        id = "theme-hospital", label = "医院", prompt = "现代医疗建筑、病房、检查室和医疗设施",
        baseSettingKey = "hospital", floorHeight = MultiFloor.FLOOR_HEIGHT,
        packStatus = "ready", generationMode = "generic", plannerSource = TopicSeeds.SOURCE,
    },
    ["theme-school"] = {
        id = "theme-school", label = "学校", prompt = "现代学校、教室、图书馆、实验室和公共走廊",
        baseSettingKey = "school", floorHeight = MultiFloor.FLOOR_HEIGHT,
        packStatus = "ready", generationMode = "theme-pack", plannerSource = TopicSeeds.SOURCE,
    },
}

local IDS_BY_SETTING = {
    dungeon = "theme-dungeon",
    hospital = "theme-hospital",
    school = "theme-school",
}

local function Copy(record)
    local result = {}
    for key, value in pairs(record or {}) do result[key] = value end
    return result
end

function TopicSeeds.Get(id)
    local record = TopicSeeds.records[id]
    return record and Copy(record) or nil
end

function TopicSeeds.IdForSetting(settingKey)
    return IDS_BY_SETTING[settingKey] or TopicSeeds.DEFAULT_ID
end

function TopicSeeds.IdsBySetting()
    local result = {}
    for settingKey, id in pairs(IDS_BY_SETTING) do result[settingKey] = id end
    return result
end

function TopicSeeds.Ensure(records)
    local result, ids = {}, {}
    for _, record in ipairs(records or {}) do
        result[#result + 1] = record
        ids[record.id] = true
    end
    for _, id in ipairs(TopicSeeds.order) do
        if not ids[id] then result[#result + 1] = TopicSeeds.Get(id) end
    end
    return result
end

return TopicSeeds
