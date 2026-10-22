# Shared map markers (markersync)

Part of Windrose Party On, server side: shared map markers a player adds,
renames or removes are applied to every player in the world.

A marker is shared while its name starts with `!`; all other markers stay private.
Shared markers show up live for every online player and are kept in every player's
save, so they are still there after a relog.

| Rule | Shared before | Name with `!` now | Other players get |
| --- | --- | --- | --- |
| Add | - | yes | add |
| Update | yes | yes | update |
| Update | no | yes | add |
| Update | yes | no | remove |
| Remove | yes | - | remove |

All other cases stay with the owner. An add or removal that comes from an update is a
request the DLL builds itself (same payload, other rule name, the three ids only for a
removal). The MarkerIds of shared markers are kept in
`windrose_plus_data/markersync_shared.txt`, so a marker shared before a server restart
still counts as shared afterwards.

Markers shared before this rule existed (every marker was shared then) are not in that
list: copies the others already have stay in their saves, and renaming or removing the
original no longer reaches them. One that was already named `!...` is sent to the others as
an add again on its next update, for a MarkerId they already have.

## How it works

`dll/markersync.c` is a native DLL (mingw + MinHook) loaded by a Windrose+ Lua
mod via `package.loadlib`. It hooks two functions of the server binary:

- `R5NetBlServerReactorV2::RuleRequestServer`: every
  `R5BLPlayerInWorld_{Add,Update,Remove}UserMarkerRule` request is replayed for
  each other known player with the PlayerId in the payload swapped. MarkerIds stay
  the same, so a removal by anyone removes the marker everywhere.
- `R5NetBlSession::AddServerReactor`: captures the session, whose reactor list
  tells which connections are still alive.

The DLL also calls the game's own getter for a connection's AccountId
(`reactor+0x20` gRPC metadata `account-id`).

**Persistence (DLL):** the rule replay writes the marker into each player's
`PlayerInWorld` record. A client ignores the resulting diff on screen, though,
so this alone only shows after the next login.

**Live (Lua, `server/partyon/live.lua`):** for each marker action the DLL appends a line to
`windrose_plus_data/markersync_events.txt` (action, sender AccountId, MarkerId,
position, icon, far-away flag, name). The Lua side reads it every 300 ms. For every other
online player it creates, moves, renames or destroys a marker model with
`R5MarkersSystemComponent:CreateMarker` / `DestroyMarker` on that player's
PlayerState. These server-side models replicate to their owner only and appear
at once. After a relog the PlayerState is new, so the model is gone and the
marker comes from the save, without duplicates.

Online players get the replay through their own connection, offline players
through the sender's (save only). The connection-to-player mapping is learned
from marker requests. Known PlayerIds persist in
`windrose_plus_data/markersync_players.txt`, the log goes to
`windrose_plus_data/markersync.log`.

A connection can carry rules for another player: the test bot
(`windrose-testbot`) sends its marker rules through a connected player's
connection. So each account's own PlayerId is the first one seen on its
connections, persisted in `windrose_plus_data/markersync_accounts.txt`
(`AccountId PlayerId` per line). Rules for any other PlayerId do not relink the
connection, and their events name that PlayerId as sender, so every real player
gets the live copy. An account whose first marker rule comes from the bot is
learned wrong; add the line by hand before using the bot with a new account.
The same goes for a new character on a known account: its markers count as sent
on someone's behalf until the account's line is fixed by hand.

Hook and call addresses are fixed RVAs for game build `0.10.0.9.32`. Before hooking, the
DLL compares 32 bytes of each target. After a game update it logs
`markersync DISABLED` and does nothing, instead of crashing the server. The
addresses then have to be found again (`tools/xref.py` on the log strings
`Server mode. RuleRequest` and `R5NetBlSession::AddServerReactor`; the AccountId
getter is the call right before the `AccountId {}` log in `AddServerReactor`).

## Known limits

- Marker icon: the rule's `Type` is passed to `SetIcon`. The mapping is unverified.
- A marker that a player already had from the save (placed before they logged in)
  only disappears for them after a relog when someone else removes it. The live
  path only knows the models it created.
- Removing or editing another player's live marker (a server-side model) has not
  been tested.
- `wp.msync [poll]` (RCON) shows the live state: event offset, players found,
  models per player.

## Layout on the host

```
~/space/windrose/
  docker-compose.yml, .env    <- testserver/ (env.example as template)
  server-files/               <- game + Windrose+, created by the image
  dev/                        <- dll/ + tools/ (build container mounts ../server-files)
```

## Build and deploy

```sh
cd ~/space/windrose/dev
docker compose build
docker compose run --rm -T windev sh build.sh
cp markersync.dll ../server-files/windrose_plus_mods/partyon/
```

The DLL ships inside the `partyon` mod, see the README for the install. A server restart is
needed to load a new DLL.

`tools/probe.lua` has the reverse-engineering RCON commands (`wp.uprobe`,
`wp.rpcs`, `wp.mktest`, ...); it is not part of the deployed mod.

`tools/guardtest.sh` builds a variant with a wrong signature and checks that the
mod disables itself, then restores the real build.
