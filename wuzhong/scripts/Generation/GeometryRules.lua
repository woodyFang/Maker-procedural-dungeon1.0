local MultiFloor = require("Generation.MultiFloor")

local GeometryRules = {
    CELL_SIZE = 1.0,
    SEAM_EPSILON = 0.003,
    VERTICAL_PROFILE_SCHEMA_VERSION = 1,
    VERTICAL_EPSILON = 0.000001,
    FULL_HEIGHT_CLEARANCE_MAX = 0.400,

    -- The visible tiles keep the Three.js dimensions and height variation.
    FLOOR_Y_JITTER_MIN = -0.020,
    FLOOR_Y_JITTER_MAX = 0.008,
    DUNGEON_FLOOR_BRICK_SIZE = 0.960,
    DUNGEON_FLOOR_BRICK_HEIGHT = 0.220,
    DUNGEON_FLOOR_BRICK_CHAMFER = 0.030,
    DUNGEON_FLOOR_BRICK_GAP_MIN = 0.020,
    DUNGEON_FLOOR_BRICK_GAP_MAX = 0.060,

    -- Authored against the unified 5m art baseline. At the default 5m storey
    -- these values are used at 1:1; an explicit storey override scales every
    -- local Y coordinate through MultiFloor.VERTICAL_SCALE.
    DUNGEON_WALL_CAP_HEIGHT = 0.130,
    HOSPITAL_WALL_CAP_HEIGHT = 0.100,
    SCHOOL_WALL_CAP_HEIGHT = 0.100,
    DUNGEON_WALL_HEIGHT = 2.000,
    DUNGEON_WALL_HEIGHT_VARIATION = 0.250,
    HOSPITAL_WALL_HEIGHT = 2.250,
    HOSPITAL_WALL_HEIGHT_VARIATION = 0.080,
    SCHOOL_WALL_HEIGHT = 2.550,
    SCHOOL_WALL_HEIGHT_VARIATION = 0.040,
    DUNGEON_DOOR_LINTEL_BASE = 1.620,
    DUNGEON_DOOR_LINTEL_HEIGHT = 0.220,
    HOSPITAL_DOOR_LINTEL_BASE = 1.520,
    HOSPITAL_DOOR_LINTEL_HEIGHT = 0.160,
    SCHOOL_DOOR_LINTEL_BASE = 1.850,
    SCHOOL_DOOR_LINTEL_HEIGHT = 0.180,
    SCHOOL_DOOR_POST_HEIGHT = 1.920,

    -- A constant-height structural layer seals the gaps below those tiles.
    FLOOR_SEAL_TOP = -0.075,
    FLOOR_SEAL_DEPTH = 0.120,
    SUBMERGED_SEAL_OFFSET = -0.100,
    FLOOR_SEAL_COLOR_FACTOR = 0.68,

    -- Hospital tiles are the shallowest visible floor geometry: 0.1m deep.
    SHALLOW_FLOOR_BOTTOM = -0.100,

    -- The narrowest visible tile is 0.96m. A wall-foot structural seal reaches
    -- across that visual inset, while the wall body is sunk into the floor seal.
    MIN_VISIBLE_FLOOR_SIZE = 0.960,
    WALL_FLOOR_VERTICAL_OVERLAP = 0.100,
}

local function NearlyEqual(a, b)
    return type(a) == "number" and type(b) == "number"
        and math.abs(a - b) <= GeometryRules.VERTICAL_EPSILON
end

function GeometryRules.CurrentVerticalProfile(floorHeight)
    floorHeight = MultiFloor.NormalizeFloorHeight(floorHeight)
    return {
        schemaVersion = GeometryRules.VERTICAL_PROFILE_SCHEMA_VERSION,
        authoredFloorHeight = MultiFloor.SOURCE_FLOOR_HEIGHT,
        floorHeight = floorHeight,
        verticalScale = floorHeight / MultiFloor.SOURCE_FLOOR_HEIGHT,
        structureScaleMode = "five-meter-baseline",
        propScaleMode = "human-scale",
        wallMountMode = "below-wall-top",
    }
end

function GeometryRules.VerticalPromptClause(floorHeight)
    local profile = GeometryRules.CurrentVerticalProfile(floorHeight)
    return string.format(
        "通用尺度规则：程序化美术以 %.2f 米层高为制作基准；本题材楼层间距 %.2f 米、纵向比例 %.2f。"
            .. "墙体、柱子和门框必须声明结构高度及用途；家具和普通道具保持人体尺度；"
            .. "墙挂物安装点不得高于最低墙顶。",
        profile.authoredFloorHeight, profile.floorHeight, profile.verticalScale)
