-- Baseline probe for native On Ship Death killer attribution and RTS bounty.
-- Uses real ship:kill(killer) calls; records results without assuming policy.
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local start=R.OnGameplayStart
local originalOnShipDeath=R.OnShipDeath
local file=cf.openFile('kill-reward-headless.jsonl','w','data')
assert(file and file:isValid())

local function log(event,data)
    file:write(U.json({event=event,data=data})..'\n'); file:flush()
end
local function v(x,y,z) return ba.createVector(x,y,z) end
local function valid(object)
    if object==nil then return false end
    local ok,result=pcall(function() return object:isValid() end)
    return ok and result==true
end
local function signature(object)
    return valid(object) and object:getSignature() or -1
end
local function handleInfo(object)
    if not valid(object) then return {valid=false} end
    local info={valid=true,signature=signature(object)}
    local ok,breed=pcall(function() return object:getBreedName() end)
    if ok then info.breed=breed end
    local nameOk,name=pcall(function() return object.Name end)
    if nameOk then info.name=name end
    local factionOk,faction=pcall(function() return R:GetFactionKey(object) end)
    if factionOk then info.faction=faction end
    return info
end
local function killerInfo(killer)
    local info=handleInfo(killer)
    if not info.valid then return info end
    local owner
    if info.breed=='Weapon' then
        local ok,parent=pcall(function() return killer.Parent end)
        if ok then owner=parent end
        info.ownerProperty='Parent'
    elseif info.breed=='Beam' then
        local ok,parent=pcall(function() return killer.ParentShip end)
        if ok then owner=parent end
        info.ownerProperty='ParentShip'
    elseif info.breed=='Ship' then
        owner=killer
        info.ownerProperty='self'
    end
    if owner~=nil then info.owner=handleInfo(owner) end
    return info
end
local function cpSnapshot(self)
    local states=self.AIStates or {}
    return {
        BLUE=self.CommandPoints,
        RED=states.RED and states.RED.cp or nil,
        GOLD=states.GOLD and states.GOLD.cp or nil,
    }
end
local function cpDelta(before,after)
    local delta={}
    for _,key in ipairs({'BLUE','RED','GOLD'}) do
        if type(before[key])=='number' and type(after[key])=='number' then
            delta[key]=after[key]-before[key]
        end
    end
    return delta
end
local function quiet(ship)
    ship:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#ship do if ship[i]:isTurret() then ship[i].TurretLocked=true end end
end
local function spawn(self,name,team,position)
    local ship=mn.createShip(name,tb.ShipClasses['GTF Hercules'],ba.createOrientation(),position,team,true)
    assert(valid(ship),'failed to spawn '..name)
    quiet(ship)
    self:InvalidateShipList()
    return ship
end

local cases={
    {id='gold_kills_red',killerFaction='GOLD',victimFaction='RED',expectedRewardFaction='GOLD'},
    {id='red_kills_gold',killerFaction='RED',victimFaction='GOLD',expectedRewardFaction='RED'},
    {id='blue_kills_red',killerFaction='BLUE',victimFaction='RED',expectedRewardFaction='BLUE'},
    {id='gold_kills_blue',killerFaction='GOLD',victimFaction='BLUE',expectedRewardFaction='GOLD'},
    {id='red_kills_red',killerFaction='RED',victimFaction='RED'},
    {id='red_self_kill',killerFaction='SELF',victimFaction='RED'},
    {id='red_unknown_killer',killerFaction='UNKNOWN',victimFaction='RED'},
}
local nativeByVictim={}
local currentCase
local nativeHookCount=0
local wrappedCallbackCount=0

