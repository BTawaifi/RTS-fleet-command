-- AI group roles: local threat choice, transitions, formations and group relations.
return function(RTS, _shared)
local shipAlive, distance, sig, valid, canAutoEngage = _shared.shipAlive, _shared.distance, _shared.sig, _shared.valid, _shared.canAutoEngage

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
                if inRange and canAutoEngage(self,lead,t) and not self:IsCommandStation(t) then
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
            if candidate.distance<=radius and canAutoEngage(self,lead,t) and not self:IsCommandStation(t) then
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
    -- Geometry and pair construction are diagnostic output only. Leave the
    -- sample clock untouched until a real trace/sink can receive the result.
    if not self:IsAITraceActive() then return end
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
end
