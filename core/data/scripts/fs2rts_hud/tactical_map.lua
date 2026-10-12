-- HUD tactical map: briefing icons, faction colours, map drawing and chrome.
local _shared = require "fs2rts_hud.common"
local RTS, clamp, vec, shipValid, RETICLE_COLOR_SELECTED = _shared.RTS, _shared.clamp, _shared.vec, _shared.shipValid, _shared.RETICLE_COLOR_SELECTED

-- Retail FS2 briefing icons (sparky_fs2.vp): Icon<species>-<type>.ani.
local BRIEFING_ICON_TYPE={fighter="fighter",bomber="bomber",escort="cruiser",capital="vette",heavy="cap",juggernaut="super",sentry="gun"}

-- FS2 ship type (ships.tbl / objecttypes) -> briefing icon suffix.
local TYPE_ICON={fighter="fighter",bomber="bomber",cruiser="cruiser",corvette="vette",capital="cap",["super cap"]="super",
    awacs="awac",support="support",transport="transport",freighter="freight",["gas miner"]="gas",["sentry gun"]="gun",stealth="fighter",["knossos device"]="node"}

function RTS:LoadBriefingIcon(name)
    local cache=self.TacticalMapIconCache or {}; self.TacticalMapIconCache=cache
    local tex=cache[name]
    if tex==nil then tex=gr.loadTexture(name,true); if tex==nil or not tex:isValid() then tex=false end; cache[name]=tex end
    return tex or nil
end

function RTS:DrawFactionInsignia(kind,x1,y1,x2,y2)
    local profile=self:GetFactionProfile(kind)
    local texture=profile and profile.insignia and self:LoadBriefingIcon(profile.insignia)
    if not texture then return false end
    local width,height=texture:getWidth(),texture:getHeight()
    if width<=0 or height<=0 then return false end
    -- The original GTVA mark is dark bronze and disappears on the dark HUD.
    local backdrop=profile.insigniaBackdrop
    if backdrop then gr.setColor(backdrop[1],backdrop[2],backdrop[3],255); gr.drawRectangle(x1,y1,x2,y2,true) end
    local scale=math.min((x2-x1)/width,(y2-y1)/height)
    local x,y=(x1+x2-width*scale)/2,(y1+y2-height*scale)/2
    gr.setColor(255,255,255,255); gr.drawImage(texture,x,y,x+width*scale,y+height*scale)
    return true
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
    -- Markers stay out of the zoom-button row at the top and the help strip at the
    -- bottom; both bands are drawn over the map, so markers there were hidden or
    -- overprinted.
    local chromeTop=y1+m.pad(4)+m.mapButtonHeight+m.pad(4)
    local hintBand=self.ShowHotkeyHints~=false and (lh+m.pad(8)) or 0
    local contentBottom=y2-hintBand
    self:EachShip(function(ship)
        local faction=self:GetFactionKey(ship)
        local draw=faction~=nil
        if draw then local c=self:GetFactionColorTable(faction); gr.setColor(c[1],c[2],c[3],255) end
        local px,py,inView=self:WorldToTacticalMapIn(ship.Position,mapRect,mapView,mapHalf)
        if draw and inView and ship.Name~=self.Config.ObserverShip then
            local isStation=self:IsCommandStation(ship); local role=self:GetShipRole(ship)
            local big=isStation or role=="capital" or role=="heavy" or role=="juggernaut" or role=="escort"
            local radius=math.max(2,math.floor((isStation and 6 or role=="juggernaut" and 6 or big and 5 or 4)*markerScale))
            -- Keep markers inside the map frame.
            px=clamp(px,x1+radius+2,x2-radius-2); py=clamp(py,chromeTop+radius,contentBottom-radius-2)
            self:DrawShipTypeIcon(ship,px-radius,py-radius,2*radius)
            local ring=radius+6
            if faction=='BLUE' and self.FleetServices and self.FleetServices[ship:getSignature()] then
                local sx,sy=px+radius+3,py-radius-3
                if sx+3<x2 and sy-3>y1 then
                    gr.setColor(120,255,165,255); gr.drawLine(sx-3,sy,sx+3,sy); gr.drawLine(sx,sy-3,sx,sy+3)
                end
            end
            if selectedSet[ship:getSignature()] and px-ring>=x1 and px+ring<=x2 and py-ring>=y1 and py+ring<=y2 then
                gr.setColor(RETICLE_COLOR_SELECTED[1],RETICLE_COLOR_SELECTED[2],RETICLE_COLOR_SELECTED[3],255); gr.drawCircle(ring,px,py,false) end
        end
    end)
    -- Jump signatures for hulls still building, at their warp-in points.
    local signatureColour=self:GetFactionColorTable('BLUE')
    for _,signature in ipairs(self:GetBuildSignatures(self:UINow())) do
        local sx,sy,inView=self:WorldToTacticalMapIn(signature.pos,mapRect,mapView,mapHalf)
        if inView then gr.setColor(signatureColour[1],signatureColour[2],signatureColour[3],255); gr.drawCircle(math.max(4,math.floor(5*markerScale)),sx,sy,false) end
    end
    local cx,cy=self:WorldToTacticalMap(self.CameraFocus); gr.setColor(255,230,90,255); gr.drawCircle(math.max(6,math.floor(6*m.scale)),cx,cy,false)
    self:DrawOrderPing()
    self:DrawStationMapOverlay()
    if self.MapDrag then local left=clamp(math.min(self.MapDrag.x1,self.MapDrag.x2),x1,x2); local right=clamp(math.max(self.MapDrag.x1,self.MapDrag.x2),x1,x2); local top=clamp(math.min(self.MapDrag.y1,self.MapDrag.y2),y1,y2); local bottom=clamp(math.max(self.MapDrag.y1,self.MapDrag.y2),y1,y2); gr.setColor(90,220,255,230); gr.drawRectangle(left,top,right,bottom,false) end
    if hintBand>0 then
        gr.setColor(3,8,13,bgAlpha); gr.drawRectangle(x1,contentBottom,x2,y2,true)
        gr.setColor(135,175,190,255)
        self:DrawTextLine("LMB select | RMB order | Wheel zoom",x1+m.pad(6),contentBottom+math.floor((hintBand-lh)/2),(x2-m.pad(6))-(x1+m.pad(6)))
    end
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
    button("pop",v.popped and "DOCK" or "POP OUT",widths.pop); button("fit","FIT",widths.fit); button("zoomOut","-",widths.zoomOut); button("zoomIn","+",widths.zoomIn)
    gr.setColor(200,225,235,255); gr.drawString(string.format("x%.1f",v.zoom),rect.x1+m.pad(6),rect.y1+m.pad(6))
    if v.popped then
        local f=self:GetTacticalMapFrame()
        gr.setColor(10,30,45,math.max(160,math.floor(255*v.alpha))); gr.drawRectangle(f.x1,f.y1,f.x2,rect.y1,true); gr.setColor(100,190,220,255); gr.drawRectangle(f.x1,f.y1,f.x2,f.y2,false)
        gr.setColor(220,238,245,255); self:DrawTextLine(self.ShowHotkeyHints==false and 'TACTICAL MAP' or "TACTICAL MAP  (drag to move)",f.x1+m.pad(8),f.y1+math.max(2,math.floor((m.mapHeader-lh)/2)),math.floor((f.x2-f.x1)*0.4))
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
