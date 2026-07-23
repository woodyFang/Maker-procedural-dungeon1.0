local StairContract = {}

StairContract.GRID_SIZE = 1.0
StairContract.MIN_WIDTH = 1
StairContract.MAX_WIDTH = 5
StairContract.WIDTH_STEP = 1
StairContract.REQUIRED_HEADROOM = 2.5
StairContract.EPSILON = 0.000001

local DIRECTIONS = {
    east = { x = 1, y = 0, name = "east", next = "south" },
    south = { x = 0, y = 1, name = "south", next = "west" },
    west = { x = -1, y = 0, name = "west", next = "north" },
    north = { x = 0, y = -1, name = "north", next = "east" },
}

local CARDINALS = {
    DIRECTIONS.east, DIRECTIONS.west, DIRECTIONS.south, DIRECTIONS.north,
}

local function Round(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

local function Index(x, y, width)
    return y * width + x + 1
end

local function Coordinates(index, width)
    local zero = index - 1
    return zero % width, math.floor(zero / width)
end

local function InBounds(x, y, width, height)
    return x >= 0 and y >= 0 and x < width and y < height
end

local function CopyPoint(point)
    return point and { x = point.x, y = point.y } or nil
end

local function CellSet(cells)
    local result = {}
    for _, cell in ipairs(cells or {}) do result[cell] = true end
    return result
end

local function UniqueCells(...)
    local result, seen = {}, {}
    for _, group in ipairs({ ... }) do
        for _, cell in ipairs(group or {}) do
            if not seen[cell] then
                seen[cell] = true
                result[#result + 1] = cell
            end
        end
    end
    table.sort(result)
    return result
end

function StairContract.NormalizeStyle(style)
    return style == "straight" and "straight" or "l-turn"
end

function StairContract.Direction(value)
    if type(value) == "table" and tonumber(value.x) and tonumber(value.y) then
        local name = value.name
        if not name then
            if value.x == 1 and value.y == 0 then name = "east"
            elseif value.x == -1 and value.y == 0 then name = "west"
            elseif value.x == 0 and value.y == 1 then name = "south"
            elseif value.x == 0 and value.y == -1 then name = "north" end
        end
        return DIRECTIONS[name]
    end
    return DIRECTIONS[tostring(value or "")]
end

function StairContract.Directions()
    return CARDINALS
end

function StairContract.NormalizeWidth(width)
    local value = tonumber(width) or 2
    local snapped = math.floor(value / StairContract.WIDTH_STEP + 0.5) * StairContract.WIDTH_STEP
    return math.max(StairContract.MIN_WIDTH, math.min(StairContract.MAX_WIDTH, snapped))
end

function StairContract.NormalizeLandingDepth(depth)
    return math.max(1, math.min(4, Round(depth or 2)))
end

function StairContract.GridSpan(width)
    return StairContract.NormalizeWidth(width)
end

function StairContract.LateralCenterOffset(width, preservedOffset)
    if tonumber(preservedOffset) then return tonumber(preservedOffset) end
    return StairContract.GridSpan(width) % 2 == 0 and 0.5 or 0
end

function StairContract.WidthOffsets(width, lateralCenterOffset)
    width = StairContract.GridSpan(width)
    local result = {}
    local first = tonumber(lateralCenterOffset)
        and math.floor(tonumber(lateralCenterOffset) - (width - 1) * 0.5 + 0.5)
        or -math.floor((width - 1) * 0.5)
    for offset = first, first + width - 1 do result[#result + 1] = offset end
    return result
end

function StairContract.RunCenter(point, directionValue, stairWidth, lateralCenterOffset)
    local direction = StairContract.Direction(directionValue)
    if not point or not direction then return nil end
    local offset = StairContract.LateralCenterOffset(stairWidth, lateralCenterOffset)
    return { x = point.x - direction.y * offset, y = point.y + direction.x * offset }
end

function StairContract.Endpoints(lower, directionValue, run, style)
    local direction = StairContract.Direction(directionValue)
    if not lower or not direction then return nil end
    run = math.max(6, Round(run or 8))
    style = StairContract.NormalizeStyle(style)
    if style == "straight" then
        return {
            style = style,
            lower = CopyPoint(lower),
            turn = nil,
            upper = { x = lower.x + direction.x * run, y = lower.y + direction.y * run },
            direction = direction,
            secondDirection = direction,
            firstRun = run,
            secondRun = 0,
        }
    end
    local firstRun = math.max(3, math.floor(run * 0.5))
    local secondRun = math.max(3, run - firstRun)
    local secondDirection = DIRECTIONS[direction.next]
    local turn = { x = lower.x + direction.x * firstRun, y = lower.y + direction.y * firstRun }
    return {
        style = style,
        lower = CopyPoint(lower),
        turn = turn,
        upper = {
            x = turn.x + secondDirection.x * secondRun,
            y = turn.y + secondDirection.y * secondRun,
        },
        direction = direction,
        secondDirection = secondDirection,
        firstRun = firstRun,
        secondRun = secondRun,
    }
end

function StairContract.TurnPlatformMetrics(connector)
    if not connector or not connector.turn then return nil end
    local first = StairContract.Direction(connector.directionVector or connector.direction)
    local second = StairContract.Direction(connector.secondDirectionVector or connector.secondDirection)
    if not first or not second then return nil end
    local firstRun = math.max(0, tonumber(connector.firstRun) or 0)
    local secondRun = math.max(0, tonumber(connector.secondRun) or 0)
    local visualWidth = StairContract.NormalizeWidth(connector.width)
    local offset = StairContract.LateralCenterOffset(visualWidth, connector.lateralCenterOffset)
    local firstStart = StairContract.RunCenter(connector.lower or connector.turn, first, visualWidth, offset)
    local entry = { x = firstStart.x + first.x * firstRun, y = firstStart.y + first.y * firstRun }
    local center = {
        x = entry.x + first.x * visualWidth * 0.5,
        y = entry.y + first.y * visualWidth * 0.5,
    }
    local exitPoint = {
        x = center.x + second.x * visualWidth * 0.5,
        y = center.y + second.y * visualWidth * 0.5,
    }
    local secondEnd = {
        x = exitPoint.x + second.x * secondRun,
        y = exitPoint.y + second.y * secondRun,
    }
    return {
        center = center,
        entry = entry,
        exit = exitPoint,
        first = { start = firstStart, finish = entry, direction = first, length = firstRun },
        second = { start = exitPoint, finish = secondEnd, direction = second, length = secondRun },
        visualSpan = visualWidth,
        gridSpan = StairContract.GridSpan(visualWidth),
        offset = offset,
    }
end

function StairContract.VisualUpperCell(point, directionValue)
    local direction = StairContract.Direction(directionValue)
    if not point or not direction then return nil end
    local function AlongCell(value, axis)
        if axis > 0 then return math.ceil(value - StairContract.EPSILON) end
        if axis < 0 then return math.floor(value + StairContract.EPSILON) end
        return math.floor(value + 0.5)
    end
    return { x = AlongCell(point.x, direction.x), y = AlongCell(point.y, direction.y) }
end

local function StripCells(width, height, from, direction, firstStep, lastStep, stairWidth, lateralCenterOffset)
    local cells = {}
    local perpendicular = { x = -direction.y, y = direction.x }
    for step = firstStep, lastStep do
        for _, offset in ipairs(StairContract.WidthOffsets(stairWidth, lateralCenterOffset)) do
            local x = from.x + direction.x * step + perpendicular.x * offset
            local y = from.y + direction.y * step + perpendicular.y * offset
            if not InBounds(x, y, width, height) then return nil end
            cells[#cells + 1] = Index(x, y, width)
        end
    end
    return cells
end

local function StripCellsWithOffsets(width, height, from, direction, firstStep, lastStep, offsets)
    local cells = {}
    local perpendicular = { x = -direction.y, y = direction.x }
    for step = firstStep, lastStep do
        for _, offset in ipairs(offsets) do
            local x = from.x + direction.x * step + perpendicular.x * offset
            local y = from.y + direction.y * step + perpendicular.y * offset
            if not InBounds(x, y, width, height) then return nil end
            cells[#cells + 1] = Index(x, y, width)
        end
    end
    return cells
end

local function VisualStripCells(width, height, startPoint, endPoint, visualWidth)
    if not startPoint or not endPoint then return nil end
    local span, result = StairContract.GridSpan(visualWidth), {}
    if math.abs(endPoint.x - startPoint.x) >= math.abs(endPoint.y - startPoint.y) then
        local firstX = math.ceil(math.min(startPoint.x, endPoint.x) - StairContract.EPSILON)
        local lastX = math.ceil(math.max(startPoint.x, endPoint.x) - StairContract.EPSILON) - 1
        local firstY = math.ceil((startPoint.y + endPoint.y) * 0.5 - visualWidth * 0.5 - StairContract.EPSILON)
        for y = firstY, firstY + span - 1 do
            for x = firstX, lastX do
                if not InBounds(x, y, width, height) then return nil end
                result[#result + 1] = Index(x, y, width)
            end
        end
    else
        local firstY = math.ceil(math.min(startPoint.y, endPoint.y) - StairContract.EPSILON)
        local lastY = math.ceil(math.max(startPoint.y, endPoint.y) - StairContract.EPSILON) - 1
        local firstX = math.ceil((startPoint.x + endPoint.x) * 0.5 - visualWidth * 0.5 - StairContract.EPSILON)
        for y = firstY, lastY do
            for x = firstX, firstX + span - 1 do
                if not InBounds(x, y, width, height) then return nil end
                result[#result + 1] = Index(x, y, width)
            end
        end
    end
    return result
end

local function PlatformCells(width, height, platform)
    if not platform then return nil end
    local firstX = math.ceil(platform.center.x - platform.visualSpan * 0.5 - StairContract.EPSILON)
    local firstY = math.ceil(platform.center.y - platform.visualSpan * 0.5 - StairContract.EPSILON)
    local result = {}
    for y = firstY, firstY + platform.gridSpan - 1 do
        for x = firstX, firstX + platform.gridSpan - 1 do
            if not InBounds(x, y, width, height) then return nil end
            result[#result + 1] = Index(x, y, width)
        end
    end
    return result
end

local function RectangularEnvelope(cells, width, height)
    if not cells or #cells == 0 then return nil end
    local minX, maxX, minY, maxY = width - 1, 0, height - 1, 0
    for _, cell in ipairs(cells) do
        local x, y = Coordinates(cell, width)
        minX, maxX = math.min(minX, x), math.max(maxX, x)
        minY, maxY = math.min(minY, y), math.max(maxY, y)
    end
    local result = {}
    for y = minY, maxY do
        for x = minX, maxX do result[#result + 1] = Index(x, y, width) end
    end
    return result
end

-- Continuous per-cell swept clearance, ported from the reference
-- stairSweptClearanceCells: each tread cell's walking-surface elevation is the
-- projected distance along its flight axis, scaled by the flight's rise share.
-- The slab opening is the slice whose 2.5m headroom column crosses the upper
-- floor plane; treads that already reached the upper plane are arrival floor.
local function BuildSweptClearance(params)
    local width = params.mapWidth
    local floorHeight = tonumber(params.floorHeight) or 5.0
    local headroom = tonumber(params.headroom) or StairContract.REQUIRED_HEADROOM
    local style = params.style
    local lower = params.lower
    local direction = params.direction
    local secondDirection = params.secondDirection
    local firstRun = math.max(1, params.firstRun or 1)
    local secondRun = math.max(1, params.secondRun or 1)
    local cap = style == "l-turn" and 0.5 or 1

    local function Projected(cell, origin, axis)
        local px, py = Coordinates(cell, width)
        return (px - origin.x) * axis.x + (py - origin.y) * axis.y
    end
    local function FirstFraction(cell)
        local frac = ((Projected(cell, lower, direction) + 0.5) / firstRun) * cap
        return math.max(0, math.min(cap, frac))
    end
    local secondOrigin = style == "l-turn"
        and { x = lower.x + direction.x * firstRun, y = lower.y + direction.y * firstRun } or nil
    local function SecondFraction(cell)
        local frac = 0.5 + ((Projected(cell, secondOrigin, secondDirection) + 0.5) / secondRun) * 0.5
        return math.max(0.5, math.min(1, frac))
    end

    local elevations = {}
    local function Record(cells, fractionFn, fixed)
        for _, cell in ipairs(cells or {}) do
            local elevation = (fixed or fractionFn(cell)) * floorHeight
            if not elevations[cell] or elevation > elevations[cell] then
                elevations[cell] = elevation
            end
        end
    end
    Record(params.firstFlightCells, FirstFraction)
    if style == "l-turn" then
        Record(params.turnCells, nil, 0.5)
        Record(params.secondFlightCells, SecondFraction)
    end

    local ordered = {}
    for cell in pairs(elevations) do ordered[#ordered + 1] = cell end
    table.sort(ordered)
    local swept, opening, headroomCells = {}, {}, {}
    for _, cell in ipairs(ordered) do
        local treadElevation = elevations[cell]
        local clearanceTop = treadElevation + headroom
        local belowUpper = treadElevation < floorHeight - StairContract.EPSILON
        local intersects = belowUpper and clearanceTop > floorHeight + StairContract.EPSILON
        swept[#swept + 1] = {
            cell = cell, treadElevation = treadElevation, clearanceTop = clearanceTop,
            intersectsUpperSlab = intersects,
        }
        headroomCells[#headroomCells + 1] = cell
        if intersects then opening[#opening + 1] = cell end
    end
    return swept, opening, headroomCells
end

local function BoundaryEdges(cells, width, height)
    local set, result = CellSet(cells), {}
    for _, cell in ipairs(cells or {}) do
        local x, y = Coordinates(cell, width)
        for _, direction in ipairs(CARDINALS) do
            local nx, ny = x + direction.x, y + direction.y
            local neighbor = InBounds(nx, ny, width, height) and Index(nx, ny, width) or nil
            if not neighbor or not set[neighbor] then
                result[#result + 1] = {
                    cell = cell,
                    neighbor = neighbor,
                    x = x,
                    y = y,
                    nx = nx,
                    ny = ny,
                    dx = direction.x,
                    dy = direction.y,
                    direction = direction.name,
                    key = string.format("%d:%s", cell, direction.name),
                }
            end
        end
    end
    table.sort(result, function(a, b) return a.key < b.key end)
    return result
end

local function ClassifyOpeningEdges(contract)
    local shaftSet = CellSet(contract.shaftCells)
    local upperLandingSet = CellSet(contract.upperLandingCells)
    local access, passage, unresolved = {}, {}, {}
    local forwardCandidates, backwardCandidates = {}, {}
    for _, edge in ipairs(contract.openingBoundaryEdges or {}) do
        local dot = edge.dx * contract.secondDirection.x + edge.dy * contract.secondDirection.y
        if dot > 0 then forwardCandidates[#forwardCandidates + 1] = edge end
        if dot < 0 then backwardCandidates[#backwardCandidates + 1] = edge end
        if edge.neighbor and upperLandingSet[edge.neighbor] and dot > 0 then
            access[#access + 1] = edge
        elseif edge.neighbor and shaftSet[edge.neighbor] then
            passage[#passage + 1] = edge
        else
            unresolved[#unresolved + 1] = edge
        end
    end

    local function Promote(source, target)
        if #target > 0 or #source == 0 then return end
        table.sort(source, function(a, b)
            local aa = a.x * contract.secondDirection.x + a.y * contract.secondDirection.y
            local bb = b.x * contract.secondDirection.x + b.y * contract.secondDirection.y
            return aa == bb and a.key < b.key or aa > bb
        end)
        local extreme = source[1].x * contract.secondDirection.x
            + source[1].y * contract.secondDirection.y
        for index = #unresolved, 1, -1 do
            local edge = unresolved[index]
            local along = edge.x * contract.secondDirection.x + edge.y * contract.secondDirection.y
            if math.abs(along - extreme) < StairContract.EPSILON then
                target[#target + 1] = edge
                table.remove(unresolved, index)
            end
        end
    end
    Promote(forwardCandidates, access)
    if #passage == 0 and #backwardCandidates > 0 then
        table.sort(backwardCandidates, function(a, b)
            local aa = a.x * contract.secondDirection.x + a.y * contract.secondDirection.y
            local bb = b.x * contract.secondDirection.x + b.y * contract.secondDirection.y
            return aa == bb and a.key < b.key or aa < bb
        end)
        local extreme = backwardCandidates[1].x * contract.secondDirection.x
            + backwardCandidates[1].y * contract.secondDirection.y
        for index = #unresolved, 1, -1 do
            local edge = unresolved[index]
            local along = edge.x * contract.secondDirection.x + edge.y * contract.secondDirection.y
            if math.abs(along - extreme) < StairContract.EPSILON
                and edge.dx * contract.secondDirection.x + edge.dy * contract.secondDirection.y < 0 then
                passage[#passage + 1] = edge
                table.remove(unresolved, index)
            end
        end
    end
    return access, passage, unresolved
end

local function ClassifyStairwellEdges(contract)
    local lowerLandingSet = CellSet(contract.lowerLandingCells)
    local upperLandingSet = CellSet(contract.upperLandingCells)
    local access, unresolved = {}, {}
    for _, edge in ipairs(contract.stairwellBoundaryEdges or {}) do
        local firstDot = edge.dx * contract.direction.x + edge.dy * contract.direction.y
        local secondDot = edge.dx * contract.secondDirection.x + edge.dy * contract.secondDirection.y
        local isLower = lowerLandingSet[edge.cell] and firstDot < 0 or false
        local isUpper = upperLandingSet[edge.cell] and secondDot > 0 or false
        if isLower or isUpper then
            edge.lowerAccess = isLower or nil
            edge.upperAccess = isUpper or nil
            access[#access + 1] = edge
        else
            unresolved[#unresolved + 1] = edge
        end
    end
    return access, unresolved
end

function StairContract.Build(options)
    options = options or {}
    local width, height = assert(options.mapWidth), assert(options.mapHeight)
    local direction = StairContract.Direction(options.direction)
    if not direction or not options.lower then return nil, "invalid-direction-or-anchor" end
    local stairWidth = StairContract.NormalizeWidth(options.width)
    local run = math.max(6, Round(options.run or 8))
    local landingDepth = StairContract.NormalizeLandingDepth(options.landingDepth)
    local style = StairContract.NormalizeStyle(options.style)
    local endpoints = StairContract.Endpoints(options.lower, direction, run, style)
    local offset = StairContract.LateralCenterOffset(stairWidth, options.lateralCenterOffset)
    local platform = style == "l-turn" and StairContract.TurnPlatformMetrics({
        lower = endpoints.lower,
        turn = endpoints.turn,
        direction = direction.name,
        secondDirection = endpoints.secondDirection.name,
        firstRun = endpoints.firstRun,
        secondRun = endpoints.secondRun,
        width = stairWidth,
        lateralCenterOffset = offset,
    }) or nil
    local upper = platform and StairContract.VisualUpperCell(platform.second.finish, endpoints.secondDirection)
        or endpoints.upper
    local lowerApproach = {
        x = endpoints.lower.x - direction.x * landingDepth,
        y = endpoints.lower.y - direction.y * landingDepth,
    }
    local upperApproach = {
        x = upper.x + endpoints.secondDirection.x * landingDepth,
        y = upper.y + endpoints.secondDirection.y * landingDepth,
    }
    local firstFlight = StripCells(width, height, endpoints.lower, direction,
        1, endpoints.firstRun - 1, stairWidth, offset)
    local secondFlight = style == "l-turn" and VisualStripCells(width, height,
        platform.exit, platform.second.finish, stairWidth) or {}
    local turnCells = style == "l-turn" and PlatformCells(width, height, platform) or {}
    local lowerLanding = StripCells(width, height, endpoints.lower, direction,
        -landingDepth, 0, stairWidth, offset)
    local upperLanding = platform and VisualStripCells(width, height,
        { x = platform.second.finish.x - endpoints.secondDirection.x,
            y = platform.second.finish.y - endpoints.secondDirection.y },
        { x = platform.second.finish.x + endpoints.secondDirection.x * (landingDepth + 1),
            y = platform.second.finish.y + endpoints.secondDirection.y * (landingDepth + 1) },
        stairWidth)
        or StripCells(width, height, upper, endpoints.secondDirection,
            0, landingDepth, stairWidth, offset)
    if not firstFlight or not secondFlight or not turnCells or not lowerLanding or not upperLanding then
        return nil, "stair-out-of-bounds"
    end

    local shaft = UniqueCells(firstFlight, turnCells, secondFlight)
    local firstFlightCells = UniqueCells(firstFlight)
    local secondFlightCells = UniqueCells(secondFlight)
    local turnPlatformCells = UniqueCells(turnCells)

    local floorHeight = tonumber(options.floorHeight) or 5.0
    local stepCount = math.max(1, Round(options.stepCount or math.ceil(floorHeight / 0.25)))
    local firstSteps = style == "straight" and stepCount or math.floor(stepCount * endpoints.firstRun / run + 0.5)
    if style == "l-turn" then firstSteps = math.max(1, math.min(stepCount - 1, firstSteps)) end
    local secondSteps = style == "straight" and 0 or stepCount - firstSteps

    local swept, opening, headroomCells = BuildSweptClearance({
        firstFlightCells = firstFlightCells,
        turnCells = turnPlatformCells,
        secondFlightCells = secondFlightCells,
        lower = endpoints.lower,
        direction = { x = direction.x, y = direction.y },
        secondDirection = { x = endpoints.secondDirection.x, y = endpoints.secondDirection.y },
        firstRun = endpoints.firstRun,
        secondRun = endpoints.secondRun,
        style = style,
        mapWidth = width,
        floorHeight = floorHeight,
        headroom = options.headroom,
    })
    local openingSet = CellSet(opening)
    -- Treads that already reached the upper plane are arrival floor, not shaft:
    -- fold them into the upper landing and keep them out of the opening.
    local upperArrival = {}
    for _, record in ipairs(swept) do
        if record.treadElevation >= floorHeight - StairContract.EPSILON then
            upperArrival[#upperArrival + 1] = record.cell
        end
    end
    local upperLandingCells = {}
    for _, cell in ipairs(UniqueCells(upperLanding, upperArrival)) do
        if not openingSet[cell] then upperLandingCells[#upperLandingCells + 1] = cell end
    end
    local lowerLandingCells = UniqueCells(lowerLanding)
    local interior = UniqueCells(lowerLandingCells, shaft, upperLandingCells)

    local sideClearance = math.max(0, Round(options.sideClearance or 0))
    local offsets = StairContract.WidthOffsets(stairWidth, offset)
    local footprintOffsets = {}
    for value = offsets[1] - sideClearance, offsets[#offsets] + sideClearance do
        footprintOffsets[#footprintOffsets + 1] = value
    end
    local firstFootprint = StripCellsWithOffsets(width, height, endpoints.lower, direction,
        -landingDepth, endpoints.firstRun, footprintOffsets)
    local secondFootprint = style == "l-turn" and VisualStripCells(width, height, platform.exit,
        { x = platform.second.finish.x + endpoints.secondDirection.x * landingDepth,
            y = platform.second.finish.y + endpoints.secondDirection.y * landingDepth },
        stairWidth + sideClearance * 2)
        or StripCellsWithOffsets(width, height, upper, endpoints.secondDirection,
            0, landingDepth, footprintOffsets)
    if not firstFootprint or not secondFootprint then return nil, "stair-footprint-out-of-bounds" end
    -- Include the full stairwell interior so the reservation envelope covers L
    -- platforms that extend beyond the raw strips (prevents a later stair from
    -- overwriting an existing opening).
    local footprint = RectangularEnvelope(UniqueCells(firstFootprint, secondFootprint, interior), width, height)
    if not footprint then return nil, "stair-footprint-out-of-bounds" end

    local contract = {
        schemaVersion = 1,
        style = style,
        lower = CopyPoint(endpoints.lower),
        turn = CopyPoint(endpoints.turn),
        upper = CopyPoint(upper),
        lowerApproach = lowerApproach,
        upperApproach = upperApproach,
        lowerApproachGate = CopyPoint(lowerApproach),
        upperApproachGate = CopyPoint(upperApproach),
        direction = direction,
        secondDirection = endpoints.secondDirection,
        run = run,
        firstRun = endpoints.firstRun,
        secondRun = endpoints.secondRun,
        width = stairWidth,
        lateralCenterOffset = offset,
        landingDepth = landingDepth,
        sideClearance = sideClearance,
        wallMode = options.wallMode or "wall-backed",
        turnPlatform = platform,
        firstVisualStart = platform and platform.first.start
            or StairContract.RunCenter(endpoints.lower, direction, stairWidth, offset),
        secondVisualStart = platform and platform.second.start or nil,
        firstFlightSteps = firstSteps,
        secondFlightSteps = secondSteps,
        stepCount = stepCount,
        stepRise = floorHeight / stepCount,
        firstFlightCells = firstFlightCells,
        secondFlightCells = secondFlightCells,
        turnPlatformCells = turnPlatformCells,
        shaftCells = shaft,
        stairFootprintCells = shaft,
        lowerLandingCells = lowerLandingCells,
        upperLandingCells = upperLandingCells,
        stairwellInteriorCells = interior,
        sharedFootprintCells = footprint,
        sweptClearanceCells = swept,
        openingCells = opening,
        slabOpeningCells = opening,
        headroomCells = headroomCells,
    }
    contract.openingBoundaryEdges = BoundaryEdges(contract.openingCells, width, height)
    contract.stairwellBoundaryEdges = BoundaryEdges(contract.stairwellInteriorCells, width, height)
    contract.openingAccessEdges, contract.openingStairPassageEdges,
        contract.openingUnresolvedEdges = ClassifyOpeningEdges(contract)
    contract.stairwellAccessEdges, contract.stairwellUnresolvedEdges = ClassifyStairwellEdges(contract)
    contract.lowerNoWallCells = UniqueCells(contract.stairwellInteriorCells, contract.lowerLandingCells)
    contract.upperNoWallCells = UniqueCells(contract.stairwellInteriorCells,
        contract.upperLandingCells, contract.openingCells)
    -- 2.7 validity gate: reject degenerate contracts the renderer/audit cannot use.
    local hasLowerAccess, hasUpperAccess = false, false
    for _, edge in ipairs(contract.stairwellAccessEdges) do
        if edge.lowerAccess then hasLowerAccess = true end
        if edge.upperAccess then hasUpperAccess = true end
    end
    if #contract.openingCells == 0 or #contract.openingBoundaryEdges == 0
        or #contract.stairwellBoundaryEdges == 0 or not hasLowerAccess or not hasUpperAccess then
        return nil, "degenerate-stair-contract"
    end
    return contract
end

local function IsWall(layer, cell, tiles)
    return cell and layer and layer.grid and layer.grid[cell] == tiles.WALL
end

function StairContract.FinalizeProtection(contract, lowerLayer, upperLayer, tiles)
    contract.openingWallSegments, contract.openingGuardSegments = {}, {}
    for _, edge in ipairs(contract.openingUnresolvedEdges or {}) do
        if IsWall(upperLayer, edge.neighbor, tiles) then
            contract.openingWallSegments[#contract.openingWallSegments + 1] = edge
        else
            contract.openingGuardSegments[#contract.openingGuardSegments + 1] = edge
        end
    end

    contract.stairWallSegments, contract.stairRailSegments = {}, {}
    for _, edge in ipairs(contract.stairwellUnresolvedEdges or {}) do
        local wall = IsWall(lowerLayer, edge.neighbor, tiles) or IsWall(upperLayer, edge.neighbor, tiles)
        if wall then contract.stairWallSegments[#contract.stairWallSegments + 1] = edge
        else contract.stairRailSegments[#contract.stairRailSegments + 1] = edge end
    end

    local doubleSet, lowerSet, upperSet = {}, {}, {}
    local openingSet = CellSet(contract.openingCells)
    for _, edge in ipairs(contract.stairWallSegments) do
        if edge.neighbor then
            if openingSet[edge.cell] or openingSet[edge.neighbor] then
                doubleSet[edge.neighbor] = true
            elseif IsWall(lowerLayer, edge.neighbor, tiles) then
                lowerSet[edge.neighbor] = true
            elseif IsWall(upperLayer, edge.neighbor, tiles) then
                upperSet[edge.neighbor] = true
            end
        end
    end
    contract.doubleHeightWallCells = {}
    contract.lowerSingleHeightWallCells = {}
    contract.upperSingleHeightWallCells = {}
    for cell in pairs(doubleSet) do contract.doubleHeightWallCells[#contract.doubleHeightWallCells + 1] = cell end
    for cell in pairs(lowerSet) do
        if not doubleSet[cell] then contract.lowerSingleHeightWallCells[#contract.lowerSingleHeightWallCells + 1] = cell end
    end
    for cell in pairs(upperSet) do
        if not doubleSet[cell] then contract.upperSingleHeightWallCells[#contract.upperSingleHeightWallCells + 1] = cell end
    end
    table.sort(contract.doubleHeightWallCells)
    table.sort(contract.lowerSingleHeightWallCells)
    table.sort(contract.upperSingleHeightWallCells)
    contract.wallFinishSegments = contract.stairWallSegments
    return contract
end

local function SameCellSet(a, b)
    local left, right = CellSet(a), CellSet(b)
    for cell in pairs(left) do if not right[cell] then return false end end
    for cell in pairs(right) do if not left[cell] then return false end end
    return true
end

local function AddReason(audit, code)
    audit.reasons[#audit.reasons + 1] = code
end

function StairContract.Audit(contract, lowerLayer, upperLayer, tiles)
    local audit = {
        contractComplete = true,
        traversable = true,
        slabsComplete = true,
        wallsComplete = true,
        reachable = false,
        pass = false,
        reasons = {},
    }
    local required = {
        "shaftCells", "headroomCells", "sweptClearanceCells", "openingCells",
        "sharedFootprintCells", "stairwellInteriorCells", "lowerLandingCells",
        "upperLandingCells", "openingBoundaryEdges", "stairwellBoundaryEdges",
        "openingAccessEdges", "openingStairPassageEdges", "openingWallSegments",
        "openingGuardSegments", "stairRailSegments",
    }
    for _, key in ipairs(required) do
        if type(contract and contract[key]) ~= "table" then
            audit.contractComplete = false
            AddReason(audit, "missing-" .. key)
        end
    end
    if not lowerLayer or not upperLayer then
        audit.contractComplete = false
        AddReason(audit, "missing-layer")
        return audit
    end

    for _, cell in ipairs(contract.shaftCells or {}) do
        if lowerLayer.grid[cell] ~= tiles.FLOOR or not lowerLayer.stairMask[cell] then
            audit.traversable = false
            AddReason(audit, "lower-tread-blocked")
            break
        end
    end
    for _, cells in ipairs({ contract.lowerLandingCells or {}, contract.upperLandingCells or {} }) do
        local isLower = cells == contract.lowerLandingCells
        local layer = isLower and lowerLayer or upperLayer
        for _, cell in ipairs(cells) do
            local belongsToOtherStair = layer.stairOwner and layer.stairOwner[cell]
                and layer.stairOwner[cell] ~= contract.ownerId
            local floorUsable = layer.grid[cell] == tiles.FLOOR or belongsToOtherStair
            if not floorUsable or (not layer.stairLanding[cell] and not belongsToOtherStair) then
                audit.traversable = false
                AddReason(audit, "landing-blocked")
                break
            end
        end
    end

    local actualOpening = {}
    for cell in pairs(upperLayer.slabOpening or {}) do
        if upperLayer.stairOwner and upperLayer.stairOwner[cell] == contract.ownerId then
            actualOpening[#actualOpening + 1] = cell
        end
    end
    for _, cell in ipairs(contract.openingCells or {}) do
        if lowerLayer.slabOpening[cell] or upperLayer.grid[cell] ~= tiles.VOID
            or not upperLayer.slabOpening[cell] then
            audit.slabsComplete = false
            AddReason(audit, "opening-mismatch")
            break
        end
    end
    if contract.ownerId and not SameCellSet(actualOpening, contract.openingCells) then
        audit.slabsComplete = false
        AddReason(audit, "opening-extra-or-missing")
    end
    local openingSet = CellSet(contract.openingCells)
    for _, cell in ipairs(contract.shaftCells or {}) do
        if not openingSet[cell] and upperLayer.slabOpening[cell]
            and (not upperLayer.stairOwner or upperLayer.stairOwner[cell] == contract.ownerId) then
            audit.slabsComplete = false
            AddReason(audit, "low-tread-slab-removed")
            break
        end
    end

    for _, cell in ipairs(contract.lowerNoWallCells or {}) do
        if lowerLayer.grid[cell] == tiles.WALL then
            audit.wallsComplete = false
            AddReason(audit, "lower-no-wall-violated")
            break
        end
    end
    for _, cell in ipairs(contract.upperNoWallCells or {}) do
        if upperLayer.grid[cell] == tiles.WALL then
            audit.wallsComplete = false
            AddReason(audit, "upper-no-wall-violated")
            break
        end
    end
    local classified = {}
    for _, group in ipairs({ contract.openingAccessEdges or {}, contract.openingStairPassageEdges or {},
        contract.openingWallSegments or {}, contract.openingGuardSegments or {} }) do
        for _, edge in ipairs(group) do
            if classified[edge.key] then
                audit.wallsComplete = false
                AddReason(audit, "opening-edge-double-owned")
            end
            classified[edge.key] = true
        end
    end
    for _, edge in ipairs(contract.openingBoundaryEdges or {}) do
        if not classified[edge.key] then
            audit.wallsComplete = false
            AddReason(audit, "opening-edge-unprotected")
            break
        end
    end
    audit.pass = audit.contractComplete and audit.traversable
        and audit.slabsComplete and audit.wallsComplete
    return audit
end

StairContract.Index = Index
StairContract.Coordinates = Coordinates
StairContract.CellSet = CellSet
StairContract.UniqueCells = UniqueCells
StairContract.BoundaryEdges = BoundaryEdges

return StairContract
