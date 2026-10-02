-- Opt-in native elimination probe for a fresh isolated `probe,rts` workspace.
-- Uses Ship:kill() so FSO owns death-roll flags and callback sequencing.
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local shipAlive=require('fs2rts_util').shipAlive
local start=R.OnGameplayStart
local file=cf.openFile('elimination-headless.jsonl','w','data')
assert(file and file:isValid())

local function log(event,data)
    file:write(U.json({event=event,data=data})..'\n'); file:flush()
end
local function v(x,y,z) return ba.createVector(x,y,z) end
local function valid(ship) return ship~=nil and ship:isValid() end
local function signature(ship) return valid(ship) and ship:getSignature() or -1 end
local function quiet(ship)
    ship:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#ship do if ship[i]:isTurret() then ship[i].TurretLocked=true end end
end
local function orderTargets(ship,target)
    if not valid(ship) then return false end
    for i=1,#ship.Orders do
        local order=ship.Orders[i]
        if order:isValid() and order:getType()==ORDER_ATTACK
            and valid(order.Target) and signature(order.Target)==signature(target) then return true end
    end
    return false
end

local blue,red,gold,attacker
local attackerSignature,redSignature,goldSignature
local began,killedAt,nextAudit,auditCount
local deathCallbackSeen=false
local finished=false
local afterDeath=false
local deadTargetDecisions=0
local goldTargetDecisions=0
local goldPrimaryDecisions=0
local goldAttackDecisions=0
local decisionEvents=0
local frontOperationBeforeDeath=false
local bombers,screens
local attackDeadline,goldAttackConfirmed=false,false

local originalOnShipDeath=R.OnShipDeath
R.OnShipDeath=function(self,ship)
    if signature(ship)~=redSignature then return originalOnShipDeath(self,ship) end
    local before={valid=valid(ship),signature=signature(ship),hitpoints=ship.HitpointsLeft,
        isDying=ship:isDying(),shipAlive=shipAlive(ship),redEliminated=self.RedEliminated==true,
        commandLookup=signature(self:GetFactionCommandShip('RED')),
        stillEnemy=self:AreEnemies(attacker,ship),trackedOrder=self.AIOrderState[attackerSignature]~=nil,
        nativeAttack=orderTargets(attacker,ship)}
    log('ON_SHIP_DEATH_BEFORE_ORIGINAL',before)
    originalOnShipDeath(self,ship)
    local after={valid=valid(ship),signature=signature(ship),hitpoints=valid(ship) and ship.HitpointsLeft or nil,
        isDying=valid(ship) and ship:isDying() or false,shipAlive=shipAlive(ship),redEliminated=self.RedEliminated==true,
        commandLookup=signature(self:GetFactionCommandShip('RED')),
        stillEnemy=self:AreEnemies(attacker,ship),trackedOrder=self.AIOrderState[attackerSignature]~=nil,
        nativeAttack=orderTargets(attacker,ship)}
    log('ON_SHIP_DEATH_AFTER_ORIGINAL',after)
    assert(before.valid and before.isDying,'native callback did not observe a valid ship in death roll')
    assert(before.hitpoints>0 and not before.shipAlive,
        'native positive-hull death roll was not rejected by shared shipAlive')
    assert(after.redEliminated,'original callback did not eliminate the dead command faction')
    assert(after.trackedOrder==false and after.nativeAttack==false,
        'original callback did not release the tracked native attack order')
    deathCallbackSeen=true
end

