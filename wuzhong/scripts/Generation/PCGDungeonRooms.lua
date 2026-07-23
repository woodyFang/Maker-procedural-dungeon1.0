local PCGRandomStream = require("Generation.PCGRandomStream")

local PCGDungeonRooms = {}

local function V(x, y, z)
    return { x or 0, y or 0, z or 0 }
end

local function MinV(a, b)
    return V(math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3]))
end

local function MaxV(a, b)
    return V(math.max(a[1], b[1]), math.max(a[2], b[2]), math.max(a[3], b[3]))
end

local function Intersects(candidateMin, candidateMax, oldMin, oldMax)
    return candidateMin[1] < oldMax[1] + 1
        and candidateMax[1] > oldMin[1] - 1
        and candidateMin[2] < oldMax[2]
        and candidateMax[2] > oldMin[2]
        and candidateMin[3] < oldMax[3] + 1
        and candidateMax[3] > oldMin[3] - 1
end

local function EditorRoomsIntersect(aMin, aMax, bMin, bMax)
    return aMin[2] < bMax[2] and aMax[2] > bMin[2]
        and aMin[1] < bMax[1] and aMax[1] > bMin[1]
        and aMin[3] < bMax[3] and aMax[3] > bMin[3]
end

local function GridDimensions(roomCounts, floorCount)
    local roomsPerFloor = 1
    for _, count in ipairs(roomCounts) do roomsPerFloor = math.max(roomsPerFloor, count) end
    local slotsPerSide = math.max(1, math.ceil(math.sqrt(roomsPerFloor)))
    return math.max(3, slotsPerSide * 5), floorCount, math.max(3, slotsPerSide * 5)
end

