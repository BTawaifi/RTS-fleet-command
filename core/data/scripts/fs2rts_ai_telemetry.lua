-- AI trace, damage telemetry, final balance, mission focus.
local U = require "fs2rts_ai_util"
local shipAlive=require('fs2rts_util').shipAlive

return function(RTS)
-- Declared in the helpers' original order so upvalues resolve identically.
local valid, sig, clamp, distance, health, doctrine, mobileRole, heavyRole, balanceDefinition, json, newBaseDamageFaction, baseDamageBucketKey, baseDamageRows, baseDamageSummary, newCombatDamageFaction, FRIENDLY_FIRE_PAIR_LIMIT, combatDamageBucketKey, combatDamageRows, friendlyFireRows, combatDamageSummary
    = U.valid, U.sig, U.clamp, U.distance, U.health, U.doctrine, U.mobileRole, U.heavyRole, U.balanceDefinition, U.json, U.newBaseDamageFaction, U.baseDamageBucketKey, U.baseDamageRows, U.baseDamageSummary, U.newCombatDamageFaction, U.FRIENDLY_FIRE_PAIR_LIMIT, U.combatDamageBucketKey, U.combatDamageRows, U.friendlyFireRows, U.combatDamageSummary

-- Which station targets the On Ship Damage hooks cover is a mission-independent
-- fact: the hooks are engine-global and stay registered across a restart, so
-- ResetCoordinatedAI's per-mission re-zero of BaseDamageTelemetry would
-- otherwise leave hookCount at 0 while the engine is still delivering hits.
-- Keep the registration record in its own field so a reset cannot erase it.
local function recordBaseDamageHooks(self)
    local telemetry=self.BaseDamageTelemetry
    self.BaseDamageHookRecord={hookCount=telemetry.hookCount or 0,
        registeredTargets=telemetry.registeredTargets,
        registrationErrors=telemetry.registrationErrors}
end

function RTS:ResetCoordinatedAI()
    self.AIObservations={}; self.AIFactionHistory={}; self.AIDecisionHistory={}
    self.AIPushHistory={}
    self.AIAssaultTargets={}; self.AIProductionNeeds={}
    self.AIProductionEmergency={}
    self.AIOperations={}; self.AIHomeThreatHistory={}
    self.AITauntNextAt={}
    self.AIStats={decisions=0,retained=0,switches=0,reissued=0,nativeChanges=0,completed=0,losses={},hits={},received={}}
    self.AIPrimaryReview={}; self.AIRetreatUntil={}; self.AISummaryAt=-100
    self.AIFrameSampleAt=-100; self.AIShipIndex=nil; self.AIProfileIndex=nil
    self.AIDetailBuffer={}; self.AITraceSequence=0
    self.AIEconomyFlow={}; self.BalanceFinalEmitted=false
    self.BaseDamageTelemetry={hookCount=0,hitCount=0,registeredTargets={},registrationErrors={},intervalByFaction={},totalByFaction={}}
    self.CombatDamageTelemetry={registered=false,hitCount=0,intervalByFaction={},totalByFaction={}}
    -- Mission-scoped sample clocks behind the cohesion/contest cadence gates.
    -- mn.getMissionTime() restarts at 0, so a leftover sample from a long first
    -- mission makes now-last hugely negative and suppresses every COHESION and
    -- CONTEST record for the whole of the second one.
    self.AICohesionSampleAt={}; self.AIContestSampleAt={}; self.AIContestProgress={}
    -- 1-in-N sampler behind SampledHeavyDecisionTelemetry. Mission-scoped for
    -- the same reason the cohesion/contest clocks above are: it must not carry
    -- across a restart, or a leftover count from a long first mission makes the
    -- modulo land wherever it happens to and the second mission's heavy
    -- decisions are sampled at an arbitrary, unreproducible rate.
    self.AIHeavyDecisionSamples=0
    self.AILethalDamageByShip={}
    self.AIBaseHullSamples={}; self.AIBaseDamageSummaryAt=nil
end

