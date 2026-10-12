-- Station AI targeting: priority list for enemy hulls near the station.
local _shared = require "fs2rts_station.common"
local RTS, shipAlive, cfg, canAutoEngage = _shared.RTS, _shared.shipAlive, _shared.cfg, _shared.canAutoEngage

-- ponytail: fixed priority list, not a planner; tune by reordering if the AI turtles or neglects its economy.
function RTS:UpdateStationAI(kind, state, station, now)
    if now < state.nextAIThink then return end
    -- Hoisted with defaults: cfg(self).AI was indexed bare here AND at the
    -- opening-fleet gate below, so a Station block without an AI subtable
    -- aborted the think from two separate sites. This is per-frame reachable
    -- (UpdateStations calls it for every AI faction).
    local aiCfg = cfg(self).AI or {}
    state.nextAIThink = now + (aiCfg.ThinkSeconds or 8)
    local reserve = aiCfg.ReserveCP or 0
    local tier=self:GetCurrentEscalationTier(now)
    local fleetReserve=math.huge
    for _,entry in ipairs(self:GetAIRoster(kind)) do
        if entry.tier<=tier then
            local count=(entry.role=="fighter" or entry.role=="bomber") and (self.Config.Economy.StrikeWingSize or 4) or 1
            local estimate=self:GetPurchaseEstimate(entry.class,entry.tier,count)
            if estimate then fleetReserve=math.min(fleetReserve,estimate.cost) end
        end
    end
    if fleetReserve<math.huge then reserve=math.max(reserve,fleetReserve) end
    local production=self.AIStates and self.AIStates[kind]
    -- Hoisted: "the producer could buy something right now" is the condition both
    -- the reserve fold and the capital gate below key off, and it was open-coded
    -- in one of them only.
    local producerActive=production~=nil and not production.queue
        and self:CountCommittedCombatants(kind)<self:GetFleetCap(kind)
    if producerActive then
        reserve=math.max(reserve,production.productionReserve or 0)
    end
    -- CAPITAL-AWARE STATION GATE. Station.AI.CapitalAwareInvestment, ships OFF,
    -- so every line of this block is inert until it is deliberately enabled.
    --
    -- What it fixes. production.productionReserve IS the producer's bankTarget
    -- (fs2rts_ai_production.lua:181), i.e. the whole price of the role package
    -- it is saving for, and affordable()'s min(reserve, StationReserveCap)
    -- below THROWS THAT VALUE AWAY whenever it exceeds the cap. So the reserve
    -- the comment there describes - existing "so the FLEET producer does not
    -- undercut its own saving goal" - never protects anything on the station
    -- side: inside a 600 s capital save window the station still buys any
    -- upgrade at cp >= cost + 1500, roughly 75 times per window against a bank
    -- climbing ~180-230 CP per think. Measured per faction per 3000 s match:
    -- upgrades 59,100-77,450 CP (29-38% of income), the bank peaking at
    -- 4,056-5,859 CP against capital targets of 7,700-31,275, and
    -- capital/heavy/juggernaut production of 0 in 4 of 4 headless matches.
    -- That is the AI draining the bank it is saving.
    --
    -- Why UPGRADES ONLY, not sentries. Sentries are 3-13% of income against the
    -- upgrade tree's 29-38%, and while the producer is in a capital save window
    -- it fields NOTHING (AI.FieldCheapHullWhileSaving ships false), so the ring
    -- is the base's only defence for the length of that window - the batch that
    -- took sentry builds from 67 to 7 per 4 matches cost 220-270 unit losses.
    -- StationReserveCap exists to keep sentries flowing and is load-bearing
    -- there; deferring them under this flag would re-create the defect ST-19
    -- forbids. This gate spends the dominant sink and leaves defence alone.
    --
    -- Why it cannot hang. The deferral is bounded by the producer's OWN longest
    -- declared save window (AI.HeavyCapitalSavingSeconds and siblings), which is
    -- how long the fleet producer is itself willing to wait for the goal. Past
    -- it the gate releases whether or not the bank moved. The clock is a
    -- LOCAL one (state.capitalGateSince) and is reset only when the condition
    -- stops holding - the goal became affordable, or the producer cleared
    -- savingRole by buying or by an emergency - so it is a bound on each
    -- CONTIGUOUS deferral, not a budget that a flickering condition can extend.
    -- Station.AI.CapitalAwareInvestmentMaxSeconds overrides the derived bound.
    --
    -- The affordability condition (cp < productionReserve) is also its own
    -- short escape: a cheap role target is reached in seconds of banking, so the
    -- deferral self-terminates long before the bound.
    local deferInvestment=false
    if aiCfg.CapitalAwareInvestment==true and producerActive
        and production.savingRole~=nil
        and (production.productionReserve or 0)>self:GetFactionCP(kind) then
        local windows=self.Config.AI or {}
        local limit=tonumber(aiCfg.CapitalAwareInvestmentMaxSeconds)
            or math.max(windows.MaxProductionSavingSeconds or 0,
                windows.CapitalSavingSeconds or 0, windows.HeavyCapitalSavingSeconds or 0,
                windows.JuggernautSavingSeconds or 0)
        -- Fail OPEN on a missing/zero bound: a limit of 0 means no deferral at
        -- all, which is the safe direction if the config is ever empty.
        if state.capitalGateSince==nil then state.capitalGateSince=now end
        if (now-(state.capitalGateSince or now))<limit then
            deferInvestment=true
        else
            state.capitalGateSince=nil
        end
    elseif state.capitalGateSince~=nil then
        state.capitalGateSince=nil
    end
    -- A funded explicit player request can be waiting on fleet capacity, so
    -- protect it even after its bank target is reachable and normal producer
    -- reservation would stop. A real emergency may spend; critical base armor
    -- may still upgrade while the request waits.
    local request=(kind=="BLUE") and production and production.AutoBuildRequest or nil
    local requestEmergency=self.AIProductionEmergency and self.AIProductionEmergency[kind]
    local requestEmergencyFresh=requestEmergency and requestEmergency.emergency==true
        and now-(requestEmergency.time or now)<=math.max(24,(self.Config.AI.StrategicOrderInterval or 12)*2)
    local protectAutoBuild=request~=nil and request.status~="BUILDING" and not requestEmergencyFresh
    local criticalStationHull=station.HitpointsLeft/math.max(1,station.HitpointsMax)
        <=((self.Config.AI.Doctrine or {}).CriticalStationHullFraction or .35)
    local function affordable(cost)
        -- The fleet producer's reserve exists so the FLEET producer does not
        -- undercut its own saving goal. It must not freeze base investment.
        -- productionReserve is bankTarget - the full price of the role package
        -- being saved for - so at tier 5 a 375 CP sentry needed ~14,200 CP in
        -- the bank, and headless batches showed every faction building ZERO
        -- sentries for a whole match while the fleet sat on a capital bank.
        -- Cap how much of that reserve base investment has to clear; the fleet
        -- reserve still throttles fleet overspend, and the base can keep buying.
        local stationReserve=math.min(reserve,math.max(0,tonumber(aiCfg.StationReserveCap) or 1500))
        return self:GetFactionCP(kind) >= cost + stationReserve
    end
    local function tryUpgrade(track)
        -- One gate for every upgrade path in this function: the damaged-station
        -- armour buy, the free LOGISTICS L1, and the priority loop below. It is
        -- deliberately NOT inside affordable(), which stays shared with the
        -- sentry scan - deferring defence while the producer goes dark to save
        -- is the trade this flag must not make (see the block above).
        if protectAutoBuild and not (track=="armor" and criticalStationHull) then return false end
        if deferInvestment and not (track=="armor" and criticalStationHull) then return false end
        local offer, reason = self:GetUpgradeOffer(kind, track, now)
        if offer and reason == nil and affordable(offer.cost) then return self:BuyUpgrade(kind, track) end
        return false
    end

    -- Paid abilities wait behind either a fleet savings target or a pending
    -- requested hull; a fresh emergency may spend for defense.
    if not deferInvestment and not protectAutoBuild and self:IsAbilityReady(kind) then
        if self:GetFactionAbilityProfile(kind).kind=="strike" then
            local target = self:FindStrikeTarget(kind, station)
            if target then
                self:QueueOrbitalStrike(kind, target.Position)
            else
                self:NoteAbilityRefusal(kind, "no strike target in range")
            end
        else
            self:UseFactionAbility(kind)
        end
    end

    local hullFraction = station.HitpointsLeft / math.max(1, station.HitpointsMax)
    if hullFraction < 0.7 and tryUpgrade("armor") then return end
    if self:GetUpgradeLevel(kind, "logistics") == 0 and tryUpgrade("logistics") then return end
    -- Build an opening fleet before spending the production budget on a ring
    -- of defenses; otherwise this new CP sink removes early attack pressure.
    --
    -- The threshold has to be a RAMP, not a wall. It was a bare count with no
    -- recovery, and it sat in front of the sentry ring AND the whole upgrade
    -- loop: a faction that could not hold OpeningFleetThreshold hulls alive -
    -- a player who out-produces it, or a production director starved of CP -
    -- was locked out of sentries and out of COMMAND L3, the tier its ability
    -- keys off, for the remainder of the match. Past OpeningFleetSeconds of
    -- scenario time the gate opens unconditionally so progression can never be
    -- permanently denied. OpeningFleetSeconds (150) sits well inside the
    -- COMMAND L2/L3 tier unlocks (300/900 by default), so it does not change
    -- the intended opening in a normal match.
    if self:CountFactionCombatants(kind) < (aiCfg.OpeningFleetThreshold or 8)
        and self:GetScenarioElapsed(now) < (aiCfg.OpeningFleetSeconds or 150) then return end
    local sentries = self:GetFactionSentries(kind)
    -- Hoisted: GetSentryRadius reads the station hull and the command level, so
    -- it is the same number for every ship in the loop. It was recomputed per
    -- enemy hull inside the scan.
    local threatRadius = self:GetSentryRadius(kind) + 3000
    local threats={fighter=0,bomber=0,capital=0}; local total=0
    for _,ship in ipairs(self:GetShipList()) do
        if shipAlive(ship) and canAutoEngage(self,station,ship) and not self:IsCommandStation(ship)
            and station.Position:getDistance(ship.Position)<threatRadius then
            local role=self:GetShipRole(ship)
            local cat=self:IsCapitalTarget(ship) and "capital" or (role=="bomber" and "bomber" or "fighter")
            threats[cat]=threats[cat]+1; total=total+1
        end
    end
    local desired=threats.capital>0 and "beam" or (threats.bomber>threats.fighter and "missile" or (threats.fighter>2 and "flak" or "screen"))
    local limit=math.min(self:GetSentryCap(kind),2+math.ceil(total/3))
    -- Reuse the list built above; GetSentrySlotCount walked StaticDefenseSignatures
    -- a second time for data this function was already holding.
    if self:GetSentrySlotCount(kind,sentries)<limit then
        local best,score=nil,-math.huge
        for _,option in ipairs(self:GetSentryOptions(kind)) do
            if option.tier<=tier and affordable(option.cost) then
                local value=(option.role==desired and 10 or 0)-option.cost/1000
                if value>score then best,score=option,value end
            end
        end
        local pos=best and self:FindSentrySpot(kind)
        if pos and self:PlaceSentry(kind,best,pos,false) then return end
    end
    -- Defenses before command. DEFENSES L1 and COMMAND L2 both add exactly one
    -- CapBonus of sentry slots (GetSentryCap), but command L2 costs 1750
    -- against defenses L1's 750. Asking for command first spent 2.3x the CP
    -- for an identical benefit and left the cheaper track permanently out of
    -- reach for the rest of the match.
    for _, track in ipairs({ "logistics", "defenses", "command", "armor" }) do
        if (track~="defenses" and track~="armor") or total>0 then
            if tryUpgrade(track) then return end
        end
    end
end
