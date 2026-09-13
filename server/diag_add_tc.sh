#!/bin/sh
echo "=== 1. Versuch: rootfs-Pfad ==="
jbctl trustcache add /rootfs/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamUSB.dylib
echo "EXIT1=$?"
echo "=== 2. Versuch: relativer Pfad vom CWD ==="
cd /var/jb/Library/MobileSubstrate/DynamicLibraries/
jbctl trustcache add ./VCamUSB.dylib
echo "EXIT2=$?"
echo "=== 3. Versuch: readlink auflösen ==="
REAL=$(readlink -f /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamUSB.dylib)
echo "REAL=$REAL"
jbctl trustcache add "$REAL"
echo "EXIT3=$?"
echo "=== 4. info grep ==="
jbctl trustcache info 2>/dev/null | grep -i vcam && echo "VCAM IM TRUSTCACHE!" || echo "NICHT im TrustCache"
echo "=== fertig ==="
