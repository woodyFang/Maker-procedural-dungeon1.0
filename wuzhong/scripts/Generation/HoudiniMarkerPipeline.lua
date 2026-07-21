local HoudiniMarkerPipeline = {}
local HoudiniCoordinateSystem = require("Generation.HoudiniCoordinateSystem")

HoudiniMarkerPipeline.SCHEMA_VERSION = 9
HoudiniMarkerPipeline.MARKER_TYPES = {
    "Ground", "Wall", "Door", "WallSeparator", "Stair", "Ceil", "Light",
    "Light_Ambient", "Light_Door", "Light_Stair", "Light_Hero",
    "PillarPlacement", "PillarWebPlacement", "Curbstone01Placement",
}

local CATEGORY = {
    Ground = 0, Wall = 1, Door = 2, WallSeparator = 3, Stair = 4, Ceil = 5, Light = 6,
    Light_Ambient = 10, Light_Door = 11, Light_Stair = 12, Light_Hero = 13,
    PillarPlacement = 20, PillarWebPlacement = 22, Curbstone01Placement = 23,
}
local DIRECTIONS = {
    { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
}

local function V(x, y, z) return { x or 0, y or 0, z or 0 } end
local function CopyV(value) return V(value and value[1], value and value[2], value and value[3]) end
local function Add(a, b) return V(a[1] + b[1], a[2] + b[2], a[3] + b[3]) end
local function Sub(a, b) return V(a[1] - b[1], a[2] - b[2], a[3] - b[3]) end
local function Scale(a, amount) return V(a[1] * amount, a[2] * amount, a[3] * amount) end
local function Length2(a) return a[1] * a[1] + a[2] * a[2] + a[3] * a[3] end
local function Normalize(a)
    local length = math.sqrt(Length2(a))
    return length > 0.00000001 and Scale(a, 1 / length) or V(0, 0, 0)
end
local function Cross(a, b)
    return V(a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3],
        a[1] * b[2] - a[2] * b[1])
end
local function Dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function Round(value)
    return value >= 0 and math.floor(value + 0.5) or math.ceil(value - 0.5)
end
local function PositionKey(position, precision)
    precision = precision or 10000
    return string.format("%d|%d|%d", Round(position[1] * precision),
        Round(position[2] * precision), Round(position[3] * precision))
end
local function MarkerKey(marker)
    return string.format("%s|%d|%d|%d", marker.name,
        Round(marker.position[1] * 1000), Round(marker.position[2] * 1000),
        Round(marker.position[3] * 1000))
end
local function Horizontal(value) return V(value[1], 0, value[3]) end
local function AngleDegrees(normal)
    local angle = math.deg(math.atan(-normal[1], normal[3]))
    return angle < 0 and angle + 360 or angle
end
local OrientLocalX = HoudiniCoordinateSystem.OrientLocalX
local OrientLocalForward = HoudiniCoordinateSystem.OrientLocalForward
local OrientPillarPlacement = HoudiniCoordinateSystem.OrientPillarPlacement

local function NewMarker(name, position, normal, attributes)
    attributes = attributes or {}
    local marker = {
        name = name,
        category = CATEGORY[name],
        position = CopyV(position),
        normal = CopyV(normal or V(0, 0, 1)),
        up = V(0, 1, 0),
        orient = attributes.orient or { 0, 0, 0, 1 },
        scale = attributes.scale or V(1, 1, 1),
        pscale = attributes.pscale or 1,
        attributes = attributes,
        groups = { all_markers = true, gridflow_markers = true, ["marker_" .. name] = true },
    }
    marker.angle = attributes.marker_angle or AngleDegrees(marker.normal)
    return marker
end

local function CellMaps(cells)
    local byPosition, byId = {}, {}
    for _, cell in ipairs(cells) do
        byPosition[PositionKey(cell.position)] = cell
        byId[cell.id] = cell
    end
    return byPosition, byId
end

local function FindCell(byPosition, position)
    return byPosition[PositionKey(position)]
end

