local MaterialRules = require("Rendering.ProceduralMaterialRules")

local GeometryBridge = {}
local geometryDataCache = setmetatable({}, { __mode = "k" })

local function CopyVertex(target, position, normal, uv)
    target.positions[#target.positions + 1] = position.x
    target.positions[#target.positions + 1] = position.y
    target.positions[#target.positions + 1] = position.z
    target.normals[#target.normals + 1] = normal.x
    target.normals[#target.normals + 1] = normal.y
    target.normals[#target.normals + 1] = normal.z
    target.uvs[#target.uvs + 1] = uv.x
    target.uvs[#target.uvs + 1] = uv.y
end

-- procedural-geometry.md exposes geometry only through ToModel() and
-- FillCustomGeometry(). Fill once and read the native CustomGeometry back so
-- authored shapes can still be transformed and merged into vertex-colour batches.
local function ReadFillGeometry(geometry)
    if not geometry or not geometry.FillCustomGeometry then return nil end
    local holder = Node()
    local component = holder:CreateComponent("CustomGeometry")
    geometry:FillCustomGeometry(component)
    local result = { positions = {}, normals = {}, uvs = {}, count = 0 }
    if component.GetNumGeometries and component.GetNumVertices and component.GetVertex then
        for geometryIndex = 0, component:GetNumGeometries() - 1 do
            for vertexIndex = 0, component:GetNumVertices(geometryIndex) - 1 do
                local vertex = component:GetVertex(geometryIndex, vertexIndex)
                CopyVertex(result, vertex.position, vertex.normal or Vector3.UP,
                    vertex.texCoord or Vector2.ZERO)
            end
        end
    end
    holder:Remove()
    result.count = #result.positions // 3
    return result.count > 0 and result or nil
end

function GeometryBridge.ToData(geometry)
    if geometry and geometry.positions and geometry.normals then return geometry end
    if not geometry then return nil end
    local cached = geometryDataCache[geometry]
    if cached then return cached end
    local data = ReadFillGeometry(geometry)
    if data then geometryDataCache[geometry] = data end
    return data
end

function GeometryBridge.Merge(list)
    local result = { positions = {}, normals = {}, uvs = {}, count = 0 }
    for _, source in ipairs(list) do
        local data = GeometryBridge.ToData(source)
        if data then
            for _, value in ipairs(data.positions) do result.positions[#result.positions + 1] = value end
            for _, value in ipairs(data.normals) do result.normals[#result.normals + 1] = value end
            for _, value in ipairs(data.uvs) do result.uvs[#result.uvs + 1] = value end
        end
    end
    result.count = #result.positions // 3
    return result
end

local function Rotate(x, y, z, rx, ry, rz)
    if rx and rx ~= 0 then
        local c, s = math.cos(rx), math.sin(rx)
        y, z = y * c - z * s, y * s + z * c
    end
    if ry and ry ~= 0 then
        local c, s = math.cos(ry), math.sin(ry)
        x, z = x * c + z * s, -x * s + z * c
    end
    if rz and rz ~= 0 then
        local c, s = math.cos(rz), math.sin(rz)
        x, y = x * c - y * s, x * s + y * c
    end
    return x, y, z
end

function GeometryBridge.Transform(source, transform)
    local data = GeometryBridge.ToData(source)
    local result = { positions = {}, normals = {}, uvs = {}, count = data.count }
    local sx = transform.sx or transform.scale or 1
    local sy = transform.sy or transform.scale or sx
    local sz = transform.sz or transform.scale or sx
    local rx, ry, rz = transform.rx or 0, transform.ry or 0, transform.rz or 0
    for i = 1, #data.positions, 3 do
        local x, y, z = data.positions[i] * sx, data.positions[i + 1] * sy, data.positions[i + 2] * sz
        x, y, z = Rotate(x, y, z, rx, ry, rz)
        result.positions[#result.positions + 1] = x + (transform.x or 0)
        result.positions[#result.positions + 1] = y + (transform.y or 0)
        result.positions[#result.positions + 1] = z + (transform.z or 0)

        local nx = data.normals[i] / (math.abs(sx) > 0.000001 and sx or 1)
        local ny = data.normals[i + 1] / (math.abs(sy) > 0.000001 and sy or 1)
        local nz = data.normals[i + 2] / (math.abs(sz) > 0.000001 and sz or 1)
        nx, ny, nz = Rotate(nx, ny, nz, rx, ry, rz)
        local length = math.sqrt(nx * nx + ny * ny + nz * nz)
        if length > 0 then nx, ny, nz = nx / length, ny / length, nz / length end
        result.normals[#result.normals + 1] = nx
        result.normals[#result.normals + 1] = ny
        result.normals[#result.normals + 1] = nz
    end
    for _, value in ipairs(data.uvs) do result.uvs[#result.uvs + 1] = value end
    return result
end

function GeometryBridge.Color(value, alpha)
    value = value or 0xffffff
    return Color(((value >> 16) & 0xff) / 255, ((value >> 8) & 0xff) / 255,
        (value & 0xff) / 255, alpha or 1)
end

local function ScaledColor(value, strength)
    local color = GeometryBridge.Color(value, 1)
    local scale = strength or 1
    return Color(color.r * scale, color.g * scale, color.b * scale, 1)
end

function GeometryBridge.Material(options)
    options = options or {}
    local material = Material()
    local techniquePath = MaterialRules.PBRTechnique(options.transparent)
    material:SetTechnique(0, cache:GetResource("Technique", techniquePath))
    material:SetShaderParameter("MatDiffColor", Variant(GeometryBridge.Color(options.color, options.opacity)))
    local specular = options.specular or 0.5
    material:SetShaderParameter("MatSpecColor", Variant(Color(specular, specular, specular, 1)))
    material:SetShaderParameter("Metallic", Variant(options.metalness or MaterialRules.DEFAULT_METALLIC))
    material:SetShaderParameter("Roughness", Variant(options.roughness or MaterialRules.DEFAULT_ROUGHNESS))
    if options.side == 2 then material.cullMode = CULL_NONE end
    return material
end

function GeometryBridge.EmissiveMaterial(options)
    options = options or {}
    local material = GeometryBridge.Material(options)
    material:SetShaderParameter("MatEmissiveColor", Variant(ScaledColor(
        options.emissiveColor or options.color,
        options.emissiveStrength or MaterialRules.DEFAULT_EMISSIVE_STRENGTH)))
    return material
end

function GeometryBridge.UnlitMaterial(options)
    options = options or {}
    local material = Material()
    material:SetTechnique(0, cache:GetResource("Technique", MaterialRules.UNLIT))
    material:SetShaderParameter("MatDiffColor", Variant(GeometryBridge.Color(options.color, options.opacity)))
    if options.side == 2 then material.cullMode = CULL_NONE end
    return material
end

local function EmitInstance(component, data, instance, color)
    local sx, sy, sz = instance.sx or 1, instance.sy or 1, instance.sz or 1
    local rx, ry, rz = instance.rx or 0, instance.ry or 0, instance.rz or 0
    for i = 1, #data.positions, 3 do
        local x, y, z = data.positions[i] * sx, data.positions[i + 1] * sy, data.positions[i + 2] * sz
        x, y, z = Rotate(x, y, z, rx, ry, rz)
        component:DefineVertex(Vector3(x + instance.x, y + instance.y, z + instance.z))

        local nx = data.normals[i] / (math.abs(sx) > 0.000001 and sx or 1)
        local ny = data.normals[i + 1] / (math.abs(sy) > 0.000001 and sy or 1)
        local nz = data.normals[i + 2] / (math.abs(sz) > 0.000001 and sz or 1)
        nx, ny, nz = Rotate(nx, ny, nz, rx, ry, rz)
        local length = math.sqrt(nx * nx + ny * ny + nz * nz)
        if length > 0 then nx, ny, nz = nx / length, ny / length, nz / length end
        component:DefineNormal(Vector3(nx, ny, nz))
        local uvIndex = ((i - 1) // 3) * 2 + 1
        component:DefineTexCoord(Vector2(data.uvs[uvIndex] or 0, data.uvs[uvIndex + 1] or 0))
        component:DefineColor(color)
    end
end

function GeometryBridge.BuildColoredBatch(parent, name, source, instances, material, castShadows)
    if not source or #instances == 0 then return {}, 0 end
    local data = GeometryBridge.ToData(source)
    if not data or data.count == 0 then
        print("[GeometryBridge] unable to read vertices for " .. tostring(name))
        return {}, 0
    end
    local result, total = {}, 0
    local maxVertices = 180000
    local perChunk = math.max(1, maxVertices // math.max(1, data.count))
    local first = 1
    while first <= #instances do
        local last = math.min(#instances, first + perChunk - 1)
        local node = parent:CreateChild(name .. "-" .. (#result + 1))
        local component = node:CreateComponent("CustomGeometry")
        component:BeginGeometry(0, TRIANGLE_LIST)
        for i = first, last do
            local instance = instances[i]
            EmitInstance(component, data, instance,
                GeometryBridge.Color(instance.color or 0xffffff, instance.alpha))
        end
        component:Commit()
        component:SetMaterial(material)
        component.castShadows = castShadows ~= false
        component.receiveShadows = true
        result[#result + 1] = component
        total = total + last - first + 1
        first = last + 1
    end
    return result, total
end

return GeometryBridge
