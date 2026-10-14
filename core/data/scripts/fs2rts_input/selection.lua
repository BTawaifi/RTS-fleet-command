-- Map and world selection: click, box select and minimap.
local _shared = require "fs2rts_input.common"
local RTS, shipValid, copyVec, clamp, distance2, tableContainsSignature, PICK_GATE_ASPECT_SLACK = _shared.RTS, _shared.shipValid, _shared.copyVec, _shared.clamp, _shared.distance2, _shared.tableContainsSignature, _shared.PICK_GATE_ASPECT_SLACK

-- Minimap RMB mirrors the world RMB: hostile = attack, friendly = guard,
-- empty = move. With nothing selected it still jumps the camera.
function RTS:MapRightClick(x, y)
    if #self:GetSelectedFriendlyShips() == 0 then self:JumpCameraFromMap(x, y); return end
    local ship = self:GetMapShipAt(x, y)
    if shipValid(ship) and self:IsPlayerEnemy(ship) then self:IssueAttack(ship); self:SetOrderPing(ship.Position,"attack"); return end
    if shipValid(ship) and self:IsFriendly(ship) then self:IssueGuard(ship); self:SetOrderPing(ship.Position,"guard"); return end
    local target = self:TacticalMapToWorld(x, y)
    self:IssueMove(target); self:SetOrderPing(target,"move")
end

