local Random = {}
Random.__index = Random

local UINT32_MASK = 0xffffffff
local UINT32_SCALE = 4294967296.0

local function U32(value)
    return value & UINT32_MASK
end

local function IMul32(a, b)
    return U32(U32(a) * U32(b))
end

function Random.new(seed)
    return setmetatable({ state = U32(seed or 0) }, Random)
end

function Random:Raw()
    local a = U32(self.state + 0x6D2B79F5)
    self.state = a
    local t = IMul32(a ~ (a >> 15), 1 | a)
    t = U32((t + IMul32(t ~ (t >> 7), 61 | t)) ~ t)
    return U32(t ~ (t >> 14)) / UINT32_SCALE
end

function Random:Float(minValue, maxValue)
    return minValue + self:Raw() * (maxValue - minValue)
end

function Random:Int(minValue, maxValue)
    return minValue + math.floor(self:Raw() * (maxValue - minValue + 1))
end

function Random:Chance(probability)
    return self:Raw() < probability
end

function Random:Pick(values)
    if #values == 0 then return nil end
    return values[self:Int(1, #values)]
end

function Random:Gaussian(mean, deviation)
    local u = 0
    local v = 0
    while u == 0 do u = self:Raw() end
    while v == 0 do v = self:Raw() end
    return mean + deviation * math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v)
end

function Random:Shuffle(values)
    for i = #values, 2, -1 do
        local j = self:Int(1, i)
        values[i], values[j] = values[j], values[i]
    end
    return values
end

function Random.U32(value)
    return U32(value)
end

function Random.IMul32(a, b)
    return IMul32(a, b)
end

return Random
