-- EUI DoT Projection plates: draws on EllesmereUI Nameplates' own health bars (EllesmereNameplates_NS.plates[unit].health).
--
-- Health is secret in combat, so Lua never compares health with DoT damage. StatusBars take the secret values and
-- the geometry does the comparing:
--   * Projection: a reverse-filling bar whose right edge is the health fill's end, max = max health, value = DoT
--     damage. Its fill covers the health the DoTs will still take; past the bar's left edge (lethal) it's clipped.
--   * Lethal gate: a very long bar ending at the health bar's right edge, max = health, value = DoT damage. Its fill
--     only reaches the plate when damage >= health. Each lethal effect sits in a clipping frame anchored to that fill
--     end, so it clips to nothing until the DoTs are lethal, then lands exactly where the effect belongs.

local _, addon = ...
local F = addon.GetFeature("DotProjection")
if not F then return end

local WHITE = "Interface\\Buttons\\WHITE8X8"
local UPDATE_INTERVAL = 0.1
-- Lethal effects start to slide in over the last (effect width / GATE_LENGTH) of health, about 0.2%.
local GATE_LENGTH = 100000
local GLOW_MARGIN = 16
local ICON_GAP = 4
local TEST_SECONDS = 5
local TEST_PARTIAL = 0.3

local NP -- EllesmereNameplates_NS
local widgets = {} -- EUI plate frame -> our widgets (EUI pools its plates, so this stays bounded)

function F.PlatesReady()
    NP = _G.EllesmereNameplates_NS
    return type(NP) == "table" and type(NP.plates) == "table"
end

local function PlainNumber(value)
    return type(value) == "number" and not F.IsSecret(value) and value or nil
end

local function InvisibleBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0, 0, 0, 0)
    return bar
end

-- A projection bar on `parent`: the texture spans the whole health bar (so stripes stay put, like EUI's focus
-- overlay) and is clipped to the bar's (invisible) fill; end line at the fill's left end.
local function NewProjection(parent, fill, health)
    local bar = InvisibleBar(parent)
    bar:SetReverseFill(true)
    bar:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
    bar:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
    local span = bar:GetStatusBarTexture()
    local spanClip = CreateFrame("Frame", nil, bar)
    spanClip:SetClipsChildren(true)
    spanClip:SetPoint("TOPLEFT", span, "TOPLEFT")
    spanClip:SetPoint("BOTTOMRIGHT", span, "BOTTOMRIGHT")
    local tex = spanClip:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(health)
    local line = bar:CreateTexture(nil, "OVERLAY")
    line:SetTexture(WHITE)
    line:SetPoint("TOPLEFT", span, "TOPLEFT")
    line:SetPoint("BOTTOMLEFT", span, "BOTTOMLEFT")
    line:SetWidth(1)
    return { bar = bar, tex = tex, line = line }
end

-- Clipping frame that is on the plate only while the DoTs are lethal (see the header).
local function NewGated(parent, gateEnd)
    local clip = CreateFrame("Frame", nil, parent)
    clip:SetClipsChildren(true)
    clip.gateEnd = gateEnd
    return clip
end

-- Puts a gated frame (size w x h) where its effect belongs: centre (dx, dy) from the health bar's right edge.
local function PlaceGated(clip, w, h, dx, dy)
    clip:SetSize(w, h)
    clip:ClearAllPoints()
    clip:SetPoint("CENTER", clip.gateEnd, "RIGHT", dx, dy)
end

local function NewPulse(frame)
    local group = frame:CreateAnimationGroup()
    group:SetLooping("BOUNCE")
    local fade = group:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.35)
    fade:SetDuration(0.5)
    fade:SetSmoothing("IN_OUT")
    return group
end

