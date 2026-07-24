local RouteEditing = require("UI.Editor.RouteEditing")
local StairEditing = require("UI.Editor.StairEditing")
local EditorData = require("UI.Editor.EditorData")
local RoomEditing = require("UI.Editor.RoomEditing")

local EditorGesture = {}

local Snap = RouteEditing.Snap
local CopyPoint = RouteEditing.CopyPoint
local function Clamp(value, low, high) return math.max(low, math.min(high, value)) end

function EditorGesture.Apply(editor, gridX, gridY)
    local drag = editor.drag
    if not drag then return false end
    local changed = false
    if drag.kind == "roomMove" then
        local room = editor.rooms[drag.index]
        local nextX, nextY = RoomEditing.Move(drag.start,
            { x = drag.startX, y = drag.startY }, { x = gridX, y = gridY })
        changed = room.cx ~= nextX or room.cy ~= nextY
        if changed then
            room.cx, room.cy = nextX, nextY
            editor:UpdateRoomStairEdit(drag.stairEdit,
                room.cx - drag.start.cx, room.cy - drag.start.cy, false)
        end
    elseif drag.kind == "roomResize" then
        local room = editor.rooms[drag.index]
        local oldX, oldY, oldW, oldH = room.cx, room.cy, room.w, room.h
        editor:ResizeRoom(room, drag.start, gridX, gridY, drag.mode)
        changed = oldX ~= room.cx or oldY ~= room.cy or oldW ~= room.w or oldH ~= room.h
        if changed then editor:UpdateRoomStairEdit(drag.stairEdit, 0, 0, true) end
    elseif drag.kind == "linkDoor" then
        local link = editor.links[drag.link]
        local room = editor.rooms[drag.which == "a" and link.a or link.b]
        local previous = drag.which == "a" and link.doorA or link.doorB
        local nextSpec = editor:PointToDoorSpec(room, { x = gridX, y = gridY })
        changed = not previous or previous.side ~= nextSpec.side
            or math.abs((previous.offset or 0) - (nextSpec.offset or 0)) > 0.0001
        if changed then
            if drag.which == "a" then link.doorA = nextSpec else link.doorB = nextSpec end
            link.autoRoute, link.isManual = {}, true
        end
    elseif drag.kind == "linkBend" then
        local link = editor.links[drag.link]
        local bend = link.bends and link.bends[drag.bendIndex]
        if bend then
            local snapped = editor:SnapControlPoint({ x = gridX, y = gridY }, link, { bend })
            changed = bend.x ~= snapped.x or bend.y ~= snapped.y
            if changed then bend.x, bend.y = snapped.x, snapped.y; link.autoRoute, link.isManual = {}, true end
        end
    elseif drag.kind == "linkSegment" then
        local sx, sy = Snap(gridX), Snap(gridY)
        if drag.pending then
            local startX, startY = Snap(drag.startX), Snap(drag.startY)
            if sx == startX and sy == startY then return false end
            local link = editor.links[drag.link]
            local route = editor:EnsureEditableRoute(link)
            local movedPoints = { route[drag.segment], route[drag.segment + 1] }
            drag.route = route
            drag.snapTargets = editor:ControlSnapTargets(movedPoints)
            drag.lastGridX, drag.lastGridY = startX, startY
            drag.pending = false
        end
        changed = drag.lastGridX ~= sx or drag.lastGridY ~= sy
        if changed then
            drag.lastGridX, drag.lastGridY = sx, sy
            editor:MoveLinkSegment(editor.links[drag.link], drag, gridX, gridY)
        end
    elseif drag.kind == "stairMove" then
        local dx, dy = Snap(gridX - drag.startX), Snap(gridY - drag.startY)
        changed = dx ~= drag.lastDX or dy ~= drag.lastDY
        if changed then
            drag.lastDX, drag.lastDY = dx, dy
            local spec = drag.stair.spec
            editor:UpdateStairDrag(drag.stair, {
                anchor = { x = drag.anchor.x + dx, y = drag.anchor.y + dy },
                direction = spec.previewDirection or spec.direction,
                length = spec.previewLength or spec.length,
                style = spec.previewStyle or spec.style,
            })
        end
    elseif drag.kind == "stairRotate" then
        local placement = StairEditing.RotationFromPointer(
            drag.stair.spec, drag.stair.connector, { x = gridX, y = gridY }, drag.lastDirection)
        changed = placement and placement.direction ~= drag.appliedDirection
        if changed then
            drag.lastDirection = placement.direction
            drag.appliedDirection = placement.direction
            editor:UpdateStairDrag(drag.stair, placement)
        end
    elseif drag.kind == "stairWidth" then
        -- One-side-fixed resize: keep the far edge fixed, compensate with offset.
        local resize = StairEditing.WidthResizeFromPointer(
            drag.stair.spec, drag.stair.connector, { x = gridX, y = gridY })
        local spec = drag.stair.spec
        changed = resize and math.abs(resize.width - (drag.lastWidth or 0)) > 0.0001
        if changed then
            drag.lastWidth = resize.width
            editor:UpdateStairDrag(drag.stair, {
                anchor = CopyPoint(spec.previewAnchor or spec.anchor or drag.stair.connector.lower),
                direction = spec.previewDirection or spec.direction,
                length = spec.previewLength or spec.length,
                style = spec.previewStyle or spec.style,
            }, resize.width, resize.lateralCenterOffset)
        end
    end
    if changed and (drag.kind == "roomMove" or drag.kind == "roomResize") then
        editor:ApplyAdaptiveRoutes(drag.adaptive)
        editor:UpdateRoomVisual(drag.index)
        local pair = drag.stairEdit and drag.stairEdit.pair
        if pair then editor:UpdateRoomVisual(pair) end
    end
    if changed then
        drag.changed = true
        -- Room/path/stair visuals are updated locally above. Do not publish a
        -- copied editor model or regenerate the dungeon while the pointer is
        -- captured; Commit on release is the authoritative transaction.
    end
    return changed == true