R.OnShipDeath=function(self,ship,killer)
    local id=signature(ship)
    local before=cpSnapshot(self)
    local native=nativeByVictim[id]
    local call={victim=handleInfo(ship),argumentCount=2,killerArgumentPresent=killer~=nil,
        killerArgument=killerInfo(killer),
        nativeHookAlreadyObserved=native~=nil,nativeKiller=native and native.killer or nil,
        cpBefore=before}
    log('MOD_CALLBACK_BEFORE',call)
    local result=originalOnShipDeath(self,ship,killer)
    local after=cpSnapshot(self)
    local captured={victimSignature=id,cpBefore=before,cpAfter=after,cpDelta=cpDelta(before,after),
        bountyCP=self.CommandPoints-before.BLUE}
    if currentCase and id==currentCase.victimSignature then
        captured.killerArgument=killerInfo(killer)
        currentCase.modCallback=captured
        wrappedCallbackCount=wrappedCallbackCount+1
    end
    log('MOD_CALLBACK_AFTER',captured)
    return result
end

local function recordNativeDeathHook()
    local victim=hv['Ship']
    local killer=hv['Killer']
    local victimInfo=handleInfo(victim)
    local killerDetails=killerInfo(killer)
    local record={victim=victimInfo,killer=killerDetails,
        killerArgumentPresent=killer~=nil,nativeKillerSignature=signature(killer)}
    if victimInfo.valid then nativeByVictim[victimInfo.signature]=record end
    nativeHookCount=nativeHookCount+1
    log('NATIVE_CALLBACK_ARGUMENTS',record)
end

