local PhysicsComponents   = require("Modules.Physics.Components")
local ConstructComponents = require("Modules.Constructs.Components")

--- AutoPilot System — steers a ship toward a target entity or position.
--- Operates on the AutoPilotComponent attached to ship entities.
---@class AutoPilotSystem
local AutoPilotSystem = {}

--- Engage autopilot to fly toward an entity
---@param shipEntity Entity
---@param targetEntity Entity
---@param arrivalRange number|nil
function AutoPilotSystem:engageEntity(shipEntity, targetEntity, arrivalRange)
    local ap = shipEntity:get(ConstructComponents.AutoPilot)
    if not ap then return end

    local cfg = Config.game.autoPilot or {}
    ap:setActive(true)
    ap:setTargetEntity(targetEntity)
    ap:setTargetPos(nil)
    ap:setArrivalRange(arrivalRange or cfg.arrivalRange or 500)
    ap:setElapsed(0)
    Log.Info("AutoPilot: engaged to %s", tostring(targetEntity))
end

--- Engage autopilot to fly toward a position
---@param shipEntity Entity
---@param pos Position
---@param arrivalRange number|nil
---@param parentEntity Entity|nil Parent entity for tracking (e.g., planet for ring asteroids)
---@param localOffsetX number|nil Local X offset from parent
---@param localOffsetZ number|nil Local Z offset from parent
function AutoPilotSystem:engagePosition(shipEntity, pos, arrivalRange, parentEntity, localOffsetX, localOffsetZ)
    local ap = shipEntity:get(ConstructComponents.AutoPilot)
    if not ap then return end

    local cfg = Config.game.autoPilot or {}
    ap:setActive(true)
    ap:setTargetEntity(nil)
    ap:setTargetPos(pos)
    ap:setArrivalRange(arrivalRange or cfg.arrivalRange or 500)
    ap:setElapsed(0)
    ap._parentEntity = parentEntity
    ap._localOffsetX = localOffsetX
    ap._localOffsetZ = localOffsetZ
    Log.Info("AutoPilot: engaged to position")
end

--- Physics world searched for obstacles; without one the autopilot flies straight at its target.
---@param world Physics|nil
function AutoPilotSystem:setWorld(world)
    self.world = world
end

--- Disengage autopilot
---@param shipEntity Entity
function AutoPilotSystem:disengage(shipEntity)
    local ap = shipEntity:get(ConstructComponents.AutoPilot)
    if not ap then return end

    if ap:isActive() then
        Log.Info("AutoPilot: disengaged")
    end
    ap:setActive(false)
    ap:setTargetEntity(nil)
    ap:setTargetPos(nil)
    ap:setElapsed(0)

    -- Reset travel drive through component
    local drive = shipEntity:get(ConstructComponents.TravelDrive)
    if drive then
        drive:setState("idle")
        drive:setCurrentMult(1.0)
        drive:setChargeTime(0)
    end
end

--- Is autopilot currently active for this ship?
---@param shipEntity Entity
---@return boolean
function AutoPilotSystem:isActive(shipEntity)
    local ap = shipEntity:get(ConstructComponents.AutoPilot)
    return ap and ap:isActive() or false
end

--- Get target name for HUD display
---@param shipEntity Entity
---@return string
function AutoPilotSystem:getTargetName(shipEntity)
    local ap = shipEntity:get(ConstructComponents.AutoPilot)
    return ap and ap:getTargetName() or ""
end

--- Get distance to autopilot target
---@param shipEntity Entity
---@return number distance, number speed
function AutoPilotSystem:getDistanceAndSpeed(shipEntity)
    local ap = shipEntity:get(ConstructComponents.AutoPilot)
    if not ap or not ap:isActive() then return 0, 0 end

    local rbCmp = shipEntity:get(PhysicsComponents.RigidBody)
    if not rbCmp then return 0, 0 end
    local rb = rbCmp:getRigidBody()
    if not rb then return 0, 0 end

    local shipPos = rb:getPos()
    local speed = rb:getSpeed()

    -- Get target position
    local targetPos = ap:getTargetPos()
    local targetEntity = ap:getTargetEntity()
    if targetEntity then
        local tRbCmp = targetEntity:get(PhysicsComponents.RigidBody)
        if tRbCmp and tRbCmp:getRigidBody() then
            targetPos = tRbCmp:getRigidBody():getPos()
        else
            local tTransform = targetEntity:get(PhysicsComponents.Transform)
            if tTransform then targetPos = tTransform:getPos() end
        end
    end

    if not targetPos then return 0, speed end

    local dx = targetPos.x - shipPos.x
    local dy = targetPos.y - shipPos.y
    local dz = targetPos.z - shipPos.z
    return math.sqrt(dx * dx + dy * dy + dz * dz), speed
