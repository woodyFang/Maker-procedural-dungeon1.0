local Delaunay = {}

local function MakeTriangle(a, b, c)
    local d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
    local triangle = { a, b, c }
    if math.abs(d) < 1e-12 then
        triangle.ccx = 0
        triangle.ccy = 0
        triangle.r2 = math.huge
        return triangle
    end

    local a2 = a.x * a.x + a.y * a.y
    local b2 = b.x * b.x + b.y * b.y
    local c2 = c.x * c.x + c.y * c.y
    triangle.ccx = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
    triangle.ccy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
    local dx = a.x - triangle.ccx
    local dy = a.y - triangle.ccy
    triangle.r2 = dx * dx + dy * dy
    return triangle
end

local function EdgeKey(a, b)
    local ai = a.id
    local bi = b.id
    if ai > bi then ai, bi = bi, ai end
    return tostring(ai) .. ":" .. tostring(bi)
end

function Delaunay.Build(points)
    local count = #points
    if count < 2 then return {} end
    if count == 2 then return { { a = 1, b = 2 } } end

    local prepared = {}
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for i, point in ipairs(points) do
        local p = {
            x = point.x + (((i - 1) * 0.618033) % 1) * 1e-3,
            y = point.y + (((i - 1) * 0.414213) % 1) * 1e-3,
            id = i,
        }
        prepared[i] = p
        minX = math.min(minX, p.x)
        minY = math.min(minY, p.y)
        maxX = math.max(maxX, p.x)
        maxY = math.max(maxY, p.y)
    end

    local span = math.max(maxX - minX, maxY - minY, 1)
    local midX = (minX + maxX) * 0.5
    local midY = (minY + maxY) * 0.5
    local superA = { x = midX - 30 * span, y = midY - span, id = -1 }
    local superB = { x = midX, y = midY + 30 * span, id = -2 }
    local superC = { x = midX + 30 * span, y = midY - span, id = -3 }
    local triangles = { MakeTriangle(superA, superB, superC) }

    for _, point in ipairs(prepared) do
        local bad = {}
        local badSet = {}
        for _, triangle in ipairs(triangles) do
            local dx = point.x - triangle.ccx
            local dy = point.y - triangle.ccy
            if dx * dx + dy * dy < triangle.r2 then
                bad[#bad + 1] = triangle
                badSet[triangle] = true
            end
        end

        local edgeCounts = {}
        local edgeOrder = {}
        for _, triangle in ipairs(bad) do
            for edgeIndex = 1, 3 do
                local a = triangle[edgeIndex]
                local b = triangle[(edgeIndex % 3) + 1]
                local key = EdgeKey(a, b)
                if not edgeCounts[key] then
                    edgeCounts[key] = { count = 0, a = a, b = b }
                    edgeOrder[#edgeOrder + 1] = key
                end
                edgeCounts[key].count = edgeCounts[key].count + 1
            end
        end

        local kept = {}
        for _, triangle in ipairs(triangles) do
            if not badSet[triangle] then kept[#kept + 1] = triangle end
        end
        triangles = kept
        for _, key in ipairs(edgeOrder) do
            local edge = edgeCounts[key]
            if edge.count == 1 then
                triangles[#triangles + 1] = MakeTriangle(edge.a, edge.b, point)
            end
        end
    end

    local result = {}
    local seen = {}
    for _, triangle in ipairs(triangles) do
        if triangle[1].id > 0 and triangle[2].id > 0 and triangle[3].id > 0 then
            for edgeIndex = 1, 3 do
                local a = triangle[edgeIndex].id
                local b = triangle[(edgeIndex % 3) + 1].id
                if a > b then a, b = b, a end
                local key = tostring(a) .. ":" .. tostring(b)
                if not seen[key] then
                    seen[key] = true
                    result[#result + 1] = { a = a, b = b }
                end
            end
        end
    end
    return result
end

return Delaunay
