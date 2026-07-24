local VexRandom = require("Generation.VexRandom")

local ShadowCastleRooms = {}

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

function ShadowCastleRooms.Generate(options)
    options = options or {}
    local seed = math.floor(tonumber(options.seed) or 5)
    local roomCount = math.max(1, math.floor((tonumber(options.roomCount) or 22) + 0.5))
    local floorCount = math.max(1, math.min(roomCount,
        math.floor((tonumber(options.floorCount) or 3) + 0.5)))
    local cellSize = math.max(0.001, tonumber(options.cellSize) or 5.0)
    local maximumAttempts = math.max(1000, roomCount * 500)

    local roomsPerFloor = math.ceil(roomCount / floorCount)
    local slotsPerSide = math.max(1, math.ceil(math.sqrt(roomsPerFloor)))
    local gridX = math.max(3, slotsPerSide * 5)
    local gridY = floorCount
    local gridZ = math.max(3, slotsPerSide * 5)
    local layoutWorldMin = V(-gridX * cellSize * 0.5, 0, -gridZ * cellSize * 0.5)

    local rooms, roomMins, roomMaxs = {}, {}, {}
    local placedWorldMin = V(1e10, 1e10, 1e10)
    local placedWorldMax = V(-1e10, -1e10, -1e10)
    local placed, attempt = 0, 0

    while placed < roomCount and attempt < maximumAttempts do
        local sizeX = VexRandom.RandomInt(VexRandom.Affine(seed, attempt, 17.173), 1, 3)
        local sizeY = VexRandom.RandomInt(VexRandom.Affine(seed, attempt, 31.417), 1, 1)
        local sizeZ = VexRandom.RandomInt(VexRandom.Affine(seed, attempt, 47.791), 1, 3)
        local posX = VexRandom.RandomInt(VexRandom.Affine(seed, attempt, 61.113), 0, gridX - sizeX)
        local posY = placed % floorCount
        local posZ = VexRandom.RandomInt(VexRandom.Affine(seed, attempt, 97.557), 0, gridZ - sizeZ)
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
        targetRoomCount = roomCount,
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

return ShadowCastleRooms
