-- Sort Lock engine: OneBag's physical sort, done the way EllesmereUIBags 9.9.2 does it, except that a slot holding
-- a locked item ID is left alone: the item stays, and nothing else is moved into that slot.
-- Written for EUI_Pariah from a description of EUI's behaviour. It talks to EUI only through what EUI makes
-- public (EUI_CategoryManager, EllesmereUI's upgrade-track helpers and CVar holds, EUI_Bags' refresh switch).
--
-- A run, step by step; each step repeats until it has nothing left to move or reaches its pass limit, and waits
-- for the moves it sent to land before it looks at the bags again:
--   merge    partial stacks of one item pair up, emptiest onto fullest. Stacks in a one-kind bag (quiver, herb
--            bag, ...) only pair inside that bag. Locked items take part, as in ElvUI: they stay put, their
--            count changes.
--   reagents crafting reagents in the main bags go into the reagent bag's empty slots, unless the fifth slot
--            holds a profession bag. Locked items stay.
--   layout   bags 0-4, then bag 5: every unlocked item goes into display order over the slots that are left.
-- Re-check after EUI updates past 9.9.2: the display order rules below, and which step runs when.
local _, addon = ...
local F = addon.GetFeature("SortLock")
if not F then return end

local EUI = EllesmereUI
local ItemInfo = C_Item.GetItemInfo -- the Forever client has no global GetItemInfo

-- EUI's own owner name for the sound hold: its login pass then lifts a hold that a reload mid-sort left behind.
local SOUND_OWNER = "EllesmereUIBags"
local PASSES = { merge = 30, reagents = 3, layout = 16 }
local SETTLE = 0.15  -- seconds after a pass's first bag update; the latest it waits for the rest
local GIVE_UP = 5    -- seconds without any bag update after a pass: the moves failed, end the run
local TAIL = 0.3     -- seconds the end may wait for items still in flight before the bags repaint

-------------------------------------------------------------------------------
--  Bag access. Everything goes through F.bags so the offline tests can swap in fake bags.
-------------------------------------------------------------------------------
local B = {}
F.bags = B
function B.size(bag) return C_Container.GetContainerNumSlots(bag) end
function B.item(bag, slot) return C_Container.GetContainerItemInfo(bag, slot) end
function B.link(bag, slot) return C_Container.GetContainerItemLink(bag, slot) end
function B.family(bag) return (select(2, C_Container.GetContainerNumFreeSlots(bag))) end
function B.inFlight(bag, slot) return C_Item.IsLocked(ItemLocation:CreateFromBagAndSlot(bag, slot)) end
function B.forever() return EUI.IS_FOREVER end
-- Picks the item up and drops it on the other slot. False when the target turned it away (still on the cursor).
function B.move(fromBag, fromSlot, toBag, toSlot)
    C_Container.PickupContainerItem(fromBag, fromSlot)
    C_Container.PickupContainerItem(toBag, toSlot)
    local refused = CursorHasItem()
    ClearCursor()
    return not refused
end

-- Forever's one-kind bags in slots 1-4 (a non-zero bag family): nothing moves into or out of them.
local function OneKindBags()
    if not B.forever() then return nil end
    local set
    for bag = 1, 4 do
        local family = B.family(bag)
        if family and family ~= 0 then
            set = set or {}
            set[bag] = true
        end
    end
    return set
end

-- Per-run memo: facts that only depend on the item ID or link. A fact the client hasn't loaded yet is not kept,
-- so a later pass asks again.
local function NewMemo() return { stack = {}, reagent = {}, link = {}, refused = {} } end

local function StackSize(id, memo)
    local n = memo.stack[id]
    if n then return n end
    n = select(8, ItemInfo(id))
    if n then memo.stack[id] = n end
    return n or 1
end

local function IsReagent(id, memo)
    local yes = memo.reagent[id]
    if yes == nil then
        yes = select(17, ItemInfo(id))
        if yes ~= nil then memo.reagent[id] = yes end
    end
    return yes
end

-------------------------------------------------------------------------------
--  Display order: the order EUI's OneBag view draws items in.
--  Sections follow the sidebar (a category group is one section). Inside a section: two gear items rank by
--  upgrade track, then (both on a track) item level, best first, ignoring their categories; anything else by
--  category. Then item type, quality (best first), name, item ID, and last the bag and slot it sits in now.
-------------------------------------------------------------------------------
local NO_FACTS = { name = "", quality = 0, level = 0, kind = "", track = 0 }

