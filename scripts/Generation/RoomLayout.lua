-- Generic room-interior layout patterns.
--
-- The ruins theme's "structural richness" -- pillar arrays, brazier rings,
-- grave fields, centre focal props -- is a set of theme-agnostic LAYOUT
-- MECHANISMS. What differs per theme is only the prop. This module owns the
-- mechanisms; the prop kind is always supplied by the caller (theme DATA), so
-- a classroom lays desks in a `grid` exactly the way ruins lay pillars.
--
-- Every layout receives:
--   room  : room record (cx, cy, w, h, and optional feature flags)
--   rng   : the floor decoration RNG stream
--   spec  : the rule/spec table (kind, count, chance, scaleMin/Max, layout params)
--   place : { at = AddPropAt(room,kind,x,y,rot,scale)->bool,
--             prop = AddProp(room,kind,opts)->pos|false }
-- Placement always goes through the caller's helpers, so doorway / corridor /
-- lake / occupied / interior validity is still enforced -- a layout can only
-- choose target cells, never bypass placement rules.
--
-- NOTE: `scatter` (the legacy random placement) is intentionally NOT here; the
-- decorator keeps that inline so no-layout rules stay byte-identical. This
-- module only provides the opt-in structured layouts.

local RoomLayout = {}

local function Bounds(room, margin)
    margin = margin or 2
    return math.ceil(room.cx - room.w * 0.5) + margin,
        math.floor(room.cx + room.w * 0.5) - margin,
        math.ceil(room.cy - room.h * 0.5) + margin,
        math.floor(room.cy + room.h * 0.5) - margin
end

local function Scale(rng, spec)
    return rng:Float(spec.scaleMin or 0.92, spec.scaleMax or (spec.scaleMin or 1.0))
end

-- Aligned rows. Ideal for seating/desks that should face one direction.
-- spec: step | rowStep/colStep, margin, rot (uniform facing), max (optional cap).
-- Fills by geometry; `count` from Rule() is ignored here (that is a scatter concept).
--
-- `centered = true` switches to a centre-anchored modulo lattice (pillar arrays):
-- it walks every cell and keeps those on the `step` grid measured from the room
-- centre, optionally skipping the exact centre. `stepThreshold`/`stepBig`/
-- `stepSmall` pick the step from the room's short side.
function RoomLayout.grid(room, rng, spec, place)
    local x0, x1, y0, y1 = Bounds(room, spec.margin)
    local rot = spec.rot or 0
    if spec.centered then
        local step = spec.step
        if not step and spec.stepThreshold then
            step = math.min(room.w, room.h) >= spec.stepThreshold and spec.stepBig or spec.stepSmall
        end
        step = step or 3
        for y = y0, y1 do
            for x = x0, x1 do
                if (x - room.cx) % step == 0 and (y - room.cy) % step == 0
                    and (not spec.skipCenter or x ~= room.cx or y ~= room.cy) then
                    place.at(room, spec.kind, x, y, rot, Scale(rng, spec))
                end
            end
        end
        return
    end
    local rowStep = spec.rowStep or spec.step or 2
    local colStep = spec.colStep or spec.step or 2
    local cap, placed = spec.max, 0
    for y = y0, y1, rowStep do
        for x = x0, x1, colStep do
            if cap and placed >= cap then return placed end
            local s = Scale(rng, spec)
            if place.at(room, spec.kind, x, y, rot, s) then placed = placed + 1 end
        end
    end
    return placed
end

-- Props hugging the inner wall ring, facing inward. Lockers, shelves, benches.
function RoomLayout.perimeter(room, rng, spec, place)
    local x0, x1, y0, y1 = Bounds(room, spec.margin)
    local step = spec.step or 2
    local cells = {}
    for x = x0, x1, step do
        cells[#cells + 1] = { x, y0, 0 }
        if y1 > y0 then cells[#cells + 1] = { x, y1, math.pi } end
    end
    for y = y0 + step, y1 - step, step do
        cells[#cells + 1] = { x0, y, math.pi * 0.5 }
        if x1 > x0 then cells[#cells + 1] = { x1, y, -math.pi * 0.5 } end
    end
    local cap, placed = spec.max, 0
    for _, c in ipairs(cells) do
        if cap and placed >= cap then break end
        local s = Scale(rng, spec)
        if place.at(room, spec.kind, c[1], c[2], spec.rot or c[3], s) then placed = placed + 1 end
    end
    return placed
end

-- N props evenly around the room centre, optional focal anchor at the middle.
function RoomLayout.ring(room, rng, spec, place)
    if spec.anchor then place.prop(room, spec.anchor, { scale = spec.anchorScale or 1 }) end
    local count = spec.count or 6
    local radius = spec.radius or math.max(2.5, math.min(room.w, room.h) * 0.5 - 2)
    local angle0 = spec.angleJitter == false and 0 or rng:Float(0, spec.angleSpan or math.pi * 2)
    for i = 0, count - 1 do
        local angle = angle0 + i * (2 * math.pi / count)
        local x = math.floor(room.cx + math.cos(angle) * radius + 0.5)
        local y = math.floor(room.cy + math.sin(angle) * radius + 0.5)
        local s = spec.scaleMin and Scale(rng, spec) or 1
        place.at(room, spec.kind, x, y, spec.rot or 0, s)
    end
end

-- Dense sub-grid fill with a per-cell chance. Grave fields, crop rows, seating.
-- Optional `anchor` prop dropped at the centre (sarcophagus / altar / statue).
function RoomLayout.fill(room, rng, spec, place)
    local x0, x1, y0, y1 = Bounds(room, spec.margin)
    local step = spec.step or 2
    local chance = spec.chance == nil and 0.8 or spec.chance
    local jitter = spec.rotJitter or 0
    for y = y0, y1, step do
        for x = x0, x1, step do
            if (math.abs(x - room.cx) > 1 or math.abs(y - room.cy) > 1) and rng:Chance(chance) then
                local rot = jitter > 0 and rng:Float(-jitter, jitter) or (spec.rot or 0)
                place.at(room, spec.kind, x, y, rot, rng:Float(spec.scaleMin or 0.85, spec.scaleMax or 1.15))
            end
        end
    end
    if spec.anchor and math.min(room.w, room.h) >= (spec.anchorMinDim or 10) then
        local arot = spec.anchorRotAxis and (rng:Chance(0.5) and 0 or math.pi * 0.5) or (spec.anchorRot or 0)
        place.at(room, spec.anchor, room.cx, room.cy, arot, spec.anchorScale or 1)
    end
end

-- One (or a few) focal props near the room centre; reuses candidate placement.
function RoomLayout.focal(room, rng, spec, place)
    for _ = 1, spec.count or 1 do
        place.prop(room, spec.kind, {
            rot = spec.rot,
            scale = spec.scale or (spec.scaleMin and Scale(rng, spec)) or 1,
            tries = spec.tries or 60,
        })
    end
end

return RoomLayout
