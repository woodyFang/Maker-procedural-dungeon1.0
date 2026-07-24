local UI = require("urhox-libs/UI")

local CameraPreviewController = {}
CameraPreviewController.__index = CameraPreviewController

local TILE_FLOOR = 1
local TRANSITION_SECONDS = 0.72
local WALK_SPEED = 3.2
local RUN_SPEED = 4.8
local THIRD_DISTANCE = 12.5
-- Diablo-style action-RPG framing: a ~50° look-down angle keeps the floor
-- readable while giving the character a less elevated third-person view.
-- The pitch window allows slight adjustment without leaving that framing.
local THIRD_PITCH = math.rad(50)
local THIRD_PITCH_MIN = 0.78
local THIRD_PITCH_MAX = 1.22
local THIRD_DISTANCE_MIN = 9
local THIRD_DISTANCE_MAX = 20
local FIRST_PERSON_EYE_HEIGHT = 0.92
local SAMPLE_RADIUS = 0.26
local MAX_SURFACE_DISCONTINUITY = 0.65
local MOVEMENT_SUBSTEP = 0.20
local STAIR_EPSILON = 0.001

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function IsPhysicalKeyDown(key, scancode)
    return input:GetScancodeDown(scancode) or input:GetKeyDown(key)
end

local function SmoothStep(value)
    return value * value * (3 - 2 * value)
end

local function HexColor(value, brightness, alpha)
    local factor = brightness or 1
    return Color(
        math.min(1, ((value >> 16) & 0xff) / 255 * factor),
        math.min(1, ((value >> 8) & 0xff) / 255 * factor),
        math.min(1, (value & 0xff) / 255 * factor),
        alpha or 1
    )
end

local function CreateMaterial(color, roughness, metallic, emissive, alpha)
    local material = Material:new()
    local technique = alpha and "Techniques/PBR/PBRNoTextureAlpha.xml" or "Techniques/PBR/PBRNoTexture.xml"
    material:SetTechnique(0, cache:GetResource("Technique", technique))
    material:SetShaderParameter("MatDiffColor", Variant(HexColor(color, 1, alpha or 1)))
    material:SetShaderParameter("MatSpecColor", Variant(Color(0.35, 0.35, 0.35, 1)))
    material:SetShaderParameter("Roughness", Variant(roughness or 0.72))
    material:SetShaderParameter("Metallic", Variant(metallic or 0.08))
    if emissive then
        material:SetShaderParameter("MatEmissiveColor", Variant(HexColor(emissive, 1.2)))
    end
    return material
end

local function AddPart(parent, name, model, position, scale, material, rotation)
    local node = parent:CreateChild(name)
    node.position = position
    node.scale = scale
    if rotation then node.rotation = rotation end
    local staticModel = node:CreateComponent("StaticModel")
    staticModel:SetModel(model)
    staticModel:SetMaterial(material)
    staticModel.castShadows = true
    return node
end

local function ResolveModel(renderer, key, fallbackPath)
    local cacheObject = renderer and renderer.modelCache
    local model = cacheObject and cacheObject:Get(key)
    if model then return model end
    return cache:GetResource("Model", fallbackPath or ("Models/" .. key .. ".mdl"))
end

function CameraPreviewController.new(scene, dungeonRenderer, cameraNode, callbacks)
    local self = setmetatable({
        scene = scene,
        dungeonRenderer = dungeonRenderer,
        cameraNode = cameraNode,
        callbacks = callbacks or {},
        phase = "idle",
        mode = nil,
        floor = 0,
        yaw = math.pi * 0.25,
        orbitPitch = THIRD_PITCH,
        lookPitch = 0,
        distance = THIRD_DISTANCE,
        transition = 0,
        moving = false,
        elapsed = 0,
    }, CameraPreviewController)
    self:CreateCharacter()
    return self
end

