local GeometryRules = require("Generation.GeometryRules")

local ThemePacks = {
    SCHEMA_VERSION = 2,
    packs = {},
}

local function Rule(kind, count, chance, scaleMin, scaleMax, extra)
    local rule = {
        kind = kind,
        count = count or 1,
        chance = chance == nil and 1 or chance,
        scaleMin = scaleMin or 0.92,
        scaleMax = scaleMax or scaleMin or 1.0,
    }
    -- Optional layout params (layout, step, rot, margin, max, anchor, ...) let a
    -- rule opt into a structured RoomLayout instead of random scatter.
    if extra then for key, value in pairs(extra) do rule[key] = value end end
    return rule
end

-- AI-authored packs are data only. The runtime validates this manifest before
-- it is allowed to drive generation, so a prompt can never inject arbitrary Lua.
ThemePacks.packs.school = {
    schemaVersion = ThemePacks.SCHEMA_VERSION,
    key = "school",
    label = "学校",
    source = "ai-authored",
    prompt = "现代学校，教室、图书馆、实验室和公共走廊，克制的低多边形 PBR 美术",
    promptKeywords = {
        "学校", "校园", "教室", "课桌", "黑板", "图书馆", "实验室",
        "school", "campus", "classroom", "library", "laboratory",
    },
    palettes = { "schoolDay", "schoolClassic", "schoolEvening" },
    verticalProfile = {
        schemaVersion = GeometryRules.VERTICAL_PROFILE_SCHEMA_VERSION,
        authoredFloorHeight = 5.0,
        authoredVerticalScale = 1.0,
        structureScaleMode = "five-meter-baseline",
        propScaleMode = "human-scale",
        wallMountMode = "below-wall-top",
        wallMode = "partition",
        columnMode = "none",
    },
    structure = {
        floorGeometry = "schoolFloor", floorMaterial = "schoolFloor",
        wallGeometry = "schoolWall", wallMaterial = "schoolWall",
        capGeometry = "schoolWallCap", capMaterial = "schoolTrim",
        doorPostGeometry = "schoolDoorPost", doorLintelGeometry = "schoolDoorLintel",
        doorMaterial = "schoolTrim",
        wallHeight = GeometryRules.SCHOOL_WALL_HEIGHT,
        wallHeightVariation = GeometryRules.SCHOOL_WALL_HEIGHT_VARIATION,
        wallCapHeight = GeometryRules.SCHOOL_WALL_CAP_HEIGHT,
        doorPostHeight = GeometryRules.SCHOOL_DOOR_POST_HEIGHT,
        doorLintelBase = GeometryRules.SCHOOL_DOOR_LINTEL_BASE,
        doorLintelHeight = GeometryRules.SCHOOL_DOOR_LINTEL_HEIGHT,
    },
    spawnVisual = {
        geometry = "schoolSpawnMarker",
        material = "schoolAccent",
        colors = { 0x4e9f8e, 0xd49a35, 0xc95f55 },
        scales = { 0.78, 0.94, 1.10 },
    },
    props = {
        schoolStudentDesk = { geometry = "schoolStudentDesk", material = "schoolWood", color = 0xb98b55 },
        schoolTeacherDesk = { geometry = "schoolTeacherDesk", material = "schoolWood", color = 0x9b7046 },
        schoolLocker = { geometry = "schoolLocker", material = "schoolTrim", color = 0x6f948d },
        schoolBookshelf = { geometry = "schoolBookshelf", material = "schoolWood", color = 0x8f6745 },
        schoolLabBench = { geometry = "schoolLabBench", material = "schoolCounter", color = 0x96aaa5 },
        schoolCafeteriaTable = { geometry = "schoolCafeteriaTable", material = "schoolWood", color = 0xb18b62 },
        schoolReception = { geometry = "schoolReception", material = "schoolWood", color = 0xa57b50 },
        schoolGlobe = { geometry = "schoolGlobe", material = "schoolAccent", color = 0x4e91a8 },
        schoolStage = { geometry = "schoolStage", material = "schoolWood", color = 0x8d6242 },
        schoolBlackboard = {
            geometry = "schoolBlackboard", material = "schoolBoard", color = 0x244d43,
            mount = "wall", height = 1.62,
        },
        schoolNoticeBoard = {
            geometry = "schoolNoticeBoard", material = "schoolWood", color = 0xb88a52,
            mount = "wall", height = 1.48,
        },
        schoolClock = {
            geometry = "clock", material = "schoolTrim", color = 0xc4c0b4,
            mount = "wall", height = 1.78,
        },
        schoolWallLight = {
            geometry = "wallLight", material = "glow", color = 0xd5b77b,
            mount = "wall", height = 1.88, emitsLight = true,
        },
    },
    roomRules = {
        entrance = {
            Rule("schoolReception", 1, 1.0, 1.08, nil, { layout = "focal" }),
            Rule("schoolLocker", 2, 1.0, 0.92, 1.02, { layout = "perimeter", step = 2 }),
        },
        combat = {
            -- Classroom: desks in aligned rows facing the front, teacher desk focal.
            Rule("schoolStudentDesk", 4, 1.0, 0.92, 1.02, { layout = "grid", step = 2, rot = 0 }),
            Rule("schoolTeacherDesk", 1, 0.82, 0.95, 1.02, { layout = "focal" }),
        },
        elite = {
            -- Laboratory: benches in rows, globe as centre focal.
            Rule("schoolLabBench", 3, 1.0, 0.92, 1.02, { layout = "grid", step = 3, rot = 0 }),
            Rule("schoolGlobe", 1, 0.78, 0.92, 1.05, { layout = "focal" }),
        },
        treasure = {
            -- Library: bookshelves lined against the walls.
            Rule("schoolBookshelf", 4, 1.0, 0.90, 1.02, { layout = "perimeter", step = 2 }),
            Rule("schoolTeacherDesk", 1, 0.82, 0.92, nil, { layout = "focal" }),
        },
        shrine = {
            Rule("schoolLabBench", 2, 1.0, 0.95, 1.05, { layout = "grid", step = 3, rot = 0 }),
            Rule("schoolGlobe", 1, 1.0, 1.0, nil, { layout = "focal" }),
            Rule("schoolBookshelf", 1, 0.72, 0.92, nil, { layout = "perimeter", step = 3 }),
        },
        boss = {
            -- Cafeteria: stage focal, dining tables in a neat grid.
            Rule("schoolStage", 1, 1.0, 1.12, nil, { layout = "focal" }),
            Rule("schoolCafeteriaTable", 4, 1.0, 0.95, 1.05, { layout = "grid", step = 3, rot = 0 }),
        },
        default = {
            Rule("schoolStudentDesk", 3, 1.0, 0.92, 1.02, { layout = "grid", step = 2, rot = 0 }),
            Rule("schoolLocker", 1, 0.62, 0.88, 0.98, { layout = "perimeter", step = 3 }),
            Rule("schoolBookshelf", 1, 0.48, 0.88, 0.98),
        },
    },
    wallRules = {
        Rule("schoolWallLight", 1, 0.50, 0.92, 1.04),
        Rule("schoolBlackboard", 1, 0.18, 0.92, 1.04),
        Rule("schoolNoticeBoard", 1, 0.16, 0.90, 1.02),
        Rule("schoolClock", 1, 0.10, 0.90, 1.02),
    },
}

