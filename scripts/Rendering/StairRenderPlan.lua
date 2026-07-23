local MultiFloor = require("Generation.MultiFloor")

local StairRenderPlan = {}

local function AddSegment(result, a, b, kind, height)
    if not a or not b then return end
    result[#result + 1] = {
        a = { x = a.x, y = a.y },
        b = { x = b.x, y = b.y },
        kind = kind,
        height = height or 0,
    }
end

local function EdgeSegment(edge)
    local x0, y0 = edge.x, edge.y
    if edge.dx ~= 0 then
        local x = x0 + edge.dx * 0.5
        return { x = x, y = y0 - 0.5 }, { x = x, y = y0 + 0.5 }
    end
    local y = y0 + edge.dy * 0.5
    return { x = x0 - 0.5, y = y }, { x = x0 + 0.5, y = y }
end

local function AddEdges(result, edges, kind, height)
    for _, edge in ipairs(edges or {}) do
        local a, b = EdgeSegment(edge)
        AddSegment(result, a, b, kind, height)
    end
end

local function TreadElevationMap(connector)
    local result = {}
    for _, item in ipairs(connector.sweptClearanceCells or {}) do
        result[item.cell] = item.treadElevation
    end
    return result
end

function StairRenderPlan.Build(dungeon, connector)
    local plan = {
        rails = {},
        openingGuards = {},
        wallFinishes = {},
        lightingAnchors = {},
    }
    local treadElevation = TreadElevationMap(connector)
    for _, edge in ipairs(connector.stairRailSegments or {}) do
        local a, b = EdgeSegment(edge)
        AddSegment(plan.rails, a, b, "floor-rail", treadElevation[edge.cell] or 0)
    end
    AddEdges(plan.openingGuards, connector.openingGuardSegments, "opening-guard", connector.rise)
    for _, edge in ipairs(connector.wallFinishSegments or {}) do
        local a, b = EdgeSegment(edge)
        AddSegment(plan.wallFinishes, a, b, "wall-finish", treadElevation[edge.cell] or 0)
    end

    local platform = MultiFloor.StairTurnPlatformMetrics(connector)
    local firstStart = platform and platform.first.start
        or MultiFloor.StairRunCenter(connector.lower, connector.directionVector,
            connector.width, connector.lateralCenterOffset)
    local firstEnd = platform and platform.first.finish
        or MultiFloor.StairRunCenter(connector.upper, connector.directionVector,
            connector.width, connector.lateralCenterOffset)
    plan.lightingAnchors[#plan.lightingAnchors + 1] = {
        x = firstStart.x, y = firstStart.y, elevation = math.min(connector.rise - 0.2, 2.1),
    }
    if platform then
        plan.lightingAnchors[#plan.lightingAnchors + 1] = {
            x = platform.center.x, y = platform.center.y,
            elevation = math.min(connector.rise - 0.2,
                (connector.firstFlightSteps or 0) * connector.stepRise + 2.1),
        }
        plan.lightingAnchors[#plan.lightingAnchors + 1] = {
            x = platform.second.finish.x, y = platform.second.finish.y,
            elevation = math.min(connector.rise - 0.2, connector.rise - 0.6),
        }
    else
        plan.lightingAnchors[#plan.lightingAnchors + 1] = {
            x = firstEnd.x, y = firstEnd.y,
            elevation = math.min(connector.rise - 0.2, connector.rise - 0.6),
        }
    end
    return plan
end

return StairRenderPlan
