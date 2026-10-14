-- Station upgrades and per-faction command-point accounting.
local _shared = require "fs2rts_station.common"
local U, RTS, shipValid, shipAlive, objectValid, cfg = _shared.U, _shared.RTS, _shared.shipValid, _shared.shipAlive, _shared.objectValid, _shared.cfg

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
function RTS:ResetStationState()
    self.NextSentryAimUpdate=0
    self.NextStationPointDefense=0
    self.FleetServices={}; self.FleetServiceSerial=0; self.FleetServiceCooldown={}; self.SurvivalDangerSince={}; self.NextFleetServiceThink=0
    self.BountyProcessed={}
    self.StationState = {}
    for _, kind in ipairs(self.Config.FactionOrder or U.AI_FACTION_ORDER) do
        self.StationState[kind] = { levels = { armor = 0, defenses = 0, logistics = 0, command = 0 },
            upgrade = nil, abilityReadyAt = 0, lastHull = nil, lastDamageAt = -100, nextAIThink = 0, sentrySerial = 0,
            lastTurretHits = {},
            -- Start of the current contiguous base-investment deferral, owned by
            -- the capital gate in UpdateStationAI (AI.CapitalAwareInvestment,
            -- ships off). Listed here so a mission restart cannot inherit a stale
            -- clock; nil = not deferring.
            capitalGateSince = nil }
    end
    -- SentryNames and SentryHulls are the identity half of the sentry bookkeeping.
    -- Object signatures are RECYCLED by the engine, so a signature alone cannot
    -- tell "the sentry I built" from "whatever hull was handed that number
    -- later". The name is unique per sentry; the handle is what decides
    -- liveness, because a new ship's signature does not resolve until the next
    -- engine frame. Cleared here so a restart cannot resurrect a stale bonus -
    -- ResetState calls this before anything reads it.
    self.SentryCosts = {}; self.SentryNames = {}; self.SentryHulls = {}; self.SentryHullBoosted = {}; self.DefenseRateBoosted = {}; self.MjolnirRangeLocks={}; self.NextMjolnirRangeUpdate=0; self.PendingSentries = {}; self.PendingSentrySerial=0; self.PendingStrikes = {}; self.SurgedShips = {}
    self.PanelTab = "production"; self.PanelTabRects = {}; self.StationButtonRects = {}; self.ArmedSentryIndex = nil
end

function RTS:GetStationState(kind)
    if self.StationState == nil then self:ResetStationState() end
    return self.StationState[kind]
end

function RTS:GetUpgradeLevel(kind, track)
    local state = self:GetStationState(kind)
    return state and state.levels[track] or 0
end

-- ---------------------------------------------------------------------------
-- Effects read by the economy, fleet cap and build queue
-- ---------------------------------------------------------------------------
function RTS:GetFleetCap(kind)
    local base = kind == "BLUE" and self.Config.Economy.FleetCap or (self.Config.AI.FleetCap or 64)
    if self:GetUpgradeLevel(kind, "command") >= 1 then base = base + (cfg(self).FleetCapBonus or 0) end
    return base
end

function RTS:GetIncomeMultiplier(kind)
    return cfg(self).IncomeMultiplier[self:GetUpgradeLevel(kind, "logistics") + 1] or 1
end

function RTS:GetBuildTimeMultiplier(kind)
    return cfg(self).BuildTimeMultiplier[self:GetUpgradeLevel(kind, "logistics") + 1] or 1
end

function RTS:GetBuildQueueSlots(kind)
    return self:GetUpgradeLevel(kind,"logistics")>=3 and 2 or 1
end

function RTS:GetSentryCap(kind)
    local s = cfg(self).Sentries; local cap = s.Cap or 6
    local bonus = s.CapBonus or 0
    cap = cap + bonus * self:GetUpgradeLevel(kind,"defenses")
    if self:GetUpgradeLevel(kind, "command") >= 2 then cap = cap + bonus end
    return cap
end

-- `sentries` lets a caller that already built the faction's sentry list this
-- tick hand it in: walking StaticDefenseSignatures here a second time made
-- UpdateStationAI scan the same data twice every think interval.
function RTS:GetSentrySlotCount(kind, sentries)
    local count=sentries and #sentries or #self:GetFactionSentries(kind)
    for _,job in ipairs(self.PendingSentries or {}) do if job.kind==kind then count=count+1 end end
    return count
end

