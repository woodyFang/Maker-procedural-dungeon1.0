local LocalRequirementPlanner = {
    SCHEMA_VERSION = 1,
    SOURCE = "local-structured-planner-v1",
}

local GeometryRules = require("Generation.GeometryRules")
local RoomGroupColors = require("Config.RoomGroupColors")
local BuiltinRoomRules = require("Config.BuiltinRoomRules")
local TopicSeeds = require("Config.TopicSeeds")

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
        ruleClass = "specific-room",
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
    local specs = BuiltinRoomRules.Get(pack.key)
    if type(specs) ~= "table" or #specs == 0 then
        return nil, "题材包缺少可执行的特定房间定义。"
    end

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

function LocalRequirementPlanner.CompileSeedTopic(settingKey, topicId)
    local groups, reason = BuiltinRoomRules.Materialize(settingKey, topicId)
    if not groups then return nil, reason end
    return {
        schemaVersion = BuiltinRoomRules.SCHEMA_VERSION,
        source = BuiltinRoomRules.SOURCE,
        settingKey = settingKey,
        topicId = topicId,
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

local function GroupSignature(group)
    local parts = {
        tostring(group.id), tostring(group.settingKey), tostring(group.name), tostring(group.prompt),
        tostring(group.source), tostring(group.ruleClass), tostring(group.compiledSpecVersion),
        tostring(group.sortOrder), tostring(group.defaultGroup), tostring(group.minCount),
        tostring(group.maxCount), tostring(group.minArea), tostring(group.maxArea),
    }
    for _, key in ipairs(group.roleKeys or {}) do parts[#parts + 1] = "role:" .. tostring(key) end
    for _, rule in ipairs(group.propRules or {}) do
        parts[#parts + 1] = table.concat({ "prop", tostring(rule.kind), tostring(rule.count),
            tostring(rule.chance), tostring(rule.scaleMin), tostring(rule.scaleMax) }, ":")
    end
    return table.concat(parts, "|")
end

local function SeedRoomId(settingKey, id)
    local suffix = tostring(id or ""):match("^[^-]+%-[^-]+%-(.+)$") or tostring(id or "")
    return string.format("seed-%s-%s", settingKey, suffix)
end

function LocalRequirementPlanner.MergeSeedRoomGroups(existing, settingKey, topicId, generated)
    local untouched, selected, reservedById, existingSeed = {}, {}, {}, {}
    for _, group in ipairs(existing or {}) do
        local legacyScope = group.topicId == nil and group.settingKey == settingKey
        local belongsToTopic = group.topicId == topicId or legacyScope
        if not belongsToTopic then
            untouched[#untouched + 1] = group
        else
            if legacyScope then
                group.topicId, group.settingKey = topicId, nil
                group.id = SeedRoomId(settingKey, group.id)
            end
            if (group.source == "builtin" or group.source == "seed") and group.locked ~= true then
                group.source = "seed"
                existingSeed[group.id] = group
            else
                reservedById[group.id] = group
            end
        end
    end
    local consumed = {}
    for _, group in ipairs(generated or {}) do
        local reserved = reservedById[group.id]
        if reserved then
            selected[#selected + 1] = reserved
            consumed[group.id] = true
        else
            local previous = existingSeed[group.id]
            selected[#selected + 1] = previous and GroupSignature(previous) == GroupSignature(group) and previous or group
        end
    end
    for _, group in ipairs(existing or {}) do
        local belongsToTopic = group.topicId == topicId
        if belongsToTopic and group.source ~= "builtin" and group.source ~= "seed"
            and not consumed[group.id] then
            selected[#selected + 1] = group
        end
    end
    for _, group in ipairs(selected) do untouched[#untouched + 1] = group end
    return untouched
end

function LocalRequirementPlanner.EnsureSeedRoomGroups(existing)
    local original = existing or {}
    local result = original
    local valid, reason = BuiltinRoomRules.Validate()
    if not valid then return nil, false, reason end
    for _, settingKey in ipairs(BuiltinRoomRules.SettingKeys()) do
        local topicId = TopicSeeds.IdForSetting(settingKey)
        local plan, planReason = LocalRequirementPlanner.CompileSeedTopic(settingKey, topicId)
        if not plan then return nil, false, planReason end
        result = LocalRequirementPlanner.MergeSeedRoomGroups(
            result, settingKey, topicId, plan.roomGroups)
    end
    local changed = #result ~= #original
    if not changed then
        for index, group in ipairs(result) do
            if group ~= original[index] then changed = true; break end
        end
    end
    return result, changed
end

-- Compatibility alias for callers and old tests while the persisted records migrate.
LocalRequirementPlanner.EnsureBuiltinRoomGroups = LocalRequirementPlanner.EnsureSeedRoomGroups

function LocalRequirementPlanner.GroupsForContext(groups, topicId, settingKey)
    local result = {}
    for _, group in ipairs(groups or {}) do
        local matchesTopic = topicId ~= nil and group.topicId == topicId
        local matchesSetting = topicId == nil and group.topicId == nil and group.settingKey == settingKey
        if matchesTopic or matchesSetting then result[#result + 1] = group end
    end
    table.sort(result, function(a, b)
        local orderA, orderB = tonumber(a.sortOrder) or 999, tonumber(b.sortOrder) or 999
        if orderA == orderB then return tostring(a.id) < tostring(b.id) end
        return orderA < orderB
    end)
    return result
end

function LocalRequirementPlanner.GroupsForTopic(groups, topicId)
    return LocalRequirementPlanner.GroupsForContext(groups, topicId, nil)
end

return LocalRequirementPlanner
