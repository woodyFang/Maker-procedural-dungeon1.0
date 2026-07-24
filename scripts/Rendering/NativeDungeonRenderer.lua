local Themes = require("Config.Themes")
local ProceduralModelCache = require("Rendering.ProceduralModelCache")
local PropBlueprints = require("Rendering.PropBlueprints")
local ExactGeometryBatcher = require("Rendering.ExactGeometryBatcher")
local StairRenderPlan = require("Rendering.StairRenderPlan")
local Random = require("Generation.Random")
local MultiFloor = require("Generation.MultiFloor")
local EditorSelectionHighlight = require("Rendering.EditorSelectionHighlight")
local RoomGroupColors = require("Config.RoomGroupColors")

local NativeDungeonRenderer = {}
NativeDungeonRenderer.__index = NativeDungeonRenderer

local TILE_EMPTY = 0
local TILE_FLOOR = 1
local TILE_WALL = 2
local CELL_SIZE = 1.0
local FLOOR_THICKNESS = 0.16
local WALL_HEIGHT = 2.8

local function HexColor(value, brightness, alpha)
    local factor = brightness or 1.0
    local r = ((value >> 16) & 0xff) / 255
    local g = ((value >> 8) & 0xff) / 255
    local b = (value & 0xff) / 255
    return Color(math.min(1, r * factor), math.min(1, g * factor), math.min(1, b * factor), alpha or 1)
end

local function CreateMaterial(color, roughness, metallic, emissive)
    local material = Material:new()
    material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    material:SetShaderParameter("MatDiffColor", Variant(HexColor(color, 1.0)))
    material:SetShaderParameter("MatSpecColor", Variant(Color(0.35, 0.35, 0.35, 1)))
    material:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    material:SetShaderParameter("Roughness", Variant(roughness or 0.8))
    if emissive then
        material:SetShaderParameter("MatEmissiveColor", Variant(HexColor(emissive, 1.4)))
    end
    return material
end

local function MixHex(a, b, amount)
    local t = math.max(0, math.min(1, amount or 0.5))
    local function Channel(value, shift) return (value >> shift) & 0xff end
    local function MixChannel(shift)
        return math.floor(Channel(a, shift) * (1 - t) + Channel(b, shift) * t + 0.5)
    end
    return (MixChannel(16) << 16) | (MixChannel(8) << 8) | MixChannel(0)
end

local function ResourceMaterial(uri, fallback)
    local material = cache:GetResource("Material", uri)
    return material or fallback
end

local function CreateAlphaMaterial(color, roughness, emissive, alpha)
    local material = Material:new()
    material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    material:SetShaderParameter("MatDiffColor", Variant(HexColor(color, 1.0, alpha or 0.68)))
    material:SetShaderParameter("Roughness", Variant(roughness or 0.55))
    if emissive then
        material:SetShaderParameter("MatEmissiveColor", Variant(HexColor(emissive, 1.25)))
    end
    return material
end

local function CreateBlueprintMaterial(color, alpha)
    local material = Material:new()
    material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    -- Opaque PBR avoids the deferred-path and alpha-sorting issues seen on the
    -- temporary instanced overlay. Controlled emission keeps category colors.
    local strength = 0.80 + (alpha or 0.82) * 0.12
    material:SetShaderParameter("MatDiffColor", Variant(HexColor(color, strength, 1.0)))
    material:SetShaderParameter("MatSpecColor", Variant(Color(0.06, 0.06, 0.06, 1)))
    material:SetShaderParameter("Metallic", Variant(0.0))
    material:SetShaderParameter("Roughness", Variant(0.92))
    material:SetShaderParameter("MatEmissiveColor", Variant(HexColor(color, 0.58)))
    return material
end

local function CreatePropMaterials(theme)
    return {
        stone = CreateMaterial(theme.wall, 0.86, 0.02),
        trim = CreateMaterial(theme.pillar, 0.50, 0.62),
        portal = CreateAlphaMaterial(0x42e4cc, 0.22, 0x42e4cc, 0.74),
        boss = CreateMaterial(0xd8493f, 0.30, 0.12, 0xff5548),
        bossGlow = CreateMaterial(0xff6655, 0.20, 0.02, 0xff5548),
        glow = CreateMaterial(theme.flameCore, 0.22, 0.02, theme.flame),
        wood = CreateMaterial(0x6e4931, 0.82, 0.02),
        wax = CreateMaterial(0xe6d5ab, 0.72, 0.0),
        flame = CreateMaterial(theme.flameCore, 0.18, 0.0, theme.flame),
        ice = CreateAlphaMaterial(0xa8dcf3, 0.18, 0x65bde8, 0.62),
        root = CreateMaterial(0x3d2a1e, 0.92, 0.0),
        moss = CreateAlphaMaterial(0x446b36, 0.92, nil, 0.80),
        bone = CreateMaterial(0xd2cab0, 0.78, 0.0),
        spawn = CreateMaterial(theme.accentObject, 0.28, 0.06, theme.accentObject),
        cloth = CreateMaterial(MixHex(theme.floor, 0xffffff, 0.48), 0.84, 0.0),
        white = CreateMaterial(MixHex(theme.wall, 0xffffff, 0.72), 0.36, 0.0),
        metal = CreateMaterial(theme.pillar, 0.42, 0.72),
        teal = CreateMaterial(theme.accentObject, 0.38, 0.14),
        dark = CreateMaterial(MixHex(theme.wall, 0x101416, 0.66), 0.58, 0.26),
        rubber = ResourceMaterial("uuid://AkBCiS2MNfpI1vQqS6idJev_", CreateMaterial(0x24292b, 0.90, 0.0)),
        glass = CreateAlphaMaterial(0x9edbd5, 0.18, nil, 0.48),
        warning = CreateMaterial(0xe9574f, 0.48, 0.02),
        screen = CreateMaterial(0x183c42, 0.24, 0.16, 0x45d7ca),
        curtain = CreateAlphaMaterial(MixHex(theme.accentObject, 0xffffff, 0.54), 0.82, nil, 0.72),
    }
end

local function Push(list, x, y, z, sx, sy, sz)
    list[#list + 1] = {
        x = x, y = y, z = z,
        sx = sx or 1, sy = sy or 1, sz = sz or 1,
    }
end

local function Clamp01(value)
    return math.max(0, math.min(1, value))
end

local function Phase(time, startTime, endTime)
    return Clamp01((time - startTime) / math.max(0.0001, endTime - startTime))
