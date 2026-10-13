"""Regression checks for the 17 requested changes: keybinds, auto-mode gating,
formations, reticles, cinematic shot switching, capital rules and battle report.

Run: python core/tools/test_feature_request.py
Engine objects come from test_station's doubles; this does not replace an FSO run.
"""
import unittest

from lupa.lua51 import LuaRuntime
from test_station import SETUP, SCRIPTS
from script_modules import module_text

EXTRA = r'''
-- ---- engine and per-suite doubles, installed after the mod loads ----------
io=io or {}
-- FSO always defines a controls table; harnesses that call OnKeyPressed must
-- provide it, because the hook reads controls.Pause at the top of the function.
controls=controls or {}
io.getMouseX=io.getMouseX or function() return 100 end
io.getMouseY=io.getMouseY or function() return 100 end
io.setCursorHidden=io.setCursorHidden or function() end
ba.postGameEvent=ba.postGameEvent or function() end
ba.setButtonControlMode=ba.setButtonControlMode or function() end
gr={setCamera=function() end,getScreenWidth=function() return 1920 end,getScreenHeight=function() return 1080 end,
  loadTexture=function() return {isValid=function() return true end,getWidth=function() return 128 end,getHeight=function() return 128 end} end,
  setColor=function() end,drawRectangle=function() end,drawLine=function() end,drawCircle=function() end,
  drawString=function() end,drawRectangleCentered=function() end,drawImage=function() end,
  drawTargetingBrackets=function() return nil end,
  getStringWidth=function() return 40 end,setTarget=function() end,getMouseX=function() return 0 end}
ad={pauseMusic=function(handle,paused) musicCalls[#musicCalls+1]={handle=handle,paused=paused} end}
musicCalls={}
bit=bit or {checkBit=function() return false end}
-- The shared SETUP double's getOrientation() returns a bare table, which the
-- cinematic tail-hold code cannot copy(). The engine returns a real vec.
do
  local mt=getmetatable(ba.createVector(0,0,0))
  mt.getOrientation=function() return ba.createVector(0,0,1) end
  mt.copy=function(v) return ba.createVector(v.x,v.y,v.z) end
end

-- FSO does NOT define a shipValid scripting global. The AI modules get their
-- validity helper from fs2rts_ai_util as a file-local `valid`. Deliberately not
-- shimmed here: a module that calls an undefined global would otherwise pass
-- these tests and abort the engine with an uncatchable C++ exception.
r.FollowSignature=nil; r.BattleCamActive=false; r.FreeCamActive=false
r.Camera={Position=ba.createVector(0,0,0),Orientation=ba.createVector(0,0,1),FOV=0.9}
r.ordersIssued={}
REAL_ISSUE_MOVE=r.IssueMove
REAL_SET_USER_ORDER=r.SetUserOrder
function r:GetSelectedFriendlyShips() return self.testSelection or {} end
function r:IsPointOnRTSUI() return false end
function r:IsPointOnTacticalMap() return false end
function r:GetShipAtScreen() return nil end
function r:ScreenToPlane(x,y) return ba.createVector(x,0,y) end
function r:SetStatus() end

-- A movable Blue fighter, standing in for a selection.
function mkFighter(name,pos)
  local c=class(name or 'GTF TestA')
  local s=ship(name or ('Test '..(serial+1)),c,pos or ba.createVector(0,0,-2000),mn.Teams.friendly)
  s.role='fighter'; s.Radius=100
  return s
end
function mkGroup(n)
  local g={}
  for i=1,(n or 6) do g[i]=mkFighter(nil,ba.createVector(i*50,0,-2000)) end
  return g
end
-- Hulls with an explicit role, for the pursuit/chaser decision tables. The
-- role classifier itself is covered elsewhere; these tests are about the
-- pursuit gate, so the role is stated directly.
function mkHull(className,pos,role)
  local s=ship(className..' '..(serial+1),class(className),pos or ba.createVector(0,0,0),mn.Teams.friendly)
  s.__role=role or 'fighter'
  return s
end
-- A station must carry the name the mod actually keys on, because
-- IsCommandStation compares against the configured command-ship names.
function mkStation(pos)
  local s=ship(r.Config.CarrierShip,class('RTS Test Station'),
    pos or ba.createVector(20000,0,0),mn.Teams.hostile)
  s.__role='capital'
  return s
end
turboSubsystem={Name='turret',HitpointsMax=100,HitpointsLeft=100}
-- Route the role classifier through the fixtures' stated role for the duration
-- of a test; the real classifier is exercised by the other suites.
r.RealGetShipRole=r.GetShipRole
function r:GetShipRole(ship)
  if ship~=nil and ship.__role~=nil then return ship.__role end
  return r.RealGetShipRole(self,ship)
end

-- FSO order constants. Not defined by the shared fixture, so an order recorded
-- as a bare number would compare equal to any other unrecorded order (both
-- would be nil) and an "issued the right order" assertion would pass for the
-- wrong reason.
ORDER_STAY_STILL='STAY'; ORDER_WAYPOINTS_ONCE='MOVE'; ORDER_ATTACK='ATTACK'; ORDER_GUARD='GUARD'

-- Records every string the draw code actually prints. The alternative to
-- asserting a HUD claim is not reading it.
function captureStrings(fn)
  local realgr=gr; local out={}
  gr={loadTexture=realgr.loadTexture,setColor=function() end,drawRectangle=function() end,drawRectangleCentered=function() end,
    drawLine=function() end,drawCircle=function() end,drawImage=function() end,
    drawString=function(text) out[#out+1]=tostring(text) end,
    getStringWidth=function(text) return #tostring(text)*8 end,
    getScreenWidth=function() return 1920 end,getScreenHeight=function() return 1080 end,
    setTarget=function() end,getMouseX=function() return 0 end,getMouseY=function() return 0 end}
  local ok,err=pcall(fn); gr=realgr
  if not ok then error(err,0) end
  return out
end
function anyContains(list,needle)
  for _,text in ipairs(list) do if string.find(text,needle,1,true) then return true end end
  return false
end
function joinAll(list) local parts={} for _,t in ipairs(list) do parts[#parts+1]=t end return table.concat(parts,' | ') end
'''


