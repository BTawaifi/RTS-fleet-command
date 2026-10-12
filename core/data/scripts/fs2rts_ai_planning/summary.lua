-- AI summary for telemetry (SummarizeAI).
return function(RTS, _shared)
local DEFAULT_FACTION_ORDER, baseDamageSummary, combatDamageSummary, distance, doctrine, newBaseDamageFaction, newCombatDamageFaction, sig = _shared.DEFAULT_FACTION_ORDER, _shared.baseDamageSummary, _shared.combatDamageSummary, _shared.distance, _shared.doctrine, _shared.newBaseDamageFaction, _shared.newCombatDamageFaction, _shared.sig
local valid, canAutoEngage = _shared.valid, _shared.canAutoEngage

function RTS:SummarizeAI(now)
    if now-(self.AISummaryAt or -100)<(doctrine(self).TelemetrySummarySeconds or 30) then return end
    self.AISummaryAt=now
    local includeUnitDetails=self.Config.AI.DetailedUnitTelemetry==true
    local damageElapsed=math.max(0,now-(self.AIBaseDamageSummaryAt or self.ScenarioStartTime or now))
    local factionKeys=self.GetFactionKeys and self:GetFactionKeys() or DEFAULT_FACTION_ORDER
    for _,kind in ipairs(factionKeys) do
        local station=self:GetFactionCommandShip(kind)
        if valid(station) then
            local s={faction=kind,composition={},objectives={},defended={},value=0,offense=0,defense=0,reserve=0,
                idle=0,servicing=0,mismatch=0,stalled=0,engaged=0,unengagedSeconds=0,unitSeconds=0,
                combatants=0,replacementValue=0,replacementValueByClass={},
                stationHull=station.HitpointsLeft,stationMax=station.HitpointsMax,received=self.AIStats.received[kind] or 0,
                damageDealt='unknown',stationDamageDealt='unknown',engagementDelaySum=0,engagementSamples=0}
            local previousHull=self.AIBaseHullSamples[kind]
            local attributedDamage=self.BaseDamageTelemetry.intervalByFaction[kind] or newBaseDamageFaction()
            local attributedCombatDamage=self.CombatDamageTelemetry.intervalByFaction[kind] or newCombatDamageFaction()
            s.baseDamageTelemetry={coverage={registeredTarget=self.BaseDamageTelemetry.hookCount>0,
                    hitCountTotal=self.BaseDamageTelemetry.hitCount or 0},
                interval=baseDamageSummary(attributedDamage,damageElapsed),
                cumulative=baseDamageSummary(self.BaseDamageTelemetry.totalByFaction[kind],now-(self.ScenarioStartTime or now))}
            s.combatDamageTelemetry={coverage={registered=self.CombatDamageTelemetry.registered,
                    hitCountTotal=self.CombatDamageTelemetry.hitCount or 0},
                interval=combatDamageSummary(attributedCombatDamage,now-(self.AICombatDamageSummaryAt or self.ScenarioStartTime or now),true)}