local function Create(plate)
    local health = plate.health
    local fill = health:GetStatusBarTexture()
    local level = PlainNumber(health:GetFrameLevel()) or 10
    local w = { health = health, fill = fill }

    w.root = CreateFrame("Frame", nil, health)
    w.root:SetAllPoints(health)
    w.root:SetFrameLevel(level + 1)

    w.clip = CreateFrame("Frame", nil, w.root)
    w.clip:SetAllPoints(health)
    w.clip:SetClipsChildren(true)
    w.clip:SetFrameLevel(level + 2)
    w.proj = NewProjection(w.clip, fill, health)

    w.gate = InvisibleBar(w.root)
    w.gate:SetSize(GATE_LENGTH, 1)
    w.gate:SetPoint("RIGHT", health, "RIGHT")
    local gateEnd = w.gate:GetStatusBarTexture()

    -- Lethal projection colour: a second projection, inside the health bar clip and the gate.
    w.lethalClip = NewGated(w.clip, gateEnd)
    w.lethalClip:SetFrameLevel(level + 3)
    w.lethalProj = NewProjection(w.lethalClip, fill, health)
    w.lethalProj.line:Hide()

    w.glowClip = NewGated(w.root, gateEnd)
    w.glowClip:SetFrameLevel(level + 4)
    w.glowHost = CreateFrame("Frame", nil, w.glowClip)
    w.glowHost:SetAllPoints(health)

    w.iconClip = NewGated(w.root, gateEnd)
    w.iconClip:SetFrameLevel(level + 9)
    w.icon = w.iconClip:CreateTexture(nil, "OVERLAY")

    w.pulses = { NewPulse(w.lethalClip), NewPulse(w.glowClip), NewPulse(w.iconClip) }

    widgets[plate] = w
    return w
end

-- Sizes and positions; reruns when the bar size or the icon settings change.
local function Layout(w, db)
    local width, height = PlainNumber(w.health:GetWidth()), PlainNumber(w.health:GetHeight())
    if not width or not height then return false end
    local signature = width .. "|" .. height .. "|" .. db.iconSize .. "|" .. db.iconPosition .. "|"
        .. db.iconOffsetX .. "|" .. db.iconOffsetY
    if signature == w.layout then return true end
    w.layout = signature

    w.proj.bar:SetWidth(width)
    w.lethalProj.bar:SetWidth(width)
    PlaceGated(w.lethalClip, width, height, -width / 2, 0)
    PlaceGated(w.glowClip, width + GLOW_MARGIN * 2, height + GLOW_MARGIN * 2, -width / 2, 0)

    local size = db.iconSize
    local dx, dy
    if db.iconPosition == "left" then
        dx, dy = -width - ICON_GAP - size / 2, 0
    elseif db.iconPosition == "above" then
        dx, dy = -width / 2, height / 2 + ICON_GAP + size / 2
    else
        dx, dy = ICON_GAP + size / 2, 0
    end
    dx, dy = dx + db.iconOffsetX, dy + db.iconOffsetY
    PlaceGated(w.iconClip, size, size, dx, dy)
    w.icon:SetSize(size, size)
    w.icon:ClearAllPoints()
    w.icon:SetPoint("CENTER", w.health, "RIGHT", dx, dy)
    w.glowSignature = nil -- restarts the glow at the new size
    return true
end

local function SetTexture(tex, key)
    tex:SetTexture(F.TEXTURES.path[key] or WHITE)
end

local function ColorKey(c)
    return tostring(c.r) .. "," .. tostring(c.g) .. "," .. tostring(c.b) .. "," .. tostring(c.a)
end

-- Colours and textures; reruns when a setting or the accent colour changes.
local function Style(w, db)
    local ar, ag, ab = F.Accent()
    local signature = table.concat({ db.texture, ColorKey(db.color), tostring(db.endLine), ColorKey(db.endLineColor),
        ColorKey(db.lethalFill), db.icon, ar, ag, ab }, "|")
    if signature == w.style then return end
    w.style = signature

    SetTexture(w.proj.tex, db.texture)
    SetTexture(w.lethalProj.tex, db.texture)
    w.proj.tex:SetVertexColor(F.ColorOf(db.color))
    w.lethalProj.tex:SetVertexColor(F.ColorOf(db.lethalFill))
    w.proj.line:SetVertexColor(F.ColorOf(db.endLineColor))
    w.proj.line:SetShown(db.endLine)
    w.icon:SetTexture(F.ICONS.path[db.icon] or F.ICONS.path.skull)
end

local function Glows()
    return EllesmereUI and EllesmereUI.Glows
end

local function StopGlow(w)
    w.glowSignature = nil
    if not w.glowOn then return end
    w.glowOn = false
    local G = Glows()
    if G and G.StopGlow then pcall(G.StopGlow, w.glowHost) end
end

