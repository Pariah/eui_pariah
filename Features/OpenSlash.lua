-- /ec: a short alias for EllesmereUI's /eui. Hands straight to EUI's own handler, looked up on each
-- use, so its combat check and one-frame defer stay EUI's.
local _, addon = ...

local F = addon.NewFeature("OpenSlash", { title = "EllesmereUI" })
if not F then return end

SLASH_EUIPARIAH_EC1 = "/ec"
SlashCmdList.EUIPARIAH_EC = function(msg)
    local open = SlashCmdList.EUIOPTIONS
    if type(open) == "function" then return open(msg) end
    F.Say("options unavailable.")
end
