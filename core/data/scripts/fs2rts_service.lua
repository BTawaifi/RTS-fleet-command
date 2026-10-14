-- Individual survival and finite, paid station fleet services.
local R=require 'fs2rts_state'
local RTS=R
local U=require 'fs2rts_util'
local alive,vec,copyVec,objectValid=U.shipAlive,U.vec,U.copyVec,U.objectValid
local function config(self) return self.Config.Station.FleetService end
local function hull(ship) return ship.HitpointsLeft/math.max(1,ship.HitpointsMax) end
local function reservePad(self,ship,s)
    s.faction=self:GetFactionKey(ship); s.padRadius=ship.Class.Model and ship.Class.Model.Radius or 50
    local used={}
    for _,record in pairs(self.FleetServices or {}) do
        if record~=s and record.faction==s.faction and record.padSlot then used[record.padSlot]=true end
    end
    s.padSlot=1
    while used[s.padSlot] do s.padSlot=s.padSlot+1 end
end
-- Service owns the ship until completion or a fresh command cancels it.
local function servicePriority()
    return 0.97
end
-- Residual rotational velocity from the arrival turn reads as the ship rolling
-- on the pad. Trimmed gently and only while parked or inbound for service.
local function dampSpin(ship)
    pcall(function()
        local rv=ship.Physics and ship.Physics.RotationalVelocity
        if rv~=nil then ship.Physics.RotationalVelocity=vec(rv.x*.75,rv.y*.75,rv.z*.75) end
    end)
end

function RTS:IsFleetServiceShip(ship)
    return alive(ship) and ship.Name~=self.Config.ObserverShip
        and not self:IsCommandStation(ship) and not self:IsStaticDefense(ship)
        and self:GetFactionKey(ship)~=nil
end