function RTS:SupportsResolvedDamageTelemetry()
    if self.ResolvedDamageTelemetryAvailable~=nil then return self.ResolvedDamageTelemetryAvailable end
    local available=false
    if ba and type(ba.isEngineVersionAtLeast)=='function' then
        local ok,result=pcall(function() return ba.isEngineVersionAtLeast(26,1,0) end)
        available=ok and result==true
    end
    self.ResolvedDamageTelemetryAvailable=available
    if not available then
        self.ResolvedDamageTelemetryUnavailableReason='resolved damage hook unavailable on this engine build; station hull deltas remain available'
    end
    return available
end

function RTS:RegisterBaseDamageTelemetry()
    self.BaseDamageTelemetry=self.BaseDamageTelemetry or {hookCount=0,hitCount=0,registeredTargets={},registrationErrors={},intervalByFaction={},totalByFaction={}}
    if self.BaseDamageHooksRegistered then
        -- Same self-repair the CombatDamage sibling does at its early return:
        -- the hooks outlive the mission, so re-assert the registration record
        -- instead of leaving a re-zeroed table reporting hookCount=0 while the
        -- engine is still delivering hits into it.
        local record=self.BaseDamageHookRecord
        if record~=nil then
            self.BaseDamageTelemetry.hookCount=record.hookCount
            self.BaseDamageTelemetry.registeredTargets=record.registeredTargets
            self.BaseDamageTelemetry.registrationErrors=record.registrationErrors
        end
        return
    end
    self.BaseDamageHooksRegistered=true
    if not (self.Config.AI and self.Config.AI.ExperimentalDamageTelemetry==true) then
        self.BaseDamageTelemetry.unavailableReason='custom damage hook disabled'
        recordBaseDamageHooks(self); return
    end
    if not self:SupportsResolvedDamageTelemetry() then
        self.BaseDamageTelemetry.unavailableReason=self.ResolvedDamageTelemetryUnavailableReason
        recordBaseDamageHooks(self); return
    end
    local stations={
        {faction='BLUE',name=self.Config.CarrierShip},
        {faction='RED',name=self.Config.EnemyCommandShip},
        {faction='GOLD',name=self.Config.ThirdCommandShip},
    }
    for _,station in ipairs(stations) do
        local targetFaction,targetName=station.faction,station.name
        if type(targetName)=='string' and targetName~='' then
            local ok=engine.addHook('On Ship Damage',function()
                if not self.CombatTelemetryEnabled then return end
                local target=hv['Target']
                if not valid(target) or target.Name~=targetName or not self:IsCommandStation(target) then return end
                local attacker=hv['Attacker']
                local weaponClass=hv['WeaponClass'] or 'NON_WEAPON'
                local weaponSubtype=hv['WeaponSubtype'] or 'UNKNOWN'
                local sourceKind=hv['SourceKind'] or 'OTHER'
                local damageType=hv['DamageType'] or 'UNKNOWN'
                local ballistic=hv['Ballistic']==true
                local beamWeapon=hv['BeamWeapon']==true
                local attackerFaction=valid(attacker) and self:GetFactionKey(attacker) or 'UNKNOWN'
                if sourceKind=='BEAM' and beamWeapon and valid(attacker) and attacker:getBreedName()=='Ship'
                    and self:AreEnemies(target,attacker) then
                    self:RecordStationBeamHit(target,attacker,mn.getMissionTime(),'RESOLVED_DAMAGE')
                end
                local shieldDamage=math.max(0,tonumber(hv['ShieldDamage']) or 0)
                local hullDamage=math.max(0,tonumber(hv['HullDamage']) or 0)
                local telemetry=self.BaseDamageTelemetry
                local targetKey=self:GetFactionKey(target) or targetFaction
                local key=baseDamageBucketKey(target.Name,weaponClass,weaponSubtype,sourceKind,damageType,ballistic,beamWeapon,attackerFaction)
                for _,scope in ipairs({'intervalByFaction','totalByFaction'}) do
                    local factions=telemetry[scope]
                    local factionData=factions[targetKey]
                    if not factionData then factionData=newBaseDamageFaction(); factions[targetKey]=factionData end
                    factionData.hitCount=factionData.hitCount+1
                    factionData.shieldDamage=factionData.shieldDamage+shieldDamage
                    factionData.hullDamage=factionData.hullDamage+hullDamage
                    local row=factionData.weapons[key]
                    if not row then
                        row={targetName=target.Name,targetFaction=targetKey,weaponClass=weaponClass,weaponSubtype=weaponSubtype,
                            sourceKind=sourceKind,damageType=damageType,ballistic=ballistic,beamWeapon=beamWeapon,
                            attackerFaction=attackerFaction,hitCount=0,shieldDamage=0,hullDamage=0}
                        factionData.weapons[key]=row
                    end
                    row.hitCount=row.hitCount+1; row.shieldDamage=row.shieldDamage+shieldDamage; row.hullDamage=row.hullDamage+hullDamage
                end
                telemetry.hitCount=(telemetry.hitCount or 0)+1
            end,{['Target Ship']=targetName})
            self.BaseDamageTelemetry.registeredTargets[#self.BaseDamageTelemetry.registeredTargets+1]={
                faction=targetFaction,name=targetName,registered=ok==true}
            if ok then self.BaseDamageTelemetry.hookCount=self.BaseDamageTelemetry.hookCount+1
            else self.BaseDamageTelemetry.registrationErrors[#self.BaseDamageTelemetry.registrationErrors+1]=targetName end
        end
    end
    recordBaseDamageHooks(self)
end

function RTS:RegisterCombatDamageTelemetry()
    self.CombatDamageTelemetry=self.CombatDamageTelemetry or {registered=false,hitCount=0,intervalByFaction={},totalByFaction={}}
    if not (self.Config.AI and self.Config.AI.ExperimentalDamageTelemetry==true) then
        self.CombatDamageTelemetry.registrationError='custom damage hook disabled'
        return
    end
    if not self:SupportsResolvedDamageTelemetry() then
        self.CombatDamageTelemetry.registrationError=self.ResolvedDamageTelemetryUnavailableReason
        return
    end
    if self.CombatDamageHooksRegistered then
        self.CombatDamageTelemetry.registered=true
        return
    end
    self.CombatDamageHooksRegistered=true
    local ok=engine.addHook('On Ship Damage',function()
        if not self.CombatTelemetryEnabled then return end
        local target=hv['Target']
        if not valid(target) or not target.Class then return end
        local attacker=hv['Attacker']
        local attackerClass='UNKNOWN'
        if valid(attacker) and attacker:getBreedName()=='Ship' and attacker.Class then
            attackerClass=attacker.Class.Name
        end
        local targetClass=target.Class.Name
        local targetFaction=self:GetFactionKey(target) or 'UNKNOWN'
        local attackerFaction=valid(attacker) and self:GetFactionKey(attacker) or 'UNKNOWN'
        local weaponClass=hv['WeaponClass'] or 'NON_WEAPON'
        local weaponSubtype=hv['WeaponSubtype'] or 'UNKNOWN'
        local sourceKind=hv['SourceKind'] or 'OTHER'
        local damageType=hv['DamageType'] or 'UNKNOWN'
        local ballistic=hv['Ballistic']==true
        local beamWeapon=hv['BeamWeapon']==true
        local shieldDamage=math.max(0,tonumber(hv['ShieldDamage']) or 0)
        local hullDamage=math.max(0,tonumber(hv['HullDamage']) or 0)
        if shieldDamage<=0 and hullDamage<=0 then return end

        local lethalHit=hv['LethalHit']==true
        local targetSignature=sig(target)
        if lethalHit and self.AILethalDamageByShip[targetSignature]==nil then
            self.AILethalDamageByShip[targetSignature]={time=mn.getMissionTime(),attackerFaction=attackerFaction,
                attackerClass=attackerClass,weaponClass=weaponClass,weaponSubtype=weaponSubtype,
                sourceKind=sourceKind,damageType=damageType,beamWeapon=beamWeapon,ballistic=ballistic}
        end
        local telemetry=self.CombatDamageTelemetry
        local key=combatDamageBucketKey(targetClass,weaponClass,weaponSubtype,sourceKind,damageType,
            ballistic,beamWeapon,attackerFaction,attackerClass)
        for _,scope in ipairs({'intervalByFaction','totalByFaction'}) do
            local factions=telemetry[scope]
            local factionData=factions[targetFaction]
            if not factionData then factionData=newCombatDamageFaction(); factions[targetFaction]=factionData end
            factionData.hitCount=factionData.hitCount+1
            factionData.lethalHits=factionData.lethalHits+(lethalHit and 1 or 0)
            factionData.shieldDamage=factionData.shieldDamage+shieldDamage
            factionData.hullDamage=factionData.hullDamage+hullDamage
            local row=factionData.matchups[key]
            if not row then
                row={targetFaction=targetFaction,targetClass=targetClass,attackerFaction=attackerFaction,
                    attackerClass=attackerClass,weaponClass=weaponClass,weaponSubtype=weaponSubtype,
                    sourceKind=sourceKind,damageType=damageType,ballistic=ballistic,beamWeapon=beamWeapon,
                    hitCount=0,lethalHits=0,shieldDamage=0,hullDamage=0}
                factionData.matchups[key]=row
            end
            row.hitCount=row.hitCount+1; row.lethalHits=row.lethalHits+(lethalHit and 1 or 0)
            row.shieldDamage=row.shieldDamage+shieldDamage; row.hullDamage=row.hullDamage+hullDamage
        end
        -- Pair identity is valuable for diagnosing friendly fire, but recording
        -- every hit as an event would make telemetry a combat hot-path cost.
        -- Keep only interval aggregates and cap distinct pairs per faction.
        if targetFaction~='UNKNOWN' and attackerFaction==targetFaction
            and valid(attacker) and attacker:getBreedName()=='Ship' then
            local factionData=telemetry.intervalByFaction[targetFaction]
            local attackerSignature=sig(attacker)
            local pairKey=tostring(attackerSignature)..':'..tostring(targetSignature)
            local pair=factionData.friendlyFirePairs[pairKey]
            if not pair and factionData.friendlyFirePairCount<FRIENDLY_FIRE_PAIR_LIMIT then
                pair={attackerSignature=attackerSignature,targetSignature=targetSignature,
                    attackerName=attacker.Name,targetName=target.Name,attackerClass=attackerClass,targetClass=targetClass,
                    weaponClass=weaponClass,weaponSubtype=weaponSubtype,sourceKind=sourceKind,
                    hitCount=0,lethalHits=0,shieldDamage=0,hullDamage=0}
                factionData.friendlyFirePairs[pairKey]=pair
                factionData.friendlyFirePairCount=factionData.friendlyFirePairCount+1
            end
            if pair then
                pair.hitCount=pair.hitCount+1; pair.lethalHits=pair.lethalHits+(lethalHit and 1 or 0)
                pair.shieldDamage=pair.shieldDamage+shieldDamage; pair.hullDamage=pair.hullDamage+hullDamage
            else
                local overflow=factionData.friendlyFireOverflow
                overflow.hitCount=overflow.hitCount+1; overflow.lethalHits=overflow.lethalHits+(lethalHit and 1 or 0)
                overflow.shieldDamage=overflow.shieldDamage+shieldDamage; overflow.hullDamage=overflow.hullDamage+hullDamage
            end
        end
        telemetry.hitCount=(telemetry.hitCount or 0)+1
    end)
    self.CombatDamageTelemetry.registered=ok==true
    if ok then self.CombatDamageTelemetry.registrationError=nil
    else self.CombatDamageTelemetry.registrationError='engine.addHook failed' end
end

function RTS:CaptureBaseHullBaseline()
    self.AIBaseHullSamples={}
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local station=self:GetFactionCommandShip(kind)
        if valid(station) then self.AIBaseHullSamples[kind]=station.HitpointsLeft end
    end
    self.AIBaseDamageSummaryAt=mn.getMissionTime()
    self.AICombatDamageSummaryAt=self.AIBaseDamageSummaryAt
end

-- True when EmitAIEvent would actually record something; lets hot callers
-- skip building event tables that would be thrown away.
function RTS:IsAITraceActive()
    return self.CombatTelemetryEnabled==true
        and (self.AITraceFile~=nil or self.AIEventSink~=nil or self.Config.AI.TraceFileEnabled==true)
end

function RTS:EmitAIEvent(event,data,now)
    -- AI observations and counters are maintained at their gameplay call sites.
    -- Event serialization is optional experiment output, not part of decisions.
    if not self:IsAITraceActive() then return end
    self.AITraceSequence=(self.AITraceSequence or 0)+1
    local record={schema=2,event=event,time=now or mn.getMissionTime(),sequence=self.AITraceSequence,data=data}
    local line=json(record)
    -- Detailed records go to their own buffered stream. Engine log gets summaries
    -- and transitions only. No per-projectile printing on the rendering path.
    if self.AITraceFile then
        self.AIDetailBuffer[#self.AIDetailBuffer+1]=line
        if #self.AIDetailBuffer>=64 then self:FlushAITrace() end
    elseif self.Config.AI.TraceFileEnabled==true and event~='DECISION' and event~='UNIT' then
        ba.print('[AI-V2] '..line..'\n')
    end
    if self.AIEventSink then self.AIEventSink(record) end -- deterministic test boundary
end

function RTS:FlushAITrace()
    if self.AITraceFile and #(self.AIDetailBuffer or {})>0 then
        self.AITraceFile:write(table.concat(self.AIDetailBuffer,'\n')..'\n')
        self.AITraceFile:flush()
        self.AIDetailBuffer={}
    end
end

-- The one thing a bug report or a player could have used to answer "is per-hit
-- damage attribution even switched on, and what is it attributing from?" was
-- computed as DAMAGE_TELEMETRY_STATUS and then thrown away with the rest of the
-- record, because IsAITraceActive() is false in every shipped configuration
-- (no trace file, no event sink, AI.TraceFileEnabled defaults to false). Keep
-- the event for the experiment runner, and surface the same facts where they
-- can actually be seen: on the state for the HUD, in the engine log, and as a
-- status line when the resolved-damage hooks are live.
function RTS:ReportDamageTelemetryStatus(now)
    local telemetry = { enabled = self.CombatDamageTelemetry.registered==true,
        source = self.CombatDamageTelemetry.registered and 'resolved damage pipeline'
            or 'sampled station hull deltas; per-hit attribution unavailable',
        stationBeamTrackingRegistered = self.StationBeamHookRegistered==true,
        registeredTargetCount = self.BaseDamageTelemetry.hookCount,
        targets = self.BaseDamageTelemetry.registeredTargets,
        registrationErrors = self.BaseDamageTelemetry.registrationErrors,
        combatDamageRegistered = self.CombatDamageTelemetry.registered,
        combatDamageRegistrationError = self.CombatDamageTelemetry.registrationError }
    self.DamageTelemetryStatus = telemetry
    self:Log("Damage telemetry: "..telemetry.source
        .."; station target hooks "..tostring(telemetry.registeredTargetCount)
        .."; station beam tracking "..tostring(telemetry.stationBeamTrackingRegistered)
        .."; combat registered "..tostring(telemetry.combatDamageRegistered))
    if telemetry.enabled then self:SetStatus("Damage telemetry ACTIVE (per-hit attribution)", 4) end
    return telemetry
end

function RTS:StartAITrace()
    local telemetryStatus=self:ReportDamageTelemetryStatus(mn.getMissionTime())
    if self.AITraceFile then return end
    if self.Config.AI.TraceFileEnabled~=true and not self.AIEventSink then return end
    local warmup=self.RosterModelWarmup or {}
    if self.Config.AI.TraceFileEnabled==true and cf and cf.openFile then
        local filename='rts-ai-'..os.date('%Y%m%d-%H%M%S')..'.jsonl'
        local file=cf.openFile(filename,'w','data')
        if file and file:isValid() then self.AITraceFile=file; self:Log('AI telemetry: data/'..filename) end
    end
    self:EmitAIEvent('RUN',{difficulty=self.SetupDifficultyIndex,factions=self.SetupFactionCount,
        distance=self.SetupBaseDistanceIndex,economy=self.SetupEconomyIndex,normalStart=true,
        planner='coordinated-v2',detailedUnitTelemetry=self.Config.AI.DetailedUnitTelemetry==true,
        detailedDecisionTelemetry=self.Config.AI.DetailedDecisionTelemetry==true,
        doctrine=doctrine(self),balance=balanceDefinition(self),
        rosterModelWarmup={enabled=self.Config.AI.PrewarmRosterModels~=false,completed=warmup.done==true,
            loaded=warmup.loaded or 0,alreadyLoaded=warmup.alreadyLoaded or 0,failed=warmup.failed or 0,
            unsupported=warmup.unsupported==true},
        damageAttribution=self.CombatDamageTelemetry.registered and 'resolved shield and hull strength removed in ship_do_damage' or 'sampled station hull deltas; per-hit attribution unavailable',
        stationBeamTracking={registered=self.StationBeamHookRegistered==true,hook='On Beam Collision'},
        baseDamageTelemetry={enabled=self.BaseDamageTelemetry.hookCount>0,hook='On Ship Damage',registeredTargetCount=self.BaseDamageTelemetry.hookCount,
            targets=self.BaseDamageTelemetry.registeredTargets,registrationErrors=self.BaseDamageTelemetry.registrationErrors},
        combatDamageTelemetry={enabled=self.CombatDamageTelemetry.registered,hook='On Ship Damage',registered=self.CombatDamageTelemetry.registered,
            registrationError=self.CombatDamageTelemetry.registrationError}},mn.getMissionTime())
    self:EmitAIEvent('DAMAGE_TELEMETRY_STATUS',telemetryStatus,mn.getMissionTime())
    self:FlushAITrace()
end

-- Every CP movement in the mod funnels through here. SpendFactionCP calls it
-- after deducting, the two production paths call it directly, so cpAfter plus
-- the amount recovers the exact pre-deduction balance.
--
-- CP_SPEND is a per-deduction ledger record, not another interval aggregate. It
-- exists because two sinks reach this function and emit nothing else of their
-- own: the station upgrade track (BuyUpgrade) and the faction ability
-- (QueueOrbitalStrike, 750 CP, which only reported the refund). A tool that
-- reconciles FACTION.economy.flow.productionSpend against purchase events alone
-- therefore lands ~10% short on real matches and cannot tell a genuinely
-- unattributed sink from a silent emitter. With this record present the flow
-- reconciles exactly, and whatever carries no matching purchase event is named
-- rather than silently absorbed.
--
-- The amount is available to every caller, so no caller change is required and
-- a future sink cannot regress the reconciliation by omitting a field: if a path
-- ever deducts CP without routing through here, the ledger stops matching the
-- flow and the tools report it.
function RTS:RecordAIEconomyFlow(kind,flow,amount)
    if not self.CombatTelemetryEnabled or kind==nil or flow==nil then return end
    self.AIEconomyFlow=self.AIEconomyFlow or {}
    local faction=self.AIEconomyFlow[kind] or {income=0,productionSpend=0,bounty=0,refund=0}
    self.AIEconomyFlow[kind]=faction
    local value=tonumber(amount) or 0
    faction[flow]=(faction[flow] or 0)+value
    -- Running total behind the interval. The interval is zeroed the moment
    -- FACTION publishes it, so spend that lands after a match's last FACTION
    -- record belongs to an interval nobody ever reports: that is why the event
    -- stream and the summed flow disagreed by a trailing tail on real batches.
    -- The cumulative total is never reset mid-mission, so it accounts for every
    -- deduction including the last one.
    self.AIEconomyFlowCumulative=self.AIEconomyFlowCumulative or {}
    local running=self.AIEconomyFlowCumulative[kind] or {income=0,productionSpend=0,bounty=0,refund=0}
    self.AIEconomyFlowCumulative[kind]=running
    running[flow]=(running[flow] or 0)+value
    -- Only the two flows that move CP out of a faction's bank. Income and
    -- bounty are already visible as their own flow keys and carry no purchase
    -- event to reconcile against.
    if flow=='productionSpend' or flow=='refund' then
        local cpAfter=self:GetFactionCP(kind) or 0
        self:EmitAIEvent('CP_SPEND',{faction=kind,flow=flow,amount=value,
            cpAfter=cpAfter,cpBefore=cpAfter+value},mn.getMissionTime())
    end
end

function RTS:EmitAIFinalBalance(result,now)
    if not self.CombatTelemetryEnabled or self.BalanceFinalEmitted then return end
    self.BalanceFinalEmitted=true
    now=now or mn.getMissionTime()
    -- The strategic-value walk below and the two damage summaries are the only
    -- part of this record that costs anything: one full ship scan with a
    -- GetStrategicUnitValue lookup per hull, plus a table walk per faction. It
    -- ran in the shipped configuration, where IsAITraceActive() is false and
    -- EmitAIEvent discards every record. Do the walk only when a trace can
    -- actually receive it. The record is still emitted either way, and it has
    -- the same shape, so a test that swaps EmitAIEvent for a sink (the
    -- deterministic test boundary this module documents) still sees the cheap
    -- fields - alive, objectValid, cap, CP, queue - exactly as before.
    local collected=self:IsAITraceActive()
    local factions={}
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local station=self:GetFactionCommandShip(kind)
        local state=self.AIStates and self.AIStates[kind]
        local cap=self:GetFleetCap(kind)
        local currentCP=(kind=='BLUE' and self.CommandPoints) or (state and state.cp) or 0
        local queue=state and state.queue or nil
        if kind=='BLUE' and not self.AutoPlayerMode and self.BuildQueue and self.BuildQueue[1] then queue=self.BuildQueue[1] end
        local queued={}
        if queue then
            local option=queue.option or queue.entry or {}
            local estimate=queue.estimate or (option.class and self:GetPurchaseEstimate(option.class,option.tier or 1,option.count or queue.count or 1))
            queued={class=option.class or 'UNKNOWN',tier=option.tier or 1,count=queue.count or option.count or 1,
                cost=option.cost or (estimate and estimate.cost) or 0,
                remainingSeconds=math.max(0,(tonumber(queue.finishTime) or now)-now),
                capacityWaitSeconds=queue.blockedAt and math.max(0,now-queue.blockedAt) or 0}
        end
        factions[kind]={alive=shipAlive(station),objectValid=valid(station),stationHull=valid(station) and station.HitpointsLeft or 0,
            stationMax=valid(station) and station.HitpointsMax or 0,
            commandPoints=currentCP,baseIncomePerSecond=(state and state.playerEconomy and self.ActiveIncomePerSecond)
                or (state and state.income) or (kind=='BLUE' and self.ActiveIncomePerSecond) or 0,
            fleetCap=cap,combatants=0,committedUnits=0,replacementValue=0,hullWeightedValue=0,composition={},
            losses=(self.AIStats and self.AIStats.losses[kind]) or {},
            economyFlow=(self.AIEconomyFlow or {})[kind] or {},
            economyFlowCumulative=(self.AIEconomyFlowCumulative or {})[kind] or {},
            queue=next(queued) and queued or nil,
            combatDamageRegistered=self.CombatDamageTelemetry.registered}
        if collected then
            local elapsed=now-(self.ScenarioStartTime or now)
            factions[kind].baseDamage=baseDamageSummary(self.BaseDamageTelemetry.totalByFaction[kind],elapsed)
            factions[kind].combatDamage=combatDamageSummary(self.CombatDamageTelemetry.totalByFaction[kind],elapsed)
        end
    end
    if collected then
        self:EachShip(function(ship)
            local kind=self:GetFactionKey(ship)
            local faction=kind and factions[kind]
            if faction and shipAlive(ship) and not self:IsCommandStation(ship) then
                local class=ship.Class.Name
                local replacement=self:GetStrategicUnitValue(ship,kind)
                local hull=health(ship)
                faction.combatants=faction.combatants+1
                faction.replacementValue=faction.replacementValue+replacement
                faction.hullWeightedValue=faction.hullWeightedValue+replacement*hull
                local item=faction.composition[class] or {count=0,replacementValue=0,hullFractionSum=0}
                faction.composition[class]=item
                item.count=item.count+1; item.replacementValue=item.replacementValue+replacement
                item.hullFractionSum=item.hullFractionSum+hull
            end
        end)
    end
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local faction=factions[kind]
        faction.committedUnits=faction.combatants+(faction.queue and faction.queue.count or 0)
    end
    self:EmitAIEvent('BALANCE_FINAL',{result=result or self.BattleVictor or self.GameStatus,
        resultText=self.PostBattleResult,factions=factions,losses=self.AIStats.losses,
        counters={decisions=self.AIStats.decisions,retained=self.AIStats.retained,switches=self.AIStats.switches,
            nativeChanges=self.AIStats.nativeChanges}},now)
end

function RTS:CloseAITrace()
    self:FlushAITrace()
    if self.AITraceFile then self.AITraceFile:close(); self.AITraceFile=nil end
end

-- True while the RTS session owns the screen and the engine's pause menu must
-- not appear on its own. The mod's own pause (RTS:SetPaused) is separate and
-- deliberately still allows the engine to stop the clock.
function RTS:IsMissionPauseDisabled()
    return self.Enabled==true and not self.SetupActive and not self.PostBattleActive
        and self.Config.AI.DisableMissionPause~=false
end

function RTS:OnStateStart(oldState,newState)
    -- Backstop for any pause route the mod does not own itself (engine menu
    -- shortcuts, controller chords). A normal Esc press never reaches here:
    -- ShouldOverrideKey swallows it and toggles the mod's own pause instead.
    -- Same nil guard as OnStateEnd (lifecycle.lua): the engine has not been
    -- observed to hand us a nil state here, but a Lua error inside a state hook
    -- is not catchable by the mod, so the two handlers must agree on the
    -- contract rather than one of them assuming it.
    local newName=newState and newState.Name or nil
    if newName==nil then return end
    local oldName=oldState and oldState.Name or nil
    if self:IsMissionPauseDisabled() and oldName=='GS_STATE_GAME_PLAY' and newName=='GS_STATE_GAME_PAUSED' then
        self:EmitAIEvent('PAUSE_SUPPRESSED',{reason='MISSION_CONTINUES'})
        ba.postGameEvent(ba.GameEvents['GS_EVENT_PREVIOUS_STATE'])
        return
    end
    if newName=='GS_STATE_GAME_PLAY' then self:SetMissionFocusPolicy(self:IsMissionPauseDisabled())
    elseif newName~='GS_STATE_GAME_PAUSED' then self:SetMissionFocusPolicy(false) end
end

function RTS:SetMissionFocusPolicy(active)
    -- Options reads staged values immediately. Do not persist this mission-only
    -- override or discard unrelated user option edits.
    if not opt or not opt.Options then return end
    if active and not self.AIFocusOption then
        for _,option in ipairs(opt.Options) do
            if option.Key=='Game.UnfocusedPause' then
                self.AIFocusOption=option; self.AIFocusPrevious=option.Value
                for _,value in ipairs(option:getValidValues()) do
                    if value.Serialized=='false' then option.Value=value; self.AIFocusDisabled=value; break end
                end
                break
            end
        end
    elseif not active and self.AIFocusOption then
        if self.AIFocusOption.Value==self.AIFocusDisabled then self.AIFocusOption.Value=self.AIFocusPrevious end
        self.AIFocusOption=nil; self.AIFocusPrevious=nil; self.AIFocusDisabled=nil
    end
end

end
