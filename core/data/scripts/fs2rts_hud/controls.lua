-- HUD control legend.
local _shared = require "fs2rts_hud.common"
local RTS = _shared.RTS

-- Control legend. It used to bail out entirely when the band between the
-- selection panel and the options panel was under 160px wide, which is what
-- happened below about 1056px of screen width, and each of its four lines was
-- ~150 characters drawn into a ~400px box: the engine re-wrapped every line
-- into four overlapping rows. The band is now sized by the layout solve (so it
-- exists at every resolution) and the entries are wrapped to its measured
-- width, with as many lines as fit. The drawn band is published so the status
-- message can move out of its way.
-- The control legend's four lines. These are four long concatenations over the
-- key bindings, and the band is redrawn on every frame of every match, so the
-- table and roughly eight hundred characters of string garbage were produced
-- sixty times a second to say the same four things. Built once per distinct
-- set of bindings.
function RTS:GetControlLegendLines()
    local c=self.Config.HomeworldControls or {}
    local cached=self.ControlLegendLines
    if cached~=nil and self.ControlLegendKeys==c.SelectAll and self.ControlLegendStop==c.Stop
        and self.ControlLegendEngage==c.Engage and self.ControlLegendRelease==c.Release
        and self.ControlLegendMove==c.ArmMove and self.ControlLegendAttack==c.ArmAttack
        and self.ControlLegendFocus==c.Focus and self.ControlLegendWing1==c.Wing1
        and self.ControlLegendWing4==c.Wing4 and self.ControlLegendZoomFar==c.ZoomFar
        and self.ControlLegendZoomNear==c.ZoomNear and self.ControlLegendMute==c.MuteMusic
        and self.ControlLegendPolicyJ==c.HoldPolicy and self.ControlLegendPolicyZ==c.PassivePolicy
        and self.ControlLegendPolicyX==c.DefensivePolicy and self.ControlLegendPolicyV==c.AggressivePolicy
        then
        return cached
    end
    cached={
        "LMB select / drag  |  Shift add  |  Ctrl+LMB class  |  Double-click wing  |  "..(c.SelectAll or "L").." select all  |  "..(c.Chase or "B").." chase",
        "RMB order  |  RMB DRAG from empty space = move + facing  |  "..(c.ArmMove or "M").." move, "..(c.ArmAttack or "K").." attack  |  "..(c.Stop or "R").." hold  |  "..(c.Engage or "T").." engage  |  "..(c.Release or "G").." release",
        -- Alt selects the absolute speed ladder; plain digits own groups.
        "1-4 recall group | Shift+1-4 assign | Alt+1/2/3/4/0 = 1x/2x/4x/8x/16x speed | = / - step | Space pause | Esc exit menu | "..(c.HoldPolicy or "J").."/"..(c.PassivePolicy or "Z").."/"..(c.DefensivePolicy or "X").."/"..(c.AggressivePolicy or "V").." policy",
        "WASD pan | MMB pan | RMB drag orbit | Wheel zoom | "..(c.ZoomFar or "Q").."/"..(c.ZoomNear or "E").." zoom | "..(c.Focus or "F").." focus | "..(c.FocusBase or "H").." home | "..(c.MuteMusic or "N").." music | "..(c.Cinematic or "C").." cinematic | "..(self.Config.FleetCostToggleKey or 'F9').." crew estimates | "..(self.Config.HotkeyHintsKey or 'F10').." hints",
    }
    self.ControlLegendLines=cached
    self.ControlLegendKeys=c.SelectAll; self.ControlLegendStop=c.Stop
    self.ControlLegendEngage=c.Engage; self.ControlLegendRelease=c.Release
    self.ControlLegendMove=c.ArmMove; self.ControlLegendAttack=c.ArmAttack
    self.ControlLegendFocus=c.Focus; self.ControlLegendWing1=c.Wing1
    self.ControlLegendWing4=c.Wing4; self.ControlLegendZoomFar=c.ZoomFar
    self.ControlLegendZoomNear=c.ZoomNear; self.ControlLegendMute=c.MuteMusic
    self.ControlLegendPolicyJ=c.HoldPolicy; self.ControlLegendPolicyZ=c.PassivePolicy
    self.ControlLegendPolicyX=c.DefensivePolicy; self.ControlLegendPolicyV=c.AggressivePolicy
    return cached
end

function RTS:DrawControls(sw,sh)
    if self.ShowHotkeyHints==false then self.ControlsRect=nil; return end
    local m=self:GetUIMetrics(sw,sh); local lh=m.lineHeight
    local lines=self:GetControlLegendLines()
    self.ControlsRect=nil
    local selection=self:GetSelectionPanelRect(sw,sh); local options=self:GetOptionsPanelRect(sw,sh)
    local x1=selection.x2+m.gap; local x2=options.x1-m.gap
    local y2=m.sh-m.margin-m.lineHeight-m.pad(8)
    local availableW=x2-x1-m.pad(16)
    if availableW<200 then return end
    -- The band shares its column with the selection panel, so its height is
    -- bounded by that panel rather than by the screen.
    local maxH=math.max(3*lh,selection.y2-selection.y1)
    local maxLines=math.max(1,math.floor((maxH-2*m.pad(6))/lh))
    local drawn={}
    for _,line in ipairs(lines) do
        if #drawn>=maxLines then break end
        for _,piece in ipairs(self:WrapTextLinesToWidth(line,availableW,maxLines-#drawn+1)) do
            if #drawn>=maxLines then break end
            drawn[#drawn+1]=piece
        end
    end
    if #drawn==0 then return end
    local y1=y2-#drawn*lh-2*m.pad(6)
    gr.setColor(4,10,18,210); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(155,200,215,255)
    for i,line in ipairs(drawn) do self:DrawCenteredText(line,x1+m.pad(8),x2-m.pad(8),y1+m.pad(6)+(i-1)*lh) end
    self.ControlsRect={x1=x1,y1=y1,x2=x2,y2=y2}
end
