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
        generatedOffset = CopyValue(editor and editor.generatedOffset or { x = 0, y = 0 }),
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
    editor.generatedOffset = CopyValue(snapshot.generatedOffset or { x = 0, y = 0 })
    -- Keep the active theme's authoritative runtime floor height. A snapshot
    -- must not replace it with stale browser/editor data.
    editor.floorHeight = editor.floorHeight or MultiFloor.FLOOR_HEIGHT
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
