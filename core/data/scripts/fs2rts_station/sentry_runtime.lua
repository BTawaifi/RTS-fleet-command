-- Sentry runtime: aiming, point defence, Mjolnir range and selling.
local _shared = require "fs2rts_station.common"
local RTS, shipAlive, objectValid, cfg, canAutoEngage = _shared.RTS, _shared.shipAlive, _shared.objectValid, _shared.cfg, _shared.canAutoEngage

function RTS:UpdateSentryAim(now)
    if now<(self.NextSentryAimUpdate or 0) then return end
    self.NextSentryAimUpdate=now+1
    local ships=self:GetShipList()
    for _,kind in ipairs(self:GetFactionKeys()) do
        for _,sentry in ipairs(self:GetFactionSentries(kind)) do
            local nearest,range=nil,11000
            for _,other in ipairs(ships) do
                if shipAlive(other) and canAutoEngage(self,sentry,other) and other.Name~=self.Config.ObserverShip then
                    local distance=sentry.Position:getDistance(other.Position)
                    if distance<range then nearest,range=other,distance end
                end
            end
            if nearest and range>1 then
                -- Retail platforms have forward turret arcs. Slew the fixed
                -- installation toward nearby attackers instead of leaving its
                -- guns facing the bearing it had at construction forever.
                local goal=ba.createOrientationFromVectors((nearest.Position-sentry.Position)/range)
                sentry.Orientation=sentry.Orientation:rotationalInterpolate(goal,.5)
            end
        end
    end
end

function RTS:UpdateStationPointDefense(now)
    if now<(self.NextStationPointDefense or 0) then return end
    self.NextStationPointDefense=now+.5
    local contacts={}
    for _,ship in ipairs(self:GetShipList()) do
        if shipAlive(ship) and ship.Name~=self.Config.ObserverShip then
            local role=self:GetShipRole(ship)
            if role=='fighter' or role=='bomber' then contacts[#contacts+1]=ship end
        end
    end
    for _,kind in ipairs(self:GetFactionKeys()) do
        local station=self:GetFactionCommandShip(kind)
        if shipAlive(station) then
            for i=1,#station do
                local turret=station[i]; local range=0
                if objectValid(turret) and turret:isTurret() and not turret.TurretLocked and turret.HitpointsLeft>0 then
                    for b=1,#turret.PrimaryBanks do
                        local weapon=turret.PrimaryBanks[b].WeaponClass
                        if objectValid(weapon) and weapon.Name==cfg(self).Sentries.ScreenWeapon then range=self:GetWeaponFiringRange(weapon) end
                    end
                    if range>0 then
                        local target,distance,rank=nil,math.huge,math.huge
                        for _,ship in ipairs(contacts) do
                            local d=turret.WorldPosition:getDistance(ship.Position)
                            local priority=self:CanDamageBase(ship) and 0 or 1
                            if (priority<rank or priority==rank and d<distance) and d-(ship.Radius or 0)<=range and canAutoEngage(self,station,ship)
                                and turret:isPositionInFOV(ship.Position)==true then target,distance,rank=ship,d,priority end
                        end
                        -- These dedicated small-target banks must not share the
                        -- capital battery's distant base target. Native AI still
                        -- owns slewing, trigger, cooldown and hit resolution.
                        turret.Target=target
                    end
                end
            end
        end
    end
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
                    if dx*dx+dz*dz<=reach*reach and canAutoEngage(self,beam.ship,enemy) then
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
function RTS:GetFactionAbilityProfile(kind)
    local profile=self:GetFactionProfile(kind)
    local selected=profile and (profile.abilityKey and cfg(self).Ability[profile.abilityKey] or profile.ability)
    local species=self:GetFactionSpecies(kind)
    local key=species=="SHIVAN" and "RED" or species=="VASUDAN" and "GOLD" or "BLUE"
    local ability=selected or cfg(self).Ability[key] or {}
    if ability.kind==nil then
        local copy={}; for field,value in pairs(ability) do copy[field]=value end
        local legacyKey=profile and profile.abilityKey or key
        copy.kind=legacyKey=="GOLD" and "reinforcement" or legacyKey=="RED" and "surge" or "strike"
        ability=copy
    end
    if ability.kind=="reinforcement" and ability.tier then
        local result={}; for field,value in pairs(ability) do result[field]=value end
        local estimate=self:GetPurchaseEstimate(ability.class,ability.tier,ability.count or 1)
        result.cost=estimate and math.max(ability.cost or 0,estimate.cost) or (ability.cost or 0)
        result.available=estimate~=nil
        return result
    end
    return ability
end
