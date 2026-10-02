"""HUD layout regression checks: the RTS HUD has to lay out at every resolution.

Run: python core/tools/test_hud_layout.py   (or: python -m pytest test_hud_layout.py)

These drive the real shipped Lua through the same engine doubles test_station.py
installs, at a range of screen sizes from 1280x720 to 3840x2160. They are about
GEOMETRY, not pixels: every assertion is on a rectangle the HUD published for
hit-testing, or on the draw-call order and positions the layout produced.

The bug class these pin is specific. The HUD used to hard-code every rectangle
in pixels against a 1920x1080 design, and the right-hand column was a fixed
stack about 864px tall, which is more than a 720p screen has. The production
panel was therefore squeezed to 32px, its row loop's guard was already false on
the first iteration, and it drew no build rows at all; below about 1474px the
top bar's note field got a right edge behind its own left edge; and below about
1056px the control legend was skipped outright. None of that raised an error -
it just quietly drew the wrong thing.
"""
import unittest

from lupa.lua51 import LuaRuntime
from test_station import SETUP, SCRIPTS

# Every size the user cares about, plus the two legacy small ones.
RESOLUTIONS = [(1280, 720), (1366, 768), (1600, 900), (1920, 1080),
               (2560, 1440), (3440, 1440), (3840, 2160)]

EXTRA = r'''
-- ---- doubles installed after the mod loads, as test_feature_request.py does -
-- Captured BEFORE anything below is overridden, so the hit-region test can
-- exercise the shipped IsPointOnRTSUI rather than a stub.
REAL_IS_POINT_ON_RTS_UI = r.IsPointOnRTSUI
io=io or {}
controls=controls or {}
io.getMouseX=io.getMouseX or function() return 100 end
io.getMouseY=io.getMouseY or function() return 100 end
io.setCursorHidden=io.getCursorHidden or function() end
ba.postGameEvent=ba.postGameEvent or function() end
ba.setButtonControlMode=ba.setButtonControlMode or function() end
bit=bit or {checkBit=function() return false end}

-- Draw-call recorder. Every geometry assertion below reads these, because a
-- rect table the HUD forgot to publish would not show up in a hit test.
drawLog={}
function resetDraws() drawLog={strings={},rects={},lines={},order={}} end
resetDraws()

-- A proportional-font double: FSO's default UI face is font01.vf, and
-- gr_get_font_height is 16 for it, so a glyph is 6x9 on average and NOT 8
-- pixels wide. Anything that budgets 8 pixels per character is now wrong, and
-- this double is what makes that visible.
FONT_W=6
function setScreen(w,h) SCREEN_W=w; SCREEN_H=h end
SCREEN_W=1920; SCREEN_H=1080

gr={setCamera=function() end,
  getScreenWidth=function() return SCREEN_W end,
  getScreenHeight=function() return SCREEN_H end,
  setColor=function() end,
  getStringWidth=function(text) return #tostring(text)*FONT_W end,
  drawRectangle=function(x1,y1,x2,y2,filled)
    drawLog.rects[#drawLog.rects+1]={x1=x1,y1=y1,x2=x2,y2=y2}
    drawLog.order[#drawLog.order+1]='rect' end,
  drawString=function(text,x1,y1,x2,y2)
    drawLog.strings[#drawLog.strings+1]={text=tostring(text),x1=x1,y1=y1,x2=x2,y2=y2}
    drawLog.order[#drawLog.order+1]='string' end,
  drawLine=function(x1,y1,x2,y2) drawLog.order[#drawLog.order+1]='line' end,
  drawCircle=function() end,drawRectangleCentered=function() end,drawImage=function() end,
  drawTargetingBrackets=function() return nil end,
  setTarget=function() end,clearScreen=function() end,createTexture=function() return false end}

r.Camera={Position=ba.createVector(0,0,0),Orientation={
  getFvec=function() return ba.createVector(0,0,1) end,
  getRvec=function() return ba.createVector(1,0,0) end,
  copy=function() return {} end},FOV=0.9}
r.CameraFocus=ba.createVector(0,0,0)
r.Enabled=true; r.SetupActive=false; r.Paused=false; r.PostBattleActive=false
r.CinematicActive=false; r.BattleCamActive=false; r.FreeCamActive=false
r.PossessedSignature=nil; r.FollowSignature=nil
r.UIClock=0; r.UINow=function(self) return self.UIClock end
r.SetStatus=function() end
function r:IsPointOnRTSUI() return false end
function r:IsPointOnTacticalMap() return false end
function r:GetShipAtScreen() return nil end
function r:ScreenToPlane(x,y) return ba.createVector(x,0,y) end
function r:DrawShipModelThumb() return false end
function r:GetBriefingIcon() return nil end

-- A small but real build catalogue: without one the row loop is never reached
-- and every "did it draw rows" assertion would pass vacuously.
r.BuildCatalog={}
for i=1,9 do
  r.BuildCatalog[i]={class='GTF Build '..i,role=(i<=3 and 'fighter' or (i<=6 and 'bomber' or 'escort')),
    tier=1,label='Build '..i,cost=100,time=60,count=1}
end
r.BuildRoleFilter='all'; r.BuildPage=1
r.CommandPoints=5000
r.PanelTab='production'
r.GetCarrier=function() return stations.BLUE end
r.IsBuildOptionUnlocked=function() return true end
r.GetProductionQueueStatus=function() return nil end
r.AutoPlayerMode=false
r.ArmedCommand=nil
r.GlobalPolicy='HOLD'
r.GetSelectionPanelRect=r.GetSelectionPanelRect
r.Selected={}function r:GetSelectedShips() return self.testSelection or {} end
function r:GetSelectedFriendlyShips() return {} end
function r:GetControlGroupCount() return 0 end
r.Formations={{id='wedge',label='Wedge',desc='Tight wedge'}}
r.SelectedFormation='wedge'
function r:GetFormationTypes() return self.Formations end
function r:GetSelectedFormation() return 'wedge' end
r.MusicMuted=false
r.MapView=nil
'''


