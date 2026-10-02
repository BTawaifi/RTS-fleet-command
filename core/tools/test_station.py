"""Station regression checks using the shipped Lua and Lua 5.1 (Python lupa).

Run: python core/tools/test_station.py
       python -m pytest core/tools/test_station.py
Point at another core/data/scripts with the RTS_SCRIPTS_OVERRIDE environment
variable, matching test_ai_concentration, test_ai_assault_doctrine and
test_telemetry_contracts.

Do NOT sniff sys.argv for that path. This used to, guarded by is_dir(), and
`pytest tools` or `pytest core/tools` passes a DIRECTORY as argv[1], so the
override fired, SCRIPTS became the tools folder, and every test in every suite
that requires fs2rts failed with "module 'fs2rts' not found" - 226 failures from
one invocation change. Bare `pytest` passes no argv[1], which is why the same
commit looked green from the repo root and broken from core/. An environment
variable cannot be set by accident by a test runner.
Engine objects below are boundary doubles; this does not replace an FSO run.
"""
import os
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

# test_service.py, test_hud_perf.py, test_hud_layout.py and
# test_feature_request.py import SCRIPTS from here, so this stays import-time
# safe: resolve it once, from __file__, never from process state.
SCRIPTS = (Path(os.environ['RTS_SCRIPTS_OVERRIDE'])
           if os.environ.get('RTS_SCRIPTS_OVERRIDE')
           else Path(__file__).resolve().parents[1] / 'data/scripts')

SETUP = r'''
local V = {}; V.__index = V
function V.__add(a,b) return ba.createVector(a.x+b.x,a.y+b.y,a.z+b.z) end
function V.__sub(a,b) return ba.createVector(a.x-b.x,a.y-b.y,a.z-b.z) end
function V.__mul(a,b) return ba.createVector(a.x*b,a.y*b,a.z*b) end
function V.__div(a,b) return ba.createVector(a.x/b,a.y/b,a.z/b) end
function V.__unm(a) return ba.createVector(-a.x,-a.y,-a.z) end
-- FSO's l_Vector is a full arithmetic userdata (verified in the engine tree:
-- __add/__sub/__mul/__div/__unm). A partial double here made a vector
-- subtraction inside a reached function fail with "attempt to perform
-- arithmetic on a table" instead of the assertion the test actually cares
-- about, so the harness defined the whole set rather than the one operator
-- the first caller happened to need.
function V:getDistance(b) return math.sqrt((self.x-b.x)^2+(self.y-b.y)^2+(self.z-b.z)^2) end
function V:getScreenCoords() return self.x,self.z end
function V:getOrientation() return {} end
ba={createVector=function(x,y,z) return setmetatable({x=x,y=y,z=z},V) end,print=function() end}
-- createOrientationFromVectors([fvec, uvec, rvec]) -> orientation.
-- Argument order matters and the mod got it wrong once, so this double follows
-- the engine exactly rather than being conveniently permissive:
--   base.cpp:179     "[vector fvec, vector uvec, vector rvec]"
--   vecmat.cpp:898   *zvec = *fvec   (the first vector BECOMES m.vec.fvec)
-- Passing (0,-1,0) as fvec therefore produces a hull whose nose points at the
-- floor, which is what the old sentry aiming code did. Anything else that
-- asserts on facing must be able to catch that, so this double does not
-- normalise or reorder anything.
ba.createOrientationFromVectors=function(fvec,uvec,rvec)
  local o={vec={fvec=ba.createVector(fvec.x,fvec.y,fvec.z),
                 uvec=ba.createVector(0,1,0),rvec=ba.createVector(1,0,0)}}
  if uvec then o.vec.uvec=ba.createVector(uvec.x,uvec.y,uvec.z) end
  if rvec then o.vec.rvec=ba.createVector(rvec.x,rvec.y,rvec.z) end
  return o
end
now=0; serial=0; ships={}; stations={}; spawnFails=false
mn={getMissionTime=function() return now end, Ships={}, Teams={}}
tb={ShipClasses={},FireballClasses={{}}}
-- The four RTS-owned sentry weapons are registered here with the reach and
-- damage values core/data/tables/fs2rts-sentry-wep.tbm actually declares, so
-- GetSentryWeaponRange reads real numbers in tests rather than falling back to
-- the config range and passing vacuously. test_sentry_loadout.py proves these
-- values match the shipped table file.
local valid=function(self) return self.valid~=false end
for _,name in ipairs({'friendly','hostile','neutral'}) do
  mn.Teams[name]={Name=name,isValid=valid,attacks=function(a,b) return a~=b end}
end
function class(name)
  local c={Name=name,HitpointsMax=1000,ShieldHitpointsMax=0,Model={Radius=100},VelocityMax=ba.createVector(0,0,100),isValid=valid}
  tb.ShipClasses[name]=c; return c
end
function ship(name,c,pos,team)
  serial=serial+1
  -- Orientation is a plain stored field here, defaulting to facing +Z. The
  -- arc assertions read made.Orientation, so mn.createShip has to carry the
  -- orientation it was handed through onto the double.
  local s={Name=name,Class=c,Position=pos,Team=team,HitpointsMax=c.HitpointsMax,HitpointsLeft=c.HitpointsMax,
    Physics={VelocityMax=ba.createVector(0,0,100),AfterburnerVelocityMax=ba.createVector(0,0,150)},isValid=valid,signature=serial,
    Orientation=ba.createOrientationFromVectors(ba.createVector(0,0,1))}
  function s:getSignature() return self.signature end
  function s:getBreedName() return 'Ship' end
  function s:isDying() return self.dying==true end
  function s:getFlag(flag) return self.flags and self.flags[flag] or false end
  function s:clearOrders() end
  function s:giveOrder() return true end
  function s:setFlag() end
  function s:warpIn() end
  function s:vanish() self.valid=false end
  function s:kill() self.HitpointsLeft=0 end
  s[1]={FireRateMultiplier=1,PrimaryBanks={},isTurret=function() return true end,isValid=valid}
  s[1].SecondaryBanks={}; s[1].HitpointsMax=100; s[1].HitpointsLeft=100; s[1].WorldPosition=pos
  local w={Name='test laser',Damage=10,FireWait=1,Speed=100,LifeMax=5,Range=500,isValid=valid,isBeam=function() return false end}
  -- The bank has to hang off the TURRET, not just the ship: CreateSentry walks
  -- ship[i].PrimaryBanks to install the sentry weapon, so a turret with an
  -- empty bank list makes every installed-weapon assertion vacuous.
  s[1].PrimaryBanks={{WeaponClass=w,AmmoMax=0,isValid=valid}}
  s.PrimaryBanks={{WeaponClass=w,AmmoMax=0,isValid=valid}}; s.SecondaryBanks={}
  s.Shields={CombinedLeft=0}; s.Radius=100
  ships[#ships+1]=s; mn.Ships[name]=s; mn.Ships[#mn.Ships+1]=s
  return s
end
mn.createShip=function(name,c,orientation,pos,team)
  if spawnFails then return nil end
  local s=ship(name,c,pos,team)
  if orientation then s.Orientation=orientation end
  return s
end
mn.createExplosion=function() end
-- Real FSO scripting APIs (code/scripting/api/libs/mission.cpp). The AI pursuit
-- path drives a move waypoint through them, so the double has to provide them
-- or every pursuit test dies on a nil call that the engine would not.
-- The creation counters are load-bearing: GetOrCreateMoveWaypoint owns a
-- per-ship cache and recycles dead ships' waypoint lists, and the only way to
-- tell "reused the cache" from "recreated the waypoint" from the outside is to
-- count the engine calls.
waypointLists={}; waypoints={}; waypointSerial=0
mn.createWaypointList=function(name) waypointLists[#waypointLists+1]=name; return {name=name,isValid=function() return true end} end
-- l_Waypoint exposes getSignature(); fs2rts_service.lua:195 compares the live
-- order's target signature against the cached waypoint's, so a double without
-- it makes the real service move path die on a nil method.
mn.createWaypoint=function(pos,list)
  waypointSerial=waypointSerial+1
  local w={Position=pos,List=list,signature=500000+waypointSerial}
  function w:isValid() return self.valid~=false end
  function w:getSignature() return self.signature end
  waypoints[#waypoints+1]={pos=pos,list=list,waypoint=w}
  return w
end
sexps={}; mn.runSEXP=function(s) sexps[#sexps+1]=s; return true end
r=require('fs2rts')
r:ResetState(); r.SetupActive=false; r.ScenarioStartTime=0; r.SetupOpponents={RED=true,GOLD=true}
r.CommandPoints=10000; r.AIStates={RED={cp=10000},GOLD={cp=10000},BLUE={cp=10000}}
r.AutoPlayerMode=false
for kind,name in pairs({BLUE=r.Config.CarrierShip,RED=r.Config.EnemyCommandShip,GOLD=r.Config.ThirdCommandShip}) do
  local team=mn.Teams[({BLUE='friendly',RED='hostile',GOLD='neutral'})[kind]]
  stations[kind]=ship(name,class(name),ba.createVector(kind=='BLUE' and 0 or (kind=='RED' and 9000 or -9000),0,0),team)
  stations[kind].HitpointsMax=10000; stations[kind].HitpointsLeft=10000
  for _,entry in ipairs(r.Config.Station.Sentries.Classes[kind]) do class(entry.class); r.ShipCostMap[entry.class]={cost=100,time=10} end
end
class('GVCv Sobek')
r:ResetStationState()
-- UpdateStationAI is stubbed out for the whole suite because it drives a large
-- amount of economy and production state that most station tests do not care
-- about. The real function is NOT therefore uncovered: the captured reference
-- below (stationAI) is called directly by the AI spending tests, which cover
-- its production, sentry and capital-saving decisions. What the global stub
-- hides is only the interaction between UpdateStations and the real function,
-- so test_ai_never_spends_player_cp_from_the_real_station_ai covers exactly
-- that and no more.
stationAI=r.UpdateStationAI; r.UpdateStationAI=function() end
-- Real economy-flow recorder, captured before the stub below. The CP ledger
-- (CP_SPEND, emitted from RecordAIEconomyFlow) is what makes station upgrade and
-- orbital-strike spending attributable, and a test can only prove a sink ROUTES
-- THROUGH the chokepoint if the chokepoint itself is real.
realRecordAIEconomyFlow=r.RecordAIEconomyFlow
r.RecordAIEconomyFlow=function() end
r.GetShipList=function() return ships end
r.EachShip=function(self,fn) for _,s in ipairs(ships) do if s:isValid() then fn(s) end end end
-- The scan below is what most tests want, but the stale-signature tests need the
-- real engine lookup, so keep a handle on it before it is replaced.
realFindShipBySignature=r.FindShipBySignature
r.FindShipBySignature=function(self,sig) for _,s in ipairs(ships) do if s.signature==sig and s:isValid() then return s end end end
signatureObjects={}
mn.getObjectFromSignature=function(sig) return signatureObjects[sig] end
r.GetFactionCommandShip=function(self,kind) return stations[kind] end
r.GetCarrier=function() return stations.BLUE end
r.GetShipRole=function(self,s) return s.role or 'capital' end
r.GetCurrentEscalationTier=function() return tier or 4 end
r.GetDurationProfile=function() return {buildTimeScale=1} end
r.AssignAIStrategicOrder=function() end
r.EnableFullArsenal=function() end
r.NativeGetSpawnFrame=r.GetSpawnFrame
r.GetSpawnFrame=function(self,anchor) return anchor.Position,nil end
option=r:GetSentryOptions('BLUE')[1]; pos=ba.createVector(1000,0,0)
'''


class ScriptsPathTests(unittest.TestCase):
    def test_the_scripts_path_actually_contains_the_module(self):
        """If SCRIPTS is wrong, every require in this suite fails identically.

        That is what happened: SCRIPTS was derived from sys.argv[1], so
        `pytest tools` silently repointed it at the tools directory and 226
        tests failed with "module 'fs2rts' not found" while `pytest` from the
        repo root passed. One assertion catches that class of mistake at its
        source and says which directory was wrong.
        """
        self.assertTrue(
            (SCRIPTS / "fs2rts.lua").is_file(),
            f"SCRIPTS is {SCRIPTS}, which does not contain fs2rts.lua; "
            "every harness that requires the module will fail")


class StationTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(SETUP)

    def check(self, code):
        self.lua.execute(code)

    def test_purchase_deadline_and_no_double_charge(self):
        self.check("""assert(r:BuyUpgrade('BLUE','armor')); assert(r.CommandPoints==9375)
          assert(not r:BuyUpgrade('BLUE','logistics')); assert(r.CommandPoints==9375)
          now=29.99; r:UpdateStations(now); assert(stations.BLUE.HitpointsMax==10000)
          now=30; r:UpdateStations(now); assert(stations.BLUE.HitpointsMax==12000)
          r:UpdateStations(now); assert(stations.BLUE.HitpointsMax==12000)""")

    def test_builder_ship_type_filter_includes_matching_hulls(self):
        self.check("""r.BuildCatalog={{class='fighter',role='fighter'},{class='bomber',role='bomber'},
            {class='heavy',role='heavy'},{class='juggernaut',role='juggernaut'}}
          r.BuildRoleFilter='capital'; local visible=r:GetVisibleBuildCatalog()
          assert(#visible==2 and visible[1].option.class=='heavy' and visible[2].option.class=='juggernaut')
          r.BuildRoleFilter='bomber'; visible=r:GetVisibleBuildCatalog()
          assert(#visible==1 and visible[1].option.class=='bomber')""")

    def test_upgrade_rejections_and_cumulative_effects(self):
        self.check("""r.CommandPoints=0; assert(not r:BuyUpgrade('BLUE','armor'))
          r.CommandPoints=10000; tier=1; r.StationState.BLUE.levels.armor=1
          assert(not r:BuyUpgrade('BLUE','armor')); assert(r.CommandPoints==10000)
          tier=4; r.StationState.BLUE.levels.armor=0
          for i=1,3 do assert(r:BuyUpgrade('BLUE','armor')); now=r.StationState.BLUE.upgrade.finishTime; r:UpdateStations(now) end
          assert(math.abs(stations.BLUE.HitpointsMax-16000)<0.001)
          assert(not r:BuyUpgrade('BLUE','armor'))""")

    def test_dead_station_cannot_buy_or_use_ability(self):
        self.check("""stations.BLUE.HitpointsLeft=0; r.StationState.BLUE.levels.command=3
          assert(not r:BuyUpgrade('BLUE','armor')); assert(not r:IsAbilityReady('BLUE'))
          assert(not r:PlaceSentry('BLUE',option,pos,false)); assert(r.CommandPoints==10000)""")

    def test_damage_on_upgrade_completion_delays_repair(self):
        self.check("""r.StationState.BLUE.levels.armor=1; stations.BLUE.HitpointsMax=12000; stations.BLUE.HitpointsLeft=12000
          assert(r:BuyUpgrade('BLUE','armor')); r:UpdateStations(0)
          stations.BLUE.HitpointsLeft=11900; now=60; r:UpdateStations(now)
          assert(r.StationState.BLUE.lastDamageAt==60)
          local hull=stations.BLUE.HitpointsLeft; local deadline=60+r.Config.Station.ArmorRepairDelay
          now=deadline-.1; r:UpdateStations(now); assert(stations.BLUE.HitpointsLeft==hull)
          now=deadline; r:UpdateStations(now); assert(stations.BLUE.HitpointsLeft==hull)
          now=deadline+.1; r:UpdateStations(now); assert(stations.BLUE.HitpointsLeft>hull)""")

    def test_fractional_damage_keeps_out_of_combat_repair_delayed(self):
        self.check("""r.StationState.BLUE.levels.armor=2
          stations.BLUE.HitpointsLeft=5000; r.StationState.BLUE.lastHull=5000
          r.StationState.BLUE.lastDamageAt=0
          stations.BLUE.HitpointsLeft=4999.75; now=10; r:UpdateStations(now)
          assert(r.StationState.BLUE.lastDamageAt==10 and stations.BLUE.HitpointsLeft==4999.75)
          stations.BLUE.HitpointsLeft=4999.5; now=11; r:UpdateStations(now)
          now=11+r.Config.Station.ArmorRepairDelay-.001; r:UpdateStations(now); assert(stations.BLUE.HitpointsLeft==4999.5)
          now=11+r.Config.Station.ArmorRepairDelay+.1; r:UpdateStations(now); assert(stations.BLUE.HitpointsLeft>4999.5)""")

    def test_raid_damage_leaves_permanent_station_scars(self):
        self.check("""r.StationState.BLUE.levels.armor=2; r:UpdateStations(0)
          stations.BLUE.HitpointsLeft=8000; now=1; r:UpdateStations(now)
          now=1000; r:UpdateStations(now)
          assert(math.abs(stations.BLUE.HitpointsLeft-9200)<.001,'quiet repair erased raid progress')
          assert(math.abs(r.StationState.BLUE.scarHull-800)<.001)
          now=2000; r:UpdateStations(now); assert(math.abs(stations.BLUE.HitpointsLeft-9200)<.001)
          local oldMax=stations.BLUE.HitpointsMax; local oldScar=r.StationState.BLUE.scarHull
          r:ApplyUpgrade('BLUE','armor',3)
          assert(math.abs(r.StationState.BLUE.scarHull-oldScar*stations.BLUE.HitpointsMax/oldMax)<.001,
            'armor upgrade erased proportional scars')""")

    def test_feint_uses_only_an_unengaged_enemy_fighter(self):
        self.check("""local primary=stations.RED
          local probe=ship('Friendly feint probe',class('GTF Hercules'),ba.createVector(10000,0,0),stations.BLUE.Team)
          local nearby=ship('Nearby decoy target',class('GTF Ulysses'),ba.createVector(9200,0,0),stations.RED.Team)
          local distant=ship('Distant decoy target',class('GTF Perseus'),ba.createVector(11000,0,0),stations.RED.Team)
          r.GetShipRole=function() return 'fighter' end
          r.GetStrategicUnitValue=function(self,s) return s==nearby and 1000 or 50 end
          r.StrategicThreatSnapshot={{ship=nearby},{ship=distant}}
          r.AITargetedBy={}
          assert(r:ChooseAIFeintTarget('BLUE',primary,5000)==nearby,
            'feint should choose the nearby unengaged hostile fighter')
          r.AITargetedBy[nearby:getSignature()]={BLUE={[probe:getSignature()]=probe}}
          assert(r:ChooseAIFeintTarget('BLUE',primary,5000)==distant,
            'feint should avoid a fighter already engaged by its faction')
          r.AITargetedBy[distant:getSignature()]={BLUE={[probe:getSignature()]=probe}}
          assert(r:ChooseAIFeintTarget('BLUE',primary,5000)==primary,
            'feint should keep the primary objective when no decoy target is available')""")

