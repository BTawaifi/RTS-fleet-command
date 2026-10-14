-- Mouse input: UI clicks, pressed and moved handlers.
local _shared = require "fs2rts_input.common"
local RTS, clamp, shipValid = _shared.RTS, _shared.clamp, _shared.shipValid

function RTS:HandleUILeftClick(x,y)
    if self.HandleFleetHistoryClick and not self.ExitMenuActive and not self.PostBattleActive and not self.SetupActive
        and not self.CinematicActive and self:HandleFleetHistoryClick(x,y) then return true end
    if self.ExitMenuActive then
        for action,rect in pairs(self.ExitMenuButtonRects or {}) do
            if self:PointInside(rect,x,y) then return self:HandleExitMenuAction(action) end
        end
        return true
    end
    if self:HandleFleetLifeClick(x,y) then return true end
    if self:PointInside(self.SceneButtonRect,x,y) then self.EnvironmentPicker=true; self:ClearInputGestures(); return true end
    if self:PointInside(self.ExitMenuButtonRect,x,y) then self:OpenExitMenu(); return true end
    if self.SetupActive then return self:HandleSetupClick(x,y) end
    if self:PointInside(self.NewUnitPopupSelectRect,x,y) then self:SelectNewUnitPopup(); return true end
    if self.AftermathActive and self:PointInside(self.AftermathReportRect,x,y) then self:OpenSurvivorReport(); return true end
    for tab,rect in pairs(self.PanelTabRects or {}) do if self:PointInside(rect,x,y) then self.PanelTab=tab; return true end end
    if self.PanelTab=="station" and self:HandleStationPanelClick(x,y) then return true end
    for scale,rect in pairs(self.TimeButtonRects or {}) do if self:PointInside(rect,x,y) then if scale=="pause" then self:TogglePause() elseif self.Paused then self:SetPaused(false) end; if scale~="pause" then self:SetTimeScale(tonumber(scale)) end; return true end end
    if self:PointInside(self.AutoModeRect,x,y) then self:SetAutoPlayerMode(not self.AutoPlayerMode); return true end
    if self:PointInside(self.CancelAutoBuildRect,x,y) then self:CancelAutoBuildRequest(); return true end
    if self:PointInside(self.FormationButtonRect,x,y) then self:CycleSelectedFormation(1); return true end
    if self:PointInside(self.MusicButtonRect,x,y) then self:ToggleMusicMute(); return true end
    for group,rect in pairs(self.QuickGroupRects or {}) do
        if self:PointInside(rect,x,y) then
            local n=tonumber(group); if self.CtrlDown or (self:GetControlGroupCount(n)==0 and #self:GetSelectedFriendlyShips()>0) then self:AssignControlGroup(n) else self:RecallControlGroup(n) end
            return true
        end
    end
    for index=1,self.SelectionRowsShown or 0 do
        local row=self.SelectionRows[index]
        if row.rect and self:PointInside(row.rect,x,y) then
            local sigs={}; for _,sig in ipairs(row.sigs) do if self:IsSelectableShip(self:FindShipBySignature(sig)) then sigs[#sigs+1]=sig end end
            if #sigs>0 then self.Selected=sigs; self.PrimarySelectionSignature=sigs[1] end
            return true
        end
    end
    for index,rect in pairs(self.AutoBuildRequestRects or {}) do if self:PointInside(rect,x,y) then
        local ok,reason=self:RequestAutoBuild(self.BuildCatalog[index].class)
        self:SetStatus(ok and ('AI will save for '..self.BuildCatalog[index].label) or ('AI request: '..tostring(reason)),4); return true
    end end
    for index,rect in pairs(self.BuildButtonRects or {}) do if self:PointInside(rect,x,y) then self:QueueBuildOption(self.BuildCatalog[index]); return true end end
    if self:PointInside(self.BuildNavRects.prev,x,y) then self.BuildPage=math.max(1,self.BuildPage-1); return true end
    if self.BuildNavRects.filter and self:PointInside(self.BuildNavRects.filter,x,y) then
        local filters={"all","fighter","bomber","escort","capital"}; local current=self.BuildRoleFilter or "all"
        for i,value in ipairs(filters) do if value==current then self.BuildRoleFilter=filters[i%#filters+1]; break end end
        self.BuildPage=1; return true
    end
    if self:PointInside(self.BuildNavRects.next,x,y) then local pages=math.max(1,math.ceil(#self:GetVisibleBuildCatalog()/self.BuildRowsPerPage)); self.BuildPage=math.min(pages,self.BuildPage+1); return true end
    for action,rect in pairs(self.ActionButtonRects) do if self:PointInside(rect,x,y) then if action=="selectall" then self:SelectAll() elseif action=="hold" then self:HoldSelected() elseif action=="engage" then self:EngageSelected() elseif action=="release" then self:ReleaseSelected() elseif action=="service" then self:ServiceSelected() elseif action=="move" then self:ArmCommand("move") elseif action=="attack" then self:ArmCommand("attack") elseif action=="pilot" then self:EnterPilotFromSelection() elseif action=="focus" then self:FocusOnSelection() end; return true end end
    for policy,rect in pairs(self.PolicyButtonRects) do if self:PointInside(rect,x,y) then self:SetGlobalPolicy(policy); return true end end
    return false
end

function RTS:OnMousePressed(button)
    if not self.Enabled or self.PossessedSignature~=nil then return end
    -- A mouse event is an epoch boundary: nothing can move a ship or the camera
    -- between this point and the end of the handler, so anything projected
    -- earlier in this handler is as current as anything projected later in it.
    self:BeginFrameProjection()
    self:DisarmObserverWeapons()
    if self.CinematicActive then local cfg=self.Config.Cinematic or {}; if cfg.AllowSkip~=false and cfg.SkipOnAnyInput~=false then self.SwallowMouseRelease=true; self:EndIntroCinematic(true) end; return end
    if self.BattleCamActive then self:StopBattleCam(); self.SwallowMouseRelease=true; return end
    local x,y=io.getMouseX(),io.getMouseY()
    if self.PostBattleActive or self.ExitMenuActive then return end
    if self.SetupActive then return end
    if bit.checkBit(button,0) then
        if self:HandleMapUIPress(x,y) then self.LeftDrag=nil; self.MapDrag=nil; return end
        if self:IsPointOnTacticalMap(x,y) then self.MapDrag={x1=x,y1=y,x2=x,y2=y}; self.LeftDrag=nil
        else
            -- onUI is load bearing. A press is the only place that knows where
            -- the gesture started, and the release has to be able to tell a
            -- click that began on a panel from a box-select that happened to
            -- finish over one.
            self.LeftDrag={x1=x,y1=y,x2=x,y2=y,alt=self.AltDown==true,onUI=self:IsPointOnRTSUI(x,y)}
        end
    elseif bit.checkBit(button,1) then
        if self.FollowSignature~=nil then self.FollowOrbitDrag={x=x,y=y,startX=x,startY=y,moved=false}
        elseif self:CanStartFacingDrag(x,y) then
            -- Right drag from empty space with a selection is a move order, not a
            -- camera orbit: press sets the destination, drag sets the facing.
            self.RightDrag={x=x,y=y,x1=x,y1=y,startX=x,startY=y,moved=false,worldX=x,worldY=y,facingDrag=true}
            self.MovePreview=nil
        else self.RightDrag={x=x,y=y,startX=x,startY=y,moved=false} end
    elseif bit.checkBit(button,2) then
        if self:IsPointOnTacticalMap(x,y) then self.MapPanDrag={x=x,y=y}; return end
        if self.FollowSignature~=nil then self:ExitFollowMode("Tactical camera") end
        self.MiddleDrag={x=x,y=y,startX=x,startY=y,moved=false}
    end
end

function RTS:OnMouseMoved()
    if not self.Enabled or self.PossessedSignature~=nil or self.CinematicActive or self.PostBattleActive or self.ExitMenuActive then return end
    self:BeginFrameProjection()
    local x,y=io.getMouseX(),io.getMouseY()
    if self.MapWindowDrag then self:UpdateMapWindowDrag(x,y); return end
    if self.MapPanDrag then
        local a=self:TacticalMapToWorld(self.MapPanDrag.x,self.MapPanDrag.y); local b=self:TacticalMapToWorld(x,y); local v=self:GetMapView()
        v.cx=v.cx+(a.x-b.x); v.cz=v.cz+(a.z-b.z); self:ClampMapCenter(); self.MapPanDrag.x=x; self.MapPanDrag.y=y; return
    end
    if self.MapDrag then self.MapDrag.x2=x; self.MapDrag.y2=y elseif self.LeftDrag then self.LeftDrag.x2=x; self.LeftDrag.y2=y end
    local threshold=self.Config.Camera.DragThresholdPixels or 5
    if self.FollowOrbitDrag then
        local d=self.FollowOrbitDrag; local dx=x-d.x; local dy=y-d.y; local tx=x-d.startX; local ty=y-d.startY
        if tx*tx+ty*ty>threshold*threshold then d.moved=true end
        if d.moved then
            local slow=self.ShiftDown and (self.Config.Camera.ShiftSlowMultiplier or .35) or 1
            self.FollowYawOffset=(self.FollowYawOffset or 0)-dx*(self.Config.Camera.MouseOrbitYaw or .006)*slow
            self.FollowPitchOffset=clamp((self.FollowPitchOffset or .22)+dy*(self.Config.Camera.MouseOrbitPitch or .004)*slow,-1.18,1.18)
            local ship=self:FindShipBySignature(self.FollowSignature); if shipValid(ship) then self:UpdateFollowCamera(ship) end
        end
        d.x=x; d.y=y
        return
    end
    local function orbit(drag)
        local dx=x-drag.x; local dy=y-drag.y; local tdx=x-drag.startX; local tdy=y-drag.startY
        if tdx*tdx+tdy*tdy>threshold*threshold then drag.moved=true end
        if drag.moved then
            local mult=self.ShiftDown and (self.Config.Camera.ShiftSlowMultiplier or .35) or 1
            self.CameraYaw=self.CameraYaw-dx*(self.Config.Camera.MouseOrbitYaw or .006)*mult
            self.CameraPitch=clamp(self.CameraPitch+dy*(self.Config.Camera.MouseOrbitPitch or .004)*mult,math.rad(self.Config.Camera.MinPitchDegrees),math.rad(self.Config.Camera.MaxPitchDegrees))
            self:UpdateCameraTransform()
        end
        drag.x=x; drag.y=y
    end
    if self.MiddleDrag then
        local dx=x-self.MiddleDrag.x; local dy=y-self.MiddleDrag.y; local tdx=x-self.MiddleDrag.startX; local tdy=y-self.MiddleDrag.startY
        if tdx*tdx+tdy*tdy>threshold*threshold then self.MiddleDrag.moved=true end
        if self.MiddleDrag.moved and (dx~=0 or dy~=0) then
            local sh=math.max(1,gr.getScreenHeight()); local upp=(2*self.CameraDistance*math.tan((self.Camera.FOV or self.Config.Camera.FOV)*.5)/sh)*(self.Config.Camera.MousePanScale or 1)
            if self.ShiftDown then upp=upp*(self.Config.Camera.ShiftSlowMultiplier or .35) end
            local sy,cy=math.sin(self.CameraYaw),math.cos(self.CameraYaw)
            self.CameraFocus.x=self.CameraFocus.x-cy*dx*upp+sy*dy*upp; self.CameraFocus.z=self.CameraFocus.z+sy*dx*upp+cy*dy*upp; self:UpdateCameraTransform()
        end
        self.MiddleDrag.x=x; self.MiddleDrag.y=y
    end
    if self.RightDrag then
        local drag=self.RightDrag
        if drag.facingDrag then
            -- Track the cursor on the command plane so the HUD can draw the
            -- destination and the facing arrow while the drag is live. The
            -- drag threshold is measured from the press point, not the last
            -- move event, so a fast drag cannot be missed.
            local tdx=x-drag.startX; local tdy=y-drag.startY
            if tdx*tdx+tdy*tdy>threshold*threshold then drag.moved=true end
            drag.worldX=x; drag.worldY=y
            local destination=self:ScreenToPlane(drag.x1,drag.y1,self.CameraFocus.y)
            local facing=self:ScreenToPlane(x,y,self.CameraFocus.y)
            self.MovePreview=destination and {destination=destination,facing=facing} or nil
            return
        end
        orbit(drag)
    end
end
