-- EUI Sort Lock hook: the bags' Sort Items button runs our sort instead of EUI's in the OneBag view while any item
-- is locked. Everything else (other views, no locks, combat) goes to EUI's own click handler untouched.
-- EllesmereUIBags exposes no sort hook or view getter, so this reads its frames' fields (EUI_Bags._sortBtn,
-- the sidebar buttons' _catIdx/_indicator); an EUI update can move them.
local _, addon = ...
local F = addon.GetFeature("SortLock")
if not F then return end

local EUI = EllesmereUI

-- OneBag is the sidebar entry with catIdx -1. The selected entry is the one whose indicator shows (EUI paints it on
-- every refresh). A sidebar never painted (hidden since login) can't have changed view: the default view type holds.
local function IsOneBag()
    for _, key in ipairs({ "_sidebarChild", "_sidebar" }) do
        local holder = EUI_Bags[key]
        if holder then
            for _, btn in ipairs({ holder:GetChildren() }) do
                if btn._catIdx ~= nil and btn:IsShown() and btn._indicator and btn._indicator:IsShown() then
                    return btn._catIdx == -1 and not btn._isGroupHeader
                end
            end
        end
    end
    return EUI._GetBagDefaultType and EUI._GetBagDefaultType() == "onebag" or false
end
F.IsOneBag = IsOneBag

local function SetButtonBusy(btn, busy)
    if busy then
        btn:EnableMouse(false)
        btn.icon:SetAlpha(0.2)
    elseif EUI_Bags._applySortEnabled then
        EUI_Bags._applySortEnabled()
    else
        btn:EnableMouse(true)
        btn.icon:SetAlpha(0.9)
    end
end

local function StartSort(btn)
    if not F.RunSort(function()
        -- EUI keeps its button off for 3 s after a sort, so a double click doesn't start a second one.
        C_Timer.After(3, function() if not F.busy then SetButtonBusy(btn, false) end end)
    end) then return end
    SetButtonBusy(btn, true)
end

-- Asks first, like EUI does before a OneBag sort, and shares EUI's "don't ask again" flag so one answer covers both.
local function ConfirmAndSort(btn)
    if EllesmereUIDB and EllesmereUIDB.bagSortWarningDismissed then return StartSort(btn) end
    EUI:ShowConfirmPopup({
        title       = "Sort with Locks",
        message     = "This really moves your items into OneBag's order, so the new order stays even without EllesmereUI Bags.\n\nLocked items keep their slots.",
        confirmText = "Sort",
        cancelText  = "Cancel",
        checkbox    = "Don't ask again",
        onConfirm   = function(dontShowAgain)
            if dontShowAgain then
                EllesmereUIDB = EllesmereUIDB or {}
                EllesmereUIDB.bagSortWarningDismissed = true
            end
            StartSort(btn)
        end,
    })
end

local installed = false
local function Install()
    if installed then return end
    local btn = EUI_Bags and EUI_Bags._sortBtn
    if not btn then return end
    local original = btn:GetScript("OnClick")
    if not original then return end
    installed = true
    btn:SetScript("OnClick", function(self, ...)
        if F.busy then return end
        -- refreshEnabled is off while EUI's own sort moves items.
        if F.HasLocks() and EUI_Bags.refreshEnabled ~= false and not InCombatLockdown() and IsOneBag() then
            return ConfirmAndSort(self)
        end
        return original(self, ...)
    end)
end

-- EUI builds the header (and the sort button) 0.5 s after PLAYER_LOGIN; the first open is the latest it can be.
if EUI_Bags then
    EUI_Bags:HookScript("OnShow", Install)
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        C_Timer.After(2, Install)
    end)
end
