-- Prove killer ownership for native weapon and beam damage; no Ship:kill or
-- direct damage. The victims have real low hull and must die from gameplay.
local R=require 'fs2rts'
local U=require 'fs2rts_ai_util'
local start=R.OnGameplayStart
local originalDeath=R.OnShipDeath
local file=cf.openFile('kill-reward-natural-fire.jsonl','w','data')
assert(file and file:isValid())
local function log(event,data) file:write(U.json({event=event,data=data})..'\n'); file:flush() end
local function v(x,y,z) return ba.createVector(x,y,z) end
local function valid(o) return o~=nil and o:isValid() end
local function sig(o) return valid(o) and o:getSignature() or -1 end
local function basic(o)
    if not valid(o) then return {valid=false} end
    local result={valid=true,signature=sig(o)}
    local ok,breed=pcall(function() return o:getBreedName() end); if ok then result.breed=breed end
    -- Native userdata property errors can throw outside Lua pcall in unattended mode.
    -- Weapon/beam handles expose ownership, not the ship-only Name property.
    if result.breed=='Ship' then
        result.name=o.Name
        result.faction=R:GetFactionKey(o)
    end
    return result
end
local function killerData(killer)
    local result=basic(killer)
    if not result.valid then return result end
    local owner
    if result.breed=='Weapon' then result.ownerProperty='Parent'; owner=killer.Parent
    elseif result.breed=='Beam' then result.ownerProperty='ParentShip'; owner=killer.ParentShip
    elseif result.breed=='Ship' then result.ownerProperty='self'; owner=killer end
    if owner~=nil then result.owner=basic(owner) end
    return result
end
local function cp(self)
    return {BLUE=self.CommandPoints,RED=self.AIStates.RED.cp,GOLD=self.AIStates.GOLD.cp}
end
local function delta(before,after)
    return {BLUE=after.BLUE-before.BLUE,RED=after.RED-before.RED,GOLD=after.GOLD-before.GOLD}
end
local function quiet(s)
    s:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#s do if s[i]:isTurret() then s[i].TurretLocked=true end end
end
local function spawn(name,class,team,pos)
    local s=mn.createShip(name,tb.ShipClasses[class],ba.createOrientation(),pos,team,true)
    assert(valid(s),'failed to spawn '..name)
    R:EnableFullArsenal(s)
    return s
end

local blue,red,projectileShooter,projectileVictim,beamShooter,beamVictim
local currentCase,nativeDeaths={},{}
local phase='setup'; local phaseAt=0; local lastFire=-1
local projectileResult,beamResult
local finished=false

local function nativeDeathHook()
    local victim=hv['Ship']; local killer=hv['Killer']; local victimSig=sig(victim)
    local record={victim=basic(victim),killerArgumentPresent=killer~=nil,killer=killerData(killer)}
    if victimSig>=0 then nativeDeaths[victimSig]=record end
    log('NATIVE_ON_SHIP_DEATH',record)
end

R.OnShipDeath=function(self,ship,killer)
    local id=sig(ship); local before=cp(self)
    local record={victim=basic(ship),killerArgumentPresent=killer~=nil,killer=killerData(killer),cpBefore=before}
    log('MOD_CALLBACK_BEFORE',record)
    local result=originalDeath(self,ship,killer)
    local after=cp(self)
    local captured={victim=basic(ship),killerArgumentPresent=killer~=nil,killer=killerData(killer),
        cpBefore=before,cpAfter=after,cpDelta=delta(before,after)}
    if currentCase and id==currentCase.victimSig then currentCase.mod=captured end
    log('MOD_CALLBACK_AFTER',captured)
    return result
end

