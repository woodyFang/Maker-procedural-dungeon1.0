local Widget = require("urhox-libs/UI/Core/Widget")
local TextField = require("urhox-libs/UI/Widgets/TextField")
local Theme = require("urhox-libs/UI/Core/Theme")

local TextArea = TextField:Extend("TextArea")

local function utf8Chars(value)
    local chars = {}
    for _, codepoint in utf8.codes(value or "") do
        chars[#chars + 1] = utf8.char(codepoint)
    end
    return chars
end

function TextArea:Init(props)
    props = props or {}
    props.height = props.height or 112
    props.paddingHorizontal = props.paddingHorizontal or 12
    props.paddingTop = props.paddingTop or 10
    props.paddingBottom = props.paddingBottom or 10
    props.lineHeight = props.lineHeight or 1.45
    TextField.Init(self, props)
    self.lines_ = {}
    self.lineHeightPx_ = 18
end

function TextArea:BuildLines(nvg, value, maxWidth)
    local chars = utf8Chars(value)
    local lines = {}
    local text, width, startPos = "", 0, 0

    local function pushLine(endPos)
        lines[#lines + 1] = { text = text, width = width, startPos = startPos, endPos = endPos }
        text, width, startPos = "", 0, endPos
    end

    for index, char in ipairs(chars) do
        local charPos = index - 1
        if char == "\n" then
            pushLine(charPos)
            startPos = index
        else
            local charWidth = nvgTextBounds(nvg, 0, 0, char)
            if text ~= "" and width + charWidth > maxWidth then
                pushLine(charPos)
            end
            text = text .. char
            width = width + charWidth
        end
    end
    lines[#lines + 1] = { text = text, width = width, startPos = startPos, endPos = #chars }
    return lines
end

function TextArea:CursorFromPoint(x, y)
    if self.renderingPlaceholder_ then return 0 end
    local lines = self.lines_ or {}
    if #lines == 0 then return 0 end
    local lineIndex = math.floor((y - (self.textTop_ or 0)) / (self.lineHeightPx_ or 18)) + 1
    lineIndex = math.max(1, math.min(#lines, lineIndex))
    local line = lines[lineIndex]
    local relativeX = math.max(0, x - (self.textAreaX_ or 0))
    local cursor = line.startPos
    local best = math.huge
    local prefix = ""
    for offset, char in ipairs(utf8Chars(line.text)) do
        local beforeWidth = nvgTextBounds(self.lastNvg_, 0, 0, prefix)
        local distance = math.abs(relativeX - beforeWidth)
        if distance < best then best, cursor = distance, line.startPos + offset - 1 end
        prefix = prefix .. char
    end
    local endDistance = math.abs(relativeX - line.width)
    if endDistance < best then cursor = line.endPos end
    return cursor
end

function TextArea:Render(nvg)
    self.lastNvg_ = nvg
    local l = self:GetAbsoluteLayout()
    local props, state = self.props, self.state
    local value = props.value or ""
    local disabled, focused = props.disabled, state.focused
    local filled = value ~= ""
    local bgColor = disabled and Theme.Color("disabled") or Theme.Color("surface")
    local borderColor
    if disabled then
        borderColor = props.disabledBorderColor or props.borderColor or Theme.Color("border")
    elseif props.error then
        borderColor = props.errorBorderColor or Theme.Color("error")
    elseif focused then
        borderColor = props.focusedBorderColor or Theme.Color("borderFocus")
    elseif filled then
        borderColor = props.filledBorderColor or props.borderColor or Theme.Color("border")
    else
        borderColor = props.borderColor or Theme.Color("border")
    end
    local borderWidth = focused and (props.focusedBorderWidth or 2) or (props.borderWidth or 1)

    self:CreateShapePath(nvg, self:GetShapeGeometry(l, nil, props.borderRadius or 4))
    nvgFillColor(nvg, nvgRGBA(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 255))
    nvgFill(nvg)
    if borderColor and borderWidth > 0 then
        self:CreateShapePath(nvg, self:GetShapeGeometry(l, nil, props.borderRadius or 4))
        nvgStrokeColor(nvg, nvgRGBA(borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 255))
        nvgStrokeWidth(nvg, borderWidth)
        nvgStroke(nvg)
    end

    nvgFontFace(nvg, Theme.FontFace(props.fontFamily, props.fontWeight))
    nvgFontSize(nvg, Theme.FontSize(props.fontSize))
    nvgTextAlign(nvg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    local paddingL = props.paddingLeft or props.paddingHorizontal or 12
    local paddingR = props.paddingRight or props.paddingHorizontal or 12
    local paddingT = props.paddingTop or 10
    local textX, textY = l.x + paddingL, l.y + paddingT
    local textWidth = math.max(1, l.w - paddingL - paddingR)
    local _, _, fontLineHeight = nvgTextMetrics(nvg)
    local lineHeight = fontLineHeight * (props.lineHeight or 1.45)
    self.textAreaX_, self.textTop_, self.lineHeightPx_ = textX, textY, lineHeight

    local displayValue = value ~= "" and value or (props.placeholder or "")
    self.renderingPlaceholder_ = value == ""
    self.lines_ = self:BuildLines(nvg, displayValue, textWidth)
    local color = value ~= "" and (disabled and Theme.Color("disabledText") or Theme.Color("text"))
        or Theme.Color("textSecondary")
    nvgFillColor(nvg, nvgRGBA(color[1], color[2], color[3], color[4] or 255))

    nvgSave(nvg)
    nvgIntersectScissor(nvg, l.x, l.y, l.w, l.h)
    for index, line in ipairs(self.lines_) do
        nvgText(nvg, textX, textY + (index - 1) * lineHeight, line.text, nil)
    end

    if focused and state.cursorBlink and value ~= "" then
        local cursorPos = state.cursorPos or 0
        local cursorLine = self.lines_[#self.lines_]
        for _, line in ipairs(self.lines_) do
            if cursorPos >= line.startPos and cursorPos <= line.endPos then cursorLine = line; break end
        end
        local charCount = math.max(0, cursorPos - cursorLine.startPos)
        local prefix = ""
        local chars = utf8Chars(cursorLine.text)
        for i = 1, math.min(charCount, #chars) do prefix = prefix .. chars[i] end
        local cursorX = textX + nvgTextBounds(nvg, 0, 0, prefix)
        local cursorY = textY
        for index, line in ipairs(self.lines_) do
            if line == cursorLine then cursorY = textY + (index - 1) * lineHeight; break end
        end
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, cursorX, cursorY)
        nvgLineTo(nvg, cursorX, cursorY + fontLineHeight)
        nvgStrokeColor(nvg, nvgRGBA(color[1], color[2], color[3], 255))
        nvgStrokeWidth(nvg, 1)
        nvgStroke(nvg)
    end
    nvgRestore(nvg)
end

function TextArea:OnKeyDown(key)
    if self.state.focused and not self.props.disabled and (key == KEY_RETURN or key == KEY_KP_ENTER) then
        self:OnTextInput("\n")
        return true
    end
    return TextField.OnKeyDown(self, key)
end

function TextArea:OnPointerDown(event)
    self.lastPointerType_ = event.pointerType
    Widget.OnPointerDown(self, event)
    if not self.props.disabled then
        local cursorPos = self:CursorFromPoint(event.x, event.y)
        self.isDragging_ = true
        self:SetState({ cursorPos = cursorPos, selectionStart = cursorPos, selectionEnd = cursorPos, cursorBlink = true })
        self.blinkTimer_ = 0
    end
end

function TextArea:OnPointerMove(event)
    if self.isDragging_ and not self.props.disabled then
        local cursorPos = self:CursorFromPoint(event.x, event.y)
        self:SetState({ cursorPos = cursorPos, selectionEnd = cursorPos, cursorBlink = true })
    end
end

function TextArea:OnPointerUp(event)
    Widget.OnPointerUp(self, event)
    self.isDragging_ = false
end

return TextArea
