local UI = require("urhox-libs/UI")

local CameraPreviewController = {}
CameraPreviewController.__index = CameraPreviewController

local TILE_FLOOR = 1
local TRANSITION_SECONDS = 0.72
local WALK_SPEED = 3.2
local RUN_SPEED = 4.8
local THIRD_DISTANCE = 12.5
-- Diablo-style action-RPG framing: a steep ~55° look-down angle keeps the
-- floor layout readable and stops near-side walls from hiding the character.
-- The pitch window allows slight adjustment without leaving that framing.
local THIRD_PITCH = 0.96
local THIRD_PITCH_MIN = 0.78
local THIRD_PITCH_MAX = 1.22
local THIRD_DISTANCE_MIN = 9
local THIRD_DISTANCE_MAX = 20
local FIRST_PERSON_EYE_HEIGHT = 0.92
local SAMPLE_RADIUS = 0.26

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
    self.visual.scale = Vector3(0.68, 0.68, 0.68)
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
    local glow = CreateMaterial(0x35d9ff, 0.28, 0.08, 0x35d9ff)
    local glowWarm = CreateMaterial(0xff6333, 0.30, 0.12, 0xff4a24)
    cloth.cullMode = CULL_NONE

    self.rig = self.visual:CreateChild("ArmorRig")
    self.rig.position = Vector3(0, 0.04, 0)

    -- Layered silhouette: heavy torso, raised collar, trim plates and a glowing
    -- chest core give the demo character a readable shape from the high orbit.
    AddPart(self.rig, "Torso", model("roundedBox"), Vector3(0, 0.82, 0),
        Vector3(0.72, 0.94, 0.50), armor)
    AddPart(self.rig, "ChestPlate", model("roundedBox"), Vector3(0, 0.97, -0.29),
        Vector3(0.56, 0.58, 0.13), armorEdge)
    AddPart(self.rig, "ChestInset", model("box"), Vector3(0, 0.98, -0.40),
        Vector3(0.36, 0.34, 0.045), armor)
    self.core = AddPart(self.rig, "ChestCore", model("octahedron"), Vector3(0, 1.01, -0.47),
        Vector3(0.16, 0.26, 0.10), glow)
    AddPart(self.rig, "WaistGuard", model("roundedBox"), Vector3(0, 0.47, 0),
        Vector3(0.64, 0.20, 0.44), armorEdge)
    AddPart(self.rig, "WaistSeal", model("torus"), Vector3(0, 0.56, 0),
        Vector3(0.52, 0.08, 0.38), gold)

    -- Head and helmet stack, with a bright crown that makes the character
    -- legible even when the dungeon walls occupy most of the frame.
    AddPart(self.rig, "Head", model("sphere", "Models/Sphere.mdl"), Vector3(0, 1.58, 0),
        Vector3(0.36, 0.38, 0.34), skin)
    AddPart(self.rig, "Helmet", model("cone", "Models/Cone.mdl"), Vector3(0, 1.79, 0),
        Vector3(0.45, 0.38, 0.42), armor)
    AddPart(self.rig, "Visor", model("roundedBox"), Vector3(0, 1.68, -0.31),
        Vector3(0.32, 0.09, 0.08), steel)
    AddPart(self.rig, "CrownGem", model("octahedron"), Vector3(0, 2.08, 0),
        Vector3(0.13, 0.28, 0.13), glowWarm)

    -- Shoulder pivots and articulated limbs are separate nodes so their
    -- motion reads as an intentional armored figure rather than a single blob.
    self.shoulderL = self.rig:CreateChild("ShoulderL")
    self.shoulderL.position = Vector3(-0.57, 1.22, 0)
    AddPart(self.shoulderL, "Plate", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.38, 0.22, 0.48), armorEdge, Quaternion(-10, Vector3.FORWARD))
    AddPart(self.shoulderL, "Shard", model("icosahedron"), Vector3(-0.04, 0.15, 0),
        Vector3(0.17, 0.32, 0.17), glow)
    self.shoulderR = self.rig:CreateChild("ShoulderR")
    self.shoulderR.position = Vector3(0.57, 1.22, 0)
    AddPart(self.shoulderR, "Plate", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.38, 0.22, 0.48), armorEdge, Quaternion(10, Vector3.FORWARD))
    AddPart(self.shoulderR, "Shard", model("icosahedron"), Vector3(0.04, 0.15, 0),
        Vector3(0.17, 0.32, 0.17), glow)

    self.legL = self.rig:CreateChild("LegL")
    self.legL.position = Vector3(-0.24, 0.55, 0)
    AddPart(self.legL, "Greave", model("roundedBox"), Vector3(0, -0.33, 0),
        Vector3(0.24, 0.62, 0.27), armor)
    AddPart(self.legL, "Knee", model("octahedron"), Vector3(0, -0.03, -0.16),
        Vector3(0.17, 0.16, 0.12), armorEdge)
    AddPart(self.legL, "Boot", model("roundedBox"), Vector3(0, -0.68, -0.10),
        Vector3(0.28, 0.16, 0.42), steel)
    self.legR = self.rig:CreateChild("LegR")
    self.legR.position = Vector3(0.24, 0.55, 0)
    AddPart(self.legR, "Greave", model("roundedBox"), Vector3(0, -0.33, 0),
        Vector3(0.24, 0.62, 0.27), armor)
    AddPart(self.legR, "Knee", model("octahedron"), Vector3(0, -0.03, -0.16),
        Vector3(0.17, 0.16, 0.12), armorEdge)
    AddPart(self.legR, "Boot", model("roundedBox"), Vector3(0, -0.68, -0.10),
        Vector3(0.28, 0.16, 0.42), steel)

    self.weapon = self.rig:CreateChild("EnergyBlade")
    self.weapon.position = Vector3(0.72, 0.82, 0.05)
    self.weapon.rotation = Quaternion(-12, Vector3.FORWARD)
    AddPart(self.weapon, "Guard", model("roundedBox"), Vector3(0, 0, 0),
        Vector3(0.38, 0.07, 0.11), gold)
    AddPart(self.weapon, "Grip", model("cylinder", "Models/Cylinder.mdl"), Vector3(0, -0.18, 0),
        Vector3(0.08, 0.28, 0.08), armor)
    AddPart(self.weapon, "Blade", model("box", "Models/Box.mdl"), Vector3(0, 0.44, 0),
        Vector3(0.09, 0.70, 0.16), steel)
    AddPart(self.weapon, "BladeCore", model("box", "Models/Box.mdl"), Vector3(0, 0.44, -0.09),
        Vector3(0.035, 0.60, 0.035), glowWarm)

    self.cloak = self.rig:CreateChild("Cloak")
    self.cloak.position = Vector3(0, 1.15, 0.30)
    AddPart(self.cloak, "CloakCloth", model("bannerCloth"), Vector3(0, -0.48, 0),
        Vector3(1.30, 1.48, 1), cloth)
    AddPart(self.cloak, "CloakSpine", model("cylinder", "Models/Cylinder.mdl"),
        Vector3(0, -0.40, 0.05), Vector3(0.06, 0.72, 0.06), gold)

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
-- All five samples must remain on TILE_FLOOR. X and Z are then applied
-- independently so the character slides along walls instead of sticking or
-- cutting diagonally through a corner.
function CameraPreviewController:IsWalkable(x, z)
    if not self.layer or not self.dungeon then return false end
    local samples = {
        { 0, 0 }, { SAMPLE_RADIUS, 0 }, { -SAMPLE_RADIUS, 0 },
        { 0, SAMPLE_RADIUS }, { 0, -SAMPLE_RADIUS },
    }
    for _, sample in ipairs(samples) do
        local gx = math.floor(x + sample[1] + self.dungeon.width * 0.5)
        local gy = math.floor(z + sample[2] + self.dungeon.height * 0.5)
        if gx < 0 or gy < 0 or gx >= self.dungeon.width or gy >= self.dungeon.height then return false end
        if self.layer.grid[gy * self.dungeon.width + gx + 1] ~= TILE_FLOOR then return false end
    end
    return true
