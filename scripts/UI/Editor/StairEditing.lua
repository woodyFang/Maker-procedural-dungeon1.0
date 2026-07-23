local MultiFloor = require("Generation.MultiFloor")
local StairContract = require("Generation.StairContract")

local StairEditing = {}

local DIRECTIONS = {
    east = { x = 1, y = 0, next = "south" },
    south = { x = 0, y = 1, next = "west" },
    west = { x = -1, y = 0, next = "north" },
    north = { x = 0, y = -1, next = "east" },
}

local function Round(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

local function CopyPoint(point)
    return point and { x = point.x, y = point.y } or nil
end

local function OverlapSpan(aCenter, aSize, bCenter, bSize)
    return math.max(0, math.min(aCenter + aSize * 0.5, bCenter + bSize * 0.5)
        - math.max(aCenter - aSize * 0.5, bCenter - bSize * 0.5))
end

function StairEditing.NormalizeStyle(style)
    return style == "straight" and "straight" or "l-turn"
end

function StairEditing.SnapWidth(width, minimum, maximum, step)
    minimum = minimum or StairContract.MIN_WIDTH
    maximum = maximum or StairContract.MAX_WIDTH
    step = step or StairContract.WIDTH_STEP
    local value = tonumber(width) or 2
    local snapped = math.floor(value / step + 0.5) * step
    return math.max(minimum, math.min(maximum, snapped))
end

function StairEditing.AdjacentFloorTargets(floor, floorCount)
    local result = {}
    if floor + 1 < floorCount then result[#result + 1] = floor + 1 end
    if floor - 1 >= 0 then result[#result + 1] = floor - 1 end
    return result
end

function StairEditing.ChooseTargetFloor(floor, floorCount, preferredDelta)
    local targets = StairEditing.AdjacentFloorTargets(floor, floorCount)
    local preferred = floor + ((preferredDelta or 1) >= 0 and 1 or -1)
    for _, target in ipairs(targets) do if target == preferred then return target end end
    return targets[1]
end

function StairEditing.DirectPlacement(point, style, length)
    if not point or not tonumber(point.x) or not tonumber(point.y) then return nil end
    style, length = StairEditing.NormalizeStyle(style), math.max(4, Round(length or 8))
    local x, y = Round(point.x), Round(point.y)
    if style == "straight" then
        return { anchor = { x = x - Round(length * 0.5), y = y }, direction = "east", length = length, style = style }
    end
    local firstRun = math.max(3, math.floor(length * 0.5))
    local secondRun = math.max(3, length - firstRun)
    return {
        anchor = { x = x - Round(firstRun * 0.5), y = y - Round(secondRun * 0.5) },
        direction = "east", length = length, style = style,
    }
end

function StairEditing.PairError(source, target)
    if not source or not target then return "请选择楼梯两端的区域。" end
    if source == target or source.id == target.id then return "楼梯两端不能是同一个区域。" end
    if math.abs((source.floor or 0) - (target.floor or 0)) ~= 1 then return "楼梯只能连接相邻楼层。" end
    return nil
end

function StairEditing.MatchingRooms(source, rooms, targetFloor, stairRun, stairWidth)
    if not source then return {} end
    local result = {}
    local flightRun = math.max(3, math.floor((stairRun or 8) * 0.5))
    stairWidth = stairWidth or 3
    for _, room in ipairs(rooms or {}) do
        if room ~= source and room.id ~= source.id and (room.floor or 0) == targetFloor then
            local overlapX = OverlapSpan(source.cx, source.w, room.cx, room.w)
            local overlapY = OverlapSpan(source.cy, source.h, room.cy, room.h)
            if overlapX >= flightRun + stairWidth - 1 and overlapY >= flightRun + stairWidth - 1 then
                result[#result + 1] = { room = room, area = overlapX * overlapY,
                    distance = math.sqrt((room.cx - source.cx)^2 + (room.cy - source.cy)^2) }
            end
        end
    end
    table.sort(result, function(a, b)
        return a.area == b.area and a.distance < b.distance or a.area > b.area
    end)
    local roomsOnly = {}
    for index, item in ipairs(result) do roomsOnly[index] = item.room end
    return roomsOnly
end

local function PlacementClear(candidate, rooms, floor)
    for _, room in ipairs(rooms or {}) do
        if (room.floor or 0) == floor
            and math.abs(candidate.cx - room.cx) < (candidate.w + room.w) * 0.5 + 2
            and math.abs(candidate.cy - room.cy) < (candidate.h + room.h) * 0.5 + 2 then return false end
    end
    return true
end

function StairEditing.PairedRoomPlacement(source, rooms, targetFloor)
    local sourceFloor = source.floor or 0
    local offsets = { 0, -4, 4, -8, 8, -12, 12 }
    local sides = {
        { side = "east", w = 14, h = 10, cx = source.cx + source.w * 0.5 + 10, cy = source.cy, axis = "x" },
        { side = "west", w = 14, h = 10, cx = source.cx - source.w * 0.5 - 10, cy = source.cy, axis = "x" },
        { side = "south", w = 10, h = 14, cx = source.cx, cy = source.cy + source.h * 0.5 + 10, axis = "y" },
        { side = "north", w = 10, h = 14, cx = source.cx, cy = source.cy - source.h * 0.5 - 10, axis = "y" },
    }
    for _, side in ipairs(sides) do
        for _, offset in ipairs(offsets) do
            local candidate = {
                cx = Round(side.cx + (side.axis == "x" and 0 or offset)),
                cy = Round(side.cy + (side.axis == "x" and offset or 0)),
                w = side.w, h = side.h, side = side.side,
            }
            if PlacementClear(candidate, rooms, sourceFloor) and PlacementClear(candidate, rooms, targetFloor) then
                return candidate
            end
        end
    end
    return nil
end

local function StairShape(style, directionName, length, anchor)
    local first = DIRECTIONS[directionName]
    if not first or not anchor then return nil end
    style = StairEditing.NormalizeStyle(style)
    local lower = CopyPoint(anchor)
    if style == "straight" then
        return { style = style, lower = lower, turn = nil,
            upper = { x = lower.x + first.x * length, y = lower.y + first.y * length },
            first = first, second = first, firstRun = length, secondRun = 0, secondName = directionName }
    end
    local firstRun = math.max(3, math.floor(length * 0.5))
    local secondRun = math.max(3, length - firstRun)
    local secondName, second = first.next, DIRECTIONS[first.next]
    local turn = { x = lower.x + first.x * firstRun, y = lower.y + first.y * firstRun }
    return { style = style, lower = lower, turn = turn,
        upper = { x = turn.x + second.x * secondRun, y = turn.y + second.y * secondRun },
        first = first, second = second, firstRun = firstRun, secondRun = secondRun, secondName = secondName }
end

local function ShapeCenter(shape)
    local points = { shape.lower }
    if shape.turn then points[#points + 1] = shape.turn end
    points[#points + 1] = shape.upper
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, point in ipairs(points) do
        minX, maxX = math.min(minX, point.x), math.max(maxX, point.x)
        minY, maxY = math.min(minY, point.y), math.max(maxY, point.y)
    end
    return { x = (minX + maxX) * 0.5, y = (minY + maxY) * 0.5 }
end

local function CurrentPlacement(spec, visual)
    local direction = spec.previewDirection or spec.direction or (visual and visual.direction) or "east"
    local lower = visual and visual.lower or spec.previewAnchor or spec.anchor
    local upper = visual and visual.upper or nil
    local length = math.max(1, Round(spec.previewLength or spec.length
        or (lower and upper and math.sqrt((upper.x - lower.x)^2 + (upper.y - lower.y)^2)) or 8))
    local requestedStyle = spec.previewStyle or spec.style or (visual and visual.style)
    local style = requestedStyle and StairEditing.NormalizeStyle(requestedStyle) or "straight"
    if not lower or not DIRECTIONS[direction] then return nil end
    local shape = style == "l-turn" and visual and visual.turn
        and { lower = CopyPoint(lower), turn = CopyPoint(visual.turn), upper = CopyPoint(upper) }
        or StairShape(style, direction, length, lower)
    return direction, length, style, shape
end

function StairEditing.Rotate90(spec, visual)
    local direction, length, style, shape = CurrentPlacement(spec, visual)
    if not direction then return nil end
    local nextName = DIRECTIONS[direction].next
    local center, nextAtOrigin = ShapeCenter(shape), StairShape(style, nextName, length, { x = 0, y = 0 })
    local nextCenter = ShapeCenter(nextAtOrigin)
    return { anchor = { x = Round(center.x - nextCenter.x), y = Round(center.y - nextCenter.y) },
        direction = nextName, length = length, style = style }
end

function StairEditing.RotationFromPointer(spec, visual, pointer, previousDirection)
    local _, length, style, shape = CurrentPlacement(spec, visual)
    if not shape or not pointer then return nil end
    local center = ShapeCenter(shape)
    local dx, dy = pointer.x - center.x, pointer.y - center.y
    if math.sqrt(dx * dx + dy * dy) < 0.5 then return nil end
    local absX, absY = math.abs(dx), math.abs(dy)
    local horizontal = absX >= absY
    -- Keep the current axis around diagonal boundaries. Without this small
    -- hysteresis, a noisy pointer alternates east/south every frame.
    if previousDirection == "east" or previousDirection == "west" then
        horizontal = not (absY > absX * 1.18)
    elseif previousDirection == "north" or previousDirection == "south" then
        horizontal = absX > absY * 1.18
    end
    local direction = horizontal and (dx >= 0 and "east" or "west")
        or (dy >= 0 and "south" or "north")
    local nextCenter = ShapeCenter(StairShape(style, direction, length, { x = 0, y = 0 }))
    return { anchor = { x = Round(center.x - nextCenter.x), y = Round(center.y - nextCenter.y) },
        direction = direction, length = length, style = style }
end

function StairEditing.ChangeStyle(spec, visual, requestedStyle)
    local direction, length, _, shape = CurrentPlacement(spec, visual)
    if not direction then return nil end
    local style, center = StairEditing.NormalizeStyle(requestedStyle), ShapeCenter(shape)
    local nextCenter = ShapeCenter(StairShape(style, direction, length, { x = 0, y = 0 }))
    return { anchor = { x = Round(center.x - nextCenter.x), y = Round(center.y - nextCenter.y) },
        direction = direction, length = length, style = style }
end

function StairEditing.Visual(spec, visual, placement)
    if not placement or not placement.anchor or not DIRECTIONS[placement.direction] then return visual end
    local length = math.max(1, Round(placement.length or spec.previewLength or spec.length or 8))
    local landingDepth = math.max(1, Round(spec.previewLandingDepth or spec.landingDepth or 2))
    local style = StairEditing.NormalizeStyle(placement.style or spec.previewStyle or spec.style or (visual and visual.style))
    local shape = StairShape(style, placement.direction, length, placement.anchor)
    local first, second = shape.first, shape.second
    local result = {}
    for key, value in pairs(visual or {}) do result[key] = value end
    result.style, result.lower, result.turn, result.upper = style, shape.lower, shape.turn, shape.upper
    result.direction, result.secondDirection = placement.direction, shape.secondName
    result.directionVector, result.secondDirectionVector = { x = first.x, y = first.y }, { x = second.x, y = second.y }
    result.firstRun, result.secondRun, result.length = shape.firstRun, shape.secondRun, length
    result.width = spec.previewWidth or spec.width or result.width or 2
    result.lateralCenterOffset = spec.previewLateralCenterOffset or spec.lateralCenterOffset
        or result.lateralCenterOffset
    local platform = MultiFloor.StairTurnPlatformMetrics(result)
    if platform then
        result.lowerApproach = { x = platform.first.start.x - first.x * landingDepth,
            y = platform.first.start.y - first.y * landingDepth }
        result.upperApproach = { x = platform.second.finish.x + second.x * landingDepth,
            y = platform.second.finish.y + second.y * landingDepth }
        result.turnPlatform = platform
    else
        local lowerCenter = MultiFloor.StairRunCenter(shape.lower, first, result.width, result.lateralCenterOffset)
        local upperCenter = MultiFloor.StairRunCenter(shape.upper, second, result.width, result.lateralCenterOffset)
        result.lowerApproach = { x = lowerCenter.x - first.x * landingDepth,
            y = lowerCenter.y - first.y * landingDepth }
        result.upperApproach = { x = upperCenter.x + second.x * landingDepth,
            y = upperCenter.y + second.y * landingDepth }
        result.turnPlatform = nil
    end
    return result
end

function StairEditing.VisualSegments(visual)
    if not visual or not visual.lower or not visual.upper then return {}, nil end
    local platform = MultiFloor.StairTurnPlatformMetrics(visual)
    if platform then return { platform.first, platform.second }, platform end
    local direction = visual.directionVector or DIRECTIONS[visual.direction or "east"] or DIRECTIONS.east
    return { {
        start = MultiFloor.StairRunCenter(visual.lower, direction, visual.width, visual.lateralCenterOffset),
        finish = MultiFloor.StairRunCenter(visual.upper, direction, visual.width, visual.lateralCenterOffset),
        direction = direction,
        length = math.sqrt((visual.upper.x - visual.lower.x)^2 + (visual.upper.y - visual.lower.y)^2),
    } }, nil
end

function StairEditing.WidthFromPointer(spec, visual, pointer, minimum, maximum, step, handleGap)
    local segments = StairEditing.VisualSegments(visual)
    local start, finish = segments[1] and segments[1].start, segments[1] and segments[1].finish
    if not start or not finish or not pointer then return nil end
    local dx, dy = finish.x - start.x, finish.y - start.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return nil end
    local perpendicular = { x = -dy / length, y = dx / length }
    local center = { x = (start.x + finish.x) * 0.5, y = (start.y + finish.y) * 0.5 }
    local distance = math.abs((pointer.x - center.x) * perpendicular.x + (pointer.y - center.y) * perpendicular.y)
    local width = math.max(0, distance - (handleGap or 1)) * 2
    return StairEditing.SnapWidth(width, minimum, maximum, step)
end

-- One-side-fixed width resize (spec §8.2): the far edge stays put while the
-- dragged edge moves. Returns both the snapped width and the compensating
-- lateralCenterOffset so the opposite boundary keeps landing on a tile edge.
function StairEditing.WidthResizeFromPointer(spec, visual, pointer, minimum, maximum, step, handleGap)
    local segments = StairEditing.VisualSegments(visual)
    local start, finish = segments[1] and segments[1].start, segments[1] and segments[1].finish
    if not start or not finish or not pointer then return nil end
    local dx, dy = finish.x - start.x, finish.y - start.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return nil end
    local perpendicular = { x = -dy / length, y = dx / length }
    local startWidth = StairEditing.SnapWidth(
        (visual and visual.width) or spec.previewWidth or spec.width or 2, minimum, maximum, step)
    local rawStartOffset = tonumber((visual and visual.lateralCenterOffset)
        or spec.previewLateralCenterOffset or spec.lateralCenterOffset) or 0
    local startOffset = StairContract.LateralCenterOffset(startWidth, rawStartOffset)
    local center = { x = (start.x + finish.x) * 0.5, y = (start.y + finish.y) * 0.5 }
    local fixedEdge = {
        x = center.x + perpendicular.x * (startOffset - startWidth * 0.5),
        y = center.y + perpendicular.y * (startOffset - startWidth * 0.5),
    }
    local pointerDistance = (pointer.x - fixedEdge.x) * perpendicular.x
        + (pointer.y - fixedEdge.y) * perpendicular.y
    local rawWidth = math.max(0, pointerDistance - (handleGap or 1))
    local width = StairEditing.SnapWidth(rawWidth, minimum, maximum, step)
    return {
        width = width,
        lateralCenterOffset = StairContract.LateralCenterOffset(width,
            startOffset + (width - startWidth) * 0.5),
    }
end

function StairEditing.RotationHandle(visual, distance)
    local segments = StairEditing.VisualSegments(visual)
    local segment = segments[#segments]
    if not segment then return nil end
    local dx, dy = segment.finish.x - segment.start.x, segment.finish.y - segment.start.y
    local length = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    local perpendicular = { x = -dy / length, y = dx / length }
    local offset = distance or math.max(1.8, (tonumber(visual.width) or 2) * 0.5 + 1.4)
    return {
        x = segment.finish.x + perpendicular.x * offset,
        y = segment.finish.y + perpendicular.y * offset,
    }
end

function StairEditing.WidthHandle(visual, gap)
    local segments = StairEditing.VisualSegments(visual)
    local start, finish = segments[1] and segments[1].start, segments[1] and segments[1].finish
    if not start or not finish then return nil end
    local dx, dy = finish.x - start.x, finish.y - start.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return nil end
    local width = tonumber(visual.width) or 2
    return {
        x = (start.x + finish.x) * 0.5 - dy / length * (width * 0.5 + (gap or 1)),
        y = (start.y + finish.y) * 0.5 + dx / length * (width * 0.5 + (gap or 1)),
    }
end

function StairEditing.AdaptRoomToStair(room, spec, placement)
    if not room or not placement or not placement.anchor or not DIRECTIONS[placement.direction] then return room end
    local length = math.max(1, Round(placement.length or spec.previewLength or spec.length or 8))
    local landingDepth = math.max(1, Round(spec.previewLandingDepth or spec.landingDepth or 2))
    local visualWidth = math.max(1, tonumber(spec.previewWidth or spec.width or 2) or 2)
    local stairWidth = math.max(1, math.ceil(visualWidth))
    local lateralCenterOffset = tonumber(spec.previewLateralCenterOffset or spec.lateralCenterOffset)
    local style = StairEditing.NormalizeStyle(placement.style or spec.previewStyle or spec.style)
    local shape = StairShape(style, placement.direction, length, placement.anchor)
    local lowerApproach = { x = shape.lower.x - shape.first.x * landingDepth,
        y = shape.lower.y - shape.first.y * landingDepth }
    local upperApproach = { x = shape.upper.x + shape.second.x * landingDepth,
        y = shape.upper.y + shape.second.y * landingDepth }
    local firstOffset = lateralCenterOffset == nil and -math.floor((stairWidth - 1) * 0.5)
        or Round(lateralCenterOffset - (stairWidth - 1) * 0.5)
    local lastOffset = firstOffset + stairWidth - 1
    local corners = {}
    local function AddSegment(startPoint, endPoint, direction)
        local perpendicular = { x = -direction.y, y = direction.x }
        for _, point in ipairs({ startPoint, endPoint }) do
            for _, offset in ipairs({ firstOffset, lastOffset }) do
                corners[#corners + 1] = { x = point.x + perpendicular.x * offset,
                    y = point.y + perpendicular.y * offset }
            end
        end
    end
    if shape.turn then
        local platform = MultiFloor.StairTurnPlatformMetrics({
            lower = shape.lower, turn = shape.turn, upper = shape.upper,
            directionVector = shape.first, secondDirectionVector = shape.second,
            firstRun = shape.firstRun, secondRun = shape.secondRun,
            width = visualWidth, lateralCenterOffset = lateralCenterOffset,
        })
        local half = visualWidth * 0.5
        local firstApproach = { x = platform.first.start.x - shape.first.x * landingDepth,
            y = platform.first.start.y - shape.first.y * landingDepth }
        local secondApproach = { x = platform.second.finish.x + shape.second.x * landingDepth,
            y = platform.second.finish.y + shape.second.y * landingDepth }
        local function AddVisualSegment(startPoint, endPoint, direction)
            local perpendicular = { x = -direction.y, y = direction.x }
            for _, point in ipairs({ startPoint, endPoint }) do
                for _, offset in ipairs({ -half, half }) do
                    corners[#corners + 1] = { x = point.x + perpendicular.x * offset,
                        y = point.y + perpendicular.y * offset }
                end
            end
        end
        AddVisualSegment(firstApproach, platform.entry, shape.first)
        AddVisualSegment(platform.exit, secondApproach, shape.second)
        corners[#corners + 1] = { x = platform.center.x - half, y = platform.center.y - half }
        corners[#corners + 1] = { x = platform.center.x + half, y = platform.center.y - half }
        corners[#corners + 1] = { x = platform.center.x + half, y = platform.center.y + half }
        corners[#corners + 1] = { x = platform.center.x - half, y = platform.center.y + half }
    else AddSegment(lowerApproach, upperApproach, shape.first) end
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, point in ipairs(corners) do
        minX, maxX = math.min(minX, point.x), math.max(maxX, point.x)
        minY, maxY = math.min(minY, point.y), math.max(maxY, point.y)
    end
    local centerX, centerY = (minX + maxX) * 0.5, (minY + maxY) * 0.5
    if room.stairRoom then
        room.cx, room.cy = Round(centerX), Round(centerY)
        room.w, room.h = math.max(8, math.ceil(maxX - minX + 2)), math.max(8, math.ceil(maxY - minY + 2))
        return room
    end
    local inside = math.abs(centerX - room.cx) <= room.w * 0.5 + 1
        and math.abs(centerY - room.cy) <= room.h * 0.5 + 1
    if inside then
        local halfWidth = math.max(room.w * 0.5, room.cx - minX + 0.5, maxX - room.cx + 0.5)
        local halfHeight = math.max(room.h * 0.5, room.cy - minY + 0.5, maxY - room.cy + 0.5)
        room.w, room.h = math.ceil(halfWidth * 2), math.ceil(halfHeight * 2)
    end
    return room
end

function StairEditing.TranslatePlacement(spec, visual, delta)
    local function Shift(point)
        return point and { x = point.x + (delta.x or 0), y = point.y + (delta.y or 0) } or nil
    end
    local moved = nil
    if visual then
        moved = {}
        for key, value in pairs(visual) do moved[key] = value end
        for _, key in ipairs({ "lower", "turn", "upper", "lowerApproach", "upperApproach" }) do moved[key] = Shift(visual[key]) end
    end
    return { anchor = Shift(spec.anchor or spec.previewAnchor or (visual and visual.lower)),
        previewAnchor = Shift(spec.previewAnchor or spec.anchor or (visual and visual.lower)), visual = moved }
end

function StairEditing.RemovalDisconnectsRooms(rooms, links, removedLink)
    local active, adjacency = {}, {}
    for index, room in ipairs(rooms or {}) do
        if room.roleHint ~= "secret" then active[#active + 1] = index; adjacency[index] = {} end
    end
    if #active < 2 then return false end
    for _, link in ipairs(links or {}) do
        if link ~= removedLink and adjacency[link.a] and adjacency[link.b] then
            adjacency[link.a][#adjacency[link.a] + 1] = link.b
            adjacency[link.b][#adjacency[link.b] + 1] = link.a
        end
    end
    local start = active[1]
    for _, index in ipairs(active) do if rooms[index].roleHint == "entrance" then start = index; break end end
    local seen, queue, head = { [start] = true }, { start }, 1
    while head <= #queue do
        local current = queue[head]; head = head + 1
        for _, neighbor in ipairs(adjacency[current] or {}) do
            if not seen[neighbor] then seen[neighbor] = true; queue[#queue + 1] = neighbor end
        end
    end
    for _, index in ipairs(active) do if not seen[index] then return true end end
    return false
end

function StairEditing.RemovePairedStairRooms(rooms, links, stairLink)
    local roomA, roomB = rooms[stairLink.a], rooms[stairLink.b]
    local pairId = roomA and roomA.stairRoom and roomA.stairRoomPairId
        or (roomB and roomB.stairRoom and roomB.stairRoomPairId)
    if not pairId then return false end
    for roomIndex = #rooms, 1, -1 do
        if rooms[roomIndex].stairRoomPairId == pairId then
            for linkIndex = #links, 1, -1 do
                local link = links[linkIndex]
                if link.a == roomIndex or link.b == roomIndex then table.remove(links, linkIndex)
                else
                    if link.a > roomIndex then link.a = link.a - 1 end
                    if link.b > roomIndex then link.b = link.b - 1 end
                end
            end
            table.remove(rooms, roomIndex)
        end
    end
    return true
end

return StairEditing