end

function GeometryRules.ValidateThemePackVertical(pack)
    local profile = type(pack) == "table" and pack.verticalProfile or nil
    if type(profile) ~= "table" then return false, "theme pack vertical profile is missing" end
    if profile.schemaVersion ~= GeometryRules.VERTICAL_PROFILE_SCHEMA_VERSION then
        return false, "theme pack vertical profile schema mismatch"
    end
    if not NearlyEqual(profile.authoredFloorHeight, MultiFloor.SOURCE_FLOOR_HEIGHT) then
        return false, "theme pack is not authored for the unified 5m baseline"
    end
    if not NearlyEqual(profile.authoredVerticalScale, 1.0) then
        return false, "theme pack authored vertical scale must be 1.0"
    end
    if profile.structureScaleMode ~= "five-meter-baseline"
        or profile.propScaleMode ~= "human-scale"
        or profile.wallMountMode ~= "below-wall-top" then
        return false, "theme pack vertical scale policy is incomplete"
    end
    if profile.wallMode ~= "partition" and profile.wallMode ~= "full-height" then
        return false, "theme pack wall mode must be partition or full-height"
    end
    if profile.columnMode ~= "none" and profile.columnMode ~= "decorative"
        and profile.columnMode ~= "full-height" then
        return false, "theme pack column mode must be none, decorative or full-height"
    end

    local structure = pack.structure
    if type(structure) ~= "table" then return false, "theme pack structure is missing" end
    for _, name in ipairs({ "wallHeight", "wallHeightVariation", "wallCapHeight",
        "doorPostHeight", "doorLintelBase", "doorLintelHeight" }) do
        if type(structure[name]) ~= "number" then
            return false, "theme pack structure is missing " .. name
        end
    end
    local minimumWallTop = structure.wallHeight - structure.wallHeightVariation
    local maximumWallTop = structure.wallHeight + structure.wallHeightVariation + structure.wallCapHeight
    local lintelTop = structure.doorLintelBase + structure.doorLintelHeight
    if minimumWallTop <= 0 or maximumWallTop > MultiFloor.SOURCE_FLOOR_HEIGHT then
        return false, "theme pack wall height is outside the 5m baseline"
    end
    if structure.doorPostHeight <= 0 or structure.doorLintelBase <= 0
        or structure.doorLintelHeight <= 0 or lintelTop > minimumWallTop then
        return false, "theme pack door frame does not fit below the minimum wall top"
    end
    if profile.wallMode == "full-height"
        and MultiFloor.SOURCE_FLOOR_HEIGHT - maximumWallTop > GeometryRules.FULL_HEIGHT_CLEARANCE_MAX then
        return false, "full-height wall leaves too much clearance below the 5m storey"
    end
    if profile.columnMode ~= "none" then
        if type(structure.columnHeight) ~= "number" or structure.columnHeight <= 0
            or structure.columnHeight > MultiFloor.SOURCE_FLOOR_HEIGHT then
            return false, "theme pack column height is outside the 5m baseline"
        end
        if profile.columnMode == "full-height"
            and MultiFloor.SOURCE_FLOOR_HEIGHT - structure.columnHeight
                > GeometryRules.FULL_HEIGHT_CLEARANCE_MAX then
            return false, "full-height column leaves too much clearance below the 5m storey"
        end
    end
    for kind, spec in pairs(pack.props or {}) do
        if spec.mount == "wall" then
            if type(spec.height) ~= "number" or spec.height < 0 or spec.height > minimumWallTop then
                return false, "wall-mounted prop exceeds the minimum wall top: " .. tostring(kind)
            end
        end
    end
    return true
end

function GeometryRules.FloorSealSize()
    return GeometryRules.CELL_SIZE + GeometryRules.SEAM_EPSILON * 2
end

function GeometryRules.DungeonFloorBrickGap()
    return GeometryRules.CELL_SIZE - GeometryRules.DUNGEON_FLOOR_BRICK_SIZE
end

function GeometryRules.DoorLintelBase(hospital)
    return hospital and GeometryRules.HOSPITAL_DOOR_LINTEL_BASE
        or GeometryRules.DUNGEON_DOOR_LINTEL_BASE
end

