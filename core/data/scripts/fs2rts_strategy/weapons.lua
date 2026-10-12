-- Strategic weapon ranges and station beam-hit observation.
local _shared = require "fs2rts_strategy.common"
local RTS, objectValid, shipValid, shipAlive, BEAM_DAMAGE_INTERVAL = _shared.RTS, _shared.objectValid, _shared.shipValid, _shared.shipAlive, _shared.BEAM_DAMAGE_INTERVAL

function RTS:GetShipWeaponRanges(ship)
    local ranges={primary=0,secondary=0,beam=0}
    local manual={}
    if self.PossessedSignature==ship:getSignature() then
        for i,group in ipairs(self.PilotTurretGroups or {}) do
            if self.PilotTurretGroupIndex==nil or self.PilotTurretGroupIndex==i then
                for _,entry in ipairs(group.turrets) do manual[entry.subsystem.CanonicalName or entry.subsystem.Name]=not entry.wasLocked end
            end
        end
    end
    local function scan(banks,kind,beamFree)
        for i=1,#banks do
            local bank=banks[i]; local weapon=bank.WeaponClass
            if objectValid(bank) and objectValid(weapon) and ((bank.AmmoMax or 0)<=0 or (bank.AmmoLeft or 0)>0) then
                local beam=weapon:isBeam()
                local r=self:GetWeaponFiringRange(weapon)
                -- Upstream ai_turret_execute_behavior uses this firing reach
                -- for beams too. BeamInfo's visual ray length is a different
                -- value and is not exposed by WeaponClass.Range.
                if self:IsFiniteNumber(r) and (not beam or beamFree~=false) then
                    local key=beam and "beam" or kind
                    ranges[key]=math.max(ranges[key],r)
                end
            end
        end
    end
    local okP,primariesLocked=pcall(function() return ship:getFlag("primaries-locked") end)
    local okS,secondariesLocked=pcall(function() return ship:getFlag("secondaries-locked") end)
    if not (okP and primariesLocked) then scan(ship.PrimaryBanks or {},"primary") end
    if not (okS and secondariesLocked) then scan(ship.SecondaryBanks or {},"secondary") end
    for i=1,#ship do
        local turret=ship[i]
        if objectValid(turret) and (not turret.TurretLocked or manual[turret.CanonicalName or turret.Name]) and (turret.HitpointsMax<=0 or turret.HitpointsLeft>0) then
            local okT,isTurret=pcall(function() return turret:isTurret() end)
            if okT and isTurret then scan(turret.PrimaryBanks or {},"primary",turret.BeamFree); scan(turret.SecondaryBanks or {},"secondary",turret.BeamFree) end
        end
    end
    return ranges
end

function RTS:GetShipWeaponRange(ship)
    local ranges=self:GetShipWeaponRanges(ship)
    return math.max(ranges.primary,ranges.secondary,ranges.beam)
end

function RTS:GetWeaponFiringRange(weapon)
    if not objectValid(weapon) then return 0 end
    local range=math.min(tonumber(weapon.Range) or 0,(tonumber(weapon.Speed) or 0)*(tonumber(weapon.LifeMax) or 0))
    return self:IsFiniteNumber(range) and math.max(0,range) or 0
end

