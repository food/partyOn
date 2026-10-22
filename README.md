# Windrose Party On

Co-op add-on for Windrose dedicated servers, in two parts:

- **Server** (`server/partyon`, a Windrose+ mod)
  - Shared map markers: a marker one player adds, renames or removes shows up for everyone,
    live and in every player's save (`docs/markersync.md`).
  - Revive: after death a player can wait as a ghost instead of respawning, and a teammate
    brings him back where he died.
- **Client** (`client/PartyOn`, a UE4SS Lua mod, every player installs it)
  - Party panel: one row per other player with name, health and bar, sorted by name. A row
    turns orange with "Kampf" for a few seconds after the player loses health, grey with
    "tot" at zero, light blue with "wartet auf Hilfe" for a ghost. F9 hides it.
  - Revive prompts: after death F5 respawns as usual, F6 waits as a ghost (a countdown shows
    how long the choice is open). A ghost hangs
    invisible above his death spot (mobs give up there) and can cancel with F5. A teammate
    within 5 m of the spot presses F7 to revive him. A signal fire burns on every ghost's
    death spot (or a red pillar, see `config.lua`).

Settings (position, scale, combat seconds, keys, marker) are in
`client/PartyOn/Scripts/config.lua`.

## Install

Server (Windrose+ installed):

1. Build `markersync.dll` (see `docs/markersync.md`) and put it into `server/partyon/`.
2. Copy `server/partyon` to `server-files/windrose_plus_mods/partyon/` (strip CRLF from the
   Lua files) and add `"partyon"` to `windrose_plus_mods/mods_registry.json`.
3. Restart the server. Never hot-reload the Lua: the hooks crash the server.

Client, per player:

1. UE4SS experimental (tested `UE4SS_v3.0.1-1181-g83330635.zip` from UE4SS-RE/RE-UE4SS
   `experimental-latest`, not the zDEV one): unzip into `Windrose\R5\Binaries\Win64\`.
2. In `ue4ss\UE4SS-settings.ini` set `MajorVersion = 5`, `MinorVersion = 6`.
3. Copy `client/PartyOn` to `ue4ss\Mods\` and add `PartyOn : 1` to `Mods\mods.txt` (above the
   `Keybinds` line).

Uninstall on the client: delete `dwmapi.dll` and `ue4ss\`.

The panel works without the server part; markers and revive need it.

## Layout

- `server/partyon` Windrose+ mod: `init.lua` loads `markersync.dll`, `live.lua` (live markers)
  and `revive.lua` (ghosts and revive, talks to clients through
  `PlayerController:ServerExecRPC("partyon ...")`)
- `client/PartyOn` UE4SS mod, UMG widgets built at runtime, no cooked assets
- `dll` markersync hook DLL (mingw + MinHook), build container
- `docs/plan.md` research and phases of the panel and revive; `docs/markersync.md`;
  `docs/visual-candidates.md` game assets that could mark a death spot
- `probe` client dev mods: `PartyHudProbe` (F7/F8 health and tag logging),
  `PartyHudGallery` (F10-F12 asset preview); both off by default, they share keys with the HUD
- `tools` reverse engineering and test helpers: `refl.py`, `funcs.py`, `xref.py`,
  `disasm.py` (server binary), `utoc_list.py` (list and extract pak files), `probe.lua` and
  `revive_spike.lua` (server RCON probes), `dbtool`, `patch_backup.py`, `wp.sh`, `bottest.sh`
- `testserver` docker compose for the test server

Game build 0.10.0.9.32. History of the two former repos (windrose-markersync,
windrose-partyhud) is kept in this one.
