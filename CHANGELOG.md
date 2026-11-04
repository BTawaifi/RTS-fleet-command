# Changelog

## 1.4.7

This release answers the player feedback on the Hard-Light thread: Shivan bombers
had no anti-ship torpedo, corvette teams never built destroyers, the Sobek was far
tougher than its siblings, and a swarm of bombers could delete a command station.

**Install note:** the player package folder is now named `RTS-fleet-command-1.4.7`.
Update the folder name in your `-mod` command line (see the README).

### Fixed

- **Sobek and other "tanky" ships.** Ten hulls were quietly taking only a tenth of
  capital-beam damage and about a twentieth of Vasudan flux cannon damage, by
  accident. They now take full damage like every other hull: Deimos, Sobek, Orion,
  Hecate, Hatshepsut, Ravana, Leviathan, Lucifer, Colossus and Sathanas.
  Only command stations carry damage multipliers now.
  - What you will notice: duels between those ships resolve much faster. One heavy
    beam turret now does about ten times what it did to them. Destroyers with
    several heavy beams can kill a cruiser in roughly 10 seconds when every turret
    is in range and hitting, and a same-size destroyer in about 20 to 50 seconds.
    Typhon, Demon and Moloch already behaved this way.
- **Corvette teams never built destroyers.** The AI now builds in a ladder:
  a corvette first, then a destroyer, then a supercap once it owns a destroyer;
  afterwards it keeps two corvettes per destroyer. It saves toward the hull it is
  after instead of spending the bank on whatever is cheapest. Deimos, Sobek and
  Moloch count as the corvettes; every other capital or heavy hull is a destroyer.
- **Observer hears an afterburner for no reason.** Leaving pilot mode (or ejecting)
  now stops the afterburner loop on the observer ship. The engine call that ends
  the sound is confirmed to fire; this has not yet been confirmed by ear, so
  please tell us if you still hear it.
- **AI kept saving while its base was being whittled down.** A swarm of fighters
  cannot hurt a station quickly, so the AI never treated it as an emergency until
  the base was at 35% hull, and in the meantime it banked command points toward a
  capital. Now, if a command station loses 5% of its maximum hull within 60
  seconds, whoever is shooting it, the AI stops saving and buys defenders, and
  idle screening wings are called home. In a test with 18 fighters it bought 26
  defenders over 10 minutes instead of 10.
- **AI defenders chased one attacker per wing.** A screening wing used to get a
  named attack on a single attacker and was re-aimed about every half minute, so all
  four fighters followed the same target and 18 raiders were barely touched. Screening
  fighters now guard their station and each picks its own nearest attacker. Attacking
  bombers, escorts and capitals still draw a named attack, and bombers on screen duty
  and other missions are unchanged. Test, 18 AI-controlled fighters against the
  Shivan base at 4x speed for five minutes: with the change 18 and 11 of 18 attackers
  were destroyed and the station lost about 11.5% hull; without it 1 of 18 and about
  17%. A raid of 6: all 6 destroyed and 1.9% hull lost, against 2 destroyed and 5.9%.
  Single runs. The old behaviour can be restored with `ScreenGuardsStation = false` in
  the AI doctrine settings.

### Balance: bomber swarms against command stations

A swarm of bombers could take a station down with nothing the owner could do.
Siege ordnance now does **at most 3%** of its normal damage to command-station
hulls (damage to ships is unchanged):

| Weapon, per hit | 1.4.6 | 1.4.7 |
| --- | --- | --- |
| Cyclops torpedo | about 2,000 to 2,250 HP | 60 HP |
| Trebuchet missile | about 630 to 710 HP | 9 HP |
| Piranha cluster missile | about 1,025 to 1,340 HP | about 15 to 28 HP |
| Shivan siege torpedo | (new) | about 70 to 96 HP |

- Covered: Cyclops, Helios, Rebel Bomb, Unknown Bomb, Unknown Megabomb, the Shivan
  torpedo and the Trebuchet. Piranha's cluster children now take the same
  light-weapon reduction as the Piranha itself; before, they ignored it.
- **What a swarm does now.** If every round lands, seven four-bomber wings
  (28 bombers) of one class remove between 5% and 48% of a station in a
  two-team match (51,000 HP station): Boanerges 48%, Ursa and Sekhmet 42%,
  Medusa 37%, Artemis 31%, Nephilim 16%, Shaitan 5%. Two wings do 1.5% to 14%.
  With three or more teams stations have 39,780 HP, so those percentages are about
  28% higher. Capital beams are still what finishes a station.
- Those percentages are arithmetic from measured per-round damage and each
  ship's loadout. We have not watched a 28-bomber swarm fly a full attack in the
  engine, and station defenders (sentries, interceptors) are not part of it.
- Fighter bank sizes were cut where the new loadouts fit a lighter missile than
  retail, so a fighter's missile bank is worth roughly what its retail one was (a few
  banks carry up to about 45% more damage, for example the Perseus's 4 Trebuchets;
  a Perseus now carries 44 Tempests and 4 Trebuchets).
- Shivan destroyers are priced at 75%: Demon 10,450 CP and Ravana 12,300 CP
  (were about 13,900 and 16,400), in line with other factions' 7,800 to 9,200.