local function beginProjectile(self)
    local position=blue.Position+v(26000,5000,30000)
    projectileShooter=spawn('Natural projectile owner','GTF Hercules',self:GetFactionCommandShip('GOLD').Team,position)
    R:EnableFullArsenal(projectileShooter)
    projectileVictim=spawn('Natural projectile victim','GTF Hercules',red.Team,position+v(0,0,850))
    quiet(projectileVictim)
    projectileVictim.Shields.CombinedMax=0; projectileVictim.Shields.CombinedLeft=0
    projectileVictim.HitpointsMax=100; projectileVictim.HitpointsLeft=100
    assert(#projectileShooter.PrimaryBanks>0,'projectile shooter has no primary bank')
    currentCase={id='primary_weapon',victimSig=sig(projectileVictim),ownerSig=sig(projectileShooter),cpBefore=cp(self)}
    assert(self:IssueStrategicOrder(projectileShooter,projectileVictim,'natural projectile attribution','PRIMARY',
        mn.getMissionTime(),true),'native attack order rejected')
    phase='projectile'; phaseAt=mn.getMissionTime(); lastFire=-1
    log('PROJECTILE_SETUP',{shooter=basic(projectileShooter),victim=basic(projectileVictim),
        victimHull=projectileVictim.HitpointsLeft,victimShields=projectileVictim.Shields.CombinedLeft,
        nativeOrder=true,initialCP=currentCase.cpBefore})
end

local function verifyDeath(case,expectedBreed,owner)
    local native=nativeDeaths[case.victimSig]
    if not case.mod or not native then return false end
    local callbackKiller=case.mod.killer
    local nativeKiller=native.killer
    local ownerSignature=callbackKiller.owner and callbackKiller.owner.signature
    local nativeOwner=nativeKiller.owner and nativeKiller.owner.signature
    local victim=R:FindShipBySignature(case.victimSig)
    assert(valid(victim),'death callback victim vanished before reward verification')
    local mapped=R.ShipCostMap[victim.Class.Name]
    local expectedBounty=math.max(R.Config.Bounties.Minimum or 25,
        math.floor((mapped and mapped.cost or 100)*(R.Config.Bounties.DefaultFractionOfCost or .24)))
    local paid=case.mod.cpDelta
    local faction=callbackKiller.owner and callbackKiller.owner.faction
    assert(faction=='BLUE' or faction=='RED' or faction=='GOLD','killer faction missing')
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        assert(paid[kind]==(kind==faction and expectedBounty or 0),
            'kill reward must pay the exact bounty exclusively to the owner')
    end
    local after=cp(R)
    case.result={native=nativeKiller,callback=callbackKiller,owner=owner,
        cpBefore=case.cpBefore,cpAfter=after,cpDelta=delta(case.cpBefore,after),
        victim=case.mod.victim,killerArgumentPresent=case.mod.killerArgumentPresent}
    log('NATURAL_KILL_RESULT',{case=case.id,killer=nativeKiller,victim=case.mod.victim,
        callbackKiller=callbackKiller,ownerSignature=ownerSignature,nativeOwnerSignature=nativeOwner,
        expectedOwnerSignature=owner,expectedBreed=expectedBreed,cpBefore=case.cpBefore,
        cpAfter=after,cpDelta=case.result.cpDelta})
    return callbackKiller.breed==expectedBreed and ownerSignature==owner
        and nativeKiller.breed==expectedBreed and nativeOwner==owner
end

local function beginBeam(self)
    currentCase=nil
    local position=blue.Position+v(36000,5000,30000)
    beamShooter=spawn('Natural beam owner','GTD Hecate',red.Team,position)
    R:EnableFullArsenal(beamShooter)
    beamVictim=spawn('Natural beam victim','GTC Leviathan',blue.Team,position+v(0,0,3500))
    quiet(beamVictim); beamVictim.Shields.CombinedMax=0; beamVictim.Shields.CombinedLeft=0
    beamVictim.HitpointsMax=400; beamVictim.HitpointsLeft=400
    local beamMounts=0
    for i=1,#beamShooter do
        local sub=beamShooter[i]
        if sub:isTurret() then
            local hasBeam=false
            for _,banks in ipairs({sub.PrimaryBanks,sub.SecondaryBanks}) do
                for j=1,#banks do
                    local bank=banks[j]
                    if bank:isValid() and bank.WeaponClass:isValid() and bank.WeaponClass:isBeam() then hasBeam=true end
                end
            end
            if hasBeam then sub.TurretLocked=false; beamMounts=beamMounts+1 else sub.TurretLocked=true end
        end
    end
    if beamMounts==0 then
        log('BEAM_UNAVAILABLE',{class=beamShooter.Class.Name,reason='no beam turret mounted'})
        finished=true; phase='done'
        log('PROJECTILE_PASS_BEAM_UNVERIFIED',{projectile=projectileResult,beam='unavailable'})
        ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
        return
    end
    self:InvalidateShipList()
    currentCase={id='beam_weapon',victimSig=sig(beamVictim),ownerSig=sig(beamShooter),cpBefore=cp(self)}
    assert(self:IssueStrategicOrder(beamShooter,beamVictim,'natural beam attribution','PRIMARY',
        mn.getMissionTime(),true),'native beam-ship attack order rejected')
    phase='beam'; phaseAt=mn.getMissionTime()
    log('BEAM_SETUP',{shooter=basic(beamShooter),victim=basic(beamVictim),beamMounts=beamMounts,
        victimHull=beamVictim.HitpointsLeft,victimShields=beamVictim.Shields.CombinedLeft,
        nativeOrder=true,initialCP=currentCase.cpBefore})
end

local function init(self)
    start(self); self:EndIntroCinematic(true)
    self.SetupOpponents={RED=true,GOLD=true}; self.SetupAutoMode=false
    self:StartScenario(); self.Config.AI.Enabled=false
    blue=self:GetFactionCommandShip('BLUE'); red=self:GetFactionCommandShip('RED')
    assert(valid(blue) and valid(red),'Blue and Red command stations required')
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do quiet(self:GetFactionCommandShip(kind)) end
    self:ResetCoordinatedAI()
    assert(self.AIStates.RED and self.AIStates.GOLD,'faction CP states missing')
    local ok=engine.addHook('On Ship Death',nativeDeathHook)
    assert(ok,'native On Ship Death observer registration failed')
    log('SETUP',{CP=cp(self),nativeHookRegistered=ok,
        weaponParentAPI='Weapon.Parent',beamParentAPI='Beam.ParentShip'})
    self:InvalidateShipList(); beginProjectile(self)
end

local function step(self)
    if finished then return end
    local now=mn.getMissionTime()
    if phase=='projectile' then
        if now-lastFire>=.25 then
            lastFire=now
            local fired=projectileShooter:firePrimary()
            local secondaryFired=projectileShooter:fireSecondary()
            log('PROJECTILE_FIRE',{time=now-phaseAt,primaryShots=fired,secondaryShots=secondaryFired,
                victimHull=projectileVictim.HitpointsLeft,
                distance=projectileShooter.Position:getDistance(projectileVictim.Position)})
        end
        if currentCase and currentCase.mod and nativeDeaths[currentCase.victimSig] then
            projectileResult=verifyDeath(currentCase,'Weapon',sig(projectileShooter))
            assert(projectileResult,'natural projectile Killer/Parent did not identify the shooter')
            assert(currentCase.result.cpDelta.GOLD>0,
                'natural projectile owner did not receive Gold command points')
            log('PROJECTILE_PASS',{owner=sig(projectileShooter),ownerCP=currentCase.result.cpDelta})
            beginBeam(self)
        elseif now-phaseAt>45 then
            log('PROJECTILE_NO_DEATH',{hull=projectileVictim.HitpointsLeft,
                shotsAttempted=true,owner=basic(projectileShooter)})
            finished=true; phase='done'
            log('FAIL',{reason='real primary fire did not kill the low-hull target within 45 sim seconds'})
            ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
        end
    elseif phase=='beam' then
        if currentCase and currentCase.mod and nativeDeaths[currentCase.victimSig] then
            beamResult=verifyDeath(currentCase,'Beam',sig(beamShooter))
            if beamResult then
                assert(currentCase.result.cpDelta.RED>0,
                    'natural beam owner did not receive Red command points')
                log('BEAM_PASS',{owner=sig(beamShooter),ownerCP=currentCase.result.cpDelta})
                log('PASS',{projectileOwnerVerified=true,beamOwnerVerified=true})
            else
                log('BEAM_KILL_OWNER_MISMATCH',{observed=currentCase.result.native,
                    expectedOwner=sig(beamShooter)})
                log('PROJECTILE_PASS_BEAM_UNVERIFIED',{projectile=projectileResult,
                    beam='death observed but not attributed to the beam owner'})
            end
            finished=true; phase='done'; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
        elseif now-phaseAt>45 then
            log('BEAM_NO_DEATH',{elapsed=now-phaseAt,hull=beamVictim.HitpointsLeft,
                nativeAIOrder=true,beamMounts=true})
            log('PROJECTILE_PASS_BEAM_UNVERIFIED',{projectile=projectileResult,
                beam='no natural beam death within 45 sim seconds'})
            finished=true; phase='done'; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
        end
    end
end

local function guard(fn,self)
    if finished then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then
        log('FAIL',{error=err,phase=phase,projectile=projectileResult,beam=beamResult})
        finished=true; phase='done'; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end

R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
