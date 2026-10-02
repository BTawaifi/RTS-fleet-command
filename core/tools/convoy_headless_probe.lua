-- Physical movement probe; empty approach space isolates coordination from combat.
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local start=R.OnGameplayStart
local file=cf.openFile('convoy-headless.jsonl','w','data'); assert(file and file:isValid())
local function log(event,data) file:write(U.json({event=event,data=data})..'\n'); file:flush() end
local function v(x,y,z) return ba.createVector(x,y,z) end
local home,target,groups,began,initial,op
local finished=false
local lastThink=-1; local lastSample=-1
local maxApproachSeparation=0
local function quiet(s)
    s:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#s do if s[i]:isTurret() then s[i].TurretLocked=true end end
end
local function init(self)
    start(self); self:EndIntroCinematic(true)
    self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario(); self.Config.AI.Enabled=false
    home=self:GetFactionCommandShip('BLUE')
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do quiet(self:GetFactionCommandShip(kind)) end
    target=mn.createShip('Convoy objective',tb.ShipClasses['GTD Hecate'],ba.createOrientation(),
        home.Position+v(0,0,18000),mn.Teams.hostile,true)
    assert(target and target:isValid()); quiet(target)
    groups={}; initial={}; began=mn.getMissionTime()
    for i,className in ipairs({'GTB Medusa','GTF Hercules','GTF Hercules','GTF Hercules'}) do
        local ship=mn.createShip('Convoy member '..i,tb.ShipClasses[className],ba.createOrientation(),
            home.Position+v((i-2)*400,0,1400),home.Team,true)
        assert(ship and ship:isValid()); self:EnableFullArsenal(ship)
        groups[i]={id=ship:getSignature(),primary=target,armed=true,value=self:GetCombatValue(ship),
            role=i==1 and 'bomber' or 'fighter',units={ship}}
        initial[i]=ship.Position:getDistance(target.Position)
    end
    self:InvalidateShipList(); self.StrategicThreatSnapshot={}
    log('SETUP',{distance=home.Position:getDistance(target.Position),groups=#groups,combat=false})
end
local function step(self)
    local now=mn.getMissionTime(); local elapsed=now-began
    for _,g in ipairs(groups) do assert(g.units[1]:isValid() and g.units[1].HitpointsLeft>0,'convoy member lost in empty control') end
    if now-lastThink>=1 then
        lastThink=now; self:BuildAIOperations('BLUE',groups,home,now,0)
        op=groups[1].operation; assert(op,'convoy operation missing')
        for _,g in ipairs(groups) do
            local context={}
            local selected,mission=self:ApplyAIOperationOrder(g,target,'PRIMARY',context,home,now,{})
            local installed=self:IssueStrategicOrder(g.units[1],selected,'convoy physical probe',mission,now,false,context)
            assert(installed~=false and self.AIOrderState[g.id],'convoy native order rejected')
            g.probeReason=context.reason
        end
    end
    if op.phase=='APPROACH' then
        for _,g in ipairs(groups) do
            if g.role=='fighter' then
                maxApproachSeparation=math.max(maxApproachSeparation,g.units[1].Position:getDistance(op.anchor.units[1].Position))
            end
        end
    end
    if elapsed-lastSample>=5 then
        lastSample=elapsed
        local rows={}
        for i,g in ipairs(groups) do
            local state=self.AIOrderState[g.id]
            rows[#rows+1]={id=g.id,role=g.role,targetDistance=g.units[1].Position:getDistance(target.Position),
                anchorDistance=g.units[1].Position:getDistance(op.anchor.units[1].Position),
                closed=initial[i]-g.units[1].Position:getDistance(target.Position),
                mission=state and state.mission,reason=g.probeReason}
        end
        log('MOVEMENT',{elapsed=elapsed,phase=op.phase,serial=op.serial,reserveId=op.reserveId,
            reserveReleased=op.reserveReleased,groups=rows})
    end
    if elapsed>=200 then
        assert(op.serial==1,'convoy restarted during approach')
        assert(op.phase~='ASSEMBLE','convoy never launched')
        assert(op.reserveId and op.reserveReleased,'convoy reserve never released')
        local closed=initial[1]-groups[1].units[1].Position:getDistance(target.Position)
        assert(closed>3000,'strike anchor made no physical approach progress')
        assert(maxApproachSeparation<4500,'escorts separated beyond the nearby protection radius')
        log('PASS',{elapsed=elapsed,anchorClosed=closed,phase=op.phase,
            maxApproachSeparation=maxApproachSeparation,
            limitation='Movement control only; no combat effectiveness comparison'})
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
