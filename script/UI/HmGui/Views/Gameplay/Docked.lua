---@type UIView
local Docked = UICore.View {
    name = "Docked",
    noDarken = true -- keep the station in view beside the panel
}

---@type ResponsiveSize
local ResponsiveSize = require("Types.ResponsiveSize")

-- NOTE: docking itself is owned by LimitTheoryRedux:dockAt/undock.
-- Everything below the station name is placeholder content, seeded per station.

local tabs = { "Market", "Jobs", "Equipment", "Station" }
local currentTab = 1

local Colors = {
    text     = Color(0.92, 0.94, 0.96, 1.0),
    dim      = Color(0.62, 0.66, 0.70, 1.0),
    faint    = Color(0.42, 0.45, 0.50, 1.0),
    accent   = Color(0.36, 0.74, 1.00, 1.0),
    good     = Color(0.45, 0.88, 0.55, 1.0),
    bad      = Color(1.00, 0.48, 0.42, 1.0),
    warn     = Color(1.00, 0.78, 0.35, 1.0),
    rowAlt   = Color(1.0, 1.0, 1.0, 0.03),
    rowHover = Color(0.36, 0.74, 1.00, 0.12),
    card     = Color(1.0, 1.0, 1.0, 0.04),
    barBack  = Color(1.0, 1.0, 1.0, 0.08),
    panel    = Color(0.0, 0.0, 0.0, 0.78),
}

local commodities = {
    { "Water Ice", 12 }, { "Iron Ore", 28 }, { "Silicates", 19 }, { "Refined Alloys", 140 },
    { "Fuel Cells", 85 }, { "Hydroponic Food", 46 }, { "Medical Supplies", 310 }, { "Data Cores", 720 },
    { "Luxury Goods", 1150 }, { "Antimatter Pods", 2400 },
}

local jobTemplates = {
    { kind = "Courier", title = "Deliver a sealed data core to %s", issuer = "Halvorsen Logistics", reward = { 1800, 3200 }, risk = 1, color = Colors.accent },
    { kind = "Escort", title = "Escort an ore convoy to %s", issuer = "Mining Guild", reward = { 4000, 7000 }, risk = 3, color = Colors.warn },
    { kind = "Bounty", title = "Destroy the pirate cutter 'Mongrel'", issuer = "Station Security", reward = { 9000, 15000 }, risk = 4, color = Colors.bad },
    { kind = "Survey", title = "Scan the asteroid belt beyond %s", issuer = "Cartography Bureau", reward = { 1200, 2400 }, risk = 1, color = Colors.accent },
    { kind = "Salvage", title = "Recover a black box from a derelict freighter", issuer = "Corvid Underwriters", reward = { 3000, 5000 }, risk = 2, color = Colors.warn },
    { kind = "Smuggling", title = "No questions asked: crates to %s", issuer = "Unknown", reward = { 12000, 20000 }, risk = 5, color = Colors.bad },
    { kind = "Supply", title = "Supply 200 t of iron ore", issuer = "Foundry Collective", reward = { 5200, 7600 }, risk = 1, color = Colors.good },
    { kind = "Patrol", title = "Patrol the inner lane for 30 minutes", issuer = "Station Security", reward = { 2600, 4200 }, risk = 2, color = Colors.warn },
}

local equipment = {
    { "Railgun Mk I", 8400 }, { "Shield Booster", 3100 }, { "Cargo Pod Expansion", 2250 }, { "Scanner Array", 1600 },
    { "Point Defense Turret", 5900 }, { "Afterburner Mk II", 4700 }, { "Tractor Beam", 2800 },
}

local hardpoints = {
    { "WEAPON 1", "Pulse Laser Mk II" }, { "WEAPON 2", nil }, { "UTILITY", "Mining Beam Mk I" },
    { "DRIVE", "Travel Drive TD-3" },
}

local stationTypes = { "Orbital Trade Hub", "Refinery Platform", "Shipyard", "Research Outpost", "Mining Depot" }
local factions = { "Free Traders Union", "Halcyon Combine", "Independent", "Meridian Accord" }
local securityLevels = { { "Low", Colors.bad }, { "Moderate", Colors.warn }, { "High", Colors.good } }

