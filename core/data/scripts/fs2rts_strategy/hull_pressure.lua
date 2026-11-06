-- Station hull pressure: how much of its maximum hull a command station has lost
-- over a short rolling window, whoever is shooting it.
--
-- Threat ranking only sees attackers that can damage a base (bomber, escort,
-- capital, heavy, juggernaut), so a fighter swarm is never urgent by threat alone.
-- Hull lost is the one signal that does not depend on guessing which weapon is
-- effective, so this tracks it directly.
local _shared = require "fs2rts_strategy.common"
local RTS, shipValid = _shared.RTS, _shared.shipValid

local SAMPLE_INTERVAL = 1
-- Pressure stays on until the windowed loss falls to this share of the trigger.
local RELEASE_RATIO = 0.5

local function windowLossFraction(samples, hull, maxHull)
    if maxHull <= 0 then return 0 end
    local peak = hull
    for _, sample in ipairs(samples) do
        if sample.hull > peak then peak = sample.hull end
    end
    return (peak - hull) / maxHull
end

local function pruneSamples(samples, cutoff)
    while samples[1] and samples[1].time < cutoff do table.remove(samples, 1) end
end

-- Returns true while the station is under hull pressure, plus the windowed loss
-- as a fraction of maximum hull.
function RTS:UpdateStationHullPressure(kind, station, now)
    local doctrine = self.Config.AI.Doctrine or {}
    local trigger = doctrine.StationPressureLossFraction or 0
    if trigger <= 0 or not shipValid(station) then return false, 0 end
    local window = doctrine.StationPressureWindowSeconds or 60
    self.StationHullPressure = self.StationHullPressure or {}
    local state = self.StationHullPressure[kind]
    if state == nil or now < state.lastTime then
        state = {samples = {}, lastTime = -math.huge, active = false}
        self.StationHullPressure[kind] = state
    end
    local hull, maxHull = station.HitpointsLeft, station.HitpointsMax
    if now - state.lastTime >= SAMPLE_INTERVAL then
        state.samples[#state.samples + 1] = {time = now, hull = hull}
        state.lastTime = now
    end
    pruneSamples(state.samples, now - window)
    local loss = windowLossFraction(state.samples, hull, maxHull)
    if state.active then
        state.active = loss > trigger * RELEASE_RATIO
    else
        state.active = loss >= trigger
    end
    return state.active, loss
end