def boot():
    """Load the shipped Lua into a fresh runtime, as the other suites do."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
    lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
    lua.execute(SETUP)
    lua.execute(EXTRA)
    return lua


def resolutions_lua():
    return "RES={" + ",".join("{%d,%d}" % r for r in RESOLUTIONS) + "}"


class HudLayoutTests(unittest.TestCase):
    def setUp(self):
        self.lua = boot()
        self.check(resolutions_lua())

    def check(self, code):
        self.lua.execute(code)

    # -- defect 1: the production panel drew zero build rows at 768p ---------
    def test_build_panel_draws_at_least_one_row_at_every_resolution(self):
        """The row count and the loop that draws the rows used to come from two
        different sets of constants - (height-142)/50 for the page size and
        y+44 > y2-74 for the loop - which disagreed by a row. At 720p and 768p
        the panel itself was squeezed to 32/80px, the guard was false on the
        first iteration, and no build row was drawn at all. One count, used by
        both, cannot drift apart again."""
        self.check("""for _,res in ipairs(RES) do
          local w,h=res[1],res[2]
          setScreen(w,h); r.UIMetrics=nil; r.MapView=nil
          r.BuildButtonRects={}
          r:DrawBuildPanel(w,h)
          local count=0
          for _,rect in pairs(r.BuildButtonRects or {}) do count=count+1 end
          assert(count>0,'no build row was drawn at '..w..'x'..h)
          local panel=r:GetProductionPanelRect(w,h)
          local m=r:GetUIMetrics(w,h)
          for _,rect in pairs(r.BuildButtonRects) do
            assert(rect.y1>=panel.y1 and rect.y2<=panel.y2,
              'build row escapes the panel at '..w..'x'..h..': '..rect.y1..'..'..rect.y2)
            assert(rect.y2<=panel.y2-m.buildFooter,
              'build row '..rect.y1..' overlaps the footer band at '..w..'x'..h)
            assert(rect.x1>=panel.x1 and rect.x2<=panel.x2,
              'build row escapes the panel horizontally at '..w..'x'..h)
          end
          -- The page size and the rows actually drawn have to agree.
          assert(count<=r.BuildRowsPerPage,
            'the panel reported '..r.BuildRowsPerPage..' rows per page but drew '..count
              ..' at '..w..'x'..h)
        end""")

    def test_build_rows_increase_with_the_screen(self):
        """The point of scaling is that a bigger screen gets a bigger HUD, not
        the same postage stamp in the corner: the production panel is pinned to
        its 1920x1080 height on every display, so 4K showed exactly what 1080p
        did. Assert the capacity is monotone in screen height."""
        self.check("""local first=nil
          for _,res in ipairs(RES) do
            local w,h=res[1],res[2]
            setScreen(w,h); r.UIMetrics=nil
            local rows=r:CountBuildRows(w,h)
            if first==nil then first=rows end
            assert(rows>=first,'a taller screen lost build capacity: '
              ..h..'p fits '..rows..' rows, '..first..' were expected')
            first=rows
          end""")

    # -- the column has to fit at all -----------------------------------------
    def test_right_hand_column_panels_are_ordered_and_never_overlap(self):
        """The column is production | quick | options | policy under the
        docked map. It is solved from the bottom up now, so on a short screen
        the map and then the quick-group strip give up height. Whatever is left
        has to be on screen and in order, or panels draw over each other."""
        self.check("""for _,res in ipairs(RES) do
          local w,h=res[1],res[2]
          setScreen(w,h); r.UIMetrics=nil; r.PanelTab='production'
          local m=r:GetUIMetrics(w,h)
          local map=r:GetDockedMapRect(); local prod=r:GetProductionPanelRect(w,h)
          local quick=r:GetQuickGroupPanelRect(w,h); local opt=r:GetOptionsPanelRect(w,h)
          local pol=r:GetPolicyPanelRect(w,h)
          local at=w..'x'..h
          assert(map.y1>=m.topBarHeight,'the map is drawn under the top bar at '..at)
          assert(map.y2<=prod.y1,'map/production overlap at '..at)
          assert(prod.y2<=quick.y1,'production/quick overlap at '..at)
          assert(quick.y2<=opt.y1,'quick/options overlap at '..at)
          assert(opt.y2<=pol.y1,'options/policy overlap at '..at)
          assert(pol.y2<=h,'the policy panel runs off the bottom at '..at)
          assert(prod.x1>=m.selectionWidth+2*m.margin,'the right column runs into the selection panel at '..at)
          assert(map.x1>=0 and map.x2<=w,'the map runs off the side at '..at)
          assert(prod.y2-prod.y1>=m.buildMinHeight,
            'the production panel is shorter than one row needs at '..at)
        end""")

    def test_hud_uses_more_of_a_large_screen(self):
        """A 4K player should not get the 1920x1080 layout. Assert the panels
        actually grow, so a future change cannot quietly pin the metrics back to
        the design size and pass every other test here."""
        self.check("""local function area(w,h)
          setScreen(w,h); r.UIMetrics=nil
          local m=r:GetUIMetrics(w,h)
          local prod=r:GetProductionPanelRect(w,h); local sel=r:GetSelectionPanelRect(w,h)
          return (prod.x2-prod.x1)*(prod.y2-prod.y1)+(sel.x2-sel.x1)*(sel.y2-sel.y1), m
        end
        local small,ms=area(1920,1080)
        local large,ml=area(3840,2160)
        assert(large>small*2,'the HUD did not grow for a 4K screen: '
          ..tostring(large)..' vs '..tostring(small)..' pixels of panel')
        assert(ml.scale>ms.scale,'the layout scale did not grow: '..tostring(ml.scale))
        -- And it is capped: an unbounded scale would make a 8K HUD unusable.
        assert(ml.scale<=1.75,'the layout scale is uncapped at '..tostring(ml.scale))""")

    # -- defect 2: hard-coded top bar x positions -----------------------------
    def test_top_bar_text_stays_inside_the_bar_at_every_resolution(self):
        """The top bar placed its fields at literal x = 14/170/300/450/610/770
        and right-aligned the rest against sw-700 and sw-440. Below about
        1474px the note's right edge (sw-704) landed behind its own left edge
        (770), which gr.drawString only warns about once, and the tier readout
        was drawn over the policy field. Every string is now placed by measured
        width and dropped if it does not fit."""
        self.check("""for _,res in ipairs(RES) do
          local w,h=res[1],res[2]
          setScreen(w,h); r.UIMetrics=nil; r.UIClock=1; r.TopBarCounters=nil
          r:DrawTopBar(w)
          local m=r:GetUIMetrics(w,h)
          local bar=0
          for _,s in ipairs(drawLog.strings) do
            if s.y1<m.topBarHeight then
              bar=bar+1
              assert(s.x1>=0 and s.x1<=w,
                'top bar text at x='..tostring(s.x1)..' is off the '..w..'px screen')
              assert(s.y1>=0 and s.y1<m.topBarHeight,
                'top bar text "'..s.text..'" is drawn below the bar at '..w..'x'..h)
            end
          end
          assert(bar>0,'the top bar drew no text at '..w..'x'..h)
          -- The speed buttons own the right end of the bar and must be inside
          -- it, at every width, or they cannot be clicked.
          local count=0
          for _,rect in pairs(r.TimeButtonRects) do
            count=count+1
            assert(rect.x1>=0 and rect.x2<=w,
              'a time-scale button escapes the screen at '..w..'x'..h)
            assert(rect.y2<=m.topBarHeight,'a time-scale button escapes the bar at '..w..'x'..h)
          end
          assert(count==7,'the top bar lost its time-scale buttons at '..w..'x'..h)
        end""")

    def test_top_bar_fields_do_not_collide_with_each_other(self):
        """Fields are placed left to right in measured order, so their boxes
        cannot overlap at any width."""
        self.check("""for _,res in ipairs(RES) do
          local w,h=res[1],res[2]
          setScreen(w,h); r.UIMetrics=nil; r.UIClock=1; r.TopBarCounters=nil
          resetDraws(); r:DrawTopBar(w)
          local m=r:GetUIMetrics(w,h)
          local fields={}
          for _,s in ipairs(drawLog.strings) do
            if s.y1<m.topBarHeight then
              fields[#fields+1]={x=s.x1,right=s.x1+r:TextWidth(s.text),text=s.text}
            end
          end
          table.sort(fields,function(a,b) return a.x<b.x end)
          for i=2,#fields do
            assert(fields[i].x>=fields[i-1].right,
              'top bar fields "'..fields[i-1].text..'" and "'..fields[i].text
                ..'" overlap at '..w..'x'..h)
          end
        end""")

    # -- defect 3: the legend vanished below ~1056px ---------------------------
    def test_control_legend_is_drawn_at_every_resolution(self):
        """DrawControls returned early when the band between the selection panel
        and the options panel was under 160px wide, which is what happened
        below about 1056px of screen width, so the whole control legend silently
        disappeared. The band is now sized by the layout solve."""
        self.check("""for _,res in ipairs(RES) do
          local w,h=res[1],res[2]
          setScreen(w,h); r.UIMetrics=nil
          r:DrawControls(w,h)
          local at=w..'x'..h
          assert(r.ControlsRect~=nil,'the control legend was not drawn at '..at)
          local c=r.ControlsRect
          assert(c.x1>=0 and c.x2<=w,'the legend runs off the side at '..at)
          assert(c.y1>=0 and c.y2<=h,'the legend runs off the bottom at '..at)
          local sel=r:GetSelectionPanelRect(w,h); local opt=r:GetOptionsPanelRect(w,h)
          assert(c.x1>sel.x2,'the legend is drawn on top of the selection panel at '..at)
          assert(c.x2<opt.x1,'the legend is drawn on top of the options panel at '..at)
        end""")

    def test_status_message_is_kept_clear_of_the_control_legend(self):
        """The status message sat at a fixed sh-140 and the legend was drawn
        straight through it. The legend now publishes the box it used."""
        self.check("""local w,h=1920,1080
        setScreen(w,h); r.UIMetrics=nil
        r:DrawControls(w,h)
        local legend=r.ControlsRect
        assert(legend~=nil,'fixture: the legend drew nothing')
        r.StatusMessage='status'; r.StatusUntil=r.UIClock+10
        resetDraws()
        r:DrawHUD()
        local band={}
        for _,s in ipairs(drawLog.strings) do
          if s.text=='status' then band={x1=s.x1,y1=s.y1} end
        end
        assert(band.x1~=nil,'the status message was not drawn')
        local overlaps = band.y1 < legend.y2 and band.y1 > legend.y1-1
        assert(not overlaps,'the status message at y='..tostring(band.y1)
          ..' sits inside the control legend, which spans '..legend.y1..'..'..legend.y2)""")

    # -- defect 4: the map was drawn last, over the text ----------------------
    def test_popped_tactical_map_is_drawn_before_the_status_and_announcement(self):
        """A popped-out map is 75% opaque by default and used to be redrawn
        AFTER DrawAnnouncement, so it covered the escalation announcement and
        the status message sitting underneath it. The map's own chrome label is
        a unique string, so its position in the call order is unambiguous."""
        self.check("""local w,h=1920,1080
        setScreen(w,h); r.UIMetrics=nil; r.MapView=nil
        r:GetMapView().popped=true
        r.StatusMessage='status'; r.StatusUntil=r.UIClock+10
        r.AnnouncementText='TIER UNLOCKED'; r.AnnouncementUntil=r:UINow()+10
        r.AnnouncementFaction='BLUE'
        r.PanelTab='production'
        r.Selected={}
        resetDraws(); r:DrawHUD()
        local chromeAt,statusAt,announceAt
        for i,s in ipairs(drawLog.strings) do
          if s.text=='x1.0' then chromeAt=i end
          if s.text=='status' then statusAt=i end
          if s.text=='TIER UNLOCKED' then announceAt=i end
        end
        assert(chromeAt~=nil,'fixture: the tactical map drew no chrome at all')
        assert(statusAt~=nil,'fixture: the status message was not drawn')
        assert(announceAt~=nil,'fixture: the announcement was not drawn')
        assert(chromeAt<statusAt,
          'the popped tactical map was drawn AFTER the status message, so it covers it')
        assert(chromeAt<announceAt,
          'the popped tactical map was drawn AFTER the announcement, so it covers it')""")

    # -- defect 13: the selection legend at 8px per character -----------------
    def test_selection_panel_legend_and_rows_stay_inside_the_pane(self):
        """The colour legend advanced x by (#label * 8) pixels - eight pixels per
        CHARACTER - which is not the width of a glyph in FSO's proportional
        font, so the legend ran past the pane edge. It is measured now."""
        self.check("""for _,res in ipairs(RES) do
          local w,h=res[1],res[2]
          setScreen(w,h); r.UIMetrics=nil
          local s=ship('legend probe',class('GTF Ares'),ba.createVector(0,0,0),mn.Teams.friendly)
          s.role='fighter'
          r.testSelection={s}
          r:RefreshSelectionListRects(w,h)
          resetDraws()
          r:DrawSelectionPanel(w,h)
          local rect=r:GetSelectionPanelRect(w,h)
          local at=w..'x'..h
          assert(r.LegendBottomY<=rect.y2,'the legend runs past the selection panel at '..at)
          assert(r.LegendBottomY>=rect.y1,'the legend is drawn above the panel at '..at)
          -- Every legend chip has to sit inside the pane. Advancing x by eight
          -- pixels per CHARACTER put the last chip outside it.
          -- The colour legend only, matched by label: the selection row below
          -- it is drawn inside the same y band.
          local legendLabels={['YOUR ORDER']=true,['POLICY']=true,['AUTO']=true,['PILOT']=true,['SENTRY']=true}
          local chips={}
          for _,t in ipairs(drawLog.strings) do
            if legendLabels[t.text] then chips[#chips+1]=t end
          end
          assert(#chips==5,'only '..#chips..' of the 5 legend chips were drawn at '..at)
          for _,t in ipairs(chips) do
            assert(t.x1>=rect.x1 and t.x1<=rect.x2,
              'legend chip "'..t.text..'" starts at x='..tostring(t.x1)
                ..', outside the pane '..rect.x1..'..'..rect.x2..' at '..at)
            assert(t.x1+r:TextWidth(t.text)<=rect.x2,
              'legend chip "'..t.text..'" ends at x='..tostring(t.x1+r:TextWidth(t.text))
                ..', past the pane edge '..rect.x2..' at '..at)
          end
          -- Chips on the same line advance by the MEASURED width of the chip
          -- before them plus a fixed gap. A character budget of eight pixels
          -- per glyph is the wrong advance for a proportional font: it either
          -- overruns the pane or wraps the legend early.
          local m=r:GetUIMetrics(w,h)
          for i=2,#chips do
            local previous=chips[i-1]
            if chips[i].y1==previous.y1 then
              local gap=chips[i].x1-(previous.x1+r:TextWidth(previous.text))
              assert(gap==m.pad(10),
                'legend chips "'..previous.text..'" and "'..chips[i].text..'" are '
                  ..gap..'px apart, not the measured '..m.pad(10)..'px, at '..at)
            end
          end
          for _,row in ipairs(r.SelectionRows or {}) do
            if row.rect then
              assert(row.rect.y1>=rect.y1 and row.rect.y2<=rect.y2,
                'a selection row ('..row.rect.y1..'..'..row.rect.y2..') escapes the panel '
                  ..rect.y1..'..'..rect.y2..' at '..at)
            end
          end
          r.testSelection={}
        end""")

    # -- defect 7: character-based truncation ---------------------------------
    def test_truncation_is_measured_in_pixels_not_characters(self):
        """truncate() counted characters. FSO's default face is proportional
        (font01.vf, gr_get_font_height 16), so a character budget both cut long
        labels short and let wide ones overflow their pane. Truncation is now
        to a pixel budget, measured with the engine's own getStringWidth."""
        self.check("""FONT_W=6
        local text='GTF ULYSSES HEAVY CRUISER'
        local short=r:TruncateToWidth(text,60)
        assert(r:TextWidth(short)<=60,'truncation produced '..r:TextWidth(short)
          ..'px inside a 60px budget: '..short)
        -- And it must not throw away more than it had to: a character budget of
        -- 60/8 = 7 characters is what the old helper did, and at 6px per glyph
        -- that leaves a third of the budget unused.
        assert(r:TextWidth(short)>60-FONT_W,'truncation discarded a whole glyph or more: '
          ..r:TextWidth(short)..'px of a 60px budget')
        assert(r:TruncateToWidth(text,10000)==text,'a budget wider than the text changed it')
        assert(r:TruncateToWidth(text,0)=='','a zero budget produced text')""")

    def test_text_is_not_wrapped_by_the_engine_twice(self):
        """gr.drawString's five-argument form makes the ENGINE re-wrap and clip
        the string (graphics.cpp:1467 str_wrap_to_width, resized to
        (y2-y)/font_height); the three-argument form hands it straight to
        gr_string (graphics.cpp:1434). DrawTextLine is the three-argument form,
        so a label that has already been wrapped here is drawn as one line."""
        self.check("""local w,h=1920,1080
        setScreen(w,h); r.UIMetrics=nil
        resetDraws()
        r:DrawTextLine('a long label that would be re-wrapped by the engine',100,200,400)
        assert(#drawLog.strings==1,'DrawTextLine produced '..#drawLog.strings..' draw calls')
        local s=drawLog.strings[1]
        assert(s.x1==100 and s.y1==200,'DrawTextLine moved the string: '..tostring(s.x1)..','..tostring(s.y1))
        assert(s.x2==nil,'DrawTextLine used the textbox form, which re-wraps in the engine')
        assert(r:TextWidth(s.text)<=400,'the drawn string is wider than its budget')""")

    # -- defect 8: button labels re-wrapped every frame -----------------------
    def test_wrapping_is_memoised(self):
        """The HUD re-wrapped the same button labels every frame. Wrapping is
        pure, so the result is cached; a cache that missed would hand back a
        fresh table each call and this identity check fails."""
        self.check("""local a=r:WrapTextLines('ATTACK (K) SELECTED TARGET RETICLE',12,3)
          local b=r:WrapTextLines('ATTACK (K) SELECTED TARGET RETICLE',12,3)
          assert(a==b,'the same wrap request rebuilt its lines instead of reusing them')
          assert(#a==3,'the fixture did not actually wrap to three lines')
          local c=r:WrapTextLines('ATTACK (K) SELECTED TARGET RETICLE',40,3)
          assert(c~=a,'a different budget returned the cached result for another one')""")

    # -- defect 5: off-screen contacts ----------------------------------------
    def test_off_screen_contacts_spread_along_the_border(self):
        """Contacts were pinned to the exact border pixel of their bearing, so a
        group of contacts to the north collapsed into one unreadable glyph.
        Markers are now de-overlapped."""
        self.check("""local w,h=1920,1080
        setScreen(w,h); r.UIMetrics=nil
        r.EdgeMarkerPoints={}
        local points={}
        for i=1,8 do
          local s=ship('astern '..i,class('SF Mara'),ba.createVector(9000,0,-9000+i*3),mn.Teams.hostile)
          s.role='fighter'
          local x,y=r:ResolveEdgeMarkerPoint(0.001*i,1,w,h,26,r:GetUIMetrics(w,h))
          points[#points+1]={x=x,y=y}
        end
        local distinct=0
        for i=1,#points do
          local unique=true
          for j=1,i-1 do
            if math.abs(points[i].x-points[j].x)<2 and math.abs(points[i].y-points[j].y)<2 then unique=false end
          end
          if unique then distinct=distinct+1 end
        end
        assert(distinct>1,'eight contacts at almost the same bearing produced '
          ..distinct..' distinct marker position(s): they are all stacked on one pixel')""")

    def test_a_contact_behind_the_camera_still_gets_a_border_marker(self):
        """getScreenCoords returns false on a projection overflow
        (code/scripting/api/objs/vecmath.cpp, the PF_OVERFLOW branch), which is
        what a contact astern produces. DrawWorldOverlays used to return before
        reaching the edge marker, so a threat behind the player was invisible."""
        self.check("""local w,h=1920,1080
        setScreen(w,h); r.UIMetrics=nil; r.EachShip=function(self,fn) end
        r.EdgeMarkerPoints={}
        local s=ship('astern',class('SF Mara'),ba.createVector(0,0,0),mn.Teams.hostile)
        s.role='fighter'
        -- A contact astern of the camera, and an engine that reports a
        -- projection overflow rather than a mirrored coordinate.
        s.Position={x=0,y=0,z=-5000,getScreenCoords=function() return false end}
        resetDraws()
        r:DrawEdgeContactMarker(s,false,false,{255,0,0},w,h)
        assert(#r.EdgeMarkerPoints>0,'a contact whose projection overflowed drew no border marker')
        local drawn=0
        for _,k in ipairs(drawLog.order) do if k=='rect' or k=='line' then drawn=drawn+1 end end
        assert(drawn>0,'the behind-camera marker placed a point but drew nothing')""")

    def test_an_on_screen_contact_is_not_pinned_to_the_border(self):
        """The opposite guard: a contact whose projection landed on screen is
        not an off-screen contact and must not be given a border marker."""
        self.check("""local w,h=1920,1080
        setScreen(w,h); r.UIMetrics=nil; r.EdgeMarkerPoints={}
        local s=ship('on screen',class('SF Mara'),ba.createVector(0,0,0),mn.Teams.hostile)
        s.role='fighter'
        resetDraws()
        r:DrawEdgeContactMarker(s,960,540,{255,0,0},w,h)
        assert(#r.EdgeMarkerPoints==0,'a contact at the centre of the screen was pinned to the border')""")

    # -- defect 6: decoration with no culling ---------------------------------
    def test_hull_bar_and_role_marker_are_culled_for_overlapping_contacts(self):
        """Every ship got a bracket, a hull bar and a role marker on every frame.
        The reticle is still drawn for every contact, but the decoration is
        dropped where it would land on one already drawn, because two sets of
        glyphs on the same pixels are both unreadable."""
        self.check("""r.DecoratedReticles={}
        assert(r:ShouldDecorateReticle(500,500,20,false),'the first contact was not decorated')
        assert(not r:ShouldDecorateReticle(502,502,20,false),
          'a contact on top of a decorated one was decorated again')
        assert(r:ShouldDecorateReticle(500,500,20,true),
          'a selected contact was culled by the overlap rule')
        assert(r:ShouldDecorateReticle(900,500,20,false),
          'a contact well clear of the others was culled')""")

    # -- defect 9: two full ship scans per frame for three integers -----------
    def test_top_bar_counters_are_sampled_on_a_timer(self):
        """CountFriendlyCombatants and CountHostiles each walk the whole ship
        list, so the top bar was doing two full EachShip passes every frame to
        print three numbers. They are sampled now."""
        self.check("""local w,h=1920,1080
        setScreen(w,h); r.UIMetrics=nil
        local scans=0
        r.EachShip=function(self,fn) scans=scans+1 end
        r.TopBarCounters=nil; r.UIClock=0
        r:DrawTopBar(w)
        local after=s
        local first=scans
        assert(first>0,'the counters were never sampled at all; the fixture would be vacuous')
        r.UIClock=0.05
        r:DrawTopBar(w)
        r.UIClock=0.10
        r:DrawTopBar(w)
        assert(scans==first,'the top bar rescanned the ship list '..(scans-first)
          ..' extra times within the sample interval')
        r.UIClock=10
        r:DrawTopBar(w)
        assert(scans>first,'the counters were never refreshed, so they would freeze')
        r.EachShip=nil""")

    # -- hit regions must match what is drawn ---------------------------------
    def test_top_of_screen_click_band_follows_the_top_bar(self):
        """IsPointOnRTSUI hard-coded 0..44 for the top bar while the bar itself
        is drawn to the measured height, so on a large screen the strip below
        the bar was treated as UI and swallowed world clicks."""
        self.check("""local real=REAL_IS_POINT_ON_RTS_UI
        r.IsPointOnRTSUI=real
        r.IsPointOnTacticalMap=function() return false end
        for _,res in ipairs(RES) do
          local w,h=res[1],res[2]
          setScreen(w,h); r.UIMetrics=nil
          local m=r:GetUIMetrics(w,h)
          assert(r:IsPointOnRTSUI(5,m.topBarHeight-1),
            'the top bar band is not treated as UI at '..w..'x'..h)
          assert(not r:IsPointOnRTSUI(5,m.topBarHeight+1),
            'the world below the top bar is being swallowed at '..w..'x'..h)
        end""")

    def test_station_panel_still_fits_its_band_at_every_resolution(self):
        """The station tab is laid out in fs2rts_station.lua's own fixed pixels,
        so the production panel has to keep handing it the band it needs at
        every resolution. This is the same property
        test_station_panel_controls_fit_at_both_resolutions checks at two sizes;
        this one sweeps the full range including 4K."""
        self.check("""for _,res in ipairs(RES) do
          local w,h=res[1],res[2]
          setScreen(w,h); r.UIMetrics=nil; r.MapView=nil
          r.PanelTab='station'
          r.DrawButton=function() end
          r.StationButtonRects=nil
          local panel=r:GetProductionPanelRect(w,h)
          r:DrawStationPanel(panel.x1+10,panel.y1+36,panel.x2-10,panel.y2-76)
          local count=0
          for _,rect in pairs(r.StationButtonRects or {}) do
            count=count+1
            assert(rect.y1>=panel.y1+36 and rect.y2<=panel.y2-76,
              'a station control overlaps the footer at '..w..'x'..h)
            assert(rect.x1>=panel.x1 and rect.x2<=panel.x2,
              'a station control escapes the panel horizontally at '..w..'x'..h)
          end
          assert(count>0,'DrawStationPanel produced no controls at '..w..'x'..h
            ..' - the fit assertions would be vacuous')
        end""")
