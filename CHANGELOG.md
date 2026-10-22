# Changelog

## Unreleased

### Changed

- Only markers whose name starts with `!` are shared; all others stay private. Renaming a
  marker to or from `!` shares or unshares it, which also shares markers placed before the
  mod was installed (#2, #3).

## 0.3.1 (2026-10-22)

### Added

- Countdown in the respawn/wait prompt after death.

## 0.3.0 (2026-10-22)

First version as Windrose Party On.

### Added

- Client mod `PartyOn` (UE4SS Lua): party panel with name, health and bar per player, sorted
  by name; "Kampf" after a health loss, "tot" at zero, "wartet auf Hilfe" for ghosts; F9
  hides it; settings in `config.lua`.
- Revive: after death F5 respawns as usual, F6 waits as a ghost above the death spot (hidden,
  frozen, no damage, out of the mobs' reach); F5 cancels, a teammate within 5 m revives with
  F7 on the death spot.
- Signal fire on every ghost's death spot, a red pillar as an option.
- Tools to list and extract the game's pak files and to scan the server binary for reflected
  properties and functions.

### Changed

- windrose-markersync and windrose-partyhud are one repository with both histories, and one
  Windrose+ mod `partyon` on the server (markersync DLL, live markers, revive).
