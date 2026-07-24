-- Runtime smoke: preview stair surfaces must move the character vertically and
-- switch floors only at the stair endpoints. Uses the controller's public
-- movement/query methods so the check does not depend on keyboard timing.
local DungeonApp = require("App.DungeonApp")

---@type table|nil
local app = nil
local elapsed = 0
local resultPath = ".tmp/preview-stairs.result.txt"

local function WriteResult(message)
    local result = File(resultPath, FILE_WRITE)
    if result and result:IsOpen() then result:WriteLine(message); result:Close() end
end

local function Fail(message)
    UnsubscribeFromEvent("Update")
    WriteResult("FAIL " .. tostring(message))
    ErrorExit("[preview-stairs] FAIL\n" .. tostring(message), 1)
end

local function WorldForCell(preview, floor, cell, width)
    local zero = cell - 1
    return preview:WorldAt(zero % width, math.floor(zero / width), floor, 0)
end

local function CheckStairTraversal()
    local dungeon, preview = app.dungeon, app.preview
    local connector = dungeon and dungeon.connectors and dungeon.connectors[1]
    if not connector then return false, "generated dungeon has no stair connector" end

    local topItem, openingItem
    local itemByCell = {}
    for _, item in ipairs(connector.sweptClearanceCells or {}) do
        itemByCell[item.cell] = item
        if not topItem or item.treadElevation > topItem.treadElevation then topItem = item end
    end
    for _, cell in ipairs(connector.openingCells or {}) do
        local item = itemByCell[cell]
        if item and (not openingItem or item.treadElevation > openingItem.treadElevation) then
            openingItem = item
        end
    end
    if not topItem or not openingItem then return false, "stair contract has no top/opening tread" end

    preview:SetFloor(connector.fromFloor)
    local topWorld = WorldForCell(preview, connector.fromFloor, topItem.cell, dungeon.width)
    local valid, targetY, targetFloor = preview:EvaluatePosition(topWorld.x, topWorld.z)
    if not valid or targetFloor ~= connector.toFloor then
        return false, "top stair tread did not resolve to the upper floor"
    end
    local upperBase = preview:WorldAt(connector.upper.x, connector.upper.y, connector.toFloor, 0).y
    if math.abs(targetY - upperBase) > 0.01 then
        return false, string.format("upper transition Y mismatch: %.3f <> %.3f", targetY, upperBase)
    end

    preview.character.position = topWorld
    preview:TryMoveTo(topWorld.x, topWorld.z)
    if preview.floor ~= connector.toFloor or app.currentFloor ~= connector.toFloor then
        return false, "top stair transition did not update the active floor"
    end

    local openingWorld = WorldForCell(preview, connector.toFloor, openingItem.cell, dungeon.width)
    local downValid, downY, downFloor = preview:EvaluatePosition(openingWorld.x, openingWorld.z)
    if not downValid or downFloor ~= connector.fromFloor then
        return false, "upper slab opening did not resolve to a stair descent"
    end
    if downY >= upperBase - 0.01 then
        return false, "stair descent kept the upper-floor height"
    end
    return true, string.format("connector=%s topY=%.2f downY=%.2f", tostring(connector.id), targetY, downY)
end

function Start()
    local ok, message = xpcall(function()
        app = DungeonApp.new()
        app.seed = 15838
        app.floorCount = 3
        app.roomCounts = { 10, 10, 10 }
        app.loopRates = { 12, 16, 20 }
        app:Start()
        SubscribeToEvent("Update", "HandlePreviewStairSmoke")
    end, debug.traceback)
    if not ok then Fail(message) end
end

---@param eventType string
---@param eventData UpdateEventData
function HandlePreviewStairSmoke(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed > 18 then Fail("preview stair smoke timed out") end
    if not app.preview:IsActive() then
        if not app.forgeCamera:IsTransitioning() then app:ActivatePreview("third") end
        return
    end
    if app.preview.phase ~= "active" then return end

    local ok, message = CheckStairTraversal()
    if not ok then Fail(message) end
    WriteResult("PASS " .. message)
    print("[preview-stairs] PASS " .. message)
    UnsubscribeFromEvent("Update")
    engine:Exit()
end

function Stop()
    if app then app:Stop(); app = nil end
end
