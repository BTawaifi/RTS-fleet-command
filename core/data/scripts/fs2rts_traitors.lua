-- Rare, announced splinter raids. Existing commissioned fleets never change sides.
local R=require 'fs2rts_state'
local U=require 'fs2rts_util'

function R:ResetTraitorRaids()
    self.TraitorRaidCount=0; self.NextTraitorRoll=nil; self.PendingTraitorRaid=nil
    self.TraitorShips={}; self.NextTraitorOrders=0; self.TraitorRandomState=nil
end

function R:TraitorRandom()
    -- Separate subsequent event draws from camera shots and AI production draws.
    local seed=self.TraitorRandomState or self.Config.TraitorRaids.Seed or math.random(1,2147483646)
    self.TraitorRandomState=(seed*16807)%2147483647
    return self.TraitorRandomState/2147483647
end

function R:BeginTraitorRaid(origin,now)
    local c=self.Config.TraitorRaids; local anchor=self:GetFactionCommandShip(origin)
    local team=mn.Teams.Traitor or mn.Teams.traitor
    if self.PendingTraitorRaid or self.TraitorRaidCount>=c.MaxEvents or not U.shipAlive(anchor)
        or not U.objectValid(team) or not team:attacks(anchor.Team) then return false end
    local roster={}; local tier=self:GetCurrentEscalationTier(now)
    for _,entry in ipairs(self:GetAIRoster(origin)) do
        if (entry.role=='fighter' or entry.role=='bomber') and (entry.tier or 1)<=tier
            and self.ShipCostMap[entry.class] then roster[#roster+1]=entry end
    end
    if #roster==0 then return false end
    local entry=roster[math.floor(self:TraitorRandom()*#roster)+1]
    local count=self:TraitorRandom()<c.WingChance and c.WingSize or 1
    self.PendingTraitorRaid={origin=origin,class=entry.class,count=count,arriveAt=now+c.WarningSeconds}
    self.TraitorRaidCount=self.TraitorRaidCount+1
    self:ShowAnnouncement('TRAITOR SIGNAL // '..self:GetFactionDisplayName(origin)..' // HOSTILE WARP IN '..c.WarningSeconds..'s',c.WarningSeconds,'TRAITOR')
    self:EmitAIEvent('RANDOM_EVENT',{kind='TRAITOR_WARNING',origin=origin,count=count,class=entry.class,arriveAt=now+c.WarningSeconds},now)
    return true
end

function R:UpdateTraitorRaids(now)
    local c=self.Config.TraitorRaids
    if not c.Enabled or self.SetupActive or self.CinematicActive or self.Paused or self.PostBattleActive
        or self.AftermathActive or self.StrategicResult or not self.ScenarioStartTime then return end
    local pending=self.PendingTraitorRaid
    if pending and now>=pending.arriveAt then
        self.PendingTraitorRaid=nil
        local anchor=self:GetFactionCommandShip(pending.origin); local team=mn.Teams.Traitor or mn.Teams.traitor
        local created={}; local batch=self.TraitorRaidCount
        if U.shipAlive(anchor) and U.objectValid(team) then
            for i=1,pending.count do
                local unit=self:SpawnFactionUnit(pending.class,anchor,team,'TRAITOR',self.TraitorRaidCount,i,0,i,pending.count,
                    'TRAITOR '..pending.origin..' '..self.TraitorRaidCount..'-'..i,batch,created)
                if U.shipAlive(unit) then
                    local record=self:GetUnitHistory(unit); if record then record.traitorOrigin=pending.origin end
                    self.TraitorShips[unit:getSignature()]={origin=pending.origin}
                end
            end
        end
        self:ShowAnnouncement(#created>0 and ('HOSTILE TRAITORS // '..pending.origin..' // '..#created..' SHIPS') or 'TRAITOR SIGNAL LOST // NO ARRIVAL',6,'TRAITOR')
        self:EmitAIEvent('RANDOM_EVENT',{kind='TRAITOR_ARRIVAL',origin=pending.origin,spawnedCount=#created},now)
    end
    local elapsed=now-self.ScenarioStartTime
    if not self.PendingTraitorRaid and self.TraitorRaidCount<c.MaxEvents and elapsed>=(self.NextTraitorRoll or c.DelaySeconds) then
        self.NextTraitorRoll=elapsed+c.IntervalSeconds
        local living=self:GetLivingFactionKeys()
        if #living>=2 and self:TraitorRandom()<c.Chance then
            self:BeginTraitorRaid(living[math.floor(self:TraitorRandom()*#living)+1],now)
        end
    end
    if now<self.NextTraitorOrders then return end
    self.NextTraitorOrders=now+2
    for signature,raid in pairs(self.TraitorShips) do
        local unit=self:FindShipBySignature(signature)
        if not U.shipAlive(unit) then self.TraitorShips[signature]=nil
        else
            local best,score
            for _,target in ipairs(self:GetShipList()) do
                if U.shipAlive(target) and target.Name~=self.Config.ObserverShip and self:CanAutoEngage(unit,target) then
                    local distance=unit.Position:getDistance(target.Position)
                    local rank=(self:GetFactionKey(target)==raid.origin and 0 or 1000000)+distance
                    if not score or rank<score then best,score=target,rank end
                end
            end
            if best and raid.target~=best:getSignature() then
                unit:clearOrders()
                if unit:giveOrder(ORDER_ATTACK,best,nil,.8) then raid.target=best:getSignature() end
            end
        end
    end
end

return R
