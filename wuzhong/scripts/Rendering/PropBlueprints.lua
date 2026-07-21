local PropBlueprints = {}

local function Part(model, material, x, y, z, sx, sy, sz, rx, ry, rz)
    return {
        model = model, material = material,
        x = x or 0, y = y or 0, z = z or 0,
        sx = sx or 1, sy = sy or 1, sz = sz or 1,
        rx = rx or 0, ry = ry or 0, rz = rz or 0,
    }
end

local P = Part
local BLUEPRINTS = {
    pillar = { parts = {
        P("roundedBox", "stone", 0, 0.08, 0, 0.68, 0.15, 0.68),
        P("cylinder", "stone", 0, 0.89, 0, 0.44, 1.50, 0.44),
        P("cylinder", "trim", 0, 1.68, 0, 0.54, 0.07, 0.54),
        P("roundedBox", "stone", 0, 1.76, 0, 0.55, 0.14, 0.55),
    } },
    entrance = { parts = {
        P("ring", "portal", 0, 0.025, 0, 1.72, 1.72, 1.72, -90, 0, 0),
        P("torus", "trim", 0, 0.13, 0, 1.90, 0.26, 1.90),
    }, light = { color = "portal", y = 0.8, brightness = 3.0, range = 5.5 } },
    bossCrystal = { parts = {
        P("roundedBox", "stone", 0, 0.18, 0, 0.92, 0.36, 0.92),
        P("octahedron", "boss", 0, 1.12, 0, 0.82, 2.30, 0.82),
        P("torus", "bossGlow", 0, 0.48, 0, 1.35, 0.16, 1.35),
        P("octahedron", "stone", -0.62, 0.42, 0.42, 0.75, 0.80, 0.75, 3, 120, -4),
        P("octahedron", "stone", 0.75, 0.32, 0.55, 0.55, 0.60, 0.55, -3, 206, 3),
        P("octahedron", "stone", -0.50, 0.30, -0.62, 0.50, 0.55, 0.50, 2, 281, 2),
    }, light = { color = "bossGlow", y = 1.4, brightness = 4.0, range = 7.0 } },
    shrineCrystal = { parts = {
        P("roundedBox", "stone", 0, 0.20, 0, 0.92, 0.40, 0.92),
        P("octahedron", "glow", 0, 0.92, 0, 0.60, 1.30, 0.60),
        P("torus", "glow", 0, 0.44, 0, 1.05, 0.13, 1.05),
    }, light = { color = "glow", y = 1.0, brightness = 2.8, range = 5.0 } },
    chest = { parts = {
        P("roundedBox", "wood", 0, 0.20, 0, 0.80, 0.40, 0.52),
        P("cylinder", "wood", 0, 0.48, 0, 0.50, 0.78, 0.50, 0, 0, 90),
        P("box", "trim", -0.20, 0.30, 0.27, 0.07, 0.58, 0.05),
        P("box", "trim", 0.20, 0.30, 0.27, 0.07, 0.58, 0.05),
        P("box", "glow", 0, 0.34, 0.31, 0.12, 0.17, 0.06),
    } },
    debris = { parts = {
        P("icosahedron", "stone", 0, 0.09, 0, 0.30, 0.22, 0.28, 18, 28, 5),
        P("icosahedron", "stone", 0.18, 0.06, 0.08, 0.20, 0.15, 0.18, -8, 52, 22),
    } },
    grave = { parts = {
        P("box", "stone", 0, 0.25, 0, 0.36, 0.50, 0.09),
        P("cylinder", "stone", 0, 0.50, 0, 0.36, 0.09, 0.36, 90, 0, 0),
    } },
    sarco = { parts = {
        P("roundedBox", "stone", 0, 0.22, 0, 1.50, 0.44, 0.80),
        P("roundedBox", "trim", 0, 0.52, 0, 1.38, 0.16, 0.68),
    } },
    candle = { parts = {
        P("cylinder", "wax", 0, 0.09, 0, 0.13, 0.18, 0.13),
        P("cone", "flame", 0, 0.27, 0, 0.12, 0.30, 0.12),
    }, light = { color = "flame", y = 0.35, brightness = 1.2, range = 2.5 } },
    icicle = { mount = "wallHigh", parts = {
        P("cone", "ice", 0, -0.25, 0, 0.15, 0.50, 0.15, 180, 0, 0),
        P("cone", "ice", 0.11, -0.17, 0.04, 0.10, 0.34, 0.10, 180, 0, 0),
        P("cone", "ice", -0.09, -0.13, -0.05, 0.08, 0.26, 0.08, 180, 0, 0),
    } },
    shardIce = { parts = { P("octahedron", "ice", 0, 0.30, 0, 0.34, 0.75, 0.30) } },
    roots = { mount = "wall", parts = {
        P("cylinder", "root", 0.10, 0.82, 0.15, 0.10, 1.85, 0.10, 38, 0, 18),
        P("cylinder", "root", -0.18, 0.66, 0.18, 0.08, 1.55, 0.08, 48, 0, -24),
        P("cylinder", "root", 0.26, 0.48, 0.24, 0.07, 1.20, 0.07, 58, 0, 34),
    } },
    moss = { parts = { P("disc", "moss", 0, 0.018, 0, 0.84, 0.84, 0.84, -90, 0, 0) } },
    bones = { parts = {
        P("cylinder", "bone", 0, 0.05, 0, 0.05, 0.34, 0.05, 0, 0, 90),
        P("cylinder", "bone", 0.06, 0.06, 0.05, 0.04, 0.30, 0.04, 0, 40, 90),
        P("sphere", "bone", -0.12, 0.08, -0.08, 0.16, 0.16, 0.16),
    } },
    brazier = { parts = {
        P("box", "trim", 0.16, 0.25, 0, 0.07, 0.50, 0.07, 0, 0, -14),
        P("box", "trim", -0.08, 0.25, 0.14, 0.07, 0.50, 0.07, 13, 0, 8),
        P("box", "trim", -0.08, 0.25, -0.14, 0.07, 0.50, 0.07, -13, 0, 8),
        P("cylinder", "trim", 0, 0.52, 0, 0.64, 0.26, 0.64),
        P("icosahedron", "flame", 0, 0.68, 0, 0.24, 0.18, 0.24),
    }, light = { color = "flame", y = 0.78, brightness = 2.8, range = 5.0 } },
    banner = { mount = "wallHigh", parts = {
        P("cylinder", "trim", 0, -0.52, 0, 0.056, 0.74, 0.056, 0, 0, 90),
        P("bannerCloth", "cloth", 0, -0.54, -0.02, 1, 1, 1),
        P("plane", "glow", 0, -0.90, -0.04, 0.17, 0.17, 1, 0, 0, 45),
    } },
    crack = { mount = "floor", parts = {
        P("plane", "warning", 0, 0.016, 0, 1.20, 1.20, 1, -90, 0, 0),
    } },
    crackIce = { mount = "floor", parts = {
        P("plane", "ice", 0, 0.016, 0, 1.20, 1.20, 1, -90, 0, 0),
    } },
    pool = { mount = "floor", parts = {
        P("box", "stone", 0, -0.43, 0, 1, 0.55, 1),
        P("plane", "warning", 0, 0.02, 0, 2.70, 2.70, 1, -90, 0, 0),
    } },
    spawn1 = { parts = {
        P("cone", "spawn", 0, 0.25, 0, 0.20, 0.50, 0.20, 0, 14, 0),
        P("cone", "spawn", 0.16, 0.20, -0.06, 0.17, 0.42, 0.17, -17, -17, 0),
        P("cone", "spawn", -0.13, 0.17, 0.11, 0.14, 0.34, 0.14, 16, 13, 0),
    } },
    spawn2 = { parts = {
        P("octahedron", "spawn", 0, 0.52, 0, 0.34, 1.15, 0.34),
        P("torus", "glow", 0, 0.42, 0, 0.52, 0.10, 0.52),
    } },
    spawn3 = { parts = {
        P("octahedron", "boss", 0, 0.76, 0, 0.44, 1.65, 0.44),
        P("torus", "bossGlow", 0, 0.54, 0, 0.66, 0.12, 0.66),
    } },

    hospitalBed = { parts = {
        P("roundedBox", "cloth", 0, 0.42, 0, 1.35, 0.18, 0.62),
        P("roundedBox", "white", -0.66, 0.62, 0, 0.18, 0.46, 0.66),
        P("cylinder", "metal", -0.52, 0.20, -0.24, 0.05, 0.42, 0.05),
        P("cylinder", "metal", 0.52, 0.20, -0.24, 0.05, 0.42, 0.05),
        P("cylinder", "metal", -0.52, 0.20, 0.24, 0.05, 0.42, 0.05),
        P("cylinder", "metal", 0.52, 0.20, 0.24, 0.05, 0.42, 0.05),
    } },
    ivStand = { parts = {
        P("cylinder", "metal", 0, 0.52, 0, 0.05, 1.05, 0.05),
        P("cylinder", "metal", 0, 1.05, 0, 0.06, 0.45, 0.06, 0, 0, 90),
        P("torus", "glass", 0.16, 0.86, 0, 0.18, 0.05, 0.18),
        P("roundedBox", "metal", 0, 0.02, 0, 0.34, 0.04, 0.34),
    } },
    medCabinet = { parts = {
        P("roundedBox", "white", 0, 0.45, 0, 0.72, 0.90, 0.42),
        P("box", "teal", 0, 0.55, 0.235, 0.04, 0.48, 0.05),
        P("box", "teal", 0, 0.55, 0.24, 0.50, 0.06, 0.05),
    } },
    surgeryTable = { parts = {
        P("roundedBox", "cloth", 0, 0.62, 0, 1.55, 0.22, 0.68),
        P("roundedBox", "white", -0.58, 0.82, 0, 0.62, 0.12, 0.54),
        P("cylinder", "metal", 0, 0.31, 0, 0.20, 0.58, 0.20),
        P("roundedBox", "metal", 0, 0.04, 0, 0.68, 0.07, 0.50),
    } },
    receptionDesk = { parts = {
        P("roundedBox", "white", 0, 0.31, 0, 1.55, 0.62, 0.46),
        P("roundedBox", "teal", 0, 0.66, 0, 1.35, 0.08, 0.54),
        P("roundedBox", "dark", 0, 0.70, 0.29, 0.72, 0.05, 0.04),
    } },
    waitingBench = { parts = {
        P("roundedBox", "cloth", 0, 0.38, 0, 1.35, 0.12, 0.36),
        P("roundedBox", "cloth", 0, 0.58, -0.18, 1.35, 0.36, 0.08, -8, 0, 0),
        P("cylinder", "metal", -0.46, 0.18, 0.10, 0.05, 0.38, 0.05),
        P("cylinder", "metal", 0.46, 0.18, 0.10, 0.05, 0.38, 0.05),
    } },
    medCart = { parts = {
        P("roundedBox", "white", 0, 0.36, 0, 0.72, 0.12, 0.48),
        P("roundedBox", "teal", 0, 0.66, 0, 0.66, 0.08, 0.42),
        P("cylinder", "metal", -0.28, 0.36, -0.18, 0.07, 0.54, 0.07),
        P("cylinder", "metal", 0.28, 0.36, -0.18, 0.07, 0.54, 0.07),
        P("torus", "rubber", -0.28, 0.05, 0.20, 0.12, 0.05, 0.12, 90, 0, 0),
        P("torus", "rubber", 0.28, 0.05, 0.20, 0.12, 0.05, 0.12, 90, 0, 0),
    } },
    monitor = { parts = {
        P("roundedBox", "dark", 0, 0.82, 0, 0.62, 0.42, 0.05),
        P("box", "screen", 0, 0.82, -0.031, 0.50, 0.31, 0.02),
        P("cylinder", "metal", 0, 0.35, 0, 0.05, 0.70, 0.05),
        P("roundedBox", "metal", 0, 0.04, 0, 0.42, 0.06, 0.32),
    } },
    hospitalSign = { mount = "wall", parts = {
        P("box", "white", 0, 0, 0, 0.62, 0.38, 0.04),
        P("box", "warning", 0, 0, -0.03, 0.11, 0.29, 0.05),
        P("box", "warning", 0, 0, -0.04, 0.33, 0.11, 0.05),
    } },
    nurseCounter = { parts = {
        P("roundedBox", "white", 0, 0.29, 0, 1.60, 0.58, 0.50),
        P("roundedBox", "teal", -0.48, 0.38, 0, 0.58, 0.76, 0.46),
        P("roundedBox", "dark", 0.24, 0.66, 0.27, 0.78, 0.06, 0.08),
    } },
    doctorDesk = { parts = {
        P("roundedBox", "white", 0, 0.48, 0, 1.05, 0.12, 0.58),
        P("roundedBox", "white", -0.42, 0.23, 0, 0.12, 0.46, 0.46),
        P("roundedBox", "white", 0.42, 0.23, 0, 0.12, 0.46, 0.46),
        P("roundedBox", "screen", 0.18, 0.62, 0.18, 0.28, 0.18, 0.05, -9, 0, 0),
    } },
    examTable = { parts = {
        P("roundedBox", "cloth", 0, 0.55, 0, 1.20, 0.18, 0.50),
        P("roundedBox", "white", -0.44, 0.70, 0, 0.38, 0.12, 0.46, 0, 0, 10),
        P("cylinder", "metal", -0.38, 0.26, -0.16, 0.08, 0.50, 0.08),
        P("cylinder", "metal", 0.38, 0.26, 0.16, 0.08, 0.50, 0.08),
    } },
    wallChart = { mount = "wall", parts = {
        P("box", "white", 0, 0, 0, 0.54, 0.62, 0.04),
        P("box", "teal", 0, 0.18, -0.03, 0.40, 0.04, 0.05),
        P("box", "teal", 0, 0.05, -0.03, 0.34, 0.03, 0.05),
        P("box", "teal", 0, -0.08, -0.03, 0.28, 0.03, 0.05),
    } },
    noticeBoard = { mount = "wall", parts = {
        P("box", "wood", 0, 0, 0, 0.78, 0.52, 0.04),
        P("box", "white", -0.18, 0.04, -0.03, 0.22, 0.28, 0.05),
        P("box", "warning", 0.18, -0.02, -0.03, 0.22, 0.20, 0.05),
    } },
    clock = { mount = "wall", parts = {
        P("cylinder", "white", 0, 0, 0, 0.44, 0.04, 0.44, 90, 0, 0),
        P("box", "dark", 0.04, 0.03, -0.03, 0.15, 0.02, 0.05, 0, 0, 37),
        P("box", "dark", 0, -0.03, -0.04, 0.02, 0.12, 0.05),
    } },
    privacyCurtain = { parts = {
        P("cylinder", "metal", -0.62, 0.78, -0.42, 0.04, 1.55, 0.04),
        P("cylinder", "metal", 0.62, 0.78, -0.42, 0.04, 1.55, 0.04),
        P("cylinder", "metal", 0, 1.54, -0.42, 0.04, 1.28, 0.04, 0, 0, 90),
        P("plane", "curtain", 0, 1.0, -0.43, 1.32, 1.05, 1),
        P("plane", "curtain", -0.64, 1.0, 0.02, 0.92, 1.05, 1, 0, 90, 0),
    } },
    surgicalLamp = { parts = {
        P("cylinder", "metal", 0, 1.55, 0, 0.07, 1.0, 0.07, 36, 0, 12),
        P("cylinder", "metal", 0.35, 1.25, 0, 0.06, 0.72, 0.06, 0, 0, 72),
        P("cylinder", "white", 0.68, 1.08, 0, 0.64, 0.12, 0.52, 90, 0, 0),
        P("sphere", "glow", 0.56, 1.08, 0.15, 0.15, 0.15, 0.15),
        P("sphere", "glow", 0.75, 1.08, 0, 0.15, 0.15, 0.15),
        P("sphere", "glow", 0.56, 1.08, -0.15, 0.15, 0.15, 0.15),
    }, light = { color = "glow", x = 0.66, y = 1.0, brightness = 2.0, range = 4.5 } },
    mriScanner = { parts = {
        P("cylinder", "white", 0, 0.72, 0, 1.24, 0.78, 1.24, 0, 0, 90),
        P("cylinder", "dark", 0, 0.72, 0, 0.76, 0.82, 0.76, 0, 0, 90),
        P("roundedBox", "cloth", 0.28, 0.42, 0, 1.55, 0.18, 0.42),
        P("roundedBox", "white", 0.78, 0.56, 0, 0.68, 0.08, 0.32),
    } },
    wallLight = { mount = "wall", parts = {
        P("roundedBox", "glow", 0, 0, 0, 0.82, 0.08, 0.05),
        P("roundedBox", "metal", -0.46, 0, 0, 0.14, 0.10, 0.06),
        P("roundedBox", "metal", 0.46, 0, 0, 0.14, 0.10, 0.06),
    }, light = { color = "glow", y = 0, z = -0.20, brightness = 1.4, range = 3.5 } },
    oxygenTank = { parts = {
        P("cylinder", "teal", -0.08, 0.34, 0, 0.24, 0.68, 0.24),
        P("cylinder", "teal", 0.12, 0.34, 0, 0.24, 0.68, 0.24),
        P("sphere", "metal", -0.08, 0.72, 0, 0.16, 0.16, 0.16),
        P("sphere", "metal", 0.12, 0.72, 0, 0.16, 0.16, 0.16),
        P("cylinder", "metal", 0.02, 0.58, 0, 0.04, 0.46, 0.04, 0, 0, 90),
    } },
    bioBin = { parts = {
        P("roundedBox", "warning", 0, 0.26, 0, 0.44, 0.52, 0.42),
        P("roundedBox", "dark", 0, 0.56, 0, 0.52, 0.08, 0.48),
        P("box", "dark", 0, 0.62, 0.26, 0.22, 0.04, 0.04),
    } },
    gurney = { parts = {
        P("roundedBox", "cloth", 0, 0.58, 0, 1.45, 0.16, 0.55),
        P("roundedBox", "white", -0.52, 0.72, 0, 0.55, 0.10, 0.48),
        P("cylinder", "metal", 0, 0.77, -0.34, 0.04, 1.50, 0.04, 0, 0, 90),
        P("cylinder", "metal", 0, 0.77, 0.34, 0.04, 1.50, 0.04, 0, 0, 90),
        P("cylinder", "metal", -0.55, 0.30, -0.22, 0.05, 0.50, 0.05),
        P("cylinder", "metal", 0.55, 0.30, -0.22, 0.05, 0.50, 0.05),
        P("torus", "rubber", -0.55, 0.05, -0.22, 0.12, 0.05, 0.12, 90, 0, 0),
        P("torus", "rubber", 0.55, 0.05, 0.22, 0.12, 0.05, 0.12, 90, 0, 0),
    } },
    floorCross = { mount = "floor", parts = {
        P("plane", "warning", 0, 0.019, 0, 1.10, 0.22, 1, -90, 0, 0),
        P("plane", "warning", 0, 0.020, 0, 0.22, 1.10, 1, -90, 0, 0),
    } },
    floorStripe = { mount = "floor", parts = {
        P("plane", "warning", 0, 0.019, 0, 1.45, 0.12, 1, -90, 0, 0),
    } },
    cleanZone = { mount = "floor", parts = {
        P("plane", "teal", 0, 0.019, -1.10, 2.20, 0.08, 1, -90, 0, 0),
        P("plane", "teal", 0, 0.020, 1.10, 2.20, 0.08, 1, -90, 0, 0),
        P("plane", "teal", -1.10, 0.021, 0, 0.08, 2.20, 1, -90, 0, 0),
        P("plane", "teal", 1.10, 0.022, 0, 0.08, 2.20, 1, -90, 0, 0),
    } },
    floorArrow = { mount = "floor", parts = {
        P("plane", "warning", -0.16, 0.019, 0, 0.72, 0.14, 1, -90, 0, 0),
        P("cone", "warning", 0.34, 0.025, 0, 0.40, 0.06, 0.36, 0, 0, -90),
    } },
    wallPanel = { mount = "wall", parts = {
        P("box", "white", 0, 0, 0, 0.92, 0.52, 0.04),
        P("box", "teal", 0, 0.29, -0.03, 0.92, 0.06, 0.05),
        P("box", "teal", 0, -0.29, -0.03, 0.92, 0.06, 0.05),
    } },
    schoolStudentDesk = { parts = {
        P("roundedBox", "schoolWood", 0, 0.62, 0, 0.82, 0.08, 0.48),
        P("box", "schoolTrim", -0.32, 0.30, -0.16, 0.05, 0.60, 0.05),
        P("box", "schoolTrim", 0.32, 0.30, 0.16, 0.05, 0.60, 0.05),
        P("roundedBox", "schoolWood", 0, 0.34, 0.62, 0.44, 0.07, 0.38),
        P("box", "schoolWood", 0, 0.58, 0.78, 0.42, 0.42, 0.06, -7, 0, 0),
    } },
    schoolTeacherDesk = { parts = {
        P("roundedBox", "schoolWood", 0, 0.70, 0, 1.28, 0.10, 0.62),
        P("roundedBox", "schoolWood", -0.52, 0.34, 0, 0.16, 0.68, 0.54),
        P("roundedBox", "schoolWood", 0.52, 0.34, 0, 0.16, 0.68, 0.54),
    } },
    schoolLocker = { parts = {
        P("roundedBox", "schoolTrim", 0, 0.81, 0, 0.92, 1.62, 0.42),
        P("box", "schoolAccent", 0, 0.78, 0.23, 0.04, 1.48, 0.05),
    } },
    schoolBookshelf = { parts = {
        P("roundedBox", "schoolWood", 0, 0.71, 0, 1.18, 1.42, 0.34),
        P("box", "schoolAccent", 0, 0.42, 0.20, 1.04, 0.07, 0.24),
        P("box", "schoolAccent", 0, 0.86, 0.20, 1.04, 0.07, 0.24),
    } },
    schoolLabBench = { parts = {
        P("roundedBox", "schoolCounter", 0, 0.76, 0, 1.42, 0.12, 0.68),
        P("roundedBox", "schoolTrim", -0.54, 0.36, 0, 0.22, 0.72, 0.56),
        P("roundedBox", "schoolTrim", 0.54, 0.36, 0, 0.22, 0.72, 0.56),
    } },
    schoolCafeteriaTable = { parts = {
        P("roundedBox", "schoolWood", 0, 0.68, 0, 1.38, 0.10, 0.72),
        P("roundedBox", "schoolWood", 0, 0.38, -0.62, 1.28, 0.08, 0.24),
        P("roundedBox", "schoolWood", 0, 0.38, 0.62, 1.28, 0.08, 0.24),
    } },
    schoolReception = { parts = {
        P("roundedBox", "schoolWood", 0, 0.36, 0, 1.72, 0.72, 0.56),
        P("roundedBox", "schoolCounter", 0, 0.72, 0, 1.48, 0.10, 0.66),
    } },
    schoolGlobe = { parts = {
        P("sphere", "schoolAccent", 0, 0.82, 0, 0.60, 0.60, 0.60),
        P("cylinder", "schoolTrim", 0, 0.34, 0, 0.07, 0.52, 0.07),
    } },
    schoolStage = { parts = {
        P("roundedBox", "schoolWood", 0, 0.15, 0, 2.40, 0.30, 1.25),
        P("roundedBox", "schoolWood", 0, 0.38, 0.82, 1.60, 0.16, 0.42),
    } },
    schoolBlackboard = { mount = "wall", parts = {
        P("roundedBox", "schoolBoard", 0, 0, 0, 1.45, 0.82, 0.06),
        P("box", "schoolTrim", 0, -0.47, 0, 1.58, 0.06, 0.08),
    } },
    schoolNoticeBoard = { mount = "wall", parts = {
        P("roundedBox", "schoolWood", 0, 0, 0, 1.08, 0.68, 0.05),
        P("box", "schoolAccent", -0.25, -0.02, -0.03, 0.30, 0.38, 0.06),
    } },
    schoolClock = { mount = "wall", parts = { P("cylinder", "schoolTrim", 0, 0, 0, 0.44, 0.04, 0.44, 90, 0, 0) } },
    schoolWallLight = { mount = "wall", parts = { P("roundedBox", "glow", 0, 0, 0, 0.82, 0.08, 0.05) } },
    hospitalDoorPost = { parts = { P("roundedBox", "metal", 0, 0.78, 0, 0.16, 1.55, 0.16) } },
    hospitalDoorLintel = { parts = { P("roundedBox", "metal", 0, 1.52, 0, 1.0, 0.16, 0.22) } },
    deptSign = { mount = "wall", parts = {
        P("box", "white", 0, 0, 0, 0.74, 0.26, 0.04),
        P("box", "teal", -0.22, 0, -0.03, 0.16, 0.16, 0.05),
        P("box", "dark", 0.18, 0.04, -0.04, 0.34, 0.05, 0.05),
        P("box", "dark", 0.15, -0.06, -0.04, 0.28, 0.04, 0.05),
    } },
}

local ALIASES = { shrine = "shrineCrystal", ring = "entrance" }

function PropBlueprints.Get(kind)
    return BLUEPRINTS[ALIASES[kind] or kind]
end

function PropBlueprints.Count()
    local count = 0
    for _ in pairs(BLUEPRINTS) do count = count + 1 end
    return count
end

return PropBlueprints