end

function CameraPreviewController:MoveCharacter(dx, dz)
    local position = self.character.position
    if self:IsWalkable(position.x + dx, position.z) then position.x = position.x + dx end
    if self:IsWalkable(position.x, position.z + dz) then position.z = position.z + dz end
    self.character.position = position
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

    local shoulderSwing = stride * (self.running and 7 or 4)
    self.shoulderL.rotation = Quaternion(-shoulderSwing, Vector3.FORWARD)
    self.shoulderR.rotation = Quaternion(shoulderSwing, Vector3.FORWARD)
    self.rig.rotation = Quaternion(
        (self.moving and math.sin(time * (self.running and 13 or 9)) * (self.running and 4 or 2) or 0),
        Vector3.FORWARD)
    self.rig.scale = Vector3(1, 1 + pulse * 0.025, 1)

    self.cloak.rotation = Quaternion(
        math.sin(time * 2.1 + 0.7) * (self.moving and (self.running and 13 or 8) or 4),
        Vector3.RIGHT)
    self.cloak.position = Vector3(0, 1.15 + math.sin(time * 1.7) * 0.018,
        0.30 + (self.moving and (self.running and 0.07 or 0.04) or 0))

    self.runeSpinner.rotation = Quaternion(math.deg(time * 42), Vector3.UP)
    self.core.scale = Vector3(0.94 + pulse * 0.13, 0.94 + pulse * 0.13, 0.94 + pulse * 0.13)
    self.weapon.rotation = Quaternion(-12 + math.sin(time * 2.8) * 2.5, Vector3.FORWARD)

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