-- damageDealt / stationDamageDealt were the string 'unknown' in every
-- FACTION record, so the arms-race and per-faction damage curves could never be
-- computed from a batch. They were then filled from totalByFaction[kind], but
-- that table is keyed by TARGET faction (fs2rts_ai_telemetry.lua:186-188), so
-- the field carried damage this faction RECEIVED. The comment above it claimed
-- the opposite. ai_tactics.py:737 had already noticed and worked around it by
-- deriving dealt from the other two factions, so every "damage bought per ship
-- lost" number was computed by a join the emitter could have published
-- directly.
--
-- Dealt IS computable per faction at this cadence, and cheaply: the byMatchup
-- rows are already built for this very record, and each one carries
-- attackerFaction (fs2rts_ai_telemetry.lua:196). Summing the rows whose
-- attacker is this faction walks exactly the rows already being serialised, so
-- the extra cost is a comparison per row inside a loop that was already paid
-- for. Nothing is estimated and no new cadence is introduced.
--
-- So damageDealt now means dealt, and damageReceived carries the old meaning.
-- Both are emitted rather than renamed: renaming would silently change every
-- saved batch's numbers. Friendly fire is included in dealt, because a faction
-- really does inflict it; self-inflicted hits are attributed to the attacking
-- faction, which is why received and dealt no longer mirror each other.
do
local function totalHull(scope)
if scope==nil then return 0 end
local v=scope.hullDamage or 0
return type(v)=='number' and v or 0
end
-- Hull damage this faction inflicted, from rows keyed by the faction that
-- RECEIVED it. `rows` is the already-built matchup list of the target faction.
--
-- pairs, NOT ipairs: the bucket is keyed by the composite bucket-key string
-- (fs2rts_ai_util.lua:132), so it has no integer part and ipairs walks straight
-- past every row. That is not hypothetical - it shipped as damageDealt=0.0 on
-- all three factions across instrfix-a1 while a fixture using an array-shaped
-- bucket passed.
local function dealtBy(rows,kind)
local total=0
for _,row in pairs(rows or {}) do
if row.attackerFaction==kind then total=total+(row.hullDamage or 0) end
end
return total
end
local function dealtByFaction(telemetry,kind)
local total=0
for targetFaction,scope in pairs(telemetry.totalByFaction or {}) do
if targetFaction~='UNKNOWN' then total=total+dealtBy(scope.matchups,kind) end
end
return total
end
local function dealtByFactionOnBase(telemetry,kind)
local total=0
for _,scope in pairs(telemetry.totalByFaction or {}) do
for _,row in pairs(scope.weapons or {}) do
if row.attackerFaction==kind then total=total+(row.hullDamage or 0) end
end
end
return total
end
s.damageReceived=totalHull(self.CombatDamageTelemetry.totalByFaction[kind])
s.damageDealt=dealtByFaction(self.CombatDamageTelemetry,kind)
s.stationDamageReceived=totalHull(self.BaseDamageTelemetry.totalByFaction[kind])
s.stationDamageDealt=dealtByFactionOnBase(self.BaseDamageTelemetry,kind)
-- Interval figures on the same footing. s.combatDamageTelemetry.interval above
-- only carries THIS faction's received interval; the dealt interval needs the
-- same cross-faction walk, done per interval rather than on the totals.
do
local intervalDealt=0; local intervalReceived=0
for targetFaction,scope in pairs(self.CombatDamageTelemetry.intervalByFaction or {}) do
if targetFaction==kind then intervalReceived=intervalReceived+totalHull(scope) end
if targetFaction~='UNKNOWN' then
-- pairs, not ipairs: see dealtBy above.
for _,row in pairs(scope.matchups or {}) do
if row.attackerFaction==kind then intervalDealt=intervalDealt+(row.hullDamage or 0) end
end
end
end
s.damageDealtInterval=intervalDealt
s.damageReceivedInterval=intervalReceived
end
end
            if previousHull~=nil then
                local sampledHullLoss=previousHull-station.HitpointsLeft
                s.stationHullDelta={observed=true,previous=previousHull,current=station.HitpointsLeft,
                    sampledHullLoss=sampledHullLoss,attributedHullDamage=attributedDamage.hullDamage,
                    residual=sampledHullLoss-attributedDamage.hullDamage}
            else
                s.stationHullDelta={observed=false,reason='no previous base hull sample'}
            end
            self.AIBaseHullSamples[kind]=station.HitpointsLeft
            for _,row in ipairs(self.StrategicThreatSnapshot or {}) do
                local ship=row.ship; local id=sig(ship)
                -- A ship docked in fleet service deliberately holds no strategic
                -- order, because UpdateFactionStrategicPlan excludes serviced
                -- ships from group building for the same reason. Counting those
                -- as idle made a healthy withdrawing fleet look uncommanded, so
                -- track them separately instead.
                local servicing=self.FleetServices~=nil and self.FleetServices[id]~=nil
                if self:GetFactionKey(ship)==kind and not self:IsCommandStation(ship) then
                    local p=self:AIProfile(ship); local o=self.AIObservations[id]; local a=self.AIOrderState[id]
                    s.composition[ship.Class.Name]=(s.composition[ship.Class.Name] or 0)+1; s.value=s.value+p.value
                    local replacement=self:GetStrategicUnitValue(ship,kind)
                    s.combatants=s.combatants+1; s.replacementValue=s.replacementValue+replacement
