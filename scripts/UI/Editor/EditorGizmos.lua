local StairEditing = require("UI.Editor.StairEditing")
local RouteEditing = require("UI.Editor.RouteEditing")

local EditorGizmos = {}

local function DistanceToSegment(x, y, a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local lengthSquared = dx * dx + dy * dy
    if lengthSquared <= 0.0001 then return math.sqrt((x - a.x)^2 + (y - a.y)^2) end
    local t = math.max(0, math.min(1, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared))
    local px, py = a.x + dx * t, a.y + dy * t
    return math.sqrt((x - px)^2 + (y - py)^2)
end

local function ProjectRoute(editor, viewport, route)
    local result = {}
    for _, point in ipairs(route or {}) do
        local projected = viewport:ProjectGrid(editor, point, 0.66)
        if projected then result[#result + 1] = projected end
    end
    return result
end

local function BeginPolyline(vg, points)
    if #points < 2 then return false end
    nvgBeginPath(vg)
    nvgMoveTo(vg, points[1].x, points[1].y)
    for index = 2, #points do nvgLineTo(vg, points[index].x, points[index].y) end
    return true
end

local function StrokePolyline(vg, points, color, width)
    if not BeginPolyline(vg, points) then return end
    nvgStrokeColor(vg, color)
    nvgStrokeWidth(vg, width)
    nvgStroke(vg)
end

local function FillPolygon(vg, points, color)
    if not BeginPolyline(vg, points) then return end
    nvgClosePath(vg)
    nvgFillColor(vg, color)
    nvgFill(vg)
end

local function AddCircle(descriptors, descriptor)
    descriptor.shape = "circle"
    descriptors[#descriptors + 1] = descriptor
end

local function AddSegment(descriptors, descriptor)
    descriptor.shape = "segment"
    descriptors[#descriptors + 1] = descriptor
end

local function AddRoomDescriptors(editor, viewport, descriptors)
    local room = editor.rooms[editor.selected]
    if not room or room.floor ~= editor.floor then return end
    local corners = {
        nw = { x = room.cx - room.w * 0.5, y = room.cy - room.h * 0.5 },
        ne = { x = room.cx + room.w * 0.5, y = room.cy - room.h * 0.5 },
        sw = { x = room.cx - room.w * 0.5, y = room.cy + room.h * 0.5 },
        se = { x = room.cx + room.w * 0.5, y = room.cy + room.h * 0.5 },
    }
    local projected = {}
    for key, point in pairs(corners) do projected[key] = viewport:ProjectGrid(editor, point, 0.70) end
    local cornerModes = { nw = "resize-nw", ne = "resize-ne", sw = "resize-sw", se = "resize-se" }
    for key, mode in pairs(cornerModes) do
        local point = projected[key]
        if point then AddCircle(descriptors, { key = "room-" .. mode, kind = "roomResize", mode = mode, x = point.x, y = point.y,
            radius = 8, drawRadius = 3, priority = 120, cursor = mode }) end
    end
    local edges = {
        { mode = "resize-n", a = projected.nw, b = projected.ne },
        { mode = "resize-s", a = projected.sw, b = projected.se },
        { mode = "resize-w", a = projected.nw, b = projected.sw },
        { mode = "resize-e", a = projected.ne, b = projected.se },
    }
    for _, edge in ipairs(edges) do
        if edge.a and edge.b then AddSegment(descriptors, { key = "room-edge-" .. edge.mode, kind = "roomResize", mode = edge.mode,
            a = edge.a, b = edge.b, tolerance = 7, priority = 90, cursor = edge.mode }) end
    end
end

local function AddLinkDescriptors(editor, viewport, descriptors)
    local link = editor.links[editor.selectedLink]
    if not link then return end
    -- A* geometry is regenerated from the authored room graph. It remains
    -- selectable, but generic bend and stair handles would imply unsupported edits.
    if link.runtimeGenerated then return end
    if link.kind == "stairs" and link.connector and link.connector.lower and link.connector.upper then
        local segments = StairEditing.VisualSegments(link.connector)
        local rotation = StairEditing.RotationHandle(link.connector)
        local width = StairEditing.WidthHandle(link.connector)
        if rotation then
            local point = viewport:ProjectGrid(editor, rotation, 0.72)
            local last = segments[#segments]
            local edge = last and viewport:ProjectGrid(editor, last.finish, 0.72) or nil
            if point then AddCircle(descriptors, { key = "stair-" .. editor.selectedLink .. "-rotate", kind = "stairRotate", link = editor.selectedLink,
                x = point.x, y = point.y, radius = 12, drawRadius = 7, edge = edge, priority = 150, cursor = "rotate" }) end
        end
        if width then
            local point = viewport:ProjectGrid(editor, width, 0.72)
            local edgePoint = segments[1] and segments[1].start or link.connector.lower
            local edge = viewport:ProjectGrid(editor, edgePoint, 0.72)
            if point then AddCircle(descriptors, { key = "stair-" .. editor.selectedLink .. "-width", kind = "stairWidth", link = editor.selectedLink,
                x = point.x, y = point.y, radius = 12, drawRadius = 7, edge = edge, priority = 145, cursor = "width" }) end
        end
        return
    end
    local route = editor:DisplayLinkRoute(link)
    for index, point in ipairs(route) do
        local screen = viewport:ProjectGrid(editor, point, 0.72)
        if screen then
            local isDoor = index == 1 or index == #route
            AddCircle(descriptors, {
                key = "path-" .. editor.selectedLink .. "-" .. (isDoor and (index == 1 and "door-a" or "door-b") or ("bend-" .. (index - 1))),
                kind = isDoor and "door" or "bend",
                link = editor.selectedLink,
                which = index == 1 and "a" or (index == #route and "b" or nil),
                bendIndex = isDoor and nil or index - 1,
                x = screen.x, y = screen.y,
                radius = isDoor and 10 or 9,
                drawRadius = isDoor and 6 or 5,
                priority = isDoor and 140 or 135,
                cursor = "move",
            })
        end
    end
end

function EditorGizmos.Build(editor, viewport)
    local descriptors = {}
    AddRoomDescriptors(editor, viewport, descriptors)
    AddLinkDescriptors(editor, viewport, descriptors)
    table.sort(descriptors, function(a, b) return (a.priority or 0) < (b.priority or 0) end)
    return descriptors
end

function EditorGizmos.Hit(descriptors, x, y)
    for index = #descriptors, 1, -1 do
        local item = descriptors[index]
        local hit = item.shape == "circle" and math.sqrt((x - item.x)^2 + (y - item.y)^2) <= item.radius
            or item.shape == "segment" and DistanceToSegment(x, y, item.a, item.b) <= item.tolerance
        if hit then return item end
    end
    return nil
end

local function DrawRoomOutlines(editor, vg, viewport)
    for index, room in ipairs(editor.rooms) do
        if index == editor.selected and room.floor == editor.floor then
            local route = ProjectRoute(editor, viewport, {
                { x = room.cx - room.w * 0.5, y = room.cy - room.h * 0.5 },
                { x = room.cx + room.w * 0.5, y = room.cy - room.h * 0.5 },
                { x = room.cx + room.w * 0.5, y = room.cy + room.h * 0.5 },
                { x = room.cx - room.w * 0.5, y = room.cy + room.h * 0.5 },
                { x = room.cx - room.w * 0.5, y = room.cy - room.h * 0.5 },
            })
            local selected = editor.selected == index
            StrokePolyline(vg, route, selected and nvgRGBA(232, 151, 63, 255)
                or nvgRGBA(61, 199, 184, 150), selected and 2.0 or 1.0)
        end
    end
end

function EditorGizmos.CorridorEntries(editor)
    local entries = {}
    for index, link in ipairs(editor.links) do
        local roomA, roomB = editor.rooms[link.a], editor.rooms[link.b]
        if link.runtimeGenerated then
            for _, runtimeRoute in ipairs(link.runtimeRoutes or {}) do
                if runtimeRoute.floor == editor.floor and #(runtimeRoute.points or {}) > 1 then
                    entries[#entries + 1] = {
                        index = index, link = link, route = runtimeRoute.points, runtime = true,
                    }
                end
            end
        elseif link.kind ~= "stairs" and roomA and roomB
            and roomA.floor == editor.floor and roomB.floor == editor.floor then
            entries[#entries + 1] = { index = index, link = link, route = editor:DisplayLinkRoute(link) }
        end
    end
    return entries
end

local function PointInsideRoom(room, x, y)
    if not room then return false end
    return x > room.cx - room.w * 0.5 + 0.00001
        and x < room.cx + room.w * 0.5 - 0.00001
        and y > room.cy - room.h * 0.5 + 0.00001
        and y < room.cy + room.h * 0.5 - 0.00001
end

local function PointInsideCurrentFloorRoom(editor, x, y)
    for _, room in ipairs(editor.rooms or {}) do
        if room.floor == editor.floor and PointInsideRoom(room, x, y) then return true end
    end
    return false
end

local function SegmentOutsideRooms(editor, a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local cuts = { 0, 1 }
    local function AddCut(value)
        if value > 0.00001 and value < 0.99999 then cuts[#cuts + 1] = value end
    end
    local function AddRoomInterval(room)
        local enter, exit = 0, 1
        local function Clip(p, q)
            if math.abs(p) < 0.000001 then return q >= 0 end
            local value = q / p
            if p < 0 then
                if value > exit then return false end
                if value > enter then enter = value end
            else
                if value < enter then return false end
                if value < exit then exit = value end
            end
            return true
        end
        if not Clip(-dx, a.x - (room.cx - room.w * 0.5))
            or not Clip(dx, (room.cx + room.w * 0.5) - a.x)
            or not Clip(-dy, a.y - (room.cy - room.h * 0.5))
            or not Clip(dy, (room.cy + room.h * 0.5) - a.y) then return end
        if exit > enter + 0.00001 then AddCut(enter); AddCut(exit) end
    end
    for _, room in ipairs(editor.rooms or {}) do
        if room.floor == editor.floor then AddRoomInterval(room) end
    end
    table.sort(cuts)
    local pieces = {}
    for index = 1, #cuts - 1 do
        local t0, t1 = cuts[index], cuts[index + 1]
        if t1 - t0 > 0.00001 then
            local middle = (t0 + t1) * 0.5
            if not PointInsideCurrentFloorRoom(editor, a.x + dx * middle, a.y + dy * middle) then
                pieces[#pieces + 1] = {
                    a = { x = a.x + dx * t0, y = a.y + dy * t0 },
                    b = { x = a.x + dx * t1, y = a.y + dy * t1 },
                }
            end
        end
    end
    return pieces
end

function EditorGizmos.OutsideRoomSegments(editor, route)
    local result = {}
    for index = 1, #(route or {}) - 1 do
        for _, piece in ipairs(SegmentOutsideRooms(editor, route[index], route[index + 1])) do
            result[#result + 1] = piece
        end
    end
    return result
end

function EditorGizmos.HitRuntimeLink(link, floor, gridX, gridY, tolerance)
    if not link or not link.runtimeGenerated then return nil end
    local best = nil
    local function TestSegment(a, b, segment, stair)
        local distance = DistanceToSegment(gridX, gridY, a, b)
        local width = stair and (stair.width or 1) or (link.width or 1)
        if distance <= math.max(tolerance, width * 0.5)
            and (not best or distance < best.distance) then
            best = {
                segment = segment,
                distance = distance,
                stair = stair ~= nil,
                runtime = true,
            }
        end
    end
    for _, runtimeRoute in ipairs(link.runtimeRoutes or {}) do
        if runtimeRoute.floor == floor then
            for segment = 1, #(runtimeRoute.points or {}) - 1 do
                TestSegment(runtimeRoute.points[segment], runtimeRoute.points[segment + 1], segment, nil)
            end
        end
    end
    for _, connector in ipairs(link.runtimeStairs or {}) do
        if connector.fromFloor == floor or connector.toFloor == floor then
            local segments = StairEditing.VisualSegments(connector)
            for segment, stairSegment in ipairs(segments) do
                TestSegment(stairSegment.start, stairSegment.finish, segment, connector)
            end
        end
    end
    return best
end

local function DrawCorridors(editor, vg, viewport)
    nvgLineCap(vg, NVG_ROUND)
    nvgLineJoin(vg, NVG_ROUND)
    for _, entry in ipairs(EditorGizmos.CorridorEntries(editor)) do
        local index, link, route = entry.index, entry.link, entry.route
        local selected = editor.selectedLink == index
        local hovered = not selected and editor.hoveredLink == index
        -- Opaque base colors keep one route visually identical over black void,
        -- generated floors and room overlays. The outline carries selection.
        local bandColor = selected and nvgRGBA(118, 78, 35, 255)
            or (hovered and nvgRGBA(58, 92, 113, 255) or nvgRGBA(48, 74, 94, 255))
        local outlineColor = selected and nvgRGBA(232, 151, 63, 255)
            or (hovered and nvgRGBA(139, 207, 244, 255) or nvgRGBA(83, 164, 176, 255))
        for _, piece in ipairs(EditorGizmos.OutsideRoomSegments(editor, route)) do
            local points = ProjectRoute(editor, viewport, { piece.a, piece.b })
            local scale = viewport:PixelsPerGrid(editor, piece.a)
            local band = RouteEditing.CorridorScreenWidth(link.width, scale)
            StrokePolyline(vg, points, bandColor, band)
            StrokePolyline(vg, points, outlineColor, selected and 1.8 or 1.2)
        end
    end
end

local function DrawStairs(editor, vg, viewport)
    for index, link in ipairs(editor.links) do
        local roomA, roomB = editor.rooms[link.a], editor.rooms[link.b]
        local connectors = link.runtimeGenerated and link.runtimeStairs or { link.connector }
        for _, connector in ipairs(connectors or {}) do
        local fromFloor = connector and (connector.fromFloor
            or (roomA and roomB and math.min(roomA.floor, roomB.floor)))
        local toFloor = connector and (connector.toFloor
            or (roomA and roomB and math.max(roomA.floor, roomB.floor)))
        if connector and fromFloor ~= nil and toFloor ~= nil and fromFloor ~= toFloor
            and (fromFloor == editor.floor or toFloor == editor.floor)
            and (link.runtimeGenerated or editor:GetViewMode() == "2d" or index == editor.selectedLink) then
            local segments, platform = StairEditing.VisualSegments(connector)
            local scale = viewport:PixelsPerGrid(editor,
                segments[1] and segments[1].start or connector.lower)
            local selected = editor.selectedLink == index
            local invalid = not link.runtimeGenerated and link.stairSpec and link.stairSpec.invalid
            local lower = fromFloor == editor.floor
            local outline = invalid and nvgRGBA(255, 95, 95, 255)
                or (selected and nvgRGBA(255, 211, 106, 255)
                    or (lower and nvgRGBA(232, 151, 63, 255) or nvgRGBA(181, 140, 255, 255)))
            local fill = invalid and nvgRGBA(255, 72, 72, 70)
                or (lower and nvgRGBA(232, 151, 63, 66) or nvgRGBA(155, 108, 240, 55))
            if platform then
                local half = platform.visualSpan * 0.5
                local platformPoints = ProjectRoute(editor, viewport, {
                    { x = platform.center.x - half, y = platform.center.y - half },
                    { x = platform.center.x + half, y = platform.center.y - half },
                    { x = platform.center.x + half, y = platform.center.y + half },
                    { x = platform.center.x - half, y = platform.center.y + half },
                })
                FillPolygon(vg, platformPoints, fill)
                if #platformPoints >= 3 then
                    platformPoints[#platformPoints + 1] = platformPoints[1]
                    StrokePolyline(vg, platformPoints, outline, selected and 2.5 or 1.6)
                end
            end
            for _, segment in ipairs(segments) do
                local segmentPoints = ProjectRoute(editor, viewport, { segment.start, segment.finish })
                StrokePolyline(vg, segmentPoints, fill, math.max(4, (connector.width or 2) * scale))
                StrokePolyline(vg, segmentPoints, outline, selected and 2.5 or 1.6)
            end
            local totalSteps = math.min(12, connector.stepCount or 12)
            for segmentIndex, segment in ipairs(segments) do
                local a, b = segment.start, segment.finish
                local projected = ProjectRoute(editor, viewport, { a, b })
                local sa, sb = projected[1], projected[2]
                if sa and sb then
                    local dx, dy = b.x - a.x, b.y - a.y
                    local length = math.max(0.001, math.sqrt(dx * dx + dy * dy))
                    local nx, ny = -dy / length, dx / length
                    local segmentSteps = math.max(2, math.floor(totalSteps / math.max(1, #segments)))
                    for step = 1, segmentSteps - 1 do
                        local t = step / segmentSteps
                        local center = { x = a.x + dx * t, y = a.y + dy * t }
                        local halfWidth = (connector.width or 2) * 0.5
                        local p0 = viewport:ProjectGrid(editor, { x = center.x + nx * halfWidth, y = center.y + ny * halfWidth }, 0.69)
                        local p1 = viewport:ProjectGrid(editor, { x = center.x - nx * halfWidth, y = center.y - ny * halfWidth }, 0.69)
                        if p0 and p1 then StrokePolyline(vg, { p0, p1 }, nvgRGBA(255, 224, 174, 115), 1) end
                    end
                end
            end
            local anchorPoint = segments[1] and segments[1].start or connector.lower
            local anchor = viewport:ProjectGrid(editor, anchorPoint, 0.69)
            if anchor and (not link.runtimeGenerated or index == editor.selectedLink) then
                nvgFontSize(vg, 11)
                nvgFillColor(vg, outline)
                local targetFloor = lower and toFloor or fromFloor
                local style = (connector.style or (link.stairSpec and link.stairSpec.style)) == "straight" and "Straight" or "L"
                nvgText(vg, anchor.x + 9, anchor.y - 9,
                    (lower and "UP" or "DOWN") .. " F" .. (targetFloor + 1) .. "  " .. style
                        .. "  W " .. string.format("%.2f", connector.width or 2), nil)
            end
        end
        end
    end
end

function EditorGizmos.HandleLayer(item)
    return item and (item.kind == "stairRotate" or item.kind == "stairWidth") and "stair" or "foreground"
end

local function DrawHandles(editor, vg, descriptors, layer)
    for _, item in ipairs(descriptors) do
        if EditorGizmos.HandleLayer(item) == layer then
        local hovered = editor.hoveredGizmo and editor.hoveredGizmo.key == item.key
        if item.kind == "roomResize" and item.shape == "circle" then
            local radius = (item.drawRadius or 3) + (hovered and 1 or 0)
            nvgBeginPath(vg); nvgRect(vg, item.x - radius, item.y - radius, radius * 2, radius * 2)
            nvgFillColor(vg, nvgRGBA(232, 151, 63, 255)); nvgFill(vg)
        elseif item.kind ~= "roomResize" then
            if item.edge then
                StrokePolyline(vg, { item.edge, { x = item.x, y = item.y } },
                    item.kind == "stairWidth" and nvgRGBA(101, 216, 255, 220) or nvgRGBA(255, 211, 106, 220), 1.8)
            end
            local radius = (item.drawRadius or 5) + (hovered and 1.5 or 0)
            nvgBeginPath(vg)
            if item.kind == "stairWidth" then nvgRect(vg, item.x - radius, item.y - radius, radius * 2, radius * 2)
            else nvgCircle(vg, item.x, item.y, radius) end
            nvgFillColor(vg, nvgRGBA(18, 23, 36, 255)); nvgFill(vg)
            nvgStrokeColor(vg, item.kind == "stairWidth" and nvgRGBA(101, 216, 255, 255)
                or (item.kind == "bend" and nvgRGBA(232, 151, 63, 255) or nvgRGBA(255, 211, 106, 255)))
            nvgStrokeWidth(vg, hovered and 2.5 or 2); nvgStroke(vg)
            if item.kind == "door" or item.kind == "bend" then
                nvgBeginPath(vg); nvgCircle(vg, item.x, item.y, math.max(2, radius - 2))
                nvgFillColor(vg, item.kind == "door" and nvgRGBA(255, 211, 106, 255)
                    or nvgRGBA(232, 151, 63, 255)); nvgFill(vg)
            elseif item.kind == "stairRotate" or item.kind == "stairWidth" then
                nvgFontSize(vg, 10); nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, item.kind == "stairWidth" and nvgRGBA(155, 232, 255, 255)
                    or nvgRGBA(255, 227, 163, 255))
                nvgText(vg, item.x, item.y + 0.5, item.kind == "stairWidth" and "<>" or "R", nil)
                nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
            end
        end
        end
    end
end

function EditorGizmos.Render(editor, vg, viewport, descriptors)
    EditorGizmos.RenderBackground(editor, vg, viewport, descriptors)
    EditorGizmos.RenderForeground(editor, vg, viewport, descriptors)
end

function EditorGizmos.RenderBackground(editor, vg, viewport, descriptors)
    DrawCorridors(editor, vg, viewport)
end

function EditorGizmos.RenderForeground(editor, vg, viewport, descriptors)
    DrawRoomOutlines(editor, vg, viewport)
    -- Cross-floor stairs are an explicit top layer: their complete flights,
    -- turn platform and edit handles must remain visible over either room.
    DrawStairs(editor, vg, viewport)
    DrawHandles(editor, vg, descriptors or {}, "stair")
    DrawHandles(editor, vg, descriptors, "foreground")
end

return EditorGizmos
