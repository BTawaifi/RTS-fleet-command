-- Order issuing: move, attack and guard.
local _shared = require "fs2rts_orders.common"
local RTS, shipAlive, vec, copyVec = _shared.RTS, _shared.shipAlive, _shared.vec, _shared.copyVec

-- Native waypoints own transit steering. After OnWaypointsDone changes move
-- to hold, drive the requested heading and hand the settled pose back to the
-- hold goal. Keep the heading so later native drift can be corrected.
function RTS:UpdateMoveFacings()
    if self.SetupActive or self.PostBattleActive or self.PossessedSignature~=nil then return end
    for sig,order in pairs(self.UserOrders or {}) do
        if self.PossessedSignature~=sig and (order.kind=="move" or order.kind=="hold") and (self:IsFiniteVector(order.heading) or self:IsFiniteVector(order.facing)) then
            local ship=self:FindShipBySignature(sig)
            if not shipAlive(ship) or (order.kind=="move" and not self:IsFiniteVector(order.destination)) then
                order.facing=nil
                order.heading=nil
            elseif order.kind=="hold" then
                -- Aim at a point beyond the ship along the drag direction rather
                -- than at the facing point itself, so the hull actually turns.
                -- A hold carrying a facing is a ship that has ARRIVED and must
                -- keep the commanded heading, so it uses its current position
                -- as the origin. While travelling, native waypoint steering
                -- owns heading; forcing the final heading then fights transit.
                local ox,oz
                if order.kind=="hold" then ox,oz=ship.Position.x,ship.Position.z
                else ox,oz=order.destination.x,order.destination.z end
                local dx=order.heading and order.heading.x or (order.facing.x-ox)
                local dz=order.heading and order.heading.z or (order.facing.z-oz)
                local length=math.sqrt(dx*dx+dz*dz)
                if length>1 then
                    local nx,nz=dx/length,dz/length
                    if not order.heading then order.heading=vec(dx,0,dz) end
                    -- Only parse a facing SEXP while the hull is turning.
                    local fvec=nil
                    local ok=pcall(function() fvec=ship:getfvec(true) end)
                    if ok and fvec~=nil then
                        local dot=fvec.x*nx+fvec.z*nz
                        if dot>0.9995 then
                            order.facing=nil
                            if not order.facingSettled then
                                -- STAY_STILL snapshots a look-at point when it
                                -- is installed. Refresh that point after the
                                -- turn, or native AI turns back to the pre-turn
                                -- heading as soon as the SEXP stops running.
                                ship.Orientation=ba.createOrientationFromVectors(vec(nx,0,nz))
                                ship.Physics.RotationalVelocity=vec(0,0,0)
                                self:HoldShip(ship,.95); order.facingSettled=true
                            end
                        else
                            order.facingSettled=nil
                            local aim=vec(ship.Position.x+nx*10000,ship.Position.y,ship.Position.z+nz*10000)
                            mn.runSEXP(string.format('(set-object-facing "%s" %.1f %.1f %.1f 2200 1)',ship.Name,aim.x,aim.y,aim.z))
                        end
                    else
                        local aim=vec(ship.Position.x+nx*10000,ship.Position.y,ship.Position.z+nz*10000)
                        mn.runSEXP(string.format('(set-object-facing "%s" %.1f %.1f %.1f 2200 1)',ship.Name,aim.x,aim.y,aim.z))
                    end
                end
            end
        end
    end
end

