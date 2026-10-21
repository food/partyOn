#!/bin/sh
# usage: wp.sh "<command>"  (runs on ai)
J=/tmp/wp_cookies
PW=$(grep RCON ~/space/windrose/.env | cut -d= -f2)
[ -s $J ] || curl -s -c $J -o /dev/null --data-urlencode "password=$PW" http://localhost:8780/login
curl -s -b $J -H 'Content-Type: application/json' -d "$(printf '{"command":"%s"}' "$1")" http://localhost:8780/api/rcon
