-- AI group commitment: combat rally and CommitAIGroup.
return function(RTS, _shared)
local shipAlive, heavyRole, mobileRole, sig, distance, doctrine, health, valid = _shared.shipAlive, _shared.heavyRole, _shared.mobileRole, _shared.sig, _shared.distance, _shared.doctrine, _shared.health, _shared.valid
local canAutoEngage = _shared.canAutoEngage

function RTS:GetAICombatRally(g,target,mission,context)
    if g.role~='fighter' or #g.units~=1 or (mission~='PRIMARY' and mission~='INTERCEPT')
        or context.emergency or g.defending or g.feint or g.probing then return nil end
    local lead=g.units[1]
    if not self:IsAutomaticAIUnit(lead) or not shipAlive(target) or not canAutoEngage(self,lead,target) then return nil end
    local kind=self:GetFactionKey(lead); local nearest,best=nil,math.huge
    local hostiles=0; local radius=self.Config.AI.CohesionRadius or 3000
    local position=lead.Position; local snapshot=self.StrategicThreatSnapshot
    for _,contact in ipairs(snapshot or self:GetShipList()) do
        local row=snapshot and contact or nil; local other=row and row.ship or contact
        if shipAlive(other) and other~=lead and other.Name~=self.Config.ObserverShip then
            local d=position:getDistance(row and row.position or other.Position)
            local role=row and row.profile and row.profile.role or self:GetShipRole(other)
            if self:GetFactionKey(other)==kind and not self:IsCommandStation(other) and not self:IsStaticDefense(other)
                and not (self.FleetServices and self.FleetServices[sig(other)])
                and (mobileRole(role) or heavyRole(role) or role=='escort') then
                if d<=radius then return nil end
                if d<best then nearest,best=other,d end
            elseif d<=radius and canAutoEngage(self,lead,other) then hostiles=hostiles+1 end
        end
    end
    local role=self:GetShipRole(target)
    if not self:IsCommandStation(target) and not heavyRole(role) and hostiles<=1 then return nil end
    return nearest or self:GetFactionCommandShip(kind)
end

