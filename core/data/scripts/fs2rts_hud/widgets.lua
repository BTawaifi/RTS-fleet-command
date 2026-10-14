-- HUD widgets: button drawing, range-ring cache, top-bar counter sampling.
local _shared = require "fs2rts_hud.common"
local U, RTS = _shared.U, _shared.RTS

local Config = require "fs2rts_config"

local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys

-- Normalized vector paths keep action icons crisp without mission-owned bitmap handles.
local ACTION_ICONS={
    MOVE={{.1,.5,.9,.5},{.6,.2,.9,.5},{.9,.5,.6,.8}},
    ATTACK={{.15,.15,.85,.85},{.85,.15,.15,.85},{.1,.1,.4,.1},{.1,.1,.1,.4}},
    GUARD={{.2,.1,.8,.1},{.8,.1,.8,.55},{.8,.55,.5,.9},{.5,.9,.2,.55},{.2,.55,.2,.1}},
    PILOT={{.1,.7,.5,.1},{.5,.1,.9,.7},{.9,.7,.5,.55},{.5,.55,.1,.7}},
    SERVICE={{.5,.1,.5,.9},{.1,.5,.9,.5}},
    FOCUS={{.1,.3,.1,.1},{.1,.1,.3,.1},{.7,.1,.9,.1},{.9,.1,.9,.3},{.9,.7,.9,.9},{.9,.9,.7,.9},{.3,.9,.1,.9},{.1,.9,.1,.7}},
    STOP={{.2,.2,.8,.2},{.8,.2,.8,.8},{.8,.8,.2,.8},{.2,.8,.2,.2}},
    RESUME={{.25,.1,.8,.5},{.8,.5,.25,.9},{.25,.9,.25,.1}},
    EXIT={{.2,.1,.2,.9},{.2,.1,.6,.1},{.2,.9,.6,.9},{.4,.5,.9,.5},{.7,.3,.9,.5},{.9,.5,.7,.7}},
    WITHDRAW={{.9,.5,.1,.5},{.4,.2,.1,.5},{.1,.5,.4,.8}},
    RESTART={{.8,.3,.5,.1},{.5,.1,.15,.3},{.15,.3,.15,.7},{.15,.7,.5,.9},{.5,.9,.8,.7},{.8,.7,.8,.5},{.8,.3,.55,.3},{.8,.3,.8,.05}},
    PRODUCTION={{.1,.85,.1,.4},{.1,.4,.4,.6},{.4,.6,.4,.4},{.4,.4,.7,.6},{.7,.6,.7,.2},{.7,.2,.9,.2},{.9,.2,.9,.85},{.9,.85,.1,.85}},
    SCENE={{.1,.1,.9,.1},{.9,.1,.9,.9},{.9,.9,.1,.9},{.1,.9,.1,.1},{.15,.8,.4,.4},{.4,.4,.65,.8},{.55,.65,.7,.4},{.7,.4,.85,.8}},
    MUSIC={{.25,.7,.25,.2},{.25,.2,.8,.1},{.8,.1,.8,.65},{.25,.4,.8,.3},{.1,.7,.35,.7},{.65,.65,.9,.65}},
    REPORT={{.2,.1,.8,.1},{.8,.1,.8,.9},{.8,.9,.2,.9},{.2,.9,.2,.1},{.35,.3,.65,.3},{.35,.5,.65,.5},{.35,.7,.6,.7}},
    PAUSE={{.3,.1,.3,.9},{.7,.1,.7,.9}},
    NEXT={{.25,.1,.75,.5},{.75,.5,.25,.9}},
    PREV={{.75,.1,.25,.5},{.25,.5,.75,.9}},
    FILTER={{.1,.1,.9,.1},{.9,.1,.6,.5},{.6,.5,.6,.9},{.6,.9,.4,.8},{.4,.8,.4,.5},{.4,.5,.1,.1}},
    SELECT={{.1,.1,.4,.1},{.4,.1,.4,.4},{.4,.4,.1,.4},{.1,.4,.1,.1},{.6,.6,.9,.6},{.9,.6,.9,.9},{.9,.9,.6,.9},{.6,.9,.6,.6}},
    AUTO={{.5,.1,.9,.3},{.9,.3,.9,.7},{.9,.7,.5,.9},{.5,.9,.1,.7},{.1,.7,.1,.3},{.1,.3,.5,.1},{.3,.35,.7,.35},{.3,.65,.7,.65}},
    FORMATION={{.5,.1,.2,.8},{.2,.8,.8,.8},{.8,.8,.5,.1},{.2,.45,.8,.45}},
    RANDOM={{.1,.1,.9,.1},{.9,.1,.9,.9},{.9,.9,.1,.9},{.1,.9,.1,.1},{.25,.25,.35,.35},{.45,.45,.55,.55},{.65,.65,.75,.75}},
    COLOR={{.5,.05,.15,.55},{.15,.55,.2,.8},{.2,.8,.5,.95},{.5,.95,.8,.8},{.8,.8,.85,.55},{.85,.55,.5,.05}},
    ECONOMY={{.1,.25,.8,.25},{.1,.25,.1,.8},{.1,.8,.8,.8},{.8,.8,.8,.25},{.3,.1,.95,.1},{.95,.1,.95,.65}},
    COMMAND={{.15,.7,.85,.7},{.15,.7,.15,.95},{.85,.7,.85,.95},{.5,.7,.5,.1},{.5,.1,.9,.25},{.9,.25,.5,.4}},
    LOGISTICS={{.1,.35,.6,.35},{.6,.35,.6,.75},{.6,.75,.1,.75},{.1,.75,.1,.35},{.6,.5,.8,.5},{.8,.5,.95,.7},{.95,.7,.95,.8},{.2,.75,.2,.95},{.8,.8,.8,.95}},
    DURATION={{.2,.1,.8,.1},{.2,.1,.8,.9},{.8,.1,.2,.9},{.2,.9,.8,.9}},
    INTERCEPT={{.15,.1,.85,.9},{.85,.1,.15,.9},{.5,.05,.5,.25},{.5,.75,.5,.95}},
    CLOSE={{.15,.15,.85,.85},{.85,.15,.15,.85}},
    FIT={{.1,.2,.3,.2},{.1,.2,.1,.4},{.9,.2,.7,.2},{.9,.2,.9,.4},{.1,.8,.3,.8},{.1,.8,.1,.6},{.9,.8,.7,.8},{.9,.8,.9,.6}},
    STRIKE={{.6,.05,.3,.5},{.3,.5,.55,.5},{.55,.5,.4,.95},{.4,.95,.85,.4},{.85,.4,.6,.4},{.6,.4,.6,.05}},
}
ACTION_ICONS.CONTINUE=ACTION_ICONS.RESUME; ACTION_ICONS.START=ACTION_ICONS.RESUME
ACTION_ICONS.QUIT=ACTION_ICONS.EXIT; ACTION_ICONS.END=ACTION_ICONS.EXIT
ACTION_ICONS.HOLD=ACTION_ICONS.STOP; ACTION_ICONS.RETREAT=ACTION_ICONS.WITHDRAW
ACTION_ICONS.ARMOR=ACTION_ICONS.GUARD
ACTION_ICONS.DEFENSES={{.1,.85,.9,.85},{.3,.85,.3,.55},{.3,.55,.7,.55},{.7,.55,.7,.85},{.5,.55,.5,.3},{.5,.3,.9,.15}}
ACTION_ICONS.STATION=ACTION_ICONS.DEFENSES
ACTION_ICONS.BATTLE=ACTION_ICONS.REPORT; ACTION_ICONS.SUMMARY=ACTION_ICONS.REPORT; ACTION_ICONS.SHIPS=ACTION_ICONS.PILOT
ACTION_ICONS.WINGS=ACTION_ICONS.FORMATION; ACTION_ICONS.FACTIONS=ACTION_ICONS.GUARD
ACTION_ICONS.BUILD=ACTION_ICONS.PRODUCTION; ACTION_ICONS.BASE=ACTION_ICONS.GUARD; ACTION_ICONS.CREWS=ACTION_ICONS.REPORT
ACTION_ICONS['+']=ACTION_ICONS.SERVICE; ACTION_ICONS['-']={{.1,.5,.9,.5}}
ACTION_ICONS['<']=ACTION_ICONS.PREV; ACTION_ICONS['>']=ACTION_ICONS.NEXT
ACTION_ICONS.AI=ACTION_ICONS.AUTO; ACTION_ICONS.ENGAGE=ACTION_ICONS.ATTACK; ACTION_ICONS.STANDOFF=ACTION_ICONS.GUARD
ACTION_ICONS.SELL=ACTION_ICONS.ECONOMY; ACTION_ICONS.CANCEL=ACTION_ICONS.CLOSE
ACTION_ICONS.RANDOMIZE=ACTION_ICONS.RANDOM; ACTION_ICONS.DIFFICULTY=ACTION_ICONS.STRIKE; ACTION_ICONS.ESCALATION=ACTION_ICONS.DURATION
ACTION_ICONS.DISTANCE=ACTION_ICONS.MOVE; ACTION_ICONS.LAYOUT=ACTION_ICONS.FORMATION; ACTION_ICONS.FACTION=ACTION_ICONS.GUARD
ACTION_ICONS.FACTIONS=ACTION_ICONS.GUARD; ACTION_ICONS.POP=ACTION_ICONS.FIT; ACTION_ICONS.DOCK=ACTION_ICONS.FIT
ACTION_ICONS.ZOOMIN=ACTION_ICONS['+']; ACTION_ICONS.ZOOMOUT=ACTION_ICONS['-']; ACTION_ICONS.BACK=ACTION_ICONS.PREV
ACTION_ICONS.REINFORCEMENT=ACTION_ICONS.PILOT; ACTION_ICONS.REPAIR=ACTION_ICONS.SERVICE; ACTION_ICONS.SURGE=ACTION_ICONS.STRIKE
ACTION_ICONS.FLOWN=ACTION_ICONS.PILOT; ACTION_ICONS.LOST=ACTION_ICONS.CLOSE; ACTION_ICONS.LIVE=ACTION_ICONS.GUARD; ACTION_ICONS.ALL=ACTION_ICONS.SELECT
ACTION_ICONS.RELEASE=ACTION_ICONS.AUTO; ACTION_ICONS.ALLOW=ACTION_ICONS.WITHDRAW; ACTION_ICONS.END=ACTION_ICONS.EXIT
local ICON_ACTIONS={MOVE=true,ATTACK=true,GUARD=true,PILOT=true,SERVICE=true,FOCUS=true,STOP=true,
    RESUME=true,CONTINUE=true,EXIT=true,QUIT=true,RESTART=true,WITHDRAW=true,SCENE=true,MUSIC=true,
    ALL=true,HOLD=true,ENGAGE=true,RELEASE=true}

