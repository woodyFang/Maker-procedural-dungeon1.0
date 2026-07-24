-- Close-up character viewer: builds only the preview knight (no dungeon) and
-- captures front / side / back portraits so proportions can be judged at
-- human scale instead of from the 12m tactical camera.
local CameraPreviewController = require("Gameplay.CameraPreviewController")
local ProceduralModelCache = require("Rendering.ProceduralModelCache")

---@type Scene|nil
local scene = nil
---@type Node|nil
local cameraNode = nil
local preview = nil
local elapsed = 0
local shots = {
    { name = "front", yaw = 15, pitch = 12 },
    { name = "side", yaw = 105, pitch = 10 },
    { name = "back", yaw = 195, pitch = 14 },
}
local shotIndex = 1
local shotTimer = 0
local resultPath = ".tmp/knight-viewer.result.txt"

local function WriteResult(message)
    local result = File(resultPath, FILE_WRITE)
    if result and result:IsOpen() then result:WriteLine(message); result:Close() end
end

local function Fail(message)
    UnsubscribeFromEvent("Update")
    WriteResult("FAIL " .. tostring(message))
    ErrorExit("[knight-viewer] FAIL\n" .. tostring(message), 1)
end

local function AimCamera(shot)
    local target = Vector3(0, 0.90, 0)
    local yaw = math.rad(shot.yaw)
    local pitch = math.rad(shot.pitch)
    local distance = 3.9
    cameraNode.position = Vector3(
        target.x + math.sin(yaw) * math.cos(pitch) * distance,
        target.y + math.sin(pitch) * distance,
        target.z + math.cos(yaw) * math.cos(pitch) * distance)
    cameraNode:LookAt(target, Vector3.UP)
end

function Start()
    local ok, message = xpcall(function()
        scene = Scene()
        scene:CreateComponent("Octree")

        local zoneNode = scene:CreateChild("Zone")
        local zone = zoneNode:CreateComponent("Zone")
        zone.boundingBox = BoundingBox(Vector3(-100, -100, -100), Vector3(100, 100, 100))
        zone.ambientColor = Color(0.38, 0.42, 0.50, 1)
        zone.fogColor = Color(0.10, 0.12, 0.18, 1)
        zone.fogStart = 40
        zone.fogEnd = 90

        local sunNode = scene:CreateChild("Sun")
        sunNode.rotation = Quaternion(46, -30, 0)
        local sun = sunNode:CreateComponent("Light")
        sun.lightType = LIGHT_DIRECTIONAL
        sun.color = Color(1.0, 0.94, 0.85, 1)
        sun.brightness = 1.15
        sun.castShadows = true

        local fillNode = scene:CreateChild("Fill")
        fillNode.rotation = Quaternion(30, 150, 0)
        local fill = fillNode:CreateComponent("Light")
        fill.lightType = LIGHT_DIRECTIONAL
        fill.color = Color(0.45, 0.55, 0.75, 1)
        fill.brightness = 0.35

        local floorNode = scene:CreateChild("Floor")
        floorNode.position = Vector3(0, -0.06, 0)
        floorNode.scale = Vector3(14, 0.12, 14)
        local floorModel = floorNode:CreateComponent("StaticModel")
        floorModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local floorMaterial = Material:new()
        floorMaterial:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        floorMaterial:SetShaderParameter("MatDiffColor", Variant(Color(0.32, 0.34, 0.38, 1)))
        floorMaterial:SetShaderParameter("Roughness", Variant(0.85))
        floorMaterial:SetShaderParameter("Metallic", Variant(0.02))
        floorModel:SetMaterial(floorMaterial)

        cameraNode = scene:CreateChild("Camera")
        local camera = cameraNode:CreateComponent("Camera")
        camera.nearClip = 0.05
        camera.farClip = 200
        renderer:SetViewport(0, Viewport:new(scene, camera))

        local fakeRenderer = { modelCache = ProceduralModelCache.new() }
        preview = CameraPreviewController.new(scene, fakeRenderer, cameraNode, {})
        preview.root:SetEnabled(true)
        if preview.root.SetDeepEnabled then preview.root:SetDeepEnabled(true) end
        preview.thirdPersonRoot:SetEnabled(true)
        preview.character.position = Vector3(0, 0, 0)
        preview.character.rotation = Quaternion(0, Vector3.UP)
        local groundMarker = preview.thirdPersonRoot:GetChild("GroundMarker", true)
        if groundMarker then groundMarker:SetEnabled(false) end
        local chest = preview.rig:GetChild("Chest", true)
        print(string.format("[knight-viewer] root=%s third=%s visual=%s rig=%s chest=%s",
            tostring(preview.root.enabled), tostring(preview.thirdPersonRoot.enabled),
            tostring(preview.visual.enabled), tostring(preview.rig.enabled),
            chest and tostring(chest.worldPosition) or "nil"))
        AimCamera(shots[1])
        SubscribeToEvent("Update", "HandleViewerUpdate")
    end, debug.traceback)
    if not ok then Fail(message) end
end

function HandleViewerUpdate(eventType, eventData)
    local timeStep = eventData:GetFloat("TimeStep")
    elapsed = elapsed + timeStep
    if elapsed > 30 then Fail("viewer timed out") end
    shotTimer = shotTimer + timeStep
    if shotTimer < 1.0 then return end

    local shot = shots[shotIndex]
    local screenshot = Image()
    if not graphics:TakeScreenShot(screenshot)
        or not screenshot:SavePNG(".tmp/knight-viewer-" .. shot.name .. ".png") then
        Fail(shot.name .. " capture failed")
        return
    end
    print("[knight-viewer] captured " .. shot.name)

    shotIndex = shotIndex + 1
    shotTimer = 0
    if shotIndex > #shots then
        WriteResult("PASS captured front/side/back portraits")
        print("[knight-viewer] PASS")
        UnsubscribeFromEvent("Update")
        engine:Exit()
        return
    end
    AimCamera(shots[shotIndex])
end

function Stop()
    if preview then preview:Dispose(); preview = nil end
end