function CameraPreviewController:CreateCharacter()
    self.root = self.scene:CreateChild("CameraPreview")
    self.character = self.root:CreateChild("PreviewCharacter")
    self.thirdPersonRoot = self.character:CreateChild("ThirdPersonVisual")
    self.visual = self.thirdPersonRoot:CreateChild("CharacterVisual")
    self.visual.scale = Vector3(0.74, 0.74, 0.74)
    self.visual.rotation = Quaternion(180, Vector3.UP)

    local model = function(key, fallback)
        return ResolveModel(self.dungeonRenderer, key, fallback)
    end
    local armor = CreateMaterial(0x202938, 0.30, 0.76)
    local armorEdge = CreateMaterial(0x64758a, 0.22, 0.90)
    local cloth = CreateMaterial(0x291537, 0.78, 0.06)
    local skin = CreateMaterial(0xb78368, 0.68, 0.10)
    local steel = CreateMaterial(0xbac9da, 0.18, 0.92)
    local gold = CreateMaterial(0xc6812c, 0.32, 0.78)
    local heraldry = CreateMaterial(0x8e2430, 0.62, 0.18)
    local glow = CreateMaterial(0x35d9ff, 0.28, 0.08, 0x35d9ff)
    local glowWarm = CreateMaterial(0xff6333, 0.30, 0.12, 0xff4a24)
    cloth.cullMode = CULL_NONE

    self.rig = self.visual:CreateChild("ArmorRig")
    self.rig.position = Vector3(0, 0.04, 0)

    -- Human silhouette: broad chest, narrow abdomen and armored pelvis.
    AddPart(self.rig, "Pelvis", model("roundedBox"), Vector3(0, 0.52, 0),
        Vector3(0.62, 0.24, 0.46), armorEdge)
    AddPart(self.rig, "Abdomen", model("roundedBox"), Vector3(0, 0.72, 0),
        Vector3(0.50, 0.30, 0.37), armor)
    AddPart(self.rig, "Chest", model("roundedBox"), Vector3(0, 0.98, 0),
        Vector3(0.76, 0.46, 0.50), armor)
    AddPart(self.rig, "ChestPlate", model("roundedBox"), Vector3(0, 1.02, -0.29),
        Vector3(0.59, 0.50, 0.12), armorEdge)
    AddPart(self.rig, "ChestInset", model("box"), Vector3(0, 1.02, -0.40),
        Vector3(0.38, 0.29, 0.045), armor)
    self.core = AddPart(self.rig, "ChestCore", model("octahedron"), Vector3(0, 1.03, -0.47),
        Vector3(0.16, 0.25, 0.10), glow)
    AddPart(self.rig, "WaistSeal", model("torus"), Vector3(0, 0.59, 0),
        Vector3(0.50, 0.08, 0.38), gold)
    AddPart(self.rig, "Collar", model("torus"), Vector3(0, 1.23, 0),
        Vector3(0.47, 0.08, 0.38), gold)

    -- Rounded great-helm silhouette: no cone tip, only a low crest ridge.
    AddPart(self.rig, "Head", model("sphere", "Models/Sphere.mdl"), Vector3(0, 1.57, 0),
        Vector3(0.36, 0.38, 0.34), skin)
    AddPart(self.rig, "HelmetDome", model("sphere", "Models/Sphere.mdl"), Vector3(0, 1.79, 0),
        Vector3(0.45, 0.34, 0.42), armor)
    AddPart(self.rig, "HelmetBrim", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, 1.69, 0),
        Vector3(0.48, 0.10, 0.45), armorEdge)
    AddPart(self.rig, "Visor", model("roundedBox"), Vector3(0, 1.70, -0.31),
        Vector3(0.33, 0.09, 0.08), steel)
    AddPart(self.rig, "Crest", model("roundedBox"), Vector3(0, 1.98, 0.04),
        Vector3(0.07, 0.10, 0.28), gold)
    AddPart(self.rig, "CrestGem", model("octahedron"), Vector3(0, 1.91, -0.28),
        Vector3(0.09, 0.12, 0.07), glowWarm)

    -- Shoulder pivots now carry actual upper arms, elbows, gauntlets and hands.
    self.shoulderL = self.rig:CreateChild("ShoulderL")
    self.shoulderL.position = Vector3(-0.57, 1.20, 0)
    AddPart(self.shoulderL, "Pauldron", model("roundedBox"), Vector3(0, 0.02, 0),
        Vector3(0.43, 0.22, 0.52), armorEdge, Quaternion(-8, Vector3.FORWARD))
    AddPart(self.shoulderL, "ShoulderRivet", model("sphere", "Models/Sphere.mdl"),
        Vector3(-0.12, 0.10, -0.12), Vector3(0.10, 0.10, 0.10), gold)
    AddPart(self.shoulderL, "UpperArm", model("roundedBox"), Vector3(0, -0.19, 0.02),
        Vector3(0.18, 0.36, 0.20), armor)
    self.elbowL = self.shoulderL:CreateChild("ElbowL")
    self.elbowL.position = Vector3(0, -0.39, -0.02)
    AddPart(self.elbowL, "ElbowJoint", model("sphere", "Models/Sphere.mdl"),
        Vector3(0, 0, -0.03), Vector3(0.14, 0.14, 0.14), armorEdge)
    AddPart(self.elbowL, "Forearm", model("roundedBox"), Vector3(0, -0.17, -0.07),
        Vector3(0.16, 0.32, 0.18), armor)
    self.handL = self.elbowL:CreateChild("GauntletL")
    self.handL.position = Vector3(0, -0.36, -0.11)
    AddPart(self.handL, "Gauntlet", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.22, 0.18, 0.24), steel)

    self.shoulderR = self.rig:CreateChild("ShoulderR")
    self.shoulderR.position = Vector3(0.57, 1.20, 0)
    AddPart(self.shoulderR, "Pauldron", model("roundedBox"), Vector3(0, 0.02, 0),
        Vector3(0.43, 0.22, 0.52), armorEdge, Quaternion(8, Vector3.FORWARD))
    AddPart(self.shoulderR, "ShoulderRivet", model("sphere", "Models/Sphere.mdl"),
        Vector3(0.12, 0.10, -0.12), Vector3(0.10, 0.10, 0.10), gold)
    AddPart(self.shoulderR, "UpperArm", model("roundedBox"), Vector3(0, -0.19, 0.02),
        Vector3(0.18, 0.36, 0.20), armor)
    self.elbowR = self.shoulderR:CreateChild("ElbowR")
    self.elbowR.position = Vector3(0, -0.39, -0.02)
    AddPart(self.elbowR, "ElbowJoint", model("sphere", "Models/Sphere.mdl"),
        Vector3(0, 0, -0.03), Vector3(0.14, 0.14, 0.14), armorEdge)
    AddPart(self.elbowR, "Forearm", model("roundedBox"), Vector3(0, -0.17, -0.07),
        Vector3(0.16, 0.32, 0.18), armor)
    self.handR = self.elbowR:CreateChild("GauntletR")
    self.handR.position = Vector3(0, -0.36, -0.11)
    AddPart(self.handR, "Gauntlet", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.22, 0.18, 0.24), steel)

    -- Articulated legs: thigh, knee, shin and boot instead of one long greave.
    self.legL = self.rig:CreateChild("LegL")
    self.legL.position = Vector3(-0.19, 0.76, 0)
    AddPart(self.legL, "Thigh", model("roundedBox"), Vector3(0, -0.16, 0),
        Vector3(0.30, 0.34, 0.31), armor)
    self.kneeL = self.legL:CreateChild("KneeL")
    self.kneeL.position = Vector3(0, -0.35, -0.02)
    AddPart(self.kneeL, "KneeCap", model("sphere", "Models/Sphere.mdl"), Vector3(0, 0, -0.04),
        Vector3(0.18, 0.16, 0.14), armorEdge)
    local shinL = self.kneeL:CreateChild("ShinL")
    AddPart(shinL, "Shin", model("roundedBox"), Vector3(0, -0.18, 0),
        Vector3(0.25, 0.36, 0.27), armor)
    AddPart(shinL, "Boot", model("roundedBox"), Vector3(0, -0.16, -0.10),
        Vector3(0.30, 0.16, 0.42), steel)

    self.legR = self.rig:CreateChild("LegR")
    self.legR.position = Vector3(0.19, 0.76, 0)
    AddPart(self.legR, "Thigh", model("roundedBox"), Vector3(0, -0.16, 0),
        Vector3(0.30, 0.34, 0.31), armor)
    self.kneeR = self.legR:CreateChild("KneeR")
    self.kneeR.position = Vector3(0, -0.35, -0.02)
    AddPart(self.kneeR, "KneeCap", model("sphere", "Models/Sphere.mdl"), Vector3(0, 0, -0.04),
        Vector3(0.18, 0.16, 0.14), armorEdge)
    local shinR = self.kneeR:CreateChild("ShinR")
    AddPart(shinR, "Shin", model("roundedBox"), Vector3(0, -0.18, 0),
        Vector3(0.25, 0.36, 0.27), armor)
    AddPart(shinR, "Boot", model("roundedBox"), Vector3(0, -0.16, -0.10),
        Vector3(0.30, 0.16, 0.42), steel)

    -- Right hand holds the sword instead of leaving it floating beside the rig.
    self.weapon = self.handR:CreateChild("KnightSword")
    self.weapon.position = Vector3(0, -0.08, 0.03)
    self.weapon.rotation = Quaternion(-8, Vector3.FORWARD)
    AddPart(self.weapon, "Guard", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.38, 0.07, 0.12), gold)
    AddPart(self.weapon, "Grip", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, -0.18, 0),
        Vector3(0.08, 0.28, 0.08), armor)
    AddPart(self.weapon, "Blade", model("box", "Models/Box.mdl"), Vector3(0, 0.44, 0),
        Vector3(0.14, 0.70, 0.10), steel)
    AddPart(self.weapon, "BladeCore", model("box", "Models/Box.mdl"), Vector3(0, 0.44, -0.065),
        Vector3(0.035, 0.61, 0.032), glowWarm)

    -- Left hand carries a layered heater shield with a visible heraldic cross.
    self.shield = self.handL:CreateChild("HeaterShield")
    self.shield.position = Vector3(-0.16, -0.02, -0.12)
    AddPart(self.shield, "ShieldFace", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.08, 0.46, 0.36), armorEdge)
    AddPart(self.shield, "ShieldTopTrim", model("roundedBox"), Vector3(-0.045, 0.20, -0.02),
        Vector3(0.05, 0.045, 0.38), gold)
    AddPart(self.shield, "ShieldBottomTrim", model("roundedBox"), Vector3(-0.045, -0.20, -0.02),
        Vector3(0.05, 0.045, 0.34), gold)
    AddPart(self.shield, "ShieldCrossV", model("roundedBox"), Vector3(-0.055, 0, -0.20),
        Vector3(0.025, 0.22, 0.035), heraldry)
    AddPart(self.shield, "ShieldCrossH", model("roundedBox"), Vector3(-0.055, 0, -0.20),
        Vector3(0.025, 0.035, 0.18), heraldry)
    AddPart(self.shield, "ShieldBoss", model("octahedron"), Vector3(-0.08, 0, -0.23),
        Vector3(0.10, 0.12, 0.10), gold)

    self.cloak = self.rig:CreateChild("Cloak")
    self.cloak.position = Vector3(0, 1.07, 0.32)
    AddPart(self.cloak, "CloakCloth", model("bannerCloth"), Vector3(0, -0.52, 0),
        Vector3(1.48, 1.48, 1), cloth)
    AddPart(self.cloak, "CloakSpine", model("cylinder", "Models/Cylinder.mdl"),
        Vector3(0, -0.43, 0.05), Vector3(0.06, 0.78, 0.06), gold)

    -- A fixed-pitch child lets the parent spin around Y without changing the
    -- ring's floor-parallel orientation.
    self.runeSpinner = self.rig:CreateChild("RuneSpinner")
    self.runeSpinner.position = Vector3(0, 1.12, 0)
    AddPart(self.runeSpinner, "RuneRing", model("ring"), Vector3(0, 0, 0),
        Vector3(0.48, 0.48, 0.48), glow, Quaternion(-90, Vector3.RIGHT))

    self.orbitRoot = self.rig:CreateChild("OrbitingRelics")
    self.orbiters = {}
    local orbitModels = { "octahedron", "icosahedron", "octahedron" }
    local orbitMaterials = { glow, glowWarm, glow }
    for index = 1, 3 do
        local orbiter = AddPart(self.orbitRoot, "Relic" .. index,
            model(orbitModels[index]), Vector3.ZERO, Vector3(0.12, 0.20, 0.12),
            orbitMaterials[index])
        self.orbiters[index] = { node = orbiter, phase = (index - 1) * 2.094, radius = 0.86 + index * 0.04 }
    end

    local marker = CreateMaterial(0xe5a35d, 0.35, 0.05, 0xe5a35d, 0.45)
    marker.cullMode = CULL_NONE
    AddPart(self.thirdPersonRoot, "GroundMarker", model("torus", "Models/Torus.mdl"),
        Vector3(0, 0.025, 0), Vector3(0.83, 0.18, 0.83), marker)
    self.running = false
    self.root:SetEnabled(false)
