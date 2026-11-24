-- EUI Pariah registration: one EllesmereUI plugin section, a sidebar row per area that has pages,
-- a tab per page. Loaded last (see the TOC).
local addonName, addon = ...

local EUI = EllesmereUI
if type(EUI.RegisterPlugin) ~= "function" then return end

local BOTTOM_PAD = 20

local function ResetFor(area)
    local resettable, seen = {}, {}
    for _, pageName in ipairs(area.names) do
        local F = area.byName[pageName].feature
        if F.Reset and not seen[F] then
            seen[F] = true
            resettable[#resettable + 1] = F
        end
    end
    if #resettable == 0 then return nil end
    return function()
        for _, F in ipairs(resettable) do F.Reset() end
    end
end

local modules = {}
for _, spec in ipairs(addon.AREAS) do
    local area = addon.pages[spec.key]
    if area then
        modules[#modules + 1] = {
            key = spec.key,
            title = spec.title,
            description = spec.description,
            pages = area.names,
            buildPage = function(pageName, parent, yOffset)
                local page = area.byName[pageName]
                if not (page and page.feature.db) then return math.abs(yOffset) end
                -- Widgets is read per build: the search pre-build swaps it.
                return math.abs(page.build(EUI.Widgets, parent, yOffset)) + BOTTOM_PAD
            end,
            onReset = ResetFor(area),
        }
    end
end

if #modules > 0 then
    EUI.RegisterPlugin(addonName, { label = "Pariah Tweaks", modules = modules })
end