def boot():
    """Load the shipped Lua into a fresh runtime, as the other suites do."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
    lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
    lua.execute(SETUP)
    lua.execute(EXTRA)
    return lua


class KeyBindingTests(unittest.TestCase):
    """Items 2 and 3: the remapped control scheme, and that nothing is orphaned."""

    def setUp(self):
        self.lua = boot()
        self.check("r.Enabled=true; r.SetupActive=false; r.Paused=false; r.PostBattleActive=false; r.CinematicActive=false")

    def check(self, code):
        self.lua.execute(code)

    def test_digit_keys_select_an_absolute_doubling_speed_ladder(self):
        self.check("""-- 1/2/3/4 must read as 1x/2x/4x/8x. The number on the key is the
          -- speed you get, so a player does not have to count presses.
          local applied={}
          r.SetTimeScale=function(self,scale) applied[#applied+1]=scale end
          r.SetPaused=function(self,p) applied[#applied+1]=p==false and 'unpaused' or 'paused' end
          r.SetStatus=function() end
          for key,want in pairs({['1']=1,['2']=2,['3']=4,['4']=8,['0']=16}) do
            applied={}; r:OnKeyPressed('Alt-'..key,key)
            assert(applied[#applied]==want,
              'key '..key..' gave '..tostring(applied[#applied])..'x, expected '..want..'x')
          end""")

    def test_pause_key_is_a_gameplay_pause_not_the_game_pause(self):
        self.check("""-- The dedicated Pause key must stop the battle, not open the engine's
          -- game pause. It used to be routed to the mod's pause only when
          -- AI.DisableMissionPause was set, so with that off the key fell
          -- through to the engine.
          local toggles=0
          r.TogglePause=function() toggles=toggles+1 end
          r.IsMissionPauseDisabled=function() return false end
          controls={Pause='Pause'}
          r.Enabled=true; r.SetupActive=false; r.PostBattleActive=false; r.CinematicActive=false
          for _,key in ipairs({'Pause','Break'}) do
            toggles=0; r:OnKeyPressed(key,key)
            assert(toggles==1,key..' did not reach the gameplay pause (toggles='..toggles..')')
            assert(r:ShouldOverrideKey(key,key),key..' leaked to native gameplay input')
          end
          -- Alt+Pause must still fall through to the native menu, or the player
          -- loses Options / Controls / Restart / Abort entirely.
          toggles=0; r:OnKeyPressed('Alt-Pause','Alt-Pause')
          assert(toggles==0 and not r:ShouldOverrideKey('Alt-Pause','Alt-Pause'),
            'Alt+Pause was swallowed and the native menu became unreachable')
          r.PossessedSignature=123; toggles=0
          r:OnKeyPressed('Pause','Pause')
          assert(toggles==1 and r:ShouldOverrideKey('Pause','Pause'),
            'Pause must remain a gameplay pause while piloting')""")

    def test_config_declares_the_new_scheme(self):
        self.check("""local c=r.Config.HomeworldControls
          assert(c.TimeSlower=='1' and c.TimePause=='2' and c.TimeFaster=='3' and c.TimeReset=='4')
          assert(c.Wing1=='1' and c.Wing2=='2' and c.Wing3=='3' and c.Wing4=='4')
          assert(c.SelectAll=='L' and c.Chase=='B' and c.MuteMusic=='N')
          assert(c.HoldPolicy=='J' and c.PassivePolicy=='Z' and c.DefensivePolicy=='X' and c.AggressivePolicy=='V')
          assert(c.Cinematic=='C')
          for _,k in ipairs({'TimeSlower','TimePause','TimeFaster','TimeReset','Wing1','Wing2','Wing3','Wing4',
                             'SelectAll','Chase','MuteMusic','HoldPolicy','PassivePolicy','DefensivePolicy',
                             'AggressivePolicy','Cinematic'}) do assert(c[k],k) end""")

    def test_every_bound_key_is_also_swallowed(self):
        """A key bound in OnKeyPressed but missing from ShouldOverrideKey leaks to
        FSO and double-fires; a key swallowed but never bound is a dead key."""
        self.check("""local c=r.Config.HomeworldControls
          local bound={c.TimeSlower,c.TimePause,c.TimeFaster,c.TimeReset,
            c.Wing1,c.Wing2,c.Wing3,c.Wing4,c.SelectAll,c.Chase,c.MuteMusic,
            c.HoldPolicy,c.PassivePolicy,c.DefensivePolicy,c.AggressivePolicy,c.Cinematic,
            c.Stop,c.Engage,c.Release,c.ArmMove,c.ArmAttack,c.Focus,c.FocusBase,c.ZoomFar,c.ZoomNear}
          for _,key in ipairs(bound) do
            assert(r:ShouldOverrideKey(key,key)==true, key..' is bound but not swallowed')
          end""")

    def test_no_duplicate_bindings(self):
        self.check("""local c=r.Config.HomeworldControls
          local seen={}
          for _,key in ipairs({'Alt-'..c.TimeSlower,'Alt-'..c.TimePause,'Alt-'..c.TimeFaster,'Alt-'..c.TimeReset,c.Wing1,c.Wing2,c.Wing3,c.Wing4,
            c.SelectAll,c.Chase,c.MuteMusic,c.HoldPolicy,c.PassivePolicy,c.DefensivePolicy,c.AggressivePolicy,
            c.Cinematic,c.Stop,c.Engage,c.Release,c.ArmMove,c.ArmAttack,c.Focus,c.FocusBase,c.ZoomFar,c.ZoomNear,
            c.PanForward,c.PanBackward,c.PanLeft,c.PanRight}) do
            assert(not seen[key], 'duplicate binding: '..key)
            seen[key]=true
          end""")

    def test_number_keys_recall_groups(self):
        self.check("""r.testSelection={}
          local recalled=false; r.RecallControlGroup=function(self,g) recalled=g end
          r:OnKeyPressed('1','1'); r:OnKeyPressed('2','2'); r:OnKeyPressed('3','3'); r:OnKeyPressed('4','4')
          assert(recalled==4,'number keys do not recall groups')""")

    def test_digits_recall_and_shift_digits_assign_groups(self):
        self.check("""local recalled,assigned
          r.RecallControlGroup=function(self,g) recalled=g end
          r.AssignControlGroup=function(self,g) assigned=g end
          r:OnKeyPressed('3','3'); assert(recalled==3 and assigned==nil,'3 did not recall group 3')
          r:OnKeyPressed('Shift-3','3')
          assert(assigned==3,'Shift+3 did not assign group 3')
          r:OnKeyReleased('Shift','Shift')""")

    def test_policy_keys_cover_all_four_policies(self):
        self.check("""local seen={}
          r.SetGlobalPolicy=function(self,p) seen[p]=true end
          r:OnKeyPressed('J','J'); r:OnKeyPressed('Z','Z'); r:OnKeyPressed('X','X'); r:OnKeyPressed('V','V')
          assert(seen.HOLD and seen.RETREAT and seen.STANDOFF and seen.ENGAGE,
            'HOLD/RETREAT/STANDOFF/ENGAGE not all reachable by key')""")

    def test_music_key_toggles_the_audio_stream(self):
        self.check("""musicCalls={}; r.EnvironmentMusicHandle=21
          r:OnKeyPressed('N','N'); assert(r.MusicMuted==true,'N did not mute')
          assert(#musicCalls==1 and musicCalls[1].handle==21 and musicCalls[1].paused==true)
          r:OnKeyPressed('N','N'); assert(r.MusicMuted==false,'N did not unmute')
          assert(musicCalls[2].paused==false)""")


class FactionSetupTests(unittest.TestCase):
    def setUp(self):
        self.lua=boot()

    def check(self,code):
        self.lua.execute(code)

    def test_mirror_races_remain_hostile_and_six_stations_form_a_hexagon(self):
        self.check("""r.SetupFactionCountChoice=6; r:UpdateFactionCount()
          assert(#r.Config.FactionOrder==12 and #r:GetFactionKeys()==6,'setup should expose twelve supported team slots and honor six teams')
          r:SetFactionSpecies('BLUE','SHIVAN'); r:SetFactionSpecies('RED','SHIVAN')
          local blue=ship('mirror blue',class('SF Mara'),ba.createVector(0,0,0),mn.Teams.friendly)
          local red=ship('mirror red',class('SF Mara'),ba.createVector(1,0,0),mn.Teams.hostile)
          assert(r:GetFactionKey(blue)=='BLUE' and r:GetFactionKey(red)=='RED','faction slot identity collapsed by duplicate species')
          assert(r:AreEnemies(blue,red),'mirror species on separate IFF teams are not hostile')
          r.UpdateCameraTransform=function() end
          r.SetupActive=true
          r:ApplyConfiguredBaseSpacing()
          local keys=r:GetFactionKeys(); local d=r:GetBaseDistanceProfile().distance
          assert(#keys==6 and r.ScenarioMapHalfExtent>d/(2*math.sin(math.pi/6)),'six-team map bounds do not include the whole layout')
          for i=1,#keys do
            local a=r.ScenarioBasePositions[keys[i]]; local b=r.ScenarioBasePositions[keys[i%#keys+1]]
            assert(math.abs(a:getDistance(b)-d)<.01,'neighboring station spacing changed in the hexagon')
          end""")

    def test_legacy_gold_only_selection_keeps_the_chosen_slot(self):
        self.check("""r.SetupFactionCountChoice=nil; r.SetupOpponents={RED=false,GOLD=true}; r:UpdateFactionCount()
          local keys=r:GetFactionKeys()
          assert(#keys==2 and keys[1]=='BLUE' and keys[2]=='GOLD','legacy Gold-only setup was replaced with Red by faction count')
          assert(not r:IsFactionEnabled('RED') and r:IsFactionEnabled('GOLD'))""")

    def test_symmetric_matches_assign_each_faction_a_neighboring_opening_target(self):
        self.check("""r.SetupFactionCountChoice=6; r:UpdateFactionCount(); r.UpdateCameraTransform=function() end; r.SetupActive=true
          r:ApplyConfiguredBaseSpacing()
          local keys=r:GetFactionKeys(); local bases={}; local serial=0
          for _,kind in ipairs(keys) do
            local def=r:GetFactionDefinition(kind); local team=mn.Teams[def.team]
            if not team then team={Name=def.team,isValid=function() return true end,attacks=function(a,b) return a~=b end}; mn.Teams[def.team]=team end
            serial=serial+1
            bases[kind]={Name=kind,Team=team,Position=r.ScenarioBasePositions[kind],HitpointsLeft=100,
              isValid=function() return true end,getBreedName=function() return 'Ship' end,isDying=function() return false end,
              getSignature=function() return serial end}
          end
          r.GetFactionCommandShip=function(self,kind) return bases[kind] end
          r.AreEnemies=function(self,a,b) return a~=b end
          for i,kind in ipairs(keys) do
            local expected=keys[i%#keys+1]
            assert(r:SelectFactionPrimaryTarget(kind)==bases[expected],kind..' did not choose its fair ring neighbor '..expected)
          end""")

    def test_setup_cycles_player_and_ai_species_then_paginates_larger_matches(self):
        self.check("""r.SetupFactionCountChoice=nil; r.SetupOpponents={RED=true,GOLD=false}; r:UpdateFactionCount()
          r:DrawSetupOverlay(1280,720)
          local function click(id)
            local q=r.SetupButtonRects[id]; assert(q,'missing setup control '..id)
            assert(r:HandleSetupClick((q.x1+q.x2)/2,(q.y1+q.y2)/2),'setup click ignored '..id)
          end
          for i=1,4 do click('factions_more') end
          assert(r.SetupFactionCount==6,'faction count stepper stopped at '..tostring(r.SetupFactionCount)..' choice='..tostring(r.SetupFactionCountChoice))
          r:DrawSetupOverlay(1280,720)
          click('faction_BLUE'); assert(r:GetFactionChoice('BLUE')=='GTVA','player faction did not cycle')
          click('faction_RED'); assert(r:GetFactionChoice('RED')=='RANDOM','AI faction did not cycle independently')
          click('faction_next'); r:DrawSetupOverlay(1280,720)
          assert(r.SetupFactionPage==2 and r.SetupButtonRects.faction_FACTION_06,'faction page omitted a configured faction')
          for i=1,#r.Config.FactionChoices do
            if r:GetFactionChoice('FACTION_06')=='RANDOM' then break end
            click('faction_FACTION_06')
          end
          assert(r:GetFactionChoice('FACTION_06')=='RANDOM','per-faction random choice unavailable')
          r.SetupFactionCountChoice=12; r:UpdateFactionCount(); r:DrawSetupOverlay(1280,720)
          click('faction_next')
          r:DrawSetupOverlay(1280,720)
          assert(r.SetupFactionPage==3 and r.SetupButtonRects.faction_FACTION_12,
            'the setup screen cannot reach the last supported faction slot')""")


class AutoModeTests(unittest.TestCase):
    """Item 1: Auto Mode off must mean no Blue autonomy."""

    def setUp(self):
        self.lua = boot()
        self.check("r.Enabled=true; r.SetupActive=false; r.ScenarioStartTime=0; r.PostBattleActive=false")
        self.check("r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0; r.CommandPoints=10000")

    def check(self, code):
        self.lua.execute(code)

    def test_disabling_auto_mode_drops_the_blue_production_state(self):
        """The leak: SetAutoPlayerMode(false) used to keep AIStates.BLUE alive with
        playerEconomy=true, so UpdateAIProduction kept buying ships with player CP."""
        self.check("""r.AutoPlayerMode=true
          r:InitializeAIStates(0); assert(r.AIStates.BLUE,'blue state not created with auto on')
          r:SetAutoPlayerMode(false)
          assert(r.AIStates.BLUE==nil,'blue production state survived auto-mode off')""")

    def test_blue_production_cannot_spend_cp_with_auto_mode_off(self):
        self.check("""r.AutoPlayerMode=true; r:InitializeAIStates(0)
          r:SetAutoPlayerMode(false)
          local before=r.CommandPoints
          r:UpdateAIProduction(10); r:UpdateAIProduction(20); r:UpdateAIProduction(100)
          assert(r.CommandPoints==before,'blue spent CP with auto mode off')""")

    def test_red_and_gold_production_is_unaffected(self):
        self.check("""r.SetupOpponents={RED=true,GOLD=true}
          r.AutoPlayerMode=true; r:InitializeAIStates(0)
          r:SetAutoPlayerMode(false)
          assert(r.AIStates.RED and r.AIStates.GOLD,'enemy factions lost their production state')
          local red=r.AIStates.RED; local gold=r.AIStates.GOLD
          local redCp,goldCp=red.cp,gold.cp
          r:UpdateAIProduction(10); r:UpdateAIProduction(40)
          assert(r.AIStates.RED==red and r.AIStates.GOLD==gold,'enemy production state was dropped')
          assert(r.AIStates.BLUE==nil,'blue state came back')""")

    def test_default_policy_is_hold_so_idle_fleet_never_fights(self):
        self.check("""assert(r.Config.Policy.Default=='HOLD','HOLD is not the default policy')
          assert(r.GlobalPolicy=='HOLD')""")

    def test_hold_policy_issues_no_attack_or_guard_order(self):
        self.check("""r.GlobalPolicy='HOLD'; r.PolicyApplied={}
          local given={}
          local s=mkFighter()
          r.HoldShip=function(self,ship,priority) given[#given+1]='hold' end
          r.EngageShip=function() given[#given+1]='engage' end
          r.MoveShipTo=function() given[#given+1]='move' end
          r:ApplyPolicyToShip(s,true)
          assert(#given==1 and given[1]=='hold','HOLD policy issued '..tostring(given[1] or 'nothing'))""")


class FormationTests(unittest.TestCase):
    """Item 5: formation shapes, the UI selector contract, and AI selection."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        self.lua.execute(code)

    def test_all_six_shapes_are_configured_and_selectable(self):
        self.check("""local types=r:GetFormationTypes(); assert(#types==6,'expected 6 formation types')
          local ids={}
          for _,t in ipairs(types) do ids[t.id]=t.label; assert(t.desc and #t.desc>5) end
          for _,id in ipairs({'LINE_ABREAST','COLUMN','TIGHT','WEDGE','ECHELON','SCREEN'}) do assert(ids[id],id) end
          for _,id in ipairs({'LINE_ABREAST','COLUMN','TIGHT','WEDGE','ECHELON','SCREEN'}) do
            assert(r:SetSelectedFormation(id),'could not select '..id)
            assert(r:GetSelectedFormation()==id)
          end""")

    def test_unknown_formation_is_rejected_and_falls_back(self):
        self.check("""assert(not r:SetSelectedFormation('NOT_A_SHAPE'),'unknown formation was accepted')
          assert(r:GetSelectedFormation()==r.Config.Formation.Default)
          r.SelectedFormation='GARBAGE'; assert(r:GetSelectedFormation()==r.Config.Formation.Default)""")

    def test_cycling_walks_every_shape_and_wraps(self):
        self.check("""r:SetSelectedFormation(r.Config.Formation.Default)
          local seen={}; local total=#r:GetFormationTypes()
          for _=1,total do r:CycleSelectedFormation(1); seen[r:GetSelectedFormation()]=true end
          local n=0; for _ in pairs(seen) do n=n+1 end
          assert(n==total,'cycle visited '..n..' of '..total)
          local first=r:GetSelectedFormation(); r:CycleSelectedFormation(1)
          assert(r:GetSelectedFormation()~=first)""")

    def test_shapes_actually_produce_distinct_slot_geometry(self):
        self.check("""local ships=mkGroup(6)
          local function span(id)
            local slots=r:BuildSafeFormationDestinations(ships,ba.createVector(0,0,5000),id)
            local minx,maxx,minz,maxz=1e9,-1e9,1e9,-1e9
            for _,s in ipairs(slots) do
              minx=math.min(minx,s.destination.x); maxx=math.max(maxx,s.destination.x)
              minz=math.min(minz,s.destination.z); maxz=math.max(maxz,s.destination.z)
            end
            return (maxx-minx),(maxz-minz)
          end
          local lineW,lineD=span('LINE_ABREAST')
          local colW,colD=span('COLUMN')
          local tightW,tightD=span('TIGHT')
          local wedgeW,wedgeD=span('WEDGE')
          assert(lineW>colW*2,'LINE_ABREAST is not wider than COLUMN')
          assert(colD>lineD,'COLUMN is not deeper than LINE_ABREAST')
          assert(tightW<lineW,'TIGHT is not tighter than LINE_ABREAST')
          assert(wedgeD>0 and wedgeW>0,'WEDGE produced a degenerate shape')""")

    def test_unknown_formation_id_falls_back_to_row_packing(self):
        self.check("""local ships=mkGroup(4)
          local a=r:BuildSafeFormationDestinations(ships,ba.createVector(0,0,5000),'LINE_ABREAST')
          local b=r:BuildSafeFormationDestinations(ships,ba.createVector(0,0,5000),'NOT_A_SHAPE')
          assert(#a==#b and #b>0,'fallback produced no slots')""")

    def test_ai_picks_a_formation_per_role(self):
        self.check("""assert(r.Config.AI.UsesFormations~=false)
          for role,expected in pairs(r.Config.AI.Formations) do
            assert(r.Config.Formation.Shapes[expected],role..' maps to unknown shape '..expected)
          end
          assert(r:ChooseAIFormation('BOMBER','ASSAULT')~=nil,'no formation chosen for a bomber assault')""")


class ReticleTests(unittest.TestCase):
    """Item 4: reticles must stay visible at every zoom and share map colours."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        self.lua.execute(code)

    def test_reticle_size_is_clamped_at_every_zoom(self):
        self.check("""local s=mkFighter(); s.Class.Model.Radius=1000
          local min=r.Config.Selection.ReticleMinPixels; local max=r.Config.Selection.ReticleMaxPixels
          for _,d in ipairs({55,300,2000,9000,20000,65000}) do
            r.CameraDistance=d
            local size=r:GetReticlePixelSize(s)
            assert(size>=min and size<=max,'zoom '..d..' produced '..size..'px')
            assert(size>=min,'reticle collapsed at zoom '..d)
          end""")

    def test_reticle_colours_match_the_tactical_map_icons(self):
        self.check("""local s=mkFighter()
          local friendly=r:GetReticleFactionKey(s)
          assert(friendly=='friendly','friendly ship misclassified as '..friendly)
          r.EachShip=function() end""")

    def test_role_glyphs_are_filled_shapes_not_wireframes(self):
        self.check("""-- Item 4: the icons drawn inside a reticle were built from drawLine
          -- segments, which is a wireframe by definition. Record every draw call
          -- each glyph makes and require a filling primitive.
          local roles={'fighter','bomber','escort','capital','heavy','juggernaut','sentry','station','support'}
          local realgr=gr
          for _,role in ipairs(roles) do
            local calls={}
            gr={setColor=function() end,getScreenWidth=realgr.getScreenWidth,getScreenHeight=realgr.getScreenHeight,
                drawLine=function() calls[#calls+1]='line' end,
                drawRectangle=function(x1,y1,x2,y2,filled)
                  calls[#calls+1]=filled==true and 'rect-fill' or 'rect-outline' end,
                drawRectangleCentered=function(x,y,w,h,filled)
                  calls[#calls+1]=filled==true and 'rectc-fill' or 'rectc-outline' end,
                drawCircle=function(r,x,y,filled)
                  calls[#calls+1]=(filled~=false) and 'circle-fill' or 'circle-outline' end}
            local s=mkFighter(); s.role=role
            r:DrawRoleMarker(s,10,10,40,50)
            gr=realgr
            -- The last call is the badge frame DrawRoleMarker deliberately draws
            -- around the glyph. It is UI chrome, not the icon, so drop it before
            -- judging whether the icon itself is a solid shape.
            if calls[#calls]=='rect-outline' then calls[#calls]=nil end
            assert(#calls>0,role..' role glyph drew nothing')
            for _,c in ipairs(calls) do
              assert(c~='line',role..' role glyph is still drawn from line segments (hollow)')
              assert(c~='rect-outline' and c~='rectc-outline' and c~='circle-outline',
                role..' role glyph used an unfilled primitive: '..c)
            end
          end""")

    def test_icon_texture_api_matches_the_engine(self):
        # FSO's texture scripting object exposes isValid/getFilename/getWidth/
        # getHeight/unload but NOT use(). An earlier revision of the reticle
        # icon work called tex:use() to "bind" the texture; in the engine that
        # raises __indexer: Argument 2 is an invalid type 'string' and takes
        # the whole HUD draw hook down with it. gr.drawImage binds the handle
        # itself, so the correct fix for hollow icons is the filled glyph, not
        # a manual bind. This test fails if the call comes back.
        #
        # The `assert(not pcall(function() return handle:use() end))` that used
        # to carry this was true by construction: `handle` was a plain Lua
        # table with no metatable, so calling use() raised whatever was missing
        # on the double, and the assertion said nothing about the mod. It would
        # still have passed with tex:use() back in the mod. What actually
        # constrains the mod is the source scan below; the l_Texture double
        # then reproduces the engine's own __indexer behaviour so the icon code
        # is exercised against a handle that rejects unknown methods.
        offenders = []
        for path in sorted(SCRIPTS.rglob("*.lua")):
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if ":use(" in line:
                    offenders.append(f"{path.name}:{number}: {line.strip()}")
        self.assertEqual(offenders, [],
                         "l_Texture has no use(); these call sites would abort the HUD draw hook: "
                         + " | ".join(offenders))
        self.check("""-- Dot, not colon: `r:Foo~=nil` parses as a method call whose single
          -- argument is `~= nil`, which is a syntax error.
          assert(r.LoadBriefingIcon~=nil,'LoadBriefingIcon missing')
          assert(r.UseIcon==nil,'UseIcon is a texture:use() wrapper and must not come back')
          -- A handle with exactly the five methods l_Texture exposes. Indexing
          -- anything else raises the way the engine's __indexer does, so a
          -- reintroduced bind cannot hide behind a permissive double.
          local real={
            isValid=function() return true end,
            getFilename=function() return 'icon01' end,
            getWidth=function() return 128 end,
            getHeight=function() return 128 end,
            unload=function() end}
          local handle=setmetatable({},{__index=function(t,k)
            if real[k]~=nil then return real[k] end
            error("__indexer: Argument 2 is an invalid type 'string'",0) end})
          local drawn=0
          gr.loadTexture=function() return handle end
          gr.drawImage=function(tex) drawn=drawn+1; assert(tex==handle,'drawImage got the wrong handle') end
          r.TacticalMapIconCache=nil
          local tex=r:GetBriefingIcon('GTF TestB','fighter',false)
          assert(tex==handle,'GetBriefingIcon did not return the loaded handle')
          gr.drawImage(tex,0,0,10,10)
          assert(drawn==1,'the icon was never handed to drawImage')
          -- isValid() is the only validity gate: a false one must degrade to
          -- nil rather than being handed to drawImage.
          r.TacticalMapIconCache=nil
          gr.loadTexture=function() return setmetatable({},{__index=function()
            return function() return false end end}) end
          assert(r:GetBriefingIcon('GTF TestB','fighter',false)==nil,
            'an invalid texture handle was still returned for drawing')""")

    def test_edge_marker_and_range_ring_are_safe_on_degenerate_input(self):
        """These four calls used to be bare statements behind an `or true`, so
        the test could not fail: it asserted that a value was truthy, and then
        ran four draws with no assertion at all. Each case now has to either
        draw the right number of primitives or be rejected by its own guard -
        and a guard rejection has to draw nothing."""
        self.check("""local realgr=gr
          local function capture(fn)
            local n=0
            gr={loadTexture=realgr.loadTexture,drawImage=realgr.drawImage,setColor=function() end,
              getScreenWidth=realgr.getScreenWidth,getScreenHeight=realgr.getScreenHeight,getCurrentCamera=realgr.getCurrentCamera,
              drawRectangle=function() n=n+1 end,
              drawLine=function() n=n+1 end,drawString=function() end,getStringWidth=function() return 10 end}
            fn(); gr=realgr; return n
          end
          -- A contact exactly at the screen centre is on screen, not off it, so
          -- no edge marker may be drawn for it.
          assert(capture(function() r:DrawEdgeContactMarker(mkFighter(),960,540,{255,0,0},1920,1080) end)==0,
            'an on-screen contact was pinned to the edge anyway')
          -- An off-screen contact must be pinned somewhere.
          assert(capture(function() r:DrawEdgeContactMarker(mkFighter(),3000,540,{255,0,0},1920,1080) end)>0,
            'an off-screen contact drew no edge marker at all')
          -- Degenerate inputs are rejected by the guard, not drawn: a nil
          -- centre, a zero range and a negative range.
          assert(capture(function() r:DrawWorldRangeRing(nil,1000,{255,0,0},90) end)==0,'nil centre drew a ring')
          assert(capture(function() r:DrawWorldRangeRing(ba.createVector(0,0,0),0,{255,0,0},90) end)==0,'zero range drew a ring')
          assert(capture(function() r:DrawWorldRangeRing(ba.createVector(0,0,0),-5,{255,0,0},90) end)==0,'negative range drew a ring')
          -- A valid range draws exactly one segment per configured step.
          local segments=r.Config.Selection.WeaponRangeSegments or 48
          local drawn=capture(function() r:DrawWorldRangeRing(ba.createVector(0,0,0),1000,{255,0,0},90) end)
          assert(drawn==segments,'ring drew '..drawn..' segments, expected '..segments)""")

    def test_weapon_range_uses_ship_and_turret_banks(self):
        self.check("""local s=mkFighter()
          s.PrimaryBanks={{WeaponClass={Range=5000,Speed=100,LifeMax=100,isBeam=function() return false end,isValid=function() return true end},AmmoMax=0,isValid=function() return true end}}
          s.SecondaryBanks={}
          s[1].PrimaryBanks={{WeaponClass={Range=9000,Speed=100,LifeMax=100,isBeam=function() return false end,isValid=function() return true end},AmmoMax=0,isValid=function() return true end}}
          s[1].SecondaryBanks={}; s[1].TurretLocked=false
          local range=r:GetShipWeaponRange(s)
          assert(range>5000,'turret range ignored, got '..tostring(range))""")


class CinematicTests(unittest.TestCase):
    """Item 7: cinematic overhaul and switching what is being shown."""

    def setUp(self):
        self.lua = boot()
        self.lua.execute("for _,name in ipairs({'GTC Fenris','SC Lilith','GTF Hercules','SF Mara','GTB Medusa','SB Nephilim'}) do if not tb.ShipClasses[name] then class(name) end end")

    def test_intro_stages_opposing_fleets_tracks_subject_and_cleans_up(self):
        self.check('''
          local cp=r.CommandPoints
          r:StartIntroCinematic()
          local cast=r.IntroShips; assert(#cast==6)
          assert(cast[1].Team~=cast[2].Team and cast[1].Target==cast[2])
          local subject=cast[1]; r:UpdateIntroCinematic(.1)
          assert(r.Camera.Position.y>40000,'camera still films the real bases')
          local previousX=r.Camera.Position.x
          subject.Position=subject.Position+ba.createVector(1000,0,0)
          r:UpdateIntroCinematic(0)
          assert(math.abs(r.Camera.Position.x-previousX-1000)<.001,'shot did not follow its moving subject')
          r.CinematicElapsed=r:GetCinematicShotStart(5)+.1; r:UpdateIntroCinematic(0)
          local route=r.MoveWaypoints[cast[5]:getSignature()]
          assert(route and route.waypoint.Position.y==45000,'intro retreat entered the playable arena')
          local weapon={Parent=cast[3],isValid=function() return true end,vanish=function(self) self.removed=true end}
          mn.Weapons={weapon}
          r:EndIntroCinematic(true)
          assert(weapon.removed and r.IntroShips==nil and not r.CinematicActive)
          for _,s in ipairs(cast) do assert(not s:isValid(),'intro hull leaked into setup') end
          assert(r.CommandPoints==cp and next(r.UnitHistory or {})==nil,'intro changed real fleet/economy')
        ''')

    def test_partial_intro_creation_failure_removes_created_hulls(self):
        self.check('''
          local create=mn.createShip; local first
          mn.createShip=function(...)
            if first then return nil end
            first=create(...); return first
          end
          local ok=pcall(function() r:StartIntroCinematic() end)
          assert(not ok and first and not first:isValid() and r.IntroShips==nil)
        ''')

    def test_intro_order_refusal_cleans_up_the_entire_cast(self):
        self.check('''
          local create=mn.createShip; local cast={}
          mn.createShip=function(...)
            local s=create(...); cast[#cast+1]=s
            s.giveOrder=function() return false end
            return s
          end
          local ok=pcall(function() r:StartIntroCinematic() end)
          assert(not ok,'refused intro order was ignored')
          assert(r.IntroShips==nil,'refused order left the intro scene registered')
          for _,s in ipairs(cast) do assert(not s:isValid(),'refused order leaked a hull') end
        ''')

    def test_intro_tail_holds_camera_and_fades_before_resetting_to_setup(self):
        self.check('''
          r:StartIntroCinematic()
          r.CinematicElapsed=r:GetCinematicTotalDuration()-.01
          r:UpdateIntroCinematic(0)
          local x,y,z=r.Camera.Position.x,r.Camera.Position.y,r.Camera.Position.z
          r:UpdateIntroCinematic(.11)
          assert(r.CinematicTailHold and r.CinematicActive)
          r:UpdateIntroCinematic(.5)
          assert(r.Camera.Position.x==x and r.Camera.Position.y==y and r.Camera.Position.z==z,
            'tail introduced another camera movement')
          assert(r.CinematicCaptionAlpha<255,'tail flashed the faded caption back on')
          r:UpdateIntroCinematic(r.Config.Cinematic.EndHoldSeconds)
          assert(not r.CinematicActive and r.IntroFadeInUntil==r:UINow()+1,
            'camera reset did not fade into setup')
          r:StartIntroCinematic(); r:EndIntroCinematic(true)
          assert(r.IntroFadeInUntil==nil,'explicit skip was delayed by transition fade')
        ''')

    def check(self, code):
        self.lua.execute(code)

    def test_shot_switching_wraps_and_never_errors(self):
        self.check("""r:StartIntroCinematic(); assert(r.CinematicActive)
          local count=#r.Config.Cinematic.Shots; assert(count>=4)
          local visited={}
          for _=1,count do
            assert(r:CinematicNextShot(1),'shot switch refused')
            visited[r.CinematicShotIndex]=true
          end
          local n=0; for _ in pairs(visited) do n=n+1 end
          assert(n==count,'shot cycle visited '..n..' of '..count)
          for _=1,count do r:CinematicNextShot(-1) end""")

    def test_restart_keeps_the_shot_and_reanchors_time(self):
        self.check("""r:StartIntroCinematic()
          r.CinematicShotIndex=1; r.CinematicElapsed=40
          assert(r.CinematicElapsed>5)
          assert(r:CinematicRestartShot())
          assert(r.CinematicShotIndex==1,'restart changed the shot')
          assert(r.CinematicElapsed<=.001,'restart did not re-anchor the timeline: '..tostring(r.CinematicElapsed))""")

    def test_shot_start_offsets_account_for_hold_time(self):
        self.check("""r.Config.Cinematic.Shots[1].hold=0; r.Config.Cinematic.Shots[2].hold=2
          local a=r:GetCinematicShotStart(1); local b=r:GetCinematicShotStart(2)
          local c=r:GetCinematicShotStart(3)
          assert(b>a and c>b,'shot starts are not monotonic')
          assert(math.abs((b-a)-r:GetCinematicShotDuration(r.Config.Cinematic.Shots[1]))<.001,
            'shot 1 start is off by more than its duration')
          local expect=r:GetCinematicShotDuration(r.Config.Cinematic.Shots[2])+2
          assert(math.abs((c-b)-expect)<.001,
            'hold time was not added to the timeline: '..tostring(c-b)..' vs '..tostring(expect))""")

    def test_cinematic_switch_keys_do_not_skip(self):
        self.check("""r.Enabled=true; r:StartIntroCinematic()
          local nxt=r.Config.Cinematic.NextShotKey; local prv=r.Config.Cinematic.PreviousShotKey
          local rep=r.Config.Cinematic.RestartShotKey
          local before=r.CinematicShotIndex
          r:OnKeyPressed(nxt,nxt); assert(r.CinematicActive,'next shot skipped the cinematic instead')
          assert(r.CinematicShotIndex~=before,'next shot did not advance')
          r:OnKeyPressed(prv,prv); assert(r.CinematicShotIndex==before,'previous shot did not go back')
          r:OnKeyPressed(rep,rep); assert(r.CinematicActive)
          r:OnKeyPressed('Z','Z'); assert(not r.CinematicActive,'an unbound key did not skip')""")

    def test_switching_returns_false_when_inactive(self):
        self.check("""r.CinematicActive=false
          assert(not r:CinematicNextShot(1))
          assert(not r:CinematicRestartShot())""")

    def test_intro_completes_and_does_not_hang(self):
        self.check("""r:StartIntroCinematic()
          local total=r:GetCinematicTotalDuration()+r.Config.Cinematic.EndHoldSeconds+5
          r:UpdateIntroCinematic(total)
          assert(not r.CinematicActive,'cinematic never ended')""")


class BattleReportTests(unittest.TestCase):
    """Item 11: the after-action report has real content."""

    def setUp(self):
        self.lua = boot()
        self.check("r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0")

    def check(self, code):
        self.lua.execute(code)

    def test_summary_reports_duration_losses_and_factions(self):
        self.check("""r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0
          r.CombatTelemetryEnabled=true
          r.AIStats={decisions=0,losses={BLUE={['GTF Myrmidon']=3,['SJ Sathanas']=1},RED={['GTF Perseus']=7}},kills={BLUE={['GTF Perseus']=7}},hits={},received={}}
          r.AIEconomyFlow={BLUE={income=100,productionSpend=4200,bounty=0,refund=200}}
          now=421
          local s=r:BuildBattleSummary()
          assert(s.durationSeconds==421,'duration wrong: '..tostring(s.durationSeconds))
          assert(s.losses==4,'losses wrong: '..tostring(s.losses))
          assert(s.kills==7,'kills wrong: '..tostring(s.kills))
          assert(s.capitalLosses==1,'capital losses wrong: '..tostring(s.capitalLosses))
          assert(s.cpSpent==4000,'cp spent wrong: '..tostring(s.cpSpent))
          assert(#s.factions>=1,'no faction rows')""")

    def test_victory_and_defeat_record_a_summary(self):
        self.check("""r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0
          r.BlueEliminated=true
          r:EvaluateFactionVictory()
          assert(r.GameStatus=='DEFEAT' and r.PostBattleActive and r.BattleSummary,
            'defeat did not produce a battle summary')
          assert(r.PostBattleResult:find('DESTROYED'),'defeat reason is not specific: '..tostring(r.PostBattleResult))""")


class LoadoutTests(unittest.TestCase):
    """Item 15: the stats card lists what the ship can actually shoot."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        self.lua.execute(code)

    def test_capital_loadout_comes_from_turret_subsystems(self):
        self.check("""local s=mkFighter()
          s.PrimaryBanks={}; s.SecondaryBanks={}
          s[1].PrimaryBanks={{WeaponClass={Name='AAAf',Range=4000,isBeam=function() return true end,isValid=function() return true end},AmmoMax=0,isValid=function() return true end}}
          s[1].SecondaryBanks={}
          local entries,turrets,lost=r:GetShipLoadout(s)
          assert(#entries==1,'capital reported no loadout: '..#entries)
          assert(entries[1].name=='AAAf' and entries[1].beam==true)
          assert(turrets==1 and lost==0)""")

    def test_loadout_counts_destroyed_turrets(self):
        self.check("""local s=mkFighter()
          s[1].HitpointsMax=100; s[1].HitpointsLeft=0
          local _,turrets,lost=r:GetShipLoadout(s)
          assert(turrets==1 and lost==1,'destroyed turret not reported')""")

    def test_ammunition_is_shown_per_weapon(self):
        self.check("""local s=mkFighter()
          s.PrimaryBanks={{WeaponClass={Name='Falcon',Range=3000,Speed=200,LifeMax=4,isBeam=function() return false end,isValid=function() return true end},AmmoMax=40,AmmoLeft=7,isValid=function() return true end}}
          s.SecondaryBanks={}
          local entries=r:GetShipLoadout(s)
          assert(entries[1].ammoMax==40 and entries[1].ammoLeft==7,'ammo not reported')
          assert(entries[1].range==800,'lifetime-capped range wrong: '..tostring(entries[1].range))""")


class MoveFacingTests(unittest.TestCase):
    """Item 16: right-drag sets the facing, and the facing is applied per frame."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        self.lua.execute(code)

    def test_facing_is_stored_on_the_move_order(self):
        self.check("""local s=mkFighter()
          r.IssueMove=REAL_ISSUE_MOVE
          r.BuildSafeFormationDestinations=function() return {{ship=s,destination=ba.createVector(100,0,200)}} end
          r.GetSelectedFriendlyShips=function() return {s} end
          r.MoveShipTo=function() return true end
          r.ClampCommandPoint=function(self,p) return p,false end
          r.SetUserOrder=REAL_SET_USER_ORDER
          r:IssueMove(ba.createVector(100,0,200),ba.createVector(900,0,200))
          local o=r.UserOrders[s.signature]
          assert(o and o.kind=='move' and o.facing,'facing was not recorded on the move order')
          assert(o.facing.x==900)""")

    def test_no_facing_means_no_facing_field(self):
        self.check("""local s=mkFighter()
          r.IssueMove=REAL_ISSUE_MOVE
          r.BuildSafeFormationDestinations=function() return {{ship=s,destination=ba.createVector(100,0,200)}} end
          r.GetSelectedFriendlyShips=function() return {s} end
          r.MoveShipTo=function() return true end
          r.ClampCommandPoint=function(self,p) return p,false end
          r.SetUserOrder=REAL_SET_USER_ORDER
          r:IssueMove(ba.createVector(100,0,200))
          assert(r.UserOrders[s.signature].facing==nil,'a plain move invented a facing')""")

    def test_facing_sexp_is_driven_after_arrival_without_fighting_waypoint_steering(self):
        self.check("""local s=mkFighter()
          r.Enabled=true
          r.SetupActive=false; r.PostBattleActive=false; r.PossessedSignature=nil
          r.UserOrders={ [s.signature]={kind='move',destination=ba.createVector(0,0,0),facing=ba.createVector(1000,0,0)} }
          sexps={}
          r:UpdateMoveFacings()
          assert(#sexps==0,'arrival facing competed with native waypoint steering')
          r.SetUserOrder=REAL_SET_USER_ORDER
          r:OnWaypointsDone(s)
          r:UpdateMoveFacings()
          assert(#sexps>0,'arrival facing was never issued to the engine')
          assert(sexps[1]:find('set%-object%-facing'),'wrong SEXP: '..tostring(sexps[1]))""")

    def test_facing_is_dropped_when_the_ship_dies(self):
        self.check("""local s=mkFighter()
          r.SetupActive=false; r.PostBattleActive=false; r.PossessedSignature=nil
          local order={kind='move',destination=ba.createVector(0,0,0),facing=ba.createVector(1000,0,0)}
          r.UserOrders={ [s.signature]=order }
          s.valid=false
          r:UpdateMoveFacings()
          assert(order.facing==nil,'a dead ship kept a facing command')""")


class SpatialTelemetryTests(unittest.TestCase):
    """The heat-map/intersection tooling depends on these fields existing. Without
    them a headless batch can say what each group decided but not where it was, so
    no location or self-coordination map can be rebuilt."""

    def setUp(self):
        self.lua = boot()
        # A wrapping emitter spy alone is not a runtime trace destination.
        self.check("r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0; r.CombatTelemetryEnabled=true; r.AIEventSink=function() end")

    def check(self, code):
        self.lua.execute(code)

    def test_decision_records_carry_group_geometry(self):
        self.check("""local s=mkFighter()
          r.CombatTelemetryEnabled=true
          r.Config.AI.DetailedDecisionTelemetry=false
          local emitted={}
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='DECISION' then emitted[#emitted+1]=data end return real(self,name,data,t) end
          local g={id='wing1:fighter',units={s},role='fighter',value=100,spread=500,mission='PRIMARY',target=s}
          r:CommitAIGroup(g,s,'PRIMARY',mkFighter(),{posture='OFFENSIVE'},10,true)
          assert(#emitted==1,'no DECISION record emitted')
          local d=emitted[1]
          assert(type(d.centroidX)=='number' and type(d.centroidZ)=='number',
            'DECISION has no group centroid: '..tostring(d.centroidX))
          assert(d.unitCount==1,'unitCount wrong: '..tostring(d.unitCount))
          assert(d.spread==500,'spread lost')
          assert(d.formation~=nil,'DECISION does not report the chosen formation')
          assert(d.arenaHalfExtent~=nil,'DECISION does not carry the command arena')""")

    def test_cohesion_reports_shared_targets_and_overlap(self):
        self.check("""r.CombatTelemetryEnabled=true
          local emitted={}
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='COHESION' then emitted[#emitted+1]=data end return real(self,name,data,t) end
          local shared=mkFighter(nil,ba.createVector(0,0,0))
          local other=mkFighter(nil,ba.createVector(60000,0,0))
          local mk=function(id,x,z,spread,target)
            local s=mkFighter(nil,ba.createVector(x,0,z))
            return {id=id,units={s},role='fighter',value=10,spread=spread,mission='PRIMARY',target=target}
          end
          -- two wings converging on the same target, discs overlapping
          local groups={mk('A',0,0,500,shared),mk('B',900,0,500,shared),mk('C',30000,0,500,other)}
          r:EmitAICohesion('BLUE',groups,mkFighter(),nil,42)
          assert(#emitted==1,'no COHESION record emitted')
          local c=emitted[1]
          assert(c.groupCount==3,'groupCount wrong: '..tostring(c.groupCount))
          local sharedEdges,overlapping,total=0,0,0
          for _,p in ipairs(c.pairs) do
            total=total+1
            if p.sharedTarget then sharedEdges=sharedEdges+1 end
            if p.gap<0 then overlapping=overlapping+1 end
          end
          assert(sharedEdges==1,'expected exactly the A-B shared-target edge, got '..sharedEdges)
          assert(overlapping==1,'expected exactly the A-B overlap, got '..overlapping)
          assert(total==1,'a distant group with a different target was reported as interacting: '..total)
          assert(c.arenaHalfExtent~=nil,'COHESION does not carry the command arena')""")

    def test_cohesion_ignores_distant_unrelated_groups(self):
        self.check("""r.CombatTelemetryEnabled=true
          local emitted={}
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='COHESION' then emitted[#emitted+1]=data end return real(self,name,data,t) end
          local mk=function(x,z) local s=mkFighter(nil,ba.createVector(x,0,z)) return {id='g'..x,units={s},role='fighter',value=10,spread=100,mission='PRIMARY'} end
          r:EmitAICohesion('RED',{mk(0,0),mk(500000,500000)},nil,nil,7)
          local c=emitted[1]
          assert(#c.pairs==0,'distant groups were reported as interacting: '..#c.pairs)""")

    def test_cohesion_is_safe_with_no_groups(self):
        self.check("""r.CombatTelemetryEnabled=true
          local emitted={}
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='COHESION' then emitted[#emitted+1]=data end return real(self,name,data,t) end
          r.AICohesionSampleAt={}
          r:EmitAICohesion('BLUE',{},nil,nil,1)
          r:EmitAICohesion('BLUE',nil,nil,nil,10)
          assert(#emitted==2,'empty cohort sampling failed: '..#emitted)
          assert(emitted[1].groupCount==0 and #emitted[1].pairs==0)""")

    def test_cohesion_sample_is_rate_limited(self):
        """Emitting on every planner tick tripled a headless run's frame cost and
        pushed it past the runner's wall-clock timeout."""
        self.check("""r.CombatTelemetryEnabled=true
          r.Config.AI.CohesionSampleSeconds=2
          local emitted=0
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='COHESION' then emitted=emitted+1 end return real(self,name,data,t) end
          r.AICohesionSampleAt={}
          for t=0,20 do r:EmitAICohesion('BLUE',{},nil,nil,t) end
          assert(emitted<=12,'cadence not applied: '..emitted..' samples over 21 ticks at 2s')
          assert(emitted>=10,'cadence dropped too many samples: '..emitted)
          -- Factions are sampled independently.
          local before=emitted
          r:EmitAICohesion('RED',{},nil,nil,0)
          assert(emitted==before+1,'per-faction cadence leaked into other factions')""")


class OutcomeTelemetryTests(unittest.TestCase):
    """The records that explain a finished battle: who killed which base, from
    what state, and whether any group had stopped closing on its objective."""

    def setUp(self):
        self.lua = boot()
        self.check("r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0; r.CombatTelemetryEnabled=true; r.AIEventSink=function() end")

    def check(self, code):
        self.lua.execute(code)

    def test_contest_reports_allocation_and_stall(self):
        self.check("""r.CombatTelemetryEnabled=true
          r.Config.AI.ContestSampleSeconds=10
          r.AIContestSampleAt={}
          local emitted={}
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='CONTEST' then emitted[#emitted+1]=data end return real(self,name,data,t) end
          local station=mkFighter(nil,ba.createVector(0,0,0))
          local enemy=mkFighter(nil,ba.createVector(20000,0,0))
          local mk=function(id,x,target) local s=mkFighter(nil,ba.createVector(x,0,0))
            return {id=id,units={s},role='fighter',value=100,mission='PRIMARY',target=target} end
          local groups={mk('A',0,enemy),mk('B',5000,enemy)}
          r.AIStates={BLUE={cp=5000}}
          r:EmitContestRecord('BLUE',groups,station,enemy,100)
          assert(#emitted==1,'no CONTEST record emitted')
          local c=emitted[1]
          assert(c.groupCount==2 and c.valueOnPrimary==200,'allocation wrong')
          assert(c.missionCounts.PRIMARY==2,'mission counts wrong')
          assert(c.worstStallSeconds~=nil,'no stall metric')
          assert(#c.groups==2 and c.groups[1].targetIsStation==true)""")

    def test_contest_flags_a_group_that_stopped_closing(self):
        """The signature of a capital that took an attack order and then parked:
        the group is still assigned, but its range to the target stops falling."""
        self.check("""r.CombatTelemetryEnabled=true
          r.Config.AI.ContestSampleSeconds=1
          r.AIContestSampleAt={}
          local emitted={}
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='CONTEST' then emitted[#emitted+1]=data end return real(self,name,data,t) end
          r.AIStates={BLUE={cp=5000}}
          local station=mkFighter(nil,ba.createVector(0,0,0))
          local enemy=mkFighter(nil,ba.createVector(5000,0,0))
          local s=mkFighter(nil,ba.createVector(0,0,0))
          local groups={{id='stalled',units={s},role='capital',value=900,mission='PRIMARY',target=enemy}}
          for t=0,40,5 do r:EmitContestRecord('BLUE',groups,station,enemy,t) end
          local last=emitted[#emitted]
          assert(last.stalledGroups==1,'a group that never closed was not flagged')
          assert(last.worstStallSeconds>=30,'stall seconds wrong: '..tostring(last.worstStallSeconds))""")

    def test_contest_is_rate_limited(self):
        self.check("""r.CombatTelemetryEnabled=true
          r.Config.AI.ContestSampleSeconds=10
          local emitted=0
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='CONTEST' then emitted=emitted+1 end return real(self,name,data,t) end
          r.AIContestSampleAt={}
          for t=0,20 do r:EmitContestRecord('BLUE',{},nil,nil,t) end
          assert(emitted==3,'expected 3 samples over 21 ticks at 10s, got '..emitted)""")

    def test_outcome_cause_ranks_the_killers(self):
        self.check("""r.CombatTelemetryEnabled=true
          local emitted={}
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='OUTCOME_CAUSE' then emitted[#emitted+1]=data end return real(self,name,data,t) end
          local stationName=r.Config.CarrierShip
          local util=require 'fs2rts_ai_util'
          local bucket=util.baseDamageBucketKey
          r.BaseDamageTelemetry={totalByFaction={BLUE={hitCount=10,shieldDamage=0,hullDamage=0,weapons={}}}}
          local w=r.BaseDamageTelemetry.totalByFaction.BLUE.weapons
          w[bucket(stationName,'Mekhu HL-7','Laser','PROJECTILE','UNKNOWN',false,false,'GOLD')]=
            {targetName=stationName,targetFaction='BLUE',weaponClass='Mekhu HL-7',weaponSubtype='Laser',
             sourceKind='PROJECTILE',damageType='UNKNOWN',ballistic=false,beamWeapon=false,
             attackerFaction='GOLD',hitCount=8,shieldDamage=0,hullDamage=900}
          w[bucket(stationName,'AAAf','Laser','BEAM','RTS Capital Beam',false,true,'GOLD')]=
            {targetName=stationName,targetFaction='BLUE',weaponClass='AAAf',weaponSubtype='Laser',
             sourceKind='BEAM',damageType='RTS Capital Beam',ballistic=false,beamWeapon=true,
             attackerFaction='GOLD',hitCount=2,shieldDamage=0,hullDamage=35}
          r.ScenarioStartTime=0
          r:EmitOutcomeCause('BLUE',1200)
          assert(#emitted==1,'no OUTCOME_CAUSE record emitted')
          local o=emitted[1]
          assert(o.faction=='BLUE' and o.targetName==stationName)
          assert(#o.killers==2,'killers not listed: '..#o.killers)
          assert(o.killers[1].weapon=='Mekhu HL-7','wrong top killer: '..tostring(o.killers[1].weapon))
          assert(o.killers[1].attackerFaction=='GOLD','killer faction wrong')
          assert(o.totalAttributedHullDamage>900)
          assert(o.snapshot and o.snapshot.RED~=nil,'no per-faction snapshot')""")

    def test_outcome_cause_is_safe_with_no_damage_recorded(self):
        self.check("""r.CombatTelemetryEnabled=true
          local emitted={}
          local real=r.EmitAIEvent
          r.EmitAIEvent=function(self,name,data,t) if name=='OUTCOME_CAUSE' then emitted[#emitted+1]=data end return real(self,name,data,t) end
          r.BaseDamageTelemetry=nil
          r.ScenarioStartTime=0
          r:EmitOutcomeCause('GOLD',500)
          assert(#emitted==1 and #emitted[1].killers==0,'empty damage history broke the record')""")


class BaseAttackPursuitTests(unittest.TestCase):
    """A command station is on no hull's +Actively Pursues list, so ORDER_ATTACK
    on a base installs a chase goal the engine then refuses. Headless telemetry
    showed capitals and escorts assigned a PRIMARY attack stalling 10-12 km out
    for up to 17 minutes, while fighters assigned PRIMARY closed normally."""

    def setUp(self):
        self.lua = boot()
        self.check("r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0")

    def check(self, code):
        self.lua.execute(code)

    def test_a_command_station_counts_as_unpursued(self):
        self.check("""local station=mkStation(ba.createVector(20000,0,0))
          assert(r:IsCommandStation(station),'fixture is not a command station')
          assert(r:IsUnpursuedTarget(station),
            'a command station is not treated as unpursued, so ORDER_ATTACK will be used')""")

    def test_a_capital_attacking_a_base_uses_pursuit_not_chase(self):
        self.check("""local station=mkStation(ba.createVector(20000,0,0))
          local attacker=mkHull('GTCv Test',ba.createVector(0,0,0),'capital')
          assert(r:GetShipRole(attacker)=='capital','fixture role wrong: '..r:GetShipRole(attacker))
          assert(r:IsPursuitPair(attacker,station),
            'a capital attacking a base still uses ORDER_ATTACK, which the engine refuses')""")

    def test_an_escort_attacking_a_base_uses_pursuit(self):
        self.check("""local station=mkStation(ba.createVector(20000,0,0))
          local escort=mkHull('GTC EscortTest',ba.createVector(0,0,0),'escort')
          assert(r:GetShipRole(escort)=='escort','fixture role wrong: '..r:GetShipRole(escort))
          assert(r:IsPursuitPair(escort,station),
            'an escort attacking a base still uses ORDER_ATTACK')""")

    def test_mobile_enemies_still_pursue(self):
        """Only targets the engine will not chase should switch to pursuit; a
        capital attacking another capital is already covered by the pursue list."""
        self.check("""local other=mkHull('GTCv Other',ba.createVector(5000,0,0),'capital')
          assert(r:GetShipRole(other)=='capital')
          assert(not r:IsUnpursuedTarget(other),'a capital is actively pursued and must not change path')
          assert(not r:IsPursuitPair(mkHull('GTCv Attacker',ba.createVector(0,0,0),'capital'),other),
            'capital-vs-capital should keep the existing chase order')""")

    def test_a_subsystem_attack_never_takes_the_pursuit_path(self):
        """A waypoint carries no subsystem, so routing a turret-targeted attack
        into pursuit would silently degrade it to a hull-level attack."""
        self.check("""local station=mkStation(ba.createVector(20000,0,0))
          local attacker=mkHull('GTCv Test',ba.createVector(0,0,0),'capital')
          assert(r:IsPursuitPair(attacker,station),'precondition: capital on a base uses pursuit')
          assert(not r:IsPursuitPair(attacker,station,turboSubsystem),
            'a subsystem-targeted attack must keep the native ORDER_ATTACK')""")

    def test_fighters_against_a_base_still_take_the_chase_path(self):
        self.check("""local station=mkStation(ba.createVector(20000,0,0))
          local fighter=mkHull('GTF TestB',ba.createVector(0,0,0),'fighter')
          assert(r:GetShipRole(fighter)=='fighter','fixture role wrong: '..r:GetShipRole(fighter))
          assert(r:IsUnpursuedTarget(station))
          assert(not r:IsPursuitPair(fighter,station),
            'light hulls close on a base fine; they must keep the existing order')""")


class StationDefendOrderTests(unittest.TestCase):
    """The gate above is only worth having if every ORDER_ATTACK goes through
    it. STANDOFF was the one that did not, and it was on the player's fleet."""

    def setUp(self):
        self.lua = boot()
        self.check("r:ResetState(); r.SetupActive=false; r.GlobalPolicy='STANDOFF'; r.PolicyApplied={}")

    def check(self, code):
        self.lua.execute(code)

    def test_standoff_intercept_of_a_base_uses_pursuit_not_chase(self):
        """Regression: ApplyPolicyToShip called giveOrder(ORDER_ATTACK) directly,
        so a strike capital parked inside DefendRadius installed a chase goal the
        engine refuses and the player's fleet sat in guard orbits while the base
        was hit."""
        self.check("""local target=mkStation(ba.createVector(3000,0,0))
          local defender=mkHull('GTCv Defender',ba.createVector(0,0,0),'capital')
          assert(r:IsFriendly(defender),'fixture: defender is not a Blue hull')
          assert(r:IsPlayerEnemy(target),'fixture: target is not a player enemy')
          assert(r:AreEnemies(defender,target),'fixture: the pair is not hostile')
          assert(r:IsPursuitPair(defender,target),'fixture: the gate would not route this to pursuit')
          local issued={}
          function defender:giveOrder(o,t,s,p) issued[#issued+1]=o; return true end
          r:ApplyPolicyToShip(defender,true,target)
          assert(#issued==1,'STANDOFF issued '..#issued..' orders to the defender, expected 1')
          assert(issued[1]~=ORDER_ATTACK,
            'STANDOFF issued ORDER_ATTACK on a command station, which the engine refuses to pursue')
          assert(issued[1]==ORDER_WAYPOINTS_ONCE,
            'STANDOFF defender got no pursuit waypoint, got '..tostring(issued[1]))
          assert(r.AIPursuit[defender:getSignature()]~=nil,
            'the pursuit was not recorded, so nothing can re-anchor it')""")

    def test_standoff_keeps_the_chase_order_for_hulls_that_can_close(self):
        """The control for the test above: only the targets the engine will not
        chase switch paths. A fighter on a base still closes fine."""
        self.check("""local target=mkStation(ba.createVector(3000,0,0))
          local fighter=mkHull('GTF DefenderB',ba.createVector(0,0,0),'fighter')
          local issued={}
          function fighter:giveOrder(o,t,s,p) issued[#issued+1]=o; return true end
          r:ApplyPolicyToShip(fighter,true,target)
          assert(#issued==1 and issued[1]==ORDER_ATTACK,
            'a fighter must keep the native chase order, got '..tostring(issued[1]))""")

    def test_a_refused_pursuit_falls_back_to_guarding_the_station(self):
        """giveOrder always reports true, so a failed goal has to be detected by
        IssuePursuitOrder itself. When it reports failure the ship must not be
        left holding the order the engine refused."""
        self.check("""local target=mkStation(ba.createVector(3000,0,0))
          local defender=mkHull('GTCv DefenderC',ba.createVector(0,0,0),'capital')
          local issued={}
          function defender:giveOrder(o,t,s,p) issued[#issued+1]=o; return true end
          r.IssuePursuitOrder=function() return false end
          r:ApplyPolicyToShip(defender,true,target)
          assert(#issued==1 and issued[1]==ORDER_GUARD,
            'a refused pursuit left the defender with '..tostring(issued[1])..' instead of a station guard')""")

    def test_a_pursuiting_defender_is_rearmed_for_the_next_policy_pass(self):
        """A pursuit is anchored to a lead point and the goal ends on arrival.
        RefreshAIPursuit only re-anchors automatic AI units, so unless the policy
        marks the ship as needing a fresh order the interceptor reaches its
        anchor once and then holds a stale point while the threat sails away."""
        self.check("""local target=mkStation(ba.createVector(3000,0,0))
          local defender=mkHull('GTCv DefenderD',ba.createVector(0,0,0),'capital')
          local issued={}
          function defender:giveOrder(o,t,s,p) issued[#issued+1]=o; return true end
          local sig=defender:getSignature()
          r:ApplyPolicyToShip(defender,true,target)
          assert(r.PolicyApplied[sig]==nil,
            'the interceptor is marked as already policy-applied, so the pursuit is never re-anchored')
          assert(r.PolicyDefend[sig]==target:getSignature(),
            'the defend target was not recorded, so the refresh cannot re-issue this ship')
          -- The refresh must actually re-issue it, and only this ship.
          local before=#issued
          r:ApplyPolicyToShip(defender,false,target)
          assert(#issued==before+1,'the policy refresh did not re-anchor the pursuit')
          assert(issued[#issued]==ORDER_WAYPOINTS_ONCE,
            'the re-anchor issued '..tostring(issued[#issued]))
          -- A hull that is guarding the station is left alone.
          local holder=mkHull('GTCv Holder',ba.createVector(0,0,0),'capital')
          function holder:giveOrder(o,t,s,p) return true end
          r:ApplyPolicyToShip(holder,true,nil)
          assert(r.PolicyApplied[holder:getSignature()]=='STANDOFF',
            'a plain station guard is being re-armed every pass for no reason')""")

    def test_standoff_never_chooses_a_dying_station_as_the_defend_target(self):
        """IsPlayerEnemy is shipValid-only, so a hostile in death roll passed the
        old test and the whole fleet launched at a corpse that was already
        exploding."""
        self.check("""local radius=r.Config.Policy.DefendRadius or 6500
          assert(5000<=radius,'fixture: the live station is outside DefendRadius '..tostring(radius))
          local corpse=mkStation(ba.createVector(3000,0,0)); corpse.dying=true
          local live=mkStation(ba.createVector(5000,0,0))
          local picked=r:GetStationDefendTarget()
          assert(picked==live,'the defend target is a dying ship, not '..tostring(picked and picked.Name))
          live.dying=true
          assert(r:GetStationDefendTarget()==nil,
            'with every threat dying the fleet should hold the station, not chase')""")


class PostBattleScreenTests(unittest.TestCase):
    """The result screen has to stop the engine, not just the mod."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        self.lua.execute(code)

    def test_the_after_action_screen_stops_the_engine_clock(self):
        """Regression: SetTimeScale(0) without the allowZero flag is silently
        replaced by LastNonZeroTimeScale, so OnFrame's early return stopped the
        mod's systems while the ENGINE kept running the battle behind the
        overlay - ships flying, weapons firing."""
        self.check("""r:ResetState(); r.SetupActive=false
          r.TimeScale=8; r.LastNonZeroTimeScale=8
          sexps={}
          r:OpenPostBattle("ALL OPPOSING STATIONS DESTROYED")
          assert(r.PostBattleActive,'precondition: the result screen did not open')
          assert(r.TimeScale==0,'the time scale is still '..tostring(r.TimeScale)..' behind the result screen')
          assert(sexps[#sexps]=='(set-time-compression 0 0)',
            'the engine clock was not stopped; last SEXP was '..tostring(sexps[#sexps]))
          assert(r.Paused==false,
            'OpenPostBattle must not latch the mod pause: Esc is dead on this screen and RestartMission sets 1x, not unpaused')""")

    def test_restart_and_abort_still_restore_a_running_clock(self):
        self.check("""r:ResetState(); r.SetupActive=false
          r.TimeScale=8; r.LastNonZeroTimeScale=8
          sexps={}
          r:OpenPostBattle("BLUE STATION DESTROYED")
          r:RestartMission()
          assert(r.TimeScale==1,'restart left the clock at '..tostring(r.TimeScale))
          assert(sexps[#sexps]=='(set-time-compression 100 0)',
            'restart did not hand 1x back to the engine; last SEXP was '..tostring(sexps[#sexps]))
          sexps={}
          r:OpenPostBattle("BLUE STATION DESTROYED")
          r:ExitMissionToMenu()
          assert(sexps[#sexps]=='(set-time-compression 100 0)',
            'exit left the engine clock stopped at 0; last SEXP was '..tostring(sexps[#sexps]))""")


class BattleReportAccuracyTests(unittest.TestCase):
    """Item 11 follow-up: the report has to agree with the result that opened it."""

    def setUp(self):
        self.lua = boot()
        self.check("r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0")

    def check(self, code):
        self.lua.execute(code)

    def test_each_faction_row_reports_its_own_elimination_flag(self):
        """Regression: the flag was read with an and/or chain whose last term
        was not kind-guarded, so with BlueEliminated==false the expression fell
        through to GoldEliminated and reported a surviving BLUE as ELIMINATED
        whenever Gold happened to be dead."""
        self.check("""r.SetupOpponents={RED=true,GOLD=true}; r:UpdateFactionCount()
          r.BlueEliminated=false; r.RedEliminated=false; r.GoldEliminated=false
          local function flags(blue,red,gold)
            r.BlueEliminated=blue; r.RedEliminated=red; r.GoldEliminated=gold
            local seen={}
            for _,entry in ipairs(r:BuildBattleSummary().factions) do seen[entry.key]=entry.eliminated end
            return seen
          end
          for blue=0,1 do for red=0,1 do for gold=0,1 do
            local seen=flags(blue==1,red==1,gold==1)
            local want={BLUE=blue==1,RED=red==1,GOLD=gold==1}
            for _,kind in ipairs({'BLUE','RED','GOLD'}) do
              assert(seen[kind]==want[kind],kind..' row says eliminated='..tostring(seen[kind])
                ..' with the flags '..tostring(blue)..'/'..tostring(red)..'/'..tostring(gold))
            end
          end end end""")

    def test_the_report_never_calls_an_eliminated_faction_surviving(self):
        """A mutual kill: the player base and the last enemy base go in the same
        frame. Both losses must be recorded, and no row may claim a faction
        that is eliminated is still flying."""
        self.check("""local function liveFrame()
          r.Enabled=true; r.SetupActive=false; r.PostBattleActive=false; r.Paused=false
          r.CinematicActive=false; r.BattleCamActive=false; r.FreeCamActive=false
          r.FollowSignature=nil; r.PossessedSignature=nil; r.BattleVictor=nil
          r.SetupOpponents={RED=true,GOLD=true}; r:UpdateFactionCount()
          r.GoldEliminated=false
          ba.getRealFrametime=function() return 0.016 end
          r.OpenPostBattle=function(self,text) self.PostBattleActive=true; self.PostBattleResult=text end
          for _,name in ipairs({'EnforceCursorState','ObserveStationBeamHits','UpdateEconomy',
            'UpdateBuildQueue','UpdateEnemyWaves','UpdateAIProduction','UpdateStations',
            'UpdateFleetServices','UpdateMoveFacings','UpdateAIStrategicObjectives',
            'AuditWorldPositions','UpdateDefaultPolicy','ShowAnnouncement','UpdateCameraInput'}) do
            r[name]=function() end
          end
        end
        liveFrame()
        stations.BLUE.valid=false; stations.RED.valid=false
        r:OnFrame()
        assert(r.BlueEliminated and r.RedEliminated,
          'a same-frame mutual loss was only half recorded: '..tostring(r.BlueEliminated)..'/'..tostring(r.RedEliminated))
        assert(r.BattleSummary~=nil,'no report was taken at all')
        local live={BLUE=r.BlueEliminated,RED=r.RedEliminated,GOLD=r.GoldEliminated}
        for _,entry in ipairs(r.BattleSummary.factions) do
          if live[entry.key] then
            assert(entry.eliminated,
              entry.key..' is eliminated but its report row says SURVIVING // '..tostring(entry.ships)..' ships')
          end
        end""")

    def test_every_base_lost_on_one_frame_is_reported_as_mutual_destruction(self):
        """Regression: OnFrame eliminated BLUE first, and the BLUE branch of
        EvaluateFactionVictory opens the post-battle screen and sets
        PostBattleActive before either opponent is recorded. So a three-way
        mutual kill was announced to the player as 'BLUE STATION DESTROYED //
        BLUE FLEET DEFEATED' - the mod deciding the battle had a single cause
        when the whole board had gone in the same tick."""
        self.check("""r.Enabled=true; r.SetupActive=false; r.PostBattleActive=false; r.Paused=false
          r.CinematicActive=false; r.BattleCamActive=false; r.FreeCamActive=false
          r.FollowSignature=nil; r.PossessedSignature=nil; r.BattleVictor=nil
          r.SetupOpponents={RED=true,GOLD=true}; r:UpdateFactionCount()
          r.GoldEliminated=false
          ba.getRealFrametime=function() return 0.016 end
          r.OpenPostBattle=function(self,text) self.PostBattleActive=true; self.PostBattleResult=text end
          for _,name in ipairs({'EnforceCursorState','ObserveStationBeamHits','UpdateEconomy',
            'UpdateBuildQueue','UpdateEnemyWaves','UpdateAIProduction','UpdateStations',
            'UpdateFleetServices','UpdateMoveFacings','UpdateAIStrategicObjectives',
            'AuditWorldPositions','UpdateDefaultPolicy','ShowAnnouncement','UpdateCameraInput'}) do
            r[name]=function() end
          end
          stations.BLUE.valid=false; stations.RED.valid=false; stations.GOLD.valid=false
          r:OnFrame()
          assert(r.BlueEliminated and r.RedEliminated and r.GoldEliminated,
            'not every loss on the frame was recorded: '..table.concat({
              tostring(r.BlueEliminated),tostring(r.RedEliminated),tostring(r.GoldEliminated)},'/'))
          assert(r.PostBattleResult:find('MUTUAL')~=nil,
            'the result screen blames one faction for a mutual kill: '..tostring(r.PostBattleResult))
          assert(r.BattleVictor=='NONE',
            'a mutual kill was credited to a victor: '..tostring(r.BattleVictor))""")


class HudClaimTests(unittest.TestCase):
    """The HUD is how the player finds out what a key or a system does. Every
    line here is checked against the code that runs it."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        self.lua.execute(code)

    def test_the_top_bar_does_not_claim_the_tiers_run_on_real_time(self):
        """Escalation runs on mission time; the wall-clock tier accumulator was
        removed because it was the one thing the speed control did not touch.
        Saying otherwise is the same lie test_ai_escalation guards against."""
        self.check("""r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0
          r.TimeScale=8; r.LastNonZeroTimeScale=8
          r.GetEscalationProfile=function(self) return self.Config.Escalation end
          r.GetScenarioElapsed=function() return 600 end
          r.CountFriendlyCombatants=function() return 0 end
          r.CountHostiles=function() return 0 end
          local texts=captureStrings(function() r:DrawTopBar(1920) end)
          assert(not anyContains(texts,'real time'),
            'the top bar still advertises a real-time tier clock: '..joinAll(texts))
          assert(anyContains(texts,'Tiers + income: 8x mission time'),
            'the top bar does not state the speed the whole game runs at: '..joinAll(texts))""")

    def test_the_control_legend_matches_the_speed_ladder_the_keys_select(self):
        """1/2/3/4/0 select 1x/2x/4x/8x/16x outright. The legend still described
        the old relative slower/pause/faster/reset scheme, so the player was
        told the wrong thing about the control they are deciding with."""
        self.check("""r:ResetState(); r.ShowHotkeyHints=true
          local texts=captureStrings(function() r:DrawControls(1920,1080) end)
          assert(#texts>0,'the control legend drew nothing; the panel geometry is wrong')
          assert(anyContains(texts,'Alt+1/2/3/4/0 = 1x/2x/4x/8x/16x speed') and anyContains(texts,'Shift+1-4 assign'),
            'the legend does not describe the absolute ladder: '..joinAll(texts))
          assert(not anyContains(texts,'time slower / pause / faster'),
            'the legend still advertises the old relative ladder: '..joinAll(texts))""")

    def test_the_orbital_strike_tooltip_reads_the_strike_config(self):
        """Four magic numbers were hardcoded in the tooltip and had already
        drifted from Station.Ability.BLUE, and the 250 m no-damage core was left
        out of the line whose whole point is the friendly-fire warning."""
        self.check("""r:ResetState()
          local ability=r.Config.Station.Ability.BLUE
          local saved={}
          for key,value in pairs(ability) do saved[key]=value end
          ability.delay=17; ability.radius=1234; ability.innerRadius=321; ability.damage=4321; ability.range=15000
          r.StationButtonRects={ability={x1=0,y1=0,x2=10,y2=10}}
          io.getMouseX=function() return 5 end; io.getMouseY=function() return 5 end
          local texts=captureStrings(function() r:DrawStationTooltip({x1=600,y1=0,x2=1200,y2=600}) end)
          for key,value in pairs(saved) do ability[key]=value end
          assert(anyContains(texts,'17'),'the delay is not read from config: '..joinAll(texts))
          assert(anyContains(texts,'4321'),'the blast damage is not read from config: '..joinAll(texts))
          assert(anyContains(texts,'1234'),'the blast radius is not read from config: '..joinAll(texts))
          assert(anyContains(texts,'321'),
            'the no-damage inner radius is not shown, so the friendly-fire warning has no scale: '..joinAll(texts))
          assert(anyContains(texts,'15'),'the range is not read from config: '..joinAll(texts))""")

    def test_station_tooltip_text_stays_inside_its_box(self):
        self.check('''r:ResetState()
          io.getMouseX=function() return 5 end; io.getMouseY=function() return 5 end
          local realgr=gr
          for _,size in ipairs({{1920,1080},{800,600}}) do
            for _,key in ipairs({'station','track_defenses','track_command','track_logistics','ability','sentry_1','sell'}) do
              r.StationButtonRects={[key]={x1=0,y1=0,x2=10,y2=10}}
              local box; local rows={}
              gr=setmetatable({getScreenWidth=function() return size[1] end,
                getScreenHeight=function() return size[2] end,
                getStringWidth=function(text) return #tostring(text)*8 end,
                drawRectangle=function(x1,y1,x2,y2,filled) if filled then box={x1,y1,x2,y2} end end,
                drawString=function(text,x,y) rows[#rows+1]={text,x,y} end}, {__index=realgr})
              r.DrawRotatingModel=function() end
              r:DrawStationTooltip({x1=size[1]-300})
              assert(box and #rows>0,'tooltip not exercised: '..key)
              assert(box[1]>=0 and box[3]<=size[1] and box[2]>=0 and box[4]<=size[2],'box outside screen')
              for _,row in ipairs(rows) do
                assert(row[2]>=box[1] and row[2]+#row[1]*8<=box[3],'text overflows width: '..key..' '..row[1])
                assert(row[3]>=box[2] and row[3]+16<=box[4],'text overflows height: '..key)
              end
            end
          end
          gr=realgr''')

    def test_gtva_badge_does_not_draw_an_opaque_backdrop(self):
        self.check('''r:ResetState()
          r.GetFactionProfile=function() return r.Config.FactionProfiles.GTVA end
          r.LoadBriefingIcon=function() return {getWidth=function() return 64 end,getHeight=function() return 64 end} end
          local rectangles,images=0,0
          gr.drawRectangle=function() rectangles=rectangles+1 end
          gr.drawImage=function() images=images+1 end
          assert(r:DrawFactionInsignia('BLUE',0,0,32,32))
          assert(images==1 and rectangles==0,'badge has an opaque background')''')

    def test_restart_releases_the_live_world_before_native_teardown(self):
        self.check('''r:ResetState(); r.Enabled=true
          local events={}
          r.SetTimeScale=function() end
          ba.GameEvents={GS_EVENT_START_GAME={}}
          ba.postGameEvent=function() events[#events+1]='posted'; return true end
          r.Shutdown=function(self) events[#events+1]='released'; self.Enabled=false end
          r:RestartMission()
          assert(events[1]=='posted' and events[2]=='released' and not r.Enabled,
            'restart leaves live handles for cleanup after native mission teardown')
          events={}; r.Enabled=true; ba.postGameEvent=function() return false end
          r:RestartMission()
          assert(r.Enabled and #events==0,'rejected restart tore down the playable world')''')

    def test_the_pilot_panel_background_covers_every_row_it_draws(self):
        """The height was 26+lines*18 while the first row starts at y1+29, so
        the panel background stopped three pixels short of its own last line."""
        self.check("""r:ResetState()
          r.GetPossessedShip=function() return mkFighter() end
          r.GetPilotTargetSubsystemLabel=function() return '' end
          local realgr=gr
          local function panelBottom(groups,index,subsystem,firing)
            r.PilotTurretGroups=groups; r.PilotTurretGroupIndex=index
            r.GetPilotTargetSubsystemLabel=function() return subsystem end
            r.PilotTurretFiring=firing
            local box,row
            gr={loadTexture=realgr.loadTexture,drawImage=realgr.drawImage,setColor=function() end,
              drawRectangle=function(x1,y1,x2,y2) box=y2 end,
              drawString=function(text,x,y) row=math.max(row or 0,y+9) end,
              getStringHeight=function() return 9 end,
              getStringWidth=function(text) return #text*6 end}
            r:DrawPilotHUD(1920,1080); gr=realgr
            return box,row
          end
          local cases={
            {nil,nil,'',false,'no turret groups'},
            {nil,nil,'',true,'no groups, firing'},
            {nil,nil,'SUBSYSTEM 2/4',false,'no groups, subsystem'},
            {{{label='A',turrets={}}},1,'',false,'one group'},
            {{{label='A',turrets={}}},1,'SUBSYSTEM 2/4',false,'one group, subsystem'},
            {{{label='A',turrets={}}},1,'SUBSYSTEM 2/4',true,'one group, subsystem, firing'},
          }
          for _,case in ipairs(cases) do
            local box,row=panelBottom(case[1],case[2],case[3],case[4])
            assert(box~=nil and row~=nil,case[5]..': the pilot panel drew nothing')
            assert(box>=row,
              case[5]..': panel background ends at '..tostring(box)..' but a row is drawn to '..tostring(row))
          end""")

    def test_dead_click_rect_tables_are_not_rebuilt_every_frame(self):
        """SentryRects and AbilityButtonRects were reset on every HUD frame and
        read nowhere: two table allocations per frame for a hover hit-test that
        does not exist."""
        source = module_text(SCRIPTS, "fs2rts_hud")
        for name in ("SentryRects", "AbilityButtonRects"):
            self.assertNotIn(name, source,
                             f"{name} is written every frame and read nowhere; drop the reset or add the hit-test")


if __name__ == '__main__':
    unittest.main()
