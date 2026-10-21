# windrose-partyhud

Client-side Windrose mod that shows the other players' health in your own HUD: one row per
player with name, value and health bar, sorted by name. A row turns orange with "Kampf" for a
few seconds after the player loses health, and grey with "tot" at zero. F9 hides and shows the
panel.

Settings (position, scale, combat seconds, toggle key) are in
`mod/PartyHud/Scripts/config.lua`; Ctrl+R in game reloads them when UE4SS hot reload is on.

Status: P2 done, see `docs/plan.md`.

## Install

1. UE4SS experimental (tested `UE4SS_v3.0.1-1181-g83330635.zip` from UE4SS-RE/RE-UE4SS
   `experimental-latest`, not the zDEV one): unzip into `Windrose\R5\Binaries\Win64\`.
2. In `ue4ss\UE4SS-settings.ini` set `MajorVersion = 5`, `MinorVersion = 6`.
3. Copy `mod/PartyHud` to `ue4ss\Mods\` and add `PartyHud : 1` to `Mods\mods.txt` (above the
   `Keybinds` line). Same for `probe/PartyHudProbe` if you want the probe.

Every player who wants the panel installs it; the server needs nothing.

Uninstall: delete `dwmapi.dll` and `ue4ss\`.

## Layout

- `mod/PartyHud` the HUD, UE4SS Lua with UMG widgets built at runtime
- `docs/plan.md` what the game replicates, how the HUD works, phases
- `probe/PartyHudProbe` P0 probe: F7 logs health, distance and combat tags of every player,
  F8 toggles a watcher that logs every change (to `UE4SS.log`)
- `tools/refl.py` scans the server binary for reflected properties and their replication
  flags (runs in markersync's `windrose-dev` image, binary mounted at `/bin64`)
