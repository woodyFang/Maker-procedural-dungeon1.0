local UI = require("urhox-libs/UI")

local ForgeCameraController = {}
ForgeCameraController.__index = ForgeCameraController

local EDIT_TRANSITION_DURATION = 0.45
local EDIT_PITCH = 90.0
local EDIT_CAMERA_HEIGHT = 60.0
local MIN_EDIT_ORTHO_SIZE = 5.0
local MIN_OVERVIEW_DISTANCE = 45.0
local ZOOM_RATE = 0.12
local KEYBOARD_PAN_SCALE = 0.75
local MIN_KEYBOARD_PAN_SPEED = 20.0
local MAX_KEYBOARD_PAN_SPEED = 180.0
local FAST_PAN_MULTIPLIER = 2.5

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function CopyVector3(value)
    return Vector3(value.x, value.y, value.z)
end

local function EaseInOut(value)
    if value < 0.5 then return 2 * value * value end
    return 1 - ((-2 * value + 2) ^ 2) * 0.5
end

local function ShortestAngleTarget(fromAngle, toAngle)
    local delta = ((toAngle - fromAngle + 180) % 360) - 180
    return fromAngle + delta
end

local function IsTextInputFocused()
    local focused = UI.GetFocus and UI.GetFocus() or nil
    if not focused then return false end
    local isTextInput = focused._className == "TextField" or focused._className == "TextArea"
    return isTextInput and focused.state and focused.state.focused == true
end

local function IsPhysicalKeyDown(key, scancode)
    -- Scancodes keep editor controls reliable while a non-Latin IME or keyboard
    -- layout is active. Keep the logical key fallback for platform compatibility.
    return input:GetScancodeDown(scancode) or input:GetKeyDown(key)
end

function ForgeCameraController.new(cameraNode, camera)
    return setmetatable({
        cameraNode = cameraNode,
        camera = camera,
        target = Vector3(0, 2, 0),
        yaw = 45,
        pitch = math.deg(0.64),
        distance = 170,
        defaultTarget = Vector3(0, 2, 0),
        defaultDistance = 170,
        enabled = true,
        editViewActive = false,
        editPlaneY = 0,
        editLeftPanActive = false,
        editPanAnchor = nil,
        savedView = nil,
        transition = nil,
    }, ForgeCameraController)
end

function ForgeCameraController.ZoomValue(value, wheelStep, minimum)
    return math.max(minimum, value * math.exp(-wheelStep * ZOOM_RATE))
end

function ForgeCameraController.GrabPanDelta(yawDegrees, moveX, moveY, worldPerPixel)
    local yaw = math.rad(yawDegrees)
    return Vector3(
        (moveX * math.cos(yaw) - moveY * math.sin(yaw)) * worldPerPixel,
        0,
        (-moveX * math.sin(yaw) - moveY * math.cos(yaw)) * worldPerPixel
    )
end

function ForgeCameraController.ZoomAnchorTarget(target, cursorWorld, oldSize, newSize)
    -- Keep the world point under the cursor stationary while the orthographic
    -- size changes. This is exact for a top-down ortho camera because the
    -- screen->world mapping is linear in orthoSize: worldXZ = target.xz + k *
    -- orthoSize, where k depends only on the (fixed) cursor position this frame.
    -- Solving analytically from a single pre-zoom sample avoids the per-notch
    -- drift that a second post-zoom GetScreenRay sample accumulates.
    if not cursorWorld or not oldSize or oldSize <= 0 then return target end
    local ratio = 1 - newSize / oldSize
    return Vector3(
        target.x + (cursorWorld.x - target.x) * ratio,
        target.y,
        target.z + (cursorWorld.z - target.z) * ratio
    )
end

function ForgeCameraController:FrameDungeon(dungeon, currentFloor)
    local span = math.max(dungeon.width, dungeon.height)
    local floor = currentFloor or 0
    self.defaultTarget = Vector3(0, floor * dungeon.floorHeight + 1.4, 0)
    local fitSpan = span * 1.18
    self.defaultDistance = math.max(70, fitSpan / (2 * math.tan(math.rad(45) * 0.5)))
    if self.editViewActive and self.camera then
        self.editPlaneY = floor * dungeon.floorHeight + 0.22
        self.target = Vector3(0, self.editPlaneY, 0)
        self.camera.orthoSize = math.max(
            MIN_EDIT_ORTHO_SIZE,
            2 * self.defaultDistance * math.tan(math.rad(self.camera.fov or 45) * 0.5)
        )
        self:ApplyEditView()
    else
        self:Reset()
    end