end

--- Nearest body whose clearance sphere the straight path ahead passes through.
--- Skips the ship and its parts, the target, and any body whose clearance holds
--- the target point (the ship has to get close to that one anyway).
---@param world Physics
---@param rb RigidBody ship
---@param targetRb RigidBody|nil
---@param targetPos Position
---@param dirX number path direction (unit)
---@param dirY number
---@param dirZ number
---@param length number how far ahead to look
---@return RigidBody|nil obstacle
---@return number clearance radius around its center to steer outside of
---@return number distance along the path to its closest approach
local function findObstacle(world, rb, targetRb, targetPos, dirX, dirY, dirZ, length)
    local cfg = Config.game.autoPilot or {}
    local margin = cfg.avoidMargin or 0.5
    local pos = rb:getPos()
    local shipRadius = rb:getBoundingRadius()

    -- f32 sphere centre: coarse at system scale, so it only gathers candidates
    local half = length * 0.5
    local hits = world:sphereCast(Sphere(
        pos.x + dirX * half, pos.y + dirY * half, pos.z + dirZ * half,
        half + shipRadius + 1))

    local nearest, nearestT, nearestClearance = nil, math.huge, 0
    for i = 0, hits.hits_len - 1 do
        local body = hits.hits[i]
        if body ~= rb and body ~= targetRb and body:getParentBody() ~= rb then
            local c = body:getPos()
            local clearance = body:getBoundingRadius() * (1 + margin) + shipRadius
            local cx, cy, cz = c.x - pos.x, c.y - pos.y, c.z - pos.z
            local t = Math.Clamp(cx * dirX + cy * dirY + cz * dirZ, 0, length)
            local mx, my, mz = cx - dirX * t, cy - dirY * t, cz - dirZ * t
            local tx, ty, tz = targetPos.x - c.x, targetPos.y - c.y, targetPos.z - c.z
            if mx * mx + my * my + mz * mz < clearance * clearance
                and tx * tx + ty * ty + tz * tz > clearance * clearance
                and t < nearestT
            then
                nearest, nearestT, nearestClearance = body, t, clearance
            end
        end
    end
    return nearest, nearestClearance, nearestT
end

--- Turn a ship toward a world direction with its yaw and pitch torque.
---@param rb RigidBody
---@param courseX number unit direction
---@param courseY number
---@param courseZ number
---@return number alignment dot product of the ship's forward and the course
function AutoPilotSystem:steerToward(rb, courseX, courseY, courseZ)
    local cfg = Config.game.shipFlight
    local rot = rb:getRot()
    local fwd, rt, up = rot:getForward(), rot:getRight(), rot:getUp()

    local crossX = fwd.y * courseZ - fwd.z * courseY
    local crossY = fwd.z * courseX - fwd.x * courseZ
    local crossZ = fwd.x * courseY - fwd.y * courseX

    local yawError   = Math.Clamp(-(up.x * crossX + up.y * crossY + up.z * crossZ) * 3, -1, 1)
    local pitchError = Math.Clamp((rt.x * crossX + rt.y * crossY + rt.z * crossZ) * 3, -1, 1)

    rb:applyTorque(rot:mulV(Vec3f(
        pitchError * cfg.torquePitch * 0.3,
        -yawError * cfg.torqueYaw * 0.3,
        0
    )))
    return fwd.x * courseX + fwd.y * courseY + fwd.z * courseZ
end

--- Exponential mapping for smooth control output (from legacy)
local function expMap(x)
    if x >= 0 then
        return 1.0 - math.exp(-x)
    else
        return -(1.0 - math.exp(x))
    end
end

