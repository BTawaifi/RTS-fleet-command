-- Placeable sentries: options, signature bookkeeping, hull bonuses, spot finding.
local _shared = require "fs2rts_station.common"
local RTS, shipAlive, shipValid, vec, cfg, flatDistance = _shared.RTS, _shared.shipAlive, _shared.shipValid, _shared.vec, _shared.cfg, _shared.flatDistance

function RTS:GetSentryOptions(kind)
    local result = {}
    -- cfg(self).Sentries.Classes[kind] raised when Classes was absent. This is
    -- a per-frame path (the panel draws one button per option, and the AI reads
    -- it every think), and FSO only LOGS an exception thrown inside a script
    -- hook, so the whole HUD frame was silently aborted instead.
    for _, entry in ipairs(self:GetFactionSentryClassList(kind)) do
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
    for _, other in ipairs(self:GetFactionKeys()) do
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
