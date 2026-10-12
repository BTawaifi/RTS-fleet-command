-- AI planning context: helper locals, automatic-unit checks and the per-tick AI context.
return function(RTS, _shared)
local shipAlive, sig, health, valid = _shared.shipAlive, _shared.sig, _shared.health, _shared.valid

function RTS:IsAutomaticAIUnit(ship)
    local kind=self:GetFactionKey(ship); local id=sig(ship)
    return shipAlive(ship) and kind~=nil and not self:IsCommandStation(ship) and ship.Name~=self.Config.ObserverShip and not self:IsStaticDefense(ship)
        and not (self.FleetServices and self.FleetServices[id])
        and not (self.IsShipWithdrawing and self:IsShipWithdrawing(ship))
        and not (kind=='BLUE' and (not self.AutoPlayerMode or self.PossessedSignature==id or self.UserOrders[id]~=nil))
end

function RTS:BuildAIContext(snapshot)
    self.AIShipIndex={}; self.AIProfileIndex={}; self.AILocalCache={}; self.AITargetedBy={}
    self.AISpatialGrid={}
    local teams,representatives={},{}
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
        if attackerFaction and representatives[attackerFaction]==nil then
            representatives[attackerFaction]=s; teams[attackerFaction]=s.Team
        end
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
        -- Geometry belongs to this synchronous context, just like its grid.
        -- Reuse the native vector handle during the pass; rebuild next tick.
        row.index=index; row.signature=id; row.cellKey=cellKey; row.position=position
        row.coordinates={x=position.x,y=position.y,z=position.z}
        p.radius=s.Radius or 0
        cell[#cell+1]=row
        self.AIProfileIndex[id]=p; row.profile=p
        p.contextRow=row
    end
    -- This pass does not change IFF relations. Evaluate each faction relation
    -- once per row rather than once per local-strength/threat query. Keep live
    -- team checks at use sites so a reassigned hull takes the ordinary path.
    for _,row in ipairs(snapshot) do
        row.team=row.ship.Team; row.contextTeams=teams; row.hostileTo={}
        for faction,representative in pairs(representatives) do
            row.hostileTo[faction]=self:AreEnemies(representative,row.ship)
        end
    end
end

function RTS:AIContextEnemies(ship,row,faction,team)
    local hostile
    if row.hostileTo and team~=nil and row.contextTeams[faction]==team and row.team==row.ship.Team then
        hostile=row.hostileTo[faction]
    end
    if hostile==nil then hostile=self:AreEnemies(ship,row.ship) end
    -- Friendly support cannot become an enemy through extraction or arena
    -- policy; avoid repeating those native geometry reads for friendly pairs.
    if not hostile then return false,false end
    -- Extraction protection is layered over IFF, before a cached relation can
    -- make a withdrawing hull appear eligible for an automatic target.
    local permitted=true
    if self.IsAutomaticTargetPermitted then
        permitted=self:IsAutomaticTargetPermitted(ship,row.ship)
        if permitted and self.IsAutomaticTargetInArena then permitted=self:IsAutomaticTargetInArena(ship,row.ship,row.coordinates or row.position) end
    elseif not (row.hostileTo and team~=nil and row.contextTeams[faction]==team and row.team==row.ship.Team)
        and self.CanAutoEngage then permitted=self:CanAutoEngage(ship,row.ship) end
    return permitted and hostile,hostile
end
end