# ---- sentry reach and arc ------------------------------------------------
    # Both of these exist because a headless batch (capgate-20261001, 4 matches,
    # 14,635 UNIT samples) measured the ring spending its life out of contact:
    # 2.95% of attacker-time fell inside any built sentry's reach, and 80.2% of
    # the damage reaching a station arrived from a weapon firing at a median
    # 10,622 m. See the geometry note in core/data/tables/fs2rts-sentry-wep.tbm.

    def test_upgrades_do_not_zero_sentry_damage(self):
        """ApplySentryHullBonus / ApplyDefenseFireRate must not disarm the ring.

        Both run on every completed sentry. FireRateMultiplier in particular has
        a documented zero-sentinel in the engine, so a boost written without
        that guard silently stalls exactly the turrets the upgrade claims to
        cover.
        """
        self.check("""r.StationState.BLUE.levels.defenses = 3
        local opt = r:GetSentryOptions('BLUE')[1]
        assert(r:PlaceSentry('BLUE', opt, ba.createVector(4000,0,0), true))
        local sentry = r:GetFactionSentries('BLUE')[1]
        assert(sentry, 'sentry missing')
        local function totalDamage()
          local sum = 0
          for i=1,#sentry do
            local t = sentry[i]
            if t and t:isValid() and t:isTurret() then
              for b=1,#t.PrimaryBanks do
                local bank = t.PrimaryBanks[b]
                if bank and bank:isValid() and bank.WeaponClass and bank.WeaponClass:isValid() then
                  sum = sum + (bank.WeaponClass.Damage or 0)
                end
              end
            end
          end
          return sum
        end
        local base = totalDamage()
        assert(base > 0, 'nothing to damage with before upgrades')
        r:ApplySentryHullBonus(sentry)
        r:ApplyDefenseFireRate(sentry)
        local turrets = 0
        for i=1,#sentry do
          local t = sentry[i]
          if t and t:isValid() and t:isTurret() then
            assert((t.FireRateMultiplier or 0) > 0,
              'ApplyDefenseFireRate wrote the rof_scaler zero sentinel')
            turrets = turrets + 1
          end
        end
        assert(turrets >= 1, 'no turret to check after upgrades')
        local after = totalDamage()
        assert(after == base, string.format(
          'upgrades changed sentry damage %s -> %s; they must scale hull and rate only',
          tostring(base), tostring(after)))""")

    def test_sentry_aim_scan_uses_the_numeric_ship_idiom_not_ipairs(self):
        """RED on `ipairs(mn.Ships)`, which aborts the engine PROCESS.

        Measured, not inferred. Bisected against fs2_open_26_1_0_x64_AVX2 by
        inserting each form into capgate's CreateSentry, changing nothing else:

            for _,o in ipairs(mn.Ships or {}) do n=n+1 end
                -> exit 0xE06D7363 (C++ exception), ~310 s into a headless run,
                   before the first sentry finishes construction
            for i=1,#mn.Ships do local o=mn.Ships[i] ... end
                -> exit 0

        A C++ exception is not a Lua error, so NOTHING in this suite can see
        it: every unit test in the repo passes with the crashing form in place.
        Only the engine batch catches it, which is how it was found. This is the
        one automated guard available for it, and it works by asserting the
        SOURCE shape rather than by executing anything, so it has to be
        maintained deliberately - do not "simplify" the loop back to ipairs.

        The second assertion keeps the scan present, so the first cannot be
        satisfied by deleting the feature.
        """
        source = (SCRIPTS / "fs2rts_station.lua").read_text(encoding="utf-8")
        # Strip Lua comments before asserting. The doc comment above the scan
        # quotes the crashing line verbatim so the next reader knows what not to
        # write, and a plain substring search would then match its own
        # explanation and be unsatisfiable.
        code = []
        for line in source.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("--"):
                continue
            code.append(line.split("--")[0])
        live = "\n".join(code)
        self.assertNotIn(
            "ipairs(mn.Ships", live,
            "ipairs(mn.Ships) crashes fs2_open with a C++ exception")
        self.assertIn(
            "for i=1,#mn.Ships do", live,
            "SentryAimVector's numeric ship scan is missing")

    def test_every_sentry_role_aims_at_the_hostile_not_the_station(self):
        """RED on the beam-only orientation: ALL roles must aim at a hostile.

        The defect was `if option.role=="beam" then` around the orientation
        override, which left 99.26% of the ring - every screen/flak/missile hull
        built in capgate - inheriting station.Orientation, measured 30 deg off the
        enemy axis before placement scatter and p50 bearing error 29-37 deg (max
        55 deg) once scattered. Turret FOV is a hard engine gate
        (aiturret.cpp:2667 requires in_fov before the shot), so a hull pointed
        away cannot fire at a target it is already in range of.
        """
        self.check("""local kind = 'BLUE'
        -- BLUE's station is at the origin and RED's at +9,000 in this harness.
        -- Put a RED contact much closer to the sentry than RED's own station,
        -- so "nearest hostile hull" is unambiguously the contact and not the
        -- station the old beam branch used to aim at.
        local contact = ship('RED raider', class('GTF Hercules'), ba.createVector(4500,0,600), stations.RED.Team)
        assert(contact, 'could not create a hostile contact')
        for _,opt in ipairs(r:GetSentryOptions(kind)) do
          local here = ba.createVector(4000,0,0)
          local made = r:CreateSentry(kind, opt, here, true)
          assert(made, opt.class..' failed to create')
          local orient = made.Orientation or {}
          local f = orient.vec and orient.vec.fvec or nil
          assert(f, opt.class..' has no readable orientation')
          -- Exact bearing, not a sign: a sign check would pass on a hull aimed
          -- at RED's station as well. This also catches the inverted call
          -- createOrientationFromVectors(vec(0,-1,0), aim), which put the aim
          -- in uvec and left fvec pointing at the floor.
          local dx = contact.Position.x - here.x
          local dz = contact.Position.z - here.z
          local len = math.sqrt(dx*dx + dz*dz)
          local dot = ((f.x or 0)*dx + (f.y or 0)*0 + (f.z or 0)*dz) / len
          assert(dot > 0.999, string.format(
            '%s role=%s aimed at fvec(%.3f,%.3f,%.3f); the hostile is at bearing (%.3f,%.3f), dot=%.3f',
            opt.class, tostring(opt.role), f.x, f.y, f.z, dx/len, dz/len, dot))
        end""")

    def test_sentry_aim_prefers_the_nearest_hostile_hull_over_the_nearest_station(self):
        """Three-way boards: aiming at the nearest STATION can aim at the wrong
        faction, so the nearest live hostile hull must win."""
        self.check("""-- GOLD station is at -X in this harness and its contact is 20 km away;
        -- put a RED contact right next to where the sentry will be.
        local goldContact = ship('GOLD raider', class('GVF Tauret'), ba.createVector(-20000,0,-9000), stations.GOLD.Team)
        local redContact  = ship('RED raider', class('GTF Hercules'), ba.createVector(3000,0,900), stations.RED.Team)
        assert(goldContact and redContact)
        local here = ba.createVector(4000,0,0)
        local x, z = r:SentryAimVector('BLUE', here)
        assert(x and z, 'SentryAimVector returned no direction')
        -- The expected aim is the unit vector from the sentry to the NEAR
        -- hostile hull, which here is RED's contact 1.3 km away and not GOLD's
        -- at 24 km. Asserting the exact bearing is stronger than asserting a
        -- sign: a sign check would still pass if the ring aimed at GOLD.
        local dx = redContact.Position.x - here.x
        local dz = redContact.Position.z - here.z
        local len = math.sqrt(dx*dx + dz*dz)
        local ex, ez = dx/len, dz/len
        local dot = x*ex + z*ez
        assert(dot > 0.999, string.format(
          'aimed at (%.3f,%.3f) but the nearest hostile is at (%.3f,%.3f); dot=%.3f',
          x, z, ex, ez, dot))
        local x2, z2 = r:SentryAimVector('BLUE', here)
        assert(math.abs(x2-x) < 1e-9 and math.abs(z2-z) < 1e-9,
          'aim vector is not deterministic for an unchanged board')""")

    def test_sentry_validation_refund_and_sell(self):
        self.check("""assert(not r:PlaceSentry('BLUE',option,ba.createVector(0,0,0),false))
          assert(not r:PlaceSentry('BLUE',option,ba.createVector(9000,0,0),false)); assert(r.CommandPoints==10000)
          spawnFails=true; local failed=r:PlaceSentry('BLUE',option,pos,false); assert(failed and r.CommandPoints==10000-option.cost)
          assert(#r:GetFactionSentries('BLUE')==0,'sentry spawned before construction completed')
          now=now+r.Config.Station.Sentries.BuildSeconds; r:UpdateStations(now); assert(r.CommandPoints==10000 and #r:GetFactionSentries('BLUE')==0)
          spawnFails=false; local job=r:PlaceSentry('BLUE',option,pos,false); assert(job and r.CommandPoints==10000-option.cost)
          assert(not r:PlaceSentry('BLUE',option,pos,false),'pending footprint was not reserved')
          now=now+r.Config.Station.Sentries.BuildSeconds; r:UpdateStations(now); local s=r:GetFactionSentries('BLUE')[1]
          assert(s and r.CommandPoints==10000-option.cost)
          r.Selected={s.signature}; r:SellSelectedSentries()
          local expected=10000-option.cost+math.floor(option.cost*0.5)
          assert(r.CommandPoints==expected and not s:isValid()); r:SellSelectedSentries(); assert(r.CommandPoints==expected)""")

    def test_sentry_construction_cancels_if_enemy_arrives_at_site(self):
        self.check("""local job=r:PlaceSentry('BLUE',option,pos,false); assert(job)
          local enemy=ship('raider',class('SF Mara'),pos,mn.Teams.hostile)
          now=now+r.Config.Station.Sentries.BuildSeconds; r:UpdateStations(now)
          assert(#r:GetFactionSentries('BLUE')==0 and r.CommandPoints==10000,
            'construction completed on top of an enemy instead of refunding its cost')""")

    def test_mjolnir_locks_beyond_its_range_and_reacquires_near_targets(self):
        self.check("""ba.createOrientationFromVectors=function() return {} end
          -- Isolate the subject: the scan walks EVERY ship, and with a 12,000 m
          -- beam the other two command stations at 9,000 m are themselves inside
          -- its reach, so leaving them where the harness parks them resolves the
          -- beam regardless of where the target goes and the lock never engages.
          -- Move them out of the window rather than re-tuning the distances.
          stations.RED.Position=ba.createVector(400000,0,400000)
          stations.GOLD.Position=ba.createVector(-400000,0,-400000)
          local beam=r:GetSentryOptions('BLUE')[4]; local pos=ba.createVector(1000,0,0)
          local gun=r:PlaceSentry('BLUE',beam,pos,true); local turret=gun[1]; turret.TurretLocked=false
          -- Distances are derived from the beam's CONFIGURED range read off the
          -- option, not hardcoded: the reach is 12,000 m, so a fixed 9,000 m
          -- "far" target now sits INSIDE the window and the test would pass
          -- without ever exercising the lock.
          local far=pos.x+beam.range+2000; local near=pos.x+beam.range-2000
          local enemy=ship('distant base target',class('enemy base'),ba.createVector(far,0,0),mn.Teams.hostile)
          r:UpdateMjolnirRange(1); assert(turret.TurretLocked==true,'Mjolnir retained its unlimited native beam shot')
          enemy.Position=ba.createVector(near,0,0); r:UpdateMjolnirRange(3)
          assert(turret.TurretLocked==false,'Mjolnir did not reacquire an in-range target')
          enemy.Position=ba.createVector(far,0,0); r:UpdateMjolnirRange(5)
          assert(turret.TurretLocked==true,'Mjolnir did not relock after the target left weapon range')""")

    def test_repair_does_not_backfill_upgrade_or_combat_delay(self):
        self.check("""r.StationState.BLUE.levels.armor=1; stations.BLUE.HitpointsMax=12000; stations.BLUE.HitpointsLeft=6000
          assert(r:BuyUpgrade('BLUE','armor')); r:UpdateStations(0)
          now=60; r:UpdateStations(now); assert(math.abs(stations.BLUE.HitpointsLeft-6000)<0.001)
          stations.BLUE.HitpointsLeft=5000; now=61; r:UpdateStations(now)
          now=61+r.Config.Station.ArmorRepairDelay+10; r:UpdateStations(now)
          local expected=5000+14000*r.Config.Station.ArmorRepairPerSecond*10
          assert(math.abs(stations.BLUE.HitpointsLeft-expected)<0.001)""")

    def test_defense_rate_applies_once_to_existing_and_future_sentries(self):
        self.check("""r.Config.Station.Sentries.Cap=0; r.Config.Station.Sentries.CapBonus=0
          assert(not r:PlaceSentry('BLUE',option,pos,true))
          local turret={FireRateMultiplier=1,isTurret=function() return true end}
          stations.BLUE[1]=turret
          r.StationState.BLUE.levels.defenses=3; r:ApplyUpgrade('BLUE','defenses',3)
          r:ApplyUpgrade('BLUE','defenses',3); assert(turret.FireRateMultiplier==1.25)
          assert(#r:GetFactionSentries('BLUE')==0)
          r.Config.Station.Sentries.Cap=1
          local s=r:PlaceSentry('BLUE',option,pos,true); assert(s and s.HitpointsMax==option.hull*1.5)
          r:ApplyDefenseFireRate(s); r:ApplyDefenseFireRate(s)
          assert(s[1].FireRateMultiplier==1.25)""")

    def test_sentry_invalid_coordinates(self):
        self.check("""assert(r:CheckSentrySpot('BLUE',ba.createVector(0/0,0,1000)))
          assert(r:CheckSentrySpot('BLUE',nil))""")

    def test_reset_clears_station_state_and_hull_flags(self):
        self.check("""r.SentryHullBoosted={[1]=true}; r.StationState.BLUE.levels.command=3
          r.PendingStrikes={{}}; r.PanelTab='station'; r.ArmedSentryIndex=4
          r:ResetState(); assert(r:GetUpgradeLevel('BLUE','command')==0)
          assert(next(r.SentryHullBoosted)==nil and #r.PendingStrikes==0)
          assert(r.PanelTab=='production' and r.ArmedSentryIndex==nil)""")

    def test_restart_clears_dying_stations_and_never_freezes_a_recycled_signature(self):
        """Regression: DyingStations survived a mission restart while
        StabilizeDyingStations runs every frame, so a signature recycled onto an
        unrelated hull had its velocity zeroed forever. ResetState must drop the
        set, and the per-frame lookup must refuse anything that is not a command
        station still in its death roll."""
        self.check("""local red=stations.RED
          red.Physics={VelocityMax=ba.createVector(0,0,100),AfterburnerVelocityMax=ba.createVector(0,0,150),
            Velocity=ba.createVector(9,9,9),RotationalVelocity=ba.createVector(1,1,1)}
          signatureObjects[red.signature]=red; r.FindShipBySignature=realFindShipBySignature
          -- the original case must keep working: a station mid death roll is held
          red.dying=true; r.DyingStations={[red.signature]=true}
          r:StabilizeDyingStations()
          assert(red.Physics.Velocity.z==0 and red.Physics.RotationalVelocity.x==0,
            'a station in its death roll was not held still')
          assert(r.DyingStations[red.signature]==true,'the live dying station was dropped')
          -- the restart itself
          r:ResetState()
          assert(r.DyingStations~=nil and next(r.DyingStations)==nil,
            'restart kept dying-station signatures; they outlive the mission that wrote them')
          -- recycled onto an unrelated live hull
          local fighter=ship('recycled signature holder',class('GTF Ares'),ba.createVector(5000,0,0),mn.Teams.friendly)
          fighter.Physics={VelocityMax=ba.createVector(0,0,100),AfterburnerVelocityMax=ba.createVector(0,0,150),
            Velocity=ba.createVector(3,4,5),RotationalVelocity=ba.createVector(6,7,8)}
          signatureObjects[red.signature]=fighter
          r.DyingStations={[red.signature]=true}; r:StabilizeDyingStations()
          assert(fighter.Physics.Velocity.z==5 and fighter.Physics.RotationalVelocity.x==6,
            'a live hull was pinned at zero velocity by a stale dying-station signature')
          assert(r.DyingStations[red.signature]==nil,'the stale signature was not dropped')
          -- and a stale signature landing on a LIVE command station
          stations.BLUE.dying=false; stations.BLUE.HitpointsLeft=stations.BLUE.HitpointsMax
          stations.BLUE.Physics={Velocity=ba.createVector(2,2,2),RotationalVelocity=ba.createVector(2,2,2)}
          signatureObjects[stations.BLUE.signature]=stations.BLUE
          r.DyingStations={[stations.BLUE.signature]=true}; r:StabilizeDyingStations()
          assert(stations.BLUE.Physics.Velocity.z==2,'a live command station was frozen by a stale signature')""")

    def test_restart_drops_pilot_engine_state(self):
        """Regression: PilotTurretGroups holds l_Subsystem handles and
        PilotNativeWing an l_Wing from the previous mission. Only ExitPilotMode
        could clear them, and ResetState clears PossessedSignature before that
        could ever run, so a restart reached without a live observer kept them."""
        self.check("""r.PossessedSignature=77
          r.PilotTurretGroups={{label='primary',turrets={{subsystem={isValid=function() return false end},wasLocked=false}}}}
          r.PilotTurretGroupIndex=1; r.PilotTurretLastGroupIndex=1; r.PilotTurretAppliedGroupIndex=1
          r.PilotTurretFiring=true; r.PilotTurretFireLatched=true; r.PilotTurretFireStatusAt=12
          r.PilotTargetSubsystemIndex=3; r.PilotTargetSubsystemCount=7
          r.PilotNativeWing={name='Alpha',wing={},members={}}; r.PilotNativeWingLabel='Alpha'
          r:ResetState()
          assert(r.PilotTurretGroups==nil,'engine subsystem handles survived the restart')
          assert(r.PilotTurretGroupIndex==nil and r.PilotTurretLastGroupIndex==nil
            and r.PilotTurretAppliedGroupIndex==nil,'stale turret-group selection survived the restart')
          assert(r.PilotTurretFiring==false and r.PilotTurretFireLatched==false
            and r.PilotTurretFireStatusAt==nil,'stale turret fire state survived the restart')
          assert(r.PilotTargetSubsystemIndex==1 and r.PilotTargetSubsystemCount==0,
            'stale target-subsystem cursor survived the restart')
          assert(r.PilotNativeWing==nil and r.PilotNativeWingLabel==nil,
            'the previous mission native wing survived the restart')""")

    def test_restart_reopens_the_cohesion_and_contest_cadence_gates(self):
        """Regression: the COHESION/CONTEST sample clocks are mission-time
        values that no reset cleared, and mn.getMissionTime() restarts at 0, so a
        first mission of 30 minutes silenced both records for the whole second
        one -- exactly the evidence stall_probe/analyze_batch read."""
        self.check("""local emitted={}; r.EmitAIEvent=function(self,name,data) emitted[#emitted+1]=name end
          local groups={{id='wing',role='fighter',mission='PRIMARY',value=100,units={}}}
          -- end of a long first mission
          r:EmitAICohesion('RED',groups,nil,nil,1800); r:EmitContestRecord('RED',groups,nil,nil,1800)
          assert(#emitted==2,'first-mission samples were not emitted')
          assert(next(r.AIContestProgress)~=nil,'fixture did not record a progress row')
          r:ResetState(); emitted={}
          assert(next(r.AIContestProgress)==nil,'restart kept mission-time progress rows')
          -- second mission, mission time back near zero
          r:EmitAICohesion('RED',groups,nil,nil,0); r:EmitContestRecord('RED',groups,nil,nil,0)
          assert(emitted[1]=='COHESION','restart silenced COHESION for the whole second mission')
          assert(emitted[2]=='CONTEST','restart silenced CONTEST for the whole second mission')""")

    def test_restart_keeps_base_damage_hooks_reported_as_registered(self):
        """Regression: the On Ship Damage hooks are engine-global and survive a
        restart, but ResetCoordinatedAI re-zeroed their registration record and
        the re-registration early-returned with no repair, so the second mission
        reported hookCount=0 and empty registeredTargets while the engine was
        still delivering hits into the table."""
        self.check("""local hooked={}
          engine={addHook=function(name,fn,cond) hooked[#hooked+1]={name=name,cond=cond}; return true end}
          r.Config.AI.ExperimentalDamageTelemetry=true; r.ResolvedDamageTelemetryAvailable=true
          r:RegisterBaseDamageTelemetry()
          assert(r.BaseDamageTelemetry.hookCount==3,'stations were not hooked on the first mission')
          assert(#r.BaseDamageTelemetry.registeredTargets==3)
          r:ResetState()
          assert(r.BaseDamageTelemetry.hookCount==0,'the reset must still start a clean per-mission tally')
          r:RegisterBaseDamageTelemetry()
          assert(r.BaseDamageTelemetry.hookCount==3,'restart lost the live station hook registration')
          assert(#r.BaseDamageTelemetry.registeredTargets==3,'restart lost the registered-target list')
          assert(#r.BaseDamageTelemetry.registrationErrors==0)
          assert(#hooked==3,'engine hooks were added a second time instead of being reused')""")

    def test_on_state_start_survives_a_nil_state(self):
        """Regression: the On State Start hook dereferenced oldState.Name /
        newState.Name unguarded while its On State End sibling guards them, and a
        Lua error inside a state hook is not catchable by the mod."""
        self.check("""local emitted=0; r.EmitAIEvent=function() emitted=emitted+1 end
          r.Enabled=true; r.SetupActive=false; r.PostBattleActive=false
          r.Config.AI.DisableMissionPause=true
          local focus=0; r.SetMissionFocusPolicy=function() focus=focus+1 end
          ba.postGameEvent=function() end; ba.GameEvents={GS_EVENT_PREVIOUS_STATE='prev'}
          -- the real pause-suppression path must still fire
          r:OnStateStart({Name='GS_STATE_GAME_PLAY'},{Name='GS_STATE_GAME_PAUSED'})
          assert(emitted==1,'the pause backstop stopped suppressing engine pauses')
          r:OnStateStart(nil,nil)
          r:OnStateStart({Name='GS_STATE_GAME_PLAY'},nil)
          r:OnStateStart(nil,{Name='GS_STATE_GAME_PLAY'})
          assert(emitted==1 and focus==1,'a nil state changed the On State Start outcome')""")

    def test_reinforcement_respects_reserved_fleet_slots(self):
        self.check("""r.StationState.GOLD.levels.command=3
          r.CountCommittedCombatants=function(self,kind) return r:GetFleetCap(kind) end
          assert(not r:UseReinforcementJump('GOLD')); assert(r.StationState.GOLD.abilityReadyAt==0)
          r.CountCommittedCombatants=function() return 0 end
          assert(r:UseReinforcementJump('GOLD')); assert(not r:UseReinforcementJump('GOLD'))""")

    def test_surge_ets_refresh_and_strike_native_boundary(self):
        self.check("""local s=ship('red fighter',class('SF Mara'),stations.RED.Position,mn.Teams.hostile); s.role='fighter'
          s.Physics.VelocityMax=ba.createVector(10,20,100)
          r.StationState.RED.levels.command=3; assert(r:UseSwarmSurge('RED')); assert(s.Physics.VelocityMax.z==150)
          s.Physics.VelocityMax=ba.createVector(15,30,77)
          now=1; r:UpdateStations(now); assert(s.Physics.VelocityMax.z==115.5 and s.Physics.VelocityMax.x==15 and s.Physics.VelocityMax.y==30)
          now=19.9; r:UpdateStations(now); r:UpdateStations(now); assert(s.Physics.VelocityMax.z==115.5)
          now=20; r:UpdateStations(now); assert(s.Physics.VelocityMax.z==77)
          r.StationState.BLUE.levels.command=3
          assert(not r:QueueOrbitalStrike('BLUE',ba.createVector(12001,0,0)))
          assert(r.StationState.BLUE.abilityReadyAt==0 and #r.PendingStrikes==0)
          r.StationState.BLUE.levels.command=3; assert(r:QueueOrbitalStrike('BLUE',s.Position))
          local friend=ship('blue fighter',class('GTF Ares'),s.Position,mn.Teams.friendly); friend.role='fighter'
          now=24.9; r:UpdateStations(now); assert(#sexps==0)
          now=25; r:UpdateStations(now); assert(#sexps==1)
          assert(sexps[1]:find('explosion%-effect') and sexps[1]:find('1200 0 500 250 900'))
          r:UpdateStations(now); assert(#sexps==1)
          assert(#r.PendingStrikes==0)""")

    def test_surge_survives_new_ship_not_in_signature_lookup(self):
        self.check("""local s=ship('new mara',class('SF Mara'),stations.RED.Position,mn.Teams.hostile); s.role='fighter'
          r.StationState.RED.levels.command=3; assert(r:UseSwarmSurge('RED'))
          r.FindShipBySignature=function() return nil end
          r:UpdateStations(0); assert(r.SurgedShips[s.signature] and s.Physics.VelocityMax.z==150)
          s.valid=false; r:UpdateStations(1); assert(r.SurgedShips[s.signature]==nil)""")

    def test_invalid_placement_keeps_cursor_armed(self):
        self.check("""r.ArmedCommand='sentry'; r.ArmedSentryIndex=1; r:ExecuteStationArmedCommand(stations.BLUE.Position)
          assert(r.ArmedCommand=='sentry'); r:ExecuteStationArmedCommand(pos); assert(r.ArmedCommand==nil)""")

    def test_station_panel_controls_fit_at_both_resolutions(self):
        """Panel controls must land inside the drawable panel band at every
        resolution. The loop used to iterate pairs(StationButtonRects) with no
        non-empty assertion, so it passed with zero rects produced -- a silent
        pass if DrawStationPanel ever stopped laying the panel out. The name
        also claimed it varied 720/1080 while it only varied the screen WIDTH;
        it now varies both, which is what the assertion is actually about."""
        self.check("""local widths={1280,1920}; local heights={720,1080}
          for _,w in ipairs(widths) do
            for _,height in ipairs(heights) do
              gr={getScreenWidth=function() return w end,getScreenHeight=function() return height end,
                setColor=function() end,drawString=function() end,drawRectangle=function() end}
              r.DrawButton=function() end; r.PanelTab='station'
              r.StationButtonRects=nil
              local panel=r:GetProductionPanelRect(w,height)
              r:DrawStationPanel(panel.x1+10,panel.y1+36,panel.x2-10,panel.y2-76)
              local count=0
              for _,rect in pairs(r.StationButtonRects or {}) do
                count=count+1
                assert(rect.y1>=panel.y1+36 and rect.y2<=panel.y2-76,
                  'station control at '..w..'x'..height..' overlaps the footer')
                assert(rect.x1>=panel.x1 and rect.x2<=panel.x2,
                  'station control at '..w..'x'..height..' escapes the panel horizontally')
              end
              assert(count>0,'DrawStationPanel produced no button rects at '..w..'x'..height
                ..' -- the fit assertions would have been vacuous')
            end
          end""")

    def test_retreat_and_lure_strategic_order_succeed_when_the_sexp_takes_the_goal(self):
        """IssueStrategicOrder installs a RETREAT/LURE goal with mn.runSEXP and
        treats anything other than `true` as a failure (strategy.lua:230,242).
        The engine double used to return nothing, so under the harness this
        branch always read as failed and the success path -- the AIOrderState
        cache write and the 'ORDER_ACCEPTED' transition -- was never executed."""
        self.check("""r.AIOrderState={}; r.AITargetedBy={}
          local s=ship('retreating escort',class('GTF Myrmidon'),pos,mn.Teams.friendly); s.role='fighter'
          local ally=ship('retreat anchor',class('GTF Ares'),ba.createVector(-2000,0,0),mn.Teams.friendly)
          local before=#sexps
          assert(r:IssueStrategicOrder(s,ally,'retreat','RETREAT',0,true),'a RETREAT goal the engine accepted was reported as failed')
          assert(#sexps==before+1 and sexps[#sexps]:find('ai%-fly%-to%-ship'),'no fly-to goal was submitted')
          local entry=r.AIOrderState[s.signature]
          assert(entry and entry.mission=='RETREAT','the accepted order was not cached, so the next tick re-issued it forever')
          assert(entry.arrivalDistance==math.ceil((ally.Radius or 0)+(s.Radius or 0)+1400),
            'arrival distance was not recorded: '..tostring(entry.arrivalDistance))
          -- Re-issuing the same order must take the 'unchanged' fast path.
          local t0=entry.assignedAt
          r:IssueStrategicOrder(s,ally,'retreat','RETREAT',1,false)
          assert(r.AIOrderState[s.signature]==entry and entry.assignedAt==t0,
            'an unchanged RETREAT order rewrote its own cache entry')
          -- A SEXP the engine rejects must not be cached, so the tick retries.
          realRunSEXP=mn.runSEXP; mn.runSEXP=function() return false end
          local other=ship('luring escort',class('GTF Myrmidon'),pos,mn.Teams.friendly); other.role='fighter'
          assert(not r:IssueStrategicOrder(other,ally,'lure','LURE',2,true),'a rejected SEXP was reported as success')
          assert(r.AIOrderState[other.signature]==nil,'a rejected SEXP was cached as a live order')
          mn.runSEXP=realRunSEXP""")

    def test_strategic_weapon_range_is_nominal_for_a_beam_and_real_for_a_projectile(self):
        """GetStrategicWeapons reports mount.range. FSO exposes no beam range to
        scripting, so a beam mount used to report 0, and four call sites inherited
        that zero: GetFactionThreats never saw a beam attacker inside its reach,
        ScoreAIObjective charged the wrong ETA, AIRoleMatch refused every intercept
        past 1,800 m, and GetFleetLocalThreat never saw a beam platform as a
        threat at range. Measured consequence: escorts/heavies/juggernauts, the
        only hulls with sustained DPS against a 132,600 HP station, stalled at a
        p05 approach of 9,667 m while missile-armed fighters reached 1,251 m.

        Beams now report a nominal per-role reach (AI.Doctrine.BeamRangesByRole),
        raised but never lowered by evidence from real hits. This pins the new
        contract so a later rewrite cannot silently reintroduce the zero.
        """
        self.check("""local function weapon(beam,range,speed,life)
            return {Name=beam and 'beam' or 'shot',Range=range,Speed=speed,LifeMax=life,Damage=10,
              FireWait=1,FireRateMultiplier=1,isValid=function() return true end,
              isBeam=function() return beam==true end}
          end
          local function hull(bank,className)
            local s=ship('range probe',class(className or 'range probe'),pos,mn.Teams.hostile)
            s.PrimaryBanks={}; s.SecondaryBanks={}
            s.getFlag=function() return false end
            if bank then s.PrimaryBanks={{WeaponClass=bank,AmmoMax=0,isValid=function() return true end}} end
            s[1]=nil
            return s
          end
          r.BeamRangeByClass=nil; r.BeamLearnedRange=nil
          -- Every class in the roster must resolve to its own role's configured
          -- reach, and a class absent from the roster must fall back to the
          -- generic nominal. The role is derived from Config.ProductionClasses
          -- by class name, not from GetShipRole: calling that from inside the
          -- per-weapon loop was what made the engine hard-crash.
          for _,option in ipairs(r.Config.ProductionClasses) do
            local role=option.role; local value=r.Config.AI.Doctrine.BeamRangesByRole[role]
            if type(value)=="number" then
              r.BeamRangeByClass=nil
              local h=ship('probe',class(option.class),pos,mn.Teams.hostile)
              h.PrimaryBanks={{WeaponClass=weapon(true,5000,0,0),AmmoMax=0,isValid=function() return true end}}
              h.SecondaryBanks={}; h.getFlag=function() return false end; h[1]=nil
              assert(r:GetBeamMountRange(h)==value,
                option.class..' ('..tostring(role)..') beam reach is '
                  ..tostring(r:GetBeamMountRange(h))..', expected '..tostring(value))
            end
          end
          r.BeamRangeByClass=nil
          local stranger=ship('probe',class('not in the roster'),pos,mn.Teams.hostile)
          assert(r:GetBeamNominalRange(stranger)==r.Config.AI.Doctrine.BeamNominalRange,
            'a class outside the roster did not fall back to the generic nominal')
          -- The reach is nominal per role and must never be learned from hits.
          -- The learned variant read owner:getSignature() on a turret subsystem
          -- and hard-crashed the engine at mission teardown, with no Lua error
          -- and no output at all. Assert the plumbing is gone.
          r.BeamRangeByClass=nil; r.BeamLearnedRange=nil
          r.BeamRangeByClass={}
          local probe=ship('probe',class('GVCv Sobek'),pos,mn.Teams.hostile)
          r.BeamRangeByClass[probe.Class.Name]=6500
          assert(r:GetBeamMountRange(probe)==6500,'the per-class reach cache was not used')
          assert(r.BeamLearnedRange==nil,'learned beam reach came back')
          r.BeamRangeByClass=nil
          -- range is capped by the weapon's own lifetime, not the table cap.
          r.BeamRangeByClass=nil
          local shot=ship('shot',class('GTF Perseus'),pos,mn.Teams.hostile)
          shot.PrimaryBanks={{WeaponClass=weapon(false,9000,100,50),AmmoMax=0,isValid=function() return true end}}
          shot.SecondaryBanks={}; shot.getFlag=function() return false end; shot[1]=nil
          local sm,sa,sbeam,smax,spower=r:GetStrategicWeapons(shot)
          assert(sa==true and sbeam==false and #sm==1 and sm[1].beam==false)
          assert(sm[1].range==5000,'projectile range was not min(Range,Speed*LifeMax): '..tostring(sm[1].range))
          assert(smax==5000)
          -- A beam and a projectile in the SAME bank list share one mount
          -- entry (strategy.lua:368-393), so the entry is flagged beam while
          -- still carrying the projectile reach. That combination is what
          -- reaches the scoring code as range=5000, beam=true.
          local mixed=ship('mixed probe',class('mixed probe'),pos,mn.Teams.hostile)
          mixed.getFlag=function() return false end
          mixed.PrimaryBanks={{WeaponClass=weapon(true,0,0,0),AmmoMax=0,isValid=function() return true end},
            {WeaponClass=weapon(false,9000,100,50),AmmoMax=0,isValid=function() return true end}}
          mixed.SecondaryBanks={}; mixed[1]=nil
            local mm,_,mbeam,mmax=r:GetStrategicWeapons(mixed)
            -- The mount reach is now the LARGER of the two, because the beam
            -- half contributes its real nominal reach instead of a zeroed one.
            -- The projectile half is still present, it is just no longer the
            -- binding term; assert the reach is at least the projectile's.
            assert(mbeam==true and mmax>=5000,
              'a mixed battery lost its projectile reach: '..tostring(mmax))
            assert(#mm==1 and mm[1].beam==true and mm[1].range==mmax,
            'a mixed battery did not produce one beam-flagged mount at the projectile reach')
          -- An unarmed bank (empty magazine) contributes no mount at all, so a
          -- reload does not read as a threat with a phantom reach.
          local dry=ship('dry probe',class('dry probe'),pos,mn.Teams.hostile)
          dry.getFlag=function() return false end
          dry.PrimaryBanks={{WeaponClass=weapon(false,9000,100,50),AmmoMax=10,AmmoLeft=0,
            isValid=function() return true end}}
          dry.SecondaryBanks={}; dry[1]=nil
          local dm,da,dbeam,dmax=r:GetStrategicWeapons(dry)
          assert(da==false and #dm==0 and dmax==0,
            'a dry magazine still produced a mount at '..tostring(dmax))""")

    def test_set_time_scale_zero_only_stops_the_engine_clock_with_allow_zero(self):
        """allowZero is the single switch that lets the engine clock stop
        (factions.lua:495-504). Every other caller passes one number, so a zero
        has to be re-raised to the last non-zero scale; only the mod's own
        pause may pass the flag. Both halves are asserted against the actual
        SEXP handed to the engine, because the SEXP is the only thing the
        engine acts on."""
        self.check("""r.LastNonZeroTimeScale=nil; r.TimeScale=1
          local function lastPercent()
            return tonumber(sexps[#sexps]:match('%(%s*set%-time%-compression%s+([%d%.]+)'))
          end
          r:SetTimeScale(4)
          assert(r.TimeScale==4 and r.LastNonZeroTimeScale==4,'4x did not take: '..tostring(r.TimeScale))
          assert(lastPercent()==400,'the engine was not told 400: '..tostring(sexps[#sexps]))
          r:SetTimeScale(0)
          assert(r.TimeScale==4,'SetTimeScale(0) without the flag did not re-raise to the last non-zero scale: '..tostring(r.TimeScale))
          assert(lastPercent()==400,'the engine was told to stop by a zero the mod itself rejected')
          assert(r.LastNonZeroTimeScale==4)
          r:SetTimeScale(0,true)
          assert(r.TimeScale==0,'the mod pause did not reach TimeScale')
          assert(lastPercent()==0,'the engine clock was not stopped: '..tostring(sexps[#sexps]))
          -- A pause must not clobber the remembered non-zero scale, or the
          -- first step off the pause ladder restarts from 1.
          assert(r.LastNonZeroTimeScale==4,'pausing clobbered the remembered non-zero scale')
          r:SetTimeScale(0)
          assert(r.LastNonZeroTimeScale==4 and r.TimeScale==4,'a rejected zero changed remembered state')
          -- The step ladder resumes from the remembered scale.
          r:StepTimeScale(-1)
          assert(r.TimeScale==2,'stepping down from pause did not resume at the remembered scale: '..tostring(r.TimeScale))
          -- Out-of-range input is clamped, and a negative value is treated as
          -- a zero request, so it is also re-raised without the flag.
          r:SetTimeScale(99); assert(r.TimeScale==16 and lastPercent()==1600,
            '99x was not clamped to 16: '..tostring(r.TimeScale))
          r:SetTimeScale(-3); assert(r.TimeScale==16,
            'a negative scale was not treated as a zero request: '..tostring(r.TimeScale))
          r:SetTimeScale(0,true); assert(r.TimeScale==0 and r.LastNonZeroTimeScale==16,
            'a pause after clamping clobbered the remembered scale')""")

    def test_logistics_income_and_manual_build_speed(self):
        self.check("""r.ActiveIncomePerSecond=10; r.LastIncomeTime=0; tier=1
          r.StationState.BLUE.levels.logistics=1; now=10; r:UpdateEconomy(now)
          local ramp=1+0.2*(10/1800)^2
          assert(math.abs(r.CommandPoints-(10000+100*ramp*1.15))<0.001)
          r.StationState.BLUE.levels.logistics=2
          r.BuildQueue={{option={class='GTSG Watchdog',count=1,time=100,label='Watchdog'},queuedAt=now}}
          r:UpdateBuildQueue(now); assert(r.BuildQueue[1].finishTime==now+80)""")

    def test_logistics_three_runs_two_paid_ship_build_lanes(self):
        self.check("""r.BuildQueue={
            {option={class='first',count=1,time=100,label='First',cost=100},queuedAt=0},
            {option={class='second',count=1,time=200,label='Second',cost=200},queuedAt=0}}
          r.SpawnFriendly=function() return true,{} end
          r.StationState.BLUE.levels.logistics=2; r:UpdateBuildQueue(0)
          assert(r.BuildQueue[1].started and not r.BuildQueue[2].started)
          r.StationState.BLUE.levels.logistics=3; assert(r:GetBuildQueueSlots('BLUE')==2)
          r:UpdateBuildQueue(1)
          assert(r.BuildQueue[2].started and r.BuildQueue[2].finishTime>r.BuildQueue[1].finishTime)
          r:UpdateBuildQueue(300); assert(#r.BuildQueue==0)""")

    def test_spawn_frame_scatter_avoids_an_occupied_capital_sized_slot(self):
        self.check("""stations.BLUE.Orientation={getFvec=function() return ba.createVector(0,0,1) end}
          local capital=class('large capital'); capital.Model.Radius=1800
          local first=r:NativeGetSpawnFrame(stations.BLUE,capital,1,1,77)
          local blocker=ship('blocked slot',capital,first,mn.Teams.friendly); blocker.Radius=1800
          r:InvalidateShipList()
          local seen=false; r:EachShip(function(s) if s==blocker then seen=true end end); assert(seen,'fixture blocker missing from ship scan')
          assert(require('fs2rts_util').shipAlive(blocker),'fixture blocker was not alive')
          assert(require('fs2rts_util').shipValid(blocker),'fixture blocker was not a ship')
          assert(blocker:getSignature()~=stations.BLUE:getSignature(),'fixture blocker shares anchor signature')
          local inList=false; for _,s in ipairs(r:GetShipList()) do if s==blocker then inList=true end end; assert(inList,'blocker missing from ship list')
          local collides=false; for _,s in ipairs(r:GetShipList()) do if require('fs2rts_util').shipValid(s) and s:getSignature()~=stations.BLUE.signature and first:getDistance(s.Position)<capital.Model.Radius+(s.Radius or 100)+250 then collides=true end end; assert(collides,'direct collision predicate did not see occupied spawn point')
          local nextPos=r:NativeGetSpawnFrame(stations.BLUE,capital,1,1,77)
          assert(nextPos:getDistance(blocker.Position)>blocker.Radius+capital.Model.Radius,
            'large hull spawn distance '..nextPos:getDistance(blocker.Position)..' did not clear '..(blocker.Radius+capital.Model.Radius))""")

    def test_spawn_frame_ignores_transient_ships_without_placement_data(self):
        self.check("""stations.BLUE.Orientation={getFvec=function() return ba.createVector(0,0,1) end}
          local capital=class('transient placement test'); capital.Model.Radius=500
          ship('blocker',capital,ba.createVector(3000,0,0),mn.Teams.hostile)
          ships[#ships+1]={isValid=function() return true end,getBreedName=function() return 'Ship' end,
            getSignature=function() return 900001 end,Position=nil,Class=nil}
          local candidate=r:NativeGetSpawnFrame(stations.BLUE,capital,1,1,78)
          assert(candidate~=nil,'transient ship handles without position data broke spawn placement')""")

    def test_ai_does_not_spend_player_cp_with_auto_off(self):
        self.check("""local called={}; r.UpdateStationAI=function(self,kind) called[kind]=true end
          r:UpdateStations(0); assert(not called.BLUE and called.RED and called.GOLD)
          r.AutoPlayerMode=true; r:UpdateStations(1); assert(called.BLUE)""")

    def test_ai_never_spends_player_cp_from_the_real_station_ai(self):
        # The suite stubs UpdateStationAI globally, so the call-site test above
        # only proves WHERE it is called. This runs the real function inside the
        # real UpdateStations tick and asserts the money: the opponent's AI may
        # spend only its own CommandPoints pool, and the player's pool must be
        # untouched with AutoPlayerMode off, whatever the AI decides to buy.
        self.check("""r.UpdateStationAI=stationAI
          r.AutoPlayerMode=false
          r.CommandPoints=10000
          r.AIStates.RED={cp=10000}; r.AIStates.GOLD={cp=10000}
          tier=4; class('station AI fighter'); r.ShipCostMap['station AI fighter']={cost=200,time=10}
          r.GetAIRoster=function() return {{class='station AI fighter',tier=1,role='fighter',weight=1}} end
          r.StationState.RED.levels={armor=0,defenses=0,logistics=0,command=3}
          for i=1,8 do ship('sa '..i,class('SF Mara'),ba.createVector(9000,0,i*400),mn.Teams.hostile) end
          for step=1,6 do
            r.AIStates.RED.cp=10000; r.AIStates.GOLD.cp=10000
            r:UpdateStations(step*5)
            assert(r.CommandPoints==10000,
              'the opponent station AI spent the player pool: '..tostring(10000-r.CommandPoints)..' CP at step '..step)
          end
          -- And the AI actually did something, so the assertion above is not
          -- passing because the real function declined to act at all.
          assert(r.AIStates.RED.cp<10000 or #r:GetFactionSentries('RED')>0,
            'the real station AI spent nothing in six ticks; the CP assertion is vacuous')""")

    def test_ai_builds_opening_fleet_before_defense_ring(self):
        self.check("""r.StationState.RED.levels.logistics=1
          stationAI(r,'RED',r.StationState.RED,stations.RED,0)
          assert(#r:GetFactionSentries('RED')==0 and r.StationState.RED.upgrade==nil)
          for i=1,8 do ship('red '..i,class('SF Mara'),ba.createVector(9000,0,i*500),mn.Teams.hostile) end
          stationAI(r,'RED',r.StationState.RED,stations.RED,8)
          r:UpdateSentryConstruction(8+r.Config.Station.Sentries.BuildSeconds)
          assert(#r:GetFactionSentries('RED')==1)""")

    def test_station_reserve_cap_lets_the_base_invest_while_the_fleet_saves(self):
        # StationReserveCap is LOAD-BEARING, not an inert knob. productionReserve
        # is the fleet producer's whole bankTarget (7,700-13,825 CP in real
        # batches) and affordable() adds it to every base purchase. Uncapped, a
        # sentry needs cost + ~13,000 CP, which the base never reaches while the
        # fleet is banking for a capital - headless batch sentryfix-20261001
        # showed 7 sentry builds per 4 matches against the baseline's 67. The cap
        # lowers the hurdle to cost + 1,500 and the base keeps buying.
        # killcheck.py reported this guard as VACUOUS because no test made it the
        # difference; this test exists to make it one.
        self.check("""r.StationState.RED.levels.logistics=1
          r.AIStates.RED.queue=nil
          r.AIStates.RED.productionReserve=13000
          stationAI(r,'RED',r.StationState.RED,stations.RED,0)
          for i=1,8 do ship('red '..i,class('SF Mara'),ba.createVector(9000,0,i*500),mn.Teams.hostile) end
          r.AIStates.RED.cp=2000
          stationAI(r,'RED',r.StationState.RED,stations.RED,8)
          r:UpdateSentryConstruction(8+r.Config.Station.Sentries.BuildSeconds)
          assert(#r:GetFactionSentries('RED')==1,
            'the base stopped investing with a saving fleet: productionReserve is '
            ..'not being clamped by StationReserveCap')
          -- Control: the cap must not hand the base unlimited money. At 1000 CP
          -- the capped 1600 CP hurdle is still out of reach, so this stays a
          -- reservation rather than a licence to spend.
          local before=#r:GetFactionSentries('RED')
          r.AIStates.RED.cp=1000
          stationAI(r,'RED',r.StationState.RED,stations.RED,40)
          r:UpdateSentryConstruction(40+r.Config.Station.Sentries.BuildSeconds)
          assert(#r:GetFactionSentries('RED')==before,
            'the base overspent below the capped reserve threshold')""")

    # ------------------------------------------------------------------
    # Capital-aware station gate (Station.AI.CapitalAwareInvestment)
    # ------------------------------------------------------------------

    def test_capital_aware_investment_defaults_off(self):
        # The flag is the ONLY thing that changes balance, so its default is a
        # contract in its own right: with it off the station AI must behave
        # exactly as it shipped, including buying the upgrade the fleet is
        # saving for.
        self.check("""assert(r.Config.Station.AI.CapitalAwareInvestment==false,
          'CapitalAwareInvestment must ship off so the bank is NOT reallocated '
          ..'until an A/B proves it; see docs/contracts/09-capital-gate.md')
          assert(r.Config.Station.AI.StationReserveCap==1500,
            'StationReserveCap is load-bearing for sentry recovery and must not '
            ..'be retuned alongside the capital gate')""")

    def test_capital_gate_off_keeps_the_shipped_drain(self):
        # The control for the guard below: identical state, flag off, the base
        # buys. This is what makes the flag-on test a falsification of the gate
        # rather than of the fixture.
        self.capitalGateFixture()
        self.check("""stationAI(r,'RED',r.StationState.RED,stations.RED,200)
          assert(r.StationState.RED.upgrade~=nil,
            'flag off must keep the shipped behaviour: the base spent 1400 CP on '
            ..'LOGISTICS L2 while the fleet was banking for its capital')
          assert(r.AIStates.RED.cp==3000-1400,
            'flag off charged the wrong amount: '..tostring(r.AIStates.RED.cp))""")

    def test_capital_gate_defers_upgrades_while_the_fleet_saves(self):
        # The defect. productionReserve is the producer's bankTarget, and
        # min(reserve, StationReserveCap) discards it, so inside a capital save
        # window the base still buys at cp >= cost + 1500 - roughly 75 purchases
        # per 600 s window against a bank climbing 180-230 CP per think. Measured
        # per faction per 3000 s match that was 59,100-77,450 CP of upgrades
        # (29-38% of income) and 0 capital/heavy/juggernaut hulls in 4 of 4
        # headless matches.
        self.capitalGateFixture()
        self.check("""r.Config.Station.AI.CapitalAwareInvestment=true
          stationAI(r,'RED',r.StationState.RED,stations.RED,200)
          assert(r.StationState.RED.upgrade==nil,
            'the base bought an upgrade while the fleet was banking for a role '
            ..'the bank could not afford; the saving goal is being drained')
          assert(r.AIStates.RED.cp==3000,
            'flag on must not spend CP: '..tostring(r.AIStates.RED.cp))""")

    def test_capital_gate_does_not_starve_the_defence_ring(self):
        # The line the gate must not cross. Sentries are 3-13% of income against
        # the upgrade tree's 29-38%, and while the producer goes dark to save,
        # the ring is the base's only defence - the batch that took sentry builds
        # from 67 to 7 per 4 matches cost 220-270 unit losses.
        self.check("""r.StationState.RED.levels={armor=3,defenses=3,logistics=1,command=3}
          r.AIStates.RED.queue=nil
          r.AIStates.RED.savingRole='capital:4'
          r.AIStates.RED.savingSince=0
          r.AIStates.RED.productionReserve=13000
          r.Config.Station.AI.CapitalAwareInvestment=true
          for i=1,8 do ship('red '..i,class('SF Mara'),ba.createVector(9000,0,i*500),mn.Teams.hostile) end
          r.AIStates.RED.cp=2000
          stationAI(r,'RED',r.StationState.RED,stations.RED,8)
          r:UpdateSentryConstruction(8+r.Config.Station.Sentries.BuildSeconds)
          assert(#r:GetFactionSentries('RED')==1,
            'the capital gate starved the defence ring: sentries are not the '
            ..'sink this flag is allowed to stop')
          -- The gate really was engaged in this exact state, so the sentry above
          -- is bought DESPITE the deferral rather than because it never applied.
          assert(r.StationState.RED.capitalGateSince==8,
            'precondition: the gate was not engaged, so this proves nothing about '
            ..'defence surviving it: '..tostring(r.StationState.RED.capitalGateSince))
          -- And the upgrade the same think would otherwise have bought is still
          -- there, unspent: cp is 2000, LOGISTICS L2 costs 1400 + 1500 reserve.
          assert(r.AIStates.RED.cp==2000-375,
            'flag on spent CP beyond the sentry: '..tostring(r.AIStates.RED.cp))""")

    def test_capital_gate_releases_once_the_bank_can_afford_the_role(self):
        # First escape. The gate is a deferral of base investment WHILE the goal
        # is out of reach; the moment the bank can pay for the capital, holding
        # the upgrade back buys nothing and the producer buys the hull this think.
        self.capitalGateFixture()
        self.check("""r.Config.Station.AI.CapitalAwareInvestment=true
          r.AIStates.RED.cp=13000
          stationAI(r,'RED',r.StationState.RED,stations.RED,200)
          assert(r.StationState.RED.upgrade~=nil,
            'the gate kept deferring after the bank could afford the role it was '
            ..'saving for; that is a permanent drain with no upside')""")

    def test_capital_gate_releases_when_the_producer_stops_saving(self):
        # Second escape. savingRole is cleared on every purchase and on a
        # rising emergency (fs2rts_ai_production.lua:241,327), and
        # productionReserve drops to 0 on an emergency. A producer that is not
        # saving must not have the base held back.
        self.capitalGateFixture()
        self.check("""r.Config.Station.AI.CapitalAwareInvestment=true
          r.AIStates.RED.savingRole=nil; r.AIStates.RED.savingSince=nil
          r.AIStates.RED.productionReserve=0
          stationAI(r,'RED',r.StationState.RED,stations.RED,200)
          assert(r.StationState.RED.upgrade~=nil,
            'the gate deferred base investment for a producer that is not saving')""")

    def test_capital_gate_deferral_is_bounded(self):
        # The bound. Left unbounded this is a foot-gun: a producer whose target
        # is unreachable at the measured income never buys, savingRole is never
        # cleared, and the base would stop upgrading for the rest of the match.
        # The bound is the producer's OWN longest declared save window
        # (HeavyCapitalSavingSeconds = 900), i.e. how long the fleet itself is
        # willing to wait, so the base can never wait longer than the fleet that
        # is outbidding it.
        self.capitalGateFixture()
        self.check("""r.Config.Station.AI.CapitalAwareInvestment=true
          stationAI(r,'RED',r.StationState.RED,stations.RED,200)
          assert(r.StationState.RED.upgrade==nil,'precondition: gate is engaged')
          local bound=math.max(r.Config.AI.MaxProductionSavingSeconds or 0,
            r.Config.AI.CapitalSavingSeconds or 0, r.Config.AI.HeavyCapitalSavingSeconds or 0,
            r.Config.AI.JuggernautSavingSeconds or 0)
          assert(bound==900,'the derived bound should be the 900 s tier-4 window: '..tostring(bound))
          -- One tick inside the bound: still deferred, and the clock has NOT
          -- been reset by the deferral itself.
          r.StationState.RED.nextAIThink=0
          stationAI(r,'RED',r.StationState.RED,stations.RED,200+bound-1)
          assert(r.StationState.RED.upgrade==nil,
            'the gate released before the producer would have given up itself')
          -- Past the bound: released even though nothing about the producer changed.
          r.StationState.RED.nextAIThink=0
          stationAI(r,'RED',r.StationState.RED,stations.RED,200+bound+1)
          assert(r.StationState.RED.upgrade~=nil,
            'the gate never released: an unreachable producer target would freeze '
            ..'base investment for the rest of the match')
          -- The override is honoured, in both directions.
          r.Config.Station.AI.CapitalAwareInvestmentMaxSeconds=0
          r.StationState.RED.upgrade=nil; r.StationState.RED.nextAIThink=0
          r.AIStates.RED.cp=3000
          stationAI(r,'RED',r.StationState.RED,stations.RED,200+bound+2)
          assert(r.StationState.RED.upgrade~=nil,
            'MaxSeconds=0 must fail open and disable deferral entirely')""")

    def capitalGateFixture(self):
        """A faction mid-capital-save: producing nothing, banking, with an
        affordable LOGISTICS L2 upgrade in reach so the deferral is observable.

        Sentries are capped out so control reaches the upgrade loop, and the
        opening-fleet gate is passed by elapsed time rather than by hull count.
        Without both, this fixture would return before any upgrade is offered and
        the deferral tests would pass vacuously.
        """
        self.check("""r.Config.Station.Sentries.Cap=0; r.Config.Station.Sentries.CapBonus=0
          r.StationState.RED.levels={armor=3,defenses=3,logistics=1,command=3}
          r.StationState.RED.nextAIThink=0
          tier=4
          r.AIStates.RED={cp=3000,queue=nil,savingRole='capital:4',savingSince=200,productionReserve=13000}
          r.CountFactionCombatants=function() return 0 end
          r.CountCommittedCombatants=function() return 0 end""")

    def test_field_cheap_hull_while_saving_ships_off(self):
        # Pins the DEFAULT, which the alongside tests deliberately no longer
        # depend on - they set the flag explicitly so they test the alongside
        # mechanism rather than inheriting whatever ships. Without this pin the
        # default is unpinned and killcheck reports the guard VACUOUS.
        # It must ship off: while banking, the producer goes dark so the bank can
        # reach its target. Headless, with it on, the save window restarted on
        # every purchase and capital/heavy/juggernaut production was 0 in 4 of 4
        # matches, with the bank ceiling collapsing from ~13,000 CP to ~1,300.
        self.check("""assert(r.Config.AI.FieldCheapHullWhileSaving==false,
          'FieldCheapHullWhileSaving must ship off so the producer actually banks '
          ..'toward its capital target; see docs/contracts/03-ai-production.md')""")

    def test_station_upgrade_spend_routes_through_the_cp_ledger(self):
        # A station upgrade charges 625-4200 CP and used to emit NO event of its
        # own, so on real batches ~10% of economy.flow.productionSpend was
        # unattributable: BuyUpgrade and QueueOrbitalStrike reach SpendFactionCP
        # and nothing else. The CP_SPEND ledger fixed that AT THE CHOKEPOINT, so
        # every deduction is individually visible with no caller change.
        # The existing ledger test in test_ai_escalation.py calls
        # RecordAIEconomyFlow directly, so it cannot catch a sink that bypasses
        # SpendFactionCP. This one drives the real BuyUpgrade.
        self.check("""r.RecordAIEconomyFlow=realRecordAIEconomyFlow
          r.CombatTelemetryEnabled=true
          r.AIEconomyFlow=nil; r.AIEconomyFlowCumulative=nil
          local emitted={}
          r.EmitAIEvent=function(self,name,data,now)
            emitted[#emitted+1]={name=name,data=data}; self.EmittedSink=emitted end
          r.StationState.RED.levels={armor=0,defenses=0,logistics=0,command=0}
          tier=1
          local cost=r.Config.Station.Tracks.armor.costs[1]
          r.AIStates.RED.cp=cost+500
          assert(r:BuyUpgrade('RED','armor'),'the station upgrade did not start')
          assert(r.AIStates.RED.cp==500,
            'upgrade charged the wrong amount: '..r.AIStates.RED.cp)
          local flow=(r.AIEconomyFlow and r.AIEconomyFlow.RED or {}).productionSpend
          assert(flow==cost,
            'upgrade spend never reached the economy flow: '..tostring(flow))
          local found=false
          for _,e in ipairs(emitted) do
            if e.name=='CP_SPEND' and e.data.faction=='RED'
               and math.abs(e.data.amount-cost)<0.001 then found=true end
          end
          assert(found,
            'the station upgrade spent CP without emitting a CP_SPEND ledger '
            ..'record; that is exactly the unattributable-spend defect')""")

    def test_build_queue_retires_an_item_whose_spawn_raises(self):
        # killcheck reported the pcall around SpawnFriendly (fs2rts_production.lua:250)
        # as UNCOVERED: the existing spawnFails fixture drives the NIL-return path
        # (SpawnFriendly returning false), while the pcall guards the RAISING path.
        # Those are different branches and no test made the pcall the difference.
        # The failure it prevents is severe and permanent: table.remove at
        # fs2rts_production.lua:277 is the ONLY thing that retires a completed
        # queue item, and it sits AFTER the spawn block. An uncaught error aborts
        # the rest of OnFrame (FSO only logs it), the item is never retired, the
        # next frame re-enters the completion block and spawns `count` MORE hulls,
        # and it repeats until the fleet cap latches - dozens of duplicate hulls
        # permanently occupying fleet slots, with the CP already spent.
        self.check("""local spawns=0
          r.GetCarrier=function() return stations.BLUE end
          r.GetBuildQueueSlots=function() return 4 end
          r.CountFactionCombatants=function() return 0 end
          r.GetFleetCap=function() return 64 end
          r.SpawnFriendly=function(self,option) spawns=spawns+1 error('engine refused hull') end
          r.CommandPoints=0
          r.BuildQueue={{option={class='SF Mara',label='test hull',role='fighter',tier=1,
                                   cost=400,time=1,count=3},started=true,startTime=0,finishTime=1}}
          -- Must NOT propagate: an escaping error is the whole defect.
          r:UpdateBuildQueue(2)
          assert(#r.BuildQueue==0,
            'the queue item survived a raising spawn: '..#r.BuildQueue
            ..' still queued, so the next frame will spawn the hulls again')
          assert(r.CommandPoints==400,
            'a fully failed build must refund its CP: '..r.CommandPoints)
          assert(spawns==1,'expected exactly one spawn attempt: '..spawns)
          -- The anti-duplication property: a second tick must not re-attempt.
          r:UpdateBuildQueue(3)
          assert(spawns==1,
            'the same queue item spawned again on a later frame: '..spawns
            ..' attempts - this is the duplicate-hull fleet-slot leak')
          assert(#r.BuildQueue==0,'the queue did not stay empty: '..#r.BuildQueue)""")

    def test_release_object_handles_clears_every_handle_table(self):
        # What is worth protecting here is COVERAGE of the wipe list, not the
        # pcall. killcheck reports the pcall at fs2rts_lifecycle.lua:578 as
        # unfalsifiable, and the reason is Lua semantics rather than a missing
        # test: __newindex only fires for an ABSENT key, and wipe() returns
        # early when the key is nil, so by the time `self[name]={}` runs the key
        # is always present and the assignment cannot raise. Verified directly:
        # assigning to a present key with an erroring __newindex on the VALUE
        # fires 0 times and pcall succeeds; to an absent key it fires once and
        # pcall fails. No test can kill that guard, so this one asserts the
        # property that a new table added to the mod and forgotten here would
        # actually break - a stale handle surviving into the next mission.
        # FSO never tears the Lua state down between missions (code/scripting/
        # lua.cpp initialises with luaL_openlibs and never calls lua_close).
        self.check("""local names={'UserOrders','PolicyApplied','AIOrderState','FleetServices',
          'FleetServiceCooldown','SurvivalDangerSince','StaticDefenseSignatures',
          'SentryCosts','SentryHullBoosted','SentryNames','SentryHulls',
          'DefenseRateBoosted','MjolnirRangeLocks','SurgedShips','EngageTargets',
          'Selected','ControlGroups','AIStats','AIEconomyFlow','HoverReadout','OrderPing',
          'MoveWaypoints','FreeMoveWaypoints','PendingSentries','PendingStrikes',
          'AIOperations','LogicalWings','WingNameCounters','ShipCache'}
        for _,n in ipairs(names) do r[n]={marker=n} end
        r:ReleaseObjectHandles()
        local held={}
        for _,n in ipairs(names) do
          if r[n]~=nil and r[n].marker~=nil then held[#held+1]=n end
        end
        assert(#held==0,
          'teardown left handles in: '..table.concat(held,', ')
          ..' - a stale handle can survive into the next mission')""")

    def test_ffa_fronts_persist_and_new_groups_cover_both_enemies(self):
        self.check("""r.SetupFactionCount=3
          local first={BLUE='RED',RED='GOLD',GOLD='BLUE'}
          for kind,target in pairs(first) do assert(r:GetStablePrimaryTarget(kind)==stations[target]) end
          stations.BLUE.HitpointsLeft=1
          now=179.999
          for kind,target in pairs(first) do assert(r:GetStablePrimaryTarget(kind)==stations[target]) end
          now=180
          for kind,target in pairs(first) do assert(r:GetStablePrimaryTarget(kind)==stations[target]) end
          now=180.001
          local groups={{id='a',value=100},{id='b',value=100}}
          r:AssignAIAssaultFronts('RED',groups,stations.GOLD)
          assert(groups[1].primary==stations.GOLD and groups[2].primary==stations.BLUE)
          now=360; r:AssignAIAssaultFronts('RED',groups,stations.GOLD)
          assert(groups[1].primary==stations.GOLD and groups[2].primary==stations.BLUE)
          stations.GOLD.HitpointsLeft=0
          groups={{id='a',value=100},{id='b',value=100}}
          r:AssignAIAssaultFronts('RED',groups,stations.BLUE)
          assert(groups[1].primary==stations.BLUE and groups[2].primary==stations.BLUE)
          assert(r:GetStablePrimaryTarget('BLUE')==stations.RED)
          assert(r:GetStablePrimaryTarget('RED')==stations.BLUE)
          stations.RED.HitpointsLeft=0; assert(r:GetStablePrimaryTarget('BLUE')==nil)""")
        self.check("""stations.BLUE.HitpointsLeft=0; assert(r:GetStablePrimaryTarget('BLUE')==nil)""")

    def test_weapon_target_is_not_a_ship_and_native_point_defense_survives(self):
        self.check("""local s=ship('red',class('SF Mara'),pos,mn.Teams.hostile)
          local weapon={isValid=function() return true end,getBreedName=function() return 'Weapon' end,getSignature=function() return 999 end,Team=mn.Teams.friendly}
          assert(r:GetFactionKey(weapon)==nil and not r:AreEnemies(s,weapon))
          s.Target=weapon
          local status=r:GetNativeObjectiveStatus(s,{targetSignature=stations.BLUE.signature,mission='PRIMARY'})
          assert(status=='NATIVE_POINT_DEFENSE')
          s.Target=stations.BLUE
          assert(r:GetNativeObjectiveStatus(s,{targetSignature=stations.BLUE.signature,mission='PRIMARY'})=='NATIVE_TARGET_ACQUIRED')""")

    def test_campaign_reassignment_bypasses_old_base_retention(self):
        self.check("""local s=ship('red',class('SF Mara'),stations.GOLD.Position,mn.Teams.hostile); s.role='fighter'
          now=100; assert(r:IssueStrategicOrder(s,stations.GOLD,'old','PRIMARY',0,true))
          local g={id='wing',units={s},role='fighter',value=100,minHull=1,spread=0}
          r:CommitAIGroup(g,stations.BLUE,'PRIMARY',stations.RED,{assaultPrimarySignature=stations.BLUE.signature},now,false)
          assert(g.target==stations.BLUE and g.reason=='CAMPAIGN_FRONT_CHANGED')""")

    def test_subsystem_index_validation_preserves_existing_orders(self):
        self.check("""local s=ship('attacker',class('GTB Medusa'),pos,mn.Teams.friendly)
          local target=stations.RED; local turret=target[1]
          turret.Name='turret'; turret.getParent=function() return target end
          target[2]={Name='other turret'}
          local clears=0; s.clearOrders=function() clears=clears+1 end
          assert(r:IssueStrategicOrder(s,target,'valid','PRIMARY',0,true,{subsystem=turret,subsystemIndex=1}))
          assert(clears==1)
          for _,index in ipairs({0,1.5,0/0,math.huge}) do
            assert(r:IssueStrategicOrder(s,target,'invalid','PRIMARY',1,true,
              {subsystem=turret,subsystemIndex=index})==false)
          end
          assert(clears==1,'invalid subsystem index cleared the valid native order')""")

    def test_positive_hull_death_roll_is_not_a_live_front_or_order_target(self):
        self.check("""local s=ship('attacker',class('GTB Medusa'),pos,mn.Teams.friendly)
          r.FactionPrimaryTargets.BLUE=stations.RED.signature
          assert(r:GetStablePrimaryTarget('BLUE')==stations.RED)
          assert(r:IssueStrategicOrder(s,stations.GOLD,'control','PRIMARY',0,true))
          local previous=r.AIOrderState[s.signature]; local clears=0
          s.clearOrders=function() clears=clears+1 end
          stations.RED.dying=true; r.RedEliminated=true
          assert(stations.RED.HitpointsLeft>0 and stations.RED:isValid())
          assert(not require('fs2rts_util').shipAlive(stations.RED),'death roll counted as alive')
          assert(r:GetStablePrimaryTarget('BLUE')==stations.GOLD,'dead front retained')
          assert(r:IssueStrategicOrder(s,stations.RED,'dead','PRIMARY',1,true)==false)
          assert(clears==0 and r.AIOrderState[s.signature]==previous,'rejected dead target cleared live order')
          stations.RED.dying=false; r.RedEliminated=false
          assert(r:IssueStrategicOrder(s,stations.RED,'live','PRIMARY',2,true))
          r.AutoPlayerMode=true; stations.RED.dying=true
          r:ValidateStrategicOrderTargets(3)
          assert(r.AIOrderState[s.signature]==nil,'native validation retained a dying target')""")

    def test_combat_value_uses_available_weapons_not_price(self):
        self.check("""local s=ship('escort',class('GTC Fenris'),pos,mn.Teams.friendly)
          r.ShipCostMap[s.Class.Name]={cost=100,time=10}
          local value=r:GetCombatValue(s); assert(value>0)
          r.ShipCostMap[s.Class.Name].cost=10000; assert(r:GetCombatValue(s)==value)
          -- Locking must remove exactly the weapons it covers, no more.
          -- 'primaries-locked' gates the SHIP's own primary banks; a turret is a
          -- separate subsystem with its own lock (GetStrategicWeapons reads
          -- turret.TurretLocked). This assertion used to pass only because the
          -- turret double carried no banks at all, so the turret contributed
          -- nothing whether or not it was locked - it certified the flag
          -- plumbing without ever exercising it.
          -- GetStrategicWeapons returns (mounts, armed, profileBeam, maximumRange,
          -- firepower); the firepower we want is the FIFTH return, so it is
          -- picked by position rather than bound by a leading `_`.
          local function fp(ship) local _,_,_,_,p=r:GetStrategicWeapons(ship); return p end
          local full=fp(s)
          -- Isolate each lock's exact reach instead of assuming one is total.
          -- 'primaries-locked' covers the SHIP's own banks; a turret is a
          -- separate subsystem governed by turret.TurretLocked
          -- (GetStrategicWeapons). The old assertion expected a ship primary
          -- lock to zero the whole ship, which only held because the turret
          -- double carried no banks at all - it certified nothing.
          s.flags={['primaries-locked']=true}
          local turretOnly=fp(s)
          assert(turretOnly>0 and turretOnly<full,
            string.format('fixture is wrong: locked primaries gave %.2f of %.2f total', turretOnly, full))
          assert(math.abs(full-(2*turretOnly))<1e-6,
            'fixture is wrong: ship banks and turret banks should be equal here')
          s.flags={}; s[1].TurretLocked=true
          assert(math.abs(fp(s)-turretOnly)<1e-6,
            'locking the turret did not remove exactly the turret firepower')
          s[1].TurretLocked=true; s.flags={['primaries-locked']=true}
          assert(fp(s)==0,'locking both left reported firepower')
          s[1].TurretLocked=false; s.flags={}
          assert(math.abs(fp(s)-full)<1e-6,'unlocking did not restore the full loadout')
          assert(math.abs(r:GetCombatValue(s)-value)<1e-6,'combat value did not follow the weapons')
          s.HitpointsLeft=250; assert(math.abs(r:GetCombatValue(s)-value*.5)<1e-6)""")

    def test_lucifer_price_premium_is_applied_after_role_cost(self):
        self.check("""local c=class('SD Lucifer'); r.ShipCostRoleMap={['SD Lucifer']='juggernaut'}
          local formula=r.Config.CostFormula; local multiplier=formula.ClassMultipliers['SD Lucifer']
          formula.ClassMultipliers['SD Lucifer']=nil; local standard=r:EstimateShipCost(c).cost
          formula.ClassMultipliers['SD Lucifer']=multiplier; local premium=r:EstimateShipCost(c).cost
          assert(multiplier==1.25 and premium>=standard*1.2,
            'Lucifer should have a meaningful premium over a normal juggernaut')""")

    def test_factory_reservation_and_saving_deadline(self):
        self.check("""tier=4; class('old capital'); class('new capital')
          r.ShipCostMap['old capital']={cost=100,time=10}; r.ShipCostMap['new capital']={cost=1000,time=10}
          r.GetAIRoster=function() return {{class='old capital',tier=3,role='capital',weight=1},{class='new capital',tier=4,role='heavy',weight=1}} end
          local state={cp=1000}
          local choice,d=r:ChooseAIBuild('RED',state,0); assert(not choice and state.productionReserve==4500)
          choice,d=r:ChooseAIBuild('RED',state,899.99); assert(not choice)
          choice,d=r:ChooseAIBuild('RED',state,900)
          assert(choice and choice.entry.class=='old capital' and d.savingFallback and state.productionReserve==0)
          state.cp=4500; choice,d=r:ChooseAIBuild('RED',state,128)
          assert(choice.entry.class=='new capital' and state.productionReserve==0 and state.savingRole==nil)
          state={cp=1000}; r.AIStates.RED=state
          r:ChooseAIBuild('RED',state,0)
          r.StationState.RED.levels.logistics=1
          for i=1,8 do ship('red '..i,class('SF Mara'),stations.RED.Position,mn.Teams.hostile) end
          stationAI(r,'RED',r.StationState.RED,stations.RED,0)
          assert(r.AIStates.RED.cp==1000 and #r:GetFactionSentries('RED')==0)""")

    def test_station_emergency_breaks_capital_saving_for_fast_counter(self):
        self.check("""class('fast fighter'); class('fast bomber'); class('slow capital')
          tier=4
          r.Config.AI.CompositionTargets[4]={fighter=.1,bomber=.1,escort=.1,capital=.7}
          r.GetCurrentEscalationTier=function() return 4 end
          r.GetAIRoster=function() return {
            {class='fast fighter',role='fighter',tier=1,weight=1},
            {class='fast bomber',role='bomber',tier=2,weight=1},
            {class='slow capital',role='heavy',tier=4,weight=1}} end
          r.CountCommittedCombatants=function() return 0 end
          r.GetFleetCap=function() return 64 end
          r.CountAIRoleUnits=function() return {fighter=0,bomber=0,escort=0,capital=0,total=0},
            {fighter=0,bomber=0,escort=0,capital=0,total=0} end
          r.GetPurchaseEstimate=function(self,name)
            if name=='slow capital' then return {cost=5000,time=100} end
            if name=='fast bomber' then return {cost=300,time=10} end
            return {cost=200,time=6}
          end
          r.AIProductionNeeds={RED={fighter=0,bomber=.3,escort=0,capital=1.0}}
          r.AIProductionEmergency={RED={emergency=true,time=0}}
          r.Config.AI.FieldCheapHullWhileSaving=true
          local choice,decision=r:ChooseAIBuild('RED',{cp=1000},1)
          assert(choice and choice.entry.class=='fast bomber' and decision.emergencyFallback
            and decision.reason=='EMERGENCY_DEFENSE_PURCHASE' and decision.emergencyRole=='bomber'
            and decision.desiredRole=='capital',
            'station emergency kept saving for an unaffordable capital instead of a fast counter')
          assert(decision.selectedCount==r.Config.Economy.StrikeWingSize)
          r.AIProductionEmergency.RED={emergency=true,time=-100}
          choice,decision=r:ChooseAIBuild('RED',{cp=1000},1)
          -- A STALE emergency must not be treated as a live one. That is the
          -- invariant this test exists for, and it is asserted directly rather
          -- than inferred from "nothing was bought": the emergency path only
          -- engages on emergencyRole/emergencyFallback, and with
          -- AI.FieldCheapHullWhileSaving set above the saving branch fields a
          -- cheap non-capital hull, so the purchase itself cannot be the
          -- assertion. The flag is set explicitly here so this test keeps
          -- testing the stale-emergency invariant independently of the saving
          -- policy, which ships false - see docs/contracts/03-ai-production.md.
          -- The saving that policy once "fixed" away from was the AI correctly
          -- banking toward a capital, not a production stall.
          assert(decision.emergencyRole==nil and decision.emergencyFallback~=true,
            'stale emergency signal was treated as a live emergency')
          assert(decision.savingAlongside==true,
            'stale emergency bypassed the saving path entirely: '..tostring(decision.reason)..'/'..tostring(decision.savingAlongside))
          assert(decision.reason=='PURCHASE_SELECTED' or decision.reason=='SAVING_FOR_DESIRED_ROLE',
            'unexpected reason from the saving path: '..tostring(decision.reason))
          if choice then
            -- The saving path may field the cheapest affordable non-desired
            -- hull - that is the whole point of FieldCheapHullWhileSaving, and
            -- the cheapest thing on this fixture's roster happens to be a
            -- bomber. What it must NOT do is buy the capital it is saving for,
            -- which would mean the gate failed.
            assert(choice.entry.class~='slow capital',
              'the saving path bought the role it was banking for: '..tostring(choice.entry.class))
          end""")

    def test_mobile_replacement_saving_is_bounded(self):
        self.check("""tier=4; class('old escort'); class('new escort')
          r.ShipCostMap['old escort']={cost=100,time=10}; r.ShipCostMap['new escort']={cost=1000,time=10}
          r.GetAIRoster=function() return {{class='old escort',tier=3,role='escort'},{class='new escort',tier=4,role='escort'}} end
          local state={cp=1000}; local choice,d=r:ChooseAIBuild('RED',state,0); assert(not choice)
          choice,d=r:ChooseAIBuild('RED',state,119.99); assert(not choice)
          choice,d=r:ChooseAIBuild('RED',state,120)
          assert(choice.entry.class=='old escort' and d.savingFallback and state.productionReserve==0)""")

    def test_saving_is_only_skipped_when_the_bank_can_actually_reach_the_goal(self):
        # The livelock guard. Fielding a cheap hull alongside the goal drains the
        # bank on every think, so the goal never becomes affordable. Alongside is
        # only correct when banking CANNOT succeed in the time the window has
        # left; when it can, the producer must actually save.
        base = """class('cheap fighter'); class('slow capital')
          r.GetCurrentEscalationTier=function() return 4 end
          r.Config.AI.CompositionTargets[4]={fighter=.1,bomber=.1,escort=.1,capital=.7}
          r.GetAIRoster=function() return {{class='cheap fighter',role='fighter',tier=1,weight=1},
                                            {class='slow capital',role='capital',tier=4,weight=1}} end
          r.CountCommittedCombatants=function() return 0 end
          r.GetFleetCap=function() return 64 end
          r.CountAIRoleUnits=function() return {fighter=0,bomber=0,escort=0,capital=0,total=0},
            {fighter=0,bomber=0,escort=0,total=0} end
          r.GetPurchaseEstimate=function(self,name)
            if name=='slow capital' then return {cost=5000,time=100} end
            return {cost=200,time=6} end
          r.Config.AI.PreserveSavingClockWhileFielding=%s
          r.Config.AI.FieldCheapHullWhileSaving=true
          r.GetAIIncomeRamp=function() return 1 end
          r.GetIncomeMultiplier=function() return 1 end
          local window=r.Config.AI.HeavyCapitalSavingSeconds
          """
        # (1) Income comfortably funds the 5000 CP goal inside the window, so
        # banking can succeed: the producer must go dark, not field a fighter.
        self.check(base % "true" + """
          local state={cp=1000,income=20}
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(d.desiredRole=='capital' and d.savingCanBank==true,
            'expected banking to be judged reachable: '..tostring(d.savingCanBank))
          assert(not choice and d.reason=='SAVING_FOR_DESIRED_ROLE',
            'reachable goal must actually be saved for, not drained: '..tostring(d.reason))
          assert(state.savingSince==0,'going dark must not reset the savings clock')""")
        # (2) Income cannot fund it in the window: field alongside rather than
        # idle, which is what FieldCheapHullWhileSaving exists for.
        self.check(base % "true" + """
          local state={cp=1000,income=0.001}
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(d.savingCanBank==false,'starved faction should not try to bank')
          assert(choice and choice.entry.class=='cheap fighter',
            'unreachable goal should still field a cheap hull alongside')
          assert(state.savingSince==0,'alongside purchase must not reset the clock')""")
        # (3) Player-economy factions have no modelled income here (rate 0), so
        # the shipped alongside behaviour must be preserved rather than making
        # Blue stop producing.
        self.check(base % "true" + """
          local state={cp=1000,income=0,playerEconomy=true}
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(d.savingCanBank==false and choice and choice.entry.class=='cheap fighter',
            'a faction with no modelled income must keep producing alongside')""")
        # (4) Flag off: byte-identical to shipped - always alongside.
        self.check(base % "false" + """
          local state={cp=1000,income=20}
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(choice and choice.entry.class=='cheap fighter',
            'flag off must keep the shipped blind-alongside behaviour')
          assert(state.savingSince==nil,'flag off must still clear the savings clock')""")

    def test_unreachable_bank_target_falls_back_to_a_buildable_hull(self):
        # The defect: bankTarget aims at the newest tier's cheapest capital
        # (13000 CP here) while the faction's bank peaks near 2300 CP in
        # headless, so SAVING_FOR_DESIRED_ROLE is a permanent no-op and 0
        # capital/heavy/juggernaut hulls are built in 4 of 4 matches. With the
        # guard on, the target falls back to the cheapest desired-role hull the
        # faction can actually bank for - and that hull then gets BUILT.
        base = """class('cheap fighter'); class('old capital'); class('new capital')
          r.GetCurrentEscalationTier=function() return 5 end
          r.Config.AI.CompositionTargets[5]={fighter=.18,bomber=.12,escort=.12,capital=.58}
          r.GetAIRoster=function() return {{class='cheap fighter',role='fighter',tier=1,weight=1},
                                            {class='old capital',role='capital',tier=3,weight=1},
                                            {class='new capital',role='capital',tier=5,weight=1}} end
          r.CountCommittedCombatants=function() return 0 end
          r.GetFleetCap=function() return 64 end
          r.CountAIRoleUnits=function() return {fighter=0,bomber=0,escort=0,capital=0,total=0},
            {fighter=0,bomber=0,escort=0,capital=0,total=0} end
          r.GetPurchaseEstimate=function(self,name)
            if name=='new capital' then return {cost=13000,time=200} end
            if name=='old capital' then return {cost=2000,time=60} end
            return {cost=200,time=6} end
          r.GetAIIncomeRamp=function() return 1 end
          r.GetIncomeMultiplier=function() return 1 end
          r.Config.AI.BoundBankTarget=%s
          """
        # (1) Unreachable newest-tier goal: target drops to the older-tier
        # capital, and the station AI's productionReserve follows it down.
        self.check(base % "true" + """
          -- Nothing affordable, so no purchase releases the reserve: this is the
          -- value the station AI reads, and the reason base investment unblocks.
          r.GetPurchaseEstimate=function(self,name)
            if name=='new capital' then return {cost=13000,time=200} end
            if name=='old capital' then return {cost=2000,time=60} end
            return {cost=5000,time=60} end
          local state={cp=1000,income=10}
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(d.desiredRole=='capital','expected capital to be the goal: '..tostring(d.desiredRole))
          assert(d.currentTierDesiredCost==13000,'current-tier goal should still be reported')
          assert(d.bankTargetUnreachable==true,'unreachable goal was not flagged')
          assert(d.bankTarget==2000,'target should fall back to the older capital: '..tostring(d.bankTarget))
          assert(not choice,'nothing should be affordable at 1000 CP')
          assert(state.productionReserve==2000,
            'productionReserve must follow the bounded target: '..tostring(state.productionReserve))""")
        # (2) The whole point: once the bank can hold the bounded target, a
        # CAPITAL is actually committed to. Guard off, this never happens.
        self.check(base % "true" + """
          local state={cp=2500,income=10}
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(d.bankTarget==2000 and not d.savingFallback,'expected a normal purchase')
          assert(choice and choice.entry.class=='old capital',
            'no capital was built: bought '..tostring(choice and choice.entry.class))""")
        self.check(base % "false" + """
          local state={cp=2500,income=10}
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(d.bankTarget==13000,'guard off must keep the unbounded target: '..tostring(d.bankTarget))
          assert(d.bankTargetUnreachable==nil,'guard off must not flag the goal')
          assert(not choice or choice.entry.class~='old capital',
            'guard off must keep banking for the unreachable capital: bought '..tostring(choice and choice.entry.class))""")
        # (3) Reachable newest-tier goal is left alone - the bound only ever
        # lowers an impossible target, never a possible one.
        self.check(base % "true" + """
          local state={cp=11000,income=10}
          local _,d=r:ChooseAIBuild('RED',state,0)
          assert(d.bankTarget==13000,'reachable goal must not be lowered: '..tostring(d.bankTarget))
          assert(d.bankTargetUnreachable==nil)""")
        # (4) A player-economy faction has no modelled income here (rate 0), so
        # its target must be untouched rather than silently changed.
        self.check(base % "true" + """
          local state={cp=1000,income=0,playerEconomy=true}
          local _,d=r:ChooseAIBuild('RED',state,0)
          assert(d.bankTarget==13000,'player-economy target must be untouched: '..tostring(d.bankTarget))
          assert(d.bankTargetUnreachable==nil)""")

    def test_bound_bank_target_defaults_off(self):
        self.check("""assert(r.Config.AI.BoundBankTarget==false,
          'BoundBankTarget must ship off so no balance changes without an A/B')""")

    def test_saving_clock_survives_fielding_a_cheap_hull(self):
        # Regression: FieldCheapHullWhileSaving + clearing savingSince on every
        # purchase = a permanent livelock. Headless batch sentrybudget-a
        # (4 matches x 3000 s, real engine): desiredRole=capital in 2346 of 3792
        # build decisions, bankTarget median 8600, per-faction CP bank peak
        # 1300-2494, and ZERO capital builds in 4 of 4 matches.
        # savingSince is the only thing that ages the save window out into
        # savingFallback, so it must survive the alongside purchase.
        self.check("""class('cheap fighter'); class('slow capital')
          r.GetCurrentEscalationTier=function() return 4 end
          r.Config.AI.CompositionTargets[4]={fighter=.1,bomber=.1,escort=.1,capital=.7}
          r.GetAIRoster=function() return {{class='cheap fighter',role='fighter',tier=1,weight=1},
                                            {class='slow capital',role='capital',tier=4,weight=1}} end
          r.CountCommittedCombatants=function() return 0 end
          r.GetFleetCap=function() return 64 end
          r.CountAIRoleUnits=function() return {fighter=0,bomber=0,escort=0,capital=0,total=0},
            {fighter=0,bomber=0,escort=0,capital=0,total=0} end
          r.GetPurchaseEstimate=function(self,name)
            if name=='slow capital' then return {cost=5000,time=100} end
            return {cost=200,time=6} end
          r.Config.AI.PreserveSavingClockWhileFielding=true
          r.Config.AI.FieldCheapHullWhileSaving=true
          local state={cp=1000}
          -- cp is short of bankTarget, so the window opens and the cheap fighter
          -- is fielded alongside it.
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(d.desiredRole=='capital' and d.savingAlongside==true,
            'expected to be saving for capital alongside a cheap hull: '..tostring(d.reason))
          assert(choice and choice.entry.class=='cheap fighter',
            'expected the cheap non-desired hull alongside: '..tostring(choice and choice.entry.class))
          assert(state.savingSince==0,
            'the alongside purchase wiped the savings clock: '..tostring(state.savingSince))
          assert(state.savingRole=='capital:4','savingRole lost: '..tostring(state.savingRole))
          -- Repeated thinks must keep ageing the same window, not restart it.
          for i=1,5 do r:ChooseAIBuild('RED',state,i) end
          assert(state.savingSince==0,'window restarted at '..tostring(state.savingSince))
          -- Once the window ages past the saving seconds it must reach
          -- savingFallback. At cp=4900 with a 5000 CP capital NOTHING in the
          -- desired role is affordable, and the old expectation here was that
          -- the AI then buys a cheap fighter. That is the defect, not the fix:
          -- the fallback purchase spent the bank on a 200 CP hull, the caller
          -- cleared savingSince, and the window restarted from zero - which is
          -- why capital production was 0 in 4 of 4 headless matches with fallback
          -- firing at cp 2820-6047 against capitals of 7700-8600.
          -- It must now go dark and keep banking, preserving the clock.
          state.cp=4900
          local picked,d2=r:ChooseAIBuild('RED',state,r.Config.AI.HeavyCapitalSavingSeconds+1)
          assert(d2.savingFallback==true,
            'window never aged into savingFallback: '..tostring(d2.reason))
          assert(picked==nil and d2.reason=='SAVING_FOR_DESIRED_ROLE',
            'fallback bought a non-desired hull with the capital bank: '
            ..tostring(picked and picked.entry.class)..' / '..tostring(d2.reason))
          assert(d2.savingFallbackUnreachable==true,
            'the unreachable fallback did not record why it went dark')
          assert(state.savingSince==0,
            'going dark must not wipe the savings clock: '..tostring(state.savingSince))
          -- And the point of going dark: bank the remainder and buy the capital.
          state.cp=5100
          local bought,d3=r:ChooseAIBuild('RED',state,r.Config.AI.HeavyCapitalSavingSeconds+2)
          assert(bought and bought.entry.class=='slow capital',
            'with the capital affordable the producer still did not buy it: '
            ..tostring(bought and bought.entry.class)..' / '..tostring(d3.reason))
          r.Config.AI.PreserveSavingClockWhileFielding=false""")

    def test_saving_clock_default_keeps_the_pre_flag_clearing_behaviour(self):
        # The flag defaults to false, so behaviour with it off must stay
        # byte-identical to what shipped: the clock IS cleared.
        self.check("""class('cheap fighter'); class('slow capital')
          r.GetCurrentEscalationTier=function() return 4 end
          r.Config.AI.CompositionTargets[4]={fighter=.1,bomber=.1,escort=.1,capital=.7}
          r.GetAIRoster=function() return {{class='cheap fighter',role='fighter',tier=1,weight=1},
                                            {class='slow capital',role='capital',tier=4,weight=1}} end
          r.CountCommittedCombatants=function() return 0 end
          r.GetFleetCap=function() return 64 end
          r.CountAIRoleUnits=function() return {fighter=0,bomber=0,escort=0,capital=0,total=0},
            {fighter=0,bomber=0,escort=0,total=0} end
          r.GetPurchaseEstimate=function(self,name)
            if name=='slow capital' then return {cost=5000,time=100} end
            return {cost=200,time=6} end
          assert(r.Config.AI.PreserveSavingClockWhileFielding==false,'flag must default off')
          r.Config.AI.FieldCheapHullWhileSaving=true
          r.GetAIIncomeRamp=function() return 1 end
          r.GetIncomeMultiplier=function() return 1 end
          local state={cp=1000}
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(d.savingAlongside==true and choice and choice.entry.class=='cheap fighter',
            'expected the alongside purchase: '..tostring(d.reason))
          assert(state.savingSince==nil and state.savingRole==nil,
            'flag off must still clear the saving clock: '..tostring(state.savingSince))""")

    def test_saving_clock_is_not_preserved_when_the_goal_is_actually_bought(self):
        # The clock must still be cleared when the purchase IS the banked role,
        # otherwise the station AI's productionReserve stays pinned at bankTarget
        # and re-blocks base investment (the bug PreserveSavingClock fixes).
        self.check("""class('cheap fighter'); class('slow capital')
          r.GetCurrentEscalationTier=function() return 4 end
          r.Config.AI.CompositionTargets[4]={fighter=.1,bomber=.1,escort=.1,capital=.7}
          r.GetAIRoster=function() return {{class='cheap fighter',role='fighter',tier=1,weight=1},
                                            {class='slow capital',role='capital',tier=4,weight=1}} end
          r.CountCommittedCombatants=function() return 0 end
          r.GetFleetCap=function() return 64 end
          r.CountAIRoleUnits=function() return {fighter=0,bomber=0,escort=0,capital=0,total=0},
            {fighter=0,bomber=0,escort=0,total=0} end
          r.GetPurchaseEstimate=function(self,name)
            if name=='slow capital' then return {cost=5000,time=100} end
            return {cost=200,time=6} end
          r.Config.AI.PreserveSavingClockWhileFielding=true
          local state={cp=9000}
          local choice,d=r:ChooseAIBuild('RED',state,0)
          assert(choice and choice.entry.class=='slow capital','expected the capital: '..tostring(d.reason))
          assert(state.savingSince==nil and state.savingRole==nil,
            'buying the goal must still clear the saving clock')
          assert(state.productionReserve==0,'productionReserve must be released after the goal is bought')
          r.Config.AI.PreserveSavingClockWhileFielding=false""")

    def test_production_obeys_commander_counter_demand(self):
        self.check("""tier=2
          for _,name in ipairs({'fighter','bomber','escort'}) do class(name); r.ShipCostMap[name]={cost=100,time=10} end
          r.GetAIRoster=function() return {{class='fighter',role='fighter',tier=2},{class='bomber',role='bomber',tier=2},{class='escort',role='escort',tier=2}} end
          r.CountAIRoleUnits=function() return {},{total=100,fighter=40,bomber=30,escort=30,capital=0} end
          local _,d=r:ChooseAIBuild('RED',{cp=10000},0); assert(d.desiredRole=='escort')
          r.AIProductionNeeds.RED={fighter=.5}
          local choice; choice,d=r:ChooseAIBuild('RED',{cp=10000},0)
          assert(d.desiredRole=='fighter' and choice.entry.role=='fighter')""")

    def test_disabled_faction_invalidates_cached_target(self):
        self.check("""r.SetupFactionCount=3; assert(r:GetStablePrimaryTarget('RED')==stations.GOLD)
          r.SetupOpponents.GOLD=false
          assert(r:GetStablePrimaryTarget('RED')==stations.BLUE)""")

    def test_fronts_concentrate_main_effort_and_clear_reused_dead_targets(self):
        self.check("""r.SetupFactionCount=3; local groups={}
          for i=1,10 do groups[i]={id=tostring(i),value=100} end
          r:AssignAIAssaultFronts('RED',groups,stations.GOLD)
          local main=0; for _,g in ipairs(groups) do if g.primary==stations.GOLD then main=main+1 end end
          assert(main==7)
          stations.GOLD.HitpointsLeft=0
          r:AssignAIAssaultFronts('RED',groups,stations.BLUE)
          for _,g in ipairs(groups) do assert(g.primary==stations.BLUE) end
          r:ResetState(); assert(next(r.AIAssaultTargets)==nil and next(r.AIProductionNeeds)==nil)""")

    def test_front_share_extremes_keep_both_fronts_available(self):
        self.check("""r.SetupFactionCount=3
          for _,share in ipairs({0,.70,.85,1,-1,2}) do
            r.Config.AI.Doctrine.PrimaryFrontShare=share; r.AIAssaultTargets={}
            local groups={}; for i=1,20 do groups[i]={id=tostring(i),value=100} end
            r:AssignAIAssaultFronts('RED',groups,stations.GOLD)
              local main=0; for _,g in ipairs(groups) do if g.primary==stations.GOLD then main=main+1 end end
              assert(main>=1 and main<=19)
              if share==.85 then assert(main==17,'85% preference should direct 17 of 20 new groups to the main front') end
          end""")

    def test_sentries_are_not_mobile_ai_composition(self):
        self.check("""local s=r:PlaceSentry('BLUE',option,pos,true); s.role='fighter'
          local counts=r:CountAIRoleUnits('BLUE'); assert(counts.total==0)
          local mobile=ship('mobile',class('GTF Myrmidon'),pos,mn.Teams.friendly); mobile.role='fighter'
          counts=r:CountAIRoleUnits('BLUE'); assert(counts.total==1 and counts.fighter==1)""")

    def test_optional_starting_sentries_use_shared_profiles(self):
        self.check("""assert(r:SpawnSentryDefenses()==3)
          for _,kind in ipairs({'BLUE','RED','GOLD'}) do
            local s=r:GetFactionSentries(kind); assert(#s==1)
            assert(s[1].HitpointsMax==r:GetSentryOptions(kind)[1].hull)
            assert(r.SentryCosts[s[1].signature]==0)
          end""")

    def test_ai_reserves_mobile_wing_and_limits_idle_defenses(self):
        self.check("""r.StationState.RED.levels={armor=3,defenses=3,logistics=3,command=3}
          local c=class('SF Mara'); r.ShipCostMap[c.Name]={cost=350,time=10}
          r.GetAIRoster=function() return {{class=c.Name,tier=1,role='fighter'}} end
          for i=1,8 do ship('red '..i,c,stations.RED.Position,mn.Teams.hostile) end
          r.AIStates.RED.cp=1699
          stationAI(r,'RED',r.StationState.RED,stations.RED,0)
          assert(#r:GetFactionSentries('RED')==0 and r.AIStates.RED.cp==1699)
          r.AIStates.RED.cp=10000
          for _,time in ipairs({8,16,24,32}) do stationAI(r,'RED',r.StationState.RED,stations.RED,time) end
          r:UpdateSentryConstruction(60)
          assert(#r:GetFactionSentries('RED')==2)
          assert(r.AIStates.RED.cp==9250)""")

    def test_ai_selects_flak_for_fighter_threats(self):
        self.check("""r.StationState.RED.levels.logistics=1
          for i=1,8 do ship('red '..i,class('SF Mara'),stations.RED.Position,mn.Teams.hostile) end
          for i=1,3 do local s=ship('attacker '..i,class('GTF Myrmidon'),ba.createVector(10300,0,0),mn.Teams.friendly); s.role='fighter' end
          stationAI(r,'RED',r.StationState.RED,stations.RED,0)
          r:UpdateSentryConstruction(r.Config.Station.Sentries.BuildSeconds)
          local sentries=r:GetFactionSentries('RED'); assert(#sentries==1 and sentries[1].Class.Name=='SSG Rahu')""")

    def test_model_loading_precedes_cost_cache_and_lazy_pricing(self):
        self.check("""local c=class('test unloaded'); c.loaded=false
          c.Model.Radius=1
          c.isModelLoaded=function(self,load)
            if load then self.loaded=true; self.Model.Radius=1000 end
            return self.loaded
          end
          local estimate=r:GetPurchaseEstimate(c.Name,1,1)
          assert(c.loaded and r.ShipCostMap[c.Name].radius==1000 and estimate.cost>0)
          local cached=r.ShipCostMap[c.Name]; r:GetPurchaseEstimate(c.Name,1,1)
          assert(r.ShipCostMap[c.Name]==cached)""")

    def test_each_upgrade_level_for_every_faction(self):
        self.check("""for _,kind in ipairs({'BLUE','RED','GOLD'}) do
          local hull=stations[kind].HitpointsMax; local fleet=r:GetFleetCap(kind)
          local cap=r:GetSentryCap(kind); local radius=r:GetSentryRadius(kind)
          for _,track in ipairs({'armor','defenses','logistics','command'}) do
            for level=1,3 do
              r:RefundFactionCP(kind,10000); assert(r:BuyUpgrade(kind,track))
              now=r.StationState[kind].upgrade.finishTime; r:UpdateStations(now)
              assert(r:GetUpgradeLevel(kind,track)==level)
              if track=='armor' then assert(math.abs(stations[kind].HitpointsMax-hull*(1+level*.2))<.01) end
              if track=='logistics' then
                assert(r:GetIncomeMultiplier(kind)==({1.15,1.15,1.30})[level])
                assert(r:GetBuildTimeMultiplier(kind)==(level>=2 and .8 or 1))
              end
            end
          end
          assert(r:GetFleetCap(kind)==fleet+8)
          assert(r:GetSentryCap(kind)==cap+4)
          assert(r:GetSentryRadius(kind)==radius+2000)
        end""")


if __name__ == '__main__':
    unittest.main()
