"""Player feedback regressions. Native combat/geometry remains a separate probe."""
import unittest

from test_feature_request import boot


class PlayerFeedbackTests(unittest.TestCase):
    def test_selected_contact_clusters_keep_counts_classes_factions_and_damage(self):
        self.check('''
          local a=mkFighter('Close A'); local b=mkFighter('Close B'); local far=mkFighter('Far')
          b.Class=a.Class; far.Class=a.Class
          local other=mkFighter('Other class'); other.Class=class('GTF Hercules')
          b.HitpointsLeft=b.HitpointsMax*.2
          local glyphs,bars,text={}, {}, {}
          r.DrawReticle=function(self,ship,x,y,size) return size/2 end
          r.DrawRoleMarker=function(self,ship) glyphs[#glyphs+1]=ship end
          r.DrawHullBarForShip=function(self,ship) bars[#bars+1]=ship end
          gr.drawString=function(value) text[#text+1]=value end
          local groups=r:DrawSelectedReticleGroups({{ship=a,x=500,y=400,size=36},{ship=b,x=508,y=405,size=36},
            {ship=far,x=700,y=400,size=36},{ship=other,x=504,y=402,size=36}})
          assert(#groups==3 and #glyphs==3 and groups[1].count==2 and bars[1]==b,'selection lost a class, count or damaged hull')
          assert(table.concat(text,' '):find('x2',1,true),'cluster does not advertise its represented ships')
          local total=0; for _,g in ipairs(groups) do total=total+g.count end
          assert(total==4,'cluster hid selected ships')
        ''')

    def test_capital_portrait_uses_native_gauge_coordinates_and_restores_override(self):
        self.check('''
          local hull=mkFighter('Portrait owner'); hull.Shields={CombinedMax=0}; hull.HitpointsMax=1000; hull.HitpointsLeft=500
          local target=mkFighter('Shielded target'); target.Shields={CombinedMax=400}; hull.Target=target
          r.GetPossessedShip=function() return hull end; r.IsCapitalTarget=function(self,s) return s==hull end
          local texture={isValid=function() return true end}
          r.GetShipThumbTexture=function(self,name) assert(name==hull.Class.Name); return texture end
          local gauges={}
          -- The engine's HudGauge has no isValid method (any call raises "Could not find
          -- index"), so the double must not provide one: a gauge is valid when it is non-nil.
          for _,name in ipairs({'Player shield','Target shield'}) do gauges[name]={
            setRenderOverride=function(self,value) self.overridden=value end,getPosition=function() return 600,650 end,
            getBaseResolution=function() return 1024,768 end} end
          hu={getHUDGaugeHandle=function(name) return gauges[name] end}
          local resized,drawn,caption=false,false,false
          gr.setScreenScale=function(w,h) assert(w==1024 and h==768); resized=true end
          gr.resetScreenScale=function() resized=false end
          GR_RESIZE_FULL='FULL'; gr.CurrentResizeMode='NONE'
          gr.drawImage=function(t,x1,y1,x2,y2) assert(t==texture and resized and x1==616 and y1==650 and x2==696 and y2==730); drawn=true end
          gr.drawString=function(text) if text=='HULL 50%' then caption=true end end
          r:DrawPilotHullHUD()
          assert(drawn and caption and gauges['Player shield'].overridden and not gauges['Target shield'].overridden)
          assert(not resized and gr.CurrentResizeMode=='NONE','portrait leaked HUD scaling')
          r:RestorePilotHullHUD(); assert(not gauges['Player shield'].overridden and not r.PilotHullHUDOverrides)
        ''')

    def test_pilot_cycles_show_every_weapon_type_with_readable_names(self):
        self.check('''
          local pilot=mkFighter('Cycle owner'); r.GetPossessedShip=function() return pilot end
          r.GetPilotWingmates=function() return {},nil end; r.PilotTurretGroups={{label='All',turrets={}}}
          r.GetPilotWeaponInventory=function() return {primary=24,secondary=0,beams=9,localTargets=2,ranges={primary=4000,secondary=0}} end
          local names={'Green heavy beam','Terran slash beam','Terran anti-fighter beam','Heavy laser','Defense laser'}
          r.GetPilotWeaponCycles=function() local rows={}; for _,name in ipairs(names) do rows[#rows+1]={name=name,ready=1,total=1,left=0} end; return rows end
          local text={}; gr.drawString=function(value) text[#text+1]=value end
          r:DrawPilotHUD(1280,720); local all=table.concat(text,' ')
          for _,name in ipairs(names) do assert(all:find(name,1,true),'weapon cycle type hidden: '..name) end
          assert(all:find('LOCAL GUNNERS: 2',1,true) and not all:find('weapon types;',1,true))
          assert(r:GetWeaponDisplayName('BGreen')=='Green heavy beam')
        ''')

    def test_body_font_uses_existing_larger_face_and_restores_native_font(self):
        self.check('''
          local native={isValid=function() return true end}; local body={isValid=function() return true end}
          gr.Fonts={[1]=native,[3]=body}; gr.CurrentFont=native
          r.GetShipList=function() return {} end; r.GetShipAtScreen=function() return nil end
          local seen=false; r.DrawTopBar=function() assert(gr.CurrentFont==body); seen=true end
          r:DrawHUD(); assert(seen and gr.CurrentFont==native,'UI font escaped into a native gauge')
        ''')

    def test_world_hover_is_blocked_by_rts_panels(self):
        self.check('''
          r.IsPointOnRTSUI=function() return true end
          r.GetShipAtScreen=function() assert(false,'world hover ran through a UI panel') end
          r.GetShipList=function() return {} end
          r.Selected={}; r.HoveredSelectionSigs={}; r:DrawWorldOverlays()
          assert(r.HoverReadout==nil)
        ''')

    def test_pilot_comm_keeps_custom_panel_out_of_native_menu_and_resets_on_close(self):
        self.check('''
          local pilot=mkFighter('UI pilot'); r.PossessedSignature=pilot.signature
          r.GetPossessedShip=function() return pilot end
          r:OnPilotCommMenuOpened()
          assert(r.PilotCommMenuActive,'comm visibility disappeared after submenu routing')
          local draws=0; gr.drawString=function() draws=draws+1 end
          r:DrawPilotHUD(1280,720); assert(draws==0,'custom panel obscures native comms')
          r:OnPilotCommMenuClosed(); assert(not r.PilotCommMenuActive and not r.PilotCommMenuPending)
          r:DrawPilotHUD(1280,720); assert(draws>0,'pilot panel did not return after comm close')
        ''')

    def test_control_legend_names_actual_pause_and_exit_actions(self):
        self.check('''
          local text=table.concat(r:GetControlLegendLines(),' '):lower()
          assert(text:find('space pause',1,true) and text:find('esc exit menu',1,true))
          assert(not text:find('esc pause',1,true))
        ''')

    def test_digit_groups_shift_assign_and_alt_speed_are_disjoint(self):
        self.check('''
          r.SetupActive=false; r.CinematicActive=false; r.PossessedSignature=nil
          local recalled,assigned,speed
          r.RecallControlGroup=function(self,n) recalled=n end
          r.AssignControlGroup=function(self,n) assigned=n end
          r.SetTimeScale=function(self,n) speed=n end
          r.SetPaused=function(self,p) self.Paused=p end
          r:OnKeyPressed('1','1'); assert(recalled==1 and speed==nil,'digit controls time instead of group')
          r:OnKeyPressed('Shift-2','2'); assert(assigned==2,'shift digit does not assign group')
          r:OnKeyReleased('Shift','Shift')
          r:OnKeyPressed('Alt-3','3'); assert(speed==4 and recalled==1,'alt digit steals group recall')
          assert(not r:ShouldOverrideKey('F1','F1'),'removed F1 binding is still captured')
          r:SetPaused(true); r:OnKeyPressed('4','4'); assert(recalled==4 and r.Paused,'paused group recall changes speed or is blocked')
          r:OnKeyPressed('Shift-1','1'); assert(assigned==1 and r.Paused,'paused group assignment is blocked')
        ''')

    def test_weapon_cycle_readout_respects_bank_slots_rate_groups_and_empty_mounts(self):
        self.check('''
          local function weapon(name,wait) return {Name=name,FireWait=wait,isValid=function() return true end,isBeam=function() return false end} end
          local a={HitpointsLeft=10,isValid=function() return true end,PrimaryBanks={{WeaponClass=weapon('Beam cycle',20)}},
            SecondaryBanks={{WeaponClass=weapon('Missile cycle',10),AmmoMax=5,AmmoLeft=5}}}
          local empty={HitpointsLeft=10,isValid=function() return true end,PrimaryBanks={},
            SecondaryBanks={{WeaponClass=weapon('Dry missiles',40),AmmoMax=5,AmmoLeft=0}}}
          local entry={subsystem=a,cooldowns={[1]=now+12,[4]=now+3}}
          r.PilotTurretGroups={{turrets={entry}},{turrets={{subsystem=empty}}}}
          r.PilotTurretGroupIndex=1
          local cycles=r:GetPilotWeaponCycles()
          assert(#cycles==2 and cycles[1].left==12 and cycles[2].left==3,'weapon cycles use the wrong slots or ignore elapsed time')
          assert(cycles[1].ready==0 and cycles[2].ready==0)
          now=now+4; cycles=r:GetPilotWeaponCycles()
          assert(cycles[2].ready==1 and cycles[1].left==8,'cycle readout does not count down')
          r.PilotTurretGroupIndex=2; assert(#r:GetPilotWeaponCycles()==0,'empty batteries display ready cycles')
          r:ReleaseObjectHandles(); assert(not r.PilotWeaponCycleReadout or next(r.PilotWeaponCycleReadout)==nil,'restart keeps cooldown handles')
        ''')

    def test_native_shield_transfer_on_pilot_proxy_reaches_real_ship(self):
        self.check('''
          local real=mkFighter('Real pilot ship'); local proxy=mkFighter('Observer proxy')
          real.Orientation={copy=function(self) return self end}
          real.Shields={CombinedLeft=400,CombinedMax=400,[1]=100,[2]=100,[3]=100,[4]=100}
          proxy.Shields={CombinedLeft=400,CombinedMax=400,[1]=0,[2]=0,[3]=0,[4]=0}
          r.PilotShieldMirrorSnapshot=nil; r:MirrorPilotTelemetryToObserver(real,proxy)
          -- Simulate FSO's native front-shield augment, then a real hull hit in
          -- the same frame. The proxy's delta must reach the possessed ship
          -- without restoring its damage or being replayed on the next sync.
          proxy.Shields[1]=130; proxy.Shields[2]=90; proxy.Shields[3]=90; proxy.Shields[4]=90
          real.Shields[4]=80
          r:MirrorPilotTelemetryToObserver(real,proxy)
          assert(real.Shields[1]==130 and real.Shields[2]==90 and real.Shields[3]==90 and real.Shields[4]==70,
            'native shield distribution stayed on the observer proxy or overwrote real shield damage')
          r:MirrorPilotTelemetryToObserver(real,proxy)
          assert(real.Shields[1]==130 and real.Shields[4]==70,'unchanged proxy shield state was applied twice')
        ''')

    def test_manual_energy_transfer_on_proxy_reaches_live_ship_once(self):
        self.check('''
          local real=mkFighter('Real energy owner'); local proxy=mkFighter('Control proxy')
          real.Orientation={copy=function(self) return self end}
          real.WeaponEnergyLeft=80; real.WeaponEnergyMax=100; proxy.WeaponEnergyLeft=0
          r.PilotWeaponEnergyMirrorSnapshot=nil; r:MirrorPilotTelemetryToObserver(real,proxy)
          proxy.WeaponEnergyLeft=60; real.WeaponEnergyLeft=75
          r:MirrorPilotTelemetryToObserver(real,proxy)
          assert(real.WeaponEnergyLeft==55,'native energy transfer was discarded or restored real firing cost')
          r:MirrorPilotTelemetryToObserver(real,proxy)
          assert(real.WeaponEnergyLeft==55,'proxy energy transfer was replayed twice')
        ''')

    def test_control_groups_exclude_stations_and_comm_expands_group(self):
        self.check('''
          local pilot=mkFighter('pilot'); local mate=mkFighter('mate'); local grouped=mkFighter('grouped')
          r.PossessedSignature=pilot.signature; r:RegisterLogicalWing({pilot,mate},'Wing')
          r.Selected={pilot.signature,grouped.signature,stations.BLUE.signature}
          r:AssignControlGroup(1)
          assert(#r.ControlGroups[1]==2,'station entered a control group')
          local members=r:GetPilotWingmates(); local found=false
          for _,s in ipairs(members) do if s==grouped then found=true end end
          assert(found,'comm ignores the possessed ships control group')
          local recipient={forAllShips=function(self,f) f(grouped) end}
          assert(r:ShouldOverridePilotCommOrder(recipient,'Depart'),'depart is still permitted')
        ''')

    def test_manual_move_cannot_be_diverted_and_keeps_ownership_on_arrival(self):
        self.check('''
          local unit=mkFighter('Manual mover',ba.createVector(0,0,-6000))
          unit.flags={}; function unit:setFlag(v,n) self.flags[n]=v end
          r.Selected={unit.signature}; r.testSelection={unit}; r.AutoPlayerMode=true
          r:IssueMove(ba.createVector(0,0,-4000))
          assert(unit:getFlag('no-dynamic'),'manual move still accepts a native hit diversion')
          r:OnWaypointsDone(unit)
          assert(r.UserOrders[unit.signature].kind=='hold','plain move hands the ship back to automatic combat')
          r:EngageSelected(); assert(not unit:getFlag('no-dynamic'),'attack loses native combat reactions')
          unit.flags['no-dynamic']=true
          r:IssueMove(ba.createVector(0,0,-4000)); r:ReleaseSelected()
          assert(unit:getFlag('no-dynamic'),'release overwrites a flag owned by the mission')
        ''')

    def test_isolated_fighter_rejoins_support_instead_of_charging_a_station(self):
        self.check('''
          r.AutoPlayerMode=true
          local unit=mkFighter('Straggler',ba.createVector(0,0,6000))
          local support=mkHull('GTC Aeolus',ba.createVector(0,0,0),'escort')
          r.GetShipList=function() return {unit,support,stations.RED} end
          local rally=r:GetAICombatRally({units={unit},role='fighter'},stations.RED,'PRIMARY',{})
          assert(rally==support,'isolated fighter attacks a fortified station alone')
          support.Position=unit.Position+ba.createVector(400,0,0)
          assert(r:GetAICombatRally({units={unit},role='fighter'},stations.RED,'PRIMARY',{})==nil,'fighter with support is forbidden to fight')
          support.Position=ba.createVector(0,0,0)
          assert(r:GetAICombatRally({units={unit},role='fighter'},stations.RED,'FEINT',{})==nil,'deliberate feint is removed')
          assert(r:GetAICombatRally({units={unit},role='fighter'},stations.RED,'INTERCEPT',{emergency=true})==nil,'emergency defense is blocked')
        ''')

    def test_fighter_station_guard_blocks_hull_and_turret_damage(self):
        self.check('''
          local added={}; engine={addHook=function(name,fn,conditions,override)
            added[#added+1]={name=name,fn=fn,conditions=conditions,override=override}; return true
          end}
          r.BaseDamageProtectionHooks=nil; r:RegisterBaseDamageProtection()
          assert(#added==7,'base protection is missing a collision or projectile-lifetime hook')
          local shipHook,createdHook,deletedHook,beamFireHook,beamDeathHook
          for _,hook in ipairs(added) do if (hook.conditions or {}).Ship==stations.RED.Name then
            if hook.name=='On Ship Collision' then shipHook=hook.override end
          else
            if hook.name=='On Weapon Created' then createdHook=hook.fn end
            if hook.name=='On Weapon Delete' then deletedHook=hook.fn end
            if hook.name=='On Beam Fire' then beamFireHook=hook.fn end
            if hook.name=='On Beam Death' then beamDeathHook=hook.fn end
          end end
          assert(shipHook and createdHook and deletedHook and beamFireHook and beamDeathHook,
            'enemy station has no complete native damage guard')
          local fighter=mkFighter('Attacking fighter')
          local bomber=mkHull('GTB Artemis',nil,'bomber')
          local capital=mkHull('GTC Orion',nil,'capital')
          local support=mkHull('Support hull',nil,'support')
          local function projectile(parent,id) return {Parent=parent,signature=id,getSignature=function(self) return self.signature end,isValid=function() return true end} end
          local shot=projectile(fighter,9001)
          hv={Weapon=shot}; createdHook()
          assert(r.BaseDamageProtectedWeapons[shot.signature],'fighter projectile owner is not cached at creation')
          local hullSubmodel={id='hull'}; local turretSubmodel={id='turret'}
          local turret={Submodel=turretSubmodel,HitpointsLeft=100,isTurret=function() return true end,
            getParent=function() return stations.RED end,isValid=function() return true end}
          stations.RED[1]=turret
          fighter.valid=false
          hv={Self=shot,Ship=stations.RED,Weapon=shot,ShipSubmodel=hullSubmodel}
          assert(shipHook(),'fighter projectile still damages a command station hull')
          hv.ShipSubmodel=turretSubmodel
          assert(shipHook() and turret.HitpointsLeft==100,'fighter projectile damages a station turret')
          fighter.valid=true
          fighter.Target=stations.RED; fighter.TargetSubsystem=turret
          local aimedShot=projectile(fighter,9006); aimedShot.Class={Damage=10,isValid=function() return true end,isBeam=function() return false end}
          hv={Self=aimedShot,Ship=stations.RED,Weapon=aimedShot,ShipSubmodel=hullSubmodel}
          assert(shipHook() and turret.HitpointsLeft==100,
            'selecting a turret lets fighter hull impacts damage the subsystem')
          fighter.Target=nil; fighter.TargetSubsystem=nil
          aimedShot=projectile(fighter,9007); aimedShot.Class={Damage=10,isValid=function() return true end,isBeam=function() return false end}
          hv={Self=aimedShot,Ship=stations.RED,Weapon=aimedShot,ShipSubmodel=turretSubmodel}
          assert(shipHook() and turret.HitpointsLeft==100,
            'direct fighter turret-submodel hit is not blocked')
          hv.Weapon=projectile(bomber,9002); hv.ShipSubmodel=hullSubmodel
          assert(not shipHook(),'bomber damage was blocked')
          hv.Weapon=projectile(support,9005); assert(shipHook(),'support hull damage was allowed')
          hv={Self=stations.RED,ShipB=fighter}; assert(shipHook(),'fighter ram still collides with command station')
          hv.ShipB=bomber; assert(not shipHook(),'bomber ram was blocked')
          hv.ShipB=support; assert(shipHook(),'support hull ram was allowed')
          local beam={ParentShip=fighter,signature=9003,getSignature=function(self) return self.signature end,isValid=function() return true end}
          beam.Class={Damage=20,isValid=function() return true end,isBeam=function() return true end}
          hv={Beam=beam}; beamFireHook(); fighter.valid=false
          hv={Self=beam,Ship=stations.RED,Beam=beam,ShipSubmodel=hullSubmodel}
          assert(shipHook(),'fighter beam still damages a command station hull')
          fighter.valid=true; fighter.Target=stations.RED; fighter.TargetSubsystem=turret
          ba.getMissionFrametime=function() return .5 end
          hv.ShipSubmodel=hullSubmodel
          assert(shipHook() and turret.HitpointsLeft==100,
            'fighter beam damages a selected station turret subsystem')
          ba.getMissionFrametime=nil
          fighter.TargetSubsystem=nil
          hv.Beam={ParentShip=capital,signature=9004,getSignature=function(self) return self.signature end,isValid=function() return true end}
          assert(not shipHook(),'capital beam damage was blocked')
          hv={Weapon=shot}; deletedHook(); assert(r.BaseDamageProtectedWeapons[shot.signature]==nil,'deleted projectile leaked its owner mark')
          hv={Beam=beam}; beamDeathHook(); assert(r.BaseDamageProtectedWeapons[beam.signature]==nil,'dead beam leaked its owner mark')
        ''')

    def test_fighter_blast_route_pages_once_preserves_bombers_and_rejects_failed_assets(self):
        self.check('''
          local created; engine={addHook=function(name,fn)
            if name=='On Weapon Created' then created=fn end; return true end}
          r.BaseDamageProtectionHooks=nil; r:RegisterBaseDamageProtection()
          local pages=0; local allow=true
          local variant={Name='RTSF Trebuchet',isValid=function() return true end,
            loadWeapon=function() pages=pages+1; return allow end}
          tb.WeaponClasses={['RTSF Trebuchet']=variant}
          local fighter=mkFighter('Fighter source')
          local bomber=mkHull('GTB Artemis',nil,'bomber')
          local function shot(parent,id)
            return {Parent=parent,Class={Name='Trebuchet'},signature=id,valid=true,
              isValid=function(self) return self.valid end,
              getSignature=function(self) return self.signature end,
              vanish=function(self) self.vanished=true; return true end}
          end
          local a=shot(fighter,7001); hv={Weapon=a}; created()
          assert(a.Class==variant and pages==1,'fighter shot was not protected after successful page-in')
          local b=shot(fighter,7002); hv={Weapon=b}; created()
          assert(b.Class==variant and pages==1,'variant assets were paged for every shot')
          local c=shot(bomber,7003); hv={Weapon=c}; created()
          assert(c.Class.Name=='Trebuchet' and pages==1,'bomber blast was replaced')
          r.FighterBlastVariantsLoaded={}; allow=false
          local failed=shot(fighter,7004); hv={Weapon=failed}; created()
          assert(failed.vanished and not r.BaseDamageProtectedWeapons[7004],
            'failed protected asset silently fell back to original fighter blast')
          r.FighterBlastVariantsLoaded={}; tb.WeaponClasses={}
          local missing=shot(fighter,7005); hv={Weapon=missing}; created()
          assert(missing.vanished,'missing bundled protection variant restored forbidden damage')
        ''')

    def test_pilot_kills_update_the_native_player_kill_gauge_once(self):
        self.check('''
          local pilot=mkFighter('Possessed fighter'); r.PossessedSignature=pilot:getSignature()
          local victim=ship('Enemy fighter',class('SF Mara'),ba.createVector(0,0,0),mn.Teams.hostile)
          local counts={}; local stats={MissionTotalKills=0}
          function stats:getMissionShipclassKills(class) return counts[class.Name] or 0 end
          function stats:setMissionShipclassKills(class,value) counts[class.Name]=value; return true end
          ba.getCurrentPlayer=function() return {Stats=stats,isValid=function() return true end} end
          local weapon={Parent=pilot,isValid=function() return true end,getBreedName=function() return 'Weapon' end}
          r.Enabled=true; r.BountyProcessed={}; r.AIStats={losses={},kills={},hits={}}
          r.GetFactionKey=function(self,s) return s==pilot and 'BLUE' or s==victim and 'RED' or nil end
          r.GetStrategicUnitValue=function() return 100 end
          r.IsCommandStation=function() return false end
          r.AreEnemies=function(_,a,b) return a~=b end
          r.IsFactionEnabled=function() return true end
          r.GetFactionCommandShip=function() return stations.BLUE end
          r.EmitAIEvent=function() end; r.ReleaseMoveWaypoint=function() end
          r:OnShipDeath(victim,weapon)
          assert(stats.MissionTotalKills==1 and counts[victim.Class.Name]==1,
            'kill from the possessed hull did not reach the native pilot HUD stats')
          r:OnShipDeath(victim,weapon)
          assert(stats.MissionTotalKills==1 and counts[victim.Class.Name]==1,
            'repeated death callback double-counted pilot kills')
        ''')

    def test_ai_sends_fighters_to_screen_and_rejects_station_strikes(self):
        self.check('''
          r.AutoPlayerMode=true; r.PossessedSignature=nil; r.UserOrders={}; r.AIOrderState={}
          -- test_station stubs this method for unrelated station-only tests;
          -- reload its real implementation for this cross-module behavior.
          -- The module is split into parts that require caches, so clear the
          -- cache first: dofile on the aggregator alone would keep the stub.
          for name in pairs(package.loaded) do
            if name:find('^fs2rts_strategy') then package.loaded[name]=nil end
          end
          dofile(scripts_path..'/fs2rts_strategy.lua')
          r.GetStablePrimaryTarget=function() return stations.RED end
          local fighter=mkFighter('AI fighter')
          assert(r:GetShipRole(fighter)=='fighter' and r:GetFactionKey(fighter)=='BLUE'
            and r:GetFactionCommandShip('BLUE')==stations.BLUE and r:CanDamageCommandStation(fighter,stations.RED)
            and not r:CanDamageBase(fighter),
            'fixture role='..tostring(r:GetShipRole(fighter))..' faction='..tostring(r:GetFactionKey(fighter))
              ..' own='..tostring(r:GetFactionCommandShip('BLUE')==stations.BLUE))
          assert(r.AutoPlayerMode and r.PossessedSignature==nil and r.UserOrders[fighter:getSignature()]==nil
            and r:GetStablePrimaryTarget('BLUE')==stations.RED and stations.RED.HitpointsLeft>0
            and not r:IsStaticDefense(fighter) and fighter.HitpointsLeft>0,
            'AI strategic-order preconditions are not satisfied')
          r:AssignAIStrategicOrder(fighter,'BLUE',true)
          local order=r.AIOrderState[fighter:getSignature()]
          assert(order and order.targetSignature==stations.BLUE:getSignature() and order.mission=='SCREEN',
            'idle AI fighter receives an enemy base strike instead of a home screen order')
          assert(sexps[#sexps]:find('(set-guard-range "'..stations.BLUE.Name..'"',1,true),
            'AI screen bypassed the upstream SEXP guard-range order')
          assert(not r:IssueStrategicOrder(fighter,stations.RED,'bad base strike','PRIMARY',0,true),
            'strategic order gate accepts a fighter base attack')
        ''')

    def test_player_station_attack_allows_fighter_pressure_and_bomber_siege(self):
        self.check('''
          local fighter=mkFighter('Player fighter')
          local bomber=mkHull('GTB Artemis',nil,'bomber')
          r.UserOrders={}; r.testSelection={fighter,bomber}
          local status; r.SetStatus=function(_,text) status=text end
          r:IssueAttack(stations.RED)
          assert(r.UserOrders[fighter:getSignature()] and r.UserOrders[fighter:getSignature()].kind=='attack',
            'fighter chip pressure cannot be explicitly ordered')
          assert(r.UserOrders[bomber:getSignature()] and r.UserOrders[bomber:getSignature()].kind=='attack',
            'bomber was blocked together with the fighter')
          assert(not string.find(status,'NON-STRIKE UNITS SKIPPED',1,true),'valid fighter pressure was reported as skipped')
        ''')

    def test_command_armor_covers_station_guns_without_armoring_fleet(self):
        self.check('''
          local fighter=mkFighter(nil,ba.createVector(0,0,0))
          r:ScaleCommandStationsForEscalation()
          for _,kind in ipairs({'BLUE','RED','GOLD'}) do
            if r:IsFactionEnabled(kind) then
              local station=stations[kind]
              for i=1,#station do assert(station[i].ArmorClass=='RTS Command Hull','station gun bypasses command armor') end
            end
          end
          assert(fighter.ArmorClass==nil,'command armor leaked onto fleet')
        ''')

    def test_station_screen_tracks_incoming_fighters_instead_of_remote_base(self):
        self.lua.execute('''
          local station=stations.RED; local turret=station[1]
          local weapon={Name=r.Config.Station.Sentries.ScreenWeapon,Range=6000,Speed=1200,LifeMax=5,isValid=function() return true end}
          turret.PrimaryBanks={{WeaponClass=weapon}}; turret.Target=stations.BLUE
          turret.isPositionInFOV=function(self,p) return p.z>=0 end
          local near=mkFighter('Incoming',station.Position+ba.createVector(0,0,4000))
          local own=ship('Red ally',class('SF Mara'),station.Position+ba.createVector(0,0,1000),mn.Teams.hostile)
          own.role='fighter'
          r.GetShipList=function() return {near,own,stations.BLUE} end
          r.CanAutoEngage=function(self,a,b) return self:AreEnemies(a,b) and not b.withdrawing end
          near.withdrawing=true
          r:UpdateStationPointDefense(10)
          assert(turret.Target==nil,'station point defense acquired a withdrawn ship')
          near.withdrawing=false; r.NextStationPointDefense=0
          r:UpdateStationPointDefense(10.5)
          assert(turret.Target==near,'point defense lost a normal hostile or targeted its own fighter')
          near.Position=station.Position+ba.createVector(0,0,-4000)
          r.NextStationPointDefense=0; r:UpdateStationPointDefense(11); assert(turret.Target==nil,'screen retains out-of-arc fighter')
        ''')

    def test_station_strike_auto_target_obeys_withdrawal_policy(self):
        self.lua.execute('''
          local fleeing=ship('withdrawing capital',class('SD Ravana'),ba.createVector(2000,0,0),mn.Teams.hostile)
          local ordinary=ship('ordinary capital',class('GTD Hecate'),ba.createVector(5000,0,0),mn.Teams.hostile)
          fleeing.HitpointsMax=10000; ordinary.HitpointsMax=5000
          r.GetShipList=function() return {stations.BLUE,fleeing,ordinary} end
          r.Withdrawals={[fleeing.signature]={faction='RED',inCorridor=true}}
          r.AllowWithdrawal={BLUE=true}
          assert(r:FindStrikeTarget('BLUE',stations.BLUE)==ordinary,
            'automated station strike ignored the withdrawing target rule')
          r.AllowWithdrawal.BLUE=false
          local retarget=r:FindStrikeTarget('BLUE',stations.BLUE)
          assert(retarget==fleeing,
            'station strike ignored explicit permission to intercept withdrawal; got '..tostring(retarget and retarget.Name)
            ..' permitted='..tostring(r:IsAutomaticTargetPermitted(stations.BLUE,fleeing))
            ..' engage='..tostring(r:CanAutoEngage(stations.BLUE,fleeing))
            ..' iff='..tostring(r:AreEnemies(stations.BLUE,fleeing)))
        ''')

    def test_capital_pursues_another_capital_and_refreshes_manual_target(self):
        self.lua.execute('''
          local own=mkHull('GTD pursuer',ba.createVector(0,0,-12000),'capital')
          local foe=ship('Enemy capital',class('SD target'),ba.createVector(0,0,12000),mn.Teams.hostile)
          foe.role='capital'; foe.Radius=1000
          r.testSelection={own}; r.SetUserOrder=REAL_SET_USER_ORDER
          r:IssueAttack(foe)
          assert(r.AIPursuit[own.signature],'capital vs capital target must install pursuit')
          local before=r.MoveWaypoints[own.signature].waypoint.Position
          foe.Position=ba.createVector(3000,0,12000)
          r:RefreshAIPursuit(20)
          assert(r.MoveWaypoints[own.signature].waypoint.Position:getDistance(before)>100,'moving target was not pursued')
        ''')

    def test_capital_pursuit_stays_outside_target_hull(self):
        self.check('''
          local own=mkHull('GTD pursuer',ba.createVector(0,0,-6000),'capital'); own.Radius=1400
          local foe=ship('Enemy capital',class('SD target'),ba.createVector(0,0,6000),mn.Teams.hostile)
          foe.role='capital'; foe.Radius=2000
          assert(r:IssuePursuitOrder(own,foe,.95))
          local route=r.MoveWaypoints[own.signature]
          local point=(route.route and route.route[#route.route] or route.waypoint).Position
          assert(point:getDistance(foe.Position)>=own.Radius+foe.Radius+600-.01,'capital pursuit aims inside enemy collision hull')
          assert(point:getDistance(own.Position)<foe.Position:getDistance(own.Position),'pursuit stopped approaching a distant enemy')
        ''')

    def test_defeated_ai_retaliates_and_explicit_player_withdrawal_passage_is_policy_gated(self):
        self.lua.execute('''
          local red=ship('Red survivor',class('SF Mara'),ba.createVector(0,0,0),mn.Teams.hostile)
          red.role='fighter'
          local blue=mkFighter('Near Blue',ba.createVector(0,0,100))
          local gold=ship('Gold killer',class('GVF Serapis'),ba.createVector(3000,0,0),mn.Teams.neutral)
          local chosen; red.clearOrders=function() end
          red.giveOrder=function(self,kind,target) chosen=target; self.Orders={kind}; return true end
          r.GetShipList=function() return {red,blue,gold} end
          r:EliminateFaction('RED','GOLD'); r:UpdateSurvivorCombat(20)
          local order=r.AIOrderState[red:getSignature()]
          assert(red.HitpointsLeft>0 and not r:IsShipWithdrawing(red),
            'station loss pulled the defeated AI fleet out of the arena')
          assert(order and order.reason=='RETALIATE_BASE_KILLER' and chosen==gold,
            'stationless survivor did not attack the faction that destroyed its base')
          assert(r:GetFactionKey(red)=='RED' and r:AreEnemies(red,blue),
            "retaliation changed the defeated fleet's faction hostility")
          gold.HitpointsLeft=0; r.NextSurvivorCombat=0; r:UpdateSurvivorCombat(23)
          assert(r.AIOrderState[red:getSignature()].targetSignature==blue:getSignature(),
            'survivor did not switch to another reachable hostile after the killer was destroyed')
          r:SetFactionEliminated('BLUE',true); r.ExtractionAreas={}
          r.GetExtractionArea=function() return {center=ba.createVector(0,0,5000),radius=8000,slots={},home=ba.createVector(0,0,0),homeRadius=500} end
          assert(r:BeginShipWithdrawal(blue),'player can explicitly withdraw after station loss')
          r.Withdrawals[blue:getSignature()].inCorridor=true
          assert(not r:CanAutoEngage(gold,blue),'corridor passage did not suppress automatic acquisition')
          r.AllowWithdrawal.GOLD=false
          assert(r:CanAutoEngage(gold,blue),'explicit interception policy could not restore hostile targeting')
        ''')

    def test_survival_strength_counts_weapons_that_can_join_the_engagement(self):
        self.lua.execute('''
          local own=mkFighter('Own',ba.createVector(0,0,0))
          local threat=ship('Close enemy',class('Enemy'),ba.createVector(800,0,0),mn.Teams.hostile)
          local distant=ship('Distant enemy',class('Enemy'),ba.createVector(4000,0,0),mn.Teams.hostile)
          local ally=mkFighter('Ally',ba.createVector(-1000,0,0))
          local rows={}
          for _,s in ipairs({own,threat,distant,ally}) do
            rows[#rows+1]={ship=s,profile={armed=true,range=1500,speed=100,value=s==distant and 10000 or 100}}
          end
          r.GetAISpatialCandidates=function() return rows end; r.AILocalCache={}
          local friend,enemy=r:AILocalStrength(own,own.Position,4500,false,threat)
          assert(friend==200 and enemy==100,'distant short-range guns count as an overwhelming active fight')
          rows[3].profile.range=6000; r.AILocalCache={}
          friend,enemy=r:AILocalStrength(own,own.Position,4500,false,threat)
          assert(enemy==10100,'distant long-range threat was ignored')
        ''')

    def test_automatic_queries_reuse_context_iff_but_recheck_live_permissions_and_teams(self):
        self.check('''
          local own=mkFighter('IFF owner'); local foe=ship('IFF foe',class('SF Mara'),ba.createVector(500,0,0),mn.Teams.hostile)
          local rows={{ship=own,mounts={},armed=true,profileBeam=false,maxRange=1000,firepower=1},
            {ship=foe,mounts={},armed=true,profileBeam=false,maxRange=1000,firepower=1}}
          r.StrategicThreatSnapshot=rows; r:BuildAIContext(rows)
          local original=r.AreEnemies; local calls=0
          r.AreEnemies=function(self,a,b) calls=calls+1; return original(self,a,b) end
          for i=1,10 do assert(r:CanAutoEngage(own,foe)) end
          assert(calls==0,'candidate scoring repeats native IFF queries within the same context')
          r.IsAutomaticTargetPermitted=function() return false end
          assert(not r:CanAutoEngage(own,foe),'cached hostility bypassed a new extraction permission')
          r.IsAutomaticTargetPermitted=function() return true end
          foe.Team=own.Team
          assert(not r:CanAutoEngage(own,foe) and calls>0,'captured target kept stale hostile IFF')
        ''')

    def test_strength_and_service_threat_reuse_context_geometry_until_rebuild(self):
        self.check('''
          local own=mkFighter('Geometry owner',ba.createVector(0,0,0))
          local foe=ship('Geometry hostile',class('SF Mara'),ba.createVector(500,0,0),mn.Teams.hostile)
          local rows={{ship=own,mounts={},armed=true,profileBeam=false,maxRange=1000,firepower=1},
            {ship=foe,mounts={},armed=true,profileBeam=false,maxRange=1000,firepower=1}}
          r.StrategicThreatSnapshot=rows; r:BuildAIContext(rows)
          local friend,enemy=r:AILocalStrength(own,own.Position,1000,false)
          local position=rows[2].position
          position.getDistance=function() assert(false,'local query crosses native vector boundary') end
          r.AILocalCache={}
          local againFriend,againEnemy=r:AILocalStrength(own,own.Position,1000,false)
          assert(friend==againFriend and enemy==againEnemy and enemy>0)
          assert(r:GetFleetLocalThreat(own)==foe,'service ignored the same context geometry')
          foe.Position=ba.createVector(3000,0,0); r:BuildAIContext(rows)
          assert(r:GetFleetLocalThreat(own)==nil,'rebuilt context retained a moved threat')
          local fallback={ship=foe}
          assert(r:GetAIContextDistance(fallback,0,0,0)==3000,'non-context caller lost live geometry')
        ''')

    def test_excluded_hostiles_never_inflate_friendly_strength_or_support(self):
        self.check('''
          local own=mkFighter('Strength owner',ba.createVector(0,0,0))
          local foe=ship('Protected hostile',class('SF Mara'),ba.createVector(500,0,0),mn.Teams.hostile)
          local rows={{ship=own,profile={value=100}},{ship=foe,profile={value=500}}}
          r.GetAISpatialCandidates=function() return rows end; r.StrategicThreatSnapshot=rows; r.AILocalCache={}
          local permission=r.IsAutomaticTargetPermitted
          r.IsAutomaticTargetPermitted=function(self,unit,target) return target~=foe end
          local friend,enemy,support=r:AILocalStrength(own,own.Position,1000,true)
          assert(friend==100 and enemy==0 and support==math.huge,
            'protected hostile was counted as a friendly supporter')
          r.IsAutomaticTargetPermitted=permission; r.AILocalCache={}
          friend,enemy,support=r:AILocalStrength(own,own.Position,1000,true)
          assert(friend==100 and enemy==500 and support==math.huge,'ordinary hostile control did not count as enemy')
          foe.Position=ba.createVector(r:GetBattleMapHalfExtent()+1000,0,0); r.AILocalCache={}
          friend,enemy,support=r:AILocalStrength(own,own.Position,r:GetBattleMapHalfExtent()+2000,true)
          assert(friend==100 and enemy==0 and support==math.huge,'out-of-arena hostile became friendly support')
        ''')

    def setUp(self):
        self.lua = boot()
        self.lua.execute('''
          r.Enabled=true; r.SetupActive=false; r.CinematicActive=false; r.PostBattleActive=false
          gr.getStringWidth=function(s) return #s*6 end
          gr.getStringHeight=function() return 9 end
          r.CameraFocus=ba.createVector(0,0,0); r.CameraYaw=0
          r.CameraDistance=r.Config.Camera.Distance
          r.UpdateCameraTransform=function() end
        ''')

    def check(self, code):
        self.lua.execute(code)

    def test_drag_line_is_perpendicular_to_heading_and_all_orders_are_parallel(self):
        self.check('''
          local group=mkGroup(5)
          for _,s in ipairs(group) do s.Class.Model.Radius=20 end
          r.testSelection=group; r.IssueMove=REAL_ISSUE_MOVE; r.SetUserOrder=REAL_SET_USER_ORDER
          local target=ba.createVector(1000,0,5000); local facing=ba.createVector(5000,0,5000)
          r.MoveShipTo=function() return true end
          r:IssueMove(target,facing)
          local min,max=math.huge,-math.huge
          for _,s in ipairs(group) do
            local o=r.UserOrders[s.signature]
            assert(math.abs(o.destination.x-target.x)<.01,'line followed travel, not facing')
            assert(math.abs(o.facing.x-o.destination.x-4000)<.01 and math.abs(o.facing.z-o.destination.z)<.01,
              'ships converge on one point instead of parallel headings')
            min=math.min(min,o.destination.z); max=math.max(max,o.destination.z)
          end
          assert(max-min>=400 and max-min<=1000,'fighter formation is too spread out')
        ''')

    def test_mixed_hulls_do_not_impose_giant_spacing_on_fighters(self):
        self.check('''
          local group=mkGroup(8)
          for i,s in ipairs(group) do s.Class.Model.Radius=i==1 and 1600 or 20 end
          local slots=r:BuildSafeFormationDestinations(group,ba.createVector(0,0,0),'LINE_ABREAST',ba.createVector(0,0,1000))
          local small={}; local min,max=math.huge,-math.huge
          for _,slot in ipairs(slots) do
            min=math.min(min,slot.destination.x); max=math.max(max,slot.destination.x)
            if slot.ship.Class.Model.Radius==20 then small[#small+1]=slot.destination.x end
          end
          assert(max-min<4000,'one capital spread the entire fighter screen')
          table.sort(small)
          for i=2,#small do assert(small[i]-small[i-1]<=241 and small[i]-small[i-1]>=100) end
        ''')

    def test_all_shapes_keep_pairwise_clearance_and_centroid(self):
        self.check('''
          r.GetFactionCommandShip=function() return nil end -- pure formation geometry; no station obstacle
          local group=mkGroup(12)
          for i,s in ipairs(group) do s.Class.Model.Radius=({400,200,80,20})[(i-1)%4+1] end
          for _,shape in ipairs(r:GetFormationTypes()) do
            local slots=r:BuildSafeFormationDestinations(group,ba.createVector(0,0,0),shape.id,ba.createVector(1,0,1))
            local x,z=0,0
            for i,a in ipairs(slots) do
              x=x+a.destination.x; z=z+a.destination.z
              for j=1,i-1 do
                local b=slots[j]; local needed=r:GetShipFormationRadius(a.ship)+r:GetShipFormationRadius(b.ship)+60
                assert(a.destination:getDistance(b.destination)>=needed-.01,'overlap in '..shape.id)
              end
            end
            assert(math.abs(x/#slots)<.1 and math.abs(z/#slots)<.1,'off-centre '..shape.id)
          end
        ''')

    def test_near_arena_edge_clamps_the_group_without_collapsing_slots(self):
        self.check('''
          local group=mkGroup(4)
          for _,s in ipairs(group) do s.Class.Model.Radius=400 end
          local half=r:GetCommandArenaHalfExtent()
          local slots=r:BuildSafeFormationDestinations(group,ba.createVector(half,0,half),'LINE_ABREAST',ba.createVector(half,0,half+1000))
          assert(#slots==4)
          for i,a in ipairs(slots) do
            assert(math.abs(a.destination.x)+400<=half+.01 and math.abs(a.destination.z)+400<=half+.01)
            for j=1,i-1 do assert(a.destination:getDistance(slots[j].destination)>=860-.01,'edge clamp collapsed hull clearance') end
          end
        ''')

    def test_arrival_heading_refreshes_native_hold_once_and_recovers_drift(self):
        self.check('''
          local s=mkFighter(); local forward=ba.createVector(1,0,0)
          s.getfvec=function() return forward end
          local o={kind='hold',manual=true,heading=ba.createVector(1000,0,0),facing=ba.createVector(1000,0,0)}
          r.UserOrders[s.signature]=o
          local holds=0; r.HoldShip=function() holds=holds+1 end
          r:UpdateMoveFacings(); r:UpdateMoveFacings()
          assert(holds==1 and o.heading and o.facingSettled,'native hold was not refreshed exactly once')
          forward=ba.createVector(0,0,-1); sexps={}; r:UpdateMoveFacings()
          assert(#sexps==1 and not o.facingSettled,'heading drift cannot recover after facing cleared')
          forward=ba.createVector(1,0,0); r:UpdateMoveFacings(); assert(holds==2)
        ''')

    def test_enemies_keep_basic_inspection_without_private_information(self):
        self.check('''
          for _,kind in ipairs({'RED','GOLD'}) do
            local enemy=ship('Enemy fighter',class('Enemy class'),ba.createVector(100,0,200),stations[kind].Team)
            enemy.role='fighter'; enemy.Physics.Velocity=ba.createVector(10,0,0)
            enemy.Physics.getForwardSpeed=function() return 10 end
            enemy.Target=stations.BLUE
            r.AIOrderState[enemy.signature]={label='PRIVATE ORDER',reason='PRIVATE REASON',targetSignature=stations.BLUE.signature}
            r.AIObservations={[enemy.signature]={stalled=true}}
            assert(r:GetHoverOrderTarget(enemy)==nil and r:GetHoverCourseProjection(enemy,0,0)==nil)
            assert(not r:GetShipControlDescription(enemy):find('PRIVATE'))
            r.GetSelectedShips=function() return {enemy} end
            local texts=captureStrings(function()
              r:DrawSelectedUnitStats(1920,1080)
              r:DrawHoverReadout(enemy,500,500,stations.BLUE,12)
            end)
            assert(anyContains(texts,'Enemy class') and anyContains(texts,'Hull'))
            for _,secret in ipairs({'PRIVATE','STALLED','LOADOUT','TARGET:','COURSE','ACTION:'}) do
              assert(not anyContains(texts,secret),'leaked '..secret..' for '..kind)
            end
          end
        ''')

    def test_pause_allows_focus_and_chase_but_keeps_commands_blocked(self):
        self.check('''
          local group=mkGroup(1); r.GetSelectedShips=function() return group end
          r.Paused=true; r.LastNonZeroTimeScale=4
          r.Selected={group[1].signature}; r.PrimarySelectionSignature=group[1].signature
          r:OnKeyPressed('F','F'); assert(r.CameraFocus.x==group[1].Position.x)
          group[1].Position.x=900; r:OnKeyPressed('Ctrl-Space','Space'); assert(r.CameraFocus.x==900)
          r:OnKeyPressed('H','H'); assert(r.CameraFocus.x==stations.BLUE.Position.x)
          r:OnKeyPressed('B','B'); assert(r.FollowSignature==group[1].signature)
          r:OnKeyPressed('F','F'); assert(r.FollowSignature==nil)
          r.BattleCamActive=true; r.BattleCamSignature=group[1].signature
          r:OnKeyPressed('F','F'); assert(not r.BattleCamActive and r.Paused)
          r.HoldSelected=function() assert(false,'paused command ran') end
          r:OnKeyPressed('R','R'); assert(r.Paused)
        ''')

    def test_hover_world_pass_does_not_treat_a_private_order_as_a_boolean_handle(self):
        self.check('''
          local enemy=ship('Enemy hover',class('Enemy hover'),ba.createVector(100,0,200),stations.RED.Team)
          r.UserOrders[enemy.signature]={kind='move',destination=ba.createVector(800,0,500)}
          r.EachShip=function() end -- isolate the actual hover pass from ambient projection
          r.BuildViewportGate=function() return nil end
          r.ProjectionCacheNeedsPrune=function() return false end
          r.GetShipAtScreen=function() return enemy end
          r.ProjectShip=function() return 100,200 end
          r.GetShipWeaponRange=function() assert(false,'private range queried') end
          r:DrawWorldOverlays()
          assert(r.HoverReadout.ship==enemy and r.HoverReadout.order==nil)
          assert(r.HoverReadout.target==nil and r.HoverReadout.courseSeconds==nil)
        ''')

    def test_auto_stats_show_a_reason_once_and_manual_orders_do_not_show_stale_ai(self):
        self.check('''
          local s=mkFighter(); s.Physics.getForwardSpeed=function() return 10 end
          r.GetSelectedShips=function() return {s} end
          r.GetShipLoadout=function() return {},0,0 end
          r.AutoPlayerMode=true
          r.AIOrderState[s.signature]={label='DUPLICATE REASON',mission='PRIMARY',reason='PUSH_ENEMY_BASE'}
          local text=captureStrings(function() r:DrawSelectedUnitStats(1920,1080) end)
          assert(anyContains(text,'FLEET AI') and anyContains(text,'PUSH ENEMY BASE'))
          assert(not anyContains(text,'DUPLICATE REASON'))
          r.UserOrders[s.signature]={kind='hold'}
          text=captureStrings(function() r:DrawSelectedUnitStats(1920,1080) end)
          assert(not anyContains(text,'PUSH ENEMY BASE'),'manual control displays an obsolete AI rationale')
          r.UserOrders[s.signature]=nil
          r.FleetServices[s.signature]={phase='RETURNING',reason='OUTMATCHED'}
          r.GetFleetServiceLabel=function() return 'OUTMATCHED: RETURNING' end
          text=captureStrings(function() r:DrawSelectedUnitStats(1920,1080) end)
          assert(anyContains(text,'OUTMATCHED: RETURNING') and not anyContains(text,'PUSH ENEMY BASE'),
            'service displays a second stale AI rationale')
        ''')

    def test_map_and_reticle_share_the_same_juggernaut_shape(self):
        self.check('''
          local s=mkFighter(); s.role='juggernaut'; s.Position=ba.createVector(0,0,0)
          r.EachShip=function(self,fn) fn(s) end
          r.DrawStationMapOverlay=function() end; r.DrawMapWindowChrome=function() end
          r.DrawOrderPing=function() end
          local roles={}; r.DrawShipRoleShape=function(self,role) roles[#roles+1]=role end
          r:DrawTacticalMap(1920); r:DrawRoleMarker(s,0,0,100,100)
          assert(#roles==2 and roles[1]=='juggernaut' and roles[2]=='juggernaut')
        ''')

    def test_reticle_role_icon_scales_with_hud_and_stays_inside_upper_left(self):
        self.check('''
          local s=mkFighter()
          for _,scale in ipairs({1,1.75}) do
            r.GetUIMetrics=function() return {sw=3840,sh=2160,topBarHeight=44,pad=function(n) return math.floor(n*scale+.5) end} end
            local expected=math.floor(r.Config.Selection.RoleMarkerSize*scale+.5)
            local calls=0
            r.DrawShipTypeIcon=function(self,ship,x,y,size)
              assert(ship==s and size==expected,'role icon ignores HUD scaling')
              assert(x>500 and y>500 and x+size<500+22*scale and y+size<500+22*scale,'role icon is not inside upper-left of the bracket')
              calls=calls+1
            end
            for _,bracket in ipairs({22,36,120,500}) do r:DrawRoleMarker(s,500,500,500+bracket*scale,500+bracket*scale) end
            assert(calls==4,'role icon disappears at some bracket sizes')
          end
        ''')

    def test_zoomed_out_density_culling_keeps_every_contact_role_icon(self):
        self.check('''
          local group=mkGroup(3); r.Selected={}; r.HoveredSelectionSigs={}
          r.CameraDistance=r.Config.Camera.MaxDistance
          r.EachShip=function(self,fn) for _,s in ipairs(group) do fn(s) end end
          r.BuildViewportGate=function() return nil end
          r.ProjectShipAmbient=function() return 500,500 end
          r.ProjectionCacheNeedsPrune=function() return false end
          r.GetReticlePixelSize=function() return 22 end
          r.DrawReticle=function() return 11 end
          r.ShouldDecorateReticle=function() return false end
          r.DrawHullBarForShip=function() assert(false,'fixture must cull hull bars') end
          local icons=0; r.DrawRoleMarker=function() icons=icons+1 end
          r:DrawWorldOverlays()
          assert(icons==#group,'zoomed-out overlap culling hides ship type icons')
        ''')

    def test_map_and_reticle_use_basic_shapes_without_a_box_or_sprite(self):
        self.check('''
          local s=mkFighter(); s.role='juggernaut'
          local view={shapes=false}; r.GetMapView=function() return view end
          local tex={}; r.GetBriefingIcon=function() return tex end
          local images,shapes,frames=0,0,0
          gr.drawImage=function(t) assert(t==tex); images=images+1 end
          r.DrawShipRoleShape=function(self,role) assert(role=='juggernaut'); shapes=shapes+1 end
          gr.drawRectangle=function(x1,y1,x2,y2,filled) if not filled then frames=frames+1 end end
          r:DrawShipTypeIcon(s,0,0,12); r:DrawRoleMarker(s,500,500,522,522)
          assert(images==0 and shapes==2 and frames==0,'map/reticle use sprites or reticle adds a misleading box')
          view.shapes=true
          r:DrawShipTypeIcon(s,0,0,12); r:DrawRoleMarker(s,500,500,522,522)
          assert(images==0 and shapes==4,'shape preference diverges')
          view.shapes=false; r.GetBriefingIcon=function() return nil end
          r:DrawShipTypeIcon(s,0,0,12); r:DrawRoleMarker(s,500,500,522,522)
          assert(shapes==6,'missing asset changes the geometric shape')
        ''')

    def test_juggernaut_prongs_remain_distinct_after_native_integer_truncation(self):
        self.check('''
          for _,size in ipairs({8,11,12}) do
            local rects={}
            gr.drawRectangle=function(x1,y1,x2,y2)
              rects[#rects+1]={x1=math.floor(x1),y1=math.floor(y1),x2=math.floor(x2),y2=math.floor(y2)}
            end
            r:DrawShipRoleShape('juggernaut',0,0,size)
            assert(#rects==4)
            for i=3,4 do assert(rects[i].x1-rects[i-1].x2>=1,'crown collapsed to a capital block at '..size..' pixels') end
          end
        ''')

    def test_selection_rows_start_below_legend_and_badges_are_centered(self):
        self.check('''
          r.ShowHotkeyHints=true
          local s=mkFighter(); r.GetSelectedShips=function() return {s} end
          for _,res in ipairs({{1280,720},{1920,1080},{3840,2160}}) do
            r:RefreshSelectionListRects(res[1],res[2]); local rect=r:GetSelectionPanelRect(res[1],res[2])
            local m=r:GetUIMetrics(res[1],res[2])
            assert(r.SelectionRows[1].rect.y1>=rect.y1+m.pad(8)+3*m.lineHeight+m.pad(4))
          end
          local text,x,y
          gr.drawString=function(t,px,py) text=t; x=px; y=py end
          r:DrawRoleBadge('fighter',100,200,18)
          -- y is one pixel below the font-cell centre: the caps sit high in the cell.
          assert(text=='F' and x==106 and y==205,'badge did not use measured glyph bounds')
        ''')

    def test_build_rosters_and_sathanas_price_share_the_purchase_contract(self):
        self.check('''
          for _,list in ipairs({r.Config.ProductionClasses,r.Config.AI.BlueRoster}) do
            for _,entry in ipairs(list) do assert(entry.class~='GTSC Faustus','disabled transport can still be built') end
          end
          class('SJ Sathanas'); r.ShipCostMap['SJ Sathanas']={cost=1950,time=48.75,radius=3276}
          local a=r:GetPurchaseEstimate('SJ Sathanas',5,1)
          local b=r:GetPurchaseEstimate('SJ Sathanas',5,2)
          assert(a.cost==60000 and a.time==1500 and b.cost==120000)
          for _,kind in ipairs({'BLUE','GOLD','RED'}) do
            local options=r:GetSentryOptions(kind)
            assert(options[1].cost==250 and options[2].cost==375 and options[3].cost==500 and options[4].cost==1250)
          end
        ''')

    def test_hover_ranges_include_beams_separate_banks_and_ignore_unavailable_guns(self):
        self.check('''
          local s=mkFighter()
          local function bank(range,speed,life,beam,ammo)
            return {isValid=function() return true end,AmmoMax=ammo~=nil and 10 or 0,AmmoLeft=ammo,
              WeaponClass={isValid=function() return true end,isBeam=function() return beam==true end,Range=range,Speed=speed,LifeMax=life}}
          end
          local locked={}
          s.getFlag=function(self,name) return locked[name] or false end
          s.PrimaryBanks={bank(5000,1000,2)}; s.SecondaryBanks={bank(9000,1000,10,false,5)}
          local turret=s[1]; turret.TurretLocked=false; turret.BeamFree=true; turret.HitpointsMax=100; turret.HitpointsLeft=100
          turret.isTurret=function() return true end
          turret.PrimaryBanks={bank(8000,10000,1,true),bank(11000,80,137.5)}; turret.SecondaryBanks={bank(20000,2000,10,false,0)}
          local a=r:GetShipWeaponRanges(s)
          assert(a.primary==11000 and a.secondary==9000 and a.beam==8000,'bank/beam reach calculation wrong')
          turret.TurretLocked=true; locked['primaries-locked']=true
          a=r:GetShipWeaponRanges(s)
          assert(a.primary==0 and a.secondary==9000 and a.beam==0,'primary lock hides secondary or locked turrets are counted')
          locked['primaries-locked']=false; locked['secondaries-locked']=true; turret.TurretLocked=false; turret.BeamFree=false
          a=r:GetShipWeaponRanges(s)
          assert(a.secondary==0 and a.primary==11000 and a.beam==0,'beam lock or secondary lock ignored')
          turret.HitpointsLeft=0
          assert(r:GetShipWeaponRange(s)==2000,'destroyed turret still has a range')
        ''')

    def test_pilot_ranges_distinguish_same_label_turrets_by_canonical_name(self):
        self.check('''
          local hull=mkHull('GTD Orion',ba.createVector(0,0,0),'capital')
          hull.PrimaryBanks={}; hull.SecondaryBanks={}; hull.getFlag=function() return false end
          local function gun(id,reach)
            return {Name='Laser turret',CanonicalName=id,TurretLocked=true,HitpointsMax=100,HitpointsLeft=100,
              isValid=function() return true end,isTurret=function() return true end,SecondaryBanks={},
              PrimaryBanks={{isValid=function() return true end,WeaponClass={Range=reach,Speed=1000,LifeMax=10,isBeam=function() return false end,isValid=function() return true end}}}}
          end
          hull[1]=gun('turret01',9000); hull[2]=gun('turret02',1500)
          r.PossessedSignature=hull:getSignature(); r.PilotTurretGroupIndex=2
          r.PilotTurretGroups={{turrets={{subsystem=hull[1],wasLocked=false}}},{turrets={{subsystem=hull[2],wasLocked=false}}}}
          assert(r:GetShipWeaponRanges(hull).primary==1500,'shared HUD labels expose inactive battery range')
        ''')

    def test_world_range_ring_keeps_true_range_and_projects_each_world_point(self):
        self.check('''
          local centre=ba.createVector(0,0,0)
          local function orientation()
            return {getFvec=function() return ba.createVector(0,0,1) end,
              getRvec=function() return ba.createVector(1,0,0) end,
              getUvec=function() return ba.createVector(0,1,0) end}
          end
          r.Camera={Position=ba.createVector(0,0,-5000),Orientation=orientation(),FOV=.9}
          r.FollowSignature=nil; r.FollowCamera=nil
          local projections=0; local mt=getmetatable(centre)
          mt.getScreenCoords=function(v)
            projections=projections+1
            return v.x/(1+v.z/20000),v.z
          end
          local maximum=0; local lines=0
          gr.drawLine=function(x1,y1,x2,y2) maximum=math.max(maximum,math.abs(x1),math.abs(x2)); lines=lines+1 end
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0)
          assert(maximum>10000,'11km range was compressed to a small HUD circle')
          assert(projections==r.Config.Selection.WeaponRangeSegments+1 and lines==r.Config.Selection.WeaponRangeSegments,
            'ring is an affine ellipse rather than a projected world circle')
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0)
          assert(projections==r.Config.Selection.WeaponRangeSegments+1
            and lines==r.Config.Selection.WeaponRangeSegments*2,
            'unchanged ring repeated all native projections instead of reusing geometry')
          r.Camera.Position.x=10
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0)
          assert(projections==(r.Config.Selection.WeaponRangeSegments+1)*2,
            'camera motion failed to invalidate projected ring geometry')
          local seen=projections
          r.FollowSignature=123
          r.FollowCamera={Position=ba.createVector(20,0,-5000),Orientation=orientation(),FOV=.9}
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0)
          assert(projections==seen+r.Config.Selection.WeaponRangeSegments+1,
            'follow view reused RTS camera geometry')
          seen=projections; r.FollowCamera.Position.x=30
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0)
          assert(projections==seen+r.Config.Selection.WeaponRangeSegments+1,
            'follow camera motion failed to invalidate projected ring geometry')
          seen=projections; r.FollowCamera.FOV=.7
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0)
          assert(projections==seen+r.Config.Selection.WeaponRangeSegments+1,
            'follow camera FOV failed to invalidate projected ring geometry')
          seen=projections; local width=gr.getScreenWidth; gr.getScreenWidth=function() return 1280 end
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0); gr.getScreenWidth=width
          assert(projections==seen+r.Config.Selection.WeaponRangeSegments+1,
            'viewport change failed to invalidate projected ring geometry')
          centre.x=100
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0)
          assert(projections==(r.Config.Selection.WeaponRangeSegments+1)*7,
            'center motion failed to invalidate projected ring geometry')
          r:DrawWorldRangeRing(centre,9000,{1,2,3},90,0,0)
          assert(projections==(r.Config.Selection.WeaponRangeSegments+1)*8,
            'weapon-range change failed to invalidate projected ring geometry')
        ''')

    def test_world_range_ring_cache_preserves_false_projection_breaks(self):
        self.check('''
          local centre=ba.createVector(0,0,0); local projections,lines=0,0
          local function orientation()
            return {getFvec=function() return ba.createVector(0,0,1) end,
              getRvec=function() return ba.createVector(1,0,0) end,
              getUvec=function() return ba.createVector(0,1,0) end}
          end
          r.Camera={Position=ba.createVector(0,0,-5000),Orientation=orientation(),FOV=.9}
          r.FollowSignature=nil; r.FollowCamera=nil
          getmetatable(centre).getScreenCoords=function(v)
            projections=projections+1
            if v.z>5000 then return false,false end
            return v.x,v.z
          end
          gr.drawLine=function() lines=lines+1 end
          local segments=r.Config.Selection.WeaponRangeSegments
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0)
          local firstLines=lines
          assert(firstLines>0 and firstLines<segments,
            'off-screen ring vertices were connected into false line segments')
          r:DrawWorldRangeRing(centre,11000,{1,2,3},90,0,0)
          assert(projections==segments+1 and lines==2*firstLines,
            'cached false/off-screen vertices changed ring breaks or reprojected')
        ''')

    def test_world_range_ring_projection_cache_is_bounded(self):
        self.check('''
          local projections=0; local function orientation()
            return {getFvec=function() return ba.createVector(0,0,1) end,
              getRvec=function() return ba.createVector(1,0,0) end,
              getUvec=function() return ba.createVector(0,1,0) end}
          end
          r.Camera={Position=ba.createVector(0,0,-5000),Orientation=orientation(),FOV=.9}
          r.FollowSignature=nil; r.FollowCamera=nil
          getmetatable(ba.createVector(0,0,0)).getScreenCoords=function(v)
            projections=projections+1; return v.x,v.z
          end
          local centres={}
          for i=1,17 do
            centres[i]=ba.createVector(i*100,0,0)
            r:DrawWorldRangeRing(centres[i],500,{1,2,3},90,0,0)
          end
          local segments=r.Config.Selection.WeaponRangeSegments
          assert(projections==17*(segments+1))
          r:DrawWorldRangeRing(centres[13],500,{1,2,3},90,0,0)
          assert(projections==17*(segments+1),'most-recent ring did not remain cached')
          r:DrawWorldRangeRing(centres[1],500,{1,2,3},90,0,0)
          assert(projections==18*(segments+1),'cache retained unbounded stale geometry instead of evicting its LRU')
        ''')

    def test_attack_approach_uses_selected_formation_and_releases_combat_steering(self):
        self.check('''
          local group=mkGroup(4); r.testSelection=group; r.SetUserOrder=REAL_SET_USER_ORDER
          for i,s in ipairs(group) do s.Position=ba.createVector((i-2.5)*100,0,-2000) end
          local enemy=ship('Enemy fixture',class('SC Cain'),ba.createVector(0,0,20000),mn.Teams.hostile)
          enemy.Radius=100
          r.GetShipWeaponRanges=function() return {primary=2000,secondary=9000,beam=0} end
          local moves=0; r.MoveShipTo=function(self,s,p) moves=moves+1; return true end
          r:SetSelectedFormation('LINE_ABREAST'); r:IssueAttack(enemy)
          local formation=r.UserOrders[group[1].signature].formation
          assert(moves==4 and formation.id=='LINE_ABREAST','attack ignores selected formation')
          local z=nil
          for _,s in ipairs(group) do
            local o=r.UserOrders[s.signature]
            assert(o.kind=='attack' and o.approaching and o.targetSignature==enemy.signature)
            if z then assert(math.abs(o.destination.z-z)<.01,'approach slots are not a line across heading') end
            z=o.destination.z
            s.Position=ba.createVector(0,0,18500)
          end
          r:UpdateAttackFormations(2)
          for _,s in ipairs(group) do assert(not r.UserOrders[s.signature].approaching,'formation fights native steering inside gun range') end
          r:SetUserOrder(group[1],{kind='hold'})
          r:UpdateAttackFormations(3)
          assert(r.UserOrders[group[1].signature].kind=='hold','old attack cohort overrides a new order')
        ''')

    def test_intro_has_no_shot_loading_track(self):
        self.check('''
          local thin=0
          gr.drawRectangle=function(x1,y1,x2,y2,filled) if filled and y2-y1<=10 then thin=thin+1 end end
          r.CinematicShotIndex=2; r.CinematicShotProgress=.5
          r:DrawCinematicOverlay(1920,1080)
          assert(thin==0,'per-shot loading bar remains')
        ''')

    def test_intro_control_hints_respect_the_shared_visibility_toggle(self):
        self.check('''
          local text={}; gr.drawString=function(s) text[#text+1]=tostring(s) end
          r.ShowHotkeyHints=false; r:DrawCinematicOverlay(1280,720)
          assert(not table.concat(text,' '):find('PRESS ANY KEY',1,true))
          r.ShowHotkeyHints=true; r:DrawCinematicOverlay(1280,720)
          assert(table.concat(text,' '):find('PRESS ANY KEY',1,true))
        ''')

    def test_player_defeat_resumes_unresolved_battle_then_records_global_draw(self):
        self.check('''
          r.BlueEliminated=true; r:GetFactionKeys()
          r.GetLivingFactionKeys=function() return {'RED','GOLD'} end
          r:EvaluateFactionVictory()
          assert(r.PostBattleActive and r.GameStatus=='DEFEAT' and r.PlayerDefeatShown
            and not r.StrategicResult and not r.AftermathActive,'player loss prematurely finalized the battle')
          assert(r.TimeScale==0,'opening player defeat did not pause the simulation')
          assert(r:ResumePostBattle() and not r.AftermathActive and not r.PostBattleActive
            and not r.Paused and r.TimeScale==1,'resuming player defeat entered aftermath')
          assert(r.GameStatus=='ACTIVE' and not r:ResumePostBattle(),'duplicate resume changed phase')
          r:EvaluateFactionVictory()
          assert(not r.PostBattleActive and not r.AftermathActive,'player-defeat report reopened every frame')
          r.GetLivingFactionKeys=function() return {} end
          r:EvaluateFactionVictory()
          local result=r.StrategicResult
          assert(result and result.victor=='NONE' and r.PostBattleActive and r.GameStatus=='DRAW'
            and r.AftermathActive,'mutual station loss did not record a global draw')
          assert(r:ResumePostBattle() and r.AftermathActive); r:EvaluateFactionVictory()
          assert(r.PostBattleActive and r.FleetFateFinal and r.StrategicResult==result
            and r.GameStatus=='DRAW','final draw report changed or reopened the strategic result')
        ''')

    def test_station_loss_preserves_hostility_and_player_orders_while_enemy_retaliates(self):
        self.check('''
          local blue=mkFighter('Blue survivor',ba.createVector(0,0,0))
          local red=ship('Red survivor',class('SF Mara'),ba.createVector(1000,0,0),mn.Teams.hostile)
          local gold=ship('Gold survivor',class('GVF Serapis'),ba.createVector(2000,0,0),mn.Teams.neutral)
          local commands={}
          for _,s in ipairs({blue,red,gold}) do
            s.__role='fighter'
            s.Orders={}; s.clearOrders=function(self) self.Orders={} end
            s.giveOrder=function(self,kind,target) assert(kind~=ORDER_DEPART,'station loss withdraws its fleet'); commands[self.signature]=target; self.Orders={kind}; return true end
          end
          r.EachShip=function(self,fn) for _,s in ipairs({blue,red,gold}) do fn(s) end end
          r.GetShipList=function() return {blue,red,gold} end
          r.UserOrders[blue:getSignature()]={kind='hold'}
          r:EliminateFaction('RED','GOLD')
          assert(red.HitpointsLeft>0 and r:AreEnemies(red,blue),'elimination destroys or neutralizes survivors')
          r:UpdateSurvivorCombat(100)
          assert(not r:IsShipWithdrawing(red) and commands[red.signature]==gold,
            'stationless survivors did not attack the faction that destroyed their station')
          r:UpdateSurvivorCombat(102)
          assert(r.UserOrders[blue:getSignature()].kind=='hold' and commands[blue.signature]==nil,
            "survivor extraction overrode the player's manual order")
        ''')

    def test_survivor_panel_removes_purchase_buttons_and_reset_clears_the_phase(self):
        self.check('''
          r.AftermathActive=true; r.BuildButtonRects={[1]={}}; r.StationButtonRects={buy={}}
          r:DrawBuildPanel(1280,720)
          assert(next(r.BuildButtonRects)==nil and next(r.StationButtonRects)==nil and r.AftermathReportRect)
          r:ResetState()
          assert(not r.AftermathActive and r.AftermathStationCount==nil and next(r.SurvivorTargets)==nil)
        ''')

    def test_manual_capital_attack_uses_and_refreshes_pursuit_until_retasked(self):
        self.check('''
          local capital=mkHull('GTCv manual',ba.createVector(0,0,-12000),'capital')
          local enemy=mkStation(ba.createVector(0,0,12000))
          r.testSelection={capital}; r.SetUserOrder=REAL_SET_USER_ORDER
          r.IsAutomaticAIUnit=function() return false end
          local installed=0
          capital.giveOrder=function(self,kind,target,subsystem,priority) installed=installed+1; assert(kind==ORDER_WAYPOINTS_ONCE and priority==.95); return true end
          r:IssueAttack(enemy)
          assert(installed==1 and r.AIPursuit[capital.signature],'manual capital attack never approaches the station')
          enemy.Position=ba.createVector(2000,0,12000)
          r:RefreshAIPursuit(100)
          assert(installed==2,'manual pursuit was dropped because Auto Mode is off')
          r:SetUserOrder(capital,{kind='hold'})
          r:RefreshAIPursuit(200)
          assert(installed==2 and not r.AIPursuit[capital.signature],'pursuit overrides a new player order')
        ''')

    def test_native_weapons_gauge_override_is_transition_only_and_restored(self):
        self.check('''
          local lookups,writes=0,{}
          hu={getHUDGaugeHandle=function(name)
            assert(name=='Weapons'); lookups=lookups+1
            return {setRenderOverride=function(self,active) writes[#writes+1]=active end}
          end}
          r.PilotWeaponsHUDOverridden=false
          r:SetPilotWeaponsHUD(true); r:SetPilotWeaponsHUD(true)
          r:RestorePilotTurretGroups(); r:RestorePilotTurretGroups()
          assert(lookups==2 and #writes==2 and writes[1] and not writes[2],
            'native weapons gauge was retained, repeatedly rewritten or left hidden after release')
        ''')

    def test_outcome_text_is_drawn_directly_in_the_existing_large_font(self):
        self.check('''
          local normal={height=9,isValid=function() return true end}
          local large={height=18,isValid=function() return true end}
          gr.CurrentFont=normal; gr.Fonts={normal,large}
          gr.getStringHeight=function() return gr.CurrentFont.height end
          gr.getStringWidth=function(text) return #text*(gr.CurrentFont==large and 12 or 6) end
          gr.createTexture=function() assert(false,'title must not scale a bitmap texture') end
          local count=0
          gr.drawString=function(text,x,y)
            assert(gr.CurrentFont==large and x==158 and y==216,'native title bounds or font are wrong')
            count=count+1
          end
          r:DrawOutcomeTitle('VICTORY',0,200,400,250)
          assert(count==1 and gr.CurrentFont==normal,'title changed the rest of the HUD font')
        ''')

    def test_hotkey_hints_toggle_in_pilot_and_paused_rts_without_repeat_or_native_leak(self):
        self.check('''
          assert(r.ShowHotkeyHints==false,'hints must default off')
          r.ShowHotkeyHints=true; r.Paused=true; r.PossessedSignature=123
          r:OnKeyPressed('F10','F10'); r:OnKeyPressed('F10','F10')
          assert(r.ShowHotkeyHints==false and r:ShouldOverrideKey('F10','F10'))
          r:OnKeyReleased('F10','F10'); r:OnKeyPressed('F10','F10')
          assert(r.ShowHotkeyHints==true,'pilot early return retains the hint-key latch')
          r:OnKeyReleased('F10','F10'); r.PossessedSignature=nil
          r:OnKeyPressed('F10','F10')
          assert(r.ShowHotkeyHints==false,'paused RTS cannot toggle hints')
          r:ResetState(); assert(r.ShowHotkeyHints==false and not r.HotkeyHintsHeld,'restart lost hint preference')
        ''')

    def test_hiding_hints_keeps_pilot_status_objectives_and_rts_buttons(self):
        self.check('''
          local s=mkFighter(); r.GetPossessedShip=function() return s end
          r.PilotTurretGroups={{label='Test battery',turrets={}}}; r.PilotPreviousUserOrder={kind='hold'}
          r.ShowHotkeyHints=false; local text={}
          gr.drawString=function(t) text[#text+1]=tostring(t) end
          mn.Events={}; for _,name in ipairs({'RTS Pilot Task','RTS Pilot Target','RTS Pilot Phase','RTS Pilot Reason'}) do
            mn.Events[name]={DirectiveText='',isValid=function() return true end}
          end
          r:DrawPilotHUD(1280,720); r:UpdatePilotDirectives(); r:DrawControls(1280,720)
          local all=table.concat(text,' ')
          assert(all:find('BATTERY',1,true) and all:find('BANKS',1,true) and mn.Events['RTS Pilot Task'].DirectiveText=='YOUR ORDER: hold')
          assert(not all:find('RETURN TO RTS',1,true) and all:find('F10 SHOW CONTROL HINTS',1,true) and not all:find('hull/subsystem',1,true))
          assert(r.ControlsRect==nil)
          r.testSelection={s}; r:RefreshSelectionListRects(1280,720); text={}
          r:DrawSelectionPanel(1280,720); all=table.concat(text,' ')
          assert(all:find('PILOT',1,true) and not all:find('PILOT (P)',1,true) and not all:find('Right-click',1,true))
          assert(r.ActionButtonRects.pilot,'hiding hints removed functional controls')
        ''')

    def test_pilot_objectives_distinguish_live_wing_ai_takeover_and_manual_orders(self):
        self.check('''
          local member=mkFighter(); local target=mkStation(); target.Name='Red target'
          r.AutoPlayerMode=true; r.PilotAIObjective={group='BLUE WING',mission='PRIMARY',targetSignature=target.signature,reason='SAVE_FLEET'}
          r.AIOrderState[member.signature]={group='BLUE WING',mission='RETREAT',targetSignature=target.signature,reason='HULL_LOW',installedAt=20}
          local text=table.concat(r:GetPilotObjectiveLines(),' ')
          assert(text:find('AI WING ORDER',1,true) and text:find('RETREAT',1,true) and text:find('HULL LOW',1,true))
          r.AIOrderState={}; target.HitpointsLeft=0
          text=table.concat(r:GetPilotObjectiveLines(),' ')
          assert(text:find('LAST AI ORDER',1,true) and text:find('Target destroyed',1,true))
          r.PilotPreviousUserOrder={kind='hold'}
          text=table.concat(r:GetPilotObjectiveLines(),' ')
          assert(text:find('YOUR ORDER',1,true) and not text:find('AI WING',1,true))
          assert(not text:find('Protect Blue',1,true) and not text:find('destroy opposing stations',1,true),'generic mission goals leak into tactical directives')
          local rectangles={}; gr.drawRectangle=function(x1,y1,x2,y2) rectangles[#rectangles+1]={x1=x1,x2=x2,y2=y2} end
          r.GetPossessedShip=function() return member end
          r:DrawPilotHUD(640,480)
          assert(#rectangles==2 and rectangles[1].x1==rectangles[2].x1 and rectangles[2].y2<=480,
            'pilot status/controls are not two bounded panels in the same column')
        ''')

    def test_pilot_navigation_shows_target_rally_distance_and_steering_without_changing_aim(self):
        self.check('''
          local pilot=mkFighter(); local enemy=mkStation(); enemy.Name='Red objective'
          pilot.Position=ba.createVector(0,0,0)
          pilot.Orientation={getFvec=function() return ba.createVector(0,0,1) end,
            getRvec=function() return ba.createVector(1,0,0) end,getUvec=function() return ba.createVector(0,1,0) end}
          r.GetPossessedShip=function() return pilot end
          r.PilotAIObjective={mission='ASSAULT',targetSignature=enemy.signature,destination=ba.createVector(1000,1000,0)}
          local text=table.concat(r:GetPilotObjectiveLines(),' ')
          assert(text:find('Red objective',1,true) and text:find('MOVE TO 1000, 1000, 0',1,true))
          assert(text:find('RALLY 1.4 km',1,true) and text:find('RIGHT 90 deg',1,true) and text:find('UP 45 deg',1,true))
          assert(pilot.Target==nil,'guidance hijacked manual targeting')
          r.PilotAIObjective.destination=ba.createVector(-1000,-1000,0)
          text=table.concat(r:GetPilotObjectiveLines(),' ')
          assert(text:find('LEFT 90 deg',1,true) and text:find('DOWN 45 deg',1,true))
          local lines=0; gr.drawLine=function() lines=lines+1 end
          r.PilotAIObjective.destination=ba.createVector(300,0,300)
          r:DrawPilotObjectiveMarker(1280,720); assert(lines==4,'navigation point has no world marker')
        ''')

    def test_comm_broadcast_cannot_depart_station_proxy_pilot_or_other_wings(self):
        self.check('''
          local pilot,mate,stranger=mkFighter(),mkFighter(),mkFighter()
          local base=stations.BLUE; local proxy=mkFighter(r.Config.ObserverShip)
          r.PossessedSignature=pilot.signature; r.GetPossessedShip=function() return pilot end
          r:RegisterLogicalWing({pilot,mate},'Player wing')
          local function recipient(ships) return {forAllShips=function(self,f) for _,s in ipairs(ships) do f(s) end end} end
          for _,s in ipairs({pilot,stranger,base,proxy}) do
            assert(r:ShouldOverridePilotCommOrder(recipient({s})),'unsafe native recipient accepted: '..s.Name)
          end
          assert(r:ShouldOverridePilotCommOrder(recipient({pilot,mate,proxy})), 'mixed wing can depart proxy')
          assert(not r:ShouldOverridePilotCommOrder(recipient({mate})), 'own wingmate cannot be commanded')
          r.UserOrders[mate.signature]={kind='hold'}
          r.AIOrderState[mate.signature]={mission='ASSAULT'}
          r:OnPilotCommOrder(recipient({mate}))
          assert(r.UserOrders[mate.signature].kind=='wing' and r.AIOrderState[mate.signature]==nil,'AI can overwrite native command')
          r.ReissueUserOrder=function(self,s,o) assert(s==mate and o.kind=='hold') end
          r:RestorePilotCommOrders(); assert(r.UserOrders[mate.signature].kind=='hold')
          r.Paused=true; assert(r:ShouldOverridePilotCommOrder(recipient({mate})))
          r.Paused=false; r.PossessedSignature=nil; assert(r:ShouldOverridePilotCommOrder(recipient({mate})))
          r.Enabled=false; assert(not r:ShouldOverridePilotCommOrder(recipient({mate})))
        ''')

    def test_hints_hotkey_is_discoverable_with_legend_hidden(self):
        self.check('''
          r.ShowHotkeyHints=false; local text={}
          gr.drawString=function(t) text[#text+1]=tostring(t) end
          r.SetupActive=true; r.CinematicActive=false; r.ScenarioStartTime=nil
          r:DrawHintsNotice(1280,720); assert(#text==0,'setup showed match hints')
          r.SetupActive=false; r.CinematicActive=true
          r:DrawHintsNotice(1280,720); assert(#text==0,'intro showed match hints')
          r.CinematicActive=false; r.ScenarioStartTime=0
          r:DrawHintsNotice(1280,720)
          assert(table.concat(text,' '):find('F10 SHOW/HIDE CONTROL HINTS',1,true))
        ''')

    def test_directives_fit_two_native_lines_with_the_retail_font(self):
        self.check('''
          local native={isValid=function() return true end}; local previous={}
          gr.CurrentFont=previous; gr.Fonts={native}
          gr.getStringWidth=function(s) assert(gr.CurrentFont==native); return #s*7 end
          local text=r:FitPilotDirective('TARGET: RTS Blue Station | MOVE TO -3002, 0, -3380')
          local count=0; for line in text:gmatch('[^\\n]+') do count=count+1; assert(#line*7<=150,'directive overdraws frame') end
          assert(count==2 and gr.CurrentFont==previous,'native font or two-line contract was lost')
          assert(r:FitPilotDirective('')=='')
        ''')

    def test_c_menu_routes_to_native_wing_commands_once(self):
        self.check('''
          r.PossessedSignature=12; local picks=0
          mn.CommItems={{Name='Wings',Active=false,selectItem=function() assert(false,'empty native Wings selected') end},
            {Name='All Fighters',Active=true,selectItem=function() picks=picks+1; return true end}}
          r:OnPilotCommMenuOpened(); r:UpdatePilotCommMenu(); r:UpdatePilotCommMenu()
          assert(picks==1 and not r.PilotCommMenuPending,'logical wing command menu is inaccessible')
          mn.CommItems[2].Active=false; r:OnPilotCommMenuOpened(); r:UpdatePilotCommMenu(); assert(picks==1)
        ''')

    def test_armed_sentry_world_gesture_places_instead_of_box_selecting(self):
        self.check('''
          r.ArmedCommand='sentry'; r.ArmedSentryIndex=1; r.CommandPoints=1000
          local world=stations.BLUE.Position+ba.createVector(2000,0,0)
          r.ScreenToPlane=function() return world end
          io.getMouseX=function() return 300 end; io.getMouseY=function() return 300 end
          bit.checkBit=function(value,index) return index==0 end
          r.LeftDrag={x1=280,y1=280,onUI=false}; r.SelectBox=function() assert(false,'placement turned into box selection') end
          r:OnMouseReleased(1)
          assert(#r.PendingSentries==1 and r.ArmedCommand==nil,'gesture did not reach paid placement')
          assert(r.PendingSentries[1].pos:getDistance(world)<.01 and r.CommandPoints==750)
        ''')

    def test_capital_binding_override_cycles_turrets_and_suppresses_native_bank_message(self):
        self.check('''
          local hooks={}; io.Keybinding={}
          for _,name in ipairs({'CYCLE_NEXT_PRIMARY','CYCLE_PREV_PRIMARY','CYCLE_SECONDARY'}) do
            io.Keybinding[name]={Name=name,registerHook=function(self,f,enabled,override) assert(override); hooks[self.Name]=f end,
              enableScripting=function(self,value) self.enabled=value end}
          end
          r.PossessedSignature=12; r.PilotTurretGroups={{},{}}; local count=0
          r.CyclePilotTurretGroup=function(self,dir) count=count+dir end
          r:SetPilotWeaponCycleHooks(true)
          assert(hooks.CYCLE_SECONDARY()==true and count==1,'native secondary-bank action was not overridden')
          r.Paused=true; assert(hooks.CYCLE_SECONDARY()==true and count==1)
          r.Paused=false; r.PilotTurretGroups=nil; assert(hooks.CYCLE_SECONDARY()==false,'fighter bank controls were swallowed')
          local pilot=mkFighter('countermeasure owner'); pilot.CountermeasuresLeft=5
          r.GetPossessedShip=function() return pilot end
          local proxy=mkFighter('countermeasure proxy'); r.GetObserver=function() return proxy end
          local decoy={isValid=function() return true end,vanish=function(self) self.gone=true end}
          r:OnPilotCountermeasureFired(proxy,decoy)
          assert(decoy.Parent==pilot and pilot.CountermeasuresLeft==4 and proxy.CountermeasuresLeft==4,'native decoy ownership/ammo not transferred')
          r.Paused=true; r:OnPilotCountermeasureFired(proxy,decoy)
          assert(decoy.gone and pilot.CountermeasuresLeft==4,'paused launch consumed real ammunition')
          r:SetPilotWeaponCycleHooks(false); assert(not io.Keybinding.CYCLE_SECONDARY.enabled)
        ''')

    def test_eliminated_fleet_retaliation_is_observable_while_other_bases_remain(self):
        self.check('''
          local red=ship('Red survivor',class('SF Mara'),ba.createVector(0,0,0),mn.Teams.hostile)
          local blue=mkFighter(nil,ba.createVector(0,0,1000))
          local record=r:RecordShipCreated(red)
          r.AftermathActive=false; r.GameStatus='ACTIVE'
          r.GetShipList=function() return {red,blue} end
          r.IsPursuitPair=function() return false end
          r:EliminateFaction('RED','BLUE'); r:UpdateSurvivorCombat(10)
          local order=r.AIOrderState[red:getSignature()]
          assert(order and order.reason=='RETALIATE_BASE_KILLER' and record.fate=='PRESENT'
            and not r:IsShipWithdrawing(red),'retaliation was not assigned or altered ship history')
          r.NextSurvivorCombat=0; r:UpdateSurvivorCombat(14)
          assert(r.AIOrderState[red:getSignature()].targetSignature==order.targetSignature,
            'repeat survivor evaluation unnecessarily retargeted a valid killer asset')
          assert(r:GetUnitHistory(red)==record and record.fate=='PRESENT',
            'live withdrawal history lost the same ship identity')
        ''')

    def test_out_of_map_ai_units_retarget_inward_without_overriding_player_orders(self):
        self.check('''
          local enemyTarget=ship('Stray target',class('SF Mara'),ba.createVector(26000,0,0),mn.Teams.friendly)
          local red=ship('Stray AI',class('GTF Ulysses'),ba.createVector(27000,0,0),mn.Teams.hostile)
          red.Orders={}; red.clearOrders=function(self) self.Orders={} end
          red.giveOrder=function(self,kind,target) self.Orders[#self.Orders+1]={kind=kind,target=target}; return true end
          local calls=0; local assigned
          r.AIOrderState={[red:getSignature()]={targetSignature=enemyTarget:getSignature(),mission='PRIMARY'}}
          r.AssignAIStrategicOrder=function(self,unit,kind,force)
            calls=calls+1; assigned={unit=unit,kind=kind,force=force}
            self.AIOrderState[unit:getSignature()]={targetSignature=stations.BLUE:getSignature(),mission='PRIMARY'}
          end
          r.GetShipList=function() return {stations.BLUE,stations.RED,stations.GOLD,enemyTarget,red} end
          r.LastWorldBoundsAudit=-100; r.WorldBoundsWarnings={}
          r:AuditWorldPositions(1)
          assert(calls==1 and assigned.unit==red and assigned.kind=='RED' and assigned.force,
            'an active AI hull outside the map kept its outward strategic order')
          assert(r.WorldBoundsWarnings[red:getSignature()])
          local blue=mkFighter('Manual out of map',ba.createVector(27000,0,0))
          r.UserOrders[blue:getSignature()]={kind='attack',targetSignature=enemyTarget:getSignature()}
          r.LastWorldBoundsAudit=0; r:AuditWorldPositions(2)
          assert(calls==1,'world-bound recovery overrode a player-owned attack')
        ''')

    def test_beam_status_explains_target_and_range_requirements(self):
        self.check('''
          local pilot=mkFighter(); local inventory={beams=3,beamRange=4000}
          pilot.Position=ba.createVector(0,0,0); pilot.Target=nil
          assert(r:GetPilotBeamStatus(pilot,inventory):find('SELECT A HOSTILE TARGET',1,true))
          assert(r:GetPilotBeamStatus(pilot,inventory):find('LOCAL GUNNERS',1,true),'status implies a selected target is mandatory despite local gunners')
          local target=mkStation(ba.createVector(0,0,6000)); target.Radius=0; pilot.Target=target
          assert(r:GetPilotBeamStatus(pilot,inventory):find('OUT OF REACH',1,true))
          assert(r:GetPilotBeamStatus(pilot,inventory):find('LOCAL GUNNERS',1,true),'selected range warning hides local firing eligibility')
          target.Position=ba.createVector(0,0,3000)
          assert(r:GetPilotBeamStatus(pilot,inventory):find('3 BANKS',1,true))
          assert(r:GetPilotBeamStatus(pilot,{beams=0})==nil)
        ''')

    def test_blue_station_victory_is_immutable_while_enemy_mobile_assets_remain(self):
        self.check('''
          r.GameStatus='ACTIVE'; r.BlueEliminated=false
          local blue=mkFighter(); local enemy=ship('Last Red hull',class('SF Mara'),ba.createVector(0,0,1000),mn.Teams.hostile)
          r.EachShip=function(self,f) f(blue); f(enemy) end
          r.GetShipList=function() return {blue,enemy,stations.BLUE} end
          r.GetLivingFactionKeys=function() return {'BLUE'} end
          r:EvaluateFactionVictory()
          local result=r.StrategicResult
          assert(result and result.victor=='BLUE' and r.AftermathActive and r.PostBattleActive
            and enemy.HitpointsLeft>0,'strategic result waited for mobile-ship extermination')
          assert(r:ResumePostBattle() and r.AftermathActive,'strategic victory did not resume into aftermath')
          r:EvaluateFactionVictory()
          assert(r.StrategicResult==result and not r.PostBattleActive,'surviving enemy hull rewrote the winner')
          enemy.HitpointsLeft=0; r:EvaluateFactionVictory()
          assert(r.FleetFateFinal and r.PostBattleActive and r.StrategicResult==result
            and r.BattleVictor=='BLUE','later fleet fate changed the immutable station result')
          r:ResetState(); assert(not r.StrategicResult and not r.FleetFateFinal,'restart retained resolved history')
        ''')

    def test_pilot_hints_have_a_separate_panel_below_status(self):
        self.check('''
          local pilot=mkFighter(); r.GetPossessedShip=function() return pilot end
          for _,visible in ipairs({false,true}) do
            r.ShowHotkeyHints=visible; local rectangles={}; local text={}
            gr.drawRectangle=function(x1,y1,x2,y2,filled) if filled then rectangles[#rectangles+1]={x1=x1,y1=y1,x2=x2,y2=y2} end end
            gr.drawString=function(s,x,y) text[#text+1]={s=s,y=y} end
            r:DrawPilotHUD(640,480)
            assert(#rectangles==2 and rectangles[2].y1>rectangles[1].y2,'hints mingle with pilot status')
            assert(rectangles[2].y2<=480)
            for _,line in ipairs(text) do if line.s:find('F10',1,true) then assert(line.y>rectangles[1].y2) end end
          end
        ''')

    def test_flak_tracks_local_fighters_leads_motion_and_retains_manual_trigger(self):
        self.check('''
          local capital=mkHull('GTD Orion',ba.createVector(0,0,0),'capital')
          capital.Orientation={getFvec=function() return ba.createVector(0,0,1) end}
          local selected=mkStation(ba.createVector(0,0,5000)); capital.Target=selected
          local fighter=ship('Incoming fighter',class('SF Mara'),ba.createVector(0,0,900),mn.Teams.hostile)
          fighter.__role='fighter'; fighter.Radius=20; fighter.Physics.Velocity=ba.createVector(160,0,0)
          local weapon={Name='Standard Flak',Speed=700,LifeMax=1.5,Range=4000,isValid=function() return true end,isBeam=function() return false end}
          tb.WeaponClasses={['Standard Flak']=weapon}
          local calls=0; local gun={WorldPosition=ba.createVector(0,0,0),PrimaryBanks={{WeaponClass=weapon}},SecondaryBanks={},
            isValid=function() return true end,isTargetInFOV=function(self,t) return not t.outOfArc end,
            isPositionInFOV=function() return true end,rotateTurret=function(self,point) self.aim=point end,
            fireWeapon=function(self,slot,range,direction) calls=calls+1; self.burstRange=range; self.direction=direction; return true end}
          r.GetPossessedShip=function() return capital end; r.GetShipList=function() return {capital,selected,fighter} end
          local entry={subsystem=gun,wasLocked=false,flakWeapon=weapon}
          r.PilotTurretGroups={{label='Flak',turrets={entry}}}
          r:UpdatePilotTurretFire(false,false)
          assert(gun.Target==fighter and gun.aim.x>200 and calls==0,'flak ignores local threats or fires without input')
          r:UpdatePilotTurretFire(true,false)
          assert(calls==1 and gun.direction.x>0 and gun.burstRange>900,'flak has no intercept aim or correct burst distance')
          fighter.HitpointsLeft=0; r:UpdatePilotTurretFire(false,false)
          assert(gun.Target==nil and calls==1,'flak retains a dead contact')
          assert(capital.Target==selected,'local flak control stole the pilot target')
        ''')

    def test_targetless_beam_does_not_call_native_fire_and_consume_cooldown(self):
        self.check('''
          local hull=mkHull('GTD Orion',ba.createVector(0,0,0),'capital')
          hull.Orientation={getFvec=function() return ba.createVector(0,0,1) end}
          local weapon={Name='BGreen',Range=4000,Speed=1600,LifeMax=25,isValid=function() return true end,isBeam=function() return true end}
          local calls=0; local gun={WorldPosition=ba.createVector(0,0,0),PrimaryBanks={{WeaponClass=weapon}},SecondaryBanks={},
            getNextFiringPosition=function() return ba.createVector(0,0,0),ba.createVector(0,0,1) end,
            getFOVs=function() return .5 end,
            isValid=function() return true end,rotateTurret=function() end,fireWeapon=function() calls=calls+1; return false end}
          r.GetPossessedShip=function() return hull end
          r.PilotTurretGroups={{turrets={{subsystem=gun,wasLocked=false}}}}
          r:UpdatePilotTurretFire(true,false)
          assert(calls==0,'targetless beam entered the engine cooldown path')
          gun.Target=mkStation(ba.createVector(0,0,2000)); hull.Target=gun.Target; r:UpdatePilotTurretFire(true,false)
          assert(calls==1,'a selected target cannot fire')
          gun.getNextFiringPosition=function() return ba.createVector(0,0,0),ba.createVector(0,0,-1) end
          r:UpdatePilotTurretFire(true,false)
          assert(calls==1,'beam cooldown consumed while the barrel is still turning')
        ''')

    def test_pilot_swarm_launch_uses_contact_direction_without_touching_unpossessed_fire(self):
        self.check('''
          local hull=mkHull('GTVA Colossus',ba.createVector(0,0,0),'capital')
          local target=mkFighter('Swarm contact',ba.createVector(500,0,500)); target.Team=mn.Teams.hostile
          target.Physics.Velocity=ba.createVector(0,0,0)
          local weapon={Class={Name='MX-52',Speed=150,LifeMax=7,getSwarmInfo=function() return true end},Position=ba.createVector(0,0,0),
            Physics={Velocity=ba.createVector(0,0,150)},isValid=function() return true end,
            ParentTurret={Target=target,isValid=function() return true end}}
          r.PossessedSignature=hull.signature
          r:OnPilotTurretFired(weapon,hull)
          assert(weapon.Physics.Velocity.x>100 and weapon.Physics.Velocity.z>100,'deferred swarm ignores manual aiming vector')
          weapon.Physics.Velocity=ba.createVector(0,0,150); r.PossessedSignature=nil
          r:OnPilotTurretFired(weapon,hull)
          assert(weapon.Physics.Velocity.x==0,'native unpossessed salvo is changed')
        ''')

    def test_laser_battery_uses_local_target_when_selected_hull_is_unreachable(self):
        self.check('''
          local hull=mkHull('GTD Orion',ba.createVector(0,0,0),'capital')
          local distant=mkStation(ba.createVector(0,0,6000))
          local near=ship('Near hostile',class('SF Mara'),ba.createVector(0,0,800),mn.Teams.hostile)
          local friendly=mkFighter(nil,ba.createVector(0,0,100))
          local edge=ship('Closer arc-edge hostile',class('SF Mara'),ba.createVector(300,0,50),mn.Teams.hostile)
          local turret={WorldPosition=hull.Position,isTargetInFOV=function(self,t) return not t.outOfArc end,isPositionInFOV=function() return true end,
            getNextFiringPosition=function() return hull.Position,ba.createVector(0,0,1) end}
          local entry={subsystem=turret,range=1500}
          r.GetShipList=function() return {friendly,edge,near,distant} end
          assert(r:GetPilotBatteryTarget(hull,entry,distant)==near,'short laser battery idles on distant capital')
          distant.Position=ba.createVector(0,0,1200)
          assert(r:GetPilotBatteryTarget(hull,entry,distant)==distant,'local gunners ignore a valid selected target')
          distant.outOfArc=true; near.HitpointsLeft=0
          edge.HitpointsLeft=0
          assert(r:GetPilotBatteryTarget(hull,entry,distant)==nil,'battery shoots through hull or at friendly/dead target')
        ''')

    def test_beam_gunners_avoid_large_target_straddling_barrel_cone(self):
        self.check('''
          local hull=mkHull('GTD Orion',ba.createVector(0,0,0),'capital')
          local large=mkStation(ba.createVector(1000,0,1100)); large.Radius=900
          local localTarget=ship('Local hostile',class('SF Mara'),ba.createVector(0,0,800),mn.Teams.hostile)
          local turret={WorldPosition=hull.Position,isTargetInFOV=function() return true end,isPositionInFOV=function() return true end,
            getNextFiringPosition=function() return hull.Position,ba.createVector(0,0,1) end,getFOVs=function() return .707 end}
          local entry={subsystem=turret,range=7000,hasBeam=true}
          r.GetShipList=function() return {large,localTarget} end
          assert(r:GetPilotBatteryTarget(hull,entry,large)==localTarget,'beam wastes cooldowns on random model points outside its cone')
          large.Position=ba.createVector(0,0,5000)
          assert(r:GetPilotBatteryTarget(hull,entry,large)==large,'beam gunners ignore selected hull fully inside their cone')
          large.Position=ba.createVector(1000,0,1100); localTarget.HitpointsLeft=0
          assert(r:GetPilotBatteryTarget(hull,entry,large)==large,'beam abandons the only legal target')
        ''')

    def test_move_and_ai_rally_destinations_clear_their_own_station_hull(self):
        self.check('''
          local station=stations.BLUE; station.Class.Model.Radius=2000
          local hull=mkHull('GTD Orion',station.Position+ba.createVector(0,0,8000),'capital'); hull.Class.Model.Radius=1500
          assert(r:MoveShipTo(hull,station.Position))
          local point=r.MoveWaypoints[hull.signature].waypoint.Position
          assert(point:getDistance(station.Position)>=2000+1500,'move waypoint lies inside the friendly station')
        ''')

    def test_near_station_formation_translates_as_a_group_without_collapsing_slots(self):
        self.check('''
          local group=mkGroup(6); stations.BLUE.Class.Model.Radius=1800
          local slots=r:BuildSafeFormationDestinations(group,stations.BLUE.Position,'LINE_ABREAST',stations.BLUE.Position+ba.createVector(0,0,1000))
          assert(#slots==6)
          for i,a in ipairs(slots) do
            assert(a.destination:getDistance(stations.BLUE.Position)>=1800+r:GetShipFormationRadius(a.ship),'formation overlaps station hull')
            for j=1,i-1 do
              local b=slots[j]
              assert(a.destination:getDistance(b.destination)>=r:GetShipFormationRadius(a.ship)+r:GetShipFormationRadius(b.ship)+60-.01,'station avoidance collapsed slots')
            end
          end
        ''')

    def test_waypoints_remain_usable_without_a_live_command_station(self):
        self.check('''
          local hull=mkFighter(nil,ba.createVector(-4000,0,0))
          local destination=ba.createVector(4000,0,0)
          r.GetWithdrawalHomeClearance=function() return nil end
          local dead=stations.BLUE; dead.HitpointsLeft=0
          for _,station in ipairs({false,dead}) do
            r.GetFactionCommandShip=function() return station or nil end
            local first=r:ConfigureMoveWaypoints(hull,destination)
            assert(first and first.Position:getDistance(destination)<.01,
              'stationless hull lost its direct movement/pursuit waypoint')
            assert(not r.MoveWaypoints[hull.signature].route,'absent station created a detour')
          end
        ''')

    def test_station_crossing_route_uses_clear_detour_and_reuses_waypoints(self):
        self.check('''
          local station=stations.BLUE; station.Class.Model.Radius=1000
          local hull=mkFighter(nil,ba.createVector(-4000,0,0)); hull.Class.Model.Radius=50
          local destination=ba.createVector(4000,0,0)
          local first=r:ConfigureMoveWaypoints(hull,destination)
          local route=r.MoveWaypoints[hull.signature].route
          assert(first and route and #route==3,'route does not detour around station')
          assert(math.abs(first.Position.z)>1300 and route[2].Position:getDistance(destination)<.01)
          local same=r:ConfigureMoveWaypoints(hull,destination)
          assert(same==first and r.MoveWaypoints[hull.signature].route==route,'route leaks new waypoints on every update')
          r:ConfigureMoveWaypoints(hull,ba.createVector(-6000,0,0))
          for _,point in ipairs(route) do assert(point.Position.x==-6000,'straight route retained stale detour nodes') end
        ''')

    def test_flak_launch_uses_actual_muzzle_and_finalizes_range_after_native_assignment(self):
        self.check('''
          local hull=mkHull('GTD Hecate',ba.createVector(0,0,0),'capital'); r.PossessedSignature=hull.signature
          local target=ship('Fighter',class('SF Mara'),ba.createVector(0,100,900),mn.Teams.hostile)
          target.Physics.Velocity=ba.createVector(100,0,0)
          local gun={Target=target,WorldPosition=ba.createVector(0,0,0),isValid=function() return true end}
          local shot={Class={Name='Standard Flak',Speed=700,LifeMax=1.5},ParentTurret=gun,
            Position=ba.createVector(0,100,0),Physics={Velocity=ba.createVector(0,0,700)},isValid=function() return true end}
          r:OnPilotTurretFired(shot,hull)
          assert(shot.Physics.Velocity.y==0 and shot.Physics.Velocity.x>0,'launch aim uses turret mount instead of actual muzzle')
          shot.FlakDetonationRange=1000 -- native setter runs after the callback
          r:FinalizePilotFlakShots()
          assert(shot.FlakDetonationRange>900 and shot.FlakDetonationRange<1000 and r.PilotFlakPendingShots==nil)
        ''')

    def test_unassigned_pilot_gets_live_hostile_guidance_and_restart_clears_command_state(self):
        self.check('''
          local pilot=mkFighter(); r.GetPossessedShip=function() return pilot end
          pilot.Target=nil; r.PilotAIObjective=nil; r.PilotPreviousUserOrder=nil
          local order,source=r:GetPilotTacticalOrder()
          assert(order and order.targetSignature and source=='SUGGESTED TASK','unassigned pilot has no target guidance')
          local target=r:FindShipBySignature(order.targetSignature)
          assert(r:AreEnemies(pilot,target) and pilot.Target==nil)
          r.EachShip=function() assert(false,'unchanged suggestion rescans every ship') end
          assert(r:GetPilotTacticalOrder().targetSignature==target.signature)
          r.PilotCommOrders={saved=true}; r.PilotCommWarningUntil=99
          r:ResetState()
          assert(r.PilotSuggestedTarget==nil and r.PilotCommOrders==nil and r.PilotCommWarningUntil==nil)
        ''')

    def test_capital_pilot_hud_uses_real_bindings_named_aim_and_honest_fire_status(self):
        self.check('''
          r.ShowHotkeyHints=true
          local s=mkHull('Pilot fixture',nil,'capital')
          local enemy=mkStation(); enemy[1].Name='Engine'; s.Target=enemy
          r.GetPossessedShip=function() return s end
          r.PilotTurretGroups={{label='Beam battery',turrets={}}}; r.PilotTurretGroupIndex=1
          r.PilotTargetSubsystemIndex=1; r.PilotTurretFiring=true
          io.Keybinding={FIRE_PRIMARY={Name='FIRE_PRIMARY',getInputName=function(self,first) return first and 'CUSTOM PRIMARY' or 'Mouse 1' end},
            FIRE_SECONDARY={Name='FIRE_SECONDARY',getInputName=function() return '' end}}
          assert(r:GetPilotBindingLabel('FIRE_PRIMARY')=='CUSTOM PRIMARY / Mouse 1')
          assert(r:GetPilotBindingLabel('FIRE_SECONDARY')=='UNBOUND')
          assert(r:GetPilotTargetSubsystemLabel()=='Engine (1/1)','single subsystem is unnamed or hidden')
          local text={}; local bottom=0
          gr.drawString=function(t,x,y) text[#text+1]=tostring(t); bottom=math.max(bottom,y+9) end
          gr.drawRectangle=function(x1,y1,x2,y2) assert(y2<=720,'pilot help leaves viewport') end
          r:DrawPilotHUD(1280,720)
          local all=table.concat(text,' ')
          assert(all:find('CUSTOM PRIMARY',1,true),'real primary control is missing')
          assert(not all:find('UNBOUND',1,true),'empty secondary battery advertises a fire control')
          assert(all:find('Engine',1,true) and all:find('hull/subsystem',1,true),'aim controls are missing')
          assert(all:find('TRIGGER: HELD',1,true),'held input is misrepresented as successful firing')
          assert(all:find('RETURN TO RTS',1,true) and bottom<=720)
          text={}; bottom=0
          gr.drawRectangle=function(x1,y1,x2,y2) assert(x1>=0 and x2<=640 and y2<=480,'pilot help leaves a short viewport') end
          r:DrawPilotHUD(640,480)
          assert(table.concat(text,' '):find('RETURN TO RTS',1,true) and bottom<=480,'short-screen help hides the exit key')
        ''')


if __name__ == '__main__':
    unittest.main()
