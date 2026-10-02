-- Run only in an isolated `probe,rts` headless workspace.
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local start=R.OnGameplayStart
local file=cf.openFile('operations-headless.jsonl','w','data'); assert(file and file:isValid())
local function log(event,data)
    file:write(U.json({event=event,data=data})..'\n'); file:flush()
end
local function v(x,y,z) return ba.createVector(x,y,z) end
local function fail(message) error(message,2) end
local mover,attacker,target,turret,movePoint,profile,operationGroup,operation
local initialDistance,initialTurretHP,began
local movementPassed,attackPassed=false,false
local firstHitAt,lastSample,nextOrderCheck=-1,0,0
local finished=false

local function quiet(ship)
    ship:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#ship do
        local subsystem=ship[i]
        if subsystem:isTurret() then subsystem.TurretLocked=true end
    end
end

local function spawn(name,className,position,team)
    local ship=mn.createShip(name,tb.ShipClasses[className],ba.createOrientation(),position,team,true)
    assert(ship and ship:isValid(),'failed to spawn '..name)
    R:EnableFullArsenal(ship)
    return ship
end

local function init(self)
    start(self); self:EndIntroCinematic(true)
    self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario()
    self.Config.AI.Enabled=false
    local blue=self:GetFactionCommandShip('BLUE'); local red=self:GetFactionCommandShip('RED')
    quiet(blue); quiet(red); quiet(self:GetFactionCommandShip('GOLD'))

    mover=spawn('Operation waypoint mover','GTF Hercules',blue.Position+v(-1200,0,0),blue.Team)
    movePoint=blue.Position+v(0,0,3500)
    initialDistance=mover.Position:getDistance(movePoint)
    assert(self:IssueStrategicOrder(mover,blue,'operation waypoint probe','REGROUP',mn.getMissionTime(),true,
        {destination=movePoint}),'native waypoint order rejected')
    local moveState=self.AIOrderState[mover:getSignature()]
    local moveStatus,hasMoveGoal=self:GetNativeObjectiveStatus(mover,moveState)
    assert(moveStatus=='NATIVE_MOVEMENT_GOAL' and hasMoveGoal,'waypoint was not installed as a native movement goal')
    log('WAYPOINT_INSTALLED',{status=moveStatus,initialDistance=initialDistance,
        x=moveState.destination.x,y=moveState.destination.y,z=moveState.destination.z})

    target=spawn('Operation suppression target','GTD Hecate',blue.Position+v(0,0,5500),mn.Teams.hostile)
    target:setFlag(true,'immobile')
    attacker=spawn('Operation suppression bomber','GTB Medusa',target.Position+v(0,0,-2500),mn.Teams.friendly)
    profile=self:AIProfile(attacker)
    local suppression={}
    local subsystemIndex
    turret=R:GetAISuppressionSubsystem(suppression,target,mn.getMissionTime(),attacker)
    subsystemIndex=suppression.suppressionIndex
    assert(turret and subsystemIndex,'target has no live targetable turret for suppression')
    for i=1,#target do
        local subsystem=target[i]
        if subsystem:isTurret() and subsystem:isValid() and subsystem.HitpointsLeft>0
            and i~=subsystemIndex then
            subsystem.TurretLocked=true
        end
    end
    self:InvalidateShipList()
    operation={phase='ENGAGE',serial=1,target=target,defenders={target},strikes=2,groups={}}
    operationGroup={id=77,role='bomber',units={attacker},operation=operation,armed=true,value=100}
    operation.groups={operationGroup}
    local context={}
    local selected,mission=self:ApplyAIOperationOrder(operationGroup,target,'PRIMARY',context,blue,mn.getMissionTime(),{})
    log('SUPPRESSION_DECISION',{selected=selected and selected:getSignature() or -1,
        expected=target:getSignature(),mission=mission,reason=context.reason,
        subsystemIndex=context.subsystemIndex or -1,expectedIndex=subsystemIndex,
        capital=self:IsCapitalTarget(target),static=self:IsStaticDefense(target),role=self:GetShipRole(target)})
    assert(selected and selected:getSignature()==target:getSignature(),'operation changed the suppression target')
    assert(mission=='PRIMARY','operation changed the attack mission')
    assert(context.subsystemIndex==subsystemIndex and context.subsystem
        and context.subsystem.Name==turret.Name,'operation did not select live turret suppression')
    assert(context.subsystem:getParent():getSignature()==target:getSignature(),
        'selected suppression subsystem belongs to a different ship')
    initialTurretHP=turret.HitpointsLeft
    assert(self:IssueStrategicOrder(attacker,selected,'operation suppression probe',mission,mn.getMissionTime(),true,context),
        'native subsystem attack order rejected')
    local attackState=self.AIOrderState[attacker:getSignature()]
    local found=false
    for i=1,#attacker.Orders do
        local order=attacker.Orders[i]
        local orderTarget=order:isValid() and order.Target or nil
        local orderSubsystem=order:isValid() and order.TargetSubsystem or nil
        if order:isValid() and order:getType()==ORDER_ATTACK and orderTarget:isValid()
            and orderTarget:getSignature()==target:getSignature() and orderSubsystem:isValid()
            and orderSubsystem:getParent():getSignature()==target:getSignature()
            and orderSubsystem.Name==turret.Name then found=true; break end
    end
    assert(found,'native attack goal lost its selected subsystem')
    log('SUPPRESSION_INSTALLED',{subsystemIndex=subsystemIndex,initialHP=initialTurretHP,
        weaponRange=profile.range,targetRadius=target.Radius,startDistance=attacker.Position:getDistance(target.Position),
        maxSpeed=attacker.Physics.VelocityMax.z,deadline=operation.suppressionUntil,
        nativeOrder='ORDER_ATTACK',orderHasSubsystem=true})
    began=mn.getMissionTime()
