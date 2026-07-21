local Bridge = require("Rendering.GeometryBridge")
local GeometryRules = require("Generation.GeometryRules")

local rulesValid, rulesError = GeometryRules.Validate()
assert(rulesValid, rulesError)

local Geometry = {}

local function D(geometry) return Bridge.ToData(geometry) end
local function M(list) return Bridge.Merge(list) end
local function X(geometry, x, y, z, rx, ry, rz, sx, sy, sz)
    return Bridge.Transform(geometry, {
        x = x or 0, y = y or 0, z = z or 0,
        rx = rx or 0, ry = ry or 0, rz = rz or 0,
        sx = sx or 1, sy = sy or sx or 1, sz = sz or sx or 1,
    })
end

local function ChamferBox(width, height, depth, chamfer)
    -- The reference mesh has planar sides and one flat top bevel. RoundedBox
    -- smooths its normals and makes these faces look inflated, so use the
    -- documented point-cloud API to recover the original faceted silhouette.
    local halfWidth, halfDepth = width * 0.5, depth * 0.5
    local innerWidth = math.max(0.01, halfWidth - chamfer)
    local innerDepth = math.max(0.01, halfDepth - chamfer)
    local shoulder = math.max(0.01, height - chamfer)
    return D(ConvexGeometry({
        Vector3(-halfWidth, 0, -halfDepth), Vector3(halfWidth, 0, -halfDepth),
        Vector3(halfWidth, 0, halfDepth), Vector3(-halfWidth, 0, halfDepth),
        Vector3(-halfWidth, shoulder, -halfDepth), Vector3(halfWidth, shoulder, -halfDepth),
        Vector3(halfWidth, shoulder, halfDepth), Vector3(-halfWidth, shoulder, halfDepth),
        Vector3(-innerWidth, height, -innerDepth), Vector3(innerWidth, height, -innerDepth),
        Vector3(innerWidth, height, innerDepth), Vector3(-innerWidth, height, innerDepth),
    }))
end

