-- AI target candidates: group targeters, lure pursuers, spatial search, profiles and local strength.
return function(RTS, _shared)
local distance, sig, valid, health, clamp, doctrine, heavyRole, mobileRole = _shared.distance, _shared.sig, _shared.valid, _shared.health, _shared.clamp, _shared.doctrine, _shared.heavyRole, _shared.mobileRole
local canAutoEngage = _shared.canAutoEngage

function RTS:FindAIGroupTargeter(g,kind,radius)
    local best,bestDistance=nil,radius or math.huge
    for _,member in ipairs(g.units or {}) do
        local byFaction=(self.AITargetedBy or {})[sig(member)]
        if byFaction then
            for attackerFaction,attackers in pairs(byFaction) do
                if attackerFaction~=kind then
                    for _,attacker in pairs(attackers) do
                        local d=valid(attacker) and distance(member,attacker) or math.huge
                        if d<=bestDistance and canAutoEngage(self,member,attacker)
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
                        and canAutoEngage(self,bait,attacker)
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

function RTS:GetAIContextDistance(row,x,y,z)
    local p=row.coordinates or row.position or row.ship.Position
    local dx,dy,dz=p.x-x,p.y-y,p.z-z
    return math.sqrt(dx*dx+dy*dy+dz*dz)
end

function RTS:AILocalStrength(ship,point,radius,includeSupport,engagementTarget)
    local supportKey=includeSupport==false and 'LOCAL' or 'SUPPORT'
    local faction=self:GetFactionKey(ship)
    local team=ship.Team
    -- All RTS ships in a faction share the same FSO team/IFF relation. Key by
    -- that relation so every wing scoring the same target reuses one local
    -- strength query; unknown ships retain per-ship isolation.
    local ownerKey=not engagementTarget and faction and ('FACTION:'..faction) or ('SHIP:'..sig(ship))
    if engagementTarget then supportKey=supportKey..':'..sig(engagementTarget) end
    local key=table.concat({ownerKey,point.x,point.y,point.z,radius,supportKey},':')
    local cached=self.AILocalCache and self.AILocalCache[key]
    if cached then return unpack(cached) end
    local friendly,enemy=0,0; local support=math.huge; local ownSignature=sig(ship)
    local ownPosition=engagementTarget and ship.Position
    local targetPosition=engagementTarget and engagementTarget.Position
    local ownRadius=engagementTarget and (ship.Radius or 0)
    local targetRadius=engagementTarget and (engagementTarget.Radius or 0)
    local snapshot=self.StrategicThreatSnapshot or {}
    local px,py,pz=point.x,point.y,point.z
    local ox,oy,oz,tx,ty,tz
    if engagementTarget then
        ox,oy,oz=ownPosition.x,ownPosition.y,ownPosition.z
        tx,ty,tz=targetPosition.x,targetPosition.y,targetPosition.z
    end
    for _,row in ipairs(self:GetAISpatialCandidates(point,radius)) do
        local other=row.ship
        if valid(other) then
            local p=row.profile or self:AIProfile(other)
            local d=self:GetAIContextDistance(row,px,py,pz)
            if d<=radius then
                local hostile,rawHostile=self:AIContextEnemies(ship,row,faction,team)
                -- Stations are fixed support, not offensive mobile fleet value.
                local v=p.value*(p.station and .35 or 1)
                local id=row.signature or sig(other)
                if (self.FleetServices and self.FleetServices[id])
                    or (self.IsShipWithdrawing and self:IsShipWithdrawing(other)) then v=0 end
                if engagementTarget then
                    -- Recovery compares the weapons that can participate now or
                    -- within one danger window. Distant short-range fleet value
                    -- used to scare healthy, locally superior wings off a fight.
                    local reach=(p.range or 0)+(p.radius or other.Radius or 0)+(hostile and ownRadius or targetRadius)
                        +(p.speed or 0)*self.Config.Station.FleetService.DangerSeconds
                    local reachDistance=hostile and self:GetAIContextDistance(row,ox,oy,oz) or self:GetAIContextDistance(row,tx,ty,tz)
                    if not p.armed or reachDistance>reach then v=0 end
                elseif p.range~=nil then
                    -- Nearby value matters only as fast as its weapons can arrive.
                    local reach=(p.range or 0)+(p.radius or other.Radius or 0)
                    local travel=(p.speed or 0)*(doctrine(self).SupportArrivalSeconds or 20)
                    if p.armed==false then v=0
                    elseif d>reach then v=v*clamp((reach+travel-d)/math.max(1,travel),0,1) end
                end
                local friendlyContact=not rawHostile
                if hostile then enemy=enemy+v elseif friendlyContact then friendly=friendly+v end
                -- A friendly inside the search sphere is closer than anything
                -- outside the spatial query's bounding cube.
                if includeSupport~=false and (row.signature or sig(other))~=ownSignature and friendlyContact then
                    support=math.min(support,d)
                end
            end
        end
    end
    if includeSupport~=false and support>radius then
        for _,row in ipairs(snapshot) do
            local other=row.ship
            if valid(other) and (row.signature or sig(other))~=ownSignature then
                local _,hostile=self:AIContextEnemies(ship,row,faction,team)
                if not hostile then support=math.min(support,self:GetAIContextDistance(row,px,py,pz)) end
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
end
