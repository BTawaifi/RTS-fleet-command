-- AI objective scoring.
return function(RTS, _shared)
local clamp, distance, doctrine, sig, heavyRole, health, canAutoEngage = _shared.clamp, _shared.distance, _shared.doctrine, _shared.sig, _shared.heavyRole, _shared.health, _shared.canAutoEngage

function RTS:ScoreAIObjective(g,target,mission,context,coverage,includeDetails)
    local ship=g.units[1]; local p=self:AIProfile(ship); local d=distance(ship,target)
    local match,reason=self:AIRoleMatch(ship,target)
    local hostile=canAutoEngage(self,ship,target); local tv=self:AIProfile(target).value
    local urgent=context and context.urgent or false
    local eta=math.max(0,d-(target.Radius or 0)-p.range)/math.max(1,p.speed)
    local radius=doctrine(self).LocalStrengthRadius or 4500
    local friend,enemy=self:AILocalStrength(ship,target.Position,radius,false)
    -- Project only arrivals not already included in the local snapshot.
    local arrivals=0
    for _,member in ipairs(g.units) do
        if member.Position:getDistance(target.Position)>radius then
            arrivals=arrivals+self:AIProfile(member).value
        end
    end
    local ratio=(friend+arrivals)/(math.max(1,enemy))
    local covered=(coverage or 0)/math.max(1,tv)
    local valueFactor=math.min(70,math.sqrt(math.max(0,tv))*2)
    local urgencyFactor=urgent and 140 or 0
    local distanceFactor=-math.min(100,eta*.4)
    local coverageFactor=-math.max(0,covered-1)*70
    local superiorityFactor=clamp((ratio-1)*12,-35,25)
    local score=(70+valueFactor)*match+urgencyFactor+distanceFactor+coverageFactor+superiorityFactor
    if not hostile then score=55; reason='DEFEND_BASE' end
    if mission=='PRIMARY' then score=score+35; reason='PUSH_ENEMY_BASE' end
    if covered>1.8 and not urgent then reason='TARGET_OVERCOMMITTED' end
    if match<.2 and hostile and not urgent then score=-100 end
    if p.speed<1 and eta>1 then score=-100; reason='TARGET_UNREACHABLE' end
    if context and context.reason then reason=context.reason end
    if includeDetails then
        local factors={role=match,value=valueFactor,urgency=urgencyFactor,distance=distanceFactor,
            coverage=coverageFactor,superiority=superiorityFactor}
        return {target=sig(target),mission=mission,score=score,reason=reason,factors=factors,
            distance=d,eta=eta,ratio=ratio,confidence=p.confidence,urgent=urgent}
    end
    return {score=score,reason=reason,confidence=p.confidence}
end

-- Decides whether this decision should record its candidate ranking.
--
-- Two independent switches, and they must not be conflated:
--   DetailedDecisionTelemetry  every group, every decision. Measured at
--                              ~200 MB/match, so it stays off.
--   SampledHeavyDecisionTelemetry
--                              heavy/capital/juggernaut groups only, 1-in-N.
--
-- The candidate table is what ScoreAIObjective populates (it takes
-- `g.candidates~=nil` as its includeDetails argument), so enabling it for a
-- group is the whole mechanism; there is no second copy of the scoring loop.
-- Returns true when the candidate list should be collected.
function RTS:ShouldRecordDecisionCandidates(role)
    local ai=self.Config.AI or {}
    if not self.CombatTelemetryEnabled then return false end
    if ai.DetailedDecisionTelemetry==true then return true end
    if ai.SampledHeavyDecisionTelemetry~=true then return false end
    if not heavyRole(role) then return false end
    -- One counter per mission, advanced only by heavy groups, so the rate is
    -- "1 in N heavy decisions" rather than "1 in N decisions of any kind".
    local every=math.max(1,math.floor(tonumber(ai.SampledHeavyDecisionSampleEvery) or 40))
    self.AIHeavyDecisionSamples=self.AIHeavyDecisionSamples or 0
    self.AIHeavyDecisionSamples=self.AIHeavyDecisionSamples+1
    return (self.AIHeavyDecisionSamples%every)==0
end

function RTS:PrepareAIGroups(groups,station,primary,now)
    local retreatFraction=doctrine(self).RetreatHullFraction or .22
    for _,g in ipairs(groups) do
        table.sort(g.units,function(a,b) return sig(a)<sig(b) end)
        -- Sampled-heavy groups are counted here, before any scoring happens, so
        -- the 1-in-N rate is over heavy groups rather than over all of them.
        g.recordCandidates=self:ShouldRecordDecisionCandidates(g.role)
        g.candidates=g.recordCandidates and {} or nil; g.minHull=1; g.spread=0
        -- minHull stays a true minimum because the taunt probe wants the strict
        -- reading ("no hull below the fraction"). The break-off trigger cannot
        -- use it: a wing breaks off as a unit, so a single mauled escort would
        -- otherwise recall every healthy ship alongside it. Count the hulls at
        -- or below the fraction instead and let the caller compare that share
        -- against Doctrine.RetreatDamagedShipFraction.
        local damaged=0
        for _,s in ipairs(g.units) do
            local hull=health(s)
            g.minHull=math.min(g.minHull,hull)
            if hull<=retreatFraction then damaged=damaged+1 end
            g.spread=math.max(g.spread,distance(s,g.units[1]))
        end
        g.damagedFraction=#g.units>0 and damaged/#g.units or 0
        g.homeDistance=distance(g.units[1],station)
    end
    table.sort(groups,function(a,b) return a.id<b.id end)
end
end
