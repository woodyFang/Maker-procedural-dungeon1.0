local CurrentFloorCue = {}

local TILE_EMPTY = 0
local MARGIN = 0.65
local MIN_LEG_LENGTH = 1.4
local MAX_LEG_LENGTH = 3.0
local LEG_LENGTH_RATIO = 0.16

function CurrentFloorCue.Bounds(dungeon, currentFloor)
    local layer = dungeon.layers[currentFloor + 1]
    if not layer then return nil end

    local minX, minY, maxX, maxY = dungeon.width, dungeon.height, -1, -1
    for y = 0, dungeon.height - 1 do
        for x = 0, dungeon.width - 1 do
            local cell = y * dungeon.width + x + 1
            local tile = layer.grid[cell]
            if tile and tile ~= TILE_EMPTY then
                minX, minY = math.min(minX, x), math.min(minY, y)
                maxX, maxY = math.max(maxX, x), math.max(maxY, y)
            end
        end
    end
    if maxX < minX or maxY < minY then return nil end
    return {
        centerGridX = (minX + maxX) * 0.5,
        centerGridY = (minY + maxY) * 0.5,
        width = maxX - minX + 1 + MARGIN * 2,
        depth = maxY - minY + 1 + MARGIN * 2,
    }
end

function CurrentFloorCue.CornerMarkers(bounds, viewMode)
    local halfWidth, halfDepth = bounds.width * 0.5, bounds.depth * 0.5
    local legLength = math.max(MIN_LEG_LENGTH,
        math.min(MAX_LEG_LENGTH, math.min(bounds.width, bounds.depth) * LEG_LENGTH_RATIO))
    local thickness = viewMode == "current" and 0.10 or 0.14
    local postHeight = viewMode == "current" and 0.72 or 1.05
    local markers = {}
    for _, signs in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
        local signX, signZ = signs[1], signs[2]
        local cornerX, cornerZ = signX * halfWidth, signZ * halfDepth
        markers[#markers + 1] = {
            kind = "xLeg",
            x = cornerX - signX * legLength * 0.5, y = 0,
            z = cornerZ, sx = legLength, sy = 0.035, sz = thickness,
        }
        markers[#markers + 1] = {
            kind = "zLeg",
            x = cornerX, y = 0,
            z = cornerZ - signZ * legLength * 0.5,
            sx = thickness, sy = 0.035, sz = legLength,
        }
        markers[#markers + 1] = {
            kind = "post",
            x = cornerX, y = postHeight * 0.5,
            z = cornerZ, sx = thickness * 1.35, sy = postHeight, sz = thickness * 1.35,
        }
    end
    return markers
end

return CurrentFloorCue
