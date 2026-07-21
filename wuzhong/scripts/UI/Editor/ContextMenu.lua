local ContextMenu = {}
ContextMenu.__index = ContextMenu

local ITEM_HEIGHT = 32
local PADDING = 6
local WIDTH = 184

local function Inside(x, y, rect)
    return rect and x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h
end

function ContextMenu.new()
    return setmetatable({ visible = false, items = {}, rects = {}, context = nil, hover = nil }, ContextMenu)
end

function ContextMenu:IsOpen()
    return self.visible
end

function ContextMenu:Close()
    self.visible, self.context, self.hover = false, nil, nil
    self.items, self.rects = {}, {}
end

function ContextMenu:Open(x, y, items, context, logicalWidth, logicalHeight)
    self.items, self.context, self.hover = items or {}, context, nil
    local height = #self.items * ITEM_HEIGHT + PADDING * 2
    self.x = math.max(8, math.min(x, logicalWidth - WIDTH - 8))
    self.y = math.max(8, math.min(y, logicalHeight - height - 8))
    self.w, self.h, self.visible = WIDTH, height, #self.items > 0
    self.rects = {}
    for index = 1, #self.items do
        self.rects[index] = { x = self.x + PADDING, y = self.y + PADDING + (index - 1) * ITEM_HEIGHT,
            w = WIDTH - PADDING * 2, h = ITEM_HEIGHT }
    end
end

function ContextMenu:UpdateHover(x, y)
    self.hover = nil
    if not self.visible then return end
    for index, rect in ipairs(self.rects) do
        if Inside(x, y, rect) then self.hover = index; return end
    end
end

function ContextMenu:Hit(x, y)
    if not self.visible then return nil, false end
    for index, rect in ipairs(self.rects) do
        if Inside(x, y, rect) then
            local item = self.items[index]
            self:Close()
            return item, true
        end
    end
    local inside = Inside(x, y, { x = self.x, y = self.y, w = self.w, h = self.h })
    if not inside then self:Close() end
    return nil, inside
end

function ContextMenu:Render(vg)
    if not self.visible then return end
    nvgBeginPath(vg)
    nvgRoundedRect(vg, self.x, self.y, self.w, self.h, 8)
    nvgFillColor(vg, nvgRGBA(16, 19, 29, 250))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(48, 53, 72, 255))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    for index, item in ipairs(self.items) do
        local rect = self.rects[index]
        if self.hover == index then
            nvgBeginPath(vg)
            nvgRoundedRect(vg, rect.x, rect.y + 2, rect.w, rect.h - 4, 5)
            nvgFillColor(vg, nvgRGBA(29, 34, 49, 255))
            nvgFill(vg)
        end
        local danger = item.danger == true
        nvgFillColor(vg, danger and nvgRGBA(255, 116, 104, 255) or nvgRGBA(232, 235, 242, 255))
        nvgText(vg, rect.x + 10, rect.y + rect.h * 0.5, item.label or item.action or "", nil)
    end
end

return ContextMenu
