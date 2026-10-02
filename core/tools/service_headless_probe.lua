-- Real waypoint travel, paid hull/missile recovery and service interruption.
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local alive=require('fs2rts_util').shipAlive
local start=R.OnGameplayStart
local file=cf.openFile('service-headless.jsonl','w','data'); assert(file and file:isValid())
local function log(event,data) file:write(U.json({event=event,data=data})..'\n'); file:flush() end
local function v(x,y,z) return ba.createVector(x,y,z) end
local began,ship,home,initial,initialHull,initialAmmo,cp,hitAt,pausedHull,pausedAmmo,seenService,finished,engine
local repairedSubsystems=0
local emit=R.EmitAIEvent
R.EmitAIEvent=function(self,event,data,now)
    if event=='FLEET_SERVICE_WORK' then repairedSubsystems=repairedSubsystems+(data.subsystemRepair or 0) end
    return emit(self,event,data,now)
end
local lastSample=-1
local function quiet(s)
    s:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#s do if s[i]:isTurret() then s[i].TurretLocked=true end end
end
local function init(self)
    start(self); self:EndIntroCinematic(true); self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario()
    self.Config.AI.Enabled=false; self.AutoPlayerMode=false; self.CommandPoints=100000
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do quiet(self:GetFactionCommandShip(kind)) end
    home=self:GetFactionCommandShip('BLUE')
    ship=mn.createShip('Service Medusa',tb.ShipClasses['GTB Medusa'],ba.createOrientation(),home.Position+v(0,0,-7000),home.Team,true)
    assert(alive(ship)); self:EnableFullArsenal(ship)
    ship.HitpointsLeft=ship.HitpointsMax*.35
    for i=1,#ship do
        local sub=ship[i]
        if sub.Name:lower():find('engine') and sub.HitpointsMax>0 then engine=sub; break end
    end
    assert(engine,'native engine subsystem missing')
    engine.HitpointsLeft=engine.HitpointsMax*.50
    assert(#ship.SecondaryBanks>0 and ship.SecondaryBanks[1].AmmoMax>0,'native missile bank missing')
    for i=1,#ship.SecondaryBanks do ship.SecondaryBanks[i].AmmoLeft=0 end
    initial=ship.Position:getDistance(home.Position); initialHull=ship.HitpointsLeft
    initialAmmo=ship.SecondaryBanks[1].AmmoLeft; cp=self.CommandPoints; began=mn.getMissionTime()
    self:InvalidateShipList(); log('SETUP',{hull=initialHull,ammo=initialAmmo,homeDistance=initial,cp=cp})
end
local function step(self)
    local now=mn.getMissionTime(); local elapsed=now-began
    assert(alive(ship),'service ship died in quiet native control')
    self:InvalidateShipList(); self:UpdateFleetServices(now)
    local state=self.FleetServices[ship:getSignature()]
    if state and state.phase=='RETURNING' then
        assert(ship.HitpointsLeft==initialHull and ship.SecondaryBanks[1].AmmoLeft==initialAmmo,'remote recovery before arrival')
    end
    if state and state.phase=='REPAIR_REARM' and not hitAt then
        seenService=true; hitAt=now; ship.HitpointsLeft=ship.HitpointsLeft-ship.HitpointsMax*.05
        engine.HitpointsLeft=engine.HitpointsMax*.25
        pausedHull=ship.HitpointsLeft; pausedAmmo=ship.SecondaryBanks[1].AmmoLeft
        log('DAMAGE_INTERRUPT',{elapsed=elapsed,hull=pausedHull,ammo=pausedAmmo})
    end
    -- Damage is observed on the following service tick; until eight seconds
    -- after that tick, both resources must remain frozen.
    if hitAt and now-hitAt<8 then
        assert(ship.HitpointsLeft==pausedHull and ship.SecondaryBanks[1].AmmoLeft==pausedAmmo,'native damage failed to pause service')
    end
    if elapsed-lastSample>=10 then
        lastSample=elapsed; log('STATE',{elapsed=elapsed,phase=state and state.phase or 'DEFAULT',
            hull=ship.HitpointsLeft,ammo=ship.SecondaryBanks[1].AmmoLeft,cp=self.CommandPoints,
            homeDistance=ship.Position:getDistance(home.Position),orders=#ship.Orders})
    end
    if seenService and not state then
        assert(ship.HitpointsLeft>=ship.HitpointsMax*.90-.01,'native hull recovery incomplete')
        assert(self:GetFleetSubsystems(ship)>=.8999,'native subsystem recovery incomplete')
        assert(repairedSubsystems>0,'station did not perform native subsystem repairs')
        for i=1,#ship.SecondaryBanks do assert(ship.SecondaryBanks[i].AmmoLeft==ship.SecondaryBanks[i].AmmoMax,'native rearm incomplete') end
        assert(self.CommandPoints<cp and self.CommandPoints>0,'service did not spend real faction CP')
        assert(initial-ship.Position:getDistance(home.Position)>3000,'service did not travel physically')
        assert(not self.AIOrderState[ship:getSignature()] or self.AIOrderState[ship:getSignature()].mission~='PRIMARY','stale commander goal survived service')
        log('PASS',{elapsed=elapsed,hull=ship.HitpointsLeft,ammo=ship.SecondaryBanks[1].AmmoLeft,
            spent=cp-self.CommandPoints,subsystemRepair=repairedSubsystems,closed=initial-ship.Position:getDistance(home.Position)})
        finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    elseif elapsed>390 then error('native service did not finish before bounded deadline') end
end
local function guard(fn,self)
    if finished then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then log('FAIL',{error=err}); finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
end
R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
