local DungeonGenerator = require("Generation.DungeonGenerator")
local MultiFloor = require("Generation.MultiFloor")
local NativeDungeonRenderer = require("Rendering.NativeDungeonRenderer")
local ForgeCameraController = require("Input.ForgeCameraController")
local ControlPanel = require("UI.ControlPanel")
local LayoutEditor = require("UI.LayoutEditor")
local SceneLayoutEditor = require("UI.SceneLayoutEditor")
local CameraPreviewController = require("Gameplay.CameraPreviewController")
local Themes = require("Config.Themes")
local FixedThemes = require("Config.FixedThemes")
local ThemePacks = require("Config.ThemePacks")
local GenericThemeRules = require("Config.GenericThemeRules")
local CustomizationStore = require("Config.CustomizationStore")
local TopicSeeds = require("Config.TopicSeeds")
local RoomGroupColors = require("Config.RoomGroupColors")
local DungeonGeometryLibrary = require("Rendering.DungeonGeometryLibrary")
local ProceduralMaterialRules = require("Rendering.ProceduralMaterialRules")
local LocalRequirementPlanner = require("AI.LocalRequirementPlanner")
local EditorData = require("UI.Editor.EditorData")
local UI = require("urhox-libs/UI")

local DungeonApp = {}
DungeonApp.__index = DungeonApp

local CUSTOMIZATION_LOCAL_SAVE = CustomizationStore.GetLocalPath("procedural-dungeon-customization.json")
local CUSTOMIZATION_CLOUD_KEY = "procedural_dungeon_customizations_v1"

local function IsTextInputFocused()
    local focused = UI.GetFocus and UI.GetFocus() or nil
    if not focused then return false end
    local className = focused._className
    return (className == "TextField" or className == "TextArea")
        and focused.state and focused.state.focused == true
end
-- Match the Three editor's transaction model: pointer movement only updates
-- lightweight editor visuals, while authoritative generation is coalesced
-- after the gesture has finished.
local EDITOR_REBUILD_DEBOUNCE_SECONDS = 0.18
local TOPIC_MODE_CUSTOM = "custom"
local TOPIC_MODE_FIXED_PCG = "fixedPCG"

local function HexColor(value, brightness)
    local factor = brightness or 1
    local r, g, b = ((value >> 16) & 0xff) / 255, ((value >> 8) & 0xff) / 255, (value & 0xff) / 255
    return Color(math.min(1, r * factor), math.min(1, g * factor), math.min(1, b * factor), 1)
end

-- “题材”决定稳定的环境光；“色调”只重配模型材质。
-- 这样切换暖灰/冷蓝或冷白/警示红时，不会再靠染雾和换天空制造假色差。
local ENVIRONMENTS = {
    dungeon = {
        preset = "LightGroup/Night.xml", fog = 0x171b24,
        sun = 0xffe8c8, brightness = 1.05,
    },
    hospital = {
        preset = "LightGroup/Daytime.xml", fog = 0x26312f,
        sun = 0xe5f0ed, brightness = 0.92,
    },
    school = {
        preset = "LightGroup/Daytime.xml", fog = 0x28322f,
        sun = 0xfff0d8, brightness = 0.98,
    },
}

function DungeonApp.new()
    return setmetatable({
        seed = 1337, floorCount = 2, floorHeight = MultiFloor.FLOOR_HEIGHT,
        currentFloor = 0, floorViewMode = "neighbors",
        settingKey = "dungeon", themeKey = "ancient",
        roomCounts = { 21, 21 }, loopRates = { 15, 15 }, decorDensities = { 60, 60 },
        customSettings = TopicSeeds.Ensure({}), roomGroups = {}, customPalettes = {},
        nextCustomSettingId = 1, nextRoomGroupId = 1, nextCustomPaletteId = 1,
        activeCustomSettingId = TopicSeeds.DEFAULT_ID, customSettingName = "遗迹", activeFixedThemeId = nil,
        topicMode = TOPIC_MODE_CUSTOM, topicSelectionVersion = 0,
        customizationRevision = 0, customizationUpdatedAt = "", cloudLoadPending = false,
        customizationSaveInFlight = false, customizationSaveQueued = false, queuedSaveCallback = nil,
        editorActive = false, editorMode = "3d", editorTransition = nil, editorEntryMode = nil,
        editorRooms = nil, editorLinks = nil, generationSerial = 0,
        lastGenerationMs = 0, lastGenerationTotalMs = 0,
        lastValidEditorRooms = nil, lastValidEditorLinks = nil,
        editorDirty = false, editorRebuildPending = false,
        editorFrameSerial = 0, editorRebuildAfterFrame = 0, editorRebuildIdle = 0,
        selectedEditorRoom = nil, selectedEditorRoomGroupId = nil,
        graphVisible = false, heatVisible = false, postEnabled = false,
        cameraKeyboardConfirmed = false,
    }, DungeonApp)
end

function DungeonApp:NormalizeTopicSelection()
    if self.activeFixedThemeId == FixedThemes.MODE_ID then
        self.topicMode = TOPIC_MODE_FIXED_PCG
        self.activeFixedThemeId = FixedThemes.MODE_ID
        self.activeCustomSettingId, self.customSettingName = nil, nil
    else
        self.topicMode = TOPIC_MODE_CUSTOM
        self.activeFixedThemeId = nil
        if self.activeCustomSettingId == nil then
            self.activeCustomSettingId = TopicSeeds.DEFAULT_ID
        end
    end
    return self.topicMode
end

function DungeonApp:MarkTopicSelectionChanged()
    self.topicSelectionVersion = (self.topicSelectionVersion or 0) + 1
end

function DungeonApp:RestoreTopicSelection(selection)
    if not selection or selection.mode == TOPIC_MODE_FIXED_PCG then
        self.topicMode = TOPIC_MODE_FIXED_PCG
        self.activeFixedThemeId = FixedThemes.MODE_ID
        self.activeCustomSettingId, self.customSettingName = nil, nil
        self.settingKey, self.themeKey = "dungeon", "ancient"
        self.floorHeight = MultiFloor.FLOOR_HEIGHT
        return
    end

    self.activeFixedThemeId = nil
    local customId = selection.customId
    if not customId and selection.settingKey then customId = TopicSeeds.IdForSetting(selection.settingKey) end
    local record = CustomizationStore.FindById(self.customSettings, customId)
        or CustomizationStore.FindById(self.customSettings, TopicSeeds.DEFAULT_ID)
    if record and record.packStatus ~= "draft" then
        self.topicMode = TOPIC_MODE_CUSTOM
        self.activeCustomSettingId, self.customSettingName = record.id, record.label
        self.settingKey = Themes.settings[record.baseSettingKey] and record.baseSettingKey or "dungeon"
        self.floorHeight = MultiFloor.NormalizeFloorHeight(record.floorHeight)
        local palettes = Themes.GetSetting(self.settingKey).palettes
        self.themeKey = Themes.IsPaletteForSetting(selection.themeKey, self.settingKey)
            and selection.themeKey or palettes[1]
    end
end

function DungeonApp:ApplyCustomizationData(data, preserveTopicSelection)
    if type(data) ~= "table" then return false end
    local selection
    if preserveTopicSelection then
        self:NormalizeTopicSelection()
        selection = {
            mode = self.topicMode,
            customId = self.activeCustomSettingId,
            settingKey = self.settingKey,
            themeKey = self.themeKey,
        }
    end
    local normalized = CustomizationStore.Normalize(data)
    self.customSettings = normalized.customSettings
    self.roomGroups = normalized.roomGroups
    local builtinChanged, builtinReason = self:EnsureSeedRoomGroups()
    if builtinChanged == false and builtinReason then return false end
    self.customPalettes = normalized.customPalettes
    self.nextCustomSettingId = normalized.nextCustomSettingId
    self.nextRoomGroupId = normalized.nextRoomGroupId
    self.nextCustomPaletteId = normalized.nextCustomPaletteId
    self.activeCustomSettingId = normalized.activeCustomSettingId
    self.activeFixedThemeId = nil
    self.customizationRevision = normalized.revision
    self.customizationUpdatedAt = normalized.updatedAt
    Themes.SetCustomPalettes(self.customPalettes)
    local restored = CustomizationStore.RestoreImages(normalized)
    if restored > 0 then print("[DungeonForge] restored reference images=" .. restored) end

    if selection then
        self:RestoreTopicSelection(selection)
    else
        local active = CustomizationStore.FindById(self.customSettings, self.activeCustomSettingId)
        if active and active.packStatus ~= "draft" then
            self.topicMode = TOPIC_MODE_CUSTOM
            self.customSettingName = active.label
            self.settingKey = active.baseSettingKey
            self.floorHeight = MultiFloor.NormalizeFloorHeight(active.floorHeight)
            local setting = Themes.GetSetting(self.settingKey)
            local validPalette = false
            for _, palette in ipairs(setting.palettes) do if palette == self.themeKey then validPalette = true; break end end
            if not validPalette then self.themeKey = setting.palettes[1] end
        else
            local fallback = CustomizationStore.FindById(self.customSettings, TopicSeeds.DEFAULT_ID)
            if fallback then self:UseCustomSetting(fallback) end
        end
        self.activeFixedThemeId = nil
        self:NormalizeTopicSelection()
    end
    return true
