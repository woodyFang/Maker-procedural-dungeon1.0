local DungeonApp = require("App.DungeonApp")
local FixedThemes = require("Config.FixedThemes")
local DungeonGenerator = require("Generation.DungeonGenerator")

local function Check(condition, message)
    if not condition then error(message, 2) end
end

function Start()
    local ok, errorMessage = xpcall(function()
    local app = DungeonApp.new()
    app:Start()
    local panel = app.panel
    Check(app.cloudSyncEnabled == false, "offline mode did not disable cloud sync by default")
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
    Check(panel.fixedSettingModeButton and panel.fixedSettingList and panel.fixedSettingToggleButton
            and panel.aiTopicPanel and panel.fixedTopicPanel,
        "fixed PCG presets were not preserved inside the split topic layout")
    Check(app.dungeon and app.dungeon.sceneInfo, "generated dungeon has no basic scene information")
    Check(app.dungeon.sceneInfo.floorHeight == 5.0 and app.dungeon.sceneInfo.cellSize == 1.0,
        "basic scene information diverged from the authoritative geometry contract")
    Check(panel.sceneFloorHeightValue == nil,
        "floor height is still displayed in the side result panel instead of theme generation")
    Check(panel.shadowCastleRoomSlider == nil and panel.shadowCastleRoomValue == nil,
        "shadow castle still displays a separate total room control")
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

    app.preview:Activate("third")
    Check(app.preview:IsActive() and app.preview.root and app.preview.root:IsEnabled(),
        "preview character was not active before the dynamic-scene test")
    local emptyApplied, emptyApplyReason = panel.callbacks.onFixedSetting("shadowCastle")
    Check(emptyApplied, emptyApplyReason or "Houdini fixed PCG theme callback failed")
    Check(app.dungeon ~= nil and app.bgeoRenderer.root ~= nil
            and (app.bgeoRenderer.stats.markerCount or 0) > 0,
        "shadow castle did not retain its generated Dungeon and Houdini scene")
    Check(app.preview.root == nil and app.preview.character == nil,
        "shadow castle retained character preview nodes")
    Check(not app.editorActive and not app.preview:IsActive(),
        "shadow castle left editor or character preview mode active")
    app.fixedSettingInputCooldown = 0
    local restored, restoreReason = panel.callbacks.onFixedSetting("frozenSanctum")
    Check(restored, restoreReason or "non-empty fixed PCG theme did not restore the scene")
    Check(app.dungeon and app.preview.root and app.preview.character,
        "non-empty fixed PCG theme did not rebuild dungeon and preview character state")
    Check(app.bgeoRenderer.root == nil and app.bgeoRenderer.stats == nil,
        "non-empty fixed PCG theme retained the shadow castle BGEO scene")

    app:ToggleEditorMode("3d")
    Check(app.editorActive and app.forgeCamera:IsTransitioning(),
        "3D editor did not start its camera transition")
    app.fixedSettingInputCooldown = 0
    local transitionApplied, transitionReason = panel.callbacks.onFixedSetting("shadowCastle")
    Check(transitionApplied, transitionReason or "shadow castle failed during an editor camera transition")
    Check(not app.forgeCamera:IsTransitioning(),
        "shadow castle retained an orphaned editor camera transition")
    app:ActivatePreview("first")
    Check(app.preview:IsFirstPerson() and app.preview.cameraOnly,
        "shadow castle first-person camera did not activate after the scene switch")
    local shadowCastleRoot = app.bgeoRenderer.root
    panel.callbacks.onRandomTheme()
    Check(app.topicMode == "fixedPCG" and app.activeFixedThemeId == "shadowCastle",
        "random palette cleared the active shadow castle preset")
    Check(app.bgeoRenderer.root == shadowCastleRoot and app.preview:IsFirstPerson()
            and app.preview.cameraOnly,
        "random palette replaced the shadow castle scene or disabled its first-person camera")
    Check(panel.cameraOnlyTheme
            and not panel.shadowCastleParametersPanel:IsVisible()
            and not panel.shadowCastleCellDebugButton:IsVisible()
            and not panel.shadowCastleLightDebugButton:IsVisible(),
        "random palette exposed internal shadow castle controls")
    local paletteApplied, paletteReason = panel.callbacks.onTheme("ancient")
    Check(paletteApplied, paletteReason or "shadow castle palette selection failed")
    Check(app.topicMode == "fixedPCG" and app.activeFixedThemeId == "shadowCastle"
            and not panel.shadowCastleParametersPanel:IsVisible(),
        "manual palette selection cleared the shadow castle preset")
    panel:SetFixedSettingExpanded(true)
    Check(panel.houdiniFlowButton == nil,
        "fixed-topic expansion retained the internal Houdini flow control")
    panel:SetFixedSettingExpanded(false)
    app.fixedSettingInputCooldown = 0
    local transitionRestored, transitionRestoreReason = panel.callbacks.onFixedSetting("frozenSanctum")
    Check(transitionRestored, transitionRestoreReason or "scene did not recover after first-person regression test")

    app.SaveLocalCustomizations = function() return true end
    local applyThemeCalls, generateCalls, clearSceneCalls = 0, 0, 0
    app.ApplyTheme = function() applyThemeCalls = applyThemeCalls + 1 end
    app.Generate = function() generateCalls = generateCalls + 1 end
    app.ClearSceneContent = function() clearSceneCalls = clearSceneCalls + 1 end
    -- Keep this smoke test independent from the editor's persisted local cache.
    app.customSettings = {}
    app.roomGroups = {}
    app.activeCustomSettingId = nil

    local shadowRefreshCalls = 0
    app.RefreshShadowCastle = function()
        shadowRefreshCalls = shadowRefreshCalls + 1
        return true
    end
    app.fixedSettingInputCooldown = 0
    local shadowGenerated, shadowReason = panel.callbacks.onFixedSetting("shadowCastle")
    Check(shadowGenerated, shadowReason or "shadow castle fixed PCG callback failed")
    Check(app.topicMode == "fixedPCG" and app.activeFixedThemeId == "shadowCastle"
            and app.activeCustomSettingId == nil and shadowRefreshCalls == 1,
        "shadow castle did not remain an exclusive fixed PCG preset")
    Check(applyThemeCalls == 0 and generateCalls == 0,
        "shadow castle bypass did not use its dedicated Houdini refresh path")

    Check(panel.callbacks.onFixedSetting("shadowCastle"),
        "reselecting the active fixed preset failed")
    Check(shadowRefreshCalls == 1,
        "reselecting the active fixed preset rebuilt the scene")

    app.fixedSettingSwitchInProgress = true
    Check(panel.callbacks.onFixedSetting("frozenSanctum"),
        "an in-progress fixed preset click was not ignored")
    app.fixedSettingSwitchInProgress = false
    Check(app.activeFixedThemeId == "shadowCastle" and generateCalls == 0,
        "an in-progress fixed preset click changed the scene")

    Check(panel.callbacks.onFixedSetting("frozenSanctum"),
        "a queued fixed preset click was not ignored during cooldown")
    Check(app.activeFixedThemeId == "shadowCastle" and generateCalls == 0,
        "a queued fixed preset click changed the scene during cooldown")

    app.fixedSettingInputCooldown = 0
    local presetGenerated, presetReason = panel.callbacks.onFixedSetting("frozenSanctum")
    Check(presetGenerated, presetReason or "fixed PCG preset callback failed")
    Check(app.topicMode == "fixedPCG" and app.activeFixedThemeId == "frozenSanctum"
            and app.activeCustomSettingId == nil,
        "fixed PCG preset did not become active without creating a custom theme")
    Check(app.settingKey == "dungeon" and app.themeKey == "frost" and app.floorHeight == 5.6,
        "fixed PCG preset did not apply its authored scene rules")
    Check(app.roomCounts[1] == 15 and app.loopRates[1] == 6 and app.decorDensities[1] == 38,
        "fixed PCG preset did not apply its authored generation parameters")
    Check(applyThemeCalls == 1 and generateCalls == 1,
        "non-external fixed PCG preset did not use native generation")
    Check(clearSceneCalls == 1,
        "switching away from shadow castle did not clear its external scene")
    Check(app:ApplyCustomizationData({
        customSettings = {
            { id = "cloud-preset-topic", label = "云端预设题材", baseSettingKey = "school", packStatus = "ready" },
        },
        activeCustomSettingId = "cloud-preset-topic",
    }, true), "cloud customization reload for a fixed preset failed")
    Check(app.topicMode == "fixedPCG" and app.activeFixedThemeId == "frozenSanctum"
            and app.activeCustomSettingId == nil,
        "cloud customization reload replaced the selected fixed preset")

    app.RefreshShadowCastle = function() return false, "synthetic refresh failure" end
    app.fixedSettingInputCooldown = 0
    local failedShadow, failedShadowReason = panel.callbacks.onFixedSetting("shadowCastle")
    Check(failedShadow == false and failedShadowReason == "synthetic refresh failure",
        "shadow castle refresh failure was not returned to the fixed preset callback")
    app.customSettings = {}

    local fixedGenerated, fixedReason = panel.callbacks.onFixedPCG()
    Check(fixedGenerated, fixedReason or "fixed PCG theme callback failed")
    Check(app.activeFixedThemeId == FixedThemes.MODE_ID and app.activeCustomSettingId == nil,
        "fixed PCG mode did not become active without creating a custom theme")
    Check(app.settingKey == "dungeon" and app.themeKey == "ancient" and app.floorHeight == 5.0,
        "fixed PCG mode did not reset to the empty-scene baseline")
    Check(app:GenerationOptions(false).emptyScene == true,
        "fixed PCG mode did not mark the generation request as emptyScene")
    panel.callbacks.onSetting("hospital")
    Check(app.topicMode == "base" and app.activeFixedThemeId == nil and app.activeCustomSettingId == nil,
        "base topic was not mutually exclusive with fixed PCG")
    Check(panel.callbacks.onFixedPCG(), "fixed PCG callback failed after base topic")
    Check(app.topicMode == "fixedPCG" and app.activeFixedThemeId == FixedThemes.MODE_ID
            and app.activeCustomSettingId == nil,
        "fixed PCG retained a base or custom topic selection")
    Check(app:ApplyCustomizationData({
        customSettings = {
            { id = "cloud-topic", label = "浜戠棰樻潗", baseSettingKey = "school", packStatus = "ready" },
        },
        activeCustomSettingId = "cloud-topic",
    }, true), "cloud customization reload failed")
    Check(app.topicMode == "fixedPCG" and app.activeFixedThemeId == FixedThemes.MODE_ID
            and app.activeCustomSettingId == nil,
        "cloud customization reload broke fixed PCG exclusivity")
    app.customSettings = {}
    local genericGenerated, genericReason = panel.callbacks.onCustomSettingSave({
        label = "深海研究站", prompt = "海沟中的金属研究站和观景窗",
        baseSettingKey = "hospital", floorHeight = 4.2,
    }, "generate")
    Check(genericGenerated, genericReason or "generic theme generation callback failed")
    Check(#app.customSettings == 1 and app.customSettings[1].packStatus == "ready",
        "generic theme was not persisted as executable")
    Check(app.customSettings[1].generationMode == "generic"
            and app.customSettings[1].plannerSource == "generic-programmatic-v1",
        "generic theme generation metadata was not persisted")
    Check(app.customSettings[1].baseSettingKey == "hospital",
        "generic theme did not retain its selected base generation system")
    Check(app.customSettings[1].floorHeight == 4.2 and app.floorHeight == 4.2,
        "generic theme did not save and activate its configured floor height")
    Check(app.topicMode == "custom" and app.activeFixedThemeId == nil,
        "custom topic was not mutually exclusive with fixed PCG")
    Check(#app.roomGroups == 0, "generic theme invented room groups without room definitions")
    local genericTopicId = app.activeCustomSettingId
    Check(panel.callbacks.onCustomSettingDelete(genericTopicId), "generic topic deletion failed")

    local generated, generatedReason = panel.callbacks.onCustomSettingSave({
        label = "UI生成学校", prompt = "学校、教室、图书馆、实验室、食堂和大厅",
        baseSettingKey = "school", floorHeight = 5.5,
    }, "generate")
    Check(generated, generatedReason or "UI topic generation callback failed")
    Check(app.customSettings[1].generationMode == "theme-pack",
        "specialized topic did not persist ThemePack generation mode")
    Check(app.floorHeight == 5.5, "specialized topic did not activate its configured floor height")
    Check(#app.roomGroups == 5, "UI topic generation did not create five child room groups")
    Check(app.activeCustomSettingId == app.customSettings[1].id, "generated topic was not activated")
    for _, group in ipairs(app.roomGroups) do
        Check(group.topicId == app.activeCustomSettingId, "generated child group lost its parent topic")
        Check(#(group.propRules or {}) > 0, "generated child group has no executable rules")
        Check(group.prompt:find("5.50 米", 1, true) ~= nil,
            "generated room prompt did not receive the topic floor height")
    end
    local generatedTopicId = app.activeCustomSettingId
    Check(panel.callbacks.onCustomSettingDelete(generatedTopicId), "generated topic deletion failed")
    Check(#app.roomGroups == 0, "deleting a topic did not cascade to its child room groups")

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
    Check(#app.customSettings == 0, "delete did not remove local theme data")

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

    app.activeCustomSettingId, app.customSettingName = nil, nil
    app.activeFixedThemeId, app.topicMode = "shadowCastle", "fixedPCG"
    app.fixedSettingSceneId = "shadowCastle"
    local clearBeforeBaseSetting = clearSceneCalls
    panel.callbacks.onSetting("school")
    Check(clearSceneCalls == clearBeforeBaseSetting + 1
            and app.activeFixedThemeId == nil and app.fixedSettingSceneId == nil,
        "base setting switch did not clear the Shadow Castle external scene")

    app.activeFixedThemeId, app.topicMode = "shadowCastle", "fixedPCG"
    app.fixedSettingSceneId = "shadowCastle"
    local clearBeforeRandomSetting = clearSceneCalls
    panel.callbacks.onRandomSetting()
    Check(clearSceneCalls == clearBeforeRandomSetting + 1
            and app.activeFixedThemeId == nil and app.fixedSettingSceneId == nil,
        "random setting switch did not clear the Shadow Castle external scene")

    app:Stop()
    end, debug.traceback)
    if not ok then
        ErrorExit("[test] FAIL theme pack one-page and context-menu flow\n" .. tostring(errorMessage), 1)
        return
    end
    ErrorExit("[test] PASS theme pack one-page and context-menu flow", 0)
end
