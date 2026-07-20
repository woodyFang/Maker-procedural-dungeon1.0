local ProceduralMaterialRules = {
    -- Generated geometry stores the Three.js setColorAt equivalent in COLOR0.
    -- These project techniques are the documented no-texture PBR techniques
    -- with VERTEXCOLOR enabled; using plain PBRNoTexture would discard COLOR0.
    OPAQUE_PBR = "Techniques/Procedural/PBRNoTextureVCol.xml",
    TRANSPARENT_PBR = "Techniques/Procedural/PBRNoTextureAlphaVCol.xml",
    UNLIT = "Techniques/NoTextureUnlit.xml",
    DEFAULT_METALLIC = 0.0,
    DEFAULT_ROUGHNESS = 0.5,
    DEFAULT_EMISSIVE_STRENGTH = 1.65,
    -- Structural surfaces use restrained dielectric highlights: walls and
    -- wall caps stay matte, while floors are only slightly smoother so they
    -- catch a broad, weak reflection instead of reading as polished plastic.
    PROFILES = {
        dungeonFloor = { color = 0xe4e8eb, roughness = 0.70, metalness = 0.00, specular = 0.36 },
        dungeonWall = { color = 0xd2cdc5, roughness = 0.88, metalness = 0.00, specular = 0.18 },
        dungeonCap = { color = 0xe2ddd5, roughness = 0.82, metalness = 0.01, specular = 0.24 },
        stone = { color = 0xe2ded7, roughness = 0.86, metalness = 0.00, specular = 0.26 },
        hospitalFloor = { color = 0xf2ffff, roughness = 0.56, metalness = 0.01, specular = 0.52 },
        hospitalWall = { color = 0xd8dfdc, roughness = 0.82, metalness = 0.00, specular = 0.22 },
        hospitalTrim = { color = 0xf4fffd, roughness = 0.12, metalness = 0.90, specular = 0.94 },
        schoolFloor = { color = 0xe8eee9, roughness = 0.48, metalness = 0.00, specular = 0.50 },
        schoolWall = { color = 0xe5e7df, roughness = 0.86, metalness = 0.00, specular = 0.20 },
        schoolTrim = { color = 0xdce4df, roughness = 0.38, metalness = 0.62, specular = 0.66 },
        schoolWood = { color = 0xc39361, roughness = 0.58, metalness = 0.00, specular = 0.36 },
        schoolBoard = { color = 0x315b50, roughness = 0.74, metalness = 0.00, specular = 0.18 },
        schoolCounter = { color = 0xc8d2cf, roughness = 0.42, metalness = 0.04, specular = 0.46 },
        schoolAccent = { color = 0x4e91a8, roughness = 0.46, metalness = 0.02, specular = 0.44 },
        metalTrim = { color = 0xfff4df, roughness = 0.12, metalness = 0.92, specular = 0.92 },
        cloth = { roughness = 0.88, metalness = 0.0, specular = 0.36, side = 2 },
        ice = { roughness = 0.06, metalness = 0.0, specular = 0.94, transparent = true, opacity = 0.82 },
        moss = { roughness = 0.96, metalness = 0.0, specular = 0.30, side = 2 },
        bark = { roughness = 0.90, metalness = 0.0, specular = 0.36 },
    },
}

function ProceduralMaterialRules.PBRTechnique(transparent)
    return transparent and ProceduralMaterialRules.TRANSPARENT_PBR
        or ProceduralMaterialRules.OPAQUE_PBR
end

local function CheckProfile(profile, name)
    if not profile then return false, "missing material profile " .. name end
    if profile.roughness < 0 or profile.roughness > 1 then
        return false, name .. " roughness is outside 0..1"
    end
    if profile.metalness < 0 or profile.metalness > 1 then
        return false, name .. " metalness is outside 0..1"
    end
    if profile.specular < 0 or profile.specular > 1 then
        return false, name .. " specular is outside 0..1"
    end
    return true
end

function ProceduralMaterialRules.Validate()
    for name, profile in pairs(ProceduralMaterialRules.PROFILES) do
        local valid, reason = CheckProfile(profile, name)
        if not valid then return false, reason end
    end

    local profiles = ProceduralMaterialRules.PROFILES
    local dungeonRoughnessGap = profiles.dungeonWall.roughness - profiles.dungeonFloor.roughness
    if dungeonRoughnessGap < 0.12 or dungeonRoughnessGap > 0.24 then
        return false, "dungeon stone bricks must be only slightly smoother than the wall"
    end
    local dungeonSpecularGap = profiles.dungeonFloor.specular - profiles.dungeonWall.specular
    if dungeonSpecularGap < 0.12 or dungeonSpecularGap > 0.24 then
        return false, "dungeon stone-brick reflection must stay weak but visible"
    end
    if profiles.dungeonFloor.roughness < 0.68 or profiles.dungeonFloor.roughness > 0.76
        or profiles.dungeonFloor.metalness > 0.02 then
        return false, "dungeon floor must read as rough non-metallic stone brick"
    end
    local hospitalRoughnessGap = profiles.hospitalWall.roughness - profiles.hospitalFloor.roughness
    if hospitalRoughnessGap < 0.15 or hospitalRoughnessGap > 0.30 then
        return false, "hospital floor must be only slightly smoother than the wall"
    end
    local hospitalSpecularGap = profiles.hospitalFloor.specular - profiles.hospitalWall.specular
    if hospitalSpecularGap < 0.15 or hospitalSpecularGap > 0.35 then
        return false, "hospital floor reflection must stay subtle but visible"
    end
    if profiles.dungeonWall.roughness < 0.80 or profiles.hospitalWall.roughness < 0.80 then
        return false, "structural walls must remain matte"
    end
    if profiles.dungeonCap.roughness < 0.70 or profiles.dungeonCap.specular > 0.35 then
        return false, "wall caps must not read as polished surfaces"
    end
    if profiles.metalTrim.metalness < 0.75 or profiles.hospitalTrim.metalness < 0.75 then
        return false, "metal trim profiles are not metallic enough"
    end
    local schoolRoughnessGap = profiles.schoolWall.roughness - profiles.schoolFloor.roughness
    if schoolRoughnessGap < 0.30 or schoolRoughnessGap > 0.45 then
        return false, "school floor must be smoother than painted school walls"
    end
    if profiles.schoolTrim.metalness < 0.50 or profiles.schoolWood.metalness > 0.05 then
        return false, "school metal and wood material roles are not separated"
    end
    return true
end

return ProceduralMaterialRules
