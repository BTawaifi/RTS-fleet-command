-- Keyboard input and key overrides.
local _shared = require "fs2rts_input.common"
local RTS, lower, shipValid = _shared.RTS, _shared.lower, _shared.shipValid

function RTS:OnKeyPressed(key,rawKey)
    if not self.Enabled or key==nil then return end
    if self.ExitMenuActive then
        if rawKey=='Esc' or rawKey=='Escape' or key=='Esc' or key=='Escape' then
            self:HandleExitMenuAction('resume'); self.EscapeKeyOverride=true
        end
        return
    end
    if key==(self.Config.HotkeyHintsKey or 'F10') or rawKey==(self.Config.HotkeyHintsKey or 'F10') then
        if not self.HotkeyHintsHeld then
            self.ShowHotkeyHints=self.ShowHotkeyHints==false
            self:SetStatus(self.ShowHotkeyHints and 'Control hints shown' or ('Control hints hidden // '..(self.Config.HotkeyHintsKey or 'F10'):gsub('-','+')..' to show'),2)
        end
        self.HotkeyHintsHeld=true
        return
    end
    if key==(self.Config.FleetCostToggleKey or 'F9') or rawKey==(self.Config.FleetCostToggleKey or 'F9') then
        if not self.FleetCostKeyHeld then
            self.ShowFleetCost=self.ShowFleetCost~=true
            self:SetStatus('Crew cost overlay '..(self.ShowFleetCost and 'shown' or 'hidden')..' // '..(self.Config.FleetCostToggleKey or 'F9'),2)
        end
        self.FleetCostKeyHeld=true; return
    end
    local rawEarly=rawKey or key; rawEarly=string.gsub(rawEarly,"^Shift%-",""); rawEarly=string.gsub(rawEarly,"^Ctrl%-",""); rawEarly=string.gsub(rawEarly,"^Alt%-","")
    local pauseControl=(type(controls)=="table" and controls.Pause) or "__no_pause_control__"
    if (rawEarly=="Pause" or rawEarly=="Break" or rawEarly==pauseControl)
        and not string.find(key,"Alt",1,true) then
        if not (self.PostBattleActive or self.SetupActive or self.CinematicActive) then self:TogglePause() end
        return
    end
    if rawEarly=="Esc" or rawEarly=="Escape" then
        if string.find(key,"Alt",1,true) then self.EscapeKeyOverride=false; return end
        local canHandle=not (self.SetupActive or self.CinematicActive or self.PostBattleActive)
        self.EscapeKeyOverride=canHandle
        if canHandle then
            if self.PossessedSignature~=nil then
                if self.Paused then self:SetPaused(false) end
                self:TogglePilotMode()
            else self:OpenExitMenu() end
        end
        return
    end
    if self.CinematicActive then
        local cfg=self.Config.Cinematic or {}
        if cfg.RestartShotKey~=nil and rawEarly==cfg.RestartShotKey then self:CinematicRestartShot(); return end
        if cfg.NextShotKey~=nil and rawEarly==cfg.NextShotKey then self:CinematicNextShot(1); return end
        if cfg.PreviousShotKey~=nil and rawEarly==cfg.PreviousShotKey then self:CinematicNextShot(-1); return end
        if cfg.AllowSkip~=false and cfg.SkipOnAnyInput~=false then self:EndIntroCinematic(true) end
        return
    end
    if self.PostBattleActive then return end
    if self.SetupActive then return end
    if rawEarly=="Space" or rawEarly=="Spacebar" then
        if self.PossessedSignature~=nil then return end
        if not string.find(key,"Ctrl",1,true) and not string.find(key,"Alt",1,true)
            and not string.find(key,"Shift",1,true) then
            self:TogglePause(); return
        end
    end
    if rawEarly=="=" or rawEarly=="Pad +" then self:StepTimeScale(1); return end
    if rawEarly=="-" or rawEarly=="Pad -" then self:StepTimeScale(-1); return end
    local speed=string.find(key,'Alt',1,true) and ({['1']=1,['2']=2,['3']=4,['4']=8,['0']=16})[rawEarly]
    if speed then self:SetPaused(false); self:SetTimeScale(speed); self:SetStatus('Game speed: '..speed..'x',1.2); return end
    if self.Paused then
        local c=self.Config.HomeworldControls or {}
        if self.PossessedSignature~=nil then return end
        if rawEarly==(c.Focus or "F") or (string.find(key,"Ctrl",1,true) and (rawEarly=="Space" or rawEarly=="Spacebar")) then
            self:ExitFollowMode(); self:FocusOnSelection(); return
        elseif rawEarly==(c.FocusBase or "H") then
            self:ExitFollowMode(); self:FocusOnBase(); return
        elseif rawEarly==(c.Chase or "B") then self:ToggleChaseOnSelection(); return
        end
        if not (({['1']=true,['2']=true,['3']=true,['4']=true})[rawEarly] or (rawEarly=='0' and string.find(key,'Alt',1,true))) then return end
    end
    if self.BattleCamActive then if rawEarly==((self.Config.HomeworldControls or {}).Cinematic or "C") then if string.find(key,"Shift",1,true) then self:ToggleFreeCam() else self:StopBattleCam() end end; return end
    if key==self.Config.Pilot.ToggleKey then self:TogglePilotMode(); return end
    if self.PossessedSignature~=nil then
        if self.PilotTurretGroups and #self.PilotTurretGroups>1 and rawEarly==self.Config.Pilot.TurretGroupPreviousKey then self:CyclePilotTurretGroup(-1)
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>1 and rawEarly==self.Config.Pilot.TurretGroupNextKey then self:CyclePilotTurretGroup(1)
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>1 and rawEarly==self.Config.Pilot.TurretGroupToggleKey then self:TogglePilotTurretGroup()
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>0 and rawEarly==self.Config.Pilot.TurretSubsystemKey then self:TogglePilotTargetSubsystem()
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>0 and rawEarly==self.Config.Pilot.TurretSubsystemPreviousKey then self:CyclePilotTargetSubsystem(-1)
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>0 and rawEarly==self.Config.Pilot.TurretSubsystemNextKey then self:CyclePilotTargetSubsystem(1) end
        return
    end
    local lower=string.lower(tostring(key)); if string.find(lower,"shift",1,true) then self.ShiftDown=true end; if string.find(lower,"ctrl",1,true) then self.CtrlDown=true end; if string.find(lower,"alt",1,true) then self.AltDown=true end
    local raw=rawEarly; self.KeyDown[raw]=true; local controls=self.Config.HomeworldControls or {}
    if self.FollowSignature~=nil and (raw==(controls.PanForward or "W") or raw==(controls.PanBackward or "S") or raw==(controls.PanLeft or "A") or raw==(controls.PanRight or "D") or raw=="Up" or raw=="Down" or raw=="Left" or raw=="Right") then self:ExitFollowMode("Tactical camera") end

    local wingIndex=nil
    local wingKeys={controls.Wing1 or "1",controls.Wing2 or "2",controls.Wing3 or "3",controls.Wing4 or "4"}
    for i,wkey in ipairs(wingKeys) do if raw==wkey then wingIndex=i break end end
    if wingIndex and not string.find(key,'Alt',1,true) then
        if string.find(key,'Shift',1,true) then self:AssignControlGroup(wingIndex) else self:RecallControlGroup(wingIndex) end
        return
    end

    if raw=="=" or raw=="Pad +" then self:StepTimeScale(1)
    elseif self.CtrlDown and (raw=="Space" or raw=="Spacebar") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self:FocusOnSelection()
    elseif raw==(controls.SelectAll or "L") then self:SelectAll()
    elseif raw==(controls.Stop or "R") then self:HoldSelected()
    elseif raw==(controls.Engage or "T") then self:EngageSelected()
    elseif raw=="=" or raw=="Pad +" then self:StepTimeScale(1)
    elseif raw=="-" or raw=="Pad -" then self:StepTimeScale(-1)
    elseif raw==(controls.MuteMusic or "N") then self:ToggleMusicMute()
    elseif raw==(controls.Release or "G") then self:ReleaseSelected()
    elseif raw==(controls.ArmMove or "M") then self:ArmCommand("move")
    elseif raw==(controls.ArmAttack or "K") then self:ArmCommand("attack")
    elseif raw==(controls.Focus or "F") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self:FocusOnSelection()
    elseif raw==(controls.FocusBase or "H") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self:FocusOnBase()
    elseif raw==(controls.Chase or "B") then self:ToggleChaseOnSelection()
    elseif raw==(controls.ZoomFar or "Q") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self.CameraDistance=self.Config.Camera.MaxDistance; self:UpdateCameraTransform()
    elseif raw==(controls.ZoomNear or "E") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self.CameraDistance=self.Config.Camera.MinDistance; self:UpdateCameraTransform()
    elseif raw==(controls.HoldPolicy or "J") then self:SetGlobalPolicy("HOLD")
    elseif raw==(controls.PassivePolicy or "Z") then self:SetGlobalPolicy("RETREAT")
    elseif raw==(controls.DefensivePolicy or "X") then self:SetGlobalPolicy("STANDOFF")
    elseif raw==(controls.AggressivePolicy or "V") then self:SetGlobalPolicy("ENGAGE")
    elseif raw==(controls.Cinematic or "C") then if string.find(key,"Shift",1,true) then self:ToggleFreeCam() else self:ToggleBattleCam() end
    end
