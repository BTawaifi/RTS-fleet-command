-- Pilot eject, death view and per-frame update.
local _shared = require "fs2rts_pilot.common"
local RTS, copyVec, shipValid, clamp, vec, objectValid = _shared.RTS, _shared.copyVec, _shared.shipValid, _shared.clamp, _shared.vec, _shared.objectValid

function RTS:BeginPilotEject(ship)
    if self.PendingPilotEject then return end
    local delay=math.max(0,self.Config.Pilot.DeathViewSeconds or 5)
    self.PendingPilotEject=true
    self.PendingPilotEjectRemaining=delay
    local timeScale=tonumber(self.TimeScale) or 1
    if timeScale>1 then
        -- The view delay uses real time, but FSO advances the explosion at mission speed.
        self.PilotDeathRestoreTimeScale=timeScale
        self.PilotDeathRestoreLastNonZeroTimeScale=self.LastNonZeroTimeScale
        self:SetTimeScale(1)
    end
    local cameraShip=ship
    if not shipValid(cameraShip) then cameraShip=self:GetObserver() end
    if shipValid(cameraShip) then
        self.PendingPilotEjectPosition=copyVec(cameraShip.Position)
        self.PendingPilotEjectOrientation=cameraShip.Orientation:copy()
        self.PendingPilotEjectRadius=30
        if cameraShip.Class and cameraShip.Class.Model then
            self.PendingPilotEjectRadius=math.max(1,cameraShip.Class.Model.Radius)
        end
    end
end

function RTS:UpdatePilotDeathView()
    self:SetPilotInputMode()
    local observer=self:GetObserver()
    if not shipValid(observer) then
        self:ExitPilotMode("CONTROL PROXY LOST - returned to RTS",false)
        return
    end
    local ship=self:GetPossessedShip()
    if shipValid(ship) then
        self.PendingPilotEjectPosition=copyVec(ship.Position)
        if ship.Class and ship.Class.Model then
            self.PendingPilotEjectRadius=math.max(1,ship.Class.Model.Radius)
        end
    end
    if self.PendingPilotEjectPosition~=nil then observer.Position=copyVec(self.PendingPilotEjectPosition) end
    if self.PendingPilotEjectOrientation~=nil then observer.Orientation=self.PendingPilotEjectOrientation:copy() end
    observer.Physics.Velocity=vec(0,0,0)
    observer.Physics.AfterburnerActive=false
    observer.Target=nil
    self:DisarmObserverWeapons()

    -- The player proxy survives the possessed ship, so resetting to the native
    -- camera leaves the player trapped in its cockpit during the death delay.
    -- Use the RTS chase camera outside the dying craft, then hold the last
    -- known explosion position after FSO removes the ship object.
    local camera=self.FollowCamera or self.Camera
    if camera~=nil then
        local position=self.PendingPilotEjectPosition
        local orientation=self.PendingPilotEjectOrientation
        if position~=nil and orientation~=nil then
            local radius=self.PendingPilotEjectRadius or 30
            local c=self.Config.Camera
            local duration=math.max(0.1,self.Config.Pilot.DeathViewSeconds or 5)
            local remaining=math.max(0,self.PendingPilotEjectRemaining or duration)
            local progress=clamp((duration-remaining)/duration,0,1)
            local distance=math.max(c.FollowMinDistance or 180,radius*(c.FollowRadiusMultiplier or 3.2))*(1+0.45*progress)
            local forward=orientation:getFvec()
            local up=orientation:getUvec()
            local orbit=math.rad(20)*progress
            local horizontal=forward*(-math.cos(orbit))+orientation:getRvec()*math.sin(orbit)
            local cameraPosition=position+horizontal*distance+up*(distance*(c.FollowHeightFraction or 0.22))
            local lookAt=position+forward*(radius*(c.FollowLookAheadRadii or 1.0))
            camera.Position=cameraPosition
            camera.Orientation=(lookAt-cameraPosition):getOrientation()
            camera.FOV=c.FollowFOV or c.FOV
        end
        gr.setCamera(camera)
    end
end