function RTS:DrawActionIcon(text,x,y,size)
    local label=tostring(text):upper(); local key=label:match('^([A-Z]+)') or label:sub(1,1)
    local paths=ACTION_ICONS[key]
    if paths then
        for _,p in ipairs(paths) do gr.drawLine(x+p[1]*size,y+p[2]*size,x+p[3]*size,y+p[4]*size) end
    end
end

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

function RTS:DrawButton(rect, text, enabled, active, icon, showLabel)
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
    local word=tostring(text):upper():match('^([A-Z]+)')
    if icon~=false and ICON_ACTIONS[word] and not showLabel and not tostring(text):find('CP',1,true) then
        local size=math.max(6,math.min(m.pad(28),rect.y2-rect.y1-10,rect.x2-rect.x1-10))
        self:DrawActionIcon(icon or text,(rect.x1+rect.x2-size)/2,(rect.y1+rect.y2-size)/2,size)
        if self:PointInside(rect,io.getMouseX(),io.getMouseY()) then self.ButtonIconTooltip={text=tostring(text),rect=rect} end
        return
    end
    local inset=math.min(m.buttonPadding,math.floor((rect.x2-rect.x1)*.15))
    local iconSize=math.min(m.pad(18),rect.y2-rect.y1-8)
    local textLeft=rect.x1+inset
    if icon~=false and text~='' and rect.x2-rect.x1>=90 and iconSize>=8 then
        self:DrawActionIcon(icon or text,textLeft,rect.y1+(rect.y2-rect.y1-iconSize)/2,iconSize)
        textLeft=textLeft+iconSize+m.pad(6)
    end
    local width = math.max(1, rect.x2 - inset - textLeft)
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
        self:DrawCenteredTextClipped(line,textLeft,rect.x2-inset,textY+(i-1)*m.lineHeight)
    end
end

function RTS:DrawButtonIconTooltip()
    local tip=self.ButtonIconTooltip; if not tip then return end
    local m=self:GetUIMetrics(); local w=math.min(420,self:TextWidth(tip.text)+20,gr.getScreenWidth()-20)
    local lines=self:WrapTextLinesToWidth(tip.text,w-16,4); local h=#lines*m.lineHeight+16
    local x=U.clamp(tip.rect.x1,8,gr.getScreenWidth()-w-8)
    local y=U.clamp(tip.rect.y2+6,8,gr.getScreenHeight()-h-8)
    gr.setColor(4,10,18,245); gr.drawRectangle(x,y,x+w,y+h,true)
    gr.setColor(225,240,250,255)
    for i,line in ipairs(lines) do self:DrawTextLine(line,x+8,y+8+(i-1)*m.lineHeight,w-16) end
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