function RTS:CommitAIGroup(g,target,mission,station,context,now,force)
    local rally=self:GetAICombatRally(g,target,mission,context)
    if shipAlive(rally) then
        target=rally; mission='REGROUP'
        context.locked=true; context.reason='REJOIN_FLEET'; context.destination=nil; context.subsystem=nil; context.subsystemIndex=nil
    end
    -- PrepareAIGroups normally decides this and owns the sampling counter.
    -- Re-deriving the flag here would advance that counter a second time and
    -- halve the effective rate for groups routed through both paths.
    --
    -- The fallback exists because PrepareAIGroups and CommitAIGroup are only
    -- ordered by convention: every production caller (UpdateFactionStrategicPlan)
    -- prepares first, but a group arriving without a prepared flag would
    -- otherwise silently lose DetailedDecisionTelemetry - a flag that used to be
    -- honoured here regardless of how the group got here. The fallback
    -- deliberately does NOT advance the sampling counter, so the 1-in-N rate
    -- stays exact whether or not it is taken.
    local includeDecisionDetails
    if g.recordCandidates~=nil then
        includeDecisionDetails=g.recordCandidates
    else
        includeDecisionDetails=self.CombatTelemetryEnabled and self.Config.AI.DetailedDecisionTelemetry==true
    end
    if includeDecisionDetails then g.candidates=g.candidates or {} else g.candidates=nil end
    -- Adds a scored objective to the recorded ranking, once.
    --
    -- Identity, not signature: the retain path rebinds `chosen` to the row
    -- scored for the incumbent, so the SAME table would otherwise be appended
    -- twice, while the row scored for the challenger - the option actually
    -- rejected - would never be appended at all. The candidate set then held the
    -- incumbent twice and no entry for the challenger, which is the row a reader
    -- needs most. The set has to be a set.
    local function appendCandidate(list,row)
        if list==nil or row==nil then return end
        for _,existing in ipairs(list) do if existing==row then return end end
        list[#list+1]=row
    end
    local lead=g.units[1]; local previous=self.AIOrderState[sig(lead)]
    local primarySignature=context.assaultPrimarySignature
    local assaultStartedAt=now
    if previous and (previous.mission=='PRIMARY' or previous.mission=='REGROUP')
        and (previous.assaultPrimarySignature==nil or previous.assaultPrimarySignature==primarySignature) then
        assaultStartedAt=previous.assaultStartedAt or previous.assignedAt or now
    end
    local old=previous and self:FindShipBySignature(previous.targetSignature)
    local chosen=self:ScoreAIObjective(g,target,mission,context,nil,includeDecisionDetails)
    -- The row scored for the objective THIS decision proposed, kept so it can be
    -- recorded even when the retain gate throws it away. See appendCandidate.
    local challengerCandidate=chosen
    -- DECISION.score is the score of the objective the group was actually
    -- committed to. On a RETAINED decision that is the INCUMBENT's score, not
    -- the challenger's: line ~632 rebinds chosen=current before the record is
    -- built. Capture the challenger's own score here, before any rebind, so the
    -- record can carry both and name which one `score` is. Read naively the old
    -- record inverts the explanation of every retention - a tool reports the AI
    -- "choosing" a sentry by quoting the score of the capital it declined to
    -- leave. `score` keeps its meaning (the committed objective's score) so the
    -- four analysis tools stay valid; `scoreIsChallenger` says whether that
    -- committed objective is also the one this decision proposed.
    local challengerScore=chosen.score
    local age=previous and now-previous.assignedAt or 0; local switchingCost=doctrine(self).ObjectiveSwitchCost or 25
    local emergency=context.emergency==true; local retained=false; local reason=chosen.reason
    local observation=self.AIObservations and self.AIObservations[sig(lead)]
    local stale=observation and observation.stalled and observation.objective==sig(old)
    local changedFront=previous and previous.mission=='PRIMARY' and mission=='PRIMARY'
        and self:IsCommandStation(old) and sig(target)==primarySignature and sig(old)~=primarySignature
    -- OPERATION MEMBERSHIP COMMITMENT. Off unless
    -- Station.AI.Doctrine.OperationCommitmentEnabled, so this block is inert by
    -- default.
    --
    -- ApplyAIOperationOrder (fs2rts_operations.lua:257) sets context.locked=true
    -- for every operation member it does not explicitly release, and the gate
    -- below requires `not context.locked`. Measured, that makes
    -- MinimumCommitmentSeconds dead code for the 67% of decisions that are
    -- operation members: the operation re-derives a target from
    -- ChooseAIOperationTarget every StrategicOrderInterval and the group's
    -- target follows whichever defender last scored highest, which is the
    -- mechanism behind 23,686 order transitions at 15.3 s/order in the broken
    -- batch against 6,495 at 22.8 s in the baseline.
    --
    -- This exemption is deliberately narrow. It applies only when the mission is
    -- UNCHANGED, so the phase machine (ASSEMBLE -> APPROACH -> ENGAGE ->
    -- EXPLOIT -> WITHDRAW) keeps its exact cadence and a reserve release,
    -- flank pin, lure or preemption dispatch is never delayed. It still
    -- requires the old target to be live, hostile and scoring, so a dead or
    -- superseded objective is dropped immediately.
    local operationCommit=0
    if context.operation and previous and previous.mission==mission and mission~=""
        and doctrine(self).OperationCommitmentEnabled==true then
        operationCommit=doctrine(self).OperationCommitmentSeconds or 24
    end
    -- A destroyed ship can remain a valid engine handle long enough for the
    -- native order cache to retain it. Dead targets must be released so a
    -- decoy can safely fall back to the primary objective (and defenders can
    -- immediately move to the next live threat).
    if previous and valid(old) and health(old)>0
        and (canAutoEngage(self,lead,old) or self:GetFactionKey(old)==self:GetFactionKey(lead))
        and (previous.targetSignature~=sig(target) or previous.mission~=mission)
        and not emergency and (not context.locked or operationCommit>0)
        and not context.localEngageOverride and not changedFront then
        local current=self:ScoreAIObjective(g,old,previous.mission,nil,nil,includeDecisionDetails)
        appendCandidate(g.candidates,current)
        local validCurrent=current.score>0 and not stale
        if previous.mission=='INTERCEPT' and distance(lead,old)>self.Config.AI.LocalEngageRadius*1.5 then validCurrent=false end
        if previous.mission=='RETREAT' or previous.mission=='REGROUP' then validCurrent=false end
        local hold=math.max(doctrine(self).MinimumCommitmentSeconds or 8,operationCommit)
        if validCurrent and (age<hold or chosen.score<current.score+switchingCost) then
            target=old; mission=previous.mission; chosen=current; retained=true
            reason=operationCommit>0 and 'OPERATION_RETAINED' or 'OBJECTIVE_RETAINED'
        end
    end
    if stale and not retained then reason='OBJECTIVE_NO_PROGRESS' end
    if changedFront then reason='CAMPAIGN_FRONT_CHANGED' end
    g.target=target; g.mission=mission; g.reason=reason
chosen.reason=reason
    -- Record BOTH sides of the comparison. On a retained decision `chosen` is
    -- the incumbent's row and the proposed objective's own row is only reachable
    -- through challengerCandidate, so without this the ranking would omit the
    -- rejected option entirely. appendCandidate dedupes, so a non-retained
    -- decision still records its winner exactly once.
    appendCandidate(g.candidates,challengerCandidate)
    appendCandidate(g.candidates,chosen)
    -- Annotate the recorded ranking so one record answers "what did it choose,
    -- what else was on the table, and by how much". class and role are the
    -- candidate target's, resolved here because ScoreAIObjective scores by
    -- signature and does not otherwise carry the hull's identity into the row.
    --
    -- The roster vocabulary (tier, cost, selectionWeight, probability) belongs
    -- to the production picker in fs2rts_ai_production.lua and is NOT emitted
    -- here: objective scoring is deterministic, not a weighted draw, so those
    -- numbers would be invented. AI_BUILD_DECISION already carries the real
    -- ones. `selected` marks the committed objective; on a retained decision
    -- that is the incumbent, which is why scoreIsChallenger is false there.
    --
    -- candidateCountTotal is the size of the UNTRUNCATED set. The list itself is
    -- only the candidates this decision path scored, so a consumer must not read
    -- a short list as "the AI considered nothing else".
    if g.candidates then
        local committed=sig(target)
        for _,candidate in ipairs(g.candidates) do
            local signature=type(candidate.target)=='number' and candidate.target or nil
            local candidateTarget=signature~=nil and self:FindShipBySignature(signature) or nil
            if valid(candidateTarget) then
                candidate.class=candidateTarget.Class and candidateTarget.Class.Name or nil
                candidate.role=self:GetShipRole(candidateTarget)
            end
            candidate.selected=signature~=nil and signature==committed or false
        end
    end
    local candidateCountTotal=g.candidates and #g.candidates or 0
    local ids={}; local results={}
    local orderLabel='AI '..(context.reason or mission):gsub('_',' ')..': '..(context.destination and context.operationTargetName or target.Name)
    local formationSlots=context.destination and self:BuildAIFormationSlots(g,mission,context) or nil
    for _,ship in ipairs(g.units) do
        local id=sig(ship); ids[#ids+1]=id; local state=self.AIOrderState[id]
        self.AIStats.decisions=self.AIStats.decisions+1
        local point=formationSlots and formationSlots[id] or context.destination
        local options=context
        if point~=context.destination then options=setmetatable({destination=point},{__index=context}) end
        local samePoint=not point and not (state and state.destination)
            or point and state and state.destination and point:getDistance(state.destination)<100
        if not force and state and state.targetSignature==sig(target) and state.mission==mission
            and samePoint and state.subsystemIndex==context.subsystemIndex then
            self.AIStats.retained=self.AIStats.retained+1; results[tostring(id)]='ORDER_UNCHANGED'
        else
            local ok=self:IssueStrategicOrder(ship,target,orderLabel,mission,now,force,options)
            results[tostring(id)]=ok and 'ORDER_ACCEPTED' or 'ORDER_REJECTED'
        end
        state=self.AIOrderState[id]
        if state and state.targetSignature==sig(target) and state.mission==mission then
            state.label=orderLabel
            state.reason=reason; state.score=chosen.score; state.confidence=chosen.confidence
            state.group=g.id; state.role=g.role; state.posture=context.posture; state.protected=context.protected
            state.emergency=emergency; state.switchingCost=switchingCost
            state.operation=context.operation; state.operationPhase=context.operationPhase
            state.feintUntil=context.feintUntil or (mission=='FEINT' and state.feintUntil) or nil
            state.feintTargetSignature=context.feintTargetSignature
                or (mission=='FEINT' and sig(target)) or nil
            state.lureUntil=mission=='LURE' and (context.lureUntil or state.lureUntil) or nil
            -- Native orders may change between PRIMARY and REGROUP. Their
            -- assignedAt timestamps cannot also measure one assault's age.
            local assaultPhase=primarySignature and (mission=='PRIMARY' or mission=='REGROUP')
            state.assaultPrimarySignature=assaultPhase and primarySignature or nil
            state.assaultStartedAt=assaultPhase and assaultStartedAt or nil
        end
    end
    -- Group geometry and the command-arena frame. Without these the telemetry
    -- records what each group decided but not where it was, so no location or
    -- behavioural heat map can be reconstructed from a headless run.
    local centroidX,centroidZ,count=0,0,0
    for _,ship in ipairs(g.units or {}) do
        if shipAlive(ship) and ship.Position then
            centroidX=centroidX+ship.Position.x; centroidZ=centroidZ+ship.Position.z; count=count+1
        end
    end
    if count>0 then centroidX=centroidX/count; centroidZ=centroidZ/count end
    local arena=self.GetCommandArenaHalfExtent and self:GetCommandArenaHalfExtent() or nil
    -- No IsAITraceActive() guard here, deliberately. The record is consumed by
    -- anything that intercepts EmitAIEvent - a test sink replaces it with a
    -- function and asserts on the geometry fields, and test_service.py does the
    -- same. Gating construction on "will this reach disk" is therefore wrong:
    -- the consumer is not always the file. The ~40 field writes are cheap next
    -- to the per-frame ship scans elsewhere; the real cost was in the emitters
    -- that walk the world to build discarded rows, not in this literal.
    local record={faction=self:GetFactionKey(lead),group=g.id,ships=ids,role=g.role,posture=context.posture,target=sig(target),mission=mission,
        reason=reason,emergency=emergency,previousAge=age,switchingCost=switchingCost,score=chosen.score,
        -- `score` above is the COMMITTED objective's score. On a retained
        -- decision that is the incumbent, and the rejected challenger's score
        -- is a different number. Publishing both is what lets the replay tool
        -- print an honest margin instead of inverting the explanation.
        -- scoreIsChallenger=false marks the retained case; true means the
        -- committed objective is also the one this decision proposed.
        challengerScore=challengerScore,scoreIsChallenger=not retained,
        operation=context.operation,operationPhase=context.operationPhase,subsystem=context.subsystemIndex,
        targetName=valid(target) and target.Name or nil,
        targetClass=valid(target) and target.Class.Name or nil,
        targetFaction=valid(target) and self:GetFactionKey(target) or nil,
        targetRole=valid(target) and self:GetShipRole(target) or nil,
        assaultReserved=g.assaultReserved==true,localEngageOverride=context.localEngageOverride==true,
        localThreatSignature=valid(g.localThreat) and sig(g.localThreat) or nil,
        localThreatDistance=valid(g.localThreat) and distance(lead,g.localThreat) or -1,
        localThreatSource=g.localThreatSource,hardLocalThreat=g.hardLocalThreat==true,
        bomberTargeterSignature=valid(g.targetedBy) and sig(g.targetedBy) or nil,
        escortBomber=g.escortBomber==true,luring=g.luring==true,
        capitalSuppression=g.capitalSuppression==true,
        -- Set only when ApplyAssaultObjectiveLock (fs2rts_strategy.lua) actually
        -- vetoed a diversion, so it is absent on every record when the doctrine
        -- flags are off - the same "absent means off" convention the candidate
        -- fields below use. Carries the rejected signature, the station it was
        -- held back to, and the two measurements that decided it, so a batch can
        -- be partitioned into reactive / corridor / neither without re-running.
        assaultLock=g.assaultLock,
        candidates=g.candidates,results=results,spread=g.spread,protected=context.protected or -1,
        -- Size of the untruncated candidate set, so a sampled list is honestly
        -- labelled as partial rather than read as "nothing else was on the
        -- table". candidateSampleEvery=0 means the list is not sampled: it is
        -- complete, because DetailedDecisionTelemetry is on.
        --
        -- Both are emitted ONLY when a candidate list was actually recorded.
        -- Publishing them unconditionally cost 1.51 MB/match (3.4% of total
        -- telemetry volume, measured on instrfix-a1) to say "absent" on 17,805
        -- records per match. A default-off flag that costs nothing when off is
        -- worth more than an explicit false on every record: with the flag off,
        -- candidates is absent from EVERY decision, so "no candidate data in
        -- this batch" is already unambiguous without a per-record marker.
        candidateCountTotal=includeDecisionDetails and candidateCountTotal or nil,
        candidateSampleEvery=includeDecisionDetails
            and ((self.Config.AI.DetailedDecisionTelemetry~=true)
                and self.Config.AI.SampledHeavyDecisionSampleEvery or 0) or nil,
        defenseRetention=g.defenseRetention,
        -- spatial
        unitCount=count,centroidX=centroidX,centroidZ=centroidZ,
        leadX=lead.Position and lead.Position.x or nil,leadZ=lead.Position and lead.Position.z or nil,
        targetX=valid(target) and target.Position and target.Position.x or nil,
        targetZ=valid(target) and target.Position and target.Position.z or nil,
        stationX=station and station.Position and station.Position.x or nil,
        stationZ=station and station.Position and station.Position.z or nil,
        arenaHalfExtent=arena,
        formation=g.formation or self:ChooseAIFormation(g.role,mission),
        slotCount=g.slotCount}
    self:EmitAIEvent('DECISION',record,now)
    if previous==nil or previous.mission~=mission
        or (reason=='CAPITAL_THREAT_PREEMPTION' and previous.targetSignature~=sig(target)) then
        if mission=='FEINT' or mission=='LURE' or mission=='TRAP'
            or reason=='CAPITAL_THREAT_PREEMPTION' then
            self:EmitAIEvent('TACTIC',{faction=self:GetFactionKey(lead),group=g.id,role=g.role,
                mission=mission,target=sig(target),reason=reason,
                targetName=valid(target) and target.Name or nil,
                targetClass=valid(target) and target.Class.Name or nil,
                targetRole=valid(target) and self:GetShipRole(target) or nil,
                targetDistance=valid(target) and distance(lead,target) or nil,
                forceRatio=g.lureForceRatio or nil},now)
        end
    end
    return mission
end
end
