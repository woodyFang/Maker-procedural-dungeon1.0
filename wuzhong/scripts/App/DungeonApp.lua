local DungeonGenerator = require("Generation.DungeonGenerator")
local PCGDungeonGenerator = require("Generation.PCGDungeonGenerator")
local MultiFloor = require("Generation.MultiFloor")
local NativeDungeonRenderer = require("Rendering.NativeDungeonRenderer")
local PCGDungeonRenderer = require("Rendering.PCGDungeonRenderer")
local PCGDungeonMarkerPipeline = require("Generation.PCGDungeonMarkerPipeline")
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
local RoomGroupColors = require("Config.RoomGroupColors")
local DungeonGeometryLibrary = require("Rendering.DungeonGeometryLibrary")
local ProceduralMaterialRules = require("Rendering.ProceduralMaterialRules")
local LocalRequirementPlanner = require("AI.LocalRequirementPlanner")
local EditorData = require("UI.Editor.EditorData")

local DungeonApp = {}
DungeonApp.__index = DungeonApp

local CUSTOMIZATION_LOCAL_SAVE = CustomizationStore.GetLocalPath("procedural-dungeon-customization.json")
local CUSTOMIZATION_CLOUD_KEY = "procedural_dungeon_customizations_v1"
-- Match the Three editor's transaction model: pointer movement only updates
-- lightweight editor visuals, while authoritative generation is coalesced
-- after the gesture has finished.
local EDITOR_REBUILD_DEBOUNCE_SECONDS = 0.18
local PCG_DUNGEON_CELL_SIZE = 5.0
local PCG_DUNGEON_MAX_FLOORS = 6
local DEFAULT_GENERATED_FLOOR_COUNT = 2
local DEFAULT_GENERATED_ROOM_COUNT = 21
local DEFAULT_GENERATED_LOOP_RATE = 15
local DEFAULT_GENERATED_DECOR_DENSITY = 60
local TOPIC_MODE_BASE = "base"
local TOPIC_MODE_CUSTOM = "custom"
local TOPIC_MODE_FIXED_PCG = "fixedPCG"

local function ClampInteger(value, minimum, maximum, fallback)
    value = tonumber(value)
    if not value then return fallback end
    return math.max(minimum, math.min(maximum, math.floor(value + 0.5)))
end