function GeometryRules.DoorLintelHeight(hospital)
    return hospital and GeometryRules.HOSPITAL_DOOR_LINTEL_HEIGHT
        or GeometryRules.DUNGEON_DOOR_LINTEL_HEIGHT
end

function GeometryRules.WallHeightRange(verticalScale, hospital)
    local height = hospital and GeometryRules.HOSPITAL_WALL_HEIGHT or GeometryRules.DUNGEON_WALL_HEIGHT
    local variation = hospital and GeometryRules.HOSPITAL_WALL_HEIGHT_VARIATION
        or GeometryRules.DUNGEON_WALL_HEIGHT_VARIATION
    return (height - variation) * verticalScale, (height + variation) * verticalScale
end

function GeometryRules.FloorSealCenterY()
    return GeometryRules.FLOOR_SEAL_TOP - GeometryRules.FLOOR_SEAL_DEPTH * 0.5
end

function GeometryRules.WallFootprintSize()
    local floorInset = (GeometryRules.CELL_SIZE - GeometryRules.MIN_VISIBLE_FLOOR_SIZE) * 0.5
    return GeometryRules.CELL_SIZE + (floorInset + GeometryRules.SEAM_EPSILON) * 2
end

function GeometryRules.WallFootCenterY()
    return -GeometryRules.WALL_FLOOR_VERTICAL_OVERLAP * 0.5
end

function GeometryRules.WallFloorHorizontalOverlap()
    local floorEdge = GeometryRules.MIN_VISIBLE_FLOOR_SIZE * 0.5
    local wallNearEdge = GeometryRules.CELL_SIZE - GeometryRules.WallFootprintSize() * 0.5
    return floorEdge - wallNearEdge
end

function GeometryRules.WallFloorVerticalOverlap()
    local wallFootBottom = -GeometryRules.WALL_FLOOR_VERTICAL_OVERLAP
    return GeometryRules.FLOOR_SEAL_TOP - wallFootBottom
end

function GeometryRules.Validate()
    if not NearlyEqual(MultiFloor.SOURCE_FLOOR_HEIGHT, 5.0) then
        return false, "procedural geometry art baseline must remain 5m"
    end
    if not NearlyEqual(MultiFloor.VERTICAL_SCALE,
            MultiFloor.FLOOR_HEIGHT / MultiFloor.SOURCE_FLOOR_HEIGHT) then
        return false, "vertical scale diverged from floor height / authored floor height"
    end
    local requiredCoverage = GeometryRules.CELL_SIZE + GeometryRules.SEAM_EPSILON * 2
    if GeometryRules.FloorSealSize() < requiredCoverage then
        return false, "floor seal does not cover cell plus seam overlap"
    end
    if GeometryRules.FLOOR_SEAL_TOP >= GeometryRules.FLOOR_Y_JITTER_MIN then
        return false, "floor seal would cover the visible tile surface"
    end
    if GeometryRules.MIN_VISIBLE_FLOOR_SIZE ~= GeometryRules.DUNGEON_FLOOR_BRICK_SIZE then
        return false, "wall-floor overlap must use the authored dungeon brick size"
    end
    local brickGap = GeometryRules.DungeonFloorBrickGap()
    if brickGap < GeometryRules.DUNGEON_FLOOR_BRICK_GAP_MIN
        or brickGap > GeometryRules.DUNGEON_FLOOR_BRICK_GAP_MAX then
        return false, "dungeon floor brick gap is not visibly readable"
    end
    if GeometryRules.DUNGEON_FLOOR_BRICK_CHAMFER <= 0
        or GeometryRules.DUNGEON_FLOOR_BRICK_CHAMFER >= GeometryRules.DUNGEON_FLOOR_BRICK_HEIGHT * 0.5 then
        return false, "dungeon floor brick chamfer is outside its structural range"
    end
    local highestShallowBottom = GeometryRules.SHALLOW_FLOOR_BOTTOM + GeometryRules.FLOOR_Y_JITTER_MAX
    if GeometryRules.FLOOR_SEAL_TOP < highestShallowBottom then
        return false, "floor seal does not overlap the shallowest jittered tile"
    end
    if GeometryRules.WallFloorHorizontalOverlap() < GeometryRules.SEAM_EPSILON then
        return false, "wall foot does not overlap the narrowest visible floor tile"
    end
    if GeometryRules.WallFloorVerticalOverlap() < GeometryRules.SEAM_EPSILON then
        return false, "wall foot does not overlap the floor structural seal"
    end
    return true
end

return GeometryRules
