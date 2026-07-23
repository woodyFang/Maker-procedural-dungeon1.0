local UI = require("urhox-libs/UI")

local CameraPreviewController = {}
CameraPreviewController.__index = CameraPreviewController

local TILE_FLOOR = 1
local TRANSITION_SECONDS = 0.72
local WALK_SPEED = 3.2
local RUN_SPEED = 4.8
local THIRD_DISTANCE = 12.5
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

local function AddPart(parent, name, modelPath, position, scale, material, rotation)
    local node = parent:CreateChild(name)
    node.position = position
    node.scale = scale
    if rotation then node.rotation = rotation end
    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", modelPath))
    model:SetMaterial(material)
    model.castShadows = true
    return node
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
        orbitPitch = 0.54,
        lookPitch = 0,
        distance = THIRD_DISTANCE,
        transition = 0,
        moving = false,
        elapsed = 0,
        cameraOnly = false,
        freePosition = nil,
    }, CameraPreviewController)
    self:CreateCharacter()
    return self
end

function CameraPreviewController:CreateCharacter()
    self.root = self.scene:CreateChild("CameraPreview")
    self.character = self.root:CreateChild("PreviewCharacter")
    self.visual = self.character:CreateChild("CharacterVisual")
    self.visual.scale = Vector3(0.68, 0.68, 0.68)
    self.visual.rotation = Quaternion(180, Vector3.UP)

    local armor = CreateMaterial(0x252b33, 0.38, 0.50)
    local cloth = CreateMaterial(0x79221c, 0.72, 0.08)
    local skin = CreateMaterial(0xd4aa83, 0.72, 0.08)
    local steel = CreateMaterial(0xcbd2d8, 0.20, 0.88)
    AddPart(self.visual, "Armor", "Models/Cylinder.mdl", Vector3(0, 0.72, 0), Vector3(0.64, 0.70, 0.64), armor)
    AddPart(self.visual, "Cloth", "Models/Cone.mdl", Vector3(0, 0.43, 0), Vector3(0.924, 0.82, 0.924), cloth)
    AddPart(self.visual, "Head", "Models/Sphere.mdl", Vector3(0, 1.25, 0), Vector3(0.48, 0.48, 0.48), skin)
    AddPart(self.visual, "Helmet", "Models/Cone.mdl", Vector3(0, 1.43, 0), Vector3(0.582, 0.48, 0.582), armor)
    AddPart(self.visual, "Blade", "Models/Box.mdl", Vector3(0.46, 0.75, 0.12), Vector3(0.11, 0.12, 0.92), steel)

    local marker = CreateMaterial(0xe5a35d, 0.35, 0.05, 0xe5a35d, 0.45)
    AddPart(self.character, "GroundMarker", "Models/Torus.mdl", Vector3(0, 0.025, 0),
        Vector3(0.83, 0.18, 0.83), marker)
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
    self.cameraOnly, self.freePosition = false, nil
    self.dungeon = dungeon
    if not dungeon then
        self.layer = nil
        return
    end
    if not self.root then self:CreateCharacter() end
    self.floor = Clamp(floor or 0, 0, dungeon.floorCount - 1)
    self.layer = dungeon.layers[self.floor + 1]
    self.character.position = self:FindStart()
    if self:IsActive() then self:SnapCamera() end
end

function CameraPreviewController:ClearScene()
    if self:IsActive() and self.observerPosition and self.observerRotation then
        self.cameraNode.position = self.observerPosition
        self.cameraNode.rotation = self.observerRotation
    end
    self.phase, self.mode, self.transition, self.moving = "idle", nil, 0, false
    self.cameraOnly, self.freePosition = false, nil
    self.dungeon, self.layer = nil, nil
    if self.root then self.root:Dispose() end
    self.root, self.character, self.visual = nil, nil, nil
    print("[CameraPreview] scene character cleared")
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

function CameraPreviewController:DesiredCamera()
    local position = self.cameraOnly and self.freePosition or self.character.position
    local desiredPosition
    local desiredTarget
    if self.mode == "first" then
        desiredPosition = position + Vector3(0, 0.92, 0)
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
    self.cameraOnly, self.freePosition = false, nil
    if self.phase == "idle" then
        self.observerPosition = Vector3(self.cameraNode.position.x, self.cameraNode.position.y, self.cameraNode.position.z)
        self.observerRotation = Quaternion(self.cameraNode.rotation)
        self.root:SetEnabled(true)
    end
    self.transitionPosition = Vector3(self.cameraNode.position.x, self.cameraNode.position.y, self.cameraNode.position.z)
    self.transitionRotation = Quaternion(self.cameraNode.rotation)
    self.mode = mode
    self.phase = "transitioning"
    self.transition = 0
    self.visual:SetEnabled(mode == "third")
    self.root:GetChild("GroundMarker", true):SetEnabled(mode == "third")
    self:Notify(true)
    print("[CameraPreview] activate " .. mode)
end

