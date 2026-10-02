local R=require 'fs2rts'
local start=R.OnGameplayStart
local file=cf.openFile('station-fixes.txt','w','data')
assert(file and file:isValid())
local function log(s) file:write(s..'\n'); file:flush() end
local function v(x,y,z) return ba.createVector(x,y,z) end
local function disarm(s)
    s:setFlag(true,'immobile','primaries-locked','secondaries-locked','weapons-locked')
    for i=1,#s do if s[i]:isTurret() then s[i].TurretLocked=true; s[i].BeamFree=false end end
end
local rows={}; local began; local sample=1; local times={1,5,19,20.1,21}
local phase=1; local phaseStart=0; local waitingUntil; local classes={'GTC Leviathan','GTF Hercules','GTB Medusa'}
local fighter; local initialAB; local targets={}; local strikeDone=false
local blue; local repairHull; local repairSeen=false
local function init(self)
    start(self); self:EndIntroCinematic(true)
    self.SetupOpponents={RED=true,GOLD=true}; self.SetupAutoMode=false; self:StartScenario()
    self.Config.AI.Enabled=false
    for _,state in pairs(self.StationState) do state.nextAIThink=math.huge end
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local base=self:GetFactionCommandShip(kind); disarm(base)
        self.StationState[kind].nextAIThink=math.huge
        local initial=base.HitpointsMax
        local cap=self:GetFleetCap(kind); local radius=self:GetSentryRadius(kind)
        local oldTier=self.GetCurrentEscalationTier
        self.GetCurrentEscalationTier=function() return 4 end
        for _,track in ipairs({'armor','defenses','logistics','command'}) do
            for level=1,3 do
                self:RefundFactionCP(kind,10000); assert(self:BuyUpgrade(kind,track))
                self.StationState[kind].upgrade.finishTime=mn.getMissionTime()
                self:UpdateStations(mn.getMissionTime())
                assert(self:GetUpgradeLevel(kind,track)==level)
                log('UPGRADE|'..kind..'|'..track..'|'..level..'|hull='..base.HitpointsMax..'|income='..self:GetIncomeMultiplier(kind)..'|build='..self:GetBuildTimeMultiplier(kind)..'|fleet='..self:GetFleetCap(kind)..'|sentries='..self:GetSentryCap(kind))
            end
        end
        self.GetCurrentEscalationTier=oldTier
        assert(math.abs(base.HitpointsMax-initial*1.6)<1)
        assert(self:GetFleetCap(kind)==cap+8 and self:GetSentryRadius(kind)==radius+2000)
        local n=0
        for i=1,#base do if base[i]:isTurret() then n=n+1 end end
        self.StationState[kind].levels.defenses=3; self:ApplyUpgrade(kind,'defenses',3)
        for i=1,#base do if base[i]:isTurret() then assert(math.abs(base[i].FireRateMultiplier-1.25)<.001) end end
        log('BASE_RATE|'..kind..'|turrets='..n)
        self.StationState[kind].levels.command=3
    end
    for _,kind in ipairs({'BLUE','GOLD','RED'}) do
        for _,option in ipairs(self:GetSentryOptions(kind)) do
            local base=self:GetFactionCommandShip(kind)
            local spot=self:FindSentrySpot(kind); assert(spot)
            local sentry=self:PlaceSentry(kind,option,spot,true); assert(sentry and sentry:isValid())
            local heading=v(0,0,1)
            if option.role=='beam' then
                local localH=sentry[1]:getTurretHeading(); local o=sentry.Orientation
                heading=o:getRvec()*localH.x+o:getUvec()*localH.y+o:getFvec()*localH.z
                assert(math.abs(heading.y)<.01,'beam points vertically')
                local dx,dz=spot.x-base.Position.x,spot.z-base.Position.z; local length=math.sqrt(dx*dx+dz*dz)
                assert((heading.x*dx+heading.z*dz)/math.max(1,length)>.95,'Mjolnir beam axis does not face its placement lane')
            end
            local origin=v(#rows*15000,40000,60000); sentry.Position=origin
            local target=mn.createShip('Target '..#rows,tb.ShipClasses['GTC Leviathan'],ba.createOrientation(),origin+heading*650,mn.Teams[kind=='BLUE' and 'hostile' or 'friendly'],true)
            disarm(target); target.Shields.CombinedMax=0; target.Shields.CombinedLeft=0
            target.HitpointsMax=1000000; target.HitpointsLeft=1000000
            rows[#rows+1]={sentry=sentry,target=target,option=option,fired=0,origin=origin,heading=heading}
            local banks={}
            for i=1,#sentry do if sentry[i]:isTurret() then
                assert(math.abs(sentry[i].FireRateMultiplier-1.25)<.001)
                for b=1,#sentry[i].PrimaryBanks do
                    local w=sentry[i].PrimaryBanks[b].WeaponClass
                    banks[#banks+1]=w.Name..':range='..w.effectiveRange
                    log('WEAPON|'..w.Name..'|speed='..w.Speed..'|life='..w.LifeMax..'|range='..w.Range)
                end
            end end
            log('LOADOUT|'..option.class..'|hull='..sentry.HitpointsMax..'|'..table.concat(banks,','))
        end
    end
    self:InvalidateShipList()
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local counts=self:CountAIRoleUnits(kind); assert(counts.fighter==0,'sentries counted as fighters')
    end
    local red=self:GetFactionCommandShip('RED')
    fighter=self:SpawnFactionUnit('SF Mara',red,red.Team,'Surge',0,1,1,1,1)
    fighter.Position=red.Position+v(1000,0,0); disarm(fighter)
    initialAB=fighter.Physics.AfterburnerVelocityMax.z
    self:InvalidateShipList(); assert(self:UseSwarmSurge('RED'))
    blue=self:GetCarrier(); local point=blue.Position+v(7000,0,0)
    local cp=self:GetFactionCP('GOLD')
    assert(self:UseReinforcementJump('GOLD')); assert(self:GetFactionCP('GOLD')==cp)
    assert(not self:UseReinforcementJump('GOLD'))
    self:InvalidateShipList()
    local jumped=false
    for _,s in ipairs(self:GetShipList()) do if s.Class.Name=='GVCv Sobek' then jumped=true; disarm(s) end end
    assert(jumped); log('JUMP|PASS no CP spent; native Sobek spawned; cooldown enforced')
    blue.HitpointsLeft=blue.HitpointsMax*.5; repairHull=blue.HitpointsLeft
    self.StationState.BLUE.lastHull=blue.HitpointsMax
    log('NEW_SHIP_LOOKUP|valid='..tostring(fighter:isValid())..'|hull='..fighter.HitpointsLeft..'|lookup='..tostring(self:FindShipBySignature(fighter:getSignature())~=nil))
    self:UpdateStations(mn.getMissionTime())
    local state=self.StationState.BLUE
    assert(not self:QueueOrbitalStrike('BLUE',blue.Position+v(13000,0,0)))
    assert(state.abilityReadyAt==0,'rejected strike consumed cooldown')
    local function target(name,team,offset,shield)
        local s=mn.createShip(name,tb.ShipClasses['GTF Hercules'],ba.createOrientation(),point+offset,mn.Teams[team],true)
        disarm(s); s.HitpointsMax=10000; s.HitpointsLeft=10000
        s.Shields.CombinedMax=shield; s.Shields.CombinedLeft=shield
        targets[#targets+1]=s; return s
    end
    target('Shield enemy','hostile',v(0,0,0),10000)
    target('Friend','friendly',v(0,100,0),0)
    target('High','hostile',v(0,5000,0),0)
    target('Outside','hostile',v(2000,0,0),0)
    assert(self:QueueOrbitalStrike('BLUE',point))
    began=mn.getMissionTime(); log('INITIALIZED')
end
local function step(self)
    self:InvalidateShipList(); self:DisarmObserverWeapons()
    local now=mn.getMissionTime(); self:UpdateStations(now); local t=now-began
    if waitingUntil then
        if t<waitingUntil then return end
        for i,row in ipairs(rows) do
            local team=row.sentry.Team==mn.Teams.friendly and mn.Teams.hostile or mn.Teams.friendly
            row.target=mn.createShip('Phase '..phase..' target '..i,tb.ShipClasses[classes[phase]],ba.createOrientation(),row.origin+row.heading*650,team,true)
            disarm(row.target); row.target.Shields.CombinedMax=0; row.target.Shields.CombinedLeft=0
            row.target.HitpointsMax=1000000; row.target.HitpointsLeft=1000000; row.fired=0
        end
        waitingUntil=nil; phaseStart=t
    end
    for _,row in ipairs(rows) do
        if row.option.role~='beam' then
            local angle=math.floor(t/10)*math.pi/2
            row.target.Position=row.origin+v(math.sin(angle)*650,0,math.cos(angle)*650)
        end
        for i=1,#row.sentry do if row.sentry[i]:isTurret() and row.sentry[i]:hasFired() then row.fired=row.fired+1 end end
    end
    if sample<=#times and t>=times[sample] then
        local surge=self.SurgedShips[fighter:getSignature()]
        if t<self.Config.Station.ArmorRepairDelay then assert(blue.HitpointsLeft==repairHull,'repair starts in combat delay')
        else assert(blue.HitpointsLeft>repairHull,'station never repairs') end
        log(string.format('SURGE|t=%.2f|max=%.2f|AB=%.2f',t,fighter.Physics.VelocityMax.z,fighter.Physics.AfterburnerVelocityMax.z))
        log('REPAIR|t='..t..'|gained='..(blue.HitpointsLeft-repairHull))
        if t<20 then
            assert(surge and math.abs(fighter.Physics.VelocityMax.z-surge.velocity.z*1.5)<.01)
            assert(math.abs(fighter.Physics.AfterburnerVelocityMax.z-initialAB*1.5)<.01)
        else assert(not surge and math.abs(fighter.Physics.AfterburnerVelocityMax.z-initialAB)<.01) end
        sample=sample+1
    end
    if not repairSeen and t>self.Config.Station.ArmorRepairDelay+1 then
        assert(blue.HitpointsLeft>repairHull,'station never repairs after configured delay'); repairSeen=true
    end
    if not strikeDone and t>=6 then
        for _,s in ipairs(targets) do log('STRIKE|'..s.Name..'|hull='..s.HitpointsLeft..'|shield='..s.Shields.CombinedLeft) end
        assert(targets[1].HitpointsLeft==10000 and targets[1].Shields.CombinedLeft<10000,'shields ignored')
        assert(targets[2].HitpointsLeft<10000,'friendly fire absent')
        assert(targets[3].HitpointsLeft==10000 and targets[4].HitpointsLeft==10000,'blast reach incorrect')
        strikeDone=true
    end
    if phase>#classes and not rangeCheckStarted then
        rangeCheckStarted=true; phaseStart=t
        for _,row in ipairs(rows) do if row.option.role=='beam' then
            row.target:vanish(); local range=row.option.range or 4000
            local team=row.sentry.Team==mn.Teams.friendly and mn.Teams.hostile or mn.Teams.friendly
            row.target=mn.createShip('Mjolnir range target',tb.ShipClasses['GTC Leviathan'],ba.createOrientation(),
                row.origin+row.heading*(range+1200),team,true)
            disarm(row.target); row.target.HitpointsMax=1000000; row.target.HitpointsLeft=1000000
        end end
        log('MJOLNIR_RANGE_CHECK|started'); return
    end
    if phase>#classes and rangeCheckStarted and not rangeCheckDone and t-phaseStart>=8 then
        for _,row in ipairs(rows) do if row.option.role=='beam' then
            assert(row.target.HitpointsLeft==1000000,'Mjolnir damaged a target beyond its configured '..row.option.range..' m reach')
        end end
        rangeCheckDone=true; log('MJOLNIR_RANGE_CHECK|PASS')
    end
    if t-phaseStart>=40 then
        for _,row in ipairs(rows) do
            if phase>#classes then break end
            local damage=1000000-row.target.HitpointsLeft
            log('COMBAT|'..row.option.class..'|target='..classes[phase]..'|fired='..row.fired..'|damage='..damage)
            if phase==1 then assert(damage>0,'no damage from '..row.option.class) end
        end
        phase=phase+1; phaseStart=t
        if phase>#classes then
            if not rangeCheckDone then return end
            assert(repairSeen,'configured repair boundary not exercised')
            log('PASS'); ProbeDone=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
        else
            -- Let beams/projectiles from the previous trial expire before
            -- spawning a fresh target, so their damage cannot contaminate it.
            for _,row in ipairs(rows) do row.target:vanish() end
            waitingUntil=t+10
        end
    end
end
local function guard(fn,self)
    if ProbeDone then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then log('FAIL '..err); ProbeDone=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
end
R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