end

function ForgeCameraController:Reset()
    self.target = Vector3(self.defaultTarget.x, self.defaultTarget.y, self.defaultTarget.z)
    self.yaw = 45
    self.pitch = math.deg(0.64)
    self.distance = self.defaultDistance
    self:Apply()
end

function ForgeCameraController:FrameEditView()
    -- "Frame all" for the orthographic edit view, mirroring the F shortcut in
    -- DCC 3D tools: recenter on the layout origin and refit the frustum so the
    -- whole floor is visible again. Instant on purpose so the reset feels snappy.
    if not self.editViewActive or self.transition or not self.camera then return false end
    if IsTextInputFocused() then return false end
    self.target = Vector3(self.defaultTarget.x, self.editPlaneY, self.defaultTarget.z)
    self.camera.orthoSize = math.max(
        MIN_EDIT_ORTHO_SIZE,
        2 * self.defaultDistance * math.tan(math.rad(self.camera.fov or 45) * 0.5)
    )
    self:ApplyEditView()
    return true
end

function ForgeCameraController:SetTargetFloor(dungeon, floor)
    self.defaultTarget = Vector3(
        self.defaultTarget.x,
        floor * dungeon.floorHeight + 1.4,
        self.defaultTarget.z
    )
    if self.editViewActive then
        self.editPlaneY = floor * dungeon.floorHeight + 0.22
        self.target = Vector3(self.target.x, self.editPlaneY, self.target.z)
        self:ApplyEditView()
    else
        self.target = Vector3(self.target.x, self.defaultTarget.y, self.target.z)
        self:Apply()
    end
end

function ForgeCameraController:Apply()
    -- Zoom-out is intentionally unbounded. Grow the far plane with distance so
    -- the dungeon does not disappear after the former distance cap is crossed.
    self.camera.farClip = math.max(1000, self.distance * 2.0)
    local yaw = math.rad(self.yaw)
    local pitch = math.rad(self.pitch)
    local horizontal = math.cos(pitch) * self.distance
    self.cameraNode.position = Vector3(
        self.target.x + math.sin(yaw) * horizontal,
        self.target.y + math.sin(pitch) * self.distance,
        self.target.z + math.cos(yaw) * horizontal
    )
    if math.abs(horizontal) < 0.0001 then
        -- A straight-down camera is singular with the default Y-up LookAt.
        -- Use world -Z as screen-up so edit mode is an exact, stable top view.
        self.cameraNode:LookAt(self.target, Vector3(0, 0, -1), TS_WORLD)
    else
        self.cameraNode:LookAt(self.target)
    end
end

function ForgeCameraController:ApplyEditView()
    self.cameraNode.position = Vector3(
        self.target.x,
        self.target.y + EDIT_CAMERA_HEIGHT,
        self.target.z
    )
    self.cameraNode:LookAt(self.target, Vector3(0, 0, -1), TS_WORLD)
end

function ForgeCameraController:CaptureView()
    return {
        target = CopyVector3(self.target),
        yaw = self.yaw,
        pitch = self.pitch,
        distance = self.distance,
    }
end

function ForgeCameraController:IsTransitioning()
    return self.transition ~= nil
end

function ForgeCameraController:IsEditViewActive()
    return self.editViewActive
end

function ForgeCameraController:UsePerspectiveView()
    if self.transition or not self.camera then return false end
    if self.editViewActive and self.savedView then
        self.target = CopyVector3(self.savedView.target)
        self.yaw = self.savedView.yaw
        self.pitch = self.savedView.pitch
        self.distance = self.savedView.distance
    end
    self.editViewActive = false
    self.editLeftPanActive, self.editPanAnchor = false, nil
    self.savedView = nil
    self.camera.orthographic = false
    self.camera.zoom = 1
    self.enabled = true
    self:Apply()
    return true
end

