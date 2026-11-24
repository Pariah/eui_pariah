-- Threat % position: puts EllesmereUI's nameplate threat % text anywhere around the health bar
-- (inside it, or outside on any side or corner), plus free X / Y offsets.
--
-- EllesmereUINameplates lays the text out in ApplyThreatPctPos(plate), looked up on its namespace
-- each time it paints (EUI_Nameplates_Overlays.lua, NP_UpdateThreatPct). That one function is
-- replaced: with Custom Position off it hands straight back to EUI's. Size, font, colour, Threat Gap
-- mode and the on/off toggle all stay EUI's. Sync point: EllesmereUINameplates 9.8.5.
local _, addon = ...

local NP = _G.EllesmereNameplates_NS
local hooked = NP and type(NP.ApplyThreatPctPos) == "function" and type(NP.EnsureThreatPctText) == "function"
    and type(NP.SetFSFont) == "function" and type(NP.GetFont) == "function" and type(NP.GetNPOutline) == "function"

local function Refresh()
    if hooked and NP.RefreshThreatPct then NP.RefreshThreatPct() end
end

local F = addon.NewFeature("ThreatPct", {
    title = "Threat Text",
    requires = "EllesmereUINameplates",
    defaults = {
        enabled = true,
        position = "OUT_TOPRIGHT",
        x = 0,
        y = 2,
    },
    -- Plates already painted before the settings loaded pick them up now.
    onLoad = Refresh,
})
if not F then return end

-- point: the text's own anchor; rel: the health bar point it sits on.
-- ix: EUI's inset for its Inside Left / Inside Right slots, so those match EUI's at offset 0.
local POSITIONS = {
    IN_TOPLEFT      = { label = "Inside Top Left",      point = "TOPLEFT",     rel = "TOPLEFT",     ix = 4 },
    IN_TOP          = { label = "Inside Top",           point = "TOP",         rel = "TOP" },
    IN_TOPRIGHT     = { label = "Inside Top Right",     point = "TOPRIGHT",    rel = "TOPRIGHT",    ix = -2 },
    IN_LEFT         = { label = "Inside Left",          point = "LEFT",        rel = "LEFT",        ix = 4 },
    IN_CENTER       = { label = "Inside Center",        point = "CENTER",      rel = "CENTER" },
    IN_RIGHT        = { label = "Inside Right",         point = "RIGHT",       rel = "RIGHT",       ix = -2 },
    IN_BOTTOMLEFT   = { label = "Inside Bottom Left",   point = "BOTTOMLEFT",  rel = "BOTTOMLEFT",  ix = 4 },
    IN_BOTTOM       = { label = "Inside Bottom",        point = "BOTTOM",      rel = "BOTTOM" },
    IN_BOTTOMRIGHT  = { label = "Inside Bottom Right",  point = "BOTTOMRIGHT", rel = "BOTTOMRIGHT", ix = -2 },
    OUT_TOPLEFT     = { label = "Outside Top Left",     point = "BOTTOMLEFT",  rel = "TOPLEFT" },
    OUT_TOP         = { label = "Outside Top",          point = "BOTTOM",      rel = "TOP" },
    OUT_TOPRIGHT    = { label = "Outside Top Right",    point = "BOTTOMRIGHT", rel = "TOPRIGHT" },
    OUT_LEFT        = { label = "Outside Left",         point = "RIGHT",       rel = "LEFT" },
    OUT_RIGHT       = { label = "Outside Right",        point = "LEFT",        rel = "RIGHT" },
    OUT_BOTTOMLEFT  = { label = "Outside Bottom Left",  point = "TOPLEFT",     rel = "BOTTOMLEFT" },
    OUT_BOTTOM      = { label = "Outside Bottom",       point = "TOP",         rel = "BOTTOM" },
    OUT_BOTTOMRIGHT = { label = "Outside Bottom Right", point = "TOPRIGHT",    rel = "BOTTOMRIGHT" },
}
local ORDER = {
    "IN_TOPLEFT", "IN_TOP", "IN_TOPRIGHT", "IN_LEFT", "IN_CENTER", "IN_RIGHT",
    "IN_BOTTOMLEFT", "IN_BOTTOM", "IN_BOTTOMRIGHT",
    "OUT_TOPLEFT", "OUT_TOP", "OUT_TOPRIGHT", "OUT_LEFT", "OUT_RIGHT",
    "OUT_BOTTOMLEFT", "OUT_BOTTOM", "OUT_BOTTOMRIGHT",
}
local LABELS = {}
for key, pos in pairs(POSITIONS) do
    LABELS[key] = pos.label
    pos.justify = (pos.point:find("LEFT") and "LEFT") or (pos.point:find("RIGHT") and "RIGHT") or "CENTER"
