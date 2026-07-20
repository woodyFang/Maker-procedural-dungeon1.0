local DungeonApp = require("App.DungeonApp")
local CustomizationStore = require("Config.CustomizationStore")

local SAVE_PATH = "procedural-dungeon-customization.json"
local BACKUP_PATH = ".tmp/room-group-save.original"
local RESULT_PATH = ".tmp/room-group-save.result.txt"

local function Check(condition, message)
    if not condition then error(message or "check failed", 2) end
end

local function DeleteTestSave()
    fileSystem:Delete(SAVE_PATH)
    fileSystem:Delete(SAVE_PATH .. ".bak")
    fileSystem:Delete(SAVE_PATH .. ".tmp")
end

local function WriteResult(text)
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    local file = File(RESULT_PATH, FILE_WRITE)
    if file and file:IsOpen() then
        file:WriteString(text)
        file:Dispose()
    end
end

function Start()
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    fileSystem:Delete(BACKUP_PATH)
    local hadOriginal = fileSystem:FileExists(SAVE_PATH)
    if hadOriginal then Check(fileSystem:Copy(SAVE_PATH, BACKUP_PATH), "could not back up existing save") end
    DeleteTestSave()

    local app = nil
    local ok, err = xpcall(function()
        app = DungeonApp.new()
        app:Start()

        app.panel:OpenRoomGroupModal(nil)
        app.panel.roomGroupNameField:SetValue("保存回归测试")
        app.panel.roomGroupPromptField:SetValue("")
        app.panel:SetReferenceImage("room", nil, nil)
        app.panel:ApplyRoomGroup()
        Check(#app.roomGroups == 0, "missing content should not create a room group")
        Check(app.panel.roomGroupModal:IsOpen(), "validation failure should keep the editor open")

        app.panel.roomGroupPromptField:SetValue("用于验证新增、编辑覆盖和本地持久化")
        app.panel:ApplyRoomGroup()
        Check(#app.roomGroups == 1, "valid room group was not created")
        Check(not app.panel.roomGroupModal:IsOpen(), "successful create should close the editor")
        local id = app.roomGroups[1].id

        local firstLoad = CustomizationStore.Load(SAVE_PATH)
        Check(firstLoad and #firstLoad.roomGroups == 1, "created room group was not persisted")
        Check(firstLoad.roomGroups[1].id == id, "persisted room group id changed")

        app.panel:OpenRoomGroupModal(app.roomGroups[1])
        app.panel.roomGroupNameField:SetValue("保存回归测试-已编辑")
        app.panel.roomGroupPromptField:SetValue("编辑后的提示词")
        app.panel:ApplyRoomGroup()
        Check(#app.roomGroups == 1, "editing duplicated the room group")
        Check(app.roomGroups[1].id == id, "editing changed the room group id")
        Check(app.roomGroups[1].name == "保存回归测试-已编辑", "edited name was not applied")

        local secondLoad = CustomizationStore.Load(SAVE_PATH)
        Check(secondLoad and #secondLoad.roomGroups == 1, "edited room group was not persisted")
        Check(secondLoad.roomGroups[1].name == "保存回归测试-已编辑", "persisted edit is stale")
        Check(secondLoad.roomGroups[1].prompt == "编辑后的提示词", "persisted prompt is stale")
        Check((secondLoad.revision or 0) == 2, "revision should advance for create and edit")
    end, debug.traceback)

    if app then app:Stop(); app = nil end
    DeleteTestSave()
    if hadOriginal then
        fileSystem:Copy(BACKUP_PATH, SAVE_PATH)
        fileSystem:Delete(BACKUP_PATH)
    end

    if not ok then
        WriteResult("FAIL\n" .. tostring(err))
        ErrorExit("[room-group-save-test] FAIL\n" .. tostring(err), 1)
        return
    end
    WriteResult("PASS missing validation, create save, edit overwrite, reload persistence")
    print("[room-group-save-test] PASS")
    engine:Exit()
end
