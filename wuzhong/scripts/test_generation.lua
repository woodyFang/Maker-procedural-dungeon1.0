local GenerationTests = require("Tests.GenerationTests")

function Start()
    local ok, err = xpcall(function()
        GenerationTests.Run()
    end, debug.traceback)
    if not ok then
        ErrorExit("[test] FAIL\n" .. tostring(err), 1)
        return
    end
    engine:Exit()
end
