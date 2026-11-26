-- Reputation bar text: chooses what EllesmereUI's reputation bar says (faction name, current
-- reputation in full or short numbers, out of the level's total, what's left, percentage, standing).
--
-- EllesmereUIActionBars paints the bar in a local UpdateRepBar (EUI_ActionBars_DataBars.lua). Just
-- before it sets the text it stores the values it resolved (paragon, friendship and renown aware) on
-- the live frame: _tipCurrent, _tipMaximum, _tipStanding. A post-hook on that one FontString's
-- SetText replaces the text with ours, built from those values. Colours, fill, visibility and the
-- tooltip all stay EUI's. Sync point: EllesmereUIActionBars 9.9.5.
local _, addon = ...

local floor, abs, format = math.floor, math.abs, string.format

local F = addon.NewFeature("RepText", {
    title = "Rep Bar Text",
    requires = "EllesmereUIActionBars",
    defaults = {
        enabled = true,
        showName = true,
        value = "currentMax", -- none | current | currentMax | remaining
        short = true,
        showPct = true,
        pctDecimals = 0,
        showStanding = true,
    },
})
if not F then return end

local VALUE_LABELS = {
    none = "None",
    current = "Current",
    currentMax = "Current / Total",
    remaining = "Remaining",
}
local VALUE_ORDER = { "none", "current", "currentMax", "remaining" }

local function Long(n)
    n = floor(n + 0.5)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
    return tostring(n)
end

-- 950 -> 950, 12345 -> 12.3k, 12000 -> 12k, 1234567 -> 1.2m.
local function Short(n)
    local a = abs(n)
    local s
    if a >= 999950 then
        s = format("%.1fm", n / 1e6)
    elseif a >= 1000 then
        s = format("%.1fk", n / 1e3)
    else
        return tostring(floor(n + 0.5))
    end
    return (s:gsub("%.0([km])$", "%1"))
end

-- What the bar should read; opt.noName drops the faction name, for narrow bars.
function F.Build(c, name, current, maximum, standing, opt)
    local num = c.short and Short or Long
    local parts = {}
    local value
    if c.value == "current" then
        value = num(current)
    elseif c.value == "currentMax" then
        value = num(current) .. "/" .. num(maximum)
    elseif c.value == "remaining" then
        value = num(maximum - current) .. " left"
    end
    if value then parts[#parts + 1] = value end
    if c.showPct then
        local d = floor(tonumber(c.pctDecimals) or 0)
        local pct = format("%." .. d .. "f%%", maximum > 0 and current / maximum * 100 or 0)
        parts[#parts + 1] = value and "(" .. pct .. ")" or pct
    end
    if c.showStanding and standing and standing ~= "" then parts[#parts + 1] = "[" .. standing .. "]" end
    local body = table.concat(parts, " ")
    if c.showName and name and not (opt and opt.noName) then
        return body ~= "" and name .. ": " .. body or name
    end
    return body
end

local function LiveBar()
    local bar = _G.EllesmereEAB_RepBar
    if bar and bar._text and type(bar._updateFunc) == "function" then return bar end
end

local function WatchedName()
    local data = C_Reputation and C_Reputation.GetWatchedFactionData and C_Reputation.GetWatchedFactionData()
    return data and data.name
end

local hooked, busy = false, false

local function Repaint(text)
    local c = F.db
    local bar = LiveBar()
    local current, maximum = bar and bar._tipCurrent, bar and bar._tipMaximum
    if not (c and c.enabled and type(current) == "number" and type(maximum) == "number") then return end
    local name, standing = WatchedName(), bar._tipStanding

    -- Room along the bar: its width, or its height on a bar taller than it is wide (vertical).
    local w, h = bar:GetWidth() or 0, bar:GetHeight() or 0
    local room = (h > w and h or w) - 4

    busy = true
    text:SetText(F.Build(c, name, current, maximum, standing))
    if room > 0 and text:GetStringWidth() > room and c.showName then
        text:SetText(F.Build(c, name, current, maximum, standing, { noName = true }))
    end
    if room > 0 and text:GetStringWidth() > room then
        text:SetText(format("%.0f%%", maximum > 0 and current / maximum * 100 or 0))
    end
    busy = false
end

-- The live bar is built in EUI's own setup (none while it uses Blizzard's bars), so this is tried
-- again until it lands.
local function TryHook()
    if hooked then return true end
    if not F.db then return false end
    local bar = LiveBar()
    if not bar then return false end
    hooked = true
    hooksecurefunc(bar._text, "SetText", function(text)
        if not busy then Repaint(text) end
    end)
    bar._updateFunc()
    return true
end

-- Repaints the bar through EUI's own update, which ends in SetText and so in the hook.
function F.Refresh()
    local bar = LiveBar()
    if bar then bar._updateFunc() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(self)
    if TryHook() then return self:UnregisterAllEvents() end
    C_Timer.After(1, function()
        if TryHook() then self:UnregisterAllEvents() end
    end)
end)

local R = addon.Rows(F, F.Refresh)
local OFF = { disabled = function() return not F.db.enabled end, disabledTooltip = "Custom Text" }

local function Row(key, kind, text, opt)
    opt.disabled, opt.disabledTooltip, opt.refreshPage = OFF.disabled, OFF.disabledTooltip, true
    return R.Row(key, kind, text, opt)
end

local function Example()
    local bar = LiveBar()
    local c = F.db
    if bar and type(bar._tipCurrent) == "number" and type(bar._tipMaximum) == "number" and WatchedName() then
        return F.Build(c, WatchedName(), bar._tipCurrent, bar._tipMaximum, bar._tipStanding)
    end
    return F.Build(c, "Ironforge", 4321, 12000, "Honored")
end

F.AddPage("ActionBars", "Rep Bar Text", function(W, parent, y)
    TryHook()
    y = addon.Header(W, parent, y, "REPUTATION BAR TEXT")
    y = addon.Pair(W, parent, y,
        R.Row("enabled", "toggle", "Custom Text", {
            tooltip = "Builds the reputation bar's text from the settings here. Off hands it back to EllesmereUI's own text.",
            refreshPage = true,
        }),
        Row("showName", "toggle", "Faction Name", { tooltip = "Starts the text with the watched faction's name." }))
    y = addon.Pair(W, parent, y,
        Row("value", "dropdown", "Reputation", {
            tooltip = "Current: earned in this standing. Current / Total: out of what the standing needs. "
                .. "Remaining: what's left to the next standing.",
            values = VALUE_LABELS, order = VALUE_ORDER,
        }),
        Row("short", "toggle", "Short Numbers", { tooltip = "12.3k instead of 12,345." }))
    y = addon.Pair(W, parent, y,
        Row("showPct", "toggle", "Percentage", { tooltip = "Progress through this standing." }),
        Row("pctDecimals", "slider", "Percentage Decimals", { min = 0, max = 2, step = 1 }))
    y = addon.Pair(W, parent, y,
        Row("showStanding", "toggle", "Standing", { tooltip = "Friendly, Honored, Paragon and so on, in brackets." }))

    if not LiveBar() then
        y = addon.Note(parent, y, "EllesmereUI's reputation bar isn't built: it's off, or Use Blizzard's Rep Bars is on "
            .. "(Action Bars > Menu, Bags & Rep Bars).", { warning = true })
    end
    local example = F.db.enabled and Example() or "EllesmereUI's own text"
    y = addon.Note(parent, y, "Reads: " .. (example ~= "" and example or "(nothing)"))
    return addon.Note(parent, y, "On a bar too narrow for it, the name is dropped first, then everything but the percentage.")
end)
