-- HUD full-screen overlays: options strip, chase banner, post-battle report, exit menu.
local _shared = require "fs2rts_hud.common"
local RTS, shipValid, objectValid = _shared.RTS, _shared.shipValid, _shared.objectValid

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
    local descH=2*lh
    local top=y1+m.pad(6); local bottom=y2-m.pad(6)
    self.FormationButtonRect={x1=x1+m.buttonPadding,y1=top,x2=x2-musicW-m.buttonPadding,y2=bottom-descH-m.pad(4)}
    self:DrawButton(self.FormationButtonRect,label,true,false)
    gr.setColor(150,180,195,255)
    local dx1,dx2=x1+m.pad(16),x2-musicW-m.pad(8)
    self:DrawCenteredWrappedTextToWidth(desc or "",dx1,dx2,bottom-descH,dx2-dx1,lh,2)
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
    if self.ShowHotkeyHints~=false then self:DrawCenteredTextClipped("RMB drag orbit | Wheel zoom | "..(c.Chase or "B").." or Alt+double-click releases",x1+m.pad(12),x2-m.pad(12),y1+m.pad(6)+lh) end
end

-- After-action report. The battle froze with a bare VICTORY/DEFEAT card, which
-- told the player nothing about how the fight actually went.
function RTS:DrawOutcomeTitle(text,x1,y1,x2,y2)
    -- Use the retail large UI font directly. Enlarging a font01 render texture
    -- filters its nine-pixel glyphs and makes the heading visibly blurry.
    local previous=gr.CurrentFont
    local large=gr.Fonts and gr.Fonts[2] or nil
    if objectValid(large) then gr.CurrentFont=large end
    gr.setColor(255,255,255,255)
    self:DrawCenteredText(text,x1,x2,math.floor((y1+y2-self:TextHeight(text))/2))
    if objectValid(previous) then gr.CurrentFont=previous end
end