function ForgeCameraController:BeginEditView(planeY)
    if self.transition or self.editViewActive or not self.camera then return false end

    self.editLeftPanActive, self.editPanAnchor = false, nil
    self.savedView = self:CaptureView()
    self.editPlaneY = planeY or self.target.y
    self.camera.orthographic = false
    self.enabled = false

    local fov = math.rad(self.camera.fov or 45)
    local orthoSize = 2 * self.distance * math.tan(fov * 0.5)
    self.transition = {
        phase = "in",
        elapsed = 0,
        duration = EDIT_TRANSITION_DURATION,
        orthoSize = math.max(MIN_EDIT_ORTHO_SIZE, orthoSize),
        from = self:CaptureView(),
        to = {
            target = Vector3(self.target.x, self.editPlaneY, self.target.z),
            yaw = ShortestAngleTarget(self.yaw, 0),
            pitch = EDIT_PITCH,
            distance = self.distance,
        },
    }
    print(string.format("[DungeonForge] edit camera entering orthoSize=%.2f", self.transition.orthoSize))
    return true
end

function ForgeCameraController:BeginExitEditView()
    if self.transition or not self.editViewActive or not self.camera then return false end

    self.editLeftPanActive, self.editPanAnchor = false, nil
    local saved = self.savedView or {
        target = CopyVector3(self.defaultTarget), yaw = 45,
        pitch = math.deg(0.64), distance = self.defaultDistance,
    }
    local fov = math.rad(self.camera.fov or 45)
    local perspectiveDistance = self.camera.orthoSize / math.max(0.001, 2 * math.tan(fov * 0.5))
    self.yaw = 0
    self.pitch = EDIT_PITCH
    self.distance = perspectiveDistance
    self.camera.orthographic = false
    self.editViewActive = false
    self:Apply()

    self.transition = {
        phase = "out",
        elapsed = 0,
        duration = EDIT_TRANSITION_DURATION,
        from = self:CaptureView(),
        to = {
            -- Match the original: restore the orbit pose but remain centered on
            -- the part of the dungeon the user was editing.
            target = Vector3(self.target.x, saved.target.y, self.target.z),
            yaw = ShortestAngleTarget(self.yaw, saved.yaw),
            pitch = saved.pitch,
            distance = saved.distance,
        },
    }
    print("[DungeonForge] edit camera leaving orthographic view")
    return true
end

function ForgeCameraController:UpdateTransition(timeStep)
    local transition = self.transition
    if not transition then return nil, false end

    transition.elapsed = math.min(transition.duration, transition.elapsed + timeStep)
    local progress = transition.duration > 0 and transition.elapsed / transition.duration or 1
    local eased = EaseInOut(progress)
    local from, to = transition.from, transition.to
    self.yaw = from.yaw + (to.yaw - from.yaw) * eased
    self.pitch = from.pitch + (to.pitch - from.pitch) * eased
    self.distance = from.distance + (to.distance - from.distance) * eased
    self.target = Vector3(
        from.target.x + (to.target.x - from.target.x) * eased,
        from.target.y + (to.target.y - from.target.y) * eased,
        from.target.z + (to.target.z - from.target.z) * eased
    )
    self:Apply()

    if progress < 1 then return transition.phase, false end

    local phase = transition.phase
    self.transition = nil
    if phase == "in" then
        self.yaw = 0
        self.pitch = EDIT_PITCH
        self.target = CopyVector3(to.target)
        self.camera.orthographic = true
        self.camera.orthoSize = transition.orthoSize
        self.camera.zoom = 1
        self.editViewActive = true
        self:ApplyEditView()
        print("[DungeonForge] orthographic edit camera active")
    else
        self.yaw = to.yaw
        self.pitch = to.pitch
        self.distance = to.distance
        self.target = CopyVector3(to.target)
        self.camera.orthographic = false
        self.savedView = nil
        self.enabled = true
        self:Apply()
        print("[DungeonForge] overview camera restored")
    end
    return phase, true
end

