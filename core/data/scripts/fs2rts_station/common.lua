-- Shared locals of fs2rts_station, moved out of its parts so every part binds the same values.
-- Loaded first by the aggregator; parts import the names they use from the returned table.

local U = require "fs2rts_util"

local RTS = require "fs2rts_state"

local clamp, vec, copyVec, distance2, shipValid, shipAlive, objectValid = U.clamp, U.vec, U.copyVec, U.distance2, U.shipValid, U.shipAlive, U.objectValid

local TRACKS = { "armor", "defenses", "logistics", "command" }

local function cfg(self) return self.Config.Station end

local function canAutoEngage(self,attacker,target)
    if self.CanAutoEngage then return self:CanAutoEngage(attacker,target) end
    return self:AreEnemies(attacker,target)
end

local function flatDistance(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

local function refreshSurgeBase(base, current, applied)
    local function component(axis)
        return math.abs(current[axis]-applied[axis])>0.001 and current[axis] or base[axis]
    end
    return vec(component("x"),component("y"),component("z"))
end

return {
    U = U,
    RTS = RTS,
    clamp = clamp,
    vec = vec,
    copyVec = copyVec,
    shipValid = shipValid,
    shipAlive = shipAlive,
    objectValid = objectValid,
    TRACKS = TRACKS,
    cfg = cfg,
    canAutoEngage = canAutoEngage,
    flatDistance = flatDistance,
    refreshSurgeBase = refreshSurgeBase,
}
