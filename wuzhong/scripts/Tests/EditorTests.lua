local RouteEditing = require("UI.Editor.RouteEditing")
local StairEditing = require("UI.Editor.StairEditing")
local EditorData = require("UI.Editor.EditorData")
local PathWorkflow = require("UI.Editor.PathWorkflow")
local StairWorkflow = require("UI.Editor.StairWorkflow")
local EditorGizmos = require("UI.Editor.EditorGizmos")
local EditorInteraction = require("UI.Editor.EditorInteraction")
local EditorGesture = require("UI.Editor.EditorGesture")
local RoomEditing = require("UI.Editor.RoomEditing")
local EditorSession = require("UI.Editor.EditorSession")
local CanvasViewport = require("UI.Editor.CanvasViewport")
local SceneLayoutEditor = require("UI.SceneLayoutEditor")
local MultiFloor = require("Generation.MultiFloor")
local ForgeCameraController = require("Input.ForgeCameraController")

local EditorTests = {}

local function Check(condition, message)
    if not condition then error(message or "check failed", 2) end
end

local function SamePoint(point, x, y)
    return point and math.abs(point.x - x) < 0.000001 and math.abs(point.y - y) < 0.000001
end

local function TestRouteSimplification()
    local simplified = RouteEditing.Simplify({
        { x = 0, y = 0 }, { x = 2, y = 0 }, { x = 2, y = 0 },
        { x = 5, y = 0 }, { x = 5, y = 3 },
    })
    Check(#simplified == 3, "route simplification did not remove duplicate and collinear controls")
    Check(SamePoint(simplified[1], 0, 0) and SamePoint(simplified[2], 5, 0)
        and SamePoint(simplified[3], 5, 3), "route simplification changed path shape")
end

local function TestPathStraightening()
    local Editor = {}
    PathWorkflow.Install(Editor, { CopyLink = EditorData.CopyLink })
    local doorA, doorB = { side = "east", offset = 0.25 }, { side = "west", offset = -0.25 }
    local link = { a = 1, b = 2, kind = "corridor", doorA = doorA, doorB = doorB,
        bends = { { x = 8, y = 3 }, { x = 8, y = 7 }, { x = 14, y = 9 } },
        autoRoute = { { x = 1, y = 1 }, { x = 2, y = 1 } } }
    local fake = setmetatable({
        links = { link },
        LinkEndpoints = function()
            return { x = 5, y = 2, side = "east" }, { x = 17, y = 11, side = "west" }
        end,
        LinkRoute = function(self, current)
            local startPoint, endPoint = self:LinkEndpoints(current)
            local route = { startPoint }
            for _, point in ipairs(current.bends or {}) do route[#route + 1] = point end
            route[#route + 1] = endPoint
            return route
        end,
        RefreshOverlay = function(self) self.refreshCount = (self.refreshCount or 0) + 1 end,
        Commit = function(self) self.commitCount = (self.commitCount or 0) + 1 end,
    }, { __index = Editor })
    Check(fake:StraightenLink(link), "path straightening action failed")
    local aligned = fake:LinkRoute(link)
    Check(#link.bends >= 2, "path straightening removed the route's necessary turns")
    for index = 1, #aligned - 1 do
        local a, b = aligned[index], aligned[index + 1]
        Check(math.abs(a.x - b.x) < 0.000001 or math.abs(a.y - b.y) < 0.000001,
            "straightened path retained a diagonal segment at " .. index)
    end
    Check(link.doorA == doorA and link.doorB == doorB,
        "path straightening unexpectedly reset authored door points")
    Check(#link.autoRoute == 0 and link.isManual and fake.refreshCount == 1 and fake.commitCount == 1,
        "path straightening did not refresh and commit its authored route")
end

local function TestControlSnapping()
    local point = RouteEditing.SnapControlPoint({ x = 8.7, y = 4.3 }, {
        { x = 9, y = 20 }, { x = 30, y = 4 },
    }, 0.5)
    Check(SamePoint(point, 9, 4), "control point did not snap independently to nearby axes")
    local excluded = RouteEditing.SnapControlPoint({ x = 8.7, y = 4.3 }, {
        { x = 9, y = 20 },
    }, 0.5, { { x = 9, y = 20 } })
    Check(SamePoint(excluded, 9, 4), "excluded snap target broke integer grid fallback")
end

local function TestAnchoredBlankPan()
    local controller = ForgeCameraController.new(nil, nil)
    controller.target = Vector3(10, 2, 20)
    Check(controller:ApplyPointerAnchor(Vector3(4, 0, 8), Vector3(1, 0, 3)),
        "blank-space camera pan did not apply its world-space anchor delta")
    Check(math.abs(controller.target.x - 13) < 0.000001
        and math.abs(controller.target.z - 25) < 0.000001,
        "blank-space camera pan moved the edit target by the wrong delta")
    Check(not controller:ApplyPointerAnchor(Vector3(4, 0, 8), Vector3(4, 0, 8)),
        "stationary blank-space pan reported camera movement")
end

local function TestUnboundedCameraZoomOut()
    Check(ForgeCameraController.ZoomValue(360, -1, 45) > 360,
        "overview camera still stopped at its former zoom-out limit")
    Check(ForgeCameraController.ZoomValue(720, -1, 5) > 720,
        "edit camera still stopped at its former zoom-out limit")
    Check(ForgeCameraController.ZoomValue(5, 1, 5) == 5,
        "camera zoom crossed its safety minimum")
end

local function TestGrabPanDirection()
    local yawZero = ForgeCameraController.GrabPanDelta(0, 10, 6, 1)
    Check(math.abs(yawZero.x - 10) < 0.000001 and math.abs(yawZero.z + 6) < 0.000001,
        "left-button grab pan moved opposite to the pointer at yaw zero")
    local yawNinety = ForgeCameraController.GrabPanDelta(90, 10, 6, 1)
    Check(math.abs(yawNinety.x + 6) < 0.000001 and math.abs(yawNinety.z + 10) < 0.000001,
        "left-button grab pan used the wrong rotated screen basis")
end

local function TestCorridorCenterOffset()
    Check(RouteEditing.CorridorCenterOffset(2) == 0.5,
        "two-cell auto corridor did not use the Three.js half-cell center offset")
    Check(RouteEditing.CorridorCenterOffset(1) == 0
        and RouteEditing.CorridorCenterOffset(3) == 0
        and RouteEditing.CorridorCenterOffset(4) == 0,
        "corridor center offset was applied outside the Three.js width-two rule")
    Check(math.abs(RouteEditing.CORRIDOR_VISUAL_SCALE - 0.36) < 0.000001,
        "editor corridor visual width scale changed unexpectedly")
    Check(math.abs(RouteEditing.CorridorScreenWidth(2, 10) - 7.2) < 0.000001
        and RouteEditing.CorridorScreenWidth(0.1, 1) == 1.25,
        "editor corridor did not preserve its half-radius screen width")
end

local function TestAdaptiveBends()
    local adapted = RouteEditing.AdaptBends({ { x = 4, y = 2 }, { x = 8, y = 6 } },
        { x = 0, y = 0 }, { x = 10, y = 10 }, { x = 2, y = 1 }, { x = 14, y = 13 })
    Check(#adapted == 2, "adaptive path lost authored bends")
    Check(SamePoint(adapted[1], 7, 4) and SamePoint(adapted[2], 11, 8),
        "adaptive path did not preserve bend proportions")
end

local function CheckOrthogonal(route, message)
    for index = 1, #route - 1 do
        local a, b = route[index], route[index + 1]
        Check(math.abs(a.x - b.x) < 0.000001 or math.abs(a.y - b.y) < 0.000001,
            (message or "route became diagonal") .. " at segment " .. index)
    end
end

local function TestOrthogonalRouteAdaptation()
    local route = RouteEditing.AdaptOrthogonalRoute({
        { x = 0, y = 0 }, { x = 5, y = 0 }, { x = 5, y = 5 }, { x = 10, y = 5 },
    }, { x = 2, y = 3 }, { x = 13, y = 8 })
    Check(SamePoint(route[1], 2, 3) and SamePoint(route[#route], 13, 8),
        "adapted route did not reach the moved room endpoints")
    CheckOrthogonal(route, "adapted route")
end

local function TestAutomaticRouteFollowsRepeatedRoomMoves()
    local Editor = {}
    PathWorkflow.Install(Editor, { CopyLink = EditorData.CopyLink })
    local link = { a = 1, b = 2, kind = "corridor", width = 2, bends = {}, autoRoute = {
        { x = 0, y = 0 }, { x = 5, y = 0 }, { x = 5, y = 5 }, { x = 10, y = 5 },
    } }
    local fake = setmetatable({
        links = { link },
        endpoints = { { x = 0, y = 0 }, { x = 10, y = 5 } },
        LinkRoute = function(_, current) return current.autoRoute end,
        LinkEndpoints = function(self) return self.endpoints[1], self.endpoints[2] end,
    }, { __index = Editor })

    local movedEndpoints = {
        { { x = 2, y = 3 }, { x = 12, y = 5 } },
        { { x = -1, y = 1 }, { x = 14, y = 9 } },
        { { x = 4, y = -2 }, { x = 11, y = 7 } },
    }
    for cycle, endpoints in ipairs(movedEndpoints) do
        local snapshot = fake:CaptureAdaptiveRoutes(1)
        Check(#snapshot == 1 and snapshot[1].automatic, "automatic route was not captured on cycle " .. cycle)
        fake.endpoints = endpoints
        fake:ApplyAdaptiveRoutes(snapshot)
        Check(SamePoint(link.autoRoute[1], endpoints[1].x, endpoints[1].y)
            and SamePoint(link.autoRoute[#link.autoRoute], endpoints[2].x, endpoints[2].y),
            "automatic route did not follow room endpoints on cycle " .. cycle)
        Check(#link.bends == 0 and not link.isManual,
            "room movement incorrectly converted the automatic route on cycle " .. cycle)
        CheckOrthogonal(link.autoRoute, "automatic route cycle " .. cycle)
    end
end

local function TestCorridorOverlayIncludesUnselectedRoutes()
    local editor = {
        floor = 0,
        selectedLink = nil,
        rooms = { { floor = 0 }, { floor = 0 }, { floor = 1 } },
        links = {
            { a = 1, b = 2, kind = "corridor" },
            { a = 1, b = 3, kind = "corridor" },
            { a = 1, b = 3, kind = "stairs" },
        },
        DisplayLinkRoute = function() return { { x = 0, y = 0 }, { x = 1, y = 0 } } end,
    }
    local entries = EditorGizmos.CorridorEntries(editor)
    Check(#entries == 1 and entries[1].index == 1,
        "unselected current-floor corridor was omitted from the rounded overlay")
    editor.selectedLink = 1
    Check(#EditorGizmos.CorridorEntries(editor) == 1,
        "corridor overlay coverage changed with selection state")
end

local function TestSegmentControlSnapping()
    local Editor = {}
    PathWorkflow.Install(Editor, { CopyLink = EditorData.CopyLink })
    local fake = setmetatable({
        ControlSnapTolerance = function() return 3.5 end,
    }, { __index = Editor })
    local link = { bends = { { x = 0, y = 2 }, { x = 4, y = 2 } }, autoRoute = {} }
    fake:MoveLinkSegment(link, {
        route = { { x = 0, y = 0 }, { x = 0, y = 2 }, { x = 4, y = 2 }, { x = 4, y = 4 } },
        segment = 2, startX = 2, startY = 2,
        snapTargets = { { x = 0, y = 4 }, { x = 4, y = 4 } },
    }, 2, 3)
    Check(#link.bends == 1 and SamePoint(link.bends[1], 0, 4),
        "horizontal segment snap kept a duplicate bend at the route endpoint")
end

local function TestSegmentEndpointShapePreservation()
    local Editor = {}
    PathWorkflow.Install(Editor, { CopyLink = EditorData.CopyLink })
    local fake = setmetatable({
        rooms = {
            { cx = 0, cy = 0, w = 10, h = 10, floor = 0 },
            { cx = 20, cy = 0, w = 10, h = 10, floor = 0 },
        },
        ControlSnapTolerance = function() return 3.5 end,
        DoorSpecPoint = function(_, room, spec)
            if spec.side == "east" then return { x = room.cx + room.w * 0.5, y = room.cy + spec.offset * room.h * 0.5, side = spec.side } end
            return { x = room.cx - room.w * 0.5, y = room.cy + spec.offset * room.h * 0.5, side = spec.side }
        end,
    }, { __index = Editor })
    local link = { a = 1, b = 2, bends = {}, autoRoute = {} }
    fake:MoveLinkSegment(link, {
        route = { { x = 5, y = 0, side = "east" }, { x = 15, y = 0, side = "west" } },
        segment = 1, startX = 10, startY = 0, snapTargets = {},
    }, 10, 3)
    Check(link.doorA.side == "east" and link.doorB.side == "west",
        "straight segment drag changed a door to another room wall")
    Check(math.abs(link.doorA.offset - 0.6) < 0.000001 and math.abs(link.doorB.offset - 0.6) < 0.000001,
        "straight segment endpoints did not remain aligned")
    Check(#link.bends == 0, "straight segment drag introduced a false bend")
end

local function TestMiddleSegmentAdaptsRoomPoints()
    local Editor = {}
    PathWorkflow.Install(Editor, { CopyLink = EditorData.CopyLink })
    local fake = setmetatable({
        rooms = {
            { cx = 0, cy = 0, w = 10, h = 10, floor = 0 },
            { cx = 20, cy = 0, w = 10, h = 10, floor = 0 },
        },
        ControlSnapTolerance = function() return 0.1 end,
        DoorSpecPoint = function(_, room, spec)
            local y = room.cy + spec.offset * room.h * 0.5
            if spec.side == "east" then return { x = room.cx + room.w * 0.5, y = y, side = spec.side } end
            return { x = room.cx - room.w * 0.5, y = y, side = spec.side }
        end,
    }, { __index = Editor })
    local link = { a = 1, b = 2, bends = { { x = 5, y = 2 }, { x = 15, y = 2 } }, autoRoute = {} }
    fake:MoveLinkSegment(link, {
        route = {
            { x = 5, y = 0, side = "east" }, { x = 5, y = 2 },
            { x = 15, y = 2 }, { x = 15, y = 0, side = "west" },
        },
        segment = 2, startX = 10, startY = 2, snapTargets = {},
    }, 10, 3)
    Check(link.doorA and link.doorB
        and math.abs(link.doorA.offset - 0.6) < 0.000001
        and math.abs(link.doorB.offset - 0.6) < 0.000001,
        "middle segment did not slide both room-bound door points")
    Check(#link.bends == 0,
        "middle segment retained redundant support bends inside the rooms")
end

local function TestSegmentSnapTargetsUseHandlesOnly()
    local Editor = {}
    PathWorkflow.Install(Editor, { CopyLink = EditorData.CopyLink })
    local link = { a = 1, b = 2, bends = {}, autoRoute = {} }
    local fake = setmetatable({
        floor = 0, rooms = { { floor = 0 }, { floor = 0 } }, links = { link },
        LinkRoute = function()
            return { { x = 0, y = 0 }, { x = 2, y = 0 }, { x = 2, y = 3 }, { x = 5, y = 3 } }
        end,
    }, { __index = Editor })
    local targets = fake:ControlSnapTargets()
    Check(#targets == 2 and SamePoint(targets[1], 0, 0) and SamePoint(targets[2], 5, 3),
        "automatic route cells leaked into segment snap targets")
end

local function TestEditableRouteSimplifiesAutoCells()
    local Editor = {}
    PathWorkflow.Install(Editor, { CopyLink = EditorData.CopyLink })
    local link = { bends = {}, autoRoute = {
        { x = 0, y = 0 }, { x = 1, y = 0 }, { x = 2, y = 0 },
        { x = 2, y = 1 }, { x = 2, y = 2 },
    } }
    local fake = setmetatable({
        LinkRoute = function(_, current)
            if current.bends and #current.bends > 0 then
                local route = { current.autoRoute[1] }
                for _, bend in ipairs(current.bends) do route[#route + 1] = bend end
                route[#route + 1] = current.autoRoute[#current.autoRoute]
                return route
            end
            return current.autoRoute
        end,
    }, { __index = Editor })
    local route = fake:EnsureEditableRoute(link)
    Check(#route == 3 and #link.bends == 1 and SamePoint(link.bends[1], 2, 0),
        "auto-route cell chain was copied into the authored path as false bends")
    Check(#link.autoRoute == 5, "editable-route initialization discarded the source route before dragging")
end

local function TestPathSelectionDoesNotMoveRoute()
    local interaction = EditorInteraction.new()
    local link = { bends = {}, autoRoute = {
        { x = 0, y = 0 }, { x = 4, y = 0 }, { x = 4, y = 5 },
    } }
    local fake = {
        links = { link }, editorInteraction = interaction,
        EnsureEditableRoute = function(self)
            self.editableCalls = (self.editableCalls or 0) + 1
            return { { x = 0, y = 0 }, { x = 4, y = 0 }, { x = 4, y = 5 } }
        end,
        ControlSnapTargets = function() return {} end,
        MoveLinkSegment = function(self) self.moveCalls = (self.moveCalls or 0) + 1 end,
        RefreshOverlay = function(self) self.refreshCount = (self.refreshCount or 0) + 1 end,
        Commit = function(self) self.commitCount = (self.commitCount or 0) + 1 end,
    }
    fake.drag = { kind = "linkSegment", link = 1, segment = 1,
        startX = 2.2, startY = 0.1, pending = true }
    interaction:Capture()
    Check(not EditorGesture.Apply(fake, 2.2, 0.1),
        "path selection was incorrectly treated as segment movement")
    Check(EditorGesture.Finish(fake) and #link.bends == 0 and #link.autoRoute == 3,
        "selecting a path changed its automatic route")
    Check(not fake.editableCalls and not fake.moveCalls and not fake.commitCount and fake.refreshCount == 1,
        "path selection initialized or committed an edit without pointer movement")

    fake.drag = { kind = "linkSegment", link = 1, segment = 1,
        startX = 2.2, startY = 0.1, pending = true }
    interaction:Capture()
    Check(EditorGesture.Apply(fake, 3.2, 0.1),
        "path drag did not start after crossing a grid boundary")
    Check(fake.editableCalls == 1 and fake.moveCalls == 1 and fake.drag.pending == false,
        "real path drag did not initialize the editable route exactly once")
end

local function TestScreenGizmoHitParity()
    local viewport = {
        ProjectGrid = function(_, _, point) return { x = point.x * 10, y = point.y * 10 } end,
    }
    local roomEditor = {
        rooms = { { cx = 10, cy = 8, w = 6, h = 4, floor = 0 } },
        links = {}, selected = 1, floor = 0,
    }
    local roomDescriptors = EditorGizmos.Build(roomEditor, viewport)
    Check(#roomDescriptors == 8, "screen gizmos did not create four visible corners and four edge hit regions")
    local corner = EditorGizmos.Hit(roomDescriptors, 70, 60)
    Check(corner and corner.kind == "roomResize" and corner.mode == "resize-nw" and corner.radius == 8,
        "screen-space room corner did not win over the overlapping edge hit regions")

    local linkEditor = {
        rooms = {}, selected = nil, floor = 0,
        links = { { bends = { { x = 5, y = 4 } } } }, selectedLink = 1,
        DisplayLinkRoute = function() return { { x = 1, y = 4 }, { x = 5, y = 4 }, { x = 9, y = 4 } } end,
    }
    local linkDescriptors = EditorGizmos.Build(linkEditor, viewport)
    local bend = EditorGizmos.Hit(linkDescriptors, 50, 40)
    Check(#linkDescriptors == 3 and bend and bend.kind == "bend" and bend.bendIndex == 1,
        "path door and bend gizmos were not generated from the displayed route")
end

local function TestRoomMoveAndFourCornerResizeParity()
    local movedX, movedY = RoomEditing.Move(
        { cx = 10, cy = 8 }, { x = 9.3, y = 8.4 }, { x = 11.7, y = 6.8 })
    Check(movedX == 12 and movedY == 6,
        "room move did not use Three's immutable pointer delta")

    local start = { cx = 10, cy = 8, w = 5, h = 7 }
    local initialCorners = {
        { mode = "resize-nw", x = 7.5, y = 4.5 },
        { mode = "resize-ne", x = 12.5, y = 4.5 },
        { mode = "resize-sw", x = 7.5, y = 11.5 },
        { mode = "resize-se", x = 12.5, y = 11.5 },
    }
    for _, corner in ipairs(initialCorners) do
        local room = RoomEditing.Resize(start, corner, corner.mode)
        Check(room.cx == 10 and room.cy == 8 and room.w == 5 and room.h == 7,
            corner.mode .. " changed an odd-sized room on the press frame")
    end

    local cases = {
        { mode = "resize-nw", x = 6.6, y = 3.2, expected = { 10, 7, 6, 8 } },
        { mode = "resize-ne", x = 14.2, y = 3.7, expected = { 11, 8, 7, 8 } },
        { mode = "resize-sw", x = 6.6, y = 13.8, expected = { 10, 9, 6, 9 } },
        { mode = "resize-se", x = 14.2, y = 13.8, expected = { 11, 9, 7, 9 } },
    }
    for _, case in ipairs(cases) do
        local room = RoomEditing.Resize(start, case, case.mode)
        local expected = case.expected
        Check(room.cx == expected[1] and room.cy == expected[2]
            and room.w == expected[3] and room.h == expected[4],
            case.mode .. " did not match Three's unsnapped-pointer resize result")
    end
end

local function TestStairScreenGizmos()
    local viewport = {
        ProjectGrid = function(_, _, point) return { x = point.x * 10, y = point.y * 10 } end,
    }
    local editor = {
        rooms = {}, selected = nil, floor = 0,
        links = { { kind = "stairs", connector = {
            lower = { x = 2, y = 2 }, turn = { x = 6, y = 2 }, upper = { x = 6, y = 6 },
            width = 2, direction = "east", directionVector = { x = 1, y = 0 },
        } } },
        selectedLink = 1,
    }
    local descriptors = EditorGizmos.Build(editor, viewport)
    local kinds = {}
    for _, descriptor in ipairs(descriptors) do kinds[descriptor.kind] = true end
    Check(#descriptors == 2 and kinds.stairRotate and kinds.stairWidth,
        "selected stair did not expose distinct rotation and width screen gizmos")
    Check(descriptors[1].radius == 12 and descriptors[2].radius == 12,
        "stair gizmo hit size was not kept in logical screen pixels")
    Check(EditorGizmos.HandleLayer(descriptors[1]) == "stair"
        and EditorGizmos.HandleLayer(descriptors[2]) == "stair",
        "stair handles escaped the dedicated top stair layer")

    local generated = {
        lower = { x = 32, y = 27 }, turn = { x = 36, y = 27 }, upper = { x = 36, y = 31 },
        lowerApproach = { x = 30, y = 27 }, upperApproach = { x = 36, y = 33 },
        lowerRoute = { { x = 28, y = 27 }, { x = 30, y = 27 } },
    }
    local localized = EditorData.CopyConnector(generated, { x = 12, y = 7 })
    Check(SamePoint(localized.lower, 20, 20) and SamePoint(localized.turn, 24, 20)
        and SamePoint(localized.upper, 24, 24) and SamePoint(localized.lowerRoute[1], 16, 20),
        "generated stair connector was not converted back into 2D editor coordinates")
    Check(SamePoint(generated.lower, 32, 27), "stair coordinate conversion mutated the generated dungeon")
end

local function TestRepeatedStairRotationDrag()
    local Editor = {}
    StairWorkflow.Install(Editor, { CopyRooms = EditorData.CopyRooms, CopyLink = EditorData.CopyLink })
    local placement = StairEditing.DirectPlacement({ x = 20, y = 20 }, "l-turn", 8)
    local spec = {
        id = "stair-repeat", pending = false, mode = "locked",
        anchor = placement.anchor, previewAnchor = placement.anchor,
        direction = placement.direction, previewDirection = placement.direction,
        length = 8, previewLength = 8, style = "l-turn", previewStyle = "l-turn",
        width = 2, previewWidth = 2, landingDepth = 2, previewLandingDepth = 2,
    }
    local fake = setmetatable({
        rooms = {
            { cx = 20, cy = 20, w = 14, h = 14, floor = 0 },
            { cx = 20, cy = 20, w = 14, h = 14, floor = 1 },
        },
        links = { { a = 1, b = 2, kind = "stairs", stairSpec = spec,
            connector = StairEditing.Visual(spec, nil, placement) } },
    }, { __index = Editor })

    local first = fake:CaptureStairDrag(1)
    local south = StairEditing.RotationFromPointer(first.spec, first.connector, { x = 20, y = 40 })
    Check(fake:UpdateStairDrag(first, south) and fake.links[1].connector.direction == "south",
        "first stair rotation drag did not apply")

    local second = fake:CaptureStairDrag(1)
    local west = StairEditing.RotationFromPointer(second.spec, second.connector, { x = 0, y = 20 })
    Check(fake:UpdateStairDrag(second, west) and fake.links[1].connector.direction == "west",
        "second stair rotation reused stale drag state")

    local interaction = EditorInteraction.new()
    local firstSerial = interaction:Capture()
    interaction:Release()
    local secondSerial = interaction:Capture()
    Check(interaction:IsCaptured() and secondSerial == firstSerial + 1,
        "project pointer capture could not start a second gesture")
    interaction:Release()
end

local function TestRepeatedGestureLifecycle()
    local interaction = EditorInteraction.new()
    for cycle = 1, 40 do
        local pressed, released = interaction:Sample(true, false, false)
        Check(pressed and not released, "held-button fallback did not recover press " .. cycle)
        local serial = interaction:Capture()
        local repeatedPress, repeatedRelease = interaction:Sample(true, false, false)
        Check(not repeatedPress and not repeatedRelease and interaction:IsCaptured(),
            "gesture emitted duplicate edge while held " .. cycle)
        local _, recoveredRelease = interaction:Sample(false, false, false)
        Check(recoveredRelease, "button-up fallback did not recover release " .. cycle)
        interaction:Release()
        Check(not interaction:IsCaptured() and serial == cycle,
            "gesture capture did not reset after cycle " .. cycle)
    end
end

local function TestRepeatedRoomPathAndStairEdits()
    local roomEditor = {
        rooms = { { cx = 10, cy = 10, w = 8, h = 8, floor = 0 } }, links = {},
        editorInteraction = EditorInteraction.new(), callbacks = {},
        UpdateRoomStairEdit = function() end, ApplyAdaptiveRoutes = function() end,
        UpdateRoomVisual = function() end, RefreshOverlay = function() end,
        Commit = function(self) self.commits = (self.commits or 0) + 1 end,
    }
    for cycle = 1, 20 do
        local room = roomEditor.rooms[1]
        local startX, delta = room.cx, cycle % 2 == 0 and -1 or 1
        roomEditor.drag = { kind = "roomMove", index = 1, startX = room.cx, startY = room.cy,
            start = { cx = room.cx, cy = room.cy }, adaptive = {} }
        roomEditor.editorInteraction:Capture()
        Check(EditorGesture.Apply(roomEditor, room.cx + delta, room.cy) and room.cx == startX + delta,
            "room edit did not move on cycle " .. cycle)
        Check(EditorGesture.Finish(roomEditor) and not roomEditor.drag
            and not roomEditor.editorInteraction:IsCaptured(), "room edit did not release on cycle " .. cycle)
    end
    Check(roomEditor.commits == 20, "room edits did not commit every cycle")

    local PathEditor = {}
    PathWorkflow.Install(PathEditor, { CopyLink = EditorData.CopyLink })
    local pathEditor = setmetatable({
        floor = 0,
        rooms = {
            { cx = 0, cy = 0, w = 10, h = 10, floor = 0 },
            { cx = 20, cy = 0, w = 10, h = 10, floor = 0 },
        },
        links = { { a = 1, b = 2, width = 2, bends = { { x = 5, y = 3 }, { x = 15, y = 3 } }, autoRoute = {} } },
        editorInteraction = EditorInteraction.new(), callbacks = {},
        LinkRoute = function(self, link)
            local route = { { x = 5, y = 0, side = "east" } }
            for _, bend in ipairs(link.bends or {}) do route[#route + 1] = { x = bend.x, y = bend.y } end
            route[#route + 1] = { x = 15, y = 0, side = "west" }
            return route
        end,
        ControlSnapTolerance = function() return 0.1 end,
        RefreshOverlay = function() end,
        Commit = function(self) self.commits = (self.commits or 0) + 1 end,
    }, { __index = PathEditor })
    for cycle = 1, 20 do
        local link = pathEditor.links[1]
        local route = pathEditor:EnsureEditableRoute(link)
        local startY, delta = route[2].y, cycle % 2 == 0 and -1 or 1
        pathEditor.drag = { kind = "linkSegment", link = 1, segment = 2,
            startX = 10, startY = startY, route = route, snapTargets = {} }
        pathEditor.editorInteraction:Capture()
        Check(EditorGesture.Apply(pathEditor, 10, startY + delta),
            "path edit did not apply on cycle " .. cycle)
        Check(link.bends[1] and link.bends[1].y == startY + delta,
            "path shape did not change on cycle " .. cycle)
        Check(EditorGesture.Finish(pathEditor) and not pathEditor.drag
            and not pathEditor.editorInteraction:IsCaptured(), "path edit did not release on cycle " .. cycle)
    end
    Check(pathEditor.commits == 20, "path edits did not commit every cycle")

    local StairEditor = {}
    StairWorkflow.Install(StairEditor, { CopyRooms = EditorData.CopyRooms, CopyLink = EditorData.CopyLink })
    local placement = StairEditing.DirectPlacement({ x = 20, y = 20 }, "l-turn", 8)
    local spec = {
        id = "stair-repeat-all", pending = false, mode = "locked",
        anchor = placement.anchor, previewAnchor = placement.anchor,
        direction = placement.direction, previewDirection = placement.direction,
        length = 8, previewLength = 8, style = "l-turn", previewStyle = "l-turn",
        width = 2, previewWidth = 2, landingDepth = 2, previewLandingDepth = 2,
    }
    local stairEditor = setmetatable({
        rooms = {
            { cx = 20, cy = 20, w = 16, h = 16, floor = 0 },
            { cx = 20, cy = 20, w = 16, h = 16, floor = 1 },
        },
        links = { { a = 1, b = 2, kind = "stairs", stairSpec = spec,
            connector = StairEditing.Visual(spec, nil, placement) } },
        editorInteraction = EditorInteraction.new(), callbacks = {}, floor = 0,
        RefreshOverlay = function(self) self.refreshCount = (self.refreshCount or 0) + 1 end,
        NotifySelection = function() end,
        MarkDisconnectedRoomsSecret = function() end,
        Commit = function(self) self.commits = (self.commits or 0) + 1 end,
    }, { __index = StairEditor })
    for cycle = 1, 20 do
        local stair = stairEditor:CaptureStairDrag(1)
        local anchor = stair.spec.previewAnchor or stair.spec.anchor
        local startX, delta = anchor.x, cycle % 2 == 0 and -1 or 1
        stairEditor.drag = { kind = "stairMove", link = 1, startX = 0, startY = 0,
            anchor = { x = anchor.x, y = anchor.y }, stair = stair, lastDX = 0, lastDY = 0 }
        stairEditor.editorInteraction:Capture()
        Check(EditorGesture.Apply(stairEditor, delta, 0),
            "stair edit did not apply on cycle " .. cycle)
        local moved = stairEditor.links[1].stairSpec.previewAnchor or stairEditor.links[1].stairSpec.anchor
        Check(moved.x == startX + delta, "stair anchor did not move on cycle " .. cycle)
        Check(EditorGesture.Finish(stairEditor) and not stairEditor.drag
            and not stairEditor.editorInteraction:IsCaptured(), "stair edit did not release on cycle " .. cycle)
    end
    Check(stairEditor.commits == 20, "stair edits did not commit every cycle")
end

local function TestEditorCopiesAreIsolated()
    local source = {
        a = 1, b = 2, width = 3, bends = { { x = 4, y = 5 } },
        stairSpec = { id = "stair-1", pending = true, previewAnchor = { x = 7, y = 8 }, previewDirection = "east" },
    }
    local copy = EditorData.CopyLink(source)
    copy.bends[1].x = 99
    copy.stairSpec.previewAnchor.y = 77
    Check(source.bends[1].x == 4 and source.stairSpec.previewAnchor.y == 8,
        "editor link copy retained mutable nested references")
end

local function TestGeneratedStairBecomesEditable()
    local link = {
        kind = "stairs", width = 2,
        connector = { id = 3, lower = { x = 12, y = 9 }, direction = "north",
            width = 3, length = 11, landingDepth = 2, candidateIndex = 1, candidateCount = 4 },
    }
    EditorData.EnsureStairSpec(link, { id = 7, connectorId = 3 })
    Check(link.stairSpec and link.stairSpec.id == "stair-edge-7",
        "generated stair was not upgraded to an editable stair contract")
    Check(SamePoint(link.stairSpec.anchor, 12, 9) and link.stairSpec.direction == "north"
        and link.stairSpec.width == 3 and link.stairSpec.candidateCount == 4,
        "generated stair contract did not preserve connector geometry")
end

local function TestDuplicateConnectionDetection()
    local links = { { a = 1, b = 2 }, { a = 2, b = 3 }, { a = 4, b = 1 } }
    Check(EditorData.FindLink(links, 2, 1) == 1, "reverse-order duplicate connection was not found")
    Check(EditorData.FindLink(links, 1, 4, 3) == nil, "excluded connection matched itself")
    Check(EditorData.FindLink(links, 1, 3) == nil, "unconnected room pair reported a duplicate")
end

local function TestStairPairingAndRotation()
    local source = { id = 1, cx = 10, cy = 10, w = 10, h = 8, floor = 0 }
    local target = { id = 2, cx = 11, cy = 10, w = 8, h = 8, floor = 1 }
    Check(StairEditing.PairError(source, target) == nil, "valid adjacent-floor stair pair was rejected")
    Check(#StairEditing.MatchingRooms(source, { source, target }, 1) == 1,
        "overlapping room discovery missed a valid target")
    local rotated = StairEditing.Rotate90({
        anchor = { x = 4, y = 5 }, direction = "east", length = 10,
    })
    Check(rotated and rotated.direction == "south" and SamePoint(rotated.anchor, 9, 0),
        "stair rotation did not preserve its center")
end

local function TestStairStyleWidthAndPointerControls()
    local placement = StairEditing.DirectPlacement({ x = 20, y = 20 }, "l-turn", 8)
    local spec = { style = "l-turn", width = 2, length = 8, anchor = placement.anchor, direction = placement.direction }
    local visual = StairEditing.Visual(spec, nil, placement)
    Check(visual.turn and SamePoint(visual.lower, 18, 18) and SamePoint(visual.turn, 22, 18)
        and SamePoint(visual.upper, 22, 22), "L stair did not build both flights around the clicked center")
    local segments, platform = StairEditing.VisualSegments(visual)
    Check(#segments == 2 and platform
        and math.abs(segments[1].start.y - 18.5) < 0.000001
        and math.abs(platform.center.x - 23) < 0.000001
        and math.abs(segments[2].finish.y - 23.5) < 0.000001,
        "L stair visual segments still use the old turn anchor")

    local straight = StairEditing.ChangeStyle(spec, visual, "straight")
    local straightVisual = StairEditing.Visual(spec, visual, straight)
    Check(straight.style == "straight" and SamePoint(straightVisual.lower, 16, 20)
        and SamePoint(straightVisual.upper, 24, 20), "style switch did not preserve the stair bounding center")

    local rotated = StairEditing.RotationFromPointer(spec, visual, { x = 20, y = 30 })
    Check(rotated and rotated.direction == "south", "rotation handle did not follow the pointer cardinal direction")
    local stable = StairEditing.RotationFromPointer(spec, visual, { x = 29, y = 30 }, "east")
    Check(stable and stable.direction == "east", "rotation handle jittered across a diagonal boundary")
    Check(StairEditing.SnapWidth(2.13) == 2.25 and StairEditing.SnapWidth(9) == 5,
        "stair width did not use the Three.js 0.25 step and 1..5 limits")
    Check(StairEditing.WidthFromPointer(spec, visual, { x = 20, y = 21.5 }) == 4,
        "width handle did not measure from the centered stair flight")
    Check(StairEditing.RotationHandle(visual) and StairEditing.WidthHandle(visual),
        "stair editor handles were not generated")
end

local function TestDirectStairWorkflow()
    local Editor = {}
    StairWorkflow.Install(Editor, { CopyRooms = EditorData.CopyRooms, CopyLink = EditorData.CopyLink })
    local fake = setmetatable({
        rooms = {
            { id = 1, cx = 10, cy = 10, w = 14, h = 14, floor = 0 },
            { id = 2, cx = 10, cy = 10, w = 14, h = 14, floor = 1 },
        },
        links = {}, floor = 0, floorCount = 2, nextStairId = 1,
        stairPlacementStyle = "l-turn", callbacks = {},
        RefreshOverlay = function(self) self.refreshCount = (self.refreshCount or 0) + 1 end,
        NotifySelection = function() end,
        MarkDisconnectedRoomsSecret = function() end,
        Commit = function(self) self.commitCount = (self.commitCount or 0) + 1 end,
        GetRooms = function(self) return EditorData.CopyRooms(self.rooms) end,
        GetLinks = function(self)
            local result = {}
            for index, link in ipairs(self.links) do result[index] = EditorData.CopyLink(link) end
            return result
        end,
    }, { __index = Editor })

    Check(fake:BeginAddStair() and fake.stairPlacing, "top-level stair tool did not enter direct placement mode")
    Check(fake:PlaceStairAt(1, 10, 10), "direct stair click did not create a connector")
    local link = fake.links[1]
    Check(link and link.stairSpec.pending and link.stairSpec.previewStyle == "l-turn"
        and link.connector and link.connector.turn, "direct placement did not create a pending L stair preview")
    Check(fake:SetSelectedStairStyle("straight") and link.stairSpec.previewStyle == "straight"
        and not link.connector.turn, "workflow style toggle did not replace the stair preview")
    Check(fake:ConfirmSelectedStair() and not link.stairSpec.pending,
        "pending direct stair could not be confirmed")
    local direction = link.stairSpec.direction
    Check(fake:RotateSelectedStair() and link.stairSpec.direction ~= direction,
        "confirmed stair could not be rotated")
    Check(fake:ToggleSelectedStairLock(), "confirmed stair lock could not be toggled")
    Check(fake.refreshCount == 6,
        "stair action lifecycle did not refresh its live geometry")
end

local function TestCriticalStairDetection()
    local rooms = { { id = 1 }, { id = 2 }, { id = 3 } }
    local stair = { a = 1, b = 2, kind = "stairs" }
    local links = { stair, { a = 2, b = 3, kind = "corridor" } }
    Check(StairEditing.RemovalDisconnectsRooms(rooms, links, stair),
        "critical stair deletion was not detected")
    links[#links + 1] = { a = 1, b = 3, kind = "corridor" }
    Check(not StairEditing.RemovalDisconnectsRooms(rooms, links, stair),
        "redundant stair was incorrectly classified as critical")
end

local function TestPairedStairRoomRemoval()
    local rooms = {
        { id = 1 },
        { id = 2, stairRoom = true, stairRoomPairId = "pair-1" },
        { id = 3, stairRoom = true, stairRoomPairId = "pair-1" },
        { id = 4 },
    }
    local stair = { a = 2, b = 3, kind = "stairs" }
    local links = { { a = 1, b = 2 }, stair, { a = 3, b = 4 }, { a = 1, b = 4 } }
    Check(StairEditing.RemovePairedStairRooms(rooms, links, stair), "paired stair rooms were not removed")
    Check(#rooms == 2 and #links == 1 and links[1].a == 1 and links[1].b == 2,
        "paired stair removal did not remove incident paths and reindex survivors")
end

local function Test2D3DSessionSynchronization()
    local source = {
        rooms = {
            { id = 1, cx = 8, cy = 7, w = 10, h = 8, floor = 0, roomGroupId = "crypt" },
            { id = 2, cx = 8, cy = 7, w = 10, h = 8, floor = 1, stairRoom = true,
                stairRoomPairId = "pair-sync" },
        },
        links = {
            { a = 1, b = 2, kind = "stairs", width = 3,
                stairSpec = { id = "stair-sync", mode = "locked", style = "straight", width = 3,
                    anchor = { x = 8, y = 7 }, direction = 1 },
                connector = { id = "connector-sync", lower = { x = 8, y = 7 },
                    upper = { x = 8, y = 15 }, width = 3, style = "straight" } },
        },
        floor = 1, floorCount = 3, floorHeight = 3,
        dungeonWidth = 80, dungeonHeight = 64,
        generatedOffset = { x = 13, y = 9 },
        selected = 2, selectedLink = 1, mode = "connect", linkStart = 2, nextStairId = 9,
        stairPlacing = true, stairPlacementStyle = "straight",
        stairSnapshot = { floor = 1, rooms = { { id = 1, cx = 8, cy = 7, w = 10, h = 8, floor = 0 } } },
    }
    local target = { rooms = {}, links = {}, floorHeight = 99,
        RefreshOverlay = function(self) self.refreshed = true end,
        NotifySelection = function(self) self.notified = true end }
    Check(EditorSession.Apply(target, EditorSession.Capture(source)), "editor view session synchronization failed")
    Check(target.floor == 1 and target.floorCount == 3 and target.selected == 2 and target.selectedLink == 1,
        "editor view session lost floor or selection state")
    Check(SamePoint(target.generatedOffset, 13, 9),
        "editor view session lost the generated coordinate offset")
    Check(target.rooms[1].roomGroupId == "crypt" and target.rooms[2].stairRoomPairId == "pair-sync",
        "editor view session lost room authoring metadata")
    Check(target.links[1].stairSpec.style == "straight" and target.links[1].connector.width == 3,
        "editor view session lost stair authoring or preview data")
    Check(target.mode == "connect" and target.linkStart == 2,
        "editor view session lost the active connection tool")
    Check(target.stairPlacing and target.stairPlacementStyle == "straight" and target.stairSnapshot,
        "editor view session lost stair placement or cancellation state")
    Check(target.floorHeight == MultiFloor.FLOOR_HEIGHT and target.floorHeight == 5.0,
        "editor view synchronization imported a non-UrhoX floor height")
    target.links[1].connector.lower.x = 99
    Check(source.links[1].connector.lower.x == 8, "editor view session shared mutable connector state")
    target.stairSnapshot.rooms[1].cx = 99
    Check(source.stairSnapshot.rooms[1].cx == 8, "editor view session shared a mutable stair cancellation snapshot")
    target.generatedOffset.x = 99
    Check(source.generatedOffset.x == 13, "editor view session shared a mutable generated coordinate offset")
    Check(target.refreshed and target.notified, "editor view session did not refresh the destination view")
end

local function TestGeneratedCoordinateMapping()
    local editor = setmetatable({
        dungeonWidth = 80, dungeonHeight = 64, floor = 1, floorHeight = MultiFloor.FLOOR_HEIGHT,
        generatedOffset = { x = 13, y = 9 },
    }, { __index = SceneLayoutEditor })
    local world = editor:GridToWorld({ x = 8, y = 7 }, 0.34)
    Check(math.abs(world.x - (21 - 40 + 0.5)) < 0.000001
        and math.abs(world.z - (16 - 32 + 0.5)) < 0.000001,
        "3D editor did not map local stair coordinates into generated dungeon coordinates")
    local gridX, gridY = editor:WorldToGrid(world)
    Check(math.abs(gridX - 8) < 0.000001 and math.abs(gridY - 7) < 0.000001,
        "3D editor generated coordinate mapping was not reversible")
end

local function TestCanvasViewportPanZoom()
    local viewport = CanvasViewport.new()
    viewport:SetRect(100, 80, 600, 420)
    viewport:Fit({ { cx = 20, cy = 15, w = 10, h = 8, floor = 0 } }, 0)
    local anchorX, anchorY = 350, 260
    local beforeX, beforeY = viewport:ScreenToGrid(anchorX, anchorY)
    Check(viewport:ZoomAt(anchorX, anchorY, 1), "2D viewport wheel zoom was ignored")
    local afterX, afterY = viewport:ScreenToGrid(anchorX, anchorY)
    Check(math.abs(beforeX - afterX) < 0.000001 and math.abs(beforeY - afterY) < 0.000001,
        "2D viewport zoom did not stay anchored at the pointer")
    local originX, originY = viewport.originX, viewport.originY
    viewport:Pan(18, -11)
    Check(viewport.originX == originX + 18 and viewport.originY == originY - 11,
        "2D viewport pan did not preserve the fitted transform")
end

function EditorTests.Run()
    local tests = {
        { "route simplification", TestRouteSimplification },
        { "path straightening", TestPathStraightening },
        { "control snapping", TestControlSnapping },
        { "anchored blank camera pan", TestAnchoredBlankPan },
        { "unbounded camera zoom out", TestUnboundedCameraZoomOut },
        { "left-button grab pan direction", TestGrabPanDirection },
        { "corridor center offset", TestCorridorCenterOffset },
        { "adaptive bends", TestAdaptiveBends },
        { "orthogonal route adaptation", TestOrthogonalRouteAdaptation },
        { "automatic route room moves", TestAutomaticRouteFollowsRepeatedRoomMoves },
        { "unselected corridor overlay", TestCorridorOverlayIncludesUnselectedRoutes },
        { "segment control snapping", TestSegmentControlSnapping },
        { "segment endpoint shape", TestSegmentEndpointShapePreservation },
        { "middle segment room points", TestMiddleSegmentAdaptsRoomPoints },
        { "segment handle targets", TestSegmentSnapTargetsUseHandlesOnly },
        { "editable route simplification", TestEditableRouteSimplifiesAutoCells },
        { "path selection stability", TestPathSelectionDoesNotMoveRoute },
        { "screen gizmo hit parity", TestScreenGizmoHitParity },
        { "room move/four-corner resize", TestRoomMoveAndFourCornerResizeParity },
        { "stair screen gizmos", TestStairScreenGizmos },
        { "repeated stair rotation drag", TestRepeatedStairRotationDrag },
        { "repeated gesture lifecycle", TestRepeatedGestureLifecycle },
        { "repeated room path stair edits", TestRepeatedRoomPathAndStairEdits },
        { "isolated editor copies", TestEditorCopiesAreIsolated },
        { "generated stair editability", TestGeneratedStairBecomesEditable },
        { "duplicate connection detection", TestDuplicateConnectionDetection },
        { "stair pairing and rotation", TestStairPairingAndRotation },
        { "stair style/width controls", TestStairStyleWidthAndPointerControls },
        { "direct stair workflow", TestDirectStairWorkflow },
        { "critical stair detection", TestCriticalStairDetection },
        { "paired stair room removal", TestPairedStairRoomRemoval },
        { "2D/3D session synchronization", Test2D3DSessionSynchronization },
        { "generated coordinate mapping", TestGeneratedCoordinateMapping },
        { "2D canvas pan and zoom", TestCanvasViewportPanZoom },
    }
    for _, test in ipairs(tests) do
        test[2]()
        print(string.format("[test] PASS %-28s", test[1]))
    end
    print(string.format("[test] PASS all %d editor suites", #tests))
    return true
end

function EditorTests.RunStairs()
    local tests = {
        { "stair screen gizmos", TestStairScreenGizmos },
        { "repeated stair rotation drag", TestRepeatedStairRotationDrag },
        { "repeated room path stair edits", TestRepeatedRoomPathAndStairEdits },
        { "generated stair editability", TestGeneratedStairBecomesEditable },
        { "stair pairing and rotation", TestStairPairingAndRotation },
        { "stair style/width controls", TestStairStyleWidthAndPointerControls },
        { "direct stair workflow", TestDirectStairWorkflow },
        { "critical stair detection", TestCriticalStairDetection },
        { "paired stair room removal", TestPairedStairRoomRemoval },
    }
    for _, test in ipairs(tests) do
        test[2]()
        print(string.format("[stair-test] PASS %-28s", test[1]))
    end
    print(string.format("[stair-test] PASS all %d stair suites", #tests))
    return true
end

return EditorTests
