-- Startup checkpoints for the runner-only flank probe; no gameplay assertions changed.
local file=cf.openFile('flank-headless-v2.jsonl','w','data'); assert(file and file:isValid())
file:write('{"event":"MODULE_LOADED"}\n'); file:flush()
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local start=R.OnGameplayStart
local function gameStateName()
    local ok,name=pcall(function() return ba.getCurrentGameState().Name end)
    return ok and name or 'UNAVAILABLE'
end
local function log(event,data)
    data=data or {}; data.gameState=gameStateName()
    file:write(U.json({event=event,data=data})..'\n'); file:flush()
end
local function v(x,y,z) return ba.createVector(x,y,z) end
local function quiet(ship)
    ship:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#ship do if ship[i]:isTurret() then ship[i].TurretLocked=true end end
end
local function spawn(name,className,position,team)
    local ship=mn.createShip(name,tb.ShipClasses[className],ba.createOrientation(),position,team,true)
    assert(ship and ship:isValid(),'failed to spawn '..name)
    R:EnableFullArsenal(ship)
    return ship
end
local function hasNativeOrder(ship,kind,targetSignature)
    for i=1,#ship.Orders do
        local order=ship.Orders[i]
        if order:isValid() and order:getType()==kind and order.Target:isValid()
            and order.Target:getSignature()==targetSignature then return true end
    end
    return false
end

local home,targets,groups,defenders,began
local launches={}; local suitable; local flank; local anchor; local reserve
local sawPin=false; local sawRelease=false; local flankReached=false
local maxFlankSeparation=0; local finalFlankSeparation=math.huge; local minFlankPointDistance=math.huge
local lastThink=-1; local lastSample=-1; local finished=false

local function makeGroup(self,label,target,className,role,offset)
    local ship=spawn('Flank probe '..label,className,home.Position+offset,home.Team)
    local g={id=ship:getSignature(),primary=target,armed=true,value=self:GetCombatValue(ship),role=role,units={ship},front=label}
    assert(g.value>0,'combat group has no profile value: '..label)
    return g
end

