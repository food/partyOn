#!/bin/sh
# Checks marker sharing with the test bot, which sends its rules through a player's connection:
# a private marker is not announced, renaming it with the "!" prefix shares it (add event),
# renaming it back removes it for the others (remove event), deleting it then stays quiet.
# Shared events must name the bot's PlayerId as sender, so every real player gets the live copy.
# Needs a player online who keeps moving (bot commands run on movement), the bot joined
# (wp.bot join) and the self-test flag off.
WP="sh $(cd "$(dirname "$0")" && pwd)/wp.sh"
BOT=B0710000000000000000000000000001
cd ~/space/windrose/server-files/windrose_plus_data
[ -e markersync_selftest_live ] && { echo "self-test flag is on, remove markersync_selftest_live first"; exit 1; }

events() {  # event lines since line $start; the DLL writes them with CRLF under Wine
  tail -n +$((start + 1)) markersync_events.txt | tr -d '\r'
}

wait_event() {  # waits for an event line with op $1 matching $2, prints it
  for i in $(seq 1 60); do
    line=$(events | grep "^$1	" | grep -- "$2" | tail -1)
    [ -n "$line" ] && { echo "$line"; return; }
    sleep 2
  done
}

wait_ran() {  # waits until the bot log shows a command containing $1
  for i in $(seq 1 60); do
    $WP "wp.bot log 3" | grep -q -- "$1" && return
    sleep 2
  done
}

start=$(wc -l < markersync_events.txt)
$WP "wp.bot marker add bottest" >/dev/null
wait_ran "run marker add"
$WP "wp.bot marker rename !bottest" >/dev/null
shared=$(wait_event A "	!bottest$")
mid=$(echo "$shared" | cut -f3)
private=$(events | grep -c "	bottest$")
$WP "wp.bot marker rename bottest" >/dev/null
unshared=$(wait_event R "	${mid:-none}$")
before=$(events | grep -c "${mid:-none}")
$WP "wp.bot marker del" >/dev/null
wait_ran "marker del ${mid:-none}"
sleep 4
after=$(( $(events | grep -c "${mid:-none}") - before ))
echo "events for the private add: $private (want 0)"
echo "share sender: $(echo "$shared" | cut -f2)"
echo "unshare sender: $(echo "$unshared" | cut -f2)"
echo "events for the delete: $after (want 0)"
[ "$private" = 0 ] && [ "$(echo "$shared" | cut -f2)" = "$BOT" ] &&
  [ "$(echo "$unshared" | cut -f2)" = "$BOT" ] && [ "$after" = 0 ] && echo PASS || { echo FAIL; exit 1; }
