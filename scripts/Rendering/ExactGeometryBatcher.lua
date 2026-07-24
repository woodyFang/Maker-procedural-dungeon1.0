local Random = require("Generation.Random")
local MultiFloor = require("Generation.MultiFloor")
local GeometryRules = require("Generation.GeometryRules")
local Geometry = require("Rendering.DungeonGeometryLibrary")
local Bridge = require("Rendering.GeometryBridge")
local MaterialRules = require("Rendering.ProceduralMaterialRules")
local ThemeToneRules = require("Rendering.ThemeToneRules")
local ThemePacks = require("Config.ThemePacks")
local EnvironmentProfiles = require("Config.EnvironmentProfiles")

local materialRulesValid, materialRulesError = MaterialRules.Validate()
assert(materialRulesValid, materialRulesError)
local toneRulesValid, toneRulesError = ThemeToneRules.Validate()
assert(toneRulesValid, toneRulesError)

local ExactGeometryBatcher = {}
ExactGeometryBatcher.__index = ExactGeometryBatcher

local TILE_FLOOR = 1
local TILE_WALL = 2

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
        templeFloor = Bridge.Material(profiles.templeFloor),
        templeWall = Bridge.Material(profiles.templeWall),
        templeCap = Bridge.Material(profiles.templeCap),
        gild = Bridge.Material(profiles.gild),
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
    local profile = EnvironmentProfiles.Resolve(settingKey)
    local structureKit = (pack and pack.structure) or profile.structure
    return setmetatable({
        dungeon = dungeon,
        theme = theme,
        settingKey = settingKey,
        pack = pack,
        profile = profile,
        -- Flame style comes with the structure kit: the temple burns arcane
        -- orbs where the ruins burn cone flames.
        flameGeo = structureKit and structureKit.flameGeometry or "flame",
        flameCoreGeo = structureKit and structureKit.flameCoreGeometry or "flameCore",
        -- Props listed here keep only their static base in the merged batches;
        -- the AtmosphereFX layer owns the moving part (spinning gate rings,
        -- floating shrine crystal). Empty for settings without an atmosphere.
        animatedProps = profile.atmosphere and profile.atmosphere.animatedProps or {},
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
        local emissiveScale = self.theme.fx and self.theme.fx.emissiveScale or 1.0
        material = Bridge.EmissiveMaterial({
            color = 0xffffff,
            emissiveColor = key,
            emissiveStrength = 1.65 * emissiveScale,
            roughness = 0.32,
            metalness = 0.0,
            transparent = true,
            opacity = 0.86,
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

local FOUR_DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function IsDoorAdjacent(layer, x, y, width, height)
    for _, direction in ipairs(FOUR_DIRECTIONS) do
        local nx, ny = x + direction[1], y + direction[2]
        if nx >= 0 and ny >= 0 and nx < width and ny < height
            and layer.doorway[Index(nx, ny, width)] then
            return true
        end
    end
    return false
end

function ExactGeometryBatcher:QueueStructure(layer, floorSpacing)
    local width, height = self.dungeon.width, self.dungeon.height
    -- Structure kits come from a ThemePack, or (for built-in settings without
    -- a pack, e.g. 神殿遗迹) from the environment profile as plain data.
    local structure = (self.pack and self.pack.structure) or self.profile.structure
    local rng = Random.new((self.dungeon.seed ~ 0x9e3779b9) + layer.floor * 0x45d9f3b)
    local tone = ThemeToneRules.Resolve(self.settingKey)
    local mossMask = {}
    -- Wall cells carrying a mounted fixture (torch, banner, icicle, roots…)
    -- must keep their full height, otherwise the fixture floats over a stub.
    local mountedWallMask = {}
    for _, torch in ipairs(layer.torches) do
        mountedWallMask[Index(torch.x, torch.y, width)] = true
    end
    for _, prop in ipairs(layer.props) do
        if prop.kind == "moss" then mossMask[Index(prop.x, prop.y, width)] = true end
        if prop.dx or prop.dy then mountedWallMask[Index(prop.x, prop.y, width)] = true end
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
                local color = ThemeToneRules.ResolveFloorColor(self.theme, tone, {
                    corridor = layer.corridor[c], room = room, walls8 = walls8,
                    isDoorway = layer.doorway[c], checker = ((x + y) & 1) ~= 0,
                    surfaceTint = mossMask[c] and tone.surfaceTint,
                    rng = rng,
                })
                local floorGeometry = structure and structure.floorGeometry
                    or (self.hospital and "hospitalFloor" or "floor")
                local floorMaterial = structure and structure.floorMaterial
                    or (self.hospital and "hospitalFloor" or "floor")
                -- Paving accents: a kit may swap in a relief slab on a fixed
                -- lattice (processional rosettes), and lay a faint glowing
                -- rune inlay inside rooms only — both pure data.
                if structure and structure.floorAccentGeometry then
                    local every = structure.floorAccentEvery or 2
                    if x % every == 0 and y % every == 0 then
                        floorGeometry = structure.floorAccentGeometry
                    end
                end
                self:Add("floorSeal", floorMaterial, {
                    x = worldX, y = baseY, z = worldZ,
                    color = MultiplyColor(color, GeometryRules.FLOOR_SEAL_COLOR_FACTOR),
                })
                self:Add(floorGeometry, floorMaterial, {
                        x = worldX,
                        y = baseY + rng:Float(GeometryRules.FLOOR_Y_JITTER_MIN, GeometryRules.FLOOR_Y_JITTER_MAX),
                        z = worldZ, color = color,
                    })
                local inlay = structure and structure.floorInlay
                if inlay and rid > 0 and not layer.corridor[c]
                    and x % (inlay.every or 3) == 1 and y % (inlay.every or 3) == 1 then
                    self:Add(inlay.geometry, "glow", {
                        x = worldX, y = baseY, z = worldZ,
                        color = LerpColor(self:FxColor(inlay.colorField or "runeColor"),
                            0x000000, inlay.dim or 0.45),
                    })
                end
            elseif tile == TILE_WALL and not IsDoorWallCut(layer, x, y, width, height) then
                -- Double-height stair walls span two storeys as one seamless wall.
                -- The tall wall is drawn from the lower floor; the upper floor's
                -- matching cell is skipped so it does not duplicate/overlap.
                local doubleMask = layer.stairWallMask and layer.stairWallMask[c] == "double-height"
                local belowLayer = doubleMask and self.dungeon.layers[layer.floor] or nil
                local skipDoubleUpper = (doubleMask and belowLayer and belowLayer.stairWallMask
                    and belowLayer.stairWallMask[c] == "double-height") and true or false
                local doubleExtra = (doubleMask and not skipDoubleUpper)
                    and (MultiFloor.SOURCE_FLOOR_HEIGHT * floorSpacing) or 0
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
                local wallColor = ThemeToneRules.ResolveWallColor(self.theme, tone, rng)
                local capColor = ThemeToneRules.ResolveCapColor(self.theme, tone, rng)
                local wallMaterial = structure and structure.wallMaterial
                    or (self.hospital and "hospitalWall" or "wall")
                local wallGeometry = structure and structure.wallGeometry
                    or (self.hospital and "hospitalWall" or "wall")
                -- Curtain-and-pier rhythm: (x + y) % N == 0 lands an engaged
                -- column at an even interval along any straight wall run,
                -- horizontal or vertical, with brick panels in between.
                if structure and structure.wallAccentGeometry
                    and (x + y) % (structure.wallAccentEvery or 3) == 0 then
                    wallGeometry = structure.wallAccentGeometry
                    wallColor = MultiplyColor(wallColor, structure.wallAccentGain or 1.0)
                end
                local capGeometry = structure and structure.capGeometry
                    or (self.hospital and "hospitalWallCap" or "wallCap")
                local capMaterial = structure and structure.capMaterial
                    or (self.hospital and "hospitalTrim" or "cap")
                -- Structural weathering: a small fraction of plain walls
                -- collapse to a stub with rubble on the break. Stair walls,
                -- doorway frames and fixture-bearing cells always stay whole.
                local ruin = self.profile.structureRuin
                local ruinFactor = nil
                if ruin and not doubleMask and not mountedWallMask[c]
                    and not (layer.stairWallMask and layer.stairWallMask[c])
                    and rng:Chance(ruin.brokenWallChance or 0)
                    and not IsDoorAdjacent(layer, x, y, width, height) then
                    ruinFactor = rng:Float(ruin.heightMin or 0.32, ruin.heightMax or 0.60)
                    wallHeight = wallHeight * ruinFactor
                end
                if not skipDoubleUpper then
                    self:Add("wallFootSeal", wallMaterial, {
                        x = worldX, y = baseY, z = worldZ, color = wallColor,
                    })
                    self:Add(wallGeometry, wallMaterial, {
                            x = worldX,
                            y = baseY - GeometryRules.WALL_FLOOR_VERTICAL_OVERLAP,
                            z = worldZ,
                            sy = wallHeight + doubleExtra + GeometryRules.WALL_FLOOR_VERTICAL_OVERLAP,
                            color = wallColor,
                        })
                    if ruinFactor then
                        if rng:Chance(ruin.rubbleChance or 0.7) then
                            self:Add("debrisB", "stone", {
                                x = worldX, y = baseY + wallHeight, z = worldZ,
                                scale = rng:Float(0.9, 1.4), ry = rng:Float(0, math.pi * 2),
                                color = MultiplyColor(wallColor, 0.82),
                            })
                        end
                    else
                        self:Add(capGeometry, capMaterial, {
                                x = worldX, y = baseY + wallHeight + doubleExtra, z = worldZ, color = capColor,
                            })
                    end
                end
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
    brokenPillar = { "brokenPillar", "stone" }, archRuin = { "archRuin", "stone" },
    templeUrn = { "templeUrn", "stone", 0x9a8668 },
    goldPile = { "goldPile", "gild", 0xe8c46a },
    -- Waymarks are readable by shape and gilt metal; they are intentionally
    -- not emissive so the corridor does not become a runway of lights.
    pathRune = { "pathRune", "gild" },
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

-- Palette FX colors with a stable fallback so packs/custom palettes without an
-- fx block still render the new ruins props.
function ExactGeometryBatcher:FxColor(field, fallback)
    local fx = self.theme.fx
    local value = fx and fx[field]
    if type(value) == "number" then return value end
    return fallback or self.theme.accentObject
end

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
        -- Per-kind style swaps from the environment profile (神殿遗迹 fluted
        -- columns etc.) — geometry and color only, placement stays shared.
        local style = self.profile.propStyle and self.profile.propStyle[prop.kind]
        if style and style.geometry then geometryKey = style.geometry end
        local color = (style and style.color) or spec[3] or self.theme.pillar
        if prop.kind == "debris" then
            local colors = self.theme.debris or { self.theme.wall, self.theme.pillar }
            color = LerpColor(colors[1], colors[2], rng:Raw())
        elseif prop.kind == "moss" then color = LerpColor(0x3f6b3a, 0x5a8a4a, rng:Raw())
        elseif prop.kind == "crack" then
            -- Pool-edge cracks glow with the liquid seeping below them, so a
            -- grim pool leaks ghost green while a molten pool leaks lava.
            color = prop.ice and 0x9fd8ff
                or (self.theme.pools and LerpColor(self.theme.pools.colB, 0xffffff, 0.30) or 0xff6a28)
        elseif prop.kind == "pathRune" then
            color = LerpColor(self:FxColor("runeColor"), 0x000000, 0.30)
        end
        if prop.kind == "pillar" then scale = scale * 1.15; rot = rng:Int(0, 3) * math.pi * 0.5 end
        self:Add(geometryKey, spec[2], { x = x, y = baseY, z = z, scale = scale, ry = rot, color = color })
        if style and style.trimGeometry then
            self:Add(style.trimGeometry, style.trimMaterial or "gild", {
                x = x, y = baseY, z = z, scale = scale, ry = rot,
                color = style.trimColor or 0xd8b46a,
            })
        end

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
            self:Add(self.flameCoreGeo, "glow", { x=x, y=baseY+0.19*scale, z=z, scale=0.55, color=self.theme.flameCore })
        end
        return false
    end

    if prop.kind == "chest" then
        self:Add("chestBody", "stone", { x=x,y=baseY,z=z,ry=rot,color=0x8a5a2c })
        self:Add("chestTrim", "trim", { x=x,y=baseY,z=z,ry=rot,color=0xc8a24a })
        self:Add("chestSeam", "glow", { x=x,y=baseY,z=z,ry=rot,color=0xffd27a })
    elseif prop.kind == "templeMedallion" then
        -- Wall plaque: gilt double ring with a dimly glowing sigil core.
        local dx, dy = prop.dx or 0, prop.dy or 1
        local mx, mz, mry = x + dx * 0.55, z + dy * 0.55, math.atan(dx, dy)
        self:Add("templeMedallion", "gild", { x=mx, y=baseY+1.52, z=mz,
            scale=scale, ry=mry, color=0xd8b46a })
        self:Add("templeMedallionCore", "glow", { x=mx+dx*0.012, y=baseY+1.52, z=mz+dy*0.012,
            scale=scale, ry=mry, color=LerpColor(self:FxColor("runeColor"), 0x000000, 0.35) })
    elseif prop.kind == "obelisk" then
        self:Add("obelisk", "stone", { x=x, y=baseY, z=z, scale=scale, ry=rot,
            color=LerpColor(self.theme.pillar, 0x1c2028, 0.22) })
        self:Add("obeliskCollar", "gild", { x=x, y=baseY, z=z, scale=scale, ry=rot,
            color=0xd8b46a })
        self:Add("obeliskRune", "glow", { x=x, y=baseY, z=z, scale=scale, ry=rot,
            color=self:FxColor("runeColor") })
    elseif prop.kind == "guardianStatue" then
        self:Add("guardianStatue", "stone", { x=x, y=baseY, z=z, scale=scale, ry=rot,
            color=LerpColor(self.theme.wall, 0x14181e, 0.30) })
        self:Add("guardianEyes", "glow", { x=x, y=baseY, z=z, scale=scale, ry=rot,
            color=self:FxColor("runeColor") })
    elseif prop.kind == "crystalCluster" then
        self:Add("crystalRocks", "stone", { x=x, y=baseY, z=z, scale=scale, ry=rot,
            color=LerpColor(self.theme.wall, 0x0e1216, 0.30) })
        self:Add("crystalCluster", "glow", { x=x, y=baseY, z=z, scale=scale, ry=rot,
            color=self:FxColor("orbitColor", 0x8fbcff) })
    elseif prop.kind == "shrineCrystal" then
        self:Add("plinth", "stone", { x=x,y=baseY,z=z,ry=rot,color=LerpColor(self.theme.pillar,0xffffff,0.12) })
        if not self.animatedProps.shrineCrystal then
            self:Add("crystal", "glow", { x=x,y=baseY+1.4,z=z,scale=1.05,ry=rot,color=0x8fbcff })
        end
        for k = 0, 3 do
            local angle = k * math.pi * 0.5 + math.pi * 0.25
            local cx, cz = x + math.cos(angle) * 0.36, z + math.sin(angle) * 0.36
            self:Add("candle", "stone", { x=cx,y=baseY+0.5,z=cz,scale=0.8,color=0xd8cba8 })
            self:Add(self.flameCoreGeo, "glow", { x=cx,y=baseY+0.65,z=cz,scale=0.5,color=self.theme.flameCore })
        end
    elseif prop.kind == "ring" then
        self:Add("platform", "stone", { x=x,y=baseY-0.02,z=z,color=LerpColor(self.theme.floor,0xffffff,0.1) })
        self:Add("pillar", "stone", { x=x-1.45,y=baseY+0.1,z=z,scale=0.72,color=self.theme.pillar })
        self:Add("pillar", "stone", { x=x+1.45,y=baseY+0.1,z=z,scale=0.72,color=self.theme.pillar })
        if not self.animatedProps.ring then
            self:Add("ring", "glow", { x=x,y=baseY+0.16,z=z,color=0x3fd0bb })
            self:Add("portal", "glow", { x=x,y=baseY+0.12,z=z,color=0x3fd0bb,alpha=0.75 })
        end
    elseif prop.kind == "bossCrystal" then
        local style = self.profile.propStyle and self.profile.propStyle.bossCrystal
        if style then
            -- Temple boss centrepiece: stepped dais + levitated crystal
            -- monolith, keeping the boss-red identity without spike shards.
            self:Add(style.core or "templeBossCore", "stone", { x=x, y=baseY, z=z, ry=rot,
                color=LerpColor(self.theme.wall, 0x14181e, 0.30) })
            self:Add(style.crystal or "templeBossCrystal", "glow", { x=x, y=baseY, z=z, ry=rot,
                color=0xff4636 })
        else
            self:Add("bossShard", "glow", { x=x,y=baseY,z=z,scale=1.15,ry=rot,color=0xff4636 })
            self:Add("bossShard", "glow", { x=x+0.55,y=baseY,z=z-0.42,sx=0.6,sy=0.75,sz=0.6,ry=rot+1.2,color=0xff6a45 })
            local rocks = {{-0.62,0.42,0.75,0.8,2.1,0x4a3336},{0.75,0.55,0.55,0.6,3.6,0x51383a},{-0.5,-0.62,0.5,0.55,4.9,0x452f31}}
            for _, rock in ipairs(rocks) do self:Add("bossShard", "stone", {x=x+rock[1],y=baseY,z=z+rock[2],sx=rock[3],sy=rock[4],sz=rock[3],ry=rot+rock[5],color=rock[6]}) end
        end
    elseif prop.kind == "brazier" then
        local style = self.profile.propStyle and self.profile.propStyle.brazier
        self:Add(style and style.geometry or "brazier", style and style.material or "trim",
            {x=x,y=baseY,z=z,ry=rng:Float(0,math.pi*2),color=style and style.color or 0x3a3f4a})
        self:Add("coals", "glow", {x=x,y=baseY,z=z,color=0xff7a30})
        self:Add(self.flameGeo, "glow", {x=x,y=baseY+0.62,z=z,scale=1.35,color=self.theme.flame})
        self:Add(self.flameCoreGeo, "glow", {x=x,y=baseY+0.66,z=z,scale=1.3,color=self.theme.flameCore})
        return true
    elseif prop.kind == "banner" then
        local dx, dy = prop.dx or 0, prop.dy or 1
        local bx, bz, ry = x + dx * 0.54, z + dy * 0.54, math.atan(dx, dy)
        self:Add("bannerRod","trim",{x=bx,y=baseY+1.98,z=bz,ry=ry,color=0x6a5a3a})
        self:Add("bannerCloth","cloth",{x=bx+dx*0.03,y=baseY+1.96,z=bz+dy*0.03,ry=ry,color=self.theme.cloth})
        self:Add("emblem","glow",{x=bx+dx*0.06,y=baseY+1.6,z=bz+dy*0.06,ry=ry,color=self.theme.accentObject})
    elseif prop.kind == "templeBanner" then
        -- Processional tapestry: gilt rod with finials, a long swallow-tail
        -- cloth and a large rune emblem at its heart.
        local dx, dy = prop.dx or 0, prop.dy or 1
        local bx, bz, ry = x + dx * 0.54, z + dy * 0.54, math.atan(dx, dy)
        self:Add("templeBannerRod", "gild", { x=bx, y=baseY+2.02, z=bz, ry=ry, color=0xd8b46a })
        self:Add("templeBannerCloth", "cloth",
            { x=bx+dx*0.03, y=baseY+2.00, z=bz+dy*0.03, ry=ry, color=self.theme.cloth })
        self:Add("emblem", "glow", { x=bx+dx*0.06, y=baseY+1.42, z=bz+dy*0.06, ry=ry,
            scale=1.5, color=self:FxColor("runeColor") })
    end
    return false
end

function ExactGeometryBatcher:QueueTorch(layer, torch, floorSpacing)
    local x, baseY, z = self:WorldPosition(torch.x, torch.y, layer.floor, floorSpacing, 0)
    self.activeBaseY = baseY
    local dx, dy = torch.dx or 0, torch.dy or 1
    local mountX, mountZ, ry = x + dx * 0.5, z + dy * 0.5, math.atan(dx, dy)
    local structure = (self.pack and self.pack.structure) or self.profile.structure
    local torchGeometry = structure and structure.torchGeometry or "torch"
    local torchMaterial = structure and structure.torchMaterial or "trim"
    local torchColor = structure and structure.torchColor or 0x4a4038
    self:Add(torchGeometry, torchMaterial, { x=mountX,y=baseY+1.02,z=mountZ,ry=ry,color=torchColor })
    -- A kit may enclose its light in fixture glass (hanging lantern) instead
    -- of the open flame pair; the glass also anchors the point light.
    local glowSpec = structure and structure.torchGlow
    if glowSpec then
        local out = glowSpec.out or 0.16
        self:Add(glowSpec.geometry, "glow", {
            x = mountX + dx * out, y = baseY + (glowSpec.height or 1.5),
            z = mountZ + dy * out, ry = ry,
            scale = glowSpec.scale or 1, color = self.theme.flame,
        })
        return mountX + dx * out, baseY + (glowSpec.height or 1.5) * self.verticalScale, mountZ + dy * out
    end
    self:Add(self.flameGeo, "glow", { x=mountX+dx*0.16,y=baseY+1.5,z=mountZ+dy*0.16,scale=1.2,color=self.theme.flame })
    self:Add(self.flameCoreGeo, "glow", { x=mountX+dx*0.16,y=baseY+1.53,z=mountZ+dy*0.16,scale=1.2,color=self.theme.flameCore })
    return mountX + dx * 0.16, baseY + 1.53 * self.verticalScale, mountZ + dy * 0.16
end

function ExactGeometryBatcher:QueueSpawn(layer, spawn, floorSpacing, rng)
    local x, baseY, z = self:WorldPosition(spawn.x, spawn.y, layer.floor, floorSpacing, 0)
    self.activeBaseY = baseY
    local tier, rot = math.max(1, math.min(3, spawn.tier or 1)), rng:Float(0, math.pi * 2)
    local spawnVisual = (self.pack and self.pack.spawnVisual) or self.profile.spawnVisual
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
    local side = arch.side or "east"
    local horizontal = side == "north" or side == "south" or side == "n" or side == "s"
    -- The arch centre follows the corridor tangent, while its wall-normal
    -- coordinate follows the resolved room/corridor interface. Older saved
    -- layouts have no interface fields and intentionally fall back to x/y.
    local gridX = horizontal and arch.x or (arch.interfaceX or arch.x)
    local gridY = horizontal and (arch.interfaceY or arch.y) or arch.y
    local x, baseY, z = self:WorldPosition(gridX, gridY, layer.floor, floorSpacing, 0)
    self.activeBaseY = baseY
    local half = (arch.len or 2) * 0.5 + 0.15
    local structure = (self.pack and self.pack.structure) or self.profile.structure
    local tone = ThemeToneRules.Resolve(self.settingKey)
    local color = ThemeToneRules.ResolveDoorColor(self.theme, tone)
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
    templeFlame = true, templeFlameCore = true, templeSpawn = true,
    templeFloorInlay = true, templeBossCrystal = true, obeliskRune = true,
    templeLanternGlass = true, templeMedallionCore = true, pathRune = true,
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

-- The AtmosphereFX layer breathes the shared emissive materials. Entries pair
-- each material with the authored color so the pulse can rescale from a fixed
-- base instead of compounding frame over frame.
function ExactGeometryBatcher:GetEmissiveEntries()
    local entries = {}
    for color, material in pairs(self.emissiveMaterials) do
        entries[#entries + 1] = { color = color, material = material }
    end
    return entries
end

return ExactGeometryBatcher
