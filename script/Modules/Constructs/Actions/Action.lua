--- Base class for actions on an entity's action stack (see ActionSystem). Only the
--- top action is active; actions below it are suspended until it finishes.
---
---   onStart / onStop       : the action first becomes active / leaves the stack
---   onSuspend / onResume   : another action is pushed on top / it comes back on top
---   onUpdateActive         : every update while on top
---   onUpdatePassive        : every update, active or not
---@class Action
local Action = Class("Action", function(self) end)

---@return string
function Action:getName()
    return tostring(getmetatable(self))
end

---@param e Entity
function Action:onStart(e) end

---@param e Entity
function Action:onStop(e) end

---@param e Entity
function Action:onSuspend(e) end

---@param e Entity
function Action:onResume(e) end

---@param e Entity
---@param dt number
function Action:onUpdateActive(e, dt) end

---@param e Entity
---@param dt number
function Action:onUpdatePassive(e, dt) end

--- Take this action off the entity's stack.
---@param e Entity
function Action:finish(e)
    require("Modules.Constructs.Systems.ActionSystem"):remove(e, self)
end

return Action
