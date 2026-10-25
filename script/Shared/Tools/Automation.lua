--- Helpers for driving the game through the automation server (doc/AUTOMATION.md).
--- `lua` and `wait` code sees this module as the global `Automation`.
--- Distances and speeds are physics units; the `*Hud` fields format them as the HUD does.
local PhysicsComponents = require('Modules.Physics.Components')
local AutoPilotSystem = require('Modules.Constructs.Systems.AutoPilotSystem')
local UniverseScaleConfig = require('Config.Gen.UniverseScaleConfig')
local Registry = require('Core.ECS.Registry')

local Automation = {}

---@param x number
---@param digits integer|nil
---@return number
local function round(x, digits)
    local scale = 10 ^ (digits or 0)
    return math.floor(x * scale + 0.5) / scale
end

---@return table|nil app the main game state; nil in other apps
local function game()
    return rawget(_G, 'LimitTheoryRedux')
end

---@param entity Entity|nil
---@return RigidBody|nil
local function body(entity)
    local cmp = entity and entity:get(PhysicsComponents.RigidBody)
    return cmp and cmp:getRigidBody()
end

---@param entity Entity
---@return RigidBody
local function requireBody(entity)
    local rb = body(entity)
    if not rb then error(format("%s has no rigid body", tostring(entity)), 3) end
    return rb
end

---@return Entity|nil
function Automation.ship()
    local app = game()
    return app and app.playerShip
end

---@return table
function Automation.state()
    local app = game()
    local state = GameState:GetCurrentState()
    for name, value in pairs(Enums.GameStates) do
        if value == state then state = name end
    end
    return {
        state = state,
        paused = GameState.paused,
        camera = app and app.player and app.player:getModeName(),
        pauseMenu = app and app.pauseMenuOpen or false,
        map = app and app.mapMode,
        hud = not (app and app.hudHidden),
        focused = Window:isFocused(),
        fullscreen = GameState.render.fullscreen,
        window = { Window:width(), Window:height() },
    }
end

--- The entity's world label if it has one, such as "Station 1", otherwise its type and id.
---@param entity Entity
---@return string
function Automation.name(entity)
    local app = game()
    for _, labeled in ipairs(app and app.labeledEntities or {}) do
        if labeled.entity.id == entity.id then return labeled.label end
    end
    return tostring(entity)
end

