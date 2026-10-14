-- Faction threat snapshots, feint targets and heavy assault objective lock.
local _shared = require "fs2rts_strategy.common"
local RTS, objectValid, shipAlive, shipValid, canAutoEngage = _shared.RTS, _shared.objectValid, _shared.shipAlive, _shared.shipValid, _shared.canAutoEngage

function RTS:GetFactionThreats(kind,station,radius,lurePursuers)
    local threats={}; local total=0; local urgent=false
    local stationRadius=station.Radius or (station.Class.Model and station.Class.Model.Radius) or 0
    for _,row in ipairs(self.StrategicThreatSnapshot or self:BuildStrategicThreatSnapshot()) do
        local other=row.ship
        -- Static defenses are not station threats. A sentry sits on a fixed
        -- point inside Sentries.ControlRadius of its OWN base, and the bases
        -- are BaseDistances (9000 m) apart, so the closest an enemy sentry can
        -- stand to our base is 5000 m: inside ThreatRadius (6500). It then
        -- entered the threat list at full GetCombatValue, which set
        -- threat.attacking on a single recorded beam hit and tripped the
        -- emergency gate in UpdateFactionStrategicPlan (the `local emergency=`
        -- loop below) - cap jumps from MaxDefenseFleetFraction (0.50) to
        -- EmergencyDefenseFleetFraction (0.70) of the whole fleet and every
        -- group reacts. A turret that cannot manoeuvre, cannot be intercepted
        -- and cannot be chased should not drive a fleet-wide recall; its guns
        -- are already answered by the station's own defenses. It is still
        -- counted as front DEFENSE in UpdateFactionStrategicPlan, which is the
        -- side where a static gun genuinely matters.
        if shipAlive(other) and row.armed and not self:IsStaticDefense(other) and canAutoEngage(self,station,other) then
            local d=other.Position:getDistance(station.Position)
            local inRange=false; local attacking=false
            local shipTargetingStation=objectValid(other.Target) and other.Target:getSignature()==station:getSignature()
            local targetingStation=shipTargetingStation
            local beamCapable=false
            local hits=(self.StationBeamHits or {})[station:getSignature()]
            local hitTime=hits and hits[other:getSignature()]
            local memory=(self.Config.AI.Doctrine or {}).BeamHitMemorySeconds or 6
            if hitTime and mn.getMissionTime()-hitTime<=memory then inRange=true; attacking=true end
            for _,mount in ipairs(row.mounts) do
                beamCapable=beamCapable or mount.beam==true
                if objectValid(mount.target) and mount.target:getSignature()==station:getSignature() then targetingStation=true end
                if mount.position:getDistance(station.Position)<=mount.range+stationRadius then
                    inRange=true
                    if objectValid(mount.target) and mount.target:getSignature()==station:getSignature() then attacking=true end
                end
            end
            local homeDefenseEligible=inRange or d<=radius+stationRadius
            -- A mobile capital that has explicitly selected this station is
            -- a bomber-suppression target even before it enters the local
            -- screen radius. Keep it out of ordinary fighter screening until
            -- it is nearby or its weapons can reach the station.
            local capitalIntent=not self:IsCommandStation(other) and self:IsCapitalTarget(other)
                and beamCapable and shipTargetingStation
            if inRange or (not self:IsCommandStation(other) and d<=radius+stationRadius) or capitalIntent then
                local v=row.profile and row.profile.value or self:GetCombatValue(other,row.firepower)
                local big=self:IsCapitalTarget(other); local role=self:GetShipRole(other); local baseDamageCapable=self:CanDamageBase(other)
                local baseAttack=targetingStation and baseDamageCapable
                local baseAttacking=attacking and baseDamageCapable
                -- Fighter chip pressure warrants local defense, not the emergency recall reserved for siege-capable attackers.
                local immediate=baseAttacking or (baseDamageCapable and inRange and (big or role=="bomber"))
                threats[#threats+1]={ship=other,value=v,distance=d,capital=big,urgent=immediate,attacking=baseAttacking,
                    baseAttack=baseAttack,baseDamageCapable=baseDamageCapable,
                    targetingStation=targetingStation,homeDefenseEligible=homeDefenseEligible,
                    pursuingLure=(lurePursuers or {})[other:getSignature()]==true}
                total=total+v; urgent=urgent or immediate
            end
        end
    end
    table.sort(threats,function(a,b)
        -- Base-capable attackers outrank a larger harmless fighter swarm.
        if a.baseAttack~=b.baseAttack then return a.baseAttack end
        if a.urgent~=b.urgent then return a.urgent end
        if a.attacking~=b.attacking then return a.attacking end
        if a.value~=b.value then return a.value>b.value end
        return a.ship:getSignature()<b.ship:getSignature()
    end)
    return threats,total,urgent
end