-- The glow runs whenever the plate has DoTs; the gate decides whether it's seen.
local function UpdateGlow(w, db)
    local G = Glows()
    if not db.glow or not (G and G.StartGlow) then return StopGlow(w) end
    local width, height = PlainNumber(w.health:GetWidth()), PlainNumber(w.health:GetHeight())
    if not width or not height then return StopGlow(w) end
    local r, g, b = F.ColorOf(db.glowColor)
    local signature = table.concat({ db.glowStyle, r, g, b, width, height }, "|")
    if signature == w.glowSignature then return end
    StopGlow(w)
    if pcall(G.StartGlow, w.glowHost, db.glowStyle, width, r, g, b, nil, height) then
        w.glowSignature, w.glowOn = signature, true
    end
end

local function SetPulse(w, on)
    if w.pulsing == on then return end
    w.pulsing = on
    for _, group in ipairs(w.pulses) do
        if on then group:Play() else group:Stop() end
    end
end

local function Hide(w)
    if not w.root:IsShown() then return end
    w.root:Hide()
    StopGlow(w)
    SetPulse(w, false)
end

-- Secret values only ever go into StatusBar min/max/value. `test` (/dotp test) feeds plain fractions instead:
-- projection = that share of the bar, gate open only when it's 1.
local function FeedBars(w, unit, damage, test)
    local maxHealth, health = 1, 1
    if test then
        damage = test
    else
        maxHealth, health = UnitHealthMax(unit), UnitHealth(unit)
    end
    w.proj.bar:SetMinMaxValues(0, maxHealth)
    w.proj.bar:SetValue(damage)
    w.lethalProj.bar:SetMinMaxValues(0, maxHealth)
    w.lethalProj.bar:SetValue(damage)
    w.gate:SetMinMaxValues(0, health)
    w.gate:SetValue(test and (test >= 1 and 1 or 0) or damage)
end

local reported = {}
local function Report(err)
    err = tostring(err)
    if reported[err] then return end
    reported[err] = true
    if F.trace then F.trace("ERROR plates: " .. err) end
    F.Say("Display error (logged): " .. err)
end

-- Returns nil when drawn, else why not (for the log).
local function Draw(w, unit, damage, db, test)
    if not Layout(w, db) then
        Hide(w)
        return "not drawn: health bar size unreadable"
    end
    Style(w, db)
    local ok, err = pcall(FeedBars, w, unit, damage, test)
    if not ok then
        Report(err)
        Hide(w)
        return "not drawn: " .. tostring(err)
    end
    w.proj.bar:SetShown(db.projection)
    w.lethalClip:SetShown(db.lethalColor)
    w.iconClip:SetShown(db.killIcon)
    w.root:Show()
    UpdateGlow(w, db)
    SetPulse(w, db.pulse)
end

---------------------------------------------------------------------------
-- Test (/dotp test): on the target's plate, a projection of 30% of the bar, then lethal. UnitHealth is always
-- secret, so the test never reads health: FeedBars gets plain fractions instead.
---------------------------------------------------------------------------

local testStart

function F.StartTest()
    testStart = GetTime()
end

-- Fraction to feed the bars, or nil when no test is running on this unit.
local function TestShare(unit)
    if not testStart or not UnitIsUnit(unit, "target") then return end
    local elapsed = GetTime() - testStart
    if elapsed > TEST_SECONDS * 2 then
        testStart = nil
        return
    end
    return elapsed < TEST_SECONDS and TEST_PARTIAL or 1
end

---------------------------------------------------------------------------
-- Log: what each plate shows for the DoTs, one line per change (the update runs 10x a second).
---------------------------------------------------------------------------

local plateLog = {}    -- unit -> last logged "key|state"
local unshownLog = {}  -- mob key -> true once logged as having DoTs no plate shows

local function LogPlate(unit, key, state)
    local last = plateLog[unit]
    if not state then
        -- Nothing to show: only worth a line if this plate showed (or failed to show) something before.
        if last then
            plateLog[unit] = nil
            F.trace(string.format("PLATE %s %s: nothing to show", unit, F.ShortKey(key)))
        end
        return
    end
    local line = tostring(key) .. "|" .. state
    if last == line then return end
    plateLog[unit] = line
    F.trace(string.format("PLATE %s %s: %s", unit, F.ShortKey(key), state))
end

local function Summary(list, damage)
    local parts = {}
    for _, entry in ipairs(list) do
        table.insert(parts, string.format("%s %d", entry.name, math.floor(entry.damage + 0.5)))
    end
    return string.format("%s = %d", table.concat(parts, " + "), math.floor(damage + 0.5))
