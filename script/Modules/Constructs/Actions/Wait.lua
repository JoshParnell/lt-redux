local Action = require("Modules.Constructs.Actions.Action")

--- Do nothing for a number of seconds of game time.
---@class WaitAction: Action
---@overload fun(seconds: number): WaitAction
local Wait = Subclass("Wait", Action, function(self, seconds)
    self.remaining = seconds
end)

function Wait:getName()
    return format("Wait %.1fs", self.remaining)
end

function Wait:onUpdateActive(e, dt)
    self.remaining = self.remaining - dt
    if self.remaining <= 0 then self:finish(e) end
end

return Wait
