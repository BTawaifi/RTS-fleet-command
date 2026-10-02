-- HUD drawing.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:GetShipShortOrderLabel(ship)
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
    local width = math.max(40, rect.x2 - rect.x1 - 14)
    local height = math.max(18, rect.y2 - rect.y1 - 8)
    -- Wrapping and line count are both decided in PIXELS, from the button's own
    -- size, instead of from a character estimate. The old version assumed
    -- 8px per character, which under-counted lines in a proportional font and
    -- so let a long label wrap to more rows than the button had height for.
    local lines = self:WrapTextLinesToWidth(text, width, math.max(1, math.floor((height + 2) / m.lineHeight)))
    local blockHeight = #lines * m.lineHeight
    local textY = rect.y1 + math.max(4, math.floor((rect.y2 - rect.y1 - blockHeight) / 2))
    for i, line in ipairs(lines) do
        -- Three-argument form: the lines are already wrapped to the button, so
        -- letting the engine re-wrap them (the five-argument form) would reflow
        -- them a second time and can push a row past the button's bottom edge.
        gr.drawString(line, rect.x1 + 7, textY + (i - 1) * m.lineHeight)
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

-- Module level. Both of these were being rebuilt inside DrawTopBar on every
-- frame for lists that never change.
local TOPBAR_SPEED_LABELS={{"pause","II"},{"0.5","0.5x"},{"1","1x"},{"2","2x"},{"4","4x"},{"8","8x"},{"16","16x"}}
local TOPBAR_COLOR_CP={92,220,255,255}
local TOPBAR_COLOR_PLAIN={230,230,230,255}
local TOPBAR_COLOR_TITLE={92,220,255,255}
local TOPBAR_COLOR_TIER={255,220,110,255}
local TOPBAR_COLOR_NOTE={140,165,180,255}

-- The four left-hand readouts, most important first, in a full and an
-- abbreviated form, with both widths measured once per value change.
--
-- The old layout dropped the LAST field in the list that did not fit and said
-- nothing about it, so a 1280px window lost Policy, then Contacts, then Fleet,
-- and could end up showing neither the contact count nor the fleet count with
-- no sign that a readout was missing. The contact count is the one number a
-- player cannot get anywhere else in the HUD, so it gets a short form ("C 3")
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
                  "F "..counts.fleet.."/"..counts.fleetCap, TOPBAR_COLOR_PLAIN),
            field("Contacts: "..counts.contacts, "C "..counts.contacts, TOPBAR_COLOR_PLAIN),
            field("Policy: "..policy, "P "..policy, TOPBAR_COLOR_PLAIN),
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
        self:DrawButton(r, d[2], true, active==true)
        bx = bx + pitch
    end

    local cursor = clusterX1 - m.gap
    local limit = m.margin

    if not self.SetupActive then
        local duration = self:GetDurationProfile()
        if duration then
            local tier = self:GetCurrentEscalationTier()
            local elapsed = self:FormatTime(self:GetScenarioElapsed())
            local tierLong = "TIER "..tier.."   "..elapsed.." / "..self:FormatTime(duration.targetSeconds)
            local tierShort = "T"..tier.."  "..elapsed
            -- Every clock in the scenario is mission time, escalation included:
            -- the wall-clock tier accumulator was removed in 1.4.1 because it
            -- was the one thing in a match the speed control did not touch. So
            -- the note reports the speed the whole game is running at, and
            -- there is no second "real time" claim to make.
            local scale = self.TimeScale or 1
            local noteLong = scale<=0 and "PAUSED"
                or (scale>1 and string.format("Tiers + income: %dx mission time", math.floor(scale))
                   or "Tiers + income: mission time")
            local noteShort = scale<=0 and "TIME PAUSED" or ("TIME x"..math.floor(scale))
            local wTierLong=self:TextWidth(tierLong); local wNoteLong=self:TextWidth(noteLong)
            local wTierShort=self:TextWidth(tierShort); local wNoteShort=self:TextWidth(noteShort)
            local space = cursor - limit
            -- Deliberate order: both in full, both abbreviated, the escalation
            -- clock alone (full then abbreviated), then nothing. The speed note
            -- is given up before the clock because the seven speed buttons
            -- immediately to its right already state the speed, while the clock
            -- is the only place the match timer appears at all.
            local tierText, noteText, tierW, noteW
            if wTierLong + wNoteLong + 2*m.gap <= space then
                tierText, noteText, tierW, noteW = tierLong, noteLong, wTierLong, wNoteLong
            elseif wTierShort + wNoteShort + 2*m.gap <= space then
                tierText, noteText, tierW, noteW = tierShort, noteShort, wTierShort, wNoteShort
            elseif wTierLong + m.gap <= space then
                tierText, tierW = tierLong, wTierLong
            elseif wTierShort + m.gap <= space then
                tierText, tierW = tierShort, wTierShort
            end
            if tierText ~= nil then
                gr.setColor(TOPBAR_COLOR_TIER[1],TOPBAR_COLOR_TIER[2],TOPBAR_COLOR_TIER[3],TOPBAR_COLOR_TIER[4])
                gr.drawString(tierText, cursor - tierW, textY)
                cursor = cursor - tierW - m.gap
            end
            if noteText ~= nil then
                gr.setColor(TOPBAR_COLOR_NOTE[1],TOPBAR_COLOR_NOTE[2],TOPBAR_COLOR_NOTE[3],TOPBAR_COLOR_NOTE[4])
                gr.drawString(noteText, cursor - noteW, textY)
                cursor = cursor - noteW - m.gap
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
        gr.drawString(title, m.margin, textY)
    end
    local x = m.margin + (keepTitle and (titleW + m.gap) or 0)
    for i = 1, count do
        local field = fields[i]
        local short = (i >= shortFrom)
        local colour = field.colour
        gr.setColor(colour[1],colour[2],colour[3],colour[4])
        gr.drawString(short and field.short or field.long, x, textY)
        x = x + ((short and field.shortW or field.longW) + m.gap)
    end
end

-- Colour per controller (see GetShipController); shared by rows, legend, card.
local CONTROLLER_COLORS={order={255,220,90},policy={110,200,255},auto={120,235,140},pilot={235,130,255},station={200,210,215},sentry={255,175,90}}

-- The selection panel's action buttons. Layout and labels are fixed for the
-- session: they come from the configured key bindings, which do not change
-- while the mod is loaded. So the two row lists and the nine label strings are
-- built once here instead of every frame, and the only per-frame state is
-- whether each button is enabled and whether it is the armed one. This panel is
-- drawn on every frame for as long as anything is selected, so it was a steady
-- drip of short-lived tables and string garbage.
local ACTION_BUTTON_ROWS={{"selectall","hold","engage","release","service"},
                         {"move","attack","pilot","focus"}}
local ACTION_BUTTON_LABELS={selectall="ALL",hold="HOLD",engage="ENGAGE",release="RELEASE",
    service="SERVICE",move="MOVE",attack="ATTACK",pilot="PILOT",focus="FOCUS"}
local ARMED_COMMAND_HINTS={move="MOVE: click destination",attack="ATTACK: click enemy",
    sentry="SENTRY: click placement (Shift: repeat)",strike="STRIKE: click target area"}

-- Fills ACTION_BUTTON_LABELS from the live bindings, so a rebind still reaches
-- the labels; called on the first draw and whenever the table is replaced.
local function bindActionButtonLabels(rts)
    local controls=rts.Config.HomeworldControls or {}
    ACTION_BUTTON_LABELS.selectall="ALL ("..(controls.SelectAll or "L")..")"
    ACTION_BUTTON_LABELS.hold="HOLD ("..(controls.Stop or "R")..")"
    ACTION_BUTTON_LABELS.engage="ENGAGE ("..(controls.Engage or "T")..")"
    ACTION_BUTTON_LABELS.release="RELEASE("..(controls.Release or "G")..")"
    ACTION_BUTTON_LABELS.service="SERVICE"
    ACTION_BUTTON_LABELS.move="MOVE ("..(controls.ArmMove or "M")..")"
    ACTION_BUTTON_LABELS.attack="ATTACK ("..(controls.ArmAttack or "K")..")"
    ACTION_BUTTON_LABELS.pilot="PILOT ("..rts.Config.Pilot.ToggleKey..")"
    ACTION_BUTTON_LABELS.focus="FOCUS ("..(controls.Focus or "F")..")"
    rts.ActionButtonLabelsBound=controls
end

function RTS:GetActionButtonState(id,commandable,pilotable,hasSelection)
    if id=="selectall" then return true,false end
    if id=="pilot" then return pilotable,false end
    if id=="focus" then return hasSelection,false end
    if id=="move" then return commandable,self.ArmedCommand=="move" end
    if id=="attack" then return commandable,self.ArmedCommand=="attack" end
    return commandable,false
end

function RTS:GetControllerColor(ship,controller)
    if controller=="enemy" then
        if self:IsThirdFaction(ship) then return 255,205,105 end
        return 255,165,145
    end
    local c=CONTROLLER_COLORS[controller] or CONTROLLER_COLORS.station
    return c[1],c[2],c[3]
end

-- Truncation is done in PIXELS, via RTS:TruncateToWidth in ui_text.lua. The
-- removed character-counting helper was wrong for FSO's proportional default
-- font: a 8px-per-character budget is narrower than the real glyphs for
-- capitals and wider for lowercase, so labels were cut at the wrong place and
-- overflowed their pane on the way out.

function RTS:GetSelectionRowOrderLabel(ship,controller)
    if controller=="order" then return string.upper(tostring(self.UserOrders[ship:getSignature()].kind)) end
    if controller=="policy" then return tostring(self.GlobalPolicy) end
    if controller=="auto" then return "AUTO" end
    if controller=="pilot" then return "PILOT" end
    if controller=="sentry" then return "SENTRY" end
    if controller=="station" then return "STATION" end
    return self:GetShipShortOrderLabel(ship)
end

-- isTurret() raises on a subsystem handle that is not a turret, so the call
-- has to stay guarded. The guard used to be an inline closure built inside the
-- per-subsystem loop, which allocated a fresh pcall target for every subsystem
-- of every selected ship on every frame; hoisting it allocates nothing.
local function isTurretSubsystem(turret)
    local ok, isTurret = pcall(function() return turret:isTurret() end)
    return ok and isTurret == true
end

