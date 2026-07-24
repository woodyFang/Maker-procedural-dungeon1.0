-- Generic "environment richness" rules.
--
-- The original build gave only the "dungeon" (遗迹) setting a rich environment
-- layer: floor-level scatter that fills negative space, dense light-emitting
-- wall fixtures, emphasis markers in high-tier rooms, and depth-gated ambient
-- clutter. That richness is a GENERIC capability, not a ruins-only feature.
--
-- This module models the ruins richness as a set of theme-agnostic layers. The
-- decoration passes that consume it (DungeonGenerator.Decorate) contain NO
-- ruins prop names and NO `settingKey == "dungeon"` branch -- the prop/model
-- types live here as per-theme DATA. Every built-in theme, and every custom
-- theme (which always inherits a base setting via baseSettingKey), runs the
-- identical passes; only the assets and densities differ.
--
-- These are 通用规则 in the sense of docs/generation-rules.md: the passes still
-- enforce doorway/corridor/lake/occupied avoidance, so a profile can only tune
-- WHAT fills the level and HOW densely, never break connectivity or placement
-- validity. A theme that omits a layer simply skips that pass.

local EnvironmentProfiles = {
    SCHEMA_VERSION = 3,
}

-- Layer vocabulary (all optional per theme):
--
-- floorScatter    Sprinkle a clutter prop across free floor cells to fill space.
--                 { kind, baseChance, corridorFactor, difficultyBias, scaleMin, scaleMax, variants }
--
-- emphasis        Wall-mounted markers in high-tier rooms (banner-style focus).
--                 { kind, minSpacing, roleTargets = { <roomType> = count } }
--
-- wallFixtures    How the light-emitting wall fixture is placed.
--                 mode = "dense"  : every clear candidate becomes a fixture (torch-style spam).
--                 mode = "spaced" : place along a spacing grid using wallDecor priority rolls.
--                 channel = "torch": feed layer.torches (renderer lights every 2nd, cap 18).
--                 channel = "prop" : the wallDecor entries are placed as emitsLight props.
--                 channel = "pack" : pull the decor list from the theme's ThemePack.wallRules.
--                 { mode, channel, proximity, spacing }
--
-- wallDecor       Priority list rolled per candidate in "spaced" mode; first hit wins.
--                 { { kind, chanceBase, chanceDensity, scaleMin, scaleMax }, ... }
--
-- wallAccents     Extra rolls layered onto "dense" fixtures (e.g. icicles on frost walls).
--                 { { kind, requireThemeFlag, chanceBase, chanceDensity, scaleMin, scaleMax }, ... }
--
-- ambientClutter  Depth-gated floor scatter for atmosphere (bones-style).
--                 { kind, requireThemeFlag, chanceBase, chanceDensity, minDepth, avoidCorridor, scaleMin, scaleMax }
--
-- structureRuin   Structural weathering applied while walls are batched: a
--                 fraction of eligible wall cells collapse to a partial height
--                 with rubble on the break. Never applies to doorway-adjacent
--                 or stair-contract walls, so connectivity reads intact.
--                 { brokenWallChance, heightMin, heightMax, rubbleChance }
--
-- atmosphere      Declares which AtmosphereFX passes run for this setting and
--                 where. Palette-level colors/counts live in theme.particles /
--                 theme.fx; this block only owns placement policy.
--                 { particles = { perFloorCap, totalCap, size, emissive },
--                   godRays = { roomTypes, minDim, maxPerFloor },
--                   runeCircles = { roomTypes },
--                   animatedProps = { <propKind> = true, ... },
--                   pulse = { min, max, speed } (fallback envelope) }
local PROFILES = {
    dungeon = {
        -- Shared structure-tone algorithm parameters. The renderer owns the
        -- algorithm; each setting only supplies data for the same pass.
        structureTone = {
            doorwayGain = 1.14, edgeDarkenStep = 0.11, edgeDarkenMaxWalls = 4,
            checkerGain = 0.965, semanticTintAmount = 0.17, surfaceTintAmount = 0.32,
            paletteAccentTintAmount = 0.00, paletteSaturation = 1.00, paletteContrast = 1.00,
            floorVariation = { 0.94, 1.06 }, wallVariation = { 0.90, 1.08 },
            capVariation = { 0.92, 1.10 }, surfaceTint = 0x4c7a42,
        },
        floorScatter = {
            kind = "debris", baseChance = 0.045, corridorFactor = 0.45,
            difficultyBias = true, scaleMin = 0.6, scaleMax = 1.35, variants = 3,
        },
        emphasis = {
            kind = "banner", minSpacing = 4,
            roleTargets = { elite = 2, boss = 4 },
        },
        wallFixtures = { mode = "dense", channel = "torch", proximity = 5 },
        wallAccents = {
            { kind = "icicle", requireThemeFlag = "icicles",
                chanceBase = 0.06, chanceDensity = 0.08, scaleMin = 0.70, scaleMax = 1.30 },
        },
        ambientClutter = {
            kind = "bones", requireThemeFlag = "bones",
            chanceBase = 0.018, chanceDensity = 0.02, minDepth = 1, avoidCorridor = true,
            scaleMin = 0.8, scaleMax = 1.2,
        },
        -- Region features use generic operations. These model types are data in
        -- this profile; other themes can provide their own feature props without
        -- changing the selector, carving or decoration code.
        roomFeatures = {
            { roomField = "lake", themeFlag = "lakes", roomTypes = { combat = true, elite = true },
                minDim = 9, count = 2 },
            { roomField = "grave", themeFlag = "graveyards", roomTypes = { combat = true },
                minDim = 8, shapeNot = "ellipse", count = 3 },
        },
        terrainCarving = {
            poolField = {
                themeField = "pools", amountField = "amount", tile = "POOL",
                output = "pools", candidate = "wall-edge", avoidDoorDistance = 2, spacing = 3,
            },
            pitField = {
                themeField = "pools", countField = "pits", tile = "POOL", output = "pools",
                roomTypes = { combat = true, elite = true },
                excludeRoomFields = { "lake", "grave" }, candidate = "room-interior",
                margin = 2, avoidCenter = true, neighborRadius = 1, poolSpacing = 4,
                maxAttempts = 40,
            },
            roomSurface = {
                roomField = "lake", mask = "lakeMask", cells = "lakeCells",
                margin = 2, neighborRadius = 1, requireSolid = true,
            },
        },
        terrainDecor = {
            surfaceProps = {
                cells = "lakeCells", kind = "shardIce", themeFlag = "icicles",
                chance = 0.05, scaleMin = 0.6, scaleMax = 1.2,
            },
            wallBreach = {
                kind = "roots", themeFlag = "roots", maxSites = 5, spacing = 7,
                secondary = { kind = "moss", radius = 2, chance = 0.75,
                    scaleMin = 0.7, scaleMax = 1.4 },
            },
            poolEdges = {
                poolModes = { [0] = 0.8, [3] = 0.45 }, kind = "crack",
                scaleMin = 0.9, scaleMax = 1.5,
            },
        },
    },
    -- Every setting below provides its own semantic assets for the same richness
    -- layers. The generic passes stay identical; only these data choices differ.
    -- Hospital uses medical equipment and signage, while school uses campus props.
    hospital = {
        structureTone = {
            doorwayGain = 1.14, edgeDarkenStep = 0.11, edgeDarkenMaxWalls = 4,
            checkerGain = 0.965, semanticTintAmount = 0.17, surfaceTintAmount = 0,
            paletteAccentTintAmount = 0.14, paletteSaturation = 1.45, paletteContrast = 1.08,
            floorVariation = { 0.94, 1.06 }, wallVariation = { 0.90, 1.08 },
            capVariation = { 0.92, 1.10 },
        },
        floorScatter = {
            kind = "medCart", baseChance = 0.018, corridorFactor = 0.28,
            difficultyBias = false, scaleMin = 0.72, scaleMax = 0.96, variants = 1,
        },
        emphasis = { kind = "hospitalSign", minSpacing = 3, roleTargets = { elite = 2, boss = 4 } },
        wallFixtures = { mode = "spaced", channel = "prop", spacing = 3, proximity = 5 },
        wallDecor = {
            { kind = "wallLight", chanceBase = 0.78, chanceDensity = 0.16, scaleMin = 0.88, scaleMax = 1.08 },
            { kind = "wallChart", chanceBase = 0.20, chanceDensity = 0.18, scaleMin = 0.88, scaleMax = 1.08 },
            { kind = "noticeBoard", chanceBase = 0.16, chanceDensity = 0.14, scaleMin = 0.88, scaleMax = 1.08 },
            { kind = "clock", chanceBase = 0.12, chanceDensity = 0.10, scaleMin = 0.88, scaleMax = 1.08 },
            { kind = "hospitalSign", chanceBase = 0.14, chanceDensity = 0.12, scaleMin = 0.88, scaleMax = 1.08 },
        },
        ambientClutter = {
            kind = "bioBin", chanceBase = 0.014, chanceDensity = 0.016, minDepth = 1, avoidCorridor = true,
            scaleMin = 0.70, scaleMax = 0.86,
        },
        corridorScatter = {
            { kind = "floorStripe", chanceBase = 0.040, chanceDensity = 0.045, rotMode = "axis",
                scaleMin = 0.85, scaleMax = 1.08 },
            { kind = "floorArrow", chanceBase = 0.014, chanceDensity = 0.024, rotMode = "quarter",
                scaleMin = 0.85, scaleMax = 1.05 },
        },
    },
    school = {
        structureTone = {
            doorwayGain = 1.14, edgeDarkenStep = 0.11, edgeDarkenMaxWalls = 4,
            checkerGain = 0.965, semanticTintAmount = 0.17, surfaceTintAmount = 0,
            paletteAccentTintAmount = 0.10, paletteSaturation = 1.35, paletteContrast = 1.08,
            floorVariation = { 0.94, 1.06 }, wallVariation = { 0.90, 1.08 },
            capVariation = { 0.92, 1.10 },
        },
        floorScatter = {
            kind = "schoolLocker", baseChance = 0.014, corridorFactor = 0.32,
            difficultyBias = false, scaleMin = 0.72, scaleMax = 0.94, variants = 1,
        },
        emphasis = { kind = "schoolBlackboard", minSpacing = 3, roleTargets = { elite = 2, boss = 4 } },
        ambientClutter = {
            kind = "schoolBookshelf", chanceBase = 0.012, chanceDensity = 0.014, minDepth = 1,
            avoidCorridor = true, scaleMin = 0.78, scaleMax = 0.98,
        },
        -- The school decor list (incl. its schoolWallLight) is authored in the
        -- ThemePack; the generic pass consumes it at the same quality spacing as
        -- the other settings.
        wallFixtures = { mode = "spaced", channel = "pack", spacing = 3, proximity = 5 },
    },
}

