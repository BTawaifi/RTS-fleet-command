-- Pilot turret group drive and HUD restore.
local _shared = require "fs2rts_pilot.common"
local RTS, objectValid, shipValid, clearPilotForcedTarget, turretTrigger, turretSecondaries = _shared.RTS, _shared.objectValid, _shared.shipValid, _shared.clearPilotForcedTarget, _shared.turretTrigger, _shared.turretSecondaries

-- Drives the active turret group directly: a capital keeps its weapons in turret
-- subsystems, so ship:firePrimary()/fireSecondary() reach nothing on one.
function RTS:UpdatePilotTurretFire(primaryDown, secondaryDown)
    local groups=self.PilotTurretGroups
    if groups==nil or #groups==0 then
        -- All three are reset together here, as at :46, :236 and
        -- fs2rts_factions/spawn_frame.lua:144. Clearing only the latch left
        -- PilotTurretFiring stuck true, so the HUD kept drawing the
        -- MANUAL TURRET FIRE ACTIVE banner (hud.lua:1053) for a pilot frame
        -- that had no turrets to fire with.
        self.PilotTurretFireLatched=false; self.PilotTurretFiring=false; self.PilotTurretFireStatusAt=nil
        return
    end
    local previous=self.PilotTurretFireLatched==true
    local engaged
    if self.Config.Pilot.TurretFireLatches~=false then engaged=primaryDown else engaged=primaryDown and not previous end
    self.PilotTurretFireLatched=primaryDown
    local groupIndex=self.PilotTurretGroupIndex
    local ship=self:GetPossessedShip()
    if not shipValid(ship) then return end
    if self.IsShipWithdrawing and self:IsShipWithdrawing(ship) then
        self.PilotTurretFireLatched=false; self.PilotTurretFiring=false; self.PilotTurretFireStatusAt=nil
        for _,group in ipairs(groups) do
            for _,entry in ipairs(group.turrets) do
                if objectValid(entry.subsystem) then entry.subsystem.TurretLocked=true end
            end
        end
        return
    end
    for i,group in ipairs(groups) do
        local live=groupIndex==nil or i==groupIndex
        for _,entry in ipairs(group.turrets) do
            local turret=entry.subsystem
            local target=ship.Target
            local flakAim=nil
            if live and entry.wasLocked~=true and objectValid(turret) then
                if entry.flakWeapon then
                    target=self:GetPilotFlakTarget(ship,entry,target)
                    clearPilotForcedTarget(entry)
                    turret.Target=target
                    if objectValid(target) then flakAim=self:GetPilotFlakAim(turret,target,entry.flakWeapon) end
                elseif entry.range then
                    target=self:GetPilotBatteryTarget(ship,entry,target)
                    if target~=ship.Target then clearPilotForcedTarget(entry) end
                    turret.Target=target
                end
                local selected=not entry.flakWeapon and target==ship.Target and self:ResolvePilotTargetSubsystemIndex(target) or 0
                local subsystem=selected>0 and objectValid(target) and target[selected] or nil
                local aim=objectValid(subsystem) and subsystem.WorldPosition or (objectValid(target) and target.Position or (ship.Position+ship.Orientation:getFvec()*10000))
                if not flakAim and objectValid(target) and not objectValid(subsystem) then
                    for b=1,#turret.PrimaryBanks do
                        local weapon=turret.PrimaryBanks[b].WeaponClass
                        if objectValid(weapon) and not weapon:isBeam() then aim=self:GetPilotFlakAim(turret,target,weapon); break end
                    end
                end
                turret:rotateTurret(flakAim or aim,false)
            end
            entry.targetRequired=objectValid(ship.Target)
            local fire=live and engaged and entry.wasLocked~=true
            local ok,err=pcall(turretTrigger,entry,fire,flakAim)
            if not ok then self:SetStatus("TURRET FIRE FAILED: "..tostring(err),2) end
            if live and secondaryDown and entry.wasLocked~=true then
                ok,err=pcall(turretSecondaries,entry,flakAim)
                if not ok then self:SetStatus("TURRET SECONDARY FAILED: "..tostring(err),2) end
            end
        end
    end
    self.PilotTurretFiring=engaged or secondaryDown
    if self.PilotTurretFiring then
        local now=self:UINow()
        if self.PilotTurretFireStatusAt==nil or (now-self.PilotTurretFireStatusAt)>=0.5 then
            self.PilotTurretFireStatusAt=now
            self:SetStatus(self.Config.Pilot.TurretFireStatusLine or "MANUAL TURRET FIRE ACTIVE",0.6)
        end
    else
        self.PilotTurretFireStatusAt=nil
    end
end

function RTS:RestorePilotTurretGroups()
    self:RestorePilotHullHUD()
    self.PilotWeaponCycleReadout=nil
    self.PilotBatteryCandidates=nil
    self.PilotFlakCandidates=nil
    self.PilotFlakPendingShots=nil
    self:SetPilotWeaponsHUD(false)
    self.PilotWeaponHint=nil
    for _,group in ipairs(self.PilotTurretGroups or {}) do
        for _,entry in ipairs(group.turrets) do
            local subsystem=entry.subsystem
            if subsystem:isValid() then
                clearPilotForcedTarget(entry)
                subsystem:targetingOverride(false)
                subsystem.TurretLocked=entry.wasLocked
            end
        end
    end
    self.PilotTurretGroups=nil; self.PilotTurretGroupIndex=nil; self.PilotTurretAppliedGroupIndex=nil; self.PilotTurretLastGroupIndex=nil
    self.PilotTurretFiring=false; self.PilotTurretFireLatched=false; self.PilotTurretFireStatusAt=nil
    self.PilotTargetSubsystemIndex=0; self.PilotTargetSubsystemCount=0
end

function RTS:SetPilotWeaponsHUD(active)
    if self.PilotWeaponsHUDOverridden==active then return end
    -- Resolve a fresh gauge handle on transitions; HUD gauge pointers may be
    -- rebuilt on mission restart and must not be retained across missions.
    if hu and hu.getHUDGaugeHandle then
        local gauge=hu.getHUDGaugeHandle('Weapons')
        if gauge then gauge:setRenderOverride(active) end
    end
    self.PilotWeaponsHUDOverridden=active
end

function RTS:RestorePilotHullHUD()
    for name,active in pairs(self.PilotHullHUDOverrides or {}) do
        if active and hu and hu.getHUDGaugeHandle then
            local gauge=hu.getHUDGaugeHandle(name)
            if gauge~=nil then gauge:setRenderOverride(false) end
        end
    end
    self.PilotHullHUDOverrides=nil
end