function RTS:GetFleetAmmo(ship)
    local banks={}; local low=1
    for _,list in ipairs({ship.PrimaryBanks,ship.SecondaryBanks}) do
        for i=1,#list do
            local b=list[i]
            if b.AmmoMax>0 then banks[#banks+1]=b; low=math.min(low,b.AmmoLeft/b.AmmoMax) end
        end
    end
    return low,banks
end

function RTS:CanStartAmmoService(ship,role)
    -- Bombers and craft without a usable main battery need ordnance to fight.
    -- Otherwise book repair capacity before recalling a healthy ship merely
    -- for missiles: an unlimited queue parked half the fleet behind its base.
    if role=='bomber' then return true end
    local ranges=self:GetShipWeaponRanges(ship)
    if ranges.primary<=0 and ranges.beam<=0 then return true end
    local c=config(self); local kind=self:GetFactionKey(ship); local booked=0
    local function weight(unit)
        local r=self:GetShipRole(unit)
        return (r=='capital' or r=='heavy' or r=='juggernaut') and math.min(2,c.Slots) or 1
    end
    for id in pairs(self.FleetServices or {}) do
        local owner=self:FindShipBySignature(id)
        if alive(owner) and self:GetFactionKey(owner)==kind then booked=booked+weight(owner) end
    end
    return booked+weight(ship)<=c.Slots
end

function RTS:GetFleetSubsystems(ship)
    local systems,lowest,total={},1,0
    for i=1,#ship do
        local sub=ship[i]
        if sub:isValid() and sub.HitpointsMax>0 then
            systems[#systems+1]=sub; total=total+sub.HitpointsMax
            lowest=math.min(lowest,sub.HitpointsLeft/sub.HitpointsMax)
        end
    end
    return lowest,systems,total
end

function RTS:GetFleetLocalThreat(ship)
    local nearest,best=nil,math.huge
    local position=ship.Position; local radius=config(self).DangerRadius
    local px,py,pz=position.x,position.y,position.z
    local faction=self:GetFactionKey(ship); local team=ship.Team
    for _,row in ipairs(self:GetAISpatialCandidates(position,radius)) do
        local other=row.ship
        if alive(other) and other.Name~=self.Config.ObserverShip then
            local distance=self:GetAIContextDistance(row,px,py,pz)
            -- Only a nearer candidate can change the answer. Keep stable tie
            -- order while avoiding IFF/bank reads for the rest of the sphere.
            if distance<=radius and distance<best then
                local profile=row.profile or self:AIProfile(other)
                if profile.armed and distance<=(profile.range or 0)+(ship.Radius or 0)+(other.Radius or 0)+400
                    and self:AIContextEnemies(ship,row,faction,team) then nearest,best=other,distance end
            end
        end
    end
    return nearest
end

function RTS:IsFleetFocusedByHostiles(ship,now)
    local id=ship:getSignature(); local kind=self:GetFactionKey(ship)
    for faction,attackers in pairs((self.AITargetedBy or {})[id] or {}) do
        if faction~=kind then
            for _,attacker in pairs(attackers) do
                if alive(attacker) and self:AreEnemies(ship,attacker)
                    and ship.Position:getDistance(attacker.Position)<=config(self).DangerRadius then return true end
            end
        end
    end
    local hit=self.AIStats and self.AIStats.hits and self.AIStats.hits[id]
    return hit~=nil and hit.hostileTime~=nil
        and now-hit.hostileTime<=(self.Config.AI.Doctrine.FocusEvidenceSeconds or 8)
end

function RTS:GetFleetServiceSummary(kind)
    local active,waiting=0,0
    for id,s in pairs(self.FleetServices or {}) do
        local ship=self:FindShipBySignature(id)
        if alive(ship) and self:GetFactionKey(ship)==kind then
            if s.phase=='REPAIR_REARM' or s.phase=='WAIT_CP' then active=active+1 else waiting=waiting+1 end
        end
    end
    return string.format('SERVICE %d active / %d waiting',active,waiting)
end

function RTS:GetFleetServiceLabel(ship)
    if not alive(ship) then return nil end
    local s=self.FleetServices and self.FleetServices[ship:getSignature()]
    if not s then return nil end
    return string.format('%s: %s | HULL %d%% / AMMO %d%% / SYS %d%%',s.reason:gsub('_',' '),s.phase:gsub('_',' '),
        math.floor(100*hull(ship)),math.floor(100*self:GetFleetAmmo(ship)),math.floor(100*self:GetFleetSubsystems(ship)))
end

function RTS:SetFleetServicePhase(ship,s,phase,now)
    if s.phase==phase then return end
    s.phase=phase
    self:EmitAIEvent('FLEET_SERVICE',{ship=ship:getSignature(),faction=self:GetFactionKey(ship),
        phase=phase,reason=s.reason,visit=s.visit,hull=hull(ship),ammo=self:GetFleetAmmo(ship)},now)
end

function RTS:BeginFleetService(ship,reason,now,manual)
    if self.AftermathActive then return false end
    if not self:IsFleetServiceShip(ship) or self.PossessedSignature==ship:getSignature() then return false end
    if self.IsShipWithdrawing and self:IsShipWithdrawing(ship) then return false end
    self.FleetServices=self.FleetServices or {}
    local id=ship:getSignature()
    if self.FleetServices[id] then
        local current=self.FleetServices[id]
        current.manual=current.manual or manual==true
        if manual then
            local station=self:GetFactionCommandShip(self:GetFactionKey(ship))
            if alive(station) and not current.arrived then
                self:MoveFleetServiceShip(ship,current,self:GetFleetServicePoint(ship,station,nil,current.padApproachX,current.padApproachZ),now,station:getSignature())
            end
        end
        return true
    end
    local station=self:GetFactionCommandShip(self:GetFactionKey(ship))
    if not alive(station) then return false end
    -- Release any prior move lock: FSO needs dynamic AI enabled to evade a
    -- locked missile, and its hit reactions preserve the assigned service goal.
    self:SetShipCommandDiscipline(ship,false)
    local s={reason=reason,started=now,lastUpdate=now,lastHull=ship.HitpointsLeft,
        quietAt=now,lastShields=ship.Shields and ship.Shields.CombinedLeft or 0,ammoCredit={},manual=manual==true,spent=0}
    self.FleetServiceSerial=(self.FleetServiceSerial or 0)+1; s.visit=self.FleetServiceSerial
    if s.manual then
        local hit=self.AIStats and self.AIStats.hits and self.AIStats.hits[id]
        s.quietAt=math.max(now-config(self).QuietSeconds,hit and hit.hostileTime or -math.huge)
    end
    -- Park the prior player order during recovery and restore it on completion.
    local order=self.UserOrders and self.UserOrders[id]
    s.pendingOrder=(order and order.kind~='service') and order or nil
    self.FleetServices[id]=s; self.AIOrderState[id]=nil; self.PolicyApplied[id]=nil
    if self.RecordServiceStart then self:RecordServiceStart(ship,now) end
    reservePad(self,ship,s)
    self:SetFleetServicePhase(ship,s,'RETURNING',now)
    self:SetShipCommandDiscipline(ship,false)
    self:SetShipTurretLock(ship,true)
    if alive(station) then
        s.padApproachX,s.padApproachZ=self:GetServiceApproach(ship,station,self:GetFleetLocalThreat(ship))
        self:MoveFleetServiceShip(ship,s,self:GetFleetServicePoint(ship,station,nil,s.padApproachX,s.padApproachZ),now,station:getSignature())
    end
    return true
end

-- Public. RTS:SetUserOrder only drops the record, which leaves the service waypoint
-- and its cached slot behind; the input layer calls this to genuinely free a ship
-- for a new task before issuing it, then issues the new order normally. Nothing in
-- this file calls it: the service tick must not cancel itself under the player.
function RTS:CancelFleetServiceForShip(ship,keepOrder)
    if not alive(ship) then return false end
    self.FleetServices=self.FleetServices or {}
    local id=ship:getSignature()
    local s=self.FleetServices[id]
    if not s then return false end
    self.FleetServices[id]=nil; self.AIOrderState[id]=nil; self.PolicyApplied[id]=nil
    self:SetShipCommandDiscipline(ship,false); self:SetShipTurretLock(ship,false)
    s.destination=nil; s.destinationAnchor=nil; s.holdSince=nil
    local order=keepOrder or self.UserOrders[id] or s.pendingOrder
    if order then
        self.UserOrders[id]=order
        self:ReissueUserOrder(ship,order)
        return true
    end
    ship:clearOrders()
    return true
end

function RTS:FinishFleetService(ship,s,now)
    local id=ship:getSignature()
    self:SetFleetServicePhase(ship,s,'READY',now)
    if self.RecordServiceFinish then self:RecordServiceFinish(ship,now,s) end
    self.FleetServices[id]=nil; self.AIOrderState[id]=nil; self.PolicyApplied[id]=nil
    self:SetShipCommandDiscipline(ship,false); self:SetShipTurretLock(ship,false)
    self.FleetServiceCooldown[id]=now+config(self).RetrySeconds
    -- Existing manual intent survives automatic self-preservation; explicit
    -- SERVICE ends by handing the ship back to its normal owner.
    local order=self.UserOrders[id]
    if order and order.kind=='service' then self:ClearUserOrder(ship); order=nil end
    -- Hand back whatever the player asked for before the ship was pulled in, so
    -- the round trip is a round trip and not a silent order drop.
    if s.pendingOrder then order=s.pendingOrder; self.UserOrders[id]=order end
    ship:clearOrders()
    if self:GetFactionKey(ship)=='BLUE' then
        if order then self:ReissueUserOrder(ship,order) else self:ReturnToDefaultControl(ship) end
    else self:AssignAIStrategicOrder(ship,self:GetFactionKey(ship),true) end
end

-- A station's far side is a rally/service point, not its model center.
-- Unit vector FROM the ship TOWARD the station. The pad must sit on the ship's
-- own side of the hull, i.e. station - approach*separation; adding the approach
-- instead places it beyond the station and routes the rearming ship through the
-- hull, which is the rearm-collision bug.
function RTS:GetServiceApproach(ship,station,threat)
    local toStation=station.Position-ship.Position
    local length=math.sqrt(toStation.x*toStation.x+toStation.z*toStation.z)
    local ax,az=0,-1
    if length>.001 then ax,az=toStation.x/length,toStation.z/length end
    -- A threatened pad belongs opposite the attacker's actual bearing, not
    -- merely on whichever half of the station the returning ship occupies.
    if alive(threat) then
        local toThreat=threat.Position-station.Position
        local threatLen=math.sqrt(toThreat.x*toThreat.x+toThreat.z*toThreat.z)
        if threatLen>.001 then
            ax,az=toThreat.x/threatLen,toThreat.z/threatLen
        end
    end
    -- The pad sits behind the station, opposite this side. Near a map edge that point
    -- falls outside the arena, and the clamp then parks every hull on the boundary, so
    -- take the other side when its pad is inside the arena.
    local c=config(self)
    local radius=(station.Class.Model and station.Class.Model.Radius or 500)
        +(ship.Class.Model and ship.Class.Model.Radius or 50)+c.StandOff
    local function padInside(x,z)
        local pad=vec(station.Position.x-x*radius,station.Position.y,station.Position.z-z*radius)
        local bounded=self:ClampCommandPoint(pad,0)
        return bounded~=nil and bounded:getDistance(pad)<=.01
    end
    if not padInside(ax,az) and padInside(-ax,-az) then ax,az=-ax,-az end
    return ax,az
end

function RTS:GetFleetServicePoint(ship,station,threat,approachX,approachZ)
    local c=config(self)
    local shipRadius=ship.Class.Model and ship.Class.Model.Radius or 50
    local stationRadius=station.Class.Model and station.Class.Model.Radius or 500
    local separation=stationRadius+shipRadius+c.StandOff
    if approachX==nil then approachX,approachZ=self:GetServiceApproach(ship,station,threat) end
    local kind=self:GetFactionKey(ship); local record=self.FleetServices and self.FleetServices[ship:getSignature()]
    if record and record.padPoint and record.padStation==station:getSignature() then return record.padPoint end
    local slot=(ship:getSignature()%5)-2; local widest=shipRadius
    if record then
        if not record.padSlot or record.faction~=kind then reservePad(self,ship,record) end
        slot=math.floor(record.padSlot/2)*(record.padSlot%2==0 and -1 or 1)
        for _,other in pairs(self.FleetServices) do
            if other.faction==kind then widest=math.max(widest,other.padRadius or 0) end
        end
    end
    -- Signature modulo slots alias unrelated arrivals. Reserve distinct pads
    -- and allow the largest booked hull enough lateral clearance to park.
    local spread=slot*math.max(180,widest*2.4)
    local point=vec(station.Position.x-approachX*separation-approachZ*spread,station.Position.y,
        station.Position.z-approachZ*separation+approachX*spread)
    if not record then return self:ClampCommandPoint(point,self:GetShipFormationRadius(ship)*1.05) end
    local function reserve(candidate)
        candidate=self:ClampShipDestination(ship,candidate)
        if not candidate then return nil end
        for _,other in pairs(self.FleetServices) do
            if other~=record and other.faction==kind and other.padPoint
                and candidate:getDistance(other.padPoint)<shipRadius+(other.padRadius or 50)+120 then return nil end
        end
        record.padPoint=copyVec(candidate); record.padStation=station:getSignature()
        return record.padPoint
    end
    local reserved=reserve(point)
    if reserved then return reserved end
    -- Edge clamping can compress a lane onto an existing hull. Find a clear
    -- point around the station instead and latch it for the whole visit.
    for ring=1,3 do
        local radius=separation+(ring-1)*math.max(400,shipRadius*2.4)
        for i=0,15 do
            local angle=i*math.pi/8; local ca,sa=math.cos(angle),math.sin(angle)
            reserved=reserve(station.Position+vec((-approachX*ca+approachZ*sa)*radius,0,(-approachZ*ca-approachX*sa)*radius))
            if reserved then return reserved end
        end
    end
    return nil
end

function RTS:MoveFleetServiceShip(ship,s,point,now,anchor)
    if point then point=self:ClampShipDestination(ship,point) end
    if not point then self:SetFleetServicePhase(ship,s,'NO_SAFE_ROUTE',now); return false end
    local slack=math.max(300,self:GetShipFormationRadius(ship)*1.5)
    local drift=not s.destination or s.destinationAnchor~=anchor or point:getDistance(s.destination)>slack
    local intact=false
    local entry=self.MoveWaypoints[ship:getSignature()]
    for i=1,#ship.Orders do
        local order=ship.Orders[i]
        if order:isValid() and order:getType()==ORDER_WAYPOINTS_ONCE and entry
            and objectValid(order.Target) and order.Target:getSignature()==entry.waypoint:getSignature() then intact=true end
    end
    if not drift and intact then return true end
    local waypoint=self:ConfigureMoveWaypoints(ship,point)
    if not objectValid(waypoint) then
        self:SetFleetServicePhase(ship,s,'ORDER_FAILED',now); return false
    end
    ship:clearOrders()
    if ship:giveOrder(ORDER_WAYPOINTS_ONCE,waypoint,nil,servicePriority(self,ship))~=true then
        self:SetFleetServicePhase(ship,s,'ORDER_FAILED',now); return false
    end
    s.destination=copyVec(point); s.destinationAnchor=anchor; s.nextMove=now+8
    self:SetShipCommandDiscipline(ship,false); self:SetShipTurretLock(ship,true)
    return true
end

function RTS:ServiceFleetShip(ship,s,station,now,slots,threat)
    local c=config(self); local dt=math.min(c.TickSeconds*2,math.max(0,now-math.max(s.lastUpdate,s.quietAt+c.QuietSeconds)))
    local readyHull=s.manual and 1 or c.ReadyHull
    s.lastUpdate=now
    local shields=ship.Shields and ship.Shields.CombinedLeft or 0
    local subsystemHull=0
    for i=1,#ship do if ship[i]:isValid() then subsystemHull=subsystemHull+ship[i].HitpointsLeft end end
    if ship.HitpointsLeft<s.lastHull-.01 or shields<(s.lastShields or shields)-.01
        or subsystemHull<(s.lastSubsystemHull or subsystemHull)-.01 then s.quietAt=now end
    s.lastSubsystemHull=subsystemHull
    s.lastShields=shields
    s.lastHull=ship.HitpointsLeft
    if not alive(station) then
        self:SetFleetServicePhase(ship,s,'STATION_LOST',now)
        -- Losing the base must not turn a withdrawal into a dead-target attack.
        if alive(threat) then
            local d=ship.Position-threat.Position; local length=math.max(1,math.sqrt(d.x*d.x+d.z*d.z))
            self:MoveFleetServiceShip(ship,s,self:ClampCommandPoint(ship.Position+vec(d.x/length*3000,0,d.z/length*3000),self:GetShipFormationRadius(ship)*1.05),now,-threat:getSignature())
        end
        return 0
    end
    -- Latch which side of the station the pad is on when the run starts. The
    -- threat bearing is recomputed from a live ship every tick, so without a
    -- latch the pad teleports by twice the separation each time the threat
    -- changes side, and MoveFleetServiceShip sees that as drift and re-orders
    -- the ship mid-approach.
    if s.padApproachX==nil then
        s.padApproachX,s.padApproachZ=self:GetServiceApproach(ship,station,threat)
    end
    local focused=self:IsFleetFocusedByHostiles(ship,now)
    if focused and alive(threat) then
        local approachX,approachZ=self:GetServiceApproach(ship,station,threat)
        if s.padApproachX*approachX+s.padApproachZ*approachZ<.999 then
            -- Rebook the visitor on the station's newly safe side when its
            -- current attacker changes bearing.
            s.padApproachX,s.padApproachZ=approachX,approachZ
            s.padPoint=nil; s.padStation=nil; s.arrived=false; s.holdSince=nil
        end
    end
    local point=self:GetFleetServicePoint(ship,station,threat,s.padApproachX,s.padApproachZ)
    if not point or ship.Position:getDistance(point)>c.ArrivalRadius then
        s.arrived=false
        if not self.Paused then dampSpin(ship) end
        self:SetFleetServicePhase(ship,s,'RETURNING',now)
        self:MoveFleetServiceShip(ship,s,point,now,station and station:getSignature())
        return 0
    end
    local priority=servicePriority(self,ship)
    if not s.arrived then
        -- Physically at the service point (checked above). Hold station there
        -- for the duration of the repair instead of continuing to track a
        -- travel goal, so the hull cannot drift back into the station while
        -- it is being worked on.
        --
        -- ORDER_STAY_STILL is not a brake: the engine's ai_still() only calls
        -- turn_towards_point and never applies longitudinal thrust, and there
        -- is no drag in space, so a hull arriving at cruise coasts at cruise
        -- forever and sails straight back out of the arrival radius. Bleed the
        -- linear velocity off explicitly, and keep bleeding it for a few ticks
        -- so the ship settles instead of oscillating around the pad.
        s.arrived=true; s.holdSince=now; dt=0
        if not s.manual then s.quietAt=now end
        ship:clearOrders()
        local phys=ship.Physics
        if phys~=nil and not focused then phys.Velocity=vec(0,0,0); phys.RotationalVelocity=vec(0,0,0) end
        if ship:giveOrder(ORDER_STAY_STILL,nil,nil,priority)~=true then
            s.arrived=false; s.holdSince=nil; self:SetFleetServicePhase(ship,s,'ORDER_FAILED',now); return 0
        end
    elseif not self.Paused and not focused then
        -- Keep bleeding speed while parked. l_Vector has no scale(), so scale
        -- the components explicitly; Physics.Velocity is the writable property
        -- (phys_info.vel is not exposed to Lua at all).
        local phys=ship.Physics
        if phys~=nil then
            local v=phys.Velocity
            if v~=nil then phys.Velocity=vec(v.x*.35,v.y*.35,v.z*.35) end
        end
    end
    -- A hull being worked on must not be diverted by a stray native order. The
    -- hold is a native order the engine (or anything else touching the ship)
    -- can drop, so re-install it whenever the order list has been taken over.
    --
    -- The old guard was `not atDestination and preempted`. atDestination was
    -- recomputed from the identical test the enclosing arrival check already
    -- made, so it was always true here and the condition was always false: the
    -- re-install was unreachable dead code, and a ship that got an ORDER_ATTACK
    -- while on the pad simply stopped being serviced in place. Position is
    -- irrelevant to this decision - the ship has already arrived, by
    -- construction, at this point in the function.
    local holdIntact=false
    local orders=ship.Orders
    for i=1,#orders do
        local o=orders[i]
        if o~=nil then
            local valid,kind=pcall(function() return o:isValid() and o:getType() or nil end)
            if valid and kind==ORDER_STAY_STILL then holdIntact=true end
        end
    end
    if not holdIntact then
        s.holdSince=now
        ship:clearOrders()
        if ship:giveOrder(ORDER_STAY_STILL,nil,nil,priority)~=true then
            self:SetFleetServicePhase(ship,s,'ORDER_FAILED',now); return 0
        end
    end
    -- Only dampen spin while ship is physically moving to/from service point
    if not self.Paused and not focused and s.phase=='RETURNING' then dampSpin(ship) end
    -- Arrival is physical. Time spent travelling/queued never accumulates repair.
    local ammo,banks=self:GetFleetAmmo(ship)
    local subsystemHealth,systems,totalSubsystemHull=self:GetFleetSubsystems(ship)
    local serviceBlocked=focused or (not s.manual and alive(threat))
    if now-s.started>=c.MinimumRecoverySeconds and hull(ship)>=readyHull-.0001 and ammo>=c.ReadyAmmo and subsystemHealth>=readyHull-.0001
        and now-s.quietAt>=c.QuietSeconds and not serviceBlocked then self:FinishFleetService(ship,s,now); return 0 end
    if now-s.quietAt<c.QuietSeconds or serviceBlocked then
        -- Stay parked and quiet while hostiles focus the visitor. A ship that
        -- remains under fire for the bound returns to combat and gets a retry
        -- delay; manual SERVICE remains the player's decision.
        if serviceBlocked then s.underFireSince=s.underFireSince or now else s.underFireSince=nil end
        if not s.manual and serviceBlocked and now-s.underFireSince>=(c.MaxUnderFireSeconds or 240) then
            self:SetFleetServicePhase(ship,s,'UNDER_FIRE',now)
            local sid=ship:getSignature(); local kind=self:GetFactionKey(ship)
            local parked=self.UserOrders and self.UserOrders[sid]
            self.FleetServices[sid]=nil
            self:SetShipCommandDiscipline(ship,false); self:SetShipTurretLock(ship,false)
            self.AIOrderState[sid]=nil; self.PolicyApplied[sid]=nil
            s.destination=nil; s.destinationAnchor=nil; s.holdSince=nil
            self:EmitAIEvent('FLEET_SERVICE_INTERRUPTED',{ship=sid,faction=kind,
                phase='UNDER_FIRE',reason='UNDER_FIRE_TIMEOUT',
                threat=alive(threat) and threat:getSignature() or nil,
                spent=s.spent,hull=hull(ship)},now)
            self.FleetServiceCooldown[sid]=now+(c.RetrySeconds or 30)
            ship:clearOrders()
            local resume=parked~=nil and parked.kind~='service' and parked or nil
            if resume~=nil then self.UserOrders[sid]=resume end
            if kind=='BLUE' then
                if resume~=nil then self:ReissueUserOrder(ship,resume) else self:ReturnToDefaultControl(ship) end
            else self:AssignAIStrategicOrder(ship,kind,true) end
            return 0
        end
        self:SetFleetServicePhase(ship,s,'UNDER_FIRE',now); return 0
    end
    s.underFireSince=nil
    local role=self:GetShipRole(ship)
    local weight=(role=='capital' or role=='heavy' or role=='juggernaut') and math.min(2,c.Slots) or 1
    if slots<weight then self:SetFleetServicePhase(ship,s,'QUEUED',now); return 0 end
    local value=math.max(1,self:GetStrategicUnitValue(ship,self:GetFactionKey(ship)))
    local budget=self:GetFactionCP(self:GetFactionKey(ship)); local spent=0; local budgetBlocked=false
    local missing=math.max(0,readyHull*ship.HitpointsMax-ship.HitpointsLeft)
    local heal=math.min(missing,ship.HitpointsMax*c.HullPerSecond*dt,budget/value/c.HullCostFraction*ship.HitpointsMax)
    if heal>0 then
        spent=heal/ship.HitpointsMax*value*c.HullCostFraction
        if self:SpendFactionCP(self:GetFactionKey(ship),spent) then ship.HitpointsLeft=ship.HitpointsLeft+heal else heal=0; spent=0 end
    end
    local systemRepair=0
    for _,sub in ipairs(systems) do
        local missingSub=math.max(0,readyHull*sub.HitpointsMax-sub.HitpointsLeft)
        local rate=value*c.SubsystemCostFraction/math.max(1,totalSubsystemHull)
        local amount=math.min(missingSub,sub.HitpointsMax*c.SubsystemPerSecond*dt,self:GetFactionCP(self:GetFactionKey(ship))/rate)
        if amount>0 and self:SpendFactionCP(self:GetFactionKey(ship),amount*rate) then
            sub.HitpointsLeft=sub.HitpointsLeft+amount; spent=spent+amount*rate; systemRepair=systemRepair+amount
        end
    end
    local bankCount=math.max(1,#banks)
    for i,b in ipairs(banks) do
        local want=math.max(0,math.ceil(b.AmmoMax*c.ReadyAmmo)-b.AmmoLeft)
        if want>0 then
            -- Native AmmoLeft is integer; carry fractional rounds only while
            -- actually receiving service, never while travelling or waiting.
            local credit=(s.ammoCredit[i] or 0)+b.AmmoMax*c.AmmoPerSecond*dt
            local cost=value*c.AmmoCostFraction/bankCount/math.max(1,b.AmmoMax)
            local rounds=math.min(want,math.floor(credit),math.floor(self:GetFactionCP(self:GetFactionKey(ship))/cost))
            if math.floor(credit)>0 and rounds==0 then budgetBlocked=true end
            s.ammoCredit[i]=credit-math.floor(credit)
            if rounds>0 and self:SpendFactionCP(self:GetFactionKey(ship),rounds*cost) then
                b.AmmoLeft=b.AmmoLeft+rounds; spent=spent+rounds*cost
            end
        end
    end
    s.spent=s.spent+spent; s.hullRepaired=(s.hullRepaired or 0)+heal; s.lastHull=ship.HitpointsLeft
    s.lastSubsystemHull=subsystemHull+systemRepair
    self:SetFleetServicePhase(ship,s,(budgetBlocked or self:GetFactionCP(self:GetFactionKey(ship))<=.001) and 'WAIT_CP' or 'REPAIR_REARM',now)
    if spent>0 then
        self:EmitAIEvent('FLEET_SERVICE_WORK',{ship=ship:getSignature(),faction=self:GetFactionKey(ship),
            healed=heal,subsystemRepair=systemRepair,spent=spent,totalSpent=s.spent,hull=hull(ship),ammo=self:GetFleetAmmo(ship)},now)
    end
    return weight
end

function RTS:UpdateFleetServices(now)
    if self.AftermathActive then return end
    local c=config(self)
    if now<(self.NextFleetServiceThink or 0) then return end
    self.NextFleetServiceThink=now+c.TickSeconds
    self.FleetServices=self.FleetServices or {}; self.FleetServiceCooldown=self.FleetServiceCooldown or {}
    self.SurvivalDangerSince=self.SurvivalDangerSince or {}
    local ships={}; self:EachShip(function(ship) if self:IsFleetServiceShip(ship) then ships[#ships+1]=ship end end)
    -- One spatial context per service tick, shared with local strength queries.
    local owned=self.StrategicThreatSnapshot==nil
    local function ensureContext()
        if not self.StrategicThreatSnapshot then
            self.StrategicThreatSnapshot=self:BuildStrategicThreatSnapshot()
            self:BuildAIContext(self.StrategicThreatSnapshot)
        end
    end
    local function localThreat(ship)
        ensureContext()
        return self:GetFleetLocalThreat(ship)
    end
    -- Active visits also read targeting evidence when their remembered threat
    -- survives, so they need a fresh context even without a nearest-threat scan.
    if next(self.FleetServices) then ensureContext() end
    local threats={}; local present={}
-- Signatures currently holding a committed base strike inside their own beam
-- reach. Populated during the dispatch loop, read by the outmatched reasons
-- and by HULL_LOW. Local to the pass so a stale entry cannot survive a frame.
local assaultHold={}
    for _,ship in ipairs(ships) do
        local id=ship:getSignature(); present[id]=true
        -- Keep the pad latched, but danger must describe the visitor's current
        -- location; a living attacker elsewhere cannot hold a ready crew here.
        local rec=self.FleetServices[id]
        local hp=hull(ship)
        -- Outmatched recovery requires hull below ReturnHull. Healthy focus
        -- cannot use a strength result; ammo/subsystem admission still samples
        -- danger below before it actually starts service. Active visits always
        -- retain their safety scans.
        local needsDanger=rec~=nil or (self.PossessedSignature~=id and not self.UserOrders[id]
            and hp<c.ReturnHull)
        local threat=nil
        if needsDanger then
            threat=localThreat(ship)
            if rec then rec.threatSignature=threat and threat:getSignature() or nil end
        end
        threats[id]=threat
        if self.PossessedSignature~=id and not rec then
            local ammo=self:GetFleetAmmo(ship)
            local reason
            local pressured=alive(threat)
            local friend,enemy=0,0
            if pressured then friend,enemy=self:AILocalStrength(ship,ship.Position,c.DangerRadius,false,threat) end
            local role=self:GetShipRole(ship)
            local strikeRole=role=='bomber' or role=='capital' or role=='heavy' or role=='juggernaut'
            -- A base's large hull is not evidence that a healthy siege unit
            -- loses its intended matchup. Mobile opposition still triggers
            -- the local force test; damage always triggers recovery.
            local siegeMatchup=strikeRole and pressured and (self:IsCommandStation(threat)
                or self:IsStaticDefense(threat) or self:IsCapitalTarget(threat))
            local outmatched=pressured and not siegeMatchup and enemy>math.max(1,friend)*c.DisadvantageRatio
            -- Does this hull currently hold a committed strike on a station
            -- inside its own reach? Computed here because both the outmatched
            -- reasons below and HULL_LOW further down need the same answer, and
            -- the outmatched test is what the commitment is meant to survive.
            local holding=false
            do
                local doctrine=(self.Config.AI and self.Config.AI.Doctrine) or {}
                if doctrine.AssaultHoldEnabled~=false then
                    local aiOrder=self.AIOrderState and self.AIOrderState[id]
                    if aiOrder and (aiOrder.mission=='PRIMARY' or aiOrder.mission=='ESCORT') then
                        local objective=self:FindShipBySignature(aiOrder.targetSignature)
                        -- isValid presence is checked explicitly: this is a hot
                        -- path and the objective is whatever the AI last recorded,
                        -- so it must not be trusted to be a full engine object.
                        if alive(objective) and type(objective.isValid)=="function" and self:IsCommandStation(objective) then
                            -- Read the PREBUILT profile index, never AIProfile().
                            -- AIProfile walks every bank of every turret of every
                            -- subsystem, so calling it per ship here would rebuild
                            -- the whole strategic picture once per hull per service
                            -- pass. A missing entry simply falls back to the
                            -- configured hold distance.
                            local profile=(self.AIProfileIndex or {})[id]
                            local reach=math.max(doctrine.AssaultHoldDistance or 8000,(profile and profile.range) or 0)
                            holding=ship.Position:getDistance(objective.Position)<=reach
                        end
                    end
                end
            end
            if holding then assaultHold[id]=true end
            local focused=pressured and self:IsFleetFocusedByHostiles(ship,now)
            if outmatched and focused then self.SurvivalDangerSince[id]=self.SurvivalDangerSince[id] or now else self.SurvivalDangerSince[id]=nil end
            local order=self.UserOrders[id]
            local retryReady=now>=(self.FleetServiceCooldown[id] or 0)
            -- Explicit commands own even a critically damaged hull. Automatic
            -- recovery is for unassigned ships; the player chooses SERVICE.
            if not order and hp<=c.CriticalHull and pressured then reason='SELF_PRESERVATION'
        elseif retryReady and not order and focused and outmatched and not assaultHold[ship:getSignature()]
            and hp<c.ReturnHull and enemy>math.max(1,friend)*c.AvoidFightRatio then reason='AVOID_OVERWHELMING_FIGHT'
        elseif retryReady and not order and focused and outmatched and not assaultHold[ship:getSignature()]
            and hp<c.ReturnHull and now-(self.SurvivalDangerSince[id] or now)>=c.DangerSeconds then reason='OUTMATCHED'
            elseif not order and retryReady then
                local aiOrder=self.AIOrderState and self.AIOrderState[id]
                local objective=aiOrder and self:FindShipBySignature(aiOrder.targetSignature)
                -- A committed strike is a real operating regime, not just an
                -- ammo exception. HULL_LOW used to fire at ReturnHull (0.40)
                -- UNPRESSURED, so it was the dominant reason a committed
                -- heavy or juggernaut turned back, and the two outmatched
                -- reasons pulled a committed escort off while its own beams
                -- were already landing. The commitment is GEOMETRIC, not a
                -- timer: inside the range where this hull's own beams reach the
                -- station, retreating throws that damage away. Outside it, the
                -- old thresholds apply unchanged.
                local committedBase=aiOrder and (aiOrder.mission=='PRIMARY' or aiOrder.mission=='ESCORT')
                    and alive(objective) and self:IsCommandStation(objective)
                local ammoThreshold=committedBase and c.CommittedStrikeReturnAmmo or role=='fighter' and c.FighterReturnAmmo or c.ReturnAmmo
                if hp<(holding and c.AssaultHullFloor or c.ReturnHull) then reason='HULL_LOW'
                elseif ammo<ammoThreshold and self:CanStartAmmoService(ship,role) then reason='AMMO_LOW'
                elseif self:GetFleetSubsystems(ship)<c.ReturnHull then reason='SYSTEMS_DAMAGED' end
            end
            if reason and not threat then threat=localThreat(ship); threats[id]=threat end
            if reason and self:BeginFleetService(ship,reason,now,false) then
                local started=self.FleetServices[id]
                if started then started.threatSignature=threat and threat:getSignature() or nil end
            end
        end
    end
    table.sort(ships,function(a,b)
        local sa,sb=self.FleetServices[a:getSignature()],self.FleetServices[b:getSignature()]
        if (sa~=nil)~=(sb~=nil) then return sa~=nil end
        if sa and sb and sa.started~=sb.started then return sa.started<sb.started end
        if sa and sb then
            local pa,pb=self:GetFleetServiceCrewPriority(a,sa),self:GetFleetServiceCrewPriority(b,sb)
            if pa~=pb then return pa>pb end
        end
        return a:getSignature()<b:getSignature()
    end)
    local slots={}
    for _,kind in ipairs(self:GetFactionKeys()) do slots[kind]=c.Slots end
    for _,ship in ipairs(ships) do
        local id=ship:getSignature(); local s=self.FleetServices[id]
        if s and self.PossessedSignature~=id then
            local kind=self:GetFactionKey(ship)
            slots[kind]=slots[kind]-self:ServiceFleetShip(ship,s,self:GetFactionCommandShip(kind),now,slots[kind],threats[id])
        end
    end
    for id in pairs(self.FleetServices) do if not present[id] then self.FleetServices[id]=nil; self.SurvivalDangerSince[id]=nil; self.FleetServiceCooldown[id]=nil end end
    -- Drop the whole AI context, not just the snapshot. BuildAIContext above
    -- repopulated AIShipIndex/AIProfileIndex/AITargetedBy/AISpatialGrid/
    -- AILocalCache from this pass; leaving them set let every reader outside a
    -- strategic window consume a grid and index from an unrelated, up-to-2s
    -- old pass. UpdateAIStrategicObjectives clears the same set the same way.
    if owned then
        self.StrategicThreatSnapshot=nil
        self.AIShipIndex=nil; self.AIProfileIndex=nil; self.AITargetedBy=nil
        self.AISpatialGrid=nil; self.AILocalCache=nil
    end
end

function RTS:GetFleetServiceCrewPriority(ship,service)
    local c=config(self); local role=self:GetShipRole(ship)
    local slots=(role=='capital' or role=='heavy' or role=='juggernaut') and math.min(2,c.Slots) or 1
    local exposure=self:GetCrewExposureEstimate(ship)
    return exposure*math.max(0,(service.manual and 1 or c.ReadyHull)-hull(ship))/math.max(1,slots)
end

function RTS:ServiceSelected()
    local count=0; local now=mn.getMissionTime()
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do
        if self:BeginFleetService(ship,'STATION_SERVICE',now,true) then
            self:SetUserOrder(ship,{kind='service'}); count=count+1
        end
    end
    self:SetStatus(count>0 and ('Returning '..count..' ships for paid station repair/rearm') or 'No selected ships can receive station service',3)
end

return R
