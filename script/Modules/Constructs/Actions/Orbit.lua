local Action            = require("Modules.Constructs.Actions.Action")
local FlyTo             = require("Modules.Constructs.Actions.FlyTo")
local AutoPilotSystem   = require("Modules.Constructs.Systems.AutoPilotSystem")
local PhysicsComponents = require("Modules.Physics.Components")

--- Circle an entity at `radius` from its center, at cruise speed, around the world's up axis,
--- flying there first when far away. Runs until `seconds` have passed, or until removed.
---@class OrbitAction: Action
---@overload fun(target: Entity, radius: number, seconds: number|nil): OrbitAction
local Orbit = Subclass("Orbit", Action, function(self, target, radius, seconds)
    self.target = target
    self.radius = radius
    self.remaining = seconds
end)

function Orbit:getName()
    return format("Orbit %s at %.0f", tostring(self.target), self.radius)
end

---@param entity Entity
---@return RigidBody|nil
local function body(entity)
    local cmp = entity:get(PhysicsComponents.RigidBody)
    return cmp and cmp:getRigidBody()
end

function Orbit:onUpdateActive(e, dt)
    local rb, targetRb = body(e), body(self.target)
    if not rb or not targetRb then return self:finish(e) end

    if self.remaining then
        self.remaining = self.remaining - dt
        if self.remaining <= 0 then return self:finish(e) end
    end

    local c, p = targetRb:getPos(), rb:getPos()
    local rx, ry, rz = p.x - c.x, p.y - c.y, p.z - c.z
    local dist = math.sqrt(rx * rx + ry * ry + rz * rz)
    if dist < 1e-6 then return end
    if dist > self.radius * 1.5 and not self.approached then
        self.approached = true
        return require("Modules.Constructs.Systems.ActionSystem"):push(e, FlyTo(self.target))
    end
    rx, ry, rz = rx / dist, ry / dist, rz / dist

    -- Tangent = up x radial; near the poles any horizontal direction will do
    local tx, ty, tz = rz, 0, -rx
    local tLen = math.sqrt(tx * tx + tz * tz)
    if tLen < 1e-3 then tx, ty, tz, tLen = 1, 0, 0, 1 end
    tx, tz = tx / tLen, tz / tLen

    -- Cruise along the tangent, closing radius error over about a second
    local cfg = Config.game.shipFlight
    local speed = cfg.maxSpeedGame
    local radial = Math.Clamp(self.radius - dist, -speed, speed)
    local vx, vy, vz = tx * speed + rx * radial, ty * speed + ry * radial, tz * speed + rz * radial

    -- matchVelocity settles at target / (1 + drag) because drag fights it, so aim that much higher
    local aim = 1 + cfg.linearDrag
    AutoPilotSystem:matchVelocity(rb, vx * aim, vy * aim, vz * aim, 0.001)
    local vLen = math.sqrt(vx * vx + vy * vy + vz * vz)
    AutoPilotSystem:steerToward(rb, vx / vLen, vy / vLen, vz / vLen)
end

return Orbit
