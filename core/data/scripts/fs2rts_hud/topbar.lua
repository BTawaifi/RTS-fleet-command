-- HUD top bar: counters, speed buttons, resource fields.
local _shared = require "fs2rts_hud.common"
local RTS = _shared.RTS

-- Module level. Both of these were being rebuilt inside DrawTopBar on every
-- frame for lists that never change.
local TOPBAR_SPEED_LABELS={{"pause","II"},{"0.5","0.5x"},{"1","1x"},{"2","2x"},{"4","4x"},{"8","8x"},{"16","16x"}}

local TOPBAR_COLOR_CP={92,220,255,255}

local TOPBAR_COLOR_PLAIN={230,230,230,255}

local TOPBAR_COLOR_TITLE={92,220,255,255}

local TOPBAR_COLOR_TIER={255,220,110,255}

-- The four left-hand readouts, most important first, in a full and an
-- abbreviated form, with both widths measured once per value change.
--
-- The old layout dropped the LAST field in the list that did not fit and said
-- nothing about it, so a 1280px window lost Policy, then Contacts, then Fleet,
-- and could end up showing neither the contact count nor the fleet count with
-- no sign that a readout was missing. The contact count is the one number a
-- player cannot get anywhere else in the HUD, so it gets a short form ("CON 3")
-- that fits long before the full one is given up, and a field is removed only
-- after every lower-priority field is already as short as it goes.
function RTS:TopBarFields(counts)
    local cp = math.floor(self.CommandPoints or 0)
    local policy = tostring(self.GlobalPolicy)
    local cache = self.TopBarFieldCache
    if cache ~= nil and cache.cp == cp and cache.fleet == counts.fleet
        and cache.fleetCap == counts.fleetCap and cache.contacts == counts.contacts
        and cache.policy == policy then
        return cache.fields
    end
    -- The font does not change mid-mission, so a width measured when the text
    -- was built stays correct: the same answer for a fraction of the work.
    local function field(long, short, colour)
        return { long=long, short=short, colour=colour,
                 longW=self:TextWidth(long), shortW=self:TextWidth(short) }
    end
    cache = {
        cp = cp, fleet = counts.fleet, fleetCap = counts.fleetCap,
        contacts = counts.contacts, policy = policy,
        fields = {
            field("CP: "..cp, "CP "..cp, TOPBAR_COLOR_CP),
            field("Fleet: "..counts.fleet.."/"..counts.fleetCap,
                  "FLT "..counts.fleet.."/"..counts.fleetCap, TOPBAR_COLOR_PLAIN),
            field("Contacts: "..counts.contacts, "CON "..counts.contacts, TOPBAR_COLOR_PLAIN),
            field("Policy: "..policy, "POL "..policy, TOPBAR_COLOR_PLAIN),
        },
    }
    self.TopBarFieldCache = cache
    return cache.fields
end

