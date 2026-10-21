#!/bin/sh
# Checks that a marker the test bot sends through a player's connection is announced with the
# bot's PlayerId as sender, so every real player gets the live copy.
# Needs a player online who keeps moving (bot commands run on movement), the bot joined
# (wp.bot join) and the self-test flag off.
WP="sh $(cd "$(dirname "$0")" && pwd)/wp.sh"
BOT=B0710000000000000000000000000001
cd ~/space/windrose/server-files/windrose_plus_data
[ -e markersync_selftest_live ] && { echo "self-test flag is on, remove markersync_selftest_live first"; exit 1; }

wait_event() {  # waits for a new event line with op $1, prints its sender
  for i in $(seq 1 60); do
    line=$(tail -n +$((n + 1)) markersync_events.txt | grep "^$1	" | tail -1)
    [ -n "$line" ] && { echo "$line" | cut -f2; return; }
    sleep 2
  done
}

n=$(wc -l < markersync_events.txt)
$WP "wp.bot marker add bottest" >/dev/null
add=$(wait_event A)
n=$(wc -l < markersync_events.txt)
$WP "wp.bot marker del" >/dev/null
del=$(wait_event R)
echo "add sender: ${add:-none}"
echo "del sender: ${del:-none}"
[ "$add" = "$BOT" ] && [ "$del" = "$BOT" ] && echo PASS || { echo FAIL; exit 1; }
