-- Possession state: button reads, observer restore and telemetry mirror.
local _shared = require "fs2rts_pilot.common"
local RTS, copyVec, shipValid, clamp, objectValid = _shared.RTS, _shared.copyVec, _shared.shipValid, _shared.clamp, _shared.objectValid

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
        -- FSO applies native shield-balance keys to Player_obj (the observer).
        -- Carry that proxy delta to the real hull before mirroring it back;
        -- adding the delta preserves shield damage received during this frame.
        local count=math.min(#observer.Shields,#ship.Shields)
        local previous=self.PilotShieldMirrorSnapshot
        if previous~=nil then
            for i=1,math.min(count,#previous) do
                local delta=(tonumber(observer.Shields[i]) or 0)-(tonumber(previous[i]) or 0)
                if math.abs(delta)>.001 then ship.Shields[i]=(tonumber(ship.Shields[i]) or 0)+delta end
            end
        end
        local snapshot={}
        for i=1,count do observer.Shields[i]=ship.Shields[i]; snapshot[i]=ship.Shields[i] end
        self.PilotShieldMirrorSnapshot=snapshot
    end
    if self.PilotWeaponEnergyMirrorSnapshot~=nil then
        local delta=observer.WeaponEnergyLeft-self.PilotWeaponEnergyMirrorSnapshot
        ship.WeaponEnergyLeft=clamp(ship.WeaponEnergyLeft+delta,0,ship.WeaponEnergyMax)
    end
    observer.WeaponEnergyLeft = ship.WeaponEnergyLeft
    self.PilotWeaponEnergyMirrorSnapshot=ship.WeaponEnergyLeft
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