function RTS:DrawTopBar(sw)
    local m = self:GetUIMetrics(sw)
    local barH = m.topBarHeight
    gr.setColor(4,10,18,225); gr.drawRectangle(0,0,sw,barH,true)

    local btnW = m.pad(58); local btnGap = math.max(5, m.pad(5)); local btnH = m.pad(31)
    local pitch = btnW + btnGap
    local speedLabels = TOPBAR_SPEED_LABELS
    local clusterW = #speedLabels * pitch - btnGap
    local clusterX1 = sw - m.margin - clusterW
    local textY = math.floor((barH - m.lineHeight) / 2)

    -- Right-hand cluster: the speed buttons own their space, so they are placed
    -- first and the text fields get whatever is left of the bar.
    self.TimeButtonRects = {}
    local bx = clusterX1
    for _,d in ipairs(speedLabels) do
        local r = {x1=bx, y1=math.floor((barH-btnH)/2), x2=bx+btnW, y2=math.floor((barH-btnH)/2)+btnH}
        self.TimeButtonRects[d[1]] = r
        local active = (d[1]=="pause" and self.Paused==true) or tonumber(d[1])==(self.TimeScale or 1)
        self:DrawButton(r, d[2], true, active==true,false)
        bx = bx + pitch
    end

    local cursor = clusterX1 - m.gap
    local limit = m.margin
    self.SceneButtonRect={x1=limit,y1=math.floor((barH-btnH)/2),x2=limit+m.pad(58),y2=math.floor((barH-btnH)/2)+btnH}
    self:DrawButton(self.SceneButtonRect,'SCENE',true,self.EnvironmentPicker==true)
    limit=self.SceneButtonRect.x2+m.gap
    self.ExitMenuButtonRect=nil
    if not self.SetupActive and not self.PostBattleActive then
        self.ExitMenuButtonRect={x1=limit,y1=math.floor((barH-btnH)/2),x2=limit+m.pad(58),y2=math.floor((barH-btnH)/2)+btnH}
        self:DrawButton(self.ExitMenuButtonRect,'EXIT (ESC)',true,false)
        limit=self.ExitMenuButtonRect.x2+m.gap
    end

    if not self.SetupActive then
        local duration = self:GetEscalationProfile()
        if duration then
            local tier = self:GetCurrentEscalationTier()
            local elapsed = self:FormatTime(self:GetScenarioElapsed())
            local tierLong = "TIER "..tier.."   ELAPSED "..elapsed
            local tierShort = "T"..tier.."  "..elapsed
            local wTierLong=self:TextWidth(tierLong)
            local wTierShort=self:TextWidth(tierShort)
            local space = cursor - limit
            local tierText, tierW
            if wTierLong + m.gap <= space then
                tierText, tierW = tierLong, wTierLong
            elseif wTierShort + m.gap <= space then
                tierText, tierW = tierShort, wTierShort
            end
            if tierText ~= nil then
                gr.setColor(TOPBAR_COLOR_TIER[1],TOPBAR_COLOR_TIER[2],TOPBAR_COLOR_TIER[3],TOPBAR_COLOR_TIER[4])
                gr.drawString(tierText, cursor - tierW, textY)
                cursor = cursor - tierW - m.gap
            end
        end
    end

    -- Left-aligned fields. Shorten the least important one first, then the next,
    -- and only give a field up when nothing cheaper is left. The order of
    -- sacrifice is: shorten the tail, then the title, then the tail again. The
    -- title goes before the readouts rather than after because it is the most
    -- expensive single item in the bar (a twelve character heading is wider
    -- than any abbreviated readout) and the least informative; keeping it and
    -- dropping "Fleet: 300/64" in its place is the wrong trade at a narrow
    -- width. The readouts themselves go in priority order, command points
    -- last, because it is the one number every other decision is measured
    -- against.
    local counts = self:SampleTopBarCounters()
    local fields = self:TopBarFields(counts)
    local title = "FLEET COMMAND"
    local titleW = self:TextWidth(title)
    local space = cursor - limit
    local count, shortFrom, keepTitle = #fields, #fields + 1, true
    while true do
        local needed = keepTitle and (titleW + m.gap) or 0
        for i = 1, count do
            local field = fields[i]
            needed = needed + ((i >= shortFrom) and field.shortW or field.longW) + m.gap
        end
        if needed <= space then break end
        if shortFrom > 1 then shortFrom = shortFrom - 1
        elseif keepTitle then keepTitle = false
        elseif count > 1 then count = count - 1
        else count = 0; break end
    end
    if keepTitle then
        gr.setColor(TOPBAR_COLOR_TITLE[1],TOPBAR_COLOR_TITLE[2],TOPBAR_COLOR_TITLE[3],TOPBAR_COLOR_TITLE[4])
        gr.drawString(title, limit, textY)
    end
    local x = limit + (keepTitle and (titleW + m.gap) or 0)
    for i = 1, count do
        local field = fields[i]
        local short = (i >= shortFrom)
        local colour = field.colour
        gr.setColor(colour[1],colour[2],colour[3],colour[4])
        gr.drawString(short and field.short or field.long, x, textY)
        x = x + ((short and field.shortW or field.longW) + m.gap)
    end
end
