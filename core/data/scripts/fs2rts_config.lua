return {
    MissionNames = {
        ["rts_command_test"] = true,
        ["rts_command_test.fs2"] = true,
        ["fs2_rts_escalation"] = true,
        ["fs2_rts_escalation.fs2"] = true,
    },

    FriendlyTeam = "friendly",
    HostileTeam = "hostile",
    ThirdTeam = "neutral",
    ObserverShip = "RTS Observer",
    FleetHumanity = {
        ModelVersion = 1,
        -- Gameplay estimates, not canonical crew facts. Destruction leaves the rest missing/unconfirmed.
        RoleCrew = {fighter=1,bomber=3,escort=80,capital=250,heavy=1500,juggernaut=6000,station=2500},
        ClassCrew = {}, DestructionDeathFraction = .80,
    },
    HotkeyHintsKey = "F10",
    FleetCostToggleKey = "F9",
    TraitorRaids = {Enabled=true,DelaySeconds=480,IntervalSeconds=180,Chance=.02,
        MaxEvents=1,WarningSeconds=12,WingChance=.65,WingSize=3},
    CarrierShip = "RTS Team 01 Station",
    EnemyCommandShip = "RTS Team 02 Station",
    ThirdCommandShip = "RTS Team 03 Station",
    Species = {
        TERRAN = { label = "TERRAN", stationClass = "GTI Arcadia", roster = "BlueRoster" },
        SHIVAN = { label = "SHIVAN", stationClass = "SI Arachnas", roster = "RedRoster" },
        VASUDAN = { label = "VASUDAN", stationClass = "GVI Cairo", roster = "GoldRoster" },
    },
    -- Political factions share species/assets, not identity. The rosters are
    -- curated per faction. Five missing FS1/ST craft are bundled as standalone
    -- ship classes with attributed models and retail-only weapons.
    FactionChoices = { "GTA", "GTVA", "PVN", "PVE", "NTF", "GTI_LOYAL", "GTI_ROGUE", "HOL", "SHIVAN", "RANDOM" },
    FactionAliases = { TERRAN="GTA", VASUDAN="PVE", NFT="NTF", GTI="GTI_LOYAL" },
    FactionProfiles = {
        GTA = { label="GTA", name="Galactic Terran Alliance", species="TERRAN", insignia="rts-faction-gta", rosters={"BlueRoster"},
            doctrine="Great War fleet: affordable massed escorts",
            classes={"GTF Ulysses","GTF Hercules","GTF Apollo","GTF Valkyrie","GTF Ares","GTB Athena","GTB Medusa","GTB Ursa","GTC Fenris","GTC Leviathan","GTD Orion"},
            abilityKey="BLUE", ability={name="ORBITAL STRIKE"} },
        PVN = { label="PVN", name="Parliamentary Vasudan Navy", species="VASUDAN", insignia="rts-faction-pvn", rosters={"GoldRoster"},
            doctrine="Great War fleet: resilient strike wings",
            classes={"PVF Anubis","GVF Horus","GVF Seth","GVF Thoth","GVB Osiris","GVB Sekhmet","GVC Aten","GVD Typhon"},
            ability={kind="reinforcement",name="MOBILE RESERVES",class="GVF Thoth",tier=1,count=4,cooldown=180} },
        GTVA = { label="GTVA", name="Galactic Terran-Vasudan Alliance", species="TERRAN", insignia="rts-faction-gtva", rosters={"BlueRoster","GoldRoster"},
            doctrine="Combined fleet: flexible but expensive endgame",
            classes={"GTF Myrmidon","GTF Perseus","GTF Ulysses","GTF Hercules Mark II","GTF Loki","GTF Pegasus","GTF Ares","GTF Erinyes","GVF Tauret","GTB Artemis","GTB Boanerges","GTB Medusa","GTB Ursa","GTB Zeus","GVB Bakha","GTC Fenris","GTC Aeolus","GTC Leviathan","GVC Aten","GVC Mentu","GTCv Deimos","GVCv Sobek","GTD Hecate","GTD Orion","GVD Typhon","GVD Hatshepsut","GTVA Colossus"},
            ability={kind="surge",name="JOINT MOBILIZATION",roles={escort=true,capital=true},cost=750,cooldown=180,radius=6000,speedMultiplier=1.30,seconds=25} },
        PVE = { label="PVE", name="Parliamentary Vasudan Empire", species="VASUDAN", insignia="rts-faction-pvn", rosters={"GoldRoster"},
            doctrine="Modern Vasudan fleet: escort and bomber support",
            classes={"GVF Tauret","GVF Serapis","GVF Ptah","GVB Bakha","GVB Sekhmet","GVC Aten","GVC Mentu","GVCv Sobek","GVD Typhon","GVD Hatshepsut"},
            abilityKey="GOLD", ability={name="REINFORCEMENT JUMP"} },
        NTF = { label="NTF", name="Neo-Terran Front", species="TERRAN", insignia="rts-faction-ntf", rosters={"BlueRoster"},
            doctrine="Terran insurgency: rapid fighter interception",
            classes={"GTF Myrmidon","GTF Hercules Mark II","GTF Loki","GTF Perseus","GTF Ulysses","GTB Artemis","GTB Medusa","GTC Aeolus","GTC Leviathan","GTCv Deimos","GTD Orion","NTF Boadicea","NTF Iceni"},
            ability={kind="surge",name="RAIDER SCREEN",roles={fighter=true},cost=750,cooldown=180,radius=6000,speedMultiplier=1.60,seconds=20} },
        GTI_LOYAL = { label="GTI LOYAL", name="Galactic Terran Intelligence - Loyalists", species="TERRAN", insignia="rts-faction-gti", rosters={"BlueRoster"},
            doctrine="Special operations: precise fire support",
            classes={"GTF Ulysses","GTF Hercules","GTF Loki","GTB Zeus","GTB Ursa","GTC Fenris","GTC Leviathan","GTD Orion"},
            ability={kind="strike",name="PRECISION STRIKE",cost=750,cooldown=150,delay=3,range=10000,radius=450,innerRadius=150,damage=1800} },
        GTI_ROGUE = { label="GTI ROGUE", name="Galactic Terran Intelligence - Hades Rebels", species="TERRAN", insignia="rts-faction-gti", rosters={"BlueRoster"},
            doctrine="Hades rebels: costly prototype flagship",
            classes={"GTF Ulysses","GTF Hercules","GTF Loki","GTB Zeus","GTB Ursa","GTC Fenris","GTC Leviathan","GTD Orion","GTD Hades"},
            ability={kind="surge",name="PROTOTYPE OVERDRIVE",roles={heavy=true,juggernaut=true},cost=1000,cooldown=240,radius=6000,speedMultiplier=1.20,seconds=20} },
        HOL = { label="HoL", name="Hammer of Light", species="VASUDAN", insignia="rts-faction-hol", rosters={"GoldRoster"},
            doctrine="Vasudan zealots: committed bomber assaults",
            classes={"PVF Anubis","GVF Horus","GVF Seth","GVF Thoth","GVB Osiris","GVB Sekhmet","GVC Aten","GVD Typhon"},
            ability={kind="surge",name="ZEALOUS ADVANCE",roles={bomber=true,escort=true},cost=750,cooldown=180,radius=6000,speedMultiplier=1.40,seconds=25} },
        SHIVAN = { label="SHIVANS", name="Shivans", species="SHIVAN", insignia="rts-faction-shivan", rosters={"RedRoster"},
            doctrine="Alien invasion: premium siege and swarm mobility",
            classes={"SF Mara","SF Basilisk","SF Dragon","SF Manticore","SF Aeshma","SF Astaroth","SB Shaitan","SB Nephilim","SB Taurvi","SB Nahema","SB Seraphim","SC Cain","SC Rakshasa","SC Lilith","SCv Moloch","SD Ravana","SD Demon","SD Lucifer","SJ Sathanas"},
            abilityKey="RED", ability={name="SWARM SURGE"} },
    },
    SentryShipClass = "GTSG Mjolnir",
    -- Normalize strategic base durability before fixed escalation modifiers,
    -- so faction choice changes arsenal/geometry rather
    -- than granting a free hull-HP advantage.
    StationBaseHull = 60000,

    -- Stable three-faction tie-break.  With symmetric base layouts a pure
    -- nearest/health sort otherwise degenerates into both AI factions choosing
    -- Blue because BLUE appears first in the candidate list.  The cycle makes
    -- the opening strategic fronts Blue -> Red -> Gold -> Blue.
    ThreeFactionTargetCycle = {
        BLUE = "RED",
        RED = "GOLD",
        GOLD = "BLUE",
    },

    Factions = {
        BLUE = {
            name = "TERRAN",
            short = "TEAM 01",
            team = "friendly",
            teamColor = "RTS Faction Blue",
            defaultSpecies = "TERRAN",
            station = "RTS Team 01 Station",
            primary = "Destroy every opposing faction command station.",
            secondary = "Protect your station; screen hostile strike craft; destroy enemy capital ships.",
        },
        RED = {
            name = "SHIVAN",
            short = "TEAM 02",
            team = "hostile",
            teamColor = "RTS Faction Red",
            defaultSpecies = "SHIVAN",
            station = "RTS Team 02 Station",
            primary = "Destroy an opposing command station while advancing through its fleet screen.",
            secondary = "Protect your station; intercept nearby threats; destroy hostile capital ships.",
        },
        GOLD = {
            name = "VASUDAN",
            short = "TEAM 03",
            team = "neutral",
            teamColor = "RTS Faction Gold",
            defaultSpecies = "VASUDAN",
            station = "RTS Team 03 Station",
            primary = "Destroy an opposing command station while advancing through its fleet screen.",
            secondary = "Protect your station; intercept nearby threats; destroy hostile capital ships.",
        },
    },

    -- The first three teams are the mission's Friendly/Hostile/Neutral IFFs.
    -- fs2rts_factions.lua adds 9 more after loading so the experiment runner
    -- can still wrap this config's single top-level return table.
    FactionOrder = { "BLUE", "RED", "GOLD" },
    FactionIndex = { BLUE=1, RED=2, GOLD=3 },
    FactionStationByName = {
        ["RTS Team 01 Station"]="BLUE", ["RTS Team 02 Station"]="RED", ["RTS Team 03 Station"]="GOLD",
    },
    FactionColors = {
        {70,220,255}, {255,75,75}, {255,190,70}, {45,190,255}, {70,230,105},
        {195,115,255}, {255,130,45}, {255,100,195}, {190,240,70}, {110,100,255},
        {60,225,185}, {255,115,95},
    },

    Camera = {
        Focus = { x = 0, y = 0, z = 500 },
        Distance = 9000,
        MinDistance = 55,
        MaxDistance = 300000,
        PitchDegrees = 58,
        MinPitchDegrees = 24,
        MaxPitchDegrees = 84,
        YawDegrees = 0,
        FOV = 1.02,
        PanSpeed = 4000,
        VerticalPanSpeed = 2800,
        EdgePanFraction = 0.015,
        EdgePanEnabled = false,
        RotationSpeed = 1.15,
        MouseOrbitYaw = 0.006,
        MouseOrbitPitch = 0.004,
        ZoomFactor = 0.78,
        KeyZoomSteps = 2, -- wheel notches per Q/E press
        FollowFOV = 0.95,
        FollowMinDistance = 150,
        FollowRadiusMultiplier = 3.2,
        FollowHeightFraction = 0.22,
        FollowLookAheadRadii = 1.4,
        DragThresholdPixels = 10,
        MousePanScale = 1.0,
        ShiftSlowMultiplier = 0.35,
        FocusBoundsMultiplier = 1.20,
    },

    -- Sins-style tactical controls. Mouse gestures are handled in fs2rts.lua:
    -- LMB selects, MMB drag pans, RMB drag orbits, RMB click issues context orders,
    -- wheel zooms toward the cursor, WASD pans, and Shift slows camera movement.
    -- Number keys recall groups, Shift assigns and Alt controls time. Keep the
    -- literals in fs2rts_input.lua in sync: ShouldOverrideKey swallows a key
    -- that is listed here, and a key that is only bound there leaks to FSO.
    HomeworldControls = {
        SelectAll = "L",
        Stop = "R",
        Engage = "T",
        Release = "G",
        ArmMove = "M",
        ArmAttack = "K",
        Focus = "F",
        FocusBase = "H",
        PanForward = "W",
        PanBackward = "S",
        PanLeft = "A",
        PanRight = "D",
        ZoomFar = "Q",
        ZoomNear = "E",
        Chase = "B",
        HoldPolicy = "J",
        PassivePolicy = "Z",
        DefensivePolicy = "X",
        AggressivePolicy = "V",
        Cinematic = "C",
        -- Labels used by the speed buttons; keyboard speed requires Alt.
        TimeSlower = "1",
        TimePause = "2",
        TimeFaster = "3",
        TimeReset = "4",
        Wing1 = "1",
        Wing2 = "2",
        Wing3 = "3",
        Wing4 = "4",
        MuteMusic = "N",
    },

    Cinematic = {
        Enabled = true,
        AllowSkip = true,
        SkipOnAnyInput = true,
        FOV = 0.86,
        -- Shot switching. Any of these keys jumps to the next/previous shot
        -- instead of skipping, so the player can pick the establishing angle
        -- they actually want. Shots cycle in both directions and wrap.
        NextShotKey = "Right",
        PreviousShotKey = "Left",
        RestartShotKey = "5",
        -- Fade through black before resetting the camera to battle setup.
        EndHoldSeconds = 2,
        Shots = {
            {
                duration = 10.2,
                subject = 1,
                from = { x = -400, y = 250, z = -650 },
                to = { x = -220, y = 150, z = -450 },
                target = { x = 0, y = 0, z = 0 },
                faction = "RIVAL COMMANDS",
                caption = "COMMANDS IN CONFLICT",
                subcaption = "Rival commands converge on contested space. Broken alliances, competing claims and old hostilities have become a fight for survival.",
            },
            {
                duration = 8.1,
                subject = 5,
                from = { x = -180, y = 75, z = -210 },
                to = { x = -100, y = 40, z = -130 },
                target = { x = 0, y = 0, z = 0 },
                caption = "LIVES ABOARD",
                subcaption = "Every deployment carries people into danger. Recover damaged crews, protect their return and keep a fighting fleet alive.",
            },
            {
                duration = 9.3,
                subject = 3,
                from = { x = -250, y = 120, z = -220 },
                to = { x = -140, y = 60, z = -170 },
                target = { x = 0, y = 0, z = 0 },
                caption = "THE ESCALATION FRONT",
                subcaption = "Reinforcements deepen the conflict. Fighters protect the strike force; bombers and capital ships threaten enemy command stations.",
            },
            {
                duration = 10.2,
                subject = 2,
                from = { x = 400, y = 230, z = 650 },
                to = { x = 200, y = 150, z = 420 },
                target = { x = 0, y = 0, z = 0 },
                faction = "OPPOSING CREWS",
                caption = "RIVAL SURVIVORS",
                subcaption = "Other commands fight for their own survival. Losing a station does not erase the ships and crews still in battle.",
            },
            {
                duration = 8.4,
                subject = 5,
                from = { x = 180, y = 90, z = -230 },
                to = { x = 100, y = 60, z = -160 },
                target = { x = 0, y = 0, z = 0 },
                caption = "THE COST OF COMMAND",
                subcaption = "Some objectives demand courage and sacrifice. Commit with purpose, cover the vulnerable and give survivors a way home.",
            },
            {
                duration = 8.7,
                subject = 1,
                from = { x = 800, y = 1800, z = -2200 },
                to = { x = 400, y = 1400, z = -1600 },
                target = { x = 0, y = 0, z = 0 },
                caption = "FLEET COMMAND",
                subcaption = "Choose your command. Lead from the tactical view or take the helm. Break the opposition while bringing your people through.",
            },
        },
    },

    -- Mission music. FSO's event music runs on the same global stream table as
    -- every other sound, so pausing handle -1 silences the whole score without
    -- touching unrelated voice or effects. The scene module owns its stream.
    Music = {
        Enabled = true,
        Muted = false,
        -- Retail soundtrack audio, streamed through FSO's VFS so MediaVP
        -- overrides win automatically. Keep this list to looping combat cues.
        Tracks = {
            { label="Genesis A", file="FS2_Btl_A01.wav", mediavps="FS2_Btl_A01.ogg" },
            { label="Genesis B", file="FS2_Btl_A02.wav" },
            { label="Genesis C", file="FS2_Btl_A03.wav" },
            { label="Exodus A", file="FS2_Btl_B01.wav" },
            { label="Exodus B", file="FS2_Btl_B02.wav" },
            { label="Exodus C", file="FS2_Btl_B03.wav" },
            { label="Leviticus A", file="FS2_Btl_C01.wav" },
            { label="Leviticus B", file="FS2_Btl_C02.wav" },
            { label="Leviticus C", file="FS2_Btl_C03.wav", mediavps="FS2_Btl_C03.ogg" },
            { label="Numbers A", file="FS2_Btl_D01.wav", mediavps="FS2_Btl_D01.ogg" },
            { label="Numbers B", file="FS2_Btl_D02.wav", mediavps="FS2_Btl_D02.ogg" },
            { label="Numbers C", file="FS2_Btl_D03.wav", mediavps="FS2_Btl_D03.ogg" },
            { label="Revelation A", file="FS2_Btl_E01.wav", mediavps="FS2_Btl_E01.ogg" },
            { label="Revelation B", file="FS2_Btl_E02.wav", mediavps="FS2_Btl_E02.ogg" },
            { label="Revelation C", file="FS2_Btl_E03.wav", mediavps="FS2_Btl_E03.ogg" },
            { label="Deuteronomy A", file="FS2_Btl_F01.wav", mediavps="FS2_Btl_F01.ogg" },
            { label="Deuteronomy B", file="FS2_Btl_F02.wav", mediavps="FS2_Btl_F02.ogg" },
            { label="Deuteronomy C", file="FS2_Btl_F03.wav", mediavps="FS2_Btl_F03.ogg" },
            { label="Joshua A", file="FS2_Btl_G01.wav", mediavps="FS2_Btl_G01.ogg" },
            { label="Joshua B", file="FS2_Btl_G02.wav", mediavps="FS2_Btl_G02.ogg" },
            { label="Joshua C", file="FS2_Btl_G03.wav", mediavps="FS2_Btl_G03.ogg" },
        },
    },

    Environment = {
        -- These are the stock retail nebula backdrops registered in stars.tbl.
        -- They are 2D sky art only: no full-nebula fog, visibility, targeting,
        -- or volumetric rendering. FSO resolves same-name MV textures via VFS.
        NebulaBackdrops = {
            "neb01", "neb02", "neb03", "neb04", "neb05", "neb06",
            "neb07", "neb08", "neb09", "neb10", "neb11", "neb12",
            "neb13", "neb14", "neb15", "neb16", "neb17", "neb18",
            "dneb01", "dneb02", "dneb03", "dneb04", "dneb05", "dneb06",
            "dneb07", "dneb08", "dneb09", "dneb10", "dneb11", "dneb12",
            "dneb13", "dneb14", "dneb15", "dneb16", "dneb17", "dneb18",
        },
        -- The mission's own nebula (+Nebula in FS2_RTS_Escalation.fs2) is the default look.
        -- These 2D sky sprites are an optional pick, so they do not start on top of it.
        RandomBackdropOnStart = false,
        BackdropPatches = 32, BackdropScaleX = 5, BackdropScaleY = 4.7,
    },

    Selection = {
        BasePickRadiusPixels = 20,
        MaxPickRadiusPixels = 110,
        CapitalHoverPickRadiusPixels = 280,
        DragThresholdPixels = 6,
        DoubleClickSeconds = 0.32,
        DoubleClickMaxDistancePixels = 12,
        BracketPadding = 6,
        SelectedBracketPadding = 18,
        -- Role marker inside the upper-left corner, scaled with the HUD.
        -- 0 disables it. Inset is the gap from the bracket corner.
        RoleMarkerSize = 11,
        RoleMarkerInset = 3,
        -- gr.drawTargetingBrackets projects the real model bounds, so at long
        -- camera range the box collapses to a few pixels and the unit reads as
        -- unmarked. Reticles are clamped to this band instead, and are drawn
        -- with the same shape and colour language as the tactical-map icons so
        -- a contact looks the same in both views.
        ReticleMinPixels = 22,
        ReticleMaxPixels = 120,
        ReticleAlpha = 225,
        -- Reticles for contacts that are far outside the current camera focus
        -- are clamped onto the screen edge and get a hollow marker instead of a
        -- full bracket, so off-screen threats stay locatable.
        ReticleEdgeClampMargin = 26,
        -- Hover weapon range ring.
        ShowWeaponRange = true,
        WeaponRangeSegments = 48,
        WeaponRangeAlpha = 90,
        HullBarThickness = 5,
        HoverTrajectorySeconds = 6,
        HoverCapitalTrajectoryMaxSeconds = 90,
        HoverCapitalTrajectoryMinPixels = 32,
    },

    Pilot = {
        -- Upstream Lua does not expose the weapon Flak flag. Canonical retail
        -- classes are explicit; asset packs can register additional classes here.
        FlakWeapons = {['Standard Flak']=true,['Heavy Flak']=true,['Long Range Flak']=true},
        NativeWingExtensions = false, -- upstream proposal only; the released mod must run on stock FSO
        ToggleKey = "P",
        FOV = 0.92,
        DeathViewSeconds = 5,
        UseNativeHUDProxy = true,
        -- No class allow-list. Possession used to be gated on
        -- ClassPrefixes/CapitalClassPrefixes, which silently excluded every
        -- hull it did not name (user-made and mission-specific classes alike).
        -- IsPilotableShip now accepts any friendly non-station hull, and the
        -- turret-group layer detects capitals structurally in
        -- IsPilotableCapital, so no name list is consulted.
        TurretGroupPreviousKey = "[",
        TurretGroupNextKey = "]",
        -- Capital possession. A capital carries every weapon in turret
        -- subsystems, so ship:firePrimary()/fireSecondary() reach nothing. The
        -- pilot layer therefore drives the selected turret group directly.
        TurretGroupToggleKey = "\\",
        TurretSubsystemKey = "O",
        TurretSubsystemPreviousKey = "<",
        TurretSubsystemNextKey = ">",
        -- Manual fire is all-or-nothing on the active group by default. Set to
        -- false to require the player to hold the trigger through the native
        -- control rather than latching on the first tick.
        TurretFireLatches = true,
        -- Announce the manual-fire state in the pilot HUD.
        TurretFireStatusLine = "FIRE INPUT HELD // SHOTS NOT GUARANTEED",
    },

    Formation = {
        Spacing = 240,
        SpawnForwardClearance = 1100,
        InterShipClearance = 60,
        CommandAreaFraction = 0.90,
        MaxFormationWidthFraction = 1.10,
        VerticalCommandFraction = 0.35,
        -- Player-selectable shapes. "id" is stored on self.SelectedFormation and
        -- consumed by RTS:BuildSafeFormationDestinations. Every shape resolves to
        -- a (lateral, depth) slot for each unit relative to the move target and
        -- the group centroid; Spacing scales the shape, so the same solver feeds
        -- the player and the AI.
        Default = "LINE_ABREAST",
        Types = {
            { id = "LINE_ABREAST", label = "LINE",     desc = "One rank, perpendicular to facing." },
            { id = "COLUMN",       label = "COLUMN",   desc = "Single file; narrow passages." },
            { id = "TIGHT",        label = "TIGHT",    desc = "Close ranks; concentrated fire." },
            { id = "WEDGE",        label = "WEDGE",    desc = "Point forward; breaks fighter clusters." },
            { id = "ECHELON",      label = "ECHELON",  desc = "Diagonal ranks; broad coverage." },
            { id = "SCREEN",       label = "SCREEN",   desc = "Outward wedge around a slow core." },
        },
        -- Shape-specific multipliers applied on top of Spacing.
        Shapes = {
            LINE_ABREAST = { spacing = 1.00, depth = 0.85, taper = 0.00 },
            COLUMN       = { spacing = 0.70, depth = 1.55, taper = 0.00 },
            TIGHT        = { spacing = 0.55, depth = 0.80, taper = 0.00 },
            WEDGE        = { spacing = 0.90, depth = 1.25, taper = 0.55 },
            ECHELON      = { spacing = 0.95, depth = 1.10, taper = 0.30 },
            SCREEN       = { spacing = 0.90, depth = 1.20, taper = 0.45 },
        },
        -- When true the AI picks a formation per group from Config.AI.Formations
        -- instead of sending every unit to one shared point.
        AIUsesFormations = true,
    },

    -- Spawn placement for very large hulls. Capital/very-large ships used to
    -- inherit the fighter spawn frame, whose clearance grows with hull radius
    -- and whose retry fan can walk the ship across the whole map. This clamps
    -- the spawn ring and keeps big hulls near their own station.
    CapitalSpawn = {
        -- Radius as a multiple of the hull radius. A juggernaut sits at most
        -- this far out from its station, instead of front-clearance + up to
        -- 6x the (radius-scaled) spacing the strike-craft frame computes.
        MaxStationRadiusFactor = 2.4,
        -- Hard ceiling in metres regardless of hull size.
        MaxStationRadius = 9000,
        -- Never spawn closer than this to any hostile station. Without it a
        -- capital can materialise inside the enemy base ring and one-shot it.
        MinEnemyBaseSeparation = 12000,
        -- Arrival bearing: this fraction of the way toward the battlefield
        -- centre. 0 keeps the hull at the station, 1 aims at the midpoint.
        ForwardBias = 0.35,
    },

    Economy = {
        StartingCommandPoints = 1800,
        PassiveIncomePerSecond = 10,
        FleetCap = 64,
        StrikeWingSize = 4,
        WingBuildTimeMultiplier = 1.65,
    },

    -- Player production tiers unlock on the shared escalation schedule.
    ProductionClasses = {
        { class = "GTF Myrmidon", tier = 1, role = "fighter", count = 4 },
        { class = "GTF Perseus", tier = 1, role = "fighter", count = 4 },
        { class = "GTB Artemis", tier = 2, role = "bomber", count = 4 },
        { class = "GTB Boanerges", tier = 2, role = "bomber", count = 4 },
        { class = "GTF Ulysses", tier = 1, role = "fighter", count = 4 },
        { class = "GVF Serapis", tier = 1, role = "fighter", count = 4 },
        { class = "GTF Hercules", tier = 1, role = "fighter", count = 4 },
        { class = "GTF Loki", tier = 1, role = "fighter", count = 4 },
        { class = "GTF Hercules Mark II", tier = 2, role = "fighter", count = 4 },
        { class = "GTF Pegasus", tier = 2, role = "fighter", count = 4 },
        { class = "GTF Ares", tier = 2, role = "fighter", count = 4 },
        { class = "GTF Erinyes", tier = 2, role = "fighter", count = 4 },
        { class = "GTB Medusa", tier = 2, role = "bomber", count = 4 },
        { class = "GTB Ursa", tier = 2, role = "bomber", count = 4 },
        { class = "GTB Zeus", tier = 2, role = "bomber", count = 4 },
        { class = "GTC Aeolus", tier = 2, role = "escort" },
        { class = "GTC Leviathan", tier = 2, role = "escort" },
        { class = "GVC Mentu", tier = 2, role = "escort" },
        { class = "GTCv Deimos", tier = 3, role = "capital" },
        { class = "GVCv Sobek", tier = 3, role = "capital" },
        { class = "GTD Hecate", tier = 4, role = "heavy" },
        { class = "GTD Orion", tier = 4, role = "heavy" },
        { class = "GVD Hatshepsut", tier = 4, role = "heavy" },
        { class = "GTVA Colossus", tier = 5, role = "juggernaut" },
    },

    CostFormula = {
        Base = 50,
        HullShieldSqrt = 5.0,
        Radius = 2.5,
        ForwardSpeed = 0.6875,
        LargeRadius = 500,
        LargeMultiplier = 1.15,
        HugeRadius = 1200,
        HugeMultiplier = 1.30,
        MinimumCost = 50,
        CostRoundTo = 25,
        BuildSecondsPerCP = 0.025,
        GlobalMultiplier = 1.25,
        TierMultipliers = { 1.0, 1.50, 1.75, 2.00, 2.00 },
        -- Spawn telemetry shows fighters dominate hull counts. Add modest
        -- premiums to fighter/bomber packages while leaving scarce high-tier
        -- roles unchanged until their share warrants a price increase.
        RoleMultipliers = {
            fighter = 1.20,
            bomber = 1.10,
            escort = 1.00,
            capital = 1.00,
            heavy = 1.00,
            juggernaut = 0.14,
        },
        -- Class estimates feed replacement value/bounties. Sathanas purchases
        -- have an explicit floor below, shared by every producer.
        ClassMultipliers = {
            ["GTVA Colossus"] = 0.50, ["SJ Sathanas"] = 0.65, ["SD Lucifer"] = 1.25,
            -- Classic-only fleets lack cheap corvettes; reduce the radius
            -- premium on their first heavy hull. Shared class pricing also
            -- applies to modern rosters, replacement value and bounties.
            ["GTD Orion"] = 0.60, ["GVD Typhon"] = 0.60,
        },
        -- A tier-5 Sathanas must cost more than a destroyer. Retail pricing
        -- otherwise discounts it to 12,675 CP through the juggernaut formula.
        PurchaseCostFloor = { ["SJ Sathanas"] = 60000, ["GTVA Colossus"] = 40000, ["SD Lucifer"] = 35000, ["GTD Hades"] = 40000 },
        MinBuildSeconds = 6,
        MaxBuildSeconds = 180,
    },

    Bounties = {
        DefaultFractionOfCost = 0.24,
        Minimum = 25,
    },

    TacticalMap = {
        HalfExtent = 15000,
        Width = 410,
        Height = 238,
        Margin = 14,
        Top = 58,
        PickRadiusPixels = 10,
    },

    UI = {
        RightPanelWidth = 410,
        RightPanelGap = 12,
        ProductionMaxHeight = 350,
        ProductionMinHeight = 255,
        PolicyHeight = 196,
        QuickGroupHeight = 86,
        OptionsHeight = 48,
        SelectionHeight = 330,
        -- How long the "NEW UNITS READY" card stays after delivery or after pilot mode ends.
        NewUnitPopupSeconds = 5,
    },

    Policy = {
        -- HOLD issues no standing order at all, so with Auto Mode off the fleet
        -- only ever does what the player told it to. STANDOFF/ENGAGE/RETREAT are
        -- opt-in stances the player chooses deliberately.
        Default = "HOLD",
        -- Reissue only to units that have no manual player order.
        RefreshInterval = 20.0,
        RetreatDistance = 3200,
        RetreatSpread = 1100,
        Priority = 0.65,
        -- STANDOFF orbits the station. Without this the player's fleet never
        -- starts a fight by itself, so a fresh game is a stalemate while the AI
        -- escalates. Inside DefendRadius a threat to the station is intercepted;
        -- ENGAGE remains the "go find them" policy.
        DefendRadius = 6500,
    },

    Setup = {
        DefaultDifficulty = 2,
        DefaultFactions = 2,
        DefaultEconomy = 2,
        DefaultAutoMode = false,
        DefaultAsteroids = false,
        DefaultSentries = false,
        DefaultBaseDistance = 1,
        DefaultBaseLayout = 1,
        BaseLayouts = {
            {id="CIRCLE",name="CIRCLE",desc="One ring with evenly spaced stations."},
            {id="STAR",name="STAR",desc="Alternating outer and inner stations."},
            {id="MULTI_CIRCLE",name="MULTIPLE CIRCLES",desc="Two or three separated clusters of stations."},
        },
        BaseDistances = {
            { name = "CLOSE", distance = 12000 },
            { name = "STANDARD", distance = 18000 },
            { name = "WIDE", distance = 24000 },
            { name = "EPIC", distance = 30000 },
        },
        Difficulties = {
            { name = "EASY", aiIncome = 0.82, aiBuildSpeed = 0.90, aiAggression = 0.85 },
            { name = "NORMAL", aiIncome = 1.00, aiBuildSpeed = 1.00, aiAggression = 1.00 },
            { name = "HARD", aiIncome = 1.14, aiBuildSpeed = 1.10, aiAggression = 1.10 },
            { name = "BRUTAL", aiIncome = 1.32, aiBuildSpeed = 1.22, aiAggression = 1.22 },
        },
        Economies = {
            { name = "SCARCE", startCP = 1200, income = 7 },
            { name = "STANDARD", startCP = 1800, income = 10 },
            { name = "RICH", startCP = 2600, income = 14 },
        },
    },

    Escalation = {
        tierUnlocks = { 0, 240, 570, 1050, 1380 },
        playerIncomeScale = 1.10, aiIncomeScale = 1.12,
        buildTimeScale = 0.85, stationHullScale = 0.85,
        threeFactionStationScale = 0.78,
    },

    -- Station upgrades, placeable sentries and faction command abilities.
    -- Sentry classes are each faction's retail sentry guns.
    Station = {
        Sentries = {
            Cap = 0,                -- no sentry defenses until the station is upgraded
            CapBonus = 2,           -- each Defenses level and Command L2 add two slots
            ControlRadius = 4000,   -- sentries only go this close to the owning station
            RadiusBonus = 2000,     -- Command L2
            MinSpacing = 600,
            BuildSeconds = 20,
            DeploySafeRadius = 1800,
            SellRefund = 0.5,
            HullBonus = 1.5,        -- Defenses L2
            -- Legacy beam platforms use this interval; cannon/laser platforms
            -- slew toward nearby enemies once per mission second.
            RangeScanSeconds = 1,
            ScreenWeapon = "RTS Sentry Interceptor",
            -- Every platform has two turrets, each with a close-defense laser
            -- and an anti-capital cannon. Tiers buy durability, not new weapons.
            -- fs2rts-cannon-wep.tbm patches the retail Vasudan Flux Cannon to
            -- 11 km. Retail ships.tbl has no other hull mounting this weapon;
            -- other asset packs must be checked separately. Keep these fallback
            -- ranges in sync with that table. The HUD reads native weapon reach.
            -- The cannon retains its retail capital-target flags and slow shell
            -- speed; the separate laser handles nearby strike craft.
            Classes = {
                BLUE = {
                    { class = "GTSG Watchdog", tier = 1, cost = 250,  hull = 600,  role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                    { class = "GTSG Watchdog", tier = 2, cost = 375,  hull = 900,  role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                    { class = "GTSG Watchdog", tier = 3, cost = 500,  hull = 1200, role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                    { class = "GTSG Watchdog", tier = 4, cost = 1250, hull = 3000, role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                },
                GOLD = {
                    { class = "GVSG Ankh",    tier = 1, cost = 250,  hull = 600,  role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                    { class = "GVSG Ankh",    tier = 2, cost = 375,  hull = 900,  role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                    { class = "GVSG Ankh",    tier = 3, cost = 500,  hull = 1200, role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                    { class = "GVSG Ankh",    tier = 4, cost = 1250, hull = 3000, role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                },
                RED = {
                    { class = "SSG Trident",  tier = 1, cost = 250,  hull = 600,  role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                    { class = "SSG Trident",  tier = 2, cost = 375,  hull = 900,  role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                    { class = "SSG Trident",  tier = 3, cost = 500,  hull = 1200, role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                    { class = "SSG Trident",  tier = 4, cost = 1250, hull = 3000, role = "cannon", weapon = "Vasudan Flux Cannon", range = 11000 },
                },
            },
        },
        -- Each track has three levels; level N needs escalation tier Tiers[N].
        Tracks = {
armor     = { label = "ARMOR",     costs = { 625, 1250, 2250 }, seconds = { 30, 60, 90 }, tiers = { 1, 2, 3 },
        -- Passive station repair is available from the start; Armor 2 doubles
        -- its rate. Scars remain permanent at every level.
desc = { "+20% station hull", "+40% hull, double quiet repair rate", "+60% hull" } },
            defenses  = { label = "DEFENSES",  costs = { 750, 1500, 2750 }, seconds = { 30, 60, 90 }, tiers = { 1, 2, 5 },
                          desc = { "First base guns; +2 sentry slots", "Remaining guns; +2 slots, sentries +50% hull", "+2 slots; base beams, all turrets fire 25% faster" } },
logistics = { label = "LOGISTICS", costs = { 625, 1400, 4200 }, seconds = { 30, 60, 150 }, tiers = { 1, 2, 3 },
desc = { "+15% CP income", "Builds 20% faster", "+30% CP income, second build lane" } },
            command   = { label = "COMMAND",   costs = { 875, 1750, 3250 }, seconds = { 30, 60, 90 }, tiers = { 1, 2, 3 },
                          desc = { "+8 fleet cap", "Sentry radius +2 km, sentry cap +2", "Unlocks faction ability" } },
        },
        ArmorHull = { 1.0, 1.2, 1.4, 1.6 },
        ArmorRepairPerSecond = 0.0005,  -- Armor L2+: 5%; below L2 stations repair at half rate
        ArmorRepairDelay = 30,          -- follow-up attacks have time to exploit damage
        RecoverableDamageFraction = .60, -- remaining hull damage permanently lowers the station repair ceiling
        FleetService = {
            TickSeconds = 1, Slots = 4, StandOff = 1100, ArrivalRadius = 700,
            QuietSeconds = 8, MinimumRecoverySeconds = 20, RetrySeconds = 30,
    -- A docked hull whose pad stays inside a hostile's DangerRadius can never
    -- satisfy the `not alive(threat)` finish test, so it sat in UNDER_FIRE for
    -- the whole mission: never repaired, never released, and reported as
    -- mode=IDLE the entire time because a ship in FleetServices holds no
    -- AIOrderState. The station-under-attack abort only covers
    -- REPAIR_REARM/WAIT_CP/QUEUED, so it never caught this case. Measured over
    -- the sentryfix-20261001 batch: 216-254 service entries per match were
    -- still open at run end, and 12-28% of all service ship-time was
    -- UNDER_FIRE against 0.8-1.4% actually spent repairing. A hull that cannot
    -- repair should return to the fight and try again, not park forever.
    MaxUnderFireSeconds = 240,
            HullPerSecond = .004, AmmoPerSecond = .04,
            HullCostFraction = .35, AmmoCostFraction = .12,
            SubsystemPerSecond = .01, SubsystemCostFraction = .15,
            -- Free field repair of destroyed subsystems: slow, only after this long untouched.
            RegenQuietSeconds = 20, RegenPerSecond = .005,
            ReturnHull = .40, ReturnAmmo = .15, ReadyHull = .90, ReadyAmmo = 1,
    -- Floor a committed strike presses to while inside its own reach. Must stay
    -- BELOW CriticalHull (0.22) so self-preservation, not this, is the floor
    -- that eventually pulls a hull out of the assault.
    AssaultHullFloor = .14,
            CriticalHull = .22, DangerRadius = 4500, DisadvantageRatio = 2,
            AvoidFightRatio = 4,
            DangerSeconds = 6,
            FighterReturnAmmo = .05, CommittedStrikeReturnAmmo = .02,
        },
        IncomeMultiplier = { 1.0, 1.15, 1.15, 1.30 },
        BuildTimeMultiplier = { 1.0, 1.0, 0.8, 0.8 },
        FleetCapBonus = 8,
        DefenseFireRate = 1.25,
        Ability = {
            Cooldown = 150,
            -- PROPOSED cost. The strike was free, so a misclick on empty space
            -- cost only the 150 s cooldown; 750 sits between a T1 sentry (375)
            -- and a T2 sentry (875) and is well under COMMAND L3's own 3250.
            -- Balance call: retune freely, QueueOrbitalStrike reads a.cost.
            BLUE = { kind="strike", name = "ORBITAL STRIKE", cost = 750, delay = 5, radius = 900, innerRadius = 250, damage = 1200, range = 12000 },
            GOLD = { kind="reinforcement", name = "REINFORCEMENT JUMP", class = "GVCv Sobek", tier=3, count=1, cost = 6000, cooldown = 300 },
            RED  = { kind="surge", roles={fighter=true,bomber=true}, name = "SWARM SURGE", cost=750, radius = 5000, speedMultiplier = 1.5, seconds = 20 },
        },
        AI = {
            ThinkSeconds = 8,
            ReserveCP = 400,
            -- The station AI holds its defense ring and the rest of the upgrade
            -- tree back until it has an opening fleet, so the new CP sink does
            -- not remove early attack pressure. This was a hard count with no
            -- recovery: a faction that never held OpeningFleetThreshold hulls
            -- alive was locked out of sentries and out of COMMAND L3 (the tier
            -- its ability keys off) for the rest of the match. The threshold
            -- opens unconditionally after OpeningFleetSeconds of scenario time
            -- so progression can never be permanently denied.
            -- PROPOSED values; both were hardcoded (8 hulls, never).
            OpeningFleetThreshold = 8,
            OpeningFleetSeconds = 150,
            -- PARTIAL MITIGATION ONLY, and inert below ~1500.
            -- productionReserve is bankTarget - the full price of the role
            -- package being saved for - so without a cap a 375 CP sentry needed
            -- ~14,200 CP in the bank at tier 5. This clips that.
            -- IT IS NOT THE SENTRY FIX. reserve is max(ReserveCP=400,
            -- fleetReserve, productionReserve) and fleetReserve alone is
            -- StrikeWingSize 4 x 375 = 1500, so the floor is already 1500 and
            -- this cap only clips productionReserve down to it. Lowering this
            -- below 1500 achieves nothing; fleetReserve re-imposes the floor.
            -- The real cause of zero sentry builds was the producer saving-clock
            -- livelock (see AI.PreserveSavingClockWhileFielding): the bank
            -- never accumulated past 1300-2494 CP, so the 375+1500 hurdle was
            -- unreachable regardless of this cap. See ai_production.lua:264.
            StationReserveCap = 1500,
            -- CAPITAL-AWARE STATION GATE. Ships OFF: false = current shipped
            -- behaviour, byte for byte, until an A/B proves it.
            --
            -- The defect it addresses. productionReserve is the producer's whole
            -- bankTarget (fs2rts_ai_production.lua:181), the full price of the
            -- role package being saved for, and the min() above DISCARDS it
            -- whenever it exceeds this cap. So the reserve documented at
            -- fs2rts_station.lua as existing "so the FLEET producer does not
            -- undercut its own saving goal" protects nothing: inside a 600 s
            -- capital save window the station still buys any upgrade at
            -- cp >= cost + 1500, ~75 times per window, against a bank climbing
            -- 180-230 CP per think. Measured per faction per 3000 s match:
            -- upgrades 59,100-77,450 CP (29-38% of income) against a bank that
            -- peaked at 4,056-5,859 CP and capital targets of 7,700-31,275,
            -- with 0 capital/heavy/juggernaut hulls built in 4 of 4 headless
            -- matches. The 21,225 CP upgrade tree is ~47% of a faction's
            -- lifetime income, and it is being paid out of the capital bank.
            --
            -- When true, base UPGRADES are deferred while the producer is
            -- actively saving (savingRole set, nothing queued, under fleet cap)
            -- for a role the bank cannot yet afford. SENTRIES ARE NOT deferred:
            -- they are 3-13% of income against the upgrade tree's 29-38%, and
            -- while the producer goes dark to save, the ring is the base's only
            -- defence. StationReserveCap above stays load-bearing and untouched.
            --
            -- Escape, twice over, so it cannot hang: the condition lifts the
            -- moment the bank can afford the role (or the producer buys it, or
            -- an emergency clears savingRole), AND each contiguous deferral is
            -- capped at CapitalAwareInvestmentMaxSeconds, defaulting to the
            -- producer's own longest save window (AI.HeavyCapitalSavingSeconds
            -- and siblings, 900 at tier 4). That is how long the fleet producer
            -- is itself willing to wait, so the base never waits longer than the
            -- fleet that is outbidding it.
            CapitalAwareInvestment = true,
            -- Escape bound in seconds. nil = derive the producer's longest
            -- declared save window. Set to 0 to disable deferral entirely
            -- (fail-open), or to a positive number to hold the base back longer.
            CapitalAwareInvestmentMaxSeconds = nil,
        },
    },

    ThirdFaction = {
        StationPosition = { x = 0, y = 0, z = 11500 },
        -- No combat units are pre-spawned. Gold uses the same production director
        -- as the other factions once the scenario begins.
    },

    -- AI uses CP, build time, fleet caps and the same runtime ship cost map as
    -- the player. Scripted legacy waves are disabled by default.
    AI = {
        Enabled = true,
        -- Per-mission formation choice per strategic role. RTS:ChooseAIFormation
        -- reads this table by the group's role so a fighter screen arrives in
        -- line, an armour column queues single file, and an assault wing closes
        -- to a wedge instead of every unit stacking on one point.
        Formations = {
            ASSAULT = "WEDGE",
            SCREEN = "LINE_ABREAST",
            DEFEND = "LINE_ABREAST",
            BOMBER = "COLUMN",
            ESCORT = "WEDGE",
            CAPITAL = "SCREEN",
            RETREAT = "COLUMN",
            LURE = "LINE_ABREAST",
            REGROUP = "TIGHT",
        },
        DefaultFormation = "LINE_ABREAST",
        -- Groups whose discs come within this distance are reported as
        -- intersecting in the COHESION telemetry record.
        CohesionRadius = 3000,
        -- Seconds between COHESION samples per faction. The planner ticks far
        -- faster than a heat map needs, and sampling every tick roughly tripled
        -- the frame cost of a headless run.
        CohesionSampleSeconds = 2,
        -- Seconds between CONTEST samples: how each faction's groups are
        -- allocated, and whether any assigned group has stopped closing on its
        -- objective. This is the record that answers "why did this side lose".
        ContestSampleSeconds = 10,
        -- Requires the local experimental FSO hook build; keep it disabled for
        -- Knossos releases built against stock FSO.
        ExperimentalDamageTelemetry = false,
        -- Per-unit telemetry performs a local force scan and writes one record
        -- per observed ship at each summary interval. Enable while diagnosing
        -- individual orders; faction-level behavior summaries remain available.
        DetailedUnitTelemetry = false,
        -- Candidate score breakdowns are high-volume diagnostics; enable for AI tuning.
        DetailedDecisionTelemetry = false,
        -- Cheap TARGETED sampling of the same per-candidate list, independent of
        -- DetailedDecisionTelemetry above and without changing its meaning.
        -- DetailedDecisionTelemetry was measured at ~200 MB/match (~6x telemetry
        -- volume), which is why the ranking behind every decision is unrecorded:
        -- 0 of 106 staged telemetry files carried DECISION.candidates while
        -- DECISION.results was present in all 47,626 records.
        --
        -- This records the candidate ranking for heavy/capital/juggernaut groups
        -- only, on a 1-in-N sample. Heavy groups are where target choice is worth
        -- explaining and they are a small share of DECISION records (6.9% of
        -- 47,626 in capgate-20261001; 0% in runs that never fielded one), so the
        -- combination is what makes this affordable.
        --
        -- Default OFF: the flag adds a per-decision sample counter and nothing
        -- else when disabled.
        SampledHeavyDecisionTelemetry = false,
        -- 1-in-N heavy-group decisions that carry the candidate list. 1 means
        -- every heavy decision, which reproduces the DetailedDecisionTelemetry
        -- cost for those groups alone. 40 is the default sampling rate.
        SampledHeavyDecisionSampleEvery = 40,
        -- Full JSONL AI event traces add serialization and periodic disk flushes.
        -- Keep disabled during normal play; enable for experiment collection.
        TraceFileEnabled = false,
        -- Move first-use ship model loads into setup to avoid combat-time hitches.
        PrewarmRosterModels = true,
        DisableMissionPause = true,
        UseLegacyWaves = false,
        ThinkInterval = 8.0,
        Operations = { Enabled = true, AssembleSeconds = 45, RallyRadius = 2400, AttackSeconds = 480, RegroupSeconds = 35,
            -- How long home threat must stay low before an operation is released
            -- early as a counterattack. Without a dwell, a single 2 s tick in
            -- which a player wing left the threat bubble recalled every front in
            -- the faction straight out of assembly.
            -- 0 = release on the first tick where home threat collapses, which is
            -- the tested doctrine (a defeated raid recalls the assault at once).
            -- Raise it to require a dwell, which stops a player wing briefly
            -- crossing the threat bubble from releasing every front in the
            -- faction straight out of assembly.
            CounterattackQuietSeconds = 0 },
        MaxProductionSavingSeconds = 120,
        -- While banking for the desired role, go dark for the window instead of
        -- fielding the cheapest affordable non-desired hull.
        --
        -- This was true from an earlier round, on the belief that a faction
        -- sitting at SAVING_FOR_DESIRED_ROLE with affordable options was
        -- malfunctioning. That reading was wrong, and it cost the capital tier.
        -- The "blackouts" that motivated the flip were the AI saving CORRECTLY.
        -- Measured in session-fix-20260930 (4 matches, real engine), each
        -- flagged window is the bank RISING toward a capital target:
        --   BLUE  586 s no purchase, bank  1,286 -> 11,496 CP, 20 options affordable
        --   GOLD  586 s no purchase, bank  2,104 -> 13,597 CP, 15 options affordable
        --   RED   530 s no purchase, bank  2,108 -> 12,606 CP, 15 options affordable
        -- and that batch built 12 capitals (3 per match). The earlier comment
        -- here claimed "GOLD wanted a 13825 CP Colossus ... and simply never
        -- built anything", which the class histogram contradicts.
        --
        -- With this true, every purchase restarts the save window, so the window
        -- never ages into savingFallback, the alongside hull keeps draining the
        -- bank, and the ceiling collapses from ~13,000 CP to 1,300-2,300 CP:
        --   ZERO capital, heavy or juggernaut builds in 4 of 4 matches
        --   sentries 67 -> 7, losses_units 67 -> 220-270
        -- RED degenerated to tierHistogram={1: 132} - 132 builds, all tier 1.
        -- Neither PreserveSavingClockWhileFielding nor BoundBankTarget rescues
        -- it: both were A/B'd and both leave capital production at 0, because
        -- the drain is the policy of fielding a hull during saving, not the
        -- clock or the target. See docs/DEVELOPMENT.md.
        FieldCheapHullWhileSaving = false,
        -- ChooseAIBuild clears state.savingSince/state.savingRole after EVERY
        -- purchase. When FieldCheapHullWhileSaving is also on, that purchase is
        -- the cheap non-desired hull the save window deliberately fields
        -- ALONGSIDE the goal - so the goal is still unmet, and wiping the clock
        -- restarts the whole window. The window then never elapses,
        -- savingFallback never runs, and the producer buys a ~1500 CP fighter
        -- wing on every think forever.
        -- Headless evidence, batch sentrybudget-a (4 matches, real engine,
        -- 3000 s each): desiredRole=capital in 2346 of 3792 build decisions and
        -- bankTarget median 8600 CP, against a per-faction CP bank that peaked
        -- at 1300-2494 CP. ZERO capital builds in 4 of 4 matches.
        -- Baseline session-fix-20260930 built 1 capital per faction per match.
        -- On by default: false = the livelock, for A/B.
        PreserveSavingClockWhileFielding = false,
        -- Bound the saving TARGET when it is unreachable, rather than changing
        -- what the producer does while saving.
        -- ChooseAIBuild aims bankTarget at the newest tier's cheapest capital
        -- whenever a current-tier desired option exists (12675 CP at tier 4,
        -- 13825 at tier 5, up to 31275 for a juggernaut), while the measured
        -- per-faction CP bank peaks near 2300 CP and the faction spends more CP
        -- than it earns. The goal is therefore never met, the save window never
        -- ends in a purchase, and 0 capital/heavy/juggernaut hulls are built in 4
        -- of 4 headless matches (baseline: 1 capital per faction per match).
        -- When true, an unreachable newest-tier target falls back to the cheapest
        -- desired-role hull the faction can bank inside one saving window.
        -- Anchored to a real roster price, deliberately NOT cp-relative: a bound
        -- of the form cp + rate * window recomputes as cp grows and would outrun
        -- the bank every think, which is the same livelock by another route.
        -- On by default: false = current shipped behaviour.
        BoundBankTarget = true,
        CapitalSavingSeconds = 600,
        HeavyCapitalSavingSeconds = 900,
        JuggernautSavingSeconds = 600,
        StrategicOrderInterval = 2.0,
        FleetCap = 64,
        StationDefenseRadius = 5600,
        LocalEngageRadius = 3600,
        StartingCPScale = 0.92,
        IncomeScale = 0.95,
        MaxQueue = 1,
        TierBias = 3.0,
        SmallCraftMinimumRatio = 0.30,
        CurrentTierWeight = 5.0,
        DeficitRoleBias = 5.0,
        CompositionTargets = {
            [1] = { fighter = 1.00, bomber = 0.00, escort = 0.00, capital = 0.00 },
            [2] = { fighter = 0.42, bomber = 0.20, escort = 0.38, capital = 0.00 },
            [3] = { fighter = 0.28, bomber = 0.18, escort = 0.20, capital = 0.34 },
            [4] = { fighter = 0.20, bomber = 0.15, escort = 0.15, capital = 0.50 },
            [5] = { fighter = 0.18, bomber = 0.12, escort = 0.12, capital = 0.58 },
        },
        -- Late-game income ramp. Was 0.65 with a per-tier coefficient of 0.20, so
    -- the AI ended a match at ~2.45x income against the player's ~1.60x. Blue
    -- led combatant value in 0% of samples over 32 headless matches and never
    -- took the lead once. The AI is now converged onto the player's curve; the
    -- Normal difficulty follows comparable player and opponent income curves.
    LateGameIncomeRamp = 0.20,
    IncomeRampPerTier = 0.10,
        Doctrine = {
            PrimaryFrontShare = 0.70,
            ScreenReserveFraction = 0.38,
            DefenseResponseRatio = 1.15,
            MaxDefenseFleetFraction = 0.50,
            -- Active base fire overrides assault commitment; recall only the
            -- response value needed, up to the available fleet in an emergency.
            EmergencyDefenseFleetFraction = 0.70, -- critical hull may still recall the full fleet
            DefenderRetentionSeconds = 10,
            DefenseTargetCommitmentSeconds = 18,
            DefenderReleaseDistance = 1500,
            BeamHitMemorySeconds = 6,
            ThreatRadius = 6500,
            AssaultCommitSeconds = 25,
            AssaultCommitDistance = 5200,
            -- A committed base strike becomes a real operating regime, judged
            -- GEOMETRICALLY rather than by a timer. The existing 25 s commitment
            -- covers only a fraction of a 15 km transit, so it was never the
            -- thing that decided anything. Inside the range where a hull's own
            -- beams reach the station, retreating throws that damage away, so
            -- the survival thresholds relax and the two outmatched reasons are
            -- suppressed. Outside that range nothing changes.
            -- AssaultHullFloor is deliberately BELOW Station.FleetService
            -- CriticalHull (0.22), so the committed behaviour is "press on until
            -- 22% hull, then the self-preservation reflex pulls it" - a legible
            -- single-hull beat rather than a squad wipe. SELF_PRESERVATION and
            -- SYSTEMS_DAMAGED are never overridden.
            AssaultHoldEnabled = true,
            AssaultHoldDistance = 8000,
            -- Bounded close-in escort screen on the strike. Escorts were never
            -- assault-reserved at all (assaultRole is capital/heavy/juggernaut/
            -- bomber only), so the bulk of the beam DPS simply had no base
            -- mission to accept.
            AssaultEscortWings = 1,
            -- Keep a real assault element moving toward the selected enemy
            -- base. Local interception may still override this reserve at
            -- hard-contact range, or when the station is in an emergency.
            AssaultFleetFraction = 0.30,
            HardEngageRadius = 1800,
            -- Bombers preserve their strategic strike through routine fighter
            -- contact, but respond when a nearby hostile has actually targeted
            -- them or entered this close self-defense envelope.
            BomberSelfDefenseRadius = 1200,
            -- A target lock at 3600 made bombers peel off the base strike
            -- whenever a fighter merely selected them at midfield range.
            -- Let their screen handle those contacts; bombers respond to a
            -- direct pursuer only inside the close-defense band.
            BomberTargetedResponseRadius = 1200,
            -- Commit at most one spare bomber wing against a mobile capital
            -- targeting this base. Non-immediate responses preserve one
            -- bomber wing for the main strike.
            CapitalSuppressionEnabled = true,
            CapitalSuppressionBomberWings = 1,
            FocusEvidenceSeconds = 8,
            -- A single inexpensive fighter wing may make a visible probe while
            -- the bomber/capital strike stays committed. Under local pressure it
            -- withdraws toward friendly defenses to bait and trap pursuers.
            TauntEnabled = true,
            TauntCooldownSeconds = 90,
            TauntCommitSeconds = 18,
            TauntMinHullFraction = 0.75,
            -- Defender fighters often stage around midfield, outside the
            -- local base-threat radius. Search farther for a real screen
            -- target without widening threat scoring or bomber response.
            TauntTargetRadius = 11000,
            LureForceRatio = 1.30,
            LureDurationSeconds = 18,
            LurePursuitRadius = 1800,
            -- How often a live pursuit re-anchors its move goal. A pursuit
            -- order terminates on arrival (only ORDER_WAYPOINTS_ONCE raises
            -- $On Waypoints Done), so without this cadence the capital
            -- reaches the stale intercept point once and then sits there
            -- holding nothing. Read at fs2rts_strategy/orders.lua:40 (RefreshAIPursuit),
            -- :299 (RefreshEngagePursuit) and :330 (UpdateAIPursuitGoals gate).
            -- Matches the PURSUIT_REFRESH_SECONDS fallback those sites carry.
            PursuitRefreshInterval = 1.5,
            NativeTargetRepairInterval = 6,
            LocalTargetRetentionSeconds = 8,
            RetargetImprovementRatio = 0.25,
            CriticalStationHullFraction = 0.35,
            MinimumCommitmentSeconds = 8,
            ObjectiveSwitchCost = 25,
            LocalStrengthRadius = 4500,
            -- Test committing a planned assault at 65% of nearby defense value;
            -- the previous parity gate left several fronts stalled all match.
            AssaultStrengthRatio = 0.65,
            NoProgressSeconds = 40,
            RegroupDistance = 2600,
            RetreatHullFraction = .22,
            -- A wing breaks off as a unit, so the break-off trigger counts
            -- hulls at or below RetreatHullFraction instead of taking the
            -- group-wide minimum. With a plain minimum one mauled escort
            -- recalled every healthy ship in the wing, which is the opposite
            -- of a damage-based reaction. A lone hull (1 of 1) still breaks
            -- off, and a majority-hurt wing still does. Individual ships below
            -- the fraction are handled separately by fleet service
            -- (CriticalHull in fs2rts_service.lua), which pulls them out
            -- without disbanding the rest of the formation.
            RetreatDamagedShipFraction = 0.75,
            RetreatCommitSeconds = 25,
            TelemetrySummarySeconds = 30,

            -- ASSAULT GROUP POOLING. OFF = current shipped behaviour, byte for
            -- byte, until an A/B proves it.
            --
            -- The defect it addresses. A group's identity is fixed at
            -- fs2rts_strategy/weapons.lua:151 as (logical wing id or ship signature) ..
            -- role, and it is rebuilt from scratch every strategic tick from
            -- wing membership. Nothing ever merges two groups. So the number of
            -- simultaneous groups is exactly the number of surviving wings plus
            -- unwinged hulls, and it rises mechanically with the purchase rate:
            -- measured over 4 headless matches, sentryfix-20261001 ran 4.0
            -- simultaneous groups per faction at group_value_hhi 0.420 while
            -- session-fix-20260930 held 2.1 at 0.677. Because CommitAIGroup
            -- issues an independent order per group, four half-strength wings
            -- produce four independent decisions, four times the OBJECTIVE
            -- churn, and no single commitment large enough to matter.
            --
            -- When true, groups that share a role AND a mission AND a primary
            -- front AND are already co-located (within PoolAssaultGroupsRadius,
            -- so a wing never gets ordered across the map to join a sibling) are
            -- merged into one group before planning continues. Distinct
            -- missions, distinct fronts, distant wings, and any group with its
            -- own target/defending/luring/feint/operation state are left alone,
            -- so the operations layer, the taunt probe, the preemption
            -- dispatch and the lure machinery all still see one group per
            -- independent intent.
            PoolAssaultGroupsEnabled = false,
            PoolAssaultGroupsRadius = 3000,

            -- OPERATION MEMBERSHIP COMMITMENT. OFF = current shipped behaviour.
            --
            -- ApplyAIOperationOrder (fs2rts_operations.lua:257) sets
            -- context.locked=true for every operation member it does not
            -- release, and CommitAIGroup's retention gate
            -- (fs2rts_ai_planning/battle_events.lua:8) requires `not context.locked`. So for
            -- the 67% of decisions that are operation members the
            -- MinimumCommitmentSeconds floor above never runs at all: the
            -- operation re-derives a target from ChooseAIOperationTarget every
            -- StrategicOrderInterval (12 s) and the group's target flips with
            -- whatever defender it last scored highest. That is the mechanism
            -- behind 23,686 order transitions at 15.3 s/order in the broken
            -- batch against 6,495 at 22.8 s in the baseline.
            --
            -- When true, an operation member whose mission is UNCHANGED keeps
            -- its current target for OperationCommitmentSeconds instead of
            -- being re-chosen. A mission change (ASSEMBLE -> APPROACH ->
            -- ENGAGE -> WITHDRAW, a reserve release, a flank pin, a withdraw)
            -- is never delayed, so the operation phase machine keeps its
            -- cadence; only the within-phase defender re-pick is damped.
            OperationCommitmentEnabled = false,
            OperationCommitmentSeconds = 24,

            -- HEAVY ASSAULT OBJECTIVE LOCK. BOTH LOCKS OFF = current shipped
            -- behaviour, byte for byte, until an A/B proves otherwise.
            --
            -- The defect it addresses, measured on capgate-20261001 (4 matches,
            -- 2906 heavy PRIMARY decisions, DECISION records):
            --   target kind   station 476 (16.4%) | sentry 1301 (44.8%)
            --                 escort 880 (30.3%) | capital 164 (5.6%) | jugg 85 (2.9%)
            --   reason        OPERATION_ROLE_TARGET 2682 (92%), BREAKTHROUGH_EXPLOIT 120
            --   localThreatSignature == target   0 of 2906
            --   hardLocalThreat == true         0 of 2906
            --
            -- The heavy group is never choosing. ChooseAIOperationTarget
            -- (fs2rts_operations.lua:192) scores a static defence at rank 3 for
            -- a strike group and the objective of the operation itself at rank
            -- 1, then compares rank*100000 minus distance minus covered, so the
            -- 200,000 gap makes the objective unreachable: every candidate is
            -- within station radius + 6000 m, so distance can never pay for two
            -- ranks. It is called from fs2rts_strategy/strategic_plan.lua:468, AFTER every
            -- local-threat decision, and it returns with context.locked=true,
            -- which is why the local threat never appears in the record. It was
            -- never consulted, not merely outvoted.
            --
            -- ApplyAssaultObjectiveLock (fs2rts_strategy.lua) vetoes the value
            -- operations returns for capital/heavy/juggernaut groups whose
            -- operation objective is a command station, so the station stays the
            -- objective unless the diverted hull is a genuine obstacle. Two
            -- independent flags, because the two buckets are different problems
            -- and neither has an A/B behind it yet.
            --
            -- Static-defence lock: sentries and other fixed defences.
            -- Ships OFF, and the tests and the killcheck guard pin it OFF:
            -- the clause below is narrow enough to be safe by construction, but
            -- no batch has been run with it on, and the 16.4%-on-station target
            -- mix it would change is the reference every later A/B is read
            -- against.
            AssaultStaticDefenceLock = false,
            -- Distance bound on the reactive test, which requires that the
            -- diverted hull IS the local threat of this group AND that the
            -- nearest member is within this many metres of it. 3600 is
            -- AI.LocalEngageRadius, the radius that produces localThreat at all
            -- (ChooseAILocalThreat), so the bound is tight by construction and
            -- still bites on the one path that can push a local threat outward:
            -- the INTERCEPT retention swap at fs2rts_strategy/strategic_plan.lua:86-90,
            -- which re-binds localThreat to a previous target that may be far
            -- outside the radius.
            AssaultStaticDefenceThreatDistance = 3600,
            -- Corridor half-width, in metres, for the clause "it lies between us
            -- and the station". 0 DISABLES the clause, which is the default
            -- because the clause is measurably vacuous in this game: over the
            -- 1301 sentry diversions the perpendicular offset from the
            -- centroid->station axis is p50 689 m and p90 2008 m, so a 3000 m
            -- corridor admits 97.5% of them and a 5000 m corridor admits 100%.
            -- That is structural, not a tuning accident: sentry placement is
            -- capped at station radius + 4 km (README), so for an attacker
            -- 11-12 km out every sentry sits within a few km of the axis by
            -- construction. No width that still admits a sentry genuinely
            -- blocking the lane can exclude one that is not.
            AssaultStaticDefenceCorridorWidth = 0,
            -- Mobile-threat lock: enemy escorts, capitals, juggernauts, fighters
            -- and bombers. Separate flag, default OFF pending evidence. This is
            -- the 30.3% escort bucket, and it is the same rank rule rather than
            -- a separate defect: IsCapitalTarget is true for role escort
            -- (fs2rts_factions/faction_setup.lua:97), so an enemy escort is a rank-1 capital
            -- target that beats the station on distance alone across an 18 km
            -- map. 74.7% of those also satisfy a 3000 m corridor, so the same
            -- local-threat-only rule is the only one that can bite here too.
            AssaultMobileThreatLock = false,
            AssaultMobileThreatDistance = 3600,
            AssaultMobileThreatCorridorWidth = 0,
        },
        BlueRoster = {
            { class = "GTF Apollo", tier = 1, role = "fighter", weight = 3 },
            { class = "GTF Valkyrie", tier = 2, role = "fighter", weight = 2 },
            { class = "GTB Athena", tier = 1, role = "bomber", weight = 2 },
            { class = "GTF Myrmidon", tier = 1, role = "fighter", weight = 5 },
            { class = "GTF Perseus", tier = 1, role = "fighter", weight = 4 },
            { class = "GTB Artemis", tier = 2, role = "bomber", weight = 4 },
            { class = "GTB Boanerges", tier = 2, role = "bomber", weight = 3 },
            { class = "GTF Ulysses", tier = 1, role = "fighter", weight = 3 },
            { class = "GVF Serapis", tier = 1, role = "fighter", weight = 1 },
            { class = "GTF Hercules", tier = 1, role = "fighter", weight = 3 },
            { class = "GTF Loki", tier = 1, role = "fighter", weight = 2 },
            { class = "GTF Hercules Mark II", tier = 2, role = "fighter", weight = 3 },
            { class = "GTF Pegasus", tier = 2, role = "fighter", weight = 2 },
            { class = "GTF Ares", tier = 2, role = "fighter", weight = 2 },
            { class = "GTF Erinyes", tier = 2, role = "fighter", weight = 2 },
            { class = "GTB Medusa", tier = 2, role = "bomber", weight = 3 },
            { class = "GTB Ursa", tier = 2, role = "bomber", weight = 3 },
            { class = "GTB Zeus", tier = 2, role = "bomber", weight = 2 },
            -- Upstream strips retail's obsolete @ demo prefix from Fenris.
            { class = "GTC Fenris", tier = 2, role = "escort", weight = 3 },
            { class = "GTC Aeolus", tier = 2, role = "escort", weight = 4 },
            { class = "GTC Leviathan", tier = 2, role = "escort", weight = 2 },
            { class = "GTCv Deimos", tier = 3, role = "capital", weight = 5 },
            { class = "GTD Hecate", tier = 4, role = "heavy", weight = 4 },
            { class = "GTD Orion", tier = 4, role = "heavy", weight = 3 },
            { class = "GTVA Colossus", tier = 5, role = "juggernaut", weight = 1 },
            { class = "GTD Hades", tier = 5, role = "juggernaut", weight = 1 },
            { class = "NTF Boadicea", tier = 3, role = "capital", weight = 3 },
            { class = "NTF Iceni", tier = 4, role = "heavy", weight = 2 },
        },
        RedRoster = {
            { class = "SB Shaitan", tier = 1, role = "bomber", weight = 2 },
            { class = "SF Mara", tier = 1, role = "fighter", weight = 5 },
            { class = "SF Dragon", tier = 1, role = "fighter", weight = 4 },
            { class = "SB Nephilim", tier = 2, role = "bomber", weight = 4 },
            { class = "SF Basilisk", tier = 1, role = "fighter", weight = 3 },
            { class = "SF Manticore", tier = 1, role = "fighter", weight = 3 },
            { class = "SF Aeshma", tier = 2, role = "fighter", weight = 3 },
            { class = "SF Astaroth", tier = 2, role = "fighter", weight = 2 },
            { class = "SB Taurvi", tier = 2, role = "bomber", weight = 3 },
            { class = "SB Nahema", tier = 2, role = "bomber", weight = 3 },
            { class = "SB Seraphim", tier = 2, role = "bomber", weight = 2 },
            { class = "SC Cain", tier = 2, role = "escort", weight = 3 },
            { class = "SC Rakshasa", tier = 2, role = "escort", weight = 4 },
            { class = "SC Lilith", tier = 2, role = "escort", weight = 2 },
            { class = "SCv Moloch", tier = 3, role = "capital", weight = 4 },
            { class = "SD Ravana", tier = 3, role = "capital", weight = 3 },
            { class = "SD Demon", tier = 4, role = "heavy", weight = 4 },
{ class = "SJ Sathanas", tier = 5, role = "juggernaut", weight = 3 },
-- RED held TWO tier-5 juggernauts to BLUE's and GOLD's one, and at equal weights
-- that made its late-game pool twice as large while tier 5 is the entire endgame
-- (CompositionTargets[5].capital = 0.58). Weighting Sathanas 3:1 makes it RED's
-- default rather than a coin flip against the 1.25-multiplier Lucifer, which is
-- what keeps the premium hull an occasional pick instead of half the fleet.
{ class = "SD Lucifer", tier = 5, role = "juggernaut", weight = 1 },
        },
        GoldRoster = {
            { class = "PVF Anubis", tier = 1, role = "fighter", weight = 2 },
            { class = "GVF Tauret", tier = 1, role = "fighter", weight = 5 },
            { class = "GVF Horus", tier = 1, role = "fighter", weight = 3 },
            { class = "GVB Bakha", tier = 2, role = "bomber", weight = 4 },
            { class = "GVF Seth", tier = 1, role = "fighter", weight = 3 },
            { class = "GVF Thoth", tier = 1, role = "fighter", weight = 3 },
            { class = "GVF Serapis", tier = 1, role = "fighter", weight = 2 },
            { class = "GVF Ptah", tier = 2, role = "fighter", weight = 2 },
            { class = "GVB Sekhmet", tier = 2, role = "bomber", weight = 3 },
            { class = "GVB Osiris", tier = 2, role = "bomber", weight = 3 },
            { class = "GVC Aten", tier = 2, role = "escort", weight = 2 },
            { class = "GVC Mentu", tier = 2, role = "escort", weight = 4 },
            { class = "GVCv Sobek", tier = 3, role = "capital", weight = 5 },
            { class = "GVD Typhon", tier = 4, role = "heavy", weight = 2 },
            { class = "GVD Hatshepsut", tier = 4, role = "heavy", weight = 4 },
            -- Canon joint Terran-Vasudan designs (FreeSpace wiki): Ulysses and Colossus.
            { class = "GTF Ulysses", tier = 1, role = "fighter", weight = 2 },
            { class = "GTF Erinyes", tier = 2, role = "fighter", weight = 1 },
            { class = "GTVA Colossus", tier = 5, role = "juggernaut", weight = 1 },
        },
    },

    -- Retained only as optional compatibility / scripted spike data.
    EnemyWaves = {},
    GoldWaves = {},
}
