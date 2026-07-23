local EditorData = require("UI.Editor.EditorData")
local MultiFloor = require("Generation.MultiFloor")

local EditorSession = {}

local function CopyValue(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[CopyValue(key, seen)] = CopyValue(item, seen)
    end
    return result
end

local function CopyLinks(links)
    local result = {}
    for index, source in ipairs(links or {}) do
        local link = EditorData.CopyLink(source)
        link.connector = CopyValue(source.connector)
        result[index] = link
    end
    return result
end

function EditorSession.Capture(editor)
    return {
        rooms = EditorData.CopyRooms(editor and editor.rooms or {}),
        links = CopyLinks(editor and editor.links or {}),
        floor = editor and editor.floor or 0,
        floorCount = editor and editor.floorCount or 1,
        dungeonWidth = editor and editor.dungeonWidth or 1,
        dungeonHeight = editor and editor.dungeonHeight or 1,
        roomMinimumWidth = editor and editor.roomMinimumWidth or 5,
        roomMinimumHeight = editor and editor.roomMinimumHeight or 5,
        generatedOffset = CopyValue(editor and editor.generatedOffset or { x = 0, y = 0 }),
        editorWorldScale = editor and editor.editorWorldScale or 1,
        editorSwapAxes = editor and editor.editorSwapAxes == true,
        editorCenterOffset = editor and editor.editorCenterOffset ~= nil
            and editor.editorCenterOffset or 0.5,
        selected = editor and editor.selected or nil,
        selectedLink = editor and editor.selectedLink or nil,
        mode = editor and editor.mode or "select",
        linkStart = editor and editor.linkStart or nil,
        nextStairId = editor and editor.nextStairId or 1,
        stairPlacing = editor and editor.stairPlacing == true,
        stairSnapshot = CopyValue(editor and editor.stairSnapshot or nil),
        stairPlacementStyle = editor and editor.stairPlacementStyle or "l-turn",
    }
end

function EditorSession.Apply(editor, snapshot)
    if not editor or not snapshot then return false end
    editor.rooms = EditorData.CopyRooms(snapshot.rooms)
    editor.links = CopyLinks(snapshot.links)
    editor.floor = snapshot.floor or editor.floor or 0
    editor.floorCount = math.max(1, snapshot.floorCount or editor.floorCount or 1)
    editor.dungeonWidth = snapshot.dungeonWidth or editor.dungeonWidth or 1
    editor.dungeonHeight = snapshot.dungeonHeight or editor.dungeonHeight or 1
    editor.roomMinimumWidth = snapshot.roomMinimumWidth or 5
    editor.roomMinimumHeight = snapshot.roomMinimumHeight or snapshot.roomMinimumWidth or 5
    editor.generatedOffset = CopyValue(snapshot.generatedOffset or { x = 0, y = 0 })
    editor.editorWorldScale = tonumber(snapshot.editorWorldScale) or 1
    editor.editorSwapAxes = snapshot.editorSwapAxes == true
    editor.editorCenterOffset = tonumber(snapshot.editorCenterOffset)
    if editor.editorCenterOffset == nil then editor.editorCenterOffset = 0.5 end
    -- Floor height is an engine-wide metre contract. Neither the source
    -- snapshot nor stale state in the destination view may override it.
    editor.floorHeight = MultiFloor.FLOOR_HEIGHT
    editor.selected = editor.rooms[snapshot.selected] and snapshot.selected or nil
    editor.selectedLink = editor.links[snapshot.selectedLink] and snapshot.selectedLink or nil
    editor.mode = (snapshot.mode == "draw" or snapshot.mode == "connect") and snapshot.mode or "select"
    editor.linkStart = editor.rooms[snapshot.linkStart] and snapshot.linkStart or nil
    editor.nextStairId = snapshot.nextStairId or editor.nextStairId or 1
    editor.stairPlacing = snapshot.stairPlacing == true
    editor.stairSnapshot = CopyValue(snapshot.stairSnapshot)
    editor.stairPlacementStyle = snapshot.stairPlacementStyle or editor.stairPlacementStyle or "l-turn"
    editor.drag, editor.draw = nil, nil
    editor.hoveredRoom, editor.hoveredLink, editor.hoveredGizmo = nil, nil, nil
    if editor.editorInteraction then editor.editorInteraction:Reset(false) end
    if editor.contextMenu then editor.contextMenu:Close() end
    if editor.RefreshOverlay then editor:RefreshOverlay() end
    if editor.NotifySelection then editor:NotifySelection() end
    return true
end

function EditorSession.CopyLinks(links)
    return CopyLinks(links)
end

return EditorSession
