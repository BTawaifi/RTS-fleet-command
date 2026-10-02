-- Proves logical wingmates join the player's existing native starting wing.
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local start=R.OnGameplayStart
local file=cf.openFile('pilot-wing-headless.jsonl','w','data'); assert(file and file:isValid())
local function log(event,data) file:write(U.json({event=event,data=data})..'\n'); file:flush() end
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
local function nativeOrder(ship,orderType,target)
    for i=1,#ship.Orders do
        local order=ship.Orders[i]
        if order:isValid() and order:getType()==orderType and order.Target:isValid()
            and order.Target:getSignature()==target:getSignature() then return true end
    end
    return false
end

local base,observer,wing,pilot,mates,target,baselineMembers,baselineDisplay,began,phase= nil,nil,nil,nil,{},nil,{},nil,nil,0
local finished=false

local function assertNativeRoster(self,expected)
    assert(#wing==expected,'native wing count mismatch: '..tostring(#wing)..' ~= '..tostring(expected))
    for i,signature in ipairs(baselineMembers) do
        assert(wing[i]:getSignature()==signature,'original observer-wing member moved or was replaced')
    end
    for i,ship in ipairs(mates) do
        assert(ship:getWing():getBreedName()=='Wing' and ship:getWing().Name==wing.Name,
            'logical wingmate is not in native wing '..i)
    end
    for _,entry in ipairs(R.PilotNativeWing.members) do
        assert(entry.hudWingIndex>=0 and entry.hudSlot>=0,
            'native wingmember lacks a wingman HUD slot')
    end
end

local function init(self)
    start(self); self:EndIntroCinematic(true)
    self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario(); self.Config.AI.Enabled=false
    base=self:GetFactionCommandShip('BLUE')
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do quiet(self:GetFactionCommandShip(kind)) end
    target=spawn('Pilot wing order target','GTD Hecate',base.Position+v(0,0,5000),self:GetFactionCommandShip('RED').Team)
    quiet(target)
    pilot=spawn('Pilot wing member 1','GTB Medusa',base.Position+v(-250,0,1400),base.Team)
    mates={
        spawn('Pilot wing member 2','GTF Hercules',base.Position+v(250,0,1400),base.Team),
        spawn('Pilot wing member 3','GTF Hercules',base.Position+v(500,0,1600),base.Team),
    }
    local logical=self:RegisterLogicalWing({pilot,mates[1],mates[2]},'Blue Beta')
    assert(logical and #logical.signatures==3)
    self:InvalidateShipList()
    observer=self:GetObserver(); assert(observer and observer:isValid())
    wing=observer:getWing(); assert(wing and #wing>0 and wing.Name=='Alpha','player proxy is not in native starting wing Alpha')
    baselineDisplay=wing.DisplayName
    for i=1,#wing do baselineMembers[i]=wing[i]:getSignature() end
    began=mn.getMissionTime(); phase=1
    assert(self:StartPilotMode(pilot),'pilot possession failed')
    assert(R.PilotNativeWing and R.PilotNativeWing.name=='Alpha','logical wing did not join native starting wing')
    assertNativeRoster(self,#baselineMembers+#mates)
    assert(wing.DisplayName=='Blue Beta','native wing display did not use the logical wing label')
    local removeOriginalOk,removedOriginal=pcall(function() return wing:removePlayerWingMember(observer) end)
    assert(removeOriginalOk and removedOriginal~=true and #wing==#baselineMembers+#mates,
        'temporary membership API removed the original mission/player ship')

    local hudSlots={}
    for _,entry in ipairs(R.PilotNativeWing.members) do
        local key=tostring(entry.hudWingIndex)..':'..tostring(entry.hudSlot)
        assert(not hudSlots[key],'two members share a wingman HUD slot')
        hudSlots[key]=true
    end
    local accepted=mates[1]:giveOrder(ORDER_ATTACK,target,nil,.88)
    assert(accepted==true and nativeOrder(mates[1],ORDER_ATTACK,target),
        'native wingmate rejected an ordinary FreeSpace attack order')
    log('PILOT_JOINED_NATIVE_WING',{label=wing.DisplayName,baselineCount=#baselineMembers,
        currentCount=#wing,members=#R.PilotNativeWing.members,wingIndex=R.PilotNativeWing.members[1].hudWingIndex,
        hudSlots=hudSlots,ordinaryAttackAccepted=true})
end

local function step(self)
    if finished or phase==0 then return end
    local elapsed=mn.getMissionTime()-began
    if phase==1 and elapsed>=1 then
        self:TogglePilotMode()
        assert(self.PossessedSignature==nil and #wing==#baselineMembers,
            'normal pilot exit did not restore original native wing roster')
        assert(wing.DisplayName==baselineDisplay,'normal exit did not restore original wing label')
        for _,ship in ipairs(mates) do assert(ship:getWing():getBreedName()~='Wing','normal exit left a wingmate attached') end
        log('PILOT_EXIT_RESTORED',{elapsed=elapsed,count=#wing,displayName=wing.DisplayName})
        phase=2
    elseif phase==2 and elapsed>=2 then
        assert(self:StartPilotMode(pilot),'pilot re-entry failed')
        assertNativeRoster(self,#baselineMembers+#mates)
        log('PILOT_REENTRY_NO_DUPLICATES',{elapsed=elapsed,count=#wing})
        phase=3
    elseif phase==3 and elapsed>=3 then
        assert(pilot:kill(),'pilot ship native kill failed')
        self:UpdatePilotMode(6)
        assert(self.PossessedSignature==nil,'pilot death did not eject back to RTS')
        assert(#wing==#baselineMembers and wing.DisplayName==baselineDisplay,
            'death eject did not restore original native wing state')
        for _,ship in ipairs(mates) do assert(ship:getWing():getBreedName()~='Wing','death eject left a wingmate attached') end
        log('PILOT_DEATH_RESTORED',{elapsed=elapsed,count=#wing,displayName=wing.DisplayName,
            pilotDying=pilot:isDying()})
        phase=0; finished=true
        log('PASS',{elapsed=elapsed,logicalMembers=3,nativeHUDSlots=true,
            ordinaryNativeOrder=true,normalExit=true,reentry=true,deathExit=true})
        ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    elseif elapsed>15 then error('pilot wing lifecycle probe exceeded its bound') end
end

local function guard(fn,self)
    if finished then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then
        log('FAIL',{error=err}); finished=true
        if self.PossessedSignature~=nil then pcall(function() self:ExitPilotMode(nil,true) end) end
        ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end
R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
