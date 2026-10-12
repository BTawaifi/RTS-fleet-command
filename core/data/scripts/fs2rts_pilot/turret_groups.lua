-- Pilot turret groups and subsystem targeting.
local _shared = require "fs2rts_pilot.common"
local RTS, shipValid, objectValid, sexpString, clearPilotForcedTarget = _shared.RTS, _shared.shipValid, _shared.objectValid, _shared.sexpString, _shared.clearPilotForcedTarget

-- Any friendly hull can be possessed. The old prefix allow-list (GTF/GTC/SD/...)
-- silently excluded every class it did not name, including user-made and
-- mission-specific hulls, so those ships could never be flown. Static defenses
-- are excluded because they are immobile installations, and the capital
-- turret-group layer keys off IsPilotableCapital, not off this gate.
function RTS:IsPilotableShip(ship)
    if not self:IsFriendly(ship) then return false end
    if (self.IsCommandStation and self:IsCommandStation(ship))
        or ship.Name == self.Config.CarrierShip or ship.Name == self.Config.EnemyCommandShip
        or ship.Name == self.Config.ThirdCommandShip or ship.Name == self.Config.ObserverShip then return false end
    if self:IsStaticDefense(ship) then return false end
    return true
end

-- The turret-group layer only applies to a hull whose weapons live in turret
-- subsystems; a fighter carries its guns on the ship itself, where
-- ship:firePrimary() already reaches them. Detect that structurally rather than
-- by class-name prefix, so user-made and mission-specific capitals get the
-- group layer too instead of being excluded by a naming convention.
function RTS:IsPilotableCapital(ship)
    if not shipValid(ship) then return false end
    for i=1,#ship do
        local subsystem=ship[i]
        if subsystem and subsystem:isValid() and subsystem:isTurret() then
            local primaries=subsystem.PrimaryBanks
            local secondaries=subsystem.SecondaryBanks
            if (primaries and #primaries>0) or (secondaries and #secondaries>0) then return true end
        end
    end
    return false
end

function RTS:InitializePilotTurretGroups(ship)
    self.PilotWeaponCycleReadout=nil
    if self.PilotTurretGroups then self:RestorePilotTurretGroups() end
    self.PilotWeaponHint=nil
    self.PilotWeaponInventory=nil
    self.PilotTurretGroups=nil; self.PilotTurretGroupIndex=nil; self.PilotTurretAppliedGroupIndex=nil
    self.PilotTurretLastGroupIndex=nil; self.PilotTurretFiring=false; self.PilotTurretFireLatched=false; self.PilotTurretFireStatusAt=nil
    self.PilotTargetSubsystemIndex=0; self.PilotTargetSubsystemCount=0
    self.PilotAimTargetSignature=nil; self.PilotNativeSubsystemName=nil
    if not self:IsPilotableCapital(ship) then return end
    local byWeapons={}
    for i=1,#ship do
        local subsystem=ship[i]
        if subsystem and subsystem:isValid() and subsystem:isTurret() then
            local weapons={}; local reach=0; local hasBeam=false
            for _,banks in ipairs({subsystem.PrimaryBanks or {},subsystem.SecondaryBanks or {}}) do
                for b=1,#banks do
                    local bank=banks[b]; local weapon=bank and bank:isValid() and bank.WeaponClass
                    if weapon and weapon:isValid() then
                        weapons[#weapons+1]=weapon.Name
                        reach=math.max(reach,self:GetWeaponFiringRange(weapon))
                        hasBeam=hasBeam or weapon:isBeam()
                    end
                end
            end
            table.sort(weapons)
            if #weapons>0 then
                local label=table.concat(weapons," + ")
                local group=byWeapons[label]
                if group==nil then group={label=label,turrets={}}; byWeapons[label]=group end
                group.turrets[#group.turrets+1]={subsystem=subsystem,wasLocked=subsystem.TurretLocked==true,
                    range=reach,hasBeam=hasBeam,flakWeapon=self:GetPilotFlakWeapon(subsystem)}
            end
        end
    end
    local groups={}; for _,group in pairs(byWeapons) do groups[#groups+1]=group end
    table.sort(groups,function(a,b) return a.label<b.label end)
    self.PilotTurretGroups=groups; self.PilotTurretGroupIndex=nil
    self.PilotTurretAppliedGroupIndex=false -- force the initial ALL-group pass
    self:ApplyPilotTurretGroup(ship.Target)
end

-- 0 means "the whole target ship"; 1..count select one of its subsystems.
function RTS:ResolvePilotTargetSubsystemIndex(target)
    local count=shipValid(target) and #target or 0
    self.PilotTargetSubsystemCount=count
    local index=self.PilotTargetSubsystemIndex or 0
    if count<1 or index<1 or index>count then return 0 end
    return index
end

function RTS:InvalidatePilotTurretTargets()
    for _,group in ipairs(self.PilotTurretGroups or {}) do group.targetAssigned=nil end
end

function RTS:ApplyPilotTurretGroup(target)
    local groups=self.PilotTurretGroups
    if groups==nil then return end
    local ship=self:GetPossessedShip(); local targetSignature=shipValid(target) and self:IsPlayerEnemy(target) and target:getSignature() or nil
    if self.PilotAimTargetSignature~=targetSignature then
        self.PilotAimTargetSignature=targetSignature
        self.PilotTargetSubsystemIndex=0
    end
    local groupIndex=self.PilotTurretGroupIndex
    if self.PilotTurretAppliedGroupIndex~=groupIndex then
        for i,group in ipairs(groups) do
            for _,entry in ipairs(group.turrets) do
                local subsystem=entry.subsystem
                if subsystem:isValid() then
                    subsystem:targetingOverride(true)
                    -- The pilot owns firing. rotateTurret below handles aiming
                    -- while this lock prevents native automatic trigger pulls.
                    subsystem.TurretLocked=true
                end
            end
        end
        self.PilotTurretAppliedGroupIndex=groupIndex
    end
    local subsystemIndex=self:ResolvePilotTargetSubsystemIndex(target)
    for i,group in ipairs(groups) do
        if groupIndex==nil or i==groupIndex then
            local changed=not group.targetAssigned or group.targetSignature~=targetSignature or group.targetSubsystemIndex~=subsystemIndex
            do
                -- Subsystem.Target is declared ADE_VIRTVAR(Target, l_Subsystem,
                -- "object", ...) and reads its argument with l_Object.GetPtr, so
                -- it accepts an OBJECT and nothing else. Assigning a subsystem to
                -- it raises "Argument 2 is the wrong type of userdata; 'subsystem'
                -- given, but 'object' expected", which aborts StartPilotMode
                -- mid-initialisation and is why capitals could not be flown at
                -- all. Subsystem aiming uses the upstream forced-subsystem
                -- SEXP after assigning the whole object to this property.
                local newTarget=nil
                if targetSignature~=nil and objectValid(target) then newTarget=target end
                for _,entry in ipairs(group.turrets) do
                    local turret=entry.subsystem
                    if turret:isValid() and not entry.wasLocked and not entry.flakWeapon then
                        -- Native turret AI may discard a target outside its arc
                        -- or reach. Retry a selected hull when it becomes valid.
                        local current=turret.Target
                        if changed or (newTarget and (not objectValid(current) or current:getSignature()~=targetSignature))
                            or (not newTarget and objectValid(current)) then
                            clearPilotForcedTarget(entry)
                            turret.Target=newTarget
                            turret:targetingOverride(true)
                            local aim=subsystemIndex>0 and newTarget and newTarget[subsystemIndex] or nil
                            if objectValid(aim) then
                                local command='(turret-set-forced-subsys-target '..sexpString(newTarget.Name)..' '..sexpString(aim.CanonicalName)..' '..sexpString(ship.Name)..' '..sexpString(turret.CanonicalName)..')'
                                if mn.runSEXP(command)==true then entry.forcedOwner=ship.Name end
                            end
                        end
                    end
                end
                group.targetSignature=targetSignature; group.targetSubsystemIndex=subsystemIndex; group.targetAssigned=true
            end
        end
    end
end

function RTS:CyclePilotTurretGroup(delta)
    local groups=self.PilotTurretGroups
    if groups==nil or #groups<2 then return false end
    local index=self.PilotTurretGroupIndex or self.PilotTurretLastGroupIndex or (delta>0 and 0 or 1)
    self.PilotTurretGroupIndex=((index-1+delta)%#groups)+1
    local ship=self:GetPossessedShip(); self:ApplyPilotTurretGroup(shipValid(ship) and ship.Target or nil)
    local group=groups[self.PilotTurretGroupIndex]
    self:SetStatus("CAPITAL WEAPONS: "..group.label.." ("..self.PilotTurretGroupIndex.."/"..#groups..")",2)
    return true
end

-- A nil group index means every group is live at once: all turrets unlocked and
-- assigned, so a capital can put its whole battery on one target.
function RTS:TogglePilotTurretGroup()
    local groups=self.PilotTurretGroups
    if groups==nil or #groups<2 then return false end
    self:InvalidatePilotTurretTargets()
    if self.PilotTurretGroupIndex==nil then
        self.PilotTurretGroupIndex=self.PilotTurretLastGroupIndex or 1
        local group=groups[self.PilotTurretGroupIndex]
        self:SetStatus("CAPITAL WEAPONS: "..group.label.." ("..self.PilotTurretGroupIndex.."/"..#groups..")",2)
    else
        self.PilotTurretLastGroupIndex=self.PilotTurretGroupIndex
        self.PilotTurretGroupIndex=nil
        self:SetStatus("CAPITAL WEAPONS: ALL GROUPS LIVE ("..#groups..")",2)
    end
    local ship=self:GetPossessedShip(); self:ApplyPilotTurretGroup(shipValid(ship) and ship.Target or nil)
    return true
end

function RTS:CyclePilotTargetSubsystem(delta)
    local ship=self:GetPossessedShip()
    if not shipValid(ship) then return false end
    local target=ship.Target
    local count=shipValid(target) and #target or 0
    self.PilotTargetSubsystemCount=count
    if count<1 then self:SetStatus("TURRET AIM: TARGET HAS NO SUBSYSTEMS",1.5); return false end
    local index=(self.PilotTargetSubsystemIndex or 0)+delta
    if index<0 then index=count elseif index>count then index=0 end
    self.PilotTargetSubsystemIndex=index
    local observer=self:GetObserver()
    if shipValid(observer) then observer.TargetSubsystem=index>0 and target[index] or nil end
    self:InvalidatePilotTurretTargets()
    self:ApplyPilotTurretGroup(target)
    self:SetStatus("AIM: "..self:GetPilotTargetSubsystemLabel(),1.5)
    return true
end

function RTS:TogglePilotTargetSubsystem()
    local count=self.PilotTargetSubsystemCount or 0
    if count<2 then return self:CyclePilotTargetSubsystem(1) end
    local index=self.PilotTargetSubsystemIndex or 0
    return self:CyclePilotTargetSubsystem(index>0 and -index or 1)
end

function RTS:GetPilotTargetSubsystemLabel()
    local ship=self:GetPossessedShip()
    local target=shipValid(ship) and ship.Target or nil
    local count=shipValid(target) and #target or 0
    local index=self.PilotTargetSubsystemIndex or 0
    if not objectValid(target) then return 'FORWARD // NO TARGET' end
    if not shipValid(target) then return 'OBJECT TARGET' end
    if index<1 or index>count then return 'WHOLE SHIP' end
    return tostring(target[index].Name)..' ('..index..'/'..count..')'
end