--- Entities with a rigid body, nearest first.
---@param opts? { near: Entity|nil, within: number|nil, match: string|nil, limit: integer|nil }
---@return table[] { entity, name, distance, surface, surfaceHud }
function Automation.entities(opts)
    opts = opts or {}
    local origin = body(opts.near or Automation.ship())
    local originPos = origin and origin:getPos()
    local match = opts.match and opts.match:lower()

    local found = {}
    for entity, cmp in Registry:iterEntities(PhysicsComponents.RigidBody) do
        local rb = cmp:getRigidBody()
        if rb and not (origin and rb == origin) then
            local name = Automation.name(entity)
            local distance = originPos and (rb:getPos() - originPos):length() or 0
            if (not match or name:lower():find(match, 1, true))
                and (not opts.within or distance <= opts.within)
            then
                found[#found + 1] = {
                    entity = entity,
                    name = name,
                    distance = distance,
                    surface = distance - rb:getBoundingRadius(),
                }
            end
        end
    end
    table.sort(found, function(a, b) return a.distance < b.distance end)

    local limit = math.min(#found, opts.limit or 20)
    local nearest = {}
    for i = 1, limit do
        local entry = found[i]
        entry.distance = round(entry.distance, 1)
        entry.surface = round(entry.surface, 1)
        entry.surfaceHud = UniverseScaleConfig:formatDistance(entry.surface)
        nearest[i] = entry
    end
    return nearest
end

--- The nearest entity whose name contains `text`, ignoring case.
---@param text string
---@return Entity|nil
function Automation.find(text)
    local nearest = Automation.entities({ match = text, limit = 1 })[1]
    return nearest and nearest.entity
end

---@param target Entity|string an entity, or text for `find`
---@return Entity
local function resolve(target)
    if type(target) == 'string' then
        local entity = Automation.find(target)
        if not entity then error(format("No entity matches '%s'", target), 3) end
        return entity
    end
    return target
end

--- Where `target` is from the player ship: distance to its surface, the ship's speed, and the
--- target's direction in the ship's frame (`offAxis` is degrees off the nose).
---@param target Entity|string
---@return table
function Automation.nav(target)
    target = resolve(target)
    local rb, targetRb = requireBody(Automation.ship()), requireBody(target)
    local offset = targetRb:getPos() - rb:getPos()
    local distance = offset:length()
    local dir = Vec3f(offset.x / distance, offset.y / distance, offset.z / distance)
    local rot = rb:getRot()
    local forward = dir:dot(rot:getForward())
    local surface = distance - targetRb:getBoundingRadius()
    return {
        name = Automation.name(target),
        surface = round(surface, 1),
        surfaceHud = UniverseScaleConfig:formatDistance(surface),
        speed = round(rb:getSpeed(), 3),
        speedHud = UniverseScaleConfig:formatSpeed(rb:getSpeed()),
        offAxis = round(math.deg(math.acos(math.max(-1, math.min(1, forward))))),
        forward = round(forward, 3),
        right = round(dir:dot(rot:getRight()), 3),
        up = round(dir:dot(rot:getUp()), 3),
    }
end

--- Turn the player ship to face `target` instantly.
---@param target Entity|string
---@return table nav
function Automation.aimAt(target)
    target = resolve(target)
    local rb, targetRb = requireBody(Automation.ship()), requireBody(target)
    local offset = targetRb:getPos() - rb:getPos()
    local distance = offset:length()
    local dir = Vec3f(offset.x / distance, offset.y / distance, offset.z / distance)
    rb:setRot(Quat.FromLookUp(dir, rb:getRot():getUp()))
    return Automation.nav(target)
end

--- Move the player ship to `altitude` above `target`'s surface on the side it's on now,
--- facing the target. The flight controller damps any velocity it keeps.
---@param target Entity|string
---@param altitude number
---@return table nav
function Automation.placeNear(target, altitude)
    target = resolve(target)
    local rb, targetRb = requireBody(Automation.ship()), requireBody(target)
    local center = targetRb:getPos()
    local offset = rb:getPos() - center
    local scale = (targetRb:getBoundingRadius() + altitude) / offset:length()
    rb:setPos(Position(center.x + offset.x * scale, center.y + offset.y * scale, center.z + offset.z * scale))
    return Automation.aimAt(target)
end

--- Engage the game's autopilot toward `target`. It arrives at 1.5x the target's radius from
--- its center (at least 50 units) and then disengages; wait on `not Automation.autopilot().active`.
---@param target Entity|string
---@return table nav
function Automation.flyTo(target)
    target = resolve(target)
    AutoPilotSystem:engageEntity(Automation.ship(), target)
    return Automation.nav(target)
end

---@return table
function Automation.autopilot()
    local ship = Automation.ship()
    local distance, speed = AutoPilotSystem:getDistanceAndSpeed(ship)
    local ap = ship:get(require('Modules.Constructs.Components').AutoPilot)
    return {
        active = AutoPilotSystem:isActive(ship),
        target = AutoPilotSystem:getTargetName(ship),
        avoiding = ap and ap.avoiding ~= nil or false,
        distance = round(distance, 1),
        distanceHud = UniverseScaleConfig:formatDistance(distance),
        speedHud = UniverseScaleConfig:formatSpeed(speed),
    }
end

function Automation.stop()
    AutoPilotSystem:disengage(Automation.ship())
end

--- Name of the key bound to an input action such as "ShipActions.Dock" (modules in
--- script/Input/ActionBindings). `negative` picks the second key of a two-key axis.
---@param path string
---@param negative boolean|nil
---@return string
function Automation.keyFor(path, negative)
    local module, field = path:match('^([%w_]+)%.([%w_]+)$')
    local ok, bindings = pcall(require, 'Input.ActionBindings.' .. tostring(module))
    local binding = ok and field and bindings[field]
    if not binding then error(format("No action binding '%s'", path), 2) end

    for _, device in ipairs({ 'keyboard', 'mouse' }) do
        for _, bind in ipairs(binding.deviceBindings[device] or {}) do
            local key = bind.key or (negative and bind.negative or bind.positive)
            if key then return ffi.string(Button.ToString(key)) end
        end
    end
    error(format("Action '%s' has no key or mouse button bound", path), 2)
end

return Automation