-- Short-lived map marker so a minimap order is visibly acknowledged.
function RTS:SetOrderPing(position, kind)
    -- A missing acknowledgement marker is cosmetic; a crash here kills the whole
    -- input handler on the player's own click. Same class as the copyVec(nil) in
    -- $On Waypoints Done. Callers pass ship.Position, a ScreenToPlane result or a
    -- raw focus vector, all of which can be absent on a degenerate pick.
    if position==nil or not self:IsFiniteVector(position) then return end
    local sigs={}; for _,s in ipairs(self:GetSelectedFriendlyShips()) do sigs[#sigs+1]=s:getSignature() end
    self.OrderPing={pos=copyVec(position),kind=kind,sigs=sigs,untilTime=self:UINow()+2}
end

function RTS:JumpCameraFromMap(x, y)
    if self.FollowSignature ~= nil then self:ExitFollowMode() end
    local world = self:TacticalMapToWorld(x, y)
    self.CameraFocus = world
    gr.setCamera(self.Camera)
    self:UpdateCameraTransform()
    self:SetStatus("Tactical camera repositioned", 1.2)
end

-- Cost order in this loop is the whole point of the function, because it runs
-- over every ship in the world on every click, every right-button press and
-- every frame of hover.
--
--   1. the observer's NAME          - one property read
--   2. the team                     - was being resolved up to THREE times per
--                                    ship, because IsFriendly, IsHostile and
--                                    IsThirdFaction each re-derive teamName,
--                                    and teamName is four reads (isValid,
--                                    getBreedName, Team.Name, string.lower)
--   3. the tangent-space gate       - about a dozen flops, no engine call
--   4. the cached projection        - free for a ship already seen this epoch
--   5. "cannot be further than the widest radius in play" - one subtraction
--   6. only then getDistance and Class.Model.Radius, the two expensive reads
--
-- Steps 5 and 6 are the reorder: the exact pick radius depends on the hull's
-- own model radius and its distance from the camera, and both were read for
-- every ship in the world before anything had established that the ship could
-- be within reach at all.
-- projectAge is the projection tolerance in EPOCHS and defaults to 0, meaning
-- "from this epoch", which is what every click path needs: the ship a click
-- selects must be the ship the player is looking at. The only caller that
-- passes anything else is the hover readout, which is an inspection aid drawn
-- over a contact the reticle pass has normally already projected this frame,
-- and a one-frame-old position is exactly as good there.
function RTS:GetShipAtScreen(mouseX, mouseY, includeFriendly, includeEnemies, hoverPick, projectAge)
    local best = nil
    local bestScore = math.huge
    local screenH = math.max(1, gr.getScreenHeight())
    local screenW = math.max(1, gr.getScreenWidth())
    local sel = self.Config.Selection or {}
    local activeCamera = self.Camera
    if self.FollowSignature ~= nil and self.FollowCamera ~= nil then activeCamera = self.FollowCamera end
    local baseRadius = sel.BasePickRadiusPixels or 20

    -- The widest radius any of the per-ship rules below can produce. Used for
    -- the gate and for the cheap range test; the exact radius is only derived
    -- for a ship that has already passed both.
    local reach = sel.MaxPickRadiusPixels or 110
    if hoverPick then
        local capital = sel.CapitalHoverPickRadiusPixels or 280
        if capital > reach then reach = capital end
    end
    local reachSquared = reach * reach
    local gate = self:BuildPickGate(mouseX, mouseY, screenW, screenH, reach)

    local observer = self.Config.ObserverShip
    local cameraPosition = activeCamera ~= nil and activeCamera.Position or nil

    self:EachShip(function(ship)
        if ship.Name == observer then return end
        local kind=self:GetFactionKey(ship)
        local allowed = false
        if includeFriendly and kind=="BLUE" then allowed = true end
        if not allowed and includeEnemies and kind~=nil and kind~="BLUE" then allowed = true end
        if not allowed then return end
        local position = ship.Position
        if position == nil then return end
        if gate ~= nil and not self:PassesScreenGate(gate, position) then return end
        local sx, sy = self:ProjectShip(ship, projectAge or 0)
        if sx == false then return end

        local score = distance2(mouseX, mouseY, sx, sy)
        if score > reachSquared then return end

        local radius = baseRadius
        if cameraPosition ~= nil then
            local dist = position:getDistance(cameraPosition)
            local modelRadius = 30
            if ship.Class and ship.Class.Model then modelRadius = ship.Class.Model.Radius end
            -- Keep click/selection tolerance unchanged; broad hull picking is
            -- only for passive hover inspection of capital-sized targets.
            local maxPickRadius = sel.MaxPickRadiusPixels
            if hoverPick and self:IsCapitalTarget(ship) then
                maxPickRadius = math.max(maxPickRadius, sel.CapitalHoverPickRadiusPixels or 280)
            end
            radius = clamp((modelRadius / math.max(dist, 1)) * screenH * 1.35, baseRadius, maxPickRadius)
        end
        if score <= radius * radius and score < bestScore then
            best = ship
            bestScore = score
        end
    end)
    return best
end

function RTS:SelectClick(mouseX, mouseY)
    local ship=self:GetShipAtScreen(mouseX,mouseY,true,true)
    if ship==nil then if not self.ShiftDown then self.Selected={}; self.PrimarySelectionSignature=nil end; return end
    if self.CtrlDown then self:SelectSameClass(ship,true); self.PrimarySelectionSignature=ship:getSignature(); return end
    local sig=ship:getSignature()
    if self.ShiftDown then
        if tableContainsSignature(self.Selected,sig) then
            local n={}; for _,v in ipairs(self.Selected) do if v~=sig then n[#n+1]=v end end; self.Selected=n
            if self.PrimarySelectionSignature==sig then self.PrimarySelectionSignature=self.Selected[1] end
        else self.Selected[#self.Selected+1]=sig; self.PrimarySelectionSignature=sig end
    else self.Selected={sig}; self.PrimarySelectionSignature=sig end
end

function RTS:SelectBox(x1, y1, x2, y2)
    local left = math.min(x1, x2)
    local right = math.max(x1, x2)
    local top = math.min(y1, y2)
    local bottom = math.max(y1, y2)
    local result = self.ShiftDown and self.Selected or {}
    local sw = math.max(1, gr.getScreenWidth())
    local sh = math.max(1, gr.getScreenHeight())
    -- Reject a ship that cannot land inside the rubber band before it costs a
    -- projection. The exact box test still runs after the projection, so this
    -- can only ever be a superset.
    local gate = self:BuildScreenGate(sw, sh, (left + right) * 0.5, (top + bottom) * 0.5,
        (right - left) * 0.5, (bottom - top) * 0.5, PICK_GATE_ASPECT_SLACK)

    self:EachShip(function(ship)
        -- Command stations are selected by click only; a rubber band over the base
        -- must not pull it into the selection with the ships.
        if self:IsFriendly(ship) and not self:IsCommandStation(ship) then
            local position = ship.Position
            if position ~= nil and (gate == nil or self:PassesScreenGate(gate, position)) then
                local sx, sy = self:ProjectShip(ship, 0)
                if sx ~= false and sx >= left and sx <= right and sy >= top and sy <= bottom then
                    local sig = ship:getSignature()
                    if not tableContainsSignature(result, sig) then result[#result + 1] = sig end
                end
            end
        end
    end)
    self.Selected = result; self.PrimarySelectionSignature=self.Selected[1]
end

function RTS:PointInside(rect, x, y)
    return rect ~= nil and x >= rect.x1 and x <= rect.x2 and y >= rect.y1 and y <= rect.y2
end

function RTS:GetPolicyPanelRect(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    local x2 = m.sw - m.margin
    local x1 = x2 - m.rightPanelWidth
    local y2 = m.sh - m.margin
    local y1 = y2 - m.policyHeight
    return { x1=x1, y1=y1, x2=x2, y2=y2 }
end

function RTS:GetOptionsPanelRect(sw, sh)
    local policy = self:GetPolicyPanelRect(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    return { x1=policy.x1, y1=policy.y1-m.gap-m.optionsHeight, x2=policy.x2, y2=policy.y1-m.gap }
end

-- Vertical budget the production panel has, in pixels: the band between the
-- bottom of the docked map and the top of the quick-group strip.
function RTS:GetProductionPanelRect(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    local mapRect = self:GetDockedMapRect()
    local x1, x2 = m.sw - m.margin - m.rightPanelWidth, m.sw - m.margin
    local y1 = mapRect.y2 + m.gap
    if self.PanelTab=='history' then
        local inset=2*m.panelPadding+28
        local wanted=inset+self:GetLiveHistoryPanelHeight(#self:GetLiveHistoryRecords(),m.sh-m.margin-y1-inset)
        return {x1=x1,y1=y1,x2=x2,y2=math.min(m.sh-m.margin,y1+wanted)}
    end
    if self.PanelTab == "station" then
        -- The station tab is laid out in its own fixed pixels (fs2rts_station.lua
        -- is not one of the files that may be rescaled) and needs 276px of
        -- content inside the 36/76 band insets DrawBuildPanel hands it, so the
        -- panel is sized to that requirement rather than to the column's slack.
        -- Quick groups, options and policy are not drawn while this tab is up,
        -- so the station panel is free to use the whole column.
        local wanted = clamp(m.pad(430), m.pad(388), m.pad(388) + m.pad(120))
        return { x1=x1, y1=y1, x2=x2, y2=y1 + wanted }
    end
    return { x1=x1, y1=y1, x2=x2, y2=y1 + m.productionHeight }
end

function RTS:GetQuickGroupPanelRect(sw,sh)
    local m=self:GetUIMetrics(sw,sh)
    local prod=self:GetProductionPanelRect(sw,sh)
    if not m.quickGroupsVisible then
        return { x1=prod.x1, y1=prod.y2, x2=prod.x2, y2=prod.y2 }
    end
    return { x1=prod.x1, y1=prod.y2+m.gap, x2=prod.x2, y2=prod.y2+m.gap+m.quickGroupHeight }
end

-- How many build rows the production panel can actually draw. Counted from the
-- same geometry the drawing loop uses; the old version computed a page size
-- from (height-142)/50 while the loop tested against (y2-74) with a 50px pitch,
-- and those two constants did not agree, which is how a 768p screen ended up
-- with a page size of one and a loop that broke before drawing even that.
function RTS:CountBuildRows(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    local rect = self:GetProductionPanelRect(sw, sh)
    local y = rect.y1 + m.buildNavTop + m.buildFirstRowOffset
    local limit = rect.y2 - m.buildFooter
    local rows = 0
    while y + m.buildRowHeight <= limit do
        rows = rows + 1
        y = y + m.buildRowPitch
        if rows >= 8 then break end
    end
    return math.max(1, rows)
end