local function ValidateRule(rule, props, label)
    if type(rule) ~= "table" or type(rule.kind) ~= "string" or not props[rule.kind] then
        return false, label .. " references an unknown prop"
    end
    if (rule.count or 1) < 1 then return false, label .. " has an invalid count" end
    if (rule.chance or 0) < 0 or (rule.chance or 0) > 1 then
        return false, label .. " chance is outside 0..1"
    end
    return true
end

local function ValidateModelColor(value, label)
    if type(value) ~= "number" or value < 0 or value > 0xffffff then
        return false, label .. " color is not a valid #RRGGBB value"
    end
    local red = (value >> 16) & 0xff
    local green = (value >> 8) & 0xff
    local blue = value & 0xff
    if math.max(red, green, blue) > 0xdc then
        return false, label .. " non-emissive color is too bright"
    end
    return true
end

function ThemePacks.Validate(pack, geometry, profiles)
    if type(pack) ~= "table" then return false, "theme pack is not a table" end
    if pack.schemaVersion ~= ThemePacks.SCHEMA_VERSION then return false, "theme pack schema mismatch" end
    if type(pack.key) ~= "string" or pack.key == "" then return false, "theme pack key is missing" end
    if type(pack.structure) ~= "table" or type(pack.props) ~= "table" then
        return false, "theme pack structure or props are missing"
    end
    local validVertical, verticalReason = GeometryRules.ValidateThemePackVertical(pack)
    if not validVertical then return false, verticalReason end
    for roomType, rules in pairs(pack.roomRules or {}) do
        for index, rule in ipairs(rules) do
            local valid, reason = ValidateRule(rule, pack.props, roomType .. " rule " .. index)
            if not valid then return false, reason end
        end
    end
    for index, rule in ipairs(pack.wallRules or {}) do
        local valid, reason = ValidateRule(rule, pack.props, "wall rule " .. index)
        if not valid then return false, reason end
    end
    for kind, spec in pairs(pack.props) do
        if spec.material ~= "glow" and spec.color ~= nil then
            local valid, reason = ValidateModelColor(spec.color, kind)
            if not valid then return false, reason end
        end
    end
    if pack.spawnVisual and pack.spawnVisual.colors then
        for index, color in ipairs(pack.spawnVisual.colors) do
            local valid, reason = ValidateModelColor(color, "spawn visual " .. index)
            if not valid then return false, reason end
        end
    end
    if geometry then
        for name, key in pairs(pack.structure) do
            if name:find("Geometry", 1, true) and not geometry[key] then
                return false, "missing structure geometry " .. tostring(key)
            end
        end
        for kind, spec in pairs(pack.props) do
            if not geometry[spec.geometry] then return false, "missing geometry for " .. kind end
        end
        if pack.spawnVisual and not geometry[pack.spawnVisual.geometry] then
            return false, "missing spawn visual geometry " .. tostring(pack.spawnVisual.geometry)
        end
    end
    if profiles then
        for name, key in pairs(pack.structure) do
            if name:find("Material", 1, true) and key ~= "glow" and not profiles[key] then
                return false, "missing structure material " .. tostring(key)
            end
        end
        for kind, spec in pairs(pack.props) do
            if spec.material ~= "glow" and not profiles[spec.material] then
                return false, "missing material for " .. kind
            end
        end
        if pack.spawnVisual and pack.spawnVisual.material ~= "glow"
            and not profiles[pack.spawnVisual.material] then
            return false, "missing spawn visual material " .. tostring(pack.spawnVisual.material)
        end
    end
    return true
