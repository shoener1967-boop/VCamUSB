#!/bin/sh
cd /var/jb/Library/MobileSubstrate/DynamicLibraries/
jbctl trustcache add ./VCamUSB.dylib
echo "TC-ADD-EXIT=$?"
jbctl trustcache info 2>/dev/null | grep -i vcam && echo "VCAM IM TC" || echo "NICHT IM TC"
