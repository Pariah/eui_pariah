-- Sort Lock options: an input and a list per lock list (account, character).
-- EllesmereUI's widget factory has no text input, so both are drawn here from EUI's own font and border helpers.
-- The input takes item IDs and shift-clicked item links, comma-separated.
local _, addon = ...
local F = addon.GetFeature("SortLock")
if not F then return end

local EUI = EllesmereUI
local ROW_H, INPUT_H, ICON = 24, 24, 18
local GREY = { 0.6, 0.6, 0.6, 1 }
local UNKNOWN_ICON = 134400

local function Rebuild()
    EUI:RefreshPage(true)
end

-- Shift-clicking an item while one of our boxes has focus types its link there (AceGUI's way).
local focusedBox
local function InsertLink(link)
    if not (focusedBox and focusedBox:HasFocus() and type(link) == "string") then return end
    local text = focusedBox:GetText() or ""
    if text:match("%S") and not text:match(",%s*$") then focusedBox:Insert(", ") end
    focusedBox:Insert(link)
end
if ChatFrameUtil and ChatFrameUtil.InsertLink then
    hooksecurefunc(ChatFrameUtil, "InsertLink", InsertLink)
elseif ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", InsertLink)
end

local function Font(parent, size, r, g, b, a)
    return EUI.MakeFont(parent, size, nil, r or 1, g or 1, b or 1, a or 1)
end

local function Commit(which, box)
    local added = F.AddFromText(which, box:GetText())
    box:SetText("")
    box:ClearFocus()
    if added > 0 then Rebuild() end
end

-- Input box + Add button, then a hint line. Returns the block height.
local function BuildInput(parent, y, width, which)
    local block = CreateFrame("Frame", nil, parent)
    block:SetPoint("TOPLEFT", parent, "TOPLEFT", EUI.CONTENT_PAD, y - 10)
    block:SetSize(width, INPUT_H + 22)

    local add = CreateFrame("Button", nil, block)
    add:SetSize(70, INPUT_H)
    add:SetPoint("TOPRIGHT", block, "TOPRIGHT", 0, 0)
    local ar, ag, ab = addon.Accent()
    local addBg = add:CreateTexture(nil, "BACKGROUND")
    addBg:SetAllPoints()
    addBg:SetColorTexture(ar, ag, ab, 0.20)
    EUI.MakeRoundedBorder(add, ar, ag, ab, 0.7, addBg)
    local addText = Font(add, 11, 1, 1, 1, 0.9)
    addText:SetPoint("CENTER")
    addText:SetText("Add")
    add:SetScript("OnEnter", function() addBg:SetColorTexture(ar, ag, ab, 0.35) end)
    add:SetScript("OnLeave", function() addBg:SetColorTexture(ar, ag, ab, 0.20) end)

    local box = CreateFrame("EditBox", nil, block)
    box:SetPoint("TOPLEFT", block, "TOPLEFT", 0, 0)
    box:SetPoint("RIGHT", add, "LEFT", -8, 0)
    box:SetHeight(INPUT_H)
    local probe = Font(block, 11)
    box:SetFont(probe:GetFont())
    probe:Hide()
    box:SetTextColor(1, 1, 1, 0.9)
    box:SetAutoFocus(false)
    box:SetTextInsets(6, 6, 3, 3)
    box:SetMaxLetters(2000)
    local boxBg = box:CreateTexture(nil, "BACKGROUND")
    boxBg:SetAllPoints()
    boxBg:SetColorTexture(0, 0, 0, 0.4)
    EUI.MakeRoundedBorder(box, 1, 1, 1, 0.10, boxBg)
    box:SetScript("OnEditFocusGained", function(self) focusedBox = self end)
    box:SetScript("OnEditFocusLost", function(self) if focusedBox == self then focusedBox = nil end end)
    box:SetScript("OnEnterPressed", function(self) Commit(which, self) end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    add:SetScript("OnClick", function() Commit(which, box) end)

    local hint = Font(block, 10, unpack(GREY))
    hint:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -5)
    hint:SetText("Item IDs or shift-clicked items, separated by commas. Enter adds them.")
    return INPUT_H + 32
end

-- Icon, name and ID; hover shows the item, the x removes it. Uncached names fill in when the item loads.
local function BuildRow(parent, y, width, which, itemID)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", EUI.CONTENT_PAD, y)
    row:SetSize(width, ROW_H)
    row:EnableMouse(true)

    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON, ICON)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetTexture(C_Item.GetItemIconByID(itemID) or UNKNOWN_ICON)

    local idText = Font(row, 10, unpack(GREY))
    idText:SetPoint("RIGHT", row, "RIGHT", -30, 0)
    idText:SetText(tostring(itemID))

    local name = Font(row, 11)
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", idText, "LEFT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    local function Fill()
        local itemName, _, quality = C_Item.GetItemInfo(itemID)
        if itemName then
            local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1]
            name:SetText(color and color.hex and (color.hex .. itemName .. "|r") or itemName)
            icon:SetTexture(C_Item.GetItemIconByID(itemID) or UNKNOWN_ICON)
            return true
        end
        name:SetText("|cff999999Item " .. itemID .. "|r")
    end
    if not Fill() and Item and Item.CreateFromItemID then
        local item = Item:CreateFromItemID(itemID)
        if not item:IsItemEmpty() then item:ContinueOnItemLoad(Fill) end
    end

    local rm = CreateFrame("Button", nil, row)
    rm:SetSize(16, 16)
    rm:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    rm.icon = rm:CreateTexture(nil, "OVERLAY")
    rm.icon:SetAllPoints()
    rm.icon:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-close.png")
    rm.icon:SetAlpha(0.45)
    rm:SetScript("OnEnter", function(self) self.icon:SetAlpha(1); hl:SetColorTexture(1, 1, 1, 0.06) end)
    rm:SetScript("OnLeave", function(self) self.icon:SetAlpha(0.45); hl:SetColorTexture(1, 1, 1, 0) end)
    rm:SetScript("OnClick", function()
        F.Remove(which, itemID)
        Rebuild()
    end)

    row:SetScript("OnEnter", function(self)
        hl:SetColorTexture(1, 1, 1, 0.06)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(itemID)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        hl:SetColorTexture(1, 1, 1, 0)
        GameTooltip:Hide()
    end)
    return ROW_H
end

local function BuildList(W, parent, y, title, which)
    y = addon.Header(W, parent, y, title)
    if EUI.IsSearchPrebuild() then return y end

    local width = parent:GetWidth() - EUI.CONTENT_PAD * 2
    y = y - BuildInput(parent, y, width, which)
    local ids = F.SortedIDs(which)
    if #ids == 0 then
        local none = Font(parent, 11, unpack(GREY))
        none:SetPoint("TOPLEFT", parent, "TOPLEFT", EUI.CONTENT_PAD + 4, y - 4)
        none:SetText("Nothing locked.")
        return y - ROW_H
    end
    for _, id in ipairs(ids) do
        y = y - BuildRow(parent, y, width, which, id)
    end
    return y
end

F.AddPage("Bags", "Locked Items", function(W, parent, y)
    y = BuildList(W, parent, y, "ALL CHARACTERS", "account")
    return BuildList(W, parent, y - 10, "THIS CHARACTER", "character")
end)
