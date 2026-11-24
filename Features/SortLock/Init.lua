-- Sort Lock: the two lock lists (account-wide and this character) and input parsing.
-- A locked item ID keeps every copy of that item in the slot it is in when OneBag sorts.
local _, addon = ...

local F = addon.NewFeature("SortLock", {
    title = "Sort Lock",
    requires = "EllesmereUIBags",
    defaults = { items = {} },
    charDefaults = { items = {} },
    slash = "sortlock",
    onLoad = function(F)
        F.lists.account = F.db.items
        F.lists.character = F.charDb.items
    end,
})
if not F then return end

-- F.lists.account / F.lists.character: itemID -> true. Set on load.
F.lists = {}

function F.IsLocked(itemID)
    if not itemID then return false end
    local a, c = F.lists.account, F.lists.character
    return (a and a[itemID]) or (c and c[itemID]) or false
end

function F.HasLocks()
    local a, c = F.lists.account, F.lists.character
    return (a and next(a) ~= nil) or (c and next(c) ~= nil) or false
end

-- Item IDs in free text: shift-clicked links (their names can hold commas, so links are read whole first),
-- then comma- or space-separated numbers in what is left. Returns ids (in order, no repeats), bad tokens.
function F.ParseItemIDs(text)
    local ids, seen, bad = {}, {}, {}
    local function add(id)
        id = tonumber(id)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    text = text or ""
    for id in text:gmatch("|Hitem:(%d+)") do add(id) end
    -- Drop whole links, then any loose colour codes, then read the rest token by token.
    local rest = text:gsub("|H.-|h.-|h", " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    for token in rest:gmatch("[^,%s]+") do
        local id = token:match("^item:(%d+)") or token:match("^(%d+)$")
        if id then add(id) else bad[#bad + 1] = token end
    end
    return ids, bad
end

-- Adds every ID in text to one list ("account" or "character"); returns how many were new.
function F.AddFromText(which, text)
    local list = F.lists[which]
    local ids, bad = F.ParseItemIDs(text)
    local added = 0
    for _, id in ipairs(ids) do
        if not list[id] then
            list[id] = true
            added = added + 1
        end
    end
    if #bad > 0 then F.Say("Not an item ID or link: " .. table.concat(bad, ", ")) end
    return added
end

function F.Remove(which, itemID)
    F.lists[which][itemID] = nil
end

function F.SortedIDs(which)
    local out = {}
    for id in pairs(F.lists[which]) do out[#out + 1] = id end
    table.sort(out)
    return out
end
