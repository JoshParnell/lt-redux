---@type UIView
local Docked = UICore.View {
    name = "Docked",
    noDarken = true -- keep the station in view beside the panel
}

---@type ResponsiveSize
local ResponsiveSize = require("Types.ResponsiveSize")

-- NOTE: docking itself is owned by LimitTheoryRedux:dockAt/undock.

local tabs = { "Market", "Jobs", "Equipment" }
local currentTab = 1

function Docked:onInput() end

function Docked:onUpdate(dt) end

function Docked:onViewOpen(isPageOpen) end

function Docked:onViewClose(isPageClose) end

---@param index integer
local function tabButton(index)
    return UIComponent.Button_MainMenu {
        title = tabs[index],
        size = ResponsiveSize(140, 40, true),
        font = { name = "Unageo-Medium", size = 18 },
        align = { AlignHorizontal.Center, AlignVertical.Center },
        callback = function() currentTab = index end
    }
end

local dockedGrid = UILayout.Grid {
    align = { AlignHorizontal.Stretch, AlignVertical.Stretch },
    padding = { 60, 60 },
    margin = { 0, 0 },
    stackDirection = GuiLayoutType.Horizontal,
    contents = {
        UILayout.Grid {
            align = { AlignHorizontal.Stretch, AlignVertical.Stretch },
            padding = { 30, 30 },
            margin = { 0, 0 },
            widthInLayout = 0.34,
            layoutType = GuiLayoutType.Vertical,
            color = {
                background = Color(0, 0, 0, 0.6)
            },
            contents = {
                UIComponent.Container {
                    align = { AlignHorizontal.Stretch, AlignVertical.Stretch },
                    childrenAlign = { AlignHorizontal.Left, AlignVertical.Top },
                    spacing = 12,
                    layoutType = GuiLayoutType.Vertical,
                    heightInLayout = 0.15,
                    contents = {
                        UIComponent.Text {
                            text = function() return LimitTheoryRedux:getDockedStationName() end,
                            font = "Unageo-Medium",
                            size = 32
                        },
                        UIComponent.Text {
                            text = "DOCKED",
                            font = "Unageo-Regular",
                            size = 14,
                            color = Color(0.7, 0.7, 0.7, 1.0)
                        }
                    }
                },
                UIComponent.Container {
                    align = { AlignHorizontal.Stretch, AlignVertical.Stretch },
                    childrenAlign = { AlignHorizontal.Left, AlignVertical.Center },
                    spacing = 8,
                    layoutType = GuiLayoutType.Horizontal,
                    heightInLayout = 0.1,
                    contents = { tabButton(1), tabButton(2), tabButton(3) }
                },
                UIComponent.Container {
                    align = { AlignHorizontal.Stretch, AlignVertical.Stretch },
                    childrenAlign = { AlignHorizontal.Left, AlignVertical.Top },
                    padding = { 0, 20 },
                    layoutType = GuiLayoutType.Vertical,
                    heightInLayout = 0.6,
                    contents = {
                        UIComponent.Text {
                            text = function() return tabs[currentTab] .. ": coming soon" end,
                            font = "Unageo-Regular",
                            size = 20
                        }
                    }
                },
                UIComponent.Container {
                    align = { AlignHorizontal.Stretch, AlignVertical.Stretch },
                    childrenAlign = { AlignHorizontal.Left, AlignVertical.Bottom },
                    layoutType = GuiLayoutType.Vertical,
                    heightInLayout = 0.15,
                    contents = {
                        UIComponent.Button_MainMenu {
                            title = "Undock",
                            size = ResponsiveSize(200, 40, true),
                            font = { name = "Unageo-Medium", size = 20 },
                            align = { AlignHorizontal.Left, AlignVertical.Center },
                            callback = function() LimitTheoryRedux:undock() end
                        }
                    }
                }
            }
        },
        UIComponent.Container {
            align = { AlignHorizontal.Stretch, AlignVertical.Stretch },
            widthInLayout = 0.66,
            contents = {}
        }
    }
}

Docked:addContent(dockedGrid)

return Docked
