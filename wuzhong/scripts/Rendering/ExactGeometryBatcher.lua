local Random = require("Generation.Random")
local MultiFloor = require("Generation.MultiFloor")
local GeometryRules = require("Generation.GeometryRules")
local Geometry = require("Rendering.DungeonGeometryLibrary")
local Bridge = require("Rendering.GeometryBridge")
local MaterialRules = require("Rendering.ProceduralMaterialRules")
local ThemePacks = require("Config.ThemePacks")

local materialRulesValid, materialRulesError = MaterialRules.Validate()
assert(materialRulesValid, materialRulesError)

local ExactGeometryBatcher = {}
ExactGeometryBatcher.__index = ExactGeometryBatcher

local TILE_FLOOR = 1
local TILE_WALL = 2

local ROOM_TINT = {
    entrance = 0x3fd0bb,
    combat = 0x8f95a3,
    elite = 0x9b6cf0,
    treasure = 0xd9a441,
    shrine = 0x5a8fe8,
    boss = 0xd8433a,
}

local function ClampByte(value)
    return math.max(0, math.min(255, math.floor(value + 0.5)))
end

local function Channels(value)
    return (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff
end

local function FromChannels(r, g, b)
    return (ClampByte(r) << 16) | (ClampByte(g) << 8) | ClampByte(b)
end

local function LerpColor(a, b, amount)
    local ar, ag, ab = Channels(a)
    local br, bg, bb = Channels(b)
    return FromChannels(ar + (br - ar) * amount, ag + (bg - ag) * amount, ab + (bb - ab) * amount)
end

local function MultiplyColor(value, factor)
    local r, g, b = Channels(value)
    return FromChannels(r * factor, g * factor, b * factor)
end

local function Index(x, y, width)
    return y * width + x + 1
end

local function MakeMaterials()
    local profiles = MaterialRules.PROFILES
    return {
        floor = Bridge.Material(profiles.dungeonFloor),
        wall = Bridge.Material(profiles.dungeonWall),
        cap = Bridge.Material(profiles.dungeonCap),
        stone = Bridge.Material(profiles.stone),
        hospitalFloor = Bridge.Material(profiles.hospitalFloor),
        hospitalWall = Bridge.Material(profiles.hospitalWall),
        hospitalTrim = Bridge.Material(profiles.hospitalTrim),
        schoolFloor = Bridge.Material(profiles.schoolFloor),
        schoolWall = Bridge.Material(profiles.schoolWall),
        schoolTrim = Bridge.Material(profiles.schoolTrim),
        schoolWood = Bridge.Material(profiles.schoolWood),
        schoolBoard = Bridge.Material(profiles.schoolBoard),
        schoolCounter = Bridge.Material(profiles.schoolCounter),
        schoolAccent = Bridge.Material(profiles.schoolAccent),
        trim = Bridge.Material(profiles.metalTrim),
        cloth = Bridge.Material(profiles.cloth),
        ice = Bridge.Material(profiles.ice),
        moss = Bridge.Material(profiles.moss),
        bark = Bridge.Material(profiles.bark),
    }
end

function ExactGeometryBatcher.new(dungeon, theme, settingKey)
    local pack = ThemePacks.Get(settingKey)
    if pack then
        local valid, reason = ThemePacks.Validate(pack, Geometry.GEO, MaterialRules.PROFILES)
        assert(valid, reason)
    end
    return setmetatable({
        dungeon = dungeon,
        theme = theme,
        settingKey = settingKey,
        pack = pack,
        hospital = settingKey == "hospital",
        school = settingKey == "school",
        materials = MakeMaterials(),
        emissiveMaterials = {},
        batches = {},
        buildLayer = nil,
        stagedEntries = {},
        instanceCount = 0,
        batchCount = 0,
        verticalScale = dungeon.floorHeight / MultiFloor.SOURCE_FLOOR_HEIGHT,
        activeBaseY = nil,
    }, ExactGeometryBatcher)
end

function ExactGeometryBatcher:WorldPosition(gridX, gridY, floor, floorSpacing, localY)
    return (gridX - self.dungeon.width * 0.5 + 0.5) * GeometryRules.CELL_SIZE,
        floor * self.dungeon.floorHeight * floorSpacing + (localY or 0),
        (gridY - self.dungeon.height * 0.5 + 0.5) * GeometryRules.CELL_SIZE
end

function ExactGeometryBatcher:SetBuildLayer(layer)
    self.buildLayer = layer
end

local NearFloorBfs

function ExactGeometryBatcher:Add(geometryKey, materialKey, transform)
    if not Geometry.GEO[geometryKey] then
        print("[ExactGeometry] missing GEO." .. tostring(geometryKey))
        return
    end
    -- Emissive color is a material uniform in UrhoX. Keep a small exact-color
    -- batch for glow geometry so the PBR emission matches Three.js instance color.
    local emissiveColor = materialKey == "glow" and (transform.color or 0xffffff) or nil
    local key = geometryKey .. "|" .. materialKey
        .. (emissiveColor and string.format("|%06x", emissiveColor) or "")
    local batch = self.batches[key]
    if not batch then
        batch = {
            geometryKey = geometryKey,
            materialKey = materialKey,
            emissiveColor = emissiveColor,
            instances = {},
        }
        self.batches[key] = batch
    end
    transform.sx = transform.sx or transform.scale or 1
    transform.sy = transform.sy or transform.scale or 1
    transform.sz = transform.sz or transform.scale or 1
    if self.activeBaseY and transform.scaleY ~= false then
        transform.y = self.activeBaseY + (transform.y - self.activeBaseY) * self.verticalScale
        transform.sy = transform.sy * self.verticalScale
    end
    transform.rx = transform.rx or 0
    transform.ry = transform.ry or transform.rot or 0
    transform.rz = transform.rz or 0
    if self.buildLayer then
        local gridX = math.floor(transform.x / GeometryRules.CELL_SIZE + self.dungeon.width * 0.5 - 0.5 + 0.5)
        local gridY = math.floor(transform.z / GeometryRules.CELL_SIZE + self.dungeon.height * 0.5 - 0.5 + 0.5)
        local distance = NearFloorBfs(self.buildLayer, gridX, gridY, self.dungeon.width, self.dungeon.height)
        transform.buildOrder = math.max(0, math.min(1, distance / math.max(1, self.buildLayer.maxBfs or 1)))
    else
        transform.buildOrder = 0.5
    end
    batch.instances[#batch.instances + 1] = transform
end

function ExactGeometryBatcher:GetEmissiveMaterial(color)
    local key = color or 0xffffff
    local material = self.emissiveMaterials[key]
    if not material then
        material = Bridge.EmissiveMaterial({
            color = 0xffffff,
            emissiveColor = key,
            emissiveStrength = 1.65,
            roughness = 0.32,
            metalness = 0.0,
            transparent = true,
            opacity = 0.94,
            side = 2,
        })
        self.emissiveMaterials[key] = material
    end
    return material
end

NearFloorBfs = function(layer, x, y, width, height)
    local nearest = math.huge
    for oy = -1, 1 do
        for ox = -1, 1 do
            local nx, ny = x + ox, y + oy
            if nx >= 0 and ny >= 0 and nx < width and ny < height then
                local value = layer.bfs[Index(nx, ny, width)] or -1
                if value >= 0 then nearest = math.min(nearest, value) end
            end
        end
    end
    return nearest == math.huge and 0 or nearest
end

local function IsDoorWallCut(layer, x, y, width, height)
    local c = Index(x, y, width)
    if layer.grid[c] ~= TILE_WALL then return false end
    local function IsDoor(nx, ny)
        return nx >= 0 and ny >= 0 and nx < width and ny < height
            and layer.doorway[Index(nx, ny, width)]
    end
    local function IsFloor(nx, ny)
        return nx >= 0 and ny >= 0 and nx < width and ny < height
            and layer.grid[Index(nx, ny, width)] == TILE_FLOOR
    end
    return (IsDoor(x - 1, y) and IsFloor(x + 1, y))
        or (IsDoor(x + 1, y) and IsFloor(x - 1, y))
        or (IsDoor(x, y - 1) and IsFloor(x, y + 1))
        or (IsDoor(x, y + 1) and IsFloor(x, y - 1))
end

function ExactGeometryBatcher:QueueStructure(layer, floorSpacing)
    local width, height = self.dungeon.width, self.dungeon.height
    local structure = self.pack and self.pack.structure or nil
    local rng = Random.new((self.dungeon.seed ~ 0x9e3779b9) + layer.floor * 0x45d9f3b)
    local mossMask = {}
    for _, prop in ipairs(layer.props) do
        if prop.kind == "moss" then mossMask[Index(prop.x, prop.y, width)] = true end
    end

    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local c = Index(x, y, width)
            local tile = layer.grid[c]
            local worldX, baseY, worldZ = self:WorldPosition(x, y, layer.floor, floorSpacing, 0)
            self.activeBaseY = baseY
            if layer.lakeMask and layer.lakeMask[c] then
                local lakeColor = self.theme.pools and self.theme.pools.colB or 0xbfe4ff
                self:Add("floorSeal", self.hospital and "hospitalFloor" or (self.school and "schoolFloor" or "stone"), {
                    x=worldX, y=baseY+GeometryRules.SUBMERGED_SEAL_OFFSET, z=worldZ,
                    color=MultiplyColor(lakeColor, GeometryRules.FLOOR_SEAL_COLOR_FACTOR),
                })
                self:Add("liquidCell", "ice", {x=worldX,y=baseY-0.12,z=worldZ,color=lakeColor,alpha=0.88})
            elseif tile == 3 then
                local poolColor = self.theme.pools and self.theme.pools.colB or self.theme.accentObject
                self:Add("floorSeal", self.hospital and "hospitalFloor" or (self.school and "schoolFloor" or "floor"), {
                    x=worldX, y=baseY+GeometryRules.SUBMERGED_SEAL_OFFSET, z=worldZ,
                    color=MultiplyColor(poolColor, GeometryRules.FLOOR_SEAL_COLOR_FACTOR),
                })
                self:Add("basin", "stone", {x=worldX,y=baseY,z=worldZ,color=LerpColor(self.theme.wall,0x000000,0.35)})
                self:Add("liquidCell", "glow", {x=worldX,y=baseY-0.08,z=worldZ,color=poolColor,alpha=0.88})
            end
            if tile == TILE_FLOOR and not layer.stairMask[c] and not layer.slabOpening[c]
                and not (layer.lakeMask and layer.lakeMask[c]) then
                local walls8 = 0
                for oy = -1, 1 do
                    for ox = -1, 1 do
                        if ox ~= 0 or oy ~= 0 then
                            local nx, ny = x + ox, y + oy
                            if nx < 0 or ny < 0 or nx >= width or ny >= height
                                or layer.grid[Index(nx, ny, width)] == TILE_WALL then
                                walls8 = walls8 + 1
                            end
                        end
                    end
                end
                local rid = layer.roomId[c] or 0
                local room = rid > 0 and self.dungeon.rooms[rid] or nil
                local color
                if self.hospital then
                    color = layer.corridor[c] and 0x93aaa5 or 0xb4c1bb
                    if room and room.type == "boss" then color = LerpColor(color, 0xcbd8d2, 0.12) end
                    if room and room.type == "entrance" then color = LerpColor(color, 0xa8bbb4, 0.10) end
                    if layer.doorway[c] then color = LerpColor(color, 0xc5d3cd, 0.12) end
                    if rng:Chance(0.02) then color = LerpColor(color, 0x7b8783, 0.12) end
                elseif self.school then
                    color = layer.corridor[c] and self.theme.corridor or self.theme.floor
                    if room and room.type == "entrance" then color = LerpColor(color, 0xc4d1c9, 0.10) end
                    if room and room.type == "treasure" then color = LerpColor(color, 0xb09b78, 0.10) end
                    if layer.doorway[c] then color = LerpColor(color, 0xd0d1c3, 0.08) end
                else
                    color = layer.corridor[c] and self.theme.corridor or self.theme.floor
                    if room and room.type ~= "combat" then color = LerpColor(color, ROOM_TINT[room.type] or color, 0.17) end
                    if layer.doorway[c] then color = MultiplyColor(color, 1.14) end
                    if mossMask[c] then color = LerpColor(color, 0x4c7a42, 0.32) end
                    color = MultiplyColor(color, 1 - 0.11 * math.min(walls8, 4))
                end
                if ((x + y) & 1) ~= 0 then color = MultiplyColor(color, 0.965) end
                color = MultiplyColor(color, rng:Float(0.94, 1.06))
                local floorGeometry = structure and structure.floorGeometry
                    or (self.hospital and "hospitalFloor" or "floor")
                local floorMaterial = structure and structure.floorMaterial
                    or (self.hospital and "hospitalFloor" or "floor")
                self:Add("floorSeal", floorMaterial, {
                    x = worldX, y = baseY, z = worldZ,
                    color = MultiplyColor(color, GeometryRules.FLOOR_SEAL_COLOR_FACTOR),
                })
                self:Add(floorGeometry, floorMaterial, {
                        x = worldX,
                        y = baseY + rng:Float(GeometryRules.FLOOR_Y_JITTER_MIN, GeometryRules.FLOOR_Y_JITTER_MAX),
                        z = worldZ, color = color,
                    })
            elseif tile == TILE_WALL and not IsDoorWallCut(layer, x, y, width, height) then
                local wallHeight = structure
                    and (structure.wallHeight
                        + rng:Float(-structure.wallHeightVariation, structure.wallHeightVariation))
                    or (self.hospital
                    and (GeometryRules.HOSPITAL_WALL_HEIGHT
                        + rng:Float(-GeometryRules.HOSPITAL_WALL_HEIGHT_VARIATION,
                            GeometryRules.HOSPITAL_WALL_HEIGHT_VARIATION))
                    or (GeometryRules.DUNGEON_WALL_HEIGHT
                        + rng:Float(-GeometryRules.DUNGEON_WALL_HEIGHT_VARIATION,
                            GeometryRules.DUNGEON_WALL_HEIGHT_VARIATION)))
                local wallColor = self.hospital and MultiplyColor(0xaebdb8, rng:Float(0.99, 1.02))
                    or (self.school and MultiplyColor(self.theme.wall, rng:Float(0.98, 1.02)))
                    or MultiplyColor(self.theme.wall, rng:Float(0.90, 1.08))
                local capColor = self.hospital and MultiplyColor(0xb8c4bf, rng:Float(0.995, 1.02))
                    or (self.school and MultiplyColor(self.theme.cap, rng:Float(0.99, 1.02)))
                    or MultiplyColor(self.theme.cap, rng:Float(0.92, 1.10))
                local wallMaterial = structure and structure.wallMaterial
                    or (self.hospital and "hospitalWall" or "wall")
                local wallGeometry = structure and structure.wallGeometry
                    or (self.hospital and "hospitalWall" or "wall")
                local capGeometry = structure and structure.capGeometry
                    or (self.hospital and "hospitalWallCap" or "wallCap")
                local capMaterial = structure and structure.capMaterial
                    or (self.hospital and "hospitalTrim" or "cap")
                self:Add("wallFootSeal", wallMaterial, {
                    x = worldX, y = baseY, z = worldZ, color = wallColor,
                })
                self:Add(wallGeometry, wallMaterial, {
                        x = worldX,
                        y = baseY - GeometryRules.WALL_FLOOR_VERTICAL_OVERLAP,
                        z = worldZ,
                        sy = wallHeight + GeometryRules.WALL_FLOOR_VERTICAL_OVERLAP,
                        color = wallColor,
                    })
                self:Add(capGeometry, capMaterial, {
                        x = worldX, y = baseY + wallHeight, z = worldZ, color = capColor,
                    })
            end
        end
    end
    self.activeBaseY = nil
end

local PROP_SPEC = {
    hospitalBed = { "hospitalBed", "hospitalWall", 0xb7c3be },
    ivStand = { "ivStand", "hospitalTrim", 0x9aa8a4 },
    medCabinet = { "medCabinet", "hospitalWall", 0xb2beb9 },
    receptionDesk = { "receptionDesk", "hospitalWall", 0xb9c4bf },
    nurseCounter = { "nurseCounter", "hospitalWall", 0xb6c5c0 },
    doctorDesk = { "doctorDesk", "hospitalWall", 0xb9b8aa },
    examTable = { "examTable", "hospitalWall", 0xb8c5bf },
    waitingBench = { "waitingBench", "hospitalWall", 0x7d8a86 },
    medCart = { "medCart", "hospitalTrim", 0xa8b7b2 },
    monitor = { "monitor", "hospitalTrim", 0x1f2f31 },
    privacyCurtain = { "privacyCurtain", "cloth", 0xb4c7c1 },
    surgicalLamp = { "surgicalLamp", "hospitalTrim", 0xc5d7d1 },
    mriScanner = { "mriScanner", "hospitalWall", 0xc7d4d0 },
    oxygenTank = { "oxygenTank", "hospitalTrim", 0x8fd3cf },
    bioBin = { "bioBin", "hospitalWall", 0xd8a12d },
    gurney = { "gurney", "hospitalTrim", 0xc5d1cc },
    floorCross = { "floorCross", "glow", 0xff3b35 },
    floorStripe = { "floorStripe", "glow", 0x5fd1c7 },
    cleanZone = { "cleanZone", "glow", 0x5fd1c7 },
    floorArrow = { "floorArrow", "glow", 0x5fd1c7 },
    surgeryTable = { "surgeryTable", "hospitalWall", 0xcfd8d4 },
    pillar = { "pillar", "stone" }, debris = { "debrisA", "stone" },
    grave = { "grave", "stone" }, sarco = { "sarco", "stone" },
    candle = { "candle", "stone", 0xd8cba8 },
    icicle = { "icicle", "ice", 0xbfe2ff }, shardIce = { "shard", "ice", 0xcfeaff },
    roots = { "roots", "bark", 0x5a4632 }, moss = { "moss", "moss" },
    crack = { "crack", "glow" }, bones = { "bone", "stone", 0xcfc4a4 },
}

local WALL_PROPS = {
    wallLight = { "wallLight", "glow", 0xb7d8d1, 1.65 },
    wallChart = { "wallChart", "hospitalWall", 0xb8c6bf, 1.42 },
    noticeBoard = { "noticeBoard", "hospitalWall", 0xb9a97b, 1.38 },
    clock = { "clock", "hospitalTrim", 0xc0cbc5, 1.64 },
    wallPanel = { "wallPanel", "stone", 0xb8c7c0, 1.20 },
    hospitalSign = { "hospitalSign", "glow", 0xff3b35, 1.50 },
}

function ExactGeometryBatcher:QueueProp(layer, prop, floorSpacing, rng)
    local x, baseY, z = self:WorldPosition(prop.x, prop.y, layer.floor, floorSpacing, 0)
    self.activeBaseY = baseY
    if prop.kind == "entrance" then prop = { kind="ring", x=prop.x, y=prop.y, rot=prop.rot, scale=prop.scale } end
    if prop.kind == "shrine" then prop = { kind="shrineCrystal", x=prop.x, y=prop.y, rot=prop.rot, scale=prop.scale } end
    local scale, rot = prop.scale or 1, prop.rot or 0
    local packSpec = self.pack and self.pack.props[prop.kind]
    if packSpec then
        if packSpec.mount == "wall" then
            local dx, dy = prop.dx or 0, prop.dy or 1
            self:Add(packSpec.geometry, packSpec.material, {
                x = x + dx * 0.54, y = baseY + (packSpec.height or 1.5), z = z + dy * 0.54,
                scale = scale, ry = math.atan(dx, dy), color = packSpec.color,
            })
        else
            self:Add(packSpec.geometry, packSpec.material, {
                x = x, y = baseY, z = z, scale = scale, ry = rot, color = packSpec.color,
            })
        end
        return packSpec.emitsLight == true
    end
    local wall = WALL_PROPS[prop.kind]
    if wall then
        local dx, dy = prop.dx or 0, prop.dy or 1
        self:Add(wall[1], wall[2], { x = x + dx * 0.54, y = baseY + wall[4], z = z + dy * 0.54,
            scale = scale, ry = math.atan(dx, dy), color = wall[3] })
        return wall[1] == "wallLight"
    end

    local spec = PROP_SPEC[prop.kind]
    if spec then
        local geometryKey = spec[1]
        if prop.kind == "debris" then geometryKey = ({ "debrisA", "debrisB", "debrisC" })[(prop.v or 0) + 1] end
        local color = spec[3] or self.theme.pillar
        if prop.kind == "debris" then
            local colors = self.theme.debris or { self.theme.wall, self.theme.pillar }
            color = LerpColor(colors[1], colors[2], rng:Raw())
        elseif prop.kind == "moss" then color = LerpColor(0x3f6b3a, 0x5a8a4a, rng:Raw())
        elseif prop.kind == "crack" then color = prop.ice and 0x9fd8ff or 0xff6a28 end
        if prop.kind == "pillar" then scale = scale * 1.15; rot = rng:Int(0, 3) * math.pi * 0.5 end
        self:Add(geometryKey, spec[2], { x = x, y = baseY, z = z, scale = scale, ry = rot, color = color })

        if prop.kind == "hospitalBed" then
            self:Add("bannerCloth", "cloth", { x=x, y=baseY+0.6, z=z, sx=scale*1.08, sy=scale*0.66, sz=scale, ry=rot, color=0xc0cec7 })
        elseif prop.kind == "examTable" then
            self:Add("bannerCloth", "cloth", { x=x, y=baseY+0.7, z=z, sx=scale*0.8, sy=scale*0.42, sz=scale, ry=rot, color=0xc4d2cb })
        elseif prop.kind == "gurney" then
            self:Add("bannerCloth", "cloth", { x=x, y=baseY+0.75, z=z, sx=scale*1.2, sy=scale*0.45, sz=scale, ry=rot, color=0xc0d0c8 })
        elseif prop.kind == "surgeryTable" then
            self:Add("bannerCloth", "cloth", { x=x, y=baseY+0.9, z=z, sx=scale*1.2, sy=scale*0.55, sz=scale, ry=rot, color=0xc5d8cf })
        elseif prop.kind == "medCabinet" then
            self:Add("emblem","glow",{x=x,y=baseY+1.02*scale,z=z+0.25*math.cos(rot),scale=scale*0.9,ry=rot,color=0xd96a62})
        elseif prop.kind == "receptionDesk" then
            self:Add("emblem","glow",{x=x,y=baseY+0.96*scale,z=z+0.31*math.cos(rot),scale=scale*0.95,ry=rot,color=0x7db8b0})
        elseif prop.kind == "nurseCounter" then
            self:Add("emblem","glow",{x=x,y=baseY+0.78*scale,z=z+0.30*math.cos(rot),scale=scale*0.9,ry=rot,color=0x7db8b0})
        elseif prop.kind == "doctorDesk" then
            self:Add("emblem","glow",{x=x+0.2*math.sin(rot),y=baseY+0.66*scale,z=z+0.18*math.cos(rot),scale=scale*0.65,ry=rot,color=0x30414a})
        elseif prop.kind == "monitor" then
            self:Add("emblem","glow",{x=x,y=baseY+0.84*scale,z=z+0.04,scale=scale*1.1,ry=rot,color=0x58c8bf})
        elseif prop.kind == "surgicalLamp" then
            self:Add("emblem","glow",{x=x+0.68*scale,y=baseY+1.08*scale,z=z,scale=scale*1.6,ry=rot,color=0xc8ddd4})
        elseif prop.kind == "mriScanner" then
            self:Add("emblem","glow",{x=x,y=baseY+0.78*scale,z=z+0.48*math.cos(rot),scale=scale*1.3,ry=rot,color=0x58c8bf})
        elseif prop.kind == "bioBin" then
            self:Add("emblem","glow",{x=x,y=baseY+0.60*scale,z=z+0.25,scale=scale*1.1,ry=rot,color=0x1f1a12})
        elseif prop.kind == "candle" then
            self:Add("flameCore", "glow", { x=x, y=baseY+0.19*scale, z=z, scale=0.55, color=self.theme.flameCore })
        end
        return false
    end

    if prop.kind == "chest" then
        self:Add("chestBody", "stone", { x=x,y=baseY,z=z,ry=rot,color=0x8a5a2c })
        self:Add("chestTrim", "trim", { x=x,y=baseY,z=z,ry=rot,color=0xc8a24a })
        self:Add("chestSeam", "glow", { x=x,y=baseY,z=z,ry=rot,color=0xffd27a })
    elseif prop.kind == "shrineCrystal" then
        self:Add("plinth", "stone", { x=x,y=baseY,z=z,ry=rot,color=LerpColor(self.theme.pillar,0xffffff,0.12) })
        self:Add("crystal", "glow", { x=x,y=baseY+1.4,z=z,scale=1.05,ry=rot,color=0x8fbcff })
        for k = 0, 3 do
            local angle = k * math.pi * 0.5 + math.pi * 0.25
            local cx, cz = x + math.cos(angle) * 0.36, z + math.sin(angle) * 0.36
            self:Add("candle", "stone", { x=cx,y=baseY+0.5,z=cz,scale=0.8,color=0xd8cba8 })
            self:Add("flameCore", "glow", { x=cx,y=baseY+0.65,z=cz,scale=0.5,color=self.theme.flameCore })
        end
    elseif prop.kind == "ring" then
        self:Add("platform", "stone", { x=x,y=baseY-0.02,z=z,color=LerpColor(self.theme.floor,0xffffff,0.1) })
        self:Add("ring", "glow", { x=x,y=baseY+0.16,z=z,color=0x3fd0bb })
        self:Add("pillar", "stone", { x=x-1.45,y=baseY+0.1,z=z,scale=0.72,color=self.theme.pillar })
        self:Add("pillar", "stone", { x=x+1.45,y=baseY+0.1,z=z,scale=0.72,color=self.theme.pillar })
        self:Add("portal", "glow", { x=x,y=baseY+0.12,z=z,color=0x3fd0bb,alpha=0.75 })
    elseif prop.kind == "bossCrystal" then
        self:Add("bossShard", "glow", { x=x,y=baseY,z=z,scale=1.15,ry=rot,color=0xff4636 })
        self:Add("bossShard", "glow", { x=x+0.55,y=baseY,z=z-0.42,sx=0.6,sy=0.75,sz=0.6,ry=rot+1.2,color=0xff6a45 })
        local rocks = {{-0.62,0.42,0.75,0.8,2.1,0x4a3336},{0.75,0.55,0.55,0.6,3.6,0x51383a},{-0.5,-0.62,0.5,0.55,4.9,0x452f31}}
        for _, rock in ipairs(rocks) do self:Add("bossShard", "stone", {x=x+rock[1],y=baseY,z=z+rock[2],sx=rock[3],sy=rock[4],sz=rock[3],ry=rot+rock[5],color=rock[6]}) end
    elseif prop.kind == "brazier" then
        self:Add("brazier", "trim", {x=x,y=baseY,z=z,ry=rng:Float(0,math.pi*2),color=0x3a3f4a})
        self:Add("coals", "glow", {x=x,y=baseY,z=z,color=0xff7a30})
        self:Add("flame", "glow", {x=x,y=baseY+0.62,z=z,scale=1.35,color=self.theme.flame})
        self:Add("flameCore", "glow", {x=x,y=baseY+0.66,z=z,scale=1.3,color=self.theme.flameCore})
        return true
    elseif prop.kind == "banner" then
        local dx, dy = prop.dx or 0, prop.dy or 1
        local bx, bz, ry = x + dx * 0.54, z + dy * 0.54, math.atan(dx, dy)
        self:Add("bannerRod","trim",{x=bx,y=baseY+1.98,z=bz,ry=ry,color=0x6a5a3a})
        self:Add("bannerCloth","cloth",{x=bx+dx*0.03,y=baseY+1.96,z=bz+dy*0.03,ry=ry,color=self.theme.cloth})
        self:Add("emblem","glow",{x=bx+dx*0.06,y=baseY+1.6,z=bz+dy*0.06,ry=ry,color=self.theme.accentObject})
    end
    return false
end

function ExactGeometryBatcher:QueueTorch(layer, torch, floorSpacing)
    local x, baseY, z = self:WorldPosition(torch.x, torch.y, layer.floor, floorSpacing, 0)
    self.activeBaseY = baseY
    local dx, dy = torch.dx or 0, torch.dy or 1
    local mountX, mountZ, ry = x + dx * 0.5, z + dy * 0.5, math.atan(dx, dy)
    self:Add("torch", "trim", { x=mountX,y=baseY+1.02,z=mountZ,ry=ry,color=0x4a4038 })
    self:Add("flame", "glow", { x=mountX+dx*0.16,y=baseY+1.5,z=mountZ+dy*0.16,scale=1.2,color=self.theme.flame })
    self:Add("flameCore", "glow", { x=mountX+dx*0.16,y=baseY+1.53,z=mountZ+dy*0.16,scale=1.2,color=self.theme.flameCore })
    return mountX + dx * 0.16, baseY + 1.53 * self.verticalScale, mountZ + dy * 0.16
end

function ExactGeometryBatcher:QueueSpawn(layer, spawn, floorSpacing, rng)
    local x, baseY, z = self:WorldPosition(spawn.x, spawn.y, layer.floor, floorSpacing, 0)
    self.activeBaseY = baseY
    local tier, rot = math.max(1, math.min(3, spawn.tier or 1)), rng:Float(0, math.pi * 2)
    local spawnVisual = self.pack and self.pack.spawnVisual
    if spawnVisual then
        self:Add(spawnVisual.geometry, spawnVisual.material, {
            x = x,
            y = baseY,
            z = z,
            ry = rot,
            scale = (spawnVisual.scales and spawnVisual.scales[tier]) or 1.0,
            color = (spawnVisual.colors and spawnVisual.colors[tier]) or 0xffffff,
        })
        return
    end
    self:Add("spawn" .. tier, "stone", {x=x,y=baseY,z=z,ry=rot,color=tier==1 and 0x5f4b45 or (tier==2 and 0x5a4348 or 0x4c4258)})
    if tier == 1 then self:Add("band2","glow",{x=x,y=baseY+0.14,z=z,scale=0.7,ry=rot,color=0xb03a2a})
    elseif tier == 2 then self:Add("band2","glow",{x=x,y=baseY+0.55,z=z,ry=rot,color=0xd8433a})
    else
        self:Add("band3","glow",{x=x,y=baseY+0.62,z=z,ry=rot,color=0x9b6cf0})
        self:Add("crystal","glow",{x=x,y=baseY+1.98,z=z,scale=0.42,ry=rot,color=0xb794ff})
    end
end

function ExactGeometryBatcher:QueueArch(layer, arch, floorSpacing)
    local x, baseY, z = self:WorldPosition(arch.x, arch.y, layer.floor, floorSpacing, 0)
    self.activeBaseY = baseY
    local side = arch.side or "east"
    local horizontal = side == "north" or side == "south" or side == "n" or side == "s"
    local half = (arch.len or 2) * 0.5 + 0.15
    local structure = self.pack and self.pack.structure or nil
    local color = self.hospital and LerpColor(self.theme.wall, 0xe8f3ef, 0.35)
        or (structure and LerpColor(self.theme.wall, 0xffffff, 0.08))
        or LerpColor(self.theme.wall, 0xffffff, 0.12)
    local post = structure and structure.doorPostGeometry
        or (self.hospital and "hospitalDoorPost" or "archPost")
    local lintel = structure and structure.doorLintelGeometry
        or (self.hospital and "hospitalDoorLintel" or "archLintel")
    local material = structure and structure.doorMaterial
        or (self.hospital and "hospitalWall" or "stone")
    local openingWidth = (arch.len or 2) + 0.46
    local lintelBase = structure and structure.doorLintelBase
        or GeometryRules.DoorLintelBase(self.hospital)
    if horizontal then
        self:Add(post, material, {x=x-half,y=baseY,z=z,color=color})
        self:Add(post, material, {x=x+half,y=baseY,z=z,color=color})
        self:Add(lintel, material, {x=x,y=baseY+lintelBase,z=z,sx=openingWidth,color=color})
    else
        self:Add(post, material, {x=x,y=baseY,z=z-half,color=color})
        self:Add(post, material, {x=x,y=baseY,z=z+half,color=color})
        self:Add(lintel, material, {x=x,y=baseY+lintelBase,z=z,sx=openingWidth,ry=math.pi*0.5,color=color})
    end
end

local FLOOR_BUILD = {
    floor = true, hospitalFloor = true, schoolFloor = true, floorSeal = true,
}

local WALL_BUILD = {
    wall = true, hospitalWall = true, schoolWall = true, wallFootSeal = true,
    archPost = true, hospitalDoorPost = true, schoolDoorPost = true,
}

local CAP_BUILD = {
    wallCap = true, hospitalWallCap = true, schoolWallCap = true,
    archLintel = true, hospitalDoorLintel = true, schoolDoorLintel = true,
}

local ATMOSPHERE_BUILD = {
    flame = true, flameCore = true, coals = true, chestSeam = true,
    emblem = true, band2 = true, band3 = true, crystal = true, ring = true,
    bossGlow = true, wallLight = true, hospitalSign = true, deptSign = true,
    floorCross = true, floorStripe = true, cleanZone = true, floorArrow = true,
    liquidCell = true, portal = true,
}

local function AverageBuildOrder(instances)
    if #instances == 0 then return 0 end
    local total = 0
    for _, instance in ipairs(instances) do total = total + (instance.buildOrder or 0) end
    return total / #instances
end

local function BuildShowTime(geometryKey, timeline, instances)
    local stage, offset, spread
    if FLOOR_BUILD[geometryKey] then
        stage, offset, spread = timeline.structure, 0.02, 0.20
    elseif WALL_BUILD[geometryKey] then
        stage = timeline.structure
        offset = geometryKey:find("Post", 1, true) and 0.30 or 0.15
        spread = 0.20
    elseif CAP_BUILD[geometryKey] then
        stage, offset, spread = timeline.structure, 0.32, 0.16
    elseif ATMOSPHERE_BUILD[geometryKey] then
        stage, offset, spread = timeline.atmosphere, 0.02, 0.18
    else
        stage, offset, spread = timeline.rooms, 0.02, 0.26
    end
    local timeScale = timeline.timeScale or 1
    offset, spread = offset * timeScale, spread * timeScale
    local order = AverageBuildOrder(instances)
    return math.min(stage.finish - 0.04 * timeScale, stage.start + offset + order * spread)
end

function ExactGeometryBatcher:Flush(parent, stagingConfig)
    local keys = {}
    for key in pairs(self.batches) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local batch = self.batches[key]
        local material = batch.materialKey == "glow"
            and self:GetEmissiveMaterial(batch.emissiveColor)
            or self.materials[batch.materialKey]
        local showTime = nil
        if stagingConfig then
            showTime = BuildShowTime(batch.geometryKey, stagingConfig.timeline, batch.instances)
        end
        local components, count = Bridge.BuildColoredBatch(parent, "Exact-" .. batch.geometryKey,
            Geometry.GEO[batch.geometryKey], batch.instances, material, true)
        if showTime then
            for _, component in ipairs(components) do
                component.enabled = false
                self.stagedEntries[#self.stagedEntries + 1] = {
                    object = component, showTime = showTime, shown = false,
                }
            end
        end
        self.instanceCount = self.instanceCount + count
        self.batchCount = self.batchCount + 1
    end
    return self.instanceCount, self.batchCount, self.stagedEntries
end

return ExactGeometryBatcher
