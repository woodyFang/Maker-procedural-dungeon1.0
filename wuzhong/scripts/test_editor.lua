local EditorTests = require("Tests.EditorTests")

function Start()
    local ok, message = xpcall(EditorTests.Run, debug.traceback)
    if not ok then
        ErrorExit("[test] FAIL\n" .. tostring(message), 1)
        return
    end
    engine:Exit()
end
