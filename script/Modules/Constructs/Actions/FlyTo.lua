local Action          = require("Modules.Constructs.Actions.Action")
local AutoPilotSystem = require("Modules.Constructs.Systems.AutoPilotSystem")
local DockingSystem   = require("Modules.Constructs.Systems.DockingSystem")

--- Fly to an entity or position with the ship's autopilot, undocking first. Finishes when
--- the autopilot stops, on arrival or because something cancelled it.
---@class FlyToAction: Action
---@overload fun(target: Entity|Position): FlyToAction
local FlyTo = Subclass("FlyTo", Action, function(self, target)
    self.target = target
end)

function FlyTo:getName()
    return format("FlyTo %s", tostring(self.target))
end

---@param e Entity
local function engage(self, e)
    if rawtype(self.target) == "table" then
        AutoPilotSystem:engageEntity(e, self.target)
    else
        AutoPilotSystem:engagePosition(e, self.target)
    end
end

function FlyTo:onStart(e)
    DockingSystem:undock(e)
    engage(self, e)
end

function FlyTo:onResume(e) engage(self, e) end

function FlyTo:onSuspend(e) AutoPilotSystem:disengage(e) end

function FlyTo:onStop(e)
    if AutoPilotSystem:isActive(e) then AutoPilotSystem:disengage(e) end
end

function FlyTo:onUpdateActive(e, dt)
    if not AutoPilotSystem:isActive(e) then self:finish(e) end
end

return FlyTo
