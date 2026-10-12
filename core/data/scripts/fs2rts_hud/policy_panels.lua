-- HUD side panels: quick groups, policy panel, notifications and announcements.
local _shared = require "fs2rts_hud.common"
local RTS, clamp, shipAlive = _shared.RTS, _shared.clamp, _shared.shipAlive

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
    local preview=math.max(110,m.pad(150)); local edge=m.panelPadding; local descW=w-2*edge
    local lines=self:WrapTextLinesToWidth((desc:gsub("%s+"," ")),descW,12)
    local boxHeight=m.pad(48)+#lines*lh+preview+m.pad(8)
    local x2=panel.x1-m.pad(10); local x1=x2-w
    local y1=clamp(my-m.pad(20),m.topBarHeight+m.pad(4),math.max(m.topBarHeight+m.pad(4),sh-boxHeight-m.margin))
    local y2=y1+boxHeight
    gr.setColor(4,10,18,235); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    gr.setColor(235,245,250,255); self:DrawCenteredTextClipped(option.class..((option.count or 1)>1 and (" x"..option.count) or ""),x1+edge,x2-edge,y1+edge)
    gr.setColor(255,220,110,255); self:DrawCenteredTextClipped(stats,x1+edge,x2-edge,y1+edge+lh)
    local side=preview-m.pad(8); local cx=math.floor((x1+x2)/2)
    self:DrawRotatingModel(option.class,cx-side/2,y1+m.pad(48),cx+side/2,y1+m.pad(48)+side)
    gr.setColor(160,200,215,255)
    for i,line in ipairs(lines) do self:DrawCenteredTextClipped(line,x1+edge,x2-edge,y1+m.pad(52)+preview+(i-1)*lh) end
end

function RTS:DrawQuickGroupsPanel(sw,sh)
    local r=self:GetQuickGroupPanelRect(sw,sh)
    -- Skipped entirely when the column solve had to drop this strip to fit the
    -- panels above it; the control groups stay reachable from their keys.
    if r.y2<=r.y1 then self.QuickGroupRects={}; return end
    local x1,y1,x2,y2=r.x1,r.y1,r.x2,r.y2
    local m=self:GetUIMetrics(sw,sh); local pad=m.panelPadding
    gr.setColor(4,10,18,220); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    gr.setColor(210,230,238,255); self:DrawTextLine(self.ShowHotkeyHints==false and 'QUICK GROUPS' or "QUICK GROUPS // Ctrl=overwrite",x1+pad,y1+pad,(x2-pad)-(x1+pad))
    local gap=m.pad(8); local bw=((x2-x1)-2*pad-gap*3)/4; local bx=x1+pad; self.QuickGroupRects={}
    for i=1,4 do
        local br={x1=bx,y1=y1+m.pad(34),x2=bx+bw,y2=y2-m.pad(9)}; self.QuickGroupRects[i]=br; local count=self:GetControlGroupCount(i)
        self:DrawButton(br,'',true,count>0)
        local lineHeight=self:TextHeight('M'); local textY=br.y1+math.floor((br.y2-br.y1-2*lineHeight-4)/2)
        gr.setColor(235,245,250,255); self:DrawCenteredTextClipped(tostring(i),br.x1+4,br.x2-4,textY)
        gr.setColor(count>0 and 235 or 155,count>0 and 245 or 180,count>0 and 250 or 190,255)
        self:DrawCenteredTextClipped(tostring(count).." ships",br.x1+4,br.x2-4,textY+lineHeight+4)
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
        local key=ship.Class.Name.."|"..controller.."|"..label.."|"..tostring(self:GetFactionKey(ship))
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
    for _,def in ipairs(defs) do local r={x1=bx,y1=by,x2=bx+buttonW,y2=by+buttonH}; self.PolicyButtonRects[def.id]=r; self:DrawButton(r,self.ShowHotkeyHints==false and def.id or def.text,policyEnabled,self.GlobalPolicy==def.id); bx=bx+buttonW+gap end
    local description="Ships do nothing until you order them. No production, no self-preservation overrides."
    if self.GlobalPolicy=="ENGAGE" then description="Hunt enemies anywhere on the map."
    elseif self.GlobalPolicy=="RETREAT" then description="Pull back behind "..self:GetFactionDisplayName("BLUE").." station, out of the fight."
    elseif self.GlobalPolicy=="STANDOFF" then description="Escort "..self:GetFactionDisplayName("BLUE").." station and fight anything that comes near it." end
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

function RTS:GetNotificationRect(sw,sh,height,slot)
    local m=self:GetUIMetrics(sw,sh)
    local left=self:GetSelectionPanelRect(sw,sh).x2+m.gap
    local right=sw-m.margin-m.rightPanelWidth-m.gap
    if right<=left then return nil end
    local y=m.topBarHeight+m.gap
    if slot=='ready' and self.AnnouncementText and self:UINow()<=(self.AnnouncementUntil or -1) then
        y=y+m.lineHeight+m.pad(20)+m.gap
    elseif slot=='status' then
        y=sh-m.pad(100)-height
        if self.ControlsRect then y=math.min(y,self.ControlsRect.y1-m.gap-height) end
    end
    -- A popped map's buttons remain usable even when it occupies this band.
    if self.MapPoppedOut then
        local map=self:GetTacticalMapRect()
        if left<map.x2 and right>map.x1 and y<map.y1+m.mapHeader and y+height>map.y1 then
            y=map.y1+m.mapHeader+m.gap
        end
    end
    if y<m.topBarHeight or y+height>sh-m.margin then return nil end
    return {x1=left,y1=y,x2=right,y2=y+height}
