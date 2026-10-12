-- HUD world overlays: reticle decoration grid, selected groups, per-frame world pass.
local _shared = require "fs2rts_hud.common"
local RTS, shipValid, RETICLE_COLOR_SELECTED, RETICLE_COLOR_HOVERED = _shared.RTS, _shared.shipValid, _shared.RETICLE_COLOR_SELECTED, _shared.RETICLE_COLOR_HOVERED

-- Effective weapon reach for a hull. Projectile range is capped by the weapon's
-- own lifetime. A capital carries everything in turrets, so turrets are scanned
-- too; a beam weapon with no projectile range contributes nothing rather than a
-- false zero.
-- Cull overlapping ambient hull bars. Type icons remain visible for every
-- on-screen contact, including dense fleets at maximum zoom-out.
-- A contact that
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

function RTS:DrawSelectedReticleGroups(contacts)
    local groups={}
    -- ponytail: this scan is bounded by the player's selected fleet. Use
    -- spatial bins if the supported selection grows to hundreds of hulls.
    for _,c in ipairs(contacts) do
        local half=c.size/2; local role=self:GetShipRole(c.ship)
        local key=(role=='fighter' or role=='bomber') and
            (tostring(self:GetFactionKey(c.ship))..'|'..c.ship.Class.Name) or false
        local group=nil
        if key then
            for _,g in ipairs(groups) do
                if g.key==key and c.x-half<=g.x2 and c.x+half>=g.x1 and c.y-half<=g.y2 and c.y+half>=g.y1 then group=g; break end
            end
        end
        if not group then
            group={key=key,ship=c.ship,worst=c.ship,count=0,x1=c.x-half,x2=c.x+half,y1=c.y-half,y2=c.y+half}
            groups[#groups+1]=group
        end
        group.count=group.count+1
        group.x1=math.min(group.x1,c.x-half); group.x2=math.max(group.x2,c.x+half)
        group.y1=math.min(group.y1,c.y-half); group.y2=math.max(group.y2,c.y+half)
        if c.ship.HitpointsLeft/math.max(1,c.ship.HitpointsMax)<group.worst.HitpointsLeft/math.max(1,group.worst.HitpointsMax) then group.worst=c.ship end
    end
    local m=self:GetUIMetrics()
    for _,g in ipairs(groups) do
        local size=math.max(g.x2-g.x1,g.y2-g.y1); local x,y=(g.x1+g.x2)/2,(g.y1+g.y2)/2
        local half=self:DrawReticle(g.ship,x,y,size,RETICLE_COLOR_SELECTED,'selected')
        self:DrawRoleMarker(g.ship,x-half,y-half,x+half,y+half)
        self:DrawHullBarForShip(g.worst,x-half,y-half,x+half,y+half)
        if g.count>1 then
            gr.setColor(255,235,90,255)
            self:DrawTextLine('x'..g.count,x-half+m.pad(18),y-half+m.pad(3),size-m.pad(22))
        end
    end
    return groups
end

-- Jump signature where a building hull will warp in: two rings in the player's colour,
-- pulsing so they read as an arrival rather than a fixed marker.
-- A spawn point three km out is often off screen and a 350 m ring at that range is a few
-- pixels, so the signature also gets a pixel marker: on screen where the point projects,
-- pinned to the edge (as contact markers are) where it does not.
function RTS:DrawBuildSignatures()
    local now=self:UINow()
    local colour=self:GetFactionColorTable('BLUE')
    local pulse=0.5+0.5*math.sin(now*3)
    local alpha=math.floor(120+100*pulse)
    local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
    local m=self:GetUIMetrics(sw,sh)
    local view=self:GetContactViewport(sw,sh,m)
    local margin=(self.Config.Selection or {}).ReticleEdgeClampMargin or 26
    local radius=math.max(5,math.floor(7*m.scale))+math.floor(2*pulse)
    local drawn=0
    for _,signature in ipairs(self:GetBuildSignatures(now)) do
        local pos=signature.pos
        self:DrawWorldRangeRing(pos,350,colour,alpha)
        local sx,sy=pos:getScreenCoords()
        local ox,oy
        if sx~=false and sx>=view.x1 and sx<=view.x2 and sy>=view.y1 and sy<=view.y2 then
            ox,oy=sx,sy
        else
            local dx,dy=self:GetEdgeContactDirection({Position=pos})
            if dx~=nil and not (dx==0 and dy==0) then
                ox,oy=self:ResolveEdgeMarkerPoint(dx,dy,sw,sh,margin,m,view)
            end
        end
        if ox~=nil then
            gr.setColor(colour[1],colour[2],colour[3],alpha)
            gr.drawCircle(radius,ox,oy,false)
            drawn=drawn+1
        end
    end
    return drawn
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
    -- thing marking that the ship exists). Every on-screen contact keeps its
    -- role marker; only hull bars yield to density culling.
    self:RecycleMarkerPoints(self.EdgeMarkerPoints)
    self.EdgeMarkerPoints={}
    self:ResetDecorationGrid()
    -- After the edge-marker list is reset, so the signature claims its border slot first.
    self:DrawBuildSignatures()

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
    local selectedContacts={}
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
            self:DrawEdgeContactMarker(ship,sx,sy,self:GetReticleFactionColor(ship),sw,sh)
            return
        end
        local size=self:GetReticlePixelSize(ship)
        if selected then size=math.max(size,(sel.SelectedBracketPadding or 18)*2) end
        if hovered then size=size+8 end
        local colour=selected and RETICLE_COLOR_SELECTED or (hovered and RETICLE_COLOR_HOVERED or self:GetReticleFactionColor(ship))
        if selected and self:IsFriendly(ship) then
            selectedContacts[#selectedContacts+1]={ship=ship,x=sx,y=sy,size=size}
            return
        end
        local half=self:DrawReticle(ship,sx,sy,size,colour,selected and "selected" or nil)
        self:DrawRoleMarker(ship,sx-half,sy-half,sx+half,sy+half)
        if self:ShouldDecorateReticle(sx,sy,half,selected or hovered) then
            self:DrawHullBarForShip(ship,sx-half,sy-half,sx+half,sy+half)
        end
    end)
    self:DrawSelectedReticleGroups(selectedContacts)
    local mx,my=io.getMouseX(),io.getMouseY()
    -- The hover pick is the only picking caller that is not resolving a click,
    -- so it is the only one allowed to accept a projection a frame old. The
    -- reticle pass above has already projected every contact on screen, and
    -- this pick cone reaches 304px past the cursor, so being strict here made
    -- the mod re-project most of the visible fleet a second time every frame
    -- purely to draw an inspection tooltip.
    local hovered=not self:IsPointOnRTSUI(mx,my) and self:GetShipAtScreen(mx,my,true,true,true,1) or nil
    if shipValid(hovered) then
        -- The hover pick already projected this hull, and the reticle pass
        -- above drew its bracket from the same answer, so the readout and the
        -- bracket can no longer disagree about where the ship is.
        local sx,sy=self:ProjectShip(hovered,0)
        if sx~=false then
            if self:IsFriendly(hovered) and sel.ShowWeaponRange~=false then
                local ranges=self:GetShipWeaponRanges(hovered)
                if ranges.primary>0 then self:DrawWorldRangeRing(hovered.Position,ranges.primary,{80,220,255},sel.WeaponRangeAlpha or 90,sx,sy) end
                if ranges.secondary>0 then self:DrawWorldRangeRing(hovered.Position,ranges.secondary,{255,190,75},sel.WeaponRangeAlpha or 90,sx,sy) end
                if ranges.beam>0 then self:DrawWorldRangeRing(hovered.Position,ranges.beam,{205,140,255},sel.WeaponRangeAlpha or 90,sx,sy) end
            end
            local order=(self:IsFriendly(hovered) and self.UserOrders and self.UserOrders[hovered:getSignature()]) or nil
            if order~=nil and order.kind=="move" and self:IsFiniteVector(order.destination) then
                local dx,dy=order.destination:getScreenCoords()
                if dx~=false then
                    gr.setColor(120,255,200,220); gr.drawLine(sx,sy,dx,dy)
                    gr.setColor(120,255,200,255); gr.drawCircle(9,dx,dy,false)
                end
                if dx~=false and order.facing~=nil and self:IsFiniteVector(order.facing) then
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
