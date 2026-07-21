local ShadowCastleGenerator = require("Generation.ShadowCastleGenerator")
local HoudiniMarkerPipeline = require("Generation.HoudiniMarkerPipeline")
local BgeoDungeonRenderer = require("Rendering.BgeoDungeonRenderer")
local ForgeCameraController = require("Input.ForgeCameraController")

---@type Scene|nil
local scene = nil
---@type BgeoDungeonRenderer|nil
local bgeoRenderer = nil
local elapsed = 0
local screenshotPath = ".tmp/bgeo-cell-debug-scene.png"

for _, argument in ipairs(GetArguments()) do
    local configuredPath = argument:match("^%-smoke_output=(.+)$")
    if configuredPath then screenshotPath = configuredPath end
end

local function WriteResult(message)
    local result = File(screenshotPath .. ".result.txt", FILE_WRITE)
    if result and result:IsOpen() then
        result:WriteLine(message)
        result:Close()
    end
end

function Start()
    local ok, err = xpcall(function()
        scene = Scene()
        scene:CreateComponent("Octree")

        local lightGroup = scene:CreateChild("LightGroup")
        local lightFile = cache:GetResource("XMLFile", "LightGroup/Night.xml")
        assert(lightFile, "night light group was not found")
        lightGroup:LoadXML(lightFile:GetRoot())

        local cameraNode = scene:CreateChild("Camera")
        local camera = cameraNode:CreateComponent("Camera")
        camera.nearClip, camera.farClip, camera.fov = 0.1, 1000, 45
        renderer:SetViewport(0, Viewport:new(scene, camera))
        renderer.hdrRendering = false

        local dungeon = ShadowCastleGenerator.Generate({
            seed = 5, floorCount = 3, roomCount = 22, cellSize = 5.0,
        })
        assert(dungeon.valid, dungeon.error or "shadow castle generation failed")
        local markerResult = HoudiniMarkerPipeline.GenerateFromTopology(dungeon.topology, {
            cellSize = 5.0, pillarPlacementDistance = 1.2,
        })

        bgeoRenderer = BgeoDungeonRenderer.new(scene)
        local built, stats = bgeoRenderer:RebuildFromHoudini(markerResult, {
            rooms = dungeon.rooms,
            cells = dungeon.topology.cells,
            cellSize = 5.0,
        })
        assert(built, tostring(stats))

        local controller = ForgeCameraController.new(cameraNode, camera)
        controller.defaultTarget = Vector3(0, 5.0, 0)
        controller.defaultDistance = math.max(80, math.max(dungeon.width, dungeon.height) * 4.25)
        controller:Reset()

        local visible, cellStats = bgeoRenderer:SetCellDebugVisible(true)
        assert(visible and cellStats.total > 0, "cell debug geometry was not created")
        for _, group in ipairs(bgeoRenderer.groups) do
            assert(not group:IsEnabled(), "a dungeon StaticModelGroup remained enabled")
        end

        SubscribeToEvent("Update", "HandleBgeoCellDebugSceneUpdate")
    end, debug.traceback)
    if not ok then
        WriteResult("FAIL startup\n" .. tostring(err))
        ErrorExit("[bgeo-cell-debug-scene] FAIL\n" .. tostring(err), 1)
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleBgeoCellDebugSceneUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed < 2.0 then return end
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    local screenshot = Image()
    local saved = graphics:TakeScreenShot(screenshot) and screenshot:SavePNG(screenshotPath)
    screenshot:Dispose()
    if not saved then
        WriteResult("FAIL screenshot capture")
        ErrorExit("[bgeo-cell-debug-scene] FAIL screenshot", 1)
        return
    end
    WriteResult(string.format("PASS rooms=%d corridors=%d stairs=%d total=%d",
        bgeoRenderer.cellDebugStats.rooms, bgeoRenderer.cellDebugStats.corridors,
        bgeoRenderer.cellDebugStats.stairs, bgeoRenderer.cellDebugStats.total))
    UnsubscribeFromEvent("Update")
    engine:Exit()
end

function Stop()
    renderer:SetViewport(0, nil)
    if bgeoRenderer then bgeoRenderer:Dispose(); bgeoRenderer = nil end
    if scene then scene:Dispose(); scene = nil end
end
