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
    SCHEMA_VERSION = 2,
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
local PROFILES = {
    dungeon = {
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
    },
    -- hospital/school have no themed floor-clutter/emphasis blueprint yet, and the
    -- ruins props (debris/banner/bones) are forbidden in them by theme purity, so
    -- those layers stay nil. They DO inherit the generic wall-fixture richness now;
    -- adding a themed asset later is a data-only edit -- no engine change.
    -- Hospital fills the SAME generic layers with its OWN existing props: no new
    -- assets, no ruins models. floorStripe/floorArrow decorate corridors,
    -- bioBin is depth-gated ward clutter, hospitalSign marks key rooms.
    hospital = {
        emphasis = { kind = "hospitalSign", minSpacing = 4, roleTargets = { elite = 1, boss = 2 } },
        wallFixtures = { mode = "spaced", channel = "prop", spacing = 4, proximity = 5 },
        wallDecor = {
            { kind = "wallLight", chanceBase = 0.55, chanceDensity = 0.14, scaleMin = 0.88, scaleMax = 1.08 },
            { kind = "wallChart", chanceBase = 0.16, chanceDensity = 0.16, scaleMin = 0.88, scaleMax = 1.08 },
            { kind = "noticeBoard", chanceBase = 0.12, chanceDensity = 0.12, scaleMin = 0.88, scaleMax = 1.08 },
            { kind = "clock", chanceBase = 0.08, chanceDensity = 0.08, scaleMin = 0.88, scaleMax = 1.08 },
            { kind = "hospitalSign", chanceBase = 0.10, chanceDensity = 0.10, scaleMin = 0.88, scaleMax = 1.08 },
        },
        ambientClutter = {
            kind = "bioBin", chanceBase = 0.008, chanceDensity = 0.010, minDepth = 1, avoidCorridor = true,
            scaleMin = 0.70, scaleMax = 0.86,
        },
        corridorScatter = {
            { kind = "floorStripe", chanceBase = 0.025, chanceDensity = 0.035, rotMode = "axis",
                scaleMin = 0.85, scaleMax = 1.08 },
            { kind = "floorArrow", chanceBase = 0.008, chanceDensity = 0.018, rotMode = "quarter",
                scaleMin = 0.85, scaleMax = 1.05 },
        },
    },
    school = {
        -- The school decor list (incl. its schoolWallLight) is authored in the
        -- ThemePack; the generic pass just consumes it at a denser spacing.
        wallFixtures = { mode = "spaced", channel = "pack", spacing = 4, proximity = 5 },
    },
}

function EnvironmentProfiles.Resolve(settingKey)
    return PROFILES[settingKey] or PROFILES.dungeon
end

return EnvironmentProfiles