local function EditorLayout(options, seed, cellSize)
    local sourceRooms = options.editorRooms or {}
    local floorCount = math.max(1, math.floor((tonumber(options.floorCount) or 1) + 0.5))
    local counts = {}
    for floor = 1, floorCount do counts[floor] = 0 end
    for _, source in ipairs(sourceRooms) do
        local floor = math.floor((tonumber(source.floor) or 0) + 0.5)
        if floor >= 0 and floor < floorCount then counts[floor + 1] = counts[floor + 1] + 1 end
    end

    local baseGridX, gridY, baseGridZ = GridDimensions(counts, floorCount)
    local configuredGrid = options.editorGridCells
    if type(configuredGrid) == "table" then
        baseGridX = math.max(3, math.floor((tonumber(configuredGrid[1]) or baseGridX) + 0.5))
        baseGridZ = math.max(3, math.floor((tonumber(configuredGrid[3]) or baseGridZ) + 0.5))
    end
    local layoutWorldMin = V(-baseGridX * cellSize * 0.5, 0, -baseGridZ * cellSize * 0.5)
    local rooms, roomMins, roomMaxs, errors = {}, {}, {}, {}
    local gridMin = V(0, 0, 0)
    local gridMax = V(baseGridX, gridY, baseGridZ)

    for index, source in ipairs(sourceRooms) do
        local cx, cy = tonumber(source.cx or source.x), tonumber(source.cy or source.y)
        local width = math.max(1, math.floor((tonumber(source.w) or 1) + 0.5))
        local depth = math.max(1, math.floor((tonumber(source.h) or 1) + 0.5))
        local floor = math.floor((tonumber(source.floor) or 0) + 0.5)
        if not cx or not cy or cx ~= cx or cy ~= cy then
            errors[#errors + 1] = "Editor room " .. index .. " has invalid coordinates"
            cx, cy = 0, 0
        end
        if floor < 0 or floor >= floorCount then
            errors[#errors + 1] = "Editor room " .. index .. " is outside the configured floors"
            floor = math.max(0, math.min(floorCount - 1, floor))
        end

        local candidateMin = V(cx - width * 0.5, floor, cy - depth * 0.5)
        local candidateMax = V(cx + width * 0.5, floor + 1, cy + depth * 0.5)
        for oldIndex, oldMin in ipairs(roomMins) do
            if EditorRoomsIntersect(candidateMin, candidateMax, oldMin, roomMaxs[oldIndex]) then
                errors[#errors + 1] = string.format(
                    "Editor rooms %d and %d overlap on floor %d", oldIndex, index, floor)
                break
            end
        end
        roomMins[index], roomMaxs[index] = candidateMin, candidateMax
        gridMin = MinV(gridMin, V(math.floor(candidateMin[1]) - 4, 0, math.floor(candidateMin[3]) - 4))
        gridMax = MaxV(gridMax, V(math.ceil(candidateMax[1]) + 4, gridY, math.ceil(candidateMax[3]) + 4))

        local worldMin = V(
            layoutWorldMin[1] + candidateMin[1] * cellSize,
            layoutWorldMin[2] + candidateMin[2] * cellSize,
            layoutWorldMin[3] + candidateMin[3] * cellSize)
        local worldMax = V(
            layoutWorldMin[1] + candidateMax[1] * cellSize,
            layoutWorldMin[2] + candidateMax[2] * cellSize,
            layoutWorldMin[3] + candidateMax[3] * cellSize)
        rooms[index] = {
            id = index - 1,
            floor = floor,
            gridMin = candidateMin,
            gridMax = candidateMax,
            minimum = worldMin,
            maximum = worldMax,
            position = V((worldMin[1] + worldMax[1]) * 0.5,
                (worldMin[2] + worldMax[2]) * 0.5,
                (worldMin[3] + worldMax[3]) * 0.5),
            size = V(width * cellSize, cellSize, depth * cellSize),
            w = width,
            h = depth,
            cx = cx,
            cy = cy,
            locked = source.locked == true,
            roleHint = source.roleHint,
            type = source.type,
            roomGroupId = source.roomGroupId,
            stairRoom = source.stairRoom == true,
            stairRoomPairId = source.stairRoomPairId,
        }
    end

    local gridCells = V(gridMax[1] - gridMin[1], gridY, gridMax[3] - gridMin[3])
    if gridCells[1] > 256 or gridCells[3] > 256 then
        errors[#errors + 1] = "Editor layout exceeds the 256-cell routing limit"
    end
    local spaceMin = V(layoutWorldMin[1] + gridMin[1] * cellSize, 0,
        layoutWorldMin[3] + gridMin[3] * cellSize)
    local spaceMax = V(layoutWorldMin[1] + gridMax[1] * cellSize, floorCount * cellSize,
        layoutWorldMin[3] + gridMax[3] * cellSize)
    return {
        schemaVersion = 1,
        seed = seed,
        valid = #errors == 0,
        errors = errors,
        targetRoomCount = #sourceRooms,
        targetRoomCountsByFloor = counts,
        placedRoomCount = #rooms,
        floorCount = floorCount,
        cellSize = cellSize,
        gridCells = gridCells,
        editorGridCells = V(baseGridX, gridY, baseGridZ),
        layoutWorldMin = layoutWorldMin,
        spaceMin = spaceMin,
        spaceMax = spaceMax,
        spaceSize = V(spaceMax[1] - spaceMin[1], spaceMax[2] - spaceMin[2],
            spaceMax[3] - spaceMin[3]),
        attempts = 0,
        rooms = rooms,
        roomCountsByFloor = counts,
        warning = errors[1],
        editorEnabled = true,
    }
end

local function RoomTargets(options)
    local source = options.roomCountsByFloor
    local requestedFloors = math.max(1, math.floor((tonumber(options.floorCount) or 3) + 0.5))
    local counts, total = {}, 0
    if type(source) == "table" and #source > 0 then
        for floor = 1, requestedFloors do
            counts[floor] = math.max(1, math.floor((tonumber(source[floor]) or 1) + 0.5))
            total = total + counts[floor]
        end
        return counts, total, requestedFloors
    end

    total = math.max(1, math.floor((tonumber(options.roomCount) or 22) + 0.5))
    requestedFloors = math.min(total, requestedFloors)
    local base = total // requestedFloors
    for floor = 1, requestedFloors do counts[floor] = base end
    for floor = 1, total - base * requestedFloors do counts[floor] = counts[floor] + 1 end
    return counts, total, requestedFloors
end

local function FloorSequence(counts)
    local remaining, sequence = {}, {}
    for floor, count in ipairs(counts) do remaining[floor] = count end
    while true do
        local added = false
        for floor = 1, #remaining do
            if remaining[floor] > 0 then
                sequence[#sequence + 1] = floor - 1
                remaining[floor] = remaining[floor] - 1
                added = true
            end
        end
        if not added then return sequence end
    end
end

function PCGDungeonRooms.Generate(options)
    options = options or {}
    local seed = math.floor(tonumber(options.seed) or 5)
    local cellSize = math.max(0.001, tonumber(options.cellSize) or 5.0)
    if options.editorEnabled and type(options.editorRooms) == "table" then
        return EditorLayout(options, seed, cellSize)
    end

    local requestedCounts, roomCount, floorCount = RoomTargets(options)
    local floorSequence = FloorSequence(requestedCounts)
    local maximumAttempts = math.max(1000, roomCount * 500)

    local gridX, gridY, gridZ = GridDimensions(requestedCounts, floorCount)
    local layoutWorldMin = V(-gridX * cellSize * 0.5, 0, -gridZ * cellSize * 0.5)

    local rooms, roomMins, roomMaxs = {}, {}, {}
    local placedWorldMin = V(1e10, 1e10, 1e10)
    local placedWorldMax = V(-1e10, -1e10, -1e10)
    local placed, attempt = 0, 0

    while placed < roomCount and attempt < maximumAttempts do
        local sizeX = PCGRandomStream.RandomInt(PCGRandomStream.Affine(seed, attempt, 17.173), 1, 3)
        local sizeY = PCGRandomStream.RandomInt(PCGRandomStream.Affine(seed, attempt, 31.417), 1, 1)
        local sizeZ = PCGRandomStream.RandomInt(PCGRandomStream.Affine(seed, attempt, 47.791), 1, 3)
        local posX = PCGRandomStream.RandomInt(PCGRandomStream.Affine(seed, attempt, 61.113), 0, gridX - sizeX)
        local posY = floorSequence[placed + 1]
        local posZ = PCGRandomStream.RandomInt(PCGRandomStream.Affine(seed, attempt, 97.557), 0, gridZ - sizeZ)
        local candidateMin = V(posX, posY, posZ)
        local candidateMax = V(posX + sizeX, posY + sizeY, posZ + sizeZ)
        local overlaps = false

        for index, oldMin in ipairs(roomMins) do
            if Intersects(candidateMin, candidateMax, oldMin, roomMaxs[index]) then
                overlaps = true
                break
            end
        end

        if not overlaps then
            roomMins[#roomMins + 1] = candidateMin
            roomMaxs[#roomMaxs + 1] = candidateMax
            local worldMin = V(
                layoutWorldMin[1] + candidateMin[1] * cellSize,
                layoutWorldMin[2] + candidateMin[2] * cellSize,
                layoutWorldMin[3] + candidateMin[3] * cellSize)
            local worldMax = V(
                layoutWorldMin[1] + candidateMax[1] * cellSize,
                layoutWorldMin[2] + candidateMax[2] * cellSize,
                layoutWorldMin[3] + candidateMax[3] * cellSize)
            local size = V(worldMax[1] - worldMin[1], worldMax[2] - worldMin[2],
                worldMax[3] - worldMin[3])
            rooms[#rooms + 1] = {
                id = placed,
                floor = posY,
                gridMin = candidateMin,
                gridMax = candidateMax,
                minimum = worldMin,
                maximum = worldMax,
                position = V((worldMin[1] + worldMax[1]) * 0.5,
                    (worldMin[2] + worldMax[2]) * 0.5,
                    (worldMin[3] + worldMax[3]) * 0.5),
                size = size,
                w = sizeX,
                h = sizeZ,
                cx = (candidateMin[1] + candidateMax[1]) * 0.5,
                cy = (candidateMin[3] + candidateMax[3]) * 0.5,
            }
            placedWorldMin = MinV(placedWorldMin, worldMin)
            placedWorldMax = MaxV(placedWorldMax, worldMax)
            placed = placed + 1
        end
        attempt = attempt + 1
    end

    local countsByFloor = {}
    for floor = 1, floorCount do countsByFloor[floor] = 0 end
    for _, room in ipairs(rooms) do countsByFloor[room.floor + 1] = countsByFloor[room.floor + 1] + 1 end

    return {
        schemaVersion = 1,
        seed = seed,
        valid = placed == roomCount,
        errors = placed < roomCount and { "Not enough room search space for the requested count" } or {},
        targetRoomCount = roomCount,
        targetRoomCountsByFloor = requestedCounts,
        placedRoomCount = placed,
        floorCount = floorCount,
        cellSize = cellSize,
        gridCells = V(gridX, gridY, gridZ),
        layoutWorldMin = layoutWorldMin,
        spaceMin = placedWorldMin,
        spaceMax = placedWorldMax,
        spaceSize = V(placedWorldMax[1] - placedWorldMin[1],
            placedWorldMax[2] - placedWorldMin[2],
            placedWorldMax[3] - placedWorldMin[3]),
        attempts = attempt,
        rooms = rooms,
        roomCountsByFloor = countsByFloor,
        warning = placed < roomCount and "Not enough room search space for the requested count" or nil,
    }
end

return PCGDungeonRooms