-- Measured from the station's hull so large station models still leave room.
function RTS:GetSentryRadius(kind)
    local s = cfg(self).Sentries
    local station = self:GetFactionCommandShip(kind)
    local hull = shipValid(station) and station.Class.Model and station.Class.Model.Radius or 0
    -- Arithmetic on a missing ControlRadius raises "attempt to perform
    -- arithmetic on field 'ControlRadius'". This is per-frame: the map overlay
    -- draws the placement ring, the panel prints the range, and CheckSentrySpot
    -- gates every cursor click on it.
    return hull + (s.ControlRadius or 4000) + (self:GetUpgradeLevel(kind, "command") >= 2 and (s.RadiusBonus or 2000) or 0)
end

-- ---------------------------------------------------------------------------
-- Command points: Blue spends the player pool, AI factions their own pool.
-- ---------------------------------------------------------------------------
function RTS:GetFactionCP(kind)
    if kind == "BLUE" then return self.CommandPoints or 0 end
    local s = self.AIStates and self.AIStates[kind]
    return s and s.cp or 0
end

function RTS:SpendFactionCP(kind, amount)
    if self.AftermathActive then return false end
    if self:GetFactionCP(kind) < amount then return false end
    if kind == "BLUE" then self.CommandPoints = self.CommandPoints - amount
    else self.AIStates[kind].cp = self.AIStates[kind].cp - amount end
    self:RecordAIEconomyFlow(kind, "productionSpend", amount)
    return true
end

function RTS:RefundFactionCP(kind, amount)
    if kind == "BLUE" then self.CommandPoints = self.CommandPoints + amount
    elseif self.AIStates and self.AIStates[kind] then self.AIStates[kind].cp = self.AIStates[kind].cp + amount end
    self:RecordAIEconomyFlow(kind, "refund", amount)
end

