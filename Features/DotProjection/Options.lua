-- DoT Projection options: the Projection and Lethal pages. Rows only write F.db and ask Plates.lua to redraw.
local _, addon = ...
local F = addon.GetFeature("DotProjection")
if not F then return end

local Header, Pair = addon.Header, addon.Pair
local R = addon.Rows(F, function() F.RefreshPlates() end)

local ACCENT_TIP = "Turn off Accent colour first."

-- A colour that can follow the accent: the picker is locked while it does.
local function AccentColor(key)
    return R.Color(key, "Colour", {
        accentKeepsColor = true, disabled = R.FollowsAccent(key), disabledTooltip = ACCENT_TIP,
    })
end

-- Glow styles that suit a bar: EUI's list without Shape Glow (needs a mask) and Blackout (a fill).
local function GlowChoices()
    local values, order = {}, {}
    local G = EllesmereUI.Glows
    for i, style in ipairs(G and G.STYLES or {}) do
        if not style.shapeGlow and not style.solidFill then
            values[i] = style.name
            order[#order + 1] = i
        end
    end
    return values, order
end

local function Button(W, parent, y, text, onClick)
    local _, h = W:WideButton(parent, text, y, onClick)
    return y - (h or 0)
end

F.AddPage("Nameplates", "DoT Projection", function(W, parent, y)
    y = Header(W, parent, y, "PROJECTION")
    y = Pair(W, parent, y,
        R.Row("projection", "toggle", "Show projection", { tooltip = "Health your DoTs will still take." }),
        R.Row("texture", "dropdown", "Texture", { values = F.TEXTURES.values, order = F.TEXTURES.order }))
    y = Pair(W, parent, y,
        R.Color("color", "Colour"),
        R.Row("endLine", "toggle", "End line", { tooltip = "Where health ends up." }))
    y = Pair(W, parent, y, R.Color("endLineColor", "End line colour"))

    y = Header(W, parent, y, "TRACKING")
    y = Pair(W, parent, y, R.Row("waitFirstTick", "dropdown", "Wait for first tick", {
        values = F.WAIT_MODES.values, order = F.WAIT_MODES.order,
        tooltip = "Hold a new DoT back until it ticks.",
    }))
    y = Button(W, parent, y, "Preview on target", function() F.StartTest() end)
    return Button(W, parent, y, "Forget learned ticks", F.ForgetTicks)
end)

F.AddPage("Nameplates", "DoT Lethal", function(W, parent, y)
    y = Header(W, parent, y, "FILL")
    y = Pair(W, parent, y, R.Row("lethalColor", "toggle", "Recolour when lethal"), AccentColor("lethalFill"))
    y = Pair(W, parent, y, R.AccentToggle("lethalFill"))

    y = Header(W, parent, y, "GLOW")
    local glowValues, glowOrder = GlowChoices()
    y = Pair(W, parent, y,
        R.Row("glow", "toggle", "Glow when lethal"),
        R.Row("glowStyle", "dropdown", "Style", { values = glowValues, order = glowOrder }))
    y = Pair(W, parent, y, AccentColor("glowColor"), R.AccentToggle("glowColor"))

    y = Header(W, parent, y, "KILL ICON")
    y = Pair(W, parent, y,
        R.Row("killIcon", "toggle", "Kill icon"),
        R.Row("icon", "dropdown", "Icon", { values = F.ICONS.values, order = F.ICONS.order }))
    y = Pair(W, parent, y,
        R.Row("iconPosition", "dropdown", "Position", { values = F.ICON_POSITIONS.values, order = F.ICON_POSITIONS.order }),
        R.Row("iconSize", "slider", "Size", { min = 10, max = 32, step = 1 }))
    y = Pair(W, parent, y,
        R.Row("iconOffsetX", "slider", "Offset X", { min = -40, max = 40, step = 1 }),
        R.Row("iconOffsetY", "slider", "Offset Y", { min = -40, max = 40, step = 1 }))

    y = Header(W, parent, y, "ANIMATION")
    return Pair(W, parent, y, R.Row("pulse", "toggle", "Pulse when lethal"))
end)