function RTS:ChooseAIFeintTarget(kind,primary,radius)
    if not shipValid(primary) then return primary end
    local station=self:GetFactionCommandShip(kind)
    local best,bestScore=nil,math.huge
    for _,row in ipairs(self:GetAISpatialCandidates(primary.Position,radius)) do
        local target=row.ship
        if shipAlive(target) and target.Name~=self.Config.ObserverShip
            and not self:IsCommandStation(target) and canAutoEngage(self,station,target) then
            local role=self:GetShipRole(target)
            if role=="fighter" then
                local targeters=(self.AITargetedBy or {})[target:getSignature()]
                local alreadyEngaged=targeters and targeters[kind] and next(targeters[kind])~=nil
                local distanceToBase=target.Position:getDistance(primary.Position)
                if not alreadyEngaged and distanceToBase<=radius then
                    local faction=self:GetFactionKey(target)
                    local score=distanceToBase+self:GetStrategicUnitValue(target,faction)*0.05
                    if best==nil or score<bestScore
                        or (score==bestScore and target:getSignature()<best:getSignature()) then
                        best=target; bestScore=score
                    end
                end
            end
        end
    end
    -- A fighter feint with no screen contact must not fall back to a station
    -- target it cannot damage.
    return best
end

-- HEAVY ASSAULT OBJECTIVE LOCK. Default OFF: with both doctrine flags unset
-- this returns its inputs untouched and UpdateFactionStrategicPlan behaves
-- exactly as it shipped.
--
-- Why it exists, and why it lives here rather than in ChooseAIOperationTarget.
-- ChooseAIOperationTarget (fs2rts_operations.lua:192) scores a candidate with
-- `rank*100000 - distance - covered`, where a static defence is rank 3 for a
-- strike group and the objective of the operation itself - the enemy command station,
-- a capital target by name - is rank 1. The 200,000 gap cannot be closed by
-- distance, which is bounded by ~(station radius + 6000) for every candidate,
-- so every sentry in the defender ring outranks the station for a capital
-- unconditionally. Measured on capgate-20261001, over 2906 heavy PRIMARY
-- decisions: 44.8% targeted a sentry, 16.4% the station, and
-- localThreatSignature == target occurred 0 times with hardLocalThreat false in
-- 100% - because ApplyAIOperationOrder runs at the END of the per-group loop,
-- after every local-threat decision, and returns with context.locked=true. The
-- heavy group was never choosing; it was being told.
--
-- This is a veto on the value operations returns, deliberately placed at the
-- only seam this file owns. Two separate flags, because the sentry bucket and
-- the mobile bucket are different problems with different evidence.
function RTS:ApplyAssaultObjectiveLock(g,target,mission,context)
    local doctrine=(self.Config.AI and self.Config.AI.Doctrine) or {}
    local lockStatic=doctrine.AssaultStaticDefenceLock==true
    local lockMobile=doctrine.AssaultMobileThreatLock==true
    g.assaultLock=nil
    if not (lockStatic or lockMobile) then return target,mission end
    -- Bombers are excluded on purpose and not by oversight: turret suppression
    -- is what a bomber wing is for, and GetAISuppressionSubsystem already
    -- reserves SIEGE_TURRET_TARGET/SUBSYSTEM_SUPPRESSION for them. Escorts are
    -- excluded because Doctrine.AssaultEscortWings already gives the strike
    -- anchor their job, and a mixed wing must not be split by this gate.
    if g.role~='capital' and g.role~='heavy' and g.role~='juggernaut' then return target,mission end
    if mission~='PRIMARY' then return target,mission end
    local op=g.operation
    if not op or not shipAlive(op.target) or not self:IsCommandStation(op.target) then return target,mission end
    -- Already pressing the station, or already the station: nothing to veto.
    if not shipValid(target) or target==op.target then return target,mission end
    local lead=g.units and g.units[1]
    if not shipAlive(lead) or not canAutoEngage(self,lead,target) then return target,mission end
    local isStatic=self:IsStaticDefense(target)
    if isStatic and not lockStatic then return target,mission end
    if not isStatic and not lockMobile then return target,mission end
    local bound,corridor
    if isStatic then
        bound=doctrine.AssaultStaticDefenceThreatDistance or 0
        corridor=doctrine.AssaultStaticDefenceCorridorWidth or 0
    else
        bound=doctrine.AssaultMobileThreatDistance or 0
        corridor=doctrine.AssaultMobileThreatCorridorWidth or 0
    end
    -- REACTIVE. The diverted hull must be the local threat of this group - the
    -- hostile the planner already identified as pressing it - and no member may
    -- have fallen further than the bound from it. Identity is required, not
    -- just proximity: g.hardLocalThreat is a statement about SOME local threat,
    -- so honouring it for an arbitrary target would re-admit exactly the
    -- behaviour being gated.
    local reactive=false; local threatDistance=-1
    if shipValid(g.localThreat) and g.localThreat:getSignature()==target:getSignature() then
        threatDistance=math.huge
        for _,member in ipairs(g.units or {}) do
            if shipAlive(member) and member.Position then
                threatDistance=math.min(threatDistance,member.Position:getDistance(target.Position))
            end
        end
        if threatDistance==math.huge then threatDistance=-1 end
        reactive=threatDistance>=0 and threatDistance<=bound
    end
    -- CORRIDOR. Disabled when width is 0, which is the shipped default, because
    -- it is measurably vacuous: over the 1301 sentry diversions the
    -- perpendicular offset from the centroid->station axis is p50 689 m and
    -- p90 2008 m, so a 3000 m corridor admits 97.5% of them and 5000 m admits
    -- all of them. That is structural - sentry placement is capped at station
    -- radius + 4 km - so no width that still admits a sentry blocking the lane
    -- can exclude one that is not.
    local inCorridor=false; local corridorOffset=-1
    if corridor>0 then
        local x,z,count=0,0,0
        for _,member in ipairs(g.units or {}) do
            if shipAlive(member) and member.Position then
                x=x+member.Position.x; z=z+member.Position.z; count=count+1
            end
        end
        if count>0 then
            x=x/count; z=z/count
            local ax,az=op.target.Position.x,op.target.Position.z
            local dx,dz=ax-x,az-z
            local length=math.sqrt(dx*dx+dz*dz)
            if length>1 then
                dx, dz = dx/length, dz/length
                local along=(target.Position.x-x)*dx+(target.Position.z-z)*dz
                corridorOffset=math.abs((target.Position.x-x)*dz-(target.Position.z-z)*dx)
                inCorridor=along>0 and along<length and corridorOffset<=corridor
            end
        end
    end
    if reactive or inCorridor then return target,mission end
    -- Hold the station. Deliberately not touching context.locked: the
    -- operation set it, and the retention gate in CommitAIGroup reads it, so the
    -- group stays committed to the front for the whole tick instead of
    -- re-deriving the same sentry on the next StrategicOrderInterval.
    g.assaultLock={held=op.target:getSignature(),rejected=target:getSignature(),
        staticDefence=isStatic,threatDistance=threatDistance,corridorOffset=corridorOffset}
    context.reason='ASSAULT_OBJECTIVE_HELD'
    return op.target,mission
