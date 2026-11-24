-- DoT Projection: your DoT damage projected on EllesmereUI nameplates, with effects when it's lethal.
-- This file holds the settings, the choice lists and the slash command; Tracker.lua works the damage out,
-- Plates.lua draws it.
local _, addon = ...

local DB_VERSION = 1 -- bump to discard learned tick sizes from an older tracker

local function ForgetTicks(F)
    wipe(F.db.ticks)
    if F.db.tickWeights then wipe(F.db.tickWeights) end
    if F.DropSnapshots then F.DropSnapshots() end
    F.Say("Learned tick sizes cleared.")
end

local function OnSlash(F, msg)
    local cmd = strlower(msg)
    if cmd == "test" then
        F.StartTest()
    elseif cmd == "debug" then
        F.db.debug = not F.db.debug
        F.Say("Debug " .. (F.db.debug and "on" or "off") .. ".")
    elseif cmd == "reset" then
        ForgetTicks(F)
    elseif cmd == "log clear" then
        wipe(F.db.log)
        F.Say("Log cleared.")
    elseif cmd == "log" or cmd:match("^log %d+$") then
        local log = F.db.log
        local count = math.min(tonumber(cmd:match("%d+")) or 20, #log)
        F.Say(string.format("Last %d of %d log lines (all saved on /reload or logout):", count, #log))
        for i = #log - count + 1, #log do
            DEFAULT_CHAT_FRAME:AddMessage("|cff888888" .. log[i] .. "|r")
        end
    else
        F.Say("/dotp: options")
        F.Say("/dotp test: preview on your target's plate")
        F.Say("/dotp debug: trace casts and ticks to chat")
        F.Say("/dotp log [n]: show the last n log lines (default 20)")
        F.Say("/dotp log clear: empty the log")
        F.Say("/dotp reset: forget learned tick sizes")
    end
end

-- Colours are { r, g, b, a }; nil r = follow the EllesmereUI accent colour.
-- The section also carries ticks, log and version, which a reset leaves alone.
local F = addon.NewFeature("DotProjection", {
    title = "DoT Projection",
    requires = "EllesmereUINameplates",
    defaults = {
        -- Projection
        projection = true,
        texture = "flat",
        color = { r = 1, g = 1, b = 1, a = 0.4 },
        endLine = true,
        endLineColor = { r = 1, g = 1, b = 1, a = 0.9 },
        waitFirstTick = "off",
        -- Lethal
        lethalColor = true,
        lethalFill = { a = 0.75 },
        glow = true,
        glowStyle = 1,
        glowColor = { a = 1 },
        pulse = false,
        killIcon = true,
        icon = "skull",
        iconSize = 16,
        iconPosition = "right",
        iconOffsetX = 0,
        iconOffsetY = 0,
        -- Misc
        debug = false,
    },
    slash = "dotp",
    onSlash = OnSlash,
    onLoad = function(F)
        local db = F.db
        if db.version ~= DB_VERSION then db.ticks, db.version = nil, DB_VERSION end
        db.ticks = db.ticks or {}
        db.log = db.log or {}
        F.TrackerInit()
        if not F.PlatesReady() then
            F.Say("EllesmereUI Nameplates changed its plate table; nothing to draw on.")
        end
    end,
    onReset = function(F) F.RefreshPlates(true) end,
})
if not F then return end

F.ForgetTicks = function() ForgetTicks(F) end
F.Accent = addon.Accent
F.ColorOf = addon.ColorOf

-- Stripes are EllesmereUI Nameplates' own (its focus overlay), drawn across the whole bar so they don't crawl.
local EUI_NP_MEDIA = "Interface\\AddOns\\EllesmereUINameplates\\Media\\"
F.TEXTURES = {
    values = { flat = "Flat", stripes = "Stripes", wide = "Wide stripes" },
    order = { "flat", "stripes", "wide" },
    path = {
        flat = "Interface\\Buttons\\WHITE8X8",
        stripes = EUI_NP_MEDIA .. "striped-v2.png",
        wide = EUI_NP_MEDIA .. "striped-wide-v2.png",
    },
}

F.ICONS = {
    values = { skull = "Skull", cross = "Cross", boss = "Boss skull" },
    order = { "skull", "cross", "boss" },
    path = {
        skull = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",
        cross = "Interface\\RaidFrame\\ReadyCheck-NotReady",
        boss = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
    },
}

F.ICON_POSITIONS = {
    values = { left = "Left", right = "Right", above = "Above" },
    order = { "left", "right", "above" },
}

function F.IsSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    return ok and secret or false
end
