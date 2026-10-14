-- Mouse release, wheel and gesture reset.
local _shared = require "fs2rts_input.common"
local RTS, shipValid, copyVec, clamp = _shared.RTS, _shared.shipValid, _shared.copyVec, _shared.clamp

-- A facing drag only makes sense on a real move order: something selected, not
-- over the HUD, and starting on empty space.
function RTS:CanStartFacingDrag(x,y)
    if self.ArmedCommand~=nil or self.Paused or self.BattleCamActive or self.FreeCamActive then return false end
    if self:IsPointOnRTSUI(x,y) or self:IsPointOnTacticalMap(x,y) then return false end
    if #self:GetSelectedFriendlyShips()==0 then return false end
    if self:GetShipAtScreen(x,y,true,true)~=nil then return false end
    return true
end

-- An armed command released on the tactical map.
--
-- Only sentry and strike were handled here. MOVE and ATTACK fell straight
-- through to SelectMapClick/SelectMapBox, so arming MOVE (M or the MOVE
-- button), pressing MOVE on the map and clicking the destination changed the
-- selection instead of moving the fleet, and the armed state survived so the
-- next world click moved it to somewhere the player never looked. The map is
-- where an RTS player issues orders, so an armed order has to work there.
--
-- Returns true when it consumed the release. A release that started on the
-- map but ended off it is still consumed, which is what the sentry and strike
-- path already did, so the click does not fall through and select a hull in
-- the world instead.
function RTS:ExecuteMapArmedCommand(x, y)
    local kind = self.ArmedCommand
    if kind == nil then return false end
    if not self:IsPointOnTacticalMap(x, y) then return true end
    if kind == "sentry" or kind == "strike" then
        self:ExecuteStationArmedCommand(self:TacticalMapToWorld(x, y))
        return true
    end
    if kind == "move" then
        local target = self:TacticalMapToWorld(x, y)
        if self:IsFiniteVector(target) then self:IssueMove(target); self:SetOrderPing(target, "move") end
        self.ArmedCommand = nil
        return true
    end
    if kind == "attack" then
        local target = self:GetMapShipAt(x, y)
        if shipValid(target) and self:IsPlayerEnemy(target) then
            self:IssueAttack(target)
            self:SetOrderPing(target.Position, "attack")
        else
            self:SetStatus("ATTACK: click an enemy contact on the map (right-click cancels)", 2)
        end
        self.ArmedCommand = nil
        return true
    end
    return false
end

function RTS:OnMouseReleased(button)
    if not self.Enabled or self.PossessedSignature~=nil then return end
    self:BeginFrameProjection()
    -- The click that closed cinematic mode must not also select or issue an order.
    if self.SwallowMouseRelease then self.SwallowMouseRelease=false; return end
    if self.MapWindowDrag and bit.checkBit(button,0) then self.MapWindowDrag=nil; return end
    if self.MapPanDrag and bit.checkBit(button,2) then self.MapPanDrag=nil; return end
    if self.CinematicActive then return end
    local x,y=io.getMouseX(),io.getMouseY()
    if self.ExitMenuActive then
        if bit.checkBit(button,0) then self:HandleUILeftClick(x,y) end
        return
    end
    if self.PostBattleActive then
        if bit.checkBit(button,0) then self:HandlePostBattleClick(x,y) end
        self.LeftDrag=nil; self.MapDrag=nil; self.RightDrag=nil; self.MiddleDrag=nil; self.FollowOrbitDrag=nil; self.MovePreview=nil
        return
    end
    if bit.checkBit(button,0) then
        if self.EnvironmentPicker then self:HandleFleetLifeClick(x,y); self:ClearInputGestures(); return end
        if self.SetupActive then self:HandleSetupClick(x,y); self.LeftDrag=nil; self.MapDrag=nil; return end
        if self.MapDrag then
            local drag=self.MapDrag; self.MapDrag=nil
            if self:ExecuteMapArmedCommand(x,y) then return end
            local dx=x-drag.x1; local dy=y-drag.y1; local threshold=self.Config.Selection.DragThresholdPixels
            if dx*dx+dy*dy<=threshold*threshold then
                if not self:HandleDoubleClick(x,y,true) then self:SelectMapClick(x,y) end
            else self:SelectMapBox(drag.x1,drag.y1,x,y) end
            return
        end
        -- A left press that began in the world owns its release.
        --
        -- The press is the only place that knows where the gesture started. It
        -- used to be thrown away, so HandleUILeftClick ran on every left
        -- release regardless of origin: drag a box-select across the build
        -- panel and releasing over the PRODUCTION row queued a ship, and
        -- releasing over MUSIC toggled the music off. A drag that started on
        -- the world now never reaches a panel; a press that started on a panel
        -- behaves exactly as before.
        local worldGesture = self.LeftDrag ~= nil and not self.LeftDrag.onUI
        if worldGesture and (self.ArmedCommand=='sentry' or self.ArmedCommand=='strike')
            and not self:IsPointOnRTSUI(x,y) then
            self.LeftDrag=nil
            self:ExecuteArmedCommand(x,y)
            return
        end
        local dragged = false
        if worldGesture then
            local drag = self.LeftDrag
            local dx = x - drag.x1; local dy = y - drag.y1
            local threshold = self.Config.Selection.DragThresholdPixels
            dragged = (dx * dx + dy * dy) > threshold * threshold
        end
        if worldGesture and dragged then
            local drag = self.LeftDrag; self.LeftDrag = nil
            self:SelectBox(drag.x1, drag.y1, x, y)
            if drag.alt then self:FocusOnSelection() end
            return
        end
        if not worldGesture and self:HandleUILeftClick(x,y) then self.LeftDrag=nil; return end
        if self:IsPointOnRTSUI(x,y) then self.LeftDrag=nil; return end
        if self.LeftDrag and self.LeftDrag.alt then
            local drag=self.LeftDrag; self.LeftDrag=nil
            local dx=x-drag.x1; local dy=y-drag.y1; local threshold=self.Config.Selection.DragThresholdPixels
            if dx*dx+dy*dy>threshold*threshold then
                self:SelectBox(drag.x1,drag.y1,x,y)
                self:FocusOnSelection()
            else
                local target=self:GetShipAtScreen(x,y,true,true)
                local focus=target and target.Position or self:ScreenToPlane(x,y,self.CameraFocus.y)
                if focus~=nil then
                    if self.FollowSignature~=nil then self:ExitFollowMode("Tactical camera") end
                    self.CameraFocus=copyVec(focus); self:UpdateCameraTransform()
                    self:SetStatus(target and ("Focused: "..target.Name) or "Focused tactical area",1.2)
                end
            end
            return
        end
        if self.LeftDrag then local dx=x-self.LeftDrag.x1; local dy=y-self.LeftDrag.y1; local threshold=self.Config.Selection.DragThresholdPixels; if dx*dx+dy*dy<=threshold*threshold then if not self:ExecuteArmedCommand(x,y) and not self:HandleDoubleClick(x,y) then self:SelectClick(x,y) end else self:SelectBox(self.LeftDrag.x1,self.LeftDrag.y1,x,y) end end
        self.LeftDrag=nil
    elseif bit.checkBit(button,1) then
        if self.FollowOrbitDrag then self.FollowOrbitDrag=nil; return end
        local drag=self.RightDrag; self.RightDrag=nil
        if drag~=nil and drag.facingDrag then
            self.MovePreview=nil
            local destination=self:ScreenToPlane(drag.x1,drag.y1,self.CameraFocus.y)
            if destination==nil then return end
            local facing=nil
            if drag.moved then facing=self:ScreenToPlane(drag.worldX,drag.worldY,self.CameraFocus.y) end
            self:IssueMove(destination,facing)
            return
        end
        if drag~=nil and drag.moved then return end
        if self.ArmedCommand~=nil then self.ArmedCommand=nil; self:SetStatus("Order cancelled",1.2); return end
        if self:IsPointOnTacticalMap(x,y) then self:MapRightClick(x,y); return end
        if self:IsPointOnRTSUI(x,y) then return end
        local selected=self:GetSelectedFriendlyShips(); if #selected==0 then return end
        local hostile=self:GetShipAtScreen(x,y,false,true); if hostile then self:IssueAttack(hostile); return end
        local friendly=self:GetShipAtScreen(x,y,true,false); if friendly then self:IssueGuard(friendly); return end
        local destination=self:ScreenToPlane(x,y,self.CameraFocus.y); if destination then self:IssueMove(destination) end
    elseif bit.checkBit(button,2) then self.MiddleDrag=nil end
