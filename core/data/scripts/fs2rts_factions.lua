-- Scenario timing, faction/ship queries, spawning helpers, state reset.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:GetDurationProfile()
    local durations = self.Config.Setup.Durations or {}
    return durations[self.SetupDurationIndex or 1] or durations[1]
end

-- Mission time, which advances with time compression. This is the clock the
-- economy and AI difficulty ramp run on: 16x genuinely means 16x resources per
-- real second, the standard RTS bargain.
function RTS:GetScenarioElapsed(now)
    if self.ScenarioStartTime == nil then return 0 end
    return math.max(0, (now or mn.getMissionTime()) - self.ScenarioStartTime)
end

-- The scenario has ONE clock: mission time. 1.4.1 also kept a wall-clock
-- accumulator (ba.getRealFrametime) and drove the escalation tiers off it, on
-- the theory that 16x should not compress the advertised schedule. That made
-- the tier schedule the only thing in a match that ignored the speed control,
-- so skipping to 8x sped up the fleets but not the escalation. Removed: with
-- the tiers back on mission time there is nothing left that needs a second
-- clock, and two disagreeing clocks is how the bug stayed invisible.


function RTS:GetCurrentEscalationTier(now)
    if self.SetupActive or self.ScenarioStartTime == nil then return 1 end
    local duration = self:GetDurationProfile()
    local unlocks = duration and duration.tierUnlocks or { 0, 300, 900, 1800 }
    -- Mission time, NOT wall-clock. 1.4.1 drove this off an accumulator built
    -- from ba.getRealFrametime() so that time compression could not accelerate
    -- escalation, but that made the tier schedule the one thing in the match
    -- that ignored the speed control: skip to 8x and the fleets still fight to
    -- the same advertised schedule while everything else runs 8x faster. The
    -- schedule now follows the game clock, as it did in 1.3.0, so choosing a
    -- higher speed genuinely shortens the match.
    local elapsed = self:GetScenarioElapsed(now)
    local tier = 1
    for i = 1, #unlocks do if elapsed >= unlocks[i] then tier = i end end
    return clamp(tier, 1, math.max(1,#unlocks))
end

function RTS:GetTierUnlockRemaining(tier, now)
    local duration = self:GetDurationProfile()
    if duration == nil or duration.tierUnlocks == nil then return 0 end
    local unlock = duration.tierUnlocks[tier] or 0
    return math.max(0, unlock - self:GetScenarioElapsed(now))
end

function RTS:IsBuildOptionUnlocked(option, now)
    if option == nil then return false end
    return (option.tier or 1) <= self:GetCurrentEscalationTier(now)
end

function RTS:GetFactionKey(ship)
    if not shipValid(ship) then return nil end
    if self:IsFriendly(ship) then return "BLUE" end
    if self:IsHostile(ship) then return "RED" end
    if self:IsThirdFaction(ship) then return "GOLD" end
    return nil
end

function RTS:GetFactionDefinition(key)
    return self.Config.Factions and self.Config.Factions[key] or nil
end

function RTS:GetFactionCommandShip(key)
    if key == "BLUE" then return self:GetCarrier() end
    if key == "RED" then return self:GetEnemyCommand() end
    if key == "GOLD" then return self:GetThirdCommand() end
    return nil
end

function RTS:AreEnemies(a, b)
    if not shipValid(a) or not shipValid(b) then return false end
    if a.Team == nil or b.Team == nil or not a.Team:isValid() or not b.Team:isValid() then return false end
    -- FSO IFF data is global and can be extended by another mod. Keep the RTS
    -- faction boundary explicit so a same-faction ship can never become an AI
    -- attack target even if an inherited IFF entry says the teams are hostile.
    if a.Team == b.Team then return false end
    local aFaction, bFaction = self:GetFactionKey(a), self:GetFactionKey(b)
    if aFaction ~= nil and aFaction == bFaction then return false end
    return a.Team:attacks(b.Team)
end

function RTS:EnforceCursorState()
    -- Alt-tab / focus changes can make FSO reacquire relative mouse mode and
    -- leave the OS cursor hidden.  RTS mode owns an absolute visible pointer,
    -- while possession owns the captured/hidden mouse.  Reassert the desired
    -- state every frame so focus transitions cannot strand either mode.
    if self.PossessedSignature ~= nil then
        io.MouseControlStatus = true
        io.setCursorHidden(true)
    else
        io.MouseControlStatus = false
        io.setCursorHidden(false)
    end
end

function RTS:CountFactionCombatants(key)
    local count = 0
    local station = self:GetFactionCommandShip(key)
    local stationSig = shipValid(station) and station:getSignature() or nil
    self:EachShip(function(ship)
        if shipAlive(ship) and self:GetFactionKey(ship) == key then
            -- Sentries have their own cap and never count against fleet cap.
            if ship:getSignature() ~= stationSig and not self:IsStaticDefense(ship) then count = count + 1 end
        end
    end)
    return count
end

function RTS:FormatTime(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Real seconds for UI timers (status, announcements, double-click, markers).
-- Mission time scales with game speed and stops at pause (speed 0), which made
-- messages vanish at 16x and never expire while paused. OnFrame accumulates
-- ba.getRealFrametime(), and OnFrame keeps running at speed 0.
function RTS:UINow()
    return self.UIClock or 0
end

function RTS:ShowAnnouncement(text, seconds, factionKey)
    self.AnnouncementText = tostring(text or "")
    self.AnnouncementFaction = factionKey
    self.AnnouncementUntil = self:UINow() + (seconds or 5)
end


function RTS:IsFactionEnabled(kind)
    if kind == "BLUE" then return true end
    return self.SetupOpponents ~= nil and self.SetupOpponents[kind] == true
end

function RTS:UpdateFactionCount()
    local count = 1
    if self:IsFactionEnabled("RED") then count = count + 1 end
    if self:IsFactionEnabled("GOLD") then count = count + 1 end
    self.SetupFactionCount = count
end

function RTS:GetShipRole(ship)
    if not shipValid(ship) then return "combat" end
    if self:IsStaticDefense(ship) then return "sentry" end
    -- Role depends only on the class (static config + model radius), and this
    -- runs per ship per frame in hover picking and throughout the planner.
    local className = ship.Class.Name
    local cached = self.RoleByClass[className]
    if cached == nil then cached = self:ComputeClassRole(ship); self.RoleByClass[className] = cached end
    return cached
end

function RTS:IsStaticDefense(ship)
    return shipValid(ship) and self.StaticDefenseSignatures ~= nil
        and self.StaticDefenseSignatures[ship:getSignature()] == true
end

function RTS:ComputeClassRole(ship)
    for _, option in ipairs(self.Config.ProductionClasses or {}) do
        if option.class == ship.Class.Name then return option.role or "combat" end
    end
    for _, kind in ipairs({"RED","GOLD"}) do
        local e = self:GetAIRosterEntry(kind, ship.Class.Name)
        if e ~= nil then return e.role or "combat" end
    end
    local name = string.upper(ship.Class.Name or "")
    if string.find(name, "GTB ", 1, true) or string.find(name, "GVB ", 1, true) or string.find(name, "SB ", 1, true) then return "bomber" end
    local r = ship.Class.Model and ship.Class.Model.Radius or 0
    if r >= 700 then return "capital" end
    return "fighter"
end

function RTS:IsCapitalTarget(ship)
    if not shipValid(ship) then return false end
    if ship.Name == self.Config.CarrierShip or ship.Name == self.Config.EnemyCommandShip or ship.Name == self.Config.ThirdCommandShip then return true end
    local role = self:GetShipRole(ship)
    if role == "capital" or role == "heavy" or role == "juggernaut" or role == "escort" then return true end
    local radius = ship.Class.Model and ship.Class.Model.Radius or 0
    return radius >= 220
end

function RTS:FindBomberPriorityTarget(ship)
    if not shipValid(ship) then return nil end
    local stationBest, capitalBest, capitalScore = nil, nil, -1
    self:EachShip(function(other)
        if shipValid(other) and self:AreEnemies(ship, other) then
            local isStation = other.Name == self.Config.CarrierShip or other.Name == self.Config.EnemyCommandShip or other.Name == self.Config.ThirdCommandShip
            if isStation then
                if stationBest == nil or other.Position:getDistance(ship.Position) < stationBest.Position:getDistance(ship.Position) then stationBest = other end
            elseif self:IsCapitalTarget(other) then
                local radius = other.Class.Model and other.Class.Model.Radius or 1
                local hull = math.max(1, other.HitpointsMax or 1)
                local score = radius * 4 + math.sqrt(hull) - other.Position:getDistance(ship.Position) * 0.01
                if score > capitalScore then capitalBest, capitalScore = other, score end
            end
        end
    end)
    return stationBest or capitalBest
end

function RTS:EnableFullArsenal(ship)
    if not shipValid(ship) then return end
    -- Retail/FSPort capital beams may exist in the turret loadout but remain
    -- beam-locked unless explicitly freed.  Clear turret locks and free every
    -- beam-capable turret; pcall makes this harmless on non-turret subsystems.
    -- This is the runtime half of the Blue station's beam guarantee: GTI Arcadia
    -- is a +nocreate override, so it inherits the retail turret list and every
    -- one of those beams stays locked until this runs.  InitializeUnitOrders
    -- covers all three station classes and SpawnGoldFaction the runtime-created
    -- one, so no per-faction call is needed.
    for i = 1, #ship do
        local subsystem = ship[i]
        if subsystem ~= nil and subsystem:isValid() then
            pcall(function() subsystem.TurretLocked = false end)
            pcall(function() subsystem.BeamFree = true end)
        end
    end
end

function RTS:AuditShipArsenal(ship)
    if not shipValid(ship) then return end
    local turrets,primaries,secondaries,beams=0,0,0,0; local names={}
    for i=1,#ship do
        local subsystem=ship[i]
        if subsystem~=nil and subsystem:isValid() then
            local p,q=subsystem.PrimaryBanks,subsystem.SecondaryBanks; local pc,sc=0,0; pcall(function() pc=#p end); pcall(function() sc=#q end)
            if pc+sc>0 then turrets=turrets+1 end
            for b=1,pc do local bank=p[b]; if bank and bank:isValid() then primaries=primaries+1; local wc=bank.WeaponClass; if wc and wc:isValid() then names[#names+1]=wc.Name; if wc:isBeam() then beams=beams+1 end end end end
            for b=1,sc do local bank=q[b]; if bank and bank:isValid() then secondaries=secondaries+1; local wc=bank.WeaponClass; if wc and wc:isValid() then names[#names+1]=wc.Name end end end
        end
    end
    self:Log(string.format("ARSENAL %s [%s]: turrets=%d primaryBanks=%d secondaryBanks=%d beamBanks=%d weapons={%s}",ship.Name,ship.Class.Name,turrets,primaries,secondaries,beams,table.concat(names,", ")))
end

function RTS:GetTierMultiplier(tier)
    local t = self.Config.CostFormula.TierMultipliers or {1.0,1.75,2.75,4.5}
    return t[tier or 1] or t[#t] or 1
end

-- allowModelLoad defaults to true. The death path passes false: a ship dying
-- is the worst possible moment to page a POF, and a pricing failure there must
-- not abort the rest of the $On Ship Death handler.
function RTS:GetPurchaseEstimate(className, tier, count, allowModelLoad)
    if allowModelLoad == nil then allowModelLoad = true end
    local base = self.ShipCostMap[className]
    if base == nil then
        local ok, est = pcall(function() return self:EstimateShipCost(tb.ShipClasses[className], allowModelLoad) end)
        base = ok and est or nil
        if base ~= nil then self.ShipCostMap[className] = base end
    end
    if base == nil then return nil end
    count = count or 1
    local mult = self:GetTierMultiplier(tier or 1)
    local cost = math.floor((base.cost * mult * count + 12.5) / 25) * 25
    local timeMult = count > 1 and (self.Config.Economy.WingBuildTimeMultiplier or 1.75) or 1
    return {cost=cost, time=base.time * mult * timeMult, count=count, radius=base.radius}
end

-- Capital placement is deliberately separated from the fighter grid: the strike
-- frame's clearance and its 6x-spacing retry fan both grow with hull radius, so
-- a juggernaut either lands far outside its own base or materialises inside an
-- enemy station's kill ring before it has been ordered.
function RTS:IsCapitalSpawnClass(className, radius)
    if radius >= ((self.Config.CostFormula or {}).HugeRadius or 1200) then return true end
    for _, option in ipairs(self.Config.ProductionClasses or {}) do
        if option.class == className then return option.role == "capital" or option.role == "heavy" or option.role == "juggernaut" end
    end
    for _, kind in ipairs({"RED","GOLD"}) do
        local e = self:GetAIRosterEntry(kind, className)
        if e ~= nil then return e.role == "capital" or e.role == "heavy" or e.role == "juggernaut" end
    end
    return false
end

-- Pull a spawn candidate back to MinEnemyBaseSeparation from the nearest hostile
-- command station, and hand back that station so the caller can try a fallback.
function RTS:SeparateFromHostileStation(pos, anchor, toward)
    local separation = self:GetEnemyBaseSeparation()
    local station, closest = nil, nil
    for _, key in ipairs(self:GetLivingFactionKeys()) do
        local other = self:GetFactionCommandShip(key)
        if shipValid(other) and other ~= anchor and self:IsCommandStation(other) and self:AreEnemies(anchor, other) then
            local d = pos:getDistance(other.Position)
            if closest == nil or d < closest then closest, station = d, other end
        end
    end
    if station == nil or closest >= separation then return pos, nil end
    local dx, dy, dz = pos.x - station.Position.x, pos.y - station.Position.y, pos.z - station.Position.z
    local len = math.sqrt(dx*dx + dy*dy + dz*dz)
    if len < 1 then dx, dy, dz, len = toward.x, toward.y, toward.z, 1 end
    return vec(station.Position.x + dx/len*separation, station.Position.y + dy/len*separation, station.Position.z + dz/len*separation), station
end

-- Fallback when the pulled-back spot is still blocked: the far intersection of
-- the anchor->centre line with a sphere of `distance` around the hostile station,
-- which by construction sits on our own side of the battlefield.
function RTS:FrontLineSpawn(anchor, toward, station, distance)
    local ax, ay, az = anchor.Position.x, anchor.Position.y, anchor.Position.z
    local ex, ey, ez = ax - station.Position.x, ay - station.Position.y, az - station.Position.z
    local b = 2 * (toward.x*ex + toward.y*ey + toward.z*ez)
    local c = ex*ex + ey*ey + ez*ez - distance*distance
    local disc = b*b - 4*c
    if disc >= 0 then
        local t = (-b + math.sqrt(disc)) / 2
        if t > 0 then return vec(ax + toward.x*t, ay + toward.y*t, az + toward.z*t) end
    end
    local e = math.sqrt(ex*ex + ey*ey + ez*ez)
    if e < 1 then e = 1 end
    return vec(station.Position.x + ex/e*distance, station.Position.y + ey/e*distance, station.Position.z + ez/e*distance)
end

-- Never spawn closer than this to any hostile station, clamped against how far
-- apart the two bases actually are. MinEnemyBaseSeparation is an absolute
-- number, but at the CLOSE base distance (12000) it exactly equals the base
-- separation, so EVERY candidate in the forward ring sat between the two bases,
-- tooClose() rejected all 16 retries, and the pull-back path then resolved to
-- the player's own station. Clamp to a fraction of the real separation.
function RTS:GetEnemyBaseSeparation()
    local cap=self.Config.CapitalSpawn or {}
    local want=cap.MinEnemyBaseSeparation or 12000
    if self.GetBaseDistanceProfile~=nil then
        local profile=self:GetBaseDistanceProfile()
        local baseDistance=profile and profile.distance or nil
        if type(baseDistance)=="number" and baseDistance>0 then
            return math.min(want,baseDistance*0.55)
        end
    end
    return want
end

function RTS:GetSpawnFrame(anchor, class, slot, total, batch)
    slot = slot or 1; total = total or 1
    local cap = self.Config.CapitalSpawn or {}
    local toCenter = vec(-anchor.Position.x, -anchor.Position.y * 0.15, -anchor.Position.z)
    local len = math.sqrt(toCenter.x*toCenter.x + toCenter.y*toCenter.y + toCenter.z*toCenter.z)
    if len < 1 then
        -- Station sitting at the world origin: "toward the centre" is undefined,
        -- and inheriting the model's nose vector made the entire spawn ring
        -- depend on which way the hull happened to be pointing. Use a fixed
        -- bearing so the geometry is deterministic.
        toCenter = vec(0, 0, -1); len = 1
    end
    local forward = vec(toCenter.x/len, toCenter.y/len, toCenter.z/len)
    -- Unrotated centre bearing, kept for the capital ring so a batch's golden
    -- angle shows up as lateral offset instead of swinging the arrival heading.
    local toBattle = copyVec(forward)
    if batch and batch > 0 then
        -- True golden-angle scatter, clamped to a forward-facing cone. The old
        -- expression applied 137.5 BEFORE the %140, which reduces to
        -- (-2.5*b) mod 140 - a slow linear ramp, not a scatter. Batch 1 landed
        -- at +67.5 deg, so the player's very first wing appeared off to the
        -- flank of its own base instead of in front of it.
        local deg=(batch*137.508)%360
        if deg>70 and deg<290 then deg = deg<180 and 70 or 290 end
        local angle = math.rad(deg)
        local ca, sa = math.cos(angle), math.sin(angle)
        forward = vec(forward.x*ca - forward.z*sa, forward.y, forward.x*sa + forward.z*ca)
    end
    local right = vec(forward.z, 0, -forward.x)
    local rlen = math.sqrt(right.x*right.x + right.z*right.z)
    if rlen < 0.01 then right = vec(1,0,0) else right = vec(right.x/rlen,0,right.z/rlen) end
    local anchorRadius = anchor.Class.Model and anchor.Class.Model.Radius or 500
    local shipRadius = class.Model and class.Model.Radius or 50
    local front = anchorRadius + shipRadius + (self.Config.Formation.SpawnForwardClearance or 1100)
    local spacing = math.max(self.Config.Formation.Spacing or 450, shipRadius * 2.4)
    local lateral = (slot - (total + 1) / 2) * spacing
    local row = math.floor((slot - 1) / 4)
    front = front + row * spacing * 1.4
    local function candidate(extraForward,extraSide)
        return vec(anchor.Position.x + forward.x*(front+extraForward) + right.x*(lateral+extraSide),
            anchor.Position.y + ((slot-1)%2)*80,
            anchor.Position.z + forward.z*(front+extraForward) + right.z*(lateral+extraSide))
    end
      -- Snapshot the blockers and the hostile station set ONCE for the whole fan.
    -- clear() used to walk the live ship list and re-read Position/Radius/Class
    -- on every one of up to 34 candidate tests per hull, and tooClose() re-derived
    -- the living-faction list each time (3 registry lookups plus two teamName
    -- calls per attempt). That is ~37,000 ADE property crossings for a single
    -- 4-ship wing. Nothing moves during one GetSpawnFrame, so both sets are
    -- fixed for its duration.
    local blockers={}
    for _,other in ipairs(self:GetShipList()) do
        if shipValid(other) and other:getSignature()~=anchor:getSignature() then
            local otherPosition=other.Position
            local otherClass=other.Class
            if otherPosition and otherClass then
                blockers[#blockers+1]={x=otherPosition.x,y=otherPosition.y,z=otherPosition.z,
                    r=other.Radius or (otherClass.Model and otherClass.Model.Radius) or 50}
            end
        end
    end
    local enemySeparation=self:GetEnemyBaseSeparation()
    local hostileStations={}
    for _, key in ipairs(self:GetLivingFactionKeys()) do
        local other = self:GetFactionCommandShip(key)
        if shipValid(other) and other ~= anchor and self:IsCommandStation(other) and self:AreEnemies(anchor, other) then
            local op=other.Position
            if op then hostileStations[#hostileStations+1]={x=op.x,y=op.y,z=op.z} end
        end
    end
    local function clear(pos)
        local px,py,pz=pos.x,pos.y,pos.z
        for i=1,#blockers do
            local b=blockers[i]
            local dx=px-b.x; local dy=py-b.y; local dz=pz-b.z
            if dx*dx+dy*dy+dz*dz < (shipRadius+b.r+250)*(shipRadius+b.r+250) then return false end
        end
        return true
    end
    local function tooClose(pos)
        local px,py,pz=pos.x,pos.y,pos.z
        for i=1,#hostileStations do
            local h=hostileStations[i]
            local dx=px-h.x; local dy=py-h.y; local dz=pz-h.z
            if dx*dx+dy*dy+dz*dz < enemySeparation*enemySeparation then return true end
        end
        return false
    end
    -- Both constraints belong inside the fan, not just on its result: a slot that
    -- is merely unoccupied can still sit inside an enemy base's kill ring, and a
    -- translated retry is what walks a huge hull across the map.
    local function usable(pos) return clear(pos) and not tooClose(pos) end
    local capital = self:IsCapitalSpawnClass(class.Name, shipRadius)
    local centre, reach, fan = nil, 0, 0
    if capital then
        -- The reach has to clear the ANCHOR as well as the incoming hull. It used
        -- to be derived from the ship's radius alone (0.35 * 2.4 * R = 0.84R), so
        -- a 700 m capital spawned ~590 m from the station centre - inside any
        -- station hull wider than that - and clear() cannot catch it because it
        -- deliberately skips the anchor. Telemetry confirmed it: a GTCv Deimos
        -- spawning 266 m from its own station's centre.
        reach = math.min(cap.MaxStationRadius or 9000,
            anchorRadius + shipRadius + (self.Config.Formation.SpawnForwardClearance or 1100)
            + (cap.ForwardBias or 0.35) * shipRadius * (cap.MaxStationRadiusFactor or 2.4))
        fan = math.min(cap.MaxStationRadius or 9000, reach * 0.35 + shipRadius * 3)
        centre = vec(anchor.Position.x + toBattle.x*reach, anchor.Position.y + toBattle.y*reach, anchor.Position.z + toBattle.z*reach)
    end
    -- offset carries the enemy-base pull-back, so the retry fan searches around
    -- the separated ring rather than the ring the pull-back already rejected.
    local offset = vec(0, 0, 0)
    local function place(attempt)
        local p
        if capital then
            if attempt == 0 then
                local l = math.cos(math.rad((batch or 1) * 137.5)) * reach * 0.35
                p = vec(centre.x + right.x*l, centre.y, centre.z + right.z*l)
            else
                local a = math.rad((batch or 1) * 137.5 + attempt * 137.5)
                local f = fan * math.min(attempt / 6, 1)
                local sf, cf = f*math.sin(a), f*math.cos(a)
                p = vec(centre.x + toBattle.x*sf + right.x*cf, centre.y + toBattle.y*sf,
                    centre.z + toBattle.z*sf + right.z*cf)
            end
        elseif attempt == 0 then
            p = candidate(0,0)
        else
            -- Straddle the anchor on alternating attempts. The old fan only ever
            -- added a POSITIVE forward offset, so it could resolve "too close to
            -- my own station" - where stepping back is the only fix - never. All
            -- 16 attempts then failed, which is what made a congested ring cost
            -- the full ~34 scans per hull and still produce nothing.
            local angle=math.rad(((batch or 1)*137.5+attempt*111)%360)
            local step=spacing*(1+math.floor((attempt-1)/4))
            if attempt%2==0 then step=-step end
            p=candidate(step,math.cos(angle)*math.abs(step)*1.5)
        end
        return vec(p.x+offset.x, p.y+offset.y, p.z+offset.z)
    end
    local base = place(0)
    local pos, ok = base, usable(base)
    if not ok then
        for attempt=1,16 do
            pos=place(attempt); ok=usable(pos)
            if ok then break end
        end
    end
    local pulled, station = self:SeparateFromHostileStation(pos, anchor, toBattle)
    if station ~= nil then
        if clear(pulled) then
            pos, ok = pulled, true
        else
            offset = vec(pulled.x-base.x, pulled.y-base.y, pulled.z-base.z)
            for attempt=1,16 do
                pos=place(attempt)
                if usable(pos) then ok=true; break end
            end
            offset = vec(0, 0, 0)
            -- Fall back to a point on the anchor-to-centre line at the full
            -- separation, not 0.75 of it. Sitting inside the separation is the
            -- exact failure this whole path exists to prevent, and headless
            -- telemetry caught a Colossus materialising 9,000 m from an enemy
            -- base: 0.75 * 12,000 is exactly 9,000.
            if not ok then
                pos = self:FrontLineSpawn(anchor, toBattle, station, self:GetEnemyBaseSeparation() * 1.05)
                ok = not tooClose(pos)
            end
        end
    end
    if not ok then
        -- Nothing in the fan satisfied clear() AND tooClose(). This is the case
        -- that used to leave NO trace: the frame quietly handed back an
        -- unvalidated position and the hull either appeared somewhere
        -- unexpected or not at all. Say so, with the geometry that failed.
        self:Log(string.format("SPAWN SLOT REJECTED: %s at %s, batch %s after full retry fan (no clear slot in the forward ring)",
            tostring(class.Name), tostring(anchor.Name), tostring(batch)))
    end
    if not ok then
        local safe = self:ClampCommandPoint(pos, 0)
        if safe ~= nil then pos = safe end
    end
    if capital then
        -- A capital that no usable slot could take must still land inside its own
        -- base's ring, or the retry fan walks it most of the way to the enemy.
        -- Use the SAME reach as the placement above: this clamp used the old
        -- ship-only formula (0.84 * R), so it would have dragged a correctly
        -- placed capital back inside its own station hull.
        local reachLimit=math.min(cap.MaxStationRadius or 9000,
            anchorRadius + shipRadius + (self.Config.Formation.SpawnForwardClearance or 1100)
            + (cap.ForwardBias or 0.35) * shipRadius * (cap.MaxStationRadiusFactor or 2.4))
        local away=vec(pos.x-anchor.Position.x,0,pos.z-anchor.Position.z)
        local distance=math.sqrt(away.x*away.x+away.z*away.z)
        if distance>reachLimit and distance>0.01 then
            local k=reachLimit/distance
            pos=vec(anchor.Position.x+away.x*k,pos.y,anchor.Position.z+away.z*k)
        end
    end
    -- Last gate before the vector reaches mn.createShip. Every branch above can
    -- leave `pos` untouched (ClampCommandPoint returns nil for a non-finite
    -- input, and the capital clamp divides by `distance`), and a NaN position
    -- makes ship_create build a hull the player can never see or select, with no
    -- error anywhere. Fall back to a plain ring slot on the anchor's own side.
    if not self:IsFiniteVector(pos) then
        self:Log("Spawn frame resolved to a non-finite position for "..tostring(class.Name).."; using anchor ring")
        local ax,az=anchor.Position.x,anchor.Position.z
        local angle=math.rad(((batch or 1)*137.5)%360)
        local ring=anchorRadius+shipRadius+(self.Config.Formation.SpawnForwardClearance or 1100)
        pos=vec(ax+math.cos(angle)*ring,anchor.Position.y,az+math.sin(angle)*ring)
    end
    -- Guaranteed-clearance pass. clear() deliberately skips the anchor, and the
    -- enemy pull-back path can end on FrontLineSpawn, which never re-checks
    -- clearance - so a hull could still be handed to mn.createPoint on top of
    -- an existing ship, or inside the anchor's own hull. Sweep a ring and take
    -- the first point that clears BOTH every blocker and the anchor. Pure
    -- arithmetic against the snapshot taken above, so this is cheap.
    if capital or not clear(pos) or (function(p)
            local dx=p.x-anchor.Position.x; local dy=p.y-anchor.Position.y; local dz=p.z-anchor.Position.z
            return math.sqrt(dx*dx+dy*dy+dz*dz)
        end)(pos) < anchorRadius+shipRadius+250 then
        local ax,ay,az2=anchor.Position.x,anchor.Position.y,anchor.Position.z
        local minOwn=anchorRadius+shipRadius+250
        -- Own-hull clearance, done with plain arithmetic rather than
        -- getMagnitude() so the headless test harness (whose vector double does
        -- not implement it) can exercise this path.
        local function clearsOwn(p)
            local dx=p.x-ax; local dy=p.y-ay; local dz=p.z-az2
            return math.sqrt(dx*dx+dy*dy+dz*dz)>=minOwn
        end
        local bestClear=nil; local bestOwn=-1
        for step=0,23 do
            local a2=math.rad(step*15)
            for _,mult in ipairs({1,1.6,2.3,3.2}) do
                local rad2=front*mult
                local cand=vec(ax+math.cos(a2)*rad2,ay,az2+math.sin(a2)*rad2)
                if clearsOwn(cand) and clear(cand) and not tooClose(cand) then
                    bestClear=cand; bestOwn=1; break
                end
            end
            if bestOwn==1 then break end
        end
        if bestClear~=nil then
            pos=bestClear
        else
            -- Nothing on the ring is clear (a genuinely congested base). Take
            -- the anchor-relative point furthest from the nearest blocker rather
            -- than knowingly landing inside a hull.
            local worst=nil; local worstGap=-1
            for step=0,23 do
                local a2=math.rad(step*15)
                local cand=vec(ax+math.cos(a2)*front*1.6,ay,az2+math.sin(a2)*front*1.6)
                local nearest=math.huge
                for i=1,#blockers do
                    local b=blockers[i]
                    local dx=cand.x-b.x; local dy=cand.y-b.y; local dz=cand.z-b.z
                    local d=math.sqrt(dx*dx+dy*dy+dz*dz)-b.r-shipRadius
                    if d<nearest then nearest=d end
                end
                if #blockers==0 then nearest=1e9 end
                if nearest>worstGap then worstGap=nearest; worst=cand end
            end
            if worst~=nil then
                pos=worst
                self:Log("SPAWN CONGESTED: no clear slot for "..tostring(class.Name).." at "..tostring(anchor.Name).."; placed at best available point")
            end
        end
    end
    return pos, forward:getOrientation()
end

function RTS:RegisterLogicalWing(ships, label)
    if ships == nil or #ships == 0 then return nil end
    self.WingSerial = (self.WingSerial or 0) + 1
    local id = "W"..tostring(self.WingSerial)
    local wing = {id=id, label=label or id, signatures={}}
    self.RTSWings[id] = wing
    for _,ship in ipairs(ships) do
        if shipValid(ship) then
            local sig=ship:getSignature(); wing.signatures[#wing.signatures+1]=sig; self.WingBySignature[sig]=id
        end
    end
    return wing
end

function RTS:GetLogicalWing(ship)
    if not shipValid(ship) then return nil end
    local id=self.WingBySignature[ship:getSignature()]
    return id and self.RTSWings[id] or nil
end

function RTS:SelectLogicalWing(ship, additive)
    local wing=self:GetLogicalWing(ship)
    if wing == nil then return false end
    local result=additive and self.Selected or {}
    for _,sig in ipairs(wing.signatures) do
        if self:FindShipBySignature(sig) ~= nil and not tableContainsSignature(result,sig) then result[#result+1]=sig end
    end
    self.Selected=result
    return true
end

-- allowZero is set only by the mod's own pause, which is the single caller
-- allowed to stop the engine clock. It has to bypass the mission-pause guard
-- below as well, otherwise the guard re-raises 0 to LastNonZeroTimeScale and
-- the pause silently does nothing.
function RTS:SetTimeScale(scale, allowZero)
    scale = tonumber(scale) or 1
    if scale < 0 then scale = 0 end
    if scale > 16 then scale = 16 end
    if scale <= 0 and not allowZero then scale = self.LastNonZeroTimeScale or 1 end
    self.TimeScale = scale
    if scale > 0 then self.LastNonZeroTimeScale = scale end
    local percent = math.floor(scale * 100 + 0.5)
    mn.runSEXP("(set-time-compression "..tostring(percent).." 0)")
end

-- Same steps as the top-bar speed buttons. From pause, steps from the last speed.
local TIME_SCALE_STEPS = {0.5, 1, 2, 4, 8, 16}

function RTS:StepTimeScale(delta)
    local current = (self.TimeScale or 1) > 0 and self.TimeScale or (self.LastNonZeroTimeScale or 1)
    local index = 1
    for i, step in ipairs(TIME_SCALE_STEPS) do if step <= current then index = i end end
    index = clamp(index + delta, 1, #TIME_SCALE_STEPS)
    self:SetTimeScale(TIME_SCALE_STEPS[index], self.Paused == true)
    self:SetStatus("Game speed: " .. TIME_SCALE_STEPS[index] .. "x", 1.2)
end

-- The mod owns its own pause: it stops the engine clock and gates every sim
-- update in OnFrame. Esc toggles it while the RTS session owns the screen, and
-- falls through to the native pause menu while paused so the player can still
-- reach Options / Controls / Restart / Abort.
function RTS:SetPaused(paused)
    paused = paused == true
    if self.Paused == paused then return end
    self.Paused = paused
    if paused then
        self.PausedTimeScale = self.TimeScale
        self:SetTimeScale(0, true)
    else
        self:SetTimeScale(self.PausedTimeScale or self.LastNonZeroTimeScale or 1, true)
        self.PausedTimeScale = nil
    end
    self:SetStatus(paused and "PAUSED // Esc resumes, or opens the native menu" or "RESUMED", 2)
end

function RTS:TogglePause()
    self:SetPaused(not self.Paused)
end

function RTS:DisableFactionShips(kind)
    -- ship:vanish() instead of building a (ship-vanish "name") SEXP: names are
    -- not escaped there, so a quote in a ship name broke the call.
    local ships={}
    self:EachShip(function(ship) if self:GetFactionKey(ship)==kind then ships[#ships+1]=ship end end)
    for _,ship in ipairs(ships) do if shipValid(ship) then ship:vanish() end end
end

function RTS:ApplyFactionVisuals()
    local red=self:GetEnemyCommand()
    if shipValid(red) then
        pcall(function()
            local tc=tb.TeamColors["RTS Shivan Red"]
            if tc and tc:isValid() then red.TeamColor=tc end
        end)
    end
end

function RTS:IsRTSMission()
    local filename = lower(mn.getMissionFilename())
    return self.Config.MissionNames[filename] == true
end

function RTS:IsFriendly(ship)
    return shipValid(ship)
        and ship.Name ~= self.Config.ObserverShip
        and teamName(ship) == self.Config.FriendlyTeam
end

function RTS:IsHostile(ship)
    return shipValid(ship) and teamName(ship) == self.Config.HostileTeam
end


function RTS:IsThirdFaction(ship)
    return shipValid(ship) and teamName(ship) == self.Config.ThirdTeam
end

function RTS:IsPlayerEnemy(ship)
    return self:IsHostile(ship) or self:IsThirdFaction(ship)
end

function RTS:IsSelectableShip(ship)
    return shipValid(ship) and ship.Name ~= self.Config.ObserverShip
end
-- One ship list per frame instead of re-walking mn.Ships (a fresh handle per
-- ship per call) 6-8 times per HUD frame. OnFrame drops it each frame and
-- InvalidateShipList() drops it after every createShip; dead ships are
-- filtered by the isValid check on iteration.
function RTS:GetShipList()
    local list = self.ShipCache
    if list == nil then
        list = {}
        for i = 1, #mn.Ships do
            local ship = mn.Ships[i]
            if shipValid(ship) then list[#list + 1] = ship end
        end
        self.ShipCache = list
    end
    return list
end

function RTS:InvalidateShipList()
    self.ShipCache = nil
end

function RTS:EachShip(callback)
    for _, ship in ipairs(self:GetShipList()) do
        if ship:isValid() then callback(ship) end
    end
end

function RTS:FindShipBySignature(signature)
    if signature == nil then return nil end
    -- Engine lookup by signature; the old path scanned every ship.
    local object = mn.getObjectFromSignature(signature)
    if object ~= nil and object:isValid() and object:getBreedName() == "Ship" then return object end
    return nil
end

function RTS:GetObserver()
    local ship = mn.Ships[self.Config.ObserverShip]
    if shipValid(ship) then return ship end
    return nil
end

function RTS:GetCarrier()
    local ship = mn.Ships[self.Config.CarrierShip]
    if shipValid(ship) then return ship end
    return nil
end

function RTS:GetEnemyCommand()
    local ship = mn.Ships[self.Config.EnemyCommandShip]
    if shipValid(ship) then return ship end
    return nil
end


function RTS:GetThirdCommand()
    local ship = mn.Ships[self.Config.ThirdCommandShip]
    if shipValid(ship) then return ship end
    return nil
end
function RTS:GetSelectedShips()
    local result = {}
    local cleaned = {}
    for _, signature in ipairs(self.Selected) do
        local ship = self:FindShipBySignature(signature)
        if self:IsSelectableShip(ship) then
            result[#result + 1] = ship
            cleaned[#cleaned + 1] = signature
        end
    end
    self.Selected = cleaned
    return result
end


function RTS:GetSelectedFriendlyShips()
    local result={}; local seen={}
    for _,ship in ipairs(self:GetSelectedShips()) do
        if self:IsFriendly(ship) then
            local sig=ship:getSignature()
            if not seen[sig] then result[#result+1]=ship; seen[sig]=true end
        end
    end
    return result
end

function RTS:GetPrimarySelectedShip()
    local ships = self:GetSelectedShips()
    if #ships > 0 then return ships[1] end
    return nil
end
function RTS:CountFriendlyCombatants()
    local count = 0
    self:EachShip(function(ship)
        if self:IsMovableFriendly(ship) then
            count = count + 1
        end
    end)
    return count
end

function RTS:CountHostiles()
    local count = 0
    self:EachShip(function(ship)
        if self:IsPlayerEnemy(ship) then count = count + 1 end
    end)
    return count
end

function RTS:ResetState()
    self:ResetStationState()
    self:CloseAITrace()
    self:ResetCoordinatedAI()
    self.Selected = {}; self.ControlGroups = {}; self.MoveWaypoints = {}; self.BuildQueue = {}
    self.BuildSerial=0; self.EnemySerial=0; self.GoldSerial=0; self.WaveIndex=1; self.GoldWaveIndex=1
    self.CommandPoints=self.Config.Economy.StartingCommandPoints; self.ActiveIncomePerSecond=self.Config.Economy.PassiveIncomePerSecond; self.LastIncomeTime=0
    self.GameStatus="SETUP"; self.StatusMessage="Configure escalation battle, then START."; self.StatusUntil=math.huge
    self.KeyDown={}; self.FastKeyDown={}; self.CtrlDown=false; self.ShiftDown=false; self.AltDown=false
    self.LeftDrag=nil; self.RightDrag=nil; self.MiddleDrag=nil; self.MapDrag=nil; self.FollowOrbitDrag=nil; self.MovePreview=nil
    self.BuildButtonRects={}; self.BuildNavRects={}; self.ActionButtonRects={}; self.PolicyButtonRects={}; self.SetupButtonRects={}; self.TimeButtonRects={}; self.PostBattleButtonRects={}
    self.CommandMarker=nil; self.CommandMarkerUntil=0; self.FollowSignature=nil; self.FollowZoom=1.0; self.FollowYawOffset=0; self.FollowPitchOffset=0.22
    self.LastLeftClickTime=-100; self.LastLeftClickX=0; self.LastLeftClickY=0; self.LastLeftClickKey=nil
    self.PossessedSignature=nil; self.PilotCamera=nil; self.PilotCameraSerial=0; self.PilotButtons={0,0,0,0}; self.PilotPreviousUserOrder=nil
    -- PilotTurretGroups holds l_Subsystem userdata and PilotNativeWing holds an
    -- l_Wing; both belong to the mission that created them. RestorePilotTurretGroups
    -- and LeavePilotNativeWing are only reachable through ExitPilotMode, which
    -- needs PossessedSignature, and the line above has just cleared it -- so a
    -- restart entered from Shutdown's early-return (Enabled already false, or the
    -- observer already deleted) would carry engine objects from the old mission
    -- into the new one. Clear the same field set the two restore functions clear.
    self.PilotTurretGroups=nil; self.PilotTurretGroupIndex=nil; self.PilotTurretLastGroupIndex=nil; self.PilotTurretAppliedGroupIndex=nil
    self.PilotTurretFiring=false; self.PilotTurretFireLatched=false; self.PilotTurretFireStatusAt=nil
    self.PilotTargetSubsystemIndex=1; self.PilotTargetSubsystemCount=0; self.PilotNativeWing=nil; self.PilotNativeWingLabel=nil
    self.ObserverHomePosition=nil; self.ObserverHomeOrientation=nil; self.ObserverOriginalClassName=nil
    self.UserOrders={}; self.PolicyApplied={}; self.PolicyDefend={}; self.EngageTargets={}; self.GlobalPolicy=self.Config.Policy.Default or "STANDOFF"; self.LastPolicyRefresh=-100
    self.SetupActive=true; self.SetupDifficultyIndex=self.Config.Setup.DefaultDifficulty or 2
    self.SetupOpponents={RED=true,GOLD=false}; self:UpdateFactionCount()
    self.SetupEconomyIndex=self.Config.Setup.DefaultEconomy or 2; self.SetupDurationIndex=self.Config.Setup.DefaultDuration or 1
    self.SetupAutoMode=self.Config.Setup.DefaultAutoMode == true; self.SetupAsteroids=self.Config.Setup.DefaultAsteroids==true; self.SetupSentries=self.Config.Setup.DefaultSentries==true; self.AutoPlayerMode=false
    self.SetupBaseDistanceIndex=self.Config.Setup.DefaultBaseDistance or 2; self.ScenarioBasePositions={}
    self.ScenarioStartTime=nil; self.RedEliminated=false; self.GoldEliminated=true; self.BlueEliminated=false; self.BattleVictor=nil
    self.PostBattleActive=false; self.PostBattleResult=nil
    self.PreviousButtonControlMode=nil; self.BuildPage=1; self.BuildRowsPerPage=5; self.ShipCostMap={}; self.BuildCatalog={}
    self.CinematicActive=false; self.CinematicElapsed=0; self.CinematicShotIndex=1; self.CinematicCaption=nil; self.CinematicSubcaption=nil; self.CinematicFaction=nil; self.CinematicCaptionAlpha=0
    self.AnnouncementText=nil; self.AnnouncementFaction=nil; self.AnnouncementUntil=-1
    self.AIStates={}; self.AIOrderState={}; self.AIPlanTelemetry={}; self.AIOrderTelemetry={attempts=0,success=0,failed=0,rejected=0,unchanged=0,byMission={},byResult={}}; self.CombatTelemetryEnabled=false; self.LastAIThink=-100; self.LastAIStrategicUpdate=-100; self.AIStrategicPlanQueue=nil; self.StationBaseHull={}; self.StaticDefenseSignatures={}; self.DyingStations={}; self.TacticalMapIconCache={}; self.LastEscalationTier=1; self.LastWorldBoundsAudit=-100; self.WorldBoundsWarnings={}
    -- Mission-scoped economy ledgers. AIEconomyFlow is the per-sample INTERVAL
    -- that FACTION publishes and zeroes; AIEconomyFlowCumulative is the running
    -- total behind it. Without the running total the spend that happens after
    -- the last FACTION record of a match is never published by anyone, because
    -- the interval it belonged to is zeroed before it is ever reported - so the
    -- event stream and the flow disagree by that trailing interval on every run.
    self.AIEconomyFlow=nil; self.AIEconomyFlowCumulative=nil
    self.RTSWings={}; self.WingBySignature={}; self.WingSerial=0; self.WingNameCounters={BLUE=0,RED=0,GOLD=0}
    self.PrimarySelectionSignature=nil; self.SelectionRows={}; self.SelectionRowsShown=0; self.HoveredSelectionRow=nil; self.HoveredSelectionSigs={}; self.ArmedCommand=nil; self.QuickGroupRects={}; self.AutoModeRect=nil
    self.PendingPilotEject=false; self.PendingPilotEjectRemaining=nil; self.PendingPilotEjectPosition=nil; self.PendingPilotEjectOrientation=nil; self.PendingPilotEjectRadius=nil; self.PilotDeathRestoreTimeScale=nil; self.PilotDeathRestoreLastNonZeroTimeScale=nil; self.FactionPrimaryTargets={}; self.StationBeamHits={}; self.StationBeamHitSeen={}; self.NextStationBeamCleanup=0
    -- Learned beam reach is mission-scoped evidence. Carrying it across a
    -- restart is the DyingStations defect class: a stale signature resolving to
    -- an unrelated hull would arrive with a reach it never earned.
    self.BeamRangeByClass=nil
    self.RosterModelWarmup=nil
    self.TimeScale=1; self.LastNonZeroTimeScale=1; self.Paused=false; self.PausedTimeScale=nil
    self.UIClock=0; self.RoleByClass={}; self.RosterIndex=nil; self.ShipCache=nil; self.FreeMoveWaypoints={}; self.ButtonControlMode=nil
end