end

function RTS:UpdateAIProductionDemand(kind,station,threats,now)
    local observed={fighter=0,bomber=0,escort=0,capital=0}; local total=0
    local function counter(ship)
        local role=self:GetShipRole(ship)
        return self:IsCapitalTarget(ship) and 'bomber' or role=='bomber' and 'fighter' or 'escort'
    end
    for _,row in ipairs(self.StrategicThreatSnapshot or {}) do
        if shipAlive(row.ship) and not self:IsCommandStation(row.ship) and not self:IsStaticDefense(row.ship)
            and canAutoEngage(self,station,row.ship) then
            local value=row.profile and row.profile.value or self:GetCombatValue(row.ship,row.firepower)
            local role=counter(row.ship); observed[role]=observed[role]+value; total=total+value
        end
    end
    self.AIOpponentDemand=self.AIOpponentDemand or {}
    local memory=self.AIOpponentDemand[kind]
    local alpha=memory and 1-math.exp(-math.log(2)*math.max(0,now-memory.time)/30) or 1
    memory=memory or {values={}}
    local demand={}
    for role,value in pairs(observed) do
        memory.values[role]=(memory.values[role] or 0)*(1-alpha)+.35*value/math.max(1,total)*alpha
        demand[role]=memory.values[role]
    end
    memory.time=now; self.AIOpponentDemand[kind]=memory
    local pressure=0
    for _,threat in ipairs(threats) do pressure=pressure+threat.value end
    for _,threat in ipairs(threats) do
        local role=counter(threat.ship); demand[role]=demand[role]+.5*threat.value/math.max(1,pressure)
    end
    self.AIProductionNeeds=self.AIProductionNeeds or {}; self.AIProductionNeeds[kind]=demand
end

function RTS:ChooseAIBomberEscort(groups,anchor,reserve,allocated)
    local free=0; local best,bestDistance=nil,math.huge
    for _,g in ipairs(groups) do
        if (g.role=='fighter' or g.role=='escort') and g.target==nil and not g.defending and not g.committed
            and not g.luring and not g.probing and not g.assaultReserved and not shipAlive(g.localThreat) then
            free=free+g.value
            local d=g.units[1].Position:getDistance(anchor.units[1].Position)
            if not best or d<bestDistance or (d==bestDistance and g.id<best.id) then best,bestDistance=g,d end
        end
    end
    if best and free-best.value>=math.max(0,reserve-allocated) then return best end
end
