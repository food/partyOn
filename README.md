# windrose-partyhud

Client-side Windrose mod that shows the other players' health in your own HUD: name, health
bar and, if the game exposes it, whether they are in combat.

Status: research done, nothing built yet. See `docs/plan.md`.

## Probe install

1. UE4SS experimental (tested `UE4SS_v3.0.1-1181-g83330635.zip` from UE4SS-RE/RE-UE4SS
   `experimental-latest`, not the zDEV one): unzip into `Windrose\R5\Binaries\Win64\`.
2. In `ue4ss\UE4SS-settings.ini` set `MajorVersion = 5`, `MinorVersion = 6`.
3. Copy `probe/PartyHudProbe` to `ue4ss\Mods\` and add `PartyHudProbe : 1` to `Mods\mods.txt`
   (above the `Keybinds` line).

Uninstall: delete `dwmapi.dll` and `ue4ss\`.

## Layout

- `docs/plan.md` what the game replicates, how the HUD would be built, phases
- `probe/PartyHudProbe` P0 UE4SS Lua mod: Ctrl+F7 logs health, owner, distance and combat
  tags of every attribute set the client knows (`UE4SS.log` and `probe.txt` in the mod folder)
- `tools/refl.py` scans the server binary for reflected properties and their replication
  flags (runs in markersync's `windrose-dev` image, binary mounted at `/bin64`)
