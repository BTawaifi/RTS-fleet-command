"""Faction identity, roster admission and paid ability failure paths.

These boundary checks complement faction_setup_probe.lua's native model and
ability checks; synthetic hull stats are not faction balance evidence.
"""
import unittest
import re
import struct
from lupa.lua51 import LuaRuntime
from test_station import SETUP, SCRIPTS
import retail_tables


class FactionProfileTests(unittest.TestCase):
    def test_all_layouts_counts_and_distances_keep_minimum_separation_and_bounds(self):
        self.check('''
          r.SetupActive=true; r.UpdateCameraTransform=function() end
          for layout=1,#r.Config.Setup.BaseLayouts do
            r.SetupBaseLayoutIndex=layout
            for count=2,r:GetMaxFactionCount() do
              r.SetupFactionCountChoice=count; r:UpdateFactionCount()
              for distance=1,#r.Config.Setup.BaseDistances do
                r.SetupBaseDistanceIndex=distance; r:ApplyConfiguredBaseSpacing()
                local keys=r:GetFactionKeys(); local closest=math.huge; local x,z=0,0
                local d=r:GetBaseDistanceProfile().distance
                for i,kind in ipairs(keys) do
                  local p=r.ScenarioBasePositions[kind]
                  assert(p and p.y==0 and r:IsFiniteVector(p),'invalid start point')
                  assert(math.abs(p.x)+10000<=r.ScenarioMapHalfExtent+.01 and math.abs(p.z)+10000<=r.ScenarioMapHalfExtent+.01,
                    'layout escaped map bounds or spawn clearance')
                  x=x+p.x; z=z+p.z
                  for j=i+1,#keys do closest=math.min(closest,p:getDistance(r.ScenarioBasePositions[keys[j]])) end
                end
                assert(math.abs(closest-d)<.01,'layout changed the selected minimum station distance')
                assert(math.abs(x)<.01 and math.abs(z)<.01,'layout is not centered')
              end
            end
          end
        ''')

    def test_star_and_multiple_circles_have_distinct_geometry(self):
        self.check('''
          r.SetupActive=true; r.UpdateCameraTransform=function() end
          r.SetupFactionCountChoice=6; r:UpdateFactionCount(); r.SetupBaseLayoutIndex=2
          r:ApplyConfiguredBaseSpacing()
          local origin=ba.createVector(0,0,0); local keys=r:GetFactionKeys()
          local outer=r.ScenarioBasePositions[keys[1]]:getDistance(origin)
          local inner=r.ScenarioBasePositions[keys[2]]:getDistance(origin)
          assert(math.abs(outer-inner*2)<.01,'star has no alternating radial levels')
          r.SetupFactionCountChoice=12; r:UpdateFactionCount(); r.SetupBaseLayoutIndex=3
          r:ApplyConfiguredBaseSpacing(); keys=r:GetFactionKeys()
          local centers={}
          for group=1,3 do
            local center=ba.createVector(0,0,0)
            for index=group,12,3 do center=center+r.ScenarioBasePositions[keys[index]]/4 end
            centers[group]=center
            local radius=r.ScenarioBasePositions[keys[group]]:getDistance(center)
            for index=group,12,3 do assert(math.abs(r.ScenarioBasePositions[keys[index]]:getDistance(center)-radius)<.01) end
            assert(center:getDistance(origin)>radius*2,'multiple circles collapsed into one ring')
          end
          assert(centers[1]:getDistance(centers[2])>r:GetBaseDistanceProfile().distance*2)
        ''')

    def test_layout_changes_are_setup_only_and_gold_only_positions_work(self):
        self.check('''
          r.SetupActive=true; r.UpdateCameraTransform=function() end
          r.SetupFactionCountChoice=nil; r.SetupOpponents={RED=false,GOLD=true}; r:UpdateFactionCount()
          r:ApplyConfiguredBaseSpacing()
          assert(r.ScenarioBasePositions.GOLD and not r.ScenarioBasePositions.RED)
          local d=r:GetBaseDistanceProfile().distance
          assert(math.abs(r.ScenarioBasePositions.BLUE:getDistance(r.ScenarioBasePositions.GOLD)-d)<.01)
          local positions=r.ScenarioBasePositions; local extent=r.ScenarioMapHalfExtent; local layout=r.ScenarioBaseLayoutId
          r.SetupActive=false; r.SetupBaseLayoutIndex=2; r:ApplyConfiguredBaseSpacing()
          assert(r.ScenarioBasePositions==positions and r.ScenarioMapHalfExtent==extent and r.ScenarioBaseLayoutId==layout,'live layout mutation changed map state')
          r:ResetState(); assert(r.SetupBaseLayoutIndex==r.Config.Setup.DefaultBaseLayout)
          r:CycleSetupValue('layout',-1); assert(r.SetupBaseLayoutIndex==#r.Config.Setup.BaseLayouts)
          r:CycleSetupValue('layout',1); assert(r.SetupBaseLayoutIndex==1)
        ''')

    def test_cluster_ai_chooses_local_opponents_and_advances_after_local_bases_fall(self):
        self.check('''
          r.SetupActive=true; r.SetupFactionCountChoice=6; r:UpdateFactionCount()
          r.SetupBaseLayoutIndex=3; r.UpdateCameraTransform=function() end; r:ApplyConfiguredBaseSpacing()
          local keys=r:GetFactionKeys(); local bases={}
          for i,kind in ipairs(keys) do
            local definition=r:GetFactionDefinition(kind); local team=mn.Teams[definition.team]
            if not team then team={Name=definition.team,isValid=function() return true end,attacks=function(a,b) return a~=b end}; mn.Teams[definition.team]=team end
            bases[kind]=ship(definition.station,class('Station '..i),r.ScenarioBasePositions[kind],team)
          end
          r.GetFactionCommandShip=function(self,kind) return bases[kind] end
          r.AreEnemies=function(self,a,b) return a~=b end
          for i,kind in ipairs(keys) do
            local target=r:SelectFactionPrimaryTarget(kind); local closest=math.huge
            for _,enemy in ipairs(keys) do if enemy~=kind then closest=math.min(closest,bases[kind].Position:getDistance(bases[enemy].Position)) end end
            assert(math.abs(bases[kind].Position:getDistance(target.Position)-closest)<1,'cluster AI used slot order instead of geometry')
            assert(math.abs(bases[kind].Position:getDistance(r:GetFactionBattleFacingPoint(kind))-closest)<1,'station/spawn facing used distant world center')
            local point=r:NativeGetSpawnFrame(bases[kind],class('GTF Layout Scout'),1,1)
            local heading=r:GetFactionBattleFacingPoint(kind)-bases[kind].Position
            local delta=point-bases[kind].Position
            assert(heading.x*delta.x+heading.z*delta.z>0,'new unit spawned behind the local battle direction: '..kind..' key='..tostring(r:GetFactionKey(bases[kind]))..' delta='..delta.x..','..delta.z..' heading='..heading.x..','..heading.z)
          end
          local groups={}; for i=1,8 do groups[i]={id='group'..i,value=100} end
          r:AssignAIAssaultFronts('BLUE',groups,r:SelectFactionPrimaryTarget('BLUE'))
          for _,g in ipairs(groups) do assert(g.primary==bases.GOLD or g.primary==bases.FACTION_05,'fleet split across remote clusters') end
          bases.GOLD.HitpointsLeft=0; bases.FACTION_05.HitpointsLeft=0
          r:AssignAIAssaultFronts('BLUE',groups,r:SelectFactionPrimaryTarget('BLUE'))
          for _,g in ipairs(groups) do assert(g.primary and g.primary.HitpointsLeft>0,'fleet stayed on a defeated local front') end
        ''')

    def test_compute_class_role_precedence_and_fallbacks(self):
        # Order is the contract: explicit production role, then roster role, then the
        # name prefixes, then hull radius. Each rung is reached only when the one above misses.
        self.check('''
          r.Config.ProductionClasses={{class='Known Hull',role='bomber'},{class='Roleless Hull'}}
          r.GetFactionKeys=function() return {'BLUE'} end
          r.GetAIRosterEntry=function(self,kind,name)
            if name=='Rostered' then return {role='capital'} end
            if name=='Rostered Plain' then return {} end
            return nil
          end
          local function hull(name,radius) return {Class={Name=name,Model={Radius=radius}}} end
          assert(r:ComputeClassRole(hull('Known Hull',10))=='bomber', 'explicit production role wins')
          assert(r:ComputeClassRole(hull('Roleless Hull',10))=='combat', 'a production entry without a role is combat')
          assert(r:ComputeClassRole(hull('Rostered',10))=='capital', 'roster role wins over radius')
          assert(r:ComputeClassRole(hull('Rostered Plain',10))=='combat', 'a roster entry without a role is combat')
          assert(r:ComputeClassRole(hull('GTB Test',10))=='bomber', 'GTB prefix is a bomber')
          assert(r:ComputeClassRole(hull('gvb test',10))=='bomber', 'GVB prefix matches case-insensitively')
          assert(r:ComputeClassRole(hull('SB Test',10))=='bomber', 'SB prefix is a bomber')
          assert(r:ComputeClassRole(hull('Big Test',700))=='capital', 'radius 700 is a capital')
          assert(r:ComputeClassRole(hull('Small Test',699))=='fighter', 'below 700 falls back to fighter')
          assert(r:ComputeClassRole({Class={Name=nil,Model=nil}})=='fighter', 'an unnamed hull without a model is a fighter')
        ''')

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(SETUP)
        self.lua.execute('''
          for _,source in ipairs({'BlueRoster','RedRoster','GoldRoster'}) do
            for _,entry in ipairs(r.Config.AI[source]) do
              if not tb.ShipClasses[entry.class] then class(entry.class) end
            end
          end
          r:BuildShipCostMap()
        ''')

    def check(self, code):
        self.lua.execute(code)

    def test_each_faction_has_exact_unique_role_complete_roster_and_ability(self):
        self.check('''
          local total=0; local names={}
          for choice,profile in pairs(r.Config.FactionProfiles) do
            total=total+1
            assert(r:SetFactionChoice('BLUE',choice))
            assert(r:GetFactionChoice('BLUE')==choice and r:GetFactionSpecies('BLUE')==profile.species)
            local roster=r:GetAIRoster('BLUE'); local seen={}; local roles={}
            assert(#roster==#profile.classes,choice..' roster does not match curated hulls')
            for _,entry in ipairs(roster) do
              assert(not seen[entry.class],choice..' duplicated '..entry.class)
              seen[entry.class]=true; roles[entry.role]=true
              assert(r:GetPurchaseEstimate(entry.class,entry.tier,1).cost>0)
            end
            assert(roles.fighter and roles.bomber and roles.escort and (roles.capital or roles.heavy or roles.juggernaut),choice..' lacks a combat role')
            local a=r:GetFactionAbilityProfile('BLUE')
            assert(a.kind and a.cost>0 and not names[a.name],choice..' has a free or duplicate ability')
            names[a.name]=true
            assert(profile.insignia,'faction insignia is missing')
          end
          assert(total==9,'original faction family is incomplete')
        ''')

    def test_political_identity_mirrors_and_invalid_selection(self):
        self.check('''
          assert(r:SetFactionChoice('BLUE','GTI_ROGUE') and r:SetFactionChoice('RED','GTI_ROGUE'))
          assert(r:GetFactionSpecies('BLUE')=='TERRAN' and r:GetFactionChoice('BLUE')=='GTI_ROGUE')
          assert(r:AreEnemies(stations.BLUE,stations.RED),'mirror political factions lost hostility')
          assert(not r:SetFactionChoice('BLUE','unknown') and r:GetFactionChoice('BLUE')=='GTI_ROGUE')
          r:SetFactionChoice('BLUE','RANDOM'); r:ResolveRandomFactionSpecies()
          assert(r.Config.FactionProfiles[r:GetFactionChoice('BLUE')],'random selected a species alias instead of a political faction')
          assert(r:SetFactionSpecies('BLUE','TERRAN') and r:GetFactionChoice('BLUE')=='GTA','legacy species API broke')
        ''')

    def test_each_profile_has_a_bundled_insignia(self):
        from pathlib import Path
        maps=Path(__file__).resolve().parents[1]/'data/maps'
        for _,profile in self.lua.globals().r.Config.FactionProfiles.items():
            name=profile.insignia
            self.assertTrue(any((maps/(name+ext)).is_file() for ext in ('.pcx','.png')),name)

    def test_curated_faction_hulls_exist_in_stock_fs2_retail(self):
        path=retail_tables.retail_ships_table()
        if path is None:
            self.skipTest('optional retail ships.tbl is unavailable')
        retail=retail_tables.parse_names(retail_tables.read(path))
        bundled=retail_tables.mod_defined_names()
        for choice,profile in self.lua.globals().r.Config.FactionProfiles.items():
            for name in profile.classes.values():
                if name not in retail:
                    self.assertIn(name,bundled,f'{choice} hull is neither retail nor bundled: {name}')

    def test_bundled_fs1_models_have_closed_texture_and_weapon_dependencies(self):
        from pathlib import Path
        root=Path(__file__).resolve().parents[1]/'data'
        table=(root/'tables/fs2rts-fs1-ships-shp.tbm').read_text(encoding='utf-8')
        profiles={
            'GTF Apollo':('fighter04.pof',{'fighter04-01a','fighter04-01b','fighter04-01c','thruster01'}),
            'GTF Valkyrie':('fighter05.pof',{'fighter05-01a','fighter05-01b','fighter05-01c','thruster01'}),
            'GTB Athena':('bomber01.pof',{'bomber01-01a','bomber01-01b','bomber01-01c','thruster01'}),
            'PVF Anubis':('fighter02.pof',{'fighter02-01a','fighter02-01b','fighter02-01c','thruster02'}),
            'SB Shaitan':('bomber03.pof',{'bomber03-01a','bomber03-01b','bomber03-01c','thruster03'}),
        }
        retail_ships=retail_tables.parse_names(retail_tables.read(retail_tables.retail_ships_table()))
        retail_weapons=retail_tables.parse_weapon_names(retail_tables.read(retail_tables.retail_weapons_table()))
        for name,(pof,expected_textures) in profiles.items():
            self.assertNotIn(name,retail_ships)
            match=re.search(r'^\$Name: '+re.escape(name)+r'\s*$(.*?)(?=^\$Name:|^#End)',table,re.M|re.S)
            self.assertIsNotNone(match,name)
            body=match.group(1)
            self.assertIn('$POF file: '+pof,body)
            for weapon in re.findall(r'^\$(?:Allowed|Default) [PS]Banks:.*$',body,re.M):
                for dependency in re.findall(r'"([^"]+)"',weapon):
                    self.assertIn(dependency,retail_weapons,f'{name} needs optional weapon {dependency}')

            model=(root/'models'/pof).read_bytes()
            self.assertEqual(model[:4],b'PSPO')
            textures=set(); pos=8
            while pos+8<=len(model):
                chunk=model[pos:pos+4]; size=struct.unpack_from('<i',model,pos+4)[0]; pos+=8
                self.assertGreaterEqual(size,0)
                self.assertLessEqual(pos+size,len(model),f'{name} malformed POF chunk')
                if chunk==b'TXTR':
                    count=struct.unpack_from('<i',model,pos)[0]; cursor=pos+4
                    for _ in range(count):
                        length=struct.unpack_from('<i',model,cursor)[0]; cursor+=4
                        textures.add(model[cursor:cursor+length].split(b'\0',1)[0].decode('ascii').lower())
                        cursor+=length
                    self.assertLessEqual(cursor,pos+size,f'{name} malformed texture list')
                pos+=size
            self.assertTrue(expected_textures.issubset(textures),f'{name} texture closure is incomplete: {textures}')
            for texture in textures:
                if texture.startswith('thruster'):
                    continue
                self.assertTrue((root/'maps'/f'{texture}.pcx').is_file(),f'{name} missing {texture}.pcx')

        for name in profiles:
            match=re.search(r'^\$Name: '+re.escape(name)+r'\s*$(.*?)(?=^\$Name:|^#End)',table,re.M|re.S)
            self.assertIsNotNone(match,name)
            self.assertIn('"generate icon"',match.group(1),name)

    def test_flagships_are_faction_restricted_and_player_ai_share_prices(self):
        self.check('''
          for choice in pairs(r.Config.FactionProfiles) do
            r:SetFactionChoice('BLUE',choice); r:SetFactionChoice('RED',choice)
            r:BuildProductionCatalog()
            local player={}; for _,option in ipairs(r.BuildCatalog) do player[option.class]=option end
            for _,entry in ipairs(r:GetAIRoster('RED')) do
              assert(player[entry.class],choice..' AI has an exclusive purchase')
              local count=(entry.role=='fighter' or entry.role=='bomber') and 4 or 1
              assert(player[entry.class].cost==r:GetPurchaseEstimate(entry.class,entry.tier,count).cost)
              if entry.class=='GTD Hades' then assert(choice=='GTI_ROGUE') end
              if entry.class=='SJ Sathanas' then assert(choice=='SHIVAN') end
              if entry.class=='GTVA Colossus' then assert(choice=='GTVA') end
            end
          end
          assert(r:GetPurchaseEstimate('GTD Hades',5,1).cost>=40000)
        ''')

    def test_multiship_reserves_require_all_slots_and_refund_only_failed_hulls(self):
        self.check('''
          r:SetFactionChoice('BLUE','PVN'); r.StationState.BLUE.levels.command=3
          local a=r:GetFactionAbilityProfile('BLUE')
          assert(a.cost==r:GetPurchaseEstimate(a.class,a.tier,4).cost,'ability undercuts ordinary production')
          r.CountCommittedCombatants=function(self,kind) return self:GetFleetCap(kind)-3 end
          local before=#ships; local cp=r.CommandPoints
          assert(not r:UseFactionAbility('BLUE') and #ships==before and r.CommandPoints==cp,'reserves bypassed the complete-wave fleet cap')
          assert(r.StationState.BLUE.abilityReadyAt==0)
          r.CountCommittedCombatants=function() return 0 end
          local originalCreate=mn.createShip; local calls=0
          mn.createShip=function(...)
            calls=calls+1; if calls==2 then return nil end
            return originalCreate(...)
          end
          assert(r:UseFactionAbility('BLUE') and #ships==before+3)
          assert(r.CommandPoints==cp-a.cost+math.floor(a.cost/4),'partial reinforcement refund is wrong')
          assert(r.StationState.BLUE.abilityReadyAt==now+180)
          assert(r.NewUnitPopup and #r.NewUnitPopup.signatures==3,'reserves cannot be selected from arrival popup')
          assert(not r:UseFactionAbility('BLUE') and #ships==before+3,'partial wave duplicated on retry')
        ''')

    def test_classic_heavy_prices_reduce_the_shared_hull_estimate(self):
        self.check('''
          local hull=class('GTD Orion')
          r.ShipCostRoleMap['GTD Orion']='heavy'
          local discounted=r:EstimateShipCost(hull)
          local original=r.Config.CostFormula.ClassMultipliers['GTD Orion']
          r.Config.CostFormula.ClassMultipliers['GTD Orion']=nil
          local baseline=r:EstimateShipCost(hull)
          r.Config.CostFormula.ClassMultipliers['GTD Orion']=original
          assert(discounted.cost<=baseline.cost*.65,'classic destroyer still uses the oversized radius price')
          assert(r.Config.CostFormula.ClassMultipliers['GVD Typhon']==original,'classic fleets use inconsistent hull pricing')
        ''')

    def test_surge_is_paid_role_limited_nonstacking_and_expires(self):
        self.check('''
          r:SetFactionChoice('BLUE','NTF'); r.StationState.BLUE.levels.command=3
          local pos=stations.BLUE.Position
          local fighter=ship('fighter',class('GTF Loki'),pos,mn.Teams.friendly); fighter.role='fighter'
          local bomber=ship('bomber',class('GTB Medusa'),pos,mn.Teams.friendly); bomber.role='bomber'
          local hostile=ship('hostile',class('SF Mara'),pos,mn.Teams.hostile); hostile.role='fighter'
          r.CommandPoints=749
          assert(not r:UseFactionAbility('BLUE') and fighter.Physics.VelocityMax.z==100,'surge admitted a short bank')
          assert(r.CommandPoints==749 and r.StationState.BLUE.abilityReadyAt==0)
          r.CommandPoints=1000
          assert(r:UseFactionAbility('BLUE') and r.CommandPoints==250)
          assert(fighter.Physics.VelocityMax.z==160 and bomber.Physics.VelocityMax.z==100 and hostile.Physics.VelocityMax.z==100,'surge changed an excluded role or faction')
          assert(stations.BLUE.Physics.VelocityMax.z==100,'command station was accelerated')
          assert(not r:UseFactionAbility('BLUE') and fighter.Physics.VelocityMax.z==160)
          now=20; r:UpdateStations(now)
          assert(fighter.Physics.VelocityMax.z==100 and next(r.SurgedShips)==nil)
          r.AftermathActive=true; now=300
          assert(not r:UseFactionAbility('BLUE') and r.CommandPoints==250)
        ''')

    def test_ai_paid_abilities_respect_bounded_fleet_savings(self):
        self.check('''
          r:SetFactionChoice('BLUE','PVN')
          r.StationState.BLUE.levels={armor=3,defenses=3,logistics=3,command=3}
          r.AIStates.BLUE={cp=3000,playerEconomy=true,productionReserve=10000,savingRole='capital:4'}
          r.CommandPoints=3000
          r.Config.Station.AI.CapitalAwareInvestment=true
          r.Config.Station.AI.CapitalAwareInvestmentMaxSeconds=90
          r.CountCommittedCombatants=function() return 8 end
          r.CountFactionCombatants=function() return 8 end
          r.GetFactionSentries=function() return {} end
          r.GetSentryOptions=function() return {} end
          r.BuyUpgrade=function() return false end
          r.IsAbilityReady=function() return true end
          local calls=0; r.UseFactionAbility=function() calls=calls+1; return true end
          local state=r.StationState.BLUE
          state.nextAIThink=0; stationAI(r,'BLUE',state,stations.BLUE,0)
          assert(state.capitalGateSince==0,'precondition: fleet savings gate was not active')
          assert(calls==0,'AI paid ability consumed the protected fleet savings')
          state.nextAIThink=0; stationAI(r,'BLUE',state,stations.BLUE,89.99)
          assert(calls==0,'ability released the savings gate too early')
          state.nextAIThink=0; stationAI(r,'BLUE',state,stations.BLUE,90)
          assert(calls==1,'bounded savings gate permanently blocked the ability')
          r.AIStates.BLUE.savingRole=nil; state.nextAIThink=0
          stationAI(r,'BLUE',state,stations.BLUE,91)
          assert(calls==2,'ordinary ability dispatch remained blocked')
        ''')

    def test_ship_demo_prefix_is_canonicalized_like_upstream(self):
        self.assertEqual(retail_tables.parse_names('$Name: @GTC Fenris ;; original demo marker\n'), {'GTC Fenris'})

    def test_new_capital_classes_are_counted_in_battle_losses(self):
        self.check('''
          r:PrimeRosterCostMap()
          r.AIStats.losses.BLUE={['GTD Hades']=1,['NTF Boadicea']=2,['NTF Iceni']=3,['GTF Ulysses']=4}
          local summary=r:BuildBattleSummary()
          assert(summary.losses==10 and summary.capitalLosses==6,'new capital losses vanished from the battle report')
        ''')

    def test_mission_uses_rts_outcomes_and_retains_native_tactical_directives(self):
        from pathlib import Path
        text=(Path(__file__).resolve().parents[1]/'data/missions/FS2_RTS_Escalation.fs2').read_text(encoding='utf-8')
        goals=text.split('#Goals',1)[1].split('#Waypoints',1)[0]
        self.assertEqual(goals.strip(),'','a fixed native goal conflicts with dynamic elimination/survivor outcomes')
        for name in ('RTS Pilot Task','RTS Pilot Target','RTS Pilot Phase','RTS Pilot Reason'):
            self.assertIn('+Name: '+name,text)
        self.assertNotIn('RTS Red Station',text)
        # Bases are spawned by StartScenario when the player presses START; the mission
        # must not place them, or the setup screen would show bases before the start.
        self.assertNotIn('$Name: RTS Team 01 Station',text)
        self.assertNotIn('$Name: RTS Team 02 Station',text)

    def test_random_and_selected_colors_never_duplicate_and_conflicts_swap(self):
        self.check('''
          local function unique()
            local seen={}
            for _,kind in ipairs(r.Config.FactionOrder) do
              local red,green,blue=r:GetFactionColor(kind)
              local rgb=red..'/'..green..'/'..blue
              assert(not seen[rgb],'two factions share a color'); seen[rgb]=true
              local label=r:GetFactionDefinition(kind).short
              assert(label~='BLUE' and label~='RED' and label~='GOLD','color names still label factions')
            end
          end
          local random=math.random; local draws=0
          math.random=function(n) draws=draws+1; return 1 end
          r:RandomizeFactionColors(); math.random=random
          assert(draws>0 and r:GetFactionColorIndex('BLUE')~=1,'initial colors were not randomized')
          unique()
          package.loaded.fs2rts_factions=nil; require 'fs2rts_factions'
          assert(#r.Config.FactionOrder==12,'module reload duplicated faction slots')
          r:RandomizeFactionColors(); unique()
          local blue,red=r:GetFactionColorIndex('BLUE'),r:GetFactionColorIndex('RED')
          assert(r:SetFactionColor('BLUE',red))
          assert(r:GetFactionColorIndex('BLUE')==red and r:GetFactionColorIndex('RED')==blue,'occupied color did not swap owners')
          unique()
          assert(not r:SetFactionColor('BLUE',0) and not r:SetFactionColor('BLUE',13) and not r:SetFactionColor('BLUE',1.5))
          assert(r:GetFactionColorIndex('BLUE')==red,'invalid color changed the selection')
          for i=1,25 do r:RandomizeFactionColors(); unique() end
        ''')

    def test_color_picker_click_changes_the_player_and_fits_small_viewports(self):
        from test_feature_request import boot
        lua=boot()
        lua.execute('''
          r.SetupFactionCountChoice=12; r:UpdateFactionCount()
          for _,size in ipairs({{640,480},{800,600},{1280,720},{1920,1080}}) do
            r.SetupColorPicker=nil; r:DrawSetupOverlay(size[1],size[2])
            local button=r.SetupButtonRects.color_BLUE
            assert(button and r:HandleSetupClick((button.x1+button.x2)/2,(button.y1+button.y2)/2))
            r:DrawSetupOverlay(size[1],size[2])
            assert(r.SetupColorPicker=='BLUE')
            for _,rect in pairs(r.SetupColorRects) do
              assert(rect.x1>=0 and rect.y1>=0 and rect.x2<=size[1] and rect.y2<=size[2],'color picker leaves viewport')
            end
            local wanted=r:GetFactionColorIndex('RED'); local rect=r.SetupColorRects[wanted]
            assert(r:HandleSetupClick((rect.x1+rect.x2)/2,(rect.y1+rect.y2)/2))
            assert(r:GetFactionColorIndex('BLUE')==wanted and not r.SetupColorPicker,'color picker ignored its chosen swatch')
          end
        ''')

    def test_generated_names_fit_upstream_buffer_and_remain_unique_at_large_serials(self):
        self.check('''
          local native=mn.createShip; local seen={}
          mn.createShip=function(name,...)
            assert(#name<=31,'generated name exceeds upstream 32-byte buffer: '..name)
            assert(not seen[name],'generated names collide after truncation: '..name)
            seen[name]=true
            return native(name,...)
          end
          r.GeneratedShipNameSerial=1000000
          r.EnemySerial=128
          for i=129,140 do
            r:SpawnFactionUnit('GTF Ulysses',stations.BLUE,mn.Teams.friendly,'RTS TEAM 04 Production',2,13,i,1,1)
          end
          r:SpawnFriendly({class='GTF Ulysses',label=string.rep('Long ship label ',5),role='fighter',count=1})
          local a=r:GetSafeShipName('Already short')
          assert(a=='Already short','safe existing display names were rewritten')
        ''')


if __name__ == '__main__':
    unittest.main()
