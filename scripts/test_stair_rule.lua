-- Standalone stair-rule regression tower entry. Builds the fixed 4-floor tower
-- (wall-hugging L / wide straight / open L) and checks the 12 named stair rules,
-- isolated from room/decor/combat quality. Run headless or in-engine.
local StairRuleMap = require("Tests.StairRuleMap")

local function RunStairRuleTower()
    local map = StairRuleMap.Create()
    local report = StairRuleMap.Evaluate(map)
    print(string.format("[stair-rule] tower valid=%s connectors=%d errors=%d audits=%d/%d",
        tostring(map.valid), #(map.connectors or {}), #(map.errors or {}),
        map.passedStairs or 0, map.totalStairs or 0))
    for _, err in ipairs(map.errors or {}) do print("[stair-rule]   ERROR: " .. tostring(err)) end
    for _, rule in ipairs(report.rules) do
        print(string.format("[stair-rule]   [%s] %-18s %s",
            rule.pass and "PASS" or "FAIL", rule.id, rule.detail or ""))
    end
    assert(report.pass, "[stair-rule] tower failed one or more named rules")
    print("[stair-rule] PASS: all 12 named rules")
    return report
end

StairRuleMap.RunStairRuleTower = RunStairRuleTower

function Start()
    local ok, err = xpcall(RunStairRuleTower, debug.traceback)
    if not ok then
        ErrorExit("[stair-rule] FAIL\n" .. tostring(err), 1)
        return
    end
    engine:Exit()
end

return { Run = RunStairRuleTower }
