local Component = require("Core.ECS.Component")

--- Present on a ship while it is parked inside a station
---@class DockedComponent: Component
---@overload fun(station: Entity): DockedComponent
local DockedComponent = Subclass("DockedComponent", Component, function(self, station)
    self:setComponentName("Docked")

    self._station = station
end)

---@return Entity
function DockedComponent:getStation() return self._station end

return DockedComponent
