-- Tactical camera, intro cinematic, follow camera.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:SetupCamera()
    self.IntroFadeInUntil=nil
    local c = self.Config.Camera
    self.CameraFocus = vec(c.Focus.x, c.Focus.y, c.Focus.z)
    self.CameraDistance = c.Distance
    self.CameraPitch = math.rad(c.PitchDegrees)
    self.CameraYaw = math.rad(c.YawDegrees)
    self.Camera = gr.createCamera("FS2RTS Tactical Camera", self.CameraFocus)
    self.Camera.FOV = c.FOV
    self.FollowCamera = gr.createCamera("FS2RTS Follow Camera", self.CameraFocus)
    self.FollowCamera.FOV = c.FollowFOV or c.FOV
    self:UpdateCameraTransform()
    gr.setCamera(self.Camera)
end

function RTS:ClampCameraFocus()
    if self.CameraFocus==nil then return end
    local half=self:GetTacticalMapHalfExtent()*(self.Config.Camera.FocusBoundsMultiplier or 1.20)
    self.CameraFocus.x=clamp(self.CameraFocus.x,-half,half)
    self.CameraFocus.z=clamp(self.CameraFocus.z,-half,half)
    self.CameraFocus.y=clamp(self.CameraFocus.y,-half*0.45,half*0.45)
end

function RTS:UpdateCameraTransform()
    if self.Camera == nil then return end
    self:ClampCameraFocus()

    local horizontal = self.CameraDistance * math.cos(self.CameraPitch)
    local height = self.CameraDistance * math.sin(self.CameraPitch)
    local sinYaw = math.sin(self.CameraYaw)
    local cosYaw = math.cos(self.CameraYaw)

    local position = vec(
        self.CameraFocus.x - sinYaw * horizontal,
        self.CameraFocus.y + height,
        self.CameraFocus.z - cosYaw * horizontal
    )
    local direction = vec(
        self.CameraFocus.x - position.x,
        self.CameraFocus.y - position.y,
        self.CameraFocus.z - position.z
    )

    self.Camera.Position = position
    self.Camera.Orientation = direction:getOrientation()
end

function RTS:GetCinematicShotDuration(shot)
    return math.max(0.1, (shot and shot.duration) or 6)
end

-- Absolute start time of a shot in the cinematic timeline. Switching shots
-- re-anchors CinematicElapsed to this so the chosen shot plays from t=0.
function RTS:GetCinematicShotStart(index)
    local shots = (self.Config.Cinematic or {}).Shots or {}
    local cursor = 0
    for i = 1, (index - 1) do
        local shot = shots[i]
        if shot == nil then return cursor end
        cursor = cursor + self:GetCinematicShotDuration(shot) + math.max(0, shot.hold or 0)
    end
    return cursor
end

function RTS:GetCinematicTotalDuration()
    local shots = (self.Config.Cinematic or {}).Shots or {}
    local total = 0
    for _, shot in ipairs(shots) do total = total + self:GetCinematicShotDuration(shot) + math.max(0, shot.hold or 0) end
    return total
end

-- delta != 0 steps the shot selection with wraparound, so the player can cut
-- between establishing angles instead of only skipping the whole intro.
function RTS:CinematicNextShot(delta, restart)
    if not self.CinematicActive then return false end
    local shots = (self.Config.Cinematic or {}).Shots
    if shots == nil or #shots == 0 then return false end
    local count = #shots
    local index = self.CinematicShotIndex or 1
    if not restart then index = ((index - 1 + (tonumber(delta) or 1)) % count) + 1 end
    self.CinematicShotIndex = index
    self.CinematicElapsed = self:GetCinematicShotStart(index)
    self.CinematicTailHold = nil
    self.IntroFadeInUntil=nil
    self:SetStatus(string.format("CINEMATIC SHOT %d/%d", index, count), 1.2)
    return true
end

function RTS:CinematicRestartShot()
    return self:CinematicNextShot(0, true)
end

