-- Paid fighter-rush replay. Normal AI/economy/defenses remain active.
local R=require 'fs2rts'
local out=cf.openFile('fighter-rush-probe.log','w','data')
assert(out and out:isValid())
local kind=R.ReviewRushFaction or 'RED'
local count=R.ReviewRushFighters or 18
-- Default 120 s keeps the original fixed-window comparison; the runner raises it for long attacks.
local attackSeconds=R.ReviewRushAttackSeconds or 120
-- Mission-time cap. Raise it when a long attack starts late (48 fighters attack near 1240 s).
local maxSeconds=R.ReviewRushMaxSeconds or 1800
-- Optional: place the paid fighters on an arc around the target station at this distance (m)
-- and bearing (deg, world XZ) instead of letting them fly in from the build yard. 0 keeps the default.
local spawnDistance=R.ReviewRushSpawnDistance or 0
local spawnBearing=math.rad(R.ReviewRushSpawnBearing or 0)
local spawnArc=math.rad(40)
-- Measurement only: from the attack onward, vanish RED ships of these roles (comma list, e.g. "capital,bomber")
-- once a second, to test what that role contributes to the base kill and to the counter-attack.
local removeRoles={}
for role in string.gmatch(R.ReviewRushRemoveRoles or '','[^,]+') do removeRoles[role]=true end
local removedCounts={}; local nextRemoval=0
local nextSignatureLog=0
local stage,finished,startTime,lastSample,attackAt=0,false,0,-100,nil
local attackers={}; local ownCollisions={}; local collisionCount=0
local recentBaseContacts={}; local previousBaseHull
local function log(s) out:write(s..'\n'); out:flush() end
local function quit() finished=true; R:SetTimeScale(1); ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
engine.addHook('On Frame',function() if finished then ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end end)
engine.addHook('On Ship Collision',function()
    local a,b=hv.Ship,hv.ShipB
    if a and b and a:isValid() and b:isValid() and (R:IsCommandStation(a) or R:IsCommandStation(b)) then
        local station=R:IsCommandStation(a) and a or b; local other=station==a and b or a
        recentBaseContacts[station:getSignature()]={at=mn.getMissionTime(),kind='SHIP',source=other.Name..'/'..other.Class.Name,faction=R:GetFactionKey(other)}
    end
    if a and b and a:isValid() and b:isValid() and (R:IsCommandStation(a) or R:IsCommandStation(b))
        and R:GetFactionKey(a)==R:GetFactionKey(b) then
        local x,y=a:getSignature(),b:getSignature(); if x>y then x,y=y,x end
        local key=x..':'..y; local now=mn.getMissionTime()
        if ownCollisions[key]~=now then
            ownCollisions[key]=now; collisionCount=collisionCount+1
            log('OWN_BASE_COLLISION t='..now..' faction='..tostring(R:GetFactionKey(a))..' a='..a.Name..' b='..b.Name)
            local moving=R:IsCommandStation(a) and b or a
            local order=R.UserOrders[moving:getSignature()] or R.AIOrderState[moving:getSignature()] or {}
            log('COLLISION_ORDER kind='..tostring(order.kind or order.mission)..' reason='..tostring(order.reason)
                ..' position='..tostring(moving.Position)..' destination='..tostring(order.destination)
                ..' target='..tostring(order.targetSignature))
        end
    end
end)
engine.addHook('On Weapon Collision',function()
    local target,weapon=hv.Self,hv.Weapon
    if target and target:isValid() and target:getBreedName()=='Ship' and R:IsCommandStation(target) and weapon and weapon:isValid() then
        recentBaseContacts[target:getSignature()]={at=mn.getMissionTime(),kind='WEAPON',source=weapon.Class.Name}
    end
end)
engine.addHook('On Debris Collision',function()
    local station,piece=hv.Ship,hv.Debris
    if station and station:isValid() and R:IsCommandStation(station) and piece and piece:isValid() then
        recentBaseContacts[station:getSignature()]={at=mn.getMissionTime(),kind='DEBRIS',source=piece.OriginClass.Name}
        log('BASE_DEBRIS t='..mn.getMissionTime()..' class='..piece.OriginClass.Name..' mass='..piece.Physics.Mass..' hull='..station.HitpointsLeft)
    end
end)
engine.addHook('On Ship Death Started',function()
    local ship=hv.Ship
    if ship and ship:isValid() and R:IsCommandStation(ship) then
        local killer=R:ResolveKillRewardShip(hv.Killer)
        local source=hv.Killer
        local breed=source and source:isValid() and source:getBreedName() or 'INVALID'
        local parent=source and source:isValid() and source.Parent
        log('BASE_DEATH t='..mn.getMissionTime()..' name='..ship.Name..' hull='..ship.HitpointsLeft..' max='..ship.HitpointsMax..' killer='..(killer and killer.Name..'/'..killer.Class.Name or 'UNKNOWN')..' breed='..breed..' parent='..(parent and parent:isValid() and tostring(parent) or 'NONE'))
    end
end)
R.Config.Cinematic.Enabled=false
R.Config.AI.ExperimentalDamageTelemetry=R.ReviewProbeHeadless==true
if R.ReviewProbeHeadless then
    -- Diagnostic-only extension in the experimental engine. The mod remains
    -- disabled by default and the upstream replay uses collision/death hooks.
    engine.addHook('On Ship Damage',function()
        local target=hv.Target
        if target and target:isValid() and R:IsCommandStation(target) and (hv.HullDamage or 0)>1000 then
            log('RESOLVED_SPIKE t='..mn.getMissionTime()..' damage='..hv.HullDamage..' source='..tostring(hv.SourceKind)..' weapon='..tostring(hv.WeaponClass)..' type='..tostring(hv.DamageType)..' lethal='..tostring(hv.LethalHit))
        end
    end)
