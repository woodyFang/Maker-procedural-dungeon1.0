-- ============================================================================
-- Modal Widget
-- UrhoX UI Library - Yoga + NanoVG
-- Modal dialog with overlay backdrop
-- ============================================================================

local Widget = require("urhox-libs/UI/Core/Widget")
local Theme = require("urhox-libs/UI/Core/Theme")
local Style = require("urhox-libs/UI/Core/Style")
local UI = require("urhox-libs/UI/Core/UI")

---@class ModalProps : WidgetProps
---@field isOpen boolean|nil Is modal visible
---@field title string|nil Modal title
---@field size string|nil "sm" | "md" | "lg" | "xl" | "fullscreen" (default: "md")
---@field dialogWidth number|nil Exact dialog width before viewport clamping
---@field dialogMaxHeight number|nil Exact dialog maximum height before viewport clamping
---@field closeOnOverlay boolean|nil Close when clicking overlay (default: true)
---@field closeOnEscape boolean|nil Close on Escape key (default: true)
---@field showCloseButton boolean|nil Show close button (default: true)
---@field contentPadding number|table|nil Content area padding: number for uniform, or {top, right, bottom, left} (default: 16)
---@field contentGap number|nil Gap between content children (default: 8)
---@field footerPadding number|table|nil Footer padding: number for uniform, or {top, right, bottom, left} (default: {12, 16, 12, 16})
---@field headerBorderRadius number|table|nil Header background radius
---@field headerStripeColor table|nil Header bottom stripe color
---@field headerStripeHeight number|nil Header bottom stripe height
---@field titleTextColor table|nil Title text color
---@field titleFontWeight string|nil Title font weight
---@field titleFontSize number|nil Title font size in pt (default: Theme.FontSizeOf("subtitle"))
---@field onClose fun(self: Modal)|nil Close callback
---@field onOpen fun(self: Modal)|nil Open callback

---@class Modal : Widget
---@operator call(ModalProps?): Modal
---@field props ModalProps
---@field new fun(self, props: ModalProps?): Modal
local Modal = Widget:Extend("Modal")

-- Size presets
local SIZE_PRESETS = {
    sm = { width = 320, maxHeight = 400 },
    md = { width = 480, maxHeight = 600 },
    lg = { width = 640, maxHeight = 720 },
    xl = { width = 800, maxHeight = 800 },
    fullscreen = { width = "90%", maxHeight = "90%" },
}

-- ============================================================================
-- Constructor
-- ============================================================================