local headlines = {
    "Ore prices climb as belt output stalls",
    "Pirate activity reported along the outer lane",
    "Station council approves a new docking ring",
    "Medical shortage eases after convoy arrives",
    "Unidentified signal detected near the gas giant",
    "Local pilot sets a new courier record",
    "Fuel cell tariffs cut by 2% this cycle",
    "Derelict freighter spotted drifting near the ring",
}

---@param seed EntityId
---@return fun(lo: number, hi: number): number uniform in [lo, hi)
local function rngFor(seed)
    local s = tonumber(seed) % 2147483646 * 7919 % 2147483646 + 1
    return function(lo, hi)
        s = s * 16807 % 2147483647
        return lo + (hi - lo) * (s / 2147483647)
    end
end

---@return table[] the first `n` of a shuffled copy of `list`
local function sample(rng, list, n)
    local pool = { unpack(list) }
    for i = 1, math.min(n, #pool) do
        local j = floor(rng(i, #pool + 1))
        pool[i], pool[j] = pool[j], pool[i]
    end
    return { unpack(pool, 1, math.min(n, #pool)) }
end

---@param n number
---@return string
local function commas(n)
    local s = tostring(floor(n + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (s:gsub("^,", ""))
end

local function otherStationNames(stationId)
    local names = {}
    for _, station in ipairs(LimitTheoryRedux.stations or {}) do
        if station.id ~= stationId then
            names[#names + 1] = LimitTheoryRedux.stationNames[station.id]
        end
    end
    if #names == 0 then names[1] = "the outer ring" end
    return names
end

local function buildData(station)
    local rng = rngFor(station.id)
    local d = { market = {}, jobs = {} }

    for _, c in ipairs(commodities) do
        local buy = c[2] * rng(0.8, 1.3)
        d.market[#d.market + 1] = {
            name = c[1], buy = buy, sell = buy * rng(0.86, 0.95), stock = rng(0.05, 1.0), trend = rng(-9, 9),
        }
    end

    local destinations = otherStationNames(station.id)
    for _, job in ipairs(sample(rng, jobTemplates, 5)) do
        d.jobs[#d.jobs + 1] = {
            kind = job.kind,
            title = format(job.title, destinations[floor(rng(1, #destinations + 1))]),
            detail = format("%s  ·  %.1f Mm  ·  %d min", job.issuer, rng(0.4, 9.0), floor(rng(8, 90))),
            reward = floor(rng(job.reward[1], job.reward[2]) / 50) * 50,
            risk = job.risk,
            color = job.color,
        }
    end

    d.forSale = sample(rng, equipment, 4)
    d.type, d.faction = stationTypes[floor(rng(1, #stationTypes + 1))], factions[floor(rng(1, #factions + 1))]
    d.security = securityLevels[floor(rng(1, #securityLevels + 1))]
    d.population, d.tariff = floor(rng(8, 120)) * 1000, rng(1, 8)
    d.news = sample(rng, headlines, 4)
    return d
end

local data, dataStationId

local function stationData()
    local station = LimitTheoryRedux:getDockedStation()
    if not station then return nil end
    if dataStationId ~= station.id then
        data, dataStationId = buildData(station), station.id
    end
    return data
end

-- Drawing helpers (immediate-mode Gui; each call adds widgets to the current container)

local function text(str, fontName, size, color)
    Gui:text(str, Cache.Font(fontName, size), color)
end

-- One line of text in a column `percent` wide
local function cell(percent, str, fontName, size, color, h)
    Gui:beginStackContainer()
    Gui:setPercentWidth(percent)
    -- Text is measured without descenders; leave room so the next row doesn't cover them
    Gui:setPaddingEx(0, 1, 0, 4)
    Gui:setChildrenAlignment(h or AlignHorizontal.Left, AlignVertical.Center)
    text(str, fontName, size, color)
    Gui:endContainer()
end

local function bar(fraction, color, height)
    Gui:beginStackContainer()
    Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Center)
    Gui:setFixedHeight(height)
    Gui:setBackgroundColor(Colors.barBack)
    Gui:rect()
    Gui:setAlignment(AlignHorizontal.Left, AlignVertical.Stretch)
    Gui:setPercentWidth(math.max(0, math.min(1, fraction)) * 100)
    Gui:setBackgroundColor(color)
    Gui:endContainer()
end

-- A bar in a column `percent` wide
local function barCell(percent, fraction, color)
    Gui:beginStackContainer()
    Gui:setPercentWidth(percent)
    Gui:setPadding(10, 0)
    bar(fraction, color, 5)
    Gui:endContainer()
end

local function beginColumn(spacing)
    Gui:beginVerticalContainer()
    Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Top)
    Gui:setSpacing(spacing or 0)
end

local function beginRow(index)
    Gui:beginHorizontalContainer()
    Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Top)
    Gui:setChildrenAlignment(AlignHorizontal.Left, AlignVertical.Center)
    Gui:setPadding(8, 3)
    if Gui:isMouseOver(FocusType.Mouse) then
        Gui:setBackgroundColor(Colors.rowHover)
    elseif index and index % 2 == 0 then
        Gui:setBackgroundColor(Colors.rowAlt)
    end
end

local function sectionTitle(str)
    Gui:beginStackContainer()
    Gui:setPadding(8, 6)
    text(str:upper(), "Unageo-Semibold", 11, Colors.faint)
    Gui:endContainer()
end

local function stockColor(fraction)
    return fraction < 0.25 and Colors.bad or (fraction < 0.5 and Colors.warn or Colors.accent)
end

local function riskColor(risk)
    return risk >= 4 and Colors.bad or (risk >= 2 and Colors.warn or Colors.good)
end

-- Tabs

local function renderMarket(d)
    beginColumn(1)

    Gui:beginHorizontalContainer()
    Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Top)
    Gui:setPadding(8, 4)
    cell(36, "COMMODITY", "Unageo-Semibold", 11, Colors.faint)
    cell(16, "BUY", "Unageo-Semibold", 11, Colors.faint, AlignHorizontal.Right)
    cell(16, "SELL", "Unageo-Semibold", 11, Colors.faint, AlignHorizontal.Right)
    cell(20, "STOCK", "Unageo-Semibold", 11, Colors.faint, AlignHorizontal.Center)
    cell(12, "24H", "Unageo-Semibold", 11, Colors.faint, AlignHorizontal.Right)
    Gui:endContainer()

    for i, item in ipairs(d.market) do
        beginRow(i)
        cell(36, item.name, "Unageo-Regular", 14, Colors.text)
        cell(16, commas(item.buy), "ShareTechMono", 14, Colors.text, AlignHorizontal.Right)
        cell(16, commas(item.sell), "ShareTechMono", 14, Colors.dim, AlignHorizontal.Right)
        barCell(20, item.stock, stockColor(item.stock))
        cell(12, format("%+.1f%%", item.trend), "ShareTechMono", 13,
            item.trend >= 0 and Colors.good or Colors.bad, AlignHorizontal.Right)
        Gui:endContainer()
    end

    Gui:endContainer()
end

local function renderJobs(d)
    beginColumn(6)

    for _, job in ipairs(d.jobs) do
        Gui:beginHorizontalContainer()
        Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Top)
        Gui:setChildrenAlignment(AlignHorizontal.Left, AlignVertical.Center)
        Gui:setBackgroundColor(Gui:isMouseOver(FocusType.Mouse) and Colors.rowHover or Colors.card)

        Gui:rect()
        Gui:setFixedWidth(3)
        Gui:setAlignment(AlignHorizontal.Left, AlignVertical.Stretch)
        Gui:setBackgroundColor(job.color)

        Gui:beginVerticalContainer()
        Gui:setPercentWidth(72)
        Gui:setPadding(12, 8)
        Gui:setSpacing(3)
        text(job.kind:upper(), "Unageo-Semibold", 11, job.color)
        text(job.title, "Unageo-Medium", 15, Colors.text)
        text(job.detail, "Unageo-Regular", 12, Colors.dim)
        Gui:endContainer()

        Gui:beginVerticalContainer()
        Gui:setPercentWidth(27)
        Gui:setPadding(12, 8)
        Gui:setSpacing(8)
        Gui:setChildrenAlignment(AlignHorizontal.Right, AlignVertical.Center)
        text(commas(job.reward) .. " cr", "ShareTechMono", 16, Colors.good)
        Gui:beginHorizontalContainer()
        Gui:setSpacing(3)
        for pip = 1, 5 do
            Gui:rect()
            Gui:setFixedSize(10, 4)
            Gui:setBackgroundColor(pip <= job.risk and riskColor(job.risk) or Colors.barBack)
        end
        Gui:endContainer()
        Gui:endContainer()

        Gui:endContainer()
    end

    Gui:endContainer()
end

local function statRow(label, fraction, value, color)
    beginRow()
    cell(30, label, "Unageo-Regular", 13, Colors.dim)
    barCell(50, fraction, color)
    cell(20, value, "ShareTechMono", 13, Colors.text, AlignHorizontal.Right)
    Gui:endContainer()
end

local function renderEquipment(d)
    beginColumn(1)

    sectionTitle("Ship Systems")
    statRow("Hull", 1.0, "100%", Colors.good)
    statRow("Shields", 0.82, "82%", Colors.accent)
    statRow("Capacitor", 0.64, "64%", Colors.warn)
    statRow("Cargo", 12 / 40, "12 / 40 t", Colors.dim)

    sectionTitle("Hardpoints")
    for i, slot in ipairs(hardpoints) do
        beginRow(i)
        cell(30, slot[1], "Unageo-Semibold", 11, Colors.faint)
        cell(70, slot[2] or "Empty", "Unageo-Regular", 14, slot[2] and Colors.text or Colors.faint)
        Gui:endContainer()
    end

    sectionTitle("For Sale")
    for i, item in ipairs(d.forSale) do
        beginRow(i)
        cell(60, item[1], "Unageo-Regular", 14, Colors.text)
        cell(28, commas(item[2]) .. " cr", "ShareTechMono", 14, Colors.dim, AlignHorizontal.Right)
        cell(12, "BUY", "Unageo-Semibold", 11, Colors.accent, AlignHorizontal.Right)
        Gui:endContainer()
    end

    Gui:endContainer()
end

local function infoRow(i, label, value, color)
    beginRow(i)
    cell(35, label, "Unageo-Regular", 13, Colors.dim)
    cell(65, value, "Unageo-Medium", 14, color or Colors.text)
    Gui:endContainer()
end

local function renderStation(d)
    beginColumn(1)

    sectionTitle("Registry")
    infoRow(1, "Type", d.type)
    infoRow(2, "Faction", d.faction)
    infoRow(3, "Population", commas(d.population))
    infoRow(4, "Security", d.security[1], d.security[2])
    infoRow(5, "Docking Tariff", format("%.1f%%", d.tariff))

    sectionTitle("Local News")
    for i, headline in ipairs(d.news) do
        beginRow(i)
        cell(15, format("%02d:%02d", (7 + i * 3) % 24, (i * 17) % 60), "ShareTechMono", 13, Colors.faint)
        cell(85, headline, "Unageo-Regular", 14, Colors.text)
        Gui:endContainer()
    end

    Gui:endContainer()
end

local tabRenderers = { renderMarket, renderJobs, renderEquipment, renderStation }

-- Panel sections, sized by share of the panel height like the Grid's other children

---@param heightInLayout number
---@param render fun()
local function section(heightInLayout, render)
    return {
        state = { heightInLayout = function() return heightInLayout end },
        render = function()
            Gui:beginVerticalContainer()
            Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Stretch)
            render()
            Gui:endContainer()
        end,
    }
end

local header = section(0.14, function()
    Gui:setSpacing(6)
    text(LimitTheoryRedux:getDockedStationName(), "Unageo-Medium", 32, Colors.text)
    local d = stationData()
    if d then
        text(format("DOCKED  ·  BAY 7  ·  %s", d.faction:upper()), "Unageo-Regular", 13, Colors.dim)
    end
end)

local tabBar = section(0.08, function()
    Gui:setChildrenAlignment(AlignHorizontal.Left, AlignVertical.Bottom)
    Gui:beginHorizontalContainer()
    Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Bottom)
    Gui:setSpacing(22)
    for i, name in ipairs(tabs) do
        Gui:beginVerticalContainer()
        Gui:setSpacing(6)
        local hover = Gui:isMouseOver(FocusType.Mouse)
        local active = i == currentTab
        text(name:upper(), "Unageo-Semibold", 14,
            (active or hover) and Colors.text or Colors.faint)
        Gui:rect()
        Gui:setFixedHeight(2)
        Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Top)
        Gui:setBackgroundColor(active and Colors.accent or Colors.barBack)
        Gui:endContainer()
        if hover and Input:mouse():isPressed(MouseControl.Left) then currentTab = i end
    end
    Gui:endContainer()
end)

local content = section(0.66, function()
    Gui:setPadding(0, 12)
    local d = stationData()
    if d then tabRenderers[currentTab](d) end
end)

local undockButton = UIComponent.Button_MainMenu {
    title = "Undock",
    size = ResponsiveSize(200, 40, true),
    font = { name = "Unageo-Medium", size = 20 },
    align = { AlignHorizontal.Right, AlignVertical.Center },
    callback = function() LimitTheoryRedux:undock() end
}

local footer = section(0.12, function()
    Gui:setChildrenAlignment(AlignHorizontal.Stretch, AlignVertical.Bottom)
    Gui:beginHorizontalContainer()
    Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Bottom)
    Gui:setChildrenAlignment(AlignHorizontal.Left, AlignVertical.Center)

    Gui:beginVerticalContainer()
    Gui:setPercentWidth(55)
    Gui:setSpacing(4)
    text("CREDITS", "Unageo-Semibold", 11, Colors.faint)
    text("12,480 cr", "ShareTechMono", 20, Colors.text)
    Gui:endContainer()

    Gui:beginStackContainer()
    Gui:setPercentWidth(45)
    Gui:setChildrenAlignment(AlignHorizontal.Right, AlignVertical.Center)
    undockButton:render()
    Gui:endContainer()

    Gui:endContainer()
end)

-- Station chatter in the corner, leaving the station itself in view
local comms = {
    "Dock Control: Welcome aboard, pilot. Bay 7 is yours.",
    "Station Security: Weapons are locked while docked.",
    "Market: Prices updated for this cycle.",
    "Halvorsen Logistics: Courier contracts available.",
}

local commsPanel = {
    state = { widthInLayout = function() return 0.58 end },
    render = function()
        Gui:beginStackContainer()
        Gui:setAlignment(AlignHorizontal.Stretch, AlignVertical.Stretch)
        Gui:setChildrenAlignment(AlignHorizontal.Right, AlignVertical.Bottom)

        Gui:beginVerticalContainer()
        Gui:setFixedWidth(440)
        Gui:setPadding(18, 14)
        Gui:setSpacing(6)
        Gui:setBackgroundColor(Color(0, 0, 0, 0.45))
        text("COMMS", "Unageo-Semibold", 11, Colors.faint)
        for i, line in ipairs(comms) do
            local source, message = line:match("^(.-): (.*)$")
            Gui:beginHorizontalContainer()
            Gui:setSpacing(8)
            text(format("%02d:%02d", 9, 40 + i), "ShareTechMono", 12, Colors.faint)
            text(source, "Unageo-Semibold", 12, Colors.accent)
            text(message, "Unageo-Regular", 12, Colors.dim)
            Gui:endContainer()
        end
        Gui:endContainer()

        Gui:endContainer()
    end,
}

function Docked:onInput() end

function Docked:onUpdate(dt) end

function Docked:onViewOpen(isPageOpen) end

function Docked:onViewClose(isPageClose) end

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
            widthInLayout = 0.42,
            layoutType = GuiLayoutType.Vertical,
            color = { background = Colors.panel },
            contents = { header, tabBar, content, footer }
        },
        commsPanel
    }
}

Docked:addContent(dockedGrid)

return Docked
