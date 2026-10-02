-- Native movement control: threats use PLAY_DEAD while retaining armed profiles.
local R=require 'fs2rts'; local U=require 'fs2rts_ai_util'; local alive=require('fs2rts_util').shipAlive
local start=R.OnGameplayStart
local file=cf.openFile('survival-headless.jsonl','w','data'); assert(file and file:isValid())
local function log(event,data) file:write(U.json({event=event,data=data})..'\n'); file:flush() end
local function v(x,y,z) return ba.createVector(x,y,z) end
local began,home,critical,outmatched,balanced,initial,critEnemy,finished
local lastSample=-1
local function spawn(name,class,position,team)
    local ship=mn.createShip(name,tb.ShipClasses[class],ba.createOrientation(),position,team,true)
    assert(alive(ship)); assert(ship:giveOrder(ORDER_PLAY_DEAD,nil,nil,.95)==true); return ship
end
local function init(self)
    start(self); self:EndIntroCinematic(true); self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario()
    self.Config.AI.Enabled=false; self.AutoPlayerMode=false; self.CommandPoints=100000
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local base=self:GetFactionCommandShip(kind); base:setFlag(true,'immobile','primaries-locked','secondaries-locked')
        for i=1,#base do if base[i]:isTurret() then base[i].TurretLocked=true end end
    end
    home=self:GetFactionCommandShip('BLUE'); local team=home.Team
    critical=spawn('Critical defender','GTF Hercules',home.Position+v(0,0,-7000),team)
    critical.HitpointsLeft=critical.HitpointsMax*.20
    self:SetUserOrder(critical,{kind='guard',targetSignature=home:getSignature()})
    critEnemy=spawn('Critical threat','GTF Ulysses',critical.Position+v(600,0,0),mn.Teams.hostile)
    critEnemy:setFlag(true,'immobile')
    outmatched=spawn('Isolated fighter','GTF Hercules',home.Position+v(8000,0,8000),team)
    for i=1,3 do local e=spawn('Bad fight '..i,'GTF Hercules',outmatched.Position+v(i*250,0,600),mn.Teams.hostile); e:setFlag(true,'immobile') end
    -- A real recent hostile hit makes the force-disadvantage case actionable;
    -- the enemies otherwise hold PLAY_DEAD and cannot establish focused pressure.
    self.AIStats.hits[outmatched:getSignature()]={hostileTime=mn.getMissionTime(),
        hostileTarget=self:GetFactionCommandShip('RED'):getSignature()}
    balanced=spawn('Balanced fighter','GTF Hercules',home.Position+v(8000,0,-8000),team)
    local fair=spawn('Balanced opponent','GTF Ulysses',balanced.Position+v(600,0,0),mn.Teams.hostile); fair:setFlag(true,'immobile')
    self:SetUserOrder(balanced,{kind='guard',targetSignature=home:getSignature()})
    self:InvalidateShipList(); began=mn.getMissionTime()
    initial=critical.Position:getDistance(home.Position)
    log('SETUP',{criticalHull=critical.HitpointsLeft,initialHomeDistance=initial,combat=false})
end
local function step(self)
    local now=mn.getMissionTime(); local elapsed=now-began
    self:InvalidateShipList(); self:UpdateFleetServices(now)
    assert(alive(critical) and alive(outmatched) and alive(balanced),'movement-control ship unexpectedly lost')
    local c=self.FleetServices[critical:getSignature()]; local o=self.FleetServices[outmatched:getSignature()]
    if elapsed<1 then assert(c and c.reason=='SELF_PRESERVATION','critical defender was exempted') end
    if elapsed<5.9 then assert(not o,'transient contact triggered instant outmatched retreat') end
    if elapsed>=8 and elapsed<12 then assert(o and o.reason=='OUTMATCHED','persistent bad fight did not trigger retreat') end
    assert(not self.FleetServices[balanced:getSignature()],'balanced defender was unnecessarily withdrawn')
    assert(self.UserOrders[critical:getSignature()] and self.UserOrders[critical:getSignature()].kind=='guard','survival discarded defender intent')
    if elapsed-lastSample>=10 then
        lastSample=elapsed; log('STATE',{elapsed=elapsed,criticalPhase=c and c.phase,outmatchedPhase=o and o.phase,
            criticalHomeDistance=critical.Position:getDistance(home.Position),criticalThreatDistance=critical.Position:getDistance(critEnemy.Position)})
    end
    if elapsed>=100 then
        local closed=initial-critical.Position:getDistance(home.Position)
        assert(closed>2000,'critical defender did not physically withdraw toward station')
        assert(critical.Position:getDistance(critEnemy.Position)>2000,'withdrawal did not break contact')
        log('PASS',{elapsed=elapsed,closed=closed,threatDistance=critical.Position:getDistance(critEnemy.Position),
            limitation='Threat AI paused with PLAY_DEAD; decision/movement control, not combat survival rate'})
        finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end
local function guard(fn,self)
    if finished then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then log('FAIL',{error=err}); finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
end
R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
