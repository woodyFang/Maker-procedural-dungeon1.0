local DoorContract = {}

-- Generic same-floor door contract. The editor and themes may choose the
-- content and appearance, but the grid validity of a door is shared by every
-- setting. Width remains the project-wide 1..6 corridor contract.
DoorContract.MIN_WIDTH = 1
DoorContract.MAX_WIDTH = 6
DoorContract.WIDTH_STEP = 1
DoorContract.DEFAULT_MARGIN = 0
DoorContract.APPROACH_DEPTH = 2

local SIDES = { "north", "south", "west", "east" }
local SIDE_ALIASES = {
    n = "north", s = "south", w = "west", e = "east",
}

local function Round(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

local function Index(x, y, width)
    return y * width + x + 1
end

local function InBounds(x, y, width, height)
    return x >= 0 and y >= 0 and x < width and y < height
end

local function NormalizeSide(side)
    side = SIDE_ALIASES[tostring(side or "")] or tostring(side or "east")
    for _, value in ipairs(SIDES) do
        if value == side then return value end
    end
    return nil
end

function DoorContract.NormalizeSide(side)
    return NormalizeSide(side)
end

function DoorContract.NormalizeWidth(width, fallback)
    local value = tonumber(width) or fallback or 2
    local snapped = math.floor(value / DoorContract.WIDTH_STEP + 0.5) * DoorContract.WIDTH_STEP
    return math.max(DoorContract.MIN_WIDTH, math.min(DoorContract.MAX_WIDTH, snapped))
end

function DoorContract.WidthOffsets(width)
    width = DoorContract.NormalizeWidth(width)
    local result = {}
    local first = -math.floor((width - 1) * 0.5)
    for offset = first, first + width - 1 do result[#result + 1] = offset end
    return result
end

function DoorContract.SideNormal(side)
    side = NormalizeSide(side)
    if side == "east" then return { x = 1, y = 0 } end
    if side == "west" then return { x = -1, y = 0 } end
    if side == "south" then return { x = 0, y = 1 } end
    if side == "north" then return { x = 0, y = -1 } end
    return nil
end

function DoorContract.RoomDoorPoint(room, other, margin)
    if not room or not other then return nil end
    margin = tonumber(margin)
    if margin == nil then margin = DoorContract.DEFAULT_MARGIN end
    local dx, dy = other.cx - room.cx, other.cy - room.cy
    local halfWidth = math.max(1, room.w * 0.5 - margin)
    local halfHeight = math.max(1, room.h * 0.5 - margin)
    if math.abs(dx) / halfWidth >= math.abs(dy) / halfHeight then
        return {
            x = Round(room.cx + (dx >= 0 and halfWidth or -halfWidth)),
            y = Round(room.cy + math.max(-halfHeight, math.min(halfHeight, dy))),
            side = dx >= 0 and "east" or "west",
        }
    end
    return {
        x = Round(room.cx + math.max(-halfWidth, math.min(halfWidth, dx))),
        y = Round(room.cy + (dy >= 0 and halfHeight or -halfHeight)),
        side = dy >= 0 and "south" or "north",
    }
end

function DoorContract.DoorSpecPoint(room, spec)
    if not room or not spec then return nil end
    local side = NormalizeSide(spec.side) or "east"
    local offset = math.max(-0.82, math.min(0.82, tonumber(spec.offset) or 0))
    if side == "north" then
        return { x = room.cx + offset * room.w * 0.5, y = room.cy - room.h * 0.5, side = side }
    end
    if side == "south" then
        return { x = room.cx + offset * room.w * 0.5, y = room.cy + room.h * 0.5, side = side }
    end
    if side == "west" then
        return { x = room.cx - room.w * 0.5, y = room.cy + offset * room.h * 0.5, side = side }
    end
    return { x = room.cx + room.w * 0.5, y = room.cy + offset * room.h * 0.5, side = "east" }
end

local function BoundaryRange(room, side)
    local x0, x1 = math.ceil(room.cx - room.w * 0.5), math.floor(room.cx + room.w * 0.5)
    local y0, y1 = math.ceil(room.cy - room.h * 0.5), math.floor(room.cy + room.h * 0.5)
    if side == "north" or side == "south" then
        return { min = x0, max = x1, fixed = side == "north" and y0 or y1 }
    end
    return { min = y0, max = y1, fixed = side == "west" and x0 or x1 }
end

local function IsHardBlocked(layer, cell)
    return (layer.stairMask and layer.stairMask[cell])
        or (layer.stairWallMask and layer.stairWallMask[cell])
        or (layer.stairClearance and layer.stairClearance[cell])
        or (layer.stairLanding and layer.stairLanding[cell])
        or (layer.slabOpening and layer.slabOpening[cell])
end

-- A door frame has two posts, so the wall must continue by at least one
-- tangent cell beyond both ends of the opening. Without this check a legal
-- opening can be placed at a room corner: the route is valid, but one post
-- hangs in empty space and the rendered arch appears skewed.
local function HasWallSupport(layer, width, height, room, x, y, normal)
    if not normal then return false end
    if not InBounds(x, y, width, height)
        or (layer.roomId[Index(x, y, width)] or 0) ~= room.id then
        return false
    end

    -- The support cell is the room-boundary cell carrying the post. The
    -- approach side may already be open or corridor-carved; the important
    -- invariant here is that both posts remain anchored inside this room's
    -- actual wall span rather than hanging past a corner.
    return true
end

local function HasFrameSupports(layer, width, height, room, point, offsets, normal)
    local first, last = offsets[1], offsets[#offsets]
    if not first or not last or not normal then return false end
    local tangentX, tangentY = normal.y ~= 0 and 1 or 0, normal.x ~= 0 and 1 or 0
    local firstX = point.x + tangentX * (first - 1)
    local firstY = point.y + tangentY * (first - 1)
    local lastX = point.x + tangentX * (last + 1)
    local lastY = point.y + tangentY * (last + 1)
    return HasWallSupport(layer, width, height, room, firstX, firstY, normal)
        and HasWallSupport(layer, width, height, room, lastX, lastY, normal)
end

local function ResolveWallDoor(layer, width, height, room, preferred, fallback, doorWidth, allowSideFallback)
    if not layer or not room then return nil, "missing door layer or room" end
    local requestedSide = NormalizeSide(preferred and preferred.side)
        or NormalizeSide(fallback and fallback.side)
    if not requestedSide then return nil, "invalid door side" end
    local sides = { requestedSide }
    if allowSideFallback then
        for _, side in ipairs(SIDES) do
            if side ~= requestedSide then sides[#sides + 1] = side end
        end
    end

    local offsets = DoorContract.WidthOffsets(doorWidth)
    local function InsideRoom(x, y)
        return InBounds(x, y, width, height)
            and (layer.roomId[Index(x, y, width)] or 0) == room.id
    end
    local function OutsideRayIsOpen(x, y, normal)
        for depth = 1, DoorContract.APPROACH_DEPTH do
            local nx, ny = x + normal.x * depth, y + normal.y * depth
            if not InBounds(nx, ny, width, height) then return false end
            local cell = Index(nx, ny, width)
            local reusedDoorway = depth == 1
                and layer.corridor and layer.corridor[cell]
                and layer.doorway and layer.doorway[Index(x, y, width)]
            local openSurface = (layer.grid[cell] or 0) == 0 or reusedDoorway
            if (layer.roomId[cell] or 0) ~= 0 or IsHardBlocked(layer, cell) or not openSurface then
                return false
            end
        end
        return true
    end
    local function PreferredTangent(side)
        local alongHorizontalWall = side == "north" or side == "south"
        local value = preferred and (alongHorizontalWall and preferred.x or preferred.y)
        if tonumber(value) then return tonumber(value) end
        return alongHorizontalWall and room.cx or room.cy
    end

    for _, side in ipairs(sides) do
        local range = BoundaryRange(room, side)
        if range.max >= range.min then
            local target = math.max(range.min, math.min(range.max, Round(PreferredTangent(side))))
            local candidates = {}
            for tangent = range.min, range.max do candidates[#candidates + 1] = tangent end
            table.sort(candidates, function(a, b)
                local da, db = math.abs(a - target), math.abs(b - target)
                return da == db and a < b or da < db
            end)
            local normal = assert(DoorContract.SideNormal(side))
            for _, tangent in ipairs(candidates) do
                local point
                if side == "north" or side == "south" then
                    point = { x = tangent, y = range.fixed, side = side }
                else
                    point = { x = range.fixed, y = tangent, side = side }
                end
                local legal = true
                for _, offset in ipairs(offsets) do
                    local x = point.x + (normal.y ~= 0 and offset or 0)
                    local y = point.y + (normal.x ~= 0 and offset or 0)
                    if not InsideRoom(x, y) or not OutsideRayIsOpen(x, y, normal) then
                        legal = false
                        break
                    end
                end
                if legal and not HasFrameSupports(layer, width, height, room, point, offsets, normal) then
                    legal = false
                end
                if legal then return point end
            end
        end
    end
    return nil, "no legal wall door"
end

function DoorContract.ResolveWallDoor(layer, width, height, room, preferred, fallback, doorWidth, allowSideFallback)
    return ResolveWallDoor(layer, width, height, room, preferred, fallback, doorWidth, allowSideFallback)
end

function DoorContract.DoorApproach(point, depth)
    if not point then return nil end
    local normal = DoorContract.SideNormal(point.side)
    if not normal then return nil end
    depth = math.max(1, math.floor((tonumber(depth) or DoorContract.APPROACH_DEPTH) + 0.5))
    return { x = Round(point.x) + normal.x * depth, y = Round(point.y) + normal.y * depth }
end

function DoorContract.MarkDoor(layer, width, height, point, doorWidth)
    if not layer or not point then return {} end
    local x, y = Round(point.x), Round(point.y)
    local normal = DoorContract.SideNormal(point.side)
    if not normal then return {} end
    local cells = {}
    local seen = {}
    for _, offset in ipairs(DoorContract.WidthOffsets(doorWidth)) do
        local dx = x + (normal.y ~= 0 and offset or 0)
        local dy = y + (normal.x ~= 0 and offset or 0)
        if InBounds(dx, dy, width, height) then
            local cell = Index(dx, dy, width)
            layer.doorway[cell] = true
            if not seen[cell] then cells[#cells + 1], seen[cell] = cell, true end
        end
    end
    return cells
end

function DoorContract.ResolveArchInterface(layer, width, height, room, point, doorWidth)
    if not layer or not room or not point then return nil end
    local normal = DoorContract.SideNormal(point.side)
    if not normal then return nil end
    local tangent = normal.y ~= 0 and { x = 1, y = 0 } or { x = 0, y = 1 }
    local anchorX, anchorY = Round(point.x), Round(point.y)
    local offsets = DoorContract.WidthOffsets(doorWidth)
    local firstOffset, lastOffset = offsets[1], offsets[#offsets]
    if not firstOffset or not lastOffset then return nil end
    if not HasFrameSupports(layer, width, height, room,
        { x = anchorX, y = anchorY }, offsets, normal) then
        return nil
    end
    local centerOffset = (firstOffset + lastOffset) * 0.5
    local interfaces = {}
    for _, offset in ipairs(offsets) do
        local roomX = anchorX + tangent.x * offset
        local roomY = anchorY + tangent.y * offset
        if not InBounds(roomX, roomY, width, height)
            or (layer.roomId[Index(roomX, roomY, width)] or 0) ~= room.id then
            return nil
        end
        for _ = 1, math.max(width, height) do
            local nextX, nextY = roomX + normal.x, roomY + normal.y
            if not InBounds(nextX, nextY, width, height)
                or (layer.roomId[Index(nextX, nextY, width)] or 0) ~= room.id then
                break
            end
            roomX, roomY = nextX, nextY
        end
        local outsideX, outsideY = roomX + normal.x, roomY + normal.y
        if not InBounds(outsideX, outsideY, width, height) then return nil end
        interfaces[#interfaces + 1] = {
            roomX = roomX, roomY = roomY,
            x = roomX + normal.x * 0.5, y = roomY + normal.y * 0.5,
        }
    end
    if #interfaces == 0 then return nil end
    local first = interfaces[1]
    if not first then return nil end
    local normalCoordinate = normal.x ~= 0 and "x" or "y"
    for _, item in ipairs(interfaces) do
        if item[normalCoordinate] ~= first[normalCoordinate] then return nil end
    end
    local centerX = anchorX + tangent.x * centerOffset
    local centerY = anchorY + tangent.y * centerOffset
    return {
        wallCellX = tangent.x ~= 0 and centerX or first.roomX,
        wallCellY = tangent.y ~= 0 and centerY or first.roomY,
        interfaceX = normal.x ~= 0 and first.x or centerX,
        interfaceY = normal.y ~= 0 and first.y or centerY,
    }
end

function DoorContract.BuildArch(layer, width, height, room, point, doorWidth)
    if not room or not point then return nil end
    local normalizedWidth = DoorContract.NormalizeWidth(doorWidth)
    local normal = DoorContract.SideNormal(point.side)
    if not normal then return nil end
    local px = normal.y ~= 0 and 1 or 0
    local py = px == 1 and 0 or 1
    local offsets = DoorContract.WidthOffsets(normalizedWidth)
    local firstOffset, lastOffset = offsets[1], offsets[#offsets]
    if not firstOffset or not lastOffset then return nil end
    local centerOffset = (firstOffset + lastOffset) * 0.5
    local anchorX, anchorY = Round(point.x), Round(point.y)
    local arch = {
        x = anchorX + px * centerOffset,
        y = anchorY + py * centerOffset,
        px = px, py = py, len = normalizedWidth,
        corridorWidth = normalizedWidth, doorUnitWidth = normalizedWidth,
        doorUnitHeight = 2, doorUnitIndex = 0, doorUnitCount = 1,
        roomId = room.id, floor = room.floor or 0,
        side = NormalizeSide(point.side), anchorX = anchorX, anchorY = anchorY,
        nx = normal.x, ny = normal.y,
    }
    local interface = DoorContract.ResolveArchInterface(layer, width, height, room, point, normalizedWidth)
    for key, value in pairs(interface or {}) do arch[key] = value end
    return arch
end

return DoorContract