end

local function step(self)
    if finished then return end
    local now=mn.getMissionTime(); local elapsed=now-began
    assert(attacker and attacker:isValid() and attacker.HitpointsLeft>0,
        'suppression attacker died before the native-effect control completed')
    local distance=mover.Position:getDistance(movePoint)
    if not movementPassed and elapsed>=20 then
        assert(distance<initialDistance-100,'native waypoint order did not move the ship toward its destination')
        movementPassed=true
        log('WAYPOINT_MOVED',{elapsed=elapsed,distance=distance,closed=initialDistance-distance})
    end
    if not attackPassed and turret:isValid() and turret.HitpointsLeft<initialTurretHP then
        attackPassed=true
        firstHitAt=elapsed
        log('SUPPRESSION_FIRST_HIT',{elapsed=elapsed,initialHP=initialTurretHP,currentHP=turret.HitpointsLeft})
    end
    if now>=nextOrderCheck then
        nextOrderCheck=now+2
        local context={}
        local selected,mission=self:ApplyAIOperationOrder(operationGroup,target,'PRIMARY',context,
            self:GetFactionCommandShip('BLUE'),now,{})
        assert(selected and selected:getSignature()==target:getSignature() and mission=='PRIMARY',
            'operation commander changed the active suppression objective')
        if elapsed>=25 and elapsed<operation.suppressionUntil then
            assert(context.subsystem and context.subsystemIndex==operation.suppressionIndex,
                'commander re-evaluation dropped suppression before its travel-aware deadline')
        end
        self:IssueStrategicOrder(attacker,selected,'operation suppression recheck',mission,now,false,context)
    end
    if elapsed>=25 and lastSample<25 then
        assert(movementPassed,'native waypoint movement did not complete its observation window')
        lastSample=25
        local nativeTarget=attacker.Target
        local nativeSubsystem=attacker.TargetSubsystem
        log('SUPPRESSION_DEADLINE_CHECK',{elapsed=elapsed,deadline=operation.suppressionUntil,
            hitObserved=attackPassed,currentHP=turret.HitpointsLeft,
            distance=attacker.Position:getDistance(target.Position),
            turretDistance=attacker.Position:getDistance(turret.WorldPosition),
            nativeTarget=nativeTarget and nativeTarget:isValid() and nativeTarget:getSignature() or -1,
            nativeSubsystem=nativeSubsystem and nativeSubsystem:isValid() and nativeSubsystem.Name or 'NONE',
            status=self:GetNativeObjectiveStatus(attacker,self.AIOrderState[attacker:getSignature()])})
        if not attackPassed then log('OLD_FIXED_25S_WINDOW_WOULD_MISS',{elapsed=elapsed,
            firstHitObserved=firstHitAt<0 and 'pending' or firstHitAt}) end
    end
    if attackPassed then
        assert(firstHitAt<=operation.suppressionUntil,
            'native turret hit arrived after the travel-aware suppression deadline')
        operation.phase='EXPLOIT'
        local context={}
        local selected,mission=self:ApplyAIOperationOrder(operationGroup,target,'PRIMARY',context,
            self:GetFactionCommandShip('BLUE'),now,{})
        assert(selected and selected:getSignature()==target:getSignature() and mission=='PRIMARY'
            and context.subsystem==nil and context.reason=='BREAKTHROUGH_EXPLOIT',
            'operation kept suppressing after its ENGAGE enabling phase ended')
        assert(self:IssueStrategicOrder(attacker,selected,'operation suppression counter',mission,now,false,context),
            'native counter-order failed after exploitation began')
        local nativeCounterFound=false
        for i=1,#attacker.Orders do
            local order=attacker.Orders[i]
            if order:isValid() and order:getType()==ORDER_ATTACK and order.Target:isValid()
                and order.Target:getSignature()==target:getSignature() then
                assert(not order.TargetSubsystem:isValid(),'native subsystem goal remained after suppression ended')
                nativeCounterFound=true
                log('SUPPRESSION_COUNTER_ORDER',{elapsed=elapsed,mission=mission,
                    nativeTarget=order.Target:getSignature(),subsystemReleased=true})
                break
            end
        end
        assert(nativeCounterFound,'no native general attack control after suppression ended')
        log('SUPPRESSION_RESULT',{elapsed=elapsed,firstHitAt=firstHitAt,deadline=operation.suppressionUntil,
            deadlinePassed=firstHitAt<=operation.suppressionUntil,currentHP=turret.HitpointsLeft,
            initialHP=initialTurretHP,turretDistance=attacker.Position:getDistance(turret.WorldPosition),
            weaponRange=profile.range})
        finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    elseif elapsed-lastSample>=5 then
        lastSample=elapsed
        log('SUPPRESSION_SAMPLE',{elapsed=elapsed,currentHP=turret.HitpointsLeft,
            centerDistance=attacker.Position:getDistance(target.Position),
            turretDistance=attacker.Position:getDistance(turret.WorldPosition),
            weaponRange=profile.range})
    end
end

local function guard(fn,self)
    if finished then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then
        log('FAIL',{error=err}); finished=true
        ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end
R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
