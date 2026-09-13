#!/bin/sh
echo "=== wo liegt die Dylib physisch? ==="
ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamUSB.dylib
readlink -f /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamUSB.dylib
echo "=== rootfs mount check ==="
ls -la /rootfs/private/preboot/ 2>/dev/null | head -5
find /private/preboot -maxdepth 5 -name 'VCamUSB.dylib' 2>/dev/null | head -5
find /rootfs -maxdepth 8 -name 'VCamUSB.dylib' 2>/dev/null | head -5
echo "=== jbroot symlink ==="
ls -la /var/jb/ 2>/dev/null | head -5
ls -la /.jbroot 2>/dev/null
echo "=== fertig ==="