local function LinkFacts(link, memo)
    if not link then return NO_FACTS end
    local facts = memo.link[link]
    if facts then return facts end
    local name, _, quality, level, _, kind = ItemInfo(link)
    local track = 0
    local ranks, trackOf = EUI._TRACK_RANK, EUI.GetUpgradeTrack
    if ranks and trackOf then
        local _, colour = trackOf(link)
        track = (colour and ranks[colour]) or 0
        -- A crafted item's quality tier counts as its track, at its real (scaled) item level.
        local crafted = EUI.GetCraftedTrackColor and EUI.GetCraftedTrackColor(link)
        if crafted then
            track = ranks[crafted] or 0
            level = C_Item.GetDetailedItemLevelInfo(link) or level
        end
    end
    facts = { name = name or "", quality = quality or 0, level = level or 0, kind = kind or "", track = track }
    if name then memo.link[link] = facts end
    return facts
end

local function IsGear(cat)
    return cat.isSetGear or (cat.types ~= nil and (cat._defaultName == "Armor" or cat._defaultName == "Weapons / Trinkets"))
end

-- category index -> section number, and the set of gear categories.
local function Sections(cats)
    local section, gear, n, groupSeen = {}, {}, 0, {}
    for i, cat in ipairs(cats) do
        if IsGear(cat) then gear[i] = true end
        local group = cat.groupName
        if not group then
            n = n + 1
            section[i] = n
        elseif not groupSeen[group] then
            groupSeen[group] = true
            n = n + 1
            for _, member in ipairs(EUI_CategoryManager:GetGroupMembers(group) or {}) do section[member] = n end
        end
    end
    return section, gear
end

-- Each rule decides a before b (true/false) or ties (nil); the first rule that decides wins.
local function By(x, y, highFirst)
    if x == y then return nil end
    if highFirst then return x > y end
    return x < y
end
local RULES = {
    function(a, b) return By(a.section, b.section) end,
    function(a, b) if a.gear and b.gear then return By(a.track, b.track, true) end end,
    function(a, b) if a.gear and b.gear and a.track > 0 then return By(a.level, b.level, true) end end,
    function(a, b) if not (a.gear and b.gear) then return By(a.cat, b.cat) end end,
    function(a, b) return By(a.kind, b.kind) end,
    function(a, b) return By(a.quality, b.quality, true) end,
    function(a, b) return By(a.name, b.name) end,
    function(a, b) return By(a.id, b.id) end,
    function(a, b) return By(a.bag, b.bag) end,
    function(a, b) return By(a.slot, b.slot) end,
}
local function Before(a, b)
    for i = 1, #RULES do
        local verdict = RULES[i](a, b)
        if verdict ~= nil then return verdict end
    end
    return false
end

-- entries: { bag, slot, info, itemLink } (the shape EUI_CategoryManager:ClassifyAll reads). Sorted in place.
function F.Rank(entries, memo)
    EUI_CategoryManager:ClassifyAll(entries, true)
    local section, gear = Sections(EUI_CategoryManager:GetCategories())
    for _, e in ipairs(entries) do
        local facts, cat = LinkFacts(e.itemLink, memo), e.categoryIndex
        e.cat = cat or 9999
        e.section = (cat and section[cat]) or 9999
        e.gear = (cat and gear[cat]) or false
        e.track, e.level, e.kind = facts.track, facts.level, facts.kind
        e.quality, e.name, e.id = facts.quality, facts.name, e.info.itemID or 0
    end
    table.sort(entries, Before)
end

