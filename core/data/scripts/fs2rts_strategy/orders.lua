-- Strategic order issuing: telemetry, pursuit and move goals.
local _shared = require "fs2rts_strategy.common"
local RTS, shipAlive, copyVec, objectValid, vec, shipValid, canAutoEngage, ATTACK_ORDER_PRIORITY = _shared.RTS, _shared.shipAlive, _shared.copyVec, _shared.objectValid, _shared.vec, _shared.shipValid, _shared.canAutoEngage, _shared.ATTACK_ORDER_PRIORITY
local PURSUIT_LEAD_SECONDS, PURSUIT_REFRESH_SECONDS, UNPURSUED_TARGET_ROLES, HEAVY_ATTACKER_ROLES = _shared.PURSUIT_LEAD_SECONDS, _shared.PURSUIT_REFRESH_SECONDS, _shared.UNPURSUED_TARGET_ROLES, _shared.HEAVY_ATTACKER_ROLES

function RTS:RecordAIOrderTelemetry(kind,mission,status,result)
    if not self.CombatTelemetryEnabled then return end
    local audit=self.AIOrderTelemetry or {attempts=0,success=0,failed=0,rejected=0,unchanged=0,byMission={},byResult={}}
    self.AIOrderTelemetry=audit
    local faction=tostring(kind or "?"); local label=tostring(mission or "NONE"); local outcome=tostring(status or "unknown")
    audit.attempts=audit.attempts+1
    if outcome=="success" then audit.success=audit.success+1
    elseif outcome=="failed" then audit.failed=audit.failed+1
    elseif outcome=="rejected" then audit.rejected=audit.rejected+1
    elseif outcome=="unchanged" then audit.unchanged=audit.unchanged+1 end
    audit.byMission[faction]=audit.byMission[faction] or {}
    audit.byMission[faction][label]=audit.byMission[faction][label] or {success=0,failed=0,rejected=0,unchanged=0}
    audit.byMission[faction][label][outcome]=(audit.byMission[faction][label][outcome] or 0)+1
    local resultKey=outcome..":"..tostring(result)
    audit.byResult[resultKey]=(audit.byResult[resultKey] or 0)+1
end

function RTS:IsHeavyAttackHull(ship)
    if not shipAlive(ship) then return false end
    return HEAVY_ATTACKER_ROLES[self:GetShipRole(ship)]==true
end

function RTS:IsUnpursuedTarget(target)
    if not shipAlive(target) then return false end
    -- A command station is never on any hull's +Actively Pursues list: those
    -- lists enumerate mobile class types (transport, freighter, cruiser,
    -- corvette, capital, super cap, drydock, knossos) and omit "command". So
    -- ORDER_ATTACK on a base installs a chase goal the engine then refuses, and
    -- the attacker sits where it was. A station's computed role is "capital"
    -- (its hull radius is large), which is why this has to test the station
    -- itself rather than the role. Measured: capitals and escorts assigned a
    -- PRIMARY attack on a base stalled 10-12 km out for up to 17 minutes.
    if self:IsCommandStation(target) then return true end
    return UNPURSUED_TARGET_ROLES[self:GetShipRole(target)]==true
end

function RTS:IsPursuitPair(ship,target,subsystem,forceApproach)
    -- A subsystem-targeted attack must stay a native ORDER_ATTACK: that order is
    -- the only way to aim at a specific turret, and the pursuit waypoint carries
    -- no subsystem, so it would silently degrade to a hull-level attack.
    if subsystem~=nil then return false end
    -- Native capital chase may settle into a stationary broadside before its
    -- short batteries reach. An explicit RTS attack owns the approach for every
    -- hull target, including another capital, rather than just excluded types.
    return self:IsHeavyAttackHull(ship) and shipAlive(target) and (forceApproach or self:IsUnpursuedTarget(target))
end