end

function ThemePacks.ValidateRoomGroups(pack, groups)
    if type(pack) ~= "table" or type(pack.props) ~= "table" then
        return false, "room groups require a validated theme pack"
    end
    if type(groups) ~= "table" or #groups == 0 then return false, "room groups are missing" end
    local ids, defaultCount = {}, 0
    for index, group in ipairs(groups) do
        if type(group.id) ~= "string" or group.id == "" or ids[group.id] then
            return false, "room group " .. index .. " has a missing or duplicate id"
        end
        if type(group.name) ~= "string" or group.name == "" then
            return false, "room group " .. index .. " has no name"
        end
        if type(group.roleKeys) ~= "table" or #group.roleKeys == 0 then
            return false, group.name .. " has no semantic room roles"
        end
        if group.defaultGroup == true then defaultCount = defaultCount + 1 end
        if type(group.propRules) ~= "table" or #group.propRules == 0 then
            return false, group.name .. " has no prop rules"
        end
        for ruleIndex, rule in ipairs(group.propRules) do
            local valid, reason = ValidateRule(rule, pack.props, group.name .. " rule " .. ruleIndex)
            if not valid then return false, reason end
        end
        ids[group.id] = true
    end
    if defaultCount ~= 1 then return false, "room groups require exactly one default group" end
    return true
end

function ThemePacks.Get(key)
    return ThemePacks.packs[key]
end

function ThemePacks.ResolvePrompt(prompt, label, fallback)
    local text = string.lower(tostring(label or "") .. " " .. tostring(prompt or ""))
    for key, pack in pairs(ThemePacks.packs) do
        for _, keyword in ipairs(pack.promptKeywords or {}) do
            if text:find(string.lower(keyword), 1, true) then return key, pack end
        end
    end
    return fallback, ThemePacks.packs[fallback]
end

function ThemePacks.All()
    return ThemePacks.packs
end

return ThemePacks
