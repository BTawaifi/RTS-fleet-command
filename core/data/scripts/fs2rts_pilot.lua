-- Pilot (possession) mode.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

-- FSO has no "press the trigger" property on a subsystem. PrimaryTriggerDown
-- is a SHIP property (ship.cpp), and l_Subsystem exposes neither firePrimary
-- nor fireSecondaries - calling either raised "attempt to call a nil value"
-- and the surrounding pcall swallowed it, so turret fire silently did nothing.
-- The one real subsystem trigger is fireWeapon(slot), whose slot is a flat
-- index over the turret's own weapon list: primaries occupy slots 1..3 and
-- secondaries 4..7, because the engine splits the list at
-- MAX_SHIP_PRIMARY_BANKS (=3, code/globalincs/globals.h).
-- Firing is one-shot per call, so a held trigger re-issues every frame.
local MAX_SHIP_PRIMARY_BANKS = 3

local function fireSlot(subsystem, slot)
    local ok = pcall(function() subsystem:fireWeapon(slot, 100, nil) end)
    return ok == true
end

local function turretTrigger(subsystem, down)
    if not down or not subsystem:isValid() then return end
    local banks = subsystem.PrimaryBanks
    if banks == nil then return end
    for slot = 1, #banks do fireSlot(subsystem, slot) end
end

local function turretSecondaries(subsystem)
    if not subsystem:isValid() then return end
    local banks = subsystem.SecondaryBanks
    if banks == nil then return end
    for slot = 1, #banks do fireSlot(subsystem, MAX_SHIP_PRIMARY_BANKS + slot) end
end

