Optional MediaVPs dependency package

Enabling this package adds the separate MVPS 4.7.x mod as a Knossos dependency.
MediaVPs are not bundled here and are not required to play FS2 RTS - Escalation.
Leave this package disabled for the smaller retail-assets-only setup.

The data/tables/z-rtsf-*-wep.tbm files replay MediaVP 4.7.3 weapon patches on
the RTS fighter aliases, preserving ranges/effects while retaining station
damage types. Load this package's data alongside Core only when MediaVPs are
installed. Re-audit/regenerate these tables when updating MediaVP weapon tables:
python core/tools/audit_fighter_weapon_overrides.py <MediaVP-directory> --output <report.json> --write-variant-patches mediavps/data/tables
Unrelated third-party weapons are not automatically supported.
