-- Guard ranges, native waypoint reactions and policy application.
local _shared = require "fs2rts_orders.common"
local RTS, shipValid, shipAlive = _shared.RTS, _shared.shipValid, _shared.shipAlive

-- Native hit reactions replace waypoint/hold modes without removing their
-- goal, so inspecting Orders alone cannot detect the diversion. Own this flag
-- only for noncombat commands and restore the mission's original setting.
function RTS:SetShipCommandDiscipline(ship,locked)
    if not shipValid(ship) then return end
    self.CommandDiscipline=self.CommandDiscipline or {}
    local id=ship:getSignature(); local saved=self.CommandDiscipline[id]
    if saved and saved.ship~=ship then self.CommandDiscipline[id]=nil; saved=nil end
    if locked then
        if not saved then
            self.CommandDiscipline[id]={ship=ship,wasSet=ship:getFlag('no-dynamic')==true}
            ship:setFlag(true,'no-dynamic')
        end
    elseif saved then
        ship:setFlag(saved.wasSet,'no-dynamic'); self.CommandDiscipline[id]=nil
    end
end

-- Upstream setGuardRange is registered with an explicit guarder argument, so
-- ship:setGuardRange(...) resolves to a non-callable ADE userdata at runtime.
-- The matching set-guard-range SEXP has the same contract on upstream FSO.
local function sexpString(value)
    return '"'..tostring(value):gsub('\\','\\\\'):gsub('"','\\"'):gsub('[\r\n]',' ')..'"'
end

function RTS:SetNativeGuardRange(guarder,guarded,range)
    if not shipAlive(guarder) or not shipAlive(guarded) or not self:IsFiniteNumber(range) then return false end
    local command=string.format('(set-guard-range %s %.0f %s)',sexpString(guarded.Name),range,sexpString(guarder.Name))
    return mn.runSEXP(command)==true
end

