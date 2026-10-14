-- AI execution observation: native objective status, ObserveAIExecution and hit records.
return function(RTS, _shared)
local distance, doctrine, sig, valid, canAutoEngage = _shared.distance, _shared.doctrine, _shared.sig, _shared.valid, _shared.canAutoEngage

function RTS:GetNativeObjectiveStatus(ship,state)
    local native=ship.Target; local target=self:FindShipBySignature(state.targetSignature)
    if not valid(target) then return 'TARGET_INVALID',false end
    if state.subsystemIndex then
        local sub=target[state.subsystemIndex]
        if not sub:isValid() or sub.HitpointsLeft<=0 then return 'OBJECTIVE_COMPLETE',false end
    end
    if state.destination then
        if ship.Position:getDistance(state.destination)<=(state.arrivalDistance or 900) then return 'OBJECTIVE_COMPLETE',true end
        local entry=self.MoveWaypoints[sig(ship)]
        local orders=ship.Orders
        for i=1,#orders do
            if orders[i]:isValid() and orders[i]:getType()==ORDER_WAYPOINTS_ONCE
                and entry and sig(orders[i].Target)==sig(entry.waypoint) then return 'NATIVE_MOVEMENT_GOAL',true end
        end
        return 'NATIVE_ORDER_PREEMPTED',false
    end
    -- A pursuit is the same ORDER_WAYPOINTS_ONCE primitive aimed at the pooled
    -- move waypoint, but issued by IssuePursuitOrder (fs2rts_strategy/assault_pooling.lua:87)
    -- instead of the destination branch, so state.destination stays nil and
    -- state.pursuitAt marks it. Without this branch the order fell through to
    -- the hostile path below, which expects ORDER_ATTACK, never matched, and
    -- reported NATIVE_ORDER_PREEMPTED every single cycle. That is a permanent
    -- false positive: ValidateStrategicOrderTargets reads that status as
    -- "preempted" and force-reissues the order (the `local repair=` clause in
    -- ValidateStrategicOrderTargets, fs2rts_strategy.lua) on every
    -- NativeTargetRepairInterval, fighting RefreshAIPursuit for the same goal
    -- and inflating the NATIVE_ORDER_PREEMPTED mismatch count in SummarizeAI.
    if state.pursuitAt then
        local entry=self.MoveWaypoints and self.MoveWaypoints[sig(ship)]
        if valid(entry and entry.waypoint) then
            if ship.Position:getDistance(entry.waypoint.Position)<=(state.arrivalDistance or 900) then
                return 'OBJECTIVE_COMPLETE',true
            end
            local orders=ship.Orders
            local orderCount=orders and #orders or 0
            for i=1,orderCount do
                if orders[i]:isValid() and orders[i]:getType()==ORDER_WAYPOINTS_ONCE
                    and sig(orders[i].Target)==sig(entry.waypoint) then return 'NATIVE_MOVEMENT_GOAL',true end
            end
        end
        -- No waypoint order installed. RefreshAIPursuit re-anchors on its own
        -- cadence, so this is a gap between anchors, not a preemption: report
        -- the goal as absent without telling the repair path to reissue it.
        return 'NATIVE_MOVEMENT_PENDING',false
    end
    local goalPresent=nil
    local hostile=canAutoEngage(self,ship,target)
    local movement=state.mission=='RETREAT' or state.mission=='LURE'
    local expected=hostile and ORDER_ATTACK or (movement and ORDER_FLY_TO or ORDER_GUARD)
    local ok=pcall(function()
        local orders=ship.Orders
        if orders then
            goalPresent=false
            for i=1,#orders do
                local order=orders[i]
                if order:isValid() and sig(order.Target)==state.targetSignature and order:getType()==expected then
                    if not state.subsystemIndex or (order.TargetSubsystem:isValid()
                        and order.TargetSubsystem.Name==target[state.subsystemIndex].Name) then goalPresent=true; break end
                end
            end
        end
    end)
    if not ok then goalPresent=nil end
    if goalPresent==false then
        if movement and not hostile and state.arrivalDistance
            and distance(ship,target)<=state.arrivalDistance then return 'OBJECTIVE_COMPLETE',false end
        return 'NATIVE_ORDER_PREEMPTED',false
    end
    if not hostile then return movement and 'NATIVE_MOVEMENT_GOAL' or 'NATIVE_GUARD_GOAL',goalPresent end
    if not valid(native) then return 'NATIVE_TARGET_LOST',goalPresent end
    if native:getBreedName()~='Ship' then
        if native:getBreedName()=='Weapon' then
            return native.Team~=ship.Team and ship.Team:attacks(native.Team) and 'NATIVE_POINT_DEFENSE' or 'NATIVE_TARGET_FRIENDLY',goalPresent
        end
        return 'NATIVE_NONSHIP_TARGET',goalPresent
    end
    if sig(native)==state.targetSignature then return 'NATIVE_TARGET_ACQUIRED',goalPresent end
    if not canAutoEngage(self,ship,native) then return 'NATIVE_TARGET_FRIENDLY',goalPresent end
    local p=self:AIProfile(ship)
    if distance(ship,native)<=math.max(p.range,doctrine(self).HardEngageRadius or 1800)+(native.Radius or 0) then
        return 'NATIVE_LOCAL_ENGAGEMENT',goalPresent
    end
    return 'PLANNER_TARGET_MISMATCH',goalPresent
