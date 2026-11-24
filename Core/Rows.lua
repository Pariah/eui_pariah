-- EUI Pariah option rows: every settings row goes through EllesmereUI's DualRow, described by these helpers,
-- so pages share one look and are indexed by EUI's search.
local _, addon = ...

local NOTE_GREY = { 0.6, 0.6, 0.6 }
local NOTE_RED = { 1, 0.45, 0.45 }

function addon.Header(W, parent, y, text)
    local _, h = W:SectionHeader(parent, text, y)
    return y - (h or 0)
end

-- One row of two controls; a missing right side is left empty.
function addon.Pair(W, parent, y, left, right)
    local _, h = W:DualRow(parent, y, left, right or { type = "label", text = "" })
    return y - (h or 0)
end

-- A line of plain text under the rows. opt: height (default 30), warning (red).
function addon.Note(parent, y, text, opt)
    local EUI = EllesmereUI
    local height = opt and opt.height or 30
    if EUI.IsSearchPrebuild() then return y - height end
    local c = opt and opt.warning and NOTE_RED or NOTE_GREY
    local note = EUI.MakeFont(parent, 11, nil, c[1], c[2], c[3], 1)
    note:SetPoint("TOPLEFT", parent, "TOPLEFT", EUI.CONTENT_PAD + 4, y - 10)
    note:SetPoint("RIGHT", parent, "RIGHT", -EUI.CONTENT_PAD, 0)
    note:SetJustifyH("LEFT")
    note:SetText(text)
    return y - height
end

-- Row builders bound to one feature's settings (F.db). onChange runs after every write.
function addon.Rows(F, onChange)
    local R = {}

    local function Changed(refreshPage)
        if onChange then onChange() end
        if refreshPage then EllesmereUI:RefreshPage() end
    end

    -- kind: toggle | slider | dropdown.
    -- opt: tooltip, min, max, step, values, order, disabled, disabledTooltip, refreshPage (other rows depend on this one).
    function R.Row(key, kind, text, opt)
        opt = opt or {}
        return {
            type = kind, text = text, tooltip = opt.tooltip,
            disabled = opt.disabled, disabledTooltip = opt.disabledTooltip,
            min = opt.min, max = opt.max, step = opt.step, values = opt.values, order = opt.order,
            getValue = function()
                local v = F.db[key]
                if kind == "toggle" then return v and true or false end
                return v
            end,
            setValue = function(v)
                F.db[key] = v
                Changed(opt.refreshPage)
            end,
        }
    end

    -- opt: disabled, disabledTooltip, accentKeepsColor (while the colour follows the accent, only alpha is written).
    function R.Color(key, text, opt)
        opt = opt or {}
        return {
            type = "colorpicker", text = text, hasAlpha = true,
            disabled = opt.disabled, disabledTooltip = opt.disabledTooltip,
            getValue = function() return addon.ColorOf(F.db[key]) end,
            setValue = function(r, g, b, a)
                local c = F.db[key]
                if not opt.accentKeepsColor or type(c.r) == "number" then c.r, c.g, c.b = r, g, b end
                c.a = a or c.a
                Changed()
            end,
        }
    end

    function R.FollowsAccent(key)
        return function() return type(F.db[key].r) ~= "number" end
    end

    -- On: the colour follows the EllesmereUI accent (its r, g, b cleared); off: the current accent becomes a fixed colour.
    function R.AccentToggle(key)
        return {
            type = "toggle", text = "Accent colour",
            getValue = R.FollowsAccent(key),
            setValue = function(on)
                local c = F.db[key]
                if on then
                    c.r, c.g, c.b = nil, nil, nil
                else
                    c.r, c.g, c.b = addon.Accent()
                end
                Changed(true)
            end,
        }
    end

    return R
end
