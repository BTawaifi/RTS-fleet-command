-- Faction command abilities: readiness, cooldowns, orbital strikes, reinforcement and speed boosts.
local _shared = require "fs2rts_station.common"
local U, RTS, shipAlive, copyVec, shipValid, objectValid, cfg, flatDistance = _shared.U, _shared.RTS, _shared.shipAlive, _shared.copyVec, _shared.shipValid, _shared.objectValid, _shared.cfg, _shared.flatDistance
local refreshSurgeBase = _shared.refreshSurgeBase

function RTS:IsAbilityReady(kind)
    if self.AftermathActive then return false end
    return shipAlive(self:GetFactionCommandShip(kind)) and self:GetUpgradeLevel(kind, "command") >= 3
        and mn.getMissionTime() >= self:GetStationState(kind).abilityReadyAt
end

function RTS:GetAbilityStatus(kind,now)
    if self:GetUpgradeLevel(kind,"command")<3 then return "COMMAND L3" end
    if self.AftermathActive then return "MATCH ENDED" end
    if not shipAlive(self:GetFactionCommandShip(kind)) then return "STATION LOST" end
    now=now or mn.getMissionTime()
    local remaining=math.max(0,(tonumber(self:GetStationState(kind).abilityReadyAt) or 0)-now)
    if remaining>0 then return math.ceil(remaining).."s" end
    local ability=self:GetFactionAbilityProfile(kind)
    local cost=ability.cost or 0
    if self:GetFactionCP(kind)<cost then return cost.." CP" end
    return "READY"
end

function RTS:StartAbilityCooldown(kind)
    local state = self:GetStationState(kind)
    state.abilityReadyAt = mn.getMissionTime() + (self:GetFactionAbilityProfile(kind).cooldown or cfg(self).Ability.Cooldown)
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
    local ability=self:GetFactionAbilityProfile(kind)
    self:EmitAIEvent('ABILITY_REFUSED',{faction=kind,ability=ability.name,reason=reason,
        commandLevel=self:GetUpgradeLevel(kind,'command'),readyAt=state.abilityReadyAt},state.abilityRefusedAt)
    self:Log(ability.name.." unavailable for "..kind..": "..reason)
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
    local a = self:GetFactionAbilityProfile(kind)
    if a.kind~="strike" or not self:IsAbilityReady(kind) or not self:IsFiniteVector(pos) then return false end
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
        local message = a.name.." inbound - " .. (a.delay or 5) .. "s"
        if friends>0 then
            message = message .. " - " .. friends .. " friendly unit" .. (friends==1 and "" or "s") .. " in the blast"
        end
        self:SetStatus(message, 3)
    end
    return true
end

function RTS:ResolveOrbitalStrike(strike)
    local a = self:GetFactionAbilityProfile(strike.kind)
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

