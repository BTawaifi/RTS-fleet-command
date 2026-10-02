-- Controlled lure response: a real hostile target lock should release one
-- nearby defender to intercept; removing the pursuit should end the trap.
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local start=R.OnGameplayStart
local file=cf.openFile('lure-trap-headless.jsonl','w','data'); assert(file and file:isValid())
local function log(event,data) file:write(U.json({event=event,data=data})..'\n'); file:flush() end
local function v(x,y,z) return ba.createVector(x,y,z) end
local function alive(s) return s~=nil and s:isValid() and s.HitpointsLeft>0 and not s:isDying() end
local function quiet(s)
    s:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#s do if s[i]:isTurret() then s[i].TurretLocked=true end end
end
local function spawn(name,class,position,team)
    local s=mn.createShip(name,tb.ShipClasses[class],ba.createOrientation(),position,team,true)
    assert(alive(s),'failed to spawn '..name); R:EnableFullArsenal(s); return s
end

local blue,red,gold,bait,hunter,defender,began,finished

local function evaluate(self,now)
    self:InvalidateShipList()
    local snapshot=self:BuildStrategicThreatSnapshot(); self.StrategicThreatSnapshot=snapshot
    self:BuildAIContext(snapshot)
    local pursuers=self:GetActiveLurePursuers('BLUE',now)
    local threats=self:GetFactionThreats('BLUE',blue,6500,pursuers)
    local pursuing=false; local threatRows={}
    for _,threat in ipairs(threats) do
        threatRows[#threatRows+1]={ship=threat.ship:getSignature(),value=threat.value,
            distance=threat.distance,eligible=threat.homeDefenseEligible,pursuingLure=threat.pursuingLure,
            attacking=threat.attacking,urgent=threat.urgent}
        if threat.ship:getSignature()==hunter:getSignature() and threat.pursuingLure then pursuing=true end
    end
    assert(pursuing,'native pursuer did not become a lure-tagged base threat')
    self:UpdateFactionStrategicPlan('BLUE',now,true)
    local state=self.AIOrderState[defender:getSignature()]
    log('PLAN_DEBUG',{autoPlayer=self.AutoPlayerMode,setup=self.SetupActive,threats=threatRows,
        state=state and {mission=state.mission,target=state.targetSignature,reason=state.reason,group=state.group} or nil,
        plan=self.AIPlanTelemetry and self.AIPlanTelemetry.BLUE})
    assert(state and state.mission=='TRAP' and state.targetSignature==hunter:getSignature(),
        'base defense did not release an armed defender against the lure pursuer')
    local nativeFound=false
    for i=1,#defender.Orders do
        local order=defender.Orders[i]
        if order:isValid() and order:getType()==ORDER_ATTACK and order.Target:isValid()
            and order.Target:getSignature()==hunter:getSignature() then nativeFound=true end
    end
    assert(nativeFound,'trap response was not installed as a native attack order')
    log('TRAP_RESPONSE',{time=now,defender=defender:getSignature(),pursuer=hunter:getSignature(),
        nativeOrder=true,pursuerInsideRange=hunter.Position:getDistance(blue.Position)})
    return state
end

local function init(self)
    start(self); self:EndIntroCinematic(true)
    self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario(); self.Config.AI.Enabled=false
    self.AutoPlayerMode=true; self.CombatTelemetryEnabled=true
    blue=self:GetFactionCommandShip('BLUE'); red=self:GetFactionCommandShip('RED'); gold=self:GetFactionCommandShip('GOLD')
    for _,s in ipairs({blue,red,gold}) do quiet(s) end
    local now=mn.getMissionTime()
    bait=spawn('Trap probe lure','GTF Hercules',blue.Position+v(0,0,1400),blue.Team)
    hunter=spawn('Trap probe pursuer','SF Mara',blue.Position+v(0,0,2200),red.Team)
    defender=spawn('Trap probe defender','GTF Ulysses',blue.Position+v(400,0,-900),blue.Team)
    quiet(bait)
    self.AIOrderState[bait:getSignature()]={mission='LURE',lureUntil=now+120,assignedAt=now,
        targetSignature=blue:getSignature()}
    hunter.Target=bait
    assert(hunter:giveOrder(ORDER_ATTACK,bait,nil,.95)==true,'native pursuer order failed')
    began=now
    log('SETUP',{station=blue:getSignature(),bait=bait:getSignature(),pursuer=hunter:getSignature(),
        defender=defender:getSignature(),combat=true})
    evaluate(self,now)
end

local function step(self)
    if finished then return end
    local now=mn.getMissionTime()
    if not alive(defender) then error('defender died in the controlled trap scenario') end
    if now-began>=20 then
        hunter.Target=nil; hunter:clearOrders()
        local baitId=bait:getSignature(); local lureState=self.AIOrderState[baitId]
            or {mission='LURE',targetSignature=blue:getSignature(),assignedAt=began}
        lureState.mission='LURE'; lureState.lureUntil=now-1; self.AIOrderState[baitId]=lureState
        self.AIOrderState[defender:getSignature()]=nil
        self.AITargetedBy=nil; self.AIShipIndex=nil; self.AIProfileIndex=nil
        -- Move the former pursuer beyond the station's normal response range;
        -- with no lure or attack on the base, it must not stay the trap target.
        hunter.Position=blue.Position+v(0,0,14000)
        local snapshot=self:BuildStrategicThreatSnapshot(); self.StrategicThreatSnapshot=snapshot
        self:BuildAIContext(snapshot)
        local threats=self:GetFactionThreats('BLUE',blue,6500,self:GetActiveLurePursuers('BLUE',now))
        for _,threat in ipairs(threats) do
            assert(threat.ship:getSignature()~=hunter:getSignature(),'inactive distant decoy remained a base threat')
        end
        self:UpdateFactionStrategicPlan('BLUE',now,true)
        local restored=self.AIOrderState[defender:getSignature()]
        assert(not restored or restored.targetSignature~=hunter:getSignature() or restored.mission~='TRAP',
            'defender kept a trap order after lure evidence ended')
        for i=1,#defender.Orders do
            local order=defender.Orders[i]
            assert(not (order:isValid() and order:getType()==ORDER_ATTACK and order.Target:isValid()
                and order.Target:getSignature()==hunter:getSignature()),
                'native attack on the former pursuer was not cleared on counterplay')
        end
        log('COUNTERPLAY',{time=now,formerPursuer=hunter:getSignature(),distance=hunter.Position:getDistance(blue.Position),
            noLurePursuers=true,noBaseThreat=true})
        log('PASS',{elapsed=now-began,limitation='Valid lure recognition and native trap-order control; no casualty or win-rate claim'})
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