end
local original=R.OnFrame
local function sample(self,now)
    local blue,foes,defending=0,0,0
    self:EachShip(function(ship)
        if ship:isValid() and not ship:isDying() and ship.HitpointsLeft>0 and not self:IsCommandStation(ship) and not self:IsStaticDefense(ship) then
            if attackers[ship:getSignature()] then blue=blue+1 end
            if self:GetFactionKey(ship)==kind then
                foes=foes+1
                local order=self.AIOrderState[ship:getSignature()]
                if order and attackers[order.targetSignature] then defending=defending+1 end
            end
        end
    end)
    local base=self:GetFactionCommandShip(kind); local carrier=self:GetCarrier()
    log(string.format('SAMPLE t=%.1f phase=%d blueHull=%.1f enemyHull=%.1f attackers=%d defenders=%d targetingRush=%d ownBaseCollisions=%d',
        now-startTime,stage,carrier and carrier:isValid() and carrier.HitpointsLeft or 0,
        base and base:isValid() and base.HitpointsLeft or 0,blue,foes,defending,collisionCount))
end
local function probe(self)
    if stage==0 and self.Enabled and self.SetupActive then
        self.SetupOpponents={RED=kind=='RED',GOLD=kind=='GOLD'}; self.SetupAutoMode=false; self.SetupSentries=false
        self:StartScenario(); startTime=mn.getMissionTime(); stage=1; self:SetTimeScale(self.ReviewRushTimeScale or 16)
        log('START faction='..kind..' requestedFighters='..count..' BlueStartingCP='..self.CommandPoints)
    elseif stage>0 then
        local now=mn.getMissionTime()
        local base=self:GetFactionCommandShip(kind)
        if base and base:isValid() then
            local hp=base.HitpointsLeft
            if previousBaseHull and previousBaseHull-hp>1000 then
                local contact=recentBaseContacts[base:getSignature()] or {}
                log('BASE_SPIKE t='..now..' damage='..(previousBaseHull-hp)..' kind='..tostring(contact.kind)..' source='..tostring(contact.source)..' age='..(now-(contact.at or now)))
            end
            previousBaseHull=hp
        end
        if now>=nextSignatureLog and stage>=1 and stage<3 then
            -- Warp-in signature check: do queued hulls get spawn points, and does the draw emit lines?
            nextSignatureLog=now+2
            local jobs=self.BuildQueue or {}
            local started=0
            for _,job in ipairs(jobs) do if job.started then started=started+1 end end
            local sigs=self:GetBuildSignatures(now)
            -- The engine's gr table ignores reassigned functions, so the draw reports its own marker count.
            local okDraw,markers=pcall(function() return self:DrawBuildSignatures() end)
            log(string.format('BUILD_SIG t=%.1f jobs=%d started=%d sigs=%d markersDrawn=%s carrier=%s drawOk=%s err=%s',
                now,#jobs,started,#sigs,tostring(markers),tostring(self:GetCarrier()~=nil),tostring(okDraw),tostring(not okDraw and markers or nil)))
            for _,sig in ipairs(sigs) do
                log(string.format('BUILD_SIG_POS x=%.0f y=%.0f z=%.0f class=%s',
                    sig.pos.x,sig.pos.y,sig.pos.z,tostring(sig.job.option.class)))
            end
        end
        if attackAt and next(removeRoles) and now>=nextRemoval then
            nextRemoval=now+1
            local doomed={}
            self:EachShip(function(ship)
                if self:GetFactionKey(ship)=='RED' and not self:IsCommandStation(ship) and removeRoles[self:GetShipRole(ship)] then doomed[#doomed+1]=ship end
            end)
            for _,ship in ipairs(doomed) do
                local role=self:GetShipRole(ship); removedCounts[role]=(removedCounts[role] or 0)+1
                ship:vanish()
            end
        end
        if now-lastSample>=30 then sample(self,now); lastSample=now end
        if self.PostBattleActive or (attackAt and now-attackAt>=attackSeconds) or now-startTime>=maxSeconds then
            -- A battle result (base destroyed) is a real outcome that can come before the
            -- attack window; the exposure is still reported in COMPLETE below.
            if self.PostBattleActive then assert(attackAt,'battle ended before the rush attack started')
            else assert(attackAt and now-attackAt>=attackSeconds,'rush ended without '..attackSeconds..' seconds of accepted attack exposure') end
            sample(self,now); self:FlushAITrace()
            for role,n in pairs(removedCounts) do log('REMOVED role='..role..' count='..n) end
            log('COMPLETE outcome='..self.GameStatus..' elapsed='..(now-startTime)
                ..' attackSeconds='..(now-attackAt)..' ownBaseCollisions='..collisionCount); quit(); return
        end
        if stage==1 then
            local quote=self:GetPurchaseEstimate('GTF Myrmidon',1,count)
            if self.CommandPoints>=quote.cost then
                self:QueueBuildOption({class='GTF Myrmidon',label='Paid rush',role='fighter',count=count,tier=1,cost=quote.cost,time=quote.time})
                assert(#self.BuildQueue==1,'paid rush did not enter the normal build queue')
                log('PURCHASE cost='..quote.cost..' baseSeconds='..quote.time..' bankAfter='..self.CommandPoints); stage=2
            end
        elseif stage==2 and #self.BuildQueue==0 then
            local selected={}
            self:EachShip(function(ship)
                if self:IsFriendly(ship) and ship.Class.Name=='GTF Myrmidon' then selected[#selected+1]=ship:getSignature(); attackers[ship:getSignature()]=true end
            end)
            assert(#selected==count,'paid rush produced the wrong number of hulls')
            local targetStation=self:GetFactionCommandShip(kind)
            -- Base shape at attack time: facing and turret offsets, so bearings can be read against the layout.
            local front=targetStation.Orientation:getFvec()
            log(string.format('STATION_FRONT x=%.4f z=%.4f',front.x,front.z))
            for i=1,#targetStation do
                local turret=targetStation[i]
                if turret and turret:isValid() and turret:isTurret() then
                    local offset=turret.WorldPosition-targetStation.Position
                    log(string.format('BASE_TURRET name=%s x=%.0f y=%.0f z=%.0f',turret.Name,offset.x,offset.y,offset.z))
                end
            end
            if spawnDistance>0 then
                for i,signature in ipairs(selected) do
                    local ship=self:FindShipBySignature(signature)
                    local t=count>1 and (i-1)/(count-1)-0.5 or 0
                    local a=spawnBearing+t*spawnArc
                    ship.Position=targetStation.Position+ba.createVector(math.cos(a)*spawnDistance,0,math.sin(a)*spawnDistance)
                end
                log(string.format('SPAWN_RING distance=%d bearing=%.0f arc=40 count=%d',spawnDistance,math.deg(spawnBearing),count))
            end
            self.Selected=selected; self:IssueAttack(targetStation)
            for _,signature in ipairs(selected) do
                local order=self.UserOrders[signature]
                assert(order and order.kind=='attack' and order.targetSignature==self:GetFactionCommandShip(kind):getSignature(),
                    'rush command was not accepted for every paid fighter')
            end
            -- Enable the AI trace at attack start, so the file holds the attack window
            -- rather than the whole approach. The trace is off by default (AI.TraceFileEnabled).
            if R.ReviewRushTrace==true then
                R.Config.AI.TraceFileEnabled=true; R.Config.AI.DetailedUnitTelemetry=true
                R:StartAITrace()
            end
            attackAt=now
            log('ATTACK t='..(now-startTime)..' count='..#selected); stage=3
        end
    end
end
R.OnFrame=function(self)
    if finished then return end
    local ok,err=pcall(function() original(self); probe(self) end)
    if not ok then log('FAIL '..tostring(err)); quit() end
end
return true
