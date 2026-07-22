local DungeonApp = require("App.DungeonApp")
local FixedThemes = require("Config.FixedThemes")
local DungeonGenerator = require("Generation.DungeonGenerator")
local LocalRequirementPlanner = require("AI.LocalRequirementPlanner")
local TopicSeeds = require("Config.TopicSeeds")

local function Check(condition, message)
    if not condition then error(message, 2) end
end

function Start()
    local app = DungeonApp.new()
    app:Start()
    local panel = app.panel
    Check(panel.buildAnimationCheckbox == nil, "removed build-animation checkbox is still present")
    for name, button in pairs({
        seed = panel.randomSeedButton,
        setting = panel.randomSettingButton,
        theme = panel.randomThemeButton,
    }) do
        Check(button ~= nil and button.props.text == nil and button:GetNumChildren() > 0,
            name .. " random control is not a graphic icon button")
        Check(button.props.borderRadius ~= 999, name .. " random control still uses the pill appearance")
    end
    Check(panel.diceButton == nil, "legacy dice-only random seed control is still present")
    Check(panel.fixedSettingModeButton and panel.fixedSettingList == nil and panel.fixedSettingToggleButton == nil,
        "fixed PCG still exposes an expandable topic list")
    Check(app.dungeon and app.dungeon.sceneInfo, "generated dungeon has no basic scene information")
    Check(app.dungeon.sceneInfo.floorHeight == 5.0 and app.dungeon.sceneInfo.cellSize == 1.0,
        "basic scene information diverged from the authoritative geometry contract")
    Check(panel.sceneFloorHeightValue == nil,
        "floor height is still displayed in the side result panel instead of theme generation")
    local empty = DungeonGenerator.Generate({
        seed = 20260720, floorCount = 2, roomCountsByFloor = { 21, 21 },
        emptyScene = true, floorHeight = 5.0, settingKey = "dungeon", theme = "ancient",
    })
    Check(empty.valid and #empty.rooms == 0 and #empty.edges == 0 and #empty.connectors == 0,
        "fixed PCG empty scene is not a valid roomless generation shell")
    Check(empty.roomCountsByFloor[1] == 0 and empty.roomCountsByFloor[2] == 0,
        "fixed PCG empty scene still contains generated room counts")
    local actualFixed, actualFixedReason = panel.callbacks.onFixedPCG()
    Check(actualFixed, actualFixedReason or "fixed PCG runtime callback failed")
    Check(app.activeFixedThemeId == FixedThemes.MODE_ID and app.dungeon and #app.dungeon.rooms == 0,
        "fixed PCG runtime callback did not install the empty scene")

    panel:OpenCustomSettingModal()
    Check(panel.customFloorHeightField:GetValue() == "5.00",
        "theme generation form did not initialize its editable floor height")
    panel.customNameField:SetValue("现代学校")
    panel.customPromptField:SetValue("现代校园教室、图书馆和实验室")
    panel.customBaseSettingDropdown:SetValue("school")
    Check(panel:RefreshCustomSettingPlan(), "school plan did not refresh on the one-page form")
    Check(panel.customFormPanel:IsVisible() and panel.customPlanPanel:IsVisible(),
        "one-page theme form did not keep input and plan visible together")
    Check(panel.customNextButton == nil and panel.customStep == nil,
        "removed two-step wizard state is still present")
    Check(panel.customResolvedPackKey == "school", "school prompt did not resolve to school pack")
    Check(not panel.customGenerateButton:IsDisabled(), "valid school plan disabled generation")
    Check(panel.customPlanStructure:GetText() ~= "" and panel.customPlanRooms:GetText() ~= "",
        "generation plan did not expose structure and room summaries")

    panel.customNameField:SetValue("深海研究站")
    panel.customPromptField:SetValue("海沟中的金属研究站和观景窗")
    panel.customBaseSettingDropdown:SetValue("dungeon")
    panel.customFloorHeightField:SetValue("4.20")
    Check(panel:RefreshCustomSettingPlan(), "unknown theme did not resolve to the executable generic rules")
    Check(panel.customResolvedPackKey == nil, "unknown theme silently resolved to an installed pack")
    Check(panel.customPlanMode == "generic", "unknown theme did not select generic generation mode")
    Check(not panel.customGenerateButton:IsDisabled(), "generic theme incorrectly disabled generation")
    Check(panel.customPlanStatus:GetText():find("通用规则", 1, true) ~= nil,
        "unknown theme did not expose the universal-rule fallback")
    Check(panel.customPlanStructure:GetText():find("4.20 米", 1, true) ~= nil,
        "generation plan did not include the configured floor height")
    panel.customSettingModal:Close()

    app.SaveLocalCustomizations = function() return true end
    app.ApplyTheme = function() end
    app.Generate = function(self) self:RefreshPanel() end
    -- Keep this smoke test independent from the editor's persisted local cache.
    app.customSettings = TopicSeeds.Ensure({})
    app.roomGroups = {}
    app:EnsureSeedRoomGroups()
    Check(#LocalRequirementPlanner.GroupsForTopic(app.roomGroups, "theme-hospital") == 7,
        "hospital seed rooms were not materialized for the UI flow")
    Check(#LocalRequirementPlanner.GroupsForTopic(app.roomGroups, "theme-school") == 5,
        "school seed rooms were not materialized for the UI flow")
    app.activeCustomSettingId = nil
    local fixedGenerated, fixedReason = panel.callbacks.onFixedPCG()
    Check(fixedGenerated, fixedReason or "fixed PCG theme callback failed")
    Check(app.activeFixedThemeId == FixedThemes.MODE_ID and app.activeCustomSettingId == nil,
        "fixed PCG mode did not become active without creating a custom theme")
    Check(app.settingKey == "dungeon" and app.themeKey == "ancient" and app.floorHeight == 5.0,
        "fixed PCG mode did not reset to the empty-scene baseline")
    Check(app:GenerationOptions(false).emptyScene == true,
        "fixed PCG mode did not mark the generation request as emptyScene")
    Check(panel.callbacks.onSetting("hospital"), "hospital topic selection failed")
    Check(app.topicMode == "custom" and app.activeFixedThemeId == nil
            and app.activeCustomSettingId == "theme-hospital",
        "seed topic did not use the unified custom topic state")
    Check(#app:ActiveRoomGroups() == 7, "hospital topic did not expose seven specific rooms")
    panel:SetState(app:State())
    Check(panel.roomGroupList:GetNumChildren() == 7,
        "hospital specific rooms were not rendered in the room UI")
    panel.callbacks.onSetting("school")
    Check(#app:ActiveRoomGroups() == 5, "school base topic did not expose five specific rooms")
    panel:SetState(app:State())
    Check(panel.roomGroupList:GetNumChildren() == 5,
        "school specific rooms were not rendered in the room UI")
    Check(panel.callbacks.onFixedPCG(), "fixed PCG callback failed after base topic")
    Check(app.topicMode == "fixedPCG" and app.activeFixedThemeId == FixedThemes.MODE_ID
            and app.activeCustomSettingId == nil,
        "fixed PCG retained a base or custom topic selection")
    Check(panel.currentTopicValue:GetText() == "未启用" and panel.currentTopicStatus:GetText() == "固定 PCG",
        "fixed PCG mode did not clear the current AI topic indicator")
    Check(app:ApplyCustomizationData({
        customSettings = {
            { id = "cloud-topic", label = "浜戠棰樻潗", baseSettingKey = "school", packStatus = "ready" },
        },
        activeCustomSettingId = "cloud-topic",
    }, true), "cloud customization reload failed")
    Check(app.topicMode == "fixedPCG" and app.activeFixedThemeId == FixedThemes.MODE_ID
            and app.activeCustomSettingId == nil,
        "cloud customization reload broke fixed PCG exclusivity")
    app.customSettings = TopicSeeds.Ensure({
        { id = "older-topic", label = "旧题材", prompt = "旧题材", baseSettingKey = "dungeon", packStatus = "ready" },
    })
    local genericGenerated, genericReason = panel.callbacks.onCustomSettingSave({
        label = "超市", prompt = "现代超市、货架、收银台和商品区",
        baseSettingKey = "hospital", floorHeight = 4.2,
    }, "generate")
    Check(genericGenerated, genericReason or "generic theme generation callback failed")
    Check(#app.customSettings == 5 and app.customSettings[1].label == "超市"
            and app.customSettings[1].packStatus == "ready",
        "new generic theme was not persisted at the front of the list")
    Check(app.customSettings[1].generationMode == "generic"
            and app.customSettings[1].plannerSource == "generic-programmatic-v1",
        "generic theme generation metadata was not persisted")
    Check(app.customSettings[1].baseSettingKey == "hospital",
        "generic theme did not retain its selected base generation system")
    Check(app.customSettings[1].floorHeight == 4.2 and app.floorHeight == 4.2,
        "generic theme did not save and activate its configured floor height")
    Check(app.topicMode == "custom" and app.activeFixedThemeId == nil,
        "custom topic was not mutually exclusive with fixed PCG")
    Check(panel.currentTopicValue:GetText() == "超市" and panel.currentTopicStatus:GetText() == "已生成",
        "generated supermarket topic was not shown as the current UI topic")
    Check(panel.customSettingExpanded and panel.customSettingList:IsVisible(),
        "generated custom topic did not automatically expand the saved topic list")
    local supermarketCard = panel.customSettingList:GetChildAt(1)
    Check(supermarketCard and supermarketCard.props.borderWidth == 2,
        "generated supermarket topic card was not visibly active")
    Check(#LocalRequirementPlanner.GroupsForTopic(app.roomGroups, app.activeCustomSettingId) == 0,
        "generic theme invented room groups without room definitions")
    local genericTopicId = app.activeCustomSettingId
    Check(panel.callbacks.onCustomSettingDelete(genericTopicId), "generic topic deletion failed")
    Check(#app.customSettings == 4 and app.customSettings[1].id == "older-topic",
        "deleting the new topic also removed an older or seed topic")

    app.customSettings = TopicSeeds.Ensure({})
    app.roomGroups = {}
    app:EnsureSeedRoomGroups()

    local generated, generatedReason = panel.callbacks.onCustomSettingSave({
        label = "UI生成学校", prompt = "学校、教室、图书馆、实验室、食堂和大厅",
        baseSettingKey = "school", floorHeight = 5.5,
    }, "generate")
    Check(generated, generatedReason or "UI topic generation callback failed")
    Check(app.customSettings[1].generationMode == "theme-pack",
        "specialized topic did not persist ThemePack generation mode")
    Check(app.floorHeight == 5.5, "specialized topic did not activate its configured floor height")
    Check(#LocalRequirementPlanner.GroupsForTopic(
            app.roomGroups, app.activeCustomSettingId) == 5,
        "UI topic generation did not create five child room groups")
    Check(app.activeCustomSettingId == app.customSettings[1].id, "generated topic was not activated")
    for _, group in ipairs(LocalRequirementPlanner.GroupsForTopic(
        app.roomGroups, app.activeCustomSettingId)) do
        Check(group.topicId == app.activeCustomSettingId, "generated child group lost its parent topic")
        Check(#(group.propRules or {}) > 0, "generated child group has no executable rules")
        Check(group.prompt:find("5.50 米", 1, true) ~= nil,
            "generated room prompt did not receive the topic floor height")
    end
    local generatedTopicId = app.activeCustomSettingId
    Check(panel.callbacks.onCustomSettingDelete(generatedTopicId), "generated topic deletion failed")
    Check(#LocalRequirementPlanner.GroupsForTopic(app.roomGroups, generatedTopicId) == 0,
        "deleting a topic did not cascade to its child room groups")

    local managed = {
        id = "ui-flow-managed", label = "可管理学校", prompt = "学校", baseSettingKey = "school",
        packStatus = "ready",
    }
    app.customSettings = { managed }
    app.roomGroups = {}
    Check(panel.callbacks.onCustomSettingSelect(managed.id), "left-click selection callback failed")
    Check(app.activeCustomSettingId == managed.id, "selection did not activate the theme")
    Check(panel.callbacks.onCustomSettingRename(managed.id, "重命名学校"), "rename callback failed")
    Check(app.customSettings[1].label == "重命名学校", "rename did not update local theme data")
    Check(panel.callbacks.onCustomSettingDelete(managed.id), "delete callback failed")
    Check(#app.customSettings == 1 and app.customSettings[1].id == TopicSeeds.DEFAULT_ID,
        "deleting the only ready topic did not restore the default seed topic")

    local record = {
        id = "ui-flow-ready", label = "测试学校", prompt = "学校", baseSettingKey = "school",
        packStatus = "ready",
    }
    panel.currentState.customSettings = { record }
    panel:RebuildCustomSettingList(panel.currentState.customSettings)
    local card = panel.customSettingList:GetChildAt(1)
    Check(card and card.props.onClick and card.props.onPointerDown, "theme card lacks click or right-click handlers")
    panel:OpenCustomSettingContextMenu(record, { x = 120, y = 160 })
    Check(panel.customContextMenuLayer:IsVisible(), "right-click menu layer did not open")
    local menu = panel.customContextMenuLayer:GetChildAt(1)
    Check(menu and menu:GetNumChildren() == 4, "right-click menu actions are incomplete")
    panel:CloseCustomSettingContextMenu()
    Check(not panel.customContextMenuLayer:IsVisible(), "right-click menu did not close")

    print("[test] PASS theme pack one-page and context-menu flow")
    app:Stop()
    engine:Exit()
end