-- ---------------------------------------------------------------------------
-- Upgrades
-- ---------------------------------------------------------------------------
function RTS:ApplyStationDefenseProgression(kind,level)
    local station=self:GetFactionCommandShip(kind)
    if not shipValid(station) then return end
    level=math.max(0,math.min(3,tonumber(level) or self:GetUpgradeLevel(kind,"defenses")))
    local guns,beams={},{}
    for i=1,#station do
        local turret=station[i]
        if objectValid(turret) and turret:isTurret() then
            local hasBeam=false
            for _,banks in ipairs({turret.PrimaryBanks or {},turret.SecondaryBanks or {}}) do
                for bankIndex=1,#banks do
                    local bank=banks[bankIndex]
                    local weapon=bank.WeaponClass
                    if objectValid(weapon) and weapon:isBeam() then hasBeam=true; break end
                end
                if hasBeam then break end
            end
            local list=hasBeam and beams or guns
            list[#list+1]=turret
        end
    end
    local activeGuns=level==1 and math.ceil(#guns/2) or level>=2 and #guns or 0
    for i,turret in ipairs(guns) do turret.TurretLocked=i>activeGuns end
    for _,turret in ipairs(beams) do turret.TurretLocked=level<3 end
end

-- Returns the next level's info plus a reason string when it can't be bought.
function RTS:GetUpgradeOffer(kind, track, now)
    if self.AftermathActive then return nil,'SURVIVORS ONLY' end
    if not shipAlive(self:GetFactionCommandShip(kind)) then return nil, "DESTROYED" end
    local t = cfg(self).Tracks[track]; local level = self:GetUpgradeLevel(kind, track)
    if level >= 3 then return nil, "MAX" end
    local offer = { track = track, level = level + 1, cost = t.costs[level + 1], seconds = t.seconds[level + 1],
        tier = t.tiers[level + 1], desc = t.desc[level + 1] }
    local state = self:GetStationState(kind)
    if state.upgrade ~= nil then return offer, "BUSY" end
    if self:GetCurrentEscalationTier(now) < offer.tier then return offer, "TIER" end
    if self:GetFactionCP(kind) < offer.cost then return offer, "CP" end
    return offer, nil
end

function RTS:BuyUpgrade(kind, track)
    local now = mn.getMissionTime()
    local offer, reason = self:GetUpgradeOffer(kind, track, now)
    if offer == nil or reason ~= nil then
        if kind == "BLUE" then
            local msg = { MAX = "Upgrade maxed", BUSY = "Station is already upgrading", CP = "Insufficient command points", DESTROYED = "Station destroyed" }
            self:SetStatus(reason == "TIER" and ("Needs escalation tier " .. offer.tier) or msg[reason] or "Unavailable", 2)
        end
        return false
    end
    if not self:SpendFactionCP(kind, offer.cost) then return false end
    local duration = self:GetEscalationProfile()
    local scale = duration and duration.buildTimeScale or 1
    self:GetStationState(kind).upgrade = { track = track, level = offer.level, cost = offer.cost,
        startTime = now, finishTime = now + offer.seconds * scale }
    if kind == "BLUE" then self:SetStatus("Station upgrade started: " .. cfg(self).Tracks[track].label .. " L" .. offer.level, 2) end
    return true
end

function RTS:ApplyUpgrade(kind, track, level)
    local station = self:GetFactionCommandShip(kind)
    if track == "armor" and shipValid(station) then
        local mult = cfg(self).ArmorHull
        local ratio = (mult[level + 1] or 1) / (mult[level] or 1)
        -- Capacity only. Scaling HitpointsLeft by the same ratio was a free
        -- repair proportional to how damaged the station already was, and
        -- because scarHull is absolute rather than proportional the damage cap
        -- made that worse the longer the fight went on. The added capacity is
        -- simply available; recovering into it is the repair track's job.
        station.HitpointsMax = station.HitpointsMax * ratio
        station.HitpointsLeft = math.min(station.HitpointsLeft, station.HitpointsMax)
        self:GetStationState(kind).scarHull=(self:GetStationState(kind).scarHull or 0)*ratio
        self:GetStationState(kind).lastRepairTime = mn.getMissionTime()
    elseif track == "defenses" then
        self:ApplyStationDefenseProgression(kind,level)
        if level == 2 then
            for _, ship in ipairs(self:GetFactionSentries(kind)) do self:ApplySentryHullBonus(ship) end
        elseif level == 3 then
            self:ApplyDefenseFireRate(station)
            for _,ship in ipairs(self:GetFactionSentries(kind)) do self:ApplyDefenseFireRate(ship) end
        end
    end
end

function RTS:ApplyDefenseFireRate(ship)
    if not shipAlive(ship) then return end
    local sig = ship:getSignature()
    -- The guard is an idempotence check for a mutation that is NOT idempotent
    -- (it multiplies rof_scaler), so a false positive is permanent damage: this
    -- hull silently keeps its stock rate forever. A recycled signature used to
    -- produce exactly that false positive. Require the record to still belong
    -- to THIS hull before believing it.
    if self.DefenseRateBoosted[sig] and self:SentryRecordMatches(sig, ship) then return end
    local mult = cfg(self).DefenseFireRate or 1.25
    for i=1,#ship do
        local turret=ship[i]
        if turret:isTurret() then
            -- FireRateMultiplier is the engine's rof_scaler verbatim
            -- (subsystem.cpp:415-434), and zero is NOT a rate: it is the
            -- "$ROF: +Use firingpoints" sentinel the POF parser stores
            -- (ship.cpp:5564-5567) and the same value an invalid subsystem
            -- handle reports. Multiplying it wrote 0 straight back, so the boost
            -- silently did nothing on exactly the turrets the upgrade claims to
            -- cover, and it disagreed with the value the engine itself uses:
            -- once get_adjusted_turret_rof has resolved the sentinel it rewrites
            -- rof_scaler to the firing-point count (aiturret.cpp:2989-2992), so
            -- the same upgrade would then compound that count instead. Treat a
            -- non-positive reading as "no stated rate" and apply the multiplier
            -- to 1.0, the same default the engine resets to.
            local current = turret.FireRateMultiplier
            if not (current > 0) then current = 1 end
            turret.FireRateMultiplier = current * mult
        end
    end
    self.DefenseRateBoosted[sig]=true
end

-- True when the bookkeeping filed under `sig` still describes `ship`. A
-- signature is a recyclable slot, so the name filed at creation time is what
-- makes a SENTRY record trustworthy: same signature AND same hull.
--
-- "No name on file" is NOT a mismatch and must not fail this test. ApplyUpgrade
-- runs ApplyDefenseFireRate over the command STATION as well as the sentries,
-- and a station was never registered in SentryNames at all. Treating that as a
-- mismatch would make every station re-apply its rate boost on each
-- re-evaluation and compound the multiplier. So:
--   * no name filed      -> not a sentry record; the boost flag alone guards it
--   * name matches       -> the record is this hull's, trust the flag
--   * name differs       -> a recycled signature; the flag is a false positive
--                           and the new hull must be boosted
function RTS:SentryRecordMatches(sig, ship)
    local name = self.SentryNames and self.SentryNames[sig]
    if name == nil then return true end
    return name == ship.Name
end

-- ---------------------------------------------------------------------------
-- Sentries
-- ---------------------------------------------------------------------------
function RTS:GetFactionSentryClassList(kind)
    local classes=cfg(self).Sentries.Classes or {}
    local faction=self:GetFactionDefinition(kind)
    local species=self:GetFactionSpecies(kind)
    local raceKey=species=="SHIVAN" and "RED" or species=="VASUDAN" and "GOLD" or "BLUE"
    if faction and species==faction.defaultSpecies and classes[kind] then return classes[kind] end
    return classes[raceKey] or classes[kind] or {}
end
