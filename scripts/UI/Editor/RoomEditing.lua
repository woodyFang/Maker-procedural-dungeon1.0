local RouteEditing = require("UI.Editor.RouteEditing")

local RoomEditing = {}

local Snap = RouteEditing.Snap
RoomEditing.DEFAULT_MINIMUM_SIZE = 5

local function NormalizeMinimum(value, fallback)
    return math.max(1, Snap(tonumber(value) or fallback))
end

function RoomEditing.ResolveMinimumSize(dungeon)
    local width = NormalizeMinimum(dungeon and dungeon.editorRoomMinimumWidth,
        RoomEditing.DEFAULT_MINIMUM_SIZE)
    local height = NormalizeMinimum(dungeon and dungeon.editorRoomMinimumHeight, width)
    return width, height
end

-- Keep this geometry in the same order as Three's editorNormalizeRect:
-- calculate from the unsnapped pointer first, then snap the resulting center
-- and size. Snapping an edge before this step makes odd-sized rooms jump by
-- half a cell as soon as a resize handle is pressed.
function RoomEditing.NormalizeRect(a, b, minimumWidth, minimumHeight)
    local x0, x1 = math.min(a.x, b.x), math.max(a.x, b.x)
    local y0, y1 = math.min(a.y, b.y), math.max(a.y, b.y)
    minimumWidth = NormalizeMinimum(minimumWidth, RoomEditing.DEFAULT_MINIMUM_SIZE)
    minimumHeight = NormalizeMinimum(minimumHeight, minimumWidth)
    return {
        cx = Snap((x0 + x1) * 0.5),
        cy = Snap((y0 + y1) * 0.5),
        w = math.max(minimumWidth, Snap(x1 - x0)),
        h = math.max(minimumHeight, Snap(y1 - y0)),
    }
end

function RoomEditing.Resize(start, pointer, mode, minimumWidth, minimumHeight)
    -- UI descriptors use names such as "resize-nw". Never search the full
    -- name for direction letters: the word "resize" itself contains both
    -- "e" and "s", which used to activate the east and south edges for every
    -- handle. Only the suffix is the resize direction.
    local direction = (mode or ""):gsub("^resize%-", "")
    local x0, x1 = start.cx - start.w * 0.5, start.cx + start.w * 0.5
    local y0, y1 = start.cy - start.h * 0.5, start.cy + start.h * 0.5
    if direction:find("w", 1, true) then x0 = pointer.x end
    if direction:find("e", 1, true) then x1 = pointer.x end
    if direction:find("n", 1, true) then y0 = pointer.y end
    if direction:find("s", 1, true) then y1 = pointer.y end
    return RoomEditing.NormalizeRect({ x = x0, y = y0 }, { x = x1, y = y1 },
        minimumWidth, minimumHeight)
end

-- Use the immutable room and pointer starts, matching Three's room drag.
-- Snap only the pointer delta: PCG rooms can legitimately have half-cell
-- centers (for example 2.5 for a one-cell room), and snapping the absolute
-- center would move such a room on the first frame of a plain click.
function RoomEditing.Move(start, pointerStart, pointer)
    return start.cx + Snap(pointer.x - pointerStart.x),
        start.cy + Snap(pointer.y - pointerStart.y)
end

return RoomEditing
