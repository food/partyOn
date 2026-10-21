# windrose-partyhud

Client-side Windrose mod that shows the other players' health in your own HUD: name, health
bar and, if the game exposes it, whether they are in combat.

Status: research done, nothing built yet. See `docs/plan.md`.

## Layout

- `docs/plan.md` what the game replicates, how the HUD would be built, phases
- `tools/refl.py` scans the server binary for reflected properties and their replication
  flags (runs in markersync's `windrose-dev` image, binary mounted at `/bin64`)
