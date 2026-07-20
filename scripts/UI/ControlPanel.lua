local UI = require("urhox-libs/UI")
local Themes = require("Config.Themes")
local ThemePacks = require("Config.ThemePacks")
local GenericThemeRules = require("Config.GenericThemeRules")
local RoomGroupColors = require("Config.RoomGroupColors")
local MultiFloor = require("Generation.MultiFloor")
local PaletteData = require("Config.PaletteData")
local TextArea = require("UI.TextArea")
local OriginalModal = require("UI.OriginalModal")

local ControlPanel = {}
ControlPanel.__index = ControlPanel

local C = {
    panel = { 16, 19, 29, 232 }, section = { 17, 21, 32, 255 }, line = { 37, 42, 58, 255 },
    input = { 21, 25, 37, 255 }, inputLine = { 48, 53, 72, 255 },
    text = { 224, 228, 238, 255 }, bright = { 244, 246, 251, 255 }, dim = { 154, 162, 182, 255 },
    accent = { 232, 151, 63, 255 }, teal = { 63, 208, 187, 255 }, danger = { 216, 67, 58, 255 },
}

local function Label(text, size, color, extra)
    local props = extra or {}
    props.text, props.fontSize, props.fontColor = text, size or 12, color or C.text
    return UI.Label(props)
end

local function Row(children, extra)
    local props = extra or {}
    props.width, props.flexDirection, props.gap, props.children = props.width or "100%", "row", props.gap or 6, children
    return UI.Panel(props)
end

local function Section(children)
    return UI.Panel {
        width = "100%", padding = { 9, 12 }, gap = 7, flexShrink = 0,
        borderColor = C.line, borderBottomWidth = 1,
        children = children,
    }
end

local function SmallButton(text, onClick, extra)
    local props = extra or {}
    props.text, props.onClick = text, onClick
    props.variant = props.variant or "secondary"
    props.height, props.fontSize, props.paddingHorizontal = props.height or 31, props.fontSize or 11, props.paddingHorizontal or 8
    if props.backgroundColor == nil then props.backgroundColor = C.input end
    if props.borderColor == nil then props.borderColor = C.inputLine end
    if props.borderWidth == nil then props.borderWidth = 1 end
    if props.borderRadius == nil then props.borderRadius = 8 end
    return UI.Button(props)
end

local function PillButton(text, onClick, extra)
    local props = extra or {}
    props.borderRadius = 999
    props.height = props.height or 27
    props.fontSize = props.fontSize or 10
    return SmallButton(text, onClick, props)
end

local function AddButton(text, onClick)
    return SmallButton(text, onClick, {
        width = 66, height = 27, fontSize = 9.0,
        backgroundColor = { 17, 26, 25, 255 },
        borderColor = { 53, 80, 72, 255 },
        textColor = { 169, 207, 197, 255 },
        borderRadius = 7,
    })
end

local function DiceIcon(color)
    local icon = UI.Panel {
        width = 18, height = 18, position = "relative", pointerEvents = "none",
    }
    icon:AddChild(UI.Panel {
        position = "absolute", left = 1, top = 1, width = 16, height = 16,
        backgroundColor = { 0, 0, 0, 0 }, borderColor = color,
        borderWidth = 2, borderRadius = 4, pointerEvents = "none",
    })
    local dotSize = 3
    for _, point in ipairs({
        { x = 4, y = 4 }, { x = 11, y = 4 }, { x = 7.5, y = 7.5 },
        { x = 4, y = 11 }, { x = 11, y = 11 },
    }) do
        icon:AddChild(UI.Panel {
            position = "absolute", left = point.x, top = point.y,
            width = dotSize, height = dotSize, backgroundColor = color,
            borderRadius = dotSize * 0.5, pointerEvents = "none",
        })
    end
    return icon
end

local function TriangleIcon(color)
    local function Chevron(rotation)
        local chevron = UI.Panel {
            width = 16, height = 16, position = "relative", rotate = rotation,
            transformOrigin = "center", pointerEvents = "none",
        }
        local left = UI.Panel {
            position = "absolute", left = 1, top = 7, width = 8, height = 2,
            backgroundColor = color, borderRadius = 1, rotate = 35,
            transformOrigin = "center", pointerEvents = "none",
        }
        local right = UI.Panel {
            position = "absolute", left = 7, top = 7, width = 8, height = 2,
            backgroundColor = color, borderRadius = 1, rotate = -35,
            transformOrigin = "center", pointerEvents = "none",
        }
        chevron:AddChild(left)
        chevron:AddChild(right)
        chevron.segments = { left, right }
        return chevron
    end
    local icon = UI.Panel {
        width = 16, height = 16, position = "relative", pointerEvents = "none",
    }
    local down = Chevron(0)
    local up = Chevron(180)
    up:SetVisible(false)
    icon:AddChild(down)
    icon:AddChild(up)
    icon.downTriangle, icon.upTriangle = down, up
    return icon
end

local function RandomButton(onClick, extra)
    local props = extra or {}
    props.width = props.width or 32
    props.height = props.height or 27
    props.fontSize = props.fontSize or 16
    props.backgroundColor = props.backgroundColor or { 40, 31, 27, 255 }
    props.borderColor = props.borderColor or { 112, 77, 48, 255 }
    props.textColor = props.textColor or { 255, 209, 157, 255 }
    props.borderRadius = props.borderRadius or 7
    props.paddingHorizontal, props.paddingVertical = 0, 0
    props.alignItems, props.justifyContent = "center", "center"
    props.children = { DiceIcon(props.textColor) }
    return SmallButton(nil, onClick, props)
end

local function TooltipButton(button, content)
    return UI.Tooltip {
        content = content, position = "top", delay = 0.18,
        children = { button },
    }
end

local function ExpandButton(onClick)
    local icon = TriangleIcon(C.dim)
    local button = SmallButton(nil, onClick, {
        width = 32, height = 27, fontSize = 16,
        paddingHorizontal = 0, paddingVertical = 0,
        alignItems = "center", justifyContent = "center",
        backgroundColor = C.input, borderColor = C.inputLine,
        textColor = C.dim, borderRadius = 7, children = { icon },
    })
    function button:SetExpanded(expanded)
        local triangle = self.props.children[1]
        local iconColor = expanded and C.accent or C.dim
        triangle.downTriangle:SetVisible(not expanded)
        triangle.upTriangle:SetVisible(expanded)
        for _, segment in ipairs(triangle.downTriangle.segments) do
            segment:SetStyle({ backgroundColor = iconColor })
        end
        for _, segment in ipairs(triangle.upTriangle.segments) do
            segment:SetStyle({ backgroundColor = iconColor })
        end
        self:SetStyle({
            backgroundColor = expanded and { 48, 36, 29, 255 } or C.input,
            borderColor = expanded and C.accent or C.inputLine,
        })
    end
    return button
end

local function FloorSetting(labelText, valueLabel, slider)
    return UI.Panel {
        width = "100%", padding = { 6, 7, 2, 7 }, gap = 3,
        backgroundColor = C.section, borderColor = { 36, 42, 58, 255 }, borderWidth = 1, borderRadius = 6,
        children = {
            Row({ Label(labelText, 10, C.text, { flexGrow = 1 }), valueLabel }),
            slider,
        },
    }
end

local function PreviewButton(code, title, hint, onClick)
    local icon = Label(code, 9, C.accent, {
        width = 29, height = 29, textAlign = "center", verticalAlign = "middle",
        backgroundColor = { 11, 15, 23, 255 }, borderColor = { 91, 70, 50, 255 },
        borderWidth = 1, borderRadius = 5,
    })
    local button = UI.Button {
        width = 142, height = 44, padding = 7, gap = 9, flexDirection = "row", alignItems = "center",
        backgroundColor = { 20, 25, 37, 245 }, borderColor = { 48, 55, 74, 255 },
        borderWidth = 1, borderRadius = 7, onClick = onClick,
        children = {
            icon,
            UI.Panel { gap = 3, children = {
                Label(title, 11, C.text, { fontWeight = "bold" }),
                Label(hint, 8, { 114, 124, 145, 255 }),
            } },
        },
    }
    return button
end

local function PaletteSwatch(color, size)
    return UI.Panel {
        width = size or 14, height = size or 14, flexShrink = 0,
        backgroundColor = PaletteData.ToRGBA(color), borderColor = { 255, 255, 255, 48 },
        borderWidth = 1, borderRadius = 4,
    }
end

local function Trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function FirstCharacter(value)
    local nextByte = utf8.offset(value or "", 2)
    return nextByte and string.sub(value, 1, nextByte - 1) or (value or "")
end

local function FieldLabel(text, suffix)
    return Row({
        Label(text, 11, C.text, { fontWeight = "bold", flexGrow = 1 }),
        suffix and Label(suffix, 9, C.dim) or nil,
    })
end

local ROOM_TYPE_LABELS = {
    classroom = "教室", library = "图书馆", laboratory = "实验室", cafeteria = "食堂",
    default = "普通教室", combat = "教室", elite = "实验室", shrine = "图书馆",
    entrance = "入口大厅", boss = "礼堂", treasure = "资料室", special = "公共空间",
}

local function CountKeys(value)
    local count = 0
    for _ in pairs(type(value) == "table" and value or {}) do count = count + 1 end
    return count
end

