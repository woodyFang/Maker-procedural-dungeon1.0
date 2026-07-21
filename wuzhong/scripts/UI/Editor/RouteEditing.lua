local RouteEditing = {}

-- Editor-only presentation scale. Keep hit testing and generated corridor
-- dimensions on the authored width while displaying a lighter path ribbon.
RouteEditing.CORRIDOR_VISUAL_SCALE = 0.36
RouteEditing.CORRIDOR_MIN_SCREEN_WIDTH = 1.25
RouteEditing.CORRIDOR_MIN_WORLD_WIDTH = 0.175

function RouteEditing.CorridorScreenWidth(authoredWidth, pixelsPerGrid)
    return math.max(RouteEditing.CORRIDOR_MIN_SCREEN_WIDTH,
        (authoredWidth or 2) * pixelsPerGrid * RouteEditing.CORRIDOR_VISUAL_SCALE)
end

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

function RouteEditing.Snap(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

function RouteEditing.CopyPoint(point)
    if not point then return nil end
    return { x = tonumber(point.x) or 0, y = tonumber(point.y) or 0, side = point.side }
end

function RouteEditing.CopyDoor(spec)
    if not spec then return nil end
    return { side = spec.side, offset = tonumber(spec.offset) or 0 }
end

function RouteEditing.DistanceToSegment(px, py, a, b)
    local vx, vy = b.x - a.x, b.y - a.y
    local lengthSquared = vx * vx + vy * vy
    if lengthSquared <= 0.0001 then
        return math.sqrt((px - a.x)^2 + (py - a.y)^2), 0
    end
    local t = Clamp(((px - a.x) * vx + (py - a.y) * vy) / lengthSquared, 0, 1)
    local x, y = a.x + vx * t, a.y + vy * t
    return math.sqrt((px - x)^2 + (py - y)^2), t, x, y
end

function RouteEditing.Simplify(points, epsilon)
    epsilon = epsilon or 0.000001
    local compact = {}
    for _, point in ipairs(points or {}) do
        if point and tonumber(point.x) and tonumber(point.y) then
            local previous = compact[#compact]
            if not previous or math.sqrt((point.x - previous.x)^2 + (point.y - previous.y)^2) > epsilon then
                compact[#compact + 1] = RouteEditing.CopyPoint(point)
            end
        end
    end

    local changed = true
    while changed and #compact > 2 do
        changed = false
        for index = 2, #compact - 1 do
            local a, b, c = compact[index - 1], compact[index], compact[index + 1]
            local sameX = math.abs(a.x - b.x) <= epsilon and math.abs(b.x - c.x) <= epsilon
            local sameY = math.abs(a.y - b.y) <= epsilon and math.abs(b.y - c.y) <= epsilon
            local continuesX = sameX and (b.y - a.y) * (c.y - b.y) >= -epsilon
            local continuesY = sameY and (b.x - a.x) * (c.x - b.x) >= -epsilon
            if continuesX or continuesY then
                table.remove(compact, index)
                changed = true
                break
            end
        end
    end
    return compact
end

function RouteEditing.SnapControlPoint(point, targets, tolerance, excluded)
    local x, y = point.x, point.y
    local distanceX, distanceY = tolerance, tolerance
    local function IsExcluded(target)
        for _, item in ipairs(excluded or {}) do
            if math.abs(item.x - target.x) < 0.000001 and math.abs(item.y - target.y) < 0.000001 then
                return true
            end
        end
        return false
    end
    for _, target in ipairs(targets or {}) do
        if not IsExcluded(target) then
            local dx, dy = math.abs(point.x - target.x), math.abs(point.y - target.y)
            if dx < distanceX then distanceX, x = dx, target.x end
            if dy < distanceY then distanceY, y = dy, target.y end
        end
    end
    return {
        x = RouteEditing.Snap(x), y = RouteEditing.Snap(y),
        snappedX = distanceX < tolerance, snappedY = distanceY < tolerance,
    }
end

function RouteEditing.AdaptBends(bends, fromStart, fromEnd, toStart, toEnd)
    if not bends or #bends == 0 then return {} end
    if not fromStart or not fromEnd or not toStart or not toEnd then
        local copy = {}
        for index, point in ipairs(bends) do copy[index] = RouteEditing.CopyPoint(point) end
        return copy
    end
    local path = { fromStart }
    for _, point in ipairs(bends) do path[#path + 1] = point end
    path[#path + 1] = fromEnd
    ---@type number[]
    local cumulative = { 0 }
    ---@type number
    local total = 0
    for index = 2, #path do
        total = total + math.sqrt((path[index].x - path[index - 1].x)^2 + (path[index].y - path[index - 1].y)^2)
        cumulative[index] = total
    end
    local startDx, startDy = toStart.x - fromStart.x, toStart.y - fromStart.y
    local endDx, endDy = toEnd.x - fromEnd.x, toEnd.y - fromEnd.y
    local result = {}
    for index, point in ipairs(bends) do
        local weight = total > 0.000001 and cumulative[index + 1] / total or index / (#bends + 1)
        result[index] = {
            x = RouteEditing.Snap(point.x + startDx * (1 - weight) + endDx * weight),
            y = RouteEditing.Snap(point.y + startDy * (1 - weight) + endDy * weight),
        }
    end
    return result
end

-- Adapt a complete route while keeping every rendered segment orthogonal.
-- Endpoint movement can make independently interpolated bends diagonal; walk
-- the original segment directions and add one final elbow when the moved door
-- no longer lies on the previous segment axis.
function RouteEditing.AdaptOrthogonalRoute(route, toStart, toEnd)
    if not route or #route < 2 or not toStart or not toEnd then return {} end
    local fromStart, fromEnd = route[1], route[#route]
    local bends = {}
    for index = 2, #route - 1 do bends[#bends + 1] = RouteEditing.CopyPoint(route[index]) end
    local adapted = RouteEditing.AdaptBends(bends, fromStart, fromEnd, toStart, toEnd)
    local result = { RouteEditing.CopyPoint(toStart) }
    for index, point in ipairs(adapted) do
        local oldA, oldB = route[index], route[index + 1]
        local previous = result[#result]
        local nextPoint = RouteEditing.CopyPoint(point)
        if math.abs(oldB.x - oldA.x) >= math.abs(oldB.y - oldA.y) then
            nextPoint.y = previous.y
        else
            nextPoint.x = previous.x
        end
        result[#result + 1] = nextPoint
    end
    local previous = result[#result]
    if math.abs(previous.x - toEnd.x) > 0.000001 and math.abs(previous.y - toEnd.y) > 0.000001 then
        local oldA, oldB = route[#route - 1], route[#route]
        if math.abs(oldB.x - oldA.x) >= math.abs(oldB.y - oldA.y) then
            result[#result + 1] = { x = toEnd.x, y = previous.y }
        else
            result[#result + 1] = { x = previous.x, y = toEnd.y }
        end
    end
    result[#result + 1] = RouteEditing.CopyPoint(toEnd)
    return RouteEditing.Simplify(result)
end

function RouteEditing.CorridorCenterOffset(width)
    return RouteEditing.Snap(width or 2) == 2 and 0.5 or 0
end

return RouteEditing
