local CanvasViewport = {}
CanvasViewport.__index = CanvasViewport

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

function CanvasViewport.new()
    return setmetatable({ x = 0, y = 0, width = 1, height = 1,
        scale = 4, originX = 0, originY = 0, fitted = false }, CanvasViewport)
end

function CanvasViewport:SetRect(x, y, width, height)
    self.x, self.y = x, y
    self.width, self.height = math.max(1, width), math.max(1, height)
end

function CanvasViewport:Fit(rooms, floor)
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, room in ipairs(rooms or {}) do
        if room.floor == floor then
            minX, minY = math.min(minX, room.cx - room.w * 0.5), math.min(minY, room.cy - room.h * 0.5)
            maxX, maxY = math.max(maxX, room.cx + room.w * 0.5), math.max(maxY, room.cy + room.h * 0.5)
        end
    end
    if minX == math.huge then minX, minY, maxX, maxY = 0, 0, 40, 30 end
    self.scale = Clamp(math.min((self.width - 50) / math.max(1, maxX - minX),
        (self.height - 50) / math.max(1, maxY - minY)), 1.2, 18)
    self.originX = self.x + self.width * 0.5 - (minX + maxX) * 0.5 * self.scale
    self.originY = self.y + self.height * 0.5 - (minY + maxY) * 0.5 * self.scale
    self.fitted = true
end

function CanvasViewport:GridToScreen(point)
    return { x = self.originX + point.x * self.scale, y = self.originY + point.y * self.scale }
end

function CanvasViewport:ScreenToGrid(x, y)
    return (x - self.originX) / self.scale, (y - self.originY) / self.scale
end

function CanvasViewport:ProjectGrid(_, point, _)
    return self:GridToScreen(point)
end

function CanvasViewport:PixelsPerGrid(_, _)
    return self.scale
end

function CanvasViewport:Pan(deltaX, deltaY)
    self.originX, self.originY = self.originX + deltaX, self.originY + deltaY
end

function CanvasViewport:ZoomAt(x, y, wheel)
    if not wheel or wheel == 0 then return false end
    local gridX, gridY = self:ScreenToGrid(x, y)
    local nextScale = Clamp(self.scale * (wheel > 0 and 1.12 or (1 / 1.12)), 0.75, 32)
    if nextScale == self.scale then return false end
    self.scale = nextScale
    self.originX, self.originY = x - gridX * nextScale, y - gridY * nextScale
    return true
end

return CanvasViewport
