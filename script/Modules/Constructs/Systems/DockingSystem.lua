local PhysicsComponents   = require("Modules.Physics.Components")
local ConstructComponents = require("Modules.Constructs.Components")
local CoreComponents      = require("Modules.Core.Components")
local RenderComp          = require("Modules.Rendering.Components").Render
local AutoPilotSystem     = require("Modules.Constructs.Systems.AutoPilotSystem")
local ActionSystem        = require("Modules.Constructs.Systems.ActionSystem")

--- Docking System — parks a ship inside a station while docked:
--- kinematic, non-collidable and hidden. UI, camera and input are the caller's.
--- Docked ships carry a DockedComponent naming their station.
---@class DockingSystem
local DockingSystem = {}

---@param entity Entity
---@return RigidBody|nil
local function getBody(entity)
    local rbCmp = entity:get(PhysicsComponents.RigidBody)
    return rbCmp and rbCmp:getRigidBody()
end

---@param entity Entity
---@param visible boolean
local function setTreeVisible(entity, visible)
    local renderCmp = entity:get(RenderComp)
    if renderCmp then renderCmp:setVisible(visible) end

    local children = entity:get(CoreComponents.Children)
    if children then
        for child in children:iterChildren() do
            setTreeVisible(child, visible)
        end
    end
end

---@param station Entity
---@return number
function DockingSystem:getDockRange(station)
    local rb = getBody(station)
    return rb and rb:getBoundingRadius() * Config.game.docking.rangeMult or 0
end

--- Nearest station whose docking range contains the ship
---@param ship Entity
---@param stations Entity[]
---@return Entity|nil station
function DockingSystem:findDockable(ship, stations)
    local shipRb = getBody(ship)
    if not shipRb then return nil end
    local p = shipRb:getPos()

    local best, bestDist = nil, math.huge
    for _, station in ipairs(stations) do
        local rb = getBody(station)
        if rb then
            local s = rb:getPos()
            local dx, dy, dz = s.x - p.x, s.y - p.y, s.z - p.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist <= self:getDockRange(station) and dist < bestDist then
                best, bestDist = station, dist
            end
        end
    end
    return best
end

---@param ship Entity
---@return Entity|nil station
function DockingSystem:getDockedStation(ship)
    local docked = ship:get(ConstructComponents.Docked)
    return docked and docked:getStation()
end

--- Park the ship inside the station, dropping its orders
---@param ship Entity
---@param station Entity
---@return boolean docked
function DockingSystem:dock(ship, station)
    local shipRb, stationRb = getBody(ship), getBody(station)
    if not shipRb or not stationRb then return false end

    ActionSystem:clear(ship)
    AutoPilotSystem:disengage(ship)
    local drive = ship:get(ConstructComponents.TravelDrive)
    if drive then
        drive:setState("idle")
        drive:setChargeTime(0)
        drive:setCurrentMult(1.0)
    end

    -- Kinematic bodies take their velocity from their own motion, so the
    -- ship comes to rest while parked and undocks without momentum.
    shipRb:setKinematic(true)
    shipRb:setCollidable(false)
    shipRb:setPos(stationRb:getPos())
    setTreeVisible(ship, false)

    ship:add(ConstructComponents.Docked(station))
    Log.Info("Docking: docked")
    return true
end

--- Put the ship outside its station, facing along the station's forward axis
---@param ship Entity
---@return boolean undocked
function DockingSystem:undock(ship)
    local station = self:getDockedStation(ship)
    local shipRb = getBody(ship)
    local stationRb = station and getBody(station)
    if not shipRb or not stationRb then return false end

    local rot = stationRb:getRot()
    local dir = rot:getForward()
    local dist = stationRb:getBoundingRadius() * Config.game.docking.undockDistMult
    local s = stationRb:getPos()
    shipRb:setPos(Position(s.x + dir.x * dist, s.y + dir.y * dist, s.z + dir.z * dist))
    shipRb:setRot(rot)
    shipRb:setKinematic(false)
    shipRb:setCollidable(true)
    setTreeVisible(ship, true)

    ship:remove(ConstructComponents.Docked)
    Log.Info("Docking: undocked")
    return true
end

--- Drop docking state without moving anything (teardown)
---@param ship Entity
function DockingSystem:forget(ship)
    ship:remove(ConstructComponents.Docked)
end

return DockingSystem
