local R=require 'fs2rts_state'

function R:DrawFleetHistoryBadge(ship,x,y,width)
    local text=self:GetShipHistoryBadge(ship)
    if text=='' then return end
    gr.setColor(255,225,130,255); self:DrawTextLine(text,x,y,math.max(1,width or 48))
end

function R:GetLiveCostHeight()
    if not self.ShowFleetCost then return 0 end
    local m=self:GetUIMetrics(); return 3*m.lineHeight+2*m.panelPadding
end

function R:DrawLiveFleetCost(sw,sh)
    if not self.ShowFleetCost or self.SetupActive or self.CinematicActive or self.PilotCommMenuActive then return end
    local m=self:GetUIMetrics(sw,sh)
    local left=m.margin+m.selectionWidth+m.gap; local right=sw-m.margin-m.rightPanelWidth-m.gap
    if right-left<160 then return end
    local y=m.topBarHeight+m.gap; local h=self:GetLiveCostHeight()
    gr.setColor(3,10,18,220); gr.drawRectangle(left,y,right,y+h,true)
    local own,other=self:GetFleetCrewSummary('BLUE'),self:GetFleetCrewSummary()
    gr.setColor(255,190,130,255)
    self:DrawTextLine('YOU // EST DEAD '..own.dead..' / MISSING '..own.missing..' / ? HULLS '..own.unknown,left+m.panelPadding,y+m.panelPadding,right-left-2*m.panelPadding)
    gr.setColor(205,195,205,255)
    self:DrawTextLine('OPPOSING // EST DEAD '..other.dead..' / MISSING '..other.missing..' / ? HULLS '..other.unknown,left+m.panelPadding,y+m.panelPadding+m.lineHeight,right-left-2*m.panelPadding)
    local notice
    for i=#(self.FleetHumanityNotices or {}),1,-1 do
        local candidate=self.FleetHumanityNotices[i]
        if candidate.untilTime>=self:UINow() and (not notice or candidate.priority>notice.priority) then notice=candidate end
    end
    gr.setColor(245,225,170,255)
    self:DrawTextLine(notice and notice.text or 'ESTIMATES v1 // details in CREWS / report // F9 hide',left+m.panelPadding,y+m.panelPadding+2*m.lineHeight,right-left-2*m.panelPadding)
end

