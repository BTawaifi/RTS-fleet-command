-- HUD setup and fleet-life overlays.
local _shared = require "fs2rts_hud.common"
local RTS = _shared.RTS

function RTS:DrawSetupOverlay(sw,sh)
    local w=math.min(900,sw-32); local h=math.min(740,sh-32); local x1=(sw-w)/2; local y1=(sh-h)/2; local x2=x1+w; local y2=y1+h
    gr.setColor(2,7,12,190); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,210,240,255); gr.drawRectangle(x1,y1,x2,y2,false)
    gr.setColor(110,235,255,255); self:DrawCenteredText("ESCALATION BATTLE CONFIGURATION",x1+20,x2-20,y1+14)
    gr.setColor(190,210,220,255); self:DrawCenteredText("Choose each faction independently. Mirror factions remain enemies with separate colors.",x1+24,x2-24,y1+43)
    local diff=self.Config.Setup.Difficulties[self.SetupDifficultyIndex]; local eco=self.Config.Setup.Economies[self.SetupEconomyIndex]; local dist=self:GetBaseDistanceProfile()
    self.SetupButtonRects={}; self.SetupColorRects={}; local y=y1+74
    local function row(id,label,value,help)
        gr.setColor(255,220,110,255); gr.drawString(label,x1+26,y+4,x1+190,y+23)
        if id=="factions" then
            local left={x1=x1+195,y1=y-2,x2=x1+235,y2=y+24}
            local right={x1=x2-66,y1=y-2,x2=x2-26,y2=y+24}
            local middle={x1=x1+239,y1=y-2,x2=x2-70,y2=y+24}
            self.SetupButtonRects.factions_less=left; self.SetupButtonRects.factions=middle; self.SetupButtonRects.factions_more=right
            self:DrawButton(left,"-",true,false); self:DrawButton(middle,value,true,false); self:DrawButton(right,"+",true,false)
        else
            local r={x1=x1+195,y1=y-2,x2=x2-26,y2=y+24}; self.SetupButtonRects[id]=r; self:DrawButton(r,value,true,false)
        end
        -- Caption starts 3px below the box border; it used to sit on the border.
        gr.setColor(145,175,190,255); gr.drawString(help,x1+199,y+27,x2-28,y+43); y=y+48
    end
    row("difficulty","DIFFICULTY",diff.name.." // click","AI income, production cadence and aggression.")
    row("factions","TOTAL FACTIONS",tostring(self.SetupFactionCount).." of "..self:GetMaxFactionCount().." // click","Includes you. Each faction is a separate hostile team.")
    local layout=self:GetBaseLayoutProfile()
    row("layout","START LAYOUT",layout.name.." // click",layout.desc)
    row("distance","BASE DISTANCE",dist.name.." // "..tostring(math.floor((dist.distance or 18000)/1000)).." km // click","Minimum distance between command stations.")
    row("economy","ECONOMY",eco.name.." // click","Starting command points and passive income.")

    local keys=self:GetFactionKeys(); local pageSize=math.max(1,math.min(5,math.floor((h-418)/44)))
    self.SetupFactionPageSize=pageSize
    local pages=math.max(1,math.ceil(#keys/pageSize))
    local page=math.min(math.max(1,self.SetupFactionPage or 1),pages); self.SetupFactionPage=page
    local previous={x1=x1+26,y1=y,x2=x1+98,y2=y+24}; local nextPage={x1=x2-98,y1=y,x2=x2-26,y2=y+24}
    self.SetupButtonRects.faction_prev=previous; self.SetupButtonRects.faction_next=nextPage
    self:DrawButton(previous,"<",pages>1 and page>1,false); self:DrawButton(nextPage,">",pages>1 and page<pages,false)
    gr.setColor(255,220,110,255); self:DrawCenteredText("FACTION DOCTRINES // PAGE "..page.." / "..pages,x1+105,x2-105,y+4)
    y=y+31
    local first=(page-1)*pageSize+1; local last=math.min(#keys,first+pageSize-1)
    for index=first,last do
        local kind=keys[index]; local def=self:GetFactionDefinition(kind); local species=self:GetFactionChoice(kind)
        local race=self:GetFactionProfile(kind); local label=species=="RANDOM" and "RANDOM // resolve at start" or (race and race.label or species)
        local color=self:GetFactionColorTable(kind); gr.setColor(color[1],color[2],color[3],255); gr.drawRectangle(x1+18,y+5,x1+22,y+31,true)
        self:DrawFactionInsignia(kind,x1+25,y+1,x1+55,y+31)
        gr.setColor(210,230,238,255); local owner=index==1 and "PLAYER" or string.format("AI %02d",index)
        gr.drawString(owner.." // "..(def.short or string.format("TEAM %02d",index)),x1+62,y+4,x1+255,y+23)
        local r={x1=x1+265,y1=y,x2=x2-90,y2=y+25}; self.SetupButtonRects["faction_"..kind]=r
        self:DrawButton(r,label.." // click to change",true,false)
        local swatch={x1=x2-82,y1=y,x2=x2-26,y2=y+25}; self.SetupButtonRects["color_"..kind]=swatch
        gr.setColor(color[1],color[2],color[3],255); gr.drawRectangle(swatch.x1,swatch.y1,swatch.x2,swatch.y2,true)
        gr.setColor(225,235,240,255); gr.drawRectangle(swatch.x1,swatch.y1,swatch.x2,swatch.y2,false)
        gr.setColor(145,175,190,255)
        self:DrawTextLine(race and race.doctrine and (race.doctrine.." // "..race.ability.name) or "Random faction resolves before the battle starts",x1+62,y+27,w-88)
        y=y+44
    end
    gr.setColor(145,175,190,255); self:DrawCenteredText("ELIMINATION // LAST COMMAND STATION STANDING",x1+24,x2-24,y+12)
    local start={x1=x1+130,y1=y2-52,x2=x2-130,y2=y2-14}; self.SetupButtonRects.start=start; self:DrawButton(start,"START ESCALATION",self.SetupFactionCount>=2,true)
    local scene={x1=x2-122,y1=y2-52,x2=x2-26,y2=y2-14}; self.SetupButtonRects.environment=scene
    self:DrawButton(scene,'SCENE',true,false)
    if self.SetupColorPicker then
        local left=x2-298; local top=math.min(y1+300,y2-170)
        gr.setColor(3,10,18,255); gr.drawRectangle(left,top,x2-26,top+112,true)
        gr.setColor(230,240,245,255); gr.drawRectangle(left,top,x2-26,top+112,false)
        self:DrawTextLine("COLOR // TAKEN COLORS SWAP TEAMS",left+8,top+6,256)
        for index,color in ipairs(self.Config.FactionColors) do
            local column=(index-1)%6; local row=math.floor((index-1)/6)
            local rect={x1=left+8+column*43,y1=top+29+row*29,x2=left+44+column*43,y2=top+53+row*29}
            self.SetupColorRects[index]=rect
            gr.setColor(color[1],color[2],color[3],255); gr.drawRectangle(rect.x1,rect.y1,rect.x2,rect.y2,true)
            if self:GetFactionColorIndex(self.SetupColorPicker)==index then gr.setColor(255,255,255,255); gr.drawRectangle(rect.x1-2,rect.y1-2,rect.x2+2,rect.y2+2,false) end
        end
        local random={x1=left+8,y1=top+88,x2=x2-34,y2=top+108}; self.SetupColorRects.random=random
        self:DrawButton(random,"RANDOMIZE ALL COLORS",true,false)
    end
end

function RTS:DrawFleetLifeOverlay(sw,sh)
    self.FleetLifeButtonRects={}
    if self.EnvironmentPicker then
        local w=math.min(560,sw-32); local x=(sw-w)/2; local y=math.max(48,(sh-220)/2)
        gr.setColor(3,10,18,250); gr.drawRectangle(x,y,x+w,y+220,true)
        gr.setColor(110,225,245,255); self:DrawCenteredText('MUSIC / NEBULA BACKDROP',x+12,x+w-12,y+12)
        self.EnvironmentButtonRects={}
        for index,kind in ipairs({'music','backdrop'}) do
            local yy=y+46+(index-1)*65
            local selected
            if kind=='music' then selected=self.EnvironmentMusicIndex else selected=self.EnvironmentBackdropIndex end
            local list=kind=='music' and self.Config.Music.Tracks or self.Config.Environment.NebulaBackdrops
            local label=selected and (kind=='music' and list[selected].label or string.upper(list[selected])) or 'RANDOM AT START'
            gr.setColor(225,235,240,255); self:DrawCenteredTextClipped(string.upper(kind)..': '..label,x+18,x+w-18,yy)
            for i,action in ipairs({'prev','next','random'}) do
                local bw=(w-48)/3; local rect={x1=x+12+(i-1)*(bw+12),y1=yy+22,x2=x+12+(i-1)*(bw+12)+bw,y2=yy+48}
                self.EnvironmentButtonRects[kind..'_'..action]=rect
                self:DrawButton(rect,action=='prev' and '< PREV' or action=='next' and 'NEXT >' or 'RANDOM',true,false)
            end
        end
        local close={x1=x+w/2-65,y1=y+181,x2=x+w/2+65,y2=y+209}
        self.EnvironmentButtonRects.close=close; self:DrawButton(close,'CLOSE',true,false)
        return
    end
    if self.SetupActive then return end
    local m=self:GetUIMetrics(sw,sh)
    local left=m.margin+m.selectionWidth+m.gap
    local right=sw-m.margin-m.rightPanelWidth-m.gap
    local bw=math.min(150,math.max(1,(right-left-16)/3))
    local x=(left+right-3*bw-16)/2
    local y=sh-m.margin-25
    if self.ControlsRect then y=math.min(y,self.ControlsRect.y1-m.gap-25) end
    local function button(id,label,enabled,active)
        local rect={x1=x,y1=y,x2=x+bw,y2=y+25}; self.FleetLifeButtonRects[id]=rect; self:DrawButton(rect,label,enabled,active==true); x=x+bw+8
    end
    if self.BlueEliminated or self.AftermathActive then button('withdraw','WITHDRAW SELECTED',#self:GetSelectedFriendlyShips()>0) end
    -- Lit while interception is on (enemies may fire on departing ships).
    if next(self.ExtractionAreas or {}) then button('passage','INTERCEPT',true,self.AllowWithdrawal.BLUE==false) end
    if self.PlayerDefeatShown or self.AftermathActive then button('report','BATTLE REPORT',true) end
    for kind,area in pairs(self.ExtractionAreas or {}) do
        self:DrawWorldRangeRing(area.center,area.radius,self:GetFactionColorTable(kind),100)
        local xx,yy=area.center:getScreenCoords()
        if xx~=false then gr.setColor(220,235,240,255); self:DrawTextLine('EXTRACTION // '..self:GetFactionDisplayName(kind),xx,yy,math.max(0,sw-xx-12)) end
    end
    local notice=self.FleetRecoveryNotice
    if notice and self:UINow()<=notice.untilTime then
        local record=self.UnitHistory[notice.id]
        if record and record.fate=='PRESENT' then
            local w=math.min(460,right-left); local xx=(left+right-w)/2; local yy=y-m.gap-70
            gr.setColor(3,10,18,245); gr.drawRectangle(xx,yy,xx+w,yy+70,true)
            gr.setColor(255,195,120,255); self:DrawTextLine(record.name..' // CRITICAL HULL',xx+10,yy+7,w-20)
            local focus={x1=xx+10,y1=yy+32,x2=xx+10+w*.4,y2=yy+59}
            local service={x1=focus.x2+8,y1=focus.y1,x2=xx+w-10,y2=focus.y2}
            self.FleetLifeButtonRects.focus=focus; self.FleetLifeButtonRects.service=service
            self:DrawButton(focus,'FOCUS',true,false)
            self:DrawButton(service,self:GetCarrier() and 'SERVICE' or 'STATION LOST',not self.BlueEliminated and not self.AftermathActive,false)
        end
    end
end