end
F.POSITIONS = POSITIONS -- for the offline test

if hooked then
    local PP = EllesmereUI.PP
    local euiApply = NP.ApplyThreatPctPos

    -- Same memo fields as EUI's (plate._tpt*), with the position key prefixed, so switching
    -- Custom Position off makes EUI's function see a changed key and lay the text out again.
    NP.ApplyThreatPctPos = function(plate)
        local c = F.db
        if not (c and c.enabled) then return euiApply(plate) end
        local key = POSITIONS[c.position] and c.position or "OUT_TOPRIGHT"
        local pos = POSITIONS[key]
        NP.EnsureThreatPctText(plate)
        local prof = NP.db and NP.db.profile
        local size = (prof and prof.threatPctSize) or (NP.defaults and NP.defaults.threatPctSize) or 10
        local x, y = tonumber(c.x) or 0, tonumber(c.y) or 0
        local font, outline = NP.GetFont(), NP.GetNPOutline()
        local memoKey = "euit:" .. key
        if plate._tptPos ~= memoKey or plate._tptSize ~= size
            or plate._tptX ~= x or plate._tptY ~= y
            or plate._tptFont ~= font or plate._tptOutline ~= outline then
            plate._tptPos = memoKey
            plate._tptSize = size
            plate._tptX = x
            plate._tptY = y
            plate._tptFont = font
            plate._tptOutline = outline
            local fs = plate.threatPctText
            NP.SetFSFont(fs, size, outline)
            fs:ClearAllPoints()
            PP.Point(fs, pos.point, plate.health, pos.rel, (pos.ix or 0) + x, y)
            fs:SetJustifyH(pos.justify)
        end
    end
end

local R = addon.Rows(F, Refresh)
local CUSTOM_OFF = { disabled = function() return not F.db.enabled end, disabledTooltip = "Custom Position" }

local function Offset(key, text, tooltip)
    return R.Row(key, "slider", text, {
        min = -300, max = 300, step = 1, tooltip = tooltip,
        disabled = CUSTOM_OFF.disabled, disabledTooltip = CUSTOM_OFF.disabledTooltip,
    })
end

F.AddPage("Nameplates", "Threat Text", function(W, parent, y)
    y = addon.Header(W, parent, y, "THREAT % POSITION")
    if not hooked then
        return addon.Note(parent, y, "EllesmereUI Nameplates changed how it lays out the threat text. Nothing to do here.",
            { warning = true })
    end

    y = addon.Pair(W, parent, y,
        R.Row("enabled", "toggle", "Custom Position", {
            tooltip = "Lays out the nameplate Threat % text from the settings here. Off hands it back to EllesmereUI's own Threat % Position.",
            refreshPage = true,
        }),
        R.Row("position", "dropdown", "Position", {
            tooltip = "Inside sits on the health bar; Outside sits just past its edge.",
            values = LABELS, order = ORDER,
            disabled = CUSTOM_OFF.disabled, disabledTooltip = CUSTOM_OFF.disabledTooltip,
        }))
    y = addon.Pair(W, parent, y,
        Offset("x", "X Offset", "Positive moves right. Type a value in the box for exact placement."),
        Offset("y", "Y Offset", "Positive moves up. Type a value in the box for exact placement."))

    return addon.Note(parent, y, "Needs \"Show Threat % on Nameplates\" on (Nameplates > Enemy Colors). While Custom Position is on, "
        .. "that page's Threat % Position and its X / Y offsets are ignored; size, colour and Threat Gap still come from there. "
        .. "The text only shows on mobs you have threat on, so test on a dummy.", { height = 50 })
end)
