-- AI rosters and build choices.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:GetAIRoster(kind)
    if kind=="BLUE" then return self.Config.AI.BlueRoster or self.Config.ProductionClasses or {} end
    if kind=="RED" then return self.Config.AI.RedRoster or {} end
    if kind=="GOLD" then return self.Config.AI.GoldRoster or {} end
    return {}
end

-- Rosters are static config; index class -> first matching entry per faction
-- instead of scanning the roster on every call (per ship in several passes).
-- Callers include the death path, where GetFactionKey returns nil for ships on
-- a team the mod does not own; indexing a table with a nil key raises
-- "table index is nil" and silently aborts the rest of the $On Ship Death
-- handler, so that case has to bail out before the cache is written.
function RTS:GetAIRosterEntry(kind, className)
    if kind == nil or className == nil then return nil end
    local index = self.RosterIndex
    if index == nil then index = {}; self.RosterIndex = index end
    local byClass = index[kind]
    if byClass == nil then
        byClass = {}
        for _, entry in ipairs(self:GetAIRoster(kind)) do
            if entry.class ~= nil and byClass[entry.class] == nil then byClass[entry.class] = entry end
        end
        index[kind] = byClass
    end
    return byClass[className]
end

function RTS:InitializeAIStates(now)
    self.AIStates={}; local economy=self.Config.Setup.Economies[self.SetupEconomyIndex]; local duration=self:GetDurationProfile(); local difficulty=self.Config.Setup.Difficulties[self.SetupDifficultyIndex]
    local baseStart=economy.startCP*(self.Config.AI.StartingCPScale or .92); local baseIncome=economy.income*(duration.aiIncomeScale or 1)*(difficulty.aiIncome or 1)*(self.Config.AI.IncomeScale or .95)
    if self.AutoPlayerMode then self.AIStates.BLUE={cp=self.CommandPoints,income=0,lastIncome=now,queue=nil,nextThink=now+0.25,serial=0,eliminated=false,playerEconomy=true} end
    if self:IsFactionEnabled("RED") then self.AIStates.RED={cp=baseStart,income=baseIncome,lastIncome=now,queue=nil,nextThink=now+0.25,serial=0,eliminated=false} end
    if self:IsFactionEnabled("GOLD") then self.AIStates.GOLD={cp=baseStart,income=baseIncome,lastIncome=now,queue=nil,nextThink=now+0.25,serial=0,eliminated=false} end
end

function RTS:CountAIRoleUnits(kind)
    local counts={fighter=0,bomber=0,escort=0,capital=0,juggernaut=0,total=0}; local values={fighter=0,bomber=0,escort=0,capital=0,total=0}
    local station=self:GetFactionCommandShip(kind)
    local stationSig=shipValid(station) and station:getSignature() or nil
    self:EachShip(function(ship)
        if shipAlive(ship) and self:GetFactionKey(ship)==kind then
            if ship:getSignature()~=stationSig and not self:IsStaticDefense(ship) then
                local entry=self:GetAIRosterEntry(kind,ship.Class.Name); local role=entry and entry.role or self:GetShipRole(ship)
                local cat=(role=="heavy" or role=="juggernaut" or role=="capital") and "capital" or role
                if counts[cat]==nil then cat="fighter" end
                counts[cat]=counts[cat]+1; counts.total=counts.total+1
                if role=="juggernaut" then counts.juggernaut=counts.juggernaut+1 end
                local est=self:GetPurchaseEstimate(ship.Class.Name,entry and entry.tier or 1,1); local v=est and est.cost or 1
                values[cat]=values[cat]+v; values.total=values.total+v
            end
        end
    end)
    return counts,values
end

function RTS:CountCommittedCombatants(kind)
    local count=self:CountFactionCombatants(kind)
    if kind=="BLUE" then for _,q in ipairs(self.BuildQueue or {}) do count=count+(q.option.count or 1) end end
    local state=self.AIStates and self.AIStates[kind]
    if state and state.queue then count=count+(state.queue.count or 1) end
    return count
end

