local RouteEditing = require("UI.Editor.RouteEditing")

local PathWorkflow = {}

function PathWorkflow.Install(Editor, helpers)
    local CopyPoint = RouteEditing.CopyPoint
    local Snap = RouteEditing.Snap

    function Editor:EnsureEditableRoute(link)
        link.bends = link.bends or {}
        local route = RouteEditing.Simplify(self:LinkRoute(link))
        if #link.bends == 0 then
            for index = 2, #route - 1 do link.bends[#link.bends + 1] = CopyPoint(route[index]) end
        end
        return RouteEditing.Simplify(self:LinkRoute(link))
    end

    function Editor:NormalizeLink(link)
        if not link or link.kind == "stairs" then return end
        local route = RouteEditing.Simplify(self:LinkRoute(link))
        link.bends = {}
        for index = 2, #route - 1 do
            link.bends[#link.bends + 1] = { x = Snap(route[index].x), y = Snap(route[index].y) }
        end
    end

    function Editor:StraightenLink(link)
        if not link or link.kind == "stairs" then return false end
        local startPoint, endPoint = self:LinkEndpoints(link)
        if not startPoint or not endPoint then return false end
        local sourceRoute = RouteEditing.Simplify(self:LinkRoute(link))
        local route = RouteEditing.AdaptOrthogonalRoute(sourceRoute, startPoint, endPoint)
        if #route < 2 then return false end
        link.bends = {}
        for index = 2, #route - 1 do
            link.bends[#link.bends + 1] = CopyPoint(route[index])
        end
        link.autoRoute, link.isManual = {}, true
        if self.RefreshOverlay then self:RefreshOverlay() end
        if self.Commit then self:Commit() end
        return true
    end

    local function IsExcluded(point, excludedPoints)
        for _, excluded in ipairs(excludedPoints or {}) do
            if math.abs(point.x - excluded.x) < 0.000001 and math.abs(point.y - excluded.y) < 0.000001 then return true end
        end
        return false
    end

    local function PointInsideRoom(room, point)
        if not room or not point then return false end
        local epsilon = 0.0001
        return point.x >= room.cx - room.w * 0.5 - epsilon
            and point.x <= room.cx + room.w * 0.5 + epsilon
            and point.y >= room.cy - room.h * 0.5 - epsilon
            and point.y <= room.cy + room.h * 0.5 + epsilon
    end

    function Editor:ControlSnapTargets(excludedPoints)
        local targets = {}
        for _, link in ipairs(self.links) do
            if link.kind ~= "stairs" then
                local roomA, roomB = self.rooms[link.a], self.rooms[link.b]
                if roomA and roomB and roomA.floor == self.floor and roomB.floor == self.floor then
                    local route = self:LinkRoute(link)
                    local handles = { route[1], route[#route] }
                    for _, point in ipairs(link.bends or {}) do handles[#handles + 1] = point end
                    for _, point in ipairs(handles) do
                        if point and not IsExcluded(point, excludedPoints) then
                            targets[#targets + 1] = { x = point.x, y = point.y }
                        end
                    end
                end
            end
        end
        return targets
    end

    function Editor:ControlSnapTolerance()
        if self.editorViewport and self.editorViewport.PixelsPerGrid then
            local pixelsPerGrid = self.editorViewport:PixelsPerGrid(self, { x = 0, y = 0 })
            if pixelsPerGrid and pixelsPerGrid > 0 then return math.max(0.35, 10 / pixelsPerGrid) end
        end
        local dpr = math.max(1, graphics:GetDPR())
        local logicalHeight = math.max(1, graphics:GetHeight() / dpr)
        return math.max(3.5, (self.camera.orthoSize or 30) * 28 / logicalHeight)
    end

    function Editor:SnapControlPoint(point, _excludedLink, excludedPoints)
        return RouteEditing.SnapControlPoint(point, self:ControlSnapTargets(excludedPoints),
            self:ControlSnapTolerance(), excludedPoints)
    end

    function Editor:CaptureAdaptiveRoutes(roomIndex)
        local snapshots = {}
        for linkIndex, link in ipairs(self.links) do
            local connected = roomIndex == nil or link.a == roomIndex or link.b == roomIndex
            local hasBends = link.bends and #link.bends > 0
            local hasAutomaticRoute = not hasBends and not link.doorA and not link.doorB
                and link.autoRoute and #link.autoRoute > 1
            if connected and link.kind ~= "stairs" and (hasBends or hasAutomaticRoute) then
                local route = RouteEditing.Simplify(self:LinkRoute(link))
                snapshots[#snapshots + 1] = {
                    link = linkIndex,
                    route = route,
                    automatic = hasAutomaticRoute == true,
                }
            end
        end
        return snapshots
    end

    function Editor:ApplyAdaptiveRoutes(snapshots)
        for _, snapshot in ipairs(snapshots or {}) do
            local link = self.links[snapshot.link]
            if link then
                local startPoint, endPoint = self:LinkEndpoints(link)
                if startPoint and endPoint then
                    local route = RouteEditing.AdaptOrthogonalRoute(snapshot.route, startPoint, endPoint)
                    if snapshot.automatic then
                        -- Keep generated corridors automatic. The live route follows the
                        -- moved room immediately; final generation may still reroute it.
                        link.bends = {}
                        link.autoRoute = {}
                        for index, point in ipairs(route) do link.autoRoute[index] = CopyPoint(point) end
                    else
                        link.bends = {}
                        for index = 2, #route - 1 do link.bends[#link.bends + 1] = CopyPoint(route[index]) end
                        link.autoRoute = {}
                    end
                end
            end
        end
    end

    function Editor:RouteDoorSpecOnSide(room, point, side)
        if not room or not point then return nil end
        side = side or self:PointToDoorSpec(room, point).side
        local offset = 0
        if side == "north" or side == "south" or side == "n" or side == "s" then
            offset = (point.x - room.cx) / math.max(1, room.w * 0.5)
        else offset = (point.y - room.cy) / math.max(1, room.h * 0.5) end
        return { side = side, offset = math.max(-0.82, math.min(0.82, offset)) }
    end

    function Editor:SetRouteDoorOnSide(link, which, point, side)
        local room = self.rooms[which == "a" and link.a or link.b]
        local spec = self:RouteDoorSpecOnSide(room, point, side)
        if not spec then return nil end
        if which == "a" then link.doorA = spec else link.doorB = spec end
        return self:DoorSpecPoint(room, spec)
    end

    function Editor:RouteDoorAxisRange(room, side)
        if not room then return nil end
        if side == "north" or side == "south" or side == "n" or side == "s" then
            return { axis = "x", minimum = room.cx - room.w * 0.41, maximum = room.cx + room.w * 0.41 }
        end
        if side == "west" or side == "east" or side == "w" or side == "e" then
            return { axis = "y", minimum = room.cy - room.h * 0.41, maximum = room.cy + room.h * 0.41 }
        end
        return nil
    end

    function Editor:SnapRouteSegmentDelta(drag, deltaX, deltaY, lock)
        local best, tolerance = nil, self:ControlSnapTolerance()
        local a, b = drag.route[drag.segment], drag.route[drag.segment + 1]
        for _, moved in ipairs({ a, b }) do
            local current = { x = moved.x + deltaX, y = moved.y + deltaY }
            for _, target in ipairs(drag.snapTargets or {}) do
                local snapX, snapY = target.x - current.x, target.y - current.y
                if lock == "x" then snapY = 0 elseif lock == "y" then snapX = 0 end
                local distance = math.sqrt(snapX * snapX + snapY * snapY)
                if distance <= tolerance and (not best or distance < best.distance) then
                    best = { x = deltaX + snapX, y = deltaY + snapY, distance = distance }
                end
            end
        end
        return Snap(best and best.x or deltaX), Snap(best and best.y or deltaY)
    end

    function Editor:MoveLinkSegment(link, drag, gridX, gridY)
        local points = {}
        for _, point in ipairs(drag.route) do points[#points + 1] = CopyPoint(point) end
        local deltaX, deltaY = gridX - drag.startX, gridY - drag.startY
        local a, b = points[drag.segment], points[drag.segment + 1]
        local lock = nil
        if math.abs(b.x - a.x) >= math.abs(b.y - a.y) * 1.4 then deltaX, lock = 0, "y"
        elseif math.abs(b.y - a.y) >= math.abs(b.x - a.x) * 1.4 then deltaY, lock = 0, "x" end
        local snappedX, snappedY = self:SnapRouteSegmentDelta(drag, deltaX, deltaY, lock)
        deltaX, deltaY = snappedX or 0, snappedY or 0
        a.x, a.y, b.x, b.y = a.x + deltaX, a.y + deltaY, b.x + deltaX, b.y + deltaY

        local last = #points
        local fallbackStart, fallbackEnd = nil, nil
        if self.LinkEndpoints then fallbackStart, fallbackEnd = self:LinkEndpoints(link) end
        local sideA = drag.route[1].side or (fallbackStart and fallbackStart.side)
        local sideB = drag.route[last].side or (fallbackEnd and fallbackEnd.side)
        if last == 2 then
            local rangeA = self:RouteDoorAxisRange(self.rooms[link.a], sideA)
            local rangeB = self:RouteDoorAxisRange(self.rooms[link.b], sideB)
            if rangeA and rangeB and rangeA.axis == rangeB.axis then
                local low, high = math.max(rangeA.minimum, rangeB.minimum), math.min(rangeA.maximum, rangeB.maximum)
                if low <= high then
                    local target = math.max(low, math.min(high, points[1][rangeA.axis]))
                    points[1][rangeA.axis], points[2][rangeA.axis] = target, target
                end
            end
            points[1] = self:SetRouteDoorOnSide(link, "a", points[1], sideA) or points[1]
            points[2] = self:SetRouteDoorOnSide(link, "b", points[2], sideB) or points[2]
        else
            if drag.segment == 1 then
                local door = self:SetRouteDoorOnSide(link, "a", points[1], sideA)
                if door then
                    if drag.route[1].x == drag.route[2].x then points[2].x = door.x
                    elseif drag.route[1].y == drag.route[2].y then points[2].y = door.y end
                    points[1] = door
                end
            elseif self.DoorSpecPoint and PointInsideRoom(self.rooms and self.rooms[link.a], points[2]) then
                -- The moved segment is not the endpoint segment, but its
                -- neighbour still lies on/in room A. Slide the door to that
                -- support point and collapse the redundant in-room segment.
                local door = self:SetRouteDoorOnSide(link, "a", points[2], sideA)
                if door then points[1], points[2] = door, CopyPoint(door) end
            end
            if drag.segment == last - 1 then
                local door = self:SetRouteDoorOnSide(link, "b", points[last], sideB)
                local previous, previousStart = points[last - 1], drag.route[last - 1]
                if door and previous and previousStart then
                    if previousStart.x == drag.route[last].x then previous.x = door.x
                    elseif previousStart.y == drag.route[last].y then previous.y = door.y end
                    points[last] = door
                end
            elseif self.DoorSpecPoint and PointInsideRoom(self.rooms and self.rooms[link.b], points[last - 1]) then
                local door = self:SetRouteDoorOnSide(link, "b", points[last - 1], sideB)
                if door then points[last - 1], points[last] = CopyPoint(door), door end
            end
        end
        local route = RouteEditing.Simplify(points)
        link.bends = {}
        for index = 2, #route - 1 do
            link.bends[#link.bends + 1] = { x = Snap(route[index].x), y = Snap(route[index].y) }
        end
        link.autoRoute, link.isManual = {}, true
    end
end

return PathWorkflow
