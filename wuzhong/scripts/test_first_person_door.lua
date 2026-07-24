local FirstPersonDoorSystem = require("Gameplay.FirstPersonDoorSystem")
local BgeoDungeonRenderer = require("Rendering.BgeoDungeonRenderer")

local function Check(condition, message)
    if not condition then error(message, 2) end
end

local function Near(actual, expected, tolerance)
    return math.abs(actual - expected) <= (tolerance or 0.001)
end

function Start()
    local ok, errorMessage = xpcall(function()
        local scene = Scene()
        local system = FirstPersonDoorSystem.new()
        local ignored = scene:CreateChild("IgnoredDoor")
        Check(system:Register(ignored, { interactive_door = false }) == nil,
            "non-interactive rule was registered")

        local frontNode = scene:CreateChild("FrontDoor")
        frontNode.position = Vector3(0, 0, -2)
        local front = system:Register(frontNode, {
            id = "front",
            interactive_door = true,
            door_open_angle = 100,
            door_open_duration = 0.45,
            door_interaction_distance = 300,
        })
        Check(front ~= nil and system:GetDoorCount() == 1, "interactive door was not registered")
        Check(Near(front.interactionDistance, 3.0), "centimeters were not converted to meters")

        local behindNode = scene:CreateChild("BehindDoor")
        behindNode.position = Vector3(0, 0, 1)
        system:Register(behindNode, {
            id = "behind", interactive_door = true, door_interaction_distance = 300,
        })
        local origin, forward = Vector3(0, 1, 0), Vector3(0, 0, -1)
        local selected = system:FindNearestDoor(origin, forward)
        Check(selected == front, "nearest forward-facing door was not selected")
        Check(system:FindNearestDoor(origin, Vector3(0, 0, 1)).id == "behind",
            "door behind the camera was not rejected")

        local interacted, door, opening = system:InteractNearestDoor(origin, forward)
        Check(interacted and door == front and opening, "door did not start opening")
        system:Update(0.225)
        local halfAngle = front.currentAngle
        Check(math.abs(halfAngle) > 0 and math.abs(halfAngle) < 100, "door did not animate")

        local reversed, reversedDoor, stillOpening = system:InteractNearestDoor(origin, forward)
        Check(reversed and reversedDoor == front and not stillOpening, "door did not reverse toward closed")
        system:Update(0.45)
        Check(Near(front.currentAngle, 0), "door did not reach exact closed angle")
        Check(Near(frontNode.rotation:YawAngle(), 0, 0.01), "door did not restore closed rotation")

        system:InteractNearestDoor(origin, forward)
        system:Update(0.45)
        Check(Near(math.abs(front.currentAngle), 100), "door did not reach exact open angle")
        Check(Near(math.abs(frontNode.rotation:YawAngle()), 100, 0.01), "door node did not reach open rotation")

        local renderer = BgeoDungeonRenderer.new(scene)
        local rebuilt, stats = renderer:Rebuild()
        Check(rebuilt, "BGEO renderer rebuild failed: " .. tostring(stats))
        Check(stats.doors > 0, "BGEO manifest registered no interactive door leaves")
        Check(renderer.doorSystem:GetDoorCount() == stats.doors, "BGEO door count is inconsistent")
        Check(Near(renderer.doorSystem.doors[1].interactionDistance, 3.0),
            "BGEO door interaction distance is not 3 m")
        renderer:Dispose()

        scene:Dispose()
        print(string.format(
            "[FirstPersonDoor] PASS registration, range, facing, toggle, reversal, animation, bgeo=%d doors",
            stats.doors))
    end, debug.traceback)
    if not ok then
        ErrorExit("[FirstPersonDoor] FAIL\n" .. tostring(errorMessage), 1)
        return
    end
    engine:Exit()
end
