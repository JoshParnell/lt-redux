local Action            = require("Modules.Constructs.Actions.Action")
local AutoPilotSystem   = require("Modules.Constructs.Systems.AutoPilotSystem")
local PhysicsComponents = require("Modules.Physics.Components")

--- Turn the ship until its nose points at an entity or position.
---@class FaceAction: Action
---@overload fun(target: Entity|Position): FaceAction
local Face = Subclass("Face", Action, function(self, target)
    self.target = target
end)

function Face:getName()
    return format("Face %s", tostring(self.target))
end

---@param target Entity|Position
---@return Position|nil
local function targetPos(target)
    if rawtype(target) ~= "table" then return target end
    local cmp = target:get(PhysicsComponents.RigidBody)
    local rb = cmp and cmp:getRigidBody()
    return rb and rb:getPos()
end

function Face:onUpdateActive(e, dt)
    local cmp = e:get(PhysicsComponents.RigidBody)
    local rb = cmp and cmp:getRigidBody()
    local pos = targetPos(self.target)
    if not rb or not pos then return self:finish(e) end

    local shipPos = rb:getPos()
    local dx, dy, dz = pos.x - shipPos.x, pos.y - shipPos.y, pos.z - shipPos.z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-6 then return self:finish(e) end

    local alignment = AutoPilotSystem:steerToward(rb, dx / len, dy / len, dz / len)
    if alignment > 0.9995 and rb:getVelocityA():length() < 0.01 then
        self:finish(e)
    end
end

return Face