function ForgeCameraController:ScreenToPlane(mousePosition, planeY)
    if not self.camera then return nil end
    local width, height = graphics:GetWidth(), graphics:GetHeight()
    if width <= 0 or height <= 0 then return nil end
    local ray = self.camera:GetScreenRay(mousePosition.x / width, mousePosition.y / height)
    if math.abs(ray.direction.y) < 0.0001 then return nil end
    local distance = (planeY - ray.origin.y) / ray.direction.y
    if distance < 0 then return nil end
    return ray.origin + ray.direction * distance
end

function ForgeCameraController:ScreenToEditPlane(mousePosition)
    return self:ScreenToPlane(mousePosition, self.editPlaneY)
end

function ForgeCameraController:ApplyPointerAnchor(anchor, current)
    if not anchor or not current then return false end
    local deltaX, deltaZ = anchor.x - current.x, anchor.z - current.z
    if math.abs(deltaX) < 0.000001 and math.abs(deltaZ) < 0.000001 then return false end
    -- Vector3 is returned through the binding as a value. Mutating target.x/z
    -- writes into a temporary copy, so always assign the complete vector back.
    self.target = Vector3(self.target.x + deltaX, self.target.y, self.target.z + deltaZ)
    return true
end

function ForgeCameraController:ApplyKeyboardPan(timeStep, orthographic)
    if not timeStep or timeStep <= 0 or IsTextInputFocused() then return false end

    local forward = 0
    local right = 0
    if IsPhysicalKeyDown(KEY_W, SCANCODE_W) or IsPhysicalKeyDown(KEY_UP, SCANCODE_UP) then
        forward = forward + 1
    end
    if IsPhysicalKeyDown(KEY_S, SCANCODE_S) or IsPhysicalKeyDown(KEY_DOWN, SCANCODE_DOWN) then
        forward = forward - 1
    end
    if IsPhysicalKeyDown(KEY_D, SCANCODE_D) or IsPhysicalKeyDown(KEY_RIGHT, SCANCODE_RIGHT) then
        right = right + 1
    end
    if IsPhysicalKeyDown(KEY_A, SCANCODE_A) or IsPhysicalKeyDown(KEY_LEFT, SCANCODE_LEFT) then
        right = right - 1
    end
    if forward == 0 and right == 0 then return false end

    local inputLength = math.sqrt(forward * forward + right * right)
    forward = forward / inputLength
    right = right / inputLength

    local viewHeight
    if orthographic then
        viewHeight = self.camera.orthoSize
    else
        local fov = math.rad(self.camera.fov or 45)
        viewHeight = 2 * self.distance * math.tan(fov * 0.5)
    end
    local speed = Clamp(
        viewHeight * KEYBOARD_PAN_SCALE,
        MIN_KEYBOARD_PAN_SPEED,
        MAX_KEYBOARD_PAN_SPEED
    )
    if IsPhysicalKeyDown(KEY_LSHIFT, SCANCODE_LSHIFT)
        or IsPhysicalKeyDown(KEY_RSHIFT, SCANCODE_RSHIFT) then
        speed = speed * FAST_PAN_MULTIPLIER
    end

    -- Move parallel to the floor and relative to the current camera heading.
    -- At yaw 0 the camera looks toward -Z. In UrhoX's left-handed coordinate
    -- system its screen-right direction is -X, so D advances along -X.
    local yaw = math.rad(self.yaw)
    local step = speed * timeStep
    self.target = Vector3(
        self.target.x + (-right * math.cos(yaw) - forward * math.sin(yaw)) * step,
        self.target.y,
        self.target.z + (right * math.sin(yaw) - forward * math.cos(yaw)) * step
    )
    return true
end