end

local function HasTrackedDots()
    for _ in F.TrackedKeys() do return true end
    return false
end

-- DoTs that count toward a projection but that no plate drew: the mob's plate is off screen, or its unit key
-- didn't match the one the DoT was stored under.
local function LogUnshown(drawnKeys)
    for key in F.TrackedKeys() do
        local list, damage = F.BreakdownKey(key)
        if damage > 0 and not drawnKeys[key] then
            if not unshownLog[key] then
                unshownLog[key] = true
                F.trace(string.format("UNSHOWN %s: %s tracked, no plate drew it", F.ShortKey(key),
                    Summary(list, damage)))
            end
        else
            unshownLog[key] = nil
        end
    end
end

local function OnPlateRemoved(unit)
    local ok, dead = pcall(UnitIsDead, unit)
    dead = ok and not F.IsSecret(dead) and dead
    local key = F.UnitKey(unit)
    if plateLog[unit] then
        plateLog[unit] = nil
        local list, damage = F.BreakdownKey(key)
        F.trace(string.format("PLATE %s %s: removed (dead=%s), DoTs left: %s", unit, F.ShortKey(key),
            ok and tostring(dead) or "unreadable", #list > 0 and Summary(list, damage) or "none"))
    end
    -- Otherwise its DoTs linger until they'd have expired, logged as UNSHOWN.
    if dead == true then F.ForgetMob(key) end
end

-- Whether anything health-shaped is readable, once in combat and once out (log only). If the health fill's width
-- were plain, real tick sizes could be learned from it; UNIT_COMBAT amounts are secret in combat.
local probed = {}
local function Probe(w, unit)
    local state = InCombatLockdown() and "in combat" or "out of combat"
    if probed[state] then return end
    probed[state] = true
    local function read(fn, ...)
        local ok, value = pcall(fn, ...)
        if not ok then return "error" end
        if F.IsSecret(value) then return "secret" end
        return tostring(value)
    end
    F.trace(string.format("PROBE %s: UnitHealth=%s UnitHealthMax=%s UnitHealthPercent=%s fillWidth=%s barWidth=%s",
        state, read(UnitHealth, unit), read(UnitHealthMax, unit),
        UnitHealthPercent and read(UnitHealthPercent, unit) or "n/a",
        read(w.fill.GetWidth, w.fill), read(w.health.GetWidth, w.health)))
end

---------------------------------------------------------------------------
-- Update loop
---------------------------------------------------------------------------

local seen = {}
local drawnKeys = {}
local function Update()
    local db = F.db
    if not db or not NP then return end
    wipe(seen)
    wipe(drawnKeys)
    local anyDots = HasTrackedDots()
    for _, plate in pairs(NP.plates) do
        local unit = plate.unit
        if unit and plate.health then
            local key = F.UnitKey(unit)
            local list, damage = F.BreakdownKey(key)
            local test = TestShare(unit)
            if damage > 0 or test then
                seen[plate] = true
                if key then drawnKeys[key] = true end
                local w = widgets[plate] or Create(plate)
                if not test then Probe(w, unit) end
                local problem = Draw(w, unit, damage, db, test)
                LogPlate(unit, key, problem or ("shown " .. (test and "test" or Summary(list, damage))))
            elseif not key and anyDots then
                LogPlate(unit, key, "GUID unreadable, can't look up its DoTs")
            else
                LogPlate(unit, key, nil)
            end
        end
    end
    for plate, w in pairs(widgets) do
        if not seen[plate] then Hide(w) end
    end
    LogUnshown(drawnKeys)
end

-- After an options change: re-apply everything now.
function F.RefreshPlates()
    for _, w in pairs(widgets) do
        w.layout, w.style = nil, nil
        StopGlow(w)
    end
    local ok, err = pcall(Update)
    if not ok then Report(err) end
end

local driver = CreateFrame("Frame")
driver:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
driver:SetScript("OnEvent", function(_, _, unit)
    if not F.db then return end
    local ok, err = pcall(OnPlateRemoved, unit)
    if not ok then Report(err) end
end)
local sinceUpdate = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < UPDATE_INTERVAL then return end
    sinceUpdate = 0
    local ok, err = pcall(Update)
    if not ok then Report(err) end
end)
