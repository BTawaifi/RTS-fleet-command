-- Faction strategic plan: UpdateFactionStrategicPlan, a single large function.
local _shared = require "fs2rts_strategy.common"
local RTS, clamp, shipAlive, shipValid, canAutoEngage = _shared.RTS, _shared.clamp, _shared.shipAlive, _shared.shipValid, _shared.canAutoEngage

function RTS:UpdateFactionStrategicPlan(kind,now,force)
    local station=self:GetFactionCommandShip(kind); if not shipValid(station) then return end
    if not self.AIStats then self:ResetCoordinatedAI() end
    local ownsSnapshot=self.StrategicThreatSnapshot==nil
    if ownsSnapshot then self.StrategicThreatSnapshot=self:BuildStrategicThreatSnapshot(); self:BuildAIContext(self.StrategicThreatSnapshot) end
    local primary=self:GetStablePrimaryTarget(kind)
    local doctrine=self.Config.AI.Doctrine or {}; local threatRadius=doctrine.ThreatRadius or self.Config.AI.StationDefenseRadius or 6000
    local lurePursuers=self:GetActiveLurePursuers(kind,now)
    local threats,threatValue,urgent=self:GetFactionThreats(kind,station,threatRadius,lurePursuers)
    self:UpdateAIProductionDemand(kind,station,threats,now)
    local groups={}; local byGroup={}; local totalValue=0; local screenEligibleValue=0
    local servicingCount=0; local playerControlledCount=0
    local ownedCount=0; local plannedCount=0
    self:EachShip(function(ship)
        if shipAlive(ship) and self:GetFactionKey(ship)==kind and ship:getSignature()~=station:getSignature() and ship.Name~=self.Config.ObserverShip and not self:IsStaticDefense(ship) then
            local sig=ship:getSignature()
            -- Ships in fleet service hold no strategic order by design, so they
            -- are counted apart from genuinely unordered ships. Both are tallied
            -- here because this is the only place that knows why a ship was
            -- left out of every group.
            ownedCount=ownedCount+1
            if self.FleetServices and self.FleetServices[sig] then
                servicingCount=servicingCount+1
            elseif kind=="BLUE" and (not self.AutoPlayerMode or self.PossessedSignature==sig or self.UserOrders[sig]~=nil) then
                playerControlledCount=playerControlledCount+1
            else
                local entry=self:GetAIRosterEntry(kind,ship.Class.Name); local role=entry and entry.role or self:GetShipRole(ship); local profile=self:AIProfile(ship); local v=profile.value
                local wing=self:GetLogicalWing(ship)
                local id=(wing and wing.id or tostring(sig))..":"..role
                local g=byGroup[id]
                if g==nil then g={id=id,units={},role=role,value=0,screen=false,committed=false,assaultReserved=false}; byGroup[id]=g; groups[#groups+1]=g end
                g.units[#g.units+1]=ship; g.value=g.value+v; totalValue=totalValue+v
                plannedCount=plannedCount+1
                g.armed=g.armed or profile.armed
                local carries,loaded=self:GetShipOrdnance(ship)
                g.ordnance=g.ordnance or carries
                g.ordnanceLoaded=g.ordnanceLoaded or loaded
                local prev=self.AIOrderState[sig]
                g.screen=g.screen or (prev~=nil and (prev.mission=="SCREEN" or prev.mission=="TRAP"))
                if role=="fighter" or role=="escort" then screenEligibleValue=screenEligibleValue+v end
            end
        end
    end)
-- ASSAULT GROUP POOLING, off unless Station.AI.Doctrine.PoolAssaultGroupsEnabled.
    -- A group's identity is (logical wing or ship signature)..role (line 687) and
    -- nothing in the planner ever merges two of them, so the simultaneous group
    -- count is simply the surviving wing count and grows with the purchase rate.
    -- Measured: 4.0 groups/faction at group_value_hhi 0.420 in the broken batch
    -- against 2.1 at 0.677 in the baseline, with 3.6x the order churn. Pooling
    -- folds wings that already share a role, a front and a mission - and are
    -- already next to each other - into one group, so one intent is one order.
    groups=self:PoolAIAssaultGroups(groups)
    self:PrepareAIGroups(groups,station,primary,now)
    self:AssignAIAssaultFronts(kind,groups,primary)
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local previous=lead and self.AIOrderState[lead:getSignature()] or nil
        if previous and shipAlive(g.primary) and (previous.mission=="PRIMARY" or previous.mission=="REGROUP")
            and (previous.assaultPrimarySignature==nil or previous.assaultPrimarySignature==g.primary:getSignature()) then
            g.committed=now-(previous.assaultStartedAt or previous.assignedAt or now)>=(doctrine.AssaultCommitSeconds or 25)
                or lead.Position:getDistance(g.primary.Position)<=(doctrine.AssaultCommitDistance or 5200)
        end
        if previous and now<(previous.feintUntil or 0) then
            g.probing=true; g.feint=true; g.feintUntil=previous.feintUntil
            g.feintTargetSignature=previous.feintTargetSignature
                or (previous.mission=="FEINT" and previous.targetSignature or nil)
        end
        if previous and previous.mission=="LURE" and now<(previous.lureUntil or 0) then
            g.luring=true; g.lureUntil=previous.lureUntil
            g.target=station; g.mission="LURE"
        end
    end
    -- A strategic primary is not a substitute for local combat awareness.
    -- When opposing mobile units meet in the lane between bases, mark the
    -- nearest hostile as an intercept candidate. Station-defense assignments
    -- below take priority; this candidate is used only by groups left over.
    local localRadius=(self.Config.AI and self.Config.AI.LocalEngageRadius) or 0
    if localRadius>0 then
        for _,g in ipairs(groups) do
            g.localThreat=self:ChooseAILocalThreat(g)
            g.localThreatSource=shipValid(g.localThreat) and "LOCAL_RADIUS" or nil
        end
    end
    local stationPct=station.HitpointsMax>0 and station.HitpointsLeft/station.HitpointsMax or 1; local critical=stationPct<=(doctrine.CriticalStationHullFraction or .35)
    -- Range capability deserves a response, but is not evidence that the
    -- entire fleet must abandon its offensive objective. Reserve full recall
    -- for active station attacks, close heavy threats, or critical base hull.
    local emergency=critical and #threats>0
    for _,threat in ipairs(threats) do
        if threat.attacking or (threat.urgent and threat.distance<=(station.Radius or 0)+(doctrine.HardEngageRadius or 1800)) then
            emergency=true; break
        end
    end
    local overwhelmed=emergency and threatValue*(doctrine.DefenseResponseRatio or 1.15)>totalValue*(doctrine.EmergencyDefenseFleetFraction or .7)
    local posture=critical and #threats>0 and "CRITICAL_DEFENSE" or overwhelmed and "BASE_UNDER_ASSAULT" or urgent and "DEFENSIVE" or "BALANCED"
    local cap=((critical or overwhelmed) and emergency and 1 or emergency and (doctrine.EmergencyDefenseFleetFraction or .7) or (doctrine.MaxDefenseFleetFraction or .5))*totalValue
    local reserve=math.min((doctrine.ScreenReserveFraction or .38)*screenEligibleValue,cap)
    -- Do not let routine local contacts consume the entire faction. Reserve
    -- an assault element for the selected enemy station so the strategic
    -- objective continues to make progress while the rest screens/intercepts.
    local assaultFraction=clamp(doctrine.AssaultFleetFraction or .30,0,.80)
    local assaultReserveValue=totalValue*assaultFraction
    local assaultReservedValue=0
    local function assaultRole(g)
        return g.role=="capital" or g.role=="heavy" or g.role=="juggernaut" or g.role=="bomber"
    end
    -- Bomber wings are strike assets. Keep them assigned to the strategic
    -- capital/base target through routine fighter contacts; close or targeted
    -- threats are handled by the bomber-specific self-defense test below.
    for _,g in ipairs(groups) do
        if g.role=="bomber" then
            g.assaultReserved=true; assaultReservedValue=assaultReservedValue+g.value
        end
    end
    for _,g in ipairs(groups) do
        if assaultReservedValue<assaultReserveValue and assaultRole(g) and not g.assaultReserved then
            g.assaultReserved=true; assaultReservedValue=assaultReservedValue+g.value
        end
    end
    -- Escorts were never assault-reserved by the loop above: assaultRole covers
    -- capital/heavy/juggernaut/bomber only, and an escort is screen-eligible and
    -- otherwise defaults to target=station with the SCREEN mission. That left
    -- the bulk of the fleet's beam DPS with no base mission to accept at all.
    -- Reserve a bounded number of escort wings for the strike, excluding groups
    -- already screening so the release is one-way and the wings cannot oscillate
    -- between screen and strike every strategic tick.
    local escortWings=math.floor(doctrine.AssaultEscortWings or 0)
    if escortWings>0 then
        local taken=0
        for _,g in ipairs(groups) do
            if taken>=escortWings then break end
            if g.role=="escort" and not g.assaultReserved and not g.screen and g.target==nil and not emergency then
                g.assaultReserved=true
                assaultReservedValue=assaultReservedValue+g.value
                taken=taken+1
            end
        end
    end
    -- Do not fill a short assault reserve with arbitrary fighter wings. A
    -- smaller capital/heavy/bomber push is preferable to suppressing the
    -- local interception behavior of groups meant to screen the battle lane.
    local dv=0
    local threatBySignature={}
    for _,threat in ipairs(threats) do threatBySignature[threat.ship:getSignature()]=threat end
    local retainedCoverage={}
    local defenseCommitSeconds=doctrine.DefenseTargetCommitmentSeconds or 18
    local defenseReleaseRadius=threatRadius+(doctrine.DefenderReleaseDistance or 1500)
    -- Keep a station defender on its current hostile through short gaps in the
    -- threat candidate list. This prevents the planner's greedy reassignment
    -- from making wings bounce between nearby attackers as they cross radius
    -- or weapon-eligibility boundaries. Active base emergencies still override.
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local prior=lead and self.AIOrderState[lead:getSignature()] or nil
        if prior and (prior.mission=="SCREEN" or prior.mission=="TRAP") and prior.protected==station:getSignature() then
            local oldTarget=self:FindShipBySignature(prior.targetSignature)
            local distanceToStation=shipValid(oldTarget) and oldTarget.Position:getDistance(station.Position) or math.huge
            local age=now-(prior.assignedAt or now)
            if not emergency and age<defenseCommitSeconds and shipAlive(oldTarget)
                and canAutoEngage(self,lead,oldTarget) and distanceToStation<=defenseReleaseRadius then
                local priorThreat=threatBySignature[prior.targetSignature]
                local telemetry={targetSignature=prior.targetSignature,age=age,
                    targetDistance=distanceToStation,releaseRadius=defenseReleaseRadius,
                    candidatePresent=priorThreat~=nil,retained=true}
                g.defenseRetention=telemetry
                g.target=oldTarget
                g.trapping=priorThreat~=nil and priorThreat.pursuingLure==true
                g.mission=g.trapping and "TRAP" or prior.mission
                g.defending=true
                dv=dv+g.value
                if priorThreat then
                    local signature=oldTarget:getSignature()
                    local match=self:AIRoleMatch(lead,oldTarget)
                    retainedCoverage[signature]=(retainedCoverage[signature] or 0)
                        +g.value*math.min(1.5,match)
                end
            else
                g.defenseRetention={targetSignature=prior.targetSignature,
                    age=age,targetDistance=distanceToStation,
                    releaseRadius=defenseReleaseRadius,retained=false,
                    reason=emergency and "EMERGENCY_OVERRIDE" or age>=defenseCommitSeconds and "COMMITMENT_EXPIRED" or
                        not shipAlive(oldTarget) and "TARGET_DEAD" or
                not canAutoEngage(self,lead,oldTarget) and "TARGET_NOT_HOSTILE" or "OUTSIDE_RELEASE_RADIUS"}
            end
        end
    end
    local function isScreen(g) return g.role=="fighter" or g.role=="escort" end
    local function responseTime(g,target)
        local eta=0
        for _,ship in ipairs(g.units) do
            local distance=ship.Position:getDistance(target.Position)
            eta=math.max(eta,math.max(0,distance-(target.Radius or 0))/math.max(1,math.abs(ship.Physics.VelocityMax.z)))
        end
        return eta
    end
    -- Assign whole available wings, crediting their value to one threat instead
    -- of spreading every fighter over a different target. Retain an existing
    -- interception on ties, but prefer ships that can arrive sooner.
    for _,threat in ipairs(threats) do
        local covered=retainedCoverage[threat.ship:getSignature()] or 0
        local required=threat.value*(doctrine.DefenseResponseRatio or 1.15)
        while threat.homeDefenseEligible~=false and covered<required and dv<cap do
            local best=nil; local bestScore=math.huge
            for _,g in ipairs(groups) do
                local match=self:AIRoleMatch(g.units[1],threat.ship)
                local suitable=(isScreen(g) or threat.capital or (critical and #threats>0)) and (match>=.2 or critical)
                local prior=self.AIOrderState[g.units[1]:getSignature()]
                local priorThreat=prior and threatBySignature[prior.targetSignature]
                local committedDefense=prior and (prior.mission=="SCREEN" or prior.mission=="TRAP") and prior.protected==station:getSignature() and priorThreat
                    and prior.targetSignature~=threat.ship:getSignature()
                    and now-(prior.assignedAt or now)<defenseCommitSeconds
                    and not emergency and not critical and not threat.attacking and not (threat.urgent and not priorThreat.urgent)
                suitable=suitable and not committedDefense
                local recallReserved=critical and emergency or emergency and dv+g.value<=cap
                if g.target==nil and not g.luring and suitable and (recallReserved or not g.assaultReserved) and (emergency or g.screen or not g.committed) then
                    local candidate=self:ScoreAIObjective(g,threat.ship,"SCREEN",{urgent=threat.urgent,reason="DEFEND_BASE"},covered,g.candidates~=nil)
                    if g.candidates then g.candidates[#g.candidates+1]=candidate end
                    local score=responseTime(g,threat.ship)/math.max(.1,match)-candidate.score*.1
                    if g.screen then score=score-(doctrine.DefenderRetentionSeconds or 10) end
                    local prev=self.AIOrderState[g.units[1]:getSignature()]
                    if prev and prev.targetSignature==threat.ship:getSignature() then score=score-(doctrine.DefenderRetentionSeconds or 10) end
                    if threat.capital and not isScreen(g) then score=score*.75 end
                    if best==nil or score<bestScore or (score==bestScore and g.id<best.id) then best=g; bestScore=score end
                end
            end
            if best==nil then break end
            best.target=threat.ship; best.defending=true; best.emergency=threat.urgent or critical
            best.trapping=threat.pursuingLure
            best.mission=best.trapping and "TRAP" or "SCREEN"
            covered=covered+best.value*math.min(1.5,(self:AIRoleMatch(best.units[1],threat.ship))); dv=dv+best.value
        end
    end
    -- A defended skirmish needs orders, not perpetual replacement purchases from the capital bank.
    local needsReinforcements=critical and emergency
    if emergency and not needsReinforcements then
        for _,threat in ipairs(threats) do
            if threat.urgent then
                local ready=0
                for _,g in ipairs(groups) do
                    if g.defending and g.target==threat.ship then
                        local eta=0
                        for _,member in ipairs(g.units) do
                            local p=self:AIProfile(member)
                            eta=math.max(eta,math.max(0,member.Position:getDistance(threat.ship.Position)
                                -(threat.ship.Radius or 0)-(p.range or 0))/math.max(1,p.speed or 0))
                        end
                        ready=ready+g.value*math.min(1.5,(self:AIRoleMatch(g.units[1],threat.ship)))*clamp(1-eta/30,0,1)
                    end
                end
                if ready<threat.value*(doctrine.DefenseResponseRatio or 1.15) then needsReinforcements=true; break end
            end
        end
    end
    self.AIProductionEmergency=self.AIProductionEmergency or {}
    self.AIProductionEmergency[kind]={emergency=needsReinforcements,time=now}
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local previous=lead and self.AIOrderState[lead:getSignature()] or nil
        if previous and previous.mission=="LURE" and now<(previous.lureUntil or 0) then
            g.luring=true; g.lureUntil=previous.lureUntil
            g.target=station; g.mission="LURE"
        end
        if g.role=="bomber" then
            g.targetedBy=self:FindAIGroupTargeter(g,kind,doctrine.BomberTargetedResponseRadius or localRadius)
            if shipValid(g.targetedBy) then
                g.localThreat=g.targetedBy; g.localThreatSource="DIRECT_TARGETER"
            end
        end
        if shipValid(g.localThreat) and not g.luring then
            -- A hostile inside the local engagement radius is a hard
            -- interception requirement.  Letting an uncommitted wing keep a
            -- remote strategic target is what caused ships to pass through
            -- each other and rely on the base screen to fight for them.
            if previous and previous.mission=="INTERCEPT" and previous.targetSignature~=nil then
                local oldTarget=self:FindShipBySignature(previous.targetSignature)
                if shipValid(oldTarget) and canAutoEngage(self,lead,oldTarget) and oldTarget:getSignature()~=g.localThreat:getSignature() then
                    local oldDistance=lead.Position:getDistance(oldTarget.Position); local newDistance=lead.Position:getDistance(g.localThreat.Position)
                    local age=now-(previous.assignedAt or now); local retention=doctrine.LocalTargetRetentionSeconds or 8
                    local improvement=clamp(doctrine.RetargetImprovementRatio or .25,0,.90)
                    if age<retention or newDistance>oldDistance*(1-improvement) then g.localThreat=oldTarget end
                end
            end
            local hardRadius=g.role=="bomber" and (doctrine.BomberSelfDefenseRadius or 1200)
                or (doctrine.HardEngageRadius or (localRadius*0.5))
            local localDistance=math.huge
            for _,member in ipairs(g.units) do
                if shipValid(g.localThreat) then localDistance=math.min(localDistance,member.Position:getDistance(g.localThreat.Position)) end
            end
            local targeted=g.role=="bomber" and shipValid(g.targetedBy)
            g.hardLocalThreat=localDistance<=hardRadius or targeted
            if g.target==nil and (not g.assaultReserved or critical or g.hardLocalThreat) then
                g.target=g.localThreat
                g.mission="INTERCEPT"
            end
        end
    end
    -- A direct ship-level base attack order from a beam-capable capital is an
    -- early bomber response, even outside the local screen radius. A turret's
    -- aim alone is weaker evidence and only qualifies nearby; an observed hit
    -- is strongest and takes the full emergency path.
    local maxSuppressionWings=math.max(0,math.floor(doctrine.CapitalSuppressionBomberWings or 1))
    local capitalResponseRadius=doctrine.CapitalSuppressionRadius or threatRadius
    if not emergency and doctrine.CapitalSuppressionEnabled~=false and maxSuppressionWings>0 then
        local function isCapitalResponseThreat(threat)
            return threat.capital and (threat.urgent or threat.targetingStation)
        end
        local function capitalAttackEvidence(threat)
            if threat.attacking then return 2 end
            if threat.targetingStation then return 1 end
            return 0
        end
        local strongestCapitalEvidence=0
        for _,threat in ipairs(threats) do
            if isCapitalResponseThreat(threat) then
                strongestCapitalEvidence=math.max(strongestCapitalEvidence,capitalAttackEvidence(threat))
            end
        end
        local capitalReleaseRadius=capitalResponseRadius+(doctrine.DefenderReleaseDistance or 1500)
        local function findThreat(signature,retaining)
            local target=self:FindShipBySignature(signature)
            if not shipAlive(target) or not self:IsCapitalTarget(target)
                or self:IsCommandStation(target) or target==primary or not canAutoEngage(self,station,target) then
                return nil
            end
            for _,threat in ipairs(threats) do
                if threat.ship:getSignature()==signature and isCapitalResponseThreat(threat) then
                    return target
                end
            end
            -- Once dispatched against a base-targeting capital, keep the
            -- bomber committed while that capital remains near the base, even
            -- if it switches targets to the responding wing.
            if retaining and target.Position:getDistance(station.Position)<=capitalReleaseRadius then return target end
            return nil
        end
        local retained={}; local assignedGroups={}; local assignedTargets={}
        for _,g in ipairs(groups) do
            local lead=g.units[1]
            local previous=lead and self.AIOrderState[lead:getSignature()] or nil
            if previous and previous.mission=="INTERCEPT" and previous.reason=="CAPITAL_THREAT_PREEMPTION" then
                local target=findThreat(previous.targetSignature,true)
                local priorEvidence=0
                for _,threat in ipairs(threats) do
                    if threat.ship:getSignature()==previous.targetSignature then
                        priorEvidence=capitalAttackEvidence(threat)
                        break
                    end
                end
                local displaced=strongestCapitalEvidence>priorEvidence
                if target and not displaced and g.target==nil and not g.hardLocalThreat and not g.luring and not g.probing then
                    retained[#retained+1]={group=g,target=target}
                end
            end
        end
        table.sort(retained,function(a,b) return a.group.id<b.group.id end)
        local activeWings=0
        for _,entry in ipairs(retained) do
            if activeWings>=maxSuppressionWings then break end
            local g=entry.group; local signature=entry.target:getSignature()
            g.target=entry.target; g.mission="INTERCEPT"; g.defending=true; g.capitalSuppression=true
            assignedGroups[g.id]=true; assignedTargets[signature]=true; activeWings=activeWings+1
        end
        for _,threat in ipairs(threats) do
            if activeWings>=maxSuppressionWings then break end
            local signature=threat.ship:getSignature()
            if isCapitalResponseThreat(threat) and not self:IsCommandStation(threat.ship)
                and threat.ship~=primary and shipAlive(threat.ship) and not assignedTargets[signature] then
                local best,bestScore,available= nil,math.huge,0
                for _,g in ipairs(groups) do
                    local lead=g.units[1]
                    local previous=lead and self.AIOrderState[lead:getSignature()] or nil
                    local previousIsAssault=previous==nil or previous.mission=="PRIMARY" or previous.mission=="REGROUP"
                    local localThreatMatches=not shipValid(g.localThreat) or g.localThreat==threat.ship
                    if g.role=="bomber" and g.assaultReserved and g.target==nil and not g.defending
                        and not assignedGroups[g.id] and not g.luring and not g.probing and not g.screen
                        and not g.hardLocalThreat and localThreatMatches and previousIsAssault then
                        local match=self:AIRoleMatch(lead,threat.ship)
                        if match>=.2 then
                            available=available+1
                            local score=responseTime(g,threat.ship)/math.max(.1,match)
                            if g.committed then score=score+100000 end
                            if best==nil or score<bestScore or (score==bestScore and g.id<best.id) then
                                best=g; bestScore=score
                            end
                        end
                    end
                end
                -- A non-immediate response must leave one bomber wing on the
                -- strategic strike. Immediate weapon-range threats can use
                -- the last available wing; the emergency path handles hits.
                if best and (threat.urgent or available>1) then
                    best.target=threat.ship; best.mission="INTERCEPT"
                    best.defending=true; best.capitalSuppression=true
                    assignedGroups[best.id]=true; assignedTargets[signature]=true; activeWings=activeWings+1
                end
            end
        end
    end
    table.sort(groups,function(a,b)
        if a.screen~=b.screen then return a.screen end
        local ad=responseTime(a,station); local bd=responseTime(b,station)
        if ad~=bd then return ad<bd end
        return a.id<b.id
    end)
    local bomberAnchor=nil
    for _,g in ipairs(groups) do
        if g.role=="bomber" and g.assaultReserved and not g.defending and not g.hardLocalThreat
            and not emergency and (g.target==nil or g.target==g.primary) and shipValid(g.primary) then
            if not bomberAnchor or g.value>bomberAnchor.value or (g.value==bomberAnchor.value and g.id<bomberAnchor.id) then
                bomberAnchor=g
            end
        end
    end
    local bomberEscort=nil
    if bomberAnchor and not emergency then
        bomberEscort=self:ChooseAIBomberEscort(groups,bomberAnchor,reserve,dv)
        if bomberEscort then
            -- An idle home screen can join the bomber's front without splitting the escort package.
            bomberEscort.primary=bomberAnchor.primary
            self.AIAssaultTargets[kind][bomberEscort.id]=bomberAnchor.primary:getSignature()
        end
    end
    -- front.assault is the strength the planner believes it can put on a front.
    -- At this point the wings the SCREEN fallback further down will retain at
    -- home carry no target and no mission, so the `not g.defending` test below
    -- silently absorbed them too: the homeguard was counted as striking power
    -- the same tick it was being promised to the home station, which biases
    -- rawCanPush (and therefore canPush, posture and the LOCAL_INFERIORITY
    -- regroup fallback) optimistic by exactly the reserve that stays home.
    -- Replay the same retention the SCREEN fallback performs - same sorted
    -- order, same (g.screen or not g.committed) test, same reserve/dv budget -
    -- and exclude those wings from assault weight. This is a no-op when no wing
    -- is retained, and it only ever lowers assault weight toward the truth.
    do
        local pendingDv=dv
        for _,g in ipairs(groups) do
            if g.target==nil and g~=bomberEscort and isScreen(g)
                and (g.screen or not g.committed) and pendingDv<reserve then
                g.homeguard=true
                pendingDv=pendingDv+g.value
            end
        end
    end
    local missionCounts={}; local actualDefenseValue=0; local offenseValue=0
    self.AIPushHistory=self.AIPushHistory or {}
    local history=self.AIPushHistory[kind] or {}; self.AIPushHistory[kind]=history
    local frontPlans={}
    for _,g in ipairs(groups) do
        if shipAlive(g.primary) then
            local id=g.primary:getSignature()
            local front=frontPlans[id] or {target=g.primary,assault=0,defense=0}; frontPlans[id]=front
            if not g.defending and not g.homeguard then front.assault=front.assault+g.value end
        end
    end
    for id,front in pairs(frontPlans) do
        for _,row in ipairs(self.StrategicThreatSnapshot) do
            if shipAlive(row.ship) and self:GetFactionKey(row.ship)==self:GetFactionKey(front.target)
                and not self:IsCommandStation(row.ship) and row.ship.Position:getDistance(front.target.Position)<=threatRadius then
                front.defense=front.defense+row.profile.value
            end
        end
        front.rawCanPush=front.defense<=front.assault/self:GetAIAssaultStrengthRatio()
        local push=history[id]
        if not push then push={accepted=front.rawCanPush}; history[id]=push
        elseif front.rawCanPush==push.accepted then push.pending=nil; push.pendingSince=nil
        elseif push.pending~=front.rawCanPush then push.pending=front.rawCanPush; push.pendingSince=now
        elseif now-push.pendingSince>=(doctrine.MinimumCommitmentSeconds or 8) then push.accepted=front.rawCanPush; push.pending=nil; push.pendingSince=nil end
        front.canPush=push.accepted
    end
    for id in pairs(history) do if not frontPlans[id] then history[id]=nil end end
    local primarySignature=shipValid(primary) and primary:getSignature() or -1
    local selected=frontPlans[primarySignature]
    local enemyDefense=selected and selected.defense or 0
    local rawCanPush=selected and selected.rawCanPush or false
    local canPush=selected and selected.canPush or false
    if not emergency and canPush then posture="OFFENSIVE" end
    -- Make one visible, low-cost fighter probe while the strike assets stay on
    -- the enemy station. The probe is deterministic (no RNG) and tightly paced;
    -- it is a feint, not an invisible unit or a second full assault wave.
    local activeFeint=false
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local previous=lead and self.AIOrderState[lead:getSignature()] or nil
        if previous and now<(previous.feintUntil or 0) then
            activeFeint=true
            g.feint=true
            if g.probing and g.target==nil and not shipValid(g.localThreat) then
                local feintTarget=self:FindShipBySignature(g.feintTargetSignature)
                if not shipAlive(feintTarget) or not canAutoEngage(self,lead,feintTarget) then feintTarget=primary end
                g.target=feintTarget; g.mission="FEINT"; g.feintUntil=previous.feintUntil
                g.feintTargetSignature=shipValid(feintTarget) and feintTarget:getSignature() or nil
            end
        end
    end
    if not activeFeint and doctrine.TauntEnabled~=false and not emergency and canPush
        and shipValid(primary) and assaultReservedValue>0 and now>=(self.AITauntNextAt[kind] or -math.huge) then
        local probe=nil; local probeCost=math.huge; local freeScreenValue=0
        for _,g in ipairs(groups) do
            if (g.role=="fighter" or g.role=="escort") and not g.screen and not g.assaultReserved
                and not g.committed and g.target==nil and not shipValid(g.localThreat)
                and g.minHull>=(doctrine.TauntMinHullFraction or .75) then
                freeScreenValue=freeScreenValue+g.value
                local speed=math.max(1,math.abs(g.units[1].Physics.VelocityMax.z))
                local cost=g.value/speed
                if probe==nil or cost<probeCost or (cost==probeCost and g.id<probe.id) then
                    probe=g; probeCost=cost
                end
            end
        end
        if probe and freeScreenValue-probe.value>=math.max(0,reserve-dv) then
            local decoyTarget=self:ChooseAIFeintTarget(kind,primary,doctrine.TauntTargetRadius or threatRadius)
            if shipAlive(decoyTarget) then
                probe.target=decoyTarget; probe.mission="FEINT"; probe.feint=true
                probe.feintTargetSignature=decoyTarget:getSignature()
                -- Keep the probe window alive until the wing has reached the
                -- contested objective. An 18-second timer expired long before an
                -- enemy could react, leaving luring inert in full battles.
                local feintWindow=doctrine.TauntCommitSeconds or 18
                probe.feintUntil=now+math.max(feintWindow,responseTime(probe,decoyTarget)+feintWindow)
                self.AITauntNextAt[kind]=now+(doctrine.TauntCooldownSeconds or 90)
            end
        end
    end
    local assaultAnchors={}
    for _,g in ipairs(groups) do
        if not g.defending and (g.role=="capital" or g.role=="heavy" or g.role=="juggernaut") then
            if g.primary then local id=g.primary:getSignature(); if not assaultAnchors[id] or g.value>assaultAnchors[id].value then assaultAnchors[id]=g end end
        end
    end
    local coverage={}
    for _,g in ipairs(groups) do if g.defending then local id=g.target:getSignature(); coverage[id]=(coverage[id] or 0)+g.value end end
    self:BuildAIOperations(kind,groups,station,now,threatValue,emergency)
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local primary=g.primary or primary
        local primarySignature=shipValid(primary) and primary:getSignature() or -1
        local front=frontPlans[primarySignature]
        local canPush=front and front.canPush or false
        local assaultAnchor=assaultAnchors[primarySignature]
        local previous=lead and self.AIOrderState[lead:getSignature()] or nil
        if previous and previous.mission=="LURE" and now>=(previous.lureUntil or 0)
            and not g.defending and not shipValid(g.localThreat) and not emergency and canPush and shipValid(primary) then
            g.target=primary; g.mission="PRIMARY"; g.expiredLure=true
        end
        -- Existing screens keep guarding the home station. Other reserved
        -- groups receive the strategic primary unless they have a hard local
        -- contact or this faction is in an emergency response.
        if g.target==nil and shipValid(primary) and not emergency and g.assaultReserved and not g.screen and not g.hardLocalThreat then
            g.target=primary; g.mission="PRIMARY"
        end
        if g.target==nil and g==bomberEscort then
            g.target=bomberAnchor.units[1]; g.mission="ESCORT"; g.escortBomber=true
        end
        if g.target==nil and isScreen(g) and dv<reserve and (g.screen or not g.committed) then g.target=station; dv=dv+g.value end
        if g.target==nil and not self:CanDamageBase(g.units[1]) then g.target=station; g.mission="SCREEN" end
        local target=g.target or primary or station
        local mission=g.mission or ((g.target~=nil or not shipValid(primary)) and "SCREEN" or "PRIMARY")
        local releasedDefense=g.defenseRetention and not g.defenseRetention.retained and not emergency
        local context={emergency=g.emergency==true,locked=g.defending==true or g.escortBomber==true or releasedDefense==true or g.luring==true or g.expiredLure==true,urgent=g.emergency==true,posture=posture,
            reason=g.capitalSuppression and "CAPITAL_THREAT_PREEMPTION"
                or g.trapping and "TRAP_LURE_PURSUIT" or g.luring and (g.lureReason or "LURE_UNDER_PRESSURE")
                or g.expiredLure and "LURE_COMPLETE_REJOIN_ASSAULT"
                or g.feint and (g.feintTargetSignature~=primarySignature and "TAUNT_DECOY" or "TAUNT_PROBE")
                or g.escortBomber and "ESCORT_BOMBER_STRIKE" or g.defending and "DEFEND_BASE"
                or releasedDefense and g.defenseRetention.reason or nil,
            protected=g.defending and station:getSignature() or nil,
            assaultPrimarySignature=primarySignature,
            feintUntil=g.feintUntil,lureUntil=g.lureUntil,
            feintTargetSignature=g.feintTargetSignature}
        if mission=="INTERCEPT" and not g.defending then
            -- Coverage throttling is for ordinary contacts. A hostile inside
            -- the hard engagement radius must not be ignored just because
            -- other groups were assigned to it from farther away.
            if not g.hardLocalThreat and (coverage[target:getSignature()] or 0)>self:AIProfile(target).value*1.8 then
                local chosen=self:ChooseAILocalThreat(g,coverage)
                if shipValid(chosen) then target=chosen else target=station; mission="SCREEN" end
            end
            local previous=self.AIOrderState[g.units[1]:getSignature()]
            if g.hardLocalThreat and (not previous or previous.mission=="PRIMARY") then
                context.emergency=true; context.reason="INTERCEPT_IMMEDIATE_THREAT"
            elseif previous and previous.mission=="INTERCEPT" then
                local old=self:FindShipBySignature(previous.targetSignature)
                if shipValid(old) and now-previous.assignedAt>=(doctrine.LocalTargetRetentionSeconds or 8)
                    and g.units[1].Position:getDistance(target.Position)<g.units[1].Position:getDistance(old.Position)*(1-(doctrine.RetargetImprovementRatio or .25)) then
                    context.locked=true
                end
            end
        end
        local lead=g.units[1]; local friend,enemy=self:AILocalStrength(lead,lead.Position,doctrine.LocalStrengthRadius or 4500,false)
        local retreat=self.AIRetreatUntil[g.id] or -1
        local previous=self.AIOrderState[lead:getSignature()]
        local feinting=mission=="FEINT" or g.probing==true
            or (previous and now<(previous.feintUntil or 0))
        local pursuing=feinting and self:FindAIGroupTargeter(g,kind,localRadius) or nil
        if feinting and not g.luring and not g.defending and not emergency and shipValid(g.localThreat)
            and (enemy>math.max(1,friend)*(doctrine.LureForceRatio or 1.30) or shipValid(pursuing)) then
            g.luring=true; g.lureForceRatio=enemy/math.max(1,friend)
            g.lureReason=shipValid(pursuing) and "PURSUER_LOCKED" or "LOCAL_FORCE_DISADVANTAGE"
            -- Hold the withdrawal long enough to reach friendly defenses and
            -- give their screen one commitment window to catch pursuers.
            local returnAndTrap=responseTime(g,station)+(doctrine.DefenseTargetCommitmentSeconds or 18)
            g.lureUntil=now+math.max(doctrine.LureDurationSeconds or 18,returnAndTrap)
        end
        -- Break off as a unit only when a real share of the wing is hurt.
        -- g.minHull alone is the group-wide minimum, so one mauled escort used
        -- to recall the entire formation; a lone hull still breaks off
        -- (damagedFraction 1.0) and so does a wing that is mostly shot up.
        if not critical and g.minHull<=(doctrine.RetreatHullFraction or .22)
            and g.damagedFraction>=(doctrine.RetreatDamagedShipFraction or .75)
            and enemy>friend and not g.defending then
            retreat=now+(doctrine.RetreatCommitSeconds or 25); self.AIRetreatUntil[g.id]=retreat
        end
        if g.luring and now<(g.lureUntil or 0) and not g.defending then
            target=station; mission="LURE"; context.locked=true
            -- The lure is the SAME decoy continuing, so the feint window has to
            -- span it. Clearing feintUntil here ended the decoy's life while
            -- the wing was still baiting: the `g.probing` restore and the
            -- `activeFeint` test above both re-derive the decoy flag from
            -- previous.feintUntil, so the next tick stopped counting this wing
            -- as a decoy, the TACTIC record lost its TAUNT_DECOY identity, and
            -- - because a lure can outlast TauntCooldownSeconds (g.lureUntil is
            -- driven by responseTime(g,station), not by LureDurationSeconds) -
            -- the taunt launcher was free to start a SECOND decoy while the
            -- first was still in the field. Carry the window to the end of the
            -- lure so one taunt is one decoy.
            context.feintUntil=math.max(g.feintUntil or 0,g.lureUntil or 0)
            context.feintTargetSignature=g.feintTargetSignature
            context.reason=g.lureReason or "LURE_UNDER_PRESSURE"; context.lureUntil=g.lureUntil
        elseif not critical and retreat>now and not g.defending then
            target=station; mission="RETREAT"; context.locked=true; context.reason="RETREAT"
        elseif not g.defending and not g.armed and g.ordnance and not g.ordnanceLoaded then
            -- Only a genuinely dry group retreats. A capital that lost its
            -- turrets has no surviving ordnance bank at all and must keep its
            -- objective instead of being locked into RETREAT for the battle.
            target=station; mission="RETREAT"; context.locked=true; context.reason="WEAPONS_DISABLED"
        elseif not g.defending and (g.role=="support" or g.role=="transport") then
            target=assaultAnchor and assaultAnchor.units[1] or station; mission="ESCORT"; context.locked=true; context.reason="ESCORT_HIGH_VALUE_UNIT"
        -- A weak front-wide ratio means the whole fleet lacks a push, not
        -- that every healthy wing at every position should retreat to its base.
        -- Regroup only this wing when its own local radius is overwhelmed.
        elseif mission=="PRIMARY" and not canPush and not g.committed
            and enemy>math.max(1,friend)*(self.Config.Station.FleetService.DisadvantageRatio or 2) then
            target=assaultAnchor and assaultAnchor.units[1] or station
            if target:getSignature()==lead:getSignature() then target=station end
            mission="REGROUP"; context.locked=true; context.reason="LOCAL_INFERIORITY"
        elseif mission=="PRIMARY" and assaultAnchor and assaultAnchor~=g and isScreen(g) and not g.screen and not g.assaultReserved then
            target=assaultAnchor.units[1]; mission="ESCORT"; context.reason="SUPPORT_ASSAULT"; context.protected=target:getSignature()
        elseif mission=="PRIMARY" and #g.units>1 and g.spread>(doctrine.RegroupDistance or 2600) and not g.hardLocalThreat then
            target=station; mission="REGROUP"; context.locked=true; context.reason="FORMATION_RECOVERY"
        end
        if mission=="PRIMARY" and emergency and not critical and not g.defending then context.locked=true end
        if mission=="INTERCEPT" and not g.defending and shipValid(g.localThreat)
            and shipValid(target) and target:getSignature()==g.localThreat:getSignature() then
            local previous=self.AIOrderState[lead:getSignature()]
            context.localEngageOverride=not previous or previous.mission~="INTERCEPT"
            if context.localEngageOverride and not context.reason then context.reason="LOCAL_ENGAGEMENT" end
        end
        target,mission=self:ApplyAIOperationOrder(g,target,mission,context,station,now,coverage)
        target,mission=self:ApplyAssaultObjectiveLock(g,target,mission,context)
        if self:IsCommandStation(target) and canAutoEngage(self,lead,target) and not self:CanDamageBase(lead) then
            target=station; mission="SCREEN"; context.locked=true; context.reason="UNIT_CANNOT_DAMAGE_BASE"
        end
        mission=self:CommitAIGroup(g,target,mission,station,context,now,force)
        missionCounts[mission]=(missionCounts[mission] or 0)+#g.units
        if mission=="PRIMARY" or mission=="ESCORT" then offenseValue=offenseValue+g.value else actualDefenseValue=actualDefenseValue+g.value end
        if canAutoEngage(self,lead,g.target) then local id=g.target:getSignature(); coverage[id]=(coverage[id] or 0)+g.value end
    end
    if self.CombatTelemetryEnabled then
        self:EmitAICohesion(kind,groups,station,primary,now)
        self:EmitContestRecord(kind,groups,station,primary,now)
    end
    if self.CombatTelemetryEnabled then
        self.AIPlanTelemetry[kind]={
            time=now,
            primarySignature=shipValid(primary) and primary:getSignature() or nil,
            primaryName=shipValid(primary) and primary.Name or "NONE",
            threatCount=#threats,
            threatValue=threatValue,
            urgent=urgent,
            critical=critical,
            emergency=emergency,
            groups=#groups,
            totalValue=totalValue,
            screenEligibleValue=screenEligibleValue,
            reserve=reserve,
            defenseValue=actualDefenseValue,
            offenseValue=offenseValue,
            -- 's' is the SummarizeAI summary, which does not exist yet: this
            -- runs before SummarizeAI and is per-faction. Count from the group
            -- builder's own tallies instead of dereferencing a nil global.
            -- Serviced and player-held ships are owned but deliberately
            -- unplanned, so they must be subtracted before reporting idle.
            idle=math.max(0,ownedCount-plannedCount-servicingCount-playerControlledCount),
            servicing=servicingCount,
            playerControlled=playerControlledCount,
            posture=posture,
            enemyDefenseValue=enemyDefense,
            canPush=canPush,
            rawCanPush=rawCanPush,
            assaultReserveValue=assaultReserveValue,
            assaultReservedValue=assaultReservedValue,
            missionCounts=missionCounts,
        }
    end
    if ownsSnapshot then
        self.StrategicThreatSnapshot=nil; self.AIShipIndex=nil; self.AIProfileIndex=nil
        self.AITargetedBy=nil; self.AISpatialGrid=nil; self.AILocalCache=nil
    end
end
