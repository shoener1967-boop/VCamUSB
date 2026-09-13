#!/bin/sh
echo "=== trust/jbctl tools ==="
ls /var/jb/usr/bin/ | grep -iE 'trust|jbctl|rootfs'
which jbctl trustcache 2>/dev/null
echo "=== TrustCache files ==="
find /var/jb -maxdepth 4 -iname '*trustcache*' 2>/dev/null
find / -maxdepth 5 -iname '*trustcache*' -not -path '*/dev/*' 2>/dev/null | head
echo "=== done ==="
