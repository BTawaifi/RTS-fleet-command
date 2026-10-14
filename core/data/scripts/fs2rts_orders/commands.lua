-- Order reissue and selected-ship commands.
local _shared = require "fs2rts_orders.common"
local RTS, shipAlive, shipValid, copyVec = _shared.RTS, _shared.shipAlive, _shared.shipValid, _shared.copyVec

function RTS:ReissueUserOrder(ship, order)
    if not self:IsFriendly(ship) or order == nil then return false end
    if self.FleetServices and self.FleetServices[ship:getSignature()] then return false end
    self:SetShipCommandDiscipline(ship,order.kind=='move' or order.kind=='hold')
    if order.kind~='move' then self:SetShipTurretLock(ship,false) end
    if order.kind == "hold" then
        self:HoldShip(ship, 0.95)
        return true
    elseif order.kind == "engage" then
        self:EngageShip(ship, 0.95)
        return true
    elseif order.kind == "move" and order.destination ~= nil then
        return self:MoveShipTo(ship, order.destination, 0.95)
    elseif order.kind == 'wing' then
        local pilot=self:FindShipBySignature(self.PossessedSignature)
        if shipAlive(pilot) then
            ship:clearOrders()
            return ship:giveOrder(ORDER_GUARD,pilot,nil,.95)==true
        end
    elseif (order.kind == "attack" or order.kind == "guard" or order.kind == "attack_wing") and order.targetSignature ~= nil then
        local target = order.kind=="attack_wing" and self:ResolveAttackWingTarget(order) or self:FindShipBySignature(order.targetSignature)
        if shipValid(target) then
            if order.kind=="attack_wing" then order.targetSignature=target:getSignature() end
            if (order.kind == "attack" or order.kind=="attack_wing") and not self:AreEnemies(ship,target) then
                self:ClearUserOrder(ship)
                self:ReturnToDefaultControl(ship)
                return false
            end
            ship:clearOrders()
            if order.kind == "attack" or order.kind=="attack_wing" then
                if self:IsPursuitPair(ship,target,nil,true) then
                    return self:IssuePursuitOrder(ship,target,0.95)
                end
                self:DropPursuit(ship:getSignature())
                return ship:giveOrder(ORDER_ATTACK,target,nil,0.95)==true
            end
            self:DropPursuit(ship:getSignature())
            return ship:giveOrder(ORDER_GUARD,target,nil,0.95)==true
        end
    end

    self:ClearUserOrder(ship)
    self:ReturnToDefaultControl(ship)
    return false
end

-- no-dynamic prevents native hit diversions. Also repair goals removed by
-- another engine/script callback while a player move still owns the ship.
function RTS:ReconcileMoveOrders(now)
    if self.SetupActive or self.PostBattleActive then return end
    if now<(self.NextMoveReconcile or 0) then return end
    self.NextMoveReconcile=now+.5
    -- getSignature() on an invalid handle raises, so guard it the way
    -- GetNativeObjectiveStatus does rather than trusting the order entry.
    local function sigOf(handle)
        if handle==nil then return nil end
        local ok,value=pcall(function() return handle:getSignature() end)
        if ok and type(value)=="number" then return value end
        return nil
    end
    for sig,order in pairs(self.UserOrders or {}) do
        if order.kind=="move" and self:IsFiniteVector(order.destination) then
            local ship=self:FindShipBySignature(sig)
            if shipAlive(ship) and not (self.FleetServices and self.FleetServices[sig]) then
                local entry=self.MoveWaypoints[sig]
                local intact=false
                local orders=ship.Orders
                for i=1,#orders do
                    local o=orders[i]
                    if o~=nil then
                        local valid,kind=pcall(function() return o:isValid() and o:getType() or nil end)
                        if valid and kind==ORDER_WAYPOINTS_ONCE and entry~=nil
                            and sigOf(o.Target)==sigOf(entry.waypoint) then intact=true end
                    end
                end
                if not intact then
                    if self:ReissueUserOrder(ship,order) then
                        self:Log(string.format("Re-issued lost move order for %s (engine diverted the ship)",ship.Name))
                    end
                end
            end
        end
    end
end

function RTS:HoldSelected()
    local issued = 0
    for _, ship in ipairs(self:GetSelectedFriendlyShips()) do
        if not self:IsCommandStation(ship) then
            self:SetUserOrder(ship, { kind = "hold" })
            self:HoldShip(ship, 0.95)
            issued = issued + 1
        end
    end
    if issued > 0 then self:SetStatus("Hold position", 2) end
end

function RTS:EngageSelected()
    local issued = 0
    for _, ship in ipairs(self:GetSelectedFriendlyShips()) do
        if not self:IsCommandStation(ship) then
            self:SetUserOrder(ship, { kind = "engage" })
            self:EngageShip(ship, 0.95)
            issued = issued + 1
        end
    end
    if issued > 0 then self:SetStatus("Engage hostiles", 2) end
end

function RTS:IssueMove(target,facing)
    if target==nil or not self:IsFiniteVector(target) then return end
    local selected=self:GetSelectedFriendlyShips(); local ships={}
    for _,ship in ipairs(selected) do if self:IsMovableFriendly(ship) then ships[#ships+1]=ship end end
    if #ships==0 then
        if #selected>0 then self:SetStatus("Command stations are fixed installations and cannot move",2.5) end
        return
    end

    local safeTarget,clipped=self:ClampCommandPoint(target,0)
    if safeTarget==nil then self:SetStatus("Invalid movement point rejected",2.5); return end
    -- The drag defines a parallel heading, not a shared point every hull
    -- converges on. Compute it before clamping changes the group's centre.
    local heading=self:IsFiniteVector(facing) and (facing-target) or nil
    if heading and heading.x*heading.x+heading.z*heading.z<1 then heading=nil end
    local slots,refusal=self:BuildSafeFormationDestinations(ships,safeTarget,self:GetSelectedFormation(),heading and (safeTarget+heading) or nil)
    if refusal then self:SetStatus(refusal,2.5); return end
    local issued=0
    for _,slot in ipairs(slots) do
        -- Record the order only once the engine accepted it: a recorded move with
        -- no waypoint goal never completes, and policy skips ordered ships.
        if self:MoveShipTo(slot.ship,slot.destination,0.95) then
            -- Both a tap and a drag remain player-owned after arrival.
            local facingValue=heading and (slot.destination+heading) or nil
            self:SetUserOrder(slot.ship,{kind="move",destination=copyVec(slot.destination),facing=facingValue,heading=heading and copyVec(heading) or nil,manual=true})
            issued=issued+1
        end
    end
    if issued==0 then self:SetStatus("No valid movement orders issued",2.5); return end
    self.CommandMarker=copyVec(safeTarget); self.CommandMarkerUntil=self:UINow()+1.2
    self:SetStatus((clipped and "Move clamped to tactical area" or "Move formation").." // "..tostring(issued).." ships",1.8)
end
