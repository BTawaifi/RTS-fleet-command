-- Opt-in native contract probe for an isolated headless copy. Never load in play.
-- The emergency contact is injected into the observed-hit cache; this tests
-- allocation with real ships, not whether the beam physically hits the base.
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local start=R.OnGameplayStart; local stationThink=R.UpdateStationAI
local file=cf.openFile('coordination-contracts.jsonl','w','data'); assert(file and file:isValid())
local function log(event,data) file:write(U.json({event=event,data=data})..'\n'); file:flush() end
local function v(x,y,z) return ba.createVector(x,y,z) end
local function quiet(s)
    s:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#s do if s[i]:isTurret() then s[i].TurretLocked=true end end
end
local function spawn(name,class,pos,team)
    local s=mn.createShip(name,tb.ShipClasses[class],ba.createOrientation(),pos,mn.Teams[team],true)
    assert(s and s:isValid()); s:setFlag(true,'immobile'); R:EnableFullArsenal(s); return s
end
local wings={}; local cruiser; local threat; local blue; local began; local tested=false; local lastHit; local repairHull
local function init(self)
    start(self); self:EndIntroCinematic(true); self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario()
    self.Config.AI.Enabled=false; self.UpdateStationAI=function() end
    -- Isolate the existing commander contracts from the operation assembly
    -- phase; operations_headless_probe exercises the new layer separately.
    if self.Config.AI.Operations then self.Config.AI.Operations.Enabled=false end
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do quiet(self:GetFactionCommandShip(kind)) end
    local red=self:GetFactionCommandShip('RED')
    for n=1,2 do
        local wing={}
        for i=1,4 do wing[i]=spawn('Contract bomber '..n..' '..i,'SB Taurvi',red.Position+v(i*300,0,n*1000),'hostile') end
        self:RegisterLogicalWing(wing); wings[n]=wing
    end
    cruiser=spawn('Value cruiser','GTC Leviathan',v(60000,60000,60000),'friendly')
    threat=spawn('Disarmed home capital','GTD Hecate',red.Position+v(0,0,6000),'friendly'); quiet(threat)
    blue=self:GetCarrier(); began=mn.getMissionTime()
