local MultiFloor = require("Generation.MultiFloor")
local StairContract = require("Generation.StairContract")

local StairRenderPlan = {}

-- Faithful port of threejs-procedural-dungeon/src/render/stair-style.js.
-- Produces continuous sloped rail runs (not per-edge flat stubs), splits each
-- rail against the real lower-stairwell walls into guardrail / wall-handrail /
-- wall-blocked intervals, resolves L-turn inner/outer corner continuity, and
-- emits guardrail posts and wall-hugging finish strips. Output stays in grid
-- space (x = grid X, y = grid Y) plus elevation; the renderer converts to world.

-- Kit constants (themed recipe is Phase 5; use fixed values that match the
-- reference feel for now).
local KIT = {
    railHeight = 0.95,
    railThickness = 0.06,
    postThickness = 0.07,
    postSpacing = 1.4,
    wallInset = 0.18,
    wallMatchDistance = 0.65,
    wallClearance = 0.1,
    finishHeight = 0.22,
    finishThickness = 0.05,
    surfaceLift = 0.015,
}

local EPSILON = 0.01

local function Hypot(dx, dz)
    return math.sqrt(dx * dx + dz * dz)
end

-- Internal 3D point mirrors the reference {x = gridX, y = elevation, z = gridY}.
local function Point3(point, elevation)
    return { x = point.x, y = elevation, z = point.y }
end

local function ValidRun(start, finish)
    return Hypot(finish.x - start.x, finish.z - start.z) > EPSILON
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

-- Wall faces of the lower stairwell, in grid space, with an interior->wall
-- normal. Derived from the contract's already-classified stairWallSegments.
local function WallEdges(connector)
    local result = {}
    for _, edge in ipairs(connector.stairWallSegments or {}) do
        local a, b = EdgeSegment(edge)
        result[#result + 1] = {
            x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y,
            normal = { x = edge.dx, y = edge.dy },
        }
    end
    return result
end

local function CenterRun(connector, start, finish)
    local dx, dz = finish.x - start.x, finish.z - start.z
    local length = math.max(0.001, Hypot(dx, dz))
    local offset = StairContract.LateralCenterOffset(connector.width, connector.lateralCenterOffset)
    local ox, oz = -dz / length * offset, dx / length * offset
    return
        { x = start.x + ox, y = start.y, z = start.z + oz },
        { x = finish.x + ox, y = finish.y, z = finish.z + oz }
end