### Balance: fighter swarms against the Shivan station

The Shivan station (SI Arachnas) is far larger than the Terran and Vasudan ones
(radius 2,473 m against 1,522 m and 1,343 m), so a fighter swarm's guns hit it
almost every time. With the same hull points, 18 fighters took two to four times
as much hull off Arachnas as off the other two stations. Arachnas now takes
**40% of the fighter-gun damage** it took before (0.02 instead of 0.05); every
other damage type, including siege and capital beams, is unchanged, and the Terran
and Vasudan stations are unchanged.

- Station comparison test (18 attacking fighters, 8 guard fighters, 180 seconds,
  station turrets unlocked), hull lost: Arachnas was 14.7% and 15.5% in two runs
  with different guard fighters; with the change it is 5.4% and 8.2% in two runs.
  The same test gives Arcadia 9.6% and 7.4% and Cairo 4.4% and 5.5%.
- Full match test (AI Shivans against 18 AI-controlled fighters, 5 minutes, 4x
  speed, before the defender change above): Arachnas lost about 18% of its hull,
  against 37% to 40% before. Single
  runs; test speed changes the numbers, and real-time speed has not been measured.

### Balance: defending the base against servicing

- **A shelled base outranks servicing.** A command station that loses hull or shield
  counts as under attack for 20 seconds, whatever is shooting it. In that time no
  automatic service starts at the station unless the ship's hull is critical, and ships
  parked there with hull and systems at 60% or better go back to their orders. Player-ordered
  service and tender visits are not touched.
- **Automatic service picks the closest safe anchor.** A ship that needs service chooses
  between the base and a tender by distance, skipping any with an armed hostile near it.
  When none is safe, a routine visit waits; a critical hull goes to the nearest.
- **Ammunition ranks last, and is optional except for bombers.** Automatic service checks
  a damaged hull first, then damaged systems, then ammunition. A fighter or other ship
  keeps its primary guns when its missiles run out, so it stays in a fight while an armed
  hostile is near; a bomber, whose ordnance is its weapon, still rearms.

### Added

- **Battle map log (diagnostics, off by default).** Set `Diagnostics.BattleMapLog = true`
  in `fs2rts_config.lua` and the game writes `battle-map.tsv` to its data folder: every
  ship's position, order, hull, shield and targets every 30 seconds, plus the hits each
  command station took, by attacker and weapon, for diagnosing fleet behaviour.
  `Diagnostics.BattleMapVolleys = true` also counts each ship's primary-weapon volleys.
- **Shivan siege torpedo.** Shaitan, Nephilim, Taurvi, Nahema and Seraphim now
  carry dedicated anti-ship torpedoes. They are slow and aspect-locking, so
  escort the bomber through its approach.
- **Role loadouts.** Interceptors, assault fighters, siege bombers and
  subsystem-suppression bombers carry specialised missile profiles. Player
  production, AI production and scripted reinforcements all use the same
  profiles.
- **Loadout preview.** Hover a build icon to see the ship's role, guns, missile
  banks and ammunition before you buy it.
- **Field tender, for every faction.** An unarmed mobile workshop (1,800 CP, 30 s, two
  per team) that repairs and rearms ships in the field. Buy it with a ship selected to
  call it to that ship. **Right-click a ship with the tender selected** and the tender
  goes and services it and is then released, not left on hold; **right-click the tender
  with ships selected** and they go to it, ahead of ships it picked up by itself. An idle
  tender goes looking for work instead of waiting at the base: it heads for the ship that
  needs it most (capitals first, damaged systems counting more than hull) and trails the
  fleet when nobody needs help. Serviced ships park alongside the tender, about 120 m
  between hulls, instead of the station's 1.1 km stand-off. The AI buys one tender once
  it has 10 ships. Right-click on a tender with a combat ship selected no longer guards
  it. Based on the 1.5.0 tender, with the right-click order, seeking and docking added.
- **One supercap per team.** A team may hold one active or queued supercap
  (Colossus, Hades, Sathanas, Lucifer) at a time, for the player and for the AI.
  Losing it allows a replacement. A rejected purchase says "Team limit reached
  (including queued ships)".

### Not in this release

- Limited hangar wings (an idea from the thread) are deferred.
- Frame rate with eight teams is not addressed.
- Station gun turrets stay locked until the DEFENSES upgrade, and the AI does not buy
  it. Unlocking them in tests at 16x speed killed 0 to 6 of 18 raiders in five minutes,
  so we left the AI's buying alone. Real-time (1x) speed has not been measured for
  any of the fighter-swarm figures in this file.
- Infyrno and Shivan Cluster missiles still ignore the station damage reduction
  through their cluster children. No default loadout carries either.

### Notes for modders and testers

- New probes in `core/tools`: `damage_matrix_probe.lua` fires 20 weapons at 21
  hull types with repeats, `damage_matrix_report.py` turns the log into tables and
  a pass/fail gate, and `loadout_damage_report.py` totals each class's sortie
  damage. See `docs/DEVELOPMENT.md` for how to run a baseline comparison.
- `test_typed_weapons_spawn_children_of_the_same_type` fails if a typed weapon spawns
  a child with a different damage type.
