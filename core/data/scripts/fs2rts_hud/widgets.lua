-- HUD widgets: button drawing, range-ring cache, top-bar counter sampling.
local _shared = require "fs2rts_hud.common"
local U, RTS = _shared.U, _shared.RTS

local Config = require "fs2rts_config"

local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys

function RTS:GetShipShortOrderLabel(ship)
    if not self:IsFriendly(ship) then return "CONTACT" end
    local service=self.FleetServices and self.FleetServices[ship:getSignature()]
    if service then return service.phase:gsub('_',' ') end
    local label = self:GetShipCommandLabel(ship)
    label = string.gsub(label, "PLAYER ORDER: ", "")
    label = string.gsub(label, "DEFAULT POLICY: ", "")
    label = string.gsub(label, "AI SECONDARY: ", "")
    label = string.gsub(label, "AI PRIMARY: ", "")
    if #label > 18 then label = string.sub(label,1,18) end
    return label
end

function RTS:DrawButton(rect, text, enabled, active)
    if enabled == false then
        gr.setColor(38, 42, 48, 210)
    elseif active then
        gr.setColor(32, 104, 126, 245)
    else
        gr.setColor(20, 55, 72, 225)
    end
    gr.drawRectangle(rect.x1, rect.y1, rect.x2, rect.y2, true)

    if enabled == false then gr.setColor(110, 115, 120, 255)
    elseif active then gr.setColor(235, 255, 255, 255)
    else gr.setColor(180, 235, 255, 255) end
    gr.drawRectangle(rect.x1, rect.y1, rect.x2, rect.y2, false)

    local m = self:GetUIMetrics()
    local inset=math.min(m.buttonPadding,math.floor((rect.x2-rect.x1)*.15))
    local width = math.max(1, rect.x2 - rect.x1 - 2*inset)
    local height = math.max(1, rect.y2 - rect.y1 - 8)
    -- Wrapping and line count are both decided in PIXELS, from the button's own
    -- size, instead of from a character estimate. The old version assumed
    -- 8px per character, which under-counted lines in a proportional font and
    -- so let a long label wrap to more rows than the button had height for.
    local lines = self:WrapTextLinesToWidth(text, width, math.max(1, math.floor((height + 2) / m.lineHeight)))
    if #lines==0 then return end
    local blockHeight = (#lines-1)*m.lineHeight+self:TextHeight(lines[#lines])
    -- +1: same font-cell offset as the role badge; the caps sat ~1.5px above centre.
    local textY = rect.y1 + math.max(0, math.floor((rect.y2 - rect.y1 - blockHeight) / 2)) + 1
    for i, line in ipairs(lines) do
        -- Three-argument form: the lines are already wrapped to the button, so
        -- letting the engine re-wrap them (the five-argument form) would reflow
        -- them a second time and can push a row past the button's bottom edge.
        self:DrawCenteredTextClipped(line,rect.x1+inset,rect.x2-inset,textY+(i-1)*m.lineHeight)
    end
end

-- Command points, fleet count and contact count are three integers, but
-- computing them walks the whole ship list. Doing that twice inside DrawTopBar
-- meant two full EachShip passes (thousands of ADE property reads) every frame
-- purely to print numbers the player cannot read changing at 60Hz. Sample them
-- on a timer instead: the numbers are a strategic readout, not an animation.
local TOPBAR_SAMPLE_SECONDS = 0.35

function RTS:SampleTopBarCounters()
    local now = self:UINow()
    local sample = self.TopBarCounters
    if sample == nil or (now - (sample.at or -1e9)) >= TOPBAR_SAMPLE_SECONDS then
        sample = {
            at = now,
            fleet = self:CountFriendlyCombatants(),
            fleetCap = self:GetFleetCap("BLUE"),
            contacts = self:CountHostiles(),
        }
        self.TopBarCounters = sample
    end
    return sample
end

-- The top bar used to place its fields at literal x positions (14/170/300/450/
-- 610/770) and right-align the rest against sw-700 / sw-440. Below roughly
-- 1474px the note's right edge (sw-704) fell behind its left edge (770), which
-- is a gr.drawString argument error the engine only warns about once, and the
-- tier readout overwrote the policy field. Everything is now measured and laid
-- out left to right, and whatever does not fit is shortened, then dropped, in
-- a fixed order rather than by whatever happened to be last.
