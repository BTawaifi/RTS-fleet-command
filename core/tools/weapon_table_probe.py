"""Does the engine actually load core/data/tables/fs2rts-sentry-wep.tbm?

Runs a SHORT headless sim with an injected diagnostic and reports what the
engine saw. 300 s is enough: the first sentry completes ~t=323 in a 3000 s
match, and EnableFullArsenal/CreateSentry run on completion, so 400 s is the
smallest safe window.

This exists because the mod's only warning for a missing weapon class is
self:Log -> ba.print, which writes to stdout - and stdout.log is 0 bytes in a
staged headless run. The failure is therefore completely silent in batch, which
is exactly how a batch can look green while the sentries keep their retail
weapons.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

STAGE = Path(r"D:\Games\FreespaceOpen\FS2\RTS-fleet-command-1.4.1")
WORK = Path(r"C:\Users\User\AppData\Local\Temp\kilo\wepprobe")
EXE = Path(r"D:\Games\FreespaceOpen\src\fs2open\build\bin\Release\fs2_open_26_1_0_x64_AVX2.exe")

PROBE_NAMES = (
    "RTS Sentry Screen Laser",
    "RTS Sentry Flak",
    "RTS Sentry Missiles",
    "RTS Sentry Beam",
    "Prometheus R",
    "Terran Turret",
)

PROBE = """
-- TEMPORARY diagnostic, injected by tools/weapon_table_probe.py
--
-- Every lookup is by NAME. Do not iterate this table: tb.WeaponClasses is an
-- ADE indexer userdata, and pairs()/ipairs() over it does not behave like a
-- Lua table. It cost a real match - the engine aborted at the first sentry
-- build (~t=323) and the batch reported a 17-second failure.
function RTS:__WeaponProbe()
    local out = {}
    local wc = tb and tb.WeaponClasses or nil
    out[#out+1] = "tb is "..tostring(tb)
    out[#out+1] = "WeaponClasses is "..tostring(wc)
    local ok, err = pcall(function()
        for i = 1, #__PROBE_NAMES do
            local name = __PROBE_NAMES[i]
            local w = wc[name]
            if w == nil then
                out[#out+1] = name .. " -> nil"
            elseif not w:isValid() then
                out[#out+1] = name .. " -> INVALID HANDLE (exists as a name, no such weapon class)"
            else
                out[#out+1] = string.format(
                    "%s -> OK damage=%s lifemax=%s speed=%s range=%s damageType=%s",
                    name, tostring(w.Damage), tostring(w.LifeMax),
                    tostring(w.Speed), tostring(w.Range),
                    tostring(w.DamageType))
            end
        end
    end)
    if not ok then out[#out+1] = "LOOKUP ERROR: " .. tostring(err) end
    local f = io.open("weapon-probe.txt", "w")
    if f then
        for i=1,#out do f:write(out[i].."\\n") end
        f:close()
    end
end
"""

PROBE = PROBE.replace("__PROBE_NAMES", repr(tuple(PROBE_NAMES)))


def main():
    if WORK.exists():
        shutil.rmtree(WORK)
    shutil.copytree(STAGE / "core", WORK)
    # hardlink the VP trees from a known-good staged base
    base = Path(r"D:\Games\FreespaceOpen\FS2\rts-headless-staging\sentryfix-20261002c\base")
    for mod in ("probe", "rts"):
        src = base / mod
        dst = WORK.parent / ("wp_" + mod)
        if dst.exists():
            shutil.rmtree(dst)
        # Copy the mod DIRECTORY itself. Copying src.parent lands each mod
        # inside a nested folder, so `-mod wp_probe,wp_rts` names a directory
        # that holds two more directories and the engine never loads the mod -
        # which is why the probe hung to its timeout with no output file.
        shutil.copytree(src, dst, ignore=shutil.ignore_patterns("results", "*.jsonl"))
    # inject the probe into the rts scripts and call it once
    script = WORK / "data" / "scripts" / "fs2rts_station.lua"
    text = script.read_text(encoding="utf-8")
    text = text + "\n" + PROBE
    text += "\nif mn.getMissionTime() > 1 and mn.getMissionTime() < 2 then RTS:__WeaponProbe() end\n"
    script.write_text(text, encoding="utf-8", newline="")

    result = subprocess.run(
        [str(EXE), "-portable_mode", "-mod", "wp_probe,wp_rts",
         "-start_mission", "FS2_RTS_Escalation", "-pilot", "Alver",
         "-headless", "-fixed-dt", "0.03333333333333333",
         "-max-sim-time", "400.0",
         "-sim-result", str(WORK / "res.json"),
         "-noninteractive", "-seed", "2026092901"],
        cwd=str(WORK.parent), capture_output=True, text=True, timeout=900)
    print("exit code:", result.returncode)
    out = WORK / "weapon-probe.txt"
    if out.exists():
        print("--- weapon-probe.txt ---")
        print(out.read_text(encoding="utf-8"))
    else:
        print("probe file not written; stdout:")
        print(result.stdout[-2000:])
        print("stderr:")
        print(result.stderr[-2000:])


if __name__ == "__main__":
    main()