-- A move goal to a leading intercept point. The goal terminates on arrival, so
-- RefreshAIPursuit re-anchors it; without that the capital reaches the stale
-- point once and then sits there holding nothing.
function RTS:IssuePursuitOrder(ship,target,priority,arrivalDistance)
    if not shipAlive(ship) or not shipAlive(target) then return false end
    local sig=ship:getSignature()
    if self.FleetServices and self.FleetServices[sig] then return false end
    local point=copyVec(target.Position)
    local vel=target.Physics and target.Physics.Velocity
    if vel and self:IsFiniteVector(vel) then
        local vx,vz=vel.x or 0,vel.z or 0
        local speed=math.sqrt(vx*vx+vz*vz)
        if speed>1 then
            local top=math.max(speed,math.abs((target.Physics.VelocityMax or {}).z or speed))
            -- Never lead by more than half a target's own top speed: a big
            -- hull is slow and would otherwise sail past a fast fighter.
            local lead=math.min(PURSUIT_LEAD_SECONDS,0.5*top/speed)
            point=vec(point.x+vx*lead,point.y,point.z+vz*lead)
        end
    end
    -- Pursue a firing position, not the target's centre. Native waypoint
    -- steering otherwise takes large hulls into each other before arrival.
    local away=ship.Position-target.Position; local length=away:getDistance(vec(0,0,0))
    local direction=length>1 and away/length or -ship.Orientation:getFvec()
    point=point+direction*((ship.Radius or 0)+(target.Radius or 0)+600)
    local safe=self:ClampShipDestination(ship,point)
    if not safe then return false end
    local waypoint=self:ConfigureMoveWaypoints(ship,safe)
    if not objectValid(waypoint) then return false end
    ship:clearOrders()
    if ship:giveOrder(ORDER_WAYPOINTS_ONCE,waypoint,nil,priority or ATTACK_ORDER_PRIORITY)~=true then return false end
    self.AIPursuit=self.AIPursuit or {}
    local entry=self.AIPursuit[sig]
    if entry==nil then entry={}; self.AIPursuit[sig]=entry end
    entry.targetSignature=target:getSignature(); entry.anchoredAt=mn.getMissionTime()
    entry.priority=priority or ATTACK_ORDER_PRIORITY
    entry.arrivalDistance=arrivalDistance or 900
    return true
end

function RTS:DropPursuit(sig)
    if self.AIPursuit then self.AIPursuit[sig]=nil end
end

function RTS:IssueStrategicOrder(ship,target,label,mission,now,force,options)
    if not shipAlive(ship) or not shipAlive(target) or (self.IsShipWithdrawing and self:IsShipWithdrawing(ship)) then return false end
    if self.FleetServices and self.FleetServices[ship:getSignature()] then return false end
    local sig=ship:getSignature(); local tsig=target:getSignature(); local previous=self.AIOrderState[sig]; local kind=self:GetFactionKey(ship)
    local enemies=canAutoEngage(self,ship,target)
    -- Fighter chip damage permits player pressure, not a committed AI siege force.
    if enemies and self:IsCommandStation(target) and not self:CanDamageBase(ship) then
        self:RecordAIOrderTelemetry(kind,mission,"rejected",false)
        return false
    end
    local destination=options and options.destination
    local subsystem=options and options.subsystem
    local subsystemIndex=options and options.subsystemIndex
    if destination and (not self:IsFiniteVector(destination) or (mission~='REGROUP' and mission~='RETREAT')) then return false end
    if subsystem and (not enemies or not subsystem:isValid() or subsystem.HitpointsLeft<=0
        or not objectValid(subsystem:getParent()) or subsystem:getParent():getSignature()~=tsig
        or type(subsystemIndex)~='number' or subsystemIndex~=math.floor(subsystemIndex)
        or subsystemIndex<1 or subsystemIndex>#target
        or target[subsystemIndex].Name~=subsystem.Name) then return false end
    local guard=(mission=="SCREEN" or mission=="ESCORT" or mission=="REGROUP" or mission=="RETREAT" or mission=="LURE") and not enemies and self:GetFactionKey(ship)==self:GetFactionKey(target)
    if not guard and not enemies then
        -- Do not clear a valid order when a stale/invalid planner target is
        -- presented. This is the last gate before an engine attack goal.
        if previous and previous.targetSignature==tsig then self.AIOrderState[sig]=nil end
        self:RecordAIOrderTelemetry(kind,mission,"rejected",false)
        return false
    end
    if destination then
        destination=self:ClampShipDestination(ship,destination)
        if not destination then return false end
    end
    local samePoint=not destination and not (previous and previous.destination)
        or destination and previous and previous.destination and destination:getDistance(previous.destination)<100
    if not force and previous and previous.targetSignature==tsig and previous.mission==mission
        and samePoint and previous.subsystemIndex==subsystemIndex then
        self:RecordAIOrderTelemetry(kind,mission,"unchanged",true)
        return
    end
    local moveWaypoint
    if destination then
        local safe=self:ClampCommandPoint(destination,self:GetShipFormationRadius(ship)*1.05)
        if not safe then return false end
        moveWaypoint=self:ConfigureMoveWaypoints(ship,safe)
        if not objectValid(moveWaypoint) then return false end
        destination=copyVec(safe)
    end