end

function CameraPreviewController:IsActive()
    return self.phase ~= "idle"
end

function CameraPreviewController:IsFirstPerson()
    return self:IsActive() and self.mode == "first"
end

function CameraPreviewController:WorldAt(gridX, gridY, floor, localY)
    local x, y, z = self.dungeonRenderer:WorldPosition(self.dungeon, gridX, gridY, floor, localY or 0)
    return Vector3(x, y, z)
end

function CameraPreviewController:FloorBaseY(gridX, gridY, floor)
    return self:WorldAt(gridX, gridY, floor, 0).y
end

function CameraPreviewController:BuildStairSurfaceIndex()
    self.stairSurfaces = {}
    self.stairDescents = {}
    if not self.dungeon then return end

    local function FloorMap(container, floor)
        container[floor] = container[floor] or {}
        return container[floor]
    end
    local function AddSurface(floor, cell, elevation, connector, kind, isTop)
        if not cell then return end
        local map = FloorMap(self.stairSurfaces, floor)
        if not map[cell] or (kind == "landing" and map[cell].kind ~= "landing") then
            map[cell] = {
                elevation = elevation or 0,
                connector = connector,
                kind = kind,
                isTop = isTop == true,
            }
        end
    end

    for _, connector in ipairs(self.dungeon.connectors or {}) do
        local lowerFloor = connector.fromFloor
        local upperFloor = connector.toFloor
        local elevationByCell = {}
        local maxElevation = -math.huge
        for _, item in ipairs(connector.sweptClearanceCells or {}) do
            local elevation = item.treadElevation or 0
            elevationByCell[item.cell] = elevation
            maxElevation = math.max(maxElevation, elevation)
        end
        for _, item in ipairs(connector.sweptClearanceCells or {}) do
            local elevation = item.treadElevation or 0
            AddSurface(lowerFloor, item.cell, elevation, connector, "tread",
                math.abs(elevation - maxElevation) <= STAIR_EPSILON)
        end
        for _, cell in ipairs(connector.lowerLandingCells or {}) do
            AddSurface(lowerFloor, cell, 0, connector, "landing")
        end
        for _, cell in ipairs(connector.upperLandingCells or {}) do
            AddSurface(upperFloor, cell, 0, connector, "landing")
        end

        -- The upper layer stores the slab opening as VOID. It is still a valid
        -- descent entry, but only when the corresponding lower-layer tread is
        -- present in the connector contract.
        local descentMap = FloorMap(self.stairDescents, upperFloor)
        for _, cell in ipairs(connector.openingCells or {}) do
            local elevation = elevationByCell[cell]
            if elevation ~= nil then
                descentMap[cell] = {
                    lowerFloor = lowerFloor,
                    elevation = elevation,
                    connector = connector,
                    kind = "descent",
                }
            end
        end
    end