--- Update autopilot — steer ship toward target
---@param dt number
---@param shipEntity Entity
function AutoPilotSystem:update(dt, shipEntity)
    if not shipEntity then return end

    local ap = shipEntity:get(ConstructComponents.AutoPilot)
    if not ap or not ap:isActive() then return end

    local rbCmp = shipEntity:get(PhysicsComponents.RigidBody)
    if not rbCmp then self:disengage(shipEntity); return end
    local rb = rbCmp:getRigidBody()
    if not rb then self:disengage(shipEntity); return end

    -- Get target position
    local targetEntity = ap:getTargetEntity()
    local targetPos = ap:getTargetPos()
    if targetEntity then
        local tRbCmp = targetEntity:get(PhysicsComponents.RigidBody)
        if tRbCmp and tRbCmp:getRigidBody() then
            targetPos = tRbCmp:getRigidBody():getPos()
        else
            local tTransform = targetEntity:get(PhysicsComponents.Transform)
            if tTransform then targetPos = tTransform:getPos() end
        end
    end

    -- Recompute position from parent + local offset (for orbiting targets)
    if ap._parentEntity and ap._localOffsetX then
        local pRb = ap._parentEntity:get(PhysicsComponents.RigidBody)
        if pRb and pRb:getRigidBody() then
            local pp = pRb:getRigidBody():getPos()
            targetPos = Position(pp.x + ap._localOffsetX, pp.y, pp.z + ap._localOffsetZ)
            ap:setTargetPos(targetPos)
        end
    end

    if not targetPos then self:disengage(shipEntity); return end

    local shipPos = rb:getPos()
    local speed = rb:getSpeed()

    -- Compute target velocity from position delta (works for kinematic bodies moved by setPos)
    local tVelX, tVelY, tVelZ = 0, 0, 0
    if ap._prevTargetPos and dt > 0 then
        tVelX = (targetPos.x - ap._prevTargetPos.x) / dt
        tVelY = (targetPos.y - ap._prevTargetPos.y) / dt
        tVelZ = (targetPos.z - ap._prevTargetPos.z) / dt
        -- Smooth velocity (low-pass filter to reduce jitter)
        local s = math.min(1, 5 * dt)
        ap.targetVelX = ap.targetVelX + (tVelX - ap.targetVelX) * s
        ap.targetVelY = ap.targetVelY + (tVelY - ap.targetVelY) * s
        ap.targetVelZ = ap.targetVelZ + (tVelZ - ap.targetVelZ) * s
    end
    ap._prevTargetPos = Position(targetPos.x, targetPos.y, targetPos.z)

    -- Quick distance check for approach mode
    local qdx = targetPos.x - shipPos.x
    local qdy = targetPos.y - shipPos.y
    local qdz = targetPos.z - shipPos.z
    local quickDist = math.sqrt(qdx*qdx + qdy*qdy + qdz*qdz)

    -- Lead prediction: aim where target WILL BE when we arrive
    -- Skip leading when close (within 5000 units) or inside any gravity well — fly direct
    local GravityWellSystem = require("Modules.Physics.Systems.GravityWellSystem")
    local closeApproach = quickDist < 5000
    local inGravityWell = GravityWellSystem:getZoneType() ~= "openSpace"
    local inTargetZone = closeApproach or inGravityWell

    local interceptPos = targetPos
    local tSpeed = math.sqrt(ap.targetVelX^2 + ap.targetVelY^2 + ap.targetVelZ^2)
    if tSpeed > 0.1 and not inTargetZone then
        -- Use expected cruise speed for ETA, not current speed
        -- Cruise = base flight speed × zone max drive multiplier
        local maxDriveMult = GravityWellSystem:getMaxDriveSpeed()
        local cfg = Config.game.shipFlight
        local baseCruise = cfg.thrustForward / (rb:getMass() * cfg.linearDrag)
        local expectedSpeed = math.max(speed, baseCruise * maxDriveMult * 0.5)

        local tdx = targetPos.x - shipPos.x
        local tdy = targetPos.y - shipPos.y
        local tdz = targetPos.z - shipPos.z
        local currentDist = math.sqrt(tdx*tdx + tdy*tdy + tdz*tdz)
        local eta = currentDist / math.max(1, expectedSpeed)

        -- Two-pass refinement
        for _ = 1, 2 do
            local lx = targetPos.x + ap.targetVelX * eta
            local ly = targetPos.y + ap.targetVelY * eta
            local lz = targetPos.z + ap.targetVelZ * eta
            local ldx = lx - shipPos.x
            local ldy = ly - shipPos.y
            local ldz = lz - shipPos.z
            eta = math.sqrt(ldx*ldx + ldy*ldy + ldz*ldz) / math.max(1, expectedSpeed)
        end

        -- Blend lead prediction: full lead when far, direct approach when close
        local tdx = targetPos.x - shipPos.x
        local tdy = targetPos.y - shipPos.y
        local tdz = targetPos.z - shipPos.z
        local rawDist = math.sqrt(tdx*tdx + tdy*tdy + tdz*tdz)
        local leadBlend = math.min(1.0, rawDist / math.max(1, speed * 30))  -- fade over 30s travel

        interceptPos = Position(
            targetPos.x + ap.targetVelX * eta * leadBlend,
            targetPos.y + ap.targetVelY * eta * leadBlend,
            targetPos.z + ap.targetVelZ * eta * leadBlend)
    end

    -- Distance to ACTUAL target (for arrival check + drive decel)
    local actualTargetPos = ap._prevTargetPos or targetPos
    local adx = actualTargetPos.x - shipPos.x
    local ady = actualTargetPos.y - shipPos.y
    local adz = actualTargetPos.z - shipPos.z
    local actualDist = math.sqrt(adx * adx + ady * ady + adz * adz)

    -- Distance to intercept (for steering)
    local idx = interceptPos.x - shipPos.x
    local idy = interceptPos.y - shipPos.y
    local idz = interceptPos.z - shipPos.z
    local interceptDist = math.sqrt(idx * idx + idy * idy + idz * idz)

    -- Store nav data on component for map/HUD
    ap.interceptPos = interceptPos
    ap.distance = actualDist
    ap.eta = speed > 1 and actualDist / speed or 0

    -- Use actual distance for arrival/drive logic, intercept for steering
    local dist = actualDist

    -- Navigate toward intercept point
    targetPos = interceptPos

    -- Get target radius for safe distance
    local targetRadius = 0
    if targetEntity then
        local tRbCmp = targetEntity:get(PhysicsComponents.RigidBody)
        if tRbCmp and tRbCmp:getRigidBody() then
            targetRadius = tRbCmp:getRigidBody():getBoundingRadius()
        else
            local tTransform = targetEntity:get(PhysicsComponents.Transform)
            if tTransform then targetRadius = tTransform:getScale() end
        end
    end

    -- Safe arrival distance: 1.5x object radius, minimum 50 units
    local safeRange = math.max(50, targetRadius * 1.5)

    -- Arrival check; inside the safe range the desired speed is zero, so it brakes until slow
    if dist < safeRange and speed <= Config.game.shipFlight.maxSpeedGame then
        Log.Info("AutoPilot: arrived at destination (dist=%.0f, safe=%.0f)", dist, safeRange)
        self:disengage(shipEntity)
        return
    end

    local cfg = Config.game.shipFlight
    local vel = rb:getVelocity()
    local speed = rb:getSpeed()
    local rot = rb:getRot()
    local fwd = rot:getForward()
    local up  = rot:getUp()

    -- Get target body's velocity — skip inside gravity wells (GravityWellSystem handles matching)
    local targetVelX, targetVelY, targetVelZ = 0, 0, 0
    if targetEntity and not inTargetZone then
        local tRbCmp = targetEntity:get(PhysicsComponents.RigidBody)
        if tRbCmp and tRbCmp:getRigidBody() then
            local tVel = tRbCmp:getRigidBody():getVelocity()
            targetVelX, targetVelY, targetVelZ = tVel.x, tVel.y, tVel.z
        end
    end

    -- Compute DESIRED VELOCITY
    -- Direction to intercept point (for steering)
    local steerDx = targetPos.x - shipPos.x
    local steerDy = targetPos.y - shipPos.y
    local steerDz = targetPos.z - shipPos.z
    local steerDist = math.sqrt(steerDx*steerDx + steerDy*steerDy + steerDz*steerDz)
    if steerDist < 1 then steerDist = 1 end
    local dirX, dirY, dirZ = steerDx / steerDist, steerDy / steerDist, steerDz / steerDist

    -- Desired speed. Drag bleeds speed at rate linearDrag, so after thrust stops the ship
    -- coasts about speed / linearDrag: keep that within half the remaining distance. Close
    -- in, the thrust-braking curve allows more.
    local maxDecel = cfg.thrustForward / rb:getMass()
    local brakingDist = math.max(0, dist - safeRange)
    local desiredApproachSpeed = math.max(
        math.sqrt(2.0 * maxDecel * brakingDist),
        brakingDist * cfg.linearDrag * 0.5
    )

    -- Steer around the nearest body in the next few seconds of travel, slow enough to stop short of it
    ap.avoiding = nil
    if self.world then
        local apCfg = Config.game.autoPilot or {}
        local lookAhead = math.min(steerDist, math.max(speed, cfg.maxSpeedGame) * (apCfg.avoidLookAhead or 5))
        local targetRbCmp = targetEntity and targetEntity:get(PhysicsComponents.RigidBody)
        local targetRb = targetRbCmp and targetRbCmp:getRigidBody()
        local obstacle, clearance, obstacleT = findObstacle(
            self.world, rb, targetRb, targetPos, dirX, dirY, dirZ, lookAhead)
        if obstacle then
            local c = obstacle:getPos()
            local cx, cy, cz = c.x - shipPos.x, c.y - shipPos.y, c.z - shipPos.z
            local along = cx * dirX + cy * dirY + cz * dirZ
            -- Pass on the side the path already leans to; dead centre, go over the ship's top
            local ox, oy, oz = dirX * along - cx, dirY * along - cy, dirZ * along - cz
            local offLen = math.sqrt(ox * ox + oy * oy + oz * oz)
            if offLen < clearance * 1e-3 then
                local upAlong = up.x * dirX + up.y * dirY + up.z * dirZ
                ox, oy, oz = up.x - dirX * upAlong, up.y - dirY * upAlong, up.z - dirZ * upAlong
                offLen = math.sqrt(ox * ox + oy * oy + oz * oz)
            end
            local scale = clearance * 1.2 / offLen
            local wx, wy, wz = cx + ox * scale, cy + oy * scale, cz + oz * scale
            local wLen = math.sqrt(wx * wx + wy * wy + wz * wz)
            dirX, dirY, dirZ = wx / wLen, wy / wLen, wz / wLen
            desiredApproachSpeed = math.min(desiredApproachSpeed,
                math.max(cfg.maxSpeedGame, obstacleT * cfg.linearDrag * 0.5))
            ap.avoiding = obstacle
        end
    end

    -- Desired velocity = approach direction * approach speed + target's velocity (match orbit)
    local desVelX = dirX * desiredApproachSpeed + targetVelX
    local desVelY = dirY * desiredApproachSpeed + targetVelY
    local desVelZ = dirZ * desiredApproachSpeed + targetVelZ

    -- Velocity error
    local errX = desVelX - vel.x
    local errY = desVelY - vel.y
    local errZ = desVelZ - vel.z
    local errLen = math.sqrt(errX * errX + errY * errY + errZ * errZ)

    -- Apply force to correct velocity error
    if errLen > 0.1 then
        local corrX = errX / errLen
        local corrY = errY / errLen
        local corrZ = errZ / errLen
        -- At least the ship's own thrust, or drag holds a slow ship below any useful speed
        local desiredDecel = math.min(errLen, math.max(speed * 0.5, maxDecel))
        local forceScale = desiredDecel * rb:getMass()
        rb:applyForce(Vec3f(corrX * forceScale, corrY * forceScale, corrZ * forceScale))
    end

    -- Steering: point ship toward desired velocity direction
    local desVelLen = math.sqrt(desVelX * desVelX + desVelY * desVelY + desVelZ * desVelZ)
    if desVelLen > 1 then
        self:steerToward(rb, desVelX / desVelLen, desVelY / desVelLen, desVelZ / desVelLen)
    end

    -- Travel drive: its multiplier sets top speed (cruise x mult), so match it to the
    -- approach speed. Engage once that's worth it with the nose on course; cut it close in.
    local drive = shipEntity:get(ConstructComponents.TravelDrive)
    if drive then
        local autoPilotCfg = Config.game.autoPilot or {}
        local travelDriveDelay = autoPilotCfg.travelDriveDelay or 5.0
        local enableTravelDrive = autoPilotCfg.enableTravelDrive ~= false
        local GravityWellSystem = require("Modules.Physics.Systems.GravityWellSystem")
        local zoneMax = GravityWellSystem:getMaxDriveSpeed()

        local cruise = cfg.thrustForward / (rb:getMass() * cfg.linearDrag)
        local desiredMult = Math.Clamp(desiredApproachSpeed / cruise, 1, zoneMax)

        if drive:isActive() then
            if desiredMult < 2 then
                drive:setState("decelerating")
            elseif drive:getCurrentMult() > desiredMult then
                drive:setCurrentMult(desiredMult)
            end
        end

        local elapsed = ap:getElapsed() + dt
        ap:setElapsed(elapsed)

        local onCourse = fwd.x * dirX + fwd.y * dirY + fwd.z * dirZ > 0.98
        if enableTravelDrive and elapsed > travelDriveDelay and desiredMult > 4 and onCourse then
            if not drive:isActive() and drive:getState() == "idle" then
                drive:setState("charging")
                drive:setChargeTime(0)
            end
        end
    else
        ap:setElapsed(ap:getElapsed() + dt)
    end
end

return AutoPilotSystem
