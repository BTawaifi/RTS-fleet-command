-- Station upgrades, placeable sentries and faction command abilities.
local U = require "fs2rts_util"
local RTS = require "fs2rts_state"
local clamp, vec, copyVec, distance2, shipValid, shipAlive = U.clamp, U.vec, U.copyVec, U.distance2, U.shipValid, U.shipAlive

local TRACKS = { "armor", "defenses", "logistics", "command" }
local FACTIONS = { "BLUE", "RED", "GOLD" }

local function cfg(self) return self.Config.Station end

local function flatDistance(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

local function refreshSurgeBase(base, current, applied)
    local function component(axis)
        return math.abs(current[axis]-applied[axis])>0.001 and current[axis] or base[axis]
    end
    return vec(component("x"),component("y"),component("z"))
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
function RTS:ResetStationState()
    self.FleetServices={}; self.FleetServiceCooldown={}; self.SurvivalDangerSince={}; self.NextFleetServiceThink=0
    self.BountyProcessed={}
    self.StationState = {}
    for _, kind in ipairs(FACTIONS) do
        self.StationState[kind] = { levels = { armor = 0, defenses = 0, logistics = 0, command = 0 },
            upgrade = nil, abilityReadyAt = 0, lastHull = nil, lastDamageAt = -100, nextAIThink = 0, sentrySerial = 0,
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
    if self:GetUpgradeLevel(kind, "defenses") >= 1 then cap = cap + bonus end
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
-- Returns the next level's info plus a reason string when it can't be bought.
function RTS:GetUpgradeOffer(kind, track, now)
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
    local duration = self:GetDurationProfile()
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
    elseif track == "defenses" and level == 2 then
        for _, ship in ipairs(self:GetFactionSentries(kind)) do self:ApplySentryHullBonus(ship) end
    elseif track == "defenses" and level == 3 then
        self:ApplyDefenseFireRate(station)
        for _,ship in ipairs(self:GetFactionSentries(kind)) do self:ApplyDefenseFireRate(ship) end
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
function RTS:GetSentryOptions(kind)
    local result = {}
    -- cfg(self).Sentries.Classes[kind] raised when Classes was absent. This is
    -- a per-frame path (the panel draws one button per option, and the AI reads
    -- it every think), and FSO only LOGS an exception thrown inside a script
    -- hook, so the whole HUD frame was silently aborted instead.
    for _, entry in ipairs((cfg(self).Sentries.Classes or {})[kind] or {}) do
        local class = tb.ShipClasses[entry.class]
        if class and class:isValid() then result[#result + 1] = entry end
    end
    return result
end

function RTS:GetFactionSentries(kind)
    local result = {}
    self:PruneStaleSentryRecords()
    for sig in pairs(self.StaticDefenseSignatures or {}) do
        local ship = self:FindShipBySignature(sig)
        if shipAlive(ship) and self:GetFactionKey(ship) == kind then result[#result + 1] = ship end
    end
    return result
end

-- Every table in the mod that is keyed by an object signature shares one
-- hazard: FSO RECYCLES signatures, so a record left behind by a sentry that
-- died (or was sold, or whose faction was eliminated) is inherited by whatever
-- unrelated hull is later handed that number. The consequences are silent and
-- all of them were live before this function existed:
--   * StaticDefenseSignatures -> IsStaticDefense() said "sentry" about a
--     freighter, so it stopped counting against the fleet cap and could not be
--     selected, ordered or sold as the combat ship it was.
--   * DefenseRateBoosted -> ApplyDefenseFireRate returned early, so a genuinely
--     new sentry never got the DEFENSES L3 +25% rate it had paid for.
--   * SentryCosts -> selling that hull paid out another sentry's price.
--   * MjolnirRangeLocks -> turret lock state from a hull that no longer exists.
-- The elimination path that should have cleared these lives in lifecycle.lua,
-- which this module does not own, so the prune is defensive and runs on the read
-- path instead.
--
-- Liveness is decided from the retained hull handle (SentryHulls), NOT from
-- whether the signature still resolves. FSO registers a newly created ship's
-- signature on the NEXT engine frame, so a prune that required the signature to
-- resolve would delete the record of a sentry that was built moments earlier -
-- the same reason UseSwarmSurge keeps its handle in SurgedShips. Two independent
-- stale signals are used instead, and both must be checked against the handle:
--   * the recorded hull is gone (shipValid false) - it died, vanished or was sold
--   * the signature now resolves to a DIFFERENT hull - the number was recycled
function RTS:PruneStaleSentryRecords()
    local signatures = self.StaticDefenseSignatures
    if signatures == nil then return end
    local hulls, names = self.SentryHulls, self.SentryNames
    for sig in pairs(signatures) do
        local stale = false
        if hulls ~= nil then
            local recorded = hulls[sig]
            -- No handle on file means the record predates the identity fields
            -- (or ResetStationState ran): fall back to the signature lookup.
            if recorded ~= nil then
                if not shipValid(recorded) then
                    stale = true
                else
                    local resolved = self:FindShipBySignature(sig)
                    if resolved ~= nil and (names ~= nil and names[sig] ~= resolved.Name) then stale = true end
                end
            else
                stale = not shipAlive(self:FindShipBySignature(sig))
            end
        else
            stale = not shipAlive(self:FindShipBySignature(sig))
        end
        if stale then self:ForgetSentryRecord(sig) end
    end
end

-- Drop every signature-keyed record for one hull. One writer so the tables can
-- never drift apart again: SellSelectedSentries cleared three of the five, and
-- the two it missed (DefenseRateBoosted, MjolnirRangeLocks) are exactly the
-- ones that outlive a sold sentry.
function RTS:ForgetSentryRecord(sig)
    if self.StaticDefenseSignatures then self.StaticDefenseSignatures[sig] = nil end
    if self.SentryCosts then self.SentryCosts[sig] = nil end
    if self.SentryHulls then self.SentryHulls[sig] = nil end
    if self.SentryNames then self.SentryNames[sig] = nil end
    if self.SentryHullBoosted then self.SentryHullBoosted[sig] = nil end
    if self.DefenseRateBoosted then self.DefenseRateBoosted[sig] = nil end
    if self.MjolnirRangeLocks then self.MjolnirRangeLocks[sig] = nil end
end

function RTS:ApplySentryHullBonus(ship)
    self.SentryHullBoosted = self.SentryHullBoosted or {}
    if not shipValid(ship) then return end
    local sig = ship:getSignature()
    -- Same recyclable-signature hazard as ApplyDefenseFireRate: the mutation is
    -- a hull multiplier, so skipping it leaves a paid-for DEFENSES L2 hull at
    -- its unboosted value.
    if self.SentryHullBoosted[sig] and self:SentryRecordMatches(sig, ship) then return end
    local bonus = cfg(self).Sentries.HullBonus or 1.5
    ship.HitpointsMax = ship.HitpointsMax * bonus
    ship.HitpointsLeft = ship.HitpointsLeft * bonus
    self.SentryHullBoosted[sig] = true
end

-- Returns nil or a reason string for an invalid sentry position.
-- `sentries` is the same escape hatch as GetSentrySlotCount: FindSentrySpot
-- calls this up to 12 times per placement and each call used to rebuild the
-- faction's sentry list from StaticDefenseSignatures, so a full cap meant 12
-- full scans (a team lookup, a tostring and a string.lower per hull) for one
-- cursor position.
function RTS:CheckSentrySpot(kind, pos, excludedJob, option, sentries)
    if not self:IsFiniteVector(pos) then return "Invalid position" end
    local station = self:GetFactionCommandShip(kind)
    if not shipAlive(station) then return "Station destroyed" end
    local _, clipped = self:ClampCommandPoint(pos, 0)
    if clipped then return "Outside the battlefield" end
    local d = flatDistance(pos, station.Position)
    local stationRadius = station.Class.Model and station.Class.Model.Radius or 500
    if d > self:GetSentryRadius(kind) then return "Too far from your station" end
    local sentryRadius=option and tb.ShipClasses[option.class] and tb.ShipClasses[option.class].Model
        and tb.ShipClasses[option.class].Model.Radius or 0
    if sentryRadius==0 then
        for _,candidate in ipairs(self:GetSentryOptions(kind)) do
            local cls=tb.ShipClasses[candidate.class]
            sentryRadius=math.max(sentryRadius,cls and cls.Model and cls.Model.Radius or 0)
        end
    end
    if d < stationRadius + sentryRadius + 300 then return "Too close to your station" end
    local spacing = cfg(self).Sentries.MinSpacing
    for _, other in ipairs(sentries or self:GetFactionSentries(kind)) do
        local otherRadius=other.Class.Model and other.Class.Model.Radius or 0
        if flatDistance(pos, other.Position) < math.max(spacing,sentryRadius+otherRadius+150) then return "Too close to another sentry" end
    end
    for _,job in ipairs(self.PendingSentries or {}) do
        if job.kind==kind and job.id~=excludedJob then
            local cls=tb.ShipClasses[job.option.class]; local otherRadius=cls and cls.Model and cls.Model.Radius or 0
            if flatDistance(pos,job.pos)<math.max(spacing,sentryRadius+otherRadius+150) then return "Too close to another sentry" end
        end
    end
    return nil
end

function RTS:FindSentrySpot(kind)
    local station = self:GetFactionCommandShip(kind)
    if not shipAlive(station) then return nil end
    -- Face the nearest enemy station so AI sentries cover the likely approach.
    local facing = nil; local best = math.huge
    for _, other in ipairs(FACTIONS) do
        if other ~= kind and self:IsFactionEnabled(other) then
            local enemy = self:GetFactionCommandShip(other)
            if shipValid(enemy) then
                local d = flatDistance(enemy.Position, station.Position)
                if d < best then best = d; facing = math.atan2(enemy.Position.x - station.Position.x, enemy.Position.z - station.Position.z) end
            end
        end
    end
    facing = facing or math.random() * math.pi * 2
    local radius = self:GetSentryRadius(kind)
    local largest=0; for _,option in ipairs(self:GetSentryOptions(kind)) do local cls=tb.ShipClasses[option.class]; largest=math.max(largest,cls and cls.Model and cls.Model.Radius or 0) end
    local inner = (station.Class.Model and station.Class.Model.Radius or 500) + largest + 300
    -- One sentry list for the whole search: the per-attempt CheckSentrySpot
    -- used to rebuild it 12 times over.
    local sentries = self:GetFactionSentries(kind)
    for _ = 1, 12 do
        local angle = facing + (math.random() - 0.5) * 2.2
        local r = inner + (radius - inner) * (0.25 + math.random() * 0.65)
        local pos = vec(station.Position.x + math.sin(angle) * r, station.Position.y, station.Position.z + math.cos(angle) * r)
        if self:CheckSentrySpot(kind, pos, nil, nil, sentries) == nil then return pos end
    end
    return nil
end

-- The direction a new sentry should point, as a unit vector in the xz plane.
--
-- Two measured reasons this exists at all, both from batch capgate-20261001
-- (4 matches, streamed in full):
--
--  1. ARC. Stations are spawned facing map centre (fs2rts_lifecycle.lua,
--     towardCenter), which measured 30 deg off the bearing to the owner's
--     nearest enemy station. CreateSentry used to hand every non-beam role
--     that same station orientation, and FindSentrySpot then placed the hull
--     a further +-63 deg off. Measured sentry bearing error against the real
--     enemy axis: p50 29-37 deg, max 55 deg. Turret FOV is a hard engine gate
--     (aiturret.cpp:2667 requires in_fov before the shot; turret_std_fov_test
--     :2932), so a hull pointed away cannot shoot at a target it is in range
--     of. This was independent of reach: fixing reach alone would have left
--     roughly a third of the ring unable to engage.
--
--  2. FACTION-SPECIFIC. In a three-way battle a sentry ring defends against
--     two different enemy axes, not one. Aiming at the map centre, or at
--     whichever station happens to be nearest, points the ring at the wrong
--     faction whenever the nearest enemy is not the one attacking.
--
-- The nearest live hostile SHIP is preferred over the nearest enemy station:
-- a hull is what actually arrives, it is the thing the guns are rated against,
-- and on a three-way board it removes the "nearest station is not the
-- attacker" failure entirely. Station bearing is the fallback for an
-- uncontested or not-yet-contacted board, so the first sentries of a match
-- still point somewhere useful.
--
-- COST. This runs ONCE per CreateSentry, never per tick and never per frame:
-- the search is a single walk of the ship list at build completion, at most
-- 6-10 times per match per faction. The runtime alternative - re-aiming every
-- live sentry at the nearest threat each interval - is not available anyway:
-- the scripting API exposes no way to set a ship's orientation after
-- mn.createShip (ship.cpp ADE surface has turnTowardsPoint and
-- turnTowardsOrientation but no setter), so a hull's facing is fixed for its
-- whole life. A 3-platform ring therefore never scans the ship list per tick.
function RTS:SentryAimVector(kind, pos)
    local station = self:GetFactionCommandShip(kind)
    local fromX = pos.x; local fromZ = pos.z
    if shipAlive(station) then
        local originX = station.Position.x; local originZ = station.Position.z
        local best = math.huge; local aimX, aimZ
        -- NUMERIC for over mn.Ships, never ipairs. Bisected against
        -- fs2_open_26_1_0_x64_AVX2: `for _,o in ipairs(mn.Ships or {}) do n=n+1 end`
        -- on its own, inserted into capgate's CreateSentry and nothing else,
        -- aborts the process with 0xE06D7363 (C++ exception) ~310 s into a
        -- headless run - before the first sentry finishes construction. The
        -- numeric form is clean (exit 0) and is the idiom this mod already uses
        -- for every other ship walk (fs2rts_station.lua:201, :567). l_Ship is a
        -- table of engine handles whose iteration is not safe through
        -- ipairs' C iterator protocol here; this is not a cost trade-off,
        -- the other form does not run at all.
        -- does not run at all.
        for i=1,#mn.Ships do
            local other = mn.Ships[i]
            if other and other:isValid() and not other:isDying() then
                local owner = self:GetFactionKey(other)
                if owner and owner ~= kind and not self:IsStaticDefense(other) then
                    local dx = other.Position.x - fromX
                    local dz = other.Position.z - fromZ
                    local d = dx*dx + dz*dz
                    if d < best and d > 1 then best = d; aimX, aimZ = dx, dz end
                end
            end
        end
        local length = math.sqrt(best)
        if aimX and length > 1 then
            return aimX/length, aimZ/length
        end
        -- No hostile hull yet: aim at the nearest enemy STATION so the opening
        -- ring is not pointing at empty space.
        best = math.huge; aimX, aimZ = nil, nil
        for _, other in ipairs(FACTIONS) do
            if other ~= kind and self:IsFactionEnabled(other) then
                local enemy = self:GetFactionCommandShip(other)
                if shipValid(enemy) then
                    local dx = enemy.Position.x - originX
                    local dz = enemy.Position.z - originZ
                    local d = dx*dx + dz*dz
                    if d < best then best = d; aimX, aimZ = dx, dz end
                end
            end
        end
        length = math.sqrt(best)
        if aimX and length > 1 then
            -- Direction is station-to-station, not sentry-to-station: the ring
            -- is 2.6-6.1 km out and aiming back at the base would point the
            -- guns at own hull.
            return aimX/length, aimZ/length
        end
    end
    return nil
end

function RTS:CreateSentry(kind, option, pos, free)
    local station=self:GetFactionCommandShip(kind)
    -- station.Orientation is read below and CreateSentry is reached from three
    -- call sites (the free path, the build-completion path, and the AI), only
    -- two of which re-check the station inside the same call. shipAlive, not
    -- shipValid: a station at 0 HP is still a valid Lua object, so validity
    -- alone does not stop the read, and FSO only LOGS an exception thrown
    -- inside a script hook, which would silently abort the rest of that
    -- frame's hook for whoever called in.
    if not shipAlive(station) then return nil end
    -- EVERY role aims at the owner's actual hostile, not just the beam role.
    -- Three defects are fixed here at once, all proven against capgate-20261001.
    --
    -- (a) Only the beam role was aimed at all. `if option.role=="beam" then`
    --     left 99.26% of every ring built in capgate - all screen, flak and
    --     missile hulls - inheriting station.Orientation. Stations spawn
    --     facing map centre (fs2rts_lifecycle.lua, towardCenter), measured
    --     30 deg off the bearing to the owner's nearest enemy, and
    --     FindSentrySpot then scatters the hull a further +-63 deg. Measured
    --     sentry bearing error against the real enemy axis: p50 29-37 deg, max
    --     55 deg. Turret FOV is a hard engine gate (aiturret.cpp:2667 requires
    --     in_fov before the shot; turret_std_fov_test :2932), so a hull pointed
    --     away cannot fire at a target it is already in range of.
    --
    -- (b) The vector arguments were in the wrong order, which made (a) worse
    --     than inert: the old call was
    --         createOrientationFromVectors(vec(0,-1,0), vec(aimX,0,aimZ))
    --     but the engine signature is [fvec, uvec, rvec] (base.cpp:179) and
    --     vm_vector_2_matrix assigns the FIRST vector straight to m.vec.fvec
    --     (vecmat.cpp:898). So every explicitly aimed sentry was built with
    --     forward vector (0,-1,0) - nose straight down at the floor - and the
    --     real aim direction was installed as the UP vector. That is the one
    --     role that did get aimed, i.e. the beam hull, and it was aimed
    --     downwards. Passing the aim as fvec alone is correct: the engine then
    --     generates uvec/rvec itself (vm_vector_2_matrix_gen_vectors).
    --
    local orientation=station.Orientation
    local aimX, aimZ = self:SentryAimVector(kind, pos)
    if aimX then
        orientation=ba.createOrientationFromVectors(vec(aimX,0,aimZ))
    elseif option.role=="beam" then
        -- No resolvable hostile at all. A beam still has to point somewhere
        -- fixed, and the only deterministic choice left is outward from the
        -- base along its own radius.
        local dx,dz=pos.x-station.Position.x,pos.z-station.Position.z
        local length=math.sqrt(dx*dx+dz*dz)
        if length<1 then
            orientation=ba.createOrientationFromVectors(vec(0,0,1))
        else
            orientation=ba.createOrientationFromVectors(vec(dx/length,0,dz/length))
        end
    end
    local teams = { BLUE = self.Config.FriendlyTeam, RED = self.Config.HostileTeam, GOLD = self.Config.ThirdTeam }
    local state = self:GetStationState(kind); state.sentrySerial = state.sentrySerial + 1
    local ship = mn.createShip("RTS Sentry " .. kind .. " " .. state.sentrySerial, tb.ShipClasses[option.class],
        orientation, pos, mn.Teams[teams[kind]], true)
    self:InvalidateShipList()
    if not shipValid(ship) then return nil end
    ship:setFlag(true, "immobile")
    ship.HitpointsMax=option.hull; ship.HitpointsLeft=option.hull
    -- Resolve the weapon before touching any bank. Writing an INVALID handle
    -- into WeaponClass is silently discarded by the engine (ship_bank.cpp
    -- guards on `weaponclass > -1`), so an unresolved class leaves the stock
    -- retail loadout in place and nothing anywhere reports a failure.
    --
    -- An unknown name does NOT come back as nil: tables.cpp falls through to
    -- atoi() and returns an invalid handle, which is truthy in Lua. So
    -- `weaponClass == nil` is false here, the guard below could never fire,
    -- and `weaponClass ~= nil` let the install run and write a handle the
    -- engine threw away. Both tests must be isValid().
    local weaponClasses=tb and tb.WeaponClasses
    local weaponClass=option.weapon and weaponClasses and weaponClasses[option.weapon] or nil
    local resolved=weaponClass~=nil and weaponClass:isValid()
    -- NOTE: do not try to count these classes with pairs()/ipairs(). tb.WeaponClasses
    -- is an ADE indexer userdata, and iterating it aborts the engine outright -
    -- the same trap as ipairs(mn.Ships). Counting it killed a match in 17s.
    if option.weapon and not resolved then
        self:Log("Sentry weapon class does not resolve, leaving stock loadout: "..tostring(option.weapon))
        self:EmitAIEvent("SENTRY_WEAPON",{action="RESOLVE_FAILED",faction=kind,class=option.class,weapon=option.weapon,installed="NONE"})
    elseif resolved then
        self:EmitAIEvent("SENTRY_WEAPON",{action="RESOLVED",faction=kind,class=option.class,weapon=option.weapon,installed=tostring(weaponClass.Name)})
    end
    if resolved then
        for i=1,#ship do
            local turret=ship[i]
            if turret:isTurret() then
                for b=1,#turret.PrimaryBanks do turret.PrimaryBanks[b].WeaponClass=weaponClass end
            end
        end
    end
    ship:warpIn(); self:EnableFullArsenal(ship)
    self.SentryNames=self.SentryNames or {}
    self.SentryHulls=self.SentryHulls or {}
    self.StaticDefenseSignatures=self.StaticDefenseSignatures or {}; self.StaticDefenseSignatures[ship:getSignature()]=true
    self.SentryNames[ship:getSignature()]=ship.Name
    self.SentryHulls[ship:getSignature()]=ship
    self.SentryCosts[ship:getSignature()]=free and 0 or option.cost
    if self:GetUpgradeLevel(kind,"defenses")>=2 then self:ApplySentryHullBonus(ship) end
    if self:GetUpgradeLevel(kind,"defenses")>=3 then self:ApplyDefenseFireRate(ship) end
    if kind=="BLUE" then self:SetStatus(option.class.." deployed",2) end
    return ship
end

function RTS:PlaceSentry(kind, option, pos, free)
    local reason = self:CheckSentrySpot(kind, pos, nil, option)
    if reason == nil and self:GetSentrySlotCount(kind) >= self:GetSentryCap(kind) then reason = "Sentry cap reached" end
    if reason == nil and not free and self:GetCurrentEscalationTier() < option.tier then reason = "Needs escalation tier " .. option.tier end
    if reason == nil and not free and not self:SpendFactionCP(kind, option.cost) then reason = "Insufficient command points" end
    if reason then if kind == "BLUE" then self:SetStatus(reason, 2) end; return nil end
    if free then
        local ship=self:CreateSentry(kind,option,pos,true)
        if not ship then return nil end
        return ship
    end
    self.PendingSentrySerial=(self.PendingSentrySerial or 0)+1
    local job={id=self.PendingSentrySerial,kind=kind,option=option,pos=copyVec(pos),startedAt=mn.getMissionTime(),
        finishAt=mn.getMissionTime()+cfg(self).Sentries.BuildSeconds,cost=option.cost}
    self.PendingSentries[#self.PendingSentries+1]=job
    self:EmitAIEvent("SENTRY_BUILD",{action="BUILD_STARTED",faction=kind,class=option.class,cost=option.cost,
        position={x=pos.x,y=pos.y,z=pos.z},startedAt=job.startedAt,finishAt=job.finishAt},job.startedAt)
    if kind=="BLUE" then self:SetStatus("Building "..option.class.." ("..cfg(self).Sentries.BuildSeconds.."s)",2) end
    return job
end

function RTS:UpdateSentryConstruction(now)
    for i=#(self.PendingSentries or {}),1,-1 do
        local job=self.PendingSentries[i]
        if not shipAlive(self:GetFactionCommandShip(job.kind)) then
            table.remove(self.PendingSentries,i); self:RefundFactionCP(job.kind,job.cost)
        elseif now>=job.finishAt then
            local reason=self:CheckSentrySpot(job.kind,job.pos,job.id,job.option)
            if not reason then
                for _,enemy in ipairs(self:GetShipList()) do
                    if shipAlive(enemy) and self:AreEnemies(self:GetFactionCommandShip(job.kind),enemy)
                        and not self:IsCommandStation(enemy)
                        and enemy.Position:getDistance(job.pos)<=cfg(self).Sentries.DeploySafeRadius then
                        reason="Enemy contact at build site"; break
                    end
                end
            end
            table.remove(self.PendingSentries,i)
            local ship=not reason and self:CreateSentry(job.kind,job.option,job.pos,false) or nil
            if not ship then
                self:RefundFactionCP(job.kind,job.cost)
                if job.kind=="BLUE" then self:SetStatus(reason or "Sentry construction failed; CP refunded",2) end
                self:EmitAIEvent("SENTRY_BUILD",{action="BUILD_CANCELLED",faction=job.kind,class=job.option.class,
                    cost=job.cost,reason=reason or "SPAWN_FAILED"},now)
            else
                self:EmitAIEvent("SENTRY_BUILD",{action="BUILD_COMPLETED",faction=job.kind,class=job.option.class,
                    cost=job.cost,signature=ship:getSignature(),buildSeconds=now-job.startedAt},now)
            end
        end
    end
end

-- Beam sentries use the entry that declares role="beam" for their own faction.
-- Indexing Classes.BLUE[4] instead meant any Mjolnir field added to RED or GOLD
-- would silently inherit BLUE's engagement range. Read the config directly:
-- this is a configured range, and GetSentryOptions() filters entries out when
-- the ship class is absent from the active tables, which would otherwise turn
-- a range lookup into "no opinion".
function RTS:GetBeamSentryRangeOption(kind, className)
    for _, option in ipairs((cfg(self).Sentries.Classes or {})[kind] or {}) do
        if option.role == "beam" and option.class == className then return option end
    end
    return nil
end

-- How far a sentry's configured weapon class can actually shoot. The engine
-- fires a projectile turret out to MIN(lifetime * max_speed, weapon_range) and
-- a beam out to its own lock range (aiturret.cpp:2435-2444); both components
-- are readable off the weapon class (weaponclass.cpp:470 LifeMax, :572 Speed,
-- :487 Range). option.range is the mod's own engagement window and only the
-- beam role ever used it, so the tooltip used to quote it for every class and
-- promise a reach the gun did not have.
function RTS:GetSentryWeaponRange(option)
    local fallback = option.range or 0
    local weapon = option.weapon and tb and tb.WeaponClasses and tb.WeaponClasses[option.weapon] or nil
    -- An unresolved name is an INVALID HANDLE, not nil (tables.cpp), so the
    -- original `== nil` test never fired. LifeMax/Speed then read 0 off the
    -- dead handle, `reach <= 0` fell back to option.range, and the player was
    -- shown a 12,000 m engagement window for a gun that fires at ~1 km.
    if weapon == nil or not weapon:isValid() then return fallback end
    local flight = (weapon.LifeMax or 0) * (weapon.Speed or 0)
    local reach = weapon.Range or 0
    if flight > 0 and flight < reach then reach = flight end
    if reach <= 0 then return fallback end
    return reach
end

-- One honest sentence per sentry role. A beam is gated to its configured
-- window by UpdateMjolnirRange, so the config value IS its reach; every other
-- role fires at the weapon's own native reach.
function RTS:DescribeSentryRange(option)
    if option.role == "beam" then
        return "reach " .. math.floor(option.range or 0) .. " m (locked) | aims away from base"
    end
    return "reach " .. math.floor(self:GetSentryWeaponRange(option)) .. " m"
end

function RTS:UpdateMjolnirRange(now)
    if now<(self.NextMjolnirRangeUpdate or 0) then return end
    self.NextMjolnirRangeUpdate=now+(cfg(self).Sentries.RangeScanSeconds or 1)
    -- Collect the beam sentries, then answer every one of them from a SINGLE
    -- ship-list walk. This called EachShip once per beam, so the scan was
    -- O(beams x ships) in closure invocations as well as distance checks; a
    -- full Mjolnir ring on a crowded board is thousands of iterations per
    -- interval. The per-sentry lock state below is unchanged.
    --
    -- This throttle is on MISSION time, so time compression multiplies how often
    -- it runs per wall second: at 16x an interval of 1 mission second is 16
    -- scans per real second. The cadence has to stay on mission time (the scan
    -- is what decides turret locks, and a wall clock would make lock behaviour
    -- depend on frame rate), so the cost per scan is what gets bounded instead:
    --  * an explicit work budget, so one scan cannot walk an unbounded ship
    --    list no matter how the board grows, and
    --  * an early exit as soon as every beam has found its target, which is the
    --    common case the moment an attacker is anywhere near the ring.
    -- Both bounds are correctness-neutral: a beam that does not resolve inside
    -- its budget simply keeps whatever lock state it had, which is what the
    -- pre-budget code did for any enemy the scan never reached.
    local beams = {}
    for signature in pairs(self.StaticDefenseSignatures or {}) do
        local sentry=self:FindShipBySignature(signature)
        if shipAlive(sentry) and sentry.Class.Name==self.Config.SentryShipClass then
            local owner=self:GetFactionKey(sentry)
            local option=owner and self:GetBeamSentryRangeOption(owner,sentry.Class.Name) or nil
            beams[#beams+1]={signature=signature,ship=sentry,range=(option and option.range) or 4000,inRange=false}
        else self.MjolnirRangeLocks[signature]=nil end
    end
    if #beams==0 then return end
    local unresolved=#beams
    local scanBudget=(cfg(self).Sentries.RangeScanMaxShips or 512)
    local visited=0
    -- Per-beam constants are read once here instead of per (beam, enemy) pair.
    -- Reach is NOT hoisted: it depends on the enemy's radius, so it stays in
    -- the inner loop, but it is squared there rather than passed through sqrt.
    for i=1,#beams do
        local beam=beams[i]
        beam.x=beam.ship.Position.x; beam.z=beam.ship.Position.z
    end
    self:EachShip(function(enemy)
        if unresolved==0 or visited>=scanBudget then return end
        visited=visited+1
        if shipAlive(enemy) then
            local enemyRadius=enemy.Radius or 0
            local ex,ez=enemy.Position.x,enemy.Position.z
            for i=1,#beams do
                local beam=beams[i]
                -- Squared XZ distance against a pre-squared reach: no sqrt, no
                -- l_Vector method call, no per-pair table. The beams are base
                -- turrets on the station's plane, so this is the same distance
                -- the previous getDistance() call measured for every hull that
                -- mattered, at a fraction of the cost.
                if not beam.inRange then
                    local reach=enemyRadius+beam.range
                    local dx=ex-beam.x; local dz=ez-beam.z
                    if dx*dx+dz*dz<=reach*reach and self:AreEnemies(beam.ship,enemy) then
                        beam.inRange=true; unresolved=unresolved-1
                    end
                end
            end
        end
    end)
    for i=1,#beams do
        local beam=beams[i]; local sentry=beam.ship
        local locks=self.MjolnirRangeLocks[beam.signature] or {}; self.MjolnirRangeLocks[beam.signature]=locks
        for t=1,#sentry do
            local turret=sentry[t]
            if turret:isTurret() then
                if beam.inRange and locks[t] then turret.TurretLocked=false; locks[t]=nil
                elseif not beam.inRange then
                    if locks[t]==nil and turret.TurretLocked~=true then locks[t]=true end
                    turret.TurretLocked=true
                end
            end
        end
    end
end

function RTS:SellSelectedSentries()
    local sold, refund = 0, 0
    -- self.Selected is an ARRAY of signature VALUES (every producer appends with
    -- Selected[#Selected+1]=sig), so ipairs is the correct walk here.
    -- Keep every non-sentry entry: selling a sentry must not wipe the player's
    -- fleet selection, which it used to do via a wholesale self.Selected={}.
    local keep = {}
    for _, id in ipairs(self.Selected or {}) do
        local ship = self:FindShipBySignature(id)
        if shipAlive(ship) and self:IsStaticDefense(ship) and self:GetFactionKey(ship) == "BLUE" then
            local value = math.floor((self.SentryCosts[id] or 0) * (cfg(self).Sentries.SellRefund or 0.5))
            -- One writer for all five tables. This line used to clear three of
            -- them, so a SOLD sentry left DefenseRateBoosted[id] and
            -- MjolnirRangeLocks[id] behind: the freed signature then handed the
            -- next hull a permanent "already boosted" verdict.
            self:ForgetSentryRecord(id)
            ship:vanish()
            sold = sold + 1; refund = refund + value
        elseif shipAlive(ship) then
            keep[#keep+1] = id
        end
    end
    if sold == 0 then self:SetStatus("Select your sentries to sell them", 2) return end
    self:RefundFactionCP("BLUE", refund)
    self:InvalidateShipList(); self.Selected = keep
    self:SetStatus("Sold " .. sold .. " sentr" .. (sold == 1 and "y" or "ies") .. " for " .. refund .. " CP", 2)
end

-- ---------------------------------------------------------------------------
-- Faction abilities (Command L3)
-- ---------------------------------------------------------------------------
function RTS:IsAbilityReady(kind)
    return shipAlive(self:GetFactionCommandShip(kind)) and self:GetUpgradeLevel(kind, "command") >= 3
        and mn.getMissionTime() >= self:GetStationState(kind).abilityReadyAt
end

function RTS:StartAbilityCooldown(kind)
    local state = self:GetStationState(kind)
    state.abilityReadyAt = mn.getMissionTime() + cfg(self).Ability.Cooldown
    state.abilityRefusal = nil
end

-- A refusal changed nothing, so it must NOT consume the cooldown: a jump with
-- no free fleet slot has to be able to fire the moment one opens, and a surge
-- with no strike craft alongside has to fire when they come home. That is the
-- right behaviour, but it left the AI able to sit on a permanently unusable
-- ability with nothing to show for it - RED could hold a ready SWARM SURGE for
-- a whole match with no ship ever in radius, and neither the log nor the
-- telemetry said a word. Record each distinct cause once so "the ability never
-- fires" is diagnosable instead of silent.
function RTS:NoteAbilityRefusal(kind, reason)
    local state = self:GetStationState(kind)
    if state.abilityRefusal == reason then return end
    state.abilityRefusal = reason
    state.abilityRefusedAt = mn.getMissionTime()
    self:EmitAIEvent('ABILITY_REFUSED',{faction=kind,ability=cfg(self).Ability[kind].name,reason=reason,
        commandLevel=self:GetUpgradeLevel(kind,'command'),readyAt=state.abilityReadyAt},state.abilityRefusedAt)
    self:Log(cfg(self).Ability[kind].name.." unavailable for "..kind..": "..reason)
end

-- Hostile and friendly hulls the blast would touch, so the strike can refuse a
-- target that would hit nothing and can name what it is about to kill.
function RTS:SurveyBlastArea(kind, pos, radius)
    local station = self:GetFactionCommandShip(kind)
    local enemies, friends = 0, 0
    if not shipAlive(station) or not self:IsFiniteVector(pos) then return enemies, friends end
    local reach = (radius or 0) * (radius or 0)
    self:EachShip(function(ship)
        if shipAlive(ship) then
            local p = ship.Position
            if p then
                local dx, dz = p.x - pos.x, p.z - pos.z
                local hull = ship.Radius or 0
                if dx*dx + dz*dz <= reach + hull*hull then
                    if self:AreEnemies(station, ship) then enemies = enemies + 1 else friends = friends + 1 end
                end
            end
        end
    end)
    return enemies, friends
end

-- Terran: a delayed strike on a map position.
function RTS:QueueOrbitalStrike(kind, pos)
    if kind~="BLUE" or not self:IsAbilityReady(kind) or not self:IsFiniteVector(pos) then return false end
    local a = cfg(self).Ability[kind]
    if self:GetFactionCommandShip(kind).Position:getDistance(pos)>a.range then
        if kind=="BLUE" then self:SetStatus("Strike target must be within "..(a.range/1000).." km of the station",2) end
        return false
    end
    -- The strike used to cost nothing and validate nothing, so a click on empty
    -- space burned the full 150 s cooldown for no damage, and the same click
    -- over the player's own sentry ring killed them (the tooltip warns about
    -- friendly fire, but a 150 s commitment deserves a check first). Refuse a
    -- blast with nothing hostile inside it; friendly fire stays legal because
    -- that is the documented design, but the player is told the count before
    -- the command points go.
    local enemies, friends = self:SurveyBlastArea(kind, pos, a.radius)
    if enemies==0 then
        if kind=="BLUE" then self:SetStatus("No enemy inside the blast area - strike not fired",3) end
        self:NoteAbilityRefusal(kind, "no target in blast area")
        return false
    end
    local cost = a.cost or 0
    if cost>0 and not self:SpendFactionCP(kind, cost) then
        if kind=="BLUE" then self:SetStatus("Insufficient command points for the strike ("..cost.." needed)",3) end
        self:NoteAbilityRefusal(kind, "insufficient command points")
        return false
    end
    -- `cost` is carried on the record rather than re-read from config at resolve
    -- time: a balance edit between queue and impact must not change what a
    -- cancelled strike refunds, and a config entry that lost its `cost` must
    -- not refund an arbitrary amount.
    self.PendingStrikes[#self.PendingStrikes + 1] = { kind = kind, pos = copyVec(pos), at = mn.getMissionTime() + (a.delay or 5), radius = a.radius or 0, cost = cost }
    self:StartAbilityCooldown(kind)
    if kind == "BLUE" then
        local message = "ORBITAL STRIKE inbound - " .. (a.delay or 5) .. "s"
        if friends>0 then
            message = message .. " - " .. friends .. " friendly unit" .. (friends==1 and "" or "s") .. " in the blast"
        end
        self:SetStatus(message, 3)
    end
    return true
end

function RTS:ResolveOrbitalStrike(strike)
    local a = cfg(self).Ability[strike.kind]
    -- The pending strike used to fire with no check at all, so destroying the
    -- station during the 5 s delay silently deleted a queued 750 CP strike:
    -- the entry was removed from PendingStrikes, the SEXP was skipped or run
    -- against a dead faction, and the CP was never returned. Refuse and refund
    -- once, the same rule UpdateSentryConstruction already applies to a build
    -- that loses its station. Guarded by strike.refunded so a second resolve of
    -- the same record cannot pay twice.
    if not shipAlive(self:GetFactionCommandShip(strike.kind)) then
        if not strike.refunded then
            strike.refunded = true
            local refund = strike.cost or 0
            self:RefundFactionCP(strike.kind, refund)
            self:EmitAIEvent('SENTRY_BUILD',{action="STRIKE_CANCELLED",faction=strike.kind,
                cost=refund,reason="BASE_DESTROYED",queuedAt=strike.at},mn.getMissionTime())
        end
        return false
    end
    -- Native spherical blast: shields, armor, invulnerability, falloff and
    -- friendly fire follow FSO combat rules; no role-based instant kills.
    mn.runSEXP(string.format('(explosion-effect %d %d %d %d 0 500 %d %d 0 0 -1)',
        strike.pos.x,strike.pos.y,strike.pos.z,a.damage or 0,a.innerRadius or 0,strike.radius or 0))
    return true
end

-- Vasudan: a free corvette jumps in beside the station.
function RTS:UseReinforcementJump(kind)
    if not self:IsAbilityReady(kind) then return false end
    if self:CountCommittedCombatants(kind) >= self:GetFleetCap(kind) then
        -- No cooldown: nothing was created, and a slot may open at any time.
        self:NoteAbilityRefusal(kind, "fleet cap reached")
        return false
    end
    local station = self:GetFactionCommandShip(kind)
    if not shipValid(station) then
        self:NoteAbilityRefusal(kind, "station handle invalid")
        return false
    end
    local a = cfg(self).Ability[kind]
    local ship = self:SpawnFactionUnit(a.class, station, station.Team, "RTS Gold Jump", 0, 1, 1, 1, 1)
    -- mn.createShip returns an INVALID HANDLE rather than raising when
    -- ship_create refuses, so this is a real outcome and not an error path.
    if not shipValid(ship) then
        self:NoteAbilityRefusal(kind, "reinforcement spawn refused")
        return false
    end
    self:AssignAIStrategicOrder(ship, kind, true)
    self:StartAbilityCooldown(kind)
    -- The refusal path (NoteAbilityRefusal) had telemetry and the success path
    -- had none, so "the ability did nothing" and "the ability fired" were the
    -- same empty trace. A jump is a real hull appearing on the board at a
    -- known cost of zero, and it is the only ability that creates a unit rather
    -- than altering one, so its arrival has to be countable: the economy
    -- reconciliation otherwise sees a hull appear with no production event.
    self:EmitAIEvent("PRODUCTION",{action="ABILITY_REINFORCEMENT",producer="COMMAND_ABILITY",faction=kind,
        class=a.class,shipSignature=ship:getSignature(),count=1,cost=0,refundedCP=0,
        spawnedAt=mn.getMissionTime(),readyAt=self:GetStationState(kind).abilityReadyAt,
        economyTreatment="free-reinforcement"},mn.getMissionTime())
    return true
end

-- Shivan: nearby strike craft get a temporary speed boost.
function RTS:UseSwarmSurge(kind)
    if not self:IsAbilityReady(kind) then return false end
    local station = self:GetFactionCommandShip(kind)
    if not shipValid(station) then
        self:NoteAbilityRefusal(kind, "station handle invalid")
        return false
    end
    local a = cfg(self).Ability[kind]; local untilTime = mn.getMissionTime() + a.seconds; local boosted = 0
    for _, ship in ipairs(self:GetShipList()) do
        local role = self:GetShipRole(ship)
        if shipAlive(ship) and self:GetFactionKey(ship) == kind and (role == "fighter" or role == "bomber")
            and flatDistance(ship.Position, station.Position) <= a.radius and self.SurgedShips[ship:getSignature()] == nil then
            local physics = ship.Physics
            self.SurgedShips[ship:getSignature()] = { ship=ship, untilTime = untilTime, velocity = copyVec(physics.VelocityMax), afterburner = copyVec(physics.AfterburnerVelocityMax), multiplier=a.speedMultiplier }
            physics.VelocityMax = physics.VelocityMax * a.speedMultiplier
            physics.AfterburnerVelocityMax = physics.AfterburnerVelocityMax * a.speedMultiplier
            local surge=self.SurgedShips[ship:getSignature()]
            surge.appliedVelocity=copyVec(physics.VelocityMax); surge.appliedAfterburner=copyVec(physics.AfterburnerVelocityMax)
            boosted = boosted + 1
        end
    end
    if boosted == 0 then
        -- No cooldown: no ship was touched, and the strike craft this surge is
        -- for may be on the way back.
        self:NoteAbilityRefusal(kind, "no strike craft within surge radius")
        return false
    end
    self:StartAbilityCooldown(kind)
    return true
end

function RTS:UseFactionAbility(kind)
    if kind == "GOLD" then return self:UseReinforcementJump(kind) end
    if kind == "RED" then return self:UseSwarmSurge(kind) end
    return false -- Blue's strike needs a target; see ArmCommand("strike")
end

-- ---------------------------------------------------------------------------
-- Per-frame update: upgrade completion, armor repair, strikes, surge expiry, AI
-- ---------------------------------------------------------------------------
function RTS:UpdateStations(now)
    if self.StationState == nil then return end
    for _, kind in ipairs(FACTIONS) do
        local state = self.StationState[kind]
        local station = self:GetFactionCommandShip(kind)
        if shipAlive(station) then
            -- Sample damage before an armor upgrade raises current hull.
            -- Native armor can reduce a hit below 0.5 HP. Every observed loss
            -- must reset the delay, or light fire allows continuous repair.
            if state.lastHull and station.HitpointsLeft < state.lastHull then
                local damage=state.lastHull-station.HitpointsLeft
                state.lastDamageAt = now
                state.scarHull=math.min(station.HitpointsMax,(state.scarHull or 0)
                    +damage*(1-cfg(self).RecoverableDamageFraction))
            end
            if state.upgrade and now >= state.upgrade.finishTime then
                local up = state.upgrade; state.upgrade = nil
                state.levels[up.track] = up.level
                self:ApplyUpgrade(kind, up.track, up.level)
                if kind == "BLUE" then self:ShowAnnouncement(cfg(self).Tracks[up.track].label .. " L" .. up.level .. " COMPLETE", 3, nil) end
            end
            local hull = station.HitpointsLeft
            local repairCeiling=math.max(0,station.HitpointsMax-(state.scarHull or 0))
            if self:GetUpgradeLevel(kind, "armor") >= 2 and now - state.lastDamageAt >= cfg(self).ArmorRepairDelay and hull < repairCeiling then
                local dt = math.max(0, now - math.max(state.lastRepairTime or now, state.lastDamageAt + cfg(self).ArmorRepairDelay))
                station.HitpointsLeft = math.min(repairCeiling, hull + station.HitpointsMax * cfg(self).ArmorRepairPerSecond * dt)
                state.repairedTotal=(state.repairedTotal or 0)+math.max(0,station.HitpointsLeft-hull)
            end
            state.lastRepairTime = now; state.lastHull = station.HitpointsLeft
            if self.CombatTelemetryEnabled and now>=(state.nextRepairReport or 0) then
                local total=state.repairedTotal or 0
                self:EmitAIEvent('STATION_REPAIR',{faction=kind,hull=station.HitpointsLeft,maxHull=station.HitpointsMax,
                    repaired=total-(state.reportedRepair or 0),totalRepaired=total,scarHull=state.scarHull or 0,repairCeiling=repairCeiling},now)
                state.reportedRepair=total; state.nextRepairReport=now+30
            end
            if kind ~= "BLUE" or self.AutoPlayerMode then self:UpdateStationAI(kind, state, station, now) end
        else
            state.upgrade = nil
        end
    end
    self:UpdateSentryConstruction(now)
    self:UpdateMjolnirRange(now)
    -- `#nil` raises "attempt to get length of a nil value". UpdateStations returns
    -- early only when StationState is nil, which is not the same condition as
    -- PendingStrikes having been built, and this loop runs every frame.
    for i = #(self.PendingStrikes or {}), 1, -1 do
        if now >= self.PendingStrikes[i].at then self:ResolveOrbitalStrike(self.PendingStrikes[i]); table.remove(self.PendingStrikes, i) end
    end
    for sig, surge in pairs(self.SurgedShips) do
        -- Newly created ships enter signature lookup on the next engine frame.
        -- Keep the validated handle captured by the ability until expiration.
        local ship=surge.ship
        if shipAlive(ship) then
            local physics=ship.Physics
            -- ETS rewrites forward speed. Adopt a fresh engine value before
            -- multiplying; never compound our own value on repeated frames.
            surge.velocity=refreshSurgeBase(surge.velocity,physics.VelocityMax,surge.appliedVelocity)
            surge.afterburner=refreshSurgeBase(surge.afterburner,physics.AfterburnerVelocityMax,surge.appliedAfterburner)
            local mult=now<surge.untilTime and surge.multiplier or 1
            physics.VelocityMax=surge.velocity*mult; physics.AfterburnerVelocityMax=surge.afterburner*mult
            surge.appliedVelocity=copyVec(physics.VelocityMax); surge.appliedAfterburner=copyVec(physics.AfterburnerVelocityMax)
        end
        if not shipAlive(ship) or now>=surge.untilTime then self.SurgedShips[sig]=nil end
    end
end

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
        if deferInvestment then return false end
        local offer, reason = self:GetUpgradeOffer(kind, track, now)
        if offer and reason == nil and affordable(offer.cost) then return self:BuyUpgrade(kind, track) end
        return false
    end

    if self:IsAbilityReady(kind) then
        if kind == "BLUE" then
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
        if shipAlive(ship) and self:AreEnemies(station,ship) and not self:IsCommandStation(ship)
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

-- Highest-value enemy ship near our station, for the AI's strike.
function RTS:FindStrikeTarget(kind, station)
    local ability = cfg(self).Ability.BLUE
    -- One pass to collect the escort positions, then a flat scan. This was a
    -- nested O(n*m) walk: the inner loop only broke when a friendly was FOUND,
    -- so every "safe" candidate rescanned the whole ship list, and each
    -- iteration called GetFactionKey twice (each of which does teamName, a
    -- tostring and a string.lower). At a full board that is ~50,000 iterations
    -- and ~300,000 string allocations inside a single frame, and it runs twice
    -- per wall second under time compression.
    local escorts = {}
    for _, friendly in ipairs(self:GetShipList()) do
        if shipAlive(friendly) and self:GetFactionKey(friendly) == kind then
            local p = friendly.Position
            escorts[#escorts+1] = {x=p.x, y=p.y, z=p.z}
        end
    end
    local best, bestHull = nil, 0
    local escortsLocal = escorts; local guardRadius = ability.radius
    for _, ship in ipairs(self:GetShipList()) do
        local key = self:GetFactionKey(ship)
        if shipAlive(ship) and key ~= nil and key ~= kind and not self:IsCommandStation(ship)
            and ship.Position:getDistance(station.Position) <= ability.range and ship.HitpointsMax > bestHull then
            local sp = ship.Position; local sx,sy,sz = sp.x,sp.y,sp.z
            local safe = true
            for i=1,#escortsLocal do
                local e = escortsLocal[i]
                local dx=sx-e.x; local dy=sy-e.y; local dz=sz-e.z
                if dx*dx+dy*dy+dz*dz < guardRadius*guardRadius then safe=false; break end
            end
            if safe then best, bestHull = ship, ship.HitpointsMax end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- STATION panel (tab of the production panel)
-- ---------------------------------------------------------------------------
-- Deterministic hit-test order, topmost-first. Both the click handler and the
-- tooltip walked the rect table with pairs(), whose order is undefined in Lua:
-- they returned on the first rect that contained the point, so if any two rects
-- ever overlapped, which one won was arbitrary - and the tooltip could describe
-- a different button than the one the click fired. Reverse draw order (ability
-- is drawn last, so it sits on top) and test that way.
local function orderedButtonKeys(rects)
    local keys = {}
    for key in pairs(rects or {}) do keys[#keys+1] = key end
    table.sort(keys, function(a, b)
        local function rank(k)
            if k == "ability" then return 5 end
            if k:match("^sentry_") then return 4 end
            if k == "sell" then return 3 end
            if k:match("^track_") then return 2 end
            if k == "station" then return 1 end
            return 0
        end
        return rank(a) > rank(b)
    end)
    return keys
end

function RTS:DrawStationPanel(x1, y1, x2, y2)
    local kind = "BLUE"; local now = mn.getMissionTime(); local state = self:GetStationState(kind)
    local station = self:GetFactionCommandShip(kind); local rects = {}
    self.StationButtonRects = rects
    if not shipAlive(station) then gr.setColor(255, 90, 90, 255); gr.drawString("Blue Station destroyed", x1 + 4, y1 + 4); return end
    rects.station = {x1=x1,y1=y1,x2=x2,y2=y1+20}

    local hullPct = math.floor(100 * station.HitpointsLeft / math.max(1, station.HitpointsMax))
    local ceilingPct=math.floor(100*(1-(state.scarHull or 0)/math.max(1,station.HitpointsMax)))
    gr.setColor(200, 225, 235, 255); gr.drawString("HULL " .. hullPct .. "%", x1 + 4, y1 + 2)
    if state.upgrade then
        local up = state.upgrade; local t = clamp((now - up.startTime) / math.max(1, up.finishTime - up.startTime), 0, 1)
        local bx1 = x1 + 90; local bx2 = x2 - 4
        gr.setColor(40, 60, 70, 255); gr.drawRectangle(bx1, y1 + 3, bx2, y1 + 15, true)
        gr.setColor(255, 220, 110, 255); gr.drawRectangle(bx1, y1 + 3, bx1 + (bx2 - bx1) * t, y1 + 15, true)
        gr.setColor(10, 20, 25, 255); gr.drawString(self.Config.Station.Tracks[up.track].label .. " L" .. up.level .. "  " .. math.ceil(up.finishTime - now) .. "s", bx1 + 6, y1 + 3)
    end

    gr.setColor(170,205,215,255); gr.drawString(self:GetFleetServiceSummary(kind)..' | BASE LIMIT '..ceilingPct..'%',x1+4,y1+22,x2-4,y1+40)
    local y = y1 + 44
    for _, track in ipairs(TRACKS) do
        local t = self.Config.Station.Tracks[track]; local level = self:GetUpgradeLevel(kind, track)
        local offer, reason = self:GetUpgradeOffer(kind, track, now)
        local pips = string.rep("#", level) .. string.rep("-", 3 - level)
        local label
        if offer == nil then label = "[" .. pips .. "] " .. t.label .. "  MAX"
        elseif reason == "TIER" then label = "[" .. pips .. "] " .. t.label .. "  L" .. offer.level .. " needs T" .. offer.tier
        else label = "[" .. pips .. "] " .. t.label .. "  L" .. offer.level .. "  " .. offer.cost .. " CP  " .. math.ceil(offer.seconds * (self:GetDurationProfile().buildTimeScale or 1)) .. "s" end
        local r = { x1 = x1, y1 = y, x2 = x2, y2 = y + 24 }; rects["track_" .. track] = r
        self:DrawButton(r, label, offer ~= nil and reason == nil, false)
        y = y + 26
    end

    local sentries = self:GetSentrySlotCount(kind); local placed=#self:GetFactionSentries(kind)
    local building=sentries-placed
    gr.setColor(200, 225, 235, 255)
    gr.drawString(string.format("SENTRIES %d/%d%s   RANGE %.1f km", placed, self:GetSentryCap(kind), building>0 and (" ("..building.." BUILDING)") or "", self:GetSentryRadius(kind) / 1000), x1 + 4, y + 2, x2-60, y+20)
    local sell = { x1 = x2 - 56, y1 = y - 2, x2 = x2, y2 = y + 18 }; rects.sell = sell
    self:DrawButton(sell, "SELL", true, false)
    y = y + 22
    local options = self:GetSentryOptions(kind)
    local w = math.floor((x2 - x1 - 4) / 2); local bx = x1
    local tier = self:GetCurrentEscalationTier(now)
    for i, option in ipairs(options) do
        local r = { x1 = bx, y1 = y, x2 = bx + w, y2 = y + 34 }; rects["sentry_" .. i] = r
        local short = option.class:gsub("^%S+%s", "")
        local armed = self.ArmedCommand == "sentry" and self.ArmedSentryIndex == i
            self:DrawButton(r, option.tier <= tier and (short .. " " .. option.cost .. " CP / "..cfg(self).Sentries.BuildSeconds.."s") or (short .. " T" .. option.tier),
            option.tier <= tier and self.CommandPoints >= option.cost and sentries < self:GetSentryCap(kind), armed)
        bx = bx + w + 4
        if i % 2 == 0 then bx=x1; y=y+38 end
    end
    if #options % 2 == 1 then y=y+38 end
    y = y + 4

    -- A missing Ability.BLUE entry used to raise here ("attempt to index local
    -- 'ability'") and again in HandleStationPanelClick and DrawStationTooltip.
    -- DrawStationPanel runs every HUD frame, so this took the whole frame down.
    -- Degrade to an unnamed, free, permanently-unready ability rather than
    -- aborting the render.
    local ability = self.Config.Station.Ability[kind] or { name = "ABILITY" }
    local r = { x1 = x1, y1 = y, x2 = x2, y2 = y + 26 }; rects.ability = r
    local abilityReady = self:IsAbilityReady(kind) and self.CommandPoints >= (ability.cost or 0)
    local abilityLabel
    if self:GetUpgradeLevel(kind, "command") < 3 then abilityLabel = ability.name .. ": COMMAND L3"
    elseif self:IsAbilityReady(kind) and not abilityReady then abilityLabel = ability.name .. ": " .. (ability.cost or 0) .. " CP"
    elseif abilityReady then abilityLabel = ability.name .. ": READY"
    else abilityLabel = ability.name .. ": " .. math.ceil(state.abilityReadyAt - now) .. "s" end
    self:DrawButton(r, abilityLabel, abilityReady, self.ArmedCommand == "strike")
end

-- Hover text for the STATION tab, drawn left of the panel.
function RTS:DrawStationTooltip(panel)
    local mx, my = io.getMouseX(), io.getMouseY(); local lines, title = nil, nil
    for _, key in ipairs(orderedButtonKeys(self.StationButtonRects)) do
        local r = self.StationButtonRects[key]
        if self:PointInside(r, mx, my) then
            local track = key:match("^track_(.+)$")
            if key == "station" then
                title = "BLUE STATION"; lines = { "Hover an upgrade to inspect its three levels.",
                    "One upgrade at a time; ship production continues.",
                    "SERVICE sends selected ships to the station's far side.",
                    "A green + on the map marks ships recovering.",
                    "Two service slots; capitals use both. Damage pauses work.",
                    "Repair: 0.4% hull/s to 90%; rearm: 4% payload/s.",
                    "Full hull repair costs 35% of ship CP; full ammo 12%.",
                    "Subsystems: 1%/s to 90%; full repair costs 15%.",
                    "Base repairs recover 60% of damage; scars lower BASE LIMIT." }
            elseif track then
                local t = self.Config.Station.Tracks[track]
                -- A missing track definition used to raise on t.label here.
                -- The hover tooltip is drawn every frame the mouse is over the
                -- panel, so this aborted the HUD frame rather than just
                -- skipping one line of help text.
                if t == nil then return end
                title = t.label; lines = {}
                for i = 1, 3 do lines[#lines + 1] = "L" .. i .. " (T" .. (t.tiers[i] or 0) .. ", " .. (t.costs[i] or 0) .. " CP): " .. (t.desc[i] or "") end
            elseif key:match("^sentry_") then
                local option = self:GetSentryOptions("BLUE")[tonumber(key:match("%d+"))]
                if option then
                    -- Report the hull the sentry will actually have.
                    -- CreateSentry sets option.hull and Defenses L2 then applies
                    -- HullBonus on top, so the bare config number understated
                    -- every sentry built after that upgrade.
                    local hull = option.hull
                    local bonus = self:GetUpgradeLevel("BLUE", "defenses") >= 2
                        and (cfg(self).Sentries.HullBonus or 1.5) or 1
                    if bonus ~= 1 then hull = math.floor(hull * bonus) end
                    title = option.class
                    lines = { "Tier " .. option.tier .. "  |  " .. option.cost .. " CP  |  Hull " .. hull .. "  |  build "..cfg(self).Sentries.BuildSeconds.."s",
                        string.upper(option.role).." | "..self:DescribeSentryRange(option),
                        "Click, then left-click inside the station radius.", "Assembly cancels and refunds if enemies reach the site.", "Hold Shift to place several." } end
            elseif key == "ability" then
                -- Read from Station.Ability.BLUE rather than restating the
                -- numbers: the hardcoded 12 km/1200/5 s/900 m had already
                -- drifted from the config, and omitted innerRadius entirely.
                --
                -- The inner radius is the DEADLIEST part of the blast, not a safe
                -- hollow. ship_explode_area_calc_damage applies FULL max_damage
                -- for dist < inner_rad and attenuates to zero at outer_rad
                -- (ship.cpp:9233-9236), which is the opposite of what this
                -- tooltip claimed. A player who trusted it and parked inside
                -- the ring took the full 1200.
                local ability = self.Config.Station.Ability.BLUE or { name = "ABILITY" }
                title = ability.name
                lines = { "Command L3 ability, " .. (ability.cost or 0) .. " CP, " .. (self.Config.Station.Ability.Cooldown or 0) .. "s cooldown.",
                    string.format("Within %.0f km: %d blast damage after %gs.",
                        (ability.range or 0)/1000, ability.damage or 0, ability.delay or 0),
                    string.format("Full %d damage inside %.0f m, tapering to nothing at %.0f m.",
                        ability.damage or 0, ability.innerRadius or 0, ability.radius or 0),
                    "Refused, cooldown untouched, if no enemy is inside the blast.",
                    "Shields and armor apply. FRIENDLY FIRE; keep allies clear." }
            elseif key == "sell" then
                title = "SELL SENTRIES"; lines = { "Removes selected sentries for " .. math.floor((self.Config.Station.Sentries.SellRefund or 0.5) * 100) .. "% of their cost." }
            end
        end
    end
    if lines == nil then return end
    local w = 470; local x2 = panel.x1 - 10; local x1 = x2 - w; local y1 = clamp(my - 20, 40, gr.getScreenHeight() - 140)
    local model = title == "BLUE STATION" and self:GetCarrier() or nil
    local y2 = y1 + 34 + #lines * 17 + (model and 140 or 0)
    y1=math.min(y1,gr.getScreenHeight()-(y2-y1)-10); y2=y1+34+#lines*17+(model and 140 or 0)
    gr.setColor(4, 10, 18, 235); gr.drawRectangle(x1, y1, x2, y2, true); gr.setColor(100, 190, 220, 255); gr.drawRectangle(x1, y1, x2, y2, false)
    gr.setColor(235, 245, 250, 255); self:DrawCenteredText(title, x1 + 10, x2 - 10, y1 + 8)
    gr.setColor(160, 200, 215, 255); for i, line in ipairs(lines) do self:DrawCenteredText(line, x1 + 10, x2 - 10, y1 + 28 + (i - 1) * 17) end
    if model then self:DrawRotatingModel(model.Class.Name,x1+165,y2-140,x1+305,y2) end
end

-- Returns true when the click hit the STATION tab.
function RTS:HandleStationPanelClick(x, y)
    for _, key in ipairs(orderedButtonKeys(self.StationButtonRects)) do
        local r = self.StationButtonRects[key]
        if self:PointInside(r, x, y) then
            local track = key:match("^track_(.+)$")
            if track then self:BuyUpgrade("BLUE", track)
            elseif key == "sell" then self:SellSelectedSentries()
        elseif key == "ability" then
            local strikeCost=(self.Config.Station.Ability.BLUE or {}).cost or 0
            -- Same rule as the sentry buttons: the drawn state is greyed out
            -- when the strike is unaffordable, so do not arm a target cursor the
            -- player cannot pay for either.
            if not self:IsAbilityReady("BLUE") then
                self:SetStatus("ORBITAL STRIKE recharging: " .. math.ceil(self:GetStationState("BLUE").abilityReadyAt - mn.getMissionTime()) .. "s", 2)
            elseif self.CommandPoints < strikeCost then
                self:SetStatus("Insufficient command points for the strike (" .. strikeCost .. " needed)", 2)
            else
                self.ArmedCommand = "strike"; self:SetStatus("ORBITAL STRIKE: left-click a target area (right-click cancels)", 3)
            end
            else
                local index = tonumber(key:match("^sentry_(%d+)$"))
                local option = index and self:GetSentryOptions("BLUE")[index]
                if option then
                    if option.tier > self:GetCurrentEscalationTier() then self:SetStatus("Needs escalation tier " .. option.tier, 2)
                    -- The button is already drawn greyed out for these two cases
                    -- (DrawStationPanel), but the click handler never repeated
                    -- the check, so a click armed a cursor for a placement the
                    -- player cannot pay for and every world click then reported
                    -- the same refusal. Arm only what can actually be placed.
                    elseif self.CommandPoints < option.cost then
                        self:SetStatus("Insufficient command points for " .. option.class .. " (" .. option.cost .. " needed)", 2)
                    elseif self:GetSentrySlotCount("BLUE") >= self:GetSentryCap("BLUE") then
                        self:SetStatus("Sentry cap reached", 2)
                    else
                        self.ArmedCommand = "sentry"; self.ArmedSentryIndex = index
                        self:SetStatus("PLACE " .. option.class .. ": left-click inside the station radius (Shift: keep placing)", 3)
                    end
                end
            end
            return true
        end
    end
    return false
end

-- Executes an armed sentry/strike click at a world position.
function RTS:ExecuteStationArmedCommand(pos)
    local station = self:GetCarrier()
    if not shipAlive(station) then self.ArmedCommand = nil; return end
    if not self:IsFiniteVector(pos) then return end
    pos = vec(pos.x, station.Position.y, pos.z)
    if self.ArmedCommand == "strike" then
        if self:QueueOrbitalStrike("BLUE", pos) then self.ArmedCommand = nil end
    elseif self.ArmedCommand == "sentry" then
        local option = self:GetSentryOptions("BLUE")[self.ArmedSentryIndex or 1]
        -- The command points the cursor was armed against can be spent on
        -- something else while it sits on the map. Disarm rather than
        -- re-issuing a placement that can never succeed, so the next click is a
        -- fresh decision instead of the same refusal.
        if option and self.CommandPoints < option.cost then
            self.ArmedCommand = nil
            self:SetStatus("Not enough command points for " .. option.class .. " - placement cancelled", 2)
            return
        end
        local placed = option and self:PlaceSentry("BLUE", option, pos, false)
        if placed and not self.ShiftDown then self.ArmedCommand = nil end
    end
end

-- 65 unit offsets for the overlay rings, and one scratch vector, both built on
-- first use. The ring used to build 65 l_Vector handles and recompute 65 sets
-- of trig for every ring on every frame - DrawStationMapOverlay runs per frame
-- and there is one ring for the armed sentry plus one per pending strike.
local RING_OFFSETS, RING_SCRATCH
local function ringPoint(pos, radius, index)
    local offsets = RING_OFFSETS
    if offsets == nil then
        offsets = {}
        for i = 0, 64 do
            local angle = i * math.pi / 32
            offsets[i] = { math.cos(angle), math.sin(angle) }
        end
        RING_OFFSETS = offsets
        RING_SCRATCH = vec(0, 0, 0)
    end
    local unit = offsets[index]
    -- l_Vector exposes its components as a writable indexer
    -- (vecmath.cpp:358-388), so one handle serves all 65 sample points.
    RING_SCRATCH.x = pos.x + unit[1] * radius
    RING_SCRATCH.y = pos.y
    RING_SCRATCH.z = pos.z + unit[2] * radius
    return RING_SCRATCH
end

-- Map overlay: station radius while placing, strike rings and pending strikes.
function RTS:DrawStationMapOverlay()
    local function ring(pos, radius, r, g, b)
        -- Project the circumference instead of a clamped center/radius. This
        -- respects map zoom, non-square maps and the map's drawing bounds.
        gr.setColor(r, g, b, 200)
        local px,py,inside
        for i=0,64 do
            local x,y,visible=self:WorldToTacticalMap(ringPoint(pos, radius, i))
            if inside and visible then gr.drawLine(px,py,x,y) end
            px,py,inside=x,y,visible
        end
    end
    local station = self:GetCarrier()
    if self.ArmedCommand == "sentry" and shipValid(station) then ring(station.Position, self:GetSentryRadius("BLUE"), 255, 175, 90) end
    for _,job in ipairs(self.PendingSentries or {}) do
        if job.kind=="BLUE" then
            local x,y,visible=self:WorldToTacticalMap(job.pos)
            if visible then gr.setColor(255,190,70,230); gr.drawCircle(8,x,y,false); self:DrawCenteredText("BUILD "..math.max(0,math.ceil(job.finishAt-mn.getMissionTime())),x-45,x+45,y+10) end
        end
    end
    for _, strike in ipairs(self.PendingStrikes or {}) do ring(strike.pos, strike.radius, 255, 70, 70) end
end

-- World overlay: pulsing warning over pending strikes.
function RTS:DrawStrikeWarnings()
    local now = mn.getMissionTime()
    for _, strike in ipairs(self.PendingStrikes or {}) do
        local sx, sy = strike.pos:getScreenCoords()
        if sx then
            local pulse = 18 + (now * 40) % 30
            gr.setColor(255, 70, 70, 220); gr.drawCircle(pulse, sx, sy, false); gr.drawCircle(8, sx, sy, false)
            self:DrawCenteredText("STRIKE " .. math.max(0, math.ceil(strike.at - now)), sx - 60, sx + 60, sy + pulse + 4)
        end
    end
end
