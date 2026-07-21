local EditorViewport = {}
EditorViewport.__index = EditorViewport

function EditorViewport.new(camera)
    return setmetatable({
        camera = camera,
        dpr = 1,
        width = 1,
        height = 1,
    }, EditorViewport)
end

function EditorViewport:Update()
    self.dpr = math.max(1, graphics:GetDPR())
    self.width = math.max(1, graphics:GetWidth() / self.dpr)
    self.height = math.max(1, graphics:GetHeight() / self.dpr)
    return self.width, self.height, self.dpr
end

function EditorViewport:MouseLogical(mousePosition)
    return mousePosition.x / self.dpr, mousePosition.y / self.dpr
end

function EditorViewport:ProjectWorld(worldPosition)
    if not self.camera or not worldPosition then return nil end
    local screen = self.camera:WorldToScreenPoint(worldPosition)
    if not screen then return nil end
    return { x = screen.x * self.width, y = screen.y * self.height }
end

function EditorViewport:ProjectGrid(editor, point, localY)
    if not editor or not point then return nil end
    return self:ProjectWorld(editor:GridToWorld(point, localY or 0.62))
end

function EditorViewport:PixelsPerGrid(editor, point)
    local origin = self:ProjectGrid(editor, point, 0.62)
    local right = self:ProjectGrid(editor, { x = point.x + 1, y = point.y }, 0.62)
    local down = self:ProjectGrid(editor, { x = point.x, y = point.y + 1 }, 0.62)
    if not origin or not right or not down then return 1 end
    local xScale = math.sqrt((right.x - origin.x)^2 + (right.y - origin.y)^2)
    local yScale = math.sqrt((down.x - origin.x)^2 + (down.y - origin.y)^2)
    return math.max(0.1, (xScale + yScale) * 0.5)
end

return EditorViewport
