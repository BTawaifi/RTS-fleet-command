-- Placeable sentries: creation, placement, construction and role descriptions.
local _shared = require "fs2rts_station.common"
local RTS, shipAlive, shipValid, objectValid, vec, copyVec, cfg, canAutoEngage = _shared.RTS, _shared.shipAlive, _shared.shipValid, _shared.objectValid, _shared.vec, _shared.copyVec, _shared.cfg, _shared.canAutoEngage

-- Choose an initial horizontal facing at deployment, respecting turret arcs.
-- Prefer the nearest hostile mobile hull; otherwise face the hostile station.
function RTS:SentryAimVector(kind, pos)
    local station = self:GetFactionCommandShip(kind)
    local fromX = pos.x; local fromZ = pos.z
    if shipAlive(station) then
        local originX = station.Position.x; local originZ = station.Position.z
        local best = math.huge; local aimX, aimZ
        -- mn.Ships is an ADE indexer, not a Lua table: use numeric indexing.
        for i=1,#mn.Ships do
            local other = mn.Ships[i]
            if other and other:isValid() and not other:isDying() then
                local owner = self:GetFactionKey(other)
                if owner and owner ~= kind and not self:IsStaticDefense(other)
                    and canAutoEngage(self,station,other) then
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
        for _, other in ipairs(self:GetFactionKeys()) do
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
    local faction=self:GetFactionDefinition(kind)
    local state = self:GetStationState(kind); state.sentrySerial = state.sentrySerial + 1
    local ship = mn.createShip(self:GetSafeShipName("RTS Sentry " .. (self:GetFactionDefinition(kind).short or kind) .. " " .. state.sentrySerial), tb.ShipClasses[option.class],
        orientation, pos, mn.Teams[faction and faction.team or ""], true)
    self:InvalidateShipList()
    if not shipValid(ship) then return nil end
    ship:setFlag(true, "immobile")
    self:ApplyFactionVisual(ship,kind)
    local hullScale=option.hull/math.max(1,ship.HitpointsMax)
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
        local screen=cfg(self).Sentries.ScreenWeapon and weaponClasses[cfg(self).Sentries.ScreenWeapon]
        for i=1,#ship do
            local turret=ship[i]
            if turret:isTurret() then
                -- Raising hull HP does not scale retail subsystem HP. Otherwise
                -- a 600-HP platform retains 4-HP guns and loses them to one hit.
                turret.HitpointsMax=turret.HitpointsMax*hullScale
                turret.HitpointsLeft=turret.HitpointsMax
                for b=1,#turret.PrimaryBanks do
                    if b==1 and #turret.PrimaryBanks>1 and objectValid(screen) then
                        turret.PrimaryBanks[b].WeaponClass=screen
                    else turret.PrimaryBanks[b].WeaponClass=weaponClass end
                end
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
    if self.AftermathActive then return nil end
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
        jobId=job.id,position={x=pos.x,y=pos.y,z=pos.z},startedAt=job.startedAt,finishAt=job.finishAt},job.startedAt)
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
                    jobId=job.id,cost=job.cost,reason=reason or "SPAWN_FAILED"},now)
            else
                self:EmitAIEvent("SENTRY_BUILD",{action="BUILD_COMPLETED",faction=job.kind,class=job.option.class,
                    jobId=job.id,cost=job.cost,signature=ship:getSignature(),buildSeconds=now-job.startedAt},now)
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
    for _, option in ipairs(self:GetFactionSentryClassList(kind)) do
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
    local screen=cfg(self).Sentries.ScreenWeapon and tb.WeaponClasses and tb.WeaponClasses[cfg(self).Sentries.ScreenWeapon]
    local screenRange=objectValid(screen) and self:GetWeaponFiringRange(screen) or 0
    return "cannon " .. math.floor(self:GetSentryWeaponRange(option)) .. " m | fighter screen "..math.floor(screenRange).." m"
end
