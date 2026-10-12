-- Station placement and strike overlays.
local _shared = require "fs2rts_station.common"
local RTS, vec, shipValid, clamp = _shared.RTS, _shared.vec, _shared.shipValid, _shared.clamp

-- 65 unit offsets for the overlay rings, and one scratch vector, both built on
-- first use. The ring used to build 65 l_Vector handles and recompute 65 sets
-- of trig for every ring on every frame - DrawStationMapOverlay runs per frame
-- and there is one ring for the armed sentry plus one per pending strike.
local RING_OFFSETS, RING_SCRATCH

local function ringPoint(pos, radius, index)
    local offsets = RING_OFFSETS
    if offsets == nil then
        offsets = {}
        for i = 0, 64 do
            local angle = i * math.pi / 32
            offsets[i] = { math.cos(angle), math.sin(angle) }
        end
        RING_OFFSETS = offsets
        RING_SCRATCH = vec(0, 0, 0)
    end
    local unit = offsets[index]
    -- l_Vector exposes its components as a writable indexer
    -- (vecmath.cpp:358-388), so one handle serves all 65 sample points.
    RING_SCRATCH.x = pos.x + unit[1] * radius
    RING_SCRATCH.y = pos.y
    RING_SCRATCH.z = pos.z + unit[2] * radius
    return RING_SCRATCH
end

-- Map overlay: station radius while placing, strike rings and pending strikes.
function RTS:DrawStationMapOverlay()
    local function ring(pos, radius, r, g, b)
        -- Project the circumference instead of a clamped center/radius. This
        -- respects map zoom, non-square maps and the map's drawing bounds.
        gr.setColor(r, g, b, 200)
        local px,py,inside
        for i=0,64 do
            local x,y,visible=self:WorldToTacticalMap(ringPoint(pos, radius, i))
            if inside and visible then gr.drawLine(px,py,x,y) end
            px,py,inside=x,y,visible
        end
    end
    local station = self:GetCarrier()
    if self.ArmedCommand == "sentry" and shipValid(station) then
        local r,g,b=self:GetFactionColor("BLUE")
        ring(station.Position,self:GetSentryRadius("BLUE"),r,g,b)
    end
    for _,job in ipairs(self.PendingSentries or {}) do
        if job.kind=="BLUE" then
            local x,y,visible=self:WorldToTacticalMap(job.pos)
            if visible then gr.setColor(255,190,70,230); gr.drawCircle(8,x,y,false); self:DrawCenteredText("BUILD "..math.max(0,math.ceil(job.finishAt-mn.getMissionTime())),x-45,x+45,y+10) end
        end
    end
    for _, strike in ipairs(self.PendingStrikes or {}) do ring(strike.pos, strike.radius, 255, 70, 70) end
end

function RTS:DrawStationPlacementOverlay()
    if self.ArmedCommand~="sentry" or self.PossessedSignature~=nil then return end
    local station=self:GetCarrier()
    if not shipValid(station) then return end
    local function worldRing(pos,radius,r,g,b,a)
        gr.setColor(r,g,b,a)
        local px,py
        for i=0,64 do
            local x,y=ringPoint(pos,radius,i):getScreenCoords()
            if x~=false then
                if px~=nil then gr.drawLine(px,py,x,y) end
                px,py=x,y
            else px,py=nil,nil end
        end
    end
    local r,g,b=self:GetFactionColor("BLUE")
    worldRing(station.Position,self:GetSentryRadius("BLUE"),r,g,b,210)

    local option=self:GetSentryOptions("BLUE")[self.ArmedSentryIndex or 1]
    local pos=self:ScreenToPlane(io.getMouseX(),io.getMouseY(),station.Position.y)
    if pos==nil then return end
    local reason="No sentry selected"
    if option then reason=self:CheckSentrySpot("BLUE",pos,nil,option) end
    local cls=option and tb.ShipClasses[option.class]
    local radius=math.max(50,cls and cls.Model and cls.Model.Radius or 0)
    local valid=reason==nil
    worldRing(pos,radius,valid and 90 or 255,valid and 255 or 75,valid and 150 or 75,235)
    local x,y=pos:getScreenCoords()
    if x~=false then
        local tr,tg,tb2=valid and 120 or 255,valid and 255 or 90,valid and 175 or 90
        gr.setColor(tr,tg,tb2,255)
        gr.drawCircle(6,x,y,false)
        -- The readout is wrapped to a pixel budget, not truncated: "Too close to your
        -- station" was cut to "TOO CLOSE TO YOUR ST...". It is queued so the control
        -- hint panel cannot paint over it.
        local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
        local m=self:GetUIMetrics(sw,sh)
        local textW=math.min(m.pad(300),sw-16)
        local lines=self:WrapTextLinesToWidth(valid and "PLACE SENTRY" or reason,textW-12,2)
        local lh=m.lineHeight
        local left=clamp(x+12,8,math.max(8,sw-textW-8))
        local top=clamp(y+12,48,math.max(48,sh-#lines*lh-12))
        self:QueueTopLayer(function()
            gr.setColor(4,10,18,225); gr.drawRectangle(left-6,top-4,left+textW+6,top+#lines*lh+2,true)
            gr.setColor(tr,tg,tb2,255)
            for i,line in ipairs(lines) do gr.drawString(line,left,top+(i-1)*lh) end
        end)
    end
end

-- World overlay: pulsing warning over pending strikes.
function RTS:DrawStrikeWarnings()
    self:DrawStationPlacementOverlay()
    local now = mn.getMissionTime()
    for _, strike in ipairs(self.PendingStrikes or {}) do
        local sx, sy = strike.pos:getScreenCoords()
        if sx then
            local pulse = 18 + (now * 40) % 30
            gr.setColor(255, 70, 70, 220); gr.drawCircle(pulse, sx, sy, false); gr.drawCircle(8, sx, sy, false)
            self:DrawCenteredText("STRIKE " .. math.max(0, math.ceil(strike.at - now)), sx - 60, sx + 60, sy + pulse + 4)
        end
    end
end