end

local function EaseOutCubic(value)
    local inverse = 1 - Clamp01(value)
    return 1 - inverse * inverse * inverse
end

local BUILD_ANIMATION_DURATION = 1.80

local function CreateBuildTimeline(dungeon, floorVisible)
    local maxBfs = 0
    for _, layer in ipairs(dungeon.layers) do
        if floorVisible(layer.floor) then maxBfs = math.max(maxBfs, layer.maxBfs or 0) end
    end
    -- Keep the spatial wave readable without making large maps wait several
    -- extra seconds. The previous cap produced a ~6.6s animation on 42 rooms.
    local depthSpan = math.max(0.32, math.min(0.78, maxBfs * 0.0075))
    local cursor = 0
    local function Add(duration)
        local stage = { start = cursor, finish = cursor + duration, duration = duration }
        cursor = stage.finish
        return stage
    end
    local result = {
        layout = Add(0.32),
        graph = Add(0.26),
        structure = Add(0.52 + depthSpan),
        rooms = Add(0.40 + depthSpan * 0.18),
        atmosphere = Add(0.36),
    }
    -- Keep the stage proportions and spatial wave, but guarantee a short,
    -- map-size-independent presentation time.
    local timeScale = BUILD_ANIMATION_DURATION / math.max(0.0001, cursor)
    for _, name in ipairs({ "layout", "graph", "structure", "rooms", "atmosphere" }) do
        local stage = result[name]
        stage.start = stage.start * timeScale
        stage.finish = stage.finish * timeScale
        stage.duration = stage.duration * timeScale
    end
    result.timeScale = timeScale
    result.total = BUILD_ANIMATION_DURATION
    return result
end

function NativeDungeonRenderer.new(scene)
    return setmetatable({
        scene = scene,
        root = nil,
        instanceCount = 0,
        batchCount = 0,
        floorSpacing = 1,
        dynamicLights = {},
        elapsed = 0,
        animation = nil,
        lastBuildMetrics = nil,
        lastAnimationMetrics = nil,
        modelCache = ProceduralModelCache.new(),
        selectionRoot = nil,
        selectionDungeon = nil,
        selectionRoomIndex = nil,
        selectionLinkIndex = nil,
        selectionLink = nil,
        selectionMaterial = CreateMaterial(0xffa43a, 0.24, 0.04, 0xff7a18),
    }, NativeDungeonRenderer)
end

function NativeDungeonRenderer:WorldPosition(dungeon, gridX, gridY, floor, localY)
    local verticalScale = dungeon.floorHeight / MultiFloor.SOURCE_FLOOR_HEIGHT
    return (gridX - dungeon.width * 0.5 + 0.5) * CELL_SIZE,
        floor * dungeon.floorHeight * self.floorSpacing + (localY or 0) * verticalScale,
        (gridY - dungeon.height * 0.5 + 0.5) * CELL_SIZE
end

function NativeDungeonRenderer:Clear()
    if self.root then
        self.root:Remove()
        self.root = nil
    end
    self.instanceCount = 0
    self.batchCount = 0
    self.dynamicLights = {}
    self.animation = nil
    self.selectionRoot = nil
end

function NativeDungeonRenderer:RefreshEditorSelection()
    EditorSelectionHighlight.Refresh(self)
end

function NativeDungeonRenderer:SetEditorSelection(dungeon, roomIndex, linkIndex, link)
    EditorSelectionHighlight.Set(self, dungeon, roomIndex, linkIndex, link)
end

function NativeDungeonRenderer:ClearEditorSelection()
    EditorSelectionHighlight.Clear(self)
end

function NativeDungeonRenderer:AddModelBatch(parent, transforms, model, material, name, castShadows)
    if #transforms == 0 then return nil end
    if not model or not material then
        print("[NativeRenderer] skipped invalid batch " .. tostring(name))
        return nil
    end

    local batchNode = parent:CreateChild(name)
    local group = batchNode:CreateComponent("StaticModelGroup")
    group:SetModel(model)
    group:SetMaterial(material)
    group.castShadows = castShadows ~= false

    for index, transform in ipairs(transforms) do
        local node = batchNode:CreateChild(name .. "-" .. index)
        node.position = Vector3(transform.x, transform.y, transform.z)
        node.scale = Vector3(transform.sx, transform.sy, transform.sz)
        if transform.rotation then node.rotation = transform.rotation end
        group:AddInstanceNode(node)
    end

    self.instanceCount = self.instanceCount + #transforms
    self.batchCount = self.batchCount + 1
    return group
end

function NativeDungeonRenderer:AddBatch(parent, transforms, material, name)
    return self:AddModelBatch(parent, transforms, self.modelCache:Get("box"), material, name, true)
end

function NativeDungeonRenderer:AddRoomGroupHighlights(root, dungeon, floorVisible, roomGroups)
    local groupsById = {}
    for index, group in ipairs(roomGroups or {}) do
        if group and group.id then groupsById[group.id] = { group = group, index = index } end
    end

    local batches = {}
    for _, room in ipairs(dungeon.rooms or {}) do
        local entry = groupsById[room.roomGroupId]
        if entry and floorVisible(room.floor) then
            local color = RoomGroupColors.Parse(entry.group.color,
                RoomGroupColors.Default(entry.group, entry.index))
            local key = tostring(entry.group.id)
            batches[key] = batches[key] or { color = color, transforms = {} }
            local x, y, z = self:WorldPosition(dungeon, room.cx, room.cy, room.floor, 0.08)
            batches[key].transforms[#batches[key].transforms + 1] = {
                x = x, y = y, z = z,
                sx = math.max(0.8, room.w - 0.32), sy = 0.045, sz = math.max(0.8, room.h - 0.32),
            }
        end
    end

    for key, batch in pairs(batches) do
        local material = CreateAlphaMaterial(batch.color, 0.42, batch.color, 0.36)
        self:AddModelBatch(root, batch.transforms, self.modelCache:Get("box"), material,
            "RoomGroupHighlight-" .. key, false)
    end
end

function NativeDungeonRenderer:AddMarker(parent, name, x, y, z, color, scale)
    local node = parent:CreateChild(name)
    node.position = Vector3(x, y, z)
    node.scale = scale
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    model:SetMaterial(CreateMaterial(color, 0.3, 0.08, color))
    model.castShadows = true
    self.instanceCount = self.instanceCount + 1
    return node
