-- Shared locals of fs2rts_pilot, moved out of its parts so every part binds the same values.
-- Loaded first by the aggregator; parts import the names they use from the returned table.

local U = require "fs2rts_util"

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

local function sexpString(value)
    return '"'..tostring(value):gsub('\\','\\\\'):gsub('"','\\"'):gsub('[\r\n]',' ')..'"'
end

local function clearPilotForcedTarget(entry)
    if entry.forcedOwner then
        mn.runSEXP('(turret-clear-forced-target '..sexpString(entry.forcedOwner)..' '..sexpString(entry.subsystem.CanonicalName)..')')
        entry.forcedOwner=nil
    end
end

local function fireSlot(entry, slot, flakAim)
    local subsystem=entry.subsystem
    local target=subsystem.Target
    local flakRange=1000
    if objectValid(target) then flakRange=math.max(1,subsystem.WorldPosition:getDistance(target.Position)) end
    local direction=nil
    local banks=slot<=MAX_SHIP_PRIMARY_BANKS and subsystem.PrimaryBanks or subsystem.SecondaryBanks
    local bank=banks and banks[slot<=MAX_SHIP_PRIMARY_BANKS and slot or slot-MAX_SHIP_PRIMARY_BANKS]
    local weapon=bank and bank.WeaponClass
    if entry.targetRequired and not objectValid(target) then return false end
    if objectValid(target) and objectValid(weapon) and not weapon:isBeam() and not flakAim then
        local origin=subsystem:getNextFiringPosition()
        local aim=RTS:GetPilotFlakAim(subsystem,target,weapon,origin)
        if shipValid(target) and target==RTS:GetPossessedShip().Target then
            local index=RTS:ResolvePilotTargetSubsystemIndex(target)
            local selected=index>0 and target[index] or nil
            if objectValid(selected) then aim=aim+selected.WorldPosition-target.Position end
        end
        local delta=aim-origin; local length=delta:getDistance(vec(0,0,0))
        if origin:getDistance(target.Position)-(target.Radius or 0)>RTS:GetWeaponFiringRange(weapon)
            or subsystem:isPositionInFOV(aim)~=true then return false end
        -- Unlike native turret AI, fireWeapon does not compute a firing vector
        -- from the target. Supply the intercept within the mount's arc; some
        -- retail barrel models cannot visually converge on the arc's centre.
        if length>1 then
            direction=delta/length
        end
    end
    -- turret_fire_weapon advances its cooldown before beam_fire rejects a
    -- missing target. Avoid spending a real beam cycle on a targetless trigger.
    if objectValid(weapon) and weapon:isBeam() and (not objectValid(target) or subsystem.BeamFree==false) then return false end
    if objectValid(weapon) and weapon:isBeam() then
        -- beam_fire can reject a slewing barrel AFTER consuming its cooldown.
        -- Check the actual muzzle normal, not just the turret's base arc.
        local origin,normal=subsystem:getNextFiringPosition()
        local delta=target.Position-origin; local length=delta:getDistance(vec(0,0,0))
        if length-(target.Radius or 0)>RTS:GetWeaponFiringRange(weapon) then return false end
        local fov=subsystem:getFOVs()
        if length>1 and (delta.x*normal.x+delta.y*normal.y+delta.z*normal.z)/length<fov then return false end
    end
    if flakAim and weapon and (RTS.Config.Pilot.FlakWeapons or {})[weapon.Name] then
        if subsystem:isPositionInFOV(flakAim)~=true then return false end
        flakRange=math.max(1,subsystem.WorldPosition:getDistance(flakAim))
        direction=(flakAim-subsystem.WorldPosition)/flakRange
    end
    local fired=subsystem:fireWeapon(slot,flakRange,direction)==true
    if fired and objectValid(weapon) then
        -- Upstream does not expose the per-bank native timestamps. This is
        -- observed-shot cycle guidance, not a gate on the engine's trigger.
        entry.cooldowns=entry.cooldowns or {}
        entry.cooldowns[slot]=mn.getMissionTime()+(weapon.FireWait or 0)/math.max(.01,subsystem.FireRateMultiplier or 1)
    end
    -- Native code assigns its range after On Turret Fired. Apply the exact
    -- launch-point range after the API returns so it cannot overwrite it.
    RTS:FinalizePilotFlakShots()
    return fired
end

local function turretTrigger(entry, down, flakAim)
    local subsystem=entry.subsystem
    if not down or not subsystem:isValid() then return end
    local banks = subsystem.PrimaryBanks
    if banks == nil then return end
    for slot = 1, #banks do fireSlot(entry, slot, flakAim) end
end

local function turretSecondaries(entry, flakAim)
    local subsystem=entry.subsystem
    if not subsystem:isValid() then return end
    local banks = subsystem.SecondaryBanks
    if banks == nil then return end
    for slot = 1, #banks do fireSlot(entry, MAX_SHIP_PRIMARY_BANKS + slot, flakAim) end
end

return {
    U = U,
    RTS = RTS,
    clamp = clamp,
    vec = vec,
    copyVec = copyVec,
    objectValid = objectValid,
    shipValid = shipValid,
    shipAlive = shipAlive,
    sexpString = sexpString,
    clearPilotForcedTarget = clearPilotForcedTarget,
    turretTrigger = turretTrigger,
    turretSecondaries = turretSecondaries,
}