local function Spire(radius, height, twist)
    local rings = {
        { r = radius, y = 0, a = 0 },
        { r = radius * 0.8, y = height * 0.45, a = twist * 0.5 },
        { r = radius * 0.48, y = height * 0.78, a = twist },
    }
    local function Point(r, y, a, index)
        local angle = a + index * math.pi * 0.5 + math.pi * 0.25
        return Vector3(math.cos(angle) * r, y, math.sin(angle) * r)
    end
    rings[#rings + 1] = { r = 0.001, y = height, a = twist }
    local sections = {}
    for _, ring in ipairs(rings) do
        local section = {}
        for side = 0, 3 do section[#section + 1] = Point(ring.r, ring.y, ring.a, side) end
        sections[#sections + 1] = section
    end
    return D(LoftGeometry(sections, true))
end

local function Tube(a, b, c)
    -- The engine library exposes TubeGeometry but not QuadraticBezierCurve3.
    -- Sampling the quadratic into a centripetal curve preserves the authored
    -- endpoints/control shape while still using the engine's Three.js tube API.
    local points = {}
    for i = 0, 7 do
        local t, u = i / 7, 1 - i / 7
        points[#points + 1] = Vector3(
            u * u * a.x + 2 * u * t * b.x + t * t * c.x,
            u * u * a.y + 2 * u * t * b.y + t * t * c.y,
            u * u * a.z + 2 * u * t * b.z + t * t * c.z)
    end
    return D(TubeGeometry(points, 7, 0.055, 6, false))
end

local G = {}

-- Each dungeon cell is an individual worn stone brick. The 40mm joint, top
-- chamfer and small per-instance height variation make the paving readable;
-- floorSeal remains the hidden watertight substrate below those joints.
G.floor = X(ChamferBox(
    GeometryRules.DUNGEON_FLOOR_BRICK_SIZE,
    GeometryRules.DUNGEON_FLOOR_BRICK_HEIGHT,
    GeometryRules.DUNGEON_FLOOR_BRICK_SIZE,
    GeometryRules.DUNGEON_FLOOR_BRICK_CHAMFER),
    0, -GeometryRules.DUNGEON_FLOOR_BRICK_HEIGHT, 0)
G.hospitalFloor = X(BoxGeometry(0.98, 0.1, 0.98), 0, -0.05, 0)
G.floorSeal = X(BoxGeometry(GeometryRules.FloorSealSize(), GeometryRules.FLOOR_SEAL_DEPTH,
    GeometryRules.FloorSealSize()), 0, GeometryRules.FloorSealCenterY(), 0)
G.wallFootSeal = X(BoxGeometry(GeometryRules.WallFootprintSize(),
    GeometryRules.WALL_FLOOR_VERTICAL_OVERLAP, GeometryRules.WallFootprintSize()),
    0, GeometryRules.WallFootCenterY(), 0)
G.wall = ChamferBox(1, 1, 1, 0.07)
G.hospitalWall = X(BoxGeometry(1, 1, 1), 0, 0.5, 0)
G.wallCap = ChamferBox(1.09, GeometryRules.DUNGEON_WALL_CAP_HEIGHT, 1.09, 0.035)
G.hospitalWallCap = X(BoxGeometry(1.04, GeometryRules.HOSPITAL_WALL_CAP_HEIGHT, 1.04),
    0, GeometryRules.HOSPITAL_WALL_CAP_HEIGHT * 0.5, 0)
G.basin = X(BoxGeometry(1, 0.55, 1), 0, -0.43, 0)
G.pillar = M({
    X(ChamferBox(0.68, 0.15, 0.68, 0.035), 0, 0, 0),
    X(CylinderGeometry(0.19, 0.25, 1.5, 10), 0, 0.89, 0),
    X(CylinderGeometry(0.27, 0.27, 0.07, 10), 0, 1.68, 0),
    X(ChamferBox(0.55, 0.14, 0.55, 0.03), 0, 1.72, 0),
})
G.archPost = ChamferBox(0.24, 1.74, 0.24, 0.045)
G.archLintel = ChamferBox(1, 0.22, 0.36, 0.05)
G.torch = M({
    X(BoxGeometry(0.07, 0.36, 0.07), 0, 0.16, 0.07, -0.42, 0, 0),
    X(CylinderGeometry(0.11, 0.05, 0.16, 7), 0, 0.36, 0.15),
})
G.flame = X(ConeGeometry(0.13, 0.42, 7), 0, 0.21, 0)
G.flameCore = X(ConeGeometry(0.065, 0.26, 7), 0, 0.13, 0)
G.debrisA = X(IcosahedronGeometry(0.15, 0), 0, 0.05, 0)
G.debrisB = M({
    X(IcosahedronGeometry(0.13, 0), 0, 0.05, 0, 0.3, 0.5, 0),
    X(IcosahedronGeometry(0.09, 0), 0.17, 0.04, 0.05, 0, 1.1, 0.4),
    X(IcosahedronGeometry(0.07, 0), -0.12, 0.03, 0.13, 0.7, 0, 0),
})
G.debrisC = X(ChamferBox(0.34, 0.07, 0.28, 0.02), 0, 0, 0, 0, 0.4, 0.06)
G.chestBody = M({
    X(ChamferBox(0.8, 0.36, 0.52, 0.04), 0, 0, 0),
    X(CylinderGeometry(0.25, 0.25, 0.78, 10, 1, false, 0, math.pi), 0, 0.36, 0, 0, 0, math.pi * 0.5),
    X(CircleGeometry(0.25, 8, 0, math.pi), 0.39, 0.36, 0, 0, math.pi * 0.5, 0),
    X(CircleGeometry(0.25, 8, 0, math.pi), -0.39, 0.36, 0, 0, -math.pi * 0.5, 0),
})
G.chestTrim = M({
    X(BoxGeometry(0.07, 0.4, 0.55), -0.2, 0.2, 0), X(BoxGeometry(0.07, 0.4, 0.55), 0.2, 0.2, 0),
    X(TorusGeometry(0.26, 0.036, 6, 10, math.pi), -0.2, 0.36, 0, 0, math.pi * 0.5, 0),
    X(TorusGeometry(0.26, 0.036, 6, 10, math.pi), 0.2, 0.36, 0, 0, math.pi * 0.5, 0),
    X(BoxGeometry(0.11, 0.16, 0.06), 0, 0.33, 0.26),
})
G.chestSeam = X(BoxGeometry(0.6, 0.045, 0.03), 0, 0.36, 0.25)
G.grave = M({
    X(BoxGeometry(0.36, 0.5, 0.09), 0, 0.25, 0),
    X(CylinderGeometry(0.18, 0.18, 0.09, 10, 1, false, 0, math.pi), 0, 0.5, 0, math.pi * 0.5, 0, math.pi * 0.5),
})
G.sarco = M({ X(ChamferBox(1.5, 0.44, 0.8, 0.06), 0, 0, 0), X(ChamferBox(1.38, 0.16, 0.68, 0.05), 0, 0.44, 0) })
G.candle = X(CylinderGeometry(0.05, 0.065, 0.18, 6), 0, 0.09, 0)
G.icicle = M({
    X(ConeGeometry(0.075, 0.5, 6), 0, -0.25, 0, math.pi, 0, 0),
    X(ConeGeometry(0.05, 0.34, 6), 0.11, -0.17, 0.04, math.pi, 0, 0),
    X(ConeGeometry(0.04, 0.26, 5), -0.09, -0.13, -0.05, math.pi, 0, 0),
})
G.shard = Spire(0.17, 0.6, 0.6)
G.roots = M({
    Tube(Vector3(0, 1.75, -0.1), Vector3(0.05, 1.1, 0.42), Vector3(0.5, 0.02, 0.75)),
    Tube(Vector3(-0.1, 1.6, -0.1), Vector3(-0.3, 0.9, 0.4), Vector3(-0.55, 0.02, 0.9)),
    Tube(Vector3(0.12, 1.45, -0.08), Vector3(0.15, 0.8, 0.3), Vector3(0.05, 0.02, 1.1)),
    Tube(Vector3(-0.02, 1.2, -0.05), Vector3(-0.5, 0.7, 0.3), Vector3(-0.2, 0.02, 0.55)),
})
G.moss = X(CircleGeometry(0.42, 9), 0, 0.013, 0, -math.pi * 0.5, 0, 0)
G.crack = X(PlaneGeometry(1.2, 1.2), 0, 0.016, 0, -math.pi * 0.5, 0, 0)
G.skirt = X(PlaneGeometry(2.7, 2.7), 0, 0.02, 0, -math.pi * 0.5, 0, 0)
G.liquidCell = X(PlaneGeometry(1.02, 1.02), 0, 0, 0, -math.pi * 0.5, 0, 0)
G.bannerRod = X(CylinderGeometry(0.028, 0.028, 0.74, 6), 0, 0, 0, 0, 0, math.pi * 0.5)
G.bannerCloth = D(ShapeGeometry({
    Vector2(-0.27, 0), Vector2(0.27, 0), Vector2(0.27, -0.62),
    Vector2(0, -0.8), Vector2(-0.27, -0.62),
}))
G.emblem = X(PlaneGeometry(0.17, 0.17), 0, 0, 0, 0, 0, math.pi * 0.25)
G.spawn1 = M({
    X(ConeGeometry(0.1, 0.5, 5), 0, 0.24, 0, 0, 0, 0.24),
    X(ConeGeometry(0.085, 0.42, 5), 0.16, 0.2, -0.06, 0.3, 0, -0.3),
    X(ConeGeometry(0.07, 0.34, 5), -0.13, 0.17, 0.11, -0.28, 0, 0.22),
})
G.spawn2, G.band2 = Spire(0.17, 1.15, 0.5), ChamferBox(0.26, 0.07, 0.26, 0.015)
G.spawn3, G.band3 = Spire(0.22, 1.65, 0.85), ChamferBox(0.33, 0.09, 0.33, 0.02)
G.bossShard = Spire(0.34, 2.3, 0.7)
G.plinth, G.platform = ChamferBox(0.92, 0.5, 0.92, 0.06), ChamferBox(2.35, 0.14, 2.35, 0.06)
G.crystal = M({ X(OctahedronGeometry(0.3, 0), 0, 0, 0, 0, 0, 0, 1, 1.45, 1), X(OctahedronGeometry(0.16, 0), 0, 0.34, 0, 0, 0.6, 0, 1, 1.4, 1) })
G.ring = X(TorusGeometry(0.95, 0.07, 8, 30), 0, 0, 0, -math.pi * 0.5, 0, 0)
G.portal = X(CircleGeometry(0.86, 24), 0, 0, 0, -math.pi * 0.5, 0, 0)
G.runeRing = X(RingGeometry(1.5, 2.3, 48), 0, 0, 0, -math.pi * 0.5, 0, 0)
G.shaft = X(CylinderGeometry(0.45, 1.7, 6, 12, 1, true), 0, 3, 0)
G.brazier = M({
    X(BoxGeometry(0.07, 0.5, 0.07), 0.16, 0.25, 0, 0, 0, -0.25),
    X(BoxGeometry(0.07, 0.5, 0.07), -0.08, 0.25, 0.14, 0.22, 0, 0.13),
    X(BoxGeometry(0.07, 0.5, 0.07), -0.08, 0.25, -0.14, -0.22, 0, 0.13),
    X(CylinderGeometry(0.32, 0.16, 0.26, 9), 0, 0.52, 0),
})
G.coals = M({ X(IcosahedronGeometry(0.09, 0), 0, 0.63, 0.03), X(IcosahedronGeometry(0.07, 0), 0.1, 0.62, -0.06, 0, 0.5, 0), X(IcosahedronGeometry(0.06, 0), -0.1, 0.61, -0.02, 0.4, 0, 0) })
G.bone = M({
    X(CylinderGeometry(0.024, 0.024, 0.34, 5), 0, 0.03, 0, 0, 0.4, math.pi * 0.5),
    X(CylinderGeometry(0.02, 0.02, 0.3, 5), 0.04, 0.05, 0.06, 0, -0.7, math.pi * 0.5),
    X(SphereGeometry(0.08, 7, 6), -0.12, 0.08, -0.09),
    X(BoxGeometry(0.07, 0.05, 0.06), -0.12, 0.03, -0.03),
})

-- Hospital kit. These definitions are a direct Lua translation of the
-- reference project's GEO.* composites. procedural-geometry.md guarantees
-- Three.js parameter order, metre scale, and parameterized-shape orientation.
G.hospitalBed = M({
    X(ChamferBox(1.35, 0.18, 0.62, 0.035), 0, 0.42, 0),
    X(ChamferBox(0.18, 0.46, 0.66, 0.025), -0.66, 0.62, 0),
    X(CylinderGeometry(0.025, 0.025, 0.42, 5), -0.52, 0.20, -0.24),
    X(CylinderGeometry(0.025, 0.025, 0.42, 5), 0.52, 0.20, -0.24),
    X(CylinderGeometry(0.025, 0.025, 0.42, 5), -0.52, 0.20, 0.24),
    X(CylinderGeometry(0.025, 0.025, 0.42, 5), 0.52, 0.20, 0.24),
})
G.ivStand = M({
    X(CylinderGeometry(0.025, 0.025, 1.05, 6), 0, 0.52, 0),
    X(CylinderGeometry(0.03, 0.03, 0.45, 6), 0, 1.05, 0, 0, 0, math.pi * 0.5),
    X(TorusGeometry(0.09, 0.012, 5, 10), 0.16, 0.86, 0),
    X(ChamferBox(0.34, 0.035, 0.34, 0.01), 0, 0.02, 0),
})
G.medCabinet = M({
    X(ChamferBox(0.72, 0.9, 0.42, 0.035), 0, 0.45, 0),
    X(BoxGeometry(0.035, 0.48, 0.045), 0, 0.55, 0.235),
    X(BoxGeometry(0.5, 0.055, 0.045), 0, 0.55, 0.24),
})
G.surgeryTable = M({
    X(ChamferBox(1.55, 0.22, 0.68, 0.04), 0, 0.62, 0),
    X(ChamferBox(0.62, 0.12, 0.54, 0.03), -0.58, 0.82, 0),
    X(CylinderGeometry(0.08, 0.12, 0.58, 8), 0, 0.31, 0),
    X(ChamferBox(0.68, 0.07, 0.5, 0.02), 0, 0.04, 0),
})
G.receptionDesk = M({
    X(ChamferBox(1.55, 0.62, 0.46, 0.035), 0, 0.31, 0),
    X(ChamferBox(1.35, 0.08, 0.54, 0.02), 0, 0.66, 0),
    X(ChamferBox(0.72, 0.05, 0.035, 0.01), 0, 0.70, 0.29),
})
G.waitingBench = M({
    X(ChamferBox(1.35, 0.12, 0.36, 0.025), 0, 0.38, 0),
    X(ChamferBox(1.35, 0.36, 0.08, 0.02), 0, 0.58, -0.18, -0.14, 0, 0),
    X(CylinderGeometry(0.025, 0.025, 0.38, 5), -0.46, 0.18, 0.10),
    X(CylinderGeometry(0.025, 0.025, 0.38, 5), 0.46, 0.18, 0.10),
})
G.medCart = M({
    X(ChamferBox(0.72, 0.12, 0.48, 0.025), 0, 0.36, 0),
    X(ChamferBox(0.66, 0.08, 0.42, 0.02), 0, 0.66, 0),
    X(CylinderGeometry(0.035, 0.035, 0.54, 6), -0.28, 0.36, -0.18),
    X(CylinderGeometry(0.035, 0.035, 0.54, 6), 0.28, 0.36, -0.18),
    X(TorusGeometry(0.06, 0.014, 5, 8), -0.28, 0.05, 0.20, math.pi * 0.5, 0, 0),
    X(TorusGeometry(0.06, 0.014, 5, 8), 0.28, 0.05, 0.20, math.pi * 0.5, 0, 0),
})
G.monitor = M({
    X(ChamferBox(0.62, 0.42, 0.05, 0.018), 0, 0.82, 0),
    X(CylinderGeometry(0.025, 0.025, 0.7, 6), 0, 0.35, 0),
    X(ChamferBox(0.42, 0.06, 0.32, 0.015), 0, 0.04, 0),
})
G.hospitalSign = M({
    X(BoxGeometry(0.62, 0.38, 0.035), 0, 0, 0),
    X(BoxGeometry(0.11, 0.29, 0.045), 0, 0, 0.01),
    X(BoxGeometry(0.33, 0.105, 0.05), 0, 0, 0.02),
})
G.nurseCounter = M({
    X(ChamferBox(1.6, 0.58, 0.5, 0.035), 0, 0.29, 0),
    X(ChamferBox(0.58, 0.76, 0.46, 0.03), -0.48, 0.38, 0),
    X(ChamferBox(0.78, 0.06, 0.08, 0.015), 0.24, 0.66, 0.27),
})
G.doctorDesk = M({
    X(ChamferBox(1.05, 0.12, 0.58, 0.025), 0, 0.48, 0),
    X(ChamferBox(0.12, 0.46, 0.46, 0.018), -0.42, 0.23, 0),
    X(ChamferBox(0.12, 0.46, 0.46, 0.018), 0.42, 0.23, 0),
    X(ChamferBox(0.28, 0.18, 0.05, 0.01), 0.18, 0.62, 0.18, -0.16, 0, 0),
})
G.examTable = M({
    X(ChamferBox(1.2, 0.18, 0.5, 0.03), 0, 0.55, 0),
    X(ChamferBox(0.38, 0.12, 0.46, 0.02), -0.44, 0.70, 0, 0, 0, 0.18),
    X(CylinderGeometry(0.04, 0.04, 0.5, 6), -0.38, 0.26, -0.16),
    X(CylinderGeometry(0.04, 0.04, 0.5, 6), 0.38, 0.26, 0.16),
})
G.wallChart = M({
    X(BoxGeometry(0.54, 0.62, 0.035), 0, 0, 0),
    X(BoxGeometry(0.4, 0.035, 0.045), 0, 0.18, 0.01),
    X(BoxGeometry(0.34, 0.028, 0.045), 0, 0.05, 0.01),
    X(BoxGeometry(0.28, 0.028, 0.045), 0, -0.08, 0.01),
})
G.noticeBoard = M({
    X(BoxGeometry(0.78, 0.52, 0.035), 0, 0, 0),
    X(BoxGeometry(0.22, 0.28, 0.045), -0.18, 0.04, 0.01),
    X(BoxGeometry(0.22, 0.2, 0.045), 0.18, -0.02, 0.01),
})
G.clock = M({
    X(CylinderGeometry(0.22, 0.22, 0.035, 24), 0, 0, 0, math.pi * 0.5, 0, 0),
    X(BoxGeometry(0.15, 0.018, 0.045), 0.04, 0.03, 0.015, 0, 0, 0.65),
    X(BoxGeometry(0.018, 0.12, 0.045), 0, -0.03, 0.018),
})
G.privacyCurtain = M({
    X(CylinderGeometry(0.018, 0.018, 1.55, 6), -0.62, 0.78, -0.42),
    X(CylinderGeometry(0.018, 0.018, 1.55, 6), 0.62, 0.78, -0.42),
    X(CylinderGeometry(0.018, 0.018, 1.28, 6), 0, 1.54, -0.42, 0, 0, math.pi * 0.5),
    X(PlaneGeometry(1.32, 1.05), 0, 1.0, -0.43),
    X(PlaneGeometry(0.92, 1.05), -0.64, 1.0, 0.02, 0, math.pi * 0.5, 0),
})
G.surgicalLamp = M({
    X(CylinderGeometry(0.035, 0.035, 1.0, 6), 0, 1.55, 0, 0.62, 0, 0.20),
    X(CylinderGeometry(0.03, 0.03, 0.72, 6), 0.35, 1.25, 0, 0, 0, 1.25),
    X(CylinderGeometry(0.32, 0.26, 0.12, 18), 0.68, 1.08, 0, math.pi * 0.5, 0, 0),
    X(SphereGeometry(0.075, 8, 6), 0.56, 1.08, 0.15),
    X(SphereGeometry(0.075, 8, 6), 0.75, 1.08, 0),
    X(SphereGeometry(0.075, 8, 6), 0.56, 1.08, -0.15),
})
G.mriScanner = M({
    X(CylinderGeometry(0.62, 0.62, 0.78, 24, 1, false, 0, math.pi * 2), 0, 0.72, 0, 0, 0, math.pi * 0.5),
    X(CylinderGeometry(0.38, 0.38, 0.82, 24), 0, 0.72, 0, 0, 0, math.pi * 0.5),
    X(ChamferBox(1.55, 0.18, 0.42, 0.035), 0.28, 0.42, 0),
    X(ChamferBox(0.68, 0.08, 0.32, 0.02), 0.78, 0.56, 0),
})
G.wallLight = M({
    X(ChamferBox(0.82, 0.08, 0.05, 0.012), 0, 0, 0),
    X(ChamferBox(0.14, 0.1, 0.06, 0.01), -0.46, 0, 0),
    X(ChamferBox(0.14, 0.1, 0.06, 0.01), 0.46, 0, 0),
})
G.oxygenTank = M({
    X(CylinderGeometry(0.12, 0.12, 0.68, 12), -0.08, 0.34, 0),
    X(CylinderGeometry(0.12, 0.12, 0.68, 12), 0.12, 0.34, 0),
    X(SphereGeometry(0.08, 8, 6), -0.08, 0.72, 0),
    X(SphereGeometry(0.08, 8, 6), 0.12, 0.72, 0),
    X(CylinderGeometry(0.018, 0.018, 0.46, 6), 0.02, 0.58, 0, 0, 0, math.pi * 0.5),
})
G.bioBin = M({
    X(ChamferBox(0.44, 0.52, 0.42, 0.04), 0, 0.26, 0),
    X(ChamferBox(0.52, 0.08, 0.48, 0.025), 0, 0.56, 0),
    X(BoxGeometry(0.22, 0.035, 0.035), 0, 0.62, 0.26),
})
G.gurney = M({
    X(ChamferBox(1.45, 0.16, 0.55, 0.035), 0, 0.58, 0),
    X(ChamferBox(0.55, 0.1, 0.48, 0.025), -0.52, 0.72, 0),
    X(CylinderGeometry(0.022, 0.022, 1.5, 6), 0, 0.77, -0.34, 0, 0, math.pi * 0.5),
    X(CylinderGeometry(0.022, 0.022, 1.5, 6), 0, 0.77, 0.34, 0, 0, math.pi * 0.5),
    X(CylinderGeometry(0.025, 0.025, 0.5, 6), -0.55, 0.30, -0.22),
    X(CylinderGeometry(0.025, 0.025, 0.5, 6), 0.55, 0.30, -0.22),
    X(TorusGeometry(0.06, 0.014, 5, 8), -0.55, 0.05, -0.22, math.pi * 0.5, 0, 0),
    X(TorusGeometry(0.06, 0.014, 5, 8), 0.55, 0.05, 0.22, math.pi * 0.5, 0, 0),
})
G.floorCross = M({
    X(PlaneGeometry(1.1, 0.22), 0, 0.018, 0, -math.pi * 0.5, 0, 0),
    X(PlaneGeometry(0.22, 1.1), 0, 0.019, 0, -math.pi * 0.5, 0, 0),
})
G.floorStripe = X(PlaneGeometry(1.45, 0.12), 0, 0.018, 0, -math.pi * 0.5, 0, 0)
G.wallPanel = M({
    X(BoxGeometry(0.92, 0.52, 0.035), 0, 0, 0),
    X(BoxGeometry(0.92, 0.055, 0.045), 0, 0.29, 0.01),
    X(BoxGeometry(0.92, 0.055, 0.045), 0, -0.29, 0.01),
})
G.hospitalDoorPost = ChamferBox(0.16, 1.55, 0.16, 0.025)
G.hospitalDoorLintel = ChamferBox(1, 0.16, 0.22, 0.025)
G.deptSign = M({
    X(BoxGeometry(0.74, 0.26, 0.035), 0, 0, 0),
    X(BoxGeometry(0.16, 0.16, 0.045), -0.22, 0, 0.01),
    X(BoxGeometry(0.34, 0.045, 0.045), 0.18, 0.04, 0.015),
    X(BoxGeometry(0.28, 0.035, 0.045), 0.15, -0.06, 0.015),
})
G.cleanZone = M({
    X(PlaneGeometry(2.2, 0.08), 0, 0.019, -1.1, -math.pi * 0.5, 0, 0),
    X(PlaneGeometry(2.2, 0.08), 0, 0.019, 1.1, -math.pi * 0.5, 0, 0),
    X(PlaneGeometry(0.08, 2.2), -1.1, 0.02, 0, -math.pi * 0.5, 0, 0),
    X(PlaneGeometry(0.08, 2.2), 1.1, 0.02, 0, -math.pi * 0.5, 0, 0),
})
G.floorArrow = M({
    X(PlaneGeometry(0.72, 0.14), -0.16, 0.018, 0, -math.pi * 0.5, 0, 0),
    X(ConeGeometry(0.2, 0.36, 3), 0.34, 0.019, 0, -math.pi * 0.5, 0, math.pi * 0.5),
})

-- School ThemePack kit. Every object is authored against the shared 5m art
-- baseline. Human-scale props stay 1:1 at the default 5m storey.
G.schoolFloor = X(ChamferBox(0.98, 0.12, 0.98, 0.012), 0, -0.12, 0)
G.schoolWall = ChamferBox(1, 1, 1, 0.025)
G.schoolWallCap = ChamferBox(1.04, GeometryRules.SCHOOL_WALL_CAP_HEIGHT, 1.04, 0.012)
G.schoolDoorPost = ChamferBox(0.17, GeometryRules.SCHOOL_DOOR_POST_HEIGHT, 0.17, 0.018)
G.schoolDoorLintel = ChamferBox(1, GeometryRules.SCHOOL_DOOR_LINTEL_HEIGHT, 0.22, 0.018)
G.schoolSpawnMarker = M({
    X(RingGeometry(0.28, 0.40, 24), 0, 0.018, 0, -math.pi * 0.5, 0, 0),
    X(BoxGeometry(0.34, 0.018, 0.055), 0, 0.018, 0),
    X(BoxGeometry(0.055, 0.018, 0.34), 0, 0.018, 0),
})

G.schoolStudentDesk = M({
    X(ChamferBox(0.82, 0.08, 0.48, 0.018), 0, 0.62, 0),
    X(BoxGeometry(0.045, 0.60, 0.045), -0.32, 0.30, -0.16),
    X(BoxGeometry(0.045, 0.60, 0.045), 0.32, 0.30, -0.16),
    X(BoxGeometry(0.045, 0.60, 0.045), -0.32, 0.30, 0.16),
    X(BoxGeometry(0.045, 0.60, 0.045), 0.32, 0.30, 0.16),
    X(ChamferBox(0.44, 0.07, 0.38, 0.015), 0, 0.34, 0.62),
    X(BoxGeometry(0.42, 0.42, 0.055), 0, 0.58, 0.78, -0.12, 0, 0),
    X(BoxGeometry(0.04, 0.34, 0.04), -0.16, 0.17, 0.62),
    X(BoxGeometry(0.04, 0.34, 0.04), 0.16, 0.17, 0.62),
})
G.schoolTeacherDesk = M({
    X(ChamferBox(1.28, 0.10, 0.62, 0.022), 0, 0.70, 0),
    X(ChamferBox(0.16, 0.68, 0.54, 0.018), -0.52, 0.34, 0),
    X(ChamferBox(0.16, 0.68, 0.54, 0.018), 0.52, 0.34, 0),
    X(BoxGeometry(1.02, 0.34, 0.06), 0, 0.47, -0.29),
    X(ChamferBox(0.32, 0.07, 0.24, 0.012), 0.34, 0.82, 0.08),
})
G.schoolLocker = M({
    X(ChamferBox(0.92, 1.62, 0.42, 0.025), 0, 0, 0),
    X(BoxGeometry(0.035, 1.48, 0.045), 0, 0.78, 0.23),
    X(BoxGeometry(0.32, 0.025, 0.05), -0.23, 1.30, 0.24),
    X(BoxGeometry(0.32, 0.025, 0.05), 0.23, 1.30, 0.24),
    X(BoxGeometry(0.32, 0.025, 0.05), -0.23, 0.32, 0.24),
    X(BoxGeometry(0.32, 0.025, 0.05), 0.23, 0.32, 0.24),
})
G.schoolBookshelf = M({
    X(ChamferBox(1.18, 1.42, 0.34, 0.025), 0, 0, 0),
    X(BoxGeometry(1.04, 0.07, 0.38), 0, 0.42, 0.03),
    X(BoxGeometry(1.04, 0.07, 0.38), 0, 0.86, 0.03),
    X(BoxGeometry(1.04, 0.07, 0.38), 0, 1.28, 0.03),
    X(BoxGeometry(0.08, 0.32, 0.23), -0.38, 0.62, 0.20),
    X(BoxGeometry(0.08, 0.28, 0.23), -0.12, 1.06, 0.20),
    X(BoxGeometry(0.08, 0.34, 0.23), 0.26, 0.20, 0.20),
})
G.schoolLabBench = M({
    X(ChamferBox(1.42, 0.12, 0.68, 0.022), 0, 0.76, 0),
    X(ChamferBox(0.22, 0.72, 0.56, 0.018), -0.54, 0.36, 0),
    X(ChamferBox(0.22, 0.72, 0.56, 0.018), 0.54, 0.36, 0),
    X(CylinderGeometry(0.12, 0.08, 0.18, 10), -0.28, 0.91, 0.08),
    X(CylinderGeometry(0.09, 0.06, 0.24, 10), 0.18, 0.94, -0.04),
    X(BoxGeometry(0.34, 0.045, 0.24), 0.44, 0.85, 0.02),
})
G.schoolCafeteriaTable = M({
    X(ChamferBox(1.38, 0.10, 0.72, 0.022), 0, 0.68, 0),
    X(BoxGeometry(0.08, 0.64, 0.08), -0.48, 0.32, -0.24),
    X(BoxGeometry(0.08, 0.64, 0.08), 0.48, 0.32, 0.24),
    X(ChamferBox(1.28, 0.08, 0.24, 0.016), 0, 0.38, -0.62),
    X(ChamferBox(1.28, 0.08, 0.24, 0.016), 0, 0.38, 0.62),
})
G.schoolReception = M({
    X(ChamferBox(1.72, 0.72, 0.56, 0.028), 0, 0, 0),
    X(ChamferBox(1.48, 0.10, 0.66, 0.018), 0, 0.72, 0),
    X(BoxGeometry(0.72, 0.08, 0.05), 0, 0.48, 0.31),
})
G.schoolGlobe = M({
    X(SphereGeometry(0.30, 16, 12), 0, 0.82, 0),
    X(TorusGeometry(0.34, 0.025, 8, 20), 0, 0.82, 0, 0, 0, 0.30),
    X(CylinderGeometry(0.035, 0.05, 0.52, 8), 0, 0.34, 0),
    X(ChamferBox(0.42, 0.06, 0.34, 0.012), 0, 0.04, 0),
})
G.schoolStage = M({
    X(ChamferBox(2.4, 0.30, 1.25, 0.035), 0, 0, 0),
    X(ChamferBox(1.6, 0.16, 0.42, 0.022), 0, 0.30, 0.82),
    X(BoxGeometry(1.10, 0.05, 0.05), 0, 0.72, -0.42),
    X(BoxGeometry(0.05, 0.82, 0.05), -0.52, 0.72, -0.42),
    X(BoxGeometry(0.05, 0.82, 0.05), 0.52, 0.72, -0.42),
})
G.schoolBlackboard = M({
    X(ChamferBox(1.45, 0.82, 0.055, 0.012), 0, -0.41, 0),
    X(BoxGeometry(1.58, 0.055, 0.075), 0, 0.06, 0),
    X(BoxGeometry(1.58, 0.055, 0.075), 0, -0.88, 0),
})
G.schoolNoticeBoard = M({
    X(ChamferBox(1.08, 0.68, 0.05, 0.012), 0, -0.34, 0),
    X(BoxGeometry(0.30, 0.38, 0.06), -0.25, -0.36, 0.02),
    X(BoxGeometry(0.28, 0.30, 0.06), 0.25, -0.28, 0.02),
})

Geometry.GEO = G
Geometry.ChamferBox = ChamferBox
Geometry.Spire = Spire

return Geometry