-- Vasudan: rapid reinforcement, paid through the shared CP ledger.
function RTS:UseReinforcementJump(kind)
    if not self:IsAbilityReady(kind) then return false end
    local a = self:GetFactionAbilityProfile(kind)
    local count=a.count or 1
    if a.kind~="reinforcement" or a.available==false then return false end
    if self:CountCommittedCombatants(kind)+count > self:GetFleetCap(kind) then
        -- No cooldown: nothing was created, and a slot may open at any time.
        self:NoteAbilityRefusal(kind, "fleet cap reached")
        return false
    end
    local station = self:GetFactionCommandShip(kind)
    if not shipValid(station) then
        self:NoteAbilityRefusal(kind, "station handle invalid")
        return false
    end
    local cost=a.cost or 0
    if not self:SpendFactionCP(kind,cost) then
        self:NoteAbilityRefusal(kind,"insufficient command points")
        return false
    end
    local created={}
    for index=1,count do
        local ok,err=pcall(self.SpawnFactionUnit,self,a.class,station,station.Team,"RTS "..kind.." Reserve",index,index,count,1,1,nil,nil,created)
        if not ok then self:Log("REINFORCEMENT SPAWN FAILED: "..tostring(err)) end
    end
    local refund=math.floor(cost*(count-#created)/count)
    if refund>0 then self:RefundFactionCP(kind,refund) end
    if #created==0 then
        self:NoteAbilityRefusal(kind, "reinforcement spawn refused")
        return false
    end
    self:StartAbilityCooldown(kind)
    if #created>1 then self:RegisterLogicalWing(created,self:GetNextWingCallsign(kind)) end
    for _,ship in ipairs(created) do
        local orderOK,orderError=pcall(self.AssignAIStrategicOrder,self,ship,kind,true)
        if not orderOK then self:Log("REINFORCEMENT ORDER FAILED: "..tostring(orderError)) end
    end
    if kind=="BLUE" then self:NotifyNewUnits(created) end
    -- The refusal path (NoteAbilityRefusal) had telemetry and the success path
    -- had none, so "the ability did nothing" and "the ability fired" were the
    -- same empty trace. A jump is a real hull appearing on the board at its
    -- charged cost, and it is the only ability that creates a unit rather
    -- than altering one, so its arrival has to be countable: the economy
    -- reconciliation otherwise sees a hull appear with no production event.
    self:EmitAIEvent("PRODUCTION",{action="ABILITY_REINFORCEMENT",producer="COMMAND_ABILITY",faction=kind,
        class=a.class,shipSignature=created[1]:getSignature(),count=#created,cost=cost,refundedCP=refund,
        spawnedAt=mn.getMissionTime(),readyAt=self:GetStationState(kind).abilityReadyAt,
        economyTreatment=cost>0 and "paid-reinforcement" or "free-reinforcement"},mn.getMissionTime())
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
    local a = self:GetFactionAbilityProfile(kind)
    if a.kind~="surge" then return false end
    local untilTime = mn.getMissionTime() + a.seconds; local eligible={}
    for _, ship in ipairs(self:GetShipList()) do
        local role = self:GetShipRole(ship)
        if shipAlive(ship) and not self:IsCommandStation(ship) and self:GetFactionKey(ship) == kind
            and (a.roles or {fighter=true,bomber=true})[role]
            and flatDistance(ship.Position, station.Position) <= a.radius and self.SurgedShips[ship:getSignature()] == nil then
            eligible[#eligible+1]=ship
        end
    end
    if #eligible==0 then
        self:NoteAbilityRefusal(kind, "no eligible fleet within surge radius")
        return false
    end
    if not self:SpendFactionCP(kind,a.cost or 0) then
        self:NoteAbilityRefusal(kind,"insufficient command points")
        return false
    end
    self:StartAbilityCooldown(kind)
    for _,ship in ipairs(eligible) do
        local physics = ship.Physics
        self.SurgedShips[ship:getSignature()] = { ship=ship, untilTime = untilTime, velocity = copyVec(physics.VelocityMax), afterburner = copyVec(physics.AfterburnerVelocityMax), multiplier=a.speedMultiplier }
        physics.VelocityMax = physics.VelocityMax * a.speedMultiplier
        physics.AfterburnerVelocityMax = physics.AfterburnerVelocityMax * a.speedMultiplier
        local surge=self.SurgedShips[ship:getSignature()]
        surge.appliedVelocity=copyVec(physics.VelocityMax); surge.appliedAfterburner=copyVec(physics.AfterburnerVelocityMax)
    end
    self:EmitAIEvent("SENTRY_BUILD",{action="ABILITY_SURGE",faction=kind,count=#eligible,cost=a.cost or 0,ability=a.name,untilTime=untilTime},mn.getMissionTime())
    return true
end

function RTS:UseFactionAbility(kind)
    local ability=self:GetFactionAbilityProfile(kind)
    if ability.kind=="reinforcement" then return self:UseReinforcementJump(kind) end
    if ability.kind=="surge" then return self:UseSwarmSurge(kind) end
    return false -- Terran orbital strike needs a target; see ArmCommand("strike")
end

-- ---------------------------------------------------------------------------
-- Per-frame update: upgrade completion, armor repair, strikes, surge expiry, AI
-- ---------------------------------------------------------------------------
function RTS:UpdateStations(now)
    if self.StationState == nil then return end
    self:UpdateStationPointDefense(now)
    if not self.AftermathActive then
    for _, kind in ipairs(self.Config.FactionOrder or U.AI_FACTION_ORDER) do
        local state = self.StationState[kind]
        local station = self:GetFactionCommandShip(kind)
        if shipAlive(station) then
            state.lastTurretHits=state.lastTurretHits or {}
            -- Sample damage before an armor upgrade raises current hull.
            -- Native armor can reduce a hit below 0.5 HP. Every observed loss
            -- must reset the delay, or light fire allows continuous repair.
            if state.lastHull and station.HitpointsLeft < state.lastHull then
                local damage=state.lastHull-station.HitpointsLeft
                state.lastDamageAt = now
                state.scarHull=math.min(station.HitpointsMax,(state.scarHull or 0)
                    +damage*(1-cfg(self).RecoverableDamageFraction))
            end
            local turretDamage=false
            for i=1,#station do
                local turret=station[i]
                if objectValid(turret) and turret:isTurret() then
                    local hp=turret.HitpointsLeft or 0
                    local previous=state.lastTurretHits[i]
                    if previous~=nil and hp<previous then turretDamage=true end
                    state.lastTurretHits[i]=hp
                end
            end
            if turretDamage then state.lastDamageAt=now end
            if state.upgrade and now >= state.upgrade.finishTime then
                local up = state.upgrade; state.upgrade = nil
                state.levels[up.track] = up.level
                self:ApplyUpgrade(kind, up.track, up.level)
                if kind == "BLUE" then self:ShowAnnouncement(cfg(self).Tracks[up.track].label .. " L" .. up.level .. " COMPLETE", 3, nil) end
            end
            local hull = station.HitpointsLeft
            local repairCeiling=math.max(0,station.HitpointsMax-(state.scarHull or 0))
            local repairRate=cfg(self).ArmorRepairPerSecond
            if self:GetUpgradeLevel(kind,"armor")<2 then repairRate=repairRate*.5 end
            local dt=0
            if now-state.lastDamageAt>=cfg(self).ArmorRepairDelay then
                dt=math.max(0,now-math.max(state.lastRepairTime or now,state.lastDamageAt+cfg(self).ArmorRepairDelay))
            end
            if dt>0 and hull<repairCeiling then
                station.HitpointsLeft = math.min(repairCeiling, hull + station.HitpointsMax * repairRate * dt)
                state.repairedTotal=(state.repairedTotal or 0)+math.max(0,station.HitpointsLeft-hull)
            end
            local subsystemRate=cfg(self).FleetService.SubsystemPerSecond or .01
            if dt>0 then
                for i=1,#station do
                    local turret=station[i]
                    local max=objectValid(turret) and turret:isTurret() and (turret.HitpointsMax or 0) or 0
                    local hp=max>0 and (turret.HitpointsLeft or 0) or 0
                    if hp<max then turret.HitpointsLeft=math.min(max,hp+max*subsystemRate*dt) end
                    if max>0 then state.lastTurretHits[i]=turret.HitpointsLeft or 0 end
                end
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
    end
    self:UpdateSentryAim(now)
    self:UpdateMjolnirRange(now)
    -- `#nil` raises "attempt to get length of a nil value". UpdateStations returns
    -- early only when StationState is nil, which is not the same condition as
    -- PendingStrikes having been built, and this loop runs every frame.
    for i = #(self.PendingStrikes or {}), 1, -1 do
        if not self.AftermathActive and now >= self.PendingStrikes[i].at then self:ResolveOrbitalStrike(self.PendingStrikes[i]); table.remove(self.PendingStrikes, i) end
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
