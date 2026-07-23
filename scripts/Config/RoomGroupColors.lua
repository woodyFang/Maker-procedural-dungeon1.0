local RoomGroupColors = {}

RoomGroupColors.DEFAULTS = {
    entrance = 0x43d7af,
    treasure = 0xe0b657,
    boss = 0xe85d62,
    elite = 0xa783e8,
    shrine = 0xd58cff,
    combat = 0x56b8d0,
    secret = 0xff8f70,
}

RoomGroupColors.FALLBACK = 0x56b8d0
RoomGroupColors.DEFAULT_KEY_ORDER = { "entrance", "treasure", "boss", "elite", "shrine", "combat", "secret" }

local function Parse(value)
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

function RoomGroupColors.Parse(value, fallback)
    return Parse(value) or Parse(fallback) or RoomGroupColors.FALLBACK
end

function RoomGroupColors.Default(group, index)
    local keys = type(group) == "table" and group.roleKeys or nil
    if type(keys) == "table" then
        for _, key in ipairs(keys) do
            if RoomGroupColors.DEFAULTS[key] then return RoomGroupColors.DEFAULTS[key] end
        end
    end

    local id = type(group) == "table" and tostring(group.id or "") or ""
    for _, key in ipairs(RoomGroupColors.DEFAULT_KEY_ORDER) do
        local color = RoomGroupColors.DEFAULTS[key]
        if id:lower():find(key, 1, true) then return color end
    end

    local order = math.max(1, math.floor(tonumber(index) or 1))
    local palette = { 0x43d7af, 0x56b8d0, 0xe0b657, 0xe85d62, 0xa783e8, 0xff8f70 }
    return palette[((order - 1) % #palette) + 1]
end

-- A wider spread of muted tones used to give ungrouped rooms distinct color
-- identities instead of a single flat fill. Deterministic by index so a room
-- keeps its color across redraws.
RoomGroupColors.INDEX_PALETTE = {
    0x56b8d0, 0x43d7af, 0xe0b657, 0xe85d62, 0xa783e8,
    0xff8f70, 0x6fa8e8, 0x8bd06a, 0xd58cff, 0xf0a03c,
    0x4fc2a8, 0xd76a9b,
}

function RoomGroupColors.ByIndex(index)
    local order = math.max(1, math.floor(tonumber(index) or 1))
    local palette = RoomGroupColors.INDEX_PALETTE
    return palette[((order - 1) % #palette) + 1]
end

function RoomGroupColors.ToHex(value)
    return string.format("#%06X", RoomGroupColors.Parse(value))
end

function RoomGroupColors.ToRGBA(value, alpha)
    local color = RoomGroupColors.Parse(value)
    return { (color >> 16) & 0xff, (color >> 8) & 0xff, color & 0xff, alpha or 255 }
end

return RoomGroupColors
