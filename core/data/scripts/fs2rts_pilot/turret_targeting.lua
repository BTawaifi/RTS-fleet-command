-- Pilot flak and battery targeting.
local _shared = require "fs2rts_pilot.common"
local RTS, objectValid, vec, shipAlive, shipValid, clamp = _shared.RTS, _shared.objectValid, _shared.vec, _shared.shipAlive, _shared.shipValid, _shared.clamp

function RTS:GetPilotFlakWeapon(turret)
    for _,banks in ipairs({turret.PrimaryBanks or {},turret.SecondaryBanks or {}}) do
        for i=1,#banks do
            local bank=banks[i]; local weapon=bank and bank.WeaponClass
            if objectValid(weapon) and (self.Config.Pilot.FlakWeapons or {})[weapon.Name] then return weapon end
        end
    end
end

function RTS:GetPilotFlakAim(turret,target,weapon,origin,speedOverride)
    local point=target.Position; local velocity=target.Physics and target.Physics.Velocity or vec(0,0,0)
    local delta=point-(origin or turret.WorldPosition); local speed=speedOverride or weapon.Speed or 0
    if speed<=1 then return point end
    local a=velocity.x^2+velocity.y^2+velocity.z^2-speed^2
    local b=2*(delta.x*velocity.x+delta.y*velocity.y+delta.z*velocity.z)
    local c=delta.x^2+delta.y^2+delta.z^2
    local time=0
    if math.abs(a)<.001 then
        if b<-.001 then time=-c/b end
    else
        local discriminant=b*b-4*a*c
        if discriminant>=0 then
            local root=math.sqrt(discriminant)
            local t1,t2=(-b-root)/(2*a),(-b+root)/(2*a)
            if t1>0 then time=t1 end
            if t2>0 and (time==0 or t2<time) then time=t2 end
        end
    end
    if weapon.LifeMax and weapon.LifeMax>0 then time=math.min(time,weapon.LifeMax) end
    return point+velocity*time
end