ship:clearOrders()
    local given
    local arrivalDistance
    local pursuit=false
    if destination then
        -- Pure movement goal (RETREAT, REGROUP, LURE): a single waypoint on a
        -- freshly cleared order list. There is no FSO SEXP for a coordinate
        -- fly-to (only ai-fly-to-ship exists), so ORDER_WAYPOINTS_ONCE against
        -- the pooled waypoint is the only engine primitive that moves a hull to
        -- a point. clearOrders above removes any prior attack target, which is
        -- what keeps the transit from engaging.
        given=ship:giveOrder(ORDER_WAYPOINTS_ONCE,moveWaypoint,nil,ATTACK_ORDER_PRIORITY)
        arrivalDistance=900
    elseif guard and (mission=="RETREAT" or mission=="LURE") then
        arrivalDistance=math.ceil((target.Radius or 0)+(ship.Radius or 0)+1400)
        -- giveOrder(ORDER_FLY_TO) leaves float_data=0 in FSO 26.0.1.
        -- The SEXP contract exposes a real, safe arrival distance instead.
        if not ship.Name:find('["\\%c]') and not target.Name:find('["\\%c]') then
            given=mn.runSEXP(string.format('(add-ship-goal "%s" (ai-fly-to-ship "%s" 90 %d))',ship.Name,target.Name,arrivalDistance))
        end
    elseif guard then given=ship:giveOrder(ORDER_GUARD,target,nil,.84)
    elseif self:IsPursuitPair(ship,target,subsystem) then
        arrivalDistance=900
        pursuit=self:IssuePursuitOrder(ship,target,ATTACK_ORDER_PRIORITY,arrivalDistance)
        given=pursuit and true or false
    else given=ship:giveOrder(ORDER_ATTACK,target,subsystem,ATTACK_ORDER_PRIORITY) end
    -- FSO returns false/nil when a goal cannot be installed (for example when
    -- the ship is being deleted or the target became invalid between the check
    -- and the call). Do not cache a successful-looking assignment in that case;
    -- the next strategic tick must be allowed to retry it.
    if given~=true then
        self.AIOrderState[sig]=nil
        if pursuit then self:DropPursuit(sig) end
        self:RecordAIOrderTelemetry(kind,mission,"failed",given)
        return false
    end
    self:SetShipCommandDiscipline(ship,destination~=nil or (guard and (mission=='RETREAT' or mission=='LURE')))
    self:SetShipTurretLock(ship,destination~=nil)
    if guard and not destination then
        self:SetNativeGuardRange(ship,target,self:IsCommandStation(target) and self.Config.AI.StationDefenseRadius or self.Config.AI.CohesionRadius)
    end
    local same=previous and previous.targetSignature==tsig and previous.mission==mission
    self.AIOrderState[sig]=same and previous or {targetSignature=tsig,label=label,mission=mission,assignedAt=now or mn.getMissionTime()}
    self.AIOrderState[sig].installedAt=now or mn.getMissionTime()
    self.AIOrderState[sig].arrivalDistance=arrivalDistance
    self.AIOrderState[sig].destination=destination
    self.AIOrderState[sig].subsystemIndex=subsystemIndex
    -- A pursuit is a live move goal, not a single chase assignment: the
    -- refresh pass re-anchors it while the pair stays valid.
    self.AIOrderState[sig].pursuitAt=pursuit and (now or mn.getMissionTime()) or nil
    if not pursuit then self:DropPursuit(sig) end
    self:RecordAITransition(ship,previous,self.AIOrderState[sig],same and "ORDER_REISSUED" or "ORDER_ACCEPTED",now)
    self:RecordAIOrderTelemetry(kind,mission,"success",given)
    return true
end

