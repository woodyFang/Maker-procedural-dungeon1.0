local FirstPersonDoorSystem = {}
FirstPersonDoorSystem.__index = FirstPersonDoorSystem

local DEFAULT_OPEN_ANGLE = 90
local DEFAULT_OPEN_DURATION = 0.45
local DEFAULT_INTERACTION_DISTANCE_CM = 300
local INTERACTION_HEIGHT = 1.0
local MIN_FACING_DOT = 0.25
local EPSILON = 0.0001

local function Clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function SmoothStep(value)
    value = Clamp(value, 0, 1)
    return value * value * (3 - 2 * value)
end

local function HorizontalLengthSquared(value)
    return value.x * value.x + value.z * value.z
end

local function Dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

function FirstPersonDoorSystem.new()
    return setmetatable({ doors = {} }, FirstPersonDoorSystem)
end

function FirstPersonDoorSystem:Clear()
    self.doors = {}
end

function FirstPersonDoorSystem:Register(node, rule, id)
    if not node or type(rule) ~= "table" or rule.interactive_door ~= true then return nil end
    local angle = math.abs(tonumber(rule.door_open_angle) or DEFAULT_OPEN_ANGLE)
    local duration = math.max(EPSILON, tonumber(rule.door_open_duration) or DEFAULT_OPEN_DURATION)
    local distanceCm = math.max(0, tonumber(rule.door_interaction_distance)
        or DEFAULT_INTERACTION_DISTANCE_CM)
    local door = {
        id = id or rule.id or ("door-" .. (#self.doors + 1)),
        node = node,
        closedRotation = Quaternion(node.rotation),
        openAngle = angle,
        openDuration = duration,
        interactionDistance = distanceCm * 0.01,
        currentAngle = 0,
        fromAngle = 0,
        targetAngle = 0,
        openSign = nil,
        animationElapsed = duration,
        animationDuration = duration,
    }
    self.doors[#self.doors + 1] = door
    return door
end

function FirstPersonDoorSystem:GetDoorCount()
    return #self.doors
end

-- Interaction volume (top view):
--
--                  door pivot D
--                              .
--                           .     max radius: manifest distance (3 m by default)
--                        .
--             camera C --------> view direction / forward cone
--
-- The interaction point is lifted from the floor-level hinge to the door body.
-- Doors behind the camera, on another floor, or outside the radius are rejected;
-- among overlapping candidates the nearest facing door wins. Repeated input while
-- animating reverses from the current angle without snapping.
function FirstPersonDoorSystem:FindNearestDoor(origin, forward)
    if not origin or not forward then return nil end
    local forwardLengthSquared = HorizontalLengthSquared(forward)
    if forwardLengthSquared <= EPSILON then return nil end
    local inverseForwardLength = 1 / math.sqrt(forwardLengthSquared)
    local view = Vector3(forward.x * inverseForwardLength, 0, forward.z * inverseForwardLength)
    local nearest, nearestDistance = nil, math.huge

    for _, door in ipairs(self.doors) do
        if door.node then
            local point = door.node.worldPosition + Vector3(0, INTERACTION_HEIGHT, 0)
            local delta = point - origin
            local distance = math.sqrt(delta:LengthSquared())
            local horizontalLengthSquared = HorizontalLengthSquared(delta)
            local facing = -1
            if horizontalLengthSquared > EPSILON then
                local inverseLength = 1 / math.sqrt(horizontalLengthSquared)
                facing = Dot(view, Vector3(delta.x * inverseLength, 0, delta.z * inverseLength))
            end
            if distance <= door.interactionDistance and facing >= MIN_FACING_DOT
                and distance < nearestDistance then
                nearest, nearestDistance = door, distance
            end
        end
    end
    return nearest, nearestDistance
end

function FirstPersonDoorSystem:ChooseOpenSign(door, origin)
    local yaw = math.rad(door.node.worldRotation:YawAngle())
    local doorNormal = Vector3(-math.sin(yaw), 0, -math.cos(yaw))
    local relative = origin - door.node.worldPosition
    return Dot(relative, doorNormal) >= 0 and -1 or 1
end

function FirstPersonDoorSystem:ToggleDoor(door, origin)
    if not door then return false end
    door.fromAngle = door.currentAngle
    if math.abs(door.targetAngle) > EPSILON then
        door.targetAngle = 0
    else
        door.openSign = door.openSign or self:ChooseOpenSign(door, origin)
        door.targetAngle = door.openSign * door.openAngle
    end
    local remaining = math.abs(door.targetAngle - door.currentAngle)
    door.animationDuration = math.max(EPSILON, door.openDuration * remaining / math.max(EPSILON, door.openAngle))
    door.animationElapsed = 0
    return true, math.abs(door.targetAngle) > EPSILON
end

function FirstPersonDoorSystem:InteractNearestDoor(origin, forward)
    local door, distance = self:FindNearestDoor(origin, forward)
    if not door then
        print("[DoorInteraction] no door in range and view")
        return false
    end
    local _, opening = self:ToggleDoor(door, origin)
    print(string.format("[DoorInteraction] %s id=%s distance=%.2fm",
        opening and "open" or "close", tostring(door.id), distance))
    return true, door, opening
end

function FirstPersonDoorSystem:Update(timeStep)
    for _, door in ipairs(self.doors) do
        if door.node and math.abs(door.currentAngle - door.targetAngle) > EPSILON then
            door.animationElapsed = math.min(door.animationDuration,
                door.animationElapsed + math.max(0, timeStep or 0))
            local alpha = SmoothStep(door.animationElapsed / door.animationDuration)
            door.currentAngle = door.fromAngle + (door.targetAngle - door.fromAngle) * alpha
            if door.animationElapsed >= door.animationDuration then door.currentAngle = door.targetAngle end
            door.node.rotation = door.closedRotation * Quaternion(door.currentAngle, Vector3.UP)
        end
    end
end

return FirstPersonDoorSystem
