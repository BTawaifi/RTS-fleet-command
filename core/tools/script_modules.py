"""Source text of a mod module that may be split into <stem>/ part files.

A split module is an aggregator <stem>.lua whose require lines name its parts in load
order (<stem>/<part>.lua). A guard that searches a module's text must read the parts
in that order; searching only the aggregator finds nothing.
"""
import re
from pathlib import Path

# Both forms: `require "mod.part"` (flat aggregators) and `require("mod.part")(RTS, x)` (installers).
REQUIRE = re.compile(r'^\s*(?:local \w+ = )?require\s*\(?\s*["\']([^"\']+)["\']', re.M)


def module_files(scripts, stem):
    scripts = Path(scripts)
    aggregator = scripts / f'{stem}.lua'
    files = [aggregator]
    if not aggregator.is_file():
        return files
    for name in REQUIRE.findall(aggregator.read_text(encoding='utf-8')):
        if name.startswith(stem + '.'):
            files.append(scripts / (name.replace('.', '/') + '.lua'))
    return files


def module_text(scripts, stem):
    return '\n'.join(p.read_text(encoding='utf-8', errors='replace') for p in module_files(scripts, stem))
