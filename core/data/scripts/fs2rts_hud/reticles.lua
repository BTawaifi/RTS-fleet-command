-- HUD world reticles and role markers.
local _shared = require "fs2rts_hud.common"
local RTS, clamp, RETICLE_COLORS = _shared.RTS, _shared.clamp, _shared.RETICLE_COLORS

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
local function diamond(gr,cx,cy,rx,ry) -- one filled rotated square
    gr.drawRectangleCentered(cx,cy,rx*1.4142,ry*1.4142,true,math.rad(45))
end

local function triangle(gr,x,y,size)
    -- Five solid horizontal bands retain the simple triangle at map sizes.
    for i=0,4 do
        local width=math.max(1,math.floor(size*(i+1)/5))
        local left=x+math.floor((size-width)/2)
        gr.drawRectangle(left,y+math.floor(size*i/5),left+width,y+math.floor(size*(i+1)/5),true)
    end
end

local ROLE_MARKER_SHAPES={
    fighter=function(gr,px,py,size) -- triangle
        triangle(gr,px,py,size)
    end,
    bomber=function(gr,px,py,size) -- triangle over a separate base bar
        triangle(gr,px+math.floor(size*.175),py,math.floor(size*.65))
        gr.drawRectangle(px,py+math.floor(size*.8),px+size,py+size,true)
    end,
    escort=function(gr,px,py,size) -- filled lozenge
        diamond(gr,px+size*0.5,py+size*0.5,size*0.5,size*0.5)
    end,
    capital=function(gr,px,py,size) -- broad slab
        gr.drawRectangle(px,py+size*0.12,px+size,py+size*0.88,true)
    end,
    heavy=function(gr,px,py,size) -- two parallel slabs
        gr.drawRectangle(px,py,px+size,py+math.floor(size*.4),true)
        gr.drawRectangle(px,py+math.floor(size*.6),px+size,py+size,true)
    end,
    juggernaut=function(gr,px,py,size) -- three-pronged crown, distinct from capitals
        local width=math.max(1,math.floor(size/4))
        local mid=math.floor((size-width)/2)
        gr.drawRectangle(px,py+math.floor(size*.60),px+size,py+math.floor(size*.88),true)
        -- Integer gaps survive the engine's coordinate truncation at 8-12 px.
        for i=0,2 do
            local offset=i==0 and 0 or (i==1 and mid or size-width)
            gr.drawRectangle(px+offset,py+math.floor(size*.12),px+offset+width,py+math.floor(size*.60),true)
        end
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

-- module level: the fallback was a table literal inside the call, and
-- DrawRoleMarker runs for every decorated contact on every frame
local ROLE_MARKER_FALLBACK_COLOR={160,180,190}

function RTS:DrawShipRoleShape(role,x,y,size)
    local shape=ROLE_MARKER_SHAPES[role] or ROLE_MARKER_SHAPES.support
    shape(gr,x,y,size)
end

-- Both views use the same geometric silhouette; retail briefing sprites have
-- a different visual vocabulary and do not remain readable at these sizes.
function RTS:DrawShipTypeIcon(ship,x,y,size)
    local station=self:IsCommandStation(ship)
    local role=station and "station" or self:GetShipRole(ship)
    self:DrawShipRoleShape(role,x,y,size)
end

function RTS:DrawRoleMarker(ship,x1,y1,x2,y2)
    local size=self.Config.Selection.RoleMarkerSize or 11
    if not size or size<=0 then return end
    local m=self:GetUIMetrics()
    size=m.pad(size)
    local gap=m.pad(self.Config.Selection.RoleMarkerInset or 3)
    size=math.max(1,math.min(size,math.floor(x2-x1-2*gap),math.floor(y2-y1-2*gap)))
    local px=math.floor(x1+gap); local py=math.floor(y1+gap)
    local color=self:GetReticleFactionColor(ship)
    -- Faint dark plate first so the mark stays legible over bright ship models
    -- and over a selected unit's second, brighter bracket pass. The role
    -- colour is restored after the plate, or the glyph draws in plate grey.
    gr.setColor(8,14,20,150)
    gr.drawRectangle(px-2,py-2,px+size+2,py+size+2,true)
    gr.setColor(color[1],color[2],color[3],255)
    self:DrawShipTypeIcon(ship,px,py,size)
end

function RTS:GetReticleFactionKey(ship)
    local faction=self:GetFactionKey(ship)
    if faction=='BLUE' then return "friendly" elseif faction=='GOLD' then return "third" end
    return "hostile"
end

function RTS:GetReticleFactionColor(ship)
    local kind=self:GetFactionKey(ship)
    return kind and self:GetFactionColorTable(kind) or RETICLE_COLORS[self:GetReticleFactionKey(ship)] or ROLE_MARKER_FALLBACK_COLOR
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
    local m=self:GetUIMetrics()
    return clamp(size,m.pad(sel.ReticleMinPixels or 22),m.pad(sel.ReticleMaxPixels or 120))
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