local function init(self)
    start(self); self:EndIntroCinematic(true)
    self.SetupOpponents={RED=true,GOLD=true}; self.SetupAutoMode=false
    self:StartScenario()
    blue=self:GetFactionCommandShip('BLUE')
    red=self:GetFactionCommandShip('RED')
    gold=self:GetFactionCommandShip('GOLD')
    for _,station in ipairs({blue,red,gold}) do quiet(station) end
    assert(valid(blue) and valid(red) and valid(gold),'three live command stations required')

    bombers={}; screens={}
    for i=1,4 do
        bombers[i]=mn.createShip('Elimination bomber '..i,tb.ShipClasses['GTB Medusa'],
            ba.createOrientation(),blue.Position+v(i*140,0,1100),blue.Team,true)
        screens[i]=mn.createShip('Elimination screen '..i,tb.ShipClasses['GTF Hercules'],
            ba.createOrientation(),blue.Position+v(i*140,0,1900),blue.Team,true)
        assert(valid(bombers[i]) and valid(screens[i]),'failed to spawn offensive force')
        self:EnableFullArsenal(bombers[i]); self:EnableFullArsenal(screens[i])
    end
    self:RegisterLogicalWing(bombers,'Elimination strike wing')
    self:RegisterLogicalWing(screens,'Elimination screen wing')
    attacker=bombers[1]
    self:InvalidateShipList()
    self:ResetCoordinatedAI()
    attackerSignature=signature(attacker); redSignature=signature(red); goldSignature=signature(gold)

    self.CombatTelemetryEnabled=true
    self.AIEventSink=function(record)
        if record.event~='DECISION' then return end
        decisionEvents=decisionEvents+1
        if not afterDeath then return end
        if record.data.target==redSignature or record.data.assaultPrimarySignature==redSignature then
            deadTargetDecisions=deadTargetDecisions+1
        end
        if record.data.target==goldSignature then goldTargetDecisions=goldTargetDecisions+1 end
        if record.data.assaultPrimarySignature==goldSignature then goldPrimaryDecisions=goldPrimaryDecisions+1 end
        if record.data.target==goldSignature and record.data.mission=='PRIMARY' then
            goldAttackDecisions=goldAttackDecisions+1
        end
    end

    assert(shipAlive(red) and not red:isDying(),'living Red target control is not alive')
    self.FactionPrimaryTargets.BLUE=redSignature
    local livePrimary=self:GetStablePrimaryTarget('BLUE')
    assert(signature(livePrimary)==redSignature,'living Red command station failed primary-target control')
    log('LIVE_TARGET_CONTROL',{target=signature(livePrimary),alive=shipAlive(red),hostile=self:AreEnemies(attacker,red)})
    assert(self:IssueStrategicOrder(attacker,red,'elimination probe setup','PRIMARY',
        mn.getMissionTime(),true),'native pre-death attack order rejected')
    assert(orderTargets(attacker,red),'native pre-death attack goal was not installed')
    self.AutoPlayerMode=true
    local strikeValue=self:GetCombatValue(attacker)
    assert(strikeValue>0,'offensive control unit has no combat value')
    self:UpdateFactionStrategicPlan('BLUE',mn.getMissionTime(),true)
    frontOperationBeforeDeath=self.AIOperations.BLUE and self.AIOperations.BLUE[redSignature]~=nil or false
    local preDeathState=self.AIOrderState[attackerSignature]
    local opFronts={}; for signature in pairs(self.AIOperations.BLUE or {}) do opFronts[#opFronts+1]=signature end
    table.sort(opFronts)
    local mounts,armed=self:GetStrategicWeapons(attacker)
    log('PRE_DEATH_PLAN',{autoPlayerMode=self.AutoPlayerMode,aiEnabled=self.Config.AI.Enabled,
        faction=self:GetFactionKey(attacker),role=self:GetShipRole(attacker),combatValue=strikeValue,
        profileArmed=self:AIProfile(attacker).armed,weaponsArmed=armed,mounts=#mounts,
        target=preDeathState and preDeathState.targetSignature or -1,
        operationEstablished=frontOperationBeforeDeath,operationFronts=opFronts,
        decisionEvents=decisionEvents,userOrder=self.UserOrders[attackerSignature]~=nil})
    assert(frontOperationBeforeDeath,'failed to establish a pre-death Red operation front')
    assert(decisionEvents>0,'AIEventSink did not observe the pre-death control decision')
    assert(self:IssueStrategicOrder(attacker,red,'elimination callback cleanup control','PRIMARY',
        mn.getMissionTime(),true),'native direct attack control rejected before death')
    preDeathState=self.AIOrderState[attackerSignature]
    assert(preDeathState and preDeathState.targetSignature==redSignature and preDeathState.mission=='PRIMARY'
        and orderTargets(attacker,red),'direct native Red attack was not restored before death')
    log('NATIVE_ATTACK_INSTALLED',{attacker=attackerSignature,target=redSignature,
        faction=self:GetFactionKey(red),hitpoints=red.HitpointsLeft,
        strikeShips=#bombers,screenShips=#screens,strikeValue=strikeValue,
        currentOrderTarget=preDeathState and preDeathState.targetSignature or -1,
        currentMission=preDeathState and preDeathState.mission or 'NONE',
        strategicFront=true,operationEstablished=frontOperationBeforeDeath,
        controlDecisions=decisionEvents})
    self:InvalidateShipList()
    began=mn.getMissionTime(); killedAt=nil; nextAudit=nil; auditCount=0
end

local function runAfterDeath(self,now)
    local primary=self:GetStablePrimaryTarget('BLUE')
    local stableSignature=signature(primary)
    log('PRIMARY_AFTER_CALLBACK',{target=stableSignature,expectedSurvivor=goldSignature,
        dyingStillValid=valid(red),dyingIsDying=valid(red) and red:isDying() or false,
        dyingShipAlive=shipAlive(red),
        dyingHitpoints=valid(red) and red.HitpointsLeft or nil,
        commandLookup=signature(self:GetFactionCommandShip('RED')),
        areEnemiesStillTrue=self:AreEnemies(attacker,red),redEliminated=self.RedEliminated==true})
    assert(self.RedEliminated,'Red was not marked eliminated after native death callback')
    assert(stableSignature==goldSignature,'surviving Gold station was not reselected as Blue primary')

    afterDeath=true
    self:UpdateFactionStrategicPlan('BLUE',now,true)
    local state=self.AIOrderState[attackerSignature]
    local deadFrontOperationRemains=self.AIOperations.BLUE
        and self.AIOperations.BLUE[redSignature]~=nil or false
    local wing=self:GetLogicalWing(attacker)
    local groupId=wing and (wing.id..':'..self:GetShipRole(attacker)) or nil
    local assaultTarget=groupId and self.AIAssaultTargets.BLUE[groupId] or nil
    local goldOperation=self.AIOperations.BLUE and self.AIOperations.BLUE[goldSignature] or nil
    log('STRATEGIC_RETARGET',{attacker=attackerSignature,oldTarget=redSignature,
        newTarget=state and state.targetSignature or -1,nativeGoldOrder=orderTargets(attacker,gold),
        primary=stableSignature,assaultTarget=assaultTarget or -1,
        goldOperationPhase=goldOperation and goldOperation.phase or 'NONE',
        deadTargetDecisions=deadTargetDecisions,goldTargetDecisions=goldTargetDecisions,
        goldPrimaryDecisions=goldPrimaryDecisions,goldAttackDecisions=goldAttackDecisions,
        frontOperationBeforeDeath=frontOperationBeforeDeath,
        deadFrontOperationRemains=deadFrontOperationRemains,
        deadFrontOperationReleased=frontOperationBeforeDeath and not deadFrontOperationRemains,
        commandLookupStillValid=valid(self:GetFactionCommandShip('RED')),
        areEnemiesStillTrue=self:AreEnemies(attacker,red)})
    assert(frontOperationBeforeDeath,'no operation front existed to test cancellation')
    assert(not deadFrontOperationRemains,'dead front operation remained after reassignment')
    assert(deadTargetDecisions==0,'planner emitted a decision targeting the dead station')
    assert(assaultTarget==goldSignature,'assault-front assignment did not move to the surviving Gold station')
    attackDeadline=now+(self.Config.AI.Operations.AssembleSeconds or 45)+8
    nextAudit=now+1
    auditCount=1
end

local function step(self)
    if finished then return end
    local now=mn.getMissionTime()
    if killedAt==nil then
        if now-began<.2 then return end
        -- This public Lua API calls ship_hit_kill(), which establishes the real
        -- native death-roll state and dispatches On Ship Death synchronously.
        log('BEFORE_NATIVE_KILL',{redValid=valid(red),redDying=red:isDying(),
            hitpoints=red.HitpointsLeft,attacker=attackerSignature,
            trackedOrder=self.AIOrderState[attackerSignature]~=nil,
            frontOperation=frontOperationBeforeDeath})
        local killResult=red:kill(attacker)
        log('AFTER_NATIVE_KILL_API',{returned=killResult==true,deathCallbackSeen=deathCallbackSeen,
            redValid=valid(red),redDying=valid(red) and red:isDying() or false,
            hitpoints=valid(red) and red.HitpointsLeft or nil})
        assert(killResult,'native Ship:kill call failed')
        killedAt=now
        assert(deathCallbackSeen,'native On Ship Death hook did not run synchronously')
        runAfterDeath(self,now)
        return
    end
    if not goldAttackConfirmed and now>=nextAudit then
        self:UpdateFactionStrategicPlan('BLUE',now,true)
        local state=self.AIOrderState[attackerSignature]
        local primary=self:GetStablePrimaryTarget('BLUE')
        local deadFrontOperationRemains=self.AIOperations.BLUE
            and self.AIOperations.BLUE[redSignature]~=nil or false
        local wing=self:GetLogicalWing(attacker)
        local groupId=wing and (wing.id..':'..self:GetShipRole(attacker)) or nil
        local assaultTarget=groupId and self.AIAssaultTargets.BLUE[groupId] or nil
        assert(deadTargetDecisions==0,'later decision targeted the dead command station')
        assert(signature(primary)==goldSignature and assaultTarget==goldSignature and not deadFrontOperationRemains,
            'later plan lost the surviving Gold assault front or restored the dead Red front')
        if state and state.targetSignature==goldSignature and state.mission=='PRIMARY'
            and orderTargets(attacker,gold) and goldAttackDecisions>0 then
            goldAttackConfirmed=true
            local rejected=self:IssueStrategicOrder(attacker,red,'rejected dying target control','PRIMARY',now,true)
            assert(rejected==false,'IssueStrategicOrder accepted the still-valid dying station')
            assert(self.AIOrderState[attackerSignature].targetSignature==goldSignature and orderTargets(attacker,gold),
                'rejected dying target replaced or cleared the valid Gold order')
            log('DYING_TARGET_REJECTED',{rejected=true,goldOrderPreserved=true,
                redValid=valid(red),redIsDying=red:isDying(),redHitpoints=red.HitpointsLeft})
            log('GOLD_NATIVE_ATTACK',{elapsed=now-killedAt,target=state.targetSignature,
                decisionCount=goldAttackDecisions,phase=self.AIOperations.BLUE[goldSignature].phase})
        else
            assert(now<attackDeadline,'bounded operation assembly deadline expired before a Gold attack')
        end
        auditCount=auditCount+1; nextAudit=now+1
        log('REPEATED_STRATEGIC_AUDIT',{elapsed=now-killedAt,audit=auditCount,
            target=state and state.targetSignature or -1,mission=state and state.mission or 'NONE',
            assaultTarget=assaultTarget or -1,deadTargetDecisions=deadTargetDecisions,
            goldPrimaryDecisions=goldPrimaryDecisions,goldAttackDecisions=goldAttackDecisions})
    end
    if goldAttackConfirmed then
        log('PASS',{deathRollCallback=true,factionEliminated=true,nativeOrderReleased=true,
            survivingEnemyReselected=true,deadTargetDecisions=deadTargetDecisions,
        goldTargetDecisions=goldTargetDecisions,goldAttackDecisions=goldAttackDecisions,
        repeatedAudits=auditCount,
        deathRollHitpoints=valid(red) and red.HitpointsLeft or nil})
        finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end

local function guard(fn,self)
    if finished then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then
        log('FAIL',{error=err,deathCallbackSeen=deathCallbackSeen,
            redEliminated=self.RedEliminated==true,deadTargetDecisions=deadTargetDecisions,
            goldTargetDecisions=goldTargetDecisions,decisionEvents=decisionEvents})
        finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end

R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