---@param props ModalProps?
function Modal:Init(props)
    props = props or {}

    -- Apply theme defaults
    local themeStyle = Theme.ComponentStyle("Modal")
    Style.ApplyDefaults(props, themeStyle)
    props.borderRadius = props.borderRadius or 12
    self.borderRadius_ = props.borderRadius

    -- Default settings
    self.size_ = props.size or "md"
    self.closeOnOverlay_ = props.closeOnOverlay ~= false  -- Default true
    self.closeOnEscape_ = props.closeOnEscape ~= false    -- Default true
    self.showCloseButton_ = props.showCloseButton ~= false  -- Default true
    self.isOpen_ = props.isOpen or false
    self.title_ = props.title

    -- Callbacks
    self.onOpen_ = props.onOpen
    self.onClose_ = props.onClose

    -- Modal is positioned absolute, full screen
    props.position = "absolute"
    props.left = 0
    props.top = 0
    props.width = "100%"
    props.height = "100%"

    -- Normalize footerPadding to {top, right, bottom, left}
    local fp = props.footerPadding
    if fp == nil then
        props.footerPadding = {12, 16, 12, 16}
    elseif type(fp) == "number" then
        props.footerPadding = {fp, fp, fp, fp}
    elseif type(fp) == "table" then
        local n = #fp
        if n == 0 then
            props.footerPadding = {12, 16, 12, 16}
        elseif n == 1 then
            props.footerPadding = {fp[1], fp[1], fp[1], fp[1]}
        elseif n == 2 then
            props.footerPadding = {fp[1], fp[2], fp[1], fp[2]}
        elseif n == 3 then
            props.footerPadding = {fp[1], fp[2], fp[3], fp[2]}
        end
        -- n >= 4: already correct
    end

    -- Call parent constructor
    Widget.Init(self, props)

    -- Animation state
    self.animProgress_ = self.isOpen_ and 1 or 0
    self.targetAnimProgress_ = self.isOpen_ and 1 or 0

    -- Create Yoga-managed content container (NOT added to Modal's Yoga tree)
    -- This Panel manages layout for content children via Yoga flexbox
    local Panel = require("urhox-libs/UI/Widgets/Panel")
    self.contentContainer_ = Panel({
        flexDirection = "column",
        gap = props.contentGap or 8,
    })
    self.contentContainer_.parent = self

    -- Convenience alias: contentChildren_ points to contentContainer_'s children
    self.contentChildren_ = self.contentContainer_.children

    -- Header/Footer widgets
    self.headerWidget_ = nil
    self.footerWidget_ = nil

    -- Auto-mount tracking (nil = not auto-mounted, ref = auto-mount parent)
    self.autoMountParent_ = nil

    -- State for hover
    self.closeButtonHovered_ = false

    -- Handle children prop
    if props.children then
        for _, child in ipairs(props.children) do
            self:AddContent(child)
        end
    end

end

-- ============================================================================
-- Rendering
-- ============================================================================

function Modal:Render(nvg)
    -- Don't render if not visible
    if self.animProgress_ <= 0 then
        return
    end

    -- Queue modal rendering as overlay to avoid parent transform issues
    UI.QueueOverlay(function(overlayNvg)
        self:RenderModalContent(overlayNvg)
    end)
end

function Modal:RenderModalContent(nvg)
    local screenWidth = UI.GetWidth() or 800
    local screenHeight = UI.GetHeight() or 600
    local borderRadius = self.borderRadius_
    local title = self.title_
    local showCloseButton = self.showCloseButton_

    -- Layout values (no scale needed - nvgScale handles it)
    local headerHeight = 56
    local cp = self.props.contentPadding or 16
    local cpTop, cpRight, cpBottom, cpLeft
    if type(cp) == "table" then
        cpTop, cpRight, cpBottom, cpLeft = cp[1], cp[2], cp[3], cp[4]
    else
        cpTop, cpRight, cpBottom, cpLeft = cp, cp, cp, cp
    end

    -- Get size preset
    local sizePreset = SIZE_PRESETS[self.size_] or SIZE_PRESETS.md
    local modalWidth = self.props.dialogWidth or sizePreset.width
    local modalMaxHeight = self.props.dialogMaxHeight or sizePreset.maxHeight

    -- Handle percentage widths
    if type(modalWidth) == "string" and modalWidth:match("%%$") then
        local percent = tonumber(modalWidth:match("(%d+)")) / 100
        modalWidth = screenWidth * percent
    end
    if type(modalMaxHeight) == "string" and modalMaxHeight:match("%%$") then
        local percent = tonumber(modalMaxHeight:match("(%d+)")) / 100
        modalMaxHeight = screenHeight * percent
    end

    -- Match the original web dialogs: fixed preferred size, with 14 px viewport gutters.
    modalWidth = math.min(modalWidth, math.max(1, screenWidth - 28))
    modalMaxHeight = math.min(modalMaxHeight, math.max(1, screenHeight - 28))

    -- Calculate footer height: measure footer widget + padding (after modalWidth is resolved)
    local footerHeight = 64  -- default
    if self.footerWidget_ then
        local fp = self.props.footerPadding
        local fpTop, fpRight, fpBottom, fpLeft = fp[1], fp[2], fp[3], fp[4]
        local footerContentWidth = modalWidth - fpLeft - fpRight
        YGNodeCalculateLayout(self.footerWidget_.node, footerContentWidth, YGUndefined, YGDirectionLTR)
        local measuredFooter = YGNodeLayoutGetHeight(self.footerWidget_.node)
        footerHeight = math.max(64, measuredFooter + fpTop + fpBottom)
    end

    -- Animation values
    local alpha = self.animProgress_
    local animScale = 0.9 + 0.1 * self.animProgress_

    -- Draw overlay backdrop
    local overlayAlpha = math.floor(alpha * 180)
    nvgBeginPath(nvg)
    nvgRect(nvg, 0, 0, screenWidth, screenHeight)
    nvgFillColor(nvg, nvgRGBA(0, 0, 0, overlayAlpha))
    nvgFill(nvg)

    -- Calculate content area width for Yoga layout
    local contentAreaWidth = modalWidth - cpLeft - cpRight

    -- Calculate modal position (centered)
    local modalHeight = self:CalculateContentHeight(contentAreaWidth) + cpTop + cpBottom + (title and headerHeight or 0) + (self.footerWidget_ and footerHeight or 0)
    modalHeight = math.min(modalHeight, modalMaxHeight)

    local modalX = (screenWidth - modalWidth * animScale) / 2
    local modalY = (screenHeight - modalHeight * animScale) / 2

    -- Apply scale transform
    nvgSave(nvg)
    nvgTranslate(nvg, screenWidth / 2, screenHeight / 2)
    nvgScale(nvg, animScale, animScale)
    nvgTranslate(nvg, -screenWidth / 2, -screenHeight / 2)

    -- Draw modal shadow
    local boxShadow = self.props.boxShadow
    if boxShadow == false then
        -- Explicitly disabled.
    elseif boxShadow then
        nvgSave(nvg)
        nvgGlobalAlpha(nvg, alpha)
        local geom = self:GetShapeGeometry({ x = modalX, y = modalY, w = modalWidth, h = modalHeight }, nil, borderRadius)
        self:RenderBoxShadows(nvg, geom, boxShadow)
        nvgRestore(nvg)
    else
        nvgBeginPath(nvg)
        self:CreateShapePath(nvg, self:GetShapeGeometry(
            { x = modalX - 4, y = modalY - 2, w = modalWidth + 8, h = modalHeight + 12 },
            nil,
            Widget.OffsetRadius(borderRadius, 4)
        ))
        nvgFillColor(nvg, nvgRGBA(0, 0, 0, math.floor(60 * alpha)))
        nvgFill(nvg)
    end

    -- Draw modal background
    local bgColor = Theme.Color("surface")
    self:CreateShapePath(nvg, self:GetShapeGeometry({ x = modalX, y = modalY, w = modalWidth, h = modalHeight }, nil, borderRadius))
    nvgFillColor(nvg, nvgRGBA(bgColor[1], bgColor[2], bgColor[3], math.floor(255 * alpha)))
    nvgFill(nvg)

    -- Draw border
    local borderColor = self.props.borderColor or Theme.Color("border")
    local borderAlpha = self.props.borderColor and (borderColor[4] or 255) or 100
    self:CreateShapePath(nvg, self:GetShapeGeometry({ x = modalX, y = modalY, w = modalWidth, h = modalHeight }, nil, borderRadius))
    nvgStrokeColor(nvg, nvgRGBA(borderColor[1], borderColor[2], borderColor[3], math.floor(borderAlpha * alpha)))
    nvgStrokeWidth(nvg, self.props.borderWidth or 1)
    nvgStroke(nvg)

    -- Store calculated layout for hit testing (in screen coordinates)
    self.modalLayout_ = {
        x = modalX,
        y = modalY,
        w = modalWidth,
        h = modalHeight,
    }

    local contentY = modalY

    -- Draw header with title
    if title then
        contentY = self:RenderHeader(nvg, modalX, modalY, modalWidth, title, showCloseButton, alpha)
    elseif showCloseButton then
        -- Just close button without title
        self:RenderCloseButton(nvg, modalX + modalWidth - 44, modalY + 8, alpha)
        contentY = modalY + 16
    end

    -- Render content area via Yoga subtree
    local footerHeightActual = self.footerWidget_ and footerHeight or 0
    local clipY = contentY
    local clipHeight = math.max(0, modalHeight - (contentY - modalY) - footerHeightActual)

    -- Content area background (theme token)
    -- Draws from header bottom to footer top, covering the header-content gap
    local contentBgColor = self.props.contentBgColor
    if contentBgColor then
        local headerHeight = 56
        local bgStartY = title and (modalY + headerHeight) or modalY
        local bgEndY = modalY + modalHeight - footerHeightActual
        local hasFooter = self.footerWidget_ ~= nil
        local contentRadius = 0
        if title and not hasFooter then
            contentRadius = Widget.BottomRadius(borderRadius)
        elseif not title and hasFooter then
            contentRadius = Widget.TopRadius(borderRadius)
        elseif not title and not hasFooter then
            contentRadius = borderRadius
        end
        self:CreateShapePath(nvg, self:GetShapeGeometry(
            { x = modalX, y = bgStartY, w = modalWidth, h = bgEndY - bgStartY },
            nil,
            contentRadius
        ))
        nvgFillColor(nvg, nvgRGBA(contentBgColor[1], contentBgColor[2], contentBgColor[3], math.floor((contentBgColor[4] or 255) * alpha)))
        nvgFill(nvg)
    end

    if #self.contentContainer_.children > 0 then
        -- Use constrained height so flexGrow/flexShrink and ScrollView work
        -- correctly within the visible content area. CalculateContentHeight
        -- (above) already measured natural height with YGUndefined; this call
        -- is for rendering layout and must respect the actual available space.
        YGNodeCalculateLayout(self.contentContainer_.node, contentAreaWidth, clipHeight, YGDirectionLTR)

        -- Position the content container for rendering and hit testing
        self.contentContainer_.renderOffsetX_ = modalX + cpLeft
        self.contentContainer_.renderOffsetY_ = contentY
        self.contentContainer_.renderWidth_ = contentAreaWidth
        self.contentContainer_.renderHeight_ = clipHeight

        nvgSave(nvg)
        nvgIntersectScissor(nvg, modalX, clipY, modalWidth, clipHeight)

        -- Render via framework tree walker (handles children recursion)
        UI.RenderWidgetSubtree(self.contentContainer_, nvg)

        nvgRestore(nvg)
    end

    -- Render footer
    if self.footerWidget_ then
        self:RenderFooter(nvg, modalX, modalY + modalHeight - footerHeight, modalWidth, footerHeight, alpha)
    end

    nvgRestore(nvg)
end

--- Render modal header
function Modal:RenderHeader(nvg, x, y, width, title, showCloseButton, alpha)
    local headerHeight = 56
    local padding = 16
    local titlePadding = 20
    local closeButtonSize = 28
    local closeButtonOffset = 44
    local fontFamily = Theme.FontFace(self.props.fontFamily, self.props.titleFontWeight or self.props.fontWeight)
    local textColor = self.props.titleTextColor or Theme.Color("text")

    -- Header background (theme token)
    local headerBgColor = self.props.headerBgColor
    if headerBgColor then
        local borderRadius = self.props.borderRadius or 12
        local headerRadius = self.props.headerBorderRadius or Widget.TopRadius(borderRadius)
        self:CreateShapePath(nvg, self:GetShapeGeometry({ x = x, y = y, w = width, h = headerHeight }, nil, headerRadius))
        nvgFillColor(nvg, nvgRGBA(headerBgColor[1], headerBgColor[2], headerBgColor[3], math.floor((headerBgColor[4] or 255) * alpha)))
        nvgFill(nvg)
    end

    local stripeColor = self.props.headerStripeColor
    local stripeHeight = self.props.headerStripeHeight or 0
    if stripeColor and stripeHeight > 0 then
        nvgBeginPath(nvg)
        nvgRect(nvg, x, y + headerHeight - stripeHeight, width, stripeHeight)
        nvgFillColor(nvg, nvgRGBA(stripeColor[1], stripeColor[2], stripeColor[3], math.floor((stripeColor[4] or 255) * alpha)))
        nvgFill(nvg)
    end

    -- Draw header separator (skip when headerBorderWidth = 0)
    local hdrBorderW = self.props.headerBorderWidth
    if hdrBorderW ~= 0 then
        local borderColor = Theme.Color("border")
        local hdrFullWidth = self.props.headerFullWidthBorder
        nvgBeginPath(nvg)
        if hdrFullWidth then
            nvgMoveTo(nvg, x, y + headerHeight)
            nvgLineTo(nvg, x + width, y + headerHeight)
        else
            nvgMoveTo(nvg, x + padding, y + headerHeight)
            nvgLineTo(nvg, x + width - padding, y + headerHeight)
        end
        nvgStrokeColor(nvg, nvgRGBA(borderColor[1], borderColor[2], borderColor[3], math.floor(100 * alpha)))
        nvgStrokeWidth(nvg, hdrBorderW or 1)
        nvgStroke(nvg)
    end

    -- Draw title
    nvgFontFace(nvg, fontFamily)
    nvgFontSize(nvg, self.props.titleFontSize and Theme.FontSize(self.props.titleFontSize) or Theme.FontSizeOf("subtitle"))
    nvgFillColor(nvg, nvgRGBA(textColor[1], textColor[2], textColor[3], math.floor(255 * alpha)))
    nvgTextAlign(nvg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgText(nvg, x + titlePadding, y + headerHeight / 2, title, nil)

    -- Draw close button
    if showCloseButton then
        self:RenderCloseButton(nvg, x + width - closeButtonOffset, y + (headerHeight - closeButtonSize) / 2, alpha)
    end

    local headerContentGap = self.props.headerContentGap
    if headerContentGap ~= nil then
        return y + headerHeight + headerContentGap
    end
    return y + headerHeight + padding
end

--- Render close button
function Modal:RenderCloseButton(nvg, x, y, alpha)
    local size = 28
    local iconSize = 10
    local borderRadius = 6

    -- Store button position for hit testing
    self.closeButtonLayout_ = { x = x, y = y, w = size, h = size }

    -- Button background on hover
    if self.closeButtonHovered_ then
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, x, y, size, size, borderRadius)
        nvgFillColor(nvg, nvgRGBA(128, 128, 128, math.floor(50 * alpha)))
        nvgFill(nvg)
    end

    -- Draw X icon
    local cx = x + size / 2
    local cy = y + size / 2
    local iconColor = Theme.Color("textSecondary")

    nvgBeginPath(nvg)
    nvgMoveTo(nvg, cx - iconSize / 2, cy - iconSize / 2)
    nvgLineTo(nvg, cx + iconSize / 2, cy + iconSize / 2)
    nvgMoveTo(nvg, cx + iconSize / 2, cy - iconSize / 2)
    nvgLineTo(nvg, cx - iconSize / 2, cy + iconSize / 2)
    nvgStrokeColor(nvg, nvgRGBA(iconColor[1], iconColor[2], iconColor[3], math.floor(255 * alpha)))
    nvgStrokeWidth(nvg, 2)
    nvgLineCap(nvg, NVG_ROUND)
    nvgStroke(nvg)
end

--- Render footer via Yoga subtree
function Modal:RenderFooter(nvg, x, y, width, footerHeight, alpha)
    local fp = self.props.footerPadding
    local fpTop, fpRight, fpBottom, fpLeft = fp[1], fp[2], fp[3], fp[4]
    local footerContentWidth = width - fpLeft - fpRight
    local footerContentHeight = footerHeight - fpTop - fpBottom

    -- Draw footer separator
    local ftrBorderW = self.props.footerBorderWidth or 1
    local footerFullWidth = self.props.footerFullWidthBorder
    local borderColor = Theme.Color("border")
    nvgBeginPath(nvg)
    if footerFullWidth then
        nvgMoveTo(nvg, x, y)
        nvgLineTo(nvg, x + width, y)
    else
        nvgMoveTo(nvg, x + fpLeft, y)
        nvgLineTo(nvg, x + width - fpRight, y)
    end
    nvgStrokeColor(nvg, nvgRGBA(borderColor[1], borderColor[2], borderColor[3], math.floor(100 * alpha)))
    nvgStrokeWidth(nvg, ftrBorderW)
    nvgStroke(nvg)

    -- Render footer widget via Yoga layout
    if self.footerWidget_ then
        YGNodeCalculateLayout(self.footerWidget_.node, footerContentWidth, footerContentHeight, YGDirectionLTR)
        self.footerWidget_.renderOffsetX_ = x + fpLeft
        self.footerWidget_.renderOffsetY_ = y + fpTop
        self.footerWidget_.renderWidth_ = footerContentWidth
        self.footerWidget_.renderHeight_ = footerContentHeight
        UI.RenderWidgetSubtree(self.footerWidget_, nvg)
    end
end

-- ============================================================================
-- Update
-- ============================================================================

function Modal:Update(dt)
    -- Animate open/close
    local speed = 8
    if self.animProgress_ < self.targetAnimProgress_ then
        self.animProgress_ = math.min(self.targetAnimProgress_, self.animProgress_ + dt * speed)
    elseif self.animProgress_ > self.targetAnimProgress_ then
        self.animProgress_ = math.max(self.targetAnimProgress_, self.animProgress_ - dt * speed)
    end

    -- Recursively update contentContainer_ subtree
    local function updateWidgetTree(widget)
        if widget.Update then
            widget:Update(dt)
        end
        for _, child in ipairs(widget.children or {}) do
            updateWidgetTree(child)
        end
    end

    if #self.contentContainer_.children > 0 then
        updateWidgetTree(self.contentContainer_)
    end

    -- Update footer subtree
    if self.footerWidget_ then
        updateWidgetTree(self.footerWidget_)
    end
end

-- ============================================================================
-- Content Height Calculation (via Yoga measurement)
-- ============================================================================

--- Calculate content height using Yoga layout
---@param availableWidth number|nil Available width for content (default: use size preset)
---@return number height Content area height
function Modal:CalculateContentHeight(availableWidth)
    if #self.contentContainer_.children == 0 then
        return 32  -- Minimum padding
    end

    -- Measure with available width, unconstrained height
    local measureWidth = availableWidth or 400
    YGNodeCalculateLayout(self.contentContainer_.node, measureWidth, YGUndefined, YGDirectionLTR)

    local measuredHeight = YGNodeLayoutGetHeight(self.contentContainer_.node)
    return math.max(measuredHeight, 32)
end

-- ============================================================================
-- Event Handlers
-- ============================================================================

function Modal:OnPointerDown(event)
    if not self.isOpen_ then
        return false
    end

    local ml = self.modalLayout_
    if not ml then
        return false
    end

    -- Check close button
    local cbl = self.closeButtonLayout_
    if cbl and event.x >= cbl.x and event.x <= cbl.x + cbl.w
        and event.y >= cbl.y and event.y <= cbl.y + cbl.h then
        self:Close()
        return true
    end

    -- Check if click is inside modal
    local insideModal = event.x >= ml.x and event.x <= ml.x + ml.w
        and event.y >= ml.y and event.y <= ml.y + ml.h

    if not insideModal and self.closeOnOverlay_ then
        self:Close()
        return true
    end

    return insideModal
end

function Modal:OnPointerMove(event)
    if not self.isOpen_ then
        return false
    end

    -- Check close button hover
    local cbl = self.closeButtonLayout_
    if cbl then
        self.closeButtonHovered_ = event.x >= cbl.x and event.x <= cbl.x + cbl.w
            and event.y >= cbl.y and event.y <= cbl.y + cbl.h
    end

    return true
end

function Modal:OnKeyDown(key)
    if self.isOpen_ and self.closeOnEscape_ then
        -- Check for Escape key (key code varies by platform)
        if key == 27 or key == "Escape" or key == "ESCAPE" then
            self:Close()
            return true
        end
    end
    return false
end

-- ============================================================================
-- Visibility Override
-- ============================================================================

--- Modal is invisible when closed, preventing findWidgetAt from traversing
--- into uncalculated Yoga subtrees (which have NaN dimensions).
function Modal:IsVisible()
    return self.isOpen_ and self.animProgress_ > 0
end

-- ============================================================================
-- Hit Test Override
-- ============================================================================

function Modal:HitTest(x, y)
    -- Modal captures all input when open
    return self.isOpen_ and self.animProgress_ > 0
end

--- Return children for findWidgetAt to recurse into
--- This enables hit testing on content children (buttons, inputs, etc.)
---@return Widget[]|nil
function Modal:GetHitTestChildren()
    local hitChildren = {}
    if self.contentContainer_ and #self.contentContainer_.children > 0 then
        table.insert(hitChildren, self.contentContainer_)
    end
    if self.footerWidget_ then
        table.insert(hitChildren, self.footerWidget_)
    end
    if #hitChildren > 0 then
        return hitChildren
    end
    return nil
end

-- ============================================================================
-- Content Management
-- ============================================================================

--- Add content to modal body (managed by Yoga-backed contentContainer_)
---@param child Widget
---@return Modal self
function Modal:AddContent(child)
    self.contentContainer_:AddChild(child)
    return self
end

--- Remove content from modal body
---@param child Widget
---@return Modal self
function Modal:RemoveContent(child)
    self.contentContainer_:RemoveChild(child)
    return self
end

--- Clear all content
---@return Modal self
function Modal:ClearContent()
    self.contentContainer_:ClearChildren()
    return self
end

--- Set footer widget (typically buttons)
---@param footer Widget
---@return Modal self
function Modal:SetFooter(footer)
    if self.footerWidget_ then
        self.footerWidget_.parent = nil
    end
    self.footerWidget_ = footer
    if footer then
        footer.parent = self
    end
    return self
end

-- ============================================================================
-- Public Methods
-- ============================================================================

--- Open the modal
---@return Modal self
function Modal:Open()
    if not self.isOpen_ then
        self.isOpen_ = true
        self.targetAnimProgress_ = 1
        -- Auto-mount to root if not in widget tree
        if not self.parent then
            local root = UI.GetRoot()
            if root then
                root:AddChild(self)
                self.autoMountParent_ = root
            end
        end
        UI.PushOverlay(self)
        self:DispatchEvent("open", self)
        if self.onOpen_ then
            self.onOpen_(self)
        end
    end
    return self
end

--- Close the modal
---@return Modal self
function Modal:Close()
    if self.isOpen_ then
        self.isOpen_ = false
        self.targetAnimProgress_ = 0
        UI.PopOverlay(self)

        -- Clear stale render coordinates to prevent ghost hit testing
        -- (renderOffsetX_ is set by RenderModalContent when open, but never cleared)
        if self.contentContainer_ then
            self.contentContainer_.renderOffsetX_ = nil
            self.contentContainer_.renderOffsetY_ = nil
            self.contentContainer_.renderWidth_ = nil
            self.contentContainer_.renderHeight_ = nil
        end
        if self.footerWidget_ then
            self.footerWidget_.renderOffsetX_ = nil
            self.footerWidget_.renderOffsetY_ = nil
            self.footerWidget_.renderWidth_ = nil
            self.footerWidget_.renderHeight_ = nil
        end

        self:DispatchEvent("close", self)
        if self.onClose_ then
            self.onClose_(self)
        end

        -- Auto-unmount: only remove if still attached to the auto-mount parent
        if self.autoMountParent_ and self.parent == self.autoMountParent_ then
            self.parent:RemoveChild(self)
            self.autoMountParent_ = nil
        end
    end
    return self
end

--- Toggle modal visibility
---@return Modal self
function Modal:Toggle()
    if self.isOpen_ then
        self:Close()
    else
        self:Open()
    end
    return self
end

--- Check if modal is open
---@return boolean
function Modal:IsOpen()
    return self.isOpen_ == true
end

--- Set modal title
---@param title string
---@return Modal self
function Modal:SetTitle(title)
    self.title_ = title
    return self
end

--- Set modal size
---@param size string "sm" | "md" | "lg" | "xl" | "fullscreen"
---@return Modal self
function Modal:SetSize(size)
    self.size_ = size
    return self
end

-- ============================================================================
-- Stateful
-- ============================================================================

function Modal:IsStateful()
    return true
end

-- ============================================================================
-- Static Helper: Confirm Dialog
-- ============================================================================

--- Create a confirm dialog
---@param options table { title, message, confirmText, cancelText, onConfirm, onCancel }
---@return Modal
function Modal.Confirm(options)
    local Label = require("urhox-libs/UI/Widgets/Label")
    local Button = require("urhox-libs/UI/Widgets/Button")
    local Panel = require("urhox-libs/UI/Widgets/Panel")

    options = options or {}

    local modal = Modal({
        title = options.title or "请确认",
        size = "sm",
    })

    -- Message
    modal:AddContent(Label({
        text = options.message or "确定要继续吗？",
        color = Theme.Color("text"),
    }))

    -- Footer buttons
    local footer = Panel({
        flexDirection = "row",
        justifyContent = "flex-end",
        gap = 10,
        width = "100%",
    })

    footer:AddChild(Button({
        text = options.cancelText or "取消",
        variant = "secondary",
        onClick = function()
            modal:Close()
            if options.onCancel then
                options.onCancel()
            end
        end,
    }))

    footer:AddChild(Button({
        text = options.confirmText or "确认",
        variant = "primary",
        onClick = function()
            modal:Close()
            if options.onConfirm then
                options.onConfirm()
            end
        end,
    }))

    modal:SetFooter(footer)
    modal:Open()

    return modal
end

--- Create an alert dialog
---@param options table { title, message, buttonText, onClose }
---@return Modal
function Modal.Alert(options)
    local Label = require("urhox-libs/UI/Widgets/Label")
    local Button = require("urhox-libs/UI/Widgets/Button")
    local Panel = require("urhox-libs/UI/Widgets/Panel")

    options = options or {}

    local modal = Modal({
        title = options.title or "提示",
        size = "sm",
        closeOnOverlay = false,
    })

    -- Message
    modal:AddContent(Label({
        text = options.message or "",
        color = Theme.Color("text"),
    }))

    -- Footer button
    local footer = Panel({
        flexDirection = "row",
        justifyContent = "flex-end",
        width = "100%",
    })

    footer:AddChild(Button({
        text = options.buttonText or "确定",
        variant = "primary",
        onClick = function()
            modal:Close()
            if options.onClose then
                options.onClose()
            end
        end,
    }))

    modal:SetFooter(footer)
    modal:Open()

    return modal
end

return Modal