function RTS:OnPilotTurretFired(weapon,ship)
    if not self.Enabled or not self.PossessedSignature or not objectValid(weapon) or not shipValid(ship)
        or ship:getSignature()~=self.PossessedSignature then return end
    local flak=(self.Config.Pilot.FlakWeapons or {})[weapon.Class.Name]
    -- Deferred swarm/corkscrew launches ignore fireWeapon's vector and use
    -- the resting barrel later. Correct only these launches; ordinary weapon
    -- spread remains native, and unpossessed fleets never enter this path.
    if not flak and not weapon.Class:getSwarmInfo() and not weapon.Class:getCorkscrewInfo() then return end
    local turret=weapon.ParentTurret
    local target=objectValid(weapon.Target) and weapon.Target or (objectValid(turret) and turret.Target)
    if not shipAlive(target) or not self:AreEnemies(ship,target) then return end
    local origin=weapon.Position
    local speed=weapon.Physics.Velocity:getDistance(vec(0,0,0))
    local point=self:GetPilotFlakAim(turret,target,weapon.Class,origin,speed)
    local range=origin:getDistance(point)
    if range<1 then return end
    local direction=(point-origin)/range
    weapon.Orientation=direction:getOrientation(); weapon.Physics.Velocity=direction*speed
    if flak then
        self.PilotFlakPendingShots=self.PilotFlakPendingShots or {}
        self.PilotFlakPendingShots[#self.PilotFlakPendingShots+1]={weapon=weapon,range=range}
    end
end

function RTS:FinalizePilotFlakShots()
    for _,shot in ipairs(self.PilotFlakPendingShots or {}) do
        if objectValid(shot.weapon) then shot.weapon.FlakDetonationRange=shot.range end
    end
    self.PilotFlakPendingShots=nil
end

function RTS:GetPilotFlakTarget(ship,entry,selected)
    local turret=entry.subsystem; local range=self:GetWeaponFiringRange(entry.flakWeapon)
    local function suitable(target,explicit)
        return shipAlive(target) and self:AreEnemies(ship,target)
            and (explicit or not self.CanAutoEngage or self:CanAutoEngage(ship,target))
            and turret.WorldPosition:getDistance(target.Position)-(target.Radius or 0)<=range
            and turret:isTargetInFOV(target)==true
            and turret:isPositionInFOV(target.Position)==true
    end
    local role=shipAlive(selected) and self:GetShipRole(selected)
    if (role=='fighter' or role=='bomber') and suitable(selected,true) then return selected end
    local now=self:UINow(); local cached=self:FindShipBySignature(entry.flakTargetSignature)
    if now<(entry.flakTargetRefresh or 0) and suitable(cached,false) then return cached end
    if now>=(entry.flakTargetRefresh or 0) then
        entry.flakTargetRefresh=now+.25
        local candidates=self.PilotFlakCandidates
        if not candidates or now-candidates.at>=.25 then
            candidates={at=now,ships={}}
            local envelope=range
            for name in pairs(self.Config.Pilot.FlakWeapons or {}) do
                local weapon=tb.WeaponClasses[name]
                if objectValid(weapon) then envelope=math.max(envelope,self:GetWeaponFiringRange(weapon)) end
            end
            for _,other in ipairs(self:GetShipList()) do
                if shipAlive(other) and self:AreEnemies(ship,other)
                    and (not self.CanAutoEngage or self:CanAutoEngage(ship,other))
                    and ship.Position:getDistance(other.Position)<=envelope+(ship.Radius or 0)+(other.Radius or 0) then
                    local kind=self:GetShipRole(other)
                    if kind=='fighter' or kind=='bomber' then candidates.ships[#candidates.ships+1]=other end
                end
            end
            self.PilotFlakCandidates=candidates
        end
        local best,distance=nil,math.huge
        for _,target in ipairs(candidates.ships) do
            if suitable(target,false) then
                local d=turret.WorldPosition:getDistance(target.Position)
                if d<distance then best,distance=target,d end
            end
        end
        entry.flakTargetSignature=best and best:getSignature() or nil
        if best then return best end
    end
    if suitable(selected,true) then return selected end
end

function RTS:GetPilotBatteryTarget(ship,entry,selected)
    local turret=entry.subsystem
    local turretPosition=turret.WorldPosition
    local function suitable(target,explicit)
        return shipAlive(target)
            and turretPosition:getDistance(target.Position)-(target.Radius or 0)<=entry.range
            and self:AreEnemies(ship,target)
            and (explicit or not self.CanAutoEngage or self:CanAutoEngage(ship,target))
            and turret:isTargetInFOV(target)==true
            and turret:isPositionInFOV(target.Position)==true
    end
    local selectedValid=suitable(selected,true)
    local origin,normal=turret:getNextFiringPosition()
    if selectedValid then
        if not entry.hasBeam then return selected end
        -- Direct/slashing beams pick points on the target model, not its
        -- centre. A large hull straddling the barrel cone can reject every
        -- shot despite a legal centre. Let gunners use a local contact then;
        -- retain the selected hull when no alternative exists.
        local delta=selected.Position-origin; local d=delta:getDistance(vec(0,0,0))
        local dot=d>1 and (delta.x*normal.x+delta.y*normal.y+delta.z*normal.z)/d or 1
        if d>1 and math.acos(clamp(dot,-1,1))+math.asin(clamp((selected.Radius or 0)/d,0,1))<=math.acos(clamp(turret:getFOVs(),-1,1)) then return selected end
    end
    local now=self:UINow()
    local cached=self:FindShipBySignature(entry.batteryTargetSignature)
    if now<(entry.batteryTargetRefresh or 0) then return suitable(cached,false) and cached or (selectedValid and selected or nil) end
    entry.batteryTargetRefresh=now+.25
    local candidates=self.PilotBatteryCandidates
    if not candidates or now-candidates.at>=.25 then
        candidates={at=now,ships={}}
        for _,other in ipairs(self:GetShipList()) do
            if shipAlive(other) and self:AreEnemies(ship,other)
                and (not self.CanAutoEngage or self:CanAutoEngage(ship,other)) then candidates.ships[#candidates.ships+1]=other end
        end
        self.PilotBatteryCandidates=candidates
    end
    local best,score=nil,math.huge
    for _,other in ipairs(candidates.ships) do
        if suitable(other,false) then
            local delta=other.Position-origin; local d=delta:getDistance(vec(0,0,0))
            local alignment=d>1 and (delta.x*normal.x+delta.y*normal.y+delta.z*normal.z)/d or 1
            -- Favor a contact the barrel can already bear on over a slightly
            -- nearer hull at the arc edge. Narrow beams otherwise waste whole
            -- cooldowns on edge-of-cone shots despite usable local contacts.
            local cost=d/math.max(.05,alignment)^4
            if cost<score then best,score=other,cost end
        end
    end
    entry.batteryTargetSignature=best and best:getSignature() or nil
    return best or (selectedValid and selected or nil)
end
