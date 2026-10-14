-- Selected-ship queries and state reset.
local _shared = require "fs2rts_factions.common"
local RTS, clamp = _shared.RTS, _shared.clamp

function RTS:GetSelectedShips()
    local result = {}
    local cleaned = {}
    for _, signature in ipairs(self.Selected) do
        local ship = self:FindShipBySignature(signature)
        if self:IsSelectableShip(ship) then
            result[#result + 1] = ship
            cleaned[#cleaned + 1] = signature
        end
    end
    self.Selected = cleaned
    return result
end

function RTS:GetSelectedFriendlyShips()
    local result={}; local seen={}
    for _,ship in ipairs(self:GetSelectedShips()) do
        if self:IsFriendly(ship) then
            local sig=ship:getSignature()
            if not seen[sig] then result[#result+1]=ship; seen[sig]=true end
        end
    end
    return result
end

function RTS:GetPrimarySelectedShip()
    local ships = self:GetSelectedShips()
    if #ships > 0 then return ships[1] end
    return nil
end

function RTS:CountFriendlyCombatants()
    local count = 0
    self:EachShip(function(ship)
        if self:IsMovableFriendly(ship) then
            count = count + 1
        end
    end)
    return count
end

function RTS:CountHostiles()
    local count = 0
    self:EachShip(function(ship)
        if self:IsPlayerEnemy(ship) then count = count + 1 end
    end)
    return count
end

function RTS:ResetState()
    if self.ClearIntroScene then self:ClearIntroScene() end
    if self.ClearSetupBackdrop then self:ClearSetupBackdrop() end
    if self.StopEnvironment then self:StopEnvironment() end
    self.EnvironmentPicker=false; self.SetupMusicChoice='RANDOM'; self.SetupBackdropChoice='RANDOM'
    if self.ShowHotkeyHints==nil then self.ShowHotkeyHints=false end
    self.HotkeyHintsHeld=false; self.ExitMenuActive=false; self.ExitMenuResumeScale=nil; self.ExitMenuButtonRects={}
    self.PilotAIObjective=nil; self.PilotDirectiveWarningShown=false
    self.PilotSuggestedTarget=nil; self.PilotSuggestedAt=nil; self.PilotCommOrders=nil; self.PilotCommWarningUntil=nil
    self.PilotCommMenuPending=nil; self.PilotCommMenuActive=false
    if self.RestorePilotHullHUD then self:RestorePilotHullHUD() end
    self.PilotWeaponCycleHooksActive=false
    self.PilotFlakCandidates=nil
    self.PilotFlakPendingShots=nil
    if self.PilotWeaponsHUDOverridden then self:SetPilotWeaponsHUD(false) end
    self:ReleaseObjectHandles()
    if self.ResetFleetLife then self:ResetFleetLife() end
    self:ResetStationState()
    self:CloseAITrace()
    self:ResetCoordinatedAI()
    self.Selected = {}; self.ControlGroups = {}; self.MoveWaypoints = {}; self.BuildQueue = {}
    self.BuildSerial=0; self.ProductionJobSerial=0; self.EnemySerial=0; self.GoldSerial=0; self.WaveIndex=1; self.GoldWaveIndex=1
    self.CommandPoints=self.Config.Economy.StartingCommandPoints; self.ActiveIncomePerSecond=self.Config.Economy.PassiveIncomePerSecond; self.LastIncomeTime=0
    self.GameStatus="SETUP"; self.StatusMessage="Configure escalation battle, then START."; self.StatusUntil=math.huge
    self.KeyDown={}; self.FastKeyDown={}; self.CtrlDown=false; self.ShiftDown=false; self.AltDown=false
    self.LeftDrag=nil; self.RightDrag=nil; self.MiddleDrag=nil; self.MapDrag=nil; self.FollowOrbitDrag=nil; self.MovePreview=nil
    self.BuildButtonRects={}; self.BuildNavRects={}; self.ActionButtonRects={}; self.PolicyButtonRects={}; self.SetupButtonRects={}; self.TimeButtonRects={}; self.PostBattleButtonRects={}
    self.CommandMarker=nil; self.CommandMarkerUntil=0; self.FollowSignature=nil; self.FollowZoom=1.0; self.FollowYawOffset=0; self.FollowPitchOffset=0.22
    self.LastLeftClickTime=-100; self.LastLeftClickX=0; self.LastLeftClickY=0; self.LastLeftClickKey=nil
    self.PossessedSignature=nil; self.PilotCamera=nil; self.PilotCameraSerial=0; self.PilotButtons={0,0,0,0}; self.PilotPreviousUserOrder=nil
    -- PilotTurretGroups holds l_Subsystem userdata and PilotNativeWing holds an
    -- l_Wing; both belong to the mission that created them. RestorePilotTurretGroups
    -- and LeavePilotNativeWing are only reachable through ExitPilotMode, which
    -- needs PossessedSignature, and the line above has just cleared it -- so a
    -- restart entered from Shutdown's early-return (Enabled already false, or the
    -- observer already deleted) would carry engine objects from the old mission
    -- into the new one. Clear the same field set the two restore functions clear.
    self.PilotTurretGroups=nil; self.PilotTurretGroupIndex=nil; self.PilotTurretLastGroupIndex=nil; self.PilotTurretAppliedGroupIndex=nil
    self.PilotTurretFiring=false; self.PilotTurretFireLatched=false; self.PilotTurretFireStatusAt=nil
    self.PilotTargetSubsystemIndex=0; self.PilotTargetSubsystemCount=0; self.PilotAimTargetSignature=nil; self.PilotNativeSubsystemName=nil; self.PilotNativeWing=nil; self.PilotNativeWingLabel=nil
    self.PilotShieldMirrorSnapshot=nil
    self.PilotWeaponEnergyMirrorSnapshot=nil; self.PilotProxyRecharge=nil
    self.ObserverHomePosition=nil; self.ObserverHomeOrientation=nil; self.ObserverOriginalClassName=nil
    self.UserOrders={}; self.PolicyApplied={}; self.PolicyDefend={}; self.EngageTargets={}; self.GlobalPolicy=self.Config.Policy.Default or "STANDOFF"; self.LastPolicyRefresh=-100
    self.SetupActive=true; self.SetupDifficultyIndex=self.Config.Setup.DefaultDifficulty or 2
    self.SetupFactionCountChoice=nil; self.SetupFactionPage=1; self.FactionSpecies={}; self.FactionColorCache=nil; self.FactionRosterCache=nil
    self.FactionColorChoices=nil; self.SetupColorPicker=nil; self.GeneratedShipNameSerial=0
    self.ActiveFactionKeys=nil; self.ActiveFactionSet=nil; self.ActiveFactionCount=nil
    local defaultFactions=math.floor(clamp(self.Config.Setup.DefaultFactions or 2,2,self:GetMaxFactionCount()))
    self.SetupOpponents={}
    for i=2,defaultFactions do self.SetupOpponents[self.Config.FactionOrder[i]]=true end
    self:UpdateFactionCount()
    self.SetupEconomyIndex=self.Config.Setup.DefaultEconomy or 2
    self.SetupAutoMode=self.Config.Setup.DefaultAutoMode == true; self.SetupAsteroids=self.Config.Setup.DefaultAsteroids==true; self.SetupSentries=self.Config.Setup.DefaultSentries==true; self.AutoPlayerMode=false
    self.SetupBaseDistanceIndex=self.Config.Setup.DefaultBaseDistance or 2
    self.SetupBaseLayoutIndex=self.Config.Setup.DefaultBaseLayout or 1
    self.ScenarioBasePositions={}; self.ScenarioMapHalfExtent=nil; self.ScenarioBaseLayoutId=nil
    self.ScenarioStartTime=nil; self.FactionEliminated={BLUE=false,RED=false,GOLD=true}; self.RedEliminated=false; self.GoldEliminated=true; self.BlueEliminated=false; self.BattleVictor=nil
    self.PostBattleActive=false; self.PostBattleResult=nil
    self.AftermathActive=false; self.AftermathStationCount=nil; self.AftermathResultStatus=nil; self.AftermathResultText=nil
    self.AftermathFinalVictory=false
    self.SurvivorTargets={}; self.FactionDefeatedBy={}; self.NextSurvivorCombat=0; self.AftermathReportRect=nil
    self.NextStationPointDefense=0; self.PilotBatteryCandidates=nil
    self.PreviousButtonControlMode=nil; self.BuildPage=1; self.BuildRowsPerPage=5; self.ShipCostMap={}; self.BuildCatalog={}
    self.CinematicActive=false; self.CinematicElapsed=0; self.CinematicShotIndex=1; self.CinematicCaption=nil; self.CinematicSubcaption=nil; self.CinematicFaction=nil; self.CinematicCaptionAlpha=0
    self.AnnouncementText=nil; self.AnnouncementFaction=nil; self.AnnouncementUntil=-1
    self.NewUnitPopup=nil; self.NewUnitPopupRect=nil; self.NewUnitPopupSelectRect=nil
    self.AIStates={}; self.AIOrderState={}; self.AIPlanTelemetry={}; self.AIOrderTelemetry={attempts=0,success=0,failed=0,rejected=0,unchanged=0,byMission={},byResult={}}; self.CombatTelemetryEnabled=false; self.LastAIThink=-100; self.LastAIStrategicUpdate=-100; self.AIStrategicPlanQueue=nil; self.StationBaseHull={}; self.StaticDefenseSignatures={}; self.DyingStations={}; self.TacticalMapIconCache={}; self.LastEscalationTier=1; self.LastWorldBoundsAudit=-100; self.WorldBoundsWarnings={}
    -- Mission-scoped economy ledgers. AIEconomyFlow is the per-sample INTERVAL
    -- that FACTION publishes and zeroes; AIEconomyFlowCumulative is the running
    -- total behind it. Without the running total the spend that happens after
    -- the last FACTION record of a match is never published by anyone, because
    -- the interval it belonged to is zeroed before it is ever reported - so the
    -- event stream and the flow disagree by that trailing interval on every run.
    self.AIEconomyFlow=nil; self.AIEconomyFlowCumulative=nil
    self.RTSWings={}; self.WingBySignature={}; self.WingSerial=0; self.WingNameCounters={}
    self.PrimarySelectionSignature=nil; self.SelectionRows={}; self.SelectionRowsShown=0; self.HoveredSelectionRow=nil; self.HoveredSelectionSigs={}; self.ArmedCommand=nil; self.QuickGroupRects={}; self.AutoModeRect=nil
    self.PendingPilotEject=false; self.PendingPilotEjectRemaining=nil; self.PendingPilotEjectPosition=nil; self.PendingPilotEjectOrientation=nil; self.PendingPilotEjectRadius=nil; self.PilotDeathRestoreTimeScale=nil; self.PilotDeathRestoreLastNonZeroTimeScale=nil; self.FactionPrimaryTargets={}; self.StationBeamHits={}; self.StationBeamHitSeen={}; self.NextStationBeamCleanup=0
    -- Learned beam reach is mission-scoped evidence. Carrying it across a
    -- restart is the DyingStations defect class: a stale signature resolving to
    -- an unrelated hull would arrive with a reach it never earned.
    self.RosterModelWarmup=nil
    self.TimeScale=1; self.LastNonZeroTimeScale=1; self.Paused=false; self.PausedTimeScale=nil
    self.UIClock=0; self.RoleByClass={}; self.RosterIndex=nil; self.ShipCache=nil; self.ShipSignatureIndex=nil; self.FreeMoveWaypoints={}; self.ButtonControlMode=nil
    self.BattleCamActive=false; self.FreeCamActive=false; self.BattleCamSignature=nil; self.BattleCamTargetSignature=nil
    self.BattleCamShotStart=nil; self.BattleCamShotUntil=0; self.CinematicTailHold=nil
    self.MapWindowDrag=nil; self.MapPanDrag=nil; self.SwallowMouseRelease=false
    self.EscapeKeyOverride=nil
    self.TopBarCounters=nil; self.TopBarFieldCache=nil; self.HoverReadout=nil; self.OrderPing=nil
    self.NextSentryAimUpdate=0
    self.ProjectionAt=nil; self.ProjectionPrunedAt=nil; self.ProjectionEpoch=nil
    self.AIPursuit={}; self.EngagePursuit={}; self.NextAIPursuitRefresh=nil
    self.BuildRoleFilter=nil; self.BattleSummary=nil
    self.NextMoveReconcile=0; self.BlueAutoStateLeakAt=nil; self.TooltipModelAt=nil
end
