# windrose-markersync

Server-side mod for the Windrose dedicated server: map markers a player adds,
renames or removes are applied to every player in the world.

Status 0.1.0: markers reach the other players' saves and show up after their
next login. They do not appear live yet.

## How it works

`dll/markersync.c` is a native DLL (mingw + MinHook) loaded by a Windrose+ Lua
mod via `package.loadlib`. It hooks two functions of the server binary:

- `R5NetBlServerReactorV2::RuleRequestServer`: every
  `R5BLPlayerInWorld_{Add,Update,Remove}UserMarkerRule` request is replayed for
  each other known player with the PlayerId in the payload swapped. MarkerIds stay
  the same, so a removal by anyone removes the marker everywhere.
- `R5NetBlSession::AddServerReactor`: captures the session, whose reactor list
  tells which connections are still alive.

Online players get the replay through their own connection, offline players
through the sender's (save only). The connection-to-player mapping is learned
from marker requests. Known PlayerIds persist in
`windrose_plus_data/markersync_players.txt`, the log goes to
`windrose_plus_data/markersync.log`.

Hook addresses are fixed RVAs for game build `0.10.0.9.32`. Before hooking, the
DLL compares 32 bytes of each target. After a game update it logs
`markersync DISABLED` and does nothing, instead of crashing the server. The
addresses then have to be found again (`tools/xref.py` on the log strings
`Server mode. RuleRequest` and `R5NetBlSession::AddServerReactor`).

## Layout on the host

```
~/space/windrose/
  docker-compose.yml, .env    <- server/ (env.example as template)
  server-files/               <- game + Windrose+, created by the image
  dev/                        <- dll/ + tools/ (build container mounts ../server-files)
```

## Build and deploy

```sh
cd ~/space/windrose/dev
docker compose build
docker compose run --rm -T windev sh build.sh
cp markersync.dll ../server-files/windrose_plus_mods/markersync/
```

Copy `mod/` to `server-files/windrose_plus_mods/markersync/` and list the mod in
`windrose_plus_mods/mods_registry.json` (`["markersync"]`). Windrose+ only loads
registered mods. A server restart is needed to load a new DLL.

`tools/guardtest.sh` builds a variant with a wrong signature and checks that the
mod disables itself, then restores the real build.
