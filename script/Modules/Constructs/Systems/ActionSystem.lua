local Registry            = require("Core.ECS.Registry")
local ConstructComponents = require("Modules.Constructs.Components")

--- ActionSystem — runs each entity's action stack (ActionsComponent). Only the top
--- action is active: `push` interrupts the current action until the new one finishes,
--- while `queue` runs an action after everything already on the stack.
---@class ActionSystem
local ActionSystem = {}

---@param entity Entity
---@param create boolean|nil add the component if the entity has none
---@return ActionsComponent|nil
local function actions(entity, create)
    local cmp = entity:get(ConstructComponents.Actions)
    if not cmp and create then
        cmp = ConstructComponents.Actions()
        entity:add(cmp)
    end
    return cmp
end

--- Start `action` on the next update, suspending the current one until it finishes.
---@param entity Entity
---@param action Action
function ActionSystem:push(entity, action)
    local stack = actions(entity, true).stack
    stack[#stack + 1] = action
end

--- Run `action` after everything already on the entity's stack.
---@param entity Entity
---@param action Action
function ActionSystem:queue(entity, action)
    table.insert(actions(entity, true).stack, 1, action)
end

--- Take `action` off the stack, stopping it if it had started.
---@param entity Entity
---@param action Action
function ActionSystem:remove(entity, action)
    local cmp = actions(entity)
    if not cmp then return end
    for i = #cmp.stack, 1, -1 do
        if cmp.stack[i] == action then
            table.remove(cmp.stack, i)
            if cmp.active == action then cmp.active = nil end
            if action._started then action:onStop(entity) end
            return
        end
    end
end

--- Stop and remove every action, top first.
---@param entity Entity
function ActionSystem:clear(entity)
    local cmp = actions(entity)
    while cmp and #cmp.stack > 0 do
        self:remove(entity, cmp.stack[#cmp.stack])
    end
end

---@param entity Entity
---@return Action|nil
function ActionSystem:current(entity)
    local cmp = actions(entity)
    return cmp and cmp.stack[#cmp.stack]
end

---@param entity Entity
---@return boolean
function ActionSystem:isBusy(entity)
    return self:current(entity) ~= nil
end

---@param entity Entity
---@return string[] top first
function ActionSystem:getNames(entity)
    local names = {}
    local cmp = actions(entity)
    for i = #(cmp and cmp.stack or {}), 1, -1 do
        names[#names + 1] = cmp.stack[i]:getName()
    end
    return names
end

---@param dt number
function ActionSystem:update(dt)
    for entity, cmp in Registry:iterEntities(ConstructComponents.Actions) do
        local stack = cmp.stack
        local top = stack[#stack]

        if top ~= cmp.active then
            if cmp.active and cmp.active._started then cmp.active:onSuspend(entity) end
            cmp.active = top
            if top then
                if top._started then
                    top:onResume(entity)
                else
                    top._started = true
                    top:onStart(entity)
                end
            end
        end

        if #stack > 0 then
            for _, action in ipairs({ table.unpack(stack) }) do
                action:onUpdatePassive(entity, dt)
            end
            if stack[#stack] == top then top:onUpdateActive(entity, dt) end
        end
    end
end

return ActionSystem