local began=0
local finished=false
local function runCases(self)
    local blue=self:GetFactionCommandShip('BLUE')
    local teams={
        BLUE=self:GetFactionCommandShip('BLUE').Team,
        RED=self:GetFactionCommandShip('RED').Team,
        GOLD=self:GetFactionCommandShip('GOLD').Team,
    }
    local base=blue.Position+v(26000,12000,34000)
    local allResults={}
    for index,case in ipairs(cases) do
        local position=base+v(index*1700,0,index*900)
        local victimName=string.format('RV%02d',index)
        local killerName=string.format('RK%02d',index)
        log('CASE_SETUP_BEGIN',{case=case.id,index=index,victimName=victimName,killerName=killerName})
        local victim=spawn(self,victimName,teams[case.victimFaction],position)
        local killer
        if case.killerFaction=='SELF' then
            killer=victim
        elseif case.killerFaction~='UNKNOWN' then
            if case.killerFaction=='BLUE_WEAPON' then
                local owner=self:GetFactionCommandShip('BLUE')
                local weaponClass=tb.WeaponClasses['Cyclops#short']
                local classValid=weaponClass~=nil and weaponClass:isValid()
                log('WEAPON_CLASS_CONTROL',{name='Cyclops#short',valid=classValid})
                assert(classValid,'Cyclops#short weapon class unavailable in this workspace')
                log('WEAPON_CREATE_BEGIN',{owner=handleInfo(owner),class='Cyclops#short'})
                killer=mn.createWeapon(tb.WeaponClasses['Cyclops#short'],ba.createOrientation(),
                    position+v(0,900,100),owner)
                assert(valid(killer),'failed to create projectile attribution control')
                log('WEAPON_CREATE_DONE',{weapon=handleInfo(killer),owner=handleInfo(killer.Parent)})
            else
                killer=spawn(self,killerName,teams[case.killerFaction],position+v(0,900,0))
            end
        end

        case.victim=victim; case.victimSignature=signature(victim)
        case.apiKiller=killerInfo(killer)
        case.victimFaction=self:GetFactionKey(victim)
        case.isPlayerEnemy=self:IsPlayerEnemy(victim)
        case.cpBefore=cpSnapshot(self)
        currentCase=case
        log('KILL_API_ARGUMENT',{case=case.id,victim=handleInfo(victim),killer=case.apiKiller,
            playerEnemyVictim=case.isPlayerEnemy,cpBefore=case.cpBefore})
        local accepted
        if killer==nil then accepted=victim:kill() else accepted=victim:kill(killer) end
        assert(accepted,'native ship:kill API rejected case '..case.id)
        assert(case.modCallback~=nil,'RTS On Ship Death callback was not observed for '..case.id)
        assert(nativeByVictim[case.victimSignature]~=nil,
            'native On Ship Death killer hook was not observed for '..case.id)
        case.cpAfter=cpSnapshot(self)
        case.cpDelta=cpDelta(case.cpBefore,case.cpAfter)
        case.nativeKiller=nativeByVictim[case.victimSignature].killer
        case.nativeArgumentPresent=nativeByVictim[case.victimSignature].killerArgumentPresent
        local expectedFaction=case.expectedRewardFaction
        if expectedFaction then
            assert(case.cpDelta[expectedFaction]>0,
                'expected killer faction received no bounty in '..case.id)
        else
            for _,faction in ipairs({'BLUE','RED','GOLD'}) do
                assert(case.cpDelta[faction]==0,'unexpected bounty recipient '..faction..' in '..case.id)
            end
            assert(case.modCallback.bountyCP==0,'unexpected Blue bounty in '..case.id)
        end
        for _,faction in ipairs({'BLUE','RED','GOLD'}) do
            if faction~=expectedFaction then
                assert(case.cpDelta[faction]==0,'wrong faction received bounty in '..case.id)
            end
        end
        log('KILL_REWARD_BASELINE',{case=case.id,killerFaction=case.killerFaction,
            victimFaction=case.victimFaction,playerEnemyVictim=case.isPlayerEnemy,
            expectedRewardFaction=expectedFaction,
            apiKiller=case.apiKiller,nativeKiller=case.nativeKiller,
            modCallbackKiller=case.modCallback.killerArgument,
            nativeArgumentPresent=case.nativeArgumentPresent,
            cpBefore=case.cpBefore,cpAfter=case.cpAfter,cpDelta=case.cpDelta,
            callbackBlueCPDelta=case.modCallback.bountyCP})
        allResults[#allResults+1]={id=case.id,killerFaction=case.killerFaction,
            victimFaction=case.victimFaction,playerEnemyVictim=case.isPlayerEnemy,
            nativeKiller=case.nativeKiller,cpBefore=case.cpBefore,cpAfter=case.cpAfter,
            cpDelta=case.cpDelta}
        currentCase=nil
    end
    assert(nativeHookCount==#cases and wrappedCallbackCount==#cases,
        'not every case reached both native killer hook and RTS callback')
    local summary={caseCount=#cases,nativeHookCount=nativeHookCount,
        wrappedCallbackCount=wrappedCallbackCount,cases=allResults}
    log('BASELINE_SUMMARY',summary)
    local caseIds={}; for _,case in ipairs(cases) do caseIds[#caseIds+1]=case.id end
    log('PASS',{caseCount=#cases,nativeKillerObserved=true,blueRedGoldCPRecorded=true,caseIds=caseIds})
    finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
end

local function init(self)
    start(self); self:EndIntroCinematic(true)
    self.SetupOpponents={RED=true,GOLD=true}; self.SetupAutoMode=false
    self:StartScenario(); self.Config.AI.Enabled=false
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do quiet(self:GetFactionCommandShip(kind)) end
    self:ResetCoordinatedAI()
    assert(self.AIStates.RED and self.AIStates.GOLD,'AI CP state missing for RED/GOLD')
    self.CombatTelemetryEnabled=false
    local ok=engine.addHook('On Ship Death',recordNativeDeathHook)
    assert(ok,'engine.addHook On Ship Death registration failed')
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        assert(valid(self:GetFactionCommandShip(kind)),'missing command station '..kind)
    end
    log('SETUP',{commandPoints=cpSnapshot(self),nativeDeathHookRegistered=ok,
        playerEnemyCheck={RED=self:IsPlayerEnemy(self:GetFactionCommandShip('RED')),
            GOLD=self:IsPlayerEnemy(self:GetFactionCommandShip('GOLD')),
            BLUE=self:IsPlayerEnemy(self:GetFactionCommandShip('BLUE'))}})
    began=mn.getMissionTime()
end

local function step(self)
    if finished or mn.getMissionTime()-began<.2 then return end
    local ok,err=xpcall(function() runCases(self) end,debug.traceback)
    if not ok then
        log('FAIL',{error=err,cases=wrappedCallbackCount,nativeHooks=nativeHookCount})
        finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end

local function guard(fn,self)
    if finished then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then
        log('FAIL',{error=err,cases=wrappedCallbackCount,nativeHooks=nativeHookCount})
        finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end

R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
