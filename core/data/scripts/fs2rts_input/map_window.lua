-- Map window chrome, drag and hit tests.
local _shared = require "fs2rts_input.common"
local RTS, clamp, shipValid, distance2, tableContainsSignature = _shared.RTS, _shared.clamp, _shared.shipValid, _shared.distance2, _shared.tableContainsSignature

-- Map window buttons, header drag, resize grip and opacity slider.
-- Returns true when the press was consumed.
function RTS:HandleMapUIPress(x, y)
    local v=self:GetMapView(); local b=self.MapButtonRects or {}
    if b.zoomIn and self:PointInside(b.zoomIn,x,y) then self:SetMapZoom(v.zoom*1.5); return true end
    if b.zoomOut and self:PointInside(b.zoomOut,x,y) then self:SetMapZoom(v.zoom/1.5); return true end
    if b.fit and self:PointInside(b.fit,x,y) then v.zoom=1; v.cx=0; v.cz=0; return true end
    if b.pop and self:PointInside(b.pop,x,y) then v.popped=not v.popped; self:ClampMapWindow(); return true end
    if not v.popped then return false end
    if b.slider and self:PointInside(b.slider,x,y) then self.MapWindowDrag={kind="alpha"}; self:UpdateMapWindowDrag(x,y); return true end
    if b.grip and self:PointInside(b.grip,x,y) then self.MapWindowDrag={kind="resize",x=x,y=y,w=v.w,h=v.h}; return true end
    if y>=v.y and y<v.y+self:GetMapHeaderHeight() and x>=v.x and x<=v.x+v.w then self.MapWindowDrag={kind="move",x=x,y=y,ox=v.x,oy=v.y}; return true end
    return false
end

function RTS:UpdateMapWindowDrag(x, y)
    local d=self.MapWindowDrag; if d==nil then return end; local v=self:GetMapView()
    if d.kind=="move" then v.x=d.ox+(x-d.x); v.y=d.oy+(y-d.y)
    elseif d.kind=="resize" then v.w=d.w+(x-d.x); v.h=d.h+(y-d.y)
    elseif d.kind=="alpha" then local s=self.MapButtonRects.slider; v.alpha=clamp((x-s.x1)/math.max(1,s.x2-s.x1),0.15,1) end
    self:ClampMapWindow()
end

function RTS:ClampMapWindow()
    local v=self:GetMapView(); local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
    local m=self:GetUIMetrics(sw,sh)
    -- A popped-out window has to stay big enough for its own header buttons, so
    -- the floor is the measured width of that button row rather than a guess.
    local minW=math.max(280,m.mapChromeWidth+m.pad(20)); local minH=math.max(200,m.mapHeader+120)
    v.w=clamp(v.w,minW,math.max(minW,sw-m.margin*2)); v.h=clamp(v.h,minH,math.max(minH,sh-m.margin*2))
    v.x=clamp(v.x,m.margin,math.max(m.margin,sw-m.margin-v.w)); v.y=clamp(v.y,m.margin,math.max(m.margin,sh-m.margin-v.h))
end

-- The one predicate the tactical map uses to decide what a click or a drag can
-- pick.
--
-- There were three, and they did not agree. SelectMapClick took
-- IsFriendly OR IsPlayerEnemy, GetMapShipAt took the same set but expressed as
-- a raw observer-name compare, and SelectMapBox took IsFriendly only. The
-- player-visible consequence is that clicking an enemy raider on the map put
-- it in the selection and the identical drag one pixel over refused to, and
-- dragging a box over a Vasudan (third-faction) contact silently selected
-- nothing. Click and drag now ask the same question, so they cannot disagree
-- about what is hostile.
--
-- Note this makes the map's box select include hostiles, which the WORLD box
-- select still does not. That asymmetry is deliberate and is called out in the
-- report: the world drag is a fleet gesture matched to SelectAll, whereas a
-- map click already selected hostiles so the player could right-click them for
-- an order. Widening the world drag would put hostile hulls into a move
-- gesture's selection.
function RTS:IsMapSelectableTarget(ship)
    if not shipValid(ship) or ship.Name == self.Config.ObserverShip then return false end
    if self:IsFriendly(ship) then return true end
    return self:IsPlayerEnemy(ship)