-- Own only the temporary move lock. Native/scripted locks must survive a move.
function RTS:SetShipTurretLock(ship,locked)
    if not shipValid(ship) then return end
    self.MoveTurretLocks=self.MoveTurretLocks or {}
    local id=ship:getSignature()
    local saved=self.MoveTurretLocks[id]
    if saved and saved.ship~=ship then self.MoveTurretLocks[id]=nil; saved=nil end
    if not locked then
        if saved then
            for _,entry in ipairs(saved.turrets) do
                if entry.subsystem:isValid() then entry.subsystem.TurretLocked=entry.wasLocked end
            end
            self.MoveTurretLocks[id]=nil
        end
        return
    end
    if saved then return end
    saved={ship=ship,turrets={}}
    self.MoveTurretLocks[id]=saved
    for i=1,#ship do
        local subsystem=ship[i]
        if subsystem~=nil and subsystem:isValid() and subsystem:isTurret() then
            saved.turrets[#saved.turrets+1]={subsystem=subsystem,wasLocked=subsystem.TurretLocked==true}
            subsystem.TurretLocked=true
        end
    end
end

-- One pass over the world per policy refresh, not one per ship: the defender
-- target is a property of the station, not of each unit.
function RTS:GetStationDefendTarget()
    local carrier = self:GetCarrier()
    if not shipValid(carrier) then return nil end
    local radius = self.Config.Policy.DefendRadius or self.Config.AI.StationDefenseRadius or 6500
    local best, bestDistance = nil, math.huge
    self:EachShip(function(ship)
        -- shipAlive, not just IsPlayerEnemy: a hostile in death roll is still
        -- a valid object, so a shipValid-only test let the whole player's fleet
        -- launch at a corpse that was already exploding. shipAlive also covers
        -- the dying flag, which is what a scripted kill leaves behind.
        if self:IsPlayerEnemy(ship) and shipAlive(ship) then
            local d = ship.Position:getDistance(carrier.Position)
            if d <= radius and d < bestDistance then best, bestDistance = ship, d end
        end
    end)
    return best
end

function RTS:ApplyPolicyToShip(ship, force, defendTarget)
    if not self:IsFriendly(ship) or self:IsCommandStation(ship) or self:IsStaticDefense(ship) then return end
    local sig = ship:getSignature()
    if self.FleetServices and self.FleetServices[sig] then return end
    if self.PossessedSignature == sig or self.UserOrders[sig] ~= nil then return end
    local protection=self.FleetProtection and self.FleetProtection[sig]
    if protection and protection.policy==self.GlobalPolicy then return end
    if not force and self.PolicyApplied[sig] == self.GlobalPolicy then return end

    local priority = self.Config.Policy.Priority or 0.65
    local reArmPursuit = false
    if self.GlobalPolicy == "ENGAGE" then
        self:EngageShip(ship, priority)
    elseif self.GlobalPolicy == "RETREAT" then
        self:MoveShipTo(ship, self:GetRetreatDestination(ship), priority)
    elseif self.GlobalPolicy == "HOLD" then
        -- No standing order beyond staying put. This is the default while Auto
        -- Mode is off, so an uncommanded fleet never fights on its own.
        self:HoldShip(ship, priority)
    else
        local carrier = self:GetCarrier()
        if shipValid(carrier) and ship ~= carrier then
            if defendTarget ~= nil and self:AreEnemies(ship, defendTarget) then
                -- Opportunistic intercept instead of orbiting while the station
                -- is under attack. Still anchored: a threat that never comes
                -- inside DefendRadius is never chased.
                --
                -- Through the same gate the AI uses. ORDER_ATTACK on a base
                -- installs a chase goal the engine then refuses to pursue (no
                -- hull lists the command class in +Actively Pursues), so a
                -- strike capital parked on the player's doorstep was never
                -- actually intercepted - the order looked applied and the fleet
                -- sat in guard orbits. This was the only ORDER_ATTACK issued
                -- outside the gate, and it was on the player's own fleet.
                if self:IsPursuitPair(ship, defendTarget) then
                    -- giveOrder's return value is not a success signal, and
                    -- IssuePursuitOrder reports a genuinely failed goal, so a
                    -- refused pursuit falls back to guarding the station rather
                    -- than to an order the engine will not carry out.
                    if not self:IssuePursuitOrder(ship, defendTarget, priority) then
                        self:DropPursuit(sig)
                        ship:clearOrders()
                        ship:giveOrder(ORDER_GUARD, carrier, nil, priority)
                    else
                        reArmPursuit = true
                    end
                else
                    ship:clearOrders()
                    ship:giveOrder(ORDER_ATTACK, defendTarget, nil, priority)
                end
            else
                ship:clearOrders()
                ship:giveOrder(ORDER_GUARD, carrier, nil, priority)
            end
        else
            self:HoldShip(ship, priority)
        end
    end
    self.PolicyApplied[sig] = self.GlobalPolicy
    -- A pursuit is anchored to a 4 s lead point and the goal ends on arrival,
    -- so an interceptor has to be re-anchored or it flies there once and then
    -- holds a stale point while the threat sails away. RefreshAIPursuit only
    -- re-anchors automatic AI units, and a player ship is not one, so the
    -- re-arm is handed to the policy refresh instead: leaving PolicyApplied
    -- clear makes UpdateDefaultPolicy re-issue this ship on its next pass.
    if reArmPursuit then self.PolicyApplied[sig] = nil end
    if defendTarget ~= nil then self.PolicyDefend[sig] = defendTarget:getSignature() else self.PolicyDefend[sig] = nil end
end

function RTS:SetGlobalPolicy(policy)
    if policy ~= "STANDOFF" and policy ~= "ENGAGE" and policy ~= "RETREAT" and policy ~= "HOLD" then return end
    if self.AutoPlayerMode then return end
    if self.GlobalPolicy == policy then return end
    self.GlobalPolicy = policy
    self.PolicyApplied = {}
    self.PolicyDefend = {}
    local defend = self.GlobalPolicy == "STANDOFF" and self:GetStationDefendTarget() or nil
    if not self.AutoPlayerMode then
        self:EachShip(function(ship)
            if self:IsFriendly(ship) and not self:IsCommandStation(ship) and not self:IsStaticDefense(ship) then self:ApplyPolicyToShip(ship,true,defend) end
        end)
    end
    local label = policy == "RETREAT" and "RETREAT TO SAFE DISTANCE" or policy
    self:SetStatus("Default policy: " .. label .. " (manual orders override)", 3)
end

function RTS:UpdateDefaultPolicy(now)
    local interval=self.Config.Policy.RefreshInterval or 20
    if now-self.LastPolicyRefresh<interval then return end; self.LastPolicyRefresh=now
    -- Clean dead/invalid manual targets in both manual and Auto Mode. Once an
    -- explicit attack/guard target is gone, automatic control may resume.
    for sig,order in pairs(self.UserOrders) do
        local ship=self:FindShipBySignature(sig)
        if not shipValid(ship) then self.UserOrders[sig]=nil; self.PolicyApplied[sig]=nil
        elseif (order.kind=="attack" or order.kind=="guard" or order.kind=="attack_wing") and order.targetSignature~=nil then
            local target=order.kind=="attack_wing" and self:ResolveAttackWingTarget(order) or self:FindShipBySignature(order.targetSignature)
            if shipValid(target) then
                if order.kind=="attack_wing" and target:getSignature()~=order.targetSignature then
                    order.targetSignature=target:getSignature()
                    self:ReissueUserOrder(ship,order)
                end
            else self.UserOrders[sig]=nil; self.PolicyApplied[sig]=nil end
        end
    end
    if self.AutoPlayerMode then return end
    -- Not forced: only ships that do not already carry the current policy
    -- (new builds, ships just released from a player order). Forcing this every
    -- tick cleared and re-gave every idle ship's orders, resetting fights in
    -- progress. Policy changes and order hand-backs still force.
    -- The STANDOFF intercept is the exception: an appearing threat has to be
    -- able to pull units off the station orbit, so the defend target is part of
    -- the policy identity rather than a forced reissue.
    local defend = self.GlobalPolicy == "STANDOFF" and self:GetStationDefendTarget() or nil
    local defendSig = defend ~= nil and defend:getSignature() or nil
    self:EachShip(function(ship)
        if self:IsFriendly(ship) and not self:IsCommandStation(ship) and not self:IsStaticDefense(ship) then
            local sig=ship:getSignature()
            if self.UserOrders[sig]==nil and self.PossessedSignature~=sig then
                if self.PolicyDefend[sig] ~= defendSig then self.PolicyApplied[sig]=nil end
                self:ApplyPolicyToShip(ship,false,defend)
            end
        end
    end)
end
