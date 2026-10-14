-- HUD off-screen contact markers and world range rings.
local _shared = require "fs2rts_hud.common"
local RTS, clamp, vec, rangeRingCameraKey, sameRangeRingKey = _shared.RTS, _shared.clamp, _shared.vec, _shared.rangeRingCameraKey, _shared.sameRangeRingKey

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
-- The 3D view between the left and right columns, below the top bar. Markers
-- pinned to the full screen edge landed on the side panels and the production
-- and selection controls.
function RTS:GetContactViewport(sw,sh,m)
    local x1=m.margin+m.selectionWidth+m.gap
    local x2=sw-m.margin-m.rightPanelWidth-m.gap
    if x2-x1<120 then x1,x2=0,sw end
    return {x1=x1,y1=m.topBarHeight,x2=x2,y2=sh-m.margin}
end

function RTS:DrawEdgeContactMarker(ship,sx,sy,colour,sw,sh)
    -- Our own command station is never marked; it is where the player works from.
    if self:IsFriendly(ship) and self:IsCommandStation(ship) then return end
    local sel=self.Config.Selection or {}
    local margin=sel.ReticleEdgeClampMargin or 26
    local m=self:GetUIMetrics(sw,sh)
    local view=self:GetContactViewport(sw,sh,m)
    local cx,cy=(view.x1+view.x2)/2,(view.y1+view.y2)/2
    local dx,dy
    if sx~=false and sy~=false then
        -- A contact whose projection landed inside the view is not an off-view
        -- contact and has nothing to be pinned for.
        if sx>=view.x1 and sy>=view.y1 and sx<=view.x2 and sy<=view.y2 then return end
        dx,dy=sx-cx,sy-cy
        if dx==0 and dy==0 then return end
    else
        dx,dy=self:GetEdgeContactDirection(ship)
    end
    if dx==nil or (dx==0 and dy==0) then return end
    local ex,ey=self:ResolveEdgeMarkerPoint(dx,dy,sw,sh,margin,m,view)
    -- A small filled square marks the bearing. No role letter: the colour is enough.
    local size=math.max(3,math.floor(3*m.scale))
    gr.setColor(colour[1],colour[2],colour[3],230)
    gr.drawRectangle(ex-size,ey-size,ex+size,ey+size,true)
end