end

function DungeonApp:CustomizationData()
    return {
        version = CustomizationStore.SCHEMA_VERSION,
        customSettings = self.customSettings,
        roomGroups = self.roomGroups,
        customPalettes = self.customPalettes,
        nextCustomSettingId = self.nextCustomSettingId,
        nextRoomGroupId = self.nextRoomGroupId,
        nextCustomPaletteId = self.nextCustomPaletteId,
        activeCustomSettingId = self.activeCustomSettingId,
        revision = self.customizationRevision,
        updatedAt = self.customizationUpdatedAt,
    }
end

function DungeonApp:LoadLocalCustomizations()
    local data, source = CustomizationStore.Load(CUSTOMIZATION_LOCAL_SAVE)
    if not data then return false end
    self:ApplyCustomizationData(data)
    print(string.format("[DungeonForge] local customization cache loaded source=%s themes=%d palettes=%d groups=%d",
        tostring(source), #self.customSettings, #self.customPalettes, #self.roomGroups))
    return true
end

function DungeonApp:SaveLocalCustomizations()
    local saved, reason = CustomizationStore.SaveAtomic(CUSTOMIZATION_LOCAL_SAVE, self:CustomizationData())
    if not saved then log:Write(LOG_WARNING, "[DungeonForge] local customization save failed: " .. tostring(reason)) end
    return saved, reason
end

function DungeonApp:LoadCloudCustomizations(onComplete)
    local finished = false
    local revisionAtStart = self.customizationRevision
    local topicSelectionVersionAtStart = self.topicSelectionVersion or 0
    local function Finish(success, source, reason)
        if finished then return end
        finished = true
        self.cloudLoadPending = false
        if onComplete then onComplete(success, source, reason) end
    end

    if not clientCloud then
        log:Write(LOG_WARNING, "[DungeonForge] clientCloud unavailable; using local cache")
        Finish(false, "local", "clientCloud unavailable")
        return
    end

    self.cloudLoadPending = true
    print("[DungeonForge] loading customization cloud key=" .. CUSTOMIZATION_CLOUD_KEY)
    clientCloud:Get(CUSTOMIZATION_CLOUD_KEY, {
        ok = function(values, iscores)
            if self.customizationRevision ~= revisionAtStart then
                print("[DungeonForge] cloud load ignored because local customization changed")
                Finish(true, "local-newer")
                return
            end

            local data = type(values) == "table" and values[CUSTOMIZATION_CLOUD_KEY] or nil
            if type(data) == "table" then
                local localHasData = #self.customSettings > 0 or #self.customPalettes > 0 or #self.roomGroups > 0
                local localRevision = self.customizationRevision or 0
                local cloudRevision = math.max(0, tonumber(data.revision) or 0)
                local localUpdatedAt = self.customizationUpdatedAt or ""
                local cloudUpdatedAt = type(data.updatedAt) == "string" and data.updatedAt or ""
                local localIsNewer = localRevision > cloudRevision
                    or (localRevision == cloudRevision and localUpdatedAt ~= ""
                        and (cloudUpdatedAt == "" or localUpdatedAt > cloudUpdatedAt))
                if localHasData and localIsNewer then
                    print("[DungeonForge] local customization cache is newer; syncing it to cloud")
                    self:SaveCustomizations(function(saved, reason)
                        Finish(saved, saved and "local-synced" or "local", reason)
                    end)
                    return
                end

                self:ApplyCustomizationData(data,
                    self.topicSelectionVersion ~= topicSelectionVersionAtStart)
                self:SaveLocalCustomizations()
                print(string.format("[DungeonForge] cloud customization loaded themes=%d palettes=%d groups=%d",
                    #self.customSettings, #self.customPalettes, #self.roomGroups))
                Finish(true, "cloud")
                return
            end

            local hasLocalData = #self.customSettings > 0 or #self.customPalettes > 0 or #self.roomGroups > 0
            if hasLocalData then
                print("[DungeonForge] cloud customization empty; migrating local cache")
                self:SaveCustomizations(function(saved, reason)
                    Finish(saved, saved and "migrated" or "local", reason)
                end)
            else
                print("[DungeonForge] cloud customization is empty")
                Finish(true, "empty")
            end
        end,
        error = function(code, reason)
            log:Write(LOG_WARNING, string.format(
                "[DungeonForge] cloud customization load failed code=%s reason=%s",
                tostring(code), tostring(reason)))
            Finish(false, "local", tostring(reason))
        end,
        timeout = function()
            log:Write(LOG_WARNING, "[DungeonForge] cloud customization load timed out")
            Finish(false, "local", "timeout")
        end,
    })
end

function DungeonApp:StartCloudCustomizationSave(data, localSaved, onComplete)
    local finished = false
    local function Finish(cloudSaved, reason)
        if finished then return end
        finished = true
        self.customizationSaveInFlight = false
        local target = cloudSaved and "cloud" or (localSaved and "local" or "none")
        if onComplete then onComplete(cloudSaved or localSaved, reason, target) end

        if self.customizationSaveQueued then
            local queuedCallback = self.queuedSaveCallback
            self.customizationSaveQueued, self.queuedSaveCallback = false, nil
            self:StartCloudCustomizationSave(CustomizationStore.Normalize(self:CustomizationData()), true, queuedCallback)
        end
    end

    self.customizationSaveInFlight = true
    if self.panel then self.panel:SetStatus("正在保存到云端…") end
    print(string.format("[DungeonForge] saving customization cloud key=%s revision=%d",
        CUSTOMIZATION_CLOUD_KEY, data.revision or 0))
    clientCloud:Set(CUSTOMIZATION_CLOUD_KEY, data, {
        ok = function()
            print("[DungeonForge] cloud customization saved")
            Finish(true)
        end,
        error = function(code, reason)
            log:Write(LOG_WARNING, string.format(
                "[DungeonForge] cloud customization save failed code=%s reason=%s",
                tostring(code), tostring(reason)))
            Finish(false, tostring(reason))
        end,
        timeout = function()
            log:Write(LOG_WARNING, "[DungeonForge] cloud customization save timed out")
            Finish(false, "timeout")
        end,
    })
end

function DungeonApp:SaveCustomizations(onComplete)
    self.customizationUpdatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local localSaved, localReason = self:SaveLocalCustomizations()
    if not localSaved then
        if onComplete then onComplete(false, localReason, "none") end
        return false, localReason
    end

    if not clientCloud then
        local reason = "clientCloud unavailable"
        log:Write(LOG_WARNING, "[DungeonForge] " .. reason .. "; saved local cache only")
        if onComplete then onComplete(true, reason, "local") end
        return true
    end
    if self.customizationSaveInFlight then
        self.customizationSaveQueued = true
        self.queuedSaveCallback = onComplete
        print("[DungeonForge] cloud save queued; latest revision will replace pending data")
        return true
    end
    self:StartCloudCustomizationSave(CustomizationStore.Normalize(self:CustomizationData()), true, onComplete)
    return true
end

function DungeonApp:ReportCustomizationSave(success, successText, reason, target)
    if not self.panel then return end
    if success and target == "cloud" then
        self.panel:SetStatus(successText .. "（本地与云端）")
    elseif success and target == "local" then
        self.panel:SetStatus(successText .. "（已保存本地；云端同步失败：" .. tostring(reason or "不可用") .. "）")
    else
        self.panel:SetStatus("保存失败：" .. tostring(reason or "未知错误"))
    end
end

function DungeonApp:CreateScene()
    self.scene = Scene()
    self.scene:CreateComponent("Octree")
    self:LoadLightingPreset(self.settingKey)

    self.cameraNode = self.scene:CreateChild("ForgeCamera")
    self.camera = self.cameraNode:CreateComponent("Camera")
    self.camera.nearClip, self.camera.farClip, self.camera.fov = 0.1, 1000, 45
    self.overviewViewport = Viewport:new(self.scene, self.camera)
    renderer:SetViewport(0, self.overviewViewport); renderer.hdrRendering = true
    self.dungeonRenderer = NativeDungeonRenderer.new(self.scene)
    self.forgeCamera = ForgeCameraController.new(self.cameraNode, self.camera)
    print("[DungeonForge] native UrhoX viewport ready")
end

function DungeonApp:LoadLightingPreset(settingKey)
    local environment = ENVIRONMENTS[settingKey] or ENVIRONMENTS.dungeon
    local preset = environment.preset
    if self.lightPreset == preset and self.zone and self.sun then return end
    if self.lightGroupNode then self.lightGroupNode:Remove() end
    self.lightGroupNode = self.scene:CreateChild("LightGroup")
    local file = cache:GetResource("XMLFile", preset)
    if file then
        self.lightGroupNode:LoadXML(file:GetRoot())
        self.zone = self.lightGroupNode:GetComponent("Zone", true)
        self.sun = self.lightGroupNode:GetComponent("Light", true)
        self.lightPreset = preset
        print("[DungeonForge] lighting preset=" .. preset)
    else
        log:Write(LOG_ERROR, "[DungeonForge] missing lighting preset " .. preset)
        self.zone = self.lightGroupNode:CreateComponent("Zone")
        self.zone.boundingBox = BoundingBox(Vector3(-1000, -1000, -1000), Vector3(1000, 1000, 1000))
        local sunNode = self.lightGroupNode:CreateChild("Sun")
        sunNode.rotation = Quaternion(52, -36, 0)
        self.sun = sunNode:CreateComponent("Light")
        self.sun.lightType = LIGHT_DIRECTIONAL
    end
end

function DungeonApp:State()
    self:NormalizeTopicSelection()
    return {
        seed = self.seed, floorCount = self.floorCount, floorHeight = self.floorHeight,
        currentFloor = self.currentFloor,
        floorViewMode = self.floorViewMode, settingKey = self.settingKey, themeKey = self.themeKey,
        roomCounts = self.roomCounts, loopRates = self.loopRates, decorDensities = self.decorDensities,
        customSettings = self.customSettings, roomGroups = self.roomGroups, customPalettes = self.customPalettes,
        activeCustomSettingId = self.activeCustomSettingId, customSettingName = self.customSettingName,
        activeFixedThemeId = self.activeFixedThemeId,
        topicMode = self.topicMode,
        editorActive = self.editorActive, editorMode = self.editorMode,
        selectedEditorRoom = self.selectedEditorRoom,
        selectedEditorRoomGroupId = self.selectedEditorRoomGroupId,
        valid = self.dungeon == nil or self.dungeon.valid,
    }
end

function DungeonApp:EnsureSeedRoomGroups()
    local merged, changed, reason = LocalRequirementPlanner.EnsureSeedRoomGroups(self.roomGroups)
    if not merged then
        log:Write(LOG_ERROR, "[DungeonForge] built-in room rules invalid: " .. tostring(reason))
        return false, reason
    end
    self.roomGroups = merged
    if changed then
        print(string.format("[DungeonForge] materialized seed topic rooms hospital=%d school=%d",
            #LocalRequirementPlanner.GroupsForTopic(self.roomGroups, TopicSeeds.IdForSetting("hospital")),
            #LocalRequirementPlanner.GroupsForTopic(self.roomGroups, TopicSeeds.IdForSetting("school"))))
    end
    return changed
end

function DungeonApp:ActiveRoomGroups()
    return LocalRequirementPlanner.GroupsForTopic(
        self.roomGroups, self.activeCustomSettingId)
end

function DungeonApp:RefreshPanel()
    if self.panel then self.panel:SetState(self:State()) end
end

function DungeonApp:UseCustomSetting(record)
    if not record or record.packStatus == "draft" then return false end
    self.activeFixedThemeId = nil
    self.topicMode = TOPIC_MODE_CUSTOM
    self:MarkTopicSelectionChanged()
    self.activeCustomSettingId, self.customSettingName = record.id, record.label
    self.settingKey = Themes.settings[record.baseSettingKey] and record.baseSettingKey or "dungeon"
    self.floorHeight = MultiFloor.NormalizeFloorHeight(record.floorHeight)
    local palettes = Themes.GetSetting(self.settingKey).palettes
    if not Themes.IsPaletteForSetting(self.themeKey, self.settingKey) then self.themeKey = palettes[1] end
    return true
end

function DungeonApp:ClearRoomGroupAssignments(id)
    local changed = false
    for _, room in ipairs(self.editorRooms or {}) do
        if room.roomGroupId == id then room.roomGroupId = nil; changed = true end
    end
    if self.editor2D and self.editor2D.ClearRoomGroup then self.editor2D:ClearRoomGroup(id) end
    if self.editor3D and self.editor3D.ClearRoomGroup then self.editor3D:ClearRoomGroup(id) end
    if self.selectedEditorRoomGroupId == id then self.selectedEditorRoomGroupId = nil end
    if changed and self.editorRooms then self:Generate(true, false) end
end

function DungeonApp:CreatePanel()
    self.panel = ControlPanel.new({
        onGenerate = function(seed) self.seed = seed or self.seed; self.editorRooms = nil; self:Generate(false, true) end,
        onRandomSeed = function()
            self.seed = ((os.time() * 1103515245 + math.floor(os.clock() * 1000000)) & 0xffffffff)
            self.editorRooms = nil; self:Generate(false, true)
        end,
        onFixedPCG = function()
            self:MarkTopicSelectionChanged()
            self.topicMode = TOPIC_MODE_FIXED_PCG
            self.activeFixedThemeId = FixedThemes.MODE_ID
            self.activeCustomSettingId, self.customSettingName = nil, nil
            self.settingKey, self.themeKey = "dungeon", "ancient"
            self.floorHeight = MultiFloor.FLOOR_HEIGHT
            self.editorRooms = nil
            self.editorLinks = nil
            self:ApplyTheme()
            self:Generate(false, true)
            if self.panel then
                self.panel:SetStatus("固定已进入空场景，等待 PCG 规则接入")
            end
            return true
        end,
        onSetting = function(key)
            local record = CustomizationStore.FindById(
                self.customSettings, TopicSeeds.IdForSetting(key))
            if record then return self.panel.callbacks.onCustomSettingSelect(record.id) end
            return false, "题材不存在。"
        end,
        onRandomSetting = function()
            local ready = {}
            for _, record in ipairs(self.customSettings) do
                if record.packStatus ~= "draft" then ready[#ready + 1] = record end
            end
            if #ready == 0 then return false, "没有可使用的题材。" end
            local nextIndex = 1
            for index, record in ipairs(ready) do
                if record.id == self.activeCustomSettingId then nextIndex = index % #ready + 1; break end
            end
            return self.panel.callbacks.onCustomSettingSelect(ready[nextIndex].id)
        end,
        onCustomSettingSave = function(custom, mode)
            mode = mode == "draft" and "draft" or "generate"
            local previousActiveId, previousName = self.activeCustomSettingId, self.customSettingName
            local previousSetting, previousTheme = self.settingKey, self.themeKey
            local previousFloorHeight = self.floorHeight
            local previousFixedId, previousTopicMode = self.activeFixedThemeId, self.topicMode
            local pack, generationMode = nil, nil
            if mode == "generate" then
                local resolvedKey
                resolvedKey, pack = ThemePacks.ResolvePrompt(custom.prompt, custom.label, nil)
                if not pack then
                    resolvedKey = custom.baseSettingKey
                    pack = ThemePacks.Get(resolvedKey)
                end
                if pack then
                    local validPack, packReason = ThemePacks.Validate(
                        pack, DungeonGeometryLibrary.GEO, ProceduralMaterialRules.PROFILES)
                    if not validPack then return false, "题材包校验失败：" .. tostring(packReason) end
                    custom.baseSettingKey = resolvedKey
                    generationMode = "theme-pack"
                else
                    local contract = GenericThemeRules.Resolve(custom.baseSettingKey)
                    local validGeneric, genericReason = GenericThemeRules.Validate(custom, contract)
                    if not validGeneric then return false, genericReason end
                    custom.baseSettingKey = contract.baseSettingKey
                    generationMode = contract.generationMode
                end
                custom.generationMode = generationMode
                custom.packStatus = "ready"
            else
                custom.generationMode = nil
                custom.packStatus = "draft"
            end
            if not custom.id then
                custom.id = "custom-" .. self.nextCustomSettingId
                self.nextCustomSettingId = self.nextCustomSettingId + 1
            end
            local previous = CustomizationStore.FindById(self.customSettings, custom.id)
            local prepared, oldImageOrError = CustomizationStore.PrepareImage(
                custom, previous, "theme", self.customizationRevision + 1)
            if not prepared then return false, oldImageOrError end
            local previousRoomGroups, plan = self.roomGroups, nil
            if mode == "generate" then
                local planReason
                if generationMode == "theme-pack" then
                    plan, planReason = LocalRequirementPlanner.Compile(
                        prepared, pack, self.customizationRevision + 1)
                else
                    plan, planReason = GenericThemeRules.Compile(
                        prepared, self.customizationRevision + 1)
                end
                if not plan then return false, planReason end
                if pack then
                    local validGroups, groupReason = ThemePacks.ValidateRoomGroups(pack, plan.roomGroups)
                    if not validGroups then return false, "房间规则校验失败：" .. tostring(groupReason) end
                end
                prepared.generationMode = plan.generationMode or generationMode
                prepared.plannerSource = plan.source
                prepared.compiledFromRevision = plan.compiledFromRevision
                prepared.compiledSpecVersion = plan.schemaVersion
                prepared.compiledRoomGroupCount = #plan.roomGroups
                self.roomGroups = LocalRequirementPlanner.MergeRoomGroups(
                    self.roomGroups, prepared.id, plan.roomGroups)
                print(string.format("[DungeonForge] compiled topic=%s groups=%d source=%s reference=%s",
                    prepared.id, #plan.roomGroups, plan.source, tostring(plan.referenceImageAvailable)))
            end
            local _, replaced = CustomizationStore.UpsertFirstById(self.customSettings, prepared)
            if self.panel then self.panel:SetCustomSettingExpanded(true) end
            self.customizationRevision = self.customizationRevision + 1
            if mode == "generate" then
                self:UseCustomSetting(prepared)
            elseif self.activeCustomSettingId == prepared.id then
                local fallback = CustomizationStore.FindById(self.customSettings, TopicSeeds.DEFAULT_ID)
                if fallback and fallback.id ~= prepared.id then self:UseCustomSetting(fallback) end
            end
            self.customizationUpdatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
            local saved, reason = self:SaveLocalCustomizations()
            if not saved then
                CustomizationStore.DeleteById(self.customSettings, prepared.id)
                if replaced then CustomizationStore.UpsertById(self.customSettings, replaced) end
                self.activeCustomSettingId, self.customSettingName = previousActiveId, previousName
                self.activeFixedThemeId, self.topicMode = previousFixedId, previousTopicMode
                self.settingKey, self.themeKey = previousSetting, previousTheme
                self.floorHeight = previousFloorHeight
                self.roomGroups = previousRoomGroups
                self.customizationRevision = math.max(0, self.customizationRevision - 1)
                CustomizationStore.DeleteImageIfUnused(prepared.imagePath, self:CustomizationData())
                return false, "本地保存失败：" .. tostring(reason)
            end
            CustomizationStore.DeleteImageIfUnused(oldImageOrError, self:CustomizationData())
            if mode == "draft" then
                self:RefreshPanel()
                self.panel:SetStatus(string.format("题材草稿“%s”已保存到本地，尚未生成题材包", prepared.label))
                return true
            end
            self.editorRooms = nil
            self:ApplyTheme(); self:Generate(false, false)
            if prepared.generationMode == GenericThemeRules.GENERATION_MODE then
                self.panel:SetStatus(string.format(
                    "题材“%s”已使用通用 PCG 和特定规则生成基础预览；AI 3D 资产接口待接入", prepared.label))
            else
                self.panel:SetStatus(string.format("题材“%s”已生成 %d 个特定房间并执行预览",
                    prepared.label, plan and #plan.roomGroups or 0))
            end
            return true
        end,
        onCustomSettingRename = function(id, label)
            local record = CustomizationStore.FindById(self.customSettings, id)
            if not record then return false, "题材不存在或已被删除。" end
            label = tostring(label or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if label == "" then return false, "题材名称不能为空。" end
            for _, existing in ipairs(self.customSettings) do
                if existing.id ~= id and string.lower(existing.label) == string.lower(label) then
                    return false, "已经存在同名题材。"
                end
            end
            local renamed = {}
            for key, value in pairs(record) do renamed[key] = value end
            renamed.label = label
            local _, replaced = CustomizationStore.UpsertById(self.customSettings, renamed)
            local previousName = self.customSettingName
            if self.activeCustomSettingId == id then self.customSettingName = label end
            self.customizationRevision = self.customizationRevision + 1
            self.customizationUpdatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
            local saved, reason = self:SaveLocalCustomizations()
            if not saved then
                CustomizationStore.UpsertById(self.customSettings, replaced)
                self.customSettingName = previousName
                self.customizationRevision = math.max(0, self.customizationRevision - 1)
                return false, "本地保存失败：" .. tostring(reason)
            end
            self:RefreshPanel()
            self.panel:SetStatus(string.format("题材已重命名为“%s”", label))
            return true
        end,
        onCustomSettingSelect = function(id)
            if self.activeCustomSettingId == id then return true end
            local record = CustomizationStore.FindById(self.customSettings, id)
            if not record then return false, "题材组不存在或已被删除。" end
            if record.packStatus == "draft" then return false, "该题材仍是草稿，请先生成题材包。" end
            local oldId, oldName, oldSetting, oldTheme = self.activeCustomSettingId, self.customSettingName, self.settingKey, self.themeKey
            local oldFixedId, oldTopicMode = self.activeFixedThemeId, self.topicMode
            local oldFloorHeight = self.floorHeight
            self:UseCustomSetting(record)
            self.customizationRevision = self.customizationRevision + 1
            self.customizationUpdatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
            local saved, reason = self:SaveLocalCustomizations()
            if not saved then
                self.activeCustomSettingId, self.customSettingName = oldId, oldName
                self.activeFixedThemeId, self.topicMode = oldFixedId, oldTopicMode
                self.settingKey, self.themeKey = oldSetting, oldTheme
                self.floorHeight = oldFloorHeight
                self.customizationRevision = self.customizationRevision - 1
                return false, reason
            end
            self.editorRooms = nil
            self:ApplyTheme(); self:Generate(false, false)
            self.panel:SetStatus(string.format("已切换到题材“%s”", record.label))
            return true
        end,
        onCustomSettingDelete = function(id)
            local deleteIndex = nil
            for index, item in ipairs(self.customSettings) do if item.id == id then deleteIndex = index; break end end
            local deleted = CustomizationStore.DeleteById(self.customSettings, id)
            if not deleted then return false, "题材组不存在。" end
            local previousRoomGroups = self.roomGroups
            local remainingGroups, deletedChildGroups = {}, {}
            for _, group in ipairs(self.roomGroups) do
                if group.topicId ~= id then
                    remainingGroups[#remainingGroups + 1] = group
                else
                    deletedChildGroups[#deletedChildGroups + 1] = group
                end
            end
            self.roomGroups = remainingGroups
            local wasActive = self.activeCustomSettingId == id
            local fallback
            if wasActive then
                for _, record in ipairs(self.customSettings) do
                    if record.packStatus ~= "draft" then fallback = record; break end
                end
                if not fallback then
                    fallback = TopicSeeds.Get(TopicSeeds.DEFAULT_ID)
                    CustomizationStore.UpsertById(self.customSettings, fallback)
                end
                self:UseCustomSetting(fallback)
            end
            self.customizationRevision = self.customizationRevision + 1
            self:RefreshPanel()
            self.customizationUpdatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
            local saved, reason = self:SaveLocalCustomizations()
            if not saved then
                table.insert(self.customSettings, deleteIndex or (#self.customSettings + 1), deleted)
                self.roomGroups = previousRoomGroups
                if wasActive then self:UseCustomSetting(deleted) end
                self.customizationRevision = self.customizationRevision - 1
                self:RefreshPanel()
                return false, reason
            end
            CustomizationStore.DeleteImageIfUnused(deleted.imagePath, self:CustomizationData())
            for _, group in ipairs(deletedChildGroups) do
                CustomizationStore.DeleteImageIfUnused(group.imagePath, self:CustomizationData())
            end
            if wasActive then self.editorRooms = nil; self:ApplyTheme(); self:Generate(false, false) end
            self.panel:SetStatus(string.format("题材“%s”已从本地删除", deleted.label))
            return true
        end,
        onCustomPaletteSave = function(palette)
            local oldSetting, oldTheme = self.settingKey, self.themeKey
            local oldActiveId, oldActiveName = self.activeCustomSettingId, self.customSettingName
            local oldFloorHeight = self.floorHeight
            local oldFixedId, oldTopicMode = self.activeFixedThemeId, self.topicMode
            if not palette.id then
                palette.id = "custom-palette-" .. self.nextCustomPaletteId
                self.nextCustomPaletteId = self.nextCustomPaletteId + 1
            end
            local _, replaced = CustomizationStore.UpsertById(self.customPalettes, palette)
            Themes.SetCustomPalettes(self.customPalettes)
            self.settingKey, self.themeKey = palette.baseSettingKey, palette.id
            local activeTopic = CustomizationStore.FindById(self.customSettings, self.activeCustomSettingId)
            if activeTopic and activeTopic.baseSettingKey ~= self.settingKey then
                local seedTopic = CustomizationStore.FindById(
                    self.customSettings, TopicSeeds.IdForSetting(self.settingKey))
                if seedTopic then self:UseCustomSetting(seedTopic) end
            end
            self.customizationRevision = self.customizationRevision + 1
            self:RefreshPanel()
            local saved, reason = self:SaveCustomizations(function(success, detail, target)
                self:ReportCustomizationSave(success,
                    string.format("自定义配色“%s”已保存并使用", palette.label), detail, target)
            end)
            if not saved then
                CustomizationStore.DeleteById(self.customPalettes, palette.id)
                if replaced then CustomizationStore.UpsertById(self.customPalettes, replaced) end
                Themes.SetCustomPalettes(self.customPalettes)
                self.settingKey, self.themeKey = oldSetting, oldTheme
                self.activeCustomSettingId, self.customSettingName = oldActiveId, oldActiveName
                self.activeFixedThemeId, self.topicMode = oldFixedId, oldTopicMode
                self.floorHeight = oldFloorHeight
                self.customizationRevision = math.max(0, self.customizationRevision - 1)
                self:RefreshPanel()
                return false, "本地保存失败：" .. tostring(reason)
            end
            self:ApplyTheme(); self:RebuildView(); self:RefreshPanel()
            return true
        end,
        onCustomPaletteDelete = function(id)
            local deleteIndex = nil
            for index, item in ipairs(self.customPalettes) do if item.id == id then deleteIndex = index; break end end
            local deleted = CustomizationStore.DeleteById(self.customPalettes, id)
            if not deleted then return false, "自定义配色不存在。" end
            local wasActive = self.themeKey == id
            Themes.SetCustomPalettes(self.customPalettes)
            if wasActive then self.themeKey = Themes.GetSetting(self.settingKey).palettes[1] end
            self.customizationRevision = self.customizationRevision + 1
            self:RefreshPanel()
            local saved, reason = self:SaveCustomizations(function(success, detail, target)
                self:ReportCustomizationSave(success, "自定义配色已删除", detail, target)
            end)
            if not saved then
                table.insert(self.customPalettes, deleteIndex or (#self.customPalettes + 1), deleted)
                Themes.SetCustomPalettes(self.customPalettes)
                if wasActive then self.themeKey = deleted.id end
                self.customizationRevision = math.max(0, self.customizationRevision - 1)
                self:RefreshPanel()
                return false, reason
            end
            if wasActive then self:ApplyTheme(); self:RebuildView(); self:RefreshPanel() end
            return true
        end,
        onTheme = function(key)
            if not Themes.IsPaletteForSetting(key, self.settingKey) then return false, "该配色不适用于当前题材。" end
            if self.activeFixedThemeId == FixedThemes.MODE_ID then
                local fallback = CustomizationStore.FindById(
                    self.customSettings, TopicSeeds.IdForSetting(self.settingKey))
                    or CustomizationStore.FindById(self.customSettings, TopicSeeds.DEFAULT_ID)
                if fallback then self:UseCustomSetting(fallback) end
            end
            self.activeFixedThemeId = nil
            self.themeKey = key; self:ApplyTheme(); self:RebuildView(); self:RefreshPanel(); return true
        end,
        onRandomTheme = function()
            if self.activeFixedThemeId == FixedThemes.MODE_ID then
                local fallback = CustomizationStore.FindById(
                    self.customSettings, TopicSeeds.IdForSetting(self.settingKey))
                    or CustomizationStore.FindById(self.customSettings, TopicSeeds.DEFAULT_ID)
                if fallback then self:UseCustomSetting(fallback) end
            end
            self.activeFixedThemeId = nil
            self.themeKey = Themes.RandomPalette(self.settingKey, self.themeKey)
            self:ApplyTheme(); self:RebuildView(); self:RefreshPanel()
        end,
        onRoomGroupSave = function(group)
            if not group.id then
                group.id = "room-group-" .. self.nextRoomGroupId
                self.nextRoomGroupId = self.nextRoomGroupId + 1
            end
            local previous = CustomizationStore.FindById(self.roomGroups, group.id)
            if previous then
                for _, field in ipairs({ "topicId", "settingKey", "plannerSource", "compiledFromRevision", "compiledSpecVersion",
                    "sortOrder", "roleKeys", "defaultGroup", "minCount", "maxCount", "minArea", "maxArea",
                    "propRules", "color", "ruleClass" }) do
                    if group[field] == nil then group[field] = previous[field] end
                end
                group.source, group.locked = "manual", true
            else
                group.topicId = group.topicId or self.activeCustomSettingId
                group.settingKey = group.topicId and nil or self.settingKey
                group.source, group.locked = "manual", true
            end
            if group.topicId then group.settingKey = nil end
            if not group.topicId and not group.settingKey then
                group.settingKey = "dungeon"
            end
            group.color = RoomGroupColors.Parse(group.color,
                RoomGroupColors.Default(group, #self.roomGroups + 1))
            local prepared, oldImageOrError = CustomizationStore.PrepareImage(
                group, previous, "room", self.customizationRevision + 1)
            if not prepared then return false, oldImageOrError end
            local _, replaced = CustomizationStore.UpsertById(self.roomGroups, prepared)
            self.customizationRevision = self.customizationRevision + 1
            self:RefreshPanel()
            local saved, reason = self:SaveCustomizations(function(success, detail, target)
                self:ReportCustomizationSave(success,
                    string.format("房间“%s”已保存", prepared.name), detail, target)
            end)
            if not saved then
                CustomizationStore.DeleteById(self.roomGroups, prepared.id)
                if replaced then CustomizationStore.UpsertById(self.roomGroups, replaced) end
                self.customizationRevision = self.customizationRevision - 1
                CustomizationStore.DeleteImageIfUnused(prepared.imagePath, self:CustomizationData())
                self:RebuildView()
                self:RefreshPanel()
                return false, "本地保存失败：" .. tostring(reason)
            end
            CustomizationStore.DeleteImageIfUnused(oldImageOrError, self:CustomizationData())
            self:RebuildView()
            if self.dungeon then
                if self.editor2D then self.editor2D:SyncDungeon(self.dungeon, self.currentFloor, self:ActiveRoomGroups()) end
                if self.editor3D then self.editor3D:SyncDungeon(self.dungeon, self.currentFloor, self:ActiveRoomGroups()) end
            end
            self:RefreshPanel()
            return true
        end,
        onRoomGroupDelete = function(id)
            local deleteIndex = nil
            for index, item in ipairs(self.roomGroups) do if item.id == id then deleteIndex = index; break end end
            local target = CustomizationStore.FindById(self.roomGroups, id)
            if target and tostring(target.id or ""):sub(1, 8) == "builtin-" then
                return false, "内置房间不能删除，可以编辑其规则。"
            end
            local deleted = CustomizationStore.DeleteById(self.roomGroups, id)
            if not deleted then return false, "房间不存在。" end
            self.customizationRevision = self.customizationRevision + 1
            self:RefreshPanel()
            local saved, reason = self:SaveCustomizations(function(success, detail, target)
                self:ReportCustomizationSave(success, "房间已删除", detail, target)
            end)
            if not saved then
                table.insert(self.roomGroups, deleteIndex or (#self.roomGroups + 1), deleted)
                self.customizationRevision = self.customizationRevision - 1
                self:RefreshPanel()
                return false, reason
            end
            self:ClearRoomGroupAssignments(id)
            CustomizationStore.DeleteImageIfUnused(deleted.imagePath, self:CustomizationData())
            self:RefreshPanel()
            return true
        end,
        onRoomGroupAssign = function(id)
            local groupId = id ~= "" and id or nil
            if groupId then
                local visible = false
                for _, group in ipairs(self:ActiveRoomGroups()) do
                    if group.id == groupId then visible = true; break end
                end
                if not visible then return false, "该房间不属于当前题材或已被删除。" end
            end
            if not self.editor or not self.editor.SetSelectedRoomGroup then return false, "请先选择一个房间。" end
            return self.editor:SetSelectedRoomGroup(groupId)
        end,
        onFloorSelect = function(floor)
            self.currentFloor = math.max(0, math.min(self.floorCount - 1, floor))
            if self.editor2D then self.editor2D:SetFloor(self.currentFloor) end
            if self.editor3D then self.editor3D:SetFloor(self.currentFloor) end
            if self.dungeon then self.forgeCamera:SetTargetFloor(self.dungeon, self.currentFloor) end
            self:RebuildView(); self:RefreshPanel()
        end,
        onRoomCount = function(value)
            local changedFloor = self.currentFloor
            local preservedDungeon = self.dungeon
            self.roomCounts[changedFloor + 1] = value
            self.editorRooms = nil
            self:Generate(false, false, changedFloor, preservedDungeon)
        end,
        onLoopRate = function(value)
            local changedFloor = self.currentFloor
            local preservedDungeon = self.dungeon
            self.loopRates[changedFloor + 1] = value
            self.editorRooms = nil
            self:Generate(false, false, changedFloor, preservedDungeon)
        end,
        onDecorDensity = function(value)
            self.decorDensities[self.currentFloor + 1] = value
            -- Decoration has its own floor-local random stream and does not
            -- need to perturb generation retries or stair ordering.
            self:Generate(self.editorRooms ~= nil, false)
        end,
        onAddFloorBefore = function() self:AddFloor(self.currentFloor + 1) end,
        onAddFloorAfter = function() self:AddFloor(self.currentFloor + 2) end,
        onRemoveFloor = function() self:RemoveFloor() end,
        onFloorView = function(mode) self.floorViewMode = mode; self:RebuildView(); self:RefreshPanel() end,
        onToggleEditor = function() self:ToggleEditorMode("3d") end,
        onOpenEditor2D = function() self:ToggleEditorMode("2d") end,
        onPreview = function(mode) self:ActivatePreview(mode) end,
        onExitPreview = function() if self.preview then self.preview:Exit() end end,
    }, self:State())
end

function DungeonApp:Start()
    input.mouseMode = MM_ABSOLUTE
    self:LoadLocalCustomizations()
    self:EnsureSeedRoomGroups()
    self:CreateScene(); self:ApplyTheme()
    self.eventNode = Node(); self.eventObject = self.eventNode:CreateScriptObject("LuaScriptObject")
    self:CreatePanel()
    local editorCallbacks = {
        onCommit = function(rooms, links)
            self.editorRooms, self.editorLinks = rooms, links
            local mirror = self.editorMode == "2d" and self.editor3D or self.editor2D
            if self.editor and mirror and mirror ~= self.editor and mirror.SyncEditorState then
                mirror:SyncEditorState(self.editor)
            end
            -- Never rebuild inside the pointer callback. Queue one model rebuild
            -- after the gesture has fully released so dragging stays responsive.
            self.editorDirty = true
            self.editorRebuildPending = true
            -- The commit can happen on the pointer-release frame. Rebuilding in
            -- that same frame resets the editor while Input is still publishing
            -- the release edge, which can swallow the next press. Wait until the
            -- following editor frame before replacing the model and overlays.
            self.editorRebuildAfterFrame = (self.editorFrameSerial or 0) + 1
            self.editorRebuildIdle = 0
        end,
        onSelection = function(index, room, mode, linkIndex, link)
            if mode ~= self.editorMode then return end
            self.selectedEditorRoom = index
            self.selectedEditorRoomGroupId = room and room.roomGroupId or nil
            if mode == "2d" then
                self.dungeonRenderer:SetEditorSelection(self.dungeon, index, linkIndex, link)
            else
                self.dungeonRenderer:ClearEditorSelection()
            end
            self:RefreshPanel()
        end,
        onClose = function() self:ToggleEditor(false) end,
        onStatus = function(text) self.panel:SetStatus(text) end,
        onRoomGroupMenu = function()
            self:RefreshPanel()
            if self.panel.OpenRoomGroupAssignment then self.panel:OpenRoomGroupAssignment() end
        end,
        onViewMode = function(mode) self:SetEditorMode(mode) end,
    }
    self.editor2D = LayoutEditor.new(self.eventObject, editorCallbacks)
    self.editor3D = SceneLayoutEditor.new(self.scene, self.camera, self.eventObject, editorCallbacks)
    self.editor = self.editor3D
    self.preview = CameraPreviewController.new(self.scene, self.dungeonRenderer, self.cameraNode, {
        onPreviewChange = function(active, mode)
            self.panel:SetPreviewActive(active, mode)
            if not active then self:RestoreOverview() end
        end,
    })
    self.eventObject:SubscribeToEvent("Update", function(_, _, eventData) self:HandleUpdate(eventData:GetFloat("TimeStep")) end)
    self:Generate(false, true)
    self.panel:SetStatus("正在读取云端题材…")
    self:LoadCloudCustomizations(function(success, source, reason)
        if success and (source == "cloud" or source == "local-synced") then
            self:ApplyTheme()
            self.editorRooms, self.editorLinks = nil, nil
            self:Generate(false, false)
        end
        self:RefreshPanel()
        if source == "cloud" then
            self.panel:SetStatus("云端题材已加载")
        elseif source == "migrated" then
            self.panel:SetStatus("本地题材已迁移并保存到云端")
        elseif source == "local-synced" then
            self.panel:SetStatus("较新的本地题材已重新同步到云端")
        elseif source == "empty" then
            self.panel:SetStatus("云端暂无自定义题材")
        elseif source == "local-newer" then
            self.panel:SetStatus("已保留刚刚编辑的本地题材")
        elseif not success then
            self.panel:SetStatus("云端读取失败，已使用本地缓存：" .. tostring(reason or "未知错误"))
        end
    end)
end

function DungeonApp:ApplyTheme()
    local theme = Themes.Get(self.themeKey)
    self:LoadLightingPreset(self.settingKey)
    self.zone.fogColor = HexColor(theme.fog, 1.0)
    self.zone.fogStart, self.zone.fogEnd = 0, 1000
    self.zone.fogDensity = theme.fogDensity
    self.zone.ambientSource = AMBIENT_COLOR
    self.zone.ambientGradient = true
    self.zone.ambientStartColor = HexColor(theme.sky, 1.0)
    self.zone.ambientEndColor = HexColor(theme.ground, 1.0)
    self.zone.ambientColor = HexColor(theme.sky, 1.0)
    self.zone.ambientIntensity = theme.ambient
    self.zone.autoExposureEnabled = false
    self.zone.bloomPlusEnabled = self.postEnabled
    self.sun.color = HexColor(theme.sun, 1.0)
    self.sun.brightness = theme.sunIntensity
    self.sun.castShadows = true
    self.sun.shadowBias = BiasParameters(0.00025, 0.5)
    self.sun.shadowCascade = CascadeParameters(12.0, 45.0, 140.0, 0.0, 0.8)
end

function DungeonApp:RebuildView(animate)
    if not self.dungeon then return end
    self.dungeonRenderer:Build(self.dungeon, self.themeKey, {
        currentFloor = self.currentFloor, viewMode = self.floorViewMode,
        graphVisible = self.graphVisible, heatVisible = self.heatVisible, settingKey = self.settingKey,
        roomGroups = self:ActiveRoomGroups(),
        animate = animate == true,
    })
end

function DungeonApp:GenerationOptions(useEditor, changedFloor, preserveDungeon)
    local loops, densities = {}, {}
    for floor = 1, self.floorCount do
        loops[floor] = (self.loopRates[floor] or 15) / 100
        densities[floor] = (self.decorDensities[floor] or 60) / 100
    end
    return {
        seed = self.seed, floorCount = self.floorCount, roomCountsByFloor = self.roomCounts,
        floorHeight = self.floorHeight,
        loopRatesByFloor = loops, decorDensitiesByFloor = densities,
        theme = self.themeKey, settingKey = self.settingKey,
        roomGroups = self:ActiveRoomGroups(),
        emptyScene = self.activeFixedThemeId == FixedThemes.MODE_ID,
        changedFloor = changedFloor,
        preserveDungeon = preserveDungeon,
        editorEnabled = useEditor, editorRooms = useEditor and self.editorRooms or nil,
        editorEdges = useEditor and self.editorLinks or nil,
    }
end

function DungeonApp:Generate(useEditor, frameCamera, changedFloor, preserveDungeon)
    local started = os.clock(); self.generationSerial = self.generationSerial + 1
    print(string.format("[DungeonForge] generate #%d seed=%u floors=%d editor=%s", self.generationSerial,
        self.seed & 0xffffffff, self.floorCount, tostring(useEditor)))
    local dungeon = DungeonGenerator.Generate(self:GenerationOptions(useEditor, changedFloor, preserveDungeon))
    local generationMs = (os.clock() - started) * 1000
    self.lastGenerationMs = generationMs
    self.dungeon, self.seed = dungeon, dungeon.requestedSeed
    self.roomCounts = {}
    for floor = 1, self.floorCount do self.roomCounts[floor] = dungeon.roomCountsByFloor[floor] or 0 end
    self:RebuildView(frameCamera == true)
    if frameCamera then self.forgeCamera:FrameDungeon(dungeon, self.currentFloor) end
    self.panel:SetDungeon(dungeon, generationMs); self:RefreshPanel()
    if self.editor2D then self.editor2D:SyncDungeon(dungeon, self.currentFloor, self:ActiveRoomGroups()) end
    if self.editor3D then self.editor3D:SyncDungeon(dungeon, self.currentFloor, self:ActiveRoomGroups()) end
    if self.editor then
        local editorShouldBeVisible = self.editorActive and not self.editorTransition
        -- SyncDungeon already refreshes the overlay. Re-entering the same visible
        -- state also resets EditorInteraction, so only change actual visibility.
        if self.editor:IsVisible() ~= editorShouldBeVisible then
            self.editor:SetVisible(editorShouldBeVisible)
        end
    end
    if self.preview then self.preview:SyncDungeon(dungeon, self.currentFloor) end
    self.lastGenerationTotalMs = (os.clock() - started) * 1000
    print(string.format("[DungeonForge] valid=%s rooms=%d connectors=%d hash=%s time=%.1fms",
        tostring(dungeon.valid), #dungeon.rooms, #dungeon.connectors, tostring(dungeon.hash), generationMs))
    if not dungeon.valid then log:Write(LOG_ERROR, "[DungeonForge] " .. table.concat(dungeon.errors or {}, "; ")) end
    return dungeon.valid == true
end

local function CopyEditorLinks(links)
    local result = {}
    for index, link in ipairs(links or {}) do result[index] = EditorData.CopyLink(link) end
    return result
end

function DungeonApp:CaptureLastValidEditorState()
    local editor = self.editor or self.editor3D
    if not editor then return false end
    self.lastValidEditorRooms = editor:GetRooms()
    self.lastValidEditorLinks = editor:GetLinks()
    return true
end

function DungeonApp:GenerateEditorWithRollback(frameCamera)
    if self:Generate(true, frameCamera == true) then
        self:CaptureLastValidEditorState()
        return true
    end
    if not self.lastValidEditorRooms or not self.lastValidEditorLinks then return false end
    self.editorRooms = EditorData.CopyRooms(self.lastValidEditorRooms)
    self.editorLinks = CopyEditorLinks(self.lastValidEditorLinks)
    local restored = self:Generate(true, frameCamera == true)
    if self.panel then self.panel:SetStatus(restored
        and "本次编辑会产生无效布局，已恢复到上一个有效状态。"
        or "布局无效，且恢复上一个有效状态失败。") end
    print("[DungeonForge] invalid editor commit rolled back to last valid state")
    return false
end

function DungeonApp:AddFloor(luaIndex)
    local source = math.max(1, math.min(self.floorCount, self.currentFloor + 1))
    table.insert(self.roomCounts, luaIndex, self.roomCounts[source] or 21)
    table.insert(self.loopRates, luaIndex, self.loopRates[source] or 15)
    table.insert(self.decorDensities, luaIndex, self.decorDensities[source] or 60)
    self.floorCount = self.floorCount + 1; self.currentFloor = luaIndex - 1
    self.editorRooms = nil; self:Generate(false, true)
    if self.floorCount > MultiFloor.RECOMMENDED_MAX_FLOORS then
        self.panel:SetStatus(string.format("已添加第 %d 层；建议不超过 %d 层以控制生成耗时和编辑复杂度。",
            self.floorCount, MultiFloor.RECOMMENDED_MAX_FLOORS))
    end
end

function DungeonApp:RemoveFloor()
    if self.floorCount <= 1 then self.panel:SetStatus("至少保留 1 层"); return end
    local index = self.currentFloor + 1
    table.remove(self.roomCounts, index); table.remove(self.loopRates, index); table.remove(self.decorDensities, index)
    self.floorCount = self.floorCount - 1; self.currentFloor = math.min(self.currentFloor, self.floorCount - 1)
    self.editorRooms = nil; self:Generate(false, true)
end

function DungeonApp:SetEditorMode(mode)
    if mode ~= "2d" and mode ~= "3d" then return end
    local source = self.editor
    local target = mode == "3d" and self.editor3D or self.editor2D
    if source and target and source ~= target and target.SyncEditorState then
        target:SyncEditorState(source)
    end
    self.editorMode = mode
    self.editor = target
    if not self.editorActive or self.editorTransition then return end

    if mode == "3d" and not self.forgeCamera:IsEditViewActive() then
        self.editor2D:SetVisible(false)
        self.editor3D:SetVisible(false)
        local planeY = self.currentFloor * self.dungeon.floorHeight + 0.22
        self.editorEntryMode = "3d"
        if self.forgeCamera:BeginEditView(planeY) then
            self.editorTransition = "in"
            self.panel:SetEditorActive(true, mode)
            self.panel:SetStatus("正在切换到三维正交顶视编辑…")
            return
        end
        self.editorEntryMode = nil
    elseif mode == "2d" then
        self.forgeCamera:UsePerspectiveView()
    end

    self.editor2D:SetVisible(mode == "2d")
    self.editor3D:SetVisible(mode == "3d")
    self.panel:SetEditorActive(true, mode)
    self.panel:SetStatus(mode == "3d"
        and "三维布局编辑：正交顶视；左键编辑，空白/Alt+左键或中键平移，滚轮缩放"
        or "二维平面编辑：拖动使用轻量预览，松手后同步三维；Tab 返回三维，Esc 完成")
end

function DungeonApp:FinishEditorExit()
    self.editorTransition = nil
    self.forgeCamera:UsePerspectiveView()
    self.floorViewMode = self.floorViewBeforeEditor or self.floorViewMode
    self.floorViewBeforeEditor = nil
    self:RebuildView()
    self:RefreshPanel()

    local pendingPreviewMode = self.pendingPreviewMode
    self.pendingPreviewMode = nil
    if pendingPreviewMode then self:ActivatePreview(pendingPreviewMode) end
end

function DungeonApp:UpdateEditorTransition(timeStep)
    local phase, completed = self.forgeCamera:UpdateTransition(timeStep)
    if not completed then return end

    if phase == "in" then
        self.editorTransition = nil
        local entryMode = self.editorEntryMode or self.editorMode or "3d"
        self.editorEntryMode = nil
        self:SetEditorMode(entryMode)
    elseif phase == "out" then
        self:FinishEditorExit()
    end
end

function DungeonApp:ToggleEditor(force, preferredMode)
    if self.preview and self.preview:IsActive() then return end
    if self.forgeCamera:IsTransitioning() then return end
    local nextValue = force
    if nextValue == nil then nextValue = not self.editorActive end
    if nextValue == self.editorActive then return end

    if nextValue then
        local entryMode = preferredMode == "2d" and "2d" or "3d"
        self.editorActive = true
        self.floorViewBeforeEditor = self.floorViewMode
        self.floorViewMode = "current"
        self:RebuildView()
        self.editor2D:SyncDungeon(self.dungeon, self.currentFloor, self:ActiveRoomGroups())
        self.editor3D:SyncDungeon(self.dungeon, self.currentFloor, self:ActiveRoomGroups())
        self.editorEntryMode = entryMode
        self.editorMode = entryMode
        self.editor = entryMode == "2d" and self.editor2D or self.editor3D
        self.editor2D:SetVisible(false)
        self.editor3D:SetVisible(false)
        self:CaptureLastValidEditorState()
        self.editorEntryMode = nil
        self.forgeCamera:UsePerspectiveView()
        self:SetEditorMode(entryMode)
    else
        self.editorActive = false
        self.editorEntryMode = nil
        self.editor2D:SetVisible(false)
        self.editor3D:SetVisible(false)
        self.dungeonRenderer:ClearEditorSelection()
        if self.editorDirty then
            self.editorDirty = false
            self.editorRebuildPending = false
            self.editorRebuildAfterFrame = 0
            self.editorRebuildIdle = 0
            self:GenerateEditorWithRollback(false)
        end
        self:FinishEditorExit()
    end
    self.panel:SetEditorActive(nextValue, self.editorMode)
end

function DungeonApp:ToggleEditorMode(mode)
    if mode ~= "2d" and mode ~= "3d" then return end
    if self.editorActive then
        if self.editorMode == mode then
            self:ToggleEditor(false)
        else
            self:SetEditorMode(mode)
        end
        return
    end
    self:ToggleEditor(true, mode)
end

function DungeonApp:FlushEditorModelRebuild(timeStep)
    if not self.editorActive or not self.editorRebuildPending or not self.editor then return false end
    if (self.editorFrameSerial or 0) < (self.editorRebuildAfterFrame or 0) then return false end
    if self.editor.drag or self.editor.draw then return false end
    if self.editor.editorInteraction and self.editor.editorInteraction:IsCaptured() then return false end
    local pointerBusy = input:GetMouseButtonDown(MOUSEB_LEFT)
        or input:GetMouseButtonDown(MOUSEB_MIDDLE)
        or input:GetMouseButtonDown(MOUSEB_RIGHT)
    if pointerBusy then self.editorRebuildIdle = 0; return false end
    self.editorRebuildIdle = (self.editorRebuildIdle or 0) + math.max(0, timeStep or 0)
    if self.editorRebuildIdle < EDITOR_REBUILD_DEBOUNCE_SECONDS then return false end
    self.editorRebuildPending, self.editorDirty = false, false
    self.editorRebuildAfterFrame = 0
    self.editorRebuildIdle = 0
    self:GenerateEditorWithRollback(false)
    print("[DungeonForge] editor model rebuilt from committed rooms/paths")
    return true
end

function DungeonApp:ActivatePreview(mode)
    if not self.preview or not self.dungeon then return end
    if self.forgeCamera:IsTransitioning() then return end
    if self.editorActive then
        self.pendingPreviewMode = mode or "third"
        self:ToggleEditor(false)
        return
    end
    if not self.preview:IsActive() then
        self.floorViewBeforePreview = self.floorViewMode
        self.floorViewMode = "current"
        self:RebuildView()
    end
    self.forgeCamera.enabled = false
    self.preview:SyncDungeon(self.dungeon, self.currentFloor)
    self.preview:Activate(mode or "third")
end

function DungeonApp:RestoreOverview()
    self.floorViewMode = self.floorViewBeforePreview or "neighbors"
    self.forgeCamera.enabled = true
    self.panel:SetPreviewActive(false, nil)
    self:RebuildView()
    self:RefreshPanel()
end

function DungeonApp:ConfirmCameraKeyboardInput()
    if self.cameraKeyboardConfirmed then return end
    self.cameraKeyboardConfirmed = true
    self.panel:SetStatus("相机键盘移动已触发：WASD/方向键移动，Shift 加速")
    print("[DungeonForge] camera keyboard movement confirmed")
end

function DungeonApp:HandleUpdate(timeStep)
    self.dungeonRenderer:Update(timeStep)
    if self.preview and self.preview:IsActive() then self.preview:Update(timeStep); return end
    local textInputFocused = IsTextInputFocused()
    if not textInputFocused and input:GetKeyPress(KEY_E) then self:ToggleEditorMode("3d") end
    if textInputFocused then return end
    if self.editorTransition then
        self:UpdateEditorTransition(timeStep)
        return
    end
    if self.editorActive then
        self.editorFrameSerial = (self.editorFrameSerial or 0) + 1
        self.editor:Update(timeStep)
        if self:FlushEditorModelRebuild(timeStep) then return end
        local allowBlankPan = self.editorMode == "3d"
            and self.editor.IsBlankPanActive and self.editor:IsBlankPanActive()
        local altDown = input:GetKeyDown(KEY_LALT) or input:GetKeyDown(KEY_RALT)
        local pointerBlocked = self.editorMode == "2d"
            and self.editor2D.IsPointerInsidePanel and self.editor2D:IsPointerInsidePanel()
        local allowLeftPan = self.editorMode == "2d" or allowBlankPan or altDown
        local cameraMoved
        if self.editorMode == "3d" and self.forgeCamera:IsEditViewActive() then
            if input:GetKeyPress(KEY_F) and self.forgeCamera:FrameEditView() then
                self.panel:SetStatus("已将编辑焦点复位到布局中心（F）")
            end
            cameraMoved = self.forgeCamera:UpdateEditView(timeStep, allowBlankPan)
        else
            cameraMoved = self.forgeCamera:Update(timeStep, allowLeftPan, pointerBlocked)
        end
        if cameraMoved then
            self:ConfirmCameraKeyboardInput()
        end
        return
    end
    if input:GetKeyPress(KEY_R) then
        self.seed = ((os.time() * 1103515245 + math.floor(os.clock() * 1000000)) & 0xffffffff)
        self.editorRooms, self.editorLinks = nil, nil
        self:Generate(false, true)
        return
    end
    if input:GetKeyPress(KEY_T) then
        if input:GetKeyDown(KEY_LSHIFT) or input:GetKeyDown(KEY_RSHIFT) then
            local ready = {}
            for _, record in ipairs(self.customSettings) do
                if record.packStatus ~= "draft" then ready[#ready + 1] = record end
            end
            if #ready > 0 then
                local nextIndex = 1
                for index, record in ipairs(ready) do
                    if record.id == self.activeCustomSettingId then nextIndex = index % #ready + 1; break end
                end
                local nextTopic = ready[nextIndex]
                self:UseCustomSetting(nextTopic)
                self.themeKey = Themes.GetSetting(self.settingKey).palettes[1]
                self.editorRooms = nil; self:ApplyTheme(); self:Generate(false, false)
            end
        else
            self.themeKey = Themes.Next(self.themeKey, self.settingKey); self:ApplyTheme(); self:RebuildView(); self:RefreshPanel()
        end
    elseif input:GetKeyPress(KEY_G) then
        self.graphVisible = not self.graphVisible; self:RebuildView()
        self.panel:SetStatus("连通图 " .. (self.graphVisible and "已开启" or "已关闭"))
    elseif input:GetKeyPress(KEY_H) then
        self.heatVisible = not self.heatVisible; self:RebuildView()
        self.panel:SetStatus("难度热区 " .. (self.heatVisible and "已开启" or "已关闭"))
    elseif input:GetKeyPress(KEY_P) then
        self.postEnabled = not self.postEnabled; self.zone.bloomPlusEnabled = self.postEnabled
        self.panel:SetStatus("后处理 " .. (self.postEnabled and "已开启" or "已关闭"))
    end
    if self.forgeCamera:Update(timeStep) then self:ConfirmCameraKeyboardInput() end
end

function DungeonApp:Stop()
    if self.eventObject then self.eventObject:UnsubscribeFromAllEvents() end
    if self.editor2D then self.editor2D:Dispose() end
    if self.editor3D then self.editor3D:Dispose() end
    if self.panel then self.panel:Dispose() end
    renderer:SetViewport(0, nil)
    if self.preview then self.preview:Dispose() end
    self.preview, self.editor, self.editor2D, self.editor3D = nil, nil, nil, nil
    self.panel, self.eventObject, self.eventNode, self.scene = nil, nil, nil, nil
end

return DungeonApp
