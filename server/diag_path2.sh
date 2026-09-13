#!/bin/sh
echo "=== jbroot symlinks ==="
ls -la /var/jb/ | head -3
ls -la / | grep jb
echo "=== preboot ==="
ls /private/preboot/ 2>/dev/null
echo "=== fertig ==="