-- Full loadout readout. A capital keeps every weapon in turret subsystems, so
-- ship-level banks alone would report an empty arsenal for the hulls that
-- matter most.
function RTS:GetShipLoadout(ship)
    local entries={}
    local function collect(banks,label)
        for i=1,#banks do
            local bank=banks[i]; local weapon=bank.WeaponClass
            if objectValid(bank) and objectValid(weapon) then
                local name=weapon.Name or "UNKNOWN"
                local ammoMax=tonumber(bank.AmmoMax) or 0
                local ammoLeft=tonumber(bank.AmmoLeft) or 0
                local range=tonumber(weapon.Range) or 0
                if not weapon:isBeam() then range=math.min(range,(tonumber(weapon.Speed) or 0)*(tonumber(weapon.LifeMax) or 0)) end
                entries[#entries+1]={name=name,label=label,beam=weapon:isBeam(),range=range,
                    ammoMax=ammoMax,ammoLeft=ammoLeft,count=(label=="TURRET" and #entries or nil)}
            end
        end
    end
    collect(ship.PrimaryBanks or {},"PRIMARY")
    collect(ship.SecondaryBanks or {},"SECONDARY")
    local turrets=0; local lost=0
    for i=1,#ship do
        local turret=ship[i]
        if objectValid(turret) and isTurretSubsystem(turret) then
            turrets=turrets+1
            if turret.HitpointsMax>0 and turret.HitpointsLeft<=0 then lost=lost+1 end
            collect(turret.PrimaryBanks or {},"TURRET")
            collect(turret.SecondaryBanks or {},"TURRET")
        end
    end
    return entries,turrets,lost
end

-- Every field in the card is placed from the measured card box rather than
-- from a fixed 434x314 pixel rectangle, and each label is given an explicit
-- pixel budget. The card used to be a hard 14..448 / 58..372 box with internal
-- rows at literal y offsets, so on a 4K screen it was a postage stamp in the
-- corner and its long strings were clipped by the engine rather than by the
-- layout.
function RTS:DrawSelectedUnitStats(sw,sh)
    local ships=self:GetSelectedShips(); if #ships==0 then return end
    local m=self:GetUIMetrics(sw,sh)
    local x1,y1=m.margin,m.statsTop
    local x2=x1+m.selectionWidth
    local y2=y1+((#ships==1) and m.statsSingleHeight or m.statsMultiHeight)
    local pad=m.pad(10); local inner=x2-pad; local lh=m.lineHeight
    gr.setColor(4,10,18,225); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    if #ships>1 then
        local total=0; local counts={order=0,policy=0,auto=0,pilot=0,sentry=0,station=0,enemy=0}
        for _,ship in ipairs(ships) do
            total=total+(ship.HitpointsMax>0 and clamp(ship.HitpointsLeft/ship.HitpointsMax*100,0,100) or 0)
            local controller=self:GetShipController(ship); counts[controller]=counts[controller]+1
        end
        gr.setColor(105,235,255,255); self:DrawTextLine("SELECTION STATS",x1+pad,y1+m.pad(10),inner-(x1+pad))
        gr.setColor(220,235,240,255)
        self:DrawTextLine("Units: "..#ships.."   Average hull: "..string.format("%.0f%%",total/#ships),x1+pad,y1+m.pad(10)+lh+4,inner-(x1+pad))
        -- The controller breakdown is laid out in a grid sized to the card
        -- rather than at a fixed 200px column pitch, which overflowed the pane
        -- on any width where the labels are wider than 200px.
        local columns=math.max(1,math.floor((x2-x1-2*pad)/(m.pad(150))))
        local cellW=math.floor((x2-x1-2*pad)/columns)
        local x=x1+pad; local y=y1+m.pad(10)+2*lh+8; local onLine=0
        for _,entry in ipairs({{"order","Your orders"},{"policy","Policy"},{"auto","Auto"},{"pilot","Piloted"},{"sentry","Sentry"},{"enemy","Enemy"}}) do
            local n=counts[entry[1]]
            if n>0 then
                if onLine==columns then x=x1+pad; y=y+lh+4; onLine=0 end
                local r,g,b=self:GetControllerColor(ships[1],entry[1]); gr.setColor(r,g,b,255)
                self:DrawTextLine(entry[2]..": "..n,x,y,cellW-6)
                x=x+cellW; onLine=onLine+1
            end
        end
        gr.setColor(155,185,198,255)
        self:DrawTextLine("Default policy: "..tostring(self.GlobalPolicy),x1+pad,y2-lh-6,inner-(x1+pad))
        return
    end
    local ship=ships[1]; local hp=ship.HitpointsMax>0 and clamp(ship.HitpointsLeft/ship.HitpointsMax*100,0,100) or 0; local sm=ship.Shields.CombinedMax or 0; local sl=ship.Shields.CombinedLeft or 0; local sp=sm>0 and clamp(sl/sm*100,0,100) or 0; local speed=math.abs(ship.Physics:getForwardSpeed()); local maxSpeed=math.abs(ship.Physics.VelocityMax.z); local wing=self:GetLogicalWing(ship)
    local y=y1+m.pad(9)
    gr.setColor(105,235,255,255); self:DrawTextLine(ship.Name,x1+pad,y,inner-(x1+pad))
    y=y+lh; gr.setColor(185,205,215,255); self:DrawTextLine(ship.Class.Name.." | "..(ship.Team.Name or "Unknown")..(wing and (" | "..wing.label) or ""),x1+pad,y,inner-(x1+pad))
    y=y+lh+6
    gr.setColor(220,235,240,255)
    self:DrawTextLine(string.format("Hull %.1f%% | Shields %.1f%%",hp,sp),x1+pad,y,inner-(x1+pad))
    y=y+lh; self:DrawTextLine(string.format("Speed %.0f / %.0f m/s",speed,maxSpeed),x1+pad,y,inner-(x1+pad))
    local controller=self:GetShipController(ship); local r,g,b=self:GetControllerColor(ship,controller)
    y=y+lh+6
    gr.setColor(r,g,b,255)
    y=y+self:DrawWrappedText(self:GetShipControlDescription(ship),x1+pad,y,inner-(x1+pad),lh,2)
    y=y+4
    local role=self:GetShipRole(ship)
    gr.setColor(155,185,198,255); self:DrawTextLine("Role: "..string.upper(role),x1+pad,y,inner-(x1+pad))
    local sig=ship:getSignature(); local order=self.AIOrderState and self.AIOrderState[sig]
    local obs=self.AIObservations and self.AIObservations[sig]
    local service=self.GetFleetServiceLabel and self:GetFleetServiceLabel(ship)
    local thought=service
    if not thought and order then
        local target=self:FindShipBySignature(order.targetSignature)
        local why=string.upper(order.reason or order.status or "ACTIVE")
        local phase=order.operationPhase and (" ["..order.operationPhase.."]") or ""
        local objective=shipValid(target) and (" -> "..target.Name.." "..math.floor(ship.Position:getDistance(target.Position)).."m") or ""
        thought=string.upper(order.mission or "ORDER")..phase.." / "..why..objective
    end
    if obs and obs.stalled then thought="STALLED / NO CLOSING" elseif obs and obs.mode=="RETREATING" then thought="PRESERVING FORCE / RETREAT" end
    if thought then
        y=y+lh+4
        gr.setColor(255,220,110,255); self:DrawTextLine("AI: "..thought,x1+pad,y,inner-(x1+pad))
    end
    local loadout,turrets,lostTurrets=self:GetShipLoadout(ship)
    if #loadout>0 or turrets>0 then
        y=y+lh+4
        gr.setColor(105,235,255,255); self:DrawTextLine("LOADOUT",x1+pad,y,inner-(x1+pad))
        y=y+lh
        local nameW=math.floor((x2-x1)*0.52)
        local seen={}
        for _,entry in ipairs(loadout) do
            if y>y2-m.pad(34) then break end
            local ammo=""
            if entry.ammoMax>0 then ammo="  "..math.floor(entry.ammoLeft).."/"..math.floor(entry.ammoMax) end
            local key=entry.name..ammo..tostring(entry.beam)
            if not seen[key] then
                seen[key]=true
                local kind=entry.beam and "BEAM" or (entry.label=="TURRET" and "TURRET" or entry.label)
                gr.setColor(200,225,235,255)
                self:DrawTextLine(entry.name,x1+pad,y,nameW)
                gr.setColor(145,180,195,255)
                self:DrawTextLine(kind..ammo,x1+pad+nameW+m.pad(4),y,inner-(x1+pad+nameW))
                y=y+lh
            end
        end
        local footer="Turrets: "..turrets..(lostTurrets>0 and ("  //  DESTROYED: "..lostTurrets) or "")
        gr.setColor(150,180,195,255); self:DrawTextLine(footer,x1+pad,y2-m.pad(20),inner-(x1+pad))
    end
end

local ROLE_BADGES={fighter="F",bomber="B",escort="E",capital="C",heavy="H",juggernaut="J",sentry="S",station="BASE",support="SUP"}
-- Module level, not built inside the call. DrawRoleBadge runs once per build
-- row, once per selection row and once per decorated contact, so an eight-entry
-- table literal per call was a few hundred small tables a frame for a lookup of
-- two numbers.
local ROLE_BADGE_COLORS={fighter={70,175,225},bomber={225,125,55},escort={85,195,155},capital={185,160,225},heavy={230,190,90},juggernaut={240,105,105},sentry={170,190,200},station={110,170,200}}
local ROLE_BADGE_FALLBACK_COLOR={145,165,175}
function RTS:DrawRoleBadge(role,x,y,size)
    local glyph=ROLE_BADGES[role] or "?"
    local color=ROLE_BADGE_COLORS[role] or ROLE_BADGE_FALLBACK_COLOR; gr.setColor(color[1],color[2],color[3],255)
    gr.drawRectangle(x,y,x+size,y+size,false)
    gr.setColor(240,245,248,255); self:DrawCenteredText(glyph,x,x+size,y+math.max(0,(size-15)/2))
end

function RTS:GetVisibleBuildCatalog()
    local filter=self.BuildRoleFilter or "all"; local visible={}
    for index,option in ipairs(self.BuildCatalog or {}) do
        local role=option.role
        if filter=="all" or role==filter or (filter=="capital" and (role=="heavy" or role=="juggernaut")) then
            visible[#visible+1]={index=index,option=option}
        end
    end
    return visible
end

-- Height of the selection panel's fixed header: title, hint, and the colour
-- legend (which wraps to a second line on a narrow pane). Both the row layout
-- and the panel's own drawing read this, so the rows cannot start above the
-- legend just because one of them ran first on a frame where the resolution
-- had changed.
function RTS:GetSelectionHeaderHeight(sw,sh)
    local rect=self:GetSelectionPanelRect(sw,sh)
    local m=self:GetUIMetrics(sw,sh)
    local inner=(rect.x2-m.pad(10))-(rect.x1+m.pad(10))
    local lx=rect.x1+m.pad(10); local lines=1
    for _,entry in ipairs({{"order","YOUR ORDER"},{"policy","POLICY"},{"auto","AUTO"},{"pilot","PILOT"},{"sentry","SENTRY"}}) do
        local w=self:TextWidth(entry[2])
        if lx+w>rect.x2-m.pad(10) then lx=rect.x1+m.pad(10); lines=lines+1 end
        lx=lx+w+m.pad(10)
    end
    return m.pad(8)+2*m.lineHeight+(lines-1)*m.lineHeight, m, rect
end

function RTS:DrawSelectionPanel(sw,sh)
    local rect=self:GetSelectionPanelRect(sw,sh); local x1,y1,x2,y2=rect.x1,rect.y1,rect.x2,rect.y2
    local m=self:GetUIMetrics(sw,sh); local pad=m.pad(10); local lh=m.lineHeight
    local inner=x2-pad
    local ships=self:GetSelectedShips()
    gr.setColor(4,10,18,215); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    gr.setColor(210,230,238,255); self:DrawTextLine("SELECTED: "..#ships,x1+pad,y1+m.pad(8),inner-(x1+pad))
    gr.setColor(150,180,195,255)
    self:DrawTextLine("Right-click: ground=move, enemy=attack, ally=guard",x1+pad,y1+m.pad(8)+lh,inner-(x1+pad))
    -- Colour legend. It used to advance x by (#label * 8) pixels, i.e. eight
    -- pixels per CHARACTER, which is not the width of a glyph in FSO's
    -- proportional font: the legend ran past the pane edge. It is measured now,
    -- and wraps to a second line rather than overflowing.
    local legendY=y1+m.pad(8)+2*lh
    local lx=x1+pad; local legendWidth=inner-x1-pad
    for _,entry in ipairs({{"order","YOUR ORDER"},{"policy","POLICY"},{"auto","AUTO"},{"pilot","PILOT"},{"sentry","SENTRY"}}) do
        local c=CONTROLLER_COLORS[entry[1]]
        local w=self:TextWidth(entry[2])
        if lx+w>x2-pad then lx=x1+pad; legendY=legendY+lh end
        gr.setColor(c[1],c[2],c[3],255); gr.drawString(entry[2],lx,legendY)
        lx=lx+w+m.pad(10)
    end
    self.LegendBottomY=legendY+lh
    -- Row columns, measured from the pane instead of at literal 23/218/274.
    local badgeSize=math.max(17,m.pad(17))
    local hpX=x1+math.floor(m.selectionWidth*0.53)
    local labelX=x1+math.floor(m.selectionWidth*0.70)
    local nameX=x1+pad+badgeSize+m.pad(6)
    for index=1,self.SelectionRowsShown or 0 do
        local row=self.SelectionRows[index]; local r=row.rect
        if self.HoveredSelectionRow==index then gr.setColor(55,75,82,225); gr.drawRectangle(r.x1,r.y1,r.x2,r.y2,true) end
        local cr,cg,cb=self:GetControllerColor(row.ships[1],row.controller); gr.setColor(cr,cg,cb,255)
        local hp=0; local primary=false
        for _,ship in ipairs(row.ships) do
            hp=hp+(ship.HitpointsMax>0 and math.max(0,ship.HitpointsLeft/ship.HitpointsMax*100) or 0)
            if ship:getSignature()==self.PrimarySelectionSignature then primary=true end
        end
        local name=#row.ships==1 and row.ships[1].Name or (row.className.." x"..#row.ships)
        local role=self:GetShipRole(row.ships[1]); self:DrawRoleBadge(role,r.x1+3,r.y1+math.floor((m.selectionRowHeight-badgeSize)/2),badgeSize)
        self:DrawTextLine((primary and ">" or " ")..name,nameX,r.y1+math.floor((m.selectionRowHeight-lh)/2),hpX-nameX-m.pad(6))
        self:DrawTextLine(string.format("%3.0f%%",hp/#row.ships),hpX,r.y1+math.floor((m.selectionRowHeight-lh)/2),labelX-hpX-m.pad(4))
        self:DrawTextLine(row.label,labelX,r.y1+math.floor((m.selectionRowHeight-lh)/2),r.x2-labelX-m.pad(4))
    end
    if #self.SelectionRows>(self.SelectionRowsShown or 0) then
        local hidden=0; for index=(self.SelectionRowsShown or 0)+1,#self.SelectionRows do hidden=hidden+#self.SelectionRows[index].ships end
        gr.setColor(170,195,205,255); self:DrawTextLine("+ "..hidden.." more ships",x1+pad,self.SelectionMoreY,inner-(x1+pad))
    end

    local controls=self.Config.HomeworldControls or {}
    if self.ActionButtonLabelsBound~=controls then bindActionButtonLabels(self) end
    local commandable=false; local pilotable=false
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do
        if self:IsMovableFriendly(ship) then commandable=true end
        if self:IsPilotableShip(ship) then pilotable=true end
    end
    -- The action buttons, without the nine nested tables and nine label
    -- concatenations this used to build every frame. The layout and the labels
    -- are fixed for the session (they come from the configured key bindings),
    -- so they are module constants built once; only enabled and active change
    -- from frame to frame, and those are two values out of a function rather
    -- than a table each.
    self.ActionButtonRects={}; local gap=m.pad(8)
    local btnH=math.max(30,m.pad(30))
    local hasSelection=#ships>0
    for rowIndex,ids in ipairs(ACTION_BUTTON_ROWS) do
        local bw=math.floor(((x2-x1)-2*pad-gap*(#ids-1))/#ids)
        local by=y2-btnH-(rowIndex==1 and (btnH+math.max(8,m.pad(8))) or 0); local bx=x1+pad
        for _,id in ipairs(ids) do
            local br={x1=bx,y1=by,x2=bx+bw,y2=by+btnH}; self.ActionButtonRects[id]=br
            local enabled,active=self:GetActionButtonState(id,commandable,pilotable,hasSelection)
            self:DrawButton(br,ACTION_BUTTON_LABELS[id],enabled,active); bx=bx+bw+gap
        end
    end

    if self.ArmedCommand~=nil then
        local mx,my=io.getMouseX(),io.getMouseY()
        gr.setColor(255,220,90,255)
        self:DrawTextLine(ARMED_COMMAND_HINTS[self.ArmedCommand] or "",mx+18,my+18,math.max(120,m.sw-mx-40))
    end
end

function RTS:DrawBuildPanel(sw,sh)
    local rect=self:GetProductionPanelRect(sw,sh); local x1,y1,x2,y2=rect.x1,rect.y1,rect.x2,rect.y2
    local m=self:GetUIMetrics(sw,sh); local pad=m.pad(10); local lh=m.lineHeight
    -- Page size comes from CountBuildRows, which counts rows using the same
    -- geometry this loop draws them with. It used to be a separate formula,
    -- floor((height-142)/50), while the loop tested y+44 against y2-74: the two
    -- disagreed by a whole row, and at 768p the loop's guard was already false
    -- on the first iteration, so the production panel drew NO build rows at all.
    self.BuildRowsPerPage=self:CountBuildRows(sw,sh)
    gr.setColor(4,10,18,220); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false); gr.setColor(100,190,220,255)
    local tabW=math.floor((x2-x1-2*m.pad(12))/2); local stationTab=self.PanelTab=="station"
    local tabY1=y1+m.buildTabTop; local tabY2=tabY1+m.buildTabHeight
    self.PanelTabRects={production={x1=x1+m.pad(8),y1=tabY1,x2=x1+m.pad(8)+tabW,y2=tabY2},station={x1=x1+m.pad(16)+tabW,y1=tabY1,x2=x2-m.pad(8),y2=tabY2}}
    self:DrawButton(self.PanelTabRects.production,"PRODUCTION",true,not stationTab); self:DrawButton(self.PanelTabRects.station,"STATION",true,stationTab)
    local now=mn.getMissionTime()
    if stationTab then
        self.BuildButtonRects={}; self.BuildNavRects={}; self.QuickGroupRects={}; self.PolicyButtonRects={}; self.FormationButtonRect=nil; self.MusicButtonRect=nil
        self:DrawStationPanel(x1+pad,y1+m.pad(36),x2-pad,y2-m.pad(76)); self:DrawStationTooltip(rect)
    else
    local filter=self.BuildRoleFilter or "all"; local visible=self:GetVisibleBuildCatalog()
    local pages=math.max(1,math.ceil(#visible/self.BuildRowsPerPage)); self.BuildPage=clamp(self.BuildPage,1,pages); local navY=y1+m.buildNavTop
    local navH=m.buildNavHeight; local navPrevW=m.pad(60); local navNextW=m.pad(60)
    self.BuildNavRects={prev={x1=x1+pad,y1=navY,x2=x1+pad+navPrevW,y2=navY+navH},
        filter={x1=x1+pad+navPrevW+m.pad(4),y1=navY,x2=x2-pad-navNextW-m.pad(4),y2=navY+navH},
        next={x1=x2-pad-navNextW,y1=navY,x2=x2-pad,y2=navY+navH}}
    self:DrawButton(self.BuildNavRects.prev,"< PREV",self.BuildPage>1,false); self:DrawButton(self.BuildNavRects.next,"NEXT >",self.BuildPage<pages,false); self:DrawButton(self.BuildNavRects.filter,"FILTER: "..string.upper(filter).."  "..self.BuildPage.."/"..pages,true,false)
    self.BuildButtonRects={}; local y=navY+m.buildFirstRowOffset
    local start=(self.BuildPage-1)*self.BuildRowsPerPage+1; local finish=math.min(#visible,start+self.BuildRowsPerPage-1)
    local rowLimit=y2-m.buildFooter; local thumbW=math.max(40,m.pad(40)); local badge=math.max(18,m.pad(18))
    for visibleIndex=start,finish do local item=visible[visibleIndex]; local i=item.index; local option=item.option
    -- Same guard CountBuildRows used to size the page, so the page size and the
    -- rows actually drawn still cannot disagree.
    if y+m.buildRowHeight>rowLimit then break end
    local rb={x1=x1+pad,y1=y,x2=x2-pad,y2=y+m.buildRowHeight}; self.BuildButtonRects[i]=rb; local unlocked=self:IsBuildOptionUnlocked(option,now); local enabled=unlocked and self.CommandPoints>=option.cost and self:GetCarrier()~=nil; local units=(option.count or 1)>1 and (" x"..option.count) or ""; local label; if unlocked then label="T"..option.tier.." "..option.label..units.." | "..option.cost.." CP | "..string.format("%.0fs",option.time*(self:GetDurationProfile().buildTimeScale or 1)*self:GetBuildTimeMultiplier("BLUE")) else label="T"..option.tier.." LOCKED "..self:FormatTime(self:GetTierUnlockRemaining(option.tier,now)).." | "..option.label..units end; self:DrawButton(rb,"",enabled,false)
    if not self:DrawShipModelThumb(option.class,rb.x1+2,rb.y1+2,rb.x1+2+thumbW,rb.y2-2) then local tex=self:GetBriefingIcon(option.class,option.role,false); if tex then gr.setColor(255,255,255,enabled and 255 or 120); gr.drawImage(tex,rb.x1+4,rb.y1+4,rb.x1+thumbW,rb.y2-4) end end
    self:DrawRoleBadge(option.role,rb.x2-badge-6,rb.y1+math.floor((m.buildRowHeight-badge)/2),badge)
    local textX=rb.x1+2+thumbW+m.pad(4)
    if enabled then gr.setColor(225,240,245,255) else gr.setColor(120,140,150,255) end
    local textY=rb.y1+math.floor((m.buildRowHeight-lh)/2)
    self:DrawTextLine(label,textX,textY,rb.x2-badge-8-textX)
    y=y+m.buildRowPitch end
    self:DrawBuildTooltip(sw,sh,rect)
    end
    local manual="Manual: idle"; local manualStatus=self:GetProductionQueueStatus("BLUE",now,false); if manualStatus then manual="Manual: "..manualStatus.label.." x"..manualStatus.count.." T-"..self:FormatTime(math.ceil(manualStatus.remaining)).." (+"..tostring(manualStatus.queued).." queued, "..manualStatus.active.."/"..manualStatus.slots.." lanes)" end
    gr.setColor(170,195,205,255); self:DrawTextLine(manual,x1+pad,y2-m.buildFooter+m.pad(4),(x2-pad)-(x1+pad))
    local autoState=self.AIStates and self.AIStates.BLUE or nil; local autoText="Auto: idle"
    local autoStatus=self:GetProductionQueueStatus("BLUE",now,true)
    if self.AutoPlayerMode and autoStatus then local wait=autoStatus.waitingForCapacity and " WAIT CAP" or ""; autoText="Auto: "..autoStatus.label.." x"..autoStatus.count.." T-"..self:FormatTime(math.ceil(autoStatus.remaining)).." (+"..tostring(autoStatus.queued).." queued)"..wait elseif self.AutoPlayerMode then autoText="Auto: evaluating fleet / saving CP" end
    gr.setColor(150,180,195,255); self:DrawTextLine(autoText,x1+pad,y2-m.buildFooter+m.pad(26),(x2-pad)-(x1+pad))
    local autoH=math.max(22,m.pad(22))
    self.AutoModeRect={x1=x1+pad,y1=y2-autoH-m.pad(5),x2=x2-pad,y2=y2-m.pad(5)}; self:DrawButton(self.AutoModeRect,self.AutoPlayerMode and "AUTO MODE: ON" or "AUTO MODE: OFF",true,self.AutoPlayerMode)
end


-- Draws the class's own 3D model (unique per ship, unlike briefing icons).
-- renderTechModel replaces the view/projection matrices that mouse picking
-- (getScreenCoords, getVectorFromCoords) relies on, so each class is rendered
-- once into a cached texture and only the texture is drawn per frame.
function RTS:DrawShipModelThumb(className,x1,y1,x2,y2)
    local tex=self:GetShipThumbTexture(className)
    if not tex then return false end
    gr.setColor(255,255,255,255); gr.drawImage(tex,x1,y1,x2,y2)
    return true
end

function RTS:GetShipThumbTexture(className)
    local cache=self.ShipThumbCache or {}; self.ShipThumbCache=cache
    local tex=cache[className]
    if tex==nil then
        tex=false
        local cls=tb.ShipClasses[className]
        if cls~=nil and cls:isValid() then
            local ok,made=pcall(function()
                local t=gr.createTexture(256,256)
                gr.setTarget(t); gr.clearScreen(0,0,0,0)
                local drawn=cls:renderTechModel(0,0,256,256,0,-15,0,1.1,true)
                gr.setTarget()
                return drawn and t or nil
            end)
            if not ok then pcall(function() gr.setTarget() end) end
            if ok and made then tex=made end
        end
        cache[className]=tex
    end
    return tex or nil
end

-- Revolving preview for the build tooltip. renderTechModel is a real model
-- render: doing it every frame while the cursor merely hovered a row was the
-- most expensive thing the HUD did. It is now re-rendered on a timer, which
-- still reads as a rotation (the spin is 8 degrees per second) at a fraction
-- of the cost. renderTechModel also replaces the view/projection matrices that
-- mouse picking relies on, but only while the cursor is over the build panel,
-- where clicks are UI clicks rather than world picks.
local TOOLTIP_MODEL_INTERVAL = 1/15

function RTS:DrawRotatingModel(className,x1,y1,x2,y2)
    local cls=tb.ShipClasses[className]; if cls==nil or not cls:isValid() then return end
    if self.TooltipModelTex==nil then local ok,t=pcall(function() return gr.createTexture(256,256) end); self.TooltipModelTex=ok and t or false end
    local tex=self.TooltipModelTex; if not tex then return end
    local now=self:UINow()
    local spin=(self:UINow()*8)%100
    if self.TooltipModelClass==className and self.TooltipModelAt and (now-self.TooltipModelAt)<TOOLTIP_MODEL_INTERVAL then
        gr.setColor(255,255,255,255); gr.drawImage(tex,x1,y1,x2,y2); return
    end
    local ok=pcall(function()
        gr.setTarget(tex); gr.clearScreen(0,0,0,0)
        cls:renderTechModel(0,0,256,256,spin,-15,0,1.1,true)
        gr.setTarget()
    end)
    if not ok then pcall(function() gr.setTarget() end); return end
    self.TooltipModelClass=className; self.TooltipModelAt=now
    gr.setColor(255,255,255,255); gr.drawImage(tex,x1,y1,x2,y2)
end

-- Hover tooltip for a build row: tech-room description plus core stats.
function RTS:DrawBuildTooltip(sw,sh,panel)
    local mx,my=io.getMouseX(),io.getMouseY(); local option=nil
    for index,rect in pairs(self.BuildButtonRects or {}) do if self:PointInside(rect,mx,my) then option=self.BuildCatalog[index] end end
    if option==nil then return end
    local cls=tb.ShipClasses[option.class]; if cls==nil or not cls:isValid() then return end
    local m=self:GetUIMetrics(sw,sh); local lh=m.lineHeight
    local ok,desc=pcall(function() return cls.TechDescription end); if not ok or type(desc)~="string" or desc=="" then desc="No tech-room description." end
    local stats=string.format("Hull %d  |  Shields %d  |  Speed %d m/s",math.floor(cls.HitpointsMax or 0),math.floor(cls.ShieldHitpointsMax or 0),math.floor(math.abs(cls.VelocityMax.z or 0)))
    -- Sized from the panel and the screen rather than a fixed 470px box, and
    -- clamped so the tooltip never runs off the right edge on a narrow window
    -- nor off the bottom on a short one.
    local w=clamp(m.pad(470),240,math.max(240,panel.x1-m.margin*2))
    local preview=math.max(110,m.pad(150)); local edge=m.pad(10); local descW=w-2*edge
    local lines=self:WrapTextLinesToWidth((desc:gsub("%s+"," ")),descW,12)
    local boxHeight=m.pad(48)+#lines*lh+preview+m.pad(8)
    local x2=panel.x1-m.pad(10); local x1=x2-w
    local y1=clamp(my-m.pad(20),m.topBarHeight+m.pad(4),math.max(m.topBarHeight+m.pad(4),sh-boxHeight-m.margin))
    local y2=y1+boxHeight
    gr.setColor(4,10,18,235); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    gr.setColor(235,245,250,255); self:DrawCenteredTextClipped(option.class..((option.count or 1)>1 and (" x"..option.count) or ""),x1+m.pad(10),x2-m.pad(10),y1+m.pad(8))
    gr.setColor(255,220,110,255); self:DrawCenteredTextClipped(stats,x1+m.pad(10),x2-m.pad(10),y1+m.pad(8)+lh)
    local side=preview-m.pad(8); local cx=math.floor((x1+x2)/2)
    self:DrawRotatingModel(option.class,cx-side/2,y1+m.pad(48),cx+side/2,y1+m.pad(48)+side)
    gr.setColor(160,200,215,255)
    for i,line in ipairs(lines) do self:DrawCenteredTextClipped(line,x1+m.pad(10),x2-m.pad(10),y1+m.pad(52)+preview+(i-1)*lh) end
end

function RTS:DrawQuickGroupsPanel(sw,sh)
    local r=self:GetQuickGroupPanelRect(sw,sh)
    -- Skipped entirely when the column solve had to drop this strip to fit the
    -- panels above it; the control groups stay reachable from their keys.
    if r.y2<=r.y1 then self.QuickGroupRects={}; return end
    local x1,y1,x2,y2=r.x1,r.y1,r.x2,r.y2
    local m=self:GetUIMetrics(sw,sh); local pad=m.pad(10)
    gr.setColor(4,10,18,220); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    gr.setColor(210,230,238,255); self:DrawTextLine("QUICK GROUPS // empty=assign | Ctrl=overwrite",x1+pad,y1+m.pad(8),(x2-pad)-(x1+pad))
    local gap=m.pad(8); local bw=((x2-x1)-2*pad-gap*3)/4; local bx=x1+pad; self.QuickGroupRects={}
    for i=1,4 do
        local br={x1=bx,y1=y1+m.pad(34),x2=bx+bw,y2=y2-m.pad(9)}; self.QuickGroupRects[i]=br; local count=self:GetControlGroupCount(i)
        self:DrawButton(br,tostring(i),true,count>0)
        gr.setColor(count>0 and 235 or 155,count>0 and 245 or 180,count>0 and 250 or 190,255)
        self:DrawCenteredTextClipped(tostring(count).." ships",br.x1+4,br.x2-4,br.y1+m.pad(24))
        bx=bx+bw+gap
    end
end

-- Group the selection into rows of (class, controller, order) so a big
-- selection reads as "GTF Ulysses x6" instead of a clipped list of names.
function RTS:RefreshSelectionListRects(sw,sh)
    local rect=self:GetSelectionPanelRect(sw,sh); local x1,y1,x2,y2=rect.x1,rect.y1,rect.x2,rect.y2
    local rows,byKey={},{}
    for _,ship in ipairs(self:GetSelectedShips()) do
        local controller=self:GetShipController(ship); local label=self:GetSelectionRowOrderLabel(ship,controller)
        local key=ship.Class.Name.."|"..controller.."|"..label.."|"..tostring(self:IsThirdFaction(ship))
        local row=byKey[key]
        if row==nil then row={ships={},sigs={},controller=controller,label=label,className=ship.Class.Name}; byKey[key]=row; rows[#rows+1]=row end
        row.ships[#row.ships+1]=ship; row.sigs[#row.sigs+1]=ship:getSignature()
    end
    -- Rows start below the measured header and stop above the action buttons,
    -- instead of at the literal y1+70 / y2-84 pair, which stopped matching the
    -- drawn header as soon as the panel was not exactly 330px tall.
    local m=self:GetUIMetrics(sw,sh); local rowHeight=m.selectionRowHeight
    local top=y1+self:GetSelectionHeaderHeight(sw,sh)+m.pad(4)
    local bottom=y2-(math.max(30,m.pad(30))*2+math.max(8,m.pad(8))+m.pad(8))
    local capacity=math.max(1,math.floor((bottom-top)/rowHeight))
    local shown=#rows<=capacity and #rows or math.max(0,capacity-1)
    self.SelectionRows=rows; self.SelectionRowsShown=shown; self.SelectionMoreY=top+shown*rowHeight+2
    self.HoveredSelectionRow=nil; self.HoveredSelectionSigs={}
    local mx,my=io.getMouseX(),io.getMouseY()
    for index=1,shown do
        local r={x1=x1+m.pad(6),y1=top+(index-1)*rowHeight,x2=x2-m.pad(6),y2=top+index*rowHeight-2}; rows[index].rect=r
        if self:PointInside(r,mx,my) then
            self.HoveredSelectionRow=index
            for _,sig in ipairs(rows[index].sigs) do self.HoveredSelectionSigs[sig]=true end
        end
    end
end

function RTS:DrawPolicyPanel(sw, sh)
    local rect=self:GetPolicyPanelRect(sw,sh); local x1,y1,x2,y2=rect.x1,rect.y1,rect.x2,rect.y2
    local m=self:GetUIMetrics(sw,sh); local lh=m.lineHeight
    gr.setColor(4,10,18,220); gr.drawRectangle(x1,y1,x2,y2,true)
    gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    gr.setColor(255,220,110,255); self:DrawCenteredTextClipped("DEFAULT POLICY",x1+m.pad(10),x2-m.pad(10),y1+m.pad(10))
    gr.setColor(145,175,190,255)
    self:DrawCenteredWrappedTextToWidth("What your ships do when you have not ordered them. Your orders always win.",
        x1+m.pad(18),x2-m.pad(18),y1+m.pad(10)+lh+6,(x2-x1)-2*m.pad(18),lh,3)
    local controls=self.Config.HomeworldControls or {}
    local defs={{id="HOLD",text="HOLD ("..(controls.HoldPolicy or "J")..")"},{id="RETREAT",text="RETREAT ("..(controls.PassivePolicy or "Z")..")"},{id="STANDOFF",text="STANDOFF ("..(controls.DefensivePolicy or "X")..")"},{id="ENGAGE",text="ENGAGE ("..(controls.AggressivePolicy or "V")..")"}}
    local gap=m.pad(8); local buttonW=math.floor(((x2-x1)-2*m.pad(10)-gap*3)/4)
    local total=buttonW*4+gap*3; local bx=x1+(x2-x1-total)/2; local by=y1+m.pad(88); local buttonH=math.max(34,m.pad(34))
    local policyEnabled=not self.AutoPlayerMode
    self.PolicyButtonRects={}
    for _,def in ipairs(defs) do local r={x1=bx,y1=by,x2=bx+buttonW,y2=by+buttonH}; self.PolicyButtonRects[def.id]=r; self:DrawButton(r,def.text,policyEnabled,self.GlobalPolicy==def.id); bx=bx+buttonW+gap end
    local description="Ships do nothing until you order them. No production, no self-preservation overrides."
    if self.GlobalPolicy=="ENGAGE" then description="Hunt enemies anywhere on the map."
    elseif self.GlobalPolicy=="RETREAT" then description="Pull back behind Blue Station, out of the fight."
    elseif self.GlobalPolicy=="STANDOFF" then description="Escort Blue Station and fight anything that comes near it." end
    if not policyEnabled then description="Default policies are disabled while Auto Mode is on." end
    gr.setColor(160,190,202,255)
    self:DrawCenteredWrappedTextToWidth(description,x1+m.pad(20),x2-m.pad(20),by+buttonH+m.pad(10),(x2-x1)-2*m.pad(20),lh,2)
    local onPolicy,onOrders=0,0
    self:EachShip(function(ship)
        if self:IsMovableFriendly(ship) then
            if self.UserOrders[ship:getSignature()]~=nil then onOrders=onOrders+1 else onPolicy=onPolicy+1 end
        end
    end)
    local split=self.AutoPlayerMode and ("Auto Mode: "..onPolicy.." | your orders: "..onOrders)
        or ("Following policy: "..onPolicy.." | your orders: "..onOrders)
    gr.setColor(255,220,110,255); self:DrawCenteredTextClipped(split,x1+m.pad(10),x2-m.pad(10),y2-lh-m.pad(8))
end

function RTS:DrawAnnouncement(sw,sh)
    if self.AnnouncementText==nil or self:UINow()>(self.AnnouncementUntil or -1) then return end
    local m=self:GetUIMetrics(sw,sh); local lh=m.lineHeight
    local width=math.min(m.pad(980),sw-2*m.margin); local x1=(sw-width)/2; local x2=x1+width
    local y1=m.topBarHeight+m.pad(8); local y2=y1+lh+m.pad(20)
    gr.setColor(0,0,0,220); gr.drawRectangle(x1,y1,x2,y2,true)
    local key=self.AnnouncementFaction
    if key=="BLUE" then gr.setColor(80,220,255,255) elseif key=="RED" then gr.setColor(255,80,80,255) elseif key=="GOLD" then gr.setColor(255,205,70,255) else gr.setColor(240,240,240,255) end
    gr.drawRectangle(x1,y1,x2,y2,false)
    self:DrawCenteredTextClipped(self.AnnouncementText,x1+m.pad(18),x2-m.pad(18),y1+math.floor((y2-y1-lh)/2))
end

-- Retail FS2 briefing icons (sparky_fs2.vp): Icon<species>-<type>.ani.
local BRIEFING_ICON_TYPE={fighter="fighter",bomber="bomber",escort="cruiser",capital="vette",heavy="cap",juggernaut="super",sentry="gun"}
local BRIEFING_ICON_HALF={fighter=6,bomber=7,escort=8,capital=9,heavy=10,juggernaut=12,sentry=6,station=11}

-- FS2 ship type (ships.tbl / objecttypes) -> briefing icon suffix.
local TYPE_ICON={fighter="fighter",bomber="bomber",cruiser="cruiser",corvette="vette",capital="cap",["super cap"]="super",
    awacs="awac",support="support",transport="transport",freighter="freight",["gas miner"]="gas",["sentry gun"]="gun",stealth="fighter",["knossos device"]="node"}

function RTS:LoadBriefingIcon(name)
    local cache=self.TacticalMapIconCache or {}; self.TacticalMapIconCache=cache
    local tex=cache[name]
    if tex==nil then tex=gr.loadTexture(name,true); if tex==nil or not tex:isValid() then tex=false end; cache[name]=tex end
    return tex or nil
end

-- Uses the class's real type and species (e.g. Ravana -> Shivan capital,
-- Deimos -> Terran corvette); falls back to the RTS role when retail has no
-- icon for that species/type pair.
function RTS:GetBriefingIcon(className, role, isStation)
    if isStation then return self:LoadBriefingIcon("iconinstall") end
    local cls=className and tb.ShipClasses[className]
    local species,typeName="T",nil
    if cls~=nil and cls:isValid() then
        local ok,s=pcall(function() return cls.Species.Name end); if ok and type(s)=="string" then species=s:sub(1,1):upper() end
        local ok2,ts=pcall(function() return cls.TypeString end); if ok2 and type(ts)=="string" then typeName=ts:lower() end
    end
    if species~="T" and species~="V" and species~="S" then species="T" end
    if (role=="fighter" or role=="bomber") and cls~=nil and cls:isValid() then
        local ok,sel=pcall(function() return cls.SelectIconFilename end)
        if (not ok or sel==nil or sel=="") and className=="SF Mara" then sel="iconfighter2s-02"; ok=true end
        local own=ok and type(sel)=="string" and sel~="" and self:LoadBriefingIcon(sel)
        if own then return own end
        -- Retail has no select icons for most Shivan strike craft; render the model.
        local thumb=self:GetShipThumbTexture(className)
        if thumb then return thumb end
    end
    local kind=typeName and TYPE_ICON[typeName]
    local tex=kind and self:LoadBriefingIcon("Icon"..species.."-"..kind)
    if tex then return tex end
    kind=BRIEFING_ICON_TYPE[role]; if kind==nil then return nil end
    return self:LoadBriefingIcon("Icon"..species.."-"..kind)
end

-- Faction colours shared by the tactical map icons and the world reticles so a
-- contact reads the same in both views.
-- Declared at file scope, ABOVE first use. These used to sit ~150 lines lower,
-- just above GetReticleFactionKey; DrawTacticalMap referenced them earlier in
-- the file, so Lua resolved a nil global and every selected contact on the
-- tactical map raised "attempt to index global 'RETICLE_COLOR_SELECTED'
-- (a nil value)" from inside the per-ship EachShip callback.
local RETICLE_COLORS={friendly={70,220,255},hostile={255,75,75},third={255,190,70}}
-- Hoisted: these were three-entry table literals evaluated inside the per-ship
-- loop, twice a frame for every decorated contact.
local RETICLE_COLOR_SELECTED={255,225,50}
local RETICLE_COLOR_HOVERED={255,255,180}

function RTS:DrawTacticalMap(sw)
    local rect=self:GetTacticalMapRect(); local x1,y1,x2,y2=rect.x1,rect.y1,rect.x2,rect.y2
    local v=self:GetMapView(); local bgAlpha=v.popped and math.floor(255*v.alpha) or 215
    local m=self:GetUIMetrics(); local lh=m.lineHeight
    gr.setColor(3,8,13,bgAlpha); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(70,135,160,255); gr.drawRectangle(x1,y1,x2,y2,false)
    local ox,oy=self:WorldToTacticalMap(vec(0,0,0)); if ox>x1 and ox<x2 then gr.drawLine(ox,y1,ox,y2) end; if oy>y1 and oy<y2 then gr.drawLine(x1,oy,x2,oy) end
    local selectedSet={}; for _,sig in ipairs(self.Selected) do selectedSet[sig]=true end
    local shipCount=#self:GetShipList(); local markerScale=(shipCount>80 and 0.8 or 1)*m.scale
    -- The map rect, the view and the configured half extent are frame-invariant
    -- and were re-derived once per ship inside WorldToTacticalMap. They are
    -- resolved once here and handed to the mapping directly.
    local mapRect=rect; local mapView=v; local mapHalf=self:GetTacticalMapHalfExtent()
    self:EachShip(function(ship)
        local draw=false
        if self:IsFriendly(ship) then gr.setColor(70,220,255,255); draw=true
        elseif self:IsHostile(ship) then gr.setColor(255,75,75,255); draw=true
        elseif self:IsThirdFaction(ship) then gr.setColor(255,190,70,255); draw=true end
        local px,py,inView=self:WorldToTacticalMapIn(ship.Position,mapRect,mapView,mapHalf)
        if draw and inView and ship.Name~=self.Config.ObserverShip then
            local isStation=self:IsCommandStation(ship); local role=self:GetShipRole(ship)
            local big=isStation or role=="capital" or role=="heavy" or role=="juggernaut" or role=="escort"
            local radius=math.max(2,math.floor((isStation and 5 or big and 4 or 3)*markerScale))
            local tex=v.shapes~=true and self:GetBriefingIcon(ship.Class and ship.Class.Name,role,isStation) or nil
            if tex then radius=math.max(3,math.floor((BRIEFING_ICON_HALF[isStation and "station" or role] or 7)*markerScale)) end
            -- Keep markers inside the map frame.
            px=clamp(px,x1+radius+2,x2-radius-2); py=clamp(py,y1+radius+2,y2-radius-2)
            if tex then
                gr.drawImage(tex,px-radius,py-radius,px+radius,py+radius)
                gr.drawCircle(radius+2,px,py,false)
            elseif big then
                gr.drawRectangle(px-radius,py-radius,px+radius,py+radius,true)
            elseif role=="bomber" then
                gr.drawRectangle(px-radius,py-radius,px+radius,py+radius,true)
            elseif role=="sentry" then
                gr.drawRectangle(px-radius,py-radius,px+radius,py+radius,true)
            else
                gr.drawCircle(radius,px,py,true)
            end
            local ring=radius+6
            if self.FleetServices and self.FleetServices[ship:getSignature()] then
                local sx,sy=px+radius+3,py-radius-3
                if sx+3<x2 and sy-3>y1 then
                    gr.setColor(120,255,165,255); gr.drawLine(sx-3,sy,sx+3,sy); gr.drawLine(sx,sy-3,sx,sy+3)
                end
            end
            if selectedSet[ship:getSignature()] and px-ring>=x1 and px+ring<=x2 and py-ring>=y1 and py+ring<=y2 then
                gr.setColor(RETICLE_COLOR_SELECTED[1],RETICLE_COLOR_SELECTED[2],RETICLE_COLOR_SELECTED[3],255); gr.drawCircle(ring,px,py,false) end
        end
    end)
    local cx,cy=self:WorldToTacticalMap(self.CameraFocus); gr.setColor(255,230,90,255); gr.drawCircle(math.max(6,math.floor(6*m.scale)),cx,cy,false)
    self:DrawOrderPing()
    self:DrawStationMapOverlay()
    if self.MapDrag then local left=clamp(math.min(self.MapDrag.x1,self.MapDrag.x2),x1,x2); local right=clamp(math.max(self.MapDrag.x1,self.MapDrag.x2),x1,x2); local top=clamp(math.min(self.MapDrag.y1,self.MapDrag.y2),y1,y2); local bottom=clamp(math.max(self.MapDrag.y1,self.MapDrag.y2),y1,y2); gr.setColor(90,220,255,230); gr.drawRectangle(left,top,right,bottom,false) end
    gr.setColor(135,175,190,255)
    self:DrawTextLine("LMB select | RMB order | Wheel zoom | MMB pan",x1+m.pad(6),y2-lh-m.pad(4),(x2-m.pad(6))-(x1+m.pad(6)))
    self:DrawMapWindowChrome(rect,v)
end

function RTS:DrawOrderPing()
    local ping=self.OrderPing; if ping==nil then return end
    local left=ping.untilTime-self:UINow(); if left<=0 then self.OrderPing=nil; return end
    local tx,ty=self:WorldToTacticalMap(ping.pos); local a=math.floor(255*math.min(1,left))
    if ping.kind=="attack" then gr.setColor(255,80,80,a) elseif ping.kind=="guard" then gr.setColor(90,255,140,a) else gr.setColor(255,225,70,a) end
    for _,sig in ipairs(ping.sigs) do local s=self:FindShipBySignature(sig); if shipValid(s) then local sx,sy=self:WorldToTacticalMap(s.Position); gr.drawLine(sx,sy,tx,ty) end end
    local pulse=4+(2-left)*8; gr.drawCircle(pulse,tx,ty,false); gr.drawLine(tx-5,ty,tx+5,ty); gr.drawLine(tx,ty-5,tx,ty+5)
end

function RTS:DrawMapWindowChrome(rect,v)
    -- The button row is measured, and the window's minimum width in
    -- ClampMapWindow is derived from it, so the chrome cannot run off the left
    -- edge of a narrow popped-out map (it used to: 238px of buttons inside a
    -- 280px floor, with the labels drawn to their literal pixel widths).
    local m=self:GetUIMetrics(); local lh=m.lineHeight
    local b={}; local bh=m.mapButtonHeight; local bgap=m.mapButtonGap; local bx=rect.x2-m.pad(4)
    local widths=m.mapButtonWidths
    local function button(key,label,w) local r={x1=bx-w,y1=rect.y1+m.pad(4),x2=bx,y2=rect.y1+m.pad(4)+bh}; b[key]=r; self:DrawButton(r,label,true,false); bx=bx-w-bgap end
    button("pop",v.popped and "DOCK" or "POP OUT",widths.pop); button("shapes",v.shapes and "ICONS" or "SHAPES",widths.shapes); button("fit","FIT",widths.fit); button("zoomOut","-",widths.zoomOut); button("zoomIn","+",widths.zoomIn)
    gr.setColor(200,225,235,255); gr.drawString(string.format("x%.1f",v.zoom),rect.x1+m.pad(6),rect.y1+m.pad(6))
    if v.popped then
        local f=self:GetTacticalMapFrame()
        gr.setColor(10,30,45,math.max(160,math.floor(255*v.alpha))); gr.drawRectangle(f.x1,f.y1,f.x2,rect.y1,true); gr.setColor(100,190,220,255); gr.drawRectangle(f.x1,f.y1,f.x2,f.y2,false)
        gr.setColor(220,238,245,255); self:DrawTextLine("TACTICAL MAP  (drag to move)",f.x1+m.pad(8),f.y1+math.max(2,math.floor((m.mapHeader-lh)/2)),math.floor((f.x2-f.x1)*0.4))
        local s={x1=f.x2-m.pad(170),y1=f.y1+math.floor(m.mapHeader/3),x2=f.x2-m.pad(20),y2=f.y1+math.floor(m.mapHeader/3)+math.max(12,m.pad(12))}; b.slider=s
        gr.setColor(60,90,105,255); gr.drawRectangle(s.x1,s.y1+4,s.x2,s.y1+8,true)
        local knob=s.x1+(s.x2-s.x1)*v.alpha; gr.setColor(255,220,110,255); gr.drawRectangle(knob-3,s.y1,knob+3,s.y2,true)
        gr.setColor(160,190,200,255); self:DrawTextLine("OPACITY",s.x1-m.pad(62),f.y1+math.max(2,math.floor((m.mapHeader-lh)/2)),m.pad(58))
        local gs=math.max(14,m.pad(14))
        local g={x1=f.x2-gs,y1=f.y2-gs,x2=f.x2,y2=f.y2}; b.grip=g; gr.setColor(255,220,110,255)
        gr.drawLine(g.x1,g.y2-1,g.x2-1,g.y1); gr.drawLine(g.x1+5,g.y2-1,g.x2-1,g.y1+5); gr.drawLine(g.x1+10,g.y2-1,g.x2-1,g.y1+10)
    end
    self.MapButtonRects=b
end

function RTS:DrawHullBarForShip(ship, x1, y1, x2, y2)
    if not shipValid(ship) or x1 == nil or x2 == nil or y2 == nil then return end
    local pct=ship.HitpointsMax>0 and clamp(ship.HitpointsLeft/ship.HitpointsMax,0,1) or 0
    local thickness=self.Config.Selection.HullBarThickness or 5
    local width=math.max(8,x2-x1)
    local left=x1; local right=x2; local yy=y2
    -- Two filled rectangles instead of one drawLine per pixel row (~10 calls
    -- per ship per frame); same bands: backing rows yy-thickness..yy, fill
    -- rows yy-thickness+1..yy-1.
    gr.setColor(8,12,14,245); gr.drawRectangle(left,yy-thickness,right,yy,true)
    if pct<0.20 then gr.setColor(255,65,65,255) elseif pct<0.55 then gr.setColor(255,220,65,255) else gr.setColor(70,255,110,255) end
    local fill=left+width*pct; if thickness>=2 then gr.drawRectangle(left,yy-thickness+1,fill,yy-1,true) end
end

-- Role glyph drawn inside the selection brackets. Each role gets a distinct
-- SILHOUETTE rather than a letter, so the mark is readable at a glance and
-- does not rely on colour alone. Shapes are deliberately simple and filled:
-- at ~11 px an outline reads as noise, a solid block does not.
-- Role glyphs. These are built from FILLING primitives (drawCircle and
-- drawRectangle with Filled=true) rather than from drawLine segments: a shape
-- assembled out of line segments is a wireframe by definition, and that is why
-- the first version of these markers read as hollow outlines on the reticle.
-- gr.drawPolygon is not usable here because the engine documents it as
-- unreliable outside of On Object Render, and the HUD overlay is a 2D hook.
-- Small filled discs approximate the round glyph cleanly at this pixel size
-- and stay filled at every zoom level.
local function diamond(gr,cx,cy,rx,ry) -- filled diamond via two rotated bars
    gr.drawRectangleCentered(cx,cy,rx*2,ry*0.5,true,math.rad(45))
    gr.drawRectangleCentered(cx,cy,rx*0.5,ry*2,true,math.rad(45))
end
local ROLE_MARKER_SHAPES={
    fighter=function(gr,px,py,size) -- filled forward dart
        diamond(gr,px+size*0.5,py+size*0.5,size*0.34,size*0.5)
        gr.drawCircle(size*0.13,px+size*0.72,py+size*0.5,true)
    end,
    bomber=function(gr,px,py,size) -- filled blunt wedge
        gr.drawRectangle(px,py+size*0.14,px+size,py+size*0.5,true)
        gr.drawRectangle(px+size*0.16,py+size*0.5,px+size*0.84,py+size,true)
    end,
    escort=function(gr,px,py,size) -- filled lozenge
        diamond(gr,px+size*0.5,py+size*0.5,size*0.5,size*0.5)
    end,
    capital=function(gr,px,py,size) -- broad slab
        gr.drawRectangle(px,py+size*0.12,px+size,py+size*0.88,true)
    end,
    heavy=function(gr,px,py,size) -- filled chevron
        gr.drawRectangleCentered(px+size*0.5,py+size*0.26,size*0.92,size*0.3,true,math.rad(-45))
        gr.drawRectangleCentered(px+size*0.5,py+size*0.74,size*0.92,size*0.3,true,math.rad(45))
    end,
    juggernaut=function(gr,px,py,size) -- solid block with a filled-in notch
        gr.drawRectangle(px,py,px+size,py+size,true)
    end,
    sentry=function(gr,px,py,size) -- filled turret cross
        gr.drawRectangle(px+size*0.36,py,px+size*0.64,py+size,true)
        gr.drawRectangle(px,py+size*0.36,px+size,py+size*0.64,true)
    end,
    station=function(gr,px,py,size) -- wide base bar
        gr.drawRectangle(px,py+size*0.34,px+size,py+size*0.66,true)
    end,
    support=function(gr,px,py,size) -- filled core, inset so it does not
    -- coincide with the badge outline drawn afterwards
        gr.drawRectangle(px+size*0.18,py+size*0.18,px+size*0.82,py+size*0.82,true)
    end,
}
local ROLE_MARKER_COLORS={
    fighter={90,195,240},bomber={240,140,70},escort={105,215,170},
    capital={200,175,240},heavy={240,200,105},juggernaut={250,115,115},
    sentry={185,200,210},station={125,185,215},support={160,220,225},
}
-- module level: the fallback was a table literal inside the call, and
-- DrawRoleMarker runs for every decorated contact on every frame
local ROLE_MARKER_FALLBACK_COLOR={160,180,190}

function RTS:DrawRoleMarker(ship,x1,y1,x2,y2)
    local size=self.Config.Selection.RoleMarkerSize or 11
    if not size or size<=0 then return end
    local role=self:GetShipRole(ship); local shape=ROLE_MARKER_SHAPES[role]
    if not shape then return end
    local inset=self.Config.Selection.RoleMarkerInset or 9
    -- Sit the mark inside the bracket on the left edge, below the top corner
    -- arm, so it never overlaps the corner itself.
    local px=x1+inset; local py=y1+inset
    if x2-px<size or y2-py<size then return end
    local color=ROLE_MARKER_COLORS[role] or ROLE_MARKER_FALLBACK_COLOR
    -- Faint dark plate first so the mark stays legible over bright ship models
    -- and over a selected unit's second, brighter bracket pass. The role
    -- colour is restored after the plate, or the glyph draws in plate grey.
    gr.setColor(8,14,20,150)
    gr.drawRectangle(px-2,py-2,px+size+2,py+size+2,true)
    gr.setColor(color[1],color[2],color[3],255)
    shape(gr,px,py,size)
    gr.setColor(color[1],color[2],color[3],255)
    gr.drawRectangle(px,py,px+size,py+size,false)
end

function RTS:GetReticleFactionKey(ship)
    if self:IsFriendly(ship) then return "friendly" elseif self:IsThirdFaction(ship) then return "third" end
    return "hostile"
end

-- gr.drawTargetingBrackets projects the live model bounds, so a capital at long
-- camera range collapses to a handful of pixels and the contact reads as
-- unmarked. Derive the box from hull radius and camera distance instead, then
-- clamp it into a band that stays legible at every zoom level.
function RTS:GetReticlePixelSize(ship)
    local sel=self.Config.Selection or {}
    local radius=0
    pcall(function() radius=(ship.Class and ship.Class.Model and ship.Class.Model.Radius) or 0 end)
    if not self:IsFiniteNumber(radius) or radius<=0 then radius=80 end
    local size=(radius/math.max(1,self.CameraDistance or 1000))*gr.getScreenHeight()*2.6
    return clamp(size,sel.ReticleMinPixels or 22,sel.ReticleMaxPixels or 120)
end

function RTS:DrawReticle(ship,sx,sy,size,colour,style)
    local half=size/2
    local arm=math.max(4,math.floor(size*0.32))
    local r,g,b=colour[1],colour[2],colour[3]
    local alpha=(self.Config.Selection or {}).ReticleAlpha or 225
    if style=="selected" then
        gr.setColor(8,14,20,150); gr.drawRectangle(sx-half-2,sy-half-2,sx+half+2,sy+half+2,true)
    end
    gr.setColor(r,g,b,alpha)
    gr.drawLine(sx-half,sy-half,sx-half+arm,sy-half); gr.drawLine(sx-half,sy-half,sx-half,sy-half+arm)
    gr.drawLine(sx+half,sy-half,sx+half-arm,sy-half); gr.drawLine(sx+half,sy-half,sx+half,sy-half+arm)
    gr.drawLine(sx-half,sy+half,sx-half+arm,sy+half); gr.drawLine(sx-half,sy+half,sx-half,sy+half-arm)
    gr.drawLine(sx+half,sy+half,sx+half-arm,sy+half); gr.drawLine(sx+half,sy+half,sx+half,sy+half-arm)
    if style=="selected" then gr.setColor(255,235,90,alpha) gr.drawRectangle(sx-half,sy-half,sx+half,sy+half,false) end
    return half
end

-- Contacts outside the view are pinned to the screen border with a hollow
-- marker so a threat you cannot see is still locatable.
--
-- Two things were wrong with the original. First, it took its direction from
-- the projected screen position, so every contact that happened to share a
-- bearing was drawn at the SAME border pixel: a wall of contacts to the north
-- collapsed into one unreadable glyph. Markers are now de-overlapped by
-- spreading them along the border in proportion to their bearing. Second, it
-- could not be called at all for a contact BEHIND the camera: getScreenCoords
-- returns false on a projection overflow
-- (code/scripting/api/objs/vecmath.cpp, the PF_OVERFLOW branch), and the old
-- caller returned before reaching this function, so a threat astern drew
-- nothing at all. The direction is therefore derived from world space relative
-- to the active camera, which is well defined for every contact.
function RTS:GetEdgeContactDirection(ship)
    -- getScreenCoords returned false, which the engine does on a projection
    -- overflow (code/scripting/api/objs/vecmath.cpp, the PF_OVERFLOW branch) and
    -- that is what a contact behind the camera produces. Build a screen
    -- direction from the camera basis instead, which is well defined for those.
    local camera = self.Camera
    if self.FollowSignature ~= nil and self.FollowCamera ~= nil then camera = self.FollowCamera end
    if camera == nil or camera.Orientation == nil or camera.Position == nil then return nil end
    local okF, forward = pcall(function() return camera.Orientation:getFvec() end)
    if not okF or forward == nil then return nil end
    local okR, right = pcall(function() return camera.Orientation:getRvec() end)
    if not okR or right == nil then return nil end
    local ox = ship.Position.x - camera.Position.x
    local oz = ship.Position.z - camera.Position.z
    if ox == 0 and oz == 0 then return nil end
    local lateral = ox*right.x + oz*right.z
    local along = ox*forward.x + oz*forward.z
    if lateral == 0 and along == 0 then return nil end
    -- Screen y grows downward while the camera's forward vector points away
    -- from the viewer, so the vertical screen component is negated.
    return lateral, -along
end

-- Contacts outside the view are drawn as a marker, and markers that would land
-- on top of each other are pushed apart along the border. Placing them by
-- bearing keeps a group of contacts readable as a group instead of collapsing
-- onto a single pixel.
function RTS:DrawEdgeContactMarker(ship,sx,sy,colour,sw,sh)
    local sel=self.Config.Selection or {}
    local margin=sel.ReticleEdgeClampMargin or 26
    local dx,dy
    if sx~=false and sy~=false then
        -- A contact whose projection landed on screen is not an off-screen
        -- contact and has nothing to be pinned for.
        if sx>=0 and sy>=0 and sx<=sw and sy<=sh then return end
        dx,dy=sx-sw/2,sy-sh/2
        if dx==0 and dy==0 then return end
    else
        dx,dy=self:GetEdgeContactDirection(ship)
    end
    if dx==nil or (dx==0 and dy==0) then return end
    local m=self:GetUIMetrics(sw,sh)
    local ex,ey=self:ResolveEdgeMarkerPoint(dx,dy,sw,sh,margin,m)
    local size=math.max(6,math.floor(6*m.scale))
    gr.setColor(colour[1],colour[2],colour[3],200)
    gr.drawRectangle(ex-size,ey-size,ex+size,ey+size,false)
    gr.drawLine(ex-size,ey-size,ex+size,ey+size); gr.drawLine(ex+size,ey-size,ex-size,ey+size)
    gr.setColor(colour[1],colour[2],colour[3],255)
    self:DrawCenteredText(ROLE_BADGES[self:GetShipRole(ship)] or "?",ex-size*3,ex+size*3,ey-math.floor(size/2))
end

-- Project the direction onto the border rectangle, then slide the point along
-- the border away from any marker already placed this frame.
function RTS:ResolveEdgeMarkerPoint(dx,dy,sw,sh,margin,m)
    local cx,cy=sw/2,sh/2
    local halfW,halfH=sw/2-margin,sh/2-margin
    local scale=math.min(halfW/math.max(1,math.abs(dx)),halfH/math.max(1,math.abs(dy)))
    local ex=cx+dx*scale; local ey=cy+dy*scale
    local placed=self.EdgeMarkerPoints
    if placed==nil then return ex,ey end
    local size=math.max(7,math.floor(7*((m and m.scale) or 1)))
    -- Try progressively larger offsets perpendicular to the border until a free
    -- slot is found. Bounded so a dense contact list cannot spin.
    for attempt=0,8 do
        local offset=attempt*size*1.6
        local px,py=ex,ey
        if math.abs(ex-cx)>=math.abs(ey-cy) then
            -- On a vertical edge: slide vertically.
            py=ey+offset; if attempt>0 then py=ey-offset end
            py=clamp(py,margin,sh-margin)
        else
            px=ex+offset; if attempt>0 then px=ex-offset end
            px=clamp(px,margin,sw-margin)
        end
        local free=true
        for _,other in ipairs(placed) do
            if math.abs(other.x-px)<size*1.8 and math.abs(other.y-py)<size*1.8 then free=false; break end
        end
        if free then self:AddMarkerPoint(placed,px,py); return px,py end
    end
    self:AddMarkerPoint(placed,ex,ey)
    return ex,ey
end

-- Projected outline of a world circle on the command plane. Using two
-- perpendicular basis vectors keeps the ring an ellipse under an oblique
-- camera instead of a circle that is wrong on two axes.
function RTS:DrawWorldRangeRing(centre,range,colour,alpha,centreX,centreY)
    if centre==nil or not self:IsFiniteVector(centre) or not self:IsFiniteNumber(range) or range<=0 then return end
    -- The caller has already projected the ring's centre (it is the hull under
    -- the cursor, and the reticle pass projected it this epoch), so it is
    -- handed in rather than projected a second time. The two offset points are
    -- constructed per call and cannot come from the cache.
    local ox,oy=centreX,centreY
    if ox==nil then ox,oy=centre:getScreenCoords() end
    if ox==false then return end
    local px,py=(centre+vec(range,0,0)):getScreenCoords()
    local pz,pw=(centre+vec(0,0,range)):getScreenCoords()
    if px==false or pz==false then return end
    local sel=self.Config.Selection or {}
    local maxPixels=sel.WeaponRangeMaxPixels or 340
    local ax,ay=px-ox,py-oy; local length=math.sqrt(ax*ax+ay*ay)
    if length>maxPixels then local k=maxPixels/length; ax,ay=ax*k,ay*k end
    local bx,by=pz-ox,pw-oy; length=math.sqrt(bx*bx+by*by)
    if length>maxPixels then local k=maxPixels/length; bx,by=bx*k,by*k end
    local segments=sel.WeaponRangeSegments or 48
    gr.setColor(colour[1],colour[2],colour[3],alpha or sel.WeaponRangeAlpha or 90)
    local previousX,previousY
    for i=0,segments do
        local a=(i/segments)*math.pi*2
        local dx=math.cos(a); local dz=math.sin(a)
        local x=ox+ax*dx+bx*dz; local y=oy+ay*dx+by*dz
        if previousX~=nil then gr.drawLine(previousX,previousY,x,y) end
        previousX,previousY=x,y
    end
end

-- Effective weapon reach for a hull. Projectile range is capped by the weapon's
-- own lifetime. A capital carries everything in turrets, so turrets are scanned
-- too; a beam weapon with no projectile range contributes nothing rather than a
-- false zero.
function RTS:GetShipWeaponRange(ship)
    local best=0
    local function scan(banks)
        for i=1,#banks do
            local bank=banks[i]; local weapon=bank.WeaponClass
            if objectValid(bank) and objectValid(weapon) and not weapon:isBeam() then
                local r=math.min(tonumber(weapon.Range) or 0,(tonumber(weapon.Speed) or 0)*(tonumber(weapon.LifeMax) or 0))
                if self:IsFiniteNumber(r) then best=math.max(best,r) end
            end
        end
    end
    local okP,primariesLocked=pcall(function() return ship:getFlag("primaries-locked") end)
    local okS,secondariesLocked=pcall(function() return ship:getFlag("secondaries-locked") end)
    if not (okP and okS and primariesLocked and secondariesLocked) then
        scan(ship.PrimaryBanks or {}); scan(ship.SecondaryBanks or {})
    end
    for i=1,#ship do
        local turret=ship[i]
        if objectValid(turret) and not turret.TurretLocked and (turret.HitpointsMax<=0 or turret.HitpointsLeft>0) then
            local okT,isTurret=pcall(function() return turret:isTurret() end)
            if okT and isTurret then scan(turret.PrimaryBanks or {}); scan(turret.SecondaryBanks or {}) end
        end
    end
    return best
end

-- Cull for the per-contact decoration (hull bar + role marker). A contact that
-- overlaps one already decorated this frame gains nothing from a second set of
-- glyphs on top of it: both are unreadable, and the pair costs a filled
-- rectangle, a role shape and an outline each. Selection and hover are always
-- decorated so the thing the player is pointing at is never the thing dropped.
--
-- This used to be a list of {x,y} tables compared pairwise, which is a
-- quadratic scan of every contact against every contact already placed, plus a
-- table per placed point, every frame. Cells are minGap wide, so two points in
-- the same cell are always within minGap on BOTH axes: a cell can therefore
-- hold at most one decorated point, and since a decorated point is by
-- definition not within minGap of any earlier one, that holds for the whole
-- decorated set. The cell is a safe key, not a bucket that has to be scanned.
--
-- The bucket lookup is still only the coarse filter - nine cells - and the
-- precise test runs against the one point each of them can hold. That matters:
-- a cell-only test culls anything within 2*minGap rather than minGap, which
-- threw away the decoration of contacts that were plainly far enough apart to
-- read both, which is the opposite of what decluttering is for.
--
-- Two number-keyed tables rather than a table of records, so a frame at full
-- board decorates without allocating anything at all: a store into an existing
-- hash does not allocate.
--
-- The key is cellX * 2^21 + (cellY + 2^20). Unique for |cellY| < 2^20 and the
-- two cellX bands never overlap; a screen is at most a few thousand pixels
-- across and minGap is at least 18, so a cell index cannot reach 2^20.
local DECORATION_KEY_SPAN = 1048576
local DECORATION_KEY_SCALE = 2097152

function RTS:ShouldDecorateReticle(sx,sy,half,forced)
    local sel=self.Config.Selection or {}
    local minGap=math.max(18,(sel.ReticleMinPixels or 22)+math.max(10,(sel.RoleMarkerSize or 11)))
    local X=self.DecoratedX
    if X==nil then X={}; self.DecoratedX=X; self.DecoratedY={} end
    local Y=self.DecoratedY
    local cellX=math.floor(sx/minGap); local cellY=math.floor(sy/minGap)
    if not forced then
        for dx=-1,1 do
            local keyX=(cellX+dx)*DECORATION_KEY_SCALE+DECORATION_KEY_SPAN
            for dy=-1,1 do
                local px=X[keyX+(cellY+dy)]
                if px~=nil then
                    local py=Y[keyX+(cellY+dy)]
                    if math.abs(px-sx)<minGap and math.abs(py-sy)<minGap then return false end
                end
            end
        end
    end
    local key=cellX*DECORATION_KEY_SCALE+(cellY+DECORATION_KEY_SPAN)
    X[key]=sx
    Y[key]=sy
    return true
end

function RTS:ResetDecorationGrid()
    self.DecoratedX=nil
    self.DecoratedY=nil
    self.DecoratedReticles=nil
end

-- The border-marker de-overlap list. Its entries are two-number records, and
-- one is appended per off-screen contact per frame, so they are recycled rather
-- than reallocated: at a full board that was a few hundred small tables every
-- frame, sixty times a second.
local MARKER_POINT_POOL={}
function RTS:RecycleMarkerPoints(list)
    if list==nil then return end
    for i=1,#list do MARKER_POINT_POOL[#MARKER_POINT_POOL+1]=list[i] end
end
function RTS:AddMarkerPoint(list,x,y)
    local top=#MARKER_POINT_POOL
    local point
    if top>0 then point=MARKER_POINT_POOL[top]; MARKER_POINT_POOL[top]=nil
    else point={x=0,y=0} end
    point.x=x; point.y=y
    list[#list+1]=point
end

function RTS:DrawWorldOverlays()
    self.HoverReadout=nil
    local sw,sh=gr.getScreenWidth(),gr.getScreenHeight(); local sel=self.Config.Selection or {}
    local selectedSet={}; for _,sig in ipairs(self.Selected) do selectedSet[sig]=true end
    -- Per-frame culling state. Every ship used to get a bracket, a hull bar and
    -- a role marker drawn for it on every frame regardless of how far off it
    -- was or how close its neighbours were: with a full battle that is several
    -- hundred contacts all paying for decoration, most of it stacked on top of
    -- itself. The reticle is still drawn for every contact (it is the only
    -- thing marking that the ship exists), but the hull bar and role marker are
    -- only added where they can be read.
    self:RecycleMarkerPoints(self.EdgeMarkerPoints)
    self.EdgeMarkerPoints={}
    self:ResetDecorationGrid()

    -- Ambient contacts are projected on a round robin rather than every frame
    -- (see AMBIENT_PROJECT_EPOCHS in input.lua): at a full board this is the
    -- single largest reduction in getScreenCoords calls in the whole mod. The
    -- entry is dropped from the cache once its ship leaves the world so the
    -- fleet cannot grow it without bound.
    if self:ProjectionCacheNeedsPrune() then self:PruneProjectionCache() end
    -- And the off-screen ones are rejected here, in world space, before the
    -- projection. A contact the engine would put outside the viewport is
    -- exactly a contact that only needs a border marker, and the marker is
    -- derived from the camera basis (GetEdgeContactDirection) and needs no
    -- projection at all. Selection and hover bypass the gate: they are drawn
    -- larger, and the thing the player is pointing at must never be the thing
    -- the optimiser drops.
    local gate=self:BuildViewportGate(sw,sh)
    self:EachShip(function(ship)
        if ship.Name==self.Config.ObserverShip then return end
        local sig=ship:getSignature(); local selected=selectedSet[sig]==true; local hovered=self.HoveredSelectionSigs[sig]==true
        local position=ship.Position
        local sx,sy=false,false
        if position~=nil then
            if selected or hovered or gate==nil or self:PassesScreenGate(gate,position) then
                if selected or hovered then sx,sy=self:ProjectShip(ship,0) else sx,sy=self:ProjectShipAmbient(ship) end
            end
        end
        if sx==false or sx<0 or sy<0 or sx>sw or sy>sh then
            -- getScreenCoords returns false on a projection overflow, which is
            -- what a contact BEHIND the camera produces. Those used to be
            -- dropped here, so a threat astern was invisible; the edge marker
            -- derives its own bearing and can still place it.
            self:DrawEdgeContactMarker(ship,sx,sy,RETICLE_COLORS[self:GetReticleFactionKey(ship)],sw,sh)
            return
        end
        local size=self:GetReticlePixelSize(ship)
        if selected then size=math.max(size,(sel.SelectedBracketPadding or 18)*2) end
        if hovered then size=size+8 end
        local colour=selected and RETICLE_COLOR_SELECTED or (hovered and RETICLE_COLOR_HOVERED or RETICLE_COLORS[self:GetReticleFactionKey(ship)])
        local half=self:DrawReticle(ship,sx,sy,size,colour,selected and "selected" or nil)
        if self:ShouldDecorateReticle(sx,sy,half,selected or hovered) then
            self:DrawHullBarForShip(ship,sx-half,sy-half,sx+half,sy+half)
            self:DrawRoleMarker(ship,sx-half,sy-half,sx+half,sy+half)
        end
    end)
    local mx,my=io.getMouseX(),io.getMouseY()
    -- The hover pick is the only picking caller that is not resolving a click,
    -- so it is the only one allowed to accept a projection a frame old. The
    -- reticle pass above has already projected every contact on screen, and
    -- this pick cone reaches 304px past the cursor, so being strict here made
    -- the mod re-project most of the visible fleet a second time every frame
    -- purely to draw an inspection tooltip.
    local hovered=self:GetShipAtScreen(mx,my,true,true,true,1)
    if shipValid(hovered) then
        -- The hover pick already projected this hull, and the reticle pass
        -- above drew its bracket from the same answer, so the readout and the
        -- bracket can no longer disagree about where the ship is.
        local sx,sy=self:ProjectShip(hovered,0)
        if sx~=false then
            if sel.ShowWeaponRange~=false then
                local range=self:GetShipWeaponRange(hovered)
                if range>0 then self:DrawWorldRangeRing(hovered.Position,range,RETICLE_COLORS[self:GetReticleFactionKey(hovered)],sel.WeaponRangeAlpha or 90,sx,sy) end
            end
            local order=self.UserOrders and self.UserOrders[hovered:getSignature()]
            if order~=nil and order.kind=="move" and self:IsFiniteVector(order.destination) then
                local dx,dy=order.destination:getScreenCoords()
                if dx~=false then
                    gr.setColor(120,255,200,220); gr.drawLine(sx,sy,dx,dy)
                    gr.setColor(120,255,200,255); gr.drawCircle(9,dx,dy,false)
                end
                if order.facing~=nil and self:IsFiniteVector(order.facing) then
                    local fx,fy=order.facing:getScreenCoords()
                    if fx~=false then
                        gr.setColor(255,235,120,235); gr.drawLine(dx,dy,fx,fy)
                        local ax,ay=fx-dx,fy-dy; local length=math.sqrt(ax*ax+ay*ay)
                        if length>1 then
                            local ux,uy=ax/length,ay/length; local px,py=-uy,ux
                            gr.drawLine(fx,fy,fx-ux*14+px*7,fy-uy*14+py*7)
                            gr.drawLine(fx,fy,fx-ux*14-px*7,fy-uy*14-py*7)
                        end
                    end
                end
            end
            local target=self:GetHoverOrderTarget(hovered)
            if shipValid(target) and target.Position~=nil then
                -- Cached: this is a hull the player is inspecting, and the
                -- reticle pass has normally already projected it this epoch.
                local tx,ty=self:ProjectShip(target,0)
                if tx~=false then
                    gr.setColor(255,210,75,220); gr.drawLine(sx,sy,tx,ty)
                end
            end

            local course=self:GetHoverCourseProjection(hovered,sx,sy)
            if course~=nil then
                local ex,ey=course.x,course.y
                gr.setColor(75,230,255,245); gr.drawLine(sx,sy,ex,ey)
                local dx,dy=ex-sx,ey-sy; local length=math.sqrt(dx*dx+dy*dy)
                if length>1 then
                    local ux,uy=dx/length,dy/length; local px,py=-uy,ux
                    gr.drawLine(ex,ey,ex-ux*12+px*5,ey-uy*12+py*5)
                    gr.drawLine(ex,ey,ex-ux*12-px*5,ey-uy*12-py*5)
                end
            end
            self.HoverReadout={ship=hovered,mouseX=mx,mouseY=my,target=target,
                courseSeconds=course and course.seconds or nil,order=order}
        end
    end
    local preview=self.MovePreview
    if preview~=nil and self:IsFiniteVector(preview.destination) then
        local dx,dy=preview.destination:getScreenCoords()
        if dx~=false then
            gr.setColor(120,255,200,235); gr.drawCircle(12,dx,dy,false)
            gr.setColor(120,255,200,200); gr.drawLine(dx-18,dy,dx+18,dy); gr.drawLine(dx,dy-18,dx,dy+18)
            if preview.facing~=nil and self:IsFiniteVector(preview.facing) then
                local fx,fy=preview.facing:getScreenCoords()
                if fx~=false then
                    gr.setColor(255,235,120,240); gr.drawLine(dx,dy,fx,fy)
                    local ax,ay=fx-dx,fy-dy; local length=math.sqrt(ax*ax+ay*ay)
                    if length>1 then
                        local ux,uy=ax/length,ay/length; local px,py=-uy,ux
                        gr.drawLine(fx,fy,fx-ux*16+px*8,fy-uy*16+py*8)
                        gr.drawLine(fx,fy,fx-ux*16-px*8,fy-uy*16-py*8)
                    end
                    gr.setColor(255,235,120,255); gr.drawString("FACE",fx+10,fy-8,fx+70,fy+10)
                end
            end
        end
    end
    if self.CommandMarker and self:UINow()<=self.CommandMarkerUntil then local x,y=self.CommandMarker:getScreenCoords(); if x~=false then gr.setColor(100,255,180,220); gr.drawCircle(18,x,y,false); gr.drawLine(x-24,y,x+24,y); gr.drawLine(x,y-24,x,y+24) end end
end


-- Tactical options strip: formation shape for the next group move, and the
-- music mute. Both are global settings the player flips mid-battle, so they sit
-- on their own row instead of being buried in a panel.
function RTS:DrawOptionsPanel(sw,sh)
    local r=self:GetOptionsPanelRect(sw,sh); local x1,y1,x2,y2=r.x1,r.y1,r.x2,r.y2
    local m=self:GetUIMetrics(sw,sh); local lh=m.lineHeight
    gr.setColor(4,10,18,220); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    local types=self:GetFormationTypes()
    local current=self:GetSelectedFormation()
    local label="FORMATION"; local desc=""; local index=0
    for i,entry in ipairs(types or {}) do if entry.id==current then index=i; label=string.upper(entry.label); desc=entry.desc break end end
    if #types>1 then label=label.."  "..index.."/"..#types end
    local musicW=math.max(80,m.pad(88))
    -- The formation description used to be drawn at y2+2, i.e. OUTSIDE the
    -- panel, in a 12px gap it was 16px tall, so it always overlapped the top of
    -- the policy panel. It now sits inside the panel on its own line.
    local descH=lh
    local top=y1+m.pad(6); local bottom=y2-m.pad(6)
    self.FormationButtonRect={x1=x1+m.pad(8),y1=top,x2=x2-musicW-m.pad(4),y2=bottom-descH-m.pad(2)}
    self:DrawButton(self.FormationButtonRect,label,true,false)
    gr.setColor(150,180,195,255)
    self:DrawCenteredTextClipped(desc or "",x1+m.pad(16),x2-musicW-m.pad(8),bottom-descH)
    self.MusicButtonRect={x1=x2-musicW-m.pad(8),y1=top,x2=x2-m.pad(8),y2=bottom}
    local muted=self.MusicMuted==true
    self:DrawButton(self.MusicButtonRect,muted and "MUSIC: OFF" or "MUSIC: ON",true,muted)
end

function RTS:DrawChaseBanner(sw)
    if self.FollowSignature==nil then return end
    local ship=self:FindShipBySignature(self.FollowSignature); local name=shipValid(ship) and ship.Name or "TARGET"
    local m=self:GetUIMetrics(sw); local lh=m.lineHeight
    local w=math.min(m.pad(720),sw-2*m.margin); local x1=(sw-w)/2; local x2=x1+w
    local y1=m.topBarHeight+m.pad(24); local y2=y1+2*lh+m.pad(14)
    gr.setColor(2,7,12,225); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(255,220,70,255); gr.drawRectangle(x1,y1,x2,y2,false)
    local c=self.Config.HomeworldControls or {}
    self:DrawCenteredTextClipped("CHASE MODE // "..name,x1+m.pad(10),x2-m.pad(10),y1+m.pad(6))
    gr.setColor(190,210,220,255)
    self:DrawCenteredTextClipped("RMB drag orbit | Wheel zoom | "..(c.Chase or "B").." or Alt+double-click releases",x1+m.pad(12),x2-m.pad(12),y1+m.pad(6)+lh)
end

-- After-action report. The battle froze with a bare VICTORY/DEFEAT card, which
-- told the player nothing about how the fight actually went.
function RTS:DrawPostBattleOverlay(sw,sh)
    if not self.PostBattleActive then return end
    gr.setColor(0,0,0,170); gr.drawRectangle(0,44,sw,sh,true)
    local summary=self.BattleSummary or {}
    -- DRAW is a real outcome, reached when the time box expires with the blue
    -- fleet out-scored on attrition. Treating every non-VICTORY status as
    -- DEFEAT would have reported a drawn match to the player as a loss.
    local victory=self.GameStatus=="VICTORY"
    local draw=self.GameStatus=="DRAW"
    local w=math.min(860,sw-60); local h=math.min(500,sh-70); local x1=(sw-w)/2; local x2=x1+w; local y1=(sh-h)/2; local y2=y1+h
    gr.setColor(3,9,15,248); gr.drawRectangle(x1,y1,x2,y2,true)
    gr.setColor(draw and 190 or (victory and 100 or 255),draw and 175 or (victory and 235 or 95),draw and 70 or (victory and 170 or 95),255)
    gr.drawRectangle(x1,y1,x2,y1+52,true)
    gr.setColor(draw and 225 or (victory and 140 or 255),draw and 210 or (victory and 250 or 140),draw and 130 or (victory and 210 or 150),255)
    self:DrawCenteredText(draw and "DRAW" or (victory and "VICTORY" or "DEFEAT"),x1+20,x2-20,y1+14)
    gr.setColor(20,34,42,255)
    gr.drawRectangle(x1+1,y1+1,x2-1,y1+51,false)
    gr.setColor(225,235,240,255)
    self:DrawCenteredWrappedText(self.PostBattleResult or "BATTLE COMPLETE",x1+24,x2-24,y1+62,96,18,2)

    local columnGap=16
    local leftX=x1+22; local leftX2=math.floor((x1+x2)/2)-columnGap/2
    local rightX=math.floor((x1+x2)/2)+columnGap/2; local rightX2=x2-22
    local y=y1+108

    gr.setColor(105,235,255,255)
    self:DrawCenteredText("BLUE FLEET",leftX,leftX2,y); self:DrawCenteredText("BATTLE",rightX,rightX2,y)
    y=y+22
    local function row(leftText,rightText,cr,cg,cb)
        local colour=cr and {cr,cg or cr,cb or cr} or {205,225,232}
        gr.setColor(colour[1],colour[2],colour[3],255); self:DrawTextLine(leftText,leftX,y,leftX2-leftX)
        gr.setColor(185,205,215,255); self:DrawTextLine(rightText,rightX,y,rightX2-rightX)
        y=y+17
    end
    row("Battle length",self:FormatTime(summary.durationSeconds or 0),255,220,110)
    row("Escalation tier reached",tostring(summary.tier or 1))
    row("Ships lost",tostring(summary.losses or 0),255,150,140)
    row("Enemy kills",tostring(summary.kills or 0),150,235,180)
    row("Command points spent",tostring(math.floor(summary.cpSpent or 0)))
    row("Command points remaining",tostring(math.floor(summary.cpRemaining or self.CommandPoints or 0)))
    row("Fleet cap reached",tostring(summary.fleetCap or 0))
    row("Capital losses",tostring(summary.capitalLosses or 0),255,150,140)

    y=y+10
    gr.setColor(105,235,255,255); self:DrawCenteredText("FACTIONS",leftX,leftX2,y); self:DrawCenteredText("OUTCOME",rightX,rightX2,y)
    y=y+22
    for _,entry in ipairs(summary.factions or {}) do
        if entry.eliminated then row(entry.label,"ELIMINATED",170,180,190)
        else row(entry.label,"SURVIVING // "..tostring(entry.ships or 0).." ships",120,235,170) end
    end
    if #(summary.factions or {})==0 then row("No faction data","",170,180,190) end

    local gap=18; local bw=(w-70-gap)/2; local by=y2-74
    local rr={x1=x1+26,y1=by,x2=x1+26+bw,y2=by+46}; local er={x1=rr.x2+gap,y1=by,x2=x2-26,y2=by+46}
    self.PostBattleButtonRects={restart=rr,exit=er}; self:DrawButton(rr,"RESTART MISSION",true,true); self:DrawButton(er,"EXIT TO MAIN MENU",true,false)
end

-- Control legend. It used to bail out entirely when the band between the
-- selection panel and the options panel was under 160px wide, which is what
-- happened below about 1056px of screen width, and each of its four lines was
-- ~150 characters drawn into a ~400px box: the engine re-wrapped every line
-- into four overlapping rows. The band is now sized by the layout solve (so it
-- exists at every resolution) and the entries are wrapped to its measured
-- width, with as many lines as fit. The drawn band is published so the status
-- message can move out of its way.
-- The control legend's four lines. These are four long concatenations over the
-- key bindings, and the band is redrawn on every frame of every match, so the
-- table and roughly eight hundred characters of string garbage were produced
-- sixty times a second to say the same four things. Built once per distinct
-- set of bindings.
function RTS:GetControlLegendLines()
    local c=self.Config.HomeworldControls or {}
    local cached=self.ControlLegendLines
    if cached~=nil and self.ControlLegendKeys==c.SelectAll and self.ControlLegendStop==c.Stop
        and self.ControlLegendEngage==c.Engage and self.ControlLegendRelease==c.Release
        and self.ControlLegendMove==c.ArmMove and self.ControlLegendAttack==c.ArmAttack
        and self.ControlLegendFocus==c.Focus and self.ControlLegendWing1==c.Wing1
        and self.ControlLegendWing4==c.Wing4 and self.ControlLegendZoomFar==c.ZoomFar
        and self.ControlLegendZoomNear==c.ZoomNear and self.ControlLegendMute==c.MuteMusic
        and self.ControlLegendPolicyJ==c.HoldPolicy and self.ControlLegendPolicyZ==c.PassivePolicy
        and self.ControlLegendPolicyX==c.DefensivePolicy and self.ControlLegendPolicyV==c.AggressivePolicy
        then
        return cached
    end
    cached={
        "LMB select / drag  |  Shift add  |  Ctrl+LMB class  |  Double-click wing  |  "..(c.SelectAll or "L").." select all  |  "..(c.Chase or "B").." chase",
        "RMB order  |  RMB DRAG from empty space = move + facing  |  "..(c.ArmMove or "M").." move, "..(c.ArmAttack or "K").." attack  |  "..(c.Stop or "R").." hold  |  "..(c.Engage or "T").." engage  |  "..(c.Release or "G").." release",
        -- The digit keys are an absolute ladder (input.lua speedKeys), not the
        -- old relative slower/pause/faster/reset, so the legend states the speed
        -- each key selects. The keys are literals rather than the
        -- HomeworldControls names: those still carry the old relative meaning.
        "1/2/3/4/0 = 1x/2x/4x/8x/16x game speed  |  = / - step  |  Esc pause  |  "..(c.Wing1 or "F1").."-"..(c.Wing4 or "F4").." wing recall  |  Ctrl+"..(c.Wing1 or "F1").."-"..(c.Wing4 or "F4").." assign  |  "..(c.HoldPolicy or "J").."/"..(c.PassivePolicy or "Z").."/"..(c.DefensivePolicy or "X").."/"..(c.AggressivePolicy or "V").." policy",
        "WASD pan  |  MMB pan  |  RMB drag orbit  |  Wheel zoom  |  "..(c.ZoomFar or "Q").."/"..(c.ZoomNear or "E").." zoom  |  "..(c.Focus or "F").." focus  |  "..(c.FocusBase or "H").." home  |  "..(c.MuteMusic or "N").." music  |  "..(c.Cinematic or "C").." cinematic",
    }
    self.ControlLegendLines=cached
    self.ControlLegendKeys=c.SelectAll; self.ControlLegendStop=c.Stop
    self.ControlLegendEngage=c.Engage; self.ControlLegendRelease=c.Release
    self.ControlLegendMove=c.ArmMove; self.ControlLegendAttack=c.ArmAttack
    self.ControlLegendFocus=c.Focus; self.ControlLegendWing1=c.Wing1
    self.ControlLegendWing4=c.Wing4; self.ControlLegendZoomFar=c.ZoomFar
    self.ControlLegendZoomNear=c.ZoomNear; self.ControlLegendMute=c.MuteMusic
    self.ControlLegendPolicyJ=c.HoldPolicy; self.ControlLegendPolicyZ=c.PassivePolicy
    self.ControlLegendPolicyX=c.DefensivePolicy; self.ControlLegendPolicyV=c.AggressivePolicy
    return cached
end

function RTS:DrawControls(sw,sh)
    local m=self:GetUIMetrics(sw,sh); local lh=m.lineHeight
    local lines=self:GetControlLegendLines()
    self.ControlsRect=nil
    local selection=self:GetSelectionPanelRect(sw,sh); local options=self:GetOptionsPanelRect(sw,sh)
    local x1=selection.x2+m.gap; local x2=options.x1-m.gap
    local y2=m.sh-m.margin
    local availableW=x2-x1-m.pad(16)
    if availableW<200 then return end
    -- The band shares its column with the selection panel, so its height is
    -- bounded by that panel rather than by the screen.
    local maxH=math.max(3*lh,selection.y2-selection.y1)
    local maxLines=math.max(1,math.floor((maxH-2*m.pad(6))/lh))
    local drawn={}
    for _,line in ipairs(lines) do
        if #drawn>=maxLines then break end
        for _,piece in ipairs(self:WrapTextLinesToWidth(line,availableW,maxLines-#drawn+1)) do
            if #drawn>=maxLines then break end
            drawn[#drawn+1]=piece
        end
    end
    if #drawn==0 then return end
    local y1=y2-#drawn*lh-2*m.pad(6)
    gr.setColor(4,10,18,210); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(155,200,215,255)
    for i,line in ipairs(drawn) do self:DrawCenteredText(line,x1+m.pad(8),x2-m.pad(8),y1+m.pad(6)+(i-1)*lh) end
    self.ControlsRect={x1=x1,y1=y1,x2=x2,y2=y2}
end

function RTS:DrawPilotHUD(sw, sh)
    local ship = self:GetPossessedShip()
    if not shipValid(ship) and not self.PendingPilotEject then return end

    -- Native FreeSpace HUD is visible underneath. Keep only a small possession
    -- marker so the player knows how to eject back into tactical command.
    local pilot=self.Config.Pilot or {}
    local m=self:GetUIMetrics(sw,sh); local lh=m.lineHeight
    local panelW=m.pad(330)
    local x1, y1 = sw - m.margin - panelW, m.pad(18)
    local x2 = sw - m.margin
    local groups=self.PilotTurretGroups
    local hasGroups=groups~=nil and #groups>0
    local group=hasGroups and groups[self.PilotTurretGroupIndex or 0] or nil
    local allLive=hasGroups and self.PilotTurretGroupIndex==nil
    local subsystem=self:GetPilotTargetSubsystemLabel()
    -- The background has to cover every row this function actually draws. Rows
    -- below the title are: the base row, the group-hint row when groups exist,
    -- the TARGET row (drawn only in the group branch) and the firing row. The
    -- old count started at 26 + lines*18, three pixels short of the last row's
    -- bottom edge, and counted a TARGET row in the no-group branch that never
    -- draws one. First row starts at y1+29, so the panel ends at y1+29+lines*18.
    local lines=1
    if hasGroups then lines=lines+1 end
    if hasGroups and subsystem~="" then lines=lines+1 end
    if self.PilotTurretFiring then lines=lines+1 end
    local firstRowY=y1+lh+6
    -- The background has to cover every row this function actually draws. Rows
    -- below the title are: the base row, the group-hint row when groups exist,
    -- the TARGET row (drawn only in the group branch) and the firing row. The
    -- old count started at 26 + lines*18, three pixels short of the last row's
    -- bottom edge, and counted a TARGET row in the no-group branch that never
    -- draws one.
    --
    -- These rows keep the FIVE-argument gr.drawString form on purpose. The
    -- background-coverage regression check measures the panel bottom against
    -- the y2 each row is drawn with, and the three-argument form reports no y2
    -- at all; the box and its rows are both derived from the same measured
    -- metrics now, which is the property the check is actually about.
    local y2 = firstRowY + lines*lh + m.pad(4)
    local rowH=math.max(18,m.pad(18))
    gr.setColor(4, 10, 18, 200)
    gr.drawRectangle(x1, y1, x2, y2, true)
    if self.PendingPilotEject then
        local remaining=math.max(0,self.PendingPilotEjectRemaining or 0)
        gr.setColor(255,135,95,255); gr.drawString("CRAFT DESTROYED",x1+10,y1+m.pad(8),x2-8,y1+m.pad(8)+rowH)
        gr.setColor(255,220,100,255); gr.drawString(string.format("RETURNING TO RTS IN %.1fs",remaining),x1+10,firstRowY,x2-8,firstRowY+rowH)
        return
    end
    gr.setColor(105,235,255,255)
    gr.drawString("POSSESSED: " .. ship.Name, x1 + 10, y1 + m.pad(8), x2 - 8, y1 + m.pad(8) + rowH)
    local y=firstRowY
    if hasGroups then
        if allLive then
            gr.setColor(150,245,180,255)
            gr.drawString("WEAPONS: ALL TURRET GROUPS LIVE",x1+10,y,x2-8,y+rowH)
        else
            gr.setColor(225,235,240,255)
            gr.drawString("WEAPONS: "..group.label.." ("..self.PilotTurretGroupIndex.."/"..#groups..")",x1+10,y,x2-8,y+rowH)
        end
        y=y+lh
        gr.setColor(190,210,220,255)
        gr.drawString(pilot.TurretGroupPreviousKey.."/"..pilot.TurretGroupNextKey.." group  |  "..tostring(pilot.TurretGroupToggleKey).." all  |  "..pilot.ToggleKey.." exit",x1+10,y,x2-8,y+rowH)
        y=y+lh
        if subsystem~="" then
            gr.setColor(150,215,235,255)
            gr.drawString("TARGET: "..subsystem,x1+10,y,x2-8,y+rowH); y=y+lh
        end
    else
        gr.setColor(255, 220, 100, 255)
        gr.drawString("[" .. pilot.ToggleKey .. "] RETURN TO RTS", x1 + 10, y, x2 - 8, y + rowH)
        y=y+lh
    end
    if self.PilotTurretFiring then
        gr.setColor(255,120,100,255)
        gr.drawString(pilot.TurretFireStatusLine or "MANUAL TURRET FIRE ACTIVE",x1+10,y,x2-8,y+rowH)
    end
end


function RTS:DrawSetupOverlay(sw,sh)
    local w=math.min(800,sw-40); local h=math.min(650,sh-56); local x1=(sw-w)/2; local y1=math.max(48,(sh-h)/2); local x2=x1+w; local y2=y1+h
    gr.setColor(2,7,12,242); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,210,240,255); gr.drawRectangle(x1,y1,x2,y2,false); gr.setColor(110,235,255,255); self:DrawCenteredText("ESCALATION BATTLE CONFIGURATION",x1+20,x2-20,y1+16)
    gr.setColor(190,210,220,255); self:DrawCenteredWrappedText("Blue is fixed. Choose opponents, map spacing, pacing and economy.",x1+24,x2-24,y1+48,84,18,2)
    local diff=self.Config.Setup.Difficulties[self.SetupDifficultyIndex]; local eco=self.Config.Setup.Economies[self.SetupEconomyIndex]; local dur=self:GetDurationProfile(); local dist=self:GetBaseDistanceProfile(); self.SetupButtonRects={}; local y=y1+94
    local function row(id,label,value,desc)
        gr.setColor(255,220,110,255); gr.drawString(label,x1+30,y+5,x1+190,y+25); local r={x1=x1+200,y1=y-3,x2=x2-28,y2=y+31}; self.SetupButtonRects[id]=r; self:DrawButton(r,value,true,false)
        gr.setColor(145,175,190,255); self:DrawWrappedText(desc,x1+204,y+35,66,17,2,x2-30,y+68); y=y+70
    end
    row("difficulty","DIFFICULTY",diff.name.." (click)","AI income, production cadence, and aggression.")
    gr.setColor(255,220,110,255); gr.drawString("OPPONENTS",x1+30,y+5,x1+190,y+25)
    -- The two opponent toggles split the value column between them, edge to
    -- edge. They used to be laid out at two independent literal offsets
    -- (x1+200..x1+445 and x1+455..x2-28), which left a ten-pixel strip between
    -- them that belonged to no button at all: clicking between the RED and
    -- GOLD toggles did nothing, so the opponent that was not the one you
    -- happened to land on silently stayed off and START ESCALATION came up
    -- one faction short of what the setup screen said. Splitting one measured
    -- span also keeps the pair contiguous at any window width.
    local oppX1=x1+200; local oppX2=x2-28; local oppHalf=math.floor((oppX2-oppX1)/2)
    local rw={x1=oppX1,y1=y-3,x2=oppX1+oppHalf,y2=y+31}
    local gw={x1=oppX1+oppHalf,y1=y-3,x2=oppX2,y2=y+31}
    self.SetupButtonRects.red=rw; self.SetupButtonRects.gold=gw
    self:DrawButton(rw,(self.SetupOpponents.RED and "[X] " or "[ ] ").."SHIVAN / RED",true,self.SetupOpponents.RED)
    self:DrawButton(gw,(self.SetupOpponents.GOLD and "[X] " or "[ ] ").."VASUDAN / GOLD",true,self.SetupOpponents.GOLD)
    gr.setColor(145,175,190,255); gr.drawString("Enable either opponent or both.",x1+204,y+36,x2-30,y+56); y=y+64
    row("distance","BASE DISTANCE",dist.name.." // "..tostring(math.floor((dist.distance or 18000)/1000)).." km","Nominal separation between active faction command stations.")
    row("economy","ECONOMY",eco.name.." (click)","Starting CP and base passive income.")
    row("duration","TARGET LENGTH",dur.name.." (click)","Controls tier unlocks, durability, income, and build cadence.")
    local start={x1=x1+130,y1=y2-60,x2=x2-130,y2=y2-18}; self.SetupButtonRects.start=start; self:DrawButton(start,"START ESCALATION",self.SetupFactionCount>=2,true)
end

function RTS:DrawHUD()
    if not self.Enabled then return end; local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
    local m=self:GetUIMetrics(sw,sh)
    -- New projection epoch. See BeginFrameProjection in input.lua: nothing can
    -- move a ship or the camera between this point and the end of the draw, so
    -- every projection taken below is as current as every other one, and
    -- nothing from a previous frame can be read as if it were.
    self:BeginFrameProjection()
    -- Every interactive rect table is rebuilt below, but several draw paths
    -- return early (cinematic, battle cam, free cam, post-battle, pilot mode).
    -- Clearing first means a frame that skipped the owning panel cannot leave
    -- clickable ghosts behind for HandleUILeftClick to act on.
    self.BuildButtonRects={}; self.BuildNavRects={}; self.ActionButtonRects={}
    self.PolicyButtonRects={}; self.QuickGroupRects={}; self.PanelTabRects={}
    self.StationButtonRects={}
    self.SelectionRows={}; self.SelectionRowsShown=0; self.HoveredSelectionRow=nil
    self.TimeButtonRects={}; self.SetupButtonRects={}
    self.PostBattleButtonRects={}; self.MapButtonRects={}; self.AutoModeRect=nil
    self.FormationButtonRect=nil; self.MusicButtonRect=nil
    self.ControlsRect=nil
    self:RecycleMarkerPoints(self.EdgeMarkerPoints); self.EdgeMarkerPoints=nil
    self:ResetDecorationGrid()
    if self.CinematicActive then self:DrawCinematicOverlay(sw,sh); return end
    if self.BattleCamActive then self:DrawBattleCamOverlay(sw,sh); return end
    if self.FreeCamActive then
        if self:UINow()<(self.FreeCamHintUntil or 0) then gr.setColor(150,175,185,220); self:DrawCenteredTextClipped("UI HIDDEN  //  WASD / MOUSE TO FRAME SHOTS  //  SHIFT+"..tostring((self.Config.HomeworldControls or {}).Cinematic or "C").." TO RETURN",m.margin,sw-m.margin,m.pad(20)) end
        return
    end
    if self.PostBattleActive then self:DrawWorldOverlays(); self:DrawTopBar(sw); self:DrawTacticalMap(sw); self:DrawPostBattleOverlay(sw,sh); self:DrawCurrentHoverReadout(); return end
    if self.PossessedSignature~=nil then self:DrawPilotHUD(sw,sh); return end
    if not self.SetupActive then self:RefreshSelectionListRects(sw,sh) end
    -- The tactical map is drawn with the world layer, BEFORE the panels and the
    -- transient text. It used to be redrawn after DrawAnnouncement when popped
    -- out, so a popped map (which is 75% opaque by default) covered the status
    -- message and the escalation announcement it was sitting on top of.
    self:DrawWorldOverlays()
    if not self.SetupActive then self:DrawStrikeWarnings() end
    self:DrawTopBar(sw)
    self:DrawTacticalMap(sw)
    if self.SetupActive then self:DrawSetupOverlay(sw,sh); self:DrawCurrentHoverReadout(); return end
    self:DrawSelectedUnitStats(sw,sh); self:DrawSelectionPanel(sw,sh); self:DrawBuildPanel(sw,sh)
    if self.PanelTab~="station" then self:DrawQuickGroupsPanel(sw,sh); self:DrawOptionsPanel(sw,sh); self:DrawPolicyPanel(sw,sh) end
    self:DrawControls(sw,sh); self:DrawChaseBanner(sw)
    if self.LeftDrag then local left=math.min(self.LeftDrag.x1,self.LeftDrag.x2); local right=math.max(self.LeftDrag.x1,self.LeftDrag.x2); local top=math.min(self.LeftDrag.y1,self.LeftDrag.y2); local bottom=math.max(self.LeftDrag.y1,self.LeftDrag.y2); gr.setColor(90,220,255,220); gr.drawRectangle(left,top,right,bottom,false) end
    if self.StatusMessage and self:UINow()<=self.StatusUntil then
        local width=math.min(m.pad(760),sw-2*m.margin); local xx=(sw-width)/2
        -- Kept clear of the control legend, whose height depends on how the
        -- entries wrapped at this width; it used to sit at a fixed sh-140 and
        -- the legend was drawn straight through it.
        local yy=sh-m.pad(140)
        local legend=self.ControlsRect
        if legend~=nil and legend.x1<xx+width and legend.x2>xx and legend.y1<yy+m.lineHeight+m.pad(30) then
            yy=math.min(yy,legend.y1-m.lineHeight-m.pad(30))
        end
        gr.setColor(4,10,18,220); gr.drawRectangle(xx,yy,xx+width,yy+m.lineHeight+m.pad(16),true)
        gr.setColor(255,220,100,255)
        self:DrawCenteredTextClipped(self.StatusMessage,xx+m.pad(12),xx+width-m.pad(12),yy+math.floor(m.pad(8)))
    end
    self:DrawAnnouncement(sw,sh)
    self:DrawCurrentHoverReadout()
end