end

function EditorGesture.UpdateDraw(editor, gridX, gridY)
    if not editor.draw then return false end
    editor.draw.ex, editor.draw.ey = gridX, gridY
    editor:UpdateDrawPreview()
    return true
end

function EditorGesture.Finish(editor, mousePosition)
    editor.editorInteraction:Release()
    if editor.drag then
        local finished = editor.drag
        editor.drag = nil
        if finished.kind == "linkSegment" and finished.pending then
            editor:RefreshOverlay()
            return true
        end
        if finished.kind == "linkDoor" and mousePosition then
            local world = editor:ScreenToFloor(mousePosition)
            if world then
                local target = editor:HitRoom(world)
                local link = editor.links[finished.link]
                if target and link then
                    local other = finished.which == "a" and link.b or link.a
                    if target ~= other and target ~= (finished.which == "a" and link.a or link.b) then
                        local duplicate = EditorData.FindLink(editor.links, target, other, finished.link)
                        if duplicate then
                            if finished.which == "a" then link.doorA = finished.originalDoor
                            else link.doorB = finished.originalDoor end
                            if editor.callbacks.onStatus then
                                editor.callbacks.onStatus("已存在相同的区域连接，门槽端点保持不变。")
                            end
                        else
                            local gridX, gridY = editor:WorldToGrid(world)
                            if finished.which == "a" then
                                link.a, link.doorA = target,
                                    editor:PointToDoorSpec(editor.rooms[target], { x = gridX, y = gridY })
                            else
                                link.b, link.doorB = target,
                                    editor:PointToDoorSpec(editor.rooms[target], { x = gridX, y = gridY })
                            end
                        end
                    end
                end
            end
        end
        if finished.kind == "linkDoor" then editor:NormalizeConnectedSecretRooms() end
        -- Selecting a room/path creates a drag candidate immediately. A plain
        -- click must not regenerate the whole dungeon; only a gesture that
        -- actually changed geometry is a model edit.
        if not finished.changed then
            editor:RefreshOverlay()
            return true
        end
        local editedLink = editor.links[finished.link]
        if editedLink and not finished.kind:find("stair", 1, true) then editor:NormalizeLink(editedLink) end
        editor:RefreshOverlay()
        editor:Commit()
        return true
    end
    if editor.draw then
        local minX, maxX = math.min(editor.draw.gx, editor.draw.ex), math.max(editor.draw.gx, editor.draw.ex)
        local minY, maxY = math.min(editor.draw.gy, editor.draw.ey), math.max(editor.draw.gy, editor.draw.ey)
        if maxX - minX >= 3 and maxY - minY >= 3 then
            editor.rooms[#editor.rooms + 1] = {
                cx = math.floor((minX + maxX) * 0.5 + 0.5),
                cy = math.floor((minY + maxY) * 0.5 + 0.5),
                w = Clamp(math.floor(maxX - minX + 0.5), 5, 24),
                h = Clamp(math.floor(maxY - minY + 0.5), 5, 24),
                floor = editor.floor,
            }
            -- Drawn rooms start disconnected; keep them valid as secret rooms
            -- until a path connects them (which clears the flag).
            editor:MarkDisconnectedRoomsSecret()
            editor.selected = #editor.rooms
            editor:NotifySelection()
            editor.draw = nil
            editor:UpdateDrawPreview()
            editor:Commit()
        else
            editor.draw = nil
            editor:UpdateDrawPreview()
        end
        return true
    end
    return false
end

return EditorGesture
