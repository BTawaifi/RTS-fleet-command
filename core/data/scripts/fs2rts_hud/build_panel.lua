-- HUD build panel: top layer, build rows, 3D model thumbnails, build tooltip.
local _shared = require "fs2rts_hud.common"
local RTS, clamp = _shared.RTS, _shared.clamp

-- Tooltips and cursor readouts are queued during the panel pass and drawn after
-- the control-hint panel. Drawn in place they were painted over by that panel,
-- which made the unit card description unreadable with hints on.
function RTS:QueueTopLayer(draw)
    self.TopLayerDraws=self.TopLayerDraws or {}
    self.TopLayerDraws[#self.TopLayerDraws+1]=draw
end

function RTS:FlushTopLayer()
    local draws=self.TopLayerDraws; self.TopLayerDraws=nil
    if draws then for _,draw in ipairs(draws) do draw() end end
end

function RTS:DrawBuildPanel(sw,sh)
    self.AutoBuildRequestRects={}; self.CancelAutoBuildRect=nil
    local rect=self:GetProductionPanelRect(sw,sh); local x1,y1,x2,y2=rect.x1,rect.y1,rect.x2,rect.y2
    local m=self:GetUIMetrics(sw,sh); local pad=m.panelPadding; local lh=m.lineHeight
    local historyRows=self.PanelTab=='history' and self:GetLiveHistoryRecords() or nil
    -- Page size comes from CountBuildRows, which counts rows using the same
    -- geometry this loop draws them with. It used to be a separate formula,
    -- floor((height-142)/50), while the loop tested y+44 against y2-74: the two
    -- disagreed by a whole row, and at 768p the loop's guard was already false
    -- on the first iteration, so the production panel drew NO build rows at all.
    self.BuildRowsPerPage=self:CountBuildRows(sw,sh)
    gr.setColor(4,10,18,220); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false); gr.setColor(100,190,220,255)
    if self.PanelTab=='history' then
        self.BuildButtonRects={}; self.BuildNavRects={}; self.StationButtonRects={}; self.AutoModeRect=nil
        self.PanelTabRects={production={x1=x1+pad,y1=y1+pad,x2=x2-pad,y2=y1+pad+24}}
        self:DrawButton(self.PanelTabRects.production,'BACK TO BUILD',true,false)
        self:DrawLiveHistoryPanel(x1+pad,y1+pad+28,x2-pad,y2-pad,historyRows)
        return
    end
    if self.AftermathActive or self.BlueEliminated then
        self.BuildButtonRects={}; self.BuildNavRects={}; self.PanelTabRects={}; self.StationButtonRects={}; self.AutoModeRect=nil
        -- Show the outcome the battle already resolved to. The generic AFTERMATH
        -- card reads as a loss, so it is only the title when no result is set.
        local outcome=self.AftermathActive and (self.GameStatus=='VICTORY' and 'VICTORY' or self.GameStatus=='DRAW' and 'DRAW' or self.GameStatus=='DEFEAT' and 'DEFEAT') or nil
        self:DrawTextLine(outcome or (self.AftermathActive and 'AFTERMATH' or 'YOUR STATION IS LOST'),x1+pad,y1+pad,x2-x1-2*pad)
        gr.setColor(210,225,235,255)
        local message
        if outcome then
            message=(self.AftermathResultText or outcome)..'. Remaining ships stay under your command; the battle report is final once they have left the field.'
        elseif self.AftermathActive then
            message='Command, pilot or withdraw surviving ships. Construction and refitting have ended. Destroy the remaining enemy station to earn a draw, or eliminate every hostile asset for survivor victory.'
        else
            message='Your station is lost. Command, pilot or withdraw your remaining ships; your construction and service are unavailable. Other factions continue their battle and economy.'
        end
        self:DrawWrappedTextToWidth(message,x1+pad,y1+pad+2*lh,x2-x1-2*pad,lh,12)
        self.AftermathReportRect={x1=x1+pad,y1=y2-m.pad(50),x2=x2-pad,y2=y2-m.pad(8)}
        self:DrawButton(self.AftermathReportRect,'BATTLE REPORT',true,false)
        self.HumanityOpenRect={x1=x1+pad,y1=y2-m.pad(78),x2=x2-pad,y2=y2-m.pad(54)}
        self:DrawButton(self.HumanityOpenRect,'CREWS',true,false)
        return
    end
    self.AftermathReportRect=nil
    local tabW=math.floor((x2-x1-2*m.pad(12))/3); local stationTab=self.PanelTab=="station"
    local tabY1=y1+m.buildTabTop; local tabY2=tabY1+m.buildTabHeight
    self.PanelTabRects={production={x1=x1+m.pad(8),y1=tabY1,x2=x1+m.pad(8)+tabW,y2=tabY2},station={x1=x1+m.pad(12)+tabW,y1=tabY1,x2=x1+m.pad(12)+2*tabW,y2=tabY2},history={x1=x1+m.pad(16)+2*tabW,y1=tabY1,x2=x2-m.pad(8),y2=tabY2}}
    self:DrawButton(self.PanelTabRects.production,"BUILD",true,not stationTab); self:DrawButton(self.PanelTabRects.station,"BASE",true,stationTab); self:DrawButton(self.PanelTabRects.history,'CREWS',true,false)
    local now=mn.getMissionTime()
    if stationTab then
        self.BuildButtonRects={}; self.BuildNavRects={}; self.QuickGroupRects={}; self.PolicyButtonRects={}; self.FormationButtonRect=nil; self.MusicButtonRect=nil
        self:DrawStationPanel(x1+pad,y1+m.pad(36),x2-pad,y2-m.pad(76)); self:QueueTopLayer(function() self:DrawStationTooltip(rect) end)
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
    local rb={x1=x1+pad,y1=y,x2=x2-pad,y2=y+m.buildRowHeight}; self.BuildButtonRects[i]=rb
    local unlocked=self:IsBuildOptionUnlocked(option,now)
    local enabled=unlocked and self.CommandPoints>=option.cost and self:GetCarrier()~=nil
    local units=(option.count or 1)>1 and (' x'..option.count) or ''
    self:DrawButton(rb,'',enabled,false)
    local thumbSide=math.min(thumbW,m.buildRowHeight-8); local thumbY=rb.y1+(m.buildRowHeight-thumbSide)/2
    if not self:DrawShipModelThumb(option.class,rb.x1+4,thumbY,rb.x1+4+thumbSide,thumbY+thumbSide) then local tex=self:GetBriefingIcon(option.class,option.role,false); if tex then gr.setColor(255,255,255,enabled and 255 or 120); gr.drawImage(tex,rb.x1+4,thumbY,rb.x1+4+thumbSide,thumbY+thumbSide) end end
    local badgeX=rb.x2-badge-m.buttonPadding
    self:DrawRoleBadge(option.role,badgeX,rb.y1+math.floor((m.buildRowHeight-badge)/2),badge)
    local textX=rb.x1+thumbW+m.buttonPadding
    local textRight=badgeX-m.sectionGap
    if self.AutoPlayerMode then
        local autoWidth=m.pad(32); local buttonHeight=m.pad(28)
        local ar={x1=badgeX-m.sectionGap-autoWidth,x2=badgeX-m.sectionGap,
            y1=rb.y1+(m.buildRowHeight-buttonHeight)/2,y2=rb.y1+(m.buildRowHeight+buttonHeight)/2}
        self.AutoBuildRequestRects[i]=ar; self:DrawButton(ar,'AI',unlocked and not self.BlueEliminated,false)
        textRight=ar.x1-m.sectionGap
    end
    if enabled then gr.setColor(225,240,245,255) else gr.setColor(120,140,150,255) end
    local title='T'..option.tier..' '..option.label..units
    local details=unlocked and (option.cost..' CP | '..string.format('%.0fs',option.time*(self:GetEscalationProfile().buildTimeScale or 1)*self:GetBuildTimeMultiplier('BLUE')))
        or ('UNLOCKS IN '..self:FormatTime(self:GetTierUnlockRemaining(option.tier,now)))
    local textHeight=self:TextHeight(title); local pitch=textHeight+m.pad(4)
    local textY=rb.y1+math.floor((m.buildRowHeight-textHeight-pitch)/2)
    self:DrawTextLine(title,textX,textY,textRight-textX)
    self:DrawTextLine(details,textX,textY+pitch,textRight-textX)
    y=y+m.buildRowPitch end
    self:QueueTopLayer(function() self:DrawBuildTooltip(sw,sh,rect) end)
    end
    local manual="Manual: idle"; local manualStatus=self:GetProductionQueueStatus("BLUE",now,false); if manualStatus then manual="Manual: "..manualStatus.label.." x"..manualStatus.count.." T-"..self:FormatTime(math.ceil(manualStatus.remaining)).." (+"..tostring(manualStatus.queued).." queued, "..manualStatus.active.."/"..manualStatus.slots.." lanes)" end
    gr.setColor(170,195,205,255); self:DrawTextLine(manual,x1+pad,y2-m.buildFooter+m.pad(4),(x2-pad)-(x1+pad))
    local autoState=self.AIStates and self.AIStates.BLUE or nil; local autoText="Auto: idle"
    local autoStatus=self:GetProductionQueueStatus("BLUE",now,true)
    local request=autoState and autoState.AutoBuildRequest
    if self.AutoPlayerMode and autoStatus then local wait=autoStatus.waitingForCapacity and " WAIT CAP" or ""; local queued=(autoStatus.queued or 0)>0 and (" +"..tostring(autoStatus.queued).." queued") or ""; autoText="Auto: "..autoStatus.label.." x"..autoStatus.count.." T-"..self:FormatTime(math.ceil(autoStatus.remaining))..queued..wait elseif self.AutoPlayerMode then autoText="Auto: evaluating fleet / saving CP" end
    if request then autoText='Requested: '..request.label..' // '..request.status end
    gr.setColor(150,180,195,255); self:DrawTextLine(autoText,x1+pad,y2-m.buildFooter+m.pad(26),(x2-pad)-(x1+pad))
    local autoH=math.max(22,m.pad(22))
    self.AutoModeRect={x1=x1+pad,y1=y2-autoH-m.pad(5),x2=x2-pad,y2=y2-m.pad(5)}
    if request then
        self.AutoModeRect.x2=(x1+x2)/2-4
        self.CancelAutoBuildRect={x1=(x1+x2)/2+4,y1=self.AutoModeRect.y1,x2=x2-pad,y2=self.AutoModeRect.y2}
        self:DrawButton(self.AutoModeRect,'AUTO: ON',true,true); self:DrawButton(self.CancelAutoBuildRect,'CANCEL REQUEST',true,false)
    else
        self:DrawButton(self.AutoModeRect,self.AutoPlayerMode and 'AUTO MODE: ON' or 'AUTO MODE: OFF',true,self.AutoPlayerMode)
    end
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
