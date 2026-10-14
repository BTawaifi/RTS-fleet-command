-- Camera view shortcuts and per-frame camera input.
local _shared = require "fs2rts_input.common"
local RTS, vec, copyVec, shipValid, clamp = _shared.RTS, _shared.vec, _shared.copyVec, _shared.shipValid, _shared.clamp

function RTS:ResetCameraView()
    self.FollowSignature = nil
    self.FollowZoom = 1.0
    gr.setCamera(self.Camera)
    local c = self.Config.Camera
    self.CameraFocus = vec(c.Focus.x, c.Focus.y, c.Focus.z)
    self.CameraDistance = c.Distance
    self.CameraPitch = math.rad(c.PitchDegrees)
    self.CameraYaw = math.rad(c.YawDegrees)
    self:UpdateCameraTransform()
end

function RTS:FocusOnBase()
    if self.BattleCamActive then self:StopBattleCam() end
    if self.FollowSignature ~= nil then self:ExitFollowMode() end
    local base = self:GetCarrier()
    if shipValid(base) then
        self.CameraFocus = copyVec(base.Position)
        self.CameraDistance = math.max(self.Config.Camera.MinDistance, math.min(self.CameraDistance, self.Config.Camera.Distance))
        self:UpdateCameraTransform()
        self:SetStatus("Focused "..self:GetFactionDisplayName("BLUE").." station", 1.2)
    else
        self:ResetCameraView()
    end
end

function RTS:UpdateCameraInput(dt)
    if self.FollowSignature ~= nil then return end
    local distanceScale=clamp(self.CameraDistance/math.max(1,self.Config.Camera.Distance),.25,5)
    local multiplier=self.ShiftDown and (self.Config.Camera.ShiftSlowMultiplier or .35) or 1
    local speed=self.Config.Camera.PanSpeed*dt*distanceScale*multiplier
    local sinYaw,cosYaw=math.sin(self.CameraYaw),math.cos(self.CameraYaw); local forwardX,forwardZ=sinYaw,cosYaw; local rightX,rightZ=cosYaw,-sinYaw
    local moveForward,moveRight=0,0; local controls=self.Config.HomeworldControls or {}
    if self.KeyDown[controls.PanForward or "W"] or self.KeyDown["Up"] then moveForward=moveForward+1 end
    if self.KeyDown[controls.PanBackward or "S"] or self.KeyDown["Down"] then moveForward=moveForward-1 end
    if self.KeyDown[controls.PanRight or "D"] or self.KeyDown["Right"] then moveRight=moveRight+1 end
    if self.KeyDown[controls.PanLeft or "A"] or self.KeyDown["Left"] then moveRight=moveRight-1 end
    if self.Config.Camera.EdgePanEnabled==true then
        local mx,my=io.getMouseX(),io.getMouseY(); local sw,sh=gr.getScreenWidth(),gr.getScreenHeight(); local edgeX=sw*self.Config.Camera.EdgePanFraction; local edgeY=sh*self.Config.Camera.EdgePanFraction
        if mx<=edgeX then moveRight=moveRight-1 end; if mx>=sw-edgeX then moveRight=moveRight+1 end; if my<=edgeY then moveForward=moveForward+1 end; if my>=sh-edgeY then moveForward=moveForward-1 end
    end
    if moveForward~=0 or moveRight~=0 then self.CameraFocus.x=self.CameraFocus.x+(forwardX*moveForward+rightX*moveRight)*speed; self.CameraFocus.z=self.CameraFocus.z+(forwardZ*moveForward+rightZ*moveRight)*speed; self:UpdateCameraTransform() end
end