-- Re-anchor every live pursuit so the move goal never expires into an idle
-- capital. Runs on its own cadence, independent of StrategicOrderInterval.
function RTS:RefreshAIPursuit(now)
    local pursuit=self.AIPursuit
    if not pursuit then return end
    local interval=(self.Config.AI.Doctrine or {}).PursuitRefreshInterval or PURSUIT_REFRESH_SECONDS
    for sig,entry in pairs(pursuit) do
        local state=self.AIOrderState and self.AIOrderState[sig]
        local manual=self.UserOrders and self.UserOrders[sig]
        local playerAttack=manual and (manual.kind=='attack' or manual.kind=='attack_wing')
            and not manual.approaching and self.PossessedSignature~=sig
            and not (self.FleetServices and self.FleetServices[sig])
        if playerAttack then state=manual end
        local ship=self:FindShipBySignature(sig)
        local target=state and self:FindShipBySignature(state.targetSignature)
        if not state or (not playerAttack and not state.pursuitAt) or state.targetSignature~=entry.targetSignature
            or not shipAlive(ship) or (not playerAttack and not self:IsAutomaticAIUnit(ship))
            or not shipAlive(target) or not canAutoEngage(self,ship,target) then
            pursuit[sig]=nil
        elseif now-(entry.anchoredAt or 0)>=interval then
            if self:IssuePursuitOrder(ship,target,entry.priority or ATTACK_ORDER_PRIORITY,entry.arrivalDistance) then
                entry.anchoredAt=now; state.pursuitAt=now
            else
                state.pursuitAt=nil; pursuit[sig]=nil
            end
        end
    end
end

-- ORDER_ATTACK_ANY runs the same class-type-filtered target search, so a
-- capital under the engage (T) order never acquires a fighter and idles. Give
-- it a moving anchor while it has no usable native target, and hand the goal
-- straight back to the engine as soon as it does.
function RTS:RefreshEngagePursuit(now)
    if not self.UserOrders then return end
    local interval=(self.Config.AI.Doctrine or {}).PursuitRefreshInterval or PURSUIT_REFRESH_SECONDS
    local radius=(self.Config.AI.Doctrine or {}).EngagePursuitRadius or 12000
    for sig,order in pairs(self.UserOrders) do
        if order.kind~="engage" then
            if self.EngagePursuit then self.EngagePursuit[sig]=nil end
        else
            local ship=self:FindShipBySignature(sig)
            local entry=self.EngagePursuit and self.EngagePursuit[sig]
            local native=shipValid(ship) and ship.Target or nil
            if not self:IsHeavyAttackHull(ship) then
                if entry then self.EngagePursuit[sig]=nil end
            elseif objectValid(native) then
                -- Engine has acquired something; stop overriding its goal.
                if entry then self.EngagePursuit[sig]=nil; self:EngageShip(ship,0.95) end
            else
                self.EngagePursuit=self.EngagePursuit or {}
                entry=entry or {}; self.EngagePursuit[sig]=entry
                if now-(entry.anchoredAt or 0)>=interval then
                    local victim=self:FindUnitLocalThreat(ship,radius)
                    if self:IsPursuitPair(ship,victim) and self:IssuePursuitOrder(ship,victim,ATTACK_ORDER_PRIORITY) then
                        entry.anchoredAt=now; entry.targetSignature=victim:getSignature()
                    elseif entry.targetSignature~=nil then
                        self.EngagePursuit[sig]=nil; self:EngageShip(ship,0.95)
                    else entry.anchoredAt=now end
                end
            end
        end
    end
end

function RTS:UpdateAIPursuitGoals(now)
    if self.SetupActive or self.PostBattleActive then return end
    local interval=(self.Config.AI.Doctrine or {}).PursuitRefreshInterval or PURSUIT_REFRESH_SECONDS
    if now-(self.NextAIPursuitRefresh or 0)<interval then return end
    self.NextAIPursuitRefresh=now+interval
    self:RefreshAIPursuit(now)
    self:RefreshEngagePursuit(now)
end

-- 'armed' in the profile is false for any hull whose only mounts are destroyed
-- turrets, so a capital that lost its turrets looked identical to a ship that
-- is out of missiles. Returns carries (any ammo-bearing bank survives) and
-- loaded (at least one of those banks still has rounds).
function RTS:GetShipOrdnance(ship)
    if not shipValid(ship) then return false,false end
    local function scan(list,carries,loaded)
        for i=1,#list do
            local bank=list[i]
            if objectValid(bank) and (bank.AmmoMax or 0)>0 then
                carries=true
                if (bank.AmmoLeft or 0)>0 then loaded=true end
            end
        end
        return carries,loaded
    end
    local function mount(field,carries,loaded)
        for i=1,#ship do
            local turret=ship[i]
            if objectValid(turret) and not turret.TurretLocked then
                carries,loaded=scan(turret[field],carries,loaded)
            end
        end
        return carries,loaded
    end
    local carries,loaded=scan(ship.SecondaryBanks,false,false)
    carries,loaded=mount("SecondaryBanks",carries,loaded)
    if not carries then
        carries,loaded=scan(ship.PrimaryBanks,false,false)
        carries,loaded=mount("PrimaryBanks",carries,loaded)
    end
    return carries,loaded
end
