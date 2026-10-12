-- Shared locals of fs2rts_ai_planning: file-level state every part binds to the same values.
return function(RTS)
local U = require "fs2rts_ai_util"

local FS2_UTIL=require 'fs2rts_util'

local shipAlive=FS2_UTIL.shipAlive

local DEFAULT_FACTION_ORDER=FS2_UTIL.AI_FACTION_ORDER

-- Declared in the helpers' original order so upvalues resolve identically.
local valid, sig, clamp, distance, health, doctrine, mobileRole, heavyRole, balanceDefinition, json, newBaseDamageFaction, baseDamageBucketKey, baseDamageRows, baseDamageSummary, newCombatDamageFaction, FRIENDLY_FIRE_PAIR_LIMIT, combatDamageBucketKey, combatDamageRows, friendlyFireRows, combatDamageSummary
    = U.valid, U.sig, U.clamp, U.distance, U.health, U.doctrine, U.mobileRole, U.heavyRole, U.balanceDefinition, U.json, U.newBaseDamageFaction, U.baseDamageBucketKey, U.baseDamageRows, U.baseDamageSummary, U.newCombatDamageFaction, U.FRIENDLY_FIRE_PAIR_LIMIT, U.combatDamageBucketKey, U.combatDamageRows, U.friendlyFireRows, U.combatDamageSummary

local function canAutoEngage(self,attacker,target)
    if self.CanAutoEngage then return self:CanAutoEngage(attacker,target) end
    return self:AreEnemies(attacker,target)
end

return {
    shipAlive = shipAlive,
    DEFAULT_FACTION_ORDER = DEFAULT_FACTION_ORDER,
    valid = valid,
    sig = sig,
    clamp = clamp,
    distance = distance,
    health = health,
    doctrine = doctrine,
    mobileRole = mobileRole,
    heavyRole = heavyRole,
    newBaseDamageFaction = newBaseDamageFaction,
    baseDamageRows = baseDamageRows,
    baseDamageSummary = baseDamageSummary,
    newCombatDamageFaction = newCombatDamageFaction,
    combatDamageSummary = combatDamageSummary,
    canAutoEngage = canAutoEngage,
}
end