local function JoinRuleLabels(rules)
    local labels = {}
    for key in pairs(type(rules) == "table" and rules or {}) do
        labels[#labels + 1] = ROOM_TYPE_LABELS[key] or key
    end
    table.sort(labels)
    return #labels > 0 and table.concat(labels, "、") or "通用房间"
end

local activeDropOwner = nil
local dropEventSubscribed = false
local keyEventSubscribed = false

function HandleDungeonReferenceImageDropped(_, eventData)
    if activeDropOwner then activeDropOwner:HandleReferenceImageDropped(eventData) end
end

function HandleDungeonReferenceImagePasteKey(_, eventData)
    if activeDropOwner then activeDropOwner:HandleReferenceImagePasteKey(eventData) end
end

function ControlPanel.new(callbacks, initial)
    local self = setmetatable({ callbacks = callbacks, seed = initial.seed, collapsed = false }, ControlPanel)
    if not nvgSetRenderOrder then nvgSetRenderOrder = function() end end
    UI.Init({ theme = "default-dark", scale = UI.Scale.DEFAULT })
    activeDropOwner = self
    if not dropEventSubscribed then
        SubscribeToEvent("DropFile", "HandleDungeonReferenceImageDropped")
        dropEventSubscribed = true
    end
    if not keyEventSubscribed then
        SubscribeToEvent("KeyDown", "HandleDungeonReferenceImagePasteKey")
        keyEventSubscribed = true
    end

    self.title = Label("场景锻炉", 10, C.accent, { fontWeight = "bold", letterSpacing = 1.8 })
    self.name = Label("程序化房间生成器", 17, C.bright, { fontWeight = "normal", whiteSpace = "normal", lineHeight = 1.18 })
    self.subtitle = Label("遗迹 · 暖灰 · 种子 1337 · 已连通 ✓", 10, C.dim, { whiteSpace = "normal" })
    self.collapseButton = SmallButton("−", function() self:SetCollapsed(true) end, {
        position = "absolute", right = 9, top = 8, width = 34, height = 30,
        backgroundColor = { 20, 25, 37, 245 },
    })

    self.seedField = UI.TextField {
        value = tostring(initial.seed), placeholder = "种子", flexGrow = 1, height = 31,
        borderRadius = 8, borderColor = C.inputLine, focusedBorderColor = C.accent,
        paddingHorizontal = 8, fontSize = 12,
        onChange = function(_, value) local n = tonumber(value); if n then self.seed = math.floor(n) end end,
        onSubmit = function(_, value) local n = tonumber(value); if n then callbacks.onGenerate(math.floor(n)) end end,
    }
    self.randomSeedButton = RandomButton(function() callbacks.onRandomSeed() end, {
        width = 34, height = 31, fontSize = 17,
    })
    self.randomSeedTooltip = TooltipButton(self.randomSeedButton, "随机种子")

    self.settingButtons = {}
    for _, key in ipairs(Themes.settingOrder) do
        local setting = Themes.GetSetting(key)
        self.settingButtons[key] = PillButton(setting.label, function() callbacks.onSetting(key) end,
            { width = 44, paddingHorizontal = 2, fontSize = 9.5 })
    end

    self.paletteExpanded = false
    self.currentPaletteButton = PillButton("当前颜色", function()
        self:SetPaletteExpanded(not self.paletteExpanded)
    end, { flexGrow = 1, height = 28, fontSize = 10, textAlign = "left" })
    self.paletteExpandedList = UI.Panel { width = "100%", gap = 6 }
    self.paletteExpandedList:SetVisible(false)
    self.paletteToggleButton = ExpandButton(function() self:SetPaletteExpanded(not self.paletteExpanded) end)
    self.paletteToggleTooltip = TooltipButton(self.paletteToggleButton, "展开色调")
    self.paletteCustomButton = AddButton("＋ 自定义", function() self:OpenCustomPaletteModal() end)
    self.randomSettingButton = RandomButton(function() callbacks.onRandomSetting() end)
    self.randomThemeButton = RandomButton(function() callbacks.onRandomTheme() end)
    self.randomSettingTooltip = TooltipButton(self.randomSettingButton, "随机题材")
    self.randomThemeTooltip = TooltipButton(self.randomThemeButton, "随机色调")
    self.customSettingButton = AddButton("＋ 自定义", function() self:OpenCustomSettingModal() end)
    self.customSettingExpanded = false
    self.customSettingToggleButton = ExpandButton(function()
        self:SetCustomSettingExpanded(not self.customSettingExpanded)
    end)
    self.customSettingToggleTooltip = TooltipButton(self.customSettingToggleButton, "展开题材")

    self.fixedSettingModeButton = PillButton("固定 PCG", function()
        callbacks.onFixedPCG()
    end, { width = 56, paddingHorizontal = 2, fontSize = 9.5 })

    self.floorSummary = Label("共 2 层 · 42 区", 11, C.accent, { fontWeight = "bold" })
    self.floorDropdown = UI.Dropdown {
        width = "100%", value = 0, maxVisibleItems = 6,
        options = { { value = 0, label = "第 1 层 · 21 个区域（当前）" }, { value = 1, label = "第 2 层 · 21 个区域" } },
        onChange = function(_, value) callbacks.onFloorSelect(math.floor(value)) end,
    }
    self.roomValue = Label("21", 11, C.accent, { fontWeight = "bold" })
    self.roomSlider = UI.Slider { value = 21, min = 6, max = 50, step = 1,
        onChange = function(_, value) self.roomValue:SetText(tostring(math.floor(value + 0.5))) end,
        onChangeEnd = function(_, value) callbacks.onRoomCount(math.floor(value + 0.5)) end }
    self.loopValue = Label("15%", 11, C.accent, { fontWeight = "bold" })
    self.loopSlider = UI.Slider { value = 15, min = 0, max = 40, step = 1,
        onChange = function(_, value) self.loopValue:SetText(string.format("%d%%", math.floor(value + 0.5))) end,
        onChangeEnd = function(_, value) callbacks.onLoopRate(math.floor(value + 0.5)) end }
    self.decorValue = Label("60%", 11, C.accent, { fontWeight = "bold" })
    self.decorSlider = UI.Slider { value = 60, min = 0, max = 100, step = 1,
        onChange = function(_, value) self.decorValue:SetText(string.format("%d%%", math.floor(value + 0.5))) end,
        onChangeEnd = function(_, value) callbacks.onDecorDensity(math.floor(value + 0.5)) end }

    self.viewButtons = {}
    local viewLabels = { current = "当前", neighbors = "相邻", all = "全部", explode = "展开" }
    for _, key in ipairs({ "current", "neighbors", "all", "explode" }) do
        self.viewButtons[key] = PillButton(viewLabels[key], function() callbacks.onFloorView(key) end, { flexGrow = 1, fontSize = 9 })
    end

    self.stats = Label("等待生成…", 11, C.dim, { whiteSpace = "normal", lineHeight = 1.4 })
    self.edit2DButton = UI.Button {
        text = "▦ 2D 平面", width = 106, height = 40, fontSize = 12,
        backgroundColor = { 18, 23, 35, 245 }, borderColor = C.line, borderWidth = 1,
        onClick = function() callbacks.onOpenEditor2D() end,
    }
    self.edit3DButton = UI.Button {
        text = "◇ 3D 编辑  E", width = 118, height = 40, fontSize = 12,
        backgroundColor = { 18, 23, 35, 245 }, borderColor = C.line, borderWidth = 1,
        onClick = function() callbacks.onToggleEditor() end,
    }
    self.editButton = self.edit3DButton
    self.editorButtons = UI.Panel {
        flexDirection = "row", gap = 6, children = { self.edit2DButton, self.edit3DButton },
    }
    self.hints = Label(
        "相机：WASD/方向键移动，Shift 加速 · 鼠标左键拖拽平移 · Ctrl+鼠标左键拖拽升降 · 鼠标右键拖拽（或 Shift+鼠标左键拖拽）旋转 · 滚轮缩放 · Home 复原\n编辑：直接点 2D 平面，E 进入 3D 编辑 · R 重新生成 · T 切换色调 · Shift+T 切换题材",
        10, C.dim,
        { position = "absolute", bottom = 14, left = "24%", right = "18%", minHeight = 46,
            textAlign = "center", whiteSpace = "normal", lineHeight = 1.35,
            backgroundColor = { 11, 14, 23, 220 }, padding = 8, borderRadius = 18 })

    self.thirdPreviewButton = PreviewButton("三", "第三人称", "观察角色与空间",
        function() callbacks.onPreview("third") end)
    self.firstPreviewButton = PreviewButton("一", "第一人称", "检查室内尺度",
        function() callbacks.onPreview("first") end)
    self.previewExitButton = SmallButton("退出预览  Esc", function() callbacks.onExitPreview() end, {
        width = 108, height = 44, fontSize = 10, backgroundColor = { 20, 25, 37, 245 },
        borderColor = { 93, 73, 56, 255 }, borderWidth = 1,
    })
    self.previewExitButton:SetVisible(false)

    self.previewBar = UI.Panel {
        height = 54, padding = 5, gap = 5, flexDirection = "row", alignItems = "center",
        backgroundColor = { 13, 17, 25, 238 }, borderColor = { 48, 56, 75, 255 },
        borderWidth = 1, borderRadius = 10, backdropBlur = 12,
        boxShadow = { { x = 0, y = 12, blur = 34, spread = 0, color = { 0, 0, 0, 180 } } },
        children = {
            UI.Panel { width = 74, paddingLeft = 7, paddingRight = 10, gap = 4,
                borderRightWidth = 1, borderColor = { 52, 59, 77, 255 }, children = {
                    Label("视角", 7, { 110, 120, 144, 255 }),
                    Label("视角预览", 11, C.text, { fontWeight = "bold" }),
                }
            },
            self.thirdPreviewButton, self.firstPreviewButton, self.previewExitButton,
        }
    }
    self.previewBarAnchor = UI.Panel {
        position = "absolute", left = 0, right = 0, bottom = 48, height = 54,
        alignItems = "center", pointerEvents = "box-none", children = { self.previewBar },
    }

    self.previewModeLabel = Label("第三人称预览", 14, C.text, { fontWeight = "bold" })
    self.previewViewHint = Label("跟随角色观察房间布局与动线", 9, { 142, 152, 170, 255 })
    self.previewCrosshair = Label("○", 12, { 217, 224, 234, 150 }, {
        position = "absolute", left = "50%", top = "50%",
    })
    self.previewHud = UI.Panel {
        position = "absolute", left = 0, right = 0, top = 0, bottom = 0, pointerEvents = "box-none",
        children = {
            UI.Panel { position = "absolute", top = 22, left = 22, minWidth = 238,
                padding = { 11, 15 }, gap = 5, backgroundColor = { 12, 17, 25, 225 },
                borderLeftWidth = 2, borderColor = C.accent, children = {
                    Label("当前视角", 8, { 119, 129, 152, 255 }), self.previewModeLabel, self.previewViewHint,
                }
            },
            UI.Panel { position = "absolute", left = "28%", right = "28%", bottom = 101,
                padding = { 7, 12 }, borderRadius = 5, backgroundColor = { 10, 14, 21, 205 },
                borderColor = { 48, 55, 73, 255 }, borderWidth = 1, alignItems = "center",
                children = { Label(
                    "WASD 移动角色 · Shift+WASD 奔跑 · 鼠标右键拖拽环视 · 滚轮缩放第三人称镜头 · 1/2 切换视角 · Esc 返回观察",
                    9, { 143, 152, 170, 255 }, { textAlign = "center", whiteSpace = "normal" }) },
            },
            self.previewCrosshair,
        }
    }
    self.previewHud:SetVisible(false)
    self.previewCrosshair:SetVisible(false)

    self.customModalTitle = Label("新建题材包", 20, C.text, { fontWeight = "bold" })
    self.customModalEyebrow = Label("AI 题材生成", 9.5, C.accent, {
        fontWeight = "bold", letterSpacing = 0.5,
    })
    self.customNameField = UI.TextField {
        width = "100%", height = 46, value = "", maxLength = 24, placeholder = "例如：深海研究站",
        borderRadius = 8, borderColor = { 52, 58, 77, 255 }, focusedBorderColor = C.accent,
        paddingHorizontal = 11, fontSize = 13,
        onChange = function() if not self.updatingCustomForm then self:RefreshCustomSettingPlan() end end,
    }
    self.customFloorHeightHint = Label("美术基准 5.00 米 · 运行比例 1.00", 9, C.dim, {
        whiteSpace = "normal",
    })
    self.customFloorHeightField = UI.TextField {
        width = 92, height = 36, value = "5.00", maxLength = 5, placeholder = "5.00",
        borderRadius = 7, borderColor = { 52, 58, 77, 255 }, focusedBorderColor = C.accent,
        paddingHorizontal = 9, fontSize = 12, textAlign = "right",
        onChange = function()
            if not self.updatingCustomForm then
                self:RefreshCustomFloorHeightHint()
                self:RefreshCustomSettingPlan()
            end
        end,
    }
    local baseSettingOptions = {}
    for _, key in ipairs(Themes.settingOrder) do
        local setting = Themes.GetSetting(key)
        baseSettingOptions[#baseSettingOptions + 1] = {
            value = key,
            label = setting.label .. " · " .. (setting.description or "程序化题材包"),
        }
    end
    self.customBaseSettingDropdown = UI.Dropdown {
        width = "100%", value = initial.settingKey or "dungeon", maxVisibleItems = 4,
        options = baseSettingOptions,
        onChange = function() if not self.updatingCustomForm then self:RefreshCustomSettingPlan() end end,
    }
    self.customPromptField = TextArea {
        width = "100%", height = 104, value = "", maxLength = 1200,
        backgroundColor = { 22, 26, 38, 255 }, borderRadius = 8,
        borderColor = { 52, 58, 77, 255 }, focusedBorderColor = C.accent, fontSize = 13,
        placeholder = "描述环境、建筑、材质、道具和氛围，例如：位于海沟中的废弃研究站，厚重金属舱门，观景窗外有微光水母…",
        onChange = function() if not self.updatingCustomForm then self:RefreshCustomSettingPlan() end end,
    }
    self.customImageName = Label("", 10, C.text, { flexGrow = 1, whiteSpace = "normal" })
    self.customImageThumb = UI.Panel {
        width = 92, height = 64, borderRadius = 6, backgroundColor = { 25, 30, 42, 255 },
        borderColor = C.line, borderWidth = 1, backgroundFit = "cover", overflow = "hidden",
    }
    self.customImagePreview = Row({
        self.customImageThumb,
        UI.Panel { flexGrow = 1, gap = 7, children = {
            self.customImageName,
            Row({
                SmallButton("重新粘贴", function() self:ActivateReferenceImagePaste("custom") end, {
                    width = 82, height = 27, textColor = C.teal, borderColor = { 66, 83, 94, 255 },
                }),
                SmallButton("移除图片", function() self:SetReferenceImage("custom", nil, nil) end, { width = 82, height = 27 }),
            }, { gap = 6 }),
        } },
    }, { alignItems = "center" })
    self.customImagePreview:SetVisible(false)
    self.customUploadButton = UI.Button {
        flexGrow = 1, height = 42, paddingHorizontal = 10, borderWidth = 1,
        borderColor = { 70, 72, 79, 255 }, borderRadius = 5, backgroundColor = { 43, 43, 43, 255 },
        onClick = function() self:ActivateReferenceImagePaste("custom") end,
        children = {
            Label("▧  粘贴或拖入参考图", 11, { 218, 220, 224, 255 }, {
                fontWeight = "bold", textAlign = "center",
            }),
        },
        justifyContent = "center", alignItems = "center",
    }
    self.customImageInputRow = UI.Panel {
        width = "100%", padding = 8, gap = 6, backgroundColor = { 24, 24, 25, 255 },
        borderColor = { 57, 58, 62, 255 }, borderWidth = 1, borderRadius = 8,
        children = {
            Row({ self.customUploadButton,
                SmallButton("历史记录", function() self:OpenImageHistory("custom") end, {
                    width = 88, height = 42,
                }),
            }, { gap = 6 }),
            Label("支持常用图片格式，单张上限 20 MB", 8.5, { 145, 151, 161, 255 }),
        },
    }
    self.customSettingError = Label("", 10, C.danger, { whiteSpace = "normal" })

    self.customAdvancedExpanded = false
    self.customAdvancedPanel = UI.Panel { width = "100%", padding = { 9, 10 }, gap = 7,
        backgroundColor = { 13, 17, 26, 255 }, borderColor = C.line, borderWidth = 1, borderRadius = 8,
        children = {
            FieldLabel("参考生成体系", "仅影响已安装规则的匹配"), self.customBaseSettingDropdown,
        },
    }
    self.customAdvancedPanel:SetVisible(false)
    self.customAdvancedButton = SmallButton("+ 高级设置", function()
        self:SetCustomAdvancedExpanded(not self.customAdvancedExpanded)
    end, { width = 108, height = 28, fontSize = 9.5, backgroundColor = { 18, 22, 32, 255 } })

    self.customFormPanel = UI.Panel { width = "100%", gap = 10, children = {
        FieldLabel("题材名称", "必填"), self.customNameField,
        FieldLabel("基础场景参数", "保存到题材规则"),
        UI.Panel {
            width = "100%", padding = { 8, 10 }, gap = 6,
            backgroundColor = { 13, 17, 26, 255 }, borderColor = C.line,
            borderWidth = 1, borderRadius = 8,
            children = {
                Row({
                    Label("层高", 11, C.text, { fontWeight = "bold", flexGrow = 1 }),
                    self.customFloorHeightField, Label("米", 10, C.dim, { width = 18 }),
                }, { alignItems = "center" }),
                self.customFloorHeightHint,
                Label(string.format("可设置 %.1f–%.1f 米；同步影响楼层间距、结构纵向比例、楼梯和相机。",
                    MultiFloor.MIN_FLOOR_HEIGHT, MultiFloor.MAX_FLOOR_HEIGHT), 8.5, C.dim,
                    { whiteSpace = "normal", lineHeight = 1.35 }),
            },
        },
        Row({ Label("描述你希望生成的场景", 11, C.text, { fontWeight = "bold", flexGrow = 1 }),
            Label("生成时必填；草稿可留空", 9, C.dim) }),
        self.customPromptField,
        FieldLabel("参考图片", "可选"), self.customImageInputRow, self.customImagePreview,
        self.customAdvancedButton, self.customAdvancedPanel,
    } }

    self.customPlanStatus = Label("等待分析", 12, C.accent, { fontWeight = "bold" })
    self.customPlanDescription = Label("", 10, C.dim, { whiteSpace = "normal", lineHeight = 1.45 })
    self.customPlanStructure = Label("", 10.5, C.text, { flexGrow = 1, whiteSpace = "normal" })
    self.customPlanRooms = Label("", 10.5, C.text, { flexGrow = 1, whiteSpace = "normal" })
    self.customPlanProps = Label("", 10.5, C.text, { flexGrow = 1, whiteSpace = "normal" })
    self.customPlanMaterials = Label("", 10.5, C.text, { flexGrow = 1, whiteSpace = "normal" })
    self.customPlanPanel = UI.Panel { width = "100%", gap = 10, children = {
        UI.Panel { width = "100%", padding = { 12, 13 }, gap = 5, backgroundColor = { 12, 17, 25, 255 },
            borderColor = C.line, borderWidth = 1, borderRadius = 9,
            children = { self.customPlanStatus, self.customPlanDescription } },
        Label("将要生成的内容", 11, C.text, { fontWeight = "bold" }),
        UI.Panel { width = "100%", padding = { 11, 13 }, gap = 10, backgroundColor = { 20, 24, 35, 255 },
            borderColor = { 45, 51, 68, 255 }, borderWidth = 1, borderRadius = 9,
            children = {
                Row({ Label("建筑结构", 9, C.dim, { width = 76 }), self.customPlanStructure }),
                Row({ Label("房间类型", 9, C.dim, { width = 76 }), self.customPlanRooms }),
                Row({ Label("道具规则", 9, C.dim, { width = 76 }), self.customPlanProps }),
                Row({ Label("PBR 材质", 9, C.dim, { width = 76 }), self.customPlanMaterials }),
            } },
        Label("生成成功后会切换到该题材并刷新本地场景预览。", 9.5, C.dim, {
            whiteSpace = "normal", lineHeight = 1.4,
        }),
    } }
    self.customSettingModal = OriginalModal {
        size = "md", dialogWidth = 620, dialogMaxHeight = 100000,
        closeOnOverlay = true, closeOnEscape = true, showCloseButton = false,
        contentPadding = 18, contentGap = 12, footerPadding = { 14, 18 }, footerBorderWidth = 1,
        borderRadius = 14, backgroundColor = { 17, 20, 29, 248 }, backdropColor = { 3, 5, 10, 184 },
        borderColor = { 52, 58, 77, 255 }, borderWidth = 1,
        footerBorderColor = { 40, 46, 64, 255 },
        boxShadow = { { x = 0, y = 24, blur = 80, spread = 0, color = { 0, 0, 0, 215 } } },
        children = {
            Row({
                UI.Panel { flexGrow = 1, gap = 4, children = {
                    self.customModalEyebrow, self.customModalTitle,
                } },
                SmallButton("×", function() self.customSettingModal:Close() end, {
                    width = 34, height = 34, fontSize = 18, backgroundColor = { 20, 24, 35, 255 },
                }),
            }, { alignItems = "center" }),
            self.customFormPanel,
            UI.Panel { width = "100%", height = 1, backgroundColor = { 40, 46, 64, 255 } },
            self.customPlanPanel,
            self.customSettingError,
        },
    }
    self.customDraftButton = SmallButton("保存草稿", function() self:ApplyCustomSetting("draft") end, {
        width = 82,
    })
    self.customGenerateButton = SmallButton("生成并预览", function() self:ApplyCustomSetting("generate") end, {
        width = 112, variant = "primary", backgroundColor = C.accent, borderColor = C.accent,
        textColor = { 20, 16, 12, 255 }, fontWeight = "bold",
    })
    self.customSettingFooter = Row({
        SmallButton("取消", function() self.customSettingModal:Close() end, { width = 70 }),
        UI.Panel { flexGrow = 1 }, self.customDraftButton, self.customGenerateButton,
    }, { alignItems = "center", gap = 8 })
    self.customSettingModal:SetFooter(self.customSettingFooter)

    self.customRenameField = UI.TextField {
        width = "100%", height = 42, value = "", maxLength = 24, placeholder = "题材名称",
        borderRadius = 8, borderColor = C.inputLine, focusedBorderColor = C.accent,
        paddingHorizontal = 10, fontSize = 12,
    }
    self.customRenameError = Label("", 10, C.danger, { whiteSpace = "normal" })
    self.customRenameModal = OriginalModal {
        size = "sm", dialogWidth = 400, closeOnOverlay = true, closeOnEscape = true,
        contentPadding = 18, contentGap = 10, showCloseButton = false,
        children = {
            Label("重命名题材", 18, C.text, { fontWeight = "bold" }),
            FieldLabel("新名称", "必填"), self.customRenameField, self.customRenameError,
        },
    }
    self.customRenameModal:SetFooter(Row({
        SmallButton("取消", function() self.customRenameModal:Close() end, { flexGrow = 1 }),
        SmallButton("保存名称", function() self:ApplyCustomSettingRename() end, {
            width = 92, variant = "primary", backgroundColor = C.accent, borderColor = C.accent,
            textColor = { 20, 16, 12, 255 }, fontWeight = "bold",
        }),
    }, { gap = 8 }))

    self.paletteModalTitle = Label("添加自定义配色", 20, C.text, { fontWeight = "bold" })
    self.paletteNameField = UI.TextField {
        width = "100%", height = 42, value = "", maxLength = 24, placeholder = "例如：月蚀紫",
        borderRadius = 8, borderColor = { 52, 58, 77, 255 }, focusedBorderColor = C.accent,
        paddingHorizontal = 11, fontSize = 13,
    }
    self.paletteBaseSettingDropdown = UI.Dropdown {
        width = "100%", value = initial.settingKey or "dungeon", maxVisibleItems = 4,
        options = baseSettingOptions,
    }
    self.palettePromptField = TextArea {
        width = "100%", height = 76, value = "", maxLength = 600,
        backgroundColor = { 22, 26, 38, 255 }, borderRadius = 8,
        borderColor = { 52, 58, 77, 255 }, focusedBorderColor = C.accent, fontSize = 12,
        placeholder = "给 AI 的配色描述，例如：冷峻月光下的紫灰石材，少量高饱和洋红发光符文…",
    }
    self.paletteDataField = TextArea {
        width = "100%", height = 198, value = "", maxLength = 1800,
        backgroundColor = { 12, 16, 24, 255 }, borderRadius = 8,
        borderColor = { 52, 58, 77, 255 }, focusedBorderColor = C.teal, fontSize = 11,
        placeholder = "粘贴 AI 生成的 JSON 配色数据",
    }
    self.paletteError = Label("", 10, C.danger, { whiteSpace = "normal" })
    self.paletteDeleteButton = SmallButton("删除配色", function() self:ConfirmDeleteCustomPalette() end, {
        width = 88, variant = "danger",
    })
    self.paletteModal = OriginalModal {
        size = "lg", dialogWidth = 620, dialogMaxHeight = 700,
        closeOnOverlay = true, closeOnEscape = true, showCloseButton = false,
        contentPadding = 18, contentGap = 9, footerPadding = { 14, 18 }, footerBorderWidth = 1,
        borderRadius = 14, backgroundColor = { 17, 20, 29, 248 }, backdropColor = { 3, 5, 10, 184 },
        borderColor = { 52, 58, 77, 255 }, borderWidth = 1,
        footerBorderColor = { 40, 46, 64, 255 },
        boxShadow = { { x = 0, y = 24, blur = 80, spread = 0, color = { 0, 0, 0, 215 } } },
        children = {
            Row({
                UI.Panel { flexGrow = 1, gap = 4, children = {
                    Label("模型材质配色", 10, C.teal, { fontWeight = "bold", letterSpacing = 1.2 }), self.paletteModalTitle,
                } },
                SmallButton("×", function() self.paletteModal:Close() end, {
                    width = 34, height = 34, fontSize = 18, backgroundColor = { 20, 24, 35, 255 },
                }),
            }, { alignItems = "center" }),
            UI.Panel { width = "100%", padding = { 9, 11 }, backgroundColor = { 12, 20, 24, 255 },
                borderColor = { 43, 68, 65, 255 }, borderWidth = 1, borderRadius = 8, children = {
                    Label("配色只覆盖地面、墙体、结构、织物与发光物的颜色；灯光、雾效和 PBR 参数沿用基础色调。", 10,
                        { 154, 184, 177, 255 }, { whiteSpace = "normal", lineHeight = 1.45 }),
                } },
            FieldLabel("配色名称", "必填"), self.paletteNameField,
            FieldLabel("适用题材", "决定基础材质"), self.paletteBaseSettingDropdown,
            FieldLabel("AI 配色描述", "可复制给 AI"), self.palettePromptField,
            UI.Panel { width = "100%", height = 1, backgroundColor = { 40, 46, 64, 255 } },
            Row({
                Label("AI 配色数据", 11, C.text, { fontWeight = "bold", flexGrow = 1 }),
                SmallButton("复制 AI 指令", function() self:CopyPaletteAIPrompt() end, {
                    width = 92, height = 27, fontSize = 9, textColor = { 195, 171, 235, 255 },
                    borderColor = { 72, 57, 92, 255 },
                }),
                SmallButton("填入当前配色模板", function() self:FillPaletteTemplate() end, {
                    width = 126, height = 27, fontSize = 9, textColor = C.teal,
                    borderColor = { 51, 83, 77, 255 },
                }),
            }, { alignItems = "center" }),
            Label("固定 JSON 字段：floor / corridor / wall / pillar / accentObject / cloth / flame / flameCore",
                9, C.dim, { whiteSpace = "normal" }),
            self.paletteDataField, self.paletteError,
        },
    }
    self.paletteModal:SetFooter(Row({
        self.paletteDeleteButton,
        SmallButton("取消", function() self.paletteModal:Close() end, { flexGrow = 1 }),
        SmallButton("保存并使用", function() self:ApplyCustomPalette() end, {
            width = 108, variant = "primary", backgroundColor = C.teal, borderColor = C.teal,
            textColor = { 8, 24, 22, 255 }, fontWeight = "bold",
        }),
    }, { alignItems = "center", gap = 8 }))

    self.roomGroupModalTitle = Label("添加房间组", 20, C.text, { fontWeight = "bold" })
    self.roomGroupNameField = UI.TextField {
        width = "100%", height = 46, value = "", maxLength = 40, placeholder = "例如：医院病房",
        borderRadius = 8, borderColor = { 52, 58, 77, 255 }, focusedBorderColor = C.accent,
        paddingHorizontal = 11, fontSize = 13,
    }
    self.roomGroupColorHex = RoomGroupColors.ToHex(RoomGroupColors.FALLBACK)
    self.roomGroupColorPicker = UI.ColorPicker {
        width = "100%", size = "sm", color = self.roomGroupColorHex,
        showAlpha = false, showInput = true, showPresets = true,
        presets = { "#43D7AF", "#56B8D0", "#E0B657", "#E85D62", "#A783E8", "#FF8F70" },
        onChange = function(_, value) self.roomGroupColorHex = value.hex end,
    }
    self.roomGroupPromptField = TextArea {
        width = "100%", height = 122, value = "", maxLength = 1000,
        backgroundColor = { 22, 26, 38, 255 }, borderRadius = 8,
        borderColor = { 52, 58, 77, 255 }, focusedBorderColor = C.accent, fontSize = 13,
        placeholder = "描述空间用途、布局、物件、材质和氛围，例如：四床位住院病房，床头医疗设备，浅蓝色隔帘…",
    }
    self.roomGroupImageName = Label("未选择文件", 10, C.dim, { flexGrow = 1, whiteSpace = "normal" })
    self.roomGroupImageThumb = UI.Panel {
        width = 64, height = 42, borderRadius = 6, backgroundColor = { 25, 30, 42, 255 },
        borderColor = C.line, borderWidth = 1, backgroundFit = "cover", overflow = "hidden",
    }
    self.roomGroupImageThumb:SetVisible(false)
    self.roomGroupImageRemoveButton = SmallButton("移除图片", function() self:SetReferenceImage("room", nil, nil) end, { width = 82, height = 30 })
    self.roomGroupImageRow = Row({
        self.roomGroupImageThumb,
        self.roomGroupImageName,
        SmallButton("重新粘贴", function() self:ActivateReferenceImagePaste("room") end, {
            width = 82, height = 30, textColor = C.teal, borderColor = { 66, 83, 94, 255 },
        }),
        self.roomGroupImageRemoveButton,
    }, { alignItems = "center", height = 40, padding = 7, backgroundColor = { 22, 26, 38, 255 },
        borderColor = { 52, 58, 77, 255 }, borderWidth = 1, borderRadius = 8 })
    self.roomGroupImageRow:SetVisible(false)
    self.roomGroupUploadButton = UI.Button {
        width = "100%", height = 72, padding = 10, borderWidth = 1,
        borderColor = { 70, 72, 79, 255 }, borderRadius = 5, backgroundColor = { 43, 43, 43, 255 },
        onClick = function() self:ActivateReferenceImagePaste("room") end,
        children = {
            Label("▧  辅助粘贴 / 拖拽上传", 12, { 218, 220, 224, 255 }, {
                fontWeight = "bold", textAlign = "center",
            }),
            Label("点击此区域后，复制图片文件路径并按 Ctrl+V；也可直接拖入", 9, { 151, 157, 167, 255 }, {
                textAlign = "center",
            }),
        },
        gap = 6, justifyContent = "center", alignItems = "center",
    }
    self.roomGroupImageInputBox = UI.Panel {
        width = "100%", padding = 9, gap = 7, backgroundColor = { 24, 24, 25, 255 },
        borderColor = { 57, 58, 62, 255 }, borderWidth = 1, borderRadius = 8,
        children = {
            self.roomGroupUploadButton,
            SmallButton("从历史记录选择", function() self:OpenImageHistory("room") end, {
                width = "100%", height = 29,
            }),
            Label("支持 Maker 可识别的常用图片格式，单张上限 20 MB", 9,
                { 145, 151, 161, 255 }, { whiteSpace = "normal", lineHeight = 1.35 }),
        },
    }
    self.roomGroupError = Label("", 10, C.danger, { whiteSpace = "normal" })
    self.roomGroupDeleteButton = SmallButton("删除组", function() self:ConfirmDeleteRoomGroup() end, {
        width = 82, variant = "danger",
    })
    self.roomGroupModal = OriginalModal {
        size = "md", dialogWidth = 560, dialogMaxHeight = 100000,
        closeOnOverlay = true, closeOnEscape = true, showCloseButton = false,
        contentPadding = 18, contentGap = 12, footerPadding = { 14, 18 }, footerBorderWidth = 1,
        borderRadius = 14, backgroundColor = { 17, 20, 29, 248 }, backdropColor = { 3, 5, 10, 184 },
        borderColor = { 52, 58, 77, 255 }, borderWidth = 1,
        footerBorderColor = { 40, 46, 64, 255 },
        boxShadow = { { x = 0, y = 24, blur = 80, spread = 0, color = { 0, 0, 0, 215 } } },
        children = {
            Row({
                UI.Panel { flexGrow = 1, gap = 4, children = {
                    Label("房间设置", 10, C.accent, { fontWeight = "bold", letterSpacing = 1.2 }), self.roomGroupModalTitle,
                } },
                SmallButton("×", function() self.roomGroupModal:Close() end, {
                    width = 34, height = 34, fontSize = 18, backgroundColor = { 20, 24, 35, 255 },
                }),
            }, { alignItems = "center" }),
            FieldLabel("组名称"), self.roomGroupNameField,
            FieldLabel("自定义提示词"), self.roomGroupPromptField,
            FieldLabel("上传参考图", "可选"), self.roomGroupImageInputBox, self.roomGroupImageRow,
            FieldLabel("Room color"), self.roomGroupColorPicker,
            self.roomGroupError,
        },
    }
    self.roomGroupModal:SetFooter(Row({
        self.roomGroupDeleteButton,
        SmallButton("取消", function() self.roomGroupModal:Close() end, { flexGrow = 1 }),
        SmallButton("保存房间组", function() self:ApplyRoomGroup() end, {
            width = 108, variant = "primary", backgroundColor = C.accent, borderColor = C.accent,
            textColor = { 20, 16, 12, 255 }, fontWeight = "bold",
        }),
    }, { alignItems = "center", gap = 8 }))

    self.imageHistoryList = UI.Panel { width = "100%", gap = 7 }
    self.imageHistoryModal = OriginalModal {
        size = "sm", dialogWidth = 460, dialogMaxHeight = 560,
        closeOnOverlay = true, closeOnEscape = true, showCloseButton = false,
        contentPadding = 16, contentGap = 10, footerPadding = { 12, 16 }, footerBorderWidth = 1,
        borderRadius = 12, backgroundColor = { 17, 20, 29, 250 }, backdropColor = { 3, 5, 10, 190 },
        borderColor = { 52, 58, 77, 255 }, borderWidth = 1, footerBorderColor = { 40, 46, 64, 255 },
        children = {
            Row({
                UI.Panel { flexGrow = 1, gap = 3, children = {
                    Label("历史参考图", 18, C.text, { fontWeight = "bold" }),
                    Label("从已保存的题材和房间组中复用图片", 9, C.dim),
                } },
                SmallButton("×", function() self.imageHistoryModal:Close() end, {
                    width = 34, height = 34, fontSize = 18,
                }),
            }, { alignItems = "center" }),
            UI.ScrollView {
                width = "100%", maxHeight = 390, scrollY = true, showScrollbar = true,
                children = { self.imageHistoryList },
            },
        },
    }
    self.imageHistoryModal:SetFooter(SmallButton("关闭", function() self.imageHistoryModal:Close() end, {
        width = "100%", height = 32,
    }))

    self.customSettingList = UI.Panel { width = "100%", gap = 5 }
    self.customSettingHint = Label("自定义题材：单击切换 · 右键管理", 8.5, C.dim)
    self.customSettingHint:SetVisible(false)
    self.customSettingList:SetVisible(false)
    self.roomGroupExpanded = false
    self.roomGroupList = UI.Panel { width = "100%", gap = 5 }
    self.roomGroupList:SetVisible(false)
    self.roomGroupHint = Label("房间组：展开后管理可复用的房间布局", 8.5, C.dim)
    self.roomGroupHint:SetVisible(false)
    self.roomGroupAddButton = AddButton("＋ 添加", function() self:OpenRoomGroupModal() end)
    self.roomGroupToggleButton = ExpandButton(function()
        self:SetRoomGroupExpanded(not self.roomGroupExpanded)
    end)
    self.roomGroupToggleTooltip = TooltipButton(self.roomGroupToggleButton, "展开房间")
    self.roomSelectionLabel = Label("未选择房间", 10, C.dim, { flexGrow = 1 })
    self.roomGroupAssignmentDropdown = UI.Dropdown {
        width = "100%", value = "", maxVisibleItems = 8,
        options = { { value = "", label = "不赋予房间组" } },
        onChange = function(_, value)
            if self.updatingRoomAssignment then return end
            local ok, reason = callbacks.onRoomGroupAssign(value)
            if ok == false then self:SetStatus(reason or "房间组赋予失败") end
        end,
    }
    local logicalWidth = graphics:GetWidth() / math.max(1, graphics:GetDPR())
    local roomInspectorWidth = math.max(216, math.min(320, logicalWidth - 310 - 498))
    self.roomAssignmentPanel = UI.Panel {
        position = "absolute", left = 310, top = 18, width = roomInspectorWidth,
        minHeight = 104, padding = { 8, 13 }, gap = 6, zIndex = 3000,
        backgroundColor = { 13, 20, 28, 255 },
        borderColor = { 47, 76, 71, 255 }, borderWidth = 1, borderRadius = 8,
        boxShadow = { { x = 0, y = 10, blur = 26, spread = 0, color = { 0, 0, 0, 170 } } },
        children = {
            Row({ Label("当前房间", 9, C.teal, { fontWeight = "bold" }), self.roomSelectionLabel }),
            self.roomGroupAssignmentDropdown,
            Label("选择房间后，可在这里把可复用房间组赋予当前区域。", 8.5, C.dim,
                { whiteSpace = "normal", lineHeight = 1.35 }),
        },
    }
    self.roomAssignmentPanel:SetVisible(false)

    local content = UI.Panel {
        width = "100%", gap = 0, children = {
            UI.Panel {
                width = "100%", padding = { 11, 13, 10, 13 },
                borderColor = C.line, borderBottomWidth = 1,
                children = {
                    UI.Panel { width = "100%", paddingRight = 36, gap = 4, children = { self.title, self.name } },
                    self.subtitle, self.collapseButton,
                },
            },
            Section({
                Label("种子", 10.5, C.dim, { letterSpacing = 0.5 }),
                Row({
                    self.seedField, self.randomSeedTooltip,
                    UI.Button { text = "生成场景", width = 92, height = 31, fontSize = 12, fontWeight = "bold",
                        backgroundColor = C.accent, borderColor = C.accent, borderWidth = 1, borderRadius = 8,
                        textColor = { 19, 11, 5, 255 }, onClick = function() callbacks.onGenerate(self.seed) end },
                }, { gap = 5 }),
            }),
            Section({
                Row({ Label("题材", 10.5, C.dim, { flexGrow = 1, letterSpacing = 0.5 }),
                    self.customSettingButton, self.customSettingToggleTooltip }),
                Row({ self.settingButtons.dungeon, self.settingButtons.hospital, self.settingButtons.school,
                    self.fixedSettingModeButton, self.randomSettingTooltip }, { gap = 1 }),
                self.customSettingHint, self.customSettingList,
            }),
            Section({
                Row({ Label("色调", 10.5, C.dim, { flexGrow = 1, letterSpacing = 0.5 }),
                    self.paletteCustomButton, self.paletteToggleTooltip }),
                Row({ Label("当前颜色", 9, C.dim, { width = 54 }), self.currentPaletteButton,
                    self.randomThemeTooltip },
                    { alignItems = "center", gap = 6 }),
                self.paletteExpandedList,
            }),
            Section({
                Row({ Label("房间", 10.5, C.dim, { flexGrow = 1, letterSpacing = 0.5 }),
                    self.roomGroupAddButton, self.roomGroupToggleTooltip }),
                self.roomGroupHint,
                self.roomGroupList,
            }),
            Section({
                Row({ UI.Panel { flexGrow = 1, gap = 2, children = { Label("楼层管理", 12, C.text, { fontWeight = "bold" }), Label("生成与编辑共用", 9, C.dim) } }, self.floorSummary }, { alignItems = "center" }),
                Row({ Label("当前编辑层", 10, C.text, { fontWeight = "bold", flexGrow = 1 }),
                    Label("逐层参数与二维编辑目标", 9, C.dim) }),
                self.floorDropdown,
                FloorSetting("本层区域数量", self.roomValue, self.roomSlider),
                FloorSetting("本层回环率", self.loopValue, self.loopSlider),
                FloorSetting("本层装饰密度", self.decorValue, self.decorSlider),
                Label("调整层数  ·  最多 6 层", 9, C.dim),
                Row({
                    SmallButton("＋ 下一层", function() callbacks.onAddFloorAfter() end, { flexGrow = 1, fontSize = 9.5, textColor = { 182, 217, 207, 255 } }),
                    SmallButton("＋ 顶层", function() callbacks.onAddFloorTop() end, { flexGrow = 1, fontSize = 9.5, textColor = { 182, 217, 207, 255 } }),
                    SmallButton("删当前", function() callbacks.onRemoveFloor() end, { flexGrow = 1, variant = "danger", fontSize = 10 }),
                }),
                Label("三维显示范围", 10, C.dim),
                Row({ self.viewButtons.current, self.viewButtons.neighbors, self.viewButtons.all, self.viewButtons.explode }),
            }),
            Section({ self.stats }),
        }
    }

    self.panelShell = UI.Panel {
        position = "absolute", left = 12, top = 12, bottom = 12, width = 286,
        backgroundColor = C.panel, borderColor = C.line, borderWidth = 1, borderRadius = 14,
        backdropBlur = 14, boxShadow = { { x = 0, y = 16, blur = 46, spread = 0, color = { 0, 0, 0, 187 } } },
        children = { UI.ScrollView { width = "100%", height = "100%", scrollY = true, showScrollbar = true, children = { content } } },
    }
    self.expandButton = SmallButton("展开", function() self:SetCollapsed(false) end,
        { position = "absolute", left = 12, top = 12, width = 52, height = 38 })
    self.expandButton:SetVisible(false)

    self.customContextMenuLayer = UI.Panel {
        position = "absolute", left = 0, right = 0, top = 0, bottom = 0,
        zIndex = 4200, backgroundColor = { 0, 0, 0, 0 }, pointerEvents = "auto",
        onPointerDown = function() self:CloseCustomSettingContextMenu() end,
    }
    self.customContextMenuLayer:SetVisible(false)

    self.root = UI.Panel {
        width = "100%", height = "100%", pointerEvents = "box-none",
        children = {
            self.panelShell, self.roomAssignmentPanel, self.expandButton, self.hints, self.previewBarAnchor,
            UI.Panel { position = "absolute", right = 18, bottom = 18, children = { self.editorButtons } },
            self.previewHud, self.customSettingModal, self.customRenameModal, self.paletteModal, self.roomGroupModal,
            self.imageHistoryModal, self.customContextMenuLayer,
        }
    }
    UI.SetRoot(self.root)
    self:SetState(initial)
    return self
end

function ControlPanel:SetReferenceImage(kind, path, name)
    if kind == "custom" then
        self.customImagePath, self.customImageFileName = path, name
        self.customImagePreview:SetVisible(path ~= nil)
        self.customImageInputRow:SetVisible(path == nil)
        self.customImageName:SetText(name or "")
        self.customImageThumb:SetBackgroundImage(path)
        if not self.updatingCustomForm and self.customGenerateButton then self:RefreshCustomSettingPlan() end
    else
        self.roomGroupImagePath, self.roomGroupImageFileName = path, name
        self.roomGroupImageName:SetText(name or "未选择文件")
        self.roomGroupImageName:SetFontColor(path and C.text or C.dim)
        self.roomGroupImageThumb:SetBackgroundImage(path)
        self.roomGroupImageThumb:SetVisible(path ~= nil)
        self.roomGroupImageRemoveButton:SetVisible(path ~= nil)
        self.roomGroupImageInputBox:SetVisible(path == nil)
        self.roomGroupImageRow:SetVisible(path ~= nil)
    end
end

function ControlPanel:OpenImageHistory(kind)
    self.imageHistoryKind = kind
    self.imageHistoryList:ClearChildren()
    local entries, seen = {}, {}
    local state = self.currentState or {}
    for _, list in ipairs({ state.customSettings or {}, state.roomGroups or {} }) do
        for _, item in ipairs(list) do
            if item.imagePath and not seen[item.imagePath] and fileSystem:FileExists(item.imagePath) then
                seen[item.imagePath] = true
                entries[#entries + 1] = {
                    path = item.imagePath,
                    name = item.imageName or item.label or item.name or "参考图",
                }
            end
        end
    end
    if #entries == 0 then
        self.imageHistoryList:AddChild(UI.Panel {
            width = "100%", padding = 18, alignItems = "center",
            backgroundColor = { 23, 27, 38, 255 }, borderColor = C.line, borderWidth = 1, borderRadius = 8,
            children = {
                Label("暂无历史参考图", 12, C.text, { fontWeight = "bold" }),
                Label("保存过带图片的题材或房间组后，会显示在这里。", 9, C.dim, {
                    textAlign = "center", whiteSpace = "normal",
                }),
            },
        })
    else
        for _, entry in ipairs(entries) do
            local saved = entry
            self.imageHistoryList:AddChild(UI.Panel {
                width = "100%", height = 62, padding = 7, flexDirection = "row", alignItems = "center", gap = 9,
                backgroundColor = { 23, 27, 38, 255 }, borderColor = C.line, borderWidth = 1, borderRadius = 8,
                children = {
                    UI.Panel {
                        width = 70, height = 46, backgroundImage = saved.path, backgroundFit = "cover",
                        backgroundColor = { 34, 36, 42, 255 }, borderRadius = 5, overflow = "hidden",
                    },
                    Label(saved.name, 10.5, C.text, { flexGrow = 1, whiteSpace = "normal" }),
                    SmallButton("使用", function()
                        if self:ApplyReferenceImagePath(self.imageHistoryKind, saved.path) then
                            self.imageHistoryModal:Close()
                        end
                    end, { width = 58, height = 30, textColor = C.teal }),
                },
            })
        end
    end
    self.imageHistoryModal:Open()
end

local function CleanPastedImagePath(value)
    local text = Trim(value)
    text = string.match(text, "[^\r\n]+") or ""
    if #text >= 2 then
        local first, last = string.sub(text, 1, 1), string.sub(text, -1)
        if (first == '"' and last == '"') or (first == "'" and last == "'") then
            text = string.sub(text, 2, -2)
        end
    end
    if string.lower(string.sub(text, 1, 8)) == "file:///" then
        text = string.sub(text, 9)
    elseif string.lower(string.sub(text, 1, 7)) == "file://" then
        text = string.sub(text, 8)
    end
    text = text:gsub("%%20", " ")
    return Trim(text)
end

function ControlPanel:ApplyReferenceImagePath(kind, path)
    local errorLabel = kind == "custom" and self.customSettingError or self.roomGroupError
    path = CleanPastedImagePath(path)
    if path == "" then
        errorLabel:SetText("剪贴板中没有图片路径。请先对图片文件使用“复制为路径”。")
        return false
    end
    local lower = string.lower(path)
    if string.match(lower, "^https?://") or string.match(lower, "^data:image/") then
        errorLabel:SetText("辅助粘贴当前支持本地图片路径；网络图片请先保存到本地。")
        return false
    end
    local file = File(path, FILE_READ)
    if not file or not file:IsOpen() then
        errorLabel:SetText("无法读取粘贴的图片路径，请确认文件仍然存在。")
        return false
    end
    local size = file:GetSize()
    file:Dispose()
    if size <= 0 or size > 20 * 1024 * 1024 then
        errorLabel:SetText("图片为空或超过 Maker 的 20 MB 上限。")
        return false
    end
    errorLabel:SetText("")
    self:SetReferenceImage(kind, path, GetFileNameAndExtension(path, false))
    self.referenceImagePasteKind = nil
    print(string.format("[ControlPanel] reference image accepted kind=%s source=path", kind))
    return true
end

function ControlPanel:ActivateReferenceImagePaste(kind)
    ui.useSystemClipboard = true
    self.referenceImagePasteKind = kind
    local errorLabel = kind == "custom" and self.customSettingError or self.roomGroupError
    errorLabel:SetText("")
    print(string.format("[ControlPanel] reference image paste target active kind=%s", kind))
end

function ControlPanel:HandleReferenceImagePasteKey(eventData)
    if eventData:GetBool("Repeat") then return false end
    if eventData:GetInt("Key") ~= KEY_V or (eventData:GetInt("Qualifiers") & QUAL_CTRL) == 0 then return false end
    if self.imageHistoryModal and self.imageHistoryModal:IsOpen() then return false end
    local openKind = self.customSettingModal:IsOpen() and "custom"
        or self.roomGroupModal:IsOpen() and "room" or nil
    local kind = self.referenceImagePasteKind
    if not kind or kind ~= openKind then return false end
    ui.useSystemClipboard = true
    local text = ui:GetClipboardText()
    if not text or Trim(text) == "" then
        local errorLabel = kind == "custom" and self.customSettingError or self.roomGroupError
        errorLabel:SetText("当前运行时不能读取剪贴板位图。请复制图片文件路径后按 Ctrl+V，或直接拖入图片文件。")
        return false
    end
    local candidate = CleanPastedImagePath(text)
    if not fileSystem:FileExists(candidate) then
        local errorLabel = kind == "custom" and self.customSettingError or self.roomGroupError
        errorLabel:SetText("剪贴板内容不是可读取的本地图片路径。请使用“复制为路径”后重试。")
        return false
    end
    return self:ApplyReferenceImagePath(kind, text)
end

function ControlPanel:HandleReferenceImageDropped(eventData)
    if self.imageHistoryModal and self.imageHistoryModal:IsOpen() then return false end
    local kind = self.customSettingModal:IsOpen() and "custom"
        or self.roomGroupModal:IsOpen() and "room" or nil
    if not kind then return false end
    local path = eventData:GetString("FileName")
    local accepted = self:ApplyReferenceImagePath(kind, path)
    if accepted then print("[ControlPanel] reference image accepted source=drop") end
    return accepted
end

function ControlPanel:FindCustomPalette(id)
    for _, item in ipairs((self.currentState or {}).customPalettes or {}) do
        if item.id == id then return item end
    end
end

function ControlPanel:CopyPaletteAIPrompt()
    local description = Trim(self.palettePromptField:GetValue())
    local label = Trim(self.paletteNameField:GetValue())
    local template = self.paletteDataField:GetValue()
    if Trim(template) == "" then
        self:FillPaletteTemplate()
        template = self.paletteDataField:GetValue()
    end
    local prompt = table.concat({
        "请为程序化 3D 场景生成一组模型材质配色。",
        "配色名称：" .. (label ~= "" and label or "未命名配色"),
        "视觉描述：" .. (description ~= "" and description or "在参考配色基础上形成清晰、克制的 PBR 色彩层级"),
        "只输出一个 JSON 对象，不要 Markdown、解释或额外字段。每个值必须是 #RRGGBB。",
        "必须保留字段：floor, corridor, wall, pillar, accentObject, cloth, flame, flameCore。",
        "保证 floor/corridor/wall/pillar 彼此可辨但属于同一材质家族；accentObject 和 flame 提供视觉焦点。",
        "参考数据：",
        template,
    }, "\n")
    ui.useSystemClipboard = true
    ui:SetClipboardText(prompt)
    self:SetStatus("AI 配色生成指令已复制；把 AI 返回的 JSON 粘贴到数据框即可保存")
    print("[ControlPanel] AI palette prompt copied")
end

function ControlPanel:FillPaletteTemplate(themeKey)
    local key = themeKey or self.paletteTemplateThemeKey
        or ((self.currentState or {}).themeKey) or "ancient"
    local encoded, reason = PaletteData.EncodeAIData(Themes.Get(key))
    if encoded == "" then
        self.paletteError:SetText(reason or "无法生成当前配色模板。")
        return false
    end
    self.paletteDataField:SetValue(encoded)
    self.paletteError:SetText("")
    return true
end

function ControlPanel:OpenCustomPaletteModal(item)
    self.editingPaletteId = item and item.id or nil
    self.paletteModalTitle:SetText(item and "编辑自定义配色" or "添加自定义配色")
    self.paletteNameField:SetValue(item and item.label or "")
    self.palettePromptField:SetValue(item and item.prompt or "")
    local state = self.currentState or {}
    local settingKey = item and item.baseSettingKey or state.settingKey or "dungeon"
    self.paletteBaseSettingDropdown:SetValue(settingKey)

    local baseKey = item and item.basePaletteKey or state.themeKey
    if not baseKey or Themes.IsCustom(baseKey) or not Themes.IsPaletteForSetting(baseKey, settingKey) then
        baseKey = Themes.GetBuiltinPalettes(settingKey)[1]
    end
    self.paletteBasePaletteKey = baseKey
    self.paletteTemplateThemeKey = item and item.id or state.themeKey or baseKey
    if item then
        local encoded = PaletteData.EncodeAIData(item.colors)
        self.paletteDataField:SetValue(encoded)
    else
        self:FillPaletteTemplate(self.paletteTemplateThemeKey)
    end
    self.paletteDeleteButton:SetVisible(item ~= nil)
    self.paletteError:SetText("")
    print("[ControlPanel] open custom palette modal mode=" .. (item and "edit" or "new"))
    self.paletteModal:Open()
end

function ControlPanel:ApplyCustomPalette()
    local label = Trim(self.paletteNameField:GetValue())
    if label == "" then self.paletteError:SetText("请先填写配色名称。"); return end
    for _, item in ipairs((self.currentState or {}).customPalettes or {}) do
        if item.id ~= self.editingPaletteId and string.lower(Trim(item.label)) == string.lower(label) then
            self.paletteError:SetText("已经存在同名配色，请换一个名称。")
            return
        end
    end
    local colors, reason = PaletteData.DecodeAIData(self.paletteDataField:GetValue())
    if not colors then self.paletteError:SetText(reason or "AI 配色数据无效。"); return end
    local settingKey = self.paletteBaseSettingDropdown:GetValue() or "dungeon"
    local baseKey = self.paletteBasePaletteKey
    if not baseKey or not Themes.IsPaletteForSetting(baseKey, settingKey) or Themes.IsCustom(baseKey) then
        baseKey = Themes.GetBuiltinPalettes(settingKey)[1]
    end
    local ok, saveReason = self.callbacks.onCustomPaletteSave({
        schemaVersion = PaletteData.SCHEMA_VERSION,
        id = self.editingPaletteId,
        label = label,
        prompt = Trim(self.palettePromptField:GetValue()),
        baseSettingKey = settingKey,
        basePaletteKey = baseKey,
        colors = colors,
    })
    if ok == false then self.paletteError:SetText(saveReason or "自定义配色保存失败。"); return end
    print("[ControlPanel] custom palette saved label=" .. label)
    self.paletteModal:Close()
end

function ControlPanel:ConfirmDeleteCustomPalette()
    local item = self:FindCustomPalette(self.editingPaletteId)
    if not item then return end
    UI.Modal.Confirm {
        title = "删除自定义配色", message = string.format("确定删除配色“%s”吗？", item.label),
        confirmText = "删除", cancelText = "取消",
        onConfirm = function()
            local ok, reason = self.callbacks.onCustomPaletteDelete(item.id)
            if ok == false then self.paletteError:SetText(reason or "自定义配色删除失败。"); return end
            self.paletteModal:Close()
        end,
    }
end

function ControlPanel:FindCustomSetting(id)
    for _, item in ipairs((self.currentState or {}).customSettings or {}) do
        if item.id == id then return item end
    end
end

function ControlPanel:SetCustomAdvancedExpanded(expanded)
    self.customAdvancedExpanded = expanded == true
    self.customAdvancedPanel:SetVisible(self.customAdvancedExpanded)
    self.customAdvancedButton:SetText(self.customAdvancedExpanded and "− 高级设置" or "+ 高级设置")
end

function ControlPanel:RefreshCustomFloorHeightHint()
    local value = tonumber(Trim(self.customFloorHeightField:GetValue()))
    if not value then
        self.customFloorHeightHint:SetText("请输入有效的米制层高，例如 5.00。")
        self.customFloorHeightHint:SetFontColor(C.danger)
        return false
    end
    local valid = value >= MultiFloor.MIN_FLOOR_HEIGHT and value <= MultiFloor.MAX_FLOOR_HEIGHT
    self.customFloorHeightHint:SetText(string.format("美术基准 %.2f 米 · 运行比例 %.2f",
        MultiFloor.SOURCE_FLOOR_HEIGHT, value / MultiFloor.SOURCE_FLOOR_HEIGHT))
    self.customFloorHeightHint:SetFontColor(valid and C.dim or C.danger)
    return valid
end

function ControlPanel:ValidateCustomSetting(requireContent)
    local payload = {
        id = self.editingCustomId,
        label = Trim(self.customNameField:GetValue()),
        prompt = Trim(self.customPromptField:GetValue()),
        baseSettingKey = self.customBaseSettingDropdown:GetValue() or "dungeon",
        floorHeight = tonumber(Trim(self.customFloorHeightField:GetValue())),
        imagePath = self.customImagePath,
        imageName = self.customImageFileName,
    }
    if payload.label == "" then
        self.customSettingError:SetText("请先填写题材名称。")
        return nil
    end
    if not payload.floorHeight or payload.floorHeight < MultiFloor.MIN_FLOOR_HEIGHT
        or payload.floorHeight > MultiFloor.MAX_FLOOR_HEIGHT then
        self.customSettingError:SetText(string.format("层高请输入 %.1f 到 %.1f 米之间的数值。",
            MultiFloor.MIN_FLOOR_HEIGHT, MultiFloor.MAX_FLOOR_HEIGHT))
        return nil
    end
    for _, item in ipairs((self.currentState or {}).customSettings or {}) do
        if item.id ~= self.editingCustomId
            and string.lower(Trim(item.label)) == string.lower(payload.label) then
            self.customSettingError:SetText("已经存在同名题材，请换一个名称。")
            return nil
        end
    end
    if requireContent and payload.prompt == "" and not payload.imagePath then
        self.customSettingError:SetText("进入生成方案前，请填写题材描述或添加参考图。")
        return nil
    end
    self.customSettingError:SetText("")
    return payload
end

function ControlPanel:UpdateCustomSettingPlan(payload)
    local resolvedKey, pack = ThemePacks.ResolvePrompt(payload.prompt, payload.label, nil)
    local source = "题材描述"
    if not pack then
        resolvedKey = payload.baseSettingKey
        pack = ThemePacks.Get(resolvedKey)
        source = "参考生成体系"
    end
    self.customResolvedPackKey = pack and resolvedKey or nil
    if not pack then
        local contract = GenericThemeRules.Resolve(payload.baseSettingKey)
        self.customPlanMode = GenericThemeRules.GENERATION_MODE
        self.customPlanStatus:SetText("可生成预览 · 使用通用规则")
        self.customPlanStatus:SetStyle({ fontColor = C.teal })
        self.customPlanDescription:SetText(
            string.format("未匹配专用题材包，本次将继承“%s”的结构、素材、摆放与材质规则，以 %.2f 米层高生成基础预览；AI 3D 资产接口仍待接入。",
                contract.baseSettingLabel, payload.floorHeight))
        self.customPlanStructure:SetText(string.format("层高 %.2f 米 / 纵向比例 %.2f · %s",
            payload.floorHeight, payload.floorHeight / MultiFloor.SOURCE_FLOOR_HEIGHT,
            table.concat(contract.structureRules, " / ")))
        self.customPlanRooms:SetText("房间定义可选；未定义时执行题材通用区域逻辑")
        self.customPlanProps:SetText("使用已安装通用素材 · 避开门口和主通道 · 保持可通行")
        self.customPlanMaterials:SetText("使用已安装 PBR 材质规则（不会虚构 AI 模型）")
        self.customGenerateButton:SetDisabled(payload.label == "")
        return true
    end

    self.customPlanMode = "theme-pack"
    local materialRoles = {}
    for _, prop in pairs(pack.props or {}) do
        if prop.material then materialRoles[prop.material] = true end
    end
    for key, value in pairs(pack.structure or {}) do
        if key:find("Material", 1, true) and type(value) == "string" then materialRoles[value] = true end
    end
    self.customPlanStatus:SetText(string.format("可生成 · 已匹配“%s”题材包", pack.label or resolvedKey))
    self.customPlanStatus:SetStyle({ fontColor = C.teal })
    local vertical = pack.verticalProfile or {}
    self.customPlanDescription:SetText(string.format(
        "通过%s匹配；按 %.2f 米层高生成，并校验 %.2f 米美术基准、结构高度、安装高度、几何、材质和道具引用。",
        source, payload.floorHeight, vertical.authoredFloorHeight or 0))
    self.customPlanStructure:SetText(string.format("层高 %.2f 米 / 比例 %.2f · %d 项结构声明",
        payload.floorHeight, payload.floorHeight / MultiFloor.SOURCE_FLOOR_HEIGHT,
        CountKeys(pack.structure)))
    self.customPlanRooms:SetText(JoinRuleLabels(pack.roomRules))
    self.customPlanProps:SetText(string.format("%d 类题材道具及墙面装饰", CountKeys(pack.props)))
    self.customPlanMaterials:SetText(string.format("%d 类独立 PBR 材质角色", CountKeys(materialRoles)))
    self.customGenerateButton:SetDisabled(payload.label == "")
    return true
end

function ControlPanel:RefreshCustomSettingPlan()
    if not self.customGenerateButton then return false end
    local payload = {
        label = Trim(self.customNameField:GetValue()),
        prompt = Trim(self.customPromptField:GetValue()),
        baseSettingKey = self.customBaseSettingDropdown:GetValue() or "dungeon",
        floorHeight = MultiFloor.NormalizeFloorHeight(tonumber(Trim(self.customFloorHeightField:GetValue()))),
        imagePath = self.customImagePath,
        imageName = self.customImageFileName,
    }
    if payload.prompt == "" and not payload.imagePath then
        self.customResolvedPackKey = nil
        self.customPlanMode = nil
        self.customPlanStatus:SetText("等待题材描述")
        self.customPlanStatus:SetStyle({ fontColor = C.accent })
        self.customPlanDescription:SetText("填写提示词或粘贴参考图后，将在本页直接显示题材生成方案。")
        self.customPlanStructure:SetText("通用程序化结构已就绪")
        self.customPlanRooms:SetText("房间定义可选")
        self.customPlanProps:SetText("等待生成题材通用素材")
        self.customPlanMaterials:SetText("等待生成题材 PBR 材质")
        self.customGenerateButton:SetDisabled(true)
        return false
    end
    return self:UpdateCustomSettingPlan(payload)
end

function ControlPanel:OpenCustomSettingModal(item)
    self:CloseCustomSettingContextMenu()
    self.referenceImagePasteKind = nil
    self.editingCustomId = item and item.id or nil
    self.customModalTitle:SetText(item and (item.packStatus == "draft" and "继续编辑草稿" or "编辑题材包") or "新建题材包")
    self.updatingCustomForm = true
    self.customNameField:SetValue(item and item.label or "")
    self.customBaseSettingDropdown:SetValue(item and item.baseSettingKey or (self.currentState and self.currentState.settingKey) or "dungeon")
    self.customFloorHeightField:SetValue(string.format("%.2f", item and item.floorHeight
        or (self.currentState and self.currentState.floorHeight) or MultiFloor.FLOOR_HEIGHT))
    self.customPromptField:SetValue(item and item.prompt or "")
    self:SetReferenceImage("custom", item and item.imagePath or nil, item and item.imageName or nil)
    self.updatingCustomForm = false
    self:RefreshCustomFloorHeightHint()
    self:SetCustomAdvancedExpanded(false)
    self.customSettingError:SetText("")
    self:RefreshCustomSettingPlan()
    print("[ControlPanel] open custom setting modal mode=" .. (item and "edit" or "new"))
    self.customSettingModal:Open()
end

function ControlPanel:ApplyCustomSetting(mode)
    mode = mode == "draft" and "draft" or "generate"
    local payload = self:ValidateCustomSetting(mode == "generate")
    if not payload then return end
    if mode == "generate" and not self:UpdateCustomSettingPlan(payload) then return end
    self.customDraftButton:SetDisabled(true)
    self.customGenerateButton:SetDisabled(true)
    local ok, reason = self.callbacks.onCustomSettingSave(payload, mode)
    self.customDraftButton:SetDisabled(false)
    self.customGenerateButton:SetDisabled(self.customPlanMode == nil or payload.label == "")
    if ok == false then self.customSettingError:SetText(reason or "题材保存失败，请重试。"); return end
    print(string.format("[ControlPanel] custom setting %s label=%s", mode, payload.label))
    self.customSettingModal:Close()
end

function ControlPanel:OpenCustomSettingRename(item)
    self:CloseCustomSettingContextMenu()
    if not item then return end
    self.renamingCustomId = item.id
    self.customRenameField:SetValue(item.label or "")
    self.customRenameError:SetText("")
    self.customRenameModal:Open()
end

function ControlPanel:ApplyCustomSettingRename()
    local item = self:FindCustomSetting(self.renamingCustomId)
    local label = Trim(self.customRenameField:GetValue())
    if not item then self.customRenameError:SetText("题材不存在或已被删除。"); return end
    if label == "" then self.customRenameError:SetText("请填写题材名称。"); return end
    for _, existing in ipairs((self.currentState or {}).customSettings or {}) do
        if existing.id ~= item.id and string.lower(Trim(existing.label)) == string.lower(label) then
            self.customRenameError:SetText("已经存在同名题材，请换一个名称。")
            return
        end
    end
    local ok, reason = self.callbacks.onCustomSettingRename(item.id, label)
    if ok == false then self.customRenameError:SetText(reason or "重命名失败。"); return end
    self.customRenameModal:Close()
end

function ControlPanel:CloseCustomSettingContextMenu()
    if not self.customContextMenuLayer then return end
    self.customContextMenuLayer:ClearChildren()
    self.customContextMenuLayer:SetVisible(false)
    self.contextCustomId = nil
end

function ControlPanel:OpenCustomSettingContextMenu(item, event)
    if not item or not self.customContextMenuLayer then return end
    self:CloseCustomSettingContextMenu()
    self.contextCustomId = item.id
    local rootLayout = self.root:GetAbsoluteLayout()
    local menuWidth, menuHeight = 150, 108
    local x = (event and event.x or rootLayout.x + 20) - rootLayout.x
    local y = (event and event.y or rootLayout.y + 20) - rootLayout.y
    x = math.max(8, math.min(x, rootLayout.w - menuWidth - 8))
    y = math.max(8, math.min(y, rootLayout.h - menuHeight - 8))

    local function menuButton(text, action, danger)
        return SmallButton(text, function()
            self:CloseCustomSettingContextMenu()
            action()
        end, {
            width = "100%", height = 30, fontSize = 10.5, borderWidth = 0, borderRadius = 4,
            backgroundColor = { 0, 0, 0, 0 }, textColor = danger and C.danger or C.text,
        })
    end
    local menu = UI.Panel {
        position = "absolute", left = x, top = y, width = menuWidth, padding = 5, gap = 2,
        backgroundColor = { 24, 28, 39, 250 }, borderColor = { 64, 71, 91, 255 },
        borderWidth = 1, borderRadius = 8, boxShadow = {
            { x = 0, y = 10, blur = 28, spread = 0, color = { 0, 0, 0, 190 } },
        },
        onPointerDown = function(pointerEvent) pointerEvent:StopPropagation() end,
        children = {
            menuButton(item.packStatus == "draft" and "继续编辑" or "编辑题材", function()
                self:OpenCustomSettingModal(item)
            end),
            menuButton("重命名", function() self:OpenCustomSettingRename(item) end),
            UI.Panel { width = "100%", height = 1, backgroundColor = C.line },
            menuButton("删除题材", function() self:ConfirmDeleteCustomSetting(item) end, true),
        },
    }
    self.customContextMenuLayer:AddChild(menu)
    self.customContextMenuLayer:SetVisible(true)
end

function ControlPanel:ConfirmDeleteCustomSetting(target)
    local item = target or self:FindCustomSetting(self.editingCustomId)
    if not item then return end
    self:CloseCustomSettingContextMenu()
    UI.Modal.Confirm {
        title = "删除题材", message = string.format("确定删除题材“%s”吗？", item.label),
        confirmText = "删除", cancelText = "取消",
        onConfirm = function()
            local ok, reason = self.callbacks.onCustomSettingDelete(item.id)
            if ok == false then self:SetStatus(reason or "题材删除失败"); return end
            if self.customSettingModal:IsOpen() then self.customSettingModal:Close() end
        end,
    }
end

function ControlPanel:FindRoomGroup(id)
    for _, item in ipairs((self.currentState or {}).roomGroups or {}) do
        if item.id == id then return item end
    end
end

function ControlPanel:OpenRoomGroupModal(item)
    self.referenceImagePasteKind = nil
    self.editingRoomGroupId = item and item.id or nil
    self.roomGroupModalTitle:SetText(item and "编辑房间组" or "添加房间组")
    self.roomGroupNameField:SetValue(item and item.name or "")
    self.roomGroupPromptField:SetValue(item and item.prompt or "")
    local color = RoomGroupColors.Parse(item and item.color,
        RoomGroupColors.Default(item, 1))
    self.roomGroupColorHex = RoomGroupColors.ToHex(color)
    self.roomGroupColorPicker:SetHex(self.roomGroupColorHex)
    self:SetReferenceImage("room", item and item.imagePath or nil, item and item.imageName or nil)
    self.roomGroupDeleteButton:SetVisible(item ~= nil)
    self.roomGroupError:SetText("")
    print("[ControlPanel] open room group modal mode=" .. (item and "edit" or "new"))
    self.roomGroupModal:Open()
end

function ControlPanel:ApplyRoomGroup()
    local name = Trim(self.roomGroupNameField:GetValue())
    local prompt = Trim(self.roomGroupPromptField:GetValue())
    local editing = self:FindRoomGroup(self.editingRoomGroupId)
    local topicId = editing and editing.topicId or (self.currentState or {}).activeCustomSettingId
    if name == "" then
        self.roomGroupError:SetText("请填写房间组名称。")
        return
    end
    if prompt == "" and not self.roomGroupImagePath then
        self.roomGroupError:SetText("请至少填写提示词或添加一张参考图。")
        return
    end
    for _, item in ipairs((self.currentState or {}).roomGroups or {}) do
        if item.id ~= self.editingRoomGroupId and item.topicId == topicId
            and string.lower(Trim(item.name)) == string.lower(name) then
            self.roomGroupError:SetText("已有同名房间组，请换一个名称。")
            return
        end
    end
    local ok, reason = self.callbacks.onRoomGroupSave({
        id = self.editingRoomGroupId, name = name, prompt = prompt,
        imagePath = self.roomGroupImagePath, imageName = self.roomGroupImageFileName,
        color = RoomGroupColors.Parse(self.roomGroupColorHex),
    })
    if ok == false then self.roomGroupError:SetText(reason or "房间组保存失败，请重试。"); return end
    print("[ControlPanel] room group saved name=" .. name)
    self.roomGroupModal:Close()
end

function ControlPanel:ConfirmDeleteRoomGroup()
    local item = self:FindRoomGroup(self.editingRoomGroupId)
    if not item then return end
    UI.Modal.Confirm {
        title = "删除房间组", message = string.format("确定删除房间组“%s”吗？", item.name),
        confirmText = "删除", cancelText = "取消",
        onConfirm = function()
            local ok, reason = self.callbacks.onRoomGroupDelete(item.id)
            if ok == false then self.roomGroupError:SetText(reason or "房间组删除失败。"); return end
            self.roomGroupModal:Close()
        end,
    }
end

function ControlPanel:RebuildCustomSettingList(items)
    self:CloseCustomSettingContextMenu()
    self.customSettingList:ClearChildren()
    self.customSettingHint:SetVisible(self.customSettingExpanded and #(items or {}) > 0)
    for _, item in ipairs(items or {}) do
        local saved = item
        local active = (self.currentState or {}).topicMode == "custom"
            and (self.currentState or {}).activeCustomSettingId == saved.id
        local isDraft = saved.packStatus == "draft"
        local visual = UI.Panel {
            width = 38, height = 38, backgroundColor = { 44, 34, 27, 255 },
            backgroundImage = saved.imagePath, backgroundFit = "cover", overflow = "hidden",
            borderColor = active and C.accent or { 94, 67, 42, 255 }, borderWidth = active and 2 or 1, borderRadius = 7,
            children = saved.imagePath and {} or {
                Label(FirstCharacter(saved.label), 12, C.accent, {
                    width = "100%", height = "100%", textAlign = "center", verticalAlign = "middle",
                }),
            },
        }
        local card = UI.Panel {
            width = "100%", height = 54, padding = 7, flexDirection = "row", alignItems = "center", gap = 8,
            backgroundColor = active and { 34, 31, 31, 255 } or C.section,
            borderColor = active and { 139, 91, 52, 255 } or { 41, 47, 64, 255 }, borderWidth = 1, borderRadius = 8,
            pointerEvents = "box-only",
            onPointerDown = function(event)
                if event.button == MOUSEB_RIGHT then
                    event:StopPropagation()
                    event:PreventDefault()
                    self:OpenCustomSettingContextMenu(saved, event)
                end
            end,
            onClick = function(_, event)
                if event and event.button == MOUSEB_RIGHT then return end
                self:CloseCustomSettingContextMenu()
                if isDraft then self:OpenCustomSettingModal(saved); return end
                local ok, reason = self.callbacks.onCustomSettingSelect(saved.id)
                if ok == false then self:SetStatus(reason or "题材切换失败") end
            end,
            children = {
                visual,
                UI.Panel { flexGrow = 1, gap = 3, children = {
                    Label(saved.label, 11, { 232, 235, 242, 255 }, { fontWeight = "bold" }),
                    Label(isDraft and "草稿 · 单击继续编辑" or "已生成 · 单击切换", 8.5,
                        isDraft and { 199, 158, 103, 255 } or { 122, 185, 171, 255 }),
                } },
            },
        }
        self.customSettingList:AddChild(card)
    end
end

function ControlPanel:RebuildRoomGroupList(items)
    self.roomGroupList:ClearChildren()
    local currentState = self.currentState or {}
    local activeTopicId = currentState.topicMode == "custom" and currentState.activeCustomSettingId or nil
    for _, item in ipairs(items or {}) do
        if (activeTopicId and item.topicId == activeTopicId) or (not activeTopicId and not item.topicId) then
            local saved = item
            self.roomGroupList:AddChild(UI.Panel {
                width = "100%", height = 44, padding = 5, flexDirection = "row", alignItems = "center", gap = 6,
                backgroundColor = C.section, borderColor = { 41, 47, 64, 255 }, borderWidth = 1, borderRadius = 8,
                children = {
                    UI.Panel {
                        width = 16, height = 16, flexShrink = 0,
                        backgroundColor = RoomGroupColors.ToRGBA(saved.color),
                        borderColor = { 255, 255, 255, 64 }, borderWidth = 1, borderRadius = 4,
                    },
                    UI.Panel { flexGrow = 1, gap = 2, children = {
                        Label(saved.name, 10, C.text, {
                            fontWeight = "bold", whiteSpace = "nowrap", overflow = "hidden",
                        }),
                        Label("可分配到房间", 8.5, C.dim),
                    } },
                    SmallButton("编辑", function() self:OpenRoomGroupModal(saved) end,
                        { width = 38, height = 24, fontSize = 8.5 }),
                },
            })
        end
    end
end

function ControlPanel:SetPaletteExpanded(expanded)
    self.paletteExpanded = expanded == true
    self.paletteExpandedList:SetVisible(self.paletteExpanded)
    self.paletteToggleButton:SetExpanded(self.paletteExpanded)
    self.paletteToggleTooltip:SetContent(self.paletteExpanded and "收起色调" or "展开色调")
end

function ControlPanel:RebuildPaletteExpandedList(state)
    self.paletteExpandedList:ClearChildren()
    for _, key in ipairs(Themes.GetSetting(state.settingKey).palettes) do
        local paletteKey = key
        local theme = Themes.Get(paletteKey)
        local custom = self:FindCustomPalette(paletteKey)
        local active = state.themeKey == paletteKey
        local swatches = Row({
            PaletteSwatch(theme.floor), PaletteSwatch(theme.wall), PaletteSwatch(theme.pillar),
            PaletteSwatch(theme.accentObject), PaletteSwatch(theme.flame),
        }, { width = 90, gap = 3, alignItems = "center" })
        local topChildren = {
            Label(theme.label, 10.5, active and { 255, 215, 168, 255 } or C.text,
                { flexGrow = 1, fontWeight = "bold", whiteSpace = "nowrap", overflow = "hidden" }),
            SmallButton(active and "使用中" or "使用", function()
                local ok, reason = self.callbacks.onTheme(paletteKey)
                if ok == false then self:SetStatus(reason or "配色切换失败") end
            end, { width = 46, height = 26, fontSize = 8.5,
                backgroundColor = active and { 63, 45, 31, 255 } or C.input }),
        }
        if custom then
            topChildren[#topChildren + 1] = SmallButton("编辑", function() self:OpenCustomPaletteModal(custom) end,
                { width = 38, height = 26, fontSize = 8.5 })
        end
        self.paletteExpandedList:AddChild(UI.Panel {
            width = "100%", height = 64, padding = { 6, 7 }, gap = 4,
            backgroundColor = active and { 34, 31, 31, 255 } or C.section,
            borderColor = active and { 139, 91, 52, 255 } or { 41, 47, 64, 255 },
            borderWidth = 1, borderRadius = 8, children = {
                Row(topChildren, { height = 27, alignItems = "center", gap = 6 }),
                Row({ swatches, Label(custom and "自定义 · AI 数据" or "内置配色", 8.5,
                    custom and C.teal or C.dim, { flexGrow = 1, textAlign = "right" }) },
                    { height = 18, alignItems = "center" }),
            },
        })
    end
    self.paletteExpandedList:SetVisible(self.paletteExpanded)
end

function ControlPanel:SetCollapsed(collapsed)
    self.collapsed = collapsed
    self.panelShell:SetVisible(not collapsed)
    self.expandButton:SetVisible(collapsed)
end

function ControlPanel:SetCustomSettingExpanded(expanded)
    self.customSettingExpanded = expanded == true
    self.customSettingHint:SetVisible(self.customSettingExpanded)
    self.customSettingList:SetVisible(self.customSettingExpanded)
    self.customSettingToggleButton:SetExpanded(self.customSettingExpanded)
    self.customSettingToggleTooltip:SetContent(self.customSettingExpanded and "收起题材" or "展开题材")
end

function ControlPanel:SetRoomGroupExpanded(expanded)
    self.roomGroupExpanded = expanded == true
    self.roomGroupHint:SetVisible(self.roomGroupExpanded)
    self.roomGroupList:SetVisible(self.roomGroupExpanded)
    self.roomGroupToggleButton:SetExpanded(self.roomGroupExpanded)
    self.roomGroupToggleTooltip:SetContent(self.roomGroupExpanded and "收起房间" or "展开房间")
end

function ControlPanel:SetState(state)
    self.currentState = state
    self.seed = state.seed or self.seed
    self.seedField:SetValue(tostring(self.seed))
    local setting = Themes.GetSetting(state.settingKey)
    local theme = Themes.Get(state.themeKey)
    local fixedActive = state.topicMode == "fixedPCG"
        or (state.topicMode == nil and state.activeFixedThemeId ~= nil)
    self.fixedSettingModeButton:SetText("固定 PCG")
    self.fixedSettingModeButton:SetStyle({
        backgroundColor = fixedActive and { 48, 36, 29, 255 } or C.input,
        borderColor = fixedActive and { 139, 91, 52, 255 } or C.inputLine,
        textColor = fixedActive and { 255, 209, 157, 255 } or { 165, 173, 191, 255 },
    })
    self.currentPaletteButton:SetText(theme.label)
    self.currentPaletteButton:SetStyle({
        backgroundColor = { 48, 36, 29, 255 },
        borderColor = { 139, 91, 52, 255 },
        textColor = { 255, 209, 157, 255 },
    })
    self.subtitle:SetText(string.format("%s · %s · 种子 %u · %s", state.customSettingName or setting.label, theme.label,
        self.seed & 0xffffffff, state.valid == false and "生成失败" or "已连通 ✓"))
    if fixedActive then
        self.subtitle:SetText("固定 PCG · 空场景 · " .. theme.label)
    end
    for key, button in pairs(self.settingButtons) do
        local active = key == state.settingKey
            and (state.topicMode == "base"
                or (state.topicMode == nil and state.activeCustomSettingId == nil and state.activeFixedThemeId == nil))
        button:SetText(Themes.GetSetting(key).label)
        button:SetStyle({
            backgroundColor = active and { 48, 36, 29, 255 } or C.input,
            borderColor = active and { 139, 91, 52, 255 } or C.inputLine,
            textColor = active and { 255, 209, 157, 255 } or { 165, 173, 191, 255 },
        })
    end
    self:RebuildPaletteExpandedList(state)
    local options, total = {}, 0
    for floor = 1, state.floorCount do
        local count = state.roomCounts[floor] or 21
        total = total + count
        options[#options + 1] = { value = floor - 1, label = string.format("第 %d 层 · %d 个区域%s", floor, count, floor - 1 == state.currentFloor and "（当前）" or "") }
    end
    self.floorDropdown:SetOptions(options)
    self.floorDropdown:SetValue(state.currentFloor)
    self.floorSummary:SetText(string.format("共 %d 层 · %d 区", state.floorCount, total))
    local idx = state.currentFloor + 1
    local rooms = state.roomCounts[idx] or 21
    local loops = state.loopRates[idx] or 15
    local decor = state.decorDensities[idx] or 60
    self.roomSlider:SetValue(rooms); self.roomValue:SetText(tostring(rooms))
    self.loopSlider:SetValue(loops); self.loopValue:SetText(string.format("%d%%", loops))
    self.decorSlider:SetValue(decor); self.decorValue:SetText(string.format("%d%%", decor))
    for key, button in pairs(self.viewButtons) do
        local active = key == state.floorViewMode
        button:SetText(({current="当前",neighbors="相邻",all="全部",explode="展开"})[key])
        button:SetStyle({
            backgroundColor = active and { 48, 36, 29, 255 } or C.input,
            borderColor = active and { 139, 91, 52, 255 } or C.inputLine,
            textColor = active and { 255, 209, 157, 255 } or C.dim,
        })
    end
    self:RebuildCustomSettingList(state.customSettings)
    self:RebuildRoomGroupList(state.roomGroups)
    local roomGroupOptions = { { value = "", label = "不赋予房间组" } }
    for _, group in ipairs(state.roomGroups or {}) do
        local activeTopicId = state.topicMode == "custom" and state.activeCustomSettingId or nil
        if (activeTopicId and group.topicId == activeTopicId)
            or (not activeTopicId and not group.topicId) then
            roomGroupOptions[#roomGroupOptions + 1] = { value = group.id, label = group.name }
        end
    end
    self.roomGroupAssignmentDropdown:SetOptions(roomGroupOptions)
    self.updatingRoomAssignment = true
    self.roomGroupAssignmentDropdown:SetValue(state.selectedEditorRoomGroupId or "")
    self.updatingRoomAssignment = false
    local hasSelectedRoom = state.selectedEditorRoom ~= nil
    self.roomSelectionLabel:SetText(hasSelectedRoom and ("房间 #" .. state.selectedEditorRoom) or "未选择房间")
    self.roomGroupAssignmentDropdown:SetDisabled(not hasSelectedRoom)
    -- Match Three's canvas inspector: this is an absolute top overlay and never
    -- participates in the persistent left panel's layout.
    self.roomAssignmentPanel:SetVisible(state.editorActive == true and hasSelectedRoom)
    self:SetEditorActive(state.editorActive == true, state.editorMode)
end

function ControlPanel:SetDungeon(dungeon, generationMs)
    self.name:SetText(dungeon.name or "程序化房间生成器")
    self.stats:SetText(string.format("%d 房间 · %d 连接 · %d 回环\n%d 层 · %d 楼梯 · %d 地面格\n结构 %s · %.1f 毫秒",
        dungeon.stats.rooms, dungeon.stats.edges, dungeon.stats.loops, dungeon.stats.floors,
        #dungeon.connectors, dungeon.stats.floorTiles, tostring(dungeon.hash), generationMs or 0))
end

function ControlPanel:SetEditorActive(active, mode)
    local activeMode = active and mode or nil
    self.edit2DButton:SetText(activeMode == "2d" and "完成 2D ✓" or "▦ 2D 平面")
    self.edit3DButton:SetText(activeMode == "3d" and "完成 3D ✓" or "◇ 3D 编辑  E")
    self.edit2DButton:SetStyle({
        backgroundColor = activeMode == "2d" and { 48, 36, 29, 250 } or { 18, 23, 35, 245 },
        borderColor = activeMode == "2d" and C.accent or C.line,
    })
    self.edit3DButton:SetStyle({
        backgroundColor = activeMode == "3d" and { 48, 36, 29, 250 } or { 18, 23, 35, 245 },
        borderColor = activeMode == "3d" and C.accent or C.line,
    })
end
function ControlPanel:OpenRoomGroupAssignment()
    if not self.roomGroupAssignmentDropdown or not self.roomAssignmentPanel:IsVisible() then return false end
    self.roomGroupAssignmentDropdown:Open()
    return true
end

function ControlPanel:SetPreviewMode(mode)
    local first = mode == "first"
    self.previewModeLabel:SetText(first and "第一人称预览" or "第三人称预览")
    self.previewViewHint:SetText(first and "以角色视线高度观察空间细节" or "跟随角色观察房间布局与动线")
    self.previewCrosshair:SetVisible(first and self.previewActive)
    self.thirdPreviewButton:SetStyle({
        backgroundColor = not first and { 48, 36, 29, 250 } or { 20, 25, 37, 245 },
        borderColor = not first and C.accent or { 48, 55, 74, 255 },
    })
    self.firstPreviewButton:SetStyle({
        backgroundColor = first and { 48, 36, 29, 250 } or { 20, 25, 37, 245 },
        borderColor = first and C.accent or { 48, 55, 74, 255 },
    })
end

function ControlPanel:SetPreviewActive(active, mode)
    self.previewActive = active
    self.panelShell:SetVisible(not active and not self.collapsed)
    self.expandButton:SetVisible(not active and self.collapsed)
    self.hints:SetVisible(not active)
    self.editorButtons:SetVisible(not active)
    self.previewExitButton:SetVisible(active)
    self.previewHud:SetVisible(active)
    self.previewBarAnchor:SetStyle({ bottom = active and 18 or 48 })
    if active then self:SetPreviewMode(mode or "third") else self.previewCrosshair:SetVisible(false) end
end
function ControlPanel:SetStatus(text) self.stats:SetText(text) end
function ControlPanel:Dispose()
    if activeDropOwner == self then activeDropOwner = nil end
    UI.Shutdown()
end

return ControlPanel
