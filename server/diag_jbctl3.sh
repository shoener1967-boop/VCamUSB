#!/bin/sh
echo "=== ADD Befehl ==="
jbctl trustcache add /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamUSB.dylib
echo "ADD-EXIT=$?"
echo "=== count vorher/nachher ==="
jbctl trustcache info 2>/dev/null | grep -c '|'
echo "=== suche vcam cdhash ==="
jbctl trustcache info 2>/dev/null | grep -i -A2 -B2 'vcam\|VCamUSB'
echo "=== fertig ==="
