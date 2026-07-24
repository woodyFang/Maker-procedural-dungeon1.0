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
local FIRST_PERSON_EYE_HEIGHT = 1.48
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

local function CreateMaterial(color, roughness, metallic)
    local material = Material:new()
    material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    material:SetShaderParameter("MatDiffColor", Variant(HexColor(color)))
    material:SetShaderParameter("MatSpecColor", Variant(Color(0.35, 0.35, 0.35, 1)))
    material:SetShaderParameter("Roughness", Variant(roughness or 0.72))
    material:SetShaderParameter("Metallic", Variant(metallic or 0.08))
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
    self.visual.scale = Vector3(0.78, 0.78, 0.78)
    self.visual.rotation = Quaternion(180, Vector3.UP)

    local model = function(key, fallback)
        return ResolveModel(self.dungeonRenderer, key, fallback)
    end
    -- Classic medieval palette: bright polished plate over dark under-armour,
    -- gold trim and heraldic red cloth. Bright plate keeps the figure readable
    -- inside dark dungeon lighting instead of dissolving into a black column.
    local plate = CreateMaterial(0x9fabb8, 0.30, 0.86)
    local plateDark = CreateMaterial(0x39424e, 0.42, 0.62)
    local steel = CreateMaterial(0xd6dde3, 0.16, 0.94)
    local gold = CreateMaterial(0xc08a35, 0.30, 0.85)
    local heraldry = CreateMaterial(0x9c2430, 0.55, 0.12)
    local clothRed = CreateMaterial(0x77201e, 0.85, 0.03)
    local glowWarm = CreateMaterial(0xff6333, 0.30, 0.12, 0xff4a24)
    clothRed.cullMode = CULL_NONE
    local flat = Quaternion(-90, Vector3.RIGHT)

    -- Proportion contract: authored at ~8 heads tall (total 2.20 units, helm
    -- width 0.27) so the silhouette reads as an adult man-at-arms, not a chibi
    -- mascot. Legs take half the height; plate limbs are round tubes like real
    -- rerebraces/vambraces instead of rectangular robot blocks.
    self.rig = self.visual:CreateChild("ArmorRig")
    self.rig.position = Vector3(0, 0.02, 0)

    -- Pelvis, faulds skirt and waist.
    AddPart(self.rig, "Pelvis", model("roundedBox"), Vector3(0, 1.20, 0),
        Vector3(0.42, 0.20, 0.30), plateDark)
    AddPart(self.rig, "FauldFront", model("roundedBox"), Vector3(0, 1.10, -0.145),
        Vector3(0.32, 0.24, 0.05), plate, Quaternion(6, Vector3.RIGHT))
    AddPart(self.rig, "FauldBack", model("roundedBox"), Vector3(0, 1.10, 0.145),
        Vector3(0.32, 0.24, 0.05), plate, Quaternion(-6, Vector3.RIGHT))
    AddPart(self.rig, "FauldL", model("roundedBox"), Vector3(-0.20, 1.10, 0),
        Vector3(0.05, 0.22, 0.26), plate, Quaternion(0, 0, -10))
    AddPart(self.rig, "FauldR", model("roundedBox"), Vector3(0.20, 1.10, 0),
        Vector3(0.05, 0.22, 0.26), plate, Quaternion(0, 0, 10))
    AddPart(self.rig, "Waist", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, 1.36, 0),
        Vector3(0.34, 0.16, 0.26), plateDark)
    AddPart(self.rig, "Belt", model("torus"), Vector3(0, 1.31, 0),
        Vector3(0.34, 0.26, 0.30), gold, flat)

    -- Chest: broad plate tapering into the waist, with the heraldic cross.
    AddPart(self.rig, "Chest", model("roundedBox"), Vector3(0, 1.60, 0),
        Vector3(0.52, 0.36, 0.32), plate)
    AddPart(self.rig, "ChestLower", model("roundedBox"), Vector3(0, 1.44, 0),
        Vector3(0.42, 0.16, 0.28), plate)
    AddPart(self.rig, "ChestCrossV", model("roundedBox"), Vector3(0, 1.60, -0.155),
        Vector3(0.075, 0.24, 0.03), heraldry)
    AddPart(self.rig, "ChestCrossH", model("roundedBox"), Vector3(0, 1.645, -0.155),
        Vector3(0.19, 0.075, 0.03), heraldry)
    AddPart(self.rig, "Gorget", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, 1.795, 0),
        Vector3(0.235, 0.09, 0.21), plateDark)
    AddPart(self.rig, "GorgetTrim", model("torus"), Vector3(0, 1.775, 0),
        Vector3(0.25, 0.22, 0.24), gold, flat)

    -- Small great helm at true head scale: tube + dome + eye slit + red plume.
    AddPart(self.rig, "Neck", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, 1.86, 0),
        Vector3(0.13, 0.10, 0.13), plateDark)
    AddPart(self.rig, "HelmBody", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, 1.97, 0),
        Vector3(0.27, 0.18, 0.255), plate)
    AddPart(self.rig, "HelmDome", model("sphere", "Models/Sphere.mdl"), Vector3(0, 2.065, 0),
        Vector3(0.28, 0.20, 0.265), plate)
    AddPart(self.rig, "VisorBar", model("roundedBox"), Vector3(0, 1.935, -0.115),
        Vector3(0.20, 0.032, 0.035), plateDark)
    AddPart(self.rig, "EyeSlit", model("box"), Vector3(0, 1.985, -0.118),
        Vector3(0.16, 0.028, 0.028), glowWarm)
    AddPart(self.rig, "PlumeBase", model("roundedBox"), Vector3(0, 2.155, 0.01),
        Vector3(0.045, 0.09, 0.16), heraldry)
    AddPart(self.rig, "PlumeMid", model("roundedBox"), Vector3(0, 2.10, 0.135),
        Vector3(0.04, 0.07, 0.14), heraldry, Quaternion(-32, Vector3.RIGHT))
    AddPart(self.rig, "PlumeTail", model("roundedBox"), Vector3(0, 2.015, 0.235),
        Vector3(0.035, 0.06, 0.12), heraldry, Quaternion(-58, Vector3.RIGHT))

    -- Arms: bowl pauldrons over tubular plate limbs with ball elbows.
    self.shoulderL = self.rig:CreateChild("ShoulderL")
    self.shoulderL.position = Vector3(-0.30, 1.76, 0)
    AddPart(self.shoulderL, "Pauldron", model("sphere", "Models/Sphere.mdl"), Vector3(-0.03, 0.045, 0),
        Vector3(0.24, 0.15, 0.25), plate)
    AddPart(self.shoulderL, "PauldronRim", model("torus"), Vector3(-0.03, 0.0, 0),
        Vector3(0.185, 0.16, 0.19), gold, flat)
    AddPart(self.shoulderL, "UpperArm", model("cylinder", "Models/Cylinder.mdl"), Vector3(-0.03, -0.19, 0),
        Vector3(0.125, 0.34, 0.125), plateDark)
    self.elbowL = self.shoulderL:CreateChild("ElbowL")
    self.elbowL.position = Vector3(-0.03, -0.38, 0)
    AddPart(self.elbowL, "ElbowJoint", model("sphere", "Models/Sphere.mdl"), Vector3(0, 0, 0),
        Vector3(0.13, 0.13, 0.13), plate)
    AddPart(self.elbowL, "Forearm", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, -0.17, 0),
        Vector3(0.115, 0.30, 0.115), plate)
    self.handL = self.elbowL:CreateChild("GauntletL")
    self.handL.position = Vector3(0, -0.36, 0)
    AddPart(self.handL, "Gauntlet", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.15, 0.13, 0.16), plateDark)

    self.shoulderR = self.rig:CreateChild("ShoulderR")
    self.shoulderR.position = Vector3(0.30, 1.76, 0)
    AddPart(self.shoulderR, "Pauldron", model("sphere", "Models/Sphere.mdl"), Vector3(0.03, 0.045, 0),
        Vector3(0.24, 0.15, 0.25), plate)
    AddPart(self.shoulderR, "PauldronRim", model("torus"), Vector3(0.03, 0.0, 0),
        Vector3(0.185, 0.16, 0.19), gold, flat)
    AddPart(self.shoulderR, "UpperArm", model("cylinder", "Models/Cylinder.mdl"), Vector3(0.03, -0.19, 0),
        Vector3(0.125, 0.34, 0.125), plateDark)
    self.elbowR = self.shoulderR:CreateChild("ElbowR")
    self.elbowR.position = Vector3(0.03, -0.38, 0)
    AddPart(self.elbowR, "ElbowJoint", model("sphere", "Models/Sphere.mdl"), Vector3(0, 0, 0),
        Vector3(0.13, 0.13, 0.13), plate)
    AddPart(self.elbowR, "Forearm", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, -0.17, 0),
        Vector3(0.115, 0.30, 0.115), plate)
    self.handR = self.elbowR:CreateChild("GauntletR")
    self.handR.position = Vector3(0, -0.36, 0)
    AddPart(self.handR, "Gauntlet", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.15, 0.13, 0.16), plateDark)

    -- Legs: half the body height, tubular cuisses and greaves, ball knees.
    self.legL = self.rig:CreateChild("LegL")
    self.legL.position = Vector3(-0.13, 1.18, 0)
    AddPart(self.legL, "Thigh", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, -0.27, 0),
        Vector3(0.185, 0.50, 0.185), plate)
    self.kneeL = self.legL:CreateChild("KneeL")
    self.kneeL.position = Vector3(0, -0.55, 0)
    AddPart(self.kneeL, "KneeCap", model("sphere", "Models/Sphere.mdl"), Vector3(0, 0, -0.02),
        Vector3(0.15, 0.13, 0.14), plateDark)
    local shinL = self.kneeL:CreateChild("ShinL")
    AddPart(shinL, "Shin", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, -0.26, 0),
        Vector3(0.155, 0.46, 0.155), plate)
    AddPart(shinL, "Boot", model("roundedBox"), Vector3(0, -0.525, -0.06),
        Vector3(0.17, 0.11, 0.32), plateDark)

    self.legR = self.rig:CreateChild("LegR")
    self.legR.position = Vector3(0.13, 1.18, 0)
    AddPart(self.legR, "Thigh", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, -0.27, 0),
        Vector3(0.185, 0.50, 0.185), plate)
    self.kneeR = self.legR:CreateChild("KneeR")
    self.kneeR.position = Vector3(0, -0.55, 0)
    AddPart(self.kneeR, "KneeCap", model("sphere", "Models/Sphere.mdl"), Vector3(0, 0, -0.02),
        Vector3(0.15, 0.13, 0.14), plateDark)
    local shinR = self.kneeR:CreateChild("ShinR")
    AddPart(shinR, "Shin", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, -0.26, 0),
        Vector3(0.155, 0.46, 0.155), plate)
    AddPart(shinR, "Boot", model("roundedBox"), Vector3(0, -0.525, -0.06),
        Vector3(0.17, 0.11, 0.32), plateDark)

    -- Arming sword held point-up in the right gauntlet.
    self.weapon = self.handR:CreateChild("KnightSword")
    self.weapon.position = Vector3(0.05, -0.01, -0.06)
    self.weapon.rotation = Quaternion(-12, Vector3.FORWARD)
    AddPart(self.weapon, "Pommel", model("sphere", "Models/Sphere.mdl"), Vector3(0, -0.20, 0),
        Vector3(0.075, 0.075, 0.075), gold)
    AddPart(self.weapon, "Grip", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, -0.12, 0),
        Vector3(0.055, 0.15, 0.055), plateDark)
    AddPart(self.weapon, "Guard", model("roundedBox"), Vector3(0, -0.025, 0),
        Vector3(0.28, 0.05, 0.08), gold)
    AddPart(self.weapon, "Blade", model("box", "Models/Box.mdl"), Vector3(0, 0.42, 0),
        Vector3(0.10, 0.86, 0.032), steel)
    AddPart(self.weapon, "BladeTip", model("box", "Models/Box.mdl"), Vector3(0, 0.88, 0),
        Vector3(0.068, 0.09, 0.032), steel)

    -- Tall heater shield strapped to the left forearm.
    self.shield = self.handL:CreateChild("HeaterShield")
    self.shield.position = Vector3(-0.115, 0.02, -0.03)
    AddPart(self.shield, "ShieldFace", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.05, 0.56, 0.42), plate)
    AddPart(self.shield, "ShieldTopTrim", model("roundedBox"), Vector3(-0.018, 0.265, 0),
        Vector3(0.042, 0.05, 0.44), gold)
    AddPart(self.shield, "ShieldPoint", model("roundedBox"), Vector3(-0.008, -0.31, 0),
        Vector3(0.046, 0.12, 0.26), plate)
    AddPart(self.shield, "ShieldCrossV", model("roundedBox"), Vector3(-0.038, -0.005, 0),
        Vector3(0.026, 0.40, 0.095), heraldry)
    AddPart(self.shield, "ShieldCrossH", model("roundedBox"), Vector3(-0.038, 0.09, 0),
        Vector3(0.026, 0.095, 0.30), heraldry)
    AddPart(self.shield, "ShieldBoss", model("sphere", "Models/Sphere.mdl"), Vector3(-0.05, 0.09, 0),
        Vector3(0.09, 0.09, 0.09), gold)

    -- Heraldic red cloak pinned at the shoulder blades, swept away from the back.
    self.cloak = self.rig:CreateChild("Cloak")
    self.cloak.position = Vector3(0, 1.76, 0.17)
    self.cloak.rotation = Quaternion(-14, Vector3.RIGHT)
    AddPart(self.cloak, "CloakCloth", model("bannerCloth"), Vector3(0, -0.02, 0),
        Vector3(1.20, 1.45, 1), clothRed)
    AddPart(self.cloak, "CloakPinL", model("sphere", "Models/Sphere.mdl"),
        Vector3(-0.24, 0.02, -0.02), Vector3(0.075, 0.075, 0.075), gold)
    AddPart(self.cloak, "CloakPinR", model("sphere", "Models/Sphere.mdl"),
        Vector3(0.24, 0.02, -0.02), Vector3(0.075, 0.075, 0.075), gold)

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
    if room then
        -- The entrance room centre carries the spawn-gate FX rig; offset the
        -- start cell so the knight is not born inside the glowing portal.
        for _, offset in ipairs({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 }, { 0, 0 } }) do
            local gx, gy = room.cx + offset[1], room.cy + offset[2]
            if gx >= 0 and gy >= 0 and gx < self.dungeon.width and gy < self.dungeon.height
                and self.layer.grid[gy * self.dungeon.width + gx + 1] == TILE_FLOOR then
                return self:WorldAt(gx, gy, self.floor, 0)
            end
        end
        return self:WorldAt(room.cx, room.cy, self.floor, 0)
    end

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
    -- SetDeepEnabled is required here: the visual is a nested tree of model
    -- nodes, and SetEnabled on the group does not suppress descendant meshes.
    self.thirdPersonRoot:SetDeepEnabled(self.mode == "third")
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
        desiredTarget = position + Vector3(0, 0.82, 0)
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
        self.root:SetDeepEnabled(true)
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
            self.root:SetDeepEnabled(false)
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
    self.elbowL.rotation = Quaternion(12 + math.max(0, -stride) * 8, Vector3.RIGHT)
    self.elbowR.rotation = Quaternion(12 + math.max(0, stride) * 8, Vector3.RIGHT)
    self.rig.rotation = Quaternion(
        (self.moving and math.sin(time * (self.running and 13 or 9)) * (self.running and 4 or 2) or 0),
        Vector3.FORWARD)
    self.rig.scale = Vector3(1, 1 + pulse * 0.02, 1)

    self.cloak.rotation = Quaternion(
        -14 - (self.moving and (self.running and 14 or 8) or 0)
            + math.sin(time * 2.1 + 0.7) * (self.moving and (self.running and 5 or 3) or 2),
        Vector3.RIGHT)
    self.weapon.rotation = Quaternion(-14 + math.sin(time * 2.8) * 2.5, Vector3.FORWARD)
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