end

function CameraPreviewController:ResolveCell(gridX, gridY, floor)
    if not self.dungeon then return false end
    local layer = self.dungeon.layers[floor + 1]
    if not layer or gridX < 0 or gridY < 0
        or gridX >= self.dungeon.width or gridY >= self.dungeon.height then
        return false
    end
    local cell = gridY * self.dungeon.width + gridX + 1
    local surface = self.stairSurfaces[floor] and self.stairSurfaces[floor][cell]
    if layer.grid[cell] == TILE_FLOOR then
        return true, self:FloorBaseY(gridX, gridY, floor) + (surface and surface.elevation or 0), surface
    end

    local descent = self.stairDescents[floor] and self.stairDescents[floor][cell]
    if descent then
        local baseY = self:FloorBaseY(gridX, gridY, descent.lowerFloor)
        return true, baseY + descent.elevation, descent
    end
    return false
end

function CameraPreviewController:SetFloor(floor)
    local nextFloor = Clamp(floor or 0, 0, self.dungeon.floorCount - 1)
    if nextFloor == self.floor then
        self.layer = self.dungeon.layers[nextFloor + 1]
        return true
    end
    self.floor = nextFloor
    self.layer = self.dungeon.layers[nextFloor + 1]
    if self.callbacks.onFloorChange then self.callbacks.onFloorChange(nextFloor) end
    return true
