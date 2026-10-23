---@type UIView
local Paused = UICore.View {
    name = "Paused"
}

---@type UIRouter
local UIRouter = require("UI.HmGui.UICore.UIRouter")
---@type ResponsiveSize
local ResponsiveSize = require("Types.ResponsiveSize")

-- NOTE: Escape handling is owned by LimitTheoryRedux:onInput (single
-- toggle point); the Paused view only provides the button callbacks.
-- Pause state and cursor are likewise owned by openPauseMenu/closePauseMenu.

function Paused:onInput() end

function Paused:onUpdate(dt) end

function Paused:onViewOpen(isPageOpen) end

function Paused:onViewClose(isPageClose) end

local menuContainer = UIComponent.Container {
    align = { AlignHorizontal.Stretch, AlignVertical.Stretch },
    childrenAlign = { AlignHorizontal.Center, AlignVertical.Center },
    padding = { 0, 0 },
    layoutType = GuiLayoutType.Vertical,
    color = {
        background = Color(0, 0, 0, 0.75)
    },
    contents = {
        UIComponent.Button_MainMenu {
            title = "Return to Game",
            size = ResponsiveSize(200, 40, true),
            font = { name = "Unageo-Medium", size = 20 },
            callback = function()
                LimitTheoryRedux:closePauseMenu()
            end
        },
        UIComponent.Button_MainMenu {
            title = "Settings",
            size = ResponsiveSize(200, 40, true),
            font = { name = "Unageo-Medium", size = 20 },
            align = { AlignHorizontal.Center, AlignVertical.Center },
            callback = function() UIRouter:getCurrentPage():setView("Settings") end
        },
        UIComponent.Button_MainMenu {
            title = "Back to Main Menu",
            size = ResponsiveSize(200, 40, true),
            font = { name = "Unageo-Medium", size = 20 },
            align = { AlignHorizontal.Center, AlignVertical.Center },
            callback = function() LimitTheoryRedux:returnToMainMenu() end
        },
        UIComponent.Button_MainMenu {
            title = "Exit",
            size = ResponsiveSize(200, 40, true),
            font = { name = "Unageo-Medium", size = 20 },
            callback = function()
                LimitTheoryRedux:exit() -- run pre-exit operations & exit game
            end
        }
    }
}

Paused:addContent(menuContainer)

return Paused
