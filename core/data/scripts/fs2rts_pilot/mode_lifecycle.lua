-- Pilot mode lifecycle: start, enter, exit and toggle.
local _shared = require "fs2rts_pilot.common"
local RTS, shipAlive, shipValid, copyVec = _shared.RTS, _shared.shipAlive, _shared.shipValid, _shared.copyVec

function RTS:StartPilotMode(ship)
    if self.GameStatus ~= "ACTIVE" then return false end
    if not self:IsPilotableShip(ship) or not shipAlive(ship) or ship:isDying() then
        self:SetStatus("PILOT: select a friendly fighter, bomber, or capital ship", 3)
        return false
    end

    local signature=ship:getSignature()
    local withdrawal=self.Withdrawals and self.Withdrawals[signature]
    if withdrawal and (withdrawal.inCorridor or withdrawal.departureStarted) then
        self:SetStatus("PILOT: cannot take control after extraction begins",3)
        return false
    end
    if self.FleetProtection then self.FleetProtection[signature]=nil end

    if self.FollowSignature ~= nil then self:ExitFollowMode() end
    self:OnPilotCommMenuClosed()

    self.PendingPilotEject=false; self.PendingPilotEjectRemaining=nil; self.PendingPilotEjectPosition=nil; self.PendingPilotEjectOrientation=nil; self.PendingPilotEjectRadius=nil
    self.PilotDeathRestoreTimeScale=nil; self.PilotDeathRestoreLastNonZeroTimeScale=nil
    self.PossessedSignature = signature
    if self.RecordPilotTime then self:RecordPilotTime(ship,mn.getMissionTime(),true) end
    self.PilotShieldMirrorSnapshot=nil
    self.PilotWeaponEnergyMirrorSnapshot=nil
    if self.NewUnitPopup then self.NewUnitPopup.expiresAt=nil end
    -- Possession supersedes service without restoring its parked order now.
    -- Otherwise service keeps consuming slots and CP during direct control.
    if self.FleetServices then self.FleetServices[signature]=nil end
    self:SetShipCommandDiscipline(ship,false)
    self:SetShipTurretLock(ship,withdrawal~=nil)
    self:InitializePilotTurretGroups(ship)
    self.Selected = { signature }
    self.PilotPreviousUserOrder = self.UserOrders[signature]
    local objective=self.AIOrderState[signature]
    self.PilotAIObjective=objective and {label=objective.label,mission=objective.mission,reason=objective.reason,
        group=objective.group,targetSignature=objective.targetSignature,destination=objective.destination,
        operationPhase=objective.operationPhase,posture=objective.posture} or nil
    self.UserOrders[signature] = { kind = "pilot" }
    self.PolicyApplied[signature] = nil
    -- A leftover Auto Mode objective would let OnShipDeath clearOrders() this
    -- craft when that old target dies, stripping PLAY_DEAD mid-flight.
    self.AIOrderState[signature] = nil
    self.KeyDown = {}
    self.CtrlDown = false
    self.ShiftDown = false
    self.LeftDrag = nil
    self.MiddleDrag = nil
    self.MapDrag = nil
    self.RightDrag = nil
    self.MovePreview = nil
    self.PilotButtons = { 0, 0, 0, 0 }

    -- Stop the fighter AI from competing with the pilot. Lua maneuver overrides
    -- still drive the craft and direct fire calls still use its real weapons.
    ship:clearOrders()
    -- Turrets are driven explicitly via rotateTurret/fireWeapon. PLAY_DEAD
    -- disables ai_still's turn toward its cached heading, so native steering
    -- cannot counteract the pilot's rotation before maneuver overrides apply.
    ship:giveOrder(ORDER_PLAY_DEAD,nil,nil,2.0)

    local observer = self:GetObserver()
    if shipValid(observer) then
        if self.ObserverOriginalClassName == nil then self.ObserverOriginalClassName = observer.Class.Name end
        self.PilotProxyRecharge={shield=observer.ShieldRegenRate,weapon=observer.WeaponRegenRate}
        observer.Class = ship.Class
        -- Only the real hull regenerates. Proxy deltas then represent native
        -- shield/weapon transfers instead of a second copy of passive recharge.
        observer.ShieldRegenRate=0; observer.WeaponRegenRate=0
        observer:EtsSetIndexes(ship.EtsEngineIndex,ship.EtsShieldIndex,ship.EtsWeaponIndex)
        -- Primaries fire on the hull. Native player secondaries stay on the
        -- proxy so FSO owns target locks, cooldowns and queued swarm launches.
        observer:setFlag(true,"primaries-locked")
        observer:setFlag(self.Paused or withdrawal~=nil,"secondaries-locked")
        self:DisarmObserverTurrets(observer)
        self:MirrorPilotTelemetryToObserver(ship, observer)
    end
    local nativeWingLabel,nativeWingError=self:JoinPilotNativeWing(ship)

    -- In pilot mode let FSO run its normal player HUD/targeting/view system on
    -- the hidden proxy. The proxy is then slaved to the possessed fighter each
    -- frame, so this feels like normal FreeSpace flight instead of a camera mod.
    self:MirrorPilotTelemetryToObserver(ship, observer)
    mn.runSEXP("(player-not-use-ai)")
    self:SetPilotInputMode()
    gr.setCamera()
    self.PilotCamera = nil

    io.MouseControlStatus = true
    io.setCursorHidden(true)
    local turretHint=""
    if self.PilotTurretGroups~=nil and #self.PilotTurretGroups>0 then
        turretHint=" | "..self.Config.Pilot.TurretGroupPreviousKey.."/"..self.Config.Pilot.TurretGroupNextKey.." weapons"
            .." | "..self.Config.Pilot.TurretGroupToggleKey.." all"
            .." | "..self.Config.Pilot.TurretSubsystemPreviousKey.."/"..self.Config.Pilot.TurretSubsystemNextKey.." subsystem"
    end
    self:SetPilotWeaponsHUD(self.PilotTurretGroups~=nil and #self.PilotTurretGroups>0)
    self:SetPilotWeaponCycleHooks(true)
    self:UpdatePilotDirectives()
    self:SetStatus("PILOT: " .. ship.Name .. turretHint
        .. (nativeWingLabel and (" | "..nativeWingLabel) or "")
        .. (nativeWingError and (" | "..nativeWingError) or "")
        .. " | " .. self.Config.Pilot.ToggleKey .. " returns to RTS", 4)
    self:Log("Pilot possession entered: " .. ship.Name)
    return true
end

function RTS:EnterPilotFromSelection()
    local candidate=nil
    if self.PrimarySelectionSignature~=nil then
        local ship=self:FindShipBySignature(self.PrimarySelectionSignature)
        if self:IsPilotableShip(ship) then candidate=ship end
    end
    if candidate==nil then
        for _,ship in ipairs(self:GetSelectedShips()) do if self:IsPilotableShip(ship) then candidate=ship; break end end
    end
    if candidate==nil then
        self:SetStatus("PILOT: select a friendly fighter or bomber",3)
        return false
    end
    return self:StartPilotMode(candidate)
end

function RTS:ExitPilotMode(message, lost)
    if self.PossessedSignature == nil then return end
    self:UpdatePilotDirectives(true); self.PilotAIObjective=nil; self.PilotSuggestedTarget=nil; self.PilotSuggestedAt=nil; self.PilotCommWarningUntil=nil
    self:RestorePilotCommOrders()
    self:SetPilotWeaponCycleHooks(false)
    local wingRestored,wingError=self:LeavePilotNativeWing()
    local restoreScale=self.PilotDeathRestoreTimeScale
    local restoreLastScale=self.PilotDeathRestoreLastNonZeroTimeScale
    if restoreScale~=nil then
        if self.Paused then self.PausedTimeScale=restoreScale
        else self:SetTimeScale(restoreScale) end
        if restoreLastScale~=nil then self.LastNonZeroTimeScale=restoreLastScale end
    end
    self.PilotDeathRestoreTimeScale=nil; self.PilotDeathRestoreLastNonZeroTimeScale=nil
    local oldSignature=self.PossessedSignature
    local ship=self:GetPossessedShip()
    local observer=self:GetObserver()
    -- Native fire can run after the last Lua mirror and before this exit.
    if shipValid(ship) and shipValid(observer) then ship.SecondaryBanks=observer.SecondaryBanks end
    if self.RecordPilotTime then self:RecordPilotTime(ship,mn.getMissionTime(),false) end
    self:RestorePilotTurretGroups()
    local lastPosition=self.PendingPilotEjectPosition
    if shipValid(ship) then
        if not self.PendingPilotEject then lastPosition=copyVec(ship.Position) end
        ship.PrimaryTriggerDown=false; ship.Physics.AfterburnerActive=false
        -- Release the never-expiring maneuver override (a call that applies no
        -- axes just resets the override flags) so the AI can fly it again.
        ship:doManeuver(1,0,0,0,false,0,0,0,false,0)
    end
    self.PossessedSignature=nil; self.PilotCamera=nil; self.PilotButtons={0,0,0,0}; self.KeyDown={}; self.CtrlDown=false; self.ShiftDown=false; self.AltDown=false
    self:OnPilotCommMenuClosed()
    self.PilotShieldMirrorSnapshot=nil
    self.PilotWeaponEnergyMirrorSnapshot=nil
    mn.runSEXP("(player-use-ai)")
    self:SetRTSInputMode(); self:RestoreObserverClass(); self:RestoreObserverHome(); self:DisarmObserverWeapons()
    if shipValid(observer) and self.PilotProxyRecharge then
        observer.ShieldRegenRate=self.PilotProxyRecharge.shield; observer.WeaponRegenRate=self.PilotProxyRecharge.weapon
    end
    self.PilotProxyRecharge=nil
    io.MouseControlStatus=false; io.setCursorHidden(false); pcall(function() io.flushMouse() end); pcall(function() if self.ControlInfo~=nil then self.ControlInfo.clearLuaButtonInfo() end end)
    if lastPosition~=nil then self.CameraFocus=lastPosition end
    gr.setCamera(self.Camera); self:UpdateCameraTransform()
    if lost then
        self.Selected={}; self.PrimarySelectionSignature=nil; self.UserOrders[oldSignature]=nil; self.PolicyApplied[oldSignature]=nil
    elseif shipValid(ship) then
        self.Selected={oldSignature}; self.PrimarySelectionSignature=oldSignature; self.UserOrders[oldSignature]=self.PilotPreviousUserOrder; self.PolicyApplied[oldSignature]=nil
        if self.PilotPreviousUserOrder~=nil then self:ReissueUserOrder(ship,self.PilotPreviousUserOrder)
        else self:ReturnToDefaultControl(ship) end
    end
    self.PendingPilotEject=false; self.PendingPilotEjectRemaining=nil; self.PendingPilotEjectPosition=nil; self.PendingPilotEjectOrientation=nil; self.PendingPilotEjectRadius=nil; self.PilotPreviousUserOrder=nil
    if message then self:SetStatus(message..(not wingRestored and (" | "..tostring(wingError)) or ""),4)
    elseif not wingRestored then self:SetStatus(wingError,4) end
    self:Log("Pilot possession exited"..(lost and " after craft loss" or ""))
end

function RTS:TogglePilotMode()
    if self.PossessedSignature ~= nil then
        if self.PendingPilotEject then
            local remaining=math.max(0,self.PendingPilotEjectRemaining or 0)
            self:SetStatus(string.format("CRAFT DESTROYED - returning to RTS in %.1fs",remaining),1)
            return
        end
        self:ExitPilotMode("RTS command restored", false)
    else
        self:EnterPilotFromSelection()
    end
end
