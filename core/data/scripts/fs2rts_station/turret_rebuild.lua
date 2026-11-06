-- A destroyed base turret stays down until its owner pays to rebuild it. Rebuilds are
-- their own timed job, one at a time per station, and never occupy the upgrade slot.
local _shared = require "fs2rts_station.common"
local RTS, objectValid, shipAlive, cfg = _shared.RTS, _shared.objectValid, _shared.shipAlive, _shared.cfg

local function heavierFirst(a,b)
    if a.max~=b.max then return a.max>b.max end
    return a.index<b.index
end

-- Turrets with no hull left, heaviest first, plus the largest turret on the station.
local function downedTurrets(station)
    local downed,largest={},0
    for i=1,#station do
        local turret=station[i]
        if objectValid(turret) and turret:isTurret() then
            local max=turret.HitpointsMax or 0
            if max>largest then largest=max end
            if max>0 and (turret.HitpointsLeft or 0)<=0 then downed[#downed+1]={index=i,max=max} end
        end
    end
    table.sort(downed,heavierFirst)
    return downed,largest
end

local function finishRebuild(state,station,job,restoreFraction)
    state.turretRebuild=nil
    local turret=station[job.index]
    if not (objectValid(turret) and turret:isTurret()) then return end
    local restored=turret.HitpointsMax*restoreFraction
    if (turret.HitpointsLeft or 0)<restored then turret.HitpointsLeft=restored end
    state.lastTurretHits[job.index]=turret.HitpointsLeft or 0
end

-- Called from the station sampler. Refreshes the downed list the panel and the AI read,
-- completes a finished job and lets AI factions pay for the next one.
function RTS:SampleStationTurrets(kind,state,station,now)
    state.downedTurrets,state.largestTurret=downedTurrets(station)
    local job=state.turretRebuild
    if job and now>=job.finishTime then finishRebuild(state,station,job,(cfg(self).TurretRebuild or {}).RestoreFraction or .5) end
    local c=cfg(self).TurretRebuild or {}
    if (kind~='BLUE' or self.AutoPlayerMode) and not state.turretRebuild and #state.downedTurrets>0
        and now>=(state.nextTurretBuy or 0) then
        state.nextTurretBuy=now+(c.AIRetrySeconds or 8)
        local offer,reason=self:GetTurretRebuildOffer(kind,now)
        if offer and not reason and self:GetFactionCP(kind)>=offer.cost*(c.AIReserveMultiple or 2) then
            self:BuyTurretRebuild(kind)
        end
    end
end

-- Returns the next rebuild (heaviest downed turret) and a reason when it cannot be bought.
function RTS:GetTurretRebuildOffer(kind,now)
    if self.AftermathActive then return nil,'SURVIVORS ONLY' end
    if not shipAlive(self:GetFactionCommandShip(kind)) then return nil,'DESTROYED' end
    local state=self:GetStationState(kind)
    if state.turretRebuild then return nil,'BUSY' end
    local pick=state.downedTurrets and state.downedTurrets[1]
    if not pick then return nil,'NONE' end
    local c=cfg(self).TurretRebuild or {}
    local share=pick.max/math.max(1,state.largestTurret or pick.max)
    local profile=self:GetEscalationProfile()
    local offer={index=pick.index,count=#state.downedTurrets,
        cost=math.ceil(c.MinCost+(c.MaxCost-c.MinCost)*share),
        seconds=(c.MinSeconds+(c.MaxSeconds-c.MinSeconds)*share)*(profile and profile.buildTimeScale or 1)}
    if self:GetFactionCP(kind)<offer.cost then return offer,'CP' end
    return offer,nil
end

function RTS:BuyTurretRebuild(kind)
    local now=mn.getMissionTime()
    local offer,reason=self:GetTurretRebuildOffer(kind,now)
    if offer==nil or reason~=nil then
        if kind=='BLUE' then
            local msg={BUSY='A turret is already being rebuilt',CP='Insufficient command points',NONE='No turrets are down',
                DESTROYED='Station destroyed'}
            self:SetStatus(msg[reason] or 'Unavailable',2)
        end
        return false
    end
    local station=self:GetFactionCommandShip(kind)
    local turret=station[offer.index]
    if not (objectValid(turret) and (turret.HitpointsLeft or 0)<=0) then return false end
    if not self:SpendFactionCP(kind,offer.cost) then return false end
    self:GetStationState(kind).turretRebuild={index=offer.index,cost=offer.cost,startTime=now,finishTime=now+offer.seconds}
    if kind=='BLUE' then self:SetStatus('Turret rebuild started',2) end
    return true
end