local function StairRailRuns(connector, totalRise, platform)
    if not connector.lower or not connector.upper then return {} end
    local rise = math.max(0, tonumber(totalRise) or 0)
    local runs = {}
    local function Push(kind, start, finish, alreadyCentered)
        if not ValidRun(start, finish) then return end
        local s, e = start, finish
        if not alreadyCentered then s, e = CenterRun(connector, start, finish) end
        runs[#runs + 1] = { kind = kind, start = s, finish = e }
    end
    if platform then
        local steps = math.max(1, connector.stepCount or 1)
        local firstSteps = math.max(1, connector.firstFlightSteps or math.floor(steps / 2))
        local turnY = rise * firstSteps / steps
        Push("first-flight", Point3(platform.first.start, 0), Point3(platform.entry, turnY), true)
        Push("second-flight", Point3(platform.exit, turnY), Point3(platform.second.finish, rise), true)
    else
        Push("flight", Point3(connector.lower, 0), Point3(connector.upper, rise))
    end
    return runs
end

local function SideRailSegment(run, side, railOffset, trimStart, trimEnd, kind)
    trimStart = trimStart or 0
    trimEnd = trimEnd or 0
    local dx, dz = run.finish.x - run.start.x, run.finish.z - run.start.z
    local horizontal = math.max(0.001, Hypot(dx, dz))
    local dirx, dirz = dx / horizontal, dz / horizontal
    local perpx, perpz = -dirz, dirx
    local startT = math.min(1, math.max(0, trimStart / horizontal))
    local endT = math.max(startT, math.min(1, 1 - trimEnd / horizontal))
    local function At(t)
        return {
            x = run.start.x + dx * t + perpx * railOffset * side,
            y = run.start.y + (run.finish.y - run.start.y) * t,
            z = run.start.z + dz * t + perpz * railOffset * side,
        }
    end
    return { kind = kind or run.kind, side = side, start = At(startT), finish = At(endT) }
end

local function StairRailSegments(connector, totalRise, railOffset, platform)
    local runs = StairRailRuns(connector, totalRise, platform)
    if not platform then
        local segments = {}
        for _, run in ipairs(runs) do
            segments[#segments + 1] = SideRailSegment(run, -1, railOffset)
            segments[#segments + 1] = SideRailSegment(run, 1, railOffset)
        end
        return segments
    end
    local first, second
    for _, run in ipairs(runs) do
        if run.kind == "first-flight" then first = run
        elseif run.kind == "second-flight" then second = run end
    end
    if not first or not second then
        local segments = {}
        for _, run in ipairs(runs) do
            segments[#segments + 1] = SideRailSegment(run, -1, railOffset)
            segments[#segments + 1] = SideRailSegment(run, 1, railOffset)
        end
        return segments
    end
    local d1 = connector.directionVector or { x = 1, y = 0 }
    local d2 = connector.secondDirectionVector or { x = -d1.y, y = d1.x }
    local turnSign = d1.x * d2.y - d1.y * d2.x
    turnSign = turnSign > 0 and 1 or (turnSign < 0 and -1 or 1)
    local innerSide = turnSign
    local outerSide = -innerSide
    local segments = {}
    for _, run in ipairs(runs) do
        if run ~= first and run ~= second then
            segments[#segments + 1] = SideRailSegment(run, -1, railOffset)
            segments[#segments + 1] = SideRailSegment(run, 1, railOffset)
        end
    end
    local firstOuter = SideRailSegment(first, outerSide, railOffset, 0, 0, "first-flight-outer")
    local firstInner = SideRailSegment(first, innerSide, railOffset, 0, 0, "first-flight-inner")
    local secondOuter = SideRailSegment(second, outerSide, railOffset, 0, 0, "second-flight-outer")
    local secondInner = SideRailSegment(second, innerSide, railOffset, 0, 0, "second-flight-inner")

    local function UnitDir(seg)
        local dx, dz = seg.finish.x - seg.start.x, seg.finish.z - seg.start.z
        local length = math.max(0.001, Hypot(dx, dz))
        return { x = dx / length, z = dz / length }
    end
    -- Inner rails terminate at the intersection of their two edge lines so both
    -- flight rails stay full length while the landing interior stays open.
    local firstInnerDir = UnitDir(first)
    local secondInnerDir = UnitDir(second)
    local function Cross(a, b) return a.x * b.z - a.z * b.x end
    local denominator = Cross(firstInnerDir, secondInnerDir)
    if math.abs(denominator) > 0.001 then
        local between = {
            x = secondInner.start.x - firstInner.finish.x,
            z = secondInner.start.z - firstInner.finish.z,
        }
        local distance = Cross(between, secondInnerDir) / denominator
        local innerCorner = {
            x = firstInner.finish.x + firstInnerDir.x * distance,
            y = first.finish.y,
            z = firstInner.finish.z + firstInnerDir.z * distance,
        }
        firstInner.finish = { x = innerCorner.x, y = innerCorner.y, z = innerCorner.z }
        secondInner.start = { x = innerCorner.x, y = innerCorner.y, z = innerCorner.z }
    end
    segments[#segments + 1] = firstOuter
    segments[#segments + 1] = firstInner
    segments[#segments + 1] = secondOuter
    segments[#segments + 1] = secondInner

    -- Outer rail wraps the platform corner.
    local firstDx, firstDz = first.finish.x - first.start.x, first.finish.z - first.start.z
    local firstLength = math.max(0.001, Hypot(firstDx, firstDz))
    local firstDir = { x = firstDx / firstLength, z = firstDz / firstLength }
    local toSecond = {
        x = secondOuter.start.x - firstOuter.finish.x,
        z = secondOuter.start.z - firstOuter.finish.z,
    }
    local cornerDistance = toSecond.x * firstDir.x + toSecond.z * firstDir.z
    local corner = {
        x = firstOuter.finish.x + firstDir.x * cornerDistance,
        y = firstOuter.finish.y,
        z = firstOuter.finish.z + firstDir.z * cornerDistance,
    }
    segments[#segments + 1] = {
        kind = "turn-platform-outer-first", side = outerSide,
        start = { x = firstOuter.finish.x, y = firstOuter.finish.y, z = firstOuter.finish.z },
        finish = corner,
    }
    segments[#segments + 1] = {
        kind = "turn-platform-outer-second", side = outerSide,
        start = corner,
        finish = { x = secondOuter.start.x, y = secondOuter.start.y, z = secondOuter.start.z },
    }
    return segments
end

local function PointAlongRail(segment, distance, length)
    local t = math.max(0, math.min(1, distance / math.max(0.001, length)))
    return {
        x = segment.start.x + (segment.finish.x - segment.start.x) * t,
        y = segment.start.y + (segment.finish.y - segment.start.y) * t,
        z = segment.start.z + (segment.finish.z - segment.start.z) * t,
    }
end

local function WallCoverageIntervals(segment, wallEdges, matchDistance)
    local dx, dz = segment.finish.x - segment.start.x, segment.finish.z - segment.start.z
    local length = Hypot(dx, dz)
    if length < EPSILON then return {} end
    local dirx, dirz = dx / length, dz / length
    local intervals = {}
    for _, edge in ipairs(wallEdges) do
        local ex, ez = edge.x2 - edge.x1, edge.y2 - edge.y1
        local edgeLength = Hypot(ex, ez)
        if edgeLength >= EPSILON and math.abs(dirx * ez - dirz * ex) / edgeLength <= 0.02 then
            local fromStartX = edge.x1 - segment.start.x
            local fromStartZ = edge.y1 - segment.start.z
            local perpendicular = math.abs(fromStartX * dirz - fromStartZ * dirx)
            if perpendicular <= matchDistance then
                local a = fromStartX * dirx + fromStartZ * dirz
                local b = (edge.x2 - segment.start.x) * dirx + (edge.y2 - segment.start.z) * dirz
                local start = math.max(0, math.min(a, b))
                local finish = math.min(length, math.max(a, b))
                if finish - start > EPSILON then
                    intervals[#intervals + 1] = { start = start, finish = finish, edge = edge }
                end
            end
        end
    end
    table.sort(intervals, function(a, b) return a.start < b.start end)
    local merged = {}
    for _, interval in ipairs(intervals) do
        local previous = merged[#merged]
        if previous and interval.start <= previous.finish + 0.02
            and interval.edge.normal.x == previous.edge.normal.x
            and interval.edge.normal.y == previous.edge.normal.y then
            previous.finish = math.max(previous.finish, interval.finish)
        else
            merged[#merged + 1] = { start = interval.start, finish = interval.finish, edge = interval.edge }
        end
    end
    return merged
end

local function WallCellIntervals(segment, wallEdges, clearance)
    local dx, dz = segment.finish.x - segment.start.x, segment.finish.z - segment.start.z
    local length = Hypot(dx, dz)
    if length < EPSILON then return {} end
    local dir = { x = dx / length, z = dz / length }
    local start3 = { x = segment.start.x, z = segment.start.z }
    local intervals, seen = {}, {}
    for _, edge in ipairs(wallEdges) do
        local normal = edge.normal or { x = 0, y = 0 }
        local center = {
            x = (edge.x1 + edge.x2) / 2 + normal.x * 0.5,
            z = (edge.y1 + edge.y2) / 2 + normal.y * 0.5,
        }
        local key = string.format("%.3f,%.3f", center.x, center.z)
        if not seen[key] then
            seen[key] = true
            local start, finish, hit = 0, length, true
            for _, axis in ipairs({ "x", "z" }) do
                local min = center[axis] - 0.5 - clearance
                local max = center[axis] + 0.5 + clearance
                local origin = start3[axis]
                local velocity = dir[axis]
                if math.abs(velocity) < 1e-9 then
                    if origin < min or origin > max then hit = false end
                else
                    local a = (min - origin) / velocity
                    local b = (max - origin) / velocity
                    start = math.max(start, math.min(a, b))
                    finish = math.min(finish, math.max(a, b))
                end
            end
            if hit and finish - start > EPSILON then
                intervals[#intervals + 1] = { start = start, finish = finish, edge = edge }
            end
        end
    end
    table.sort(intervals, function(a, b) return a.start < b.start end)
    local merged = {}
    for _, interval in ipairs(intervals) do
        local previous = merged[#merged]
        if previous and interval.start <= previous.finish + 0.02 then
            previous.finish = math.max(previous.finish, interval.finish)
        else
            merged[#merged + 1] = { start = interval.start, finish = interval.finish, edge = interval.edge }
        end
    end
    return merged
end

local function WallMountedRailSegment(segment, interval, length, wallInset)
    local normal = interval.edge.normal or { x = 0, y = 0 }
    local start = PointAlongRail(segment, interval.start, length)
    local finish = PointAlongRail(segment, interval.finish, length)
    local edgeX, edgeZ = interval.edge.x1, interval.edge.y1
    local function Shift(point)
        local distance = (edgeX - point.x) * normal.x + (edgeZ - point.z) * normal.y
        return {
            x = point.x + normal.x * (distance - wallInset),
            y = point.y,
            z = point.z + normal.y * (distance - wallInset),
        }
    end
    return {
        kind = segment.kind .. "-wall-handrail",
        side = segment.side,
        protection = "wall-handrail",
        wallNormal = { x = normal.x, y = normal.y },
        wallInset = wallInset,
        start = Shift(start),
        finish = Shift(finish),
    }
end

local function StairRailProtectionSegments(connector, totalRise, railOffset, platform, wallEdges, wallInset)
    local rails = StairRailSegments(connector, totalRise, railOffset, platform)
    if #wallEdges == 0 then
        local result = {}
        for _, segment in ipairs(rails) do
            segment.protection = "guardrail"
            result[#result + 1] = segment
        end
        return result
    end
    local resolved = {}
    for _, segment in ipairs(rails) do
        local length = Hypot(segment.finish.x - segment.start.x, segment.finish.z - segment.start.z)
        local wallIntervals = WallCoverageIntervals(segment, wallEdges, KIT.wallMatchDistance)
        local blockedIntervals = WallCellIntervals(segment, wallEdges, KIT.wallClearance)
        local boundaries = { 0, length }
        for _, interval in ipairs(wallIntervals) do
            boundaries[#boundaries + 1] = interval.start
            boundaries[#boundaries + 1] = interval.finish
        end
        for _, interval in ipairs(blockedIntervals) do
            boundaries[#boundaries + 1] = interval.start
            boundaries[#boundaries + 1] = interval.finish
        end
        table.sort(boundaries)
        local unique = {}
        for index, value in ipairs(boundaries) do
            if index == 1 or value - boundaries[index - 1] > 0.005 then
                unique[#unique + 1] = value
            end
        end
        for index = 1, #unique - 1 do
            local startDistance, endDistance = unique[index], unique[index + 1]
            if endDistance - startDistance > EPSILON then
                local midpoint = (startDistance + endDistance) / 2
                local wall
                for _, interval in ipairs(wallIntervals) do
                    if midpoint >= interval.start - 0.005 and midpoint <= interval.finish + 0.005 then
                        wall = interval
                        break
                    end
                end
                if wall then
                    resolved[#resolved + 1] = WallMountedRailSegment(segment,
                        { edge = wall.edge, start = startDistance, finish = endDistance }, length, wallInset)
                else
                    local blocked = false
                    for _, interval in ipairs(blockedIntervals) do
                        if midpoint >= interval.start - 0.005 and midpoint <= interval.finish + 0.005 then
                            blocked = true
                            break
                        end
                    end
                    resolved[#resolved + 1] = {
                        kind = segment.kind, side = segment.side,
                        protection = blocked and "wall-blocked" or "guardrail",
                        start = PointAlongRail(segment, startDistance, length),
                        finish = PointAlongRail(segment, endDistance, length),
                    }
                end
            end
        end
    end
    return resolved
end

local function RailPostFractions(segment, spacing)
    local horizontal = Hypot(segment.finish.x - segment.start.x, segment.finish.z - segment.start.z)
    if horizontal < EPSILON then return {} end
    local intervals = math.max(1, math.ceil(horizontal / math.max(0.5, spacing)))
    local fractions = {}
    for index = 0, intervals do fractions[#fractions + 1] = index / intervals end
    return fractions
end

-- Convert an internal 3D rail point back to grid + elevation output form.
local function GridPoint(point) return { x = point.x, y = point.z } end

function StairRenderPlan.Build(dungeon, connector)
    local plan = {
        beams = {},        -- guardrail / wall-handrail / opening-guard beams
        posts = {},        -- vertical balusters
        wallFinishes = {}, -- wall-hugging finish strips
        lightingAnchors = {},
    }
    local platform = MultiFloor.StairTurnPlatformMetrics(connector)
    local rise = connector.rise or 0
    local railOffset = (connector.width or 2) / 2 + KIT.railThickness * 0.55
    local wallEdges = WallEdges(connector)

    local function AddBeam(a, b, aElev, bElev, crossW, crossH)
        plan.beams[#plan.beams + 1] = {
            a = GridPoint(a), b = GridPoint(b),
            aElev = aElev, bElev = bElev,
            crossW = crossW or KIT.railThickness, crossH = crossH or KIT.railThickness,
        }
    end
    local function AddPost(point, baseElev)
        plan.posts[#plan.posts + 1] = {
            x = point.x, y = point.z, baseElev = baseElev,
            height = KIT.railHeight, thickness = KIT.postThickness,
        }
    end

    -- Flight rails with wall protection classification.
    local segments = StairRailProtectionSegments(connector, rise, railOffset, platform, wallEdges, KIT.wallInset)
    local postKeys = {}
    for _, segment in ipairs(segments) do
        if segment.protection ~= "wall-blocked" then
            -- Top handrail beam follows the walking-surface slope.
            AddBeam(segment.start, segment.finish,
                segment.start.y + KIT.railHeight, segment.finish.y + KIT.railHeight)
            if segment.protection == "wall-handrail" then
                local normal = segment.wallNormal or { x = 0, y = 0 }
                for _, t in ipairs(RailPostFractions(segment, KIT.postSpacing)) do
                    if t > 0 and t < 1 then
                        local railPoint = {
                            x = segment.start.x + (segment.finish.x - segment.start.x) * t,
                            y = segment.start.y + (segment.finish.y - segment.start.y) * t + KIT.railHeight,
                            z = segment.start.z + (segment.finish.z - segment.start.z) * t,
                        }
                        local wallPoint = {
                            x = railPoint.x + normal.x * (segment.wallInset - 0.035),
                            y = railPoint.y,
                            z = railPoint.z + normal.y * (segment.wallInset - 0.035),
                        }
                        -- Short bracket beam from handrail to wall.
                        AddBeam(railPoint, wallPoint, railPoint.y, wallPoint.y,
                            math.max(0.025, KIT.railThickness * 0.55), math.max(0.025, KIT.railThickness * 0.55))
                    end
                end
            else
                for _, t in ipairs(RailPostFractions(segment, KIT.postSpacing)) do
                    local point = {
                        x = segment.start.x + (segment.finish.x - segment.start.x) * t,
                        y = segment.start.y + (segment.finish.y - segment.start.y) * t,
                        z = segment.start.z + (segment.finish.z - segment.start.z) * t,
                    }
                    local key = string.format("%.3f,%.3f,%.3f", point.x, point.y, point.z)
                    if not postKeys[key] then
                        postKeys[key] = true
                        AddPost(point, point.y)
                    end
                end
            end
        end
    end

    -- Wall-hugging finish strips (only where a wall-handrail exists).
    for _, segment in ipairs(segments) do
        if segment.protection == "wall-handrail" then
            plan.wallFinishes[#plan.wallFinishes + 1] = {
                a = GridPoint(segment.start), b = GridPoint(segment.finish),
                aElev = segment.start.y + KIT.surfaceLift + KIT.finishHeight * 0.5,
                bElev = segment.finish.y + KIT.surfaceLift + KIT.finishHeight * 0.5,
                crossW = KIT.finishThickness, crossH = KIT.finishHeight,
            }
        end
    end

    -- Opening guard rails: flat at the upper floor plane, beam + posts.
    for _, edge in ipairs(connector.openingGuardSegments or {}) do
        local a, b = EdgeSegment(edge)
        AddBeam({ x = a.x, z = a.y }, { x = b.x, z = b.y }, rise + KIT.railHeight, rise + KIT.railHeight)
        local length = Hypot(b.x - a.x, b.y - a.y)
        local divisions = math.max(1, math.ceil(length / math.max(0.25, KIT.postSpacing)))
        for i = 0, divisions do
            local t = i / divisions
            AddPost({ x = a.x + (b.x - a.x) * t, z = a.y + (b.y - a.y) * t }, rise)
        end
    end

    -- Lighting anchors (unchanged contract).
    local firstStart = platform and platform.first.start
        or MultiFloor.StairRunCenter(connector.lower, connector.directionVector,
            connector.width, connector.lateralCenterOffset)
    local firstEnd = platform and platform.first.finish
        or MultiFloor.StairRunCenter(connector.upper, connector.directionVector,
            connector.width, connector.lateralCenterOffset)
    plan.lightingAnchors[#plan.lightingAnchors + 1] = {
        x = firstStart.x, y = firstStart.y, elevation = math.min(rise - 0.2, 2.1),
    }
    if platform then
        plan.lightingAnchors[#plan.lightingAnchors + 1] = {
            x = platform.center.x, y = platform.center.y,
            elevation = math.min(rise - 0.2,
                (connector.firstFlightSteps or 0) * connector.stepRise + 2.1),
        }
        plan.lightingAnchors[#plan.lightingAnchors + 1] = {
            x = platform.second.finish.x, y = platform.second.finish.y,
            elevation = math.min(rise - 0.2, rise - 0.6),
        }
    else
        plan.lightingAnchors[#plan.lightingAnchors + 1] = {
            x = firstEnd.x, y = firstEnd.y,
            elevation = math.min(rise - 0.2, rise - 0.6),
        }
    end
    return plan
end

return StairRenderPlan