-- 神殿遗迹 (temple) keeps every ruins layer and stacks the showcase-only ones
-- on top: structural weathering, the dynamic atmosphere, and the signature
-- set pieces the ruins room decorator reads as data.
local function ExtendProfile(base, overrides)
    local result = {}
    for key, value in pairs(base) do result[key] = value end
    for key, value in pairs(overrides) do result[key] = value end
    return result
end

PROFILES.temple = ExtendProfile(PROFILES.dungeon, {
    -- A fully separate architectural kit: polished rosette paving with faint
    -- rune inlays inside rooms, dressed masonry (skirting + crown band) under
    -- a stepped cornice, pedimented doorways, fire sconces instead of stick
    -- torches. Geometry keys live in DungeonGeometryLibrary, materials in
    -- ProceduralMaterialRules; the batcher consumes this like a pack kit.
    structure = {
        floorGeometry = "templeFloor", floorMaterial = "templeFloor",
        floorAccentGeometry = "templeFloorRosette", floorAccentEvery = 2,
        floorInlay = { geometry = "templeFloorInlay", every = 3, colorField = "runeColor", dim = 0.45 },
        wallGeometry = "templeWall", wallMaterial = "templeWall",
        wallAccentGeometry = "templeWallPier", wallAccentEvery = 3, wallAccentGain = 1.06,
        capGeometry = "templeWallCap", capMaterial = "templeCap",
        doorPostGeometry = "templeDoorPost", doorLintelGeometry = "templeDoorLintel",
        doorMaterial = "templeCap",
        wallHeight = 2.0, wallHeightVariation = 0.06,
        -- Wall lamp: hanging gilt lantern whose glass capsule carries the glow
        -- (and the point light) instead of an open flame pair.
        torchGeometry = "templeLantern", torchMaterial = "gild", torchColor = 0xb08d52,
        torchGlow = { geometry = "templeLanternGlass", height = 1.675, out = 0.16 },
        flameGeometry = "templeFlame", flameCoreGeometry = "templeFlameCore",
    },
    -- Fluted columns with gilt rings and the great tripod cauldron replace
    -- the plain ruins pillar/brazier; the boss spike cluster becomes a dais
    -- with a levitated crystal monolith. Placement mechanics stay shared.
    propStyle = {
        pillar = { geometry = "templePillar", trimGeometry = "templePillarTrim",
            trimMaterial = "gild", trimColor = 0xd8b46a },
        brazier = { geometry = "templeBrazier", color = 0x6e5428 },
        bossCrystal = { core = "templeBossCore", crystal = "templeBossCrystal" },
    },
    -- Floating-bead tier markers instead of the ruins spike spires.
    spawnVisual = {
        geometry = "templeSpawn",
        material = "glow",
        colors = { 0xcf6a3a, 0xe0483e, 0xa678ff },
        scales = { 0.85, 1.0, 1.2 },
    },
    -- Scene-richness overrides: gilt sigil plaques between the lanterns,
    -- ceremonial amphorae in deep rooms, and waymark runes along corridors.
    wallAccents = {
        { kind = "templeMedallion", chanceBase = 0.05, chanceDensity = 0.06,
            scaleMin = 0.92, scaleMax = 1.06 },
        { kind = "icicle", requireThemeFlag = "icicles",
            chanceBase = 0.06, chanceDensity = 0.08, scaleMin = 0.70, scaleMax = 1.30 },
    },
    ambientClutter = {
        kind = "templeUrn", chanceBase = 0.015, chanceDensity = 0.017, minDepth = 1,
        avoidCorridor = true, scaleMin = 0.80, scaleMax = 1.08,
    },
    corridorScatter = {
        { kind = "pathRune", chanceBase = 0.030, chanceDensity = 0.032, rotMode = "quarter",
            scaleMin = 0.88, scaleMax = 1.10 },
    },
    emphasis = {
        kind = "templeBanner", minSpacing = 4,
        roleTargets = { elite = 2, boss = 4 },
    },
    structureRuin = {
        brokenWallChance = 0.055, heightMin = 0.32, heightMax = 0.60, rubbleChance = 0.7,
    },
    atmosphere = {
        particles = { perFloorCap = 240, totalCap = 420, size = 0.052, emissive = 1.9 },
        godRays = {
            roomTypes = { entrance = true, shrine = true, boss = true, treasure = true },
            minDim = 6, maxPerFloor = 5,
        },
        runeCircles = { roomTypes = { boss = true, shrine = true } },
        animatedProps = { ring = true, shrineCrystal = true },
        pulse = { min = 0.88, max = 1.18, speed = 1.1 },
    },
    -- Signature set pieces consumed by the ruins room decorator. A profile
    -- without this block (the plain dungeon) keeps the original dressing.
    roomSetPieces = {
        bossGuardian = { kind = "guardianStatue", scale = 1.25, edgeInset = 2 },
        eliteRing = { kind = "obelisk", count = 4, minDim = 8, radiusInset = 2.5,
            scaleMin = 0.92, scaleMax = 1.04 },
        treasureFocal = { kind = "crystalCluster", count = 2, scaleMin = 0.95, scaleMax = 1.30 },
        treasureGold = { kind = "goldPile", count = 2, scaleMin = 0.85, scaleMax = 1.25 },
        shrineFocal = { kind = "crystalCluster", count = 2, scaleMin = 0.75, scaleMax = 1.05 },
        combatArch = { kind = "archRuin", minDim = 12, chance = 0.4, scaleMin = 0.95, scaleMax = 1.10 },
        combatBroken = { kind = "brokenPillar", minDim = 8, chance = 0.55, scaleMin = 0.90, scaleMax = 1.12 },
    },
})

function EnvironmentProfiles.Resolve(settingKey)
    return PROFILES[settingKey] or PROFILES.dungeon
end

return EnvironmentProfiles