end

function RTS:SelectMapClick(mouseX, mouseY)
    local best = nil
    local bestScore = math.huge
    local pick = self.Config.TacticalMap.PickRadiusPixels or 10
    local view = self:GetMapView()
    local rect = self:GetTacticalMapRect()
    local half = self:GetTacticalMapHalfExtent()
    self:EachShip(function(ship)
        if self:IsMapSelectableTarget(ship) then
            local sx, sy, inView = self:WorldToTacticalMapIn(ship.Position, rect, view, half)
            local score = distance2(mouseX, mouseY, sx, sy)
            if inView and score <= pick * pick and score < bestScore then best, bestScore = ship, score end
        end
    end)
    if not shipValid(best) then
        -- An empty map click clears the selection. It used to clear Selected
        -- but leave PrimarySelectionSignature pointing at whatever was
        -- selected a moment ago, so every downstream "the primary ship" read
        -- - the order the last clicked ship was given, the detail card, the
        -- station panel - acted on a ship the player had just deselected.
        if not self.ShiftDown then self.Selected = {}; self.PrimarySelectionSignature = nil end
        return
    end
    local sig = best:getSignature()
    if self.ShiftDown then
        if tableContainsSignature(self.Selected, sig) then
            local result = {}
            for _, current in ipairs(self.Selected) do if current ~= sig then result[#result + 1] = current end end
            self.Selected = result
        else
            self.Selected[#self.Selected + 1] = sig
        end
    else
        self.Selected = { sig }
    end
    -- SelectMapBox has always published this; a map click did not, so a ship
    -- picked off the map never became the primary and the detail card and the
    -- station panel showed the previous selection.
    if self.PrimarySelectionSignature ~= nil and not tableContainsSignature(self.Selected, self.PrimarySelectionSignature) then
        self.PrimarySelectionSignature = nil
    end
    self.PrimarySelectionSignature = self.Selected[1]
end

function RTS:SelectMapBox(x1, y1, x2, y2)
    local rect = self:GetTacticalMapRect()
    local left = clamp(math.min(x1, x2), rect.x1, rect.x2)
    local right = clamp(math.max(x1, x2), rect.x1, rect.x2)
    local top = clamp(math.min(y1, y2), rect.y1, rect.y2)
    local bottom = clamp(math.max(y1, y2), rect.y1, rect.y2)
    local result = self.ShiftDown and self.Selected or {}
    local view = self:GetMapView()
    local half = self:GetTacticalMapHalfExtent()

    self:EachShip(function(ship)
        if self:IsMapSelectableTarget(ship) then
            local sx, sy, inView = self:WorldToTacticalMapIn(ship.Position, rect, view, half)
            if not inView then return end
            if sx >= left and sx <= right and sy >= top and sy <= bottom then
                local sig = ship:getSignature()
                if not tableContainsSignature(result, sig) then result[#result + 1] = sig end
            end
        end
    end)
    self.Selected = result; self.PrimarySelectionSignature=self.Selected[1]
end

function RTS:GetMapShipAt(mouseX, mouseY)
    local best, bestScore = nil, math.huge
    local pick = self.Config.TacticalMap.PickRadiusPixels or 10
    local view = self:GetMapView()
    local rect = self:GetTacticalMapRect()
    local half = self:GetTacticalMapHalfExtent()
    self:EachShip(function(ship)
        if self:IsMapSelectableTarget(ship) then
            local sx, sy, inView = self:WorldToTacticalMapIn(ship.Position, rect, view, half)
            local score = distance2(mouseX, mouseY, sx, sy)
            if inView and score <= pick * pick and score < bestScore then best, bestScore = ship, score end
        end
    end)
    return best
end
