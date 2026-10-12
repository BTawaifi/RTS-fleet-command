-- Upstream-native check for fighter chip weapon routing. Run rendered to page
-- and draw cloned primary/secondary assets while checking collision and blast paths.
local R=require 'fs2rts'
local out=cf.openFile('fighter-blast-probe.log','w','data')
assert(out and out:isValid())
local function log(s) out:write(s..'\n'); out:flush() end
local function check(ok,s) assert(ok,s); log('PASS '..s) end
local finished,stage,at=false,0,0
local station,fighter,bomber,ordinary,childParent,support,sentry
local surfacePoint,stationSignature,secondChipStart
local fighterBaseHull,fighterBaseSubsystems,fighterHullDelta,fighterSubsystemDelta,secondChipDelta,bomberBaseHull,bomberHullDelta,ordinaryHull
local fighterWeapon,bomberWeapon,ordinaryWeapon,piranha,orphanPiranha
local childSafeCount=0
local createdEventCount=0
local childCountBeforeOrphan=0
local collisionHitsByParent={}
local shipCollisionEventsByParent={}
local fighterDirectStart,fighterDirectDelta,fighterDirectRatio,guardedHullStart,guardedHullDelta
local orientation=ba.createOrientationFromVectors(ba.createVector(0,0,1))
local direction=ba.createVector(1,0,0)
local originalFrame=R.OnFrame

local function create(name,class,pos,team)
    local teamHandle=type(team)=='string' and mn.Teams[team] or team
    local ship=mn.createShip(name,tb.ShipClasses[class],
        ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos,teamHandle,true)
    assert(ship:isValid(),'failed to create '..class)
    R:InvalidateShipList()
    return ship
end

local function subsystemHP(ship)
    local total=0
    for i=1,#ship do total=total+(ship[i].HitpointsLeft or 0) end
    return total
end

local function stationImpactPoint(ship)
    local hit=ship:checkRayCollision(ship.Position-direction*6000,ship.Position+direction*6000)
    assert(hit,'could not find a native station surface point')
    return hit
end

local function spawnWeapon(class,parent,position,expectedClass,detonateNow)
    local weaponClass=tb.WeaponClasses[class]
    assert(weaponClass and weaponClass:isValid(),'missing weapon class '..class)
    local before=createdEventCount
    local weapon=mn.createWeapon(weaponClass,orientation,position,parent)
    assert(weapon and weapon:isValid(),'native weapon creation failed for '..class)
    assert(createdEventCount>before,'native On Weapon Created did not run for '..class)
    assert(weapon.Class.Name==expectedClass,
        'expected '..expectedClass..' after creation, got '..tostring(weapon.Class.Name))
    local role=R:GetShipRole(parent)
    if role=='fighter' and expectedClass:sub(1,5)=='RTSF ' then
        assert(R.BaseDamageProtectedWeapons[weapon:getSignature()]==false,
            'successfully routed fighter variant is not marked as chip-allowed')
    elseif not R:CanDamageBase(parent) then
        assert(R.BaseDamageProtectedWeapons[weapon:getSignature()]==true,
            'nonfighter or unmapped non-strike weapon is not protected')
    end
    if detonateNow~=false then assert(weapon:detonate(),'failed to detonate '..class) end
    return weapon
end

local function directBurst(parent,class,expectedClass,count)
    local weaponClass=tb.WeaponClasses[class]
    assert(weaponClass and weaponClass:isValid(),'missing direct weapon class '..class)
    local createdBefore=createdEventCount
    local sig=parent:getSignature()
    local directOrientation=ba.createOrientationFromVectors(direction)
    for i=1,count do
        local side=(i%8-3.5)*6
        local row=(math.floor((i-1)/8)-1.5)*6
        local position=surfacePoint-direction*80+ba.createVector(0,side,row)
        local weapon=mn.createWeapon(weaponClass,directOrientation,position,parent)
        assert(weapon and weapon:isValid(),'native direct weapon creation failed for '..class)
        if i==1 then
            assert(weapon.Class.Name==expectedClass,
                'expected direct weapon class '..expectedClass..', got '..tostring(weapon.Class.Name))
            if R:GetShipRole(parent)=='fighter' and expectedClass:sub(1,5)=='RTSF ' then
                assert(R.BaseDamageProtectedWeapons[weapon:getSignature()]==false,
                    'routed direct fighter weapon is not chip-allowed')
            elseif not R:CanDamageBase(parent) then
                assert(R.BaseDamageProtectedWeapons[weapon:getSignature()]==true,
                    'unmapped/nonfighter direct weapon is not protected')
            end
        end
    end
    assert(createdEventCount-createdBefore==count,'native creation hook missed direct burst weapons')
    return sig
