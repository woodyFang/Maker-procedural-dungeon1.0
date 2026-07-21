local LocalRequirementPlanner = require("AI.LocalRequirementPlanner")
local ThemePacks = require("Config.ThemePacks")
local CustomizationStore = require("Config.CustomizationStore")
local DungeonGenerator = require("Generation.DungeonGenerator")

local RESULT_PATH = ".tmp/ai-topic-flow.result.txt"

local function Check(condition, message)
    if not condition then error(message or "check failed", 2) end
end

local function WriteResult(text)
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    local file = File(RESULT_PATH, FILE_WRITE)
    if file and file:IsOpen() then file:WriteString(text); file:Dispose() end
end

local function Run()
    local path = CustomizationStore.GetLocalPath("ai-topic-flow-regression.json")
    fileSystem:Delete(path)
    fileSystem:Delete(path .. ".bak")
    fileSystem:Delete(path .. ".tmp")

    local topic = {
        id = "custom-school-regression", label = "学校", baseSettingKey = "school",
        prompt = "参考双点学校，自动拆分教室、图书馆、实验室、食堂和大厅",
        packStatus = "ready",
    }
    local pack = ThemePacks.Get("school")
    local plan, reason = LocalRequirementPlanner.Compile(topic, pack, 11)
    Check(plan ~= nil, reason)
    local valid, validReason = ThemePacks.ValidateRoomGroups(pack, plan.roomGroups)
    Check(valid, validReason)

    topic.plannerSource = plan.source
    topic.compiledFromRevision = plan.compiledFromRevision
    topic.compiledSpecVersion = plan.schemaVersion
    topic.compiledRoomGroupCount = #plan.roomGroups
    local saved, saveReason = CustomizationStore.SaveAtomic(path, {
        customSettings = { topic }, roomGroups = plan.roomGroups,
        activeCustomSettingId = topic.id, revision = 11,
    })
    Check(saved, "compiled topic save failed: " .. tostring(saveReason))

    local loaded = CustomizationStore.Load(path)
    Check(loaded and loaded.activeCustomSettingId == topic.id, "compiled topic did not reload")
    local groups = LocalRequirementPlanner.GroupsForTopic(loaded.roomGroups, topic.id)
    Check(#groups == 5, "compiled child groups did not reload")
    Check(groups[1].topicId == topic.id and #groups[1].propRules > 0,
        "reloaded group lost its parent or rules")

    local parameters = {
        seed = 2026071601, floorCount = 1, roomCountsByFloor = { 28 },
        settingKey = "school", theme = "schoolDay", roomGroups = groups,
        decorDensitiesByFloor = { 0.72 },
    }
    local first = DungeonGenerator.Generate(parameters)
    local second = DungeonGenerator.Generate(parameters)
    Check(first.valid and second.valid, "planned dungeon generation failed")
    local firstBindings, secondBindings = {}, {}
    for _, room in ipairs(first.rooms) do firstBindings[#firstBindings + 1] = room.id .. ":" .. tostring(room.roomGroupId) end
    for _, room in ipairs(second.rooms) do secondBindings[#secondBindings + 1] = room.id .. ":" .. tostring(room.roomGroupId) end
    Check(table.concat(firstBindings, "|") == table.concat(secondBindings, "|"),
        "same seed did not reproduce room bindings")
    for _, group in ipairs(groups) do
        Check((first.roomGroupCounts[group.id] or 0) >= math.max(1, group.minCount or 0),
            "minimum room count was not satisfied for " .. group.name)
    end

    fileSystem:Delete(path)
    fileSystem:Delete(path .. ".bak")
    fileSystem:Delete(path .. ".tmp")
    print("[test] PASS topic -> five room groups -> save/reload -> deterministic rule execution")
end

function Start()
    local ok, err = xpcall(Run, debug.traceback)
    if not ok then
        WriteResult("FAIL\n" .. tostring(err))
        ErrorExit("[test] FAIL\n" .. tostring(err), 1)
        return
    end
    WriteResult("PASS topic -> five room groups -> save/reload -> deterministic rule execution")
    engine:Exit()
end