function RTS:DrawPostBattleOverlay(sw,sh)
    if not self.PostBattleActive then return end
    local summary=self.BattleSummary or {}; local fleet=summary.fleetHistory or {records={},wings={}}
    local w=math.min(860,sw-32); local h=math.min(540,sh-64); local x=(sw-w)/2; local y=(sh-h)/2
    gr.setColor(0,0,0,170); gr.drawRectangle(0,0,sw,sh,true)
    gr.setColor(3,9,15,250); gr.drawRectangle(x,y,x+w,y+h,true)
    gr.setColor(20,45,60,255); gr.drawRectangle(x,y,x+w,y+52,true)
    self:DrawOutcomeTitle(self.GameStatus=='VICTORY' and 'VICTORY' or self.GameStatus=='DRAW' and 'DRAW' or 'DEFEAT',x+16,y,x+w-16,y+52)
    gr.setColor(225,235,240,255); self:DrawCenteredWrappedTextToWidth(self.PostBattleResult or 'BATTLE REPORT',x+16,x+w-16,y+61,w-32,18,2)
    self.PostBattleButtonRects={}
    local tabs={'SUMMARY','SHIPS','WINGS','FACTIONS'}
    for i,name in ipairs(tabs) do local bw=(w-40)/4; local rect={x1=x+12+(i-1)*(bw+5),y1=y+101,x2=x+12+(i-1)*(bw+5)+bw,y2=y+129}; self.PostBattleButtonRects['page_'..name]=rect; self:DrawButton(rect,name,true,(self.ReportPage or 'SUMMARY')==name) end
    local rows={}; local page=self.ReportPage or 'SUMMARY'
    if page=='SUMMARY' then
        local victor=summary.strategicVictor or 'UNRESOLVED'
        rows={ 'Player station: '..(summary.playerStationLost and 'LOST' or 'PRESENT'),
            'Original station result: '..(victor=='UNRESOLVED' and 'UNRESOLVED' or victor=='NONE' and 'DRAW' or self:GetFactionDisplayName(victor)..' VICTOR'),
            'Fleet: '..(fleet.escaped or 0)..' escaped / '..(fleet.present or 0)..' still present / '..(fleet.lost or 0)..' lost',
            'After-result losses: '..(fleet.afterResultLosses or 0)..' // Stranded: '..(fleet.stranded or 0),
            'Returned from damaged service: '..(fleet.recoveries or 0)..' // Ships piloted: '..(fleet.piloted or 0),
            'Battle length: '..self:FormatTime(summary.durationSeconds or 0)..' // Tier '..tostring(summary.tier or 1),
            'CP spent (net refunds): '..math.floor(summary.cpSpent or 0)..' // Remaining '..math.floor(summary.cpRemaining or 0),
            'Enemy kills: '..tostring(summary.kills or 0)..' // Capital losses: '..tostring(summary.capitalLosses or 0),
            self.AftermathActive and 'Global aftermath: construction, income, abilities and refitting ended.' or 'Other surviving stations retain production, income and service.' }
    elseif page=='SHIPS' then
        for _,id in ipairs(fleet.records or {}) do local r=self.UnitHistory[id]; local text=r.name..' // '..r.class..' // '..r.fate
            if self.HistoryDetail==id then text=text..string.format(' // min hull %d%% // %d recoveries // piloted %ss',math.floor(r.lowestHull*100),r.recoveries,math.floor(r.pilotSeconds)) end
            rows[#rows+1]={text=text,id=id}
            if self.HistoryDetail==id then rows[#rows+1]='  Crew exposure: '..(r.crewExposureEstimate or 'UNKNOWN')..' (role estimate; no head count)' end
            for _,kind in ipairs({'RECOVERY_REJOIN','WITHDRAWAL_COVER'}) do
                local citation=(r.citations or {})[kind]
                if citation then rows[#rows+1]='  CITATION // '..citation.reason end
            end
        end
    elseif page=='WINGS' then
        for _,wing in ipairs(fleet.wings or {}) do rows[#rows+1]=wing.label..' // Original '..wing.original..' / Escaped '..wing.escaped..' / Present '..wing.present..' / Lost '..wing.lost end
    else
        for _,faction in ipairs(summary.factions or {}) do rows[#rows+1]=faction.label..' // '..(faction.eliminated and 'STATION LOST' or 'STATION PRESENT')..' // Mobile '..(faction.mobileShips or 0)..' / Installations '..(faction.installations or 0) end
    end
    if #rows==0 then rows[1]='No records yet.' end
    local capacity=math.max(1,math.floor((h-236)/21)); local offset=math.min(self.ReportOffset or 0,math.max(0,#rows-capacity)); self.ReportOffset=offset
    for i=1,capacity do local row=rows[i+offset]; if not row then break end; local yy=y+139+(i-1)*21
        gr.setColor(205,225,235,255); self:DrawTextLine(type(row)=='table' and row.text or row,x+16,yy,w-32)
        if type(row)=='table' then self.PostBattleButtonRects['history_'..row.id]={x1=x+12,y1=yy,x2=x+w-12,y2=yy+20} end
    end
    local prev={x1=x+16,y1=y+h-91,x2=x+80,y2=y+h-66}; local nextPage={x1=x+w-80,y1=prev.y1,x2=x+w-16,y2=prev.y2}
    self.PostBattleButtonRects.prev=prev; self.PostBattleButtonRects.next=nextPage
    self:DrawButton(prev,'<',offset>0,false); self:DrawButton(nextPage,'>',offset+capacity<#rows,false)
    local actions={{'restart','RESTART'},{'exit','END OBSERVATION'}}
    if not self.FleetFateFinal then
        table.insert(actions,1,{'resume','CONTINUE'})
        if self.BlueEliminated and (fleet.present or 0)>0 then table.insert(actions,2,{'withdraw','WITHDRAW FLEET'}) end
    end
    local bw=(w-32-(#actions-1)*8)/#actions
    for i,action in ipairs(actions) do local rect={x1=x+16+(i-1)*(bw+8),y1=y+h-53,x2=x+16+(i-1)*(bw+8)+bw,y2=y+h-13}; self.PostBattleButtonRects[action[1]]=rect; self:DrawButton(rect,action[2],true,action[1]=='resume') end
end

function RTS:DrawExitMenu(sw,sh)
    local w=math.min(520,sw-32); local h=180; local x=(sw-w)/2; local y=(sh-h)/2
    gr.setColor(0,0,0,180); gr.drawRectangle(0,0,sw,sh,true)
    gr.setColor(3,9,15,250); gr.drawRectangle(x,y,x+w,y+h,true)
    gr.setColor(255,255,255,255); self:DrawCenteredText('EXIT MENU',x+16,x+w-16,y+20)
    self:DrawCenteredTextClipped('Resume this battle, restart it, or quit to the menu.',x+16,x+w-16,y+58)
    self.ExitMenuButtonRects={}
    local labels={{'resume','RESUME'},{'restart','RESTART'},{'quit','QUIT'}}
    local bw=(w-48)/3
    for i,entry in ipairs(labels) do
        local rect={x1=x+16+(i-1)*(bw+8),y1=y+110,x2=x+16+(i-1)*(bw+8)+bw,y2=y+158}
        self.ExitMenuButtonRects[entry[1]]=rect; self:DrawButton(rect,entry[2],true,false)
    end
end