-- Project the direction onto the border rectangle, then slide the point along
-- the border away from any marker already placed this frame.
function RTS:ResolveEdgeMarkerPoint(dx,dy,sw,sh,margin,m,view)
    view=view or {x1=0,y1=0,x2=sw,y2=sh}
    local cx,cy=(view.x1+view.x2)/2,(view.y1+view.y2)/2
    local halfW,halfH=(view.x2-view.x1)/2-margin,(view.y2-view.y1)/2-margin
    local scale=math.min(halfW/math.max(1,math.abs(dx)),halfH/math.max(1,math.abs(dy)))
    local ex=cx+dx*scale; local ey=cy+dy*scale
    local placed=self.EdgeMarkerPoints
    if placed==nil then return ex,ey end
    local size=math.max(7,math.floor(7*((m and m.scale) or 1)))
    local gap=size*1.8
    -- The frame's point list owns its index, so recycling the list also drops
    -- its cells. A size change rebuilds the exact overlap neighborhoods.
    local grid=placed.grid
    if not grid or grid.gap~=gap or grid.count>#placed then
        grid={gap=gap,count=0,cells={}}; placed.grid=grid
    end
    for i=grid.count+1,#placed do
        local point=placed[i]
        local x,y=math.floor(point.x/gap),math.floor(point.y/gap)
        local column=grid.cells[x]
        if not column then column={}; grid.cells[x]=column end
        local cell=column[y]
        if not cell then cell={}; column[y]=cell end
        cell[#cell+1]=point
    end
    grid.count=#placed
    -- Try progressively larger offsets perpendicular to the border until a free
    -- slot is found. Bounded so a dense contact list cannot spin.
    for attempt=0,8 do
        local offset=attempt*size*1.6
        local px,py=ex,ey
        if math.abs(ex-cx)>=math.abs(ey-cy) then
            -- On a vertical edge: slide vertically.
            py=ey+offset; if attempt>0 then py=ey-offset end
            py=clamp(py,view.y1+margin,view.y2-margin)
        else
            px=ex+offset; if attempt>0 then px=ex-offset end
            px=clamp(px,view.x1+margin,view.x2-margin)
        end
        local free=true
        local cellX,cellY=math.floor(px/gap),math.floor(py/gap)
        for x=cellX-1,cellX+1 do
            local column=grid.cells[x]
            if column then
                for y=cellY-1,cellY+1 do
                    local cell=column[y]
                    if cell then
                        for _,other in ipairs(cell) do
                            if math.abs(other.x-px)<gap and math.abs(other.y-py)<gap then free=false; break end
                        end
                    end
                    if not free then break end
                end
            end
            if not free then break end
        end
        if free then self:AddMarkerPoint(placed,px,py); return px,py end
    end
    self:AddMarkerPoint(placed,ex,ey)
    return ex,ey
end

-- Range-ring cache state lives beside its only user (DrawWorldRangeRing). It is
-- a mutable counter, so it must not be copied into a second module.
local RANGE_RING_CACHE={}

-- Covers 12 faction extraction rings plus the three weapon-range overlays.
local RANGE_RING_CACHE_LIMIT=16

local RANGE_RING_CACHE_CLOCK=0

-- Projected outline of a world circle on the command plane. Using two
-- perpendicular basis vectors keeps the ring an ellipse under an oblique
-- camera instead of a circle that is wrong on two axes.
function RTS:DrawWorldRangeRing(centre,range,colour,alpha,centreX,centreY)
    if centre==nil or not self:IsFiniteVector(centre) or not self:IsFiniteNumber(range) or range<=0 then return end
    -- The caller has already projected the ring's centre (it is the hull under
    -- the cursor, and the reticle pass projected it this epoch), so it is
    -- handed in rather than projected a second time.
    local ox,oy=centreX,centreY
    if ox==nil then ox,oy=centre:getScreenCoords() end
    if ox==false then return end
    local sel=self.Config.Selection or {}
    local segments=sel.WeaponRangeSegments or 48
    local cameraKey=rangeRingCameraKey(self,gr.getScreenWidth(),gr.getScreenHeight())
    local entry
    if cameraKey~=nil then
        for _,candidate in ipairs(RANGE_RING_CACHE) do
            if sameRangeRingKey(candidate,centre.x,centre.y,centre.z,range,segments,ox,oy,cameraKey) then
                entry=candidate; break
            end
        end
    end
    if entry==nil and cameraKey~=nil then
        local pointsX,pointsY={},{}
        local point=vec(centre.x,centre.y,centre.z)
        for i=0,segments do
            local a=(i/segments)*math.pi*2
            point.x=centre.x+math.cos(a)*range; point.y=centre.y; point.z=centre.z+math.sin(a)*range
            pointsX[i+1],pointsY[i+1]=point:getScreenCoords()
        end
        if #RANGE_RING_CACHE<RANGE_RING_CACHE_LIMIT then
            entry={}; RANGE_RING_CACHE[#RANGE_RING_CACHE+1]=entry
        else
            local oldest=1
            for i=2,#RANGE_RING_CACHE do if RANGE_RING_CACHE[i].lastUsed<RANGE_RING_CACHE[oldest].lastUsed then oldest=i end end
            entry=RANGE_RING_CACHE[oldest]
        end
        entry.cx,entry.cy,entry.cz=centre.x,centre.y,centre.z
        entry.range,entry.segments,entry.screenX,entry.screenY=range,segments,ox,oy
        entry.cameraKey=cameraKey; entry.pointsX,entry.pointsY=pointsX,pointsY
    end
    RANGE_RING_CACHE_CLOCK=RANGE_RING_CACHE_CLOCK+1
    if entry then entry.lastUsed=RANGE_RING_CACHE_CLOCK end
    gr.setColor(colour[1],colour[2],colour[3],alpha or sel.WeaponRangeAlpha or 90)
    local previousX,previousY
    for i=0,segments do
        local x,y
        if entry then x,y=entry.pointsX[i+1],entry.pointsY[i+1]
        else
            local a=(i/segments)*math.pi*2
            local point=centre+vec(math.cos(a)*range,0,math.sin(a)*range)
            x,y=point:getScreenCoords()
        end
        -- Project the real circle. A pixel cap shrank large ranges into false
        -- boundaries; affine offsets were also wrong under perspective.
        if x~=false and previousX~=nil then gr.drawLine(previousX,previousY,x,y) end
        previousX,previousY=x~=false and x or nil,y
    end
end
