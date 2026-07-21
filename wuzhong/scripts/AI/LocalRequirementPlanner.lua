local LocalRequirementPlanner = {
    SCHEMA_VERSION = 1,
    SOURCE = "local-structured-planner-v1",
}

local GeometryRules = require("Generation.GeometryRules")
local RoomGroupColors = require("Config.RoomGroupColors")

local function CopyRules(rules)
    local result = {}
    for _, rule in ipairs(rules or {}) do
        result[#result + 1] = {
            kind = rule.kind,
            count = rule.count or 1,
            chance = rule.chance == nil and 1 or rule.chance,
            scaleMin = rule.scaleMin or 0.92,
            scaleMax = rule.scaleMax or rule.scaleMin or 1.0,
        }
    end
    return result
end

local function TopicPrompt(topic, roomName, purpose)
    local prompt = tostring(topic.prompt or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local prefix = string.format("题材“%s”中的%s。%s", topic.label or "未命名题材", roomName, purpose)
    local topicRequirement = prompt ~= "" and (" 全局要求：" .. prompt) or ""
    return prefix .. topicRequirement .. " " .. GeometryRules.VerticalPromptClause(topic.floorHeight)
end

local function Group(topic, pack, revision, spec)
    return {
        id = string.format("generated-%s-%s", topic.id, spec.key),
        topicId = topic.id,
        name = spec.name,
        color = RoomGroupColors.Default(spec, spec.sortOrder),
        prompt = TopicPrompt(topic, spec.name, spec.purpose),
        source = "ai",
        locked = false,
        plannerSource = LocalRequirementPlanner.SOURCE,
        compiledFromRevision = revision,
        compiledSpecVersion = LocalRequirementPlanner.SCHEMA_VERSION,
        sortOrder = spec.sortOrder,
        roleKeys = spec.roleKeys,
        defaultGroup = spec.defaultGroup == true,
        minCount = spec.minCount or 1,
        maxCount = spec.maxCount or 0,
        minArea = spec.minArea or 0,
        maxArea = spec.maxArea or 0,
        propRules = CopyRules(pack.roomRules[spec.ruleKey] or pack.roomRules.default),
    }
end

function LocalRequirementPlanner.Compile(topic, pack, revision)
    if type(topic) ~= "table" or type(topic.id) ~= "string" or topic.id == "" then
        return nil, "题材缺少稳定 ID，无法生成房间规则。"
    end
    if type(pack) ~= "table" or pack.key ~= "school" then
        return nil, "最短闭环当前只支持已安装的学校题材包。"
    end

    revision = math.max(1, math.floor(tonumber(revision) or 1))
    local specs = {
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

    local groups = {}
    for _, spec in ipairs(specs) do groups[#groups + 1] = Group(topic, pack, revision, spec) end
    return {
        schemaVersion = LocalRequirementPlanner.SCHEMA_VERSION,
        source = LocalRequirementPlanner.SOURCE,
        topicId = topic.id,
        packKey = pack.key,
        compiledFromRevision = revision,
        inputPrompt = topic.prompt or "",
        referenceImageName = topic.imageName,
        referenceImageAvailable = topic.imageData ~= nil or topic.imagePath ~= nil,
        verticalProfile = GeometryRules.CurrentVerticalProfile(topic.floorHeight),
        roomGroups = groups,
    }
end

function LocalRequirementPlanner.MergeRoomGroups(existing, topicId, generated)
    local result, preserved = {}, {}
    for _, group in ipairs(existing or {}) do
        local belongsToTopic = group.topicId == topicId
        local replaceable = belongsToTopic and group.source == "ai" and group.locked ~= true
        if not replaceable then
            result[#result + 1] = group
            if belongsToTopic then preserved[group.id] = true end
        end
    end
    for _, group in ipairs(generated or {}) do
        if not preserved[group.id] then result[#result + 1] = group end
    end
    return result
end

function LocalRequirementPlanner.GroupsForTopic(groups, topicId)
    local result = {}
    for _, group in ipairs(groups or {}) do
        if group.topicId == topicId then result[#result + 1] = group end
    end
    table.sort(result, function(a, b)
        local orderA, orderB = tonumber(a.sortOrder) or 999, tonumber(b.sortOrder) or 999
        if orderA == orderB then return tostring(a.id) < tostring(b.id) end
        return orderA < orderB
    end)
    return result
end

return LocalRequirementPlanner