-------------------------------------------------------------------------------
--  Planning. Each returns a list of moves { fromBag, fromSlot, toBag, toSlot } and touches nothing.
-------------------------------------------------------------------------------
-- Stack merging over bags 0-5.
function F.PlanMerges(memo)
    local oneKind = OneKindBags()
    local piles = {}
    for bag = 0, 5 do
        for slot = 1, B.size(bag) do
            local info = B.item(bag, slot)
            local id = info and info.itemID
            if id and info.stackCount then
                local full = StackSize(id, memo)
                if full > 1 and info.stackCount < full then
                    local key = (oneKind and oneKind[bag]) and (bag .. ":" .. id) or id
                    local pile = piles[key]
                    if not pile then pile = {}; piles[key] = pile end
                    pile[#pile + 1] = { bag = bag, slot = slot, n = info.stackCount }
                end
            end
        end
    end
    local moves = {}
    for _, pile in pairs(piles) do
        -- Ends inward (emptiest onto fullest, next onto next): each slot is used once, so the whole pass can go
        -- out at once, and many partial stacks finish in a few passes.
        table.sort(pile, function(x, y) return x.n < y.n end)
        local i, j = 1, #pile
        while i < j do
            local from, to = pile[i], pile[j]
            if not B.inFlight(from.bag, from.slot) and not B.inFlight(to.bag, to.slot) then
                moves[#moves + 1] = { from.bag, from.slot, to.bag, to.slot }
            end
            i, j = i + 1, j - 1
        end
    end
    return moves
end

-- Layout of bags first..last. Places are the slots left once locked items' slots and one-kind bags are taken
-- out; ranked item k goes to place k (the last #items places with Sort to Bottom). The walk runs toward the free
-- places, so an item pushed aside never lands on a place already done.
function F.PlanLayout(first, last, toBottom, memo)
    local oneKind = OneKindBags()
    local places, entries = {}, {}
    for bag = first, last do
        if not (oneKind and oneKind[bag]) then
            for slot = 1, B.size(bag) do
                local info = B.item(bag, slot)
                if not (info and F.IsLocked(info.itemID)) then
                    places[#places + 1] = { bag, slot }
                    if info then
                        entries[#entries + 1] = {
                            bag = bag, slot = slot, info = info, itemLink = B.link(bag, slot), place = #places,
                        }
                    end
                end
            end
        end
    end
    if #entries == 0 then return {} end
    F.Rank(entries, memo)

    local holder, at = {}, {} -- holder[place] = entry number now there; at[entry number] = its place
    for k, e in ipairs(entries) do
        holder[e.place] = k
        at[k] = e.place
    end
    local shift, from, to, dir = 0, 1, #entries, 1
    if toBottom then shift, from, to, dir = #places - #entries, #entries, 1, -1 end

    local moves = {}
    for k = from, to, dir do
        local want, now = k + shift, at[k]
        if want ~= now then
            local other = holder[want]
            -- The same item on both ends would merge stacks rather than swap: a later pass gets it.
            if not (other and entries[other].info.itemID == entries[k].info.itemID) then
                moves[#moves + 1] = { places[now][1], places[now][2], places[want][1], places[want][2] }
                holder[want], holder[now] = k, other
                at[k] = want
                if other then at[other] = now end
            end
        end
    end
    return moves
end

-- Reagent routing, planned and sent in one go: only the drop shows whether the reagent bag takes an item.
-- Returns whether anything moved.
local function RouteReagents(memo)
    local size = B.size(5)
    if size == 0 then return false end
    local family = B.forever() and B.family(5)
    if family and family ~= 0 then return false end -- a profession bag in the fifth slot: leave it be
    local open = {}
    for slot = 1, size do
        if not B.item(5, slot) then open[#open + 1] = slot end
    end
    local oneKind, used, moved = OneKindBags(), 0, false
    for bag = 0, 4 do
        if not (oneKind and oneKind[bag]) then
            for slot = 1, B.size(bag) do
                if used >= #open then return moved end
                local info = B.item(bag, slot)
                local id = info and info.itemID
                if id and not info.isLocked and not memo.refused[id] and not F.IsLocked(id) and IsReagent(id, memo) then
                    if B.move(bag, slot, 5, open[used + 1]) then
                        used = used + 1
                        moved = true
                    else
                        memo.refused[id] = true
                    end
                end
            end
        end
    end
    return moved
end

-------------------------------------------------------------------------------
--  Running: one coroutine per run. It yields while moves are landing; bag events and timers resume it.
-------------------------------------------------------------------------------
F.busy = false
local run          -- the live run, nil when idle
local events = CreateFrame("Frame")
local tail = CreateFrame("Frame")

local function AnyInFlight(first, last)
    for bag = first, last do
        for slot = 1, B.size(bag) do
            local info = B.item(bag, slot)
            if info and info.isLocked then return true end
        end
    end
    return false
end

local function Repaint()
    F.busy = false
    EUI_Bags.refreshEnabled = true
    EUI_Bags:RefreshInventory()
end

-- Ends the run r. combat: repaint now (still outside the lockdown); else once nothing is in flight, so EUI's
-- new-item check doesn't take an item mid-move for a new one.
local function Finish(r, combat)
    if run ~= r then return end
    run = nil
    r.co, r.ticket = nil, nil
    events:UnregisterAllEvents()
    if not r.tookOver then EUI.ReleaseCVar("Sound_EnableSFX", r.soundWas, SOUND_OWNER) end
    local done = false
    local function Done()
        if done then return end
        done = true
        tail:UnregisterAllEvents()
        Repaint()
        if r.onFinish then r.onFinish() end
    end
    if combat or not AnyInFlight(0, 5) then return Done() end
    tail:SetScript("OnEvent", function() if not AnyInFlight(0, 5) then Done() end end)
    tail:RegisterEvent("ITEM_LOCK_CHANGED")
    tail:RegisterEvent("BAG_UPDATE_DELAYED")
    C_Timer.After(TAIL, Done)
end

local function Resume(r, ...)
    if run ~= r or not r.co or coroutine.status(r.co) ~= "suspended" then return end
    local ok, result = coroutine.resume(r.co, ...)
    if not ok then
        -- Never leave the bags frozen and the sound muted: end the run, then report.
        Finish(r, false)
        return geterrorhandler()(result)
    end
    if r.co and coroutine.status(r.co) == "dead" then Finish(r, result == "combat") end
end

-- Inside the run: waits until the moves just sent have landed in bags first..last. Landed = a
-- BAG_UPDATE_DELAYED with nothing there in flight, or SETTLE seconds after the first BAG_UPDATE.
-- Returns false when no bag update came at all within GIVE_UP seconds.
local function Settle(r, first, last)
    local ticket = {}
    r.ticket, r.first, r.last, r.clock = ticket, first, last, false
    events:RegisterEvent("BAG_UPDATE")
    events:RegisterEvent("BAG_UPDATE_DELAYED")
    C_Timer.After(GIVE_UP, function()
        if r.ticket == ticket and not r.clock then Resume(r, ticket, false) end
    end)
    while true do
        local got, landed = coroutine.yield()
        if got == ticket then
            r.ticket = nil
            events:UnregisterEvent("BAG_UPDATE")
            events:UnregisterEvent("BAG_UPDATE_DELAYED")
            return landed
        end
    end
end

events:SetScript("OnEvent", function(_, event, arg)
    local r = run
    if not r then return end
    if event == "PLAYER_REGEN_DISABLED" then return Finish(r, true) end
    if event == "CVAR_UPDATE" then
        -- The player changed sound effects mid-run: the hold ends where it stands and nothing is restored.
        if type(arg) == "string" and arg:lower() == "sound_enablesfx" then
            r.tookOver = true
            events:UnregisterEvent("CVAR_UPDATE")
            EUI.DropHold("Sound_EnableSFX", SOUND_OWNER)
        end
        return
    end
    local ticket = r.ticket
    if not ticket then return end
    if event == "BAG_UPDATE_DELAYED" and not AnyInFlight(r.first, r.last) then
        Resume(r, ticket, true)
    elseif event == "BAG_UPDATE" and not r.clock then
        r.clock = true
        C_Timer.After(SETTLE, function() if r.ticket == ticket then Resume(r, ticket, true) end end)
    end
end)

local function Send(moves)
    for _, m in ipairs(moves) do B.move(m[1], m[2], m[3], m[4]) end
    return #moves > 0
end

-- The run's body. Returns "combat" when the lockdown stopped it.
local function Body(r)
    local memo = r.memo
    -- step(n) sends pass n's moves and says whether it sent any. Returns false when the run should stop.
    local function Repeat(limit, first, last, step)
        for n = 1, limit do
            if InCombatLockdown() then return false end
            if not step(n) then return true end
            if not Settle(r, first, last) then return false end
        end
        return true
    end
    local go = Repeat(PASSES.merge, 0, 5, function() return Send(F.PlanMerges(memo)) end)
        and Repeat(PASSES.reagents, 0, 5, function() return RouteReagents(memo) end)
    for _, range in ipairs({ { 0, 4 }, { 5, 5 } }) do
        local first, last = range[1], range[2]
        if go and (first == 0 or B.size(5) > 0) then
            go = Repeat(PASSES.layout, first, last, function(n)
                local moves = F.PlanLayout(first, last, r.toBottom, memo)
                if #moves == 0 then return false end
                -- Show the progress so far; refreshEnabled stays off, so no new-item check runs.
                if n > 1 then securecallfunction(EUI_Bags.RefreshInventory, EUI_Bags) end
                return Send(moves)
            end)
        end
    end
    if InCombatLockdown() then return "combat" end
end

-- Starts a run; false when one can't start now. onFinish runs once the bags have repainted.
function F.RunSort(onFinish)
    if F.busy or InCombatLockdown() or not EUI_CategoryManager then return false end
    F.busy = true
    if CursorHasItem() then ClearCursor() end -- a held item would be dropped into the first slot we pick up
    EUI_Bags.refreshEnabled = false

    local profile = EUI._bagsDB and EUI._bagsDB.profile
    local r = { memo = NewMemo(), onFinish = onFinish, toBottom = (profile and profile.bagSortToBottom) and true or false }
    run = r

    -- Blizzard's clean-up sound on the Master channel (the item moves run with sound effects muted), only when the
    -- player would hear sound effects at all.
    r.soundWas = GetCVar("Sound_EnableSFX")
    if r.soundWas == "1" and (tonumber(GetCVar("Sound_SFXVolume")) or 0) > 0 then
        PlaySound(SOUNDKIT.UI_BAG_SORTING_01, "Master")
    end
    EUI.HoldCVar("Sound_EnableSFX", "0", SOUND_OWNER)
    -- After the hold: CVAR_UPDATE fires at once, and the hold's own write must not count as the player's.
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    events:RegisterEvent("CVAR_UPDATE")

    r.co = coroutine.create(Body)
    Resume(r, r)
    return true
end
