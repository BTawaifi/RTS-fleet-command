-- HUD frame: drawHUDContents and the per-frame entry point DrawHUD.
local _shared = require "fs2rts_hud.common"
local RTS, objectValid = _shared.RTS, _shared.objectValid

local function drawHUDContents(self)
    if not self.Enabled then return end; local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
    local m=self:GetUIMetrics(sw,sh)
    -- New projection epoch. See BeginFrameProjection in input.lua: nothing can
    -- move a ship or the camera between this point and the end of the draw, so
    -- every projection taken below is as current as every other one, and
    -- nothing from a previous frame can be read as if it were.
    self:BeginFrameProjection()
    -- Every interactive rect table is rebuilt below, but several draw paths
    -- return early (cinematic, battle cam, free cam, post-battle, pilot mode).
    -- Clearing first means a frame that skipped the owning panel cannot leave
    -- clickable ghosts behind for HandleUILeftClick to act on.
    self.BuildButtonRects={}; self.BuildNavRects={}; self.ActionButtonRects={}
    self.FleetHistoryButtonRects={}; self.HumanityOpenRect=nil
    self.AutoBuildRequestRects={}; self.CancelAutoBuildRect=nil
    self.PolicyButtonRects={}; self.QuickGroupRects={}; self.PanelTabRects={}
    self.StationButtonRects={}
    self.FleetLifeButtonRects={}; self.EnvironmentButtonRects={}; self.SceneButtonRect=nil; self.ExitMenuButtonRect=nil
    self.ExitMenuButtonRects={}
    self.AftermathReportRect=nil
    self.SelectionRows={}; self.SelectionRowsShown=0; self.HoveredSelectionRow=nil
    self.TimeButtonRects={}; self.SetupButtonRects={}
    self.PostBattleButtonRects={}; self.MapButtonRects={}; self.AutoModeRect=nil
    self.FormationButtonRect=nil; self.MusicButtonRect=nil
    self.ControlsRect=nil
    self.AnnouncementRect=nil; self.StatusRect=nil
    self:RecycleMarkerPoints(self.EdgeMarkerPoints); self.EdgeMarkerPoints=nil
    self.TopLayerDraws=nil
    self:ResetDecorationGrid()
    if self.ExitMenuActive then self:DrawExitMenu(sw,sh); return end
    if self.CinematicActive then
        self:DrawCinematicOverlay(sw,sh)
        local tail=self.CinematicTailHold
        if tail then gr.setColor(0,0,0,math.floor(255*math.min(1,tail.time/math.max(.001,tail.duration)))); gr.drawRectangle(0,0,sw,sh,true) end
        return
    end
    if self.BattleCamActive then self:DrawBattleCamOverlay(sw,sh); return end
    if self.FreeCamActive then
        if self:UINow()<(self.FreeCamHintUntil or 0) then gr.setColor(150,175,185,220); self:DrawCenteredTextClipped("UI HIDDEN  //  "..(self.PossessedSignature~=nil and "" or "WASD / MOUSE TO FRAME SHOTS  //  ").."SHIFT+"..tostring((self.Config.HomeworldControls or {}).Cinematic or "C").." TO RETURN",m.margin,sw-m.margin,m.pad(20)) end
        return
    end
    if self.PostBattleActive then self:DrawWorldOverlays(); self:DrawTopBar(sw); self:DrawTacticalMap(sw); self:DrawPostBattleOverlay(sw,sh); return end
    if self.PossessedSignature~=nil then self:DrawLiveFleetCost(sw,sh); self:DrawPilotHullHUD(); self:DrawPilotObjectiveMarker(sw,sh); self:DrawPilotHUD(sw,sh); self:DrawFleetCitationNotice(sw,sh); return end
    if not self.SetupActive then self:RefreshSelectionListRects(sw,sh) end
    -- The tactical map is drawn with the world layer, BEFORE the panels and the
    -- transient text. It used to be redrawn after DrawAnnouncement when popped
    -- out, so a popped map (which is 75% opaque by default) covered the status
    -- message and the escalation announcement it was sitting on top of.
    self:DrawWorldOverlays()
    if not self.SetupActive then self:DrawStrikeWarnings() end
    self:DrawTopBar(sw)
    self:DrawTacticalMap(sw)
    if not self.SetupActive then self:DrawLiveFleetCost(sw,sh) end
    if self.SetupActive then
        self:DrawSetupOverlay(sw,sh); self:DrawCurrentHoverReadout(); self:DrawFleetLifeOverlay(sw,sh)
        local fade=math.max(0,(self.IntroFadeInUntil or 0)-self:UINow())
        if fade>0 then gr.setColor(0,0,0,math.floor(255*math.min(1,fade))); gr.drawRectangle(0,0,sw,sh,true) end
        return
    end
    self:DrawSelectedUnitStats(sw,sh); self:DrawSelectionPanel(sw,sh); self:DrawBuildPanel(sw,sh)
    if self.PanelTab~="station" and self.PanelTab~='history' then self:DrawQuickGroupsPanel(sw,sh); self:DrawOptionsPanel(sw,sh); self:DrawPolicyPanel(sw,sh) end
    self:DrawControls(sw,sh); self:DrawChaseBanner(sw)
    self:FlushTopLayer()
    if self.LeftDrag then local left=math.min(self.LeftDrag.x1,self.LeftDrag.x2); local right=math.max(self.LeftDrag.x1,self.LeftDrag.x2); local top=math.min(self.LeftDrag.y1,self.LeftDrag.y2); local bottom=math.max(self.LeftDrag.y1,self.LeftDrag.y2); gr.setColor(90,220,255,220); gr.drawRectangle(left,top,right,bottom,false) end
    if not self:DrawFleetCitationNotice(sw,sh) and self.StatusMessage and self:UINow()<=self.StatusUntil then
        local rect=self:GetNotificationRect(sw,sh,m.lineHeight+m.pad(16),'status')
        if rect then
            self.StatusRect=rect
            gr.setColor(4,10,18,235); gr.drawRectangle(rect.x1,rect.y1,rect.x2,rect.y2,true)
            gr.setColor(255,220,100,255)
            self:DrawCenteredTextClipped(self.StatusMessage,rect.x1+m.pad(8),rect.x2-m.pad(8),rect.y1+m.pad(8))
        end
    end
    self:DrawAnnouncement(sw,sh)
    self:DrawNewUnitPopup(sw,sh)
    self:DrawCurrentHoverReadout()
    -- Last, so a hover card cannot cover the F10 notice the player is told to use.
    self:DrawHintsNotice(sw,sh)
    self:DrawFleetLifeOverlay(sw,sh)
end

function RTS:DrawHUD()
    self.ButtonIconTooltip=nil
    local previous=gr.CurrentFont
    -- Render the retail eleven-pixel face directly, without scaling a texture
    -- of font01's nine-pixel glyphs. Native gauges retain their own fonts.
    local body=gr.Fonts and gr.Fonts[3]
    if objectValid(body) then gr.CurrentFont=body end
    local ok,message=pcall(function() drawHUDContents(self); self:DrawButtonIconTooltip() end)
    if previous then gr.CurrentFont=previous end
    assert(ok,message)
end