end

function RTS:DrawAnnouncement(sw,sh)
    if self.AnnouncementText==nil or self:UINow()>(self.AnnouncementUntil or -1) then return end
    local m=self:GetUIMetrics(sw,sh); local lh=m.lineHeight
    local rect=self:GetNotificationRect(sw,sh,lh+m.pad(20),'announcement')
    if not rect then return end
    self.AnnouncementRect=rect
    local x1,x2,y1,y2=rect.x1,rect.x2,rect.y1,rect.y2
    gr.setColor(0,0,0,220); gr.drawRectangle(x1,y1,x2,y2,true)
    local key=self.AnnouncementFaction
    if key and self:GetFactionDefinition(key) then local c=self:GetFactionColorTable(key); gr.setColor(c[1],c[2],c[3],255)
    else gr.setColor(240,240,240,255) end
    gr.drawRectangle(x1,y1,x2,y2,false)
    self:DrawCenteredTextClipped(self.AnnouncementText,x1+m.pad(18),x2-m.pad(18),y1+math.floor((y2-y1-lh)/2))
end

function RTS:DrawFleetCitationNotice(sw,sh)
    local notice=self.FleetCitationNotice
    if not notice or self:UINow()>notice.untilTime or self.PilotCommMenuActive then return false end
    local m=self:GetUIMetrics(sw,sh)
    local slot=self.PossessedSignature and 'announcement' or 'status'
    local rect=self:GetNotificationRect(sw,sh,m.lineHeight+m.pad(16),slot)
    if not rect then return false end
    local lines=self:WrapTextLinesToWidth('CITATION // '..notice.name..': '..notice.reason,rect.x2-rect.x1-2*m.panelPadding,4)
    rect=self:GetNotificationRect(sw,sh,#lines*m.lineHeight+2*m.panelPadding,slot)
    if not rect then return false end
    gr.setColor(4,10,18,240); gr.drawRectangle(rect.x1,rect.y1,rect.x2,rect.y2,true)
    gr.setColor(255,220,110,255)
    for i,line in ipairs(lines) do self:DrawCenteredTextClipped(line,rect.x1+m.panelPadding,rect.x2-m.panelPadding,rect.y1+m.panelPadding+(i-1)*m.lineHeight) end
    return true
end

function RTS:DrawNewUnitPopup(sw,sh)
    self.NewUnitPopupRect=nil; self.NewUnitPopupSelectRect=nil
    local popup=self.NewUnitPopup
    if popup==nil or self.PossessedSignature~=nil then return end
    local now=self:UINow()
    if popup.expiresAt==nil then popup.expiresAt=now+(self.Config.UI.NewUnitPopupSeconds or 5) end
    if now>popup.expiresAt then self.NewUnitPopup=nil; return end
    local count=0
    for _,signature in ipairs(popup.signatures) do
        local ship=self:FindShipBySignature(signature)
        if shipAlive(ship) and self:IsMovableFriendly(ship) then count=count+1 end
    end
    if count==0 then self.NewUnitPopup=nil; return end

    local m=self:GetUIMetrics(sw,sh); local height=m.lineHeight+m.pad(18)
    local card=self:GetNotificationRect(sw,sh,height,'ready'); if not card then return end
    -- The notification band spans the whole middle of the screen and would hang the
    -- card off its left edge. The card is a compact single line centred over the 3D
    -- view, keeping the band's height.
    local view=self:GetContactViewport(sw,sh,m); local half=m.pad(160); local centre=(view.x1+view.x2)/2
    card={x1=centre-half,y1=card.y1,x2=centre+half,y2=card.y2}
    local width=card.x2-card.x1; local inset=m.pad(7); local stacked=width<m.pad(300)
    if stacked then height=2*m.lineHeight+3*inset; card=self:GetNotificationRect(sw,sh,height,'ready') end
    if not card then return end
    local y1=card.y1; local buttonWidth=stacked and width-2*inset or m.pad(104)
    local button={x1=card.x2-inset-buttonWidth,y1=y1+inset,x2=card.x2-inset,y2=y1+height-inset}
    if stacked then button.y1=y1+2*inset+m.lineHeight end
    self.NewUnitPopupRect=card; self.NewUnitPopupSelectRect=button
    gr.setColor(4,10,18,240); gr.drawRectangle(card.x1,card.y1,card.x2,card.y2,true)
    gr.setColor(80,220,255,255); gr.drawRectangle(card.x1,card.y1,card.x2,card.y2,false)
    self:DrawCenteredTextClipped(count..(count==1 and " NEW UNIT READY" or " NEW UNITS READY"),
        card.x1+inset,stacked and card.x2-inset or button.x1-inset,
        stacked and y1+inset or y1+math.floor((height-m.lineHeight)/2))
    self:DrawButton(button,"SELECT",true,false)
end
