-- Shared locals of fs2rts_strategy, moved out of its parts so every part binds the same values.
-- Loaded first by the aggregator; parts import the names they use from the returned table.

local U = require "fs2rts_util"

local sortedNumericKeys = U.sortedNumericKeys

local RTS = require "fs2rts_state"

local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

local function canAutoEngage(self,attacker,target)
    if self.CanAutoEngage then return self:CanAutoEngage(attacker,target) end
    return self:AreEnemies(attacker,target)
end

-- Same priority the bare ORDER_ATTACK branch installs, so nothing else in the
-- order stack shifts when a pursuit replaces a chase goal.
local ATTACK_ORDER_PRIORITY=0.88

local PURSUIT_LEAD_SECONDS=4

local PURSUIT_REFRESH_SECONDS=1.5

-- Upstream beam.h BEAM_DAMAGE_TIME=170 ms: Damage is per interval, not per second.
local BEAM_DAMAGE_INTERVAL=.170

-- objecttypes.tbl '+Actively Pursues' covers cruiser/corvette/capital but not
-- fighter, bomber or support, and omits the "command" class type entirely, so
-- ai_chase sets AIM_NONE on those targets. IsUnpursuedTarget also treats a
-- command station as unpursued for every attacker, because no hull pursues one.
local UNPURSUED_TARGET_ROLES={fighter=true,bomber=true,support=true}

-- Escorts are included because they stalled just as far as capitals on a base
-- attack; the attack order has to be driven by a waypoint, not a chase goal.
local HEAVY_ATTACKER_ROLES={capital=true,heavy=true,juggernaut=true,escort=true}

return {
    sortedNumericKeys = sortedNumericKeys,
    RTS = RTS,
    clamp = clamp,
    vec = vec,
    copyVec = copyVec,
    objectValid = objectValid,
    shipValid = shipValid,
    shipAlive = shipAlive,
    canAutoEngage = canAutoEngage,
    ATTACK_ORDER_PRIORITY = ATTACK_ORDER_PRIORITY,
    PURSUIT_LEAD_SECONDS = PURSUIT_LEAD_SECONDS,
    PURSUIT_REFRESH_SECONDS = PURSUIT_REFRESH_SECONDS,
    BEAM_DAMAGE_INTERVAL = BEAM_DAMAGE_INTERVAL,
    UNPURSUED_TARGET_ROLES = UNPURSUED_TARGET_ROLES,
    HEAVY_ATTACKER_ROLES = HEAVY_ATTACKER_ROLES,
}
