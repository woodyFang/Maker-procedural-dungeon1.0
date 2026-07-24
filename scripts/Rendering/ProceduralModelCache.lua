local ProceduralModelCache = {}
ProceduralModelCache.__index = ProceduralModelCache

local FACTORIES = {
    box = function() return BoxGeometry(1, 1, 1):ToModel() end,
    roundedBox = function() return RoundedBoxGeometry(1, 1, 1, 2, 0.10):ToModel() end,
    cylinder = function() return CylinderGeometry(0.5, 0.5, 1, 12, 1, false):ToModel() end,
    cone = function() return ConeGeometry(0.5, 1, 10, 1, false):ToModel() end,
    sphere = function() return SphereGeometry(0.5, 14, 10):ToModel() end,
    torus = function() return TorusGeometry(0.5, 0.09, 8, 20):ToModel() end,
    octahedron = function() return OctahedronGeometry(0.5, 0):ToModel() end,
    icosahedron = function() return IcosahedronGeometry(0.5, 0):ToModel() end,
    plane = function() return PlaneGeometry(1, 1, 1, 1):ToModel() end,
    disc = function() return CircleGeometry(0.5, 24):ToModel() end,
    ring = function() return RingGeometry(0.34, 0.5, 24, 1):ToModel() end,
    bannerCloth = function()
        return ShapeGeometry({
            Vector2(-0.27, 0), Vector2(0.27, 0), Vector2(0.27, -0.62),
            Vector2(0, -0.80), Vector2(-0.27, -0.62),
        }):ToModel()
    end,
    -- Atmosphere FX primitives. godRay is a downward-widening open cone that
    -- spans one 5m storey (0..6 local, scaled by the renderer). Ring/disc
    -- geometry stays in the three.js XY plane; the FX layer lays it flat with
    -- a -90° pitch on the holder node before spinning the parent around +Y.
    godRay = function() return CylinderGeometry(0.40, 1.55, 6, 16, 1, true):ToModel() end,
    runeRing = function() return RingGeometry(1.5, 2.3, 48):ToModel() end,
    runeRingInner = function() return RingGeometry(0.78, 1.18, 36):ToModel() end,
    portalDisc = function() return CircleGeometry(0.86, 24):ToModel() end,
    gateRing = function() return TorusGeometry(0.95, 0.055, 8, 40):ToModel() end,
}

function ProceduralModelCache.new()
    return setmetatable({ models = {} }, ProceduralModelCache)
end

---@param key string
---@return Model|nil
function ProceduralModelCache:Get(key)
    local cached = self.models[key]
    if cached then return cached end

    local factory = FACTORIES[key]
    if not factory then
        log:Write(LOG_ERROR, "[ProceduralModelCache] unknown model key " .. tostring(key))
        return nil
    end

    local ok, model = pcall(factory)
    if not ok or not model then
        log:Write(LOG_ERROR, "[ProceduralModelCache] failed to build " .. tostring(key) .. ": " .. tostring(model))
        return nil
    end
    self.models[key] = model
    print(string.format("[ProceduralModelCache] built %s", key))
    return model
end

function ProceduralModelCache:Warmup()
    for key in pairs(FACTORIES) do self:Get(key) end
end

return ProceduralModelCache