function RTS:IssueAttack(target)
    local ships={}
    local skippedNonStrike=false
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do
        if self:IsMovableFriendly(ship) then
            if self:CanDamageCommandStation(ship,target) then ships[#ships+1]=ship else skippedNonStrike=true end
        end
    end
    if #ships==0 and skippedNonStrike then self:SetStatus("BASE STRIKE REQUIRES BOMBERS, ESCORTS OR CAPITALS",2); return end
    if #ships == 0 or not self:IsPlayerEnemy(target) then return end
    local targetSig = target:getSignature()
    local wing=self:GetLogicalWing(target)
    local wingMembers=0
    if wing~=nil then
        for _,sig in ipairs(wing.signatures or {}) do
            local member=self:FindShipBySignature(sig)
            if shipAlive(member) and self:IsPlayerEnemy(member) then wingMembers=wingMembers+1 end
        end
    end
    local orderKind=wingMembers>1 and "attack_wing" or "attack"
    local formation=#ships>1 and {id=self:GetSelectedFormation(),members={}} or nil
    if formation then for _,ship in ipairs(ships) do formation.members[#formation.members+1]=ship:getSignature() end end
    for _, ship in ipairs(ships) do
        self:SetUserOrder(ship, { kind = orderKind, targetSignature = targetSig, targetWing = orderKind=="attack_wing" and wing.id or nil,formation=formation })
        self:ReissueUserOrder(ship,self.UserOrders[ship:getSignature()])
    end
    if formation then self:UpdateAttackFormations(mn.getMissionTime(),true) end
    self:SetStatus((skippedNonStrike and "NON-STRIKE UNITS SKIPPED // " or "")..(orderKind=="attack_wing" and "Attack wing: " or "Attack: ") .. (wing and wing.label or target.Name), 2)
end

-- Keep the selected shape during approach, then hand close combat to native
-- attack steering. Each order owns its membership; retasking, service, death
-- and possession remove that member without a separate global group cache.
function RTS:UpdateAttackFormations(now,force)
    local processed={}
    for _,order in pairs(self.UserOrders or {}) do
        local group=order.formation
        if group and not processed[group] and (force or now>=(group.nextThink or 0)) then
            processed[group]=true
            group.nextThink=now+1
            local units={}; local centre=vec(0,0,0)
            for _,sig in ipairs(group.members) do
                local current=self.UserOrders[sig]; local ship=self:FindShipBySignature(sig)
                if current and current.formation==group and self.PossessedSignature~=sig and shipAlive(ship)
                    and self:IsMovableFriendly(ship) and not (self.FleetServices and self.FleetServices[sig]) then
                    units[#units+1]=ship; centre=centre+ship.Position
                end
            end
            local target=self:FindShipBySignature(order.targetSignature)
            if #units>0 and shipAlive(target) then
                centre=centre/#units
                local heading=target.Position-centre
                local length=heading:getDistance(vec(0,0,0))
                if length>1 then
                    -- A short shared lead retains cohesion without sending the
                    -- formation straight through a large target's hull.
                    local advance=math.min(2500,math.max(0,length-(target.Radius or 0)-800))
                    local point=centre+heading*(advance/length)
                    local slots=self:BuildSafeFormationDestinations(units,point,group.id,point+heading)
                    if slots then for _,slot in ipairs(slots) do
                        local ship=slot.ship; local current=self.UserOrders[ship:getSignature()]
                        local ranges=self:GetShipWeaponRanges(ship)
                        local reach=ranges.primary>0 and ranges.primary or math.max(ranges.beam,ranges.secondary,1000)
                        local distance=math.max(0,ship.Position:getDistance(target.Position)-(target.Radius or 0))
                        if distance>reach*1.15 and #units>1 then
                            if current.approaching then
                                self:ConfigureMoveWaypoints(ship,slot.destination)
                            elseif self:MoveShipTo(ship,slot.destination,.95) then
                                current.approaching=true
                                self:SetShipTurretLock(ship,false)
                            end
                            current.destination=copyVec(slot.destination)
                        elseif current.approaching then
                            current.approaching=nil; current.destination=nil
                            self:ReissueUserOrder(ship,current)
                        end
                    end end
                end
            end
        end
    end
end

function RTS:IssueGuard(target)
    local ships = self:GetSelectedFriendlyShips()
    if #ships == 0 or not self:IsFriendly(target) then return end
    local targetSig = target:getSignature()
    for _, ship in ipairs(ships) do
        if ship ~= target then
            self:SetUserOrder(ship, { kind = "guard", targetSignature = targetSig })
            ship:clearOrders()
            ship:giveOrder(ORDER_GUARD, target, nil, 0.95)
        end
    end
    self:SetStatus("Guard: " .. target.Name, 2)
end
