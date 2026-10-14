# FreeSpace RTS: Fleet Command

![FreeSpace RTS: Fleet Command — capital ships above a planet](artwork/banner.jpg)

**Command the fleet. Take the cockpit. Bring your survivors home.**

Build a battle group, protect your command station, and fight for control of the battlefield. Then press **P** to take the controls of one of your ships — from a fighter to a capital — before returning to the tactical view.

Fleet Command is a **single-player RTS mod for FreeSpace Open**. Battles grow from station skirmishes into bomber strikes, capital engagements, and desperate withdrawals.

**[Player downloads](https://github.com/BTawaifi/RTS-fleet-command/releases)** · **[Player guide and controls](core/README.md)** · **[Discussion and feedback](https://www.hard-light.net/forums/index.php?topic=100151.0)**

Featured in the **[Hard-Light Highlights](https://www.hard-light.net/forums/index.php?topic=100152.0)**. Visit **[Hard-Light Productions](https://www.hard-light.net/)** for the FreeSpace community, mods, and development.

## Architecture

Fleet Command adds a Lua-driven strategy layer to FreeSpace Open. The engine supplies flight, physics, weapons, and rendering. The mod coordinates fleet commands, production, station development, AI planning, and battle outcomes.

[The Lua entry point](core/data/scripts/fs2rts.lua) loads feature modules that extend a [shared RTS state](core/data/scripts/fs2rts_state.lua). [Engine hooks](core/data/tables/fs2rts-sct.tbm) connect that state to frame updates, input, HUD drawing, combat events, and ship departures. The diagram groups responsibilities within that shared runtime.

```mermaid
flowchart LR
    Content["Mission, tables<br/>and assets"] --> Engine["FreeSpace Open"]
    Config["Lua configuration"] --> Runtime["Shared Lua<br/>RTS runtime"]
    Engine -->|"Frame, input, HUD<br/>and ship events"| Hooks["Engine hook table"]
    Hooks --> Runtime
    Runtime -->|"Native API calls"| Engine
    Runtime --- Interface["Camera, input,<br/>selection and HUD"]
    Runtime --- Control["Orders and<br/>direct piloting"]
    Runtime --- Economy["Economy, production,<br/>stations and service"]
    Runtime --- AI["AI strategy, operations<br/>and observation"]
    Runtime --- Outcomes["Fleet history, extraction<br/>and battle outcomes"]
```

| Area | Responsibility | Entry points |
| --- | --- | --- |
| **Engine integration** | Load the Lua runtime and connect native frame, input, HUD, combat, and ship-lifecycle events to mod behavior. | [Hook table](core/data/tables/fs2rts-sct.tbm) |
| **Runtime and lifecycle** | Shared state, scenario setup, frame orchestration, pause handling, restart, and shutdown. Simulation uses mission time; interface updates have a separate clock. | [State](core/data/scripts/fs2rts_state.lua), [lifecycle](core/data/scripts/fs2rts_lifecycle.lua) |
| **Player interface** | Tactical camera, selection, minimap, HUD panels, world overlays, music, and backdrops. | [HUD](core/data/scripts/fs2rts_hud.lua), [input](core/data/scripts/fs2rts_input.lua), [environment](core/data/scripts/fs2rts_environment.lua) |
| **Orders and piloting** | Formation movement, attack and guard commands, control groups, ship possession, capital batteries, and native wing commands. | [Orders](core/data/scripts/fs2rts_orders.lua), [piloting](core/data/scripts/fs2rts_pilot.lua), [player wings](core/data/scripts/fs2rts_player_wing.lua) |
| **Economy and stations** | Faction rosters, command points, production queues, escalation, upgrades, sentries, abilities, and paid repair/rearm. | [Production](core/data/scripts/fs2rts_production.lua), [stations](core/data/scripts/fs2rts_station.lua), [service](core/data/scripts/fs2rts_service.lua) |
| **AI coordination** | Battlefield snapshots feed threat assessment and objective scoring. Operations coordinate multiple wings, while native AI handles immediate flight and combat. Observation and telemetry track execution separately from planned intent. | [Planning](core/data/scripts/fs2rts_ai_planning.lua), [strategy](core/data/scripts/fs2rts_strategy.lua), [operations](core/data/scripts/fs2rts_operations.lua) |
| **Fleet history and outcomes** | Ship histories, losses, crew estimates, citations, extraction, splinter raids, station results, and final fleet outcomes. | [Fleet life](core/data/scripts/fs2rts_fleet_life.lua), [crew records](core/data/scripts/fs2rts_fleet_humanity.lua), [raids](core/data/scripts/fs2rts_traitors.lua) |
| **Content and packaging** | Missions define the scenario; tables define ships, weapons, armor, and factions. Models and textures supply assets, with optional MediaVP compatibility patches and launcher metadata. | [Configuration](core/data/scripts/fs2rts_config.lua), [scenario](core/data/missions/FS2_RTS_Escalation.fs2), [package metadata](mod.json), [MediaVP support](mediavps/README.txt) |

### Runtime flow

During normal gameplay, [the frame loop](core/data/scripts/fs2rts_lifecycle.lua) updates the active view before checking whether mod simulation updates should proceed. Input and HUD drawing also have their own engine hooks. The simplified flow below shows the main update sequence; individual systems apply their own scenario and lifecycle checks.

```mermaid
flowchart TD
    Frame["Engine frame hook"] --> Clock["Advance the interface clock"]
    Clock --> View["Update active camera or pilot view"]
    View --> Gate{"Paused, battle report or exit menu?"}
    Gate -->|"Yes"| Hold["Skip mod simulation updates"]
    Gate -->|"No"| Economy["Update economy, production, stations and service"]
    Economy --> Orders["Reconcile orders and update tactical AI"]
    Orders --> Fleet["Update survivor combat, fleet life and raids"]
    Fleet --> Result["Evaluate escalation and battle outcomes"]
```

Player commands, direct piloting, autonomous planning, station service, and withdrawal all interact with the same native ships. Their control rules coordinate those transitions. Death and departure hooks update fleet records, while station resolution and the final fate of surviving ships remain separate outcomes.


## Choose your battle

- **Nine faction identities, 2–12 teams.** Field GTA, GTVA, PVN, Vasudan Empire, NTF, loyal or rogue GTI, Hammer of Light, or Shivan fleets. Choose each team's faction and color, with Circle, Star, and Multiple Circles starting layouts.
- **Command from above, fight from within.** Give attack, guard, formation, and withdrawal orders. Pilot friendly ships with native flight controls; capitals add selectable turret batteries and manual guns and beams.
- **Build a station worth defending.** Invest in Armor, Defenses, Logistics, and Command. Place sentries, unlock faction abilities, and bring damaged ships back for paid repair and rearm.
- **Keep track of the ships you fought beside.** CREWS records this battle's flown ships, losses, escapes, and citations. Optional crew and casualty estimates stay hidden until you press F9.
- **Fight beyond the loss of your station.** Withdraw your surviving fleet or continue the battle. Station outcomes and the final fate of your mobile forces are recorded separately.
- **Set the pace and the scene.** Pause to issue orders, adjust time compression, pick music and a sky backdrop, or let the battle director follow the action. Rare announced splinter raids introduce new hostile ships.

Fleet Command is under active development. Balance and performance are still being tested, especially in large late-game fleets, twelve-team battles, and high time compression. Feedback and bug reports are welcome in the [discussion thread](https://www.hard-light.net/forums/index.php?topic=100151.0).

## Get into the battle

You need **retail FreeSpace 2 assets** and **FreeSpace Open**. MediaVPs are optional.

Follow the [player guide](core/README.md) to install and launch the mod. Choose your teams, click **START ESCALATION**, and build your fleet. The guide also covers controls, optional MediaVP loading, station service, and piloting.

## Contributing

Want to extend Fleet Command? [Open an issue](https://github.com/BTawaifi/RTS-fleet-command/issues) to discuss an idea or report a bug, or [submit a pull request](https://github.com/BTawaifi/RTS-fleet-command/pulls) with your changes.

Describe what the change does, why it is needed, and how you tested it. For gameplay bugs, include the FSO build, factions, team count, and steps to reproduce.

## Credits

Created by Boutros. Third-party assets retain their owners' terms; see [asset credits](core/data/ASSET-CREDITS.txt), [FSPort credits](core/data/FSPORT-ASSET-CREDITS.txt), and [insignia credits](core/data/maps/README-insignias.txt).