end

function NativeDungeonRenderer:AddBeam(parent, name, a, b, material, thickness)
    local delta = b - a
    local length = math.sqrt(delta.x * delta.x + delta.z * delta.z)
    if length < 0.01 then return nil end
    local node = parent:CreateChild(name)
    node.position = (a + b) * 0.5
    node.rotation = Quaternion(math.deg(math.atan(delta.x, delta.z)), Vector3.UP)
    node.scale = Vector3(thickness or 0.10, thickness or 0.10, length)
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Box.mdl")); model:SetMaterial(material); model.castShadows = false
    self.instanceCount = self.instanceCount + 1
    return node
end

-- Beam that follows a full 3D direction (used by sloped stair handrails and
-- wall-finish strips). Cross-section is crossW (local X) x crossH (local Y),
-- length along local Z toward `b`.
function NativeDungeonRenderer:AddSlopedBeam(parent, name, a, b, material, crossW, crossH)
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length < 0.01 then return nil end
    local node = parent:CreateChild(name)
    node.position = (a + b) * 0.5
    node:LookAt(b)
    node.scale = Vector3(crossW or 0.06, crossH or 0.06, length)
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Box.mdl")); model:SetMaterial(material); model.castShadows = false
    self.instanceCount = self.instanceCount + 1
    return node
end

-- Vertical baluster/post box sitting on the walking surface.
function NativeDungeonRenderer:AddPostBox(parent, name, base, height, thickness, material)
    if height < 0.01 then return nil end
    local node = parent:CreateChild(name)
    node.position = Vector3(base.x, base.y + height * 0.5, base.z)
    node.scale = Vector3(thickness, height, thickness)
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Box.mdl")); model:SetMaterial(material); model.castShadows = false
    self.instanceCount = self.instanceCount + 1
    return node
end

function NativeDungeonRenderer:AddPrimitive(parent, name, modelPath, position, scale, material, rotation, castShadows)
    local node = parent:CreateChild(name)
    node.position = position
    node.scale = scale
    if rotation then node.rotation = rotation end
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", modelPath))
    model:SetMaterial(material)
    model.castShadows = castShadows ~= false
    self.instanceCount = self.instanceCount + 1
    return node
end

function NativeDungeonRenderer:AddPointLight(parent, name, position, color, brightness, range, flicker)
    local node = parent:CreateChild(name)
    node.position = position
    local light = node:CreateComponent("Light")
    light.lightType = LIGHT_POINT
    light.color = color
    light.brightness = brightness or 4.0
    light.range = range or 7.0
    light.castShadows = false
    self.dynamicLights[#self.dynamicLights + 1] = {
        light = light, base = light.brightness, phase = #self.dynamicLights * 1.731,
        flicker = flicker ~= false,
    }
    return light
end

local function SetAnimatedBeam(node, a, b, progress, thickness)
    local endPoint = a + (b - a) * math.max(0.0001, progress)
    local delta = endPoint - a
    local length = math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
    node.position = (a + endPoint) * 0.5
    node:LookAt(endPoint)
    node.scale = Vector3(thickness, thickness, math.max(0.0001, length))
end

local function UpdateRoomOutline(entry, progress)
    local center = entry.start + (entry.finish - entry.start) * progress
    local halfWidth, halfHeight = entry.width * 0.5, entry.height * 0.5
    local corners = {
        Vector3(center.x - halfWidth, center.y, center.z - halfHeight),
        Vector3(center.x + halfWidth, center.y, center.z - halfHeight),
        Vector3(center.x + halfWidth, center.y, center.z + halfHeight),
        Vector3(center.x - halfWidth, center.y, center.z + halfHeight),
    }
    for index, node in ipairs(entry.segments) do
        SetAnimatedBeam(node, corners[index], corners[index % 4 + 1], 1, entry.thickness)
    end
    entry.marker.position = center
    local markerScale = math.max(0.001, progress)
    entry.marker.scale = Vector3(entry.markerSize * markerScale, 0.035, entry.markerSize * markerScale)
end

local function RefreshOverlayGroups(overlay)
    for _, batch in ipairs(overlay.groups) do
        batch.group:RemoveAllInstanceNodes()
        for _, node in ipairs(batch.instances) do batch.group:AddInstanceNode(node) end
    end
end

