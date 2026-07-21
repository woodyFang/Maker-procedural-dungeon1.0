local VexRandom = {}

local UINT32_MASK = 0xffffffff
local MANTISSA_MASK = 0x007fffff
local MANTISSA_SCALE = 8388608.0

local function U32(value)
    return math.floor(value) & UINT32_MASK
end

local function F32(value)
    return string.unpack("<f", string.pack("<f", tonumber(value) or 0))
end

local function WangHash(key)
    key = U32(key + U32(~U32(key << 16)))
    key = U32(key ~ (key >> 5))
    key = U32(key + U32(key << 3))
    key = U32(key ~ (key >> 13))
    key = U32(key + U32(~U32(key << 9)))
    key = U32(key ~ (key >> 17))
    return key
end

function VexRandom.Float32(value)
    return F32(value)
end

function VexRandom.Affine(base, index, multiplier)
    return F32(F32(base) + F32(F32(index) * F32(multiplier)))
end

function VexRandom.Rand(value)
    local bits = string.unpack("<I4", string.pack("<f", tonumber(value) or 0))
    local hash = WangHash(WangHash(bits))
    hash = U32(hash * 1664525 + 1013904223)
    return (hash & MANTISSA_MASK) / MANTISSA_SCALE
end

function VexRandom.RandomInt(value, minimum, maximum)
    local count = math.max(1, maximum - minimum + 1)
    return math.min(maximum, minimum + math.floor(VexRandom.Rand(value) * count))
end

VexRandom.U32 = U32
VexRandom.WangHash = WangHash

return VexRandom