local function PairStairCells(cells, cellSize)
    local role0, role1 = {}, {}
    for _, cell in ipairs(cells) do
        if cell.cell_type == 3 and cell.stair_role == 0 then role0[#role0 + 1] = cell
        elseif cell.cell_type == 3 and cell.stair_role == 1 then role1[#role1 + 1] = cell end
    end
    table.sort(role0, function(a, b) return a.id < b.id end)
    table.sort(role1, function(a, b) return a.id < b.id end)
    local used, result = {}, {}
    for _, lower in ipairs(role0) do
        local match = nil
        for index, upper in ipairs(role1) do
            if not used[index] then
                local delta = Sub(upper.position, lower.position)
                local adjacent = math.abs(delta[2]) < 0.001
                    and ((math.abs(math.abs(delta[1]) - cellSize) < 0.001 and math.abs(delta[3]) < 0.001)
                        or (math.abs(math.abs(delta[3]) - cellSize) < 0.001 and math.abs(delta[1]) < 0.001))
                if adjacent then
                    if upper.connection_id == lower.connection_id
                        and upper.stairwell_id == lower.stairwell_id then match = index; break end
                end
            end
        end
        if match then
            used[match] = true
            local upper = role1[match]
            local delta = Sub(upper.position, lower.position)
            local direction = math.abs(delta[1]) >= math.abs(delta[3])
                and V(delta[1] >= 0 and 1 or -1, 0, 0)
                or V(0, 0, delta[3] >= 0 and 1 or -1)
            result[#result + 1] = { lower = lower, upper = upper, direction = direction }
        end
    end
    return result
end

local function ValidateStairPairs(cells, stairPairs, cellSize)
    local byPosition = CellMaps(cells)
    local errors = {}
    local function Error(stairwell, message)
        errors[#errors + 1] = string.format("stairwell %s: %s", tostring(stairwell), message)
    end
    local pairByStair, stairwells = {}, {}
    for _, pair in ipairs(stairPairs) do pairByStair[pair.lower.stairwell_id] = pair end
    for _, cell in ipairs(cells) do
        if cell.stairwell_id ~= nil and cell.stairwell_id >= 0 then
            stairwells[cell.stairwell_id] = true
        end
    end
    for stairwell in pairs(stairwells) do
        if not pairByStair[stairwell] then Error(stairwell, "physical stair cells could not be paired") end
    end
    for _, pair in ipairs(stairPairs) do
        local stairwell = pair.lower.stairwell_id
        local roles = {}
        for _, cell in ipairs(cells) do
            if cell.stairwell_id == stairwell then roles[cell.stair_role] = cell end
        end
        local count = 0
        for _, cell in ipairs(cells) do
            if cell.stairwell_id == stairwell then count = count + 1 end
        end
        if count ~= 4 then Error(stairwell, "must occupy exactly 4 cells, got " .. count) end
        if not roles[0] or not roles[1] or not roles[2] or not roles[3] then
            Error(stairwell, "missing one or more stair roles")
        else
            if roles[0].cell_type ~= 3 or roles[1].cell_type ~= 3
                or roles[2].cell_type ~= 4 or roles[3].cell_type ~= 4 then
                Error(stairwell, "roles are not two physical stairs plus two headroom cells")
            end
            local lowerDelta = Sub(roles[1].position, roles[0].position)
            local adjacent = math.abs(lowerDelta[2]) < 0.001
                and ((math.abs(math.abs(lowerDelta[1]) - cellSize) < 0.001
                        and math.abs(lowerDelta[3]) < 0.001)
                    or (math.abs(math.abs(lowerDelta[3]) - cellSize) < 0.001
                        and math.abs(lowerDelta[1]) < 0.001))
            local headroomDelta0 = Sub(roles[2].position, roles[0].position)
            local headroomDelta1 = Sub(roles[3].position, roles[1].position)
            if not adjacent or math.abs(headroomDelta0[1]) > 0.001
                or math.abs(headroomDelta0[2] - cellSize) > 0.001
                or math.abs(headroomDelta0[3]) > 0.001
                or math.abs(headroomDelta1[1]) > 0.001
                or math.abs(headroomDelta1[2] - cellSize) > 0.001
                or math.abs(headroomDelta1[3]) > 0.001 then
                Error(stairwell, "physical/headroom cells are not vertically aligned")
            end
            local lowerLanding = FindCell(byPosition,
                Add(roles[0].position, Scale(pair.direction, -cellSize)))
            local upperLanding = FindCell(byPosition,
                Add(roles[3].position, Scale(pair.direction, cellSize)))
            if not lowerLanding or lowerLanding.cell_type ~= 2 then
                Error(stairwell, "lower stair end is not connected to a corridor cell")
            end
            if not upperLanding or upperLanding.cell_type ~= 2 then
                Error(stairwell, "upper stair end is not connected to a corridor cell")
            end
        end
    end
    return #errors == 0, errors
end

local function BuildGround(cells, cellSize)
    local result = {}
    for _, cell in ipairs(cells) do
        if cell.cell_type == 1 or cell.cell_type == 2 then
            local position = Add(cell.position, V(0, -cellSize * 0.5, 0))
            local marker = NewMarker("Ground", position, V(0, 0, 1), {
                marker_angle = 0, marker_size = V(cellSize, cellSize, cellSize),
                source_cell = cell.id, source_cell_type = cell.cell_type,
                source_room_id = cell.room_id, source_grid_index = cell.grid_index,
                floor_id = cell.floor_id,
            })
            marker.groups[cell.cell_type == 1 and "marker_Ground_Room" or "marker_Ground_Corridor"] = true
            result[#result + 1] = marker
        end
    end
    return result
end

local function DoorPositionMap(doors, cellSize)
    local result = {}
    for _, door in ipairs(doors) do
        result[PositionKey(Add(door.position, V(0, cellSize * 0.5, 0)))] = true
    end
    return result
end

local function BuildWalls(cells, doors, stairPairs, cellSize)
    local byPosition = CellMaps(cells)
    local doorPositions = DoorPositionMap(doors, cellSize)
    local result, emitted = {}, {}

    local function emit(position, normal, cellType, roomId, priority, extra)
        local key = PositionKey(position)
        local existing = emitted[key]
        if existing and existing.attributes.marker_priority >= priority then return existing end
        local attributes = extra or {}
        attributes.marker_priority = priority
        attributes.marker_size = V(cellSize, cellSize, cellSize)
        attributes.source_cell_type = cellType
        attributes.source_room_id = roomId or -1
        attributes.source_connection_id = attributes.source_connection_id or -1
        attributes.marker_angle = AngleDegrees(normal)
        if existing then
            existing.normal, existing.orient, existing.angle = CopyV(normal), OrientLocalX(normal), attributes.marker_angle
            existing.attributes = attributes
            existing.groups.marker_Wall_Room = nil
            existing.groups.marker_Wall_Corridor = nil
            existing.groups.marker_Wall_Stair = nil
        else
            existing = NewMarker("Wall", position, normal, attributes)
            existing.orient = OrientLocalX(normal)
            emitted[key] = existing
            result[#result + 1] = existing
        end
        existing.groups[cellType == 1 and "marker_Wall_Room"
            or (cellType == 2 and "marker_Wall_Corridor" or "marker_Wall_Stair")] = true
        return existing
    end

    for _, cell in ipairs(cells) do
        if cell.cell_type == 1 or cell.cell_type == 2 then
            for _, normal in ipairs(DIRECTIONS) do
                local neighbor = FindCell(byPosition, Add(cell.position, Scale(normal, cellSize)))
                local boundary = Add(cell.position, Scale(normal, cellSize * 0.5))
                local blocked = neighbor == nil
                if neighbor then
                    local touchesRoom = cell.cell_type == 1 or neighbor.cell_type == 1
                    local sameRoom = cell.cell_type == 1 and neighbor.cell_type == 1
                        and cell.room_id == neighbor.room_id
                    local sameCorridor = cell.cell_type == 2 and neighbor.cell_type == 2
                    blocked = touchesRoom and not sameRoom and not sameCorridor
                        and not doorPositions[PositionKey(boundary)]
                end
                if blocked then
                    local position = Add(boundary, V(0, -cellSize * 0.5, 0))
                    emit(position, normal, cell.cell_type, cell.room_id,
                        cell.cell_type == 1 and 2 or 1)
                end
            end
        end
    end

    for stairIndex, pair in ipairs(stairPairs) do
        local sideNormal = V(-pair.direction[3], 0, pair.direction[1])
        local wallBaseY = math.min(pair.lower.position[2], pair.upper.position[2]) - cellSize * 0.5
        local centers = { pair.lower.position, pair.upper.position }
        for lengthIndex = 0, 1 do
            for heightIndex = 0, 1 do
                for _, side in ipairs({ -1, 1 }) do
                    local normal = Scale(sideNormal, side)
                    local position = Add(centers[lengthIndex + 1], Scale(normal, cellSize * 0.5))
                    position[2] = wallBaseY + heightIndex * cellSize
                    emit(position, normal, 3, -1, 3, {
                        source_connection_id = pair.lower.connection_id,
                        source_stair_instance_id = pair.lower.stairwell_id >= 0
                            and pair.lower.stairwell_id or stairIndex - 1,
                        source_stair_role = lengthIndex,
                        source_stair_length_index = lengthIndex,
                        source_stair_height_index = heightIndex,
                    })
                end
            end
        end
        for endIndex = 0, 1 do
            local lengthIndex = endIndex == 0 and 0 or 1
            local heightIndex = endIndex == 0 and 1 or 0
            local normal = endIndex == 0 and Scale(pair.direction, -1) or pair.direction
            local position = Add(centers[lengthIndex + 1], Scale(normal, cellSize * 0.5))
            position[2] = wallBaseY + heightIndex * cellSize
            emit(position, normal, 3, -1, 3, {
                source_connection_id = pair.lower.connection_id,
                source_stair_instance_id = pair.lower.stairwell_id >= 0
                    and pair.lower.stairwell_id or stairIndex - 1,
                source_stair_role = lengthIndex, source_stair_end_type = endIndex + 1,
                source_stair_length_index = lengthIndex,
                source_stair_height_index = heightIndex,
            })
        end
    end
    return result
end

local function BuildDoors(doors, cellSize)
    local result, emitted = {}, {}
    for index, source in ipairs(doors) do
        local normal = Normalize(Horizontal(source.normal or V(0, 0, 1)))
        if Length2(normal) < 0.000001 then normal = V(0, 0, 1) end
        local key = PositionKey(source.position) .. "|" .. PositionKey(normal)
        if not emitted[key] then
            local marker = NewMarker("Door", source.position, normal, {
                marker_size = V(cellSize, cellSize, cellSize),
                marker_angle = AngleDegrees(normal),
                source_room_id = source.source_room_id or -1,
                source_connection_id = source.source_connection_id or -1,
                source_cell_type = source.source_cell_type or 0,
                source_astar_point = index - 1,
            })
            marker.orient = OrientLocalX(normal)
            result[#result + 1], emitted[key] = marker, marker
        end
    end
    return result
end

local function BuildStairs(stairPairs, cellSize)
    local result = {}
    for index, pair in ipairs(stairPairs) do
        local position = Add(pair.lower.position, V(0, -cellSize * 0.5, 0))
        local marker = NewMarker("Stair", position, pair.direction, {
            marker_size = V(cellSize * 2, cellSize, cellSize), marker_span_cells = 2,
            marker_occupied_cells = 4, marker_angle = math.deg(math.atan(pair.direction[1], pair.direction[3])),
            source_connection_id = pair.lower.connection_id,
            source_grid_index = pair.lower.grid_index, source_stair_role = 0,
            stairwell_id = pair.lower.stairwell_id,
            source_stair_instance_id = pair.lower.stairwell_id >= 0 and pair.lower.stairwell_id or index - 1,
        })
        if marker.angle < 0 then marker.angle = marker.angle + 360 end
        marker.orient = OrientLocalForward(pair.direction)
        marker.groups.marker_Stair_Stair = true
        result[#result + 1] = marker
    end
    return result
end

local function BuildCeil(cells, cellSize)
    local positions, metadata = {}, {}
    for _, cell in ipairs(cells) do
        if cell.cell_type == 1 or cell.cell_type == 2 or cell.cell_type == 4 then
            local position = Add(cell.position, V(0, cellSize * 0.5, 0))
            local key = PositionKey(position)
            local priority = cell.cell_type
            if not metadata[key] or priority > metadata[key].priority then
                positions[key] = position
                metadata[key] = { cell = cell, priority = priority }
            end
        end
    end
    local result = {}
    for key, position in pairs(positions) do
        local cell = metadata[key].cell
        local east = positions[PositionKey(Add(position, V(cellSize, 0, 0)))] ~= nil
        local west = positions[PositionKey(Add(position, V(-cellSize, 0, 0)))] ~= nil
        local north = positions[PositionKey(Add(position, V(0, 0, cellSize)))] ~= nil
        local south = positions[PositionKey(Add(position, V(0, 0, -cellSize)))] ~= nil
        local innerMask = 0
        if east and north and not positions[PositionKey(Add(position, V(cellSize, 0, cellSize)))] then innerMask = innerMask | 1 end
        if west and north and not positions[PositionKey(Add(position, V(-cellSize, 0, cellSize)))] then innerMask = innerMask | 2 end
        if west and south and not positions[PositionKey(Add(position, V(-cellSize, 0, -cellSize)))] then innerMask = innerMask | 4 end
        if east and south and not positions[PositionKey(Add(position, V(cellSize, 0, -cellSize)))] then innerMask = innerMask | 8 end
        local boundary = not (east and west and north and south) or innerMask ~= 0
        local marker = NewMarker("Ceil", position, V(0, 1, 0), {
            marker_angle = 0, marker_size = V(cellSize, cellSize, cellSize),
            source_cell_type = cell.cell_type == 4 and 3 or cell.cell_type,
            source_room_id = cell.room_id, source_grid_index = cell.grid_index,
            ceil_is_boundary = boundary and 1 or 0,
            ceil_is_inner_corner = innerMask ~= 0 and 1 or 0,
            ceil_inner_corner_mask = innerMask,
        })
        marker.up = V(0, 0, 1)
        marker.groups[boundary and "marker_Ceil_Boundary" or "marker_Ceil_Interior"] = true
        marker.groups[innerMask ~= 0 and "marker_Ceil_InnerCorner" or "marker_Ceil_NonInnerCorner"] = true
        local typeName = cell.cell_type == 1 and "Room" or (cell.cell_type == 2 and "Corridor" or "Stair")
        marker.groups["marker_Ceil_" .. typeName] = true
        result[#result + 1] = marker
    end
    table.sort(result, function(a, b) return PositionKey(a.position) < PositionKey(b.position) end)
    return result
end

local function BuildCellLights(cells, cellSize)
    local result = {}
    for _, cell in ipairs(cells) do
        if cell.cell_type ~= 3 then
            result[#result + 1] = NewMarker("Light", cell.position, V(0, 0, 1), {
                marker_angle = 0, marker_size = V(cellSize, cellSize, cellSize),
                source_cell = cell.id, source_cell_type = cell.cell_type,
                source_grid_index = cell.grid_index, source_room_id = cell.room_id,
                source_connection_id = cell.connection_id, source_stair_role = cell.stair_role,
            })
        end
    end
    return result
end

local function CardinalIndex(direction)
    if math.abs(direction[1]) >= math.abs(direction[3]) then return direction[1] >= 0 and 1 or 2 end
    return direction[3] >= 0 and 3 or 4
end

local function BitCount4(mask)
    local count = 0
    for _, bit in ipairs({ 1, 2, 4, 8 }) do if mask & bit ~= 0 then count = count + 1 end end
    return count
end

local function BuildWallSeparators(walls, cellSize)
    local endpointByKey, endpoints = {}, {}
    local bits = { 1, 2, 4, 8 }
    for wallIndex, wall in ipairs(walls) do
        local cellType = wall.attributes.source_cell_type or 0
        local priority = cellType == 3 and 3 or (cellType == 1 and 2 or 1)
        local categoryMask = cellType == 3 and 4 or (cellType == 1 and 1 or 2)
        local facing = Scale(wall.normal, -1)
        local directionIndex = CardinalIndex(facing)
        local tangent = Cross(V(0, 1, 0), wall.normal)
        for _, side in ipairs({ -1, 1 }) do
            local position = Add(wall.position, Scale(tangent, side * cellSize * 0.5))
            local key = PositionKey(position)
            local endpoint = endpointByKey[key]
            if not endpoint then
                endpoint = { position = position, count = 0, categoryMask = 0, directionMask = 0,
                    scores = { 0, 0, 0, 0 }, roomId = -1, priority = 0, sourceWall = wallIndex - 1 }
                endpointByKey[key], endpoints[#endpoints + 1] = endpoint, endpoint
            end
            endpoint.count = endpoint.count + 1
            endpoint.categoryMask = endpoint.categoryMask | categoryMask
            endpoint.directionMask = endpoint.directionMask | bits[directionIndex]
            endpoint.scores[directionIndex] = endpoint.scores[directionIndex] + priority * 100 + 1
            endpoint.priority = math.max(endpoint.priority, priority)
            if cellType == 1 and (wall.attributes.source_room_id or -1) >= 0 and endpoint.roomId < 0 then
                endpoint.roomId = wall.attributes.source_room_id
            end
        end
    end

    local result = {}
    for _, endpoint in ipairs(endpoints) do
        local directionCount = BitCount4(endpoint.directionMask)
        local directionSum = V(0, 0, 0)
        for index, bit in ipairs(bits) do
            if endpoint.directionMask & bit ~= 0 then directionSum = Add(directionSum, DIRECTIONS[index]) end
        end
        local preferred, cornerClass, preferredClass, valid = V(0, 0, 0), "End", "Invalid", true
        if directionCount == 1 then
            preferred = Normalize(directionSum)
            preferredClass = math.abs(preferred[1]) > 0.5 and "AxisX" or "AxisZ"
        elseif directionCount == 2 and Length2(directionSum) > 0.5 then
            preferred, cornerClass, preferredClass = Normalize(directionSum), "Corner", "DiagonalXZ"
        else
            local best = 1
            for index = 2, 4 do if endpoint.scores[index] > endpoint.scores[best] then best = index end end
            preferred = DIRECTIONS[best]
            if directionCount == 2 then cornerClass, valid = "Opposite", false
            elseif directionCount == 3 then
                cornerClass = "Tee"
                if Length2(directionSum) > 0.5 then preferred = Normalize(directionSum) end
            else cornerClass, valid = "Cross", false end
            preferredClass = math.abs(preferred[1]) > 0.5 and "JunctionX" or "JunctionZ"
        end
        local marker = NewMarker("WallSeparator", endpoint.position, V(0, 0, 1), {
            marker_angle = 0, marker_priority = endpoint.priority,
            marker_size = V(cellSize, cellSize, cellSize), source_room_id = endpoint.roomId,
            source_wall_point = endpoint.sourceWall, source_wall_count = endpoint.count,
            source_wall_category_mask = endpoint.categoryMask,
            source_cell_type = endpoint.categoryMask & 4 ~= 0 and 3
                or (endpoint.categoryMask & 1 ~= 0 and 1 or 2),
            pillar_corner_class = cornerClass,
            pillar_attachment_preferred_direction = preferred,
            pillar_attachment_preferred_class = preferredClass,
            pillar_attachment_direction_mask = endpoint.directionMask,
            pillar_attachment_direction_count = directionCount,
            pillar_attachment_valid = valid and 1 or 0,
            pillar_attachment_surface_position = Add(endpoint.position,
                Add(Scale(preferred, cellSize * 0.10), V(0, cellSize * 0.50, 0))),
            pillar_attachment_position = Add(endpoint.position,
                Add(Scale(preferred, cellSize * 0.12), V(0, cellSize * 0.50, 0))),
        })
        if endpoint.categoryMask & 1 ~= 0 then marker.groups.marker_WallSeparator_Room = true end
        if endpoint.categoryMask & 2 ~= 0 then marker.groups.marker_WallSeparator_Corridor = true end
        if endpoint.categoryMask & 4 ~= 0 then marker.groups.marker_WallSeparator_Stair = true end
        result[#result + 1] = marker
    end
    return result
end

local function NearAnyMarker(position, markerLists, distance)
    for _, markers in ipairs(markerLists) do
        for _, marker in ipairs(markers) do
            local delta = Horizontal(Sub(position, marker.position))
            if math.sqrt(Length2(delta)) < distance then return true end
        end
    end
    return false
end

local function StableFraction(cellId, roomId)
    local value = ((cellId or 0) * 1103515245 + (roomId or 0) * 12345 + 3502) & 0xffffffff
    value = (value ~ (value >> 16)) * 2246822519 & 0xffffffff
    value = (value ~ (value >> 13)) * 3266489917 & 0xffffffff
    return ((value ~ (value >> 16)) & 0xffffffff) / 0xffffffff
end

local function BuildAmbientLights(cells, doors, stairs, reference, cellSize)
    if type(reference) == "table" and #reference > 0 then
        local result = {}
        for _, item in ipairs(reference) do
            result[#result + 1] = NewMarker("Light_Ambient", item.position,
                item.normal or V(0, 0, 1), { source_cell = item.source_cell })
        end
        return result
    end
    local candidates = {}
    for _, cell in ipairs(cells) do
        if (cell.cell_type == 1 or cell.cell_type == 2)
            and not NearAnyMarker(cell.position, { doors, stairs }, cellSize + 0.1) then
            local score = StableFraction(cell.id, cell.room_id)
            if score <= 0.45 then candidates[#candidates + 1] = { cell = cell, score = score } end
        end
    end
    local result = {}
    for _, candidate in ipairs(candidates) do
        if not NearAnyMarker(candidate.cell.position, { result }, cellSize * 2) then
            result[#result + 1] = NewMarker("Light_Ambient", candidate.cell.position, V(0, 0, 1), {
                source_cell = candidate.cell.id, light_variation = candidate.score,
            })
        end
    end
    return result
end

local function BuildDoorLights(doors, cells, cellSize)
    local result, emitted = {}, {}
    for index, door in ipairs(doors) do
        local normal = Normalize(Horizontal(door.normal))
        local target = Add(door.position, Scale(normal, cellSize * 0.5))
        local expectedY = door.position[2] + cellSize * 0.5
        local best, bestDifference = nil, math.huge
        for _, cell in ipairs(cells) do
            if cell.cell_type == 1 or cell.cell_type == 2 then
                local delta = Sub(cell.position, target); delta[2] = 0
                if Length2(delta) <= 0.01 then
                    local difference = math.abs(cell.position[2] - expectedY)
                    if difference < bestDifference then best, bestDifference = cell, difference end
                end
            end
        end
        if best and not emitted[PositionKey(best.position)] then
            local marker = NewMarker("Light_Door", best.position, normal, {
                source_door_point = index - 1, source_cell = best.id,
                source_cell_type = best.cell_type, marker_angle = 0,
            })
            marker.orient = door.orient or OrientLocalX(normal)
            result[#result + 1], emitted[PositionKey(best.position)] = marker, true
        end
    end
    return result
end

local function BuildStairLights(stairs, cellSize)
    local result = {}
    for index, stair in ipairs(stairs) do
        for endpoint, position in ipairs({
            Add(stair.position, V(0, cellSize * 0.5, 0)),
            Add(stair.position, Add(Scale(stair.normal, cellSize), V(0, cellSize * 1.5, 0))),
        }) do
            local marker = NewMarker("Light_Stair", position, stair.normal, {
                source_stair_instance_id = stair.attributes.source_stair_instance_id or index - 1,
                stair_endpoint = endpoint - 1, marker_angle = 0,
            })
            marker.orient = stair.orient or OrientLocalForward(stair.normal)
            result[#result + 1] = marker
        end
    end
    return result
end

local function BuildHeroLights(cells)
    local byRoom = {}
    for _, cell in ipairs(cells) do
        if cell.cell_type == 1 and cell.room_id >= 0 then
            local room = byRoom[cell.room_id] or { sum = V(0, 0, 0), count = 0, top = -math.huge }
            room.sum, room.count = Add(room.sum, cell.position), room.count + 1
            room.top = math.max(room.top, cell.position[2])
            byRoom[cell.room_id] = room
        end
    end
    local result, ids = {}, {}
    for id in pairs(byRoom) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local room = byRoom[id]
        if room.count >= 6 then
            local position = Scale(room.sum, 1 / room.count); position[2] = room.top + 2
            result[#result + 1] = NewMarker("Light_Hero", position, V(0, 0, 1), {
                source_room_id = id, room_cell_count = room.count,
            })
        end
    end
    return result
end

local function GroundComponents(grounds, cellSize)
    local corridorByPosition, components = {}, {}
    for index, ground in ipairs(grounds) do
        if ground.attributes.source_cell_type == 2 then corridorByPosition[PositionKey(ground.position)] = index end
    end
    local componentId = 0
    for startIndex, ground in ipairs(grounds) do
        if ground.attributes.source_cell_type == 2 and components[startIndex] == nil then
            local queue, head = { startIndex }, 1
            components[startIndex] = componentId
            while head <= #queue do
                local current = queue[head]; head = head + 1
                for _, direction in ipairs(DIRECTIONS) do
                    local neighbor = corridorByPosition[PositionKey(Add(grounds[current].position,
                        Scale(direction, cellSize)))]
                    if neighbor and components[neighbor] == nil then
                        components[neighbor] = componentId; queue[#queue + 1] = neighbor
                    end
                end
            end
            componentId = componentId + 1
        end
    end
    return components
end

local function AdjacentGrounds(pillar, grounds, cellSize, diagonalOnly)
    local result, half, epsilon = {}, cellSize * 0.5, cellSize * 0.01
    for index, ground in ipairs(grounds) do
        local delta = Sub(ground.position, pillar.position)
        local adjacent = math.abs(delta[2]) <= epsilon
        if diagonalOnly then
            adjacent = adjacent and math.abs(math.abs(delta[1]) - half) <= epsilon
                and math.abs(math.abs(delta[3]) - half) <= epsilon
        else
            adjacent = adjacent and math.abs(delta[1]) <= half + 0.001
                and math.abs(delta[3]) <= half + 0.001
                and delta[1] * delta[1] + delta[3] * delta[3] <= half * half * 2 + 0.01
                and delta[1] * delta[1] + delta[3] * delta[3] > 0.001
        end
        if adjacent then result[#result + 1] = index end
    end
    return result
end

local function BuildPillarPlacements(separators, grounds, cellSize, targetDistance, referenceSources)
    if type(referenceSources) == "table" and #referenceSources > 0 then
        local result = {}
        for _, source in ipairs(referenceSources) do
            local direction = Normalize(Horizontal(Sub(source.source_position, source.pillar_position)))
            local position = Add(source.pillar_position, Scale(direction, targetDistance))
            local marker = NewMarker("PillarPlacement", position, direction, {
                placement_owner_type = source.owner_type, placement_owner_id = source.owner_id,
                placement_ground_count = source.ground_count,
                placement_source_position = source.source_position,
                placement_pillar_position = source.pillar_position,
                placement_direction = direction, placement_distance = targetDistance, marker_angle = 0,
            })
            marker.orient = OrientPillarPlacement(direction)
            result[#result + 1] = marker
        end
        return result
    end
    local components = GroundComponents(grounds, cellSize)
    local unique = {}
    for pillarIndex, pillar in ipairs(separators) do
        local byOwner = {}
        for _, groundIndex in ipairs(AdjacentGrounds(pillar, grounds, cellSize, false)) do
            local ground = grounds[groundIndex]
            local cellType = ground.attributes.source_cell_type
            local ownerId = cellType == 1 and ground.attributes.source_room_id or components[groundIndex]
            local ownerKey = cellType .. "|" .. tostring(ownerId)
            local owner = byOwner[ownerKey] or { type = cellType, id = ownerId, indices = {} }
            owner.indices[#owner.indices + 1], byOwner[ownerKey] = groundIndex, owner
        end
        for ownerKey, owner in pairs(byOwner) do
            local sourcePosition = V(0, 0, 0)
            for _, index in ipairs(owner.indices) do sourcePosition = Add(sourcePosition, grounds[index].position) end
            sourcePosition = Scale(sourcePosition, 1 / #owner.indices)
            local direction = Normalize(Horizontal(Sub(sourcePosition, pillar.position)))
            if Length2(direction) > 0 then
                local key = ownerKey .. "|" .. PositionKey(sourcePosition)
                local candidate = unique[key]
                if not candidate or pillarIndex < candidate.pillarIndex then
                    unique[key] = { owner = owner, sourcePosition = sourcePosition,
                        direction = direction, pillar = pillar, pillarIndex = pillarIndex }
                end
            end
        end
    end
    local keys, result = {}, {}
    for key in pairs(unique) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local candidate = unique[key]
        local position = Add(candidate.pillar.position, Scale(candidate.direction, targetDistance))
        local marker = NewMarker("PillarPlacement", position, candidate.direction, {
            placement_owner_type = candidate.owner.type,
            placement_owner_id = candidate.owner.id,
            placement_ground_count = #candidate.owner.indices,
            placement_source_pillar = candidate.pillarIndex - 1,
            placement_source_position = candidate.sourcePosition,
            placement_pillar_position = candidate.pillar.position,
            placement_direction = candidate.direction,
            placement_distance = targetDistance, marker_angle = 0,
        })
        marker.orient = OrientPillarPlacement(candidate.direction)
        result[#result + 1] = marker
    end
    return result
end

local function BuildPillarWebs(separators, grounds, cellSize)
    local result = {}
    for index, pillar in ipairs(separators) do
        local adjacent = AdjacentGrounds(pillar, grounds, cellSize, true)
        if #adjacent == 1 then
            local ground = grounds[adjacent[1]]
            local direction = Normalize(Horizontal(Sub(ground.position, pillar.position)))
            local position = Add(pillar.position, Scale(direction, 1.2))
            local scale = 2 + StableFraction(index - 1, 404)
            local marker = NewMarker("PillarWebPlacement", position, direction, {
                scale = V(scale, scale, scale), adjacent_ground_count = 1,
                source_ground_point = adjacent[1] - 1,
                source_ground_cell_type = ground.attributes.source_cell_type,
                source_pillar_position = pillar.position,
                source_ground_position = ground.position, web_direction = direction,
                web_offset_cm = 120, web_uniform_scale = scale, marker_angle = 0,
            })
            marker.orient = OrientLocalX(direction)
            result[#result + 1] = marker
        end
    end
    return result
end

local function BuildCurbstones(walls, cells, cellSize)
    local result, half, epsilon = {}, cellSize * 0.5, cellSize * 0.01
    for wallIndex, wall in ipairs(walls) do
        for _, cell in ipairs(cells) do
            if cell.cell_type == 1 or cell.cell_type == 2 then
                local delta = Sub(cell.position, wall.position)
                local sameLevel = math.abs(delta[2] - half) <= epsilon
                local cardinal = (math.abs(math.abs(delta[1]) - half) <= epsilon and math.abs(delta[3]) <= epsilon)
                    or (math.abs(math.abs(delta[3]) - half) <= epsilon and math.abs(delta[1]) <= epsilon)
                if sameLevel and cardinal then
                    local toward = Normalize(Horizontal(delta))
                    local facing = Scale(toward, -1)
                    local marker = NewMarker("Curbstone01Placement", wall.position, facing, {
                        marker_size = V(cellSize, cellSize, cellSize), marker_angle = AngleDegrees(facing),
                        source_wall_point = wallIndex - 1,
                        source_wall_cell_type = wall.attributes.source_cell_type,
                        source_cell = cell.id, source_cell_type = cell.cell_type,
                        source_room_id = cell.room_id, curbstone_facing_direction = facing,
                    })
                    marker.orient = OrientLocalX(facing)
                    result[#result + 1] = marker
                end
            end
        end
    end
    return result
end

local function Quad(center, normal, half)
    local up = V(0, 1, 0)
    if math.abs(normal[2]) > 0.5 then
        return {
            Add(center, V(-half, 0, -half)), Add(center, V(half, 0, -half)),
            Add(center, V(half, 0, half)), Add(center, V(-half, 0, half)),
        }
    end
    local tangent = Normalize(Cross(up, normal))
    return {
        Add(center, Add(Scale(tangent, -half), Scale(up, -half))),
        Add(center, Add(Scale(tangent, half), Scale(up, -half))),
        Add(center, Add(Scale(tangent, half), Scale(up, half))),
        Add(center, Add(Scale(tangent, -half), Scale(up, half))),
    }
end

local function BuildFaces(cells, doors, walls, cellSize)
    local byPosition = CellMaps(cells)
    local result, half = {}, cellSize * 0.5
    local function emit(boundaryType, center, normal, ownerCell, neighborCell)
        result[#result + 1] = {
            boundary_type = boundaryType, center = CopyV(center), normal = CopyV(normal),
            owner_cell = ownerCell and ownerCell.id or -1,
            neighbor_cell = neighborCell and neighborCell.id or -1,
            room_id = ownerCell and ownerCell.room_id or -1,
            vertices = Quad(center, normal, half),
        }
    end
    for _, cell in ipairs(cells) do
        local below = FindCell(byPosition, Add(cell.position, V(0, -cellSize, 0)))
        local above = FindCell(byPosition, Add(cell.position, V(0, cellSize, 0)))
        if not below and (cell.cell_type == 1 or cell.cell_type == 2) then
            emit(0, Add(cell.position, V(0, -half, 0)), V(0, -1, 0), cell, nil)
        end
        if not above then emit(3, Add(cell.position, V(0, half, 0)), V(0, 1, 0), cell, nil) end
    end
    for _, door in ipairs(doors) do
        local normal = Normalize(Horizontal(door.normal))
        local center = Add(door.position, V(0, half, 0))
        local owner = FindCell(byPosition, Add(center, Scale(normal, -half)))
        local neighbor = FindCell(byPosition, Add(center, Scale(normal, half)))
        if owner and owner.cell_type ~= 1 and neighbor and neighbor.cell_type == 1 then
            owner, neighbor, normal = neighbor, owner, Scale(normal, -1)
        end
        emit(2, center, normal, owner, neighbor)
    end
    for _, wall in ipairs(walls) do
        local center = Add(wall.position, V(0, half, 0))
        local owner = FindCell(byPosition, Add(center, Scale(wall.normal, -half)))
        local neighbor = FindCell(byPosition, Add(center, Scale(wall.normal, half)))
        emit(1, center, wall.normal, owner, neighbor)
    end
    return result
end

local function Append(target, source)
    for _, value in ipairs(source) do target[#target + 1] = value end
end

local function CountMarkers(markers)
    local counts = {}
    for _, name in ipairs(HoudiniMarkerPipeline.MARKER_TYPES) do counts[name] = 0 end
    for _, marker in ipairs(markers) do counts[marker.name] = (counts[marker.name] or 0) + 1 end
    return counts
end

function HoudiniMarkerPipeline.GenerateFromTopology(input, options)
    options = options or {}
    local cells, doors = input.cells or {}, input.doors or {}
    local cellSize = tonumber(options.cellSize) or 5
    local stairPairs = PairStairCells(cells, cellSize)
    local stairTopologyValid, stairTopologyErrors = ValidateStairPairs(cells, stairPairs, cellSize)
    local ground = BuildGround(cells, cellSize)
    local walls = BuildWalls(cells, doors, stairPairs, cellSize)
    local doorMarkers = BuildDoors(doors, cellSize)
    local stairs = BuildStairs(stairPairs, cellSize)
    local ceil = BuildCeil(cells, cellSize)
    local lights = BuildCellLights(cells, cellSize)
    local separators = BuildWallSeparators(walls, cellSize)
    local ambient = BuildAmbientLights(cells, doorMarkers, stairs, input.reference_ambient, cellSize)
    local doorLights = BuildDoorLights(doorMarkers, cells, cellSize)
    local stairLights = BuildStairLights(stairs, cellSize)
    local heroLights = BuildHeroLights(cells)
    local pillarDistance = tonumber(options.pillarPlacementDistance) or 1.2
    local pillarPlacements = BuildPillarPlacements(separators, ground, cellSize, pillarDistance,
        input.reference_pillar_sources)
    local pillarWebs = BuildPillarWebs(separators, ground, cellSize)
    local curbstones = BuildCurbstones(walls, cells, cellSize)
    local markers = {}
    for _, branch in ipairs({ ground, walls, doorMarkers, separators, stairs, ceil, lights,
        ambient, doorLights, stairLights, heroLights, pillarPlacements, pillarWebs, curbstones }) do
        Append(markers, branch)
    end
    for index, marker in ipairs(markers) do
        marker.marker_id = index - 1
        marker.global_marker_id = string.format("%s_%d_%d_%d_%d", marker.name,
            Round(marker.position[1] * 1000), Round(marker.position[2] * 1000),
            Round(marker.position[3] * 1000), index - 1)
    end
    local faces = BuildFaces(cells, doorMarkers, walls, cellSize)
    return {
        schemaVersion = HoudiniMarkerPipeline.SCHEMA_VERSION,
        markers = markers, faces = faces, counts = CountMarkers(markers),
        cellCount = #cells, stairCount = #stairPairs,
        stairTopologyValid = stairTopologyValid,
        stairTopologyErrors = stairTopologyErrors,
        branches = {
            ground = ground, walls = walls, doors = doorMarkers, separators = separators,
            stairs = stairs, ceil = ceil, lights = lights,
        },
    }
end

local function FaceKey(face)
    local corners = {}
    for _, point in ipairs(face.vertices) do
        corners[#corners + 1] = string.format("%d,%d,%d", Round(point[1] * 1000),
            Round(point[2] * 1000), Round(point[3] * 1000))
    end
    table.sort(corners)
    return tostring(face.boundary_type) .. "|" .. table.concat(corners, ";")
end

local function SortedMarkerKeys(markers)
    local result = {}
    for _, marker in ipairs(markers) do result[#result + 1] = MarkerKey(marker) end
    table.sort(result)
    return result
end

local function SortedFaceKeys(faces)
    local result = {}
    for _, face in ipairs(faces) do result[#result + 1] = FaceKey(face) end
    table.sort(result)
    return result
end

local function CompareKeys(label, actual, expected, errors)
    if #actual ~= #expected then
        errors[#errors + 1] = string.format("%s count: expected %d, got %d", label, #expected, #actual)
        return
    end
    for index = 1, #expected do
        if actual[index] ~= expected[index] then
            local actualCounts, expectedCounts = {}, {}
            for _, key in ipairs(actual) do actualCounts[key] = (actualCounts[key] or 0) + 1 end
            for _, key in ipairs(expected) do expectedCounts[key] = (expectedCounts[key] or 0) + 1 end
            local missing, extra = nil, nil
            for _, key in ipairs(expected) do
                if (actualCounts[key] or 0) < (expectedCounts[key] or 0) then missing = key; break end
            end
            for _, key in ipairs(actual) do
                if (expectedCounts[key] or 0) < (actualCounts[key] or 0) then extra = key; break end
            end
            errors[#errors + 1] = string.format(
                "%s mismatch #%d: missing %s, extra %s",
                label, index, tostring(missing), tostring(extra))
            return
        end
    end
end

function HoudiniMarkerPipeline.Validate(result, expected)
    local errors = {}
    if result.schemaVersion ~= (expected.marker_schema_version or HoudiniMarkerPipeline.SCHEMA_VERSION) then
        errors[#errors + 1] = "marker schema version mismatch"
    end
    for _, name in ipairs(HoudiniMarkerPipeline.MARKER_TYPES) do
        local actualCount = result.counts[name] or 0
        local expectedCount = (expected.marker_counts or {})[name] or 0
        if actualCount ~= expectedCount then
            errors[#errors + 1] = string.format("%s count: expected %d, got %d",
                name, expectedCount, actualCount)
        end
    end
    if expected.marker_keys then
        local actualByType, expectedByType = {}, {}
        for _, name in ipairs(HoudiniMarkerPipeline.MARKER_TYPES) do
            actualByType[name], expectedByType[name] = {}, {}
        end
        for _, marker in ipairs(result.markers) do
            actualByType[marker.name][#actualByType[marker.name] + 1] = MarkerKey(marker)
        end
        for _, key in ipairs(expected.marker_keys) do
            local name = key:match("^([^|]+)")
            if expectedByType[name] then expectedByType[name][#expectedByType[name] + 1] = key end
        end
        for _, name in ipairs(HoudiniMarkerPipeline.MARKER_TYPES) do
            table.sort(actualByType[name]); table.sort(expectedByType[name])
            CompareKeys(name .. " key", actualByType[name], expectedByType[name], errors)
        end
    end
    if expected.face_keys then
        CompareKeys("face key", SortedFaceKeys(result.faces), expected.face_keys, errors)
    elseif expected.face_count and #result.faces ~= expected.face_count then
        errors[#errors + 1] = string.format("face count: expected %d, got %d",
            expected.face_count, #result.faces)
    end
    return #errors == 0, {
        errors = errors, markerCount = #result.markers, faceCount = #result.faces,
        markerTypeCount = #HoudiniMarkerPipeline.MARKER_TYPES, counts = result.counts,
    }
end

function HoudiniMarkerPipeline.LoadFixture()
    local candidates = {
        "assets/BgeoDungeon/HoudiniMarkerFixture.json",
        "BgeoDungeon/HoudiniMarkerFixture.json",
    }
    for _, path in ipairs(candidates) do
        if cache:Exists(path) then
            local file = cache:GetFile(path)
            if not file then return nil, "fixture could not be opened: " .. path end
            local raw = file:ReadString(); file:Close()
            local ok, value = pcall(cjson.decode, raw)
            if ok and type(value) == "table" then return value, path end
            return nil, "fixture JSON is invalid: " .. path
        end
    end
    return nil, "HoudiniMarkerFixture.json was not found"
end

function HoudiniMarkerPipeline.RunReferenceValidation()
    local fixture, pathOrError = HoudiniMarkerPipeline.LoadFixture()
    if not fixture then return false, { errors = { pathOrError } } end
    local result = HoudiniMarkerPipeline.GenerateFromTopology(fixture.input, {
        cellSize = fixture.source.cell_size,
        pillarPlacementDistance = fixture.source.pillar_placement_distance,
    })
    local valid, report = HoudiniMarkerPipeline.Validate(result, fixture.expected)
    report.fixturePath, report.result = pathOrError, result
    return valid, report
end

local function GridIndex(x, y, width) return y * width + x + 1 end

function HoudiniMarkerPipeline.TopologyFromDungeon(dungeon, overrides)
    overrides = overrides or {}
    local cellSize = tonumber(overrides.cellSize)
        or (dungeon.sceneInfo and dungeon.sceneInfo.cellSize) or 1
    local floorHeight = tonumber(overrides.floorHeight) or dungeon.floorHeight or 5
    local cells, byGrid, nextId = {}, {}, 0
    local function position(x, y, floor)
        return V((x - dungeon.width * 0.5 + 0.5) * cellSize,
            floor * floorHeight + cellSize * 0.5,
            (y - dungeon.height * 0.5 + 0.5) * cellSize)
    end
    local function addCell(x, y, floor, cellType, roomId, stairwellId, role, connectionId)
        local key = floor .. "|" .. x .. "|" .. y
        local cell = byGrid[key]
        if not cell then
            cell = { id = nextId, grid_index = nextId, grid_coord = { x, floor, y },
                position = position(x, y, floor) }
            nextId = nextId + 1; cells[#cells + 1], byGrid[key] = cell, cell
        end
        cell.cell_type, cell.room_id = cellType, roomId or -1
        cell.floor_id, cell.stairwell_id = floor, stairwellId or -1
        cell.stair_role, cell.connection_id = role or -1, connectionId or -1
        return cell
    end
    for _, layer in ipairs(dungeon.layers or {}) do
        for y = 0, dungeon.height - 1 do
            for x = 0, dungeon.width - 1 do
                local index = GridIndex(x, y, dungeon.width)
                if layer.grid[index] == 1 then
                    local roomId = layer.roomId[index] or 0
                    addCell(x, y, layer.floor, roomId > 0 and 1 or 2, roomId > 0 and roomId or -1)
                end
            end
        end
    end
    for _, connector in ipairs(dungeon.connectors or {}) do
        local direction = connector.directionVector or { x = 1, y = 0 }
        for role = 0, 1 do
            addCell(connector.lower.x + direction.x * role,
                connector.lower.y + direction.y * role, connector.fromFloor,
                3, -1, connector.id - 1, role, connector.edgeId or connector.id)
            addCell(connector.lower.x + direction.x * role,
                connector.lower.y + direction.y * role, connector.toFloor,
                4, -1, connector.id - 1, role + 2, connector.edgeId or connector.id)
        end
    end
    local doors = {}
    local sideNormal = {
        east = V(1, 0, 0), west = V(-1, 0, 0),
        south = V(0, 0, 1), north = V(0, 0, -1),
    }
    for _, layer in ipairs(dungeon.layers or {}) do
        for _, arch in ipairs(layer.arches or {}) do
            local normal = sideNormal[arch.side] or V(0, 0, 1)
            local center = position(arch.x, arch.y, layer.floor)
            center = Add(center, Scale(normal, cellSize * 0.5))
            center[2] = layer.floor * floorHeight
            doors[#doors + 1] = { position = center, normal = normal,
                source_room_id = arch.roomId or -1, source_cell_type = 1 }
        end
    end
    return { cells = cells, doors = doors }, { cellSize = cellSize,
        pillarPlacementDistance = tonumber(overrides.pillarPlacementDistance)
            or math.min(1.2, cellSize * 0.24) }
end

function HoudiniMarkerPipeline.GenerateFromDungeon(dungeon, overrides)
    local topology, options = HoudiniMarkerPipeline.TopologyFromDungeon(dungeon, overrides)
    return HoudiniMarkerPipeline.GenerateFromTopology(topology, options)
end

return HoudiniMarkerPipeline
