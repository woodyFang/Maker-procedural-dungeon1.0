local HoudiniCoordinateSystem = {}

local function Value(values, index, fallback)
    local value = values and values[index]
    return value == nil and fallback or value
end

local function YawQuaternion(radians)
    return { 0, math.sin(radians * 0.5), 0, math.cos(radians * 0.5) }
end

local function MultiplyQuaternion(a, b)
    local ax, ay, az, aw = Value(a, 1, 0), Value(a, 2, 0), Value(a, 3, 0), Value(a, 4, 1)
    local bx, by, bz, bw = Value(b, 1, 0), Value(b, 2, 0), Value(b, 3, 0), Value(b, 4, 1)
    return {
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    }
end

function HoudiniCoordinateSystem.OrientLocalX(direction)
    return YawQuaternion(math.atan(-Value(direction, 3, 0), Value(direction, 1, 0)))
end

function HoudiniCoordinateSystem.OrientLocalForward(direction)
    return YawQuaternion(math.atan(Value(direction, 1, 0), Value(direction, 3, 0)))
end

function HoudiniCoordinateSystem.OrientPillarPlacement(direction)
    -- The source wrangle passes an atan2 result through radians() again. Preserve it
    -- because attached brazier placement observes this transport Marker orientation.
    local sourceRadians = math.atan(-Value(direction, 3, 0), Value(direction, 1, 0))
    return YawQuaternion(math.rad(sourceRadians))
end

function HoudiniCoordinateSystem.ApplyMarkerYawOffset(orient, degrees)
    if not degrees or math.abs(degrees) < 0.00000001 then
        return {
            Value(orient, 1, 0), Value(orient, 2, 0),
            Value(orient, 3, 0), Value(orient, 4, 1),
        }
    end
    return MultiplyQuaternion(orient, YawQuaternion(math.rad(degrees)))
end

function HoudiniCoordinateSystem.RotateHoudiniVector(orient, vector)
    local qx, qy, qz, qw = Value(orient, 1, 0), Value(orient, 2, 0),
        Value(orient, 3, 0), Value(orient, 4, 1)
    local vx, vy, vz = Value(vector, 1, 0), Value(vector, 2, 0), Value(vector, 3, 0)
    local tx = 2 * (qy * vz - qz * vy)
    local ty = 2 * (qz * vx - qx * vz)
    local tz = 2 * (qx * vy - qy * vx)
    return {
        vx + qw * tx + qy * tz - qz * ty,
        vy + qw * ty + qz * tx - qx * tz,
        vz + qw * tz + qx * ty - qy * tx,
    }
end

function HoudiniCoordinateSystem.PackMarkerTransform(marker, markerYawOffsetDegrees)
    local position = marker.position or { 0, 0, 0 }
    local orient = HoudiniCoordinateSystem.ApplyMarkerYawOffset(
        marker.orient or { 0, 0, 0, 1 }, markerYawOffsetDegrees)
    local scale = marker.scale or { 1, 1, 1 }
    local pscale = tonumber(marker.pscale) or 1
    -- The Y/Z swap changes handedness, so quaternion vector components transform
    -- as an axial vector: det(S) * S rather than the position-vector permutation.
    return {
        Value(position, 1, 0) * 100,
        Value(position, 3, 0) * 100,
        Value(position, 2, 0) * 100,
        -Value(orient, 1, 0),
        -Value(orient, 3, 0),
        -Value(orient, 2, 0),
        Value(orient, 4, 1),
        Value(scale, 1, 1) * pscale,
        Value(scale, 3, 1) * pscale,
        Value(scale, 2, 1) * pscale,
    }
end

function HoudiniCoordinateSystem.UEVectorToUrho(values, scale)
    scale = scale or 1
    return Vector3(Value(values, 2, 0) * scale, Value(values, 3, 0) * scale,
        Value(values, 1, 0) * scale)
end

function HoudiniCoordinateSystem.PackedPositionToUrho(values)
    return HoudiniCoordinateSystem.UEVectorToUrho(values, 0.01)
end

function HoudiniCoordinateSystem.PackedScaleToUrho(values)
    return Vector3(Value(values, 2, 1), Value(values, 3, 1), Value(values, 1, 1))
end

function HoudiniCoordinateSystem.PackedTransformScaleToUrho(values)
    return Vector3(Value(values, 9, 1), Value(values, 10, 1), Value(values, 8, 1))
end

function HoudiniCoordinateSystem.PackedQuaternionToUrho(values)
    return Quaternion(Value(values, 7, 1), Value(values, 5, 0),
        Value(values, 6, 0), Value(values, 4, 0))
end

function HoudiniCoordinateSystem.UERotatorToUrho(rotation)
    -- UE pitch/yaw/roll axes Y/Z/X map to UrhoX X/Y/Z. The cyclic
    -- UE-to-Urho permutation preserves handedness, so angle signs stay unchanged.
    return Quaternion(Value(rotation, 1, 0), Value(rotation, 2, 0), Value(rotation, 3, 0))
end

function HoudiniCoordinateSystem.UEScatterRotation(normal, localUpAxis, yawDegrees, alignToNormal)
    local localUp = HoudiniCoordinateSystem.UEVectorToUrho(localUpAxis or { 0, 0, 1 }, 1)
    if localUp:LengthSquared() < 0.00000001 then localUp = Vector3.UP else localUp = localUp:Normalized() end
    local yaw = Quaternion(yawDegrees or 0, localUp)
    if not alignToNormal then return yaw end

    local targetUp = HoudiniCoordinateSystem.UEVectorToUrho(normal or { 0, 0, 1 }, 1)
    if targetUp:LengthSquared() < 0.00000001 then return yaw end
    targetUp = targetUp:Normalized()
    local alignment = Quaternion()
    alignment:FromRotationTo(localUp, targetUp)
    return alignment * yaw
end

return HoudiniCoordinateSystem