function ForgeCameraController:UpdateEditView(timeStep, allowLeftPan)
    if not self.editViewActive or self.transition or not self.camera then return false end
    allowLeftPan = allowLeftPan == true

    local pointerOverUI = UI.IsPointerOverUI()
    local mousePosition = input.mousePosition
    local changed = false
    local wheel = input.mouseMoveWheel
    if wheel ~= 0 and not pointerOverUI then
        -- Sample the cursor's world point once, at the current zoom, then solve
        -- for the target that keeps it fixed. Sampling the ray a second time
        -- after the zoom let tiny projection differences accumulate into
        -- per-notch drift, so the new target is computed directly instead.
        local cursorWorld = self:ScreenToEditPlane(mousePosition)
        local wheelStep = wheel > 0 and 1 or -1
        local oldSize = self.camera.orthoSize
        local newSize = ForgeCameraController.ZoomValue(oldSize, wheelStep, MIN_EDIT_ORTHO_SIZE)
        self.camera.orthoSize = newSize
        self.target = ForgeCameraController.ZoomAnchorTarget(
            self.target, cursorWorld, oldSize, newSize)
        self:ApplyEditView()
        changed = true
    end

    local altDown = input:GetKeyDown(KEY_LALT) or input:GetKeyDown(KEY_RALT)
    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    local middleDown = input:GetMouseButtonDown(MOUSEB_MIDDLE)
    local panDown = middleDown or (leftDown and (allowLeftPan or altDown))
    if not panDown then
        self.editLeftPanActive, self.editPanAnchor = false, nil
    elseif self.editLeftPanActive or not pointerOverUI then
        if not self.editLeftPanActive then
            self.editLeftPanActive = true
            self.editPanAnchor = self:ScreenToEditPlane(mousePosition)
        end
        local current = self:ScreenToEditPlane(mousePosition)
        if self:ApplyPointerAnchor(self.editPanAnchor, current) then
            self:ApplyEditView()
            changed = true
        end
    end

    local keyboardMoved = self:ApplyKeyboardPan(timeStep, true)
    if keyboardMoved then
        self:ApplyEditView()
    end
    return keyboardMoved or changed
end

function ForgeCameraController:Update(timeStep, allowLeftPan, pointerBlocked)
    if not self.enabled then return false end
    if allowLeftPan == nil then allowLeftPan = true end
    local pointerOverUI = pointerBlocked == true or UI.IsPointerOverUI()
    if not IsTextInputFocused() and (input:GetKeyPress(KEY_HOME) or input:GetKeyPress(KEY_F)) then
        self:Reset()
    end

    local wheel = input.mouseMoveWheel
    if wheel ~= 0 and not pointerOverUI then
        -- Match the original browser's per-wheel-event factor. UrhoX may
        -- aggregate wheel units per frame, so normalize the input first.
        local mousePosition = input.mousePosition
        local before = self:ScreenToPlane(mousePosition, self.target.y)
        local wheelStep = wheel > 0 and 1 or -1
        self.distance = ForgeCameraController.ZoomValue(
            self.distance, wheelStep, MIN_OVERVIEW_DISTANCE)
        self:Apply()
        local after = self:ScreenToPlane(mousePosition, self.target.y)
        if self:ApplyPointerAnchor(before, after) then self:Apply() end
    end

    local move = input.mouseMove
    local leftDown = allowLeftPan and input:GetMouseButtonDown(MOUSEB_LEFT)
    local middleDown = input:GetMouseButtonDown(MOUSEB_MIDDLE)
    local rightDown = input:GetMouseButtonDown(MOUSEB_RIGHT)
    if (leftDown or middleDown or rightDown) and not pointerOverUI then
        if rightDown or input:GetKeyDown(KEY_LSHIFT) or input:GetKeyDown(KEY_RSHIFT) then
            self.yaw = self.yaw + move.x * math.deg(0.005)
            self.pitch = Clamp(self.pitch + move.y * math.deg(0.005), -math.deg(1.5), math.deg(1.5))
        elseif input:GetKeyDown(KEY_LCTRL) or input:GetKeyDown(KEY_RCTRL) then
            local viewHeight = 2 * self.distance * math.tan(math.rad(45) * 0.5)
            self.target = Vector3(
                self.target.x,
                self.target.y + move.y * viewHeight / math.max(1, graphics:GetHeight()),
                self.target.z
            )
        else
            local viewHeight = 2 * self.distance * math.tan(math.rad(45) * 0.5)
            local worldPerPixel = viewHeight / math.max(1, graphics:GetHeight())
            local delta = ForgeCameraController.GrabPanDelta(
                self.yaw, move.x, move.y, worldPerPixel)
            self.target = Vector3(
                self.target.x + delta.x,
                self.target.y,
                self.target.z + delta.z
            )
        end
    end
    local keyboardMoved = self:ApplyKeyboardPan(timeStep, false)
    self:Apply()
    return keyboardMoved
end

return ForgeCameraController
