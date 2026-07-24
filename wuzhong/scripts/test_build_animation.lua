local DungeonGenerator = require("Generation.DungeonGenerator")
local NativeDungeonRenderer = require("Rendering.NativeDungeonRenderer")

---@type Scene|nil
local scene = nil
---@type NativeDungeonRenderer|nil
local native = nil
local elapsed = 0
local resultPath = ".tmp/build-animation.result.txt"
local staticMetrics = nil
local layoutScreenshotTaken = false
local midScreenshotTaken = false
local completedAt = nil
local expectedDuration = 1.80
local deterministic = false

for _, argument in ipairs(GetArguments()) do
    local configuredPath = argument:match("^%-result_output=(.+)$")
    if configuredPath then resultPath = configuredPath end
    if argument == "-deterministic_animation" then deterministic = true end
end

local function WriteResult(message)
    local result = File(resultPath, FILE_WRITE)
    if result and result:IsOpen() then
        result:WriteLine(message)
        result:Close()
    end
end

local function FinishTest(takeScreenshot)
    local animated = native.lastBuildMetrics
    local frame = native.lastAnimationMetrics
    local batchParity = staticMetrics.batches == animated.batches
        and staticMetrics.instances == animated.instances
    if animated.stagedBatches <= 0 then
        WriteResult("FAIL geometry batches were not staged")
        ErrorExit("[build-animation-test] FAIL geometry staging unavailable", 1)
        return
    end
    if animated.materialAnimatedBatches ~= 0 then
        WriteResult("FAIL material animation is still active")
        ErrorExit("[build-animation-test] FAIL material animation active", 1)
        return
    end
    if math.abs(frame.duration - expectedDuration) > 0.08 then
        local message = string.format("FAIL animation duration %.3fs, expected %.2fs", frame.duration, expectedDuration)
        WriteResult(message)
        ErrorExit("[build-animation-test] " .. message, 1)
        return
    end
    local message = string.format(
        "PASS staticBuild=%.3fms animatedBuild=%.3fms batches=%d stagedBatches=%d materialAnimatedBatches=%d instances=%d overlayRooms=%d overlayBeams=%d batchParity=%s duration=%.3fs frames=%d avgUpdate=%.4fms maxUpdate=%.4fms",
        staticMetrics.buildMs, animated.buildMs, animated.batches, animated.stagedBatches,
        animated.materialAnimatedBatches, animated.instances,
        animated.overlayRooms or 0, animated.overlayBeams or 0,
        tostring(batchParity), frame.duration, frame.frames, frame.averageUpdateMs, frame.maxUpdateMs)
    if takeScreenshot then
        local finalScreenshot = Image()
        if graphics:TakeScreenShot(finalScreenshot) then
            finalScreenshot:SavePNG(".tmp/build-animation-final.png")
        end
    end
    WriteResult(message)
    print("[build-animation-test] " .. message)
    UnsubscribeFromEvent("Update")
    engine:Exit()
end

function Start()
    local ok, err = xpcall(function()
        scene = Scene()
        scene:CreateComponent("Octree")

        local zoneNode = scene:CreateChild("Zone")
        local zone = zoneNode:CreateComponent("Zone")
        zone.boundingBox = BoundingBox(Vector3(-1000, -1000, -1000), Vector3(1000, 1000, 1000))
        zone.ambientColor = Color(0.30, 0.36, 0.46, 1)
        zone.ambientIntensity = 1.2

        local sunNode = scene:CreateChild("Sun")
        sunNode.rotation = Quaternion(52, -36, 0)
        local sun = sunNode:CreateComponent("Light")
        sun.lightType = LIGHT_DIRECTIONAL
        sun.brightness = 1.2
        sun.castShadows = false

        local cameraNode = scene:CreateChild("Camera")
        cameraNode.position = Vector3(70, 64, -70)
        cameraNode:LookAt(Vector3(0, 2, 0))
        local camera = cameraNode:CreateComponent("Camera")
        camera.farClip = 1200
        renderer:SetViewport(0, Viewport:new(scene, camera))

        local dungeon = DungeonGenerator.Generate({
            seed = 2026071501, floorCount = 2, roomCountsByFloor = { 12, 12 },
            loopRatesByFloor = { 0.15, 0.15 }, decorDensitiesByFloor = { 0.60, 0.60 },
            settingKey = "dungeon", theme = "ancient",
        })
        assert(dungeon.valid, table.concat(dungeon.errors or {}, "; "))

        native = NativeDungeonRenderer.new(scene)
        native:Build(dungeon, "ancient", { settingKey = "dungeon", viewMode = "neighbors" })
        staticMetrics = native.lastBuildMetrics
        native:Build(dungeon, "ancient", {
            settingKey = "dungeon", viewMode = "neighbors", animate = true,
        })
        if deterministic then
            local fixedTimeStep = 1 / 120
            local safetyFrames = 0
            while native.animation and safetyFrames < 600 do
                native:Update(fixedTimeStep)
                safetyFrames = safetyFrames + 1
            end
            assert(not native.animation, "animation did not complete in deterministic mode")
            FinishTest(false)
        else
            SubscribeToEvent("Update", "HandleBuildAnimationTestUpdate")
        end
    end, debug.traceback)
    if not ok then
        WriteResult("FAIL startup\n" .. tostring(err))
        ErrorExit("[build-animation-test] FAIL startup\n" .. tostring(err), 1)
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleBuildAnimationTestUpdate(eventType, eventData)
    local timeStep = eventData:GetFloat("TimeStep")
    elapsed = elapsed + timeStep
    native:Update(timeStep)
    if not layoutScreenshotTaken and elapsed >= 0.18 then
        local screenshot = Image()
        if graphics:TakeScreenShot(screenshot) then
            screenshot:SavePNG(".tmp/build-animation-layout.png")
        end
        layoutScreenshotTaken = true
    end
    if not midScreenshotTaken and elapsed >= 1.00 then
        local screenshot = Image()
        if graphics:TakeScreenShot(screenshot) then
            screenshot:SavePNG(".tmp/build-animation-mid.png")
        end
        midScreenshotTaken = true
    end
    if not native.animation and native.lastAnimationMetrics then
        if not completedAt then completedAt = elapsed; return end
        if elapsed - completedAt < 0.10 then return end
        FinishTest(true)
    elseif elapsed > 9.0 then
        WriteResult("FAIL animation did not complete within 9 seconds")
        ErrorExit("[build-animation-test] FAIL timeout", 1)
    end
end
