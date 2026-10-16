#!/bin/sh
# Checks that markersync refuses to hook when the signature does not match, then restores the real DLL.
set -e
cd ~/space/windrose
python3 -c "
s = open('dev/markersync.c').read()
assert s.count(r'\x4f\xa8\x93\"') == 1
open('dev/guard_bad.c', 'w').write(s.replace(r'\x4f\xa8\x93\"', r'\x4f\xa8\x94\"'))
"
sed 's/markersync\.c/guard_bad.c/; s/-o markersync\.dll/-o guard_bad.dll/; s/ls -la markersync\.dll/ls -la guard_bad.dll/' dev/build.sh > dev/guard_build.sh
(cd dev && docker compose run --rm -T windev sh guard_build.sh 2>&1 | grep -E "error|guard_bad.dll")

LOG=server-files/windrose_plus_data/markersync.log
restart_and_wait() {  # waits for the DLL to write its startup line
  n=$(wc -l < $LOG)
  docker compose restart >/dev/null 2>&1
  for i in $(seq 1 60); do [ "$(wc -l < $LOG)" -gt "$n" ] && return; sleep 5; done
  echo "timeout waiting for markersync log"
}
cp dev/guard_bad.dll server-files/windrose_plus_mods/markersync/markersync.dll
restart_and_wait
echo "bad build:  $(tail -1 server-files/windrose_plus_data/markersync.log)"

cp dev/markersync.dll server-files/windrose_plus_mods/markersync/markersync.dll
rm -f dev/guard_bad.c dev/guard_bad.dll dev/guard_build.sh
restart_and_wait
echo "good build: $(tail -1 server-files/windrose_plus_data/markersync.log)"
echo "server: $(docker inspect -f '{{.State.Status}}' windrose)"