end

local function quit()
    finished=true; R:SetTimeScale(1)
    ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
end

engine.addHook('On Frame',function()
    if finished then ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
end)
R.Config.Cinematic.Enabled=false
R.Config.AI.ExperimentalDamageTelemetry=false
R.Config.Pilot.NativeWingExtensions=false
local function probe(self)
    local now=mn.getMissionTime()
    if stage==0 and self.SetupActive then
        local aliases=0
        for index=1,#tb.WeaponClasses do
            local variant=tb.WeaponClasses[index]
            if variant.Name:sub(1,5)=='RTSF ' then
                local source=tb.WeaponClasses[variant.Name:sub(6)]
                assert(source and source:isValid(),'missing native source for '..variant.Name)
                for _,field in ipairs({'Range','Damage','ArmorFactor'}) do
                    assert(math.abs(variant[field]-source[field])<.0001,
                        'native fighter variant bypasses '..field..' override: '..variant.Name)
                end
                aliases=aliases+1
            end
        end
        check(aliases==44,'all 44 native fighter aliases preserve loaded range/damage/armor factors')
        self.SetupOpponents={RED=true,GOLD=false}
        self.SetupAutoMode=false; self.SetupSentries=false; self.SetupAsteroids=false
        check(engine.addHook('On Ship Collision',function()
            local target,weapon=hv['Ship'],hv['Weapon']
            if target and target:isValid() and R:IsCommandStation(target)
                and weapon and weapon:isValid() and weapon.Parent and weapon.Parent:isValid() then
                local parentSig=weapon.Parent:getSignature()
                shipCollisionEventsByParent[parentSig]=(shipCollisionEventsByParent[parentSig] or 0)+1
            end
        end),'early native station collision observer registers')
        check(self:SetFactionChoice('BLUE','GTVA'),'native fighter blast fixture selects GTVA')
        self:StartScenario()
        self.Config.AI.Enabled=false
        for _,ship in ipairs(self:GetShipList()) do
            if ship.Name~=self.Config.ObserverShip and not self:IsCommandStation(ship) then ship:vanish() end
        end
        self:InvalidateShipList()
        station=self:GetFactionCommandShip('RED')
        assert(station and station:isValid(),'RED command station missing')
        stationSignature=station:getSignature()
        for i=1,#station do if station[i]:isTurret() then station[i].TurretLocked=true end end
        station.Shields.CombinedLeft=0
        surfacePoint=stationImpactPoint(station)
        fighter=create('Blast test fighter','GTF Myrmidon',station.Position+ba.createVector(2500,0,0),self.Config.FriendlyTeam)
        bomber=create('Blast test bomber','GTB Artemis',station.Position+ba.createVector(-2500,0,0),self.Config.FriendlyTeam)
        ordinary=create('Blast control target','GTF Ulysses',station.Position+ba.createVector(0,1800,0),mn.Teams[self.Config.HostileTeam])
        childParent=create('Blast child parent','GTF Myrmidon',ordinary.Position+ba.createVector(0,1200,0),self.Config.FriendlyTeam)
        support=create('Chip support direct guard','GTF Ulysses',station.Position-direction*2500+ba.createVector(0,800,0),self.Config.FriendlyTeam)
        sentry=create('Chip sentry direct guard','GTSG Watchdog',station.Position-direction*2500+ba.createVector(0,-800,0),self.Config.FriendlyTeam)
        self.RoleByClass=self.RoleByClass or {}; self.RoleByClass[support.Class.Name]='support'
        self.StaticDefenseSignatures=self.StaticDefenseSignatures or {}
        self.StaticDefenseSignatures[sentry:getSignature()]=true
        ordinary:setFlag(true,'immobile')
        support:setFlag(true,'immobile'); sentry:setFlag(true,'immobile')
        ordinary.Shields.CombinedLeft=0
        fighterBaseHull=station.HitpointsLeft; fighterBaseSubsystems=subsystemHP(station)
        local variantClass=tb.WeaponClasses['RTSF Trebuchet']
        local registered=0; for _,ok in pairs(self.BaseDamageProtectionHooks or {}) do if ok then registered=registered+1 end end
        check(engine.addHook('On Weapon Created',function()
            createdEventCount=createdEventCount+1
            local weapon=hv.Weapon
            if weapon and weapon:isValid() and weapon.Class.Name=='RTSF Cluster Baby' then
                childSafeCount=childSafeCount+1
            end
        end),'native weapon-created observer registers')
        check(engine.addHook('On Weapon Collision',function()
            local target,weapon=hv['Self'],hv['Weapon']
            if target and target:isValid() and target:getSignature()==stationSignature
                and weapon and weapon:isValid() and weapon.Parent and weapon.Parent:isValid() then
                local parentSig=weapon.Parent:getSignature()
                collisionHitsByParent[parentSig]=(collisionHitsByParent[parentSig] or 0)+1
            end
        end,{['Ship']=station.Name}),'native station direct-collision observer registers')
        log(string.format('DIAG fighter=%s role=%s supportRole=%s sentryRole=%s canDamageBase=%s hooks=%d variantValid=%s',
            fighter.Class.Name,tostring(self:GetShipRole(fighter)),tostring(self:GetShipRole(support)),
            tostring(self:GetShipRole(sentry)),tostring(self:CanDamageBase(fighter)),
            registered,tostring(variantClass and variantClass:isValid())))
        log('HOOK ACTIVATION YIELDED; deterministic native weapon creation begins next frame')
        at=now; stage=1
    elseif stage==1 then
        fighterWeapon=spawnWeapon('Trebuchet',fighter,surfacePoint,'RTSF Trebuchet')
        check(self.FighterBlastVariantsLoaded and self.FighterBlastVariantsLoaded['RTSF Trebuchet']==true,
            'variant assets page in successfully before the first class swap')
        at=now; stage=2
    elseif stage==2 and now-at>=1 then
        fighterHullDelta=fighterBaseHull-station.HitpointsLeft
        fighterSubsystemDelta=fighterBaseSubsystems-subsystemHP(station)
        check(fighterHullDelta>0,'fighter Trebuchet blast chips command-station hull')
        -- Simulate a mission paging boundary: weapon tables stay valid, native
        -- weapon POF caches are invalidated, and StartScenario resets this Lua
        -- cache before registering/using the next match hooks.
        self.FighterBlastVariantsLoaded={}
        check(tb.WeaponClasses['RTSF Trebuchet']:loadWeapon(),
            'native weapon class pages again after mission-cache reset')
        secondChipStart=station.HitpointsLeft
        fighterWeapon=spawnWeapon('Trebuchet',fighter,stationImpactPoint(station),'RTSF Trebuchet')
        check(self.FighterBlastVariantsLoaded['RTSF Trebuchet']==true,
            'runtime route reloads variant after mission-cache reset')
        at=now; stage=3
    elseif stage==3 and now-at>=1 then
        secondChipDelta=secondChipStart-station.HitpointsLeft
        check(secondChipDelta>0 and math.abs(secondChipDelta-fighterHullDelta)<0.15,
            're-paged fighter variant repeats the same small station chip')
        bomberBaseHull=station.HitpointsLeft
        bomberWeapon=spawnWeapon('Trebuchet',bomber,stationImpactPoint(station),'Trebuchet')
        at=now; stage=4
    elseif stage==4 and now-at>=1 then
        check(station.HitpointsLeft<bomberBaseHull-0.01,
            'original bomber Trebuchet damages the same command-station surface')
        bomberHullDelta=bomberBaseHull-station.HitpointsLeft
        check(bomberHullDelta>0 and math.abs(fighterHullDelta/bomberHullDelta-0.05)<0.002,
            'fighter Trebuchet station damage is approximately five percent of the matched bomber weapon')
        ordinaryHull=ordinary.HitpointsLeft
        ordinaryWeapon=spawnWeapon('Trebuchet',fighter,ordinary.Position,'RTSF Trebuchet')
        at=now; stage=5
    elseif stage==5 and now-at>=1 then
        check(ordinary.HitpointsLeft<ordinaryHull-0.01,
            'fighter variant blast still damages an ordinary hostile ship')
        fighterDirectStart=station.HitpointsLeft
        directBurst(fighter,'Subach HL-7','RTSF Subach HL-7',32)
        at=now; stage=6
    elseif stage==6 and now-at>=2 then
        fighterDirectDelta=fighterDirectStart-station.HitpointsLeft
        local fighterHits=collisionHitsByParent[fighter:getSignature()] or 0
        local sourceClass=tb.WeaponClasses['Subach HL-7']
        local normalDamage=fighterHits*sourceClass.Damage*sourceClass.ArmorFactor
        check(fighterHits>0,'routed fighter primary guns reach the native station collision path')
        check(fighterDirectDelta>0 and normalDamage>0,
            'routed fighter primary guns deal positive station chip damage')
        fighterDirectRatio=fighterDirectDelta/normalDamage
        check(fighterDirectRatio>0.045 and fighterDirectRatio<0.055,
            'routed fighter primary guns deal about five percent of source damage')
        guardedHullStart=station.HitpointsLeft
        directBurst(support,'Subach HL-7','Subach HL-7',16)
        directBurst(sentry,'Subach HL-7','Subach HL-7',16)
        directBurst(fighter,'RTS Sentry Interceptor','RTS Sentry Interceptor',16)
        at=now; stage=7
    elseif stage==7 and now-at>=2 then
        guardedHullDelta=guardedHullStart-station.HitpointsLeft
        check((shipCollisionEventsByParent[support:getSignature()] or 0)>0,
            'support-role direct weapons reach the protected collision path')
        check((shipCollisionEventsByParent[sentry:getSignature()] or 0)>0,
            'sentry-role direct weapons reach the protected collision path')
        check((shipCollisionEventsByParent[fighter:getSignature()] or 0)>32,
            'unmapped fighter direct weapons reach the protected collision path')
        check(math.abs(guardedHullDelta)<0.01,
            'support, sentry, and unmapped direct weapons remain blocked at command stations')
        piranha=spawnWeapon('Piranha',childParent,station.Position+ba.createVector(3000,5000,0),'RTSF Piranha',false)
        check(piranha:detonate(),'fighter Piranha detonates with its launcher alive')
        at=now; stage=8
    elseif stage==8 and now-at>=1 then
        check(childSafeCount>0,'Piranha spawn graph creates fighter-safe cluster children')
        childCountBeforeOrphan=childSafeCount
        orphanPiranha=spawnWeapon('Piranha',childParent,station.Position+ba.createVector(3000,5000,0),'RTSF Piranha',false)
        childParent:vanish()
        at=now; stage=9
    elseif stage==9 and now-at>=1 then
        check(not childParent:isValid(),'second Piranha launcher ship is destroyed before detonation')
        check(orphanPiranha and orphanPiranha:isValid() and orphanPiranha:detonate(),
            'second Piranha remains detonatable after launcher destruction')
        at=now; stage=10
    elseif stage==10 and now-at>=1 then
        check(childSafeCount==childCountBeforeOrphan,
            'upstream suppresses child spawning when the launcher ship no longer exists')
        log(string.format('RESULT fighterBlastChip=%.3f repeatChip=%.3f bomberHullDelta=%.3f blastRatio=%.5f fighterDirectChip=%.3f directRatio=%.5f guardedDirectDelta=%.3f ordinaryShipDelta=%.3f safeChildren=%d',
            fighterHullDelta,secondChipDelta,bomberHullDelta,fighterHullDelta/bomberHullDelta,
            fighterDirectDelta,fighterDirectRatio,guardedHullDelta,ordinaryHull-ordinary.HitpointsLeft,childSafeCount))
        log('COMPLETE fighter blast protection native probe')
        quit()
    end
end

R.OnFrame=function(self)
    if finished then ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']); return end
    local ok,err=pcall(function() originalFrame(self); probe(self) end)
    if not ok then log('FAIL '..tostring(err)); quit() end
end