function RTS:GetStrategicWeapons(ship)
    local mounts={}
    local armed=false; local profileBeam=false; local maximumRange=0; local firepower=0
    local function addBankList(owner,banks,position,includeMount)
        local reach=0; local mountBeam=false
        for i=1,#banks do
            local bank=banks[i]; local weapon=bank.WeaponClass
            if includeMount and objectValid(bank) and objectValid(weapon) and ((bank.AmmoMax or 0)<=0 or (bank.AmmoLeft or 0)>0) then
                armed=true
                local beam=weapon:isBeam()
                local cycle=math.max(.25,weapon.FireWait or 1)
                local damage=math.max(1,weapon.Damage or 0)
                if beam then
                    damage=damage*math.max(.1,weapon.BeamLife or 1)/BEAM_DAMAGE_INTERVAL
                    cycle=cycle+(weapon.BeamWarmup or 0)+(weapon.BeamLife or 0)+(weapon.BeamWarmdown or 0)
                end
                firepower=firepower+damage/cycle*(owner==ship and 1 or owner.FireRateMultiplier)
                profileBeam=profileBeam or beam
                if includeMount then
                    -- Native turret acquisition/firing uses this cap for beams
                    -- as well as projectiles. Role estimates of 8 km parked
                    -- capitals outside their real 4 km beam firing range.
                    local r=self:GetWeaponFiringRange(weapon)
                    if beam then mountBeam=true end
                    if self:IsFiniteNumber(r) then reach=math.max(reach,r) end
                end
            end
        end
        if includeMount and (reach>0 or mountBeam) then
            mounts[#mounts+1]={range=reach,position=position,target=owner.Target,beam=mountBeam}
            maximumRange=math.max(maximumRange,reach)
        end
    end
    local function addOwner(owner,position,includeMount)
        addBankList(owner,owner.PrimaryBanks,position,includeMount)
        addBankList(owner,owner.SecondaryBanks,position,includeMount)
    end
    -- 'weapons-locked' controls the loadout screen, not combat firing. Check
    -- each combat bank's lock separately; turret locks are independent too.
    local primariesLocked = ship:getFlag('primaries-locked')
    local secondariesLocked = ship:getFlag('secondaries-locked')
    if not (primariesLocked and secondariesLocked) then
        addBankList(ship,ship.PrimaryBanks,ship.Position,not primariesLocked)
        addBankList(ship,ship.SecondaryBanks,ship.Position,not secondariesLocked)
    end
    for i=1,#ship do
        local turret=ship[i]
        if objectValid(turret) and not turret.TurretLocked then
            -- A destroyed or locked turret cannot contribute combat strength.
            local includeMount=turret.HitpointsMax<=0 or turret.HitpointsLeft>0
            addOwner(turret,includeMount and turret.WorldPosition or nil,includeMount)
        end
    end
    return mounts,armed,profileBeam,maximumRange,firepower
end

function RTS:RecordStationBeamHit(target,attacker,now,source)
    local stationSig=target:getSignature()
    local attackerSig=attacker:getSignature()
    self.StationBeamHits=self.StationBeamHits or {}
    self.StationBeamHits[stationSig]=self.StationBeamHits[stationSig] or {}
    self.StationBeamHits[stationSig][attackerSig]=now
    self.StationBeamHitSeen=self.StationBeamHitSeen or {}
    self.StationBeamHitSeen[stationSig]=self.StationBeamHitSeen[stationSig] or {}
    if not self.StationBeamHitSeen[stationSig][attackerSig] then
        self.StationBeamHitSeen[stationSig][attackerSig]=true
        if self.CombatTelemetryEnabled then
            self:EmitAIEvent("STATION_BEAM_HIT",{targetName=target.Name,targetFaction=self:GetFactionKey(target),
                attackerSignature=attackerSig,attackerName=attacker.Name,
                attackerClass=attacker.Class and attacker.Class.Name or "UNKNOWN",
                attackerFaction=self:GetFactionKey(attacker),source=source or "UNKNOWN",
                distance=attacker.Position:getDistance(target.Position)},now)
        end
    end
end

function RTS:RegisterStationBeamHitHook()
    if self.StationBeamHookRegistered then return end
    local ok=engine.addHook("On Beam Collision",function()
        if not self.Enabled or self.SetupActive or self.PostBattleActive then return end
        local target=hv["Self"]
        local beam=hv["Beam"]
        if not objectValid(target) or target:getBreedName()~="Ship" or not self:IsCommandStation(target)
            or not objectValid(beam) then return end
        local attacker=beam.ParentShip
        if shipValid(attacker) and self:CanDamageBase(attacker) and self:AreEnemies(target,attacker) then
            self:RecordStationBeamHit(target,attacker,mn.getMissionTime(),"ON_BEAM_COLLISION")
        end
    end)
    self.StationBeamHookRegistered=ok==true
    if not self.StationBeamHookRegistered then self:Log("Station beam tracking unavailable: On Beam Collision hook registration failed") end
end

function RTS:ObserveStationBeamHits(now)
    -- Beam contacts arrive through On Beam Collision. Only age the small
    -- station/attacker cache periodically; never scan every live beam per frame.
    if now<(self.NextStationBeamCleanup or 0) then return end
    self.NextStationBeamCleanup=now+1
    self.StationBeamHits=self.StationBeamHits or {}
    local memory=(self.Config.AI.Doctrine or {}).BeamHitMemorySeconds or 6
    for stationSig,hits in pairs(self.StationBeamHits) do
        for attackerSig,time in pairs(hits) do if now-time>memory then hits[attackerSig]=nil end end
        if next(hits)==nil then self.StationBeamHits[stationSig]=nil end
    end
end

function RTS:BuildStrategicThreatSnapshot()
    local snapshot={}
    self:EachShip(function(ship)
        if ship.Name~=self.Config.ObserverShip and shipAlive(ship) then
            local mounts,armed,beam,reach,power=self:GetStrategicWeapons(ship)
            snapshot[#snapshot+1]={ship=ship,mounts=mounts,armed=armed,profileBeam=beam,maxRange=reach,firepower=power}
        end
    end)
    return snapshot
end