function RTS:UpdatePilotMode(dt)
    if self.PilotCommMenuPending then self:UpdatePilotCommMenu() end
    self:UpdatePilotDirectives(self.PendingPilotEject==true)
    self.PilotTurretFiring=false
    if self.PendingPilotEject then
        -- OnFrame receives ba.getRealFrametime(), which is explicitly
        -- independent of mission time compression. Keep this UX delay at five
        -- actual seconds even when the battle is running at an accelerated rate.
        self.PendingPilotEjectRemaining=math.max(0,(self.PendingPilotEjectRemaining or 0)-math.max(0,tonumber(dt) or 0))
        if self.PendingPilotEjectRemaining<=0 then
            self:ExitPilotMode("CRAFT DESTROYED - returned to RTS command",true)
        else
            self:UpdatePilotDeathView()
        end
        return
    end

    local ship = self:GetPossessedShip()
    if not shipValid(ship) or ship:isDying() then
        self:BeginPilotEject(ship)
        self.PendingPilotEjectRemaining=math.max(0,(self.PendingPilotEjectRemaining or 0)-math.max(0,tonumber(dt) or 0))
        if self.PendingPilotEjectRemaining<=0 then
            self:ExitPilotMode("CRAFT DESTROYED - returned to RTS command",true)
        else
            self:UpdatePilotDeathView()
        end
        return
    end

    -- Default FSO player camera/HUD is used in pilot mode. The formal player
    -- proxy shares the possessed fighter's class and transform.
    if self.Paused then
        -- Native frame hooks still run at zero time compression. Direct fire
        -- calls mutate the world, so pause must gate them as well as RTS AI.
        ship.PrimaryTriggerDown=false; ship.Physics.AfterburnerActive=false
        return
    end
    gr.setCamera()

    local observer = self:GetObserver()
    if not shipValid(observer) then
        self:ExitPilotMode("CONTROL PROXY LOST - returned to RTS", false)
        return
    end

    -- Native target/bank controls operate on the proxy. Copy those decisions
    -- into the actual fighter before issuing its maneuver/fire commands.
    local target = observer.Target
    if objectValid(target) and target:getSignature() ~= ship:getSignature() then
        ship.Target = target
    else
        ship.Target = nil
    end
    self:CopyArmedBankState(observer.PrimaryBanks, ship.PrimaryBanks)
    self:CopyArmedBankState(observer.SecondaryBanks, ship.SecondaryBanks)
    ship.PrimaryBanks.Linked = observer.PrimaryBanks.Linked
    ship.SecondaryBanks.DualFire = observer.SecondaryBanks.DualFire
    if self.PilotTurretGroups~=nil then
        self:ApplyPilotTurretGroup(ship.Target)
        local native=observer.TargetSubsystem
        local name=objectValid(native) and native.Name or nil
        if name~=self.PilotNativeSubsystemName then
            self.PilotNativeSubsystemName=name
            self.PilotTargetSubsystemIndex=0
            if name and shipValid(ship.Target) then
                for i=1,#ship.Target do if ship.Target[i].Name==name then self.PilotTargetSubsystemIndex=i; break end end
            end
            self:InvalidatePilotTurretTargets(); self:ApplyPilotTurretGroup(ship.Target)
        end
    end
    if type(observer.EtsEngineIndex)=="number" and
        (observer.EtsEngineIndex~=ship.EtsEngineIndex or observer.EtsShieldIndex~=ship.EtsShieldIndex or observer.EtsWeaponIndex~=ship.EtsWeaponIndex) then
        ship:EtsSetIndexes(observer.EtsEngineIndex,observer.EtsShieldIndex,observer.EtsWeaponIndex)
    end

    local controls = self.ControlInfo or ba.getControlInfo()
    if controls == nil then return end
    self.ControlInfo = controls

    local forward = controls.Forward or 0
    local cruise = clamp(controls.ForwardCruise or 0, 0, 1)
    if math.abs(forward) < 0.02 and cruise > 0 then
        local maxForward = math.abs(ship.Physics.VelocityMax.z)
        local speed = math.max(0, ship.Physics:getForwardSpeed())
        if maxForward > 1 then
            local targetSpeed = maxForward * cruise
            forward = clamp((targetSpeed - speed) / math.max(10, maxForward * 0.25), 0, 1)
        end
    end

    local buttons = self:ReadPilotButtons()
    if self.PilotTurretGroups and not self.PilotWeaponCycleHooksActive then
        if self:IsPilotControlPressed(buttons,"CYCLE_NEXT_PRIMARY") then self:CyclePilotTurretGroup(1)
        elseif self:IsPilotControlPressed(buttons,"CYCLE_PREV_PRIMARY") then self:CyclePilotTurretGroup(-1)
        elseif self:IsPilotControlPressed(buttons,"CYCLE_SECONDARY") then self:CyclePilotTurretGroup(1) end
    end
    local afterburner = observer.Physics.AfterburnerActive and ship.AfterburnerFuelLeft > 0
    if not afterburner then
        afterburner = self:IsPilotControlDown(buttons, "AFTERBURNER") and ship.AfterburnerFuelLeft > 0
    end
    ship.Physics.AfterburnerActive = afterburner
    if afterburner then forward = 1 end

    -- Duration 1 = never expire (released in ExitPilotMode). A finite hold is a
    -- game-time timestamp: under time compression or a frame hitch it lapsed
    -- before the next frame and PLAY_DEAD took over, freezing the craft.
    ship:doManeuver(
        1,
        controls.Heading or 0,
        controls.Pitch or 0,
        controls.Bank or 0,
        true,
        controls.Vertical or 0,
        controls.Sideways or 0,
        clamp(forward, -1, 1),
        true,
        0
    )

    local withdrawing=self.IsShipWithdrawing and self:IsShipWithdrawing(ship)
    local primaryHeld=not withdrawing and ((controls.PrimaryCount or 0) > 0 or self:IsPilotControlDown(buttons,"FIRE_PRIMARY"))
    local secondaryHeld=not withdrawing and ((controls.SecondaryCount or 0) > 0 or self:IsPilotControlDown(buttons,"FIRE_SECONDARY"))
    if primaryHeld then
        ship.PrimaryTriggerDown = true
        ship:firePrimary()
    else
        ship.PrimaryTriggerDown = false
    end

    if secondaryHeld then ship:fireSecondary() end
    self:UpdatePilotTurretFire(primaryHeld, secondaryHeld)

    self:MirrorPilotTelemetryToObserver(ship, observer)
    self.PilotButtons = buttons
end
