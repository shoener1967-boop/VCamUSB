#!/bin/sh
echo "=== jbctl location ==="
which jbctl
ls -la /var/jb/usr/bin/jbctl /usr/bin/jbctl 2>/dev/null
echo "=== jbctl trustcache add (versuche beide Pfade) ==="
jbctl trustcache add /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamUSB.dylib
echo "exit1=$?"
/usr/bin/jbctl trustcache add /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamUSB.dylib
echo "exit2=$?"
echo "=== trustcache info ==="
jbctl trustcache info 2>&1 | head -30
echo "=== done ==="
