-- AI context, objective scoring, group commits, execution observation.
local U = require "fs2rts_ai_util"
local shipAlive=require('fs2rts_util').shipAlive

return function(RTS)
-- Declared in the helpers' original order so upvalues resolve identically.
local valid, sig, clamp, distance, health, doctrine, mobileRole, heavyRole, balanceDefinition, json, newBaseDamageFaction, baseDamageBucketKey, baseDamageRows, baseDamageSummary, newCombatDamageFaction, FRIENDLY_FIRE_PAIR_LIMIT, combatDamageBucketKey, combatDamageRows, friendlyFireRows, combatDamageSummary
    = U.valid, U.sig, U.clamp, U.distance, U.health, U.doctrine, U.mobileRole, U.heavyRole, U.balanceDefinition, U.json, U.newBaseDamageFaction, U.baseDamageBucketKey, U.baseDamageRows, U.baseDamageSummary, U.newCombatDamageFaction, U.FRIENDLY_FIRE_PAIR_LIMIT, U.combatDamageBucketKey, U.combatDamageRows, U.friendlyFireRows, U.combatDamageSummary

function RTS:IsAutomaticAIUnit(ship)
    local kind=self:GetFactionKey(ship); local id=sig(ship)
    return shipAlive(ship) and kind~=nil and not self:IsCommandStation(ship) and ship.Name~=self.Config.ObserverShip and not self:IsStaticDefense(ship)
        and not (self.FleetServices and self.FleetServices[id])
        and not (kind=='BLUE' and (not self.AutoPlayerMode or self.PossessedSignature==id or self.UserOrders[id]~=nil))
end

