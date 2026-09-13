#!/bin/sh
echo "=== Safe-Mode Flags ==="
ls -la /var/mobile/.safemode /var/mobile/.ellekit_safemode /var/mobile/.libhooker_safemode /var/tmp/.safemode 2>/dev/null
echo "=== MobileSafety Pfade ==="
find /var -maxdepth 5 -iname '*MobileSafety*' 2>/dev/null
echo "=== ElleKit process ==="
ps aux 2>/dev/null | grep -i elle | grep -v grep
echo "=== hidden files in /var/mobile ==="
ls -la /var/mobile/ 2>/dev/null | grep '^\..*' | head
echo "=== done ==="
