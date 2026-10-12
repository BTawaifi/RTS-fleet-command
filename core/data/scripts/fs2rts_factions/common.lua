-- Shared locals of fs2rts_factions, moved out of its parts so every part binds the same values.
-- Loaded first by the aggregator; parts import the names they use from the returned table.

local U = require "fs2rts_util"

local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys

local RTS = require "fs2rts_state"

local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

local function factionForTeam(self,ship,team)
    local withdrawal=self.Withdrawals and next(self.Withdrawals) and self.Withdrawals[ship:getSignature()]
    if withdrawal and withdrawal.inCorridor then return withdrawal.faction end
    if team==nil or not team:isValid() then return nil end
    local kind=self.FactionKeyByTeam and self.FactionKeyByTeam[lower(team.Name)] or nil
    if kind=="BLUE" and ship.Name==self.Config.ObserverShip then return nil end
    return kind
end

return {
    AI_FACTION_ORDER = AI_FACTION_ORDER,
    RTS = RTS,
    clamp = clamp,
    lower = lower,
    vec = vec,
    copyVec = copyVec,
    shipValid = shipValid,
    shipAlive = shipAlive,
    tableContainsSignature = tableContainsSignature,
    factionForTeam = factionForTeam,
}
