local PaletteData = {}

PaletteData.SCHEMA_VERSION = 1
PaletteData.COLOR_FIELDS = {
    "floor", "corridor", "wall", "pillar",
    "accentObject", "cloth", "flame", "flameCore",
}

PaletteData.FIELD_LABELS = {
    floor = "地面", corridor = "走廊", wall = "墙体", pillar = "结构",
    accentObject = "强调物", cloth = "织物", flame = "发光", flameCore = "高光",
}

local function ClampByte(value)
    return math.max(0, math.min(255, math.floor(value + 0.5)))
end

local function ParseColor(value)
    if type(value) == "number" then
        local integer = math.floor(value)
        if integer >= 0 and integer <= 0xffffff then return integer end
        return nil
    end
    if type(value) ~= "string" then return nil end
    local text = value:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("^#", ""):gsub("^0[xX]", "")
    if #text ~= 6 or not text:match("^[0-9a-fA-F]+$") then return nil end
    return tonumber(text, 16)
end

local function Clone(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = Clone(item) end
    return copy
end

local function MixColor(a, b, amount)
    local ar, ag, ab = (a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff
    local br, bg, bb = (b >> 16) & 0xff, (b >> 8) & 0xff, b & 0xff
    local r = ClampByte(ar + (br - ar) * amount)
    local g = ClampByte(ag + (bg - ag) * amount)
    local blue = ClampByte(ab + (bb - ab) * amount)
    return (r << 16) | (g << 8) | blue
end

function PaletteData.ParseColor(value)
    return ParseColor(value)
end

function PaletteData.NormalizeColors(source)
    if type(source) ~= "table" then return nil, "配色数据必须是 JSON 对象。" end
    local colors = {}
    for _, field in ipairs(PaletteData.COLOR_FIELDS) do
        local value = ParseColor(source[field])
        if value == nil then
            return nil, string.format("字段 %s（%s）缺失或不是 #RRGGBB。", field,
                PaletteData.FIELD_LABELS[field] or field)
        end
        colors[field] = value
    end
    return colors
end

function PaletteData.DecodeAIData(raw)
    local text = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "请粘贴或生成 AI 配色数据。" end
    local ok, decoded = pcall(cjson.decode, text)
    if not ok or type(decoded) ~= "table" then return nil, "AI 配色数据不是有效 JSON。" end
    return PaletteData.NormalizeColors(decoded.colors or decoded)
end

function PaletteData.EncodeAIData(colors)
    local normalized, reason = PaletteData.NormalizeColors(colors)
    if not normalized then return "", reason end
    local lines = { "{" }
    for index, field in ipairs(PaletteData.COLOR_FIELDS) do
        lines[#lines + 1] = string.format('  "%s": "#%06X"%s', field, normalized[field],
            index < #PaletteData.COLOR_FIELDS and "," or "")
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

function PaletteData.CreateRuntimeTheme(record, baseTheme)
    if type(record) ~= "table" or type(baseTheme) ~= "table" then return nil end
    local colors = PaletteData.NormalizeColors(record.colors)
    if not colors then return nil end
    local theme = Clone(baseTheme)
    theme.key = record.id
    theme.label = record.label
    theme.isCustom = true
    theme.customPaletteId = record.id
    for _, field in ipairs(PaletteData.COLOR_FIELDS) do theme[field] = colors[field] end
    theme.accent = colors.accentObject
    theme.cap = MixColor(colors.wall, 0xffffff, 0.16)
    theme.debris = { MixColor(colors.wall, 0x000000, 0.24), MixColor(colors.corridor, 0x000000, 0.12) }
    local oldTorch = type(baseTheme.torchLight) == "table" and baseTheme.torchLight or { colors.flame, 1.0, 9.0 }
    theme.torchLight = { colors.flame, oldTorch[2] or 1.0, oldTorch[3] or 9.0 }
    if type(theme.pools) == "table" then
        theme.pools.colA = MixColor(colors.accentObject, 0x000000, 0.72)
        theme.pools.colB = colors.accentObject
    end
    if type(theme.particles) == "table" then theme.particles.color = colors.flameCore end
    return theme
end

function PaletteData.ToRGBA(value, alpha)
    local color = ParseColor(value) or 0
    return { (color >> 16) & 0xff, (color >> 8) & 0xff, color & 0xff, alpha or 255 }
end

return PaletteData