end

function RTS:ObserveAIExecution(now)
    if not self.AIStats then self:ResetCoordinatedAI() end
    for _,row in ipairs(self.StrategicThreatSnapshot or {}) do
        local ship=row.ship; local id=sig(ship); local state=self.AIOrderState[id]
        local previous=self.AIObservations[id]; local dt=previous and math.max(0,now-previous.time) or 0
        local target=state and self:FindShipBySignature(state.targetSignature)
        local d=valid(target) and distance(ship,target) or nil
        local p=self:AIProfile(ship); local native=sig(ship.Target)
        local status,goalPresent='NO_OBJECTIVE',nil
        if state then status,goalPresent=self:GetNativeObjectiveStatus(ship,state) end
        local same=previous and previous.objective==(state and state.targetSignature) and previous.assignedAt==(state and state.assignedAt)
        local closing=same and d and previous.distance and (previous.distance-d)/math.max(.001,dt) or 0
        -- A pursuit is ordered to a moving anchor AHEAD of its objective
        -- (IssuePursuitOrder, fs2rts_strategy/assault_pooling.lua:87), and RefreshAIPursuit
        -- re-issues that anchor every PursuitRefreshInterval. So the range to
        -- the objective goes flat the moment the pursuer is on the anchor, and
        -- progress judged only on range closure (closing>1) never fires: a
        -- healthy pursuit reads STALLED after NoProgressSeconds, and
        -- CommitAIGroup turns that into reason='OBJECTIVE_NO_PROGRESS' and
        -- refuses to retain the target (below: the `stale`/`validCurrent`
        -- checks), so the planner abandons an objective that is in fact being
        -- pursued. Measure progress against the anchor the AI actually handed
        -- over, and surface both numbers so the pursuit is observable rather
        -- than inferred.
        local pursuitRange,pursuitClosing=nil,0
        if state and state.pursuitAt then
            local entry=self.MoveWaypoints and self.MoveWaypoints[id]
            local waypoint=entry and entry.waypoint
            if valid(waypoint) then
                pursuitRange=distance(ship,waypoint)
                if same and previous.pursuitRange then
                    pursuitClosing=(previous.pursuitRange-pursuitRange)/math.max(.001,dt)
                end
            end
        end
        local hullLoss=previous and math.max(0,previous.hull-ship.HitpointsLeft) or 0
        local inRange=valid(target) and p.range>0 and d<=p.range+(target.Radius or 0)
        local hit=self.AIStats.hits[id]; local recentHit=hit and hit.hostileTime and now-hit.hostileTime<=6 or false
        local objectiveHit=recentHit and state and hit.hostileTarget==state.targetSignature and hit.hostileTime>=state.assignedAt
        local engaged=recentHit or (inRange and native==sig(target))
        local objectiveEngaged=objectiveHit or (inRange and native==sig(target)) or false
        local lastProgress=same and previous.lastProgress or now
        -- Re-anchoring the pursuit is itself forward motion: RefreshAIPursuit
        -- moved the goal to a new intercept point because the pair is still
        -- valid, which is evidence the objective is being pursued rather than
        -- abandoned. Without it a capital holding its anchor on a faster target
        -- never registers progress and is scored stalled.
        local pursuit=self.AIPursuit and self.AIPursuit[id]
        local anchorAdvanced=pursuit and state and state.pursuitAt
            and (pursuit.anchoredAt or 0)>(previous and previous.time or now)
        if closing>1 or pursuitClosing>1 or anchorAdvanced or objectiveHit then
            lastProgress=now
        end
    local stalled=state~=nil and canAutoEngage(self,ship,target) and now-lastProgress>(doctrine(self).NoProgressSeconds or 40) and not objectiveEngaged
        local mode=not state and 'IDLE' or state.mission=='LURE' and 'LURING'
            or state.mission=='RETREAT' and 'RETREATING'
            or state.mission=='REGROUP' and 'REGROUPING' or state.mission=='ESCORT' and 'SCREENING'
        or state.mission=='SCREEN' and not canAutoEngage(self,ship,target) and 'SCREENING'
            or engaged and 'ENGAGED' or stalled and 'STALLED' or 'APPROACHING'
        local o={time=now,objective=state and state.targetSignature,assignedAt=state and state.assignedAt,
            native=native,status=status,goalPresent=goalPresent,distance=d,closing=closing,hull=ship.HitpointsLeft,
            hullLoss=hullLoss,lastProgress=lastProgress,stalled=stalled,mode=mode,inRange=inRange,
            engaged=engaged,hitObserved=recentHit,
            pursuit=state~=nil and state.pursuitAt~=nil or false,
            pursuitRange=pursuitRange,pursuitClosing=pursuitClosing,anchorAdvanced=anchorAdvanced or false,
            unengaged=(previous and previous.unengaged or 0)+(engaged and 0 or dt),
            sampledSeconds=(previous and previous.sampledSeconds or 0)+dt,
            objectiveEngaged=same and previous.objectiveEngaged or false,
            engagementDelay=same and previous.engagementDelay or nil}
        if objectiveEngaged and state and not o.objectiveEngaged then o.engagementDelay=now-state.assignedAt; o.objectiveEngaged=true end
        if previous and native~=previous.native then self.AIStats.nativeChanges=self.AIStats.nativeChanges+1 end
        self.AIObservations[id]=o
        local kind=self:GetFactionKey(ship)
        self.AIStats.received[kind]=(self.AIStats.received[kind] or 0)+hullLoss
        if not previous or status~=previous.status or mode~=previous.mode then
            self:EmitAIEvent('EXECUTION',{ship=id,faction=kind,target=o.objective or -1,native=native,status=status,
                mode=mode,goalPresent=goalPresent==nil and 'unknown' or goalPresent,distance=d,closing=closing,
                pursuit=o.pursuit,pursuitRange=pursuitRange,pursuitClosing=pursuitClosing,anchorAdvanced=o.anchorAdvanced,
                effectiveRange=p.range,rangeConfidence=p.confidence,hitObserved=recentHit,hullLoss=hullLoss},now)
        end
    end