end

-- Q/E zoom about the screen centre in wheel-sized steps; steps > 0 zooms in.
function RTS:StepCameraZoom(steps)
    local cam = self.Config.Camera
    self.CameraDistance = clamp(self.CameraDistance * cam.ZoomFactor ^ steps, cam.MinDistance, cam.MaxDistance)
    self:UpdateCameraTransform()
end

function RTS:OnMouseWheel(delta)
    if not self.Enabled or self.PossessedSignature ~= nil or self.CinematicActive or self.BattleCamActive or delta == nil or delta == 0 then return end
    local factor = self.Config.Camera.ZoomFactor

    if self.FollowSignature ~= nil then
        if delta > 0 then self.FollowZoom = self.FollowZoom * (factor ^ delta)
        else self.FollowZoom = self.FollowZoom / (factor ^ (-delta)) end
        self.FollowZoom = clamp(self.FollowZoom, 0.35, 3.5)
        local ship = self:FindShipBySignature(self.FollowSignature)
        if shipValid(ship) then self:UpdateFollowCamera(ship) end
        return
    end

    -- Sins-style zoom-to-cursor: keep the world point under the cursor anchored
    -- while changing altitude/distance.
    local mx, my = io.getMouseX(), io.getMouseY()
    if self:IsPointOnTacticalMap(mx, my) then local v=self:GetMapView(); self:SetMapZoom(v.zoom*(1.25^delta),mx,my); return end
    local anchorBefore = self:ScreenToPlane(mx, my, self.CameraFocus.y)
    if delta > 0 then self.CameraDistance = self.CameraDistance * (factor ^ delta)
    else self.CameraDistance = self.CameraDistance / (factor ^ (-delta)) end
    self.CameraDistance = clamp(self.CameraDistance, self.Config.Camera.MinDistance, self.Config.Camera.MaxDistance)
    self:UpdateCameraTransform()
    local anchorAfter = self:ScreenToPlane(mx, my, self.CameraFocus.y)
    if anchorBefore ~= nil and anchorAfter ~= nil then
        self.CameraFocus.x = self.CameraFocus.x + (anchorBefore.x - anchorAfter.x)
        self.CameraFocus.z = self.CameraFocus.z + (anchorBefore.z - anchorAfter.z)
        self:UpdateCameraTransform()
    end
end

function RTS:ClearInputGestures()
    self.HotkeyHintsHeld=false
    self.FleetCostKeyHeld=false
    self.KeyDown={}; self.FastKeyDown={}; self.ShiftDown=false; self.CtrlDown=false; self.AltDown=false
    self.LeftDrag=nil; self.RightDrag=nil; self.MiddleDrag=nil; self.MapDrag=nil
    self.MapWindowDrag=nil; self.MapPanDrag=nil; self.FollowOrbitDrag=nil; self.MovePreview=nil
    self.SwallowMouseRelease=false
end