function NativeDungeonRenderer:CreateBuildOverlay(dungeon, floorVisible, timeline)
    local root = self.root:CreateChild("BuildPipelineOverlay")
    local box = cache:GetResource("Model", "Models/Box.mdl")
    local overlay = { root = root, rooms = {}, beams = {}, groups = {}, removed = false }

    local function CreateOverlayGroup(name, color, alpha)
        local node = root:CreateChild(name)
        local group = node:CreateComponent("StaticModelGroup")
        group:SetModel(box)
        group:SetMaterial(CreateBlueprintMaterial(color, alpha))
        group.castShadows = false
        local batch = { node = node, group = group, instances = {} }
        overlay.groups[#overlay.groups + 1] = batch
        return batch
    end

    local roomGroups = {
        normal = CreateOverlayGroup("LayoutRooms-Normal", 0x56b8d0, 0.72),
        entrance = CreateOverlayGroup("LayoutRooms-Entrance", 0x43d7af, 0.88),
        treasure = CreateOverlayGroup("LayoutRooms-Treasure", 0xe0b657, 0.90),
        boss = CreateOverlayGroup("LayoutRooms-Boss", 0xe85d62, 0.92),
        special = CreateOverlayGroup("LayoutRooms-Special", 0xa783e8, 0.84),
    }
    local graphGroups = {
        normal = CreateOverlayGroup("Graph-Normal", 0x5cc5d8, 0.66),
        loop = CreateOverlayGroup("Graph-Loop", 0xb27ae8, 0.82),
        critical = CreateOverlayGroup("Graph-Critical", 0xf0b84f, 0.92),
        vertical = CreateOverlayGroup("Graph-Vertical", 0x72e0b8, 0.88),
    }

    local maxDepth = math.max(1, dungeon.maxDepth or 1)
    local function TrimToRoomBoundary(center, toward, room)
        local dx, dz = toward.x - center.x, toward.z - center.z
        if math.abs(dx) + math.abs(dz) < 0.001 then return center end
        local scale = math.huge
        if math.abs(dx) > 0.001 then
            scale = math.min(scale, math.max(0.25, room.w * 0.5 - 0.25) / math.abs(dx))
        end
        if math.abs(dz) > 0.001 then
            scale = math.min(scale, math.max(0.25, room.h * 0.5 - 0.25) / math.abs(dz))
        end
        if scale == math.huge or scale >= 1 then return center end
        return Vector3(center.x + dx * scale, center.y, center.z + dz * scale)
    end

    local function RoomStyle(room)
        if room.type == "entrance" then return "entrance" end
        if room.type == "treasure" then return "treasure" end
        if room.type == "boss" then return "boss" end
        if room.type == "elite" or room.type == "shrine" or room.type == "secret" then return "special" end
        return "normal"
    end

    for _, room in ipairs(dungeon.rooms) do
        if floorVisible(room.floor) then
            local batch = roomGroups[RoomStyle(room)]
            local startX, startY, startZ = self:WorldPosition(
                dungeon, room.sx0 or room.cx, room.sy0 or room.cy, room.floor, 0.30)
            local endX, endY, endZ = self:WorldPosition(dungeon, room.cx, room.cy, room.floor, 0.30)
            local entry = {
                start = Vector3(startX, startY, startZ), finish = Vector3(endX, endY, endZ),
                width = math.max(1, room.w), height = math.max(1, room.h), segments = {},
                thickness = room.type == "boss" and 0.070 or 0.050,
                markerSize = room.type == "boss" and 0.32 or 0.24,
                delay = 0.09 * timeline.timeScale * ((room.depth or 0) / maxDepth),
            }
            for side = 1, 4 do
                local node = batch.node:CreateChild("LayoutRoom-" .. room.id .. "-" .. side)
                entry.segments[side] = node
                batch.group:AddInstanceNode(node)
                batch.instances[#batch.instances + 1] = node
            end
            entry.marker = batch.node:CreateChild("LayoutPoint-" .. room.id)
            batch.group:AddInstanceNode(entry.marker)
            batch.instances[#batch.instances + 1] = entry.marker
            UpdateRoomOutline(entry, 0)
            overlay.rooms[#overlay.rooms + 1] = entry
        end
    end

    for _, edge in ipairs(dungeon.edges) do
        local roomA, roomB = dungeon.rooms[edge.a], dungeon.rooms[edge.b]
        if roomA and roomB and (floorVisible(roomA.floor) or floorVisible(roomB.floor)) then
            local style = roomA.floor ~= roomB.floor and "vertical"
                or (edge.isCritical and "critical" or (edge.isLoop and "loop" or "normal"))
            local batch = graphGroups[style]
            local ax, ay, az = self:WorldPosition(dungeon, roomA.cx, roomA.cy, roomA.floor, 0.34)
            local bx, by, bz = self:WorldPosition(dungeon, roomB.cx, roomB.cy, roomB.floor, 0.34)
            local centerA, centerB = Vector3(ax, ay, az), Vector3(bx, by, bz)
            local pointA = TrimToRoomBoundary(centerA, centerB, roomA)
            local pointB = TrimToRoomBoundary(centerB, centerA, roomB)
            local node = batch.node:CreateChild("BuildGraph-" .. edge.id)
            batch.group:AddInstanceNode(node)
            batch.instances[#batch.instances + 1] = node
            local entry = {
                node = node, a = pointA, b = pointB,
                thickness = style == "critical" and 0.180 or (style == "vertical" and 0.160
                    or (style == "loop" and 0.140 or 0.120)),
                delay = 0.06 * timeline.timeScale
                    * ((math.min(roomA.depth or 0, roomB.depth or 0)) / maxDepth),
            }
            SetAnimatedBeam(node, entry.a, entry.b, 0, entry.thickness)
            overlay.beams[#overlay.beams + 1] = entry
        end
    end
    RefreshOverlayGroups(overlay)
    return overlay
end

function NativeDungeonRenderer:UpdateBuildOverlay(animation)
    local overlay, timeline, time = animation.overlay, animation.timeline, animation.elapsed
    if not overlay or overlay.removed then return end
    for _, entry in ipairs(overlay.rooms) do
        local layoutProgress = EaseOutCubic(Phase(time,
            timeline.layout.start + entry.delay, timeline.layout.finish))
        UpdateRoomOutline(entry, layoutProgress)
    end
    for _, entry in ipairs(overlay.beams) do
        local graphProgress = EaseOutCubic(Phase(time,
            timeline.graph.start + 0.06 * timeline.timeScale + entry.delay, timeline.graph.finish))
        SetAnimatedBeam(entry.node, entry.a, entry.b,
            time >= timeline.graph.start and graphProgress or 0, entry.thickness)
    end
    if time >= timeline.structure.start + 0.24 * timeline.timeScale then
        overlay.root:Remove()
        overlay.removed = true
    else
        -- StaticModelGroup caches instance transforms and bounds. Re-registering
        -- this small temporary set keeps animated lines visible and correctly culled.
        RefreshOverlayGroups(overlay)
    end
end

local function RotateOffset(x, z, radians)
    local cosine, sine = math.cos(radians), math.sin(radians)
    return x * cosine + z * sine, -x * sine + z * cosine
end

function NativeDungeonRenderer:QueueBlueprint(batches, prop, x, baseY, z)
    local blueprint = PropBlueprints.Get(prop.kind)
    if not blueprint then
        print("[NativeRenderer] unsupported prop kind " .. tostring(prop.kind))
        return nil
    end

    local yaw = math.deg(prop.rot or 0)
    local mountY = 0
    if blueprint.mount == "wall" then
        mountY = 1.45
        if prop.dx or prop.dy then yaw = math.deg(math.atan(prop.dx or 0, prop.dy or 1)) end
        x, z = x + (prop.dx or 0) * 0.48, z + (prop.dy or 0) * 0.48
    elseif blueprint.mount == "wallHigh" then
        mountY = 2.50
        if prop.dx or prop.dy then yaw = math.deg(math.atan(prop.dx or 0, prop.dy or 1)) end
        x, z = x + (prop.dx or 0) * 0.48, z + (prop.dy or 0) * 0.48
    end

    local scale = prop.scale or 1
    local yawRadians = math.rad(yaw)
    for _, part in ipairs(blueprint.parts) do
        local ox, oz = RotateOffset(part.x * scale, part.z * scale, yawRadians)
        local key = part.model .. "|" .. part.material
        local batch = batches[key]
        if not batch then
            batch = { model = part.model, material = part.material, transforms = {} }
            batches[key] = batch
        end
        batch.transforms[#batch.transforms + 1] = {
            x = x + ox,
            y = baseY + mountY + part.y * scale,
            z = z + oz,
            sx = part.sx * scale,
            sy = part.sy * scale,
            sz = part.sz * scale,
            rotation = Quaternion(part.rx, yaw + part.ry, part.rz),
        }
    end
    return blueprint.light
end

function NativeDungeonRenderer:FlushBlueprints(parent, batches, materials)
    local keys = {}
    for key in pairs(batches) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local batch = batches[key]
        self:AddModelBatch(parent, batch.transforms, self.modelCache:Get(batch.model),
            materials[batch.material], "Props-" .. batch.model .. "-" .. batch.material, true)
    end
end

function NativeDungeonRenderer:AddHospitalBed(parent, name, position, yaw, materials)
    local bed = parent:CreateChild(name)
    bed.position = position
    bed.rotation = Quaternion(yaw or 0, Vector3.UP)
    self:AddPrimitive(bed, "Frame", "Models/Box.mdl", Vector3(0, 0.35, 0), Vector3(0.82, 0.12, 1.92), materials.metal)
    self:AddPrimitive(bed, "Mattress", "Models/Box.mdl", Vector3(0, 0.49, 0), Vector3(0.76, 0.18, 1.72), materials.cloth)
    self:AddPrimitive(bed, "Pillow", "Models/Box.mdl", Vector3(0, 0.62, -0.62), Vector3(0.52, 0.15, 0.34), materials.white)
    self:AddPrimitive(bed, "Headboard", "Models/Box.mdl", Vector3(0, 0.76, -0.92), Vector3(0.86, 0.78, 0.08), materials.metal)
    self:AddPrimitive(bed, "RailL", "Models/Box.mdl", Vector3(-0.45, 0.72, 0.18), Vector3(0.05, 0.36, 1.10), materials.metal)
    self:AddPrimitive(bed, "RailR", "Models/Box.mdl", Vector3(0.45, 0.72, 0.18), Vector3(0.05, 0.36, 1.10), materials.metal)
end

function NativeDungeonRenderer:AddHospitalDetails(root, dungeon, floorVisible, theme)
    local materials = {
        metal = CreateMaterial(theme.pillar, 0.46, 0.76),
        cloth = CreateMaterial(MixHex(theme.floor, 0xffffff, 0.46), 0.82, 0.0),
        white = CreateMaterial(MixHex(theme.wall, 0xffffff, 0.70), 0.34, 0.0),
        teal = CreateMaterial(theme.accentObject, 0.38, 0.18, MixHex(theme.accentObject, 0x000000, 0.52)),
        dark = CreateMaterial(MixHex(theme.wall, 0x121719, 0.58), 0.56, 0.28),
        rubber = ResourceMaterial("uuid://AkBCiS2MNfpI1vQqS6idJev_", CreateMaterial(0x24292b, 0.88, 0.0)),
    }

    for _, room in ipairs(dungeon.rooms) do
        if floorVisible(room.floor) and room.w >= 6 and room.h >= 6 then
            local x, y, z = self:WorldPosition(dungeon, room.cx, room.cy, room.floor, 0)
            local horizontal = room.w >= room.h
            local yaw = horizontal and 90 or 0
            local offsetX = horizontal and 0 or math.min(1.35, room.w * 0.18)
            local offsetZ = horizontal and math.min(1.35, room.h * 0.18) or 0
            self:AddHospitalBed(root, "HospitalBed-" .. room.id .. "-A",
                Vector3(x - offsetX, y, z - offsetZ), yaw, materials)
            if math.min(room.w, room.h) >= 9 then
                self:AddHospitalBed(root, "HospitalBed-" .. room.id .. "-B",
                    Vector3(x + offsetX, y, z + offsetZ), yaw, materials)
            end

            if room.id % 3 == 0 then
                local cabinet = root:CreateChild("MedCabinet-" .. room.id)
                cabinet.position = Vector3(x + (horizontal and 0 or 2.0), y, z + (horizontal and 2.0 or 0))
                self:AddPrimitive(cabinet, "Cabinet", "Models/Box.mdl", Vector3(0, 0.78, 0),
                    Vector3(0.75, 1.55, 0.38), materials.white)
                self:AddPrimitive(cabinet, "Glass", "Models/Box.mdl", Vector3(0, 0.92, -0.205),
                    Vector3(0.58, 0.92, 0.03), materials.teal, nil, false)
            end

            if room.id % 4 == 0 then
                local cart = root:CreateChild("Gurney-" .. room.id)
                cart.position = Vector3(x, y, z)
                cart.rotation = Quaternion(yaw + 90, Vector3.UP)
                self:AddPrimitive(cart, "Top", "Models/Box.mdl", Vector3(0, 0.68, 0), Vector3(0.64, 0.12, 1.35), materials.cloth)
                self:AddPrimitive(cart, "Frame", "Models/Box.mdl", Vector3(0, 0.48, 0), Vector3(0.54, 0.08, 1.28), materials.metal)
                for wheel = -1, 1, 2 do
                    self:AddPrimitive(cart, "WheelL" .. wheel, "Models/Cylinder.mdl", Vector3(-0.31, 0.18, wheel * 0.46),
                        Vector3(0.16, 0.08, 0.16), materials.rubber, Quaternion(90, Vector3.FORWARD))
                    self:AddPrimitive(cart, "WheelR" .. wheel, "Models/Cylinder.mdl", Vector3(0.31, 0.18, wheel * 0.46),
                        Vector3(0.16, 0.08, 0.16), materials.rubber, Quaternion(90, Vector3.FORWARD))
                end
            end

            if room.id % 5 == 0 then
                local lamp = root:CreateChild("SurgicalLamp-" .. room.id)
                lamp.position = Vector3(x, y, z)
                self:AddPrimitive(lamp, "Stand", "Models/Cylinder.mdl", Vector3(0, 1.25, 0),
                    Vector3(0.08, 2.5, 0.08), materials.metal)
                self:AddPrimitive(lamp, "Shade", "Models/Cone.mdl", Vector3(0, 2.45, 0),
                    Vector3(0.62, 0.28, 0.62), materials.white, Quaternion(180, Vector3.RIGHT))
                self:AddPointLight(lamp, "ClinicalLight", Vector3(0, 2.25, 0), Color(0.75, 1.0, 0.96), 2.2, 5.5, false)
            end
        end
    end
end

function NativeDungeonRenderer:AddThemeDetails(root, dungeon, theme, themeKey, floorVisible)
    local accent = theme.accentObject
    local darkStone = CreateMaterial(MixHex(theme.wall, 0x15191f, 0.42), 0.92, 0.02)
    local accentMaterial = CreateMaterial(accent, 0.35, 0.08, accent)
    local transparentAccent = Material:new()
    transparentAccent:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    transparentAccent:SetShaderParameter("MatDiffColor", Variant(HexColor(accent, 1.0, 0.68)))
    transparentAccent:SetShaderParameter("MatEmissiveColor", Variant(HexColor(accent, 1.4)))
    transparentAccent:SetShaderParameter("Roughness", Variant(0.18))

    for _, room in ipairs(dungeon.rooms) do
        if floorVisible(room.floor) and room.id % 3 == 0 then
            local x, y, z = self:WorldPosition(dungeon, room.cx, room.cy, room.floor, 0)
            if themeKey == "molten" then
                self:AddPrimitive(root, "LavaPool-" .. room.id, "Models/Cylinder.mdl", Vector3(x, y + 0.025, z),
                    Vector3(math.min(3.2, room.w * 0.28), 0.05, math.min(3.2, room.h * 0.28)), transparentAccent, nil, false)
            elseif themeKey == "frost" then
                self:AddPrimitive(root, "IceLake-" .. room.id, "Models/Cylinder.mdl", Vector3(x, y + 0.035, z),
                    Vector3(math.min(3.0, room.w * 0.26), 0.07, math.min(3.0, room.h * 0.26)), transparentAccent, nil, false)
                self:AddPrimitive(root, "IceSpire-" .. room.id, "Models/Cone.mdl", Vector3(x + 1.1, y + 0.9, z - 0.8),
                    Vector3(0.42, 1.8, 0.42), accentMaterial)
            elseif themeKey == "grim" then
                for index = -1, 1 do
                    self:AddPrimitive(root, "Grave-" .. room.id .. "-" .. index, "Models/Box.mdl",
                        Vector3(x + index * 0.72, y + 0.48, z), Vector3(0.38, 0.95, 0.16), darkStone,
                        Quaternion(index * 5, Vector3.FORWARD))
                end
            elseif themeKey == "verdant" then
                self:AddPrimitive(root, "Moss-" .. room.id, "Models/Sphere.mdl", Vector3(x, y + 0.04, z),
                    Vector3(math.min(2.4, room.w * 0.22), 0.10, math.min(2.4, room.h * 0.22)), transparentAccent, nil, false)
                self:AddPrimitive(root, "Root-" .. room.id, "Models/Cylinder.mdl", Vector3(x + 0.8, y + 0.3, z - 0.7),
                    Vector3(0.18, 2.3, 0.18), darkStone, Quaternion(78, 0, 32))
            else
                self:AddPrimitive(root, "RuneStone-" .. room.id, "Models/Cylinder.mdl", Vector3(x, y + 0.12, z),
                    Vector3(0.72, 0.24, 0.72), darkStone)
                self:AddPrimitive(root, "RuneGlow-" .. room.id, "Models/Cylinder.mdl", Vector3(x, y + 0.25, z),
                    Vector3(0.32, 0.04, 0.32), accentMaterial, nil, false)
            end
        end
    end
end

function NativeDungeonRenderer:Build(dungeon, themeKey, options)
    local buildStarted = os.clock()
    self:Clear()
    self.selectionDungeon = dungeon
    options = options or {}
    local currentFloor = options.currentFloor or 0
    local viewMode = options.viewMode or "neighbors"
    local settingKey = options.settingKey or "dungeon"
    local verticalScale = dungeon.floorHeight / MultiFloor.SOURCE_FLOOR_HEIGHT
    self.floorSpacing = viewMode == "explode" and 2.2 or 1
    local function FloorVisible(floor)
        if viewMode == "current" then return floor == currentFloor end
        if viewMode == "neighbors" then return math.abs(floor - currentFloor) <= 1 end
        return true
    end
    local animate = options.animate == true
    local timeline = animate and CreateBuildTimeline(dungeon, FloorVisible) or nil
    local stagingConfig = animate and { timeline = timeline } or nil
    local deferredComponents = {}
    local function Defer(object, showTime)
        if not animate or not object then return end
        object.enabled = false
        deferredComponents[#deferredComponents + 1] = {
            object = object, showTime = showTime or timeline.total, shown = false,
        }
    end
    local theme = Themes.Resolve(settingKey, themeKey)
    local root = self.scene:CreateChild("GeneratedDungeon")
    self.root = root

    local floorMaterial = CreateMaterial(theme.floor, 0.9, 0.02)
    local corridorMaterial = CreateMaterial(theme.corridor, 0.82, 0.03)
    local wallMaterial = CreateMaterial(theme.wall, 0.78, 0.04)
    local pillarMaterial = CreateMaterial(theme.pillar, 0.72, 0.06)
    local stairMaterial = CreateMaterial(theme.corridor, 0.68, 0.08)
    if settingKey == "hospital" then
        -- 医院色调同样使用动态 PBR 配色。固定贴图材质会吞掉冷白/灰绿/警示红的差异。
        floorMaterial = CreateMaterial(theme.floor, 0.62, 0.02)
        corridorMaterial = CreateMaterial(theme.corridor, 0.70, 0.03)
        wallMaterial = CreateMaterial(theme.wall, 0.76, 0.02)
        pillarMaterial = CreateMaterial(theme.pillar, 0.44, 0.68)
        stairMaterial = CreateMaterial(theme.corridor, 0.56, 0.22)
    elseif settingKey == "school" then
        floorMaterial = CreateMaterial(theme.floor, 0.48, 0.01)
        corridorMaterial = CreateMaterial(theme.corridor, 0.54, 0.02)
        wallMaterial = CreateMaterial(theme.wall, 0.86, 0.0)
        pillarMaterial = CreateMaterial(theme.pillar, 0.42, 0.58)
        stairMaterial = CreateMaterial(theme.corridor, 0.50, 0.10)
    end
    local torchMaterial = CreateMaterial(theme.flameCore, 0.24, 0, theme.flame)
    local propMaterials = CreatePropMaterials(theme)
    local propBatches = {}
    local exact = ExactGeometryBatcher.new(dungeon, theme, settingKey)
    local exactRng = Random.new(dungeon.seed ~ 0x9e3779b9)
    local torchLightCount = 0
    local propLightCount = 0

    for _, layer in ipairs(dungeon.layers) do
        if FloorVisible(layer.floor) then
        exact:SetBuildLayer(layer)
        exact:QueueStructure(layer, self.floorSpacing)
        for _, prop in ipairs(layer.props) do
            local x, baseY, z = self:WorldPosition(dungeon, prop.x, prop.y, layer.floor, 0)
            local emitsLight = exact:QueueProp(layer, prop, self.floorSpacing, exactRng)
            if emitsLight and propLightCount < 18 then
                propLightCount = propLightCount + 1
                self:AddPointLight(root, "PropLight-" .. layer.floor .. "-" .. propLightCount,
                    Vector3(x, baseY + 1.0 * verticalScale, z), HexColor(theme.accentObject, 1.0), 2.4, 6.2,
                    settingKey == "dungeon")
            end
        end
        for _, spawn in ipairs(layer.spawns) do
            exact:QueueSpawn(layer, spawn, self.floorSpacing, exactRng)
        end
        for torchIndex, torch in ipairs(layer.torches) do
            local tx, ty, tz = exact:QueueTorch(layer, torch, self.floorSpacing)
            if torchIndex % 2 == 1 and torchLightCount < 18 then
                torchLightCount = torchLightCount + 1
                local torchSpec = theme.torchLight or { settingKey == "hospital" and 0xbfe9e3 or 0xffa640, 1.5, 9.5 }
                self:AddPointLight(root, "TorchLight-" .. layer.floor .. "-" .. torchIndex,
                    Vector3(tx, ty, tz), HexColor(torchSpec[1], 1.0), torchSpec[2], torchSpec[3])
            end
        end
        for _, arch in ipairs(layer.arches or {}) do exact:QueueArch(layer, arch, self.floorSpacing) end
        end
    end
    local exactInstances, exactBatches, stagedEntries = exact:Flush(root, stagingConfig)
    self.instanceCount = self.instanceCount + exactInstances
    self.batchCount = self.batchCount + exactBatches
    if options.roomGroupsVisible then
        self:AddRoomGroupHighlights(root, dungeon, FloorVisible, options.roomGroups)
    end

    local stairs = {}
    local stairRailMaterial = CreateMaterial(theme.pillar, 0.38, 0.72)
    local stairFinishMaterial = CreateMaterial(theme.wall, 0.78, 0.08)
    local stairRailRoot = root:CreateChild("StairProtection")
    -- Stair rail/finish/post elevations are already actual meters (derived from
    -- connector.rise/stepRise), so add them onto the floor base directly instead
    -- of routing through WorldPosition's localY scaling (matches tread placement).
    local function StairWorld(connector, gridX, gridY, elevation)
        local wx, baseY, wz = self:WorldPosition(dungeon, gridX, gridY, connector.fromFloor, 0)
        return Vector3(wx, baseY + (elevation or 0), wz)
    end
    for _, connector in ipairs(dungeon.connectors) do
        if FloorVisible(connector.fromFloor) or FloorVisible(connector.toFloor) then
            local globalStep = 0
            local function AddFlight(startPoint, direction, run, count)
                if not startPoint or not direction or count <= 0 or run <= 0 then return end
                local treadDepth = run / count
                for step = 0, count - 1 do
                    globalStep = globalStep + 1
                    local distance = (step + 0.5) * treadDepth
                    local gridX = startPoint.x + direction.x * distance
                    local gridY = startPoint.y + direction.y * distance
                    local x, baseY, z = self:WorldPosition(dungeon, gridX, gridY, connector.fromFloor, 0)
                    local stepTop = globalStep * connector.stepRise
                    Push(stairs, x, baseY + stepTop * 0.5, z,
                        direction.x == 0 and connector.width or treadDepth,
                        stepTop,
                        direction.y == 0 and connector.width or treadDepth)
                end
            end
            local platform = MultiFloor.StairTurnPlatformMetrics(connector)
            local firstStart = platform and platform.first.start
                or MultiFloor.StairRunCenter(connector.lower, connector.directionVector,
                    connector.width, connector.lateralCenterOffset)
            AddFlight(firstStart, connector.directionVector,
                connector.firstRun or connector.length, connector.firstFlightSteps or connector.stepCount)
            if platform then
                local landingThickness = 0.16 * verticalScale
                local x, baseY, z = self:WorldPosition(dungeon,
                    platform.center.x, platform.center.y, connector.fromFloor, 0)
                local surfaceY = (connector.firstFlightSteps or 0) * connector.stepRise
                Push(stairs, x, baseY + surfaceY - landingThickness * 0.5,
                    z, platform.visualSpan, landingThickness, platform.visualSpan)
            end
            AddFlight(platform and platform.second.start or nil, connector.secondDirectionVector,
                connector.secondRun or 0, connector.secondFlightSteps or 0)

            local stairPlan = StairRenderPlan.Build(dungeon, connector)
            for index, beam in ipairs(stairPlan.beams) do
                local a = StairWorld(connector, beam.a.x, beam.a.y, beam.aElev)
                local b = StairWorld(connector, beam.b.x, beam.b.y, beam.bElev)
                local node = self:AddSlopedBeam(stairRailRoot, "StairRail-" .. connector.id .. "-" .. index,
                    a, b, stairRailMaterial, beam.crossW, beam.crossH)
                if node then Defer(node:GetComponent("StaticModel"), timeline and timeline.rooms.start) end
            end
            for index, post in ipairs(stairPlan.posts) do
                local base = StairWorld(connector, post.x, post.y, post.baseElev)
                local node = self:AddPostBox(stairRailRoot, "StairPost-" .. connector.id .. "-" .. index,
                    base, post.height, post.thickness, stairRailMaterial)
                if node then Defer(node:GetComponent("StaticModel"), timeline and timeline.rooms.start) end
            end
            for index, finish in ipairs(stairPlan.wallFinishes) do
                local a = StairWorld(connector, finish.a.x, finish.a.y, finish.aElev)
                local b = StairWorld(connector, finish.b.x, finish.b.y, finish.bElev)
                local node = self:AddSlopedBeam(stairRailRoot, "StairFinish-" .. connector.id .. "-" .. index,
                    a, b, stairFinishMaterial, finish.crossW, finish.crossH)
                if node then Defer(node:GetComponent("StaticModel"), timeline and timeline.rooms.start) end
            end
            local stairLightSpec = theme.torchLight or { theme.flameCore, 1.1, 7.0 }
            for index, anchor in ipairs(stairPlan.lightingAnchors) do
                local lx, ly, lz = self:WorldPosition(dungeon, anchor.x, anchor.y,
                    connector.fromFloor, anchor.elevation)
                self:AddPointLight(root, "StairLight-" .. connector.id .. "-" .. index,
                    Vector3(lx, ly, lz), HexColor(stairLightSpec[1], 1.0),
                    stairLightSpec[2], stairLightSpec[3], settingKey == "dungeon")
            end
        end
    end
    local stairGroup = self:AddBatch(root, stairs, stairMaterial, "Stairs")
    Defer(stairGroup, timeline and timeline.rooms.start)

    if options.heatVisible then
        for _, room in ipairs(dungeon.rooms) do
            if FloorVisible(room.floor) then
                local heat = room.difficulty >= 0.72 and 0xe54e3e or (room.difficulty >= 0.4 and 0xe5a43e or 0x45c79c)
                local x, y, z = self:WorldPosition(dungeon, room.cx, room.cy, room.floor, 0.10)
                local marker = self:AddMarker(root, "Heat-" .. room.id, x, y, z, heat,
                    Vector3(math.max(0.35, room.w * 0.10), 0.05, math.max(0.35, room.h * 0.10)))
                Defer(marker, timeline and timeline.rooms.start)
            end
        end
    end

    if options.graphVisible then
        local material = CreateMaterial(0x55d8ce, 0.28, 0.08, 0x2a8f88)
        for _, edge in ipairs(dungeon.edges) do
            local roomA, roomB = dungeon.rooms[edge.a], dungeon.rooms[edge.b]
            if roomA and roomB and (FloorVisible(roomA.floor) or FloorVisible(roomB.floor)) then
                local ax, ay, az = self:WorldPosition(dungeon, roomA.cx, roomA.cy, roomA.floor, 0.26)
                local bx, by, bz = self:WorldPosition(dungeon, roomB.cx, roomB.cy, roomB.floor, 0.26)
                local graphNode = self:AddBeam(root, "Graph-" .. edge.id,
                    Vector3(ax, ay, az), Vector3(bx, by, bz), material,
                    edge.isCritical and 0.14 or 0.08)
                Defer(graphNode, timeline and (timeline.structure.start + 0.34 * timeline.timeScale))
            end
        end
    end

    local buildMs = (os.clock() - buildStarted) * 1000
    self.lastBuildMetrics = {
        buildMs = buildMs, batches = self.batchCount, instances = self.instanceCount, animate = animate,
        stagedBatches = #(stagedEntries or {}), materialAnimatedBatches = 0,
    }
    if animate then
        for _, entry in ipairs(self.dynamicLights) do entry.light.brightness = 0 end
        self.animation = {
            elapsed = 0, duration = timeline.total, timeline = timeline,
            stagedEntries = stagedEntries or {}, deferredComponents = deferredComponents,
            overlay = self:CreateBuildOverlay(dungeon, FloorVisible, timeline),
            updateTotalMs = 0, updateMaxMs = 0, frames = 0, buildMs = buildMs,
        }
        self.lastBuildMetrics.overlayRooms = #self.animation.overlay.rooms
        self.lastBuildMetrics.overlayBeams = #self.animation.overlay.beams
        print(string.format("[BuildAnimation] started duration=%.2fs stagedBatches=%d materialAnimation=false",
            timeline.total, #(stagedEntries or {})))
    end
    self:RefreshEditorSelection()
    print(string.format("[NativeRenderer] batches=%d instances=%d build=%.1fms animate=%s",
        self.batchCount, self.instanceCount, buildMs, tostring(animate)))
    return root
end

function NativeDungeonRenderer:Update(timeStep)
    local updateStarted = os.clock()
    self.elapsed = self.elapsed + timeStep
    local lightRamp = 1
    if self.animation then
        self.animation.elapsed = self.animation.elapsed + timeStep
        for _, entry in ipairs(self.animation.stagedEntries) do
            if not entry.shown and self.animation.elapsed >= entry.showTime then
                entry.object.enabled = true
                entry.shown = true
            end
        end
        for _, entry in ipairs(self.animation.deferredComponents) do
            if not entry.shown and self.animation.elapsed >= entry.showTime then
                entry.object.enabled = true
                entry.shown = true
            end
        end
        lightRamp = Phase(self.animation.elapsed,
            self.animation.timeline.atmosphere.start, self.animation.timeline.atmosphere.finish)
        self:UpdateBuildOverlay(self.animation)
    end
    for _, entry in ipairs(self.dynamicLights) do
        local flicker = 1
        if entry.flicker then
            flicker = 0.90 + math.sin(self.elapsed * 7.3 + entry.phase) * 0.07
                + math.sin(self.elapsed * 13.1 + entry.phase * 0.37) * 0.03
        end
        entry.light.brightness = entry.base * flicker * lightRamp
    end
    if self.animation then
        local animation = self.animation
        local updateMs = (os.clock() - updateStarted) * 1000
        animation.frames = animation.frames + 1
        animation.updateTotalMs = animation.updateTotalMs + updateMs
        animation.updateMaxMs = math.max(animation.updateMaxMs, updateMs)
        if animation.elapsed >= animation.duration then
            for _, entry in ipairs(animation.stagedEntries) do entry.object.enabled = true end
            for _, entry in ipairs(animation.deferredComponents) do entry.object.enabled = true end
            if animation.overlay and not animation.overlay.removed then
                animation.overlay.root:Remove()
                animation.overlay.removed = true
            end
            for _, entry in ipairs(self.dynamicLights) do entry.light.brightness = entry.base end
            local average = animation.frames > 0 and animation.updateTotalMs / animation.frames or 0
            self.lastAnimationMetrics = {
                duration = animation.elapsed, frames = animation.frames,
                averageUpdateMs = average, maxUpdateMs = animation.updateMaxMs,
                buildMs = animation.buildMs,
            }
            print(string.format(
                "[BuildAnimation] completed duration=%.2fs frames=%d avgUpdate=%.3fms maxUpdate=%.3fms build=%.1fms",
                animation.elapsed, animation.frames, average, animation.updateMaxMs, animation.buildMs))
            self.animation = nil
        end
    end
end

return NativeDungeonRenderer