end

function RTS:RecordAIHit(source,target,sourceKind)
    if sourceKind=='PROJECTILE' and hv and hv.Weapon then source=self:GetWeaponCombatSource(hv.Weapon) end
    if not self.Enabled or self.SetupActive or self.PostBattleActive or not valid(source) or not valid(target) then return end
    if source:getBreedName()~='Ship' or target:getBreedName()~='Ship' then return end
    if not self.AIStats then self:ResetCoordinatedAI() end
    local id=sig(source); local hit=self.AIStats.hits[id] or {count=0}
    hit.count=hit.count+1; hit.time=mn.getMissionTime(); hit.target=sig(target)
    if self:AreEnemies(source,target) then
        hit.hostileTime=hit.time; hit.hostileTarget=hit.target
    elseif sourceKind~='PROJECTILE' then
        -- Unknown resolved beam damage cannot qualify a friendly-fire recovery.
        -- Projectile hull damage is measured by the pre/post collision hook.
        local record=self:GetUnitHistory(target)
        if record then
            record.friendlyDamageEpisode=true; record.serviceCitationEligible=false; record.recoveryRejoinPending=nil
        end
    end
    self.AIStats.hits[id]=hit
    -- Only build the event when a trace can receive it: this runs on every
    -- weapon/beam collision and EmitAIEvent would discard it anyway.
    if self:IsAITraceActive() and not self:AreEnemies(source,target) then
        local objective=self.AIOrderState[id]
        self:EmitAIEvent('FRIENDLY_HIT',{ship=id,target=sig(target),sourceName=source.Name,targetName=target.Name,
            faction=self:GetFactionKey(source),targetFaction=self:GetFactionKey(target),native=sig(source.Target),
            plannerTarget=objective and objective.targetSignature,mission=objective and objective.mission,
            sourceKind=sourceKind or 'UNKNOWN',evidence='weapon contact; resolved damage unknown'})
    end
end
end
