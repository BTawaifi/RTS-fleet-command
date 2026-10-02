-- Tactical camera, intro cinematic, follow camera.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:SetupCamera()
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
    self:SetStatus(string.format("CINEMATIC SHOT %d/%d", index, count), 1.2)
    return true
end

function RTS:CinematicRestartShot()
    return self:CinematicNextShot(0, true)
end

function RTS:StartIntroCinematic()
    local cfg = self.Config.Cinematic
    if cfg == nil or cfg.Enabled == false or cfg.Shots == nil or #cfg.Shots == 0 then
        self.CinematicActive = false
        return
    end

    self.CinematicActive = true
    self.CinematicElapsed = 0
    self.CinematicShotIndex = 1
    self.CinematicShotProgress = 0
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
    self.CinematicActive = false
    self.CinematicCaption = nil
    self.CinematicSubcaption = nil
    self.CinematicFaction = nil
    self.CinematicCaptionAlpha = 0
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
            if last ~= nil and last.to ~= nil then
                local look = last.target or last.targetTo or last.targetFrom
                if look ~= nil then
                    hold.direction = vec(look.x-last.to.x, look.y-last.to.y, look.z-last.to.z):getOrientation()
                end
            end
            self.CinematicTailHold = hold
        end
        hold.time = hold.time + math.max(0, dt or 0)
        -- Slow lateral drift through the final framing while it resolves.
        local drift = math.min(1, hold.time / math.max(0.001, hold.duration))
        local base = hold.position
        local swing = math.sin(drift * math.pi) * (base.x * 0.02 + 400)
        local position = vec(base.x + swing, base.y, base.z)
        local orientation = hold.direction or hold.orientation
        self.Camera.Position = position
        self.Camera.Orientation = orientation:copy()
        gr.setCamera(self.Camera)
        self.CinematicShotIndex = #shots
        self.CinematicShotProgress = 1
        self.CinematicCaptionAlpha = 255
        if hold.time >= hold.duration then self:EndIntroCinematic(false) end
        return
    end

    self.CinematicTailHold = nil
    self.CinematicShotIndex = shotIndex
    local p1 = shot.from
    if p1 == nil then self:EndIntroCinematic(false) return end
    local p2 = shot.to or p1
    local target1 = shot.targetFrom or shot.target or p2
    local target2 = shot.targetTo or shot.target or target1

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
    self.CinematicShotProgress = t
    local fade = math.min(1, t / 0.14, (1 - t) / 0.14)
    self.CinematicCaptionAlpha = math.floor(255 * clamp(fade, 0, 1))
end

function RTS:DrawCinematicOverlay(sw, sh)
    local cfg = self.Config.Cinematic or {}
    local m = self:GetUIMetrics(sw, sh)
    local edge = m.pad(40)
    local bar = math.max(78, math.floor(sh * 0.13))
    gr.setColor(0, 0, 0, 255)
    gr.drawRectangle(0, 0, sw, bar, true)
    gr.drawRectangle(0, sh - bar, sw, sh, true)

    local count = #((cfg.Shots) or {})
    if count > 0 then
        local index = self.CinematicShotIndex or 1
        local progress = clamp(self.CinematicShotProgress or 0, 0, 1)
        -- The progress track is sized from the screen rather than left at a
        -- fixed 260px, which on a 4K panel left the shot counter stranded in
        -- the left eighth of the bar.
        local trackW = clamp(math.floor(sw * 0.22), m.pad(260), m.pad(900))
        local tx1 = edge
        local ty1 = bar - 20
        gr.setColor(70, 92, 104, 220)
        gr.drawRectangle(tx1, ty1, tx1 + trackW, ty1 + 4, true)
        gr.setColor(120, 220, 245, 235)
        gr.drawRectangle(tx1, ty1, tx1 + math.max(2, math.floor(trackW * progress)), ty1 + 4, true)
        for i = 1, count do
            local cx = tx1 + math.floor(((i - 1) / math.max(1, count - 1)) * trackW)
            local active = i == index
            gr.setColor(active and 245 or 90, active and 235 or 105, active and 160 or 120, active and 255 or 190)
            gr.drawRectangle(cx - 1, ty1 - 3, cx + 1, ty1 + 7, true)
        end
        gr.setColor(160, 200, 215, 220)
        self:DrawCenteredTextClipped(string.format("SHOT %d/%d", index, count), tx1 + trackW + 12, sw - edge, ty1 - 6)
    end

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
        self:DrawCenteredTextClipped(self.CinematicCaption, edge, sw - edge, sh - bar + 16)
    end
    if self.CinematicSubcaption ~= nil then
        gr.setColor(120, 205, 225, alpha)
        self:DrawCenteredWrappedText(self.CinematicSubcaption, m.pad(80), sw - m.pad(80), sh - bar + 43, 104, 18, 3)
    end

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