local function init(self)
    log('BEFORE_START',{missionTime=mn.getMissionTime()})
    start(self)
    log('AFTER_START',{missionTime=mn.getMissionTime()})
    self:EndIntroCinematic(true)
    self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario()
    log('AFTER_SCENARIO',{missionTime=mn.getMissionTime()})
    self.Config.AI.Enabled=false
    home=self:GetFactionCommandShip('BLUE')
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do quiet(self:GetFactionCommandShip(kind)) end

    targets={
        red=spawn('Flank suitable objective','GTD Hecate',home.Position+v(0,0,12000),self:GetFactionCommandShip('RED').Team),
        gold=spawn('Flank control objective','GTD Hecate',home.Position+v(0,0,-12000),self:GetFactionCommandShip('GOLD').Team),
    }
    for _,target in pairs(targets) do quiet(target) end
    defenders={}
    for _,row in ipairs({{label='red',kind='RED'},{label='gold',kind='GOLD'}}) do
        local label,kind=row.label,row.kind
        local target=targets[label]
        local defender=spawn('Quiet strategic defender '..label,'GTF Hercules',
            target.Position+v(800,0,0),self:GetFactionCommandShip(kind).Team)
        local value=self:GetCombatValue(defender)
        assert(value>0,'quiet defender has no pre-disarm strategic value: '..label)
        quiet(defender)
        defenders[#defenders+1]={ship=defender,profile={value=value}}
    end

    local near=v(-250,0,1200); local right=v(250,0,1200)
    groups={
        makeGroup(self,'red-anchor',targets.red,'GTB Medusa','bomber',near),
        makeGroup(self,'red-flank',targets.red,'GTB Medusa','bomber',right),
        makeGroup(self,'red-screen-1',targets.red,'GTF Hercules','fighter',v(-500,0,1500)),
        makeGroup(self,'red-screen-2',targets.red,'GTF Hercules','fighter',v(500,0,1500)),
        makeGroup(self,'gold-strike',targets.gold,'GTB Medusa','bomber',v(-250,0,-1200)),
        makeGroup(self,'gold-screen',targets.gold,'GTF Hercules','fighter',v(250,0,-1500)),
    }
    R:InvalidateShipList()
    R.StrategicThreatSnapshot=defenders
    began=mn.getMissionTime()
    log('SETUP',{combat=false,defenders=#defenders,groups=#groups,
        redTarget=targets.red:getSignature(),goldTarget=targets.gold:getSignature(),
        defenderValues={red=defenders[1].profile.value,gold=defenders[2].profile.value}})
end

local function think(self,now)
    self.StrategicThreatSnapshot=defenders
    self:BuildAIOperations('BLUE',groups,home,now,0)
    local redOp=self.AIOperations.BLUE[targets.red:getSignature()]
    local goldOp=self.AIOperations.BLUE[targets.gold:getSignature()]
    assert(redOp and goldOp,'one of the controlled fronts was not built')
    if redOp.serial>0 and not launches.red then
        launches.red=redOp.launchedAt
        suitable=redOp
        flank=groups[2]; anchor=redOp.anchor
        reserve=redOp.reserveId
        assert(redOp.strikes==2 and redOp.screens==2 and redOp.defense>0,
            'suitable fixture did not provide two strikes, a screen, and live strategic defense')
        assert(redOp.flankId==flank.id and redOp.reserveId,
            'suitable composition did not assign flank and reserve groups')
        log('SUITABLE_LAUNCH',{time=now,phase=redOp.phase,serial=redOp.serial,
            flankId=redOp.flankId,anchorId=redOp.anchor.id,reserveId=redOp.reserveId,defense=redOp.defense})
    end
    if goldOp.serial>0 and not launches.gold then
        launches.gold=goldOp.launchedAt
        assert(goldOp.strikes==1 and goldOp.screens==1 and goldOp.defense>0,
            'unsuitable control fixture changed composition or lost defended target')
        assert(goldOp.flankId==nil,'one-strike control incorrectly received a flank group')
        log('UNSUITABLE_LAUNCH',{time=now,phase=goldOp.phase,serial=goldOp.serial,
            strikes=goldOp.strikes,screens=goldOp.screens,defense=goldOp.defense,flankId='NONE'})
    end
    for _,g in ipairs(groups) do
        local context={}
        local target,mission=self:ApplyAIOperationOrder(g,g.primary,'PRIMARY',context,home,now,{})
        local order=self:IssueStrategicOrder(g.units[1],target,'physical flank probe',mission,now,false,context)
        assert(order~=false and self.AIOrderState[g.id],'native operation order was not retained for '..g.front)
        g.probeReason=context.reason; g.probeDestination=context.destination; g.probeTarget=target
        if g==flank then
            if context.reason=='PIN_AND_FLANK' then sawPin=true end
            if sawPin and context.reason~='PIN_AND_FLANK' then
                local state=self.AIOrderState[g.id]
                sawRelease=state.destination==nil and state.mission~='REGROUP'
                    and ((state.mission=='PRIMARY' and hasNativeOrder(g.units[1],ORDER_ATTACK,state.targetSignature))
                        or (state.mission=='ESCORT' and hasNativeOrder(g.units[1],ORDER_GUARD,state.targetSignature)))
            end
        elseif g.front=='gold-strike' then
            assert(context.reason~='PIN_AND_FLANK' and context.destination==nil,
                'unsuitable control unexpectedly received a flank waypoint')
            local state=self.AIOrderState[g.id]
            assert(state.mission=='PRIMARY' and hasNativeOrder(g.units[1],ORDER_ATTACK,state.targetSignature),
                'unsuitable control bomber lacks its native primary attack order')
        elseif g.front=='gold-screen' then
            local state=self.AIOrderState[g.id]
            local ordinary=state.mission=='ESCORT' and hasNativeOrder(g.units[1],ORDER_GUARD,state.targetSignature)
                or state.mission=='PRIMARY' and hasNativeOrder(g.units[1],ORDER_ATTACK,state.targetSignature)
            assert(context.reason~='PIN_AND_FLANK' and context.destination==nil and ordinary,
                'unsuitable control screen lacks its native escort/primary order')
        end
    end
    if suitable then
        minFlankPointDistance=math.min(minFlankPointDistance,flank.units[1].Position:getDistance(suitable.flankPoint))
        if minFlankPointDistance<=900 then flankReached=true end
        maxFlankSeparation=math.max(maxFlankSeparation,
            flank.units[1].Position:getDistance(anchor.units[1].Position))
        finalFlankSeparation=flank.units[1].Position:getDistance(anchor.units[1].Position)
    end
end

local function step(self)
    if finished then return end
    local now=mn.getMissionTime(); local elapsed=now-began
    for _,g in ipairs(groups) do
        assert(g.units[1]:isValid() and g.units[1].HitpointsLeft>0,
            'probe ship died; no physical flank conclusion is available')
    end
    if now-lastThink>=1 then lastThink=now; think(self,now) end
    if elapsed-lastSample>=10 then
        lastSample=elapsed
        if suitable then
            log('FLANK_MOVEMENT',{elapsed=elapsed,phase=suitable.phase,serial=suitable.serial,
                flankReason=flank.probeReason,flankMission=self.AIOrderState[flank.id].mission,
                flankTargetDistance=flank.units[1].Position:getDistance(targets.red.Position),
                flankPointDistance=flank.units[1].Position:getDistance(suitable.flankPoint),
                anchorDistance=flank.units[1].Position:getDistance(anchor.units[1].Position),
                maxSeparation=maxFlankSeparation,minPointDistance=minFlankPointDistance,
                flankDone=suitable.flankDone,reserveReleased=suitable.reserveReleased})
        end
    end
    if elapsed>=240 then
        local redOp=suitable
        local goldOp=self.AIOperations.BLUE[targets.gold:getSignature()]
        assert(redOp and redOp.serial==1 and launches.red,'suitable operation failed or restarted')
        assert(redOp.reserveReleased and reserve~=nil,'suitable reserve did not release by deadline')
        assert(sawPin and maxFlankSeparation>1800,'flank received no divergent physical movement')
        assert(flankReached and redOp.flankDone,'flank did not reach its staging point before the bounded deadline')
        assert(sawRelease and self.AIOrderState[flank.id].mission~='REGROUP',
            'flank waypoint order was not released back to the assault')
        assert(finalFlankSeparation<4500,'released flank did not rejoin the assault formation envelope')
        assert(goldOp and goldOp.serial==1 and goldOp.flankId==nil and launches.gold,
            'unsuitable one-strike control did not remain unflanked')
        local controlBomber=self.AIOrderState[groups[5].id]
        assert(controlBomber and controlBomber.mission=='PRIMARY',
            'unsuitable control did not retain its normal primary attack order')
        log('PASS',{elapsed=elapsed,flankReached=flankReached,flankDone=redOp.flankDone,
            maxSeparation=maxFlankSeparation,finalSeparation=finalFlankSeparation,
            minFlankPointDistance=minFlankPointDistance,reserveReleased=redOp.reserveReleased,
            flankReleased=sawRelease,controlFlankId='NONE',controlMission=controlBomber.mission,
            limitation='Disarmed defender fixture; physical approach/order effect, no combat effectiveness claim'})
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