function RTS:ChooseAIBuild(kind,state,now)
    local tier=self:GetCurrentEscalationTier(now); local roster=self:GetAIRoster(kind); local counts,values=self:CountAIRoleUnits(kind)
    local cap=self:GetFleetCap(kind)
    local slots=cap-self:CountCommittedCombatants(kind)
    local targets=(self.Config.AI.CompositionTargets or {})[tier] or {fighter=.3,bomber=.2,escort=.2,capital=.3}
    local demand=self.AIProductionNeeds and self.AIProductionNeeds[kind] or {}
    local deficits={}; for _,cat in ipairs({"fighter","bomber","escort","capital"}) do local share=values.total>0 and values[cat]/values.total or 0; deficits[cat]=(targets[cat] or 0)-share+(demand[cat] or 0) end
    local availableRoles={}
    for _,entry in ipairs(roster) do
        local class=tb.ShipClasses[entry.class]
        if (entry.tier or 1)<=tier and class and class:isValid() then
            local role=entry.role or "fighter"; availableRoles[(role=="heavy" or role=="juggernaut") and "capital" or role]=true
        end
    end
    local desired=nil
    for _,cat in ipairs({"fighter","bomber","escort","capital"}) do if availableRoles[cat] and (not desired or deficits[cat]>deficits[desired]) then desired=cat end end
    desired=desired or "fighter"
    local decision={faction=kind,tier=tier,commandPoints=state.cp,slots=slots,unitCounts=counts,
        unitValues=values,compositionTargets=targets,tacticalDemand=demand,deficits=deficits,desiredRole=desired,options={}}
    local candidates={}; local cheapestDesired=math.huge; local cheapestCurrentDesired=math.huge; local hasCurrentDesired=false
    local unlockedCount=0; local fleetFitCount=0; local affordableCount=0
    for _,entry in ipairs(roster) do
        local et=entry.tier or 1
        local role=entry.role or "fighter"
        local cat=(role=="heavy" or role=="juggernaut" or role=="capital") and "capital" or role
        local count=(cat=="fighter" or cat=="bomber") and (self.Config.Economy.StrikeWingSize or 4) or 1
        -- A strike wing is 4 hulls, so with fewer free slots than a wing no
        -- fighter/bomber option can satisfy count<=slots and the AI silently
        -- falls through to single-hull capitals. Because capital is the largest
        -- deficit target at tier 3-5, its strike force decays monotonically
        -- while its cruiser count climbs. Buy as many as actually fit instead
        -- of abandoning the role.
        if slots>0 and count>slots then count=slots end
        local class=tb.ShipClasses[entry.class]
        local available=class~=nil and class:isValid()
        local est=available and self:GetPurchaseEstimate(entry.class,et,count) or nil
        local option={class=entry.class,role=cat,tier=et,count=count,weight=entry.weight or 1,
            unlocked=et<=tier,available=available,fitsFleetCap=count<=slots,
            cost=est and est.cost or nil,buildSeconds=est and est.time or nil,
            affordable=est~=nil and est.cost<=state.cp or false}
        decision.options[#decision.options+1]=option
        if option.unlocked and available and est then
            unlockedCount=unlockedCount+1
            if count<=slots then
                fleetFitCount=fleetFitCount+1
                if cat==desired then
                    cheapestDesired=math.min(cheapestDesired,est.cost)
                    if et==tier then hasCurrentDesired=true; cheapestCurrentDesired=math.min(cheapestCurrentDesired,est.cost) end
                end
                if est.cost<=state.cp then
                    affordableCount=affordableCount+1
                    local tierPressure=1+(et==tier and (self.Config.AI.CurrentTierWeight or 5.0) or 0)
                    local deficitPressure=math.max(.08,(deficits[cat] or 0)+.18)*8
                    local weight=(entry.weight or 1)*tierPressure*deficitPressure
                    if cat==desired then weight=weight*(self.Config.AI.DeficitRoleBias or 5.0) end
                    candidates[#candidates+1]={entry=entry,estimate=est,weight=weight,count=count,category=cat,telemetry=option}
                end
            end
        end
    end
    local bankTarget=(hasCurrentDesired and cheapestCurrentDesired or cheapestDesired)
    local boundedBankTarget=false
    -- Saving window length, hoisted ABOVE the target so BoundBankTarget can ask
    -- whether the newest-tier goal fits inside it. Values are verbatim from the
    -- window they used to be computed in; the computation itself is unchanged.
    local savingSeconds=self.Config.AI.MaxProductionSavingSeconds or 120
    if tier>=3 and desired=="capital" then
        savingSeconds=self.Config.AI.CapitalSavingSeconds or savingSeconds
        if tier>=4 then savingSeconds=self.Config.AI.HeavyCapitalSavingSeconds or savingSeconds end
        if tier>=5 then savingSeconds=self.Config.AI.JuggernautSavingSeconds or savingSeconds end
    end
    -- An unreachable target makes SAVING_FOR_DESIRED_ROLE a permanent no-op.
    -- hasCurrentDesired aims the bank at the NEWEST tier's cheapest capital
    -- (12675-31275 CP at tiers 4-5) while the measured per-faction bank peaks
    -- near 2300 CP, so the goal is never met and no capital is ever committed to:
    -- 0 capital/heavy/juggernaut builds in 4 of 4 headless matches, versus 1
    -- capital per faction per match in the baseline. Aim at the cheapest
    -- desired-role hull the faction CAN actually bank for inside one window
    -- instead. Anchored to a real roster price, NOT to cp, so it does not
    -- outrun the bank the way a cp-relative bound (cp + rate * window) would.
    if self.Config.AI.BoundBankTarget==true and hasCurrentDesired and cheapestDesired<math.huge then
        -- rate is 0 for a player-economy faction (Blue auto spends the player's
        -- pool, whose income this function does not model), so leave Blue alone
        -- rather than silently changing what it builds.
        local rate=(state.income or 0)*self:GetAIIncomeRamp(now)*self:GetIncomeMultiplier(kind)
        if rate>0 and state.cp+rate*savingSeconds<cheapestCurrentDesired then
            bankTarget=cheapestDesired
            boundedBankTarget=true
        end
    end
    decision.unlockedOptions=unlockedCount; decision.fleetFitOptions=fleetFitCount
    decision.affordableOptions=affordableCount
    decision.bankTarget=bankTarget<math.huge and bankTarget or nil
    decision.currentTierDesiredCost=hasCurrentDesired and cheapestCurrentDesired or nil
    if boundedBankTarget then
        decision.bankTargetUnreachable=true
        decision.bankTargetBoundedTo=cheapestDesired
    end
    local emergencyState=self.AIProductionEmergency and self.AIProductionEmergency[kind]
    local emergencyBuild=emergencyState and emergencyState.emergency==true
        and now-(emergencyState.time or now)<=math.max(24,(self.Config.AI.StrategicOrderInterval or 12)*2)
    -- Rising edge only. A sustained emergency spans many 2 s strategic frames,
    -- and clearing the save clock on every one of them meant a routine weapon
    -- lock during a committed assault permanently cancelled the 10-15 minute
    -- capital bank - the more committed the assault, the less the AI ever
    -- built a capital.
    local risingEmergency=emergencyBuild and not (emergencyState and emergencyState.wasEmergencyBuild==true)
    if emergencyState then emergencyState.wasEmergencyBuild=emergencyBuild end
    state.productionReserve=emergencyBuild and 0 or (decision.bankTarget or 0)
    if bankTarget<math.huge and state.cp<bankTarget and tier>=2 and not emergencyBuild then
        local goal=desired..":"..tier
        state.savingRole=goal
        if state.savingSince==nil then state.savingSince=now end
        if now-state.savingSince<savingSeconds then
            -- Saving for a role deliberately means fielding nothing cheaper, and
            -- test_station.py's emergency/counter contract asserts exactly that
            -- (a stale emergency must fall back to SAVING_FOR_DESIRED_ROLE with
            -- no purchase). That is a design choice, not a defect, so it stays
            -- the default. AI.FieldCheapHullWhileSaving opts into the softer
            -- behaviour, where the bank keeps filling but the faction still
            -- fields the cheapest affordable non-desired hull instead of going
            -- dark for the whole window.
            local during={}
            if self.Config.AI.FieldCheapHullWhileSaving==true then
                -- A blind alongside purchase is a livelock, not a soft landing.
                -- It drains the bank on every think, so bankTarget never becomes
                -- affordable, so the window never ends in the purchase it exists
                -- to enable. Headless, 4 matches x 3000 s: desiredRole=capital in
                -- 2346 of 3792 build decisions and bankTarget median 8600 CP,
                -- against a per-faction bank that peaked at 1300-2494 CP - ZERO
                -- capital builds in 4 of 4 matches, while the baseline built one
                -- capital per faction per match.
                -- Field alongside ONLY when banking cannot succeed in the time
                -- the window has left. When it can, actually save, so the window
                -- ends in the hull it was opened for. This also fixes the
                -- opposite failure FieldCheapHullWhileSaving was introduced for:
                -- with it off the producer banked ~7700 CP for ~2600 s and built
                -- nothing at all.
                local preserveClock = self.Config.AI.PreserveSavingClockWhileFielding==true
                local canBank = false
                if preserveClock then
                    local remaining = savingSeconds - (now - state.savingSince)
                    local shortfall = bankTarget - state.cp
                    local rate = (state.income or 0) * self:GetAIIncomeRamp(now) * self:GetIncomeMultiplier(kind)
                    -- rate is 0 for a player-economy faction (Blue auto spends the
                    -- player's pool, whose income this function does not model), so
                    -- fall back to the shipped alongside behaviour there rather than
                    -- silently making Blue stop producing.
                    canBank = rate > 0 and shortfall <= rate * remaining
                    decision.savingCanBank=canBank
                end
                if not canBank then
                    for _,c in ipairs(candidates) do if c.category~=desired then during[#during+1]=c end end
                end
            end
            if #during==0 then decision.reason="SAVING_FOR_DESIRED_ROLE"; return nil,decision end
            decision.reason="SAVING_FOR_DESIRED_ROLE"; decision.savingAlongside=true
            candidates=during
        else
            -- Tier savings are bounded so an unaffordable endgame hull cannot stall
            -- the fleet; prefer that role when affordable, otherwise buy an affordable role.
            decision.savingFallback=true; decision.bankTarget=cheapestDesired
            state.productionReserve=cheapestDesired
        end
    elseif not emergencyBuild then
        state.savingRole=nil; state.savingSince=nil
    end
    if risingEmergency then
        state.savingRole=nil; state.savingSince=nil; state.productionReserve=0
    end
    if #candidates==0 then
        decision.reason=unlockedCount==0 and "NO_UNLOCKED_OPTIONS"
            or fleetFitCount==0 and "FLEET_CAP"
            or "INSUFFICIENT_CP"
        -- NOT decision.emergencyFallback here. This branch returns without
        -- selecting anything, so reporting a fallback made the flag a false
        -- success: 61 of 80 emergency decisions in one savepolicy match set it
        -- and then fell back to nothing, which inverts any reading of it as a
        -- success rate. It is set below, where a hull is actually chosen.
        return nil,decision
    end
    if decision.savingFallback then
        local replacements={}
        for _,c in ipairs(candidates) do if c.category==desired then replacements[#replacements+1]=c end end
        -- The save window exists to END in a purchase, and this is the only rung
        -- that lowers bankTarget to something reachable. If the desired role has
        -- nothing affordable, buying a cheap substitute here spends the bank on
        -- junk; the caller then clears savingSince below, restarting the window
        -- from zero - so the window can never complete, which is the mechanism
        -- behind zero capital production in 4 of 4 headless matches (fallback
        -- fired at cp 2820-6047 against a cheapest capital of 7700-8600, bought
        -- a 1800-3150 CP fighter instead, and the clock reset).
        -- Go dark instead and keep banking: income accumulates unspent until the
        -- hull we are actually saving for is affordable. Note the return happens
        -- BEFORE the savingRole/savingSince clear further down, which is what
        -- preserves the window across thinks.
        if #replacements==0 and not emergencyBuild then
            decision.reason="SAVING_FOR_DESIRED_ROLE"
            decision.savingFallbackUnreachable=true
            -- Reaching here means no desired-role hull is affordable, so the
            -- cheapest one IS out of reach by definition. Emitting it makes the
            -- gap visible in a batch instead of inferring it from silence.
            decision.bankTargetUnreachable=cheapestDesired
            return nil,decision
        end
        if #replacements>0 then candidates=replacements end
    end
    -- When the deficient category has a hull in the newest tier and we can
    -- finally afford it, buy from that newest-tier category rather than
    -- immediately falling back to an older cheap substitute.
    if not emergencyBuild and hasCurrentDesired and state.cp>=cheapestCurrentDesired then
        local newest={}
        for _,c in ipairs(candidates) do if c.category==desired and (c.entry.tier or 1)==tier then newest[#newest+1]=c end end
        if #newest>0 then candidates=newest end
    end
    if emergencyBuild then
        local preferred=(demand.bomber or 0)>(demand.fighter or 0) and {"bomber","fighter","escort","capital"} or {"fighter","escort","bomber","capital"}
        for _,role in ipairs(preferred) do
            local fastest=nil
            for _,candidate in ipairs(candidates) do
                if candidate.category==role and (fastest==nil
                    or candidate.estimate.time<fastest.estimate.time
                    or (candidate.estimate.time==fastest.estimate.time and candidate.estimate.cost<fastest.estimate.cost)) then
                    fastest=candidate
                end
            end
            if fastest then candidates={fastest}; decision.emergencyRole=role; break end
        end
        decision.emergencyFallback=decision.emergencyRole~=nil
    end
    table.sort(candidates,function(a,b) return a.weight>b.weight end)
    local total=0; for _,c in ipairs(candidates) do total=total+c.weight end
    local draw=math.random()*total; local roll=draw; local selected=nil
    decision.totalWeight=total; decision.draw=draw
    decision.reason=emergencyBuild and "EMERGENCY_DEFENSE_PURCHASE" or "PURCHASE_SELECTED"
    decision.candidates={}
    for _,c in ipairs(candidates) do
        c.telemetry.selectionWeight=c.weight; c.telemetry.probability=total>0 and c.weight/total or 0
        decision.candidates[#decision.candidates+1]=c.telemetry
        roll=roll-c.weight
        if selected==nil and roll<=0 then selected=c end
    end
    selected=selected or candidates[1]
    -- Clear the savings bookkeeping, but NOT when the purchase we just made is
    -- the cheap hull the save window fields alongside an unmet goal.
    -- savingSince is the ONLY thing that ages the window out into
    -- savingFallback (see above), and FieldCheapHullWhileSaving makes that
    -- purchase the normal outcome of every think while the goal is unaffordable.
    -- Wiping the clock here therefore restarted the window on every single
    -- think: the goal never aged out, the bank never accumulated toward
    -- bankTarget, and the producer fielded a ~1500 CP fighter wing forever.
    -- Headless, 4 matches at 3000 s: desiredRole=capital in 2346 of 3792
    -- decisions, bankTarget median 8600, per-faction CP bank peak 1300-2494,
    -- and ZERO capital builds in 4 of 4 matches.
    local fieldingAlongside = decision.savingAlongside==true
        and self.Config.AI.PreserveSavingClockWhileFielding==true
    state.productionReserve=0
    if not fieldingAlongside then state.savingRole=nil; state.savingSince=nil end
    selected.telemetry.selected=true
    decision.selectedClass=selected.entry.class; decision.selectedCost=selected.estimate.cost
    decision.selectedCount=selected.count; decision.selectedProbability=selected.telemetry.probability
    return selected,decision
end

function RTS:SpawnAIProduction(kind,queued)
    local station=self:GetFactionCommandShip(kind); if not shipValid(station) or queued==nil then return nil end
    local state=self.AIStates[kind]; state.serial=(state.serial or 0)+1
    local prefix=kind=="BLUE" and "RTS Blue Auto" or (kind=="RED" and "RTS Red Production" or "RTS Gold Production")
    local count=queued.count or 1; local spawned={}; local wingLabel=count>1 and self:GetNextWingCallsign(kind) or nil
    for i=1,count do
        local name=wingLabel and (wingLabel.." "..tostring(i)) or nil
        local ship=self:SpawnFactionUnit(queued.entry.class,station,station.Team,prefix,queued.entry.tier or 1,state.serial,i,i,count,name,state.serial)
        if shipValid(ship) then spawned[#spawned+1]=ship; self:AssignAIStrategicOrder(ship,kind,true) end
    end
    if #spawned>1 then self:RegisterLogicalWing(spawned,wingLabel) end
    return spawned[1],spawned
end

-- ONE income ramp, two former copies. The AI used to run
-- 1 + 0.20*(tier-1) + LateGameIncomeRamp*p^2 while the player ran
-- 1 + 0.10*(tier-1) + 0.20*p^2, and the telemetry reported the PLAYER's number
-- for RED and GOLD. Late game that is 26.1 vs 17.6 CP/s: the AI was 48% richer
-- per second, the gap only widened, and Blue led combatant value in 0% of
-- samples across 32 matches with the lead changing hands 0 times. Blue's +144
-- starting CP was erased around t=300-500 s and never recovered.
--
-- The AI is now converged DOWN onto the player's curve rather than the player
-- up onto the AI's. The player's economy is the one the difficulty multiplier
-- and the existing tests already describe, and raising it 48% would flood the
-- mid-game with income whose second-order effects are unmeasured.
function RTS:GetAIIncomeRamp(now)
    local duration=self:GetDurationProfile()
    local target=(duration and duration.targetSeconds) or 1800
    local progress=clamp(self:GetScenarioElapsed(now)/math.max(1,target),0,1)
    local tier=self:GetCurrentEscalationTier(now)
    local cfg=self.Config.AI or {}
    local perTier=cfg.IncomeRampPerTier or 0.10
    local lateGame=cfg.LateGameIncomeRamp
    if lateGame==nil then lateGame=0.20 end
    return 1+perTier*(tier-1)+lateGame*progress*progress
end

function RTS:UpdateAIProduction(now)
    if self.Config.AI==nil or self.Config.AI.Enabled==false or self.SetupActive or self.ScenarioStartTime==nil or self.PostBattleActive then return end
    local duration=self:GetDurationProfile(); local difficulty=self.Config.Setup.Difficulties[self.SetupDifficultyIndex]; local target=duration.targetSeconds or 1800
    local progress=clamp(self:GetScenarioElapsed(now)/math.max(1,target),0,1); local tier=self:GetCurrentEscalationTier(now)
    local incomeRamp=self:GetAIIncomeRamp(now)
    -- Blue auto can be switched off mid-mission. AIStates.BLUE survives the
    -- switch, so without this the loop keeps syncing the player's CP, keeps
    -- choosing builds and keeps spawning Blue ships forever.
    local blueAutoOff=not self.AutoPlayerMode
    if blueAutoOff and self.AIStates and self.AIStates.BLUE
        and now-(self.BlueAutoStateLeakAt or -math.huge)>=(self.Config.AI.BlueAutoStateLeakInterval or 30) then
        self.BlueAutoStateLeakAt=now
        self:Log("BLUE auto production suppressed: AIStates.BLUE still present after Auto Mode off")
        self:EmitAIEvent("PRODUCTION",{action="BUILD_SUSPENDED",producer="AI",faction="BLUE",
            reason="AUTO_MODE_OFF",staleState=true},now)
    end
    for _,kind in ipairs(AI_FACTION_ORDER) do
        local state=self.AIStates and self.AIStates[kind]
        local station=self:GetFactionCommandShip(kind)
        -- No production state means the faction is not AI controlled here, and
        -- for Blue it also means Blue is not running automatically: only the
        -- player builds. RED and GOLD keep their own states untouched.
        if state == nil or (kind=="BLUE" and not self.AutoPlayerMode) then
        elseif not shipValid(station) then state.eliminated=true else
            if state.playerEconomy then state.cp=self.CommandPoints; state.lastIncome=now
            else
                local delta=math.max(0,now-(state.lastIncome or now)); local income=delta*state.income*incomeRamp*self:GetIncomeMultiplier(kind)
                state.cp=state.cp+income; self:RecordAIEconomyFlow(kind,"income",income); state.lastIncome=now
            end
            local cap=self:GetFleetCap(kind)
            if state.queue and now>=state.queue.finishTime then
                local queued=state.queue
                if self:CountFactionCombatants(kind)+(queued.count or 1)<=cap then
                    local first,spawned=self:SpawnAIProduction(kind,queued); local signatures={}
                    for _,ship in ipairs(spawned or {}) do if shipValid(ship) then signatures[#signatures+1]=ship:getSignature() end end
                    -- Spawn placement is the only observable proof that capitals
                    -- land near their own station instead of the enemy base, so
                    -- record where each hull actually appeared.
                    local placements={}
                    for _,ship in ipairs(spawned or {}) do
                        if shipValid(ship) and ship.Position then
                            placements[#placements+1]={signature=ship:getSignature(),x=ship.Position.x,y=ship.Position.y,z=ship.Position.z}
                        end
                    end
                    local failureReason=nil
                    if not first then failureReason="SPAWN_FAILED" end
                    self:EmitAIEvent("PRODUCTION",{action=first and "UNIT_SPAWNED" or "BUILD_FAILED",
                        producer="AI",faction=kind,class=queued.entry.class,role=queued.entry.role,
                        tier=queued.entry.tier or 1,requestedCount=queued.count or 1,spawnedCount=#signatures,
                        shipSignatures=signatures,cost=queued.estimate.cost,queuedAt=queued.queuedAt,
                        placements=placements,
                        startedAt=queued.startedAt or queued.queuedAt,completedAt=now,
                        buildSeconds=now-(queued.startedAt or queued.queuedAt or now),
                        capacityWaitSeconds=queued.blockedAt and math.max(0,now-queued.blockedAt) or 0,
                        reason=failureReason},now)
                    state.queue=nil
                elseif queued.blockedAt==nil then
                    queued.blockedAt=now
                    self:EmitAIEvent("PRODUCTION",{action="BUILD_BLOCKED",producer="AI",faction=kind,
                        class=queued.entry.class,count=queued.count or 1,cost=queued.estimate.cost,
                        reason="FLEET_CAP",finishTime=queued.finishTime},now)
                end
            end
            if state.queue==nil and now>=(state.nextThink or 0) then
                -- Sample the cap on the think cadence, not once per frame.
                -- nextThink used to be advanced as the last statement INSIDE
                -- this block, so a faction sitting at its fleet cap never
                -- advanced it: now>=nextThink stayed true forever and
                -- CountFactionCombatants - a full EachShip walk with a
                -- string.lower per hull - ran on every single frame, per
                -- capped faction, for the rest of the match.
                if self:CountFactionCombatants(kind)>=self:GetFleetCap(kind) then
                    state.nextThink=now+(self.Config.AI.ThinkInterval or 8)
                else
                    if state.playerEconomy then state.cp=self.CommandPoints end
                    local choice,decision=self:ChooseAIBuild(kind,state,now)
                    if decision then self:EmitAIEvent("AI_BUILD_DECISION",decision,now) end
                    if choice then
                        local before=state.cp
                        state.cp=state.cp-choice.estimate.cost; if state.playerEconomy then self.CommandPoints=state.cp end
                        local speed=difficulty.aiBuildSpeed or 1; local buildTime=choice.estimate.time*(duration.buildTimeScale or 1)*self:GetBuildTimeMultiplier(kind)/math.max(.25,speed)
                        state.queue={entry=choice.entry,estimate=choice.estimate,count=choice.count or 1,
                            queuedAt=now,startedAt=now,finishTime=now+buildTime}
                        self:RecordAIEconomyFlow(kind,"productionSpend",choice.estimate.cost)
                        self:EmitAIEvent("PRODUCTION",{action="QUEUE_ACCEPTED",producer="AI",faction=kind,
                            class=choice.entry.class,role=choice.category,tier=choice.entry.tier or 1,
                            count=choice.count or 1,cost=choice.estimate.cost,buildSeconds=buildTime,
                            cpBefore=before,cpAfter=state.cp,queuedAt=now,
                            selectionProbability=decision and decision.selectedProbability},now)
                    end
                    state.nextThink=now+(self.Config.AI.ThinkInterval or 8)
                end
            end
        end
    end
end