end

-- Dedicated chase-mode shortcut. Toggles the follow camera on the ship under the
-- cursor, falling back to the primary selection when the cursor is on empty
-- space, so it is a real key rather than only Alt+double-click.
function RTS:ToggleChaseOnSelection()
    if self.FollowSignature~=nil then self:ExitFollowMode("Tactical camera") return end
    local target=self:GetShipAtScreen(io.getMouseX(),io.getMouseY(),true,true)
    if target==nil then target=self:GetPrimarySelectedShip() end
    if not shipValid(target) then self:SetStatus("Nothing to chase - select a ship first",1.4) return end
    self.Selected={target:getSignature()}; self.PrimarySelectionSignature=target:getSignature()
    self:StartFollowMode(target)
end

function RTS:OnKeyReleased(key,rawKey)
    if not self.Enabled or key==nil then return end
    -- The modifier may be released before F10, and pilot mode normally exits
    -- this handler early. Release the physical-key latch before either gate.
    local hintKey=(self.Config.HotkeyHintsKey or 'F10'):match('([^%-]+)$')
    if tostring(rawKey or key):match('([^%-]+)$')==(self.Config.FleetCostToggleKey or 'F9') then self.FleetCostKeyHeld=false end
    if tostring(rawKey or key):match('([^%-]+)$')==hintKey then self.HotkeyHintsHeld=false end
    if self.PossessedSignature~=nil then return end
    local raw=rawKey or key; raw=string.gsub(raw,"^Shift%-",""); raw=string.gsub(raw,"^Ctrl%-",""); raw=string.gsub(raw,"^Alt%-",""); self.KeyDown[raw]=nil; self.FastKeyDown[raw]=nil
    local modifier=string.lower(tostring(rawKey or key))
    -- Modifier state is owned by the modifier keys alone. Clearing Shift when a
    -- pan key comes up dropped the slow-pan modifier mid-gesture while the
    -- Shift key was still physically held.
    if modifier=="shift" or modifier=="left shift" or modifier=="right shift" then self.ShiftDown=false end
    if modifier=="ctrl" or modifier=="left ctrl" or modifier=="right ctrl" then self.CtrlDown=false end
    if modifier=="alt" or modifier=="left alt" or modifier=="right alt" then self.AltDown=false end
