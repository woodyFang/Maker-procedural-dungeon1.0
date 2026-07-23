local UI = require("urhox-libs/UI")
local RouteEditing = require("UI.Editor.RouteEditing")
local StairEditing = require("UI.Editor.StairEditing")

local StairWorkflow = {}

local function InsideRoom(room, x, y)
    return room and x >= room.cx - room.w * 0.5 and x <= room.cx + room.w * 0.5
        and y >= room.cy - room.h * 0.5 and y <= room.cy + room.h * 0.5
end

local function CopyRoomShape(room)
    return room and { cx = room.cx, cy = room.cy, w = room.w, h = room.h } or nil
end

local function RestoreRoomShape(room, shape)
    if room and shape then room.cx, room.cy, room.w, room.h = shape.cx, shape.cy, shape.w, shape.h end
end

function StairWorkflow.Install(Editor, helpers)
    local CopyRooms = helpers.CopyRooms
    local CopyLink = helpers.CopyLink
    local CopyPoint = RouteEditing.CopyPoint

    function Editor:CaptureState()
        return { rooms = self:GetRooms(), links = self:GetLinks(), floor = self.floor,
            selected = self.selected, selectedLink = self.selectedLink, nextStairId = self.nextStairId }
    end

    function Editor:RestoreState(snapshot)
        if not snapshot then return end
        self.rooms, self.links = CopyRooms(snapshot.rooms), {}
        for index, link in ipairs(snapshot.links or {}) do self.links[index] = CopyLink(link) end
        self.floor, self.selected, self.selectedLink = snapshot.floor, snapshot.selected, snapshot.selectedLink
        self.nextStairId = snapshot.nextStairId or self.nextStairId
        self.stairSnapshot, self.stairPlacing = nil, false
        self:RefreshOverlay()
        self:NotifySelection()
        self:Commit()
    end

    function Editor:ApplyStairPlacement(link, placement, requestedWidth, requestedOffset)
        local spec = link and link.stairSpec
        if not spec or not placement then return false end
        if requestedWidth then spec.previewWidth = StairEditing.SnapWidth(requestedWidth) end
        -- One-side-fixed width resize supplies a compensating center offset so
        -- the opposite edge stays fixed; other edits leave the offset untouched.
        if requestedOffset ~= nil then spec.previewLateralCenterOffset = requestedOffset end
        spec.previewAnchor, spec.previewDirection = CopyPoint(placement.anchor), placement.direction
        spec.previewLength, spec.previewStyle = placement.length, StairEditing.NormalizeStyle(placement.style)
        spec.mode, spec.invalid, spec.error, spec.manualPreview = "locked", false, nil, true
        link.connector = StairEditing.Visual(spec, link.connector, placement)
        local roomA, roomB = self.rooms[link.a], self.rooms[link.b]
        StairEditing.AdaptRoomToStair(roomA, spec, placement)
        StairEditing.AdaptRoomToStair(roomB, spec, placement)
        if not spec.pending then
            spec.anchor, spec.direction, spec.length = CopyPoint(placement.anchor), placement.direction, placement.length
            spec.style, spec.width = spec.previewStyle, spec.previewWidth or spec.width
            spec.lateralCenterOffset = spec.previewLateralCenterOffset or spec.lateralCenterOffset
        end
        return true
    end

    function Editor:CompleteAddStair(sourceIndex, targetIndex, snapshot, placement)
        local source, target = self.rooms[sourceIndex], self.rooms[targetIndex]
        local errorText = StairEditing.PairError(source, target)
        if errorText then if self.callbacks.onStatus then self.callbacks.onStatus(errorText) end; return false end
        for index, link in ipairs(self.links) do
            if (link.a == sourceIndex and link.b == targetIndex) or (link.a == targetIndex and link.b == sourceIndex) then
                self.selected, self.selectedLink, self.stairPlacing = nil, index, false
                return false
            end
        end
        placement = placement or StairEditing.DirectPlacement({ x = source.cx, y = source.cy }, self.stairPlacementStyle, 8)
        local stairId = "stair-" .. self.nextStairId
        self.nextStairId = self.nextStairId + 1
        self.stairSnapshot = snapshot or self:CaptureState()
        local link = {
            a = sourceIndex, b = targetIndex, kind = "stairs", isManual = true, width = 2,
            bends = {}, autoRoute = {}, stairSpec = {
                id = stairId, mode = "locked", pending = true,
                style = placement.style, previewStyle = placement.style,
                width = 2, previewWidth = 2, landingDepth = 2, previewLandingDepth = 2,
                candidateIndex = 0, candidateCount = 0, manualPreview = true,
            },
        }
        self.links[#self.links + 1] = link
        self:ApplyStairPlacement(link, placement, 2)
        self.selected, self.selectedLink, self.mode, self.stairPlacing = nil, #self.links, "select", false
        self:RefreshOverlay()
        self:NotifySelection()
        self:Commit()
        return true
    end

    function Editor:BeginAddStair()
        if self.stairPlacing then return self:CancelSelectedStair() end
        if self.floorCount < 2 then
            if self.callbacks.onStatus then self.callbacks.onStatus("至少需要两层才能添加楼梯。") end
            return false
        end
        self.stairPlacing, self.mode = true, "select"
        self.selected, self.selectedLink, self.linkStart = nil, nil, nil
        if self.callbacks.onStatus then self.callbacks.onStatus("楼梯工具：在当前层任一区域内点击放置；右键或 Esc 取消。") end
        self:NotifySelection()
        self:RefreshOverlay()
        return true
    end

    function Editor:PlaceStairAt(sourceIndex, x, y)
        local source = self.rooms[sourceIndex]
        if not source or source.floor ~= self.floor then return false end
        local targetFloor = StairEditing.ChooseTargetFloor(source.floor or 0, self.floorCount, 1)
        if targetFloor == nil then return false end
        local snapshot = self:CaptureState()
        local targetIndex, bestArea = nil, math.huge
        for index, room in ipairs(self.rooms) do
            local alreadyLinked = false
            for _, link in ipairs(self.links) do
                if (link.a == sourceIndex and link.b == index) or (link.a == index and link.b == sourceIndex) then
                    alreadyLinked = true; break
                end
            end
            if not alreadyLinked and (room.floor or 0) == targetFloor and InsideRoom(room, x, y) then
                local area = (room.stairRoom and 0 or 1000000) + room.w * room.h
                if area < bestArea then targetIndex, bestArea = index, area end
            end
        end
        if not targetIndex then
            targetIndex = #self.rooms + 1
            self.rooms[targetIndex] = {
                id = targetIndex, cx = RouteEditing.Snap(x), cy = RouteEditing.Snap(y), w = 10, h = 10,
                floor = targetFloor, locked = true, roomGroupId = source.roomGroupId,
                stairRoom = true, stairRoomPairId = "direct-stair-" .. self.nextStairId,
            }
        end
        local placement = StairEditing.DirectPlacement({ x = x, y = y }, self.stairPlacementStyle, 8)
        return self:CompleteAddStair(sourceIndex, targetIndex, snapshot, placement)
    end

    function Editor:ConfirmSelectedStair()
        local link = self.links[self.selectedLink]
        local spec = link and link.stairSpec
        if not spec or not spec.pending or spec.invalid or not spec.previewAnchor then return false end
        spec.anchor, spec.direction = CopyPoint(spec.previewAnchor), spec.previewDirection
        spec.length, spec.style = spec.previewLength or spec.length, spec.previewStyle or spec.style
        spec.width, spec.landingDepth = spec.previewWidth or spec.width, spec.previewLandingDepth or spec.landingDepth
        spec.pending, spec.invalid, spec.error = false, false, nil
        self.stairSnapshot = nil
        self:RefreshOverlay()
        self:Commit()
        return true
    end

    function Editor:CancelSelectedStair()
        if self.stairPlacing then
            self.stairPlacing = false
            if self.callbacks.onStatus then self.callbacks.onStatus("已取消楼梯工具。") end
            self:RefreshOverlay()
            return true
        end
        if self.stairSnapshot then self:RestoreState(self.stairSnapshot); return true end
        return false
    end

    function Editor:RotateSelectedStair()
        local link = self.links[self.selectedLink]
        local spec = link and link.stairSpec
        local rotated = spec and StairEditing.Rotate90(spec, link.connector)
        if not rotated or not self:ApplyStairPlacement(link, rotated) then return false end
        self:RefreshOverlay()
        self:Commit()
        return true
    end

    function Editor:SetSelectedStairStyle(style)
        self.stairPlacementStyle = StairEditing.NormalizeStyle(style)
        local link = self.links[self.selectedLink]
        if not link or link.kind ~= "stairs" then self:RefreshOverlay(); return true end
        local placement = StairEditing.ChangeStyle(link.stairSpec, link.connector, self.stairPlacementStyle)
        if not placement or not self:ApplyStairPlacement(link, placement) then return false end
        self:RefreshOverlay()
        self:Commit()
        return true
    end

    function Editor:CaptureStairDrag(linkIndex)
        local link = self.links[linkIndex]
        if not link or not link.stairSpec or not link.connector then return nil end
        return {
            link = linkIndex, spec = CopyLink(link).stairSpec, connector = link.connector,
            roomA = CopyRoomShape(self.rooms[link.a]), roomB = CopyRoomShape(self.rooms[link.b]),
        }
    end

    function Editor:CaptureRoomStairEdit(roomIndex)
        local room, pairIndex = self.rooms[roomIndex], nil
        if room and room.stairRoomPairId then
            for index, other in ipairs(self.rooms) do
                if index ~= roomIndex and other.stairRoomPairId == room.stairRoomPairId then pairIndex = index; break end
            end
        end
        local result = { room = roomIndex, pair = pairIndex, pairShape = CopyRoomShape(self.rooms[pairIndex]), stairs = {}, shapes = {} }
        for linkIndex, link in ipairs(self.links) do
            if link.kind == "stairs" and (link.a == roomIndex or link.b == roomIndex
                or (pairIndex and (link.a == pairIndex or link.b == pairIndex))) and link.stairSpec and link.connector then
                result.stairs[#result.stairs + 1] = self:CaptureStairDrag(linkIndex)
                result.shapes[link.a], result.shapes[link.b] = CopyRoomShape(self.rooms[link.a]), CopyRoomShape(self.rooms[link.b])
            end
        end
        return result
    end

    function Editor:UpdateRoomStairEdit(edit, deltaX, deltaY, resized)
        if not edit then return end
        local room = self.rooms[edit.room]
        if edit.pair and self.rooms[edit.pair] then
            local pair = self.rooms[edit.pair]
            if resized then pair.cx, pair.cy, pair.w, pair.h = room.cx, room.cy, room.w, room.h
            else pair.cx, pair.cy = edit.pairShape.cx + deltaX, edit.pairShape.cy + deltaY end
        end
        if resized then return end
        for _, stair in ipairs(edit.stairs) do
            local link, base = self.links[stair.link], stair.spec
            if link then
                for _, endpoint in ipairs({ link.a, link.b }) do
                    if endpoint ~= edit.room and endpoint ~= edit.pair then RestoreRoomShape(self.rooms[endpoint], edit.shapes[endpoint]) end
                end
                local anchor = base.previewAnchor or base.anchor or stair.connector.lower
                local placement = {
                    anchor = { x = anchor.x + deltaX, y = anchor.y + deltaY },
                    direction = base.previewDirection or base.direction,
                    length = base.previewLength or base.length,
                    style = base.previewStyle or base.style,
                }
                link.stairSpec = CopyLink({ a = link.a, b = link.b, stairSpec = base }).stairSpec
                self:ApplyStairPlacement(link, placement)
            end
        end
    end

    function Editor:UpdateStairDrag(drag, placement, width, lateralCenterOffset)
        local link = drag and self.links[drag.link]
        if not link then return false end
        RestoreRoomShape(self.rooms[link.a], drag.roomA)
        RestoreRoomShape(self.rooms[link.b], drag.roomB)
        link.stairSpec = CopyLink({ stairSpec = drag.spec, a = link.a, b = link.b }).stairSpec
        link.connector = drag.connector
        return self:ApplyStairPlacement(link, placement, width, lateralCenterOffset)
    end

    function Editor:ToggleSelectedStairLock()
        local link = self.links[self.selectedLink]
        local spec = link and link.stairSpec
        if not spec then return false end
        spec.mode = spec.mode == "locked" and "stable-auto" or "locked"
        if spec.mode == "locked" and not spec.anchor and spec.previewAnchor then
            spec.anchor, spec.direction = CopyPoint(spec.previewAnchor), spec.previewDirection
        end
        self:RefreshOverlay()
        self:Commit()
        return true
    end

    function Editor:DeleteSelectedStair()
        local index, link = self.selectedLink, self.links[self.selectedLink]
        if not link or link.kind ~= "stairs" then return false end
        local function Delete()
            if not StairEditing.RemovePairedStairRooms(self.rooms, self.links, link) then table.remove(self.links, index) end
            self.selectedLink, self.stairSnapshot = nil, nil
            self:MarkDisconnectedRoomsSecret()
            self:RefreshOverlay()
            self:NotifySelection()
            self:Commit()
        end
        if StairEditing.RemovalDisconnectsRooms(self.rooms, self.links, link) then
            UI.Modal.Confirm {
                title = "删除关键楼梯？",
                message = "删除后会有区域或楼层无法从入口到达。仍然删除吗？",
                confirmText = "仍然删除", cancelText = "取消", onConfirm = Delete,
            }
        else Delete() end
        return true
    end
end

return StairWorkflow
