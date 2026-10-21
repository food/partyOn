#!/bin/sh
# builds markersync.dll with mingw + MinHook (runs inside windev container)
set -e
MH=/opt/minhook
x86_64-w64-mingw32-gcc -O2 -shared -static-libgcc -o markersync.dll markersync.c \
  $MH/src/buffer.c $MH/src/hook.c $MH/src/trampoline.c $MH/src/hde/hde64.c \
  -I$MH/include -Wl,--subsystem,windows
ls -la markersync.dll
