-- Spawn frame computation (GetSpawnFrame).
local _shared = require "fs2rts_factions.common"
local RTS, copyVec, shipValid, vec = _shared.RTS, _shared.copyVec, _shared.shipValid, _shared.vec

function RTS:GetSpawnFrame(anchor, class, slot, total, batch, preferred)
    slot = slot or 1; total = total or 1
    local cap = self.Config.CapitalSpawn or {}
    local facing=vec(0,0,0)
    if self:IsCommandStation(anchor) then facing=self:GetFactionBattleFacingPoint(self:GetFactionKey(anchor)) end
    local toCenter = vec(facing.x-anchor.Position.x, -anchor.Position.y * 0.15, facing.z-anchor.Position.z)
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
    local function usable(pos)
        local bounded=self:ClampCommandPoint(pos,0)
        return bounded~=nil and bounded:getDistance(pos)<=.01 and clear(pos) and not tooClose(pos)
    end
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
    -- Keep a visible jump signature as the arrival slot, unless the live
    -- arena or a new blocker makes it unsafe.
    if preferred and self:IsFiniteVector(preferred) then
        local away=preferred:getDistance(anchor.Position)
        if usable(preferred) and away>=anchorRadius+shipRadius+250 and (not capital or away<=reach) then base=copyVec(preferred) end
    end
    local pos, ok = base, usable(base)
    if not ok then
        for attempt=1,16 do
            pos=place(attempt); ok=usable(pos)
            if ok then break end
        end
    end
    local pulled, station = self:SeparateFromHostileStation(pos, anchor, toBattle)
    if station ~= nil then
        if usable(pulled) then
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
                ok = usable(pos)
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
    if capital or not usable(pos) or (function(p)
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
        -- Nearest ring first, and within a ring start from the battle-facing bearing.
        -- The old search was angle-first, so a far ring on bearing 0 beat a legal
        -- slot close by on another bearing: a capital landed 8.6 km behind its own
        -- station, outside its reach. A capital's rings also stop at its reach limit.
        local facing=math.atan2(toBattle.z,toBattle.x)
        local rings={front,front*1.6,front*2.3,front*3.2}
        if capital then rings={front,math.min(front*1.6,reach),reach} end
        local bestClear=nil
        for _,rad2 in ipairs(rings) do
            for step=0,23 do
                local a2=facing+math.rad(step*15)
                local cand=vec(ax+math.cos(a2)*rad2,ay,az2+math.sin(a2)*rad2)
                if clearsOwn(cand) and usable(cand) then
                    bestClear=cand; break
                end
            end
            if bestClear~=nil then break end
        end
        if bestClear~=nil then
            pos=bestClear
        else
            self:Log('SPAWN CONGESTED: no legal slot for '..tostring(class.Name))
            return nil,nil
        end
    end
    local own=anchor.Position
    local dx,dy,dz=pos.x-own.x,pos.y-own.y,pos.z-own.z
    local bounded=self:ClampCommandPoint(pos,0)
    if not self:IsFiniteVector(pos) or not usable(pos)
        or dx*dx+dy*dy+dz*dz<(anchorRadius+shipRadius+250)^2
        or bounded==nil or bounded:getDistance(pos)>.01 then
        self:Log('SPAWN REJECTED: no legal slot for '..tostring(class.Name))
        return nil,nil
    end
    return pos, forward:getOrientation()
end