function R:GetCostOfCommandRows(summary,fleet)
    local rows={'COST OF COMMAND // CREW COUNTS ARE DESIGN ESTIMATES',
        'Your station: '..(summary.playerStationLost and 'LOST' or 'PRESENT')..' // Original result: '..tostring(summary.strategicVictor or 'UNRESOLVED')}
    for _,line in ipairs(self:GetFleetCostLines()) do rows[#rows+1]=line end
    rows[#rows+1]='YOUR FLEET: '..(fleet.lost or 0)..' lost / '..(fleet.escaped or 0)..' escaped / '..(fleet.present or 0)..' present / '..(fleet.stranded or 0)..' stranded'
    rows[#rows+1]='AFTER-RESULT LOSSES: '..(fleet.afterResultLosses or 0)..' // DAMAGED RETURNS: '..(fleet.recoveries or 0)
    for _,id in ipairs(fleet.records or {}) do
        local record=self.UnitHistory[id]
        if record.everPiloted then rows[#rows+1]={id=id,text='YOU FLEW '..record.name..' // '..record.fate..' // '..math.floor(self:GetPilotHistorySeconds(record))..'s / returns '..record.recoveries} end
        for _,citation in ipairs(self:GetRecordCitations(record)) do rows[#rows+1]='  '..record.name..': '..citation.reason end
    end
    rows[#rows+1]='Model v1: lost hulls estimate 80% dead; remaining crew fate unconfirmed. No repair restores people.'
    rows[#rows+1]='Battle '..self:FormatTime(summary.durationSeconds or 0)..' // Tier '..tostring(summary.tier or 1)..' // CP net refunds '..math.floor(summary.cpSpent or 0)
    return rows
end

function R:GetLiveHistoryRecords()
    local rows={}
    local filter=self.FleetHistoryFilter or 'all'
    for _,record in pairs(self.UnitHistory or {}) do
        if record.faction=='BLUE' and (filter=='all' or filter=='flown' and record.everPiloted
            or filter=='lost' and record.fate=='LOST' or filter=='live' and record.fate=='PRESENT') then rows[#rows+1]=record end
    end
    table.sort(rows,function(a,b)
        if a.everPiloted~=b.everPiloted then return a.everPiloted==true end
        return tonumber(a.id:match('%d+'))<tonumber(b.id:match('%d+'))
    end)
    return rows
end

function R:GetLiveHistoryPanelHeight(count,maxHeight)
    local lh=self:GetUIMetrics().lineHeight
    local detailHeight=self.UnitHistory[self.LiveHistoryDetail] and (lh*5+35) or 2*lh+8
    local height=8+lh+6+24+6+math.max(1,count)*(lh+9)+12+detailHeight
    local paging=maxHeight and height>maxHeight
    return paging and maxHeight or height,detailHeight,paging and 38 or 12
end

local LOST_COLOR={255,110,100,255}

function R:DrawLiveHistoryPanel(x1,y1,x2,y2,rows)
    local m=self:GetUIMetrics(); local lh=m.lineHeight; local y=y1+8
    self.FleetHistoryButtonRects={}
    rows=rows or self:GetLiveHistoryRecords()
    local height,detailHeight,pagerHeight=self:GetLiveHistoryPanelHeight(#rows,y2-y1)
    y2=math.min(y2,y1+height)
    local filter=self.FleetHistoryFilter or 'all'
    gr.setColor(255,225,145,255); self:DrawTextLine('CREW RECORDS // SELECT TO INSPECT',x1,y,x2-x1)
    y=y+lh+6
    local filters={{'all','ALL'},{'flown','FLOWN'},{'lost','LOST'},{'live','LIVE'}}
    local w=(x2-x1-9)/4
    for i,choice in ipairs(filters) do
        local rect={x1=x1+(i-1)*(w+3),y1=y,x2=x1+(i-1)*(w+3)+w,y2=y+24}
        self.FleetHistoryButtonRects['filter_'..choice[1]]=rect; self:DrawButton(rect,choice[2],true,filter==choice[1],false)
    end
    y=y+30
    local detailY=y2-detailHeight
    local rowHeight=lh+9
    local capacity=math.max(1,math.floor((detailY-y-pagerHeight)/rowHeight))
    local pages=math.max(1,math.ceil(#rows/capacity)); self.FleetHistoryPageSize=capacity
    self.FleetHistoryOffset=math.floor(math.min(self.FleetHistoryOffset or 0,(pages-1)*capacity)/capacity)*capacity
    for i=1,capacity do
        local record=rows[i+self.FleetHistoryOffset]; if not record then break end
        local rect={x1=x1,y1=y,x2=x2,y2=y+rowHeight-3}; self.FleetHistoryButtonRects[record.id]=rect
        local color=record.fate=='LOST' and LOST_COLOR or nil
        self:DrawButton(rect,'',true,self.LiveHistoryDetail==record.id,false,true,color)
        local size=rowHeight-9; local px=rect.x1+6; local py=rect.y1+3
        local texture=self:GetBriefingIcon(record.class,record.role,false)
        if texture then gr.drawImage(texture,px,py,px+size,py+size)
        else self:DrawShipRoleShape(record.role or 'combat',px,py,size) end
        if color then gr.setColor(unpack(color)) else gr.setColor(180,235,255,255) end
        local fateX=x2-6-self:TextWidth(record.fate)
        self:DrawTextLine(record.name,px+size+8,py,math.max(1,fateX-px-size-16))
        self:DrawTextLine(record.fate,fateX,py,x2-fateX-6)
        y=y+rowHeight
    end
    local prev={x1=x1,y1=detailY-32,x2=x1+58,y2=detailY-7}; local nextPage={x1=x2-58,y1=detailY-32,x2=x2,y2=detailY-7}
    if pages>1 then
        self.FleetHistoryButtonRects.prev=prev; self.FleetHistoryButtonRects.next=nextPage
        self:DrawButton(prev,'PREV',self.FleetHistoryOffset>0,false)
        self:DrawButton(nextPage,'NEXT',self.FleetHistoryOffset+capacity<#rows,false)
        gr.setColor(180,200,210,255); self:DrawCenteredTextClipped('PAGE '..(self.FleetHistoryOffset/capacity+1)..'/'..pages,prev.x2+3,nextPage.x1-3,prev.y1+4)
    end
    local record=(self.UnitHistory or {})[self.LiveHistoryDetail]
    if not record then gr.setColor(180,200,210,255); self:DrawWrappedTextToWidth('Select a ship to see crew and history.',x1,detailY,x2-x1,lh,2); return end
    if record.fate=='LOST' then gr.setColor(unpack(LOST_COLOR)) else gr.setColor(255,225,145,255) end
    self:DrawTextLine(record.name..' // '..record.fate,x1,detailY,x2-x1)
    gr.setColor(195,215,225,255)
    self:DrawTextLine((record.everPiloted and ('YOU FLEW '..math.floor(self:GetPilotHistorySeconds(record))..'s') or 'NOT PILOTED BY YOU')..' / RETURNS '..record.recoveries,x1,detailY+lh,x2-x1)
    self:DrawTextLine('CREW '..(record.crewComplement or '?')..' (est) / EST DEAD '..(record.crewEstimatedDead or 0)..' / MISSING '..(record.crewMissing or 0),x1,detailY+2*lh,x2-x1)
    local citations=self:GetRecordCitations(record)
    local wing=record.originalWing and self.WingHistory[record.originalWing]
    if wing then for _,citation in ipairs(self:GetRecordCitations(wing)) do citations[#citations+1]={reason='WING '..wing.label..': '..citation.reason} end end
    local index=math.min(self.FleetHistoryCitationIndex or 1,math.max(1,#citations)); self.FleetHistoryCitationIndex=index
    self:DrawWrappedTextToWidth(citations[index] and citations[index].reason or 'No citations earned.',x1,detailY+3*lh,x2-x1,lh,2)
    local focus={x1=x1,y1=y2-25,x2=x1+88,y2=y2}; self.FleetHistoryButtonRects.focus=focus
    local live=record.fate=='PRESENT' and self:FindShipBySignature(record.signature)
    self:DrawButton(focus,'FOCUS',require('fs2rts_util').shipAlive(live),false,'FOCUS',true)
    if #citations>1 then
        local before={x1=x2-118,y1=y2-25,x2=x2-62,y2=y2}; local after={x1=x2-56,y1=y2-25,x2=x2,y2=y2}
        self.FleetHistoryButtonRects.cite_prev=before; self.FleetHistoryButtonRects.cite_next=after
        self:DrawButton(before,'<',index>1,false); self:DrawButton(after,'>',index<#citations,false)
        self:DrawTextLine('CITATION '..index..'/'..#citations,focus.x2+4,y2-21,math.max(1,before.x1-focus.x2-8))
    end
end

function R:HandleFleetHistoryClick(x,y)
    if self:PointInside(self.HumanityOpenRect,x,y) then self.PanelTab='history'; return true end
    if self.PanelTab~='history' then return false end
    for id,rect in pairs(self.FleetHistoryButtonRects or {}) do
        if self:PointInside(rect,x,y) then
            if id:match('^filter_') then self.FleetHistoryFilter=id:sub(8); self.FleetHistoryOffset=0; self.LiveHistoryDetail=nil
            elseif id=='focus' then self:FocusHistoryShip(self.LiveHistoryDetail,false)
            elseif id=='cite_prev' then self.FleetHistoryCitationIndex=math.max(1,(self.FleetHistoryCitationIndex or 1)-1)
            elseif id=='cite_next' then self.FleetHistoryCitationIndex=(self.FleetHistoryCitationIndex or 1)+1
            elseif id=='prev' then self.FleetHistoryOffset=math.max(0,(self.FleetHistoryOffset or 0)-(self.FleetHistoryPageSize or 1))
            elseif id=='next' then self.FleetHistoryOffset=(self.FleetHistoryOffset or 0)+(self.FleetHistoryPageSize or 1)
            else self.LiveHistoryDetail=id; self.FleetHistoryCitationIndex=1 end
            return true
        end
    end
    return false
end

return R