local function NormalizeRoomCounts(source, defaults, floorCount)
    local result, total = {}, 0
    for floor = 1, floorCount do
        local fallback = defaults and (defaults[floor] or defaults[#defaults]) or 6
        result[floor] = ClampInteger(source and source[floor], 6, 50, fallback or 6)
        total = total + result[floor]
    end
    return result, total
end

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
        seed = 1337, floorCount = DEFAULT_GENERATED_FLOOR_COUNT, floorHeight = MultiFloor.FLOOR_HEIGHT,
        currentFloor = 0, floorViewMode = "neighbors",
        settingKey = "dungeon", themeKey = "ancient",
        roomCounts = { DEFAULT_GENERATED_ROOM_COUNT, DEFAULT_GENERATED_ROOM_COUNT },
        loopRates = { DEFAULT_GENERATED_LOOP_RATE, DEFAULT_GENERATED_LOOP_RATE },
        decorDensities = { DEFAULT_GENERATED_DECOR_DENSITY, DEFAULT_GENERATED_DECOR_DENSITY },
        customSettings = {}, roomGroups = {}, customPalettes = {},
        nextCustomSettingId = 1, nextRoomGroupId = 1, nextCustomPaletteId = 1,
        activeCustomSettingId = nil, customSettingName = nil, activeFixedThemeId = nil,
        topicMode = TOPIC_MODE_BASE, topicSelectionVersion = 0,
        fixedSettingSwitchInProgress = false, fixedSettingInputCooldown = 0,
        fixedSettingSceneId = nil,
        customizationRevision = 0, customizationUpdatedAt = "", cloudLoadPending = false,
        cloudSyncEnabled = false,
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
    if self.activeFixedThemeId == FixedThemes.MODE_ID or FixedThemes.Get(self.activeFixedThemeId) then
        self.topicMode = TOPIC_MODE_FIXED_PCG
        self.activeCustomSettingId, self.customSettingName = nil, nil
    elseif self.activeCustomSettingId ~= nil then
        self.topicMode = TOPIC_MODE_CUSTOM
        self.activeFixedThemeId = nil
    else
        self.topicMode = TOPIC_MODE_BASE
        self.activeCustomSettingId, self.customSettingName = nil, nil
        self.activeFixedThemeId = nil
    end
    return self.topicMode
end

function DungeonApp:MarkTopicSelectionChanged()
    self.topicSelectionVersion = (self.topicSelectionVersion or 0) + 1
end

function DungeonApp:RestoreTopicSelection(selection)
    if not selection or selection.mode == TOPIC_MODE_FIXED_PCG then
        self.topicMode = TOPIC_MODE_FIXED_PCG
        local fixedId = selection and selection.fixedId or FixedThemes.MODE_ID
        if fixedId ~= FixedThemes.MODE_ID and not FixedThemes.Get(fixedId) then
            fixedId = FixedThemes.MODE_ID
        end
        self.activeFixedThemeId = fixedId
        self.activeCustomSettingId, self.customSettingName = nil, nil
        local preset = FixedThemes.Get(self.activeFixedThemeId)
        self.settingKey, self.themeKey = preset and preset.settingKey or "dungeon",
            preset and preset.themeKey or "ancient"
        self.floorHeight = MultiFloor.NormalizeFloorHeight(preset and preset.floorHeight)
        return
    end

    self.activeFixedThemeId = nil
    if selection.mode == TOPIC_MODE_CUSTOM then
        local record = CustomizationStore.FindById(self.customSettings, selection.customId)
        if record and record.packStatus ~= "draft" then
            self.topicMode = TOPIC_MODE_CUSTOM
            self.activeCustomSettingId, self.customSettingName = record.id, record.label
            self.settingKey = Themes.settings[record.baseSettingKey] and record.baseSettingKey or "dungeon"
            self.floorHeight = MultiFloor.NormalizeFloorHeight(record.floorHeight)
            local palettes = Themes.GetSetting(self.settingKey).palettes
            self.themeKey = Themes.IsPaletteForSetting(selection.themeKey, self.settingKey)
                and selection.themeKey or palettes[1]
            return
        end
    end

    self.topicMode = TOPIC_MODE_BASE
    self.activeCustomSettingId, self.customSettingName = nil, nil
    self.settingKey = Themes.settings[selection.settingKey] and selection.settingKey or "dungeon"
    self.floorHeight = MultiFloor.FLOOR_HEIGHT
    self.themeKey = Themes.IsPaletteForSetting(selection.themeKey, self.settingKey)
        and selection.themeKey or Themes.GetSetting(self.settingKey).palettes[1]
end

function DungeonApp:ApplyCustomizationData(data, preserveTopicSelection)
    if type(data) ~= "table" then return false end
    local selection
    if preserveTopicSelection then
        self:NormalizeTopicSelection()
        selection = {
            mode = self.topicMode,
            fixedId = self.activeFixedThemeId,
            customId = self.activeCustomSettingId,
            settingKey = self.settingKey,
            themeKey = self.themeKey,
        }
    end
    local normalized = CustomizationStore.Normalize(data)
    self.customSettings = normalized.customSettings
    self.roomGroups = normalized.roomGroups
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
            self.topicMode = TOPIC_MODE_BASE
            self.activeCustomSettingId, self.customSettingName = nil, nil
            self.floorHeight = MultiFloor.FLOOR_HEIGHT
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
        local topicSelectionChanged = self.topicSelectionVersion ~= topicSelectionVersionAtStart
        if onComplete then onComplete(success, source, reason, topicSelectionChanged) end
    end

    if not self.cloudSyncEnabled then
        Finish(true, "local", "cloud sync disabled")
        return
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

    if not self.cloudSyncEnabled then
        if onComplete then onComplete(true, nil, "local") end
        return true
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
        self.panel:SetStatus(self.cloudSyncEnabled
            and (successText .. "（已保存本地；云端同步失败：" .. tostring(reason or "不可用") .. "）")
            or (successText .. "（已保存本地）"))
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
    self.pcgDungeonRenderer = PCGDungeonRenderer.new(self.scene)
    self.forgeCamera = ForgeCameraController.new(self.cameraNode, self.camera)
    print("[DungeonForge] native UrhoX viewport ready")
end

function DungeonApp:IsEmptyFixedThemeActive()
    local preset = FixedThemes.Get(self.activeFixedThemeId)
    return preset ~= nil and preset.emptyScene == true
end

function DungeonApp:IsPCGDungeonThemeActive()
    local preset = FixedThemes.Get(self.activeFixedThemeId)
    return preset ~= nil and preset.dungeonFlow == "pcgDungeon"
end

function DungeonApp:ClearInactivePCGDungeonScene()
    if self:IsPCGDungeonThemeActive() or not self.pcgDungeonRenderer then return false end
    local renderer = self.pcgDungeonRenderer
    local hasScene = renderer.root ~= nil
        or renderer.lightDebugRoot ~= nil
        or renderer.cellDebugRoot ~= nil
        or renderer.stats ~= nil
        or #(renderer.groups or {}) > 0
        or #(renderer.lights or {}) > 0
    if not hasScene then return false end
    renderer:Clear()
    self.lastPCGDungeonMarkerResult = nil
    print("[DungeonForge] cleared inactive PCG Dungeon scene")
    return true
end

function DungeonApp:IsSceneLightingEnabled()
    local preset = FixedThemes.Get(self.activeFixedThemeId)
    return not (preset and preset.lightingEnabled == false)
end

function DungeonApp:ClearSceneContent()
    self.pendingPreviewMode, self.floorViewBeforePreview = nil, nil
    renderer:SetViewport(0, nil)
    if self.preview and self.preview.ClearScene then self.preview:ClearScene() end
    if self.forgeCamera then
        self.forgeCamera.enabled = true
        self.forgeCamera:UsePerspectiveView(true)
    end
    if self.panel then
        self.panel:SetPreviewActive(false, nil)
        self.panel:SetEditorActive(false, self.editorMode)
    end
    self.editorActive, self.editorTransition, self.editorEntryMode = false, nil, nil
    self.editorDirty, self.editorRebuildPending = false, false
    self.editorRebuildAfterFrame, self.editorRebuildIdle = 0, 0
    if self.editor2D then self.editor2D:SetVisible(false) end
    if self.editor3D then self.editor3D:SetVisible(false) end
    if self.dungeonRenderer then self.dungeonRenderer:Clear() end
    if self.pcgDungeonRenderer then
        self.pcgDungeonRenderer:ClearEditorSelection()
        self.pcgDungeonRenderer:Clear()
    end
    if self.editor3D and self.editor3D.ClearOverlay then self.editor3D:ClearOverlay() end
    if self.lightGroupNode then self.lightGroupNode:Dispose() end
    self.lightGroupNode, self.zone, self.sun, self.lightPreset = nil, nil, nil, nil
    if self.scene then
        for _, child in ipairs(self.scene:GetChildren()) do
            if child ~= self.cameraNode then child:Dispose() end
        end
    end
    self.dungeon, self.editorRooms, self.editorLinks = nil, nil, nil
    self.lastValidEditorRooms, self.lastValidEditorLinks = nil, nil
    self.selectedEditorRoom, self.selectedEditorRoomGroupId = nil, nil
    print("[DungeonForge] empty fixed theme: scene, atmosphere, editor overlays, and character cleared")
end

function DungeonApp:LoadLightingPreset(settingKey)
    local fixedPreset = FixedThemes.Get(self.activeFixedThemeId)
    local environmentOnly = not self:IsSceneLightingEnabled()
        or (fixedPreset and fixedPreset.directionalLight == false)
    local localLightOnly = fixedPreset and fixedPreset.localLightOnlyEnvironment == true
    local environment = ENVIRONMENTS[settingKey] or ENVIRONMENTS.dungeon
    local preset = environmentOnly and (fixedPreset and fixedPreset.environmentPreset or environment.preset)
        or environment.preset
    local presetKey = localLightOnly and "local-point-lights"
        or (environmentOnly and (preset .. ":environment-only") or preset)
    if self.lightPreset == presetKey and self.zone then return end
    if self.lightGroupNode then self.lightGroupNode:Remove() end
    self.lightGroupNode = self.scene:CreateChild("LightGroup")
    if localLightOnly then
        self.zone = self.lightGroupNode:CreateComponent("Zone")
        self.zone.boundingBox = BoundingBox(Vector3(-1000, -1000, -1000), Vector3(1000, 1000, 1000))
        self.sun = nil
        self.lightPreset = presetKey
        print("[DungeonForge] local point-light environment (IBL and directional light disabled)")
        return
    end
    local file = cache:GetResource("XMLFile", preset)
    if file then
        self.lightGroupNode:LoadXML(file:GetRoot())
        self.zone = self.lightGroupNode:GetComponent("Zone", true)
        local loadedSun = self.lightGroupNode:GetComponent("Light", true)
        if environmentOnly then
            if loadedSun then loadedSun:Dispose() end
            self.sun = nil
            print("[DungeonForge] environment preset=" .. preset .. " (directional light removed)")
        else
            self.sun = loadedSun
            print("[DungeonForge] lighting preset=" .. preset)
        end
        self.lightPreset = presetKey
    else
        log:Write(LOG_ERROR, "[DungeonForge] missing lighting preset " .. preset)
        self.zone = self.lightGroupNode:CreateComponent("Zone")
        self.zone.boundingBox = BoundingBox(Vector3(-1000, -1000, -1000), Vector3(1000, 1000, 1000))
        self.sun = nil
        self.lightPreset = environmentOnly and "disabled" or preset
        if not environmentOnly then
            local sunNode = self.lightGroupNode:CreateChild("Sun")
            sunNode.rotation = Quaternion(52, -36, 0)
            self.sun = sunNode:CreateComponent("Light")
            self.sun.lightType = LIGHT_DIRECTIONAL
        end
    end
end

function DungeonApp:State()
    self:NormalizeTopicSelection()
    local activeFixedPreset = FixedThemes.Get(self.activeFixedThemeId)
    return {
        seed = self.seed, floorCount = self.floorCount, floorHeight = self.floorHeight,
        currentFloor = self.currentFloor,
        floorViewMode = self.floorViewMode, settingKey = self.settingKey, themeKey = self.themeKey,
        roomCounts = self.roomCounts,
        loopRates = self.loopRates, decorDensities = self.decorDensities,
        customSettings = self.customSettings, roomGroups = self.roomGroups, customPalettes = self.customPalettes,
        activeCustomSettingId = self.activeCustomSettingId, customSettingName = self.customSettingName,
        activeFixedThemeId = self.activeFixedThemeId,
        activeFixedThemeLabel = activeFixedPreset and activeFixedPreset.label or nil,
        pcgDungeonStats = self.pcgDungeonRenderer and self.pcgDungeonRenderer.stats or nil,
        lightDebugVisible = self.pcgDungeonRenderer and self.pcgDungeonRenderer.lightDebugVisible == true,
        cellDebugVisible = self.pcgDungeonRenderer and self.pcgDungeonRenderer.cellDebugVisible == true,
        topicMode = self.topicMode,
        editorActive = self.editorActive, editorMode = self.editorMode,
        selectedEditorRoom = self.selectedEditorRoom,
        selectedEditorRoomGroupId = self.selectedEditorRoomGroupId,
        valid = self.dungeon == nil or self.dungeon.valid,
    }
end

function DungeonApp:ActiveRoomGroups()
    if not self.activeCustomSettingId then return {} end
    return LocalRequirementPlanner.GroupsForTopic(self.roomGroups, self.activeCustomSettingId)
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

-- Fixed presets own their layout controls (for example, Shadow Castle uses
-- three floors and a 8/7/7 room split). Once the user returns to an AI/base
-- generated scene, restore the generic controls before the next generation so
-- the scene and the left panel describe the same parameter set.
function DungeonApp:ResetGeneratedSceneParameters()
    self.floorCount = DEFAULT_GENERATED_FLOOR_COUNT
    self.currentFloor = 0
    self.roomCounts = { DEFAULT_GENERATED_ROOM_COUNT, DEFAULT_GENERATED_ROOM_COUNT }
    self.loopRates = { DEFAULT_GENERATED_LOOP_RATE, DEFAULT_GENERATED_LOOP_RATE }
    self.decorDensities = { DEFAULT_GENERATED_DECOR_DENSITY, DEFAULT_GENERATED_DECOR_DENSITY }
end

function DungeonApp:IsFixedTopicActive()
    return self.activeFixedThemeId ~= nil or self.topicMode == TOPIC_MODE_FIXED_PCG
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
        onFixedSetting = function(id)
            local preset = FixedThemes.Get(id)
            if not preset then return false, "固定题材不存在" end
            if self.activeFixedThemeId == preset.id and self.fixedSettingSceneId == preset.id then
                return true
            end
            if self.fixedSettingSwitchInProgress or (self.fixedSettingInputCooldown or 0) > 0 then
                return true
            end
            local previousPreset = FixedThemes.Get(self.activeFixedThemeId)
            self.fixedSettingSwitchInProgress = true
            self:MarkTopicSelectionChanged()
            self.topicMode = TOPIC_MODE_FIXED_PCG
            self.activeFixedThemeId = preset.id
            self.activeCustomSettingId, self.customSettingName = nil, nil
            self.settingKey, self.themeKey = preset.settingKey, preset.themeKey
            self.floorCount = ClampInteger(preset.floorCount, 1, PCG_DUNGEON_MAX_FLOORS, self.floorCount)
            self.currentFloor = math.min(self.currentFloor, self.floorCount - 1)
            self.floorHeight = MultiFloor.NormalizeFloorHeight(preset.floorHeight)
            self.roomCounts, self.loopRates, self.decorDensities = {}, {}, {}
            if preset.id == "shadowCastle" then
                self.seed = ClampInteger(preset.seed, 0, 0xffffffff, self.seed)
                self.roomCounts = NormalizeRoomCounts(preset.roomCounts, preset.roomCounts, self.floorCount)
            end
            for floor = 1, self.floorCount do
                self.roomCounts[floor] = self.roomCounts[floor] or preset.roomCount
                self.loopRates[floor] = preset.loopRate
                self.decorDensities[floor] = preset.decorDensity
            end
            self.editorRooms = nil
            local switched, switchReason = true, nil
            if preset.dungeonFlow == "pcgDungeon" then
                switched, switchReason = self:RefreshPCGDungeon(true)
            elseif preset.emptyScene then
                self:ClearSceneContent()
                self:RefreshPanel()
            else
                if previousPreset and previousPreset.dungeonFlow then
                    self:ClearSceneContent()
                end
                self:ApplyTheme()
                self:Generate(false, false)
            end
            self.fixedSettingSwitchInProgress = false
            self.fixedSettingInputCooldown = 0.25
            if not switched then return false, switchReason end
            self.fixedSettingSceneId = preset.id
            if self.panel and preset.dungeonFlow ~= "pcgDungeon" then
                self.panel:SetStatus(preset.emptyScene
                    and ("固定题材“" .. preset.label .. "”已切换为空场景")
                    or ("固定题材“" .. preset.label .. "”已按 PCG 规则生成"))
            end
            return true
        end,
        onPCGDungeonRefresh = function(parameters)
            if not self:IsPCGDungeonThemeActive() then return false, "请先选择暗影古堡。" end
            return self:RefreshPCGDungeon(true, parameters)
        end,
        onPCGDungeonLightDebug = function()
            if not self:IsPCGDungeonThemeActive() then return nil, "请先选择暗影古堡。" end
            local enabled, count = self.pcgDungeonRenderer:ToggleLightDebug()
            self:RefreshPanel()
            return enabled, count
        end,
        onPCGDungeonCellDebug = function()
            if not self:IsPCGDungeonThemeActive() then return nil, "请先选择暗影古堡。" end
            local enabled, statsOrReason = self.pcgDungeonRenderer:ToggleCellDebug()
            renderer:SetViewport(0, nil)
            renderer:SetViewport(0, self.overviewViewport)
            self:RefreshPanel()
            return enabled, statsOrReason
        end,
        onMarkerFlow = function()
            return self:RunMarkerFlowValidation()
        end,
        onFixedPCG = function()
            -- The fixed PCG mode button is the public entry point for the
            -- authored castle flow. Keep it on the same callback as the
            -- preset so initialization, resource preload, marker generation,
            -- and scene rebuild cannot diverge between the two controls.
            local onFixedSetting = self.panel and self.panel.callbacks
                and self.panel.callbacks.onFixedSetting
            if not onFixedSetting then return false, "固定题材生成回调尚未初始化" end
            return onFixedSetting("shadowCastle")
        end,
        onSetting = function(key)
            self:MarkTopicSelectionChanged()
            self.topicMode = TOPIC_MODE_BASE
            local wasFixedTopic = self:IsFixedTopicActive()
            local previousPreset = FixedThemes.Get(self.activeFixedThemeId)
            local oldId, oldName, oldSetting, oldTheme =
                self.activeCustomSettingId, self.customSettingName, self.settingKey, self.themeKey
            local oldFloorHeight = self.floorHeight
            self.activeCustomSettingId, self.customSettingName = nil, nil
            self.activeFixedThemeId = nil
            self.floorHeight = MultiFloor.FLOOR_HEIGHT
            self.settingKey = key; self.themeKey = Themes.GetSetting(key).palettes[1]
            if oldId then
                self.customizationRevision = self.customizationRevision + 1
                local saved, reason = self:SaveCustomizations(function(success, detail, target)
                    self:ReportCustomizationSave(success, "当前题材已更新", detail, target)
                end)
                if not saved then
                    self.activeCustomSettingId, self.customSettingName = oldId, oldName
                    self.settingKey, self.themeKey = oldSetting, oldTheme
                    self.floorHeight = oldFloorHeight
                    self.customizationRevision = self.customizationRevision - 1
                    return self.panel:SetStatus("题材切换未保存：" .. tostring(reason))
                end
            end
            if previousPreset and previousPreset.dungeonFlow then
                self:ClearSceneContent()
                self.fixedSettingSceneId = nil
            end
            if wasFixedTopic then self:ResetGeneratedSceneParameters() end
            self.editorRooms = nil; self:ApplyTheme(); self:Generate(false, false)
        end,
        onRandomSetting = function()
            self:MarkTopicSelectionChanged()
            self.topicMode = TOPIC_MODE_BASE
            local wasFixedTopic = self:IsFixedTopicActive()
            local previousPreset = FixedThemes.Get(self.activeFixedThemeId)
            local oldId, oldName, oldSetting, oldTheme =
                self.activeCustomSettingId, self.customSettingName, self.settingKey, self.themeKey
            local oldFloorHeight = self.floorHeight
            local hadCustom = self.activeCustomSettingId ~= nil
            self.activeCustomSettingId, self.customSettingName = nil, nil
            self.activeFixedThemeId = nil
            self.floorHeight = MultiFloor.FLOOR_HEIGHT
            self.settingKey = Themes.NextSetting(self.settingKey)
            self.themeKey = Themes.RandomPalette(self.settingKey)
            if hadCustom then
                self.customizationRevision = self.customizationRevision + 1
                local saved = self:SaveCustomizations()
                if not saved then
                    self.activeCustomSettingId, self.customSettingName = oldId, oldName
                    self.settingKey, self.themeKey = oldSetting, oldTheme
                    self.floorHeight = oldFloorHeight
                    self.customizationRevision = self.customizationRevision - 1
                    return self.panel:SetStatus("随机题材切换未保存")
                end
            end
            if previousPreset and previousPreset.dungeonFlow then
                self:ClearSceneContent()
                self.fixedSettingSceneId = nil
            end
            if wasFixedTopic then self:ResetGeneratedSceneParameters() end
            self.editorRooms = nil; self:ApplyTheme(); self:Generate(false, false)
        end,
        onCustomSettingSave = function(custom, mode)
            mode = mode == "draft" and "draft" or "generate"
            local wasFixedTopic = self:IsFixedTopicActive()
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
            local _, replaced = CustomizationStore.UpsertById(self.customSettings, prepared)
            self.customizationRevision = self.customizationRevision + 1
            if mode == "generate" then
                self:UseCustomSetting(prepared)
            elseif self.activeCustomSettingId == prepared.id then
                self:MarkTopicSelectionChanged()
                self.topicMode = TOPIC_MODE_BASE
                self.activeCustomSettingId, self.customSettingName = nil, nil
                self.floorHeight = MultiFloor.FLOOR_HEIGHT
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
            if wasFixedTopic then self:ResetGeneratedSceneParameters() end
            self:ApplyTheme(); self:Generate(false, false)
            if prepared.generationMode == GenericThemeRules.GENERATION_MODE then
                self.panel:SetStatus(string.format(
                    "题材“%s”已使用通用规则生成基础预览；AI 3D 资产接口待接入", prepared.label))
            else
                self.panel:SetStatus(string.format("题材包“%s”已生成 %d 个房间组并执行预览",
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
            local wasFixedTopic = self:IsFixedTopicActive()
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
            if wasFixedTopic then self:ResetGeneratedSceneParameters() end
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
            if wasActive then
                self:MarkTopicSelectionChanged()
                self.activeCustomSettingId, self.customSettingName = nil, nil
                self.topicMode = TOPIC_MODE_BASE
                self.floorHeight = MultiFloor.FLOOR_HEIGHT
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
            if self.activeCustomSettingId and self.settingKey ~= oldSetting then
                self:MarkTopicSelectionChanged()
                self.topicMode = TOPIC_MODE_BASE
                self.activeCustomSettingId, self.customSettingName = nil, nil
                self.floorHeight = MultiFloor.FLOOR_HEIGHT
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
                self:MarkTopicSelectionChanged()
                self.topicMode = TOPIC_MODE_BASE
                self.activeFixedThemeId = nil
            end
            self.themeKey = key; self:ApplyTheme(); self:RebuildView(); self:RefreshPanel(); return true
        end,
        onRandomTheme = function()
            if self.activeFixedThemeId == FixedThemes.MODE_ID then
                self:MarkTopicSelectionChanged()
                self.topicMode = TOPIC_MODE_BASE
                self.activeFixedThemeId = nil
            end
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
                for _, field in ipairs({ "topicId", "plannerSource", "compiledFromRevision", "compiledSpecVersion",
                    "sortOrder", "roleKeys", "defaultGroup", "minCount", "maxCount", "minArea", "maxArea",
                    "propRules", "color" }) do
                    if group[field] == nil then group[field] = previous[field] end
                end
                group.source, group.locked = "manual", true
            else
                group.topicId = group.topicId or self.activeCustomSettingId
                group.source, group.locked = "manual", true
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
                    string.format("房间组“%s”已保存", prepared.name), detail, target)
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
            local deleted = CustomizationStore.DeleteById(self.roomGroups, id)
            if not deleted then return false, "房间组不存在。" end
            self.customizationRevision = self.customizationRevision + 1
            self:RefreshPanel()
            local saved, reason = self:SaveCustomizations(function(success, detail, target)
                self:ReportCustomizationSave(success, "房间组已删除", detail, target)
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
            if groupId and not CustomizationStore.FindById(self.roomGroups, groupId) then
                return false, "房间组不存在或已被删除。"
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
        onAddFloorAfter = function() self:AddFloor(self.currentFloor + 2) end,
        onAddFloorTop = function() self:AddFloor(self.floorCount + 1) end,
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
            if EditorData.HasPendingConnections(rooms) then
                -- Keep newly drawn rooms in the editor until they join the
                -- authored graph; rebuilding a disconnected graph would roll
                -- the canvas back to the last generated dungeon.
                self.editorDirty, self.editorRebuildPending = false, false
                self.editorRebuildAfterFrame, self.editorRebuildIdle = 0, 0
                if self.panel then
                    self.panel:SetStatus("新房间已保留在画布中；连接到现有房间后更新场景")
                end
                return
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
            if self:IsPCGDungeonThemeActive() then
                self.dungeonRenderer:ClearEditorSelection()
                self.pcgDungeonRenderer:SetEditorSelection(self.dungeon, index)
            elseif mode == "2d" then
                self.pcgDungeonRenderer:ClearEditorSelection()
                self.dungeonRenderer:SetEditorSelection(self.dungeon, index, linkIndex, link)
            else
                self.dungeonRenderer:ClearEditorSelection()
                self.pcgDungeonRenderer:ClearEditorSelection()
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
        onInteract = function(position, forward)
            if not self:IsPCGDungeonThemeActive() then return false end
            return self.pcgDungeonRenderer:InteractNearestDoor(position, forward)
        end,
    })
    self.eventObject:SubscribeToEvent("Update", function(_, _, eventData) self:HandleUpdate(eventData:GetFloat("TimeStep")) end)
    self:Generate(false, true)
    if self.cloudSyncEnabled then
        self.panel:SetStatus("正在读取云端题材…")
        self:LoadCloudCustomizations(function(success, source, reason, topicSelectionChanged)
            if success and not topicSelectionChanged
                and (source == "cloud" or source == "local-synced") then
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
    else
        self:RefreshPanel()
        self.panel:SetStatus("本地离线模式：题材仅保存在此设备")
        print("[DungeonForge] offline mode enabled; cloud customization sync skipped")
    end
end

function DungeonApp:ApplyTheme()
    if self:IsEmptyFixedThemeActive() then
        self:ClearSceneContent()
        return
    end
    renderer:SetViewport(0, self.overviewViewport)
    local theme = Themes.Get(self.themeKey)
    local fixedPreset = FixedThemes.Get(self.activeFixedThemeId)
    if self.pcgDungeonRenderer then
        self.pcgDungeonRenderer:SetLightingEnabled(self:IsSceneLightingEnabled())
    end
    self:LoadLightingPreset(self.settingKey)
    self.zone.fogColor = HexColor(theme.fog, 1.0)
    self.zone.fogStart, self.zone.fogEnd = 0, 1000
    self.zone.fogDensity = theme.fogDensity
    local preserveEnvironmentLighting = fixedPreset
        and fixedPreset.preserveEnvironmentLighting == true
    if preserveEnvironmentLighting then
        if fixedPreset.environmentIntensity ~= nil then
            self.zone.ambientIntensity = fixedPreset.environmentIntensity
        end
    else
        self.zone.ambientSource = AMBIENT_COLOR
        local ambientGradient = true
        if fixedPreset and fixedPreset.ambientGradient ~= nil then
            ambientGradient = fixedPreset.ambientGradient
        end
        self.zone.ambientGradient = ambientGradient
        self.zone.ambientStartColor = HexColor(theme.sky, 1.0)
        self.zone.ambientEndColor = HexColor(theme.ground, 1.0)
        self.zone.ambientColor = HexColor(
            fixedPreset and fixedPreset.ambientColor or theme.sky, 1.0)
        self.zone.ambientIntensity = fixedPreset and fixedPreset.ambientIntensity ~= nil
            and fixedPreset.ambientIntensity or theme.ambient
    end
    self.zone.autoExposureEnabled = false
    self.zone.bloomPlusEnabled = self.postEnabled
    if not self:IsSceneLightingEnabled() or (fixedPreset and fixedPreset.directionalLight == false) then
        if self.sun then self.sun:Dispose(); self.sun = nil end
        print("[DungeonForge] fixed scene directional light removed id="
            .. tostring(fixedPreset and fixedPreset.id or "lighting-disabled"))
    else
        self.sun.color = HexColor(theme.sun, 1.0)
        self.sun.brightness = theme.sunIntensity
        self.sun.castShadows = true
        self.sun.shadowBias = BiasParameters(0.00025, 0.5)
        self.sun.shadowCascade = CascadeParameters(12.0, 45.0, 140.0, 0.0, 0.8)
    end
end

function DungeonApp:ApplyPCGDungeonParameters(parameters)
    parameters = parameters or {}
    local preset = FixedThemes.Get("shadowCastle")
    self.seed = ClampInteger(parameters.seed, 0, 0xffffffff, self.seed)
    self.floorCount = ClampInteger(parameters.floorCount, 1, PCG_DUNGEON_MAX_FLOORS,
        self.floorCount or preset.floorCount or 3)
    self.currentFloor = math.min(self.currentFloor, self.floorCount - 1)
    local normalizedRoomCounts, roomCount = NormalizeRoomCounts(
        parameters.roomCountsByFloor or self.roomCounts, preset.roomCounts, self.floorCount)
    self.roomCounts = normalizedRoomCounts
    local loopRatesByFloor, decorDensitiesByFloor = {}, {}
    for floor = 1, self.floorCount do
        self.loopRates[floor] = self.loopRates[floor] or preset.loopRate
        self.decorDensities[floor] = self.decorDensities[floor] or preset.decorDensity
        loopRatesByFloor[floor] = math.max(0, math.min(1,
            (tonumber(self.loopRates[floor]) or preset.loopRate or 0) / 100))
        decorDensitiesByFloor[floor] = math.max(0, math.min(1,
            (tonumber(self.decorDensities[floor]) or preset.decorDensity or 0) / 100))
    end
    for floor = #self.loopRates, self.floorCount + 1, -1 do self.loopRates[floor] = nil end
    for floor = #self.decorDensities, self.floorCount + 1, -1 do self.decorDensities[floor] = nil end
    return {
        seed = self.seed,
        floorCount = self.floorCount,
        roomCount = roomCount,
        roomCountsByFloor = self.roomCounts,
        loopRatesByFloor = loopRatesByFloor,
        decorDensitiesByFloor = decorDensitiesByFloor,
    }
end

function DungeonApp:RefreshPCGDungeon(frameCamera, parameters, useEditor)
    if not self:IsPCGDungeonThemeActive() then return false, "暗影古堡未激活" end
    local preloadOk, preloadResult = self.pcgDungeonRenderer:PreloadResources()
    if not preloadOk then
        local reason = "暗影古堡资源加载失败：" .. tostring(preloadResult)
        if self.panel then self.panel:SetStatus(reason) end
        log:Write(LOG_ERROR, "[DungeonForge] " .. reason)
        return false, reason
    end
    useEditor = useEditor == true
    self.generationSerial = self.generationSerial + 1
    print(string.format("[DungeonForge] PCG generate #%d seed=%u floors=%d editor=%s",
        self.generationSerial, self.seed & 0xffffffff, self.floorCount, tostring(useEditor)))
    local applied = self:ApplyPCGDungeonParameters(parameters)
    local started = os.clock()
    local topologyStarted = os.clock()
    local previousLayout = self.dungeon and self.dungeon.layout or nil
    local dungeon = PCGDungeonGenerator.Generate({
        seed = applied.seed,
        floorCount = applied.floorCount,
        roomCountsByFloor = applied.roomCountsByFloor,
        loopRatesByFloor = applied.loopRatesByFloor,
        cellSize = PCG_DUNGEON_CELL_SIZE,
        editorEnabled = useEditor,
        editorRooms = useEditor and self.editorRooms or nil,
        editorEdges = useEditor and self.editorLinks or nil,
        editorGridCells = useEditor and previousLayout
            and (previousLayout.editorGridCells or previousLayout.gridCells) or nil,
    })
    local topologyMs = (os.clock() - topologyStarted) * 1000
    if not dungeon.valid then
        local reason = dungeon.error or "PCG Dungeon 生成了无效布局"
        if self.panel then self.panel:SetStatus("暗影古堡刷新失败：" .. tostring(reason)) end
        return false, reason
    end
    self.seed = dungeon.requestedSeed or self.seed
    applied.seed = self.seed
    local markerStarted = os.clock()
    local markerResult = PCGDungeonMarkerPipeline.GenerateFromTopology(dungeon.topology, {
        cellSize = PCG_DUNGEON_CELL_SIZE,
        pillarPlacementDistance = 1.2,
    })
    local markerMs = (os.clock() - markerStarted) * 1000
    if markerResult.stairTopologyValid == false then
        local reason = "stair topology invalid: "
            .. table.concat(markerResult.stairTopologyErrors or {}, "; ")
        if self.panel then self.panel:SetStatus("暗影古堡刷新失败：" .. reason) end
        log:Write(LOG_ERROR, "[PCGDungeon] " .. reason)
        return false, reason
    end
    if useEditor then
        self.dungeonRenderer:Clear()
    else
        self:ClearSceneContent()
    end
    self:ApplyTheme()
    local buildStarted = os.clock()
    local ok, result = self.pcgDungeonRenderer:RebuildFromMarkers(markerResult, {
        rooms = dungeon.rooms,
        cells = dungeon.topology.cells,
        cellSize = PCG_DUNGEON_CELL_SIZE,
        decorDensitiesByFloor = applied.decorDensitiesByFloor,
    }, {
        currentFloor = self.currentFloor,
        viewMode = self.floorViewMode,
        floorHeight = self.floorHeight,
    })
    local sceneBuildMs = (os.clock() - buildStarted) * 1000
    if not ok then
        if self.panel then self.panel:SetStatus("暗影古堡刷新失败：" .. tostring(result)) end
        log:Write(LOG_ERROR, "[PCGDungeon] refresh failed: " .. tostring(result))
        return false, result
    end
    result.generationMs = (os.clock() - started) * 1000
    result.topologyMs, result.markerMs, result.sceneBuildMs = topologyMs, markerMs, sceneBuildMs
    result.seed, result.floorCount, result.roomCount = applied.seed, applied.floorCount, dungeon.roomCount
    result.stairCount = dungeon.astar.stairCount
    result.delaunayEdgeCount = #dungeon.delaunay.edges
    result.mstEdgeCount = #dungeon.graph.mstEdges
    result.loopEdgeCount = #dungeon.graph.loopEdges
    result.dungeonHash = dungeon.hash
    self.dungeon = dungeon
    if not useEditor then self.editorRooms, self.editorLinks = nil, nil end
    self.roomCounts = {}
    for floor = 1, self.floorCount do
        self.roomCounts[floor] = dungeon.roomCountsByFloor[floor] or 0
    end
    self.lastPCGDungeonMarkerResult = markerResult
    if self.editor2D then self.editor2D:SyncDungeon(dungeon, self.currentFloor, self:ActiveRoomGroups()) end
    if self.editor3D then self.editor3D:SyncDungeon(dungeon, self.currentFloor, self:ActiveRoomGroups()) end
    if self.editor then
        local editorShouldBeVisible = self.editorActive and not self.editorTransition
        if self.editor:IsVisible() ~= editorShouldBeVisible then
            self.editor:SetVisible(editorShouldBeVisible)
        end
    end
    print(string.format(
        "[PCGDungeon] ready topologyMs=%.1f markerMs=%.1f sceneBuildMs=%.1f totalMs=%.1f",
        topologyMs, markerMs, sceneBuildMs, result.generationMs))
    if frameCamera ~= false and self.forgeCamera then
        self.forgeCamera.defaultTarget = Vector3(0, (self.floorCount - 1) * PCG_DUNGEON_CELL_SIZE * 0.5, 0)
        local sceneInfo = dungeon.sceneInfo or {}
        local worldSpan = math.max(sceneInfo.worldWidth or dungeon.width * PCG_DUNGEON_CELL_SIZE,
            sceneInfo.worldDepth or dungeon.height * PCG_DUNGEON_CELL_SIZE)
        self.forgeCamera.defaultDistance = math.max(80,
            worldSpan * 1.18 / (2 * math.tan(math.rad(45) * 0.5)))
        self.forgeCamera:Reset()
    end
    if self.panel then
        if self.panel.SetPCGDungeonStats then self.panel:SetPCGDungeonStats(result) end
        self.panel:SetStatus(string.format(
            "暗影古堡已刷新：%d 层，%d 个总房间，%d 个回环，%d 组楼梯，%d 个 Marker，种子 %u",
            applied.floorCount, dungeon.roomCount, result.loopEdgeCount or 0, result.stairCount or 0,
            result.markerCount or 0, applied.seed))
    end
    self:RefreshPanel()
    return true, result
end

function DungeonApp:RunMarkerFlowValidation()
    local started = os.clock()
    local valid, report = PCGDungeonMarkerPipeline.RunReferenceValidation()
    report = report or { errors = { "Marker 流程验证没有返回报告" } }
    report.elapsedMs = (os.clock() - started) * 1000
    if not valid then
        local reason = table.concat(report.errors or { "未知错误" }, "; ")
        if self.panel then self.panel:SetStatus("Marker 流程失败：" .. reason) end
        log:Write(LOG_ERROR, "[PCGDungeonMarkerFlow] " .. reason)
        return false, reason
    end

    self.lastPCGDungeonMarkerResult = report.result
    if self.panel then
        if self.panel.SetMarkerFlowStats then self.panel:SetMarkerFlowStats(report) end
        self.panel:SetStatus(string.format(
            "Marker 流程通过：%d 类 Marker，%d 点，%d 面（%.1f ms）",
            report.markerTypeCount or 0, report.markerCount or 0,
            report.faceCount or 0, report.elapsedMs))
    end
    print(string.format(
        "[PCGDungeonMarkerFlow] PASS fixture=%s markers=%d faces=%d types=%d time=%.1fms",
        tostring(report.fixturePath), report.markerCount or 0, report.faceCount or 0,
        report.markerTypeCount or 0, report.elapsedMs))
    return true, report
end

function DungeonApp:RebuildView(animate)
    if self:IsPCGDungeonThemeActive() then
        if not self.pcgDungeonRenderer or not self.pcgDungeonRenderer.cachedBuild then return end
        local ok, reason = self.pcgDungeonRenderer:RebuildView({
            currentFloor = self.currentFloor,
            viewMode = self.floorViewMode,
            floorHeight = self.floorHeight,
        })
        if not ok then
            local message = "固定 PCG 三维显示范围更新失败：" .. tostring(reason)
            if self.panel then self.panel:SetStatus(message) end
            log:Write(LOG_ERROR, "[DungeonForge] " .. message)
        end
        return
    end
    self:ClearInactivePCGDungeonScene()
    if self:IsEmptyFixedThemeActive() then
        self:ClearSceneContent()
        return
    end
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
    if self:IsPCGDungeonThemeActive() then
        local ok = self:RefreshPCGDungeon(frameCamera ~= false, nil, useEditor == true)
        return ok == true
    end
    self:ClearInactivePCGDungeonScene()
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
    if self.floorCount >= 6 then self.panel:SetStatus("最多支持 6 层"); return end
    local source = math.max(1, math.min(self.floorCount, self.currentFloor + 1))
    table.insert(self.roomCounts, luaIndex, self.roomCounts[source] or 21)
    table.insert(self.loopRates, luaIndex, self.loopRates[source] or 15)
    table.insert(self.decorDensities, luaIndex, self.decorDensities[source] or 60)
    self.floorCount = self.floorCount + 1; self.currentFloor = luaIndex - 1
    self.editorRooms = nil; self:Generate(false, true)
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
        self.pcgDungeonRenderer:ClearEditorSelection()
        if self.editorDirty then
            self.editorDirty = false
            self.editorRebuildPending = false
            self.editorRebuildAfterFrame = 0
            self.editorRebuildIdle = 0
            self:GenerateEditorWithRollback(false)
        end
        -- A final rebuild can restore selection while synchronizing editors.
        self.dungeonRenderer:ClearEditorSelection()
        self.pcgDungeonRenderer:ClearEditorSelection()
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
    if not self.preview then return end
    local cameraOnly = self:IsPCGDungeonThemeActive()
    if not cameraOnly and not self.dungeon then return end
    if self.forgeCamera:IsTransitioning() then return end
    if self.editorActive then
        self.pendingPreviewMode = mode or "third"
        self:ToggleEditor(false)
        return
    end
    if cameraOnly then
        if not self.preview:IsActive() then self.floorViewBeforePreview = self.floorViewMode end
        self.forgeCamera.enabled = false
        self.preview:ActivateCameraOnly(self.pcgDungeonRenderer:GetPreviewStart())
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
    self.fixedSettingInputCooldown = math.max(0, (self.fixedSettingInputCooldown or 0) - timeStep)
    self.dungeonRenderer:Update(timeStep)
    self.pcgDungeonRenderer:Update(timeStep)
    if self.preview and self.preview:IsActive() then self.preview:Update(timeStep); return end
    if input:GetKeyPress(KEY_E) then self:ToggleEditorMode("3d") end
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
            self:MarkTopicSelectionChanged()
            self.topicMode = TOPIC_MODE_BASE
            self.activeCustomSettingId, self.customSettingName = nil, nil
            self.activeFixedThemeId = nil
            self.floorHeight = MultiFloor.FLOOR_HEIGHT
            self.settingKey = Themes.NextSetting(self.settingKey); self.themeKey = Themes.GetSetting(self.settingKey).palettes[1]
            self.editorRooms = nil; self:ApplyTheme(); self:Generate(false, false)
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
        self.postEnabled = not self.postEnabled
        if self.zone then self.zone.bloomPlusEnabled = self.postEnabled end
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
    if self.pcgDungeonRenderer then self.pcgDungeonRenderer:Dispose() end
    self.preview, self.editor, self.editor2D, self.editor3D = nil, nil, nil, nil
    self.panel, self.eventObject, self.eventNode, self.scene = nil, nil, nil, nil
end

return DungeonApp
