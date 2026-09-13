#!/bin/sh
echo "=== jbctl help ==="
jbctl 2>&1 | head -30
echo "=== jbctl trustcache ==="
jbctl trustcache 2>&1 | head -20
echo "=== done ==="