end

function CameraPreviewController:FindStart()
    local entrance = self.dungeon.rooms[self.dungeon.entrance]
    local room = entrance and entrance.floor == self.floor and entrance or nil
    if not room then
        for _, candidate in ipairs(self.dungeon.rooms) do
            if candidate.floor == self.floor and (candidate.type == "entrance" or room == nil) then
                room = candidate
                if candidate.type == "entrance" then break end
            end
        end
    end
    if room then return self:WorldAt(room.cx, room.cy, self.floor, 0) end

    for cell, tile in ipairs(self.layer.grid) do
        if tile == TILE_FLOOR then
            local zero = cell - 1
            return self:WorldAt(zero % self.dungeon.width, math.floor(zero / self.dungeon.width), self.floor, 0)
        end
    end
    return Vector3(0, self.floor * self.dungeon.floorHeight, 0)
end

function CameraPreviewController:SyncDungeon(dungeon, floor)
    self.dungeon = dungeon
    if not dungeon then return end
    self.floor = Clamp(floor or 0, 0, dungeon.floorCount - 1)
    self.layer = dungeon.layers[self.floor + 1]
    self:BuildStairSurfaceIndex()
    self.character.position = self:FindStart()
    if self:IsActive() then self:SnapCamera() end
end

-- Collision sampling contract (top view):
--
--             [front]
--                o
--                |
--       [left] o-C-o [right]   radius = 0.26 m
--                |
--                o
--              [back]
--
-- All five samples must resolve to a floor or a contract-backed stair surface.
-- X and Z are then applied independently so the character slides along walls
-- instead of sticking or cutting diagonally through a corner.
function CameraPreviewController:EvaluatePositionAtFloor(x, z, floor)
    if not self.dungeon then return false end
    local samples = {
        { 0, 0 }, { SAMPLE_RADIUS, 0 }, { -SAMPLE_RADIUS, 0 },
        { 0, SAMPLE_RADIUS }, { 0, -SAMPLE_RADIUS },
    }
    local minY, maxY = math.huge, -math.huge
    local centerY, centerSurface
    for index, sample in ipairs(samples) do
        local gx = math.floor(x + sample[1] + self.dungeon.width * 0.5)
        local gy = math.floor(z + sample[2] + self.dungeon.height * 0.5)
        local valid, surfaceY, surface = self:ResolveCell(gx, gy, floor)
        if not valid then return false end
        minY, maxY = math.min(minY, surfaceY), math.max(maxY, surfaceY)
        if index == 1 then
            centerY, centerSurface = surfaceY, surface
        end
    end
    if maxY - minY > MAX_SURFACE_DISCONTINUITY then return false end
    return true, centerY, centerSurface
