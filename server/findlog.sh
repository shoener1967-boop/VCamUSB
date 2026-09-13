#!/bin/sh
for p in /var/mobile/Documents/vcam.log /var/jb/var/mobile/Documents/vcam.log /rootfs/var/mobile/Documents/vcam.log; do
  if [ -f "$p" ]; then
    echo "GEFUNDEN: $p"
    cat "$p"
  fi
done
echo "ENDE"
