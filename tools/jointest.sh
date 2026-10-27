#!/bin/sh
# Checks that a player who never touched a marker is learned from the location save and gets
# the shared markers made before that. Setup: stop the server, remove the player's PlayerId
# from markersync_players.txt, start the server, log in with that player and keep moving
# (bot commands run on movement). The bot then shares a marker through that connection;
# within about a minute the player must be learned and the marker sent. It shows after the
# next login. The marker stays shared; after checking it, remove it with "wp.bot marker del".
# usage: jointest.sh <PlayerId>
WP="sh $(cd "$(dirname "$0")" && pwd)/wp.sh"
PID=${1:?PlayerId}
cd ~/space/windrose/server-files/windrose_plus_data
grep -q "^$PID" markersync_players.txt && { echo "$PID is already known, remove it first"; exit 1; }
start=$(wc -l < markersync.log)

log() {  # DLL log lines since line $start, without the CR Wine writes
  tail -n +$((start + 1)) markersync.log | tr -d '\r'
}

$WP "wp.bot join" >/dev/null
$WP "wp.bot marker add !jointest" >/dev/null
for i in $(seq 1 60); do
  log | grep -q "learned player $PID" && break
  sleep 3
done
shared=$(log | grep -c "AddUserMarkerRule from B071.* others get A")
sent=$(log | grep "sent [0-9]* shared markers to $PID" | tail -1 | grep -o "sent [0-9]*" | cut -d' ' -f2)
echo "bot shared before the player was known: $shared (want 1)"
echo "markers sent to $PID: ${sent:-none} (want at least 1)"
[ "$shared" = 1 ] && [ "${sent:-0}" -ge 1 ] && echo PASS || { echo FAIL; exit 1; }