end

function RTS:ShouldOverrideKey(key,rawKey)
    if self.Enabled~=true or key==nil then return false end
    if self.ExitMenuActive then return true end
    if key==(self.Config.HotkeyHintsKey or 'F10') or rawKey==(self.Config.HotkeyHintsKey or 'F10') then return true end
    if key==(self.Config.FleetCostToggleKey or 'F9') or rawKey==(self.Config.FleetCostToggleKey or 'F9') then return true end
    local raw=rawKey or key; raw=string.gsub(raw,"^Shift%-",""); raw=string.gsub(raw,"^Ctrl%-",""); raw=string.gsub(raw,"^Alt%-","")
    local pauseControl=(type(controls)=="table" and controls.Pause) or "__no_pause_control__"
    if (raw=="Pause" or raw=="Break" or raw==pauseControl) then return not string.find(key,"Alt",1,true) end
    if raw=="Esc" or raw=="Escape" then
        return self.EscapeKeyOverride==true and not string.find(key,"Alt",1,true)
    end
    if self.CinematicActive then return true end
    if self.PostBattleActive then return false end
    if raw=="Space" or raw=="Spacebar" then
        if self.PossessedSignature~=nil then return false end
        if self.CtrlDown and string.find(key,"Ctrl",1,true) then return true end
        return not self.SetupActive and not string.find(key,"Ctrl",1,true)
            and not string.find(key,"Alt",1,true) and not string.find(key,"Shift",1,true)
    end
    if raw=="=" or raw=="-" or raw=="Pad +" or raw=="Pad -"
        or (string.find(key,'Alt',1,true) and ({['0']=true,['1']=true,['2']=true,['3']=true,['4']=true})[raw]) then
        return not self.SetupActive
    end
    if string.find(key,'Alt',1,true) and ({['0']=true,['1']=true,['2']=true,['3']=true,['4']=true})[raw] then return true end
    if self.PossessedSignature~=nil then
        local groups=self.PilotTurretGroups
        return key==self.Config.Pilot.ToggleKey or (groups and #groups>0 and
            (raw==self.Config.Pilot.TurretGroupPreviousKey or raw==self.Config.Pilot.TurretGroupNextKey
             or raw==self.Config.Pilot.TurretGroupToggleKey or raw==self.Config.Pilot.TurretSubsystemKey
             or raw==self.Config.Pilot.TurretSubsystemPreviousKey or raw==self.Config.Pilot.TurretSubsystemNextKey))
    end
    if self.SetupActive then return false end
    if self.BattleCamActive then return true end
    local c=self.Config.HomeworldControls or {}
    if raw=="0" then return string.find(key,'Alt',1,true)~=nil end
    local handled={[self.Config.Pilot.ToggleKey]=true,[c.SelectAll or "L"]=true,[c.Stop or "R"]=true,[c.Engage or "T"]=true,[c.Release or "G"]=true,["="]=true,["-"]=true,["Pad +"]=true,["Pad -"]=true,[c.MuteMusic or "N"]=true,[c.ArmMove or "M"]=true,[c.ArmAttack or "K"]=true,[c.Focus or "F"]=true,[c.FocusBase or "H"]=true,[c.Chase or "B"]=true,[c.HoldPolicy or "J"]=true,[c.PanForward or "W"]=true,[c.PanBackward or "S"]=true,[c.PanLeft or "A"]=true,[c.PanRight or "D"]=true,["Up"]=true,["Down"]=true,["Left"]=true,["Right"]=true,[c.ZoomFar or "Q"]=true,[c.ZoomNear or "E"]=true,[c.PassivePolicy or "Z"]=true,[c.DefensivePolicy or "X"]=true,[c.AggressivePolicy or "V"]=true,[c.Cinematic or "C"]=true,[c.TimeSlower or "1"]=true,[c.TimePause or "2"]=true,[c.TimeFaster or "3"]=true,[c.TimeReset or "4"]=true,[c.Wing1 or "1"]=true,[c.Wing2 or "2"]=true,[c.Wing3 or "3"]=true,[c.Wing4 or "4"]=true}
    return handled[raw]==true
end
