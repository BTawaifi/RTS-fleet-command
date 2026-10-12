-- Escalation profile, tier unlocks and IFF setup.
local _shared = require "fs2rts_factions.common"
local RTS, clamp = _shared.RTS, _shared.clamp

local Config = require "fs2rts_config"

-- Upstream stores IFF relations in a signed 32-bit mask. Twelve RTS teams are
-- well below its bit limit and the measured practical ceiling; build the slots
-- here so experiment tools can still wrap config.lua's top-level return table.
do
    local order=Config.FactionOrder
    local species={"TERRAN","SHIVAN","VASUDAN"}
    for index=4,12 do
        local key=string.format("FACTION_%02d",index)
        local race=species[(index-4)%#species+1]
        local team="RTS Faction "..index
        local station=team.." Station"
        if not Config.FactionIndex[key] then order[#order+1]=key end
        Config.FactionIndex[key]=index
        Config.Factions[key]={name=Config.Species[race].label,short=string.format("TEAM %02d",index),
            team=team,teamColor=team,defaultSpecies=race,station=station,
            primary="Destroy the opposing command stations.",secondary="Defend your station and destroy hostile fleets."}
        Config.FactionStationByName[station]=key
    end
end

function RTS:GetEscalationProfile()
    return self.Config.Escalation
end

function RTS:GetEscalationProgress(now)
    local unlocks=self:GetEscalationProfile().tierUnlocks
    return clamp(self:GetScenarioElapsed(now)/math.max(1,unlocks[#unlocks] or 1),0,1)
end

-- Mission time, which advances with time compression. This is the clock the
-- economy and AI difficulty ramp run on: 16x genuinely means 16x resources per
-- real second, the standard RTS bargain.
function RTS:GetScenarioElapsed(now)
    if self.ScenarioStartTime == nil then return 0 end
    return math.max(0, (now or mn.getMissionTime()) - self.ScenarioStartTime)
end

-- The scenario has ONE clock: mission time. 1.4.1 also kept a wall-clock
-- accumulator (ba.getRealFrametime) and drove the escalation tiers off it, on
-- the theory that 16x should not compress the advertised schedule. That made
-- the tier schedule the only thing in a match that ignored the speed control,
-- so skipping to 8x sped up the fleets but not the escalation. Removed: with
-- the tiers back on mission time there is nothing left that needs a second
-- clock, and two disagreeing clocks is how the bug stayed invisible.

function RTS:GetCurrentEscalationTier(now)
    if self.SetupActive or self.ScenarioStartTime == nil then return 1 end
    local duration = self:GetEscalationProfile()
    local unlocks = duration and duration.tierUnlocks or { 0, 300, 900, 1800 }
    -- Mission time, NOT wall-clock. 1.4.1 drove this off an accumulator built
    -- from ba.getRealFrametime() so that time compression could not accelerate
    -- escalation, but that made the tier schedule the one thing in the match
    -- that ignored the speed control: skip to 8x and the fleets still fight to
    -- the same advertised schedule while everything else runs 8x faster. The
    -- schedule now follows the game clock, as it did in 1.3.0, so choosing a
    -- higher speed genuinely shortens the match.
    local elapsed = self:GetScenarioElapsed(now)
    local tier = 1
    for i = 1, #unlocks do if elapsed >= unlocks[i] then tier = i end end
    return clamp(tier, 1, math.max(1,#unlocks))
end

function RTS:GetTierUnlockRemaining(tier, now)
    local duration = self:GetEscalationProfile()
    if duration == nil or duration.tierUnlocks == nil then return 0 end
    local unlock = duration.tierUnlocks[tier] or 0
    return math.max(0, unlock - self:GetScenarioElapsed(now))
end

function RTS:IsBuildOptionUnlocked(option, now)
    if option == nil then return false end
    return (option.tier or 1) <= self:GetCurrentEscalationTier(now)
end