-- Vanishes a group of ships together with the weapons they fired. Shared by the
-- intro tableau and the setup backdrop.
function RTS:VanishShipGroup(group)
    local signatures={}
    for _,ship in ipairs(group or {}) do
        if shipValid(ship) then signatures[ship:getSignature()]=true end
    end
    local weapons={}
    for i=1,#(mn.Weapons or {}) do
        local weapon=mn.Weapons[i]
        if objectValid(weapon) and shipValid(weapon.Parent) and signatures[weapon.Parent:getSignature()] then weapons[#weapons+1]=weapon end
    end
    for _,weapon in ipairs(weapons) do weapon:vanish() end
    for _,ship in ipairs(group or {}) do
        if shipValid(ship) then
            self:ReleaseMoveWaypoint(ship:getSignature())
            ship:vanish()
        end
    end
end

function RTS:ClearIntroScene()
    self:VanishShipGroup(self.IntroShips)
    self.IntroShips=nil
    self.IntroRetreatStarted=nil
    self:InvalidateShipList()
end

function RTS:CreateIntroScene()
    self:ClearIntroScene()
    self.IntroShips={}
    -- A separate, invulnerable tableau keeps the briefing fight out of the
    -- real stations, economy, losses and commissioned fleet histories.
    local cast={
        {'GTC Fenris',-900,0,0,mn.Teams.friendly},
        {'SC Lilith',900,0,0,mn.Teams.hostile},
        {'GTF Hercules',-450,150,-450,mn.Teams.friendly},
        {'SF Mara',450,150,450,mn.Teams.hostile},
        {'GTB Medusa',-1100,-180,300,mn.Teams.friendly},
        {'SB Nephilim',1100,-180,-300,mn.Teams.hostile},
    }
    for i,item in ipairs(cast) do
        local ship=mn.createShip('RTS Intro '..i,tb.ShipClasses[item[1]],nil,
            vec(item[2],45000+item[3],item[4]),item[5],true)
        if not shipAlive(ship) then self:ClearIntroScene(); assert(false,'Intro ship creation failed: '..item[1]) end
        self.IntroShips[i]=ship
        ship:setFlag(true,'invulnerable','no-shields')
        ship.Orientation=vec(i%2==1 and 1 or -1,0,0):getOrientation()
        self:EnableFullArsenal(ship)
        ship:clearOrders()
    end
    for i,ship in ipairs(self.IntroShips) do
        local target=self.IntroShips[i%2==1 and 2 or 1]
        ship.Target=target
        if ship:giveOrder(ORDER_ATTACK,target,nil,.95)~=true then
            self:ClearIntroScene()
            assert(false,'Intro attack order refused')
        end
    end
    self:InvalidateShipList()
end

-- Random skirmish shown behind the escalation setup panel. It is a separate,
-- invulnerable group on the map: START vanishes it before the real bases and
-- fleets spawn, so none of it counts as a faction, base or loss.
local SETUP_BACKDROP_PAIRS=3
local SETUP_BACKDROP_CLASSES={
    friendly={'GTC Fenris','GTF Hercules','GTB Medusa'},
    hostile={'SC Lilith','SF Mara','SB Nephilim'},
}

-- A private generator: the global math.random stream drives the seeded headless
-- runs, and the backdrop must not shift their draws.
local function backdropRandom(seed)
    local state=seed%2147483647
    if state<=0 then state=1 end
    return function(lo,hi)
        state=(state*48271)%2147483647
        return lo+(state/2147483647)*(hi-lo)
    end
end

function RTS:CreateSetupBackdrop()
    self:ClearSetupBackdrop()
    self.SetupBackdropSeed=((self.SetupBackdropSeed or 0)+os.time()*1000+math.floor(os.clock()*1000))%2147483647
    local rand=backdropRandom(self.SetupBackdropSeed)
    local half=self:GetTacticalMapHalfExtent()*0.5
    local ships={}
    for pair=1,SETUP_BACKDROP_PAIRS do
        local angle=rand(0,2*math.pi)
        local radius=rand(0.2,0.8)*half
        local cx,cz=math.cos(angle)*radius,math.sin(angle)*radius
        local dir=rand(0,2*math.pi)
        local ox,oz=math.cos(dir)*500,math.sin(dir)*500
        local sides={
            {kind='friendly',team=mn.Teams.friendly,x=cx-ox,z=cz-oz},
            {kind='hostile',team=mn.Teams.hostile,x=cx+ox,z=cz+oz},
        }
        for side,item in ipairs(sides) do
            local pool=SETUP_BACKDROP_CLASSES[item.kind]
            local className=pool[math.floor(rand(1,#pool+1))]
            local ship=mn.createShip('RTS Setup '..pair..'-'..side,tb.ShipClasses[className],nil,
                vec(item.x,0,item.z),item.team,true)
            if not shipAlive(ship) then self:VanishShipGroup(ships); assert(false,'Setup backdrop ship creation failed: '..className) end
            ships[#ships+1]=ship
            ship:setFlag(true,'invulnerable','no-shields')
            self:EnableFullArsenal(ship)
            ship:clearOrders()
        end
    end
    -- Ships are created in opposing pairs, so each pair is (ships[i], ships[i+1]).
    for i=1,#ships,2 do
        local a,b=ships[i],ships[i+1]
        a.Orientation=(b.Position-a.Position):getOrientation()
        b.Orientation=(a.Position-b.Position):getOrientation()
        a.Target=b; b.Target=a
        if a:giveOrder(ORDER_ATTACK,b,nil,.95)~=true or b:giveOrder(ORDER_ATTACK,a,nil,.95)~=true then
            self:VanishShipGroup(ships)
            assert(false,'Setup backdrop attack order refused')
        end
    end
    self.SetupBackdropShips=ships
    self:InvalidateShipList()
end

function RTS:ClearSetupBackdrop()
    self:VanishShipGroup(self.SetupBackdropShips)
    self.SetupBackdropShips=nil
    self:InvalidateShipList()
end

function RTS:StartIntroCinematic()
    local cfg = self.Config.Cinematic
    if cfg == nil or cfg.Enabled == false or cfg.Shots == nil or #cfg.Shots == 0 then
        self.CinematicActive = false
        return
    end

    self:CreateIntroScene()
    self.CinematicActive = true
    self.CinematicElapsed = 0
    self.CinematicShotIndex = 1
    self.CinematicTailHold = nil
    self.CinematicCaption = nil
    self.CinematicSubcaption = nil
    self.CinematicFaction = nil
    self.CinematicCaptionAlpha = 0
    self:SetRTSInputMode()
    self:DisarmObserverWeapons()
    io.setCursorHidden(true)
    gr.setCamera(self.Camera)
    self:Log("Mission intro cinematic started")
end

function RTS:EndIntroCinematic(skipped)
    if not self.CinematicActive then return end
    self:ClearIntroScene()
    self.CinematicActive = false
    self.CinematicCaption = nil
    self.CinematicSubcaption = nil
    self.CinematicFaction = nil
    self.CinematicCaptionAlpha = 0
    self.IntroFadeInUntil=not skipped and self:UINow()+1 or nil
    io.setCursorHidden(false)

    local c = self.Config.Camera
    self.CameraFocus = vec(c.Focus.x, c.Focus.y, c.Focus.z)
    self.CameraDistance = c.Distance
    self.CameraPitch = math.rad(c.PitchDegrees)
    self.CameraYaw = math.rad(c.YawDegrees)
    self.Camera.FOV = c.FOV
    self:UpdateCameraTransform()
    gr.setCamera(self.Camera)
    self.StatusMessage = skipped and "Intro skipped. Configure escalation battle, then START." or "Configure escalation battle, then START."
    self.StatusUntil = math.huge
    self:Log(skipped and "Mission intro cinematic skipped" or "Mission intro cinematic complete")
end

function RTS:UpdateIntroCinematic(dt)
    if not self.CinematicActive then return end
    local cfg = self.Config.Cinematic
    local shots = cfg.Shots
    self.CinematicElapsed = self.CinematicElapsed + math.max(0, dt or 0)

    local cursor = 0
    local shot = nil
    local shotStart = 0
    local shotDuration = 0
    local shotIndex = 1
    for i, candidate in ipairs(shots) do
        local duration = self:GetCinematicShotDuration(candidate) + math.max(0, candidate.hold or 0)
        if self.CinematicElapsed < cursor + duration then
            shot = candidate
            shotStart = cursor
            shotDuration = duration
            shotIndex = i
            break
        end
        cursor = cursor + duration
    end

    if shot == nil then
        -- Hold the last framing for a beat instead of freezing on the cut, so a
        -- player who just watches still sees the shot resolve.
        local hold = self.CinematicTailHold
        if hold == nil then
            local last = shots[#shots]
            local tail = math.max(0, (cfg.EndHoldSeconds) or 0)
            if tail <= 0 then self:EndIntroCinematic(false) return end
            hold = { position = self.Camera.Position, orientation = self.Camera.Orientation:copy(), time = 0, duration = tail }
            if last ~= nil and last.to ~= nil and not last.subject then
                local look = last.target or last.targetTo or last.targetFrom
                if look ~= nil then
                    hold.direction = vec(look.x-last.to.x, look.y-last.to.y, look.z-last.to.z):getOrientation()
                end
            end
            self.CinematicTailHold = hold
        end
        hold.time = hold.time + math.max(0, dt or 0)
        -- Hold the final pose while fading out; moving it again made the cut lurch.
        local fade = math.min(1, hold.time / math.max(0.001, hold.duration))
        local orientation = hold.direction or hold.orientation
        self.Camera.Position = hold.position
        self.Camera.Orientation = orientation:copy()
        gr.setCamera(self.Camera)
        self.CinematicShotIndex = #shots
        self.CinematicCaptionAlpha = math.floor(255*(1-fade))
        if hold.time >= hold.duration then self:EndIntroCinematic(false) end
        return
    end

    self.CinematicTailHold = nil
    self.CinematicShotIndex = shotIndex
    if shotIndex>=5 and not self.IntroRetreatStarted and shipAlive((self.IntroShips or {})[5]) then
        local bomber=self.IntroShips[5]
        bomber.HitpointsLeft=bomber.HitpointsMax*.3
        local waypoint=self:GetOrCreateMoveWaypoint(bomber)
        assert(objectValid(waypoint),'Intro withdrawal waypoint creation failed')
        waypoint.Position=vec(-4000,45000,1200)
        bomber:clearOrders()
        assert(bomber:giveOrder(ORDER_WAYPOINTS_ONCE,waypoint,nil,.98)==true,'Intro withdrawal order refused')
        self.IntroRetreatStarted=true
    end
    local p1 = shot.from
    if p1 == nil then self:EndIntroCinematic(false) return end
    local p2 = shot.to or p1
    local target1 = shot.targetFrom or shot.target or p2
    local target2 = shot.targetTo or shot.target or target1
    local subject=(self.IntroShips or {})[shot.subject or 0]
    if shipAlive(subject) then
        local anchor=subject.Position
        p1={x=anchor.x+p1.x,y=anchor.y+p1.y,z=anchor.z+p1.z}
        p2={x=anchor.x+p2.x,y=anchor.y+p2.y,z=anchor.z+p2.z}
        target1={x=anchor.x+target1.x,y=anchor.y+target1.y,z=anchor.z+target1.z}
        target2={x=anchor.x+target2.x,y=anchor.y+target2.y,z=anchor.z+target2.z}
    end

    local hold = math.max(0, shot.hold or 0)
    local moveDuration = math.max(0.001, shotDuration - hold)
    local moveT = clamp((self.CinematicElapsed - shotStart - hold) / moveDuration, 0, 1)
    local smooth = moveT * moveT * (3 - 2 * moveT)

    local position = vec(
        p1.x + (p2.x - p1.x) * smooth,
        p1.y + (p2.y - p1.y) * smooth,
        p1.z + (p2.z - p1.z) * smooth
    )
    local target = vec(
        target1.x + (target2.x - target1.x) * smooth,
        target1.y + (target2.y - target1.y) * smooth,
        target1.z + (target2.z - target1.z) * smooth
    )
    local direction = target - position

    self.Camera.Position = position
    self.Camera.Orientation = direction:getOrientation()
    local fov = shot.fov or cfg.FOV or self.Config.Camera.FOV
    if shot.fovTo ~= nil then fov = fov + (shot.fovTo - fov) * smooth end
    self.Camera.FOV = fov
    gr.setCamera(self.Camera)

    self.CinematicFaction = shot.faction
    self.CinematicCaption = shot.caption
    self.CinematicSubcaption = shot.subcaption
    -- Keep the caption up through the hold beat, then fade with the move.
    local t = clamp((self.CinematicElapsed - shotStart) / math.max(0.001, shotDuration), 0, 1)
    local fade = math.min(1, t / 0.14, (1 - t) / 0.14)
    self.CinematicCaptionAlpha = math.floor(255 * clamp(fade, 0, 1))
end

function RTS:DrawCinematicOverlay(sw, sh)
    local cfg = self.Config.Cinematic or {}
    local m = self:GetUIMetrics(sw, sh)
    local edge = m.pad(40)
    local lines=self:WrapTextLinesToWidth(self.CinematicSubcaption or '',sw-2*m.pad(80),3)
    -- Reserve the persistent hints-key footer beneath every wrapped caption.
    local bar = math.max(78, math.floor(sh * 0.13),m.pad(40)+(2+#lines)*m.lineHeight)
    gr.setColor(0, 0, 0, 255)
    gr.drawRectangle(0, 0, sw, bar, true)
    gr.drawRectangle(0, sh - bar, sw, sh, true)

    local alpha = self.CinematicCaptionAlpha or 255
    if self.CinematicFaction ~= nil then
        gr.setColor(110, 225, 255, alpha)
        -- No scalable font is guaranteed by retail assets, so make the faction
        -- title visually dominant with a centered framed banner.
        local fw = math.min(m.pad(760), sw - 4*edge)
        local fx1 = (sw - fw) / 2
        local fx2 = fx1 + fw
        gr.drawRectangle(fx1, bar + 24, fx2, bar + 70, false)
        self:DrawCenteredTextClipped(self.CinematicFaction, fx1 + 12, fx2 - 12, bar + 38)
    end
    if self.CinematicCaption ~= nil then
        gr.setColor(220, 238, 245, alpha)
        self:DrawCenteredTextClipped(self.CinematicCaption, edge, sw - edge, sh - bar + m.pad(16))
    end
    if self.CinematicSubcaption ~= nil then
        gr.setColor(120, 205, 225, alpha)
        for i,line in ipairs(lines) do
            self:DrawCenteredTextClipped(line,m.pad(80),sw-m.pad(80),sh-bar+m.pad(24)+i*m.lineHeight)
        end
    end

    if self.ShowHotkeyHints==false then return end
    local switchHint = ""
    if cfg.AllowSkip ~= false then
        local parts = { "PRESS ANY KEY OR MOUSE BUTTON TO SKIP" }
        if cfg.NextShotKey ~= nil and cfg.PreviousShotKey ~= nil then
            parts[#parts + 1] = string.format("%s / %s CHANGE SHOT", tostring(cfg.PreviousShotKey), tostring(cfg.NextShotKey))
        end
        if cfg.RestartShotKey ~= nil then parts[#parts + 1] = string.format("%s REPLAY SHOT", tostring(cfg.RestartShotKey)) end
        switchHint = table.concat(parts, "   //   ")
    else
        switchHint = "MISSION INTRO"
    end
    gr.setColor(115, 135, 145, 210)
    self:DrawCenteredTextClipped(switchHint, edge, sw - edge, 20)
end

-- Cinematic battle camera: hides the RTS HUD and cuts between ships in the
-- fight, orbiting each one on the follow camera. The simulation keeps running.
-- C cycles: off -> director (auto shots) -> free camera (UI hidden, normal
-- WASD/mouse camera controls) -> off.
function RTS:ToggleBattleCam()
    if self.BattleCamActive then self:StopBattleCam() return end
    if self.FreeCamActive then self.FreeCamActive=false end
    if self.SetupActive or self.PostBattleActive or self.PossessedSignature~=nil then return end
    self:ExitFollowMode()
    self.RightDrag=nil; self.MovePreview=nil
    self.BattleCamActive=true; self.BattleCamSignature=nil; self.BattleCamShotUntil=0
end

-- Shift+C: hide the RTS UI only; the normal camera controls stay live and
-- nothing moves on its own.
function RTS:ToggleFreeCam()
    if self.BattleCamActive then self:StopBattleCam() end
    self.RightDrag=nil; self.MovePreview=nil
    self.FreeCamActive=not self.FreeCamActive
    if self.FreeCamActive then self.FreeCamHintUntil=self:UINow()+3 end
end

function RTS:StopBattleCam()
    if not self.BattleCamActive then return end
    local ship=self.BattleCamSignature and self:FindShipBySignature(self.BattleCamSignature)
    if shipValid(ship) then self.CameraFocus=copyVec(ship.Position) end
    self.BattleCamActive=false; self.BattleCamSignature=nil
    self.FollowZoom=1.0; self.FollowYawOffset=0; self.FollowPitchOffset=0.22
    gr.setCamera(self.Camera); self:UpdateCameraTransform(); self:SetStatus("Tactical camera",1.5)
end

function RTS:PickBattleCamTarget()
    local best,bestScore=nil,-1
    local now=mn.getMissionTime(); local activity=self.AIStats and self.AIStats.hits or {}
    for _,ship in ipairs(self:GetShipList()) do
        if ship.Name~=self.Config.ObserverShip and ship:getSignature()~=self.BattleCamSignature and not self:IsStaticDefense(ship) then
            local hull=ship.HitpointsMax>0 and ship.HitpointsLeft/ship.HitpointsMax or 1
            local id=ship:getSignature(); local hit=activity[id]; local recentHit=hit and hit.hostileTime and now-hit.hostileTime<=8
            local target=objectValid(ship.Target) and ship.Target or nil
            local attacking=target~=nil and self:AreEnemies(ship,target)
            local targeters=(self.AITargetedBy or {})[id]; local underFire=false
            if targeters then for faction,ships in pairs(targeters) do if faction~=self:GetFactionKey(ship) and next(ships) then underFire=true; break end end end
            local observation=(self.AIObservations or {})[id]
            local active=recentHit or attacking or underFire or (observation and (observation.engaged or observation.hitObserved))
            local score=active and (100+(self:IsCapitalTarget(ship) and 8 or 0)+(underFire and 20 or 0)
                +(attacking and 10 or 0)+(hull<.75 and 5 or 0))
                or (self:IsCapitalTarget(ship) and 3 or 1)*(hull<0.97 and 2 or 1)*math.random()
            if score>bestScore then best,bestScore=ship,score end
        end
    end
    return best
end

function RTS:UpdateBattleCam()
    if self.PostBattleActive then self:StopBattleCam() return end
    local cfg=self.Config.BattleCam or {}
    local ship=self.BattleCamSignature and self:FindShipBySignature(self.BattleCamSignature)
    if not shipValid(ship) or self:UINow()>=self.BattleCamShotUntil then
        ship=self:PickBattleCamTarget()
        if ship==nil then self:StopBattleCam() return end
        self.BattleCamSignature=ship:getSignature(); self.BattleCamShotUntil=self:UINow()+(cfg.ShotSeconds or 9)
        self.BattleCamShotStart=self:UINow(); self.BattleCamYawStart=math.random()*math.pi*2
        self.FollowZoom=0.8+math.random()*0.9; self.FollowPitchOffset=-0.25+math.random()*0.7
    end
    self.FollowYawOffset=self.BattleCamYawStart+(self:UINow()-self.BattleCamShotStart)*(cfg.OrbitRadiansPerSecond or 0.12)
    self:UpdateFollowCamera(ship)
end

function RTS:DrawBattleCamOverlay(sw, sh)
    local m=self:GetUIMetrics(sw,sh)
    local edge=m.pad(40)
    local bar=math.max(60,math.floor(sh*0.10))
    gr.setColor(0,0,0,255); gr.drawRectangle(0,0,sw,bar,true); gr.drawRectangle(0,sh-bar,sw,sh,true)
    local ship=self.BattleCamSignature and self:FindShipBySignature(self.BattleCamSignature)
    if shipValid(ship) then
        gr.setColor(220,238,245,255); self:DrawCenteredTextClipped(ship.Name,edge,sw-edge,sh-bar+m.pad(14))
        gr.setColor(120,205,225,255); self:DrawCenteredTextClipped(ship.Class.Name.."  //  "..tostring(self:GetFactionKey(ship) or ""),edge,sw-edge,sh-bar+m.pad(34))
    end
    local key=tostring((self.Config.HomeworldControls or {}).Cinematic or "C")
    gr.setColor(115,135,145,210)
    self:DrawCenteredTextClipped("CINEMATIC: DIRECTOR  //  "..key.." OR CLICK TO RETURN  //  SHIFT+"..key.." HIDE UI",edge,sw-edge,math.floor(bar/2)-6)
end

function RTS:ExitFollowMode(message)
    if self.FollowSignature == nil then return end
    local followed = self:FindShipBySignature(self.FollowSignature)
    if shipValid(followed) then self.CameraFocus = copyVec(followed.Position) end
    self.FollowSignature=nil; self.FollowZoom=1.0; self.FollowYawOffset=0; self.FollowPitchOffset=0.22; self.FollowOrbitDrag=nil
    gr.setCamera(self.Camera); self:UpdateCameraTransform()
    if message then self:SetStatus(message,2) end
end

function RTS:StartFollowMode(ship)
    if not shipValid(ship) or ship.Name == self.Config.ObserverShip then return end

    self.FollowSignature = ship:getSignature()
    self.FollowZoom = 1.0
    self.FollowYawOffset = 0
    self.FollowPitchOffset = 0.22
    self:UpdateFollowCamera(ship)
    self:SetStatus("CHASE MODE: " .. ship.Name, 2)
end

function RTS:UpdateFollowCamera(ship)
    if self.FollowCamera == nil or not shipValid(ship) then return end
    local radius=30; if ship.Class and ship.Class.Model then radius=math.max(1,ship.Class.Model.Radius) end
    local c=self.Config.Camera
    local baseDistance=math.max(c.FollowMinDistance or 180,radius*(c.FollowRadiusMultiplier or 3.2))
    local distance=baseDistance*self.FollowZoom
    local o=ship.Orientation; local forward=o:getFvec(); local up=o:getUvec(); local right=o:getRvec()
    local yaw=self.FollowYawOffset or 0; local pitch=self.FollowPitchOffset or 0.22
    local cy,sy=math.cos(yaw),math.sin(yaw); local cp,sp=math.cos(pitch),math.sin(pitch)
    local horizontal = forward * (-cy) + right * sy
    local offset = horizontal * (distance*cp) + up * (distance*sp)
    local position=ship.Position+offset
    local lookAt=ship.Position+forward*(radius*(c.FollowLookAheadRadii or 1.0))
    self.FollowCamera.Position=position; self.FollowCamera.Orientation=(lookAt-position):getOrientation(); self.FollowCamera.FOV=c.FollowFOV or c.FOV
    self.CameraFocus=copyVec(ship.Position); gr.setCamera(self.FollowCamera)
end
