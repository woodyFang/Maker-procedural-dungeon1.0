local PaletteData = require("Config.PaletteData")

local PaletteAIProvider = {
    SCHEMA_VERSION = 1,
    SOURCE = "external-palette-ai-v1",
    STATUS = {
        IDLE = "idle",
        REQUESTING = "requesting",
        SUCCESS = "success",
        ERROR = "error",
        UNAVAILABLE = "unavailable",
    },
    UNAVAILABLE_REASON = "AI 配色服务尚未接入，请先使用“复制 AI 指令”或直接粘贴 JSON。",
}

local function Trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function BuildPrompt(description, label, template)
    return table.concat({
        "请为程序化 3D 场景生成一组模型材质配色。",
        "配色名称：" .. (label ~= "" and label or "未命名配色"),
        "视觉描述：" .. (description ~= "" and description
            or "在参考配色基础上形成清晰、克制的 PBR 色彩层级"),
        "只输出一个 JSON 对象，不要 Markdown、解释或额外字段。每个值必须是 #RRGGBB。",
        "必须保留字段：floor, corridor, wall, pillar, accentObject, cloth, flame, flameCore。",
        "字段语义：floor/corridor/wall/pillar 是结构层；accentObject/cloth 是强调层；flame/flameCore 是发光层。",
        "结构层需要属于同一材质家族且彼此可辨；不要返回 PBR 参数、灯光、雾效或其他字段。",
        "参考数据：",
        template,
    }, "\n")
end

function PaletteAIProvider.BuildRequest(description, label, baseSettingKey, template)
    description, label, baseSettingKey, template = Trim(description), Trim(label),
        Trim(baseSettingKey), Trim(template)
    return {
        schemaVersion = PaletteAIProvider.SCHEMA_VERSION,
        operation = "palette.generate",
        source = PaletteAIProvider.SOURCE,
        description = description,
        label = label,
        baseSettingKey = baseSettingKey,
        fields = PaletteData.COLOR_FIELDS,
        responseFormat = "palette-colors-v1",
        prompt = BuildPrompt(description, label, template),
        template = template,
    }
end

local function DecodeJSONText(text)
    text = Trim(text)
    if text == "" then return nil, "AI 服务返回了空内容。" end

    local fenced = text:match("^```[%w_-]*%s*(.-)%s*```$")
    if fenced then text = Trim(fenced) end

    local ok, decoded = pcall(cjson.decode, text)
    if ok and type(decoded) == "table" then return decoded end

    local objectText = text:match("(%b{})")
    if objectText and objectText ~= text then
        ok, decoded = pcall(cjson.decode, objectText)
        if ok and type(decoded) == "table" then return decoded end
    end
    return nil, "AI 服务返回的内容不是有效 JSON。"
end

local function ExtractContent(value)
    if type(value) == "string" then
        local decoded, reason = DecodeJSONText(value)
        if type(decoded) ~= "table" then return decoded, reason end
        -- A JSON string may itself be a provider envelope (choices /
        -- dataAsString); fall through so the table branch unwraps it.
        value = decoded
    end
    if type(value) ~= "table" then return nil, "AI 服务返回的内容格式不受支持。" end

    if value.dataAsString ~= nil then return ExtractContent(value.dataAsString) end
    if value.choices and value.choices[1] then
        local choice = value.choices[1]
        local message = choice.message or {}
        local content = message.content or choice.text
        if type(content) == "table" then
            local parts = {}
            for _, part in ipairs(content) do
                if type(part) == "table" and part.text then parts[#parts + 1] = part.text end
            end
            content = table.concat(parts)
        end
        return ExtractContent(content)
    end
    return value
end

function PaletteAIProvider.DecodeResponse(raw)
    local decoded, reason = ExtractContent(raw)
    if not decoded then return nil, reason end
    return PaletteData.NormalizeColors(decoded.colors or decoded)
end

-- The client cannot call an external HTTP service. A future server-backed
-- adapter should keep this callback contract and invoke done(rawResponse).
function PaletteAIProvider.Generate(_, _)
    return false, PaletteAIProvider.UNAVAILABLE_REASON
end

return PaletteAIProvider
