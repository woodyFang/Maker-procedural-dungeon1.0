local EditorInteraction = {}
EditorInteraction.__index = EditorInteraction

function EditorInteraction.new()
    return setmetatable({ captured = false, serial = 0, previousLeftDown = false }, EditorInteraction)
end

function EditorInteraction:Sample(leftDown, pressedEdge, releasedEdge)
    leftDown = leftDown == true
    local pressed = leftDown and (pressedEdge == true or not self.previousLeftDown)
    local released = not leftDown and (releasedEdge == true or self.previousLeftDown)
    self.previousLeftDown = leftDown
    return pressed, released
end

function EditorInteraction:Capture()
    if self.captured then return self.serial end
    self.serial = self.serial + 1
    self.captured = true
    return self.serial
end

function EditorInteraction:Release()
    self.captured = false
end

function EditorInteraction:Reset(leftDown)
    self.captured = false
    self.previousLeftDown = leftDown == true
end

function EditorInteraction:IsCaptured()
    return self.captured
end

return EditorInteraction
