-- EUI Pariah core: the feature registry, saved settings, chat output and slash commands.
--
-- A feature registers once from its first file:
--   local F = addon.NewFeature("Key", {
--       title        = "Chat Prefix",
--       requires     = "EllesmereUIBags",   -- optional; without it the feature is skipped (NewFeature returns nil)
--       defaults     = { ... },             -- EUIPariahDB.Key, account-wide
--       charDefaults = { ... },             -- EUIPariahCharDB.Key, this character
--       onLoad       = function(F) end,     -- F.db / F.charDb are in place
--       onReset      = function(F) end,     -- makes the feature resettable; runs after defaults are restored
--       slash        = "key",               -- /key and /euit key
--       onSlash      = function(F, msg) end -- non-empty arguments; an empty command opens the options
--   })
--   F.AddPage("Nameplates", "Page Name", function(W, parent, y) ... return y end)
-- Its other files pick the same table up with addon.GetFeature("Key") and return early when it is nil.
local addonName, addon = ...

local ACCENT = { 12 / 255, 210 / 255, 157 / 255 }
local ACCENT_HEX = "0cd29f"

-- Sidebar rows, in order. A row with no pages is left out.
addon.AREAS = {
    { key = "Nameplates", title = "Nameplates", description = "Extras on top of EllesmereUI's nameplates." },
    { key = "Bags", title = "Bags", description = "Extras for EllesmereUI's bags." },
    { key = "ActionBars", title = "Action Bars", description = "Extras for EllesmereUI's action and data bars." },
}

-- areaKey -> { names = { pageName, ... }, byName = { [pageName] = { feature, build } } }
addon.pages = {}

local features, featureList, slashFeatures = {}, {}, {}
local areaKeys = {}
for _, area in ipairs(addon.AREAS) do areaKeys[area.key] = true end

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = DeepCopy(v) end
    return copy
end

local function Section(root, key, defaults)
    local section = root[key]
    if type(section) ~= "table" then
        section = {}
        root[key] = section
    end
    for k, v in pairs(defaults or {}) do
        if section[k] == nil then section[k] = DeepCopy(v) end
    end
    return section
end

function addon.Accent()
    if type(EllesmereUI.GetAccentColor) == "function" then
        local r, g, b = EllesmereUI.GetAccentColor()
        if type(r) == "number" then return r, g, b end
    end
    return ACCENT[1], ACCENT[2], ACCENT[3]
end

-- r, g, b, a of a stored colour; one without r follows the EllesmereUI accent.
function addon.ColorOf(c)
    if type(c) ~= "table" then return 1, 1, 1, 1 end
    local a = type(c.a) == "number" and c.a or 1
    if type(c.r) ~= "number" then
        local r, g, b = addon.Accent()
        return r, g, b, a
    end
    return c.r, c.g, c.b, a
end

local function Say(prefix, text)
    DEFAULT_CHAT_FRAME:AddMessage(("|cff%s%s|r %s"):format(ACCENT_HEX, prefix, text))
end

-- Opens the options panel, on one page when given.
function addon.Open(areaKey, pageName)
    if InCombatLockdown() then return Say("EUI Pariah", "Options open out of combat.") end
    if not (EllesmereUI.OpenPlugin and EllesmereUI.OpenPlugin(addonName, areaKey, pageName)) then
        Say("EUI Pariah", "EllesmereUI options unavailable.")
    end
end

function addon.GetFeature(key)
    return features[key]
end

function addon.NewFeature(key, spec)
    assert(not features[key], "EUI Pariah: feature registered twice: " .. key)
    if spec.requires and not C_AddOns.IsAddOnLoaded(spec.requires) then return nil end

    local F = { key = key }
    local firstPage

    function F.Say(text)
        Say(spec.title or key, text)
    end

    -- build(W, parent, y) -> y, both top-down (negative) offsets.
    function F.AddPage(areaKey, pageName, build)
        if not areaKeys[areaKey] then error(("EUI Pariah: unknown area %q (see addon.AREAS)"):format(areaKey), 2) end
        local area = addon.pages[areaKey]
        if not area then
            area = { names = {}, byName = {} }
            addon.pages[areaKey] = area
        end
        area.names[#area.names + 1] = pageName
        area.byName[pageName] = { feature = F, build = build }
        firstPage = firstPage or { areaKey, pageName }
    end

    function F.Open()
        if firstPage then addon.Open(firstPage[1], firstPage[2]) else addon.Open() end
    end

    if spec.onReset then
        function F.Reset()
            if not F.db then return end
            for k, v in pairs(spec.defaults or {}) do F.db[k] = DeepCopy(v) end
            spec.onReset(F)
        end
    end

    function F.Load()
        F.db = Section(EUIPariahDB, key, spec.defaults)
        if spec.charDefaults then F.charDb = Section(EUIPariahCharDB, key, spec.charDefaults) end
        if spec.onLoad then spec.onLoad(F) end
    end

    function F.RunSlash(msg)
        if not F.db then return end
        msg = strtrim(msg or "")
        if msg ~= "" and spec.onSlash then return spec.onSlash(F, msg) end
        F.Open()
    end

    if spec.slash then
        local id = "EUIPARIAH_" .. key:upper()
        _G["SLASH_" .. id .. "1"] = "/" .. spec.slash
        SlashCmdList[id] = F.RunSlash
        slashFeatures[spec.slash] = F
    end

    features[key] = F
    featureList[#featureList + 1] = F
    return F
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, _, name)
    if name ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")
    EUIPariahDB = EUIPariahDB or {}
    EUIPariahCharDB = EUIPariahCharDB or {}
    for _, F in ipairs(featureList) do F.Load() end
end)

SLASH_EUIPARIAH1 = "/euit"
SLASH_EUIPARIAH2 = "/pariah"
SlashCmdList.EUIPARIAH = function(msg)
    local name, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    local F = slashFeatures[name:lower()]
    if F then return F.RunSlash(rest) end
    addon.Open()
end