function CameraPreviewController:ActivateCameraOnly(position)
    if not position then return end
    if self.phase == "idle" then
        self.observerPosition = Vector3(self.cameraNode.position.x, self.cameraNode.position.y, self.cameraNode.position.z)
        self.observerRotation = Quaternion(self.cameraNode.rotation)
    end
    if self.root then self.root:SetEnabled(false) end
    self.transitionPosition = Vector3(self.cameraNode.position.x, self.cameraNode.position.y, self.cameraNode.position.z)
    self.transitionRotation = Quaternion(self.cameraNode.rotation)
    self.freePosition = Vector3(position.x, position.y, position.z)
    self.cameraOnly = true
    self.mode = "first"
    self.phase = "transitioning"
    self.transition = 0
    self.moving = false
    self:Notify(true)
    print(string.format("[CameraPreview] activate camera-only first at %.2f %.2f %.2f",
        position.x, position.y, position.z))
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
            self.cameraOnly, self.freePosition = false, nil
            if self.root then self.root:SetEnabled(false) end
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

function CameraPreviewController:Update(timeStep)
    if self.phase == "idle" then return end
    self.elapsed = self.elapsed + timeStep
    if self.phase == "exiting" or self.phase == "transitioning" then
        self:UpdateTransition(timeStep)
        return
    end

    if input:GetKeyPress(KEY_ESCAPE) then self:Exit(); return end
    if input:GetKeyPress(KEY_1) and not self.cameraOnly then self:Activate("third"); return end
    if input:GetKeyPress(KEY_2) and not self.cameraOnly then self:Activate("first"); return end

    if input:GetMouseButtonDown(MOUSEB_RIGHT) and not UI.IsPointerOverUI() then
        local move = input.mouseMove
        self.yaw = self.yaw + move.x * 0.006
        if self.mode == "first" then
            self.lookPitch = Clamp(self.lookPitch - move.y * 0.004, -1.05, 1.05)
        else
            self.orbitPitch = Clamp(self.orbitPitch + move.y * 0.004, 0.28, 0.88)
        end
    end
    local wheel = input.mouseMoveWheel
    if wheel ~= 0 and self.mode == "third" and not UI.IsPointerOverUI() then
        self.distance = math.max(9, self.distance * math.exp(-wheel * 0.10))
        local camera = self.cameraNode:GetComponent("Camera")
        if camera then camera.farClip = math.max(camera.farClip, self.distance * 2.0) end
    end

    local forward
    if self.cameraOnly then
        local cp = math.cos(self.lookPitch)
        forward = Vector3(-math.sin(self.yaw) * cp, math.sin(self.lookPitch), -math.cos(self.yaw) * cp)
    else
        forward = Vector3(-math.sin(self.yaw), 0, -math.cos(self.yaw))
    end
    local right = Vector3(-math.cos(self.yaw), 0, math.sin(self.yaw))
    local move = Vector3.ZERO
    if IsPhysicalKeyDown(KEY_W, SCANCODE_W) then move = move + forward end
    if IsPhysicalKeyDown(KEY_S, SCANCODE_S) then move = move - forward end
    if IsPhysicalKeyDown(KEY_D, SCANCODE_D) then move = move + right end
    if IsPhysicalKeyDown(KEY_A, SCANCODE_A) then move = move - right end
    self.moving = move:LengthSquared() > 0.01
    if self.moving then
        move = move:Normalized()
        local running = IsPhysicalKeyDown(KEY_LSHIFT, SCANCODE_LSHIFT)
            or IsPhysicalKeyDown(KEY_RSHIFT, SCANCODE_RSHIFT)
        local speed = running and RUN_SPEED or WALK_SPEED
        if self.cameraOnly then
            self.freePosition = self.freePosition + move * speed * timeStep
        else
            self:MoveCharacter(move.x * speed * timeStep, move.z * speed * timeStep)

            local target = math.atan(move.x, move.z)
            local current = math.rad(self.character.rotation:YawAngle())
            local delta = math.atan(math.sin(target - current), math.cos(target - current))
            current = current + delta * math.min(1, timeStep * 14)
            self.character.rotation = Quaternion(math.deg(current), Vector3.UP)
        end
    end
    if self.visual then
        local bob = self.mode == "third" and self.moving and math.abs(math.sin(self.elapsed * 10)) * 0.045 or 0
        self.visual.position = Vector3(0, bob, 0)
    end

    local desiredPosition, desiredRotation = self:DesiredCamera()
    local smoothing = 1 - math.exp(-timeStep * 10)
    self.cameraNode.position = self.cameraNode.position:Lerp(desiredPosition, smoothing)
    self.cameraNode.rotation = self.cameraNode.rotation:Slerp(desiredRotation, smoothing)
end

function CameraPreviewController:Dispose()
    if self.root then self.root:Dispose(); self.root = nil end
    self.character, self.visual, self.dungeon, self.layer = nil, nil, nil, nil
    self.cameraOnly, self.freePosition = false, nil
end

return CameraPreviewController
