local Component = require("Core.ECS.Component")

--- The stack of actions an entity carries out; ActionSystem runs the top one.
---@class ActionsComponent: Component
---@overload fun(): ActionsComponent
local ActionsComponent = Subclass("ActionsComponent", Component, function(self)
    self:setComponentName("Actions")

    ---@type Action[] bottom first
    self.stack  = {}
    ---@type Action|nil the action that was on top last update
    self.active = nil
end)

return ActionsComponent