-- Any friendly hull can be possessed. The old prefix allow-list (GTF/GTC/SD/...)
-- silently excluded every class it did not name, including user-made and
-- mission-specific hulls, so those ships could never be flown. Static defenses
-- are excluded because they are immobile installations, and the capital
-- turret-group layer keys off IsPilotableCapital, not off this gate.
function RTS:IsPilotableShip(ship)
    if not self:IsFriendly(ship) then return false end
    if ship.Name == self.Config.CarrierShip or ship.Name == self.Config.ObserverShip then return false end
    if ship.Name == self.Config.EnemyCommandShip or ship.Name == self.Config.ThirdCommandShip then return false end
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
    self.PilotTurretGroups=nil; self.PilotTurretGroupIndex=nil; self.PilotTurretAppliedGroupIndex=nil
    self.PilotTurretLastGroupIndex=nil; self.PilotTurretFiring=false; self.PilotTurretFireLatched=false; self.PilotTurretFireStatusAt=nil
    self.PilotTargetSubsystemIndex=1; self.PilotTargetSubsystemCount=0
    if not self:IsPilotableCapital(ship) then return end
    local byWeapons={}
    for i=1,#ship do
        local subsystem=ship[i]
        if subsystem and subsystem:isValid() and subsystem:isTurret() then
            local weapons={}
            for _,banks in ipairs({subsystem.PrimaryBanks or {},subsystem.SecondaryBanks or {}}) do
                for b=1,#banks do
                    local bank=banks[b]; local weapon=bank and bank:isValid() and bank.WeaponClass
                    if weapon and weapon:isValid() then weapons[#weapons+1]=weapon.Name end
                end
            end
            table.sort(weapons)
            if #weapons>0 then
                local label=table.concat(weapons," + ")
                local group=byWeapons[label]
                if group==nil then group={label=label,turrets={}}; byWeapons[label]=group end
                group.turrets[#group.turrets+1]={subsystem=subsystem,wasLocked=subsystem.TurretLocked==true}
            end
        end
    end
    local groups={}; for _,group in pairs(byWeapons) do groups[#groups+1]=group end
    table.sort(groups,function(a,b) return a.label<b.label end)
    self.PilotTurretGroups=groups; self.PilotTurretGroupIndex=#groups>0 and 1 or nil
    self:ApplyPilotTurretGroup(ship.Target)
end

-- 0 means "the whole target ship"; 1..count select one of its subsystems.
function RTS:ResolvePilotTargetSubsystemIndex(target)
    local count=objectValid(target) and #target or 0
    self.PilotTargetSubsystemCount=count
    local index=self.PilotTargetSubsystemIndex or 0
    if count<2 or index<1 or index>count then return 0 end
    return index
end

function RTS:InvalidatePilotTurretTargets()
    for _,group in ipairs(self.PilotTurretGroups or {}) do group.targetAssigned=nil end
end

function RTS:ApplyPilotTurretGroup(target)
    local groups=self.PilotTurretGroups
    if groups==nil then return end
    local ship=self:GetPossessedShip(); local targetSignature=shipValid(target) and self:IsPlayerEnemy(target) and target:getSignature() or nil
    local groupIndex=self.PilotTurretGroupIndex
    if self.PilotTurretAppliedGroupIndex~=groupIndex then
        for i,group in ipairs(groups) do
            for _,entry in ipairs(group.turrets) do
                local subsystem=entry.subsystem
                if subsystem:isValid() then
                    local active=(groupIndex==nil or i==groupIndex) and not entry.wasLocked
                    subsystem:targetingOverride(true)
                    subsystem.TurretLocked=not active
                end
            end
        end
        self.PilotTurretAppliedGroupIndex=groupIndex
    end
    local subsystemIndex=self:ResolvePilotTargetSubsystemIndex(target)
    for i,group in ipairs(groups) do
        if groupIndex==nil or i==groupIndex then
            if (not group.targetAssigned or group.targetSignature~=targetSignature or group.targetSubsystemIndex~=subsystemIndex) then
                -- Subsystem.Target is declared ADE_VIRTVAR(Target, l_Subsystem,
                -- "object", ...) and reads its argument with l_Object.GetPtr, so
                -- it accepts an OBJECT and nothing else. Assigning a subsystem to
                -- it raises "Argument 2 is the wrong type of userdata; 'subsystem'
                -- given, but 'object' expected", which aborts StartPilotMode
                -- mid-initialisation and is why capitals could not be flown at
                -- all. Hitting one subsystem of a capital is simply not
                -- expressible through this API, so the index stays a targeting
                -- preference and the object is what the turrets are given.
                local newTarget=nil
                if targetSignature~=nil and objectValid(target) then newTarget=target end
                for _,entry in ipairs(group.turrets) do
                    if entry.subsystem:isValid() and not entry.wasLocked then entry.subsystem.Target=newTarget end
                end
                group.targetSignature=targetSignature; group.targetSubsystemIndex=subsystemIndex; group.targetAssigned=true
            end
        end
    end
end

function RTS:CyclePilotTurretGroup(delta)
    local groups=self.PilotTurretGroups
    if groups==nil or #groups<2 then return false end
    local index=self.PilotTurretGroupIndex or self.PilotTurretLastGroupIndex or 1
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
    local count=objectValid(target) and #target or 0
    self.PilotTargetSubsystemCount=count
    if count<2 then self:SetStatus("TURRET AIM: TARGET HAS NO SUBSYSTEMS",1.5); return false end
    local index=(self.PilotTargetSubsystemIndex or 0)+delta
    if index<0 then index=count elseif index>count then index=0 end
    self.PilotTargetSubsystemIndex=index
    self:InvalidatePilotTurretTargets()
    self:ApplyPilotTurretGroup(target)
    self:SetStatus("TURRET AIM: "..self:GetPilotTargetSubsystemLabel(),1.5)
    return true
end

function RTS:TogglePilotTargetSubsystem()
    local count=self.PilotTargetSubsystemCount or 0
    if count<2 then return self:CyclePilotTargetSubsystem(1) end
    local index=self.PilotTargetSubsystemIndex or 0
    return self:CyclePilotTargetSubsystem(index>0 and -index or 1)
end

function RTS:GetPilotTargetSubsystemLabel()
    local count=self.PilotTargetSubsystemCount or 0
    if count<2 then return "" end
    local index=self.PilotTargetSubsystemIndex or 0
    if index<1 or index>count then return "WHOLE SHIP ("..count..")" end
    return "SUBSYSTEM "..index.."/"..count
end

-- Drives the active turret group directly: a capital keeps its weapons in turret
-- subsystems, so ship:firePrimary()/fireSecondary() reach nothing on one.
function RTS:UpdatePilotTurretFire(primaryDown, secondaryDown)
    local groups=self.PilotTurretGroups
    if groups==nil or #groups==0 then
        -- All three are reset together here, as at :46, :236 and
        -- fs2rts_factions.lua:715. Clearing only the latch left
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
    for i,group in ipairs(groups) do
        local live=groupIndex==nil or i==groupIndex
        for _,entry in ipairs(group.turrets) do
            local fire=live and engaged and entry.wasLocked~=true
            pcall(turretTrigger,entry.subsystem,fire)
            if fire and secondaryDown then pcall(turretSecondaries,entry.subsystem) end
        end
    end
    self.PilotTurretFiring=engaged
    if engaged then
        local now=self:UINow()
        if not previous or self.PilotTurretFireStatusAt==nil or (now-self.PilotTurretFireStatusAt)>=0.5 then
            self.PilotTurretFireStatusAt=now
            self:SetStatus(self.Config.Pilot.TurretFireStatusLine or "MANUAL TURRET FIRE ACTIVE",0.6)
        end
    else
        self.PilotTurretFireStatusAt=nil
    end
end

function RTS:RestorePilotTurretGroups()
    for _,group in ipairs(self.PilotTurretGroups or {}) do
        for _,entry in ipairs(group.turrets) do
            local subsystem=entry.subsystem
            if subsystem:isValid() then
                pcall(turretTrigger,subsystem,false)
                subsystem:targetingOverride(false)
                subsystem.TurretLocked=entry.wasLocked
            end
        end
    end
    self.PilotTurretGroups=nil; self.PilotTurretGroupIndex=nil; self.PilotTurretAppliedGroupIndex=nil; self.PilotTurretLastGroupIndex=nil
    self.PilotTurretFiring=false; self.PilotTurretFireLatched=false; self.PilotTurretFireStatusAt=nil
    self.PilotTargetSubsystemIndex=1; self.PilotTargetSubsystemCount=0
end

function RTS:GetPossessedShip()
    if self.PossessedSignature == nil then return nil end
    return self:FindShipBySignature(self.PossessedSignature)
end

function RTS:ReadPilotButtons()
    if self.ControlInfo == nil then return { 0, 0, 0, 0 } end
    local b0, b1, b2, b3 = self.ControlInfo.pollAllButtons()
    return { b0 or 0, b1 or 0, b2 or 0, b3 or 0 }
end

function RTS:IsPilotControlDown(buttons, name)
    if self.ControlInfo == nil or buttons == nil then return false end
    local index = self.ControlInfo.getButtonControlNumber(name)
    if index == nil or index < 0 then return false end
    local word = math.floor(index / 32) + 1
    local bitIndex = index % 32
    return bit.checkBit(buttons[word] or 0, bitIndex)
end

function RTS:IsPilotControlPressed(buttons, name)
    return self:IsPilotControlDown(buttons, name) and not self:IsPilotControlDown(self.PilotButtons, name)
end

function RTS:RestoreObserverHome()
    local observer = self:GetObserver()
    if not shipValid(observer) then return end
    if self.ObserverHomePosition ~= nil then observer.Position = copyVec(self.ObserverHomePosition) end
    if self.ObserverHomeOrientation ~= nil then observer.Orientation = self.ObserverHomeOrientation:copy() end
end

function RTS:CopyArmedBankState(sourceBanks, targetBanks)
    if sourceBanks == nil or targetBanks == nil then return end
    local count = math.min(#sourceBanks, #targetBanks)
    for i = 1, count do
        if sourceBanks[i].Armed then
            targetBanks[i].Armed = true
            break
        end
    end
end

function RTS:MirrorPilotTelemetryToObserver(ship, observer)
    if not shipValid(ship) or not shipValid(observer) then return end

    observer.Position = copyVec(ship.Position)
    observer.Orientation = ship.Orientation:copy()
    observer.Physics.Velocity = ship.Physics.Velocity

    observer.HitpointsLeft = math.max(1, ship.HitpointsLeft)
    if observer.Shields ~= nil and ship.Shields ~= nil then
        observer.Shields.CombinedLeft = ship.Shields.CombinedLeft
    end
    observer.WeaponEnergyLeft = ship.WeaponEnergyLeft
    observer.AfterburnerFuelLeft = ship.AfterburnerFuelLeft
    observer.CountermeasuresLeft = ship.CountermeasuresLeft

    -- Copy the actual possessed craft loadout into the formal player proxy so the
    -- native FreeSpace HUD, reticle, missile display, ammo counts and bank names
    -- are based on the craft the player is really flying.
    observer.PrimaryBanks = ship.PrimaryBanks
    observer.SecondaryBanks = ship.SecondaryBanks

    local target = ship.Target
    if objectValid(target) then observer.Target = target else observer.Target = nil end
end

function RTS:RestoreObserverClass()
    local observer = self:GetObserver()
    if not shipValid(observer) then return end
    if self.ObserverOriginalClassName ~= nil then
        local original = tb.ShipClasses[self.ObserverOriginalClassName]
        if original ~= nil and original:isValid() then observer.Class = original end
    end
end

function RTS:StartPilotMode(ship)
    if self.GameStatus ~= "ACTIVE" then return false end
    if not self:IsPilotableShip(ship) or not shipAlive(ship) or ship:isDying() then
        self:SetStatus("PILOT: select a friendly fighter, bomber, or capital ship", 3)
        return false
    end

    if self.FollowSignature ~= nil then self:ExitFollowMode() end

    local signature = ship:getSignature()
    self.PendingPilotEject=false; self.PendingPilotEjectRemaining=nil; self.PendingPilotEjectPosition=nil; self.PendingPilotEjectOrientation=nil; self.PendingPilotEjectRadius=nil
    self.PilotDeathRestoreTimeScale=nil; self.PilotDeathRestoreLastNonZeroTimeScale=nil
    self.PossessedSignature = signature
    self:InitializePilotTurretGroups(ship)
    self.Selected = { signature }
    self.PilotPreviousUserOrder = self.UserOrders[signature]
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
    ship:giveOrder(ORDER_PLAY_DEAD, nil, nil, 2.0)

    local observer = self:GetObserver()
    if shipValid(observer) then
        if self.ObserverOriginalClassName == nil then self.ObserverOriginalClassName = observer.Class.Name end
        observer.Class = ship.Class
        -- Keep the proxy's own weapons locked: it is Player_obj, so the engine
        -- would fire its mirrored banks from the trigger as well, doubling every
        -- shot from inside the possessed hull. UpdatePilotMode fires the real
        -- craft from the same control counts, which the lock does not touch.
        observer:setFlag(true,"primaries-locked","secondaries-locked")
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
    local wingRestored,wingError=self:LeavePilotNativeWing()
    local restoreScale=self.PilotDeathRestoreTimeScale
    local restoreLastScale=self.PilotDeathRestoreLastNonZeroTimeScale
    if restoreScale~=nil then
        self:SetTimeScale(restoreScale)
        if restoreLastScale~=nil then self.LastNonZeroTimeScale=restoreLastScale end
    end
    self.PilotDeathRestoreTimeScale=nil; self.PilotDeathRestoreLastNonZeroTimeScale=nil
    local oldSignature=self.PossessedSignature
    local ship=self:GetPossessedShip()
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
    mn.runSEXP("(player-use-ai)")
    self:SetRTSInputMode(); self:RestoreObserverClass(); self:RestoreObserverHome(); self:DisarmObserverWeapons()
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
    elseif not objectValid(target) then
        ship.Target = nil
    end
    self:CopyArmedBankState(observer.PrimaryBanks, ship.PrimaryBanks)
    self:CopyArmedBankState(observer.SecondaryBanks, ship.SecondaryBanks)
    ship.PrimaryBanks.Linked = observer.PrimaryBanks.Linked
    ship.SecondaryBanks.DualFire = observer.SecondaryBanks.DualFire
    if self.PilotTurretGroups~=nil then self:ApplyPilotTurretGroup(ship.Target) end

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

    local primaryHeld=(controls.PrimaryCount or 0) > 0
    local secondaryHeld=(controls.SecondaryCount or 0) > 0
    if primaryHeld then
        ship.PrimaryTriggerDown = true
        ship:firePrimary()
    else
        ship.PrimaryTriggerDown = false
    end

    if secondaryHeld then ship:fireSecondary() end
    self:UpdatePilotTurretFire(primaryHeld, secondaryHeld)
    if (controls.CountermeasureCount or 0) > 0 or self:IsPilotControlPressed(buttons, "LAUNCH_COUNTERMEASURE") then
        ship:fireCountermeasure()
    end

    self:MirrorPilotTelemetryToObserver(ship, observer)
    self.PilotButtons = buttons
end