function RTS:BuildAIContext(snapshot)
    self.AIShipIndex={}; self.AIProfileIndex={}; self.AILocalCache={}; self.AITargetedBy={}
    self.AISpatialGrid={}
    local doctrineConfig=self.Config.AI.Doctrine or {}
    self.AISpatialCellSize=math.max(1,tonumber(doctrineConfig.LocalStrengthRadius) or 4500)
    local function recordTarget(target,attackerFaction,attackerId)
        if not valid(target) or attackerFaction==nil then return end
        local targetId=sig(target)
        local factions=self.AITargetedBy[targetId]
        if factions==nil then factions={}; self.AITargetedBy[targetId]=factions end
        local attackers=factions[attackerFaction]
        if attackers==nil then attackers={}; factions[attackerFaction]=attackers end
        attackers[attackerId]=self.AIShipIndex[attackerId]
    end
    for index,row in ipairs(snapshot) do
        local s=row.ship; local id=sig(s); local role=self:GetShipRole(s); local position=s.Position
        local attackerFaction=self:GetFactionKey(s)
        self.AIShipIndex[id]=s
        recordTarget(s.Target,attackerFaction,id)
        for _,mount in ipairs(row.mounts) do recordTarget(mount.target,attackerFaction,id) end
        local reach=row.maxRange
        if reach==nil then
            reach=0
            for _,mount in ipairs(row.mounts) do reach=math.max(reach,mount.range) end
        end
        local armed=row.armed; local beam=row.profileBeam
        if armed==nil or beam==nil then
            -- Keep compatibility with snapshots produced by older callers.
            armed=false; beam=false
            local function banks(owner)
                for _,list in ipairs({owner.PrimaryBanks,owner.SecondaryBanks}) do
                    for i=1,#list do local bank=list[i]; local w=bank.WeaponClass
                        if valid(bank) and valid(w) and ((bank.AmmoMax or 0)<=0 or (bank.AmmoLeft or 0)>0) then
                            armed=true; beam=beam or w:isBeam()
                        end
                    end
                end
            end
            banks(s)
            for i=1,#s do local turret=s[i]; if valid(turret) and not turret.TurretLocked then banks(turret) end end
        end
        local p={ship=s,role=role,range=reach,beam=beam,armed=armed,confidence=beam and .65 or .9,
            speed=math.abs(s.Physics.VelocityMax.z),value=self:GetCombatValue(s,row.firepower),
            hull=health(s),station=self:IsCommandStation(s),mounts=row.mounts}
        local cellX=math.floor(position.x/self.AISpatialCellSize)
        local cellY=math.floor(position.y/self.AISpatialCellSize)
        local cellZ=math.floor(position.z/self.AISpatialCellSize)
        local cellKey=cellX..':'..cellY..':'..cellZ
        local cell=self.AISpatialGrid[cellKey]
        if cell==nil then cell={}; self.AISpatialGrid[cellKey]=cell end
        row.index=index; row.signature=id; row.cellKey=cellKey
        cell[#cell+1]=row
        self.AIProfileIndex[id]=p; row.profile=p
    end
end

function RTS:FindAIGroupTargeter(g,kind,radius)
    local best,bestDistance=nil,radius or math.huge
    for _,member in ipairs(g.units or {}) do
        local byFaction=(self.AITargetedBy or {})[sig(member)]
        if byFaction then
            for attackerFaction,attackers in pairs(byFaction) do
                if attackerFaction~=kind then
                    for _,attacker in pairs(attackers) do
                        local d=valid(attacker) and distance(member,attacker) or math.huge
                        if d<=bestDistance and self:AreEnemies(member,attacker)
                            and (best==nil or d<bestDistance or sig(attacker)<sig(best)) then
                            best=attacker; bestDistance=d
                        end
                    end
                end
            end
        end
    end
    return best
end

function RTS:GetActiveLurePursuers(kind,now)
    local pursuers={}
    local pursuitRadius=(self.Config.AI.Doctrine or {}).LurePursuitRadius or
        (self.Config.AI.Doctrine or {}).HardEngageRadius or 1800
    for targetId,state in pairs(self.AIOrderState or {}) do
        if state.mission=='LURE' and (state.lureUntil or 0)>now then
            local bait=(self.AIShipIndex or {})[targetId]
            if valid(bait) and self:GetFactionKey(bait)==kind then
                local factions=(self.AITargetedBy or {})[targetId]
                if factions then
                    for attackerFaction,attackers in pairs(factions) do
                        if attackerFaction~=kind then
                            for attackerId in pairs(attackers) do pursuers[attackerId]=true end
                        end
                    end
                end
                -- Native combat AI does not always expose a pursued wing via
                -- ship.Target. Treat a hostile that stays inside the bait's
                -- close-defense envelope as a trap candidate as well; the
                -- ordinary station-threat filter still has to confirm it is
                -- actually near enough for home defenders to respond.
                local nearby=self.GetAISpatialCandidates
                    and self:GetAISpatialCandidates(bait.Position,pursuitRadius)
                    or self.StrategicThreatSnapshot or {}
                for _,row in ipairs(nearby) do
                    local attacker=row.ship
                    if valid(attacker) and self:GetFactionKey(attacker)~=kind
                        and self:AreEnemies(bait,attacker)
                        and distance(bait,attacker)<=pursuitRadius then
                        pursuers[sig(attacker)]=true
                    end
                end
            end
        end
    end
    return pursuers
end

function RTS:GetAISpatialCandidates(point,radius)
    local snapshot=self.StrategicThreatSnapshot or {}
    local grid=self.AISpatialGrid; local cellSize=self.AISpatialCellSize
    if grid==nil or cellSize==nil or point==nil then return snapshot end
    radius=math.max(0,tonumber(radius) or 0)
    local minX=math.floor((point.x-radius)/cellSize); local maxX=math.floor((point.x+radius)/cellSize)
    local minY=math.floor((point.y-radius)/cellSize); local maxY=math.floor((point.y+radius)/cellSize)
    local minZ=math.floor((point.z-radius)/cellSize); local maxZ=math.floor((point.z+radius)/cellSize)
    local cellCount=(maxX-minX+1)*(maxY-minY+1)*(maxZ-minZ+1)
    if cellCount>#snapshot*2 then return snapshot end
    local candidates={}
    for x=minX,maxX do
        for y=minY,maxY do
            for z=minZ,maxZ do
                local cell=grid[x..':'..y..':'..z]
                if cell then for _,row in ipairs(cell) do candidates[#candidates+1]=row end end
            end
        end
    end
    table.sort(candidates,function(a,b) return a.index<b.index end)
    return candidates
end

function RTS:AIProfile(ship)
    local p=self.AIProfileIndex and self.AIProfileIndex[sig(ship)]
    if p then return p end
    local mounts,armed,beam,reach,power=self:GetStrategicWeapons(ship)
    return {ship=ship,role=self:GetShipRole(ship),range=reach,armed=armed,beam=beam,confidence=beam and .65 or .9,
        speed=math.abs(ship.Physics.VelocityMax.z),value=self:GetCombatValue(ship,power),hull=health(ship),mounts=mounts}
end

function RTS:AILocalStrength(ship,point,radius,includeSupport)
    local supportKey=includeSupport==false and 'LOCAL' or 'SUPPORT'
    local faction=self:GetFactionKey(ship)
    -- All RTS ships in a faction share the same FSO team/IFF relation. Key by
    -- that relation so every wing scoring the same target reuses one local
    -- strength query; unknown ships retain per-ship isolation.
    local ownerKey=faction and ('FACTION:'..faction) or ('SHIP:'..sig(ship))
    local key=table.concat({ownerKey,point.x,point.y,point.z,radius,supportKey},':')
    local cached=self.AILocalCache and self.AILocalCache[key]
    if cached then return unpack(cached) end
    local friendly,enemy=0,0; local support=math.huge; local ownSignature=sig(ship)
    local snapshot=self.StrategicThreatSnapshot or {}
    for _,row in ipairs(self:GetAISpatialCandidates(point,radius)) do
        local other=row.ship
        if valid(other) then
            local p=row.profile or self:AIProfile(other); local d=other.Position:getDistance(point)
            if d<=radius then
                local hostile=self:AreEnemies(ship,other)
                -- Stations are fixed support, not offensive mobile fleet value.
                local v=p.value*(p.station and .35 or 1)
                if hostile then enemy=enemy+v else friendly=friendly+v end
                -- A friendly inside the search sphere is closer than anything
                -- outside the spatial query's bounding cube.
                if includeSupport~=false and (row.signature or sig(other))~=ownSignature and not hostile then
                    support=math.min(support,d)
                end
            end
        end
    end
    if includeSupport~=false and support>radius then
        for _,row in ipairs(snapshot) do
            local other=row.ship
            if valid(other) and (row.signature or sig(other))~=ownSignature and not self:AreEnemies(ship,other) then
                support=math.min(support,other.Position:getDistance(point))
            end
        end
    end
    if self.AILocalCache then self.AILocalCache[key]={friendly,enemy,support} end
    return friendly,enemy,support
end

function RTS:AIRoleMatch(ship,target)
    local p=self:AIProfile(ship); local t=self:AIProfile(target)
    if p.role=='support' or p.role=='transport' then return .05,'TARGET_BAD_ROLE_MATCH' end
    if p.role=='bomber' then return self:IsCapitalTarget(target) and 1.6 or .12,'WEAPON_ROLE' end
    if heavyRole(p.role) and mobileRole(t.role) then
        if t.speed>p.speed*1.5 and distance(ship,target)>math.max(p.range,doctrine(self).HardEngageRadius or 1800) then
            return .05,'TARGET_BAD_ROLE_MATCH'
        end
        return .35,'TARGET_LOW_VALUE'
    end
    if p.role=='fighter' and t.role=='bomber' then return 1.8,'TARGET_HIGH_VALUE' end
    if p.role=='escort' and mobileRole(t.role) then return 1.5,'WEAPON_ROLE' end
    return 1,'WEAPON_ROLE'
end

function RTS:ScoreAIObjective(g,target,mission,context,coverage,includeDetails)
    local ship=g.units[1]; local p=self:AIProfile(ship); local d=distance(ship,target)
    local match,reason=self:AIRoleMatch(ship,target)
    local hostile=self:AreEnemies(ship,target); local tv=self:AIProfile(target).value
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

function RTS:ChooseAILocalThreat(g,coverage)
    local lead=g.units[1]; local best,bestScore=nil,-math.huge
    local radius=self.Config.AI.LocalEngageRadius
    local spread=g.spread
    if spread==nil then
        spread=0
        for i=2,#g.units do spread=math.max(spread,distance(lead,g.units[i])) end
    end
    if spread<=radius*.25 then
        -- Tight wings can use one superset query. The radius+spread bound
        -- includes every contact within radius of any member; exact member
        -- distances below preserve the old target set. Rows are already in
        -- snapshot order, so no merge map or candidate sort is needed.
        for _,row in ipairs(self:GetAISpatialCandidates(lead.Position,radius+spread+0.01)) do
            local t=row.ship
            if valid(t) then
                local inRange=distance(lead,t)<=radius
                if not inRange then
                    for i=2,#g.units do
                        if distance(g.units[i],t)<=radius then inRange=true; break end
                    end
                end
                if inRange and self:AreEnemies(lead,t) and not self:IsCommandStation(t) then
                    local c=self:ScoreAIObjective(g,t,'INTERCEPT',nil,(coverage or {})[sig(t)],g.candidates~=nil)
                    if g.candidates then g.candidates[#g.candidates+1]=c end
                    if c.score>bestScore and c.score>0 then best=t; bestScore=c.score end
                end
            end
        end
    else
        local bySignature={}; local candidates={}
        -- Widely spread wings retain member-local queries so the enclosing
        -- superset does not pull in a much larger part of the battlefield.
        for _,member in ipairs(g.units) do
            for _,row in ipairs(self:GetAISpatialCandidates(member.Position,radius)) do
                local t=row.ship
                if valid(t) then
                    local id=row.signature or sig(t); local d=distance(member,t)
                    local candidate=bySignature[id]
                    if candidate==nil then
                        candidate={row=row,distance=d}; bySignature[id]=candidate; candidates[#candidates+1]=candidate
                    elseif d<candidate.distance then
                        candidate.distance=d
                    end
                end
            end
        end
        table.sort(candidates,function(a,b)
            local ai=a.row.index or math.huge; local bi=b.row.index or math.huge
            if ai~=bi then return ai<bi end
            return tostring(a.row.signature or sig(a.row.ship))<tostring(b.row.signature or sig(b.row.ship))
        end)
        for _,candidate in ipairs(candidates) do
            local row=candidate.row; local t=row.ship
            if candidate.distance<=radius and self:AreEnemies(lead,t) and not self:IsCommandStation(t) then
                local c=self:ScoreAIObjective(g,t,'INTERCEPT',nil,(coverage or {})[sig(t)],g.candidates~=nil)
                if g.candidates then g.candidates[#g.candidates+1]=c end
                if c.score>bestScore and c.score>0 then best=t; bestScore=c.score end
            end
        end
    end
    return best
end

function RTS:RecordAITransition(ship,old,new,status,now)
    if not self.AIStats then self:ResetCoordinatedAI() end
    now=now or mn.getMissionTime()
    if status=='ORDER_REISSUED' then self.AIStats.reissued=self.AIStats.reissued+1
    elseif old then self.AIStats.switches=self.AIStats.switches+1 end
    self:EmitAIEvent('OBJECTIVE',{ship=sig(ship),name=ship.Name,faction=self:GetFactionKey(ship),
        status=status,previous=old and old.targetSignature,previousMission=old and old.mission,
        previousAge=old and now-old.assignedAt,target=new.targetSignature,mission=new.mission,
        assignedAt=new.assignedAt,native=sig(ship.Target)},now)
end

function RTS:ChooseAIFormation(role,mission)
    local F=self.Config.Formation or {}
    if F.AIUsesFormations~=true then return nil end
    local map=(self.Config.AI or {}).Formations or {}
    local function pick(key)
        return (type(key)=="string" and self:GetFormationShape(map[key])~=nil) and map[key] or nil
    end
    local chosen=pick(role) or pick(mission)
    if chosen~=nil then return chosen end
    local fallback=(self.Config.AI or {}).DefaultFormation or F.Default
    if self:GetFormationShape(fallback)~=nil then return fallback end
    return nil
end

-- Per-unit slots for a group that is moving to a shared point. Capitals,
-- escorted hulls and anything that cannot be moved keep the shared point:
-- fanning a battleship out of a mixed group only parks it alone on the target.
function RTS:BuildAIFormationSlots(g,mission,context)
    local slots={}
    if context==nil or not self:IsFiniteVector(context.destination) then return slots end
    local units=g.units or {}
    local spacing=(self.Config.Formation or {}).Spacing or 450
    local largest=0
    for _,ship in ipairs(units) do largest=math.max(largest,self:GetShipFormationRadius(ship)) end
    local limit=math.min(spacing*2,math.max(spacing,largest*0.5))
    local group={}
    for _,ship in ipairs(units) do
        local role=self:GetShipRole(ship)
        local anchor=role=='capital' or role=='heavy' or role=='juggernaut' or role=='escort'
        if not anchor and self:GetShipFormationRadius(ship)<=limit and self:IsAutomaticAIUnit(ship) then
            group[#group+1]=ship
        end
    end
    if #group<2 then return slots end
    for _,slot in ipairs(self:BuildSafeFormationDestinations(group,context.destination,
        self:ChooseAIFormation(g.role,mission))) do
        slots[sig(slot.ship)]=slot.destination
    end
    return slots
end

-- How a faction's own groups relate to each other and to the environment: do
-- two wings chase the same thing, do their discs overlap, how far is each from
-- the nearest sibling and from the command-arena wall. This is the only record
-- of AI self-coordination; without it a headless run shows what each group did
-- but not whether the groups were working together or piling onto each other.
function RTS:EmitAICohesion(kind,groups,station,primary,now)
    -- The strategic plan runs far more often than a heat map needs. Emitting on
    -- every plan tripled the record count and the frame cost, which pushed a
    -- 3000 s mission past the experiment runner's wall-clock timeout.
    local cadence=(self.Config.AI or {}).CohesionSampleSeconds or 2
    self.AICohesionSampleAt=self.AICohesionSampleAt or {}
    local last=self.AICohesionSampleAt[kind] or -1e9
    if now-last<cadence then return end
    self.AICohesionSampleAt[kind]=now
    local nodes={}
    for _,g in ipairs(groups or {}) do
        local x,z,count=0,0,0
        for _,ship in ipairs(g.units or {}) do
            if shipAlive(ship) and ship.Position then x=x+ship.Position.x; z=z+ship.Position.z; count=count+1 end
        end
        if count>0 then x=x/count; z=z/count end
        local target=g.target
        nodes[#nodes+1]={
            group=g.id,role=g.role,mission=g.mission or (g.committed and "PRIMARY" or "IDLE"),
            x=x,z=z,count=count,value=g.value or 0,
            radius=math.max(g.spread or 0,(g.spread or 0)*0.5),
            targetX=valid(target) and target.Position and target.Position.x or nil,
            targetZ=valid(target) and target.Position and target.Position.z or nil,
            targetSignature=valid(target) and target:getSignature() or nil,
        }
    end
    table.sort(nodes,function(a,b) return tostring(a.group)<tostring(b.group) end)
    local pairs_={}
    for i=1,#nodes do
        for j=i+1,#nodes do
            local a,b=nodes[i],nodes[j]
            local dx=(a.x or 0)-(b.x or 0); local dz=(a.z or 0)-(b.z or 0)
            local centre=math.sqrt(dx*dx+dz*dz)
            local gap=centre-((a.radius or 0)+(b.radius or 0))
            local shared=a.targetSignature~=nil and a.targetSignature==b.targetSignature
            if shared or gap<=(self.Config.AI.CohesionRadius or 3000) then
                pairs_[#pairs_+1]={a=a.group,b=b.group,distance=centre,gap=gap,sharedTarget=shared}
            end
        end
    end
    local arena=self.GetCommandArenaHalfExtent and self:GetCommandArenaHalfExtent() or nil
    local nearEdge=0
    if arena then
        for _,n in ipairs(nodes) do
            if math.abs(n.x or 0)>(arena-1200) or math.abs(n.z or 0)>(arena-1200) then nearEdge=nearEdge+1 end
        end
    end
    -- COHESION.nodes USED TO CHANGE SHAPE MID-STREAM. The shared json() encoder
    -- emits a table as a JSON array only when #v>0, and as an object otherwise
    -- (fs2rts_ai_util.lua:68), so every record whose faction had zero groups
    -- serialised nodes as {} while every record with groups serialised it as
    -- [...]. It is NOT a first-iteration versus steady-state code path: on
    -- sentryfix-20261001 the 266 {} records were all empty and the 17,230 array
    -- records were all non-empty, and {} records recur all through the match
    -- for RED and GOLD while they hold no groups. ai_matchmap.py had to accept
    -- both shapes, and its first implementation handled only dicts and
    -- therefore reported zero stalls. The trap is the encoder's empty-table
    -- ambiguity, not the emitter's ordering, so the fix belongs here: keep the
    -- array shape stable for consumers and name the case explicitly.
    --
    -- nodes is unchanged (dict and list consumers both keep working). The new
    -- fields make the distinction deliberate:
    --   nodesEmpty  true when there are no groups; nodes is {} in that case
    --   nodeCount   authoritative length, so a consumer never has to infer it
    --               from the container's type
    -- groupCount already duplicated nodeCount and is kept for compatibility.
    self:EmitAIEvent('COHESION',{
        faction=kind,time=now,stationX=station and station.Position and station.Position.x or nil,
        stationZ=station and station.Position and station.Position.z or nil,
        primaryX=valid(primary) and primary.Position and primary.Position.x or nil,
        primaryZ=valid(primary) and primary.Position and primary.Position.z or nil,
        arenaHalfExtent=arena,groupCount=#nodes,nodes=nodes,pairs=pairs_,nearArenaEdge=nearEdge,
        nodesEmpty=#nodes==0,nodeCount=#nodes,
    },now)
end

-- Why a battle ended, and who was ahead when it did.
--
-- The FACTION samples give a snapshot every 30 s and the base-damage telemetry
-- gives cumulative damage per weapon, but nothing joined the two: a finished
-- match could not say who killed which base, with what, or from what position.
-- This emits that join at the moment a command station is destroyed, and a
-- periodic CONTEST record that says how each faction's groups are actually
-- allocated and whether any of them are making progress toward their target.
function RTS:EmitContestRecord(kind,groups,station,primary,now)
    local cadence=(self.Config.AI or {}).ContestSampleSeconds or 10
    self.AIContestSampleAt=self.AIContestSampleAt or {}
    if now-(self.AIContestSampleAt[kind] or -1e9)<cadence then return end
    self.AIContestSampleAt[kind]=now
    self.AIContestProgress=self.AIContestProgress or {}

    local primarySignature=valid(primary) and primary:getSignature() or nil
    local onBase,onGroups,stalledGroups=0,0,0
    local worstStall=0; local missions={}; local nodes={}
    for _,g in ipairs(groups or {}) do
        local target=g.target
        local targetSignature=valid(target) and sig(target) or nil
        -- Named "range" not "distance": a local called distance shadows the
        -- distance() helper this module closes over, and the call below would
        -- then be a call on nil.
        local range=nil
        if valid(target) and g.units and g.units[1] and shipAlive(g.units[1]) then
            range=distance(g.units[1],target)
        end
        -- "Progress" is a reduction in range to the current objective. A group
        -- assigned to attack that stops closing is the signature of a capital
        -- that accepted its order and then sat there, which is exactly what the
        -- engine does when ai_chase refuses a fighter target.
        local key=tostring(kind)..'/'..tostring(g.id)
        local state=self.AIContestProgress[key]
        if state==nil or state.mission~=(g.mission or 'IDLE') or state.target~=targetSignature then
            state={mission=g.mission or 'IDLE',target=targetSignature,lastDistance=range,lastProgressAt=now}
            self.AIContestProgress[key]=state
        end
        if range~=nil and state.lastDistance~=nil and range<state.lastDistance-150 then
            state.lastDistance=range; state.lastProgressAt=now
        elseif range~=nil then state.lastDistance=range end
        local stalled=math.max(0,now-(state.lastProgressAt or now))
        if (g.mission=="PRIMARY" or g.mission=="SCREEN" or g.mission=="INTERCEPT") and stalled>30 then
            stalledGroups=stalledGroups+1
            if stalled>worstStall then worstStall=stalled end
        end
        if targetSignature==primarySignature then onBase=onBase+(g.value or 0) else onGroups=onGroups+(g.value or 0) end
        missions[g.mission or 'IDLE']=(missions[g.mission or 'IDLE'] or 0)+1
        nodes[#nodes+1]={group=g.id,role=g.role,mission=g.mission or 'IDLE',value=g.value or 0,
            ships=#(g.units or {}),distance=range,stalledSeconds=stalled,
            targetIsStation=targetSignature==primarySignature}
    end
    -- Orders that stopped being valid: a live order pointing at a dead target is
    -- how "the ship ignores my command" shows up in the aggregate.
    local staleOrders,serviced,alive=0,0,0
    for id,state in pairs(self.AIOrderState or {}) do
        if state.targetSignature~=nil then
            local target=self:FindShipBySignature(state.targetSignature)
            if not valid(target) then staleOrders=staleOrders+1 end
        end
    end
    if self.FleetServices then for _ in pairs(self.FleetServices) do serviced=serviced+1 end end
    self:EmitAIEvent('CONTEST',{
        faction=kind,time=now,primaryName=valid(primary) and primary.Name or 'NONE',
        primaryX=valid(primary) and primary.Position and primary.Position.x or nil,
        primaryZ=valid(primary) and primary.Position and primary.Position.z or nil,
        stationHull=valid(station) and station.HitpointsMax>0 and station.HitpointsLeft/station.HitpointsMax or nil,
        valueOnPrimary=onBase,valueOnGroups=onGroups,groupCount=#nodes,
        missionCounts=missions,stalledGroups=stalledGroups,worstStallSeconds=worstStall,
        staleOrders=staleOrders,servicedShips=serviced,groups=nodes,
    },now)
end

-- Emitted the instant a command station dies, so an outcome can be explained
-- without replaying the whole battle.
function RTS:EmitOutcomeCause(kind,now)
    local targetName=nil
    if kind=="BLUE" then targetName=self.Config.CarrierShip
    elseif kind=="RED" then targetName=self.Config.EnemyCommandShip
    else targetName=self.Config.ThirdCommandShip end
    local rows=baseDamageRows(self.BaseDamageTelemetry and self.BaseDamageTelemetry.totalByFaction
        and self.BaseDamageTelemetry.totalByFaction[kind] or nil)
    -- A row without targetName is one this emitter cannot attribute, so keep it
    -- rather than silently dropping the evidence.
    local function forThisBase(row) return row.targetName==nil or row.targetName==targetName end
    local total=0
    for _,row in ipairs(rows) do if forThisBase(row) then total=total+(row.hullDamage or 0) end end
    local killers={}
    for _,row in ipairs(rows) do
        if forThisBase(row) then
            killers[#killers+1]={weapon=row.weaponClass,subtype=row.weaponSubtype,
                attackerFaction=row.attackerFaction,source=row.sourceKind,
                beam=row.beamWeapon==true,damageType=row.damageType,
                hullDamage=row.hullDamage,hitCount=row.hitCount,
                share=total>0 and (row.hullDamage or 0)/total or 0}
        end
    end
    table.sort(killers,function(a,b) return (a.hullDamage or 0)>(b.hullDamage or 0) end)
    local snapshot={}
    for _,other in ipairs({"BLUE","RED","GOLD"}) do
        local state=self.AIStates and self.AIStates[other] or nil
        local station=self:GetFactionCommandShip(other)
        snapshot[other]={alive=other~=kind and self:IsFactionEnabled(other) and valid(station) or false,
            commandPoints=(other=="BLUE") and self.CommandPoints or (state and state.cp) or 0,
            stationHull=valid(station) and station.HitpointsMax>0 and station.HitpointsLeft/station.HitpointsMax or 0,
            eliminated=other=="BLUE" and self.BlueEliminated or (other=="RED" and self.RedEliminated) or (other=="GOLD" and self.GoldEliminated) or false}
    end
    self:EmitAIEvent('OUTCOME_CAUSE',{
        faction=kind,targetName=targetName,time=now,
        elapsed=now-(self.ScenarioStartTime or now),
        totalAttributedHullDamage=total,killers=killers,snapshot=snapshot,
    },now)
end

function RTS:CommitAIGroup(g,target,mission,station,context,now,force)
    -- PrepareAIGroups normally decides this and owns the sampling counter.
    -- Re-deriving the flag here would advance that counter a second time and
    -- halve the effective rate for groups routed through both paths.
    --
    -- The fallback exists because PrepareAIGroups and CommitAIGroup are only
    -- ordered by convention: every production caller (UpdateFactionStrategicPlan)
    -- prepares first, but a group arriving without a prepared flag would
    -- otherwise silently lose DetailedDecisionTelemetry - a flag that used to be
    -- honoured here regardless of how the group got here. The fallback
    -- deliberately does NOT advance the sampling counter, so the 1-in-N rate
    -- stays exact whether or not it is taken.
    local includeDecisionDetails
    if g.recordCandidates~=nil then
        includeDecisionDetails=g.recordCandidates
    else
        includeDecisionDetails=self.CombatTelemetryEnabled and self.Config.AI.DetailedDecisionTelemetry==true
    end
    if includeDecisionDetails then g.candidates=g.candidates or {} else g.candidates=nil end
    -- Adds a scored objective to the recorded ranking, once.
    --
    -- Identity, not signature: the retain path rebinds `chosen` to the row
    -- scored for the incumbent, so the SAME table would otherwise be appended
    -- twice, while the row scored for the challenger - the option actually
    -- rejected - would never be appended at all. The candidate set then held the
    -- incumbent twice and no entry for the challenger, which is the row a reader
    -- needs most. The set has to be a set.
    local function appendCandidate(list,row)
        if list==nil or row==nil then return end
        for _,existing in ipairs(list) do if existing==row then return end end
        list[#list+1]=row
    end
    local lead=g.units[1]; local previous=self.AIOrderState[sig(lead)]
    local primarySignature=context.assaultPrimarySignature
    local assaultStartedAt=now
    if previous and (previous.mission=='PRIMARY' or previous.mission=='REGROUP')
        and (previous.assaultPrimarySignature==nil or previous.assaultPrimarySignature==primarySignature) then
        assaultStartedAt=previous.assaultStartedAt or previous.assignedAt or now
    end
    local old=previous and self:FindShipBySignature(previous.targetSignature)
    local chosen=self:ScoreAIObjective(g,target,mission,context,nil,includeDecisionDetails)
    -- The row scored for the objective THIS decision proposed, kept so it can be
    -- recorded even when the retain gate throws it away. See appendCandidate.
    local challengerCandidate=chosen
    -- DECISION.score is the score of the objective the group was actually
    -- committed to. On a RETAINED decision that is the INCUMBENT's score, not
    -- the challenger's: line ~632 rebinds chosen=current before the record is
    -- built. Capture the challenger's own score here, before any rebind, so the
    -- record can carry both and name which one `score` is. Read naively the old
    -- record inverts the explanation of every retention - a tool reports the AI
    -- "choosing" a sentry by quoting the score of the capital it declined to
    -- leave. `score` keeps its meaning (the committed objective's score) so the
    -- four analysis tools stay valid; `scoreIsChallenger` says whether that
    -- committed objective is also the one this decision proposed.
    local challengerScore=chosen.score
    local age=previous and now-previous.assignedAt or 0; local switchingCost=doctrine(self).ObjectiveSwitchCost or 25
    local emergency=context.emergency==true; local retained=false; local reason=chosen.reason
    local observation=self.AIObservations and self.AIObservations[sig(lead)]
    local stale=observation and observation.stalled and observation.objective==sig(old)
    local changedFront=previous and previous.mission=='PRIMARY' and mission=='PRIMARY'
        and self:IsCommandStation(old) and sig(target)==primarySignature and sig(old)~=primarySignature
    -- OPERATION MEMBERSHIP COMMITMENT. Off unless
    -- Station.AI.Doctrine.OperationCommitmentEnabled, so this block is inert by
    -- default.
    --
    -- ApplyAIOperationOrder (fs2rts_operations.lua:257) sets context.locked=true
    -- for every operation member it does not explicitly release, and the gate
    -- below requires `not context.locked`. Measured, that makes
    -- MinimumCommitmentSeconds dead code for the 67% of decisions that are
    -- operation members: the operation re-derives a target from
    -- ChooseAIOperationTarget every StrategicOrderInterval and the group's
    -- target follows whichever defender last scored highest, which is the
    -- mechanism behind 23,686 order transitions at 15.3 s/order in the broken
    -- batch against 6,495 at 22.8 s in the baseline.
    --
    -- This exemption is deliberately narrow. It applies only when the mission is
    -- UNCHANGED, so the phase machine (ASSEMBLE -> APPROACH -> ENGAGE ->
    -- EXPLOIT -> WITHDRAW) keeps its exact cadence and a reserve release,
    -- flank pin, lure or preemption dispatch is never delayed. It still
    -- requires the old target to be live, hostile and scoring, so a dead or
    -- superseded objective is dropped immediately.
    local operationCommit=0
    if context.operation and previous and previous.mission==mission and mission~=""
        and doctrine(self).OperationCommitmentEnabled==true then
        operationCommit=doctrine(self).OperationCommitmentSeconds or 24
    end
    -- A destroyed ship can remain a valid engine handle long enough for the
    -- native order cache to retain it. Dead targets must be released so a
    -- decoy can safely fall back to the primary objective (and defenders can
    -- immediately move to the next live threat).
    if previous and valid(old) and health(old)>0
        and (self:AreEnemies(lead,old) or self:GetFactionKey(old)==self:GetFactionKey(lead))
        and (previous.targetSignature~=sig(target) or previous.mission~=mission)
        and not emergency and (not context.locked or operationCommit>0)
        and not context.localEngageOverride and not changedFront then
        local current=self:ScoreAIObjective(g,old,previous.mission,nil,nil,includeDecisionDetails)
        appendCandidate(g.candidates,current)
        local validCurrent=current.score>0 and not stale
        if previous.mission=='INTERCEPT' and distance(lead,old)>self.Config.AI.LocalEngageRadius*1.5 then validCurrent=false end
        if previous.mission=='RETREAT' or previous.mission=='REGROUP' then validCurrent=false end
        local hold=math.max(doctrine(self).MinimumCommitmentSeconds or 8,operationCommit)
        if validCurrent and (age<hold or chosen.score<current.score+switchingCost) then
            target=old; mission=previous.mission; chosen=current; retained=true
            reason=operationCommit>0 and 'OPERATION_RETAINED' or 'OBJECTIVE_RETAINED'
        end
    end
    if stale and not retained then reason='OBJECTIVE_NO_PROGRESS' end
    if changedFront then reason='CAMPAIGN_FRONT_CHANGED' end
    g.target=target; g.mission=mission; g.reason=reason
chosen.reason=reason
    -- Record BOTH sides of the comparison. On a retained decision `chosen` is
    -- the incumbent's row and the proposed objective's own row is only reachable
    -- through challengerCandidate, so without this the ranking would omit the
    -- rejected option entirely. appendCandidate dedupes, so a non-retained
    -- decision still records its winner exactly once.
    appendCandidate(g.candidates,challengerCandidate)
    appendCandidate(g.candidates,chosen)
    -- Annotate the recorded ranking so one record answers "what did it choose,
    -- what else was on the table, and by how much". class and role are the
    -- candidate target's, resolved here because ScoreAIObjective scores by
    -- signature and does not otherwise carry the hull's identity into the row.
    --
    -- The roster vocabulary (tier, cost, selectionWeight, probability) belongs
    -- to the production picker in fs2rts_ai_production.lua and is NOT emitted
    -- here: objective scoring is deterministic, not a weighted draw, so those
    -- numbers would be invented. AI_BUILD_DECISION already carries the real
    -- ones. `selected` marks the committed objective; on a retained decision
    -- that is the incumbent, which is why scoreIsChallenger is false there.
    --
    -- candidateCountTotal is the size of the UNTRUNCATED set. The list itself is
    -- only the candidates this decision path scored, so a consumer must not read
    -- a short list as "the AI considered nothing else".
    if g.candidates then
        local committed=sig(target)
        for _,candidate in ipairs(g.candidates) do
            local signature=type(candidate.target)=='number' and candidate.target or nil
            local candidateTarget=signature~=nil and self:FindShipBySignature(signature) or nil
            if valid(candidateTarget) then
                candidate.class=candidateTarget.Class and candidateTarget.Class.Name or nil
                candidate.role=self:GetShipRole(candidateTarget)
            end
            candidate.selected=signature~=nil and signature==committed or false
        end
    end
    local candidateCountTotal=g.candidates and #g.candidates or 0
    local ids={}; local results={}
    local orderLabel='AI '..(context.reason or mission):gsub('_',' ')..': '..(context.destination and context.operationTargetName or target.Name)
    local formationSlots=context.destination and self:BuildAIFormationSlots(g,mission,context) or nil
    for _,ship in ipairs(g.units) do
        local id=sig(ship); ids[#ids+1]=id; local state=self.AIOrderState[id]
        self.AIStats.decisions=self.AIStats.decisions+1
        local point=formationSlots and formationSlots[id] or context.destination
        local options=context
        if point~=context.destination then options=setmetatable({destination=point},{__index=context}) end
        local samePoint=not point and not (state and state.destination)
            or point and state and state.destination and point:getDistance(state.destination)<100
        if not force and state and state.targetSignature==sig(target) and state.mission==mission
            and samePoint and state.subsystemIndex==context.subsystemIndex then
            self.AIStats.retained=self.AIStats.retained+1; results[tostring(id)]='ORDER_UNCHANGED'
        else
            local ok=self:IssueStrategicOrder(ship,target,orderLabel,mission,now,force,options)
            results[tostring(id)]=ok and 'ORDER_ACCEPTED' or 'ORDER_REJECTED'
        end
        state=self.AIOrderState[id]
        if state and state.targetSignature==sig(target) and state.mission==mission then
            state.label=orderLabel
            state.reason=reason; state.score=chosen.score; state.confidence=chosen.confidence
            state.group=g.id; state.role=g.role; state.posture=context.posture; state.protected=context.protected
            state.emergency=emergency; state.switchingCost=switchingCost
            state.operation=context.operation; state.operationPhase=context.operationPhase
            state.feintUntil=context.feintUntil or (mission=='FEINT' and state.feintUntil) or nil
            state.feintTargetSignature=context.feintTargetSignature
                or (mission=='FEINT' and sig(target)) or nil
            state.lureUntil=mission=='LURE' and (context.lureUntil or state.lureUntil) or nil
            -- Native orders may change between PRIMARY and REGROUP. Their
            -- assignedAt timestamps cannot also measure one assault's age.
            local assaultPhase=primarySignature and (mission=='PRIMARY' or mission=='REGROUP')
            state.assaultPrimarySignature=assaultPhase and primarySignature or nil
            state.assaultStartedAt=assaultPhase and assaultStartedAt or nil
        end
    end
    -- Group geometry and the command-arena frame. Without these the telemetry
    -- records what each group decided but not where it was, so no location or
    -- behavioural heat map can be reconstructed from a headless run.
    local centroidX,centroidZ,count=0,0,0
    for _,ship in ipairs(g.units or {}) do
        if shipAlive(ship) and ship.Position then
            centroidX=centroidX+ship.Position.x; centroidZ=centroidZ+ship.Position.z; count=count+1
        end
    end
    if count>0 then centroidX=centroidX/count; centroidZ=centroidZ/count end
    local arena=self.GetCommandArenaHalfExtent and self:GetCommandArenaHalfExtent() or nil
    -- No IsAITraceActive() guard here, deliberately. The record is consumed by
    -- anything that intercepts EmitAIEvent - a test sink replaces it with a
    -- function and asserts on the geometry fields, and test_service.py does the
    -- same. Gating construction on "will this reach disk" is therefore wrong:
    -- the consumer is not always the file. The ~40 field writes are cheap next
    -- to the per-frame ship scans elsewhere; the real cost was in the emitters
    -- that walk the world to build discarded rows, not in this literal.
    local record={faction=self:GetFactionKey(lead),group=g.id,ships=ids,role=g.role,posture=context.posture,target=sig(target),mission=mission,
        reason=reason,emergency=emergency,previousAge=age,switchingCost=switchingCost,score=chosen.score,
        -- `score` above is the COMMITTED objective's score. On a retained
        -- decision that is the incumbent, and the rejected challenger's score
        -- is a different number. Publishing both is what lets the replay tool
        -- print an honest margin instead of inverting the explanation.
        -- scoreIsChallenger=false marks the retained case; true means the
        -- committed objective is also the one this decision proposed.
        challengerScore=challengerScore,scoreIsChallenger=not retained,
        operation=context.operation,operationPhase=context.operationPhase,subsystem=context.subsystemIndex,
        targetName=valid(target) and target.Name or nil,
        targetClass=valid(target) and target.Class.Name or nil,
        targetFaction=valid(target) and self:GetFactionKey(target) or nil,
        targetRole=valid(target) and self:GetShipRole(target) or nil,
        assaultReserved=g.assaultReserved==true,localEngageOverride=context.localEngageOverride==true,
        localThreatSignature=valid(g.localThreat) and sig(g.localThreat) or nil,
        localThreatDistance=valid(g.localThreat) and distance(lead,g.localThreat) or -1,
        localThreatSource=g.localThreatSource,hardLocalThreat=g.hardLocalThreat==true,
        bomberTargeterSignature=valid(g.targetedBy) and sig(g.targetedBy) or nil,
        escortBomber=g.escortBomber==true,luring=g.luring==true,
        capitalSuppression=g.capitalSuppression==true,
        -- Set only when ApplyAssaultObjectiveLock (fs2rts_strategy.lua) actually
        -- vetoed a diversion, so it is absent on every record when the doctrine
        -- flags are off - the same "absent means off" convention the candidate
        -- fields below use. Carries the rejected signature, the station it was
        -- held back to, and the two measurements that decided it, so a batch can
        -- be partitioned into reactive / corridor / neither without re-running.
        assaultLock=g.assaultLock,
        candidates=g.candidates,results=results,spread=g.spread,protected=context.protected or -1,
        -- Size of the untruncated candidate set, so a sampled list is honestly
        -- labelled as partial rather than read as "nothing else was on the
        -- table". candidateSampleEvery=0 means the list is not sampled: it is
        -- complete, because DetailedDecisionTelemetry is on.
        --
        -- Both are emitted ONLY when a candidate list was actually recorded.
        -- Publishing them unconditionally cost 1.51 MB/match (3.4% of total
        -- telemetry volume, measured on instrfix-a1) to say "absent" on 17,805
        -- records per match. A default-off flag that costs nothing when off is
        -- worth more than an explicit false on every record: with the flag off,
        -- candidates is absent from EVERY decision, so "no candidate data in
        -- this batch" is already unambiguous without a per-record marker.
        candidateCountTotal=includeDecisionDetails and candidateCountTotal or nil,
        candidateSampleEvery=includeDecisionDetails
            and ((self.Config.AI.DetailedDecisionTelemetry~=true)
                and self.Config.AI.SampledHeavyDecisionSampleEvery or 0) or nil,
        defenseRetention=g.defenseRetention,
        -- spatial
        unitCount=count,centroidX=centroidX,centroidZ=centroidZ,
        leadX=lead.Position and lead.Position.x or nil,leadZ=lead.Position and lead.Position.z or nil,
        targetX=valid(target) and target.Position and target.Position.x or nil,
        targetZ=valid(target) and target.Position and target.Position.z or nil,
        stationX=station and station.Position and station.Position.x or nil,
        stationZ=station and station.Position and station.Position.z or nil,
        arenaHalfExtent=arena,
        formation=g.formation or self:ChooseAIFormation(g.role,mission),
        slotCount=g.slotCount}
    self:EmitAIEvent('DECISION',record,now)
    if previous==nil or previous.mission~=mission
        or (reason=='CAPITAL_THREAT_PREEMPTION' and previous.targetSignature~=sig(target)) then
        if mission=='FEINT' or mission=='LURE' or mission=='TRAP'
            or reason=='CAPITAL_THREAT_PREEMPTION' then
            self:EmitAIEvent('TACTIC',{faction=self:GetFactionKey(lead),group=g.id,role=g.role,
                mission=mission,target=sig(target),reason=reason,
                targetName=valid(target) and target.Name or nil,
                targetClass=valid(target) and target.Class.Name or nil,
                targetRole=valid(target) and self:GetShipRole(target) or nil,
                targetDistance=valid(target) and distance(lead,target) or nil,
                forceRatio=g.lureForceRatio or nil},now)
        end
    end
    return mission
end

function RTS:GetNativeObjectiveStatus(ship,state)
    local native=ship.Target; local target=self:FindShipBySignature(state.targetSignature)
    if not valid(target) then return 'TARGET_INVALID',false end
    if state.subsystemIndex then
        local sub=target[state.subsystemIndex]
        if not sub:isValid() or sub.HitpointsLeft<=0 then return 'OBJECTIVE_COMPLETE',false end
    end
    if state.destination then
        if ship.Position:getDistance(state.destination)<=(state.arrivalDistance or 900) then return 'OBJECTIVE_COMPLETE',true end
        local entry=self.MoveWaypoints[sig(ship)]
        local orders=ship.Orders
        for i=1,#orders do
            if orders[i]:isValid() and orders[i]:getType()==ORDER_WAYPOINTS_ONCE
                and entry and sig(orders[i].Target)==sig(entry.waypoint) then return 'NATIVE_MOVEMENT_GOAL',true end
        end
        return 'NATIVE_ORDER_PREEMPTED',false
    end
    -- A pursuit is the same ORDER_WAYPOINTS_ONCE primitive aimed at the pooled
    -- move waypoint, but issued by IssuePursuitOrder (fs2rts_strategy.lua:144)
    -- instead of the destination branch, so state.destination stays nil and
    -- state.pursuitAt marks it. Without this branch the order fell through to
    -- the hostile path below, which expects ORDER_ATTACK, never matched, and
    -- reported NATIVE_ORDER_PREEMPTED every single cycle. That is a permanent
    -- false positive: ValidateStrategicOrderTargets reads that status as
    -- "preempted" and force-reissues the order (the `local repair=` clause in
    -- ValidateStrategicOrderTargets, fs2rts_strategy.lua) on every
    -- NativeTargetRepairInterval, fighting RefreshAIPursuit for the same goal
    -- and inflating the NATIVE_ORDER_PREEMPTED mismatch count in SummarizeAI.
    if state.pursuitAt then
        local entry=self.MoveWaypoints and self.MoveWaypoints[sig(ship)]
        if valid(entry and entry.waypoint) then
            if ship.Position:getDistance(entry.waypoint.Position)<=(state.arrivalDistance or 900) then
                return 'OBJECTIVE_COMPLETE',true
            end
            local orders=ship.Orders
            local orderCount=orders and #orders or 0
            for i=1,orderCount do
                if orders[i]:isValid() and orders[i]:getType()==ORDER_WAYPOINTS_ONCE
                    and sig(orders[i].Target)==sig(entry.waypoint) then return 'NATIVE_MOVEMENT_GOAL',true end
            end
        end
        -- No waypoint order installed. RefreshAIPursuit re-anchors on its own
        -- cadence, so this is a gap between anchors, not a preemption: report
        -- the goal as absent without telling the repair path to reissue it.
        return 'NATIVE_MOVEMENT_PENDING',false
    end
    local goalPresent=nil
    local hostile=self:AreEnemies(ship,target)
    local movement=state.mission=='RETREAT' or state.mission=='LURE'
    local expected=hostile and ORDER_ATTACK or (movement and ORDER_FLY_TO or ORDER_GUARD)
    local ok=pcall(function()
        local orders=ship.Orders
        if orders then
            goalPresent=false
            for i=1,#orders do
                local order=orders[i]
                if order:isValid() and sig(order.Target)==state.targetSignature and order:getType()==expected then
                    if not state.subsystemIndex or (order.TargetSubsystem:isValid()
                        and order.TargetSubsystem.Name==target[state.subsystemIndex].Name) then goalPresent=true; break end
                end
            end
        end
    end)
    if not ok then goalPresent=nil end
    if goalPresent==false then
        if movement and not hostile and state.arrivalDistance
            and distance(ship,target)<=state.arrivalDistance then return 'OBJECTIVE_COMPLETE',false end
        return 'NATIVE_ORDER_PREEMPTED',false
    end
    if not hostile then return movement and 'NATIVE_MOVEMENT_GOAL' or 'NATIVE_GUARD_GOAL',goalPresent end
    if not valid(native) then return 'NATIVE_TARGET_LOST',goalPresent end
    if native:getBreedName()~='Ship' then
        if native:getBreedName()=='Weapon' then
            return native.Team~=ship.Team and ship.Team:attacks(native.Team) and 'NATIVE_POINT_DEFENSE' or 'NATIVE_TARGET_FRIENDLY',goalPresent
        end
        return 'NATIVE_NONSHIP_TARGET',goalPresent
    end
    if sig(native)==state.targetSignature then return 'NATIVE_TARGET_ACQUIRED',goalPresent end
    if not self:AreEnemies(ship,native) then return 'NATIVE_TARGET_FRIENDLY',goalPresent end
    local p=self:AIProfile(ship)
    if distance(ship,native)<=math.max(p.range,doctrine(self).HardEngageRadius or 1800)+(native.Radius or 0) then
        return 'NATIVE_LOCAL_ENGAGEMENT',goalPresent
    end
    return 'PLANNER_TARGET_MISMATCH',goalPresent
end

function RTS:ObserveAIExecution(now)
    if not self.AIStats then self:ResetCoordinatedAI() end
    for _,row in ipairs(self.StrategicThreatSnapshot or {}) do
        local ship=row.ship; local id=sig(ship); local state=self.AIOrderState[id]
        local previous=self.AIObservations[id]; local dt=previous and math.max(0,now-previous.time) or 0
        local target=state and self:FindShipBySignature(state.targetSignature)
        local d=valid(target) and distance(ship,target) or nil
        local p=self:AIProfile(ship); local native=sig(ship.Target)
        local status,goalPresent='NO_OBJECTIVE',nil
        if state then status,goalPresent=self:GetNativeObjectiveStatus(ship,state) end
        local same=previous and previous.objective==(state and state.targetSignature) and previous.assignedAt==(state and state.assignedAt)
        local closing=same and d and previous.distance and (previous.distance-d)/math.max(.001,dt) or 0
        -- A pursuit is ordered to a moving anchor AHEAD of its objective
        -- (IssuePursuitOrder, fs2rts_strategy.lua:144), and RefreshAIPursuit
        -- re-issues that anchor every PursuitRefreshInterval. So the range to
        -- the objective goes flat the moment the pursuer is on the anchor, and
        -- progress judged only on range closure (closing>1) never fires: a
        -- healthy pursuit reads STALLED after NoProgressSeconds, and
        -- CommitAIGroup turns that into reason='OBJECTIVE_NO_PROGRESS' and
        -- refuses to retain the target (below: the `stale`/`validCurrent`
        -- checks), so the planner abandons an objective that is in fact being
        -- pursued. Measure progress against the anchor the AI actually handed
        -- over, and surface both numbers so the pursuit is observable rather
        -- than inferred.
        local pursuitRange,pursuitClosing=nil,0
        if state and state.pursuitAt then
            local entry=self.MoveWaypoints and self.MoveWaypoints[id]
            local waypoint=entry and entry.waypoint
            if valid(waypoint) then
                pursuitRange=distance(ship,waypoint)
                if same and previous.pursuitRange then
                    pursuitClosing=(previous.pursuitRange-pursuitRange)/math.max(.001,dt)
                end
            end
        end
        local hullLoss=previous and math.max(0,previous.hull-ship.HitpointsLeft) or 0
        local inRange=valid(target) and p.range>0 and d<=p.range+(target.Radius or 0)
        local hit=self.AIStats.hits[id]; local recentHit=hit and hit.hostileTime and now-hit.hostileTime<=6 or false
        local objectiveHit=recentHit and state and hit.hostileTarget==state.targetSignature and hit.hostileTime>=state.assignedAt
        local engaged=recentHit or (inRange and native==sig(target))
        local objectiveEngaged=objectiveHit or (inRange and native==sig(target)) or false
        local lastProgress=same and previous.lastProgress or now
        -- Re-anchoring the pursuit is itself forward motion: RefreshAIPursuit
        -- moved the goal to a new intercept point because the pair is still
        -- valid, which is evidence the objective is being pursued rather than
        -- abandoned. Without it a capital holding its anchor on a faster target
        -- never registers progress and is scored stalled.
        local pursuit=self.AIPursuit and self.AIPursuit[id]
        local anchorAdvanced=pursuit and state and state.pursuitAt
            and (pursuit.anchoredAt or 0)>(previous and previous.time or now)
        if closing>1 or pursuitClosing>1 or anchorAdvanced or objectiveHit then
            lastProgress=now
        end
        local stalled=state~=nil and self:AreEnemies(ship,target) and now-lastProgress>(doctrine(self).NoProgressSeconds or 40) and not objectiveEngaged
        local mode=not state and 'IDLE' or state.mission=='LURE' and 'LURING'
            or state.mission=='RETREAT' and 'RETREATING'
            or state.mission=='REGROUP' and 'REGROUPING' or state.mission=='ESCORT' and 'SCREENING'
            or state.mission=='SCREEN' and not self:AreEnemies(ship,target) and 'SCREENING'
            or engaged and 'ENGAGED' or stalled and 'STALLED' or 'APPROACHING'
        local o={time=now,objective=state and state.targetSignature,assignedAt=state and state.assignedAt,
            native=native,status=status,goalPresent=goalPresent,distance=d,closing=closing,hull=ship.HitpointsLeft,
            hullLoss=hullLoss,lastProgress=lastProgress,stalled=stalled,mode=mode,inRange=inRange,
            engaged=engaged,hitObserved=recentHit,
            pursuit=state~=nil and state.pursuitAt~=nil or false,
            pursuitRange=pursuitRange,pursuitClosing=pursuitClosing,anchorAdvanced=anchorAdvanced or false,
            unengaged=(previous and previous.unengaged or 0)+(engaged and 0 or dt),
            sampledSeconds=(previous and previous.sampledSeconds or 0)+dt,
            objectiveEngaged=same and previous.objectiveEngaged or false,
            engagementDelay=same and previous.engagementDelay or nil}
        if objectiveEngaged and state and not o.objectiveEngaged then o.engagementDelay=now-state.assignedAt; o.objectiveEngaged=true end
        if previous and native~=previous.native then self.AIStats.nativeChanges=self.AIStats.nativeChanges+1 end
        self.AIObservations[id]=o
        local kind=self:GetFactionKey(ship)
        self.AIStats.received[kind]=(self.AIStats.received[kind] or 0)+hullLoss
        if not previous or status~=previous.status or mode~=previous.mode then
            self:EmitAIEvent('EXECUTION',{ship=id,faction=kind,target=o.objective or -1,native=native,status=status,
                mode=mode,goalPresent=goalPresent==nil and 'unknown' or goalPresent,distance=d,closing=closing,
                pursuit=o.pursuit,pursuitRange=pursuitRange,pursuitClosing=pursuitClosing,anchorAdvanced=o.anchorAdvanced,
                effectiveRange=p.range,rangeConfidence=p.confidence,hitObserved=recentHit,hullLoss=hullLoss},now)
        end
    end
end

function RTS:RecordAIHit(source,target,sourceKind)
    if not self.Enabled or self.SetupActive or self.PostBattleActive or not valid(source) or not valid(target) then return end
    if source:getBreedName()~='Ship' or target:getBreedName()~='Ship' then return end
    if not self.AIStats then self:ResetCoordinatedAI() end
    local id=sig(source); local hit=self.AIStats.hits[id] or {count=0}
    hit.count=hit.count+1; hit.time=mn.getMissionTime(); hit.target=sig(target)
    if self:AreEnemies(source,target) then
        hit.hostileTime=hit.time; hit.hostileTarget=hit.target
    end
    self.AIStats.hits[id]=hit
    -- Only build the event when a trace can receive it: this runs on every
    -- weapon/beam collision and EmitAIEvent would discard it anyway.
    if self:IsAITraceActive() and not self:AreEnemies(source,target) then
        local objective=self.AIOrderState[id]
        self:EmitAIEvent('FRIENDLY_HIT',{ship=id,target=sig(target),sourceName=source.Name,targetName=target.Name,
            faction=self:GetFactionKey(source),targetFaction=self:GetFactionKey(target),native=sig(source.Target),
            plannerTarget=objective and objective.targetSignature,mission=objective and objective.mission,
            sourceKind=sourceKind or 'UNKNOWN',evidence='weapon contact; resolved damage unknown'})
    end
end

function RTS:SummarizeAI(now)
    if now-(self.AISummaryAt or -100)<(doctrine(self).TelemetrySummarySeconds or 30) then return end
    self.AISummaryAt=now
    local includeUnitDetails=self.Config.AI.DetailedUnitTelemetry==true
    local damageElapsed=math.max(0,now-(self.AIBaseDamageSummaryAt or self.ScenarioStartTime or now))
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local station=self:GetFactionCommandShip(kind)
        if valid(station) then
            local s={faction=kind,composition={},objectives={},defended={},value=0,offense=0,defense=0,reserve=0,
                idle=0,servicing=0,mismatch=0,stalled=0,engaged=0,unengagedSeconds=0,unitSeconds=0,
                combatants=0,replacementValue=0,replacementValueByClass={},
                stationHull=station.HitpointsLeft,stationMax=station.HitpointsMax,received=self.AIStats.received[kind] or 0,
                damageDealt='unknown',stationDamageDealt='unknown',engagementDelaySum=0,engagementSamples=0}
            local previousHull=self.AIBaseHullSamples[kind]
            local attributedDamage=self.BaseDamageTelemetry.intervalByFaction[kind] or newBaseDamageFaction()
            local attributedCombatDamage=self.CombatDamageTelemetry.intervalByFaction[kind] or newCombatDamageFaction()
            s.baseDamageTelemetry={coverage={registeredTarget=self.BaseDamageTelemetry.hookCount>0,
                    hitCountTotal=self.BaseDamageTelemetry.hitCount or 0},
                interval=baseDamageSummary(attributedDamage,damageElapsed),
                cumulative=baseDamageSummary(self.BaseDamageTelemetry.totalByFaction[kind],now-(self.ScenarioStartTime or now))}
            s.combatDamageTelemetry={coverage={registered=self.CombatDamageTelemetry.registered,
                    hitCountTotal=self.CombatDamageTelemetry.hitCount or 0},
                interval=combatDamageSummary(attributedCombatDamage,now-(self.AICombatDamageSummaryAt or self.ScenarioStartTime or now),true)}
-- damageDealt / stationDamageDealt were the string 'unknown' in every
-- FACTION record, so the arms-race and per-faction damage curves could never be
-- computed from a batch. They were then filled from totalByFaction[kind], but
-- that table is keyed by TARGET faction (fs2rts_ai_telemetry.lua:186-188), so
-- the field carried damage this faction RECEIVED. The comment above it claimed
-- the opposite. ai_tactics.py:737 had already noticed and worked around it by
-- deriving dealt from the other two factions, so every "damage bought per ship
-- lost" number was computed by a join the emitter could have published
-- directly.
--
-- Dealt IS computable per faction at this cadence, and cheaply: the byMatchup
-- rows are already built for this very record, and each one carries
-- attackerFaction (fs2rts_ai_telemetry.lua:196). Summing the rows whose
-- attacker is this faction walks exactly the rows already being serialised, so
-- the extra cost is a comparison per row inside a loop that was already paid
-- for. Nothing is estimated and no new cadence is introduced.
--
-- So damageDealt now means dealt, and damageReceived carries the old meaning.
-- Both are emitted rather than renamed: renaming would silently change every
-- saved batch's numbers. Friendly fire is included in dealt, because a faction
-- really does inflict it; self-inflicted hits are attributed to the attacking
-- faction, which is why received and dealt no longer mirror each other.
do
local function totalHull(scope)
if scope==nil then return 0 end
local v=scope.hullDamage or 0
return type(v)=='number' and v or 0
end
-- Hull damage this faction inflicted, from rows keyed by the faction that
-- RECEIVED it. `rows` is the already-built matchup list of the target faction.
--
-- pairs, NOT ipairs: the bucket is keyed by the composite bucket-key string
-- (fs2rts_ai_util.lua:132), so it has no integer part and ipairs walks straight
-- past every row. That is not hypothetical - it shipped as damageDealt=0.0 on
-- all three factions across instrfix-a1 while a fixture using an array-shaped
-- bucket passed.
local function dealtBy(rows,kind)
local total=0
for _,row in pairs(rows or {}) do
if row.attackerFaction==kind then total=total+(row.hullDamage or 0) end
end
return total
end
local function dealtByFaction(telemetry,kind)
local total=0
for targetFaction,scope in pairs(telemetry.totalByFaction or {}) do
if targetFaction~='UNKNOWN' then total=total+dealtBy(scope.matchups,kind) end
end
return total
end
local function dealtByFactionOnBase(telemetry,kind)
local total=0
for _,scope in pairs(telemetry.totalByFaction or {}) do
for _,row in pairs(scope.weapons or {}) do
if row.attackerFaction==kind then total=total+(row.hullDamage or 0) end
end
end
return total
end
s.damageReceived=totalHull(self.CombatDamageTelemetry.totalByFaction[kind])
s.damageDealt=dealtByFaction(self.CombatDamageTelemetry,kind)
s.stationDamageReceived=totalHull(self.BaseDamageTelemetry.totalByFaction[kind])
s.stationDamageDealt=dealtByFactionOnBase(self.BaseDamageTelemetry,kind)
-- Interval figures on the same footing. s.combatDamageTelemetry.interval above
-- only carries THIS faction's received interval; the dealt interval needs the
-- same cross-faction walk, done per interval rather than on the totals.
do
local intervalDealt=0; local intervalReceived=0
for targetFaction,scope in pairs(self.CombatDamageTelemetry.intervalByFaction or {}) do
if targetFaction==kind then intervalReceived=intervalReceived+totalHull(scope) end
if targetFaction~='UNKNOWN' then
-- pairs, not ipairs: see dealtBy above.
for _,row in pairs(scope.matchups or {}) do
if row.attackerFaction==kind then intervalDealt=intervalDealt+(row.hullDamage or 0) end
end
end
end
s.damageDealtInterval=intervalDealt
s.damageReceivedInterval=intervalReceived
end
end
            if previousHull~=nil then
                local sampledHullLoss=previousHull-station.HitpointsLeft
                s.stationHullDelta={observed=true,previous=previousHull,current=station.HitpointsLeft,
                    sampledHullLoss=sampledHullLoss,attributedHullDamage=attributedDamage.hullDamage,
                    residual=sampledHullLoss-attributedDamage.hullDamage}
            else
                s.stationHullDelta={observed=false,reason='no previous base hull sample'}
            end
            self.AIBaseHullSamples[kind]=station.HitpointsLeft
            for _,row in ipairs(self.StrategicThreatSnapshot or {}) do
                local ship=row.ship; local id=sig(ship)
                -- A ship docked in fleet service deliberately holds no strategic
                -- order, because UpdateFactionStrategicPlan excludes serviced
                -- ships from group building for the same reason. Counting those
                -- as idle made a healthy withdrawing fleet look uncommanded, so
                -- track them separately instead.
                local servicing=self.FleetServices~=nil and self.FleetServices[id]~=nil
                if self:GetFactionKey(ship)==kind and not self:IsCommandStation(ship) then
                    local p=self:AIProfile(ship); local o=self.AIObservations[id]; local a=self.AIOrderState[id]
                    s.composition[ship.Class.Name]=(s.composition[ship.Class.Name] or 0)+1; s.value=s.value+p.value
                    local replacement=self:GetStrategicUnitValue(ship,kind)
                    s.combatants=s.combatants+1; s.replacementValue=s.replacementValue+replacement
-- analyze_batch.py reads `combatantValue` for the arms-race curve; the emitter
-- only ever wrote `replacementValue`, so that curve was permanently None. Emit
-- BOTH rather than renaming: renaming would invalidate every saved batch.
s.combatantValue=s.replacementValue
                    s.replacementValueByClass[ship.Class.Name]=(s.replacementValueByClass[ship.Class.Name] or 0)+replacement
                    if a then
                        local key=tostring(a.targetSignature); s.objectives[key]=(s.objectives[key] or 0)+1
                        if a.mission=='PRIMARY' or a.mission=='ESCORT' then s.offense=s.offense+p.value
                        elseif a.mission=='REGROUP' or a.mission=='RETREAT' or a.mission=='LURE' then s.reserve=s.reserve+p.value
                        else s.defense=s.defense+p.value end
                        if a.protected then s.defended[tostring(a.protected)]=(s.defended[tostring(a.protected)] or 0)+1 end
                    elseif servicing then s.servicing=s.servicing+1 else s.idle=s.idle+1 end
                    if o then
                        if includeUnitDetails then
                            -- Local force balance is telemetry only. Sample it at
                            -- the summary cadence instead of rescanning nearby
                            -- ships on every strategic update.
                            local friend,enemy=self:AILocalStrength(ship,ship.Position,
                                doctrine(self).LocalStrengthRadius or 4500,false)
                            o.friendlyValue=friend; o.enemyValue=enemy
                        end
                        s.stalled=s.stalled+(o.stalled and 1 or 0); s.engaged=s.engaged+(o.engaged and 1 or 0)
                        if o.status=='PLANNER_TARGET_MISMATCH' or o.status=='NATIVE_ORDER_PREEMPTED' then s.mismatch=s.mismatch+1 end
                        s.unengagedSeconds=s.unengagedSeconds+o.unengaged; s.unitSeconds=s.unitSeconds+o.sampledSeconds
                        if o.engagementDelay then s.engagementDelaySum=s.engagementDelaySum+o.engagementDelay; s.engagementSamples=s.engagementSamples+1 end
                        if includeUnitDetails then
                            local target=a and self:FindShipBySignature(a.targetSignature)
                            self:EmitAIEvent('UNIT',{ship=id,name=ship.Name,class=ship.Class.Name,faction=kind,observation=o,
                                objective=a or {},baseDistance=distance(ship,station),enemyBaseDistance=valid(self:GetStablePrimaryTarget(kind)) and distance(ship,self:GetStablePrimaryTarget(kind)) or -1,
                                targetHostile=valid(target) and self:AreEnemies(ship,target) or false},now)
                        end
                    end
                end
            end
            local state=self.AIStates and self.AIStates[kind]
            local automaticQueue=state and state.queue or nil
            local manualQueue=kind=='BLUE' and not self.AutoPlayerMode and self.BuildQueue and self.BuildQueue[1] or nil
            local q=automaticQueue or manualQueue
            local option=q and (q.option or q.entry) or nil
            local estimate=q and (q.estimate or (option and self:GetPurchaseEstimate(option.class,option.tier or 1,option.count or q.count or 1))) or nil
            local queuedCount=q and (q.count or (option and option.count) or 1) or 0
            local cap=self:GetFleetCap(kind)
            local queuedUnits=queuedCount
            if kind=='BLUE' and manualQueue then
                for i=2,#(self.BuildQueue or {}) do queuedUnits=queuedUnits+((self.BuildQueue[i].option and self.BuildQueue[i].option.count) or 1) end
            end
            local economyState=self.AIEconomyFlow and self.AIEconomyFlow[kind] or {}
            local scenarioProgress=clamp((now-(self.ScenarioStartTime or now))/math.max(1,(self:GetDurationProfile() or {}).targetSeconds or 1800),0,1)
            local tier=self:GetCurrentEscalationTier(now)
            -- Report the ramp the sim ACTUALLY applied. This used to be a
            -- second, player-shaped copy of the income formula, so CONTEST's
            -- incomeMultiplier was wrong for RED and GOLD by up to 0.85x - the
            -- balance tooling was reading a number the simulation never used.
            local incomeRamp=(kind=='BLUE') and (1+0.10*(tier-1)+0.20*scenarioProgress*scenarioProgress)
                or self:GetAIIncomeRamp(now)
            s.economy={commandPoints=(kind=='BLUE' and self.CommandPoints) or (state and state.cp) or 0,
                baseIncomePerSecond=(state and state.playerEconomy and self.ActiveIncomePerSecond) or (state and state.income) or (kind=='BLUE' and self.ActiveIncomePerSecond) or 0,
                incomeMultiplier=incomeRamp,flow={income=economyState.income or 0,
                    productionSpend=economyState.productionSpend or 0,bounty=economyState.bounty or 0,
                    refund=economyState.refund or 0},fleetCap=cap,combatants=s.combatants,
                committedUnits=s.combatants+queuedUnits,queueDepth=(manualQueue and #(self.BuildQueue or {}) or (automaticQueue and 1 or 0))}
            if q and option then
                local finish=tonumber(q.finishTime) or 0
                s.economy.queue={class=option.class or 'UNKNOWN',role=option.role,tier=option.tier or 1,
                    count=queuedCount,cost=option.cost or (estimate and estimate.cost) or 0,
                    buildSeconds=option.time or (estimate and estimate.time) or 0,
                    queuedAt=q.queuedAt or q.startTime or now,finishAt=finish>0 and finish or nil,
                    remainingSeconds=finish>0 and math.max(0,finish-now) or nil,
                    waitingForCapacity=finish>0 and now>=finish and s.combatants+queuedCount>cap or false,
                    capacityWaitSeconds=q.blockedAt and math.max(0,now-q.blockedAt) or 0}
            end
            local threats,value,urgent=self:GetFactionThreats(kind,station,doctrine(self).ThreatRadius or 6500)
            s.stationThreats=#threats; s.threatValue=value; s.urgent=urgent
            -- Station position, so an offline check can measure where each
            -- faction's capitals actually spawned relative to both bases.
            if station and station.Position then
                s.stationPosition={x=station.Position.x,y=station.Position.y,z=station.Position.z}
            end
            s.plan=self.AIPlanTelemetry[kind]; s.losses=self.AIStats.losses[kind] or {}
            -- Station upgrade levels and the CP already sunk into them.
            -- BuyUpgrade spends through SpendFactionCP (so it lands in
            -- economy.flow.productionSpend) but emits no event of its own, which
            -- left ~10% of productionSpend unattributable from a batch. It is
            -- also the gate on STATION_REPAIR: station.lua only repairs below
            -- ARMOR L2, so a faction that never bought it reports
            -- totalRepaired 0.0 forever, and "the AI never repaired" is
            -- indistinguishable from "station repair is broken". Publishing the
            -- levels lets both questions be answered from telemetry alone.
            local upgradeLevels,upgradeSpend={},0
            local tracks=(self.Config.Station or {}).Tracks or {}
            for _,track in ipairs({'armor','defenses','logistics','command'}) do
                local level=self:GetUpgradeLevel(kind,track)
                upgradeLevels[track]=level
                local costs=(tracks[track] or {}).costs or {}
                for i=1,level do upgradeSpend=upgradeSpend+(tonumber(costs[i]) or 0) end
            end
            s.economy.upgradeLevels=upgradeLevels
            s.economy.upgradeSpend=upgradeSpend
            s.economy.repairUnlocked=upgradeLevels.armor>=2
            -- The running total behind economy.flow, which is an interval zeroed
            -- on the next line. Reading only the intervals loses the spend that
            -- happened after the final FACTION record of a match, so this is
            -- what a total has to be read from.
            local running=(self.AIEconomyFlowCumulative or {})[kind]
            s.economy.flowCumulative={income=0,productionSpend=0,bounty=0,refund=0}
            if running then
                for name,total in pairs(running) do s.economy.flowCumulative[name]=total end
            end
            s.detailedUnitTelemetry=includeUnitDetails
            s.detailedDecisionTelemetry=self.Config.AI.DetailedDecisionTelemetry==true
            self:EmitAIEvent('FACTION',s,now)
            self.AIEconomyFlow[kind]={income=0,productionSpend=0,bounty=0,refund=0}
            self.BaseDamageTelemetry.intervalByFaction[kind]=newBaseDamageFaction()
            self.CombatDamageTelemetry.intervalByFaction[kind]=newCombatDamageFaction()
        end
    end
    self.AIBaseDamageSummaryAt=now
    self.AICombatDamageSummaryAt=now
    self:EmitAIEvent('COUNTERS',{decisions=self.AIStats.decisions,retained=self.AIStats.retained,
        switches=self.AIStats.switches,reissued=self.AIStats.reissued,nativeChanges=self.AIStats.nativeChanges,
        orders=self.AIOrderTelemetry},now)
    self:FlushAITrace()
end

end