-- analyze_batch.py reads `combatantValue` for the arms-race curve; the emitter
-- only ever wrote `replacementValue`, so that curve was permanently None. Emit
-- BOTH rather than renaming: renaming would invalidate every saved batch.
s.combatantValue=s.replacementValue
                    s.replacementValueByClass[ship.Class.Name]=(s.replacementValueByClass[ship.Class.Name] or 0)+replacement
                    if a then
                        local key=tostring(a.targetSignature); s.objectives[key]=(s.objectives[key] or 0)+1
                        if a.mission=='PRIMARY' or a.mission=='ESCORT' then s.offense=s.offense+p.value
                        elseif a.mission=='REGROUP' or a.mission=='RETREAT' or a.mission=='LURE' then s.reserve=s.reserve+p.value
                        else s.defense=s.defense+p.value end
                        if a.protected then s.defended[tostring(a.protected)]=(s.defended[tostring(a.protected)] or 0)+1 end
                    elseif servicing then s.servicing=s.servicing+1 else s.idle=s.idle+1 end
                    if o then
                        if includeUnitDetails then
                            -- Local force balance is telemetry only. Sample it at
                            -- the summary cadence instead of rescanning nearby
                            -- ships on every strategic update.
                            local friend,enemy=self:AILocalStrength(ship,ship.Position,
                                doctrine(self).LocalStrengthRadius or 4500,false)
                            o.friendlyValue=friend; o.enemyValue=enemy
                        end
                        s.stalled=s.stalled+(o.stalled and 1 or 0); s.engaged=s.engaged+(o.engaged and 1 or 0)
                        if o.status=='PLANNER_TARGET_MISMATCH' or o.status=='NATIVE_ORDER_PREEMPTED' then s.mismatch=s.mismatch+1 end
                        s.unengagedSeconds=s.unengagedSeconds+o.unengaged; s.unitSeconds=s.unitSeconds+o.sampledSeconds
                        if o.engagementDelay then s.engagementDelaySum=s.engagementDelaySum+o.engagementDelay; s.engagementSamples=s.engagementSamples+1 end
                        if includeUnitDetails then
                            local target=a and self:FindShipBySignature(a.targetSignature)
                            self:EmitAIEvent('UNIT',{ship=id,name=ship.Name,class=ship.Class.Name,faction=kind,observation=o,
                                objective=a or {},baseDistance=distance(ship,station),enemyBaseDistance=valid(self:GetStablePrimaryTarget(kind)) and distance(ship,self:GetStablePrimaryTarget(kind)) or -1,
                                targetHostile=valid(target) and canAutoEngage(self,ship,target) or false},now)
                        end
                    end
                end
            end
            local state=self.AIStates and self.AIStates[kind]
            local automaticQueue=state and state.queue or nil
            local manualQueue=kind=='BLUE' and not self.AutoPlayerMode and self.BuildQueue and self.BuildQueue[1] or nil
            local q=automaticQueue or manualQueue
            local option=q and (q.option or q.entry) or nil
            local estimate=q and (q.estimate or (option and self:GetPurchaseEstimate(option.class,option.tier or 1,option.count or q.count or 1))) or nil
            local queuedCount=q and (q.count or (option and option.count) or 1) or 0
            local cap=self:GetFleetCap(kind)
            local queuedUnits=queuedCount
            if kind=='BLUE' and manualQueue then
                for i=2,#(self.BuildQueue or {}) do queuedUnits=queuedUnits+((self.BuildQueue[i].option and self.BuildQueue[i].option.count) or 1) end
            end
            local economyState=self.AIEconomyFlow and self.AIEconomyFlow[kind] or {}
            local scenarioProgress=self:GetEscalationProgress(now)
            local tier=self:GetCurrentEscalationTier(now)
            -- Report the ramp the sim ACTUALLY applied. This used to be a
            -- second, player-shaped copy of the income formula, so CONTEST's
            -- incomeMultiplier was wrong for RED and GOLD by up to 0.85x - the
            -- balance tooling was reading a number the simulation never used.
            local incomeRamp=(kind=='BLUE') and (1+0.10*(tier-1)+0.20*scenarioProgress*scenarioProgress)
                or self:GetAIIncomeRamp(now)
            s.economy={commandPoints=(kind=='BLUE' and self.CommandPoints) or (state and state.cp) or 0,
                baseIncomePerSecond=(state and state.playerEconomy and self.ActiveIncomePerSecond) or (state and state.income) or (kind=='BLUE' and self.ActiveIncomePerSecond) or 0,
                incomeMultiplier=incomeRamp,flow={income=economyState.income or 0,
                    productionSpend=economyState.productionSpend or 0,bounty=economyState.bounty or 0,
                    refund=economyState.refund or 0},fleetCap=cap,combatants=s.combatants,
                committedUnits=s.combatants+queuedUnits,queueDepth=(manualQueue and #(self.BuildQueue or {}) or (automaticQueue and 1 or 0))}
            if q and option then
                s.economy.queueJobs={}
                if manualQueue then
                    for _,job in ipairs(self.BuildQueue or {}) do
                        if job.id then s.economy.queueJobs[#s.economy.queueJobs+1]=job.id end
                    end
                elseif q.id then s.economy.queueJobs[1]=q.id end
                local finish=tonumber(q.finishTime) or 0
                s.economy.queue={class=option.class or 'UNKNOWN',role=option.role,tier=option.tier or 1,
                    count=queuedCount,cost=option.cost or (estimate and estimate.cost) or 0,
                    buildSeconds=option.time or (estimate and estimate.time) or 0,
                    jobId=q.id,queuedAt=q.queuedAt or q.startTime or now,finishAt=finish>0 and finish or nil,
                    remainingSeconds=finish>0 and math.max(0,finish-now) or nil,
                    waitingForCapacity=finish>0 and now>=finish and s.combatants+queuedCount>cap or false,
                    capacityWaitSeconds=q.blockedAt and math.max(0,now-q.blockedAt) or 0}
            end
            local threats,value,urgent=self:GetFactionThreats(kind,station,doctrine(self).ThreatRadius or 6500)
            s.stationThreats=#threats; s.threatValue=value; s.urgent=urgent
            -- Station position, so an offline check can measure where each
            -- faction's capitals actually spawned relative to both bases.
            if station and station.Position then
                s.stationPosition={x=station.Position.x,y=station.Position.y,z=station.Position.z}
            end
            s.plan=self.AIPlanTelemetry[kind]; s.losses=self.AIStats.losses[kind] or {}
            -- Station upgrade levels and the CP already sunk into them.
            -- BuyUpgrade spends through SpendFactionCP (so it lands in
            -- economy.flow.productionSpend) but emits no event of its own, which
            -- left ~10% of productionSpend unattributable from a batch. It is
            -- also the gate on STATION_REPAIR: station.lua only repairs below
            -- ARMOR L2, so a faction that never bought it reports
            -- totalRepaired 0.0 forever, and "the AI never repaired" is
            -- indistinguishable from "station repair is broken". Publishing the
            -- levels lets both questions be answered from telemetry alone.
            local upgradeLevels,upgradeSpend={},0
            local tracks=(self.Config.Station or {}).Tracks or {}
            for _,track in ipairs({'armor','defenses','logistics','command'}) do
                local level=self:GetUpgradeLevel(kind,track)
                upgradeLevels[track]=level
                local costs=(tracks[track] or {}).costs or {}
                for i=1,level do upgradeSpend=upgradeSpend+(tonumber(costs[i]) or 0) end
            end
            s.economy.upgradeLevels=upgradeLevels
            s.economy.upgradeSpend=upgradeSpend
            s.economy.repairUnlocked=upgradeLevels.armor>=2
            -- The running total behind economy.flow, which is an interval zeroed
            -- on the next line. Reading only the intervals loses the spend that
            -- happened after the final FACTION record of a match, so this is
            -- what a total has to be read from.
            local running=(self.AIEconomyFlowCumulative or {})[kind]
            s.economy.flowCumulative={income=0,productionSpend=0,bounty=0,refund=0}
            if running then
                for name,total in pairs(running) do s.economy.flowCumulative[name]=total end
            end
            s.detailedUnitTelemetry=includeUnitDetails
            s.detailedDecisionTelemetry=self.Config.AI.DetailedDecisionTelemetry==true
            self:EmitAIEvent('FACTION',s,now)
            self.AIEconomyFlow[kind]={income=0,productionSpend=0,bounty=0,refund=0}
            self.BaseDamageTelemetry.intervalByFaction[kind]=newBaseDamageFaction()
            self.CombatDamageTelemetry.intervalByFaction[kind]=newCombatDamageFaction()
        end
    end
    self.AIBaseDamageSummaryAt=now
    self.AICombatDamageSummaryAt=now
    self:EmitAIEvent('COUNTERS',{decisions=self.AIStats.decisions,retained=self.AIStats.retained,
        switches=self.AIStats.switches,reissued=self.AIStats.reissued,nativeChanges=self.AIStats.nativeChanges,
        orders=self.AIOrderTelemetry},now)
    self:FlushAITrace()
end
end