end
local function contracts(self)
    local now=mn.getMissionTime(); local red=self:GetFactionCommandShip('RED')
    self:InvalidateShipList(); self:UpdateFactionStrategicPlan('RED',now,true)
    local a=self.AIOrderState[wings[1][1]:getSignature()]; local b=self.AIOrderState[wings[2][1]:getSignature()]
    assert(a and b and a.mission=='PRIMARY' and b.mission=='PRIMARY' and a.targetSignature~=b.targetSignature)
    log('TWO_FRONTS',{first=a.targetSignature,second=b.targetSignature})
    local missile=mn.createWeapon(tb.WeaponClasses['Cyclops#short'],ba.createOrientation(),v(60000,60000,60100),blue)
    assert(missile and missile:isValid())
    wings[1][1].Target=missile
    assert(self:GetNativeObjectiveStatus(wings[1][1],a)=='NATIVE_POINT_DEFENSE')
    wings[1][1].Target=self:FindShipBySignature(a.targetSignature)
    log('NATIVE_POINT_DEFENSE',{})
    self.ScenarioStartTime=now-800; self:UpdateFactionStrategicPlan('RED',now,false)
    assert(self.AIOrderState[wings[1][1]:getSignature()].targetSignature==a.targetSignature)
    assert(self.AIOrderState[wings[2][1]:getSignature()].targetSignature==b.targetSignature)
    log('PERSISTENT_FRONTS',{})
    quiet(wings[1][1]); self:UpdateFactionStrategicPlan('RED',now,true)
    assert(self.AIOrderState[wings[1][1]:getSignature()].mission~='RETREAT','armed wing abandoned because leader was disarmed')
    wings[1][1]:setFlag(false,'primaries-locked','secondaries-locked','weapons-locked')
    log('ARMED_WING_WITH_DISABLED_LEADER',{})
    red.HitpointsLeft=red.HitpointsMax*.3; self:UpdateFactionStrategicPlan('RED',now,true)
    assert(self.AIPlanTelemetry.RED.threatCount==0 and not self.AIPlanTelemetry.RED.emergency)
    red.HitpointsLeft=red.HitpointsMax; log('NO_PHANTOM_RECALL',{})
    threat:setFlag(false,'primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#threat do if threat[i]:isTurret() then threat[i].TurretLocked=false end end
    threat.Target=red
    self:RecordStationBeamHit(red,threat,now,'CONTRACT_INJECTED_CONTACT')
    self:UpdateFactionStrategicPlan('RED',now,true)
    local ordinary=self.AIPlanTelemetry.RED
    assert(ordinary.emergency and ordinary.offenseValue>0 and ordinary.defenseValue<=ordinary.totalValue*.7)
    assert(self.AIProductionNeeds.RED.bomber>0 and self.AIProductionNeeds.RED.fighter==0)
    red.HitpointsLeft=red.HitpointsMax*.3; self:UpdateFactionStrategicPlan('RED',now,true)
    local critical=self.AIPlanTelemetry.RED
    assert(critical.emergency and critical.defenseValue>ordinary.defenseValue)
    log('EMERGENCY_BUDGET',{ordinary=ordinary.defenseValue,critical=critical.defenseValue,total=critical.totalValue})
    quiet(threat); red.HitpointsLeft=red.HitpointsMax
    local bombers={}
    for i=1,12 do bombers[i]=spawn('Counter demand '..i,'GTB Zeus',red.Position+v(i*100,0,6000),'friendly') end
    self:InvalidateShipList(); self:UpdateFactionStrategicPlan('RED',now,true)
    assert(self.AIProductionNeeds.RED.fighter>0 and self.AIProductionNeeds.RED.bomber==0)
    log('COUNTER_DEMAND',{fighter=self.AIProductionNeeds.RED.fighter,bomber=self.AIProductionNeeds.RED.bomber})
    for _,s in ipairs(bombers) do quiet(s) end
    self.AIProductionNeeds.RED={}
    local value=self:GetCombatValue(cruiser); assert(value>0)
    local cache=self.ShipCostMap[cruiser.Class.Name]; local cost=cache.cost; cache.cost=cost*2
    assert(self:GetCombatValue(cruiser)==value); cache.cost=cost; quiet(cruiser)
    assert(self:GetCombatValue(cruiser)==0); log('COMBAT_VALUE',{armed=value,disabled=0,priceIndependent=true})
    local oldTier=self.GetCurrentEscalationTier; self.GetCurrentEscalationTier=function() return 4 end
    local state=self.AIStates.RED; state.cp=24974
    local choice,d=self:ChooseAIBuild('RED',state,now); assert(not choice and d.bankTarget==24975)
    local ss=self:GetStationState('RED'); ss.levels.logistics=1; ss.nextAIThink=0
    stationThink(self,'RED',ss,red,now); assert(state.cp==24974)
    choice,d=self:ChooseAIBuild('RED',state,now+120)
    assert(not choice and state.productionReserve==24975)
    state.cp=24975; choice,d=self:ChooseAIBuild('RED',state,now+128)
    assert(choice and choice.entry.class=='SD Demon')
    log('PROTECTED_SAVINGS',{before=24974,retainedPastDeadline=true,selected=choice.entry.class})
    self.GetCurrentEscalationTier=oldTier
    for _,wing in ipairs(wings) do for _,s in ipairs(wing) do quiet(s) end end
    blue.HitpointsMax=10000; blue.HitpointsLeft=6000
    local bs=self:GetStationState('BLUE'); bs.levels.armor=2; bs.lastHull=6000; bs.lastDamageAt=now; bs.lastRepairTime=now
    began=now; tested=true; repairHull=6000
end
local function step(self)
    if not tested then if mn.getMissionTime()-began>=.5 then contracts(self) end; return end
    local now=mn.getMissionTime(); local elapsed=now-began
    if elapsed<3 then
        blue.HitpointsLeft=blue.HitpointsLeft-.125; repairHull=blue.HitpointsLeft; lastHit=now
    end
    self:UpdateStations(now)
    if now-lastHit<self.Config.Station.ArmorRepairDelay then assert(blue.HitpointsLeft==repairHull,'fractional damage failed to delay repair') end
    if elapsed>self.Config.Station.ArmorRepairDelay+3.2 then
        assert(blue.HitpointsLeft>repairHull); log('FRACTIONAL_DAMAGE_REPAIR',{gained=blue.HitpointsLeft-repairHull})
        log('PASS',{}); ContractDone=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end
local function guard(fn,self)
    if ContractDone then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then log('FAIL',{error=err}); ContractDone=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
end
R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