end

function CameraPreviewController:FindUpperLandingPosition(connector)
    local floor = connector.toFloor
    local layer = self.dungeon.layers[floor + 1]
    if not layer then return nil end
    local candidates = {}
    if connector.upper then candidates[#candidates + 1] = connector.upper end
    for _, cell in ipairs(connector.upperLandingCells or {}) do
        local zero = cell - 1
        candidates[#candidates + 1] = {
            x = zero % self.dungeon.width,
            y = math.floor(zero / self.dungeon.width),
        }
    end
    for _, candidate in ipairs(candidates) do
        local cell = candidate.y * self.dungeon.width + candidate.x + 1
        if layer.grid[cell] == TILE_FLOOR then
            local world = self:WorldAt(candidate.x, candidate.y, floor, 0)
            local valid, surfaceY = self:EvaluatePositionAtFloor(world.x, world.z, floor)
            if valid then return world.x, world.z, surfaceY end
        end
    end
    return nil
end

function CameraPreviewController:EvaluatePosition(x, z)
    if not self.layer or not self.dungeon then return false end
    local valid, surfaceY, surface = self:EvaluatePositionAtFloor(x, z, self.floor)
    if not valid then return false end

    local nextFloor, connector, targetX, targetZ, targetY
    if surface and surface.kind == "descent" then
        nextFloor, connector = surface.lowerFloor, surface.connector
        targetY = surfaceY
    elseif surface and surface.kind == "tread" and surface.connector and surface.isTop then
        nextFloor, connector = surface.connector.toFloor, surface.connector
        targetX, targetZ, targetY = self:FindUpperLandingPosition(connector)
        if not targetX then return false end
    end
    if nextFloor and nextFloor ~= self.floor then
        if surface.kind == "descent" then
            local targetValid = self:EvaluatePositionAtFloor(x, z, nextFloor)
            if not targetValid then return false end
        end
        return true, targetY, nextFloor, targetX or x, targetZ or z, connector
    end
    return true, surfaceY, nil, x, z, nil
end

function CameraPreviewController:IsWalkable(x, z)
    local valid = self:EvaluatePosition(x, z)
    return valid == true
end

function CameraPreviewController:TryMoveTo(x, z)
    local valid, surfaceY, nextFloor, targetX, targetZ = self:EvaluatePosition(x, z)
    if not valid then return false end
    if nextFloor then self:SetFloor(nextFloor) end
    local position = self.character.position
    position.x, position.z, position.y = targetX, targetZ, surfaceY
    self.character.position = position
    return true
end

function CameraPreviewController:MoveCharacter(dx, dz)
    local distance = math.sqrt(dx * dx + dz * dz)
    local steps = math.max(1, math.ceil(distance / MOVEMENT_SUBSTEP))
    local stepX, stepZ = dx / steps, dz / steps
    for _ = 1, steps do
        local position = self.character.position
        self:TryMoveTo(position.x + stepX, position.z)
        position = self.character.position
        self:TryMoveTo(position.x, position.z + stepZ)
    end
end

function CameraPreviewController:SyncCharacterVisibility()
    self.thirdPersonRoot:SetEnabled(self.mode == "third")
end

function CameraPreviewController:DesiredCamera()
    local position = self.character.position
    local desiredPosition
    local desiredTarget
    if self.mode == "first" then
        desiredPosition = position + Vector3(0, FIRST_PERSON_EYE_HEIGHT, 0)
        local cp = math.cos(self.lookPitch)
        desiredTarget = desiredPosition + Vector3(
            -math.sin(self.yaw) * cp,
            math.sin(self.lookPitch),
            -math.cos(self.yaw) * cp
        )
    else
        local cp = math.cos(self.orbitPitch)
        desiredPosition = position + Vector3(
            math.sin(self.yaw) * cp * self.distance,
            math.sin(self.orbitPitch) * self.distance + 0.72,
            math.cos(self.yaw) * cp * self.distance
        )
        desiredTarget = position + Vector3(0, 0.56, 0)
    end
    local desiredRotation = Quaternion()
    desiredRotation:FromLookRotation((desiredTarget - desiredPosition):Normalized(), Vector3.UP)
    return desiredPosition, desiredRotation
end

function CameraPreviewController:SnapCamera()
    local position, rotation = self:DesiredCamera()
    self.cameraNode.position = position
    self.cameraNode.rotation = rotation
end

function CameraPreviewController:Notify(active)
    if self.callbacks.onPreviewChange then self.callbacks.onPreviewChange(active, self.mode, self.phase) end
end

function CameraPreviewController:Activate(mode)
    if not self.dungeon or (mode ~= "third" and mode ~= "first") then return end
    if self.phase == "idle" then
        self.observerPosition = Vector3(self.cameraNode.position.x, self.cameraNode.position.y, self.cameraNode.position.z)
        self.observerRotation = Quaternion(self.cameraNode.rotation)
        self.root:SetEnabled(true)
    end
    self.transitionPosition = Vector3(self.cameraNode.position.x, self.cameraNode.position.y, self.cameraNode.position.z)
    self.transitionRotation = Quaternion(self.cameraNode.rotation)
    self.mode = mode
    self:SyncCharacterVisibility()
    self.phase = "transitioning"
    self.transition = 0
    self:Notify(true)
    print("[CameraPreview] activate " .. mode)
end

function CameraPreviewController:Exit()
    if self.phase == "idle" or self.phase == "exiting" then return end
    self.transitionPosition = Vector3(self.cameraNode.position.x, self.cameraNode.position.y, self.cameraNode.position.z)
    self.transitionRotation = Quaternion(self.cameraNode.rotation)
    self.phase = "exiting"
    self.transition = 0
    self.moving = false
    self:Notify(true)
    print("[CameraPreview] exit transition")
end

function CameraPreviewController:UpdateTransition(timeStep)
    self.transition = math.min(1, self.transition + timeStep / TRANSITION_SECONDS)
    local t = SmoothStep(self.transition)
    if self.phase == "exiting" then
        self.cameraNode.position = self.transitionPosition:Lerp(self.observerPosition, t)
        self.cameraNode.rotation = self.transitionRotation:Slerp(self.observerRotation, t)
        if self.transition >= 1 then
            self.phase = "idle"
            self.mode = nil
            self.root:SetEnabled(false)
            self:Notify(false)
            print("[CameraPreview] idle")
        end
        return
    end

    local desiredPosition, desiredRotation = self:DesiredCamera()
    self.cameraNode.position = self.transitionPosition:Lerp(desiredPosition, t)
    self.cameraNode.rotation = self.transitionRotation:Slerp(desiredRotation, t)
    if self.transition >= 1 then self.phase = "active" end
end

function CameraPreviewController:UpdateCharacterAnimation()
    if self.mode ~= "third" then return end

    local time = self.elapsed
    local pulse = (math.sin(time * 2.35) + 1) * 0.5
    local stride = self.moving and math.sin(time * (self.running and 13 or 9)) or 0
    local strideAngle = stride * (self.running and 24 or 15)
    self.legL.rotation = Quaternion(strideAngle, Vector3.RIGHT)
    self.legR.rotation = Quaternion(-strideAngle, Vector3.RIGHT)

    -- Bend knees and elbows instead of swinging rigid sticks.
    local kneeL = 8 + math.max(0, stride) * (self.running and 24 or 16)
    local kneeR = 8 + math.max(0, -stride) * (self.running and 24 or 16)
    self.kneeL.rotation = Quaternion(kneeL, Vector3.RIGHT)
    self.kneeR.rotation = Quaternion(kneeR, Vector3.RIGHT)

    local shoulderSwing = stride * (self.running and 7 or 4)
    self.shoulderL.rotation = Quaternion(-shoulderSwing, Vector3.FORWARD)
    self.shoulderR.rotation = Quaternion(shoulderSwing, Vector3.FORWARD)
    self.elbowL.rotation = Quaternion(14 + math.max(0, -stride) * 8, Vector3.RIGHT)
    self.elbowR.rotation = Quaternion(14 + math.max(0, stride) * 8, Vector3.RIGHT)
    self.rig.rotation = Quaternion(
        (self.moving and math.sin(time * (self.running and 13 or 9)) * (self.running and 4 or 2) or 0),
        Vector3.FORWARD)
    self.rig.scale = Vector3(1, 1 + pulse * 0.025, 1)

    self.cloak.rotation = Quaternion(
        math.sin(time * 2.1 + 0.7) * (self.moving and (self.running and 13 or 8) or 4),
        Vector3.RIGHT)
    self.cloak.position = Vector3(0, 1.07 + math.sin(time * 1.7) * 0.018,
        0.32 + (self.moving and (self.running and 0.07 or 0.04) or 0))

    self.runeSpinner.rotation = Quaternion(math.deg(time * 42), Vector3.UP)
    self.core.scale = Vector3(0.94 + pulse * 0.13, 0.94 + pulse * 0.13, 0.94 + pulse * 0.13)
    self.weapon.rotation = Quaternion(-8 + math.sin(time * 2.8) * 2.5, Vector3.FORWARD)

    for _, orbiter in ipairs(self.orbiters) do
        local angle = time * (self.running and 1.75 or 1.0) + orbiter.phase
        local height = 1.10 + math.sin(time * 2.0 + orbiter.phase) * 0.18
        local radius = orbiter.radius + pulse * 0.035
        orbiter.node.position = Vector3(math.cos(angle) * radius, height, math.sin(angle) * radius)
        local scale = 0.86 + pulse * 0.24
        orbiter.node.scale = Vector3(scale, scale * 1.45, scale)
        orbiter.node.rotation = Quaternion(math.deg(angle * 1.8), Vector3.UP)
    end
end

function CameraPreviewController:Update(timeStep)
    if self.phase == "idle" then return end
    self.elapsed = self.elapsed + timeStep
    if self.phase == "exiting" or self.phase == "transitioning" then
        self:UpdateTransition(timeStep)
        return
    end

    if input:GetKeyPress(KEY_ESCAPE) then self:Exit(); return end
    if input:GetKeyPress(KEY_1) then self:Activate("third"); return end
    if input:GetKeyPress(KEY_2) then self:Activate("first"); return end

    if input:GetMouseButtonDown(MOUSEB_RIGHT) and not UI.IsPointerOverUI() then
        local move = input.mouseMove
        self.yaw = self.yaw + move.x * 0.006
        if self.mode == "first" then
            self.lookPitch = Clamp(self.lookPitch - move.y * 0.004, -1.05, 1.05)
        else
            self.orbitPitch = Clamp(self.orbitPitch + move.y * 0.004, THIRD_PITCH_MIN, THIRD_PITCH_MAX)
        end
    end
    local wheel = input.mouseMoveWheel
    if wheel ~= 0 and self.mode == "third" and not UI.IsPointerOverUI() then
        self.distance = Clamp(self.distance * math.exp(-wheel * 0.10),
            THIRD_DISTANCE_MIN, THIRD_DISTANCE_MAX)
        local camera = self.cameraNode:GetComponent("Camera")
        if camera then camera.farClip = math.max(camera.farClip, self.distance * 2.0) end
    end

    local forward = Vector3(-math.sin(self.yaw), 0, -math.cos(self.yaw))
    local right = Vector3(-math.cos(self.yaw), 0, math.sin(self.yaw))
    local move = Vector3.ZERO
    if IsPhysicalKeyDown(KEY_W, SCANCODE_W) then move = move + forward end
    if IsPhysicalKeyDown(KEY_S, SCANCODE_S) then move = move - forward end
    if IsPhysicalKeyDown(KEY_D, SCANCODE_D) then move = move + right end
    if IsPhysicalKeyDown(KEY_A, SCANCODE_A) then move = move - right end
    self.moving = move:LengthSquared() > 0.01
    self.running = false
    if self.moving then
        move = move:Normalized()
        self.running = IsPhysicalKeyDown(KEY_LSHIFT, SCANCODE_LSHIFT)
            or IsPhysicalKeyDown(KEY_RSHIFT, SCANCODE_RSHIFT)
        local speed = self.running and RUN_SPEED or WALK_SPEED
        self:MoveCharacter(move.x * speed * timeStep, move.z * speed * timeStep)

        local target = math.atan(move.x, move.z)
        local current = math.rad(self.character.rotation:YawAngle())
        local delta = math.atan(math.sin(target - current), math.cos(target - current))
        current = current + delta * math.min(1, timeStep * 14)
        self.character.rotation = Quaternion(math.deg(current), Vector3.UP)
    end
    local bob = self.mode == "third" and self.moving
        and math.abs(math.sin(self.elapsed * (self.running and 13 or 10)))
            * (self.running and 0.060 or 0.045) or 0
    self.visual.position = Vector3(0, bob, 0)
    self:UpdateCharacterAnimation()

    local desiredPosition, desiredRotation = self:DesiredCamera()
    if self.mode == "first" then
        -- First-person camera must stay exactly at the eye position. A smoothed
        -- follow camera trails behind while sprinting and can slip into the
        -- hidden character's head or torso for a frame.
        self.cameraNode.position = desiredPosition
        self.cameraNode.rotation = desiredRotation
        return
    end
    local smoothing = 1 - math.exp(-timeStep * 10)
    self.cameraNode.position = self.cameraNode.position:Lerp(desiredPosition, smoothing)
    self.cameraNode.rotation = self.cameraNode.rotation:Slerp(desiredRotation, smoothing)
end

function CameraPreviewController:Dispose()
    if self.root then self.root:Remove(); self.root = nil end
end

return CameraPreviewController
