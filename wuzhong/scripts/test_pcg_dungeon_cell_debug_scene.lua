local PCGDungeonGenerator = require("Generation.PCGDungeonGenerator")
local PCGDungeonMarkerPipeline = require("Generation.PCGDungeonMarkerPipeline")
local PCGDungeonRenderer = require("Rendering.PCGDungeonRenderer")
local ForgeCameraController = require("Input.ForgeCameraController")

---@type Scene|nil
local scene = nil
---@type PCGDungeonRenderer|nil
local pcgDungeonRenderer = nil
local elapsed = 0
local screenshotPath = ".tmp/pcgDungeon-cell-debug-scene.png"

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

        local dungeon = PCGDungeonGenerator.Generate({
            seed = 5, floorCount = 3, roomCount = 22, cellSize = 5.0,
        })
        assert(dungeon.valid, dungeon.error or "PCG Dungeon generation failed")
        local markerResult = PCGDungeonMarkerPipeline.GenerateFromTopology(dungeon.topology, {
            cellSize = 5.0, pillarPlacementDistance = 1.2,
        })

        pcgDungeonRenderer = PCGDungeonRenderer.new(scene)
        local built, stats = pcgDungeonRenderer:RebuildFromMarkers(markerResult, {
            rooms = dungeon.rooms,
            cells = dungeon.topology.cells,
            cellSize = 5.0,
        })
        assert(built, tostring(stats))

        local controller = ForgeCameraController.new(cameraNode, camera)
        controller.defaultTarget = Vector3(0, 5.0, 0)
        controller.defaultDistance = math.max(80, math.max(dungeon.width, dungeon.height) * 4.25)
        controller:Reset()

        local visible, cellStats = pcgDungeonRenderer:SetCellDebugVisible(true)
        assert(visible and cellStats.total > 0, "cell debug geometry was not created")
        assert(pcgDungeonRenderer.root == nil and #pcgDungeonRenderer.groups == 0,
            "the final dungeon geometry remained alive in cell debug mode")

        SubscribeToEvent("Update", "HandlePCGDungeonCellDebugSceneUpdate")
    end, debug.traceback)
    if not ok then
        WriteResult("FAIL startup\n" .. tostring(err))
        ErrorExit("[pcgDungeon-cell-debug-scene] FAIL\n" .. tostring(err), 1)
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandlePCGDungeonCellDebugSceneUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed < 2.0 then return end
    if not fileSystem:DirExists(".tmp") then fileSystem:CreateDir(".tmp") end
    local screenshot = Image()
    local saved = graphics:TakeScreenShot(screenshot) and screenshot:SavePNG(screenshotPath)
    screenshot:Dispose()
    if not saved then
        WriteResult("FAIL screenshot capture")
        ErrorExit("[pcgDungeon-cell-debug-scene] FAIL screenshot", 1)
        return
    end
    WriteResult(string.format("PASS rooms=%d corridors=%d stairs=%d total=%d",
        pcgDungeonRenderer.cellDebugStats.rooms, pcgDungeonRenderer.cellDebugStats.corridors,
        pcgDungeonRenderer.cellDebugStats.stairs, pcgDungeonRenderer.cellDebugStats.total))
    UnsubscribeFromEvent("Update")
    engine:Exit()
end

function Stop()
    renderer:SetViewport(0, nil)
    if pcgDungeonRenderer then pcgDungeonRenderer:Dispose(); pcgDungeonRenderer = nil end
    if scene then scene:Dispose(); scene = nil end
end
